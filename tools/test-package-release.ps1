[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:assertions = 0
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'package-release.ps1')

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    $script:assertions++
    if ($Actual -cne $Expected) { throw "断言失败：$Message；实际='$Actual'，预期='$Expected'" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw "断言失败：$Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $script:assertions++
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "断言失败：应拒绝 $Message" }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-StableArchiveVariant {
    param([string]$SourcePath,[string]$DestinationPath,[string]$RenameFrom,[string]$RenameTo,
        [string]$AttributesPath,[int]$Attributes)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $sourceArchive = [System.IO.Compression.ZipFile]::OpenRead($SourcePath)
    $outputStream = [System.IO.File]::Open($DestinationPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $destinationArchive = $null
    try {
        $destinationArchive = [System.IO.Compression.ZipArchive]::new($outputStream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
        foreach ($sourceEntry in $sourceArchive.Entries) {
            $targetName = if ([string]$sourceEntry.FullName -ceq $RenameFrom) { $RenameTo } else { [string]$sourceEntry.FullName }
            $targetEntry = $destinationArchive.CreateEntry($targetName,[System.IO.Compression.CompressionLevel]::Optimal)
            $targetEntry.ExternalAttributes = if ([string]$sourceEntry.FullName -ceq $AttributesPath) { $Attributes } else { [int]$sourceEntry.ExternalAttributes }
            $inputStream = $sourceEntry.Open()
            $entryStream = $targetEntry.Open()
            try { $inputStream.CopyTo($entryStream) } finally { $entryStream.Dispose(); $inputStream.Dispose() }
        }
    } finally {
        if ($null -ne $destinationArchive) { $destinationArchive.Dispose() }
        $outputStream.Dispose()
        $sourceArchive.Dispose()
    }
}

function New-SyntheticStablePackage {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [Parameter(Mandatory=$true)][string]$FixturePath)
    $profile = Set-ReleaseVersion -Version 'v0.1.0'
    [System.IO.Directory]::CreateDirectory($PackageRoot) | Out-Null
    foreach ($relativeDirectory in $profile.Directories) {
        [System.IO.Directory]::CreateDirectory((Join-Path $PackageRoot ([string]$relativeDirectory).Replace('/', [System.IO.Path]::DirectorySeparatorChar))) | Out-Null
    }
    foreach ($relativePath in $profile.PackageFiles | Where-Object { $_ -cne 'manifest.json' }) {
        $fullPath = Join-Path $PackageRoot ([string]$relativePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not [System.IO.Directory]::Exists($parent)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
        if ([string]$relativePath -ceq 'runtime/private/device-y.bin') {
            Copy-Item -LiteralPath $FixturePath -Destination $fullPath -ErrorAction Stop
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic v0.1.0 package file: ' + [string]$relativePath)
        }
    }

    $records = @()
    foreach ($relativePath in $profile.PackageFiles | Where-Object { $_ -cne 'manifest.json' }) {
        $records += ,(Get-ReleaseFileRecord -PackageRoot $PackageRoot -RelativePath ([string]$relativePath) `
            -Source 'synthetic v0.1.0 package fixture')
    }
    $recordByPath = @{}
    foreach ($record in $records) { $recordByPath[[string]$record.path] = $record }
    $commit = '0123456789abcdef0123456789abcdef01234567'
    $manifest = [ordered]@{
        schema_version = 1
        package_kind = 'wirex_bridge_stable_release_green_directory'
        package_status = 'awaiting_root_audit'
        version = 'v0.1.0'
        tag_candidate = 'v0.1.0'
        tag_created = $false
        github_release_published = $false
        source = [ordered]@{ repository='https://github.com/iCassius/WIREX_Bridge.git'; commit=$commit; working_tree_clean=$true }
        build = [ordered]@{
            source_commit=$commit; source_tree_clean=$true; compile_only=$false; build_completed=$true
            output_directory='build/_work/synthetic-native-build'; evidence_log='build/_work/synthetic-native-build.log'
            evidence_log_sha256=('1' * 64); provenance_asset='build-provenance.json'
            provenance_sha256=[string]$recordByPath['build-provenance.json'].sha256; result='passed'
            passed_test_count=$profile.TestNames.Count; passed_tests=@($profile.TestNames)
            compiler_warnings=0; compiler_errors=0; executable_sha256=[string]$recordByPath['runtime/wirex_bridge.exe'].sha256
        }
        release_scope = $profile.ReleaseScope
        not_included = @($profile.NotIncluded)
        hardware_validation = [ordered]@{
            current_release_hil='not performed'; current_profile_and_volume_settings='not tested'
            previous_direct_parrot_echo='older source only'; previous_tg91_listening='older source only'
            radio_state='unknown'; rf_transmission='not tested'
        }
        approved_y_fixture = [ordered]@{
            path='runtime/private/device-y.bin'; length_bytes=100
            sha256=(Get-FileHash -LiteralPath $FixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        excluded_private_files = @(Get-ReleaseExcludedPrivateFiles -Version 'v0.1.0')
        runtime_directories = @($profile.Directories | Where-Object { [string]$_ -like 'runtime*' })
        manifest_asset_name = 'manifest.json'
        files = @($records)
        launcher_build = [ordered]@{
            source_commit=$commit; source_path='ui/launcher/WirexBridgeLauncher.cs'; source_sha256=('2' * 64)
            compiler_family='Microsoft .NET Framework csc.exe'; compiler_version='synthetic-test'
            target='x64 Windows GUI executable'; output_directory='build/_work/synthetic-launcher-build'
            executable_asset='WirexBridge.exe'; executable_sha256=[string]$recordByPath['WirexBridge.exe'].sha256
            provenance_asset='launcher-build-provenance.json'
            provenance_sha256=[string]$recordByPath['launcher-build-provenance.json'].sha256
            build_log_path='build/_work/synthetic-launcher-build/launcher-build.log'; build_log_sha256=('3' * 64)
        }
    }
    Write-Utf8NoBom -Path (Join-Path $PackageRoot 'manifest.json') -Text ((ConvertTo-Json -InputObject $manifest -Depth 16) + "`n")
}

$stableProfile = Set-ReleaseVersion -Version 'v0.1.0'
$assetPairs = @(
    @{ Path='runtime/wirex_bridge.exe'; Name='runtime__wirex_bridge.exe' },
    @{ Path='runtime/docs/连接配置.md'; Name='runtime__docs__connection-profile.md' },
    @{ Path='runtime/docs/音量调节.md'; Name='runtime__docs__audio-gain.md' },
    @{ Path='runtime/licenses/dmr_signal/NOTICE.md'; Name='runtime__licenses__dmr-signal__NOTICE.md' },
    @{ Path='runtime/licenses/droidstar_mbe/ISC-NOTICE.txt'; Name='runtime__licenses__droidstar-mbe__ISC-NOTICE.txt' },
    @{ Path='runtime/private/device-y.bin'; Name='runtime__private__device-y.bin' }
)
foreach ($pair in $assetPairs) {
    Assert-Equal (Get-ReleaseAssetName -RelativePath $pair.Path) $pair.Name "ASCII asset 映射 $($pair.Path)"
    Assert-True ($pair.Name -cmatch '^[A-Za-z0-9._-]+$') "asset_name 仅含 ASCII 字符：$($pair.Name)"
}
$mappedPaths = @(Get-ExpectedReleasePackageFiles | Where-Object { $_ -cne 'manifest.json' })
$mappedAssetNames = @($mappedPaths | ForEach-Object { Get-ReleaseAssetName -RelativePath $_ })
Assert-True (@($mappedAssetNames | Sort-Object -Unique).Count -eq $mappedAssetNames.Count) `
    '所有固定文件的 GitHub asset 名称均唯一'
Assert-True (@($mappedAssetNames | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' }).Count -eq 0) `
    '所有固定文件的 GitHub asset 名称均为 ASCII'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0') 'stable v0.1.0 has its own explicit release profile'
Assert-True (Test-ReleaseVersion -Value 'v0.1.1-test.2') 'R126 ZIP-only prerelease profile is explicitly registered'
Assert-True (Test-ReleaseVersion -Value 'v0.1.1') 'R126 ZIP-only final profile is explicitly registered'
foreach ($retiredVersion in @('v0.1.0-alpha.1', 'v0.1.0-alpha.9', 'v0.1.0-alpha.19')) {
    Assert-True (-not (Test-ReleaseVersion -Value $retiredVersion)) ('retired alpha profile is no longer registered: ' + $retiredVersion)
}
Assert-True (-not (Test-ReleaseVersion -Value 'v0.2.0-alpha.1')) '未登记的版本必须拒绝'
Assert-True (-not (Test-ReleaseVersion -Value 'V0.1.0')) '版本匹配区分大小写'
Assert-Throws { Get-ReleaseAssetName -RelativePath 'runtime/docs/未知文件.md' } '未列入白名单的文件路径'
Assert-Throws { Get-ReleaseAssetName -RelativePath '../private/secret.txt' } '越界路径'
Assert-Throws { Get-ReleaseAssetName -RelativePath 'start-ui.cmd' } 'stable profile does not accept retired alpha root entry points'

$stableProfile = Get-ReleaseProfile -Version 'v0.1.0'
[void](Set-ReleaseVersion -Version 'v0.1.0')
Assert-Equal @($stableProfile.PackageFiles | Sort-Object -Unique).Count $stableProfile.PackageFiles.Count 'stable folder layout has no duplicate file paths'
Assert-Equal $stableProfile.AssetMap.Count ($stableProfile.PackageFiles.Count - 1) 'stable folder manifest has one unique asset name per non-manifest file'
Assert-Equal @($stableProfile.PackageFiles | Where-Object { $_ -notmatch '/' }).Count 6 'stable package root contains exactly six necessary files'
Assert-True (@($stableProfile.SourceFiles | Where-Object {
    [string]$_.Source -ceq 'ui\windows\ChannelActivationState.psm1' -and
    [string]$_.Destination -ceq 'runtime/ui/windows/ChannelActivationState.psm1'
}).Count -eq 1 -and $stableProfile.PackageFiles -ccontains 'runtime/ui/windows/ChannelActivationState.psm1' -and
    [string]$stableProfile.AssetMap['runtime/ui/windows/ChannelActivationState.psm1'] -ceq 'runtime__ui__windows__channel-activation-state.psm1') `
    'stable profile maps the new channel activation runtime dependency to one source path and one ASCII asset name'
Assert-True ($stableProfile.PackageFiles -ccontains 'runtime/private/device-y.bin') `
    'stable runtime keeps the approved HRI protocol template at runtime/private/device-y.bin'
Assert-True (@($stableProfile.PackageFiles | Where-Object { $_ -match '^([^/]+\.(cmd|ps1))$' }).Count -eq 0) `
    'stable package root contains no CMD or PowerShell user entry point'
Assert-True (@($stableProfile.PackageFiles | Where-Object { $_ -match '(^|/)tests?/' -or $_ -match 'test-' }).Count -eq 0) `
    'stable runtime contains no test script or development test assets'
$stablePathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($relativePath in $stableProfile.PackageFiles) {
    Assert-True ($stablePathSet.Add([string]$relativePath)) ('stable folder path is unique without case sensitivity: ' + [string]$relativePath)
}
$stableAssetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($relativePath in $stableProfile.PackageFiles | Where-Object { $_ -cne 'manifest.json' }) {
    Assert-True ($stableAssetSet.Add((Get-ReleaseAssetName -RelativePath ([string]$relativePath)))) `
        ('stable asset name is unique without case sensitivity: ' + [string]$relativePath)
}
Assert-True ((Get-ReleaseAssetName -RelativePath 'runtime/wirex_bridge.exe') -ceq 'runtime__wirex_bridge.exe') `
    'stable Native runtime has a fixed asset name'

$expectedTests = @(Get-ExpectedReleaseTests)
Assert-Equal $expectedTests.Count 40 'v0.1.0 builder 测试清单数'
Assert-True (@($expectedTests | Select-Object -Unique).Count -eq $expectedTests.Count) 'builder 测试名称不重复'
$builderTestLines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-bm-bridge.ps1') -Encoding UTF8 |
    Where-Object { $_ -match "^\s*@\{\s*Name='[^']+';\s*Source='tests\\" })
$builderTestNames = @($builderTestLines | ForEach-Object { [regex]::Match($_, "Name='([^']+)'").Groups[1].Value })
# R128：builder 在 v0.1.0 的 40 项之后追加 engine_test；v0.1.0 序列本身保持不变。
$currentBuilderTests = @($expectedTests) + @('engine_test')
Assert-Equal ([string]::Join('|', $builderTestNames)) ([string]::Join('|', $currentBuilderTests)) `
    'current builder test list is the fixed v0.1.0 sequence followed by engine_test'
foreach ($zipVersion in @('v0.1.1-test.2', 'v0.1.1')) {
    Assert-Equal ([string]::Join('|', (Get-ReleaseProfile -Version $zipVersion).TestNames)) ([string]::Join('|', $currentBuilderTests)) `
        ($zipVersion + ' uses the current builder Native test sequence')
}
Assert-Equal ([string]$stableProfile.PackageReadme) 'docs\releases\v0.1.0-package-README.md' 'v0.1.0 profile selects its package README'
Assert-True ([System.IO.File]::Exists((Join-Path $repositoryRoot $stableProfile.PackageReadme))) 'v0.1.0 package README source exists'
foreach ($sourceEntry in $stableProfile.SourceFiles) {
    Assert-True ([System.IO.File]::Exists((Join-Path $repositoryRoot ([string]$sourceEntry.Source)))) `
        ('v0.1.0 source file exists in the repository: ' + [string]$sourceEntry.Source)
}
Assert-Equal @($stableProfile.SourceFiles).Count 36 'v0.1.0 profile keeps the 36 published source mappings'
Assert-Equal $stableProfile.AssetMap.Count 42 'v0.1.0 profile keeps the 42 published manifest file records'
Assert-Equal ([string]::Join('|', $stableProfile.Directories)) `
    'runtime|runtime/docs|runtime/licenses|runtime/licenses/dmr_signal|runtime/licenses/droidstar_mbe|runtime/private|runtime/ui|runtime/ui/windows' `
    'v0.1.0 profile keeps the published runtime directory list'
$stableExcluded = @(Get-ReleaseExcludedPrivateFiles -Version 'v0.1.0')
foreach ($requiredExcludedPath in @('config.json', 'config.*.backup*', 'credentials/', 'tempSecrets/', 'runtime/config.json', 'runtime/private/user-config/')) {
    Assert-True ($stableExcluded -ccontains $requiredExcludedPath) ('v0.1.0 manifest excludes ' + $requiredExcludedPath)
}

$testRoot = Join-Path $repositoryRoot ('build\_work\package-release-test-' + [guid]::NewGuid().ToString('N'))
$buildDirectory = Join-Path $testRoot 'wirex-bridge-0123456-20261025-000000'
$buildLogPath = Join-Path $testRoot 'synthetic-build.log'
$approvedFixturePath = Join-Path $repositoryRoot 'private\fixtures\device-y.bin'
[void](Test-ApprovedYFixture -Path $approvedFixturePath)
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
try {
    $fakeExePath = Join-Path $buildDirectory 'wirex_bridge.exe'
    Write-Utf8NoBom -Path $fakeExePath -Text 'synthetic-only; not an executable'
    $fakeExe = Get-Item -LiteralPath $fakeExePath
    $fakeExeHash = (Get-FileHash -LiteralPath $fakeExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $buildRelative = (Get-RepoRelativePath -RepositoryRoot $repositoryRoot -Path $buildDirectory)
    $testRecords = @($expectedTests | ForEach-Object {
        [ordered]@{ name=$_; result='passed'; exit_code=0 }
    })
    $provenance = [ordered]@{
        schema_version = 1
        source_commit = '0123456789abcdef0123456789abcdef01234567'
        source_tree_clean = $true
        compile_only = $false
        build_completed = $true
        result = 'passed'
        output_directory = $buildRelative
        started_utc = '2026-10-25T00:00:00.0000000Z'
        completed_utc = '2026-10-25T00:01:00.0000000Z'
        executable = [ordered]@{
            path='wirex_bridge.exe'
            length_bytes=[long]$fakeExe.Length
            sha256=$fakeExeHash
        }
        tests = $testRecords
    }
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    $logLines = @('DroidStar 固定 commit 的 57 个本地源文件 SHA-256 全部通过。')
    foreach ($testName in $expectedTests) { $logLines += '运行离线测试：' + $testName }
    $logLines += '构建产物：' + $buildDirectory
    $logLines += '可执行文件：' + $fakeExePath
    $validLogText = ($logLines -join "`n") + "`n"
    Write-Utf8NoBom -Path $buildLogPath -Text $validLogText

    $syntheticEvidence = Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
        -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
        -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    Assert-Equal $syntheticEvidence.passed_test_count 40 'v0.1.0 合成 provenance 的结构和测试数验证'
    Assert-Equal $syntheticEvidence.executable_sha256 $fakeExeHash '合成 EXE 文件 hash 一致性验证'

    $provenance.output_directory = 'C:/Users/example/build-output'
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } '含绝对本机路径的 provenance'
    $provenance.output_directory = $buildRelative
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")

    $provenance.source_tree_clean = $false
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } 'dirty source provenance'
    $provenance.source_tree_clean = $true
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")

    $provenance.compile_only = $true
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } 'CompileOnly provenance'
    $provenance.compile_only = $false
    $provenance.tests = @($testRecords | Select-Object -First ($testRecords.Count - 1))
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } '缺少一项测试的 provenance'
    $provenance.tests = $testRecords
    $provenance.executable.sha256 = ('0' * 64)
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } 'EXE hash 与 provenance 不符'
    $provenance.executable.sha256 = $fakeExeHash
    Write-Utf8NoBom -Path (Join-Path $buildDirectory 'build-provenance.json') `
        -Text ((ConvertTo-Json -InputObject $provenance -Depth 8) + "`n")
    Write-Utf8NoBom -Path $buildLogPath -Text ($validLogText + 'warning C4996: synthetic warning')
    Assert-Throws {
        Test-ReleaseBuildEvidence -RepositoryRoot $repositoryRoot `
            -SourceCommit '0123456789abcdef0123456789abcdef01234567' `
            -BuildDirectory $buildDirectory -BuildLogPath $buildLogPath
    } '包含编译警告的构建日志'
    Write-Utf8NoBom -Path $buildLogPath -Text $validLogText

    $stablePackageRoot = Join-Path $testRoot 'package-v0.1.0-stable'
    New-SyntheticStablePackage -PackageRoot $stablePackageRoot -FixturePath $approvedFixturePath
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0') -eq $null) `
        'stable synthetic folder package validates the exact root/runtime layout and HRI template hash'
    $sharedStableLimits = Get-WirexStableReleaseLimits
    Assert-True ((Test-WirexStableLengthWithinLimit -Length ([long]$sharedStableLimits.MaximumArchiveBytes) -MaximumBytes ([long]$sharedStableLimits.MaximumArchiveBytes)) -and
        -not (Test-WirexStableLengthWithinLimit -Length ([long]$sharedStableLimits.MaximumArchiveBytes + 1) -MaximumBytes ([long]$sharedStableLimits.MaximumArchiveBytes))) `
        'shared stable ZIP size boundary accepts 512 MiB and rejects one byte above it'
    $launcherPerFileMaximum = [long](Get-WirexStableMaximumFileBytes -Path 'WirexBridge.exe')
    Assert-True ((Test-WirexStableLengthWithinLimit -Length $launcherPerFileMaximum -MaximumBytes $launcherPerFileMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($launcherPerFileMaximum + 1) -MaximumBytes $launcherPerFileMaximum)) `
        'shared stable per-file boundary rejects the first byte above the launcher cap'
    $bridgeUiPerFileMaximum = [long](Get-WirexStableMaximumFileBytes -Path 'runtime/ui/windows/bridge-ui.ps1')
    Assert-True ($bridgeUiPerFileMaximum -eq 4MB -and
        (Test-WirexStableLengthWithinLimit -Length $bridgeUiPerFileMaximum -MaximumBytes $bridgeUiPerFileMaximum) -and
        -not (Test-WirexStableLengthWithinLimit -Length ($bridgeUiPerFileMaximum + 1) -MaximumBytes $bridgeUiPerFileMaximum)) `
        'shared stable bridge-ui script limit preserves the established 4 MiB cap'
    $stableDistributionRoot = Join-Path $testRoot 'stable-distribution'
    $stableDistribution = New-StableReleaseDistribution -PackageRoot $stablePackageRoot `
        -RepositoryRoot $repositoryRoot -DistributionDirectory $stableDistributionRoot
    Assert-True ([System.IO.File]::Exists($stableDistribution.archive) -and [System.IO.File]::Exists($stableDistribution.manifest) -and
        [System.IO.File]::Exists($stableDistribution.checksum)) `
        'stable packaging creates ZIP, byte-exact manifest, and detached checksum outside the folder candidate'
    $distributionFiles = @(Get-ChildItem -LiteralPath $stableDistributionRoot -File -Recurse | ForEach-Object { $_.Name } | Sort-Object -CaseSensitive)
    Assert-True ($distributionFiles.Count -eq 3 -and
        @($distributionFiles | Where-Object { [string]$_ -ceq 'WIREX_Bridge_v0.1.0.zip' }).Count -eq 1 -and
        @($distributionFiles | Where-Object { [string]$_ -ceq 'manifest.json' }).Count -eq 1 -and
        @($distributionFiles | Where-Object { [string]$_ -ceq 'SHA256SUMS.txt' }).Count -eq 1) `
        'stable release distribution contains exactly the three approved top-level assets'
    $packageManifestBytes = [System.IO.File]::ReadAllBytes((Join-Path $stablePackageRoot 'manifest.json'))
    $distributionManifestBytes = [System.IO.File]::ReadAllBytes($stableDistribution.manifest)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$packageManifestBytes,[byte[]]$distributionManifestBytes) -and
        $stableDistribution.manifest_sha256 -ceq (Get-FileHash -LiteralPath $stableDistribution.manifest -Algorithm SHA256).Hash.ToLowerInvariant()) `
        'standalone distribution manifest preserves the exact audited manifest bytes and hash'
    $stableArchiveFacts = Test-ReleaseArchiveMatchesPackage -PackageRoot $stablePackageRoot -ArchivePath $stableDistribution.archive
    Assert-Equal $stableArchiveFacts.EntryCount $stableProfile.PackageFiles.Count 'stable ZIP contains exactly the audited folder files'
    Assert-True ($stableArchiveFacts.ManifestSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $stablePackageRoot 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()) `
        'stable ZIP includes the exact standalone manifest bytes'
    $renamedArchive = Join-Path $testRoot 'stable-case-renamed.zip'
    New-StableArchiveVariant -SourcePath $stableDistribution.archive -DestinationPath $renamedArchive `
        -RenameFrom 'runtime/ui/windows/ChannelActivationState.psm1' -RenameTo 'runtime/ui/windows/channelActivationState.psm1' `
        -AttributesPath '' -Attributes 0
    Assert-Throws { Test-ReleaseArchiveMatchesPackage -PackageRoot $stablePackageRoot -ArchivePath $renamedArchive } `
        'stable packager archive verifier rejects a single non-canonical case variant'
    foreach ($typeCase in @(
        [pscustomobject]@{ Name='symlink'; Attributes=([int]0xa000 -shl 16) },
        [pscustomobject]@{ Name='fifo'; Attributes=([int]0x1000 -shl 16) },
        [pscustomobject]@{ Name='character-device'; Attributes=([int]0x2000 -shl 16) },
        [pscustomobject]@{ Name='block-device'; Attributes=([int]0x6000 -shl 16) },
        [pscustomobject]@{ Name='socket'; Attributes=([int]0xc000 -shl 16) },
        [pscustomobject]@{ Name='directory'; Attributes=([int]0x4000 -shl 16) },
        [pscustomobject]@{ Name='dos-directory-bit'; Attributes=0x10 }
    )) {
        $invalidTypeArchive = Join-Path $testRoot ('stable-type-' + [string]$typeCase.Name + '.zip')
        New-StableArchiveVariant -SourcePath $stableDistribution.archive -DestinationPath $invalidTypeArchive `
            -RenameFrom '' -RenameTo '' -AttributesPath 'WirexBridge.exe' -Attributes ([int]$typeCase.Attributes)
        Assert-Throws { Test-ReleaseArchiveMatchesPackage -PackageRoot $stablePackageRoot -ArchivePath $invalidTypeArchive } `
            ('stable packager archive verifier rejects ZIP entry type ' + [string]$typeCase.Name)
    }
    Assert-True ($stableDistribution.archive_sha256 -ceq (Get-FileHash -LiteralPath $stableDistribution.archive -Algorithm SHA256).Hash.ToLowerInvariant()) `
        'stable distribution metadata records the archive SHA-256'
    Assert-True ($stableDistribution.archive_uncompressed_bytes -gt 0) 'stable distribution records bounded uncompressed size'
    $stableChecksums = [System.IO.File]::ReadAllText($stableDistribution.checksum, [System.Text.Encoding]::UTF8)
    Assert-True ($stableChecksums.Contains($stableDistribution.archive_sha256 + '  WIREX_Bridge_v0.1.0.zip') -and
        $stableChecksums.Contains($stableArchiveFacts.ManifestSha256 + '  manifest.json')) `
        'detached SHA256SUMS covers both the ZIP and standalone manifest'
    $stableZip = [System.IO.Compression.ZipFile]::OpenRead($stableDistribution.archive)
    try {
        $stableZipPaths = @($stableZip.Entries | ForEach-Object { [string]$_.FullName })
        Assert-True ($stableZipPaths -ccontains 'WirexBridge.exe' -and $stableZipPaths -ccontains 'runtime/private/device-y.bin') `
            'stable ZIP root contains the launcher and the approved runtime HRI template'
        Assert-True (@($stableZipPaths | Where-Object { $_ -match '(^|/)config\.json$|(^|/)logs/|\.log$' }).Count -eq 0) `
            'stable ZIP contains no user config or runtime logs'
    } finally { $stableZip.Dispose() }

    foreach ($unsafeZipPath in @('../escape.txt','runtime/../../escape.txt','runtime/config.json:stream','runtime\\escape.txt')) {
        Assert-Throws { Assert-ReleaseArchivePath -Path $unsafeZipPath } ('unsafe ZIP entry path is rejected: ' + $unsafeZipPath)
    }
    $caseCollisionZip = Join-Path $testRoot 'stable-case-collision.zip'
    Copy-Item -LiteralPath $stableDistribution.archive -Destination $caseCollisionZip
    $caseArchive = [System.IO.Compression.ZipFile]::Open($caseCollisionZip, [System.IO.Compression.ZipArchiveMode]::Update)
    try { [void]$caseArchive.CreateEntry('wirexbridge.exe') } finally { $caseArchive.Dispose() }
    Assert-Throws { Test-ReleaseArchiveMatchesPackage -PackageRoot $stablePackageRoot -ArchivePath $caseCollisionZip } `
        'ZIP entry that collides with an existing Windows path by letter case is rejected'
    $symlinkZip = Join-Path $testRoot 'stable-symlink.zip'
    Copy-Item -LiteralPath $stableDistribution.archive -Destination $symlinkZip
    $symlinkArchive = [System.IO.Compression.ZipFile]::Open($symlinkZip, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = @($symlinkArchive.Entries | Where-Object { $_.FullName -ceq 'WirexBridge.exe' })[0]
        $entry.ExternalAttributes = [int](0xa000 -shl 16)
    } finally { $symlinkArchive.Dispose() }
    Assert-Throws { Test-ReleaseArchiveMatchesPackage -PackageRoot $stablePackageRoot -ArchivePath $symlinkZip } `
        'ZIP Unix symbolic-link entry is rejected'
    Assert-Throws { New-StableReleaseDistribution -PackageRoot $stablePackageRoot -RepositoryRoot $repositoryRoot `
        -DistributionDirectory $stableDistributionRoot } 'stable ZIP and checksum are not overwritten'

    Write-Utf8NoBom -Path (Join-Path $stablePackageRoot 'config.json') -Text '{"synthetic":"private user config"}'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0' } `
        'stable package inventory rejects config.json before ZIP generation'
    Remove-Item -LiteralPath (Join-Path $stablePackageRoot 'config.json') -Force -ErrorAction Stop
    $stableManifestPath = Join-Path $stablePackageRoot 'manifest.json'
    $stableReadme = Join-Path $stablePackageRoot 'README.md'
    $stableReadmeText = [System.IO.File]::ReadAllText($stableReadme, [System.Text.Encoding]::UTF8)
    Write-Utf8NoBom -Path $stableReadme -Text 'tampered content'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0' } '文件内容与manifest SHA不符'
    Write-Utf8NoBom -Path $stableReadme -Text $stableReadmeText
    $manifestObject = [System.IO.File]::ReadAllText($stableManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $exeRecord = @($manifestObject.files | Where-Object { [string]$_.path -ceq 'runtime/wirex_bridge.exe' })[0]
    $exeRecord.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $stableManifestPath -Text ((ConvertTo-Json -InputObject $manifestObject -Depth 16) + "`n")
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0' } '占用manifest asset名的普通文件'
    $exeRecord.asset_name = 'runtime__wirex_bridge.exe'
    Write-Utf8NoBom -Path $stableManifestPath -Text ((ConvertTo-Json -InputObject $manifestObject -Depth 16) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0') -eq $null) `
        'stable synthetic folder validates again after the manifest is restored'
    $forbiddenPath = Join-Path $stablePackageRoot 'runtime\connection-profile.json'
    Write-Utf8NoBom -Path $forbiddenPath -Text '{"gateway_id":1}'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0' } '额外连接配置文件'
    Remove-Item -LiteralPath $forbiddenPath -Force -ErrorAction Stop

    $badFixture = Join-Path $testRoot 'wrong-y.bin'
    [System.IO.File]::WriteAllBytes($badFixture, (New-Object byte[] 100))
    Assert-Throws { Test-ApprovedYFixture -Path $badFixture } '内容不同的 100 字节 Y 素材'
    Copy-Item -LiteralPath $badFixture -Destination (Join-Path $stablePackageRoot 'runtime\private\device-y.bin') -Force
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $stablePackageRoot -Version 'v0.1.0' } '被替换的 Y 素材'

    Write-Host ("Release packager 离线合成断言通过：{0}；未生成发布包，未运行 EXE。" -f $script:assertions)
}
finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PathWithinDirectory -Path $testRoot -Directory (Join-Path $repositoryRoot 'build\_work')) -and
        ([System.IO.Path]::GetFileName($testRoot).StartsWith('package-release-test-', [System.StringComparison]::Ordinal))) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
