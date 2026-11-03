#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$script:assertionCount=0
function Assert-Ui { param([bool]$Ok,[string]$Why) $script:assertionCount++; if(-not $Ok){throw "ASSERTION FAILED [$script:assertionCount]: $Why"} }
function Assert-Bom { param([string]$Path) $b=[IO.File]::ReadAllBytes($Path); Assert-Ui ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) ("UTF-8 BOM missing: "+[IO.Path]::GetFileName($Path)) }
function Node { param([xml]$Doc,[string]$Name) $n=@($Doc.SelectNodes("//*[@*[local-name()='Name']='$Name']")); if($n.Count -ne 1){throw "XAML控件$Name数量异常：$($n.Count)"}; return $n[0] }
function Rows { param([System.Xml.XmlNode]$N) $d=$N.SelectSingleNode("./*[local-name()='Grid.RowDefinitions']"); if(-not $d){throw '缺少Grid.RowDefinitions'}; @($d.SelectNodes("./*[local-name()='RowDefinition']")) }
function Cols { param([System.Xml.XmlNode]$N) $d=$N.SelectSingleNode("./*[local-name()='Grid.ColumnDefinitions']"); if(-not $d){throw '缺少Grid.ColumnDefinitions'}; @($d.SelectNodes("./*[local-name()='ColumnDefinition']")) }
function Rect { param([object]$L,[string]$N) $p=$L.main.controls_bounds.PSObject.Properties[$N]; if(-not $p -or -not $p.Value.actual){throw "布局缺少${N}边界"}; $p.Value.actual }
function Luminance { param([string]$Color) $h=$Color.TrimStart('#');if($h.Length -eq 8){$h=$h.Substring(2)};$v=@();for($i=0;$i -lt 6;$i+=2){$c=[Convert]::ToInt32($h.Substring($i,2),16)/255.0;$v+= $(if($c -le .04045){$c/12.92}else{[Math]::Pow(($c+.055)/1.055,2.4)})};(.2126*$v[0]+.7152*$v[1]+.0722*$v[2]) }
function Contrast { param([string]$Foreground,[string]$Background) $a=Luminance $Foreground;$b=Luminance $Background;$hi=[Math]::Max($a,$b);$lo=[Math]::Min($a,$b);($hi+.05)/($lo+.05) }
function Get-UiVisualTextBlock {
 param([System.Windows.DependencyObject]$Root)
 if($Root -is [System.Windows.Controls.TextBlock]){return $Root}
 for($i=0;$i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root);$i++){$found=Get-UiVisualTextBlock -Root ([System.Windows.Media.VisualTreeHelper]::GetChild($Root,$i));if($found){return $found}}
 return $null
}
function Find-UiTextBlock {
 param([System.Windows.DependencyObject]$Root,[string]$Text)
 if($Root -is [System.Windows.Controls.TextBlock] -and [string]$Root.Text -ceq $Text){return $Root}
 for($i=0;$i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root);$i++){$found=Find-UiTextBlock -Root ([System.Windows.Media.VisualTreeHelper]::GetChild($Root,$i)) -Text $Text;if($found){return $found}}
 return $null
}
function Save-WpfFixtureScreenshot {
 param([System.Windows.Window]$Window,[string]$Path)
 $width=[int][Math]::Ceiling($Window.ActualWidth);$height=[int][Math]::Ceiling($Window.ActualHeight)
 if($width -le 0 -or $height -le 0){throw 'WPF fixture没有实际窗口尺寸，无法保存截图'}
 $bitmap=New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($Window);$encoder=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
 [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create($Path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function Assert-ThreeStaticGroupRows {
 param([string]$XamlPath,[string]$ScreenshotPath)
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
 $app=New-Object System.Windows.Application;$app.ShutdownMode=[System.Windows.ShutdownMode]::OnExplicitShutdown
 $stream=[IO.File]::OpenRead($XamlPath);$window=$null
 try{$window=[System.Windows.Markup.XamlReader]::Load($stream)}finally{$stream.Dispose()}
 try{
  $window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Opacity=1;$window.WindowStartupLocation=[System.Windows.WindowStartupLocation]::Manual;$window.Left=-32000;$window.Top=-32000
  $list=$window.FindName('BmStaticGroupsList');$overlay=$window.FindName('StaticApiRequiredOverlay');$overlay.Visibility=[System.Windows.Visibility]::Collapsed;$list.Items.Clear()
  $fixtureIds=[uint64[]]@(91,46001,12345);foreach($id in $fixtureIds){[void]$list.Items.Add([pscustomobject]@{talkgroup=$id})}
  $window.Show();$window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Render)
  $listOrigin=$list.TranslatePoint([System.Windows.Point]::new(0,0),$window);$listBottom=$listOrigin.Y+$list.ActualHeight-1
  for($i=0;$i -lt 3;$i++){
   $item=$list.ItemContainerGenerator.ContainerFromIndex($i);Assert-Ui ($item -and $item.IsVisible -and $item.ActualHeight -gt 0) ("合成静态组第{0}行没有生成可见ItemContainer" -f ($i+1))
   $origin=$item.TranslatePoint([System.Windows.Point]::new(0,0),$window);$text=Get-UiVisualTextBlock -Root $item
   Assert-Ui ($text -and $text.ActualHeight -gt 0 -and $origin.Y -ge ($listOrigin.Y+1) -and ($origin.Y+$item.ActualHeight) -le ($listBottom+.5) -and ($origin.Y+$text.ActualHeight) -le ($listBottom+.5)) ("合成静态组第{0}行的文字超出49px列表可视边界：listY={1} listBottom={2} itemY={3} itemHeight={4} textHeight={5}" -f ($i+1),$listOrigin.Y,$listBottom,$origin.Y,$item.ActualHeight,$text.ActualHeight)
   Assert-Ui ($text.Text -ceq ('TG {0}' -f $fixtureIds[$i])) ("合成静态组第{0}行文字绑定不完整" -f ($i+1))
  }
  Assert-Ui ([int]$list.Items.Count -eq 3) '49px静态组列表没有同时容纳三条合成数据'
  $list.IsEnabled=$false;$busyRefresh=$window.FindName('RefreshBmStaticGroupsButton');$busyRefresh.IsEnabled=$false;$busyRefresh.Content='刷新中…';$window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Render)
  $disabledChrome=$list.Template.FindName('ListBoxChrome',$list)
  Assert-Ui ($disabledChrome -and $disabledChrome.BorderBrush.ToString()-ceq '#FF263138' -and $disabledChrome.Background.ToString()-ceq '#FF151C20') '刷新忙碌态ListBox外框没有实际套用灰色Chrome模板'
  for($i=0;$i -lt 3;$i++){
   $item=$list.ItemContainerGenerator.ContainerFromIndex($i);$text=Get-UiVisualTextBlock -Root $item
   $chrome=$item.Template.FindName('ItemChrome',$item)
   Assert-Ui (-not $item.IsEnabled -and $item.Background.ToString()-ceq '#FF151C20' -and $item.Foreground.ToString()-ceq '#FF758188' -and $chrome.Background.ToString()-ceq '#FF151C20' -and $text.Foreground.ToString()-ceq '#FF758188') ("刷新读取忙碌态静态组第{0}行没有套用暗色ItemTemplate及灰色文字" -f ($i+1))
  }
  if($ScreenshotPath){
   Save-WpfFixtureScreenshot -Window $window -Path $ScreenshotPath
   Add-Type -AssemblyName System.Drawing
   $busyImage=[System.Drawing.Bitmap]::FromFile($ScreenshotPath)
   try{
    $borderX=[int][Math]::Round($listOrigin.X+($list.ActualWidth/2));$borderY=[int][Math]::Round($listOrigin.Y)
    $borderPixel=$busyImage.GetPixel($borderX,$borderY)
    Assert-Ui ($borderPixel.R-eq 38 -and $borderPixel.G-eq 49 -and $borderPixel.B-eq 56) ("截图中禁用ListBox顶部边框像素不是灰色#263138：#{0:X2}{1:X2}{2:X2}" -f $borderPixel.R,$borderPixel.G,$borderPixel.B)
   }finally{$busyImage.Dispose()}
  }
  $window.FindName('ConnectionConfigTitleText').Text='Connection and device settings'
  $window.FindName('RefreshDevicesButton').Content='Refresh devices'
  $window.FindName('StopButton').Content='Stop and exit'
  $window.FindName('LanguageToggleButton').Content='English'
  $window.FindName('ConnectButton').Content='Connect to BrandMeister'
  $window.FindName('SaveSettingsButton').Content='Save configuration'
  $window.FindName('AddBmStaticGroupButton').Content='Add as a static group'
  $busyRefresh.Content='Refreshing groups…'
  $window.FindName('RemoveBmStaticGroupButton').Content='Remove selected'
  $window.FindName('BmStaticGroupPageText').Text='Page 1 of 10'
  $dynamicLabel=Find-UiTextBlock -Root $window -Text '增加动态组 频道ID';$staticLabel=Find-UiTextBlock -Root $window -Text '增加BM静态组'
  Assert-Ui ($dynamicLabel -and $staticLabel) '英文长文案fixture找不到动态/静态组标签'
  $dynamicLabel.Text='Add dynamic group · Channel ID';$staticLabel.Text='Add BrandMeister static group'
  $window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Render)
  $refreshDevices=$window.FindName('RefreshDevicesButton');Assert-Ui ([double]$refreshDevices.ActualWidth-ge 100) '英文长文案刷新设备按钮实际宽度不足'
  if($ScreenshotPath){$englishPath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($ScreenshotPath),'bm-static-groups-english-long-copy.png');Save-WpfFixtureScreenshot -Window $window -Path $englishPath}
  Assert-Ui ($list.Items.Count -eq 3 -and -not $list.IsEnabled) '英文长文案fixture没有保留3条禁用静态组'
 }finally{if($window){$window.Close()};$app.Shutdown()}
}
function Test-BluePixel {
 param([System.Drawing.Color]$Color)
 return ($Color.B -gt ($Color.G+40) -and $Color.G -gt ($Color.R+35))
}
function Assert-GainTrackJunction {
 param([string]$ImagePath,[object]$Layout,[int]$GainLevel,[string]$Label)
 Add-Type -AssemblyName System.Drawing
 $bitmap=[System.Drawing.Bitmap]::FromFile($ImagePath)
 try{
  foreach($name in @('PlaybackGainSlider','TransmitGainSlider')){
   $slider=Rect $Layout $name
   $center=[int][Math]::Round($slider.x+15+(($GainLevel-1)/15.0*($slider.width-30)))
   $y=[int][Math]::Round($slider.y+($slider.height/2))
   $before=$bitmap.GetPixel($center-15,$y);$edge=$bitmap.GetPixel($center-14,$y);$after=$bitmap.GetPixel($center+15,$y)
   if($GainLevel -eq 1){Assert-Ui (-not (Test-BluePixel $before) -and -not (Test-BluePixel $edge)) "$Label $name最小刻度仍画出蓝色增益填充"}
   else{Assert-Ui ((Test-BluePixel $before) -and -not ($edge.R -eq 86 -and $edge.G -eq 89 -and $edge.B -eq 94)) "$Label $name在${GainLevel}x处蓝色填充没有延伸到旋钮曲线外缘"}
   Assert-Ui (-not (Test-BluePixel $after)) "$Label $name在${GainLevel}x处蓝色填充越过旋钮或灰色轨道末端"
  }
 }finally{$bitmap.Dispose()}
}
function Check-Render {
 param([string]$LayoutPath,[string]$Dir,[string]$Label,[int]$GainLevel)
 if(-not [IO.File]::Exists($LayoutPath)){throw "$Label缺少layout-info.json"}; foreach($f in @('main-window.png','settings-window.png')){if(-not [IO.File]::Exists((Join-Path $Dir $f))){throw "$Label缺少$f截图"}}
 Add-Type -AssemblyName System.Drawing;$screenshot=[System.Drawing.Image]::FromFile((Join-Path $Dir 'main-window.png'));try{Assert-Ui ($screenshot.Width -eq 1360 -and $screenshot.Height -eq 900) "$Label主窗口截图尺寸不是1360x900"}finally{$screenshot.Dispose()}
 $l=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($LayoutPath,[Text.Encoding]::UTF8));$m=$l.main
 $top=Rect $l 'ConsoleTop';$dash=Rect $l 'DashboardPanel';$left=Rect $l 'ConnectionConfigPanel';$right=Rect $l 'DailyControlsPanel'
 Assert-Ui ($m.controls_bounds.ConsoleTop.fully_visible -and $m.controls_bounds.DashboardPanel.fully_visible -and $m.controls_bounds.ConnectionConfigPanel.fully_visible -and $m.controls_bounds.DailyControlsPanel.fully_visible) "$Label固定区域被裁切"
 Assert-Ui ($top.bottom -le ($dash.y+1) -and [Math]::Abs($left.width-$right.width) -le 2 -and [Math]::Abs($left.width/$dash.width-.5) -le .01) "$Label区域覆盖或下方不是50:50"
 foreach($n in @('ConnectionRowSerial','CatOperatingPanel','ConnectionRowIdentity','ConnectionRowServer','ConnectionRowSecrets','ConnectionRowActions','ChannelConsolePanel','BmStaticGroupPanel','AudioDevicePanel','ConnectionRowAudio','VolumeControlsPanel')){$e=$m.controls_bounds.PSObject.Properties[$n];Assert-Ui ($e -and $e.Value.fully_visible) "$Label $n裁切"}
 $cfgTitle=Rect $l 'ConnectionConfigTitleText';$refresh=Rect $l 'RefreshDevicesButton';Assert-Ui ([Math]::Abs(($cfgTitle.y+$cfgTitle.height/2)-($refresh.y+$refresh.height/2))-le 1) "$Label连接配置标题与设备刷新按钮没有垂直对齐"
 $a=Rect $l 'SerialBox';$b=Rect $l 'SerialConnectButton';Assert-Ui ([Math]::Abs($a.height-$b.height)-le 1 -and [Math]::Abs($a.bottom-$b.bottom)-le 1) "$Label串口框与切换按钮未对齐"
 $a=Rect $l 'ConnectButton';$b=Rect $l 'SaveSettingsButton';$actions=Rect $l 'ConnectionRowActions';Assert-Ui ([Math]::Abs($a.height-$b.height)-le 1 -and [Math]::Abs($a.bottom-$b.bottom)-le 1 -and [Math]::Abs($a.y-$actions.y)-le 1 -and ($actions.bottom-$a.bottom)-ge 16) "$Label BM按钮未对齐或按钮下方留白不足"
 $mode=Rect $l 'CatMainModeBox';$freq=Rect $l 'CatMainFrequencyMHzBox';$pow=Rect $l 'CatPowerBox'
 Assert-Ui ([Math]::Abs($mode.height-29)-le 1 -and [Math]::Abs($freq.height-29)-le 1 -and [Math]::Abs($pow.height-29)-le 1 -and [Math]::Abs($mode.width-$freq.width)-le 2 -and [Math]::Abs($freq.width-$pow.width)-le 2) "$Label CAT列没有等宽/29高"
 $apply=Rect $l 'ApplyCatSettingsButton';Assert-Ui ($apply.y -lt $pow.y -and $apply.bottom -le ($pow.y+1)) "$Label应用按钮挤入功率输入"
 $modeObserved=$m.controls_bounds.CatObservedMainModeText
 $freqObserved=$m.controls_bounds.CatObservedFrequencyText;$powerObserved=$m.controls_bounds.CatObservedPowerText
 Assert-Ui (-not $m.controls_visible.CatObservedPanel -and $modeObserved.text-ceq 'FM' -and -not $modeObserved.actual) "$Label MAIN重复观测值仍显示，或隐藏控件没有保留后台读数更新"
 Assert-Ui (-not $m.controls_visible.CatObservedFrequencyText -and -not $freqObserved.actual -and [string]$freqObserved.text-ceq '145.500 MHz') "$Label CAT频率重复观测值仍显示，或隐藏控件没有保留后台读数更新"
 Assert-Ui (-not $m.controls_visible.CatObservedPowerText -and -not $powerObserved.actual -and [string]$powerObserved.text-ceq '25 W') "$Label CAT功率重复观测值仍显示，或隐藏控件没有保留后台读数更新"
 $history=Rect $l 'RadioDetailsExpander';$list=Rect $l 'CallHistoryList';Assert-Ui ([Math]::Abs($history.height-120)-le 1 -and [Math]::Abs($list.height-82)-le 1 -and [int]$l.history_visible_count -eq 5) "$Label历史框不是120/五行"
 $historyRows=@($l.history_page_probe.visual.rows);Assert-Ui ($historyRows.Count -eq 5 -and @($historyRows|Where-Object{-not $_.container_fully_visible -or -not $_.text_fully_visible}).Count -eq 0) "$Label历史五行未完整显示"
 Assert-Ui (@($l.channel_card_layout).Count -eq 6) "$Label频道区不是固定六格"
 foreach($card in @($l.channel_card_layout|Where-Object{-not $_.blank})){
  $title=$card.card_title;$meta=$title.tag;$box=$card.card_bounds;$header=$title.bounds;$call=$card.call_area_bounds
  $prefix=if([string]$meta.kind -ceq 'group'){('组呼 '+[string]$meta.id)}else{('单呼 '+[string]$meta.id)}
  $expectedKey=[string]$meta.kind+':'+[string]$meta.id+':'+[string]$meta.slot
  Assert-Ui ($title.name -ceq 'ChannelCardTitle' -and [string]$title.text -ceq [string]$meta.title -and [string]$title.tooltip -ceq [string]$meta.tooltip -and [string]$meta.channel_key -ceq [string]$card.channel_key -and [string]$card.channel_key -ceq $expectedKey) "${Label}频道标题没有保留完整文字或稳定ID/kind/slot"
  Assert-Ui ($title.text.StartsWith($prefix,[StringComparison]::Ordinal) -and $title.tooltip.Contains([string]$meta.id) -and (-not [string]$meta.name -or $title.tooltip.Contains([string]$meta.name))) "${Label}频道标题没有显示kind、ID和完整已知名称"
  Assert-Ui ([Math]::Abs([double]$card.height-109) -le 1 -and $header.x -ge ($box.x-.5) -and $header.y -ge ($box.y-.5) -and $header.right -le ($box.right+.5) -and $header.bottom -le ($call.y+.5) -and [double]$title.desired_height -gt 0 -and [double]$title.desired_height -le ([double]$title.height+.5)) "${Label}频道标题实际高度不足以容纳中文文字，或超出109px卡片/来话区域"
  Assert-Ui ($title.text_trimming -ceq 'CharacterEllipsis' -and $title.text_wrapping -ceq 'NoWrap') "${Label}频道长标题没有使用省略显示且保留单行布局"
  if([bool]$meta.is_bm_static){Assert-Ui ($title.text.Contains('静态组') -and $title.tooltip.Contains('静态组已读取')) "${Label}已确认的静态组分类或简短提示没有出现在频道卡"}
  if([bool]$meta.request_sent){Assert-Ui ($title.text.Contains('动态组') -and $title.tooltip.Contains('激活请求已发送') -and -not $title.tooltip.Contains('Native')) "${Label}已确认的动态组分类或简短提示没有出现在频道卡"}
 }
 $longCard=@($l.channel_card_layout|Where-Object{-not $_.blank -and [string]$_.card_title.tag.name.Length -ge 20}|Select-Object -First 1)
 Assert-Ui ($longCard.Count -eq 1 -and [string]$longCard[0].card_title.tag.name -match '测试长频道名称' -and $longCard[0].card_title.text_trimming -ceq 'CharacterEllipsis' -and $longCard[0].card_title.tooltip.Contains([string]$longCard[0].card_title.tag.name)) "${Label}中文超长频道名没有省略显示或Tooltip没有保留完整名称"
 $samplesProperty=$l.PSObject.Properties['caller_identity_samples'];$shortCaller=if($samplesProperty){$samplesProperty.Value.PSObject.Properties['short'].Value}else{$null};$longCaller=if($samplesProperty){$samplesProperty.Value.PSObject.Properties['long'].Value}else{$null}
 Assert-Ui ($shortCaller -and $longCaller -and [string]$shortCaller.name -match '[\u4e00-\u9fff]' -and [string]$longCaller.name -match '[\u4e00-\u9fff]' -and [string]$shortCaller.visual_text -match '[\u4e00-\u9fff]' -and [string]$longCaller.visual_text -match '[\u4e00-\u9fff]' -and [string]$shortCaller.dmr_id_text -match '^DMR ID [0-9]+$' -and [string]$longCaller.dmr_id_text -match '^DMR ID [0-9]+$') "$Label短/长来话身份没有同时呈现中文姓名与DMR ID"
 $shortCallUri=[Uri][string]$shortCaller.callsign_uri;$shortDmrUri=[Uri][string]$shortCaller.dmr_profile_uri;$longCallUri=[Uri][string]$longCaller.callsign_uri;$longDmrUri=[Uri][string]$longCaller.dmr_profile_uri
 Assert-Ui ($shortCallUri.Scheme -ceq 'https' -and $shortCallUri.Host -ceq 'www.qrz.com' -and $shortCallUri.AbsoluteUri.Contains([string]$shortCaller.callsign) -and $shortDmrUri.Scheme -ceq 'https' -and $shortDmrUri.Host -ceq 'brandmeister.network' -and $shortDmrUri.AbsoluteUri.Contains([string]$shortCaller.callsign) -and $shortCallUri.Host -cne $shortDmrUri.Host -and $longCallUri.Scheme -ceq 'https' -and $longCallUri.Host -ceq 'www.qrz.com' -and $longCallUri.AbsoluteUri.Contains([string]$longCaller.callsign) -and $longDmrUri.Scheme -ceq 'https' -and $longDmrUri.Host -ceq 'brandmeister.network' -and $longDmrUri.AbsoluteUri.Contains([string]$longCaller.callsign) -and $longCallUri.Host -cne $longDmrUri.Host) "$Label QRZ呼号链接与DMR ID链接没有分别指向QRZ和BrandMeister资料页"
 $title=Rect $l 'MainTitleText';$bm=Rect $l 'BmStatusCard';$event=Rect $l 'TransientStatusText'
 Assert-Ui ([Math]::Abs(($bm.y+$bm.height/2)-($title.y+$title.height/2))-le 1 -and $l.transient_status.visible -and $event.x -ge $title.right) "$Label标题/BM/事件未对齐到同一行"
 if($m.controls_visible.BmLossMetric){$metric=Rect $l 'BmLossMetric'}else{$metric=Rect $l 'BmRttMetric'};Assert-Ui ($event.x -ge ($metric.right-1)) "$Label事件没有紧随最后可见指标"
 if($l.bm_loss_valid){Assert-Ui ($m.controls_visible.BmLossMetric -and $m.controls_bounds.BmLossValue.text -match '^\d+(\.\d+)?%$') "$Label有效loss未显示"}else{Assert-Ui (-not $m.controls_visible.BmLossMetric -and $m.controls_bounds.BmLossValue.text -ceq '') "$Label无效loss仍显示"}
 Assert-Ui (@($m.controls_bounds.ConnectButton.visual_text)-contains '连接BM' -and @($m.controls_bounds.SaveSettingsButton.visual_text)-contains '保存配置' -and @($m.controls_bounds.SerialConnectButton.visual_text)-contains '连接串口' -and @($m.controls_bounds.AddBmStaticGroupButton.visual_text)-contains '添加为静态组' -and @($m.controls_bounds.LanguageToggleButton.visual_text)-contains 'English') "$Label连接、语言切换或BM静态组按钮文字不正确"
 $language=Rect $l 'LanguageToggleButton';$stop=Rect $l 'StopButton';$headerTitle=Rect $l 'MainTitleText';Assert-Ui ($language.right-le($stop.x+1) -and $stop.right-le1360 -and [Math]::Abs(($language.y+$language.height/2)-($headerTitle.y+$headerTitle.height/2))-le 1) "$Label语言切换按钮没有位于右上并完整显示在停止按钮之前"
 Assert-Ui (@($m.controls_bounds.RefreshDevicesButton.visual_text)-contains '刷新设备' -and @($m.controls_bounds.ApplyCatSettingsButton.visual_text)-contains '应用' -and @($m.controls_bounds.AddChannelButton.visual_text)-contains '加入监听') "$Label刷新/CAT应用/加入监听按钮文本或显示状态不正确"
 $channelId=Rect $l 'ChannelIdBox';$channelKind=Rect $l 'ChannelKindBox';$addChannel=Rect $l 'AddChannelButton';Assert-Ui ([Math]::Abs($channelId.height-$addChannel.height)-le 1 -and [Math]::Abs($channelKind.height-$addChannel.height)-le 1 -and [Math]::Abs($channelId.bottom-$addChannel.bottom)-le 1 -and [Math]::Abs($channelKind.bottom-$addChannel.bottom)-le 1) "$Label频道ID/类型/加入按钮没有同高并对齐底边"
 $audioPanel=Rect $l 'AudioDevicePanel';$audioFields=Rect $l 'ConnectionRowAudio';$volumePanel=Rect $l 'VolumeControlsPanel';$inputAudio=Rect $l 'WaveInEndpointBox';$outputAudio=Rect $l 'WaveOutEndpointBox';Assert-Ui ($audioFields.y -ge $audioPanel.y -and $audioFields.bottom -le $audioPanel.bottom -and $audioPanel.bottom -le ($volumePanel.y+1) -and [Math]::Abs($inputAudio.height-$outputAudio.height)-le 1) "$Label音频设备行未固定在音量区上方或输入输出错位"
 $dailyHeights=@((Rect $l 'ChannelConsolePanel').height,(Rect $l 'BmStaticGroupPanel').height,(Rect $l 'AudioDevicePanel').height,(Rect $l 'VolumeControlsPanel').height);$dailyStats=$dailyHeights|Measure-Object -Minimum -Maximum
 Assert-Ui ([double]$dailyStats.Maximum-[double]$dailyStats.Minimum -le 1.1) "$Label日常控制四个子面板实际高度没有均匀分配"
 $staticList=Rect $l 'BmStaticGroupsList';$staticInput=Rect $l 'BmStaticGroupIdBox';$staticAdd=Rect $l 'AddBmStaticGroupButton';$staticGap=$staticAdd.x-$staticInput.right
 Assert-Ui ([Math]::Abs($staticInput.x-$staticList.x)-le 1 -and [Math]::Abs($staticAdd.right-$staticList.right)-le 1 -and [Math]::Abs($staticInput.height-$staticAdd.height)-le 1 -and [Math]::Abs($staticInput.bottom-$staticAdd.bottom)-le 1 -and $staticGap-ge 4 -and $staticGap-le 8) "$Label BM静态组输入与按钮未对齐，或两者间距不在4至8px"
 Assert-Ui ($m.area_scrollviewer_count -eq 0 -and $m.non_popup_scrollbar_count -eq 0) "$Label可见区域存在滚动查看器/滚动条"
 Assert-Ui ($l.bm_static_group_panel.visible -and $l.static_api_required.visible -and $l.static_api_required.text -ceq '需启用BM API key') "$Label静态组提示没有显示"
 $a=Rect $l 'BmStaticGroupsList';$b=Rect $l 'StaticApiRequiredOverlay';Assert-Ui ([Math]::Abs($a.x-$b.x)-le 1 -and [Math]::Abs($a.y-$b.y)-le 1 -and [Math]::Abs($a.width-$b.width)-le 1 -and [Math]::Abs($a.height-$b.height)-le 1) "$Label API覆盖层没有覆盖列表边界"
 $text=Rect $l 'StaticApiRequiredText';Assert-Ui ([Math]::Abs(($text.x+$text.width/2)-($a.x+$a.width/2))-le 1 -and [Math]::Abs(($text.y+$text.height/2)-($a.y+$a.height/2))-le 4) "$Label API提示文字没有在静态列表中央"
 Assert-Ui ([int]$l.bm_static_group_visible_count -eq 0 -and [int]$l.bm_static_group_count -eq 0) "$Label无API key时仍显示静态组数据"
 Assert-Ui (-not [bool]$l.page_navigation.visible -and [int]$l.page_navigation.slot_count -eq 6) "$Label没有分页数据时仍显示频道页码，或3x2槽位数错误"
 Assert-Ui ([int]$l.history_page_probe.first_page_count -eq 5 -and [int]$l.history_page_probe.second_page_count -eq 3 -and [string]$l.history_page_probe.second_page_text -ceq '2 / 2') "$Label来话历史分页边界不是5+3条"
 Assert-Ui ($l.channel_state.selected_tx_background -ceq '#28583C' -and $l.channel_state.active_tx_background -ceq '#713237' -and $l.channel_state.muted_selected_background -ceq '#28583C' -and $l.channel_state.receive_caller_text -match '[\u4e00-\u9fff]') "$Label频道收话/目标/发射状态颜色或中文来话名字错误"
 $contrastNames=@('MasterPresetBox','ChannelKindBox','CatPortBox','CatBaudRateBox','CatMainModeBox','CatMainFrequencyMHzBox','CatPowerBox','ChannelIdBox')
 foreach($name in $contrastNames){$c=@($l.combo_contrast|Where-Object{$_.name -ceq $name})|Select-Object -First 1;Assert-Ui ($c -and (Contrast ([string]$c.foreground) ([string]$c.background)) -ge 4.5) "$Label组合框$name文字对比度低于4.5:1"}
 Assert-Ui ($l.combo_interaction.cat_port.editable_text_preserved) "$Label CAT可编辑串口没有保留手输内容（真实 Popup 点击在 test-ui-r124.ps1 验证）"
 $playSlider=Rect $l 'PlaybackGainSlider';$txSlider=Rect $l 'TransmitGainSlider';$playValue=Rect $l 'PlaybackGainValueText';$txValue=Rect $l 'TransmitGainValueText'
 Assert-Ui ([Math]::Abs($playSlider.height-34)-le 1 -and [Math]::Abs($txSlider.height-34)-le 1 -and $playValue.bottom-le($playSlider.y-1) -and $txValue.bottom-le($txSlider.y-1) -and $l.main.controls_bounds.PlaybackGainValueText.text-ceq([string]$GainLevel+'x') -and $l.main.controls_bounds.TransmitGainValueText.text-ceq([string]$GainLevel+'x')) "$Label增益滑块高度、当前值文字或轨道边界不符"

 $inputs=@('LanguageToggleButton','StopButton','RefreshDevicesButton','SerialBox','CatPortBox','CatBaudRateBox','SerialConnectButton','CatMainModeBox','CatMainFrequencyMHzBox','CatPowerBox','ApplyCatSettingsButton','CallsignBox','SourceBox','DeviceNumberBox','MasterPresetBox','MasterPortBox','MasterBox','BmApiKeyBox','PasswordBox','ConnectButton','SaveSettingsButton','CallHistoryPagePreviousButton','CallHistoryPageNextButton','SetHistoryCallTargetButton','CallHistoryList','ChannelIdBox','ChannelKindBox','AddChannelButton','BmStaticGroupsList','BmStaticGroupPagePreviousButton','BmStaticGroupPageNextButton','RefreshBmStaticGroupsButton','RemoveBmStaticGroupButton','BmStaticGroupIdBox','AddBmStaticGroupButton','WaveInEndpointBox','WaveOutEndpointBox','PlaybackGainSlider','TransmitGainSlider')
 $rs=@();foreach($n in $inputs){$v=$m.controls_visible.PSObject.Properties[$n];Assert-Ui ($null -ne $v) "$Label缺$n可见性";if(-not $v.Value){continue};$r=Rect $l $n;Assert-Ui ($r.width -gt 0 -and $r.height -gt 0) "$Label$n没有边界";$rs+=,[pscustomobject]@{Name=$n;R=$r}}
 for($i=0;$i -lt $rs.Count;$i++){for($j=$i+1;$j -lt $rs.Count;$j++){$a=$rs[$i].R;$b=$rs[$j].R;$x=[Math]::Min($a.right,$b.right)-[Math]::Max($a.x,$b.x);$y=[Math]::Min($a.bottom,$b.bottom)-[Math]::Max($a.y,$b.y);Assert-Ui ($x -le .5 -or $y -le .5) "$Label输入$($rs[$i].Name)与$($rs[$j].Name)重叠"}}
 $panel=Rect $l 'ChannelCardsPanel';$buttons=@()
 foreach($card in @($l.channel_card_layout|Where-Object{-not $_.blank})){$box=$card.card_bounds;$call=$card.call_area_bounds;$action=$card.action_area_bounds;Assert-Ui ($box -and $call -and $action -and [Math]::Abs([double]$call.y-[double]$action.y)-le .5 -and [Math]::Abs([double]$call.bottom-[double]$action.bottom)-le .5 -and $call.x -ge ($box.x-.5) -and $call.y -ge ($box.y-.5) -and $call.right -le ($box.right+.5) -and $call.bottom -le ($box.bottom+.5) -and $action.x -ge ($box.x-.5) -and $action.y -ge ($box.y-.5) -and $action.right -le ($box.right+.5) -and $action.bottom -le ($box.bottom+.5)) "$Label频道来话区与2x2操作区未对齐或超出卡片";$bs=@($card.buttons_bounds);Assert-Ui ($bs.Count -eq @($card.buttons).Count -and [int]$card.action_count -eq 4) "$Label动态卡片操作边界缺失";$vis=@($bs|Where-Object{$_.visible});foreach($caption in @($card.buttons)){Assert-Ui (@($vis|Where-Object{@($_.text)-contains [string]$caption}).Count -gt 0) "$Label操作$caption没有可见边界"};foreach($b in $vis){$r=[pscustomobject]@{x=[double]$b.x;y=[double]$b.y;width=[double]$b.width;height=[double]$b.height;right=([double]$b.x+[double]$b.width);bottom=([double]$b.y+[double]$b.height)};Assert-Ui ($r.width -gt 0 -and $r.height -gt 0 -and $r.x -ge ($panel.x-1) -and $r.y -ge ($panel.y-1) -and $r.right -le ($panel.right+1) -and $r.bottom -le ($panel.bottom+1) -and $r.x -ge ($box.x-.5) -and $r.y -ge ($box.y-.5) -and $r.right -le ($box.right+.5) -and $r.bottom -le ($box.bottom+.5)) "$Label动态按钮超出所属卡片/网格";$buttons+=,[pscustomobject]@{R=$r;Name=$b.action}}}
 $cards=@($l.channel_card_layout|Where-Object{-not $_.blank})
 foreach($card in $cards){$box=$card.card_bounds;Assert-Ui ($box -and $box.width -gt 0 -and $box.height -gt 0 -and $box.x -ge ($panel.x-1) -and $box.y -ge ($panel.y-1) -and $box.right -le ($panel.right+1) -and $box.bottom -le ($panel.bottom+1)) "$Label频道卡边界超出频道网格"}
 for($i=0;$i -lt $cards.Count;$i++){for($j=$i+1;$j -lt $cards.Count;$j++){$a=$cards[$i].card_bounds;$b=$cards[$j].card_bounds;$x=[Math]::Min([double]$a.right,[double]$b.right)-[Math]::Max([double]$a.x,[double]$b.x);$y=[Math]::Min([double]$a.bottom,[double]$b.bottom)-[Math]::Max([double]$a.y,[double]$b.y);Assert-Ui ($x -le .5 -or $y -le .5) "$Label频道卡$($cards[$i].channel_key)与$($cards[$j].channel_key)边界重叠"}}
 for($i=0;$i -lt $buttons.Count;$i++){for($j=$i+1;$j -lt $buttons.Count;$j++){$a=$buttons[$i].R;$b=$buttons[$j].R;$x=[Math]::Min($a.right,$b.right)-[Math]::Max($a.x,$b.x);$y=[Math]::Min($a.bottom,$b.bottom)-[Math]::Max($a.y,$b.y);Assert-Ui ($x -le .5 -or $y -le .5) "$Label频道卡按钮重叠"}}
 return $l
}

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));$ui=Join-Path $repo 'ui\windows\bridge-ui.ps1';$xaml=Join-Path $repo 'ui\windows\MainWindow.xaml';$settings=Join-Path $repo 'ui\windows\SettingsWindow.xaml'
$task=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wirex-r126-render-'+[guid]::NewGuid().ToString('N'))));$pkg=Join-Path $task 'package';[void][IO.Directory]::CreateDirectory($pkg);[IO.File]::WriteAllText((Join-Path $pkg 'start-bm-radio-bridge.ps1'),'');[IO.File]::WriteAllText((Join-Path $pkg 'wirex_bridge.exe'),'')
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){throw '请使用-STA运行WPF RenderOnly回归'}
foreach($f in @($PSCommandPath,$ui,$xaml,$settings)){if(-not [IO.File]::Exists($f)){throw "缺渲染目标$f"};Assert-Bom $f}
$t=$null;$parse=$null;[void][Management.Automation.Language.Parser]::ParseFile($ui,[ref]$t,[ref]$parse);if($parse.Count){throw "bridge-ui.ps1解析失败：$($parse[0].Message)"}
$doc=[xml][IO.File]::ReadAllText($xaml,[Text.Encoding]::UTF8);$sd=[xml][IO.File]::ReadAllText($settings,[Text.Encoding]::UTF8);$st=[IO.File]::ReadAllText($settings,[Text.Encoding]::UTF8);$w=$doc.DocumentElement
Assert-ThreeStaticGroupRows -XamlPath $xaml -ScreenshotPath (Join-Path $task 'bm-static-groups-disabled-busy.png')
Assert-Ui ($w.GetAttribute('Width')-ceq '1360' -and $w.GetAttribute('Height')-ceq '900' -and $w.GetAttribute('MinWidth')-ceq '1360' -and $w.GetAttribute('MinHeight')-ceq '900' -and $w.GetAttribute('ResizeMode')-ceq 'CanMinimize') '主窗口没有固定为1360x900'
$gainStyle=$doc.SelectSingleNode("//*[local-name()='Style' and @*[local-name()='Key']='AudioGainSliderStyle']")
$gainTemplate=$gainStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='Template']/*[local-name()='Setter.Value']/*[local-name()='ControlTemplate']")
$gainTrack=$gainTemplate.SelectSingleNode(".//*[local-name()='Track' and @*[local-name()='Name']='PART_Track']")
$gainRail=$gainTemplate.SelectSingleNode(".//*[local-name()='Border' and @*[local-name()='Name']='TrackRail']")
$gainThumb=$gainTemplate.SelectSingleNode(".//*[local-name()='Thumb' and @*[local-name()='Name']='PART_Thumb']")
 $gainDots=$gainTemplate.SelectSingleNode(".//*[local-name()='UniformGrid' and @Columns='7']")
 $gainFill=$gainTemplate.SelectSingleNode(".//*[local-name()='Border' and @*[local-name()='Name']='SelectedTrack']")
$playGain=Node $doc 'PlaybackGainSlider';$txGain=Node $doc 'TransmitGainSlider'
$gainScript=[IO.File]::ReadAllText($ui,[Text.Encoding]::UTF8)
 Assert-Ui ($gainStyle -and $gainTrack -and $gainRail.GetAttribute('Height')-ceq '18' -and $gainRail.GetAttribute('CornerRadius')-ceq '9' -and $gainFill.GetAttribute('CornerRadius')-ceq '9,0,0,9' -and $gainThumb.GetAttribute('Width')-ceq '28' -and $gainThumb.GetAttribute('Height')-ceq '28' -and @($gainDots.SelectNodes("./*[local-name()='Ellipse']")).Count -eq 7) '增益滑块轨道与填充端点、28px旋钮或七个装饰刻点错误'
 Assert-Ui ($playGain.GetAttribute('Style')-ceq '{StaticResource AudioGainSliderStyle}' -and $txGain.GetAttribute('Style')-ceq '{StaticResource AudioGainSliderStyle}' -and $playGain.GetAttribute('Minimum')-ceq '1' -and $txGain.GetAttribute('Minimum')-ceq '1' -and $playGain.GetAttribute('Maximum')-ceq '16' -and $txGain.GetAttribute('Maximum')-ceq '16' -and $playGain.GetAttribute('Value')-ceq '1' -and $txGain.GetAttribute('Value')-ceq '16' -and $gainTemplate.SelectSingleNode("./*[local-name()='ControlTemplate.Triggers']/*[local-name()='Trigger' and @Property='IsEnabled' and @Value='False']")) '增益滑块没有保留1至16整数范围、默认边界或禁用态'
 $snapSetter=$gainStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='IsSnapToTickEnabled' and @Value='True']")
 $tickSetter=$gainStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='TickFrequency' and @Value='1']")
 $smallStepSetter=$gainStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='SmallChange' and @Value='1']")
 $largeStepSetter=$gainStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='LargeChange' and @Value='1']")
$moveSetter=$gainStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='IsMoveToPointEnabled' and @Value='True']")
 Assert-Ui ($snapSetter -and $tickSetter -and $smallStepSetter -and $largeStepSetter -and $moveSetter) '滑块没有按整数刻度吸附，或点击轨道不能定位'
Assert-Ui ($gainScript -match "PlaybackGainSlider'\)\.Add_ValueChanged\(\{ On-UiAudioGainValueChanged \}\)" -and $gainScript -match "TransmitGainSlider'\)\.Add_ValueChanged\(\{ On-UiAudioGainValueChanged \}\)") '播放或发送增益没有连接运行时 ValueChanged 处理器'
$root=Node $doc 'ConsoleRoot';$rr=Rows $root;Assert-Ui ($rr.Count -eq 3 -and $rr[0].GetAttribute('Height')-ceq '32' -and $rr[1].GetAttribute('Height')-ceq '370') '标题单行/上区高度错误'
$d=Node $doc 'DashboardPanel';$dc=Cols $d;Assert-Ui ($dc.Count -eq 2 -and @($dc|Where-Object{$_.GetAttribute('Width')-ceq '1*'}).Count -eq 2) '下方两列不等宽'
$c=Node $doc 'ChannelCardsPanel';Assert-Ui ($c.GetAttribute('Rows')-ceq '2' -and $c.GetAttribute('Columns')-ceq '3') '频道卡不是3x2'
$cb=Node $doc 'ChannelCardsScroll';$cr=Rows ($cb.SelectSingleNode("./*[local-name()='Grid']"));Assert-Ui ($cr[1].GetAttribute('Height')-ceq 'Auto' -and (Node $doc 'ChannelPageNav').GetAttribute('Visibility')-ceq 'Collapsed') '无频道分页时仍留白'
$ct=Rows (Node $doc 'ConsoleTop');$hg=Node $doc 'RadioDetailsExpander';$hr=Rows ($hg.SelectSingleNode("./*[local-name()='Grid']"));$hl=Node $doc 'CallHistoryList';$hs=$hl.SelectSingleNode("./*[local-name()='ListBox.ItemContainerStyle']/*[local-name()='Style']/*[local-name()='Setter' and @Property='Height']")
Assert-Ui ($ct[1].GetAttribute('Height')-ceq '120' -and $hr[0].GetAttribute('Height')-ceq '28' -and $hl.GetAttribute('Height')-ceq '82' -and $hs.GetAttribute('Value')-ceq '16') '历史框/标题/五行行高不符'
$cfg=Node $doc 'ConnectionConfigPanel';$rows=Rows ($cfg.SelectSingleNode("./*[local-name()='Grid']"));Assert-Ui ($rows.Count -eq 7 -and $rows[0].GetAttribute('Height')-ceq '24' -and $rows[6].GetAttribute('Height')-ceq '52') '连接区没有固定标题和底部按钮留白行'
foreach($i in @(1,2,3,4,5)){Assert-Ui ($rows[$i].GetAttribute('Height')-ceq '*') '连接区五行设置没有平均分配高度'}
$comboStyle=$doc.SelectSingleNode("//*[local-name()='Style' and @TargetType='ComboBox']");$comboFont=$comboStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='FontSize']");$baud=Node $doc 'CatBaudRateBox'
$cfgLabels=@($cfg.SelectNodes(".//*[local-name()='TextBlock' and @FontSize='10']"));$hiddenMode=Node $doc 'CatObservedMainModeText';$catObserved=Node $doc 'CatObservedPanel'
Assert-Ui ($comboFont.GetAttribute('Value')-ceq '14' -and $baud.GetAttribute('FontSize')-ceq '12' -and $cfgLabels.Count -eq 1 -and $cfgLabels[0].GetAttribute('x:Name')-ceq 'CatObservedMainModeText' -and $catObserved.GetAttribute('Visibility')-ceq 'Collapsed') '连接区选项字号没有加大，或重复MAIN观测文字仍可见'
$connectionRows=@((Node $doc 'ConnectionRowSerial'),(Node $doc 'CatOperatingPanel'),(Node $doc 'ConnectionRowIdentity'),(Node $doc 'ConnectionRowServer'),(Node $doc 'ConnectionRowSecrets'))
Assert-Ui (@($connectionRows|Where-Object{$_.GetAttribute('Margin')-cne '0,3'}).Count -eq 0) '连接区各设置行上下间距不一致'
$sr=Cols (Node $doc 'ConnectionRowSerial');$rc=Cols (Node $doc 'RadioCatPanel');$cc=Cols (Node $doc 'CatOperatingPanel');$ac=Cols (Node $doc 'ConnectionRowActions')
Assert-Ui ($sr.Count -eq 3 -and $sr[0].GetAttribute('Width')-ceq '1*' -and $sr[1].GetAttribute('Width')-ceq '2*' -and $sr[2].GetAttribute('Width')-ceq '1*' -and @($rc|Where-Object{$_.GetAttribute('Width')-ceq '1*'}).Count -eq 2 -and @($cc|Where-Object{$_.GetAttribute('Width')-ceq '1*'}).Count -eq 3 -and @($ac|Where-Object{$_.GetAttribute('Width')-ceq '1*'}).Count -eq 2) '串口/CAT/BM按钮列宽合同错误'
$f=Node $doc 'CatMainFrequencyMHzBox';$p=Node $doc 'CatPowerBox';$powerTags=@($p.SelectNodes("./*[local-name()='ComboBoxItem']")|ForEach-Object{$_.GetAttribute('Tag')});Assert-Ui ($f.LocalName-ceq 'ComboBox' -and $f.GetAttribute('IsEditable')-ceq 'True' -and $p.LocalName-ceq 'ComboBox' -and @($powerTags)-contains '5' -and @($powerTags)-contains '10' -and @($powerTags)-contains '15' -and @($powerTags)-contains '25' -and @($powerTags)-contains '50' -and ([regex]::Matches([IO.File]::ReadAllText($xaml,[Text.Encoding]::UTF8),'x:Name="ApplyCatSettingsButton"')).Count -eq 1) 'CAT频率/五档功率/唯一应用控件错误'
$id=Node $doc 'ChannelIdBox';$presetItems=@($id.SelectNodes("./*[local-name()='ComboBoxItem']"));$tags=@($presetItems|%{$_.GetAttribute('Tag')});$searchIds=@($presetItems|%{$_.GetAttribute('TextSearch.Text')});$dailyIdLabel=$doc.SelectSingleNode("//*[local-name()='TextBlock' and @Text='增加动态组 频道ID']");$bmTitleLabel=$doc.SelectSingleNode("//*[local-name()='TextBlock' and @Text='增加BM静态组']");Assert-Ui ($id.LocalName-ceq 'ComboBox' -and $id.GetAttribute('IsEditable')-ceq 'True' -and $id.GetAttribute('IsTextSearchEnabled')-ceq 'False' -and @($tags)-contains '460997|private' -and @($tags)-contains '46001|group' -and @($tags)-contains '91|group' -and @($searchIds)-contains '460997' -and @($searchIds)-contains '46001' -and @($searchIds)-contains '91' -and $dailyIdLabel.GetAttribute('FontSize')-ceq '11' -and $bmTitleLabel.GetAttribute('FontSize')-ceq '11') '频道ID编辑/标签字号、预设Tag或可编辑项纯ID显示文本错误'
$sp=Node $doc 'BmStaticGroupPanel';$hint=Node $doc 'StaticApiRequiredText';$overlay=Node $doc 'StaticApiRequiredOverlay';$list=Node $doc 'BmStaticGroupsList';Assert-Ui ($sp.GetAttribute('Visibility')-ceq 'Visible' -and $hint.GetAttribute('Text')-ceq '需启用BM API key' -and $hint.ParentNode-eq $overlay -and $overlay.ParentNode-eq $list.ParentNode -and $overlay.GetAttribute('Background')-ceq '#151C20') 'API提示没有固定暗色覆盖在静态列表'
foreach($old in @('FooterText','BmDetail','SerialDisconnectButton','CatSessionStatusText','CatPowerSlider','CatDesiredPowerText','CatOperationStatusText','DisconnectBmButton','ConnectionLockValue','TransmitTargetValue','ChannelStatusText','BmStaticGroupStatus','PlaybackGainStatusValue','PlaybackGainSavedValueText','PlaybackGainRuntimeValueText','HiddenRuntimeControls','OfflineBanner','CoreValue','ControlStatusButton','RxCallLossValue')){Assert-Ui (@($doc.SelectNodes("//*[@*[local-name()='Name']='$old']")).Count -eq 0) "旧控件$old仍存在"}
 $daily=Node $doc 'DailyControlsPanel';$dailyRows=Rows ($daily.SelectSingleNode("./*[local-name()='Grid']"));$out=@($doc.SelectNodes("//*[local-name()='ScrollViewer' and not(ancestor::*[local-name()='Popup'])]"));$pop=@($doc.SelectNodes("//*[local-name()='ScrollViewer' and ancestor::*[local-name()='Popup']]"))
 Assert-Ui ($dailyRows.Count -eq 5 -and $dailyRows[0].GetAttribute('Height')-ceq '21' -and @($dailyRows|Select-Object -Skip 1|Where-Object{$_.GetAttribute('Height')-ceq '*'}).Count -eq 4) '日常控制四个子面板没有平均分配固定窗口高度'
 $channelPanel=Node $doc 'ChannelConsolePanel';$channelContent=$channelPanel.SelectSingleNode("./*[local-name()='Grid']");$channelColumns=Cols $channelContent;$channelFields=@($channelContent.SelectNodes("./*[local-name()='Grid']"));$idRows=Rows $channelFields[0];$kindRows=Rows $channelFields[1];$audioRow=Node $doc 'ConnectionRowAudio';$volumePanel=Node $doc 'VolumeControlsPanel';$gainStacks=@($volumePanel.SelectNodes(".//*[local-name()='StackPanel']"))
 Assert-Ui ($channelContent.GetAttribute('VerticalAlignment')-ceq 'Center' -and $channelColumns.Count -eq 3 -and $idRows[0].GetAttribute('Height')-ceq '17' -and $idRows[1].GetAttribute('Height')-ceq 'Auto' -and $kindRows[0].GetAttribute('Height')-ceq '17' -and $kindRows[1].GetAttribute('Height')-ceq 'Auto' -and $audioRow.GetAttribute('VerticalAlignment')-ceq 'Center' -and $gainStacks.Count -eq 2 -and @($gainStacks|Where-Object{$_.GetAttribute('VerticalAlignment')-ceq 'Center'}).Count -eq 2) '频道输入、音频设备和增益控件没有作为紧凑行组垂直居中'
Assert-Ui (@($daily.SelectNodes(".//*[local-name()='Border']")).Count -eq 0 -and $out.Count -eq 0 -and $pop.Count -eq 1 -and @($sd.SelectNodes("//*[local-name()='ScrollViewer']")).Count -eq 0 -and $st -notmatch 'TS1|TS2|时隙|切换PTT') '日常/主窗口/说明窗含内部边框或区域滚动/旧说明'
$listNodes=@($doc.SelectNodes("//*[local-name()='ListBox']"));Assert-Ui ($listNodes.Count -eq 2) '主界面来话/静态组列表数量不正确'
foreach($listNode in $listNodes){$v=$listNode.Attributes|Where-Object{$_.Name -ceq 'ScrollViewer.VerticalScrollBarVisibility'}|Select-Object -First 1;$h=$listNode.Attributes|Where-Object{$_.Name -ceq 'ScrollViewer.HorizontalScrollBarVisibility'}|Select-Object -First 1;Assert-Ui ($v -and $v.Value -ceq 'Disabled' -and $h -and $h.Value -ceq 'Disabled') '列表仍能显示滚动条'}
 $bmGrid=Node $doc 'BmStaticGroupPanel';$bmInner=$bmGrid.SelectSingleNode("./*[local-name()='Grid']");$bmRows=Rows $bmInner;$bmEntryGrid=$bmInner.SelectSingleNode("./*[local-name()='Grid'][3]");$bmEntryColumns=Cols $bmEntryGrid;$bmId=Node $doc 'BmStaticGroupIdBox';$bmAdd=Node $doc 'AddBmStaticGroupButton';$bmList=Node $doc 'BmStaticGroupsList'
 Assert-Ui ($bmRows.Count -eq 3 -and $bmRows[0].GetAttribute('Height')-ceq '21' -and $bmRows[1].GetAttribute('Height')-ceq '49' -and $bmRows[2].GetAttribute('Height')-ceq '24' -and $bmList.GetAttribute('Height')-ceq '49' -and $bmList.GetAttribute('Padding')-ceq '0' -and $bmId.GetAttribute('Margin')-ceq '0' -and $bmAdd.GetAttribute('Margin')-ceq '0' -and $bmAdd.GetAttribute('Content')-ceq '添加为静态组' -and $bmEntryColumns.Count -eq 3 -and $bmEntryColumns[0].GetAttribute('Width')-ceq '*' -and $bmEntryColumns[1].GetAttribute('Width')-ceq '6' -and $bmEntryColumns[2].GetAttribute('Width')-ceq 'Auto') 'BM静态组添加按钮文案、4至8px间距或对齐错误'
 $bmItemStyle=$bmList.SelectSingleNode("./*[local-name()='ListBox.ItemContainerStyle']/*[local-name()='Style']");$bmItemPadding=$bmItemStyle.SelectSingleNode("./*[local-name()='Setter' and @Property='Padding']")
 Assert-Ui ($bmItemStyle.GetAttribute('BasedOn')-ceq '{StaticResource {x:Type ListBoxItem}}' -and $bmItemPadding.GetAttribute('Value')-ceq '3,0') 'BM静态组列表没有压缩行内边距以完整显示三项'
$bmText=$bmList.SelectSingleNode("./*[local-name()='ListBox.ItemTemplate']/*[local-name()='DataTemplate']/*[local-name()='TextBlock']")
$globalItemStyle=$doc.SelectSingleNode("/*/*[local-name()='Window.Resources']/*[local-name()='Style' and @TargetType='ListBoxItem']")
$disabledItemTrigger=$globalItemStyle.SelectSingleNode("./*[local-name()='Style.Triggers']/*[local-name()='Trigger' and @Property='IsEnabled' and @Value='False']")
Assert-Ui ($bmText.GetAttribute('Foreground')-match 'AncestorType=.*ListBoxItem' -and $disabledItemTrigger.SelectSingleNode("./*[local-name()='Setter' and @Property='Foreground' and @Value='#758188']") -and $disabledItemTrigger.SelectSingleNode("./*[local-name()='Setter' and @Property='Background' and @Value='#151C20']")) '静态组禁用态没有从ListBoxItem模板向文字应用灰色和暗色'

Import-Module -Name (Join-Path $repo 'ui\windows\PortableConfig.psm1') -Force
$geometryReference=$null;$fixed=@('MainTitleText','LanguageToggleButton','StopButton','BmStatusCard','BmValue','BmRttMetric','BmRttValue','BmLossMetric','BmLossValue','TransientStatusText','ConsoleTop','ChannelCardsPanel','ChannelPageNav','RadioDetailsExpander','CallHistoryList','DashboardPanel','ConnectionConfigPanel','ConnectionConfigTitleText','RefreshDevicesButton','DailyControlsPanel','ConnectionRowSerial','SerialBox','CatPortBox','CatBaudRateBox','SerialConnectButton','CatOperatingPanel','CatMainModeBox','CatMainFrequencyMHzBox','CatPowerBox','ApplyCatSettingsButton','CatModeCaptionText','CatFrequencyCaptionText','CatPowerCaptionText','ConnectionRowIdentity','CallsignBox','SourceIdCaptionText','SourceBox','DeviceNumberBox','ConnectionRowServer','MasterPresetBox','MasterPortBox','MasterBox','ConnectionRowSecrets','BmApiKeyBox','PasswordBox','ConnectionRowActions','ConnectButton','SaveSettingsButton','ChannelConsolePanel','ChannelIdBox','ChannelKindBox','AddChannelButton','BmStaticGroupPanel','BmStaticGroupsList','StaticApiRequiredOverlay','StaticApiRequiredText','BmStaticGroupIdBox','AddBmStaticGroupButton','AudioDevicePanel','ConnectionRowAudio','WaveInEndpointBox','WaveOutEndpointBox','VolumeControlsPanel','PlaybackGainSlider','TransmitGainSlider')
foreach($gainLevel in @(1,8,16)){
 $gainLabel=('{0:D2}' -f $gainLevel);$config=Join-Path $task ('config-'+$gainLabel);[void][IO.Directory]::CreateDirectory($config);$configPath=Join-Path $config 'config.json'
 $fixture=Get-WirexPortableConfig -Path $configPath;$fixture.audio.radio_playback_gain=[decimal]$gainLevel;$fixture.audio.mic_transmit_gain=[decimal]$gainLevel
 [void](Save-WirexPortableConfig -Path $configPath -Config $fixture);$reference=$null
 foreach($label in @('render-a','render-b')){
  $runLabel=('gain-{0}/{1}' -f $gainLabel,$label);$dir=Join-Path (Join-Path $task ('gain-'+$gainLabel)) $label;[void][IO.Directory]::CreateDirectory($dir)
  $out=@(& powershell.exe -NoLogo -NoProfile -STA -File $ui -RenderOnly -NoAutoConnect -UserConfigDirectory $config -PackageDirectory $pkg -RenderOutputDirectory $dir -RenderWorkArea '1360x900' 2>&1);$exit=$LASTEXITCODE
  if($exit -ne 0){throw ($runLabel+' RenderOnly exited '+[string]$exit+': '+($out -join [Environment]::NewLine))}
  $layoutPath=Join-Path $dir 'layout-info.json';$cur=Check-Render $layoutPath $dir $runLabel -GainLevel $gainLevel;Assert-GainTrackJunction -ImagePath (Join-Path $dir 'main-window.png') -Layout $cur -GainLevel $gainLevel -Label $runLabel
  if($null -eq $reference){$reference=$cur}else{foreach($n in $fixed){$a=$reference.main.controls_bounds.PSObject.Properties[$n].Value.actual;$b=$cur.main.controls_bounds.PSObject.Properties[$n].Value.actual;Assert-Ui ([Math]::Abs([double]$a.x-[double]$b.x)-le 1 -and [Math]::Abs([double]$a.y-[double]$b.y)-le 1 -and [Math]::Abs([double]$a.width-[double]$b.width)-le 1 -and [Math]::Abs([double]$a.height-[double]$b.height)-le 1) "$runLabel与同档上一截图的$n位置不同"}}
  if($null -eq $geometryReference){$geometryReference=$cur}else{foreach($n in $fixed){$a=$geometryReference.main.controls_bounds.PSObject.Properties[$n].Value.actual;$b=$cur.main.controls_bounds.PSObject.Properties[$n].Value.actual;Assert-Ui ([Math]::Abs([double]$a.x-[double]$b.x)-le 1 -and [Math]::Abs([double]$a.y-[double]$b.y)-le 1 -and [Math]::Abs([double]$a.width-[double]$b.width)-le 1 -and [Math]::Abs([double]$a.height-[double]$b.height)-le 1) "$runLabel的$n位置受增益档位影响"}}
 }
 Assert-Ui (@(Get-ChildItem -LiteralPath $config -Force).Count -eq 1 -and [IO.File]::Exists($configPath)) ("$runLabel RenderOnly意外写入额外配置文件")
}
Write-Output ("PASS: test-ui-render.ps1 ({0}布局/实际边界断言; gains=1/8/16; static_groups=3; screenshots={1})" -f $script:assertionCount,$task)
