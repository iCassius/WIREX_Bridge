[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-UiTarget {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module -Name (Join-Path $PSScriptRoot 'bridge-user-config.psm1') -Force
$uiScript = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiScript, [ref]$tokens, [ref]$parseErrors)
Assert-UiTarget ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$functionNames = @('Format-ProfileTarget', 'Format-ProfileReceiveTarget', 'Format-ProfileTransmitPermission', 'New-EffectiveTargetProfile')
foreach ($functionName in $functionNames) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
    Assert-UiTarget ($null -ne $functionAst) "缺少 UI 收发目标处理函数：$functionName"
    Invoke-Expression $functionAst.Extent.Text
}

$connection = [pscustomobject][ordered]@{
    callsign = 'BI7KGD'; gateway_id = [uint64]461135501; source_id = [uint64]4611355
    master = '43.129.83.124'; master_port = [uint64]62031; destination_id = [uint64]460997
    slot = [uint64]2; color_code = [uint64]0; call_kind = 'private'
}
$devices = [pscustomobject][ordered]@{
    serial_port = 'COM5'; wave_in_endpoint_id = 'usb-in'; wave_out_endpoint_id = 'usb-out'
}
$baseProfile = ConvertTo-BridgeUserConnectionProfile -Connection $connection -Devices $devices
$parrot = New-EffectiveTargetProfile -Profile $baseProfile -Target 'parrot-cn'
Assert-UiTarget ($parrot.connection.destination_id -eq 460997 -and $parrot.connection.call_kind -ceq 'private' -and
    $parrot.connection.slot -eq 2 -and $parrot.receive.destination_id -eq 4611355 -and
    $parrot.receive.call_kind -ceq 'private' -and $parrot.receive.slot -eq 2 -and $parrot.transmit_enabled) `
    '中国鹦鹉预设应将发射指向460997，并接收本机私呼回应'

$listen91 = New-EffectiveTargetProfile -Profile $parrot -Target 'listen-91'
Assert-UiTarget ($listen91.connection.destination_id -eq 460997 -and $listen91.connection.call_kind -ceq 'private' -and
    $listen91.receive.destination_id -eq 91 -and $listen91.receive.call_kind -ceq 'group' -and
    $listen91.receive.slot -eq 2 -and -not $listen91.transmit_enabled) `
    'TG91预设应保留发射目标、独立选择TG91接收并关闭发射许可'
$receiveSummary = Format-ProfileReceiveTarget -Profile $listen91
Assert-UiTarget ($receiveSummary -ceq '接收：TG 91 · TS2') `
    'TG91只收预设不应显示发射私呼回话接收'
Assert-UiTarget ((Format-ProfileTransmitPermission -Profile $listen91) -ceq '发射许可：关闭') `
    '收听预设的界面必须显示发射许可已关闭'
$listen46001 = New-EffectiveTargetProfile -Profile $parrot -Target 'listen-46001'
Assert-UiTarget ($listen46001.receive.destination_id -eq 46001 -and $listen46001.receive.call_kind -ceq 'group' -and
    $listen46001.receive.slot -eq 2 -and $listen46001.connection.destination_id -eq 460997 -and
    -not $listen46001.transmit_enabled) 'TG46001预设应只改接收目标并关闭发射许可'
$tg91WithTransmit = ConvertTo-BridgeUserConnectionProfile -Connection $parrot.connection -Devices $parrot.devices `
    -Receive $listen91.receive -TransmitEnabled $true
Assert-UiTarget ((Format-ProfileReceiveTarget -Profile $tg91WithTransmit).Contains('鹦鹉回声 · TS2')) `
    '启用私呼发射并以TG91作主接收时应显示鹦鹉私呼回话接收'

$custom = New-EffectiveTargetProfile -Profile $listen91 -Target 'custom'
Assert-UiTarget ($custom.connection.destination_id -eq 460997 -and $custom.receive.destination_id -eq 91 -and
    -not $custom.transmit_enabled) '使用已保存目标应保留各自的收发目标与许可'
$parrotReceiveSummary = Format-ProfileReceiveTarget -Profile $parrot
Assert-UiTarget ($parrotReceiveSummary -ceq '接收：单呼 4611355 · TS2') '鹦鹉预设主接收字段已是本机ID时不重复显示回程目标'

$settingsXaml = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'), [System.Text.Encoding]::UTF8)
$mainXaml = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ui\windows\MainWindow.xaml'), [System.Text.Encoding]::UTF8)
Assert-UiTarget ($settingsXaml.Contains('Tag="bm-china-4602"') -and $settingsXaml.Contains('43.129.83.124:62031')) `
    '设置窗口应列出BM China 4602地址和UDP端口'
Assert-UiTarget ($settingsXaml.Contains('x:Name="ReceiveDestinationBox"') -and
    $settingsXaml.Contains('x:Name="TransmitEnabledBox"')) '设置窗口应分别编辑接收目标和发射许可'
Assert-UiTarget ($settingsXaml.Contains('使用已保存目标') -and $settingsXaml.Contains('TG91 或 TG46001')) `
    '设置窗口应说明收听预设关闭发射许可，用户需选择已保存目标才能应用已保存发射许可'
Assert-UiTarget ($mainXaml.Contains('x:Name="ReceiveTargetValue"') -and
    $mainXaml.Contains('x:Name="TransmitTargetValue"') -and
    $mainXaml.Contains('x:Name="TransmitPermissionValue"')) '主面板应显示本次运行冻结的收发目标与发射许可'

Write-Output '通过：发射目标、TG91收听目标、私呼回程接收、发射许可和BM China 4602设置显示已校验。'
