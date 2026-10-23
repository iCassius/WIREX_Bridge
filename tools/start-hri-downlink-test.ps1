[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$TestProbePath,
    [string]$TestFixturePath,
    [string]$TestWavPath
)

$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$probePath = Join-Path $packageRoot 'wirex_probe.exe'
$fixturePath = Join-Path $packageRoot 'private\device-y.bin'
$wavPath = Join-Path $packageRoot 'assets\voice-test.wav'
$logPath = Join-Path $packageRoot 'last-downlink-test.log'
$reportPath = Join-Path $packageRoot 'last-downlink-status.json'
$expectedFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$expectedWavSha256 = '4beaf3d5539084f33ae05ba02112823edb75985d2f9e03668e2bdf28cd75570d'
$expectedWaveOutName = '扬声器 (2- USB Audio Device)'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:launcherReport = $null

function Write-AtomicReport {
    param([Parameter(Mandatory=$true)][object]$Report)
    $temporaryPath = $reportPath + '.tmp.' + [string]$Report.run_id
    $backupPath = $temporaryPath + '.bak'
    $json = ConvertTo-Json -InputObject $Report -Depth 10 -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8NoBom)
    try {
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
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
        downlink = [pscustomobject]@{
            enabled = $true
            phase = 'not_started'
            operation_result = 'not_started'
            failure_reason = ''
            start_t_write_attempts = 0
            start_t_write_completions = 0
            start_matching_t_records = 0
            start_matching_t_payload_observed = $false
            start_matching_t_payload_bytes = 0
            stop_t_write_attempts = 0
            stop_t_write_completions = 0
            stop_matching_t_records = 0
            stop_matching_t_payload_observed = $false
            stop_matching_t_payload_bytes = 0
            pcm_submitted_bytes = 0
            pcm_drained = $false
            radio_state = 'unknown'
        }
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

function Get-SafeReportValue {
    param([object]$Value)
    if ($null -eq $Value) { return 'unknown' }
    $text = [string]$Value
    if ($text -match '^[A-Za-z0-9_.-]{1,80}$') { return $text }
    return 'invalid'
}

function Write-ReportSummary {
    param([Parameter(Mandatory=$true)][object]$Report, [string]$Prefix)
    $cleanup = $Report.pc_cleanup
    $downlink = $Report.downlink
    $fields = @(
        ($Prefix + 'run_id=' + (Get-SafeReportValue $Report.run_id)),
        ($Prefix + 'pid=' + (Get-SafeReportValue $Report.pid)),
        ($Prefix + 'stage=' + (Get-SafeReportValue $Report.phase)),
        ($Prefix + 'final=' + (Get-SafeReportValue $Report.final)),
        ($Prefix + 'status=' + (Get-SafeReportValue $Report.status)),
        ($Prefix + 'elapsed_ms=' + (Get-SafeReportValue $Report.elapsed_ms)),
        ($Prefix + 'stop_reason=' + (Get-SafeReportValue $Report.stop_reason)),
        ($Prefix + 'failure_reason=' + (Get-SafeReportValue $Report.failure_reason)),
        ($Prefix + 'start_t_write_attempts=' + (Get-SafeReportValue $downlink.start_t_write_attempts)),
        ($Prefix + 'start_t_write_completions=' + (Get-SafeReportValue $downlink.start_t_write_completions)),
        ($Prefix + 'start_matching_t_records=' + (Get-SafeReportValue $downlink.start_matching_t_records)),
        ($Prefix + 'stop_t_write_attempts=' + (Get-SafeReportValue $downlink.stop_t_write_attempts)),
        ($Prefix + 'stop_t_write_completions=' + (Get-SafeReportValue $downlink.stop_t_write_completions)),
        ($Prefix + 'stop_matching_t_records=' + (Get-SafeReportValue $downlink.stop_matching_t_records)),
        ($Prefix + 'pcm_submitted_bytes=' + (Get-SafeReportValue $downlink.pcm_submitted_bytes)),
        ($Prefix + 'pcm_drained=' + (Get-SafeReportValue $downlink.pcm_drained)),
        ($Prefix + 'downlink_phase=' + (Get-SafeReportValue $downlink.phase)),
        ($Prefix + 'operation_result=' + (Get-SafeReportValue $downlink.operation_result)),
        ($Prefix + 'downlink_failure_reason=' + (Get-SafeReportValue $downlink.failure_reason)),
        ($Prefix + 'audio_input_cleanup=' + (Get-SafeReportValue $cleanup.audio_input)),
        ($Prefix + 'audio_output_cleanup=' + (Get-SafeReportValue $cleanup.audio_output)),
        ($Prefix + 'serial_handle_cleanup=' + (Get-SafeReportValue $cleanup.serial_handle)),
        ($Prefix + 'radio_state=unknown')
    )
    foreach ($field in $fields) { Write-ReportLogLine $field }
}

function Write-LauncherError {
    param([string]$Category, [string]$VisibleMessage)
    Write-Host $VisibleMessage
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Write-ReportLogLine ('launcher_error=' + (Get-SafeReportValue $Category))
    }
    if ($null -ne $script:launcherReport) {
        $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $script:launcherReport.final = $true
        $script:launcherReport.status = 'launcher_failed'
        $script:launcherReport.phase = 'preflight_failed'
        $script:launcherReport.failure_reason = $Category
        $script:launcherReport.downlink.phase = 'not_started'
        $script:launcherReport.downlink.operation_result = 'failed'
        $script:launcherReport.downlink.failure_reason = $Category
        try { Write-AtomicReport $script:launcherReport } catch { }
    }
}

