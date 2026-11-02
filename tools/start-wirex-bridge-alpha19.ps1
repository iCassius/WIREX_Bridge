[CmdletBinding()]
param(
    [ValidateSet('Start', 'PrepareOnly', 'RoutingDiagnosticAutoTest')]
    [string]$Mode = 'Start',
    [string]$PackageDirectory,
    [string]$UserConfigDirectory,
    [string]$ConnectionProfilePath,
    [string]$AudioSettingsPath,
    [string]$PasswordFile,
    [string]$BodyFile,
    [string]$StatusDirectory,
    [string]$PreparationOutputPath
)

$ErrorActionPreference = 'Stop'

try {
    $entryDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
    $packageRoot = if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
        [System.IO.Path]::GetFullPath((Split-Path -Parent $entryDirectory))
    } else {
        [System.IO.Path]::GetFullPath($PackageDirectory)
    }

    $uiLauncher = Join-Path $packageRoot 'start-ui.ps1'
    $bridgeLauncher = Join-Path $packageRoot 'start-bm-radio-bridge.ps1'
    $uiScript = Join-Path $packageRoot 'ui\windows\bridge-ui.ps1'
    $nativeExecutable = Join-Path $packageRoot 'wirex_bridge.exe'
    if (-not [System.IO.File]::Exists($uiLauncher) -or
        -not [System.IO.File]::Exists($bridgeLauncher) -or
        -not [System.IO.File]::Exists($uiScript) -or
        -not [System.IO.File]::Exists($nativeExecutable)) {
        throw '所选目录缺少 WIREX Bridge 运行文件。'
    }

    switch ($Mode) {
        'Start' {
            if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
                throw '正式 Start 从 packageRoot/config.json 读取设置；UserConfigDirectory 仅供隔离诊断测试使用。'
            }
            . $uiLauncher -PackageDirectory $packageRoot
        }
        'PrepareOnly' {
            foreach ($required in @($ConnectionProfilePath, $AudioSettingsPath, $PasswordFile,
                $StatusDirectory, $PreparationOutputPath)) {
                if ([string]::IsNullOrWhiteSpace($required)) {
                    throw 'PrepareOnly 模式需要连接配置、音量设置、密码文件路径、状态目录和预检输出路径。'
                }
            }
            $resolvedBodyFile = if ([string]::IsNullOrWhiteSpace($BodyFile)) {
                Join-Path $packageRoot 'private\device-y.bin'
            } else {
                [System.IO.Path]::GetFullPath($BodyFile)
            }
            & $bridgeLauncher -BridgePath $nativeExecutable -BodyFile $resolvedBodyFile -Preset manual `
                -ConnectionProfilePath ([System.IO.Path]::GetFullPath($ConnectionProfilePath)) `
                -AudioSettingsPath ([System.IO.Path]::GetFullPath($AudioSettingsPath)) `
                -PasswordFile ([System.IO.Path]::GetFullPath($PasswordFile)) `
                -StatusDirectory ([System.IO.Path]::GetFullPath($StatusDirectory)) `
                -PreparationOutputPath ([System.IO.Path]::GetFullPath($PreparationOutputPath)) `
                -PrepareOnly -NoInteractive -RequirePasswordFile
        }
        'RoutingDiagnosticAutoTest' {
            if ([string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
                throw '隔离路由诊断必须指定独立的 UserConfigDirectory。'
            }
            . $uiLauncher -PackageDirectory $packageRoot `
                -UserConfigDirectory ([System.IO.Path]::GetFullPath($UserConfigDirectory)) `
                -RoutingDiagnostic -RoutingDiagnosticAutoTest
        }
    }

    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    exit 0
} catch {
    [Console]::Error.WriteLine(('WIREX Bridge alpha.19 启动失败：' + $_.Exception.Message))
    exit 2
}
