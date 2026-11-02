#requires -Version 5.1
[CmdletBinding()]
param([switch]$GainOnly,[switch]$DiagnoseSerial)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw '请使用 Windows PowerShell 5.1 运行此回归。' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw '请使用 -STA 运行此 WPF 回归。' }
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Windows.Forms -ErrorAction Stop
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class R124NativeInput {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyInput { public ushort vk; public ushort scan; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int dx; public int dy; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion { [FieldOffset(0)] public KeyInput key; [FieldOffset(0)] public MouseInput mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct InputRecord { public uint type; public InputUnion data; }
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int maxCount);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr window, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, uint length, out uint needed);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("kernel32.dll")] private static extern uint GetTickCount();
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", SetLastError=true)] private static extern bool WTSQuerySessionInformation(IntPtr server, uint session, int infoClass, out IntPtr buffer, out uint bytes);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr buffer);
    [StructLayout(LayoutKind.Sequential)] private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr windowHandle);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, InputRecord[] inputs, int size);
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint code, uint mapType);
    public static string GetInputDesktopName(out int error) {
        IntPtr desktop=OpenInputDesktop(0,false,1); error=Marshal.GetLastWin32Error();
        if(desktop==IntPtr.Zero) return null;
        uint needed; StringBuilder value=new StringBuilder(256);
        bool ok=GetUserObjectInformation(desktop,2,value,512,out needed); int infoError=Marshal.GetLastWin32Error(); CloseDesktop(desktop);
        error=ok?0:infoError; return ok?value.ToString():null;
    }
    public static int GetSessionConnectState(uint session, out bool ok, out int error) {
        IntPtr buffer; uint bytes; ok=WTSQuerySessionInformation(IntPtr.Zero,session,8,out buffer,out bytes); error=Marshal.GetLastWin32Error();
        if(!ok) return -1; int state=Marshal.ReadInt32(buffer); WTSFreeMemory(buffer); return state;
    }
    public static long GetSystemIdleMilliseconds(out bool ok) {
        LASTINPUTINFO info=new LASTINPUTINFO(); info.cbSize=(uint)Marshal.SizeOf(typeof(LASTINPUTINFO)); ok=GetLastInputInfo(ref info);
        return ok?(long)(GetTickCount()-info.dwTime):-1;
    }
    public static bool MoveCursorAbsolute(int x,int y,int width,int height) {
        if(width<=1 || height<=1) return false;
        InputRecord input=new InputRecord(); input.type=0;
        input.data.mouse.dx=(int)Math.Round(x*65535.0/(width-1));
        input.data.mouse.dy=(int)Math.Round(y*65535.0/(height-1));
        input.data.mouse.flags=0x8001;
        return SendInput(1,new InputRecord[]{input},Marshal.SizeOf(typeof(InputRecord)))==1;
    }
    public static bool SendRightArrow() {
        ushort scan=(ushort)MapVirtualKey(0x27,0);
        InputRecord[] inputs=new InputRecord[2];
        inputs[0].type=1; inputs[0].data.key.vk=0x27; inputs[0].data.key.scan=scan; inputs[0].data.key.flags=0x1;
        inputs[1].type=1; inputs[1].data.key.vk=0x27; inputs[1].data.key.scan=scan; inputs[1].data.key.flags=0x3;
        return SendInput(2,inputs,Marshal.SizeOf(typeof(InputRecord)))==2;
    }
}
'@ -ErrorAction Stop

$script:assertionCount = 0
$script:r124MouseTrace = New-Object 'System.Collections.Generic.List[string]'
$script:r124DiagnosticLog = New-Object 'System.Collections.Generic.List[string]'
$script:r124ItemTrace = New-Object 'System.Collections.Generic.List[string]'
$script:r124SelectionTrace = New-Object 'System.Collections.Generic.List[string]'
$script:r124TraceName = ''
$script:r124DiagnoseSerial = [bool]$DiagnoseSerial
function Assert-R124 {
    param([bool]$Condition,[string]$Message)
    $script:assertionCount++
    if (-not $Condition) {
        $trace=if($script:r124DiagnosticLog.Count){"`r`n"+($script:r124DiagnosticLog -join "`r`n")}elseif($script:r124MouseTrace.Count){"`r`n"+($script:r124MouseTrace -join "`r`n")}else{''}
        throw ("ASSERTION FAILED: {0}{1}" -f $Message,$trace)
    }
}

