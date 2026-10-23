[CmdletBinding()]
param(
    [string]$ProbePath,
    [string]$BodyFile,
    [string]$FixedWav,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
$script:packageRoot = $PSScriptRoot
$script:expectedBodyLength = 100
$script:expectedBodySha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:expectedWavLength = 695836
$script:expectedWavSha256 = '4beaf3d5539084f33ae05ba02112823edb75985d2f9e03668e2bdf28cd75570d'
$script:radioWaveOutName = '扬声器 (2- USB Audio Device)'

function Resolve-LocalFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    } catch {
        throw "$Label 路径无效：$Path"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "找不到$Label：$fullPath"
    }
    return $fullPath
}

function Test-ApprovedAsset {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][long]$ExpectedLength,
        [Parameter(Mandatory=$true)][string]$ExpectedSha256
    )

    $resolved = Resolve-LocalFile -Path $Path -Label $Label
    $item = Get-Item -LiteralPath $resolved
    if ($item.Length -ne $ExpectedLength) {
        throw "$Label 长度不符：需要 $ExpectedLength 字节，当前 $($item.Length) 字节。"
    }
    $actualHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedSha256) {
        throw "$Label SHA-256 与已批准素材不符。"
    }
    return $resolved
}

function Invoke-ProbeCapture {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int]$TimeoutMilliseconds = 10000
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = [string]::Join(' ', $Arguments)
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
        if (-not $process.Start()) { throw '无法启动 native 音频枚举命令。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $killError = $null
            try { $process.Kill() } catch { $killError = $_.Exception.Message }
            if (-not $process.WaitForExit(5000)) {
                if ($killError) {
                    throw "native 音频枚举超时，且无法确认自有枚举子进程退出；终止请求失败：$killError"
                }
                throw 'native 音频枚举超时，且无法确认自有枚举子进程退出。'
            }
            if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
                throw 'native 音频枚举进程已退出，但未能在 5 秒内读完标准流；无法确认枚举子进程已关闭管道。'
            }
            throw "native 音频枚举在 $TimeoutMilliseconds 毫秒内未完成；已确认终止本次枚举进程。"
        }
        if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
            throw 'native 音频枚举进程已退出，但未能在 5 秒内读完标准流；无法确认枚举子进程已关闭管道。'
        }
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout = [string]$stdoutText
            Stderr = [string]$stderrText
        }
    } finally {
        $process.Dispose()
    }
}

function ConvertFrom-AudioEnumeration {
    param([Parameter(Mandatory=$true)][string]$JsonText)

    $text = $JsonText.Trim().TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Contains("`n") -or $text.Contains("`r")) {
        throw 'native 音频枚举必须只输出一行 JSON。'
    }
    try {
        $payload = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        throw "native 音频枚举没有返回有效 JSON：$($_.Exception.Message)"
    }
    if ($null -eq $payload -or $payload.schema_version -ne 1 -or $payload.type -cne 'audio_devices') {
        throw 'native 音频枚举 schema 与版本 1 不符。'
    }

    foreach ($field in @('wave_inputs', 'wave_outputs')) {
        if (-not $payload.PSObject.Properties[$field]) { throw "native 音频枚举缺少 $field。" }
        $seen = @{}
        foreach ($device in @($payload.$field)) {
            if ($null -eq $device -or $null -eq $device.id -or
                $device.id -is [bool] -or -not ($device.id -is [int] -or $device.id -is [long]) -or $device.id -lt 0 -or
                [string]::IsNullOrWhiteSpace([string]$device.name) -or
                $device.pcm_48000_mono_s16_supported -isnot [bool]) {
                throw "native 音频枚举的 $field 含无效设备记录。"
            }
            $idKey = [string]$device.id
            if ($seen.ContainsKey($idKey)) { throw "native 音频枚举的 $field 含重复 ID $idKey。" }
            $seen[$idKey] = $true
        }
    }
    return $payload
}

