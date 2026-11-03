[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^(v0\.1\.0|v0\.1\.1-test\.2|v0\.1\.1)$')]
    [string]$Tag,
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [switch]$AllowDraft
)

$ErrorActionPreference = 'Stop'
$script:stableReleaseContractPath = Join-Path $PSScriptRoot 'StableReleaseContract.psm1'
if (-not [System.IO.File]::Exists($script:stableReleaseContractPath)) { throw 'StableReleaseContract.psm1 is missing.' }
Import-Module -Name $script:stableReleaseContractPath -Force -Scope Global -ErrorAction Stop
$script:zipOnlyReleaseContractPath = Join-Path $PSScriptRoot 'ZipOnlyRelease.psm1'
if (-not [System.IO.File]::Exists($script:zipOnlyReleaseContractPath)) { throw 'ZipOnlyRelease.psm1 is missing.' }
Import-Module -Name $script:zipOnlyReleaseContractPath -Force -Scope Global -ErrorAction Stop
$script:stableReleaseLimits = Get-WirexStableReleaseLimits
$script:githubOwner = 'iCassius'
$script:githubRepository = 'WIREX_Bridge'
$script:githubApiRoot = 'https://api.github.com/repos/iCassius/WIREX_Bridge'
$script:approvedYFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:maximumManifestBytes = [long]$script:stableReleaseLimits.MaximumManifestBytes
$script:maximumAssetBytes = 128MB
$script:maximumStablePackageBytes = [long]$script:stableReleaseLimits.MaximumUncompressedBytes
$script:maximumStableArchiveBytes = [long]$script:stableReleaseLimits.MaximumArchiveBytes
$script:releaseAssetRedirectHosts = @(
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com'
)

function Test-ReleaseTag {
    param([Parameter(Mandatory=$true)][string]$Tag)
    return ($Tag -ceq 'v0.1.0' -or (Test-WirexZipOnlyVersion -Version $Tag))
}

function Get-ExpectedReleaseTests {
    param([Parameter(Mandatory=$true)][string]$Tag)
    if ($Tag -cne 'v0.1.0') { throw 'Only v0.1.0, v0.1.1-test.2, and v0.1.1 are supported.' }
    return @(
        'dmrd_test', 'direct_frame_test', 'hri_t_payload_test', 'hri_call_header_test', 'hri_t_record_test',
        'hri_lcd_identity_candidate_test', 'radio_identity_cache_test', 'direct_stream_test', 'hri_session_test', 'hri_ptt_gate_test',
        'hri_p_status_test', 'hri_downlink_session_test', 'hri_radio_protocol_test', 'operation_audio_cleanup_test', 'audio_input_cleanup_test',
        'wave_output_open_test', 'session_timing_test', 'wave_file_test', 'pcm_gain_test', 'bounded_pipe_writer_test',
        'ui_pipe_test', 'console_lifecycle_test', 'session_report_test', 'dmr_call_test', 'bm_session_test',
        'bm_udp_test', 'dmr_vocoder_test', 'ambe_dmr72_test', 'ysf_vd2_vch_test', 'voice_transcode_buffer_test',
        'pcm_resampler_test', 'bm_voice_pipeline_test', 'bm_test_profile_test', 'bm_connection_config_test', 'hri_stream_session_test',
        'bm_bridge_loopback_test', 'ui_control_protocol_v2_test', 'talkgroup_routing_test', 'bm_routing_lifecycle_test', 'routing_state_test'
    )
}

function Get-ExpectedStableReleaseFiles {
    $specification = @'
WirexBridge.exe|WirexBridge.exe|134217728
build-provenance.json|build-provenance.json|2097152
launcher-build-provenance.json|launcher-build-provenance.json|2097152
README.md|README.md|4194304
SOURCE.txt|SOURCE.txt|1048576
runtime/wirex_bridge.exe|runtime__wirex_bridge.exe|134217728
runtime/private/device-y.bin|runtime__private__device-y.bin|100
runtime/start-bm-radio-bridge.ps1|runtime__start-bm-radio-bridge.ps1|1048576
runtime/start-ui.ps1|runtime__start-ui.ps1|1048576
runtime/bridge-user-config.psm1|runtime__bridge-user-config.psm1|1048576
runtime/docs/配置与桌面操作.md|runtime__docs__desktop-user-config.md|4194304
runtime/docs/连接配置.md|runtime__docs__connection-profile.md|4194304
runtime/docs/音量调节.md|runtime__docs__audio-gain.md|4194304
runtime/ui/windows/bridge-ui.ps1|runtime__ui__windows__bridge-ui.ps1|4194304
runtime/ui/windows/BridgeSupervisor.cs|runtime__ui__windows__BridgeSupervisor.cs|4194304
runtime/ui/windows/MainWindow.xaml|runtime__ui__windows__MainWindow.xaml|4194304
runtime/ui/windows/SettingsWindow.xaml|runtime__ui__windows__SettingsWindow.xaml|4194304
runtime/licenses/dmr_signal/COPYING.GPL-3.0.txt|runtime__licenses__dmr-signal__COPYING.GPL-3.0.txt|4194304
runtime/licenses/dmr_signal/NOTICE.md|runtime__licenses__dmr-signal__NOTICE.md|1048576
runtime/licenses/droidstar_mbe/COPYING.GPL-3.0.txt|runtime__licenses__droidstar-mbe__COPYING.GPL-3.0.txt|4194304
runtime/licenses/droidstar_mbe/ISC-NOTICE.txt|runtime__licenses__droidstar-mbe__ISC-NOTICE.txt|1048576
runtime/licenses/droidstar_mbe/source-manifest.json|runtime__licenses__droidstar-mbe__source-manifest.json|4194304
runtime/docs/BM来话身份显示.md|runtime__docs__bm-call-identity.md|4194304
runtime/docs/R106_IPC第二版.md|runtime__docs__r106-ipc-v2.md|4194304
runtime/docs/R106_配置迁移与测试.md|runtime__docs__r106-profile-migration-test.md|4194304
runtime/docs/R108_收发路由状态与alpha6验收.md|runtime__docs__r108-routing-state-alpha6.md|4194304
runtime/docs/R109_下行状态与动态组修复.md|runtime__docs__r109-downlink-dynamic-groups.md|4194304
runtime/docs/R109_动态组激活实现.md|runtime__docs__r109-dynamic-group-activation.md|4194304
runtime/ui/windows/RadioIdentity.psm1|runtime__ui__windows__radio-identity.psm1|1048576
runtime/docs/R112_A_网络音频指标.md|runtime__docs__r112-a-network-audio-metrics.md|4194304
runtime/docs/R113_LCD核心实现.md|runtime__docs__r113-lcd-core-implementation.md|4194304
runtime/docs/R113_身份与LCD接线.md|runtime__docs__r113-identity-lcd-integration.md|4194304
runtime/ui/windows/RadioCat.psm1|runtime__ui__windows__radio-cat.psm1|1048576
runtime/docs/R116_CAT能力与控制实现.md|runtime__docs__r116-cat-controls.md|4194304
runtime/docs/R116_电台控制界面.md|runtime__docs__r116-radio-controls-ui.md|4194304
runtime/ui/windows/RadioCatUi.ps1|runtime__ui__windows__radio-cat-ui.ps1|1048576
runtime/ui/windows/RadioDevices.psm1|runtime__ui__windows__radio-devices.psm1|1048576
runtime/ui/windows/BmServers.psm1|runtime__ui__windows__bm-servers.psm1|1048576
runtime/ui/windows/BmManagement.psm1|runtime__ui__windows__bm-management.psm1|1048576
runtime/ui/windows/BmManagementUi.ps1|runtime__ui__windows__bm-management-ui.ps1|1048576
runtime/ui/windows/PortableConfig.psm1|runtime__ui__windows__portable-config.psm1|1048576
runtime/ui/windows/ChannelActivationState.psm1|runtime__ui__windows__channel-activation-state.psm1|1048576
'@
    foreach ($line in ($specification -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line.Split('|')
        $contractMaximum = [long](Get-WirexStableMaximumFileBytes -Path $parts[0])
        if ([long]$parts[2] -ne $contractMaximum) { throw ('Stable size limit drift for ' + $parts[0]) }
        [pscustomobject]@{ Path=$parts[0]; AssetName=$parts[1]; MaximumBytes=$contractMaximum }
    }
}

function Get-ExpectedReleaseDirectories {
    param([string]$Tag)
    if ($Tag -ceq 'v0.1.0') {
        return @('runtime','runtime/docs','runtime/licenses','runtime/licenses/dmr_signal',
            'runtime/licenses/droidstar_mbe','runtime/private','runtime/ui','runtime/ui/windows')
    }
    if (Test-WirexZipOnlyVersion -Version $Tag) {
        return @(Get-WirexZipOnlyReleaseProfile -Version $Tag).Directories
    }
    throw 'Only v0.1.0, v0.1.1-test.2, and v0.1.1 are supported.'
}

function Get-ExpectedReleaseFiles {
    param([Parameter(Mandatory=$true)][string]$Tag)
    if ($Tag -ceq 'v0.1.0') { return @(Get-ExpectedStableReleaseFiles) }
    throw 'Only v0.1.0, v0.1.1-test.2, and v0.1.1 are supported.'
}

function Assert-JsonObjectKeysUnique {
    param([Parameter(Mandatory=$true)][string]$JsonText)
    $objects = New-Object System.Collections.ArrayList
    $index = 0
    while ($index -lt $JsonText.Length) {
        $character = $JsonText[$index]
        if ($character -eq '{') {
            $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            [void]$objects.Add($keys)
            $index++
            continue
        }
        if ($character -eq '}') {
            if ($objects.Count -eq 0) { throw 'Release JSON 对象结构无效。' }
            $objects.RemoveAt($objects.Count - 1)
            $index++
            continue
        }
        if ($character -ne '"') { $index++; continue }

        $start = $index + 1
        $cursor = $start
        $escaped = $false
        while ($cursor -lt $JsonText.Length) {
            $part = $JsonText[$cursor]
            if ($escaped) { $escaped = $false; $cursor++; continue }
            if ($part -eq '\') { $escaped = $true; $cursor++; continue }
            if ($part -eq '"') { break }
            $cursor++
        }
        if ($cursor -ge $JsonText.Length) { throw 'Release JSON 字符串没有闭合。' }
        $rawString = $JsonText.Substring($start, $cursor - $start)
        $after = $cursor + 1
        while ($after -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$after])) { $after++ }
        if ($objects.Count -gt 0 -and $after -lt $JsonText.Length -and $JsonText[$after] -eq ':') {
            if ($rawString.Contains('\')) { throw 'Release JSON 字段名不能使用转义写法。' }
            $keys = [System.Collections.Generic.HashSet[string]]$objects[$objects.Count - 1]
            if (-not $keys.Add($rawString)) { throw "Release JSON 字段重复：$rawString" }
        }
        $index = $cursor + 1
    }
    if ($objects.Count -ne 0) { throw 'Release JSON 对象结构无效。' }
}

function ConvertFrom-StrictJson {
    param([Parameter(Mandatory=$true)][string]$JsonText, [Parameter(Mandatory=$true)][string]$Label)
    Assert-JsonObjectKeysUnique -JsonText $JsonText
    try { return ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop }
    catch { throw "$Label JSON 无效。" }
}

function Assert-ExactJsonObject {
    param(
        [Parameter(Mandatory=$true)][object]$Value,
        [Parameter(Mandatory=$true)][string[]]$ExpectedNames,
        [string[]]$OptionalNames = @(),
        [Parameter(Mandatory=$true)][string]$Label
    )
    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or
        $Value -is [bool] -or $Value -is [ValueType]) { throw "$Label 必须是 JSON 对象。" }
    $properties = @($Value.PSObject.Properties)
    $allowedNames = @($ExpectedNames) + @($OptionalNames)
    if ($properties.Count -lt $ExpectedNames.Count -or $properties.Count -gt $allowedNames.Count) {
        throw "$Label 字段不完整或包含未知字段。"
    }
    foreach ($property in $properties) {
        if ($allowedNames -cnotcontains $property.Name) { throw "$Label 包含未知字段：$($property.Name)" }
    }
    foreach ($name in $ExpectedNames) {
        $matches = @($properties | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -ne 1) { throw "$Label 缺少字段或字段重复：$name" }
    }
    foreach ($name in $OptionalNames) {
        $matches = @($properties | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -gt 1) { throw "$Label 字段重复：$name" }
    }
}

function Test-JsonUnsignedInteger {
    param([object]$Value, [long]$Minimum = 0, [long]$Maximum = 9223372036854775807)
    if ($null -eq $Value -or $Value -is [bool] -or
        ($Value -isnot [byte] -and $Value -isnot [uint16] -and $Value -isnot [uint32] -and
         $Value -isnot [uint64] -and $Value -isnot [int16] -and $Value -isnot [int32] -and
         $Value -isnot [int64])) { return $false }
    try { $number = [decimal]$Value } catch { return $false }
    return ($number -ge $Minimum -and $number -le $Maximum)
}

function Test-Sha256Text {
    param([object]$Value)
    return ($Value -is [string] -and $Value -cmatch '^[0-9a-fA-F]{64}$')
}

function Assert-RelativeMetadataPath {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or
        $Path.StartsWith('/') -or $Path.StartsWith('//') -or $Path.Contains('//') -or
        $Path -match '(^|/)\.{1,2}(/|$)' -or $Path -match '[\x00-\x1f\x7f]') {
        throw "$Label 必须是规范的相对 POSIX 路径。"
    }
    return $Path
}

