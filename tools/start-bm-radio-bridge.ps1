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
            ParentInstanceId = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent')
            ContainerId = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ContainerId')
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
    if (-not $Port -and $presentHri.Count -eq 1) {
        $device = $presentHri[0]
        Write-Host ("PnP 唯一识别到 YAESU HRI USB 接口：{0} · VID_26AA&PID_{1}" -f $device.PortName, $device.ProductId)
        Write-Host ("  实例：{0}" -f $device.InstanceId)
        Write-Host ("  父实例：{0}；容器：{1}" -f $device.ParentInstanceId, $device.ContainerId)
        Write-Host '  此次 COM 选择只读取 PnP 和串口登记信息，没有打开串口。'
        return $device.PortName
    }

    if (-not $Port) {
        if ($presentHri.Count -gt 1) {
            Write-Host 'PnP 找到多个当前 YAESU HRI USB 接口；请选择其中一个实例：'
            foreach ($device in $presentHri) {
                Write-Host ("  {0} · VID_26AA&PID_{1} · {2}" -f $device.PortName, $device.ProductId, $device.InstanceId)
                Write-Host ("    父实例：{0}；容器：{1}" -f $device.ParentInstanceId, $device.ContainerId)
            }
        } else {
            Write-Host '没有唯一的 PnP YAESU HRI USB 接口；当前 COM 只作手工选择：'
            foreach ($item in $current) {
                $matches = @($HriDevices | Where-Object { $_.PortName -ieq $item })
                if ($matches.Count -eq 1) {
                    Write-Host ("  {0} · VID_26AA&PID_{1} · {2}" -f $item, $matches[0].ProductId, $matches[0].InstanceId)
                } else {
                    Write-Host "  $item · 未由 PnP 确认为 HRI 接口"
                }
            }
        }
    }
    $restrictToHri = (-not $Port -and $presentHri.Count -gt 1)
    while ($true) {
        $selected = if ($Port) { $Port } else { Read-Host '输入本次 HRI COM 端口；选择只作人工确认，不会扫描或打开候选端口' }
        $selected = ([string]$selected).Trim().ToUpperInvariant()
        $isCurrent = @($current | Where-Object { $_ -ieq $selected }).Count -eq 1
        $isHriCandidate = @($presentHri | Where-Object { $_.PortName -ieq $selected }).Count -eq 1
        if ($isCurrent -and (-not $restrictToHri -or $isHriCandidate)) {
            $selectedDevice = @($presentHri | Where-Object { $_.PortName -ieq $selected })
            if ($selectedDevice.Count -eq 1) {
                Write-Host ("已按人工选择 {0}：{1}" -f $selected, $selectedDevice[0].InstanceId)
            } else {
                Write-Host "已按人工选择 $selected；PnP 未确认该端口属于 YAESU HRI。" -ForegroundColor Yellow
            }
            return $selected
        }
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
        $text = if ($WaveIn) { $WaveIn } else { Read-Host '输入本次枚举得到的 Radio WaveIn ID' }
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($Devices | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1 -and $matches[0].pcm_48000_mono_s16_supported) { return $matches[0] }
        }
        Write-Host 'ID 无效或该 WaveIn 不支持 48 kHz、单声道、16 位 PCM。' -ForegroundColor Yellow
        $WaveIn = ''
    }
}

function Read-WaveOutSelection {
    param([Parameter(Mandatory=$true)][object[]]$Devices)
    $available = @($Devices | Where-Object { $_.pcm_48000_mono_s16_supported })
    if ($available.Count -eq 0) { throw '没有支持 48 kHz、单声道、16 位 PCM 的 WaveOut 设备。' }
    Write-Host '选择 Radio WaveOut：'
    foreach ($device in $Devices) {
        $support = if ($device.pcm_48000_mono_s16_supported) { '48 kHz PCM 可用' } else { '不支持目标 PCM' }
        Write-Host ("  ID {0}: {1} · {2}" -f $device.id, $device.name, $support)
    }
    while ($true) {
        $text = if ($WaveOut) { $WaveOut } else { Read-Host '输入本次枚举得到的 Radio WaveOut ID' }
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            $matches = @($available | Where-Object { [int]$_.id -eq $id })
            if ($matches.Count -eq 1) { return $matches[0] }
        }
        Write-Host 'ID 无效或该 WaveOut 不支持 48 kHz、单声道、16 位 PCM。' -ForegroundColor Yellow
        $WaveOut = ''
    }
}

