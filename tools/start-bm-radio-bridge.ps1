[CmdletBinding()]
param(
    [string]$BridgePath,
    [string]$BodyFile,
    [string]$Port,
    [string]$WaveIn,
    [string]$WaveOut,
    [string]$StatusDirectory,
    [string]$Preset,
    [string]$PasswordFile,
    [switch]$ManualPtt
)

$ErrorActionPreference = 'Stop'
$script:packageRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:expectedBodyLength = 100
$script:expectedBodySha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
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
    return 'parrot-cn'
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
                    ($device.PSObject.Properties['endpoint_id'] -and $null -ne $device.endpoint_id -and $device.endpoint_id -isnot [string]) -or
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

function Get-PnpPropertyData {
    param([Parameter(Mandatory=$true)][string]$InstanceId, [Parameter(Mandatory=$true)][string]$KeyName)
    if (-not (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) { return $null }
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction SilentlyContinue
    if ($null -eq $property) { return $null }
    return $property.Data
}

function Get-HriSerialDevices {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return @() }
    $presentPorts = @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue)
    $devices = @()
    foreach ($device in $presentPorts) {
        $instanceId = [string]$device.InstanceId
        $identity = [regex]::Match($instanceId, '^USB\\VID_26AA&PID_([0-9A-F]{4})\\', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $identity.Success) { continue }
        $productId = [Convert]::ToInt32($identity.Groups[1].Value, 16)
        if ($productId -lt 0x0030) { continue }
        $friendlyName = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_FriendlyName')
        $busDescription = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc')
        $portMatch = [regex]::Match($friendlyName, '\((COM[1-9][0-9]*)\)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $devices += [pscustomobject]@{
            InstanceId = $instanceId
            ProductId = $identity.Groups[1].Value.ToUpperInvariant()
            FriendlyName = $friendlyName
            BusDescription = $busDescription
            PortName = if ($portMatch.Success) { $portMatch.Groups[1].Value.ToUpperInvariant() } else { '' }
            IsHri = ($busDescription -match '(?i)\bHRI\b')
        }
    }
    return @($devices)
}

function Read-PortSelection {
    param([Parameter(Mandatory=$true)][string[]]$Ports, [Parameter(Mandatory=$true)][object[]]$HriDevices)
    if ($Ports.Count -eq 0) { throw '当前没有枚举到 Windows COM 端口。' }
    $current = @($Ports | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $presentHri = @($HriDevices | Where-Object { $_.IsHri -and $_.PortName -and $current -contains $_.PortName })
    $com5Matches = @($presentHri | Where-Object { $_.PortName -ieq 'COM5' })
    if (-not $Port -and $current -contains 'COM5' -and $presentHri.Count -eq 1 -and $com5Matches.Count -eq 1) {
        Write-Host ("已识别电台串口 COM5 · VID_26AA&PID_{0}" -f $com5Matches[0].ProductId)
        return 'COM5'
    }

    if (-not $Port) {
        if ($presentHri.Count -gt 1) {
            Write-Host '请选择本次使用的 HRI 串口：'
            foreach ($device in $presentHri) {
                Write-Host ("  {0} · VID_26AA&PID_{1}" -f $device.PortName, $device.ProductId)
            }
        } else {
            Write-Host '请选择本次使用的 HRI 串口：'
            foreach ($item in $current) {
                $matches = @($HriDevices | Where-Object { $_.PortName -ieq $item })
                if ($matches.Count -eq 1) {
                    Write-Host ("  {0} · VID_26AA&PID_{1}" -f $item, $matches[0].ProductId)
                } else {
                    Write-Host "  $item"
                }
            }
        }
    }
    $restrictToHri = (-not $Port -and $presentHri.Count -gt 1)
    while ($true) {
        $selected = if ($Port) { $Port } else { Read-Host '输入本次 HRI COM 端口' }
        $selected = ([string]$selected).Trim().ToUpperInvariant()
        $isCurrent = @($current | Where-Object { $_ -ieq $selected }).Count -eq 1
        $isHriCandidate = @($presentHri | Where-Object { $_.PortName -ieq $selected }).Count -eq 1
        if ($isCurrent -and (-not $restrictToHri -or $isHriCandidate)) {
            $selectedDevice = @($presentHri | Where-Object { $_.PortName -ieq $selected })
            if ($selectedDevice.Count -eq 1) {
                Write-Host ("已选择 HRI 串口 {0}" -f $selected)
            } else {
                Write-Host ("已选择串口 {0}" -f $selected)
            }
            return $selected
        }
        Write-Host '所选 COM 端口不在本次枚举中；请重新输入。' -ForegroundColor Yellow
        $Port = ''
    }
}

function Read-WaveInSelection {
    param([Parameter(Mandatory=$true)][object[]]$Devices)
    $available = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -and -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    if ($available.Count -eq 0) { throw '没有可用的 48 kHz WaveIn 端点；请检查电台 USB 音频连接后重试。' }
    Write-Host '请选择电台音频输入：'
    foreach ($device in $available) {
        Write-Host ("  ID {0}: {1} · 48 kHz PCM 可用" -f $device.id, $device.name)
    }
    while ($true) {
        $text = if ($WaveIn) { $WaveIn } else { Read-Host '输入本次枚举得到的 Radio WaveIn ID' }
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($available | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1) { return $matches[0] }
        }
        Write-Host '请输入列表中的 WaveIn ID。' -ForegroundColor Yellow
        $WaveIn = ''
    }
}

