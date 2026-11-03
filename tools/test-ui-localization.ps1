#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$script:assertionCount=0
function Assert-Locale { param([bool]$Ok,[string]$Why) $script:assertionCount++; if(-not $Ok){throw "ASSERTION FAILED [$script:assertionCount]: $Why"} }
function Get-ComboTagSnapshot {
    param([string[]]$Names)
    $result=[ordered]@{}
    foreach($name in $Names){
        $combo=$script:mainWindow.FindName($name)
        $result[$name]=@($combo.Items | ForEach-Object { ConvertTo-Json -InputObject $_.Tag -Compress -Depth 8 })
    }
    return ConvertTo-Json -InputObject ([pscustomobject]$result) -Compress -Depth 8
}
function Get-ConfigWithoutLanguage {
    param([string]$Path)
    $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))
    $value.ui.language='__test_language__'
    return ConvertTo-Json -InputObject $value -Compress -Depth 24
}
function Get-ButtonTexts {
    param([System.Windows.DependencyObject]$Root)
    $result=New-Object 'System.Collections.Generic.List[string]'
    $pending=New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
    $pending.Push($Root)
    while($pending.Count -gt 0){
        $current=$pending.Pop()
        if($current -is [System.Windows.Controls.Button] -and $current.Content -is [string]){[void]$result.Add([string]$current.Content)}
        for($i=0;$i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($current);$i++){$pending.Push([System.Windows.Media.VisualTreeHelper]::GetChild($current,$i))}
    }
    return @($result)
}
function Ensure-Bom {
    param([string]$Path)
    $bytes=[IO.File]::ReadAllBytes($Path)
    Assert-Locale ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "PS1/PSM1缺少UTF-8 BOM：$Path"
}

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath=Join-Path $repo 'ui\windows\bridge-ui.ps1'
$task=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wirex-ui-localization-'+[guid]::NewGuid().ToString('N'))))
$configDirectory=Join-Path $task 'toggle-config'
$renderDirectory=Join-Path $task 'english-render'
$fakePackageDir=Join-Path $task 'package'
[void][IO.Directory]::CreateDirectory($configDirectory)
[void][IO.Directory]::CreateDirectory($renderDirectory)
[void][IO.Directory]::CreateDirectory($fakePackageDir)
[IO.File]::WriteAllText((Join-Path $fakePackageDir 'start-bm-radio-bridge.ps1'),'')
[IO.File]::WriteAllText((Join-Path $fakePackageDir 'wirex_bridge.exe'),'')

foreach($path in @(
    (Join-Path $repo 'ui\windows\PortableConfig.psm1'),
    (Join-Path $repo 'ui\windows\UiLocalization.psm1'),
    (Join-Path $repo 'ui\windows\bridge-ui.ps1'),
    (Join-Path $repo 'ui\windows\RadioCatUi.ps1'),
    (Join-Path $repo 'ui\windows\BmManagementUi.ps1'),
    (Join-Path $PSScriptRoot 'test-ui-localization.ps1')
)){ Ensure-Bom $path }

Import-Module (Join-Path $repo 'ui\windows\PortableConfig.psm1') -Force
$configPath=Join-Path $configDirectory 'config.json'
$config=Get-WirexPortableConfig -Path $configPath
$config.connection.callsign='N0SAVED'
$config.connection.gateway_id=[uint64]1
$config.connection.source_id=[uint64]123456
$config.connection.color_code=[uint64]1
$config.channels=[object[]]@([pscustomobject][ordered]@{id=[uint64]91;kind='group';slot=[uint64]1;name='用户自定义组名'})
$config.tx_channel_id='group:91:1'
$config.ui.language='en-US'
[void](Save-WirexPortableConfig -Path $configPath -Config $config -PersistUiLanguage)
$raw=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($configPath,[Text.Encoding]::UTF8))
Add-Member -InputObject $raw -NotePropertyName future_extension -NotePropertyValue ([pscustomobject][ordered]@{preserve='keep-me';revision=7}) -Force
[IO.File]::WriteAllText($configPath,(ConvertTo-Json -InputObject $raw -Depth 24),(New-Object Text.UTF8Encoding($false)))
$savedConfigWithoutLanguage=Get-ConfigWithoutLanguage -Path $configPath
$oldSupervisor=$null

