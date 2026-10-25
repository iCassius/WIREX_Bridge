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
$script:packageRoot = if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    [System.IO.Path]::GetFullPath((Join-Path $script:uiRoot '..\..'))
} else {
    [System.IO.Path]::GetFullPath($PackageDirectory)
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
$script:releaseDirectory = $script:packageRoot
$script:releasePointerPath = Join-Path $script:configDirectory 'bridge-directory.txt'
if ([System.IO.File]::Exists($script:releasePointerPath)) {
    $script:releaseDirectory = Get-BridgeReleaseDirectory -UserConfigDirectory $script:configDirectory
}
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
}

function Get-WpfWindowLayoutInfo {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window, [Parameter(Mandatory=$true)][string[]]$ControlNames)
    $visibility = [ordered]@{}
    foreach ($name in $ControlNames) {
        $control = $Window.FindName($name)
        $visibility[$name] = ($null -ne $control -and $control.IsVisible)
    }
    return [pscustomobject][ordered]@{
        width = [double]$Window.ActualWidth
        height = [double]$Window.ActualHeight
        controls_visible = [pscustomobject]$visibility
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
    $numberTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    foreach ($name in @('seq', 'timestamp_utc_ms', 'elapsed_ms', 'last_rx_source_id', 'last_rx_destination_id', 'last_rx_slot')) {
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
    }
    if ($Record.bm_state -cnotin @('idle', 'waiting_login_ack', 'waiting_auth_ack', 'waiting_config_ack', 'waiting_options_ack', 'ready', 'backoff', 'stopped')) { return $false }
    if ($Record.bm_failure -cnotin @('none', 'invalid_profile', 'login_timeout', 'auth_timeout', 'config_timeout', 'options_timeout',
            'pong_timeout', 'master_rejected', 'master_closed', 'malformed_response', 'unexpected_response', 'wrong_peer_id',
            'authentication_error', 'inbound_queue_full', 'transport_lost', 'outbound_queue_full', 'unknown')) { return $false }
    if ($Record.radio_state -cne 'unknown') { return $false }
    if ($Record.hri_phase -cnotin @('not_started', 'awaiting_version_write', 'awaiting_version', 'waiting_for_y_due', 'exchanging', 'stopped', 'unknown')) { return $false }
    if ($Record.wavein_state -cnotin @('open', 'closed') -or $Record.waveout_state -cnotin @('open', 'closed')) { return $false }
    if ($Record.last_rx_call_kind -cnotin @('G', 'P')) { return $false }
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

function Read-CurrentPasswordPath {
    try { return Get-BridgePasswordFile -UserConfigDirectory $script:configDirectory }
    catch { return '' }
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
        SerialBox = if ($script:storedProfile) { $script:storedProfile.devices.serial_port } else { 'auto' }
        WaveInEndpointBox = if ($script:storedProfile) { $script:storedProfile.devices.wave_in_endpoint_id } else { 'auto' }
        WaveOutEndpointBox = if ($script:storedProfile) { $script:storedProfile.devices.wave_out_endpoint_id } else { 'auto' }
        PlaybackGainBox = Format-BridgeGain -GainMilli ([uint32]$audio.RadioPlaybackGainMilli)
        TransmitGainBox = Format-BridgeGain -GainMilli ([uint32]$audio.MicTransmitGainMilli)
        PasswordPathBox = Read-CurrentPasswordPath
    }
    foreach ($name in $fields.Keys) { (Get-SettingsControl $name).Text = [string]$fields[$name] }
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
    Fit-WpfWindowToWorkArea -Window $script:settingsWindow
    $script:settingsWindow.Owner = $script:mainWindow
    $script:settingsWindow.ShowInTaskbar = $false
    $script:settingsWindow.Add_Closed({ $script:settingsWindow = $null })
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
    (Get-SettingsControl 'SaveSettingsButton').Add_Click({ Save-SettingsFromWindow })
    Set-SettingsWindowFields
}

function Show-SettingsWindow {
    if ($null -eq $script:settingsWindow) { Initialize-SettingsWindow }
    [void]$script:settingsWindow.ShowDialog()
}

function Save-SettingsFromWindow {
    try {
        $slotItem = (Get-SettingsControl 'SlotBox').SelectedItem
        $kindItem = (Get-SettingsControl 'CallKindBox').SelectedItem
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
            serial_port = (Get-SettingsControl 'SerialBox').Text.Trim()
            wave_in_endpoint_id = (Get-SettingsControl 'WaveInEndpointBox').Text.Trim()
            wave_out_endpoint_id = (Get-SettingsControl 'WaveOutEndpointBox').Text.Trim()
        }
        $profile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $devices -AllowTextNumbers
        $playbackMilli = ConvertTo-BridgeGainMilli -Value (Get-SettingsControl 'PlaybackGainBox').Text -Label '电台播放增益'
        $transmitMilli = ConvertTo-BridgeGainMilli -Value (Get-SettingsControl 'TransmitGainBox').Text -Label '手咪发送增益'
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
        $script:preparedRunDirectory = Join-Path (Join-Path $script:configDirectory 'ui-runs') ([guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($script:preparedRunDirectory) | Out-Null
        $temporaryProfilePath = Join-Path $script:preparedRunDirectory 'connection-profile.json'
        Write-BridgeUserConnectionProfile -Path $temporaryProfilePath -Profile $script:effectiveProfile
        $preparationPath = Join-Path $script:preparedRunDirectory 'preparation.json'
        $script:statusPath = Join-Path $script:preparedRunDirectory 'status.jsonl'
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
        if ($preparation.schema_version -ne 1 -or -not [System.IO.File]::Exists([string]$preparation.executable) -or
            [string]$preparation.status_path -cne $script:statusPath -or @($preparation.arguments).Count -lt 20 -or
            @($preparation.arguments | Where-Object { $_ -ceq '--ui-pipe' }).Count -ne 1) {
            throw '设备预检返回的启动参数不完整。'
        }
        $script:supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
        $script:supervisor.Start([string]$preparation.executable, [string[]]$preparation.arguments, $script:releaseDirectory)
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
    if ($script:allowWindowClose) { return }
    if (($script:supervisor -and -not $script:supervisor.HasExited) -or $script:preparationStarted) {
        $eventArgs.Cancel = $true
        Request-StopAndExit
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
    $script:settingsWindow.Show()
    $script:settingsWindow.UpdateLayout()
    Save-RenderedWindow -Window $script:settingsWindow -Path (Join-Path $renderDirectory 'settings-window.png')
    $layoutInfo = [pscustomobject][ordered]@{
        work_area_width = $script:workAreaWidth
        work_area_height = $script:workAreaHeight
        max_window_width = $script:maxWindowWidth
        max_window_height = $script:maxWindowHeight
        main = Get-WpfWindowLayoutInfo -Window $script:mainWindow -ControlNames @('ConnectButton', 'SettingsButton', 'StopButton', 'FooterText')
        settings = Get-WpfWindowLayoutInfo -Window $script:settingsWindow -ControlNames @('CancelSettingsButton', 'SaveSettingsButton', 'SettingsErrorText', 'PasswordPathBox', 'BrowsePasswordButton')
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
