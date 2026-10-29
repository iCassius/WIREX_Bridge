Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\ui\windows\RadioIdentity.psm1'
Import-Module -Name $modulePath -Force

$script:assertionCount = 0
$script:transportCount = 0
$script:lastRequest = $null

function Assert-RadioIdentityTest {
    param([bool]$Condition, [string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "FAILED: $Message" }
}

function Assert-RadioIdentityThrows {
    param([scriptblock]$Action, [string]$Message)
    $script:assertionCount++
    try { & $Action } catch { return }
    throw "FAILED: expected an exception: $Message"
}

function Start-RadioIdentityHttpFixture {
    param([Parameter(Mandatory = $true)][string]$Mode, [Parameter(Mandatory = $true)][string]$Root)

    $readyPath = Join-Path $Root ('http-' + [guid]::NewGuid().ToString('N') + '.ready')
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        $powerShellPath = Join-Path $PSHOME 'pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) { throw 'PowerShell executable for the local HTTP fixture is missing.' }
    $helperScript = Join-Path $PSScriptRoot 'test-radio-identity-http-server.ps1'
    $quotedScript = '"' + $helperScript.Replace('"', '""') + '"'
    $quotedReadyPath = '"' + $readyPath.Replace('"', '""') + '"'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript,
        '-Mode', $Mode, '-ReadyFile', $quotedReadyPath)
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden -PassThru
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and -not $process.HasExited -and $clock.ElapsedMilliseconds -lt 5000) {
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $code = if ($process.HasExited) { $process.ExitCode } else { -1 }
        $process.Dispose()
        throw "Local HTTP fixture failed to start (exit $code)."
    }
    $port = 0
    if (-not [int]::TryParse([IO.File]::ReadAllText($readyPath), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $process.Dispose()
        throw 'Local HTTP fixture reported an invalid TCP port.'
    }
    return [pscustomobject]@{ process = $process; port = $port; ready_path = $readyPath }
}

