#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0

function Assert-BmManagement {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Utf8Bom {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-BmManagement -Condition ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        -Message ("UTF-8 BOM missing from {0}" -f [System.IO.Path]::GetFileName($Path))
}

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui\windows\BmManagement.psm1'
Assert-Utf8Bom -Path $PSCommandPath
Assert-Utf8Bom -Path $modulePath
Import-Module $modulePath -Force -ErrorAction Stop

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('bm-management-fake-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDirectory
$apiKeyFile = Join-Path $tempDirectory 'fake-api-key.txt'
$fakeToken = ('a' * 100) + '.' + ('b' * 100) + '.' + ('c' * 100)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($apiKeyFile, $fakeToken, $utf8NoBom)

$state = [pscustomobject]@{
    requests = New-Object 'System.Collections.Generic.List[object]'
    seen_auths = New-Object 'System.Collections.Generic.List[string]'
    responses = New-Object 'System.Collections.Generic.Queue[object]'
}
$transport = {
    param($Request)
    $state.requests.Add($Request)
    $state.seen_auths.Add([string]$Request.headers.Authorization)
    $next = $state.responses.Dequeue()
    if ($next -is [System.Exception]) { throw $next }
    return $next
}.GetNewClosure()

function Set-FakeResponseSequence {
    param([Parameter(Mandatory = $true)][object[]]$Responses)
    $state.responses.Clear()
    $state.requests.Clear()
    $state.seen_auths.Clear()
    foreach ($response in $Responses) { $state.responses.Enqueue($response) }
}

try {
    $profileJson = '{"staticSubscriptions":[{"talkgroup":91,"slot":2},{"talkgroup":46001,"slot":1}],"dynamicSubscriptions":[{"talkgroup":3100,"slot":2}],"displayName":"must not be returned"}'
    Set-FakeResponseSequence @([pscustomobject]@{ status_code = 200; body = $profileJson })
    $read = Get-BmStaticGroups -ApiKey $fakeToken -DeviceId '461135501' -TimeoutMs 2500 -Transport $transport
    Assert-BmManagement ($read.operation -ceq 'get_static_groups' -and $read.success) 'GET should report a successful static list operation'
    Assert-BmManagement ($read.groups.Count -eq 2) 'GET should return only static subscriptions'
    Assert-BmManagement ([uint64]$read.groups[0].talkgroup -eq 91 -and [int]$read.groups[0].slot -eq 2) 'GET should preserve TG and slot'
    Assert-BmManagement ($read.groups[0].type -ceq 'static' -and $read.groups[0].device_id -ceq '461135501') 'GET should label remote static records and device ID'
    Assert-BmManagement ($state.requests.Count -eq 1) 'GET should issue one request'
    Assert-BmManagement ($state.requests[0].method -ceq 'GET') 'static list should use GET'
    Assert-BmManagement ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/profile') 'GET must target the fixed official v2 profile endpoint'
    $observedAuthorization = [string]$state.seen_auths[0]
    $authorizationIsExpected = ($observedAuthorization -ceq ('Bearer ' + $fakeToken))
    Assert-BmManagement $authorizationIsExpected ("only the explicit token should become Bearer authorization (length={0}, starts_bearer={1}, exact={2})" -f $observedAuthorization.Length, $observedAuthorization.StartsWith('Bearer '), $authorizationIsExpected)
    Assert-BmManagement ($state.requests[0].timeout_ms -eq 2500) 'caller timeout should reach the transport'
    $readJson = ConvertTo-Json -InputObject $read -Depth 8 -Compress
    Assert-BmManagement (-not $readJson.Contains($fakeToken) -and -not $readJson.Contains('must not be returned')) 'GET result must not expose token or unrelated BM profile fields'

    $state.requests.Clear()
    $afterAddJson = '{"staticSubscriptions":[{"talkgroup":91,"slot":2},{"talkgroup":12345,"slot":1}],"dynamicSubscriptions":[]}'
    Set-FakeResponseSequence @(
        [pscustomobject]@{ status_code = 201; body = '' },
        [pscustomobject]@{ status_code = 200; body = $afterAddJson }
    )
    $add = Add-BmStaticGroup -ApiKey $fakeToken -DeviceId '461135501' -Talkgroup 12345 -Slot 1 -Transport $transport
    Assert-BmManagement ($add.write_accepted -and $add.readback_status -ceq 'confirmed') 'POST should be followed by a confirming GET'
    Assert-BmManagement ($add.operation -ceq 'add_static_group' -and [uint64]$add.talkgroup -eq 12345 -and [int]$add.slot -eq 1) 'add result should identify exact operation and target'
    Assert-BmManagement ($state.requests.Count -eq 2) 'add should make one POST and one readback GET'
    Assert-BmManagement ($state.requests[0].method -ceq 'POST' -and $state.requests[1].method -ceq 'GET') 'add request order should be POST then GET'
    Assert-BmManagement ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/talkgroup') 'add must target the fixed official talkgroup endpoint'
    $addBody = ConvertFrom-Json -InputObject $state.requests[0].body
    Assert-BmManagement ([int]$addBody.slot -eq 1 -and [uint64]$addBody.group -eq 12345) 'POST body should contain only slot and group'
    $addJson = ConvertTo-Json -InputObject $add -Depth 8 -Compress
    Assert-BmManagement (-not $addJson.Contains($fakeToken)) 'write result must not expose the token'

    $state.requests.Clear()
    Set-FakeResponseSequence @(
        [pscustomobject]@{ status_code = 204; body = '' },
        [pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[]}' }
    )
    $remove = Remove-BmStaticGroup -ApiKey $fakeToken -DeviceId '461135501' -Talkgroup 91 -Slot 2 -Transport $transport
    Assert-BmManagement ($remove.write_accepted -and $remove.readback_status -ceq 'confirmed') 'DELETE should be followed by a confirming GET'
    Assert-BmManagement ($state.requests[0].method -ceq 'DELETE') 'remove should use DELETE'
    Assert-BmManagement ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/talkgroup/2/91') 'remove URI should include slot and talkgroup'

    $state.requests.Clear()
    Set-FakeResponseSequence @(
        [pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[{"talkgroup":91,"slot":0}]}' }
    )
    $simplex = Get-BmStaticGroups -ApiKey $fakeToken -DeviceId '461135501' -Transport $transport
    Assert-BmManagement ([int]$simplex.groups[0].slot -eq 0) 'GET should preserve slot 0 from a simplex device for display and removal'

    $state.requests.Clear()
    Set-FakeResponseSequence @(
        [pscustomobject]@{ status_code = 201; body = '' },
        [System.TimeoutException]::new('fake timeout')
    )
    $acceptedUnconfirmed = Add-BmStaticGroup -ApiKey $fakeToken -DeviceId '461135501' -Talkgroup 23456 -Slot 2 -Transport $transport
    Assert-BmManagement ($acceptedUnconfirmed.write_accepted -and $acceptedUnconfirmed.readback_status -ceq 'unavailable') 'successful write with failed readback must stay accepted but unconfirmed'
    Assert-BmManagement ($acceptedUnconfirmed.readback_error -ceq 'timeout') 'readback timeout should be reported without repeating the write'
    Assert-BmManagement ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'POST') 'readback timeout must not retry the write'

    Set-FakeResponseSequence @([System.OperationCanceledException]::new('synthetic canceled write'))
    $writeOutcomeUnknown = $false
    try { [void](Add-BmStaticGroup -ApiKey $fakeToken -DeviceId '461135501' -Talkgroup 34567 -Slot 2 -Transport $transport) }
    catch [System.OperationCanceledException] { $writeOutcomeUnknown = $true }
    Assert-BmManagement $writeOutcomeUnknown 'canceled write should surface as an unresolved operation'
    Assert-BmManagement ($state.requests.Count -eq 1 -and $state.requests[0].method -ceq 'POST') 'canceled write must not trigger readback or an automatic retry'

    $state.requests.Clear()
    $cancelSource = New-Object System.Threading.CancellationTokenSource
    $cancelSource.Cancel()
    $canceled = $false
    try { [void](Get-BmStaticGroups -ApiKey $fakeToken -DeviceId '461135501' -CancellationToken $cancelSource.Token -Transport $transport) }
    catch [System.OperationCanceledException] { $canceled = $true }
    finally { $cancelSource.Dispose() }
    Assert-BmManagement $canceled 'pre-canceled GET should stop before transport'
    Assert-BmManagement ($state.requests.Count -eq 0) 'pre-canceled GET should make no request'

    $badProfileRejected = $false
    Set-FakeResponseSequence @([pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[{"talkgroup":"<script>","slot":2}]}' })
    try { [void](Get-BmStaticGroups -ApiKey $fakeToken -DeviceId '461135501' -Transport $transport) }
    catch { $badProfileRejected = $true }
    Assert-BmManagement $badProfileRejected 'malformed TG values must be rejected'

    $state.requests.Clear()
    $invalidDeviceRejected = $false
    try { [void](Get-BmStaticGroups -ApiKey $fakeToken -DeviceId '461135501/elsewhere' -Transport $transport) }
    catch { $invalidDeviceRejected = $true }
    Assert-BmManagement $invalidDeviceRejected 'device id must not inject an alternate API path'
    Assert-BmManagement ($state.requests.Count -eq 0) 'invalid device id must be rejected before transport'

    $state.requests.Clear()
    $invalidSlotRejected = $false
    try { [void](Add-BmStaticGroup -ApiKey $fakeToken -DeviceId '461135501' -Talkgroup 91 -Slot 0 -Transport $transport) }
    catch { $invalidSlotRejected = $true }
    Assert-BmManagement $invalidSlotRejected 'add must accept only TS1 or TS2'
    Assert-BmManagement ($state.requests.Count -eq 0) 'invalid add slot must not reach transport'

    $iniKeyFile = Join-Path $tempDirectory 'pistar-style-api-key.ini'
    [System.IO.File]::WriteAllText($iniKeyFile, "[key]`napikey=$fakeToken`n", $utf8NoBom)
    $state.requests.Clear()
    Set-FakeResponseSequence @([pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[]}' })
    [void](Get-BmStaticGroups -ApiKeyFilePath $iniKeyFile -DeviceId '461135501' -Transport $transport)
    Assert-BmManagement ($state.seen_auths[0] -ceq ('Bearer ' + $fakeToken)) 'Pi-Star-style key file should be accepted without changing profile data'

    $invalidKeyFile = Join-Path $tempDirectory 'invalid-api-key.txt'
    [System.IO.File]::WriteAllText($invalidKeyFile, 'synthetic-invalid-token-content', $utf8NoBom)
    $state.requests.Clear()
    $invalidKeyRejected = $false
    try { [void](Get-BmStaticGroups -ApiKeyFilePath $invalidKeyFile -DeviceId '461135501' -Transport $transport) }
    catch { $invalidKeyRejected = $true; Assert-BmManagement (-not $_.Exception.Message.Contains('synthetic-invalid-token-content')) 'API key errors must not echo file contents' }
    Assert-BmManagement $invalidKeyRejected 'invalid API key file should be rejected'
    Assert-BmManagement ($state.requests.Count -eq 0) 'invalid API key should not reach the transport'

    $state.requests.Clear()
    $ambiguousSourceRejected = $false
    try { [void](Get-BmStaticGroups -ApiKey $fakeToken -ApiKeyFilePath $apiKeyFile -DeviceId '461135501' -Transport $transport) }
    catch { $ambiguousSourceRejected = $true; Assert-BmManagement (-not $_.Exception.Message.Contains($fakeToken)) 'key source errors must not echo the token' }
    Assert-BmManagement $ambiguousSourceRejected 'direct key and compatibility file path must not be accepted together'
    Assert-BmManagement ($state.requests.Count -eq 0) 'ambiguous key source must be rejected before transport'

    $invalidDirectKey = 'synthetic-invalid-direct-key'
    $invalidDirectRejected = $false
    try { [void](Get-BmStaticGroups -ApiKey $invalidDirectKey -DeviceId '461135501' -Transport $transport) }
    catch { $invalidDirectRejected = $true; Assert-BmManagement (-not $_.Exception.Message.Contains($invalidDirectKey)) 'direct key validation errors must not echo the key' }
    Assert-BmManagement $invalidDirectRejected 'invalid direct API key should be rejected'
    Assert-BmManagement ($state.requests.Count -eq 0) 'invalid direct API key should not reach transport'

    Write-Output ("PASS: test-bm-management.ps1 ({0} assertions; PowerShell {1})" -f $script:assertionCount, $PSVersionTable.PSVersion)
} finally {
    if (Test-Path -LiteralPath $tempDirectory) { Remove-Item -LiteralPath $tempDirectory -Recurse -Force }
}
