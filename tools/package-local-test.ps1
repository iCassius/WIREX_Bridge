[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stableSourceCommit = 'c12b50a9f339417ffd49d37b7acab6057fa51bcf'
$expectedStableManifestSha256 = '1bdc80890cd8aa0b51b19c8f6385d312014b11c006b4643e2b31862cd980cc0e'
$expectedNativeSha256 = '8f629aefbaaba3b865f09b3d1cb4b012e6b1953a7ec58d340edbec460225ca32'
$expectedLauncherSha256 = 'de4d0b113cd7a25a907b3fe96a0a4b1579730c1a884175930ad6db9412b60638'
$expectedDeviceTemplateSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$expectedDeviceTemplateLength = 100
$localVersion = 'v0.1.1-test.1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
        if ($null -eq $worktreeLine) { continue }
        if ($lines -ccontains 'branch refs/heads/main') {
            $mainRoots += [IO.Path]::GetFullPath($worktreeLine.Substring(9))
        }
    }
    if ($mainRoots.Count -ne 1) { throw 'Could not identify exactly one main checkout for the canonical local test destination.' }
    return $mainRoots[0]
}

function ConvertTo-AssetFullPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.StartsWith('/') -or $RelativePath.Contains('\')) {
        throw "Asset path is not a canonical forward-slash relative path: $RelativePath"
    }
    $parts = $RelativePath.Split('/')
    if (@($parts | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "Asset path contains an invalid component: $RelativePath"
    }
    if (@($parts | Where-Object { $_ -match '^(?i:config\.json|logs?|cache|credentials?|tempsecrets?)$' }).Count -ne 0) {
        throw "Private configuration or runtime data is excluded from the local test package: $RelativePath"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $nativeRelative = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $Root $nativeRelative))
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Asset path escaped its root: $RelativePath" }
    return $full
}

