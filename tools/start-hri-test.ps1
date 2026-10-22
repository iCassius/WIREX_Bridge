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

if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($TestProbePath) -or
        [string]::IsNullOrWhiteSpace($TestFixturePath)) {
        [Console]::Error.WriteLine('Test mode requires a mock probe and a 100-byte mock fixture.')
        exit 2
    }
    $probePath = [System.IO.Path]::GetFullPath($TestProbePath)
    $fixturePath = [System.IO.Path]::GetFullPath($TestFixturePath)
    if ([System.IO.Path]::GetExtension($probePath) -ine '.ps1') {
        [Console]::Error.WriteLine('Test mode only accepts a PowerShell mock; it cannot launch the hardware probe.')
        exit 2
    }
} elseif ($PSBoundParameters.Count -ne 0) {
    [Console]::Error.WriteLine('Test-only parameters cannot be used for a hardware run.')
    exit 2
}

if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    [Console]::Error.WriteLine("Probe executable is missing: $probePath")
    exit 2
}
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    [Console]::Error.WriteLine('The private 100-byte Y template is missing.')
    exit 2
}
if ((Get-Item -LiteralPath $fixturePath).Length -ne 100) {
    [Console]::Error.WriteLine('The private Y template must be exactly 100 bytes.')
    exit 2
}

[System.IO.File]::WriteAllText($logPath, '', [System.Text.Encoding]::Unicode)

if (-not $TestMode) {
    Write-Host ''
    Write-Host 'FTX-1 本机 DIRECT HRI 监听测试（最长 120 秒）'
    Write-Host '开始前确认：电台 USB 已连接；电台 HRI Mode 已启用且 Node Mode 为 DIRECT；官方 WIRES-X 程序已关闭。'
    Write-Host '本次固定打开 COM5、WaveIn 1 和 WaveOut 0。请先准备好耳机，并保持此可见控制台打开。'
    Write-Host '看到“音频路由已打开”后，可用手咪发言不超过 15 秒，然后松开 PTT；不要错过 120 秒截止。'
    Write-Host '日志只保留统计摘要，不保存录音或 HRI 正文。按任意键开始；运行结束后本窗口会直接退出。'
    try {
        [void][Console]::ReadKey($true)
    } catch {
        [Console]::Error.WriteLine('A visible interactive console is required. Open the CMD launcher directly.')
        exit 2
    }
}

$probeArguments = @(
    '--hri-listen', '--port', 'COM5', '--body-file', $fixturePath,
    '--input', '1', '--output', '0', '--seconds', '120', '--gain', '16'
)
$summaryPattern = '^(HRI state stopped:|Audio route started after valid Y/0=|Captured input:|Submitted pre-gain:|Submitted post-gain:|serial_close_success=|Limited V/Y exchange observed;)'

if ($TestMode) {
    # 离线测试用PowerShell模拟器；真实运行固定调用相邻的wirex_probe.exe。
    $global:LASTEXITCODE = 0
    & $probePath @probeArguments 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        if ($line -match $summaryPattern) {
            $line | Tee-Object -FilePath $logPath -Append | Out-Null
        }
    }
    $probeExitCode = $global:LASTEXITCODE
} else {
    & $probePath @probeArguments 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        if ($line -match $summaryPattern) {
            $line | Tee-Object -FilePath $logPath -Append | Out-Null
        }
    }
    $probeExitCode = $LASTEXITCODE
}

if ($null -eq $probeExitCode) {
    $probeExitCode = 2
}
$exitSummary = "launcher_probe_exit_code=$probeExitCode"
$exitSummary | Tee-Object -FilePath $logPath -Append | Out-Null
exit ([int]$probeExitCode)
