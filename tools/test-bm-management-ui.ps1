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
        BmApiKeyBox = (New-Object System.Windows.Controls.PasswordBox)
        BmStaticGroupPanel = (New-Object System.Windows.Controls.Border)
        BmStaticGroupSourceValue = (New-Object System.Windows.Controls.TextBlock)
        BmStaticGroupsList = (New-Object System.Windows.Controls.ListBox)
        BmStaticGroupPagePreviousButton = (New-Object System.Windows.Controls.Button)
        BmStaticGroupPageText = (New-Object System.Windows.Controls.TextBlock)
        BmStaticGroupPageNextButton = (New-Object System.Windows.Controls.Button)
        BmStaticGroupIdBox = (New-Object System.Windows.Controls.TextBox)
        AddBmStaticGroupButton = (New-Object System.Windows.Controls.Button)
        RemoveBmStaticGroupButton = (New-Object System.Windows.Controls.Button)
        RefreshBmStaticGroupsButton = (New-Object System.Windows.Controls.Button)
        BmStaticGroupStatus = (New-Object System.Windows.Controls.TextBlock)
    }
    foreach ($entry in $controls.GetEnumerator()) {
        $window.RegisterName([string]$entry.Key, $entry.Value)
        [void]$rootPanel.Children.Add($entry.Value)
    }
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

function Invoke-BmManagementUiButtonClick {
    param([Parameter(Mandatory = $true)][string]$Name)
    $button = $window.FindName($Name)
    $routedArgs = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$button)
    $button.RaiseEvent($routedArgs)
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
$script:portableConfig = [pscustomobject][ordered]@{ connection = [pscustomobject][ordered]@{ api_key = '' } }
$script:portableConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) 'bm-management-ui-test-config.json'
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