function Test-AssetFile {
    param(
        [string]$Path,
        [string]$Label,
        [string]$ExpectedHash,
        [int64]$MinimumLength
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-LauncherError ('missing_' + $Label) ('The ' + $Label + ' test asset is missing.')
        return $false
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt $MinimumLength) {
        Write-LauncherError ($Label + '_size_invalid') ('The ' + $Label + ' test asset has an invalid size.')
        return $false
    }
    if ($TestMode) { return $true }
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedHash) {
        Write-LauncherError ($Label + '_sha256_mismatch') ('The ' + $Label + ' test asset does not match the approved package file.')
        return $false
    }
    return $true
}

$previousReport = $null
$previousReportState = 'none'
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    try {
        $previousReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host 'Existing downlink status report cannot be read; keeping the report and log unchanged.'
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
        Write-Host 'Existing downlink status report has no valid final marker; keeping the report and log unchanged.'
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
    Write-Host ("Could not write the downlink status report; no probe was started. " + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
    exit 2
}

if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($TestProbePath) -or
        [string]::IsNullOrWhiteSpace($TestFixturePath) -or
        [string]::IsNullOrWhiteSpace($TestWavPath)) {
        Write-LauncherError 'test_arguments_missing' 'Test mode requires a PowerShell mock, a 100-byte mock fixture, and a mock WAV file.'
        exit 2
    }
    $probePath = [System.IO.Path]::GetFullPath($TestProbePath)
    $fixturePath = [System.IO.Path]::GetFullPath($TestFixturePath)
    $wavPath = [System.IO.Path]::GetFullPath($TestWavPath)
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
if (-not (Test-AssetFile $fixturePath 'fixture' $expectedFixtureSha256 100)) { exit 2 }
if ((Get-Item -LiteralPath $fixturePath).Length -ne 100) {
    Write-LauncherError 'fixture_size_invalid' 'The private Y template must be exactly 100 bytes.'
    exit 2
}
if (-not (Test-AssetFile $wavPath 'wav' $expectedWavSha256 45)) { exit 2 }

if (-not $TestMode) {
    $script:launcherReport.phase = 'audio_device_preflight'
    $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    try { Write-AtomicReport $script:launcherReport } catch {
        Write-LauncherError 'session_report_update_failed' 'Could not update the downlink status report; no probe was started.'
        exit 2
    }
}

