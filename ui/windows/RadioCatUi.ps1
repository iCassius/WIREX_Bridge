#requires -Version 5.1

# CAT-1 UI controller. Loaded by bridge-ui.ps1 after script state is initialized.

# Keep all CAT access bounded to explicit short open/query-or-set/readback/close operations.

function Initialize-UiRadioCatController {
    if ($script:radioCatControllerInitialized -or -not $script:mainWindow) { return }
    $script:radioCatControllerInitialized = $true
    if ($null -eq $script:radioCatPortSelectionExplicit) { $script:radioCatPortSelectionExplicit = $false }
    if ($null -eq $script:radioCatPortTextEditExplicit) { $script:radioCatPortTextEditExplicit = $false }
    if ($null -eq $script:radioCatPollingActive) { $script:radioCatPollingActive = $false }
    if ($null -eq $script:radioCatOperationOrdinal) { $script:radioCatOperationOrdinal = 0 }
    if ($null -eq $script:radioCatEditDraft) { $script:radioCatEditDraft = @{ mode=$null; frequency=$null; power=$null } }

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
    (Get-SettingsControl 'CatStopBitsBox').Add_SelectionChanged({ Update-UiRadioCatControls })
    (Get-SettingsControl 'ReadRadioButton').Add_Click({ Invoke-UiRadioCatAction -Operation 'query' })
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

function Start-UiRadioCatPolling {
    if (-not $script:radioCatModuleAvailable) { return $false }
    $connectionKey = Get-UiRadioCatConnectionKey
    if (-not $connectionKey) { return $false }
    if ($script:radioCatPollingActive -and [string]::Equals([string]$script:radioCatPollingConnectionKey,$connectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($script:radioCatPollingActive) { Stop-UiRadioCatPolling -Reason 'cat_configuration_changed' }
    $script:radioCatPollingActive = $true
    $script:radioCatPollingConnectionKey = $connectionKey
    $script:radioCatPollNextUtc = [DateTime]::UtcNow
    [void](Invoke-UiRadioCatPollTick -Force)
    return $true
}

function Stop-UiRadioCatPolling {
    param([string]$Reason='session_stopped')
    $script:radioCatPollingActive = $false
    $script:radioCatPollingConnectionKey = ''
    $script:radioCatPollNextUtc = [DateTime]::MinValue
    $script:radioCatResult = $null
    if ($Reason -cin @('stop_and_exit','main_window_closing')) { $script:radioCatPendingModeFrequencyRequest = $null }
    if ($script:radioCatOperationPowerShell) {
        try { [void](Request-StopUiRadioCatOperation -Reason $Reason) }
        catch { if ($script:mainWindow -or $script:settingsWindow) { Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('CAT-1 取消失败：' + $_.Exception.Message) } }
    }
    Update-UiRadioCatControls
}

function Invoke-UiRadioCatPollTick {
    param([switch]$Force)
    if (-not $script:radioCatPollingActive -or -not $script:radioCatModuleAvailable) { return $false }
    $now = [DateTime]::UtcNow
    if (-not $Force -and $now -lt $script:radioCatPollNextUtc) { return $false }
    $interval = if ([int]$script:radioCatPollIntervalMs -ge 500 -and [int]$script:radioCatPollIntervalMs -le 5000) { [int]$script:radioCatPollIntervalMs } else { 1000 }
    $script:radioCatPollNextUtc = $now.AddMilliseconds($interval)
    if ($script:radioCatOperationPowerShell) { return $false }
    $connectionKey = Get-UiRadioCatConnectionKey
    if (-not $connectionKey -or -not [string]::Equals($connectionKey,[string]$script:radioCatPollingConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        Stop-UiRadioCatPolling -Reason 'cat_configuration_changed'
        return $false
    }
    try {
        Start-UiRadioCatOperation -Operation 'query'
        return $true
    } catch {
        $script:radioCatResult = $null
        $script:radioCatLastOperationStatus = 'unknown'
        Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('CAT-1 轮询未能启动：' + $_.Exception.Message)
        Update-UiRadioCatControls
        return $false
    }
}

function Set-UiRadioCatDeviceControls {
    if (-not $script:mainWindow -or -not $script:radioCatModuleAvailable) { return }
    $portControl = Get-SettingsControl 'CatPortBox'
    $baudControl = Get-SettingsControl 'CatBaudRateBox'
    $stopBitsControl = Get-SettingsControl 'CatStopBitsBox'
    if (-not $script:radioControlPreferences) { $script:radioControlPreferences = Get-UiDefaultRadioControlPreferences }

    $allPorts = if ($script:deviceCatalog) { @($script:deviceCatalog.serial_ports) } else { @() }
    $hriPorts = if ($script:deviceCatalog) { @($script:deviceCatalog.hri_ports) } else { @() }
    $options = New-Object 'System.Collections.Generic.List[object]'
    $savedPort = [string]$script:radioControlPreferences.cat_port
    $hriPort = Get-UiHriPortName
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
    $savedAvailable = @($allPorts | Where-Object {
        [string]::Equals([string]$_.PortName,$savedPort,[StringComparison]::OrdinalIgnoreCase) -and
        -not [bool]$_.IsHri -and [string]::Equals([string]$_.PortName,$hriPort,[StringComparison]::OrdinalIgnoreCase) -eq $false
    })
    if (-not $savedConflict -and $savedPort -match '^COM[1-9][0-9]{0,2}$' -and $savedAvailable.Count -gt 0) {
        $selectedPort = ([string]$savedAvailable[0].PortName).ToUpperInvariant()
    } else {
        $ranked = @($allPorts | Where-Object { -not [bool]$_.IsHri -and [int]$_.CatMatchRank -gt 0 -and [string]$_.PortName -ine $hriPort } | Sort-Object { -[int]$_.CatMatchRank })
        if ($ranked.Count -gt 0) {
            $bestRank = [int]$ranked[0].CatMatchRank
            $best = @($ranked | Where-Object { [int]$_.CatMatchRank -eq $bestRank })
            if ($best.Count -eq 1) { $selectedPort = [string]$best[0].PortName }
        }
    }
    $script:radioCatPortSelectionExplicit = $false
    $script:radioCatPortTextEditExplicit = $false
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
        $portControl.SelectedItem = @($portControl.Items | Where-Object { $_.Tag.Value -ieq $selectedPort -and $_.Tag.IsAvailable } | Select-Object -First 1)[0]
        $portControl.Text = $selectedPort
    } finally { $script:radioCatProgrammaticControlUpdate = $wasProgrammatic }
    Register-UiRadioCatPortTextInput
    $baudControl.SelectedItem = @($baudControl.Items | Where-Object { [int]$_.Tag -eq [int]$script:radioControlPreferences.baud_rate })[0]
    $stopBitsControl.SelectedItem = @($stopBitsControl.Items | Where-Object { [string]$_.Tag -ceq [string]$script:radioControlPreferences.stop_bits })[0]
    if ($savedConflict) {
        Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('已保存的 CAT 端口 {0} 与 HRI 冲突；请选择另一个端口。' -f $savedPort)
        (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
    } elseif (-not $selectedPort) {
        Set-UiRadioCatText -Name 'CatOperationStatusText' -Text '未找到唯一的 CAT 串口匹配；可手动输入 COM1–COM999。'
        (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
    }
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
    if (-not $script:mainWindow -and -not $script:settingsWindow) { return }
    $control = Get-SettingsControl $Name
    if ($control -is [System.Windows.Controls.TextBlock] -or $control -is [System.Windows.Controls.TextBox]) {
        $control.Text = $Text
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
    if ($port -ieq (Get-UiHriPortName)) { return $null }
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
    $baudItem = (Get-SettingsControl 'CatBaudRateBox').SelectedItem
    $stopBitsItem = (Get-SettingsControl 'CatStopBitsBox').SelectedItem
    if ($baudItem -isnot [System.Windows.Controls.ComboBoxItem] -or $stopBitsItem -isnot [System.Windows.Controls.ComboBoxItem]) { return '' }
    return ('{0}|{1}|{2}' -f $port.ToUpperInvariant(),[int]$baudItem.Tag,[string]$stopBitsItem.Tag)
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
        [string]$status.receive_media_state -cnotin @('idle','filtered') -or -not [bool]$status.ptt_gate_ready) { return $false }
    foreach ($name in @('rx_queue_bursts','rx_queue_playback_frames','rx_queue_unconfirmed_playback_frames','rx_buffered_receive_frames')) {
        $value = [uint64]0
        if ($status.PSObject.Properties[$name].Value -is [bool] -or
            -not [uint64]::TryParse([string]$status.PSObject.Properties[$name].Value,[Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or $value -ne 0) { return $false }
    }
    return $true
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
    $slider = Get-SettingsControl 'CatPowerSlider'
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
    $wasLoading = [bool]$script:loadingRadioCatSettings
    $wasUpdating = [bool]$script:radioCatProgrammaticControlUpdate
    $oldTag = $slider.Tag
    try {
        $script:loadingRadioCatSettings = $true
        $slider.Tag = '__radio_cat_programmatic__'
        $slider.Minimum = 5
        $slider.Maximum = [double]$Maximum
        $script:radioCatPowerNeedsUserChoice = $needsChoice
        $script:radioCatProgrammaticControlUpdate = $true
        $slider.Value = if ($needsChoice) { 5.0 } else { [double]$sliderWatts }
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
    $panel = Get-SettingsControl 'CatObservedPanel'
    if (-not $script:radioCatObserved) {
        $panel.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }
    $id = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'radio_id'
    $mainMode = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'main_mode'
    $subMode = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'sub_mode'
    $mainFrequency = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'main_frequency_hz'
    $power = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'power'
    $visibleValues = 0
    if ($id) {
        Set-UiRadioCatText -Name 'CatRadioIdentityText' -Text ('CAT-1 {0} · ID {1} · {2} · 读取 {3}' -f [string]$script:radioCatObservedPortName,[string]$id.value,$id.source,(Format-UiRadioCatUtcTime $id.updated_at_utc))
        $visibleValues++
    }
    if ($mainMode) {
        Set-UiRadioCatText -Name 'CatObservedMainModeText' -Text ('MAIN 模式：{0} · {1} · {2}' -f [string]$mainMode.value.mode,$mainMode.source,(Format-UiRadioCatUtcTime $mainMode.updated_at_utc))
        $visibleValues++
        if (-not $script:radioCatEditDraft -or $null -eq $script:radioCatEditDraft.mode) {
            $script:radioCatProgrammaticControlUpdate = $true
            try {
                $modeBox = Get-SettingsControl 'CatMainModeBox'
                $modeBox.SelectedItem = @($modeBox.Items | Where-Object { [string]$_.Tag -ceq [string]$mainMode.value.mode })[0]
            } finally { $script:radioCatProgrammaticControlUpdate = $false }
        }
    }
    if ($subMode) {
        Set-UiRadioCatText -Name 'CatObservedSubModeText' -Text ('SUB 模式：{0} · {1} · {2}' -f [string]$subMode.value.mode,$subMode.source,(Format-UiRadioCatUtcTime $subMode.updated_at_utc))
        $visibleValues++
    }
    if ($mainFrequency) {
        $frequencyMHz = Format-UiFrequencyMHz -FrequencyHz ([long]$mainFrequency.value)
        Set-UiRadioCatText -Name 'CatObservedFrequencyText' -Text ('MAIN VFO：{0} MHz · {1} · {2}' -f $frequencyMHz,$mainFrequency.source,(Format-UiRadioCatUtcTime $mainFrequency.updated_at_utc))
        if (-not $script:radioCatEditDraft -or $null -eq $script:radioCatEditDraft.frequency) {
            $script:radioCatProgrammaticControlUpdate = $true
            try { (Get-SettingsControl 'CatMainFrequencyMHzBox').Text = $frequencyMHz }
            finally { $script:radioCatProgrammaticControlUpdate = $false }
        }
        $visibleValues++
    }
    if ($power) {
        $value = $power.value
        Set-UiRadioCatText -Name 'CatObservedPowerText' -Text ('电台功率设定：{0} {1} W · {2} · {3}' -f [string]$value.path,[int]$value.watts,$power.source,(Format-UiRadioCatUtcTime $power.updated_at_utc))
        $visibleValues++
        $capabilities = Get-UiRadioCatProperty -InputObject $script:radioCatResult -Name 'capabilities'
        $powerCapability = Get-UiRadioCatProperty -InputObject $capabilities -Name 'set_power'
        $maximum = Get-UiRadioCatProperty -InputObject $powerCapability -Name 'maximum_watts'
        if ($maximum -is [int] -or $maximum -is [long]) {
            Set-UiRadioCatPowerSliderRange -Maximum ([int]$maximum)
        } elseif (-not $script:radioCatResult) {
            $actualMaximum = if ([string]$value.path -ceq 'FieldHead') { 10 } else { 50 }
            Set-UiRadioCatPowerSliderRange -Maximum $actualMaximum
        }
        if ($script:radioCatEditDraft -and $null -eq $script:radioCatEditDraft.power) {
            $slider = Get-SettingsControl 'CatPowerSlider'
            $actualMaximum = if ([string]$value.path -ceq 'FieldHead') { 10 } else { 50 }
            $script:radioCatProgrammaticControlUpdate = $true
            $wasLoading = [bool]$script:loadingRadioCatSettings
            $script:loadingRadioCatSettings = $true
            $oldTag = $slider.Tag
            try {
                $slider.Tag = '__radio_cat_programmatic__'
                $slider.Minimum = 5
                $slider.Maximum = [double]$actualMaximum
                $slider.Value = [double]$value.watts
            } finally {
                $slider.Tag = $oldTag
                $script:loadingRadioCatSettings = $wasLoading
                $script:radioCatProgrammaticControlUpdate = $false
            }
        }
    }
    $panel.Visibility = if ($visibleValues -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Update-UiRadioCatControls {
    if (-not $script:mainWindow -and -not $script:settingsWindow) { return }
    $panel = Get-SettingsControl 'RadioCatPanel'
    $panel.Visibility = if ($script:radioCatModuleAvailable) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $operatingPanel = Get-SettingsControl 'CatOperatingPanel'
    $operatingPanel.Visibility = if ($script:radioCatModuleAvailable) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    if (-not $script:radioCatModuleAvailable) { return }
    if ($script:radioControlPreferencesError) {
        foreach ($name in @('CatPortBox','CatBaudRateBox','CatStopBitsBox','ReadRadioButton','CatMainModeBox','ApplyCatModeButton',
                'CatMainFrequencyMHzBox','ApplyCatFrequencyButton','CatPowerSlider','ApplyCatPowerButton')) {
            (Get-SettingsControl $name).IsEnabled = $false
        }
        return
    }
    $busy = ($script:radioCatOperationPowerShell -or $script:radioModeApplyAfterStop -or $script:stopTask -or
        $script:preparationStarted -or $script:prepareStopAsync)
    $connectionLocked = [bool]($script:preparationStarted -or $script:stopTask -or $script:prepareStopAsync -or
        ($script:supervisor -and -not $script:supervisor.HasExited))
    foreach ($name in @('CatPortBox','CatBaudRateBox','CatStopBitsBox')) {
        (Get-SettingsControl $name).IsEnabled = (-not $busy -and -not $connectionLocked)
    }
    foreach ($name in @('CatMainModeBox','CatMainFrequencyMHzBox','CatPowerSlider')) {
        (Get-SettingsControl $name).IsEnabled = -not $busy
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
    (Get-SettingsControl 'ReadRadioButton').IsEnabled = (-not $busy -and $portReady -and -not $portConflict)

    $idle = Test-UiRadioCatRunIdle -RequireFreshStatus
    $modeBox = Get-SettingsControl 'CatMainModeBox'
    $modeSelected = ($modeBox.SelectedItem -is [System.Windows.Controls.ComboBoxItem] -and
        [string]$modeBox.SelectedItem.Tag -cin @('FM','FM-N','C4FM-DN','C4FM-VW'))
    $frequencyHz = [long]0
    $frequencyValid = $false
    try { $frequencyHz = ConvertFrom-UiFrequencyMHz -Text (Get-SettingsControl 'CatMainFrequencyMHzBox').Text; $frequencyValid = $true } catch { }
    $buttonText = if ($script:supervisor -and -not $script:supervisor.HasExited) { '断开并应用 MAIN 模式' } else { '应用 MAIN 模式' }
    (Get-SettingsControl 'ApplyCatModeButton').Content = $buttonText
    (Get-SettingsControl 'ApplyCatModeButton').IsEnabled = (-not $busy -and $portReady -and -not $portConflict -and $modeSelected -and $confirmedObservationPermit -and $idle)
    $frequencyButtonText = if ($script:supervisor -and -not $script:supervisor.HasExited) { '断开并应用 MAIN 频率' } else { '应用 MAIN 频率' }
    (Get-SettingsControl 'ApplyCatFrequencyButton').Content = $frequencyButtonText
    (Get-SettingsControl 'ApplyCatFrequencyButton').IsEnabled = (-not $busy -and $portReady -and -not $portConflict -and $frequencyValid -and $confirmedObservationPermit -and $idle)

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
    (Get-SettingsControl 'CatPowerSlider').IsEnabled = -not $busy
    $hasPowerDraft = ($script:radioCatEditDraft -and $null -ne $script:radioCatEditDraft.power)
    (Get-SettingsControl 'ApplyCatPowerButton').IsEnabled = (-not $busy -and $portReady -and -not $portConflict -and
        $observationMatchesConnection -and $powerAllowed -and $hasPowerDraft -and -not $script:radioCatPowerNeedsUserChoice)
    if ($script:radioCatOperationKind) {
        Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('CAT-1 操作中：{0}' -f $script:radioCatOperationKind)
        (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
    }
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
    $hriPort = if ($PSBoundParameters.ContainsKey('HriPortNameOverride')) { [string]$HriPortNameOverride } else { Get-UiHriPortName }
    if ($hriPort -and [string]::Equals($port,$hriPort,[StringComparison]::OrdinalIgnoreCase)) {
        throw ('CAT-1 与 HRI 不能共用 {0}。' -f $port)
    }
    if ($Operation -cin @('setPower','setMode','setFrequency') -and -not (Test-UiRadioCatRunIdle -RequireFreshStatus)) {
        throw '核心状态未确认电台空闲；设置操作已取消。'
    }
    if ($Operation -cin @('setMode','setFrequency')) {
        $candidateBaud = if ($PSBoundParameters.ContainsKey('BaudRateOverride')) { [int]$BaudRateOverride } else { [int](Get-UiComboTag -Combo (Get-SettingsControl 'CatBaudRateBox')) }
        $candidateStopBits = if ($PSBoundParameters.ContainsKey('StopBitsOverride')) { [string]$StopBitsOverride } else { [string](Get-UiComboTag -Combo (Get-SettingsControl 'CatStopBitsBox')) }
        $candidateKey = '{0}|{1}|{2}' -f $port.ToUpperInvariant(),$candidateBaud,$candidateStopBits
        if (-not $script:radioCatResult -or [string]$script:radioCatResult.status -cne 'confirmed' -or
            -not [string]::Equals($candidateKey,[string]$script:radioCatObservedConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
            throw '没有当前 CAT 端口的已确认读取许可；请先重新读取电台状态。'
        }
    }
    if ($Operation -cin @('setMode','setFrequency') -and $script:supervisor -and -not $script:supervisor.HasExited) {
        throw '请先停止 HRI 会话，再应用 MAIN 调制或频率。'
    }
    $baud = if ($PSBoundParameters.ContainsKey('BaudRateOverride')) { [int]$BaudRateOverride } else { [int](Get-UiComboTag -Combo (Get-SettingsControl 'CatBaudRateBox')) }
    $stopBits = if ($PSBoundParameters.ContainsKey('StopBitsOverride')) { [string]$StopBitsOverride } else { [string](Get-UiComboTag -Combo (Get-SettingsControl 'CatStopBitsBox')) }
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
        Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('正在执行 CAT-1 {0}；本次操作最多 2.5 秒，不会自动重试。' -f $Operation)
        (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
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
    if ($script:radioCatOperationKind -ceq 'setPower' -and -not $script:radioCatOperationCancelled -and
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
    if ($script:radioCatObservedConnectionKey -and
        -not [string]::Equals([string]$script:radioCatObservedConnectionKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        $script:radioCatObserved = $null
        $script:radioCatObservedPortName = ''
        $script:radioCatObservedConnectionKey = ''
    }
    if ($script:radioCatOperationCancelled) {
        $failure = 'CAT-1 操作已取消；设置结果未知，不会自动重试。'
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    } elseif (-not $failure -and $result -and (Test-UiRadioCatResult -Result $result -ExpectedOperation $operation -ExpectedPort $port)) {
        if ([string]$result.cleanup_status -cne 'closed' -and [string]$result.status -ne 'rejected') {
            $failure = 'CAT-1 串口关闭状态未确认；本次结果未知。'
            $script:radioCatLastOperationStatus = 'unknown'
            $script:radioCatResult = $null
        } elseif ([string]$result.status -ceq 'confirmed') {
            $script:radioCatObserved = Merge-UiRadioCatObserved -Existing $script:radioCatObserved -Fresh $result.observed
            $script:radioCatObservedPortName = $port
            $script:radioCatObservedConnectionKey = $operationConnectionKey
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
        } else {
            $failure = if ($result.error_message) { [string]$result.error_message } else { 'CAT-1 未确认本次设置。' }
            $script:radioCatLastOperationStatus = [string]$result.status
            $script:radioCatResult = $null
            if ([string]$result.status -ceq 'identity_mismatch') {
                $script:radioCatObserved = $null
                $script:radioCatObservedPortName = ''
                $script:radioCatObservedConnectionKey = ''
            } elseif ($operation -ceq 'setPower' -and
                [string]::Equals((Get-UiRadioCatConnectionKey),$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase) -and
                (Test-UiRadioCatRejectedPowerReadback -Result $result -ExpectedPort $port)) {
                $script:radioCatObserved = Merge-UiRadioCatObserved -Existing $script:radioCatObserved -Fresh $result.observed
                $script:radioCatObservedPortName = $port
                $script:radioCatObservedConnectionKey = $operationConnectionKey
                $script:radioCatResult = $result
            }
        }
    } elseif (-not $failure) {
        $failure = 'CAT-1 返回的数据结构或端口身份不符合界面合同。'
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    } else {
        $script:radioCatLastOperationStatus = 'unknown'
        $script:radioCatResult = $null
    }
    if ($script:mainWindow -or $script:settingsWindow) {
        if ($script:radioCatOperationCancelled) {
            Set-UiRadioCatText -Name 'CatOperationStatusText' -Text $failure
        } elseif ($script:radioCatLastOperationStatus -ceq 'confirmed') {
            $stamp = Get-UiRadioCatObservedValue -Observed $script:radioCatObserved -Name 'radio_id'
            $timeText = if ($stamp) { Format-UiRadioCatUtcTime -Value $stamp.updated_at_utc } else { '时间未知' }
            Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('CAT-1 {0} 已读回确认 · {1} · 串口已关闭' -f $operation,$timeText)
        } else {
            Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('CAT-1 {0}：{1}' -f $script:radioCatLastOperationStatus,$failure)
        }
        (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
        Update-UiRadioCatObservationDisplay
        Update-UiRadioCatControls
    }
    $script:radioCatOperationKind = ''
    $script:radioCatOperationPortName = ''
    $script:radioCatOperationBaudRate = 0
    $script:radioCatOperationStopBits = ''
    $script:radioCatOperationCancelled = $false
    $script:radioCatOperationCancelReason = ''
    $script:radioCatOperationOwnerWindow = $null
    $script:radioCatOperationStopStartedUtc = [DateTime]::MinValue
    if ($script:radioModePreviousHriPortName) { $script:radioModePreviousHriPortName = '' }
    if ($operation -ceq 'query' -and $script:radioCatPendingModeFrequencyRequest) {
        $pendingRequest = $script:radioCatPendingModeFrequencyRequest
        $script:radioCatPendingModeFrequencyRequest = $null
        $pendingKey = '{0}|{1}|{2}' -f [string]$pendingRequest.cat_port,[int]$pendingRequest.baud_rate,[string]$pendingRequest.stop_bits
        if ($script:radioCatLastOperationStatus -ceq 'confirmed' -and $script:radioCatResult -and
            [string]$script:radioCatResult.operation -ceq 'query' -and
            [string]::Equals($pendingKey,$operationConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
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
                Set-UiRadioCatText -Name 'CatOperationStatusText' -Text ('HRI 已停止；新 CAT 读取已确认，但没有执行设置：' + $_.Exception.Message)
                Update-UiRadioCatControls
            }
        } else {
            Set-UiRadioCatText -Name 'CatOperationStatusText' -Text 'HRI 已停止；CAT 新读取没有确认，未执行 MAIN 设置。'
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
    if (-not $script:radioCatObserved) { throw '请先读取电台当前 CAT 状态。' }
    if (-not $script:radioCatResult -or [string]$script:radioCatResult.status -cne 'confirmed') {
        throw '当前 CAT 读取未确认；请重新读取电台状态后再应用设置。'
    }
    if (-not (Get-UiRadioCatConnectionKey) -or -not [string]::Equals((Get-UiRadioCatConnectionKey),$script:radioCatObservedConnectionKey,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'CAT-1 端口或串口参数已更改；请重新读取电台状态。'
    }
    if (-not (Test-UiRadioCatRunIdle -RequireFreshStatus)) { throw '核心尚未确认电台空闲；请在来话和手咪发送结束后重试。' }
    if ($Operation -ceq 'setMode') {
        $selected = (Get-SettingsControl 'CatMainModeBox').SelectedItem
        if ($selected -isnot [System.Windows.Controls.ComboBoxItem] -or [string]$selected.Tag -cnotin @('FM','FM-N','C4FM-DN','C4FM-VW')) { throw '请选择明确的 MAIN 调制模式。' }
        $request = [pscustomobject]@{ operation='setMode'; side='Main'; mode=[string]$selected.Tag }
    } else {
        $frequencyHz = ConvertFrom-UiFrequencyMHz -Text (Get-SettingsControl 'CatMainFrequencyMHzBox').Text
        $request = [pscustomobject]@{ operation='setFrequency'; side='Main'; frequency_hz=[long]$frequencyHz }
    }
    $catPort = Get-UiRadioCatSelectedPort
    if (-not $catPort) { throw '请选择设备枚举中已发现且不是 HRI 的 CAT-1 端口。' }
    $hriPort = Get-UiHriPortName
    if ($hriPort -and [string]::Equals($catPort,$hriPort,[StringComparison]::OrdinalIgnoreCase)) {
        throw ('CAT-1 与 HRI 不能共用 {0}。' -f $catPort)
    }
    $baud = [int](Get-UiComboTag -Combo (Get-SettingsControl 'CatBaudRateBox'))
    $stopBits = [string](Get-UiComboTag -Combo (Get-SettingsControl 'CatStopBitsBox'))
    $request | Add-Member -NotePropertyName cat_port -NotePropertyValue $catPort
    $request | Add-Member -NotePropertyName hri_port -NotePropertyValue $hriPort
    $request | Add-Member -NotePropertyName baud_rate -NotePropertyValue $baud
    $request | Add-Member -NotePropertyName stop_bits -NotePropertyValue $stopBits
    if ($script:supervisor -and -not $script:supervisor.HasExited) {
        if ($script:radioCatOperationPowerShell -or $script:stopTask -or $script:preparationStarted) { throw '当前有连接或 CAT 操作正在收尾。' }
        $script:radioModePreviousHriPortName = Get-UiHriPortName
        $script:radioModeApplyAfterStop = $request
        $script:closingAfterStop = $false
        $script:reconnectAfterStop = $false
        $script:stopTask = $script:supervisor.StopAsync(5000)
        Set-MainText -Name 'FooterText' -Text '正在停止 HRI；确认核心退出并释放串口后应用 CAT 设置。'
        (Get-SettingsControl 'CatOperationStatusText').Text = '正在停止 HRI。确认停止前不会写入调制或频率。'
        (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
        Update-UiRadioCatControls
        return
    }
    if ($Operation -ceq 'setMode') {
        Start-UiRadioCatOperation -Operation $Operation -Side $request.side -Mode $request.mode -HriPortNameOverride $request.hri_port `
            -PortNameOverride $request.cat_port -BaudRateOverride $request.baud_rate -StopBitsOverride $request.stop_bits
    } else {
        Start-UiRadioCatOperation -Operation $Operation -Side $request.side -FrequencyHz ([long]$request.frequency_hz) -HriPortNameOverride $request.hri_port `
            -PortNameOverride $request.cat_port -BaudRateOverride $request.baud_rate -StopBitsOverride $request.stop_bits
    }
}

function Invoke-UiRadioCatAction {
    param([ValidateSet('query','setPower','setMode','setFrequency')][string]$Operation)
    try {
        switch -CaseSensitive ($Operation) {
            'query' { Start-UiRadioCatOperation -Operation 'query' }
            'setPower' {
                if (-not $script:radioCatEditDraft -or $null -eq $script:radioCatEditDraft.power) {
                    throw '请先调整功率滑块，再明确应用该草稿值。'
                }
                if ($script:radioCatPowerNeedsUserChoice) { throw '目标功率超出电台当前范围；请先明确选择合法值。' }
                $watts = [int]$script:radioCatEditDraft.power
                $capability = Get-UiRadioCatProperty -InputObject (Get-UiRadioCatProperty -InputObject $script:radioCatResult -Name 'capabilities') -Name 'set_power'
                $maximum = Get-UiRadioCatProperty -InputObject $capability -Name 'maximum_watts'
                if (-not $script:radioCatResult -or [string]$script:radioCatResult.status -cne 'confirmed' -or
                    -not $capability -or -not [bool]$capability.available -or
                    ($maximum -isnot [int] -and $maximum -isnot [long]) -or $watts -lt 5 -or $watts -gt [int]$maximum) {
                    throw '请重新读取电台并选择当前路径允许的目标功率。'
                }
                Start-UiRadioCatOperation -Operation 'setPower' -PowerWatts $watts
            }
            'setMode' { Invoke-UiRadioModeOrFrequencyApply -Operation 'setMode' }
            'setFrequency' { Invoke-UiRadioModeOrFrequencyApply -Operation 'setFrequency' }
        }
    } catch {
        if ($script:mainWindow -or $script:settingsWindow) {
            Set-UiRadioCatText -Name 'CatOperationStatusText' -Text $_.Exception.Message
            (Get-SettingsControl 'CatOperationStatusText').Visibility = [System.Windows.Visibility]::Visible
        }
    }
    Update-UiRadioCatControls
}
