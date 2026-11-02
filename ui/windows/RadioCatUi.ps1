#requires -Version 5.1

# CAT-1 UI controller. Loaded by bridge-ui.ps1 after script state is initialized.

# Keep all CAT access bounded to explicit short open/query-or-set/readback/close operations.

function Find-UiRadioCatControl {
    param([Parameter(Mandatory=$true)][string]$Name)
    if ($script:mainWindow) {
        $control = $script:mainWindow.FindName($Name)
        if ($control) { return $control }
    }
    if ($script:settingsWindow) {
        $control = $script:settingsWindow.FindName($Name)
        if ($control) { return $control }
    }
    return $null
}

function Set-UiRadioCatControlEnabled {
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][bool]$Enabled)
    $control = Find-UiRadioCatControl -Name $Name
    if ($control -and [bool]$control.IsEnabled -ne $Enabled) { $control.IsEnabled = $Enabled }
}

function Set-UiRadioCatControlVisibility {
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][System.Windows.Visibility]$Visibility)
    $control = Find-UiRadioCatControl -Name $Name
    if ($control -and $control.Visibility -ne $Visibility) { $control.Visibility = $Visibility }
}

function Get-UiRadioCatStopBits {
    return 'Two'
}

function Get-UiRadioCatBaudRate {
    $control = Find-UiRadioCatControl -Name 'CatBaudRateBox'
    if ($control -and $control.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) {
        $selected = [int]$control.SelectedItem.Tag
        if ($selected -in @(4800,9600,19200,38400,115200)) { return $selected }
    }
    if ($script:radioControlPreferences -and $script:radioControlPreferences.PSObject.Properties['baud_rate']) {
        $configured = [int]$script:radioControlPreferences.baud_rate
        if ($configured -in @(4800,9600,19200,38400,115200)) { return $configured }
    }
    return 38400
}

function Set-UiRadioCatNotice {
    param([AllowEmptyString()][string]$Text='')
    $control = Find-UiRadioCatControl -Name 'CatOperationStatusText'
    if (-not $control) { return }
    if ($control -is [System.Windows.Controls.TextBlock] -or $control -is [System.Windows.Controls.TextBox]) {
        if ([string]$control.Text -cne $Text) { $control.Text = $Text }
    }
    $visibility = if ($Text) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    if ($control.Visibility -ne $visibility) { $control.Visibility = $visibility }
}

function Get-UiRadioCatSessionState {
    if ($null -eq $script:radioCatSessionRequested) { $script:radioCatSessionRequested = $false }
    if ($null -eq $script:radioCatSessionConnected) { $script:radioCatSessionConnected = $false }
    if ($null -eq $script:radioCatSessionState) { $script:radioCatSessionState = 'disconnected' }
    if ($null -eq $script:radioCatSessionGeneration) { $script:radioCatSessionGeneration = 0 }
    $userActionBusy = [bool](($script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -cne 'query') -or
        $script:radioCatQueuedAction -or $script:radioCatPendingModeFrequencyRequest -or $script:radioModeApplyAfterStop)
    return [pscustomobject][ordered]@{
        requested = [bool]$script:radioCatSessionRequested
        connected = [bool]$script:radioCatSessionConnected
        polling = [bool]$script:radioCatPollingActive
        operation = [string]$script:radioCatOperationKind
        error = [string]$script:radioCatSessionError
        shutdown = [bool]$script:radioCatSessionShutdown
        generation = [int]$script:radioCatSessionGeneration
        user_action_busy = $userActionBusy
        state = [string]$script:radioCatSessionState
    }
}

function Update-UiRadioCatCoreActionGate {
    $busy = [bool](Get-UiRadioCatSessionState).user_action_busy
    if ($null -ne $script:radioCatReportedUserActionBusy -and [bool]$script:radioCatReportedUserActionBusy -eq $busy) { return }
    $script:radioCatReportedUserActionBusy = $busy
    if (Get-Command -Name 'Set-ConnectionButtonState' -ErrorAction SilentlyContinue) { Set-ConnectionButtonState }
}

function Set-UiRadioCatSessionState {
    param([Parameter(Mandatory=$true)][ValidateSet('disconnected','connecting','connected','polling','error','disconnecting','shutdown')][string]$State)
    $script:radioCatSessionState = $State
    $text = switch ($State) {
        'disconnected' { '未连接' }
        'connecting' { '正在连接' }
        'connected' { '已连接' }
        'polling' { '正在读取' }
        'error' { if ($script:radioCatSessionError) { '读取失败：' + [string]$script:radioCatSessionError } else { '读取失败' } }
        'disconnecting' { '正在断开' }
        'shutdown' { '正在退出' }
    }
    Set-UiRadioCatText -Name 'CatSessionStatusText' -Text $text
}

function Update-UiRadioCatSessionControls {
    $state = Get-UiRadioCatSessionState
    if (Get-Command -Name 'Set-ConnectionButtonState' -ErrorAction SilentlyContinue) {
        Set-ConnectionButtonState
    } else {
        $connectButton = Find-UiRadioCatControl -Name 'SerialConnectButton'
        $disconnectButton = Find-UiRadioCatControl -Name 'SerialDisconnectButton'
        if ($connectButton) {
            $enabled = (-not $state.requested -and -not $state.shutdown -and -not $script:radioCatOperationPowerShell -and
                (Get-UiRadioCatSelectedPort) -and -not (Test-UiRadioCatSelectedPortConflict))
            $connectButton.IsEnabled = [bool]$enabled
        }
        if ($disconnectButton) { $disconnectButton.IsEnabled = ($state.requested -and -not $state.shutdown) }
    }
    if ($state.state -eq 'polling' -or $state.state -eq 'connected' -or $state.state -eq 'error' -or
        $state.state -eq 'connecting' -or $state.state -eq 'disconnecting' -or $state.state -eq 'shutdown') {
        Set-UiRadioCatSessionState -State $state.state
    } else {
        Set-UiRadioCatSessionState -State 'disconnected'
    }
}

function Set-UiRadioCatLinkState {
    param([Parameter(Mandatory=$true)][ValidateSet('unknown','connected','missing','query_failed')][string]$State)
    $previous = [string]$script:radioCatLinkState
    if ($previous -ceq $State) { return }
    $script:radioCatLinkState = $State
    $eventText = ''
    if ($State -ceq 'missing' -and $previous -in @('connected','query_failed')) {
        $eventText = 'CAT串口从设备列表消失；正在等待重新枚举。'
    } elseif ($State -ceq 'query_failed') {
        $eventText = 'CAT状态读取失败；等待下一次读取。'
    } elseif ($State -ceq 'connected' -and $previous -in @('missing','query_failed') -and
        $script:radioCatLastSuccessfulQueryUtc -gt [DateTime]::MinValue) {
        $eventText = 'CAT状态读取已恢复。'
    }
    if ($eventText -and (Get-Command -Name Add-UiEvent -ErrorAction SilentlyContinue)) { Add-UiEvent $eventText }
}

function Initialize-UiRadioCatController {
    if ($script:radioCatControllerInitialized -or -not $script:mainWindow) { return }
    $script:radioCatControllerInitialized = $true
    if ($null -eq $script:radioCatPortSelectionExplicit) { $script:radioCatPortSelectionExplicit = $false }
    if ($null -eq $script:radioCatPortTextEditExplicit) { $script:radioCatPortTextEditExplicit = $false }
    if ($null -eq $script:radioCatPollingActive) { $script:radioCatPollingActive = $false }
    if ($null -eq $script:radioCatSessionRequested) { $script:radioCatSessionRequested = [bool]$script:radioCatPollingActive }
    if ($null -eq $script:radioCatSessionConnected) { $script:radioCatSessionConnected = $false }
    if ($null -eq $script:radioCatSessionState) { $script:radioCatSessionState = 'disconnected' }
    if ($null -eq $script:radioCatSessionError) { $script:radioCatSessionError = '' }
    if ($null -eq $script:radioCatSessionShutdown) { $script:radioCatSessionShutdown = $false }
    if ($null -eq $script:radioCatSessionGeneration) { $script:radioCatSessionGeneration = 0 }
    if ($null -eq $script:radioCatManualDisconnect) { $script:radioCatManualDisconnect = $false }
    if ($null -eq $script:radioCatQueuedAction) { $script:radioCatQueuedAction = $null }
    if ($null -eq $script:radioCatOperationOrdinal) { $script:radioCatOperationOrdinal = 0 }
    if ($null -eq $script:radioCatEditDraft) { $script:radioCatEditDraft = @{ mode=$null; frequency=$null; power=$null } }
    if (-not $script:radioCatLinkState) { $script:radioCatLinkState = 'unknown' }

    (Get-SettingsControl 'CatMainModeBox').Add_SelectionChanged({
        if ($script:radioCatProgrammaticControlUpdate -or $script:loadingSettings -or $script:loadingRadioCatSettings) { return }
        $item = (Get-SettingsControl 'CatMainModeBox').SelectedItem
        if ($item -is [System.Windows.Controls.ComboBoxItem] -and [string]$item.Tag -cin @('FM','FM-N','C4FM-DN','C4FM-VW')) {
            $script:radioCatEditDraft.mode = [string]$item.Tag
        }
        Update-UiRadioCatControls
    })
    (Get-SettingsControl 'CatMainFrequencyMHzBox').Add_TextChanged({
        if ($script:radioCatProgrammaticControlUpdate -or $script:loadingSettings -or $script:loadingRadioCatSettings) { return }
        $script:radioCatEditDraft.frequency = [string](Get-SettingsControl 'CatMainFrequencyMHzBox').Text
        Update-UiRadioCatControls
    })
    $catPortControl = Get-SettingsControl 'CatPortBox'
    $catPortControl.Add_SelectionChanged({
        if (-not $script:radioCatProgrammaticControlUpdate -and -not $script:loadingSettings -and -not $script:loadingRadioCatSettings) {
            $script:radioCatPortSelectionExplicit = $true
            $script:radioCatPortTextEditExplicit = $false
        }
        Update-UiRadioCatControls
    })
    $catPortControl.Add_Loaded({ Register-UiRadioCatPortTextInput })
    Register-UiRadioCatPortTextInput
    (Get-SettingsControl 'CatBaudRateBox').Add_SelectionChanged({ Update-UiRadioCatControls })
    $stopBitsControl = Find-UiRadioCatControl -Name 'CatStopBitsBox'
    if ($stopBitsControl) { $stopBitsControl.Add_SelectionChanged({ Update-UiRadioCatControls }) }
    $connectButton = Find-UiRadioCatControl -Name 'SerialConnectButton'
    if ($connectButton) { $connectButton.Add_Click({ [void](Connect-UiSerialCombo) }) }
    $disconnectButton = Find-UiRadioCatControl -Name 'SerialDisconnectButton'
    if ($disconnectButton) { $disconnectButton.Add_Click({ [void](Disconnect-UiSerialCombo) }) }
    (Get-SettingsControl 'ApplyCatModeButton').Add_Click({ Invoke-UiRadioCatAction -Operation 'setMode' })
    (Get-SettingsControl 'ApplyCatFrequencyButton').Add_Click({ Invoke-UiRadioCatAction -Operation 'setFrequency' })
    (Get-SettingsControl 'ApplyCatPowerButton').Add_Click({ Invoke-UiRadioCatAction -Operation 'setPower' })
    (Get-SettingsControl 'CatPowerSlider').Add_ValueChanged({
        $slider = Get-SettingsControl 'CatPowerSlider'
        if ($script:radioCatProgrammaticControlUpdate -or $script:loadingRadioCatSettings -or [string]$slider.Tag -ceq '__radio_cat_programmatic__') { return }
        $script:radioCatEditDraft.power = [int][Math]::Round([double]$slider.Value,[MidpointRounding]::AwayFromZero)
        Update-UiRadioCatControls
    })
    Update-UiRadioCatObservationDisplay
    Update-UiRadioCatControls
    Update-UiRadioCatSessionControls
}

