$ErrorActionPreference = 'Stop'
$launcherPath = Join-Path $PSScriptRoot 'start-local-radio-session.ps1'
. $launcherPath -LibraryOnly

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    Assert-True $thrown $Message
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$tempRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ('wirex-local-session-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $tempRoot.StartsWith($tempBase + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "测试临时目录越出系统临时目录：$tempRoot"
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $script:fakeProbePath = Join-Path $tempRoot 'fakeprobe.ps1'
    $script:fakeNativeScriptPath = Join-Path $tempRoot 'fake-native.ps1'
    $script:fakeNativePath = Join-Path $tempRoot 'fake-native.cmd'
    $script:fakeThrowNativePath = Join-Path $tempRoot 'fake-native-throw.ps1'
    $script:fakeArgumentPath = Join-Path $tempRoot 'captured-arguments.txt'
    $script:fakeEnumArgumentPath = Join-Path $tempRoot 'captured-enum-arguments.txt'
    $script:fakeJson = @'
{"schema_version":1,"type":"audio_devices","wave_inputs":[{"id":3,"name":"Microphone (USB Radio)","pcm_48000_mono_s16_supported":true},{"id":7,"name":"Microphone (PC Headset)","pcm_48000_mono_s16_supported":true},{"id":8,"name":"Unsupported input","pcm_48000_mono_s16_supported":false}],"wave_outputs":[{"id":2,"name":"扬声器 (2- USB Audio Device)","pcm_48000_mono_s16_supported":true},{"id":6,"name":"Speakers (PC Headset)","pcm_48000_mono_s16_supported":true},{"id":9,"name":"Unsupported output","pcm_48000_mono_s16_supported":false}]}
'@
    function Invoke-ProbeCapture {
        param([string]$Executable, [string[]]$Arguments, [int]$TimeoutMilliseconds = 10000)
        $lines = @(& $Executable @Arguments)
        $exitCode = [int]$LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Stdout = [string]::Join([Environment]::NewLine, [string[]]$lines); Stderr = '' }
    }

    @'
