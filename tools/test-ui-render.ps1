#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertionCount = 0

function Assert-UiRender {
    param([Parameter(Mandatory=$true)][bool]$Condition,[Parameter(Mandatory=$true)][string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-UiRenderBom {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-UiRender ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        ("UTF-8 BOM missing: {0}" -f [System.IO.Path]::GetFileName($Path))
}

function Get-UiRenderRect {
    param([Parameter(Mandatory=$true)][object]$Layout,[Parameter(Mandatory=$true)][string]$Name)
    $entry = $Layout.main.controls_bounds.PSObject.Properties[$Name]
    if (-not $entry -or $null -eq $entry.Value.actual) { throw "布局 JSON 缺少 $Name 的实际边界。" }
    return $entry.Value.actual
}

function Assert-UiRenderNoInputOverlap {
    param([Parameter(Mandatory=$true)][object]$Layout,[Parameter(Mandatory=$true)][string]$Label)
    $names = @(
        'StopButton','RefreshDevicesButton','SerialBox','CatPortBox','CatBaudRateBox','SerialConnectButton','SerialDisconnectButton',
        'CatMainModeBox','CatMainFrequencyMHzBox','CatPowerSlider','ApplyCatSettingsButton',
        'CallsignBox','SourceBox','DeviceNumberBox','MasterPresetBox','MasterPortBox','MasterBox','BmApiKeyBox','PasswordBox',
        'ConnectButton','DisconnectBmButton','SaveSettingsButton','ChannelPagePreviousButton','ChannelPageNextButton',
        'CallHistoryPagePreviousButton','CallHistoryPageNextButton','SetHistoryCallTargetButton','CallHistoryList',
        'ChannelIdBox','ChannelKindBox','AddChannelButton','BmStaticGroupsList',
        'BmStaticGroupPagePreviousButton','BmStaticGroupPageNextButton','RefreshBmStaticGroupsButton','RemoveBmStaticGroupButton',
        'BmStaticGroupIdBox','AddBmStaticGroupButton','WaveInEndpointBox','WaveOutEndpointBox',
        'PlaybackGainSlider','TransmitGainSlider'
    )
    $rects = @()
    foreach ($name in $names) {
        $visibleProperty = $Layout.main.controls_visible.PSObject.Properties[$name]
        Assert-UiRender ($null -ne $visibleProperty) "$Label 布局信息没有记录 $name 的可见状态。"
        if (-not [bool]$visibleProperty.Value) { continue }
        $rect = Get-UiRenderRect -Layout $Layout -Name $name
        Assert-UiRender ($rect.width -gt 0 -and $rect.height -gt 0) "$Label 可见控件 $name 没有实际尺寸。"
        $rects += [pscustomobject]@{ Name=$name; Rect=$rect }
    }
    for ($i=0; $i -lt $rects.Count; $i++) {
        for ($j=$i + 1; $j -lt $rects.Count; $j++) {
            $a=$rects[$i]; $b=$rects[$j]
            $overlapX = [Math]::Min([double]$a.Rect.right,[double]$b.Rect.right) - [Math]::Max([double]$a.Rect.x,[double]$b.Rect.x)
            $overlapY = [Math]::Min([double]$a.Rect.bottom,[double]$b.Rect.bottom) - [Math]::Max([double]$a.Rect.y,[double]$b.Rect.y)
            Assert-UiRender ($overlapX -le 0.5 -or $overlapY -le 0.5) "$Label 输入/按钮 $($a.Name) 与 $($b.Name) 的实际可见范围重叠。"
        }
    }
    $channelPanel = Get-UiRenderRect -Layout $Layout -Name 'ChannelCardsPanel'
    $channelButtons = @()
    foreach ($card in @($Layout.channel_card_layout | Where-Object { -not $_.blank })) {
        $buttonBounds = @($card.buttons_bounds)
        Assert-UiRender ($buttonBounds.Count -eq @($card.buttons).Count -and [int]$card.action_count -eq 4) `
            "$Label 频道卡没有为每个实际操作按钮提供边界或没有保留四格操作区。"
        $visibleButtonBounds = @($buttonBounds | Where-Object { $_.visible })
        foreach ($buttonText in @($card.buttons)) {
            Assert-UiRender (@($visibleButtonBounds | Where-Object { @($_.text) -contains [string]$buttonText }).Count -gt 0) `
                "$Label 频道卡操作 $buttonText 没有对应的可见按钮实际边界。"
        }
        foreach ($button in $visibleButtonBounds) {
            $buttonRect = [pscustomobject]@{
                x=[double]$button.x; y=[double]$button.y
                width=[double]$button.width; height=[double]$button.height
                right=([double]$button.x + [double]$button.width)
                bottom=([double]$button.y + [double]$button.height)
            }
            Assert-UiRender ($buttonRect.width -gt 0 -and $buttonRect.height -gt 0 -and
                $buttonRect.x -ge ($channelPanel.x - 1) -and $buttonRect.y -ge ($channelPanel.y - 1) -and
                $buttonRect.right -le ($channelPanel.right + 1) -and $buttonRect.bottom -le ($channelPanel.bottom + 1)) `
                "$Label 频道卡动态按钮 $($button.name) 超出频道卡面板或没有实际尺寸。"
            $channelButtons += [pscustomobject]@{ Name=[string]$button.action; Rect=$buttonRect }
        }
    }
    for ($i=0; $i -lt $channelButtons.Count; $i++) {
        for ($j=$i + 1; $j -lt $channelButtons.Count; $j++) {
            $a=$channelButtons[$i]; $b=$channelButtons[$j]
            $overlapX = [Math]::Min($a.Rect.right,$b.Rect.right) - [Math]::Max($a.Rect.x,$b.Rect.x)
            $overlapY = [Math]::Min($a.Rect.bottom,$b.Rect.bottom) - [Math]::Max($a.Rect.y,$b.Rect.y)
            Assert-UiRender ($overlapX -le 0.5 -or $overlapY -le 0.5) "$Label 频道卡按钮 $($a.Name) 与 $($b.Name) 的实际边界重叠。"
        }
    }
}

function Assert-UiRenderLayout {
    param([Parameter(Mandatory=$true)][string]$LayoutPath,[Parameter(Mandatory=$true)][string]$RenderDirectory,[Parameter(Mandatory=$true)][string]$Label)
    if (-not [System.IO.File]::Exists($LayoutPath)) { throw "$Label 未生成 layout-info.json。" }
    $layout = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($LayoutPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $main = $layout.main
    $top = Get-UiRenderRect -Layout $layout -Name 'ConsoleTop'
    $dashboard = Get-UiRenderRect -Layout $layout -Name 'DashboardPanel'
    $left = Get-UiRenderRect -Layout $layout -Name 'ConnectionConfigPanel'
    $right = Get-UiRenderRect -Layout $layout -Name 'DailyControlsPanel'
    $serialRow = Get-UiRenderRect -Layout $layout -Name 'ConnectionRowSerial'
    $radioRow = Get-UiRenderRect -Layout $layout -Name 'CatOperatingPanel'
    $audioRow = Get-UiRenderRect -Layout $layout -Name 'AudioDevicePanel'
    $audioFields = Get-UiRenderRect -Layout $layout -Name 'ConnectionRowAudio'
    $volumePanel = Get-UiRenderRect -Layout $layout -Name 'VolumeControlsPanel'
    $bmRow = Get-UiRenderRect -Layout $layout -Name 'ConnectionRowBm'
    $actionRow = Get-UiRenderRect -Layout $layout -Name 'ConnectionRowActions'
    $connect = Get-UiRenderRect -Layout $layout -Name 'ConnectButton'
    $disconnectBm = Get-UiRenderRect -Layout $layout -Name 'DisconnectBmButton'
    $save = Get-UiRenderRect -Layout $layout -Name 'SaveSettingsButton'
    $serialConnect = Get-UiRenderRect -Layout $layout -Name 'SerialConnectButton'
    $serialDisconnect = Get-UiRenderRect -Layout $layout -Name 'SerialDisconnectButton'
    $serialSelector = Get-UiRenderRect -Layout $layout -Name 'SerialBox'
    $catModeInput = Get-UiRenderRect -Layout $layout -Name 'CatMainModeBox'
    $catFrequencyInput = Get-UiRenderRect -Layout $layout -Name 'CatMainFrequencyMHzBox'
    $catPowerInput = Get-UiRenderRect -Layout $layout -Name 'CatPowerSlider'
    $catApply = Get-UiRenderRect -Layout $layout -Name 'ApplyCatSettingsButton'
    $catStatus = Get-UiRenderRect -Layout $layout -Name 'CatOperationStatusText'
    $channelIdInput = Get-UiRenderRect -Layout $layout -Name 'ChannelIdBox'
    $channelKindInput = Get-UiRenderRect -Layout $layout -Name 'ChannelKindBox'
    $addChannel = Get-UiRenderRect -Layout $layout -Name 'AddChannelButton'
    $audioInput = Get-UiRenderRect -Layout $layout -Name 'WaveInEndpointBox'
    $audioOutput = Get-UiRenderRect -Layout $layout -Name 'WaveOutEndpointBox'
    Assert-UiRender ($main.controls_bounds.ConsoleTop.fully_visible -and $main.controls_bounds.DashboardPanel.fully_visible) "$Label 上下区域没有完整显示。"
    Assert-UiRender ($main.controls_bounds.ConnectionConfigPanel.fully_visible -and $main.controls_bounds.DailyControlsPanel.fully_visible) "$Label 左右区域没有完整显示。"
    Assert-UiRender ($main.controls_bounds.ConnectButton.fully_visible -and $main.controls_bounds.DisconnectBmButton.fully_visible -and
        $main.controls_bounds.SaveSettingsButton.fully_visible -and $main.controls_bounds.SerialConnectButton.fully_visible -and
        $main.controls_bounds.SerialDisconnectButton.fully_visible) "$Label BM 或串口连接/断开/保存按钮被裁切。"
    foreach ($name in @('ConnectionRowSerial','CatOperatingPanel','ConnectionRowBm','ConnectionRowActions','AudioDevicePanel','ConnectionRowAudio','VolumeControlsPanel')) {
        $rowEntry = $main.controls_bounds.PSObject.Properties[$name]
        Assert-UiRender ($rowEntry -and $rowEntry.Value.fully_visible) "$Label 连接区第 $name 布局行未完整显示。"
    }
    Assert-UiRender ($top.bottom -le ($dashboard.y + 1)) "$Label 上下区域发生覆盖。"
    Assert-UiRender ($left.right -le ($right.x + 1)) "$Label 左右区域发生覆盖。"
    $leftRatio = $left.width / $dashboard.width
    Assert-UiRender ($leftRatio -ge 0.48 -and $leftRatio -le 0.52 -and [Math]::Abs($left.width - $right.width) -le 2) "$Label 左右区域没有保持严格50:50。"
    Assert-UiRender ($connect.bottom -le $left.bottom -and $disconnectBm.bottom -le $left.bottom -and $save.bottom -le $left.bottom -and
        $serialRow.y -ge $left.y -and $radioRow.y -ge $serialRow.bottom -and
        $bmRow.y -ge $radioRow.bottom -and $actionRow.y -ge $bmRow.bottom -and $actionRow.bottom -le $left.bottom) `
        "$Label 左侧配置发生重叠或超出固定区域。"
    Assert-UiRender ([Math]::Abs($serialSelector.height - $serialConnect.height) -le 1 -and
        [Math]::Abs($serialSelector.bottom - $serialConnect.bottom) -le 1 -and
        [Math]::Abs($serialSelector.height - $serialDisconnect.height) -le 1 -and
        [Math]::Abs($serialSelector.bottom - $serialDisconnect.bottom) -le 1) "$Label 串口选择框和连接/断开按钮没有同高并对齐底边。"
    Assert-UiRender ($audioRow.x -ge $right.x -and $audioRow.right -le $right.right -and
        $audioFields.y -ge $audioRow.y -and $audioFields.bottom -le $audioRow.bottom -and
        $audioRow.bottom -le $volumePanel.y + 1 -and $volumePanel.bottom -le $right.bottom) `
        "$Label 音频输入/输出没有完整放在右侧音量控制上方。"
    Assert-UiRender ([Math]::Abs($channelIdInput.height - $addChannel.height) -le 1 -and
        [Math]::Abs($channelKindInput.height - $addChannel.height) -le 1 -and
        [Math]::Abs($channelIdInput.bottom - $addChannel.bottom) -le 1 -and
        [Math]::Abs($channelKindInput.bottom - $addChannel.bottom) -le 1) "$Label 加入监听按钮没有与频道输入框同高、对齐底边。"
    $bmStatus = Get-UiRenderRect -Layout $layout -Name 'BmStatusCard'
    $bmRtt = Get-UiRenderRect -Layout $layout -Name 'BmRttMetric'
    $bmRttValue = Get-UiRenderRect -Layout $layout -Name 'BmRttValue'
    $bmLoss = Get-UiRenderRect -Layout $layout -Name 'BmLossMetric'
    $bmLossValue = Get-UiRenderRect -Layout $layout -Name 'BmLossValue'
    $lossText = [string]$layout.main.controls_bounds.BmLossValue.text
    $lossValid = [bool]$layout.bm_loss_valid
    $title = Get-UiRenderRect -Layout $layout -Name 'MainTitleText'
    $stop = Get-UiRenderRect -Layout $layout -Name 'StopButton'
    $bmTitleCenter = $bmStatus.y + ($bmStatus.height / 2)
    $titleCenter = $title.y + ($title.height / 2)
    $lossVisible = [bool]$main.controls_visible.BmLossMetric -and [bool]$main.controls_visible.BmLossValue
    Assert-UiRender ([Math]::Abs($bmTitleCenter - $titleCenter) -le 1 -and $title.right -le $bmStatus.x -and $bmStatus.right -le $stop.x -and
        $bmRttValue.width -gt 0 -and $layout.main.controls_bounds.BmRttValue.text -match '42 ms' -and
        (($lossValid -and $lossVisible -and $bmLossValue.width -gt 0 -and $lossText -match '^\d+(\.\d+)?%$') -or
            (-not $lossValid -and -not $lossVisible -and $lossText -ceq ''))) `
        "$Label BM连接状态、RTT和有效loss没有集中显示，或无有效loss时仍显示占位值。"
    $footer = Get-UiRenderRect -Layout $layout -Name 'FooterText'
    Assert-UiRender ($footer.x -ge $title.right -and $footer.right -le $stop.x -and $main.controls_visible.FooterText -and
        $main.controls_bounds.FooterText.text -match '离线预览' -and -not $main.controls_visible.OfflineBanner -and
        -not $main.controls_visible.SettingsErrorText) "$Label 成功/失败事件没有集中在顶部状态区，或旧banner/配置错误行仍单独显示。"
    $catMode = Get-UiRenderRect -Layout $layout -Name 'CatObservedMainModeText'
    $catFrequency = Get-UiRenderRect -Layout $layout -Name 'CatObservedFrequencyText'
    $catPower = Get-UiRenderRect -Layout $layout -Name 'CatObservedPowerText'
    $catModeCenter = $catMode.y + ($catMode.height / 2)
    $catFrequencyCenter = $catFrequency.y + ($catFrequency.height / 2)
    $catPowerCenter = $catPower.y + ($catPower.height / 2)
    Assert-UiRender ([Math]::Abs($catModeCenter - $catFrequencyCenter) -le 1 -and [Math]::Abs($catModeCenter - $catPowerCenter) -le 5 -and
        $catMode.right -le $catFrequency.x -and $catFrequency.right -le $catPower.x -and
        $catMode.x -ge $radioRow.x -and $catPower.right -le $radioRow.right) `
        "$Label MAIN模式、频率和功率没有占用互不覆盖的固定列范围。"
    Assert-UiRender ($catModeInput.width -ge 110 -and $catFrequencyInput.width -ge 140 -and $catPowerInput.width -ge 125 -and
        $catModeInput.x -lt $catFrequencyInput.x -and $catFrequencyInput.right -le $catPowerInput.x + 1 -and
        $catPowerInput.right -le $catApply.x + 1 -and $catApply.right -le $radioRow.right) `
        "$Label CAT模式、频率、功率输入列过窄或没有按顺序留在同一行。"
    Assert-UiRender ($catStatus.y -ge [Math]::Max($catModeInput.bottom,$catFrequencyInput.bottom) -and
        $catStatus.y -ge $catApply.bottom -and $catStatus.bottom -le $radioRow.bottom -and $catStatus.right -le $radioRow.right) `
        "$Label CAT操作结果行与输入控件或CAT卡片边界发生重叠。"
    Assert-UiRender ($xamlText -match 'Text="功率 W"' -and $xamlText -match 'Text="当前"' -and
        $xamlText -match 'x:Name="CatDesiredPowerText"') "$Label 功率行没有分别标明当前值和目标值。"
    Assert-UiRender ($layout.channel_list_present -eq $false) "$Label 仍显示下方重复频道清单。"
    Assert-UiRender (-not [bool]$main.controls_visible.CoreStatusCard -and -not [bool]$main.controls_visible.RadioStatusCard -and
        -not [bool]$main.controls_visible.AudioStatusCard) "$Label 顶部仍显示核心、电台或音频状态卡。"
    $contrast = @($layout.combo_contrast)
    Assert-UiRender ($contrast.Count -ge 5) "$Label ComboBox 对比度记录不完整。"
    foreach ($combo in $contrast) {
        Assert-UiRender ($combo.background -match '^#FF' -and $combo.foreground -match '^#FF' -and
            $combo.popup_background -match '^#FF') ("$Label ComboBox $($combo.name) 的闭合或展开状态缺少深色底和可读前景。")
        if ($combo.name -cne 'CatPortBox') {
            Assert-UiRender ($combo.popup_text.Count -gt 0) ("$Label ComboBox $($combo.name) 下拉列表没有可读项目。")
        }
        Assert-UiRender ($combo.background -cne $combo.foreground -and $combo.popup_background -cne $combo.foreground) ("$Label ComboBox $($combo.name) 前景和背景颜色相同。")
    }
    $normal = Join-Path $RenderDirectory 'main-window.png'
    $advanced = Join-Path $RenderDirectory 'settings-window.png'
    Assert-UiRender ([System.IO.File]::Exists($normal) -and (New-Object System.IO.FileInfo($normal)).Length -gt 50000) "$Label 没有生成完整主窗口截图。"
    Assert-UiRender ([System.IO.File]::Exists($advanced) -and (New-Object System.IO.FileInfo($advanced)).Length -gt 1000) "$Label 没有生成频道高级设置截图。"
    Assert-UiRender ($layout.history_count -ge 4 -and $layout.history_visible_count -eq 3 -and $layout.history_page_text -ceq '1 / 2') `
        "$Label 来话历史没有固定显示三条并提供完整分页。"
    Assert-UiRender ($layout.history_page_probe.first_page_count -eq 3 -and $layout.history_page_probe.second_page_count -eq 2 -and
        $layout.history_page_probe.second_page_text -ceq '2 / 2') "$Label 来话历史翻页没有保留最后两条记录。"
    $historyRows = @($layout.history_page_probe.visual.rows)
    Assert-UiRender ($historyRows.Count -eq 3 -and
        @($historyRows | Where-Object { -not $_.container_fully_visible -or -not $_.text_fully_visible -or
            -not $_.text_inside_list_bounds }).Count -eq 0) "$Label 来话历史三条实际行容器或文字仍被裁切。"
    $history = Get-UiRenderRect -Layout $layout -Name 'RadioDetailsExpander'
    $historyList = Get-UiRenderRect -Layout $layout -Name 'CallHistoryList'
    Assert-UiRender ($history.height -ge 78 -and $history.height -le 82 -and $historyList.height -ge 48) "$Label 来话历史没有保持固定三行区域。"
    Assert-UiRender ($main.controls_visible.CallHistoryPagePreviousButton -and $main.controls_visible.CallHistoryPageNextButton -and
        $main.controls_visible.CallHistoryPageText) "$Label 来话历史分页控件没有显示。"
    Assert-UiRender ($main.controls_visible.BmStaticGroupPagePreviousButton -and $main.controls_visible.BmStaticGroupPageNextButton -and
        $main.controls_visible.BmStaticGroupPageText) "$Label BM静态组分页控件没有显示。"
    $bmStaticPanel = Get-UiRenderRect -Layout $layout -Name 'BmStaticGroupPanel'
    Assert-UiRender ($layout.bm_static_group_count -eq 4 -and $layout.bm_static_group_visible_count -eq 3 -and
        $layout.bm_static_group_page_text -ceq '1 / 2' -and $layout.bm_static_group_page_probe.first_page_count -eq 3 -and
        $layout.bm_static_group_page_probe.second_page_count -eq 1 -and $layout.bm_static_group_page_probe.second_page_text -ceq '2 / 2' -and
        $main.controls_bounds.BmStaticGroupPanel.fully_visible -and @($layout.bm_static_group_text).Count -eq 3 -and
        @($layout.bm_static_group_text | Where-Object { $_ -match '时隙|slot|TS[12]' }).Count -eq 0) `
        "$Label BM静态组列表没有固定三项并保留完整翻页，或仍显示 slot 文案。"
    Assert-UiRender (@($layout.caller_card_text) -contains 'TEST · Sample Operator') "$Label 频道卡没有显示呼号和姓名。"
    Assert-UiRender (@($layout.caller_card_text) -notcontains '暂无来话' -and
        @($layout.caller_card_text) -notcontains '✓ 已选为下次呼叫目标') "$Label 空频道或已选目标重复显示了说明文字。"
    Assert-UiRender (-not $layout.favorites_present -and -not $layout.transmit_enabled_control_present -and -not $layout.stop_bits_control_present) `
        "$Label 仍显示收藏、发射开关或停止位控件。"
    Assert-UiRender (@($layout.channel_card_layout).Count -eq 6 -and $layout.page_navigation.slot_count -eq 6) "$Label 监听区没有保持固定六个显示槽。"
    Assert-UiRender (@($layout.channel_card_layout | Where-Object { -not $_.blank }).Count -eq [Math]::Min(6,@($layout.channel_cards).Count) -and
        (@($layout.channel_card_layout | Where-Object { $_.blank }).Count -gt 0)) "$Label 空槽数量与配置频道数不一致。"
    Assert-UiRender (@($layout.channel_card_layout | Where-Object { $_.blank }).Count -eq 3 -and
        @($layout.channel_card_layout | Where-Object { $_.blank -and ($_.text.Count -gt 0 -or $_.buttons.Count -gt 0) }).Count -eq 0) `
        "$Label 空频道槽没有保持低对比空白显示。"
    Assert-UiRender (@($layout.channel_card_layout | Where-Object { $_.call_active }).Count -gt 0 -and
        @($layout.channel_card_layout | Where-Object { -not $_.blank -and -not $_.call_active }).Count -gt 0) "$Label 渲染样本没有同时包含来话卡和空闲卡。"
    Assert-UiRender (-not $layout.page_navigation.visible) "$Label 六个以内的频道仍显示分页控件。"
    $callHeights = @($layout.channel_card_layout | Where-Object { -not $_.blank } | ForEach-Object { [double]$_.call_area_height } | Select-Object -Unique)
    Assert-UiRender ($callHeights.Count -eq 1 -and [Math]::Abs($callHeights[0] - 76) -le 1) "$Label 来话区没有保持固定高度。"
    $cardHeights = @($layout.channel_card_layout | Where-Object { -not $_.blank } | ForEach-Object { [double]$_.height } | Select-Object -Unique)
    Assert-UiRender ($cardHeights.Count -eq 1 -and $cardHeights[0] -gt 100) "$Label 来话期间频道卡尺寸发生变化或没有填满单元格。"
    $cardsWithActions = @($layout.channel_card_layout | Where-Object { -not $_.blank })
    $actionWidthRatios = @($cardsWithActions | ForEach-Object {
        [double]$_.action_area_width / ([double]$_.card_body_width * (0.9 / (1.25 + 0.9)))
    } | Select-Object -Unique)
    $callWidthRatios = @($cardsWithActions | ForEach-Object {
        [double]$_.call_area_width / ([double]$_.card_body_width * (1.25 / (1.25 + 0.9)))
    } | Select-Object -Unique)
    $callerToActionRatios = @($cardsWithActions | ForEach-Object { [double]$_.call_area_width / [double]$_.action_area_width } | Select-Object -Unique)
    Assert-UiRender ($actionWidthRatios.Count -eq 1 -and $actionWidthRatios[0] -ge 0.70 -and $actionWidthRatios[0] -le 0.80 -and
        $callWidthRatios.Count -eq 1 -and $callWidthRatios[0] -ge 1.15 -and $callWidthRatios[0] -le 1.30 -and
        $callerToActionRatios.Count -eq 1 -and $callerToActionRatios[0] -ge 1.6) "$Label 2×2按钮区宽度没有比R120缩小20%至30%，或呼号/来话区没有扩大15%至30%。"
    foreach ($card in @($layout.channel_card_layout)) {
        if ($card.blank) { continue }
        Assert-UiRender ($card.action_count -eq 4) "$Label 频道卡没有为2×2操作区保留四个固定格子。"
        Assert-UiRender ($card.buttons -contains '取消监听' -and
            @($card.buttons | Where-Object { $_ -in @('临时屏蔽','恢复收听') }).Count -eq 1) `
            "$Label 频道卡没有显示取消监听和屏蔽/恢复操作。"
        Assert-UiRender (@($card.buttons | Where-Object { $_ -in @('设为呼叫','✓ 呼叫目标','呼叫目标','当前起呼') }).Count -eq 1) `
            "$Label 频道卡没有显示选择下次呼叫目标或已选状态。"
        Assert-UiRender (-not (@($card.text) -match 'TS[12]|更多|时隙设置')) "$Label 频道卡仍显示时隙或更多菜单入口。"
    }
    Assert-UiRender (@($layout.channel_card_layout | Where-Object { $_.buttons -contains '激活组' }).Count -gt 0) "$Label 组呼频道没有直接激活组操作。"
    Assert-UiRender (@($layout.channel_card_layout | Where-Object { -not $_.blank -and $_.buttons.Count -eq 3 }).Count -gt 0) "$Label 私呼卡第四格没有留空。"
    $bmTitleCenter = $layout.main.controls_bounds.BmStatusCard.actual.y + ($layout.main.controls_bounds.BmStatusCard.actual.height / 2)
    $appTitleCenter = $layout.main.controls_bounds.MainTitleText.actual.y + ($layout.main.controls_bounds.MainTitleText.actual.height / 2)
    Assert-UiRender ([Math]::Abs($bmTitleCenter - $appTitleCenter) -le 18) "$Label BM状态没有显示在应用标题的统一状态区域。"
    Assert-UiRender ($layout.combo_interaction.cat_port.opened -and -not $layout.combo_interaction.cat_port.handled -and
        $layout.combo_interaction.cat_port.editable_text_preserved) "$Label 点击 CAT 可编辑端口区域没有展开列表或影响手工输入。"
    Assert-UiRender ($layout.main.controls_visible.SerialConnectButton -and $layout.main.controls_visible.SerialDisconnectButton -and
        $layout.main.controls_visible.CatSessionStatusText) "$Label 串口连接/断开控件或CAT状态没有放入左侧连接区。"
    Assert-UiRender (@($layout.main.controls_bounds.SerialConnectButton.visual_text) -contains '连接串口' -and
        @($layout.main.controls_bounds.SerialDisconnectButton.visual_text) -contains '断开串口' -and
        @($layout.main.controls_bounds.ConnectButton.visual_text) -contains '连接BM' -and
        @($layout.main.controls_bounds.DisconnectBmButton.visual_text) -contains '断开BM') "$Label 串口与BM连接/断开按钮文字不准确。"
    Assert-UiRender ($main.area_scrollviewer_count -eq 0 -and $main.non_popup_scrollbar_count -eq 0) `
        "$Label 窗口可见树仍包含区域滚动查看器或可见滚动条。"
    Assert-UiRenderNoInputOverlap -Layout $layout -Label $Label
    return $layout
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$xamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
$settingsXamlPath = Join-Path $repoRoot 'ui\windows\SettingsWindow.xaml'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw '请使用 -STA 运行 WPF RenderOnly 回归。'
}
foreach ($path in @($PSCommandPath,$uiPath,$xamlPath,$settingsXamlPath)) {
    if (-not [System.IO.File]::Exists($path)) { throw "缺少渲染目标：$path" }
    Assert-UiRenderBom -Path $path
}
foreach ($path in @($uiPath)) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "bridge-ui.ps1 parse failed: $($parseErrors[0].Message)" }
}
$xamlDocument = [xml][System.IO.File]::ReadAllText($xamlPath,[System.Text.Encoding]::UTF8)
$settingsXamlDocument = [xml][System.IO.File]::ReadAllText($settingsXamlPath,[System.Text.Encoding]::UTF8)
$xamlText = [System.IO.File]::ReadAllText($xamlPath,[System.Text.Encoding]::UTF8)
$settingsXamlText = [System.IO.File]::ReadAllText($settingsXamlPath,[System.Text.Encoding]::UTF8)
foreach ($required in @('BmApiKeySetupLink','BmPasswordSetupLink','SerialBox','CatPortBox','CatBaudRateBox','ChannelIdBox','ChannelKindBox','AddChannelButton',
        'ChannelCardsPanel','ChannelPagePreviousButton','ChannelPageText','ChannelPageNextButton','SerialConnectButton','SerialDisconnectButton',
        'CatSessionStatusText','DisconnectBmButton','BmLossValue','ConnectionRowSerial','CatOperatingPanel','ConnectionRowAudio','AudioDevicePanel','VolumeControlsPanel','ConnectionRowBm',
        'CatMainModeBox','CatMainFrequencyMHzBox','CatPowerSlider','ApplyCatSettingsButton','CatOperationStatusText','SourceBox','DeviceNumberBox','WaveInEndpointBox','WaveOutEndpointBox',
        'ConnectionRowActions','CallHistoryPagePreviousButton','CallHistoryPageText','CallHistoryPageNextButton',
        'BmStaticGroupPagePreviousButton','BmStaticGroupPageText','BmStaticGroupPageNextButton')) {
    Assert-UiRender ($xamlText -match ('x:Name="' + [regex]::Escape($required) + '"')) "XAML 缺少 $required。"
}
Assert-UiRender ($xamlText -match 'Rows="2" Columns="3"' -and $xamlText -notmatch 'ChannelAdvancedButton|ChannelSlotBox') '频道面板没有固定3×2格，或仍暴露时隙入口。'
Assert-UiRender ($xamlText -notmatch 'CoreStatusCard|RadioStatusCard|AudioStatusCard') '主界面仍定义核心、电台或音频状态卡。'
Assert-UiRender ($xamlText -match 'x:Name="FooterText" Grid.Row="1" Grid.Column="1"' -and $xamlText -notmatch 'x:Name="FooterText"[^>]*Grid.ColumnSpan') '事件消息没有放在标题中央统一状态区。'
Assert-UiRender ($xamlText -match 'Width="1360" Height="900" MinWidth="1360" MinHeight="900" ResizeMode="CanMinimize"') '主窗口没有使用固定1360×900最小尺寸。'
Assert-UiRender ($xamlText -match 'Grid.ColumnDefinitions><ColumnDefinition Width="1\*"/><ColumnDefinition Width="1\*"/></Grid.ColumnDefinitions>') 'Dashboard没有使用等宽两列。'
Assert-UiRender ($xamlText -match 'x:Name="ApplyCatSettingsButton"[^>]*Content="应用"' -and
    $xamlText -notmatch 'ApplyCatModeButton|ApplyCatFrequencyButton|ApplyCatPowerButton' -and
    ([regex]::Matches($xamlText,'x:Name="ApplyCatSettingsButton"')).Count -eq 1) 'CAT设置区没有只保留唯一的“应用”按钮。'
Assert-UiRender ($xamlText -match 'x:Name="CatMainModeBox"[^>]*MinWidth="116"' -and
    $xamlText -match 'x:Name="CatMainFrequencyMHzBox"[^>]*MinWidth="145"' -and
    $xamlText -match 'x:Name="CatPowerSlider"[^>]*MinWidth="135"') 'CAT模式/频率/功率输入没有保留可读宽度。'
Assert-UiRender ($xamlText -match 'x:Name="CatOperationStatusText"[^>]*Text=""[^>]*TextTrimming="CharacterEllipsis"' -and
    $xamlText -match 'x:Name="CatOperationStatusText"[^>]*ToolTip="\{Binding RelativeSource=\{RelativeSource Self\}, Path=Text\}"') `
    'CAT逐项反馈状态行没有保留省略显示和完整内容提示。'
Assert-UiRender ($xamlText -match 'x:Name="DeviceNumberBox" MaxLength="2"' -and
    $xamlText -notmatch 'GatewayBox|ColorCodeBox|MakeChannelTxTargetCheckBox|同时设为PTT目标|切换PTT') '旧网关/色码/加入PTT控件或切换说明仍留在XAML。'
foreach ($name in @('ChannelConsolePanel','BmStaticGroupPanel','AudioDevicePanel','VolumeControlsPanel')) {
    $node = $xamlDocument.SelectSingleNode("//*[@*[local-name()='Name']='$name']")
    Assert-UiRender ($node -and $node.LocalName -ceq 'Grid') "$name 没有使用无内嵌边框的布局容器。"
    $borderAncestors = @($node.SelectNodes("ancestor::*[local-name()='Border']"))
    Assert-UiRender ($borderAncestors.Count -eq 1 -and $borderAncestors[0].GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -ceq 'DailyControlsPanel') "$name 内部仍套有视觉边框。"
}
$dailyPanelNode = $xamlDocument.SelectSingleNode("//*[@*[local-name()='Name']='DailyControlsPanel']")
$dailyNestedBorders = @($dailyPanelNode.SelectNodes("descendant::*[local-name()='Border']"))
Assert-UiRender ($dailyNestedBorders.Count -eq 0) '日常控制外卡片中仍有内嵌装饰边框。'
Assert-UiRender ($xamlText -match 'StackPanel x:Name="BmStatusCard"' -and $xamlText -notmatch 'Border x:Name="BmStatusCard"') 'BM状态仍被单独绘制成状态卡。'
Assert-UiRender ($xamlText -match 'x:Name="BmLossMetric"[^>]*Visibility="Collapsed"' -and $xamlText -match 'x:Name="BmLossValue" Text=""') '没有有效loss采样时BM loss没有默认隐藏。'
Assert-UiRender ($xamlText -notmatch '<Border x:Name="OfflineBanner"[^>]*Grid.Row=' -and
    $xamlText -match 'StackPanel x:Name="HiddenRuntimeControls"[^>]*Visibility="Collapsed"') '离线提示或配置错误仍占主界面独立可见行。'
Assert-UiRender ($settingsXamlText -notmatch 'TS1|TS2|时隙|切换PTT') '频道说明窗口仍显示时隙或PTT切换说明。'
Assert-UiRender ($xamlText -notmatch 'x:Name="ChannelListPanel"') 'XAML 仍包含重复频道清单控件。'
Assert-UiRender ($xamlText -notmatch 'ReadRadioButton|读取电台|CatConnectButton|CatDisconnectButton' -and $xamlText -match 'Content="连接串口"' -and
    $xamlText -match 'Content="断开串口"' -and $xamlText -match 'Content="连接BM"' -and $xamlText -match 'Content="断开BM"') '主窗口仍显示旧读取按钮，或串口/BM连接控制文字错误。'
Assert-UiRender ($xamlText -match 'Text="播放增益"' -and $xamlText -match 'Text="发送增益"' -and
    $xamlText -notmatch 'BM → 电台播放|手咪 → BM 发送') '音量标签没有保持简短且准确。'
Assert-UiRender ($xamlText -notmatch 'ConnectionScrollViewer|DashboardScrollViewer|VerticalScrollBarVisibility="Auto"|HorizontalScrollBarVisibility="Auto"') '主界面固定区域仍设置了区域滚动条。'
Assert-UiRender ($xamlText -match 'x:Name="CallHistoryList"[^>]*Padding="0"[^>]*BorderThickness="0"' -and
    $xamlText -match 'Property="Height" Value="15"' -and $xamlText -match 'Property="MinHeight" Value="15"' -and
    $xamlText -match 'Property="BorderThickness" Value="0"' -and $xamlText -match 'Property="Padding" Value="0"' -and
    $xamlText -match 'Property="FontSize" Value="11"') '历史列表项没有固定压缩到三行可见高度。'
Assert-UiRender ($xamlText -match 'Text="\{Binding talkgroup, StringFormat=''TG \{0\}''\}"') 'BM静态组列表没有只显示 TG 号码。'
$areaScrollViewers = @($xamlDocument.SelectNodes("//*[local-name()='ScrollViewer' and not(ancestor::*[local-name()='Popup'])]"))
Assert-UiRender ($areaScrollViewers.Count -eq 0) '主界面在下拉弹出窗口之外仍有ScrollViewer。'
$popupScrollViewers = @($xamlDocument.SelectNodes("//*[local-name()='ScrollViewer' and ancestor::*[local-name()='Popup']]"))
Assert-UiRender ($popupScrollViewers.Count -eq 1) 'ComboBox下拉弹出列表没有保留键盘/分页式导航容器。'
$listBoxes = @($xamlDocument.SelectNodes("//*[local-name()='ListBox']"))
Assert-UiRender ($listBoxes.Count -eq 2) '主界面历史和BM静态组列表数量不是预期的2个。'
foreach ($listBox in $listBoxes) {
    $vertical = $listBox.Attributes | Where-Object Name -ceq 'ScrollViewer.VerticalScrollBarVisibility' | Select-Object -First 1
    $horizontal = $listBox.Attributes | Where-Object Name -ceq 'ScrollViewer.HorizontalScrollBarVisibility' | Select-Object -First 1
    Assert-UiRender ($vertical -and $vertical.Value -ceq 'Disabled' -and $horizontal -and $horizontal.Value -ceq 'Disabled') '列表区域仍可显示横向或纵向滚动条。'
}
Assert-UiRender (@($settingsXamlDocument.SelectNodes("//*[local-name()='ScrollViewer']")).Count -eq 0) '频道说明窗口包含滚动区域。'

$taskRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-r122-render-' + [guid]::NewGuid().ToString('N'))))
$package = Join-Path $taskRoot 'package'
$config = Join-Path $taskRoot 'config'
[void][System.IO.Directory]::CreateDirectory($package)
[void][System.IO.Directory]::CreateDirectory($config)
# RenderOnly checks these package markers, but never starts either file.
[System.IO.File]::WriteAllText((Join-Path $package 'start-bm-radio-bridge.ps1'),'')
[System.IO.File]::WriteAllText((Join-Path $package 'wirex_bridge.exe'),'')

$referenceLayout = $null
$fixedControlNames = @('MainTitleText','ConsoleTop','ChannelCardsPanel','RadioDetailsExpander','DashboardPanel','ConnectionConfigPanel','DailyControlsPanel',
    'ConnectionRowSerial','CatOperatingPanel','ConnectionRowAudio','ConnectionRowBm','ConnectionRowActions',
    'AudioDevicePanel','VolumeControlsPanel','SerialBox','SerialConnectButton','SerialDisconnectButton','CatMainModeBox','CatMainFrequencyMHzBox','CatPowerSlider','ApplyCatSettingsButton','CatOperationStatusText',
    'SourceBox','DeviceNumberBox','WaveInEndpointBox','WaveOutEndpointBox','ChannelIdBox','ChannelKindBox','AddChannelButton',
    'ConnectButton','DisconnectBmButton','SaveSettingsButton')
foreach ($case in @(
    [pscustomobject]@{ Label='default-1360x900'; Size='1360x900'; Directory=(Join-Path $taskRoot 'default') },
    [pscustomobject]@{ Label='minimum-1360x900'; Size='1360x900'; Directory=(Join-Path $taskRoot 'minimum') }
)) {
    [void][System.IO.Directory]::CreateDirectory($case.Directory)
    $childOutput = @(& powershell.exe -NoLogo -NoProfile -STA -File $uiPath -RenderOnly -NoAutoConnect `
        -UserConfigDirectory $config -PackageDirectory $package -RenderOutputDirectory $case.Directory -RenderWorkArea $case.Size 2>&1)
    $childExitCode = $LASTEXITCODE
    if ($childExitCode -ne 0) { throw ("$($case.Label) RenderOnly exited ${childExitCode}: " + ($childOutput -join "`n")) }
    $currentLayout = Assert-UiRenderLayout -LayoutPath (Join-Path $case.Directory 'layout-info.json') -RenderDirectory $case.Directory -Label $case.Label
    if ($null -eq $referenceLayout) {
        $referenceLayout = $currentLayout
    } else {
        foreach ($name in $fixedControlNames) {
            $first = $referenceLayout.main.controls_bounds.PSObject.Properties[$name].Value.actual
            $current = $currentLayout.main.controls_bounds.PSObject.Properties[$name].Value.actual
            Assert-UiRender ([Math]::Abs([double]$first.x - [double]$current.x) -le 1 -and
                [Math]::Abs([double]$first.y - [double]$current.y) -le 1 -and
                [Math]::Abs([double]$first.width - [double]$current.width) -le 1 -and
                [Math]::Abs([double]$first.height - [double]$current.height) -le 1) `
                "default和minimum截图中的$name没有保持相同固定位置。"
        }
    }
}
Assert-UiRender (@(Get-ChildItem -LiteralPath $config -Force -ErrorAction Stop).Count -eq 0) 'RenderOnly 将 synthetic config 写入测试目录。'

Write-Output ("PASS: test-ui-render.ps1 ({0} RenderOnly layout/contrast assertions; output={1})" -f $script:assertionCount,$taskRoot)
