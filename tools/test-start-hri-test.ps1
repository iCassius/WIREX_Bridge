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
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-hri-test.ps1') -Destination $runnerPath
    [System.IO.File]::WriteAllBytes($fixturePath, [byte[]]::new(100))
    @'
$global:LASTEXITCODE = 7
[System.IO.File]::WriteAllLines($env:WIREX_LAUNCHER_TEST_ARGS, $args)
Write-Output 'PRIVATE_BODY_MUST_NOT_BE_LOGGED'
Write-Output 'Audio route started after valid Y/0=yes; captured bytes=32000, submitted bytes=31900, dropped blocks=0.'
Write-Output 'Captured input: samples=16000, RMS=-24.0 dBFS, peak=-4.0 dBFS.'
Write-Output 'Submitted pre-gain: samples=16000, RMS=-24.0 dBFS, peak=-4.0 dBFS.'
Write-Output 'Submitted post-gain: samples=16000, RMS=-8.0 dBFS, peak=0.0 dBFS, saturated samples=12.'
Write-Output 'serial_close_success=yes.'
'@ | Set-Content -LiteralPath $mockPath -Encoding UTF8

    $env:WIREX_LAUNCHER_TEST_ARGS = $argumentsPath
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $mockPath -TestFixturePath $fixturePath
    $testExitCode = $LASTEXITCODE
    Assert-True ($testExitCode -eq 7) 'The launcher did not preserve the mock probe exit code.'

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
    Assert-True ($logText.Contains('launcher_probe_exit_code=7')) 'The stats log omitted the probe exit code.'
    Assert-True (-not $logText.Contains('PRIVATE_BODY_MUST_NOT_BE_LOGGED')) 'The stats log included non-stat output.'

    $forbiddenExePath = Join-Path $testRoot 'must-not-run.exe'
    [System.IO.File]::WriteAllBytes($forbiddenExePath, [byte[]]::new(1))
    & powershell.exe -NoLogo -NoProfile -File $runnerPath -TestMode `
        -TestProbePath $forbiddenExePath -TestFixturePath $fixturePath
    Assert-True ($LASTEXITCODE -eq 2) 'Test mode must reject an EXE path before it could run hardware code.'

    Write-Output 'Launcher mock checks passed: fixed arguments, exit propagation, summary-only log.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_LAUNCHER_TEST_ARGS -ErrorAction SilentlyContinue
}
