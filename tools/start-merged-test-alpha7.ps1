[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try {
    $entryPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    $entryDirectory = [System.IO.Path]::GetDirectoryName($entryPath)
    $packageRoot = if ([System.IO.File]::Exists((Join-Path $entryDirectory 'ui\windows\bridge-ui.ps1'))) {
        $entryDirectory
    } else {
        [System.IO.Path]::GetFullPath((Split-Path -Parent $entryDirectory))
    }
    $uiLauncher = Join-Path $packageRoot 'start-ui.ps1'
    if (-not [System.IO.File]::Exists($uiLauncher)) {
        $uiLauncher = Join-Path $packageRoot 'tools\start-ui.ps1'
    }
    if (-not [System.IO.File]::Exists($uiLauncher)) { throw '所选目录缺少 start-ui.ps1。' }
    if (-not [System.IO.File]::Exists((Join-Path $packageRoot 'ui\windows\bridge-ui.ps1'))) {
        throw '所选目录缺少 UI 文件；请从完整 alpha7 便携目录启动。'
    }

    $userConfigDirectory = Join-Path $packageRoot 'private\r109-merged-test-config'
    $uiArguments = @{
        PackageDirectory = $packageRoot
        UserConfigDirectory = $userConfigDirectory
    }
    & $uiLauncher @uiArguments
    exit 0
} catch {
    [Console]::Error.WriteLine(('WIREX Bridge alpha7 测试入口启动失败：' + $_.Exception.Message))
    exit 2
}
