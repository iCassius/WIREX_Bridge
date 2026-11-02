[CmdletBinding()]
param(
    [string]$PackageDirectory,
    [string]$PortableDirectory,
    [string]$UserConfigDirectory,
    [switch]$OfflinePreview,
    [switch]$NoAutoConnect,
    [switch]$ValidateConfigOnly,
    [switch]$RenderOnly,
    [string]$RenderOutputDirectory,
    [string]$RenderWorkArea,
    [switch]$RoutingDiagnostic,
    [switch]$RoutingDiagnosticAutoTest
)

$ErrorActionPreference = 'Stop'
function Test-StartUiPathWithin {
    param([string]$Path, [string]$Directory)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($fullPath, $fullDirectory, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $fullPath.StartsWith(($fullDirectory + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)
}
if ($RoutingDiagnosticAutoTest -and -not $RoutingDiagnostic) {
    throw '-RoutingDiagnosticAutoTest 必须与 -RoutingDiagnostic 一起使用。'
}
if ($RoutingDiagnostic -and $ValidateConfigOnly) { throw '路由诊断不能与 -ValidateConfigOnly 同时使用。' }
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
    if ($RoutingDiagnostic) {
        if ([string]::IsNullOrWhiteSpace($UserConfigDirectory)) {
            throw '-RoutingDiagnostic 需要现有独立的 -UserConfigDirectory。'
        }
        if (-not [System.IO.Path]::IsPathRooted($UserConfigDirectory)) {
            throw '路由诊断 UserConfigDirectory 必须是绝对隔离目录。'
        }
        $portableRoot = if ([string]::IsNullOrWhiteSpace($PortableDirectory)) {
            $candidateRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $packageRoot))
            if ([System.IO.File]::Exists((Join-Path $candidateRoot 'WirexBridge.exe'))) { $candidateRoot } else { $packageRoot }
        } else { [System.IO.Path]::GetFullPath($PortableDirectory) }
        $isolatedRoot = [System.IO.Path]::GetFullPath($UserConfigDirectory)
        if (Test-StartUiPathWithin -Path $isolatedRoot -Directory $portableRoot) {
            throw '路由诊断隔离目录不能与便携配置目录或其子目录重合。'
        }
        $arguments.PortableDirectory = $portableRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($PortableDirectory)) {
        $portableRoot = [System.IO.Path]::GetFullPath($PortableDirectory)
        $portableConfigModule = Join-Path $packageRoot 'ui\windows\PortableConfig.psm1'
        if (-not [System.IO.File]::Exists($portableConfigModule)) { throw '所选运行目录缺少 PortableConfig.psm1。' }
        Import-Module $portableConfigModule -Force -ErrorAction Stop
        [void](Initialize-PortableConfig -PortableDirectory $portableRoot)
        $arguments.PortableDirectory = $portableRoot
        if ($ValidateConfigOnly) {
            Write-Output 'WIREX Bridge config.json 校验通过；没有启动 UI、Native 或设备连接。'
            exit 0
        }
    } elseif ($ValidateConfigOnly) {
        throw '-ValidateConfigOnly 需要 -PortableDirectory。'
    }
    if (-not [string]::IsNullOrWhiteSpace($UserConfigDirectory)) { $arguments.UserConfigDirectory = $UserConfigDirectory }
    if ($OfflinePreview) { $arguments.OfflinePreview = $true }
    if ($NoAutoConnect) { $arguments.NoAutoConnect = $true }
    if ($RenderOnly) { $arguments.RenderOnly = $true }
    if (-not [string]::IsNullOrWhiteSpace($RenderOutputDirectory)) { $arguments.RenderOutputDirectory = $RenderOutputDirectory }
    if (-not [string]::IsNullOrWhiteSpace($RenderWorkArea)) { $arguments.RenderWorkArea = $RenderWorkArea }
    if ($RoutingDiagnostic) { $arguments.RoutingDiagnostic = $true }
    if ($RoutingDiagnosticAutoTest) { $arguments.RoutingDiagnosticAutoTest = $true }
    . $uiScript @arguments
} catch {
    [Console]::Error.WriteLine(('WIREX Bridge UI 启动失败：' + $_.Exception.Message))
    exit 2
}