if ($args.Count -eq 1 -and $args[0] -ceq '--list-audio-json') {
    [System.IO.File]::WriteAllLines($env:WIREX_LOCAL_FAKE_ENUM_ARGS, [string[]]$args, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output $env:WIREX_LOCAL_FAKE_JSON
    $global:LASTEXITCODE = [int]$env:WIREX_LOCAL_FAKE_ENUM_EXIT
    return
}
[System.IO.File]::WriteAllLines($env:WIREX_LOCAL_FAKE_ARGS, [string[]]$args, (New-Object System.Text.UTF8Encoding($false)))
$global:LASTEXITCODE = [int]$env:WIREX_LOCAL_FAKE_EXIT
return
'@ | Set-Content -LiteralPath $script:fakeProbePath -Encoding UTF8
    $env:WIREX_LOCAL_FAKE_ARGS = $script:fakeArgumentPath
    $env:WIREX_LOCAL_FAKE_ENUM_ARGS = $script:fakeEnumArgumentPath
    $env:WIREX_LOCAL_FAKE_JSON = $script:fakeJson
    $env:WIREX_LOCAL_FAKE_ENUM_EXIT = '0'
    $env:WIREX_LOCAL_FAKE_EXIT = '23'

    $devices = Get-AudioEnumeration -Executable $script:fakeProbePath
    $enumArguments = @(Get-Content -LiteralPath $script:fakeEnumArgumentPath -Encoding UTF8)
    Assert-True ([string]::Join(',', [string[]]$enumArguments) -ceq '--list-audio-json') '设备枚举没有调用规定的 JSON 命令。'
    Assert-True ($devices.wave_inputs.Count -eq 3 -and $devices.wave_outputs.Count -eq 3) 'fakeprobe 的当前 WaveIn/WaveOut 枚举没有保留名称、ID 和格式。'

    $env:WIREX_LOCAL_FAKE_ENUM_EXIT = '9'
    Assert-Throws { Get-AudioEnumeration -Executable $script:fakeProbePath | Out-Null } 'fakeprobe 枚举退出失败时没有拒绝启动。'
    $env:WIREX_LOCAL_FAKE_ENUM_EXIT = '0'
    $env:WIREX_LOCAL_FAKE_JSON = '{"schema_version":1,"type":"wrong"}'
    Assert-Throws { Get-AudioEnumeration -Executable $script:fakeProbePath | Out-Null } '错误音频 schema 没有拒绝启动。'
    $env:WIREX_LOCAL_FAKE_JSON = $script:fakeJson

    $appRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $bodyPath = Join-Path $appRoot 'build\local-hri-downlink-0304eff\private\device-y.bin'
    $wavPath = Join-Path $appRoot 'build\local-hri-downlink-0304eff\assets\voice-test.wav'
    $reportPath = Join-Path $tempRoot 'logs\session.json'
    $plan = New-LocalSessionPlan -Executable $script:fakeProbePath -BodyPath $bodyPath -WavPath $wavPath `
        -Port 'COM5' -RadioInputId 3 -PcOutputId 6 -MicInputId 7 -AudioDevices $devices `
        -CurrentPorts @('COM5', 'COM11') -ReportPath $reportPath

    $expected = @(
        '--hri-radio-session', '--port', 'COM5', '--body-file', [System.IO.Path]::GetFullPath($bodyPath),
        '--fixed-wav', [System.IO.Path]::GetFullPath($wavPath), '--radio-input', '3', '--pc-output', '6',
        '--mic-input', '7', '--report-file', [System.IO.Path]::GetFullPath($reportPath), '--interactive'
    )
    $plannedText = [string]::Join('|', [string[]]$plan.Arguments)
    $expectedText = [string]::Join('|', [string[]]$expected)
    Assert-True ($plannedText -ceq $expectedText) 'native 启动参数顺序或设备 ID 不符。'
    Assert-True ($plan.RadioInput.name -ceq 'Microphone (USB Radio)' -and $plan.PcOutput.name -ceq 'Speakers (PC Headset)' -and $plan.MicInput.name -ceq 'Microphone (PC Headset)') '命令计划没有保留当前明确选择的设备名称。'
    Assert-True ($plan.RadioOutput.id -eq 2 -and -not ($plan.Arguments -contains '--radio-output')) '启动器必须验证 radio WaveOut 唯一名称，但不能固定传入其数字 ID。'

    @'
[System.IO.File]::WriteAllLines($env:WIREX_LOCAL_FAKE_ARGS, [string[]]$args, (New-Object System.Text.UTF8Encoding($false)))
$message = [System.Text.Encoding]::UTF8.GetBytes("fake native 本地中文提示`r`n")
$stream = [Console]::OpenStandardError()
$stream.Write($message, 0, $message.Length)
$stream.Flush()
exit 23
'@ | Set-Content -LiteralPath $script:fakeNativeScriptPath -Encoding UTF8
    @'
[System.IO.File]::WriteAllLines($env:WIREX_LOCAL_FAKE_ARGS, [string[]]$args, (New-Object System.Text.UTF8Encoding($false)))
throw 'fake native 已启动后故意抛出异常。'
'@ | Set-Content -LiteralPath $script:fakeThrowNativePath -Encoding UTF8
    $fakeCmd = "@echo off`r`nsetlocal`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-native.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($script:fakeNativePath, $fakeCmd, [System.Text.Encoding]::ASCII)
    if (Test-Path -LiteralPath $script:fakeArgumentPath) { Remove-Item -LiteralPath $script:fakeArgumentPath -Force }
    $priorConsoleEncoding = [Console]::OutputEncoding.WebName
    $priorPowerShellEncoding = $OutputEncoding.WebName
    $fakeOutput = @(& { Invoke-ProbeInteractive -Executable $script:fakeNativePath -Arguments $plan.Arguments } 2>&1)
    Assert-True ($fakeOutput -contains 23) 'fake native 的交互退出码没有原样传回。'
    $capturedOutputText = [string]::Join([Environment]::NewLine, [string[]]@($fakeOutput | ForEach-Object { [string]$_ }))
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        Assert-True ($capturedOutputText.Contains('fake native 本地中文提示')) "Windows PowerShell 5.1 没有正确显示 UTF-8 native 中文 stderr：$capturedOutputText"
    }
    Assert-True ([Console]::OutputEncoding.WebName -ceq $priorConsoleEncoding -and $OutputEncoding.WebName -ceq $priorPowerShellEncoding) 'native 调用后没有恢复 PowerShell 编码设置。'
    $captured = @(Get-Content -LiteralPath $script:fakeArgumentPath -Encoding UTF8)
    $capturedText = [string]::Join('|', [string[]]$captured)
    Assert-True ($capturedText -ceq $expectedText) '启动器没有把最终参数直接交给 fakeprobe。'

    # 启动器交出控制权后出错时，应报告运行异常，不能误称 native 没有启动。
    Set-Item Function:Get-CurrentSerialPorts -Value { return @('COM5') }
    Set-Item Function:Get-AudioEnumeration -Value {
        return ConvertFrom-AudioEnumeration -JsonText $script:fakeJson
    }
    Set-Item Function:Read-SerialPortSelection -Value {
        param([string[]]$Ports)
        return 'COM5'
    }
    Set-Item Function:Read-AudioDeviceSelection -Value {
        param([object[]]$Devices, [string]$Label, [string]$EndpointLabel, [int[]]$ExcludeIds = @())
        $wantedId = switch -Exact ($EndpointLabel) {
            'radio USB WaveIn' { 3 }
            'PC WaveOut' { 6 }
            'PC 麦克风 WaveIn' { 7 }
        }
        return ($Devices | Where-Object { [int]$_.id -eq $wantedId } | Select-Object -First 1)
    }
    Set-Item Function:Read-Host -Value { param([string]$Prompt) return 'START' }
    $priorPackageRoot = $script:packageRoot
    $script:packageRoot = $tempRoot
    try {
        $startedFailureOutput = @(& {
            Start-LocalRadioSession -ExplicitProbe $script:fakeThrowNativePath -ExplicitBody $bodyPath -ExplicitWav $wavPath
        } 6>&1)
    } finally {
        $script:packageRoot = $priorPackageRoot
    }
    $startedFailureLines = @(
        $startedFailureOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData }
            else { [string]$_ }
        }
    )
    $startedFailureText = [string]::Join([Environment]::NewLine, [string[]]$startedFailureLines)
    $startedFailureCodes = @($startedFailureOutput | Where-Object { $_ -is [int] })
    Assert-True ($startedFailureCodes.Count -eq 1 -and $startedFailureCodes[0] -eq 2) "native 启动后异常没有返回启动器错误码：$($startedFailureCodes -join ',')"
    Assert-True ($startedFailureText.Contains('native 调用开始后发生错误') -and $startedFailureText.Contains('无法据此确认 native 是否已完整退出')) 'native 启动后异常没有报告为运行期不确定状态。'
    Assert-True ($startedFailureText.Contains('Report 路径') -and $startedFailureText.Contains('radio-session-') -and $startedFailureText.Contains('fake native 已启动后故意抛出异常')) "运行期错误没有展示报告路径或 native 诊断：$startedFailureText"
    Assert-True (-not $startedFailureText.Contains('没有启动 HRI 会话')) 'native 已启动后仍错误地声称没有启动 HRI 会话。'
    $preflightMessage = Get-StartFailureMessage -NativeMayHaveStarted $false -Detail 'fake 预检错误'
    Assert-True ($preflightMessage.Contains('没有启动 HRI 会话') -and -not $preflightMessage.Contains('native 调用开始后')) '启动前失败没有清楚报告 native 尚未启动。'
    $startedCaptured = @(Get-Content -LiteralPath $script:fakeArgumentPath -Encoding UTF8)
    $startedExpected = @($expected)
    $startedExpected[14] = $startedCaptured[14]
    Assert-True ([string]::Join('|', [string[]]$startedCaptured) -ceq [string]::Join('|', [string[]]$startedExpected)) '启动后异常用例没有先把完整参数交给 fake native。'
    Assert-True (([System.IO.Path]::GetDirectoryName($startedCaptured[14]) -ieq (Join-Path $tempRoot 'logs')) -and ([System.IO.Path]::GetFileName($startedCaptured[14]) -like 'radio-session-*.json')) 'fake native 没有收到本包 logs 目录中的会话报告路径。'

    $before = [System.IO.File]::ReadAllText($script:fakeArgumentPath, [System.Text.Encoding]::UTF8)
    Assert-Throws {
        New-LocalSessionPlan -Executable $script:fakeProbePath -BodyPath $bodyPath -WavPath $wavPath `
            -Port 'COM5' -RadioInputId 8 -PcOutputId 6 -MicInputId 7 -AudioDevices $devices `
            -CurrentPorts @('COM5') -ReportPath $reportPath | Out-Null
    } '不支持格式的设备 ID 没有被阻止。'
    Assert-True ([System.IO.File]::ReadAllText($script:fakeArgumentPath, [System.Text.Encoding]::UTF8) -ceq $before) '格式预检失败后仍调用了 fakeprobe 会话入口。'

    $duplicate = ConvertFrom-Json -InputObject $script:fakeJson
    $duplicate.wave_outputs += [pscustomobject]@{ id = 12; name = '扬声器 (2- USB Audio Device)'; pcm_48000_mono_s16_supported = $true }
    Assert-Throws {
        New-LocalSessionPlan -Executable $script:fakeProbePath -BodyPath $bodyPath -WavPath $wavPath `
            -Port 'COM5' -RadioInputId 3 -PcOutputId 6 -MicInputId 7 -AudioDevices $duplicate `
            -CurrentPorts @('COM5') -ReportPath $reportPath | Out-Null
    } 'radio WaveOut 名称重复时没有阻止会话。'

    Assert-Throws {
        New-LocalSessionPlan -Executable $script:fakeProbePath -BodyPath $bodyPath -WavPath $wavPath `
            -Port 'COM5' -RadioInputId 3 -PcOutputId 6 -MicInputId 3 -AudioDevices $devices `
            -CurrentPorts @('COM5') -ReportPath $reportPath | Out-Null
    } '同一 WaveIn ID 同时作为 radio 输入和 PC 麦克风时没有阻止会话。'

    $badFormat = $script:fakeJson.Replace('"id":6,"name":"Speakers (PC Headset)","pcm_48000_mono_s16_supported":true', '"id":6,"name":"Speakers (PC Headset)","pcm_48000_mono_s16_supported":false')
    $badOutput = ConvertFrom-AudioEnumeration -JsonText $badFormat
    Assert-Throws {
        New-LocalSessionPlan -Executable $script:fakeProbePath -BodyPath $bodyPath -WavPath $wavPath `
            -Port 'COM5' -RadioInputId 3 -PcOutputId 6 -MicInputId 7 -AudioDevices $badOutput `
            -CurrentPorts @('COM5') -ReportPath $reportPath | Out-Null
    } 'PC WaveOut 不支持要求格式时没有阻止会话。'

    Assert-Throws {
        New-LocalSessionPlan -Executable $script:fakeProbePath -BodyPath $bodyPath -WavPath $wavPath `
            -Port 'COM8' -RadioInputId 3 -PcOutputId 6 -MicInputId 7 -AudioDevices $devices `
            -CurrentPorts @('COM5') -ReportPath $reportPath | Out-Null
    } '不存在于当前 COM 枚举的端口没有被阻止。'

    Assert-Throws {
        Test-ApprovedAsset -Path $wavPath -Label '篡改素材' -ExpectedLength $script:expectedWavLength -ExpectedSha256 ('0' * 64) | Out-Null
    } '素材摘要不符时没有被阻止。'

    Write-Output '通过：fakeprobe 设备预检、明确 CLI 参数、PowerShell 5.1 UTF-8 交互输出和 native 启动后异常状态。全程未打开串口或音频设备。'
} finally {
    Remove-Item Env:\WIREX_LOCAL_FAKE_ARGS -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_LOCAL_FAKE_ENUM_ARGS -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_LOCAL_FAKE_JSON -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_LOCAL_FAKE_ENUM_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:\WIREX_LOCAL_FAKE_EXIT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $tempRoot).Path)
        if (-not $resolvedTemp.StartsWith($tempBase + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝清理越出系统临时目录的目标：$resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
