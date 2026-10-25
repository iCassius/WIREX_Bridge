[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$assertions = 0
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'publish-release.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $script:assertions++
    $didThrow = $false
    try { & $Action } catch { $didThrow = $true }
    if (-not $didThrow) { throw ('Expected rejection: ' + $Message) }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$testRoot = Join-Path $repositoryRoot ('build/_work/publish-release-test-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $testRoot 'package'
$fakeCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$fixtureBytes = New-Object byte[] 100
$fixtureHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($fixtureBytes))).Replace('-', '').ToLowerInvariant()
$script:approvedFixtureSha256 = $fixtureHash

try {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($directory in $script:expectedDirectories) {
        New-Item -ItemType Directory -Path (Join-Path $packageRoot $directory.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) -Force | Out-Null
    }

    $records = @()
    foreach ($path in $script:assetPathMap.Keys) {
        $fullPath = Join-Path $packageRoot $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if ($path -ceq 'private/device-y.bin') {
            [System.IO.File]::WriteAllBytes($fullPath, $fixtureBytes)
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic package content: ' + $path)
        }
        $item = Get-Item -LiteralPath $fullPath
        $records += ,([ordered]@{
            path = $path
            asset_name = (Get-PublishAssetName -RelativePath $path)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $manifest = [ordered]@{
        schema_version = 1
        package_kind = 'wirex_bridge_private_alpha_release_green_directory'
        package_status = 'root_audit_passed'
        version = 'v0.1.0-alpha.1'
        tag_candidate = 'v0.1.0-alpha.1'
        manifest_asset_name = 'manifest.json'
        source = [ordered]@{
            repository = $script:repositoryUrl
            commit = $fakeCommit
            working_tree_clean = $true
        }
        build = [ordered]@{
            source_commit = $fakeCommit
            source_tree_clean = $true
            compile_only = $false
            build_completed = $true
            result = 'passed'
        }
        approved_y_fixture = [ordered]@{
            path = 'private/device-y.bin'
            length_bytes = 100
            sha256 = $fixtureHash
        }
        files = $records
    }
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")

    $valid = Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit
    Assert-True ($valid.Assets.Count -eq 17) '16 package files plus standalone manifest are accepted'
    Assert-True (@($valid.Assets | Where-Object { $_.Name -ceq 'manifest.json' }).Count -eq 1) 'manifest is a separate release asset'
    Assert-True ((Get-PublishAssetName -RelativePath 'docs/连接配置.md') -ceq 'docs__connection-profile.md') 'PowerShell reads the Chinese connection-profile path correctly'
    Assert-True ((Get-PublishAssetName -RelativePath 'docs/音量调节.md') -ceq 'docs__audio-gain.md') 'PowerShell reads the Chinese audio-settings path correctly'

    $realTagObject = 'refs/tags/v0.1.0-alpha.1^{commit}'
    $realTagCommit = Get-GitText -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', '--verify', $realTagObject)
    $realNotesPath = Join-Path $repositoryRoot 'docs/releases/v0.1.0-alpha.1.md'
    $realNotes = Get-PublishNotes -Path $realNotesPath -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit
    Assert-True (-not [string]::IsNullOrWhiteSpace($realNotes)) 'fixed release notes match both the real tag commit and current HEAD'
    Assert-Throws { Get-PublishNotes -Path (Join-Path $repositoryRoot 'README.md') -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit } 'non-release notes path is rejected'

    $manifest.package_status = 'awaiting_root_audit'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'unapproved package status'
    $manifest.package_status = 'root_audit_passed'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")

    $readmePath = Join-Path $packageRoot 'README.md'
    $goodReadme = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $readmePath -Text 'tampered bytes'
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'file hash mismatch'
    Write-Utf8NoBom -Path $readmePath -Text $goodReadme

    $extraPath = Join-Path $packageRoot 'connection-profile.json'
    Write-Utf8NoBom -Path $extraPath -Text '{}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'unexpected private configuration file'
    Remove-Item -LiteralPath $extraPath -Force

    $record = @($manifest.files | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })[0]
    $record.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'duplicate asset name'

    $unknown = New-UnknownOutcomeError
    Assert-True (Test-UnknownOutcomeError -Exception $unknown) 'mutation recovery recognizes unknown outcomes'
    Assert-True (-not (Test-UnknownOutcomeError -Exception (New-Object System.Exception('known failure')))) 'known API failures are not treated as unknown outcomes'

    $streamBytes = [System.Text.Encoding]::UTF8.GetBytes('synthetic release asset')
    $streamHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($streamBytes))).Replace('-', '').ToLowerInvariant()
    $memoryStream = [System.IO.MemoryStream]::new($streamBytes)
    try { Assert-True ((Get-StreamSha256 -Stream $memoryStream -ExpectedLength $streamBytes.Length) -ceq $streamHash) 'asset stream hash and byte count match' }
    finally { $memoryStream.Dispose() }
    $shortStream = [System.IO.MemoryStream]::new($streamBytes)
    try { Assert-Throws { Get-StreamSha256 -Stream $shortStream -ExpectedLength ($streamBytes.Length - 1) } 'oversized asset stream is rejected' }
    finally { $shortStream.Dispose() }
    $localAsset = [pscustomobject]@{ Name='one.bin'; Length=$streamBytes.Length; Sha256=$streamHash }
    $remoteAsset = [pscustomobject]@{ name='one.bin'; size=$streamBytes.Length; digest=('sha256:' + $streamHash) }
    Assert-True (Test-RemoteAssetMatches -RemoteAsset $remoteAsset -LocalAsset $localAsset) 'GitHub SHA-256 digest matches local asset'
    $remoteAsset.digest = 'sha256:' + ('0' * 64)
    Assert-True (-not (Test-RemoteAssetMatches -RemoteAsset $remoteAsset -LocalAsset $localAsset)) 'different GitHub SHA-256 digest is rejected'
    $remoteAsset.digest = 'sha256:' + $streamHash
    $expectedRemote = @([pscustomobject]@{ Name='one.bin' }, [pscustomobject]@{ Name='two.bin' })
    $actualRemote = @([pscustomobject]@{ name='one.bin' }, [pscustomobject]@{ name='two.bin' })
    Assert-True ((Assert-ExactRemoteAssetNames -RemoteAssets $actualRemote -ExpectedAssets $expectedRemote) -eq $null) 'fixed remote asset inventory is accepted'
    Assert-Throws { Assert-ExactRemoteAssetNames -RemoteAssets ($actualRemote + [pscustomobject]@{ name='extra.bin' }) -ExpectedAssets $expectedRemote } 'extra remote asset is rejected'

    $httpClients = New-PublishHttpClients
    try {
        Assert-True ($httpClients.Authenticated -is [System.Net.Http.HttpClient]) 'HTTP client construction works without using a network'
        Assert-True ($null -eq $httpClients.Authenticated.DefaultRequestHeaders.Authorization) 'HTTP client has no credential before runtime initialization'
    } finally {
        $httpClients.Authenticated.Dispose()
        $httpClients.Anonymous.Dispose()
    }
    foreach ($cdnHost in @('release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com')) {
        Assert-True (Test-AllowedReleaseAssetHost -HostName $cdnHost) "known GitHub asset host is accepted: $cdnHost"
    }
    Assert-True (-not (Test-AllowedReleaseAssetHost -HostName 'other.githubusercontent.com')) 'unlisted githubusercontent.com host is rejected'

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'publish-release.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) 'publisher script parses without errors'

    $mockDraft = [pscustomobject]@{
        id = 77
        tag_name = 'v0.1.0-alpha.1'
        target_commitish = $fakeCommit
        body = "release notes`n"
        draft = $true
        prerelease = $true
    }
    $script:mockReleases = @($mockDraft)
    $script:mockCalls = New-Object System.Collections.ArrayList
    function Send-GitHubRequest {
        param([string]$Method, [string]$Uri, [System.Net.Http.HttpContent]$Content=$null, [switch]$AllowNotFound)
        [void]$script:mockCalls.Add([pscustomobject]@{ Method=$Method; Uri=$Uri })
        if ($Method -ceq 'GET' -and $Uri.Contains('/releases/tags/')) { return [pscustomobject]@{ Status=404; Data=$null } }
        if ($Method -ceq 'GET' -and $Uri.Contains('/releases?per_page=')) { return [pscustomobject]@{ Status=200; Data=@($script:mockReleases) } }
        if ($Method -ceq 'POST' -and $Uri.EndsWith('/releases')) { throw (New-UnknownOutcomeError) }
        throw 'Unexpected mocked request.'
    }
    $recovered = New-DraftRelease -ExpectedCommit $fakeCommit -Notes "release notes`n"
    Assert-True ([long]$recovered.id -eq 77) 'by-tag 404 falls back to the release list and recovers the existing draft'
    Assert-True (@($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count -eq 1) 'unknown POST is not repeated after recovering the draft'
    $script:mockReleases = @($mockDraft, $mockDraft)
    Assert-Throws { Get-ReleaseByTag } 'multiple exact-tag entries in release list are rejected'
    $inconsistentDraft = [pscustomobject]@{
        id = 78
        tag_name = 'v0.1.0-alpha.1'
        target_commitish = ('b' * 40)
        body = "release notes`n"
        draft = $true
        prerelease = $true
    }
    $script:mockReleases = @($inconsistentDraft)
    $postsBeforeMismatch = @($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count
    Assert-Throws { New-DraftRelease -ExpectedCommit $fakeCommit -Notes "release notes`n" } 'inconsistent draft recovered after unknown POST is rejected'
    Assert-True (@($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count -eq ($postsBeforeMismatch + 1)) 'inconsistent recovery does not cause a second POST'
    Assert-True ((Get-PublishReleaseAction -Release $mockDraft -ExpectedCommit $fakeCommit -Notes "release notes`n") -ceq 'publish') 'matching draft is eligible for the single publish patch'
    $alreadyPublished = $mockDraft | Select-Object *
    $alreadyPublished.draft = $false
    Assert-True ((Get-PublishReleaseAction -Release $alreadyPublished -ExpectedCommit $fakeCommit -Notes "release notes`n") -ceq 'already-published') 'matching published prerelease is an idempotent completion'
    $alreadyPublished.prerelease = $false
    Assert-Throws { Get-PublishReleaseAction -Release $alreadyPublished -ExpectedCommit $fakeCommit -Notes "release notes`n" } 'stable release is rejected'
    foreach ($badMode in @('draft', 'PUBLISH', 'DrAfT')) {
        $modeError = ''
        try {
            Invoke-ReleasePublisher -PackagePath '' -Commit $fakeCommit -NotesFile '' -PublisherMode $badMode -RepositoryRoot ''
        } catch { $modeError = $_.Exception.Message }
        Assert-True ($modeError -ceq 'Only the fixed private alpha release is supported.') "mode spelling '$badMode' is rejected before local validation or credentials"
    }
    Assert-True ($script:mockCalls.Count -eq 8) 'invalid mode spellings do not issue mocked GitHub requests'

    $script:approvedFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
    $realPackage = Join-Path $repositoryRoot 'build/releases/v0.1.0-alpha.1'
    $realManifestPath = Join-Path $realPackage 'manifest.json'
    if (Test-Path -LiteralPath $realManifestPath -PathType Leaf) {
        $realManifestHash = (Get-FileHash -LiteralPath $realManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($realManifestHash -cne '21d2e617f7761b6cc28a467432fb4c9d50d7c5ecafe2c1524afb8f9562fab9f5') {
            throw 'The locally present release package is not the reviewed package for the offline preflight check.'
        }
        $realTagCommit = Get-GitText -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', '--verify', 'refs/tags/v0.1.0-alpha.1^{commit}')
        $helperTempBefore = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'build/_work') -Filter 'publish-helper-*.bin' -File -ErrorAction SilentlyContinue).Count
        $script:preflightBoundaryReached = $false
        $script:credentialAttempted = $false
        function Initialize-GitHubClient {
            $script:preflightBoundaryReached = $true
            throw 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY'
        }
        function Get-GitCredentialToken {
            $script:credentialAttempted = $true
            throw 'OFFLINE_TEST_CREDENTIAL_ACCESS_BLOCKED'
        }
        $boundaryMessage = ''
        try {
            Invoke-ReleasePublisher -PackagePath $realPackage -Commit $realTagCommit `
                -NotesFile (Join-Path $repositoryRoot 'docs/releases/v0.1.0-alpha.1.md') `
                -PublisherMode 'Draft' -RepositoryRoot $repositoryRoot
        } catch { $boundaryMessage = $_.Exception.Message }
        $helperTempAfter = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'build/_work') -Filter 'publish-helper-*.bin' -File -ErrorAction SilentlyContinue).Count
        Assert-True ($script:preflightBoundaryReached -and $boundaryMessage -ceq 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY') ('real package, tag helper blob, notes and HEAD preflight reach the mocked network boundary; local result=' + $boundaryMessage)
        Assert-True (-not $script:credentialAttempted -and $script:mockCalls.Count -eq 8) 'real-package preflight stops before credentials and API requests'
        Assert-True ($helperTempAfter -eq $helperTempBefore) 'temporary byte-exact helper blob is removed after the offline boundary stop'
    }

    Write-Output ('Publisher offline assertions passed: ' + $script:assertions + '; no network requests or credentials were used.')
} finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PublishPathWithin -Path $testRoot -Directory (Join-Path $repositoryRoot 'build/_work')) -and
        [System.IO.Path]::GetFileName($testRoot) -match '^publish-release-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