function Get-NearestNonRootUsbHub {
    param([Parameter(Mandatory=$true)][string]$InstanceId)
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return $null }
    $current = $InstanceId
    $seen = @{}
    for ($depth = 0; $depth -lt 12 -and $current -and -not $seen.ContainsKey($current); $depth++) {
        $seen[$current] = $true
        $parent = [string](Get-PnpPropertyData -InstanceId $current -KeyName 'DEVPKEY_Device_Parent')
        if (-not $parent) { return $null }
        if ($parent -match '(?i)^USB\\ROOT_HUB') { return $null }
        $compatibleIds = @(Get-PnpPropertyData -InstanceId $parent -KeyName 'DEVPKEY_Device_CompatibleIds' |
            ForEach-Object { [string]$_ })
        if (@($compatibleIds | Where-Object { $_ -match '(?i)^USB\\USB(20|30)_HUB$' }).Count -gt 0) {
            $locations = @(Get-PnpPropertyData -InstanceId $parent -KeyName 'DEVPKEY_Device_LocationPaths' |
                ForEach-Object { [string]$_ })
            return [pscustomobject]@{ InstanceId = $parent; LocationPaths = $locations }
        }
        $current = $parent
    }
    return $null
}

function Test-PnpDescendantOf {
    param([Parameter(Mandatory=$true)][string]$InstanceId, [Parameter(Mandatory=$true)][string]$AncestorInstanceId)
    $current = $InstanceId
    $seen = @{}
    for ($depth = 0; $depth -lt 12 -and $current -and -not $seen.ContainsKey($current); $depth++) {
        $seen[$current] = $true
        $parent = [string](Get-PnpPropertyData -InstanceId $current -KeyName 'DEVPKEY_Device_Parent')
        if (-not $parent) { return $false }
        if ($parent -ieq $AncestorInstanceId) { return $true }
        $current = $parent
    }
    return $false
}

