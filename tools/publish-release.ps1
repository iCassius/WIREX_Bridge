[CmdletBinding()]
param(
    [string]$ReleaseDirectory,
    [string]$ExpectedCommit,
    [string]$Tag,
    [string]$NotesPath,
    [ValidateSet('Draft', 'Publish')][string]$Mode
)

$ErrorActionPreference = 'Stop'
$script:stableReleaseContractPath = Join-Path $PSScriptRoot 'StableReleaseContract.psm1'
if (-not [System.IO.File]::Exists($script:stableReleaseContractPath)) { throw 'StableReleaseContract.psm1 is missing.' }
Import-Module -Name $script:stableReleaseContractPath -Force -Scope Global -ErrorAction Stop
$script:zipOnlyReleaseContractPath = Join-Path $PSScriptRoot 'ZipOnlyRelease.psm1'
if (-not [System.IO.File]::Exists($script:zipOnlyReleaseContractPath)) { throw 'ZipOnlyRelease.psm1 is missing.' }
Import-Module -Name $script:zipOnlyReleaseContractPath -Force -Scope Global -ErrorAction Stop
Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

$script:repositoryFullName = 'iCassius/WIREX_Bridge'
$script:repositoryUrl = 'https://github.com/iCassius/WIREX_Bridge.git'
$script:approvedFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:publishTag = 'v0.1.0'
$script:v010TestNames = @(
    'dmrd_test', 'direct_frame_test', 'hri_t_payload_test', 'hri_call_header_test', 'hri_t_record_test',
    'hri_lcd_identity_candidate_test', 'radio_identity_cache_test', 'direct_stream_test', 'hri_session_test', 'hri_ptt_gate_test',
    'hri_p_status_test', 'hri_downlink_session_test', 'hri_radio_protocol_test', 'operation_audio_cleanup_test', 'audio_input_cleanup_test',
    'wave_output_open_test', 'session_timing_test', 'wave_file_test', 'pcm_gain_test', 'bounded_pipe_writer_test',
    'ui_pipe_test', 'console_lifecycle_test', 'session_report_test', 'dmr_call_test', 'bm_session_test',
    'bm_udp_test', 'dmr_vocoder_test', 'ambe_dmr72_test', 'ysf_vd2_vch_test', 'voice_transcode_buffer_test',
    'pcm_resampler_test', 'bm_voice_pipeline_test', 'bm_test_profile_test', 'bm_connection_config_test', 'hri_stream_session_test',
    'bm_bridge_loopback_test', 'ui_control_protocol_v2_test', 'talkgroup_routing_test', 'bm_routing_lifecycle_test', 'routing_state_test'
)
# v0.1.0 已发布的 40 项保持不变；ZIP-only profile 由 R128 起的 builder 构建，追加 engine_test。
$script:zipOnlyTestNames = @($script:v010TestNames) + @('engine_test')
$script:publishIsPrerelease = $true

function Set-PublishProfile {
    param([Parameter(Mandatory=$true)][string]$Tag)
    switch -CaseSensitive ($Tag) {
        'v0.1.0' {
            $script:publishTag = $Tag
            $script:publishIsPrerelease = $false
            $script:assetPathMap = [ordered]@{
                'WIREX_Bridge_v0.1.0.zip'='WIREX_Bridge_v0.1.0.zip'
                'manifest.json'='manifest.json'
                'SHA256SUMS.txt'='SHA256SUMS.txt'
            }
            $script:expectedDirectories = @('runtime','runtime/docs','runtime/licenses','runtime/licenses/dmr_signal',
                'runtime/licenses/droidstar_mbe','runtime/private','runtime/ui','runtime/ui/windows')
            $script:expectedTestNames = $script:v010TestNames
        }
        'v0.1.1-test.2' {
            $zip = Get-WirexZipOnlyReleaseProfile -Version $Tag
            $script:publishTag = $Tag
            $script:publishIsPrerelease = $true
            $script:assetPathMap = [ordered]@{}
            $script:assetPathMap[$zip.ArchiveName] = $zip.ArchiveName
            $script:expectedDirectories = @($zip.Directories)
            $script:expectedTestNames = $script:zipOnlyTestNames
        }
        'v0.1.1' {
            $zip = Get-WirexZipOnlyReleaseProfile -Version $Tag
            $script:publishTag = $Tag
            $script:publishIsPrerelease = $false
            $script:assetPathMap = [ordered]@{}
            $script:assetPathMap[$zip.ArchiveName] = $zip.ArchiveName
            $script:expectedDirectories = @($zip.Directories)
            $script:expectedTestNames = $script:zipOnlyTestNames
        }
        default { throw 'Only registered v0.1.0, v0.1.1-test.2, and v0.1.1 profiles are supported.' }
    }
    return [pscustomobject]@{
        Tag = $script:publishTag
        AssetPathMap = $script:assetPathMap
        Directories = $script:expectedDirectories
        TestNames = $script:expectedTestNames
    }
}

[void](Set-PublishProfile -Tag $script:publishTag)

