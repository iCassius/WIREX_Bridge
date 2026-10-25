[CmdletBinding()]
param(
    [string]$PackageDirectory,
    [string]$UserConfigDirectory,
    [switch]$OfflinePreview,
    [switch]$NoAutoConnect,
    [switch]$RenderOnly,
    [string]$RenderOutputDirectory,
    [string]$RenderWorkArea
)

$ErrorActionPreference = 'Stop'
try {
    $packageRoot = if ([System.IO.File]::Exists((Join-Path $PSScriptRoot 'ui\windows\bridge-ui.ps1'))) {
        [System.IO.Path]::GetFullPath($PSScriptRoot)
    } else {
        [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageDirectory)) {
        $packageRoot = [System.IO.Path]::GetFullPath($PackageDirectory)
    }
    $uiScript = Join-Path $packageRoot 'ui\windows\bridge-ui.ps1'
    if (-not [System.IO.File]::Exists($uiScript)) { throw '所选目录缺少 ui\windows\bridge-ui.ps1。' }

    $arguments = @{ PackageDirectory = $packageRoot }
    if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) { $arguments.UserConfigDirectory = $UserConfigDirectory }
    if ($OfflinePreview) { $arguments.OfflinePreview = $true }
    if ($NoAutoConnect) { $arguments.NoAutoConnect = $true }
    if ($RenderOnly) { $arguments.RenderOnly = $true }
    if (-not [string]::IsNullOrWhiteSpace($RenderOutputDirectory)) { $arguments.RenderOutputDirectory = $RenderOutputDirectory }
    if (-not [string]::IsNullOrWhiteSpace($RenderWorkArea)) { $arguments.RenderWorkArea = $RenderWorkArea }
    & $uiScript @arguments
} catch {
    [Console]::Error.WriteLine(('WIREX Bridge UI 启动失败：' + $_.Exception.Message))
    exit 2
}
