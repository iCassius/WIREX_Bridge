[CmdletBinding()]
param([switch]$CatOnly)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

function Assert-RadioUi {
    param([object]$Condition,[string]$Message)
    $script:radioUiAssertionCount++
    if ($Condition -is [array]) {
        $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1)
        throw ('Assertion received an array condition from line {0}: {1}' -f $caller.ScriptLineNumber,$Message)
    }
    if (-not [bool]$Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$mainXamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
$xamlPath = Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'
$radioCatUiPath = Join-Path $repoRoot 'ui\windows\RadioCatUi.ps1'
$portableConfigModulePath = Join-Path $repoRoot 'ui\windows\PortableConfig.psm1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$parseErrors)
Assert-RadioUi ($parseErrors.Count -eq 0) 'bridge-ui.ps1 无法解析。'
$catTokens = $null
$catParseErrors = $null
$catAst = [System.Management.Automation.Language.Parser]::ParseFile($radioCatUiPath,[ref]$catTokens,[ref]$catParseErrors)
Assert-RadioUi ($catParseErrors.Count -eq 0) 'RadioCatUi.ps1 无法解析。'
$definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true)
$catDefinitions = $catAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true)
Invoke-Expression ((@($definitions) + @($catDefinitions) | ForEach-Object { $_.Extent.Text }) -join "`r`n")
$script:productionStartBridgeRun = (Get-Command -Name Start-BridgeRun -CommandType Function).ScriptBlock
Import-Module -Name (Join-Path $repoRoot 'tools\bridge-user-config.psm1') -Force
Import-Module -Name $portableConfigModulePath -Force
$script:productionRejectedReadbackValidator = (Get-Command Test-UiRadioCatRejectedPowerReadback).ScriptBlock
$script:radioCatRejectedPowerReadbackInput = $null
$script:radioCatRejectedPowerReadbackValid = $false
function Test-UiRadioCatRejectedPowerReadback {
    param([Parameter(Mandatory=$true)][object]$Result,[Parameter(Mandatory=$true)][string]$ExpectedPort)
    $script:radioCatRejectedPowerReadbackInput = $Result
    $script:radioCatRejectedPowerReadbackValid = [bool](& $script:productionRejectedReadbackValidator -Result $Result -ExpectedPort $ExpectedPort)
    return $script:radioCatRejectedPowerReadbackValid
}

$script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-r116-ui-cat-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:testRoot)
$script:radioControlPreferencesPath = ''
$script:portableConfigDirectory = $script:testRoot
$script:portableConfigPath = Join-Path $script:testRoot 'config.json'
$script:profilePath = Join-Path $script:testRoot 'connection-profile.json'
$script:audioSettingsPath = Join-Path $script:testRoot 'audio-settings.json'
$script:passwordPointerPath = Join-Path $script:testRoot 'password-path.txt'
$script:mainXamlPath = $mainXamlPath
$script:settingsXamlPath = $xamlPath
$script:radioCatModulePath = Join-Path $script:testRoot 'RadioCat.psm1'
$script:radioCatLogPath = Join-Path $script:testRoot 'operations.log'
$script:radioUiAssertionCount = 0
$script:maxWindowWidth = 1280
$script:maxWindowHeight = 900
$script:RenderOnly = $true
$global:RenderOnly = $true
$script:radioCatModuleAvailable = $true
$script:radioControlPreferencesError = ''
$script:deviceDiscoveryState = 'not_started'
$script:deviceDiscoveryPowerShell = $null
$script:deviceAudioQuery = $null
$script:deviceCatalog = $null
$script:mainWindow = $null
$script:supervisor = $null
$script:latestStatus = $null
$script:lastStatusUtc = [DateTime]::UtcNow
$script:activeHriPortName = 'COM5'
$script:activeProfile = $null
$script:effectiveProfile = $null
$script:storedProfile = $null
$script:activeRouting = $null
$script:pendingCallTarget = $null
$script:routingDraftPreservedAfterTimeout = $false
$script:routingDraftAfterTimeout = $null
$script:profileEditable = $true
$script:profileWriteAllowed = $true
$script:radioCatOperationKind = ''
$script:radioCatOperationPowerShell = $null
$script:radioCatOperationAsync = $null
$script:radioCatOperationStopAsync = $null
$script:radioCatOperationCancelled = $false
$script:radioCatOperationStartedUtc = [DateTime]::MinValue
$script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
$script:radioCatObserved = $null
$script:radioCatResult = $null
$script:radioCatObservedConnectionKey = ''
$script:radioCatObservedPortName = ''
$script:radioModeApplyAfterStop = $null
$script:radioModePreviousHriPortName = ''
$script:stopTask = $null
$script:closingAfterStop = $false
$script:reconnectAfterStop = $false
$script:allowWindowClose = $false
$script:radioCatCloseMainAfterOperation = $false
$script:radioCatCloseSettingsAfterOperation = $false
$script:testStartBridgeRunCalls = 0
$script:testUiEvents = New-Object 'System.Collections.Generic.List[string]'
$script:testTransientStatuses = New-Object 'System.Collections.Generic.List[object]'

$testConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
$testConfig.connection.callsign = 'N0TEST'
$testConfig.connection.gateway_id = [uint64]12345
$testConfig.connection.source_id = [uint64]123456
$testConfig.devices.cat_port = 'COM11'
$testConfig.devices.cat_baud_rate = 38400
$testConfig.devices.cat_stop_bits = 'Two'
$testConfig.devices.desired_power_watts = 40
$null = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $testConfig
[System.IO.File]::WriteAllText($script:radioCatLogPath,'',(New-Object System.Text.UTF8Encoding($false)))

$fakeModule = @'
function Invoke-Ftx1CatOperation {
    [CmdletBinding()]
    param([string]$Operation,[string]$PortName,[string]$PortRole,[string]$HriPortName,[int]$BaudRate,[string]$StopBits,[int]$TimeoutMs,[int]$PowerWatts,[string]$Side,[string]$Mode,[long]$FrequencyHz)
    $log = $env:WIREX_R116_UI_CAT_LOG
    [System.IO.File]::AppendAllText($log,('BEGIN|' + $Operation + "`n"),(New-Object System.Text.UTF8Encoding($false)))
    try {
        if ($env:WIREX_R116_UI_CAT_DELAY -ceq $Operation) {
            $delayMs = 0
            [void][int]::TryParse([string]$env:WIREX_R116_UI_CAT_DELAY_MS,[ref]$delayMs)
            if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs } else { Start-Sleep -Seconds 12 }
        }
        $argumentLine = 'ARGS|{0}|Port={1}|Role={2}|HRI={3}|Baud={4}|StopBits={5}|Side={6}|Mode={7}|FrequencyHz={8}|PowerWatts={9}' -f `
            $Operation,$PortName,$PortRole,$HriPortName,$BaudRate,$StopBits,$Side,$Mode,$FrequencyHz,$PowerWatts
        [System.IO.File]::AppendAllText($log,($argumentLine + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        if ($Operation -cin @('setMode','setFrequency','setPower')) { [System.IO.File]::AppendAllText($log,('WRITE|' + $Operation + "`n"),(New-Object System.Text.UTF8Encoding($false))) }
        $source = 'CAT test transport'
        $now = [DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $path = [string]$env:WIREX_R116_UI_CAT_PATH
        if (-not $path) { $path = 'Spa1' }
        $max = if ($path -ceq 'FieldHead') { 10 } else { 50 }
        $defaultPower = 25
        if ($env:WIREX_R116_UI_CAT_POWER) { [void][int]::TryParse([string]$env:WIREX_R116_UI_CAT_POWER,[ref]$defaultPower) }
        $powerWattsObserved = $defaultPower
        $mainFrequencyHz = [long]123456
        $mainMode = 'FM'
        $allLog = [System.IO.File]::ReadAllText($log)
        $lastQueryIndex = $allLog.LastIndexOf('STATE|query|',[StringComparison]::Ordinal)
        if ($lastQueryIndex -ge 0) {
            $recentLog = $allLog.Substring($lastQueryIndex)
            $queryState = [regex]::Match($recentLog,'STATE\|query\|([^|\r\n]+)\|([^|\r\n]+)\|([^|\r\n]+)')
            if ($queryState.Success) {
                $mainMode = [string]$queryState.Groups[1].Value
                [void][long]::TryParse($queryState.Groups[2].Value,[ref]$mainFrequencyHz)
                [void][int]::TryParse($queryState.Groups[3].Value,[ref]$powerWattsObserved)
            }
            $modeReadbacks = [regex]::Matches($recentLog,'READBACK\|setMode\|([^\r\n]+)')
            if ($modeReadbacks.Count -gt 0) { $mainMode = [string]$modeReadbacks[$modeReadbacks.Count - 1].Groups[1].Value }
            $frequencyReadbacks = [regex]::Matches($recentLog,'READBACK\|setFrequency\|([^\r\n]+)')
            if ($frequencyReadbacks.Count -gt 0) { [void][long]::TryParse($frequencyReadbacks[$frequencyReadbacks.Count - 1].Groups[1].Value,[ref]$mainFrequencyHz) }
            $powerReadbacks = [regex]::Matches($recentLog,'READBACK\|setPower\|([^\r\n]+)')
            if ($powerReadbacks.Count -gt 0) { [void][int]::TryParse($powerReadbacks[$powerReadbacks.Count - 1].Groups[1].Value,[ref]$powerWattsObserved) }
        }
        if ($Operation -ceq 'query') {
            switch ([string]$env:WIREX_R116_UI_CAT_SAMPLE) {
                '1' { $mainFrequencyHz = [long]145100000; $mainMode = 'C4FM-DN' }
                '2' { $mainFrequencyHz = [long]145200000; $mainMode = 'FM-N' }
                '3' { $mainFrequencyHz = [long]145300000; $mainMode = 'C4FM-VW' }
                '4' { $mainFrequencyHz = [long]145400000; $mainMode = 'FM' }
                'matched' { $mainFrequencyHz = [long]145600000; $mainMode = 'C4FM-DN' }
            }
            if ($env:WIREX_R116_UI_CAT_FORCE_POWER) {
                [void][int]::TryParse([string]$env:WIREX_R116_UI_CAT_FORCE_POWER,[ref]$powerWattsObserved)
            }
            [System.IO.File]::AppendAllText($log,('STATE|query|' + $mainMode + '|' + $mainFrequencyHz + '|' + $powerWattsObserved + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        } elseif ($Operation -ceq 'setMode') {
            $mainMode = if ($env:WIREX_R116_UI_CAT_FAIL -ceq 'setMode') { 'FM-N' } else { [string]$Mode }
            [System.IO.File]::AppendAllText($log,('READBACK|' + $Operation + '|' + $mainMode + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        } elseif ($Operation -ceq 'setFrequency') {
            $mainFrequencyHz = if ($env:WIREX_R116_UI_CAT_FAIL -ceq 'setFrequency') { [long]123456 } else { [long]$FrequencyHz }
            [System.IO.File]::AppendAllText($log,('READBACK|' + $Operation + '|' + $mainFrequencyHz + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        } elseif ($Operation -ceq 'setPower') {
            if ($PowerWatts -ge 5 -and $PowerWatts -le $max -and $env:WIREX_R116_UI_CAT_FAIL -cne 'setPower') { $powerWattsObserved = $PowerWatts }
            [System.IO.File]::AppendAllText($log,('READBACK|' + $Operation + '|' + $powerWattsObserved + "`n"),(New-Object System.Text.UTF8Encoding($false)))
        }
        $identityValue = if ($env:WIREX_R116_UI_CAT_BAD_ID -eq '1') { '9999' } else { '0840' }
        $observed = [ordered]@{
            radio_id = [pscustomobject]@{ value=$identityValue; source=$source; updated_at_utc=$now }
            auto_information_enabled = [pscustomobject]@{ value=$false; source=$source; updated_at_utc=$now }
            tx_state = [pscustomobject]@{ value=[int]0; source=$source; updated_at_utc=$now }
            main_frequency_hz = [pscustomobject]@{ value=$mainFrequencyHz; source=$source; updated_at_utc=$now }
            sub_frequency_hz = [pscustomobject]@{ value=[long]234567; source=$source; updated_at_utc=$now }
            main_mode = [pscustomobject]@{ value=[pscustomobject]@{ side='Main'; side_code='0'; mode_code='4'; mode=$mainMode }; source=$source; updated_at_utc=$now }
            sub_mode = [pscustomobject]@{ value=[pscustomobject]@{ side='Sub'; side_code='1'; mode_code='4'; mode='FM' }; source=$source; updated_at_utc=$now }
            power = [pscustomobject]@{ value=[pscustomobject]@{ path=$path; path_code=$(if ($path -ceq 'FieldHead') { '1' } else { '2' }); watts=$powerWattsObserved }; source=$source; updated_at_utc=$now }
        }
        $status = 'confirmed'
        $errorCode = $null
        $errorMessage = $null
        $prior = $null
        if ($Operation -ceq 'setMode') { $prior=[pscustomobject]@{side='Main';mode='FM'} }
        elseif ($Operation -ceq 'setFrequency') { $prior=[pscustomobject]@{side='Main';frequency_hz=[long]123456} }
        elseif ($Operation -ceq 'setPower') { $prior=[pscustomobject]@{path=$path;watts=$defaultPower} }
        if ($Operation -ceq 'setPower' -and ($PowerWatts -lt 5 -or $PowerWatts -gt $max)) { $status = 'rejected'; $errorCode='power_out_of_range'; $errorMessage='FieldHead path rejected requested power.' }
        if ($env:WIREX_R116_UI_CAT_FAIL -ceq $Operation) { $status = 'mismatch'; $errorCode='readback_mismatch'; $errorMessage='Synthetic readback did not match the frozen target.' }
        if ($env:WIREX_R116_UI_CAT_BAD_ID -eq '1') { $status = 'unknown' }
        $caps = [pscustomobject]@{
            query = [pscustomobject]@{ supported=$true; available=$true }
            set_mode = [pscustomobject]@{ supported=$true; available=$true }
            set_frequency = [pscustomobject]@{ supported=$true; available=$true; target_side='Main'; minimum_hz=[long]30000; maximum_hz=[long]470000000; step_hz=1 }
            set_power = [pscustomobject]@{ supported=$true; available=($status -ceq 'confirmed'); readable=$true; active_path=$path; minimum_watts=5; maximum_watts=$max; step_watts=1; unavailable_reason=$null; value_semantics='CAT setting' }
        }
        return [pscustomobject][ordered]@{
            schema_version=1; operation=$Operation; status=$status; source=$source; port_name=$PortName; port_role='CAT-1'
            started_at_utc=$now; updated_at_utc=$now; desired=$null; prior=$prior; observed=[pscustomobject]$observed
            capabilities=$caps; cleanup_status='closed'; error_code=$(if ($status -ceq 'rejected') { 'power_out_of_range' } elseif ($status -ceq 'unknown') { 'identity_mismatch' } else { $null })
            error_message=$(if ($status -ceq 'unknown') { 'Identity is invalid.' } elseif ($errorMessage) { $errorMessage } else { $null })
        }
    } finally {
        [System.IO.File]::AppendAllText($log,('CLEANUP|' + $Operation + "`n"),(New-Object System.Text.UTF8Encoding($false)))
    }
}
Export-ModuleMember -Function Invoke-Ftx1CatOperation
'@
[System.IO.File]::WriteAllText($script:radioCatModulePath,$fakeModule,(New-Object System.Text.UTF8Encoding($true)))
$env:WIREX_R116_UI_CAT_LOG = $script:radioCatLogPath
$env:WIREX_R116_UI_CAT_MODULE_PATH = $script:radioCatModulePath
$script:isolatedUiMode = $true
$script:NoAutoConnect = $false
$script:uiTestHooks = $null
$isolatedConnectBlocked = -not (Connect-UiRadioCatSession -Automatic)
$isolatedOperationBlocked = $false
try { Start-UiRadioCatOperation -Operation query }
catch { $isolatedOperationBlocked = $_.Exception.Message -match '隔离界面禁止' }
Assert-RadioUi ($isolatedConnectBlocked -and $isolatedOperationBlocked -and -not $script:radioCatOperationPowerShell) `
    'RenderOnly式隔离模式没有在串口worker启动前拒绝CAT自动连接和真实操作。'
$script:uiTestHooks = @{ CatOperation = {
    param([object]$Context)
    Import-Module -Name $env:WIREX_R116_UI_CAT_MODULE_PATH -Force
    $operationParameters = $Context.parameters
    Invoke-Ftx1CatOperation @operationParameters
} }
$script:NoAutoConnect = $true
$noAutoConnectBlocksAuto = -not (Connect-UiRadioCatSession -Automatic)
$noAutoConnectAllowsManual = Test-UiRadioCatHardwareAccessAllowed
$script:NoAutoConnect = $false
Assert-RadioUi ($noAutoConnectBlocksAuto -and $noAutoConnectAllowsManual) `
    'NoAutoConnect 应禁止 CAT 自动连接，同时保留 CAT 手动连接所需的真实运行模式。'
Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
Remove-Item Env:\WIREX_R116_UI_CAT_PATH -ErrorAction SilentlyContinue
Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue

# Isolate unrelated profile/audio behavior while exercising the actual WPF load and CAT functions.
function Read-BridgeUserConnectionProfile { param([string]$Path) return $null }
function Read-BridgeAudioSettings { param([string]$Path) return [pscustomobject]@{ RadioPlaybackGainMilli=[uint32]1000; MicTransmitGainMilli=[uint32]16000 } }
function Write-BridgeAudioSettings {
    param([string]$Path,[uint32]$RadioPlaybackGainMilli,[uint32]$MicTransmitGainMilli)
    $record = [pscustomobject]@{ RadioPlaybackGainMilli=$RadioPlaybackGainMilli; MicTransmitGainMilli=$MicTransmitGainMilli }
    [System.IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $record -Depth 3),(New-Object System.Text.UTF8Encoding($false)))
}
function Update-CallTargetChoices { }
function Update-UiPlaybackGainDisplay { param([object]$Record) }
function Get-UiReceiveEditorState {
    param([object]$Profile)
    $result = [pscustomobject]@{ status_name = 'test' }
    return $result
}
function Get-UiProfileMigrationSourceSchema { param([object]$Profile) return $null }
function Copy-UiRxPolicy {
    param([object]$Policy)
    return [pscustomobject][ordered]@{
        group_mode = 'selected'; private_mode = 'disabled'; allow_groups = @(); allow_private_peers = @()
        local_private_routes = @(); blocked_groups = @(); blocked_source_ids = @()
    }
}
function Read-CurrentPasswordPath { return '' }
function Set-GainValueLabel { param([string]$SliderName,[string]$LabelName) }
function Set-SettingsDeviceControls { }
function Set-SettingsPolicyLists { }
function Invalidate-UiDeviceDiscoveryForWindow { param([object]$Window) }
function Set-MainText { param([string]$Name,[string]$Text) }
function Set-MainTargetSummary { param([object]$Profile,[string]$OverallLabel) }
function Set-ConnectionButtonState { }
function Set-OfflineDisplay { param([string]$Reason) }
function Add-UiEvent { param([string]$Text) [void]$script:testUiEvents.Add($Text) }
function Set-UiTransientStatus {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,[bool]$Failed=$false,[switch]$Restart)
    [void]$script:testTransientStatuses.Add([pscustomobject]@{ message=$Message; failed=$Failed; restart=[bool]$Restart })
}
function Clear-UiIdentityQueryQueue { }
function Update-DynamicGroupControls { }
function Update-UiReceiveMetricsDisplay { param([object]$Record) }
function Set-UiIdentityRowVisibility { param([string]$Row,[System.Windows.Visibility]$Visibility) }
function Update-UiIdentityActionState { }
function Start-BridgeRun {
    param([switch]$BmStartDisconnected)
    $script:testStartBridgeRunCalls++
    $script:testLastBmStartDisconnected=[bool]$BmStartDisconnected
}
function Set-UiControl { param([string]$Name,[object]$Value) }

function New-TestRadioSupervisor {
    param([bool]$HriSerialOpen=$true)
    $source = New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
    $supervisor = [pscustomobject]@{ HasExited=$false; StopSource=$source; DisposeCount=0; StopCallCount=0; Disposed=$false }
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name StopAsync -Value { param([int]$TimeoutMs) $this.StopCallCount++; return $this.StopSource.Task } | Out-Null
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++; $this.Disposed=$true } | Out-Null
    $script:latestStatus = [pscustomobject]@{
        hri_serial_open=$HriSerialOpen; hri_ready=$HriSerialOpen
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    return $supervisor
}
function New-TestBmSupervisor {
    $source=New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
    $supervisor=[pscustomobject]@{
        HasExited=$false; StopSource=$source; StopCallCount=0
        SentCommands=(New-Object 'System.Collections.Generic.List[object]')
    }
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$Parameters='')
        [void]$this.SentCommands.Add([pscustomobject]@{request_id=$RequestId;command=$Command;parameters=$Parameters})
        return $true
    } | Out-Null
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name StopAsync -Value {
        param([int]$TimeoutMs)
        $this.StopCallCount++
        return $this.StopSource.Task
    } | Out-Null
    return $supervisor
}
function New-TestMainWindow {
    $window = Import-WpfWindow -Path $script:mainXamlPath
    $window | Add-Member -NotePropertyName Closed -NotePropertyValue $false
    $window.Add_Closed({ $window.Closed = $true }.GetNewClosure())
    return $window
}
function Restore-TestMainWindow {
    if ($script:mainWindow -and $script:mainWindow -is [System.Windows.Window] -and
        -not [object]::ReferenceEquals($script:mainWindow,$script:testRootMainWindow)) {
        try { $script:mainWindow.Close() } catch { }
    }
    $script:mainWindow = $script:testRootMainWindow
}
function Cancel-SettingsWindow {
    if (-not $script:settingsWindow) { return }
    $script:testClosedSettingsWindow = $script:settingsWindow
    $button = $script:settingsWindow.FindName('CancelSettingsButton')
    if (-not $button) { throw '测试设置窗缺少 CancelSettingsButton。' }
    $args = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
    $button.RaiseEvent($args)
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}
function Complete-TestCatRunspace {
    param([int]$TimeoutMs=3000,[switch]$RefreshStatusHeartbeat)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:radioCatOperationPowerShell -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($RefreshStatusHeartbeat) { $script:lastStatusUtc = [DateTime]::UtcNow }
        if ($script:radioCatOperationAsync -and $script:radioCatOperationAsync.IsCompleted) {
            [void](Complete-UiRadioCatOperation)
            break
        }
        if ($script:radioCatOperationStopAsync -and $script:radioCatOperationStopAsync.IsCompleted) {
            [void](Complete-UiRadioCatOperation)
            break
        }
        Start-Sleep -Milliseconds 25
    }
    $watch.Stop()
    return $watch.ElapsedMilliseconds
}
function Complete-TestCatActionSequence {
    param([int]$TimeoutMs=5000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:radioCatOperationPowerShell -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = [Math]::Max(100,$TimeoutMs - [int]$watch.ElapsedMilliseconds)
        [void](Complete-TestCatRunspace -TimeoutMs $remaining)
        if ($script:radioCatOperationPowerShell -and $script:radioCatOperationAsync -and -not $script:radioCatOperationAsync.IsCompleted) {
            Start-Sleep -Milliseconds 20
        }
    }
    $watch.Stop()
    return ($null -eq $script:radioCatOperationPowerShell)
}
function Complete-TestBridgeStop {
    $results = @(Complete-BridgeStop)
    if ($results.Count -eq 0) { return $false }
    return [bool]$results[$results.Count - 1]
}
function Get-TestRadioCatLog {
    param([int]$RetryMs=1000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $text = [System.IO.File]::ReadAllText([string]$script:radioCatLogPath)
            $watch.Stop()
            return $text
        } catch [System.IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge $RetryMs) { $watch.Stop(); throw }
            Start-Sleep -Milliseconds 20
        }
    }
}
function Wait-TestRadioCatLog {
    param([Parameter(Mandatory=$true)][string]$Pattern,[int]$TimeoutMs=2000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            if ((Get-TestRadioCatLog) -match $Pattern) { $watch.Stop(); return $true }
        } catch [System.IO.IOException] { }
        Start-Sleep -Milliseconds 20
    }
    $watch.Stop()
    return $false
}
function Wait-TestRadioCatLogCount {
    param([Parameter(Mandatory=$true)][string]$Pattern,[Parameter(Mandatory=$true)][int]$MinimumCount,[int]$TimeoutMs=2000)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $count = ([regex]::Matches((Get-TestRadioCatLog),$Pattern)).Count
            if ($count -ge $MinimumCount) { $watch.Stop(); return $true }
        } catch [System.IO.IOException] { }
        Start-Sleep -Milliseconds 20
    }
    $watch.Stop()
    return $false
}
function Set-TestRadioCatPowerSelection {
    param([Parameter(Mandatory=$true)][int]$Watts)
    $box = Get-SettingsControl 'CatPowerBox'
    $item = @($box.Items | Where-Object { [string]$_.Tag -ceq [string]$Watts } | Select-Object -First 1)
    if ($item.Count -eq 0 -or -not [bool]$item[0].IsEnabled) { return $false }
    if ((Get-UiRadioCatPowerSelection) -eq $Watts -and $null -eq $script:radioCatEditDraft.power) {
        $alternate = @($box.Items | Where-Object { [bool]$_.IsEnabled -and [int]$_.Tag -ne $Watts } | Select-Object -First 1)
        if ($alternate.Count -gt 0) { $box.SelectedItem = $alternate[0] }
    }
    $box.SelectedItem = $item[0]
    return ([int](Get-UiRadioCatPowerSelection) -eq $Watts)
}
function Set-TestRadioCatFrequencyText {
    param([Parameter(Mandatory=$true)][string]$Text)
    $combo = Get-SettingsControl 'CatMainFrequencyMHzBox'
    [void]$combo.ApplyTemplate()
    Register-UiRadioCatFrequencyTextInput
    $textBox = $combo.Template.FindName('PART_EditableTextBox',$combo)
    if ($textBox -isnot [System.Windows.Controls.TextBox]) { return $false }
    [void]($textBox.Text = $Text)
    return ([string]$combo.Text -ceq $Text)
}
function Get-TestTransientStatus {
    if ($script:testTransientStatuses.Count -eq 0) { return '' }
    return [string]$script:testTransientStatuses[$script:testTransientStatuses.Count - 1].message
}