function Test-PathWithinDirectory {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Directory)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-StableManifestDocument {
    param([Parameter(Mandatory=$true)][object]$Manifest)
    Assert-ExactJsonObject -Value $Manifest -ExpectedNames @(
        'schema_version','package_kind','package_status','version','tag_candidate','tag_created',
        'github_release_published','source','build','release_scope','not_included','hardware_validation',
        'approved_y_fixture','excluded_private_files','runtime_directories','manifest_asset_name','files','launcher_build') -Label 'stable release manifest'
    if (-not (Test-JsonUnsignedInteger $Manifest.schema_version 1 1) -or
        [string]$Manifest.package_kind -cne 'wirex_bridge_stable_release_green_directory' -or
        [string]$Manifest.package_status -cne 'root_audit_passed' -or
        [string]$Manifest.version -cne 'v0.1.0' -or [string]$Manifest.tag_candidate -cne 'v0.1.0' -or
        $Manifest.tag_created -isnot [bool] -or $Manifest.github_release_published -isnot [bool] -or
        [string]$Manifest.manifest_asset_name -cne 'manifest.json' -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.release_scope)) {
        throw 'Stable manifest version, package type, audit state, or release identity is invalid.'
    }
    Assert-ExactJsonObject -Value $Manifest.source -ExpectedNames @('repository','commit','working_tree_clean') -Label 'stable manifest.source'
    if ([string]$Manifest.source.repository -cne 'https://github.com/iCassius/WIREX_Bridge.git' -or
        [string]$Manifest.source.commit -cnotmatch '^[0-9a-f]{40}$' -or $Manifest.source.working_tree_clean -ne $true) {
        throw 'Stable manifest source identity is invalid.'
    }
    Assert-ExactJsonObject -Value $Manifest.build -ExpectedNames @(
        'source_commit','source_tree_clean','compile_only','build_completed','output_directory','evidence_log',
        'evidence_log_sha256','provenance_asset','provenance_sha256','result','passed_test_count','passed_tests',
        'compiler_warnings','compiler_errors','executable_sha256') -Label 'stable manifest.build'
    if ([string]$Manifest.build.source_commit -cne [string]$Manifest.source.commit -or
        $Manifest.build.source_tree_clean -ne $true -or $Manifest.build.compile_only -ne $false -or
        $Manifest.build.build_completed -ne $true -or [string]$Manifest.build.result -cne 'passed' -or
        [string]$Manifest.build.provenance_asset -cne 'build-provenance.json' -or
        -not (Test-JsonUnsignedInteger $Manifest.build.compiler_warnings 0 0) -or
        -not (Test-JsonUnsignedInteger $Manifest.build.compiler_errors 0 0)) {
        throw 'Stable manifest does not attest the Native build.'
    }
    [void](Assert-RelativeMetadataPath -Path ([string]$Manifest.build.output_directory) -Label 'stable build.output_directory')
    [void](Assert-RelativeMetadataPath -Path ([string]$Manifest.build.evidence_log) -Label 'stable build.evidence_log')
    foreach ($hash in @($Manifest.build.evidence_log_sha256,$Manifest.build.provenance_sha256,$Manifest.build.executable_sha256)) {
        if (-not (Test-Sha256Text $hash)) { throw 'Stable Native build hash field is invalid.' }
    }
    $expectedTests = @(Get-ExpectedReleaseTests -Tag 'v0.1.0')
    $tests = @($Manifest.build.passed_tests)
    if (-not (Test-JsonUnsignedInteger $Manifest.build.passed_test_count 1 1000) -or
        [int]$Manifest.build.passed_test_count -ne $expectedTests.Count -or $tests.Count -ne $expectedTests.Count) {
        throw 'Stable manifest Native test count is invalid.'
    }
    for ($i=0; $i -lt $expectedTests.Count; $i++) {
        if ($tests[$i] -isnot [string] -or [string]$tests[$i] -cne $expectedTests[$i]) { throw 'Stable Native test order is not exact.' }
    }
    Assert-ExactJsonObject -Value $Manifest.approved_y_fixture -ExpectedNames @('path','length_bytes','sha256') -Label 'stable manifest.approved_y_fixture'
    if ([string]$Manifest.approved_y_fixture.path -cne 'runtime/private/device-y.bin' -or
        -not (Test-JsonUnsignedInteger $Manifest.approved_y_fixture.length_bytes 100 100) -or
        [string]$Manifest.approved_y_fixture.sha256 -cne $script:approvedYFixtureSha256) {
        throw 'Stable manifest does not retain the approved HRI protocol template.'
    }
    $excluded = @($Manifest.excluded_private_files | ForEach-Object { [string]$_ })
    foreach ($required in @('config.json','runtime/config.json','credentials/','tempSecrets/','logs/','runtime/private/credentials/','callsign','password','api_key')) {
        if ($excluded -cnotcontains $required) { throw 'Stable manifest does not explicitly exclude personal config, credentials, logs, and local identity.' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.release_scope) -or @($Manifest.not_included).Count -lt 1) {
        throw 'Stable manifest has no release scope or exclusions.'
    }

    Assert-ExactJsonObject -Value $Manifest.launcher_build -ExpectedNames @(
        'source_commit','source_path','source_sha256','compiler_family','compiler_version','target','output_directory',
        'executable_asset','executable_sha256','provenance_asset','provenance_sha256','build_log_path','build_log_sha256') -Label 'stable manifest.launcher_build'
    if ([string]$Manifest.launcher_build.source_commit -cne [string]$Manifest.source.commit -or
        [string]$Manifest.launcher_build.source_path -cne 'ui/launcher/WirexBridgeLauncher.cs' -or
        -not (Test-Sha256Text $Manifest.launcher_build.source_sha256) -or
        [string]$Manifest.launcher_build.compiler_family -cne 'Microsoft .NET Framework csc.exe' -or
        [string]$Manifest.launcher_build.target -cne 'x64 Windows GUI executable' -or
        [string]$Manifest.launcher_build.executable_asset -cne 'WirexBridge.exe' -or
        [string]$Manifest.launcher_build.provenance_asset -cne 'launcher-build-provenance.json') {
        throw 'Stable launcher build source or compiler metadata is invalid.'
    }
    foreach ($key in @('output_directory','build_log_path')) {
        [void](Assert-RelativeMetadataPath -Path ([string]$Manifest.launcher_build.PSObject.Properties[$key].Value) -Label ('launcher_build.' + $key))
    }
    foreach ($hash in @($Manifest.launcher_build.executable_sha256,$Manifest.launcher_build.provenance_sha256,$Manifest.launcher_build.build_log_sha256)) {
        if (-not (Test-Sha256Text $hash)) { throw 'Stable launcher build hash field is invalid.' }
    }

    $expectedFiles = @(Get-ExpectedStableReleaseFiles)
    $files = @($Manifest.files)
    if ($files.Count -ne $expectedFiles.Count) { throw ('Stable manifest file count differs from the fixed ' + $expectedFiles.Count + '-file inventory.') }
    if ((@($Manifest.runtime_directories | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive) -join "`n") -cne
        (@(Get-ExpectedReleaseDirectories -Tag 'v0.1.0' | Sort-Object -CaseSensitive) -join "`n")) {
        throw 'Stable manifest runtime directory inventory is invalid.'
    }
    $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $assetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    foreach ($record in $files) {
        Assert-ExactJsonObject -Value $record -ExpectedNames @('path','asset_name','length_bytes','sha256','source') -Label 'stable manifest.files[]'
        $path = [string](Assert-RelativeMetadataPath -Path ([string]$record.path) -Label 'stable manifest.files[].path')
        $matching = @($expectedFiles | Where-Object { [string]$_.Path -ceq $path })
        if ($matching.Count -ne 1 -or -not $pathSet.Add($path) -or
            [string]$record.asset_name -cne [string]$matching[0].AssetName -or -not $assetSet.Add([string]$record.asset_name)) {
            throw 'Stable manifest contains an unknown, duplicate, or incorrectly named file.'
        }
        $maximumFileBytes = [long](Get-WirexStableMaximumFileBytes -Path $path)
        if ([long]$matching[0].MaximumBytes -ne $maximumFileBytes -or
            -not (Test-JsonUnsignedInteger $record.length_bytes 1 $maximumFileBytes) -or
            -not (Test-WirexStableLengthWithinLimit -Length ([long]$record.length_bytes) -MaximumBytes $maximumFileBytes) -or
            -not (Test-Sha256Text $record.sha256) -or $record.source -isnot [string] -or
            [string]$record.source -match '(?i)[A-Z]:\\|\\\\') {
            throw "Stable manifest file metadata is invalid: $path"
        }
        if ($path -ceq 'runtime/private/device-y.bin' -and
            ([long]$record.length_bytes -ne 100 -or [string]$record.sha256 -cne $script:approvedYFixtureSha256)) {
            throw 'Stable manifest HRI protocol template does not match the approved fixture.'
        }
        $total += [long]$record.length_bytes
        if (-not (Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes ([long]$script:stableReleaseLimits.MaximumUncompressedBytes))) {
            throw 'Stable package exceeds the 2 GiB uncompressed size limit.'
        }
    }
    foreach ($expected in $expectedFiles) { if (-not $pathSet.Contains([string]$expected.Path)) { throw "Stable manifest is missing $($expected.Path)." } }
    foreach ($pair in @(
        @('WirexBridge.exe',$Manifest.launcher_build.executable_sha256),
        @('launcher-build-provenance.json',$Manifest.launcher_build.provenance_sha256),
        @('build-provenance.json',$Manifest.build.provenance_sha256),
        @('runtime/wirex_bridge.exe',$Manifest.build.executable_sha256))) {
        $fileRecord = @($files | Where-Object { [string]$_.path -ceq [string]$pair[0] })
        if ($fileRecord.Count -ne 1 -or [string]$fileRecord[0].sha256 -cne [string]$pair[1]) { throw 'Stable manifest build hashes do not match its file records.' }
    }
    return [pscustomobject]@{ Manifest=$Manifest; Files=$files; TotalBytes=$total }
}