function Test-PublishPathWithin {
    param([string]$Path, [string]$Directory)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    return $fullPath.StartsWith(($fullDirectory + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ExpectedStablePackageRecords {
    $specification = @'
WirexBridge.exe|WirexBridge.exe
build-provenance.json|build-provenance.json
launcher-build-provenance.json|launcher-build-provenance.json
README.md|README.md
SOURCE.txt|SOURCE.txt
runtime/wirex_bridge.exe|runtime__wirex_bridge.exe
runtime/private/device-y.bin|runtime__private__device-y.bin
runtime/start-bm-radio-bridge.ps1|runtime__start-bm-radio-bridge.ps1
runtime/start-ui.ps1|runtime__start-ui.ps1
runtime/bridge-user-config.psm1|runtime__bridge-user-config.psm1
runtime/docs/配置与桌面操作.md|runtime__docs__desktop-user-config.md
runtime/docs/连接配置.md|runtime__docs__connection-profile.md
runtime/docs/音量调节.md|runtime__docs__audio-gain.md
runtime/ui/windows/bridge-ui.ps1|runtime__ui__windows__bridge-ui.ps1
runtime/ui/windows/BridgeSupervisor.cs|runtime__ui__windows__BridgeSupervisor.cs
runtime/ui/windows/MainWindow.xaml|runtime__ui__windows__MainWindow.xaml
runtime/ui/windows/SettingsWindow.xaml|runtime__ui__windows__SettingsWindow.xaml
runtime/licenses/dmr_signal/COPYING.GPL-3.0.txt|runtime__licenses__dmr-signal__COPYING.GPL-3.0.txt
runtime/licenses/dmr_signal/NOTICE.md|runtime__licenses__dmr-signal__NOTICE.md
runtime/licenses/droidstar_mbe/COPYING.GPL-3.0.txt|runtime__licenses__droidstar-mbe__COPYING.GPL-3.0.txt
runtime/licenses/droidstar_mbe/ISC-NOTICE.txt|runtime__licenses__droidstar-mbe__ISC-NOTICE.txt
runtime/licenses/droidstar_mbe/source-manifest.json|runtime__licenses__droidstar-mbe__source-manifest.json
runtime/docs/BM来话身份显示.md|runtime__docs__bm-call-identity.md
runtime/docs/R106_IPC第二版.md|runtime__docs__r106-ipc-v2.md
runtime/docs/R106_配置迁移与测试.md|runtime__docs__r106-profile-migration-test.md
runtime/docs/R108_收发路由状态与alpha6验收.md|runtime__docs__r108-routing-state-alpha6.md
runtime/docs/R109_下行状态与动态组修复.md|runtime__docs__r109-downlink-dynamic-groups.md
runtime/docs/R109_动态组激活实现.md|runtime__docs__r109-dynamic-group-activation.md
runtime/ui/windows/RadioIdentity.psm1|runtime__ui__windows__radio-identity.psm1
runtime/docs/R112_A_网络音频指标.md|runtime__docs__r112-a-network-audio-metrics.md
runtime/docs/R113_LCD核心实现.md|runtime__docs__r113-lcd-core-implementation.md
runtime/docs/R113_身份与LCD接线.md|runtime__docs__r113-identity-lcd-integration.md
runtime/ui/windows/RadioCat.psm1|runtime__ui__windows__radio-cat.psm1
runtime/docs/R116_CAT能力与控制实现.md|runtime__docs__r116-cat-controls.md
runtime/docs/R116_电台控制界面.md|runtime__docs__r116-radio-controls-ui.md
runtime/ui/windows/RadioCatUi.ps1|runtime__ui__windows__radio-cat-ui.ps1
runtime/ui/windows/RadioDevices.psm1|runtime__ui__windows__radio-devices.psm1
runtime/ui/windows/BmServers.psm1|runtime__ui__windows__bm-servers.psm1
runtime/ui/windows/BmManagement.psm1|runtime__ui__windows__bm-management.psm1
runtime/ui/windows/BmManagementUi.ps1|runtime__ui__windows__bm-management-ui.ps1
runtime/ui/windows/PortableConfig.psm1|runtime__ui__windows__portable-config.psm1
runtime/ui/windows/ChannelActivationState.psm1|runtime__ui__windows__channel-activation-state.psm1
'@
    foreach ($line in ($specification -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line.Split('|')
        [pscustomobject]@{ Path=$parts[0]; AssetName=$parts[1] }
    }
}

function Get-ExpectedStablePackageDirectories {
    return @('runtime','runtime/docs','runtime/licenses','runtime/licenses/dmr_signal',
        'runtime/licenses/droidstar_mbe','runtime/private','runtime/ui','runtime/ui/windows')
}

function Assert-StableArchiveMatchesPackage {
    param([string]$PackageRoot,[string]$ArchivePath,[object[]]$Records)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $canonicalPathMap = New-WirexStableCanonicalPathMap -Paths (@($Records | ForEach-Object { [string]$_.Path }) + 'manifest.json')
    $limits = Get-WirexStableReleaseLimits
    $archiveItem = Get-Item -LiteralPath $ArchivePath -ErrorAction Stop
    if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$archiveItem.Length) -MaximumBytes ([long]$limits.MaximumArchiveBytes))) {
        throw 'Stable ZIP exceeds the fixed 512 MiB download limit.'
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $total = [long]0
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.Contains(':') -or
                $name.StartsWith('/') -or $name.EndsWith('/') -or $name -match '(^|/)\.{1,2}(/|$)' -or
                $name -match '[\x00-\x1f\x7f]' -or
                @($name.Split('/') | Where-Object { $_.EndsWith('.') -or $_.EndsWith(' ') }).Count -gt 0) {
                throw 'Stable ZIP contains an unsafe path.'
            }
            $canonicalPath = Resolve-WirexStableCanonicalPath -Path $name -CanonicalPathMap $canonicalPathMap
            if (-not [string]::Equals($name, [string]$canonicalPath, [System.StringComparison]::Ordinal)) {
                throw 'Stable ZIP entry path differs from its exact canonical spelling.'
            }
            if (-not $seen.Add($name)) { throw 'Stable ZIP contains an unexpected or case-insensitive duplicate path.' }
            if (-not (Test-WirexStableRegularZipEntry -ExternalAttributes ([int]$entry.ExternalAttributes) -Length ([long]$entry.Length))) {
                throw 'Stable ZIP contains a non-regular file entry.'
            }
            $maximumFileBytes = [long](Get-WirexStableMaximumFileBytes -Path $canonicalPath)
            if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$entry.Length) -MaximumBytes $maximumFileBytes)) {
                throw "Stable ZIP entry exceeds its fixed per-file download limit: $canonicalPath"
            }
            $path = Join-Path $PackageRoot $canonicalPath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if ([long]$entry.Length -ne [long]$item.Length) { throw 'Stable ZIP entry length differs from the audited folder.' }
            $stream = $entry.Open()
            try {
                $zipHash = Get-StreamSha256 -Stream $stream -ExpectedLength ([long]$item.Length)
            } finally { $stream.Dispose() }
            $folderHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($zipHash -cne $folderHash) { throw 'Stable ZIP entry differs from the audited folder bytes.' }
            $total += [long]$entry.Length
            if (-not (Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes ([long]$limits.MaximumUncompressedBytes))) {
                throw 'Stable ZIP contents exceed the 2 GiB limit.'
            }
        }
        if ($seen.Count -ne $canonicalPathMap.Count) { throw 'Stable ZIP is missing one or more audited folder files.' }
        return $total
    } finally { $archive.Dispose() }
}

