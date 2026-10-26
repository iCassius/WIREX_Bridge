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
    if ($MaximumHeight -le 700) {
        Assert-UiRender ($layout.main.event_list_height -ge 50 -and $layout.main.event_list_height -le 60) '小工作区没有压缩运行记录区域，来话状态可能被裁切。'
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

    $smallRenderDirectory = Join-Path $renderDirectory 'work-area-1024x728'
    [System.IO.Directory]::CreateDirectory($smallRenderDirectory) | Out-Null
    & $powerShellExe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $uiLauncher `
        -PackageDirectory $stagedPackage -UserConfigDirectory $configDirectory -OfflinePreview -RenderOnly `
        -RenderWorkArea '1024x728' -RenderOutputDirectory $smallRenderDirectory
    $smallExitCode = [int]$LASTEXITCODE
    Assert-UiRender ($smallExitCode -eq 0) ("小工作区 WPF 渲染退出码为 $smallExitCode。")
    Test-RenderedLayout -Directory $smallRenderDirectory -MaximumWidth 972 -MaximumHeight 692

    $invalidPackage = Join-Path $testRoot 'invalid-package'
    [System.IO.Directory]::CreateDirectory($invalidPackage) | Out-Null
    & $powerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $uiLauncher -PackageDirectory $invalidPackage -OfflinePreview
    $errorExitCode = [int]$LASTEXITCODE
    Assert-UiRender ($errorExitCode -eq 2) ("损坏包目录应从启动器返回退出码 2，实际为 $errorExitCode。")

    Write-Output ("通过：Windows PowerShell 5.1 的包根启动链渲染了主界面和设置窗口；1024x728 工作区内操作按钮均可见；错误包返回退出码 2；没有启动 native 核心或访问设备。结果：{0}" -f $renderDirectory)
} finally {
    if ([System.IO.Directory]::Exists($testRoot)) { [System.IO.Directory]::Delete($testRoot, $true) }
}