function Read-WaveOutSelection {
    param([Parameter(Mandatory=$true)][object[]]$Devices)
    $available = @($Devices | Where-Object {
        $_.pcm_48000_mono_s16_supported -and -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    if ($available.Count -eq 0) { throw '没有可用的 48 kHz WaveOut 端点；请检查电台 USB 音频连接后重试。' }
    Write-Host '请选择电台音频输出：'
    foreach ($device in $available) {
        Write-Host ("  ID {0}: {1} · 48 kHz PCM 可用" -f $device.id, $device.name)
    }
    while ($true) {
        $text = if ($WaveOut) { $WaveOut } else { Read-Host '输入本次枚举得到的 Radio WaveOut ID' }
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($available | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1) { return $matches[0] }
        }
        Write-Host '请输入列表中的 WaveOut ID。' -ForegroundColor Yellow
        $WaveOut = ''
    }
}

function Find-UsbAudioNamePair {
    param([Parameter(Mandatory=$true)][object]$Devices)
    $inputMatches = @($Devices.wave_inputs | Where-Object {
        $_.name -match '(?i)USB Audio' -and $_.pcm_48000_mono_s16_supported -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    $outputMatches = @($Devices.wave_outputs | Where-Object {
        $_.name -match '(?i)USB Audio' -and $_.pcm_48000_mono_s16_supported -and
            -not [string]::IsNullOrWhiteSpace([string]$_.endpoint_id)
    })
    if ($inputMatches.Count -ne 1 -or $outputMatches.Count -ne 1) { return $null }
    return [pscustomobject]@{ Input = $inputMatches[0]; Output = $outputMatches[0] }
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
    $hriDevices = @(Get-HriSerialDevices)
    $portName = Read-PortSelection -Ports $serialPorts -HriDevices $hriDevices
    $radioSerialMatches = @($hriDevices | Where-Object { $_.IsHri -and $_.PortName -ieq $portName })
    $radioSerial = if ($radioSerialMatches.Count -eq 1) { $radioSerialMatches[0] } else { $null }

    $audioPair = $null
    if ($radioSerial) { $audioPair = Find-UsbAudioNamePair -Devices $devices }
    if ($WaveIn -and -not $WaveOut) { throw '手工指定音频设备时必须同时传入 -WaveIn 和 -WaveOut。' }
    if ($WaveOut -and -not $WaveIn) { throw '手工指定音频设备时必须同时传入 -WaveIn 和 -WaveOut。' }
    if ($WaveIn -or $WaveOut) { $audioPair = $null }
    if ($audioPair) {
        $radioInput = $audioPair.Input
        $radioOutput = $audioPair.Output
        Write-Host '已选择名称含 USB Audio 的唯一 WaveIn 和 WaveOut。'
    } else {
        Write-Host '请选择连接到电台的 WaveIn 和 WaveOut：'
        $radioInput = Read-WaveInSelection -Devices @($devices.wave_inputs)
        $radioOutput = Read-WaveOutSelection -Devices @($devices.wave_outputs)
    }
    $waveinEndpointId = [string]$radioInput.endpoint_id
    $waveoutEndpointId = [string]$radioOutput.endpoint_id
    if ([string]::IsNullOrWhiteSpace($waveinEndpointId) -or
        [string]::IsNullOrWhiteSpace($waveoutEndpointId)) {
        throw '本机 WinMM 未返回所选 WaveIn/WaveOut 的 endpoint ID；请检查 Windows 音频端点后重试。'
    }
    if ($StatusDirectory) { $statusDirectoryPath = $StatusDirectory }
    else { $statusDirectoryPath = Join-Path $script:packageRoot 'logs' }
    $statusDirectory = Test-StatusDirectory -Path $statusDirectoryPath
    $statusPath = Join-Path $statusDirectory ('bm-bridge-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    $script:statusPath = $statusPath

    Write-Host ''
    $audioSummary = if ($audioPair) { 'USB Audio' } else { '已选择音频输入和输出' }
    $presetSummary = switch ($selectedPreset) {
        'parrot-cn' { '鹦鹉 460997' }
        'parrot-global' { '全球回声 9990' }
        'listen-46001' { '46001 组呼收听' }
        default { '手工 BM 配置' }
    }
    Write-Host ("请确认本次设备：{0} · {1} · {2}" -f $portName, $audioSummary, $presetSummary)
    Write-Host '等待 BM 和电台连接。'
    if ($selectedPreset -eq 'listen-46001') {
        Write-Host '连接后在电台扬声器收听 BM 组呼，按 Q 停止并退出。'
    } else {
        Write-Host '连接后按住手咪讲话；松开后等待 BM 回声。按 Q 停止并退出。'
    }
    Write-Host ("COM: {0} · Radio WaveIn: ID {1} · {2}" -f $portName, $radioInput.id, $radioInput.name)
    Write-Host ("Radio WaveOut: ID {0} · {1}" -f $radioOutput.id, $radioOutput.name)
    if ($ManualPtt) { Write-Host '诊断模式已启用：按 T 开始或结束 BM 上行。' }
    Write-Host ("状态报告：{0}" -f $statusPath)
    Write-Host ''
    $arguments = @('--run', '--port', $portName, '--body-file', $body,
        '--input', [string]$radioInput.id, '--output', [string]$radioOutput.id,
        '--status-file', $statusPath,
        '--expected-wavein-endpoint', $waveinEndpointId,
        '--expected-waveout-endpoint', $waveoutEndpointId)
    if ($selectedPreset -ne 'manual') {
        $arguments += @('--test-preset', $selectedPreset, '--password-file', $passwordPath)
    }
    if ($ManualPtt) { $arguments += '--manual-ptt' }
    $script:nativeInvoked = $true
    & $executable @arguments
    $exitCode = [int]$LASTEXITCODE
    Write-Host "程序已退出，退出码：$exitCode"
    Write-Host "状态报告：$statusPath"
    exit $exitCode
} catch {
    if ($script:nativeInvoked) {
        Write-Host "运行失败：$($_.Exception.Message)" -ForegroundColor Red
        if ($script:statusPath) { Write-Host "请检查状态报告：$($script:statusPath)" }
    } else {
        Write-Host "启动检查失败：$($_.Exception.Message)；请修正后重新启动。" -ForegroundColor Red
    }
    exit 2
}