function Assert-StablePublishPackage {
    param([string]$PackageRoot,[string]$ExpectedCommit,[string]$DistributionDirectory)
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    $manifestPath = Join-Path $root 'manifest.json'
    $limits = Get-WirexStableReleaseLimits
    try {
        if (-not [System.IO.File]::Exists($manifestPath)) { throw 'Stable manifest.json is missing.' }
        $manifestInfo = Get-Item -LiteralPath $manifestPath -ErrorAction Stop
        if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$manifestInfo.Length) -MaximumBytes ([long]$limits.MaximumManifestBytes))) {
            throw 'Stable manifest.json exceeds its fixed size limit.'
        }
        $manifest = (Get-StrictUtf8Text -Path $manifestPath) | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw 'Stable manifest.json is invalid.' }
    if ([int]$manifest.schema_version -ne 1 -or
        [string]$manifest.package_kind -cne 'wirex_bridge_stable_release_green_directory' -or
        [string]$manifest.package_status -cne 'root_audit_passed' -or
        [string]$manifest.version -cne 'v0.1.0' -or [string]$manifest.tag_candidate -cne 'v0.1.0' -or
        [string]$manifest.source.repository -cne $script:repositoryUrl -or
        ([string]$manifest.source.commit).ToLowerInvariant() -cne $ExpectedCommit -or
        $manifest.source.working_tree_clean -ne $true -or
        ([string]$manifest.build.source_commit).ToLowerInvariant() -cne $ExpectedCommit -or
        $manifest.build.source_tree_clean -ne $true -or $manifest.build.compile_only -ne $false -or
        $manifest.build.build_completed -ne $true -or [string]$manifest.build.result -cne 'passed' -or
        $manifest.tag_created -ne $false -or $manifest.github_release_published -ne $false) {
        throw 'Stable package does not attest the audited clean source and build.'
    }
    if ([string]$manifest.approved_y_fixture.path -cne 'runtime/private/device-y.bin' -or
        [long]$manifest.approved_y_fixture.length_bytes -ne 100 -or
        ([string]$manifest.approved_y_fixture.sha256).ToLowerInvariant() -cne $script:approvedFixtureSha256) {
        throw 'Stable manifest does not retain the approved HRI protocol template.'
    }
    $tests = @($manifest.build.passed_tests | ForEach-Object { [string]$_ })
    if ([int]$manifest.build.passed_test_count -ne $script:expectedTestNames.Count -or $tests.Count -ne $script:expectedTestNames.Count) {
        throw 'Stable manifest does not record the fixed offline Native test set.'
    }
    for ($i=0; $i -lt $tests.Count; $i++) { if ($tests[$i] -cne $script:expectedTestNames[$i]) { throw 'Stable Native test inventory is not exact.' } }

    $records = @(Get-ExpectedStablePackageRecords)
    $expectedFiles = @($records | ForEach-Object { [string]$_.Path }) + 'manifest.json'
    $actualFiles = @(); $actualDirectories = @()
    foreach ($item in (Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Stable package contains a reparse point.' }
        $relative = $item.FullName.Substring($root.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1).Replace('\','/')
        if ($item.PSIsContainer) { $actualDirectories += $relative } else { $actualFiles += $relative }
    }
    if ((@($actualFiles | Sort-Object -CaseSensitive) -join "`n") -cne (@($expectedFiles | Sort-Object -CaseSensitive) -join "`n") -or
        (@($actualDirectories | Sort-Object -CaseSensitive) -join "`n") -cne (@(Get-ExpectedStablePackageDirectories | Sort-Object -CaseSensitive) -join "`n")) {
        throw ('Stable folder package inventory differs from the audited ' + $expectedFiles.Count + '-file layout.')
    }
    if (@($manifest.files).Count -ne $records.Count) { throw 'Stable manifest file count differs from its fixed folder inventory.' }
    $recordByPath = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($manifest.files)) {
        $path = [string]$item.path
        $expected = @($records | Where-Object { [string]$_.Path -ceq $path })
        if ($expected.Count -ne 1 -or [string]$item.asset_name -cne [string]$expected[0].AssetName -or $recordByPath.ContainsKey($path)) {
            throw 'Stable manifest contains an unknown, duplicate, or incorrectly named package path.'
        }
        if ([string]$item.source -match '(?i)[A-Z]:\\|\\\\') { throw 'Stable manifest source contains a machine-local path.' }
        $file = Join-Path $root $path.Replace('/',[System.IO.Path]::DirectorySeparatorChar)
        $info = Get-Item -LiteralPath $file -ErrorAction Stop
        $maximumFileBytes = [long](Get-WirexStableMaximumFileBytes -Path $path)
        if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$info.Length) -MaximumBytes $maximumFileBytes)) {
            throw "Stable package file exceeds its fixed download limit: $path"
        }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([long]$item.length_bytes -ne [long]$info.Length -or [string]$item.sha256 -cne $hash) {
            throw 'A stable package file does not match its manifest length and SHA-256.'
        }
        if ($path -ceq 'runtime/private/device-y.bin' -and ($hash -cne $script:approvedFixtureSha256 -or [long]$info.Length -ne 100)) {
            throw 'Stable package contains a different HRI protocol template.'
        }
        $recordByPath[$path] = $item
    }
    foreach ($path in @('WirexBridge.exe','build-provenance.json','launcher-build-provenance.json','README.md','SOURCE.txt')) {
        if (-not $recordByPath.ContainsKey($path)) { throw "Stable manifest is missing $path." }
    }
    $manifestBytes = (Get-StrictUtf8Text -Path $manifestPath)
    if ($manifestBytes -match '(?i)[A-Z]:\\|\\\\') { throw 'Stable manifest includes a machine-local absolute path.' }
    $sourceText = Get-StrictUtf8Text -Path (Join-Path $root 'SOURCE.txt')
    if ($sourceText -match '(?i)[A-Z]:\\|\\\\') { throw 'Stable SOURCE.txt contains a machine-local absolute path.' }

    $launcherBuild = Get-StrictUtf8Text -Path (Join-Path $root 'launcher-build-provenance.json') | ConvertFrom-Json -ErrorAction Stop
    $launcherRecord = $recordByPath['WirexBridge.exe']
    if ([int]$launcherBuild.schema_version -ne 1 -or [string]$launcherBuild.result -cne 'passed' -or
        [string]$launcherBuild.source.path -cne 'ui/launcher/WirexBridgeLauncher.cs' -or
        [string]$launcherBuild.source.commit -cne $ExpectedCommit -or
        [string]$launcherBuild.compiler.command -cne 'csc.exe /nologo /target:winexe /platform:x64 /optimize+ /debug- /codepage:65001' -or
        [string]$launcherBuild.compiler.target -cne 'x64 Windows GUI executable' -or
        [string]$launcherBuild.output.path -cne 'WirexBridge.exe' -or
        [string]$launcherBuild.output.sha256 -cne [string]$launcherRecord.sha256 -or
        [long]$launcherBuild.output.length_bytes -ne [long]$launcherRecord.length_bytes -or
        [string]$manifest.launcher_build.executable_sha256 -cne [string]$launcherRecord.sha256 -or
        [string]$manifest.launcher_build.provenance_sha256 -cne (Get-FileHash -LiteralPath (Join-Path $root 'launcher-build-provenance.json') -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Stable launcher build provenance does not match the release manifest and executable.'
    }

    if ([string]::IsNullOrWhiteSpace($DistributionDirectory)) {
        $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $root '..\..\..'))
        $distributionRoot = Join-Path $repositoryRoot 'build\_work\r124-distribution\v0.1.0'
    } else {
        $distributionRoot = [System.IO.Path]::GetFullPath($DistributionDirectory)
    }
    $zipPath = Join-Path $distributionRoot 'WIREX_Bridge_v0.1.0.zip'
    $checksumPath = Join-Path $distributionRoot 'SHA256SUMS.txt'
    if (-not [System.IO.File]::Exists($zipPath) -or -not [System.IO.File]::Exists($checksumPath)) { throw 'Stable distribution ZIP and SHA256SUMS.txt are missing.' }
    $distributionFiles = @(Get-ChildItem -LiteralPath $distributionRoot -Force)
    if ($distributionFiles.Count -ne 3 -or @($distributionFiles | Where-Object { $_.Name -cnotin @('WIREX_Bridge_v0.1.0.zip','SHA256SUMS.txt','manifest.json') }).Count -ne 0) {
        throw 'Stable distribution directory must contain exactly ZIP, manifest.json, and SHA256SUMS.txt.'
    }
    $manifestCopy = Join-Path $distributionRoot 'manifest.json'
    $zipInfo = Get-Item -LiteralPath $zipPath -ErrorAction Stop
    if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$zipInfo.Length) -MaximumBytes ([long]$limits.MaximumArchiveBytes)) -or
        -not (Test-WirexStableLengthWithinLimit -Length ([long](Get-Item -LiteralPath $manifestCopy).Length) -MaximumBytes ([long]$limits.MaximumManifestBytes)) -or
        -not (Test-WirexStableLengthWithinLimit -Length ([long](Get-Item -LiteralPath $checksumPath).Length) -MaximumBytes 4096)) {
        throw 'Stable ZIP, manifest, or SHA256SUMS.txt exceeds its fixed download limit.'
    }
    if ((Get-FileHash -LiteralPath $manifestCopy -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) {
        throw 'Stable distribution manifest.json differs from the audited candidate.'
    }
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sumLines = @(Get-StrictUtf8Text -Path $checksumPath) -split "`r?`n" | Where-Object { $_ }
    if ($sumLines.Count -ne 2 -or $sumLines[0] -cne ($zipHash + '  WIREX_Bridge_v0.1.0.zip') -or
        $sumLines[1] -cne ($manifestHash + '  manifest.json')) { throw 'Stable SHA256SUMS.txt does not match the release ZIP and manifest.' }
    [void](Assert-StableArchiveMatchesPackage -PackageRoot $root -ArchivePath $zipPath -Records $records)
    $assets = @(
        [pscustomobject]@{Name='WIREX_Bridge_v0.1.0.zip';Path=$zipPath;Length=[long](Get-Item $zipPath).Length;Sha256=$zipHash},
        [pscustomobject]@{Name='manifest.json';Path=$manifestCopy;Length=[long](Get-Item $manifestCopy).Length;Sha256=$manifestHash},
        [pscustomobject]@{Name='SHA256SUMS.txt';Path=$checksumPath;Length=[long](Get-Item $checksumPath).Length;Sha256=(Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    )
    return ,([pscustomobject]@{Manifest=$manifest;Assets=$assets})
}

function Get-StrictUtf8Text {
    param([string]$Path)
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { return [System.IO.File]::ReadAllText($Path, $encoding) }
    catch { throw 'A required UTF-8 text file is unreadable.' }
}

function Get-PublishNotes {
    param([string]$Path, [string]$RepositoryRoot, [string]$ExpectedCommit)
    $notesRelativePath = ('docs/releases/' + $script:publishTag + '.md')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $expectedNotes = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $notesRelativePath))
    if (-not $fullPath.Equals($expectedNotes, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw 'NotesPath must name the fixed release notes file in this repository.'
    }
    $notes = Get-StrictUtf8Text -Path $fullPath
    if ([string]::IsNullOrWhiteSpace($notes) -or $notes.Length -gt 100000 -or $notes.IndexOf([char]0) -ge 0) {
        throw 'Release notes are empty or outside the supported size.'
    }
    $expectedCommitPath = ($ExpectedCommit + ':' + $notesRelativePath)
    $commitBlob = Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', $expectedCommitPath)
    $headCommit = Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', 'HEAD')
    $headCommitPath = ($headCommit + ':' + $notesRelativePath)
    $headBlob = Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', $headCommitPath)
    $notesPathOption = ('--path=' + $notesRelativePath)
    $workingBlob = Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('hash-object', $notesPathOption, $fullPath)
    if ($commitBlob -cne $headBlob -or $commitBlob -cne $workingBlob) { throw 'Release notes do not match the expected source commit and current HEAD.' }
    return $notes
}

function Get-GitText {
    param([string]$RepositoryRoot, [string[]]$Arguments)
    $gitCommand = Get-Command git -ErrorAction Stop
    $allArguments = @('-C', $RepositoryRoot) + $Arguments
    $output = @(& $gitCommand.Source @allArguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw 'A required local Git object could not be verified.' }
    return ([string]$output[0]).Trim()
}

function Assert-ZipOnlyPublishPackage {
    param([string]$PackageRoot,[string]$ExpectedCommit,[string]$Tag,[string]$RepositoryRoot)
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $zipProfile = Get-WirexZipOnlyReleaseProfile -Version $Tag
    $auditManifestPath = Join-Path $root ('private\release-audits\R126\' + $Tag + '\manifest.json')
    $validated = Get-WirexZipOnlyAuditManifest -AuditManifestPath $auditManifestPath -Version $Tag `
        -PackageRoot $PackageRoot -RequireRootAudit
    $manifest = $validated.Manifest
    if ([string]$manifest.source.repository -cne $script:repositoryUrl -or
        [string]$manifest.source.commit -cne $ExpectedCommit -or
        [string]$manifest.build.launcher_source_commit -cne $ExpectedCommit) {
        throw 'ZIP-only private audit source does not match the requested release commit.'
    }
    $tests = @($manifest.build.passed_tests | ForEach-Object { [string]$_ })
    if ([int]$manifest.build.passed_test_count -ne $script:expectedTestNames.Count -or $tests.Count -ne $script:expectedTestNames.Count) {
        throw 'ZIP-only private audit does not record the exact Native test set.'
    }
    for ($index=0; $index -lt $tests.Count; $index++) {
        if ($tests[$index] -cne $script:expectedTestNames[$index]) { throw 'ZIP-only Native test inventory does not match the fixed profile.' }
    }
    $nativeCommit = [string]$manifest.build.native_source_commit
    $mergeBaseLines = @(& git -C $root merge-base --is-ancestor $nativeCommit $ExpectedCommit 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'ZIP-only Native build commit is not an ancestor of the package source commit.' }
    $nativeInputPaths = @('CMakeLists.txt','include/','src/','tests/','third_party/','tools/build-bm-bridge.ps1')
    $diffOutput = @(& git -C $root diff --quiet $nativeCommit $ExpectedCommit -- @nativeInputPaths 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'ZIP-only Native build inputs changed after its source commit.' }

    $distributionRoot = Join-Path $root ('build\_work\r126-distribution\' + $Tag)
    if (-not [System.IO.Directory]::Exists($distributionRoot)) { throw 'ZIP-only distribution directory is missing.' }
    $distributionItems = @(Get-ChildItem -LiteralPath $distributionRoot -Force -ErrorAction Stop)
    if ($distributionItems.Count -ne 1 -or $distributionItems[0].PSIsContainer -or $distributionItems[0].Name -cne $zipProfile.ArchiveName) {
        throw 'ZIP-only distribution must contain exactly one archive asset.'
    }
    $archivePath = Join-Path $distributionRoot $zipProfile.ArchiveName
    $archiveInfo = Get-Item -LiteralPath $archivePath -ErrorAction Stop
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($null -eq $manifest.archive -or [string]$manifest.archive.name -cne $zipProfile.ArchiveName -or
        [long]$manifest.archive.length_bytes -ne [long]$archiveInfo.Length -or [string]$manifest.archive.sha256 -cne $archiveHash) {
        throw 'ZIP-only archive does not match its private audit record.'
    }
    [void](Test-WirexZipOnlyArchive -ArchivePath $archivePath -Version $Tag `
        -AuditManifestPath $auditManifestPath -PackageRoot $PackageRoot)
    return ,([pscustomobject]@{Manifest=$manifest;Assets=@([pscustomobject]@{
        Name=$zipProfile.ArchiveName;Path=$archivePath;Length=[long]$archiveInfo.Length;Sha256=$archiveHash
    })})
}

function Assert-LocalRepositoryIdentity {
    param([string]$RepositoryRoot)
    $gitRoot = [System.IO.Path]::GetFullPath((Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--show-toplevel')))
    $expectedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if (-not $gitRoot.Equals($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'The current directory is not the expected Git repository root.' }
    $remote = (Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('remote', 'get-url', 'origin')).ToLowerInvariant().TrimEnd('/')
    $allowedRemotes = @(
        'https://github.com/icassius/wirex_bridge.git',
        'https://github.com/icassius/wirex_bridge',
        'ssh://git@github.com/icassius/wirex_bridge.git',
        'ssh://git@github.com/icassius/wirex_bridge',
        'git@github.com:icassius/wirex_bridge.git',
        'git@github.com:icassius/wirex_bridge'
    )
    if ($remote -cnotin $allowedRemotes) { throw 'The local origin is not the fixed iCassius/WIREX_Bridge repository.' }
}

function Assert-PublishPackage {
    param([string]$PackageRoot, [string]$ExpectedCommit, [string]$Tag = $script:publishTag,
          [string]$DistributionDirectory)
    [void](Set-PublishProfile -Tag $Tag)
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'ReleaseDirectory does not exist.' }
    if (Test-WirexZipOnlyVersion -Version $Tag) {
        return (Assert-ZipOnlyPublishPackage -PackageRoot $root -ExpectedCommit $ExpectedCommit -Tag $Tag -RepositoryRoot (Join-Path $root '..\..\..'))
    }
    if ($Tag -ceq 'v0.1.0') { return (Assert-StablePublishPackage -PackageRoot $root -ExpectedCommit $ExpectedCommit -DistributionDirectory $DistributionDirectory) }
    throw 'Only registered v0.1.0, v0.1.1-test.2, and v0.1.1 profiles are supported.'
}

function Get-GitCredentialToken {
    $gitCommand = Get-Command git -ErrorAction Stop
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $gitCommand.Source
    $start.Arguments = 'credential fill'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $start.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $credentialText = ''
    $errorTask = $null
    try {
        if (-not $process.Start()) { throw 'start' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write("protocol=https`nhost=github.com`n`n")
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill() } catch { }
            $stopped = $false
            try { $stopped = $process.WaitForExit(5000) } catch { }
            if (-not $stopped) { throw 'not-stopped' }
            throw 'timeout'
        }
        $credentialText = $outputTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'missing' }
        $token = $null
        foreach ($line in ($credentialText -split "`n")) {
            $cleanLine = $line.TrimEnd("`r")
            if ($cleanLine.StartsWith('password=', [System.StringComparison]::Ordinal)) { $token = $cleanLine.Substring(9) }
        }
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'missing' }
        return $token
    } catch {
        if ($_.Exception.Message -eq 'not-stopped') { throw 'Git Credential Manager timed out and did not stop.' }
        if ($_.Exception.Message -eq 'timeout') { throw 'Git Credential Manager did not return within the allowed time.' }
        throw 'Git Credential Manager did not provide a usable credential.'
    } finally {
        $credentialText = ''
        if ($null -ne $process) { $process.Dispose() }
    }
}