function Test-ManifestDocument {
    param([Parameter(Mandatory=$true)][object]$Manifest, [Parameter(Mandatory=$true)][string]$RequestedTag)
    if ($RequestedTag -cne 'v0.1.0') { throw 'Only the stable v0.1.0 manifest is validated by this downloader.' }
    return (Test-StableManifestDocument -Manifest $Manifest)
}

function Select-ReleaseCandidate {
    param([object[]]$Releases, [Parameter(Mandatory=$true)][string]$RequestedTag, [switch]$AllowDraft)
    if (-not (Test-ReleaseTag -Tag $RequestedTag)) { throw 'Requested release tag is not in a registered WIREX Bridge download profile.' }
    $matches = @($Releases | Where-Object { [string]$_.tag_name -ceq $RequestedTag })
    if ($matches.Count -ne 1) { throw 'GitHub Release 列表中没有唯一匹配的 tag。' }
    $release = $matches[0]
    $expectedPrerelease = if (Test-WirexZipOnlyVersion -Version $RequestedTag) {
        [bool](Get-WirexZipOnlyReleaseProfile -Version $RequestedTag).IsPrerelease
    } else {
        ($RequestedTag -cne 'v0.1.0')
    }
    if ($AllowDraft) {
        if ($release.draft -ne $true -or $release.prerelease -ne $expectedPrerelease) {
            throw '-AllowDraft 只接受 draft 且 prerelease 状态符合 tag 类型的 Release。'
        }
    } elseif ($release.draft -ne $false -or $release.prerelease -ne $expectedPrerelease) {
        if ($RequestedTag -ceq 'v0.1.0') { throw 'v0.1.0 必须是 stable Release（prerelease=false）。' }
        throw '默认只下载已发布的 prerelease；草稿验收需显式传入 -AllowDraft。'
    }
    return $release
}

function Assert-ReleaseTargetCommitish {
    param([Parameter(Mandatory=$true)][object]$Release, [Parameter(Mandatory=$true)][string]$SourceCommit)
    if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $Release.target_commitish -isnot [string] -or
        [string]$Release.target_commitish -cne $SourceCommit) {
        throw 'GitHub Release target_commitish 与 manifest.source.commit 不一致。'
    }
    return $true
}

