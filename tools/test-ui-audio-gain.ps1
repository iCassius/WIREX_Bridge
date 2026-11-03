#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$script:assertionCount = 0

function Assert-UiAudioGain {
    param([bool]$Condition,[string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-UiAudioGainBom {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-UiAudioGain ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        '测试脚本必须使用带 BOM 的 UTF-8，兼容 Windows PowerShell 5.1。'
}

function Invoke-UiAudioGainDispatcherUntil {
    param([Parameter(Mandatory=$true)][scriptblock]$Condition,[int]$TimeoutMilliseconds=1500)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(20)
    $tick = {
        if ([bool](& $Condition) -or $watch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            $timer.Stop()
            $frame.Continue = $false
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timer.Remove_Tick($tick)
    $watch.Stop()
    return [bool](& $Condition)
}

function Wait-UiAudioGainMilliseconds {
    param([int]$Milliseconds)
    $until = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    [void](Invoke-UiAudioGainDispatcherUntil -Condition { [DateTime]::UtcNow -ge $until } -TimeoutMilliseconds ($Milliseconds + 1000))
}

function New-UiAudioGainSupervisor {
    $commands = New-Object 'System.Collections.Generic.List[object]'
    $instance = [pscustomobject]@{ HasExited=$false; Commands=$commands }
    Add-Member -InputObject $instance -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$ParametersJson='')
        [void]$this.Commands.Add([pscustomobject][ordered]@{
            request_id=$RequestId; command=$Command; parameters_json=$ParametersJson
        })
        return $true
    } | Out-Null
    return $instance
}

function Get-TestUiGainCommandCount {
    param([string]$Command='audio.gains.set')
    return @($script:supervisor.Commands | Where-Object { $_.command -ceq $Command }).Count
}

function New-TestAudioGains {
    param([uint64]$Revision,[uint32]$Playback,[uint32]$Transmit)
    return [pscustomobject][ordered]@{
        revision=$Revision
        radio_playback_gain_milli=$Playback
        mic_transmit_gain_milli=$Transmit
    }
}

function New-TestAudioGainSnapshot {
    param([object]$Gains)
    return [pscustomobject][ordered]@{
        audio_gains=$Gains
    }
}

function Set-TestUiSlider {
    param([string]$Name,[double]$Value)
    $slider = $script:mainWindow.FindName($Name)
    $slider.Value = $Value
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
}

function Read-TestUiGainConfig {
    return Get-WirexPortableConfig -Path $script:portableConfigPath
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
Assert-UiAudioGainBom -Path $scriptPath
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$mainXamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
$configModulePath = Join-Path $repoRoot 'ui\windows\PortableConfig.psm1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$parseErrors)
Assert-UiAudioGain ($parseErrors.Count -eq 0) 'bridge-ui.ps1 必须可解析。'
$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
$functionNames = @(
    'Import-WpfWindow','Get-UiControl','Set-UiControlStatus','Request-UiControlStatus',
    'Test-UiExactControlFields','Test-UiControlUnsigned','Test-UiHasCapability','Test-UiAudioGainsValue','Test-UiAudioGainCapability',
    'Test-UiControlSnapshot','Test-UiRoutingCapabilityList','Test-UiRxPolicy','Test-UiRoutingSnapshot','ConvertFrom-UiControlFrame',
    'Format-UiGainMilli','Convert-UiGainSliderToMilli','Convert-UiStoredGainToMilli','Update-UiPlaybackGainDisplay','Update-UiAudioGainValueLabels',
    'Set-UiAudioGainStatus','Set-UiAudioGainSliders','Update-UiAudioGainControls','Reset-UiAudioGainRun',
    'Set-UiTransientStatus','Set-UiTransientStatusDisplay','Clear-UiTransientStatus','Update-UiTransientStatusExpiry',
    'Save-UiAudioGainsFromReadback','Apply-UiAudioGainReadback','Start-UiAudioGainDebounce','Get-UiAudioGainDraft',
    'Start-UiAudioGainSet','On-UiAudioGainValueChanged','Complete-UiAudioGainResult','Complete-UiAudioGainFailure',
    'Complete-UiAudioGainStatus','Consume-UiAudioGainExpiredResult','Remember-UiAudioGainExpiredRequest',
    'Expire-UiAudioGainRequest','Save-UiAudioSettings'
)
$selected = @($definitions | Where-Object { $functionNames -ccontains $_.Name })
foreach ($name in $functionNames) {
    Assert-UiAudioGain (@($selected | Where-Object { $_.Name -ceq $name }).Count -eq 1) ("必须从当前 UI 提取一个 {0} 实现。" -f $name)
}
Invoke-Expression (($selected | ForEach-Object { $_.Extent.Text }) -join "`r`n")
Import-Module -Name (Join-Path $repoRoot 'ui\windows\UiLocalization.psm1') -Force
$script:uiLanguage = 'zh-CN'
Import-Module -Name $configModulePath -Force

function Set-MainText {
    param([string]$Name,[AllowEmptyString()][string]$Text)
    $control = if ($script:mainWindow) { $script:mainWindow.FindName($Name) } else { $null }
    if ($control -and $control.PSObject.Properties['Text']) { $control.Text = $Text }
}

function Format-BridgeGain {
    param([uint32]$GainMilli)
    return ([double]$GainMilli / 1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
}

$startRunAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Start-BridgeRun' },$true)
Assert-UiAudioGain ($null -ne $startRunAst -and $startRunAst.Extent.Text -notmatch 'audioGainNativeCapability|connection\.api_key') `
    '旧版核心能力和空 API Key 不得成为连接预检条件。'

$script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-ui-audio-gain-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:testRoot)
$script:portableConfigPath = Join-Path $script:testRoot 'config.json'
$script:portableConfig = Get-WirexPortableConfig -Path $script:portableConfigPath
$script:portableConfig.connection.password = ''
$script:portableConfig.connection.api_key = ''
$script:portableConfig = Save-WirexPortableConfig -Path $script:portableConfigPath -Config $script:portableConfig
$script:mainWindow = Import-WpfWindow -Path $mainXamlPath
$script:mainWindow.Opacity = 0
$script:mainWindow.Show()
$script:mainWindow.UpdateLayout()
$script:settingsWindow = $null
$script:savedPlaybackGainMilli = [uint32]1000
$script:savedTransmitGainMilli = [uint32]16000
$script:scriptLoadingSettings = $false
$script:loadingSettings = $false
$script:preparationStarted = $false
$script:stopTask = $null
$script:nativeExitCleanupPending = $false
$script:channelMutationSafetyStopPending = $false
$script:pendingControlRequests = @{}
$script:pendingStatusRequestId = ''
$script:controlRunId = '4242-1'
$script:controlConfirmed = $true
$script:controlCapabilities = 'hello,status,shutdown,audio.gains.set'
$script:audioGainNativeCapability = $true
$script:audioGainCommandRejected = $false
$script:audioGainRunId = $script:controlRunId
$script:audioGainRevision = [uint64]0
$script:audioGainActual = $null
$script:audioGainRuntimeReady = $false
$script:audioGainProgrammaticUpdate = $false
$script:audioGainDraftRevision = [uint64]0
$script:audioGainResolvedDraftRevision = [uint64]0
$script:audioGainDraft = $null
$script:audioGainPendingRequest = $null
$script:audioGainExpiredRequests = @{}
$script:audioGainAwaitingStatus = $false
$script:audioGainTimedOutDraftRevision = [uint64]0
$script:audioGainDebounceReady = $false
$script:audioGainDebounceTimer = $null
$script:audioGainStatusText = ''
$script:supervisor = New-UiAudioGainSupervisor
(Get-UiControl 'PlaybackGainSlider').Add_ValueChanged({ On-UiAudioGainValueChanged })
(Get-UiControl 'TransmitGainSlider').Add_ValueChanged({ On-UiAudioGainValueChanged })

try {
    Assert-UiAudioGain ((Test-UiRoutingCapabilityList -Commands ([string[]]@('hello','status','shutdown'))) -and
        -not (Test-UiControlSnapshot -Snapshot ([pscustomobject][ordered]@{
            mode='normal';status='running';phase='online';media_seq=[uint64]0;diagnostic=$false;bm_state='ready';
            hri_phase='ready';hri_ready=$true;serial_open=$true;wavein_open=$true;waveout_open=$true;radio_state='connected'
        }))) '有音量 capability 时 status 必须带 audio_gains。'
    $oldSnapshot = [pscustomobject][ordered]@{
        mode='normal';status='running';phase='online';media_seq=[uint64]0;diagnostic=$false;bm_state='ready';
        hri_phase='ready';hri_ready=$true;serial_open=$true;wavein_open=$true;waveout_open=$true;radio_state='connected'
    }
    $script:controlCapabilities = 'hello,status,shutdown'
    Assert-UiAudioGain (Test-UiRoutingCapabilityList -Commands ([string[]]@('hello','status','shutdown'))) '旧三命令能力列表应继续通过。'
    Assert-UiAudioGain (Test-UiControlSnapshot -Snapshot $oldSnapshot) '旧 status fixture 不带 audio_gains 时应继续通过。'
    Assert-UiAudioGain (-not (Test-UiControlSnapshot -Snapshot ([pscustomobject]@{ mode='normal';status='running';phase='online';media_seq=[uint64]0;diagnostic=$false;bm_state='ready';hri_phase='ready';hri_ready=$true;serial_open=$true;wavein_open=$true;waveout_open=$true;radio_state='connected';unexpected='x' }))) '旧 status fixture 的未知字段仍须拒绝。'
    $script:controlCapabilities = 'hello,status,shutdown,audio.gains.set'
    $initial = New-TestAudioGains -Revision 0 -Playback 1000 -Transmit 16000
    $fullSnapshot = [pscustomobject][ordered]@{
        mode='normal';status='running';phase='online';media_seq=[uint64]0;diagnostic=$false;bm_state='ready';
        hri_phase='ready';hri_ready=$true;serial_open=$true;wavein_open=$true;waveout_open=$true;radio_state='connected';audio_gains=$initial
    }
    Assert-UiAudioGain (Test-UiControlSnapshot -Snapshot $fullSnapshot) '新版 status 的精确 audio_gains 字段应通过。'
    Assert-UiAudioGain (-not (Test-UiControlSnapshot -Snapshot ([pscustomobject]@{ mode='normal';status='running';phase='online';media_seq=[uint64]0;diagnostic=$false;bm_state='ready';hri_phase='ready';hri_ready=$true;serial_open=$true;wavein_open=$true;waveout_open=$true;radio_state='connected';audio_gains=$initial;unexpected='x' }))) '新版 status 的未知字段仍须拒绝。'
    $script:controlCapabilities = 'hello,status,shutdown'
    Assert-UiAudioGain (-not (Test-UiRoutingCapabilityList -Commands ([string[]]@('hello','status','shutdown','audio.gains.set','unknown')))) '命令能力白名单不能接受未知命令。'

    Assert-UiAudioGain ((Convert-UiGainSliderToMilli -Value 1) -eq 1000 -and
        (Convert-UiGainSliderToMilli -Value 16) -eq 16000) '滑块应把整数 1..16 转成毫增益。'
    foreach ($badSliderValue in @(0,17,2.5)) {
        $badSliderRejected=$false
        try { [void](Convert-UiGainSliderToMilli -Value $badSliderValue) } catch { $badSliderRejected=$true }
        Assert-UiAudioGain $badSliderRejected ("滑块拒绝范围外或小数增益 {0}。" -f $badSliderValue)
    }
    Assert-UiAudioGain ((Convert-UiStoredGainToMilli -Value 1.5) -eq 2000 -and
        (Convert-UiStoredGainToMilli -Value 0.25) -eq 1000 -and
        (Convert-UiStoredGainToMilli -Value 16) -eq 16000) '旧配置值只在内存中四舍五入并夹到整数 1..16。'
    Assert-UiAudioGain (-not (Test-UiAudioGainsValue -Gains (New-TestAudioGains -Revision 1 -Playback 2001 -Transmit 16000))) `
        'Native 状态读回必须拒绝非整数毫增益。'

    $script:controlCapabilities = 'hello,status,shutdown,audio.gains.set'
    $ackJson = '{"schema_version":2,"type":"control_result","run_id":"4242-1","control_seq":1,"request_id":"audio-gains-1","command":"audio.gains.set","result":"ok","replayed":false,"audio_gains":{"revision":1,"radio_playback_gain_milli":2000,"mic_transmit_gain_milli":16000}}'
    $parsedAck = ConvertFrom-UiControlFrame -Json $ackJson -LockedRunId '4242-1' -LastControlSequence 0
    Assert-UiAudioGain ($parsedAck.audio_gains.radio_playback_gain_milli -eq 2000) '严格控制帧解析应读出 audio.gains.set 确认值。'
    $badAckJson = $ackJson.Replace('"audio_gains":{"revision":1','"audio_gains":{"extra":1,"revision":1')
    $badAckRejected = $false
    try { [void](ConvertFrom-UiControlFrame -Json $badAckJson -LockedRunId '4242-1' -LastControlSequence 0) } catch { $badAckRejected = $true }
    Assert-UiAudioGain $badAckRejected 'audio_gains 子对象的未知字段必须拒绝。'

    Reset-UiAudioGainRun -RunId $script:controlRunId -Capability:$true
    [void](Complete-UiAudioGainStatus -Snapshot (New-TestAudioGainSnapshot -Gains $initial))
    Assert-UiAudioGain ((Get-UiControl 'PlaybackGainSlider').IsEnabled -and (Get-UiControl 'TransmitGainSlider').IsEnabled) `
        'Native capability、hello 确认和实际状态返回后，连接中的增益滑块应启用。'
    Assert-UiAudioGain (([double](Get-UiControl 'PlaybackGainSlider').Value -eq 1.0) -and
        ([double](Get-UiControl 'TransmitGainSlider').Value -eq 16.0)) '初始 status 应按 guard 更新两个滑块。'

    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 2
    Assert-UiAudioGain (Invoke-UiAudioGainDispatcherUntil -Condition { (Get-TestUiGainCommandCount) -eq 1 }) '首个改动应在200ms节流窗口后发送。'
    $firstCommand = @($script:supervisor.Commands | Where-Object { $_.command -ceq 'audio.gains.set' })[0]
    $firstParameters = ConvertFrom-Json -InputObject $firstCommand.parameters_json
    Assert-UiAudioGain ($firstCommand.request_id -ceq 'audio-gains-1' -and $firstParameters.revision -eq 1 -and
        $firstParameters.radio_playback_gain_milli -eq 2000 -and $firstParameters.mic_transmit_gain_milli -eq 16000 -and
        @($firstParameters.PSObject.Properties.Name | Sort-Object) -join ',' -ceq 'mic_transmit_gain_milli,radio_playback_gain_milli,revision') `
        '增益请求必须使用 revision request_id 和恰好三个协议字段。'

    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 2.0
    Wait-UiAudioGainMilliseconds -Milliseconds 240
    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 3.0
    Set-TestUiSlider -Name 'TransmitGainSlider' -Value 2.0
    Wait-UiAudioGainMilliseconds -Milliseconds 240
    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 4.0
    Wait-UiAudioGainMilliseconds -Milliseconds 240
    Assert-UiAudioGain ((Get-TestUiGainCommandCount) -eq 1 -and [uint64]$script:audioGainPendingRequest.revision -eq 1) `
        '连续拖动跨越多个200ms周期时，仍只能保留一个 in-flight 命令。'
    $firstPending = $script:audioGainPendingRequest
    [void]$script:pendingControlRequests.Remove([string]$firstPending.request_id)
    $firstApplied = [pscustomobject][ordered]@{
        request_id=$firstPending.request_id; run_id=$firstPending.run_id; result='ok'; audio_gains=(New-TestAudioGains -Revision 1 -Playback 2000 -Transmit 16000)
    }
    Assert-UiAudioGain (Complete-UiAudioGainResult -Record $firstApplied) '当前 request/revision ACK 应用于运行状态和配置。'
    $afterFirstAck = Read-TestUiGainConfig
    Assert-UiAudioGain ([decimal]$afterFirstAck.audio.radio_playback_gain -eq 2 -and
        [decimal]$afterFirstAck.audio.mic_transmit_gain -eq 16.0) '只有已确认的 Native 实际值应写入临时根 config。'
    Assert-UiAudioGain ([double](Get-UiControl 'PlaybackGainSlider').Value -eq 4.0 -and
        [double](Get-UiControl 'TransmitGainSlider').Value -eq 2.0) '旧 ACK 不得把拖动中的较新滑块草稿跳回。'
    Assert-UiAudioGain ((Get-TestUiGainCommandCount) -eq 2 -and [uint64]$script:audioGainPendingRequest.revision -eq 2) `
        '旧 ACK 后应发送合并后的最新值，且同一时刻仍只有一个 in-flight。'
    $secondCommand = @($script:supervisor.Commands | Where-Object { $_.command -ceq 'audio.gains.set' })[1]
    $secondParameters = ConvertFrom-Json -InputObject $secondCommand.parameters_json
    Assert-UiAudioGain ($secondParameters.revision -eq 2 -and $secondParameters.radio_playback_gain_milli -eq 4000 -and
        $secondParameters.mic_transmit_gain_milli -eq 2000) '第二条命令应合并拖动期间最后一组播放/发送值。'

    $programmaticRevision = [uint64]$script:audioGainDraftRevision
    [void](Set-UiAudioGainSliders -Gains (New-TestAudioGains -Revision 2 -Playback 7000 -Transmit 6000))
    Wait-UiAudioGainMilliseconds -Milliseconds 250
    Assert-UiAudioGain ([uint64]$script:audioGainDraftRevision -eq $programmaticRevision -and (Get-TestUiGainCommandCount) -eq 2) `
        'status/配置程序化写滑块必须被 guard 拦截，不触发新 IPC。'
    Assert-UiAudioGain ([decimal](Read-TestUiGainConfig).audio.radio_playback_gain -eq 2) '程序化滑块更新不得写入配置。'

    $secondPending = $script:audioGainPendingRequest
    [void]$script:pendingControlRequests.Remove([string]$secondPending.request_id)
    $secondApplied = [pscustomobject][ordered]@{
        request_id=$secondPending.request_id; run_id=$secondPending.run_id; result='ok'; audio_gains=(New-TestAudioGains -Revision 2 -Playback 5000 -Transmit 3000)
    }
    Assert-UiAudioGain (Complete-UiAudioGainResult -Record $secondApplied) '第二个实际值 ACK 应完成写回。'
    $afterSecondAck = Read-TestUiGainConfig
    Assert-UiAudioGain ([decimal]$afterSecondAck.audio.radio_playback_gain -eq 5 -and
        [decimal]$afterSecondAck.audio.mic_transmit_gain -eq 3) '配置应保存 Native ACK 的整数 actual readback，而不是请求值。'
    Assert-UiAudioGain ([double](Get-UiControl 'PlaybackGainSlider').Value -eq 5 -and
        [double](Get-UiControl 'TransmitGainSlider').Value -eq 3) 'ACK readback 应更新整数滑块值。'

    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 6
    Assert-UiAudioGain (Invoke-UiAudioGainDispatcherUntil -Condition { (Get-TestUiGainCommandCount) -eq 3 }) '错误回归前应真实发送一次 fake gain 命令。'
    $failedPending = $script:audioGainPendingRequest
    [void]$script:pendingControlRequests.Remove([string]$failedPending.request_id)
    $beforeFailure = Read-TestUiGainConfig
    Complete-UiAudioGainFailure -Record ([pscustomobject]@{request_id=$failedPending.request_id;run_id=$failedPending.run_id;result='rejected';error='invalid_audio_gains'})
    Assert-UiAudioGain ($script:audioGainAwaitingStatus -and (Get-TestUiGainCommandCount -Command 'status') -eq 1) `
        '拒绝响应不得假装应用；应发 status 查询校准。'
    [void]$script:pendingControlRequests.Remove([string]$script:pendingStatusRequestId)
    $script:pendingStatusRequestId = ''
    [void](Complete-UiAudioGainStatus -Snapshot (New-TestAudioGainSnapshot -Gains (New-TestAudioGains -Revision 2 -Playback 5000 -Transmit 3000)))
    $afterFailureStatus = Read-TestUiGainConfig
    Assert-UiAudioGain ([decimal]$afterFailureStatus.audio.radio_playback_gain -eq [decimal]$beforeFailure.audio.radio_playback_gain -and
        [double](Get-UiControl 'PlaybackGainSlider').Value -eq 5) '错误后的 status 只校准真实滑块，不写入失败草稿。'
    Wait-UiAudioGainMilliseconds -Milliseconds 240
    Assert-UiAudioGain ((Get-TestUiGainCommandCount) -eq 3) 'status 校准不得重发失败的同一请求。'

    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 7
    Assert-UiAudioGain (Invoke-UiAudioGainDispatcherUntil -Condition { (Get-TestUiGainCommandCount) -eq 4 }) 'timeout 回归前应发送新的 revision。'
    $timedOut = $script:audioGainPendingRequest
    $timedOut.started_utc = [DateTime]::UtcNow.AddSeconds(-9)
    $beforeTimeout = Read-TestUiGainConfig
    Assert-UiAudioGain (Expire-UiAudioGainRequest) '超过等待时间的请求应进入 status 校准。'
    $timeoutStatusRequestCount = @($script:supervisor.Commands | Where-Object { $_.command -ceq 'status' }).Count
    $timeoutStateReady = ($null -eq $script:audioGainPendingRequest) -and [bool]$script:audioGainAwaitingStatus -and
        [int]$timeoutStatusRequestCount -eq 2
    Assert-UiAudioGain $timeoutStateReady 'timeout 后必须清除待确认状态并读取当前 Native 值。'
    [void]$script:pendingControlRequests.Remove([string]$script:pendingStatusRequestId)
    $script:pendingStatusRequestId = ''
    [void](Complete-UiAudioGainStatus -Snapshot (New-TestAudioGainSnapshot -Gains (New-TestAudioGains -Revision 2 -Playback 5000 -Transmit 3000)))
    $afterTimeout = Read-TestUiGainConfig
    Assert-UiAudioGain ([decimal]$afterTimeout.audio.radio_playback_gain -eq [decimal]$beforeTimeout.audio.radio_playback_gain -and
        [double](Get-UiControl 'PlaybackGainSlider').Value -eq 5) 'timeout status 只显示 Native 实际值，不把 timeout 草稿写入配置。'
    Wait-UiAudioGainMilliseconds -Milliseconds 240
    Assert-UiAudioGain ((Get-TestUiGainCommandCount) -eq 4) 'timeout/status 流程不得重发超时的 request_id。'
    $beforeExpiredAck = Read-TestUiGainConfig
    $lateTimedOutAck = [pscustomobject][ordered]@{
        command='audio.gains.set'; request_id=$timedOut.request_id; run_id=$timedOut.run_id; result='ok';
        audio_gains=(New-TestAudioGains -Revision $timedOut.revision -Playback 8000 -Transmit 3000)
    }
    Assert-UiAudioGain (Consume-UiAudioGainExpiredResult -Record $lateTimedOutAck) 'timeout 后到达的 ACK 应从事件队列中明确丢弃。'
    $afterExpiredAck = Read-TestUiGainConfig
    Assert-UiAudioGain ([decimal]$afterExpiredAck.audio.radio_playback_gain -eq [decimal]$beforeExpiredAck.audio.radio_playback_gain -and
        [decimal]$afterExpiredAck.audio.mic_transmit_gain -eq [decimal]$beforeExpiredAck.audio.mic_transmit_gain) `
        'timeout 后的过期成功 ACK 不得持久化到根 config。'

    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 8
    Assert-UiAudioGain (Invoke-UiAudioGainDispatcherUntil -Condition { (Get-TestUiGainCommandCount) -eq 5 }) '逾期ACK用例应先真实发送新 revision。'
    $expiredPending = $script:audioGainPendingRequest
    $expiredPending.started_utc = [DateTime]::UtcNow.AddSeconds(-9)
    $beforeOverdueAck = Read-TestUiGainConfig
    $overdueAck = [pscustomobject][ordered]@{
        request_id=$expiredPending.request_id; run_id=$expiredPending.run_id; result='ok';
        audio_gains=(New-TestAudioGains -Revision $expiredPending.revision -Playback 9000 -Transmit 3000)
    }
    Assert-UiAudioGain (-not (Complete-UiAudioGainResult -Record $overdueAck)) '超过8秒的ACK不得按及时ACK完成。'
    $afterOverdueAck = Read-TestUiGainConfig
    Assert-UiAudioGain ($script:audioGainAwaitingStatus -and
        [decimal]$afterOverdueAck.audio.radio_playback_gain -eq [decimal]$beforeOverdueAck.audio.radio_playback_gain -and
        [decimal]$afterOverdueAck.audio.mic_transmit_gain -eq [decimal]$beforeOverdueAck.audio.mic_transmit_gain) `
        '8秒后刚到达的成功ACK也必须先status校准，不能写配置。'
    [void]$script:pendingControlRequests.Remove([string]$script:pendingStatusRequestId)
    $script:pendingStatusRequestId = ''
    [void](Complete-UiAudioGainStatus -Snapshot (New-TestAudioGainSnapshot -Gains (New-TestAudioGains -Revision 2 -Playback 5000 -Transmit 3000)))
    Assert-UiAudioGain ([decimal](Read-TestUiGainConfig).audio.radio_playback_gain -eq [decimal]$beforeOverdueAck.audio.radio_playback_gain) `
        '逾期ACK后的status对齐仍不写入root config。'

    $runBeforeChange = $script:controlRunId
    Reset-UiAudioGainRun -RunId '4242-2' -Capability:$true -RestoreSavedValues
    $script:controlRunId = '4242-2'
    [void](Complete-UiAudioGainStatus -Snapshot (New-TestAudioGainSnapshot -Gains (New-TestAudioGains -Revision 0 -Playback 1000 -Transmit 16000)))
    $beforeOldAck = Read-TestUiGainConfig
    $lateOldAck = [pscustomobject][ordered]@{
        request_id='audio-gains-99'; run_id=$runBeforeChange; result='ok'; audio_gains=(New-TestAudioGains -Revision 99 -Playback 9000 -Transmit 9000)
    }
    [void](Complete-UiAudioGainResult -Record $lateOldAck)
    $afterOldAck = Read-TestUiGainConfig
    Assert-UiAudioGain ($script:controlRunId -ceq '4242-2' -and
        [decimal]$afterOldAck.audio.radio_playback_gain -eq [decimal]$beforeOldAck.audio.radio_playback_gain -and
        [decimal]$afterOldAck.audio.mic_transmit_gain -eq [decimal]$beforeOldAck.audio.mic_transmit_gain) `
        '新 run 必须忽略旧 run 的 ACK，不能把旧值写进根 config。'
    $oldRunRejected = $false
    try { [void](ConvertFrom-UiControlFrame -Json $ackJson -LockedRunId '4242-2' -LastControlSequence 0) } catch { $oldRunRejected = $true }
    Assert-UiAudioGain $oldRunRejected '严格 control frame parser 应拒绝上一 run 的 ACK。'

    $script:controlCapabilities = 'hello,status,shutdown'
    Reset-UiAudioGainRun -RunId '4242-2' -Capability:$false
    $script:audioGainRuntimeReady = $true
    Update-UiAudioGainControls
    Assert-UiAudioGain (-not (Get-UiControl 'PlaybackGainSlider').IsEnabled -and $script:controlRunId -ceq '4242-2') `
        '旧 Native 没有 gain capability 时应保持连接可用、只禁用实时调节。'
    $script:supervisor = $null
    Update-UiAudioGainControls
    Assert-UiAudioGain ((Get-UiControl 'PlaybackGainSlider').IsEnabled -and (Get-UiControl 'TransmitGainSlider').IsEnabled) `
        '离线时仍应允许修改并保存偏好值。'
    Set-TestUiSlider -Name 'PlaybackGainSlider' -Value 3
    $offlineConfig = Read-TestUiGainConfig
    Assert-UiAudioGain ([decimal]$offlineConfig.audio.radio_playback_gain -eq 3) '离线滑块修改应保存到隔离根 config。'

    $script:mainWindow.Close()
    Write-Output ("PASS: {0} UI audio-gain assertions; fake WPF and isolated config only." -f $script:assertionCount)
} finally {
    if ($script:audioGainDebounceTimer) { $script:audioGainDebounceTimer.Stop() }
    if ($script:mainWindow -and $script:mainWindow.IsVisible) { $script:mainWindow.Close() }
    if ([System.IO.Directory]::Exists($script:testRoot)) {
        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $testRootFull = [System.IO.Path]::GetFullPath($script:testRoot).TrimEnd('\')
        $requiredPrefix = $tempBase + 'wirex-ui-audio-gain-'
        if (-not $testRootFull.StartsWith($requiredPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
            throw '拒绝清理位于系统临时目录之外的测试路径。'
        }
        Remove-Item -LiteralPath $testRootFull -Recurse -Force
    }
}