function New-PublishHttpClients {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $anonymousHandler = New-Object System.Net.Http.HttpClientHandler
    $anonymousHandler.AllowAutoRedirect = $false
    $authenticated = [System.Net.Http.HttpClient]::new($handler)
    $anonymous = [System.Net.Http.HttpClient]::new($anonymousHandler)
    foreach ($client in @($authenticated, $anonymous)) {
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('WIREX-Bridge-ReleasePublisher/1.0')
    }
    $authenticated.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $authenticated.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
    return [pscustomobject]@{ Authenticated=$authenticated; Anonymous=$anonymous }
}

function Initialize-GitHubClient {
    $script:apiBase = 'https://api.github.com'
    $script:repoBase = $script:apiBase + '/repos/' + $script:repositoryFullName
    $script:token = Get-GitCredentialToken
    $clients = New-PublishHttpClients
    $script:githubClient = $clients.Authenticated
    $script:anonymousClient = $clients.Anonymous
    $script:githubClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:token)
}

function New-UnknownOutcomeError {
    $exception = New-Object System.Exception('The GitHub mutation outcome is unknown.')
    $exception.Data['WirexOutcomeUnknown'] = $true
    return $exception
}

function Test-UnknownOutcomeError {
    param([System.Exception]$Exception)
    return ($null -ne $Exception.Data['WirexOutcomeUnknown'])
}