function Resolve-ReleaseAssetInventory {
    param([Parameter(Mandatory=$true)][object]$Release, [Parameter(Mandatory=$true)][object]$ValidatedManifest,
        [Parameter(Mandatory=$true)][string]$Tag)
    if ($Tag -ceq 'v0.1.0') {
        $expectedStableNames = @('WIREX_Bridge_v0.1.0.zip','manifest.json','SHA256SUMS.txt')
        if (@($Release.assets).Count -ne 3) { throw 'Stable GitHub Release must contain exactly ZIP, manifest.json, and SHA256SUMS.txt.' }
        $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $expectedStableNames) { [void]$expectedSet.Add($name) }
        $assetMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
        $idSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($asset in @($Release.assets)) {
            $name = [string]$asset.name
            if (-not $expectedSet.Contains($name) -or $assetMap.ContainsKey($name) -or
                -not (Test-JsonUnsignedInteger $asset.id 1 9223372036854775807) -or
                -not $idSet.Add(([long]$asset.id).ToString([Globalization.CultureInfo]::InvariantCulture)) -or
                [string]$asset.state -cne 'uploaded' -or
                -not (Test-JsonUnsignedInteger $asset.size 1 ([long]$script:maximumStableArchiveBytes)) -or
                -not (Test-WirexStableLengthWithinLimit -Length ([long]$asset.size) -MaximumBytes ([long]$script:stableReleaseLimits.MaximumArchiveBytes))) {
                throw 'Stable GitHub Release contains an invalid, duplicated, or unexpected asset.'
            }
            $assetMap[$name] = $asset
        }
        if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$assetMap['manifest.json'].size) -MaximumBytes ([long]$script:stableReleaseLimits.MaximumManifestBytes)) -or
            [long]$assetMap['SHA256SUMS.txt'].size -gt 4096 -or
            -not $assetMap.ContainsKey('WIREX_Bridge_v0.1.0.zip')) {
            throw 'Stable Release ZIP, manifest, or checksum asset size is outside fixed limits.'
        }
        return $assetMap
    }
    throw 'Only the stable v0.1.0 Release uses a manifest asset inventory.'
}

function Get-DownloadDestinationContext {
    param([Parameter(Mandatory=$true)][string]$Destination)
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'Destination 不能为空。' }
    try { $fullPath = [System.IO.Path]::GetFullPath($Destination) }
    catch { throw 'Destination 路径无效。' }
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf) -or
        $leaf.Contains(':') -or $leaf.EndsWith('.') -or $leaf.EndsWith(' ')) {
        throw 'Destination 必须是非根目录下的普通新目录路径。'
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Destination 的父目录必须已经存在。' }
    if (Test-Path -LiteralPath $fullPath) { throw "Destination 已存在，拒绝覆盖：$fullPath" }
    $staging = Join-Path $parent ('.wirex-release-staging-' + [guid]::NewGuid().ToString('N'))
    $staging = [System.IO.Path]::GetFullPath($staging)
    if (-not (Test-PathWithinDirectory -Path $staging -Directory $parent) -or (Test-Path -LiteralPath $staging)) {
        throw '下载暂存目录路径无效或已存在。'
    }
    return [pscustomobject]@{ Destination=$fullPath; Parent=$parent; Staging=$staging }
}

function Assert-DownloadStagingRoot {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { throw 'Download staging root is missing.' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Download staging root must be a regular directory without a reparse point.'
    }
}

function New-DownloadStagingRoot {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not ('WirexReleaseDownloader.NativeDirectory' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WirexReleaseDownloader {
    public static class NativeDirectory {
        [DllImport("kernel32.dll", EntryPoint="CreateDirectoryW", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CreateDirectory(string path, IntPtr securityAttributes);
    }
}
'@ -ErrorAction Stop | Out-Null
    }
    if ([WirexReleaseDownloader.NativeDirectory]::CreateDirectory($Path, [IntPtr]::Zero)) { return $true }
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($errorCode -eq 183 -or $errorCode -eq 80) { throw 'Download staging path is already occupied.' }
    throw (New-Object System.ComponentModel.Win32Exception($errorCode)).Message
}

function Test-DownloadedFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][long]$ExpectedLength,
        [Parameter(Mandatory=$true)][string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw '下载文件缺失。' }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([long]$item.Length -ne $ExpectedLength) { throw '下载文件长度与 manifest 不一致。' }
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $ExpectedSha256.ToLowerInvariant()) { throw '下载文件 SHA-256 与 manifest 不一致。' }
    return $actualHash
}

function Get-GitCredentialToken {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) { throw '没有找到 Git；请先在 GitHub 登录并使用现有 Git Credential Manager 保存凭据。' }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $gitCommand.Source
    $startInfo.Arguments = 'credential fill'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $output = ''
    $errorOutput = ''
    try {
        if (-not $process.Start()) { throw '无法调用现有 Git Credential Manager。' }
        $process.StandardInput.Write("protocol=https`nhost=github.com`n`n")
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            $killFailed = $false
            try { $process.Kill() } catch { $killFailed = $true }
            $confirmedExit = $false
            try { $confirmedExit = $process.WaitForExit(5000) } catch { $confirmedExit = $false }
            if (-not $confirmedExit) {
                throw '读取已保存的 GitHub 登录凭据超时；终止凭据助手后仍无法确认其退出，请检查残留进程。'
            }
            if ($killFailed) {
                throw '读取已保存的 GitHub 登录凭据超时；终止请求失败，但已确认凭据助手退出。'
            }
            throw '读取已保存的 GitHub 登录凭据超时；凭据助手已终止。请先在 GitHub 登录并使用现有 Git Credential Manager。'
        }
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) { throw '没有找到可用的 GitHub 登录凭据。请先在 GitHub 登录并使用现有 Git Credential Manager。' }
        $token = ''
        foreach ($line in ($output -split "`r?`n")) {
            if ($line.StartsWith('password=', [System.StringComparison]::Ordinal)) {
                $token = $line.Substring(9)
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Git Credential Manager 未提供 GitHub 凭据。请先在 GitHub 登录并使用现有 Git Credential Manager。' }
        return $token
    } catch {
        if ($_.Exception.Message -match 'GitHub|Credential Manager|凭据助手|超时|无法调用') { throw }
        throw '读取已保存的 GitHub 登录凭据失败；请先在 GitHub 登录并使用现有 Git Credential Manager。'
    } finally {
        $output = $null
        $errorOutput = $null
        if ($null -ne $process) { $process.Dispose() }
    }
}

function New-GitHubApiUri {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('tag', 'list', 'asset')][string]$Kind,
        [string]$Tag,
        [long]$AssetId,
        [int]$Page = 1
    )
    switch ($Kind) {
        'tag' {
            if (-not (Test-ReleaseTag -Tag $Tag)) { throw 'Only v0.1.0, v0.1.1-test.2, and v0.1.1 are supported.' }
            return [Uri]($script:githubApiRoot + '/releases/tags/' + $Tag)
        }
        'list' {
            if ($Page -lt 1 -or $Page -gt 100) { throw 'Release 列表页码超出安全范围。' }
            return [Uri]($script:githubApiRoot + '/releases?per_page=100&page=' + $Page.ToString([Globalization.CultureInfo]::InvariantCulture))
        }
        'asset' {
            if ($AssetId -le 0) { throw 'Release asset ID 无效。' }
            return [Uri]($script:githubApiRoot + '/releases/assets/' + $AssetId.ToString([Globalization.CultureInfo]::InvariantCulture))
        }
    }
}

function Test-AllowedReleaseAssetRedirectHost {
    param([string]$HostName)
    return ($script:releaseAssetRedirectHosts -ccontains ([string]$HostName).ToLowerInvariant())
}

function Open-ReleaseHttpResponse {
    param([Parameter(Mandatory=$true)][Uri]$Uri, [string]$Token, [string]$Accept = 'application/vnd.github+json')
    if ($Uri.Scheme -cne 'https' -or
        ($Uri.Host -cne 'api.github.com' -and -not (Test-AllowedReleaseAssetRedirectHost -HostName $Uri.Host))) {
        throw '下载地址不在允许的 HTTPS 主机范围内。'
    }
    if ($Uri.Host -ceq 'api.github.com' -and
        $Uri.AbsolutePath -notlike '/repos/iCassius/WIREX_Bridge/*') {
        throw 'GitHub API 地址不属于固定仓库。'
    }
    if ((Test-AllowedReleaseAssetRedirectHost -HostName $Uri.Host) -and -not [string]::IsNullOrEmpty($Token)) {
        throw 'Release CDN 请求不得携带 GitHub 登录凭据。'
    }
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.Accept = $Accept
    $request.UserAgent = 'WIREX-Bridge-release-downloader'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    if ($Uri.Host -ceq 'api.github.com') {
        if ([string]::IsNullOrEmpty($Token)) { throw 'GitHub API 请求缺少现有登录凭据。' }
        $request.Headers.Add('Authorization', 'Bearer ' + $Token)
        $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
    }
    try { return [System.Net.HttpWebResponse]$request.GetResponse() }
    catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) { return [System.Net.HttpWebResponse]$_.Exception.Response }
        throw 'GitHub HTTPS 请求失败；请检查网络和已保存的 GitHub 登录状态。'
    } catch {
        throw 'GitHub HTTPS 请求失败；未显示认证信息或响应正文。'
    }
}