function Get-R124ClickDiagnostic {
    param([string]$Phase,[System.Windows.FrameworkElement]$Element,[System.Windows.Point]$ScreenPoint)
    $window=$script:mainWindow
    $cursor=New-Object 'R124NativeInput+POINT';[void][R124NativeInput]::GetCursorPos([ref]$cursor)
    $underPoint=[R124NativeInput]::WindowFromPoint($cursor)
    $foreground=[R124NativeInput]::GetForegroundWindow();$foregroundPid=[uint32]0
    $foregroundThread=[R124NativeInput]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)
    $foregroundTitle=New-Object Text.StringBuilder 260;$foregroundClass=New-Object Text.StringBuilder 128
    [void][R124NativeInput]::GetWindowText($foreground,$foregroundTitle,$foregroundTitle.Capacity)
    [void][R124NativeInput]::GetClassName($foreground,$foregroundClass,$foregroundClass.Capacity)
    $foregroundProcess=Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
    $foregroundRect=New-Object 'R124NativeInput+RECT';$hasForegroundRect=[R124NativeInput]::GetWindowRect($foreground,[ref]$foregroundRect)
    $windowRect=New-Object 'R124NativeInput+RECT';$windowHandle=(New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $hasWindowRect=[R124NativeInput]::GetWindowRect($windowHandle,[ref]$windowRect)
    $hit='';$direct='';$hitChain=New-Object 'System.Collections.Generic.List[string]'
    if($window -and $ScreenPoint){
        $clientPoint=$window.PointFromScreen($ScreenPoint)
        $hitElement=$window.InputHitTest($clientPoint)
        if($hitElement){$hit=$hitElement.GetType().Name+'#'+[string]$hitElement.Name}
        $directElement=[System.Windows.Input.Mouse]::DirectlyOver
        if($directElement){$direct=$directElement.GetType().Name+'#'+[string]$directElement.Name;$node=$directElement
            while($node -is [System.Windows.DependencyObject] -and $hitChain.Count -lt 8){$name=if($node -is [System.Windows.FrameworkElement]){[string]$node.Name}else{''};$hitChain.Add($node.GetType().Name+'#'+$name);$node=[System.Windows.Media.VisualTreeHelper]::GetParent($node)}
        }
    }
    $desktopError=0;$desktop=[R124NativeInput]::GetInputDesktopName([ref]$desktopError)
    $session=[R124NativeInput]::WTSGetActiveConsoleSessionId();$sessionOk=$false;$sessionError=0
    $sessionState=[R124NativeInput]::GetSessionConnectState($session,[ref]$sessionOk,[ref]$sessionError)
    $idleOk=$false;$idleMs=[R124NativeInput]::GetSystemIdleMilliseconds([ref]$idleOk)
    $overHandle=('0x{0:X}' -f $underPoint.ToInt64())
    $foregroundHandle=('0x{0:X}' -f $foreground.ToInt64())
    $windowHandleText=('0x{0:X}' -f $windowHandle.ToInt64())
    $foregroundBounds=if($hasForegroundRect){'{0},{1},{2},{3}' -f $foregroundRect.Left,$foregroundRect.Top,$foregroundRect.Right,$foregroundRect.Bottom}else{'unavailable'}
    $windowBounds=if($hasWindowRect){'{0},{1},{2},{3}' -f $windowRect.Left,$windowRect.Top,$windowRect.Right,$windowRect.Bottom}else{'unavailable'}
    $pointText=if($ScreenPoint){'{0},{1}' -f [Math]::Round($ScreenPoint.X),[Math]::Round($ScreenPoint.Y)}else{'<none>'}
    return ("{0}: element={1} enabled={2} visibility={3} bounds={4:0.0}x{5:0.0}@{6:0.0},{7:0.0} windowVisible={8} windowActive={9} windowHandle={10} windowRect={11} point={12} cursor={13},{14} windowAtCursor={15} foreground={16}/{17}/{18} foregroundRect={19} foregroundThread={20} foregroundIsTestWindow={21} desktop={22} desktopError={23} consoleSession={24} sessionState={25} sessionQueryOk={26} sessionError={27} idleMs={28} idleQueryOk={29} wpfInputHit={30} mouseDirectlyOver={31} visualChain={32}" -f $Phase,$Element.Name,$Element.IsEnabled,$Element.Visibility,$Element.ActualWidth,$Element.ActualHeight,$Element.PointToScreen([System.Windows.Point]::new(0,0)).X,$Element.PointToScreen([System.Windows.Point]::new(0,0)).Y,[R124NativeInput]::IsWindowVisible($windowHandle),$window.IsActive,$windowHandleText,$windowBounds,$pointText,$cursor.X,$cursor.Y,$overHandle,$foregroundHandle,$foregroundProcess.ProcessName,$foregroundTitle.ToString(),$foregroundBounds,$foregroundThread,($foreground -eq $windowHandle),$desktop,$desktopError,$session,$sessionState,$sessionOk,$sessionError,$idleMs,$idleOk,$hit,$direct,($hitChain -join '>'))
}

