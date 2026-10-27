[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$NativeExecutable)

$ErrorActionPreference = 'Stop'
function Assert-UiControl {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}
function Wait-UiControlEvent {
    param($Supervisor, [string]$Type, [string]$Command, [string]$RequestId, [int]$TimeoutMilliseconds = 5000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        foreach ($line in @($Supervisor.DrainControlEvents(32))) {
            try { $candidate = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
            if ([string]$candidate.type -cne $Type) { continue }
            if ($Command -and [string]$candidate.command -cne $Command) { continue }
            if ($RequestId -and [string]$candidate.request_id -cne $RequestId) { continue }
            return [string]$line
        }
        if ($Supervisor.HasExited) { break }
        Start-Sleep -Milliseconds 20
    }
    throw "等待控制帧超时：$Type $Command"
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
foreach ($functionName in @('Test-UiExactControlFields','Test-UiControlUnsigned','Test-UiControlSnapshot','ConvertFrom-UiControlFrame')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
    Assert-UiControl ($null -ne $functionAst) "缺少控制帧验证函数：$functionName"
    Invoke-Expression $functionAst.Extent.Text
}
$supervisorSource = Join-Path $repoRoot 'ui\windows\BridgeSupervisor.cs'
Add-Type -Path $supervisorSource
$supervisor = New-Object WirexBridge.Ui.BridgeSupervisor
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-ui-control-v2-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$passed = $false
try {
    $arguments = [string[]]@('--control-diagnostic','--ui-pipe','--ui-control-version','2')
    $supervisor.Start($NativeExecutable, $arguments, $tempRoot, 2)
    $readyLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_ready' -Command '' -RequestId '' -TimeoutMilliseconds 10000
    $ready = ConvertFrom-UiControlFrame -Json $readyLine -ExpectedProcessId $supervisor.ProcessId
    Assert-UiControl ([bool]$ready.diagnostic -and $ready.control_version -eq 2 -and
        @($ready.supported_commands) -join ',' -ceq 'hello,status,shutdown') 'ready 必须报告 v2 无设备诊断和冻结命令列表。'
    Assert-UiControl $supervisor.SetControlRunId([string]$ready.run_id) 'Supervisor 必须锁定 Native ready 的 run_id。'
    $lastControlSequence = [uint64]$ready.control_seq

    $helloRequestId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($helloRequestId,'hello')) 'hello 必须经 WPF anonymous pipe 写入子进程。'
    $helloLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'hello' -RequestId $helloRequestId
    $hello = ConvertFrom-UiControlFrame -Json $helloLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($hello.result -ceq 'ok' -and -not $hello.replayed) 'hello ACK 必须返回 ok 且不是重放。'
    $lastControlSequence = [uint64]$hello.control_seq

    $statusRequestId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($statusRequestId,'status')) 'status 查询必须经同一管道发送。'
    $statusLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'status' -RequestId $statusRequestId
    $status = ConvertFrom-UiControlFrame -Json $statusLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($status.result -ceq 'ok' -and $status.snapshot.diagnostic -and
        $status.snapshot.bm_state -ceq 'not_started' -and $status.snapshot.hri_ready -eq $false -and
        $status.snapshot.radio_state -ceq 'unknown' -and $status.snapshot.media_seq -eq 0) `
        '诊断 status 必须如实显示未启动 BM/HRI、RF 未知以及独立 media_seq。'
    $lastControlSequence = [uint64]$status.control_seq

    # A repeated request returns a cached snapshot with a new control sequence.
    Assert-UiControl ($supervisor.SendControlCommand($statusRequestId,'status')) '同 request_id 重试必须能发送。'
    $replayLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'status' -RequestId $statusRequestId
    $replay = ConvertFrom-UiControlFrame -Json $replayLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($replay.replayed -and $replay.control_seq -gt $lastControlSequence -and
        $replay.snapshot.media_seq -eq $status.snapshot.media_seq) '重放必须有新 control_seq，但保留原媒体摘要序号。'
    $lastControlSequence = [uint64]$replay.control_seq

    $unknownResponse = [pscustomobject][ordered]@{
        schema_version=2; type='control_result'; run_id=[string]$ready.run_id; control_seq=($lastControlSequence + 1)
        request_id=[guid]::NewGuid().ToString('D'); command='status'; result='unsupported'; replayed=$false; error='unsupported'
    }
    $validRejected = ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $unknownResponse -Compress -Depth 6) `
        -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($validRejected.result -ceq 'unsupported') 'unsupported/rejected ACK 可显示为明确失败，且不需要伪造 snapshot。'
    $badRejected = $unknownResponse.PSObject.Copy()
    Add-Member -InputObject $badRejected -NotePropertyName snapshot -NotePropertyValue $status.snapshot -Force
    Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $badRejected -Compress -Depth 6) `
        -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence } '拒绝响应不得附带成功 snapshot。'
    $badStale = [pscustomobject]@{schema_version=2;type='control_result';run_id=$ready.run_id;control_seq=$lastControlSequence;
        request_id=[guid]::NewGuid().ToString('D');command='status';result='ok';replayed=$false;snapshot=$status.snapshot}
    Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $badStale -Compress -Depth 6) `
        -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence } 'control_seq 必须与媒体 media_seq 分开严格递增。'

    $shutdownRequestId = [guid]::NewGuid().ToString('D')
    Assert-UiControl ($supervisor.SendControlCommand($shutdownRequestId,'shutdown')) 'shutdown 必须经 JSON v2 命令写入。'
    $shutdownLine = Wait-UiControlEvent -Supervisor $supervisor -Type 'control_result' -Command 'shutdown' -RequestId $shutdownRequestId
    $shutdown = ConvertFrom-UiControlFrame -Json $shutdownLine -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence
    Assert-UiControl ($shutdown.result -ceq 'ok' -and $shutdown.shutdown_requested) 'shutdown ACK 只确认收到请求。'
    $supervisor.CloseControlInput()
    $exitWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $supervisor.HasExited -and $exitWatch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
    Assert-UiControl $supervisor.HasExited 'Native 诊断进程必须在 shutdown+EOF 后退出。'
    $exitCode = -1
    Assert-UiControl ($supervisor.TryGetExitCode([ref]$exitCode) -and $exitCode -eq 0) '无设备控制诊断进程必须以 0 退出。'

    $unexpected = [pscustomobject]@{schema_version=2;type='control_result';run_id=$ready.run_id;control_seq=($lastControlSequence + 1);
        request_id=[guid]::NewGuid().ToString('D');command='status';result='ok';replayed=$false;snapshot=$status.snapshot;extra='forbidden'}
    Assert-UiControlFrameRejected { ConvertFrom-UiControlFrame -Json (ConvertTo-Json -InputObject $unexpected -Compress -Depth 6) `
        -LockedRunId $ready.run_id -LastControlSequence $lastControlSequence } 'strict UI parser 必须拒绝未知 control_result 字段。'
    $passed = $true
    Write-Output '通过：WPF BridgeSupervisor 真实匿名管道 ready/hello/status/replay/shutdown/exit0 与 strict ACK 校验；未启动 BM、HRI、音频或 RF。'
} finally {
    if (-not $passed -and $supervisor.IsStarted -and -not $supervisor.HasExited) {
        try { $stopTask = $supervisor.StopAsync(100); [void]$stopTask.Wait(5000) } catch { }
    }
    $supervisor.Dispose()
    if ([System.IO.Directory]::Exists($tempRoot)) { [System.IO.Directory]::Delete($tempRoot, $true) }
}
