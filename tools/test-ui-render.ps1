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

function Assert-UiRenderLayout {
    param([Parameter(Mandatory=$true)][string]$LayoutPath,[Parameter(Mandatory=$true)][string]$RenderDirectory,[Parameter(Mandatory=$true)][string]$Label)
    if (-not [System.IO.File]::Exists($LayoutPath)) { throw "$Label 未生成 layout-info.json。" }
    $layout = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($LayoutPath,[System.Text.Encoding]::UTF8)) -ErrorAction Stop
    $main = $layout.main
    $top = Get-UiRenderRect -Layout $layout -Name 'ConsoleTop'
    $dashboard = Get-UiRenderRect -Layout $layout -Name 'DashboardPanel'
    $left = Get-UiRenderRect -Layout $layout -Name 'ConnectionConfigPanel'
    $right = Get-UiRenderRect -Layout $layout -Name 'DailyControlsPanel'
    $connect = Get-UiRenderRect -Layout $layout -Name 'ConnectButton'
    $save = Get-UiRenderRect -Layout $layout -Name 'SaveSettingsButton'
    Assert-UiRender ($main.controls_bounds.ConsoleTop.fully_visible -and $main.controls_bounds.DashboardPanel.fully_visible) "$Label 上下区域没有完整显示。"
    Assert-UiRender ($main.controls_bounds.ConnectionConfigPanel.fully_visible -and $main.controls_bounds.DailyControlsPanel.fully_visible) "$Label 左右区域没有完整显示。"
    Assert-UiRender ($main.controls_bounds.ConnectButton.fully_visible -and $main.controls_bounds.SaveSettingsButton.fully_visible) "$Label 连接与保存按钮被裁切。"
    Assert-UiRender ($top.bottom -le ($dashboard.y + 1)) "$Label 上下区域发生覆盖。"
    Assert-UiRender ($left.right -le ($right.x + 1)) "$Label 左右区域发生覆盖。"
    $leftRatio = $left.width / $dashboard.width
    Assert-UiRender ($leftRatio -ge 0.35 -and $leftRatio -le 0.45) "$Label 连接区比例不是约 40%。"
    Assert-UiRender ($right.width -gt $left.width) "$Label 日常控制区没有占据约 60% 宽度。"
    Assert-UiRender ($connect.bottom -le $main.height -and $save.bottom -le $main.height) "$Label 固定底栏超出窗口边界。"
    Assert-UiRender (-not [bool]$main.controls_visible.AudioStatusCard) "$Label 无音频数据时仍显示空音频卡片。"
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
    $normal = Join-Path $RenderDirectory 'main-normal.png'
    $popup = Join-Path $RenderDirectory 'main-combo-open.png'
    Assert-UiRender ([System.IO.File]::Exists($normal) -and (New-Object System.IO.FileInfo($normal)).Length -gt 50000) "$Label 没有生成完整主窗口截图。"
    Assert-UiRender ([System.IO.File]::Exists($popup) -and (New-Object System.IO.FileInfo($popup)).Length -gt 1000) "$Label 没有生成展开的 BM 服务器下拉截图。"
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiPath = Join-Path $repoRoot 'ui\windows\bridge-ui.ps1'
$xamlPath = Join-Path $repoRoot 'ui\windows\MainWindow.xaml'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw '请使用 -STA 运行 WPF RenderOnly 回归。'
}
foreach ($path in @($PSCommandPath,$uiPath,$xamlPath)) {
    if (-not [System.IO.File]::Exists($path)) { throw "缺少渲染目标：$path" }
    Assert-UiRenderBom -Path $path
}
foreach ($path in @($uiPath)) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "bridge-ui.ps1 parse failed: $($parseErrors[0].Message)" }
}
[xml]$null = [System.IO.File]::ReadAllText($xamlPath,[System.Text.Encoding]::UTF8)

$taskRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('wirex-r117-render-' + [guid]::NewGuid().ToString('N'))))
$package = Join-Path $taskRoot 'package'
$config = Join-Path $taskRoot 'config'
[void][System.IO.Directory]::CreateDirectory($package)
[void][System.IO.Directory]::CreateDirectory($config)
# RenderOnly checks these package markers, but never starts either file.
[System.IO.File]::WriteAllText((Join-Path $package 'start-bm-radio-bridge.ps1'),'')
[System.IO.File]::WriteAllText((Join-Path $package 'wirex_bridge.exe'),'')

foreach ($case in @(
    [pscustomobject]@{ Label='1360x850'; Size='1360x850'; Directory=(Join-Path $taskRoot 'normal') },
    [pscustomobject]@{ Label='1024x700'; Size='1024x700'; Directory=(Join-Path $taskRoot 'small') }
)) {
    [void][System.IO.Directory]::CreateDirectory($case.Directory)
    $childOutput = @(& powershell.exe -NoLogo -NoProfile -STA -File $uiPath -RenderOnly -NoAutoConnect `
        -UserConfigDirectory $config -PackageDirectory $package -RenderOutputDirectory $case.Directory -RenderWorkArea $case.Size 2>&1)
    $childExitCode = $LASTEXITCODE
    if ($childExitCode -ne 0) { throw ("$($case.Label) RenderOnly exited ${childExitCode}: " + ($childOutput -join "`n")) }
    Assert-UiRenderLayout -LayoutPath (Join-Path $case.Directory 'layout-info.json') -RenderDirectory $case.Directory -Label $case.Label
}

Write-Output ("PASS: test-ui-render.ps1 ({0} RenderOnly layout/contrast assertions; output={1})" -f $script:assertionCount,$taskRoot)
