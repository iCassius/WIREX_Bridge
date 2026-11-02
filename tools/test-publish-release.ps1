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
$packageRoot = Join-Path $testRoot 'package'
$fakeCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$fixtureBytes = New-Object byte[] 100
$fixtureHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($fixtureBytes))).Replace('-', '').ToLowerInvariant()
$script:approvedFixtureSha256 = $fixtureHash

try {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($directory in $script:expectedDirectories) {
        New-Item -ItemType Directory -Path (Join-Path $packageRoot $directory.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) -Force | Out-Null
    }

    $records = @()
    foreach ($path in $script:assetPathMap.Keys) {
        $fullPath = Join-Path $packageRoot $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if ($path -ceq 'private/device-y.bin') {
            [System.IO.File]::WriteAllBytes($fullPath, $fixtureBytes)
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic package content: ' + $path)
        }
        $item = Get-Item -LiteralPath $fullPath
        $records += ,([ordered]@{
            path = $path
            asset_name = (Get-PublishAssetName -RelativePath $path)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $manifest = [ordered]@{
        schema_version = 1
        package_kind = 'wirex_bridge_private_alpha_release_green_directory'
        package_status = 'root_audit_passed'
        version = 'v0.1.0-alpha.1'
        tag_candidate = 'v0.1.0-alpha.1'
        manifest_asset_name = 'manifest.json'
        source = [ordered]@{
            repository = $script:repositoryUrl
            commit = $fakeCommit
            working_tree_clean = $true
        }
        build = [ordered]@{
            source_commit = $fakeCommit
            source_tree_clean = $true
            compile_only = $false
            build_completed = $true
            result = 'passed'
            passed_test_count = $script:expectedTestNames.Count
            passed_tests = @($script:expectedTestNames)
        }
        approved_y_fixture = [ordered]@{
            path = 'private/device-y.bin'
            length_bytes = 100
            sha256 = $fixtureHash
        }
        files = $records
    }
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $validManifestJson = ConvertTo-Json -InputObject $manifest -Depth 12
    Write-Utf8NoBom -Path $manifestPath -Text ($validManifestJson + "`n")

    $valid = Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit
    Assert-True ($valid.Assets.Count -eq 17) '16 package files plus standalone manifest are accepted'
    Assert-True (@($valid.Assets | Where-Object { $_.Name -ceq 'manifest.json' }).Count -eq 1) 'manifest is a separate release asset'
    Assert-True ((Get-PublishAssetName -RelativePath 'docs/连接配置.md') -ceq 'docs__connection-profile.md') 'PowerShell reads the Chinese connection-profile path correctly'
    Assert-True ((Get-PublishAssetName -RelativePath 'docs/音量调节.md') -ceq 'docs__audio-gain.md') 'PowerShell reads the Chinese audio-settings path correctly'

    $alpha2Root = Join-Path $testRoot 'package-alpha2'
    Copy-Item -LiteralPath $packageRoot -Destination $alpha2Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.2')
    $alpha2ExtraPaths = @(
        'start-user-config.cmd', 'start-user-config.ps1', 'bridge-user-config.psm1', 'start-ui.cmd', 'start-ui.ps1',
        'docs/配置与桌面操作.md', 'ui/windows/bridge-ui.ps1', 'ui/windows/BridgeSupervisor.cs',
        'ui/windows/MainWindow.xaml', 'ui/windows/SettingsWindow.xaml'
    )
    foreach ($relativePath in $alpha2ExtraPaths) {
        $fullPath = Join-Path $alpha2Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.2 package content: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $manifest.version = 'v0.1.0-alpha.2'
    $manifest.tag_candidate = 'v0.1.0-alpha.2'
    $manifest.build.passed_test_count = $script:expectedTestNames.Count
    $manifest.build.passed_tests = @($script:expectedTestNames)
    $alpha2ManifestPath = Join-Path $alpha2Root 'manifest.json'
    $validAlpha2ManifestJson = ConvertTo-Json -InputObject $manifest -Depth 12
    Write-Utf8NoBom -Path $alpha2ManifestPath -Text ($validAlpha2ManifestJson + "`n")
    $alpha2Package = Assert-PublishPackage -PackageRoot $alpha2Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.2'
    Assert-True ($alpha2Package.Assets.Count -eq 27) 'alpha.2 package accepts 26 files plus standalone manifest'
    Assert-True (@($alpha2Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__SettingsWindow.xaml' }).Count -eq 1) 'alpha.2 UI asset mapping is fixed'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha2Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.1' } 'alpha.2 package cannot pass the alpha.1 profile'

    $alpha3Root = Join-Path $testRoot 'package-alpha3'
    Copy-Item -LiteralPath $alpha2Root -Destination $alpha3Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.3')
    $alpha3IdentityPath = Join-Path $alpha3Root 'docs\BM来话身份显示.md'
    Write-Utf8NoBom -Path $alpha3IdentityPath -Text 'synthetic alpha.3 identity guide'
    $alpha3IdentityItem = Get-Item -LiteralPath $alpha3IdentityPath
    $alpha3ManifestPath = Join-Path $alpha3Root 'manifest.json'
    $alpha3Manifest = [System.IO.File]::ReadAllText($alpha3ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha3Manifest.files += ,([ordered]@{
        path = 'docs/BM来话身份显示.md'
        asset_name = (Get-PublishAssetName -RelativePath 'docs/BM来话身份显示.md')
        length_bytes = [long]$alpha3IdentityItem.Length
        sha256 = (Get-FileHash -LiteralPath $alpha3IdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic test content'
    })
    $alpha3Manifest.version = 'v0.1.0-alpha.3'
    $alpha3Manifest.tag_candidate = 'v0.1.0-alpha.3'
    $alpha3Manifest.build.passed_test_count = $script:expectedTestNames.Count
    $alpha3Manifest.build.passed_tests = @($script:expectedTestNames)
    Write-Utf8NoBom -Path $alpha3ManifestPath -Text ((ConvertTo-Json -InputObject $alpha3Manifest -Depth 12) + "`n")
    $alpha3Package = Assert-PublishPackage -PackageRoot $alpha3Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.3'
    Assert-True ($alpha3Package.Assets.Count -eq 28) 'alpha.3 package accepts 27 files plus standalone manifest'
    Assert-True (@($alpha3Package.Assets | Where-Object { $_.Name -ceq 'docs__bm-call-identity.md' }).Count -eq 1) `
        'alpha.3 identity guide asset mapping is fixed'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha3Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.2' } `
        'alpha.3 package cannot pass the alpha.2 profile'
    $validAlpha3ManifestJson = [System.IO.File]::ReadAllText($alpha3ManifestPath, [System.Text.Encoding]::UTF8)
    $alpha4Root = Join-Path $testRoot 'package-alpha4'
    Copy-Item -LiteralPath $alpha3Root -Destination $alpha4Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.4')
    $alpha4ManifestPath = Join-Path $alpha4Root 'manifest.json'
    $alpha4ReadmePath = Join-Path $alpha4Root 'README.md'
    Write-Utf8NoBom -Path $alpha4ReadmePath -Text 'synthetic alpha.4 package README'
    $alpha4Manifest = [System.IO.File]::ReadAllText($alpha4ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha4ReadmeItem = Get-Item -LiteralPath $alpha4ReadmePath
    $alpha4ReadmeRecord = @($alpha4Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha4ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.3 manifest must contain one README record.' }
    $alpha4ReadmeRecord[0].length_bytes = [long]$alpha4ReadmeItem.Length
    $alpha4ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha4ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $alpha4Manifest.version = 'v0.1.0-alpha.4'
    $alpha4Manifest.tag_candidate = 'v0.1.0-alpha.4'
    $alpha4Manifest.build.passed_test_count = $script:expectedTestNames.Count
    $alpha4Manifest.build.passed_tests = @($script:expectedTestNames)
    $validAlpha4ManifestJson = ConvertTo-Json -InputObject $alpha4Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha4ManifestPath -Text ($validAlpha4ManifestJson + "`n")
    $alpha4Package = Assert-PublishPackage -PackageRoot $alpha4Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.4'
    Assert-True ($alpha4Package.Assets.Count -eq 28) 'alpha.4 package keeps alpha.3 27-file inventory plus standalone manifest'
    Assert-True ((Set-PublishProfile -Tag 'v0.1.0-alpha.4').AssetPathMap.Count -eq
        (Set-PublishProfile -Tag 'v0.1.0-alpha.3').AssetPathMap.Count) 'alpha.4 keeps alpha.3 asset map size'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha4Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.3' } `
        'alpha.4 package cannot pass the alpha.3 profile'
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.4')
    $validAlpha4ManifestJson = [System.IO.File]::ReadAllText($alpha4ManifestPath, [System.Text.Encoding]::UTF8)

    $alpha5Root = Join-Path $testRoot 'package-alpha5'
    Copy-Item -LiteralPath $alpha4Root -Destination $alpha5Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.5')
    $alpha5ManifestPath = Join-Path $alpha5Root 'manifest.json'
    $alpha5ReadmePath = Join-Path $alpha5Root 'README.md'
    Write-Utf8NoBom -Path $alpha5ReadmePath -Text 'synthetic alpha.5 package README'
    $alpha5Manifest = [System.IO.File]::ReadAllText($alpha5ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha5ReadmeItem = Get-Item -LiteralPath $alpha5ReadmePath
    $alpha5ReadmeRecord = @($alpha5Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha5ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.4 manifest must contain one README record.' }
    $alpha5ReadmeRecord[0].length_bytes = [long]$alpha5ReadmeItem.Length
    $alpha5ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha5ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($relativePath in @('docs/R106_IPC第二版.md', 'docs/R106_配置迁移与测试.md', 'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1')) {
        $fullPath = Join-Path $alpha5Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.5 package content: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $alpha5Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha5Manifest.version = 'v0.1.0-alpha.5'
    $alpha5Manifest.tag_candidate = 'v0.1.0-alpha.5'
    $alpha5Manifest.build.passed_test_count = $script:expectedTestNames.Count
    $alpha5Manifest.build.passed_tests = @($script:expectedTestNames)
    $validAlpha5ManifestJson = ConvertTo-Json -InputObject $alpha5Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha5ManifestPath -Text ($validAlpha5ManifestJson + "`n")
    $alpha5Package = Assert-PublishPackage -PackageRoot $alpha5Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.5'
    Assert-True ($alpha5Package.Assets.Count -eq 34) 'alpha.5 package accepts 33 files plus standalone manifest'
    Assert-True ((Set-PublishProfile -Tag 'v0.1.0-alpha.5').AssetPathMap.Count -eq
        ((Set-PublishProfile -Tag 'v0.1.0-alpha.4').AssetPathMap.Count + 6)) 'alpha.5 adds only two migration/protocol guides and four test entry files to alpha.4'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha5Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.4' } `
        'alpha.5 package cannot pass the alpha.4 profile'
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.5')
    $validAlpha5ManifestJson = [System.IO.File]::ReadAllText($alpha5ManifestPath, [System.Text.Encoding]::UTF8)

    $alpha6Root = Join-Path $testRoot 'package-alpha6'
    Copy-Item -LiteralPath $alpha5Root -Destination $alpha6Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.6')
    $alpha6ManifestPath = Join-Path $alpha6Root 'manifest.json'
    $alpha6ReadmePath = Join-Path $alpha6Root 'README.md'
    Write-Utf8NoBom -Path $alpha6ReadmePath -Text 'synthetic alpha.6 package README'
    $alpha6Manifest = [System.IO.File]::ReadAllText($alpha6ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha6ReadmeItem = Get-Item -LiteralPath $alpha6ReadmePath
    $alpha6ReadmeRecord = @($alpha6Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha6ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.5 manifest must contain one README record.' }
    $alpha6ReadmeRecord[0].length_bytes = [long]$alpha6ReadmeItem.Length
    $alpha6ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha6ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($relativePath in @('docs/R108_收发路由状态与alpha6验收.md', 'start-merged-test.cmd', 'start-merged-test.ps1')) {
        $fullPath = Join-Path $alpha6Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.6 package content: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $alpha6Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha6Manifest.version = 'v0.1.0-alpha.6'
    $alpha6Manifest.tag_candidate = 'v0.1.0-alpha.6'
    $alpha6Manifest.build.passed_test_count = 39
    $alpha6Manifest.build.passed_tests = @((Set-PublishProfile -Tag 'v0.1.0-alpha.6').TestNames)
    $validAlpha6ManifestJson = ConvertTo-Json -InputObject $alpha6Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha6ManifestPath -Text ($validAlpha6ManifestJson + "`n")
    $alpha6Package = Assert-PublishPackage -PackageRoot $alpha6Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.6'
    Assert-True ($alpha6Package.Assets.Count -eq 37) 'alpha.6 package accepts 36 files plus standalone manifest'
    Assert-True ((Set-PublishProfile -Tag 'v0.1.0-alpha.6').AssetPathMap.Count -eq
        ((Set-PublishProfile -Tag 'v0.1.0-alpha.5').AssetPathMap.Count + 3)) `
        'alpha.6 adds only the R108 guide and two merged-entry files to alpha.5'
    Assert-True ($alpha6Package.Manifest.build.passed_tests.Count -eq 39 -and
        $alpha6Package.Manifest.build.passed_tests[36] -ceq 'talkgroup_routing_test' -and
        $alpha6Package.Manifest.build.passed_tests[37] -ceq 'bm_routing_lifecycle_test' -and
        $alpha6Package.Manifest.build.passed_tests[38] -ceq 'routing_state_test') `
        'alpha.6 publisher profile pins the three additional native tests in order'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha6Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.5' } `
        'alpha.6 package cannot pass the alpha.5 profile'
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.6')
    $validAlpha6ManifestJson = [System.IO.File]::ReadAllText($alpha6ManifestPath, [System.Text.Encoding]::UTF8)

    $alpha7Root = Join-Path $testRoot 'package-alpha7'
    Copy-Item -LiteralPath $alpha6Root -Destination $alpha7Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.7')
    $alpha7ManifestPath = Join-Path $alpha7Root 'manifest.json'
    $alpha7ReadmePath = Join-Path $alpha7Root 'README.md'
    Write-Utf8NoBom -Path $alpha7ReadmePath -Text 'synthetic alpha.7 package README'
    $alpha7Manifest = [System.IO.File]::ReadAllText($alpha7ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha7ReadmeItem = Get-Item -LiteralPath $alpha7ReadmePath
    $alpha7ReadmeRecord = @($alpha7Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha7ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.6 manifest must contain one README record.' }
    $alpha7ReadmeRecord[0].length_bytes = [long]$alpha7ReadmeItem.Length
    $alpha7ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha7ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $alpha7DocPath = Join-Path $alpha7Root 'docs\R109_下行状态与动态组修复.md'
    Write-Utf8NoBom -Path $alpha7DocPath -Text 'synthetic alpha.7 R109 guide'
    $alpha7DocItem = Get-Item -LiteralPath $alpha7DocPath
    $alpha7Manifest.files += ,([ordered]@{
        path = 'docs/R109_下行状态与动态组修复.md'
        asset_name = (Get-PublishAssetName -RelativePath 'docs/R109_下行状态与动态组修复.md')
        length_bytes = [long]$alpha7DocItem.Length
        sha256 = (Get-FileHash -LiteralPath $alpha7DocPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic test content'
    })
    $alpha7DynamicDocPath = Join-Path $alpha7Root 'docs\R109_动态组激活实现.md'
    Write-Utf8NoBom -Path $alpha7DynamicDocPath -Text 'synthetic alpha.7 dynamic-group guide'
    $alpha7DynamicDocItem = Get-Item -LiteralPath $alpha7DynamicDocPath
    $alpha7Manifest.files += ,([ordered]@{
        path = 'docs/R109_动态组激活实现.md'
        asset_name = (Get-PublishAssetName -RelativePath 'docs/R109_动态组激活实现.md')
        length_bytes = [long]$alpha7DynamicDocItem.Length
        sha256 = (Get-FileHash -LiteralPath $alpha7DynamicDocPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic test content'
    })
    $alpha7Manifest.version = 'v0.1.0-alpha.7'
    $alpha7Manifest.tag_candidate = 'v0.1.0-alpha.7'
    $alpha7Manifest.build.passed_test_count = 39
    $alpha7Manifest.build.passed_tests = @((Set-PublishProfile -Tag 'v0.1.0-alpha.7').TestNames)
    $validAlpha7ManifestJson = ConvertTo-Json -InputObject $alpha7Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha7ManifestPath -Text ($validAlpha7ManifestJson + "`n")
    $alpha7Package = Assert-PublishPackage -PackageRoot $alpha7Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.7'
    Assert-True ($alpha7Package.Assets.Count -eq 39) 'alpha.7 package accepts 38 files plus standalone manifest'
    Assert-True ((Set-PublishProfile -Tag 'v0.1.0-alpha.7').AssetPathMap.Count -eq
        ((Set-PublishProfile -Tag 'v0.1.0-alpha.6').AssetPathMap.Count + 2)) `
        'alpha.7 adds the two R109 guides to the alpha.6 package profile'
    Assert-True ($alpha7Package.Manifest.build.passed_tests.Count -eq 39 -and
        [string]::Join('|', @($alpha7Package.Manifest.build.passed_tests)) -ceq
            [string]::Join('|', @(Set-PublishProfile -Tag 'v0.1.0-alpha.6').TestNames)) `
        'alpha.7 publisher profile retains all 39 alpha.6 tests in order'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha7Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.6' } `
        'alpha.7 package cannot pass the alpha.6 profile'
    Assert-True (-not (Set-PublishProfile -Tag 'v0.1.0-alpha.7').AssetPathMap.Contains('include/wirex/quick_call.hpp')) `
        'quick_call.hpp is not part of the alpha.7 runtime package asset map'
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.7')

    $alpha8Root = Join-Path $testRoot 'package-alpha8'
    Copy-Item -LiteralPath $alpha7Root -Destination $alpha8Root -Recurse
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.8')
    $alpha8ExcludedPaths = @(
        'start-bm-radio-bridge.cmd', 'start-listen-91.cmd', 'start-profile.cmd',
        'start-ui.cmd', 'start-user-config.cmd', 'start-user-config.ps1',
        'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1',
        'start-merged-test.cmd', 'start-merged-test.ps1'
    )
    foreach ($relativePath in $alpha8ExcludedPaths) {
        $excludedFile = Join-Path $alpha8Root $relativePath
        if ([System.IO.File]::Exists($excludedFile)) { [System.IO.File]::Delete($excludedFile) }
    }
    $alpha8ToolsPath = Join-Path $alpha8Root 'tools'
    New-Item -ItemType Directory -Path $alpha8ToolsPath -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha8.cmd') `
        -Destination (Join-Path $alpha8Root 'start-wirex-bridge.cmd')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tools\start-wirex-bridge-alpha8.ps1') `
        -Destination (Join-Path $alpha8ToolsPath 'start-wirex-bridge.ps1')
    $alpha8ManifestPath = Join-Path $alpha8Root 'manifest.json'
    $alpha8Manifest = [System.IO.File]::ReadAllText($alpha8ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha8Manifest.files = @($alpha8Manifest.files | Where-Object {
        $alpha8ExcludedPaths -cnotcontains [string]$_.path
    })
    $alpha8ReadmePath = Join-Path $alpha8Root 'README.md'
    Write-Utf8NoBom -Path $alpha8ReadmePath -Text 'synthetic alpha.8 package README'
    $alpha8ReadmeRecord = @($alpha8Manifest.files | Where-Object { [string]$_.path -ceq 'README.md' })
    if ($alpha8ReadmeRecord.Count -ne 1) { throw 'Synthetic alpha.7 manifest must contain exactly one README record.' }
    $alpha8ReadmeRecord[0].length_bytes = [long](Get-Item -LiteralPath $alpha8ReadmePath).Length
    $alpha8ReadmeRecord[0].sha256 = (Get-FileHash -LiteralPath $alpha8ReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($relativePath in @('start-wirex-bridge.cmd','tools/start-wirex-bridge.ps1')) {
        $physicalPath = Join-Path $alpha8Root ($relativePath -replace '/', '\\')
        $physicalItem = Get-Item -LiteralPath $physicalPath
        $alpha8Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$physicalItem.Length
            sha256 = (Get-FileHash -LiteralPath $physicalPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha8Manifest.version = 'v0.1.0-alpha.8'
    $alpha8Manifest.tag_candidate = 'v0.1.0-alpha.8'
    $alpha8Manifest.build.passed_test_count = 39
    $alpha8Manifest.build.passed_tests = @((Set-PublishProfile -Tag 'v0.1.0-alpha.8').TestNames)
    $validAlpha8ManifestJson = ConvertTo-Json -InputObject $alpha8Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha8ManifestPath -Text ($validAlpha8ManifestJson + "`n")
    $alpha8Package = Assert-PublishPackage -PackageRoot $alpha8Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.8'
    Assert-True ($alpha8Package.Assets.Count -eq 29) 'alpha.8 package accepts 28 files plus standalone manifest'
    Assert-True ((Set-PublishProfile -Tag 'v0.1.0-alpha.8').AssetPathMap.Count -eq
        ((Set-PublishProfile -Tag 'v0.1.0-alpha.7').AssetPathMap.Count - $alpha8ExcludedPaths.Count + 2)) `
        'alpha.8 publisher profile removes legacy entry scripts and retains the two new entrance files'
    Assert-True (@($alpha8Package.Assets | Where-Object { [string]$_.Name -match '\.cmd$' }).Count -eq 1 -and
        @($alpha8Package.Assets | Where-Object { [string]$_.Name -ceq 'tools__start-wirex-bridge.ps1' }).Count -eq 1) `
        'alpha.8 publisher accepts one command and the hidden technical launcher'
    Assert-True ($alpha8Package.Manifest.build.passed_tests.Count -eq 39 -and
        [string]::Join('|', @($alpha8Package.Manifest.build.passed_tests)) -ceq
            [string]::Join('|', @(Set-PublishProfile -Tag 'v0.1.0-alpha.7').TestNames)) `
        'alpha.8 publisher profile preserves all 39 native tests in order'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha8Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.7' } `
        'alpha.8 package cannot pass the alpha.7 profile'
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.8')

    $alpha9Root = Join-Path $testRoot 'package-alpha9'
    Copy-Item -LiteralPath $alpha8Root -Destination $alpha9Root -Recurse
    $alpha9Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.9'
    foreach ($relativePath in @(
        'ui/windows/RadioIdentity.psm1',
        'docs/R111_UI与音量.md',
        'docs/R111_BM订阅与收听优先级.md',
        'docs/R111_用户资料与电台显示.md'
    )) {
        $fullPath = Join-Path $alpha9Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.9 package content: ' + $relativePath)
    }
    $alpha9ReadmePath = Join-Path $alpha9Root 'README.md'
    Write-Utf8NoBom -Path $alpha9ReadmePath -Text 'synthetic alpha.9 package README'
    $alpha9LauncherPath = Join-Path $alpha9Root 'tools\start-wirex-bridge.ps1'
    $alpha9LauncherText = [System.IO.File]::ReadAllText($alpha9LauncherPath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $alpha9LauncherPath -Text $alpha9LauncherText.Replace('alpha.8', 'alpha.9')

    $alpha9ManifestPath = Join-Path $alpha9Root 'manifest.json'
    $alpha9Manifest = [System.IO.File]::ReadAllText($alpha9ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha9Manifest.files = @($alpha9Manifest.files | Where-Object {
        [string]$_.path -cne 'README.md' -and [string]$_.path -cne 'tools/start-wirex-bridge.ps1'
    })
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1',
        'ui/windows/RadioIdentity.psm1', 'docs/R111_UI与音量.md',
        'docs/R111_BM订阅与收听优先级.md', 'docs/R111_用户资料与电台显示.md')) {
        $fullPath = Join-Path $alpha9Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $alpha9Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha9Manifest.version = 'v0.1.0-alpha.9'
    $alpha9Manifest.tag_candidate = 'v0.1.0-alpha.9'
    $alpha9Manifest.build.passed_test_count = $alpha9Profile.TestNames.Count
    $alpha9Manifest.build.passed_tests = @($alpha9Profile.TestNames)
    $validAlpha9ManifestJson = ConvertTo-Json -InputObject $alpha9Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha9ManifestPath -Text ($validAlpha9ManifestJson + "`n")
    $alpha9Package = Assert-PublishPackage -PackageRoot $alpha9Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.9'
    Assert-True ($alpha9Package.Assets.Count -eq 33) 'alpha.9 package accepts 32 files plus standalone manifest'
    Assert-True ($alpha9Profile.AssetPathMap.Count -eq
        ((Set-PublishProfile -Tag 'v0.1.0-alpha.8').AssetPathMap.Count + 4)) `
        'alpha.9 publisher profile adds the runtime identity module and three R111 documents'
    Assert-True (@($alpha9Package.Assets | Where-Object { $_.Name -match '\.cmd$' }).Count -eq 1 -and
        @($alpha9Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__radio-identity.psm1' }).Count -eq 1) `
        'alpha.9 publisher accepts one command and the RadioIdentity runtime module'
    Assert-True (-not $alpha9Profile.AssetPathMap.Contains('tools/test-radio-identity.ps1') -and
        -not $alpha9Profile.AssetPathMap.Contains('tools/test-radio-identity-http-server.ps1')) `
        'alpha.9 publisher allowlist excludes both developer identity test scripts'
    Assert-True ($alpha9Package.Manifest.build.passed_tests.Count -eq 39 -and
        [string]::Join('|', @($alpha9Package.Manifest.build.passed_tests)) -ceq
            [string]::Join('|', @(Set-PublishProfile -Tag 'v0.1.0-alpha.8').TestNames)) `
        'alpha.9 publisher profile preserves all 39 native tests in order'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha9Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.8' } `
        'alpha.9 package cannot pass the alpha.8 profile'
    $cacheDirectory = Join-Path $alpha9Root 'private\user-config'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $cacheDirectory 'radio-identity-cache.json') -Text '{}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha9Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.9' } `
        'alpha.9 publisher rejects a local RadioID cache in the generic package'
    Remove-Item -LiteralPath $cacheDirectory -Recurse -Force -ErrorAction Stop
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $cacheDirectory 'channel-favorites.json') -Text '{}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha9Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.9' } `
        'alpha.9 publisher rejects user-maintained channel favorites in the generic package'
    Remove-Item -LiteralPath $cacheDirectory -Recurse -Force -ErrorAction Stop
    $identityTestHelper = Join-Path $alpha9Root 'tools\test-radio-identity-http-server.ps1'
    Write-Utf8NoBom -Path $identityTestHelper -Text '# synthetic helper that must stay out of packages'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha9Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.9' } `
        'alpha.9 publisher rejects the local test HTTP helper from the generic package'
    Remove-Item -LiteralPath $identityTestHelper -ErrorAction Stop

    $alpha10Root = Join-Path $testRoot 'package-alpha10'
    Copy-Item -LiteralPath $alpha9Root -Destination $alpha10Root -Recurse
    $alpha10Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.10'
    $alpha10R111Paths = @(
        'docs/R111_UI与音量.md',
        'docs/R111_BM订阅与收听优先级.md',
        'docs/R111_用户资料与电台显示.md'
    )
    foreach ($relativePath in $alpha10R111Paths) {
        Remove-Item -LiteralPath (Join-Path $alpha10Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) -Force -ErrorAction Stop
    }
    foreach ($relativePath in @(
        'docs/R112_A_身份查询实施.md',
        'docs/R112_A_网络音频指标.md',
        'docs/R112_A_UI精简.md'
    )) {
        $fullPath = Join-Path $alpha10Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.10 package content: ' + $relativePath)
    }
    $alpha10ReadmePath = Join-Path $alpha10Root 'README.md'
    Write-Utf8NoBom -Path $alpha10ReadmePath -Text 'synthetic alpha.10 package README'
    $alpha10LauncherPath = Join-Path $alpha10Root 'tools\start-wirex-bridge.ps1'
    $alpha10LauncherText = [System.IO.File]::ReadAllText($alpha10LauncherPath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $alpha10LauncherPath -Text $alpha10LauncherText.Replace('alpha.9', 'alpha.10')

    $alpha10ManifestPath = Join-Path $alpha10Root 'manifest.json'
    $alpha10Manifest = [System.IO.File]::ReadAllText($alpha10ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha10Manifest.files = @($alpha10Manifest.files | Where-Object {
        [string]$_.path -cne 'README.md' -and [string]$_.path -cne 'tools/start-wirex-bridge.ps1' -and
        $alpha10R111Paths -cnotcontains [string]$_.path
    })
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1',
        'docs/R112_A_身份查询实施.md', 'docs/R112_A_网络音频指标.md', 'docs/R112_A_UI精简.md')) {
        $fullPath = Join-Path $alpha10Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $alpha10Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha10Manifest.version = 'v0.1.0-alpha.10'
    $alpha10Manifest.tag_candidate = 'v0.1.0-alpha.10'
    $alpha10Manifest.build.passed_test_count = $alpha10Profile.TestNames.Count
    $alpha10Manifest.build.passed_tests = @($alpha10Profile.TestNames)
    $alpha10Manifest | Add-Member -NotePropertyName excluded_private_files -NotePropertyValue @(
        'private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json',
        'private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
        'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt'
    ) -Force
    $validAlpha10ManifestJson = ConvertTo-Json -InputObject $alpha10Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha10ManifestPath -Text ($validAlpha10ManifestJson + "`n")
    $alpha10Package = Assert-PublishPackage -PackageRoot $alpha10Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.10'
    Assert-True ($alpha10Package.Assets.Count -eq 33) 'alpha.10 package accepts 32 files plus standalone manifest'
    Assert-True ($alpha10Profile.AssetPathMap.Count -eq $alpha9Profile.AssetPathMap.Count) `
        'alpha.10 publisher profile replaces three R111 documents with three R112 documents'
    Assert-True (@($alpha10Package.Assets | Where-Object { $_.Name -match '\.cmd$' }).Count -eq 1 -and
        @($alpha10Package.Assets | Where-Object { $_.Name -like 'docs__r112-*' }).Count -eq 3) `
        'alpha.10 publisher accepts one command and all three R112 document assets'
    Assert-True (@($alpha10Profile.AssetPathMap.Keys | Where-Object { [string]$_ -like 'docs/R111_*' }).Count -eq 0) `
        'alpha.10 publisher excludes the three superseded R111 documents'
    Assert-True (@($alpha10Profile.AssetPathMap.Keys | Where-Object {
        [string]$_ -match '(^|/)test[^/]*\.(?:cmd|ps1)$'
    }).Count -eq 0) 'alpha.10 publisher allowlist excludes every test entry script'
    Assert-True ($alpha10Package.Manifest.build.passed_tests.Count -eq 39 -and
        [string]::Join('|', @($alpha10Package.Manifest.build.passed_tests)) -ceq
            [string]::Join('|', @($alpha9Profile.TestNames))) `
        'alpha.10 publisher profile preserves all 39 native tests in order'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha10Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.9' } `
        'alpha.10 package cannot pass the alpha.9 profile'
    $alpha10PrivateDirectory = Join-Path $alpha10Root 'private\user-config'
    New-Item -ItemType Directory -Path $alpha10PrivateDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $alpha10PrivateDirectory 'password-file-path.txt') -Text 'synthetic test path only'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha10Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.10' } `
        'alpha.10 publisher rejects a personal password-path file in the generic package'
    Remove-Item -LiteralPath $alpha10PrivateDirectory -Recurse -Force -ErrorAction Stop

    $alpha11Root = Join-Path $testRoot 'package-alpha11'
    Copy-Item -LiteralPath $alpha10Root -Destination $alpha11Root -Recurse
    $alpha11Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.11'
    $alpha11RetiredDocs = @('docs/R112_A_身份查询实施.md', 'docs/R112_A_UI精简.md')
    foreach ($relativePath in $alpha11RetiredDocs) {
        Remove-Item -LiteralPath (Join-Path $alpha11Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) -Force -ErrorAction Stop
    }
    foreach ($relativePath in @('docs/R113_LCD核心实现.md', 'docs/R113_身份与LCD接线.md')) {
        $fullPath = Join-Path $alpha11Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.11 package content: ' + $relativePath)
    }
    $alpha11ReadmePath = Join-Path $alpha11Root 'README.md'
    Write-Utf8NoBom -Path $alpha11ReadmePath -Text 'synthetic alpha.11 package README'
    $alpha11LauncherPath = Join-Path $alpha11Root 'tools\start-wirex-bridge.ps1'
    $alpha11LauncherText = [System.IO.File]::ReadAllText($alpha11LauncherPath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $alpha11LauncherPath -Text $alpha11LauncherText.Replace('alpha.10', 'alpha.11')

    $alpha11ManifestPath = Join-Path $alpha11Root 'manifest.json'
    $alpha11Manifest = [System.IO.File]::ReadAllText($alpha11ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha11Manifest.files = @($alpha11Manifest.files | Where-Object {
        [string]$_.path -cne 'README.md' -and [string]$_.path -cne 'tools/start-wirex-bridge.ps1' -and
        $alpha11RetiredDocs -cnotcontains [string]$_.path
    })
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1',
        'docs/R113_LCD核心实现.md', 'docs/R113_身份与LCD接线.md')) {
        $fullPath = Join-Path $alpha11Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $alpha11Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha11Manifest.version = 'v0.1.0-alpha.11'
    $alpha11Manifest.tag_candidate = 'v0.1.0-alpha.11'
    $alpha11Manifest | Add-Member -MemberType NoteProperty -Name release_scope `
        -Value 'R113 DIRECT: cached RadioID callsign in the existing mode-4 T90 SrcCallSign field' -Force
    $alpha11Manifest.build.passed_test_count = $alpha11Profile.TestNames.Count
    $alpha11Manifest.build.passed_tests = @($alpha11Profile.TestNames)
    $validAlpha11ManifestJson = ConvertTo-Json -InputObject $alpha11Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha11ManifestPath -Text ($validAlpha11ManifestJson + "`n")
    $alpha11Package = Assert-PublishPackage -PackageRoot $alpha11Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.11'
    Assert-True ($alpha11Package.Assets.Count -eq 33) 'alpha.11 package accepts 32 files plus standalone manifest'
    Assert-True ($alpha11Profile.AssetPathMap.Count -eq $alpha10Profile.AssetPathMap.Count) `
        'alpha.11 publisher profile replaces two R112 documents with two R113 documents and retains the network-audio guide'
    Assert-True (@($alpha11Package.Assets | Where-Object { $_.Name -match '\.cmd$' }).Count -eq 1 -and
        @($alpha11Package.Assets | Where-Object { $_.Name -like 'docs__r113-*' }).Count -eq 2 -and
        @($alpha11Package.Assets | Where-Object { $_.Name -ceq 'docs__r112-a-network-audio-metrics.md' }).Count -eq 1) `
        'alpha.11 publisher accepts one command, both R113 documents and the retained R112 network-audio guide'
    Assert-True (@($alpha11Profile.AssetPathMap.Keys | Where-Object { $alpha11RetiredDocs -ccontains [string]$_ }).Count -eq 0) `
        'alpha.11 publisher excludes the two superseded R112 identity/UI documents'
    Assert-True (@($alpha11Profile.AssetPathMap.Keys | Where-Object {
        [string]$_ -match '(^|/)test[^/]*\.(?:cmd|ps1)$'
    }).Count -eq 0) 'alpha.11 publisher allowlist excludes every test entry script'
    Assert-True ($alpha11Package.Manifest.build.passed_tests.Count -eq 40 -and
        [string]::Join('|', @($alpha11Package.Manifest.build.passed_tests)) -ceq
            [string]::Join('|', @($alpha11Profile.TestNames))) `
        'alpha.11 publisher profile pins all 40 native tests in the build-provenance order'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha11Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.10' } `
        'alpha.11 package cannot pass the alpha.10 profile'
    $alpha11PrivateDirectory = Join-Path $alpha11Root 'private\user-config'
    New-Item -ItemType Directory -Path $alpha11PrivateDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $alpha11PrivateDirectory 'password-file-path.txt') -Text 'synthetic test path only'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha11Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.11' } `
        'alpha.11 publisher rejects a personal password-path file in the generic package'
    Remove-Item -LiteralPath $alpha11PrivateDirectory -Recurse -Force -ErrorAction Stop

    $alpha12Root = Join-Path $testRoot 'package-alpha12'
    Copy-Item -LiteralPath $alpha11Root -Destination $alpha12Root -Recurse
    $alpha12Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.12'
    foreach ($relativePath in @('ui/windows/RadioCat.psm1', 'docs/R116_CAT能力与控制实现.md', 'docs/R116_电台控制界面.md')) {
        $fullPath = Join-Path $alpha12Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($relativePath -ceq 'ui/windows/RadioCat.psm1') {
            [System.IO.File]::WriteAllText($fullPath, 'Export-ModuleMember -Function @()', [System.Text.UTF8Encoding]::new($true))
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.12 package content: ' + $relativePath)
        }
    }
    $alpha12ReadmePath = Join-Path $alpha12Root 'README.md'
    Write-Utf8NoBom -Path $alpha12ReadmePath -Text 'synthetic alpha.12 package README'
    $alpha12LauncherPath = Join-Path $alpha12Root 'tools\start-wirex-bridge.ps1'
    $alpha12LauncherText = [System.IO.File]::ReadAllText($alpha12LauncherPath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $alpha12LauncherPath -Text $alpha12LauncherText.Replace('alpha.11', 'alpha.12')

    $alpha12ManifestPath = Join-Path $alpha12Root 'manifest.json'
    $alpha12Manifest = [System.IO.File]::ReadAllText($alpha12ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha12Manifest.files = @($alpha12Manifest.files | Where-Object {
        [string]$_.path -cne 'README.md' -and [string]$_.path -cne 'tools/start-wirex-bridge.ps1'
    })
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1',
        'ui/windows/RadioCat.psm1', 'docs/R116_CAT能力与控制实现.md', 'docs/R116_电台控制界面.md')) {
        $fullPath = Join-Path $alpha12Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $alpha12Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = (Get-PublishAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic test content'
        })
    }
    $alpha12Manifest.version = 'v0.1.0-alpha.12'
    $alpha12Manifest.tag_candidate = 'v0.1.0-alpha.12'
    $alpha12Manifest | Add-Member -MemberType NoteProperty -Name release_scope -Value 'R116 DIRECT: documented CAT queries and controls' -Force
    $alpha12Manifest.build.passed_test_count = $alpha12Profile.TestNames.Count
    $alpha12Manifest.build.passed_tests = @($alpha12Profile.TestNames)
    $alpha12Manifest.excluded_private_files = @($alpha12Manifest.excluded_private_files) + 'private/user-config/radio-control-preferences.json'
    $validAlpha12ManifestJson = ConvertTo-Json -InputObject $alpha12Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha12ManifestPath -Text ($validAlpha12ManifestJson + [Environment]::NewLine)
    $alpha12Package = Assert-PublishPackage -PackageRoot $alpha12Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.12'
    Assert-True ($alpha12Package.Assets.Count -eq ($alpha11Package.Assets.Count + 3)) 'alpha.12 publisher accepts exactly three new assets and the inherited manifest'
    Assert-True ($alpha12Profile.AssetPathMap.Count -eq ($alpha11Profile.AssetPathMap.Count + 3)) 'alpha.12 publisher inherits the complete alpha.11 allowlist and adds three exact paths'
    Assert-True (@($alpha12Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__radio-cat.psm1' }).Count -eq 1 -and
        @($alpha12Package.Assets | Where-Object { $_.Name -like 'docs__r116-*' }).Count -eq 2 -and
        @($alpha12Package.Assets | Where-Object { $_.Name -ceq 'docs__r112-a-network-audio-metrics.md' }).Count -eq 1 -and
        @($alpha12Package.Assets | Where-Object { $_.Name -like 'docs__r113-*' }).Count -eq 2) 'alpha.12 retains R112/R113 assets and adds the CAT module plus two R116 guides'
    Assert-True ($alpha12Package.Manifest.build.passed_tests.Count -eq 40 -and
        [string]::Join('|', @($alpha12Package.Manifest.build.passed_tests)) -ceq [string]::Join('|', @($alpha11Profile.TestNames))) 'alpha.12 publisher retains the exact 40-test Native inventory'
    Assert-True (@($alpha12Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'private/user-config/radio-control-preferences.json' }).Count -eq 1) 'alpha.12 manifest declares local radio-control preferences as excluded'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha12Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.11' } 'alpha.12 package cannot pass the alpha.11 profile'
    $alpha12PrivateDirectory = Join-Path $alpha12Root 'private\user-config'
    New-Item -ItemType Directory -Path $alpha12PrivateDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $alpha12PrivateDirectory 'radio-control-preferences.json') -Text '{"defaultPowerWatts":25}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha12Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.12' } 'alpha.12 publisher rejects a personal radio-control preference file'
    Remove-Item -LiteralPath $alpha12PrivateDirectory -Recurse -Force -ErrorAction Stop

    $alpha13Root = Join-Path $testRoot 'package-alpha13'
    Copy-Item -LiteralPath $alpha12Root -Destination $alpha13Root -Recurse
    $alpha13Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.13'
    $alpha13NewAssets = @(
        'ui/windows/RadioCatUi.ps1', 'ui/windows/RadioDevices.psm1', 'ui/windows/BmServers.psm1',
        'ui/windows/BmManagement.psm1', 'ui/windows/BmManagementUi.ps1'
    )
    foreach ($relativePath in $alpha13NewAssets) {
        $fullPath = Join-Path $alpha13Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($fullPath, ('# synthetic alpha.13 package content: ' + $relativePath), [System.Text.UTF8Encoding]::new($true))
    }
    $alpha13ReadmePath = Join-Path $alpha13Root 'README.md'
    Write-Utf8NoBom -Path $alpha13ReadmePath -Text 'synthetic alpha.13 package README'
    $alpha13LauncherPath = Join-Path $alpha13Root 'tools\start-wirex-bridge.ps1'
    $alpha13LauncherText = [System.IO.File]::ReadAllText($alpha13LauncherPath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $alpha13LauncherPath -Text $alpha13LauncherText.Replace('alpha.12', 'alpha.13')

    $alpha13ManifestPath = Join-Path $alpha13Root 'manifest.json'
    $alpha13Manifest = [System.IO.File]::ReadAllText($alpha13ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha13Manifest.files = @($alpha13Manifest.files | Where-Object {
        [string]$_.path -cne 'README.md' -and [string]$_.path -cne 'tools/start-wirex-bridge.ps1'
    })
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1') + $alpha13NewAssets) {
        $fullPath = Join-Path $alpha13Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $alpha13Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = [string]$alpha13Profile.AssetPathMap[$relativePath]
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.13 test content'
        })
    }
    $alpha13Manifest.version = 'v0.1.0-alpha.13'
    $alpha13Manifest.tag_candidate = 'v0.1.0-alpha.13'
    $alpha13Manifest | Add-Member -MemberType NoteProperty -Name release_scope -Value 'R117 DIRECT: BM server selection, radio catalog and static group controls' -Force
    $alpha13Manifest.build.passed_test_count = $alpha13Profile.TestNames.Count
    $alpha13Manifest.build.passed_tests = @($alpha13Profile.TestNames)
    $alpha13Manifest.excluded_private_files = @($alpha13Manifest.excluded_private_files) + @(
        'private/user-config/radio-control-preferences.json',
        'private/user-config/bm-management-preferences.json',
        'private/user-config/bm-server-preferences.json'
    )
    $validAlpha13ManifestJson = ConvertTo-Json -InputObject $alpha13Manifest -Depth 12
    Write-Utf8NoBom -Path $alpha13ManifestPath -Text ($validAlpha13ManifestJson + [Environment]::NewLine)
    $alpha13Package = Assert-PublishPackage -PackageRoot $alpha13Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.13'
    Assert-True ($alpha13Package.Assets.Count -eq ($alpha12Package.Assets.Count + 5)) 'alpha.13 publisher accepts exactly five new runtime assets and the inherited manifest'
    Assert-True ($alpha13Profile.AssetPathMap.Count -eq ($alpha12Profile.AssetPathMap.Count + 5)) 'alpha.13 publisher inherits the complete alpha.12 allowlist and adds five exact paths'
    Assert-True (@($alpha13Package.Assets | Where-Object { $_.Name -like 'ui__windows__bm-*' }).Count -eq 3 -and
        @($alpha13Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__radio-cat-ui.ps1' }).Count -eq 1 -and
        @($alpha13Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__radio-devices.psm1' }).Count -eq 1) 'alpha.13 includes the BM adapters and both radio UI/catalog modules'
    Assert-True ($alpha13Package.Manifest.build.passed_tests.Count -eq 40 -and
        [string]::Join('|', @($alpha13Package.Manifest.build.passed_tests)) -ceq [string]::Join('|', @($alpha12Profile.TestNames))) 'alpha.13 publisher retains the exact 40-test Native inventory'
    Assert-True (@($alpha13Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'private/user-config/bm-management-preferences.json' }).Count -eq 1) 'alpha.13 manifest declares local BM preferences as excluded'
    Assert-True (@($alpha13Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'private/user-config/bm-server-preferences.json' }).Count -eq 1) 'alpha.13 manifest declares local BM server-selection preferences as excluded'
    $alpha13Manifest.excluded_private_files = @($alpha13Manifest.excluded_private_files | Where-Object {
        [string]$_ -cne 'private/user-config/bm-server-preferences.json'
    })
    Write-Utf8NoBom -Path $alpha13ManifestPath -Text ((ConvertTo-Json -InputObject $alpha13Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha13Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.13' } `
        'alpha.13 publisher rejects a manifest that omits the local BM server-selection preference exclusion'
    $alpha13Manifest.excluded_private_files += 'private/user-config/bm-server-preferences.json'
    Write-Utf8NoBom -Path $alpha13ManifestPath -Text ((ConvertTo-Json -InputObject $alpha13Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha13Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.12' } 'alpha.13 package cannot pass the alpha.12 profile'
    $alpha13PrivateDirectory = Join-Path $alpha13Root 'private\user-config'
    New-Item -ItemType Directory -Path $alpha13PrivateDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $alpha13PrivateDirectory 'bm-management-preferences.json') -Text '{"schema_version":1}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha13Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.13' } 'alpha.13 publisher rejects a local BM API-key path preference file'
    Remove-Item -LiteralPath $alpha13PrivateDirectory -Recurse -Force -ErrorAction Stop

    $alpha14Root = Join-Path $testRoot 'package-alpha14'
    Copy-Item -LiteralPath $alpha13Root -Destination $alpha14Root -Recurse
    $alpha14Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.14'
    $alpha14NewAsset = 'ui/windows/PortableConfig.psm1'
    $alpha14ModulePath = Join-Path $alpha14Root 'ui\windows\PortableConfig.psm1'
    [System.IO.File]::WriteAllText($alpha14ModulePath, '# synthetic alpha.14 portable configuration module', [System.Text.UTF8Encoding]::new($true))
    Write-Utf8NoBom -Path (Join-Path $alpha14Root 'README.md') -Text 'synthetic alpha.14 package README'
    $alpha14LauncherPath = Join-Path $alpha14Root 'tools\start-wirex-bridge.ps1'
    Write-Utf8NoBom -Path $alpha14LauncherPath -Text 'synthetic alpha.14 launcher'
    $alpha14ManifestPath = Join-Path $alpha14Root 'manifest.json'
    $alpha14Manifest = [System.IO.File]::ReadAllText($alpha14ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $alpha14Manifest.files = @($alpha14Manifest.files | Where-Object {
        [string]$_.path -cne 'README.md' -and [string]$_.path -cne 'tools/start-wirex-bridge.ps1'
    })
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1', $alpha14NewAsset)) {
        $fullPath = Join-Path $alpha14Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $alpha14Manifest.files += ,([ordered]@{
            path = $relativePath
            asset_name = [string]$alpha14Profile.AssetPathMap[$relativePath]
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.14 test content'
        })
    }
    $alpha14Manifest.version = 'v0.1.0-alpha.14'
    $alpha14Manifest.tag_candidate = 'v0.1.0-alpha.14'
    $alpha14Manifest.release_scope = 'R118 DIRECT: portable package-root configuration'
    $alpha14Manifest.build.passed_test_count = $alpha14Profile.TestNames.Count
    $alpha14Manifest.build.passed_tests = @($alpha14Profile.TestNames)
    $alpha14Manifest.excluded_private_files = @($alpha14Manifest.excluded_private_files) + @(
        'config.json', 'config.*.backup*', 'credentials/', 'tempSecrets/'
    )
    Write-Utf8NoBom -Path $alpha14ManifestPath -Text ((ConvertTo-Json -InputObject $alpha14Manifest -Depth 12) + [Environment]::NewLine)
    $alpha14Package = Assert-PublishPackage -PackageRoot $alpha14Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.14'
    Assert-True ($alpha14Package.Assets.Count -eq ($alpha13Package.Assets.Count + 1)) `
        'alpha.14 publisher accepts exactly one new PortableConfig module and the inherited manifest'
    Assert-True ($alpha14Profile.AssetPathMap.Count -eq ($alpha13Profile.AssetPathMap.Count + 1)) `
        'alpha.14 publisher inherits the complete alpha.13 allowlist and adds one exact module path'
    Assert-True (@($alpha14Package.Assets | Where-Object { $_.Name -ceq 'ui__windows__portable-config.psm1' }).Count -eq 1) `
        'alpha.14 publisher assigns PortableConfig its fixed ASCII asset name'
    Assert-True (@($alpha14Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.json' }).Count -eq 1 -and
        @($alpha14Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.*.backup*' }).Count -eq 1 -and
        @($alpha14Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'credentials/' }).Count -eq 1 -and
        @($alpha14Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'tempSecrets/' }).Count -eq 1) `
        'alpha.14 publisher requires explicit config, backup, credentials and temporary-secret exclusions'
    $alpha14Manifest.excluded_private_files = @($alpha14Manifest.excluded_private_files | Where-Object { [string]$_ -cne 'config.json' })
    Write-Utf8NoBom -Path $alpha14ManifestPath -Text ((ConvertTo-Json -InputObject $alpha14Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha14Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.14' } `
        'alpha.14 publisher rejects a manifest that omits the package-root config exclusion'
    $alpha14Manifest.excluded_private_files += 'config.json'
    Write-Utf8NoBom -Path $alpha14ManifestPath -Text ((ConvertTo-Json -InputObject $alpha14Manifest -Depth 12) + [Environment]::NewLine)
    $alpha14CredentialDirectory = Join-Path $alpha14Root 'credentials'
    New-Item -ItemType Directory -Path $alpha14CredentialDirectory -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $alpha14CredentialDirectory 'synthetic-only.txt') -Text 'synthetic-only'
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha14Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.14' } `
        'alpha.14 publisher rejects a credentials directory even when manifest files are fixed'
    Remove-Item -LiteralPath $alpha14CredentialDirectory -Recurse -Force -ErrorAction Stop

    $alpha15Root = Join-Path $testRoot 'package-alpha15'
    Copy-Item -LiteralPath $alpha14Root -Destination $alpha15Root -Recurse
    $alpha15Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.15'
    Write-Utf8NoBom -Path (Join-Path $alpha15Root 'README.md') -Text 'synthetic alpha.15 package README'
    $alpha15LauncherPath = Join-Path $alpha15Root 'tools\start-wirex-bridge.ps1'
    Write-Utf8NoBom -Path $alpha15LauncherPath -Text 'synthetic alpha.15 launcher'
    $alpha15ManifestPath = Join-Path $alpha15Root 'manifest.json'
    $alpha15Manifest = [System.IO.File]::ReadAllText($alpha15ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1')) {
        $fullPath = Join-Path $alpha15Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $record = @($alpha15Manifest.files | Where-Object { [string]$_.path -ceq $relativePath })
        if ($record.Count -ne 1) { throw ('alpha.15 test fixture lacks a unique manifest record for ' + $relativePath) }
        $record[0].length_bytes = [long](Get-Item -LiteralPath $fullPath).Length
        $record[0].sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record[0].source = 'synthetic alpha.15 test content'
    }
    $alpha15Manifest.version = 'v0.1.0-alpha.15'
    $alpha15Manifest.tag_candidate = 'v0.1.0-alpha.15'
    $alpha15Manifest.release_scope = 'R119 DIRECT: CAT polling stability and runtime audio gain control'
    $alpha15Manifest.build.passed_test_count = $alpha15Profile.TestNames.Count
    $alpha15Manifest.build.passed_tests = @($alpha15Profile.TestNames)
    Write-Utf8NoBom -Path $alpha15ManifestPath -Text ((ConvertTo-Json -InputObject $alpha15Manifest -Depth 12) + [Environment]::NewLine)
    $alpha15Package = Assert-PublishPackage -PackageRoot $alpha15Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.15'
    Assert-True ($alpha15Package.Assets.Count -eq $alpha14Package.Assets.Count -and
        $alpha15Profile.AssetPathMap.Count -eq $alpha14Profile.AssetPathMap.Count) `
        'alpha.15 publisher accepts the unchanged alpha.14 asset inventory with its new versioned README and launcher source'
    Assert-True (@($alpha15Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.json' }).Count -eq 1 -and
        @($alpha15Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'credentials/' }).Count -eq 1) `
        'alpha.15 manifest retains package-root configuration and credential exclusions'
    $alpha15Manifest.excluded_private_files = @($alpha15Manifest.excluded_private_files | Where-Object { [string]$_ -cne 'config.json' })
    Write-Utf8NoBom -Path $alpha15ManifestPath -Text ((ConvertTo-Json -InputObject $alpha15Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha15Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.15' } `
        'alpha.15 publisher rejects a manifest that omits the package-root config exclusion'

    $alpha16Root = Join-Path $testRoot 'package-alpha16'
    Copy-Item -LiteralPath $alpha14Root -Destination $alpha16Root -Recurse
    $alpha16Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.16'
    Write-Utf8NoBom -Path (Join-Path $alpha16Root 'README.md') -Text 'synthetic alpha.16 package README'
    $alpha16LauncherPath = Join-Path $alpha16Root 'tools\start-wirex-bridge.ps1'
    Write-Utf8NoBom -Path $alpha16LauncherPath -Text 'synthetic alpha.16 launcher'
    $alpha16ManifestPath = Join-Path $alpha16Root 'manifest.json'
    $alpha16Manifest = [System.IO.File]::ReadAllText($alpha16ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1')) {
        $fullPath = Join-Path $alpha16Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $record = @($alpha16Manifest.files | Where-Object { [string]$_.path -ceq $relativePath })
        if ($record.Count -ne 1) { throw ('alpha.16 test fixture lacks a unique manifest record for ' + $relativePath) }
        $record[0].length_bytes = [long](Get-Item -LiteralPath $fullPath).Length
        $record[0].sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record[0].source = 'synthetic alpha.16 test content'
    }
    $alpha16Manifest.version = 'v0.1.0-alpha.16'
    $alpha16Manifest.tag_candidate = 'v0.1.0-alpha.16'
    $alpha16Manifest.release_scope = 'R120 DIRECT: BrandMeister static talkgroup management'
    $alpha16Manifest.build.passed_test_count = $alpha16Profile.TestNames.Count
    $alpha16Manifest.build.passed_tests = @($alpha16Profile.TestNames)
    Write-Utf8NoBom -Path $alpha16ManifestPath -Text ((ConvertTo-Json -InputObject $alpha16Manifest -Depth 12) + [Environment]::NewLine)
    $alpha16Package = Assert-PublishPackage -PackageRoot $alpha16Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.16'
    Assert-True ($alpha16Package.Assets.Count -eq $alpha15Package.Assets.Count -and
        $alpha16Profile.AssetPathMap.Count -eq $alpha15Profile.AssetPathMap.Count) `
        'alpha.16 publisher accepts the unchanged alpha.15 asset inventory with only its versioned README and launcher source'
    Assert-True (@($alpha16Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.json' }).Count -eq 1 -and
        @($alpha16Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'credentials/' }).Count -eq 1) `
        'alpha.16 manifest retains package-root configuration and credential exclusions'
    $alpha16Manifest.excluded_private_files = @($alpha16Manifest.excluded_private_files | Where-Object { [string]$_ -cne 'config.json' })
    Write-Utf8NoBom -Path $alpha16ManifestPath -Text ((ConvertTo-Json -InputObject $alpha16Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha16Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.16' } `
        'alpha.16 publisher rejects a manifest that omits the package-root config exclusion'

    $alpha17Root = Join-Path $testRoot 'package-alpha17'
    Copy-Item -LiteralPath $alpha14Root -Destination $alpha17Root -Recurse
    $alpha17Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.17'
    Write-Utf8NoBom -Path (Join-Path $alpha17Root 'README.md') -Text 'synthetic alpha.17 package README'
    $alpha17LauncherPath = Join-Path $alpha17Root 'tools\start-wirex-bridge.ps1'
    Write-Utf8NoBom -Path $alpha17LauncherPath -Text 'synthetic alpha.17 launcher'
    $alpha17ManifestPath = Join-Path $alpha17Root 'manifest.json'
    $alpha17Manifest = [System.IO.File]::ReadAllText($alpha17ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1')) {
        $fullPath = Join-Path $alpha17Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $record = @($alpha17Manifest.files | Where-Object { [string]$_.path -ceq $relativePath })
        if ($record.Count -ne 1) { throw ('alpha.17 test fixture lacks a unique manifest record for ' + $relativePath) }
        $record[0].length_bytes = [long](Get-Item -LiteralPath $fullPath).Length
        $record[0].sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record[0].source = 'synthetic alpha.17 test content'
    }
    $alpha17Manifest.version = 'v0.1.0-alpha.17'
    $alpha17Manifest.tag_candidate = 'v0.1.0-alpha.17'
    $alpha17Manifest.release_scope = 'R121 DIRECT: fixed no-scroll console and independent BM/serial controls'
    $alpha17Manifest.build.passed_test_count = $alpha17Profile.TestNames.Count
    $alpha17Manifest.build.passed_tests = @($alpha17Profile.TestNames)
    Write-Utf8NoBom -Path $alpha17ManifestPath -Text ((ConvertTo-Json -InputObject $alpha17Manifest -Depth 12) + [Environment]::NewLine)
    $alpha17Package = Assert-PublishPackage -PackageRoot $alpha17Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.17'
    Assert-True ($alpha17Package.Assets.Count -eq $alpha16Package.Assets.Count -and
        $alpha17Profile.AssetPathMap.Count -eq 41 -and $alpha17Profile.TestNames.Count -eq 40 -and
        [string]::Join('|', $alpha17Profile.TestNames) -ceq [string]::Join('|', $alpha16Profile.TestNames)) `
        'alpha.17 publisher accepts the unchanged 41-asset inventory and ordered 40-test sequence'
    Assert-True (@($alpha17Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.json' }).Count -eq 1 -and
        @($alpha17Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'credentials/' }).Count -eq 1) `
        'alpha.17 manifest retains package-root configuration and credential exclusions'
    $alpha17Manifest.excluded_private_files = @($alpha17Manifest.excluded_private_files | Where-Object { [string]$_ -cne 'config.json' })
    Write-Utf8NoBom -Path $alpha17ManifestPath -Text ((ConvertTo-Json -InputObject $alpha17Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha17Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.17' } `
        'alpha.17 publisher rejects a manifest that omits the package-root config exclusion'

    $alpha17Manifest.excluded_private_files += 'config.json'
    Write-Utf8NoBom -Path $alpha17ManifestPath -Text ((ConvertTo-Json -InputObject $alpha17Manifest -Depth 12) + [Environment]::NewLine)

    $alpha18Root = Join-Path $testRoot 'package-alpha18'
    Copy-Item -LiteralPath $alpha17Root -Destination $alpha18Root -Recurse
    $alpha18Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.18'
    Write-Utf8NoBom -Path (Join-Path $alpha18Root 'README.md') -Text 'synthetic alpha.18 package README'
    $alpha18LauncherPath = Join-Path $alpha18Root 'tools\start-wirex-bridge.ps1'
    Write-Utf8NoBom -Path $alpha18LauncherPath -Text 'synthetic alpha.18 launcher'
    $alpha18ManifestPath = Join-Path $alpha18Root 'manifest.json'
    $alpha18Manifest = [System.IO.File]::ReadAllText($alpha18ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1')) {
        $fullPath = Join-Path $alpha18Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $record = @($alpha18Manifest.files | Where-Object { [string]$_.path -ceq $relativePath })
        if ($record.Count -ne 1) { throw ('alpha.18 test fixture lacks a unique manifest record for ' + $relativePath) }
        $record[0].length_bytes = [long](Get-Item -LiteralPath $fullPath).Length
        $record[0].sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record[0].source = 'synthetic alpha.18 test content'
    }
    $alpha18Manifest.version = 'v0.1.0-alpha.18'
    $alpha18Manifest.tag_candidate = 'v0.1.0-alpha.18'
    $alpha18Manifest.release_scope = 'R122 DIRECT: fixed WPF layout and consolidated CAT settings'
    $alpha18Manifest.build.passed_test_count = $alpha18Profile.TestNames.Count
    $alpha18Manifest.build.passed_tests = @($alpha18Profile.TestNames)
    Write-Utf8NoBom -Path $alpha18ManifestPath -Text ((ConvertTo-Json -InputObject $alpha18Manifest -Depth 12) + [Environment]::NewLine)
    $alpha18Package = Assert-PublishPackage -PackageRoot $alpha18Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.18'
    Assert-True ($alpha18Package.Assets.Count -eq $alpha17Package.Assets.Count -and
        $alpha18Profile.AssetPathMap.Count -eq 41 -and $alpha18Profile.TestNames.Count -eq 40 -and
        [string]::Join('|', $alpha18Profile.TestNames) -ceq [string]::Join('|', $alpha17Profile.TestNames)) `
        'alpha.18 publisher accepts the unchanged 41-asset inventory and ordered 40-test sequence'
    Assert-True (@($alpha18Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.json' }).Count -eq 1 -and
        @($alpha18Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'credentials/' }).Count -eq 1) `
        'alpha.18 manifest retains package-root configuration and credential exclusions'
    $alpha18Manifest.excluded_private_files = @($alpha18Manifest.excluded_private_files | Where-Object { [string]$_ -cne 'config.json' })
    Write-Utf8NoBom -Path $alpha18ManifestPath -Text ((ConvertTo-Json -InputObject $alpha18Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha18Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.18' } `
        'alpha.18 publisher rejects a manifest that omits the package-root config exclusion'

    $alpha19Root = Join-Path $testRoot 'package-alpha19'
    Copy-Item -LiteralPath $alpha18Root -Destination $alpha19Root -Recurse
    $alpha19Profile = Set-PublishProfile -Tag 'v0.1.0-alpha.19'
    Write-Utf8NoBom -Path (Join-Path $alpha19Root 'README.md') -Text 'synthetic alpha.19 package README'
    $alpha19LauncherPath = Join-Path $alpha19Root 'tools\start-wirex-bridge.ps1'
    Write-Utf8NoBom -Path $alpha19LauncherPath -Text 'synthetic alpha.19 launcher'
    $alpha19ManifestPath = Join-Path $alpha19Root 'manifest.json'
    $alpha19Manifest = [System.IO.File]::ReadAllText($alpha19ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @('README.md', 'tools/start-wirex-bridge.ps1')) {
        $fullPath = Join-Path $alpha19Root $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $record = @($alpha19Manifest.files | Where-Object { [string]$_.path -ceq $relativePath })
        if ($record.Count -ne 1) { throw ('alpha.19 test fixture lacks a unique manifest record for ' + $relativePath) }
        $record[0].length_bytes = [long](Get-Item -LiteralPath $fullPath).Length
        $record[0].sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record[0].source = 'synthetic alpha.19 test content'
    }
    $alpha19Manifest.version = 'v0.1.0-alpha.19'
    $alpha19Manifest.tag_candidate = 'v0.1.0-alpha.19'
    $alpha19Manifest.release_scope = 'R123 DIRECT: fixed WPF console layout and one-line status'
    $alpha19Manifest.excluded_private_files = @($alpha18Manifest.excluded_private_files + 'config.json' | Select-Object -Unique)
    $alpha19Manifest.build.passed_test_count = $alpha19Profile.TestNames.Count
    $alpha19Manifest.build.passed_tests = @($alpha19Profile.TestNames)
    Write-Utf8NoBom -Path $alpha19ManifestPath -Text ((ConvertTo-Json -InputObject $alpha19Manifest -Depth 12) + [Environment]::NewLine)
    $alpha19Package = Assert-PublishPackage -PackageRoot $alpha19Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.19'
    Assert-True ($alpha19Package.Assets.Count -eq $alpha18Package.Assets.Count -and
        $alpha19Profile.AssetPathMap.Count -eq 41 -and $alpha19Profile.TestNames.Count -eq 40 -and
        [string]::Join('|', $alpha19Profile.TestNames) -ceq [string]::Join('|', $alpha18Profile.TestNames)) `
        'alpha.19 publisher accepts the unchanged 41-asset inventory and ordered 40-test sequence'
    Assert-True (@($alpha19Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'config.json' }).Count -eq 1 -and
        @($alpha19Package.Manifest.excluded_private_files | Where-Object { [string]$_ -ceq 'credentials/' }).Count -eq 1) `
        'alpha.19 manifest retains package-root configuration and credential exclusions'
    $alpha19Manifest.excluded_private_files = @($alpha19Manifest.excluded_private_files | Where-Object { [string]$_ -cne 'config.json' })
    Write-Utf8NoBom -Path $alpha19ManifestPath -Text ((ConvertTo-Json -InputObject $alpha19Manifest -Depth 12) + [Environment]::NewLine)
    Assert-Throws { Assert-PublishPackage -PackageRoot $alpha19Root -ExpectedCommit $fakeCommit -Tag 'v0.1.0-alpha.19' } `
        'alpha.19 publisher rejects a manifest that omits the package-root config exclusion'

    $stablePublishProfile = Set-PublishProfile -Tag 'v0.1.0'
    $stableRecords = @(Get-ExpectedStablePackageRecords)
    $expectedStableDirectories = @('runtime','runtime/docs','runtime/licenses','runtime/licenses/dmr_signal',
        'runtime/licenses/droidstar_mbe','runtime/private','runtime/ui','runtime/ui/windows')
    Assert-True (-not $script:publishIsPrerelease -and $stablePublishProfile.AssetPathMap.Count -eq 3 -and
        $stablePublishProfile.AssetPathMap.Contains('WIREX_Bridge_v0.1.0.zip') -and
        $stablePublishProfile.AssetPathMap.Contains('manifest.json') -and
        $stablePublishProfile.AssetPathMap.Contains('SHA256SUMS.txt')) `
        'v0.1.0 publisher uses prerelease=false and exactly ZIP, manifest, and checksum assets'
    Assert-True (@($stableRecords | ForEach-Object { [string]$_.Path } | Sort-Object -Unique).Count -eq $stableRecords.Count -and
        @($stableRecords | Where-Object { [string]$_.Path -ceq 'runtime/ui/windows/ChannelActivationState.psm1' -and
            [string]$_.AssetName -ceq 'runtime__ui__windows__channel-activation-state.psm1' }).Count -eq 1 -and
        $stablePublishProfile.Directories.Count -eq 8 -and
        [string]::Join('|', @($stablePublishProfile.Directories | Sort-Object -CaseSensitive)) -ceq
            [string]::Join('|', @($expectedStableDirectories | Sort-Object -CaseSensitive))) `
        'stable publisher inventory includes the new runtime module and exact eight-directory tree without runtime/tools'

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

    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.9')
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.1')
    [void](Set-PublishProfile -Tag 'v0.1.0-alpha.1')
    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    if (-not $SkipRepositoryGitChecks) {
        $realTagObject = 'refs/tags/v0.1.0-alpha.1^{commit}'
        $realTagCommit = Get-GitText -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', '--verify', $realTagObject)
        $realNotesPath = Join-Path $repositoryRoot 'docs/releases/v0.1.0-alpha.1.md'
        $realNotes = Get-PublishNotes -Path $realNotesPath -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit
        Assert-True (-not [string]::IsNullOrWhiteSpace($realNotes)) 'fixed release notes match both the real tag commit and current HEAD'
        Assert-Throws { Get-PublishNotes -Path (Join-Path $repositoryRoot 'README.md') -RepositoryRoot $repositoryRoot -ExpectedCommit $realTagCommit } 'non-release notes path is rejected'
    }
    $manifest.package_status = 'awaiting_root_audit'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'unapproved package status'
    $manifest.package_status = 'root_audit_passed'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")

    $readmePath = Join-Path $packageRoot 'README.md'
    $goodReadme = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $readmePath -Text 'tampered bytes'
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'file hash mismatch'
    Write-Utf8NoBom -Path $readmePath -Text $goodReadme

    $extraPath = Join-Path $packageRoot 'connection-profile.json'
    Write-Utf8NoBom -Path $extraPath -Text '{}'
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'unexpected private configuration file'
    Remove-Item -LiteralPath $extraPath -Force

    $record = @($manifest.files | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })[0]
    $record.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifest -Depth 12) + "`n")
    Assert-Throws { Assert-PublishPackage -PackageRoot $packageRoot -ExpectedCommit $fakeCommit } 'duplicate asset name'

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

    $mockDraft = [pscustomobject]@{
        id = 77
        tag_name = 'v0.1.0-alpha.1'
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
        tag_name = 'v0.1.0-alpha.1'
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
    New-Item -ItemType Directory -Path $preflightRepo -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'tools') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'docs/releases') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'download-release.ps1') -Destination (Join-Path $preflightRepo 'tools/download-release.ps1')
    foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12')) {
        Write-Utf8NoBom -Path (Join-Path $preflightRepo ('docs/releases/' + $tag + '.md')) -Text ('Synthetic offline release notes for ' + $tag + "`n")
    }
    $gitInit = @(& git -C $preflightRepo init --quiet 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the temporary offline Git repository.' }
    foreach ($gitSetting in @(
        @('config', 'user.name', 'WIREX Offline Test'),
        @('config', 'user.email', 'wirex-offline-test@example.invalid'),
        @('remote', 'add', 'origin', $script:repositoryUrl),
        @('add', '--', 'tools/download-release.ps1', 'docs/releases/v0.1.0-alpha.1.md', 'docs/releases/v0.1.0-alpha.2.md', 'docs/releases/v0.1.0-alpha.3.md', 'docs/releases/v0.1.0-alpha.4.md', 'docs/releases/v0.1.0-alpha.5.md', 'docs/releases/v0.1.0-alpha.6.md', 'docs/releases/v0.1.0-alpha.7.md', 'docs/releases/v0.1.0-alpha.8.md', 'docs/releases/v0.1.0-alpha.9.md', 'docs/releases/v0.1.0-alpha.10.md', 'docs/releases/v0.1.0-alpha.11.md', 'docs/releases/v0.1.0-alpha.12.md'),
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
    New-Item -ItemType Directory -Path (Join-Path $preflightRepo 'build/_work') -Force | Out-Null
    foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12')) {
        $sourcePackage = switch ($tag) {
            'v0.1.0-alpha.1' { $packageRoot; break }
            'v0.1.0-alpha.2' { $alpha2Root; break }
            'v0.1.0-alpha.3' { $alpha3Root; break }
            'v0.1.0-alpha.4' { $alpha4Root; break }
            'v0.1.0-alpha.5' { $alpha5Root; break }
            'v0.1.0-alpha.6' { $alpha6Root; break }
            'v0.1.0-alpha.7' { $alpha7Root; break }
            'v0.1.0-alpha.8' { $alpha8Root; break }
            'v0.1.0-alpha.9' { $alpha9Root; break }
            'v0.1.0-alpha.10' { $alpha10Root; break }
            'v0.1.0-alpha.11' { $alpha11Root; break }
            'v0.1.0-alpha.12' { $alpha12Root; break }
        }
        $targetPackage = Join-Path $preflightRepo ('build/releases/' + $tag)
        $targetParent = Split-Path -Parent $targetPackage
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        Copy-Item -LiteralPath $sourcePackage -Destination $targetPackage -Recurse
        $sourceManifestText = switch ($tag) {
            'v0.1.0-alpha.1' { $validManifestJson; break }
            'v0.1.0-alpha.2' { $validAlpha2ManifestJson; break }
            'v0.1.0-alpha.3' { $validAlpha3ManifestJson; break }
            'v0.1.0-alpha.4' { $validAlpha4ManifestJson; break }
            'v0.1.0-alpha.5' { $validAlpha5ManifestJson; break }
            'v0.1.0-alpha.6' { $validAlpha6ManifestJson; break }
            'v0.1.0-alpha.7' { $validAlpha7ManifestJson; break }
            'v0.1.0-alpha.8' { $validAlpha8ManifestJson; break }
            'v0.1.0-alpha.9' { $validAlpha9ManifestJson; break }
            'v0.1.0-alpha.10' { $validAlpha10ManifestJson; break }
            'v0.1.0-alpha.11' { $validAlpha11ManifestJson; break }
            'v0.1.0-alpha.12' { $validAlpha12ManifestJson; break }
        }
        $preflightManifest = $sourceManifestText | ConvertFrom-Json
        $preflightManifest.source.commit = $preflightCommit
        $preflightManifest.build.source_commit = $preflightCommit
        Write-Utf8NoBom -Path (Join-Path $targetPackage 'manifest.json') `
            -Text ((ConvertTo-Json -InputObject $preflightManifest -Depth 12) + "`n")
    }

    $helperTempBefore = @(Get-ChildItem -LiteralPath (Join-Path $preflightRepo 'build/_work') -Filter 'publish-helper-*.bin' -File -ErrorAction SilentlyContinue).Count
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
    foreach ($tag in @('v0.1.0-alpha.1', 'v0.1.0-alpha.2', 'v0.1.0-alpha.3', 'v0.1.0-alpha.4', 'v0.1.0-alpha.5', 'v0.1.0-alpha.6', 'v0.1.0-alpha.7', 'v0.1.0-alpha.8', 'v0.1.0-alpha.9', 'v0.1.0-alpha.10', 'v0.1.0-alpha.11', 'v0.1.0-alpha.12')) {
        $script:preflightBoundaryReached = $false
        $boundaryMessage = ''
        try {
            Invoke-ReleasePublisher -PackagePath (Join-Path $preflightRepo ('build/releases/' + $tag)) `
                -Commit $preflightCommit -NotesFile (Join-Path $preflightRepo ('docs/releases/' + $tag + '.md')) `
                -PublisherMode 'Draft' -RepositoryRoot $preflightRepo -Tag $tag
        } catch { $boundaryMessage = $_.Exception.Message }
        Assert-True ($script:preflightBoundaryReached -and $boundaryMessage -ceq 'OFFLINE_TEST_STOP_AT_NETWORK_BOUNDARY') `
            ($tag + ' clean dry package, tag helper blob and notes preflight reaches the mocked network boundary; local result=' + $boundaryMessage)
    }
    $helperTempAfter = @(Get-ChildItem -LiteralPath (Join-Path $preflightRepo 'build/_work') -Filter 'publish-helper-*.bin' -File -ErrorAction SilentlyContinue).Count
    Assert-True (-not $script:credentialAttempted -and $script:mockCalls.Count -eq 8) 'clean dry preflights stop before credentials and API requests'
    Assert-True ($helperTempAfter -eq $helperTempBefore) 'temporary byte-exact helper blobs are removed after the offline boundary stop'

    $gitEvidence = if ($SkipRepositoryGitChecks) { 'repository Git checks skipped' } else { 'repository Git checks passed' }
    Write-Output ('Publisher offline assertions passed: ' + $script:assertions + '; ' + $gitEvidence + '; no network requests or credentials were used.')
} finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PublishPathWithin -Path $testRoot -Directory (Join-Path $repositoryRoot 'build/_work')) -and
        [System.IO.Path]::GetFileName($testRoot) -match '^publish-release-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