function Get-AudioEnumeration {
    param([Parameter(Mandatory=$true)][string]$Executable)

    $result = Invoke-ProbeCapture -Executable $Executable -Arguments @('--list-audio-json')
    if ($result.ExitCode -ne 0) {
        $diagnostic = ([string]$result.Stderr).Trim()
        if ($diagnostic) { throw "native 音频枚举失败（退出码 $($result.ExitCode)）：$diagnostic" }
        throw "native 音频枚举失败（退出码 $($result.ExitCode)）。"
    }
    return ConvertFrom-AudioEnumeration -JsonText $result.Stdout
}

function Get-CurrentSerialPorts {
    if ($env:OS -ne 'Windows_NT') { throw '本启动器只支持 Windows COM 设备。' }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DEVICEMAP\SERIALCOMM', $false)
    if ($null -eq $key) { return @() }
    try {
        $ports = @(
            foreach ($valueName in $key.GetValueNames()) {
                $value = [string]$key.GetValue($valueName)
                if ($value -match '^COM[1-9][0-9]*$') { $value.ToUpperInvariant() }
            }
        ) | Sort-Object -Unique { [int]($_ -replace '^COM', '') }
        return @($ports)
    } finally {
        $key.Dispose()
    }
}

function Get-DeviceById {
    param(
        [Parameter(Mandatory=$true)][object[]]$Devices,
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $matches = @($Devices | Where-Object { [int]$_.id -eq $Id })
    if ($matches.Count -ne 1) { throw "$Label ID $Id 不在本次设备枚举中。" }
    if (-not $matches[0].pcm_48000_mono_s16_supported) {
        throw "$Label $($matches[0].name) 不支持 48 kHz、单声道、16 位 PCM。"
    }
    return $matches[0]
}

function New-LocalSessionPlan {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string]$BodyPath,
        [Parameter(Mandatory=$true)][string]$WavPath,
        [Parameter(Mandatory=$true)][string]$Port,
        [Parameter(Mandatory=$true)][int]$RadioInputId,
        [Parameter(Mandatory=$true)][int]$PcOutputId,
        [Parameter(Mandatory=$true)][int]$MicInputId,
        [Parameter(Mandatory=$true)][object]$AudioDevices,
        [Parameter(Mandatory=$true)][string[]]$CurrentPorts,
        [Parameter(Mandatory=$true)][string]$ReportPath
    )

    $probe = Resolve-LocalFile -Path $Executable -Label 'native 核心程序'
    $body = Test-ApprovedAsset -Path $BodyPath -Label 'Y 模板' -ExpectedLength $script:expectedBodyLength -ExpectedSha256 $script:expectedBodySha256
    $wav = Test-ApprovedAsset -Path $WavPath -Label '固定 WAV' -ExpectedLength $script:expectedWavLength -ExpectedSha256 $script:expectedWavSha256
    if ($Port -notmatch '^COM[1-9][0-9]*$' -or @($CurrentPorts | Where-Object { $_ -ieq $Port }).Count -ne 1) {
        throw "所选 COM 端口 $Port 不在本次 Windows 串口列表中。"
    }

    $waveInputs = @($AudioDevices.wave_inputs)
    $waveOutputs = @($AudioDevices.wave_outputs)
    $radioMatches = @($waveOutputs | Where-Object { $_.name -ceq $script:radioWaveOutName })
    if ($radioMatches.Count -ne 1) {
        throw "radio WaveOut 名称 $($script:radioWaveOutName) 必须在当前枚举中恰好出现一次；当前为 $($radioMatches.Count) 次。"
    }
    if (-not $radioMatches[0].pcm_48000_mono_s16_supported) {
        throw '唯一 radio WaveOut 不支持 48 kHz、单声道、16 位 PCM。'
    }
    $radioInput = Get-DeviceById -Devices $waveInputs -Id $RadioInputId -Label 'radio USB WaveIn'
    $pcOutput = Get-DeviceById -Devices $waveOutputs -Id $PcOutputId -Label 'PC WaveOut'
    $micInput = Get-DeviceById -Devices $waveInputs -Id $MicInputId -Label 'PC microphone WaveIn'
    if ($radioInputId -eq $micInputId) {
        throw 'radio USB WaveIn 与 PC 麦克风 WaveIn 不能选择同一设备。'
    }
    if ([int]$pcOutput.id -eq [int]$radioMatches[0].id) {
        throw 'PC WaveOut 不能与唯一 radio WaveOut 共用同一设备 ID。'
    }

    $report = [System.IO.Path]::GetFullPath($ReportPath)
    $arguments = @(
        '--hri-radio-session',
        '--port', $Port.ToUpperInvariant(),
        '--body-file', $body,
        '--fixed-wav', $wav,
        '--radio-input', [string]$radioInput.id,
        '--pc-output', [string]$pcOutput.id,
        '--mic-input', [string]$micInput.id,
        '--report-file', $report,
        '--interactive'
    )
    return [pscustomobject]@{
        ProbePath = $probe
        BodyPath = $body
        FixedWavPath = $wav
        Port = $Port.ToUpperInvariant()
        RadioInput = $radioInput
        PcOutput = $pcOutput
        MicInput = $micInput
        RadioOutput = $radioMatches[0]
        ReportPath = $report
        Arguments = [string[]]$arguments
    }
}

