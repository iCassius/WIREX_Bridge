[CmdletBinding()]
param(
    # 正式版：dev 日志默认关闭（仍可用 --dev-log 临时开启）。默认构建为开发版，dev 日志默认开启。
    [switch]$Release
)

# R128 原生 GUI 外壳：Dear ImGui + Win32 + DirectX 11，MSVC 2019 /MT 静态链接为单个 WirexBridge.exe。
# 产物：build/_work/wirex-gui-<commit7>[-dirty]-<UTC 时间>/WirexBridge.exe，附 gui-build.log 与 gui-build-provenance.json。
# 告警策略：本项目代码 /W4 /WX（0 warning）；third_party/imgui 保持上游原样，单独以 /W3 编译。

$ErrorActionPreference = 'Stop'
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$separator = [System.IO.Path]::DirectorySeparatorChar

$gitRootLines = @(& git -C $appRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $gitRootLines.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$gitRootLines[0])) {
    throw '无法定位当前 WIREX Bridge Git 根目录。'
}
$gitRoot = [System.IO.Path]::GetFullPath(([string]$gitRootLines[0]).Trim())
if (-not $gitRoot.Equals($appRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "脚本必须从 WIREX Bridge 仓库内运行：$appRoot"
}
$commitLines = @(& git -C $gitRoot rev-parse HEAD 2>$null)
$commit = if ($commitLines.Count -gt 0) { ([string]$commitLines[0]).Trim() } else { '' }
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-fA-F]{40}$') { throw '无法读取当前完整 Git 提交号。' }
$statusLines = @(& git -C $gitRoot status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 工作树状态。' }
$dirtySuffix = if ($statusLines.Count -gt 0) { '-dirty' } else { '' }

$buildName = 'wirex-gui-{0}{1}-{2}' -f $commit.Substring(0, 7).ToLowerInvariant(), $dirtySuffix,
    [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build\_work'))
$outputDirectory = [System.IO.Path]::GetFullPath((Join-Path $workRoot $buildName))
if (-not $outputDirectory.StartsWith($workRoot.TrimEnd($separator) + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "GUI 输出目录必须位于 build\_work 内：$outputDirectory"
}
if (Test-Path -LiteralPath $outputDirectory) { throw "GUI 输出目录已存在，拒绝复用：$outputDirectory" }

$imguiFiles = @('imgui.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp',
    'backends\imgui_impl_win32.cpp', 'backends\imgui_impl_dx11.cpp') | ForEach-Object { 'third_party\imgui\' + $_ }
$guiFiles = @('gui_main.cpp', 'app_view.cpp', 'view_model.cpp', 'fake_engine.cpp', 'config_bridge.cpp', 'real_services.cpp', 'dev_log.cpp', 'dev_log_engine.cpp') |
    ForEach-Object { 'src\gui\' + $_ }
# GUI 用到的 app 服务与 native 公共模块（与 tools/build-app-tests.ps1 同一组源文件）。
$serviceFiles = @('app\config.cpp', 'app\json.cpp', 'app\devices.cpp', 'app\radio_cat.cpp', 'app\radio_info.cpp', 'app\bm_api.cpp',
    'app\bm_servers.cpp', 'app\http_client.cpp', 'app\radio_identity.cpp') | ForEach-Object { 'src\' + $_ }
# 进程内桥接引擎及其 native 模块：与 tools/build-bm-bridge.ps1 的 $coreSources 相同（不含管道适配层与 CLI 入口）。
$engineFiles = @('dmrd.cpp', 'dmr_call.cpp', 'talkgroup_routing.cpp', 'dmr_vocoder.cpp', 'pcm_resampler.cpp',
    'bm_voice_pipeline.cpp', 'bm_test_profile.cpp', 'bm_connection_config.cpp', 'bm_connection_control.cpp',
    'bm_session.cpp', 'bm_udp.cpp', 'direct_frame.cpp', 'direct_stream.cpp', 'hri_session.cpp', 'hri_ptt_gate.cpp',
    'hri_downlink_session.cpp', 'hri_radio_protocol.cpp', 'hri_t_payload.cpp', 'hri_call_header.cpp', 'hri_t_record.cpp',
    'hri_lcd_identity_candidate.cpp', 'radio_identity_cache.cpp', 'hri_stream_session.cpp', 'wave_file.cpp',
    'pcm_gain.cpp', 'console_lifecycle.cpp', 'session_report.cpp', 'ui_control_protocol.cpp', 'strict_json.cpp',
    'routing_state.cpp', 'engine\engine.cpp', 'engine\engine_loop.cpp', 'engine\engine_status.cpp',
    'engine\engine_devices_win.cpp') | ForEach-Object { 'src\' + $_ }
$engineFiles += 'third_party\dmr_signal\dmr_signal.cpp'
$droidstarManifest = Get-Content -LiteralPath (Join-Path $appRoot 'third_party\droidstar_mbe\source-manifest.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
$droidstarFiles = @($droidstarManifest.files | Where-Object { [string]$_.path -match '^upstream/(imbe_vocoder/.*\.cc|mbe/.*\.cpp)$' } |
    ForEach-Object { 'third_party\droidstar_mbe\' + ([string]$_.path).Replace('/', '\') })
if ($droidstarFiles.Count -ne 27) { throw "DroidStar 编译源数量不符：$($droidstarFiles.Count)" }
$appFiles = @($guiFiles + $serviceFiles + $engineFiles)
foreach ($relative in @($imguiFiles + $appFiles + $droidstarFiles + @('src\gui\wirex_gui.rc', 'src\gui\wirex_gui.manifest', 'assets\wiresx-official.ico'))) {
    if (-not (Test-Path -LiteralPath (Join-Path $appRoot $relative) -PathType Leaf)) { throw "缺少 GUI 构建输入：$relative" }
}
$imguiVersionLine = Select-String -LiteralPath (Join-Path $appRoot 'third_party\imgui\imgui.h') -Pattern '^#define IMGUI_VERSION\s+"([^"]+)"' |
    Select-Object -First 1
if (-not $imguiVersionLine) { throw '无法从 third_party/imgui/imgui.h 读取 IMGUI_VERSION。' }
$imguiVersion = $imguiVersionLine.Matches[0].Groups[1].Value

$programFilesX86 = ${env:ProgramFiles(x86)}
if ([string]::IsNullOrWhiteSpace($programFilesX86)) { throw '当前进程未提供 ProgramFiles(x86) 路径。' }
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "找不到本机 Visual Studio 实例查询工具：$vswhere" }
$vsPathLines = @(& $vswhere -all -products '*' -version '[16.0,17.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
if ($LASTEXITCODE -ne 0 -or $vsPathLines.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$vsPathLines[0])) {
    throw 'vswhere 未找到已安装的 VS 2019 C++ x64 工具；脚本不会安装依赖。'
}
$vcvars = Join-Path ([string]$vsPathLines[0]).Trim() 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "所选 VS 2019 实例缺少 vcvars64.bat：$vcvars" }

New-Item -ItemType Directory -Path $outputDirectory -ErrorAction Stop | Out-Null
$objImgui = Join-Path $outputDirectory 'obj\imgui'
$objApp = Join-Path $outputDirectory 'obj\app'
$objUpstream = Join-Path $outputDirectory 'obj\upstream'
New-Item -ItemType Directory -Path $objImgui, $objApp, $objUpstream -Force | Out-Null
$logPath = Join-Path $outputDirectory 'gui-build.log'
$executablePath = Join-Path $outputDirectory 'WirexBridge.exe'
$resPath = Join-Path $outputDirectory 'wirex_gui.res'
$logLines = New-Object System.Collections.Generic.List[string]

function Invoke-MsvcStep {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$CommandLine)
    # VSLANG=1033：编译器输出英文，日志与告警计数不受控制台代码页影响。
    $output = @(& $env:ComSpec /d /s /c ('set VSLANG=1033&& call "{0}" >nul && {1}' -f $vcvars, $CommandLine) 2>&1)
    $exitCode = $LASTEXITCODE
    $logLines.Add("== $Name") | Out-Null
    $logLines.Add($CommandLine) | Out-Null
    foreach ($line in $output) { $logLines.Add([string]$line) | Out-Null; Write-Host $line }
    if ($exitCode -ne 0) {
        [System.IO.File]::WriteAllLines($logPath, $logLines, (New-Object System.Text.UTF8Encoding($true)))
        throw "$Name 失败（退出码 $exitCode），检查 $logPath。"
    }
    return @($output | ForEach-Object { [string]$_ })
}

$common = '/nologo /c /O2 /MT /EHsc /std:c++17 /permissive- /utf-8 /DUNICODE /D_UNICODE /DIMGUI_DISABLE_DEMO_WINDOWS /DWIREX_GUI_REAL_ENGINE=1 /DWIREX_DEV_BUILD={0} /I third_party\imgui /I include /I third_party\dmr_signal /I third_party\droidstar_mbe\upstream' -f $(if ($Release) { 0 } else { 1 })
Push-Location $appRoot
try {
    [void](Invoke-MsvcStep -Name 'ImGui (/W3)' -CommandLine ('cl.exe {0} /W3 /Fo"{1}\\" {2}' -f $common, $objImgui, ($imguiFiles -join ' ')))
    [void](Invoke-MsvcStep -Name 'DroidStar MBE/IMBE (/W0)' -CommandLine ('cl.exe {0} /W0 /D_USE_MATH_DEFINES /Fo"{1}\\" {2}' -f $common, $objUpstream, ($droidstarFiles -join ' ')))
    $appOutput = Invoke-MsvcStep -Name 'GUI (/W4 /WX)' -CommandLine ('cl.exe {0} /W4 /WX /Fo"{1}\\" {2}' -f $common, $objApp, ($appFiles -join ' '))
    $appWarnings = @($appOutput | Where-Object { $_ -match '\bwarning [A-Z]+\d+' })
    if ($appWarnings.Count -gt 0) { throw ('本项目 GUI 代码出现 {0} 条告警。' -f $appWarnings.Count) }
    [void](Invoke-MsvcStep -Name 'rc' -CommandLine ('rc.exe /nologo /I . /fo "{0}" src\gui\wirex_gui.rc' -f $resPath))
    $libs = 'd3d11.lib dxgi.lib d3dcompiler.lib user32.lib gdi32.lib shell32.lib ole32.lib windowscodecs.lib imm32.lib dwmapi.lib ' +
        'winhttp.lib setupapi.lib advapi32.lib winmm.lib icuuc.lib bcrypt.lib ws2_32.lib'
    [void](Invoke-MsvcStep -Name 'link' -CommandLine ('link.exe /nologo /SUBSYSTEM:WINDOWS /OPT:REF /OPT:ICF /OUT:"{0}" "{1}\*.obj" "{2}\*.obj" "{3}\*.obj" "{4}" {5}' -f `
        $executablePath, $objApp, $objImgui, $objUpstream, $resPath, $libs))
} finally {
    Pop-Location
}
[System.IO.File]::WriteAllLines($logPath, $logLines, (New-Object System.Text.UTF8Encoding($true)))
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw 'link 成功但没有生成 WirexBridge.exe。' }

$relativeOutput = $outputDirectory.Substring($appRoot.TrimEnd($separator).Length + 1).Replace('\', '/')
$executable = Get-Item -LiteralPath $executablePath
$provenance = [ordered]@{
    schema_version = 1
    dev_build = -not [bool]$Release
    result = 'passed'
    source = [ordered]@{ commit = $commit; tree_clean = ($statusLines.Count -eq 0) }
    imgui = [ordered]@{ version = $imguiVersion; path = 'third_party/imgui' }
    compiler = [ordered]@{
        family = 'MSVC 2019 (vcvars64)'
        app_flags = '/O2 /MT /EHsc /std:c++17 /W4 /WX /permissive- /utf-8'
        imgui_flags = '/O2 /MT /EHsc /std:c++17 /W3 /permissive- /utf-8'
        app_warnings = 0
    }
    output = [ordered]@{
        directory = $relativeOutput
        path = 'WirexBridge.exe'
        length_bytes = [long]$executable.Length
        sha256 = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$provenanceJson = ConvertTo-Json -InputObject $provenance -Depth 6
[System.IO.File]::WriteAllText((Join-Path $outputDirectory 'gui-build-provenance.json'), $provenanceJson + "`n",
    (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('GUI 编译通过：' + $relativeOutput + '/WirexBridge.exe')
Write-Output ('GUI 构建产物：' + $outputDirectory)