function Send-GitHubRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [System.Net.Http.HttpContent]$Content=$null,
        [switch]$AllowNotFound
    )
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    if ($null -ne $Content) { $request.Content = $Content }
    try {
        try { $response = $script:githubClient.SendAsync($request).GetAwaiter().GetResult() }
        catch {
            if ($Method -in @('POST', 'PATCH')) { throw (New-UnknownOutcomeError) }
            throw 'GitHub API request failed.'
        }
        $status = [int]$response.StatusCode
        if ($AllowNotFound -and $status -eq 404) { return [pscustomobject]@{ Status=404; Data=$null } }
        if ($status -ge 500 -and $Method -in @('POST', 'PATCH')) { throw (New-UnknownOutcomeError) }
        if ($status -lt 200 -or $status -ge 300) { throw ('GitHub API returned HTTP ' + $status + '.') }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try { $data = $body | ConvertFrom-Json -ErrorAction Stop }
        catch {
            if ($Method -in @('POST', 'PATCH')) { throw (New-UnknownOutcomeError) }
            throw 'GitHub API returned an invalid response.'
        }
        return [pscustomobject]@{ Status=$status; Data=$data }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }
}

function New-GitHubJsonContent {
    param([object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 10 -Compress
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.UTF8Encoding]::new($false), 'application/json')
    return $content
}