if([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){throw '请使用 -STA 运行中英文界面测试。'}
. $uiPath -UiTestFixture -NoAutoConnect -UserConfigDirectory $configDirectory -PackageDirectory $repo
try {
    Assert-Locale ($script:mainWindow -and $script:mainWindow.IsVisible -and $script:settingsWindow) '离线测试没有启动真实主窗口和设置窗口'
    $languageButton=$script:mainWindow.FindName('LanguageToggleButton')
    $startupConfig=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($configPath,[Text.Encoding]::UTF8))
    Assert-Locale ($script:uiLanguage -ceq 'zh-CN' -and $script:portableConfig.ui.language -ceq 'en-US' -and $startupConfig.ui.language -ceq 'en-US') '应用没有固定以中文启动，或启动时改写了配置中的语言值'
    Assert-Locale ($languageButton.Visibility -eq [System.Windows.Visibility]::Collapsed -and -not $languageButton.IsEnabled) '语言切换按钮仍在界面显示或可用'
    $languageButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $startupConfigAfterClick=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($configPath,[Text.Encoding]::UTF8))
    Assert-Locale ($script:uiLanguage -ceq 'zh-CN' -and $startupConfigAfterClick.ui.language -ceq 'en-US') '隐藏按钮触发了语言切换或改写配置'
    if($script:uiTimer){$script:uiTimer.Stop()}
    $remove=New-Object System.Windows.Controls.TextBlock
    $unlisten=New-Object System.Windows.Controls.TextBlock
    [void](Set-WirexUiLocalizedElementProperty -Element $remove -Property Text -SourceText '移除' -Language 'en-US' -UpdateSource)
    [void](Set-WirexUiLocalizedElementProperty -Element $unlisten -Property Text -SourceText '取消监听' -Language 'en-US' -UpdateSource)
    Assert-Locale ($remove.Text -ceq 'Remove' -and $unlisten.Text -ceq 'Remove') '两个不同中文来源没有分别映射到相同的英文Remove'
    [void](Set-WirexUiLocalizedElementProperty -Element $remove -Property Text -SourceText $remove.Text -Language 'en-US')
    [void](Set-WirexUiLocalizedElementProperty -Element $unlisten -Property Text -SourceText $unlisten.Text -Language 'en-US')
    Assert-Locale ($remove.Text -ceq 'Remove' -and $unlisten.Text -ceq 'Remove') '英文状态重复应用后发生翻译回退'
    [void](Set-WirexUiLocalizedElementProperty -Element $remove -Property Text -SourceText '移除' -Language 'zh-CN')
    [void](Set-WirexUiLocalizedElementProperty -Element $unlisten -Property Text -SourceText '取消监听' -Language 'zh-CN')
    Assert-Locale ($remove.Text -ceq '移除' -and $unlisten.Text -ceq '取消监听') '英文Remove来源冲突往返后没有恢复各自中文'

    foreach($name in @('SerialBox','CatPortBox','WaveInEndpointBox','WaveOutEndpointBox')){
        $combo=$script:mainWindow.FindName($name)
        $combo.ItemsSource=$null
        $combo.Items.Clear()
        if($name -ceq 'CatPortBox'){
            $script:deviceCatalog=[pscustomobject][ordered]@{
                serial_ports=@([pscustomobject][ordered]@{PortName='COM11';FriendlyName='R126 fake CAT radio';IsHri=$false;CatMatchRank=100})
                hri_ports=@()
                cat_ports=@()
                wave_inputs=@()
                wave_outputs=@()
            }
            if(-not $script:radioControlPreferences){$script:radioControlPreferences=Get-UiDefaultRadioControlPreferences}
            $script:radioControlPreferences.cat_port='auto'
            $script:radioCatDeviceCatalogSignature=''
            Set-UiRadioCatDeviceControls
            continue
        }
        $tag=if($name -ceq 'CatPortBox'){
            [pscustomobject][ordered]@{Kind='cat';Label='自定义电台 · 推荐 CAT · COM77';Value='COM77'}
        }else{
            [pscustomobject][ordered]@{Kind='auto';Label='自动';Value='auto'}
        }
        $item=New-Object System.Windows.Controls.ComboBoxItem
        $item.Tag=$tag;$item.Content=[string]$tag.Label
        [void]$combo.Items.Add($item)
    }
    $script:channels=@([pscustomobject][ordered]@{id=[uint64]91;kind='group';slot=[uint64]1;name='用户自定义组名'})
    $script:txChannelKey='group:91:1'
    $script:mutedChannelKeys=@{}
    $script:controlRunId='localization-fixture'
    $script:queuedQuickCall=[pscustomobject][ordered]@{run_id='localization-fixture';queue_id='queue-fixture';channel_key='group:91:1';destination_id=[uint64]91;slot=1}
    $script:pendingQuickCall=[pscustomobject][ordered]@{run_id='localization-fixture';request_id='request-fixture';channel_key='group:91:1';destination_id=[uint64]91;slot=1;timed_out=$false}
    $script:callHistoryModel.Clear();$script:callHistoryKeys=@{};$script:selectedCallHistoryKey='';$script:callHistoryPageIndex=0
    $historyEntry=[pscustomobject][ordered]@{key='language-history-fixture';run_id='language-fixture';generation=[uint64]1;source_id=[uint64]123456;destination_id=[uint64]91;slot=[uint64]1;kind='private';timestamp=[DateTime]::Now;source_label='N0CALL · 用户姓名';identity_details='';text='来话 1 · 私呼 · 来源 N0CALL'}
    $script:callHistoryModel.Add($historyEntry);$script:callHistoryKeys[$historyEntry.key]=$true
    $script:mainWindow.FindName('CallsignBox').Text='UNSAVED-CALLSIGN'
    $script:mainWindow.FindName('MasterBox').Text='unsaved-master.example'
    $script:mainWindow.FindName('CatMainFrequencyMHzBox').Text='145.12345'
    Set-UiTransientStatus -Message 'BM 连接状态尚未更新；请检查当前连接状态后重试。' -Restart
    Update-UiChannelDisplays
    Render-UiCallHistoryPage

    $catPortBox=$script:mainWindow.FindName('CatPortBox')
    $catPortBox.ApplyTemplate()
    $editableCatPortBox=$catPortBox.Template.FindName('PART_EditableTextBox',$catPortBox)
    Assert-Locale ($editableCatPortBox -is [System.Windows.Controls.TextBox] -and $catPortBox.SelectedItem.Tag.Value -ceq 'COM11') '离线WPF测试没有使用真实可编辑CAT组合框和合成COM11条目'
    $unmodifiedCatSelection=$catPortBox.SelectedItem
    $catPortBox.Text=[string]$unmodifiedCatSelection.Content
    $script:radioCatPortSelectionExplicit=$true
    $script:radioCatPortTextEditExplicit=$false
    [void](Set-UiLanguagePreference -Language 'en-US')
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    Assert-Locale ($unmodifiedCatSelection.Content -match 'Recommended CAT' -and $catPortBox.Text -match 'Recommended CAT' -and (Get-UiRadioCatSelectedPort) -ceq 'COM11') '未编辑的COM11选择没有显示英文caption或getter没有返回Tag值'
    [void](Set-UiLanguagePreference -Language 'zh-CN')
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    Assert-Locale ($unmodifiedCatSelection.Content -match '推荐 CAT' -and $catPortBox.Text -match '推荐 CAT' -and (Get-UiRadioCatSelectedPort) -ceq 'COM11') '未编辑的COM11选择没有恢复中文caption或getter没有返回Tag值'
    [void]$editableCatPortBox.Focus()
    [void][System.Windows.Input.Keyboard]::Focus($editableCatPortBox)
    $editableCatPortBox.Text='COM99'
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    $editableCatPortBox.Select(3,2)
    $catSelectedItemBefore=$catPortBox.SelectedItem
    $catTextSelectionStartBefore=[int]$editableCatPortBox.SelectionStart
    $catTextSelectionLengthBefore=[int]$editableCatPortBox.SelectionLength
    Assert-Locale ($catPortBox.Text -ceq 'COM99' -and $script:radioCatPortTextEditExplicit -and (Get-UiRadioCatSelectedPort) -ceq 'COM99') '真实XAML编辑COM99后，CAT getter没有优先返回手动输入'
    Update-UiDeviceOptionLanguage
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    Assert-Locale ($catPortBox.Text -ceq 'COM99' -and [object]::ReferenceEquals($catPortBox.SelectedItem,$catSelectedItemBefore) -and (Get-UiRadioCatSelectedPort) -ceq 'COM99') '相同语言caption更新覆盖CAT手动输入或选择'
    [void](Set-UiLanguagePreference -Language 'en-US')
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    Assert-Locale ($catPortBox.Text -ceq 'COM99' -and [object]::ReferenceEquals($catPortBox.SelectedItem,$catSelectedItemBefore) -and (Get-UiRadioCatSelectedPort) -ceq 'COM99') '英文caption变化后CAT getter误读为Tag中的COM11'
    Assert-Locale ($editableCatPortBox.SelectionStart -eq $catTextSelectionStartBefore -and $editableCatPortBox.SelectionLength -eq $catTextSelectionLengthBefore) '英文caption变化移动了手动输入的文本选择'
    [void](Set-UiLanguagePreference -Language 'zh-CN')
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    Assert-Locale ($catPortBox.Text -ceq 'COM99' -and [object]::ReferenceEquals($catPortBox.SelectedItem,$catSelectedItemBefore) -and (Get-UiRadioCatSelectedPort) -ceq 'COM99') '中文caption恢复后CAT getter没有保留COM99'
    Assert-Locale ($editableCatPortBox.SelectionStart -eq $catTextSelectionStartBefore -and $editableCatPortBox.SelectionLength -eq $catTextSelectionLengthBefore) '中文caption恢复移动了手动输入的文本选择'

    $script:deviceCatalog.serial_ports=@([pscustomobject][ordered]@{PortName='COM11';FriendlyName='R126 refreshed fake CAT radio';IsHri=$false;CatMatchRank=100})
    Set-UiRadioCatDeviceControls
    Update-UiDeviceOptionLanguage
    $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Input)
    $refreshedCatPortBox=$script:mainWindow.FindName('CatPortBox')
    Assert-Locale ($refreshedCatPortBox.Text -ceq 'COM99' -and $script:radioCatPortTextEditExplicit -and (Get-UiRadioCatSelectedPort) -ceq 'COM99') '合成设备刷新覆盖CAT手动端口或getter误读COM11'
    Assert-Locale (@($refreshedCatPortBox.Items|Where-Object{$_.Tag.Value -ceq 'COM11'}).Count -eq 1) '合成设备刷新丢失假COM11下拉项'

    $sendSpy=[pscustomobject]@{HasExited=$false;SendCount=0}
    $sendSpy | Add-Member -MemberType ScriptMethod -Name SendControlCommand -Value { param($RequestId,$Command,$Json);$this.SendCount++;return $true }
    $oldSupervisor=$script:supervisor
    $script:supervisor=$sendSpy
    $comboNames=@('SerialBox','CatPortBox','WaveInEndpointBox','WaveOutEndpointBox')
    $tagsBefore=Get-ComboTagSnapshot -Names $comboNames
    $channelKeysBefore=@($script:channels|ForEach-Object{Get-UiChannelKey -Channel $_}) -join '|'
    $txBefore=[string]$script:txChannelKey
    $queueBefore=ConvertTo-Json -InputObject $script:queuedQuickCall -Compress -Depth 8
    $pendingBefore=ConvertTo-Json -InputObject $script:pendingQuickCall -Compress -Depth 8
    $pendingRequestsBefore=[int]$script:pendingControlRequests.Count
    $bmPendingBefore=ConvertTo-Json -InputObject $script:bmConnectionPendingRequest -Compress -Depth 8
    $catGenerationBefore=[int]$script:radioCatSessionGeneration
    $preparationBefore=[bool]$script:preparationStarted
    $stopBefore=[bool]($script:stopTask -or $script:prepareStopAsync -or $script:serialDisconnectPending)
    $callsignDraftBefore=[string]$script:mainWindow.FindName('CallsignBox').Text
    $masterDraftBefore=[string]$script:mainWindow.FindName('MasterBox').Text
    $frequencyDraftBefore=[string]$script:mainWindow.FindName('CatMainFrequencyMHzBox').Text
    $removeButton=$script:mainWindow.FindName('RemoveBmStaticGroupButton')
    $staticRemoveSource=[string]$removeButton.Content
    $connectionFieldsBefore=Get-ConfigWithoutLanguage -Path $configPath

    foreach($language in @('en-US','en-US','zh-CN','zh-CN')){
        [void](Set-UiLanguagePreference -Language $language)
        $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Render)
        if($language -ceq 'en-US'){
            Assert-Locale ($removeButton.Content -ceq 'Remove' -and $languageButton.Visibility -eq [System.Windows.Visibility]::Collapsed -and -not $languageButton.IsEnabled) '内部翻译函数未更新静态文案，或主界面语言入口变为可见/可用'
            Assert-Locale ($script:mainWindow.FindName('TransientStatusText').Text -match '^BM connection state has not updated') 'BM动态状态没有随语言即时翻译'
            Assert-Locale ($script:mainWindow.FindName('BmStaticGroupSourceValue').Text -ceq 'Device 1') 'BM来源标签没有随语言切换'
            Assert-Locale ($script:mainWindow.FindName('CatObservedMainModeText').Text -ceq '') '切换语言改变了隐藏MAIN观测源文本'
            Assert-Locale ($script:mainWindow.FindName('CatPortBox').Items[0].Content -ceq 'R126 refreshed fake CAT radio · Recommended CAT · COM11') 'CAT设备友好名称被翻译或用途标记未翻译'
            Assert-Locale ([string]$script:mainWindow.FindName('CallHistoryList').Items[0].display_text -match 'N0CALL · 用户姓名') '来话历史的用户姓名被翻译或丢失'
            $presentation=Get-UiChannelActivationPresentation -Channel $script:channels[0]
            Assert-Locale ($presentation.title -match 'Group 91 · 用户自定义组名') '频道标签中的自定义组名被翻译或丢失'
        } else {
            Assert-Locale ($removeButton.Content -ceq '移除' -and $languageButton.Visibility -eq [System.Windows.Visibility]::Collapsed -and -not $languageButton.IsEnabled) '内部翻译函数没有恢复中文源文案，或主界面语言入口变为可见/可用'
            Assert-Locale ($script:mainWindow.FindName('TransientStatusText').Text -match 'BM 连接状态尚未更新') 'BM动态状态没有恢复中文源文案'
        }
    }
    $languageButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-Locale ($languageButton.Visibility -eq [System.Windows.Visibility]::Collapsed -and -not $languageButton.IsEnabled -and $script:uiLanguage -ceq 'zh-CN') '本地化实现测试意外启用了主界面的语言切换入口'

    Assert-Locale ((Get-ComboTagSnapshot -Names $comboNames) -ceq $tagsBefore) '语言切换修改了串口或音频endpoint的Tag值'
    Assert-Locale ((@($script:channels|ForEach-Object{Get-UiChannelKey -Channel $_}) -join '|') -ceq $channelKeysBefore -and [string]$script:txChannelKey -ceq $txBefore) '语言切换修改了频道列表或PTT目标'
    Assert-Locale ((ConvertTo-Json -InputObject $script:queuedQuickCall -Compress -Depth 8) -ceq $queueBefore -and (ConvertTo-Json -InputObject $script:pendingQuickCall -Compress -Depth 8) -ceq $pendingBefore) '语言切换清除了待激活请求或排队请求'
    Assert-Locale ([int]$script:pendingControlRequests.Count -eq $pendingRequestsBefore -and [int]$sendSpy.SendCount -eq 0) '语言切换新增控制请求或发送控制命令'
    Assert-Locale ((ConvertTo-Json -InputObject $script:bmConnectionPendingRequest -Compress -Depth 8) -ceq $bmPendingBefore -and [int]$script:radioCatSessionGeneration -eq $catGenerationBefore) '语言切换改变BM请求或CAT会话代次'
    Assert-Locale ([bool]$script:preparationStarted -eq $preparationBefore -and [bool]($script:stopTask -or $script:prepareStopAsync -or $script:serialDisconnectPending) -eq $stopBefore) '语言切换启动了重连、停止或串口断开流程'
    Assert-Locale ($script:mainWindow.FindName('CallsignBox').Text -ceq $callsignDraftBefore -and $script:mainWindow.FindName('MasterBox').Text -ceq $masterDraftBefore -and $script:mainWindow.FindName('CatMainFrequencyMHzBox').Text -ceq $frequencyDraftBefore) '语言切换覆盖未保存的呼号、主站或CAT频率输入'
    Assert-Locale ((Get-ConfigWithoutLanguage -Path $configPath) -ceq $savedConfigWithoutLanguage) '语言切换写入了ui.language以外的config字段'
    $diskConfig=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($configPath,[Text.Encoding]::UTF8))
    Assert-Locale ($diskConfig.connection.callsign -ceq 'N0SAVED' -and $diskConfig.future_extension.preserve -ceq 'keep-me' -and [int]$diskConfig.future_extension.revision -eq 7) '语言切换覆盖已保存连接资料或未识别配置字段'

    $localizerPath=Join-Path $repo 'ui\windows\UiLocalization.psm1'
    $samples=[ordered]@{
        '已读取 3 条 BM 静态组；设备状态 4，添加已禁用。'='Read 3 BM static groups; device status 4; adding is disabled.'
        'CAT 设置已取消，没有发送写入：当前端口不可用。'='CAT settings were cancelled. No write was sent: 当前端口不可用。'
        'TG 91 TS1 等待当前通话结束超时；没有发送激活请求。'='TG 91 TS1 timed out waiting for the current call to end; no activation request was sent.'
        '已取消 TG 91 TS1 的排队；没有发送激活请求。'='Cancelled the queued request for TG 91 TS1; no activation request was sent.'
        '正在加入频道；等待核心确认当前频道设置。'='Applying add channel; waiting for the core to confirm channel settings.'
        '向本机 Native 请求发送一次动态组 Quick Call；本机只报告发送结果，不回读 BM 当前动态组。'='Send one dynamic group Quick Call to local Native. The local result reports transmission only; it does not read back the current BM dynamic group.'
        '当前条件不允许发送该设置：请选择明确的 MAIN 调制模式。'='Current conditions do not allow this setting to be sent: Choose a specific MAIN modulation mode.'
        '目标功率 60 W 超出当前路径上限 50 W；请重新选择有效功率。'='Target power 60 W exceeds the current path limit of 50 W. Choose a valid power level.'
    }
    foreach($source in $samples.Keys){Assert-Locale ((ConvertTo-WirexUiDisplayText -Text $source -Language 'en-US') -ceq $samples[$source]) "动态状态翻译缺失或没有保留事实：$source"}
} finally {
    if($script:uiTimer){$script:uiTimer.Stop()}
    $script:supervisor=$oldSupervisor
    $script:allowWindowClose=$true
    if($script:settingsWindow){$script:settingsWindow.Close()}
    if($script:mainWindow){$script:mainWindow.Close()}
    if($script:application){$script:application.Shutdown()}
}

