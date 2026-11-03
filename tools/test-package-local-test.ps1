[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stableSourceCommit = 'c12b50a9f339417ffd49d37b7acab6057fa51bcf'
$expectedStableManifestSha256 = '1bdc80890cd8aa0b51b19c8f6385d312014b11c006b4643e2b31862cd980cc0e'
$expectedNativeSha256 = '8f629aefbaaba3b865f09b3d1cb4b012e6b1953a7ec58d340edbec460225ca32'
$expectedLauncherSha256 = 'de4d0b113cd7a25a907b3fe96a0a4b1579730c1a884175930ad6db9412b60638'
$expectedDeviceTemplateSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$expectedDeviceTemplateLength = 100
$checkCount = 0

function Assert-LocalTestPackage {
    param([bool]$Condition, [string]$Message)
    $script:checkCount++
    if (-not $Condition) { throw "FAILED: $Message" }
}

function Get-GitText {
    param([string]$Root, [string[]]$Arguments)
    $output = & git -C $Root @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw ("git {0} failed: {1}" -f ($Arguments -join ' '), ($output -join ' ')) }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-MainWorktreeRoot {
    param([string]$Root)
    $raw = Get-GitText -Root $Root -Arguments @('worktree', 'list', '--porcelain')
    $mainRoots = @()
    foreach ($block in [regex]::Split($raw, '\r?\n\r?\n')) {
        $lines = [regex]::Split($block, '\r?\n')
        $worktreeLine = $lines | Where-Object { $_.StartsWith('worktree ', [StringComparison]::Ordinal) } | Select-Object -First 1
        if ($null -ne $worktreeLine -and $lines -ccontains 'branch refs/heads/main') {
            $mainRoots += [IO.Path]::GetFullPath($worktreeLine.Substring(9))
        }
    }
    if ($mainRoots.Count -ne 1) { throw 'Could not identify exactly one main checkout.' }
    return $mainRoots[0]
}

function Get-RelativeAssetPath {
    param([string]$Root, [string]$Path)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Package entry escaped its root: $Path" }
    return $full.Substring($prefix.Length).Replace('\', '/')
}

function Get-SafeAssetPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.StartsWith('/') -or $RelativePath.Contains('\')) {
        throw "Noncanonical manifest path: $RelativePath"
    }
    $parts = $RelativePath.Split('/')
    if (@($parts | Where-Object { $_ -in @('', '.', '..') -or $_ -match '^(?i:config\.json|logs?|cache|credentials?|tempsecrets?)$' }).Count -ne 0) {
        throw "Private or invalid path is present in the local test manifest: $RelativePath"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest path escaped its package root: $RelativePath" }
    return $full
}

$sourceRoot = [IO.Path]::GetFullPath((Get-GitText -Root $PSScriptRoot -Arguments @('rev-parse', '--show-toplevel')))
$mainRoot = Get-MainWorktreeRoot -Root $sourceRoot
$head = Get-GitText -Root $sourceRoot -Arguments @('rev-parse', 'HEAD')
$status = Get-GitText -Root $sourceRoot -Arguments @('status', '--porcelain', '--untracked-files=all')
Assert-LocalTestPackage ([string]::IsNullOrWhiteSpace($status)) 'source checkout must be clean'

$packageRoot = Join-Path $mainRoot 'build\releases\v0.1.1-test.1'
$manifestPath = Join-Path $packageRoot 'manifest.json'
$stableRoot = Join-Path $mainRoot 'build\releases\v0.1.0'
$stableManifestPath = Join-Path $stableRoot 'manifest.json'
Assert-LocalTestPackage (Test-Path -LiteralPath $packageRoot -PathType Container) 'canonical v0.1.1-test.1 directory exists'
Assert-LocalTestPackage (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'producer manifest exists in the canonical test directory'
Assert-LocalTestPackage (Test-Path -LiteralPath $stableManifestPath -PathType Leaf) 'stable v0.1.0 manifest exists'

$actualStableManifestSha256 = (Get-FileHash -LiteralPath $stableManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-LocalTestPackage ($actualStableManifestSha256 -ceq $expectedStableManifestSha256) 'raw v0.1.0 manifest bytes match the fixed audited SHA-256 before mappings are read'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$stableManifest = Get-Content -LiteralPath $stableManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-LocalTestPackage ([string]$manifest.package_kind -ceq 'wirex_bridge_local_test_directory') 'manifest identifies a local test directory'
Assert-LocalTestPackage ([string]$manifest.package_status -ceq 'local_test_only') 'manifest cannot claim root-approved stable status'
Assert-LocalTestPackage ([string]$manifest.version -ceq 'v0.1.1-test.1') 'manifest identifies the local test version'
Assert-LocalTestPackage ([string]$manifest.tag_candidate -cne 'v0.1.0' -and -not [bool]$manifest.tag_created) 'manifest has no official stable tag candidate'
Assert-LocalTestPackage (-not [bool]$manifest.github_release_published) 'manifest does not claim a GitHub Release'
Assert-LocalTestPackage ([string]$manifest.source.commit -ceq $head -and [bool]$manifest.source.working_tree_clean) 'manifest records the clean R125 source commit'
Assert-LocalTestPackage ([string]$manifest.local_test.source_commit -ceq $head -and [bool]$manifest.local_test.source_tree_clean) 'local-test provenance repeats the committed source identity'
Assert-LocalTestPackage ([string]$manifest.local_test.base_stable_tag -ceq 'v0.1.0') 'manifest identifies the stable source package'
Assert-LocalTestPackage ([string]$manifest.local_test.base_stable_manifest_sha256 -ceq $expectedStableManifestSha256) 'manifest records the fixed raw v0.1.0 manifest hash'
Assert-LocalTestPackage (@($manifest.files).Count -eq 42) 'manifest lists exactly 42 generic assets'
Assert-LocalTestPackage (@($manifest.runtime_directories).Count -eq 8) 'manifest lists the eight stable runtime directories'

$stableNativeRecord = $stableManifest.files | Where-Object { $_.path -ceq 'runtime/wirex_bridge.exe' } | Select-Object -First 1
$stableLauncherRecord = $stableManifest.files | Where-Object { $_.path -ceq 'WirexBridge.exe' } | Select-Object -First 1
Assert-LocalTestPackage ($null -ne $stableNativeRecord -and [string]$stableNativeRecord.sha256 -ceq $expectedNativeSha256) 'stable Native manifest hash matches the approved v0.1.0 hash'
Assert-LocalTestPackage ($null -ne $stableLauncherRecord -and [string]$stableLauncherRecord.sha256 -ceq $expectedLauncherSha256) 'stable launcher manifest hash matches the approved v0.1.0 hash'
$stableTemplateRecord = $stableManifest.files | Where-Object { $_.path -ceq 'runtime/private/device-y.bin' } | Select-Object -First 1
$stableTemplatePath = Join-Path $stableRoot 'runtime\private\device-y.bin'
Assert-LocalTestPackage ($null -ne $stableTemplateRecord -and [long]$stableTemplateRecord.length_bytes -eq $expectedDeviceTemplateLength -and
    [string]$stableTemplateRecord.sha256 -ceq $expectedDeviceTemplateSha256) 'stable HRI template record matches the fixed length and SHA-256'
Assert-LocalTestPackage ((Get-FileHash -LiteralPath $stableTemplatePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedDeviceTemplateSha256) 'stable HRI template bytes match the fixed approved SHA-256'
Assert-LocalTestPackage ([string]$manifest.local_test.approved_template.asset -ceq 'runtime/private/device-y.bin' -and
    [long]$manifest.local_test.approved_template.length_bytes -eq $expectedDeviceTemplateLength -and
    [string]$manifest.local_test.approved_template.sha256 -ceq $expectedDeviceTemplateSha256) 'local manifest locks the approved HRI template'
$packageTemplateRecord = $manifest.files | Where-Object { $_.path -ceq 'runtime/private/device-y.bin' } | Select-Object -First 1
Assert-LocalTestPackage ($null -ne $packageTemplateRecord -and [long]$packageTemplateRecord.length_bytes -eq $expectedDeviceTemplateLength -and
    [string]$packageTemplateRecord.sha256 -ceq $expectedDeviceTemplateSha256) 'package asset record locks the approved HRI template bytes'
Assert-LocalTestPackage ([string]$manifest.build.source_commit -ceq $stableSourceCommit -and [int]$manifest.build.passed_test_count -eq 40) 'Native build record remains tied to c12b50a and its 40 passing tests'
Assert-LocalTestPackage ([string]$manifest.launcher_build.source_commit -ceq $stableSourceCommit) 'launcher build record remains tied to c12b50a'
Assert-LocalTestPackage ([string]$manifest.local_test.binary_reuse.native.source_commit -ceq $stableSourceCommit -and
    [string]$manifest.local_test.binary_reuse.native.sha256 -ceq $expectedNativeSha256 -and
    [int]$manifest.local_test.binary_reuse.native.passed_test_count -eq 40) 'local manifest records Native reuse provenance without rewriting its build source'
Assert-LocalTestPackage ([string]$manifest.local_test.binary_reuse.launcher.source_commit -ceq $stableSourceCommit -and
    [string]$manifest.local_test.binary_reuse.launcher.sha256 -ceq $expectedLauncherSha256) 'local manifest records launcher reuse provenance'

$diffText = Get-GitText -Root $sourceRoot -Arguments @('diff', '--name-only', $stableSourceCommit, $head)
$changed = @($diffText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$protected = @($changed | Where-Object { $_ -match '^(src/|include/|third_party/|CMakeLists\.txt$|ui/windows/BridgeSupervisor\.cs$|ui/launcher/WirexBridgeLauncher\.cs$|tools/(build-native|build-launcher)\.ps1$)' })
Assert-LocalTestPackage ($protected.Count -eq 0) 'Native, third-party, BridgeSupervisor, launcher, and build inputs are unchanged from c12b50a'

$manifestPaths = @($manifest.files | ForEach-Object { [string]$_.path })
Assert-LocalTestPackage (@($manifestPaths | Select-Object -Unique).Count -eq 42) 'manifest asset paths are unique'
$actualFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -Force -Recurse)
$actualDirectories = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Force -Recurse)
$actualPaths = @($actualFiles | ForEach-Object { Get-RelativeAssetPath -Root $packageRoot -Path $_.FullName } | Sort-Object)
$expectedPaths = @($manifestPaths + 'manifest.json' | Sort-Object)
Assert-LocalTestPackage (@(Compare-Object $expectedPaths $actualPaths).Count -eq 0) 'directory contains only the 42 manifest assets and manifest.json'
$expectedDirectories = @($manifest.runtime_directories | ForEach-Object { [string]$_ } | Sort-Object)
$actualDirectoryPaths = @($actualDirectories | ForEach-Object { Get-RelativeAssetPath -Root $packageRoot -Path $_.FullName } | Sort-Object)
Assert-LocalTestPackage (@(Compare-Object $expectedDirectories $actualDirectoryPaths).Count -eq 0) 'directory layout matches the eight stable runtime directories'
Assert-LocalTestPackage (@($actualFiles | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -eq 0 -and
    @($actualDirectories | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -eq 0) 'package contains no reparse points'

$sourceMapCount = 0
$reusedCount = 0
$generatedCount = 0
$approvedCount = 0
foreach ($record in @($manifest.files)) {
    $relativePath = [string]$record.path
    $assetPath = Get-SafeAssetPath -Root $packageRoot -RelativePath $relativePath
    Assert-LocalTestPackage (Test-Path -LiteralPath $assetPath -PathType Leaf) "mapped file exists: $relativePath"
    $item = Get-Item -LiteralPath $assetPath -Force
    $hash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-LocalTestPackage ([long]$record.length_bytes -eq [long]$item.Length -and [string]$record.sha256 -ceq $hash) "manifest bytes match: $relativePath"

    $sourceMatch = [regex]::Match([string]$record.source, '^source commit ([0-9a-f]{40}): (.+)$')
    if ($sourceMatch.Success) {
        $sourceMapCount++
        Assert-LocalTestPackage ($sourceMatch.Groups[1].Value -ceq $head) "source map is tied to R125 commit: $relativePath"
        $sourceRelative = $sourceMatch.Groups[2].Value
        $sourcePath = Get-SafeAssetPath -Root $sourceRoot -RelativePath $sourceRelative
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-LocalTestPackage ($sourceHash -ceq $hash) "packaged source matches committed source: $relativePath"
    } elseif ([string]$record.source -like 'reused from stable v0.1.0*') {
        $reusedCount++
        $stablePath = Get-SafeAssetPath -Root $stableRoot -RelativePath $relativePath
        $stableHash = (Get-FileHash -LiteralPath $stablePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-LocalTestPackage ($stableHash -ceq $hash) "reused binary/provenance matches v0.1.0 bytes: $relativePath"
    } elseif ([string]$record.source -like 'generated by tools/package-local-test.ps1*') {
        $generatedCount++
        Assert-LocalTestPackage ($relativePath -ceq 'SOURCE.txt') 'only SOURCE.txt is generated by the producer'
    } elseif ([string]$record.source -like 'approved 100-byte HRI protocol template*') {
        $approvedCount++
        Assert-LocalTestPackage ($relativePath -ceq 'runtime/private/device-y.bin') 'approved protocol template retains its fixed mapping'
    } else {
        throw "Unexpected manifest source category: $relativePath"
    }
}
Assert-LocalTestPackage ($sourceMapCount -eq 36) 'all 36 whitelisted source mappings are present'
Assert-LocalTestPackage ($reusedCount -eq 4) 'four Native/launcher binary and provenance assets are reused from v0.1.0'
Assert-LocalTestPackage ($generatedCount -eq 1 -and $approvedCount -eq 1) 'generated source summary and approved protocol template each appear once'
Assert-LocalTestPackage (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'config.json'))) 'no user config is present'

$readme = Get-Content -LiteralPath (Join-Path $packageRoot 'README.md') -Raw -Encoding UTF8
Assert-LocalTestPackage ($readme.Contains('v0.1.1-test.1') -and $readme.Contains('不是正式发行版')) 'README identifies the package as a local test only'
Assert-LocalTestPackage ([string]$manifest.package_kind -cne 'wirex_bridge_stable_release_green_directory' -and
    [string]$manifest.package_status -cne 'root_audit_passed' -and
    [string]$manifest.version -cne 'v0.1.0' -and
    [string]$manifest.tag_candidate -cne 'v0.1.0') 'manifest cannot pass the formal stable publisher gate'

Write-Output ("PASS: {0} checks; validated the actual local-test producer manifest and 43-file/8-directory package. No config fields or hashes were read." -f $checkCount)
