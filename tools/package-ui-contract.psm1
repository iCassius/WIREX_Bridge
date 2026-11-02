$script:wirexR123UiAssertions = 0
function Assert-WirexR123Ui {
    param([bool]$Condition,[string]$Message)
    $script:wirexR123UiAssertions++
    if (-not $Condition) { throw ('R123 UI 包合同失败：' + $Message) }
}
function Get-WirexR123NamedNode {
    param([xml]$Document,[string]$Name)
    $nodes = @($Document.SelectNodes("//*[@*[local-name()='Name']='$Name']"))
    if ($nodes.Count -ne 1) { throw ('R123 XAML 控件 {0} 数量应为 1，实为 {1}。' -f $Name,$nodes.Count) }
    return $nodes[0]
}
function Get-WirexR123GridRows {
    param([System.Xml.XmlNode]$Grid)
    $container = $Grid.SelectSingleNode("./*[local-name()='Grid.RowDefinitions']")
    if (-not $container) { throw 'R123 XAML 预期 Grid.RowDefinitions，但 XPath 未命中。' }
    return @($container.SelectNodes("./*[local-name()='RowDefinition']"))
}
function Get-WirexR123GridColumns {
    param([System.Xml.XmlNode]$Grid)
    $container = $Grid.SelectSingleNode("./*[local-name()='Grid.ColumnDefinitions']")
    if (-not $container) { throw 'R123 XAML 预期 Grid.ColumnDefinitions，但 XPath 未命中。' }
    return @($container.SelectNodes("./*[local-name()='ColumnDefinition']"))
}
function Test-WirexR123UiPackageContract {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot)
    $script:wirexR123UiAssertions = 0
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    $mainPath = Join-Path $root 'ui\windows\MainWindow.xaml'
    $settingsPath = Join-Path $root 'ui\windows\SettingsWindow.xaml'
    foreach ($path in @($mainPath,$settingsPath)) {
        if (-not [System.IO.File]::Exists($path)) { throw ('缺少窗口 XAML：' + $path) }
    }
    try {
        $main = [xml][System.IO.File]::ReadAllText($mainPath,[System.Text.Encoding]::UTF8)
        $settingsText = [System.IO.File]::ReadAllText($settingsPath,[System.Text.Encoding]::UTF8)
        $settings = [xml]$settingsText
    } catch { throw ('窗口 XAML XML 解析失败：' + $_.Exception.Message) }
    $window = $main.DocumentElement
    Assert-WirexR123Ui ($window.LocalName -ceq 'Window' -and $window.GetAttribute('Width') -ceq '1360' -and $window.GetAttribute('Height') -ceq '900') '主窗口尺寸不是 1360×900'
    $consoleRoot = Get-WirexR123NamedNode $main 'ConsoleRoot'
    $rootRows = @(Get-WirexR123GridRows $consoleRoot)
    Assert-WirexR123Ui ($rootRows.Count -eq 3 -and $rootRows[0].GetAttribute('Height') -ceq '32' -and $rootRows[1].GetAttribute('Height') -ceq '370') '主窗口上区行定义不符合 R123 固定布局'
    $dashboard = Get-WirexR123NamedNode $main 'DashboardPanel'
    $dashboardColumns = @(Get-WirexR123GridColumns $dashboard)
    Assert-WirexR123Ui ($dashboardColumns.Count -eq 2 -and @($dashboardColumns | Where-Object { $_.GetAttribute('Width') -ceq '1*' }).Count -eq 2) '下方区域不是等宽两列'
    $cards = Get-WirexR123NamedNode $main 'ChannelCardsPanel'
    Assert-WirexR123Ui ($cards.GetAttribute('Rows') -ceq '2' -and $cards.GetAttribute('Columns') -ceq '3') '频道卡不是 3×2'
    $nav = Get-WirexR123NamedNode $main 'ChannelPageNav'
    Assert-WirexR123Ui ($nav.GetAttribute('Visibility') -ceq 'Collapsed') '频道分页行未默认折叠'
    $consoleTop = Get-WirexR123NamedNode $main 'ConsoleTop'
    $topRows = @(Get-WirexR123GridRows $consoleTop)
    Assert-WirexR123Ui ($topRows.Count -eq 2 -and $topRows[1].GetAttribute('Height') -ceq '120') '历史区域固定外框不是 120 px'
    $historyFrame = Get-WirexR123NamedNode $main 'RadioDetailsExpander'
    $historyGrid = $historyFrame.SelectSingleNode("./*[local-name()='Grid']")
    $historyRows = @(Get-WirexR123GridRows $historyGrid)
    $historyList = Get-WirexR123NamedNode $main 'CallHistoryList'
    Assert-WirexR123Ui ($historyRows.Count -eq 2 -and $historyRows[0].GetAttribute('Height') -ceq '28' -and $historyList.GetAttribute('Height') -ceq '82') '历史标题行或五行列表尺寸不符'
    $configPanel = Get-WirexR123NamedNode $main 'ConnectionConfigPanel'
    $configGrid = $configPanel.SelectSingleNode("./*[local-name()='Grid']")
    $configRows = @(Get-WirexR123GridRows $configGrid)
    Assert-WirexR123Ui ($configRows.Count -eq 7 -and $configRows[0].GetAttribute('Height') -ceq '24' -and $configRows[6].GetAttribute('Height') -ceq '36' -and @($configRows[1..5] | Where-Object { $_.GetAttribute('Height') -cne '*' }).Count -eq 0) '连接配置未使用固定标题、五个等高行和底部操作行'
    $serial = Get-WirexR123NamedNode $main 'ConnectionRowSerial'
    $serialColumns = @(Get-WirexR123GridColumns $serial)
    Assert-WirexR123Ui ($serialColumns.Count -eq 3 -and $serialColumns[0].GetAttribute('Width') -ceq '1*' -and $serialColumns[1].GetAttribute('Width') -ceq '2*' -and $serialColumns[2].GetAttribute('Width') -ceq '1*') '串口设置行列宽不符'
    [void](Get-WirexR123NamedNode $main 'SerialConnectButton')
    [void](Get-WirexR123NamedNode $main 'TransientStatusText')
    [void](Get-WirexR123NamedNode $main 'ConnectionConfigTitleText')
    $cat = Get-WirexR123NamedNode $main 'CatOperatingPanel'
    $catColumns = @(Get-WirexR123GridColumns $cat)
    Assert-WirexR123Ui ($catColumns.Count -eq 3 -and @($catColumns | Where-Object { $_.GetAttribute('Width') -ceq '1*' }).Count -eq 3) 'CAT 模式、频率、功率列没有等宽'
    $mode = Get-WirexR123NamedNode $main 'CatMainModeBox'
    $frequency = Get-WirexR123NamedNode $main 'CatMainFrequencyMHzBox'
    $power = Get-WirexR123NamedNode $main 'CatPowerBox'
    $powerTags = @($power.SelectNodes("./*[local-name()='ComboBoxItem']") | ForEach-Object { $_.GetAttribute('Tag') })
    Assert-WirexR123Ui ($mode.LocalName -ceq 'ComboBox' -and $frequency.LocalName -ceq 'ComboBox' -and $frequency.GetAttribute('IsEditable') -ceq 'True' -and $power.LocalName -ceq 'ComboBox' -and @($powerTags) -contains '5' -and @($powerTags) -contains '10' -and @($powerTags) -contains '15' -and @($powerTags) -contains '25' -and @($powerTags) -contains '50') 'CAT 模式、频率编辑或五档功率预设缺失'
    foreach ($catName in @('CatModeCaptionText','CatFrequencyCaptionText','CatPowerCaptionText','CatObservedPanel','CatObservedMainModeText','CatObservedFrequencyText','CatObservedPowerText')) {
        [void](Get-WirexR123NamedNode $main $catName)
    }
    $applyNodes = @($main.SelectNodes("//*[@*[local-name()='Name']='ApplyCatSettingsButton']"))
    Assert-WirexR123Ui ($applyNodes.Count -eq 1) 'CAT 应用按钮不唯一'
    $channelId = Get-WirexR123NamedNode $main 'ChannelIdBox'
    Assert-WirexR123Ui ($channelId.LocalName -ceq 'ComboBox' -and $channelId.GetAttribute('IsEditable') -ceq 'True') '频道 ID 不是可编辑组合框'
    $overlay = Get-WirexR123NamedNode $main 'StaticApiRequiredOverlay'
    $hint = Get-WirexR123NamedNode $main 'StaticApiRequiredText'
    $groupList = Get-WirexR123NamedNode $main 'BmStaticGroupsList'
    Assert-WirexR123Ui ($hint.GetAttribute('Text') -ceq '需启用BM API key' -and $hint.ParentNode -eq $overlay -and $overlay.ParentNode -eq $groupList.ParentNode) '静态组 API 提示没有覆盖列表'
    foreach ($oldName in @('FooterText','BmDetail','SerialDisconnectButton','CatSessionStatusText','CatOperationStatusText','CatPowerSlider','CatDesiredPowerText','DisconnectBmButton','ConnectionLockValue','ChannelStatusText','BmStaticGroupStatus','PlaybackGainStatusValue','HiddenRuntimeControls')) {
        Assert-WirexR123Ui (@($main.SelectNodes("//*[@*[local-name()='Name']='$oldName']")).Count -eq 0) ('仍包含已移除控件 ' + $oldName)
    }
    $daily = Get-WirexR123NamedNode $main 'DailyControlsPanel'
    Assert-WirexR123Ui (@($daily.SelectNodes(".//*[local-name()='Border']")).Count -eq 0) '日常控制卡片内部仍有装饰边框'
    Assert-WirexR123Ui (@($main.SelectNodes("//*[local-name()='ScrollViewer' and not(ancestor::*[local-name()='Popup'])]")).Count -eq 0 -and @($settings.SelectNodes("//*[local-name()='ScrollViewer']")).Count -eq 0) '主窗口区域或设置窗口含滚动查看器'
    Assert-WirexR123Ui ($settingsText -notmatch 'TS1|TS2|时隙|切换PTT') '设置窗口包含过时 TS/PTT 说明'
    return [pscustomobject]@{ assertions=$script:wirexR123UiAssertions; main_xaml=$mainPath; settings_xaml=$settingsPath }
}
Export-ModuleMember -Function Test-WirexR123UiPackageContract