$storedEnglishConfigDirectory=Join-Path $task 'stored-en-language-config'
[void][IO.Directory]::CreateDirectory($storedEnglishConfigDirectory)
$storedEnglishConfigPath=Join-Path $storedEnglishConfigDirectory 'config.json'
$storedEnglishConfig=Get-WirexPortableConfig -Path $storedEnglishConfigPath
$storedEnglishConfig.ui.language='en-US'
[void](Save-WirexPortableConfig -Path $storedEnglishConfigPath -Config $storedEnglishConfig -PersistUiLanguage)
$chineseRenderDirectory=Join-Path $task 'default-chinese-render'
[void][IO.Directory]::CreateDirectory($chineseRenderDirectory)
$oldErrorActionPreference=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    $renderOutput=@(& powershell.exe -NoLogo -NoProfile -STA -File $uiPath -RenderOnly -NoAutoConnect `
        -UserConfigDirectory $storedEnglishConfigDirectory -PackageDirectory $fakePackageDir -PortableDirectory $fakePackageDir `
        -RenderOutputDirectory $chineseRenderDirectory -RenderWorkArea '1360x900' 2>&1)
    $renderExit=$LASTEXITCODE
} finally { $ErrorActionPreference=$oldErrorActionPreference }
if($renderExit -ne 0){throw ('Default Chinese RenderOnly failed for package {0} (wrapper={1}, native={2}): {3}' -f $fakePackageDir,[IO.File]::Exists((Join-Path $fakePackageDir 'start-bm-radio-bridge.ps1')),[IO.File]::Exists((Join-Path $fakePackageDir 'wirex_bridge.exe')),($renderOutput -join [Environment]::NewLine))}
$layoutPath=Join-Path $chineseRenderDirectory 'layout-info.json'
if(-not [IO.File]::Exists($layoutPath)){throw 'RenderOnly did not export layout-info.json'}
$layout=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($layoutPath,[Text.Encoding]::UTF8))
$image=[System.Drawing.Image]::FromFile((Join-Path $chineseRenderDirectory 'main-window.png'))
try{Assert-Locale ($image.Width -eq 1360 -and $image.Height -eq 900) '中文主界面截图不是1360x900'}finally{$image.Dispose()}
function Has-VisibleText { param([object]$Control,[string]$Text) return ([string]$Control.text -ceq $Text -or @($Control.visual_text) -contains $Text) }
$requiredChinese=[ordered]@{
    ConnectionConfigTitleText='连接配置';RefreshDevicesButton='刷新设备';StopButton='停止并退出';
    ConnectButton='连接BM';SaveSettingsButton='保存配置';AddBmStaticGroupButton='添加为静态组';
    CatModeCaptionText='MAIN 模式';CatFrequencyCaptionText='频率 MHz';CatPowerCaptionText='功率 W';
    AddChannelButton='加入监听';SetHistoryCallTargetButton='设为PTT目标'
}
Assert-Locale ($layout.ui_language -ceq 'zh-CN') '保存en-US的配置导致RenderOnly界面使用英文'
Assert-Locale (-not [bool]$layout.main.controls_visible.LanguageToggleButton -and -not [bool]$layout.main.controls_bounds.LanguageToggleButton.is_enabled) 'RenderOnly主界面显示了语言切换按钮或按钮可用'
foreach($controlName in $requiredChinese.Keys){
    $control=$layout.main.controls_bounds.PSObject.Properties[$controlName].Value
    Assert-Locale (Has-VisibleText -Control $control -Text $requiredChinese[$controlName]) "RenderOnly中文窗口缺少控件${controlName}的文案$($requiredChinese[$controlName])"
}
Assert-Locale ([string]$layout.main.controls_bounds.SerialConnectButton.visual_text[0] -match '连接串口|断开串口|取消连接') '中文串口按钮显示了错误文案'
Assert-Locale ([bool]$layout.main.controls_visible.SourceIdCaptionText -and [double]$layout.main.controls_bounds.SourceIdCaptionText.actual.width -gt 0 -and [double]$layout.main.controls_bounds.SourceIdCaptionText.actual.height -gt 0) 'DMR ID 标签没有实际可见的TextBlock边界'
Assert-Locale (-not [bool]$layout.main.controls_visible.CatObservedFrequencyText -and [string]$layout.main.controls_bounds.CatObservedFrequencyText.text -ceq '145.500 MHz') 'CAT频率观测值仍显示或后台值被清空'
Assert-Locale (-not [bool]$layout.main.controls_visible.CatObservedPowerText -and [string]$layout.main.controls_bounds.CatObservedPowerText.text -ceq '25 W') 'CAT功率观测值仍显示或后台值被清空'
Assert-Locale (@($layout.channel_card_layout|Where-Object{-not $_.blank}|ForEach-Object{[string]$_.card_title.text}|Where-Object{$_ -match '组呼|单呼'}).Count -gt 0) '中文RenderOnly频道标题没有显示通话类型'
Assert-Locale ([string]$layout.caller_identity_samples.short.visual_text -join ' ' -match '短呼号测试者') 'RenderOnly窗口翻译了用户姓名'
Assert-Locale ([string]$layout.channel_card_layout[1].card_title.text -match '测试长频道名称') 'RenderOnly窗口翻译了用户自定义频道名称'

Write-Output ("PASS: test-ui-localization.ps1 ({0}断言; runtime default zh-CN; switch hidden/disabled; translator helpers retained; Chinese 1360x900 render={1})" -f $script:assertionCount,$chineseRenderDirectory)
