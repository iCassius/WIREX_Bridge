# Builds a headless Dear ImGui harness for stable IDs and click selection.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'build\_work'))
$buildDirectory = [System.IO.Path]::GetFullPath((Join-Path $workRoot ('ui-id-harness-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))))
if (-not $buildDirectory.StartsWith($workRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Harness output must remain under build\_work: $buildDirectory"
}
New-Item -ItemType Directory -Path $buildDirectory -ErrorAction Stop | Out-Null
$imguiObjects = Join-Path $buildDirectory 'imgui-obj'
$testObjects = Join-Path $buildDirectory 'test-obj'
New-Item -ItemType Directory -Path $imguiObjects, $testObjects -ErrorAction Stop | Out-Null
$exe = Join-Path $buildDirectory 'gui_duplicate_item_harness.exe'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "Cannot find vswhere: $vswhere" }
$vsLines = @(& $vswhere -all -products '*' -version '[16.0,17.0)' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
if ($LASTEXITCODE -ne 0 -or $vsLines.Count -lt 1) { throw 'VS 2019 x64 C++ tools were not found.' }
$vcvars = Join-Path ([string]$vsLines[0]).Trim() 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "Missing vcvars64.bat: $vcvars" }

function Invoke-MsvcCommand {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$CommandLine)
    $output = @(& $env:ComSpec /d /s /c ('call "{0}" >nul 2>&1 && {1}' -f $vcvars, $CommandLine) 2>&1 |
        ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host $line }
    if ($code -ne 0) { throw "$Name failed with exit code $code." }
    if (@($output | Where-Object { $_ -match 'warning [A-Z]+\d+' }).Count -gt 0) {
        throw "$Name emitted a compiler warning."
    }
}

Push-Location $appRoot
try {
    $imguiFlags = '/nologo /c /O2 /MT /EHsc /std:c++17 /permissive- /utf-8 /W3 /I third_party\imgui'
    $imguiSources = @('imgui.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp') |
        ForEach-Object { 'third_party\imgui\' + $_ }
    Invoke-MsvcCommand -Name 'Dear ImGui core' -CommandLine (
        'cl.exe {0} /Fo"{1}\\" {2}' -f $imguiFlags, $imguiObjects, ($imguiSources -join ' '))

    $testFlags = '/nologo /c /O2 /MT /EHsc /std:c++17 /permissive- /utf-8 /W4 /WX /I third_party\imgui /I src\gui'
    Invoke-MsvcCommand -Name 'UI ID harness' -CommandLine (
        'cl.exe {0} /Fo"{1}\\" tests\gui_duplicate_item_harness.cpp' -f $testFlags, $testObjects)

    $linkObjects = Join-Path $imguiObjects '*.obj'
    $testObject = Join-Path $testObjects 'gui_duplicate_item_harness.obj'
    Invoke-MsvcCommand -Name 'UI ID harness link' -CommandLine (
        'link.exe /nologo /OUT:"{0}" "{1}" "{2}"' -f $exe, $linkObjects, $testObject)
} finally {
    Pop-Location
}

& $exe
if ($LASTEXITCODE -ne 0) { throw "UI ID harness failed with exit code $LASTEXITCODE." }
Write-Output "Harness output: $buildDirectory"
