[CmdletBinding()]
param(
    [string]$UserConfigDirectory
)

$ErrorActionPreference = 'Stop'
try {
    $parentDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    if ([System.IO.File]::Exists((Join-Path $parentDirectory 'tools\start-ui.ps1'))) {
        $repositoryRoot = $parentDirectory
        $startUiScript = Join-Path $repositoryRoot 'tools\start-ui.ps1'
    } else {
        $repositoryRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
        $startUiScript = Join-Path $repositoryRoot 'start-ui.ps1'
    }
    if (-not [System.IO.File]::Exists($startUiScript)) { throw '本目录没有 start-ui.ps1。' }

    if ([string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
        $resolvedUserConfigDirectory = Join-Path $repositoryRoot 'private\r106-step1-test-config'
    } elseif ([System.IO.Path]::IsPathRooted($UserConfigDirectory)) {
        $resolvedUserConfigDirectory = [System.IO.Path]::GetFullPath($UserConfigDirectory)
    } else {
        $resolvedUserConfigDirectory = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $UserConfigDirectory))
    }
    if ([System.IO.File]::Exists($resolvedUserConfigDirectory)) { throw '测试配置目录路径已被同名文件占用。' }
    if (-not [System.IO.Directory]::Exists($resolvedUserConfigDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($resolvedUserConfigDirectory)
    }

    & $startUiScript -UserConfigDirectory $resolvedUserConfigDirectory
} catch {
    [Console]::Error.WriteLine(('R106 第1步测试入口启动失败：' + $_.Exception.Message))
    exit 2
}
