#requires -Version 5.1

function Get-BmManagementUiControl {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:bmManagementUiWindow) { throw 'BM 静态组界面尚未初始化。' }
    $control = $script:bmManagementUiWindow.FindName($Name)
    if ($null -eq $control) { throw "BM 静态组界面缺少控件 $Name。" }
    return $control
}

function Get-BmManagementUiDeviceId {
    $profile = if ($script:activeProfile) { $script:activeProfile } else { $script:storedProfile }
    if ($null -eq $profile -or $null -eq $profile.connection) { return '' }
    $value = [string]$profile.connection.gateway_id
    if ($value -notmatch '^[0-9]{1,10}$') { return '' }
    $parsed = [uint64]0
    if (-not [uint64]::TryParse($value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 4294967295) { return '' }
    return $parsed.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Get-BmManagementUiApiKey {
    $apiKey = [string](Get-BmManagementUiControl -Name 'BmApiKeyBox').Password
    return $apiKey
}

function Test-BmManagementUiApiKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ApiKey)
    return -not [string]::IsNullOrWhiteSpace($ApiKey)
}

function Get-BmManagementUiPageCount {
    $groupCount = @($script:bmManagementGroups).Count
    $pageSize = [Math]::Max(1,[int]$script:bmManagementUiPageSize)
    return [Math]::Max(1,[int][Math]::Ceiling($groupCount / [double]$pageSize))
}

function Update-BmManagementUiVisiblePage {
    if (-not $script:bmManagementUiWindow) { return }
    $pageCount = Get-BmManagementUiPageCount
    $pageIndex = [Math]::Max(0,[Math]::Min([int]$script:bmManagementUiPageIndex,$pageCount - 1))
    $script:bmManagementUiPageIndex = $pageIndex
    $firstRow = $pageIndex * [int]$script:bmManagementUiPageSize
    $visibleRows = @($script:bmManagementGroups | Select-Object -Skip $firstRow -First ([int]$script:bmManagementUiPageSize))
    $list = Get-BmManagementUiControl -Name 'BmStaticGroupsList'
    $list.ItemsSource = $null
    $list.ItemsSource = [object[]]$visibleRows
    (Get-BmManagementUiControl -Name 'BmStaticGroupPageText').Text = ('{0} / {1}' -f ($pageIndex + 1),$pageCount)
    (Get-BmManagementUiControl -Name 'BmStaticGroupPagePreviousButton').IsEnabled = ($pageIndex -gt 0)
    (Get-BmManagementUiControl -Name 'BmStaticGroupPageNextButton').IsEnabled = ($pageIndex -lt ($pageCount - 1))
}

function Set-BmManagementUiPage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$PageIndex)
    if (-not $script:bmManagementUiWindow) { return $false }
    $pageCount = Get-BmManagementUiPageCount
    $targetIndex = [Math]::Max(0,[Math]::Min($PageIndex,$pageCount - 1))
    if ($targetIndex -eq [int]$script:bmManagementUiPageIndex) { return $false }
    $script:bmManagementUiPageIndex = $targetIndex
    Update-BmManagementUiVisiblePage
    Set-BmManagementUiControlState
    return $true
}

function Save-BmManagementUiApiKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ApiKey)
    try {
        if ($script:portableConfig) {
            $script:portableConfig.connection.api_key = $ApiKey
            $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
        }
        return $true
    } catch {
        Set-BmManagementUiStatus -Text 'BM API Key 保存失败。'
        return $false
    }
}

function Set-BmManagementUiStatus {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $status = Get-BmManagementUiControl -Name 'BmStaticGroupStatus'
    $status.Text = $Text
    $status.Visibility = if ([string]::IsNullOrWhiteSpace($Text)) {
        [System.Windows.Visibility]::Collapsed
    } else { [System.Windows.Visibility]::Visible }
}