function Find-ConfirmedRadioAudioPair {
    param([Parameter(Mandatory=$true)][object]$RadioSerial, [Parameter(Mandatory=$true)][object]$Devices)
    if (-not $RadioSerial.IsHri -or -not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return $null }
    $audioAdapters = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '(?i)^USB\\VID_0D8C&PID_0016\\'
    })
    if ($audioAdapters.Count -ne 1) { return $null }
    $audioAdapter = $audioAdapters[0]
    $radioHub = Get-NearestNonRootUsbHub -InstanceId $RadioSerial.InstanceId
    $audioHub = Get-NearestNonRootUsbHub -InstanceId $audioAdapter.InstanceId
    if ($null -eq $radioHub -or $null -eq $audioHub -or
        $radioHub.InstanceId -ine $audioHub.InstanceId) { return $null }

    $audioContainerId = [string](Get-PnpPropertyData -InstanceId $audioAdapter.InstanceId -KeyName 'DEVPKEY_Device_ContainerId')
    if ([string]::IsNullOrWhiteSpace($audioContainerId)) { return $null }
    $inputMatches = @()
    $outputMatches = @()
    foreach ($wave in @($Devices.wave_inputs)) {
        if ([string]::IsNullOrWhiteSpace([string]$wave.endpoint_id)) { continue }
        $instanceId = 'SWD\MMDEVAPI\' + [string]$wave.endpoint_id
        $endpoint = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
        if ($null -eq $endpoint -or $endpoint.Class -cne 'AudioEndpoint') { continue }
        $containerId = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ContainerId')
        if ($containerId -ine $audioContainerId -or
            -not (Test-PnpDescendantOf -InstanceId $instanceId -AncestorInstanceId $audioAdapter.InstanceId)) { continue }
        $inputMatches += [pscustomobject]@{ Wave = $wave; Endpoint = $endpoint }
    }
    foreach ($wave in @($Devices.wave_outputs)) {
        if ([string]::IsNullOrWhiteSpace([string]$wave.endpoint_id)) { continue }
        $instanceId = 'SWD\MMDEVAPI\' + [string]$wave.endpoint_id
        $endpoint = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
        if ($null -eq $endpoint -or $endpoint.Class -cne 'AudioEndpoint') { continue }
        $containerId = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ContainerId')
        if ($containerId -ine $audioContainerId -or
            -not (Test-PnpDescendantOf -InstanceId $instanceId -AncestorInstanceId $audioAdapter.InstanceId)) { continue }
        $outputMatches += [pscustomobject]@{ Wave = $wave; Endpoint = $endpoint }
    }
    if ($inputMatches.Count -ne 1 -or $outputMatches.Count -ne 1 -or
        -not $inputMatches[0].Wave.pcm_48000_mono_s16_supported -or
        -not $outputMatches[0].Wave.pcm_48000_mono_s16_supported) { return $null }
    return [pscustomobject]@{
        Input = $inputMatches[0].Wave
        Output = $outputMatches[0].Wave
        AudioAdapter = $audioAdapter
        UsbHub = $radioHub
        Endpoints = @($inputMatches[0].Endpoint, $outputMatches[0].Endpoint)
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
    $hriDevices = @(Get-HriSerialDevices)
    $portName = Read-PortSelection -Ports $serialPorts -HriDevices $hriDevices
    $radioSerialMatches = @($hriDevices | Where-Object { $_.IsHri -and $_.PortName -ieq $portName })
    $radioSerial = if ($radioSerialMatches.Count -eq 1) { $radioSerialMatches[0] } else { $null }

    $audioPair = $null
    if ($radioSerial) { $audioPair = Find-ConfirmedRadioAudioPair -RadioSerial $radioSerial -Devices $devices }
    if ($WaveIn -and -not $WaveOut) { throw '手工指定音频设备时必须同时传入 -WaveIn 和 -WaveOut。' }
    if ($WaveOut -and -not $WaveIn) { throw '手工指定音频设备时必须同时传入 -WaveIn 和 -WaveOut。' }
    if ($WaveIn -or $WaveOut) { $audioPair = $null }
    if ($audioPair) {
        if (-not $audioPair.Input.pcm_48000_mono_s16_supported -or
            -not $audioPair.Output.pcm_48000_mono_s16_supported) {
            throw '与 HRI 同一 PnP 容器关联的 WaveIn/WaveOut 不支持目标 PCM。'
        }
        $radioInput = $audioPair.Input
        $radioOutput = $audioPair.Output
        Write-Host 'WaveIn、WaveOut 与唯一 USB Audio VID_0D8C&PID_0016 设备相符，并与 YAESU HRI 共用最近非根 USB Hub；已按 endpoint ID 关联到 WinMM ID。'
        Write-Host ("  USB 音频实例：{0}" -f $audioPair.AudioAdapter.InstanceId)
        Write-Host ("  共用 Hub：{0}" -f $audioPair.UsbHub.InstanceId)
        foreach ($endpoint in $audioPair.Endpoints) {
            Write-Host ("  音频端点：{0} · 实例 {1}" -f $endpoint.FriendlyName, $endpoint.InstanceId)
        }
    } else {
        $audioEndpoints = @(Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
            $instanceId = [string]$_.InstanceId
            [pscustomobject]@{
                InstanceId = $instanceId
                FriendlyName = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_FriendlyName')
                ParentInstanceId = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent')
                ContainerId = [string](Get-PnpPropertyData -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ContainerId')
            }
        })
        Write-Host 'Windows 未唯一确认 USB Audio VID/PID、最近非根 Hub 和 WinMM endpoint ID 的对应关系；需要手工选输入和输出。' -ForegroundColor Yellow
        if ($audioEndpoints.Count -gt 0) {
            Write-Host '当前 Windows 音频端点 PnP 信息（名称仅用于显示）：'
            foreach ($endpoint in $audioEndpoints) {
                Write-Host ("  {0} · 实例 {1} · 父实例 {2} · 容器 {3}" -f $endpoint.FriendlyName, $endpoint.InstanceId, $endpoint.ParentInstanceId, $endpoint.ContainerId)
            }
        } else {
            Write-Host '当前无法读取 Windows AudioEndpoint PnP 信息。'
        }
        Write-Host '请手工选择连接到 FTX-1 的成对端点；程序不会按本地化名称或第一个 USB 设备猜选。'
        $radioInput = Read-WaveInSelection -Devices @($devices.wave_inputs)
        $radioOutput = Read-WaveOutSelection -Devices @($devices.wave_outputs)
    }
    $waveinEndpointId = [string]$radioInput.endpoint_id
    $waveoutEndpointId = [string]$radioOutput.endpoint_id
    if ([string]::IsNullOrWhiteSpace($waveinEndpointId) -or
        [string]::IsNullOrWhiteSpace($waveoutEndpointId)) {
        throw '本机 WinMM 无法为所选 WaveIn/WaveOut 返回稳定 endpoint ID；不能在 native 打开前确认端点身份，请先恢复 endpoint ID 查询能力。'
    }
    if ($StatusDirectory) { $statusDirectoryPath = $StatusDirectory }
    else { $statusDirectoryPath = Join-Path $script:packageRoot 'logs' }
    $statusDirectory = Test-StatusDirectory -Path $statusDirectoryPath
    $statusPath = Join-Path $statusDirectory ('bm-bridge-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    $script:statusPath = $statusPath

    Write-Host ''
    Write-Host '启动前已核对：Y 素材长度与 SHA-256、日志目录写权限、当前 PnP/COM 身份和所选端点的 48 kHz 能力。'
    Write-Host '本机 DIRECT 没有声明射频频率或坐标；BM 配置使用数值 0 表示未配置坐标。'
    if ($selectedPreset -eq 'manual') {
        Write-Host '手工入口会在可见控制台逐项读取 BM 配置，并隐藏输入密码。'
    } else {
        Write-Host "本次预设：$selectedPreset；身份、Master、端口、时隙、色码和目标已固定。"
        Write-Host 'native 从本机私有明文密码文件读取凭据；文件内容不会传入命令行或日志。'
    }
    Write-Host '无需输入 START；完成上述选择后 native 会在当前前台进程中打开 COM、WinMM 和 BM UDP 并进入待机。'
    if ($selectedPreset -eq 'listen-46001') {
        Write-Host '46001 严格仅接收；native 拒绝 T，且不会产生 LC 或 DMRD 上行数据报。'
    } elseif ($selectedPreset -eq 'manual') {
        Write-Host '手工入口保留原 BM 参数输入。默认按 ready 后有效手咪 PTT 边沿发送；诊断时可显式传入 -ManualPtt 改用键盘 T。'
    } else {
        Write-Host '默认 ready 后按有效手咪 PTT 边沿开始/结束上行；键盘 T 与音频噪声不会发起上行。'
    }
    Write-Host '本次不连接 PC monitor，也不发送 RF/PTT 控制命令。'
    Write-Host ("COM: {0} · Radio WaveIn: ID {1} · {2}" -f $portName, $radioInput.id, $radioInput.name)
    Write-Host ("Radio WaveOut: ID {0} · {1}" -f $radioOutput.id, $radioOutput.name)
    Write-Host ("WinMM endpoint ID：WaveIn {0}；WaveOut {1}" -f $waveinEndpointId, $waveoutEndpointId)
    if (-not $audioPair) { Write-Host '所选音频端点与电台的物理关系由操作者确认；PnP 没有唯一证明该关系。' -ForegroundColor Yellow }
    if ($ManualPtt) { Write-Host '诊断模式已启用：键盘 T 可显式请求 BM 上行；手咪 PTT 自动边沿被此诊断选项替代。' -ForegroundColor Yellow }
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
