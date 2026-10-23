$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$testLeaf = 'wirex-launcher-test-' + [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $tempRoot $testLeaf
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $runnerPath = Join-Path $testRoot 'start-hri-test.ps1'
    $mockPath = Join-Path $testRoot 'mock-probe.ps1'
    $fixturePath = Join-Path $testRoot 'mock-device-y.bin'
    $argumentsPath = Join-Path $testRoot 'mock-arguments.txt'
    $logPath = Join-Path $testRoot 'last-test.log'
    $stdoutPath = Join-Path $testRoot 'runner-stdout.txt'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-hri-test.ps1') -Destination $runnerPath
    [System.IO.File]::WriteAllBytes($fixturePath, [byte[]]::new(100))
    @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($env:WIREX_LAUNCHER_TEST_ARGS, $args)
Write-Output 'PRIVATE_BODY_MUST_NOT_BE_LOGGED'
Write-Output '音频路由已打开，进入本次 HRI 监听窗口。'
Write-Output 'Audio route started after valid Y/0=yes; captured bytes=32000, submitted bytes=31900, dropped blocks=0.'
Write-Output 'Captured input: samples=16000, RMS=-24.0 dBFS, peak=-4.0 dBFS.'
Write-Output 'Submitted pre-gain: samples=16000, RMS=-24.0 dBFS, peak=-4.0 dBFS.'
Write-Output 'Submitted post-gain: samples=16000, RMS=-8.0 dBFS, peak=0.0 dBFS, saturated samples=12.'
Write-Output 'serial_close_success=yes.'
$reportArgIndex = [Array]::IndexOf($args, '--report-file')
if ($reportArgIndex -ge 0 -and $reportArgIndex + 1 -lt $args.Count) {
        $reportPath = $args[$reportArgIndex + 1]
        $process = [System.Diagnostics.Process]::GetCurrentProcess()
        try { $createdTicks = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture) }
        finally { $process.Dispose() }
        $report = [pscustomobject]@{
            schema_version = 1; run_id = 'mock-final'; pid = $PID
            process_created_filetime_utc = $createdTicks
            snapshot_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            final = $true; status = 'completed'; phase = 'stopped'; elapsed_ms = 120000
            stop_reason = 'deadline'; version_response_validated = $true
            y_write_completed = 120; y_zero_ack_received = 120; x100_received = 2
            x0_write_completed = 2; receive_bytes = 100; transmit_bytes_requested = 1000
            audio_started = $true; captured_bytes = 32000; submitted_bytes = 31900; dropped_blocks = 0
            pc_cleanup = [pscustomobject]@{ audio_input = 'succeeded'; audio_output = 'succeeded'; serial_handle = 'succeeded' }
            radio_state = 'unknown'
        }
        [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Compress), (New-Object System.Text.UTF8Encoding($false)))
}
 [Console]::Error.WriteLine('ERROR: synthetic COM5 open diagnostic')
