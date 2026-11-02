[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0

function Assert-UiR122 {
    param([bool]$Condition,[string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw $Message }
}

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw '请使用 Windows PowerShell 5.1 运行此回归。'
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw '请使用 -STA 运行此回归。'
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$modulePath = Join-Path $repoRoot 'ui\windows\PortableConfig.psm1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$parseErrors)
Assert-UiR122 ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
$wanted = @('ConvertTo-UiOptionalUnsigned','Set-UiGatewayIdentityState','Get-UiGatewayIdentityForSave')
$selected = @($definitions | Where-Object { $wanted -ccontains $_.Name })
foreach ($name in $wanted) {
    Assert-UiR122 (@($selected | Where-Object { $_.Name -ceq $name }).Count -eq 1) ("bridge-ui.ps1 缺少唯一函数 {0}。" -f $name)
}
Invoke-Expression (($selected | ForEach-Object { $_.Extent.Text }) -join "`r`n")

function New-UiR122IdentityConfig {
    param([uint64]$SourceId,[uint64]$GatewayId)
    return [pscustomobject][ordered]@{
        connection=[pscustomobject][ordered]@{source_id=$SourceId;gateway_id=$GatewayId}
    }
}

function Assert-UiR122Throws {
    param([scriptblock]$Action,[string]$ExpectedMessage)
    $thrown = $false
    try { & $Action | Out-Null }
    catch { $thrown = ([string]$_.Exception.Message -match $ExpectedMessage) }
    Assert-UiR122 $thrown ("预期保存拒绝并提示‘{0}’。" -f $ExpectedMessage)
}

$portableConfigSource = [System.IO.File]::ReadAllText($modulePath,[System.Text.Encoding]::UTF8)
Assert-UiR122 ($portableConfigSource -match 'color_code\s*=\s*\[uint64\]1') '新便携配置的色码默认值不再是 1。'

$validConfig = New-UiR122IdentityConfig -SourceId 123456 -GatewayId 12345678
$validState = Set-UiGatewayIdentityState -Config $validConfig
Assert-UiR122 ($validState.state -ceq 'split_gateway' -and $validState.device_number -ceq '78') '匹配的旧 Gateway 没有无损拆出两位后缀。'
$validRoundTrip = Get-UiGatewayIdentityForSave -SourceText '123456' -DeviceNumberText '78' -State $validState
Assert-UiR122 ($validRoundTrip.source_id -eq 123456 -and $validRoundTrip.gateway_id -eq 12345678) '标准旧配置保存后 Gateway 没有保持 source×100+suffix。'

$zeroSuffixConfig = New-UiR122IdentityConfig -SourceId 123456 -GatewayId 12345600
$zeroSuffixState = Set-UiGatewayIdentityState -Config $zeroSuffixConfig
Assert-UiR122 ($zeroSuffixState.device_number -ceq '00') '后缀 00 没有保留两位格式。'

$bareConfig = New-UiR122IdentityConfig -SourceId 1234567 -GatewayId 1234567
$bareState = Set-UiGatewayIdentityState -Config $bareConfig
Assert-UiR122 ($bareState.device_number -ceq '' -and $bareState.state -ceq 'legacy_bare_id') '旧 bare ID 被误拆或被填入默认后缀。'
$barePreserved = Get-UiGatewayIdentityForSave -SourceText '1234567' -DeviceNumberText '' -State $bareState
Assert-UiR122 ($barePreserved.source_id -eq 1234567 -and $barePreserved.gateway_id -eq 1234567) '未编辑的旧 bare ID 没有原样保留。'
Assert-UiR122Throws { Get-UiGatewayIdentityForSave -SourceText '1234568' -DeviceNumberText '' -State $bareState } '两位设备编号'
$bareExplicitSuffix = Get-UiGatewayIdentityForSave -SourceText '1234567' -DeviceNumberText '00' -State $bareState
Assert-UiR122 ($bareExplicitSuffix.gateway_id -eq 123456700) '用户明确选择 00 后没有生成新的 Gateway。'

$sevenDigitConfig = New-UiR122IdentityConfig -SourceId 123456 -GatewayId 1234567
$sevenDigitState = Set-UiGatewayIdentityState -Config $sevenDigitConfig
Assert-UiR122 ($sevenDigitState.device_number -ceq '' -and $sevenDigitState.state -ceq 'legacy_unmatched') '不匹配的七位旧 Gateway 被当成可拆分值。'
$sevenDigitPreserved = Get-UiGatewayIdentityForSave -SourceText '123456' -DeviceNumberText '' -State $sevenDigitState
Assert-UiR122 ($sevenDigitPreserved.gateway_id -eq 1234567) '未编辑字段的七位旧 Gateway 被覆盖。'
Assert-UiR122Throws { Get-UiGatewayIdentityForSave -SourceText '654321' -DeviceNumberText '' -State $sevenDigitState } '两位设备编号'
$sevenDigitExplicit = Get-UiGatewayIdentityForSave -SourceText '123456' -DeviceNumberText '09' -State $sevenDigitState
Assert-UiR122 ($sevenDigitExplicit.gateway_id -eq 12345609) '明确选择编号后没有按 DMR ID 重新组合旧 Gateway。'

$mismatchConfig = New-UiR122IdentityConfig -SourceId 123456 -GatewayId 9876543
$mismatchState = Set-UiGatewayIdentityState -Config $mismatchConfig
Assert-UiR122 ($mismatchState.device_number -ceq '' -and $mismatchState.state -ceq 'legacy_unmatched') '前缀不匹配的 Gateway 被拆分。'
$mismatchPreserved = Get-UiGatewayIdentityForSave -SourceText '123456' -DeviceNumberText '' -State $mismatchState
Assert-UiR122 ($mismatchPreserved.gateway_id -eq 9876543) '保存呼号等非ID设置时覆盖了旧 Gateway。'

$emptyConfig = New-UiR122IdentityConfig -SourceId 0 -GatewayId 0
$emptyState = Set-UiGatewayIdentityState -Config $emptyConfig
Assert-UiR122 ($emptyState.device_number -ceq '01' -and $emptyState.state -ceq 'new_empty') '新空配置没有显示默认设备编号 01。'
$emptyRoundTrip = Get-UiGatewayIdentityForSave -SourceText '' -DeviceNumberText '01' -State $emptyState
Assert-UiR122 ($emptyRoundTrip.source_id -eq 0 -and $emptyRoundTrip.gateway_id -eq 0) '空白 DMR ID 保存时误把默认编号写成 Gateway。'
Assert-UiR122Throws { Get-UiGatewayIdentityForSave -SourceText '' -DeviceNumberText '02' -State $emptyState } '先填写本机 DMR ID'
$newIdentity = Get-UiGatewayIdentityForSave -SourceText '234567' -DeviceNumberText '01' -State $emptyState
Assert-UiR122 ($newIdentity.gateway_id -eq 23456701) '新配置输入 DMR ID 后没有组合 Gateway。'

foreach ($invalidNumber in @('0','1','100','9a','-1')) {
    Assert-UiR122Throws {
        Get-UiGatewayIdentityForSave -SourceText '123456' -DeviceNumberText $invalidNumber -State $validState
    } '两位数字'
}
$maxIdentity = Get-UiGatewayIdentityForSave -SourceText '16777215' -DeviceNumberText '99' -State $emptyState
Assert-UiR122 ($maxIdentity.gateway_id -eq 1677721599 -and $maxIdentity.gateway_id -le [uint64]4294967295) 'DMR ID 上限乘 100 后的 Gateway 计算溢出或超出配置范围。'

$source = [System.IO.File]::ReadAllText($uiPath,[System.Text.Encoding]::UTF8)
Assert-UiR122 ($source -notmatch 'GatewayBox|ColorCodeBox|MakeChannelTxTargetCheckBox' -and
    $source -match 'Add-UiChannelFromInputs' -and $source -match 'IsNullOrWhiteSpace\(\$script:txChannelKey\)') `
    '运行逻辑仍引用旧Gateway/色码/PTT checkbox控件或首项目标初始化已丢失。'

Write-Output ("PASS: test-ui-r122.ps1 ({0} WinPS 5.1 STA compatibility assertions)" -f $script:assertionCount)