function Register-UiRadioCatPortTextInput {
    if (-not $script:mainWindow) { return }
    $combo = Get-SettingsControl 'CatPortBox'
    if (-not $combo -or -not $combo.IsEditable -or -not $combo.Template) { return }
    $textBox = $combo.Template.FindName('PART_EditableTextBox',$combo)
    if ($textBox -isnot [System.Windows.Controls.TextBox]) { return }
    if ([string]$textBox.Tag -ceq '__radio_cat_port_input_bound__') { return }
    $textBox.Tag = '__radio_cat_port_input_bound__'
    $textBox.Add_TextChanged({ param($sender,$eventArgs)
        if ($script:radioCatProgrammaticControlUpdate -or $script:loadingSettings -or $script:loadingRadioCatSettings) { return }
        if (-not $sender.IsKeyboardFocusWithin -and -not $sender.IsFocused) { return }
        $script:radioCatPortSelectionExplicit = $true
        $script:radioCatPortTextEditExplicit = $true
        Update-UiRadioCatControls
    })
}

function Set-UiRadioCatDraft {
    param([Parameter(Mandatory=$true)][ValidateSet('mode','frequency','power')][string]$Field,[AllowNull()][object]$Value)
    if ($null -eq $script:radioCatEditDraft) { $script:radioCatEditDraft = @{ mode=$null; frequency=$null; power=$null } }
    $script:radioCatEditDraft[$Field] = $Value
}

function Test-UiRadioCatExplicitFakeHook {
    return [bool]($script:uiTestHooks -and $script:uiTestHooks.CatOperation -is [scriptblock])
}

function Test-UiRadioCatHardwareAccessAllowed {
    if ($script:isolatedUiMode -and -not (Test-UiRadioCatExplicitFakeHook)) { return $false }
    return $true
}

function Connect-UiRadioCatSession {
    param([switch]$Automatic)
    if (-not $script:radioCatModuleAvailable -or $script:radioCatSessionShutdown) { return $false }
    if (-not (Test-UiRadioCatHardwareAccessAllowed)) { return $false }
    if ($Automatic -and $script:NoAutoConnect) { return $false }
    # Disconnect can request cancellation while the runspace is still closing.
    # Do not advance the generation or start a replacement session until it is
    # disposed; the Connect button remains disabled during this interval.
    if ($script:radioCatOperationPowerShell) {
        Update-UiRadioCatSessionControls
        return $false
    }
    if ($Automatic -and $script:radioCatManualDisconnect) { return $false }
    if (-not $Automatic) { $script:radioCatManualDisconnect = $false }
    if ($script:radioCatSessionRequested) { return $true }
    $script:radioCatSessionRequested = $true
    $script:radioCatPollingActive = $true
    $script:radioCatSessionConnected = $false
    $script:radioCatSessionError = ''
    $script:radioCatSessionGeneration = [int]$script:radioCatSessionGeneration + 1
    $script:radioCatPollingConnectionKey = ''
    $script:radioCatPollNextUtc = [DateTime]::UtcNow
    Set-UiRadioCatSessionState -State 'connecting'
    Update-UiRadioCatControls
    Update-UiRadioCatSessionControls
    $connectionKey = Get-UiRadioCatConnectionKey
    if ($connectionKey) { $script:radioCatPollingConnectionKey = $connectionKey }
    [void](Invoke-UiRadioCatPollTick -Force)
    return $true
}

function Disconnect-UiRadioCatSession {
    param([ValidateSet('user_disconnect','app_shutdown','session_stopped','test_cleanup')][string]$Reason='user_disconnect')
    if ($Reason -ceq 'user_disconnect') { $script:radioCatManualDisconnect = $true }
    $script:radioCatSessionGeneration = [int]$script:radioCatSessionGeneration + 1
    $script:radioCatQueuedAction = $null
    $script:radioCatPendingModeFrequencyRequest = $null
    $script:radioModeApplyAfterStop = $null
    $script:radioModePreviousHriPortName = ''
    $script:radioCatSessionRequested = $false
    $script:radioCatSessionConnected = $false
    $script:radioCatPollingActive = $false
    $script:radioCatPollingConnectionKey = ''
    $script:radioCatPollNextUtc = [DateTime]::MinValue
    $script:radioCatResult = $null
    $script:radioCatSessionError = ''
    if ($Reason -ceq 'app_shutdown') {
        $script:radioCatSessionShutdown = $true
        Set-UiRadioCatSessionState -State 'shutdown'
    } elseif ($script:radioCatOperationPowerShell) {
        Set-UiRadioCatSessionState -State 'disconnecting'
    } else {
        Set-UiRadioCatSessionState -State 'disconnected'
    }
    if ($script:radioCatOperationPowerShell) {
        try { [void](Request-StopUiRadioCatOperation -Reason $Reason) }
        catch { $script:radioCatSessionError = '串口取消请求失败'; Set-UiRadioCatSessionState -State 'error' }
    }
    Update-UiRadioCatControls
    Update-UiRadioCatSessionControls
    if (-not $script:radioCatOperationPowerShell -and $Reason -ne 'app_shutdown') { Set-UiRadioCatDeviceControls }
    return ($null -eq $script:radioCatOperationPowerShell)
}

function Stop-UiRadioCatSession {
    param([ValidateSet('app_shutdown')][string]$Reason='app_shutdown')
    return [bool](Disconnect-UiRadioCatSession -Reason $Reason)
}

function Start-UiRadioCatPolling {
    param([switch]$Automatic)
    if (-not $PSBoundParameters.ContainsKey('Automatic')) { return [bool](Connect-UiRadioCatSession -Automatic) }
    return [bool](Connect-UiRadioCatSession -Automatic:$Automatic)
}

function Stop-UiRadioCatPolling {
    param([string]$Reason='session_stopped')
    if ($Reason -ceq 'hri_session_stopped' -or $Reason -ceq 'native_process_exited') { return $false }
    if ($Reason -cin @('stop_and_exit','main_window_closing','app_shutdown')) {
        return [bool](Stop-UiRadioCatSession -Reason 'app_shutdown')
    }
    if ($Reason -cin @('user_disconnect','session_stopped','test_cleanup')) {
        return [bool](Disconnect-UiRadioCatSession -Reason $Reason)
    }
    return $false
}

