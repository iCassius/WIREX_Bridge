[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [string]$RenderOutputDirectory
)

$ErrorActionPreference = 'Stop'
function Assert-UiRender {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
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
            Assert-UiRender ([bool]$property.Value) ("$windowName 窗口中的 $($property.Name) 未显示。")
        }
    }
    foreach ($controlName in @('TargetSelector', 'ReceiveTargetValue', 'TransmitTargetValue', 'TransmitPermissionValue')) {
        Assert-UiRender ([bool]$layout.main.controls_visible.$controlName) ("主窗口收发目标控件 $controlName 未显示。")
        Assert-UiRender ([bool]$layout.main.controls_bounds.$controlName.fully_visible) ("主窗口收发目标控件 $controlName 被裁切。")
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
    foreach ($controlName in @('MasterPresetBox', 'DestinationBox', 'ReceiveDestinationBox', 'ReceiveSlotBox', 'ReceiveCallKindBox', 'TransmitEnabledBox', 'PlaybackGainSlider', 'TransmitGainSlider')) {
        Assert-UiRender ([bool]$layout.settings.controls_visible.$controlName) ("设置窗口控件 $controlName 未显示。")
    }
    $trafficCard = $layout.main.controls_bounds.TrafficCard.actual
    foreach ($controlName in @('CurrentCallLabel', 'CurrentCallValue', 'CurrentCallDetail')) {
        $callBounds = $layout.main.controls_bounds.$controlName
        Assert-UiRender ([bool]$callBounds.fully_visible) ("当前 BM 来话控件 $controlName 被裁切。")
        Assert-UiRender ($callBounds.actual.x -ge $trafficCard.x -and $callBounds.actual.y -ge $trafficCard.y -and
            $callBounds.actual.right -le $trafficCard.right -and $callBounds.actual.bottom -le $trafficCard.bottom) `
            ("当前 BM 来话控件 $controlName 超出收发状态卡片范围。")
    }
    if ($MaximumHeight -le 700) {
        Assert-UiRender ($layout.main.event_list_height -ge 44 -and $layout.main.event_list_height -le 52) '小工作区运行记录区域高度不符合紧凑布局。'
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
    Assert-UiRender ($layout.configured_profile.receive.destination_id -eq 91 -and
        $layout.configured_profile.receive.call_kind -ceq 'group' -and $layout.configured_profile.receive.slot -eq 2 -and
        $layout.configured_profile.connection.destination_id -eq 460997 -and
        $layout.configured_profile.connection.call_kind -ceq 'private' -and -not [bool]$layout.configured_profile.transmit_enabled) `
        '配置与来话模拟场景没有保留 TG91 接收和禁发规则。'
    Assert-UiRender ($layout.active_call.value -ceq '离线模拟 · DMR ID 3149876' -and
        $layout.active_call.detail -ceq '离线模拟：组呼 · 目标 91 · TS2 · CC 1 · LC 已验证 · 接收中') `
        '配置与来话模拟场景没有显示完整来话值和详情。'
    Assert-UiRender (@($layout.active_call.visual_text) -ccontains $layout.active_call.value -and
        @($layout.active_call.visual_text) -ccontains $layout.active_call.detail) '模拟来话文字没有进入 WPF 视觉树。'
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
foreach ($name in @('bridge-ui.ps1', 'BridgeSupervisor.cs', 'MainWindow.xaml', 'SettingsWindow.xaml')) {
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
        -OfflinePreview -RenderOnly -RenderOutputDirectory $renderDirectory
    $exitCode = [int]$LASTEXITCODE
    Assert-UiRender ($exitCode -eq 0) ("WPF 离线渲染进程退出码为 $exitCode。")

    foreach ($name in @('main-window.png', 'settings-window.png')) {
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
    }
    Test-RenderedLayout -Directory $renderDirectory
    Test-ConfiguredActiveCallLayout -Directory (Join-Path $renderDirectory 'configured-active-call')

    $smallRenderDirectory = Join-Path $renderDirectory 'work-area-1024x728'
    [System.IO.Directory]::CreateDirectory($smallRenderDirectory) | Out-Null
    & $powerShellExe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $uiLauncher `
        -PackageDirectory $stagedPackage -UserConfigDirectory $configDirectory -OfflinePreview -RenderOnly `
        -RenderWorkArea '1024x728' -RenderOutputDirectory $smallRenderDirectory
    $smallExitCode = [int]$LASTEXITCODE
    Assert-UiRender ($smallExitCode -eq 0) ("小工作区 WPF 渲染退出码为 $smallExitCode。")
    Test-RenderedLayout -Directory $smallRenderDirectory -MaximumWidth 972 -MaximumHeight 692
    Test-ConfiguredActiveCallLayout -Directory (Join-Path $smallRenderDirectory 'configured-active-call') -MaximumWidth 972 -MaximumHeight 692

    $invalidPackage = Join-Path $testRoot 'invalid-package'
    [System.IO.Directory]::CreateDirectory($invalidPackage) | Out-Null
    & $powerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $uiLauncher -PackageDirectory $invalidPackage -OfflinePreview
    $errorExitCode = [int]$LASTEXITCODE
    Assert-UiRender ($errorExitCode -eq 2) ("损坏包目录应从启动器返回退出码 2，实际为 $errorExitCode。")

    Write-Output ("通过：Windows PowerShell 5.1 的包根启动链渲染了主界面和设置窗口；1024x728 工作区中的收发目标、当前来话值及详情均在卡片内可见；配置与来话模拟布局检查通过；错误包返回退出码 2；没有启动 native 核心或访问设备。结果：{0}" -f $renderDirectory)
} finally {
    if ([System.IO.Directory]::Exists($testRoot)) { [System.IO.Directory]::Delete($testRoot, $true) }
}