function Read-SerialPortSelection {
    param([Parameter(Mandatory=$true)][string[]]$Ports)
    if ($Ports.Count -eq 0) { throw 'Windows 当前没有可选 COM 端口；没有启动 native 核心。' }
    Write-Host '当前 Windows COM 端口（仅枚举，没有打开）：'
    foreach ($port in $Ports) { Write-Host "  $port" }
    $defaultPort = if (@($Ports | Where-Object { $_ -ieq 'COM5' }).Count -eq 1) { 'COM5' } else { '' }
    while ($true) {
        $prompt = if ($defaultPort) { "HRI COM 端口（输入 COM5 或直接回车确认 [COM5]）" } else { 'HRI COM 端口（请按设备管理器中的当前编号输入）' }
        $inputPort = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($inputPort) -and $defaultPort) { $inputPort = $defaultPort }
        $inputPort = ([string]$inputPort).Trim().ToUpperInvariant()
        if (@($Ports | Where-Object { $_ -ieq $inputPort }).Count -eq 1) { return $inputPort }
        Write-Host '该 COM 端口不在当前枚举中，请重新输入。' -ForegroundColor Yellow
    }
}

function Read-AudioDeviceSelection {
    param(
        [Parameter(Mandatory=$true)][object[]]$Devices,
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$EndpointLabel,
        [int[]]$ExcludeIds = @()
    )

    $choices = @($Devices | Where-Object { $ExcludeIds -notcontains [int]$_.id })
    if ($choices.Count -eq 0) { throw "$Label 当前没有可选择的音频端点。" }
    Write-Host "$Label（从本次枚举中明确输入 ID）："
    foreach ($device in $choices) {
        $format = if ($device.pcm_48000_mono_s16_supported) { '48 kHz / mono / s16 支持' } else { '不支持 48 kHz / mono / s16' }
        Write-Host ("  ID {0}: {1} · {2}" -f $device.id, $device.name, $format)
    }
    while ($true) {
        $text = Read-Host "$EndpointLabel ID（没有默认值）"
        $id = 0
        if ([int]::TryParse([string]$text, [ref]$id)) {
            try { return Get-DeviceById -Devices $choices -Id $id -Label $EndpointLabel }
            catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
        } else {
            Write-Host '请输入上方显示的十进制设备 ID。' -ForegroundColor Yellow
        }
    }
}

function Invoke-ProbeInteractive {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    $priorPreference = $ErrorActionPreference
    $priorConsoleEncoding = [Console]::OutputEncoding
    $priorPowerShellEncoding = $OutputEncoding
    $ErrorActionPreference = 'Continue'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        # native 使用 UTF-8 窄字节输出；只在本次直接调用期间调整 PowerShell 解码。
        [Console]::OutputEncoding = $utf8NoBom
        $OutputEncoding = $utf8NoBom
        & $Executable @Arguments
        return [int]$LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $priorConsoleEncoding
        $OutputEncoding = $priorPowerShellEncoding
        $ErrorActionPreference = $priorPreference
    }
}

