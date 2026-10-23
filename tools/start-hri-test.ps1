[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$TestProbePath,
    [string]$TestFixturePath
)

$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$probePath = Join-Path $packageRoot 'wirex_probe.exe'
$fixturePath = Join-Path $packageRoot 'private\device-y.bin'
$logPath = Join-Path $packageRoot 'last-test.log'
$reportPath = Join-Path $packageRoot 'last-session-status.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:launcherReport = $null

function Write-AtomicReport {
    param([Parameter(Mandatory=$true)][object]$Report)
    $temporaryPath = $reportPath + '.tmp.' + [string]$Report.run_id
    $json = ConvertTo-Json -InputObject $Report -Depth 8 -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $json + "`n", $utf8NoBom)
    try {
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            $backupPath = $temporaryPath + '.bak'
            [System.IO.File]::Replace($temporaryPath, $reportPath, $backupPath)
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        } else {
            [System.IO.File]::Move($temporaryPath, $reportPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        $backupPath = $temporaryPath + '.bak'
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function New-LauncherReport {
    param([string]$Phase, [string]$Status, [bool]$Final, [string]$FailureReason)
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        $createdTicks = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
    } finally {
        $process.Dispose()
    }
    return [pscustomobject]@{
        schema_version = 1
        run_id = [guid]::NewGuid().ToString('N')
        pid = $PID
        process_created_filetime_utc = $createdTicks
        process_created_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        final = $Final
        status = $Status
        phase = $Phase
        elapsed_ms = 0
        stop_reason = 'none'
        failure_reason = $FailureReason
        version_query_write_requested = 0
        version_query_write_completed = 0
        version_response_validated = $false
        y_write_requested = 0
        y_write_completed = 0
        y_zero_ack_received = 0
        x100_received = 0
        unsupported_config_import_records = 0
        x_copy_branch_count = 0
        y_byte12_changed_count = 0
        x0_write_requested = 0
        x0_write_completed = 0
        other_valid_records = 0
        malformed_records = 0
        valid_records = 0
        receive_bytes = 0
        transmit_bytes_requested = 0
        write_calls_completed = 0
        audio_started = $false
        captured_bytes = 0
        submitted_bytes = 0
        dropped_blocks = 0
        clipped_samples = 0
        report_write_failed = $false
        pc_cleanup = [pscustomobject]@{
            audio_input = 'not_started'
            audio_output = 'not_started'
            serial_handle = 'not_opened'
        }
        radio_state = 'unknown'
        radio_state_unknown = $true
    }
}

function Get-ReportOwnerState {
    param([Parameter(Mandatory=$true)][object]$Report)
    if ($Report.schema_version -ne 1 -or $null -eq $Report.pid -or
        [string]::IsNullOrWhiteSpace([string]$Report.process_created_filetime_utc)) {
        return 'unknown'
    }
    $reportPid = 0
    $reportedTicks = [int64]0
    if (-not [int]::TryParse([string]$Report.pid, [ref]$reportPid) -or $reportPid -le 0 -or
        -not [int64]::TryParse([string]$Report.process_created_filetime_utc,
            [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$reportedTicks)) {
        return 'unknown'
    }
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($reportPid)
        try {
            $actualTicks = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
            if ($actualTicks -eq $reportedTicks) { return 'active' }
            return 'ended'
        } finally {
            $process.Dispose()
        }
    } catch [ArgumentException] {
        return 'ended'
    } catch {
        return 'unknown'
    }
}

function Write-ReportLogLine {
    param([string]$Line)
    [System.IO.File]::AppendAllText($logPath, $Line + [Environment]::NewLine, [System.Text.Encoding]::Unicode)
}

function Write-ReportSummary {
    param([Parameter(Mandatory=$true)][object]$Report, [string]$Prefix)
    $cleanup = $Report.pc_cleanup
    $fields = @(
        "${Prefix}run_id=$($Report.run_id)",
        "${Prefix}pid=$($Report.pid)",
        "${Prefix}stage=$($Report.phase)",
        "${Prefix}final=$($Report.final)",
        "${Prefix}status=$($Report.status)",
        "${Prefix}elapsed_ms=$($Report.elapsed_ms)",
        "${Prefix}stop_reason=$($Report.stop_reason)",
        "${Prefix}version_response_validated=$($Report.version_response_validated)",
        "${Prefix}y_write_completed=$($Report.y_write_completed)",
        "${Prefix}y_zero_ack_received=$($Report.y_zero_ack_received)",
        "${Prefix}x100_received=$($Report.x100_received)",
        "${Prefix}x0_write_completed=$($Report.x0_write_completed)",
        "${Prefix}receive_bytes=$($Report.receive_bytes)",
        "${Prefix}transmit_bytes_requested=$($Report.transmit_bytes_requested)",
        "${Prefix}audio_started=$($Report.audio_started)",
        "${Prefix}captured_bytes=$($Report.captured_bytes)",
        "${Prefix}submitted_bytes=$($Report.submitted_bytes)",
        "${Prefix}dropped_blocks=$($Report.dropped_blocks)",
        "${Prefix}audio_input_cleanup=$($cleanup.audio_input)",
        "${Prefix}audio_output_cleanup=$($cleanup.audio_output)",
        "${Prefix}serial_handle_cleanup=$($cleanup.serial_handle)",
        "${Prefix}radio_state=unknown"
    )
    foreach ($field in $fields) { Write-ReportLogLine $field }
}

$previousReport = $null
$previousReportState = 'none'
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    try {
        $previousReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host 'Existing session status report cannot be read; keeping the report and log unchanged.'
        exit 2
    }
    if ($previousReport.final -eq $false) {
        $previousReportState = Get-ReportOwnerState $previousReport
        if ($previousReportState -eq 'active') {
            Write-Host "A previous probe process (PID $($previousReport.pid)) is still running; no new probe was started and existing files were kept."
            exit 2
        }
        if ($previousReportState -eq 'unknown') {
            Write-Host 'The previous incomplete probe process cannot be checked safely; no new probe was started and existing files were kept.'
            exit 2
        }
    } elseif ($previousReport.final -ne $true) {
        Write-Host 'Existing session status report has no valid final marker; keeping the report and log unchanged.'
        exit 2
    }
}