function Set-BmManagementUiControlState {
    if (-not $script:bmManagementUiWindow) { return }
    $apiKey = Get-BmManagementUiApiKey
    $hasApiKey = Test-BmManagementUiApiKey -ApiKey $apiKey
    $deviceId = Get-BmManagementUiDeviceId
    $busy = [bool]$script:bmManagementOperationPowerShell
    $loaded = ($script:bmManagementStatus -ceq 'loaded' -and
        -not [string]::IsNullOrWhiteSpace([string]$script:bmManagementObservedDeviceId) -and
        [string]$script:bmManagementObservedDeviceId -ceq $deviceId -and
        [string]$script:bmManagementObservedApiKey -ceq $apiKey)
    if (-not $loaded -and $script:bmManagementStatus -ceq 'loaded') {
        $script:bmManagementStatus = 'stale'
        $script:bmManagementGroups = @()
        $script:bmManagementAddContext = $null
        $script:bmManagementObservedDeviceId = ''
        $script:bmManagementObservedApiKey = ''
        if (-not $busy) { Set-BmManagementUiStatus -Text '设备或 API Key 已变更；请刷新 BM 静态组。' }
    }

    $panel = Get-BmManagementUiControl -Name 'BmStaticGroupPanel'
    $panel.Visibility = if ($hasApiKey -and $script:bmManagementModuleAvailable) {
        [System.Windows.Visibility]::Visible
    } else { [System.Windows.Visibility]::Collapsed }
    $refresh = Get-BmManagementUiControl -Name 'RefreshBmStaticGroupsButton'
    $refresh.IsEnabled = ($hasApiKey -and -not [string]::IsNullOrWhiteSpace($deviceId) -and -not $busy -and
        -not $script:bmManagementDisposeRequested)
    $list = Get-BmManagementUiControl -Name 'BmStaticGroupsList'
    $list.Visibility = if ($loaded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $pageVisibility = if ($loaded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    foreach ($name in @('BmStaticGroupPagePreviousButton','BmStaticGroupPageText','BmStaticGroupPageNextButton')) {
        (Get-BmManagementUiControl -Name $name).Visibility = $pageVisibility
    }
    $pageCount = Get-BmManagementUiPageCount
    $pageIndex = [Math]::Max(0,[Math]::Min([int]$script:bmManagementUiPageIndex,$pageCount - 1))
    $script:bmManagementUiPageIndex = $pageIndex
    (Get-BmManagementUiControl -Name 'BmStaticGroupPageText').Text = ('{0} / {1}' -f ($pageIndex + 1),$pageCount)
    (Get-BmManagementUiControl -Name 'BmStaticGroupPagePreviousButton').IsEnabled = ($loaded -and $pageIndex -gt 0)
    (Get-BmManagementUiControl -Name 'BmStaticGroupPageNextButton').IsEnabled = ($loaded -and $pageIndex -lt ($pageCount - 1))
    $remove = Get-BmManagementUiControl -Name 'RemoveBmStaticGroupButton'
    $remove.Visibility = if ($loaded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $selected = $list.SelectedItem
    $remove.IsEnabled = ($loaded -and -not $busy -and $null -ne $selected -and
        [string]$selected.type -ceq 'static' -and [string]$selected.device_id -ceq $deviceId -and
        -not $script:bmManagementDisposeRequested)
    $groupId = Get-BmManagementUiControl -Name 'BmStaticGroupIdBox'
    $groupId.Visibility = if ($loaded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $groupId.IsEnabled = ($loaded -and -not $busy -and -not $script:bmManagementDisposeRequested)
    $add = Get-BmManagementUiControl -Name 'AddBmStaticGroupButton'
    $add.Visibility = if ($loaded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $context = $script:bmManagementAddContext
    $contextReady = ($loaded -and $null -ne $context -and [bool]$context.success -and
        [string]$context.device_id -ceq $deviceId -and $null -ne $context.add_slot -and
        [string]$context.add_slot -in @('0','1','2'))
    $add.IsEnabled = ($contextReady -and -not $busy -and -not $script:bmManagementDisposeRequested)
    $source = Get-BmManagementUiControl -Name 'BmStaticGroupSourceValue'
    $source.Text = if ([string]::IsNullOrWhiteSpace($deviceId)) { '' } else { '设备 ' + $deviceId }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Set-BmManagementUiStatus -Text ''
    } elseif (-not $hasApiKey) {
        Set-BmManagementUiStatus -Text '请输入 BM API Key。'
    } elseif (-not $script:bmManagementModuleAvailable) {
        Set-BmManagementUiStatus -Text 'BM 静态组模块不可用。'
    } elseif ([string]::IsNullOrWhiteSpace($deviceId)) {
        Set-BmManagementUiStatus -Text '请先保存有效的 BM 设备 ID。'
    }
}

function Set-BmManagementUiGroupRows {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Groups)
    $rows = @(
        foreach ($group in $Groups) {
            $slot = [int]$group.slot
            [pscustomobject][ordered]@{
                device_id = [string]$group.device_id
                talkgroup = [uint64]$group.talkgroup
                slot = $slot
                type = 'static'
                text = ('TG {0}' -f [uint64]$group.talkgroup)
            }
        }
    )
    $script:bmManagementGroups = @($rows)
    $script:bmManagementUiPageIndex = 0
    Update-BmManagementUiVisiblePage
    Set-BmManagementUiControlState
}

function Get-BmManagementUiWorkerScript {
    return @'
param($ModulePath, $Operation, $ApiKey, $DeviceId, $Talkgroup, $Slot, $TimeoutMs, $CancellationToken, $Transport, $TransportRequired)
$ErrorActionPreference = 'Stop'
try {
    if ($TransportRequired -and -not $Transport) { throw [System.InvalidOperationException]::new('test transport missing') }
    Import-Module -Name $ModulePath -Force -ErrorAction Stop
    $common = @{ ApiKey = $ApiKey; DeviceId = $DeviceId; TimeoutMs = $TimeoutMs; CancellationToken = $CancellationToken }
    if ($Transport) { $common.Transport = $Transport }
    $result = switch ($Operation) {
        'get_static_groups' {
            $listResult = Get-BmStaticGroups @common
            $addContext = $null
            try {
                $addContext = Get-BmStaticGroupAddContext @common
            } catch [System.OperationCanceledException] {
                throw
            } catch {
                $addContext = [pscustomobject][ordered]@{
                    operation = 'get_static_group_add_context'; device_id = [string]$DeviceId
                    success = $false; status = $null; add_slot = $null
                }
            }
            [pscustomobject][ordered]@{
                operation = 'get_static_groups'; device_id = [string]$DeviceId
                success = $true; groups = @($listResult.groups); add_context = $addContext
                retrieved_utc = [string]$listResult.retrieved_utc
            }
            break
        }
        'add_static_group' {
            $common.Talkgroup = $Talkgroup
            $common.Slot = $Slot
            Add-BmStaticGroup @common
            break
        }
        'remove_static_group' {
            $common.Talkgroup = $Talkgroup
            $common.Slot = $Slot
            Remove-BmStaticGroup @common
            break
        }
        default { throw [System.ArgumentException]::new('unsupported operation') }
    }
    [pscustomobject][ordered]@{ success = $true; result = $result; error_code = '' }
} catch [System.OperationCanceledException] {
    [pscustomobject][ordered]@{ success = $false; result = $null; error_code = 'canceled' }
} catch [System.TimeoutException] {
    [pscustomobject][ordered]@{ success = $false; result = $null; error_code = 'timeout' }
} catch {
    [pscustomobject][ordered]@{ success = $false; result = $null; error_code = 'failed' }
}
'@
}

function Start-BmManagementUiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Get','Add','Remove')][string]$Operation,
        [Parameter()][uint64]$Talkgroup = 0,
        [Parameter()][int]$Slot = 0
    )

    if ($script:bmManagementDisposeRequested -or $script:bmManagementUiDisposed) { return $false }
    if ($script:bmManagementOperationPowerShell) {
        Set-BmManagementUiStatus -Text 'BM 静态组操作正在进行。'
        return $false
    }
    $apiKey = Get-BmManagementUiApiKey
    if (-not (Test-BmManagementUiApiKey -ApiKey $apiKey)) {
        $script:bmManagementStatus = 'unavailable'
        Set-BmManagementUiStatus -Text '请输入 BM API Key。'
        Set-BmManagementUiControlState
        return $false
    }
    if (-not $script:bmManagementModuleAvailable -or -not [System.IO.File]::Exists($script:bmManagementModulePath)) {
        $script:bmManagementStatus = 'unavailable'
        Set-BmManagementUiStatus -Text 'BM 静态组模块不可用。'
        Set-BmManagementUiControlState
        return $false
    }
    $deviceId = Get-BmManagementUiDeviceId
    if ([string]::IsNullOrWhiteSpace($deviceId)) {
        $script:bmManagementStatus = 'unavailable'
        Set-BmManagementUiStatus -Text '请先保存有效的 BM 设备 ID。'
        Set-BmManagementUiControlState
        return $false
    }
    $operationName = switch ($Operation) { 'Get' { 'get_static_groups' } 'Add' { 'add_static_group' } 'Remove' { 'remove_static_group' } }
    if ($Operation -ceq 'Add') {
        $idText = [string](Get-BmManagementUiControl -Name 'BmStaticGroupIdBox').Text
        $parsedTalkgroup = [uint64]0
        if ($idText -notmatch '^[0-9]{1,8}$' -or -not [uint64]::TryParse($idText, [ref]$parsedTalkgroup) -or $parsedTalkgroup -lt 1 -or $parsedTalkgroup -gt 16777215) {
            Set-BmManagementUiStatus -Text '请输入 1 至 16777215 的静态组 ID。'
            return $false
        }
        if ($script:bmManagementStatus -cne 'loaded' -or [string]$script:bmManagementObservedDeviceId -cne $deviceId -or
            [string]$script:bmManagementObservedApiKey -cne $apiKey) {
            Set-BmManagementUiStatus -Text '请先读取当前设备的 BM 静态组。'
            return $false
        }
        $addContext = $script:bmManagementAddContext
        if ($null -eq $addContext -or -not [bool]$addContext.success -or
            [string]$addContext.device_id -cne $deviceId -or $null -eq $addContext.add_slot -or
            [string]$addContext.add_slot -notin @('0','1','2')) {
            Set-BmManagementUiStatus -Text '设备状态不可用；添加已禁用。'
            return $false
        }
        $Talkgroup = $parsedTalkgroup
        $Slot = [int]$addContext.add_slot
        if (@($script:bmManagementGroups | Where-Object { [uint64]$_.talkgroup -eq $Talkgroup -and [int]$_.slot -eq $Slot }).Count -gt 0) {
            Set-BmManagementUiStatus -Text '该静态组已存在。'
            return $false
        }
    }
    if ($Operation -ceq 'Remove') {
        $selected = (Get-BmManagementUiControl -Name 'BmStaticGroupsList').SelectedItem
        if ($null -eq $selected -or [string]$selected.type -cne 'static' -or [string]$selected.device_id -cne $deviceId) {
            Set-BmManagementUiStatus -Text '请先选择当前设备的一条 BM 静态组。'
            return $false
        }
        $Talkgroup = [uint64]$selected.talkgroup
        $Slot = [int]$selected.slot
        if ($script:bmManagementStatus -cne 'loaded' -or [string]$script:bmManagementObservedDeviceId -cne $deviceId -or
            [string]$script:bmManagementObservedApiKey -cne $apiKey) {
            Set-BmManagementUiStatus -Text '请先读取当前设备的 BM 静态组。'
            return $false
        }
    }

    $cancellation = [System.Threading.CancellationTokenSource]::new()
    $runspace = $null
    $powerShell = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $powerShell = [System.Management.Automation.PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript((Get-BmManagementUiWorkerScript))
        [void]$powerShell.AddArgument($script:bmManagementModulePath)
        [void]$powerShell.AddArgument($operationName)
        [void]$powerShell.AddArgument($apiKey)
        [void]$powerShell.AddArgument($deviceId)
        [void]$powerShell.AddArgument([uint64]$Talkgroup)
        [void]$powerShell.AddArgument([int]$Slot)
        [void]$powerShell.AddArgument(3000)
        [void]$powerShell.AddArgument($cancellation.Token)
        [void]$powerShell.AddArgument($script:bmManagementUiTransportOverride)
        [void]$powerShell.AddArgument([bool]$script:bmManagementUiTransportRequired)
        $async = $powerShell.BeginInvoke()
    } catch {
        if ($powerShell) { try { $powerShell.Dispose() } catch { } }
        if ($runspace) { try { $runspace.Close() } catch { }; try { $runspace.Dispose() } catch { } }
        $cancellation.Dispose()
        $script:bmManagementStatus = 'failed'
        $script:bmManagementLastErrorCode = 'worker_start_failed'
        Set-BmManagementUiStatus -Text 'BM 静态组后台操作未能启动。'
        Set-BmManagementUiControlState
        return $false
    }

    $script:bmManagementCancellationSource = $cancellation
    $script:bmManagementOperationPowerShell = $powerShell
    $script:bmManagementOperationAsync = $async
    $script:bmManagementOperationStopAsync = $null
    $script:bmManagementOperationRunspace = $runspace
    $script:bmManagementOperation = $operationName
    $script:bmManagementOperationStartedUtc = [DateTime]::UtcNow
    $script:bmManagementOperationDeviceId = $deviceId
    $script:bmManagementOperationApiKey = $apiKey
    $script:bmManagementDeviceId = $deviceId
    $script:bmManagementLastIdentityDeviceId = $deviceId
    $script:bmManagementLastIdentityApiKey = $apiKey
    $script:bmManagementOperationTalkgroup = [uint64]$Talkgroup
    $script:bmManagementOperationSlot = [int]$Slot
    $script:bmManagementStatus = 'busy'
    $script:bmManagementLastErrorCode = ''
    $script:bmManagementLastWriteAccepted = $false
    $script:bmManagementLastReadbackStatus = ''
    $script:bmManagementOperationGeneration++
    $script:bmManagementActiveGeneration = $script:bmManagementOperationGeneration
    $statusText = switch ($Operation) {
        'Get' { '正在读取 BM 静态组。' }
        'Add' { '正在向 BM 添加静态组。' }
        'Remove' { '正在向 BM 移除静态组。' }
    }
    Set-BmManagementUiStatus -Text $statusText
    Set-BmManagementUiControlState
    return $true
}

function Request-BmManagementUiRefresh {
    [CmdletBinding()]
    param()
    if ($script:bmManagementOperationPowerShell) {
        $currentApiKey = Get-BmManagementUiApiKey
        $currentDeviceId = Get-BmManagementUiDeviceId
        if ([string]$script:bmManagementOperationApiKey -cne $currentApiKey -or
            [string]$script:bmManagementOperationDeviceId -cne $currentDeviceId) {
            $script:bmManagementUiRefreshPending = $true
        }
        return $false
    }
    return [bool](Start-BmManagementUiRequest -Operation Get)
}

function Sync-BmManagementUiIdentity {
    if (-not $script:bmManagementUiWindow -or $script:bmManagementDisposeRequested -or $script:bmManagementUiDisposed) { return }
    $deviceId = Get-BmManagementUiDeviceId
    $apiKey = Get-BmManagementUiApiKey
    if ([string]$script:bmManagementLastIdentityDeviceId -ceq $deviceId -and
        [string]$script:bmManagementLastIdentityApiKey -ceq $apiKey) { return }

    $script:bmManagementLastIdentityDeviceId = $deviceId
    $script:bmManagementLastIdentityApiKey = $apiKey
    if (-not [string]::IsNullOrWhiteSpace($deviceId) -and (Test-BmManagementUiApiKey -ApiKey $apiKey) -and
        $script:bmManagementModuleAvailable) {
        if ($script:bmManagementOperationPowerShell) {
            $script:bmManagementUiRefreshPending = $true
        } else {
            [void](Request-BmManagementUiRefresh)
        }
    }
}

function Complete-BmManagementUiOperation {
    if (-not $script:bmManagementOperationPowerShell) { return $false }
    $powerShell = $script:bmManagementOperationPowerShell
    $state = [string]$powerShell.InvocationStateInfo.State
    if ($state -cnotin @('Completed','Failed','Stopped')) { return $false }
    $outcome = $null
    try {
        $output = $powerShell.EndInvoke($script:bmManagementOperationAsync)
        if ($output -and $output.Count -gt 0) { $outcome = $output[$output.Count - 1] }
    } catch {
        $outcome = [pscustomobject]@{ success = $false; result = $null; error_code = 'failed' }
    } finally {
        try { $powerShell.Dispose() } catch { }
        $runspace = $script:bmManagementOperationRunspace
        if ($runspace) {
            try { if ([string]$runspace.RunspaceStateInfo.State -cne 'Closed') { $runspace.Close() } } catch { }
            try { $runspace.Dispose() } catch { }
        }
        if ($script:bmManagementCancellationSource) {
            try { $script:bmManagementCancellationSource.Dispose() } catch { }
        }
        $script:bmManagementOperationPowerShell = $null
        $script:bmManagementOperationAsync = $null
        $script:bmManagementOperationStopAsync = $null
        $script:bmManagementOperationRunspace = $null
        $script:bmManagementCancellationSource = $null
    }

    if ($script:bmManagementDisposeRequested) {
        $script:bmManagementUiDisposed = $true
        return $true
    }
    $operation = [string]$script:bmManagementOperation
    $deviceId = [string]$script:bmManagementOperationDeviceId
    $currentDeviceId = Get-BmManagementUiDeviceId
    $script:bmManagementOperation = ''
    if (-not $outcome -or -not [bool]$outcome.success) {
        $errorCode = if ($outcome) { [string]$outcome.error_code } else { 'failed' }
        $script:bmManagementLastErrorCode = $errorCode
        $script:bmManagementStatus = 'failed'
        if ($errorCode -ceq 'canceled') {
            if ($operation -ceq 'get_static_groups') {
                Set-BmManagementUiStatus -Text 'BM 静态组读取已取消。'
            } elseif ($operation -in @('add_static_group','remove_static_group')) {
                Set-BmManagementUiStatus -Text '静态组写入结果未确认；请刷新列表后再操作。'
            }
        } elseif ($errorCode -ceq 'timeout') {
            Set-BmManagementUiStatus -Text 'BM API 操作超时；请刷新列表确认服务器状态。'
        } else {
            Set-BmManagementUiStatus -Text 'BM API 操作失败；请检查 API Key 与网络后刷新。'
        }
        if ($operation -in @('add_static_group','remove_static_group') -and $errorCode -ne 'canceled') {
            $script:bmManagementStatus = 'stale'
            $script:bmManagementGroups = @()
            $script:bmManagementAddContext = $null
            $script:bmManagementObservedDeviceId = ''
            $script:bmManagementObservedApiKey = ''
        }
        Set-BmManagementUiControlState
        return $true
    }

    $result = $outcome.result
    if ([string]$result.device_id -cne $deviceId) {
        $script:bmManagementStatus = 'stale'
        $script:bmManagementGroups = @()
        $script:bmManagementAddContext = $null
        $script:bmManagementObservedDeviceId = ''
        $script:bmManagementObservedApiKey = ''
        Set-BmManagementUiStatus -Text 'BM 返回的设备 ID 与本次请求不一致；列表已清除。'
        Set-BmManagementUiControlState
        return $true
    }
    if ($operation -ceq 'get_static_groups') {
        if ($currentDeviceId -cne $deviceId -or
            [string](Get-BmManagementUiApiKey) -cne [string]$script:bmManagementOperationApiKey) {
            $script:bmManagementStatus = 'stale'
            $script:bmManagementGroups = @()
            $script:bmManagementAddContext = $null
            $script:bmManagementObservedDeviceId = ''
            $script:bmManagementObservedApiKey = ''
            Set-BmManagementUiStatus -Text '设备或 API Key 已变更；未显示旧设备的 BM 静态组。'
            Set-BmManagementUiControlState
            return $true
        }
        Set-BmManagementUiGroupRows -Groups @($result.groups)
        $script:bmManagementObservedDeviceId = $deviceId
        $script:bmManagementObservedApiKey = [string]$script:bmManagementOperationApiKey
        $script:bmManagementStatus = 'loaded'
        $script:bmManagementLastErrorCode = ''
        $context = $result.add_context
        $contextValid = ($null -ne $context -and [bool]$context.success -and
            [string]$context.device_id -ceq $deviceId -and $null -ne $context.add_slot -and
            [string]$context.add_slot -in @('0','1','2') -and $null -ne $context.status -and
            [string]$context.status -in @('0','1','2','3','4'))
        if ($contextValid) {
            $script:bmManagementAddContext = [pscustomobject][ordered]@{
                device_id = $deviceId
                status = [int]$context.status
                add_slot = [int]$context.add_slot
                success = $true
            }
            Set-BmManagementUiStatus -Text ('已读取 {0} 条 BM 静态组；设备状态 {1}。' -f @($result.groups).Count, [int]$context.status)
        } else {
            $script:bmManagementAddContext = $null
            $statusText = if ($null -ne $context -and $null -ne $context.status) { [string]$context.status } else { '未知' }
            Set-BmManagementUiStatus -Text ('已读取 {0} 条 BM 静态组；设备状态 {1}，添加已禁用。' -f @($result.groups).Count, $statusText)
        }
    } else {
        $script:bmManagementLastWriteAccepted = [bool]$result.write_accepted
        $script:bmManagementLastReadbackStatus = [string]$result.readback_status
        $sameCurrentContext = ($currentDeviceId -ceq $deviceId -and
            [string](Get-BmManagementUiApiKey) -ceq [string]$script:bmManagementOperationApiKey)
        if ([string]$result.readback_status -ceq 'confirmed' -and $sameCurrentContext) {
            Set-BmManagementUiGroupRows -Groups @($result.groups)
            $script:bmManagementObservedDeviceId = $deviceId
            $script:bmManagementObservedApiKey = [string]$script:bmManagementOperationApiKey
            $script:bmManagementStatus = 'loaded'
            Set-BmManagementUiStatus -Text 'BM 已接受静态组更改，读取列表已确认。'
        } elseif ([string]$result.readback_status -ceq 'not_confirmed' -and $sameCurrentContext) {
            Set-BmManagementUiGroupRows -Groups @($result.groups)
            $script:bmManagementObservedDeviceId = $deviceId
            $script:bmManagementObservedApiKey = [string]$script:bmManagementOperationApiKey
            $script:bmManagementStatus = 'loaded'
            Set-BmManagementUiStatus -Text 'BM 已接受静态组更改，但读取结果与请求不符；请检查列表。'
        } else {
            $script:bmManagementStatus = 'stale'
            $script:bmManagementGroups = @()
            $script:bmManagementAddContext = $null
            $script:bmManagementObservedDeviceId = ''
            $script:bmManagementObservedApiKey = ''
            $script:bmManagementLastErrorCode = [string]$result.readback_error
            Set-BmManagementUiStatus -Text 'BM 已接受静态组更改，但回查未完成；请刷新确认。'
        }
    }
    Set-BmManagementUiControlState
    return $true
}

function Poll-BmManagementUi {
    [CmdletBinding()]
    param()
    if ($script:bmManagementOperationPowerShell) {
        $state = [string]$script:bmManagementOperationPowerShell.InvocationStateInfo.State
        if ($state -cin @('Completed','Failed','Stopped')) { [void](Complete-BmManagementUiOperation) }
    }
    Sync-BmManagementUiIdentity
    if ($script:bmManagementDisposeRequested -and $script:bmManagementOperationPowerShell -and
        -not $script:bmManagementOperationAsync.IsCompleted -and -not $script:bmManagementOperationStopAsync -and
        ([DateTime]::UtcNow - [DateTime]$script:bmManagementOperationStartedUtc).TotalMilliseconds -ge 1000) {
        try { $script:bmManagementOperationStopAsync = $script:bmManagementOperationPowerShell.BeginStop($null, $null) } catch { }
    }
    if ($script:bmManagementUiRefreshPending -and -not $script:bmManagementOperationPowerShell -and
        -not $script:bmManagementDisposeRequested) {
        $script:bmManagementUiRefreshPending = $false
        [void](Start-BmManagementUiRequest -Operation Get)
    }
    if ($script:bmManagementDisposeRequested -and -not $script:bmManagementOperationPowerShell) {
        $script:bmManagementUiDisposed = $true
    }
    if (-not $script:bmManagementDisposeRequested -and $script:bmManagementUiWindow) {
        Set-BmManagementUiControlState
    }
    return [bool]$script:bmManagementUiDisposed
}

function Dispose-BmManagementUi {
    [CmdletBinding()]
    param()
    $script:bmManagementDisposeRequested = $true
    if (-not $script:bmManagementOperationPowerShell) {
        $script:bmManagementUiDisposed = $true
        return $true
    }
    if ($script:bmManagementCancellationSource -and -not $script:bmManagementCancellationSource.IsCancellationRequested) {
        try { $script:bmManagementCancellationSource.Cancel() } catch { }
    }
    if ($script:bmManagementOperationAsync -and -not $script:bmManagementOperationAsync.IsCompleted -and
        -not $script:bmManagementOperationStopAsync -and
        ([DateTime]::UtcNow - [DateTime]$script:bmManagementOperationStartedUtc).TotalMilliseconds -ge 1000) {
        try { $script:bmManagementOperationStopAsync = $script:bmManagementOperationPowerShell.BeginStop($null, $null) } catch { }
    }
    return [bool]$script:bmManagementUiDisposed
}

function Initialize-BmManagementUi {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)

    $script:bmManagementUiWindow = $Window
    $script:bmManagementUiDisposed = $false
    $script:bmManagementDisposeRequested = $false
    $script:bmManagementOperationRunspace = $null
    $script:bmManagementOperationDeviceId = ''
    $script:bmManagementOperationApiKey = ''
    $script:bmManagementOperationTalkgroup = [uint64]0
    $script:bmManagementOperationSlot = 0
    $script:bmManagementUiRefreshPending = $false
    $script:bmManagementAddContext = $null
    $script:bmManagementUiControls = @{}
    $script:bmManagementUiPageSize = 3
    $script:bmManagementUiPageIndex = 0
    foreach ($name in @('BmApiKeyBox','BmStaticGroupPanel','BmStaticGroupSourceValue',
            'BmStaticGroupsList','BmStaticGroupPagePreviousButton','BmStaticGroupPageText','BmStaticGroupPageNextButton','BmStaticGroupIdBox',
            'AddBmStaticGroupButton','RemoveBmStaticGroupButton','RefreshBmStaticGroupsButton','BmStaticGroupStatus')) {
        $script:bmManagementUiControls[$name] = $Window.FindName($name)
        if ($null -eq $script:bmManagementUiControls[$name]) { throw "BM 静态组界面缺少控件 $name。" }
    }
    $apiKey = if ($script:portableConfig) { [string]$script:portableConfig.connection.api_key } else { '' }
    $script:bmManagementUiControls['BmApiKeyBox'].Password = $apiKey
    $script:bmManagementUiControls['BmApiKeyBox'].Add_LostFocus({
        $currentApiKey = Get-BmManagementUiApiKey
        [void](Save-BmManagementUiApiKey -ApiKey $currentApiKey)
        Set-BmManagementUiControlState
        if (Test-BmManagementUiApiKey -ApiKey $currentApiKey) { [void](Request-BmManagementUiRefresh) }
    })
    $script:bmManagementUiControls['RefreshBmStaticGroupsButton'].Add_Click({ [void](Request-BmManagementUiRefresh) })
    $script:bmManagementUiControls['BmStaticGroupPagePreviousButton'].Add_Click({ [void](Set-BmManagementUiPage -PageIndex ($script:bmManagementUiPageIndex - 1)) })
    $script:bmManagementUiControls['BmStaticGroupPageNextButton'].Add_Click({ [void](Set-BmManagementUiPage -PageIndex ($script:bmManagementUiPageIndex + 1)) })
    $script:bmManagementUiControls['AddBmStaticGroupButton'].Add_Click({ [void](Start-BmManagementUiRequest -Operation Add) })
    $script:bmManagementUiControls['RemoveBmStaticGroupButton'].Add_Click({ [void](Start-BmManagementUiRequest -Operation Remove) })
    $script:bmManagementUiControls['BmStaticGroupsList'].Add_SelectionChanged({ Set-BmManagementUiControlState })
    $script:bmManagementUiControls['BmStaticGroupIdBox'].Add_TextChanged({ Set-BmManagementUiControlState })
    $unusedLabelInput = $Window.FindName('BmStaticGroupLabelBox')
    if ($unusedLabelInput) {
        $unusedLabelInput.Visibility = [System.Windows.Visibility]::Collapsed
        $unusedLabelInput.IsEnabled = $false
    }
    $script:bmManagementStatus = 'unavailable'
    $script:bmManagementGroups = @()
    $script:bmManagementAddContext = $null
    $script:bmManagementObservedDeviceId = ''
    $script:bmManagementObservedApiKey = ''
    $script:bmManagementLastIdentityDeviceId = Get-BmManagementUiDeviceId
    $script:bmManagementLastIdentityApiKey = $apiKey
    Set-BmManagementUiControlState
    if ((Test-BmManagementUiApiKey -ApiKey $apiKey) -and -not [string]::IsNullOrWhiteSpace((Get-BmManagementUiDeviceId))) {
        [void](Request-BmManagementUiRefresh)
    }
}