function Assert-GitHubIdentityAndRepository {
    $user = (Send-GitHubRequest -Method 'GET' -Uri ($script:apiBase + '/user')).Data
    if ([string]$user.login -cne 'iCassius') { throw 'The authenticated GitHub account is not iCassius.' }
    $repo = (Send-GitHubRequest -Method 'GET' -Uri $script:repoBase).Data
    if ([string]$repo.full_name -cne $script:repositoryFullName -or $repo.private -ne $true) {
        throw 'The fixed GitHub repository is missing or is not private.'
    }
}

function Assert-RemoteTagCommit {
    param([string]$ExpectedCommit)
    $escapedTag = [System.Uri]::EscapeDataString($script:publishTag)
    $reference = (Send-GitHubRequest -Method 'GET' -Uri ($script:repoBase + '/git/ref/tags/' + $escapedTag)).Data
    if ([string]$reference.ref -cne ('refs/tags/' + $script:publishTag)) { throw 'The remote tag reference is not exact.' }
    $objectType = [string]$reference.object.type
    $objectSha = [string]$reference.object.sha
    $visited = @{}
    for ($depth = 0; $depth -lt 8 -and $objectType -ceq 'tag'; $depth++) {
        if ($objectSha -notmatch '^[0-9a-f]{40}$' -or $visited.ContainsKey($objectSha)) { throw 'The remote annotated tag chain is invalid.' }
        $visited[$objectSha] = $true
        $tagObject = (Send-GitHubRequest -Method 'GET' -Uri ($script:repoBase + '/git/tags/' + $objectSha)).Data
        $objectType = [string]$tagObject.object.type
        $objectSha = [string]$tagObject.object.sha
    }
    if ($objectType -cne 'commit' -or $objectSha.ToLowerInvariant() -cne $ExpectedCommit) {
        throw 'The remote tag does not resolve to ExpectedCommit.'
    }
}

function Get-ReleaseByTag {
    $escapedTag = [System.Uri]::EscapeDataString($script:publishTag)
    $result = Send-GitHubRequest -Method 'GET' -Uri ($script:repoBase + '/releases/tags/' + $escapedTag) -AllowNotFound
    if ($result.Status -ne 404) { return $result.Data }
    $matches = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le 10; $page++) {
        $pageReleases = @((Send-GitHubRequest -Method 'GET' -Uri ($script:repoBase + '/releases?per_page=100&page=' + $page)).Data)
        foreach ($release in $pageReleases) {
            if ([string]$release.tag_name -ceq $script:publishTag) { [void]$matches.Add($release) }
        }
        if ($pageReleases.Count -lt 100) { break }
    }
    if ($matches.Count -gt 1) { throw 'GitHub lists multiple releases with the fixed tag.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Assert-ReleaseIdentity {
    param([object]$Release, [string]$ExpectedCommit, [string]$Notes, [bool]$MustBeDraft)
    if ($null -eq $Release -or [string]$Release.tag_name -cne $script:publishTag -or
        [string]$Release.target_commitish -cne $ExpectedCommit -or
        [string]$Release.body -cne $Notes -or $Release.prerelease -ne $script:publishIsPrerelease -or
        $Release.draft -ne $MustBeDraft) {
        throw 'The existing GitHub release does not match the expected tag, notes, commit, or prerelease state.'
    }
}

function Get-PublishReleaseAction {
    param([object]$Release, [string]$ExpectedCommit, [string]$Notes)
    if ($null -eq $Release -or $Release.prerelease -ne $script:publishIsPrerelease) { throw 'The GitHub release prerelease state does not match this release profile.' }
    if ($Release.draft -eq $true) {
        Assert-ReleaseIdentity -Release $Release -ExpectedCommit $ExpectedCommit -Notes $Notes -MustBeDraft $true
        return 'publish'
    }
    if ($Release.draft -eq $false) {
        Assert-ReleaseIdentity -Release $Release -ExpectedCommit $ExpectedCommit -Notes $Notes -MustBeDraft $false
        return 'already-published'
    }
    throw 'The release draft state is invalid.'
}

function Get-ReleaseAssets {
    param([long]$ReleaseId)
    $result = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le 10; $page++) {
        $response = (Send-GitHubRequest -Method 'GET' -Uri ($script:repoBase + '/releases/' + $ReleaseId + '/assets?per_page=100&page=' + $page)).Data
        $pageAssets = @($response)
        foreach ($asset in $pageAssets) { [void]$result.Add($asset) }
        if ($pageAssets.Count -lt 100) { return @($result) }
    }
    throw 'GitHub returned an unexpectedly large release asset list.'
}

function Get-StreamSha256 {
    param([System.IO.Stream]$Stream, [long]$ExpectedLength)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 65536
    $total = [long]0
    try {
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $ExpectedLength) { throw 'Release asset exceeds the expected size.' }
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
        if ($total -ne $ExpectedLength) { throw 'Release asset size does not match.' }
        return ([System.BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant())
    } finally { $sha.Dispose() }
}