function Read-ResponseBytes {
    param([Parameter(Mandatory=$true)][System.Net.HttpWebResponse]$Response, [Parameter(Mandatory=$true)][long]$MaximumBytes)
    if ($Response.ContentLength -ge 0 -and
        -not (Test-WirexStableLengthWithinLimit -Length ([long]$Response.ContentLength) -MaximumBytes $MaximumBytes)) {
        throw 'GitHub 响应超过允许的大小上限。'
    }
    $stream = $Response.GetResponseStream()
    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 65536
    $total = [long]0
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if (-not (Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes $MaximumBytes)) {
                throw 'GitHub 响应超过允许的大小上限。'
            }
            $memory.Write($buffer, 0, $read)
        }
        return $memory.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $memory.Dispose()
    }
}

function ConvertFrom-ResponseJson {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes, [Parameter(Mandatory=$true)][string]$Label)
    $jsonText = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($jsonText.Length -gt 0 -and $jsonText[0] -eq [char]0xfeff) { $jsonText = $jsonText.Substring(1) }
    return ConvertFrom-StrictJson -JsonText $jsonText -Label $Label
}

function Get-GitHubJson {
    param([Parameter(Mandatory=$true)][Uri]$Uri, [Parameter(Mandatory=$true)][string]$Token)
    $response = Open-ReleaseHttpResponse -Uri $Uri -Token $Token
    try {
        $status = [int]$response.StatusCode
        if ($status -ne 200) { throw "GitHub API 请求失败（HTTP $status）。请确认 Release tag 和私有仓库权限。" }
        $bytes = Read-ResponseBytes -Response $response -MaximumBytes 4MB
        return ConvertFrom-ResponseJson -Bytes $bytes -Label 'GitHub API response'
    } finally { $response.Close() }
}

function Get-ReleaseForTag {
    param([Parameter(Mandatory=$true)][string]$RequestedTag, [Parameter(Mandatory=$true)][string]$Token, [switch]$AllowDraft)
    if (-not $AllowDraft) {
        $release = Get-GitHubJson -Uri (New-GitHubApiUri -Kind tag -Tag $RequestedTag) -Token $Token
        return Select-ReleaseCandidate -Releases @($release) -RequestedTag $RequestedTag
    }
    $allReleases = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le 100; $page++) {
        $items = Get-GitHubJson -Uri (New-GitHubApiUri -Kind list -Page $page) -Token $Token
        if ($items -isnot [array]) { throw 'GitHub Release 列表响应格式无效。' }
        foreach ($item in $items) { [void]$allReleases.Add($item) }
        if ($items.Count -lt 100) { break }
        if ($page -eq 100) { throw 'GitHub Release 列表超过安全分页上限。' }
    }
    return Select-ReleaseCandidate -Releases @($allReleases.ToArray()) -RequestedTag $RequestedTag -AllowDraft
}