try {
    # CAT controls and preferences now live in MainWindow.xaml and config.json.
    $script:mainWindow = Import-WpfWindow -Path $script:mainXamlPath
    $script:mainWindow.UpdateLayout()
    $script:mainWindow.Opacity = 0
    $script:mainWindow.Show()
    $script:channels = @((New-UiChannelRecord -Id 460997 -Kind private -Slot 2))
    $script:txChannelKey = 'private:460997:2'
    $script:mutedChannelKeys = @{}
    $script:pendingRoutingMutation = $null
    $script:pendingChannelMutation = $null
    $script:pendingChannelStopMutation = $null
    $script:routingMutationFence = $false
    $script:supervisor = $null
    $script:controlConfirmed = $false
    $script:routingCapabilities = $null
    $script:activeRouting = $null
    $script:portableConfigPath = [System.IO.Path]::GetFullPath($script:portableConfigPath)
    $script:radioControlPreferencesPath = ''
    $script:bmServerSelectionPreferenceId = 'bm-china-4602'
    Import-UiPortableConfig | Out-Null
    Apply-UiPortableConfigToControls
    $script:radioControlPreferences = [pscustomobject][ordered]@{
        schema_version=1; cat_port=[string]$script:portableConfig.devices.cat_port
        baud_rate=[int]$script:portableConfig.devices.cat_baud_rate; stop_bits='Two'
        desired_power_watts=[int]$script:portableConfig.devices.desired_power_watts
    }
    [void](Initialize-SettingsWindow)
    $script:mainWindow.Hide()
    $script:mainWindow.Opacity = 1
    $script:testRootMainWindow = $script:mainWindow
    Initialize-UiRadioCatController
    Set-UiRadioCatDeviceControls
    $powerBox = Get-SettingsControl 'CatPowerBox'
    Assert-RadioUi ((Get-UiRadioCatPowerSelection) -eq 25) '主窗初始功率没有默认为25 W。'
    Assert-RadioUi ((Get-SettingsControl 'SerialConnectButton') -is [System.Windows.Controls.Button] -and
        $null -eq $script:mainWindow.FindName('SerialDisconnectButton') -and
        $null -eq $script:mainWindow.FindName('CatPowerSlider') -and
        $null -eq $script:mainWindow.FindName('CatDesiredPowerText') -and
        $null -eq $script:mainWindow.FindName('CatOperationStatusText') -and
        $null -eq $script:mainWindow.FindName('CatSessionStatusText')) 'XAML仍依赖已移除的连接或CAT旧控件。'
    Assert-RadioUi ($powerBox -is [System.Windows.Controls.ComboBox] -and
        (@($powerBox.Items | ForEach-Object { [string]$_.Tag }) -join ',') -ceq '5,10,15,25,50' -and
        (Get-SettingsControl 'CatMainFrequencyMHzBox').IsEditable) '主窗没有真实功率预设ComboBox或可编辑MAIN频率ComboBox。'
    Assert-RadioUi ($script:radioControlPreferencesPath -ceq '' -and -not [System.IO.File]::Exists((Join-Path $script:testRoot 'radio-control-preferences.json'))) `
        'CAT 设置仍不得创建独立偏好文件。'
    Assert-RadioUi (-not $script:radioCatPowerPreferenceDirty -and [int]$script:radioControlPreferences.desired_power_watts -eq 40) '打开设置窗时误改了已保存功率偏好。'

    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{
        serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic Enhanced'; CatMatchRank=100; IsHri=$false },[pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI'; CatMatchRank=0; IsHri=$true })
        hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' })
        wave_inputs=@(); wave_outputs=@()
    }
    Set-UiRadioCatDeviceControls
    Assert-RadioUi ((Get-UiRadioCatSelectedPort) -ceq 'COM11') 'CAT 候选端口未使用已枚举的 COM11。'
    Update-UiSerialConnectButton
    $serialToggle = Get-SettingsControl 'SerialConnectButton'
    Assert-RadioUi ([string]$serialToggle.Content -ceq '连接串口' -and $serialToggle.IsEnabled) '断开状态的单一串口按钮没有显示可用的连接操作。'
    $originalSerialConnect = (Get-Command -Name Connect-UiSerialCombo -CommandType Function).ScriptBlock
    $originalSerialDisconnect = (Get-Command -Name Disconnect-UiSerialCombo -CommandType Function).ScriptBlock
    $script:testSerialToggleConnectCalls = 0
    $script:testSerialToggleDisconnectCalls = 0
    $script:testSerialToggleConnectResult = $true
    Set-Item -Path Function:\Connect-UiSerialCombo -Value { $script:testSerialToggleConnectCalls++; return [bool]$script:testSerialToggleConnectResult }
    Set-Item -Path Function:\Disconnect-UiSerialCombo -Value { $script:testSerialToggleDisconnectCalls++; return $true }
    $serialToggle.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialToggle)))
    Assert-RadioUi ($script:testSerialToggleConnectCalls -eq 1 -and $script:testSerialToggleDisconnectCalls -eq 0) '串口按钮在真实断开状态没有走既有连接流程。'
    $script:testSerialToggleConnectResult = $false
    $serialToggle.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialToggle)))
    Assert-RadioUi ($script:testSerialToggleConnectCalls -eq 2 -and [string]$serialToggle.Content -ceq '连接串口') '连接失败后按钮没有保持真实断开状态并允许重试。'
    $script:testSerialToggleConnectResult = $true
    $script:radioCatSessionRequested = $true
    Update-UiSerialConnectButton
    Assert-RadioUi ([string]$serialToggle.Content -ceq '断开串口' -and $serialToggle.IsEnabled) 'CAT会话请求后单一按钮没有切换到断开流程。'
    $serialToggle.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialToggle)))
    Assert-RadioUi ($script:testSerialToggleDisconnectCalls -eq 1) '串口按钮在会话活动状态没有走既有断开流程。'
    $script:radioCatSessionRequested = $false
    $script:supervisor = New-TestRadioSupervisor
    Update-UiSerialConnectButton
    Assert-RadioUi ([string]$serialToggle.Content -ceq '断开串口') 'HRI supervisor实际运行时单一按钮没有显示断开操作。'
    $serialToggle.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialToggle)))
    Assert-RadioUi ($script:testSerialToggleDisconnectCalls -eq 2) 'HRI运行时按钮没有走既有HRI/BM/CAT断开流程。'
    $script:supervisor = $null
    Update-UiSerialConnectButton
    Assert-RadioUi ([string]$serialToggle.Content -ceq '连接串口' -and $serialToggle.IsEnabled) '断开完成后串口按钮没有回到可连接状态。'
    $script:preparationStarted = $true
    Update-UiSerialConnectButton
    Assert-RadioUi ([string]$serialToggle.Content -ceq '取消连接' -and $serialToggle.IsEnabled) '串口连接准备中没有保留既有取消流程。'
    $serialToggle.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialToggle)))
    Assert-RadioUi ($script:testSerialToggleDisconnectCalls -eq 3) '串口准备中按按钮没有请求既有取消流程。'
    $script:preparationStarted = $false
    Set-Item -Path Function:\Connect-UiSerialCombo -Value $originalSerialConnect
    Set-Item -Path Function:\Disconnect-UiSerialCombo -Value $originalSerialDisconnect
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$true; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
    }
    $script:lastStatusUtc = [DateTime]::UtcNow

    # A real query runs in the UI-created PowerShell worker and updates the WPF controls from its result.
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '350'
    Start-UiRadioCatOperation -Operation query
    $concurrencyRejected = $false
    try { Start-UiRadioCatOperation -Operation query } catch { $concurrencyRejected = $_.Exception.Message -match '另一项 CAT-1 操作' }
    Assert-RadioUi $concurrencyRejected 'UI 没有阻止第二个并发 CAT 查询。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed') 'fake CAT query 没有通过 UI 完成流程。'
    Assert-RadioUi ((Get-UiRadioCatPowerSelection) -eq 25 -and
        -not (@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '25' })[0].IsEnabled) -and
        -not (@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '15' })[0].IsEnabled) -and
        (@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '10' })[0].IsEnabled) -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 40 -and -not $script:radioCatPowerPreferenceDirty -and
        $script:radioCatPowerNeedsUserChoice -and $null -eq $script:radioCatEditDraft.power) ('FieldHead 首读应显示实测值、保留超出上限的 40 W 偏好，并要求用户明确选择有效功率。 max={0}, value={1}, target={2}, dirty={3}, needsChoice={4}, draft={5}' -f
        10,(Get-UiRadioCatPowerSelection),$script:radioControlPreferences.desired_power_watts,$script:radioCatPowerPreferenceDirty,$script:radioCatPowerNeedsUserChoice,$script:radioCatEditDraft.power)
    Assert-RadioUi ([int]$script:radioControlPreferences.desired_power_watts -eq 40 -and -not $script:radioCatPowerPreferenceDirty -and
        $null -eq $script:radioCatEditDraft.power -and $null -ne (Get-SettingsControl 'ApplyCatSettingsButton')) '首读不得覆盖 40 W 偏好或伪造功率草稿；界面只提供统一 Apply。'
    $frequencyBox = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $currentFrequencyOption = @($frequencyBox.Items | Where-Object { [string]$_.Tag -ceq '__radio_cat_current_frequency__' } | Select-Object -First 1)
    Assert-RadioUi ($currentFrequencyOption.Count -eq 1) 'CAT读到的MAIN频率没有成为可选的当前值项。'
    $frequencyBox.SelectedItem = $currentFrequencyOption[0]
    Assert-RadioUi ([string]$script:radioCatEditDraft.frequency -ceq [string]$frequencyBox.Text) '用户从可编辑频率Combo选择当前值没有形成频率草稿。'
    Set-UiRadioCatDraft -Field frequency -Value $null
    [void](Update-UiRadioCatObservationDisplay)

    $setPowerBeforeNonPresetRead = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    $env:WIREX_R116_UI_CAT_FORCE_POWER = '9'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $nineWattItem = @($powerBox.Items | Where-Object { [string]$_.Tag -ceq '9' } | Select-Object -First 1)
    $nonPresetWasObserved = ($nineWattItem.Count -eq 1 -and $nineWattItem[0].IsEnabled -and
        (Get-UiRadioCatPowerSelection) -eq 9 -and $null -eq $script:radioCatEditDraft.power -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $setPowerBeforeNonPresetRead)
    Assert-RadioUi $nonPresetWasObserved 'SPA-1读到9 W后应自动新增并选中9 W当前值项，且首读不发送功率写入。'
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 9) '用户不能从真实功率Combo中选择当前9 W值项。'
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 9) ('真实选择9 W当前值没有生成独立功率草稿。draft={0},selected={1},programmatic={2},tag={3}' -f $script:radioCatEditDraft.power,(Get-UiRadioCatPowerSelection),[bool]$script:radioCatProgrammaticControlUpdate,[string]$powerBox.Tag)
    Set-UiRadioCatDraft -Field power -Value $null
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    Remove-Item Env:\WIREX_R116_UI_CAT_FORCE_POWER -ErrorAction SilentlyContinue
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)

    # A connected CAT session keeps its controls and values stable across completed poll cycles.
    $modeControl = Get-SettingsControl 'CatMainModeBox'
    $frequencyControl = Get-SettingsControl 'CatMainFrequencyMHzBox'
    $powerBox = Get-SettingsControl 'CatPowerBox'
    $observedPanel = Get-SettingsControl 'CatObservedPanel'
    $operatingPanel = Get-SettingsControl 'CatOperatingPanel'
    $powerButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $script:actionEnableChanged = 0
    foreach ($name in @('ApplyCatSettingsButton')) {
        (Get-SettingsControl $name).Add_IsEnabledChanged({ $script:actionEnableChanged++ })
    }
    $modeControl.Add_IsEnabledChanged({ $script:testModeEnableChanges++ })
    $frequencyControl.Add_IsEnabledChanged({ $script:testFrequencyEnableChanges++ })
    $powerBox.Add_IsEnabledChanged({ $script:testPowerSelectionEnableChanges++ })
    $powerBox.Add_SelectionChanged({ $script:testPowerSelectionChanges++ })
    $script:testModeEnableChanges = 0
    $script:testFrequencyEnableChanges = 0
    $script:testPowerSelectionEnableChanges = 0
    $script:testPowerSelectionChanges = 0
    $script:actionEnableChanged = 0
    $script:radioCatSessionRequested = $false
    $script:radioCatPollingActive = $false
    $script:radioCatManualDisconnect = $false
    $catConnectStarted = Connect-UiRadioCatSession
    Assert-RadioUi ($script:radioCatSessionRequested -and $script:radioCatPollingActive -and
        $script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'query' -and $catConnectStarted) 'CAT会话控制没有启动CAT会话和首读。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ((Get-UiRadioCatSessionState).requested -and (Get-UiRadioCatSessionState).connected -and
        (Get-UiRadioCatSessionState).polling -and -not $script:supervisor) 'CAT首读成功后没有保持独立会话，或启动了HRI核心。'
    Assert-RadioUi ((Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11') -and
        -not (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM5')) 'HRI冲突检查没有区分CAT会话实际占用的COM11与不同COM5。'
    [void](Set-UiRadioCatDraft -Field mode -Value 'C4FM-DN')
    $modeControl.SelectedItem = @($modeControl.Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    Assert-RadioUi (Set-TestRadioCatFrequencyText -Text '145.600') '真实EditableTextBox不能录入合法MAIN频率草稿。'
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 10) 'FieldHead中10 W预设没有作为合法功率目标供用户选择。'
    $script:testPowerSelectionChanges = 0
    Update-UiRadioCatControls
    $actionEnableChanged = 0
    $script:testReadoutTextChanges = 0
    $script:testPowerSelectionChanges = 0
    $script:testModeSelectionChanges = 0
    $script:testFrequencyTextChanges = 0
    $script:testModeEnableChanges = 0
    $script:testFrequencyEnableChanges = 0
    $script:testPowerSelectionEnableChanges = 0
    $script:testPowerSelectionChanges = 0
    $snapshotNames = @('RadioCatPanel','CatOperatingPanel','CatObservedPanel','CatPortBox','CatBaudRateBox','CatMainModeBox',
        'CatMainFrequencyMHzBox','CatPowerBox','ApplyCatSettingsButton')
    function Get-TestRadioCatSnapshot {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($name in $snapshotNames) {
            $control = Get-SettingsControl $name
            $parts.Add(('{0}|{1}|{2}' -f $name,[string]$control.IsEnabled,[string]$control.Visibility))
            if ($control -is [System.Windows.Controls.TextBlock] -or $control -is [System.Windows.Controls.TextBox]) { $parts.Add([string]$control.Text) }
            if ($control -is [System.Windows.Controls.Button]) { $parts.Add([string]$control.Content) }
            if ($control -is [System.Windows.Controls.ComboBox]) {
                if ([string]$control.Name -ceq 'CatMainFrequencyMHzBox') {
                    $parts.Add(('text={0}' -f [string]$control.Text))
                } else {
                    $selectedValue = if ($control.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$control.SelectedItem.Tag } else { '' }
                    $parts.Add(('selected={0};text={1}' -f $selectedValue,[string]$control.Text))
                }
                if ([string]$control.Name -ceq 'CatPowerBox') {
                    $parts.Add(('items=' + (@($control.Items | ForEach-Object { '{0}:{1}' -f [string]$_.Tag,[bool]$_.IsEnabled }) -join ',')))
                }
            }
        }
        $parts.Add(('draft={0}|{1}|{2};session={3};generation={4}' -f $script:radioCatEditDraft.mode,$script:radioCatEditDraft.frequency,
            $script:radioCatEditDraft.power,$script:radioCatSessionState,$script:radioCatSessionGeneration))
        return ($parts -join "`n")
    }
    $readoutControls = @('CatObservedMainModeText','CatObservedFrequencyText','CatObservedPowerText') | ForEach-Object { Get-SettingsControl $_ }
    $script:testReadoutTextChanges = 0
    $textDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.TextBlock]::TextProperty,[System.Windows.Controls.TextBlock])
    foreach ($readout in $readoutControls) { $textDescriptor.AddValueChanged($readout,[System.EventHandler]{ $script:testReadoutTextChanges++ }) }
    $script:testModeSelectionChanges = 0
    $modeControl.Add_SelectionChanged({ $script:testModeSelectionChanges++ })
    $script:testFrequencyTextChanges = 0
    [void]$frequencyControl.ApplyTemplate()
    $frequencyEditBox = $frequencyControl.Template.FindName('PART_EditableTextBox',$frequencyControl)
    Assert-RadioUi ($frequencyEditBox -is [System.Windows.Controls.TextBox]) 'Editable frequency ComboBox没有实际WPF PART_EditableTextBox。'
    Register-UiRadioCatFrequencyTextInput
    $frequencyEditBox.Add_TextChanged({ $script:testFrequencyTextChanges++ })
    $baselineSnapshot = Get-TestRadioCatSnapshot
    $expectedReadoutChangeTotal = 0
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '80'
    for ($pollCycle = 0; $pollCycle -lt 4; $pollCycle++) {
        $sampleNumber = $pollCycle + 1
        $env:WIREX_R116_UI_CAT_SAMPLE = [string]$sampleNumber
        $previousModeReadout = [string](Get-SettingsControl 'CatObservedMainModeText').Text
        $previousFrequencyReadout = [string](Get-SettingsControl 'CatObservedFrequencyText').Text
        $readoutChangeCountBefore = [int]$script:testReadoutTextChanges
        $startedPoll = Invoke-UiRadioCatPollTick -Force
        Assert-RadioUi ($startedPoll -and $script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'query') ('第{0}轮CAT query没有保持为唯一在途操作。' -f ($pollCycle + 1))
        Assert-RadioUi ((Get-TestRadioCatSnapshot) -ceq $baselineSnapshot) ('第{0}轮CAT query在途时读数、编辑器、功率组合框或Apply按钮发生变化。' -f ($pollCycle + 1))
        [void](Update-UiRadioCatControls)
        [void](Update-UiRadioCatObservationDisplay)
        $dispatcherSnapshot = Get-TestRadioCatSnapshot
        Assert-RadioUi ($dispatcherSnapshot -ceq $baselineSnapshot) ('第{0}轮重复dispatcher刷新改变了CAT控件属性。 baseline={1};current={2}' -f ($pollCycle + 1),$baselineSnapshot,$dispatcherSnapshot)
        [void](Complete-TestCatRunspace -TimeoutMs 3000)
        $expectedSample = switch ($sampleNumber) {
            1 { [pscustomobject]@{ mode='C4FM-DN'; frequency_hz=[long]145100000 } }
            2 { [pscustomobject]@{ mode='FM-N'; frequency_hz=[long]145200000 } }
            3 { [pscustomobject]@{ mode='C4FM-VW'; frequency_hz=[long]145300000 } }
            4 { [pscustomobject]@{ mode='FM'; frequency_hz=[long]145400000 } }
        }
        $expectedFrequencyReadout = (Format-UiFrequencyMHz -FrequencyHz ([long]$expectedSample.frequency_hz)) + ' MHz'
        $readoutChangesExpected = [int]($previousModeReadout -cne [string]$expectedSample.mode) +
            [int]($previousFrequencyReadout -cne $expectedFrequencyReadout)
        $readoutChangeCountDelta = [int]$script:testReadoutTextChanges - $readoutChangeCountBefore
        $expectedReadoutChangeTotal += $readoutChangesExpected
        $pollSnapshotAfter = Get-TestRadioCatSnapshot
        $pollSnapshotMatches = ($pollSnapshotAfter -ceq $baselineSnapshot -and
            [string](Get-SettingsControl 'CatObservedMainModeText').Text -ceq [string]$expectedSample.mode -and
            [string](Get-SettingsControl 'CatObservedFrequencyText').Text -ceq $expectedFrequencyReadout -and
            [string](Get-SettingsControl 'CatObservedPowerText').Text -ceq '9 W' -and
            $readoutChangeCountDelta -eq $readoutChangesExpected)
        $pollAssertMessage = '第{0}轮CAT worker完成后应只把新观测写到读数一次，并保持编辑器、功率组合框、状态消息、功率选项和Apply按钮稳定。 readoutDelta={1}/{2}, mode={3}, frequency={4}' -f `
            $sampleNumber,$readoutChangeCountDelta,$readoutChangesExpected,[string](Get-SettingsControl 'CatObservedMainModeText').Text,
            [string](Get-SettingsControl 'CatObservedFrequencyText').Text
        $pollAssertMessage += (' power={0}, expectedPower=9 W' -f [string](Get-SettingsControl 'CatObservedPowerText').Text)
        if (-not $pollSnapshotMatches -and $pollSnapshotAfter -cne $baselineSnapshot) {
            $pollAssertMessage += ' snapshotDiff=' + ((Compare-Object ($baselineSnapshot -split "`n") ($pollSnapshotAfter -split "`n") | ForEach-Object { [string]$_.SideIndicator + $_.InputObject }) -join '|')
        }
        Assert-RadioUi $pollSnapshotMatches $pollAssertMessage
        $baselineSnapshot = Get-TestRadioCatSnapshot
    }
    Assert-RadioUi ($script:actionEnableChanged -eq 0 -and $script:testReadoutTextChanges -eq $expectedReadoutChangeTotal -and
        $script:testModeSelectionChanges -eq 0 -and $script:testFrequencyTextChanges -eq 0 -and
        $script:testModeEnableChanges -eq 0 -and $script:testFrequencyEnableChanges -eq 0 -and
        $script:testPowerSelectionEnableChanges -eq 0 -and $script:testPowerSelectionChanges -eq 0) `
        ('多轮CAT query重复写入了观测文字、功率选择、编辑频率或Apply按钮状态。 readout={0}/{1}, modeSel={2}, freqText={3}, modeEnable={4}, freqEnable={5}, powerEnable={6}, powerSelection={7}, apply={8}' -f $script:testReadoutTextChanges,$expectedReadoutChangeTotal,$script:testModeSelectionChanges,$script:testFrequencyTextChanges,$script:testModeEnableChanges,$script:testFrequencyEnableChanges,$script:testPowerSelectionEnableChanges,$script:testPowerSelectionChanges,$script:actionEnableChanged)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'confirmed' -and
        (Get-UiRadioCatPowerSelection) -eq 10 -and [int]$script:radioCatEditDraft.power -eq 10 -and $powerButton.IsEnabled) `
        '周期 query 完成后没有刷新确认状态，或覆盖用户保留的功率草稿。'

    # The one Apply action freezes all three targets while a query is already in flight.
    $env:WIREX_R116_UI_CAT_SAMPLE = '4'
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    $env:WIREX_R116_UI_CAT_POWER = '5'
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '400'
    [void](Invoke-UiRadioCatPollTick -Force)
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $setModeBeforeApply = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $setFrequencyBeforeApply = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $setPowerBeforeApply = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsClick = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)
    $settingsButton.RaiseEvent($settingsClick)
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setSettings' -and
        [string]$script:radioCatQueuedAction.mode -ceq 'C4FM-DN' -and [long]$script:radioCatQueuedAction.frequency_hz -eq 145600000 -and
        [int]$script:radioCatQueuedAction.power_watts -eq 10 -and [string]$script:radioCatQueuedAction.port_name -ceq 'COM11' -and
        [int]$script:radioCatQueuedAction.generation -eq [int]$script:radioCatSessionGeneration -and
        ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|set(?:Mode|Frequency|Power)')).Count -eq
            ($setModeBeforeApply + $setFrequencyBeforeApply + $setPowerBeforeApply)) `
        'query在途时的统一 Apply 没有冻结模式、频率、功率和CAT会话，或提前写入。'
    Assert-RadioUi (-not $settingsButton.IsEnabled) '统一 Apply 等待当前 query 时没有冻结控件。'
    $queuedSequenceCompleted = Complete-TestCatActionSequence -TimeoutMs 7000
    $queuedLog = Get-TestRadioCatLog
    $queuedApplyConfirmed = ($queuedSequenceCompleted -and $null -eq $script:radioCatSettingsApply -and
        ([regex]::Matches($queuedLog,'BEGIN\|setMode')).Count -eq ($setModeBeforeApply + 1) -and
        ([regex]::Matches($queuedLog,'BEGIN\|setFrequency')).Count -eq ($setFrequencyBeforeApply + 1) -and
        ([regex]::Matches($queuedLog,'BEGIN\|setPower')).Count -eq ($setPowerBeforeApply + 1) -and
        $queuedLog -match 'ARGS\|setMode\|Port=COM11\|Role=CAT-1\|HRI=\|Baud=38400\|StopBits=Two\|Side=Main\|Mode=C4FM-DN' -and
        $queuedLog -match 'ARGS\|setFrequency\|Port=COM11\|Role=CAT-1\|HRI=\|Baud=38400\|StopBits=Two\|Side=Main\|.*FrequencyHz=145600000' -and
        $queuedLog -match 'ARGS\|setPower\|Port=COM11\|Role=CAT-1\|HRI=\|Baud=38400\|StopBits=Two\|.*PowerWatts=10' -and
        $script:radioCatObserved.main_mode.value.mode -ceq 'C4FM-DN' -and
        [long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and
        [int]$script:radioCatObserved.power.value.watts -eq 10)
    if (-not $queuedApplyConfirmed) {
        $batchDebug = [ordered]@{
            values = @($script:radioCatObserved.main_mode.value.mode,$script:radioCatObserved.main_frequency_hz.value,$script:radioCatObserved.power.value.watts)
            status = $script:radioCatLastOperationStatus
            counts = @(([regex]::Matches($queuedLog,'BEGIN\|setMode')).Count,([regex]::Matches($queuedLog,'BEGIN\|setFrequency')).Count,([regex]::Matches($queuedLog,'BEGIN\|setPower')).Count)
            expected = @(($setModeBeforeApply + 1),($setFrequencyBeforeApply + 1),($setPowerBeforeApply + 1))
            args = @(($queuedLog -match 'ARGS\|setMode\|Port=COM11\|Role=CAT-1\|HRI=\|Baud=38400\|StopBits=Two\|Side=Main\|Mode=C4FM-DN'),
                ($queuedLog -match 'ARGS\|setFrequency\|Port=COM11\|Role=CAT-1\|HRI=\|Baud=38400\|StopBits=Two\|Side=Main\|.*FrequencyHz=145600000'),
                ($queuedLog -match 'ARGS\|setPower\|Port=COM11\|Role=CAT-1\|HRI=\|Baud=38400\|StopBits=Two\|.*PowerWatts=10'))
            done = $queuedSequenceCompleted
            tail = (($queuedLog -split "`n" | Select-Object -Last 24) -join ';')
        }
        Write-Output ('CAT batch debug: ' + (ConvertTo-Json -InputObject $batchDebug -Compress -Depth 5))
    }
    Assert-RadioUi $queuedApplyConfirmed '统一 Apply 没有按顺序对三个冻结目标逐字段读回。'
    Assert-RadioUi ($queuedLog -match 'READBACK\|setMode\|C4FM-DN' -and $queuedLog -match 'READBACK\|setFrequency\|145600000' -and
        $queuedLog -match 'READBACK\|setPower\|10' -and (Get-TestTransientStatus) -match '逐项读取') `
        'fake CAT transport 没有记录三个字段的精确读回或统一状态没有给出逐步结果。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Set-UiRadioCatDraft -Field power -Value $null
    Set-UiRadioCatDraft -Field mode -Value $null
    Set-UiRadioCatDraft -Field frequency -Value $null
    [void](Update-UiRadioCatControls)

    # Disconnect cancels only CAT, latches against implicit reconnect, and an explicit Connect starts a new generation.
    $generationBeforeDisconnect = [int]$script:radioCatSessionGeneration
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    Assert-RadioUi ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell) 'CAT disconnect test did not start its in-flight query.'
    Assert-RadioUi (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11') 'CAT in-flight session did not expose its port to the HRI conflict check.'
    $script:radioCatEditDraft.power = 10
    Invoke-UiRadioCatAction -Operation setSettings
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setSettings' -and
        [string]$script:radioCatQueuedAction.mode -ceq [string](Get-UiRadioCatProperty -InputObject (Get-SettingsControl 'CatMainModeBox').SelectedItem -Name 'Tag') -and
        [int]$script:radioCatQueuedAction.power_watts -eq 10) 'CAT disconnect test did not freeze the complete settings action behind its in-flight query.'
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi (-not $script:radioCatSessionRequested -and -not $script:radioCatPollingActive -and
        $script:radioCatManualDisconnect -and $script:radioCatOperationCancelled -and $script:radioCatOperationStopAsync -and
        $null -eq $script:radioCatQueuedAction -and
        [int]$script:radioCatSessionGeneration -gt $generationBeforeDisconnect -and -not $script:supervisor) `
        'CAT断开没有撤销请求和单槽动作、取消worker、记录手动断开或隔离于核心生命周期。'
    Assert-RadioUi (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11') 'manual disconnect stopped protecting the CAT worker port before worker cleanup finished.'
    Assert-RadioUi (-not (Connect-UiRadioCatSession -Automatic) -and -not $script:radioCatSessionRequested) `
        '手动断开后auto reconnect仍能重新启动CAT。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and -not $script:radioCatSessionRequested -and
        [string]$script:radioCatSessionState -ceq 'disconnected' -and $script:radioCatResult -eq $null) `
        'CAT断开后仍有worker、旧授权结果或轮询请求。'
    Assert-RadioUi (-not (Test-UiRadioCatPortConflictWithHri -HriPortName 'COM11')) 'CAT port remained reserved after disconnect worker cleanup completed.'
    [void](Connect-UiRadioCatSession)
    Assert-RadioUi ($script:radioCatSessionRequested -and -not $script:radioCatManualDisconnect -and
        $script:radioCatOperationPowerShell -and [int]$script:radioCatOperationSessionGeneration -gt $generationBeforeDisconnect) `
        '用户明确再次连接没有解除本次应用手动断开锁存或开始新代CAT查询。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ((Get-UiRadioCatSessionState).connected -and (Get-UiRadioCatSessionState).polling) `
        '显式再次连接没有恢复CAT查询会话。'
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi (-not (Get-UiRadioCatSessionState).requested -and $script:radioCatManualDisconnect -and
        -not $script:radioCatOperationPowerShell) '后续单项 CAT 操作测试没有通过用户断开结束周期会话。'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (-not (Get-UiRadioCatSessionState).requested -and $script:radioCatResult -and
        [string]$script:radioCatResult.operation -ceq 'query') 'CAT断开后的单次显式读取没有独立完成。'

    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ callsign=''; gateway_id=''; source_id=''; master=''; master_port=''; color_code=1 }; tx_target=[pscustomobject]@{ destination_id=91; kind='group'; slot=2 }; rx_policy=$null; transmit_enabled=$true }
    $script:portableConfig.ui['r121_unknown_probe'] = [ordered]@{ keep='synthetic-unknown-field' }
    $scalarTagCombo = New-Object System.Windows.Controls.ComboBox
    $scalarTagItem = New-Object System.Windows.Controls.ComboBoxItem
    $scalarTagItem.Tag = 'synthetic-scalar-tag'
    [void]$scalarTagCombo.Items.Add($scalarTagItem)
    $scalarTagCombo.SelectedItem = $scalarTagItem
    $rawObjectCombo = New-Object System.Windows.Controls.ComboBox
    [void]$rawObjectCombo.Items.Add([pscustomobject]@{ Value='synthetic-raw-object-value' })
    $rawObjectCombo.SelectedIndex = 0
    Assert-RadioUi ((Get-UiComboValue -Combo $scalarTagCombo) -ceq 'synthetic-scalar-tag' -and
        (Get-UiComboValue -Combo $rawObjectCombo) -ceq 'synthetic-raw-object-value') `
        'ComboBox 字符串 Tag 或直接对象 Value 未读取为稳定值。'
    $syntheticHriPorts = @([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI'; IsHri=$true })
    $syntheticSerialOptions = Get-UiSerialOptions -AllPorts $syntheticHriPorts -HriPorts $syntheticHriPorts -SavedPort 'auto'
    $serialCombo = Get-UiControl 'SerialBox'
    Set-UiDeviceComboOptions -Combo $serialCombo -Options $syntheticSerialOptions.Items -SelectedValue 'auto'
    Assert-RadioUi ((Set-UiComboValue -Combo $serialCombo -Value 'auto') -and (Get-UiComboValue -Combo $serialCombo) -ceq 'auto') `
        '设备选项对象 Tag 未能将 auto 值回写到串口 ComboBox。'
    Assert-RadioUi ((Set-UiComboValue -Combo $serialCombo -Value 'COM5') -and (Get-UiComboValue -Combo $serialCombo) -ceq 'COM5') `
        '设备选项对象 Tag 未能将 COM5 值回写到串口 ComboBox。'
    $syntheticInputOptions = @((New-UiDeviceOption -Label 'Synthetic input' -Value 'synthetic-input-1' -IsAvailable $true -Kind 'input'))
    $syntheticOutputOptions = @((New-UiDeviceOption -Label 'Synthetic output' -Value 'synthetic-output-1' -IsAvailable $true -Kind 'output'))
    Set-UiDeviceComboOptions -Combo (Get-UiControl 'WaveInEndpointBox') -Options $syntheticInputOptions -SelectedValue 'synthetic-input-1'
    Set-UiDeviceComboOptions -Combo (Get-UiControl 'WaveOutEndpointBox') -Options $syntheticOutputOptions -SelectedValue 'synthetic-output-1'
    Assert-RadioUi ((Get-UiComboValue -Combo (Get-UiControl 'WaveInEndpointBox')) -ceq 'synthetic-input-1' -and
        (Get-UiComboValue -Combo (Get-UiControl 'WaveOutEndpointBox')) -ceq 'synthetic-output-1') `
        '音频设备选项对象 Tag 未能读取稳定值。'
    $hriSaveValue = Get-UiComboValue -Combo (Get-UiControl 'SerialBox')
    $reproducedSaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedDeviceValues = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ($reproducedSaveSucceeded -and $hriSaveValue -ceq 'COM5' -and
        $savedDeviceValues.devices.hri_port -ceq 'COM5' -and
        $savedDeviceValues.devices.wave_in_endpoint_id -ceq 'synthetic-input-1' -and
        $savedDeviceValues.devices.wave_out_endpoint_id -ceq 'synthetic-output-1' -and
        $savedDeviceValues.ui.r121_unknown_probe.keep -ceq 'synthetic-unknown-field') `
        ('R121 fake 配置没有保存稳定设备值或未知字段：success={0}, hri={1}, in={2}, out={3}, unknown={4}' -f `
            $reproducedSaveSucceeded,$savedDeviceValues.devices.hri_port,$savedDeviceValues.devices.wave_in_endpoint_id,
            $savedDeviceValues.devices.wave_out_endpoint_id,$savedDeviceValues.ui.r121_unknown_probe.keep)
    $script:portableConfig=Get-WirexPortableConfig -Path $script:portableConfigPath
    [void](Import-UiPortableConfig)
    Apply-UiPortableConfigToControls
    Assert-RadioUi ((Get-UiComboValue -Combo (Get-UiControl 'SerialBox')) -ceq 'COM5' -and
        (Get-UiComboValue -Combo (Get-UiControl 'WaveInEndpointBox')) -ceq 'synthetic-input-1' -and
        (Get-UiComboValue -Combo (Get-UiControl 'WaveOutEndpointBox')) -ceq 'synthetic-output-1' -and
        $script:storedProfile.devices.serial_port -ceq 'COM5') `
        '自动启动重新加载已保存配置时，没有沿用与手动保存相同的COM和音频稳定值。'
    $initialSaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedPreference = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ($initialSaveSucceeded -and [int]$savedPreference.devices.desired_power_watts -eq 10) `
        ('保存设置没有成功，或没有保留先前明确应用并确认的10 W目标。 saved={0}, power={1}, path={2}' -f $initialSaveSucceeded,$savedPreference.devices.desired_power_watts,$script:portableConfigPath)
    $masterBox = Get-UiControl 'MasterBox'
    $apiBox = Get-UiControl 'BmApiKeyBox'
    $savedMaster = [string]$savedPreference.connection.master
    $savedApiKey = [string]$savedPreference.connection.api_key
    $storedProfileBeforeRejectedSave = $script:storedProfile
    $serverSelectionBeforeRejectedSave = [string]$script:bmServerSelectionPreferenceId
    $masterBox.Text = 'invalid host name'
    $apiSentinel = 'R121_FAKE_API_SECRET_MUST_NOT_APPEAR'
    $apiBox.Password = $apiSentinel
    $invalidSaveSucceeded = [bool](Save-SettingsFromWindow)
    $saveErrorText = Get-TestTransientStatus
    $savedAfterRejectedSave = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi (-not $invalidSaveSucceeded -and $saveErrorText -match 'BM 服务器或认证字段格式无效' -and
        $saveErrorText -cnotlike ('*' + $apiSentinel + '*') -and
        $savedAfterRejectedSave.connection.master -ceq $savedMaster -and
        $savedAfterRejectedSave.connection.api_key -ceq $savedApiKey -and
        $script:portableConfig.connection.master -ceq $savedMaster -and
        $script:portableConfig.connection.api_key -ceq $savedApiKey -and
        [object]::ReferenceEquals($script:storedProfile,$storedProfileBeforeRejectedSave) -and
        [string]$script:bmServerSelectionPreferenceId -ceq $serverSelectionBeforeRejectedSave) `
        '无效的BM主机没有显示不含密钥的临时安全错误，或失败保存改动了磁盘/内存设置。'
    $masterBox.Text = $savedMaster
    $apiBox.Password = $savedApiKey
    $recoveredSaveSucceeded = [bool](Save-SettingsFromWindow)
    $recoveredConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ($recoveredSaveSucceeded -and $recoveredConfig.connection.master -ceq $savedMaster) '修正BM主机后设置未能保存到统一配置。'
    Assert-RadioUi ([object]::ReferenceEquals($script:mainWindow,$script:testRootMainWindow) -and -not $script:testRootMainWindow.Closed) `
        '保存统一配置不应关闭主窗口或改变其所有权。'

    # A real WPF ComboBox selection creates a write draft without changing the saved preference.
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 5) 'FieldHead 5 W预设没有通过真实ComboBox选择。'
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 5 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 10 -and -not $script:radioCatPowerNeedsUserChoice) `
        'MainWindow功率Combo选择5 W后应形成独立草稿并保留先前确认的10 W偏好。'
    Assert-RadioUi ((Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) '合法的5 W草稿形成后应用按钮应可用。'
    Set-UiRadioCatDraft -Field power -Value $null
    [void](Update-UiRadioCatControls)

    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{
        serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic Enhanced'; CatMatchRank=100; IsHri=$false },[pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI'; CatMatchRank=0; IsHri=$true })
        hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' })
        wave_inputs=@(); wave_outputs=@()
    }
    Set-UiRadioCatDeviceControls
    $powerBox = Get-SettingsControl 'CatPowerBox'
    Assert-RadioUi ((Get-UiRadioCatSelectedPort) -ceq 'COM11') ('重开设置窗后 CAT 端口选择无效：port={0}, discovery={1}, pref={2}' -f (Get-UiRadioCatSelectedPort),$script:deviceDiscoveryState,$script:radioControlPreferences.cat_port)
    $env:WIREX_R116_UI_CAT_SAMPLE = 'matched'
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    $env:WIREX_R116_UI_CAT_POWER = '5'
    $env:WIREX_R116_UI_CAT_FORCE_POWER = '5'
    $modeControl.SelectedItem = @($modeControl.Items | Where-Object { [string]$_.Tag -ceq 'C4FM-DN' })[0]
    Assert-RadioUi (Set-TestRadioCatFrequencyText -Text '145.600') '重开设置窗后频率PART文本框没有接受用户输入。'
    $setPowerBeginsBeforeRefresh = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ([int]$script:radioControlPreferences.desired_power_watts -eq 10 -and
        $null -eq $script:radioCatEditDraft.power -and -not $script:radioCatPowerNeedsUserChoice -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $setPowerBeginsBeforeRefresh) '重开后 FieldHead 首读应保留偏好且不自动写入功率。'
    Remove-Item Env:\WIREX_R116_UI_CAT_FORCE_POWER -ErrorAction SilentlyContinue

    # Exercise the actual bound WPF SelectionChanged and Apply Button handlers.
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 5) 'FieldHead当前读值5 W没有形成真实功率选择。'
    Assert-RadioUi ($null -ne $script:radioCatEditDraft.power -and [int]$script:radioCatEditDraft.power -eq 5 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 10 -and -not $script:radioCatPowerNeedsUserChoice) `
        ('真实WPF功率选择没有创建5 W草稿或保留已确认偏好。 draft={0}, pref={1}, needsChoice={2}, selected={3}' -f `
            [string]$script:radioCatEditDraft.power,[int]$script:radioControlPreferences.desired_power_watts,
            [bool]$script:radioCatPowerNeedsUserChoice,(Get-UiRadioCatPowerSelection))
    $setPowerButton = Get-SettingsControl 'ApplyCatSettingsButton'
    Assert-RadioUi $setPowerButton.IsEnabled '用户选择5 W、并有明确模式/频率目标后统一Apply应启用。'
    $script:lastStatusUtc = [DateTime]::UtcNow
    $explicitSetPowerBeginsBefore = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $clickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$setPowerButton)
    $setPowerButton.RaiseEvent($clickArgs)
    $setPowerSequenceReady = Complete-TestCatActionSequence -TimeoutMs 6000
    $explicitSetPowerLog = (Get-TestRadioCatLog)
    Assert-RadioUi ($setPowerSequenceReady -and
        ([regex]::Matches($explicitSetPowerLog,'BEGIN\|setPower')).Count -eq $explicitSetPowerBeginsBefore -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and [int]$script:radioCatObserved.power.value.watts -eq 5 -and
        $null -eq $script:radioCatEditDraft.power -and (Get-TestTransientStatus) -match '没有发送设置帧') `
        ('当前已是5 W时，统一Apply应通过query确认并跳过功率写入。 status={0}, operation={1}, result={2}, cancelled={3}, cleanup={4}, begin={5}/{6}' -f `
            [string]$script:radioCatLastOperationStatus,[string]$script:radioCatOperationKind,
            [string]$script:radioCatResult.status,[bool]$script:radioCatOperationCancelled,
            [string]$script:radioCatResult.cleanup_status,([regex]::Matches($explicitSetPowerLog,'BEGIN\|setPower')).Count,$explicitSetPowerBeginsBefore)

    # A closed, identity-confirmed rejection can refresh path limits and current PC readback without becoming success.
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ((@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '50' })[0].IsEnabled)) 'SPA-1 readback没有刷新功率选项上限。'
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    Start-UiRadioCatOperation -Operation setPower -PowerWatts 25
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($script:radioCatLastOperationStatus -ceq 'rejected' -and [string]$script:radioCatResult.status -ceq 'rejected') `
        ('功率设置拒绝被错误显示为成功。 last={0}, result={1}, observedPower={2}, rawError={3}, rawCleanup={4}, readbackValid={5}, raw={6}' -f $script:radioCatLastOperationStatus,
            $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
            $(if ($script:radioCatObserved) { [string]$script:radioCatObserved.power.value.watts } else { '<null>' }),
            [string]$script:radioCatRejectedPowerReadbackInput.error_code,[string]$script:radioCatRejectedPowerReadbackInput.cleanup_status,
            $script:radioCatRejectedPowerReadbackValid,
            (ConvertTo-Json -InputObject $script:radioCatRejectedPowerReadbackInput -Depth 5 -Compress))
    Assert-RadioUi (-not (@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '15' })[0].IsEnabled) -and
        -not (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) '拒绝结果没有刷新FieldHead上限，或仍允许继续写入。'
    Assert-RadioUi (([string](Get-SettingsControl 'CatObservedPowerText').Text) -match '5 W') '拒绝结果中的 PC 当前读值没有显示。'
    Assert-RadioUi ($script:radioCatResult.cleanup_status -ceq 'closed' -and $script:radioCatResult.source -ceq 'CAT test transport' -and
        $script:radioCatResult.port_name -ceq 'COM11' -and $script:radioCatObserved.radio_id.value -ceq '0840' -and
        $script:radioCatObserved.power.value.path -ceq 'FieldHead' -and $script:radioCatObserved.power.value.watts -eq 5 -and
        $script:radioCatResult.capabilities.set_power.maximum_watts -eq 10) 'rejected 结果应保留 closed/ID0840/FieldHead 的新鲜 PC 读值及 10 W 上限。'
    $env:WIREX_R116_UI_CAT_BAD_ID = '1'
    Start-UiRadioCatOperation -Operation setPower -PowerWatts 25
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($null -eq $script:radioCatResult -and -not (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) '身份无效时，UI仍保留旧功率能力并允许继续操作。'
    Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue

    # A dirty 40 W preference from SPA-1 remains 40 W when FieldHead lowers the capability.
    $script:portableConfig.devices.cat_port = 'COM11'
    $script:portableConfig.devices.cat_baud_rate = 38400
    $script:portableConfig.devices.cat_stop_bits = 'Two'
    $script:portableConfig.devices.desired_power_watts = 25
    $script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
    $script:radioControlPreferences = [pscustomobject][ordered]@{
        schema_version=1; cat_port=[string]$script:portableConfig.devices.cat_port
        baud_rate=[int]$script:portableConfig.devices.cat_baud_rate; stop_bits='Two'
        desired_power_watts=[int]$script:portableConfig.devices.desired_power_watts
    }
    $script:radioCatObserved = $null
    $script:radioCatResult = $null
    $script:radioCatEditDraft.power = $null
    $script:radioCatPowerPreferenceDirty = $false
    Set-UiRadioCatPowerChoices -Maximum 50
    Set-UiRadioCatDeviceControls
    Assert-RadioUi ((Get-UiRadioCatPowerSelection) -eq 25 -and [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and -not $script:radioCatPowerPreferenceDirty) '第二种偏好用例没有从 25 W 干净回填。'
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    $env:WIREX_R116_UI_CAT_FORCE_POWER = '40'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '40' }).Count -eq 1 -and
        (Get-UiRadioCatPowerSelection) -eq 40) 'CAT讀到合法非預設SPA-1 40 W後沒有添加当前值项。'
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 40) '读到的SPA-1 40 W当前值项不能被用户选择。'
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 40 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and -not $script:radioCatPowerPreferenceDirty) '用户从 SPA-1 范围明确选 40 W 后应只创建草稿，不提前改写已保存偏好。'
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ((@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '50' })[0].IsEnabled) -and [int]$script:radioCatEditDraft.power -eq 40 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 25) 'SPA-1 读回应保留用户 40 W 草稿和独立 25 W 偏好。'
    $env:WIREX_R116_UI_CAT_PATH = 'FieldHead'
    $env:WIREX_R116_UI_CAT_FORCE_POWER = '5'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (-not (@($powerBox.Items | Where-Object { [string]$_.Tag -ceq '40' })[0].IsEnabled) -and [int]$script:radioControlPreferences.desired_power_watts -eq 25 -and
        [int]$script:radioCatEditDraft.power -eq 40 -and $script:radioCatPowerNeedsUserChoice -and
        -not (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) 'FieldHead cap 降低后应保留 dirty 40 W 并要求重新选择、禁用应用。'
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 10) 'FieldHead拒绝40 W草稿后，用户不能重新选择合法10 W。'
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 10 -and -not $script:radioCatPowerNeedsUserChoice) '用户重新选10 W后没有替换过期40 W草稿。'
    Remove-Item Env:\WIREX_R116_UI_CAT_FORCE_POWER -ErrorAction SilentlyContinue
    $savedPowerWriteCount = ([regex]::Matches((Get-TestRadioCatLog),'ARGS\|setPower')).Count
    $script:profileEditable = $false
    $script:profileWriteAllowed = $false
    $script:storedProfile = [pscustomobject]@{ connection=[pscustomobject]@{ callsign=''; gateway_id=''; source_id=''; master=''; master_port=''; color_code=1 }; tx_target=[pscustomobject]@{ destination_id=91; kind='group'; slot=2 }; rx_policy=$null; transmit_enabled=$true }
    $dirtySaveSucceeded = [bool](Save-SettingsFromWindow)
    $savedDirtyPreference = Get-WirexPortableConfig -Path $script:portableConfigPath
    Assert-RadioUi ([int]$savedDirtyPreference.devices.desired_power_watts -eq 25 -and
        ([regex]::Matches((Get-TestRadioCatLog),'ARGS\|setPower')).Count -eq $savedPowerWriteCount -and
        $dirtySaveSucceeded) ('FieldHead 保存未成功或把未应用草稿写进偏好/发起CAT操作：saved={0}, args={1}/{2}, pref={3}, draft={4}, selected={5}, needsChoice={6}' -f $savedDirtyPreference.devices.desired_power_watts,([regex]::Matches((Get-TestRadioCatLog),'ARGS\|setPower')).Count,$savedPowerWriteCount,$script:radioControlPreferences.desired_power_watts,$script:radioCatEditDraft.power,(Get-UiRadioCatPowerSelection),$script:radioCatPowerNeedsUserChoice)
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls

    function Set-R122TestCatTarget {
        param([string]$Mode,[string]$FrequencyMHz,[int]$PowerWatts)
        $box = Get-SettingsControl 'CatMainModeBox'
        $box.SelectedItem = @($box.Items | Where-Object { [string]$_.Tag -ceq $Mode })[0]
        if (-not (Set-TestRadioCatFrequencyText -Text $FrequencyMHz)) { throw 'Editable frequency PART_TextBox did not accept the requested test text.' }
        if (-not (Set-TestRadioCatPowerSelection -Watts $PowerWatts)) { throw "功率Combo没有可用的 $PowerWatts W 当前项或预设项。" }
        Update-UiRadioCatControls
    }

    # One click synchronizes three changed fields while a live HRI supervisor remains untouched.
    $env:WIREX_R116_UI_CAT_PATH = 'Spa1'
    $env:WIREX_R116_UI_CAT_POWER = '25'
    $env:WIREX_R116_UI_CAT_FORCE_POWER = '25'
    $env:WIREX_R116_UI_CAT_SAMPLE = '2'
    Set-R122TestCatTarget -Mode 'C4FM-DN' -FrequencyMHz '145.600' -PowerWatts 10
    $liveApplySupervisor = New-TestRadioSupervisor
    $script:supervisor = $liveApplySupervisor
    $beforeLiveMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $beforeLiveFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforeLivePower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    Assert-RadioUi $settingsButton.IsEnabled '空闲且有三项有效目标时，统一 Apply 应启用。'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setSettings' -and
        [string]$script:radioCatQueuedAction.mode -ceq 'C4FM-DN' -and [long]$script:radioCatQueuedAction.frequency_hz -eq 145600000 -and
        [int]$script:radioCatQueuedAction.power_watts -eq 10 -and $liveApplySupervisor.StopCallCount -eq 0) `
        '统一 Apply 没有冻结模式/频率/功率，或请求了 HRI 停止。'
    Assert-RadioUi (Complete-TestCatActionSequence -TimeoutMs 7000) 'live-core CAT 单次应用的 fake worker 没有逐步完成。'
    $liveApplyLog = Get-TestRadioCatLog
    Assert-RadioUi ($liveApplySupervisor.StopCallCount -eq 0 -and -not $liveApplySupervisor.HasExited -and
        [object]::ReferenceEquals($script:supervisor,$liveApplySupervisor) -and
        ([regex]::Matches($liveApplyLog,'BEGIN\|setMode')).Count -eq ($beforeLiveMode + 1) -and
        ([regex]::Matches($liveApplyLog,'BEGIN\|setFrequency')).Count -eq ($beforeLiveFrequency + 1) -and
        ([regex]::Matches($liveApplyLog,'BEGIN\|setPower')).Count -eq ($beforeLivePower + 1) -and
        $script:radioCatObserved.main_mode.value.mode -ceq 'C4FM-DN' -and
        [long]$script:radioCatObserved.main_frequency_hz.value -eq 145600000 -and
        [int]$script:radioCatObserved.power.value.watts -eq 10) `
        'live-core Apply 未逐字段读回三个冻结目标，或调用了 StopAsync。'
    Assert-RadioUi ($liveApplyLog -match 'READBACK\|setMode\|C4FM-DN' -and
        $liveApplyLog -match 'READBACK\|setFrequency\|145600000' -and $liveApplyLog -match 'READBACK\|setPower\|10') `
        'fake CAT worker 没有记录模式、频率、功率的实际读回值。'
    Assert-RadioUi ((Get-TestTransientStatus) -match '逐项读取' -and
        (Get-TestTransientStatus) -match '已读回目标值') '统一状态没有逐字段报告读回确认。'
    Remove-Item Env:\WIREX_R116_UI_CAT_FORCE_POWER -ErrorAction SilentlyContinue
    $liveApplySupervisor.HasExited = $true
    $liveApplySupervisor.Dispose()
    $script:supervisor = $null

    # CAT-only is available; fields already equal to the fresh query are read and skipped without writes.
    $env:WIREX_R116_UI_CAT_SAMPLE = 'matched'
    $env:WIREX_R116_UI_CAT_POWER = '10'
    Set-R122TestCatTarget -Mode 'C4FM-DN' -FrequencyMHz '145.600' -PowerWatts 10
    $beforeUnchangedMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $beforeUnchangedFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforeUnchangedPower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi (Complete-TestCatActionSequence -TimeoutMs 5000) 'CAT-only unchanged-settings query did not complete.'
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $beforeUnchangedMode -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count -eq $beforeUnchangedFrequency -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $beforeUnchangedPower -and
        (Get-TestTransientStatus) -match '没有发送设置帧' -and -not $script:supervisor) `
        'CAT-only Apply 没有读取当前设置并跳过三个相同目标。'
    Set-R122TestCatTarget -Mode 'C4FM-DN' -FrequencyMHz '145.600' -PowerWatts 15
    $beforePowerOnlyMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $beforePowerOnlyFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforePowerOnlyPower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi (Complete-TestCatActionSequence -TimeoutMs 5000) 'power-only changed CAT batch did not complete.'
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $beforePowerOnlyMode -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count -eq $beforePowerOnlyFrequency -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq ($beforePowerOnlyPower + 1) -and
        [int]$script:radioCatObserved.power.value.watts -eq 15) `
        'MAIN模式和频率一致时应跳过两项写入，继续单独设置并读回功率。'
    $savedSettingsApplyState = $script:radioCatSettingsApply
    $script:radioCatSettingsApply = [pscustomobject]@{ steps=@() }
    $batchSessionState = Get-UiRadioCatSessionState
    Assert-RadioUi $batchSessionState.user_action_busy `
        'CAT 会话状态没有把正在逐项处理的统一 Apply 报告为用户动作忙。'
    $script:radioCatSettingsApply = $savedSettingsApplyState

    # Failure at frequency preserves confirmed mode, stops before power, and reports no rollback.
    $env:WIREX_R116_UI_CAT_SAMPLE = '2'
    $env:WIREX_R116_UI_CAT_POWER = '25'
    $env:WIREX_R116_UI_CAT_FAIL = 'setFrequency'
    Set-R122TestCatTarget -Mode 'C4FM-DN' -FrequencyMHz '145.600' -PowerWatts 10
    $beforeFailureMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $beforeFailureFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforeFailurePower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi (Complete-TestCatActionSequence -TimeoutMs 6000) 'frequency readback mismatch did not close its fake worker.'
    $failureNotice = (Get-TestTransientStatus)
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq ($beforeFailureMode + 1) -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count -eq ($beforeFailureFrequency + 1) -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $beforeFailurePower -and
        $failureNotice -match 'MAIN 模式：已读回目标值' -and $failureNotice -match 'MAIN 频率：未获确认' -and
        $failureNotice -match '功率：未执行' -and $failureNotice -match '没有自动回滚') `
        ('频率失败后没有保留模式成功、停止功率步骤并报告部分结果：{0}' -f $failureNotice)
    Remove-Item Env:\WIREX_R116_UI_CAT_FAIL -ErrorAction SilentlyContinue

    # A stale core snapshot rejects the Apply before CAT writes begin.
    $env:WIREX_R116_UI_CAT_SAMPLE = '2'
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Set-R122TestCatTarget -Mode 'C4FM-DN' -FrequencyMHz '145.600' -PowerWatts 10
    $staleApplySupervisor = New-TestRadioSupervisor
    $script:supervisor = $staleApplySupervisor
    $script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Update-UiRadioCatControls
    $staleApplyLog = Get-TestRadioCatLog
    Assert-RadioUi (-not (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled -and
        -not $script:radioCatQueuedAction -and $staleApplySupervisor.StopCallCount -eq 0 -and
        (Get-TestRadioCatLog) -ceq $staleApplyLog) '核心状态超过3秒后，统一 Apply 未被禁用或启动CAT写入。'
    $staleApplySupervisor.HasExited = $true
    $staleApplySupervisor.Dispose()
    $script:supervisor = $null
    $script:lastStatusUtc = [DateTime]::UtcNow
    Update-UiRadioCatControls

    # If the status becomes stale during mode, the UI must not start frequency or power.
    $staleMidSupervisor = New-TestRadioSupervisor
    $script:supervisor = $staleMidSupervisor
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$false; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
        hri_serial_open=$true; hri_ready=$true
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $env:WIREX_R116_UI_CAT_DELAY = 'setMode'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '600'
    $beforeStaleMidMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $beforeStaleMidFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforeStaleMidPower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi ($script:radioCatQueuedAction -and $script:radioCatOperationKind -ceq 'query') `
        'stale-status test did not queue Apply behind a fresh query.'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi ($script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'setMode' -and
        $script:radioCatSettingsApply) `
        'fresh query did not begin the first changed field before the stale-status injection.'
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($beforeStaleMidMode + 1) -TimeoutMs 1000) `
        'stale-status test did not observe its current mode worker before aging the core status.'
    $script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
    [void](Complete-TestCatActionSequence -TimeoutMs 5000)
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count -eq $beforeStaleMidFrequency -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $beforeStaleMidPower -and
        $staleMidSupervisor.StopCallCount -eq 0 -and -not $script:radioCatSettingsApply) `
        '核心状态过期后仍执行了频率或功率写入。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    $staleMidSupervisor.HasExited = $true
    $staleMidSupervisor.Dispose()
    $script:supervisor = $null
    $script:lastStatusUtc = [DateTime]::UtcNow

    # CAT disconnect during the first field cancels the generation-bound rest of the batch without stopping HRI.
    $disconnectBatchSupervisor = New-TestRadioSupervisor
    $script:supervisor = $disconnectBatchSupervisor
    $env:WIREX_R116_UI_CAT_DELAY = 'setMode'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    $beforeDisconnectFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforeDisconnectPower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $generationBeforeBatchDisconnect = [int]$script:radioCatSessionGeneration
    $beforeDisconnectMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi ($script:radioCatQueuedAction -and $script:radioCatOperationKind -ceq 'query') `
        'CAT disconnect batch was not queued behind its fresh query.'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setMode' -MinimumCount ($beforeDisconnectMode + 1) -TimeoutMs 1000) `
        'CAT disconnect test did not observe its current mode worker.'
    Assert-RadioUi ($script:radioCatOperationPowerShell -and $script:radioCatOperationKind -ceq 'setMode' -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq ($beforeDisconnectMode + 1)) `
        ('CAT disconnect test did not start its current mode worker. op={0},apply={1},notice={2},target={3}/{4}/{5}, observed={6}/{7}/{8}, idle={9}, count={10}/{11}' -f `
            [string]$script:radioCatOperationKind,[bool]$script:radioCatSettingsApply,(Get-TestTransientStatus),
            [string](Get-SettingsControl 'CatMainModeBox').SelectedItem.Tag,[string](Get-SettingsControl 'CatMainFrequencyMHzBox').Text,
            (Get-UiRadioCatPowerSelection),[string]$script:radioCatObserved.main_mode.value.mode,
            [long]$script:radioCatObserved.main_frequency_hz.value,[int]$script:radioCatObserved.power.value.watts,
            (Test-UiRadioCatRunIdle -RequireFreshStatus),([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count,($beforeDisconnectMode + 1))
    [void](Disconnect-UiRadioCatSession -Reason user_disconnect)
    Assert-RadioUi (-not $script:radioCatSettingsApply -and -not $script:radioCatQueuedAction -and
        [int]$script:radioCatSessionGeneration -gt $generationBeforeBatchDisconnect -and
        $script:radioCatOperationCancelled -and $disconnectBatchSupervisor.StopCallCount -eq 0 -and
        [object]::ReferenceEquals($script:supervisor,$disconnectBatchSupervisor)) `
        'CAT disconnect没有撤销批次并取消当前worker，或停止了仍运行的HRI。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count -eq $beforeDisconnectFrequency -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $beforeDisconnectPower -and
        -not $script:radioCatSettingsApply) 'CAT disconnect后迟到结果仍启动频率或功率操作。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    $disconnectBatchSupervisor.HasExited = $true
    $disconnectBatchSupervisor.Dispose()
    $script:supervisor = $null

    # Stop and Exit revokes an Apply waiting on its fresh query and closes only after the core exits.
    $exitBatchSupervisor = New-TestRadioSupervisor
    $script:supervisor = $exitBatchSupervisor
    Assert-RadioUi ([bool](Connect-UiRadioCatSession)) 'exit cancellation test could not explicitly reconnect CAT after the prior disconnect test.'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Set-R122TestCatTarget -Mode 'C4FM-DN' -FrequencyMHz '145.600' -PowerWatts 10
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    $beforeExitMode = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $beforeExitFrequency = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count
    $beforeExitPower = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $settingsButton = Get-SettingsControl 'ApplyCatSettingsButton'
    $settingsButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$settingsButton)))
    Assert-RadioUi ($script:radioCatQueuedAction -and $script:radioCatOperationPowerShell -and
        [string]$script:radioCatOperationKind -ceq 'query') `
        ('exit cancellation test did not queue Apply behind its query. queued={0}, op={1}, enabled={2}, session={3}, idle={4}, notice={5}, targets={6}/{7}/{8}' -f `
            [string]$script:radioCatQueuedAction.operation,[string]$script:radioCatOperationKind,[bool]$settingsButton.IsEnabled,
            (Get-UiRadioCatSessionState).state,(Test-UiRadioCatRunIdle -RequireFreshStatus),(Get-TestTransientStatus),
            [string](Get-SettingsControl 'CatMainModeBox').SelectedItem.Tag,[string](Get-SettingsControl 'CatMainFrequencyMHzBox').Text,
            (Get-UiRadioCatPowerSelection))
    $script:mainWindow = New-TestMainWindow
    Request-StopAndExit
    Assert-RadioUi (-not $script:radioCatQueuedAction -and -not $script:radioCatSettingsApply -and
        $script:radioCatSessionShutdown -and $script:closingAfterStop -and $exitBatchSupervisor.StopCallCount -eq 1) `
        'Stop and Exit 没有撤销 CAT Apply 并请求正常的核心停止。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $beforeExitMode -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setFrequency')).Count -eq $beforeExitFrequency -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -eq $beforeExitPower) `
        '退出后CAT query迟到结果仍启动批次写入。'
    [void]$exitBatchSupervisor.StopSource.TrySetResult(0)
    $exitBatchSupervisor.HasExited = $true
    $script:stopTask = $exitBatchSupervisor.StopSource.Task
    Assert-RadioUi (Complete-TestBridgeStop) '退出后的核心停止没有完成。'
    Assert-RadioUi ($script:mainWindow.Closed -and $exitBatchSupervisor.Disposed) '退出后没有在核心关闭时关窗并释放 supervisor。'
    Restore-TestMainWindow
    $script:radioCatSessionShutdown = $false
    $script:radioCatSessionRequested = $false
    $script:radioCatSessionConnected = $false
    $script:radioCatPollingActive = $false
    $script:radioCatSessionState = 'disconnected'
    $script:radioCatSessionError = ''
    $script:radioCatQueuedAction = $null
    $script:radioCatSettingsApply = $null
    Update-UiRadioCatSessionControls
    # Closing the routing modal must not cancel a CAT worker owned by MainWindow.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '350'
    $queryCountBeforeCancel = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    Start-UiRadioCatOperation -Operation query
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeCancel + 1) -TimeoutMs 1500) '设置窗取消测试没有启动 fake query worker。'
    Start-Sleep -Milliseconds 100
    $cancelTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Cancel-SettingsWindow
    Assert-RadioUi ($script:radioCatOperationPowerShell -and -not $script:radioCatOperationCancelled -and
        [object]::ReferenceEquals($script:radioCatOperationOwnerWindow,$script:testRootMainWindow) -and $null -eq $script:settingsWindow) `
        '关闭路由弹窗取消了归 MainWindow 所有的 CAT 查询。'
    $closedSettingsWindow = $script:testClosedSettingsWindow
    $operationPowerShellBeforeReopen = $script:radioCatOperationPowerShell
    $reopenedSettingsWindow = Initialize-SettingsWindow
    Assert-RadioUi ($reopenedSettingsWindow -and -not [object]::ReferenceEquals($reopenedSettingsWindow,$closedSettingsWindow) -and
        [object]::ReferenceEquals($script:settingsWindow,$reopenedSettingsWindow) -and
        [object]::ReferenceEquals($script:radioCatOperationPowerShell,$operationPowerShellBeforeReopen) -and
        -not $script:radioCatOperationCancelled) '关闭并重开配置窗替换了Window实例或取消了由主窗口持有的CAT任务。'
    $cleanupElapsed = Complete-TestCatRunspace -TimeoutMs 2800
    $cancelTimer.Stop()
    Assert-RadioUi ($cleanupElapsed -lt 2800 -and $null -eq $script:radioCatOperationPowerShell -and
        [object]::ReferenceEquals($script:settingsWindow,$reopenedSettingsWindow)) '关闭并重开配置窗后，CAT runspace 没有在 fake worker 完成后及时清理或新窗口丢失。'
    $cancelLog = (Get-TestRadioCatLog)
    Assert-RadioUi (([regex]::Matches($cancelLog,'BEGIN\|query')).Count -gt $queryCountBeforeCancel -and $cancelLog -match 'CLEANUP\|query' -and
        $script:radioCatLastOperationStatus -ceq 'confirmed' -and $script:radioCatResult -and $script:radioCatObserved) `
        '路由弹窗关闭后应完成 CAT fake worker，并接受仍属 MainWindow 的查询结果。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue

    # Hitting the CAT deadline also requests cancellation and discards any eventual worker result.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $queryCountBeforeDeadline = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|query')).Count
    $observedBeforeDeadline = $script:radioCatObserved
    Start-UiRadioCatOperation -Operation query
    Assert-RadioUi (Wait-TestRadioCatLogCount -Pattern 'BEGIN\|query' -MinimumCount ($queryCountBeforeDeadline + 1) -TimeoutMs 1500) '期限测试没有启动 fake query worker。'
    Start-Sleep -Milliseconds 100
    $script:radioCatOperationStartedUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Assert-RadioUi (-not (Complete-UiRadioCatOperation) -and $script:radioCatOperationCancelled -and $script:radioCatOperationStopAsync) 'CAT 期限到达后没有要求停止 fake worker。'
    [void](Complete-TestCatRunspace -TimeoutMs 2800)
    $deadlineLog = (Get-TestRadioCatLog)
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and $script:radioCatLastOperationStatus -ceq 'unknown' -and
        $null -eq $script:radioCatResult -and [object]::ReferenceEquals($script:radioCatObserved,$observedBeforeDeadline) -and
        ([regex]::Matches($deadlineLog,'BEGIN\|query')).Count -gt $queryCountBeforeDeadline -and $deadlineLog -match 'CLEANUP\|query') ('CAT 期限取消后仍保留结果或未清理 fake worker。 powerShell={0}, status={1}, result={2}, observed={3}, canceled={4}, cleanup={5}, queryCount={6}/{7}' -f `
            [bool]$script:radioCatOperationPowerShell,$script:radioCatLastOperationStatus,
            $(if ($script:radioCatResult) { [string]$script:radioCatResult.status } else { '<null>' }),
            [bool]$script:radioCatObserved,$script:radioCatOperationCancelled,($deadlineLog -match 'CLEANUP\|query'),
            ([regex]::Matches($deadlineLog,'BEGIN\|query')).Count,$queryCountBeforeDeadline)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue

    # Expired core idle status is cancelled by the timer's stale-display path, even with no new status record.
    [void](Initialize-SettingsWindow)
    $script:deviceDiscoveryState = 'ready'
    $script:deviceCatalog = [pscustomobject]@{ serial_ports=@([pscustomobject]@{ PortName='COM11'; FriendlyName='Synthetic CAT'; CatMatchRank=100; IsHri=$false }); hri_ports=@([pscustomobject]@{ PortName='COM5'; FriendlyName='Synthetic HRI' }); wave_inputs=@(); wave_outputs=@() }
    Set-UiRadioCatDeviceControls
    Start-UiRadioCatOperation -Operation query
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    $testSupervisor = New-TestRadioSupervisor
    $script:supervisor = $testSupervisor
    $script:latestStatus = [pscustomobject]@{
        ptt_gate_ready=$false; ptt_gate_tx_active=$false; ptt_last_state='released'; current_call_valid=$false
        receive_media_state='idle'; rx_queue_bursts=[uint64]0; rx_queue_playback_frames=[uint64]0
        rx_queue_unconfirmed_playback_frames=[uint64]0; rx_buffered_receive_frames=[uint64]0
        hri_serial_open=$true; hri_ready=$true
        bm_state='stopped'; bm_connection=[pscustomobject]@{requested_enabled=$false;revision=[uint64]0;transport_open=$false}
    }
    $script:lastStatusUtc = [DateTime]::UtcNow
    $pausedCoreIdleStatus=$script:latestStatus
    Assert-RadioUi ((Test-UiRadioCatRunIdle -RequireFreshStatus) -and
        (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled -and
        (Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'tx_state').value -eq 0) `
        'HRI ready 且 BM 暂停时，released/空闲状态与新鲜 CAT TX=0 应允许电台功率操作。'
    $script:latestStatus=$pausedCoreIdleStatus.PSObject.Copy(); $script:latestStatus.ptt_last_state='pressed'
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) 'BM paused 状态不能绕过明确的 PTT pressed 状态。'
    $script:latestStatus=$pausedCoreIdleStatus.PSObject.Copy(); $script:latestStatus.ptt_gate_tx_active=$true
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) 'BM paused 状态不能绕过 Native 报告的活动发射状态。'
    $script:latestStatus=$pausedCoreIdleStatus.PSObject.Copy(); $script:latestStatus.rx_queue_playback_frames=[uint64]1
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) 'BM paused 状态不能绕过未清空的接收媒体队列。'
    $script:latestStatus=$pausedCoreIdleStatus
    $powerBox = Get-SettingsControl 'CatPowerBox'
    Assert-RadioUi (Set-TestRadioCatPowerSelection -Watts 10) '过期状态用例无法通过真实功率Combo选择10 W。'
    Assert-RadioUi ([int]$script:radioCatEditDraft.power -eq 10 -and
        [int]$script:radioControlPreferences.desired_power_watts -eq 15 -and
        (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) ((('过期测试应先通过功率组合框建立10 W草稿并保留15 W偏好。 draft={0}, pref={1}, enabled={2}, selection={3}, result={4}, key={5}/{6}, core={7}, statusAge={8}' -f `
            $script:radioCatEditDraft.power,$script:radioControlPreferences.desired_power_watts,
            [bool](Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled,(Get-UiRadioCatPowerSelection),
            $(if($script:radioCatResult){[string]$script:radioCatResult.status}else{'<null>'}),
            [string]$script:radioCatObservedConnectionKey,(Get-UiRadioCatConnectionKey),[bool]$script:supervisor,
            [int]([DateTime]::UtcNow - $script:lastStatusUtc).TotalMilliseconds) +
        (' detail: needsChoice={0}, operation={1}/{2}, queued={3}, pendingMode={4}, idle={5}, conflict={6}, port={7}, session={8}' -f `
            [bool]$script:radioCatPowerNeedsUserChoice,[bool]$script:radioCatOperationPowerShell,[string]$script:radioCatOperationKind,
            [bool]$script:radioCatQueuedAction,[bool]$script:radioCatPendingModeFrequencyRequest,(Test-UiRadioCatRunIdle -RequireFreshStatus),
            (Test-UiRadioCatSelectedPortConflict),(Get-UiRadioCatSelectedPort),(Get-UiRadioCatSessionState).state)))
    $script:latestStatus = $pausedCoreIdleStatus.PSObject.Copy()
    $script:latestStatus.ptt_last_state = 'pressed'
    $script:lastStatusUtc = [DateTime]::UtcNow
    Update-UiRadioCatControls
    Assert-RadioUi (-not (Test-UiRadioCatRunIdle -RequireFreshStatus) -and
        -not (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) `
        '核心仍报告 PTT pressed 时，统一 Apply 没有被忙状态门禁。'
    $script:latestStatus = $pausedCoreIdleStatus
    $script:lastStatusUtc = [DateTime]::UtcNow
    Update-UiRadioCatControls
    Assert-RadioUi ((Test-UiRadioCatRunIdle -RequireFreshStatus) -and
        (Get-SettingsControl 'ApplyCatSettingsButton').IsEnabled) '恢复 fresh、released 的核心状态后，合法目标应重新允许 Apply。'
    $env:WIREX_R116_UI_CAT_DELAY = 'setPower'
    $writeCountBeforeStale = ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count
    $beginCountBeforeStale = ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count
    $stalePowerButton = Get-SettingsControl 'ApplyCatSettingsButton'
    [void](Start-UiRadioCatOperation -Operation query)
    $staleClickArgs = New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$stalePowerButton)
    $stalePowerButton.RaiseEvent($staleClickArgs)
    Assert-RadioUi ($script:radioCatQueuedAction -and [string]$script:radioCatQueuedAction.operation -ceq 'setSettings' -and
        [int]$script:radioCatQueuedAction.power_watts -eq 10) `
        '过期状态取消测试没有先冻结统一 Apply 的10 W功率目标。'
    $stalePowerPreparationSteps = 0
    while ($script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -cne 'setPower' -and $stalePowerPreparationSteps -lt 3) {
        [void](Complete-TestCatRunspace -TimeoutMs 3000 -RefreshStatusHeartbeat)
        $stalePowerPreparationSteps++
    }
    $observedSnapshotBeforeStale = ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress
    $stalePowerWorkerStarted = Wait-TestRadioCatLogCount -Pattern 'BEGIN\|setPower' -MinimumCount ($beginCountBeforeStale + 1) -TimeoutMs 1000
    Assert-RadioUi $stalePowerWorkerStarted (('状态过期测试没有启动真实 WPF Apply 按钮创建的 fake CAT worker。 enabled={0}, selectedWatts={1}, statusAgeMs={2}, statusKeys={3}, queued={4}, operation={5}/{6}, log={7}' -f `
        [bool]$stalePowerButton.IsEnabled,(Get-UiRadioCatPowerSelection),[int]([DateTime]::UtcNow - $script:lastStatusUtc).TotalMilliseconds,
        (@($script:latestStatus.PSObject.Properties.Name) -join ','),[bool]$script:radioCatQueuedAction,
        [bool]$script:radioCatOperationPowerShell,[string]$script:radioCatOperationKind,(Get-TestRadioCatLog)))
    Start-Sleep -Milliseconds 100
    Assert-RadioUi (([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setPower')).Count -gt $beginCountBeforeStale) '状态过期测试没有观察到新启动的功率操作。'
    $script:lastStatusUtc = [DateTime]::UtcNow.AddSeconds(-4)
    Set-StaleDisplay
    Assert-RadioUi ($script:radioCatOperationCancelled -and $null -ne $script:radioCatOperationStopAsync) '状态过期后，timer没有取消在途功率设置。'
    [void](Complete-TestCatRunspace -TimeoutMs 2800)
    $writesAfterStale = ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and $writesAfterStale -eq $writeCountBeforeStale -and
        $script:radioCatLastOperationStatus -ceq 'unknown' -and $null -eq $script:radioCatResult -and
        (ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress) -ceq $observedSnapshotBeforeStale) `
        ('核心状态过期后仍发生新写入、UI接受晚结果、runspace未释放，或丢弃了此前仍有效的 CAT 读值。 operation={0}/{1}, canceled={2}, stop={3}, status={4}, result={5}, observedSame={6}, writes={7}/{8}' -f `
            [bool]$script:radioCatOperationPowerShell,[string]$script:radioCatOperationKind,[bool]$script:radioCatOperationCancelled,
            [bool]$script:radioCatOperationStopAsync,[string]$script:radioCatLastOperationStatus,
            $(if($script:radioCatResult){[string]$script:radioCatResult.status}else{'<null>'}),
            ((ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress) -ceq $observedSnapshotBeforeStale),$writesAfterStale,$writeCountBeforeStale)
    Start-Sleep -Milliseconds 100
    [void](Complete-UiRadioCatOperation)
    Assert-RadioUi ($null -eq $script:radioCatResult -and
        (ConvertTo-Json -InputObject $script:radioCatObserved -Depth 8 -Compress) -ceq $observedSnapshotBeforeStale -and
        ([regex]::Matches((Get-TestRadioCatLog),'WRITE\|setPower')).Count -eq $writeCountBeforeStale) '取消后的 CAT 晚结果覆盖了未知状态或继续写入。'
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue

    # Application shutdown drains CAT without stopping a live HRI supervisor.
    $script:supervisor = $null
    $env:WIREX_R116_UI_CAT_DELAY = 'query'
    $env:WIREX_R116_UI_CAT_DELAY_MS = '1200'
    $script:radioCatSessionShutdown = $false
    $script:radioCatSessionRequested = $true
    $script:radioCatPollingActive = $true
    Assert-RadioUi ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell) 'app shutdown test did not start the CAT worker.'
    $shutdownCompletedImmediately = Stop-UiRadioCatSession -Reason app_shutdown
    Assert-RadioUi (-not $shutdownCompletedImmediately -and (Get-UiRadioCatSessionState).shutdown -and
        -not (Get-UiRadioCatSessionState).requested -and -not (Get-UiRadioCatSessionState).polling -and
        $script:radioCatOperationStopAsync -and -not $script:supervisor) 'app shutdown did not request CAT worker cleanup independently.'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Assert-RadioUi ($null -eq $script:radioCatOperationPowerShell -and (Get-UiRadioCatSessionState).shutdown -and
        -not (Connect-UiRadioCatSession)) 'app shutdown left a CAT worker or allowed a new session.'

    if ($CatOnly) {
        Write-Output ('PASS: {0} CAT UI WPF fake assertions (Windows PowerShell 5.1; no physical serial ports).' -f $script:radioUiAssertionCount)
        return
    }

    # RenderOnly call-history coverage uses the production model and WPF pager with synthetic status only.
    $script:radioCatSessionShutdown=$false
    $script:callHistoryModel=New-Object 'System.Collections.Generic.List[object]'
    $script:callHistoryKeys=@{}
    $script:selectedCallHistoryKey=''
    $script:callHistoryPageIndex=0
    if ($null -eq $script:callIdentityCache) { $script:callIdentityCache=@{} }
    $script:radioIdentityModuleLoaded=$true
    function Resolve-RadioIdentity {
        param([uint32]$RadioId,[string]$CachePath)
        return $script:callIdentityCache[[string]$RadioId]
    }
    $script:identityNativeCallRefreshKeys=@{}
    $historyWindow=$script:testRootMainWindow
    $script:mainWindow=$historyWindow
    for ($historyGeneration=1; $historyGeneration -le 7; $historyGeneration++) {
        $script:identityNativeCallRefreshKeys[('history-test|{0}|460997' -f $historyGeneration)]=$true
        $historyRecord=[pscustomobject][ordered]@{
            run_id='history-test';current_call_valid=$true;current_call_generation=[uint64]$historyGeneration
            current_call_source_id=[uint64]460997;current_call_destination_id=[uint64](3149876+$historyGeneration)
            current_call_slot=[uint64]2;current_call_kind='P';timestamp_utc_ms=[int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }
        Add-UiCallHistoryRecord -Record $historyRecord
    }
    $historyList=$historyWindow.FindName('CallHistoryList')
    Assert-RadioUi ($script:callHistoryModel.Count -eq 7 -and $historyList.Items.Count -eq 2 -and
        $script:callHistoryPageIndex -eq 1 -and $historyWindow.FindName('CallHistoryPageText').Text -ceq '2 / 2') `
        '超过五条来话后，完整模型、第二页可见记录和页码未正确建立。'
    [void](Set-UiCallHistoryPage -Delta -1)
    $historyList.SelectedIndex=0
    $selectedHistoryKey=Get-UiCallHistorySelectedKey
    $selectedHistoryTarget=New-UiCallTargetFromHistoryEntry -Entry $historyList.SelectedItem
    Assert-RadioUi ($selectedHistoryKey -ceq 'history-test|7' -and $selectedHistoryTarget.destination_id -eq 460997 -and
        $selectedHistoryTarget.kind -ceq 'private' -and $selectedHistoryTarget.slot -eq 2) `
        '当前页选中的记录没有按其呼叫 key 生成 PTT 目标。'
    $offPageKey='history-test|1'
    $script:callIdentityCache['460997']=[pscustomobject]@{source_id=[uint32]460997;id=[uint32]460997;callsign='N1PAGE';name='Synthetic Page';status='found';display_name='N1PAGE'}
    Assert-RadioUi (Update-UiIdentityHistoryEntry -HistoryKey $offPageKey -Identity $script:callIdentityCache['460997']) `
        '身份查询没有按历史 record key 找到完整模型中的离页记录。'
    $offPageRecord=@($script:callHistoryModel | Where-Object { $_.key -ceq $offPageKey })[0]
    Assert-RadioUi ($offPageRecord.source_label -match 'N1PAGE' -and $historyList.Items.Count -eq 5 -and
        (Get-UiCallHistorySelectedKey) -ceq $selectedHistoryKey) ('离页身份回写丢失呼号、改变当前页或改写选中 key。 label={0}, count={1}, selected={2}/{3}' -f `
            $offPageRecord.source_label,$historyList.Items.Count,(Get-UiCallHistorySelectedKey),$selectedHistoryKey)
    $historyIncoming=[pscustomobject][ordered]@{
        run_id='history-test';current_call_valid=$true;current_call_generation=[uint64]8
        current_call_source_id=[uint64]460997;current_call_destination_id=[uint64]3149882
        current_call_slot=[uint64]2;current_call_kind='P';timestamp_utc_ms=[int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    }
    $script:identityNativeCallRefreshKeys['history-test|8|460997']=$true
    Add-UiCallHistoryRecord -Record $historyIncoming
    Assert-RadioUi ($script:callHistoryModel.Count -eq 8 -and
        (Get-UiCallHistorySelectedKey) -ceq $selectedHistoryKey -and
        [string]$historyList.SelectedItem.key -ceq $selectedHistoryKey) `
        '新来话插入后，列表没有保留用户选中的历史记录 key。'
    Add-UiCallHistoryRecord -Record $historyIncoming
    Assert-RadioUi ($script:callHistoryModel.Count -eq 8) '相同 run/generation 的来话重复进入完整模型。'
    for ($historyGeneration=9; $historyGeneration -le 55; $historyGeneration++) {
        $script:identityNativeCallRefreshKeys[('history-test|{0}|460997' -f $historyGeneration)]=$true
        $boundedHistoryRecord=[pscustomobject][ordered]@{
            run_id='history-test';current_call_valid=$true;current_call_generation=[uint64]$historyGeneration
            current_call_source_id=[uint64]460997;current_call_destination_id=[uint64](3149882+$historyGeneration)
            current_call_slot=[uint64]2;current_call_kind='P';timestamp_utc_ms=[int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }
        Add-UiCallHistoryRecord -Record $boundedHistoryRecord
    }
    Assert-RadioUi ($script:callHistoryModel.Count -eq 50 -and $script:callHistoryModel[0].key -ceq 'history-test|55' -and
        $script:callHistoryModel[49].key -ceq 'history-test|6' -and $historyList.Items.Count -eq 5) `
        '完整历史模型没有按呼叫 key 去重并保留最近五十条记录。'

    # 真实 Start-BridgeRun 参数准备走临时 fake launcher，不经过 UiTestFixture 的 supervisor factory。
    $pausedConfig=Get-WirexPortableConfig -Path $script:portableConfigPath
    $pausedConfig.connection.password=''
    $script:portableConfig=Save-WirexPortableConfig -Path $script:portableConfigPath -Config $pausedConfig
    [void](Import-UiPortableConfig)
    $passwordBoxForRealPrepare=$script:testRootMainWindow.FindName('PasswordBox')
    $passwordBoxForRealPrepare.Password=''
    $fakePrepareDirectory=Join-Path $script:testRoot 'actual-ui-prepare'
    [System.IO.Directory]::CreateDirectory($fakePrepareDirectory) | Out-Null
    $fakeUiLauncherPath=Join-Path $fakePrepareDirectory 'fake-ui-preparer.ps1'
    $fakeUiNativePath=Join-Path $fakePrepareDirectory 'wirex_bridge.exe'
    $uiPrepareCapturePath=Join-Path $fakePrepareDirectory 'captured-parameters.json'
    [System.IO.File]::WriteAllBytes($fakeUiNativePath,[byte[]]@(0x4D,0x5A))
    $fakeUiLauncher=@'
param([string]$Preset,[string]$ConnectionProfilePath,[string]$AudioSettingsPath,[string]$StatusDirectory,[string]$PreparationOutputPath,[switch]$PrepareOnly,[switch]$NoInteractive,[switch]$BmStartDisconnected,[switch]$RequirePasswordFile,[string]$PasswordFile)
$ErrorActionPreference='Stop'
$capture=[ordered]@{
    bound_names=[string[]]@($PSBoundParameters.Keys)
    paused=[bool]$BmStartDisconnected
    password_file_bound=[bool]$PSBoundParameters.ContainsKey('PasswordFile')
    require_password_file_bound=[bool]$PSBoundParameters.ContainsKey('RequirePasswordFile')
}
[System.IO.File]::WriteAllText((Join-Path $StatusDirectory 'captured-parameters.json'),(ConvertTo-Json -InputObject $capture -Depth 3 -Compress),(New-Object System.Text.UTF8Encoding($false)))
$status=Join-Path $StatusDirectory 'fake-status.jsonl'
$routing=Join-Path $StatusDirectory 'routing-state.json'
[System.IO.File]::WriteAllText($routing,'{}',(New-Object System.Text.UTF8Encoding($false)))
$record=[ordered]@{schema_version=1;executable='fake-native.exe';arguments=[string[]]@('--run','--ui-pipe','--ui-control-version','2','--bm-start-disconnected');status_path=$status;routing_state_path=$routing}
[System.IO.File]::WriteAllText($PreparationOutputPath,(ConvertTo-Json -InputObject $record -Depth 4 -Compress),(New-Object System.Text.UTF8Encoding($false)))
'@
    [System.IO.File]::WriteAllText($fakeUiLauncherPath,$fakeUiLauncher,(New-Object System.Text.UTF8Encoding($true)))
    $script:UiTestFixture=$false
    $script:configDirectory=$script:testRoot
    $script:releaseDirectory=$fakePrepareDirectory
    $script:releaseLauncher=$fakeUiLauncherPath
    $script:nativeExecutable=$fakeUiNativePath
    $script:mainWindow=$script:testRootMainWindow
    $script:supervisor=$null; $script:stopTask=$null; $script:preparePowerShell=$null; $script:prepareAsync=$null
    $script:preparationStarted=$false; $script:sessionTempDirectory=''; $script:sessionPasswordPath=''
    $script:serialDisconnectPending=$false; $script:nativeExitCleanupPending=$false
    $script:bmConnectAfterCoreReady=$false; $script:serialConnectCatAfterCoreReady=$false
    & $script:productionStartBridgeRun -BmStartDisconnected
    $prepareWatch=[System.Diagnostics.Stopwatch]::StartNew()
    while ($script:prepareAsync -and -not $script:prepareAsync.IsCompleted -and $prepareWatch.ElapsedMilliseconds -lt 5000) {
        Start-Sleep -Milliseconds 10
    }
    $prepareWatch.Stop()
    $uiPrepareCapturePath=Join-Path $script:preparedRunDirectory 'captured-parameters.json'
    Assert-RadioUi ($script:prepareAsync -and $script:prepareAsync.IsCompleted -and $script:preparationStarted -and
        $script:sessionTempDirectory -and [System.IO.Directory]::Exists($script:sessionTempDirectory)) `
        '真实 Start-BridgeRun 没有完成隔离的 BM 暂停预检参数准备。'
    [void]$script:preparePowerShell.EndInvoke($script:prepareAsync)
    Assert-RadioUi (-not $script:preparePowerShell.HadErrors -and [System.IO.File]::Exists($uiPrepareCapturePath) -and
        [System.IO.File]::Exists((Join-Path $script:preparedRunDirectory 'preparation.json'))) `
        'fake preparer 没有捕获真实 Start-BridgeRun 参数或生成合成记录。'
    $uiPrepareCapture=ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($uiPrepareCapturePath,[System.Text.Encoding]::UTF8))
    Assert-RadioUi ($uiPrepareCapture.paused -and -not $uiPrepareCapture.password_file_bound -and
        -not $uiPrepareCapture.require_password_file_bound -and
        @($uiPrepareCapture.bound_names | Where-Object { $_ -ceq 'BmStartDisconnected' }).Count -eq 1 -and
        -not [System.IO.File]::Exists((Join-Path $script:sessionTempDirectory 'bm-device-password.txt'))) `
        '空密码的真实 UI 准备链仍传入密码文件要求，或创建了空密码文件。'
    [void](Clear-UiSessionTemp)
    $script:preparePowerShell.Dispose(); $script:preparePowerShell=$null; $script:prepareAsync=$null
    $script:preparationStarted=$false; $script:sessionTempDirectory=''; $script:sessionPasswordPath=''

    # The visible serial button uses the paused-core lifecycle and a fake launcher stub.
    if ($script:radioCatOperationPowerShell) { [void](Complete-TestCatRunspace -TimeoutMs 5000) }
    $script:mainWindow=$script:testRootMainWindow
    $script:supervisor=$null; $script:stopTask=$null; $script:preparationStarted=$false
    $script:serialDisconnectPending=$false; $script:radioCatSessionShutdown=$false
    $script:radioCatManualDisconnect=$false; $script:radioCatSessionRequested=$false
    $script:serialConnectCatAfterCoreReady=$false; $script:bmConnectAfterCoreReady=$false
    $script:radioCatQueuedAction=$false; $script:radioCatPendingModeFrequencyRequest=$null; $script:radioModeApplyAfterStop=$null
    Assert-RadioUi (-not (Get-UiRadioCatSessionState).user_action_busy) `
        '伪设备 CAT worker 未在串口/BM 按钮生命周期测试前收尾。'
    $script:testStartBridgeRunCalls=0; $script:testLastBmStartDisconnected=$false
    $passwordBoxForLifecycle=Get-UiControl 'PasswordBox'
    $passwordBoxForLifecycle.Password=''
    $serialConnectButton=$script:mainWindow.FindName('SerialConnectButton')
    $serialConnectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialConnectButton)))
    Assert-RadioUi ($script:testStartBridgeRunCalls -eq 1 -and $script:testLastBmStartDisconnected -and
        $script:serialConnectCatAfterCoreReady -and -not $script:supervisor -and -not $script:radioCatOperationPowerShell) `
        '串口连接按钮没有用BM暂停参数启动核心并将CAT连接排到HRI就绪后。'
    $script:serialConnectCatAfterCoreReady=$false; $script:bmConnectAfterCoreReady=$false
    $script:testStartBridgeRunCalls=0; $script:testLastBmStartDisconnected=$false
    $blankPasswordBmResult=Connect-UiBmFromButton
    Assert-RadioUi (-not $blankPasswordBmResult -and $script:testStartBridgeRunCalls -eq 0 -and
        -not $script:bmConnectAfterCoreReady -and -not $script:serialConnectCatAfterCoreReady -and
        $script:testUiEvents.Count -gt 0 -and $script:testUiEvents[$script:testUiEvents.Count-1] -ceq 'BM 密码未填写，未发起连接。') `
        ('BM 密码为空时连接按钮没有显示字段错误并阻止启动或发送连接请求。 result={0}, calls={1}, bmAfter={2}, catAfter={3}, passwordEmpty={4}, footer=[{5}]' -f `
            $blankPasswordBmResult,$script:testStartBridgeRunCalls,$script:bmConnectAfterCoreReady,$script:serialConnectCatAfterCoreReady,
            [string]::IsNullOrWhiteSpace([string]$script:portableConfig.connection.password),(Get-TestTransientStatus)),
            (' action={0}, prep={1}, stopTask={2}, disconnect={3}' -f (Get-UiRadioCatSessionState).user_action_busy,$script:preparationStarted,[bool]$script:stopTask,$script:serialDisconnectPending)
    $passwordBoxForLifecycle.Password='ui-test-fixture-only'
    Assert-RadioUi (Connect-UiBmFromButton) '没有核心时，BM连接按钮没有复用串口准备流程。'
    Assert-RadioUi ($script:testStartBridgeRunCalls -eq 1 -and $script:testLastBmStartDisconnected -and
        $script:bmConnectAfterCoreReady -and $script:serialConnectCatAfterCoreReady -and -not $script:supervisor) `
        '无核心时的BM连接没有先准备HRI+CAT并将BM连接排到就绪后。'
    $script:bmConnectAfterCoreReady=$false; $script:serialConnectCatAfterCoreReady=$false

    # Fake v2 supervisor covers BM-only toggles, pending UDP teardown, and the serial-disconnect cancellation boundary.
    $bmSupervisor=New-TestBmSupervisor
    $script:supervisor=$bmSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:serialDisconnectPending=$false
    $script:controlConfirmed=$true; $script:controlDiagnostic=$false; $script:bmConnectionNativeCapability=$true
    $script:pendingControlRequests=@{}
    $script:bmConnectionRevision=[uint64]0; $script:bmConnectionPendingRequest=$null
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]0;transport_open=$false;resolving=$false;error='none';bm_state='stopped'
    }
    $script:latestStatus=[pscustomobject]@{ hri_ready=$true; hri_y_zero_ready=$true }
    $script:lastStatusUtc=[DateTime]::UtcNow
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $true) '已有HRI核心时BM独立连接请求没有送到fake supervisor。'
    $bmConnectCommand=$bmSupervisor.SentCommands[0]
    $bmConnectPayload=ConvertFrom-Json -InputObject ([string]$bmConnectCommand.parameters)
    $bmConnectProperties=@($bmConnectPayload.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-RadioUi ($bmConnectCommand.command -ceq 'bm.connection.set' -and $bmConnectPayload.enabled -and
        $bmConnectPayload.revision -eq 1 -and $bmConnectProperties.Count -eq 2 -and
        $bmConnectProperties -ccontains 'enabled' -and $bmConnectProperties -ccontains 'revision') `
        'BM独立连接命令没有只发送递增revision和enabled，不得携带密码、主站或配置。'
    $script:bmConnectionPendingRequest.ack_received=$true
    $script:bmConnectionRevision=[uint64]1
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$true;revision=[uint64]1;transport_open=$false}) `
        -BmState 'stopped' -Resolving $true -ErrorCode 'none' -Source ack)
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $false) 'BM解析期间用户关闭BM未能提交独立断开请求。'
    $bmDisconnectCommand=$bmSupervisor.SentCommands[1]
    $bmDisconnectPayload=ConvertFrom-Json -InputObject ([string]$bmDisconnectCommand.parameters)
    Assert-RadioUi ($bmDisconnectCommand.command -ceq 'bm.connection.set' -and -not $bmDisconnectPayload.enabled -and
        $bmDisconnectPayload.revision -eq 2 -and $bmSupervisor.StopCallCount -eq 0) `
        'BM断开按钮没有独立提交新revision，或误停了HRI核心。'
    $script:bmConnectionPendingRequest.ack_received=$true
    $script:bmConnectionRevision=[uint64]2
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]2;transport_open=$true}) `
        -BmState 'ready' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi ($script:bmConnectionSnapshot.requested_enabled -eq $false -and
        $script:bmConnectionSnapshot.transport_open -and $script:bmConnectionSnapshot.bm_state -ceq 'ready' -and
        $bmSupervisor.StopCallCount -eq 0) 'BM断开ACK被误当作UDP已关闭，或触发了核心停止。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]2;transport_open=$false}) `
        -BmState 'stopped' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi ($script:bmConnectionSnapshot.bm_state -ceq 'stopped' -and -not $script:bmConnectionSnapshot.transport_open -and
        -not $script:bmConnectionPendingRequest -and $bmSupervisor.StopCallCount -eq 0) '完整BM断开快照没有确认BM关闭并保留HRI核心。'

    $backoffSupervisor=New-TestBmSupervisor
    $script:supervisor=$backoffSupervisor; $script:controlConfirmed=$true; $script:controlDiagnostic=$false
    $script:bmConnectionNativeCapability=$true; $script:pendingControlRequests=@{}; $script:pendingStatusRequestId=''
    $script:bmConnectionRevision=[uint64]4
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$true;revision=[uint64]4;ack_received=$true}
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$true;revision=[uint64]4;transport_open=$true;resolving=$false;error='none';bm_state='backoff'
    }
    $script:latestStatus=[pscustomobject]@{hri_ready=$true;hri_y_zero_ready=$true}
    $script:lastStatusUtc=[DateTime]::UtcNow; $script:bmStatusNextRequestUtc=[DateTime]::MinValue
    for ($backoffTick=0; $backoffTick -lt 510; $backoffTick++) {
        [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
            requested_enabled=$true;revision=[uint64]4;transport_open=$true
        }) -BmState 'backoff' -Resolving $false -ErrorCode 'none' -Source status_jsonl)
        Update-UiBmConnectionPoll
    }
    Assert-RadioUi ($backoffSupervisor.SentCommands.Count -eq 0 -and $backoffSupervisor.StopCallCount -eq 0 -and
        $script:bmConnectionPendingRequest -and [bool]$script:bmConnectionPendingRequest.ack_received) `
        'BM backoff期间新鲜JSONL持续报告状态时，超过510次timer tick仍不应发送额外status或停止HRI。'
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $false) 'BM backoff期间仍不能提交独立断开操作。'
    $backoffDisconnect=ConvertFrom-Json -InputObject ([string]$backoffSupervisor.SentCommands[0].parameters)
    Assert-RadioUi ($backoffSupervisor.SentCommands.Count -eq 1 -and -not $backoffDisconnect.enabled -and
        $backoffDisconnect.revision -eq 5 -and $backoffSupervisor.StopCallCount -eq 0) `
        '长期BM backoff后仍应能独立断开BM，且不能停止HRI核心。'

    $recoverySupervisor=New-TestBmSupervisor
    $script:supervisor=$recoverySupervisor; $script:controlConfirmed=$true; $script:controlDiagnostic=$false
    $script:bmConnectionNativeCapability=$true; $script:pendingControlRequests=@{}; $script:pendingStatusRequestId=''
    $script:bmConnectionRevision=[uint64]10
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$true;revision=[uint64]10;ack_received=$true}
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$true;revision=[uint64]10;transport_open=$true;resolving=$false;error='none';bm_state='backoff'
    }
    $script:bmStatusRecoveryCount=0; $script:bmStatusRecoveryStartedUtc=[DateTime]::MinValue
    $script:bmStatusNextRequestUtc=[DateTime]::MinValue; $script:lastBmSnapshotUtc=[DateTime]::MinValue
    for ($missingJsonlTick=0; $missingJsonlTick -lt 520; $missingJsonlTick++) {
        $script:lastBmSnapshotUtc=[DateTime]::MinValue
        $script:bmStatusNextRequestUtc=[DateTime]::MinValue
        $script:pendingStatusRequestId=''
        $beforeRecoverySend=$recoverySupervisor.SentCommands.Count
        Update-UiBmConnectionPoll
        if ($recoverySupervisor.SentCommands.Count -gt $beforeRecoverySend) {
            $script:pendingStatusRequestId=''
            [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
                requested_enabled=$true;revision=[uint64]10;transport_open=$true
            }) -BmState 'backoff' -Resolving $false -ErrorCode 'none' -Source control_status)
        }
    }
    Assert-RadioUi ($recoverySupervisor.SentCommands.Count -eq 3 -and $script:bmStatusRecoveryCount -eq 3 -and
        $script:bmConnectionPendingRequest -and $recoverySupervisor.StopCallCount -eq 0) `
        ('JSONL缺失时，成功的control_status回包不得反复重置总恢复额度；520个tick只允许3次status请求。 sent={0}, recovery={1}, pending={2}, stop={3}' -f `
            $recoverySupervisor.SentCommands.Count,$script:bmStatusRecoveryCount,[bool]$script:bmConnectionPendingRequest,$recoverySupervisor.StopCallCount)
    Assert-RadioUi (Set-UiBmConnectionEnabled -Enabled $false) '恢复额度耗尽后，用户仍不能反向断开BM。'
    $recoveryDisconnect=ConvertFrom-Json -InputObject ([string]$recoverySupervisor.SentCommands[$recoverySupervisor.SentCommands.Count-1].parameters)
    Assert-RadioUi ($recoverySupervisor.SentCommands.Count -eq 4 -and -not $recoveryDisconnect.enabled -and
        $recoveryDisconnect.revision -eq 11 -and $script:bmStatusRecoveryCount -eq 0 -and
        $recoverySupervisor.StopCallCount -eq 0) `
        '新的BM断开请求没有建立新的有界恢复周期，或误停了HRI核心。'

    $script:supervisor=$bmSupervisor; $script:pendingControlRequests=@{}
    $script:bmConnectionPendingRequest=$null; $script:lastBmSnapshotUtc=[DateTime]::UtcNow
    $script:bmConnectionRevision=[uint64]3
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$true;revision=[uint64]3;transport_open=$true;resolving=$false;error='none';bm_state='ready'
    }
    $script:radioCatSessionShutdown=$false; $script:radioCatSessionRequested=$true
    $script:radioCatSessionConnected=$true; $script:radioCatPollingActive=$true; $script:radioCatSessionState='connected'
    $script:radioCatManualDisconnect=$false; $script:radioCatSessionGeneration=[int]$script:radioCatSessionGeneration + 1
    $script:radioCatPendingModeFrequencyRequest=[pscustomobject]@{operation='setMode';mode='C4FM-DN'}
    $script:radioModeApplyAfterStop=[pscustomobject]@{operation='setMode';mode='C4FM-DN'}
    $script:radioCatQueuedAction=[pscustomobject]@{operation='setPower';power_watts=6}
    $setModeLogBeforeSerialDisconnect=([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count
    $env:WIREX_R116_UI_CAT_DELAY='query'; $env:WIREX_R116_UI_CAT_DELAY_MS='700'
    Assert-RadioUi ([bool](Invoke-UiRadioCatPollTick -Force) -and $script:radioCatOperationPowerShell) `
        '组合串口断开测试没有先启动fake CAT query。'
    $serialDisconnectGeneration=[int]$script:radioCatSessionGeneration
    Update-UiSerialConnectButton
    $serialDisconnectButton=$script:mainWindow.FindName('SerialConnectButton')
    Assert-RadioUi ([string]$serialDisconnectButton.Content -ceq '断开串口') 'BM/CAT活动时唯一串口toggle未显示断开操作。'
    $serialDisconnectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialDisconnectButton)))
    $serialBmDisableCommand=$bmSupervisor.SentCommands[$bmSupervisor.SentCommands.Count - 1]
    $serialBmDisable=ConvertFrom-Json -InputObject ([string]$serialBmDisableCommand.parameters)
    Assert-RadioUi ($script:serialDisconnectPending -and -not $script:radioCatManualDisconnect -and
        $script:radioCatSessionRequested -and $script:radioCatOperationPowerShell -and
        -not $serialBmDisable.enabled -and $bmSupervisor.StopCallCount -eq 0) `
        ('串口断开没有先请求BM关闭并等待真实关闭，同时暂存CAT清理和核心停止。 pending={0}, catRequested={1}, worker={2}, manual={3}, stop={4}, sent={5}, last={6}' -f `
            [bool]$script:serialDisconnectPending,[bool]$script:radioCatSessionRequested,[bool]$script:radioCatOperationPowerShell,
            [bool]$script:radioCatManualDisconnect,$bmSupervisor.StopCallCount,$bmSupervisor.SentCommands.Count,
            $(if($bmSupervisor.SentCommands.Count){$bmSupervisor.SentCommands[$bmSupervisor.SentCommands.Count-1].parameters}else{'<none>'}))
    $script:bmConnectionPendingRequest.ack_received=$true
    $script:bmConnectionRevision=[uint64]4
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]4;transport_open=$true}) `
        -BmState 'ready' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi ($script:radioCatSessionRequested -and $bmSupervisor.StopCallCount -eq 0) `
        'Native accepted disconnect ACK 尚未关闭UDP时，CAT与HRI被提前断开。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]4;transport_open=$false}) `
        -BmState 'stopped' -Resolving $false -ErrorCode 'none' -Source status)
    Assert-RadioUi (-not $script:radioCatSessionRequested -and $script:radioCatOperationPowerShell -and
        $null -eq $script:radioCatPendingModeFrequencyRequest -and $null -eq $script:radioModeApplyAfterStop -and
        $null -eq $script:radioCatQueuedAction -and $bmSupervisor.StopCallCount -eq 0 -and
        [int]$script:radioCatSessionGeneration -gt $serialDisconnectGeneration) `
        'BM确认关闭后串口收尾没有撤销MAIN等待事务/功率动作，或在CAT worker清理前停止了HRI。'
    [void](Complete-TestCatRunspace -TimeoutMs 3000)
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    [void](Complete-UiSerialDisconnectAfterBm)
    Assert-RadioUi ($bmSupervisor.StopCallCount -eq 1 -and
        ([regex]::Matches((Get-TestRadioCatLog),'BEGIN\|setMode')).Count -eq $setModeLogBeforeSerialDisconnect -and
        -not $script:radioCatSessionRequested -and -not $script:radioCatOperationPowerShell) `
        'CAT worker清理后串口断开没有只停止HRI一次，或迟到事务恢复了MAIN写入。'
    [void]$bmSupervisor.StopSource.TrySetResult(0)
    $bmSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false

    # An uncached status can report a completed disconnect together with a stale failure code.
    $closedErrorSupervisor=New-TestBmSupervisor
    $script:supervisor=$closedErrorSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:controlConfirmed=$true; $script:bmConnectionNativeCapability=$true
    $script:pendingControlRequests=@{}; $script:pendingStatusRequestId=''
    $script:bmConnectionRevision=[uint64]0; $script:bmConnectionPendingRequest=$null
    $script:bmConnectionSnapshot=$null
    $script:serialDisconnectPending=$false; $script:serialDisconnectCoreStopIssued=$false
    $script:serialDisconnectCatStopRequested=$false
    $script:radioCatSessionShutdown=$false; $script:radioCatManualDisconnect=$false
    $script:radioCatSessionRequested=$false; $script:radioCatSessionConnected=$false
    $script:radioCatPollingActive=$false; $script:radioCatOperationPowerShell=$null
    $script:radioCatSessionState='disconnected'
    Update-UiSerialConnectButton
    $serialDisconnectButton=$script:mainWindow.FindName('SerialConnectButton')
    Assert-RadioUi ([string]$serialDisconnectButton.Content -ceq '断开串口') 'HRI核心活动时唯一串口toggle未显示断开操作。'
    $serialDisconnectButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$serialDisconnectButton)))
    Assert-RadioUi ($script:serialDisconnectPending -and -not $script:bmConnectionSnapshot -and
        $closedErrorSupervisor.SentCommands.Count -eq 1 -and
        $closedErrorSupervisor.SentCommands[0].command -ceq 'status' -and
        $closedErrorSupervisor.StopCallCount -eq 0) `
        '没有BM缓存状态时，串口断开没有等待Native状态快照。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]0;transport_open=$false
    }) -BmState 'stopped' -Resolving $false -ErrorCode 'password_required' -Source status)
    Assert-RadioUi ($script:bmConnectionSnapshot.error -ceq 'password_required' -and
        $script:serialDisconnectPending -and $script:serialDisconnectCatStopRequested -and
        $script:serialDisconnectCoreStopIssued -and $closedErrorSupervisor.StopCallCount -eq 1 -and
        -not $script:radioCatSessionRequested) `
        'BM已关闭快照携带旧密码错误时，UI仍阻止CAT和HRI核心收尾。'
    [void]$closedErrorSupervisor.StopSource.TrySetResult(0)
    $closedErrorSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false

    $mediaSupervisor=New-TestBmSupervisor
    $script:supervisor=$mediaSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:serialDisconnectPending=$true; $script:serialDisconnectCoreStopIssued=$false
    $script:serialDisconnectCatStopRequested=$false; $script:serialDisconnectDeadlineUtc=[DateTime]::UtcNow.AddSeconds(15)
    $script:bmConnectionRevision=[uint64]5
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$false;revision=[uint64]5;ack_received=$true}
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]5;transport_open=$true;resolving=$false;error='none';bm_state='ready'
    }
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]5;transport_open=$true
    }) -BmState 'ready' -Resolving $false -ErrorCode 'media_cleanup_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:bmConnectionPendingRequest -and
        -not $script:serialDisconnectCoreStopIssued -and $mediaSupervisor.StopCallCount -eq 0) `
        'BM媒体清理超时且UDP仍打开时，串口断开意图未等待Native后续关包。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]5;transport_open=$false
    }) -BmState 'stopped' -Resolving $false -ErrorCode 'media_cleanup_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:serialDisconnectCoreStopIssued -and
        -not $script:bmConnectionPendingRequest -and $mediaSupervisor.StopCallCount -eq 1) `
        'BM媒体错误保留到UDP关闭后，串口断开仍未继续停止HRI。'
    [void]$mediaSupervisor.StopSource.TrySetResult(0); $mediaSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false
    $script:serialDisconnectDeadlineUtc=[DateTime]::MinValue

    $resolverSupervisor=New-TestBmSupervisor
    $script:supervisor=$resolverSupervisor; $script:stopTask=$null; $script:closingAfterStop=$false
    $script:serialDisconnectPending=$true; $script:serialDisconnectCoreStopIssued=$false
    $script:serialDisconnectCatStopRequested=$false; $script:serialDisconnectDeadlineUtc=[DateTime]::UtcNow.AddSeconds(15)
    $script:bmConnectionRevision=[uint64]6
    $script:bmConnectionPendingRequest=[pscustomobject]@{enabled=$false;revision=[uint64]6;ack_received=$true}
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]6;transport_open=$false
    }) -BmState 'stopped' -Resolving $true -ErrorCode 'resolver_cancel_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:bmConnectionPendingRequest -and
        -not $script:serialDisconnectCoreStopIssued -and $resolverSupervisor.StopCallCount -eq 0) `
        'DNS取消清理超时但仍 resolving 时，串口断开意图未等待Native关闭解析器。'
    [void](Set-UiBmConnectionSnapshot -Connection ([pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]6;transport_open=$false
    }) -BmState 'stopped' -Resolving $false -ErrorCode 'resolver_cancel_timeout' -Source status)
    Assert-RadioUi ($script:serialDisconnectPending -and $script:serialDisconnectCoreStopIssued -and
        -not $script:bmConnectionPendingRequest -and $resolverSupervisor.StopCallCount -eq 1) `
        'DNS取消错误保留到解析结束后，串口断开仍未继续停止HRI。'
    [void]$resolverSupervisor.StopSource.TrySetResult(0); $resolverSupervisor.HasExited=$true
    $script:stopTask=$null; $script:supervisor=$null; $script:serialDisconnectPending=$false
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false
    $script:serialDisconnectDeadlineUtc=[DateTime]::MinValue

    $deadlineSupervisor=New-TestBmSupervisor
    $script:supervisor=$deadlineSupervisor; $script:serialDisconnectPending=$true
    $script:serialDisconnectCoreStopIssued=$false; $script:serialDisconnectCatStopRequested=$false
    $script:serialDisconnectDeadlineUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    $script:bmConnectionSnapshot=[pscustomobject][ordered]@{
        requested_enabled=$false;revision=[uint64]7;transport_open=$false;resolving=$true;error='resolver_cancel_timeout';bm_state='stopped'
    }
    $script:bmConnectionPendingRequest=$null; $script:bmConnectionRevision=[uint64]7
    $script:bmConnectionNativeCapability=$true; $script:controlConfirmed=$true
    $script:pendingStatusRequestId=''; $script:bmStatusNextRequestUtc=[DateTime]::MinValue
    Update-UiBmConnectionPoll
    Assert-RadioUi (-not $script:serialDisconnectPending -and $deadlineSupervisor.StopCallCount -eq 0 -and
        $script:testUiEvents.Count -gt 0 -and $script:testUiEvents[$script:testUiEvents.Count-1] -ceq '串口断开等待超时；HRI 和 CAT 仍保持连接') `
        ('断串口等待超过期限时没有失败退出并如实显示当前解析/连接状态。 pending={0}, stop={1}, deadline={2}, footer=[{3}]' -f `
            [bool]$script:serialDisconnectPending,$deadlineSupervisor.StopCallCount,$script:serialDisconnectDeadlineUtc,
            (Get-TestTransientStatus))
    $deadlineSupervisor.HasExited=$true; $script:supervisor=$null; $script:stopTask=$null

    Write-Output ('通过：四轮fake CAT轮询/写入及复核、COM和音频选值保存、无副作用安全失败、串口/BM暂停连接路线、旧错误与异步收尾快照下双口关闭及等待超时、50条呼号模型去重/分页/离页身份回写、CAT取消和退出清理均已验证。断言数：{0}' -f $script:radioUiAssertionCount)
} finally {
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_DELAY_MS -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_BAD_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_R116_UI_CAT_MODULE_PATH -ErrorAction SilentlyContinue
    if ($script:radioCatOperationPowerShell) {
        try {
            if ($script:radioCatOperationAsync -and -not $script:radioCatOperationAsync.IsCompleted) {
                $stop = $script:radioCatOperationPowerShell.BeginStop($null,$null)
                if ($stop.AsyncWaitHandle.WaitOne(3000)) { $script:radioCatOperationPowerShell.EndStop($stop) }
            }
        } catch { }
        try { $script:radioCatOperationPowerShell.Dispose() } catch { }
    }
    if ($script:settingsWindow) { try { $script:settingsWindow.Close() } catch { } }
    if ($script:mainWindow -is [System.Windows.Window]) { try { $script:mainWindow.Close() } catch { } }
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    $testRootFullPath = [System.IO.Path]::GetFullPath([string]$script:testRoot)
    $testRootName = [System.IO.Path]::GetFileName($testRootFullPath)
    $testRootIsOwned = $testRootFullPath.StartsWith($temporaryRoot,[System.StringComparison]::OrdinalIgnoreCase) -and
        $testRootName -match '^wirex-r116-ui-cat-[0-9a-f]{32}$'
    if ($testRootIsOwned -and [System.IO.Directory]::Exists($testRootFullPath)) {
        Remove-Item -LiteralPath $testRootFullPath -Recurse -Force
    } elseif ([System.IO.Directory]::Exists($testRootFullPath)) {
        Write-Warning ('测试目录未删除，因为路径不符合本脚本创建的临时目录格式：' + $testRootFullPath)
    }
}
