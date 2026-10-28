[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$NativeExecutable)

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
$NativeExecutable = [System.IO.Path]::GetFullPath($NativeExecutable)
if (-not [System.IO.File]::Exists($NativeExecutable)) { throw "缺少 Native 控制诊断核心：$NativeExecutable" }
$uiScript = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiScript, [ref]$tokens, [ref]$parseErrors)
Assert-UiControl ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
foreach ($functionName in @('Test-UiExactControlFields','Test-UiControlUnsigned','Test-UiControlSnapshot',
        'Test-UiRxPolicy','Test-UiRoutingCapabilityList','Test-UiRoutingSnapshot','ConvertFrom-UiControlFrame')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
    Assert-UiControl ($null -ne $functionAst) "缺少控制消息验证函数：$functionName"
    Invoke-Expression $functionAst.Extent.Text
}
$legacyRoutingCommands = [string[]]@('hello','status','shutdown','routing.status','rx_policy.replace','tx_policy.replace')
$quickCallRoutingCommands = $legacyRoutingCommands + 'network_subscription.quick_call_join'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $legacyRoutingCommands) '界面必须继续接受旧版六命令路由核心。'
Assert-UiControl (Test-UiRoutingCapabilityList -Commands $quickCallRoutingCommands) '界面必须识别新增Quick Call命令能力。'
Add-Type -Path (Join-Path $repoRoot 'ui\windows\BridgeSupervisor.cs')
$supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-ui-routing-control-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$passed = $false
try {
    $supervisor.Start($NativeExecutable, [string[]]@('--routing-diagnostic','--ui-pipe','--ui-control-version','2'), $tempRoot, 2)
    $readyLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_ready' -Command '' -RequestId '' -TimeoutMilliseconds 10000
    $ready = ConvertFrom-UiControlFrame -Json $readyLine -ExpectedProcessId $supervisor.ProcessId
    $expectedCommands = 'hello,status,shutdown,routing.status,rx_policy.replace,tx_policy.replace,network_subscription.quick_call_join'
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
    $passed = $true
    Write-Output ('通过：真实 WPF BridgeSupervisor→Native 路由诊断覆盖 ready/hello/status、{0}条组呼路由、{1}字节回执、4096/4097边界、下一发射目标和正常退出；未连接电台、BM、音频或RF。' -f $bestCount,[Math]::Max($largeAckBytes,$largePushBytes))
} finally {
    if (-not $passed -and $supervisor.IsStarted -and -not $supervisor.HasExited) {
        try { $stopTask = $supervisor.StopAsync(100); [void]$stopTask.Wait(5000) } catch { }
    }
    $supervisor.Dispose()
    if ([System.IO.Directory]::Exists($tempRoot)) { [System.IO.Directory]::Delete($tempRoot, $true) }
}
