$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8File {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$testLeaf = 'wirex-downlink-launcher-test-' + [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $tempRoot $testLeaf
New-Item -ItemType Directory -Path $testRoot | Out-Null
$envNames = @('WIREX_DOWNLINK_TEST_ARGS', 'WIREX_DOWNLINK_TEST_LIST_CALLS', 'WIREX_DOWNLINK_TEST_OUTPUT_ID', 'WIREX_DOWNLINK_TEST_DUPLICATE_AUDIO', 'WIREX_DOWNLINK_TEST_EXIT_CODE', 'WIREX_DOWNLINK_TEST_RESULT', 'WIREX_DOWNLINK_TEST_FINAL')
$savedEnv = @{}
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    $runnerPath = Join-Path $testRoot 'start-hri-downlink-test.ps1'
    $mockPath = Join-Path $testRoot 'mock-probe.ps1'
    $fixturePath = Join-Path $testRoot 'mock-device-y.bin'
    $wavPath = Join-Path $testRoot 'mock-voice.wav'
    $argumentsPath = Join-Path $testRoot 'mock-arguments.txt'
    $listCallsPath = Join-Path $testRoot 'mock-list-calls.txt'
    $reportPath = Join-Path $testRoot 'last-downlink-status.json'
    $logPath = Join-Path $testRoot 'last-downlink-test.log'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-hri-downlink-test.ps1') -Destination $runnerPath
    [System.IO.File]::WriteAllBytes($fixturePath, [byte[]]::new(100))
    [System.IO.File]::WriteAllBytes($wavPath, [byte[]]::new(64))

    @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if ($args.Count -eq 1 -and $args[0] -ceq '--list-audio') {
    [System.IO.File]::AppendAllText($env:WIREX_DOWNLINK_TEST_LIST_CALLS, $env:WIREX_DOWNLINK_TEST_OUTPUT_ID + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    Write-Output 'Wave output devices (select an ID explicitly; no default is chosen):'
    Write-Output ('  output ' + $env:WIREX_DOWNLINK_TEST_OUTPUT_ID + ': 扬声器 (2- USB Audio Device)')
    if ($env:WIREX_DOWNLINK_TEST_DUPLICATE_AUDIO -eq '1') { Write-Output '  output 99: 扬声器 (2- USB Audio Device)' }
    exit 0
}
[System.IO.File]::WriteAllLines($env:WIREX_DOWNLINK_TEST_ARGS, [string[]]$args, [System.Text.Encoding]::UTF8)
Write-Output 'PRIVATE_BODY_SENTINEL_MUST_NOT_BE_LOGGED'
Write-Output 'AUDIO_PATH_SENTINEL_MUST_NOT_BE_LOGGED'
Write-Output 'DEVICE_IDENTITY_SENTINEL_MUST_NOT_BE_LOGGED'
Write-Output 'ERROR: synthetic diagnostic with private details'
$reportIndex = [Array]::IndexOf($args, '--report-file')
if ($reportIndex -ge 0 -and $reportIndex + 1 -lt $args.Count) {
    $statusPath = $args[$reportIndex + 1]
    $report = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try { $ticks = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture) }
    finally { $process.Dispose() }
    $exitCode = [int]$env:WIREX_DOWNLINK_TEST_EXIT_CODE
    $result = [string]$env:WIREX_DOWNLINK_TEST_RESULT
    $report.pid = $PID
    $report.process_created_filetime_utc = $ticks
    $report.final = [bool]::Parse([string]$env:WIREX_DOWNLINK_TEST_FINAL)
    $report.status = $result
    $report.phase = 'finished'
    $report.elapsed_ms = 20000
    $report.failure_reason = if ($result -eq 'completed') { '' } else { 'synthetic_failure' }
    $report.pc_cleanup.audio_input = 'not_started'
    $report.pc_cleanup.audio_output = 'succeeded'
    $report.pc_cleanup.serial_handle = 'succeeded'
    $report.radio_state = 'unknown'
    $report.radio_state_unknown = $true
    $report.downlink.phase = 'finished'
    $report.downlink.operation_result = $result
    $report.downlink.failure_reason = if ($result -eq 'completed') { '' } else { 'synthetic_failure' }
    $report.downlink.start_t_write_attempts = 1
    $report.downlink.start_t_write_completions = 1
    $report.downlink.start_matching_t_records = 1
    $report.downlink.stop_t_write_attempts = 1
    $report.downlink.stop_t_write_completions = 1
    $report.downlink.stop_matching_t_records = 1
    $report.downlink.pcm_submitted_bytes = 672000
    $report.downlink.pcm_drained = $true
    $report.downlink.radio_state = 'unknown'
    [System.IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $report -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
}
exit $exitCode
'@ | Set-Content -LiteralPath $mockPath -Encoding UTF8

    $env:WIREX_DOWNLINK_TEST_ARGS = $argumentsPath
    $env:WIREX_DOWNLINK_TEST_LIST_CALLS = $listCallsPath
    $env:WIREX_DOWNLINK_TEST_DUPLICATE_AUDIO = '0'
    function Invoke-DownlinkMock {
        param([string]$OutputId, [int]$ExitCode, [string]$Result, [bool]$DuplicateAudio = $false, [bool]$Final = $true)
        $env:WIREX_DOWNLINK_TEST_OUTPUT_ID = $OutputId
        $env:WIREX_DOWNLINK_TEST_EXIT_CODE = [string]$ExitCode
        $env:WIREX_DOWNLINK_TEST_RESULT = $Result
        $env:WIREX_DOWNLINK_TEST_FINAL = [string]$Final
        $env:WIREX_DOWNLINK_TEST_DUPLICATE_AUDIO = if ($DuplicateAudio) { '1' } else { '0' }
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $script:lastChildOutput = @(& powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode -TestProbePath $mockPath -TestFixturePath $fixturePath -TestWavPath $wavPath 2>&1)
            $childExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldPreference
        }
        return $childExit
    }

    $firstExit = Invoke-DownlinkMock '2' 0 'completed'
    Assert-True ($firstExit -eq 0) "A completed mock run should return zero; got $firstExit. Output: $([string]::Join([Environment]::NewLine, [string[]]$script:lastChildOutput))"
    $actual = @(Get-Content -LiteralPath $argumentsPath -Encoding UTF8)
    $expected = @('--hri-downlink-candidate', '--port', 'COM5', '--body-file', [System.IO.Path]::GetFullPath($fixturePath), '--file', [System.IO.Path]::GetFullPath($wavPath), '--report-file', [System.IO.Path]::GetFullPath($reportPath))
    Assert-True ([string]::Join([Environment]::NewLine, $actual) -ceq [string]::Join([Environment]::NewLine, $expected)) 'The launcher arguments differ from the candidate contract.'
    Assert-True (-not ($actual -contains '--output')) 'The launcher must not pass any fixed WaveOut number.'
    $firstLog = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($firstLog.Contains('required_waveout_match_count=1')) 'The unique output-name match was not recorded.'
    Assert-True ($firstLog.Contains('probe_operation_result=completed')) 'The log omitted the operation result.'
    Assert-True ($firstLog.Contains('probe_start_matching_t_records=1')) 'The log omitted the matching start-record count.'
    Assert-True ($firstLog.Contains('probe_stop_matching_t_records=1')) 'The log omitted the matching stop-record count.'
    Assert-True ($firstLog.Contains('probe_radio_state=unknown')) 'The report summary must keep radio state unknown.'
    Assert-True ($firstLog.Contains('launcher_probe_exit_code=0')) 'The log omitted the process exit code.'
    Assert-True ($firstLog.Contains('native_diagnostic=reported')) 'The log omitted a sanitized diagnostic category.'
    foreach ($marker in @('PRIVATE_BODY_SENTINEL', 'AUDIO_PATH_SENTINEL', 'DEVICE_IDENTITY_SENTINEL', 'synthetic diagnostic with private details')) {
        Assert-True (-not $firstLog.Contains($marker)) "The log contains forbidden content: $marker"
    }
    $firstReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($firstReport.radio_state -ceq 'unknown' -and $firstReport.downlink.radio_state -ceq 'unknown') 'The report must keep radio_state unknown.'

    $secondExit = Invoke-DownlinkMock '3' 9 'completed'
    Assert-True ($secondExit -eq 9) 'The launcher must preserve a nonzero native exit code.'
    $listIds = @(Get-Content -LiteralPath $listCallsPath -Encoding UTF8)
    Assert-True ([string]::Join(',', $listIds) -ceq '2,3') 'The test did not exercise changing enumerated output IDs.'
    $secondReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($secondReport.downlink.operation_result -ceq 'failed') 'A nonzero exit must not leave a completed operation result.'
    Assert-True ($secondReport.downlink.failure_reason -ceq 'probe_exit_nonzero') 'The failed-exit report must explain the correction.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('probe_operation_result=failed')) 'The log summarized a failed exit as completed.'

    [System.IO.File]::WriteAllText($argumentsPath, 'KEEP_DUPLICATE_MARKER', [System.Text.Encoding]::UTF8)
    $duplicateExit = Invoke-DownlinkMock '4' 0 'completed' $true
    Assert-True ($duplicateExit -eq 2) 'Duplicate friendly names must block the candidate call.'
    Assert-True ([System.IO.File]::ReadAllText($argumentsPath, [System.Text.Encoding]::UTF8).Contains('KEEP_DUPLICATE_MARKER')) 'The candidate ran despite duplicate audio names.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('required_waveout_match_count=2')) 'The duplicate-name failure was not logged.'

    $incompleteExit = Invoke-DownlinkMock '5' 8 'completed' $false $false
    Assert-True ($incompleteExit -eq 8) 'An incomplete mock report must retain its nonzero exit code.'
    $incompleteReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($incompleteReport.final -eq $false -and $incompleteReport.downlink.operation_result -ceq 'failed') 'A nonzero exit must not leave an incomplete report with operation_result=completed.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('probe_last_snapshot_operation_result=failed')) 'The incomplete report summary must show the nonzero exit as failed.'

    $ended = $secondReport.PSObject.Copy()
    $ended.run_id = 'mock-incomplete'
    $ended.pid = 2147483647
    $ended.process_created_filetime_utc = '134000000000000000'
    $ended.final = $false
    $ended.status = 'running'
    $ended.phase = 'pcm_active'
    $ended.downlink.phase = 'pcm_active'
    $ended.downlink.operation_result = 'running'
    [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $ended -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $endedExit = Invoke-DownlinkMock '3' 5 'failed'
    Assert-True ($endedExit -eq 5) 'A failed mock run should preserve its exit code.'
    $endedLog = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($endedLog.Contains('previous_probe_status=incomplete')) 'The ended previous owner was not marked incomplete.'
    Assert-True ($endedLog.Contains('previous_stage=pcm_active')) 'The previous report stage was not preserved.'
    Assert-True ($endedLog.Contains('previous_pcm_submitted_bytes=672000')) 'The previous report counters were not preserved.'
    $failedReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($failedReport.downlink.operation_result -ceq 'failed') 'A failed native result must remain failed.'

    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try { $ticks = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture) }
    finally { $process.Dispose() }
    $active = $ended.PSObject.Copy()
    $active.run_id = 'mock-active'
    $active.pid = $PID
    $active.process_created_filetime_utc = $ticks
    [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $active -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($logPath, 'KEEP_ACTIVE_LOG', [System.Text.Encoding]::Unicode)
    Assert-True ((Invoke-DownlinkMock '3' 0 'completed') -eq 2) 'A report owned by an active process must block launch.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('KEEP_ACTIVE_LOG')) 'The active-owner guard cleared the log.'

    $unknown = $ended.PSObject.Copy()
    $unknown.run_id = 'mock-unknown'
    $unknown.pid = 'not-a-pid'
    [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $unknown -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    Assert-True ((Invoke-DownlinkMock '3' 0 'completed') -eq 2) 'An unknown report owner must block launch.'
    Assert-True ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode).Contains('KEEP_ACTIVE_LOG')) 'The unknown-owner guard cleared the log.'

    $assetRoot = Join-Path $testRoot 'asset-preflight'
    $assetPrivate = Join-Path $assetRoot 'private'
    $assetAssets = Join-Path $assetRoot 'assets'
    New-Item -ItemType Directory -Path $assetPrivate -Force | Out-Null
    New-Item -ItemType Directory -Path $assetAssets -Force | Out-Null
    $assetRunner = Join-Path $assetRoot 'start-hri-downlink-test.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-hri-downlink-test.ps1') -Destination $assetRunner
    [System.IO.File]::WriteAllText((Join-Path $assetRoot 'wirex_probe.exe'), 'must-not-be-launched', [System.Text.Encoding]::ASCII)
    $assetFixture = Join-Path $assetPrivate 'device-y.bin'
    $assetWav = Join-Path $assetAssets 'voice-test.wav'
    [System.IO.File]::WriteAllBytes($assetFixture, [byte[]]::new(100))
    [System.IO.File]::WriteAllBytes($assetWav, [byte[]]::new(64))
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $assetOutput = @(& powershell.exe -NoLogo -NoProfile -File $assetRunner 2>&1)
        $assetExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($assetExit -eq 2) "The wrong production fixture hash must fail preflight. Output: $([string]::Join([Environment]::NewLine, [string[]]$assetOutput))"
    $assetLog = [System.IO.File]::ReadAllText((Join-Path $assetRoot 'last-downlink-test.log'), [System.Text.Encoding]::Unicode)
    Assert-True ($assetLog.Contains('launcher_error=fixture_sha256_mismatch')) 'The fixture hash failure was not recorded.'
    Assert-True (-not $assetLog.Contains('required_waveout_match_count=')) 'Audio enumeration occurred before fixture validation.'

    # 仅在临时副本中模拟获准的 fixture 摘要，以便无私有资产地覆盖 WAV 摘要失败分支。
    $wavHashRunner = Join-Path $assetRoot 'start-hri-wav-hash-test.ps1'
    $sourceText = [System.IO.File]::ReadAllText($assetRunner, [System.Text.Encoding]::UTF8)
    $testFixtureHash = (Get-FileHash -LiteralPath $assetFixture -Algorithm SHA256).Hash.ToLowerInvariant()
    $approvedFixtureHash = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
    $wavHashSource = $sourceText.Replace($approvedFixtureHash, $testFixtureHash)
    Assert-True ($wavHashSource -cne $sourceText) 'The isolated simulated fixture hash was not applied.'
    Write-Utf8File $wavHashRunner $wavHashSource
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $wavHashOutput = @(& powershell.exe -NoLogo -NoProfile -File $wavHashRunner 2>&1)
        $wavHashExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($wavHashExit -eq 2) "The wrong production WAV hash must fail preflight. Output: $([string]::Join([Environment]::NewLine, [string[]]$wavHashOutput))"
    $wavHashLog = [System.IO.File]::ReadAllText((Join-Path $assetRoot 'last-downlink-test.log'), [System.Text.Encoding]::Unicode)
    Assert-True ($wavHashLog.Contains('launcher_error=wav_sha256_mismatch')) 'The WAV hash failure was not recorded.'
    Assert-True (-not $wavHashLog.Contains('required_waveout_match_count=')) 'Audio enumeration occurred before WAV validation.'

    Write-Output 'Downlink launcher mock checks passed: strict assets, unique dynamic WaveOut, fixed args, ownership, safe logs, and truthful failures.'
} finally {
    try {
        $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot).TrimEnd('\', '/')
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $prefix = $resolvedTempRoot + [System.IO.Path]::DirectorySeparatorChar
        $leaf = [System.IO.Path]::GetFileName($resolvedTestRoot)
        $withinTemp = $resolvedTestRoot.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
        $exactLeaf = $leaf -ceq $testLeaf -and $leaf -match '^wirex-downlink-launcher-test-[0-9a-f]{32}$'
        if ($resolvedTestRoot -eq $resolvedTempRoot -or -not $withinTemp -or -not $exactLeaf) {
            throw "Refusing recursive cleanup outside this test's exact temporary directory: $resolvedTestRoot"
        }
        if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
    } finally {
        foreach ($name in $envNames) {
            [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
        }
    }
}
