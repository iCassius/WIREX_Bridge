#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0

function Assert-BmManagementUi {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-BmManagementUiUtf8Bom {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-BmManagementUi ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        ("UTF-8 BOM missing from {0}" -f [System.IO.Path]::GetFileName($Path))
}

function New-BmManagementUiTestWindow {
    $window = New-Object System.Windows.Window
    [System.Windows.NameScope]::SetNameScope($window, (New-Object System.Windows.NameScope))
    $rootPanel = New-Object System.Windows.Controls.StackPanel
    $window.Content = $rootPanel

    $controls = [ordered]@{
        BmApiKeyPathBox = (New-Object System.Windows.Controls.TextBox)
        BrowseBmApiKeyButton = (New-Object System.Windows.Controls.Button)
        BmStaticGroupPanel = (New-Object System.Windows.Controls.Border)
        BmStaticGroupSourceValue = (New-Object System.Windows.Controls.TextBlock)
        BmStaticGroupsList = (New-Object System.Windows.Controls.ListBox)
        BmStaticGroupIdBox = (New-Object System.Windows.Controls.TextBox)
        BmStaticGroupSlotBox = (New-Object System.Windows.Controls.ComboBox)
        AddBmStaticGroupButton = (New-Object System.Windows.Controls.Button)
        RemoveBmStaticGroupButton = (New-Object System.Windows.Controls.Button)
        RefreshBmStaticGroupsButton = (New-Object System.Windows.Controls.Button)
        BmStaticGroupStatus = (New-Object System.Windows.Controls.TextBlock)
    }
    foreach ($entry in $controls.GetEnumerator()) {
        $window.RegisterName([string]$entry.Key, $entry.Value)
        [void]$rootPanel.Children.Add($entry.Value)
    }
    $slotOne = New-Object System.Windows.Controls.ComboBoxItem
    $slotOne.Content = 'TS1'; $slotOne.Tag = '1'
    $slotTwo = New-Object System.Windows.Controls.ComboBoxItem
    $slotTwo.Content = 'TS2'; $slotTwo.Tag = '2'
    [void]$controls.BmStaticGroupSlotBox.Items.Add($slotOne)
    [void]$controls.BmStaticGroupSlotBox.Items.Add($slotTwo)
    $controls.BmStaticGroupSlotBox.SelectedIndex = 1
    return $window
}

function Set-BmFakeResponses {
    param([Parameter()][AllowEmptyCollection()][object[]]$Responses = @())
    $state.requests.Clear()
    $state.seen_auths.Clear()
    $state.responses.Clear()
    foreach ($response in $Responses) { $state.responses.Enqueue($response) }
    $state.block_next = $false
    $state.blocking_started = $false
    $state.cancellation_observed = $false
}

function Wait-BmManagementUiIdle {
    param([Parameter()][ValidateRange(100,20000)][int]$TimeoutMs = 5000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($script:bmManagementOperationPowerShell -and [DateTime]::UtcNow -lt $deadline) {
        [void](Poll-BmManagementUi)
        Start-Sleep -Milliseconds 15
    }
    [void](Poll-BmManagementUi)
    if ($script:bmManagementOperationPowerShell) { throw 'Timed out waiting for the BM UI operation.' }
}

function Wait-BmManagementUiFakeRequest {
    param([Parameter()][ValidateRange(100,10000)][int]$TimeoutMs = 3000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while (-not $state.blocking_started -and [DateTime]::UtcNow -lt $deadline) {
        [void](Poll-BmManagementUi)
        Start-Sleep -Milliseconds 10
    }
    if (-not $state.blocking_started) { throw 'The fake transport did not enter its blocked request.' }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Net.Http -ErrorAction Stop
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw 'Run this WPF test with PowerShell -STA.'
}

$adapterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui\windows\BmManagementUi.ps1'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ui\windows\BmManagement.psm1'
Assert-BmManagementUiUtf8Bom -Path $PSCommandPath
Assert-BmManagementUiUtf8Bom -Path $adapterPath
$window = New-BmManagementUiTestWindow
$script:mainWindow = $window
$script:storedProfile = [pscustomobject]@{
    connection = [pscustomobject]@{ gateway_id = [uint64]461135501 }
}
$script:activeProfile = $null
$script:bmManagementModulePath = $modulePath
$script:bmManagementModuleAvailable = $true
$script:bmManagementPreferences = [pscustomobject][ordered]@{ schema_version = 1; api_key_file_path = '' }
$script:bmManagementPreferencesPath = Join-Path ([System.IO.Path]::GetTempPath()) 'bm-management-ui-test-prefs.json'
$script:bmManagementUiTransportRequired = $true

$state = [pscustomobject]@{
    requests = New-Object 'System.Collections.Generic.List[object]'
    seen_auths = New-Object 'System.Collections.Generic.List[string]'
    responses = New-Object 'System.Collections.Generic.Queue[object]'
    block_next = $false
    blocking_started = $false
    cancellation_observed = $false
}
$script:bmManagementUiTransportOverride = {
    param($Request)
    $state.requests.Add($Request)
    $state.seen_auths.Add([string]$Request.headers.Authorization)
    if ($state.block_next) {
        $state.block_next = $false
        $state.blocking_started = $true
        while (-not $Request.cancellation_token.IsCancellationRequested) { Start-Sleep -Milliseconds 10 }
        $state.cancellation_observed = $true
        throw [System.OperationCanceledException]::new('synthetic cancellation')
    }
    if ($state.responses.Count -eq 0) { throw [System.TimeoutException]::new('synthetic timeout') }
    $response = $state.responses.Dequeue()
    if ($response -is [System.Exception]) { throw $response }
    return $response
}.GetNewClosure()

function Save-BmManagementPreferences {
    param([string]$Path, [string]$ApiKeyFilePath)
    $script:bmManagementPreferences.api_key_file_path = [string]$ApiKeyFilePath
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDirectory = Join-Path $tempRoot ('bm-management-ui-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDirectory
$keyPath = Join-Path $tempDirectory 'synthetic-api-key.txt'
$fakeToken = ('a' * 100) + '.' + ('b' * 100) + '.' + ('c' * 100)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($keyPath, $fakeToken, $utf8NoBom)

try {
    . $adapterPath
    Initialize-BmManagementUi -Window $window
    Assert-BmManagementUi ($window.FindName('BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Collapsed) 'empty API-key preference must keep the static panel hidden'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Collapsed) 'no-key initialization must hide the static list'
    Assert-BmManagementUi ($window.FindName('AddBmStaticGroupButton').Visibility -eq [System.Windows.Visibility]::Collapsed) 'no-key initialization must hide write controls'
    Assert-BmManagementUi ($state.requests.Count -eq 0) 'no-key initialization must make no API request'

    $window.FindName('BmApiKeyPathBox').Text = $keyPath
    [void](Save-BmManagementUiPathPreference -Path $keyPath)
    Set-BmFakeResponses @([pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[]}' })
    Assert-BmManagementUi (Request-BmManagementUiRefresh) 'configured API path should start a GET'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 1 -and $state.requests[0].method -ceq 'GET') 'configured path should issue exactly one GET'
    Assert-BmManagementUi ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/profile') 'UI GET should use the frozen profile gateway ID'
    $authObserved = [string]$state.seen_auths[0]
    Assert-BmManagementUi ($authObserved -ceq ('Bearer ' + $fakeToken)) ("fake auth header should be exact (length={0}, bearer={1}, exact={2})" -f $authObserved.Length, $authObserved.StartsWith('Bearer '), ($authObserved -ceq ('Bearer ' + $fakeToken)))
    Assert-BmManagementUi ($window.FindName('BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'a successful GET should expose the BM static panel'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Visible) 'an empty successful GET should show an empty list'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 0) 'an empty GET should remain a real empty list'
    Assert-BmManagementUi ($window.FindName('AddBmStaticGroupButton').Visibility -eq [System.Windows.Visibility]::Visible) 'a successful GET should expose Add'
    Assert-BmManagementUi ($script:bmManagementStatus -ceq 'loaded' -and $script:bmManagementGroups.Count -eq 0) 'empty server list should be represented as loaded and empty'
    $preferenceJson = ConvertTo-Json -InputObject $script:bmManagementPreferences -Compress
    Assert-BmManagementUi (-not $preferenceJson.Contains($fakeToken) -and -not $window.FindName('BmStaticGroupStatus').Text.Contains($fakeToken)) 'the synthetic token must not enter preferences or UI status'

    $window.FindName('BmStaticGroupIdBox').Text = '12345'
    $window.FindName('BmStaticGroupSlotBox').SelectedIndex = 0
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 201; body = '' },
        [pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[{"talkgroup":12345,"slot":1}]}' }
    )
    Assert-BmManagementUi (Start-BmManagementUiRequest -Operation Add) 'Add should start only after a successful current-device GET'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'POST' -and $state.requests[1].method -ceq 'GET') 'Add should issue one POST followed by one readback GET'
    $addBody = ConvertFrom-Json -InputObject $state.requests[0].body
    Assert-BmManagementUi ([uint64]$addBody.group -eq 12345 -and [int]$addBody.slot -eq 1) 'Add should send only the selected TG and timeslot'
    Assert-BmManagementUi ($script:bmManagementLastWriteAccepted -and $script:bmManagementLastReadbackStatus -ceq 'confirmed') 'Add should record confirmed write and readback'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 1 -and $window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 12345 · TS1') 'Add should display only the group returned by BM'

    $window.FindName('BmStaticGroupsList').SelectedIndex = 0
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 204; body = '' },
        [pscustomobject]@{ status_code = 200; body = '{"staticSubscriptions":[]}' }
    )
    Assert-BmManagementUi (Start-BmManagementUiRequest -Operation Remove) 'Remove should start for a selected current-device static group'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'DELETE' -and $state.requests[1].method -ceq 'GET') 'Remove should issue one DELETE followed by one readback GET'
    Assert-BmManagementUi ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/talkgroup/1/12345') 'Remove should target the selected TS and TG'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 0 -and $script:bmManagementLastReadbackStatus -ceq 'confirmed') 'confirmed Remove should display the empty BM list'

    $window.FindName('BmStaticGroupIdBox').Text = '23456'
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 201; body = '' },
        [System.TimeoutException]::new('synthetic readback timeout')
    )
    Assert-BmManagementUi (Start-BmManagementUiRequest -Operation Add) 'Add should start for a valid TG and TS'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'POST') 'an unconfirmed Add must not retry its POST'
    Assert-BmManagementUi ($script:bmManagementLastWriteAccepted -and $script:bmManagementLastReadbackStatus -ceq 'unavailable') 'accepted but unreadable Add must retain the unconfirmed state'
    Assert-BmManagementUi ($script:bmManagementGroups.Count -eq 0 -and $window.FindName('BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Collapsed) 'unconfirmed readback must not create a fictional list row'

    $state.block_next = $true
    Assert-BmManagementUi (Request-BmManagementUiRefresh) 'refresh should start before disposal test'
    Wait-BmManagementUiFakeRequest
    Assert-BmManagementUi (-not (Dispose-BmManagementUi)) 'Dispose should report pending cleanup while a request is running'
    Assert-BmManagementUi ($script:bmManagementCancellationSource.IsCancellationRequested) 'Dispose should cancel the active operation token'
    $disposeDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Poll-BmManagementUi) -and [DateTime]::UtcNow -lt $disposeDeadline) { Start-Sleep -Milliseconds 10 }
    Assert-BmManagementUi $script:bmManagementUiDisposed 'Poll should finish disposal after cancellation'
    Assert-BmManagementUi ($null -eq $script:bmManagementOperationPowerShell -and $null -eq $script:bmManagementOperationRunspace -and $null -eq $script:bmManagementCancellationSource) 'Dispose should release the PowerShell, runspace, and cancellation resources'
    Assert-BmManagementUi ($state.cancellation_observed) 'fake transport should observe cancellation'

    Write-Output ("PASS: test-bm-management-ui.ps1 ({0} assertions; WPF STA; PowerShell {1})" -f $script:assertionCount, $PSVersionTable.PSVersion)
} finally {
    try { $window.Close() } catch { }
    if ([System.IO.Path]::GetFullPath($tempDirectory).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($tempDirectory).StartsWith('bm-management-ui-', [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
