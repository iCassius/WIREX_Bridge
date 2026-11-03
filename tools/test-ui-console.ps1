#requires -Version 5.1
[CmdletBinding()]
param([switch]$LiveSerialReadOnly)

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0
$script:testRoot = $null
$script:mainWindow = $null
$script:uiConsoleFakeIdleHeartbeatEnabled = $false
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

function Assert-UiConsole {
    param([Parameter(Mandatory=$true)][bool]$Condition,[Parameter(Mandatory=$true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Write-UiConsoleTestProgress {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($script:testRoot) {
        $progressPath = Join-Path $script:testRoot 'test-progress.log'
        $line = '{0:o} {1}{2}' -f [DateTimeOffset]::UtcNow,$Message,[Environment]::NewLine
        [System.IO.File]::AppendAllText($progressPath,$line,(New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host ('UI fake progress: ' + $Message)
}

function Update-UiConsoleFakeCoreHeartbeat {
    if ($LiveSerialReadOnly -or -not $script:uiConsoleFakeIdleHeartbeatEnabled -or
        -not $script:supervisor -or $script:supervisor.HasExited) { return }
    if (-not $script:latestStatus) { $script:latestStatus = [pscustomobject]@{} }
    if ($script:latestStatus.PSObject.Properties['ptt_gate_tx_active'] -and [bool]$script:latestStatus.ptt_gate_tx_active) { return }
    if ($script:latestStatus.PSObject.Properties['ptt_gate_ready'] -and -not [bool]$script:latestStatus.ptt_gate_ready) { return }
    if ($script:latestStatus.PSObject.Properties['ptt_last_state'] -and [string]$script:latestStatus.ptt_last_state -cne 'released') { return }
    if ($script:latestStatus.PSObject.Properties['current_call_valid'] -and [bool]$script:latestStatus.current_call_valid) { return }
    if ($script:latestStatus.PSObject.Properties['receive_media_state'] -and
        [string]$script:latestStatus.receive_media_state -cnotin @('idle','filtered')) { return }
    foreach ($queueName in @('rx_queue_bursts','rx_queue_playback_frames','rx_queue_unconfirmed_playback_frames','rx_buffered_receive_frames')) {
        if ($script:latestStatus.PSObject.Properties[$queueName]) {
            $queueCount = [uint64]0
            if (-not [uint64]::TryParse([string]$script:latestStatus.$queueName,[ref]$queueCount) -or $queueCount -ne 0) { return }
        }
    }
    # The fake supervisor has no status pipe. Republish its unchanged idle snapshot
    # on dispatcher ticks so this fixture models the production heartbeat cadence.
    $idleFields = [ordered]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    foreach ($name in $idleFields.Keys) {
        if ($script:latestStatus.PSObject.Properties[$name]) { $script:latestStatus.$name = $idleFields[$name] }
        else { $script:latestStatus | Add-Member -MemberType NoteProperty -Name $name -Value $idleFields[$name] -Force }
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
}

function Assert-UiConsoleBom {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-UiConsole ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        ("UTF-8 BOM missing: {0}" -f [System.IO.Path]::GetFileName($Path))
}

function Get-UiConsoleControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    $control = $script:mainWindow.FindName($Name)
    if ($null -eq $control) { throw "真实 WPF MainWindow 缺少控件 $Name。" }
    return $control
}

function Invoke-UiConsoleClick {
    param([Parameter(Mandatory=$true)][string]$Name)
    $button = Get-UiConsoleControl $Name
    if ($button -isnot [System.Windows.Controls.Primitives.ButtonBase]) { throw "$Name 不是 WPF ButtonBase。" }
    if (-not $button.IsEnabled) { throw "$Name 当前未启用，测试不能将点击算作成功。" }
    Write-UiConsoleTestProgress ("click-start name={0}" -f $Name)
    $args = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$button)
    $button.RaiseEvent($args)
    Write-UiConsoleTestProgress ("click-end name={0}" -f $Name)
}

function Invoke-UiConsoleDispatcherUntil {
    param([Parameter(Mandatory=$true)][scriptblock]$Condition,[int]$TimeoutMs=3000)
    $conditionText = ($Condition.ToString() -replace '[\r\n]+',' ').Trim()
    Write-UiConsoleTestProgress ("dispatcher-wait-start timeout_ms={0} condition={1}" -f $TimeoutMs,$conditionText)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(20)
    $script:uiConsoleDispatcherTickCount = 0
    $writeProgress = ${function:Write-UiConsoleTestProgress}
    $tick = {
        $script:uiConsoleDispatcherTickCount++
        Update-UiConsoleFakeCoreHeartbeat
        if ($script:uiConsoleDispatcherTickCount -eq 1) { & $writeProgress 'dispatcher-timer-first-tick' }
        $conditionMet = [bool](& $Condition)
        if ($script:uiConsoleDispatcherTickCount -eq 1) { & $writeProgress ("dispatcher-timer-first-condition passed={0}" -f $conditionMet) }
        $timedOut = $watch.ElapsedMilliseconds -ge $TimeoutMs
        if ($conditionMet -or $timedOut) {
            & $writeProgress ("dispatcher-timer-stop passed={0} timeout={1} ticks={2}" -f $conditionMet,$timedOut,$script:uiConsoleDispatcherTickCount)
            $timer.Stop()
            $frame.Continue = $false
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $watch.Stop()
    $timer.Remove_Tick($tick)
    $conditionMet = [bool](& $Condition)
    Write-UiConsoleTestProgress ("dispatcher-wait-end elapsed_ms={0} passed={1} condition={2}" -f $watch.ElapsedMilliseconds,$conditionMet,$conditionText)
    return $conditionMet
}

function Get-UiConsoleComboValue {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    if ($Combo.SelectedItem -is [System.Windows.Controls.ComboBoxItem] -and $Combo.SelectedItem.Tag) {
        return [string]$Combo.SelectedItem.Tag.Value
    }
    if ($Combo.IsEditable) { return [string]$Combo.Text }
    return ''
}

function Get-UiConsoleComboValues {
    param([Parameter(Mandatory=$true)][System.Windows.Controls.ComboBox]$Combo)
    return @($Combo.Items | ForEach-Object { if ($_ -is [System.Windows.Controls.ComboBoxItem] -and $_.Tag) { [string]$_.Tag.Value } })
}

function Set-UiConsoleManualCatPort {
    param([Parameter(Mandatory=$true)][string]$PortName)
    $combo = Get-UiConsoleControl 'CatPortBox'
    $editBox = $combo.Template.FindName('PART_EditableTextBox',$combo)
    if ($editBox -isnot [System.Windows.Controls.TextBox]) { throw 'CatPortBox 没有可编辑的 WPF TextBox。' }
    [void]$combo.Focus()
    [void][System.Windows.Input.Keyboard]::Focus($editBox)
    if (-not $editBox.IsKeyboardFocusWithin) { throw 'CAT ComboBox 的实际编辑 TextBox 未获得测试窗口内的键盘焦点。' }
    $editBox.SelectAll()
    $editBox.Text = $PortName
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}

function Select-UiConsoleCatPortOption {
    param([Parameter(Mandatory=$true)][string]$PortName)
    $combo = Get-UiConsoleControl 'CatPortBox'
    $item = @($combo.Items | Where-Object { $_.Tag.Value -ceq $PortName -and $_.Tag.IsAvailable })[0]
    if (-not $item) { throw "CAT port option $PortName is absent or unavailable." }
    $combo.SelectedItem = $item
    $combo.Text = [string]$item.Content
}

function Set-UiConsoleCatPower {
    param([Parameter(Mandatory=$true)][ValidateRange(5,50)][int]$Watts)
    $combo = Get-UiConsoleControl 'CatPowerBox'
    $item = @($combo.Items | Where-Object { [string]$_.Tag -ceq [string]$Watts } | Select-Object -First 1)
    if ($item.Count -eq 0 -or -not $item[0].IsEnabled) { throw "CAT power choice $Watts W is absent or disabled." }
    $combo.SelectedItem = $item[0]
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}

function New-UiConsoleSerialCatalog {
    $serialRecords = @(
        [pscustomobject]@{ PortName='COM5'; FriendlyName='USB Serial Device (COM5)'; InstanceId='USB\VID_26AA&PID_0030\FAKE-HRI'; HardwareIds=@(); DeviceSource='synthetic' },
        [pscustomobject]@{ PortName='COM10'; FriendlyName='Silicon Labs Dual CP2105 USB to UART Bridge: Standard COM Port (COM10)'; InstanceId='USB\VID_10C4&PID_EA70&MI_01\FAKE'; HardwareIds=@(); DeviceSource='synthetic' },
        [pscustomobject]@{ PortName='COM11'; FriendlyName='Silicon Labs Dual CP2105 USB to UART Bridge: Enhanced COM Port (COM11)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\FAKE'; HardwareIds=@(); DeviceSource='synthetic' }
    )
    return Get-RadioDeviceCatalog -SerialPortsInput $serialRecords
}

function New-UiConsoleDiscoveryHooks {
    param([object]$AudioStatusQueue,[object]$Catalog)
    if (-not $Catalog) { $Catalog = New-UiConsoleSerialCatalog }
    $serialPorts = @($Catalog.serial_ports)
    $hriPorts = @($Catalog.hri_ports)
    $catPorts = @($Catalog.cat_ports)
    $hooks = @{}
    $hooks.SerialEnumerator = {
        param([object]$Context)
        return [pscustomobject]@{ status='success'; serial_ports=$serialPorts; hri_ports=$hriPorts; cat_ports=$catPorts }
    }.GetNewClosure()
    $hooks.AudioQuery = {
        param([object]$Context)
        $audioStatus = [string]$AudioStatusQueue.Dequeue()
        if ($audioStatus -ceq 'success') {
            return [pscustomobject]@{ status='success'; wave_inputs=@(); wave_outputs=@() }
        }
        return [pscustomobject]@{ status=$audioStatus; error=('fake audio ' + $audioStatus); wave_inputs=@(); wave_outputs=@() }
    }.GetNewClosure()
    return $hooks
}

function New-UiConsoleCatOperationHook {
    param([int]$DelayQueryOrdinal=-1,[int]$DelayQuerySeconds=5,[int]$UnknownQueryOrdinal=-1)
    $operationLogPath = Join-Path $script:testRoot 'cat-operations.log'
    $radioStatePath = Join-Path $script:testRoot 'cat-radio-state.json'
    $scriptText = @'
param([object]$Context)
$operation = [string]$Context.operation
$ordinal = [int]$Context.ordinal
$parameters = $Context.parameters
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('{0}|{1}' -f $ordinal,$operation)+[Environment]::NewLine)
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('BEGIN|{0}' -f $operation)+[Environment]::NewLine)
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('ARGS|{0}|Port={1}|Mode={2}|FrequencyHz={3}|PowerWatts={4}' -f `
    $operation,[string]$Context.port,[string]$parameters.Mode,[string]$parameters.FrequencyHz,[string]$parameters.PowerWatts)+[Environment]::NewLine)
$stamp = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
$rejectedFieldHead = ($operation -ceq 'setPower' -and [int]$parameters.PowerWatts -eq 25)
$statePath = '__RADIO_STATE_PATH__'
if ([System.IO.File]::Exists($statePath)) {
    $radioState = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($statePath))
} else {
    $radioState = [pscustomobject]@{ path='Spa1'; watts=25; query_count=0; has_write=$false; main_mode='FM'; main_frequency_hz=[long]145500000 }
}
if ($operation -ceq 'query' -and -not [bool]$radioState.has_write) {
    $radioState.query_count = [int]$radioState.query_count + 1
    $radioState.watts = if ([int]$radioState.query_count -le 2) { 25 } else { 30 }
}
if ($operation -ceq 'setPower') {
    $radioState.has_write = $true
    if ($rejectedFieldHead) { $radioState.path='FieldHead'; $radioState.watts=5 }
    else { $radioState.watts=[int]$parameters.PowerWatts }
}
if ($operation -ceq 'setMode') { $radioState.main_mode=[string]$parameters.Mode }
if ($operation -ceq 'setFrequency') { $radioState.main_frequency_hz=[long]$parameters.FrequencyHz }
if ($operation -cne 'query') { [System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('WRITE|{0}' -f $operation)+[Environment]::NewLine) }
if ($operation -cne 'query' -or -not [bool]$radioState.has_write) {
    [System.IO.File]::WriteAllText($statePath,(ConvertTo-Json -InputObject $radioState -Compress),(New-Object System.Text.UTF8Encoding($false)))
}
$fieldHeadPath = ([string]$radioState.path -ceq 'FieldHead')
$powerPath = [string]$radioState.path
$watts = [int]$radioState.watts
if ($ordinal -eq __DELAY_QUERY_ORDINAL__ -and $operation -ceq 'query') { Start-Sleep -Seconds __DELAY_QUERY_SECONDS__ }
$status = if ($rejectedFieldHead) { 'rejected' } elseif ($operation -ceq 'query' -and
    (__UNKNOWN_QUERY_ORDINAL__ -eq -2 -or $ordinal -eq __UNKNOWN_QUERY_ORDINAL__)) { 'unknown' } else { 'confirmed' }
$errorCode = if ($status -ceq 'unknown') { 'timeout' } elseif ($rejectedFieldHead) { 'power_out_of_range' } else { $null }
$errorMessage = if ($status -ceq 'unknown') { 'synthetic bounded query timeout' } elseif ($rejectedFieldHead) { 'FieldHead supports at most 10 W.' } else { $null }
$mainMode = [string]$radioState.main_mode
$mainFrequency = [long]$radioState.main_frequency_hz
$observed = [pscustomobject][ordered]@{
    radio_id=[pscustomobject]@{ value='0840'; source='CAT test transport'; updated_at_utc=$stamp }
    auto_information_enabled=[pscustomobject]@{ value=$false; source='CAT test transport'; updated_at_utc=$stamp }
    tx_state=[pscustomobject]@{ value=[int]0; source='CAT test transport'; updated_at_utc=$stamp }
    main_frequency_hz=[pscustomobject]@{ value=$mainFrequency; source='CAT test transport'; updated_at_utc=$stamp }
    sub_frequency_hz=[pscustomobject]@{ value=[long]438500000; source='CAT test transport'; updated_at_utc=$stamp }
    main_mode=[pscustomobject]@{ value=[pscustomobject]@{ side='Main'; side_code='0'; mode=$mainMode }; source='CAT test transport'; updated_at_utc=$stamp }
    sub_mode=[pscustomobject]@{ value=[pscustomobject]@{ side='Sub'; side_code='1'; mode='C4FM-DN' }; source='CAT test transport'; updated_at_utc=$stamp }
    power=[pscustomobject]@{ value=[pscustomobject]@{ path=$powerPath; watts=$watts }; source='CAT test transport'; updated_at_utc=$stamp }
}
$powerAvailable = ($status -ceq 'confirmed')
$maximumPower = if ($powerPath -ceq 'FieldHead') { 10 } else { 50 }
$capabilities = [pscustomobject][ordered]@{
    query=[pscustomobject]@{ available=$powerAvailable }
    set_power=[pscustomobject]@{ available=$powerAvailable; active_path=$powerPath; maximum_watts=$maximumPower }
    set_frequency=[pscustomobject]@{ available=$powerAvailable }
    set_mode=[pscustomobject]@{ available=$powerAvailable }
}
$desired = if ($operation -ceq 'setPower') { [pscustomobject]@{ watts=[int]$parameters.PowerWatts } }
    elseif ($operation -ceq 'setMode') { [pscustomobject]@{ mode=[string]$parameters.Mode } }
    elseif ($operation -ceq 'setFrequency') { [pscustomobject]@{ frequency_hz=[long]$parameters.FrequencyHz } }
    else { $null }
$updatedAt = if ($status -ceq 'rejected') { $null } else { $stamp }
$result = [pscustomobject][ordered]@{
    schema_version=1; operation=$operation; status=$status; source='CAT test transport'; port_name=[string]$Context.port; port_role='CAT-1'
    started_at_utc=$stamp; updated_at_utc=$updatedAt; desired=$desired; prior=$null; observed=$observed; capabilities=$capabilities
    cleanup_status='closed'; error_code=$errorCode; error_message=$errorMessage
}
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('READBACK|{0}|Mode={1}|FrequencyHz={2}|PowerWatts={3}' -f `
    $operation,$mainMode,$mainFrequency,$watts)+[Environment]::NewLine)
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('CLEANUP|{0}' -f $operation)+[Environment]::NewLine)
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('{0}|complete|{1}|{2}' -f $ordinal,$operation,$status)+[Environment]::NewLine)
return $result
'@
    $scriptText = $scriptText.Replace('__OPERATION_LOG_PATH__',$operationLogPath.Replace("'","''"))
    $scriptText = $scriptText.Replace('__RADIO_STATE_PATH__',$radioStatePath.Replace("'","''"))
    $scriptText = $scriptText.Replace('__DELAY_QUERY_ORDINAL__',[string]$DelayQueryOrdinal)
    $scriptText = $scriptText.Replace('__DELAY_QUERY_SECONDS__',[string]$DelayQuerySeconds)
    $scriptText = $scriptText.Replace('__UNKNOWN_QUERY_ORDINAL__',[string]$UnknownQueryOrdinal)
    return [scriptblock]::Create($scriptText)
}

function New-UiConsoleMainWindowFromXaml {
    param([Parameter(Mandatory=$true)][string]$XamlPath)
    [xml]$document = [System.IO.File]::ReadAllText($XamlPath,[System.Text.Encoding]::UTF8)
    $reader = New-Object System.Xml.XmlNodeReader($document)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

function Assert-UiConsoleTempPathSafe {
    param([Parameter(Mandatory=$true)][string]$Path)
    $target = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar))
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar))
    $parent = [System.IO.Path]::GetDirectoryName($target)
    if (-not [string]::Equals($parent,$tempRoot,[System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($target) -notmatch '^wirex-r117-console-[0-9a-f]{32}$') {
        throw '拒绝清理测试目录：目标没有通过绝对路径和唯一目录名检查。'
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$xamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
$catUiPath = Join-Path $repoRoot 'ui\windows\RadioCatUi.ps1'
$devicesPath = Join-Path $repoRoot 'ui\windows\RadioDevices.psm1'
$portableConfigModulePath = Join-Path $repoRoot 'ui\windows\PortableConfig.psm1'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw '请使用 -STA 运行测试，以真实 WPF 窗口和 DispatcherTimer 验证交互。'
}
foreach ($path in @($uiPath,$xamlPath,$catUiPath,$devicesPath,$portableConfigModulePath)) {
    if (-not [System.IO.File]::Exists($path)) { throw "缺少测试目标：$path" }
}
Assert-UiConsoleBom -Path $PSCommandPath
Assert-UiConsoleBom -Path $uiPath
Assert-UiConsoleBom -Path $catUiPath

foreach ($path in @($uiPath,$catUiPath)) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw ("{0} parse failed: {1}" -f [System.IO.Path]::GetFileName($path),$parseErrors[0].Message) }
}

$tempName = 'wirex-r117-console-' + [guid]::NewGuid().ToString('N')
$script:testRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) $tempName))
[void][System.IO.Directory]::CreateDirectory($script:testRoot)
Assert-UiConsoleTempPathSafe -Path $script:testRoot
Write-UiConsoleTestProgress 'test-start'
$configDirectory = Join-Path $script:testRoot 'config'
[void][System.IO.Directory]::CreateDirectory($configDirectory)

