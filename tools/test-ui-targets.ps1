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
$functionNames = @('Format-ProfileTarget', 'Format-ProfileReceiveTarget', 'Format-ProfileTransmitPermission',
    'New-EffectiveTargetProfile', 'Get-UiReceiveEditorState', 'New-UiSimpleReceivePolicy')
foreach ($functionName in $functionNames) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
    Assert-UiTarget ($null -ne $functionAst) "缺少 UI 配置处理函数：$functionName"
    Invoke-Expression $functionAst.Extent.Text
}

$legacyConnection = [pscustomobject][ordered]@{
    callsign='BI7KGD'; gateway_id=[uint64]461135501; source_id=[uint64]4611355
    master='43.129.83.124'; master_port=[uint64]62031; destination_id=[uint64]460997
    slot=[uint64]2; color_code=[uint64]0; call_kind='private'
}
$devices = [pscustomobject][ordered]@{ serial_port='COM5'; wave_in_endpoint_id='usb-in'; wave_out_endpoint_id='usb-out' }
$baseProfile = ConvertTo-BridgeUserConnectionProfile -Connection $legacyConnection -Devices $devices
$parrot = New-EffectiveTargetProfile -Profile $baseProfile -Target 'parrot-cn'
Assert-UiTarget ($parrot.tx_target.destination_id -eq 460997 -and $parrot.tx_target.kind -ceq 'private' -and
    $parrot.tx_target.slot -eq 2 -and $parrot.rx_policy.private_mode -ceq 'all_peers_to_local' -and
    $parrot.rx_policy.local_private_routes.Count -eq 1 -and
    $parrot.rx_policy.local_private_routes[0].local_destination_id -eq 4611355 -and
    $parrot.rx_policy.local_private_routes[0].slot -eq 2 -and $parrot.transmit_enabled) `
    '鹦鹉预设应保存本机私呼主路由与私呼目标，不再用旧 connection 目标字段'

$listen91 = New-EffectiveTargetProfile -Profile $parrot -Target 'listen-91'
Assert-UiTarget ($listen91.tx_target.destination_id -eq 460997 -and $listen91.tx_target.kind -ceq 'private' -and
    $listen91.rx_policy.allow_groups.Count -eq 1 -and $listen91.rx_policy.allow_groups[0].destination_id -eq 91 -and
    $listen91.rx_policy.private_mode -ceq 'disabled' -and -not $listen91.transmit_enabled) `
    'TG91 预设应选一个组呼路由并关闭私呼与发射许可'
$receiveSummary = Format-ProfileReceiveTarget -Profile $listen91
Assert-UiTarget ($receiveSummary.Contains('TG 91') -and $receiveSummary.Contains('私呼关闭')) `
    'TG91 预设的显示应与完整 schema 2 策略一致'
Assert-UiTarget ((Format-ProfileTransmitPermission -Profile $listen91) -ceq '发射许可：关闭') `
    '收听预设的界面必须显示发射许可已关闭'

$listen46001 = New-EffectiveTargetProfile -Profile $parrot -Target 'listen-46001'
Assert-UiTarget ($listen46001.rx_policy.allow_groups.Count -eq 1 -and
    $listen46001.rx_policy.allow_groups[0].destination_id -eq 46001 -and
    $listen46001.tx_target.destination_id -eq 460997 -and -not $listen46001.transmit_enabled) `
    'TG46001 预设应保留 TX 目标并设置一个 Selected RX 路由'
$custom = New-EffectiveTargetProfile -Profile $listen91 -Target 'custom'
Assert-UiTarget ($custom.tx_target.destination_id -eq 460997 -and $custom.rx_policy.allow_groups[0].destination_id -eq 91 -and
    -not $custom.transmit_enabled) '使用已保存目标应保留独立保存的 TX、RX 与发射许可'

$v2Connection = [pscustomobject][ordered]@{
    callsign='BI7KGD'; gateway_id=[uint64]461135501; source_id=[uint64]4611355
    master='43.129.83.124'; master_port=[uint64]62031; color_code=[uint64]0
}
$v2Tx = [pscustomobject][ordered]@{ destination_id=[uint64]460997; kind='private'; slot=[uint64]2 }
$v2Policy = [pscustomobject][ordered]@{
    group_mode='selected'; private_mode='disabled'
    allow_groups=@([pscustomobject]@{destination_id=[uint64]91;slot=[uint64]2}, [pscustomobject]@{destination_id=[uint64]46001;slot=[uint64]1})
    allow_private_peers=@(); local_private_routes=@(); blocked_groups=@(); blocked_source_ids=@()
}
$multi = ConvertTo-BridgeUserConnectionProfile -Connection $v2Connection -TxTarget $v2Tx -Devices $devices `
    -RxPolicy $v2Policy -TransmitEnabled $false
$multiView = New-EffectiveTargetProfile -Profile $multi -Target 'custom'
Assert-UiTarget ($multiView.rx_policy.allow_groups.Count -eq 2 -and $multiView.rx_policy.allow_groups[1].destination_id -eq 46001) `
    '自定义目标的 UI 视图必须完整保留多组 schema 2 配置'
$multiEditor = Get-UiReceiveEditorState -Profile $multiView
Assert-UiTarget (-not $multiEditor.CanEdit -and $multiEditor.Reason) '多组策略在第一步单路由编辑器中必须只读'
Assert-UiTarget ((Format-ProfileReceiveTarget -Profile $multiView).Contains('TG 91') -and
    (Format-ProfileReceiveTarget -Profile $multiView).Contains('TG 46001')) 'UI 预览应显示所有保留的 Selected 组呼'

$settingsXaml = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'), [System.Text.Encoding]::UTF8)
$mainXaml = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'ui\windows\MainWindow.xaml'), [System.Text.Encoding]::UTF8)
Assert-UiTarget ($settingsXaml.Contains('x:Name="ProfileMigrationText"') -and
    $settingsXaml.Contains('x:Name="ReceivePolicyPreviewText"')) '设置窗口应显示 schema 来源和接收策略预览'
Assert-UiTarget ($mainXaml.Contains('x:Name="ControlProtocolValue"') -and
    $mainXaml.Contains('x:Name="ControlStatusButton"')) '主面板应显示 v2 控制状态并提供只读 status 查询'
Assert-UiTarget ($settingsXaml.Contains('Tag="bm-china-4602"') -and $settingsXaml.Contains('43.129.83.124:62031')) `
    '设置窗口应列出 BM China 4602 地址和 UDP 端口'

Write-Output '通过：schema 2 目标预设、完整多组策略保留、复杂策略只读、迁移与控制协议 UI 字段已校验。'