[System.IO.File]::WriteAllText($logPath, '', [System.Text.Encoding]::Unicode)
if ($null -ne $previousReport -and $previousReport.final -eq $false -and $previousReportState -eq 'ended') {
    Write-ReportLogLine 'previous_probe_status=incomplete'
    Write-ReportLogLine 'previous_pc_cleanup=unknown'
    Write-ReportLogLine 'previous_cleanup_unknown=true'
    Write-ReportSummary $previousReport 'previous_'
}
$script:launcherReport = New-LauncherReport 'launcher_start' 'starting' $false ''
try {
    Write-AtomicReport $script:launcherReport
} catch {
    Write-Host ("Could not write the launcher session status report; no probe was started. " + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
    exit 2
}

function Write-LauncherError {
    param([string]$Category, [string]$VisibleMessage)
    Write-Host $VisibleMessage
    Write-ReportLogLine "launcher_error=$Category"
    if ($null -ne $script:launcherReport) {
        $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $script:launcherReport.final = $true
        $script:launcherReport.status = 'launcher_failed'
        $script:launcherReport.phase = 'preflight_failed'
        $script:launcherReport.failure_reason = $Category
        try { Write-AtomicReport $script:launcherReport } catch { }
    }
}

if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($TestProbePath) -or
        [string]::IsNullOrWhiteSpace($TestFixturePath)) {
        Write-LauncherError 'test_arguments_missing' 'Test mode requires a mock probe and a 100-byte mock fixture.'
        exit 2
    }
    $probePath = [System.IO.Path]::GetFullPath($TestProbePath)
    $fixturePath = [System.IO.Path]::GetFullPath($TestFixturePath)
    if ([System.IO.Path]::GetExtension($probePath) -ine '.ps1') {
        Write-LauncherError 'test_mode_requires_script' 'Test mode only accepts a PowerShell mock; it cannot launch the hardware probe.'
        exit 2
    }
} elseif ($PSBoundParameters.Count -ne 0) {
    Write-LauncherError 'unexpected_parameters' 'Test-only parameters cannot be used for a hardware run.'
    exit 2
}

if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    Write-LauncherError 'missing_probe' 'The probe executable is missing.'
    exit 2
}
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    Write-LauncherError 'missing_fixture' 'The private 100-byte Y template is missing.'
    exit 2
}
if ((Get-Item -LiteralPath $fixturePath).Length -ne 100) {
    Write-LauncherError 'fixture_size_invalid' 'The private Y template must be exactly 100 bytes.'
    exit 2
}

