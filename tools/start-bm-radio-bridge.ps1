[CmdletBinding()]
param(
    [string]$BridgePath,
    [string]$BodyFile,
    [string]$Port,
    [string]$StatusDirectory,
    [string]$Preset,
    [string]$PasswordFile
)

$ErrorActionPreference = 'Stop'
$script:packageRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:expectedBodyLength = 100
$script:expectedBodySha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:radioWaveOutName = '扬声器 (2- USB Audio Device)'
$script:nativeInvoked = $false
$script:statusPath = ''

function Resolve-LocalFile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Label)
    try { $fullPath = [System.IO.Path]::GetFullPath($Path) }
    catch { throw "$Label 路径无效。" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "找不到$Label：$fullPath" }
    return $fullPath
}

function Resolve-BridgeExecutable {
    if ($BridgePath) { return Resolve-LocalFile -Path $BridgePath -Label 'native bridge 程序' }
    $candidate = Join-Path $script:packageRoot 'wirex_bridge.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "当前便携包目录缺少 wirex_bridge.exe：$candidate；开发运行请传入 -BridgePath。"
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Select-TestPreset {
    param([string]$Requested)
    $allowed = @('parrot-cn', 'parrot-global', 'listen-46001', 'manual')
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $match = @($allowed | Where-Object { $_ -ieq $Requested.Trim() })
        if ($match.Count -ne 1) { throw '测试预设无效；请使用 parrot-cn、parrot-global、listen-46001 或 manual。' }
        return [string]$match[0]
    }
    Write-Host '选择 BM 测试入口：'
    Write-Host '  1. 中国鹦鹉 460997（单呼，可由 T 显式发射）'
    Write-Host '  2. 通用鹦鹉 9990（单呼，可由 T 显式发射）'
    Write-Host '  3. 全国频道 46001（组呼，仅接收；native 拒绝 T）'
    Write-Host '  4. 手工输入 BM 参数（保留原入口）'
    while ($true) {
        $choice = Read-Host '输入 1–4，直接回车默认选择 1'
        if ([string]::IsNullOrWhiteSpace([string]$choice) -or $choice.Trim() -eq '1') { return 'parrot-cn' }
        switch ($choice.Trim()) {
            '2' { return 'parrot-global' }
            '3' { return 'listen-46001' }
            '4' { return 'manual' }
        }
        Write-Host '选项无效，请输入 1、2、3 或 4。' -ForegroundColor Yellow
    }
}

function Test-ApprovedBody {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = Resolve-LocalFile -Path $Path -Label '本机 Y 模板'
    $item = Get-Item -LiteralPath $fullPath
    if ($item.Length -ne $script:expectedBodyLength) { throw "Y 模板长度不符：$fullPath（必须为 $($script:expectedBodyLength) 字节）。" }
    $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $script:expectedBodySha256) { throw "Y 模板 SHA-256 不匹配：$fullPath；没有启动 native 核心。" }
    return $fullPath
}

function Invoke-AudioEnumeration {
    param([Parameter(Mandatory=$true)][string]$Executable)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = '--list-audio-json'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动有界音频设备枚举。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            if (-not $process.WaitForExit(2000)) { throw '音频枚举超时，且无法确认枚举进程已退出。' }
            throw '音频设备枚举超过 10 秒；已停止这次枚举进程。'
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) { throw '音频枚举已退出，但输出管道未及时关闭。' }
        if ($process.ExitCode -ne 0) { throw "native 音频枚举失败，退出码 $($process.ExitCode)。" }
        $json = $stdoutTask.GetAwaiter().GetResult().Trim().TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($json) -or $json.Contains("`n") -or $json.Contains("`r")) {
            throw 'native 音频枚举必须只输出一行 JSON。'
        }
        $devices = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($devices.schema_version -ne 1 -or $devices.type -cne 'audio_devices' -or
            -not $devices.PSObject.Properties['wave_inputs'] -or
            -not $devices.PSObject.Properties['wave_outputs']) {
            throw 'native 音频枚举 schema 与预期不符。'
        }
        foreach ($listName in @('wave_inputs', 'wave_outputs')) {
            $ids = @{}
            foreach ($device in @($devices.$listName)) {
                if ($null -eq $device -or $device.id -is [bool] -or
                    -not ($device.id -is [int] -or $device.id -is [long]) -or $device.id -lt 0 -or
                    [string]::IsNullOrWhiteSpace([string]$device.name) -or
                    $device.pcm_48000_mono_s16_supported -isnot [bool]) {
                    throw "音频枚举的 $listName 含无效记录。"
                }
                if ($ids.ContainsKey([string]$device.id)) { throw "音频枚举的 $listName 含重复设备 ID。" }
                $ids[[string]$device.id] = $true
            }
        }
        return $devices
    } finally {
        $process.Dispose()
    }
}

