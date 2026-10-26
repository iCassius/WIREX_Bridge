[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-UiDevices {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path (Join-Path $repoRoot 'ui\windows') 'bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
Assert-UiDevices ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$wanted = @('New-UiDeviceOption', 'Get-UiEndpointOptions', 'Get-UiSerialOptions', 'Test-UiAutoEndpointResolvable',
    'Convert-UiGainSliderToMilli', 'Start-UiAudioQuery', 'Request-StopUiAudioQuery', 'Test-UiAudioQueryExpired',
    'Read-UiAudioQueryResult', 'Test-UiDiscoveryResultOwner')
$found = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -ccontains $node.Name }, $true))
Assert-UiDevices ($found.Count -eq $wanted.Count) '没有找到设备选择或增益转换函数。'
foreach ($functionAst in $found) { Invoke-Expression $functionAst.Extent.Text }

$usbInput = [pscustomobject]@{ id = 1; name = 'USB Audio Device'; endpoint_id = '{radio-input}'; pcm_48000_mono_s16_supported = $true }
$otherInput = [pscustomobject]@{ id = 0; name = 'Virtual Cable'; endpoint_id = '{virtual-input}'; pcm_48000_mono_s16_supported = $true }
$unsupportedInput = [pscustomobject]@{ id = 2; name = 'Unsupported'; endpoint_id = '{unsupported}'; pcm_48000_mono_s16_supported = $false }
$usbOutput = [pscustomobject]@{ id = 3; name = 'USB Audio Device'; endpoint_id = '{radio-output}'; pcm_48000_mono_s16_supported = $true }
$otherOutput = [pscustomobject]@{ id = 0; name = 'Speakers'; endpoint_id = '{speaker-output}'; pcm_48000_mono_s16_supported = $true }

$inputOptions = Get-UiEndpointOptions -Devices @($usbInput, $otherInput, $unsupportedInput) -SavedEndpoint 'auto' -Direction input
Assert-UiDevices ($inputOptions.SelectedValue -ceq '{radio-input}') '多个输入端点中没有优先选择唯一 USB Audio。'
Assert-UiDevices (@($inputOptions.Items | Where-Object { $_.Value -ceq '{radio-input}' }).Count -eq 1) '音频下拉项没有保存稳定 endpoint ID。'
Assert-UiDevices (@($inputOptions.Items | Where-Object { $_.Value -ceq '1' }).Count -eq 0) '音频下拉值错误地使用易变 WinMM 数字 ID。'
Assert-UiDevices (Test-UiAutoEndpointResolvable -Devices @($usbInput, $otherInput)) '唯一 USB Audio 输入端点应允许自动选择。'

$savedInput = Get-UiEndpointOptions -Devices @($usbInput, $otherInput) -SavedEndpoint '{virtual-input}' -Direction input
Assert-UiDevices ($savedInput.SelectedValue -ceq '{virtual-input}') '已保存的可用稳定 endpoint 没有优先恢复。'
$missingInput = Get-UiEndpointOptions -Devices @($usbInput, $otherInput) -SavedEndpoint '{gone-input}' -Direction input
Assert-UiDevices ($missingInput.SelectedValue -ceq '{gone-input}') '已丢失的固定输入端点被静默替换。'
$missingInputItem = @($missingInput.Items | Where-Object { $_.Value -ceq '{gone-input}' })[0]
Assert-UiDevices (-not $missingInputItem.IsAvailable -and $missingInputItem.Kind -ceq 'missing') '已丢失输入端点没有显示为不可用。'
$wrongDirection = Get-UiEndpointOptions -Devices @($usbInput) -SavedEndpoint '{radio-output}' -Direction input
Assert-UiDevices ($wrongDirection.SelectedValue -ceq '{radio-output}' -and -not (@($wrongDirection.Items | Where-Object { $_.Value -ceq '{radio-output}' })[0].IsAvailable)) '错误方向的固定端点没有被保留并标为缺失。'
$ambiguousInputs = @(
    [pscustomobject]@{ id = 1; name = 'Input A'; endpoint_id = '{input-a}'; pcm_48000_mono_s16_supported = $true },
    [pscustomobject]@{ id = 2; name = 'Input B'; endpoint_id = '{input-b}'; pcm_48000_mono_s16_supported = $true }
)
$ambiguousInputOptions = Get-UiEndpointOptions -Devices $ambiguousInputs -SavedEndpoint 'auto' -Direction input
Assert-UiDevices ($ambiguousInputOptions.SelectedValue -ceq 'auto') '有多个非 USB Audio 输入时不应猜选一个。'
Assert-UiDevices (-not (Test-UiAutoEndpointResolvable -Devices $ambiguousInputs)) '多个非 USB Audio 输入被误判为唯一可自动选择。'
$uniqueInputOptions = Get-UiEndpointOptions -Devices @($otherInput) -SavedEndpoint 'auto' -Direction input
Assert-UiDevices ($uniqueInputOptions.SelectedValue -ceq 'auto') '只有 G6/虚拟线且没有 USB Audio 时，界面错误地预选了它。'
Assert-UiDevices (-not (Test-UiAutoEndpointResolvable -Devices @($otherInput))) '只有 G6/虚拟线且没有 USB Audio 时，自动选项仍被判为可解析。'
$savedVirtualInput = Get-UiEndpointOptions -Devices @($otherInput) -SavedEndpoint '{virtual-input}' -Direction input
Assert-UiDevices ($savedVirtualInput.SelectedValue -ceq '{virtual-input}') '仍存在的已保存稳定端点没有恢复。'
$singleSpeakerOptions = Get-UiEndpointOptions -Devices @($otherOutput) -SavedEndpoint 'auto' -Direction output
Assert-UiDevices ($singleSpeakerOptions.SelectedValue -ceq 'auto') '只有普通扬声器且没有 USB Audio 时，界面错误地预选了它。'
Assert-UiDevices (-not (Test-UiAutoEndpointResolvable -Devices @($otherOutput))) '只有普通扬声器且没有 USB Audio 时，自动选项仍被判为可解析。'

