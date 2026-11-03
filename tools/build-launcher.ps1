[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build\_work'))
$sourcePath = Join-Path $appRoot 'ui\launcher\WirexBridgeLauncher.cs'
$iconRelativePath = 'assets/wiresx-official.ico'
$iconPath = Join-Path $appRoot $iconRelativePath
$fullOutput = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $appRoot $OutputDirectory))
}
$workPrefix = $workRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $fullOutput.StartsWith($workPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Launcher 输出目录必须位于 app/build/_work 内。'
}
if (-not [System.IO.File]::Exists($sourcePath)) { throw '找不到 launcher C# 源码。' }
if (-not [System.IO.File]::Exists($iconPath)) { throw '找不到内嵌 launcher / WPF 使用的官方图标素材。' }
if (-not [System.IO.Directory]::Exists($workRoot)) { throw 'app/build/_work 目录不存在。' }
if ([System.IO.Directory]::Exists($fullOutput) -or [System.IO.File]::Exists($fullOutput)) {
    throw 'Launcher 输出目录已存在；为避免覆盖，请选择新的 build/_work 子目录。'
}

$frameworkRoot = if ([Environment]::Is64BitOperatingSystem) {
    Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
} else {
    Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
}
$compiler = Join-Path $frameworkRoot 'csc.exe'
if (-not [System.IO.File]::Exists($compiler)) { throw '本机 .NET Framework csc.exe 不可用；未下载或安装额外组件。' }

[System.IO.Directory]::CreateDirectory($fullOutput) | Out-Null
$executablePath = Join-Path $fullOutput 'WirexBridge.exe'
$provenancePath = Join-Path $fullOutput 'launcher-build-provenance.json'
$logPath = Join-Path $fullOutput 'launcher-build.log'
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
$iconHash = (Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash.ToLowerInvariant()
$arguments = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/debug-', '/codepage:65001',
    ('/win32icon:"' + $iconPath + '"'),
    ('/resource:"' + $iconPath + '",WIREX.ico'),
    ('/out:"' + $executablePath + '"'),
    ('"' + $sourcePath + '"')
) -join ' '
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $compiler
$startInfo.Arguments = $arguments
$startInfo.WorkingDirectory = $appRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
if (-not $process.Start()) { throw '无法启动本机 C# 编译器。' }
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$compilerOutput = $stdoutTask.Result + $stderrTask.Result
[System.IO.File]::WriteAllText($logPath, $compilerOutput, (New-Object System.Text.UTF8Encoding($true)))
if ($process.ExitCode -ne 0 -or -not [System.IO.File]::Exists($executablePath)) {
    throw ('Launcher 编译失败，检查 build/_work 下的 launcher-build.log；退出码为 ' + $process.ExitCode + '.')
}

$relativeOutput = $fullOutput.Substring($appRoot.TrimEnd('\').Length + 1).Replace('\', '/')
$executable = Get-Item -LiteralPath $executablePath -ErrorAction Stop
$compilerVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($compiler).FileVersion
$provenance = [ordered]@{
    schema_version = 1
    result = 'passed'
    source = [ordered]@{
        path = 'ui/launcher/WirexBridgeLauncher.cs'
        commit = $SourceCommit
        sha256 = $sourceHash
    }
    compiler = [ordered]@{
        family = 'Microsoft .NET Framework csc.exe'
        version = [string]$compilerVersion
        target = 'x64 Windows GUI executable'
        command = 'csc.exe /nologo /target:winexe /platform:x64 /optimize+ /debug- /codepage:65001 /win32icon:assets/wiresx-official.ico /resource:assets/wiresx-official.ico,WIREX.ico'
    }
    resources = [ordered]@{
        icon_path = $iconRelativePath
        icon_sha256 = $iconHash
        assembly_resource_name = 'WIREX.ico'
        windows_executable_icon = $true
    }
    output = [ordered]@{
        directory = $relativeOutput
        path = 'WirexBridge.exe'
        length_bytes = [long]$executable.Length
        sha256 = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    build_log = [ordered]@{
        path = ($relativeOutput + '/launcher-build.log')
        sha256 = (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$provenanceJson = ConvertTo-Json -InputObject $provenance -Depth 8
[System.IO.File]::WriteAllText($provenancePath, $provenanceJson + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('Launcher 编译通过：' + $relativeOutput + '/WirexBridge.exe')
Write-Output ('源码 SHA-256：' + $sourceHash)
