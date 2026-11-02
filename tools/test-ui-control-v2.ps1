[CmdletBinding()]
param(
    [string]$NativeExecutable = '',
    [string]$UiPackageDirectory = '',
    [switch]$ParserOnly,
    [string]$BmProtocolFramesPath = ''
)

$ErrorActionPreference = 'Stop'
function Assert-UiControl {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}
function Wait-UiControlEvent {
    param($Supervisor, [string]$Type, [string]$Command, [string]$RequestId, [int]$TimeoutMilliseconds = 5000)
    if (-not $script:uiControlBacklog) { $script:uiControlBacklog = New-Object 'System.Collections.Generic.Queue[string]' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        foreach ($line in @($Supervisor.DrainControlEvents(32))) { $script:uiControlBacklog.Enqueue([string]$line) }
        $count = $script:uiControlBacklog.Count
        for ($index = 0; $index -lt $count; $index++) {
            $line = $script:uiControlBacklog.Dequeue()
            try { $candidate = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
            if ([string]$candidate.type -ceq $Type -and
                (-not $Command -or [string]$candidate.command -ceq $Command) -and
                (-not $RequestId -or [string]$candidate.request_id -ceq $RequestId)) { return $line }
            $script:uiControlBacklog.Enqueue($line)
        }
        if ($Supervisor.HasExited) { break }
        Start-Sleep -Milliseconds 20
    }
    throw "等待控制消息超时：$Type $Command"
}
function Assert-UiControlFrameRejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-UiControl $rejected $Message
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$NativeExecutable = if ($NativeExecutable) { [System.IO.Path]::GetFullPath($NativeExecutable) } else { '' }
$uiWindowsDirectory = Join-Path $repoRoot 'ui\windows'
if (-not [string]::IsNullOrWhiteSpace($UiPackageDirectory)) {
    $UiPackageDirectory = [System.IO.Path]::GetFullPath($UiPackageDirectory)
    $uiWindowsDirectory = Join-Path $UiPackageDirectory 'ui\windows'
}
$uiScript = Join-Path $uiWindowsDirectory 'bridge-ui.ps1'
$supervisorSource = Join-Path $uiWindowsDirectory 'BridgeSupervisor.cs'
if (-not [System.IO.File]::Exists($uiScript) -or -not [System.IO.File]::Exists($supervisorSource)) {
    throw "缺少用于离线协议测试的 UI 文件：$uiWindowsDirectory"
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiScript, [ref]$tokens, [ref]$parseErrors)
Assert-UiControl ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
foreach ($functionName in @('Test-UiExactControlFields','Test-UiControlUnsigned','Test-UiAudioGainsValue',
        'Test-UiAudioGainCapability','Test-UiControlSnapshot',
        'Test-UiRxPolicy','Test-UiRoutingCapabilityList','Test-UiRoutingSnapshot','Test-UiHasCapability',
        'Test-UiBmConnectionState','Get-UiBmConnectionErrorText','Get-UiBmConnectionRejectText','ConvertFrom-UiControlFrame')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
    Assert-UiControl ($null -ne $functionAst) "缺少控制消息验证函数：$functionName"
    Invoke-Expression $functionAst.Extent.Text
}
$script:controlCapabilities='bm.connection.set'
$testRunId='12345-1'
$acceptedBmFrame=[pscustomobject][ordered]@{
    schema_version=2;type='control_result';run_id=$testRunId;control_seq=[uint64]1
    request_id='7e40599a-4c69-4cb9-9505-21a28ab58a88';command='bm.connection.set';result='accepted';replayed=$false
    bm_connection=[pscustomobject][ordered]@{requested_enabled=$true;revision=[uint64]1;transport_open=$false}
    bm_resolving=$true;bm_connection_error='none';bm_state='stopped'
}
$acceptedBm=ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $acceptedBmFrame -Compress -Depth 6) -LockedRunId $testRunId
Assert-UiControl ($acceptedBm.result -ceq 'accepted' -and $acceptedBm.bm_resolving -and
    $acceptedBm.bm_connection.requested_enabled -and $acceptedBm.bm_connection.revision -eq 1) `
    'accepted BM ACK 必须允许无 error 的异步 DNS 解析快照。'
$rejectedBmFrame=[pscustomobject][ordered]@{
    schema_version=2;type='control_result';run_id=$testRunId;control_seq=[uint64]2
    request_id='7e40599a-4c69-4cb9-9505-21a28ab58a89';command='bm.connection.set';result='rejected';replayed=$false
    error='bm_revision_stale';bm_connection=[pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]0;transport_open=$false}
    bm_resolving=$false;bm_connection_error='none';bm_state='stopped'
}
$rejectedBm=ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $rejectedBmFrame -Compress -Depth 6) -LockedRunId $testRunId -LastControlSequence 1
Assert-UiControl ($rejectedBm.result -ceq 'rejected' -and $rejectedBm.error -ceq 'bm_revision_stale' -and
    $rejectedBm.bm_connection.revision -eq 0) 'rejected BM ACK 必须接受 Native 返回的 revision=0 快照。'
$safeBmRejectCodes=@('bm_revision_conflict','bm_transition_busy','bm_password_required','bm_master_resolution_failed','bm_profile_invalid','bm_transport_open_failed')
foreach ($rejectCode in $safeBmRejectCodes) {
    $rejectedBmFrame.control_seq=[uint64]([uint64]$rejectedBmFrame.control_seq + 1)
    $rejectedBmFrame.error=$rejectCode
    $parsedReject=ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $rejectedBmFrame -Compress -Depth 6) `
        -LockedRunId $testRunId -LastControlSequence ([uint64]($rejectedBmFrame.control_seq - 1))
    Assert-UiControl ($parsedReject.error -ceq $rejectCode) ('BM control rejection code was not accepted: ' + $rejectCode)
}
$invalidBmStateFrame=$acceptedBmFrame.PSObject.Copy()
$invalidBmStateFrame.control_seq=[uint64]3; $invalidBmStateFrame.bm_state='connecting'
Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $invalidBmStateFrame -Compress -Depth 6) -LockedRunId $testRunId -LastControlSequence 2 } `
    'UI 必须拒绝 Native 状态机之外的 connecting 枚举。'
$unsafeBmErrorFrame=$acceptedBmFrame.PSObject.Copy()
$unsafeBmErrorFrame.control_seq=[uint64]3; $unsafeBmErrorFrame.bm_connection_error='host.example:62031'
Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $unsafeBmErrorFrame -Compress -Depth 6) -LockedRunId $testRunId -LastControlSequence 2 } `
    'UI 必须拒绝可能包含服务器或凭据的 BM 错误文本。'