exit 7
'@ | Set-Content -LiteralPath $mockPath -Encoding UTF8

    $env:WIREX_LAUNCHER_TEST_ARGS = $argumentsPath
    $oldConsoleEncoding = [Console]::OutputEncoding
    $oldErrorActionPreference = $ErrorActionPreference
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
            -TestProbePath $mockPath -TestFixturePath $fixturePath 2>&1 |
            ForEach-Object {
                [System.IO.File]::AppendAllText($stdoutPath, ([string]$_ + [Environment]::NewLine), [System.Text.Encoding]::UTF8)
            }
        $testExitCode = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $oldConsoleEncoding
        $ErrorActionPreference = $oldErrorActionPreference
    }
    Assert-True ($testExitCode -eq 7) "The launcher did not preserve the mock probe exit code; got $testExitCode. Output: $([System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8))"
    $runnerOutput = [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8)
    Assert-True ($runnerOutput.Contains('音频路由已打开，进入本次 HRI 监听窗口。')) `
        'The launcher did not decode and display the UTF-8 ready line.'

    $actualArguments = @(Get-Content -LiteralPath $argumentsPath)
    $expectedArguments = @(
        '--hri-listen', '--port', 'COM5', '--body-file', $fixturePath,
        '--input', '1', '--output', '0', '--seconds', '120', '--gain', '16',
        '--report-file', (Join-Path $testRoot 'last-session-status.json')
    )
    Assert-True (($actualArguments -join "`n") -ceq ($expectedArguments -join "`n")) `
        'The launcher did not pass the fixed COM/audio/window/gain profile.'

    $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($logText.Contains('Audio route started after valid Y/0=')) 'The stats log omitted the route summary.'
    Assert-True ($logText.Contains('Captured input: samples=')) 'The stats log omitted PCM statistics.'
    Assert-True ($logText.Contains('serial_close_success=yes.')) 'The stats log omitted serial cleanup status.'
    Assert-True ($logText.Contains('ERROR: synthetic COM5 open diagnostic')) 'The stats log omitted a native diagnostic line.'
    Assert-True ($logText.Contains('launcher_probe_exit_code=7')) 'The stats log omitted the probe exit code.'
    Assert-True ($logText.Contains('probe_status=completed')) "The stats log omitted the final metadata status. Log: $logText"
    Assert-True (-not $logText.Contains('PRIVATE_BODY_MUST_NOT_BE_LOGGED')) 'The stats log included non-stat output.'

    $statusPath = Join-Path $testRoot 'last-session-status.json'
    $endedReport = [pscustomobject]@{
        schema_version = 1; run_id = 'mock-incomplete'; pid = 2147483647
        process_created_filetime_utc = '134000000000000000'
        snapshot_utc = '2026-10-23T00:00:00.000Z'; final = $false
        status = 'running'; phase = 'audio_active'; elapsed_ms = 31000; stop_reason = 'none'
        version_response_validated = $true; y_write_completed = 2; y_zero_ack_received = 1
        x100_received = 1; x0_write_completed = 1; receive_bytes = 100; transmit_bytes_requested = 200
        audio_started = $true; captured_bytes = 64000; submitted_bytes = 63000; dropped_blocks = 1
        pc_cleanup = [pscustomobject]@{ audio_input = 'pending'; audio_output = 'pending'; serial_handle = 'pending' }
        radio_state = 'unknown'
    }
    [System.IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $endedReport -Compress), (New-Object System.Text.UTF8Encoding($false)))
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $mockPath -TestFixturePath $fixturePath 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 7) 'A completed old process should allow a new mock run after preserving its incomplete summary.'
    $endedLog = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($endedLog.Contains('previous_probe_status=incomplete')) 'The previous unfinished session was not marked incomplete.'
    Assert-True ($endedLog.Contains('previous_pc_cleanup=unknown')) 'The previous PC cleanup should remain unknown.'
    Assert-True ($endedLog.Contains('previous_stage=audio_active')) 'The previous stage was not preserved.'
    Assert-True ($endedLog.Contains('previous_y_write_completed=2')) 'The previous counters were not preserved.'

    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    try { $currentTicks = $currentProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture) }
    finally { $currentProcess.Dispose() }
    $activeReport = $endedReport.PSObject.Copy()
    $activeReport.run_id = 'mock-active'
    $activeReport.pid = $PID
    $activeReport.process_created_filetime_utc = $currentTicks
    [System.IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $activeReport -Compress), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($logPath, 'KEEP_ACTIVE_LOG', [System.Text.Encoding]::Unicode)
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $mockPath -TestFixturePath $fixturePath 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 2) 'An active process matching PID and creation time must block a new run.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('KEEP_ACTIVE_LOG')) `
        'The active-run guard must retain the existing log.'

    $unknownReport = $endedReport.PSObject.Copy()
    $unknownReport.run_id = 'mock-unknown'
    $unknownReport.pid = $PID
    $unknownReport.process_created_filetime_utc = ''
    [System.IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $unknownReport -Compress), (New-Object System.Text.UTF8Encoding($false)))
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $mockPath -TestFixturePath $fixturePath 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 2) 'An unverifiable non-final report must block a new run.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('KEEP_ACTIVE_LOG')) `
        'The unverifiable-run guard must retain the existing log.'

    $finalOldReport = $endedReport.PSObject.Copy()
    $finalOldReport.final = $true
    $finalOldReport.status = 'completed'
    [System.IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $finalOldReport -Compress), (New-Object System.Text.UTF8Encoding($false)))

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'wirex_probe.exe'), 'stub', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($logPath, 'HRI state stopped: old success', [System.Text.Encoding]::Unicode)
    Remove-Item -LiteralPath $fixturePath
    & powershell.exe -NoLogo -NoProfile -File $runnerPath 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 2) 'A missing fixture should fail before the mock probe starts.'
    $preflightLog = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($preflightLog.Contains('launcher_error=missing_fixture')) "The preflight error was not recorded. Log: $preflightLog"
    Assert-True (-not $preflightLog.Contains('old success')) 'A preflight failure retained the old success log.'

    $forbiddenExePath = Join-Path $testRoot 'must-not-run.exe'
    [System.IO.File]::WriteAllBytes($forbiddenExePath, [byte[]]::new(1))
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $forbiddenExePath -TestFixturePath (Join-Path $testRoot 'not-used.bin')
    Assert-True ($LASTEXITCODE -eq 2) 'Test mode must reject an EXE path before it could run hardware code.'

    Write-Output 'Launcher mock checks passed: fixed arguments, exit propagation, summary-only log.'
} finally {
    try {
        $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot).TrimEnd('\', '/')
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $tempPrefix = $resolvedTempRoot + [System.IO.Path]::DirectorySeparatorChar
        $leafName = [System.IO.Path]::GetFileName($resolvedTestRoot)
        $withinTemp = $resolvedTestRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        $expectedLeaf = $leafName -ceq $testLeaf -and $leafName -match '^wirex-launcher-test-[0-9a-f]{32}$'
        if ($resolvedTestRoot -eq $resolvedTempRoot -or -not $withinTemp -or -not $expectedLeaf) {
            throw "Refusing recursive cleanup outside this test's exact temporary directory: $resolvedTestRoot"
        }
        if (Test-Path -LiteralPath $resolvedTestRoot) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    } finally {
        Remove-Item Env:\WIREX_LAUNCHER_TEST_ARGS -ErrorAction SilentlyContinue
    }
}
