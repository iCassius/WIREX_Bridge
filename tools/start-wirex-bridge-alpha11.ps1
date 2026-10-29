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

function Resolve-PackageUserConfigDirectory {
    param([string]$PackageRoot, [string]$ExplicitDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitDirectory)) {
        return [System.IO.Path]::GetFullPath($ExplicitDirectory)
    }

    $pointerPath = Join-Path $PackageRoot 'private\user-config-directory.txt'
    if ([System.IO.File]::Exists($pointerPath)) {
        $lines = [System.IO.File]::ReadAllLines($pointerPath, [System.Text.Encoding]::UTF8)
        if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
            throw 'private\user-config-directory.txt 必须只包含一行完整目录路径。'
        }
        $value = $lines[0].Trim()
        if (-not [System.IO.Path]::IsPathRooted($value)) {
            throw 'private\user-config-directory.txt 必须使用绝对目录路径。'
        }
        $resolved = [System.IO.Path]::GetFullPath($value)
        if (-not [System.IO.Directory]::Exists($resolved)) {
            throw 'user-config-directory.txt 指向的本机配置目录不存在。'
        }
        return $resolved
    }

    return (Join-Path $PackageRoot 'private\user-config')
}

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
            $resolvedUserConfig = Resolve-PackageUserConfigDirectory -PackageRoot $packageRoot `
                -ExplicitDirectory $UserConfigDirectory
            . $uiLauncher -PackageDirectory $packageRoot -UserConfigDirectory $resolvedUserConfig
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
    [Console]::Error.WriteLine(('WIREX Bridge alpha.11 启动失败：' + $_.Exception.Message))
    exit 2
}