function Invoke-NativeSessionPlan {
    param([Parameter(Mandatory=$true)][object]$Plan)
    $script:nativeLaunchAttempted = $true
    return Invoke-ProbeInteractive -Executable $Plan.ProbePath -Arguments $Plan.Arguments
}

function Get-StartFailureMessage {
    param(
        [Parameter(Mandatory=$true)][bool]$NativeMayHaveStarted,
        [Parameter(Mandatory=$true)][string]$Detail,
        [string]$ReportPath
    )

    if ($NativeMayHaveStarted) {
        $reportText = if ($ReportPath) { " Report 路径：$ReportPath。" } else { '' }
        return "native 调用开始后发生错误：$Detail。无法据此确认 native 是否已完整退出；请检查报告和控制台退出状态，再决定是否重试。$reportText"
    }
    return "启动前检查失败：$Detail。没有启动 HRI 会话。"
}

function Start-LocalRadioSession {
    param(
        [string]$ExplicitProbe,
        [string]$ExplicitBody,
        [string]$ExplicitWav
    )

    $probe = if ($ExplicitProbe) { $ExplicitProbe } else { Join-Path $script:packageRoot 'wirex_probe.exe' }
    $body = if ($ExplicitBody) { $ExplicitBody } else { Join-Path $script:packageRoot 'private\device-y.bin' }
    $wav = if ($ExplicitWav) { $ExplicitWav } else { Join-Path $script:packageRoot 'assets\voice-test.wav' }

    $script:nativeLaunchAttempted = $false
    $plan = $null
    try {
        $probe = Resolve-LocalFile -Path $probe -Label 'native 核心程序'
        $body = Test-ApprovedAsset -Path $body -Label 'Y 模板' -ExpectedLength $script:expectedBodyLength -ExpectedSha256 $script:expectedBodySha256
        $wav = Test-ApprovedAsset -Path $wav -Label '固定 WAV' -ExpectedLength $script:expectedWavLength -ExpectedSha256 $script:expectedWavSha256
        $ports = @(Get-CurrentSerialPorts)
        if ($ports.Count -eq 0) { throw 'Windows 当前没有可选 COM 端口；没有启动 native 核心。' }
        $devices = Get-AudioEnumeration -Executable $probe
        $radioOutputs = @($devices.wave_outputs | Where-Object { $_.name -ceq $script:radioWaveOutName })
        if ($radioOutputs.Count -ne 1) {
            throw "radio WaveOut 名称 $($script:radioWaveOutName) 必须在当前枚举中恰好出现一次；当前为 $($radioOutputs.Count) 次。"
        }
        if (-not $radioOutputs[0].pcm_48000_mono_s16_supported) {
            throw '唯一 radio WaveOut 不支持 48 kHz、单声道、16 位 PCM。'
        }
        $port = Read-SerialPortSelection -Ports $ports
        Write-Host "唯一 radio WaveOut：ID $($radioOutputs[0].id) · $($radioOutputs[0].name)"
        $radioInput = Read-AudioDeviceSelection -Devices @($devices.wave_inputs) -Label 'WaveIn' -EndpointLabel 'radio USB WaveIn'
        Write-Host "已选 radio USB WaveIn：ID $($radioInput.id) · $($radioInput.name)"
        $pcOutput = Read-AudioDeviceSelection -Devices @($devices.wave_outputs) -Label 'WaveOut' -EndpointLabel 'PC WaveOut' -ExcludeIds @([int]$radioOutputs[0].id)
        $micInput = Read-AudioDeviceSelection -Devices @($devices.wave_inputs) -Label 'WaveIn' -EndpointLabel 'PC 麦克风 WaveIn' -ExcludeIds @([int]$radioInput.id)
        $reportDirectory = Join-Path $script:packageRoot 'logs'
        try {
            New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
            $reportProbe = Join-Path $reportDirectory ('.write-test-' + [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($reportProbe, 'ok', (New-Object System.Text.UTF8Encoding($false)))
            Remove-Item -LiteralPath $reportProbe -Force
        } catch {
            throw "无法在本包 logs 目录写入 native 报告；没有启动核心：$($_.Exception.Message)"
        }
        $reportPath = Join-Path $reportDirectory ('radio-session-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $plan = New-LocalSessionPlan -Executable $probe -BodyPath $body -WavPath $wav -Port $port `
            -RadioInputId ([int]$radioInput.id) -PcOutputId ([int]$pcOutput.id) -MicInputId ([int]$micInput.id) `
            -AudioDevices $devices -CurrentPorts $ports -ReportPath $reportPath

        Write-Host ''
        Write-Host '启动前请逐项确认：'
        Write-Host '  · 官方 WIRES-X 程序已关闭。'
        Write-Host '  · FTX-1 已通过 USB 直连，屏幕显示 WIRES-X HRI，HRI 为 ON、Node Mode 为 DIRECT。'
        Write-Host '  · 本地 CAT 端口不使用；本测试不连接 BrandMeister，也不测试 RF。'
        Write-Host '  · radio USB WaveIn、PC WaveOut、PC 麦克风 WaveIn 和 COM 均为本次枚举后明确选择。'
        Write-Host '  · 下行 F/M 操作前已松开手咪 PTT。'
        Write-Host '  · native 收尾后会显示结果；请人工确认电台扬声器是否有声、界面是否恢复并反馈。'
        Write-Host ''
        Write-Host ("COM: {0}" -f $plan.Port)
        Write-Host ("radio WaveIn: ID {0} · {1}" -f $plan.RadioInput.id, $plan.RadioInput.name)
        Write-Host ("PC WaveOut: ID {0} · {1}" -f $plan.PcOutput.id, $plan.PcOutput.name)
        Write-Host ("PC 麦克风 WaveIn: ID {0} · {1}" -f $plan.MicInput.id, $plan.MicInput.name)
        Write-Host ("radio WaveOut（native 按唯一完整名称重新匹配）: ID {0} · {1}" -f $plan.RadioOutput.id, $plan.RadioOutput.name)
        Write-Host 'native 交互：F 固定 WAV 下行；M 从 PC 麦克风采集最多 8 秒后发送；C 取消当前操作；Q 收尾退出。'
        $confirmation = Read-Host '输入 START 才启动本地会话；其它输入取消'
        if ($confirmation -cne 'START') {
            Write-Host '未输入 START；没有打开 COM 或音频流。'
            return 0
        }

        Write-Host ''
        Write-Host '正在把会话交给 native 核心；以下交互由 native 直接读取。'
        $exitCode = Invoke-NativeSessionPlan -Plan $plan
        if ($exitCode -eq 0) {
            Write-Host 'native 会话退出码为 0。退出码不代表实际声音或射频效果，请按上方提示人工确认并反馈。'
        } else {
            Write-Host "native 会话以退出码 $exitCode 结束。请保留报告并反馈可见的核心错误。" -ForegroundColor Yellow
        }
        Write-Host "会话报告：$($plan.ReportPath)"
        return $exitCode
    } catch {
        $reportForError = if ($null -ne $plan) { $plan.ReportPath } else { '' }
        $failureMessage = Get-StartFailureMessage -NativeMayHaveStarted $script:nativeLaunchAttempted `
            -Detail $_.Exception.Message -ReportPath $reportForError
        Write-Host $failureMessage -ForegroundColor Red
        if (-not $script:nativeLaunchAttempted) { Write-Host '修正显示的问题后再重试。' }
        return 2
    }
}

if (-not $LibraryOnly) {
    exit (Start-LocalRadioSession -ExplicitProbe $ProbePath -ExplicitBody $BodyFile -ExplicitWav $FixedWav)
}