$previousConsoleEncoding = [Console]::OutputEncoding
$previousPowerShellEncoding = $OutputEncoding
$previousErrorActionPreference = $ErrorActionPreference
$probeExitCode = $null
try {
    # 原生 CLI 使用 UTF-8；PowerShell 按同一编码解码原生命令输出。
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
    $ErrorActionPreference = 'Continue'

    if ($TestMode) {
        $probeExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source
        $audioLines = @(& $probeExecutable -NoLogo -NoProfile -File $probePath '--list-audio' 2>&1)
        $audioExitCode = $LASTEXITCODE
    } else {
        $audioLines = @(& $probePath '--list-audio' 2>&1)
        $audioExitCode = $LASTEXITCODE
    }
    Write-Host '已完成只读音频设备枚举。'
    if ($null -eq $audioExitCode -or $audioExitCode -ne 0) {
        Write-ReportLogLine 'audio_enumeration_exit_code=failed'
        Write-LauncherError 'audio_enumeration_failed' 'The read-only audio device listing failed; no downlink session was started.'
        exit 2
    }
    $matchingOutputCount = 0
    foreach ($item in $audioLines) {
        $line = ([string]$item).Trim()
        $nameSuffix = ': ' + $expectedWaveOutName
        if ($line.StartsWith('output ', [System.StringComparison]::Ordinal) -and
            $line.EndsWith($nameSuffix, [System.StringComparison]::Ordinal)) {
            $separator = $line.IndexOf(':')
            if ($separator -gt 7) {
                $enumeratedId = 0
                $idText = $line.Substring(7, $separator - 7)
                if ([int]::TryParse($idText, [ref]$enumeratedId)) { $matchingOutputCount++ }
            }
        }
    }
    Write-ReportLogLine ('required_waveout_match_count=' + [string]$matchingOutputCount)
    if ($matchingOutputCount -ne 1) {
        Write-LauncherError 'required_waveout_not_unique' 'The required USB WaveOut friendly name must appear exactly once; no downlink session was started.'
        exit 2
    }
    Write-Host '已找到唯一目标 WaveOut；正式流程由原生程序重新枚举并按名称选择，不固定设备编号。'

    if (-not $TestMode) {
        $script:launcherReport.phase = 'awaiting_user_start'
        $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        try { Write-AtomicReport $script:launcherReport } catch {
            Write-LauncherError 'session_report_update_failed' 'Could not update the downlink status report; no probe was started.'
            exit 2
        }
        Write-Host ''
        Write-Host 'FTX-1 DIRECT HRI 下行候选测试（流程约 20 秒，播放约 7.25 秒的固定语句）'
        Write-Host '开始前请确认：HRI Mode 为 ON、Node Mode 为 DIRECT、官方 WIRES-X 程序已关闭、手咪 PTT 已松开，并调好电台扬声器音量。'
        Write-Host '按任意键开始；无需赶到远程窗口操作。运行中可按 Ctrl+C 取消。'
        Write-Host '日志只记录统计、诊断类别和退出码，不记录音频、协议正文或身份信息。radio_state 始终为 unknown；实际是否出声以及是否停止需要你现场确认。'
        $previousTreatControlC = $false
        try {
            $previousTreatControlC = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
            $key = [Console]::ReadKey($true)
        } catch {
            Write-LauncherError 'interactive_console_required' 'A visible interactive console is required. Open the CMD launcher directly.'
            exit 2
        } finally {
            try { [Console]::TreatControlCAsInput = $previousTreatControlC } catch { }
        }
        if ($key.KeyChar -eq [char]3 -or
            (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0 -and $key.Key -eq [ConsoleKey]::C)) {
            $script:launcherReport.final = $true
            $script:launcherReport.status = 'cancelled'
            $script:launcherReport.phase = 'cancelled_before_start'
            $script:launcherReport.failure_reason = ''
            $script:launcherReport.downlink.phase = 'not_started'
            $script:launcherReport.downlink.operation_result = 'cancelled'
            $script:launcherReport.downlink.failure_reason = 'cancelled_before_start'
            Write-ReportLogLine 'launcher_result=cancelled_before_start'
            try { Write-AtomicReport $script:launcherReport } catch { }
            exit 130
        }
    }

    $script:launcherReport.phase = 'probe_starting'
    $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    try { Write-AtomicReport $script:launcherReport } catch {
        Write-LauncherError 'session_report_update_failed' 'Could not update the downlink status report; no probe was started.'
        exit 2
    }
    $probeArguments = @(
        '--hri-downlink-candidate',
        '--port', 'COM5',
        '--body-file', $fixturePath,
        '--file', $wavPath,
        '--report-file', $reportPath
    )

    if ($TestMode) {
        # 离线 mock 调用只接受模拟资产摘要，不会启动 EXE。
        & $probeExecutable -NoLogo -NoProfile -File $probePath @probeArguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host $line
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-ReportLogLine 'native_diagnostic=stderr'
            } elseif ($line -match '^(ERROR:|WAV rejected:|Could not |Invalid port\.|Serial transport stopped:|CloseHandle failed|At least one WinMM|HRI downlink status report update failed)') {
                Write-ReportLogLine 'native_diagnostic=reported'
            }
        }
        $probeExitCode = $LASTEXITCODE
    } else {
        & $probePath @probeArguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host $line
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-ReportLogLine 'native_diagnostic=stderr'
            } elseif ($line -match '^(ERROR:|WAV rejected:|Could not |Invalid port\.|Serial transport stopped:|CloseHandle failed|At least one WinMM|HRI downlink status report update failed)') {
                Write-ReportLogLine 'native_diagnostic=reported'
            }
        }
        $probeExitCode = $LASTEXITCODE
    }
} finally {
    [Console]::OutputEncoding = $previousConsoleEncoding
    $OutputEncoding = $previousPowerShellEncoding
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($null -eq $probeExitCode) { $probeExitCode = 2 }
$currentReport = $null
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    try {
        $currentReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-ReportLogLine 'probe_status_report_read=failed'
    }
}
if ($null -ne $currentReport) {
    $reportUnchanged = ([string]$currentReport.run_id -ceq [string]$script:launcherReport.run_id) -and
        ([string]$currentReport.downlink.phase -ceq 'not_started') -and
        ([string]$currentReport.downlink.operation_result -ceq 'not_started')
    if ($reportUnchanged) {
        $script:launcherReport.snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $script:launcherReport.final = $true
        $script:launcherReport.status = 'failed'
        $script:launcherReport.phase = 'probe_exited_before_native_report'
        $script:launcherReport.failure_reason = 'native_report_not_created'
        $script:launcherReport.pc_cleanup.serial_handle = 'not_opened'
        $script:launcherReport.downlink.phase = 'finished'
        $script:launcherReport.downlink.operation_result = 'failed'
        $script:launcherReport.downlink.failure_reason = 'native_report_not_created'
        try { Write-AtomicReport $script:launcherReport; $currentReport = $script:launcherReport } catch {
            Write-ReportLogLine 'probe_status_report_finalize=failed'
        }
    }
    if ($probeExitCode -ne 0 -and [string]$currentReport.downlink.operation_result -ceq 'completed') {
        # 原生进程退出码非零时，不把操作结果记为成功。
        $currentReport.status = 'failed'
        $currentReport.failure_reason = 'probe_exit_nonzero'
        $currentReport.downlink.operation_result = 'failed'
        $currentReport.downlink.failure_reason = 'probe_exit_nonzero'
        $currentReport.radio_state = 'unknown'
        $currentReport.radio_state_unknown = $true
        $currentReport.downlink.radio_state = 'unknown'
        try { Write-AtomicReport $currentReport } catch { Write-ReportLogLine 'probe_status_report_finalize=failed' }
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
Write-ReportLogLine ('launcher_probe_exit_code=' + [string]$probeExitCode)
exit ([int]$probeExitCode)
