[CmdletBinding()]
param([switch]$SkipRepositoryGitChecks)

$ErrorActionPreference = 'Stop'
$assertions = 0
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'publish-release.ps1')
. (Join-Path $PSScriptRoot 'package-release.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $script:assertions++
    $didThrow = $false
    try { & $Action } catch { $didThrow = $true }
    if (-not $didThrow) { throw ('Expected rejection: ' + $Message) }
}

function Assert-ThrowsContaining {
    param([scriptblock]$Action,[string]$ExpectedText,[string]$Message)
    $script:assertions++
    $errorText = ''
    try { & $Action } catch { $errorText = [string]$_.Exception.Message }
    if ($errorText -notlike ('*' + $ExpectedText + '*')) {
        throw ('Expected rejection containing "' + $ExpectedText + '": ' + $Message + '; actual="' + $errorText + '"')
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Get-TestSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-StableTestChecksums {
    param([string]$DistributionDirectory)
    $zipPath = Join-Path $DistributionDirectory 'WIREX_Bridge_v0.1.0.zip'
    $manifestPath = Join-Path $DistributionDirectory 'manifest.json'
    $checksumPath = Join-Path $DistributionDirectory 'SHA256SUMS.txt'
    $text = (Get-TestSha256 -Path $zipPath) + '  WIREX_Bridge_v0.1.0.zip' + "`n" +
        (Get-TestSha256 -Path $manifestPath) + '  manifest.json' + "`n"
    Write-Utf8NoBom -Path $checksumPath -Text $text
}

function New-StableTestArchive {
    param([string]$PackageRoot,[string]$ArchivePath,[object[]]$Records)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $stream = [System.IO.File]::Open($ArchivePath,[System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        foreach ($relativePath in (@($Records | ForEach-Object { [string]$_.Path }) + 'manifest.json' | Sort-Object -CaseSensitive)) {
            $entry = $archive.CreateEntry([string]$relativePath,[System.IO.Compression.CompressionLevel]::Optimal)
            $sourcePath = Join-Path $PackageRoot ([string]$relativePath).Replace('/',[System.IO.Path]::DirectorySeparatorChar)
            $sourceStream = [System.IO.File]::OpenRead($sourcePath)
            $entryStream = $entry.Open()
            try { $sourceStream.CopyTo($entryStream) }
            finally { $entryStream.Dispose(); $sourceStream.Dispose() }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
}

function New-StableTestArchiveVariant {
    param([string]$SourcePath,[string]$DestinationPath,[string]$RenameFrom,[string]$RenameTo,
        [string]$AttributesPath,[int]$Attributes,[string]$AddEntry)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $sourceArchive = [System.IO.Compression.ZipFile]::OpenRead($SourcePath)
    $outputStream = [System.IO.File]::Open($DestinationPath,[System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $destinationArchive = $null
    try {
        $destinationArchive = [System.IO.Compression.ZipArchive]::new($outputStream,
            [System.IO.Compression.ZipArchiveMode]::Create,$false)
        foreach ($sourceEntry in $sourceArchive.Entries) {
            $targetName = if ([string]$sourceEntry.FullName -ceq $RenameFrom) { $RenameTo } else { [string]$sourceEntry.FullName }
            $targetEntry = $destinationArchive.CreateEntry($targetName,[System.IO.Compression.CompressionLevel]::Optimal)
            $targetEntry.ExternalAttributes = if ([string]$sourceEntry.FullName -ceq $AttributesPath) { $Attributes } else { [int]$sourceEntry.ExternalAttributes }
            $inputStream = $sourceEntry.Open()
            $entryStream = $targetEntry.Open()
            try { $inputStream.CopyTo($entryStream) }
            finally { $entryStream.Dispose(); $inputStream.Dispose() }
        }
        if (-not [string]::IsNullOrEmpty($AddEntry)) { [void]$destinationArchive.CreateEntry($AddEntry) }
    } finally {
        if ($null -ne $destinationArchive) { $destinationArchive.Dispose() }
        $outputStream.Dispose()
        $sourceArchive.Dispose()
    }
}

function New-StableTestDistributionVariant {
    param([string]$PackageRoot,[string]$SourceDistribution,[string]$DistributionDirectory,
        [string]$RenameFrom,[string]$RenameTo,[string]$AttributesPath,[int]$Attributes,[string]$AddEntry)
    New-Item -ItemType Directory -Path $DistributionDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDistribution 'manifest.json') `
        -Destination (Join-Path $DistributionDirectory 'manifest.json')
    New-StableTestArchiveVariant -SourcePath (Join-Path $SourceDistribution 'WIREX_Bridge_v0.1.0.zip') `
        -DestinationPath (Join-Path $DistributionDirectory 'WIREX_Bridge_v0.1.0.zip') `
        -RenameFrom $RenameFrom -RenameTo $RenameTo -AttributesPath $AttributesPath -Attributes $Attributes -AddEntry $AddEntry
    Write-StableTestChecksums -DistributionDirectory $DistributionDirectory
}

function New-SyntheticStablePublishPackage {
    param([string]$PackageRoot,[string]$DistributionDirectory,[string]$ExpectedCommit,[byte[]]$FixtureBytes,[string]$FixtureHash)
    $records = @(Get-ExpectedStablePackageRecords)
    foreach ($directory in (Get-ExpectedStablePackageDirectories)) {
        [System.IO.Directory]::CreateDirectory((Join-Path $PackageRoot ([string]$directory).Replace('/',[System.IO.Path]::DirectorySeparatorChar))) | Out-Null
    }
    foreach ($record in $records) {
        $relativePath = [string]$record.Path
        $fullPath = Join-Path $PackageRoot $relativePath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
        if ($relativePath -ceq 'runtime/private/device-y.bin') {
            [System.IO.File]::WriteAllBytes($fullPath,$FixtureBytes)
        } elseif ($relativePath -ceq 'launcher-build-provenance.json') {
            continue
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic stable package content: ' + $relativePath)
        }
    }

    $launcherPath = Join-Path $PackageRoot 'WirexBridge.exe'
    $launcherHash = Get-TestSha256 -Path $launcherPath
    $launcherLength = [long](Get-Item -LiteralPath $launcherPath).Length
    $launcherProvenance = [ordered]@{
        schema_version = 1
        result = 'passed'
        source = [ordered]@{ path='ui/launcher/WirexBridgeLauncher.cs'; commit=$ExpectedCommit }
        compiler = [ordered]@{
            command='csc.exe /nologo /target:winexe /platform:x64 /optimize+ /debug- /codepage:65001'
            target='x64 Windows GUI executable'
        }
        output = [ordered]@{ path='WirexBridge.exe'; sha256=$launcherHash; length_bytes=$launcherLength }
    }
    Write-Utf8NoBom -Path (Join-Path $PackageRoot 'launcher-build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $launcherProvenance -Depth 8) + [Environment]::NewLine)

    $fileRecords = @()
    foreach ($record in $records) {
        $relativePath = [string]$record.Path
        $fullPath = Join-Path $PackageRoot $relativePath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
        $info = Get-Item -LiteralPath $fullPath
        $fileRecords += ,([ordered]@{
            path=$relativePath; asset_name=[string]$record.AssetName; length_bytes=[long]$info.Length
            sha256=(Get-TestSha256 -Path $fullPath); source=('synthetic stable test content: ' + $relativePath)
        })
    }
    $recordByPath = @{}
    foreach ($record in $fileRecords) { $recordByPath[[string]$record.path] = $record }
    $launcherProvenanceHash = Get-TestSha256 -Path (Join-Path $PackageRoot 'launcher-build-provenance.json')
    $manifest = [ordered]@{
        schema_version = 1
        package_kind = 'wirex_bridge_stable_release_green_directory'
        package_status = 'root_audit_passed'
        version = 'v0.1.0'
        tag_candidate = 'v0.1.0'
        tag_created = $false
        github_release_published = $false
        source = [ordered]@{ repository=$script:repositoryUrl; commit=$ExpectedCommit; working_tree_clean=$true }
        build = [ordered]@{
            source_commit=$ExpectedCommit; source_tree_clean=$true; compile_only=$false
            build_completed=$true; result='passed'; passed_test_count=$script:expectedTestNames.Count
            passed_tests=@($script:expectedTestNames)
        }
        approved_y_fixture = [ordered]@{ path='runtime/private/device-y.bin'; length_bytes=100; sha256=$FixtureHash }
        launcher_build = [ordered]@{
            executable_sha256=[string]$recordByPath['WirexBridge.exe'].sha256
            provenance_sha256=$launcherProvenanceHash
        }
        files = @($fileRecords)
    }
    $packageManifestPath = Join-Path $PackageRoot 'manifest.json'
    Write-Utf8NoBom -Path $packageManifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + [Environment]::NewLine)

    [System.IO.Directory]::CreateDirectory($DistributionDirectory) | Out-Null
    New-StableTestArchive -PackageRoot $PackageRoot `
        -ArchivePath (Join-Path $DistributionDirectory 'WIREX_Bridge_v0.1.0.zip') -Records $records
    [System.IO.File]::WriteAllBytes((Join-Path $DistributionDirectory 'manifest.json'),[System.IO.File]::ReadAllBytes($packageManifestPath))
    Write-StableTestChecksums -DistributionDirectory $DistributionDirectory
    return [pscustomobject]@{ Records=$records; Manifest=$manifest; PackageRoot=$PackageRoot; DistributionDirectory=$DistributionDirectory }
}

$testRoot = Join-Path $repositoryRoot ('build/_work/publish-release-test-' + [guid]::NewGuid().ToString('N'))
$fakeCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$fixtureBytes = New-Object byte[] 100
$fixtureHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($fixtureBytes))).Replace('-', '').ToLowerInvariant()
$script:approvedFixtureSha256 = $fixtureHash

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Assert-True ($script:publishTag -ceq 'v0.1.0' -and -not $script:publishIsPrerelease) `
        'publisher defaults to the stable v0.1.0 profile when dot-sourced'
    foreach ($retiredTag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.19')) {
        Assert-ThrowsContaining { Set-PublishProfile -Tag $retiredTag } 'Only registered v0.1.0, v0.1.1-test.2, and v0.1.1 profiles' `
            ('retired alpha publish profile is rejected: ' + $retiredTag)
    }
    Assert-Throws { Assert-PublishPackage -PackageRoot $testRoot -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.19' } `
        'Assert-PublishPackage rejects a retired alpha tag'
    Assert-True (@((Set-PublishProfile -Tag 'v0.1.0').TestNames).Count -eq 40 -and
        ([string]::Join('|', @((Set-PublishProfile -Tag 'v0.1.0').TestNames)) + '|engine_test|hri_y_body_test|gui_hri_diagnostics_test') -ceq
        [string]::Join('|', @((Set-PublishProfile -Tag 'v0.1.1').TestNames))) `
        'v0.1.0 keeps the fixed 40-test inventory; v0.1.1 appends engine_test, hri_y_body_test and gui_hri_diagnostics_test'

    $stablePublishProfile = Set-PublishProfile -Tag 'v0.1.0'
    $stableRecords = @(Get-ExpectedStablePackageRecords)
    $expectedStableDirectories = @('runtime','runtime/docs','runtime/licenses','runtime/licenses/dmr_signal',
        'runtime/licenses/droidstar_mbe','runtime/private','runtime/ui','runtime/ui/windows')
    Assert-True (-not $script:publishIsPrerelease -and $stablePublishProfile.AssetPathMap.Count -eq 3 -and
        $stablePublishProfile.AssetPathMap.Contains('WIREX_Bridge_v0.1.0.zip') -and
        $stablePublishProfile.AssetPathMap.Contains('manifest.json') -and
        $stablePublishProfile.AssetPathMap.Contains('SHA256SUMS.txt')) `
        'v0.1.0 publisher uses prerelease=false and exactly ZIP, manifest, and checksum assets'
    $r126TestProfile = Set-PublishProfile -Tag 'v0.1.1-test.2'
    Assert-True ($script:publishIsPrerelease -and $r126TestProfile.AssetPathMap.Count -eq 1 -and
        $r126TestProfile.AssetPathMap.Contains('WIREX_Bridge_v0.1.1-test.2.zip') -and
        $r126TestProfile.Directories.Count -eq 7 -and $r126TestProfile.TestNames.Count -eq 43) `
        'v0.1.1-test.2 publisher profile uploads only its ZIP as a prerelease'
    $r126StableProfile = Set-PublishProfile -Tag 'v0.1.1'
    Assert-True (-not $script:publishIsPrerelease -and $r126StableProfile.AssetPathMap.Count -eq 1 -and
        $r126StableProfile.AssetPathMap.Contains('WIREX_Bridge_v0.1.1.zip') -and
        $r126StableProfile.TestNames.Count -eq 43) `
        'v0.1.1 publisher profile uploads only its ZIP as a stable release'
    Assert-True (@($stableRecords | ForEach-Object { [string]$_.Path } | Sort-Object -Unique).Count -eq $stableRecords.Count -and
        @($stableRecords | Where-Object { [string]$_.Path -ceq 'runtime/ui/windows/ChannelActivationState.psm1' -and
            [string]$_.AssetName -ceq 'runtime__ui__windows__channel-activation-state.psm1' }).Count -eq 1 -and
        $stablePublishProfile.Directories.Count -eq 8 -and
        [string]::Join('|', @($stablePublishProfile.Directories | Sort-Object -CaseSensitive)) -ceq
            [string]::Join('|', @($expectedStableDirectories | Sort-Object -CaseSensitive))) `
        'stable publisher inventory includes the new runtime module and exact eight-directory tree without runtime/tools'

    # v0.1.1 profile 追加了新测试；构造 v0.1.0 合成包前切回 v0.1.0 的 40 项清单。
    [void](Set-PublishProfile -Tag 'v0.1.0')
    $stablePackageRoot = Join-Path $testRoot 'package-stable'
    $stableDistributionRoot = Join-Path $testRoot 'distribution-stable'
    $stableFixture = New-SyntheticStablePublishPackage -PackageRoot $stablePackageRoot `
        -DistributionDirectory $stableDistributionRoot -ExpectedCommit $fakeCommit -FixtureBytes $fixtureBytes -FixtureHash $fixtureHash
    $stableDirectResult = Assert-StablePublishPackage -PackageRoot $stablePackageRoot `
        -ExpectedCommit $fakeCommit -DistributionDirectory $stableDistributionRoot
    $stableWrapperResult = Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -Tag 'v0.1.0' -DistributionDirectory $stableDistributionRoot
    Assert-True ($stableDirectResult.Assets.Count -eq 3 -and $stableWrapperResult.Assets.Count -eq 3 -and
        $stableDirectResult.Manifest.files.Count -eq 42 -and $stableWrapperResult.Manifest.version -ceq 'v0.1.0') `
        'production stable validator and production tag dispatcher accept a complete 42-file candidate, matching ZIP, manifest, and checksums'
    $stableAssetNames = @($stableWrapperResult.Assets | ForEach-Object { [string]$_.Name })
    Assert-True ($stableAssetNames.Count -eq 3 -and
        @($stableAssetNames | Where-Object { $_ -ceq 'WIREX_Bridge_v0.1.0.zip' }).Count -eq 1 -and
        @($stableAssetNames | Where-Object { $_ -ceq 'manifest.json' }).Count -eq 1 -and
        @($stableAssetNames | Where-Object { $_ -ceq 'SHA256SUMS.txt' }).Count -eq 1) `
        'stable production validator returns exactly the three approved distribution assets'
    Assert-True ((Test-WirexStableRegularZipEntry -ExternalAttributes 0 -Length 0) -and
        (Test-WirexStableRegularZipEntry -ExternalAttributes ([int](0x8000 -shl 16)) -Length 1)) `
        'shared ZIP type check accepts regular Unix type zero and regular Unix file entries'

    $stableLimits = Get-WirexStableReleaseLimits
    $stableZipMaximum = [long]$stableLimits.MaximumArchiveBytes
    $stableTotalMaximum = [long]$stableLimits.MaximumUncompressedBytes
    $stableFileMaximum = [long](Get-WirexStableMaximumFileBytes -Path 'WirexBridge.exe')
    $stableManifestMaximum = [long]$stableLimits.MaximumManifestBytes
    Assert-True ((Test-WirexStableLengthWithinLimit -Length $stableZipMaximum -MaximumBytes $stableZipMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($stableZipMaximum + 1) -MaximumBytes $stableZipMaximum)) `
        'shared publisher size check accepts 512 MiB ZIP boundary and rejects the next byte without creating a huge archive'
    Assert-True ((Test-WirexStableLengthWithinLimit -Length $stableTotalMaximum -MaximumBytes $stableTotalMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($stableTotalMaximum + 1) -MaximumBytes $stableTotalMaximum)) `
        'shared publisher size check accepts the 2 GiB uncompressed boundary and rejects the next byte without large files'
    Assert-True ((Test-WirexStableLengthWithinLimit -Length $stableFileMaximum -MaximumBytes $stableFileMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($stableFileMaximum + 1) -MaximumBytes $stableFileMaximum)) `
        'shared publisher size check rejects the first byte above the launcher per-file cap'
    Assert-True ((Test-WirexStableLengthWithinLimit -Length $stableManifestMaximum -MaximumBytes $stableManifestMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($stableManifestMaximum + 1) -MaximumBytes $stableManifestMaximum)) `
        'shared publisher size check rejects the first byte above the manifest cap'

    $stablePackageManifestPath = Join-Path $stablePackageRoot 'manifest.json'
    $stableDistributionManifestPath = Join-Path $stableDistributionRoot 'manifest.json'
    $stableChecksumPath = Join-Path $stableDistributionRoot 'SHA256SUMS.txt'
    $stablePackageManifestBytes = [System.IO.File]::ReadAllBytes($stablePackageManifestPath)
    $stableDistributionManifestBytes = [System.IO.File]::ReadAllBytes($stableDistributionManifestPath)
    $stableChecksumBytes = [System.IO.File]::ReadAllBytes($stableChecksumPath)
    Remove-Item -LiteralPath $stablePackageManifestPath -Force
    try {
        Assert-ThrowsContaining { Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -Tag 'v0.1.0' -DistributionDirectory $stableDistributionRoot } 'Stable manifest.json is invalid.' `
            'stable publisher rejects a missing candidate manifest before producing assets'
    } finally { [System.IO.File]::WriteAllBytes($stablePackageManifestPath,$stablePackageManifestBytes) }
    Remove-Item -LiteralPath $stableDistributionManifestPath -Force
    try {
        Assert-ThrowsContaining { Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -Tag 'v0.1.0' -DistributionDirectory $stableDistributionRoot } `
            'Stable distribution directory must contain exactly' 'stable publisher rejects a missing distribution manifest'
    } finally { [System.IO.File]::WriteAllBytes($stableDistributionManifestPath,$stableDistributionManifestBytes) }
    Remove-Item -LiteralPath $stableChecksumPath -Force
    try {
        Assert-ThrowsContaining { Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -DistributionDirectory $stableDistributionRoot } 'Stable distribution ZIP and SHA256SUMS.txt are missing.' `
            'stable validator rejects a missing SHA256SUMS.txt before hashing or returning assets'
    } finally { [System.IO.File]::WriteAllBytes($stableChecksumPath,$stableChecksumBytes) }
    Write-Utf8NoBom -Path $stableChecksumPath -Text 'tampered checksum file'
    try {
        Assert-ThrowsContaining { Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -Tag 'v0.1.0' -DistributionDirectory $stableDistributionRoot } 'Stable SHA256SUMS.txt does not match' `
            'stable publisher rejects changed checksum bytes after loading the distribution'
    } finally { [System.IO.File]::WriteAllBytes($stableChecksumPath,$stableChecksumBytes) }
    Write-Utf8NoBom -Path $stableDistributionManifestPath -Text '{"tampered":true}'
    try {
        Assert-ThrowsContaining { Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -Tag 'v0.1.0' -DistributionDirectory $stableDistributionRoot } `
            'Stable distribution manifest.json differs from the audited candidate.' `
            'stable publisher rejects changed distribution manifest bytes after exact folder validation'
    } finally { [System.IO.File]::WriteAllBytes($stableDistributionManifestPath,$stableDistributionManifestBytes) }

    $stableReadmePath = Join-Path $stablePackageRoot 'README.md'
    $stableReadmeText = [System.IO.File]::ReadAllText($stableReadmePath,[System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $stableReadmePath -Text 'tampered stable package bytes'
    try {
        Assert-ThrowsContaining { Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -DistributionDirectory $stableDistributionRoot } 'A stable package file does not match its manifest length and SHA-256.' `
            'stable validator rejects a file that no longer matches the manifest hash'
    } finally { Write-Utf8NoBom -Path $stableReadmePath -Text $stableReadmeText }

    $stableVariantRoot = Join-Path $testRoot 'distribution-case-variant'
    New-StableTestDistributionVariant -PackageRoot $stablePackageRoot -SourceDistribution $stableDistributionRoot `
        -DistributionDirectory $stableVariantRoot -RenameFrom 'WirexBridge.exe' -RenameTo 'wirexbridge.exe' `
        -AttributesPath '' -Attributes 0 -AddEntry ''
    Assert-ThrowsContaining { Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -Tag 'v0.1.0' -DistributionDirectory $stableVariantRoot } 'Stable archive path does not use its canonical spelling.' `
        'stable publisher rejects one ZIP path whose case differs from canonical WirexBridge.exe spelling'

    $stableDuplicateRoot = Join-Path $testRoot 'distribution-duplicate-entry'
    New-StableTestDistributionVariant -PackageRoot $stablePackageRoot -SourceDistribution $stableDistributionRoot `
        -DistributionDirectory $stableDuplicateRoot -RenameFrom '' -RenameTo '' -AttributesPath '' -Attributes 0 -AddEntry 'WirexBridge.exe'
    Assert-ThrowsContaining { Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -DistributionDirectory $stableDuplicateRoot } 'Stable ZIP contains an unexpected or case-insensitive duplicate path.' `
        'stable validator rejects a repeated ZIP path using OrdinalIgnoreCase duplicate tracking'

    foreach ($typeCase in @(
        [pscustomobject]@{ Name='symlink'; Attributes=([int](0xa000 -shl 16)) },
        [pscustomobject]@{ Name='fifo'; Attributes=([int](0x1000 -shl 16)) },
        [pscustomobject]@{ Name='character-device'; Attributes=([int](0x2000 -shl 16)) },
        [pscustomobject]@{ Name='block-device'; Attributes=([int](0x6000 -shl 16)) },
        [pscustomobject]@{ Name='socket'; Attributes=([int](0xc000 -shl 16)) },
        [pscustomobject]@{ Name='directory'; Attributes=([int](0x4000 -shl 16)) },
        [pscustomobject]@{ Name='dos-directory-bit'; Attributes=0x10 }
    )) {
        $stableTypeDirectory = Join-Path $testRoot ('distribution-type-' + [string]$typeCase.Name)
        New-StableTestDistributionVariant -PackageRoot $stablePackageRoot -SourceDistribution $stableDistributionRoot `
            -DistributionDirectory $stableTypeDirectory -RenameFrom '' -RenameTo '' -AttributesPath 'WirexBridge.exe' `
            -Attributes ([int]$typeCase.Attributes) -AddEntry ''
        Assert-ThrowsContaining { Assert-PublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
            -Tag 'v0.1.0' -DistributionDirectory $stableTypeDirectory } 'Stable ZIP contains a non-regular file entry.' `
            ('stable publisher rejects ZIP entry type ' + [string]$typeCase.Name)
    }

    [void](Set-PublishProfile -Tag 'v0.1.0')
    $manifest = [System.IO.File]::ReadAllText($stablePackageManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    if (-not $SkipRepositoryGitChecks) {
        $realTagObject = 'refs/tags/v0.1.0^{commit}'
        $realTagCommit = Get-GitText -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', '--verify', $realTagObject)
        $realNotesPath = Join-Path $repositoryRoot 'docs/releases/v0.1.0.md'
        $realNotes = Get-PublishNotes -Path $realNotesPath -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit
        Assert-True (-not [string]::IsNullOrWhiteSpace($realNotes)) 'fixed release notes match both the real tag commit and current HEAD'
        Assert-Throws { Get-PublishNotes -Path (Join-Path $repositoryRoot 'README.md') -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit } 'non-release notes path is rejected'
    }
    $manifest.package_status = 'awaiting_root_audit'
    Write-Utf8NoBom -Path $stablePackageManifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -DistributionDirectory $stableDistributionRoot } 'unapproved package status'
    [System.IO.File]::WriteAllBytes($stablePackageManifestPath,$stablePackageManifestBytes)

    $extraPath = Join-Path $stablePackageRoot 'connection-profile.json'
    Write-Utf8NoBom -Path $extraPath -Text '{}'
    Assert-Throws { Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -DistributionDirectory $stableDistributionRoot } 'unexpected private configuration file'
    Remove-Item -LiteralPath $extraPath -Force

    $manifest = [System.IO.File]::ReadAllText($stablePackageManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $record = @($manifest.files | Where-Object { [string]$_.path -ceq 'WirexBridge.exe' })[0]
    $record.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $stablePackageManifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -DistributionDirectory $stableDistributionRoot } 'duplicate asset name'
    [System.IO.File]::WriteAllBytes($stablePackageManifestPath,$stablePackageManifestBytes)
    Assert-True ($null -ne (Assert-StablePublishPackage -PackageRoot $stablePackageRoot -ExpectedCommit $fakeCommit `
        -DistributionDirectory $stableDistributionRoot)) 'stable candidate is accepted again after restoring the audited manifest bytes'

    $unknown = New-UnknownOutcomeError
    Assert-True (Test-UnknownOutcomeError -Exception $unknown) 'mutation recovery recognizes unknown outcomes'
    Assert-True (-not (Test-UnknownOutcomeError -Exception (New-Object System.Exception('known failure')))) 'known API failures are not treated as unknown outcomes'

    $streamBytes = [System.Text.Encoding]::UTF8.GetBytes('synthetic release asset')
    $streamHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($streamBytes))).Replace('-', '').ToLowerInvariant()
    $memoryStream = [System.IO.MemoryStream]::new($streamBytes)
    try { Assert-True ((Get-StreamSha256 -Stream $memoryStream -ExpectedLength $streamBytes.Length) -ceq $streamHash) 'asset stream hash and byte count match' }
    finally { $memoryStream.Dispose() }
    $shortStream = [System.IO.MemoryStream]::new($streamBytes)
    try { Assert-Throws { Get-StreamSha256 -Stream $shortStream -ExpectedLength ($streamBytes.Length - 1) } 'oversized asset stream is rejected' }
    finally { $shortStream.Dispose() }
    $localAsset = [pscustomobject]@{ Name='one.bin'; Length=$streamBytes.Length; Sha256=$streamHash }
    $remoteAsset = [pscustomobject]@{ name='one.bin'; size=$streamBytes.Length; digest=('sha256:' + $streamHash) }
    Assert-True (Test-RemoteAssetMatches -RemoteAsset $remoteAsset -LocalAsset $localAsset) 'GitHub SHA-256 digest matches local asset'
    $remoteAsset.digest = 'sha256:' + ('0' * 64)
    Assert-True (-not (Test-RemoteAssetMatches -RemoteAsset $remoteAsset -LocalAsset $localAsset)) 'different GitHub SHA-256 digest is rejected'
    $remoteAsset.digest = 'sha256:' + $streamHash
    $expectedRemote = @([pscustomobject]@{ Name='one.bin' }, [pscustomobject]@{ Name='two.bin' })
    $actualRemote = @([pscustomobject]@{ name='one.bin' }, [pscustomobject]@{ name='two.bin' })
    Assert-True ((Assert-ExactRemoteAssetNames -RemoteAssets $actualRemote -ExpectedAssets $expectedRemote) -eq $null) 'fixed remote asset inventory is accepted'
    Assert-Throws { Assert-ExactRemoteAssetNames -RemoteAssets ($actualRemote + [pscustomobject]@{ name='extra.bin' }) -ExpectedAssets $expectedRemote } 'extra remote asset is rejected'

    $httpClients = New-PublishHttpClients
    try {
        Assert-True ($httpClients.Authenticated -is [System.Net.Http.HttpClient]) 'HTTP client construction works without using a network'
        Assert-True ($null -eq $httpClients.Authenticated.DefaultRequestHeaders.Authorization) 'HTTP client has no credential before runtime initialization'
    } finally {
        $httpClients.Authenticated.Dispose()
        $httpClients.Anonymous.Dispose()
    }
    foreach ($cdnHost in @('release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com')) {
        Assert-True (Test-AllowedReleaseAssetHost -HostName $cdnHost) "known GitHub asset host is accepted: $cdnHost"
    }
    Assert-True (-not (Test-AllowedReleaseAssetHost -HostName 'other.githubusercontent.com')) 'unlisted githubusercontent.com host is rejected'

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'publish-release.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) 'publisher script parses without errors'

    [void](Set-PublishProfile -Tag 'v0.1.1-test.2')
    $mockDraft = [pscustomobject]@{
        id = 77
        tag_name = 'v0.1.1-test.2'
        target_commitish = $fakeCommit
        body = "release notes`n"
        draft = $true
        prerelease = $true
    }
    $script:mockReleases = @($mockDraft)
    $script:mockCalls = New-Object System.Collections.ArrayList
    function Send-GitHubRequest {
        param([string]$Method, [string]$Uri, [System.Net.Http.HttpContent]$Content=$null, [switch]$AllowNotFound)
        [void]$script:mockCalls.Add([pscustomobject]@{ Method=$Method; Uri=$Uri })
        if ($Method -ceq 'GET' -and $Uri.Contains('/releases/tags/')) { return [pscustomobject]@{ Status=404; Data=$null } }
        if ($Method -ceq 'GET' -and $Uri.Contains('/releases?per_page=')) { return [pscustomobject]@{ Status=200; Data=@($script:mockReleases) } }
        if ($Method -ceq 'POST' -and $Uri.EndsWith('/releases')) { throw (New-UnknownOutcomeError) }
        throw 'Unexpected mocked request.'
    }
    $recovered = New-DraftRelease -ExpectedCommit $fakeCommit -Notes "release notes`n"
    Assert-True ([long]$recovered.id -eq 77) 'by-tag 404 falls back to the release list and recovers the existing draft'
    Assert-True (@($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count -eq 1) 'unknown POST is not repeated after recovering the draft'
    $script:mockReleases = @($mockDraft, $mockDraft)
    Assert-Throws { Get-ReleaseByTag } 'multiple exact-tag entries in release list are rejected'
    $inconsistentDraft = [pscustomobject]@{
        id = 78
        tag_name = 'v0.1.1-test.2'
        target_commitish = ('b' * 40)
        body = "release notes`n"
        draft = $true
        prerelease = $true
    }
    $script:mockReleases = @($inconsistentDraft)
    $postsBeforeMismatch = @($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count
    Assert-Throws { New-DraftRelease -ExpectedCommit $fakeCommit -Notes "release notes`n" } 'inconsistent draft recovered after unknown POST is rejected'
    Assert-True (@($script:mockCalls | Where-Object { $_.Method -ceq 'POST' }).Count -eq ($postsBeforeMismatch + 1)) 'inconsistent recovery does not cause a second POST'
    Assert-True ((Get-PublishReleaseAction -Release $mockDraft -ExpectedCommit $fakeCommit -Notes "release notes`n") -ceq 'publish') 'matching draft is eligible for the single publish patch'
    $alreadyPublished = $mockDraft | Select-Object *
    $alreadyPublished.draft = $false
    Assert-True ((Get-PublishReleaseAction -Release $alreadyPublished -ExpectedCommit $fakeCommit -Notes "release notes`n") -ceq 'already-published') 'matching published prerelease is an idempotent completion'
    $alreadyPublished.prerelease = $false
    Assert-Throws { Get-PublishReleaseAction -Release $alreadyPublished -ExpectedCommit $fakeCommit -Notes "release notes`n" } 'stable release is rejected'
    foreach ($badMode in @('draft', 'PUBLISH', 'DrAfT')) {
        $modeError = ''
        try {
            Invoke-ReleasePublisher -PackagePath '' -Commit $fakeCommit -NotesFile '' -PublisherMode $badMode -RepositoryRoot ''
        } catch { $modeError = $_.Exception.Message }
        Assert-True ($modeError -ceq 'Mode must be exactly Draft or Publish.') "mode spelling '$badMode' is rejected before local validation or credentials"
    }
    Assert-True ($script:mockCalls.Count -eq 8) 'invalid mode spellings do not issue mocked GitHub requests'

    $script:approvedFixtureSha256 = $fixtureHash
    $preflightRepo = Join-Path $testRoot 'preflight-repo'
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'docs/releases') -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $preflightRepo 'docs/releases/v0.1.0.md') -Text ("Synthetic offline release notes for v0.1.0`n")
    $gitInit = @(& git -C $preflightRepo init --quiet 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the temporary offline Git repository.' }
    foreach ($gitSetting in @(
        @('config', 'user.name', 'WIREX Offline Test'),
        @('config', 'user.email', 'wirex-offline-test@example.invalid'),
        @('remote', 'add', 'origin', $script:repositoryUrl),
        @('add', '--', 'docs/releases/v0.1.0.md'),
        @('commit', '--quiet', '-m', 'offline publisher preflight fixture')
    )) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $gitOutput = @(& git -C $preflightRepo @gitSetting 2>$null)
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the temporary offline Git repository.' }
    }
    $preflightCommit = [string](@(& git -C $preflightRepo rev-parse HEAD 2>$null)[0]).Trim()
    if ($LASTEXITCODE -ne 0 -or $preflightCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Could not identify the temporary offline commit.' }
    [void](Set-PublishProfile -Tag 'v0.1.0')
    $preflightPackage = Join-Path $preflightRepo 'build/releases/v0.1.0'
    $preflightDistribution = Join-Path $preflightRepo 'build/_work/r124-distribution/v0.1.0'
    [void](New-SyntheticStablePublishPackage -PackageRoot $preflightPackage -DistributionDirectory $preflightDistribution `
        -ExpectedCommit $preflightCommit -FixtureBytes $fixtureBytes -FixtureHash $fixtureHash)

    $script:preflightBoundaryReached = $false
    $script:credentialAttempted = $false
    function Initialize-GitHubClient {
        $script:preflightBoundaryReached = $true
        throw 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY'
    }
    function Get-GitCredentialToken {
        $script:credentialAttempted = $true
        throw 'OFFLINE_TEST_CREDENTIAL_ACCESS_BLOCKED'
    }
    $boundaryMessage = ''
    try {
        Invoke-ReleasePublisher -PackagePath $preflightPackage -Commit $preflightCommit `
            -NotesFile (Join-Path $preflightRepo 'docs/releases/v0.1.0.md') `
            -PublisherMode 'Draft' -RepositoryRoot $preflightRepo -Tag 'v0.1.0'
    } catch { $boundaryMessage = $_.Exception.Message }
    Assert-True ($script:preflightBoundaryReached -and $boundaryMessage -ceq 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY') `
        ('v0.1.0 clean dry stable package, distribution and notes preflight reaches the mocked network boundary; local result=' + $boundaryMessage)
    Assert-True (-not $script:credentialAttempted -and $script:mockCalls.Count -eq 8) 'clean dry preflight stops before credentials and API requests'

    $gitEvidence = if ($SkipRepositoryGitChecks) { 'repository Git checks skipped' } else { 'repository Git checks passed' }
    Write-Output ('Publisher offline assertions passed: ' + $script:assertions + '; ' + $gitEvidence + '; no network requests or credentials were used.')
} finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PublishPathWithin -Path $testRoot -Directory (Join-Path $repositoryRoot 'build/_work')) -and
        [System.IO.Path]::GetFileName($testRoot) -match '^publish-release-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
