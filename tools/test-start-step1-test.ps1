[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$assertions = 0
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'build\_work'))
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $workRoot ('start-step1-test-offline-' + [guid]::NewGuid().ToString('N'))))

function Test-PathWithinDirectory {
    param([string]$Path, [string]$Directory)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    return $fullPath.StartsWith(($fullDirectory + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function New-FakeStartUi {
    param([string]$Path)
    $text = @'
param([string]$UserConfigDirectory)
if ([string]::IsNullOrWhiteSpace($env:WIREX_R106_STEP1_TEST_CAPTURE)) { throw 'capture path is missing' }
[System.IO.File]::WriteAllText($env:WIREX_R106_STEP1_TEST_CAPTURE, [System.IO.Path]::GetFullPath($UserConfigDirectory), [System.Text.UTF8Encoding]::new($false))
'@
    Write-Utf8NoBom -Path $Path -Text $text
}

if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) { New-Item -ItemType Directory -Path $workRoot -ErrorAction Stop | Out-Null }
if (-not (Test-PathWithinDirectory -Path $testRoot -Directory $workRoot) -or (Test-Path -LiteralPath $testRoot)) {
    throw 'The offline test directory path is unsafe or already exists.'
}
New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop | Out-Null
$previousCapture = $env:WIREX_R106_STEP1_TEST_CAPTURE
try {
    $packagedRoot = Join-Path $testRoot 'package-root'
    New-Item -ItemType Directory -Path $packagedRoot -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-step1-test.ps1') `
        -Destination (Join-Path $packagedRoot 'start-step1-test.ps1') -ErrorAction Stop
    New-FakeStartUi -Path (Join-Path $packagedRoot 'start-ui.ps1')
    $env:WIREX_R106_STEP1_TEST_CAPTURE = Join-Path $testRoot 'package-captured-path.txt'

    & (Join-Path $packagedRoot 'start-step1-test.ps1')
    $defaultConfig = [System.IO.Path]::GetFullPath((Join-Path $packagedRoot 'private\r106-step1-test-config'))
    $capturedDefault = [System.IO.File]::ReadAllText($env:WIREX_R106_STEP1_TEST_CAPTURE, [System.Text.Encoding]::UTF8)
    Assert-True ($capturedDefault -ceq $defaultConfig) 'packaged ScriptRoot selects its own private/r106-step1-test-config directory'
    Assert-True (Test-Path -LiteralPath $defaultConfig -PathType Container) 'the default isolated configuration directory is created'
    Assert-True (@(Get-ChildItem -LiteralPath $defaultConfig -Force).Count -eq 0) 'the entry does not copy or create configuration files'

    $markerPath = Join-Path $defaultConfig 'test-marker.txt'
    Write-Utf8NoBom -Path $markerPath -Text 'preserve existing test data'
    & (Join-Path $packagedRoot 'start-step1-test.ps1')
    $capturedAgain = [System.IO.File]::ReadAllText($env:WIREX_R106_STEP1_TEST_CAPTURE, [System.Text.Encoding]::UTF8)
    Assert-True ($capturedAgain -ceq $defaultConfig) 'restarting the entry uses the same default configuration path'
    Assert-True ([System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8) -ceq 'preserve existing test data') `
        'restarting the entry preserves existing test-directory contents'

    $customConfig = Join-Path $packagedRoot 'private\custom-step1-test-config'
    & (Join-Path $packagedRoot 'start-step1-test.ps1') -UserConfigDirectory $customConfig
    $capturedCustom = [System.IO.File]::ReadAllText($env:WIREX_R106_STEP1_TEST_CAPTURE, [System.Text.Encoding]::UTF8)
    Assert-True ($capturedCustom -ceq [System.IO.Path]::GetFullPath($customConfig)) 'an explicit absolute UserConfigDirectory is passed unchanged'
    Assert-True (Test-Path -LiteralPath $customConfig -PathType Container) 'an explicit configuration directory is created'

    $sourceRoot = Join-Path $testRoot 'synthetic-source-root'
    $sourceTools = Join-Path $sourceRoot 'tools'
    New-Item -ItemType Directory -Path $sourceTools -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start-step1-test.ps1') `
        -Destination (Join-Path $sourceTools 'start-step1-test.ps1') -ErrorAction Stop
    New-FakeStartUi -Path (Join-Path $sourceTools 'start-ui.ps1')
    & (Join-Path $sourceTools 'start-step1-test.ps1')
    $sourceConfig = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'private\r106-step1-test-config'))
    $capturedSource = [System.IO.File]::ReadAllText($env:WIREX_R106_STEP1_TEST_CAPTURE, [System.Text.Encoding]::UTF8)
    Assert-True ($capturedSource -ceq $sourceConfig) 'source-tree ScriptRoot resolves to the repository root, not the tools directory'
    Assert-True (Test-Path -LiteralPath $sourceConfig -PathType Container) 'source-tree default configuration directory is created at the repository root'

    Write-Output ('Step-one test launcher offline assertions passed: ' + $script:assertions + '; UI launch was replaced by a local capture stub.')
} finally {
    if ($previousCapture -is [string]) { $env:WIREX_R106_STEP1_TEST_CAPTURE = $previousCapture }
    else { Remove-Item Env:WIREX_R106_STEP1_TEST_CAPTURE -ErrorAction SilentlyContinue }
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if (-not (Test-PathWithinDirectory -Path $resolvedTestRoot -Directory $workRoot) -or
        [System.IO.Path]::GetFileName($resolvedTestRoot) -notmatch '^start-step1-test-offline-[0-9a-f]{32}$') {
        throw 'The offline test directory failed its cleanup path check.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolvedTestRoot) { throw 'The offline test directory remains after cleanup.' }
    }
}
