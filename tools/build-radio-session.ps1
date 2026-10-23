[CmdletBinding()]
param(
    [switch]$CompileOnly
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gitRootLines = @(& git -C $repositoryRoot rev-parse --show-toplevel 2>$null)
$gitRootExitCode = $LASTEXITCODE
if ($gitRootExitCode -ne 0 -or $gitRootLines.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$gitRootLines[0])) {
    throw '无法定位当前 WIREX Bridge Git 根目录。'
}
$gitRoot = [System.IO.Path]::GetFullPath(([string]$gitRootLines[0]).Trim())
if (-not $gitRoot.Equals($repositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "脚本必须从 WIREX Bridge 仓库内运行：$repositoryRoot"
}

$commitLines = @(& git -C $gitRoot rev-parse HEAD 2>$null)
$commitExitCode = $LASTEXITCODE
$commit = if ($commitLines.Count -gt 0) { ([string]$commitLines[0]).Trim() } else { '' }
if ($commitExitCode -ne 0 -or $commit -notmatch '^[0-9a-fA-F]{40}$') {
    throw '无法读取当前完整 Git 提交号。'
}
$shortCommit = $commit.Substring(0, 7).ToLowerInvariant()
$statusLines = @(& git -C $gitRoot status --porcelain --untracked-files=normal)
$statusExitCode = $LASTEXITCODE
if ($statusExitCode -ne 0) {
    throw '无法读取 Git 工作树状态。'
}
$sourceDirty = $statusLines.Count -gt 0
$outputName = "radio-session-$shortCommit"
if ($sourceDirty) {
    $outputName += '-dirty'
}

$programFilesX86 = ${env:ProgramFiles(x86)}
if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
    throw '当前进程未提供 ProgramFiles(x86) 路径。'
}
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "找不到本机 Visual Studio 实例查询工具：$vswhere"
}
$vsPathLines = @(& $vswhere -all -products '*' -version '[16.0,17.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
$vswhereExitCode = $LASTEXITCODE
if ($vswhereExitCode -ne 0 -or $vsPathLines.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$vsPathLines[0])) {
    throw 'vswhere 未找到已安装的 VS 2019 C++ x64 工具。脚本不会安装工具。'
}
$vsPath = ([string]$vsPathLines[0]).Trim()
$vcvarsall = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path -LiteralPath $vcvarsall -PathType Leaf)) {
    throw "所选 VS 2019 实例缺少 vcvarsall.bat：$vcvarsall"
}

$buildWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $gitRoot 'build\_work'))
$outputDirectory = [System.IO.Path]::GetFullPath((Join-Path $buildWorkRoot $outputName))
$separator = [System.IO.Path]::DirectorySeparatorChar
if (-not $outputDirectory.StartsWith($buildWorkRoot.TrimEnd($separator) + $separator,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "构建目录必须严格位于 build\_work 下：$outputDirectory"
}
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$relativeOutput = "build\_work\$outputName"

if ($sourceDirty) {
    Write-Host "源码起点提交：$commit；工作树有未提交改动，此目录仅作开发验证。"
}
else {
    Write-Host "源码提交：$commit（工作树干净）。"
}
Write-Host "Visual Studio：$vsPath"
Write-Host "构建产物：$outputDirectory"
Write-Host '使用本机 VS 2019 x64、C++17、/W4、/DNDEBUG 和静态运行库 /MT。'

function Invoke-MsvcTarget {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string[]]$Sources,
        [string[]]$Libraries = @()
    )

    $sourceArguments = [string]::Join(' ', $Sources)
    $libraryArguments = if ($Libraries.Count -gt 0) { ' /link ' + [string]::Join(' ', $Libraries) } else { '' }
    $compile = 'cl.exe /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include ' +
        '/Fo:' + $relativeOutput + '\ /Fe:' + $relativeOutput + '\' + $Name + '.exe ' +
        $sourceArguments + $libraryArguments
    $commandLine = 'call "{0}" amd64 >nul && {1}' -f $vcvarsall, $compile
    Write-Host "编译：$Name"
    & $env:ComSpec /d /s /c $commandLine
    if ($LASTEXITCODE -ne 0) { throw "MSVC 编译失败：$Name（退出码 $LASTEXITCODE）。" }
}

Push-Location $gitRoot
try {
$probeSources = @(
    'src\probe_main.cpp',
    'src\direct_frame.cpp',
    'src\direct_stream.cpp',
    'src\hri_session.cpp',
    'src\hri_downlink_session.cpp',
    'src\hri_radio_protocol.cpp',
    'src\hri_t_payload.cpp',
    'src\wave_file.cpp',
    'src\pcm_gain.cpp',
    'src\console_lifecycle.cpp',
    'src\session_report.cpp'
)
Invoke-MsvcTarget -Name 'wirex_probe' -Sources $probeSources -Libraries @('winmm.lib', 'bcrypt.lib', 'user32.lib')

$testTargets = @(
    @{ Name='hri_downlink_session_test'; Sources=@('tests\hri_downlink_session_test.cpp','src\hri_downlink_session.cpp','src\direct_stream.cpp','src\direct_frame.cpp'); Libraries=@() },
    @{ Name='hri_radio_protocol_test'; Sources=@('tests\hri_radio_protocol_test.cpp','src\hri_radio_protocol.cpp'); Libraries=@() },
    @{ Name='operation_audio_cleanup_test'; Sources=@('tests\operation_audio_cleanup_test.cpp'); Libraries=@() },
    @{ Name='audio_input_cleanup_test'; Sources=@('tests\audio_input_cleanup_test.cpp'); Libraries=@() },
    @{ Name='wave_output_open_test'; Sources=@('tests\wave_output_open_test.cpp'); Libraries=@() },
    @{ Name='session_report_test'; Sources=@('tests\session_report_test.cpp','src\session_report.cpp'); Libraries=@('bcrypt.lib') },
    @{ Name='bounded_pipe_writer_test'; Sources=@('tests\bounded_pipe_writer_test.cpp'); Libraries=@() },
    @{ Name='session_timing_test'; Sources=@('tests\session_timing_test.cpp'); Libraries=@() }
)
foreach ($target in $testTargets) {
    Invoke-MsvcTarget -Name $target.Name -Sources $target.Sources -Libraries $target.Libraries
}

if (-not $CompileOnly) {
    foreach ($target in $testTargets) {
        $testExecutable = Join-Path $outputDirectory ($target.Name + '.exe')
        Write-Host "运行离线测试：$($target.Name)"
        & $testExecutable
        if ($LASTEXITCODE -ne 0) { throw "离线测试失败：$($target.Name)（退出码 $LASTEXITCODE）。" }
    }
}

Write-Host "构建完成：$(Join-Path $outputDirectory 'wirex_probe.exe')"
}
finally {
    Pop-Location
}
