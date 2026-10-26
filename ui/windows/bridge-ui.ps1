[CmdletBinding()]
param(
    [string]$UserConfigDirectory,
    [string]$PackageDirectory,
    [switch]$OfflinePreview,
    [switch]$NoAutoConnect,
    [switch]$RenderOnly,
    [string]$RenderOutputDirectory,
    [string]$RenderWorkArea
)

$ErrorActionPreference = 'Stop'
$script:uiRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:packageDirectoryWasExplicit = $PSBoundParameters.ContainsKey('PackageDirectory') -and
    -not [string]::IsNullOrWhiteSpace($PackageDirectory)
$script:packageRoot = if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    [System.IO.Path]::GetFullPath((Join-Path $script:uiRoot '..\..'))
} else {
    [System.IO.Path]::GetFullPath($PackageDirectory)
}

function Resolve-UiRuntimeDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$UserConfigDirectory,
        [Parameter(Mandatory=$true)][bool]$PackageDirectoryWasExplicit
    )
    $resolvedPackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
    if ($PackageDirectoryWasExplicit) { return $resolvedPackageRoot }
    $releasePointerPath = Join-Path $UserConfigDirectory 'bridge-directory.txt'
    if ([System.IO.File]::Exists($releasePointerPath)) {
        return Get-BridgeReleaseDirectory -UserConfigDirectory $UserConfigDirectory
    }
    return $resolvedPackageRoot
}

$script:modulePath = Join-Path $script:packageRoot 'bridge-user-config.psm1'
if (-not [System.IO.File]::Exists($script:modulePath)) {
    $script:modulePath = Join-Path $script:packageRoot 'tools\bridge-user-config.psm1'
}
if (-not [System.IO.File]::Exists($script:modulePath)) {
    $script:modulePath = Join-Path $script:uiRoot '..\..\tools\bridge-user-config.psm1'
}
if (-not [System.IO.File]::Exists($script:modulePath)) { throw '缺少本机配置模块 bridge-user-config.psm1。' }
$script:supervisorSource = Join-Path $script:uiRoot 'BridgeSupervisor.cs'
$script:mainXamlPath = Join-Path $script:uiRoot 'MainWindow.xaml'
$script:settingsXamlPath = Join-Path $script:uiRoot 'SettingsWindow.xaml'
foreach ($path in @($script:supervisorSource, $script:mainXamlPath, $script:settingsXamlPath)) {
    if (-not [System.IO.File]::Exists($path)) { throw "缺少桌面界面文件：$path" }
}

Import-Module -Name $script:modulePath -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
if (-not ('WirexBridge.Ui.BridgeSupervisor' -as [type])) { Add-Type -Path $script:supervisorSource }
$script:workAreaWidth = [double][System.Windows.SystemParameters]::WorkArea.Width
$script:workAreaHeight = [double][System.Windows.SystemParameters]::WorkArea.Height
if (-not [string]::IsNullOrWhiteSpace($RenderWorkArea)) {
    if (-not $RenderOnly -or $RenderWorkArea -cnotmatch '^([1-9][0-9]{2,4})x([1-9][0-9]{2,4})$') {
        throw '-RenderWorkArea 只接受 RenderOnly 使用的宽x高测试尺寸。'
    }
    $script:workAreaWidth = [Math]::Min($script:workAreaWidth, [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture))
    $script:workAreaHeight = [Math]::Min($script:workAreaHeight, [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture))
}
$script:maxWindowWidth = [Math]::Max(1, [Math]::Floor($script:workAreaWidth * 0.95))
$script:maxWindowHeight = [Math]::Max(1, [Math]::Floor($script:workAreaHeight * 0.95))