$acceptedWithErrorFrame=$acceptedBmFrame.PSObject.Copy()
$acceptedWithErrorFrame.control_seq=[uint64]3; $acceptedWithErrorFrame | Add-Member -NotePropertyName error -NotePropertyValue 'bm_invalid_request'
Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $acceptedWithErrorFrame -Compress -Depth 6) -LockedRunId $testRunId -LastControlSequence 2 } `
    'accepted BM ACK 不得携带 rejection error。'
$snapshotFrame=[pscustomobject][ordered]@{
    schema_version=2;type='control_result';run_id=$testRunId;control_seq=[uint64]3
    request_id='7e40599a-4c69-4cb9-9505-21a28ab58a8a';command='status';result='ok';replayed=$false
    snapshot=[pscustomobject][ordered]@{
        mode='manual';status='running';phase='active';media_seq=[uint64]1;diagnostic=$false;bm_state='stopped'
        hri_phase='ready';hri_ready=$true;serial_open=$true;wavein_open=$false;waveout_open=$false;radio_state='unknown'
        bm_connection=[pscustomobject][ordered]@{requested_enabled=$false;revision=[uint64]0;transport_open=$false}
        bm_resolving=$false;bm_connection_error='master_resolution_failed'
    }
}
$parsedSnapshot=ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $snapshotFrame -Compress -Depth 8) -LockedRunId $testRunId -LastControlSequence 2
Assert-UiControl ($parsedSnapshot.snapshot.bm_connection_error -ceq 'master_resolution_failed' -and
    (Test-UiBmConnectionState -Connection $parsedSnapshot.snapshot.bm_connection -BmState $parsedSnapshot.snapshot.bm_state `
        -Resolving $parsedSnapshot.snapshot.bm_resolving -Error $parsedSnapshot.snapshot.bm_connection_error)) `
    '周期 status 必须接受连接已失败、UDP关闭且无凭据的安全状态枚举。'
$transitionCases=@(
    [pscustomobject]@{name='取消DNS进行中';requested=$false;resolving=$true;transport=$false;state='stopped';error='none'},
    [pscustomobject]@{name='取消DNS解析超时';requested=$false;resolving=$true;transport=$false;state='stopped';error='master_resolution_timeout'},
    [pscustomobject]@{name='取消DNS清理超时';requested=$false;resolving=$true;transport=$false;state='stopped';error='resolver_cancel_timeout'},
    [pscustomobject]@{name='语音清理超时仍连接';requested=$false;resolving=$false;transport=$true;state='ready';error='media_cleanup_timeout'},
    [pscustomobject]@{name='语音清理后等待RPTCL';requested=$false;resolving=$false;transport=$true;state='stopped';error='media_cleanup_timeout'},
    [pscustomobject]@{name='旧清理错误但已完全关闭';requested=$false;resolving=$false;transport=$false;state='stopped';error='media_cleanup_timeout'}
)
foreach ($transition in $transitionCases) {
    $snapshotFrame.control_seq=[uint64]([uint64]$snapshotFrame.control_seq + 1)
    $snapshotFrame.snapshot.bm_connection=[pscustomobject][ordered]@{
        requested_enabled=[bool]$transition.requested;revision=[uint64]0;transport_open=[bool]$transition.transport
    }
    $snapshotFrame.snapshot.bm_resolving=[bool]$transition.resolving
    $snapshotFrame.snapshot.bm_state=[string]$transition.state
    $snapshotFrame.snapshot.bm_connection_error=[string]$transition.error
    $transitionFrame=ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $snapshotFrame -Compress -Depth 8) `
        -LockedRunId $testRunId -LastControlSequence ([uint64]($snapshotFrame.control_seq - 1))
    Assert-UiControl ($transitionFrame.snapshot.bm_connection_error -ceq $transition.error -and
        (Test-UiBmConnectionState -Connection $transitionFrame.snapshot.bm_connection -BmState $transitionFrame.snapshot.bm_state `
            -Resolving $transitionFrame.snapshot.bm_resolving -Error $transitionFrame.snapshot.bm_connection_error)) `
        ('status parser 拒绝合法的BM过渡快照：' + $transition.name)
}
foreach ($invalidCase in @(
    [pscustomobject]@{requested=$true;resolving=$true;transport=$false;state='stopped';error='resolver_cancel_timeout'},
    [pscustomobject]@{requested=$false;resolving=$true;transport=$false;state='stopped';error='password_required'},
    [pscustomobject]@{requested=$false;resolving=$true;transport=$false;state='stopped';error='media_cleanup_timeout'},
    [pscustomobject]@{requested=$false;resolving=$false;transport=$false;state='ready';error='media_cleanup_timeout'},
    [pscustomobject]@{requested=$true;resolving=$false;transport=$false;state='ready';error='none'}
)) {
    $validState=Test-UiBmConnectionState `
        -Connection ([pscustomobject][ordered]@{requested_enabled=[bool]$invalidCase.requested;revision=[uint64]0;transport_open=[bool]$invalidCase.transport}) `
        -BmState ([string]$invalidCase.state) -Resolving ([bool]$invalidCase.resolving) -Error ([string]$invalidCase.error)
    Assert-UiControl (-not $validState) 'UI BM snapshot parser 必须拒绝违反DNS、Session或UDP状态关系的帧。'
}
foreach ($safeError in @('password_required','master_resolution_failed','master_resolution_timeout','resolver_cancel_timeout',
        'profile_invalid','transport_open_failed','media_cleanup_timeout')) {
    $userText=Get-UiBmConnectionErrorText -ErrorCode $safeError
    Assert-UiControl (-not [string]::IsNullOrWhiteSpace($userText) -and $userText -cnotmatch 'password|master|profile|transport|revision|核心') `
        ('BM连接失败没有映射为面向用户的安全中文提示：' + $safeError)
}
foreach ($safeReject in @('bm_revision_stale','bm_revision_conflict','bm_transition_busy','bm_password_required',
        'bm_master_resolution_failed','bm_profile_invalid','bm_transport_open_failed','hello_required',
        'invalid_bm_connection_parameters')) {
    $userText=Get-UiBmConnectionRejectText -ErrorCode $safeReject
    Assert-UiControl (-not [string]::IsNullOrWhiteSpace($userText) -and $userText -cnotmatch 'bm_|revision|核心') `
        ('BM控制拒绝没有映射为面向用户的安全中文提示：' + $safeReject)
}
$bmProtocolFrameCounts=@{control_ready=0;hello=0;accepted=0;rejected=0;unsupported=0;status=0}
if (-not [string]::IsNullOrWhiteSpace($BmProtocolFramesPath)) {
    $framesPath=[System.IO.Path]::GetFullPath($BmProtocolFramesPath)
    if (-not [System.IO.File]::Exists($framesPath)) { throw '指定的 Native BM 协议帧文件不存在。' }
    $lines=@([System.IO.File]::ReadAllLines($framesPath,[System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 10 -or $lines.Count -gt 64) { throw 'Native BM 协议帧样本数量不在允许范围内。' }
    $frameRunId=''; $frameSequence=[uint64]0; $firstFrameRunId=''; $secondFrameRunId=''; $frameResults=@{}
    foreach ($line in $lines) {
        try { $rawFrame=ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { throw 'Native BM 协议帧文件包含无效 JSON。' }
        if ($rawFrame.type -ceq 'control_ready') {
            # 每个 control_ready 开始一条新 run，旧 run 的序号与能力不能继承。
            $frameRunId=''; $frameSequence=[uint64]0; $script:controlCapabilities=''
            $parsedFrame=ConvertFrom-UiControlFrame -Json $line
            $frameRunId=[string]$parsedFrame.run_id
            if ($bmProtocolFrameCounts.control_ready -eq 0) { $firstFrameRunId=$frameRunId } else { $secondFrameRunId=$frameRunId }
            $frameSequence=[uint64]$parsedFrame.control_seq
            $script:controlCapabilities=[string](@($parsedFrame.supported_commands) -join ',')
            $bmProtocolFrameCounts.control_ready++
        } else {
            if (-not $frameRunId) { throw 'Native BM 协议样本必须先发送 control_ready。' }
            $parsedFrame=ConvertFrom-UiControlFrame -Json $line -LockedRunId $frameRunId -LastControlSequence $frameSequence
            $frameSequence=[uint64]$parsedFrame.control_seq
            if ($parsedFrame.command -ceq 'hello') { $bmProtocolFrameCounts.hello++ }
            if ($parsedFrame.command -ceq 'bm.connection.set') {
                $bmProtocolFrameCounts[[string]$parsedFrame.result]++
                $frameResults[('{0}|{1}' -f $frameRunId,$parsedFrame.control_seq)]=$parsedFrame
            } elseif ($parsedFrame.command -ceq 'status') { $bmProtocolFrameCounts.status++ }
        }
    }
    Assert-UiControl ($bmProtocolFrameCounts.control_ready -eq 2 -and $bmProtocolFrameCounts.hello -eq 2 -and
        $bmProtocolFrameCounts.accepted -ge 3 -and $bmProtocolFrameCounts.rejected -ge 3 -and
        $bmProtocolFrameCounts.unsupported -eq 1 -and $bmProtocolFrameCounts.status -ge 1) `
        '真实 Native BM Dispatcher 样本未完整覆盖双 run、握手、请求结果和状态帧。'
    Assert-UiControl ($frameResults[('{0}|2' -f $firstFrameRunId)].error -ceq 'hello_required' -and
        $frameResults[('{0}|4' -f $firstFrameRunId)].error -ceq 'invalid_bm_connection_parameters' -and
        $frameResults[('{0}|7' -f $firstFrameRunId)].error -ceq 'bm_transition_busy' -and
        $frameResults[('{0}|3' -f $secondFrameRunId)].error -ceq 'command_not_supported' -and
        $frameResults[('{0}|3' -f $secondFrameRunId)].result -ceq 'unsupported') `
        '真实 Native BM 帧的 pre-hello、参数错误、busy 和旧核心 unsupported 拒绝没有由 PowerShell parser 识别。'
}
$diagnosticCommands=[string[]]@('hello','status','shutdown','bm.connection.set')
$diagnosticReady=[pscustomobject][ordered]@{
    schema_version=2;type='control_ready';run_id=('{0}-1' -f [System.Diagnostics.Process]::GetCurrentProcess().Id)
    control_seq=[uint64]1;process_id=[uint32][System.Diagnostics.Process]::GetCurrentProcess().Id
    control_version=2;supported_commands=$diagnosticCommands;diagnostic=$true
}
Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $diagnosticReady -Compress -Depth 6) -ExpectedProcessId ([System.Diagnostics.Process]::GetCurrentProcess().Id) } `
    '诊断核心不得声明BM独立连接命令。'
if ($ParserOnly) {
    Write-Output ('通过：BM 控制帧 parser 覆盖异步状态、revision=0 拒绝、安全错误码与 capability 隔离。真实 Dispatcher 帧：{0} 行。' -f `
        $(if ($BmProtocolFramesPath) { $lines.Count } else { 0 }))
    return
}
if (-not $NativeExecutable -or -not [System.IO.File]::Exists($NativeExecutable)) { throw "缺少 Native 控制诊断核心：$NativeExecutable" }
$legacyRoutingCommands = [string[]]@('hello','status','shutdown','routing.status','rx_policy.replace','tx_policy.replace')
$quickCallRoutingCommands = $legacyRoutingCommands + 'network_subscription.quick_call_join'
$identityBasicCommands = [string[]]@('hello','status','shutdown','radio_identity.cache_upsert')
$identityRoutingCommands = $legacyRoutingCommands + 'radio_identity.cache_upsert'
$identityQuickCallCommands = $quickCallRoutingCommands + 'radio_identity.cache_upsert'
$audioBasicCommands = $legacyRoutingCommands[0..2] + 'audio.gains.set'
$audioRoutingCommands = $legacyRoutingCommands + 'audio.gains.set'
$audioQuickCallRoutingCommands = $quickCallRoutingCommands + 'audio.gains.set'
$audioIdentityBasicCommands = $identityBasicCommands + 'audio.gains.set'
$audioIdentityRoutingCommands = $identityRoutingCommands + 'audio.gains.set'
$audioIdentityQuickCallCommands = $identityQuickCallCommands + 'audio.gains.set'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $legacyRoutingCommands) '界面必须继续接受旧版六命令路由核心。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $quickCallRoutingCommands) '界面必须识别新增Quick Call命令能力。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $identityBasicCommands) '界面必须识别基础 Native identity capability。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $identityRoutingCommands) '界面必须识别带 Native identity 的路由能力集。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $identityQuickCallCommands) '界面必须识别带 Native identity 的完整能力集。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $audioBasicCommands) '界面必须识别仅含音量控制的新版 Native 能力集。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $audioRoutingCommands) '界面必须识别路由与音量能力组合。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $audioQuickCallRoutingCommands) '界面必须识别动态组呼与音量能力组合。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $audioIdentityBasicCommands) '界面必须识别 identity 与音量能力组合。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $audioIdentityRoutingCommands) '界面必须识别路由、identity 与音量能力组合。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $audioIdentityQuickCallCommands) '界面必须识别完整 Native 能力组合。'
Add-Type -Path $supervisorSource
$supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
$noGainSupervisor = New-Object WirexBridge.Ui.BridgeSupervisor
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-ui-routing-control-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$passed = $false
try {
    $supervisor.Start($NativeExecutable, [string[]]@('--routing-diagnostic','--ui-pipe','--ui-control-version','2'), $tempRoot, 2)
    $readyLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_ready' -Command '' -RequestId '' -TimeoutMilliseconds 10000
    $ready = ConvertFrom-UiControlFrame -Json $readyLine -ExpectedProcessId $supervisor.ProcessId
    $expectedCommands = 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace,network_subscription.quick_call_join,radio_identity.cache_upsert,audio.gains.set'
    $script:controlCapabilities = @($ready.supported_commands) -join ','
    Assert-UiControl ([bool]$ready.diagnostic -and $ready.control_version -eq 2 -and
        (@($ready.supported_commands) -join ',' -ceq $expectedCommands)) 'ready 必须报告 v2 本地路由诊断与完整命令集。'
    Assert-UiControl $supervisor.SetControlRunId([string]$ready.run_id) 'Supervisor 必须锁定本次进程的 run_id。'
    $lastControlSequence = [uint64]$ready.control_seq

    $helloRequestId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($helloRequestId,'hello')) 'hello 必须经 WPF 匿名管道发送。'
    $helloLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'hello' -RequestId $helloRequestId
    $hello = ConvertFrom-UiControlFrame -Json $helloLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($hello.result -ceq 'ok' -and -not $hello.replayed -and (@($hello.supported_commands) -join ',' -ceq $expectedCommands)) 'hello 必须确认路由命令集。'
    $lastControlSequence = [uint64]$hello.control_seq
    $pushLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'routing_state' -Command '' -RequestId ''
    $push = ConvertFrom-UiControlFrame -Json $pushLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($push.routing.local_source_id -eq 1 -and $push.routing.rx_policy_revision -eq 2 -and
        $push.routing.tx_policy_revision -eq 2 -and $push.routing.rx_policy.group_mode -ceq 'selected' -and
        $push.routing.rx_policy.private_mode -ceq 'disabled' -and $push.routing.rx_policy.allow_groups.Count -eq 0 -and
        $push.routing.tx_target.destination_id -eq 91 -and $push.routing.tx_target.kind -ceq 'group' -and
        $push.routing.tx_target.slot -eq 2 -and -not $push.routing.transmit_enabled) '初始路由状态必须使用ID1、空Selected/disabled策略和只收TG91。'
    $lastControlSequence = [uint64]$push.control_seq
    $initialPushBytes = [System.Text.Encoding]::UTF8.GetByteCount($pushLine)
    Assert-UiControl (-not $supervisor.HasControlEventOverflow) '首个 routing_state push 不得触发队列溢出。'

    $statusRequestId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($statusRequestId,'routing.status')) 'routing.status 必须支持无参数请求。'
    $statusLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'routing.status' -RequestId $statusRequestId
    $status = ConvertFrom-UiControlFrame -Json $statusLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($status.result -ceq 'ok' -and $status.routing.local_source_id -eq 1) 'routing.status 必须返回当前完整快照。'
    $lastControlSequence = [uint64]$status.control_seq

    $initialStatusId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($initialStatusId,'status')) 'status 必须能查询 Native 实际音量初值。'
    $initialStatusLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'status' -RequestId $initialStatusId
    $initialStatus = ConvertFrom-UiControlFrame -Json $initialStatusLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($initialStatus.result -ceq 'ok' -and $initialStatus.snapshot.audio_gains.revision -eq 0 -and
        $initialStatus.snapshot.audio_gains.radio_playback_gain_milli -eq 1000 -and
        $initialStatus.snapshot.audio_gains.mic_transmit_gain_milli -eq 16000) 'status 必须返回默认增益和 revision=0。'
    $lastControlSequence = [uint64]$initialStatus.control_seq

    $gainRouteBefore = ConvertTo-Json -InputObject $status.routing -Depth 12 -Compress
    $gainRequestId = 'audio-gains-1'
    $gainParameters = '{"revision":1,"radio_playback_gain_milli":1250,"mic_transmit_gain_milli":8000}'
    Assert-UiControl ($supervisor.SendControlCommand($gainRequestId,'audio.gains.set',$gainParameters)) `
        'BridgeSupervisor 白名单必须允许有界的 Native 实时音量命令。'
    $gainLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'audio.gains.set' -RequestId $gainRequestId
    $gainAck = ConvertFrom-UiControlFrame -Json $gainLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($gainAck.result -ceq 'ok' -and $gainAck.audio_gains.revision -eq 1 -and
        $gainAck.audio_gains.radio_playback_gain_milli -eq 1250 -and
        $gainAck.audio_gains.mic_transmit_gain_milli -eq 8000 -and -not $gainAck.replayed) `
        'Native 必须 ACK 两路增益的实际值和单调 revision。'
    $lastControlSequence = [uint64]$gainAck.control_seq

    Assert-UiControl ($supervisor.SendControlCommand($gainRequestId,'audio.gains.set',$gainParameters)) `
        '最新音量值允许通过同 request ID 安全重放。'
    $gainReplayLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'audio.gains.set' -RequestId $gainRequestId
    $gainReplay = ConvertFrom-UiControlFrame -Json $gainReplayLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($gainReplay.result -ceq 'ok' -and $gainReplay.replayed -and
        $gainReplay.audio_gains.radio_playback_gain_milli -eq 1250 -and
        $gainReplay.audio_gains.mic_transmit_gain_milli -eq 8000) '最新 revision 重放必须返回相同实际音量且不再次应用。'
    $lastControlSequence = [uint64]$gainReplay.control_seq

    $gainConflictParameters = '{"revision":1,"radio_playback_gain_milli":2000,"mic_transmit_gain_milli":8000}'
    Assert-UiControl ($supervisor.SendControlCommand($gainRequestId,'audio.gains.set',$gainConflictParameters)) '冲突音量 payload 应进入 Native 校验。'
    $gainConflictLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'audio.gains.set' -RequestId $gainRequestId
    $gainConflict = ConvertFrom-UiControlFrame -Json $gainConflictLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($gainConflict.result -ceq 'rejected' -and $gainConflict.error -ceq 'audio_gain_revision_conflict') `
        '相同 revision 的不同音量对必须被拒绝。'
    $lastControlSequence = [uint64]$gainConflict.control_seq

    $invalidGainId = 'audio-gains-2'
    Assert-UiControl ($supervisor.SendControlCommand($invalidGainId,'audio.gains.set',
        '{"revision":2,"radio_playback_gain_milli":249,"mic_transmit_gain_milli":8000}')) '越界音量值应送 Native 做明确拒绝。'
    $invalidGainLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'audio.gains.set' -RequestId $invalidGainId
    $invalidGain = ConvertFrom-UiControlFrame -Json $invalidGainLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($invalidGain.result -ceq 'rejected' -and $invalidGain.error -ceq 'invalid_audio_gains') '0.249x 必须被 Native 拒绝。'
    $lastControlSequence = [uint64]$invalidGain.control_seq

    $secondGainParameters = '{"revision":2,"radio_playback_gain_milli":750,"mic_transmit_gain_milli":12000}'
    Assert-UiControl ($supervisor.SendControlCommand($invalidGainId,'audio.gains.set',$secondGainParameters)) '失败 revision 不前进，修正后的同 revision 应可重试。'
    $secondGainLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'audio.gains.set' -RequestId $invalidGainId
    $secondGain = ConvertFrom-UiControlFrame -Json $secondGainLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($secondGain.result -ceq 'ok' -and $secondGain.audio_gains.revision -eq 2 -and
        $secondGain.audio_gains.radio_playback_gain_milli -eq 750 -and
        $secondGain.audio_gains.mic_transmit_gain_milli -eq 12000) '校正请求必须确认最新两个实际音量。'
    $lastControlSequence = [uint64]$secondGain.control_seq

    $gainStatusId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($gainStatusId,'status')) '音量更新后 Native 状态查询应可用。'
    $gainStatusLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'status' -RequestId $gainStatusId
    $gainStatus = ConvertFrom-UiControlFrame -Json $gainStatusLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($gainStatus.snapshot.audio_gains.revision -eq 2 -and
        $gainStatus.snapshot.audio_gains.radio_playback_gain_milli -eq 750 -and
        $gainStatus.snapshot.audio_gains.mic_transmit_gain_milli -eq 12000) 'status readback 必须与已应用 ACK 一致。'
    $lastControlSequence = [uint64]$gainStatus.control_seq

    $gainRouteStatusId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($gainRouteStatusId,'routing.status')) '增益更新不应关闭或改写路由状态。'
    $gainRouteStatusLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'routing.status' -RequestId $gainRouteStatusId
    $gainRouteStatus = ConvertFrom-UiControlFrame -Json $gainRouteStatusLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ((ConvertTo-Json -InputObject $gainRouteStatus.routing -Depth 12 -Compress) -ceq $gainRouteBefore) `
        '音量更新前后真实 Native 路由 JSON 必须逐字段一致。'
    $lastControlSequence = [uint64]$gainRouteStatus.control_seq

    Assert-UiControl (-not $supervisor.SendControlCommand('unsupported-audio-command','audio.gains.set',
        ('{"revision":3,"radio_playback_gain_milli":1000,"mic_transmit_gain_milli":1000,"padding":"' + ('x' * 4096) + '"}'))) `
        'audio.gains.set 仍必须遵守完整 4KiB 请求体限制。'
    Assert-UiControl (-not $supervisor.SendControlCommand('unsupported-native-command','audio.gains.clear')) `
        'BridgeSupervisor 仍必须拒绝不在固定白名单中的命令。'

    $identityParameters = '{"source_id":7654321,"revision":1,"callsign":"N0TEST"}'
    Assert-UiControl ($supervisor.SendControlCommand('radioid-1','radio_identity.cache_upsert',$identityParameters)) `
        'Native identity 映射必须通过WPF匿名管道进入本run'
    $identityLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' `
        -Command 'radio_identity.cache_upsert' -RequestId 'radioid-1'
    $identityResult = ConvertFrom-UiControlFrame -Json $identityLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($identityResult.result -ceq 'ok' -and -not $identityResult.replayed) `
        '首个 Native identity cache upsert 必须确认已应用'
    $lastControlSequence = [uint64]$identityResult.control_seq
    Assert-UiControl ($supervisor.SendControlCommand('radioid-1','radio_identity.cache_upsert',$identityParameters)) `
        '重复的最新 identity revision 可安全重放'
    $identityReplayLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' `
        -Command 'radio_identity.cache_upsert' -RequestId 'radioid-1'
    $identityReplay = ConvertFrom-UiControlFrame -Json $identityReplayLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($identityReplay.result -ceq 'ok' -and $identityReplay.replayed) `
        '相同最新 revision 与 payload 必须得到幂等ACK'
    $lastControlSequence = [uint64]$identityReplay.control_seq
    $updatedIdentityParameters = '{"source_id":7654321,"revision":2,"callsign":"N1TEST"}'
    Assert-UiControl ($supervisor.SendControlCommand('radioid-2','radio_identity.cache_upsert',$updatedIdentityParameters)) `
        '后续 Native identity revision 可更新同一来源ID'
    $updatedIdentityLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' `
        -Command 'radio_identity.cache_upsert' -RequestId 'radioid-2'
    $updatedIdentity = ConvertFrom-UiControlFrame -Json $updatedIdentityLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($updatedIdentity.result -ceq 'ok' -and -not $updatedIdentity.replayed) `
        '更高 revision 必须接受更新后的合法呼号'
    $lastControlSequence = [uint64]$updatedIdentity.control_seq
    $removeIdentityParameters = '{"source_id":7654321,"revision":3,"callsign":null}'
    Assert-UiControl ($supervisor.SendControlCommand('radioid-3','radio_identity.cache_upsert',$removeIdentityParameters)) `
        '权威 not_found 或非法呼号结果必须可通过同一 Native 命令删除缓存映射'
    $removeIdentityLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' `
        -Command 'radio_identity.cache_upsert' -RequestId 'radioid-3'
    $removeIdentity = ConvertFrom-UiControlFrame -Json $removeIdentityLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($removeIdentity.result -ceq 'ok' -and -not $removeIdentity.replayed) `
        'callsign:null tombstone 必须得到首次成功 ACK'
    $lastControlSequence = [uint64]$removeIdentity.control_seq
    Assert-UiControl ($supervisor.SendControlCommand('radioid-3','radio_identity.cache_upsert',$removeIdentityParameters)) `
        'callsign:null tombstone 可用相同 request_id 和 payload 重放'
    $removeIdentityReplayLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' `
        -Command 'radio_identity.cache_upsert' -RequestId 'radioid-3'
    $removeIdentityReplay = ConvertFrom-UiControlFrame -Json $removeIdentityReplayLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($removeIdentityReplay.result -ceq 'ok' -and $removeIdentityReplay.replayed) `
        '相同 revision 的删除重放必须幂等 ACK'
    $lastControlSequence = [uint64]$removeIdentityReplay.control_seq
    Assert-UiControl ($supervisor.SendControlCommand('radioid-1','radio_identity.cache_upsert',$identityParameters)) `
        '可再次验证过期 identity revision 的拒绝路径'
    $staleIdentityLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' `
        -Command 'radio_identity.cache_upsert' -RequestId 'radioid-1'
    $staleIdentity = ConvertFrom-UiControlFrame -Json $staleIdentityLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($staleIdentity.result -ceq 'rejected' -and $staleIdentity.error -ceq 'stale_identity_revision') `
        '旧 revision 重放必须被 Native 拒绝而不回滚新呼号'
    $lastControlSequence = [uint64]$staleIdentity.control_seq

    $groups = New-Object 'System.Collections.Generic.List[object]'
    $bestPolicy = $null; $bestParameters = ''; $bestCount = 0; $bestBytes = 0
    $largeRequestId = [guid]::NewGuid().ToString('D')
    for ($index = 1; $index -le 300; $index++) {
        $groups.Add([pscustomobject][ordered]@{ destination_id=[uint64](10000 + $index); slot=[uint64]1 })
        $candidatePolicy = [pscustomobject][ordered]@{
            group_mode='selected'; private_mode='disabled'; allow_groups=@($groups.ToArray())
            allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
        }
        $candidatePayload = [ordered]@{ expected_revision=[uint64]$status.routing.rx_policy_revision; rx_policy=$candidatePolicy }
        $candidateParameters = ConvertTo-Json -InputObject $candidatePayload -Depth 12 -Compress
        $candidateBytes = [WirexBridge.Ui.BridgeSupervisor]::GetControlRequestBodyByteCount($ready.run_id,$largeRequestId,'rx_policy.replace',$candidateParameters)
        if ($candidateBytes -gt 4096) { break }
        $bestPolicy = $candidatePolicy; $bestParameters = $candidateParameters; $bestCount = $index; $bestBytes = $candidateBytes
    }
    Assert-UiControl ($bestCount -gt 1 -and $bestBytes -le 4096) '必须构造多路由、完整请求不超过4096字节的策略。'
    Assert-UiControl ($supervisor.SendControlCommand($largeRequestId,'rx_policy.replace',$bestParameters)) '合法路由更新必须通过完整4096字节计量后发送。'
    $largeAckLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'rx_policy.replace' -RequestId $largeRequestId
    $largeAck = ConvertFrom-UiControlFrame -Json $largeAckLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($largeAck.result -ceq 'ok' -and $largeAck.routing.rx_policy.allow_groups.Count -eq $bestCount) '核心必须应用完整的Selected路由列表。'
    $lastControlSequence = [uint64]$largeAck.control_seq
    $largeAckBytes = [System.Text.Encoding]::UTF8.GetByteCount($largeAckLine)
    $largePushLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'routing_state' -Command '' -RequestId ''
    $largePush = ConvertFrom-UiControlFrame -Json $largePushLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($largePush.routing.rx_policy.allow_groups.Count -eq $bestCount) '策略变更必须推送真实 routing_state。'
    $lastControlSequence = [uint64]$largePush.control_seq
    $largePushBytes = [System.Text.Encoding]::UTF8.GetByteCount($largePushLine)
    Assert-UiControl (($largeAckBytes -gt 4096) -or ($largePushBytes -gt 4096)) '合法routing结果或push必须能完整通过4KiB以上输出行。'

    $txRequestId = [guid]::NewGuid().ToString('D')
    $txPayload = [ordered]@{ expected_revision=[uint64]$largeAck.routing.tx_policy_revision
        tx_target=[pscustomobject][ordered]@{ destination_id=[uint64]53000; kind='group'; slot=[uint64]2 }; transmit_enabled=$true }
    $txParameters = ConvertTo-Json -InputObject $txPayload -Depth 8 -Compress
    Assert-UiControl ($supervisor.SendControlCommand($txRequestId,'tx_policy.replace',$txParameters)) 'tx_policy.replace 必须通过结构化参数发送。'
    $txLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'tx_policy.replace' -RequestId $txRequestId
    $txResult = ConvertFrom-UiControlFrame -Json $txLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($txResult.result -ceq 'ok' -and $txResult.routing.tx_target.destination_id -eq 53000 -and $txResult.routing.transmit_enabled) '核心必须分别更新下一发射目标和许可。'
    $lastControlSequence = [uint64]$txResult.control_seq

    $exactRequestId = [guid]::NewGuid().ToString('D')
    $exactParameters = ''
    for ($length = 0; $length -lt 4096; $length++) {
        $candidateParameters = '{"x":"' + ('x' * $length) + '"}'
        if ([WirexBridge.Ui.BridgeSupervisor]::GetControlRequestBodyByteCount($ready.run_id,$exactRequestId,'rx_policy.replace',$candidateParameters) -eq 4096) {
            $exactParameters = $candidateParameters; break
        }
    }
    Assert-UiControl ($exactParameters.Length -gt 0 -and [WirexBridge.Ui.BridgeSupervisor]::GetControlRequestBodyByteCount($ready.run_id,$exactRequestId,'rx_policy.replace',$exactParameters) -eq 4096) '必须精确构造4096字节请求体。'
    Assert-UiControl ($supervisor.SendControlCommand($exactRequestId,'rx_policy.replace',$exactParameters)) '4096字节完整JSON请求体必须可以发送。'
    $exactLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'rx_policy.replace' -RequestId $exactRequestId
    $exactResult = ConvertFrom-UiControlFrame -Json $exactLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($exactResult.result -ceq 'rejected') '4096字节的语法有效请求必须抵达核心并得到明确拒绝，而非被本地截断。'
    $lastControlSequence = [uint64]$exactResult.control_seq

    $overRequestId = [guid]::NewGuid().ToString('D')
    $overParameters = ''
    for ($length = 0; $length -lt 4096; $length++) {
        $candidateParameters = '{"x":"' + ('x' * $length) + '"}'
        if ([WirexBridge.Ui.BridgeSupervisor]::GetControlRequestBodyByteCount($ready.run_id,$overRequestId,'rx_policy.replace',$candidateParameters) -eq 4097) {
            $overParameters = $candidateParameters; break
        }
    }
    Assert-UiControl ($overParameters.Length -gt 0) '必须精确构造4097字节请求体。'
    Assert-UiControl (-not $supervisor.SendControlCommand($overRequestId,'rx_policy.replace',$overParameters)) '4097字节请求体必须在发送前被拒绝。'
    $afterOversizeId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($afterOversizeId,'routing.status')) '超长请求被拒绝后匿名管道仍应可用。'
    $afterOversizeLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'routing.status' -RequestId $afterOversizeId
    $afterOversize = ConvertFrom-UiControlFrame -Json $afterOversizeLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($afterOversize.result -ceq 'ok' -and -not $supervisor.HasControlEventOverflow) '超长请求不得关闭管道或导致控制队列溢出。'
    $lastControlSequence = [uint64]$afterOversize.control_seq

    $badPush = [pscustomobject][ordered]@{ schema_version=2; type='routing_state'; run_id=$ready.run_id
        control_seq=($lastControlSequence + 1); routing=$push.routing; extra='forbidden' }
    Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $badPush -Compress -Depth 8) `
        -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence } '严格解析器必须拒绝routing_state额外字段。'
    $stalePush = [pscustomobject][ordered]@{ schema_version=2; type='routing_state'; run_id=$ready.run_id
        control_seq=$lastControlSequence; routing=$push.routing }
    Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $stalePush -Compress -Depth 8) `
        -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence } 'routing_state必须使用独立递增的control_seq。'

    $shutdownRequestId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($shutdownRequestId,'shutdown')) 'shutdown 必须经 v2 JSON 命令发送。'
    $shutdownLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'shutdown' -RequestId $shutdownRequestId
    $shutdown = ConvertFrom-UiControlFrame -Json $shutdownLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($shutdown.result -ceq 'ok' -and $shutdown.shutdown_requested) 'shutdown 只确认收到请求。'
    $supervisor.CloseControlInput()
    $exitWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $supervisor.HasExited -and $exitWatch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
    Assert-UiControl $supervisor.HasExited '本地诊断进程必须在 shutdown 和 EOF 后退出。'
    $exitCode = -1
    Assert-UiControl ($supervisor.TryGetExitCode([ref]$exitCode) -and $exitCode -eq 0) '本地协议诊断进程应以0退出。'
    Assert-UiControl ($initialPushBytes -gt 0) 'hello后必须收到初始routing_state push。'
    $script:uiControlBacklog = New-Object 'System.Collections.Generic.Queue[string]'
    $noGainSupervisor.Start($NativeExecutable, [string[]]@('--control-diagnostic','--ui-pipe','--ui-control-version','2'), $tempRoot, 2)
    $noGainReadyLine = Wait-UiControlEvent -Supervisor $noGainSupervisor -Type 'control_ready' -Command '' -RequestId '' -TimeoutMilliseconds 10000
    $noGainReady = ConvertFrom-UiControlFrame -Json $noGainReadyLine -ExpectedProcessId $noGainSupervisor.ProcessId
    Assert-UiControl (-not ($noGainReady.supported_commands -contains 'audio.gains.set')) '没有 gain handler 的 Native control diagnostic 不得广告音量命令。'
    $script:controlCapabilities = @($noGainReady.supported_commands) -join ','
    Assert-UiControl $noGainSupervisor.SetControlRunId([string]$noGainReady.run_id) '基础诊断 Supervisor 必须锁定本次进程的 run_id。'
    $noGainHelloId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($noGainSupervisor.SendControlCommand($noGainHelloId,'hello')) '基础诊断 hello 必须可发送。'
    $noGainHelloLine = Wait-UiControlEvent -Supervisor $noGainSupervisor -Type 'control_result' -Command 'hello' -RequestId $noGainHelloId
    $noGainHello = ConvertFrom-UiControlFrame -Json $noGainHelloLine -LockedRunId $noGainReady.run_id -LastControlSequence ([uint64]$noGainReady.control_seq)
    Assert-UiControl ($noGainHello.result -ceq 'ok' -and -not ($noGainHello.supported_commands -contains 'audio.gains.set')) 'hello 必须保持旧版无音量能力命令集。'
    Assert-UiControl ($noGainSupervisor.SendControlCommand('audio-gains-1','audio.gains.set',
        '{"revision":1,"radio_playback_gain_milli":1000,"mic_transmit_gain_milli":1000}')) '白名单允许的音量命令应送达无handler Native，由其回报 unsupported。'
    $noGainLine = Wait-UiControlEvent -Supervisor $noGainSupervisor -Type 'control_result' -Command 'audio.gains.set' -RequestId 'audio-gains-1'
    $noGain = ConvertFrom-UiControlFrame -Json $noGainLine -LockedRunId $noGainReady.run_id -LastControlSequence ([uint64]$noGainHello.control_seq)
    Assert-UiControl ($noGain.result -ceq 'unsupported' -and $noGain.error -ceq 'command_not_supported') '无 handler 的 Native 必须返回明确 unsupported。'
    $noGainShutdownId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($noGainSupervisor.SendControlCommand($noGainShutdownId,'shutdown')) '基础诊断 shutdown 必须可发送。'
    $noGainShutdownLine = Wait-UiControlEvent -Supervisor $noGainSupervisor -Type 'control_result' -Command 'shutdown' -RequestId $noGainShutdownId
    $noGainShutdown = ConvertFrom-UiControlFrame -Json $noGainShutdownLine -LockedRunId $noGainReady.run_id -LastControlSequence ([uint64]$noGain.control_seq)
    Assert-UiControl ($noGainShutdown.result -ceq 'ok' -and $noGainShutdown.shutdown_requested) '基础诊断 shutdown 应得到 ACK。'
    $noGainSupervisor.CloseControlInput()
    $noGainExitWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $noGainSupervisor.HasExited -and $noGainExitWatch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
    Assert-UiControl $noGainSupervisor.HasExited '基础控制诊断必须在 shutdown 与 EOF 后退出。'
    $noGainExitCode = -1
    Assert-UiControl ($noGainSupervisor.TryGetExitCode([ref]$noGainExitCode) -and $noGainExitCode -eq 0) '基础控制诊断必须以0退出。'
    $passed = $true
    Write-Output ('通过：真实 WPF BridgeSupervisor→Native 诊断覆盖 audio.gains.set capability/ACK/status/revision、重放/冲突/范围拒绝、route 不变、无 handler 的旧能力集与 unsupported、{0}条组呼路由、{1}字节回执、4096/4097边界和正常退出；未连接电台、BM、音频或RF。' -f $bestCount,[Math]::Max($largeAckBytes,$largePushBytes))
} finally {
    foreach ($ownedSupervisor in @($supervisor,$noGainSupervisor)) {
        if (-not $passed -and $ownedSupervisor.IsStarted -and -not $ownedSupervisor.HasExited) {
            try { $stopTask = $ownedSupervisor.StopAsync(100); [void]$stopTask.Wait(5000) } catch { }
        }
        $ownedSupervisor.Dispose()
    }
    if ([System.IO.Directory]::Exists($tempRoot)) { [System.IO.Directory]::Delete($tempRoot, $true) }
}