$allPorts = @(
    [pscustomobject]@{ PortName = 'COM5'; FriendlyName = 'FTX-1 HRI (COM5)'; IsHri = $true },
    [pscustomobject]@{ PortName = 'COM8'; FriendlyName = 'FTX-1 HRI (COM8)'; IsHri = $true },
    [pscustomobject]@{ PortName = 'COM10'; FriendlyName = 'USB Serial (COM10)'; IsHri = $false }
)
$hriPorts = @($allPorts | Where-Object { $_.IsHri })
$serial = Get-UiSerialOptions -AllPorts $allPorts -HriPorts $hriPorts -SavedPort 'auto'
Assert-UiDevices ($serial.SelectedValue -ceq 'COM5') 'auto 没有优先选已确认的 COM5/HRI。'
Assert-UiDevices (@($serial.Items | Where-Object { $_.Value -ceq 'COM10' -and -not $_.IsAvailable }).Count -eq 1) '非 HRI 串口没有标记为不可用。'
$savedSerial = Get-UiSerialOptions -AllPorts $allPorts -HriPorts $hriPorts -SavedPort 'COM8'
Assert-UiDevices ($savedSerial.SelectedValue -ceq 'COM8') '已保存 HRI 串口没有优先恢复。'
$remainingPorts = @($allPorts | Where-Object { $_.PortName -cne 'COM5' })
$missingSerial = Get-UiSerialOptions -AllPorts $remainingPorts -HriPorts @($remainingPorts | Where-Object { $_.PortName -ceq 'COM8' }) -SavedPort 'COM5'
Assert-UiDevices ($missingSerial.SelectedValue -ceq 'COM5' -and -not (@($missingSerial.Items | Where-Object { $_.Value -ceq 'COM5' })[0].IsAvailable)) '已保存但未确认的 HRI 串口被静默替换。'
$otherHriPorts = @(
    [pscustomobject]@{ PortName = 'COM8'; FriendlyName = 'HRI A (COM8)'; IsHri = $true },
    [pscustomobject]@{ PortName = 'COM11'; FriendlyName = 'HRI B (COM11)'; IsHri = $true }
)
$ambiguousSerial = Get-UiSerialOptions -AllPorts $otherHriPorts -HriPorts $otherHriPorts -SavedPort 'auto'
Assert-UiDevices ($ambiguousSerial.SelectedValue -ceq 'auto') '多个 HRI 串口且没有 COM5 时不应猜选一个。'

Assert-UiDevices ((Convert-UiGainSliderToMilli 0.25) -eq 250) '播放增益下边界转换错误。'
Assert-UiDevices ((Convert-UiGainSliderToMilli 16.0) -eq 16000) '发送增益上边界转换错误。'
Assert-UiDevices ((Convert-UiGainSliderToMilli 1.2346) -eq 1235) '滑块显示和保存没有按同一千分之一精度舍入。'
foreach ($invalidGain in @(0.249, 16.001, [double]::NaN, [double]::PositiveInfinity)) {
    $rejected = $false
    try { [void](Convert-UiGainSliderToMilli $invalidGain) } catch { $rejected = $true }
    Assert-UiDevices $rejected '无效的滑块增益没有被拒绝。'
}