function Save-WirexPortableConfig {
    param([string]$Path, [object]$Config)
    return $Config
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDirectory = Join-Path $tempRoot ('bm-management-ui-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDirectory
$fakeToken = ('a' * 100) + '.' + ('b' * 100) + '.' + ('c' * 100)

try {
    . $adapterPath
    Initialize-BmManagementUi -Window $window
    Assert-BmManagementUi ($window.FindName('BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Collapsed) 'empty API-key preference must keep the static panel hidden'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Collapsed) 'no-key initialization must hide the static list'
    Assert-BmManagementUi ($window.FindName('AddBmStaticGroupButton').Visibility -eq [System.Windows.Visibility]::Collapsed) 'no-key initialization must hide write controls'
    Assert-BmManagementUi ($state.requests.Count -eq 0) 'no-key initialization must make no API request'

    $window.FindName('BmApiKeyBox').Password = $fakeToken
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 200; body = '[]' },
        [pscustomobject]@{ status_code = 200; body = '{"id":461135501,"status":4}' }
    )
    Assert-BmManagementUi (Request-BmManagementUiRefresh) 'configured API path should start a GET'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'GET' -and $state.requests[1].method -ceq 'GET') 'refresh should read the static list and device metadata once each'
    Assert-BmManagementUi ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/talkgroup') 'UI static list GET should use the dedicated talkgroup endpoint'
    Assert-BmManagementUi ($state.requests[1].uri -ceq 'https://api.brandmeister.network/v2/device/461135501') 'UI metadata GET should use the device endpoint'
    $authObserved = [string]$state.seen_auths[0]
    Assert-BmManagementUi ($authObserved -ceq ('Bearer ' + $fakeToken)) ("fake auth header should be exact (length={0}, bearer={1}, exact={2})" -f $authObserved.Length, $authObserved.StartsWith('Bearer '), ($authObserved -ceq ('Bearer ' + $fakeToken)))
    Assert-BmManagementUi ($window.FindName('BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'a successful GET should expose the BM static panel'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Visible) 'an empty successful GET should show an empty list'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 0) 'an empty GET should remain a real empty list'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupPageText').Text -ceq '1 / 1' -and
        -not $window.FindName('BmStaticGroupPagePreviousButton').IsEnabled -and
        -not $window.FindName('BmStaticGroupPageNextButton').IsEnabled) 'an empty list should show one disabled page'
    Assert-BmManagementUi ($window.FindName('AddBmStaticGroupButton').Visibility -eq [System.Windows.Visibility]::Visible -and $window.FindName('AddBmStaticGroupButton').IsEnabled) 'a valid simplex status should enable Add'
    Assert-BmManagementUi ($script:bmManagementStatus -ceq 'loaded' -and $script:bmManagementGroups.Count -eq 0 -and $script:bmManagementAddContext.add_slot -eq 0) 'empty list and status 4 should load with API slot 0'
    $configJson = ConvertTo-Json -InputObject $script:portableConfig -Compress
    Assert-BmManagementUi (-not $configJson.Contains($fakeToken) -and -not $window.FindName('BmStaticGroupStatus').Text.Contains($fakeToken)) 'the synthetic token must not enter saved config or UI status'

    $window.FindName('BmStaticGroupIdBox').Text = '12345'
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 201; body = '' },
        [pscustomobject]@{ status_code = 200; body = '[{"talkgroup":12345,"slot":0}]' }
    )
    Assert-BmManagementUi (Start-BmManagementUiRequest -Operation Add) 'Add should start only after list and device status have loaded'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'POST' -and $state.requests[1].method -ceq 'GET') 'Add should issue one POST followed by one talkgroup readback, without another device GET'
    $addBody = ConvertFrom-Json -InputObject $state.requests[0].body
    Assert-BmManagementUi ([uint64]$addBody.group -eq 12345 -and [int]$addBody.slot -eq 0) 'status 4 should drive Add to API slot 0'
    Assert-BmManagementUi ($script:bmManagementLastWriteAccepted -and $script:bmManagementLastReadbackStatus -ceq 'confirmed') 'Add should record confirmed write and readback'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 1 -and $window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 12345' -and [int]$window.FindName('BmStaticGroupsList').Items[0].slot -eq 0) 'Add should display TG only while retaining the original row slot'

    $window.FindName('BmStaticGroupsList').SelectedIndex = 0
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 204; body = '' },
        [pscustomobject]@{ status_code = 200; body = '[]' }
    )
    Assert-BmManagementUi (Start-BmManagementUiRequest -Operation Remove) 'Remove should start for a selected current-device static group'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].method -ceq 'DELETE' -and $state.requests[1].method -ceq 'GET') 'Remove should issue one DELETE followed by one readback GET'
    Assert-BmManagementUi ($state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135501/talkgroup/0/12345') 'Remove should use the selected row original slot and TG'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 0 -and $script:bmManagementLastReadbackStatus -ceq 'confirmed') 'confirmed Remove should display the empty BM list'

    foreach ($invalidStatusBody in @(
        '{"id":461135501,"status":null}',
        '{"id":461135501,"status":5}',
        '{"id":461135502,"status":4}',
        '{"id":461135501}'
    )) {
        Set-BmFakeResponses @(
            [pscustomobject]@{ status_code = 200; body = '[]' },
            [pscustomobject]@{ status_code = 200; body = $invalidStatusBody }
        )
        Assert-BmManagementUi (Request-BmManagementUiRefresh) 'refresh should keep reading the list when device status is incomplete'
        Wait-BmManagementUiIdle
        Assert-BmManagementUi ($script:bmManagementStatus -ceq 'loaded' -and $window.FindName('BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Visible) 'device status errors should leave the static list readable'
        Assert-BmManagementUi (-not $window.FindName('AddBmStaticGroupButton').IsEnabled -and $null -eq $script:bmManagementAddContext) 'missing, invalid, or mismatched device status must disable Add'
        if ($invalidStatusBody -ceq '{"id":461135501,"status":5}') {
            Assert-BmManagementUi ($window.FindName('BmStaticGroupStatus').Text.Contains('5')) 'a numeric unknown status should be shown as a short current value'
        }
        $requestCount = $state.requests.Count
        Assert-BmManagementUi (-not (Start-BmManagementUiRequest -Operation Add)) 'Add should reject unknown device context before creating a worker'
        Assert-BmManagementUi ($state.requests.Count -eq $requestCount) 'disabled Add must make no API call'
    }

    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 200; body = '[]' },
        [pscustomobject]@{ status_code = 200; body = '{"id":461135501,"status":0}' }
    )
    Assert-BmManagementUi (Request-BmManagementUiRefresh) 'valid network-linked status should restore Add'
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($window.FindName('AddBmStaticGroupButton').IsEnabled -and $script:bmManagementAddContext.add_slot -eq 2) 'valid loaded status 0 should use API slot 2'
    $window.FindName('BmStaticGroupIdBox').Text = '23455'
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 201; body = '' },
        [pscustomobject]@{ status_code = 200; body = '[{"talkgroup":23455,"slot":2}]' }
    )
    Assert-BmManagementUi (Start-BmManagementUiRequest -Operation Add) 'Add should accept the loaded network slot context'
    Wait-BmManagementUiIdle
    $networkAddBody = ConvertFrom-Json -InputObject $state.requests[0].body
    Assert-BmManagementUi ([int]$networkAddBody.slot -eq 2 -and $state.requests.Count -eq 2) 'network status Add should use slot 2 and only a dedicated GET readback'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 23455') 'network Add should retain the TG-only display'

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

    $newFakeToken = ('d' * 100) + '.' + ('e' * 100) + '.' + ('f' * 100)
    $window.FindName('BmApiKeyBox').Password = $newFakeToken
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 200; body = '[]' },
        [pscustomobject]@{ status_code = 200; body = '{"id":461135501,"status":2}' }
    )
    [void](Poll-BmManagementUi)
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.seen_auths[0] -ceq ('Bearer ' + $newFakeToken)) 'API key change should trigger a fresh list and device-context read'
    Assert-BmManagementUi ($script:bmManagementAddContext.add_slot -eq 2 -and $script:bmManagementObservedApiKey -ceq $newFakeToken) 'new API key context should be cached for the current device'

    $script:storedProfile.connection.gateway_id = [uint64]461135502
    Set-BmFakeResponses @(
        [pscustomobject]@{ status_code = 200; body = '[]' },
        [pscustomobject]@{ status_code = 200; body = '{"id":461135502,"status":4}' }
    )
    [void](Poll-BmManagementUi)
    Wait-BmManagementUiIdle
    Assert-BmManagementUi ($state.requests.Count -eq 2 -and $state.requests[0].uri -ceq 'https://api.brandmeister.network/v2/device/461135502/talkgroup' -and $state.requests[1].uri -ceq 'https://api.brandmeister.network/v2/device/461135502') 'device ID change should refresh list and metadata once for the new device'
    Assert-BmManagementUi ($script:bmManagementAddContext.add_slot -eq 0 -and $script:bmManagementObservedDeviceId -ceq '461135502') 'new device status should replace the prior Add context'

    $pageRequestCount = $state.requests.Count
    $pageGroups = @(
        foreach ($id in 30001..30007) {
            [pscustomobject][ordered]@{ device_id='461135502'; talkgroup=[uint64]$id; slot=2; type='static'; text=('TG {0}' -f $id) }
        }
    )
    Set-BmManagementUiGroupRows -Groups $pageGroups
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 3 -and
        $window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 30001' -and
        $window.FindName('BmStaticGroupPageText').Text -ceq '1 / 3' -and
        -not $window.FindName('BmStaticGroupPagePreviousButton').IsEnabled -and
        $window.FindName('BmStaticGroupPageNextButton').IsEnabled) 'the first static-group page should show three rows and enable only Next'
    Invoke-BmManagementUiButtonClick -Name 'BmStaticGroupPageNextButton'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 3 -and
        $window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 30004' -and
        $window.FindName('BmStaticGroupPageText').Text -ceq '2 / 3') 'Next should expose the second page without changing row contents'
    $window.FindName('BmStaticGroupsList').SelectedIndex = 0
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').SelectedItem.talkgroup -eq 30004 -and
        [int]$window.FindName('BmStaticGroupsList').SelectedItem.slot -eq 2 -and
        $window.FindName('RemoveBmStaticGroupButton').IsEnabled) 'a paged row should retain its talkgroup and slot for removal'
    Invoke-BmManagementUiButtonClick -Name 'BmStaticGroupPageNextButton'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 1 -and
        $window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 30007' -and
        $window.FindName('BmStaticGroupPageText').Text -ceq '3 / 3' -and
        -not $window.FindName('BmStaticGroupPageNextButton').IsEnabled) 'the last static-group page should show the remaining row only'
    Invoke-BmManagementUiButtonClick -Name 'BmStaticGroupPagePreviousButton'
    Assert-BmManagementUi ($window.FindName('BmStaticGroupsList').Items.Count -eq 3 -and
        $window.FindName('BmStaticGroupsList').Items[0].text -ceq 'TG 30004' -and
        $window.FindName('BmStaticGroupPageText').Text -ceq '2 / 3' -and
        $state.requests.Count -eq $pageRequestCount) 'page navigation should be local and make no API request'

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