function Get-CurrentSerialPorts {
    if ($env:OS -ne 'Windows_NT') { throw '本启动器只支持 Windows COM 设备。' }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DEVICEMAP\SERIALCOMM', $false)
    if ($null -eq $key) { return @() }
    try {
        return @($key.GetValueNames() | ForEach-Object { [string]$key.GetValue($_) } |
            Where-Object { $_ -match '^COM[1-9][0-9]*$' } | Sort-Object -Unique)
    } finally { $key.Dispose() }
}

function Read-PortSelection {
    param([Parameter(Mandatory=$true)][string[]]$Ports)
    if ($Ports.Count -eq 0) { throw '当前没有枚举到 Windows COM 端口。' }
    Write-Host '当前 COM 端口（仅查询，没有打开）：'
    foreach ($item in $Ports) { Write-Host "  $item" }
    while ($true) {
        $selected = if ($Port) { $Port } else { Read-Host '输入本次 HRI COM 端口，例如 COM5' }
        $selected = ([string]$selected).Trim().ToUpperInvariant()
        if (@($Ports | Where-Object { $_ -ieq $selected }).Count -eq 1) { return $selected }
        Write-Host '所选 COM 端口不在本次枚举中；请重新输入。' -ForegroundColor Yellow
        $Port = ''
    }
}

function Read-WaveInSelection {
    param([Parameter(Mandatory=$true)][object[]]$Devices)
    if ($Devices.Count -eq 0) { throw '当前没有枚举到 WaveIn 设备。' }
    Write-Host '选择 Radio WaveIn：'
    foreach ($device in $Devices) {
        $support = if ($device.pcm_48000_mono_s16_supported) { '48 kHz PCM 可用' } else { '不支持目标 PCM' }
        Write-Host ("  ID {0}: {1} · {2}" -f $device.id, $device.name, $support)
    }
    while ($true) {
        $text = Read-Host '输入本次枚举得到的 Radio WaveIn ID'
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($Devices | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1 -and $matches[0].pcm_48000_mono_s16_supported) { return $matches[0] }
        }
        Write-Host 'ID 无效或该 WaveIn 不支持 48 kHz、单声道、16 位 PCM。' -ForegroundColor Yellow
    }
}

function Test-StatusDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    $directory = [System.IO.Path]::GetFullPath($Path)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $probe = Join-Path $directory ('.bm-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'ok', (New-Object System.Text.UTF8Encoding($false)))
    } finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force }
    }
    return $directory
}