function Test-AllowedReleaseAssetHost {
    param([string]$HostName)
    $allowedHosts = @(
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
        'github-releases.githubusercontent.com'
    )
    return ($allowedHosts -ccontains ([string]$HostName).ToLowerInvariant())
}

function Get-AssetStreamHash {
    param([long]$AssetId, [long]$ExpectedLength)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, ($script:repoBase + '/releases/assets/' + $AssetId))
    $request.Headers.Accept.Clear()
    $request.Headers.Accept.ParseAdd('application/octet-stream')
    $response = $null
    $downloadResponse = $null
    try {
        try { $response = $script:githubClient.SendAsync($request).GetAwaiter().GetResult() }
        catch { throw 'Could not download a release asset for verification.' }
        if ([int]$response.StatusCode -eq 302) {
            $location = $response.Headers.Location
            if ($null -eq $location -or -not $location.IsAbsoluteUri -or $location.Scheme -cne 'https' -or
                -not (Test-AllowedReleaseAssetHost -HostName $location.Host)) {
                throw 'GitHub returned an unsupported release asset download location.'
            }
            $anonymousRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $location)
            try { $downloadResponse = $script:anonymousClient.SendAsync($anonymousRequest).GetAwaiter().GetResult() }
            catch { throw 'Could not download a release asset for verification.' }
            finally { $anonymousRequest.Dispose() }
            $response.Dispose()
            $response = $downloadResponse
            $downloadResponse = $null
        }
        if ([int]$response.StatusCode -ne 200) { throw 'GitHub did not return the release asset bytes.' }
        $lengthHeader = $response.Content.Headers.ContentLength
        if ($null -ne $lengthHeader -and [long]$lengthHeader -ne $ExpectedLength) { throw 'Release asset size does not match.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            $downloadHash = Get-StreamSha256 -Stream $stream -ExpectedLength $ExpectedLength
        } finally { $stream.Dispose() }
        return $downloadHash
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $downloadResponse) { $downloadResponse.Dispose() }
        $request.Dispose()
    }
}

function Test-RemoteAssetMatches {
    param([object]$RemoteAsset, [object]$LocalAsset)
    if ([string]$RemoteAsset.name -cne [string]$LocalAsset.Name -or [long]$RemoteAsset.size -ne [long]$LocalAsset.Length) { return $false }
    $digest = [string]$RemoteAsset.digest
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { return ($Matches[1].ToLowerInvariant() -ceq [string]$LocalAsset.Sha256) }
    $downloadHash = Get-AssetStreamHash -AssetId ([long]$RemoteAsset.id) -ExpectedLength ([long]$LocalAsset.Length)
    return ($downloadHash -ceq [string]$LocalAsset.Sha256)
}

function Assert-ExactRemoteAssetNames {
    param([object[]]$RemoteAssets, [object[]]$ExpectedAssets)
    $expectedNames = @($ExpectedAssets | ForEach-Object { [string]$_.Name } | Sort-Object -CaseSensitive)
    $actualNames = @($RemoteAssets | ForEach-Object { [string]$_.name } | Sort-Object -CaseSensitive)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) { throw 'Release asset names do not match the fixed allowlist.' }
    if (@($actualNames | Select-Object -Unique).Count -ne $actualNames.Count) { throw 'GitHub returned duplicate release asset names.' }
}

function Upload-ReleaseAsset {
    param([long]$ReleaseId, [object]$LocalAsset)
    $uri = 'https://uploads.github.com/repos/' + $script:repositoryFullName + '/releases/' + $ReleaseId + '/assets?name=' + [System.Uri]::EscapeDataString([string]$LocalAsset.Name)
    $stream = [System.IO.File]::OpenRead([string]$LocalAsset.Path)
    $content = [System.Net.Http.StreamContent]::new($stream)
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
    try { return (Send-GitHubRequest -Method 'POST' -Uri $uri -Content $content).Data }
    finally { $content.Dispose(); $stream.Dispose() }
}

function New-DraftRelease {
    param([string]$ExpectedCommit, [string]$Notes)
    $body = [ordered]@{
        tag_name = $script:publishTag
        target_commitish = $ExpectedCommit
        name = 'WIREX Bridge ' + $script:publishTag
        body = $Notes
        draft = $true
        prerelease = $script:publishIsPrerelease
    }
    try { return (Send-GitHubRequest -Method 'POST' -Uri ($script:repoBase + '/releases') -Content (New-GitHubJsonContent -Value $body)).Data }
    catch {
        if (-not (Test-UnknownOutcomeError -Exception $_.Exception)) { throw }
        $recovered = Get-ReleaseByTag
        if ($null -eq $recovered) { throw 'Release creation outcome is unknown; no retry was attempted.' }
        Assert-ReleaseIdentity -Release $recovered -ExpectedCommit $ExpectedCommit -Notes $Notes -MustBeDraft $true
        return $recovered
    }
}

function Invoke-DraftAssetUpload {
    param([long]$ReleaseId, [object[]]$ExpectedAssets)
    $remoteAssets = @(Get-ReleaseAssets -ReleaseId $ReleaseId)
    $remoteNames = @($remoteAssets | ForEach-Object { [string]$_.name })
    if (@($remoteNames | Select-Object -Unique).Count -ne $remoteNames.Count) { throw 'GitHub returned duplicate release asset names.' }
    foreach ($remote in $remoteAssets) {
        if (@($ExpectedAssets | Where-Object { [string]$_.Name -ceq [string]$remote.name }).Count -eq 0) {
            throw 'The draft release already contains an asset outside the fixed allowlist.'
        }
    }
    foreach ($local in $ExpectedAssets) {
        $existing = @($remoteAssets | Where-Object { [string]$_.name -ceq [string]$local.Name })
        if ($existing.Count -gt 1) { throw 'GitHub returned duplicate assets with the same name.' }
        if ($existing.Count -eq 1) {
            if (-not (Test-RemoteAssetMatches -RemoteAsset $existing[0] -LocalAsset $local)) {
                throw 'An existing same-name release asset has different bytes; it was not overwritten.'
            }
            continue
        }
        try { $uploaded = Upload-ReleaseAsset -ReleaseId $ReleaseId -LocalAsset $local }
        catch {
            if (-not (Test-UnknownOutcomeError -Exception $_.Exception)) { throw }
            $afterUnknown = @(Get-ReleaseAssets -ReleaseId $ReleaseId | Where-Object { [string]$_.name -ceq [string]$local.Name })
            if ($afterUnknown.Count -eq 1 -and (Test-RemoteAssetMatches -RemoteAsset $afterUnknown[0] -LocalAsset $local)) { continue }
            throw 'Asset upload outcome is unknown; it was not retried.'
        }
        if (-not (Test-RemoteAssetMatches -RemoteAsset $uploaded -LocalAsset $local)) {
            throw 'The uploaded release asset does not match the local bytes.'
        }
    }
    $finalAssets = @(Get-ReleaseAssets -ReleaseId $ReleaseId)
    Assert-ExactRemoteAssetNames -RemoteAssets $finalAssets -ExpectedAssets $ExpectedAssets
    foreach ($local in $ExpectedAssets) {
        $remote = @($finalAssets | Where-Object { [string]$_.name -ceq [string]$local.Name })[0]
        if (-not (Test-RemoteAssetMatches -RemoteAsset $remote -LocalAsset $local)) { throw 'A release asset failed final hash verification.' }
    }
    return $finalAssets.Count
}