$script:configDirectory = Get-BridgeUserConfigDirectory -UserConfigDirectory $UserConfigDirectory -ScriptRoot $script:packageRoot
$script:profilePath = Join-Path $script:configDirectory 'connection-profile.json'
$script:audioSettingsPath = Join-Path $script:configDirectory 'audio-settings.json'
$script:passwordPointerPath = Join-Path $script:configDirectory 'password-file-path.txt'
$script:releasePointerPath = Join-Path $script:configDirectory 'bridge-directory.txt'
$script:releaseDirectory = Resolve-UiRuntimeDirectory -PackageRoot $script:packageRoot `
    -UserConfigDirectory $script:configDirectory -PackageDirectoryWasExplicit $script:packageDirectoryWasExplicit
$script:releaseLauncher = Join-Path $script:releaseDirectory 'start-bm-radio-bridge.ps1'
$script:nativeExecutable = Join-Path $script:releaseDirectory 'wirex_bridge.exe'
if (-not [System.IO.File]::Exists($script:releaseLauncher) -or -not [System.IO.File]::Exists($script:nativeExecutable)) {
    throw '所选便携目录缺少桥接启动脚本或 native 核心。'
}

$script:application = New-Object System.Windows.Application
$script:application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$script:mainWindow = $null
$script:settingsWindow = $null
$script:supervisor = $null
$script:stopTask = $null
$script:preparePowerShell = $null
$script:prepareAsync = $null
$script:prepareStopAsync = $null
$script:prepareStopStartedUtc = [DateTime]::MinValue
$script:abandonPreparationAtShutdown = $false
$script:deviceDiscoveryPowerShell = $null
$script:deviceDiscoveryAsync = $null
$script:deviceDiscoveryStopAsync = $null
$script:deviceDiscoveryStartedUtc = [DateTime]::MinValue
$script:deviceDiscoveryState = 'not_started'
$script:deviceDiscoveryError = ''
$script:deviceCatalog = $null
$script:deviceAudioQuery = $null
$script:deviceDiscoveryGeneration = [uint64]0
$script:deviceDiscoveryActiveGeneration = [uint64]0
$script:deviceDiscoveryOwnerWindow = $null
$script:deviceDiscoveryRestartPending = $false
$script:deviceDiscoveryStopReason = ''
$script:deviceDiscoveryStopStartedUtc = [DateTime]::MinValue
$script:closingAfterDeviceDiscovery = $false
$script:statusStream = $null
$script:statusPath = ''
$script:preparedRunDirectory = ''
$script:statusOffset = [int64]0
$script:partialStatusLine = ''
$script:currentRunId = ''
$script:lastSequence = [uint64]0
$script:lastStatusUtc = [DateTime]::MinValue
$script:latestStatus = $null
$script:storedProfile = $null
$script:effectiveProfile = $null
$script:passwordPath = ''
$script:allowWindowClose = $false
$script:closingAfterStop = $false
$script:startupNeedsSettings = $false
$script:preparationStarted = $false
$script:targetLabel = '尚未设置'
$script:activeTargetLabel = ''
$script:activeTargetTag = ''
$script:reconnectAfterStop = $false
$script:lastUiBmState = ''
$script:lastUiHriState = ''
$script:runLogItems = 0
$script:stopButtonActionPending = $false

function Import-WpfWindow {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [Windows.Markup.XamlReader]::Load($stream) }
    finally { $stream.Dispose() }
}

function Fit-WpfWindowToWorkArea {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window)
    $Window.MinWidth = [Math]::Min($Window.MinWidth, $script:maxWindowWidth)
    $Window.MinHeight = [Math]::Min($Window.MinHeight, $script:maxWindowHeight)
    $Window.MaxWidth = $script:maxWindowWidth
    $Window.MaxHeight = $script:maxWindowHeight
    $Window.Width = [Math]::Min($Window.Width, $script:maxWindowWidth)
    $Window.Height = [Math]::Min($Window.Height, $script:maxWindowHeight)
    $eventList = $Window.FindName('EventList')
    if ($null -ne $eventList) {
        $eventList.Height = if ($script:maxWindowHeight -le 720) { 54 } else { 94 }
    }
}

function Get-WpfWindowLayoutInfo {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window, [Parameter(Mandatory=$true)][string[]]$ControlNames)
    $visibility = [ordered]@{}
    foreach ($name in $ControlNames) {
        $control = $Window.FindName($name)
        $visibility[$name] = ($null -ne $control -and $control.IsVisible)
    }
    $eventList = $Window.FindName('EventList')
    return [pscustomobject][ordered]@{
        width = [double]$Window.ActualWidth
        height = [double]$Window.ActualHeight
        controls_visible = [pscustomobject]$visibility
        event_list_height = if ($null -ne $eventList) { [double]$eventList.ActualHeight } else { $null }
    }
}

function Get-UiControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:mainWindow.FindName($Name)
    if ($null -eq $control) { throw "主窗口缺少控件 $Name。" }
    return $control
}

function Get-SettingsControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:settingsWindow.FindName($Name)
    if ($null -eq $control) { throw "设置窗口缺少控件 $Name。" }
    return $control
}

function Set-MainText {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][string]$Text)
    (Get-UiControl -Name $Name).Text = $Text
}

function Add-UiEvent {
    param([Parameter(Mandatory=$true)][string]$Text)
    $list = Get-UiControl -Name 'EventList'
    $stamp = [DateTime]::Now.ToString('HH:mm:ss')
    [void]$list.Items.Add(($stamp + '  ' + $Text))
    while ($list.Items.Count -gt 12) { $list.Items.RemoveAt(0) }
}

function Get-VisibleUiEventText {
    param([string]$EventName)
    switch -CaseSensitive ($EventName) {
        'preflight_passed' { return '设备选择已核对' }
        'started' { return '桥接已启动' }
        'hri_y0_observed_radio_speaker_ready' { return '电台音频输出已就绪' }
        'tx_started_from_radio_ptt_down' { return '手咪开始发送' }
        'tx_audio_draining_after_radio_ptt_release' { return '手咪已松开，正在完成发送' }
        'hri_t3_observed_playback_enabled' { return '电台开始播放来话' }
        'lcd_source_identity_prepared_for_this_call' { return '本次来话来源标签已准备' }
        'downlink_call_drained_t0_observed' { return '本次来话播放结束' }
        'radio_ptt_call_120s_limit_reached_release_required' { return '单次发送到达时限，请松开手咪后再讲话' }
        'shutdown_requested' { return '正在停止桥接' }
        'stopped' { return '桥接已停止' }
        'stopped_with_failure' { return '桥接因错误停止' }
        'stopped_after_runtime_exception' { return '桥接遇到错误并已停止' }
        'bm_session_never_ready_no_connection_confirmed' { return 'BM 未能建立连接' }
        'downlink_rejected_without_ready_radio_waveout' { return '电台音频输出尚未就绪，来话未播放' }
        'tx_start_rejected_busy_or_endpoint_not_ready' { return '发送未开始，当前设备尚未就绪' }
        'radio_ptt_down_rejected_busy_release_required' { return '本次发送未开始，请松开手咪后重新按下' }
        'downlink_call_bounded_cleanup_incomplete' { return '来话结束清理未完成' }
        'playback_cancelled_and_queue_cleared' { return '来话播放已停止' }
        default { return '' }
    }
}

function Set-ConnectionButtonState {
    $button = Get-UiControl 'ConnectButton'
    if ($OfflinePreview -or $NoAutoConnect) {
        $button.IsEnabled = $false
        $button.Content = '连接'
        return
    }
    if ($script:preparationStarted -or $script:stopTask -or $script:prepareStopAsync) {
        $button.IsEnabled = $false
        $button.Content = '正在处理'
        return
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        $button.IsEnabled = $true
        $button.Content = if ($script:activeTargetTag -and $script:activeTargetTag -cne (Get-SelectedTargetTag)) { '切换目标' } else { '重新连接' }
        return
    }
    $button.IsEnabled = $true
    $button.Content = '连接'
}

function Set-OfflineDisplay {
    param([string]$Reason = '核心尚未启动。')
    Set-MainText -Name 'CoreValue' -Text '未启动'
    Set-MainText -Name 'CoreDetail' -Text $Reason
    Set-MainText -Name 'RadioValue' -Text '未知'
    Set-MainText -Name 'RadioDetail' -Text 'HRI 与电台状态等待本次运行报告'
    Set-MainText -Name 'AudioValue' -Text '未知'
    Set-MainText -Name 'AudioDetail' -Text '输入与输出流状态等待本次运行报告'
    Set-MainText -Name 'BmValue' -Text '未知'
    Set-MainText -Name 'BmDetail' -Text 'BM 连接状态等待本次运行报告'
    Set-MainText -Name 'RecentCaller' -Text '—'
    Set-MainText -Name 'RecentCallDetail' -Text '当前运行还没有来话记录'
    Set-MainText -Name 'CurrentCallValue' -Text '状态等待本次运行报告'
    Set-MainText -Name 'CurrentCallDetail' -Text '当前没有可显示的活动来话。'
    $identityDisplay = Get-UiSourceIdentityDisplay -State 'offline'
    Set-MainText -Name 'HriSourceIdentityValue' -Text $identityDisplay.value
    Set-MainText -Name 'RadioDisplayValue' -Text $identityDisplay.radio_display
    Set-MainText -Name 'TrafficValue' -Text '等待核心状态'
    Set-MainText -Name 'TrafficDetail' -Text '目标选择用于下一次连接。'
    Set-MainText -Name 'RadioStateValue' -Text '电台状态：未知'
    Set-MainText -Name 'RunValue' -Text '未启动'
    Set-MainText -Name 'FreshnessValue' -Text '没有状态报告'
}

function Format-ProfileTarget {
    param([object]$Profile)
    if ($null -eq $Profile) { return '尚未设置' }
    $connection = $Profile.connection
    $slot = [uint64]$connection.slot
    if ($connection.call_kind -ceq 'private') {
        return ('单呼目标 {0} · TS{1}' -f $connection.destination_id, $slot)
    }
    return ('TG {0} · TS{1}' -f $connection.destination_id, $slot)
}

function Get-SelectedTargetTag {
    $selector = Get-UiControl -Name 'TargetSelector'
    if ($null -eq $selector.SelectedItem) { return 'custom' }
    return [string]$selector.SelectedItem.Tag
}

function New-EffectiveTargetProfile {
    param([Parameter(Mandatory=$true)][object]$Profile, [Parameter(Mandatory=$true)][string]$Target)
    $connection = [pscustomobject][ordered]@{
        callsign = [string]$Profile.connection.callsign
        gateway_id = [uint64]$Profile.connection.gateway_id
        source_id = [uint64]$Profile.connection.source_id
        master = [string]$Profile.connection.master
        master_port = [uint64]$Profile.connection.master_port
        destination_id = [uint64]$Profile.connection.destination_id
        slot = [uint64]$Profile.connection.slot
        color_code = [uint64]$Profile.connection.color_code
        call_kind = [string]$Profile.connection.call_kind
    }
    switch ($Target) {
        'parrot-cn' { $connection.destination_id = [uint64]460997; $connection.slot = [uint64]2; $connection.call_kind = 'private' }
        'listen-91' { $connection.destination_id = [uint64]91; $connection.slot = [uint64]2; $connection.call_kind = 'group' }
        'listen-46001' { $connection.destination_id = [uint64]46001; $connection.slot = [uint64]2; $connection.call_kind = 'group' }
        default { }
    }
    return ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $Profile.devices
}

function Test-UiSourceIdentityRecord {
    param([Parameter(Mandatory=$true)][object]$Identity, [Parameter(Mandatory=$true)][object]$ParentRecord)
    if ($Identity -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $expectedNames = @('prepared', 'source_id', 'receive_generation', 'label', 'display')
    $actualNames = @($Identity.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actualNames.Count -ne $expectedNames.Count) { return $false }
    foreach ($name in $expectedNames) {
        if ($actualNames -cnotcontains $name) { return $false }
    }
    if ($Identity.prepared -isnot [bool] -or $Identity.label -isnot [string] -or
        $Identity.display -isnot [string] -or $Identity.display -cne 'unknown') { return $false }

    $numberTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    foreach ($name in @('source_id', 'receive_generation')) {
        $property = $Identity.PSObject.Properties[$name]
        if ($null -eq $property) { return $false }
        $isNumber = $false
        foreach ($type in $numberTypes) {
            if ($property.Value -is $type) { $isNumber = $true; break }
        }
        if (-not $isNumber) { return $false }
        $parsed = [uint64]0
        if (-not [uint64]::TryParse([string]$property.Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $false }
        if ($name -eq 'source_id' -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'source_id') { $sourceId = $parsed } else { $generation = $parsed }
    }

    if ($Identity.prepared) {
        if ($sourceId -eq 0 -or $generation -eq 0 -or $Identity.label.Length -ne 10) { return $false }
        $decimalId = $sourceId.ToString([Globalization.CultureInfo]::InvariantCulture)
        $expectedLabel = ('ID' + $decimalId).PadRight(10, [char]' ')
        if ($Identity.label -cne $expectedLabel) { return $false }
        if ($null -ne $ParentRecord.PSObject.Properties['current_call_valid'] -and
            [bool]$ParentRecord.current_call_valid -and
            ($sourceId -ne [uint64]$ParentRecord.current_call_source_id -or
             $generation -ne [uint64]$ParentRecord.current_call_generation)) { return $false }
    } elseif ($sourceId -ne 0 -or $generation -ne 0 -or $Identity.label.Length -ne 0) {
        return $false
    }
    return $true
}

function Get-UiSourceIdentityDisplay {
    param([object]$Identity, [bool]$IdentityPresent = $true, [string]$State = 'status')
    $value = '当前没有已准备的 HRI 来源标签'
    switch -CaseSensitive ($State) {
        'offline' { $value = '等待本次运行报告' }
        'stale' { $value = '状态已过期，旧标签已清除' }
        'exited' { $value = '本次运行已结束' }
        'legacy' { $value = '当前核心未提供来源标签字段' }
        default {
            if (-not $IdentityPresent) {
                $value = '当前核心未提供来源标签字段'
            } elseif ($Identity.prepared) {
                $value = (([string]$Identity.label).TrimEnd([char]' ') + ' · 已准备')
            }
        }
    }
    return [pscustomobject][ordered]@{
        value = $value
        radio_display = 'FTX-1 屏幕：未知'
    }
}

function Get-UiCompletedRunRecord {
    param([Parameter(Mandatory=$true)][string]$RunDirectory)
    $statusPath = Join-Path $RunDirectory 'status.jsonl'
    if (-not [System.IO.File]::Exists($statusPath)) { return $null }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($statusPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        if ($stream.Length -le 0) { return $null }
        $length = [int][Math]::Min([int64]65536, $stream.Length)
        $buffer = New-Object byte[] $length
        $stream.Position = $stream.Length - $length
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        if (-not $text.EndsWith("`n", [System.StringComparison]::Ordinal)) { return $null }
        $lines = $text.Split([char]10)
        $line = ''
        for ($index = $lines.Count - 2; $index -ge 0; $index--) {
            $candidate = ([string]$lines[$index]).TrimEnd([char]13)
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $line = $candidate; break }
        }
        if (-not $line -or $line.Length -gt 65536) { return $null }
        $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop
        if (-not (Test-UiStatusRecord -Record $record) -or
            $record.run_id -isnot [string] -or $record.event -isnot [string] -or
            $record.event -cnotin @('stopped', 'stopped_with_failure', 'stopped_after_runtime_exception')) { return $null }
        if ($record.run_id -cnotmatch '^([1-9][0-9]*)-[0-9]+$') { return $null }
        $processId = [int]0
        if (-not [int]::TryParse($Matches[1], [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$processId) -or $processId -le 0) { return $null }
        $process = $null
        try {
            $process = [System.Diagnostics.Process]::GetProcessById($processId)
            if (-not $process.HasExited) { return $null }
        } catch [System.ArgumentException] {
            # PID 当前不存在，可将带终态记录的目录纳入保留清理。
        } catch {
            # 无法确认 PID 是否仍在运行时，保留该目录。
            return $null
        } finally {
            if ($process) { $process.Dispose() }
        }
        return [pscustomobject][ordered]@{ run_id = [string]$record.run_id; event = [string]$record.event; process_id = $processId }
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-UiRunDirectorySize {
    param([Parameter(Mandatory=$true)][string]$RunDirectory)
    $total = [int64]0
    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    try {
        $root = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($RunDirectory))
        if (-not $root.Exists -or (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { return $null }
        $directories.Push($root.FullName)
        while ($directories.Count -gt 0) {
            $current = New-Object System.IO.DirectoryInfo($directories.Pop())
            foreach ($entry in $current.GetFileSystemInfos()) {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
                if ($entry -is [System.IO.DirectoryInfo]) {
                    $directories.Push($entry.FullName)
                } elseif ($entry -is [System.IO.FileInfo]) {
                    $length = [int64]$entry.Length
                    if ($length -gt ([int64]::MaxValue - $total)) { return $null }
                    $total += $length
                }
            }
        }
        return $total
    } catch {
        return $null
    }
}

function Invoke-UiRunLogRetention {
    param(
        [Parameter(Mandatory=$true)][string]$RunRoot,
        [Parameter(Mandatory=$true)][string]$ConfigRoot,
        [string]$CurrentRunDirectory = '',
        [int]$MaximumCompletedRuns = 10,
        [int64]$MaximumCompletedBytes = 52428800
    )
    $result = [ordered]@{ removed = 0; retained = 0; retained_bytes = [int64]0; cleanup_errors = 0; skipped_unknown = 0 }
    if ($MaximumCompletedRuns -lt 0 -or $MaximumCompletedBytes -lt 0) { throw 'UI 运行日志保留上限必须大于或等于零。' }
    try {
        $configPath = [System.IO.Path]::GetFullPath($ConfigRoot).TrimEnd('\', '/')
        $rootPath = [System.IO.Path]::GetFullPath($RunRoot).TrimEnd('\', '/')
        $rootPrefix = $configPath + [System.IO.Path]::DirectorySeparatorChar
        if (-not $rootPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([System.IO.Path]::GetDirectoryName($rootPath), $configPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($rootPath) -cne 'ui-runs') { throw 'UI 运行目录不在本机配置目录内。' }
        if (-not [System.IO.Directory]::Exists($rootPath)) { return [pscustomobject]$result }
        $rootInfo = [System.IO.DirectoryInfo]::new($rootPath)
        if (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'UI 运行目录是重解析点，拒绝清理。' }
        $currentPath = ''
        if (-not [string]::IsNullOrWhiteSpace($CurrentRunDirectory)) {
            $currentPath = [System.IO.Path]::GetFullPath($CurrentRunDirectory).TrimEnd('\', '/')
        }
        $eligible = New-Object 'System.Collections.Generic.List[object]'
        foreach ($directory in $rootInfo.GetDirectories()) {
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $directory.Name -cnotmatch '^[0-9a-f]{32}$') { $result.skipped_unknown++; continue }
            if ($currentPath -and [string]::Equals($directory.FullName.TrimEnd('\', '/'), $currentPath,
                    [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $terminalRecord = Get-UiCompletedRunRecord -RunDirectory $directory.FullName
            $size = if ($null -ne $terminalRecord) { Get-UiRunDirectorySize -RunDirectory $directory.FullName } else { $null }
            if ($null -eq $terminalRecord -or $null -eq $size) { $result.skipped_unknown++; continue }
            $eligible.Add([pscustomobject]@{ path = $directory.FullName; name = $directory.Name; bytes = [int64]$size; modified = $directory.LastWriteTimeUtc })
        }
        $orderedRuns = @($eligible | Sort-Object -Property @{Expression='modified';Descending=$true}, @{Expression='name';Descending=$false})
        foreach ($run in $orderedRuns) {
            if ($result.retained -lt $MaximumCompletedRuns -and
                $run.bytes -le ($MaximumCompletedBytes - $result.retained_bytes)) {
                $result.retained++
                $result.retained_bytes += [int64]$run.bytes
                continue
            }
            $target = [System.IO.Path]::GetFullPath([string]$run.path).TrimEnd('\', '/')
            $targetPrefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
            if (-not $target.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([System.IO.Path]::GetDirectoryName($target), $rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                [System.IO.Path]::GetFileName($target) -cnotmatch '^[0-9a-f]{32}$') { throw '待清理的 UI 运行目录越界。' }
            try {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                $result.removed++
            } catch {
                $result.cleanup_errors++
            }
        }
    } catch {
        $result.cleanup_errors++
    }
    return [pscustomobject]$result
}

function Test-UiStatusRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
    if ($Record -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $requiredStrings = @('run_id', 'event', 'bm_state', 'bm_failure', 'radio_state', 'hri_phase', 'wavein_state', 'waveout_state', 'last_rx_call_kind')
    foreach ($name in $requiredStrings) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string]) { return $false }
    }
    $requiredBooleans = @('audio_endpoints_validated', 'hri_serial_open', 'hri_ready', 'hri_y_zero_ready', 'last_rx_header_valid')
    foreach ($name in $requiredBooleans) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [bool]) { return $false }
    }
    $currentCallNames = @(
        'current_call_valid', 'current_call_phase', 'current_call_source_id', 'current_call_destination_id',
        'current_call_slot', 'current_call_kind', 'current_call_color_code',
        'current_call_link_control_validated', 'current_call_color_code_known', 'current_call_generation',
        'receive_media_state'
    )
    $currentCallPresent = 0
    foreach ($name in $currentCallNames) {
        if ($null -ne $Record.PSObject.Properties[$name]) { $currentCallPresent++ }
    }
    if ($currentCallPresent -ne 0 -and $currentCallPresent -ne $currentCallNames.Count) { return $false }
    $hasCurrentCallStatus = $currentCallPresent -eq $currentCallNames.Count
    if ($hasCurrentCallStatus) {
        foreach ($name in @('current_call_valid', 'current_call_link_control_validated', 'current_call_color_code_known')) {
            $property = $Record.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [bool]) { return $false }
        }
        foreach ($name in @('current_call_phase', 'current_call_kind', 'receive_media_state')) {
            $property = $Record.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [string]) { return $false }
        }
    }
    $sourceIdentityProperty = $Record.PSObject.Properties['lcd_source_identity']
    if ($null -ne $sourceIdentityProperty -and
        -not (Test-UiSourceIdentityRecord -Identity $sourceIdentityProperty.Value -ParentRecord $Record)) { return $false }
    $numberTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $numberNames = @('seq', 'timestamp_utc_ms', 'elapsed_ms', 'last_rx_source_id', 'last_rx_destination_id', 'last_rx_slot')
    if ($hasCurrentCallStatus) {
        $numberNames += @('current_call_source_id', 'current_call_destination_id', 'current_call_slot',
            'current_call_color_code', 'current_call_generation')
    }
    foreach ($name in $numberNames) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -eq $property) { return $false }
        $isNumber = $false
        foreach ($type in $numberTypes) {
            if ($property.Value -is $type) { $isNumber = $true; break }
        }
        if (-not $isNumber) { return $false }
        $parsed = [uint64]0
        if (-not [uint64]::TryParse([string]$property.Value, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $false }
        if ($name -eq 'seq' -and $parsed -eq 0) { return $false }
        if ($name -eq 'timestamp_utc_ms' -and $parsed -gt 253402300799999) { return $false }
        if ($name -eq 'last_rx_source_id' -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'last_rx_destination_id' -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'last_rx_slot' -and $parsed -notin @(1, 2)) { return $false }
        if ($name -in @('current_call_source_id', 'current_call_destination_id') -and $parsed -gt 16777215) { return $false }
        if ($name -eq 'current_call_slot' -and $parsed -gt 2) { return $false }
        if ($name -eq 'current_call_color_code' -and $parsed -gt 15) { return $false }
    }
    if ($Record.bm_state -cnotin @('idle', 'waiting_login_ack', 'waiting_auth_ack', 'waiting_config_ack', 'waiting_options_ack', 'ready', 'backoff', 'stopped')) { return $false }
    if ($Record.bm_failure -cnotin @('none', 'invalid_profile', 'login_timeout', 'auth_timeout', 'config_timeout', 'options_timeout',
            'pong_timeout', 'master_rejected', 'master_closed', 'malformed_response', 'unexpected_response', 'wrong_peer_id',
            'authentication_error', 'inbound_queue_full', 'transport_lost', 'outbound_queue_full', 'unknown')) { return $false }
    if ($Record.radio_state -cne 'unknown') { return $false }
    if ($Record.hri_phase -cnotin @('not_started', 'awaiting_version_write', 'awaiting_version', 'waiting_for_y_due', 'exchanging', 'stopped', 'unknown')) { return $false }
    if ($Record.wavein_state -cnotin @('open', 'closed') -or $Record.waveout_state -cnotin @('open', 'closed')) { return $false }
    if ($Record.last_rx_call_kind -cnotin @('G', 'P')) { return $false }
    if ($hasCurrentCallStatus) {
        if ($Record.current_call_kind -cnotin @('none', 'G', 'P')) { return $false }
        if ($Record.current_call_phase -cnotin @('none', 'waiting_for_playback', 'buffering', 'playing')) { return $false }
        if ($Record.receive_media_state -cnotin @('idle', 'filtered', 'waiting_for_playback', 'buffering', 'playing', 'draining')) { return $false }
        $activeMedia = $Record.receive_media_state -cin @('waiting_for_playback', 'buffering', 'playing')
        if ([bool]$Record.current_call_valid -ne $activeMedia) { return $false }
        if ([bool]$Record.current_call_valid) {
            if ($Record.current_call_phase -cne $Record.receive_media_state -or
                [uint64]$Record.current_call_source_id -eq 0 -or
                [uint64]$Record.current_call_destination_id -eq 0 -or
                [uint64]$Record.current_call_slot -notin @(1, 2) -or
                $Record.current_call_kind -cnotin @('G', 'P') -or
                [uint64]$Record.current_call_generation -eq 0 -or
                (-not [bool]$Record.current_call_color_code_known -and [uint64]$Record.current_call_color_code -ne 0)) {
                return $false
            }
        } elseif ($Record.current_call_phase -cne 'none' -or
            [uint64]$Record.current_call_source_id -ne 0 -or
            [uint64]$Record.current_call_destination_id -ne 0 -or
            [uint64]$Record.current_call_slot -ne 0 -or
            $Record.current_call_kind -cne 'none' -or
            [uint64]$Record.current_call_color_code -ne 0 -or
            [bool]$Record.current_call_link_control_validated -or
            [bool]$Record.current_call_color_code_known -or
            [uint64]$Record.current_call_generation -ne 0) {
            return $false
        }
    }
    if ([string]$Record.event -cnotmatch '^[a-z0-9_]{1,96}$') { return $false }
    return $true
}

function Test-UiStatusFreshness {
    param([uint64]$TimestampUtcMs, [int64]$NowUtcMs)
    if ($TimestampUtcMs -gt 253402300799999) { return $false }
    $ageMs = $NowUtcMs - [int64]$TimestampUtcMs
    return ($ageMs -le 3000 -and $ageMs -ge -5000)
}

function Test-UiRunRecordAcceptance {
    param([Parameter(Mandatory=$true)][object]$Record, [Parameter(Mandatory=$true)][uint32]$ExpectedProcessId,
        [string]$LockedRunId, [uint64]$LastSequence = 0, [Parameter(Mandatory=$true)][int64]$NowUtcMs)
    if (-not (Test-UiStatusRecord -Record $Record)) { return $false }
    if ([string]$Record.run_id -cnotmatch ('^' + $ExpectedProcessId.ToString([Globalization.CultureInfo]::InvariantCulture) + '-[0-9]+$')) { return $false }
    if ($LockedRunId -and [string]$Record.run_id -cne $LockedRunId) { return $false }
    $sequence = [uint64]0
    if (-not [uint64]::TryParse([string]$Record.seq, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$sequence) -or $sequence -le $LastSequence) { return $false }
    return (Test-UiStatusFreshness -TimestampUtcMs ([uint64]$Record.timestamp_utc_ms) -NowUtcMs $NowUtcMs)
}

function Test-UiPreparationRecord {
    param(
        [Parameter(Mandatory=$true)][object]$Record,
        [Parameter(Mandatory=$true)][string]$RunDirectory,
        [Parameter(Mandatory=$true)][string]$RunRoot,
        [Parameter(Mandatory=$true)][string]$ExpectedExecutable
    )
    if ($Record -isnot [System.Management.Automation.PSCustomObject] -or
        $Record.schema_version -is [bool] -or
        -not ($Record.schema_version -is [int] -or $Record.schema_version -is [long]) -or
        $Record.schema_version -ne 1 -or
        $Record.executable -isnot [string] -or
        $Record.status_path -isnot [string] -or
        $Record.arguments -isnot [System.Array]) {
        throw '设备预检返回的启动参数结构无效。'
    }

    $runPath = [System.IO.Path]::GetFullPath($RunDirectory)
    $runParent = [System.IO.Path]::GetFullPath($RunRoot)
    $runGuid = [guid]::Empty
    if (-not [guid]::TryParseExact([System.IO.Path]::GetFileName($runPath), 'N', [ref]$runGuid) -or
        -not [string]::Equals([System.IO.Path]::GetDirectoryName($runPath).TrimEnd('\'),
            $runParent.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '本次启动目录不属于 UI 创建的 GUID 运行目录。'
    }

    $expectedExe = [System.IO.Path]::GetFullPath($ExpectedExecutable)
    $recordExe = [System.IO.Path]::GetFullPath($Record.executable)
    if (-not [System.IO.File]::Exists($expectedExe) -or
        -not [string]::Equals($recordExe, $expectedExe, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '设备预检返回的 native 核心与当前所选便携目录不符。'
    }

    $statusPath = [System.IO.Path]::GetFullPath($Record.status_path)
    $statusDirectory = [System.IO.Path]::GetDirectoryName($statusPath)
    $statusName = [System.IO.Path]::GetFileName($statusPath)
    if (-not [string]::Equals($statusDirectory.TrimEnd('\'), $runPath.TrimEnd('\'),
            [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace($statusName) -or
        -not [string]::Equals([System.IO.Path]::GetExtension($statusName), '.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '设备预检返回的状态文件不属于本次启动目录。'
    }

    $arguments = @($Record.arguments)
    if ($arguments.Count -lt 20 -or @($arguments | Where-Object { $_ -isnot [string] }).Count -ne 0) {
        throw '设备预检返回的启动参数不完整。'
    }
    $pipeCount = 0
    $statusValue = ''
    $statusCount = 0
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        if ($arguments[$index] -ceq '--ui-pipe') { $pipeCount++ }
        if ($arguments[$index] -ceq '--status-file') {
            $statusCount++
            if ($index + 1 -ge $arguments.Count) { throw '设备预检返回的状态参数缺少路径。' }
            $statusValue = [string]$arguments[$index + 1]
        }
    }
    if ($pipeCount -ne 1 -or $statusCount -ne 1 -or
        -not [string]::Equals([System.IO.Path]::GetFullPath($statusValue), $statusPath,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '设备预检返回的启动参数与状态文件路径不一致。'
    }
    return [pscustomobject]@{
        Executable = $expectedExe
        Arguments = [string[]]$arguments
        StatusPath = $statusPath
    }
}

function Start-UiAudioQuery {
    param([Parameter(Mandatory=$true)][string]$Executable, [string]$Arguments = '--list-audio-json', [int]$TimeoutMilliseconds = 10000)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '未能启动音频设备查询进程。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        return [pscustomobject]@{
            Process = $process
            StdoutTask = $stdoutTask
            StderrTask = $stderrTask
            StartedUtc = [DateTime]::UtcNow
            TimeoutMilliseconds = $TimeoutMilliseconds
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Request-StopUiAudioQuery {
    param([Parameter(Mandatory=$true)][object]$Query)
    if (-not $Query.Process.HasExited) {
        try { $Query.Process.Kill() }
        catch {
            if (-not $Query.Process.HasExited) { throw '无法停止音频设备查询进程。' }
        }
    }
}

function Test-UiAudioQueryExpired {
    param([Parameter(Mandatory=$true)][object]$Query, [DateTime]$NowUtc = [DateTime]::UtcNow)
    return (($NowUtc - $Query.StartedUtc).TotalMilliseconds -ge $Query.TimeoutMilliseconds)
}

function Read-UiAudioQueryResult {
    param([Parameter(Mandatory=$true)][object]$Query)
    if (-not $Query.Process.HasExited -or -not $Query.StdoutTask.IsCompleted -or -not $Query.StderrTask.IsCompleted) {
        return [pscustomobject]@{ Completed = $false; Audio = $null }
    }
    if ($Query.Process.ExitCode -ne 0) { throw 'native 音频设备查询失败。' }
    $json = $Query.StdoutTask.GetAwaiter().GetResult().Trim().TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($json) -or $json.Contains("`n") -or $json.Contains("`r")) {
        throw 'native 音频设备查询必须只输出一行 JSON。'
    }
    $audio = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    if ($null -eq $audio -or $audio.schema_version -ne 1 -or $audio.type -cne 'audio_devices' -or
        -not $audio.PSObject.Properties['wave_inputs'] -or -not $audio.PSObject.Properties['wave_outputs']) {
        throw 'native 音频设备列表格式无效。'
    }
    foreach ($direction in @('wave_inputs', 'wave_outputs')) {
        $seenIds = @{}
        $seenEndpoints = @{}
        foreach ($device in @($audio.$direction)) {
            if ($null -eq $device -or $device.name -isnot [string] -or
                $device.pcm_48000_mono_s16_supported -isnot [bool] -or
                ($null -ne $device.endpoint_id -and $device.endpoint_id -isnot [string]) -or
                $device.id -is [bool] -or -not ($device.id -is [int] -or $device.id -is [long]) -or $device.id -lt 0) {
                throw 'native 音频设备列表包含无效项目。'
            }
            if ($seenIds.ContainsKey([string]$device.id)) { throw 'native 音频设备列表包含重复 WinMM ID。' }
            $seenIds[[string]$device.id] = $true
            if ($device.endpoint_id -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$device.endpoint_id)) {
                $key = ([string]$device.endpoint_id).ToUpperInvariant()
                if ($seenEndpoints.ContainsKey($key)) { throw 'native 音频设备列表包含重复稳定端点标识。' }
                $seenEndpoints[$key] = $true
            }
        }
    }
    return [pscustomobject]@{ Completed = $true; Audio = $audio }
}

function Test-UiDiscoveryResultOwner {
    param([uint64]$ResultGeneration, [uint64]$CurrentGeneration, [object]$ResultWindow, [object]$CurrentWindow)
    return ($ResultGeneration -eq $CurrentGeneration -and
        [object]::ReferenceEquals($ResultWindow, $CurrentWindow) -and $null -ne $CurrentWindow)
}

function Start-UiDeviceDiscovery {
    if ($OfflinePreview -or $RenderOnly) {
        $script:deviceDiscoveryState = 'offline'
        Set-SettingsDeviceControls
        return
    }
    if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) {
        if ($script:settingsWindow -and -not [object]::ReferenceEquals($script:settingsWindow, $script:deviceDiscoveryOwnerWindow)) {
            $script:deviceDiscoveryRestartPending = $true
            (Get-SettingsControl 'DeviceDiscoveryText').Text = '正在结束上次查询，随后重新读取设备列表。'
            (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
        }
        return
    }

    $script:deviceDiscoveryGeneration++
    $script:deviceDiscoveryActiveGeneration = $script:deviceDiscoveryGeneration
    $script:deviceDiscoveryOwnerWindow = $script:settingsWindow
    $script:deviceDiscoveryStopReason = ''
    $script:deviceDiscoveryError = ''
    $script:deviceDiscoveryState = 'loading'
    if ($script:settingsWindow) {
        (Get-SettingsControl 'DeviceDiscoveryText').Text = '正在读取串口与音频设备列表。'
        (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $false
        Set-SettingsDeviceControls
    }
    try {
        $script:deviceAudioQuery = Start-UiAudioQuery -Executable $script:nativeExecutable
    } catch {
        $script:deviceDiscoveryState = 'failed'
        $script:deviceDiscoveryError = $_.Exception.Message
        Set-SettingsDeviceControls
        if ($script:settingsWindow) { (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $true }
        return
    }
    $catalogScript = {
        $ErrorActionPreference = 'Stop'
        $serialNames = @{}
        $serialKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DEVICEMAP\SERIALCOMM', $false)
        if ($serialKey) {
            try {
                foreach ($valueName in $serialKey.GetValueNames()) {
                    $port = [string]$serialKey.GetValue($valueName)
                    if ($port -match '^COM[1-9][0-9]{0,2}$') { $serialNames[$port.ToUpperInvariant()] = [pscustomobject]@{ PortName = $port.ToUpperInvariant(); FriendlyName = ''; InstanceId = ''; IsHri = $false } }
                }
            } finally { $serialKey.Dispose() }
        }
        $hriPorts = @{}
        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            foreach ($device in @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue)) {
                $instanceId = [string]$device.InstanceId
                $identity = [regex]::Match($instanceId, '^USB\\VID_26AA&PID_([0-9A-F]{4})\\', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $identity.Success -or [Convert]::ToInt32($identity.Groups[1].Value, 16) -lt 0x0030) { continue }
                $busDescription = ''
                if (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue) {
                    $property = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction SilentlyContinue
                    if ($property) { $busDescription = [string]$property.Data }
                }
                $friendlyName = [string]$device.FriendlyName
                $portMatch = [regex]::Match($friendlyName, '\((COM[1-9][0-9]*)\)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $portMatch.Success) { continue }
                $portName = $portMatch.Groups[1].Value.ToUpperInvariant()
                $hriPorts[$portName] = [pscustomobject]@{
                    PortName = $portName
                    FriendlyName = $friendlyName
                    InstanceId = $instanceId
                    IsHri = ($busDescription -match '(?i)\bHRI\b')
                }
            }
        }
        foreach ($portName in @($hriPorts.Keys)) { $serialNames[$portName] = $hriPorts[$portName] }
        return [pscustomobject]@{
            serial_ports = @($serialNames.Values | Sort-Object PortName)
            hri_ports = @($hriPorts.Values | Where-Object { $_.IsHri } | Sort-Object PortName)
        }
    }
    try {
        $script:deviceDiscoveryPowerShell = [System.Management.Automation.PowerShell]::Create()
        [void]$script:deviceDiscoveryPowerShell.AddScript($catalogScript.ToString())
        $script:deviceDiscoveryStartedUtc = [DateTime]::UtcNow
        $script:deviceDiscoveryAsync = $script:deviceDiscoveryPowerShell.BeginInvoke()
    } catch {
        if ($script:deviceDiscoveryPowerShell) {
            try { $script:deviceDiscoveryPowerShell.Dispose() } catch { }
            $script:deviceDiscoveryPowerShell = $null
        }
        $script:deviceDiscoveryAsync = $null
        $script:deviceDiscoveryState = 'stopping'
        $script:deviceDiscoveryStopReason = 'serial_start_error'
        $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
        $script:deviceDiscoveryError = $_.Exception.Message
        if ($script:deviceAudioQuery) {
            try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
            catch { $script:deviceDiscoveryError = $_.Exception.Message }
        }
    }
}

function New-UiDeviceOption {
    param([string]$Label, [string]$Value, [bool]$IsAvailable, [string]$Kind)
    return [pscustomobject]@{ Label = $Label; Value = $Value; IsAvailable = $IsAvailable; Kind = $Kind }
}

function Get-UiEndpointOptions {
    param([object[]]$Devices, [string]$SavedEndpoint, [ValidateSet('input', 'output')][string]$Direction, [switch]$DiscoveryPending)
    $usable = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -eq $true -and $_.endpoint_id -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    $options = New-Object 'System.Collections.Generic.List[object]'
    [void]$options.Add((New-UiDeviceOption -Label '自动：唯一 USB Audio 端点' -Value 'auto' -IsAvailable $true -Kind 'auto'))
    foreach ($device in @($usable | Sort-Object name, endpoint_id)) {
        $label = ('{0} · {1} · ID {2}' -f [string]$device.name, [string]$device.endpoint_id, [string]$device.id)
        [void]$options.Add((New-UiDeviceOption -Label $label -Value ([string]$device.endpoint_id) -IsAvailable $true -Kind $Direction))
    }
    $selected = 'auto'
    if ($SavedEndpoint -and $SavedEndpoint -cne 'auto') {
        $matches = @($usable | Where-Object { [string]::Equals([string]$_.endpoint_id, $SavedEndpoint, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -eq 1) {
            $selected = [string]$matches[0].endpoint_id
        } else {
            $missingLabel = if ($DiscoveryPending) { '正在检查已保存端点 · ' + $SavedEndpoint } else { '已保存端点当前未发现 · ' + $SavedEndpoint }
            $missingKind = if ($DiscoveryPending) { 'pending' } else { 'missing' }
            [void]$options.Add((New-UiDeviceOption -Label $missingLabel -Value $SavedEndpoint -IsAvailable ([bool]$DiscoveryPending) -Kind $missingKind))
            $selected = $SavedEndpoint
        }
    } else {
        $usbMatches = @($usable | Where-Object { [string]$_.name -match '(?i)USB Audio' })
        if ($usbMatches.Count -eq 1) { $selected = [string]$usbMatches[0].endpoint_id }
    }
    return [pscustomobject]@{ Items = $options.ToArray(); SelectedValue = $selected; UsableCount = $usable.Count }
}

function Get-UiSerialOptions {
    param([object[]]$AllPorts, [object[]]$HriPorts, [string]$SavedPort = 'auto', [switch]$DiscoveryPending)
    $options = New-Object 'System.Collections.Generic.List[object]'
    [void]$options.Add((New-UiDeviceOption -Label '自动：唯一 HRI 设备' -Value 'auto' -IsAvailable $true -Kind 'auto'))
    foreach ($port in @($AllPorts | Sort-Object @{Expression={ if ($_.IsHri -and $_.PortName -ceq 'COM5') { 0 } elseif ($_.IsHri) { 1 } else { 2 } }}, PortName)) {
        $identity = if ($port.IsHri) { 'HRI' } elseif ($port.FriendlyName) { '未确认 HRI' } else { '设备信息未确认' }
        $friendly = if ($port.FriendlyName) { [string]$port.FriendlyName } else { [string]$port.PortName }
        [void]$options.Add((New-UiDeviceOption -Label ('{0} · {1} · {2}' -f $friendly, $port.PortName, $identity) `
            -Value ([string]$port.PortName) -IsAvailable ([bool]$port.IsHri) -Kind 'serial'))
    }
    $selected = 'auto'
    if ($SavedPort -and $SavedPort -cne 'auto') {
        $matches = @($HriPorts | Where-Object { $_.PortName -ieq $SavedPort })
        if ($matches.Count -eq 1) { $selected = [string]$matches[0].PortName }
        else {
            $missingLabel = if ($DiscoveryPending) { '正在检查已保存 HRI 串口 · ' + $SavedPort } else { '已保存串口当前未发现为 HRI · ' + $SavedPort }
            $missingKind = if ($DiscoveryPending) { 'pending' } else { 'missing' }
            [void]$options.Add((New-UiDeviceOption -Label $missingLabel -Value $SavedPort -IsAvailable ([bool]$DiscoveryPending) -Kind $missingKind))
            $selected = $SavedPort
        }
    } else {
        $com5 = @($HriPorts | Where-Object { $_.PortName -ceq 'COM5' })
        if ($com5.Count -eq 1) { $selected = 'COM5' }
        elseif ($HriPorts.Count -eq 1) { $selected = [string]$HriPorts[0].PortName }
    }
    return [pscustomobject]@{ Items = $options.ToArray(); SelectedValue = $selected; HriCount = $HriPorts.Count }
}

function Set-UiDeviceComboOptions {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo,
        [Parameter(Mandatory=$true)][object[]]$Options,
        [Parameter(Mandatory=$true)][string]$SelectedValue)
    $Combo.Items.Clear()
    $selectedContainer = $null
    foreach ($option in $Options) {
        if ($null -eq $option -or $option.Label -isnot [string] -or $option.Value -isnot [string] -or $option.IsAvailable -isnot [bool]) {
            throw '设备选项缺少显示标签或稳定值。'
        }
        $container = New-Object System.Windows.Controls.ComboBoxItem
        $container.Content = [string]$option.Label
        $container.Tag = $option
        $container.ToolTip = [string]$option.Label
        [void]$Combo.Items.Add($container)
        if ([string]::Equals([string]$option.Value, $SelectedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            $selectedContainer = $container
        }
    }
    $Combo.SelectedItem = $selectedContainer
    if ($null -eq $selectedContainer) { throw '当前设备选择没有对应的列表项。' }
}

function Set-SettingsDeviceControls {
    if (-not $script:settingsWindow) { return }
    $serialControl = Get-SettingsControl 'SerialBox'
    $inputControl = Get-SettingsControl 'WaveInEndpointBox'
    $outputControl = Get-SettingsControl 'WaveOutEndpointBox'
    $savedSerial = if ($script:storedProfile) { [string]$script:storedProfile.devices.serial_port } else { 'auto' }
    $savedInput = if ($script:storedProfile) { [string]$script:storedProfile.devices.wave_in_endpoint_id } else { 'auto' }
    $savedOutput = if ($script:storedProfile) { [string]$script:storedProfile.devices.wave_out_endpoint_id } else { 'auto' }
    $catalog = $script:deviceCatalog
    $allPorts = if ($catalog) { @($catalog.serial_ports) } else { @() }
    $hriPorts = if ($catalog) { @($catalog.hri_ports) } else { @() }
    $discoveryPending = ($script:deviceDiscoveryState -in @('not_started', 'loading', 'stopping'))
    $serialSetup = Get-UiSerialOptions -AllPorts $allPorts -HriPorts $hriPorts -SavedPort $savedSerial -DiscoveryPending:$discoveryPending
    Set-UiDeviceComboOptions -Combo $serialControl -Options $serialSetup.Items -SelectedValue $serialSetup.SelectedValue

    $inputCatalog = if ($catalog) { @($catalog.wave_inputs) } else { @() }
    $outputCatalog = if ($catalog) { @($catalog.wave_outputs) } else { @() }
    $inputOptions = Get-UiEndpointOptions -Devices $inputCatalog -SavedEndpoint $savedInput -Direction input -DiscoveryPending:$discoveryPending
    $outputOptions = Get-UiEndpointOptions -Devices $outputCatalog -SavedEndpoint $savedOutput -Direction output -DiscoveryPending:$discoveryPending
    Set-UiDeviceComboOptions -Combo $inputControl -Options $inputOptions.Items -SelectedValue $inputOptions.SelectedValue
    Set-UiDeviceComboOptions -Combo $outputControl -Options $outputOptions.Items -SelectedValue $outputOptions.SelectedValue

    if ($script:deviceDiscoveryState -eq 'ready') {
        (Get-SettingsControl 'DeviceDiscoveryText').Text = '设备列表已更新；自动选择优先使用 COM5/HRI 和 USB Audio。'
    } elseif ($script:deviceDiscoveryState -eq 'failed') {
        $detail = if ($script:deviceDiscoveryError) { ' · ' + $script:deviceDiscoveryError } else { '' }
        (Get-SettingsControl 'DeviceDiscoveryText').Text = ('设备查询失败，可保留 auto；连接前会再次核验设备。' + $detail)
    } elseif ($script:deviceDiscoveryState -eq 'offline') {
        (Get-SettingsControl 'DeviceDiscoveryText').Text = '离线预览不读取本机设备。'
    }
}

function Complete-UiDeviceDiscovery {
    if (-not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery) { return }
    if (-not $script:deviceDiscoveryStopAsync -and $script:deviceDiscoveryState -eq 'loading') {
        if ($script:deviceAudioQuery -and (Test-UiAudioQueryExpired -Query $script:deviceAudioQuery)) {
            $script:deviceDiscoveryState = 'stopping'
            $script:deviceDiscoveryStopReason = 'audio_timeout'
            $script:deviceDiscoveryError = '音频设备查询超过 10 秒，已请求停止。'
        } elseif (([DateTime]::UtcNow - $script:deviceDiscoveryStartedUtc).TotalSeconds -gt 25) {
            $script:deviceDiscoveryState = 'stopping'
            $script:deviceDiscoveryStopReason = 'timeout'
            $script:deviceDiscoveryError = '本机设备查询超过 25 秒，已请求停止。'
        }
        if ($script:deviceDiscoveryStopReason) {
            $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
            if ($script:deviceAudioQuery) {
                try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
                catch { $script:deviceDiscoveryError = $_.Exception.Message }
            }
            if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted) {
                try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) }
                catch { if (-not $script:deviceDiscoveryAsync.IsCompleted) { $script:deviceDiscoveryError = '串口设备查询未能及时停止。' } }
            }
            if ($script:settingsWindow -and [object]::ReferenceEquals($script:settingsWindow, $script:deviceDiscoveryOwnerWindow)) {
                (Get-SettingsControl 'DeviceDiscoveryText').Text = '正在停止设备查询。'
            }
        }
    }

    $generation = $script:deviceDiscoveryActiveGeneration
    $ownerWindow = $script:deviceDiscoveryOwnerWindow
    $resultBelongsToWindow = Test-UiDiscoveryResultOwner -ResultGeneration $generation `
        -CurrentGeneration $script:deviceDiscoveryGeneration -ResultWindow $ownerWindow -CurrentWindow $script:settingsWindow
    $acceptResult = $resultBelongsToWindow
    $audioDone = ($null -eq $script:deviceAudioQuery)
    $audio = $null
    if ($script:deviceAudioQuery) {
        if ($script:deviceDiscoveryStopReason) {
            $query = $script:deviceAudioQuery
            if ($query.Process.HasExited -and $query.StdoutTask.IsCompleted -and $query.StderrTask.IsCompleted) {
                $query.Process.Dispose()
                $script:deviceAudioQuery = $null
                $audioDone = $true
            }
        } else {
            try {
                $audioResult = Read-UiAudioQueryResult -Query $script:deviceAudioQuery
                if ($audioResult.Completed) {
                    $audio = $audioResult.Audio
                    $script:deviceAudioQuery.Process.Dispose()
                    $script:deviceAudioQuery = $null
                    $audioDone = $true
                }
            } catch {
                $script:deviceDiscoveryError = $_.Exception.Message
                $query = $script:deviceAudioQuery
                if ($query.Process.HasExited -and $query.StdoutTask.IsCompleted -and $query.StderrTask.IsCompleted) {
                    try { $query.Process.Dispose() } catch { }
                    $script:deviceAudioQuery = $null
                    $audioDone = $true
                }
                if (-not $script:deviceDiscoveryStopReason) {
                    $script:deviceDiscoveryState = 'stopping'
                    $script:deviceDiscoveryStopReason = 'audio_error'
                    $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
                    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted) {
                        try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) } catch { }
                    }
                }
            }
        }
    }

    $serialDone = ($null -eq $script:deviceDiscoveryPowerShell)
    $serialRecords = $null
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync) {
        if ($script:deviceDiscoveryStopAsync) {
            $serialDone = $script:deviceDiscoveryStopAsync.IsCompleted
        } elseif ($script:deviceDiscoveryAsync.IsCompleted) {
            $serialDone = $true
            try {
                $serialRecords = $script:deviceDiscoveryPowerShell.EndInvoke($script:deviceDiscoveryAsync)
                if ($script:deviceDiscoveryPowerShell.HadErrors -or $serialRecords.Count -ne 1) {
                    throw '串口设备查询没有返回有效列表。'
                }
            } catch {
                $script:deviceDiscoveryError = $_.Exception.Message
                $script:deviceDiscoveryState = 'failed'
                $script:deviceDiscoveryStopReason = 'serial_error'
            }
        }
    }

    if (-not $audioDone -or -not $serialDone) {
        if ($script:closingAfterDeviceDiscovery -and $script:deviceDiscoveryStopStartedUtc -ne [DateTime]::MinValue -and
            ([DateTime]::UtcNow - $script:deviceDiscoveryStopStartedUtc).TotalSeconds -gt 5) {
            [System.Environment]::Exit(2)
        }
        return
    }

    try {
        if ($script:deviceDiscoveryStopAsync) {
            try { $script:deviceDiscoveryPowerShell.EndStop($script:deviceDiscoveryStopAsync) } catch { }
            $acceptResult = $false
        } elseif ($script:deviceDiscoveryStopReason) {
            $acceptResult = $false
        } elseif ($serialRecords -and $audio) {
            $serialCatalog = $serialRecords[0]
            if ($serialCatalog.serial_ports -isnot [array] -or $serialCatalog.hri_ports -isnot [array]) {
                throw '串口设备列表结构无效。'
            }
            $catalog = [pscustomobject]@{
                serial_ports = @($serialCatalog.serial_ports)
                hri_ports = @($serialCatalog.hri_ports)
                wave_inputs = @($audio.wave_inputs)
                wave_outputs = @($audio.wave_outputs)
            }
            if ($acceptResult) { $script:deviceCatalog = $catalog; $script:deviceDiscoveryState = 'ready' }
        } elseif ($script:deviceDiscoveryState -ne 'failed') {
            throw '设备查询没有返回完整的串口与音频列表。'
        }
    } catch {
        if ($acceptResult) {
            $script:deviceCatalog = $null
            $script:deviceDiscoveryState = 'failed'
            $script:deviceDiscoveryError = $_.Exception.Message
        }
    } finally {
        $finalStopReason = [string]$script:deviceDiscoveryStopReason
        if ($resultBelongsToWindow -and $finalStopReason -and $finalStopReason -cne 'window_closed') {
            $script:deviceCatalog = $null
            $script:deviceDiscoveryState = 'failed'
        }
        if ($script:deviceDiscoveryPowerShell) { $script:deviceDiscoveryPowerShell.Dispose() }
        $script:deviceDiscoveryPowerShell = $null
        $script:deviceDiscoveryAsync = $null
        $script:deviceDiscoveryStopAsync = $null
        $script:deviceDiscoveryOwnerWindow = $null
        $script:deviceDiscoveryStopReason = ''
    }
    if ($resultBelongsToWindow) { Set-SettingsDeviceControls }
    if ($resultBelongsToWindow -and $script:settingsWindow) { (Get-SettingsControl 'RefreshDevicesButton').IsEnabled = $true }
    if ($script:closingAfterDeviceDiscovery) {
        $script:closingAfterDeviceDiscovery = $false
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return
    }
    if ($script:deviceDiscoveryRestartPending -and $script:settingsWindow) {
        $script:deviceDiscoveryRestartPending = $false
        Start-UiDeviceDiscovery
    }
}

function Invalidate-UiDeviceDiscoveryForWindow {
    param([Parameter(Mandatory=$true)][object]$Window)
    if (-not [object]::ReferenceEquals($Window, $script:deviceDiscoveryOwnerWindow)) { return }
    $script:deviceDiscoveryGeneration++
    $script:deviceDiscoveryRestartPending = $false
    $script:deviceDiscoveryStopReason = 'window_closed'
    $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
    if ($script:deviceAudioQuery) {
        try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
        catch { $script:deviceDiscoveryError = $_.Exception.Message }
    }
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and
        -not $script:deviceDiscoveryAsync.IsCompleted -and -not $script:deviceDiscoveryStopAsync) {
        try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) }
        catch { $script:deviceDiscoveryError = '串口设备查询未能及时停止。' }
    }
}

function Read-CurrentPasswordPath {
    try { return Get-BridgePasswordFile -UserConfigDirectory $script:configDirectory }
    catch { return '' }
}

function Set-GainValueLabel {
    param([string]$SliderName, [string]$LabelName)
    $value = [double](Get-SettingsControl $SliderName).Value
    $milli = Convert-UiGainSliderToMilli -Value $value
    (Get-SettingsControl $LabelName).Text = ((Format-BridgeGain -GainMilli $milli) + 'x')
}

function Convert-UiGainSliderToMilli {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -lt 0.25 -or $Value -gt 16.0) {
        throw '音量增益必须在 0.25x 到 16x 之间。'
    }
    return [uint32][Math]::Round($Value * 1000.0, [MidpointRounding]::AwayFromZero)
}

function Set-SettingsWindowFields {
    $profileError = ''
    $audioError = ''
    try { $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath }
    catch { $script:storedProfile = $null; $profileError = $_.Exception.Message }
    try { $audio = Read-BridgeAudioSettings -Path $script:audioSettingsPath }
    catch { $audio = $null; $audioError = $_.Exception.Message }
    if ($null -eq $audio) { $audio = [pscustomobject]@{ RadioPlaybackGainMilli = [uint32]1000; MicTransmitGainMilli = [uint32]16000 } }
    $fields = @{
        CallsignBox = if ($script:storedProfile) { $script:storedProfile.connection.callsign } else { '' }
        GatewayBox = if ($script:storedProfile) { $script:storedProfile.connection.gateway_id } else { '' }
        SourceBox = if ($script:storedProfile) { $script:storedProfile.connection.source_id } else { '' }
        MasterBox = if ($script:storedProfile) { $script:storedProfile.connection.master } else { '' }
        MasterPortBox = if ($script:storedProfile) { $script:storedProfile.connection.master_port } else { '' }
        DestinationBox = if ($script:storedProfile) { $script:storedProfile.connection.destination_id } else { '' }
        ColorCodeBox = if ($script:storedProfile) { $script:storedProfile.connection.color_code } else { '' }
        PasswordPathBox = Read-CurrentPasswordPath
    }
    foreach ($name in $fields.Keys) { (Get-SettingsControl $name).Text = [string]$fields[$name] }
    (Get-SettingsControl 'PlaybackGainSlider').Value = [double]$audio.RadioPlaybackGainMilli / 1000.0
    (Get-SettingsControl 'TransmitGainSlider').Value = [double]$audio.MicTransmitGainMilli / 1000.0
    Set-GainValueLabel -SliderName 'PlaybackGainSlider' -LabelName 'PlaybackGainValueText'
    Set-GainValueLabel -SliderName 'TransmitGainSlider' -LabelName 'TransmitGainValueText'
    Set-SettingsDeviceControls
    $slotBox = Get-SettingsControl 'SlotBox'
    $slotValue = if ($script:storedProfile) { [string]$script:storedProfile.connection.slot } else { '2' }
    $slotBox.SelectedItem = @($slotBox.Items | Where-Object { [string]$_.Tag -ceq $slotValue })[0]
    $kindBox = Get-SettingsControl 'CallKindBox'
    $kindValue = if ($script:storedProfile) { [string]$script:storedProfile.connection.call_kind } else { 'private' }
    $kindBox.SelectedItem = @($kindBox.Items | Where-Object { [string]$_.Tag -ceq $kindValue })[0]
    if ($profileError -or $audioError) {
        $readErrors = @($profileError, $audioError | Where-Object { $_ }) -join '；'
        (Get-SettingsControl 'SettingsErrorText').Text = ('有本机设置无法读取，请检查并重新保存。' + $readErrors)
        (Get-SettingsControl 'SettingsErrorText').Foreground = [Windows.Media.Brushes]::IndianRed
    } elseif ($script:storedProfile) {
        (Get-SettingsControl 'SettingsErrorText').Text = '保存后，下次连接时使用新设置。'
    } else {
        (Get-SettingsControl 'SettingsErrorText').Text = '请填写连接信息后保存。'
    }
}

function Initialize-SettingsWindow {
    $script:settingsWindow = Import-WpfWindow -Path $script:settingsXamlPath
    $script:deviceCatalog = $null
    $script:deviceDiscoveryState = if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) { 'stopping' } else { 'not_started' }
    Fit-WpfWindowToWorkArea -Window $script:settingsWindow
    $script:settingsWindow.Owner = $script:mainWindow
    $script:settingsWindow.ShowInTaskbar = $false
    $script:settingsWindow.Add_Closed({
        $closedSettingsWindow = $script:settingsWindow
        $script:settingsWindow = $null
        if ($closedSettingsWindow) { Invalidate-UiDeviceDiscoveryForWindow -Window $closedSettingsWindow }
    })
    (Get-SettingsControl 'CancelSettingsButton').Add_Click({ $script:settingsWindow.Close() })
    (Get-SettingsControl 'BrowsePasswordButton').Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择本机 BM 密码文件'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($script:settingsWindow) -eq $true) {
            (Get-SettingsControl 'PasswordPathBox').Text = $dialog.FileName
        }
    })
    (Get-SettingsControl 'PlaybackGainSlider').Add_ValueChanged({ Set-GainValueLabel -SliderName 'PlaybackGainSlider' -LabelName 'PlaybackGainValueText' })
    (Get-SettingsControl 'TransmitGainSlider').Add_ValueChanged({ Set-GainValueLabel -SliderName 'TransmitGainSlider' -LabelName 'TransmitGainValueText' })
    (Get-SettingsControl 'RefreshDevicesButton').Add_Click({
        if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) { return }
        $script:deviceCatalog = $null
        Start-UiDeviceDiscovery
    })
    (Get-SettingsControl 'SaveSettingsButton').Add_Click({ Save-SettingsFromWindow })
    Set-SettingsWindowFields
    Start-UiDeviceDiscovery
}

function Show-SettingsWindow {
    if ($null -eq $script:settingsWindow) { Initialize-SettingsWindow }
    [void]$script:settingsWindow.ShowDialog()
}

function Test-UiAutoEndpointResolvable {
    param([object[]]$Devices)
    $usable = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -eq $true -and $_.endpoint_id -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    $usb = @($usable | Where-Object { [string]$_.name -match '(?i)USB Audio' })
    return ($usb.Count -eq 1)
}

function Save-SettingsFromWindow {
    try {
        $slotItem = (Get-SettingsControl 'SlotBox').SelectedItem
        $kindItem = (Get-SettingsControl 'CallKindBox').SelectedItem
        $serialContainer = (Get-SettingsControl 'SerialBox').SelectedItem
        $waveInContainer = (Get-SettingsControl 'WaveInEndpointBox').SelectedItem
        $waveOutContainer = (Get-SettingsControl 'WaveOutEndpointBox').SelectedItem
        if ($serialContainer -isnot [System.Windows.Controls.ComboBoxItem] -or
            $waveInContainer -isnot [System.Windows.Controls.ComboBoxItem] -or
            $waveOutContainer -isnot [System.Windows.Controls.ComboBoxItem]) {
            throw '请从设备列表中明确选择串口、音频输入和音频输出。'
        }
        $serialItem = $serialContainer.Tag
        $waveInItem = $waveInContainer.Tag
        $waveOutItem = $waveOutContainer.Tag
        if ($null -eq $serialItem -or $null -eq $waveInItem -or $null -eq $waveOutItem) {
            throw '设备列表项目缺少内部选择信息；请刷新设备列表。'
        }
        if (-not $serialItem.IsAvailable -or -not $waveInItem.IsAvailable -or -not $waveOutItem.IsAvailable) {
            throw '所选设备当前不可用；请从列表中选择已发现的设备。'
        }
        if ($script:deviceDiscoveryState -eq 'ready') {
            if ([string]$serialItem.Value -ceq 'auto') {
                $hri = @($script:deviceCatalog.hri_ports)
                $knownCom5 = @($hri | Where-Object { $_.PortName -ceq 'COM5' })
                if ($hri.Count -eq 0 -or ($knownCom5.Count -ne 1 -and $hri.Count -ne 1)) {
                    throw '当前有多个或没有已确认的 HRI 串口；请从下拉列表中选择 HRI 设备。'
                }
            }
            if ([string]$waveInItem.Value -ceq 'auto' -and -not (Test-UiAutoEndpointResolvable -Devices @($script:deviceCatalog.wave_inputs))) {
                throw '电台音频输入有多个候选设备；请从下拉列表中选择稳定端点。'
            }
            if ([string]$waveOutItem.Value -ceq 'auto' -and -not (Test-UiAutoEndpointResolvable -Devices @($script:deviceCatalog.wave_outputs))) {
                throw '电台音频输出有多个候选设备；请从下拉列表中选择稳定端点。'
            }
        }
        $connection = [pscustomobject]@{
            callsign = (Get-SettingsControl 'CallsignBox').Text
            gateway_id = (Get-SettingsControl 'GatewayBox').Text
            source_id = (Get-SettingsControl 'SourceBox').Text
            master = (Get-SettingsControl 'MasterBox').Text
            master_port = (Get-SettingsControl 'MasterPortBox').Text
            destination_id = (Get-SettingsControl 'DestinationBox').Text
            slot = [string]$slotItem.Tag
            color_code = (Get-SettingsControl 'ColorCodeBox').Text
            call_kind = [string]$kindItem.Tag
        }
        $devices = [pscustomobject]@{
            serial_port = [string]$serialItem.Value
            wave_in_endpoint_id = [string]$waveInItem.Value
            wave_out_endpoint_id = [string]$waveOutItem.Value
        }
        $profile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $devices -AllowTextNumbers
        $playbackValue = [double](Get-SettingsControl 'PlaybackGainSlider').Value
        $transmitValue = [double](Get-SettingsControl 'TransmitGainSlider').Value
        $playbackMilli = Convert-UiGainSliderToMilli -Value $playbackValue
        $transmitMilli = Convert-UiGainSliderToMilli -Value $transmitValue
        $passwordCandidate = (Get-SettingsControl 'PasswordPathBox').Text.Trim()
        if ($passwordCandidate) {
            $passwordCandidate = [System.IO.Path]::GetFullPath($passwordCandidate)
            if (-not [System.IO.File]::Exists($passwordCandidate)) { throw '所选 BM 密码文件当前不存在。' }
        }

        $saveFiles = @($script:profilePath, $script:audioSettingsPath, $script:passwordPointerPath)
        $transactionId = [guid]::NewGuid().ToString('N')
        $backupRecords = @()
        try {
            foreach ($path in $saveFiles) {
                $existed = [System.IO.File]::Exists($path)
                $backup = $path + '.ui-backup-' + $transactionId
                if ($existed) { [System.IO.File]::Copy($path, $backup, $false) }
                $backupRecords += [pscustomobject]@{ Path = $path; Existed = $existed; Backup = $backup }
            }
            Write-BridgeUserConnectionProfile -Path $script:profilePath -Profile $profile
            Write-BridgeAudioSettings -Path $script:audioSettingsPath -RadioPlaybackGainMilli $playbackMilli `
                -MicTransmitGainMilli $transmitMilli
            if ($passwordCandidate) {
                $temporaryPath = $script:passwordPointerPath + '.tmp-' + [guid]::NewGuid().ToString('N')
                $backupPath = $script:passwordPointerPath + '.bak-' + [guid]::NewGuid().ToString('N')
                try {
                    [System.IO.File]::WriteAllText($temporaryPath, $passwordCandidate + "`n", (New-Object System.Text.UTF8Encoding($false)))
                    if ([System.IO.File]::Exists($script:passwordPointerPath)) { [System.IO.File]::Replace($temporaryPath, $script:passwordPointerPath, $backupPath) }
                    else { [System.IO.File]::Move($temporaryPath, $script:passwordPointerPath) }
                } finally {
                    if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
                    if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
                }
            } elseif ([System.IO.File]::Exists($script:passwordPointerPath)) {
                [System.IO.File]::Delete($script:passwordPointerPath)
            }
        } catch {
            $saveError = $_.Exception.Message
            $rollbackErrors = @()
            foreach ($record in $backupRecords) {
                try {
                    if ($record.Existed -and [System.IO.File]::Exists($record.Backup)) {
                        [System.IO.File]::Copy($record.Backup, $record.Path, $true)
                    } elseif (-not $record.Existed -and [System.IO.File]::Exists($record.Path)) {
                        [System.IO.File]::Delete($record.Path)
                    }
                } catch { $rollbackErrors += ($record.Path + ': ' + $_.Exception.Message) }
            }
            if ($rollbackErrors.Count -gt 0) {
                throw ('设置保存失败，部分文件可能仍含有旧值或新值；请重新打开设置核对。' + ($rollbackErrors -join '；'))
            }
            throw ('设置保存失败，已恢复保存前的配置。' + $saveError)
        } finally {
            foreach ($record in $backupRecords) {
                if ([System.IO.File]::Exists($record.Backup)) { [System.IO.File]::Delete($record.Backup) }
            }
        }
        (Get-SettingsControl 'SettingsErrorText').Text = '设置已保存。'
        $script:storedProfile = $profile
        $selectedTarget = Get-SelectedTargetTag
        $script:targetLabel = Format-ProfileTarget -Profile (New-EffectiveTargetProfile -Profile $profile -Target $selectedTarget)
        $wasRunning = ($script:supervisor -and -not $script:supervisor.HasExited)
        if ($wasRunning) {
            Set-MainText -Name 'TrafficDetail' -Text ('设置已保存；下一次连接将使用 {0}。' -f $script:targetLabel)
        } else {
            Set-MainText -Name 'TargetValue' -Text $script:targetLabel
        }
        $script:settingsWindow.Close()
        if ($script:startupNeedsSettings -and -not $wasRunning -and -not $OfflinePreview -and -not $NoAutoConnect) {
            $script:startupNeedsSettings = $false
            Start-BridgeRun
        } else {
            Set-MainText -Name 'FooterText' -Text '设置已保存；下次连接时使用新配置。'
        }
    } catch {
        (Get-SettingsControl 'SettingsErrorText').Text = $_.Exception.Message
        (Get-SettingsControl 'SettingsErrorText').Foreground = [Windows.Media.Brushes]::IndianRed
    }
}

