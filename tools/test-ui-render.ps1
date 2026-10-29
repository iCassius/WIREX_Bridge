[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [string]$RenderOutputDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
function Assert-UiRender {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-PngHasPixelDiversity {
    param([Parameter(Mandatory=$true)][string]$Path)
    $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$Path)
    $converted = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap
    $converted.BeginInit()
    $converted.Source = $frame
    $converted.DestinationFormat = [System.Windows.Media.PixelFormats]::Bgra32
    $converted.EndInit()
    $stride = [int]$converted.PixelWidth * 4
    $pixels = New-Object byte[] ($stride * [int]$converted.PixelHeight)
    $converted.CopyPixels($pixels,$stride,0)
    $colors = New-Object 'System.Collections.Generic.HashSet[string]'
    $stepX = [Math]::Max(1,[int][Math]::Floor($converted.PixelWidth / 100))
    $stepY = [Math]::Max(1,[int][Math]::Floor($converted.PixelHeight / 100))
    for ($y=0; $y -lt $converted.PixelHeight; $y+=$stepY) {
        for ($x=0; $x -lt $converted.PixelWidth; $x+=$stepX) {
            $offset = ($y * $stride) + ($x * 4)
            [void]$colors.Add(('{0},{1},{2}' -f $pixels[$offset+2],$pixels[$offset+1],$pixels[$offset]))
        }
    }
    return ($colors.Count -gt 20)
}
function Test-RenderedLayout {
    param([string]$Directory, [double]$MaximumWidth = [double]::PositiveInfinity, [double]$MaximumHeight = [double]::PositiveInfinity)
    $layoutPath = Join-Path $Directory 'layout-info.json'
    Assert-UiRender ([System.IO.File]::Exists($layoutPath)) '缺少 WPF 窗口布局摘要。'
    $layout = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($layoutPath, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
    foreach ($windowName in @('main', 'settings')) {
        $window = $layout.$windowName
        Assert-UiRender ($window.width -le $MaximumWidth -and $window.height -le $MaximumHeight) ("$windowName 窗口超出工作区上限。")
        foreach ($property in $window.controls_visible.PSObject.Properties) {
            if ($windowName -ceq 'main' -and $property.Name -ceq 'TrafficCard') { continue }
            Assert-UiRender ([bool]$property.Value) ("$windowName 窗口中的 $($property.Name) 未显示。")
        }
    }
    Assert-UiRender ($layout.radio_details_expanded -eq $false) '主控制台首次显示时应收起详细路由与运行信息区。'
    Assert-UiRender (-not [bool]$layout.main.controls_visible.TrafficCard -and
        $null -eq $layout.main.controls_bounds.TrafficCard.actual) `
        '收听路由和来源管理折叠时应明确报告其内容未进入当前可见区域。'
    foreach ($controlName in @('TargetSelector', 'ReceiveTargetValue', 'TransmitTargetValue', 'TransmitPermissionValue', 'ActiveLeaseValue', 'ListeningHistoryPanel', 'CallChannelPanel', 'CallHistoryList', 'SetHistoryCallTargetButton', 'QueryCurrentIdentityButton', 'QueryHistoryIdentityButton', 'IdentityLookupStatusValue', 'CallFavoritesList', 'FavoriteCurrentTargetButton', 'FavoriteManualGroupButton', 'ApplyCallFavoriteButton', 'RemoveCallFavoriteButton', 'PlaybackGainStatusValue')) {
        Assert-UiRender ([bool]$layout.main.controls_visible.$controlName) ("主窗口收发目标控件 $controlName 未显示。")
        Assert-UiRender ([bool]$layout.main.controls_bounds.$controlName.fully_visible) ("主窗口收发目标控件 $controlName 被裁切。")
    }
    foreach ($controlName in @('DynamicGroupPanel','DynamicGroupIdBox','DynamicGroupSlotBox','AddListenGroupButton','ActivateDynamicGroupButton','DynamicGroupStatus','StopButton')) {
        Assert-UiRender ([bool]$layout.main.controls_visible.$controlName) ("动态组操作或停止控件 $controlName 未显示。")
        if ($MaximumHeight -gt 700) {
            Assert-UiRender ([bool]$layout.main.controls_bounds.$controlName.fully_visible) ("动态组操作或停止控件 $controlName 被裁切。")
        }
    }
    Assert-UiRender ($layout.main.controls_bounds.DynamicGroupIdBox.text -ceq '91' -and
        $layout.main.controls_bounds.DynamicGroupSlotBox.selected_text -ceq 'TS2') '动态组输入没有显示渲染样例 TG91 和 TS2。'
    Assert-UiRender ($layout.main.controls_bounds.DynamicGroupIdBox.background_color -ceq '#FF20252A' -and
        $layout.main.controls_bounds.DynamicGroupIdBox.foreground_color -ceq '#FFEDF1F2' -and
        $layout.main.controls_bounds.DynamicGroupIdBox.border_color -ceq '#FF536169') '动态组 TG 输入没有使用深色背景、浅色文字和可见边框。'
    Assert-UiRender (@($layout.main.controls_bounds.DynamicGroupPanel.visual_text) -ccontains 'TG') '动态组输入的 TG 标签没有进入 WPF 视觉树。'
    Assert-UiRender (@($layout.main.controls_bounds.AddListenGroupButton.visual_text) -ccontains '加入本机收听') '本机收听按钮文字没有进入 WPF 视觉树。'
    Assert-UiRender (@($layout.main.controls_bounds.ActivateDynamicGroupButton.visual_text) -ccontains '激活动态组') '动态组激活按钮文字没有进入 WPF 视觉树。'
    Assert-UiRender (@($layout.main.controls_bounds.StopButton.visual_text) -ccontains '停止并退出') '停止并退出按钮文字没有进入 WPF 视觉树。'
    $dynamicGroupBounds = $layout.main.controls_bounds.DynamicGroupPanel.actual
    foreach ($controlName in @('DynamicGroupIdBox','DynamicGroupSlotBox','AddListenGroupButton','ActivateDynamicGroupButton','DynamicGroupStatus')) {
        $controlBounds = $layout.main.controls_bounds.$controlName.actual
        Assert-UiRender ($controlBounds.x -ge $dynamicGroupBounds.x -and $controlBounds.y -ge $dynamicGroupBounds.y -and
            $controlBounds.right -le $dynamicGroupBounds.right -and $controlBounds.bottom -le $dynamicGroupBounds.bottom) `
            ("动态组控件 $controlName 超出面板范围。")
    }
    $statusCards = @(
        @{ card = 'CoreStatusCard'; detail = 'CoreDetail' },
        @{ card = 'RadioStatusCard'; detail = 'RadioDetail' },
        @{ card = 'AudioStatusCard'; detail = 'AudioDetail' },
        @{ card = 'BmStatusCard'; detail = 'BmDetail' }
    )
    foreach ($status in $statusCards) {
        Assert-UiRender ([bool]$layout.main.controls_bounds.($status.card).fully_visible) ("状态卡 $($status.card) 没有完整显示。")
        $cardBounds = $layout.main.controls_bounds.($status.card).actual
        $detailBounds = $layout.main.controls_bounds.($status.detail)
        Assert-UiRender ([bool]$detailBounds.fully_visible -and
            $detailBounds.actual.x -ge $cardBounds.x -and $detailBounds.actual.y -ge $cardBounds.y -and
            $detailBounds.actual.right -le $cardBounds.right -and $detailBounds.actual.bottom -le $cardBounds.bottom) `
            ("状态详情 $($status.detail) 超出卡片或被裁切。")
    }
    foreach ($controlName in @('ProfileMigrationText', 'ReceivePolicyPreviewText', 'MasterPresetBox', 'DestinationBox', 'SlotBox', 'CallKindBox', 'TransmitEnabledBox', 'ApplyNextTxTargetButton', 'GroupModeBox', 'PrivateModeBox', 'GroupRouteIdBox', 'GroupRouteSlotBox', 'GroupRoutesList', 'BlockedGroupIdBox', 'BlockedGroupSlotBox', 'BlockedGroupsList', 'PeerSourceIdBox', 'PeerLocalDestinationBox', 'PeerSlotBox', 'PeerRoutesList', 'LocalPrivateDestinationBox', 'LocalPrivateSlotBox', 'LocalPrivateRoutesList', 'BlockedSourceIdBox', 'BlockedSourcesList', 'PlaybackGainSlider', 'PlaybackGainSavedValueText', 'PlaybackGainRuntimeValueText', 'TransmitGainSlider')) {
        Assert-UiRender ([bool]$layout.settings.controls_visible.$controlName) ("设置窗口控件 $controlName 未显示。")
    }
    $listeningPanel = $layout.main.controls_bounds.ListeningHistoryPanel.actual
    foreach ($controlName in @('CurrentCallLabel', 'CurrentCallValue', 'CurrentCallDetail', 'IdentityLookupStatusValue', 'QueryCurrentIdentityButton', 'BlockCurrentSourceButton', 'CallHistoryList', 'SetHistoryCallTargetButton', 'QueryHistoryIdentityButton')) {
        $callBounds = $layout.main.controls_bounds.$controlName
        Assert-UiRender ([bool]$callBounds.fully_visible) ("收听与历史控件 $controlName 被裁切。")
        Assert-UiRender ($callBounds.actual.x -ge $listeningPanel.x -and $callBounds.actual.y -ge $listeningPanel.y -and
            $callBounds.actual.right -le $listeningPanel.right -and $callBounds.actual.bottom -le $listeningPanel.bottom) `
            ("收听与历史控件 $controlName 超出 A 区范围。")
    }
    $callChannel = $layout.main.controls_bounds.CallChannelPanel.actual
    foreach ($controlName in @('TransmitTargetValue','ActiveLeaseValue','CallTargetChoicesPanel','CallFavoritesList','FavoriteCurrentTargetButton','FavoriteManualGroupButton','ApplyCallFavoriteButton','RemoveCallFavoriteButton')) {
        $targetBounds = $layout.main.controls_bounds.$controlName
        Assert-UiRender ([bool]$targetBounds.fully_visible -and $targetBounds.actual.x -ge $callChannel.x -and
            $targetBounds.actual.y -ge $callChannel.y -and $targetBounds.actual.right -le $callChannel.right -and
            $targetBounds.actual.bottom -le $callChannel.bottom) ("呼叫目标控件 $controlName 超出 B 区或被裁切。")
    }
    Assert-UiRender ($layout.main.controls_bounds.CallFavoritesList.actual.height -le 50) '本机收藏列表没有保持有限高度。'
    $expandedDetailsPath = Join-Path $Directory 'radio-details-expanded-layout.json'
    if ([System.IO.File]::Exists($expandedDetailsPath)) {
        $expandedDetails = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($expandedDetailsPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
        Assert-UiRender ([bool]$expandedDetails.controls_bounds.RadioDetailsExpander.fully_visible -and
            [bool]$expandedDetails.controls_bounds.TrafficCard.visible.width -gt 0 -and
            [bool]$expandedDetails.controls_bounds.ControlStatusButton.visible.width -gt 0) `
            '展开并滚动后应可访问收听路由、来源管理和运行状态控件。'
        $sourceManagementButtons = @($expandedDetails.observed_source_buttons | Where-Object { $_.text -match '屏蔽.*来源|恢复来源' })
        $lastSourceManagementButton = if ($sourceManagementButtons.Count -gt 0) { $sourceManagementButtons[$sourceManagementButtons.Count - 1] } else { $null }
        Assert-UiRender ($sourceManagementButtons.Count -ge 2 -and $lastSourceManagementButton.is_visible -and
            $lastSourceManagementButton.fully_visible -and $lastSourceManagementButton.actual.width -gt 0 -and
            $lastSourceManagementButton.visible.width -gt 0) `
            '展开并滚到底部后，最后一张来源卡片的屏蔽/恢复动作仍须在视口内可达。'
    }
    $dashboardBottomPath = Join-Path $Directory 'dashboard-bottom-layout.json'
    if ([System.IO.File]::Exists($dashboardBottomPath)) {
        $dashboardBottom = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($dashboardBottomPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
        foreach ($controlName in @('DynamicGroupPanel','DynamicGroupIdBox','DynamicGroupSlotBox','SetDynamicCallTargetButton','AddListenGroupButton','ActivateDynamicGroupButton','DynamicGroupStatus')) {
            Assert-UiRender ([bool]$dashboardBottom.controls_bounds.$controlName.fully_visible) ("滚动到底部后快捷操作控件 $controlName 仍被裁切。")
        }
    }
    if ($MaximumHeight -le 700) {
        Assert-UiRender ($layout.main.event_list_height -ge 42 -and $layout.main.event_list_height -le 46) '小工作区运行记录区域高度不符合紧凑布局。'
    }
    $identity = $layout.main_source_identity
    Assert-UiRender ($identity.value -ceq '等待本次运行报告' -and
        $identity.radio_display -ceq 'FTX-1 屏幕：未知') '离线主窗口没有显示来源状态未知和电台屏显未知。'
    $mainVisualText = @($identity.visual_text)
    Assert-UiRender ($mainVisualText -ccontains 'HRI 来源标签' -and
        $mainVisualText -ccontains '等待本次运行报告' -and
        $mainVisualText -ccontains 'FTX-1 屏幕：未知') '主窗口来源标签或屏显文字没有进入 WPF 视觉树。'
    $expectedDeviceValues = @{ serial = 'COM5'; wave_input = '{render-input}'; wave_output = '{render-output}' }
    foreach ($comboName in @('serial', 'wave_input', 'wave_output')) {
        $evidence = $layout.device_combo_rendered_text.$comboName
        Assert-UiRender ($null -ne $evidence -and $evidence.expected_label -is [string]) ("缺少 $comboName 的 WPF 文字视觉证据。")
        $selectedTexts = @($evidence.selected_text)
        $dropdownTexts = @($evidence.dropdown_text)
        Assert-UiRender ($selectedTexts -ccontains [string]$evidence.expected_label) ("$comboName 选中框没有显示设备标签。")
        Assert-UiRender ($dropdownTexts -ccontains [string]$evidence.expected_label) ("$comboName 下拉列表没有显示设备标签。")
        Assert-UiRender ([string]$evidence.stable_value -ceq $expectedDeviceValues[$comboName] -and [bool]$evidence.available) ("$comboName 选中项没有保留稳定值或可用状态。")
        foreach ($text in @($selectedTexts + $dropdownTexts)) {
            Assert-UiRender ($text -notmatch '@\{(Label|Value|IsAvailable|Kind)=') ("$comboName 显示了 PowerShell 对象元数据。")
        }
    }
}

function Test-ConfiguredActiveCallLayout {
    param(
        [string]$Directory,
        [double]$MaximumWidth = [double]::PositiveInfinity,
        [double]$MaximumHeight = [double]::PositiveInfinity
    )
    Test-RenderedLayout -Directory $Directory -MaximumWidth $MaximumWidth -MaximumHeight $MaximumHeight
    $layoutPath = Join-Path $Directory 'layout-info.json'
    $layout = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($layoutPath, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
    Assert-UiRender ($layout.configured_profile.rx_policy.allow_groups.Count -eq 1 -and
        $layout.configured_profile.rx_policy.allow_groups[0].destination_id -eq 91 -and
        $layout.configured_profile.rx_policy.allow_groups[0].slot -eq 2 -and
        $layout.configured_profile.rx_policy.blocked_groups.Count -eq 1 -and
        $layout.configured_profile.rx_policy.blocked_groups[0].destination_id -eq 46001 -and
        $layout.configured_profile.rx_policy.blocked_source_ids.Count -eq 1 -and
        $layout.configured_profile.rx_policy.blocked_source_ids[0] -eq 3149877 -and
        $layout.configured_profile.rx_policy.private_mode -ceq 'all_peers_to_local' -and
        $layout.configured_profile.rx_policy.allow_private_peers.Count -eq 1 -and
        $layout.configured_profile.rx_policy.local_private_routes.Count -eq 1 -and
        $layout.configured_profile.tx_target.destination_id -eq 460997 -and
        $layout.configured_profile.tx_target.kind -ceq 'private' -and -not [bool]$layout.configured_profile.transmit_enabled) `
        '路由模拟场景没有保留 TG91、频道/来源屏蔽、本机私呼与禁发策略。'
    Assert-UiRender ($layout.radio_details_expanded -eq $false -and
        $layout.active_call.value -ceq 'TEST · DMR ID 3149876' -and
        $layout.active_call.detail -ceq '离线模拟：组呼 · 目标 91 · TS2 · CC 1 · LC 已验证 · 接收中') `
        '配置与来话模拟场景没有显示带数字 ID 的模拟呼号和详情。'
    $activeLease = $layout.main.controls_bounds.ActiveLeaseValue
    $nextTarget = $layout.main.controls_bounds.TransmitTargetValue
    Assert-UiRender ([bool]$activeLease.fully_visible -and [bool]$nextTarget.fully_visible -and
        $layout.active_call.current_tx_target -match '53000.*TS1' -and
        $layout.active_call.next_tx_target -match '460997.*TS2' -and
        $layout.active_call.current_tx_target -cne $layout.active_call.next_tx_target) `
        '当前发射锁定目标与下一发射目标没有分别显示，或样例目标不一致。'
    $targetsOverlapX = ($activeLease.actual.x -lt $nextTarget.actual.right -and $activeLease.actual.right -gt $nextTarget.actual.x)
    $targetsOverlapY = ($activeLease.actual.y -lt $nextTarget.actual.bottom -and $activeLease.actual.bottom -gt $nextTarget.actual.y)
    Assert-UiRender (-not ($targetsOverlapX -and $targetsOverlapY)) '当前发射目标和下一发射目标控件发生重叠。'
    Assert-UiRender ($layout.active_call.value -notmatch '[…]|\.\.\.' -and
        @($layout.active_call.visual_text) -ccontains 'TEST · DMR ID 3149876') '当前来话卡片用省略号遮住了模拟呼号或数字 ID。'
    Assert-UiRender (@($layout.active_call.visual_text) -ccontains $layout.active_call.value -and
        @($layout.active_call.visual_text) -ccontains $layout.active_call.detail) '模拟来话文字没有进入 WPF 视觉树。'
    Assert-UiRender ($layout.active_call.current_identity_details -match 'DMR ID 3149876' -and
        $layout.active_call.current_identity_details -match '姓名：Simulated Operator' -and
        $layout.active_call.current_identity_details -match '国家 Render Sample' -and
        $layout.active_call.current_identity_details -match '来源：本机缓存' -and
        $layout.active_call.current_identity_details -match '更新时间：' -and
        $layout.active_call.history_identity_details.Count -eq 2 -and
        (@($layout.active_call.history_identity_details) -join "`n") -match 'DMR ID 3149876') `
        '当前来话与历史行没有保留可用身份资料 Tooltip 文本。'
    Assert-UiRender ($layout.active_call.playback_gain_status -match '当前 1x' -and
        $layout.active_call.playback_gain_status -match '保存 5.959x' -and
        $layout.main.controls_bounds.PlaybackGainStatusValue.text -match '削波 0' -and
        $layout.main.controls_bounds.PlaybackGainStatusValue.tooltip -match '下次连接时生效' -and
        [double]$layout.main.controls_bounds.PlaybackGainStatusValue.actual.height -le 16) `
        '主界面音量状态应在单行显示运行值、保存值和削波计数，并在工具提示中说明下次连接生效。'
    Assert-UiRender ($layout.active_call.history_items.Count -eq 2 -and
        $layout.active_call.favorite_items.Count -eq 2 -and
        (@($layout.active_call.favorite_items) -join "`n") -match '本机静态收藏' -and
        (@($layout.active_call.favorite_items) -join "`n") -match '本机动态收藏') `
        'A区历史应按来话代次去重，B区应显示本机静态/动态分类收藏。'
    Assert-UiRender (@($layout.active_call.configured_routes_text) -ccontains 'Selected · TG 91 · TS2' -and
        @($layout.active_call.configured_routes_text) -ccontains '本地屏蔽 · TG 46001 · TS2' -and
        @($layout.active_call.configured_routes_text) -ccontains '跨组屏蔽 · DMR ID 3149877') '主窗口没有显示带样例策略的已配置路由。'
    $observedCards = @($layout.active_call.observed_cards)
    $groupCard = @($observedCards | Where-Object { $_.kind -ceq 'group' }) | Select-Object -First 1
    $privateCard = @($observedCards | Where-Object { $_.kind -ceq 'private' }) | Select-Object -First 1
    Assert-UiRender ($observedCards.Count -eq 2 -and $groupCard.source_id -eq 3149877 -and
        $groupCard.destination_id -eq 91 -and [bool]$groupCard.local_action_enabled -and
        $groupCard.source_action -ceq '恢复来源' -and -not [bool]$groupCard.tx_action_enabled -and
        $privateCard.source_id -eq 460997 -and $privateCard.destination_id -eq 3149876 -and
        [bool]$privateCard.local_action_enabled) '主窗口观察来源没有展示组呼与精确私呼卡片动作。'
    $settingsRouteLayoutPath = Join-Path (Split-Path -Parent $Directory) 'settings-routes-layout.json'
    if ([System.IO.File]::Exists($settingsRouteLayoutPath)) {
        $settingsRoutes = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($settingsRouteLayoutPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
        Assert-UiRender ($settingsRoutes.route_settings.group_routes -contains 'TG 91 · TS2' -and
            $settingsRoutes.route_settings.blocked_groups -contains 'TG 46001 · TS2' -and
            $settingsRoutes.route_settings.private_peers -contains 'peer 460997 → 本机 3149876 · TS2' -and
            $settingsRoutes.route_settings.local_private_routes -contains '发往本机 3149876 · TS1' -and
            $settingsRoutes.route_settings.blocked_sources -contains 'DMR ID 3149877') '设置窗口路由编辑区没有显示多路由样例列表。'
        Assert-UiRender ($settingsRoutes.route_settings.group_background -ceq '#FF191E21' -and
            $settingsRoutes.route_settings.group_foreground -ceq '#FFEDF1F2' -and
            $settingsRoutes.route_settings.selected_route_background -ceq '#FF355A42') '路由列表没有应用暗色背景、浅色文字和绿色选中项。'
        foreach ($controlName in @('GroupModeBox','PrivateModeBox','GroupRouteIdBox','GroupRoutesList','BlockedGroupIdBox','BlockedGroupsList','PeerSourceIdBox','PeerRoutesList','LocalPrivateDestinationBox','LocalPrivateRoutesList','BlockedSourceIdBox','BlockedSourcesList')) {
            Assert-UiRender ([bool]$settingsRoutes.settings.controls_visible.$controlName) ("设置窗口路由编辑控件 $controlName 未显示。")
        }
        foreach ($controlName in @('GroupModeBox','PrivateModeBox','GroupRouteIdBox','GroupRouteSlotBox','AddGroupRouteButton','GroupRoutesList')) {
            Assert-UiRender ([bool]$settingsRoutes.settings.controls_bounds.$controlName.fully_visible) ("设置窗口路由控件 $controlName 在路由截图中被裁切。")
        }
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiScript = Join-Path (Join-Path $repoRoot 'ui\windows') 'bridge-ui.ps1'
$uiLauncher = Join-Path $PSScriptRoot 'start-ui.ps1'
$uiCmd = Join-Path $PSScriptRoot 'start-ui.cmd'
$packageRoot = [System.IO.Path]::GetFullPath($PackageDirectory)
$powerShellExe = Join-Path $PSHOME 'powershell.exe'
if (-not [System.IO.File]::Exists($uiScript) -or -not [System.IO.File]::Exists($uiLauncher) -or -not [System.IO.File]::Exists($uiCmd)) { throw '缺少 WPF 界面或启动入口文件。' }
if (-not [System.IO.File]::Exists((Join-Path $packageRoot 'wirex_bridge.exe'))) { throw 'PackageDirectory 中缺少 native 核心。' }
if (-not [System.IO.File]::Exists($powerShellExe)) { throw '找不到 Windows PowerShell 5.1。' }

$testRoot = Join-Path $env:TEMP ('wirex-ui-render-' + [guid]::NewGuid().ToString('N'))
$configDirectory = Join-Path $testRoot 'empty-user-config'
$stagedPackage = Join-Path $testRoot 'package'
if ([string]::IsNullOrWhiteSpace($RenderOutputDirectory)) {
    $RenderOutputDirectory = Join-Path (Join-Path $repoRoot 'build\_work') ('ui-render-' + [guid]::NewGuid().ToString('N'))
}
$renderDirectory = [System.IO.Path]::GetFullPath($RenderOutputDirectory)
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($configDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $stagedPackage 'ui\windows')) | Out-Null
[System.IO.File]::Copy((Join-Path $packageRoot 'wirex_bridge.exe'), (Join-Path $stagedPackage 'wirex_bridge.exe'), $false)
[System.IO.File]::Copy((Join-Path $packageRoot 'start-bm-radio-bridge.ps1'), (Join-Path $stagedPackage 'start-bm-radio-bridge.ps1'), $false)
[System.IO.File]::Copy((Join-Path $repoRoot 'tools\bridge-user-config.psm1'), (Join-Path $stagedPackage 'bridge-user-config.psm1'), $false)
foreach ($name in @('bridge-ui.ps1', 'BridgeSupervisor.cs', 'MainWindow.xaml', 'SettingsWindow.xaml', 'RadioIdentity.psm1')) {
    [System.IO.File]::Copy((Join-Path (Join-Path $repoRoot 'ui\windows') $name), (Join-Path (Join-Path $stagedPackage 'ui\windows') $name), $false)
}
[System.IO.Directory]::CreateDirectory($renderDirectory) | Out-Null

# The explicit package selected for this UI run must take precedence over a
# stale or unavailable cross-version pointer in the shared user configuration.
$stalePointerPath = Join-Path $configDirectory 'bridge-directory.txt'
[System.IO.File]::WriteAllText($stalePointerPath, (Join-Path $testRoot 'missing-release'), (New-Object System.Text.UTF8Encoding($true)))

try {
    $cmdBytes = [System.IO.File]::ReadAllBytes($uiCmd)
    $cmdText = [System.Text.Encoding]::ASCII.GetString($cmdBytes)
    Assert-UiRender (-not ($cmdBytes.Length -ge 3 -and $cmdBytes[0] -eq 239 -and $cmdBytes[1] -eq 187 -and $cmdBytes[2] -eq 191)) 'start-ui.cmd 不应包含 UTF-8 BOM。'
    Assert-UiRender (@($cmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'start-ui.cmd 必须只包含 ASCII 字节。'
    Assert-UiRender ([regex]::Matches($cmdText, "`r`n").Count -eq ([regex]::Matches($cmdText, "`n").Count)) 'start-ui.cmd 必须使用纯 CRLF 换行。'
    Assert-UiRender ($cmdText.Contains('start-ui.ps1')) 'CMD 入口未调用同目录 PowerShell 启动器。'

    & $powerShellExe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $uiLauncher `
        -PackageDirectory $stagedPackage -UserConfigDirectory $configDirectory `
        -OfflinePreview -RenderOnly -RenderWorkArea '1280x900' -RenderOutputDirectory $renderDirectory
    $exitCode = [int]$LASTEXITCODE
    Assert-UiRender ($exitCode -eq 0) ("WPF 离线渲染进程退出码为 $exitCode。")

    foreach ($name in @('main-window.png', 'settings-window.png','main-routing-fixture.png','dashboard-bottom.png','radio-details-expanded.png','settings-routes.png','settings-private-routes.png')) {
        $path = Join-Path $renderDirectory $name
        Assert-UiRender ([System.IO.File]::Exists($path)) ("缺少渲染结果：$name")
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-UiRender ($bytes.Length -ge 1024) ("渲染结果过小：$name")
        $signature = @(137, 80, 78, 71, 13, 10, 26, 10)
        for ($index = 0; $index -lt $signature.Count; $index++) {
            Assert-UiRender ($bytes[$index] -eq $signature[$index]) ("PNG 签名无效：$name")
        }
        $width = ([int64]$bytes[16] * 16777216) + ([int64]$bytes[17] * 65536) + ([int64]$bytes[18] * 256) + $bytes[19]
        $height = ([int64]$bytes[20] * 16777216) + ([int64]$bytes[21] * 65536) + ([int64]$bytes[22] * 256) + $bytes[23]
        Assert-UiRender ($width -ge 700 -and $height -ge 450) ("渲染窗口尺寸异常：$name (${width}x${height})")
        Assert-UiRender (Test-PngHasPixelDiversity -Path $path) ("渲染结果为黑帧或缺少可见界面像素：$name")
    }
    Test-RenderedLayout -Directory $renderDirectory
    Test-ConfiguredActiveCallLayout -Directory (Join-Path $renderDirectory 'configured-active-call')
    Assert-UiRender (Test-PngHasPixelDiversity -Path (Join-Path (Join-Path $renderDirectory 'configured-active-call') 'main-window.png')) '配置来话截图为黑帧或没有可见界面像素。'

    $smallRenderDirectory = Join-Path $renderDirectory 'work-area-1024x728'
    [System.IO.Directory]::CreateDirectory($smallRenderDirectory) | Out-Null
    & $powerShellExe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $uiLauncher `
        -PackageDirectory $stagedPackage -UserConfigDirectory $configDirectory -OfflinePreview -RenderOnly `
        -RenderWorkArea '1024x728' -RenderOutputDirectory $smallRenderDirectory
    $smallExitCode = [int]$LASTEXITCODE
    Assert-UiRender ($smallExitCode -eq 0) ("小工作区 WPF 渲染退出码为 $smallExitCode。")
    Test-RenderedLayout -Directory $smallRenderDirectory -MaximumWidth 972 -MaximumHeight 692
    Test-ConfiguredActiveCallLayout -Directory (Join-Path $smallRenderDirectory 'configured-active-call') -MaximumWidth 972 -MaximumHeight 692
    Assert-UiRender (Test-PngHasPixelDiversity -Path (Join-Path (Join-Path $smallRenderDirectory 'configured-active-call') 'main-window.png')) '小工作区配置来话截图为黑帧或没有可见界面像素。'

    $invalidPackage = Join-Path $testRoot 'invalid-package'
    [System.IO.Directory]::CreateDirectory($invalidPackage) | Out-Null
    & $powerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $uiLauncher -PackageDirectory $invalidPackage -OfflinePreview
    $errorExitCode = [int]$LASTEXITCODE
    Assert-UiRender ($errorExitCode -eq 2) ("损坏包目录应从启动器返回退出码 2，实际为 $errorExitCode。")

    Write-Output ("通过：Windows PowerShell 5.1 的离线包根启动链已渲染 1280x900 与 1024x728 主界面及设置窗口；A收听/历史、B起呼目标/收藏、身份详情 Tooltip 和音量状态均通过布局检查；错误包返回退出码 2；没有启动 native 核心或访问设备。结果：{0}" -f $renderDirectory)
} finally {
    if ([System.IO.Directory]::Exists($testRoot)) { [System.IO.Directory]::Delete($testRoot, $true) }
}
