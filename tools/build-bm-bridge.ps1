[CmdletBinding()]
param(
    [switch]$CompileOnly
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gitRootLines = @(& git -C $repositoryRoot rev-parse --show-toplevel 2>$null)
$gitRootExitCode = $LASTEXITCODE
if ($gitRootExitCode -ne 0 -or $gitRootLines.Count -lt 1 -or
    [string]::IsNullOrWhiteSpace([string]$gitRootLines[0])) {
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
$statusLines = @(& git -C $gitRoot status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 工作树状态。' }
$dirtySuffix = if ($statusLines.Count -gt 0) { '-dirty' } else { '' }
$buildName = 'wirex-bridge-{0}{1}-{2}' -f $commit.Substring(0, 7).ToLowerInvariant(),
    $dirtySuffix, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$buildWorkRoot = [System.IO.Path]::GetFullPath((Join-Path $gitRoot 'build\_work'))
$outputDirectory = [System.IO.Path]::GetFullPath((Join-Path $buildWorkRoot $buildName))
$separator = [System.IO.Path]::DirectorySeparatorChar
if (-not $outputDirectory.StartsWith($buildWorkRoot.TrimEnd($separator) + $separator,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "构建产物必须位于 build\_work 下：$outputDirectory"
}
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$gitRootPrefix = $gitRoot.TrimEnd($separator) + $separator
function Get-RepoRelativePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($gitRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径不在 Git 根目录内：$fullPath"
    }
    return $fullPath.Substring($gitRootPrefix.Length).Replace('/', '\')
}
$relativeOutput = Get-RepoRelativePath -Path $outputDirectory

$manifestPath = Join-Path $gitRoot 'third_party\droidstar_mbe\source-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw '缺少 DroidStar 固定源文件 manifest。'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.commit -ne 'becf1dede57c4a70a865e9cb4cac9247e505599a' -or
    $manifest.file_count -ne 57 -or @($manifest.files).Count -ne 57) {
    throw 'DroidStar manifest 的固定 commit 或 57 项文件清单与预期不符。'
}
foreach ($entry in $manifest.files) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.local_sha256) -or
        [string]$entry.local_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "manifest 缺少本地 SHA-256：$($entry.path)"
    }
    $vendorRoot = Join-Path $gitRoot 'third_party\droidstar_mbe'
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $vendorRoot ([string]$entry.path)))
    if (-not $sourcePath.StartsWith($vendorRoot.TrimEnd($separator) + $separator,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "第三方源文件缺失或越界：$($entry.path)"
    }
    $actualHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    if (-not $actualHash.Equals([string]$entry.local_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "第三方源文件与固定 manifest 不匹配：$($entry.path)"
    }
}
Write-Host 'DroidStar 固定 commit 的 57 个本地源文件 SHA-256 全部通过。'

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
if ($LASTEXITCODE -ne 0 -or $vsPathLines.Count -lt 1 -or
    [string]::IsNullOrWhiteSpace([string]$vsPathLines[0])) {
    throw 'vswhere 未找到已安装的 VS 2019 C++ x64 工具；脚本不会安装依赖。'
}
$vcvarsall = Join-Path ([string]$vsPathLines[0]).Trim() 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path -LiteralPath $vcvarsall -PathType Leaf)) {
    throw "所选 VS 2019 实例缺少 vcvarsall.bat：$vcvarsall"
}

function Invoke-MsvcCommand {
    param([Parameter(Mandatory=$true)][string]$CommandLine)
    $output = @(& $env:ComSpec /d /s /c ('call "{0}" amd64 >nul && {1}' -f $vcvarsall, $CommandLine) 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-Host $line }
    if ($exitCode -ne 0) { throw "MSVC 命令失败，退出码 $exitCode。" }
}