function Get-ReleaseAssetResponse {
    param([Parameter(Mandatory=$true)][long]$AssetId, [Parameter(Mandatory=$true)][string]$Token)
    $response = Open-ReleaseHttpResponse -Uri (New-GitHubApiUri -Kind asset -AssetId $AssetId) `
        -Token $Token -Accept 'application/octet-stream'
    $status = [int]$response.StatusCode
    if ($status -eq 200) { return $response }
    if ($status -ne 302) { $response.Close(); throw "GitHub asset 下载失败（HTTP $status）。" }
    $locationText = [string]$response.Headers['Location']
    $response.Close()
    $redirectUri = $null
    if (-not [Uri]::TryCreate($locationText, [UriKind]::Absolute, [ref]$redirectUri) -or
        $redirectUri.Scheme -cne 'https' -or
        -not (Test-AllowedReleaseAssetRedirectHost -HostName $redirectUri.Host)) {
        throw 'GitHub asset 响应跳转到未批准的下载主机。'
    }
    $redirectResponse = Open-ReleaseHttpResponse -Uri $redirectUri -Accept 'application/octet-stream'
    if ([int]$redirectResponse.StatusCode -ne 200) {
        $redirectResponse.Close()
        throw 'GitHub asset CDN 没有返回完整文件。'
    }
    return $redirectResponse
}

function Read-ReleaseManifestAsset {
    param([Parameter(Mandatory=$true)][object]$Asset, [Parameter(Mandatory=$true)][string]$Token)
    $response = Get-ReleaseAssetResponse -AssetId ([long]$Asset.id) -Token $Token
    try {
        if ($response.ContentLength -ge 0 -and [long]$response.ContentLength -ne [long]$Asset.size) {
            throw 'manifest asset 响应长度与 GitHub 元数据不一致。'
        }
        $bytes = Read-ResponseBytes -Response $response -MaximumBytes ([long]$script:maximumManifestBytes)
        if ($bytes.Length -ne [long]$Asset.size) { throw 'manifest asset 下载长度与 GitHub 元数据不一致。' }
        if (-not [string]::IsNullOrWhiteSpace([string]$Asset.digest)) {
            if ([string]$Asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'GitHub manifest asset digest 格式无效。' }
            $actual = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
            if ($actual -cne $Matches[1].ToLowerInvariant()) { throw 'GitHub manifest asset digest 校验失败。' }
        }
        return $bytes
    } finally { $response.Close() }
}

function Write-ReleaseAssetToFile {
    param(
        [Parameter(Mandatory=$true)][object]$Asset,
        [Parameter(Mandatory=$true)][string]$Token,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][long]$ExpectedLength,
        [Parameter(Mandatory=$true)][long]$MaximumBytes
    )
    if ([long]$Asset.size -ne $ExpectedLength -or
        -not (Test-WirexStableLengthWithinLimit -Length $ExpectedLength -MaximumBytes $MaximumBytes)) {
        throw "Release asset 大小与 manifest 不一致：$($Asset.name)"
    }
    $response = Get-ReleaseAssetResponse -AssetId ([long]$Asset.id) -Token $Token
    $sourceStream = $null
    $targetStream = $null
    try {
        if ($response.ContentLength -ge 0 -and [long]$response.ContentLength -ne $ExpectedLength) {
            throw "Release asset 响应长度与 manifest 不一致：$($Asset.name)"
        }
        $sourceStream = $response.GetResponseStream()
        $targetStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $total = [long]0
        while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if (-not (Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes $ExpectedLength) -or
                -not (Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes $MaximumBytes)) {
                throw "Release asset 超出 manifest 大小：$($Asset.name)"
            }
            $targetStream.Write($buffer, 0, $read)
        }
        $targetStream.Flush()
        if ($total -ne $ExpectedLength) { throw "Release asset 未下载完整：$($Asset.name)" }
    } finally {
        if ($null -ne $targetStream) { $targetStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        $response.Close()
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Asset.digest)) {
        if ([string]$Asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw "GitHub asset digest 格式无效：$($Asset.name)" }
        $apiDigest = $Matches[1].ToLowerInvariant()
        $actualDigest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualDigest -cne $apiDigest) { throw "GitHub asset digest 校验失败：$($Asset.name)" }
    }
}

function Get-ManifestRecordForPath {
    param([Parameter(Mandatory=$true)][object]$ValidatedManifest, [Parameter(Mandatory=$true)][string]$Path)
    $matches = @($ValidatedManifest.Files | Where-Object { [string]$_.path -ceq $Path })
    if ($matches.Count -ne 1) { throw "release manifest 没有唯一记录：$Path" }
    return $matches[0]
}

function Get-ByteArraySha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-StableArchiveEntryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or
        $Path.StartsWith('/') -or $Path.EndsWith('/') -or $Path.Contains('//') -or
        $Path -match '(^|/)\.{1,2}(/|$)' -or $Path -match '[\x00-\x1f\x7f]' -or
        @($Path.Split('/') | Where-Object { $_.EndsWith('.') -or $_.EndsWith(' ') }).Count -gt 0) {
        throw 'ZIP entry path is not a safe relative file path.'
    }
}

function Test-StableExtractedInventory {
    param([string]$Directory)
    Assert-DownloadStagingRoot -Path $Directory
    $expectedFiles = @(Get-ExpectedStableReleaseFiles | ForEach-Object { [string]$_.Path }) + 'manifest.json'
    $expectedDirectories = @(Get-ExpectedReleaseDirectories -Tag 'v0.1.0')
    $actualFiles = @(); $actualDirectories = @()
    foreach ($item in (Get-ChildItem -LiteralPath $Directory -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Extracted stable package contains a reparse point.' }
        $relative = $item.FullName.Substring($Directory.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1).Replace('\','/')
        if ($item.PSIsContainer) { $actualDirectories += $relative } else { $actualFiles += $relative }
    }
    Assert-DownloadStagingRoot -Path $Directory
    if ((@($actualFiles | Sort-Object -CaseSensitive) -join "`n") -cne (@($expectedFiles | Sort-Object -CaseSensitive) -join "`n") -or
        (@($actualDirectories | Sort-Object -CaseSensitive) -join "`n") -cne (@($expectedDirectories | Sort-Object -CaseSensitive) -join "`n")) {
        throw 'Extracted stable package does not match its fixed file and directory inventory.'
    }
    return $true
}

function Test-StablePackageProvenance {
    param([string]$Directory,[object]$ValidatedManifest)
    $manifest = $ValidatedManifest.Manifest
    $buildPath = Join-Path $Directory 'build-provenance.json'
    $build = ConvertFrom-StrictJson -JsonText ([System.IO.File]::ReadAllText($buildPath,[System.Text.Encoding]::UTF8)) -Label 'stable Native build provenance'
    Assert-ExactJsonObject -Value $build -ExpectedNames @('schema_version','source_commit','source_tree_clean','compile_only',
        'build_completed','result','output_directory','started_utc','completed_utc','executable','tests') -Label 'stable Native build provenance'
    if (-not (Test-JsonUnsignedInteger $build.schema_version 1 1) -or
        [string]$build.source_commit -cne [string]$manifest.source.commit -or $build.source_tree_clean -ne $true -or
        $build.compile_only -ne $false -or $build.build_completed -ne $true -or [string]$build.result -cne 'passed') {
        throw 'Stable Native builder provenance is invalid.'
    }
    Assert-ExactJsonObject -Value $build.executable -ExpectedNames @('path','length_bytes','sha256') -Label 'stable Native provenance executable'
    $nativeRecord = Get-ManifestRecordForPath -ValidatedManifest $ValidatedManifest -Path 'runtime/wirex_bridge.exe'
    if ([string]$build.executable.path -cne 'wirex_bridge.exe' -or
        [long]$build.executable.length_bytes -ne [long]$nativeRecord.length_bytes -or
        [string]$build.executable.sha256 -cne [string]$nativeRecord.sha256) { throw 'Stable Native builder provenance does not match runtime/wirex_bridge.exe.' }
    $tests = @($build.tests)
    if ($tests.Count -ne $ValidatedManifest.Manifest.build.passed_test_count) { throw 'Stable Native provenance test count is invalid.' }
    $expected = @(Get-ExpectedReleaseTests -Tag 'v0.1.0')
    for ($i=0; $i -lt $expected.Count; $i++) {
        Assert-ExactJsonObject -Value $tests[$i] -ExpectedNames @('name','result','exit_code') -Label 'stable Native provenance test'
        if ([string]$tests[$i].name -cne $expected[$i] -or [string]$tests[$i].result -cne 'passed' -or
            -not (Test-JsonUnsignedInteger $tests[$i].exit_code 0 0)) { throw 'Stable Native provenance test inventory is invalid.' }
    }

    $launcherPath = Join-Path $Directory 'launcher-build-provenance.json'
    $launcher = ConvertFrom-StrictJson -JsonText ([System.IO.File]::ReadAllText($launcherPath,[System.Text.Encoding]::UTF8)) -Label 'stable launcher build provenance'
    Assert-ExactJsonObject -Value $launcher -ExpectedNames @('schema_version','result','source','compiler','output','build_log') -Label 'stable launcher build provenance'
    Assert-ExactJsonObject -Value $launcher.source -ExpectedNames @('path','commit','sha256') -Label 'stable launcher source provenance'
    Assert-ExactJsonObject -Value $launcher.compiler -ExpectedNames @('family','version','target','command') -Label 'stable launcher compiler provenance'
    Assert-ExactJsonObject -Value $launcher.output -ExpectedNames @('directory','path','length_bytes','sha256') -Label 'stable launcher output provenance'
    Assert-ExactJsonObject -Value $launcher.build_log -ExpectedNames @('path','sha256') -Label 'stable launcher log provenance'
    $launcherRecord = Get-ManifestRecordForPath -ValidatedManifest $ValidatedManifest -Path 'WirexBridge.exe'
    if (-not (Test-JsonUnsignedInteger $launcher.schema_version 1 1) -or [string]$launcher.result -cne 'passed' -or
        [string]$launcher.source.path -cne [string]$manifest.launcher_build.source_path -or
        [string]$launcher.source.commit -cne [string]$manifest.source.commit -or
        [string]$launcher.source.sha256 -cne [string]$manifest.launcher_build.source_sha256 -or
        [string]$launcher.compiler.family -cne [string]$manifest.launcher_build.compiler_family -or
        [string]$launcher.compiler.version -cne [string]$manifest.launcher_build.compiler_version -or
        [string]$launcher.compiler.command -cne 'csc.exe /nologo /target:winexe /platform:x64 /optimize+ /debug- /codepage:65001' -or
        [string]$launcher.compiler.target -cne [string]$manifest.launcher_build.target -or
        [string]$launcher.output.directory -cne [string]$manifest.launcher_build.output_directory -or
        [string]$launcher.output.path -cne 'WirexBridge.exe' -or
        [long]$launcher.output.length_bytes -ne [long]$launcherRecord.length_bytes -or
        [string]$launcher.output.sha256 -cne [string]$launcherRecord.sha256 -or
        [string]$launcher.build_log.path -cne [string]$manifest.launcher_build.build_log_path -or
        [string]$launcher.build_log.sha256 -cne [string]$manifest.launcher_build.build_log_sha256) {
        throw 'Stable launcher provenance does not match its manifest and EXE.'
    }
    $sourcePath = Join-Path $Directory 'SOURCE.txt'
    $sourceText = [System.IO.File]::ReadAllText($sourcePath,[System.Text.Encoding]::UTF8)
    if ($sourceText -match '(?i)[A-Z]:\\|\\\\') { throw 'Stable SOURCE.txt contains a machine-local absolute path.' }
}

function Expand-StablePackageArchive {
    param([string]$ArchivePath,[string]$Destination,[object]$ValidatedManifest,[byte[]]$ManifestBytes)
    Assert-DownloadStagingRoot -Path $Destination
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $expectedRecords = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $ValidatedManifest.Files) { $expectedRecords[[string]$record.path] = $record }
    $manifestHash = Get-ByteArraySha256 -Bytes $ManifestBytes
    $expectedRecords['manifest.json'] = [pscustomobject]@{ path='manifest.json';length_bytes=[long]$ManifestBytes.Length;sha256=$manifestHash }
    $canonicalPathMap = New-WirexStableCanonicalPathMap -Paths (@($ValidatedManifest.Files | ForEach-Object { [string]$_.path }) + 'manifest.json')
    $limits = Get-WirexStableReleaseLimits
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $archiveItem = Get-Item -LiteralPath $ArchivePath -ErrorAction Stop
    if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$archiveItem.Length) -MaximumBytes ([long]$limits.MaximumArchiveBytes))) {
        throw 'Stable ZIP exceeds the fixed 512 MiB download limit.'
    }
    foreach ($relativeDirectory in @(Get-ExpectedReleaseDirectories -Tag 'v0.1.0')) {
        $directoryPath = [System.IO.Path]::GetFullPath((Join-Path $Destination $relativeDirectory.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-PathWithinDirectory -Path $directoryPath -Directory $Destination)) { throw 'Stable package directory inventory escaped its staging root.' }
        [void][System.IO.Directory]::CreateDirectory($directoryPath)
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -ne $expectedRecords.Count) { throw 'ZIP entry count differs from the stable manifest.' }
        $total = [long]0
        foreach ($entry in $archive.Entries) {
            $entryPath = [string]$entry.FullName
            Assert-StableArchiveEntryPath -Path $entryPath
            $canonicalPath = Resolve-WirexStableCanonicalPath -Path $entryPath -CanonicalPathMap $canonicalPathMap
            if (-not $seen.Add($canonicalPath)) {
                throw 'ZIP contains an unexpected path or a case-insensitive duplicate.'
            }
            if (-not (Test-WirexStableRegularZipEntry -ExternalAttributes ([int]$entry.ExternalAttributes) -Length ([long]$entry.Length))) {
                throw 'ZIP contains a non-regular file entry.'
            }
            $record = $expectedRecords[$canonicalPath]
            $expectedLength = [long]$record.length_bytes
            $expectedHash = [string]$record.sha256
            $maximumFileBytes = [long](Get-WirexStableMaximumFileBytes -Path $canonicalPath)
            if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$entry.Length) -MaximumBytes $maximumFileBytes)) {
                throw "ZIP entry exceeds its fixed per-file download limit: $canonicalPath"
            }
            if ([long]$entry.Length -ne $expectedLength) { throw "ZIP entry length differs from manifest: $canonicalPath" }
            $total += [long]$entry.Length
            if (-not (Test-WirexStableLengthWithinLimit -Length $total -MaximumBytes ([long]$limits.MaximumUncompressedBytes))) {
                throw 'ZIP uncompressed data exceeds 2 GiB.'
            }

            $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $Destination $canonicalPath.Replace('/',[System.IO.Path]::DirectorySeparatorChar)))
            if (-not (Test-PathWithinDirectory -Path $destinationPath -Directory $Destination)) { throw 'ZIP entry escaped the exclusive staging directory.' }
            $parent = [System.IO.Path]::GetDirectoryName($destinationPath)
            $relativeParent = $parent.Substring([System.IO.Path]::GetFullPath($Destination).TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            $cursor = [System.IO.Path]::GetFullPath($Destination)
            foreach ($segment in @($relativeParent.Split([System.IO.Path]::DirectorySeparatorChar) | Where-Object { $_ })) {
                $cursor = Join-Path $cursor $segment
                if (-not [System.IO.Directory]::Exists($cursor)) { [System.IO.Directory]::CreateDirectory($cursor) | Out-Null }
                $directoryInfo = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'ZIP extraction encountered a reparse point.' }
            }
            $entryStream = $entry.Open()
            $outputStream = [System.IO.File]::Open($destinationPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $buffer = New-Object byte[] 65536
                $written = [long]0
                while (($read = $entryStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $written += $read
                    if ($written -gt $expectedLength) { throw "ZIP entry exceeded manifest length: $entryPath" }
                    $outputStream.Write($buffer,0,$read)
                    [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
                }
                [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
                if ($written -ne $expectedLength) { throw "ZIP entry is truncated: $entryPath" }
                $actualHash = [System.BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()
                if ($actualHash -cne $expectedHash) { throw "ZIP entry SHA-256 differs from manifest: $entryPath" }
            } finally { $entryStream.Dispose(); $outputStream.Dispose(); $sha.Dispose() }
        }
        if ($seen.Count -ne $expectedRecords.Count) { throw 'ZIP is missing stable package files.' }
    } finally { $archive.Dispose() }
    [void](Test-StableExtractedInventory -Directory $Destination)
    Test-StablePackageProvenance -Directory $Destination -ValidatedManifest $ValidatedManifest
}

function Invoke-StableArchiveDownload {
    param([string]$Staging,[string]$AssetStaging,[string]$Token,[object]$AssetMap,[object]$ValidatedManifest,[byte[]]$ManifestBytes)
    $stagingRoot = [System.IO.Path]::GetFullPath($Staging)
    $assetStagingRoot = [System.IO.Path]::GetFullPath($AssetStaging)
    if ([System.IO.Path]::GetDirectoryName($stagingRoot) -cne [System.IO.Path]::GetDirectoryName($assetStagingRoot) -or
        $stagingRoot -ceq $assetStagingRoot -or
        [System.IO.Path]::GetFileName($assetStagingRoot) -notmatch '^\.wirex-release-assets-[0-9a-f]{32}$') {
        throw 'Stable asset scratch must be a separate, named sibling of the package staging root.'
    }
    Assert-DownloadStagingRoot -Path $stagingRoot
    Assert-DownloadStagingRoot -Path $assetStagingRoot
    $checksumAsset = $AssetMap['SHA256SUMS.txt']
    $archiveAsset = $AssetMap['WIREX_Bridge_v0.1.0.zip']
    $checksumPath = Join-Path $assetStagingRoot ('.checksums-' + ([long]$checksumAsset.id).ToString([Globalization.CultureInfo]::InvariantCulture) + '.part')
    $archivePath = Join-Path $assetStagingRoot ('.archive-' + ([long]$archiveAsset.id).ToString([Globalization.CultureInfo]::InvariantCulture) + '.part')
    Write-ReleaseAssetToFile -Asset $checksumAsset -Token $Token -Path $checksumPath -ExpectedLength ([long]$checksumAsset.size) -MaximumBytes 4096
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try { $checksumText = [System.IO.File]::ReadAllText($checksumPath,$utf8) } catch { throw 'Stable SHA256SUMS.txt is not valid UTF-8.' }
    $checksumLines = @($checksumText -split "\r?\n")
    if ($checksumLines.Count -ne 3 -or $checksumLines[2] -cne '') {
        throw 'Stable SHA256SUMS.txt must list exactly the ZIP and manifest hashes.'
    }
    if ($checksumLines[0] -cnotmatch '^([0-9a-f]{64})  WIREX_Bridge_v0\.1\.0\.zip$') { throw 'Stable ZIP checksum line is invalid.' }
    $expectedArchiveHash = $Matches[1]
    if ($checksumLines[1] -cnotmatch '^([0-9a-f]{64})  manifest\.json$') { throw 'Stable manifest checksum line is invalid.' }
    $expectedManifestHash = $Matches[1]
    $actualManifestHash = Get-ByteArraySha256 -Bytes $ManifestBytes
    if ($expectedManifestHash -cne $actualManifestHash) { throw 'SHA256SUMS.txt manifest hash does not match the downloaded manifest.' }
    Write-ReleaseAssetToFile -Asset $archiveAsset -Token $Token -Path $archivePath -ExpectedLength ([long]$archiveAsset.size) `
        -MaximumBytes ([long]$script:maximumStableArchiveBytes)
    $actualArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualArchiveHash -cne $expectedArchiveHash) { throw 'Stable ZIP SHA-256 does not match SHA256SUMS.txt.' }
    Expand-StablePackageArchive -ArchivePath $archivePath -Destination $stagingRoot -ValidatedManifest $ValidatedManifest `
        -ManifestBytes $ManifestBytes
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop
}

function Invoke-ReleaseDownload {
    param([Parameter(Mandatory=$true)][string]$RequestedTag,
          [Parameter(Mandatory=$true)][string]$OutputDirectory,
          [switch]$AllowDraft)
    if (-not (Test-ReleaseTag -Tag $RequestedTag)) { throw 'Only v0.1.0, v0.1.1-test.2, and v0.1.1 are supported.' }
    $context = Get-DownloadDestinationContext -Destination $OutputDirectory
    $token = Get-GitCredentialToken
    $stagingCreated = $false
    $assetScratch = $null
    $assetScratchCreated = $false
    $primaryError = $null
    try {
        $release = Get-ReleaseForTag -RequestedTag $RequestedTag -Token $token -AllowDraft:$AllowDraft
        if ([string]$release.tag_name -cne $RequestedTag) { throw 'GitHub Release 返回了不同的 tag。' }
        $apiAssets = @($release.assets)
        if (Test-WirexZipOnlyVersion -Version $RequestedTag) {
            $zipProfile = Get-WirexZipOnlyReleaseProfile -Version $RequestedTag
            if ($apiAssets.Count -ne 1 -or [string]$apiAssets[0].name -cne $zipProfile.ArchiveName) {
                throw 'ZIP-only Release 必须包含唯一的版本 ZIP asset。'
            }
            $zipAsset = $apiAssets[0]
            if (-not (Test-JsonUnsignedInteger $zipAsset.id 1 9223372036854775807) -or
                [string]$zipAsset.state -cne 'uploaded' -or
                -not (Test-JsonUnsignedInteger $zipAsset.size 1 ([long]$script:maximumAssetBytes)) -or
                -not (Test-WirexStableLengthWithinLimit -Length ([long]$zipAsset.size) -MaximumBytes ([long]$script:maximumAssetBytes))) {
                throw 'ZIP-only Release asset metadata is invalid.'
            }
            $digestText = [string]$zipAsset.digest
            if ($digestText -cnotmatch '^sha256:([0-9a-f]{64})$') {
                throw 'ZIP-only Release asset is missing a valid GitHub SHA-256 digest.'
            }
            $expectedZipHash = $Matches[1]
            [void](New-DownloadStagingRoot -Path $context.Staging)
            $stagingCreated = $true
            Assert-DownloadStagingRoot -Path $context.Staging
            $assetScratch = Join-Path $context.Parent ('.wirex-release-assets-' + [guid]::NewGuid().ToString('N'))
            if (-not (Test-PathWithinDirectory -Path $assetScratch -Directory $context.Parent) -or
                (Test-Path -LiteralPath $assetScratch)) { throw 'ZIP-only asset scratch path is invalid or occupied.' }
            [void](New-DownloadStagingRoot -Path $assetScratch)
            $assetScratchCreated = $true
            Assert-DownloadStagingRoot -Path $assetScratch
            $zipAssetPath = Join-Path $assetScratch ('.archive-' + ([long]$zipAsset.id).ToString([Globalization.CultureInfo]::InvariantCulture) + '.part')
            Write-ReleaseAssetToFile -Asset $zipAsset -Token $token -Path $zipAssetPath `
                -ExpectedLength ([long]$zipAsset.size) -MaximumBytes ([long]$script:maximumAssetBytes)
            [void](Test-DownloadedFile -Path $zipAssetPath -ExpectedLength ([long]$zipAsset.size) -ExpectedSha256 $expectedZipHash)
            [void](Expand-WirexZipOnlyArchive -ArchivePath $zipAssetPath -Version $RequestedTag -Destination $context.Staging)
            if (Test-Path -LiteralPath $context.Destination) { throw 'Destination appeared during ZIP-only download; no overwrite was attempted.' }
            Assert-DownloadStagingRoot -Path $context.Staging
            [System.IO.Directory]::Move($context.Staging, $context.Destination)
            $stagingCreated = $false
            Write-Host "ZIP-only Release $RequestedTag 已校验并解压到：$($context.Destination)"
            Write-Host '已校验唯一 ZIP asset 的 GitHub SHA-256 摘要和固定文件清单；未运行包内文件。'
            return
        }
        $manifestAssets = @($apiAssets | Where-Object { [string]$_.name -ceq 'manifest.json' })
        if ($manifestAssets.Count -ne 1) { throw 'Release 必须包含唯一的 manifest.json asset。' }
        $manifestAsset = $manifestAssets[0]
        if (-not (Test-JsonUnsignedInteger $manifestAsset.id 1 9223372036854775807) -or
            [string]$manifestAsset.state -cne 'uploaded' -or
            -not (Test-JsonUnsignedInteger $manifestAsset.size 1 ([long]$script:maximumManifestBytes)) -or
            -not (Test-WirexStableLengthWithinLimit -Length ([long]$manifestAsset.size) -MaximumBytes ([long]$script:stableReleaseLimits.MaximumManifestBytes))) {
            throw 'Release manifest asset 元数据无效。'
        }
        $manifestBytes = Read-ReleaseManifestAsset -Asset $manifestAsset -Token $token
        $manifestText = [System.Text.Encoding]::UTF8.GetString($manifestBytes)
        if ($manifestText.Length -gt 0 -and $manifestText[0] -eq [char]0xfeff) { $manifestText = $manifestText.Substring(1) }
        $manifestDocument = ConvertFrom-StrictJson -JsonText $manifestText -Label 'release manifest'
        $validatedManifest = Test-ManifestDocument -Manifest $manifestDocument -RequestedTag $RequestedTag
        [void](Assert-ReleaseTargetCommitish -Release $release -SourceCommit ([string]$manifestDocument.source.commit))
        $assetMap = Resolve-ReleaseAssetInventory -Release $release -ValidatedManifest $validatedManifest -Tag $RequestedTag

        [void](New-DownloadStagingRoot -Path $context.Staging)
        $stagingCreated = $true
        Assert-DownloadStagingRoot -Path $context.Staging
        if ($RequestedTag -ceq 'v0.1.0') {
            $assetScratch = Join-Path $context.Parent ('.wirex-release-assets-' + [guid]::NewGuid().ToString('N'))
            if (-not (Test-PathWithinDirectory -Path $assetScratch -Directory $context.Parent) -or
                (Test-Path -LiteralPath $assetScratch)) { throw 'Stable asset scratch path is invalid or occupied.' }
            [void](New-DownloadStagingRoot -Path $assetScratch)
            $assetScratchCreated = $true
            Assert-DownloadStagingRoot -Path $assetScratch
            Invoke-StableArchiveDownload -Staging $context.Staging -AssetStaging $assetScratch -Token $token -AssetMap $assetMap `
                -ValidatedManifest $validatedManifest -ManifestBytes $manifestBytes
            if (@(Get-ChildItem -LiteralPath $assetScratch -Force -ErrorAction Stop).Count -ne 0) {
                throw 'Stable asset scratch is not empty after download validation.'
            }
            Assert-DownloadStagingRoot -Path $assetScratch
            [System.IO.Directory]::Delete($assetScratch, $false)
            $assetScratchCreated = $false
            if (Test-Path -LiteralPath $context.Destination) { throw 'Destination appeared during stable download; no overwrite was attempted.' }
            Assert-DownloadStagingRoot -Path $context.Staging
            [System.IO.Directory]::Move($context.Staging, $context.Destination)
            $stagingCreated = $false
            Write-Host "Stable release $RequestedTag 已校验并下载到：$($context.Destination)"
            Write-Host ('已校验稳定分发资产 3 个、ZIP 内容 ' + $validatedManifest.Files.Count + ' 个文件；未安装或运行任何文件。')
            return
        }
    } catch {
        $primaryError = $_
        throw
    } finally {
        $cleanupFailure = $null
        if ($stagingCreated -and (Test-Path -LiteralPath $context.Staging)) {
            $safeStagingPath = (Test-PathWithinDirectory -Path $context.Staging -Directory $context.Parent) -and
                [System.IO.Path]::GetFileName($context.Staging).StartsWith('.wirex-release-staging-', [System.StringComparison]::Ordinal)
            if (-not $safeStagingPath -or -not (Test-Path -LiteralPath $context.Staging -PathType Container)) {
                $cleanupFailure = '暂存路径已偏离新建目录边界，未删除该路径。'
            } else {
                try {
                    Assert-DownloadStagingRoot -Path $context.Staging
                    Remove-Item -LiteralPath $context.Staging -Recurse -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath $context.Staging) { throw '暂存目录删除后仍然存在。' }
                } catch { $cleanupFailure = $_.Exception.Message }
            }
        }
        if ($assetScratchCreated -and $null -ne $assetScratch -and (Test-Path -LiteralPath $assetScratch)) {
            $safeAssetScratchPath = (Test-PathWithinDirectory -Path $assetScratch -Directory $context.Parent) -and
                [System.IO.Path]::GetFileName($assetScratch) -match '^\.wirex-release-assets-[0-9a-f]{32}$'
            if (-not $safeAssetScratchPath -or -not (Test-Path -LiteralPath $assetScratch -PathType Container)) {
                if ($null -eq $cleanupFailure) { $cleanupFailure = 'Asset scratch path escaped its verified sibling directory.' }
            } else {
                try {
                    Assert-DownloadStagingRoot -Path $assetScratch
                    foreach ($scratchItem in @(Get-ChildItem -LiteralPath $assetScratch -Force -ErrorAction Stop)) {
                        if ($scratchItem.PSIsContainer -or
                            (($scratchItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
                            $scratchItem.Name -notmatch '^\.(checksums|archive)-[0-9]+\.part$') {
                            throw 'Asset scratch contains an unexpected entry; it was left in place.'
                        }
                        [System.IO.File]::Delete($scratchItem.FullName)
                    }
                    [System.IO.Directory]::Delete($assetScratch, $false)
                    if (Test-Path -LiteralPath $assetScratch) { throw 'Asset scratch remains after cleanup.' }
                } catch {
                    if ($null -eq $cleanupFailure) { $cleanupFailure = $_.Exception.Message }
                    else { $cleanupFailure += ' ' + $_.Exception.Message }
                }
            }
        }
        $token = $null
        $manifestBytes = $null
        $manifestText = $null
        $sourceText = $null
        if ($null -ne $cleanupFailure) {
            $cleanupPath = if ($null -ne $assetScratch -and (Test-Path -LiteralPath $assetScratch)) { $assetScratch } else { $context.Staging }
            $cleanupMessage = "下载暂存目录清理失败，残留路径：$cleanupPath。清理错误：$cleanupFailure"
            if ($null -eq $primaryError) { throw $cleanupMessage }
            [Console]::Error.WriteLine($cleanupMessage)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-ReleaseDownload -RequestedTag $Tag -OutputDirectory $Destination -AllowDraft:$AllowDraft }
    catch {
        Write-Host "下载失败：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
