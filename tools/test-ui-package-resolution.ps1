[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-UiPackageResolution {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path (Join-Path $repoRoot 'ui\windows') 'bridge-ui.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
Assert-UiPackageResolution ($parseErrors.Count -eq 0) 'bridge-ui.ps1 PowerShell 5.1 语法解析失败。'
$functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Resolve-UiRuntimeDirectory' }, $true)
Assert-UiPackageResolution ($null -ne $functionAst) '没有找到 UI 版本目录选择函数。'
Invoke-Expression $functionAst.Extent.Text

$productionText = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)
Assert-UiPackageResolution ($productionText.Contains('$PSBoundParameters.ContainsKey(''PackageDirectory'')')) 'UI 没有记录调用方是否显式指定 PackageDirectory。'
Assert-UiPackageResolution ($productionText.Contains('Resolve-UiRuntimeDirectory -PackageRoot $script:packageRoot')) 'UI 没有通过版本目录选择函数确定核心路径。'

$testRoot = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $repoRoot 'build\_work'))) ('ui-package-resolution-' + [guid]::NewGuid().ToString('N'))
$configDirectory = Join-Path $testRoot 'user-config'
[System.IO.Directory]::CreateDirectory($configDirectory) | Out-Null
$script:mockReleaseDirectory = Join-Path $testRoot 'selected-release'
$script:mockReleaseCalls = 0
function Get-BridgeReleaseDirectory {
    param([string]$UserConfigDirectory)
    $script:mockReleaseCalls++
    return $script:mockReleaseDirectory
}

try {
    $pointerPath = Join-Path $configDirectory 'bridge-directory.txt'
    [System.IO.File]::WriteAllText($pointerPath, 'stale-release', (New-Object System.Text.UTF8Encoding($true)))

    $explicitPackage = Join-Path $testRoot 'explicit-package'
    $resolved = Resolve-UiRuntimeDirectory -PackageRoot $explicitPackage -UserConfigDirectory $configDirectory -PackageDirectoryWasExplicit $true
    Assert-UiPackageResolution ([string]::Equals($resolved, [System.IO.Path]::GetFullPath($explicitPackage), [StringComparison]::OrdinalIgnoreCase)) '显式 PackageDirectory 没有作为本次 native 核心目录。'
    Assert-UiPackageResolution ($script:mockReleaseCalls -eq 0) '显式 PackageDirectory 仍读取了共享版本指针。'

    $defaultPackage = Join-Path $testRoot 'default-package'
    $resolved = Resolve-UiRuntimeDirectory -PackageRoot $defaultPackage -UserConfigDirectory $configDirectory -PackageDirectoryWasExplicit $false
    Assert-UiPackageResolution ([string]::Equals($resolved, [System.IO.Path]::GetFullPath($script:mockReleaseDirectory), [StringComparison]::OrdinalIgnoreCase)) '未显式指定版本时没有使用本机版本指针。'
    Assert-UiPackageResolution ($script:mockReleaseCalls -eq 1) '未显式指定版本时没有且仅一次读取版本指针。'

    Remove-Item -LiteralPath $pointerPath
    $resolved = Resolve-UiRuntimeDirectory -PackageRoot $defaultPackage -UserConfigDirectory $configDirectory -PackageDirectoryWasExplicit $false
    Assert-UiPackageResolution ([string]::Equals($resolved, [System.IO.Path]::GetFullPath($defaultPackage), [StringComparison]::OrdinalIgnoreCase)) '没有版本指针时未回退到推导出的便携目录。'
    Assert-UiPackageResolution ($script:mockReleaseCalls -eq 1) '没有版本指针时仍尝试读取了它。'

    Write-Output '通过：显式选择的便携目录优先；未显式选择时读取版本指针；缺少指针时使用推导目录。'
} finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        try { [System.IO.Directory]::Delete($testRoot, $true) }
        catch { throw ('测试暂存目录清理失败，残留路径：' + $testRoot) }
    }
}
