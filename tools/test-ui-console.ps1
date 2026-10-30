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
    $args = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$button)
    $button.RaiseEvent($args)
}

function Invoke-UiConsoleDispatcherUntil {
    param([Parameter(Mandatory=$true)][scriptblock]$Condition,[int]$TimeoutMs=3000)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(20)
    $tick = {
        if (& $Condition -or $watch.ElapsedMilliseconds -ge $TimeoutMs) {
            $timer.Stop()
            $frame.Continue = $false
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $watch.Stop()
    $timer.Remove_Tick($tick)
    return (& $Condition)
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
    $scriptText = @'
param([object]$Context)
$operation = [string]$Context.operation
$ordinal = [int]$Context.ordinal
$stamp = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
$rejectedFieldHead = ($operation -ceq 'setPower' -and [int]$Context.parameters.PowerWatts -eq 25)
$fieldHeadPath = ($rejectedFieldHead -or $ordinal -ge 7)
$powerPath = if ($fieldHeadPath) { 'FieldHead' } else { 'Spa1' }
$watts = if ($rejectedFieldHead) { 5 } elseif ($operation -ceq 'setPower') { [int]$Context.parameters.PowerWatts } elseif ($fieldHeadPath -and $ordinal -ge 10) { 9 } elseif ($fieldHeadPath) { 5 } elseif ($ordinal -le 2) { 25 } else { 30 }
if ($ordinal -eq 15 -and $operation -ceq 'query') { Start-Sleep -Seconds 5 }
$status = if ($rejectedFieldHead) { 'rejected' } elseif ($ordinal -eq 9 -and $operation -ceq 'query') { 'unknown' } else { 'confirmed' }
$errorCode = if ($status -ceq 'unknown') { 'timeout' } elseif ($rejectedFieldHead) { 'power_out_of_range' } else { $null }
$errorMessage = if ($status -ceq 'unknown') { 'synthetic bounded query timeout' } elseif ($rejectedFieldHead) { 'FieldHead supports at most 10 W.' } else { $null }
$mainMode = if ($operation -ceq 'setMode') { [string]$Context.parameters.Mode } else { 'FM' }
$mainFrequency = if ($operation -ceq 'setFrequency') { [long]$Context.parameters.FrequencyHz } else { [long]145500000 }
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
return [pscustomobject][ordered]@{
    schema_version=1; operation=$operation; status=$status; source='CAT test transport'; port_name=[string]$Context.port; port_role='CAT-1'
    started_at_utc=$stamp; updated_at_utc=$updatedAt; desired=$desired; prior=$null; observed=$observed; capabilities=$capabilities
    cleanup_status='closed'; error_code=$errorCode; error_message=$errorMessage
}
'@
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
$configModulePath = Join-Path $repoRoot 'tools\bridge-user-config.psm1'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw '请使用 -STA 运行测试，以真实 WPF 窗口和 DispatcherTimer 验证交互。'
}
foreach ($path in @($uiPath,$xamlPath,$catUiPath,$devicesPath,$configModulePath)) {
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
$configDirectory = Join-Path $script:testRoot 'config'
[void][System.IO.Directory]::CreateDirectory($configDirectory)

try {
    Import-Module -Name $devicesPath -Force
    Import-Module -Name $configModulePath -Force
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
            $fake = [pscustomobject]@{ HasExited=$false; Operation=[string]$Context.operation; StopDelay=$false; StopRequested=$false; StopResult=$null }
            $fake | Add-Member -MemberType ScriptMethod -Name StopAsync -Value {
                param([int]$TimeoutMs)
                $this.StopRequested = $true
                $this.StopResult = [pscustomobject]@{ IsCompleted=(-not [bool]$this.StopDelay) }
                if (-not $this.StopDelay) { $this.HasExited = $true }
                return $this.StopResult
            }
            $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.HasExited = $true }
            return $fake
        }
    }

    $connection = [pscustomobject][ordered]@{ callsign='N0TEST'; gateway_id=[uint64]1; source_id=[uint64]123456; master='127.0.0.1'; master_port=[uint64]62031; color_code=[uint64]1 }
    $devices = [pscustomobject][ordered]@{ serial_port='COM5'; wave_in_endpoint_id='auto'; wave_out_endpoint_id='auto' }
    $txTarget = [pscustomobject][ordered]@{ destination_id=[uint64]91; kind='group'; slot=[uint64]2 }
    $rxPolicy = [pscustomobject][ordered]@{ group_mode='selected'; private_mode='disabled'; allow_groups=@([pscustomobject]@{ destination_id=[uint64]91; slot=[uint64]2 }); allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@() }
    $profile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $devices -TxTarget $txTarget `
        -RxPolicy $rxPolicy -TransmitEnabled $false
    Write-BridgeUserConnectionProfile -Path (Join-Path $configDirectory 'connection-profile.json') -Profile $profile

    . $uiPath -UiTestFixture -NoAutoConnect -UserConfigDirectory $configDirectory -PackageDirectory $repoRoot
    $script:mainWindow = $script:mainWindow
    Assert-UiConsole ($null -ne $script:mainWindow -and $script:mainWindow.IsVisible) 'UiTestFixture did not show the actual MainWindow.'
    $requiredControls = @(
        'RadioCatPanel','CatPortBox','CatBaudRateBox','CatStopBitsBox','CatOperatingPanel','ReadRadioButton',
        'CatOperationStatusText','CatObservedPanel','CatRadioIdentityText','CatObservedMainModeText','CatObservedSubModeText',
        'CatObservedFrequencyText','CatObservedPowerText','CatMainModeBox','ApplyCatModeButton','CatMainFrequencyMHzBox',
        'ApplyCatFrequencyButton','CatPowerSlider','CatDesiredPowerText','ApplyCatPowerButton','SerialBox',
        'DeviceDiscoveryText','RefreshDevicesButton','CurrentCallPanel','CurrentCallLabel','CurrentCallValue',
        'CurrentCallDetail','RadioDetailsExpander','MasterPresetBox','MasterBox','MasterPortBox'
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
    Assert-UiConsole ($null -eq (Get-UiConsoleControl 'CatPortBox').SelectedItem -and -not (Get-UiRadioCatSelectedPort)) 'multiple Enhanced CP2105 ports were selected arbitrarily.'
    $script:radioControlPreferences.cat_port = 'COM11'
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
    Assert-UiConsole ((Get-UiConsoleControl 'RadioCatPanel').Visibility -eq [System.Windows.Visibility]::Visible) 'main-window CAT controls disappeared when settingsWindow was null.'
    Assert-UiConsole ([int]$script:radioCatPollIntervalMs -eq 1000) 'default CAT poll interval is not 1 second.'

    $catPortBox = Get-UiConsoleControl 'CatPortBox'
    Set-UiConsoleManualCatPort -PortName COM99
    Assert-UiConsole ((Get-UiRadioCatSelectedPort) -ceq 'COM99') 'manual CAT COM port entry was rejected without discovery metadata.'
    Start-UiRadioCatOperation -Operation 'query'
    $manualPortQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $manualPortQueryReady 'manual COM99 did not submit through the CAT operation path.'
    Assert-UiConsole ([string]$script:radioCatObservedPortName -ceq 'COM99') 'manual CAT query did not retain the selected COM99 identity.'
    Set-UiConsoleManualCatPort -PortName COM5
    $hriConflictRejected = $false
    try { Start-UiRadioCatOperation -Operation 'query' -PortNameOverride 'COM5' } catch { $hriConflictRejected = $_.Exception.Message -match 'HRI|不能用于 CAT' }
    Assert-UiConsole $hriConflictRejected 'CAT operation accepted the same COM5 port that the active profile assigns to HRI.'
    Set-UiRadioCatDeviceControls
    Update-UiRadioCatControls

    $script:radioControlPreferences.desired_power_watts = 40
    Invoke-UiConsoleClick -Name 'ConnectButton'
    $connected = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { $script:supervisor -and -not $script:supervisor.HasExited }
    Assert-UiConsole $connected 'real ConnectButton did not pass through the fake native supervisor seam.'
    Assert-UiConsole (-not (Get-UiConsoleControl 'CatPortBox').IsEnabled -and (Get-UiConsoleControl 'CatOperatingPanel').IsEnabled) 'connected state did not lock CAT configuration while leaving right operations enabled.'
    $firstQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $firstQueryReady 'first CAT state query did not complete within its bound.'
    Assert-UiConsole ([string]$script:radioCatObserved.radio_id.value -ceq '0840' -and [int]$script:radioCatObserved.power.value.watts -eq 25) 'first query did not publish ID 0840 and actual 25 W state.'
    Assert-UiConsole ((Get-UiConsoleControl 'ReadRadioButton').IsEnabled) ("connected right-side read operation was disabled after the first sample; port={0}, key={1}, selected={2}, text={3}, explicit={4}, result={5}, busy={6}, status={7}" -f (Get-UiRadioCatSelectedPort), (Get-UiRadioCatConnectionKey), [string]$catPortBox.SelectedItem.Tag.Value, [string]$catPortBox.Text, [bool]$script:radioCatPortSelectionExplicit, [string]$script:radioCatResult.status, [bool]$script:radioCatOperationPowerShell, (Get-UiConsoleControl 'CatOperationStatusText').Text)
    Assert-UiConsole (-not (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'power write was enabled before the user created a draft.'
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

    Stop-UiRadioCatPolling -Reason 'test_pause_after_poll'
    Invoke-UiConsoleClick -Name 'ReadRadioButton'
    $manualQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $manualQueryReady 'real ReadRadioButton event did not run a query.'

    Invoke-UiConsoleClick -Name 'ApplyCatPowerButton'
    $setReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $setReady 'CAT setPower operation did not finish within its bound.'
    $appliedWatts = if ($script:radioCatResult -and $script:radioCatResult.desired) { [int]$script:radioCatResult.desired.watts } else { -1 }
    Assert-UiConsole ($appliedWatts -eq 24) ("power apply did not use the explicit draft; result={0}, status={1}, preference={2}, draft={3}, ordinal={4}, message={5}" -f $appliedWatts,$script:radioCatLastOperationStatus,$script:radioControlPreferences.desired_power_watts,$script:radioCatEditDraft.power,$script:radioCatOperationOrdinal,(Get-UiConsoleControl 'CatOperationStatusText').Text)
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 24 -and $null -eq $script:radioCatEditDraft.power) 'confirmed readback did not update actual 24 W and clear the draft.'

    (Get-UiConsoleControl 'CatPowerSlider').Value = 25
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'confirmed SPA-1 state did not enable the explicit 25 W candidate before the changed path was known.'
    Invoke-UiConsoleClick -Name 'ApplyCatPowerButton'
    $rejectedPowerReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $rejectedPowerReady 'FieldHead range rejection did not complete.'
    Assert-UiConsole ($script:radioCatLastOperationStatus -ceq 'rejected' -and $script:radioCatResult -and
        [string]$script:radioCatResult.status -ceq 'rejected' -and [string]$script:radioCatResult.cleanup_status -ceq 'closed' -and
        [string]$script:radioCatResult.observed.radio_id.value -ceq '0840' -and
        [int]$script:radioCatResult.capabilities.set_power.maximum_watts -eq 10 -and
        [string]$script:radioCatObserved.power.value.path -ceq 'FieldHead' -and [int]$script:radioCatObserved.power.value.watts -eq 5) 'rejected power request was not retained as rejected or its verified FieldHead 5 W observation/capability was lost.'
    Assert-UiConsole ([double](Get-UiConsoleControl 'CatPowerSlider').Maximum -eq 10 -and
        (Get-UiConsoleControl 'CatObservedPowerText').Text -match 'FieldHead 5 W' -and
        -not (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'rejected FieldHead readback did not update the 10 W limit while removing write permission.'
    Assert-UiConsole ([int]$script:radioControlPreferences.desired_power_watts -eq 24) 'rejected power request overwrote the last confirmed power preference.'

    Invoke-UiConsoleClick -Name 'ReadRadioButton'
    $fieldHeadQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $fieldHeadQueryReady 'CAT query did not restore permission after the rejected FieldHead request.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 5 -and [string]$script:radioCatObserved.power.value.path -ceq 'FieldHead') 'confirmed FieldHead query did not retain the actual path and 5 W value.'
    (Get-UiConsoleControl 'CatPowerSlider').Value = 9
    Assert-UiConsole ([int]$script:radioCatEditDraft.power -eq 9 -and (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) 'real slider change did not immediately enable a legal 9 W FieldHead draft.'
    Invoke-UiConsoleClick -Name 'ApplyCatPowerButton'
    $fieldHeadSetReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $fieldHeadSetReady 'legal FieldHead power operation did not finish.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 9 -and $null -eq $script:radioCatEditDraft.power -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 9) 'confirmed 9 W FieldHead readback did not update actual and saved-preference state.'

    $powerStampBeforeTimeout = [string]$script:radioCatObserved.power.updated_at_utc
    Start-UiRadioCatOperation -Operation 'query'
    $failedQueryReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $failedQueryReady 'synthetic timeout query did not complete.'
    Assert-UiConsole ($null -eq $script:radioCatResult -and -not (Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled) ("query timeout left an old write permit enabled; ordinal={0}, status={1}, result={2}/{3}, button={4}, message={5}" -f $script:radioCatOperationOrdinal,$script:radioCatLastOperationStatus,[string]$script:radioCatResult.operation,[string]$script:radioCatResult.status,(Get-UiConsoleControl 'ApplyCatPowerButton').IsEnabled,(Get-UiConsoleControl 'CatOperationStatusText').Text)
    Assert-UiConsole (-not (Get-UiConsoleControl 'ApplyCatModeButton').IsEnabled -and -not (Get-UiConsoleControl 'ApplyCatFrequencyButton').IsEnabled) 'query timeout left MAIN mode or frequency writes enabled.'
    Assert-UiConsole ([int]$script:radioCatObserved.power.value.watts -eq 9 -and
        [string]$script:radioCatObserved.power.updated_at_utc -ceq $powerStampBeforeTimeout) 'query timeout replaced the last actual value or its original timestamp.'
    $script:radioCatEditDraft.mode = 'FM-N'
    $script:radioCatEditDraft.frequency = '145.600'
    $script:radioCatEditDraft.power = 20
    Update-UiRadioCatControls
    $failedPermitOrdinal = [int]$script:radioCatOperationOrdinal
    Invoke-UiRadioCatAction -Operation 'setMode'
    Invoke-UiRadioCatAction -Operation 'setFrequency'
    Invoke-UiRadioCatAction -Operation 'setPower'
    Assert-UiConsole ([int]$script:radioCatOperationOrdinal -eq $failedPermitOrdinal) 'a failed CAT query still allowed a write operation to start.'
    $script:radioCatEditDraft.mode = $null
    $script:radioCatEditDraft.frequency = $null
    $script:radioCatEditDraft.power = $null
    Update-UiRadioCatControls

    Invoke-UiConsoleClick -Name 'ReadRadioButton'
    $permitRefreshReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $permitRefreshReady 'a successful CAT read did not restore write permission after the synthetic timeout.'

    $modeBox = Get-UiConsoleControl 'CatMainModeBox'
    $modeBox.SelectedItem = @($modeBox.Items | Where-Object { [string]$_.Tag -ceq 'FM-N' })[0]
    Assert-UiConsole ([string]$script:radioCatEditDraft.mode -ceq 'FM-N') 'real MAIN mode selector did not create a draft.'
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatModeButton').IsEnabled) 'confirmed CAT state did not enable MAIN mode application.'
    Invoke-UiConsoleClick -Name 'ApplyCatModeButton'
    $modeApplyReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 8000 -Condition {
        -not $script:radioCatOperationPowerShell -and -not $script:stopTask -and -not $script:radioCatPendingModeFrequencyRequest
    }
    Assert-UiConsole $modeApplyReady 'MAIN mode operation did not finish stop → fresh query → single set within its bound.'
    Assert-UiConsole (-not $script:supervisor -and [string]$script:radioCatObserved.main_mode.value.mode -ceq 'FM-N' -and
        $script:radioCatLastOperationStatus -ceq 'confirmed') 'MAIN mode apply did not preserve stop-first behavior and confirm the requested FM-N readback.'
    Assert-UiConsole ($null -eq $script:radioCatEditDraft.mode) 'confirmed MAIN mode readback did not clear the mode draft.'

    Invoke-UiConsoleClick -Name 'ReadRadioButton'
    $modeRefreshReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $modeRefreshReady 'CAT state was not refreshed before applying MAIN frequency.'
    (Get-UiConsoleControl 'CatMainFrequencyMHzBox').Text = '145.600'
    Assert-UiConsole ([string]$script:radioCatEditDraft.frequency -ceq '145.600') 'real MAIN frequency textbox did not retain its draft.'
    Assert-UiConsole ((Get-UiConsoleControl 'ApplyCatFrequencyButton').IsEnabled) 'confirmed CAT state did not enable MAIN frequency application.'
    Invoke-UiConsoleClick -Name 'ApplyCatFrequencyButton'
    $frequencyApplyReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 4000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $frequencyApplyReady 'MAIN frequency CAT operation did not finish.'
    Assert-UiConsole ([long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and $null -eq $script:radioCatEditDraft.frequency) 'MAIN frequency apply did not confirm the requested 145.600 MHz readback.'

    Start-UiRadioCatOperation -Operation 'query'
    Stop-UiRadioCatPolling -Reason 'test_disconnect'
    $cancelReady = Invoke-UiConsoleDispatcherUntil -TimeoutMs 5000 -Condition { -not $script:radioCatOperationPowerShell }
    Assert-UiConsole $cancelReady 'disconnect did not release the in-flight CAT worker within the bound.'
    Assert-UiConsole (-not $script:radioCatPollingActive -and -not (Invoke-UiRadioCatPollTick -Force)) 'disconnect left CAT polling enabled.'

    $script:radioCatPollingActive = $true
    $script:radioCatPollingConnectionKey = Get-UiRadioCatConnectionKey
    $script:supervisor = $null
    $script:stopTask = [pscustomobject]@{ IsCompleted=$true }
    Assert-UiConsole ([bool](Complete-BridgeStop)) 'core disconnect completion path did not run.'
    Assert-UiConsole (-not $script:radioCatPollingActive) 'core disconnect completion did not stop CAT polling.'
    Assert-UiConsole ((Get-UiConsoleControl 'CatPortBox').IsEnabled) 'disconnect did not unlock left CAT configuration.'

    $fakeDelayedSupervisor = [pscustomobject]@{ HasExited=$false; Operation='connect'; StopDelay=$true; StopRequested=$false; StopResult=$null }
    $fakeDelayedSupervisor | Add-Member -MemberType ScriptMethod -Name StopAsync -Value {
        param([int]$TimeoutMs)
        $this.StopRequested = $true
        $this.StopResult = [pscustomobject]@{ IsCompleted=(-not [bool]$this.StopDelay) }
        if (-not $this.StopDelay) { $this.HasExited = $true }
        return $this.StopResult
    }
    $fakeDelayedSupervisor | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.HasExited = $true }
    $script:supervisor = $fakeDelayedSupervisor
    $script:radioCatPollingActive = $true
    $script:radioCatPollingConnectionKey = Get-UiRadioCatConnectionKey
    $exitOrdinal = [int]$script:radioCatOperationOrdinal
    Invoke-UiConsoleClick -Name 'StopButton'
    Assert-UiConsole ($fakeDelayedSupervisor.StopRequested -and $script:stopTask -and -not $script:stopTask.IsCompleted) 'StopAndExit did not remain pending behind the fake delayed supervisor.'
    Assert-UiConsole (-not $script:radioCatPollingActive -and [int]$script:radioCatOperationOrdinal -eq $exitOrdinal) 'StopAndExit restarted CAT polling while core shutdown was delayed.'
    $fakeDelayedSupervisor.HasExited = $true
    $script:stopTask.IsCompleted = $true
    Assert-UiConsole ([bool](Complete-BridgeStop)) 'delayed fake supervisor shutdown did not complete.'
    Assert-UiConsole ([int]$script:radioCatOperationOrdinal -eq $exitOrdinal -and -not $script:radioCatOperationPowerShell) 'CAT query restarted during StopAndExit completion.'
} finally {
    if ($script:deviceDiscoveryPowerShell -and $script:deviceDiscoveryAsync -and -not $script:deviceDiscoveryAsync.IsCompleted) {
        try { $script:deviceDiscoveryStopAsync = $script:deviceDiscoveryPowerShell.BeginStop($null,$null) } catch { }
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
    }
    if ($script:uiTimer) { $script:uiTimer.Stop() }
    if ($script:radioCatPollingActive) { Stop-UiRadioCatPolling -Reason 'test_cleanup' }
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(4)
    while ($script:radioCatOperationPowerShell -and [DateTime]::UtcNow -lt $cleanupDeadline) {
        try { [void](Complete-UiRadioCatOperation) } catch { }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 30
    }
    if ($script:settingsWindow) { try { $script:settingsWindow.Close() } catch { } }
    if ($script:mainWindow -and $script:mainWindow.IsVisible) {
        $script:allowWindowClose = $true
        try { $script:mainWindow.Close() } catch { }
    }
    if ($script:testRoot -and [System.IO.Directory]::Exists($script:testRoot)) {
        Assert-UiConsoleTempPathSafe -Path $script:testRoot
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force
    }
}
Write-Output ("PASS: test-ui-console.ps1 ({0} real-WPF interaction assertions; PowerShell {1})" -f $script:assertionCount,$PSVersionTable.PSVersion)