$ownerWindow = New-Object object
$otherWindow = New-Object object
Assert-UiDevices (Test-UiDiscoveryResultOwner -ResultGeneration 4 -CurrentGeneration 4 -ResultWindow $ownerWindow -CurrentWindow $ownerWindow) '当前设备查询结果被错误拒绝。'
Assert-UiDevices (-not (Test-UiDiscoveryResultOwner -ResultGeneration 4 -CurrentGeneration 5 -ResultWindow $ownerWindow -CurrentWindow $ownerWindow)) '旧扫描结果在新扫描开始后仍可写入界面。'
Assert-UiDevices (-not (Test-UiDiscoveryResultOwner -ResultGeneration 4 -CurrentGeneration 4 -ResultWindow $ownerWindow -CurrentWindow $otherWindow)) '旧设置窗口的设备扫描结果可以写入新窗口。'
Assert-UiDevices (-not (Test-UiDiscoveryResultOwner -ResultGeneration 4 -CurrentGeneration 4 -ResultWindow $ownerWindow -CurrentWindow $null)) '已关闭窗口的设备扫描结果可以写入界面。'

$query = [pscustomobject]@{
    StartedUtc = [DateTime]::UtcNow.AddSeconds(-2)
    TimeoutMilliseconds = 1000
}
Assert-UiDevices (Test-UiAudioQueryExpired -Query $query) '超时的设备查询没有被标记为过期。'

$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$audioFixturePath = Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-audio-query-' + [guid]::NewGuid().ToString('N') + '.ps1')
$audioFixtureJson = '{"schema_version":1,"type":"audio_devices","wave_inputs":[{"id":1,"name":"USB Audio Device","endpoint_id":"{input}","pcm_48000_mono_s16_supported":true}],"wave_outputs":[]}'
[System.IO.File]::WriteAllText($audioFixturePath, ("[Console]::Out.WriteLine('" + $audioFixtureJson + "')`r`n"), (New-Object System.Text.UTF8Encoding($true)))
try {
    $query = Start-UiAudioQuery -Executable $windowsPowerShell -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $audioFixturePath + '"')
    try {
        Assert-UiDevices ($query.Process.WaitForExit(5000)) '音频查询成功替身没有及时退出。'
        Assert-UiDevices ($query.StdoutTask.Wait(5000) -and $query.StderrTask.Wait(5000)) '成功查询的输出读取任务没有结束。'
        $parsedAudio = Read-UiAudioQueryResult -Query $query
        Assert-UiDevices ($parsedAudio.Completed -and $parsedAudio.Audio.wave_inputs.Count -eq 1 -and
            [string]$parsedAudio.Audio.wave_inputs[0].endpoint_id -ceq '{input}') 'UI 没有读取查询进程返回的设备 JSON。'
    } finally { $query.Process.Dispose() }
} finally {
    if ([System.IO.File]::Exists($audioFixturePath)) { [System.IO.File]::Delete($audioFixturePath) }
}

$query = Start-UiAudioQuery -Executable $windowsPowerShell -Arguments '-NoLogo -NoProfile -Command "Start-Sleep -Seconds 30"' -TimeoutMilliseconds 30000
try {
    $ownedProcessId = $query.Process.Id
    Assert-UiDevices (-not $query.Process.HasExited) '长查询替身未保持运行，无法验证取消收尾。'
    Request-StopUiAudioQuery -Query $query
    Assert-UiDevices ($query.Process.WaitForExit(5000)) '取消查询没有在有界时间内结束所创建的进程。'
    Assert-UiDevices ($query.StdoutTask.Wait(5000) -and $query.StderrTask.Wait(5000)) '取消查询后输出读取任务未收尾。'
} finally {
    if ($query -and -not $query.Process.HasExited) {
        try { Request-StopUiAudioQuery -Query $query } catch { }
        [void]$query.Process.WaitForExit(5000)
    }
    if ($query) { $query.Process.Dispose() }
}
$helperStillRunning = $false
try {
    $remainingHelper = [System.Diagnostics.Process]::GetProcessById($ownedProcessId)
    try { $helperStillRunning = -not $remainingHelper.HasExited }
    finally { $remainingHelper.Dispose() }
} catch [System.ArgumentException] { $helperStillRunning = $false }
Assert-UiDevices (-not $helperStillRunning) '取消后音频查询辅助进程仍在运行。'

Write-Output '通过：设备下拉优先级、固定设备缺失处理、旧扫描隔离、音频查询取消回收和滑块保存精度。'