function Add-R124MouseTrace {
    param([string]$Phase,[object]$Sender,[object]$EventArgs)
    if(-not $script:r124DiagnoseSerial -or $script:r124TraceName -cne 'SerialBox'){return}
    $source=if($EventArgs -and $EventArgs.Source){$EventArgs.Source.GetType().Name}else{''}
    $original=if($EventArgs -and $EventArgs.OriginalSource){$EventArgs.OriginalSource.GetType().Name}else{''}
    $handled=if($EventArgs){[bool]$EventArgs.Handled}else{$false}
    $focused=if([System.Windows.Input.Keyboard]::FocusedElement){[System.Windows.Input.Keyboard]::FocusedElement.GetType().Name}else{'<none>'}
    $open=if($script:mainWindow){[bool]$script:mainWindow.FindName('SerialBox').IsDropDownOpen}else{$false}
    $point=$null
    if($script:r124TraceControl -and $script:r124TraceControl.ActualWidth -gt 0){$point=$script:r124TraceControl.PointToScreen([System.Windows.Point]::new($script:r124TraceControl.ActualWidth/2,$script:r124TraceControl.ActualHeight/2))}
    $route=("{0}: eventSender={1}; source={2}; original={3}; handled={4}; open={5}; focus={6}" -f $Phase,$Sender.GetType().Name,$source,$original,$handled,$open,$focused)
    $script:r124MouseTrace.Add($route)
    $script:r124DiagnosticLog.Add((Get-R124ClickDiagnostic -Phase $Phase -Element $script:r124TraceControl -ScreenPoint $point))
}

function Add-R124ItemTrace {
    param([string]$Phase,[object]$Sender,[object]$EventArgs)
    $handled=if($EventArgs){[bool]$EventArgs.Handled}else{$false}
    $script:r124ItemTrace.Add(("{0}: selected={1}; handled={2}; open={3}" -f $Phase,[bool]$Sender.IsSelected,$handled,[bool]$script:mainWindow.FindName('ChannelIdBox').IsDropDownOpen))
}

