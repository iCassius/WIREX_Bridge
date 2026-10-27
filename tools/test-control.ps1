[CmdletBinding()]
param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $PSScriptRoot 'wirex_bridge.exe'
}
$exePath = [System.IO.Path]::GetFullPath($ExecutablePath)
$process = $null
$stderrTask = $null
$script:lastControlSequence = 0L

function Assert-ProtocolValue {
    param(
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Read-ControlRecord {
    param([Parameter(Mandatory=$true)][int]$TimeoutSeconds)
    $lineTask = $process.StandardOutput.ReadLineAsync()
    if (-not $lineTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        throw '等待协议响应超时。'
    }
    $line = $lineTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) { throw '协议输出在预期记录前结束。' }
    try { $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop }
    catch { throw '协议输出不是有效 JSON。' }
    if ($null -eq $record -or $record -is [string] -or $record -is [array]) {
        throw '协议记录必须是 JSON 对象。'
    }
    Assert-ProtocolValue -Condition ($record.schema_version -eq 2) -Message '协议版本不是 2。'
    Assert-ProtocolValue -Condition ([string]$record.run_id -ceq $script:runId) -Message '协议响应 run_id 不匹配。'
    $sequence = 0L
    if (-not [long]::TryParse([string]$record.control_seq, [ref]$sequence) -or
        $sequence -le $script:lastControlSequence) {
        throw '协议响应序号缺失、倒退或重复。'
    }
    $script:lastControlSequence = $sequence
    return $record
}

function Send-ControlCommand {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('hello','status','shutdown')][string]$Command,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds
    )
    $requestId = [guid]::NewGuid().ToString('N')
    $message = [ordered]@{
        schema_version = 2
        run_id = $script:runId
        request_id = $requestId
        command = $Command
    }
    $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $message -Compress -Depth 4))
    $process.StandardInput.Flush()
    $response = Read-ControlRecord -TimeoutSeconds $TimeoutSeconds
    Assert-ProtocolValue -Condition ($response.type -ceq 'control_result') -Message '协议响应类型不是 control_result。'
    Assert-ProtocolValue -Condition ([string]$response.request_id -ceq $requestId) -Message '协议响应 request_id 不匹配。'
    Assert-ProtocolValue -Condition ([string]$response.command -ceq $Command) -Message '协议响应命令名不匹配。'
    Assert-ProtocolValue -Condition ([string]$response.result -ceq 'ok') -Message ('协议命令失败：' + $Command)
    Assert-ProtocolValue -Condition ($response.replayed -eq $false) -Message ('协议命令被错误标记为重放：' + $Command)
    return $response
}