function Invoke-UiRadioCatPollTick {
    param([switch]$Force)
    if (-not $script:radioCatSessionRequested -or -not $script:radioCatPollingActive -or
        $script:radioCatSessionShutdown -or -not $script:radioCatModuleAvailable) { return $false }
    $now = [DateTime]::UtcNow
    if (-not $Force -and $now -lt $script:radioCatPollNextUtc) { return $false }
    $interval = if ([int]$script:radioCatPollIntervalMs -ge 500 -and [int]$script:radioCatPollIntervalMs -le 5000) { [int]$script:radioCatPollIntervalMs } else { 1000 }
    $script:radioCatPollNextUtc = $now.AddMilliseconds($interval)
    if ($script:radioCatOperationPowerShell) { return $false }
    $connectionKey = Get-UiRadioCatConnectionKey
    $port = Get-UiRadioCatSelectedPort
    if (-not $connectionKey -or -not (Test-UiRadioCatPollingPortEnumerated -PortName $port)) {
        if ($script:radioCatLinkState -in @('connected','query_failed')) { Set-UiRadioCatLinkState -State 'missing' }
        $script:radioCatSessionConnected = $false
        $script:radioCatSessionError = if (-not $port) { 'CAT端口未就绪' } else { 'CAT端口未枚举' }
        Set-UiRadioCatSessionState -State 'error'
        if ($script:radioCatPollingConnectionKey -or $script:radioCatResult) {
            $script:radioCatPollingConnectionKey = ''
            $script:radioCatResult = $null
            Update-UiRadioCatControls
        }
        return $false
    }
    if (-not [string]::Equals($connectionKey,[string]$script:radioCatPollingConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        $script:radioCatPollingConnectionKey = $connectionKey
        $script:radioCatResult = $null
        Update-UiRadioCatControls
    }
    try {
        if (-not $script:radioCatSessionConnected -and $script:radioCatSessionState -eq 'connecting') {
            Set-UiRadioCatSessionState -State 'polling'
        }
        Start-UiRadioCatOperation -Operation 'query'
        return $true
    } catch {
        $script:radioCatResult = $null
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatSessionConnected = $false
        $script:radioCatSessionError = $_.Exception.Message
        Set-UiRadioCatSessionState -State 'error'
        Set-UiRadioCatLinkState -State 'query_failed'
        Set-UiRadioCatNotice -Text '暂时无法读取电台状态；端口恢复后会重新读取。'
        Update-UiRadioCatControls
        return $false
    }
}

function Test-UiRadioCatPollingPortEnumerated {
    param([AllowEmptyString()][string]$PortName)
    if (-not $PortName) { return $false }
    if ($script:deviceSerialState -notin @('ready','empty') -or -not $script:deviceCatalog) { return $true }
    $ports = @($script:deviceCatalog.serial_ports | Where-Object {
        [string]::Equals([string]$_.PortName,$PortName,[StringComparison]::OrdinalIgnoreCase)
    })
    return ($ports.Count -gt 0)
}

function Get-UiRadioCatDeviceCatalogSignature {
    $allPorts = if ($script:deviceCatalog) { @($script:deviceCatalog.serial_ports) } else { @() }
    $hriPorts = if ($script:deviceCatalog) { @($script:deviceCatalog.hri_ports) } else { @() }
    $serialSignature = @($allPorts | Sort-Object PortName | ForEach-Object {
        $rank = Get-UiRadioCatProperty -InputObject $_ -Name 'CatMatchRank'
        $isHri = Get-UiRadioCatProperty -InputObject $_ -Name 'IsHri'
        '{0}|{1}|{2}|{3}' -f [string]$_.PortName,[string]$_.FriendlyName,[int]$rank,[bool]$isHri
    }) -join ';'
    $hriSignature = @($hriPorts | Sort-Object PortName | ForEach-Object { [string]$_.PortName }) -join ';'
    return ($serialSignature + '#' + $hriSignature)
}

function Set-UiRadioCatDeviceControls {
    if (-not $script:mainWindow -or -not $script:radioCatModuleAvailable) { return }
    $portControl = Get-SettingsControl 'CatPortBox'
    $baudControl = Find-UiRadioCatControl -Name 'CatBaudRateBox'
    if (-not $script:radioControlPreferences) { $script:radioControlPreferences = Get-UiDefaultRadioControlPreferences }

    $allPorts = if ($script:deviceCatalog) { @($script:deviceCatalog.serial_ports) } else { @() }
    $hriPorts = if ($script:deviceCatalog) { @($script:deviceCatalog.hri_ports) } else { @() }
    if ($script:radioCatObservedPortWasEnumerated -and $script:radioCatObservedPortName -and
        @($allPorts | Where-Object { [string]::Equals([string]$_.PortName,[string]$script:radioCatObservedPortName,[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
        Set-UiRadioCatLinkState -State 'missing'
    }
    $catalogSignature = Get-UiRadioCatDeviceCatalogSignature
    if ($script:radioCatSessionRequested) {
        $activePort = Get-UiRadioCatSelectedPort
        if ($activePort -and -not (Test-UiRadioCatPollingPortEnumerated -PortName $activePort)) {
            $script:radioCatSessionConnected = $false
            $script:radioCatSessionError = 'CAT端口未枚举'
            Set-UiRadioCatSessionState -State 'error'
            if ($script:radioCatLinkState -in @('connected','query_failed')) { Set-UiRadioCatLinkState -State 'missing' }
        }
        Update-UiRadioCatControls
        Update-UiRadioCatSessionControls
        return
    }
    $savedPort = [string]$script:radioControlPreferences.cat_port
    $hriPort = Get-UiRadioCatHriPortForOperation
    $controlSignature = '{0}#{1}#{2}#{3}' -f $catalogSignature,$savedPort,$hriPort,[int]$script:radioControlPreferences.baud_rate
    if ([string]::Equals([string]$script:radioCatDeviceCatalogSignature,$controlSignature,[StringComparison]::Ordinal)) {
        Update-UiRadioCatControls
        return
    }
    $previousPort = Get-UiRadioCatSelectedPort
    $previousExplicit = [bool]$script:radioCatPortSelectionExplicit
    $previousTextEdit = [bool]$script:radioCatPortTextEditExplicit
    $options = New-Object 'System.Collections.Generic.List[object]'
    $savedConflict = $savedPort -and (($savedPort -ieq $hriPort) -or @($hriPorts | Where-Object { [string]$_.PortName -ieq $savedPort }).Count -gt 0)
    foreach ($port in @($allPorts | Sort-Object @{ Expression = { -[int]$_.CatMatchRank } }, PortName)) {
        $portName = [string]$port.PortName
        $hriMatch = @($hriPorts | Where-Object { [string]::Equals([string]$_.PortName,$portName,[System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        $friendlyName = if ([string]::IsNullOrWhiteSpace([string]$port.FriendlyName)) { $portName } else { [string]$port.FriendlyName }
        $isHri = $hriMatch -or [bool]$port.IsHri
        $label = if ($isHri) { 'HRI（不可用于 CAT） · ' + $portName } elseif ([int]$port.CatMatchRank -gt 0) { '{0} · 推荐 CAT · {1}' -f $friendlyName,$portName } else { '{0} · 可手选 · {1}' -f $friendlyName,$portName }
        [void]$options.Add((New-UiDeviceOption -Label $label -Value $portName -IsAvailable (-not $isHri) -Kind $(if ($isHri) { 'hri' } elseif ([int]$port.CatMatchRank -gt 0) { 'cat_match' } else { 'manual' })))
    }
    $selectedPort = ''
    $preserveExplicitPort = ($previousPort -and ($previousExplicit -or $previousTextEdit) -and
        -not [string]::Equals($previousPort,$hriPort,[StringComparison]::OrdinalIgnoreCase) -and
        @($hriPorts | Where-Object { [string]::Equals([string]$_.PortName,$previousPort,[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0)
    $savedAvailable = @($allPorts | Where-Object {
        [string]::Equals([string]$_.PortName,$savedPort,[StringComparison]::OrdinalIgnoreCase) -and
        -not [bool]$_.IsHri -and [string]::Equals([string]$_.PortName,$hriPort,[StringComparison]::OrdinalIgnoreCase) -eq $false
    })
    if ($preserveExplicitPort) {
        $selectedPort = $previousPort
    } elseif (-not $savedConflict -and $savedPort -match '^COM[1-9][0-9]{0,2}$' -and $savedAvailable.Count -gt 0) {
        $selectedPort = ([string]$savedAvailable[0].PortName).ToUpperInvariant()
    } else {
        $ranked = @($allPorts | Where-Object { -not [bool]$_.IsHri -and [int]$_.CatMatchRank -gt 0 -and [string]$_.PortName -ine $hriPort } | Sort-Object { -[int]$_.CatMatchRank })
        if ($ranked.Count -gt 0) {
            $bestRank = [int]$ranked[0].CatMatchRank
            $best = @($ranked | Where-Object { [int]$_.CatMatchRank -eq $bestRank })
            if ($best.Count -eq 1) { $selectedPort = [string]$best[0].PortName }
        }
    }
    $wasProgrammatic = [bool]$script:radioCatProgrammaticControlUpdate
    $script:radioCatProgrammaticControlUpdate = $true
    try {
        $portControl.Items.Clear()
        foreach ($option in $options) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = [string]$option.Label
            $item.Tag = $option
            [void]$portControl.Items.Add($item)
        }
        $selectedItem = @($portControl.Items | Where-Object { $_.Tag.Value -ieq $selectedPort -and $_.Tag.IsAvailable } | Select-Object -First 1)[0]
        $portControl.SelectedItem = $selectedItem
        $portControl.Text = $selectedPort
    } finally { $script:radioCatProgrammaticControlUpdate = $wasProgrammatic }
    $script:radioCatPortSelectionExplicit = [bool]$preserveExplicitPort
    $script:radioCatPortTextEditExplicit = [bool]($preserveExplicitPort -and (-not $selectedItem -or $previousTextEdit))
    Register-UiRadioCatPortTextInput
    if ($baudControl) {
        $baudControl.SelectedItem = @($baudControl.Items | Where-Object { [int]$_.Tag -eq [int]$script:radioControlPreferences.baud_rate })[0]
    }
    $script:radioCatDeviceCatalogSignature = $controlSignature
    Update-UiRadioCatControls
}

function Get-UiRadioCatProperty {
    param([AllowNull()][object]$InputObject,[Parameter(Mandatory=$true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-UiRadioCatText {
    param([Parameter(Mandatory=$true)][string]$Name,[AllowEmptyString()][string]$Text)
    $control = Find-UiRadioCatControl -Name $Name
    if (-not $control) { return }
    if ($control -is [System.Windows.Controls.TextBlock] -or $control -is [System.Windows.Controls.TextBox]) {
        if ([string]$control.Text -cne $Text) { $control.Text = $Text }
    }
}

function Get-UiRadioCatSelectedPort {
    if (-not $script:mainWindow -or -not $script:radioCatModuleAvailable) { return $null }
    $control = Get-SettingsControl 'CatPortBox'
    $item = $control.SelectedItem
    $selectedPort = if ($item -is [System.Windows.Controls.ComboBoxItem] -and $item.Tag -and $item.Tag.IsAvailable) { [string]$item.Tag.Value } else { '' }
    $typedPort = ([string]$control.Text).Trim()
    $typedOverride = ($script:radioCatPortTextEditExplicit -and $typedPort -match '^(?i:COM)[1-9][0-9]{0,2}$' -and
        (-not $selectedPort -or -not [string]::Equals($typedPort,$selectedPort,[StringComparison]::OrdinalIgnoreCase)))
    $port = if ($typedOverride) { $typedPort } else { $selectedPort }
    if ($port -notmatch '^(?i:COM)[1-9][0-9]{0,2}$') { return $null }
    $port = $port.ToUpperInvariant()
    $catalog = $script:deviceCatalog
    if ($catalog) {
        $knownHri = @($catalog.hri_ports | Where-Object { [string]$_.PortName -ieq $port }).Count -gt 0
        if ($knownHri) { return $null }
    }
    return $port
}

function Get-UiRadioCatConnectionKey {
    $port = Get-UiRadioCatSelectedPort
    if (-not $port) { return '' }
    $baud = Get-UiRadioCatBaudRate
    $stopBits = Get-UiRadioCatStopBits
    if ($baud -notin @(4800,9600,19200,38400,115200) -or $stopBits -cnotin @('One','Two')) { return '' }
    return ('{0}|{1}|{2}' -f $port.ToUpperInvariant(),$baud,$stopBits)
}

function Test-UiRadioCatSelectedPortConflict {
    $port = Get-UiRadioCatSelectedPort
    $hriPort = Get-UiRadioCatHriPortForOperation
    return [bool]($port -and $hriPort -and [string]::Equals($port,$hriPort,[StringComparison]::OrdinalIgnoreCase))
}

function Test-UiRadioCatPortConflictWithHri {
    param([AllowEmptyString()][string]$HriPortName)
    $candidate = ([string]$HriPortName).Trim().ToUpperInvariant()
    if ($candidate -notmatch '^COM[1-9][0-9]{0,2}$') { return $false }
    $catPorts = New-Object 'System.Collections.Generic.List[string]'
    if ($script:radioCatSessionRequested) {
        $selected = Get-UiRadioCatSelectedPort
        if ($selected) { $catPorts.Add([string]$selected) }
        if ([string]$script:radioCatPollingConnectionKey -match '^(COM[1-9][0-9]{0,2})\|') {
            $catPorts.Add([string]$Matches[1])
        }
    }
    if ($script:radioCatOperationPowerShell -and [string]$script:radioCatOperationPortName -match '^COM[1-9][0-9]{0,2}$') {
        $catPorts.Add(([string]$script:radioCatOperationPortName).ToUpperInvariant())
    }
    return [bool](@($catPorts | Where-Object { [string]::Equals([string]$_,$candidate,[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
}

function Get-UiHriPortName {
    if ($script:activeHriPortName -match '^COM[1-9][0-9]{0,2}$') { return $script:activeHriPortName.ToUpperInvariant() }
    foreach ($profile in @($script:activeProfile,$script:effectiveProfile,$script:storedProfile)) {
        if ($profile -and $profile.devices -and [string]$profile.devices.serial_port -match '^COM[1-9][0-9]{0,2}$') {
            return ([string]$profile.devices.serial_port).ToUpperInvariant()
        }
    }
    if ($script:deviceCatalog -and @($script:deviceCatalog.hri_ports).Count -eq 1) {
        $port = [string]$script:deviceCatalog.hri_ports[0].PortName
        if ($port -match '^COM[1-9][0-9]{0,2}$') { return $port.ToUpperInvariant() }
    }
    return ''
}

function Test-UiRadioCatRunIdle {
    param([switch]$RequireFreshStatus)
    if (-not $script:supervisor -or $script:supervisor.HasExited) { return $true }
    if (-not $script:latestStatus -or $script:lastStatusUtc -eq [DateTime]::MinValue) { return $false }
    if ($RequireFreshStatus -or $script:supervisor) {
        if (([DateTime]::UtcNow - $script:lastStatusUtc).TotalMilliseconds -gt 3000) { return $false }
    }
    $status = $script:latestStatus
    foreach ($name in @('ptt_gate_ready','ptt_gate_tx_active','ptt_last_state','current_call_valid','receive_media_state',
            'rx_queue_bursts','rx_queue_playback_frames','rx_queue_unconfirmed_playback_frames','rx_buffered_receive_frames')) {
        if ($null -eq $status.PSObject.Properties[$name]) { return $false }
    }
    if ($status.ptt_gate_ready -isnot [bool] -or $status.ptt_gate_tx_active -isnot [bool] -or
        $status.current_call_valid -isnot [bool] -or [string]$status.ptt_last_state -cne 'released' -or
        [bool]$status.ptt_gate_tx_active -or [bool]$status.current_call_valid -or
        [string]$status.receive_media_state -cnotin @('idle','filtered')) { return $false }
    foreach ($name in @('rx_queue_bursts','rx_queue_playback_frames','rx_queue_unconfirmed_playback_frames','rx_buffered_receive_frames')) {
        $value = [uint64]0
        if ($status.PSObject.Properties[$name].Value -is [bool] -or
            -not [uint64]::TryParse([string]$status.PSObject.Properties[$name].Value,[Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or $value -ne 0) { return $false }
    }
    return $true
}

function Test-UiRadioCatHriSerialOpen {
    if (-not $script:supervisor -or $script:supervisor.HasExited -or -not $script:latestStatus -or
        $script:lastStatusUtc -eq [DateTime]::MinValue -or ([DateTime]::UtcNow - $script:lastStatusUtc).TotalMilliseconds -gt 3000) { return $false }
    $serialOpen = $script:latestStatus.PSObject.Properties['hri_serial_open']
    return [bool]($serialOpen -and $serialOpen.Value -is [bool] -and $serialOpen.Value)
}

function Test-UiRadioCatHasLiveCore {
    return [bool]($script:supervisor -and -not $script:supervisor.HasExited)
}

function Test-UiRadioCatHriReady {
    if (-not (Test-UiRadioCatHriSerialOpen)) { return $false }
    $ready = $script:latestStatus.PSObject.Properties['hri_ready']
    return [bool]($ready -and $ready.Value -is [bool] -and $ready.Value)
}

function Get-UiRadioCatHriPortForOperation {
    if (-not $script:supervisor -or $script:supervisor.HasExited) { return '' }
    if ($script:activeHriPortName -match '^COM[1-9][0-9]{0,2}$') { return $script:activeHriPortName.ToUpperInvariant() }
    return (Get-UiHriPortName)
}

function Get-UiRadioCatObservedValue {
    param([AllowNull()][object]$Observed,[Parameter(Mandatory=$true)][string]$Name)
    $field = Get-UiRadioCatProperty -InputObject $Observed -Name $Name
    if ($null -eq $field) { return $null }
    $value = Get-UiRadioCatProperty -InputObject $field -Name 'value'
    $source = Get-UiRadioCatProperty -InputObject $field -Name 'source'
    $updated = Get-UiRadioCatProperty -InputObject $field -Name 'updated_at_utc'
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$source) -or [string]::IsNullOrWhiteSpace([string]$updated)) { return $null }
    $parsedTime = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$updated,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsedTime)) { return $null }
    return [pscustomobject]@{ value=$value; source=[string]$source; updated_at_utc=$parsedTime.ToUniversalTime() }
}

function Merge-UiRadioCatObserved {
    param([AllowNull()][object]$Existing,[AllowNull()][object]$Fresh)
    if ($null -eq $Existing) { return $Fresh }
    if ($null -eq $Fresh) { return $Existing }
    $merged = [ordered]@{}
    foreach ($property in $Existing.PSObject.Properties) { $merged[[string]$property.Name] = $property.Value }
    foreach ($property in $Fresh.PSObject.Properties) {
        $field = $property.Value
        if ($null -eq $field -or $null -eq $field.PSObject.Properties['value']) { continue }
        if ($null -eq $field.value -or [string]::IsNullOrWhiteSpace([string]$field.source) -or
            [string]::IsNullOrWhiteSpace([string]$field.updated_at_utc)) { continue }
        $merged[[string]$property.Name] = $field
    }
    return [pscustomobject]$merged
}

function Format-UiRadioCatUtcTime {
    param([Parameter(Mandatory=$true)][DateTimeOffset]$Value)
    return $Value.ToLocalTime().ToString('HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
}

function Format-UiFrequencyMHz {
    param([Parameter(Mandatory=$true)][long]$FrequencyHz)
    return ([decimal]$FrequencyHz / [decimal]1000000).ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
}

function Set-UiRadioCatPowerSliderRange {
    param([Parameter(Mandatory=$true)][ValidateRange(5,50)][int]$Maximum)
    if (-not $script:radioControlPreferences) { return }
    $slider = Find-UiRadioCatControl -Name 'CatPowerSlider'
    if (-not $slider) { return }
    $targetWatts = [int]$script:radioControlPreferences.desired_power_watts
    $observedPower = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'power'
    if ($null -eq $script:radioCatEditDraft.power -and $observedPower -and $observedPower.value -and
        [int]$observedPower.value.watts -ge 5 -and [int]$observedPower.value.watts -le $Maximum) {
        $targetWatts = [int]$observedPower.value.watts
    }
    $needsChoice = ($targetWatts -gt $Maximum)
    $draftWatts = $null
    if ($script:radioCatEditDraft -and $null -ne $script:radioCatEditDraft.power) {
        $draftWatts = [int]$script:radioCatEditDraft.power
        $needsChoice = ($draftWatts -gt $Maximum -or $draftWatts -lt 5)
    }
    $sliderWatts = if ($null -ne $draftWatts) { $draftWatts } else { $targetWatts }
    $targetValue = if ($needsChoice) { 5.0 } else { [double]$sliderWatts }
    $rangeChanged = ([double]$slider.Minimum -ne 5.0 -or [double]$slider.Maximum -ne [double]$Maximum -or
        [double]$slider.Value -ne $targetValue)
    $script:radioCatPowerNeedsUserChoice = $needsChoice
    if (-not $rangeChanged) {
        $text = if ($needsChoice) {
            '目标功率 {0} W；当前范围 5–{1} W，请选定合法值后应用' -f $sliderWatts,$Maximum
        } else { '目标功率 {0} W' -f $sliderWatts }
        Set-UiRadioCatText -Name 'CatDesiredPowerText' -Text $text
        return
    }
    $wasLoading = [bool]$script:loadingRadioCatSettings
    $wasUpdating = [bool]$script:radioCatProgrammaticControlUpdate
    $oldTag = $slider.Tag
    try {
        $script:loadingRadioCatSettings = $true
        $script:radioCatProgrammaticControlUpdate = $true
        $slider.Tag = '__radio_cat_programmatic__'
        if ([double]$slider.Minimum -ne 5.0) { $slider.Minimum = 5.0 }
        if ([double]$slider.Maximum -ne [double]$Maximum) { $slider.Maximum = [double]$Maximum }
        if ([double]$slider.Value -ne $targetValue) { $slider.Value = $targetValue }
    } finally {
        $script:radioCatProgrammaticControlUpdate = $wasUpdating
        $slider.Tag = $oldTag
        $script:loadingRadioCatSettings = $wasLoading
    }
    $text = if ($needsChoice) {
        '目标功率 {0} W；当前范围 5–{1} W，请选定合法值后应用' -f $sliderWatts,$Maximum
    } else { '目标功率 {0} W' -f $sliderWatts }
    Set-UiRadioCatText -Name 'CatDesiredPowerText' -Text $text
}

function ConvertFrom-UiFrequencyMHz {
    param([Parameter(Mandatory=$true)][string]$Text)
    $value = $Text.Trim()
    if ($value -cnotmatch '^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,6})?$') {
        throw 'MAIN VFO 频率必须使用 MHz 十进制数，最多 6 位小数。'
    }
    $mhz = [decimal]0
    if (-not [decimal]::TryParse($value,[Globalization.NumberStyles]::AllowDecimalPoint,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$mhz)) { throw 'MAIN VFO 频率数值无效。' }
    $hzDecimal = $mhz * [decimal]1000000
    if ($hzDecimal -ne [decimal]::Truncate($hzDecimal) -or $hzDecimal -lt 30000 -or $hzDecimal -gt 470000000) {
        throw 'MAIN VFO 频率必须是整数 Hz，范围为 0.030000 到 470 MHz。'
    }
    return [long]$hzDecimal
}

function Update-UiRadioCatObservationDisplay {
    if (-not $script:mainWindow -and -not $script:settingsWindow) { return }
    $panel = Find-UiRadioCatControl -Name 'CatObservedPanel'
    if ($panel) {
        $panelVisibility = if ($script:radioCatModuleAvailable) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        if ($panel.Visibility -ne $panelVisibility) { $panel.Visibility = $panelVisibility }
    }
    if (-not $script:radioCatObserved) {
        Set-UiRadioCatText -Name 'CatObservedMainModeText' -Text ''
        Set-UiRadioCatText -Name 'CatObservedFrequencyText' -Text ''
        Set-UiRadioCatText -Name 'CatObservedPowerText' -Text ''
        return
    }
    $mainMode = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'main_mode'
    $mainFrequency = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'main_frequency_hz'
    $power = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'power'
    if ($mainMode) {
        Set-UiRadioCatText -Name 'CatObservedMainModeText' -Text ([string]$mainMode.value.mode)
        if (-not $script:radioCatEditDraft -or $null -eq $script:radioCatEditDraft.mode) {
            $script:radioCatProgrammaticControlUpdate = $true
            try {
                $modeBox = Find-UiRadioCatControl -Name 'CatMainModeBox'
                if ($modeBox) { $modeBox.SelectedItem = @($modeBox.Items | Where-Object { [string]$_.Tag -ceq [string]$mainMode.value.mode })[0] }
            } finally { $script:radioCatProgrammaticControlUpdate = $false }
        }
    }
    if ($mainFrequency) {
        $frequencyMHz = Format-UiFrequencyMHz -FrequencyHz ([long]$mainFrequency.value)
        Set-UiRadioCatText -Name 'CatObservedFrequencyText' -Text ($frequencyMHz + ' MHz')
        if (-not $script:radioCatEditDraft -or $null -eq $script:radioCatEditDraft.frequency) {
            $script:radioCatProgrammaticControlUpdate = $true
            try {
                $frequencyBox = Find-UiRadioCatControl -Name 'CatMainFrequencyMHzBox'
                if ($frequencyBox -and [string]$frequencyBox.Text -cne $frequencyMHz) { $frequencyBox.Text = $frequencyMHz }
            }
            finally { $script:radioCatProgrammaticControlUpdate = $false }
        }
    }
    if ($power) {
        $value = $power.value
        Set-UiRadioCatText -Name 'CatObservedPowerText' -Text ('{0} W' -f [int]$value.watts)
        $capabilities = Get-UiRadioCatProperty -InputObject $script:radioCatResult -Name 'capabilities'
        $powerCapability = Get-UiRadioCatProperty -InputObject $capabilities -Name 'set_power'
        $maximum = Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts'
        if ($maximum -is [int] -or $maximum -is [long]) {
            Set-UiRadioCatPowerSliderRange -Maximum ([int]$maximum)
        } else {
            $actualMaximum = if ([string]$value.path -ceq 'FieldHead') { 10 } else { 50 }
            Set-UiRadioCatPowerSliderRange -Maximum $actualMaximum
        }
    }
}

function Update-UiRadioCatControls {
    if (-not $script:mainWindow -and -not $script:settingsWindow) { return }
    Set-UiRadioCatControlVisibility -Name 'RadioCatPanel' -Visibility ([System.Windows.Visibility]::Visible)
    Set-UiRadioCatControlVisibility -Name 'CatOperatingPanel' -Visibility ([System.Windows.Visibility]::Visible)
    if (-not $script:radioCatModuleAvailable) {
        foreach ($name in @('CatPortBox','CatBaudRateBox','CatMainModeBox','ApplyCatModeButton',
                'CatMainFrequencyMHzBox','ApplyCatFrequencyButton','CatPowerSlider','ApplyCatPowerButton')) {
            Set-UiRadioCatControlEnabled -Name $name -Enabled $false
        }
        Set-UiRadioCatText -Name 'CatSessionStatusText' -Text 'CAT 模块不可用'
        if (Get-Command -Name 'Set-ConnectionButtonState' -ErrorAction SilentlyContinue) { Set-ConnectionButtonState }
        return
    }
    if ($script:radioControlPreferencesError) {
        foreach ($name in @('CatPortBox','CatBaudRateBox','CatMainModeBox','ApplyCatModeButton',
                'CatMainFrequencyMHzBox','ApplyCatFrequencyButton','CatPowerSlider','ApplyCatPowerButton')) {
            Set-UiRadioCatControlEnabled -Name $name -Enabled $false
        }
        return
    }
    $writeBusy = ($script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -cne 'query')
    $actionPending = [bool]($script:radioCatQueuedAction -or $script:radioModeApplyAfterStop -or $script:radioCatPendingModeFrequencyRequest)
    $editBusy = ($writeBusy -or $actionPending -or $script:radioCatSessionShutdown)
    $coreActive = [bool]($script:supervisor -and -not $script:supervisor.HasExited)
    foreach ($name in @('CatPortBox','CatBaudRateBox')) {
        Set-UiRadioCatControlEnabled -Name $name -Enabled (-not $coreActive -and -not $script:radioCatSessionRequested -and
            -not $script:radioCatOperationPowerShell -and -not $script:radioCatSessionShutdown)
    }
    foreach ($name in @('CatMainModeBox','CatMainFrequencyMHzBox','CatPowerSlider')) {
        Set-UiRadioCatControlEnabled -Name $name -Enabled (-not $editBusy)
    }
    $port = Get-UiRadioCatSelectedPort
    $portReady = ($port -and $port -match '^(?i:COM)[1-9][0-9]{0,2}$')
    $connectionKey = Get-UiRadioCatConnectionKey
    $observationMatchesConnection = ($connectionKey -and $script:radioCatObservedConnectionKey -and
        [string]::Equals($connectionKey,$script:radioCatObservedConnectionKey,[StringComparison]::OrdinalIgnoreCase))
    $confirmedObservationPermit = ($script:radioCatResult -and [string]$script:radioCatResult.status -ceq 'confirmed' -and
        $observationMatchesConnection)
    $hriPort = Get-UiHriPortName
    $portConflict = $port -and $hriPort -and [string]::Equals($port,$hriPort,[StringComparison]::OrdinalIgnoreCase)
    $idle = Test-UiRadioCatRunIdle -RequireFreshStatus
    $modeBox = Get-SettingsControl 'CatMainModeBox'
    $modeSelected = ($modeBox.SelectedItem -is [System.Windows.Controls.ComboBoxItem] -and
        [string]$modeBox.SelectedItem.Tag -cin @('FM','FM-N','C4FM-DN','C4FM-VW'))
    $frequencyHz = [long]0
    $frequencyValid = $false
    try { $frequencyHz = ConvertFrom-UiFrequencyMHz -Text (Get-SettingsControl 'CatMainFrequencyMHzBox').Text; $frequencyValid = $true } catch { }
    $buttonText = if ($script:supervisor -and -not $script:supervisor.HasExited) { '断开并应用 MAIN 模式' } else { '应用 MAIN 模式' }
    $modeButton = Find-UiRadioCatControl -Name 'ApplyCatModeButton'
    if ($modeButton -and [string]$modeButton.Content -cne $buttonText) { $modeButton.Content = $buttonText }
    Set-UiRadioCatControlEnabled -Name 'ApplyCatModeButton' -Enabled (-not $editBusy -and $portReady -and -not $portConflict -and $modeSelected -and $confirmedObservationPermit -and $idle)
    $frequencyButtonText = if ($script:supervisor -and -not $script:supervisor.HasExited) { '断开并应用 MAIN 频率' } else { '应用 MAIN 频率' }
    $frequencyButton = Find-UiRadioCatControl -Name 'ApplyCatFrequencyButton'
    if ($frequencyButton -and [string]$frequencyButton.Content -cne $frequencyButtonText) { $frequencyButton.Content = $frequencyButtonText }
    Set-UiRadioCatControlEnabled -Name 'ApplyCatFrequencyButton' -Enabled (-not $editBusy -and $portReady -and -not $portConflict -and $frequencyValid -and $confirmedObservationPermit -and $idle)

    $powerAllowed = $false
    $powerMaximum = 50
    $powerCapability = $null
    $currentPower = $null
    if ($script:radioCatResult) {
        $powerCapability = Get-UiRadioCatProperty -InputObject (Get-UiRadioCatProperty -InputObject $script:radioCatResult -Name 'capabilities') -Name 'set_power'
        $maximum = Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts'
        $currentPower = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'power'
        if ($currentPower -and ($maximum -is [int] -or $maximum -is [long])) { $powerMaximum = [int]$maximum }
    }
    if (-not $currentPower) { $currentPower = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'power' }
    if ($currentPower -and $currentPower.value -and -not $script:radioCatResult) {
        $powerMaximum = if ([string]$currentPower.value.path -ceq 'FieldHead') { 10 } else { 50 }
    }
    Set-UiRadioCatPowerSliderRange -Maximum $powerMaximum
    if ($script:radioCatResult) {
        $maximum = Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts'
        if ([string]$script:radioCatResult.status -ceq 'confirmed' -and
            $powerCapability -and [bool]$powerCapability.available -and $currentPower -and $observationMatchesConnection -and ($maximum -is [int] -or $maximum -is [long])) {
            $powerMaximum = [int]$maximum
            $powerAllowed = ([int](Get-SettingsControl 'CatPowerSlider').Value -ge 5 -and
                [int](Get-SettingsControl 'CatPowerSlider').Value -le $powerMaximum -and
                (-not ($script:supervisor -and -not $script:supervisor.HasExited) -or $idle))
        }
    }
        Set-UiRadioCatControlEnabled -Name 'CatPowerSlider' -Enabled (-not $editBusy)
    $hasPowerDraft = ($script:radioCatEditDraft -and $null -ne $script:radioCatEditDraft.power)
    Set-UiRadioCatControlEnabled -Name 'ApplyCatPowerButton' -Enabled (-not $editBusy -and $portReady -and -not $portConflict -and
        $observationMatchesConnection -and $powerAllowed -and $hasPowerDraft -and -not $script:radioCatPowerNeedsUserChoice)
    Update-UiRadioCatSessionControls
    Update-UiRadioCatCoreActionGate
}

function Request-StopUiRadioCatOperation {
    param([string]$Reason)
    if (-not $script:radioCatOperationPowerShell -or -not $script:radioCatOperationAsync) { return $false }
    if ($script:radioCatOperationStopAsync) { return $true }
    $script:radioCatOperationCancelled = $true
    $script:radioCatOperationCancelReason = if ($Reason) { $Reason } else { 'cancelled' }
    $script:radioCatOperationStopStartedUtc = [DateTime]::UtcNow
    try {
        $script:radioCatOperationStopAsync = $script:radioCatOperationPowerShell.BeginStop($null,$null)
    } catch {
        if ($script:radioCatOperationAsync.IsCompleted) { return $true }
        throw
    }
    return $true
}

function Test-UiRadioCatResult {
    param([Parameter(Mandatory=$true)][object]$Result,[Parameter(Mandatory=$true)][string]$ExpectedOperation,[Parameter(Mandatory=$true)][string]$ExpectedPort)
    if ($Result -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $required = @('schema_version','operation','status','source','port_name','port_role','started_at_utc','updated_at_utc',
        'desired','prior','observed','capabilities','cleanup_status','error_code','error_message')
    $actual = @($Result.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $required.Count -or @($required | Where-Object { $actual -cnotcontains $_ }).Count -gt 0 -or
        @($actual | Where-Object { $required -cnotcontains $_ }).Count -gt 0) { return $false }
    if ($Result.schema_version -is [bool] -or [int]$Result.schema_version -ne 1 -or
        [string]$Result.operation -cne $ExpectedOperation -or
        [string]$Result.status -cnotin @('confirmed','busy','identity_mismatch','rejected','mismatch','unknown') -or
        [string]$Result.port_role -cne 'CAT-1' -or
        -not [string]::Equals([string]$Result.port_name,$ExpectedPort,[StringComparison]::OrdinalIgnoreCase) -or
        [string]$Result.cleanup_status -cnotin @('closed','close_failed','not_opened')) { return $false }
    if ([string]$Result.status -ceq 'confirmed' -and [string]$Result.cleanup_status -cne 'closed') { return $false }
    if ([string]$Result.status -ceq 'confirmed') {
        $identity = Get-UiRadioCatObservedValue -Observed $Result.observed -Name 'radio_id'
        if (-not $identity -or [string]$identity.value -cne '0840') { return $false }
        if ([string]$ExpectedOperation -ceq 'query') {
            foreach ($name in @('auto_information_enabled','tx_state','main_frequency_hz','sub_frequency_hz','main_mode','sub_mode','power')) {
                if (-not (Get-UiRadioCatObservedValue -Observed $Result.observed -Name $name)) { return $false }
            }
            if ([string]$Result.source -cnotin @('FTX-1 CAT-1','CAT test transport')) { return $false }
        }
    }
    return $true
}

function Test-UiRadioCatFreshQueryAuthorization {
    param(
        [Parameter(Mandatory=$true)][object]$Result,
        [Parameter(Mandatory=$true)][string]$PortName,
        [Parameter(Mandatory=$true)][string]$ConnectionKey,
        [Parameter(Mandatory=$true)][int]$Generation
    )
    if ($Generation -ne [int]$script:radioCatSessionGeneration -or
        -not [string]::Equals((Get-UiRadioCatConnectionKey),$ConnectionKey,[StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-UiRadioCatResult -Result $Result -ExpectedOperation 'query' -ExpectedPort $PortName) -or
        [string]$Result.status -cne 'confirmed' -or [string]$Result.cleanup_status -cne 'closed') { return $false }
    $identity = Get-UiRadioCatObservedValue -Observed $Result.observed -Name 'radio_id'
    $txState = Get-UiRadioCatObservedValue -Observed $Result.observed -Name 'tx_state'
    if (-not $identity -or [string]$identity.value -cne '0840' -or -not $txState -or
        $txState.value -isnot [int] -or [int]$txState.value -ne 0) { return $false }
    $started = [DateTimeOffset]::MinValue
    $finished = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Result.started_at_utc,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$started) -or
        -not [DateTimeOffset]::TryParse([string]$Result.updated_at_utc,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$finished) -or $finished -lt $started) { return $false }
    foreach ($field in @($identity,$txState)) {
        if ($field.updated_at_utc -lt $started -or $field.updated_at_utc -gt $finished.AddSeconds(2)) { return $false }
    }
    return $true
}

function New-UiRadioCatActionRequest {
    param([Parameter(Mandatory=$true)][ValidateSet('query','setPower','setMode','setFrequency')][string]$Operation)
    $port = Get-UiRadioCatSelectedPort
    $connectionKey = Get-UiRadioCatConnectionKey
    if (-not $port -or -not $connectionKey) { throw '请选择有效 CAT 串口和波特率。' }
    if (Test-UiRadioCatSelectedPortConflict) { throw 'CAT-1 与当前 HRI 串口不能共用。' }
    $request = [ordered]@{
        operation=$Operation
        port_name=$port
        baud_rate=[int](Get-UiRadioCatBaudRate)
        stop_bits=[string](Get-UiRadioCatStopBits)
        connection_key=$connectionKey
        generation=[int]$script:radioCatSessionGeneration
        hri_port=[string](Get-UiRadioCatHriPortForOperation)
        created_at_utc=[DateTimeOffset]::UtcNow
    }
    if ($Operation -ceq 'setPower') {
        if (-not $script:radioCatEditDraft -or $null -eq $script:radioCatEditDraft.power) { throw '请先调整功率滑块，再明确应用该草稿值。' }
        if ($script:radioCatPowerNeedsUserChoice) { throw '目标功率超出电台当前范围；请先明确选择合法值。' }
        $request.power_watts = [int]$script:radioCatEditDraft.power
    } elseif ($Operation -ceq 'setMode') {
        $selected = (Get-SettingsControl 'CatMainModeBox').SelectedItem
        if ($selected -isnot [System.Windows.Controls.ComboBoxItem] -or [string]$selected.Tag -cnotin @('FM','FM-N','C4FM-DN','C4FM-VW')) {
            throw '请选择明确的 MAIN 调制模式。'
        }
        $request.side = 'Main'
        $request.mode = [string]$selected.Tag
    } elseif ($Operation -ceq 'setFrequency') {
        $request.side = 'Main'
        $request.frequency_hz = [long](ConvertFrom-UiFrequencyMHz -Text (Get-SettingsControl 'CatMainFrequencyMHzBox').Text)
    }
    return [pscustomobject]$request
}

function Start-UiRadioCatQueuedActionQuery {
    param([Parameter(Mandatory=$true)][object]$Request)
    if (-not $script:radioCatQueuedAction) { return $false }
    try {
        Start-UiRadioCatOperation -Operation 'query' -PortNameOverride ([string]$Request.port_name) `
            -BaudRateOverride ([int]$Request.baud_rate) -StopBitsOverride ([string]$Request.stop_bits) `
            -HriPortNameOverride ([string]$Request.hri_port)
        return $true
    } catch {
        $script:radioCatQueuedAction = $null
        Set-UiRadioCatNotice -Text 'CAT 设置没有执行；无法先完成当前端口读取。'
        Update-UiRadioCatControls
        return $false
    }
}

function Invoke-UiRadioCatFrozenModeFrequencyApply {
    param([Parameter(Mandatory=$true)][object]$Request)
    if ([int]$Request.generation -ne [int]$script:radioCatSessionGeneration -or
        -not [string]::Equals((Get-UiRadioCatConnectionKey),[string]$Request.connection_key,[StringComparison]::OrdinalIgnoreCase)) {
        Set-UiRadioCatNotice -Text 'CAT 端口或会话已变化；已取消 MAIN 设置。'
        return $false
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited -and -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
        Set-UiRadioCatNotice -Text '核心状态未确认电台空闲；已取消 MAIN 设置。'
        return $false
    }
    # A live supervisor may still be opening HRI even when its latest status says
    # the serial handle is closed. Keep MAIN mode/frequency writes behind the
    # existing stop -> fresh CAT query -> write transaction for every live core.
    if (Test-UiRadioCatHasLiveCore) {
        if ($script:radioCatOperationPowerShell -or $script:stopTask -or $script:preparationStarted) {
            Set-UiRadioCatNotice -Text '当前有 HRI 或 CAT 操作正在收尾；已取消 MAIN 设置。'
            return $false
        }
        $script:radioModePreviousHriPortName = [string]$Request.hri_port
        $script:radioModeApplyAfterStop = [pscustomobject]@{
            operation=[string]$Request.operation
            side=[string]$Request.side
            mode=[string]$Request.mode
            frequency_hz=[long]$Request.frequency_hz
            cat_port=[string]$Request.port_name
            hri_port=[string]$Request.hri_port
            baud_rate=[int]$Request.baud_rate
            stop_bits=[string]$Request.stop_bits
            cat_generation=[int]$Request.generation
            connection_key=[string]$Request.connection_key
        }
        $script:closingAfterStop = $false
        $script:reconnectAfterStop = $false
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-MainText -Name 'FooterText' -Text '正在停止 HRI；确认核心退出并释放串口后重新读取 CAT 并应用 MAIN 设置。'
        Set-UiRadioCatNotice -Text '正在停止 HRI；确认退出前不会应用 MAIN 设置。'
        Update-UiRadioCatControls
        return $true
    }
    try {
        if ([string]$Request.operation -ceq 'setMode') {
            Start-UiRadioCatOperation -Operation 'setMode' -Side ([string]$Request.side) -Mode ([string]$Request.mode) `
                -HriPortNameOverride '' -PortNameOverride ([string]$Request.port_name) -BaudRateOverride ([int]$Request.baud_rate) `
                -StopBitsOverride ([string]$Request.stop_bits)
        } else {
            Start-UiRadioCatOperation -Operation 'setFrequency' -Side ([string]$Request.side) -FrequencyHz ([long]$Request.frequency_hz) `
                -HriPortNameOverride '' -PortNameOverride ([string]$Request.port_name) -BaudRateOverride ([int]$Request.baud_rate) `
                -StopBitsOverride ([string]$Request.stop_bits)
        }
        return $true
    } catch {
        Set-UiRadioCatNotice -Text 'MAIN 设置未执行；请重新读取 CAT 状态后重试。'
        Update-UiRadioCatControls
        return $false
    }
}

function Complete-UiRadioCatQueuedAction {
    param([AllowNull()][object]$QueryResult,[bool]$QueryConfirmed)
    if (-not $script:radioCatQueuedAction) { return $false }
    $request = $script:radioCatQueuedAction
    if ([string]$request.operation -ceq 'query') {
        $sameActionContext = ([int]$request.generation -eq [int]$script:radioCatSessionGeneration -and
            [string]::Equals((Get-UiRadioCatConnectionKey),[string]$request.connection_key,[StringComparison]::OrdinalIgnoreCase))
        if ($sameActionContext -and $QueryConfirmed -and [string]$QueryResult.operation -ceq 'query') {
            $script:radioCatQueuedAction = $null
            Set-UiRadioCatNotice -Text ''
            Update-UiRadioCatControls
            return $true
        }
        if ($sameActionContext) {
            $script:radioCatQueuedAction = $null
            try {
                Start-UiRadioCatOperation -Operation 'query' -PortNameOverride ([string]$request.port_name) `
                    -BaudRateOverride ([int]$request.baud_rate) -StopBitsOverride ([string]$request.stop_bits) `
                    -HriPortNameOverride ([string]$request.hri_port)
            } catch {
                Set-UiRadioCatNotice -Text '用户请求的读取没有完成；请检查 CAT 端口后重试。'
                Update-UiRadioCatControls
            }
            return $true
        }
    }
    if (-not $QueryConfirmed -or -not $QueryResult -or
        -not (Test-UiRadioCatFreshQueryAuthorization -Result $QueryResult -PortName ([string]$request.port_name) `
            -ConnectionKey ([string]$request.connection_key) -Generation ([int]$request.generation))) {
        $script:radioCatQueuedAction = $null
        Set-UiRadioCatNotice -Text 'CAT 状态读取失败或端口已变化；已取消设置，没有写入。'
        Update-UiRadioCatControls
        return $true
    }
    $script:radioCatQueuedAction = $null
    try {
        switch -CaseSensitive ([string]$request.operation) {
            'setPower' {
                $capability = Get-UiRadioCatProperty -InputObject (Get-UiRadioCatProperty -InputObject $QueryResult -Name 'capabilities') -Name 'set_power'
                $maximum = Get-UiRadioCatProperty -InputObject $capability -Name 'maximum_watts'
                if (-not $capability -or -not [bool]$capability.available -or
                    ($maximum -isnot [int] -and $maximum -isnot [long]) -or
                    [int]$request.power_watts -lt 5 -or [int]$request.power_watts -gt [int]$maximum) {
                    throw '新读取的功率路径不接受已冻结的目标功率。'
                }
                if ((Test-UiRadioCatHriSerialOpen) -and -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
                    throw '核心状态未确认电台空闲；设置已取消。'
                }
                Start-UiRadioCatOperation -Operation 'setPower' -PowerWatts ([int]$request.power_watts) `
                    -PortNameOverride ([string]$request.port_name) -BaudRateOverride ([int]$request.baud_rate) `
                    -StopBitsOverride ([string]$request.stop_bits) -HriPortNameOverride ([string]$request.hri_port)
            }
            'setMode' { [void](Invoke-UiRadioCatFrozenModeFrequencyApply -Request $request) }
            'setFrequency' { [void](Invoke-UiRadioCatFrozenModeFrequencyApply -Request $request) }
            default { throw 'CAT 用户动作类型无效。' }
        }
    } catch {
        Set-UiRadioCatNotice -Text ('CAT 设置已取消，没有发送写入：' + $_.Exception.Message)
        Update-UiRadioCatControls
    }
    return $true
}

function Test-UiRadioCatFreshPowerObservation {
    param([Parameter(Mandatory=$true)][object]$Result)
    if ([string]$Result.cleanup_status -cne 'closed' -or
        [string]$Result.source -cnotin @('FTX-1 CAT-1','CAT test transport') -or
        -not [string]::Equals([string]$Result.port_name,[string]$script:radioCatOperationPortName,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $observed = Get-UiRadioCatProperty -InputObject $Result -Name 'observed'
    $identity = Get-UiRadioCatProperty -InputObject $observed -Name 'radio_id'
    $power = Get-UiRadioCatProperty -InputObject $observed -Name 'power'
    if (-not $identity -or -not $power -or [string](Get-UiRadioCatProperty -InputObject $identity -Name 'source') -cne [string]$Result.source -or
        [string](Get-UiRadioCatProperty -InputObject $power -Name 'source') -cne [string]$Result.source) { return $false }
    $identityValue = Get-UiRadioCatProperty -InputObject $identity -Name 'value'
    $powerValue = Get-UiRadioCatProperty -InputObject $power -Name 'value'
    if ([string]$identityValue -cne '0840' -or -not $powerValue) { return $false }
    $path = [string](Get-UiRadioCatProperty -InputObject $powerValue -Name 'path')
    $watts = Get-UiRadioCatProperty -InputObject $powerValue -Name 'watts'
    if ($path -cnotin @('FieldHead','Spa1') -or $watts -isnot [int] -or [int]$watts -lt 5 -or [int]$watts -gt 50) { return $false }

    $start = [DateTimeOffset]::MinValue
    $finish = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Result.started_at_utc,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$start) -or
        -not [DateTimeOffset]::TryParse([string]$Result.updated_at_utc,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$finish) -or $finish -lt $start) { return $false }
    foreach ($field in @($identity,$power)) {
        $updated = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string](Get-UiRadioCatProperty -InputObject $field -Name 'updated_at_utc'),
                [Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$updated) -or
            $updated -lt $start -or $updated -gt $finish.AddSeconds(2)) { return $false }
    }
    $capabilities = Get-UiRadioCatProperty -InputObject $Result -Name 'capabilities'
    $powerCapability = Get-UiRadioCatProperty -InputObject $capabilities -Name 'set_power'
    $activePath = [string](Get-UiRadioCatProperty -InputObject $powerCapability -Name 'active_path')
    $maximum = Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts'
    $expectedMaximum = if ($path -ceq 'FieldHead') { 10 } else { 50 }
    return ($powerCapability -and $activePath -ceq $path -and $maximum -is [int] -and [int]$maximum -eq $expectedMaximum)
}

function Test-UiRadioCatRejectedPowerReadback {
    param([Parameter(Mandatory=$true)][object]$Result,[Parameter(Mandatory=$true)][string]$ExpectedPort)
    if ([string]$Result.operation -cne 'setPower' -or [string]$Result.status -cne 'rejected' -or
        [string]$Result.error_code -cne 'power_out_of_range' -or [string]$Result.cleanup_status -cne 'closed' -or
        [string]$Result.source -cnotin @('FTX-1 CAT-1','CAT test transport') -or
        -not [string]::Equals([string]$Result.port_name,$ExpectedPort,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $identity = Get-UiRadioCatObservedValue -Observed $Result.observed -Name 'radio_id'
    $power = Get-UiRadioCatObservedValue -Observed $Result.observed -Name 'power'
    if (-not $identity -or -not $power -or [string]$identity.value -cne '0840' -or
        [string]$identity.source -cne [string]$Result.source -or [string]$power.source -cne [string]$Result.source) { return $false }
    $path = [string](Get-UiRadioCatProperty -InputObject $power.value -Name 'path')
    $watts = Get-UiRadioCatProperty -InputObject $power.value -Name 'watts'
    $maximum = if ($path -ceq 'FieldHead') { 10 } elseif ($path -ceq 'Spa1') { 50 } else { 0 }
    if ($maximum -eq 0 -or $watts -isnot [int] -or [int]$watts -lt 5 -or [int]$watts -gt $maximum) { return $false }
    $capabilities = Get-UiRadioCatProperty -InputObject $Result -Name 'capabilities'
    $powerCapability = Get-UiRadioCatProperty -InputObject $capabilities -Name 'set_power'
    if (-not $powerCapability -or [string](Get-UiRadioCatProperty -InputObject $powerCapability -Name 'active_path') -cne $path -or
        (Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts') -isnot [int] -or
        [int](Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts') -ne $maximum) { return $false }
    $started = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Result.started_at_utc,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$started)) { return $false }
    $latestAllowed = [DateTimeOffset]::UtcNow.AddSeconds(2)
    foreach ($field in @($identity,$power)) {
        $updated = [DateTimeOffset]::MinValue
        $updatedValue = $field.updated_at_utc
        $updatedValid = $false
        if ($updatedValue -is [DateTimeOffset]) { $updated = $updatedValue; $updatedValid = $true }
        else { $updatedValid = [DateTimeOffset]::TryParse([string]$updatedValue,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$updated) }
        if (-not $updatedValid -or $updated -lt $started -or $updated -gt $latestAllowed) { return $false }
    }
    return $true
}

function Start-UiRadioCatOperation {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('query','setPower','setMode','setFrequency')][string]$Operation,
        [int]$PowerWatts,
        [string]$Mode,
        [long]$FrequencyHz,
        [ValidateSet('Main')][string]$Side='Main',
        [string]$HriPortNameOverride,
        [string]$PortNameOverride,
        [int]$BaudRateOverride,
        [string]$StopBitsOverride
    )
    if (-not $script:radioCatModuleAvailable) { throw 'FTX-1 CAT-1 模块当前不可用。' }
    if (-not (Test-UiRadioCatHardwareAccessAllowed)) { throw '当前隔离界面禁止 CAT 串口操作。' }
    if ($script:radioCatOperationPowerShell) { throw '另一项 CAT-1 操作尚未结束。' }
    if ($script:preparationStarted -or $script:prepareStopAsync) { throw '核心正在准备或取消连接；请等待设备检查完成。' }
    $port = if ($PSBoundParameters.ContainsKey('PortNameOverride')) { [string]$PortNameOverride } else { Get-UiRadioCatSelectedPort }
    if (-not $port) { throw '请选择或手动输入 CAT 串口 COM1–COM999。' }
    if ($port -notmatch '^(?i:COM)[1-9][0-9]{0,2}$') { throw 'CAT 串口必须是 COM1 到 COM999。' }
    $port = $port.ToUpperInvariant()
    $enumeratedHri = @()
    if ($script:deviceCatalog) {
        $enumeratedHri = @($script:deviceCatalog.hri_ports | Where-Object { [string]::Equals([string]$_.PortName,$port,[StringComparison]::OrdinalIgnoreCase) })
    }
    if ($enumeratedHri.Count -gt 0) { throw '所选串口已识别为 HRI，不能用于 CAT。' }
    $hriPort = if ($PSBoundParameters.ContainsKey('HriPortNameOverride')) { [string]$HriPortNameOverride } else { Get-UiRadioCatHriPortForOperation }
    if ($hriPort -and [string]::Equals($port,$hriPort,[StringComparison]::OrdinalIgnoreCase)) {
        throw ('CAT-1 与 HRI 不能共用 {0}。' -f $port)
    }
    if ($Operation -cin @('setPower','setMode','setFrequency') -and $script:supervisor -and -not $script:supervisor.HasExited -and
        -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
        throw '核心状态未确认电台空闲；设置操作已取消。'
    }
    if ($Operation -cin @('setMode','setFrequency')) {
        $candidateBaud = if ($PSBoundParameters.ContainsKey('BaudRateOverride')) { [int]$BaudRateOverride } else { [int](Get-UiRadioCatBaudRate) }
        $candidateStopBits = [string](Get-UiRadioCatStopBits)
        $candidateKey = '{0}|{1}|{2}' -f $port.ToUpperInvariant(),$candidateBaud,$candidateStopBits
        if (-not $script:radioCatResult -or [string]$script:radioCatResult.status -cne 'confirmed' -or
            -not [string]::Equals($candidateKey,[string]$script:radioCatObservedConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
            throw '没有当前 CAT 端口的已确认读取许可；请先重新读取电台状态。'
        }
    }
    if ($Operation -cin @('setMode','setFrequency') -and (Test-UiRadioCatHriSerialOpen)) {
        throw '请先停止 HRI 会话，再应用 MAIN 调制或频率。'
    }
    $baud = if ($PSBoundParameters.ContainsKey('BaudRateOverride')) { [int]$BaudRateOverride } else { [int](Get-UiRadioCatBaudRate) }
    $stopBits = [string](Get-UiRadioCatStopBits)
    if ($baud -notin @(4800,9600,19200,38400,115200) -or $stopBits -cnotin @('One','Two')) {
        throw 'CAT-1 串口格式不在模块允许范围内。'
    }
    $arguments = @{
        Operation = $Operation
        PortName = $port
        PortRole = 'CAT-1'
        HriPortName = $hriPort
        BaudRate = $baud
        StopBits = $stopBits
        TimeoutMs = 2500
    }
    if ($Operation -ceq 'setPower') { $arguments.PowerWatts = $PowerWatts }
    if ($Operation -ceq 'setMode') { $arguments.Side = $Side; $arguments.Mode = $Mode }
    if ($Operation -ceq 'setFrequency') { $arguments.Side = $Side; $arguments.FrequencyHz = $FrequencyHz }

    $script:radioCatOperationKind = $Operation
    $script:radioCatOperationPortName = $port
    $script:radioCatOperationBaudRate = $baud
    $script:radioCatOperationStopBits = $stopBits
    $script:radioCatOperationCancelled = $false
    $script:radioCatOperationCancelReason = ''
    $script:radioCatOperationStopAsync = $null
    $script:radioCatOperationStartedUtc = [DateTime]::UtcNow
    $script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
    $script:radioCatOperationSessionGeneration = [int]$script:radioCatSessionGeneration
    $script:radioCatOperationOwnerWindow = $script:mainWindow
    $script:radioCatOperationOrdinal = [int]$script:radioCatOperationOrdinal + 1
    $catHook = if ($script:uiTestHooks -and $script:uiTestHooks.CatOperation -is [scriptblock]) { $script:uiTestHooks.CatOperation.ToString() } else { '' }
    $hookContext = [pscustomobject]@{
        operation=$Operation
        parameters=$arguments
        ordinal=[int]$script:radioCatOperationOrdinal
        port=$port
        baud_rate=$baud
        stop_bits=$stopBits
    }
    $script:radioCatOperationPowerShell = [System.Management.Automation.PowerShell]::Create()
    $worker = {
        param([string]$ModulePath,[hashtable]$OperationParameters,[string]$HookScript,[object]$HookContext)
        $ErrorActionPreference = 'Stop'
        if ($HookScript) {
            $hook = [scriptblock]::Create($HookScript)
            & $hook $HookContext
            return
        }
        Import-Module -Name $ModulePath -Force
        Invoke-Ftx1CatOperation @OperationParameters
    }
    try {
        [void]$script:radioCatOperationPowerShell.AddScript($worker.ToString()).AddArgument($script:radioCatModulePath).AddArgument($arguments).AddArgument($catHook).AddArgument($hookContext)
        $script:radioCatOperationAsync = $script:radioCatOperationPowerShell.BeginInvoke()
        if ($Operation -ceq 'query' -and $script:radioCatSessionRequested -and
            -not $script:radioCatSessionConnected -and $script:radioCatSessionState -eq 'connecting') {
            Set-UiRadioCatSessionState -State 'polling'
        }
        Update-UiRadioCatControls
    } catch {
        if ($script:radioCatOperationPowerShell) { $script:radioCatOperationPowerShell.Dispose() }
        $script:radioCatOperationPowerShell = $null
        $script:radioCatOperationAsync = $null
        $script:radioCatOperationKind = ''
        throw
    }
}

function Complete-UiRadioCatOperation {
    if (-not $script:radioCatOperationPowerShell -or -not $script:radioCatOperationAsync) { return $false }
    if ($script:radioCatOperationKind -cin @('setPower','setMode','setFrequency') -and $script:supervisor -and
        -not $script:supervisor.HasExited -and -not $script:radioCatOperationCancelled -and
        -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
        $script:radioCatOperationCancelled = $true
        $script:radioCatOperationCancelReason = 'core_status_stale_or_busy'
        if (-not $script:radioCatOperationAsync.IsCompleted) {
            try { Request-StopUiRadioCatOperation -Reason $script:radioCatOperationCancelReason | Out-Null }
            catch { Add-UiEvent '核心空闲状态过期，取消 CAT 功率操作失败' }
        }
    }
    if (-not $script:radioCatOperationStopAsync -and -not $script:radioCatOperationAsync.IsCompleted -and
        ([DateTime]::UtcNow - $script:radioCatOperationStartedUtc).TotalMilliseconds -ge 3000) {
        try { Request-StopUiRadioCatOperation -Reason 'deadline' | Out-Null }
        catch { Add-UiEvent 'CAT-1 操作超出期限，已请求关闭串口' }
        return $false
    }
    if ($script:radioCatOperationStopAsync) {
        if (-not $script:radioCatOperationStopAsync.IsCompleted) {
            if (([DateTime]::UtcNow - $script:radioCatOperationStopStartedUtc).TotalMilliseconds -ge 3000 -and
                ($script:closingAfterStop -or $script:radioCatCloseMainAfterOperation -or $script:radioCatCloseSettingsAfterOperation)) {
                Add-UiEvent 'CAT-1 取消后 3 秒仍未确认串口清理；安全退出界面'
                [System.Environment]::Exit(2)
            }
            return $false
        }
    } elseif (-not $script:radioCatOperationAsync.IsCompleted) { return $false }

    $result = $null
    $failure = ''
    try {
        if ($script:radioCatOperationStopAsync) {
            try { $script:radioCatOperationPowerShell.EndStop($script:radioCatOperationStopAsync) } catch { }
        }
        try {
            $output = $script:radioCatOperationPowerShell.EndInvoke($script:radioCatOperationAsync)
            if ($output.Count -gt 0) { $result = $output[$output.Count - 1] }
        } catch { $failure = $_.Exception.Message }
        if (-not $failure -and $script:radioCatOperationPowerShell.HadErrors) {
            $failure = @($script:radioCatOperationPowerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '；'
        }
    } finally {
        if ($script:radioCatOperationPowerShell) { $script:radioCatOperationPowerShell.Dispose() }
        $script:radioCatOperationPowerShell = $null
        $script:radioCatOperationAsync = $null
        $script:radioCatOperationStopAsync = $null
        $script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
    }
    $operation = $script:radioCatOperationKind
    $port = [string]$script:radioCatOperationPortName
    $baud = [int]$script:radioCatOperationBaudRate
    $stopBits = [string]$script:radioCatOperationStopBits
    $operationConnectionKey = ('{0}|{1}|{2}' -f $port.ToUpperInvariant(),$baud,$stopBits)
    $operationGeneration = [int]$script:radioCatOperationSessionGeneration
    $activeConnectionKey = Get-UiRadioCatConnectionKey
    if ($script:radioCatOperationCancelled) {
        $failure = '操作已取消；结果未知。'
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    } elseif ($operationGeneration -ne [int]$script:radioCatSessionGeneration) {
        $failure = 'CAT会话已变化；丢弃旧worker结果。'
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    } elseif (-not $activeConnectionKey -or
        -not [string]::Equals($activeConnectionKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        $failure = '串口选择已变化；丢弃了旧读取结果。'
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    } elseif (-not $failure -and $result -and (Test-UiRadioCatResult -Result $result -ExpectedOperation $operation -ExpectedPort $port)) {
        if ([string]$result.cleanup_status -cne 'closed' -and [string]$result.status -ne 'rejected') {
            $failure = '串口关闭状态未确认；本次结果未知。'
            $script:radioCatLastOperationStatus = 'unknown'
            $script:radioCatResult = $null
        } elseif ([string]$result.status -ceq 'confirmed') {
            if ($script:radioCatObservedConnectionKey -and
                -not [string]::Equals([string]$script:radioCatObservedConnectionKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
                $script:radioCatObserved = $null
                $script:radioCatObservedPortName = ''
                $script:radioCatObservedConnectionKey = ''
            }
            $script:radioCatObserved = Merge-UiRadioCatObserved -Existing $script:radioCatObserved -Fresh $result.observed
            $script:radioCatObservedPortName = $port
            $script:radioCatObservedConnectionKey = $operationConnectionKey
            $script:radioCatObservedPortWasEnumerated = [bool](@($script:deviceCatalog.serial_ports | Where-Object {
                [string]::Equals([string]$_.PortName,$port,[StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0)
            if ($operation -ceq 'query') {
                $script:radioCatResult = $result
                $script:radioCatLastSuccessfulQueryUtc = [DateTime]::UtcNow
            } elseif ($operation -ceq 'setPower') {
                $script:radioCatResult = $result
                $confirmedPower = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'power'
                if ($confirmedPower) {
                    $script:radioControlPreferences.desired_power_watts = [int]$confirmedPower.value.watts
                    Set-UiRadioCatDraft -Field power -Value $null
                }
            } else {
                $script:radioCatResult = $null
                if ($operation -ceq 'setMode') { Set-UiRadioCatDraft -Field mode -Value $null }
                if ($operation -ceq 'setFrequency') { Set-UiRadioCatDraft -Field frequency -Value $null }
            }
            $script:radioCatLastOperationStatus = 'confirmed'
            Set-UiRadioCatLinkState -State 'connected'
        } else {
            $failure = if ($result.error_message) { [string]$result.error_message } else { '本次设置未获确认。' }
            $script:radioCatLastOperationStatus = [string]$result.status
            $script:radioCatResult = $null
            if ($operation -ceq 'query') { Set-UiRadioCatLinkState -State 'query_failed' }
            if ([string]$result.status -ceq 'identity_mismatch') {
                $script:radioCatObserved = $null
                $script:radioCatObservedPortName = ''
                $script:radioCatObservedConnectionKey = ''
                $script:radioCatObservedPortWasEnumerated = $false
            } elseif ($operation -ceq 'setPower' -and
                [string]::Equals((Get-UiRadioCatConnectionKey),$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase) -and
                (Test-UiRadioCatRejectedPowerReadback -Result $result -ExpectedPort $port)) {
                if ($script:radioCatObservedConnectionKey -and
                    -not [string]::Equals([string]$script:radioCatObservedConnectionKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
                    $script:radioCatObserved = $null
                    $script:radioCatObservedPortName = ''
                    $script:radioCatObservedConnectionKey = ''
                }
                $script:radioCatObserved = Merge-UiRadioCatObserved -Existing $script:radioCatObserved -Fresh $result.observed
                $script:radioCatObservedPortName = $port
                $script:radioCatObservedConnectionKey = $operationConnectionKey
                $script:radioCatObservedPortWasEnumerated = [bool](@($script:deviceCatalog.serial_ports | Where-Object {
                    [string]::Equals([string]$_.PortName,$port,[StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0)
                $script:radioCatResult = $result
            }
        }
    } elseif (-not $failure) {
        $failure = '返回的数据或端口身份没有通过检查。'
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    } else {
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    }
    if ($operation -ceq 'query' -and -not $script:radioCatOperationCancelled -and
        $script:radioCatLastOperationStatus -cne 'confirmed' -and $activeConnectionKey -and
        [string]::Equals($activeConnectionKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        Set-UiRadioCatLinkState -State 'query_failed'
    }
    if ($operation -ceq 'query' -and $operationGeneration -eq [int]$script:radioCatSessionGeneration -and
        $script:radioCatSessionRequested) {
        if ($script:radioCatLastOperationStatus -ceq 'confirmed' -and $script:radioCatResult -and
            [string]$script:radioCatResult.operation -ceq 'query') {
            $script:radioCatSessionConnected = $true
            $script:radioCatSessionError = ''
            Set-UiRadioCatSessionState -State 'connected'
        } elseif (-not $script:radioCatOperationCancelled) {
            $script:radioCatSessionConnected = $false
            $script:radioCatSessionError = if ($failure) { [string]$failure } else { 'CAT查询未确认' }
            Set-UiRadioCatSessionState -State 'error'
        }
    }
    if ($script:mainWindow -or $script:settingsWindow) {
        if ($script:radioCatLastOperationStatus -ceq 'confirmed') {
            Set-UiRadioCatNotice -Text ''
        } elseif ($script:radioCatOperationCancelled) {
            Set-UiRadioCatNotice -Text '操作已取消；结果未知。'
        } elseif ($operation -ceq 'query') {
            Set-UiRadioCatNotice -Text '暂时无法读取电台状态；CAT会话保留并等待下一次轮询。'
        } else {
            Set-UiRadioCatNotice -Text '设置未获确认；请重新读取电台状态。'
        }
        Update-UiRadioCatObservationDisplay
        Update-UiRadioCatControls
    }
    $script:radioCatOperationKind = ''
    $script:radioCatOperationPortName = ''
    $script:radioCatOperationBaudRate = 0
    $script:radioCatOperationStopBits = ''
    $script:radioCatOperationCancelled = $false
    $script:radioCatOperationCancelReason = ''
    $script:radioCatOperationSessionGeneration = 0
    $script:radioCatOperationOwnerWindow = $null
    $script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
    if (-not $script:radioCatSessionRequested) {
        if ($script:radioCatSessionShutdown) { Set-UiRadioCatSessionState -State 'shutdown' }
        elseif ($script:radioCatOperationCancelled -or $script:radioCatSessionState -eq 'disconnecting') { Set-UiRadioCatSessionState -State 'disconnected' }
    }
    if ($script:radioModePreviousHriPortName) { $script:radioModePreviousHriPortName = '' }
    $queryConfirmed = ($operation -ceq 'query' -and $script:radioCatLastOperationStatus -ceq 'confirmed' -and
        $result -and [string]$result.operation -ceq 'query')
    [void](Complete-UiRadioCatQueuedAction -QueryResult $result -QueryConfirmed ([bool]$queryConfirmed))
    Update-UiRadioCatControls
    Update-UiRadioCatSessionControls
    if ($operation -ceq 'query' -and $script:radioCatPendingModeFrequencyRequest) {
        $pendingRequest = $script:radioCatPendingModeFrequencyRequest
        $script:radioCatPendingModeFrequencyRequest = $null
        $pendingKey = '{0}|{1}|{2}' -f [string]$pendingRequest.cat_port,[int]$pendingRequest.baud_rate,[string]$pendingRequest.stop_bits
        $pendingGeneration = if ($null -ne $pendingRequest.PSObject.Properties['cat_generation']) { [int]$pendingRequest.cat_generation } else { -1 }
        $pendingQueryAuthorized = ($queryConfirmed -and (Test-UiRadioCatFreshQueryAuthorization -Result $result `
            -PortName ([string]$pendingRequest.cat_port) -ConnectionKey $pendingKey -Generation $pendingGeneration))
        if ($script:radioCatLastOperationStatus -ceq 'confirmed' -and $script:radioCatResult -and
            [string]$script:radioCatResult.operation -ceq 'query' -and
            $pendingQueryAuthorized -and [string]::Equals($pendingKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
            try {
                if ([string]$pendingRequest.operation -ceq 'setMode') {
                    Start-UiRadioCatOperation -Operation 'setMode' -Side ([string]$pendingRequest.side) -Mode ([string]$pendingRequest.mode) `
                        -HriPortNameOverride ([string]$pendingRequest.hri_port) -PortNameOverride ([string]$pendingRequest.cat_port) `
                        -BaudRateOverride ([int]$pendingRequest.baud_rate) -StopBitsOverride ([string]$pendingRequest.stop_bits)
                } elseif ([string]$pendingRequest.operation -ceq 'setFrequency') {
                    Start-UiRadioCatOperation -Operation 'setFrequency' -Side ([string]$pendingRequest.side) -FrequencyHz ([long]$pendingRequest.frequency_hz) `
                        -HriPortNameOverride ([string]$pendingRequest.hri_port) -PortNameOverride ([string]$pendingRequest.cat_port) `
                        -BaudRateOverride ([int]$pendingRequest.baud_rate) -StopBitsOverride ([string]$pendingRequest.stop_bits)
                } else { throw '断开后的 CAT 设置类型无效。' }
            } catch {
                Set-UiRadioCatNotice -Text 'HRI 已停止；没有执行 MAIN 设置。'
                Update-UiRadioCatControls
            }
        } else {
            Set-UiRadioCatNotice -Text 'HRI 已停止；没有执行 MAIN 设置。'
            Update-UiRadioCatControls
        }
    }
    if ($script:radioCatCloseSettingsAfterOperation -and $script:settingsWindow) {
        $script:radioCatCloseSettingsAfterOperation = $false
        $script:settingsWindow.Close()
    }
    if ($script:radioCatCloseMainAfterOperation) {
        $script:radioCatCloseMainAfterOperation = $false
        $script:allowWindowClose = $true
        if ($script:mainWindow) { $script:mainWindow.Close() }
    }
    return $true
}

function Invoke-UiRadioModeOrFrequencyApply {
    param([ValidateSet('setMode','setFrequency')][string]$Operation)
    if ($script:radioCatQueuedAction -or $script:radioCatPendingModeFrequencyRequest -or $script:radioModeApplyAfterStop) {
        throw '已有一项 CAT 设置正在等待确认或执行。'
    }
    if ($script:supervisor -and -not $script:supervisor.HasExited -and -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
        throw '核心状态未确认电台空闲；请在来话和手咪发送结束后重试。'
    }
    $request = New-UiRadioCatActionRequest -Operation $Operation
    if ($script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -cne 'query') {
        throw '另一项 CAT 写入正在执行；请等待该操作结束。'
    }
    if ($script:radioCatOperationPowerShell) {
        $script:radioCatQueuedAction = $request
        Set-UiRadioCatNotice -Text '已冻结 MAIN 设置；当前 CAT 读取完成并确认身份后继续。'
    } elseif (Test-UiRadioCatHasLiveCore) {
        [void](Invoke-UiRadioCatFrozenModeFrequencyApply -Request $request)
    } else {
        $script:radioCatQueuedAction = $request
        [void](Start-UiRadioCatQueuedActionQuery -Request $request)
    }
    Update-UiRadioCatControls
    return $true
}

function Invoke-UiRadioCatAction {
    param([ValidateSet('query','setPower','setMode','setFrequency')][string]$Operation)
    try {
        if ($script:radioCatQueuedAction -or $script:radioCatPendingModeFrequencyRequest -or $script:radioModeApplyAfterStop) {
            throw '已有一项 CAT 用户动作正在等待执行。'
        }
        if ($script:radioCatOperationPowerShell -and [string]$script:radioCatOperationKind -cne 'query' -and $Operation -cne 'query') {
            throw '另一项 CAT 写入正在执行；请等待该操作结束。'
        }
        $request = New-UiRadioCatActionRequest -Operation $Operation
        if ($Operation -ceq 'query') {
            if ($script:radioCatOperationPowerShell) {
                $script:radioCatQueuedAction = $request
                Set-UiRadioCatNotice -Text '当前串口操作结束后执行用户请求的读取。'
            } else {
                Start-UiRadioCatOperation -Operation 'query' -PortNameOverride ([string]$request.port_name) `
                    -BaudRateOverride ([int]$request.baud_rate) -StopBitsOverride ([string]$request.stop_bits) `
                    -HriPortNameOverride ([string]$request.hri_port)
            }
        } elseif ($script:radioCatOperationPowerShell) {
            $script:radioCatQueuedAction = $request
            Set-UiRadioCatNotice -Text '已冻结 CAT 设置；当前读取完成并确认身份、端口和TX状态后执行一次。'
        } else {
            $script:radioCatQueuedAction = $request
            [void](Start-UiRadioCatQueuedActionQuery -Request $request)
        }
    } catch {
        if ($script:mainWindow -or $script:settingsWindow) {
            Set-UiRadioCatNotice -Text ('当前条件不允许发送该设置：' + $_.Exception.Message)
        }
    }
    Update-UiRadioCatControls
}
