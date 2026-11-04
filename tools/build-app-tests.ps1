#requires -Version 5.1
# Builds and runs all wirex::app service tests with VS 2019 x64 cl.exe.
# Output goes to build\app-tests (git-ignored); test scratch files go to tmp\.
[CmdletBinding()]
param(
    # Optional PS-generated config.json validated for structure only (contents are never printed).
    [string]$PsConfigSample = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputDirectory = Join-Path $repoRoot 'build\app-tests'
$scratchDirectory = Join-Path $repoRoot 'tmp'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $scratchDirectory -Force | Out-Null

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "找不到 vswhere：$vswhere" }
$vsPath = @(& $vswhere -all -products '*' -version '[16.0,17.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$vsPath)) { throw '未找到 VS 2019 C++ x64 工具。' }
$vcvars = Join-Path ([string]$vsPath).Trim() 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "缺少 vcvars64.bat：$vcvars" }

$common = '/nologo /EHsc /std:c++17 /W4 /WX /permissive- /utf-8 /MT /O2 /I include'
$libraries = 'advapi32.lib setupapi.lib winmm.lib ole32.lib icuuc.lib winhttp.lib'
$tests = @(
    @{ Name = 'app_config_test'; Sources = @('tests\app_config_test.cpp', 'src\app\config.cpp', 'src\app\json.cpp') },
    @{ Name = 'app_devices_test'; Sources = @('tests\app_devices_test.cpp', 'src\app\devices.cpp') },
    @{ Name = 'app_radio_cat_test'; Sources = @('tests\app_radio_cat_test.cpp', 'src\app\radio_cat.cpp') },
    @{ Name = 'gui_fake_cat_lifecycle_test'; Sources = @('tests\gui_fake_cat_lifecycle_test.cpp', 'src\gui\fake_engine.cpp') },
    @{ Name = 'gui_cat_form_sync_test'; Sources = @('tests\gui_cat_form_sync_test.cpp') },
    @{ Name = 'gui_startup_group_activation_test'; Sources = @('tests\gui_startup_group_activation_test.cpp') },
    @{ Name = 'gui_startup_group_view_model_test'; Sources = @('tests\gui_startup_group_view_model_test.cpp', 'src\gui\view_model.cpp', 'src\gui\config_bridge.cpp', 'src\app\config.cpp', 'src\app\json.cpp', 'src\app\devices.cpp', 'src\app\bm_servers.cpp', 'src\bm_connection_config.cpp', 'src\talkgroup_routing.cpp') },
    @{ Name = 'gui_bm_profile_race_view_model_test'; Sources = @('tests\gui_bm_profile_race_view_model_test.cpp', 'src\gui\view_model.cpp', 'src\gui\config_bridge.cpp', 'src\app\config.cpp', 'src\app\json.cpp', 'src\app\devices.cpp', 'src\app\bm_servers.cpp', 'src\bm_connection_config.cpp', 'src\talkgroup_routing.cpp') },
    @{ Name = 'gui_operation_event_queue_test'; Sources = @('tests\gui_operation_event_queue_test.cpp', 'src\gui\fake_engine.cpp', 'src\gui\view_model.cpp', 'src\gui\config_bridge.cpp', 'src\app\config.cpp', 'src\app\json.cpp', 'src\app\devices.cpp', 'src\app\bm_servers.cpp', 'src\bm_connection_config.cpp', 'src\talkgroup_routing.cpp') },
    @{ Name = 'gui_radio_lifecycle_view_model_test'; Sources = @('tests\gui_radio_lifecycle_view_model_test.cpp', 'src\gui\fake_engine.cpp', 'src\gui\view_model.cpp', 'src\gui\config_bridge.cpp', 'src\app\config.cpp', 'src\app\json.cpp', 'src\app\devices.cpp', 'src\app\bm_servers.cpp', 'src\bm_connection_config.cpp', 'src\talkgroup_routing.cpp') },
    @{ Name = 'app_bm_api_test'; Sources = @('tests\app_bm_api_test.cpp', 'src\app\bm_api.cpp', 'src\app\bm_servers.cpp', 'src\app\http_client.cpp', 'src\app\json.cpp') },
    @{ Name = 'app_radio_identity_test'; Sources = @('tests\app_radio_identity_test.cpp', 'src\app\radio_identity.cpp', 'src\app\http_client.cpp', 'src\app\json.cpp', 'src\radio_identity_cache.cpp') },
    @{ Name = 'gui_config_bridge_test'; Sources = @('tests\gui_config_bridge_test.cpp', 'src\gui\config_bridge.cpp', 'src\app\config.cpp', 'src\app\json.cpp', 'src\app\devices.cpp', 'src\app\bm_servers.cpp', 'src\bm_connection_config.cpp', 'src\talkgroup_routing.cpp') }
)

$env:PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH  # vcvars64.bat looks up vswhere.exe on PATH
$env:TMPDIR = $scratchDirectory
$env:TEMP = $scratchDirectory
$env:TMP = $scratchDirectory
if ($PsConfigSample) { $env:WIREX_PS_CONFIG_SAMPLE = [System.IO.Path]::GetFullPath($PsConfigSample) }
else { Remove-Item Env:\WIREX_PS_CONFIG_SAMPLE -ErrorAction SilentlyContinue }

Push-Location $repoRoot
try {
    foreach ($test in $tests) {
        $objectDirectory = Join-Path $outputDirectory ($test.Name + '-obj')
        New-Item -ItemType Directory -Path $objectDirectory -Force | Out-Null
        $exe = Join-Path $outputDirectory ($test.Name + '.exe')
        $command = 'cl.exe {0} /Fo"{1}\\" /Fe"{2}" {3} /link {4}' -f $common, $objectDirectory, $exe, ($test.Sources -join ' '), $libraries
        # cl.exe writes diagnostics to stderr; keep them as text instead of terminating errors.
        $ErrorActionPreference = 'Continue'
        $output = @(& $env:ComSpec /d /s /c ('call "{0}" >nul 2>&1 && {1}' -f $vcvars, $command) 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $warnings = @($output | Where-Object { [string]$_ -match 'warning [A-Z]+[0-9]+' })
        foreach ($line in $output) { Write-Host $line }
        if ($exitCode -ne 0) { throw "$($test.Name) 编译失败（退出码 $exitCode）。" }
        if ($warnings.Count -gt 0) { throw "$($test.Name) 存在 $($warnings.Count) 条编译警告。" }
        & $exe
        if ($LASTEXITCODE -ne 0) { throw "$($test.Name) 测试失败（退出码 $LASTEXITCODE）。" }
    }
} finally {
    Pop-Location
}
Write-Host 'app 测试全部通过，0 warning。'
