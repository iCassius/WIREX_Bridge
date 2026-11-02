#requires -Version 5.1
[CmdletBinding()]
param([switch]$LiveSerialReadOnly)

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0
$script:testRoot = $null
$script:mainWindow = $null
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
    [void]$editBox.Focus()
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
[System.IO.File]::AppendAllText('__OPERATION_LOG_PATH__',('{0}|{1}' -f $ordinal,$operation)+[Environment]::NewLine)
$stamp = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
$rejectedFieldHead = ($operation -ceq 'setPower' -and [int]$Context.parameters.PowerWatts -eq 25)
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
    else { $radioState.watts=[int]$Context.parameters.PowerWatts }
}
if ($operation -ceq 'setMode') { $radioState.main_mode=[string]$Context.parameters.Mode }
if ($operation -ceq 'setFrequency') { $radioState.main_frequency_hz=[long]$Context.parameters.FrequencyHz }
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
$desired = if ($operation -ceq 'setPower') { [pscustomobject]@{ watts=[int]$Context.parameters.PowerWatts } } else { $null }
$updatedAt = if ($status -ceq 'rejected') { $null } else { $stamp }
$result = [pscustomobject][ordered]@{
    schema_version=1; operation=$operation; status=$status; source='CAT test transport'; port_name=[string]$Context.port; port_role='CAT-1'
    started_at_utc=$stamp; updated_at_utc=$updatedAt; desired=$desired; prior=$null; observed=$observed; capabilities=$capabilities
    cleanup_status='closed'; error_code=$errorCode; error_message=$errorMessage
}
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
            $fake = [pscustomobject]@{ HasExited=$false; ProcessId=[uint32]48123; Operation=[string]$Context.operation; StopDelay=$false; StopRequested=$false; StopResult=$null }
            $fake | Add-Member -MemberType ScriptMethod -Name StopAsync -Value {
                param([int]$TimeoutMs)
                $this.StopRequested = $true
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
        'RadioCatPanel','CatPortBox','CatBaudRateBox','SerialConnectButton','SerialDisconnectButton','CatSessionStatusText','CatOperatingPanel',
        'CatObservedPanel','CatObservedMainModeText',
        'CatObservedFrequencyText','CatObservedPowerText','CatMainModeBox','ApplyCatModeButton','CatMainFrequencyMHzBox',
        'ApplyCatFrequencyButton','CatPowerSlider','CatDesiredPowerText','ApplyCatPowerButton','SerialBox',
        'DeviceDiscoveryText','RefreshDevicesButton','RadioDetailsExpander','MasterPresetBox','MasterBox','MasterPortBox',
        'BmApiKeyBox','BmStaticGroupPanel','RefreshBmStaticGroupsButton','AddBmStaticGroupButton'
    )
    $missingControls = @($requiredControls | Where-Object { $null -eq $script:mainWindow.FindName($_) })
    Assert-UiConsole ($missingControls.Count -eq 0) ('实际 WPF MainWindow 缺少稳定控件：{0}' -f ($missingControls -join ', '))
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
    Assert-UiConsole ((Get-UiConsoleControl 'CatPortBox').Text -ceq 'COM11') 'CAT did not auto-select the unique Enhanced CP2105 port after audio error.'
    Assert-UiConsole (-not $script:radioCatPortSelectionExplicit) 'automatic Enhanced port selection was incorrectly saved as a manual choice.'

    Start-UiDeviceDiscovery -UseProductionOrchestration
    $audioTimeoutReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition {
        $script:deviceSerialState -ceq 'ready' -and $script:deviceAudioState -ceq 'timeout'
    }
    Assert-UiConsole $audioTimeoutReady 'audio timeout blocked serial result publication.'
    Assert-UiConsole ($null -eq $script:uiTestDiscoveryResult) 'audio timeout regression used the fixture-only publisher path instead of production orchestration.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatPortBox').Text -ceq 'COM11') 'CAT selection was lost after audio timeout.'

    $catPortBox = Get-UiConsoleControl 'CatPortBox'
    Set-UiConsoleManualCatPort -PortName COM99
    Assert-UiConsole ([bool]$script:radioCatPortSelectionExplicit) 'real CAT port text editing did not mark the selection explicit.'
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM99') 'manual CAT COM port entry was rejected without discovery metadata.'
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
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM99') 'manual CAT COM port entry was rejected without discovery metadata.'
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
    Assert-UiConsole ((Get-UiConsoleControl 'BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Collapsed -and
        -not (Get-UiConsoleControl 'RefreshBmStaticGroupsButton').IsEnabled -and
        -not (Get-UiConsoleControl 'AddBmStaticGroupButton').IsEnabled) 'API-empty state did not hide/disable only BM static-group management.'
    $script:radioControlPreferences.desired_power_watts = 40
    Invoke-UiConsoleClick -Name 'ConnectButton'
    $connected = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { $script:supervisor -and -not $script:supervisor.HasExited }
    $settingsError = if ($script:mainWindow.FindName('SettingsErrorText')) { [string]$script:mainWindow.FindName('SettingsErrorText').Text } else { '' }
    Assert-UiConsole $connected ("real ConnectButton did not pass through the fake native supervisor seam; profileEditable={0}, startupNeedsSettings={1}, storedProfile={2}, footer={3}, settingsError={4}" -f `
        [bool]$script:profileEditable,[bool]$script:startupNeedsSettings,[bool]$script:storedProfile,[string]$script:mainWindow.FindName('FooterText').Text,$settingsError)
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
    Assert-UiConsole ([string](Get-UiConsoleControl 'BmValue').Text -ceq '已连接' -and
        [string](Get-UiConsoleControl 'RadioValue').Text -ceq 'HRI 就绪' -and
        [string]$script:latestStatus.bm_state -ceq 'ready' -and [bool]$script:latestStatus.hri_ready) `
        'API-empty fake Connect did not progress to the synthetic BM/HRI-ready UI state.'
    Assert-UiConsole ((Get-UiConsoleControl 'BmStaticGroupPanel').Visibility -eq [System.Windows.Visibility]::Collapsed -and
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
    Assert-UiConsole (-not (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'power write was enabled before the user created a draft.'
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

    (Get-UiConsoleControl 'CatPowerSlider').Value = 24
    Assert-UiConsole ([int]$script:radioCatEditDraft.power -eq 24) 'real slider event did not retain a 24 W draft.'
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'real slider change did not immediately enable a valid 24 W power draft.'
    $script:radioControlPreferences.desired_power_watts = 40
    [void](Invoke-UiRadioCatPollTick -Force)
    $pollReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $pollReady 'bounded CAT poll did not complete.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 30) 'poll did not update actual hardware state from 25 W to 30 W.'
    Assert-UiConsole ([int](Get-UiConsoleControl 'CatPowerSlider').Value -eq 24 -and [int]$script:radioCatEditDraft.power -eq 24) 'poll overwrote the user 24 W draft with actual 30 W.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPowerText').Text -match '30 W') 'actual power display did not follow the poll result.'

    Invoke-UiRadioCatAction -Operation 'query'
    $manualQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $manualQueryReady 'explicit CAT query action did not run a query.'

    $setPowerOrdinal = [int]$script:radioCatOperationOrdinal
    Invoke-UiConsoleClick -Name 'ApplyCatPowerButton'
    Assert-UiConsole (([string]$script:radioCatQueuedAction.operation -ceq 'setPower') -or
        ([string]$script:radioCatOperationKind -ceq 'setPower')) `
        ("Apply CAT power click did not freeze or start the explicit action; draft={0}, queued={1}, kind={2}, ordinal={3}, enabled={4}" -f `
            $script:radioCatEditDraft.power,[string]$script:radioCatQueuedAction.operation,[string]$script:radioCatOperationKind,
            [int]$script:radioCatOperationOrdinal,[bool](Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled)
    $setReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 24 -and $null -eq $script:radioCatEditDraft.power
    }
    $catOperationHistory = if (Test-Path -LiteralPath (Join-Path $script:testRoot 'cat-operations.log')) { [string](Get-Content -LiteralPath (Join-Path $script:testRoot 'cat-operations.log') -Raw) } else { '' }
    Assert-UiConsole $setReady ("CAT setPower operation did not finish within its bound; ordinal={0}/{1}, kind={2}, result={3}/{4}, queued={5}, session={6}/{7}, catGen={8}, observedKey={9}, currentKey={10}, notice={11}, operations={12}" -f `
        [int]$script:radioCatOperationOrdinal,$setPowerOrdinal,[string]$script:radioCatOperationKind,[string]$script:radioCatResult.operation,
        [string]$script:radioCatResult.status,[string]$script:radioCatQueuedAction.operation,[bool](Get-UiRadioCatSessionState).requested,
        [bool](Get-UiRadioCatSessionState).connected,[int](Get-UiRadioCatSessionState).generation,[string]$script:radioCatObservedConnectionKey,
        [string](Get-UiRadioCatConnectionKey),[string](Get-UiRadioCatSessionState).error,$catOperationHistory)
    $powerReadbackReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 3000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 24 -and $null -eq $script:radioCatEditDraft.power
    }
    $appliedWatts = [int]$script:radioCatObserved.power.value.watts
    $confirmedPowerWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|complete\|setPower\|confirmed\r?$')).Count
    Assert-UiConsole ($powerReadbackReady -and $appliedWatts -eq 24 -and $confirmedPowerWriteCount -eq 1) `
        ("power apply did not produce exactly one confirmed 24 W write/readback; result={0}, status={1}, writes={2}, preference={3}, draft={4}, ordinal={5}" -f $appliedWatts,$script:radioCatLastOperationStatus,$confirmedPowerWriteCount,$script:radioControlPreferences.desired_power_watts,$script:radioCatEditDraft.power,$script:radioCatOperationOrdinal)
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 24 -and $null -eq $script:radioCatEditDraft.power) 'confirmed readback did not update actual 24 W and clear the draft.'

    (Get-UiConsoleControl 'CatPowerSlider').Value = 25
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'confirmed SPA-1 state did not enable the explicit 25 W candidate before the changed path was known.'
    Invoke-UiConsoleClick -Name 'ApplyCatPowerButton'
    $rejectedPowerReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [string]$script:radioCatObserved.power.value.path -ceq 'FieldHead' -and [int]$script:radioCatObserved.power.value.watts -eq 5
    }
    Assert-UiConsole $rejectedPowerReady 'FieldHead range rejection did not complete.'
    $rejectedPowerReadbackReady = $rejectedPowerReady
    $rejectedPowerWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|complete\|setPower\|rejected\r?$')).Count
    Assert-UiConsole ($rejectedPowerReadbackReady -and $rejectedPowerWriteCount -eq 1) 'rejected power request was not executed once or its verified FieldHead 5 W readback was lost.'
    Assert-UiConsole ([double](Get-UiConsoleControl 'CatPowerSlider').Maximum -eq 10 -and
        (Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '5 W' -and
        -not (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'rejected FieldHead readback did not update the 10 W limit while removing write permission.'
    Assert-UiConsole ([int]$script:radioControlPreferences.desired_power_watts -eq 24) 'rejected power request overwrote the last confirmed power preference.'

    Invoke-UiRadioCatAction -Operation 'query'
    $fieldHeadQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $fieldHeadQueryReady 'CAT query did not restore permission after the rejected FieldHead request.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 5 -and [string]$script:radioCatObserved.power.value.path -ceq 'FieldHead') 'confirmed FieldHead query did not retain the actual path and 5 W value.'
    (Get-UiConsoleControl 'CatPowerSlider').Value = 9
    Assert-UiConsole ([int]$script:radioCatEditDraft.power -eq 9 -and (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'real slider change did not immediately enable a legal 9 W FieldHead draft.'
    Invoke-UiConsoleClick -Name 'ApplyCatPowerButton'
    $fieldHeadSetReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 9 -and $null -eq $script:radioCatEditDraft.power
    }
    Assert-UiConsole $fieldHeadSetReady 'legal FieldHead power operation did not finish.'
    $fieldHeadPowerReadbackReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 3000 -Condition {
        [int]$script:radioCatObserved.power.value.watts -eq 9 -and $null -eq $script:radioCatEditDraft.power
    }
    Assert-UiConsole ($fieldHeadPowerReadbackReady -and [int]$script:radioCatObserved.power.value.watts -eq 9 -and $null -eq $script:radioCatEditDraft.power -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 9) 'confirmed 9 W FieldHead readback did not update actual and saved-preference state.'

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
    Assert-UiConsole ($script:radioCatResult -eq $null -and [int]$script:radioCatObserved.power.value.watts -eq 9 -and
        [string]$script:radioCatObserved.power.updated_at_utc -ceq $powerStampBeforeTimeout -and
        [string](Get-UiConsoleControl 'CatObservedPowerText').Text -ceq $powerTextBeforeTimeout -and
        (Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'detach invalidated write permission or erased the last actual CAT display.'
    Assert-UiConsole (@($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT串口从设备列表消失' }).Count -eq ($disconnectEventCountBefore + 1)) 'CAT detach event was not recorded exactly once while repeated polls waited.'
    Assert-UiConsole ([string](Get-UiConsoleControl 'FooterText').Text -match 'CAT串口从设备列表消失') 'CAT detach transition did not reach the MainWindow event fallback.'
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM11') 'detached explicit CAT port was lost before a re-enumeration could restore it.'
    $failedQueryOrdinal = [int]$script:radioCatOperationOrdinal
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -UnknownQueryOrdinal ($failedQueryOrdinal + 1)
    Start-UiRadioCatOperation -Operation 'query'
    $failedQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        -not $script:radioCatOperationPowerShell -and $script:radioCatLastOperationStatus -ceq 'unknown' -and $null -eq $script:radioCatResult
    }
    Assert-UiConsole $failedQueryReady 'synthetic timeout query did not complete.'
    Assert-UiConsole ($null -eq $script:radioCatResult -and -not (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) ("query timeout left an old write permit enabled; ordinal={0}, status={1}, result={2}/{3}, button={4}" -f $script:radioCatOperationOrdinal,$script:radioCatLastOperationStatus,[string]$script:radioCatResult.operation,[string]$script:radioCatResult.status,(Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled)
    Assert-UiConsole (@($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT状态读取失败' }).Count -eq 1) 'CAT query failure did not create a single transition event.'
    Assert-UiConsole ([string](Get-UiConsoleControl 'FooterText').Text -match 'CAT状态读取失败') 'CAT query failure transition did not reach the MainWindow event fallback.'
    Assert-UiConsole (-not (Get-UiConsoleControl 'ApplyCatModeButton').IsEnabled -and -not (Get-UiConsoleControl 'ApplyCatFrequencyButton').IsEnabled) 'query timeout left MAIN mode or frequency writes enabled.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 9 -and
        [string]$script:radioCatObserved.power.updated_at_utc -ceq $powerStampBeforeTimeout) 'query timeout replaced the last actual value or its original timestamp.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        [string](Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '9 W' -and
        (Get-UiRadioCatSessionState).requested) 'query timeout hid the last value or ended the independent CAT polling session.'
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -UnknownQueryOrdinal -2
    $script:radioCatEditDraft.mode = 'FM-N'
    $script:radioCatEditDraft.frequency = '145.600'
    $script:radioCatEditDraft.power = 20
    Update-UiRadioCatControls
    $failedPermitWriteCount = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:testRoot 'cat-operations.log')),'(?m)^[0-9]+\|set(Power|Mode|Frequency)\r?$')).Count
    Invoke-UiRadioCatAction -Operation 'setMode'
    Invoke-UiRadioCatAction -Operation 'setFrequency'
    Invoke-UiRadioCatAction -Operation 'setPower'
    $failedPermitQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        -not $script:radioCatOperationPowerShell -and $null -eq $script:radioCatQueuedAction -and
        $null -eq $script:radioCatPendingModeFrequencyRequest -and $null -eq $script:radioModeApplyAfterStop
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
    $busyNotice = if ($script:mainWindow.FindName('CatOperationStatusText')) { [string]$script:mainWindow.FindName('CatOperationStatusText').Text } else { '' }
    Assert-UiConsole ($duplicateQueryRejected -and [int]$script:radioCatOperationOrdinal -eq $reattachOrdinal -and
        $script:radioCatOperationPowerShell -and $busyCatSessionRequested -and (Get-UiRadioCatSessionState).requested -and
        (Get-UiConsoleControl 'CatObservedPanel').Visibility -eq $busyPanelVisibility -and
        (Get-UiConsoleControl 'CatOperatingPanel').Visibility -eq $busyOperatingVisibility -and
        $busyNotice -notmatch '操作中') 'busy CAT refresh changed panel visibility, started a second worker, or displayed a permanent working label.'
    $reattachReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $reattachReady 'CAT read did not recover after the detached port was re-enumerated.'
    Assert-UiConsole ($script:radioCatPollingActive -and $script:radioCatResult -and
        [string]$script:radioCatResult.operation -ceq 'query' -and [string]$script:radioCatResult.status -ceq 'confirmed' -and
        [int]$script:radioCatObserved.power.value.watts -eq 9 -and
        [string]$script:radioCatObserved.power.updated_at_utc -cne $powerStampBeforeTimeout -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 9 -and
        $null -eq $script:radioCatEditDraft.power) 'reconnected read did not update only observed state while retaining the desired power setting.'
    Write-UiConsoleTestProgress 'detach, timeout, and COM11 recovery passed'
    Assert-UiConsole (@($script:capturedUiEvents | Where-Object { [string]$_ -match 'CAT状态读取已恢复' }).Count -eq 1) 'CAT recovery did not create one transition event.'
    Assert-UiConsole ([string](Get-UiConsoleControl 'FooterText').Text -match 'CAT状态读取已恢复') 'CAT recovery transition did not reach the MainWindow event fallback.'
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    Assert-UiConsole ((Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible -and
        (Get-UiConsoleControl 'CatObservedPowerText').Text -ceq '9 W' -and $script:radioCatResult -and
        [string]$script:radioCatResult.operation -ceq 'query' -and [string]$script:radioCatResult.status -ceq 'confirmed') `
        'successful reconnect did not preserve the CAT view and confirmed readback; write controls remain gated until the user creates a valid draft.'
    $permitRefreshReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $permitRefreshReady 'a successful CAT read did not restore write permission after the synthetic timeout.'

    $modeBox = Get-UiConsoleControl 'CatMainModeBox'
    $modeBox.SelectedItem = @($modeBox.Items | Where-Object { [string]$_.Tag -ceq 'FM-N' })[0]
    Assert-UiConsole ([string]$script:radioCatEditDraft.mode -ceq 'FM-N') 'real MAIN mode selector did not create a draft.'
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatModeButton').IsEnabled) 'confirmed CAT state did not enable MAIN mode application.'
    Invoke-UiConsoleClick -Name 'ApplyCatModeButton'
    $modeApplyReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 8000 -Condition {
        [string]$script:radioCatObserved.main_mode.value.mode -ceq 'FM-N' -and -not $script:radioCatOperationPowerShell -and
        -not $script:stopTask -and -not $script:radioCatPendingModeFrequencyRequest
    }
    Assert-UiConsole $modeApplyReady 'MAIN mode operation did not finish stop → fresh query → single set within its bound.'
    Assert-UiConsole (-not $script:supervisor -and [string]$script:radioCatObserved.main_mode.value.mode -ceq 'FM-N' -and
        $script:radioCatLastOperationStatus -ceq 'confirmed') 'MAIN mode apply did not preserve stop-first behavior and confirm the requested FM-N readback.'
    Assert-UiConsole ($null -eq $script:radioCatEditDraft.mode) 'confirmed MAIN mode readback did not clear the mode draft.'

    Invoke-UiRadioCatAction -Operation 'query'
    $modeRefreshReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $modeRefreshReady 'CAT state was not refreshed before applying MAIN frequency.'
    (Get-UiConsoleControl 'CatMainFrequencyMHzBox').Text = '145.600'
    Assert-UiConsole ([string]$script:radioCatEditDraft.frequency -ceq '145.600') 'real MAIN frequency textbox did not retain its draft.'
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatFrequencyButton').IsEnabled) 'confirmed CAT state did not enable MAIN frequency application.'
    Invoke-UiConsoleClick -Name 'ApplyCatFrequencyButton'
    $frequencyApplyReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        [long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and -not $script:radioCatOperationPowerShell
    }
    Assert-UiConsole $frequencyApplyReady 'MAIN frequency CAT operation did not finish.'
    Assert-UiConsole ([long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and $null -eq $script:radioCatEditDraft.frequency) 'MAIN frequency apply did not confirm the requested 145.600 MHz readback.'
    Write-UiConsoleTestProgress 'CAT mode and frequency operations passed'

    $exitPowerText = [string](Get-UiConsoleControl 'CatObservedPowerText').Text
    $exitQueryOrdinalExpected = [int]$script:radioCatOperationOrdinal + 1
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -DelayQueryOrdinal $exitQueryOrdinalExpected -DelayQuerySeconds 2
    $script:radioCatPollNextUtc = [DateTime]::UtcNow.AddMinutes(10)
    Invoke-UiConsoleClick -Name 'ConnectButton'
    $exitCoreStarted = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition { $script:supervisor -and -not $script:supervisor.HasExited }
    Assert-UiConsole $exitCoreStarted 'new ConnectButton action did not start the HRI core for the native exit probe.'
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
    $nativeExitCoreText = [string](Get-UiConsoleControl 'CoreValue').Text
    $nativeExitOrdinal = [int]$script:radioCatOperationOrdinal
    for ($tickAttempt = 0; $tickAttempt -lt 3; $tickAttempt++) { On-UiTimerTick }
    Assert-UiConsole ($oldSupervisor.HasExited -and $script:radioCatPollingActive -and
        [int]$script:radioCatOperationOrdinal -eq $nativeExitOrdinal -and
        [string](Get-UiConsoleControl 'CoreValue').Text -ceq $nativeExitCoreText -and
        (Get-UiConsoleControl 'ConnectButton').IsEnabled) 'native self-exit handling repeated cleanup, restarted CAT polling, or blocked reconnect.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 9 -and
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
        [int]$script:radioCatObserved.power.value.watts -eq 9 -and
        (Get-UiConsoleControl 'CatObservedPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'new native session did not restore the read-only CAT snapshot on the changed COM port.'
    Write-UiConsoleTestProgress 'COM12 reconnect and first CAT read passed'

    # A background CAT query may still be in flight when a user-requested HRI stop completes.
    # Keep its reply separate from the frozen MAIN-mode request and require a new query after cleanup.
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $raceSupervisor = $script:supervisor
    $raceSupervisor.StopDelay = $true
    $raceModeBox = Get-UiConsoleControl 'CatMainModeBox'
    $raceModeBox.SelectedItem = @($raceModeBox.Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    Update-UiRadioCatControls
    $script:radioCatPollNextUtc = [DateTime]::UtcNow.AddMinutes(10)
    $raceBaseOrdinal = [int]$script:radioCatOperationOrdinal
    $raceOperationLogPath = Join-Path $script:testRoot 'cat-operations.log'
    $raceLogStart = if ([System.IO.File]::Exists($raceOperationLogPath)) { @([System.IO.File]::ReadAllLines($raceOperationLogPath)) } else { @() }
    Invoke-UiConsoleClick -Name 'ApplyCatModeButton'
    Assert-UiConsole ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setMode' -and
        [string]$script:radioCatQueuedAction.mode -ceq 'C4FM-DN' -and -not $raceSupervisor.StopRequested -and
        -not $raceSupervisor.HasExited) 'MAIN mode click during a CAT query did not freeze one action before requesting HRI stop.'
    $modeStopStarted = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition {
        $script:radioModeApplyAfterStop -and $script:stopTask -and -not $script:stopTask.IsCompleted -and
        $raceSupervisor.StopRequested -and -not $raceSupervisor.HasExited
    }
    Assert-UiConsole ($modeStopStarted -and [string]$script:radioModeApplyAfterStop.mode -ceq 'C4FM-DN') `
        'confirmed query did not move the frozen MAIN mode request into the HRI stop transaction.'
    $oldQueryOrdinal = [int]$script:radioCatOperationOrdinal + 1
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook -DelayQueryOrdinal $oldQueryOrdinal -DelayQuerySeconds 5
    Assert-UiConsole ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell -and
        [string]$script:radioCatOperationKind -ceq 'query' -and [int]$script:radioCatOperationOrdinal -eq $oldQueryOrdinal) `
        'the simulated periodic CAT poll did not start the in-flight old query while HRI shutdown was pending.'
    $oldQueryPowerShell = $script:radioCatOperationPowerShell
    $oldQueryAsync = $script:radioCatOperationAsync
    $oldQueryRunspace = $oldQueryPowerShell.Runspace
    $raceSupervisor.HasExited = $true
    $script:stopTask.IsCompleted = $true
    [void](Complete-BridgeStop)
    $freshRaceQueryStarted = Invoke-UiConsoleDispatcherUntil -TimeoutMs 8000 -Condition {
        $script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -ceq 'query' -and
            [int]$script:radioCatOperationOrdinal -ge ($oldQueryOrdinal + 1)
    }
    $oldQueryRunspaceState = [string]$oldQueryRunspace.RunspaceStateInfo.State
    Assert-UiConsole ($freshRaceQueryStarted -and [int]$script:radioCatOperationOrdinal -eq ($oldQueryOrdinal + 1) -and
        $oldQueryRunspaceState -ceq 'Closed' -and -not [object]::ReferenceEquals($oldQueryPowerShell,$script:radioCatOperationPowerShell)) `
        ("HRI stop did not close the old CAT runspace before starting one fresh query; started={0}, old={1}, current={2}, baseline={3}, oldAsync={4}, oldRunspace={5}, stopTask={6}, frozen={7}, pending={8}" -f `
            $freshRaceQueryStarted,$oldQueryOrdinal,[int]$script:radioCatOperationOrdinal,$raceBaseOrdinal,[bool]$oldQueryAsync.IsCompleted,
            $oldQueryRunspaceState,[bool]$script:stopTask,[bool]$script:radioModeApplyAfterStop,[bool]$script:radioCatPendingModeFrequencyRequest)
    Assert-UiConsole ($script:radioCatOperationKind -ceq 'query' -and -not $script:radioCatOperationCancelled) `
        'the stale query reply was treated as the new frozen MAIN-mode query.'
    $raceModeReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 8000 -Condition {
        -not $script:radioCatOperationPowerShell -and -not $script:stopTask -and
            -not $script:radioCatPendingModeFrequencyRequest -and -not $script:radioModeApplyAfterStop
    }
    $raceLogNow = if ([System.IO.File]::Exists($raceOperationLogPath)) { @([System.IO.File]::ReadAllLines($raceOperationLogPath)) } else { @() }
    $raceOperations = @($raceLogNow | Select-Object -Skip $raceLogStart.Count)
    $raceOperationStarts = @($raceOperations | Where-Object { $_ -match '^\d+\|(query|setMode)$' })
    $raceModeWrites = @($raceOperationStarts | Where-Object { $_ -match '\|setMode$' })
    $raceQueryOperations = @($raceOperationStarts | Where-Object { $_ -match '\|query$' })
    $raceLastOperationsAreQueryThenMode = ($raceOperationStarts.Count -ge 2 -and
        $raceOperationStarts[$raceOperationStarts.Count - 2] -match '\|query$' -and
        $raceOperationStarts[$raceOperationStarts.Count - 1] -match '\|setMode$')
    Assert-UiConsole ($raceModeReady -and $raceModeWrites.Count -eq 1 -and $raceQueryOperations.Count -ge 2 -and
        $raceLastOperationsAreQueryThenMode -and
        [string]$script:radioCatObserved.main_mode.value.mode -ceq 'C4FM-DN' -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and -not $script:supervisor) `
        ("the fresh CAT query did not authorize exactly one frozen mode set and confirmed readback. ready={0}, query_count={1}, mode_writes={2}, operations={3}, mode={4}, status={5}, supervisor={6}, stopTask={7}, pending={8}, queued={9}" -f `
            $raceModeReady,$raceQueryOperations.Count,$raceModeWrites.Count,($raceOperations -join ','),[string]$script:radioCatObserved.main_mode.value.mode,
            [string]$script:radioCatLastOperationStatus,[bool]$script:supervisor,[bool]$script:stopTask,
            [bool]$script:radioCatPendingModeFrequencyRequest,[bool]$script:radioModeApplyAfterStop)
    $script:uiTestHooks.CatOperation = New-UiConsoleCatOperationHook
    Write-UiConsoleTestProgress 'normal stop, in-flight CAT worker cleanup, fresh query, and MAIN mode readback passed'

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

    $fakeDelayedSupervisor = [pscustomobject]@{ HasExited=$false; Operation='connect'; StopDelay=$true; StopRequested=$false; StopResult=$null }
    $fakeDelayedSupervisor | Add-Member -MemberType ScriptMethod -Name StopAsync -Value {
        param([int]$TimeoutMs)
        $this.StopRequested = $true
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
    $exitOrdinal = [int]$script:radioCatOperationOrdinal
    Invoke-UiConsoleClick -Name 'StopButton'
    Assert-UiConsole ($fakeDelayedSupervisor.StopRequested -and $script:stopTask -and -not $script:stopTask.IsCompleted) 'StopAndExit did not remain pending behind the fake delayed supervisor.'
    Assert-UiConsole (-not $script:radioCatPollingActive -and -not (Get-UiRadioCatSessionState).requested -and
        [int]$script:radioCatOperationOrdinal -eq $exitOrdinal) 'StopAndExit failed to cancel CAT polling while core shutdown was delayed.'
    $fakeDelayedSupervisor.HasExited = $true
    $script:stopTask.IsCompleted = $true
    Assert-UiConsole ([bool](Complete-BridgeStop)) 'delayed fake supervisor shutdown did not complete.'
    Assert-UiConsole ([int]$script:radioCatOperationOrdinal -eq $exitOrdinal -and -not $script:radioCatOperationPowerShell) 'CAT query restarted during StopAndExit completion.'
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