function Assert-NoReparsePath {
    param([string]$Root, [string]$RelativePath)
    $current = [IO.Path]::GetFullPath($Root)
    $rootItem = Get-Item -LiteralPath $current -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Asset root is a reparse point: $Root" }
    foreach ($part in $RelativePath.Replace('\', '/').Split('/')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { throw "Required mapped file is missing: $RelativePath" }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Mapped path contains a reparse point: $RelativePath" }
    }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-VerifiedStableAsset {
    param([string]$StableRoot, [string]$TargetRoot, [object]$Record)
    $sourcePath = ConvertTo-AssetFullPath -Root $StableRoot -RelativePath ([string]$Record.path)
    Assert-NoReparsePath -Root $StableRoot -RelativePath ([string]$Record.path)
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    $sourceHash = Get-Sha256 -Path $sourcePath
    if ([long]$sourceItem.Length -ne [long]$Record.length_bytes -or $sourceHash -cne ([string]$Record.sha256).ToLowerInvariant()) {
        throw "Stable asset differs from its v0.1.0 manifest record: $($Record.path)"
    }
    $destination = ConvertTo-AssetFullPath -Root $TargetRoot -RelativePath ([string]$Record.path)
    [IO.File]::Copy($sourcePath, $destination, $false)
    return $destination
}

function Assert-SourceCommitScope {
    param([string]$Root, [string]$Head)
    & git -C $Root merge-base --is-ancestor $stableSourceCommit $Head
    if ($LASTEXITCODE -ne 0) { throw 'The R125 source commit must descend from the published c12b50a source commit.' }

    $status = Get-GitText -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'Commit the frozen R125 source tree before producing the local test directory.' }
    if ($Head -ceq $stableSourceCommit) { throw 'The source commit is still the v0.1.0 base; no R125 source changes are committed.' }

    $diffText = Get-GitText -Root $Root -Arguments @('diff', '--name-only', $stableSourceCommit, $Head)
    $changed = @($diffText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (@($changed | Where-Object { $_ -match '^(src/|include/|third_party/|CMakeLists\.txt$|ui/windows/BridgeSupervisor\.cs$|ui/launcher/WirexBridgeLauncher\.cs$|tools/(build-native|build-launcher)\.ps1$)' }).Count -ne 0) {
        throw 'Native C++, third-party code, BridgeSupervisor, launcher source, or native/launcher build scripts changed; rebuild evidence is required.'
    }
    $unsupported = @($changed | Where-Object {
        $_ -notmatch '^(ui/windows/|docs/|tests/|devtools/|HANDOFF\.md$|tools/(test-[^/]+\.ps1|devtools/|package-local-test\.ps1$|test-package-local-test\.ps1$|download-release\.ps1$|test-download-release\.ps1$))'
    })
    if ($unsupported.Count -ne 0) { throw ('Changes are outside the local UI test package scope: ' + ($unsupported -join ', ')) }
    if (@($changed | Where-Object { $_ -match '^ui/windows/' }).Count -eq 0) { throw 'No committed R125 UI source change was found.' }
    return ,$changed
}

function New-LocalTestManifest {
    param([object]$StableManifest, [string]$SourceCommit, [string[]]$ChangedPaths, [object[]]$Records)
    $copy = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $StableManifest -Depth 100)
    $copy.package_kind = 'wirex_bridge_local_test_directory'
    $copy.package_status = 'local_test_only'
    $copy.version = $localVersion
    $copy.tag_candidate = ''
    $copy.tag_created = $false
    $copy.github_release_published = $false
    $copy.source.commit = $SourceCommit
    $copy.source.working_tree_clean = $true
    $copy.release_scope = 'R125 WPF 与 PowerShell UI 本机测试目录；不是正式发行。'
    $copy.files = $Records
    $copy | Add-Member -MemberType NoteProperty -Name local_test -Value ([pscustomobject]@{
        version = $localVersion
        source_commit = $SourceCommit
        source_tree_clean = $true
        changed_paths = @($ChangedPaths)
        base_stable_tag = 'v0.1.0'
        base_stable_manifest_sha256 = $expectedStableManifestSha256
        binary_reuse = [pscustomobject]@{
            native = [pscustomobject]@{
                source_commit = $stableSourceCommit
                asset = 'runtime/wirex_bridge.exe'
                sha256 = $expectedNativeSha256
                passed_test_count = 40
                reason = 'R125 source diff leaves Native C++, third_party, BridgeSupervisor.cs, and Native build inputs unchanged.'
            }
            launcher = [pscustomobject]@{
                source_commit = $stableSourceCommit
                asset = 'WirexBridge.exe'
                sha256 = $expectedLauncherSha256
                reason = 'R125 source diff leaves the C# launcher source and launcher build inputs unchanged.'
            }
        }
        approved_template = [pscustomobject]@{
            asset = 'runtime/private/device-y.bin'
            length_bytes = $expectedDeviceTemplateLength
            sha256 = $expectedDeviceTemplateSha256
            reason = 'Fixed approved HRI protocol template from the audited v0.1.0 package.'
        }
    }) -Force
    return $copy
}

function Invoke-LocalTestPackage {
    $sourceRoot = [IO.Path]::GetFullPath((Get-GitText -Root $PSScriptRoot -Arguments @('rev-parse', '--show-toplevel')))
    $mainRoot = Get-MainWorktreeRoot -Root $sourceRoot
    $sourceCommit = Get-GitText -Root $sourceRoot -Arguments @('rev-parse', 'HEAD')
    if ($sourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'Git returned an invalid source commit.' }
    $changedPaths = Assert-SourceCommitScope -Root $sourceRoot -Head $sourceCommit

    $stableRoot = Join-Path $mainRoot 'build\releases\v0.1.0'
    $stableManifestPath = Join-Path $stableRoot 'manifest.json'
    $targetRoot = Join-Path $mainRoot 'build\releases\v0.1.1-test.1'
    if (-not (Test-Path -LiteralPath $stableManifestPath -PathType Leaf)) { throw 'The audited v0.1.0 local package manifest is missing.' }
    if (Test-Path -LiteralPath $targetRoot) { throw 'The v0.1.1-test.1 directory already exists; the local test packer never overwrites it.' }

    $actualStableManifestSha256 = Get-Sha256 -Path $stableManifestPath
    if ($actualStableManifestSha256 -cne $expectedStableManifestSha256) { throw 'The raw v0.1.0 manifest bytes differ from the fixed audited manifest SHA-256.' }
    $stableManifest = Get-Content -LiteralPath $stableManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$stableManifest.package_kind -cne 'wirex_bridge_stable_release_green_directory' -or
        [string]$stableManifest.package_status -cne 'root_audit_passed' -or
        [string]$stableManifest.version -cne 'v0.1.0' -or
        [string]$stableManifest.source.commit -cne $stableSourceCommit) {
        throw 'The local base package is not the audited v0.1.0 source package.'
    }
    if (@($stableManifest.files).Count -ne 42 -or @($stableManifest.runtime_directories).Count -ne 8) {
        throw 'The audited v0.1.0 generic layout no longer has 42 assets and 8 runtime directories.'
    }
    if (@($stableManifest.files | Where-Object { $_.path -match '(^|/)(?i:config\.json|logs?|cache|credentials?|tempsecrets?)(/|$)' }).Count -ne 0) {
        throw 'The stable whitelist contains private configuration or runtime data.'
    }
    $mappedRecords = @($stableManifest.files | Where-Object { $_.source -match '^source commit [0-9a-f]{40}: ' })
    if ($mappedRecords.Count -ne 36) { throw 'The audited v0.1.0 source map no longer contains exactly 36 source mappings.' }

    $requiredBuildPaths = @('runtime/wirex_bridge.exe', 'build-provenance.json', 'WirexBridge.exe', 'launcher-build-provenance.json')
    foreach ($path in $requiredBuildPaths) {
        if (@($stableManifest.files | Where-Object { $_.path -ceq $path }).Count -ne 1) { throw "Stable binary/provenance mapping is missing or duplicated: $path" }
    }
    if ([string]$stableManifest.build.source_commit -cne $stableSourceCommit -or
        [string]$stableManifest.build.result -cne 'passed' -or
        [int]$stableManifest.build.passed_test_count -ne 40 -or
        [string]$stableManifest.build.executable_sha256 -cne $expectedNativeSha256 -or
        [string]$stableManifest.launcher_build.source_commit -cne $stableSourceCommit -or
        [string]$stableManifest.launcher_build.executable_sha256 -cne $expectedLauncherSha256) {
        throw 'Published Native/launcher provenance differs from the fixed v0.1.0 reuse evidence.'
    }
    foreach ($path in $requiredBuildPaths + @('runtime/private/device-y.bin')) {
        $record = $stableManifest.files | Where-Object { $_.path -ceq $path } | Select-Object -First 1
        if ($path -eq 'runtime/wirex_bridge.exe' -and [string]$record.sha256 -cne $expectedNativeSha256) { throw 'Stable Native asset hash differs from its fixed reuse hash.' }
        if ($path -eq 'WirexBridge.exe' -and [string]$record.sha256 -cne $expectedLauncherSha256) { throw 'Stable launcher asset hash differs from its fixed reuse hash.' }
        if ($path -ceq 'runtime/private/device-y.bin' -and
            ([long]$record.length_bytes -ne $expectedDeviceTemplateLength -or [string]$record.sha256 -cne $expectedDeviceTemplateSha256)) {
            throw 'Approved HRI protocol template differs from its fixed length or SHA-256.'
        }
        if ($null -eq $record) { throw "Stable approved asset is missing: $path" }
        $assetPath = ConvertTo-AssetFullPath -Root $stableRoot -RelativePath $path
        Assert-NoReparsePath -Root $stableRoot -RelativePath $path
        $asset = Get-Item -LiteralPath $assetPath -Force
        if ([long]$asset.Length -ne [long]$record.length_bytes -or (Get-Sha256 -Path $assetPath) -cne ([string]$record.sha256).ToLowerInvariant()) {
            throw "Stable binary/provenance/template bytes differ from the v0.1.0 manifest: $path"
        }
    }

    $parent = Split-Path -Parent $targetRoot
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'The canonical app/build/releases directory is missing.' }
    $mainRootFull = [IO.Path]::GetFullPath($mainRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $parentResolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $parent).Path)
    if (-not $parentResolved.StartsWith($mainRootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'The canonical release parent escaped the main app checkout.' }
    $parentItem = Get-Item -LiteralPath $parentResolved -Force
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The canonical release parent is a reparse point.' }
    if ([IO.Path]::GetPathRoot($sourceRoot) -ine [IO.Path]::GetPathRoot($mainRoot)) { throw 'Source worktree and canonical app output are on different volumes.' }
    $targetRoot = [IO.Path]::GetFullPath($targetRoot)
    $canonicalTarget = [IO.Path]::GetFullPath((Join-Path $mainRoot 'build\releases\v0.1.1-test.1'))
    if ($targetRoot -cne $canonicalTarget) { throw 'The local test output escaped its single allowed directory.' }

    [void](New-Item -ItemType Directory -Path $targetRoot -ErrorAction Stop)
    foreach ($directory in @($stableManifest.runtime_directories)) {
        $directoryPath = ConvertTo-AssetFullPath -Root $targetRoot -RelativePath ([string]$directory)
        [void][IO.Directory]::CreateDirectory($directoryPath)
    }

    $newRecords = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($stableManifest.files)) {
        $path = [string]$record.path
        $destination = ConvertTo-AssetFullPath -Root $targetRoot -RelativePath $path
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { [void][IO.Directory]::CreateDirectory($destinationParent) }

        $sourceDescription = ''
        $mapping = [regex]::Match([string]$record.source, '^source commit ([0-9a-f]{40}): (.+)$')
        if ($mapping.Success) {
            $sourceRelative = [string]$mapping.Groups[2].Value
            if ($path -ceq 'README.md') { $sourceRelative = 'docs/releases/v0.1.1-test.1-local-README.md' }
            $sourcePath = ConvertTo-AssetFullPath -Root $sourceRoot -RelativePath $sourceRelative
            Assert-NoReparsePath -Root $sourceRoot -RelativePath $sourceRelative
            [IO.File]::Copy($sourcePath, $destination, $false)
            $sourceDescription = "source commit ${sourceCommit}: $sourceRelative"
        } elseif ($requiredBuildPaths -ccontains $path -or $path -ceq 'runtime/private/device-y.bin') {
            $null = Copy-VerifiedStableAsset -StableRoot $stableRoot -TargetRoot $targetRoot -Record $record
            if ($requiredBuildPaths -ccontains $path) {
                $sourceDescription = "reused from stable v0.1.0; original build source: $($record.source)"
            } else {
                $sourceDescription = [string]$record.source
            }
        } elseif ($path -ceq 'SOURCE.txt') {
            $sourceText = @(
                'WIREX Bridge v0.1.1-test.1 local test directory',
                "R125 UI source commit: $sourceCommit",
                "Base v0.1.0 manifest SHA-256: $expectedStableManifestSha256",
                "Native source/build: $stableSourceCommit; reused v0.1.0 asset SHA-256 $expectedNativeSha256; original Native tests passed: 40",
                "Launcher source/build: $stableSourceCommit; reused v0.1.0 asset SHA-256 $expectedLauncherSha256",
                "Approved HRI template SHA-256: $expectedDeviceTemplateSha256; length: $expectedDeviceTemplateLength bytes",
                'This directory is not a Git tag, GitHub Release, ZIP, or published stable package.',
                'No user configuration, credentials, logs, or caches are included.'
            ) -join "`n"
            [IO.File]::WriteAllText($destination, $sourceText + "`n", $utf8NoBom)
            $sourceDescription = 'generated by tools/package-local-test.ps1 from the committed source and v0.1.0 provenance'
        } else {
            throw "Stable mapping type is not supported by the local test packer: $path"
        }

        $outputItem = Get-Item -LiteralPath $destination -Force
        $newRecords.Add([pscustomobject][ordered]@{
            path = $path
            asset_name = [string]$record.asset_name
            length_bytes = [long]$outputItem.Length
            sha256 = Get-Sha256 -Path $destination
            source = $sourceDescription
        })
    }

    if ($newRecords.Count -ne 42) { throw 'The local test package did not produce exactly 42 mapped assets.' }
    $localManifest = New-LocalTestManifest -StableManifest $stableManifest -SourceCommit $sourceCommit -ChangedPaths $changedPaths -Records $newRecords.ToArray()
    $manifestPath = Join-Path $targetRoot 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $localManifest -Depth 100) + "`n", $utf8NoBom)

    $actualFiles = @(Get-ChildItem -LiteralPath $targetRoot -File -Force -Recurse)
    $actualDirectories = @(Get-ChildItem -LiteralPath $targetRoot -Directory -Force -Recurse)
    if ($actualFiles.Count -ne 43 -or $actualDirectories.Count -ne 8) { throw 'The local test directory inventory differs from the 43-file/8-directory contract.' }
    if (Test-Path -LiteralPath (Join-Path $targetRoot 'config.json')) { throw 'The local test package unexpectedly contains config.json.' }
    Write-Output ("Created local test directory: {0}; source={1}; assets=42; total files=43; runtime directories=8; no ZIP or GitHub Release created." -f $targetRoot, $sourceCommit)
}

Invoke-LocalTestPackage