try {
    Import-Module -Name $devicesPath -Force
    Import-Module -Name $portableConfigModulePath -Force
    $catalog = New-UiConsoleSerialCatalog
    $audioQueue = New-Object System.Collections.Queue
    $audioQueue.Enqueue('error')
    $audioQueue.Enqueue('timeout')
    if ($LiveSerialReadOnly) {
        $script:uiTestHooks = @{}
        $script:uiTestHooks.AudioQuery = {
            param([object]$Context)
            return [pscustomobject]@{ status='success'; wave_inputs=@(); wave_outputs=@() }
        }
    } else {
        $script:uiTestHooks = New-UiConsoleDiscoveryHooks -AudioStatusQueue $audioQueue -Catalog $catalog
        $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook
        $script:uiTestHooks.NativeSupervisorFactory = {
            param([object]$Context)
            $fake = [pscustomobject]@{ HasExited=$false; ProcessId=[uint32]48123; Operation=[string]$Context.operation; StopDelay=$false; StopRequested=$false; StopCallCount=0; StopResult=$null }
            $fake | Add-Member -MemberType ScriptMethod -Name StopAsync -Value {
                param([int]$TimeoutMs)
                $this.StopRequested = $true
                $this.StopCallCount++
                $this.StopResult = [pscustomobject]@{ IsCompleted=(-not [bool]$this.StopDelay) }
                if (-not $this.StopDelay) { $this.HasExited = $true }
                return $this.StopResult
            }
            $fake | Add-Member -MemberType ScriptMethod -Name TryGetExitCode -Value {
                param([ref]$ExitCode)
                $ExitCode.Value = 0
                return $true
            }
            $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.HasExited = $true }
            return $fake
        }
    }

    $portableConfigPath = Join-Path $configDirectory 'config.json'
    $testConfig = Get-WirexPortableConfig -Path $portableConfigPath
    $testConfig.connection.callsign = 'N0TEST'
    $testConfig.connection.gateway_id = [uint64]1
    $testConfig.connection.source_id = [uint64]123456
    $testConfig.connection.master = '127.0.0.1'
    $testConfig.connection.master_port = [uint64]62031
    $testConfig.connection.color_code = [uint64]1
    $testConfig.connection.password = 'ui-console-test-only'
    $testConfig.devices.hri_port = 'COM5'
    $testConfig.devices.cat_port = 'COM11'
    $testConfig.devices.cat_baud_rate = 38400
    $testConfig.devices.cat_stop_bits = 'Two'
    $testConfig.channels = [object[]]@([pscustomobject][ordered]@{ id=[uint64]91; kind='group'; slot=[uint64]2; name='TG91' })
    $testConfig.tx_channel_id = 'group:91:2'
    [void](Save-WirexPortableConfig -Path $portableConfigPath -Config $testConfig)

    . $uiPath -UiTestFixture -NoAutoConnect -UserConfigDirectory $configDirectory -PackageDirectory $repoRoot
    $script:mainWindow = $script:mainWindow
    Assert-UiConsole ($null -ne $script:mainWindow -and $script:mainWindow.IsVisible) 'UiTestFixture did not show the actual MainWindow.'
    Assert-UiConsole ($script:portableConfig -and @($script:portableConfig.channels).Count -eq 1 -and $script:storedProfile) `
        ("isolated config did not produce a usable channel profile; configPath={0}, error={1}, channels={2}, tx={3}" -f `
            $script:portableConfigPath,$script:portableConfigError,@($script:portableConfig.channels).Count,[string]$script:portableConfig.tx_channel_id)
    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:capturedUiEvents = New-Object 'System.Collections.Generic.List[string]'
    $script:originalAddUiEvent = (Get-Command Add-UiEvent -CommandType Function -ErrorAction Stop).ScriptBlock
    Set-Item -Path Function:\Add-UiEvent -Value {
        param([Parameter(Mandatory=$true)][string]$Text)
        [void]$script:capturedUiEvents.Add($Text)
        & $script:originalAddUiEvent -Text $Text
    }
    $requiredControls = @(
        'RadioCatPanel','CatPortBox','CatBaudRateBox','SerialConnectButton','ConnectButton','CatOperatingPanel',
        'CatObservedPanel','CatObservedMainModeText',
        'CatObservedFrequencyText','CatObservedPowerText','CatMainModeBox','CatMainFrequencyMHzBox',
        'CatPowerBox','CatModeCaptionText','CatFrequencyCaptionText','CatPowerCaptionText','ApplyCatSettingsButton','SerialBox',
        'RefreshDevicesButton','RadioDetailsExpander','MasterPresetBox','MasterBox','MasterPortBox',
        'BmApiKeyBox','BmStaticGroupPanel','BmStaticGroupsList','StaticApiRequiredOverlay','StaticApiRequiredText',
        'RefreshBmStaticGroupsButton','AddBmStaticGroupButton','TransientStatusText'
    )
    $missingControls = @($requiredControls | Where-Object { $null -eq $script:mainWindow.FindName($_) })
    Assert-UiConsole ($missingControls.Count -eq 0) ('实际 WPF MainWindow 缺少稳定控件：{0}' -f ($missingControls -join ', '))
    foreach ($removedCatApply in @('ApplyCatModeButton','ApplyCatFrequencyButton','ApplyCatPowerButton')) {
        Assert-UiConsole ($null -eq $script:mainWindow.FindName($removedCatApply)) ("旧CAT Apply按钮仍存在：{0}。" -f $removedCatApply)
    }
    Assert-UiConsole ([bool](Get-Command Start-UiRadioCatPolling -ErrorAction SilentlyContinue)) 'RadioCatUi.ps1 was not dot-sourced by bridge-ui.ps1.'

    if ($LiveSerialReadOnly) {
        Assert-UiConsole (-not $script:uiTestHooks.ContainsKey('SerialEnumerator')) 'live serial mode replaced the production worker with a SerialEnumerator hook.'
        Start-UiDeviceDiscovery -UseProductionOrchestration
        $liveDiscoveryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 10000 -Condition {
            $script:deviceSerialState -in @('ready','empty') -and $script:deviceAudioState -ceq 'ready' -and
                -not $script:deviceDiscoveryPowerShell -and -not $script:deviceAudioQuery
        }
        Assert-UiConsole $liveDiscoveryReady 'real registry/CIM catalog did not publish through production discovery orchestration and WPF dispatcher.'
        $liveCatalog = $script:deviceCatalog
        Assert-UiConsole ($null -eq $script:uiTestDiscoveryResult) 'live serial discovery used the fixture-only publisher path.'
        $liveSourceStatuses = @([string]$liveCatalog.source_status.registry,[string]$liveCatalog.source_status.cim)
        Assert-UiConsole ($liveCatalog.source_status.registry -cne 'synthetic' -and $liveCatalog.source_status.cim -cne 'synthetic' -and
            $liveSourceStatuses -contains 'ready') 'live CAT catalog did not come from at least one real registry/CIM source.'
        $script:radioControlPreferences.cat_port = 'auto'
        Set-UiRadioCatDeviceControls
        $expectedPorts = @($liveCatalog.serial_ports | ForEach-Object { [string]$_.PortName } | Sort-Object -Unique)
        $visiblePorts = @(Get-UiConsoleComboValues -Combo (Get-UiConsoleControl 'CatPortBox') | Sort-Object -Unique)
        Assert-UiConsole (@($expectedPorts | Where-Object { $visiblePorts -cnotcontains $_ }).Count -eq 0) 'live Get-RadioDeviceCatalog ports did not all reach the WPF CAT dropdown.'
        Assert-UiConsole (@($visiblePorts | Where-Object { $expectedPorts -cnotcontains $_ }).Count -eq 0) 'WPF CAT dropdown contains ports absent from the live catalog.'
        foreach ($port in @($liveCatalog.hri_ports)) {
            Assert-UiConsole (@((Get-UiConsoleControl 'CatPortBox').Items | Where-Object { $_.Tag.Value -ieq [string]$port.PortName -and $_.Tag.IsAvailable }).Count -eq 0) ('live HRI port {0} was selectable for CAT.' -f $port.PortName)
        }
        $liveRanked = @($liveCatalog.cat_ports | Where-Object {
            [int]$_.CatMatchRank -gt 0 -and -not [bool]$_.IsHri -and [string]$_.PortName -ine (Get-UiHriPortName)
        } | Sort-Object { -[int]$_.CatMatchRank })
        $expectedSelection = $null
        if ($liveRanked.Count -gt 0) {
            $highestRank = [int]$liveRanked[0].CatMatchRank
            $highestMatches = @($liveRanked | Where-Object { [int]$_.CatMatchRank -eq $highestRank })
            if ($highestMatches.Count -eq 1) { $expectedSelection = [string]$highestMatches[0].PortName }
        }
        $selectedPort = Get-UiRadioCatSelectedPort
        if ($expectedSelection) {
            Assert-UiConsole ($selectedPort -ceq $expectedSelection) 'live catalog WPF selection did not use the unique highest-ranked CAT match.'
        } else {
            Assert-UiConsole (-not $selectedPort -and [string]::IsNullOrEmpty((Get-UiConsoleControl 'CatPortBox').Text)) 'live ambiguous/no-match catalog was not left blank for manual selection.'
        }
        Assert-UiConsole (-not $script:supervisor -and -not $script:radioCatOperationPowerShell) 'live serial read-only mode started a core or CAT operation.'
        Assert-UiConsole (-not $script:radioCatPollingActive -and -not $script:radioCatOperationPowerShell) 'read-only live serial discovery started CAT polling or opened a CAT operation.'
        Write-Output ("PASS: test-ui-console.ps1 ({0} read-only live-serial WPF assertions; PowerShell {1})" -f $script:assertionCount,$PSVersionTable.PSVersion)
        return
    }

    Start-UiDeviceDiscovery -UseProductionOrchestration
    $audioErrorReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition {
        $script:deviceSerialState -ceq 'ready' -and $script:deviceAudioState -ceq 'error'
    }
    Assert-UiConsole $audioErrorReady 'audio error blocked serial result publication.'
    Assert-UiConsole ($null -eq $script:uiTestDiscoveryResult) 'audio error regression used the fixture-only publisher path instead of production orchestration.'
    Assert-UiConsole (@($script:deviceCatalog.serial_ports | Where-Object { $_.PortName -ceq 'COM11' }).Count -eq 1) 'serial catalog lost valid COM11 after audio error.'
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11') ('CAT did not auto-select the unique Enhanced CP2105 port after audio error; selected={0}.' -f [string](Get-UiRadioCatSelectedPort))
    Assert-UiConsole (-not $script:radioCatPortSelectionExplicit) 'automatic Enhanced port selection was incorrectly saved as a manual choice.'

    Start-UiDeviceDiscovery -UseProductionOrchestration
    $audioTimeoutReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition {
        $script:deviceSerialState -ceq 'ready' -and $script:deviceAudioState -ceq 'timeout'
    }
    Assert-UiConsole $audioTimeoutReady 'audio timeout blocked serial result publication.'
    Assert-UiConsole ($null -eq $script:uiTestDiscoveryResult) 'audio timeout regression used the fixture-only publisher path instead of production orchestration.'
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11') ('CAT selection was lost after audio timeout; selected={0}.' -f [string](Get-UiRadioCatSelectedPort))

    $catPortBox = Get-UiConsoleControl 'CatPortBox'
    Set-UiConsoleManualCatPort -PortName COM99
    Assert-UiConsole ([bool]$script:radioCatPortSelectionExplicit) 'real CAT port text editing did not mark the selection explicit.'
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM99') ('manual CAT COM port entry was rejected without discovery metadata; selected={0}, text={1}, editExplicit={2}, selectionExplicit={3}, tag={4}, focused={5}.' -f `
        [string](Get-UiRadioCatSelectedPort),[string]$catPortBox.Text,[bool]$script:radioCatPortTextEditExplicit,[bool]$script:radioCatPortSelectionExplicit, `
        [string]$catPortBox.SelectedItem.Tag.Value,[bool]$catPortBox.Template.FindName('PART_EditableTextBox',$catPortBox).IsKeyboardFocusWithin)
    Set-UiConsoleManualCatPort -PortName COM5
    Assert-UiConsole ($null -eq (Get-UiRadioCatSelectedPort)) 'known HRI port COM5 was accepted as CAT.'
    Select-UiConsoleCatPortOption -PortName COM11
    Assert-UiConsole ([bool]$script:radioCatPortSelectionExplicit) 'a real CAT dropdown selection was not marked explicit for preference persistence.'

    $secondEnhancedRecord = [pscustomobject]@{ PortName='COM12'; FriendlyName='Silicon Labs Dual CP2105 USB to UART Bridge: Enhanced COM Port (COM12)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\FAKE2'; HardwareIds=@(); DeviceSource='synthetic' }
    $expandedRecords = @(
        [pscustomobject]@{ PortName='COM5'; FriendlyName='USB Serial Device (COM5)'; InstanceId='USB\VID_26AA&PID_0030\FAKE-HRI'; HardwareIds=@(); DeviceSource='synthetic' },
        [pscustomobject]@{ PortName='COM11'; FriendlyName='Silicon Labs Dual CP2105 USB to UART Bridge: Enhanced COM Port (COM11)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\FAKE'; HardwareIds=@(); DeviceSource='synthetic' },
        $secondEnhancedRecord
    )
    $script:deviceCatalog = Get-RadioDeviceCatalog -SerialPortsInput $expandedRecords
    $script:radioControlPreferences.cat_port = 'auto'
    Set-UiRadioCatDeviceControls
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11' -and
        [object]::ReferenceEquals($catPortBox.SelectedItem,(@($catPortBox.Items | Where-Object { $_.Tag.Value -ceq 'COM11' })[0]))) `
        'adding another Enhanced CP2105 port displaced the explicitly selected COM11.'
    $script:radioControlPreferences.cat_port = 'COM11'
    $script:radioCatPortSelectionExplicit = $false
    $script:radioCatPortTextEditExplicit = $false
    $staleCatalogRecords = @(
        [pscustomobject]@{ PortName='COM5'; FriendlyName='USB Serial Device (COM5)'; InstanceId='USB\VID_26AA&PID_0030\FAKE-HRI'; HardwareIds=@(); DeviceSource='synthetic' },
        [pscustomobject]@{ PortName='COM10'; FriendlyName='Generic UART Interface (COM10)'; InstanceId='ACME\UART\FAKE'; HardwareIds=@(); DeviceSource='synthetic' }
    )
    $script:deviceCatalog = Get-RadioDeviceCatalog -SerialPortsInput $staleCatalogRecords
    Set-UiRadioCatDeviceControls
    Assert-UiConsole (-not (Get-UiRadioCatSelectedPort) -and [string]::IsNullOrEmpty((Get-UiConsoleControl 'CatPortBox').Text)) 'stale saved COM11 was restored although the current catalog has no COM11 or unique CAT-ranked match.'
    Assert-UiConsole (-not $script:radioCatPortSelectionExplicit) 'device repopulation incorrectly marked a stale preference as a manual selection.'
    $script:deviceCatalog = $catalog
    $script:radioControlPreferences.cat_port = 'auto'
    Set-UiRadioCatDeviceControls
    $script:deviceSerialState = 'ready'
    $script:deviceDiscoveryState = 'ready'
    $script:activeHriPortName = 'COM5'

    if ($script:settingsWindow) { $script:settingsWindow.Close() }
    $script:settingsWindow = $null
    Initialize-UiRadioCatController
    Assert-UiConsole ($null -eq $script:mainWindow.FindName('CatStopBitsBox')) 'CAT stop-bits control should not be required in the main-window XAML.'
    Assert-UiConsole ((Get-UiRadioCatStopBits) -ceq 'Two') 'CAT serial framing was not fixed internally to 8N2 without requiring a stop-bits control.'
    Assert-UiConsole ((Get-UiConsoleControl 'RadioCatPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'main-window CAT controls disappeared when settingsWindow was null.'
    Assert-UiConsole ([int]$script:radioCatPollIntervalMs -eq 1000) 'default CAT poll interval is not 1 second.'
    $stableCatPortItem = (Get-UiConsoleControl 'CatPortBox').SelectedItem
    $stableCatPanelVisibility = (Get-UiConsoleControl 'RadioCatPanel').Visibility
    $stableCatOperatingVisibility = (Get-UiConsoleControl 'CatOperatingPanel').Visibility
    for ($catalogTick = 0; $catalogTick -lt 3; $catalogTick++) { Set-UiRadioCatDeviceControls }
    Assert-UiConsole ([object]::ReferenceEquals($stableCatPortItem,(Get-UiConsoleControl 'CatPortBox').SelectedItem) -and
        (Get-UiConsoleControl 'RadioCatPanel').Visibility -eq $stableCatPanelVisibility -and
        (Get-UiConsoleControl 'CatOperatingPanel').Visibility -eq $stableCatOperatingVisibility) 'unchanged device catalogs rebuilt CAT controls or changed panel visibility.'

    $catPortBox = Get-UiConsoleControl 'CatPortBox'
    Set-UiConsoleManualCatPort -PortName COM99
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM99') ('manual CAT COM port entry was rejected without discovery metadata; selected={0}, text={1}, editExplicit={2}, selectionExplicit={3}, tag={4}, focused={5}.' -f `
        [string](Get-UiRadioCatSelectedPort),[string]$catPortBox.Text,[bool]$script:radioCatPortTextEditExplicit,[bool]$script:radioCatPortSelectionExplicit, `
        [string]$catPortBox.SelectedItem.Tag.Value,[bool]$catPortBox.Template.FindName('PART_EditableTextBox',$catPortBox).IsKeyboardFocusWithin)
    Start-UiRadioCatOperation -Operation 'query' -StopBitsOverride 'One'
    Assert-UiConsole ([string]$script:radioCatOperationStopBits -ceq 'Two') 'legacy stop-bits override changed the internal CAT framing from Two.'
    $manualPortQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $manualPortQueryReady 'manual COM99 did not submit through the CAT operation path.'
    Assert-UiConsole ([string]$script:radioCatObservedPortName -ceq 'COM99') 'manual CAT query did not retain the selected COM99 identity.'
    Assert-UiConsole ([string]$script:radioCatObservedConnectionKey -match '\|Two$') 'manual CAT query identity did not retain the fixed Two stop bits.'
    Set-UiConsoleManualCatPort -PortName COM5
    $hriConflictRejected = $false
    try { Start-UiRadioCatOperation -Operation 'query' -PortNameOverride 'COM5' } catch { $hriConflictRejected = $_.Exception.Message -match 'HRI|不能用于 CAT' }
    Assert-UiConsole $hriConflictRejected 'CAT operation accepted the same COM5 port that the active profile assigns to HRI.'
    Select-UiConsoleCatPortOption -PortName COM11
    Update-UiRadioCatControls

    Assert-UiConsole ([string]::IsNullOrEmpty([string]$script:portableConfig.connection.api_key) -and
        [string]::IsNullOrEmpty([string](Get-UiConsoleControl 'BmApiKeyBox').Password)) 'API-empty fixture is not isolated from any stored API key.'
    Assert-UiConsole ((Get-UiConsoleControl 'BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'StaticApiRequiredOverlay').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'StaticApiRequiredText').Text -ceq '需启用BM API key' -and
        (Get-UiConsoleControl 'BmStaticGroupsList').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'BmStaticGroupsList').Items.Count -eq 0 -and
        -not (Get-UiConsoleControl 'BmStaticGroupsList').IsEnabled -and
        -not (Get-UiConsoleControl 'RefreshBmStaticGroupsButton').IsEnabled -and
        -not (Get-UiConsoleControl 'AddBmStaticGroupButton').IsEnabled) 'API-empty state did not hide/disable only BM static-group management.'
    $script:radioControlPreferences.desired_power_watts = 40
    Invoke-UiConsoleClick -Name 'ConnectButton'
    $connected = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { $script:supervisor -and -not $script:supervisor.HasExited }
    $settingsError = if ($script:mainWindow.FindName('SettingsErrorText')) { [string]$script:mainWindow.FindName('SettingsErrorText').Text } else { '' }
    Assert-UiConsole $connected ("real ConnectButton did not pass through the fake native supervisor seam; profileEditable={0}, startupNeedsSettings={1}, storedProfile={2}, footer={3}, settingsError={4}" -f `
        [bool]$script:profileEditable,[bool]$script:startupNeedsSettings,[bool]$script:storedProfile,[string]$script:mainWindow.FindName('TransientStatusText').Text,$settingsError)
    Assert-UiConsole (-not (Get-UiRadioCatSessionState).requested -and -not $script:radioCatOperationPowerShell -and
        -not (Get-UiConsoleControl 'CatPortBox').IsEnabled -and (Get-UiConsoleControl 'CatOperatingPanel').IsEnabled) `
        '隔离UiTestFixture在核心连接后触发了CAT物理自动连接，或核心占用时仍开放串口选择。'
    [void](Connect-UiRadioCatSession)
    $firstQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole ($firstQueryReady -and (Get-UiRadioCatSessionState).requested -and (Get-UiRadioCatSessionState).connected -and
        -not (Get-UiConsoleControl 'CatPortBox').IsEnabled) 'UI test fixture 中的手动 CAT fake session 没有独立连接并完成首读。'
    Assert-UiConsole ([string]$script:radioCatObservedConnectionKey -match '\|Two$') 'fake CAT operation did not use internal Two stop bits.'

    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    $catDisconnectReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition {
        -not $script:radioCatOperationPowerShell -and -not (Get-UiRadioCatSessionState).requested
    }
    Assert-UiConsole ($catDisconnectReady -and $script:supervisor -and -not $script:supervisor.HasExited -and
        -not (Get-UiConsoleControl 'CatPortBox').IsEnabled -and -not (Get-UiConsoleControl 'CatBaudRateBox').IsEnabled) `
        'CAT fake 会话断开应与核心退出分离，且核心占用期间继续锁定串口设备选择。'
    Assert-UiConsole ([string]$script:radioCatObserved.radio_id.value -ceq '0840' -and [int]$script:radioCatObserved.power.value.watts -eq 25) 'first query did not publish ID 0840 and actual 25 W state.'
    $fakeProcessId = [uint32]$script:supervisor.ProcessId
    $fakeReadyStatus = [pscustomobject][ordered]@{
        run_id=('{0}-1' -f $fakeProcessId); seq=[int64]1
        timestamp_utc_ms=[int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); elapsed_ms=[int64]1000
        event='runtime_snapshot'; bm_state='ready'; bm_failure='none'; radio_state='unknown'; hri_phase='exchanging'
        audio_endpoints_validated=$true; hri_serial_open=$true; hri_ready=$true; hri_y_zero_ready=$true
        wavein_state='open'; waveout_state='open'; last_rx_header_valid=$false; last_rx_source_id=[int64]0
        last_rx_destination_id=[int64]0; last_rx_slot=[int64]1; last_rx_call_kind='G'
        current_call_valid=$false; current_call_phase='none'; current_call_source_id=[int64]0
        current_call_destination_id=[int64]0; current_call_slot=[int64]0; current_call_kind='none'
        current_call_color_code=[int64]0; current_call_link_control_validated=$false
        current_call_color_code_known=$false; current_call_generation=[int64]0; receive_media_state='idle'
    }
    Assert-UiConsole (Test-UiRunRecordAcceptance -Record $fakeReadyStatus -ExpectedProcessId $fakeProcessId `
        -LockedRunId '' -LastSequence 0 -NowUtcMs ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) `
        'synthetic BM/HRI-ready status record did not meet the ordinary metadata checks.'
    Apply-StatusRecord -Record $fakeReadyStatus
    $script:uiConsoleFakeIdleHeartbeatEnabled = $true
    Assert-UiConsole ([string](Get-UiConsoleControl 'BmValue').Text -ceq '已连接' -and
        [string]$script:latestStatus.bm_state -ceq 'ready' -and [bool]$script:latestStatus.hri_ready) `
        'API-empty fake Connect did not progress to the synthetic BM/HRI-ready UI state.'
    Assert-UiConsole ((Get-UiConsoleControl 'BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'StaticApiRequiredOverlay').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'BmStaticGroupsList').Items.Count -eq 0 -and
        -not (Get-UiConsoleControl 'BmStaticGroupsList').IsEnabled -and
        -not (Get-UiConsoleControl 'RefreshBmStaticGroupsButton').IsEnabled -and
        -not (Get-UiConsoleControl 'AddBmStaticGroupButton').IsEnabled) 'BM/HRI-ready connection state incorrectly enabled API-dependent static-group management without an API key.'
    Assert-UiConsole (-not (Get-UiRadioCatSessionState).requested -and -not (Get-UiRadioCatSessionState).connected -and
        $script:radioCatManualDisconnect -and $script:supervisor -and -not $script:supervisor.HasExited) `
        ("HRI ready status reopened CAT after manual disconnect or disturbed the live core; port={0}, key={1}, selected={2}, text={3}, explicit={4}, result={5}, busy={6}" -f (Get-UiRadioCatSelectedPort), (Get-UiRadioCatConnectionKey), [string]$catPortBox.SelectedItem.Tag.Value, [string]$catPortBox.Text, [bool]$script:radioCatPortSelectionExplicit, [string]$script:radioCatResult.status, [bool]$script:radioCatOperationPowerShell)
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'CAT observation panel did not remain visible after the first confirmed read.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedMainModeText').Text -ceq 'FM' -and
        (Get-UiConsoleControl 'CatObservedFrequencyText').Text -ceq '145.5 MHz' -and
        (Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '25 W') 'CAT readout did not show only the observed mode, frequency, and power values.'
    $initialCatReadout = @((Get-UiConsoleControl 'CatObservedMainModeText').Text,(Get-UiConsoleControl 'CatObservedFrequencyText').Text,(Get-UiConsoleControl 'CatObservedPowerText').Text) -join ' '
    Assert-UiConsole ($initialCatReadout -notmatch '0840|FTX-1|CAT-1|CAT test transport|[0-9]{2}:[0-9]{2}:[0-9]{2}') 'CAT readout exposed an internal identity, transport label, or timestamp.'
    Assert-UiConsole (-not (Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) 'CAT Apply was enabled before the user created a draft.'
    Write-UiConsoleTestProgress 'initial CAT read and stable readout passed'
    Assert-UiConsole ([bool](Connect-UiRadioCatSession)) 'explicit CAT reconnect after validating the manual-disconnect latch was rejected.'
    $explicitReconnectQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole ($explicitReconnectQueryReady -and (Get-UiRadioCatSessionState).connected) 'explicit CAT reconnect did not complete a fresh initial query.'
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow

    Set-UiConsoleCatPower -Watts 15
    Assert-UiConsole ([int]$script:radioCatEditDraft.power -eq 15) 'real power-combo selection did not retain a 15 W draft.'
    (Get-UiConsoleControl 'CatMainModeBox').SelectedItem = @((Get-UiConsoleControl 'CatMainModeBox').Items | Where-Object { [string]$_.Tag -ceq 'FM-N' })[0]
    (Get-UiConsoleControl 'CatMainFrequencyMHzBox').Text = '145.600'
    Assert-UiConsole ([string]$script:radioCatEditDraft.mode -ceq 'FM-N' -and [string]$script:radioCatEditDraft.frequency -ceq '145.600') `
        'real MAIN mode/frequency controls did not create the settings drafts.'
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) 'drafted MAIN mode, frequency, and power did not enable the shared Apply button.'
    $script:radioControlPreferences.desired_power_watts = 40
    [void](Invoke-UiRadioCatPollTick -Force)
    $pollReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $pollReady 'bounded CAT poll did not complete.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 30) 'poll did not update actual hardware state from 25 W to 30 W.'
    Assert-UiConsole ([int](Get-UiConsoleControl 'CatPowerBox').SelectedItem.Tag -eq 15 -and [int]$script:radioCatEditDraft.power -eq 15) 'poll overwrote the user 15 W draft with actual 30 W.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPowerText').Text -match '30 W') 'actual power display did not follow the poll result.'

    Invoke-UiRadioCatAction -Operation 'query'
    $manualQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $manualQueryReady 'explicit CAT query action did not run a query.'

    $setPowerOrdinal = [int]$script:radioCatOperationOrdinal
    $settingsSupervisor = $script:supervisor
    $settingsStopCount = [int]$settingsSupervisor.StopCallCount
    $settingsLogPath = Join-Path $script:testRoot 'cat-operations.log'
    $settingsLogStart = @([System.IO.File]::ReadAllLines($settingsLogPath)).Count
    Invoke-UiConsoleClick -Name 'ApplyCatSettingsButton'
    Assert-UiConsole (([string]$script:radioCatQueuedAction.operation -ceq 'setSettings') -or
        $script:radioCatSettingsApply -or [string]$script:radioCatOperationKind -ceq 'query') `
        ("single Apply click did not start/freeze the settings batch; draft={0}/{1}/{2}, queued={3}, kind={4}, ordinal={5}" -f `
            $script:radioCatEditDraft.mode,$script:radioCatEditDraft.frequency,$script:radioCatEditDraft.power,
            [string]$script:radioCatQueuedAction.operation,[string]$script:radioCatOperationKind,
            [int]$script:radioCatOperationOrdinal)
    $setReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 15 -and
            [string]$script:radioCatObserved.main_mode.value.mode -ceq 'FM-N' -and
            [long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and
            -not $script:radioCatOperationPowerShell -and -not $script:radioCatSettingsApply -and -not $script:radioCatQueuedAction
    }
    $catOperationHistory = if (Test-Path -LiteralPath (Join-Path $script:testRoot 'cat-operations.log')) { [string](Get-Content -LiteralPath (Join-Path $script:testRoot 'cat-operations.log') -Raw) } else { '' }
    Assert-UiConsole $setReady ("single CAT settings batch did not finish within its bound; ordinal={0}/{1}, kind={2}, result={3}/{4}, queued={5}, session={6}/{7}, catGen={8}, observedKey={9}, currentKey={10}, notice={11}, operations={12}" -f `
        [int]$script:radioCatOperationOrdinal,$setPowerOrdinal,[string]$script:radioCatOperationKind,[string]$script:radioCatResult.operation,
        [string]$script:radioCatResult.status,[string]$script:radioCatQueuedAction.operation,[bool](Get-UiRadioCatSessionState).requested,
        [bool](Get-UiRadioCatSessionState).connected,[int](Get-UiRadioCatSessionState).generation,[string]$script:radioCatObservedConnectionKey,
        [string](Get-UiRadioCatConnectionKey),[string](Get-UiRadioCatSessionState).error,$catOperationHistory)
    $powerReadbackReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 3000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 15 -and $null -eq $script:radioCatEditDraft.power
    }
    $appliedWatts = [int]$script:radioCatObserved.power.value.watts
    $confirmedPowerWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|complete\|setPower\|confirmed\r?$')).Count
    $settingsLogNow = @([System.IO.File]::ReadAllLines($settingsLogPath))
    $settingsOperations = @($settingsLogNow | Select-Object -Skip $settingsLogStart | Where-Object { $_ -match '^\d+\|(query|setMode|setFrequency|setPower)$' } | ForEach-Object { ($_ -split '\|')[1] })
    Assert-UiConsole ($powerReadbackReady -and $appliedWatts -eq 15 -and $confirmedPowerWriteCount -eq 1 -and
        $settingsOperations.Count -eq 4 -and ($settingsOperations -join ',') -ceq 'query,setMode,setFrequency,setPower' -and
        [int]$settingsSupervisor.StopCallCount -eq $settingsStopCount -and -not $settingsSupervisor.HasExited) `
        ("single Apply did not complete query→mode→frequency→power readbacks while HRI stayed live; result={0}, status={1}, operations={2}, writes={3}, stop_calls={4}/{5}, supervisor={6}" -f `
            $appliedWatts,$script:radioCatLastOperationStatus,($settingsOperations -join ','),$confirmedPowerWriteCount,
            [int]$settingsSupervisor.StopCallCount,$settingsStopCount,[bool]$settingsSupervisor.HasExited)
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 15 -and
        [string]$script:radioCatObserved.main_mode.value.mode -ceq 'FM-N' -and
        [long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and
        $null -eq $script:radioCatEditDraft.power -and $null -eq $script:radioCatEditDraft.mode -and $null -eq $script:radioCatEditDraft.frequency) `
        'shared Apply readback did not update mode, frequency, and power or clear their drafts.'

    Set-UiConsoleCatPower -Watts 25
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) 'confirmed SPA-1 state did not enable the explicit 25 W candidate before the changed path was known.'
    Invoke-UiConsoleClick -Name 'ApplyCatSettingsButton'
    $rejectedPowerReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [string]$script:radioCatObserved.power.value.path -ceq 'FieldHead' -and [int]$script:radioCatObserved.power.value.watts -eq 5
    }
    Assert-UiConsole $rejectedPowerReady 'FieldHead range rejection did not complete.'
    $rejectedPowerReadbackReady = $rejectedPowerReady
    $rejectedPowerWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|complete\|setPower\|rejected\r?$')).Count
    Assert-UiConsole ($rejectedPowerReadbackReady -and $rejectedPowerWriteCount -eq 1) 'rejected power request was not executed once or its verified FieldHead 5 W readback was lost.'
    $catPowerBoxAfterLimit = Get-UiConsoleControl 'CatPowerBox'
    $fieldHeadTenWatts = @($catPowerBoxAfterLimit.Items | Where-Object { [string]$_.Tag -ceq '10' } | Select-Object -First 1)
    $fieldHeadTwentyFiveWatts = @($catPowerBoxAfterLimit.Items | Where-Object { [string]$_.Tag -ceq '25' } | Select-Object -First 1)
    Assert-UiConsole ($fieldHeadTenWatts.Count -eq 1 -and $fieldHeadTenWatts[0].IsEnabled -and
        $fieldHeadTwentyFiveWatts.Count -eq 1 -and -not $fieldHeadTwentyFiveWatts[0].IsEnabled -and
        (Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '5 W' -and
        -not (Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) 'rejected FieldHead readback did not update the 10 W limit while removing write permission.'
    Assert-UiConsole ([int]$script:radioControlPreferences.desired_power_watts -eq 15) 'rejected power request overwrote the last confirmed power preference.'

    Invoke-UiRadioCatAction -Operation 'query'
    $fieldHeadQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $fieldHeadQueryReady 'CAT query did not restore permission after the rejected FieldHead request.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 5 -and [string]$script:radioCatObserved.power.value.path -ceq 'FieldHead') 'confirmed FieldHead query did not retain the actual path and 5 W value.'
    (Get-UiConsoleControl 'CatMainModeBox').SelectedItem = @((Get-UiConsoleControl 'CatMainModeBox').Items | Where-Object { [string]$_.Tag -ceq 'FM-N' })[0]
    (Get-UiConsoleControl 'CatMainFrequencyMHzBox').Text = '145.600'
    Set-UiConsoleCatPower -Watts 10
    Update-UiRadioCatControls
    Assert-UiConsole ([int]$script:radioCatEditDraft.power -eq 10 -and (Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) 'real power-combo selection did not immediately enable a legal 10 W FieldHead draft.'
    Invoke-UiConsoleClick -Name 'ApplyCatSettingsButton'
    $fieldHeadSetReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 10 -and $null -eq $script:radioCatEditDraft.power
    }
    $fieldHeadLog = if (Test-Path -LiteralPath (Join-Path $script:testRoot 'cat-operations.log')) { [string](Get-Content -LiteralPath (Join-Path $script:testRoot 'cat-operations.log') -Raw) } else { '' }
    Assert-UiConsole $fieldHeadSetReady ("legal FieldHead power operation did not finish; kind={0}, status={1}, result={2}/{3}, apply={4}, queued={5}, notice={6}, power={7}, draft={8}, logs={9}" -f `
        [string]$script:radioCatOperationKind,[string]$script:radioCatLastOperationStatus,[string]$script:radioCatResult.operation,
        [string]$script:radioCatResult.status,[bool]$script:radioCatSettingsApply,[string]$script:radioCatQueuedAction.operation,
        [string](Get-UiRadioCatSessionState).error,[string]$script:radioCatObserved.power.value.watts,[string]$script:radioCatEditDraft.power,$fieldHeadLog)
    $fieldHeadPowerReadbackReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 3000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 10 -and $null -eq $script:radioCatEditDraft.power -and
            -not $script:radioCatOperationPowerShell -and -not $script:radioCatSettingsApply
    }
    Assert-UiConsole ($fieldHeadPowerReadbackReady -and [int]$script:radioCatObserved.power.value.watts -eq 10 -and $null -eq $script:radioCatEditDraft.power -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 10) 'confirmed 10 W FieldHead readback did not update actual and saved-preference state.'

    $powerStampBeforeTimeout = [string]$script:radioCatObserved.power.updated_at_utc
    $powerTextBeforeTimeout = [string](Get-UiConsoleControl 'CatObservedPowerText').Text
    $disconnectEventCountBefore = @($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT串口从设备列表消失' }).Count
    # Reconnect explicitly before testing detach recovery; a manual CAT disconnect
    # blocks automatic CAT reopen on later HRI reconnects.
    Assert-UiConsole ([bool](Connect-UiRadioCatSession)) 'explicit CAT reconnect did not clear the manual-disconnect latch.'
    $rearmQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole ($rearmQueryReady -and (Get-UiRadioCatSessionState).connected) 'explicit CAT reconnect did not finish its initial read.'
    $script:deviceCatalog = Get-RadioDeviceCatalog -SerialPortsInput $staleCatalogRecords
    $script:deviceSerialState = 'ready'
    $script:deviceDiscoveryState = 'ready'
    Set-UiRadioCatDeviceControls
    $detachedPollOrdinal = [int]$script:radioCatOperationOrdinal
    for ($pollAttempt = 0; $pollAttempt -lt 3; $pollAttempt++) { [void](Invoke-UiRadioCatPollTick -Force) }
    Assert-UiConsole (-not $script:radioCatOperationPowerShell -and [int]$script:radioCatOperationOrdinal -eq $detachedPollOrdinal -and
        $script:radioCatPollingActive -and -not $script:radioCatPollingConnectionKey) ("detached COM11 kept creating CAT workers instead of waiting for re-enumeration; active={0}, key='{1}', operation={2}, ordinal={3}/{4}, selected='{5}', serialState={6}, ports={7}" -f `
            [bool]$script:radioCatPollingActive,[string]$script:radioCatPollingConnectionKey,[string]$script:radioCatOperationKind,[int]$script:radioCatOperationOrdinal,$detachedPollOrdinal,(Get-UiRadioCatSelectedPort),[string]$script:deviceSerialState,(@($script:deviceCatalog.serial_ports | ForEach-Object { [string]$_.PortName }) -join ','))
    Assert-UiConsole ($script:radioCatResult -eq $null -and [int]$script:radioCatObserved.power.value.watts -eq 10 -and
        [string]$script:radioCatObserved.power.updated_at_utc -ceq $powerStampBeforeTimeout -and
        [string](Get-UiConsoleControl 'CatObservedPowerText').Text -ceq $powerTextBeforeTimeout -and
        (Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'detach invalidated write permission or erased the last actual CAT display.'
    Assert-UiConsole (@($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT串口从设备列表消失' }).Count -eq ($disconnectEventCountBefore + 1)) 'CAT detach event was not recorded exactly once while repeated polls waited.'
    Assert-UiConsole ([string](Get-UiConsoleControl 'TransientStatusText').Text -match 'CAT串口从设备列表消失') 'CAT detach transition did not reach the transient MainWindow event display.'
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11') 'detached explicit CAT port was lost before a re-enumeration could restore it.'
    $failedQueryOrdinal = [int]$script:radioCatOperationOrdinal
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -UnknownQueryOrdinal ($failedQueryOrdinal + 1)
    Start-UiRadioCatOperation -Operation 'query'
    $failedQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        -not $script:radioCatOperationPowerShell -and $script:radioCatLastOperationStatus -ceq 'unknown' -and $null -eq $script:radioCatResult
    }
    Assert-UiConsole $failedQueryReady 'synthetic timeout query did not complete.'
    Assert-UiConsole ($null -eq $script:radioCatResult -and -not (Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) ("query timeout left an old write permit enabled; ordinal={0}, status={1}, result={2}/{3}, button={4}" -f $script:radioCatOperationOrdinal,$script:radioCatLastOperationStatus,[string]$script:radioCatResult.operation,[string]$script:radioCatResult.status,(Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled)
    Assert-UiConsole (@($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT状态读取失败' }).Count -eq 1) 'CAT query failure did not create a single transition event.'
    Assert-UiConsole ((Get-UiConsoleControl 'TransientStatusText').Visibility -eq [System.Windows.Visibility]::Visible -and
        [string](Get-UiConsoleControl 'TransientStatusText').Text -match '读取电台状态|CAT状态读取失败') `
        ('CAT query failure did not leave a transient failure notice; text={0}' -f [string](Get-UiConsoleControl 'TransientStatusText').Text)
    Assert-UiConsole (-not (Get-UiConsoleControl 'ApplyCatSettingsButton').IsEnabled) 'query timeout left the unified CAT settings write enabled.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 10 -and
        [string]$script:radioCatObserved.power.updated_at_utc -ceq $powerStampBeforeTimeout) 'query timeout replaced the last actual value or its original timestamp.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        [string](Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '10 W' -and
        (Get-UiRadioCatSessionState).requested) 'query timeout hid the last value or ended the independent CAT polling session.'
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -UnknownQueryOrdinal -2
    $script:radioCatEditDraft.mode = 'FM-N'
    $script:radioCatEditDraft.frequency = '145.600'
    $script:radioCatEditDraft.power = 20
    Update-UiRadioCatControls
    $failedPermitWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|set(Power|Mode|Frequency)\r?$')).Count
    Invoke-UiRadioCatAction -Operation 'setSettings'
    $failedPermitQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        -not $script:radioCatOperationPowerShell -and $null -eq $script:radioCatQueuedAction -and
        $null -eq $script:radioCatPendingModeFrequencyRequest -and $null -eq $script:radioCatSettingsApply -and
        $null -eq $script:radioModeApplyAfterStop
    }
    $failedPermitWriteCountAfter = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|set(Power|Mode|Frequency)\r?$')).Count
    Assert-UiConsole ($failedPermitQueryReady -and $failedPermitWriteCountAfter -eq $failedPermitWriteCount) `
        'failed CAT queries did not cancel the frozen user action without any write.'
    $script:radioCatEditDraft.mode = $null
    $script:radioCatEditDraft.frequency = $null
    $script:radioCatEditDraft.power = $null
    Update-UiRadioCatControls

    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook
    $script:deviceCatalog = $catalog
    Set-UiRadioCatDeviceControls
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11') 'CAT selection was not restored when COM11 reappeared in the device catalog.'
    $reattachStarted = [bool](Invoke-UiRadioCatPollTick -Force)
    $reattachOrdinal = [int]$script:radioCatOperationOrdinal
    Assert-UiConsole ($reattachStarted -and $script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -ceq 'query') 're-enumerating COM11 did not restart one CAT query.'
    $busyPanelVisibility = (Get-UiConsoleControl 'CatObservedPanel').Visibility
    $busyOperatingVisibility = (Get-UiConsoleControl 'CatOperatingPanel').Visibility
    $busyCatSessionRequested = [bool](Get-UiRadioCatSessionState).requested
    for ($updateAttempt = 0; $updateAttempt -lt 3; $updateAttempt++) { Update-UiRadioCatControls }
    $duplicateQueryRejected = $false
    try { Start-UiRadioCatOperation -Operation 'query' } catch { $duplicateQueryRejected = $_.Exception.Message -match '另一项|尚未结束' }
    $busyNotice = [string](Get-UiConsoleControl 'TransientStatusText').Text
    Assert-UiConsole ($duplicateQueryRejected -and [int]$script:radioCatOperationOrdinal -eq $reattachOrdinal -and
        $script:radioCatOperationPowerShell -and $busyCatSessionRequested -and (Get-UiRadioCatSessionState).requested -and
        (Get-UiConsoleControl 'CatObservedPanel').Visibility -eq $busyPanelVisibility -and
        (Get-UiConsoleControl 'CatOperatingPanel').Visibility -eq $busyOperatingVisibility -and
        $busyNotice -notmatch '操作中') 'busy CAT refresh changed panel visibility, started a second worker, or displayed a permanent working label.'
    $reattachReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $reattachReady 'CAT read did not recover after the detached port was re-enumerated.'
    Assert-UiConsole ($script:radioCatPollingActive -and $script:radioCatResult -and
        [string]$script:radioCatResult.operation -ceq 'query' -and [string]$script:radioCatResult.status -ceq 'confirmed' -and
        [int]$script:radioCatObserved.power.value.watts -eq 10 -and
        [string]$script:radioCatObserved.power.updated_at_utc -cne $powerStampBeforeTimeout -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 10 -and
        $null -eq $script:radioCatEditDraft.power) 'reconnected read did not update only observed state while retaining the desired power setting.'
    Write-UiConsoleTestProgress 'detach, timeout, and COM11 recovery passed'
    Assert-UiConsole (@($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT状态读取已恢复' }).Count -eq 1) 'CAT recovery did not create one transition event.'
    Assert-UiConsole ([string](Get-UiConsoleControl 'TransientStatusText').Text -match 'CAT状态读取已恢复') 'CAT recovery transition did not reach the transient MainWindow event display.'
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '10 W' -and $script:radioCatResult -and
        [string]$script:radioCatResult.operation -ceq 'query' -and [string]$script:radioCatResult.status -ceq 'confirmed') `
        'successful reconnect did not preserve the CAT view and confirmed readback; write controls remain gated until the user creates a valid draft.'
    $permitRefreshReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $permitRefreshReady 'a successful CAT read did not restore write permission after the synthetic timeout.'
    Write-UiConsoleTestProgress 'CAT settings batch and failed-query cancellation passed'

    $exitPowerText = [string](Get-UiConsoleControl 'CatObservedPowerText').Text
    $exitQueryOrdinalExpected = [int]$script:radioCatOperationOrdinal + 1
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -DelayQueryOrdinal $exitQueryOrdinalExpected -DelayQuerySeconds 2
    $script:radioCatPollNextUtc = [DateTime]::UtcNow.AddMinutes(10)
    # Unified CAT Apply leaves the core running. Reuse it when testing its
    # independent self-exit path; reconnect only if an earlier lifecycle check stopped it.
    $exitCoreWasAlreadyLive = [bool]($script:supervisor -and -not $script:supervisor.HasExited)
    if (-not $exitCoreWasAlreadyLive) { Invoke-UiConsoleClick -Name 'ConnectButton' }
    $exitCoreStarted = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition { $script:supervisor -and -not $script:supervisor.HasExited }
    Assert-UiConsole $exitCoreStarted 'live or newly connected HRI core was unavailable for the native exit probe.'
    $exitQueryStarted = [bool](Invoke-UiRadioCatPollTick -Force)
    if (-not $exitQueryStarted) {
        $exitQueryStarted = Invoke-UiConsoleDispatcherUntil -TimeoutMs 1000 -Condition {
            $script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -ceq 'query'
        }
    }
    Assert-UiConsole ($exitQueryStarted -and [string]$script:radioCatOperationKind -ceq 'query') ("new connection did not begin its first CAT read before the native exit probe; started={0}, ordinal={1}, kind={2}, port={3}" -f `
        $exitQueryStarted,[int]$script:radioCatOperationOrdinal,[string]$script:radioCatOperationKind,[string]$script:radioCatOperationPortName)
    $oldSupervisor = $script:supervisor
    $script:deviceCatalog = Get-RadioDeviceCatalog -SerialPortsInput $staleCatalogRecords
    Set-UiRadioCatDeviceControls
    $oldSupervisor.HasExited = $true
    On-UiTimerTick
    $nativeExitCleanupReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 6000 -Condition {
        -not $script:radioCatOperationPowerShell -and $oldSupervisor.HasExited
    }
    Assert-UiConsole ($nativeExitCleanupReady -and (Get-UiRadioCatSessionState).requested -and
        (Get-UiRadioCatSessionState).polling -and [int]$script:radioCatOperationOrdinal -eq $exitQueryOrdinalExpected) `
        'native core exit canceled or restarted the independent CAT session instead of draining its in-flight query.'
    $nativeExitConnectContent = [string](Get-UiConsoleControl 'ConnectButton').Content
    $nativeExitOrdinal = [int]$script:radioCatOperationOrdinal
    for ($tickAttempt = 0; $tickAttempt -lt 3; $tickAttempt++) { On-UiTimerTick }
    Assert-UiConsole ($oldSupervisor.HasExited -and $script:radioCatPollingActive -and
        [int]$script:radioCatOperationOrdinal -eq $nativeExitOrdinal -and
        [string](Get-UiConsoleControl 'ConnectButton').Content -ceq $nativeExitConnectContent -and
        (Get-UiConsoleControl 'ConnectButton').IsEnabled) 'native self-exit handling repeated cleanup, restarted CAT polling, or blocked reconnect.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 10 -and
        [string](Get-UiConsoleControl 'CatObservedPowerText').Text -ceq $exitPowerText -and
        (Get-UiConsoleControl 'RadioCatPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiRadioCatSessionState).requested) 'native HRI exit erased the last CAT values, hid the CAT panel, or ended the independent CAT session.'
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook
    Write-UiConsoleTestProgress 'native self-exit and in-flight CAT worker cleanup passed'

    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    $nativeExitCatDisconnectReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition {
        -not $script:radioCatOperationPowerShell -and -not (Get-UiRadioCatSessionState).requested
    }
    Assert-UiConsole ($nativeExitCatDisconnectReady -and (Get-UiConsoleControl 'CatPortBox').IsEnabled) `
        'native exit 后无法手动断开独立 CAT 会话并解锁端口选择。'
    $changedPortRecords = @(
        [pscustomobject]@{ PortName='COM5'; FriendlyName='USB Serial Device (COM5)'; InstanceId='USB\VID_26AA&PID_0030\FAKE-HRI'; HardwareIds=@(); DeviceSource='synthetic' },
        [pscustomobject]@{ PortName='COM10'; FriendlyName='Silicon Labs Dual CP2105 USB to UART Bridge: Standard COM Port (COM10)'; InstanceId='USB\VID_10C4&PID_EA70&MI_01\FAKE'; HardwareIds=@(); DeviceSource='synthetic' },
        [pscustomobject]@{ PortName='COM12'; FriendlyName='Silicon Labs Dual CP2105 USB to UART Bridge: Enhanced COM Port (COM12)'; InstanceId='USB\VID_10C4&PID_EA70&MI_00\FAKE-RENUMBERED'; HardwareIds=@(); DeviceSource='synthetic' }
    )
    $script:deviceCatalog = Get-RadioDeviceCatalog -SerialPortsInput $changedPortRecords
    Set-UiRadioCatDeviceControls
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11') 'same-port recovery selection was not retained until the user chose the newly enumerated COM number.'
    Select-UiConsoleCatPortOption -PortName COM12
    Update-UiRadioCatControls
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM12') 'newly enumerated COM12 could not be selected after COM11 disappeared.'
    [void](Connect-UiRadioCatSession)
    $com12CatReadReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        -not $script:radioCatOperationPowerShell -and $script:radioCatResult -and
            [string]$script:radioCatResult.operation -ceq 'query' -and [string]$script:radioCatResult.status -ceq 'confirmed'
    }
    Assert-UiConsole ($com12CatReadReady -and [string]$script:radioCatObservedPortName -ceq 'COM12') `
        'manual CAT reconnect did not independently query the newly selected COM12.'
    Invoke-UiConsoleClick -Name 'ConnectButton'
    $reconnectReadReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition { $script:supervisor -and -not $script:supervisor.HasExited }
    Assert-UiConsole $reconnectReadReady 're-enumerated COM12 and a new ConnectButton action did not complete the next CAT first read.'
    Assert-UiConsole ($script:radioCatPollingActive -and [string]$script:radioCatObservedPortName -ceq 'COM12' -and
        [int]$script:radioCatObserved.power.value.watts -eq 10 -and
        (Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'new native session did not restore the read-only CAT snapshot on the changed COM port.'
    Write-UiConsoleTestProgress 'COM12 reconnect and first CAT read passed'

    $script:radioCatPollingActive = $true
    $script:radioCatSessionRequested = $true
    $script:radioCatPollingConnectionKey = Get-UiRadioCatConnectionKey
    $script:supervisor = $null
    $script:stopTask = [pscustomobject]@{ IsCompleted=$true }
    Assert-UiConsole ([bool](Complete-BridgeStop)) 'core disconnect completion path did not run.'
    Assert-UiConsole ((Get-UiRadioCatSessionState).requested -and $script:radioCatPollingActive) 'ordinary core stop canceled the independent CAT session.'
    $catPortAfterCoreStop = Get-UiConsoleControl 'CatPortBox'
    $refreshDevicesAfterCoreStop = Get-UiConsoleControl 'RefreshDevicesButton'
    Assert-UiConsole (-not $catPortAfterCoreStop.IsEnabled -and -not $refreshDevicesAfterCoreStop.IsEnabled) `
        ("ordinary core stop incorrectly unlocked an occupied CAT port or device refresh. cat_enabled={0}, refresh_enabled={1}, requested={2}, connected={3}, polling={4}, state={5}, core={6}, main={7}, settings={8}" -f `
            [bool]$catPortAfterCoreStop.IsEnabled,[bool]$refreshDevicesAfterCoreStop.IsEnabled,
            (Get-UiRadioCatSessionState).requested,(Get-UiRadioCatSessionState).connected,(Get-UiRadioCatSessionState).polling,
            (Get-UiRadioCatSessionState).state,
            [bool]$script:supervisor,[bool]$script:mainWindow,[bool]$script:settingsWindow)

    $fakeDelayedSupervisor = [pscustomobject]@{ HasExited=$false; Operation='connect'; StopDelay=$true; StopRequested=$false; StopCallCount=0; StopResult=$null }
    $fakeDelayedSupervisor | Add-Member -MemberType ScriptMethod -Name StopAsync -Value {
        param([int]$TimeoutMs)
        $this.StopRequested = $true
        $this.StopCallCount++
        $this.StopResult = [pscustomobject]@{ IsCompleted=(-not [bool]$this.StopDelay) }
        if (-not $this.StopDelay) { $this.HasExited = $true }
        return $this.StopResult
    }
    $fakeDelayedSupervisor | Add-Member -MemberType ScriptMethod -Name TryGetExitCode -Value {
        param([ref]$ExitCode)
        $ExitCode.Value = 0
        return $true
    }
    $fakeDelayedSupervisor | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.HasExited = $true }
    $script:supervisor = $fakeDelayedSupervisor
    $script:radioCatPollingActive = $true
    $script:radioCatSessionRequested = $true
    $script:radioCatPollingConnectionKey = Get-UiRadioCatConnectionKey
    $script:radioCatPollNextUtc = [DateTime]::UtcNow.AddMinutes(10)
    (Get-UiConsoleControl 'CatMainModeBox').SelectedItem = @((Get-UiConsoleControl 'CatMainModeBox').Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    (Get-UiConsoleControl 'CatMainFrequencyMHzBox').Text = '145.700'
    Set-UiConsoleCatPower -Watts 10
    Update-UiConsoleFakeCoreHeartbeat
    Update-UiRadioCatControls
    $cancelLogPath = Join-Path $script:testRoot 'cat-operations.log'
    $cancelLogStart = @([System.IO.File]::ReadAllLines($cancelLogPath)).Count
    $exitOrdinal = [int]$script:radioCatOperationOrdinal
    $cancelQueryOrdinal = $exitOrdinal + 1
    $generationBeforeCancel = [int](Get-UiRadioCatSessionState).generation
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -DelayQueryOrdinal $cancelQueryOrdinal -DelayQuerySeconds 5
    Assert-UiConsole ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell -and
        [string]$script:radioCatOperationKind -ceq 'query' -and [int]$script:radioCatOperationOrdinal -eq $cancelQueryOrdinal) `
        'pending-exit test did not start the delayed CAT query.'
    Invoke-UiConsoleClick -Name 'ApplyCatSettingsButton'
    Assert-UiConsole ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setSettings' -and
        -not $script:radioCatSettingsApply -and [int]$fakeDelayedSupervisor.StopCallCount -eq 0) `
        'one Apply click during a CAT query did not queue a frozen settings batch without stopping HRI.'
    Invoke-UiConsoleClick -Name 'StopButton'
    Assert-UiConsole ($fakeDelayedSupervisor.StopRequested -and $script:stopTask -and -not $script:stopTask.IsCompleted) 'StopAndExit did not remain pending behind the fake delayed supervisor.'
    $cancelCleanupReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        -not $script:radioCatOperationPowerShell -and -not $script:radioCatPollingActive -and
        -not $script:radioCatQueuedAction -and -not $script:radioCatSettingsApply -and -not (Get-UiRadioCatSessionState).requested
    }
    Assert-UiConsole ($cancelCleanupReady -and [int](Get-UiRadioCatSessionState).generation -gt $generationBeforeCancel -and
        [int]$script:radioCatOperationOrdinal -eq $cancelQueryOrdinal) 'StopAndExit failed to cancel the pending settings batch/query or advanced to a new CAT write.'
    $cancelLogAfter = @([System.IO.File]::ReadAllLines($cancelLogPath) | Select-Object -Skip $cancelLogStart)
    Assert-UiConsole (@($cancelLogAfter | Where-Object { $_ -match '^WRITE\|(setMode|setFrequency|setPower)$' }).Count -eq 0) `
        'StopAndExit allowed a pending setSettings batch to write after CAT session cancellation.'
    $fakeDelayedSupervisor.HasExited = $true
    $script:stopTask.IsCompleted = $true
    Assert-UiConsole ([bool](Complete-BridgeStop)) 'delayed fake supervisor shutdown did not complete.'
    Assert-UiConsole ([int]$script:radioCatOperationOrdinal -eq $cancelQueryOrdinal -and -not $script:radioCatOperationPowerShell -and
        [int]$fakeDelayedSupervisor.StopCallCount -eq 1) 'CAT query/write restarted or core StopAsync repeated during StopAndExit completion.'
} finally {
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted) {
        try {
            $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null,$null)
            $workerCleanupDeadline = [DateTime]::UtcNow.AddSeconds(4)
            while ($script:deviceDiscoveryStopAsync -and -not $script:deviceDiscoveryStopAsync.IsCompleted -and [DateTime]::UtcNow -lt $workerCleanupDeadline) {
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
                Start-Sleep -Milliseconds 25
            }
            if ($script:deviceDiscoveryStopAsync -and $script:deviceDiscoveryStopAsync.IsCompleted) {
                try { $script:deviceDiscoveryPowerShell.EndStop($script:deviceDiscoveryStopAsync) } catch { }
            }
            if ($script:deviceDiscoveryPowerShell) { try { $script:deviceDiscoveryPowerShell.Dispose() } catch { } }
            $script:deviceDiscoveryPowerShell = $null
            $script:deviceDiscoveryAsync = $null
            $script:deviceDiscoveryStopAsync = $null
        } catch {
            Write-Warning ('Device discovery cleanup failed after its deadline: ' + $_.Exception.Message)
        }
    }
    try {
        if ($script:uiTimer) { $script:uiTimer.Stop() }
        if ($script:radioCatPollingActive) { Stop-UiRadioCatPolling -Reason 'test_cleanup' }
        $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(4)
        while ($script:radioCatOperationPowerShell -and [DateTime]::UtcNow -lt $cleanupDeadline) {
            try { [void](Complete-UiRadioCatOperation) } catch { }
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 30
        }
    } catch {
        Write-Warning ('CAT test cleanup failed after its deadline: ' + $_.Exception.Message)
    }
    if ($script:settingsWindow) { try { $script:settingsWindow.Close() } catch { Write-Warning ('Settings window cleanup failed: ' + $_.Exception.Message) } }
    if ($script:mainWindow -and $script:mainWindow.IsVisible) {
        $script:allowWindowClose = $true
        try { $script:mainWindow.Close() } catch { Write-Warning ('Main window cleanup failed: ' + $_.Exception.Message) }
    }
    if ($script:testRoot -and [System.IO.Directory]::Exists($script:testRoot)) {
        try {
            Assert-UiConsoleTempPathSafe -Path $script:testRoot
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        } catch {
            Write-Warning ('Test temp cleanup failed; the original assertion remains primary: ' + $_.Exception.Message)
        }
    }
}
Write-Output ("PASS: test-ui-console.ps1 ({0} real-WPF interaction assertions; PowerShell {1})" -f $script:assertionCount,$PSVersionTable.PSVersion)