if (-not $TestMode) {
    $script:launcherReport.phase = 'awaiting_user_start'
    $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    try { Write-AtomicReport $script:launcherReport } catch {
        Write-LauncherError 'session_report_update_failed' ("Could not update the session status report; no probe was started. " + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
        exit 2
    }
    Write-Host ''
    Write-Host 'FTX-1 本机 DIRECT HRI 监听测试（最长 120 秒）'
    Write-Host '开始前确认：电台 USB 已连接；电台 HRI Mode 已启用且 Node Mode 为 DIRECT；官方 WIRES-X 程序已关闭。'
    Write-Host '本次固定打开 COM5、WaveIn 1 和 WaveOut 0。请先准备好耳机，并保持此可见控制台打开。'
    Write-Host '看到“音频路由已打开”后，可用手咪发言不超过 15 秒，然后松开 PTT；不要错过 120 秒截止。'
    Write-Host '日志只保留统计摘要，不保存录音或 HRI 正文。按任意键开始；运行结束后本窗口会直接退出。'
    try {
        [void][Console]::ReadKey($true)
    } catch {
        Write-LauncherError 'interactive_console_required' 'A visible interactive console is required. Open the CMD launcher directly.'
        exit 2
    }
}

$script:launcherReport.phase = 'probe_starting'
$script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
try { Write-AtomicReport $script:launcherReport } catch {
    Write-LauncherError 'session_report_update_failed' ("Could not update the session status report; no probe was started. " + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
    exit 2
}

$probeArguments = @(
    '--hri-listen', '--port', 'COM5', '--body-file', $fixturePath,
    '--input', '1', '--output', '0', '--seconds', '120', '--gain', '16',
    '--report-file', $reportPath
)
$summaryPattern = '^(HRI state stopped:|Audio route started after valid Y/0=|Captured input:|Submitted pre-gain:|Submitted post-gain:|serial_close_success=|Limited V/Y exchange observed;)'
$diagnosticPattern = '^(ERROR:|Cannot open COM[0-9]+:|Could not |Invalid port\.|Serial transport stopped:|CloseHandle failed|At least one WinMM|HRI status report update failed)'

$previousConsoleEncoding = [Console]::OutputEncoding
$previousPowerShellEncoding = $OutputEncoding
$previousErrorActionPreference = $ErrorActionPreference
try {
    # HRI CLI以UTF-8输出；同步PowerShell宿主的解码与控制台编码，ready中文和设备名才能正确显示。
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
    # 将原生stderr作为可筛选的记录处理，避免COM打开错误中断日志与退出码收尾。
    $ErrorActionPreference = 'Continue'
    if ($TestMode) {
        # 离线测试用PowerShell子进程模拟器；真实运行固定调用相邻的wirex_probe.exe。
        $probeExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source
        & $probeExecutable -NoLogo -NoProfile -File $probePath @probeArguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host $line
            if ($_ -is [System.Management.Automation.ErrorRecord] -or
                $line -match $summaryPattern -or $line -match $diagnosticPattern) {
                $line | Tee-Object -FilePath $logPath -Append | Out-Null
            }
        }
        $probeExitCode = $LASTEXITCODE
    } else {
        & $probePath @probeArguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host $line
            if ($_ -is [System.Management.Automation.ErrorRecord] -or
                $line -match $summaryPattern -or $line -match $diagnosticPattern) {
                $line | Tee-Object -FilePath $logPath -Append | Out-Null
            }
        }
        $probeExitCode = $LASTEXITCODE
    }
} finally {
    [Console]::OutputEncoding = $previousConsoleEncoding
    $OutputEncoding = $previousPowerShellEncoding
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($null -eq $probeExitCode) {
    $probeExitCode = 2
}
$currentReport = $null
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    try {
        $currentReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-ReportLogLine 'probe_status_report_read=failed'
    }
}
if ($null -ne $currentReport) {
    if ([string]$currentReport.run_id -ceq [string]$script:launcherReport.run_id) {
        # Native returned without replacing the launcher's preflight marker; it did not reach its report writer.
        $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $script:launcherReport.final = $true
        $script:launcherReport.status = 'failed'
        $script:launcherReport.phase = 'probe_exited_before_native_report'
        $script:launcherReport.failure_reason = 'native_report_not_created'
        $script:launcherReport.pc_cleanup.serial_handle = 'not_opened'
        try { Write-AtomicReport $script:launcherReport; $currentReport = $script:launcherReport } catch {
            Write-ReportLogLine 'probe_status_report_finalize=failed'
        }
    }
    if ($currentReport.final -eq $true) {
        Write-ReportSummary $currentReport 'probe_'
    } elseif ($currentReport.final -eq $false) {
        Write-ReportLogLine 'probe_status=incomplete'
        Write-ReportLogLine 'probe_pc_cleanup=unknown'
        Write-ReportLogLine 'probe_cleanup_unknown=true'
        Write-ReportSummary $currentReport 'probe_last_snapshot_'
    } else {
        Write-ReportLogLine 'probe_status_report_final_marker=unknown'
    }
} else {
    Write-ReportLogLine 'probe_status_report=missing_or_unreadable'
}
$exitSummary = "launcher_probe_exit_code=$probeExitCode"
$exitSummary | Tee-Object -FilePath $logPath -Append | Out-Null
exit ([int]$probeExitCode)