function Stop-RadioIdentityHttpFixture {
    param([Parameter(Mandatory = $true)][object]$Fixture)

    $process = $Fixture.process
    try {
        if (-not $process.WaitForExit(3000)) {
            $process.Kill()
            [void]$process.WaitForExit(2000)
            throw 'Local HTTP fixture did not exit after the request ended.'
        }
        if ($process.ExitCode -ne 0) { throw "Local HTTP fixture exited with code $($process.ExitCode)." }
    } finally {
        if (Test-Path -LiteralPath $Fixture.ready_path -PathType Leaf) {
            Remove-Item -LiteralPath $Fixture.ready_path -Force -ErrorAction SilentlyContinue
        }
        $process.Dispose()
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wirex-radio-identity-' + [guid]::NewGuid().ToString('N'))
$cachePath = Join-Path $testRoot 'radio-identity-cache.json'
$missingPath = Join-Path $testRoot 'missing\radio-identity-cache.json'
$validId = [uint32]7654321
$unknownId = [uint32]7654322
$mismatchId = [uint32]7654323
$conflictId = [uint32]7654324

$validBody = '{"page":1,"pages":1,"count":1,"per_page":100,"results":[{"id":7654321,"radio_id":7654321,"callsign":"N0TEST","name":"Test Operator","fname":"Test","surname":"Operator","city":"Fixture City","state":"ZZ","country":"Fixtureland"}]}'
$validTransport = {
    param($Request)
    $script:transportCount++
    $script:lastRequest = $Request
    return [pscustomobject]@{ status_code = 200; body = $validBody }
}

try {
    $path = Get-RadioIdentityCachePath -UserConfigDirectory $testRoot
    Assert-RadioIdentityTest ($path -eq $cachePath) 'cache path uses the supplied user config directory'
    Assert-RadioIdentityTest (-not (Test-Path -LiteralPath $testRoot)) 'resolving a cache path does not create its directory'

    $missing = Resolve-RadioIdentity -RadioId $validId -CachePath $cachePath
    Assert-RadioIdentityTest ($missing.status -eq 'unavailable' -and $missing.display_name -eq "DMR ID $validId") 'empty cache returns the numeric fallback'
    Assert-RadioIdentityTest (-not (Test-Path -LiteralPath $testRoot)) 'offline resolve does not create a missing cache directory'
    Assert-RadioIdentityThrows { Resolve-RadioIdentity -RadioId 0 -CachePath $cachePath } 'zero RadioId is rejected'
    Assert-RadioIdentityThrows { Resolve-RadioIdentity -RadioId 16777216 -CachePath $cachePath } 'RadioId above the 24-bit maximum is rejected'
    Assert-RadioIdentityThrows { Resolve-RadioIdentity -RadioId 'not-an-id' -CachePath $cachePath } 'non-numeric RadioId is rejected'

    $found = Invoke-RadioIdentityQuery -RadioId $validId -CachePath $cachePath -TimeoutSec 5 -Transport $validTransport
    Assert-RadioIdentityTest ($found.status -eq 'found') 'a single exact result is accepted'
    Assert-RadioIdentityTest ($found.callsign -eq 'N0TEST' -and $found.name -eq 'Test Operator') 'identity fields are normalized'
    Assert-RadioIdentityTest ($found.display_name -eq 'N0TEST (Test Operator)' -and $found.id -eq $validId -and $found.source_id -eq $validId) 'display label includes exact ID identity'
    Assert-RadioIdentityTest ($found.cache_saved -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) 'successful lookup is cached'
    Assert-RadioIdentityTest ($script:transportCount -eq 1) 'one explicit query makes one transport request'
    Assert-RadioIdentityTest ($script:lastRequest.method -eq 'GET' -and $script:lastRequest.uri -eq 'https://radioid.net/api/dmr/user/?id=7654321&id_sel=%3D') 'query uses the exact DMR user endpoint and exact ID filter'
    Assert-RadioIdentityTest ($script:lastRequest.timeout_seconds -eq 5 -and $script:lastRequest.timeout_milliseconds -le 5000) 'transport timeout is bounded to five seconds'
    Assert-RadioIdentityTest ($script:lastRequest.user_agent -like 'WIREX Bridge/*contact: https://github.com/iCassius)') 'automated User-Agent identifies the app and public contact'
    $resolved = Resolve-RadioIdentity -RadioId $validId -CachePath $cachePath
    Assert-RadioIdentityTest ($resolved.status -eq 'found' -and $resolved.callsign -eq 'N0TEST') 'fresh cache resolves without a network request'
    Assert-RadioIdentityTest ($script:transportCount -eq 1) 'offline resolve leaves transport untouched'

    $nameFallbackId = [uint32]7654325
    $nameFallbackTransport = {
        param($Request)
        $script:transportCount++
        $script:lastRequest = $Request
        return [pscustomobject]@{ status_code = 200; body = '{"count":1,"results":[{"id":7654325,"radio_id":7654325,"callsign":"N1TEST","fname":"First","surname":"Last","city":"Fixture City"}]}' }
    }
    $nameFallback = Invoke-RadioIdentityQuery -RadioId $nameFallbackId -CachePath $cachePath -Transport $nameFallbackTransport
    Assert-RadioIdentityTest ($nameFallback.status -eq 'found' -and $nameFallback.name -eq 'First Last') 'missing name falls back to first and surname'

    $emptyTransport = {
        param($Request)
        $script:transportCount++
        $script:lastRequest = $Request
        return [pscustomobject]@{ status_code = 200; body = '{"count":0,"page":1,"pages":1,"per_page":100,"results":[]}' }
    }
    $notFound = Invoke-RadioIdentityQuery -RadioId $unknownId -CachePath $cachePath -Transport $emptyTransport
    Assert-RadioIdentityTest ($notFound.status -eq 'not_found' -and $notFound.display_name -eq "DMR ID $unknownId") 'empty results produce a not-found fallback'
    Assert-RadioIdentityTest ((Resolve-RadioIdentity -RadioId $unknownId -CachePath $cachePath).status -eq 'not_found') 'fresh negative result is cached'

    $mismatchTransport = {
        param($Request)
        $script:transportCount++
        $script:lastRequest = $Request
        return [pscustomobject]@{ status_code = 200; body = '{"results":[{"id":7654999,"callsign":"N9OTHER"}]}' }
    }
    $mismatch = Invoke-RadioIdentityQuery -RadioId $mismatchId -CachePath $cachePath -Transport $mismatchTransport
    Assert-RadioIdentityTest ($mismatch.status -eq 'unavailable' -and $mismatch.callsign -eq $null) 'a result with a different ID is not accepted'

    $conflictTransport = {
        param($Request)
        $script:transportCount++
        $script:lastRequest = $Request
        return [pscustomobject]@{ status_code = 200; body = '{"results":[{"id":7654324,"callsign":"N4ONE"},{"id":7654324,"callsign":"N4OTHER"}]}' }
    }
    $conflict = Invoke-RadioIdentityQuery -RadioId $conflictId -CachePath $cachePath -Transport $conflictTransport
    Assert-RadioIdentityTest ($conflict.status -eq 'unavailable') 'conflicting duplicate results are unavailable'

    $oversizedTransport = {
        param($Request)
        $script:transportCount++
        $script:lastRequest = $Request
        return [pscustomobject]@{ status_code = 200; body = (' ' * 262145) }
    }
    $oversized = Invoke-RadioIdentityQuery -RadioId ([uint32]7654326) -CachePath $cachePath -Transport $oversizedTransport
    Assert-RadioIdentityTest ($oversized.status -eq 'unavailable') 'oversized response is rejected before parsing'

    $cachedBeforeFailure = Resolve-RadioIdentity -RadioId $validId -CachePath $cachePath
    $networkFailure = {
        param($Request)
        $script:transportCount++
        $script:lastRequest = $Request
        throw 'synthetic network failure'
    }
    $staleAfterFailure = Invoke-RadioIdentityQuery -RadioId $validId -CachePath $cachePath -TimeoutSec 2 -Transport $networkFailure
    Assert-RadioIdentityTest ($staleAfterFailure.status -eq 'stale' -and $staleAfterFailure.callsign -eq $cachedBeforeFailure.callsign) 'network failure returns cached identity as stale'
    Assert-RadioIdentityTest ((Resolve-RadioIdentity -RadioId $validId -CachePath $cachePath).status -eq 'found') 'network failure does not overwrite a still-fresh cache record'

    $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($cachePath, [Text.Encoding]::UTF8))
    $validEntry = @($doc.entries | Where-Object { [uint32]$_.id -eq $validId })[0]
    $validEntry.fetched_at_utc = [DateTimeOffset]::UtcNow.AddDays(-31).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $expiredJson = ConvertTo-Json -InputObject $doc -Depth 8
    [IO.File]::WriteAllText($cachePath, $expiredJson, (New-Object System.Text.UTF8Encoding($true)))
    $expired = Resolve-RadioIdentity -RadioId $validId -CachePath $cachePath
    Assert-RadioIdentityTest ($expired.status -eq 'stale' -and $expired.callsign -eq 'N0TEST') 'expired cache remains displayable with stale status'

    $unavailableWithoutCache = Invoke-RadioIdentityQuery -RadioId ([uint32]7654327) -CachePath (Join-Path $testRoot 'no-cache\radio-identity-cache.json') -Transport $networkFailure
    Assert-RadioIdentityTest ($unavailableWithoutCache.status -eq 'unavailable' -and $unavailableWithoutCache.display_name -eq 'DMR ID 7654327') 'network failure without cache falls back to numeric ID'

    $nonSuccessTransport = {
        param($Request)
        return [pscustomobject]@{ status_code = 503; body = '' }
    }
    $httpFailure = Invoke-RadioIdentityQuery -RadioId ([uint32]7654328) -CachePath $cachePath -Transport $nonSuccessTransport
    Assert-RadioIdentityTest ($httpFailure.status -eq 'unavailable') 'non-200 status is not treated as not-found'

    $radioIdentityModule = Get-Module RadioIdentity
    $localUserAgent = 'WIREX Bridge test (contact: https://github.com/iCassius)'
    $fixture = Start-RadioIdentityHttpFixture -Mode ok -Root $testRoot
    try {
        $httpRequest = [pscustomobject]@{
            uri = "http://127.0.0.1:$($fixture.port)/identity"
            timeout_milliseconds = 2000
            max_response_bytes = 1024
            user_agent = $localUserAgent
        }
        $httpResponse = & $radioIdentityModule { param($Request) Invoke-RadioIdentityHttpRequest -Request $Request } $httpRequest
        $httpJson = ConvertFrom-Json -InputObject $httpResponse.body -ErrorAction Stop
        Assert-RadioIdentityTest ($httpResponse.status_code -eq 200 -and $httpJson.results[0].callsign -eq 'N0TEST') 'default async transport reads a local 200 JSON response'
    } finally {
        Stop-RadioIdentityHttpFixture -Fixture $fixture
    }

    $fixture = Start-RadioIdentityHttpFixture -Mode status -Root $testRoot
    try {
        $httpRequest = [pscustomobject]@{
            uri = "http://127.0.0.1:$($fixture.port)/identity"
            timeout_milliseconds = 2000
            max_response_bytes = 1024
            user_agent = $localUserAgent
        }
        $httpResponse = & $radioIdentityModule { param($Request) Invoke-RadioIdentityHttpRequest -Request $Request } $httpRequest
        Assert-RadioIdentityTest ($httpResponse.status_code -eq 503) 'default async transport preserves non-200 status'
    } finally {
        Stop-RadioIdentityHttpFixture -Fixture $fixture
    }

    $fixture = Start-RadioIdentityHttpFixture -Mode oversized -Root $testRoot
    try {
        $httpRequest = [pscustomobject]@{
            uri = "http://127.0.0.1:$($fixture.port)/identity"
            timeout_milliseconds = 2000
            max_response_bytes = 16
            user_agent = $localUserAgent
        }
        Assert-RadioIdentityThrows { & $radioIdentityModule { param($Request) Invoke-RadioIdentityHttpRequest -Request $Request } $httpRequest } `
            'default async transport rejects an oversized Content-Length'
    } finally {
        Stop-RadioIdentityHttpFixture -Fixture $fixture
    }

    $fixture = Start-RadioIdentityHttpFixture -Mode oversized_chunked -Root $testRoot
    try {
        $httpRequest = [pscustomobject]@{
            uri = "http://127.0.0.1:$($fixture.port)/identity"
            timeout_milliseconds = 2000
            max_response_bytes = 16
            user_agent = $localUserAgent
        }
        Assert-RadioIdentityThrows { & $radioIdentityModule { param($Request) Invoke-RadioIdentityHttpRequest -Request $Request } $httpRequest } `
            'default async transport enforces the size limit while streaming chunked content'
    } finally {
        Stop-RadioIdentityHttpFixture -Fixture $fixture
    }

    $fixture = Start-RadioIdentityHttpFixture -Mode delay_headers -Root $testRoot
    try {
        $httpRequest = [pscustomobject]@{
            uri = "http://127.0.0.1:$($fixture.port)/identity"
            timeout_milliseconds = 250
            max_response_bytes = 1024
            user_agent = $localUserAgent
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Assert-RadioIdentityThrows { & $radioIdentityModule { param($Request) Invoke-RadioIdentityHttpRequest -Request $Request } $httpRequest } `
            'default async transport aborts when response headers exceed the total timeout'
        Assert-RadioIdentityTest ($timer.ElapsedMilliseconds -lt 1500) 'delayed headers finish within a bounded cancellation window'
    } finally {
        Stop-RadioIdentityHttpFixture -Fixture $fixture
    }

    $fixture = Start-RadioIdentityHttpFixture -Mode slow_body -Root $testRoot
    try {
        $httpRequest = [pscustomobject]@{
            uri = "http://127.0.0.1:$($fixture.port)/identity"
            timeout_milliseconds = 250
            max_response_bytes = 1024
            user_agent = $localUserAgent
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Assert-RadioIdentityThrows { & $radioIdentityModule { param($Request) Invoke-RadioIdentityHttpRequest -Request $Request } $httpRequest } `
            'default async transport times out a stalled response body'
        Assert-RadioIdentityTest ($timer.ElapsedMilliseconds -lt 1500) 'stalled body finishes within a bounded cancellation window'
    } finally {
        Stop-RadioIdentityHttpFixture -Fixture $fixture
    }

    $temporaryFiles = @(Get-ChildItem -LiteralPath $testRoot -Filter '.radio-identity-cache-*.*' -File -Recurse -ErrorAction SilentlyContinue)
    Assert-RadioIdentityTest ($temporaryFiles.Count -eq 0) 'atomic cache writes leave no temporary or backup files'

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $fullTarget = [IO.Path]::GetFullPath($testRoot)
    if (-not $fullTarget.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove test data outside the system temporary directory.'
    }
    Remove-Item -LiteralPath $fullTarget -Recurse -Force
    Write-Output "RadioIdentity offline tests passed: $script:assertionCount assertions; synthetic responses and 127.0.0.1 HTTP fixtures only; no BM or RadioID request."
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
} finally {
    Remove-Module -Name RadioIdentity -ErrorAction SilentlyContinue
}
