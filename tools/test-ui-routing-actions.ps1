$ErrorActionPreference = 'Stop'
function Assert-UiRoutingAction {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "检查失败：$Message" }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiScript = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiScript,[ref]$tokens,[ref]$parseErrors)
Assert-UiRoutingAction ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
foreach ($name in @('Copy-UiRxPolicy','Get-UiObservedRouteAllowed','Test-UiLocalPrivateRouteCoversSource',
        'Get-UiObservedCardActionState','Invoke-ObservedRoutingAction')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name },$true)
    Assert-UiRoutingAction ($null -ne $functionAst) "缺少来源卡片交互函数：$name"
    Invoke-Expression $functionAst.Extent.Text
}

$script:capturedPolicy = $null
$script:lastRoutingEditorStatus = ''
$script:pendingRoutingMutation = $null
$script:supervisor = $null
$script:settingsWindow = $null
function Invoke-UiRoutingMutation {
    param([string]$Command,[object]$PolicyOrTarget,[bool]$TransmitEnabled=$false)
    $script:capturedPolicy = Copy-UiRxPolicy -Policy $PolicyOrTarget
}
function Set-RoutingEditorStatus {
    param([string]$Text,[bool]$Failed=$false)
    $script:lastRoutingEditorStatus = $Text
}
function New-TestRxPolicy {
    param([string]$GroupMode='selected',[string]$PrivateMode='disabled',[object[]]$AllowGroups=@(),
        [object[]]$AllowPeers=@(),[object[]]$LocalRoutes=@(),[object[]]$BlockedGroups=@(),[uint64[]]$BlockedSources=@())
    return [pscustomobject][ordered]@{
        group_mode=$GroupMode; private_mode=$PrivateMode
        allow_groups=[object[]]$AllowGroups; allow_private_peers=[object[]]$AllowPeers
        local_private_routes=[object[]]$LocalRoutes; blocked_groups=[object[]]$BlockedGroups
        blocked_source_ids=[uint64[]]$BlockedSources
    }
}
function Set-TestActivePolicy([object]$Policy) {
    $script:activeRouting = [pscustomobject]@{ rx_policy=$Policy }
    $script:capturedPolicy = $null
    $script:lastRoutingEditorStatus = ''
}

$groupRoute = [pscustomobject]@{ destination_id=[uint64]12345; slot=[uint64]1 }
$blockedSpeaker = [uint64]71001
$groupPolicy = New-TestRxPolicy -GroupMode selected -AllowGroups @($groupRoute) -BlockedSources @($blockedSpeaker)
$groupSource = [pscustomobject]@{ source_id=$blockedSpeaker; destination_id=[uint64]12345; slot=[uint64]1; kind='group' }
Set-TestActivePolicy $groupPolicy
$groupCard = Get-UiObservedCardActionState -Source $groupSource -Policy $groupPolicy
Assert-UiRoutingAction ($groupCard.local_text -ceq '停止本地收听' -and $groupCard.local_action_enabled -and $groupCard.source_blocked) `
    '频道接收状态和全局发话来源屏蔽必须分别显示。'
Invoke-ObservedRoutingAction -Action toggle -Source $groupSource
Assert-UiRoutingAction ($null -ne $script:capturedPolicy -and $script:capturedPolicy.blocked_source_ids.Count -eq 1 -and
    $script:capturedPolicy.blocked_source_ids[0] -eq $blockedSpeaker -and $script:capturedPolicy.allow_groups.Count -eq 0 -and
    $script:capturedPolicy.blocked_groups.Count -eq 1) '群组卡片停止收听不能移除发话来源屏蔽，并须原子替换allow/block。'

$allDelivered = New-TestRxPolicy -GroupMode all_delivered -BlockedSources @($blockedSpeaker)
Set-TestActivePolicy $allDelivered
$groupCard = Get-UiObservedCardActionState -Source $groupSource -Policy $allDelivered
Assert-UiRoutingAction ($groupCard.local_text -ceq '停止本地收听') 'AllDelivered 模式下未单独屏蔽的频道应显示为已允许。'
Invoke-ObservedRoutingAction -Action toggle -Source $groupSource
Assert-UiRoutingAction ($script:capturedPolicy.blocked_groups.Count -eq 1 -and $script:capturedPolicy.allow_groups.Count -eq 0 -and
    $script:capturedPolicy.blocked_source_ids.Count -eq 1) 'AllDelivered 群组卡片操作只能切换频道屏蔽。'

$globalBlockPolicy = New-TestRxPolicy -GroupMode selected -AllowGroups @($groupRoute)
Set-TestActivePolicy $globalBlockPolicy
Invoke-ObservedRoutingAction -Action block -Source $groupSource
Assert-UiRoutingAction ($script:capturedPolicy.allow_groups.Count -eq 1 -and $script:capturedPolicy.blocked_groups.Count -eq 0 -and
    $script:capturedPolicy.blocked_source_ids.Count -eq 1 -and $script:capturedPolicy.blocked_source_ids[0] -eq $blockedSpeaker) `
    '“屏蔽此来源”操作必须只修改跨组来源屏蔽。'