function Start-BridgeRun {
    if ($script:preparationStarted -or ($script:supervisor -and -not $script:supervisor.HasExited)) { return }
    Set-OfflineDisplay -Reason '正在检查本次连接配置和设备。'
    $script:lastUiBmState = ''
    $script:lastUiHriState = ''
    try {
        if ($script:supervisor) { $script:supervisor.Dispose(); $script:supervisor = $null }
        if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
        $script:statusPath = ''
        $script:latestStatus = $null
        $script:lastStatusUtc = [DateTime]::MinValue
        $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if ($null -eq $script:storedProfile) { $script:startupNeedsSettings = $true; Show-SettingsWindow; return }
        $script:passwordPath = Get-BridgePasswordFile -UserConfigDirectory $script:configDirectory
        if ([string]::IsNullOrWhiteSpace($script:passwordPath)) { $script:startupNeedsSettings = $true; Show-SettingsWindow; return }
        $target = Get-SelectedTargetTag
        $script:effectiveProfile = New-EffectiveTargetProfile -Profile $script:storedProfile -Target $target
        $script:targetLabel = Format-ProfileTarget -Profile $script:effectiveProfile
        $script:preparedTargetTag = $target
        $script:preparedTargetLabel = $script:targetLabel
        if (-not $script:supervisor -or $script:supervisor.HasExited) {
            Set-MainText -Name 'TargetValue' -Text $script:targetLabel
        }
        $audio = Get-BridgeAudioSettings -Path $script:audioSettingsPath
        $retention = Invoke-UiRunLogRetention -RunRoot (Join-Path $script:configDirectory 'ui-runs') `
            -ConfigRoot $script:configDirectory
        if ($retention.removed -gt 0) { Add-UiEvent ('已清理 {0} 个已结束运行目录' -f $retention.removed) }
        if ($retention.cleanup_errors -gt 0) { Add-UiEvent '有已结束运行记录未能清理' }
        $script:preparedRunDirectory = Join-Path (Join-Path $script:configDirectory 'ui-runs') ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($script:preparedRunDirectory) | Out-Null
        $temporaryProfilePath = Join-Path $script:preparedRunDirectory 'connection-profile.json'
        Write-BridgeUserConnectionProfile -Path $temporaryProfilePath -Profile $script:effectiveProfile
        $preparationPath = Join-Path $script:preparedRunDirectory 'preparation.json'
        $script:statusPath = ''
        $arguments = @{
            Preset = 'manual'
            ConnectionProfilePath = $temporaryProfilePath
            AudioSettingsPath = $script:audioSettingsPath
            PasswordFile = $script:passwordPath
            StatusDirectory = $script:preparedRunDirectory
            PreparationOutputPath = $preparationPath
            PrepareOnly = $true
            NoInteractive = $true
            RequirePasswordFile = $true
        }
        $script:preparePowerShell = [System.Management.Automation.PowerShell]::Create()
        $prepareBody = {
            param([string]$LauncherPath, [hashtable]$LauncherParameters)
            & $LauncherPath @LauncherParameters
        }
        [void]$script:preparePowerShell.AddScript($prepareBody.ToString()).AddArgument($script:releaseLauncher).AddArgument($arguments)
        $script:prepareAsync = $script:preparePowerShell.BeginInvoke()
        $script:preparationStarted = $true
        Set-MainText -Name 'CoreValue' -Text '正在准备连接'
        Set-MainText -Name 'CoreDetail' -Text '正在枚举本机设备并核对音频端点'
        Set-MainText -Name 'RunValue' -Text '准备中'
        Set-MainText -Name 'FreshnessValue' -Text '连接前设备查询在后台执行'
        Set-MainText -Name 'FooterText' -Text '正在准备连接。'
        (Get-UiControl 'SettingsButton').IsEnabled = $false
        (Get-UiControl 'TargetSelector').IsEnabled = $false
        Set-ConnectionButtonState
    } catch {
        $script:preparationStarted = $false
        Set-OfflineDisplay -Reason ('连接准备失败：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置并检查连接参数、密码文件和设备选择。'
        Set-ConnectionButtonState
        Add-UiEvent '连接准备失败'
    }
}

function Complete-BridgePreparation {
    if ($script:closingAfterStop -or $script:reconnectAfterStop) { return }
    if (-not $script:preparePowerShell -or -not $script:prepareAsync -or -not $script:prepareAsync.IsCompleted) { return }
    try {
        [void]$script:preparePowerShell.EndInvoke($script:prepareAsync)
        if ($script:preparePowerShell.HadErrors) {
            $errorText = @($script:preparePowerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '；'
            throw $(if ($errorText) { $errorText } else { '设备预检失败。' })
        }
        $preparationPath = Join-Path $script:preparedRunDirectory 'preparation.json'
        if (-not [System.IO.File]::Exists($preparationPath)) { throw '设备预检没有生成启动参数。' }
        $preparationText = [System.IO.File]::ReadAllText($preparationPath, [System.Text.Encoding]::UTF8)
        $preparation = ConvertFrom-Json -InputObject $preparationText -ErrorAction Stop
        $validatedPreparation = Test-UiPreparationRecord -Record $preparation `
            -RunDirectory $script:preparedRunDirectory `
            -RunRoot (Join-Path $script:configDirectory 'ui-runs') `
            -ExpectedExecutable $script:nativeExecutable
        $script:statusPath = $validatedPreparation.StatusPath
        $script:supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
        $script:supervisor.Start($validatedPreparation.Executable, $validatedPreparation.Arguments, $script:releaseDirectory)
        $script:activeTargetTag = $script:preparedTargetTag
        $script:activeTargetLabel = $script:preparedTargetLabel
        $script:targetLabel = $script:activeTargetLabel
        Set-MainText -Name 'TargetValue' -Text $script:activeTargetLabel
        $script:statusOffset = 0
        $script:partialStatusLine = ''
        $script:currentRunId = ''
        $script:lastSequence = [uint64]0
        $script:lastStatusUtc = [DateTime]::MinValue
        Set-MainText -Name 'CoreValue' -Text '运行中'
        Set-MainText -Name 'CoreDetail' -Text '等待本次运行状态报告'
        Set-MainText -Name 'RunValue' -Text '等待状态'
        Set-MainText -Name 'FreshnessValue' -Text '等待状态报告'
        Set-MainText -Name 'FooterText' -Text '使用已保存的配置连接；关闭窗口将停止桥接并退出。'
        Add-UiEvent '核心进程已启动'
    } catch {
        Set-OfflineDisplay -Reason ('连接准备失败：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置检查配置，再重新启动。'
        Set-ConnectionButtonState
        Add-UiEvent '连接准备失败'
    } finally {
        $script:preparationStarted = $false
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        (Get-UiControl 'SettingsButton').IsEnabled = $true
        (Get-UiControl 'TargetSelector').IsEnabled = $true
        Set-ConnectionButtonState
    }
}

function Apply-StatusRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
    if (-not $script:supervisor -or $script:supervisor.HasExited) { return }
    $nowUtcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not (Test-UiRunRecordAcceptance -Record $Record -ExpectedProcessId ([uint32]$script:supervisor.ProcessId) `
            -LockedRunId $script:currentRunId -LastSequence $script:lastSequence -NowUtcMs $nowUtcMs)) { return }
    $sequence = [uint64]0
    [void][uint64]::TryParse([string]$Record.seq, [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$sequence)
    $recordUtcMs = [int64]$Record.timestamp_utc_ms
    $script:currentRunId = [string]$Record.run_id
    $script:lastSequence = $sequence
    $script:lastStatusUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($recordUtcMs).UtcDateTime
    $script:latestStatus = $Record
    $bm = [string]$Record.bm_state
    if ($script:lastUiBmState -cne $bm) {
        switch -CaseSensitive ($bm) {
            'ready' { Add-UiEvent 'BM 已连接' }
            'recovering' { Add-UiEvent 'BM 正在恢复连接' }
            'backoff' { Add-UiEvent 'BM 正在重试连接' }
            'stopped' { Add-UiEvent 'BM 已停止' }
            'connecting' { Add-UiEvent 'BM 正在连接' }
        }
        $script:lastUiBmState = $bm
    }
    switch ($bm) {
        'ready' { Set-MainText -Name 'BmValue' -Text '已连接' }
        'stopped' { Set-MainText -Name 'BmValue' -Text '已停止' }
        'recovering' { Set-MainText -Name 'BmValue' -Text '恢复中' }
        'backoff' { Set-MainText -Name 'BmValue' -Text '重试中' }
        default { Set-MainText -Name 'BmValue' -Text '连接中' }
    }
    $failure = [string]$Record.bm_failure
    if ($failure -cne 'none') {
        $bmDetail = switch -CaseSensitive ($failure) {
            'login_timeout' { 'BM 登录等待超时' }
            'auth_timeout' { 'BM 认证等待超时' }
            'config_timeout' { 'BM 配置响应超时' }
            'options_timeout' { 'BM 参数响应超时' }
            'pong_timeout' { 'BM 心跳响应超时' }
            'master_rejected' { 'BM 拒绝连接' }
            'master_closed' { 'BM 关闭连接' }
            'malformed_response' { 'BM 响应格式无效' }
            'unexpected_response' { '收到无法识别的 BM 响应' }
            'wrong_peer_id' { 'BM 对端 ID 不匹配' }
            'authentication_error' { 'BM 认证失败' }
            'inbound_queue_full' { 'BM 接收队列已满' }
            'outbound_queue_full' { 'BM 发送队列已满' }
            'transport_lost' { 'BM 网络连接中断' }
            'invalid_profile' { 'BM 连接参数无效' }
            default { 'BM 返回未知错误' }
        }
    } elseif ($bm -ceq 'ready') {
        $bmDetail = '已收到 BM 登录确认。'
    } else {
        $bmDetail = '等待 BM 登录确认。'
    }
    Set-MainText -Name 'BmDetail' -Text $bmDetail

    $serialOpen = [bool]$Record.hri_serial_open
    $hriReady = [bool]$Record.hri_ready
    $yReady = [bool]$Record.hri_y_zero_ready
    if ($hriReady -and $yReady) { Set-MainText -Name 'RadioValue' -Text 'HRI 就绪' }
    elseif ($serialOpen) { Set-MainText -Name 'RadioValue' -Text 'HRI 连接中' }
    else { Set-MainText -Name 'RadioValue' -Text 'HRI 未连接' }
    $hriSummary = if ($hriReady -and $yReady) { 'ready' } elseif ($serialOpen) { 'serial_open' } else { 'closed' }
    if ($script:lastUiHriState -cne $hriSummary) {
        switch -CaseSensitive ($hriSummary) {
            'ready' { Add-UiEvent 'HRI 与电台音频接口已就绪' }
            'serial_open' { Add-UiEvent 'HRI 串口已打开，等待设备就绪' }
            'closed' { Add-UiEvent 'HRI 串口已关闭' }
        }
        $script:lastUiHriState = $hriSummary
    }
    Set-MainText -Name 'RadioDetail' -Text ('串口：{0} · HRI：{1} · 电台音频：{2}' -f `
        $(if ($serialOpen) { '已打开' } else { '未打开' }),
        $(if ($hriReady) { '就绪' } else { '未就绪' }),
        $(if ($yReady) { '已确认' } else { '未确认' }))
    Set-MainText -Name 'RadioStateValue' -Text '电台状态：未知（核心未读取）'

    $waveIn = [string]$Record.wavein_state
    $waveOut = [string]$Record.waveout_state
    if ([bool]$Record.audio_endpoints_validated) {
        if ($waveIn -ceq 'open' -and $waveOut -ceq 'open') { Set-MainText -Name 'AudioValue' -Text '双向流已打开' }
        elseif ($waveIn -ceq 'open' -or $waveOut -ceq 'open') { Set-MainText -Name 'AudioValue' -Text '单路流已打开' }
        else { Set-MainText -Name 'AudioValue' -Text '端点已核验' }
    } else { Set-MainText -Name 'AudioValue' -Text '未知' }
    Set-MainText -Name 'AudioDetail' -Text ('输入流：{0} · 输出流：{1}' -f `
        $(if ($waveIn -ceq 'open') { '已打开' } else { '未打开' }),
        $(if ($waveOut -ceq 'open') { '已打开' } else { '未打开' }))
    if ([string]$Record.radio_state -ceq 'unknown') { Set-MainText -Name 'RadioStateValue' -Text '电台状态：未知（核心未读取）' }

    $hasCurrentCallFields = $null -ne $Record.PSObject.Properties['current_call_valid']
    if (-not $hasCurrentCallFields) {
        Set-MainText -Name 'CurrentCallValue' -Text '当前核心未提供活动来话状态'
        Set-MainText -Name 'CurrentCallDetail' -Text '本次运行不含当前 BM 来话字段。'
    } elseif ([bool]$Record.current_call_valid) {
        $caller = 'DMR ID ' + [string]$Record.current_call_source_id
        $kind = if ([string]$Record.current_call_kind -ceq 'P') { '私呼' } else { '组呼' }
        $colorCode = if ([bool]$Record.current_call_color_code_known) {
            'CC ' + [string]$Record.current_call_color_code
        } else { 'CC 未知' }
        $linkControl = if ([bool]$Record.current_call_link_control_validated) { 'LC 已验证' } else { 'LC 未验证' }
        $phase = switch -CaseSensitive ([string]$Record.current_call_phase) {
            'waiting_for_playback' { '等待回放许可' }
            'buffering' { '缓冲中' }
            'playing' { '接收中' }
            default { '状态未知' }
        }
        Set-MainText -Name 'CurrentCallValue' -Text $caller
        Set-MainText -Name 'CurrentCallDetail' -Text ('{0} · 目标 {1} · TS{2} · {3} · {4} · {5}' -f `
            $kind, $Record.current_call_destination_id, $Record.current_call_slot, $colorCode, $linkControl, $phase)
    } elseif ([string]$Record.receive_media_state -ceq 'draining') {
        Set-MainText -Name 'CurrentCallValue' -Text '当前没有活动 BM 话者'
        Set-MainText -Name 'CurrentCallDetail' -Text 'BM 来话已结束，本机回放尾音正在排空。'
    } else {
        Set-MainText -Name 'CurrentCallValue' -Text '当前没有已接受的 BM 来话'
        Set-MainText -Name 'CurrentCallDetail' -Text '等待通过目标、时隙和呼叫类型过滤的来话。'
    }
    $identityProperty = $Record.PSObject.Properties['lcd_source_identity']
    $identityDisplay = if ($null -eq $identityProperty) {
        Get-UiSourceIdentityDisplay -IdentityPresent $false
    } else {
        Get-UiSourceIdentityDisplay -Identity $identityProperty.Value
    }
    Set-MainText -Name 'HriSourceIdentityValue' -Text $identityDisplay.value
    Set-MainText -Name 'RadioDisplayValue' -Text $identityDisplay.radio_display

    if ([bool]$Record.last_rx_header_valid) {
        $caller = 'DMR ID ' + [string]$Record.last_rx_source_id
        Set-MainText -Name 'RecentCaller' -Text $caller
        Set-MainText -Name 'RecentCallDetail' -Text ('最近来话 · 目标 {0} · TS{1} · {2}' -f `
            $Record.last_rx_destination_id, $Record.last_rx_slot, $Record.last_rx_call_kind)
    }
    Set-MainText -Name 'TrafficValue' -Text $script:activeTargetLabel
    Set-MainText -Name 'TrafficDetail' -Text '当前连接使用运行会话中显示的目标。'
    Set-MainText -Name 'RunValue' -Text '运行中'
    Set-MainText -Name 'FreshnessValue' -Text ('状态更新于 {0}' -f [DateTime]::Now.ToString('HH:mm:ss'))
    $visibleEvent = Get-VisibleUiEventText -EventName ([string]$Record.event)
    if ($visibleEvent) { Add-UiEvent $visibleEvent }
}

function Read-StatusUpdates {
    if (-not $script:statusPath -or -not [System.IO.File]::Exists($script:statusPath)) { return }
    try {
        if ($null -eq $script:statusStream) {
            $script:statusStream = [System.IO.File]::Open($script:statusPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        }
        if ($script:statusStream.Length -lt $script:statusOffset) {
            $script:statusStream.Position = 0
            $script:statusOffset = 0
            $script:partialStatusLine = ''
        }
        $script:statusStream.Position = $script:statusOffset
        $remaining = [Math]::Min([int64]65536, $script:statusStream.Length - $script:statusOffset)
        if ($remaining -le 0) { return }
        $buffer = New-Object byte[] ([int]$remaining)
        $read = $script:statusStream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return }
        $script:statusOffset += $read
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $combined = $script:partialStatusLine + $text
        $lines = $combined.Split([char]10)
        if ($lines.Count -gt 0) { $script:partialStatusLine = [string]$lines[$lines.Count - 1] }
        if ($script:partialStatusLine.Length -gt 65536) { $script:partialStatusLine = ''; Add-UiEvent '状态行超过大小限制，已跳过' }
        for ($index = 0; $index -lt ($lines.Count - 1); $index++) {
            $line = ([string]$lines[$index]).TrimEnd([char]13)
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 65536) { continue }
            try { $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop }
            catch { continue }
            Apply-StatusRecord -Record $record
        }
    } catch {
        Add-UiEvent '读取运行状态失败'
    }
}

function Set-StaleDisplay {
    if ($script:lastStatusUtc -eq [DateTime]::MinValue) { return }
    if (([DateTime]::UtcNow - $script:lastStatusUtc).TotalSeconds -le 3) { return }
    Set-MainText -Name 'CoreDetail' -Text '最近状态报告已过期'
    Set-MainText -Name 'RadioValue' -Text '未知'
    Set-MainText -Name 'RadioDetail' -Text '等待新的 HRI 状态报告'
    Set-MainText -Name 'AudioValue' -Text '未知'
    Set-MainText -Name 'AudioDetail' -Text '等待新的输入与输出流状态报告'
    Set-MainText -Name 'BmValue' -Text '未知'
    Set-MainText -Name 'BmDetail' -Text '等待新的 BM 状态报告'
    Set-MainText -Name 'TrafficDetail' -Text '最近状态报告已过期；正在等待新状态。'
    Set-MainText -Name 'RadioStateValue' -Text '电台状态：未知'
    Set-MainText -Name 'CurrentCallValue' -Text '活动来话状态已过期'
    Set-MainText -Name 'CurrentCallDetail' -Text '已清除上次状态中的当前 BM 话者；等待新状态报告。'
    $identityDisplay = Get-UiSourceIdentityDisplay -State 'stale'
    Set-MainText -Name 'HriSourceIdentityValue' -Text $identityDisplay.value
    Set-MainText -Name 'RadioDisplayValue' -Text $identityDisplay.radio_display
    Set-MainText -Name 'FreshnessValue' -Text '状态报告过期'
}

function Request-StopAndExit {
    $script:closingAfterStop = $true
    $script:reconnectAfterStop = $false
    if ($script:stopTask) { return }
    if ($script:preparePowerShell -and $script:preparationStarted) {
        Begin-PreparationStop
        if (-not $script:preparationStarted -or $script:allowWindowClose) { return }
        Set-MainText -Name 'FooterText' -Text '正在取消设备检查并退出。'
        Set-ConnectionButtonState
        return
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        (Get-UiControl 'StopButton').IsEnabled = $false
        (Get-UiControl 'FooterText').Text = '正在停止桥接并清理设备资源。'
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-ConnectionButtonState
        return
    }
    $script:allowWindowClose = $true
    $script:mainWindow.Close()
}

function Request-Reconnect {
    if ($script:closingAfterStop -or $script:stopTask -or $script:prepareStopAsync) { return }
    if ($script:preparationStarted -and $script:preparePowerShell) {
        $script:reconnectAfterStop = $true
        Begin-PreparationStop
        if (-not $script:preparationStarted) { return }
        Set-MainText -Name 'FooterText' -Text '正在取消当前设备检查并使用所选目标重新连接。'
        Set-ConnectionButtonState
        return
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        $script:reconnectAfterStop = $true
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-MainText -Name 'CoreValue' -Text '正在停止当前连接'
        Set-MainText -Name 'CoreDetail' -Text '设备关闭后将使用所选目标重新连接。'
        Set-MainText -Name 'FooterText' -Text '正在切换连接目标。'
        Set-ConnectionButtonState
        return
    }
    Start-BridgeRun
}

function Complete-PreparedPipelineWithoutLaunch {
    try { if ($script:preparePowerShell -and $script:prepareAsync) { [void]$script:preparePowerShell.EndInvoke($script:prepareAsync) } }
    catch { Add-UiEvent '设备检查已取消' }
    finally {
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        $script:prepareStopAsync = $null
        $script:preparationStarted = $false
        $script:prepareStopStartedUtc = [DateTime]::MinValue
    }
    if ($script:closingAfterStop) {
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
    } elseif ($script:reconnectAfterStop) {
        $script:reconnectAfterStop = $false
        Start-BridgeRun
    }
}

function Begin-PreparationStop {
    if (-not $script:preparePowerShell -or -not $script:preparationStarted) { return }
    if ($script:prepareStopAsync) { return }
    if ($script:prepareAsync -and $script:prepareAsync.IsCompleted) {
        Complete-PreparedPipelineWithoutLaunch
        return
    }
    $script:prepareStopStartedUtc = [DateTime]::UtcNow
    try {
        $script:prepareStopAsync = $script:preparePowerShell.BeginStop($null, $null)
    } catch {
        if ($script:prepareAsync -and $script:prepareAsync.IsCompleted) {
            Complete-PreparedPipelineWithoutLaunch
            return
        }
        throw
    }
}

function Complete-PreparationStop {
    if (-not $script:prepareStopAsync -or -not $script:prepareStopAsync.IsCompleted) {
        if ($script:prepareStopAsync -and
            ([DateTime]::UtcNow - $script:prepareStopStartedUtc).TotalSeconds -ge 5) {
            Add-UiEvent '设备检查停止超时，正在关闭界面'
            $script:abandonPreparationAtShutdown = $true
            $script:allowWindowClose = $true
            $script:mainWindow.Close()
            [System.Environment]::Exit(2)
        }
        return
    }
    $wasClosing = $script:closingAfterStop
    $wasReconnect = $script:reconnectAfterStop
    try { $script:preparePowerShell.EndStop($script:prepareStopAsync) }
    catch { Add-UiEvent '设备检查已取消' }
    finally {
        if ($script:preparePowerShell) { $script:preparePowerShell.Dispose(); $script:preparePowerShell = $null }
        $script:prepareAsync = $null
        $script:prepareStopAsync = $null
        $script:preparationStarted = $false
        $script:prepareStopStartedUtc = [DateTime]::MinValue
    }
    if ($wasClosing) {
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return
    }
    if ($wasReconnect) {
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        Start-BridgeRun
    }
}

function Complete-BridgeStop {
    if (-not $script:stopTask -or -not $script:stopTask.IsCompleted) { return $false }
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        Set-MainText -Name 'CoreValue' -Text '停止未完成'
        Set-MainText -Name 'CoreDetail' -Text '核心仍在运行；请再次选择停止并退出。'
        Set-MainText -Name 'FooterText' -Text '桥接核心尚未退出。'
        $script:stopTask = $null
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        (Get-UiControl 'StopButton').IsEnabled = $true
        Set-ConnectionButtonState
        return $true
    }
    if ($script:supervisor) { $script:supervisor.Dispose(); $script:supervisor = $null }
    if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
    $script:stopTask = $null
    if ($script:closingAfterStop) {
        $script:allowWindowClose = $true
        $script:mainWindow.Close()
        return $true
    }
    if ($script:reconnectAfterStop) {
        $script:reconnectAfterStop = $false
        $script:closingAfterStop = $false
        $script:activeTargetLabel = ''
        $script:activeTargetTag = ''
        $script:lastUiBmState = ''
        $script:lastUiHriState = ''
        Set-OfflineDisplay -Reason '当前连接已停止，正在连接所选目标。'
        Start-BridgeRun
        return $true
    }
    return $true
}

function On-UiTimerTick {
    if ($script:prepareStopAsync) { Complete-PreparationStop; return }
    Complete-UiDeviceDiscovery
    Complete-BridgePreparation
    if (Complete-BridgeStop) { return }
    if ($script:supervisor) {
        if ($script:supervisor.HasExited) {
            $exitCode = -1
            [void]$script:supervisor.TryGetExitCode([ref]$exitCode)
            Set-MainText -Name 'CoreValue' -Text '已停止'
            Set-MainText -Name 'CoreDetail' -Text ('核心进程已退出，退出码 {0}' -f $exitCode)
            Set-MainText -Name 'RadioValue' -Text '未知'
            Set-MainText -Name 'RadioDetail' -Text '核心已退出'
            Set-MainText -Name 'AudioValue' -Text '未知'
            Set-MainText -Name 'AudioDetail' -Text '核心已退出'
            Set-MainText -Name 'BmValue' -Text '未知'
            Set-MainText -Name 'BmDetail' -Text '核心已退出'
            Set-MainText -Name 'RadioStateValue' -Text '电台状态：未知'
            Set-MainText -Name 'CurrentCallValue' -Text '核心已退出'
            Set-MainText -Name 'CurrentCallDetail' -Text '活动 BM 来话状态已清除。'
            $identityDisplay = Get-UiSourceIdentityDisplay -State 'exited'
            Set-MainText -Name 'HriSourceIdentityValue' -Text $identityDisplay.value
            Set-MainText -Name 'RadioDisplayValue' -Text $identityDisplay.radio_display
            Set-MainText -Name 'RunValue' -Text '已停止'
            Set-MainText -Name 'FreshnessValue' -Text '本次运行已结束'
            if (-not $script:stopTask) {
                $script:activeTargetLabel = ''
                $script:activeTargetTag = ''
                $script:lastUiBmState = ''
                $script:lastUiHriState = ''
                Set-MainText -Name 'TargetValue' -Text $script:targetLabel
                Set-MainText -Name 'TrafficDetail' -Text '连接已停止；可按所选目标重新连接。'
                Set-ConnectionButtonState
            }
            if ($script:statusStream) { $script:statusStream.Dispose(); $script:statusStream = $null }
        } else {
            Read-StatusUpdates
            Set-StaleDisplay
        }
    }
}

function Save-RenderedWindow {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window, [Parameter(Mandatory=$true)][string]$Path)
    $Window.UpdateLayout()
    $width = [Math]::Max(1, [int][Math]::Ceiling($Window.ActualWidth))
    $height = [Math]::Max(1, [int][Math]::Ceiling($Window.ActualHeight))
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Get-UiVisualTextValues {
    param([Parameter(Mandatory=$true)][System.Windows.DependencyObject]$Root)
    $values = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if ($current -is [System.Windows.Controls.ContentPresenter] -and $current.Content -is [string] -and
            -not [string]::IsNullOrWhiteSpace($current.Content)) {
            $values.Add([string]$current.Content)
        }
        if ($current -is [System.Windows.Controls.TextBlock] -and -not [string]::IsNullOrWhiteSpace($current.Text)) {
            $values.Add([string]$current.Text)
        }
        if ($current -is [System.Windows.Controls.AccessText] -and -not [string]::IsNullOrWhiteSpace($current.Text)) {
            $values.Add([string]$current.Text)
        }
        if ($current -is [System.Windows.Media.Visual] -or $current -is [System.Windows.Media.Media3D.Visual3D]) {
            $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($current)
            for ($index = 0; $index -lt $childCount; $index++) {
                $child = [System.Windows.Media.VisualTreeHelper]::GetChild($current, $index)
                if ($child -is [System.Windows.DependencyObject]) { $pending.Push($child) }
            }
        }
    }
    return @($values | Select-Object -Unique)
}

function Get-UiComboRenderEvidence {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    $Combo.ApplyTemplate()
    $Combo.UpdateLayout()
    $selectedContainer = $Combo.SelectedItem
    if ($selectedContainer -isnot [System.Windows.Controls.ComboBoxItem] -or $selectedContainer.Content -isnot [string]) {
        throw ('{0} 的选中项没有显示纯文本标签。' -f $Combo.Name)
    }
    $expectedLabel = [string]$selectedContainer.Content
    $selectedMetadata = $selectedContainer.Tag
    if ($null -eq $selectedMetadata -or $selectedMetadata.Label -isnot [string] -or
        $selectedMetadata.Value -isnot [string] -or $selectedMetadata.IsAvailable -isnot [bool] -or
        $selectedMetadata.Label -cne $expectedLabel) {
        throw ('{0} 的选中项没有保留独立的稳定值元数据。' -f $Combo.Name)
    }
    $selectionPresenter = $Combo.Template.FindName('PART_SelectionBoxItem', $Combo)
    if ($selectionPresenter -isnot [System.Windows.Controls.ContentPresenter]) {
        throw ('{0} 的模板缺少选中项文本显示区域。' -f $Combo.Name)
    }
    $selectedTexts = @(Get-UiVisualTextValues -Root $selectionPresenter)
    if (-not ($selectedTexts -ccontains $expectedLabel)) {
        throw ('{0} 选中框视觉树没有显示设备标签。' -f $Combo.Name)
    }

    $Combo.IsDropDownOpen = $true
    $Combo.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $popup = $Combo.Template.FindName('PART_Popup', $Combo)
    if ($null -eq $popup -or $null -eq $popup.Child) { throw ('{0} 下拉列表没有创建视觉树。' -f $Combo.Name) }
    $dropDownTexts = @(Get-UiVisualTextValues -Root $popup.Child)
    foreach ($container in $Combo.Items) {
        if ($container -isnot [System.Windows.Controls.ComboBoxItem] -or $container.Content -isnot [string] -or
            -not ($dropDownTexts -ccontains [string]$container.Content) -or $null -eq $container.Tag -or
            $container.Tag.Label -cne [string]$container.Content) {
            throw ('{0} 下拉项视觉树没有显示纯文本标签。' -f $Combo.Name)
        }
    }
    $Combo.IsDropDownOpen = $false
    $Combo.UpdateLayout()
    $metadataText = @($selectedTexts + $dropDownTexts | Where-Object { $_ -match '@\{(Label|Value|IsAvailable|Kind)=' })
    if ($metadataText.Count -gt 0) { throw ('{0} 视觉树泄漏了 PowerShell 对象元数据。' -f $Combo.Name) }
    return [pscustomobject]@{
        expected_label = $expectedLabel
        stable_value = [string]$selectedMetadata.Value
        available = [bool]$selectedMetadata.IsAvailable
        selected_text = $selectedTexts
        dropdown_text = $dropDownTexts
    }
}

$script:mainWindow = Import-WpfWindow -Path $script:mainXamlPath
Fit-WpfWindowToWorkArea -Window $script:mainWindow
$script:application.MainWindow = $script:mainWindow
Set-OfflineDisplay
$script:mainWindow.FindName('OfflineBanner').Visibility = [Windows.Visibility]::Collapsed
(Get-UiControl 'SettingsButton').Add_Click({ Show-SettingsWindow })
(Get-UiControl 'ConnectButton').Add_Click({ Request-Reconnect })
(Get-UiControl 'StopButton').Add_Click({ Request-StopAndExit })
(Get-UiControl 'TargetSelector').Add_SelectionChanged({
    $selectedTarget = Get-SelectedTargetTag
    if ($script:storedProfile) {
        $targetProfile = New-EffectiveTargetProfile -Profile $script:storedProfile -Target $selectedTarget
        $script:targetLabel = Format-ProfileTarget -Profile $targetProfile
        if ($script:supervisor -and -not $script:supervisor.HasExited) {
            Set-MainText -Name 'TargetValue' -Text $script:activeTargetLabel
            Set-MainText -Name 'TrafficDetail' -Text ('已选择 {0}；按“切换目标”后重新连接。' -f $script:targetLabel)
        } else {
            Set-MainText -Name 'TargetValue' -Text $script:targetLabel
            Set-MainText -Name 'TrafficDetail' -Text '所选目标将在连接时使用。'
        }
        Set-ConnectionButtonState
    }
})
$script:mainWindow.Add_Closing({
    param($sender, $eventArgs)
    if ($script:allowWindowClose -and -not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery) { return }
    if (($script:supervisor -and -not $script:supervisor.HasExited) -or $script:preparationStarted) {
        $eventArgs.Cancel = $true
        Request-StopAndExit
        return
    }
    if ($script:deviceDiscoveryPowerShell -or $script:deviceAudioQuery) {
        $eventArgs.Cancel = $true
        $script:closingAfterDeviceDiscovery = $true
        $script:deviceDiscoveryGeneration++
        $script:deviceDiscoveryRestartPending = $false
        $script:deviceDiscoveryStopReason = 'shutdown'
        $script:deviceDiscoveryStopStartedUtc = [DateTime]::UtcNow
        if ($script:deviceAudioQuery) {
            try { Request-StopUiAudioQuery -Query $script:deviceAudioQuery }
            catch { $script:deviceDiscoveryError = $_.Exception.Message }
        }
        if ($script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted -and -not $script:deviceDiscoveryStopAsync) {
            try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null, $null) }
            catch {
                if ($script:deviceDiscoveryAsync.IsCompleted) { Complete-UiDeviceDiscovery }
                else { [System.Environment]::Exit(2) }
            }
        } else {
            Complete-UiDeviceDiscovery
        }
    }
})
$script:mainWindow.Add_Loaded({
    if ($OfflinePreview -or $NoAutoConnect) {
        $banner = Get-UiControl 'OfflineBanner'
        $banner.Visibility = [Windows.Visibility]::Visible
        (Get-UiControl 'OfflineBannerText').Text = if ($OfflinePreview) { '离线预览：没有连接设备或网络。' } else { '连接已关闭：当前窗口未启动核心。' }
        Set-OfflineDisplay -Reason '当前窗口没有连接核心。'
        Set-MainText -Name 'FooterText' -Text '打开设置可查看本机配置；此窗口没有启动设备或网络连接。'
        (Get-UiControl 'ConnectButton').IsEnabled = $false
        return
    }
    try {
        $script:storedProfile = Read-BridgeUserConnectionProfile -Path $script:profilePath
        if ($script:storedProfile) {
            Set-MainText -Name 'TargetValue' -Text (Format-ProfileTarget -Profile $script:storedProfile)
            Start-BridgeRun
        } else {
            $script:startupNeedsSettings = $true
            Set-MainText -Name 'FooterText' -Text '请打开设置填写本机连接参数。'
            Show-SettingsWindow
        }
    } catch {
        Set-OfflineDisplay -Reason ('配置需要修正：' + $_.Exception.Message)
        Set-MainText -Name 'FooterText' -Text '请打开设置检查并保存连接参数。'
        Show-SettingsWindow
    }
})

$script:uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:uiTimer.Add_Tick({ On-UiTimerTick })
$script:uiTimer.Start()

if ($RenderOnly) {
    if (-not $RenderOutputDirectory) { throw '-RenderOnly 需要 -RenderOutputDirectory。' }
    $renderDirectory = [System.IO.Path]::GetFullPath($RenderOutputDirectory)
    [System.IO.Directory]::CreateDirectory($renderDirectory) | Out-Null
    $banner = Get-UiControl 'OfflineBanner'
    $banner.Visibility = [Windows.Visibility]::Visible
    (Get-UiControl 'OfflineBannerText').Text = '离线预览：没有连接设备或网络。'
    Set-OfflineDisplay -Reason '离线预览，没有连接设备。'
    $script:mainWindow.Show()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Save-RenderedWindow -Window $script:mainWindow -Path (Join-Path $renderDirectory 'main-window.png')
    Initialize-SettingsWindow
    $serialFixture = New-UiDeviceOption -Label '离线样例 · HRI (COM5)' -Value 'COM5' -IsAvailable $true -Kind 'serial'
    $inputFixture = New-UiDeviceOption -Label '离线样例 · USB Audio 输入' -Value '{render-input}' -IsAvailable $true -Kind 'input'
    $outputFixture = New-UiDeviceOption -Label '离线样例 · USB Audio 输出' -Value '{render-output}' -IsAvailable $true -Kind 'output'
    Set-UiDeviceComboOptions -Combo (Get-SettingsControl 'SerialBox') -Options @($serialFixture) -SelectedValue 'COM5'
    Set-UiDeviceComboOptions -Combo (Get-SettingsControl 'WaveInEndpointBox') -Options @($inputFixture) -SelectedValue '{render-input}'
    Set-UiDeviceComboOptions -Combo (Get-SettingsControl 'WaveOutEndpointBox') -Options @($outputFixture) -SelectedValue '{render-output}'
    (Get-SettingsControl 'DeviceDiscoveryText').Text = '离线渲染样例；没有读取本机设备。'
    $script:settingsWindow.Show()
    $script:settingsWindow.UpdateLayout()
    $deviceComboEvidence = [pscustomobject][ordered]@{
        serial = Get-UiComboRenderEvidence -Combo (Get-SettingsControl 'SerialBox')
        wave_input = Get-UiComboRenderEvidence -Combo (Get-SettingsControl 'WaveInEndpointBox')
        wave_output = Get-UiComboRenderEvidence -Combo (Get-SettingsControl 'WaveOutEndpointBox')
    }
    Save-RenderedWindow -Window $script:settingsWindow -Path (Join-Path $renderDirectory 'settings-window.png')
    $layoutInfo = [pscustomobject][ordered]@{
        work_area_width = $script:workAreaWidth
        work_area_height = $script:workAreaHeight
        max_window_width = $script:maxWindowWidth
        max_window_height = $script:maxWindowHeight
        device_combo_rendered_text = $deviceComboEvidence
        main = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('ConnectButton', 'SettingsButton', 'StopButton', 'FooterText', 'HriSourceIdentityValue', 'RadioDisplayValue', 'CurrentCallValue', 'CurrentCallDetail')
        settings = Get-WpfWindowLayoutInfo -Window $script:settingsWindow -ControlNames @('CancelSettingsButton', 'SaveSettingsButton', 'SettingsErrorText', 'PasswordPathBox', 'BrowsePasswordButton', 'DeviceDiscoveryText', 'RefreshDevicesButton', 'SerialBox', 'WaveInEndpointBox', 'WaveOutEndpointBox', 'PlaybackGainSlider', 'PlaybackGainValueText', 'TransmitGainSlider', 'TransmitGainValueText')
        main_source_identity = [pscustomobject][ordered]@{
            value = (Get-UiControl 'HriSourceIdentityValue').Text
            radio_display = (Get-UiControl 'RadioDisplayValue').Text
            visual_text = @(Get-UiVisualTextValues -Root $script:mainWindow)
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $renderDirectory 'layout-info.json'), (ConvertTo-Json -InputObject $layoutInfo -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    $script:settingsWindow.Close()
    $script:mainWindow.Close()
    $script:uiTimer.Stop()
    $script:application.Shutdown()
    Write-Host '通过：WPF 主窗口和设置窗口已离线渲染；没有启动核心或访问设备。'
    return
}

[void]$script:application.Run($script:mainWindow)
$script:uiTimer.Stop()
if ($script:statusStream) { $script:statusStream.Dispose() }
if ($script:supervisor) { $script:supervisor.Dispose() }
if ($script:preparePowerShell -and -not $script:abandonPreparationAtShutdown) { $script:preparePowerShell.Dispose() }