function Invoke-R124UiPump {
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:mainWindow -and $script:mainWindow.Dispatcher.CheckAccess()) {
        $script:mainWindow.Dispatcher.Invoke([Action]{},[System.Windows.Threading.DispatcherPriority]::Background)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-R124ScreenClick {
    param([System.Windows.Point]$Point)
    if (-not [R124NativeInput]::SetCursorPos([int][Math]::Round($Point.X),[int][Math]::Round($Point.Y))) { throw '无法定位真实鼠标。' }
    Add-R124MouseTrace -Phase 'SetCursorPos' -Sender $script:r124TraceControl -EventArgs $null
    [R124NativeInput]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
    Add-R124MouseTrace -Phase 'LeftDown' -Sender $script:r124TraceControl -EventArgs $null
    Start-Sleep -Milliseconds 35
    Invoke-R124UiPump
    Add-R124MouseTrace -Phase 'AfterDownPump' -Sender $script:r124TraceControl -EventArgs $null
    [R124NativeInput]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
    Add-R124MouseTrace -Phase 'LeftUp' -Sender $script:r124TraceControl -EventArgs $null
    Start-Sleep -Milliseconds 65
    Invoke-R124UiPump
    Add-R124MouseTrace -Phase 'AfterUpPump' -Sender $script:r124TraceControl -EventArgs $null
}

function Invoke-R124ElementClick {
    param([System.Windows.FrameworkElement]$Element,[double]$XFraction=0.5,[double]$YFraction=0.5)
    $script:r124TraceControl=$Element;$script:r124TraceName=[string]$Element.Name
    [void]$Element.UpdateLayout()
    $point=$Element.PointToScreen([System.Windows.Point]::new($Element.ActualWidth*$XFraction,$Element.ActualHeight*$YFraction))
    Invoke-R124ScreenClick -Point $point
}

function Set-R124TextWithKeyboard {
    param([System.Windows.Controls.TextBox]$TextBox,[string]$Text)
    [void]$TextBox.Focus()
    Invoke-R124UiPump
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait($Text)
    Start-Sleep -Milliseconds 40
    Invoke-R124UiPump
}

function Get-R124SliderPart {
    param([System.Windows.Controls.Slider]$Slider,[string]$Name)
    [void]$Slider.ApplyTemplate();[void]$Slider.UpdateLayout()
    return $Slider.Template.FindName($Name,$Slider)
}

$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridgePath=Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$xamlPath=Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
foreach($path in @($PSCommandPath,$bridgePath,$xamlPath)){
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-R124 ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ("{0} 缺少 UTF-8 BOM" -f [IO.Path]::GetFileName($path))
}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($bridgePath,[ref]$tokens,[ref]$parseErrors)
Assert-R124 ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 语法解析失败'
$functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
Invoke-Expression (($functions | ForEach-Object {$_.Extent.Text}) -join "`r`n")

# 隔离运行时回调：鼠标操作仍触发生产的 ValueChanged handler，发送边界由内存假 core 接收。
function Start-UiChannelMutation {
    param([object[]]$Channels,[string]$TxKey,[hashtable]$MutedKeys=@{},[string]$Action='更新频道')
    $script:lastR124ChannelMutation=[pscustomobject]@{channels=@($Channels);tx_key=$TxKey;muted_keys=$MutedKeys;action=$Action}
    return $true
}
function Set-UiAudioGainStatus { param([AllowEmptyString()][string]$Text,[switch]$Failed) $script:lastR124AudioGainStatus=$Text }
function Format-BridgeGain { param([uint32]$GainMilli) return ([double]$GainMilli / 1000.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture) }

$script:mainWindow=Import-WpfWindow -Path $xamlPath
$script:mainWindow.WindowStartupLocation=[System.Windows.WindowStartupLocation]::Manual
$script:mainWindow.Left=0;$script:mainWindow.Top=0;$script:mainWindow.Opacity=0.03
$script:mainWindow.ShowInTaskbar=$false;$script:mainWindow.Topmost=$true
$script:mainXamlPath=$xamlPath
$script:channels=@();$script:txChannelKey='';$script:mutedChannelKeys=@{}
$script:channelEditorSlot=[uint64]2;$script:channelPresetId='';$script:channelPresetKind='';$script:loadingChannelPreset=$false
$script:audioGainProgrammaticUpdate=$false;$script:loadingSettings=$false
$script:audioGainNativeCapability=$false;$script:audioGainCommandRejected=$false
$script:audioGainRuntimeReady=$false;$script:audioGainRunId='';$script:audioGainRevision=[uint64]0
$script:audioGainActual=$null;$script:audioGainDraftRevision=[uint64]0;$script:audioGainResolvedDraftRevision=[uint64]0
$script:audioGainDraft=$null;$script:audioGainPendingRequest=$null;$script:audioGainExpiredRequests=@{}
$script:audioGainAwaitingStatus=$false;$script:audioGainTimedOutDraftRevision=[uint64]0;$script:audioGainDebounceReady=$false
$script:audioGainDebounceTimer=$null;$script:audioGainStatusText='';$script:controlConfirmed=$false;$script:controlRunId=''
$script:pendingControlRequests=@{};$script:preparationStarted=$false;$script:stopTask=$null
$script:nativeExitCleanupPending=$false;$script:channelMutationSafetyStopPending=$false
$script:portableConfig=[pscustomobject]@{audio=[pscustomobject]@{radio_playback_gain=[decimal]1;mic_transmit_gain=[decimal]16}}
$script:lastR124ChannelMutation=$null
$script:mainWindow.Show();[void]$script:mainWindow.Activate();$script:mainWindow.UpdateLayout();Invoke-R124UiPump

try {
    Add-UiComboOpenHandlers -Window $script:mainWindow
    Assert-R124 (Initialize-UiChannelInputHandlers) '可编辑频道框没有取得输入文本框'

    $serialTrace=$script:mainWindow.FindName('SerialBox')
    if($script:r124DiagnoseSerial){
        $serialTrace.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124MouseTrace -Phase 'Serial.PreviewMouseLeftButtonDown' -Sender $sender -EventArgs $eventArgs},$true)
        $serialTrace.AddHandler([System.Windows.UIElement]::PreviewMouseDownEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124MouseTrace -Phase 'Serial.PreviewMouseDown' -Sender $sender -EventArgs $eventArgs},$true)
        $serialTrace.AddHandler([System.Windows.UIElement]::MouseDownEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124MouseTrace -Phase 'Serial.MouseDown' -Sender $sender -EventArgs $eventArgs},$true)
        $serialTrace.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124MouseTrace -Phase 'Serial.PreviewMouseLeftButtonUp' -Sender $sender -EventArgs $eventArgs},$true)
        $serialTrace.AddHandler([System.Windows.UIElement]::PreviewMouseUpEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124MouseTrace -Phase 'Serial.PreviewMouseUp' -Sender $sender -EventArgs $eventArgs},$true)
        $serialTrace.AddHandler([System.Windows.UIElement]::MouseUpEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124MouseTrace -Phase 'Serial.MouseUp' -Sender $sender -EventArgs $eventArgs},$true)
    }

    if (-not $GainOnly) {
    # 每个真实 ComboBox 都从主体坐标接收鼠标点击并展开 Popup。
    $comboNames=@(([xml][IO.File]::ReadAllText($xamlPath,[Text.Encoding]::UTF8)).SelectNodes("//*[local-name()='ComboBox']") | ForEach-Object {
        $name=$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if($name){$name}
    })
    Assert-R124 ($comboNames.Count -ge 11) 'XAML ComboBox 清单没有包含主窗口的全部下拉控件'
    foreach($name in $comboNames){
        $combo=$script:mainWindow.FindName($name)
        Assert-R124 ($combo -is [System.Windows.Controls.ComboBox] -and $combo.IsVisible -and $combo.IsEnabled -and $combo.ActualWidth -gt 20 -and $combo.ActualHeight -gt 15) ("$name 没有可点击的主体边界")
        $combo.IsDropDownOpen=$false
        if($script:r124DiagnoseSerial -and $name -ceq 'SerialBox'){
            $script:r124TraceControl=$combo;$script:r124TraceName='SerialBox';$script:r124MouseTrace.Clear();$script:r124DiagnosticLog.Clear()
            $serialCenter=$combo.PointToScreen([System.Windows.Point]::new($combo.ActualWidth/2,$combo.ActualHeight/2))
            Add-R124MouseTrace -Phase 'BeforeClick' -Sender $combo -EventArgs $null
        }
        Invoke-R124ElementClick -Element $combo
        if($script:r124DiagnoseSerial -and $name -ceq 'SerialBox'){
            Write-Output ("SERIAL_DIAGNOSTIC clickPoint={0:0},{1:0} open={2} popup={3}" -f $serialCenter.X,$serialCenter.Y,$combo.IsDropDownOpen,[bool]($combo.Template.FindName('PART_Popup',$combo) -and $combo.Template.FindName('PART_Popup',$combo).IsOpen))
            foreach($entry in $script:r124DiagnosticLog){Write-Output $entry}
            foreach($entry in $script:r124MouseTrace){Write-Output $entry}
        }
        Assert-R124 ($combo.IsDropDownOpen) ("点击 $name 主体没有打开下拉列表")
        $popup=$combo.Template.FindName('PART_Popup',$combo)
        Assert-R124 ($popup -and $popup.IsOpen) ("$name 的 WPF Popup 没有真正打开")
        $combo.IsDropDownOpen=$false;Invoke-R124UiPump
    }

    # 编辑框由真实键盘输入，点击展开列表后仍可编辑频道号和频率。
    $channelId=$script:mainWindow.FindName('ChannelIdBox')
    $channelText=$channelId.Template.FindName('PART_EditableTextBox',$channelId)
    $channelId.Add_SelectionChanged({param($sender,$eventArgs) $selected=if($sender.SelectedItem -is [System.Windows.Controls.ComboBoxItem]){[string]$sender.SelectedItem.Tag.id}else{'<none>'};$script:r124SelectionTrace.Add(("SelectionChanged index={0}; selected={1}; text={2}; preset={3}; loading={4}" -f $sender.SelectedIndex,$selected,$sender.Text,$script:channelPresetId,$script:loadingChannelPreset))})
    Invoke-R124ElementClick -Element $channelId
    Assert-R124 ($channelId.IsDropDownOpen -and [object]::ReferenceEquals([System.Windows.Input.Keyboard]::FocusedElement,$channelText)) '点击频道输入区没有同时展开列表并保留文本焦点'
    Set-R124TextWithKeyboard -TextBox $channelText -Text '12345'
    Assert-R124 ([string]$channelId.Text -ceq '12345' -and $channelId.IsDropDownOpen) '频道列表展开时键盘输入没有保留为纯数字'
    $channelId.IsDropDownOpen=$false;Invoke-R124UiPump

    $frequency=$script:mainWindow.FindName('CatMainFrequencyMHzBox')
    $frequencyText=$frequency.Template.FindName('PART_EditableTextBox',$frequency)
    Invoke-R124ElementClick -Element $frequency
    Assert-R124 ($frequency.IsDropDownOpen -and [object]::ReferenceEquals([System.Windows.Input.Keyboard]::FocusedElement,$frequencyText)) '点击频率输入区没有展开列表并保留文本焦点'
    Set-R124TextWithKeyboard -TextBox $frequencyText -Text '145.725'
    Assert-R124 ([string]$frequency.Text -ceq '145.725' -and $frequency.IsDropDownOpen) '频率输入在列表展开后没有保留手输值'
    $frequency.IsDropDownOpen=$false;Invoke-R124UiPump

    # 点击中文频道预设容器后，SelectionChanged 保留对象元数据并把纯 ID/类型写回输入框。
    $channelId.Text='';$channelId.SelectedIndex=-1
    Invoke-R124ElementClick -Element $channelId
    Assert-R124 $channelId.IsDropDownOpen '频道预设列表未打开'
    Start-Sleep -Milliseconds 220;Invoke-R124UiPump
    $preset=$channelId.ItemContainerGenerator.ContainerFromIndex(0)
    Assert-R124 ($preset -is [System.Windows.Controls.ComboBoxItem] -and $preset.ActualWidth -gt 0) '中文频道预设没有生成可点击项'
    $preset.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124ItemTrace -Phase 'Preset.PreviewDown' -Sender $sender -EventArgs $eventArgs},$true)
    $preset.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124ItemTrace -Phase 'Preset.Down' -Sender $sender -EventArgs $eventArgs},$true)
    $preset.AddHandler([System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124ItemTrace -Phase 'Preset.PreviewUp' -Sender $sender -EventArgs $eventArgs},$true)
    $preset.AddHandler([System.Windows.UIElement]::MouseLeftButtonUpEvent,[System.Windows.Input.MouseButtonEventHandler]{param($sender,$eventArgs) Add-R124ItemTrace -Phase 'Preset.Up' -Sender $sender -EventArgs $eventArgs},$true)
    $preset.Add_Selected({param($sender,$eventArgs) Add-R124ItemTrace -Phase 'Preset.Selected' -Sender $sender -EventArgs $eventArgs})
    $presetPoint=$preset.PointToScreen([System.Windows.Point]::new($preset.ActualWidth/2,$preset.ActualHeight/2))
    $script:r124TraceName='';$script:r124MouseTrace.Clear()
    $script:r124ItemTrace.Clear();$script:r124SelectionTrace.Clear()
    [void][R124NativeInput]::SetCursorPos([int][Math]::Round($presetPoint.X),[int][Math]::Round($presetPoint.Y));Start-Sleep -Milliseconds 70;Invoke-R124UiPump
    $hoverParts=New-Object 'System.Collections.Generic.List[string]';$hoverElement=[System.Windows.Input.Mouse]::DirectlyOver
    while($hoverElement -is [System.Windows.DependencyObject]){$hoverParts.Add($hoverElement.GetType().Name);if($hoverElement -is [System.Windows.Controls.ComboBoxItem]){break};$hoverElement=[System.Windows.Media.VisualTreeHelper]::GetParent($hoverElement)}
    $presetHover=($hoverParts -join '>')+'; itemIsMouseOver='+[string]$preset.IsMouseOver
    Invoke-R124ScreenClick -Point $presetPoint
    Assert-R124 ([string]$script:channelPresetId -ceq '460997' -and -not $channelId.IsDropDownOpen) ("鼠标点击中文预设没有触发实际 SelectionChanged (index={0}, preset={1}, itemSelected={2}, open={3}, point={4},{5}, item={6}x{7}, hover={8}; events={9}; selection={10})" -f $channelId.SelectedIndex,$script:channelPresetId,$preset.IsSelected,$channelId.IsDropDownOpen,$presetPoint.X,$presetPoint.Y,$preset.ActualWidth,$preset.ActualHeight,$presetHover,($script:r124ItemTrace -join '|'),($script:r124SelectionTrace -join '|'))
    Assert-R124 ([string]$channelId.Text -ceq '460997') '选择中文频道预设后输入框没有显示纯 DMR ID'
    $kind=$script:mainWindow.FindName('ChannelKindBox')
    $selectedKind=if($kind.SelectedItem -is [System.Windows.Controls.ComboBoxItem]){[string]$kind.SelectedItem.Tag}else{''}
    Assert-R124 ($selectedKind -ceq 'private') '中文频道预设没有把单呼类型同步到类型框'
    [void](Add-UiChannelFromInputs)
    Assert-R124 ($script:lastR124ChannelMutation -and @($script:lastR124ChannelMutation.channels).Count -eq 1 -and
        [uint64]$script:lastR124ChannelMutation.channels[0].id -eq 460997 -and [string]$script:lastR124ChannelMutation.channels[0].kind -ceq 'private') '中文预设加入监听没有得到正确 ID 与单呼类型'
    }

    # 滑块轨道、旋钮、键盘和禁用状态均通过模板实物与真实输入验证。
    $playback=$script:mainWindow.FindName('PlaybackGainSlider')
    $transmit=$script:mainWindow.FindName('TransmitGainSlider')
    foreach($slider in @($playback,$transmit)){
        Assert-R124 ($slider.Minimum -eq 0.25 -and $slider.Maximum -eq 16 -and -not $slider.IsSnapToTickEnabled -and $slider.IsMoveToPointEnabled) ("$($slider.Name) 增益范围或连续输入设置错误")
        $track=Get-R124SliderPart -Slider $slider -Name 'PART_Track'
        $thumb=Get-R124SliderPart -Slider $slider -Name 'PART_Thumb'
        $rail=Get-R124SliderPart -Slider $slider -Name 'TrackRail'
        $ticks=Get-R124SliderPart -Slider $slider -Name 'TickDots'
        Assert-R124 ($track -is [System.Windows.Controls.Primitives.Track] -and $thumb -is [System.Windows.Controls.Primitives.Thumb] -and $thumb.ActualWidth -ge 26 -and $rail.ActualHeight -ge 18 -and $ticks.Children.Count -eq 7) ("$($slider.Name) 模板没有可操作的 PART_Track/thumb/刻点")
    }

    $playback.Value=0.25;Invoke-R124UiPump
    $track=Get-R124SliderPart -Slider $playback -Name 'PART_Track'
    $point=$track.PointToScreen([System.Windows.Point]::new($track.ActualWidth*0.413,$track.ActualHeight/2))
    Invoke-R124ScreenClick -Point $point
    Assert-R124 ($playback.Value -gt 0.25 -and $playback.Value -lt 16) '鼠标点击轨道没有移动增益'
    Assert-R124 ([Math]::Abs(($playback.Value/0.25)-[Math]::Round($playback.Value/0.25)) -gt 0.01) '鼠标轨道点击把连续增益吸附到四分之一档'

    # thumb 拖动到目标点；按右键盘方向键再以 SmallChange 连续增加。
    $thumb=Get-R124SliderPart -Slider $playback -Name 'PART_Thumb'
    $thumbCenter=$thumb.PointToScreen([System.Windows.Point]::new($thumb.ActualWidth/2,$thumb.ActualHeight/2))
    $dragTarget=$track.PointToScreen([System.Windows.Point]::new($track.ActualWidth*0.671,$track.ActualHeight/2))
    if(-not [R124NativeInput]::SetCursorPos([int][Math]::Round($thumbCenter.X),[int][Math]::Round($thumbCenter.Y))){throw '无法定位增益旋钮。'}
    [R124NativeInput]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Invoke-R124UiPump
    $captureDuringDrag=if([System.Windows.Input.Mouse]::Captured){[System.Windows.Input.Mouse]::Captured.GetType().Name}else{'<none>'}
    Assert-R124 ([object]::ReferenceEquals([System.Windows.Input.Mouse]::Captured,$thumb)) ("按下旋钮后没有捕获鼠标 (captured={0}, point={1},{2}, thumb={3}x{4})" -f $captureDuringDrag,$thumbCenter.X,$thumbCenter.Y,$thumb.ActualWidth,$thumb.ActualHeight)
    [void][R124NativeInput]::SetCursorPos([int][Math]::Round($dragTarget.X),[int][Math]::Round($dragTarget.Y))
    $screenBounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    Assert-R124 ([R124NativeInput]::MoveCursorAbsolute([int][Math]::Round($dragTarget.X),[int][Math]::Round($dragTarget.Y),$screenBounds.Width,$screenBounds.Height)) '鼠标拖动位置没有送达 Windows 输入队列'
    Start-Sleep -Milliseconds 60;Invoke-R124UiPump
    [R124NativeInput]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 60;Invoke-R124UiPump
    $dragCapture=if([System.Windows.Input.Mouse]::Captured){[System.Windows.Input.Mouse]::Captured.GetType().Name}else{'<none>'}
    Assert-R124 ($playback.Value -gt 8 -and $playback.Value -lt 13) ("鼠标拖动 thumb 没有跟随连续目标位置 (after={0}, thumb={1},{2}, target={3},{4}, capture={5})" -f $playback.Value,$thumbCenter.X,$thumbCenter.Y,$dragTarget.X,$dragTarget.Y,$dragCapture)
    $beforeKey=[double]$playback.Value
    $nativeWindow=(New-Object System.Windows.Interop.WindowInteropHelper($script:mainWindow)).Handle
    [void][R124NativeInput]::SetForegroundWindow($nativeWindow);[void]$script:mainWindow.Activate();[void]$playback.Focus();Invoke-R124UiPump
    $keyboardSent=[R124NativeInput]::SendRightArrow();Start-Sleep -Milliseconds 50;Invoke-R124UiPump
    $nativeKeyboardChanged=([double]$playback.Value -gt $beforeKey)
    $keyboardMethod='SendInput'
    if(-not $nativeKeyboardChanged){
        $keyboardMethod='SendKeys'
        [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}');Start-Sleep -Milliseconds 40;Invoke-R124UiPump
    }
    $focusedName=if([System.Windows.Input.Keyboard]::FocusedElement){[System.Windows.Input.Keyboard]::FocusedElement.GetType().Name}else{'<none>'}
    Assert-R124 ($keyboardSent -and $playback.Value -gt $beforeKey -and [Math]::Abs(($playback.Value-$beforeKey)-0.05) -lt 0.002) ("键盘方向键没有按 SmallChange 调整增益 (nativeChanged={0}, before={1}, after={2}, focused={3}, active={4})" -f $nativeKeyboardChanged,$beforeKey,$playback.Value,$focusedName,$script:mainWindow.IsActive)

    $playback.IsEnabled=$false;[void]$playback.ApplyTemplate();$playback.UpdateLayout()
    $disabledRail=Get-R124SliderPart -Slider $playback -Name 'TrackRail'
    $disabledThumb=Get-R124SliderPart -Slider $playback -Name 'PART_Thumb'
    $disabledTicks=Get-R124SliderPart -Slider $playback -Name 'TickDots'
    $thumbSurface=$disabledThumb.Template.FindName('ThumbSurface',$disabledThumb)
    $disabledTrack=Get-R124SliderPart -Slider $playback -Name 'PART_Track'
    Assert-R124 (-not $disabledTrack.IsEnabled -and $disabledRail.Background.ToString() -ceq '#FF42464A' -and $disabledTicks.Opacity -eq 0.45 -and $thumbSurface.Fill.ToString() -ceq '#FFB8BEC3') '增益禁用态没有清晰显示且实际禁用'
    $playback.IsEnabled=$true

    # 生产 ValueChanged handler 在真轨道点击后生成连续 milli 增益请求；测试接收器只留内存记录。
    $commands=New-Object 'System.Collections.Generic.List[object]'
    $supervisor=[pscustomobject]@{HasExited=$false;Commands=$commands}
    Add-Member -InputObject $supervisor -MemberType ScriptMethod -Name SendControlCommand -Value {
        param([string]$RequestId,[string]$Command,[string]$ParametersJson='')
        $this.Commands.Add([pscustomobject]@{request_id=$RequestId;command=$Command;parameters_json=$ParametersJson})
        return $true
    }
    $script:supervisor=$supervisor;$script:controlRunId='ui-r124-test';$script:audioGainRunId='ui-r124-test'
    $script:controlConfirmed=$true;$script:audioGainNativeCapability=$true;$script:audioGainRuntimeReady=$true
    $script:audioGainRevision=[uint64]5
    $script:audioGainActual=[pscustomobject]@{revision=[uint64]5;radio_playback_gain_milli=[uint32]1000;mic_transmit_gain_milli=[uint32]16000}
    $script:audioGainPendingRequest=$null;$script:audioGainAwaitingStatus=$false;$script:audioGainDraftRevision=[uint64]0
    $script:audioGainDebounceReady=$false;$script:pendingControlRequests=@{}
    $transmit.Value=16;[void]$playback.Focus();$playback.Value=1
    # production main-window initialization wires these same event handlers to both gain sliders
    $playback.Add_ValueChanged({ On-UiAudioGainValueChanged })
    $transmit.Add_ValueChanged({ On-UiAudioGainValueChanged })
    $playback.Value=0.25;Invoke-R124UiPump
    $runtimeTrack=Get-R124SliderPart -Slider $playback -Name 'PART_Track'
    $runtimePoint=$runtimeTrack.PointToScreen([System.Windows.Point]::new($runtimeTrack.ActualWidth*0.527,$runtimeTrack.ActualHeight/2))
    Invoke-R124ScreenClick -Point $runtimePoint
    for($wait=0;$wait -lt 9 -and $commands.Count -eq 0;$wait++){Start-Sleep -Milliseconds 50;Invoke-R124UiPump}
    Assert-R124 ($script:audioGainDraftRevision -gt 0 -and $script:audioGainDraft -and [uint32]$script:audioGainDraft.radio_playback_gain_milli -gt 1000) '真实轨道操作没有进入运行增益草稿回调'
    Assert-R124 ($commands.Count -eq 1 -and $commands[0].command -ceq 'audio.gains.set') '真实增益滑动没有走生产运行时命令处理器'
    $gainParameters=ConvertFrom-Json -InputObject $commands[0].parameters_json
    Assert-R124 ([uint32]$gainParameters.radio_playback_gain_milli -eq [uint32]$script:audioGainDraft.radio_playback_gain_milli -and
        [Math]::Abs(([double]$gainParameters.radio_playback_gain_milli/1000/0.25)-[Math]::Round([double]$gainParameters.radio_playback_gain_milli/1000/0.25)) -gt 0.01) '运行增益命令没有保留未量化的滑块值'
    if($script:audioGainDebounceTimer){$script:audioGainDebounceTimer.Stop()}

    Write-Output ("PASS: test-ui-r124.ps1 ({0} assertions; real WPF popup, mouse, keyboard={1}, channel preset, and in-memory gain handler; no device/BM request)" -f $script:assertionCount,$keyboardMethod)
}
finally {
    if($script:audioGainDebounceTimer){$script:audioGainDebounceTimer.Stop()}
    if($script:mainWindow -and $script:mainWindow.IsVisible){$script:mainWindow.Close()}
}
