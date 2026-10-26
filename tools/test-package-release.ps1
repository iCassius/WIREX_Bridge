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

$assetPairs = @(
    @{ Path='wirex_bridge.exe'; Name='wirex_bridge.exe' },
    @{ Path='docs/连接配置.md'; Name='docs__connection-profile.md' },
    @{ Path='docs/音量调节.md'; Name='docs__audio-gain.md' },
    @{ Path='licenses/dmr_signal/NOTICE.md'; Name='licenses__dmr-signal__NOTICE.md' },
    @{ Path='licenses/droidstar_mbe/ISC-NOTICE.txt'; Name='licenses__droidstar-mbe__ISC-NOTICE.txt' },
    @{ Path='private/device-y.bin'; Name='private__device-y.bin' }
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
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.1') '候选版本格式可用'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.2') 'alpha.2 明确版本允许'
Assert-True (Test-ReleaseVersion -Value 'v0.1.0-alpha.3') 'alpha.3 明确版本允许'
Assert-True (-not (Test-ReleaseVersion -Value 'v0.1.0')) '正式版本格式不能混入 alpha 标签'
Assert-True (-not (Test-ReleaseVersion -Value 'v0.2.0-alpha.1')) '未登记的 alpha 版本必须拒绝'
Assert-True (-not (Test-ReleaseVersion -Value 'V0.1.0-ALPHA.1')) '版本匹配区分大小写'
Assert-Throws { Get-ReleaseAssetName -RelativePath 'docs/未知文件.md' } '未列入白名单的文件路径'
Assert-Throws { Get-ReleaseAssetName -RelativePath '../private/secret.txt' } '越界路径'

$expectedTests = @(Get-ExpectedReleaseTests)
Assert-Equal $expectedTests.Count 27 '正式 builder 测试清单数'
Assert-True (@($expectedTests | Select-Object -Unique).Count -eq $expectedTests.Count) 'builder 测试名称不重复'
$alpha1Files = @(Get-ExpectedReleasePackageFiles)
Assert-Equal $alpha1Files.Count 17 'alpha.1 固定本地文件数含 manifest'
Assert-True ($alpha1Files -cnotcontains 'start-ui.cmd') 'alpha.1 清单不接收 alpha.2 UI 文件'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.2')
$alpha2Files = @(Get-ExpectedReleasePackageFiles)
$alpha2Tests = @(Get-ExpectedReleaseTests)
$alpha2Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.2'
Assert-Equal $alpha2Files.Count 27 'alpha.2 固定本地文件数含 manifest'
Assert-Equal $alpha2Tests.Count 28 'alpha.2 builder 测试数含 ui_pipe_test'
Assert-True ($alpha2Tests[14] -ceq 'bounded_pipe_writer_test' -and
    $alpha2Tests[15] -ceq 'ui_pipe_test' -and $alpha2Tests[16] -ceq 'console_lifecycle_test') `
    'alpha.2 ui_pipe_test 顺序与 builder 清单一致'
$builderTestLines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-bm-bridge.ps1') -Encoding UTF8 |
    Where-Object { $_ -match "^\s*@\{\s*Name='[^']+';\s*Source='tests\\" })
$builderTestNames = @($builderTestLines | ForEach-Object { [regex]::Match($_, "Name='([^']+)'").Groups[1].Value })
Assert-True ($alpha2Tests.Count -eq 28 -and $alpha2Tests[15] -ceq 'ui_pipe_test') `
    'alpha.2 retains its historical 28-test manifest independently of the current builder'
Assert-True ($alpha2Files -ccontains 'start-ui.cmd' -and $alpha2Files -ccontains 'start-ui.ps1' -and
    $alpha2Files -ccontains 'ui/windows/SettingsWindow.xaml') 'alpha.2 允许清单中的桌面入口和设置窗口'
