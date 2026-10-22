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
[System.IO.File]::WriteAllText($logPath, '', [System.Text.Encoding]::Unicode)

function Write-LauncherError {
    param([string]$Category, [string]$VisibleMessage)
    Write-Host $VisibleMessage
    ("launcher_error=$Category") | Tee-Object -FilePath $logPath -Append | Out-Null
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

$probeArguments = @(
    '--hri-listen', '--port', 'COM5', '--body-file', $fixturePath,
    '--input', '1', '--output', '0', '--seconds', '120', '--gain', '16'
)
$summaryPattern = '^(HRI state stopped:|Audio route started after valid Y/0=|Captured input:|Submitted pre-gain:|Submitted post-gain:|serial_close_success=|Limited V/Y exchange observed;)'
$diagnosticPattern = '^(ERROR:|Cannot open COM[0-9]+:|Could not |Invalid port\.|Serial transport stopped:|CloseHandle failed|At least one WinMM)'

$previousConsoleEncoding = [Console]::OutputEncoding
$previousPowerShellEncoding = $OutputEncoding
$previousErrorActionPreference = $ErrorActionPreference
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
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
$exitSummary = "launcher_probe_exit_code=$probeExitCode"
$exitSummary | Tee-Object -FilePath $logPath -Append | Out-Null
exit ([int]$probeExitCode)