function Assert-AllReleaseAssets {
    param([long]$ReleaseId, [object[]]$ExpectedAssets)
    $remoteAssets = @(Get-ReleaseAssets -ReleaseId $ReleaseId)
    Assert-ExactRemoteAssetNames -RemoteAssets $remoteAssets -ExpectedAssets $ExpectedAssets
    foreach ($local in $ExpectedAssets) {
        $remote = @($remoteAssets | Where-Object { [string]$_.name -ceq [string]$local.Name })[0]
        if (-not (Test-RemoteAssetMatches -RemoteAsset $remote -LocalAsset $local)) { throw 'A release asset failed hash verification.' }
    }
}

function Publish-VerifiedRelease {
    param([object]$Release, [string]$ExpectedCommit, [string]$Notes)
    $body = [ordered]@{ target_commitish=$ExpectedCommit; body=$Notes; draft=$false; prerelease=$script:publishIsPrerelease }
    try {
        return (Send-GitHubRequest -Method 'PATCH' -Uri ($script:repoBase + '/releases/' + [long]$Release.id) -Content (New-GitHubJsonContent -Value $body)).Data
    } catch {
        if (-not (Test-UnknownOutcomeError -Exception $_.Exception)) { throw }
        $recovered = Get-ReleaseByTag
        if ($null -eq $recovered -or $recovered.draft -ne $false -or $recovered.prerelease -ne $script:publishIsPrerelease -or
            [string]$recovered.target_commitish -cne $ExpectedCommit -or [string]$recovered.body -cne $Notes) {
            throw 'Release publication outcome is unknown; no retry was attempted.'
        }
        return $recovered
    }
}

function Invoke-ReleasePublisher {
    param([string]$PackagePath, [string]$Commit, [string]$NotesFile, [string]$PublisherMode, [string]$RepositoryRoot,
        [string]$Tag = 'v0.1.0')
    [void](Set-PublishProfile -Tag $Tag)
    if ($PublisherMode -cnotin @('Draft', 'Publish')) { throw 'Mode must be exactly Draft or Publish.' }
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedCommit must be a full lowercase SHA-1.' }
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $expectedPackage = [System.IO.Path]::GetFullPath((Join-Path $root ('build/releases/' + $script:publishTag)))
    if (-not [System.IO.Path]::GetFullPath($PackagePath).Equals($expectedPackage, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'ReleaseDirectory must be the fixed package directory for this tag.'
    }
    Assert-LocalRepositoryIdentity -RepositoryRoot $root
    $package = Assert-PublishPackage -PackageRoot $expectedPackage -ExpectedCommit $Commit -Tag $Tag
    $notes = Get-PublishNotes -Path $NotesFile -RepositoryRoot $root -ExpectedCommit $Commit
    if (@($package.Assets | Where-Object { [string]$_.Name -ceq 'download-release.ps1' }).Count -ne 0) {
        throw 'The fixed helper asset name conflicts with a package asset.'
    }
    $script:githubClient = $null
    $script:anonymousClient = $null
    $script:token = $null
    try {
    $assets = @($package.Assets)
    $expectedRemoteAssetCount = if (Test-WirexZipOnlyVersion -Version $Tag) { 1 } else { 3 }
    if (@($assets | ForEach-Object { [string]$_.Name } | Sort-Object -Unique).Count -ne $expectedRemoteAssetCount) { throw 'Release asset names are not unique.' }
        Initialize-GitHubClient
        Assert-GitHubIdentityAndRepository
        Assert-RemoteTagCommit -ExpectedCommit $Commit
        $release = Get-ReleaseByTag
        if ($PublisherMode -ceq 'Draft') {
            if ($null -eq $release) { $release = New-DraftRelease -ExpectedCommit $Commit -Notes $notes }
            Assert-ReleaseIdentity -Release $release -ExpectedCommit $Commit -Notes $notes -MustBeDraft $true
            $assetCount = Invoke-DraftAssetUpload -ReleaseId ([long]$release.id) -ExpectedAssets $assets
            Write-Output ('Verified draft release ' + $script:publishTag + '; assets=' + $assetCount + '.')
            return
        }
        $publishAction = Get-PublishReleaseAction -Release $release -ExpectedCommit $Commit -Notes $notes
        Assert-AllReleaseAssets -ReleaseId ([long]$release.id) -ExpectedAssets $assets
        if ($publishAction -ceq 'already-published') {
            Write-Output ('Verified published release ' + $script:publishTag + '; assets=' + $assets.Count + '.')
            return
        }
        $published = Publish-VerifiedRelease -Release $release -ExpectedCommit $Commit -Notes $notes
        Assert-ReleaseIdentity -Release $published -ExpectedCommit $Commit -Notes $notes -MustBeDraft $false
        Write-Output ('Published release ' + $script:publishTag + '; assets=' + $assets.Count + '.')
    } finally {
        if ($null -ne $script:githubClient) { $script:githubClient.Dispose(); $script:githubClient=$null }
        if ($null -ne $script:anonymousClient) { $script:anonymousClient.Dispose(); $script:anonymousClient=$null }
        $script:token = $null
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    if ([string]::IsNullOrWhiteSpace($ReleaseDirectory) -or [string]::IsNullOrWhiteSpace($ExpectedCommit) -or
        [string]::IsNullOrWhiteSpace($Tag) -or [string]::IsNullOrWhiteSpace($NotesPath) -or [string]::IsNullOrWhiteSpace($Mode)) {
        throw 'Provide ReleaseDirectory, ExpectedCommit, Tag, NotesPath, and Mode.'
    }
    Invoke-ReleasePublisher -PackagePath $ReleaseDirectory -Commit $ExpectedCommit -NotesFile $NotesPath `
        -PublisherMode $Mode -RepositoryRoot $repositoryRoot -Tag $Tag
}