foreach ($entry in @(
    @{ Source='tools\start-ui.cmd'; Destination='start-ui.cmd' },
    @{ Source='tools\start-ui.ps1'; Destination='start-ui.ps1' },
    @{ Source='tools\bridge-user-config.psm1'; Destination='bridge-user-config.psm1' },
    @{ Source='tools\start-bm-radio-bridge.ps1'; Destination='start-bm-radio-bridge.ps1' }
)) {
    Assert-True (@($alpha2Profile.SourceFiles | Where-Object {
        [string]$_.Source -ceq $entry.Source -and [string]$_.Destination -ceq $entry.Destination
    }).Count -eq 1) "alpha.2 package source mapping is fixed: $($entry.Source)"
}
Assert-True ((Get-ReleaseAssetName -RelativePath 'start-ui.cmd') -ceq 'start-ui.cmd') `
    '选择 alpha.2 profile 后 UI asset 映射启用'
$alpha3Profile = Get-ReleaseProfile -Version 'v0.1.0-alpha.3'
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.3')
$alpha3Files = @(Get-ExpectedReleasePackageFiles)
$alpha3Tests = @(Get-ExpectedReleaseTests)
Assert-Equal $alpha3Files.Count 28 'alpha.3 固定本地文件数含 manifest 和身份说明'
Assert-Equal $alpha3Tests.Count 35 'alpha.3 builder 测试数为精确 35 项'
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/BM来话身份显示.md') -ceq 'docs__bm-call-identity.md') `
    'alpha.3 identity guide has a fixed ASCII asset mapping'
Assert-True (@($alpha3Profile.SourceFiles | Where-Object {
    [string]$_.Source -ceq 'docs\BM来话身份显示.md' -and [string]$_.Destination -ceq 'docs\BM来话身份显示.md'
}).Count -eq 1) 'alpha.3 package includes the BM call-identity guide'
$alpha3ReadmeMap = @($alpha3Profile.SourceFiles | Where-Object { [string]$_.Destination -ceq 'README.md' })
Assert-Equal $alpha3ReadmeMap.Count 1 'alpha.3 has exactly one README source mapping'
Assert-True ([string]$alpha3ReadmeMap[0].Source -ceq 'docs\releases\v0.1.0-alpha.3-package-README.md') `
    'alpha.3 package copies its own versioned README'
Assert-True ($alpha3Profile.ReleaseScope -match 'per-accepted-call DMR Source ID label' -and
    @($alpha3Profile.NotIncluded | Where-Object { $_ -match 'RF node operation is not implemented' }).Count -eq 1) `
    'alpha.3 package scope states identity behavior and RF omission explicitly'