function Invoke-CompileGroup {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string[]]$Sources,
        [Parameter(Mandatory=$true)][string]$ObjectDirectory,
        [Parameter(Mandatory=$true)][string]$WarningLevel,
        [string[]]$Definitions = @()
    )
    if ($Sources.Count -eq 0) { throw "编译组不能为空：$Name" }
    $fullObjectDirectory = [System.IO.Path]::GetFullPath((Join-Path $outputDirectory $ObjectDirectory))
    if (-not $fullObjectDirectory.StartsWith($outputDirectory.TrimEnd($separator) + $separator,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "对象目录越界：$fullObjectDirectory"
    }
    New-Item -ItemType Directory -Path $fullObjectDirectory -Force | Out-Null
    $relativeObjectDirectory = Get-RepoRelativePath -Path $fullObjectDirectory
    $definitionArguments = if ($Definitions.Count -gt 0) { ' /D' + [string]::Join(' /D', $Definitions) } else { '' }
    $sourcesArgument = [string]::Join(' ', $Sources)
    $command = 'cl.exe /nologo /c /O2 /MT /EHsc /std:c++17 /{0} /permissive- /utf-8 /I include /I third_party\dmr_signal /I third_party\droidstar_mbe\upstream{1} /Fo:{2}\ {3}' -f `
        $WarningLevel, $definitionArguments, $relativeObjectDirectory, $sourcesArgument
    Write-Host "编译源码组：$Name（$($Sources.Count) 个源文件）"
    Invoke-MsvcCommand -CommandLine $command
    $objects = @(Get-ChildItem -LiteralPath $fullObjectDirectory -Filter '*.obj' -File | Sort-Object Name)
    if ($objects.Count -ne $Sources.Count) {
        throw "编译组 $Name 产出的对象文件数量不符：期望 $($Sources.Count)，实际 $($objects.Count)。"
    }
    return ,@($objects | ForEach-Object { Get-RepoRelativePath -Path $_.FullName })
}

function Invoke-LinkExecutable {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string[]]$Objects,
        [string[]]$Libraries = @('winmm.lib', 'bcrypt.lib', 'ws2_32.lib', 'user32.lib')
    )
    $outputFile = Join-Path $relativeOutput ($Name + '.exe')
    $command = 'link.exe /nologo /OUT:{0} {1} {2}' -f $outputFile,
        [string]::Join(' ', $Objects), [string]::Join(' ', $Libraries)
    Write-Host "链接程序：$Name"
    Invoke-MsvcCommand -CommandLine $command
}

Push-Location $gitRoot
try {
    $coreSources = @(
        'src\dmrd.cpp',
        'third_party\dmr_signal\dmr_signal.cpp',
        'src\dmr_call.cpp',
        'src\dmr_vocoder.cpp',
        'src\pcm_resampler.cpp',
        'src\bm_voice_pipeline.cpp',
        'src\bm_test_profile.cpp',
        'src\bm_connection_config.cpp',
        'src\bm_session.cpp',
        'src\bm_udp.cpp',
        'src\direct_frame.cpp',
        'src\direct_stream.cpp',
        'src\hri_session.cpp',
        'src\hri_ptt_gate.cpp',
        'src\hri_downlink_session.cpp',
        'src\hri_radio_protocol.cpp',
        'src\hri_t_payload.cpp',
        'src\hri_stream_session.cpp',
        'src\wave_file.cpp',
        'src\pcm_gain.cpp',
        'src\console_lifecycle.cpp',
        'src\session_report.cpp'
    )
    $upstreamSources = @($manifest.files | Where-Object {
        [string]$_.path -match '^upstream/(imbe_vocoder/.*\.cc|mbe/.*\.cpp)$'
    } | ForEach-Object { 'third_party\droidstar_mbe\' + ([string]$_.path).Replace('/', '\') })
    if ($upstreamSources.Count -ne 27) { throw "DroidStar 编译源数量不符：$($upstreamSources.Count)" }

    $coreObjects = Invoke-CompileGroup -Name 'WIREX + BM runtime modules' -Sources $coreSources `
        -ObjectDirectory 'objects\runtime' -WarningLevel 'W4'
    $upstreamObjects = Invoke-CompileGroup -Name '固定 DroidStar MBE/IMBE 实现' -Sources $upstreamSources `
        -ObjectDirectory 'objects\upstream' -WarningLevel 'W0' -Definitions @('_USE_MATH_DEFINES')

    $bridgeMain = Invoke-CompileGroup -Name 'native BM bridge entry' -Sources @('src\probe_main.cpp') `
        -ObjectDirectory 'objects\bridge-entry' -WarningLevel 'W4' -Definitions @('WIREX_ENABLE_BM_BRIDGE')
    Invoke-LinkExecutable -Name 'wirex_bridge' -Objects (@($bridgeMain) + @($coreObjects) + @($upstreamObjects))

    $oldProbeSources = @(
        'src\probe_main.cpp', 'src\direct_frame.cpp', 'src\direct_stream.cpp',
        'src\hri_session.cpp', 'src\hri_downlink_session.cpp', 'src\hri_radio_protocol.cpp',
        'src\hri_t_payload.cpp', 'src\wave_file.cpp', 'src\pcm_gain.cpp',
        'src\console_lifecycle.cpp', 'src\session_report.cpp'
    )
    $oldProbeCommand = 'cl.exe /nologo /O2 /MT /EHsc /std:c++17 /W4 /permissive- /utf-8 /I include /Fo:{0}\ /Fe:{0}\wirex_probe.exe {1} /link winmm.lib bcrypt.lib user32.lib' -f `
        $relativeOutput, [string]::Join(' ', $oldProbeSources)
    Write-Host '按原有链接清单单独构建 wirex_probe。'
    Invoke-MsvcCommand -CommandLine $oldProbeCommand

    $testSpecs = @(
        @{ Name='dmrd_test'; Source='tests\dmrd_test.cpp' },
        @{ Name='direct_frame_test'; Source='tests\direct_frame_test.cpp' },
        @{ Name='hri_t_payload_test'; Source='tests\hri_t_payload_test.cpp' },
        @{ Name='direct_stream_test'; Source='tests\direct_stream_test.cpp' },
        @{ Name='hri_session_test'; Source='tests\hri_session_test.cpp' },
        @{ Name='hri_ptt_gate_test'; Source='tests\hri_ptt_gate_test.cpp' },
        @{ Name='hri_downlink_session_test'; Source='tests\hri_downlink_session_test.cpp' },
        @{ Name='hri_radio_protocol_test'; Source='tests\hri_radio_protocol_test.cpp' },
        @{ Name='operation_audio_cleanup_test'; Source='tests\operation_audio_cleanup_test.cpp' },
        @{ Name='audio_input_cleanup_test'; Source='tests\audio_input_cleanup_test.cpp' },
        @{ Name='wave_output_open_test'; Source='tests\wave_output_open_test.cpp' },
        @{ Name='session_timing_test'; Source='tests\session_timing_test.cpp' },
        @{ Name='wave_file_test'; Source='tests\wave_file_test.cpp' },
        @{ Name='pcm_gain_test'; Source='tests\pcm_gain_test.cpp' },
        @{ Name='bounded_pipe_writer_test'; Source='tests\bounded_pipe_writer_test.cpp' },
        @{ Name='console_lifecycle_test'; Source='tests\console_lifecycle_test.cpp' },
        @{ Name='session_report_test'; Source='tests\session_report_test.cpp' },
        @{ Name='dmr_call_test'; Source='tests\dmr_call_test.cpp' },
        @{ Name='bm_session_test'; Source='tests\bm_session_test.cpp' },
        @{ Name='bm_udp_test'; Source='tests\bm_udp_test.cpp' },
        @{ Name='dmr_vocoder_test'; Source='tests\dmr_vocoder_test.cpp' },
        @{ Name='pcm_resampler_test'; Source='tests\pcm_resampler_test.cpp' },
        @{ Name='bm_voice_pipeline_test'; Source='tests\bm_voice_pipeline_test.cpp' },
        @{ Name='bm_test_profile_test'; Source='tests\bm_test_profile_test.cpp' },
        @{ Name='bm_connection_config_test'; Source='tests\bm_connection_config_test.cpp' },
        @{ Name='hri_stream_session_test'; Source='tests\hri_stream_session_test.cpp' },
        @{ Name='bm_bridge_loopback_test'; Source='tests\bm_bridge_loopback_test.cpp' }
    )
    $testObjects = @()
    foreach ($test in $testSpecs) {
        if (-not (Test-Path -LiteralPath (Join-Path $gitRoot $test.Source) -PathType Leaf)) {
            throw "缺少测试源文件：$($test.Source)"
        }
        $testObject = Invoke-CompileGroup -Name $test.Name -Sources @($test.Source) `
            -ObjectDirectory ('objects\tests\' + $test.Name) -WarningLevel 'W4'
        $testObjects += ,@{ Name=$test.Name; Object=$testObject[0] }
    }

    if (-not $CompileOnly) {
        foreach ($test in $testObjects) {
            $testName = [string]$test.Name
            Invoke-LinkExecutable -Name $testName -Objects (@($test.Object) + @($coreObjects) + @($upstreamObjects))
            $testExecutable = Join-Path $outputDirectory ($testName + '.exe')
            Write-Host "运行离线测试：$testName"
            & $testExecutable
            if ($LASTEXITCODE -ne 0) { throw "离线测试失败：$testName（退出码 $LASTEXITCODE）。" }
        }
    }

    Write-Host "构建产物：$outputDirectory"
    Write-Host "可执行文件：$(Join-Path $outputDirectory 'wirex_bridge.exe')"
    if ($testObjects.Name -notcontains 'bm_bridge_loopback_test') {
        Write-Warning '本次未运行 fake Master 组合测试，因对应测试源码尚未落盘。'
    }
}
finally {
    Pop-Location
}
