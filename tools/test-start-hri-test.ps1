$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-launcher-test-' + [guid]::NewGuid().ToString('N'))
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
    Assert-True ($testExitCode -eq 7) 'The launcher did not preserve the mock probe exit code.'
    $runnerOutput = [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8)
    Assert-True ($runnerOutput.Contains('音频路由已打开，进入本次 HRI 监听窗口。')) `
        'The launcher did not decode and display the UTF-8 ready line.'

    $actualArguments = @(Get-Content -LiteralPath $argumentsPath)
    $expectedArguments = @(
        '--hri-listen', '--port', 'COM5', '--body-file', $fixturePath,
        '--input', '1', '--output', '0', '--seconds', '120', '--gain', '16'
    )
    Assert-True (($actualArguments -join "`n") -ceq ($expectedArguments -join "`n")) `
        'The launcher did not pass the fixed COM/audio/window/gain profile.'

    $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($logText.Contains('Audio route started after valid Y/0=')) 'The stats log omitted the route summary.'
    Assert-True ($logText.Contains('Captured input: samples=')) 'The stats log omitted PCM statistics.'
    Assert-True ($logText.Contains('serial_close_success=yes.')) 'The stats log omitted serial cleanup status.'
    Assert-True ($logText.Contains('ERROR: synthetic COM5 open diagnostic')) 'The stats log omitted a native diagnostic line.'
    Assert-True ($logText.Contains('launcher_probe_exit_code=7')) 'The stats log omitted the probe exit code.'
    Assert-True (-not $logText.Contains('PRIVATE_BODY_MUST_NOT_BE_LOGGED')) 'The stats log included non-stat output.'

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'wirex_probe.exe'), 'stub', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($logPath, 'HRI state stopped: old success', [System.Text.Encoding]::Unicode)
    Remove-Item -LiteralPath $fixturePath
    & powershell.exe -NoLogo -NoProfile -File $runnerPath 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 2) 'A missing fixture should fail before the mock probe starts.'
    $preflightLog = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::Unicode)
    Assert-True ($preflightLog.Contains('launcher_error=missing_fixture')) 'The preflight error was not recorded.'
    Assert-True (-not $preflightLog.Contains('old success')) 'A preflight failure retained the old success log.'

    $forbiddenExePath = Join-Path $testRoot 'must-not-run.exe'
    [System.IO.File]::WriteAllBytes($forbiddenExePath, [byte[]]::new(1))
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $forbiddenExePath -TestFixturePath (Join-Path $testRoot 'not-used.bin')
    Assert-True ($LASTEXITCODE -eq 2) 'Test mode must reject an EXE path before it could run hardware code.'

    Write-Output 'Launcher mock checks passed: fixed arguments, exit propagation, summary-only log.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_LAUNCHER_TEST_ARGS -ErrorAction SilentlyContinue
}