Assert-Equal $builderTestNames.Count $alpha3Tests.Count 'alpha.3 test list count matches current builder source'
for ($testIndex = 0; $testIndex -lt $alpha3Tests.Count; $testIndex++) {
    Assert-True ($builderTestNames[$testIndex] -ceq $alpha3Tests[$testIndex]) `
        "alpha.3 fixed test list matches builder source order at index $testIndex"
}
[void](Set-ReleaseVersion -Version 'v0.1.0-alpha.1')
Assert-Throws { Get-ReleaseAssetName -RelativePath 'start-ui.cmd' } 'alpha.1 不接受 alpha.2 UI asset'
Assert-True ((Get-ReleaseAssetName -RelativePath 'docs/连接配置.md') -ceq 'docs__connection-profile.md') `
    '切回 alpha.1 后仍保留原 asset 映射'
Assert-Throws { Get-ReleaseAssetName -RelativePath 'docs/BM来话身份显示.md' } 'alpha.1 不接受 alpha.3 identity guide'

$testRoot = Join-Path $repositoryRoot ('build\_work\package-release-test-' + [guid]::NewGuid().ToString('N'))
$buildDirectory = Join-Path $testRoot 'wirex-bridge-0123456-20261025-000000'
$buildLogPath = Join-Path $testRoot 'synthetic-build.log'
$packageRoot = Join-Path $testRoot 'synthetic-package'
$approvedFixturePath = Join-Path $repositoryRoot 'build\bm-radio-bridge-5e33433\private\device-y.bin'
$approvedFixtureHash = Test-ApprovedYFixture -Path $approvedFixturePath
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
try {
    $alpha3ReadmeOutput = Join-Path $testRoot 'synthetic-alpha3-readme\README.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $alpha3ReadmeOutput) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot $alpha3ReadmeMap[0].Source) -Destination $alpha3ReadmeOutput
    $copiedAlpha3Readme = [System.IO.File]::ReadAllText($alpha3ReadmeOutput, [System.Text.Encoding]::UTF8)
    Assert-True ($copiedAlpha3Readme -match '(?m)^# WIREX Bridge v0\.1\.0-alpha\.3\s*$' -and
        $copiedAlpha3Readme -notmatch 'v0\.1\.0-alpha\.2') `
        'alpha.3 README copy contains alpha.3 instructions and no alpha.2 version text'

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
    Assert-Equal $syntheticEvidence.passed_test_count 27 'alpha.1 合成 provenance 的结构和测试数验证'
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
    $provenance.tests = @($testRecords | Select-Object -First 26)
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

    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    foreach ($relativePath in (Get-ExpectedReleasePackageFiles | Where-Object { $_ -cne 'manifest.json' })) {
        $fullPath = Join-Path $packageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($relativePath -ceq 'private/device-y.bin') {
            Copy-Item -LiteralPath $approvedFixturePath -Destination $fullPath
        } else {
            Write-Utf8NoBom -Path $fullPath -Text ('synthetic inventory fixture: ' + $relativePath)
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $packageRoot 'logs') -Force | Out-Null
    $fileRecords = @()
    foreach ($relativePath in (Get-ExpectedReleasePackageFiles | Where-Object { $_ -cne 'manifest.json' } | Sort-Object)) {
        $fullPath = Join-Path $packageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath
        $fileRecords += ,([ordered]@{
            path=$relativePath
            asset_name=(Get-ReleaseAssetName -RelativePath $relativePath)
            length_bytes=[long]$item.Length
            sha256=(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source='synthetic test fixture'
        })
    }
    $packageManifest = [ordered]@{
        schema_version=1
        package_status='awaiting_root_audit'
        version='v0.1.0-alpha.1'
        tag_candidate='v0.1.0-alpha.1'
        manifest_asset_name='manifest.json'
        approved_y_fixture=[ordered]@{
            path='private/device-y.bin'
            length_bytes=100
            sha256=$approvedFixtureHash
        }
        files=$fileRecords
    }
    Write-Utf8NoBom -Path (Join-Path $packageRoot 'manifest.json') `
        -Text ((ConvertTo-Json -InputObject $packageManifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $packageRoot) -eq $null) `
        '合成固定目录清单结构通过；没有创建发布包'

    $alpha2PackageRoot = Join-Path $testRoot 'package-alpha2'
    Copy-Item -LiteralPath $packageRoot -Destination $alpha2PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.2')
    $alpha2ManifestPath = Join-Path $alpha2PackageRoot 'manifest.json'
    $alpha2Manifest = [System.IO.File]::ReadAllText($alpha2ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($relativePath in @(
        'start-user-config.cmd', 'start-user-config.ps1', 'bridge-user-config.psm1', 'start-ui.cmd', 'start-ui.ps1',
        'docs/配置与桌面操作.md', 'ui/windows/bridge-ui.ps1', 'ui/windows/BridgeSupervisor.cs',
        'ui/windows/MainWindow.xaml', 'ui/windows/SettingsWindow.xaml'
    )) {
        $fullPath = Join-Path $alpha2PackageRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Write-Utf8NoBom -Path $fullPath -Text ('synthetic alpha.2 inventory fixture: ' + $relativePath)
        $item = Get-Item -LiteralPath $fullPath
        $alpha2Manifest.files += ,([pscustomobject]@{
            path = $relativePath
            asset_name = (Get-ReleaseAssetName -RelativePath $relativePath)
            length_bytes = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source = 'synthetic alpha.2 test fixture'
        })
    }
    $alpha2Manifest.version = 'v0.1.0-alpha.2'
    $alpha2Manifest.tag_candidate = 'v0.1.0-alpha.2'
    Write-Utf8NoBom -Path $alpha2ManifestPath -Text ((ConvertTo-Json -InputObject $alpha2Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha2PackageRoot -Version 'v0.1.0-alpha.2') -eq $null) `
        'alpha.2 合成目录和 asset 清单与显式包配置一致'

    $alpha3PackageRoot = Join-Path $testRoot 'package-alpha3'
    Copy-Item -LiteralPath $alpha2PackageRoot -Destination $alpha3PackageRoot -Recurse
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.3')
    $alpha3ManifestPath = Join-Path $alpha3PackageRoot 'manifest.json'
    $alpha3Manifest = [System.IO.File]::ReadAllText($alpha3ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $identityGuide = Join-Path $alpha3PackageRoot 'docs\BM来话身份显示.md'
    Write-Utf8NoBom -Path $identityGuide -Text 'synthetic alpha.3 identity guide'
    $identityItem = Get-Item -LiteralPath $identityGuide
    $alpha3Manifest.files += ,([pscustomobject]@{
        path = 'docs/BM来话身份显示.md'
        asset_name = (Get-ReleaseAssetName -RelativePath 'docs/BM来话身份显示.md')
        length_bytes = [long]$identityItem.Length
        sha256 = (Get-FileHash -LiteralPath $identityGuide -Algorithm SHA256).Hash.ToLowerInvariant()
        source = 'synthetic alpha.3 test fixture'
    })
    $alpha3Manifest.version = 'v0.1.0-alpha.3'
    $alpha3Manifest.tag_candidate = 'v0.1.0-alpha.3'
    Write-Utf8NoBom -Path $alpha3ManifestPath -Text ((ConvertTo-Json -InputObject $alpha3Manifest -Depth 8) + "`n")
    Assert-True ((Assert-ReleasePackageInventory -PackageRoot $alpha3PackageRoot -Version 'v0.1.0-alpha.3') -eq $null) `
        'alpha.3 合成目录和 identity asset 清单与显式包配置一致'
    [void](Set-ReleaseVersion -Version 'v0.1.0-alpha.1')

    $readmeFixture = Join-Path $packageRoot 'README.md'
    Write-Utf8NoBom -Path $readmeFixture -Text 'tampered content'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '文件内容与manifest SHA不符'
    Write-Utf8NoBom -Path $readmeFixture -Text 'synthetic inventory fixture: README.md'
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $manifestObject = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $exeRecord = @($manifestObject.files | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })[0]
    $exeRecord.asset_name = 'manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifestObject -Depth 8) + "`n")
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '占用manifest asset名的普通文件'
    $exeRecord.asset_name = 'wirex_bridge.exe'
    Write-Utf8NoBom -Path $manifestPath -Text ((ConvertTo-Json -InputObject $manifestObject -Depth 8) + "`n")
    $forbiddenPath = Join-Path $packageRoot 'connection-profile.json'
    Write-Utf8NoBom -Path $forbiddenPath -Text '{"gateway_id":1}'
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '额外连接配置文件'

    $badFixture = Join-Path $testRoot 'wrong-y.bin'
    [System.IO.File]::WriteAllBytes($badFixture, (New-Object byte[] 100))
    Assert-Throws { Test-ApprovedYFixture -Path $badFixture } '内容不同的 100 字节 Y 素材'
    Copy-Item -LiteralPath $badFixture -Destination (Join-Path $packageRoot 'private\device-y.bin') -Force
    Assert-Throws { Assert-ReleasePackageInventory -PackageRoot $packageRoot } '被替换的 Y 素材'

    Write-Host ("Release packager 离线合成断言通过：{0}；未生成发布包，未运行 EXE。" -f $script:assertions)
}
finally {
    if ((Test-Path -LiteralPath $testRoot -PathType Container) -and
        (Test-PathWithinDirectory -Path $testRoot -Directory (Join-Path $repositoryRoot 'build\_work')) -and
        ([System.IO.Path]::GetFileName($testRoot).StartsWith('package-release-test-', [System.StringComparison]::Ordinal))) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