$privateSource = [pscustomobject]@{ source_id=[uint64]72001; destination_id=[uint64]1; slot=[uint64]1; kind='private' }
$coveredPolicy = New-TestRxPolicy -PrivateMode all_peers_to_local -LocalRoutes @([pscustomobject]@{ local_destination_id=[uint64]1; slot=[uint64]1 })
Set-TestActivePolicy $coveredPolicy
$privateCard = Get-UiObservedCardActionState -Source $privateSource -Policy $coveredPolicy
Assert-UiRoutingAction (-not $privateCard.local_action_enabled -and $privateCard.local_text -ceq '整时隙私呼已接收' -and
    $privateCard.local_tooltip -match '屏蔽此来源') 'all-local覆盖的私呼卡片必须禁用单联系人收听开关并解释范围。'
Invoke-ObservedRoutingAction -Action toggle -Source $privateSource
Assert-UiRoutingAction ($null -eq $script:capturedPolicy -and $script:lastRoutingEditorStatus -match '所有私呼') `
    'all-local覆盖的私呼卡片不能修改策略或扩大/收窄规则。'

$specificPeer = [pscustomobject]@{ source_id=[uint64]72001; local_destination_id=[uint64]1; slot=[uint64]2 }
$uncoveredPolicy = New-TestRxPolicy -PrivateMode all_peers_to_local `
    -LocalRoutes @([pscustomobject]@{ local_destination_id=[uint64]1; slot=[uint64]1 }) -BlockedSources @([uint64]72001)
$uncoveredSource = [pscustomobject]@{ source_id=[uint64]72001; destination_id=[uint64]1; slot=[uint64]2; kind='private' }
Set-TestActivePolicy $uncoveredPolicy
$privateCard = Get-UiObservedCardActionState -Source $uncoveredSource -Policy $uncoveredPolicy
Assert-UiRoutingAction ($privateCard.local_action_enabled -and $privateCard.source_blocked -and $privateCard.local_text -ceq '恢复本地收听') `
    'all-local未覆盖时，精确联系人规则和来源屏蔽应分别显示。'
Invoke-ObservedRoutingAction -Action toggle -Source $uncoveredSource
Assert-UiRoutingAction ($script:capturedPolicy.private_mode -ceq 'all_peers_to_local' -and
    $script:capturedPolicy.allow_private_peers.Count -eq 1 -and
    $script:capturedPolicy.allow_private_peers[0].source_id -eq 72001 -and
    $script:capturedPolicy.allow_private_peers[0].slot -eq 2 -and
    $script:capturedPolicy.local_private_routes.Count -eq 1 -and $script:capturedPolicy.local_private_routes[0].slot -eq 1 -and
    $script:capturedPolicy.blocked_source_ids.Count -eq 1) 'all-local未覆盖的私呼切换必须仅增删精确peer，并保留原local路由和跨组屏蔽。'

$script:activeRouting.rx_policy = $script:capturedPolicy
Invoke-ObservedRoutingAction -Action toggle -Source $uncoveredSource
Assert-UiRoutingAction ($script:capturedPolicy.allow_private_peers.Count -eq 0 -and
    $script:capturedPolicy.local_private_routes.Count -eq 1 -and $script:capturedPolicy.blocked_source_ids.Count -eq 1) `
    'all-local联系人开关关闭精确peer时不得删除local路由或跨组来源屏蔽。'

$disabledPolicy = New-TestRxPolicy -PrivateMode disabled
Set-TestActivePolicy $disabledPolicy
Invoke-ObservedRoutingAction -Action toggle -Source $uncoveredSource
Assert-UiRoutingAction ($script:capturedPolicy.private_mode -ceq 'selected_peers' -and
    $script:capturedPolicy.allow_private_peers.Count -eq 1 -and $script:capturedPolicy.local_private_routes.Count -eq 0) `
    'disabled 私呼模式从观察卡开启时只能添加精确peer。'

Write-Output '通过：WPF来源卡片策略动作覆盖Selected/AllDelivered、分离频道与发话来源屏蔽、all-local精确联系人并集和范围提示。'