try {
    $hasDevelopmentOverride = (-not [string]::IsNullOrWhiteSpace($BridgePath)) -or
        (-not [string]::IsNullOrWhiteSpace($BodyFile))
    if ($hasDevelopmentOverride -and [string]::IsNullOrWhiteSpace($StatusDirectory)) {
        throw '显式指定 -BridgePath 或 -BodyFile 时也必须显式指定 -StatusDirectory，避免运行报告落到源码目录。'
    }
    $executable = Resolve-BridgeExecutable
    $selectedPreset = Select-TestPreset -Requested $Preset
    $passwordPath = ''
    if ($selectedPreset -ne 'manual') {
        if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
            $PasswordFile = Join-Path $script:packageRoot 'private\bm-device-password.txt'
        }
        $passwordPath = Resolve-LocalFile -Path $PasswordFile -Label '本机 BM 私有密码文件'
    }
    if ($BodyFile) { $bodySource = $BodyFile } else { $bodySource = Join-Path $script:packageRoot 'private\device-y.bin' }
    $body = Test-ApprovedBody -Path $bodySource
    $devices = Invoke-AudioEnumeration -Executable $executable
    $serialPorts = @(Get-CurrentSerialPorts)
    $portName = Read-PortSelection -Ports $serialPorts

    $radioMatches = @($devices.wave_outputs | Where-Object { $_.name -ceq $script:radioWaveOutName })
    if ($radioMatches.Count -ne 1) {
        throw "Radio WaveOut 必须有且仅有一个完整名称匹配 $($script:radioWaveOutName) 的设备；当前匹配数 $($radioMatches.Count)。"
    }
    if (-not $radioMatches[0].pcm_48000_mono_s16_supported) {
        throw '唯一 Radio WaveOut 不支持 48 kHz、单声道、16 位 PCM。'
    }
    $radioInput = Read-WaveInSelection -Devices @($devices.wave_inputs)
    if ($StatusDirectory) { $statusDirectoryPath = $StatusDirectory }
    else { $statusDirectoryPath = Join-Path $script:packageRoot 'logs' }
    $statusDirectory = Test-StatusDirectory -Path $statusDirectoryPath
    $statusPath = Join-Path $statusDirectory ('bm-bridge-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    $script:statusPath = $statusPath

    Write-Host ''
    Write-Host '启动前已核对：Y 素材长度与 SHA-256、日志目录写权限、COM 枚举、48 kHz 能力和唯一 Radio WaveOut。'
    Write-Host '本机 DIRECT 没有声明射频频率或坐标；BM 配置使用数值 0 表示未配置坐标。'
    if ($selectedPreset -eq 'manual') {
        Write-Host '手工入口会在可见控制台逐项读取 BM 配置，并隐藏输入密码。'
    } else {
        Write-Host "本次预设：$selectedPreset；身份、Master、端口、时隙、色码和目标已固定。"
        Write-Host 'native 从本机私有明文密码文件读取凭据；文件内容不会传入命令行或日志。'
    }
    Write-Host 'native 输入 START 前不会打开 COM、WinMM 音频流或 BM UDP socket。运行最多 120 秒。'
    if ($selectedPreset -eq 'listen-46001') {
        Write-Host '46001 严格仅接收；native 拒绝 T，且不会产生 LC 或 DMRD 上行数据报。'
    } elseif ($selectedPreset -eq 'manual') {
        Write-Host '仅当手工目标不是组呼 46001 时，T 才按原逻辑显式控制 BM DMRD 上行。'
    } else {
        Write-Host 'T 键显式控制 BM DMRD 上行；手咪 PTT 仍由操作者物理操作。'
    }
    Write-Host '只有输入 START 后才连接该 Master 并打开所选 COM/Radio WaveIn/Radio WaveOut。'
    Write-Host '本次不连接 PC monitor，也不发送 RF/PTT 控制命令。'
    Write-Host ("COM: {0} · Radio WaveIn: ID {1} · {2}" -f $portName, $radioInput.id, $radioInput.name)
    Write-Host ("Radio WaveOut: ID {0} · {1}" -f $radioMatches[0].id, $radioMatches[0].name)
    Write-Host ("状态报告：{0}" -f $statusPath)
    Write-Host ''
    $arguments = @('--run', '--port', $portName, '--body-file', $body,
        '--input', [string]$radioInput.id, '--output', [string]$radioMatches[0].id,
        '--status-file', $statusPath)
    if ($selectedPreset -ne 'manual') {
        $arguments += @('--test-preset', $selectedPreset, '--password-file', $passwordPath)
    }
    $script:nativeInvoked = $true
    & $executable @arguments
    $exitCode = [int]$LASTEXITCODE
    Write-Host "native 退出码：$exitCode；退出码不证明声音、BM 实际登录或 RF 结果。"
    Write-Host "状态报告：$statusPath"
    exit $exitCode
} catch {
    if ($script:nativeInvoked) {
        Write-Host "native 已调用；设备和网络是否打开或完成收尾状态未知：$($_.Exception.Message)" -ForegroundColor Red
        if ($script:statusPath) { Write-Host "请检查 native 控制台和状态报告：$($script:statusPath)" }
    } else {
        Write-Host "启动前检查失败：$($_.Exception.Message)；native 核心尚未调用。" -ForegroundColor Red
    }
    exit 2
}