try {
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw '找不到本目录中的 wirex_bridge.exe。'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $exePath
    $startInfo.Arguments = '--control-diagnostic --ui-pipe --ui-control-version 2'
    $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($exePath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw '无法启动协议诊断子进程。' }
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $readyTask = $process.StandardOutput.ReadLineAsync()
    if (-not $readyTask.Wait([TimeSpan]::FromSeconds(10))) { throw '等待 control_ready 超时。' }
    $readyLine = $readyTask.Result
    if ([string]::IsNullOrWhiteSpace($readyLine)) { throw '诊断进程没有发送 control_ready。' }
    try { $ready = ConvertFrom-Json -InputObject $readyLine -ErrorAction Stop }
    catch { throw 'control_ready 不是有效 JSON。' }
    Assert-ProtocolValue -Condition ($ready.schema_version -eq 2) -Message 'control_ready schema_version 不是 2。'
    Assert-ProtocolValue -Condition ($ready.type -ceq 'control_ready') -Message '首条协议记录不是 control_ready。'
    Assert-ProtocolValue -Condition (-not [string]::IsNullOrWhiteSpace([string]$ready.run_id)) -Message 'control_ready 缺少 run_id。'
    Assert-ProtocolValue -Condition ($ready.control_seq -eq 1) -Message 'control_ready control_seq 不是 1。'
    Assert-ProtocolValue -Condition ($ready.control_version -eq 2) -Message '诊断进程报告的 control_version 不是 2。'
    Assert-ProtocolValue -Condition ($ready.diagnostic -eq $true) -Message '诊断进程没有声明 diagnostic=true。'
    $readyCommands = @($ready.supported_commands | ForEach-Object { [string]$_ })
    Assert-ProtocolValue -Condition ($readyCommands.Count -eq 3 -and
        @($readyCommands | Where-Object { $_ -ceq 'hello' }).Count -eq 1 -and
        @($readyCommands | Where-Object { $_ -ceq 'status' }).Count -eq 1 -and
        @($readyCommands | Where-Object { $_ -ceq 'shutdown' }).Count -eq 1) `
        -Message 'control_ready 支持命令列表与本步范围不一致。'
    $script:runId = [string]$ready.run_id
    $script:lastControlSequence = [long]$ready.control_seq
    Write-Host '收到 schema 2 control_ready。'

    $hello = Send-ControlCommand -Command 'hello' -TimeoutSeconds 5
    $helloCommands = @($hello.supported_commands | ForEach-Object { [string]$_ })
    Assert-ProtocolValue -Condition ($helloCommands.Count -eq 3 -and
        @($helloCommands | Where-Object { $_ -ceq 'hello' }).Count -eq 1 -and
        @($helloCommands | Where-Object { $_ -ceq 'status' }).Count -eq 1 -and
        @($helloCommands | Where-Object { $_ -ceq 'shutdown' }).Count -eq 1) `
        -Message 'hello 响应支持命令列表与 control_ready 不一致。'
    Write-Host 'hello 往返通过。'

    $statusResponse = Send-ControlCommand -Command 'status' -TimeoutSeconds 5
    $snapshot = $statusResponse.snapshot
    Assert-ProtocolValue -Condition ($snapshot.mode -ceq 'diagnostic' -and $snapshot.status -ceq 'running' -and
        $snapshot.phase -ceq 'protocol_diagnostic' -and $snapshot.media_seq -eq 0 -and $snapshot.diagnostic -eq $true) `
        -Message 'status 快照没有报告预期的纯协议诊断状态。'
    Assert-ProtocolValue -Condition ($snapshot.bm_state -ceq 'not_started' -and $snapshot.hri_phase -ceq 'not_started' -and
        $snapshot.hri_ready -eq $false -and $snapshot.serial_open -eq $false -and
        $snapshot.wavein_open -eq $false -and $snapshot.waveout_open -eq $false -and $snapshot.radio_state -ceq 'unknown') `
        -Message 'status 快照错误地报告了设备或网络已启动。'
    Write-Host 'status 明确报告未启动 BM、HRI、串口和音频。'

    $shutdown = Send-ControlCommand -Command 'shutdown' -TimeoutSeconds 5
    Assert-ProtocolValue -Condition ($shutdown.shutdown_requested -eq $true) -Message 'shutdown 响应没有确认关闭请求。'
    if (-not $process.WaitForExit(5000)) { throw '收到 shutdown 确认后，诊断子进程未在时限内退出。' }
    Assert-ProtocolValue -Condition ($process.ExitCode -eq 0) -Message ('诊断子进程退出码不是 0：' + $process.ExitCode)
    Assert-ProtocolValue -Condition ($stderrTask.Wait([TimeSpan]::FromSeconds(2))) -Message '诊断子进程 stderr 收尾超时。'
    Assert-ProtocolValue -Condition ([string]::IsNullOrWhiteSpace($stderrTask.Result)) -Message '成功诊断进程向 stderr 写入了内容。'
    Assert-ProtocolValue -Condition ([string]::IsNullOrWhiteSpace($process.StandardOutput.ReadToEnd())) `
        -Message 'shutdown ACK 后诊断进程又输出了额外内容。'
    Write-Host 'shutdown 往返通过，诊断子进程以 0 退出。'
    Write-Host '协议诊断通过；本次检查没有连接设备或网络。'
    exit 0
}
catch {
    [Console]::Error.WriteLine(('协议诊断失败：' + $_.Exception.Message))
    exit 1
}
finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(2000)
            }
        } catch { }
        try { $process.Dispose() } catch { }
    }
}
