[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$')]
    [string]$Tag,
    [Parameter(Mandatory=$true)]
    [string]$Destination,
    [switch]$AllowDraft
)

$ErrorActionPreference = 'Stop'
$script:githubOwner = 'iCassius'
$script:githubRepository = 'WIREX_Bridge'
$script:githubApiRoot = 'https://api.github.com/repos/iCassius/WIREX_Bridge'
$script:approvedYFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:maximumManifestBytes = 2MB
$script:maximumAssetBytes = 128MB
$script:maximumPackageBytes = 256MB
$script:maximumDownloaderAssetBytes = 512KB
$script:releaseDownloaderAssetName = 'download-release.ps1'
$script:releaseAssetRedirectHosts = @(
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com'
)

function Test-ReleaseTag {
    param([Parameter(Mandatory=$true)][string]$Tag)
    return ($Tag -ceq 'v0.1.0-alpha.1' -or $Tag -ceq 'v0.1.0-alpha.2' -or
        $Tag -ceq 'v0.1.0-alpha.3' -or $Tag -ceq 'v0.1.0-alpha.4' -or
        $Tag -ceq 'v0.1.0-alpha.5' -or $Tag -ceq 'v0.1.0-alpha.6' -or
        $Tag -ceq 'v0.1.0-alpha.7' -or $Tag -ceq 'v0.1.0-alpha.8')
}

function Get-ExpectedReleaseTests {
    param([Parameter(Mandatory=$true)][string]$Tag)
    $alpha1 = @(
        'dmrd_test','direct_frame_test','hri_t_payload_test','direct_stream_test','hri_session_test','hri_ptt_gate_test',
        'hri_downlink_session_test','hri_radio_protocol_test','operation_audio_cleanup_test','audio_input_cleanup_test',
        'wave_output_open_test','session_timing_test','wave_file_test','pcm_gain_test','bounded_pipe_writer_test',
        'console_lifecycle_test','session_report_test','dmr_call_test','bm_session_test','bm_udp_test','dmr_vocoder_test',
        'pcm_resampler_test','bm_voice_pipeline_test','bm_test_profile_test','bm_connection_config_test',
        'hri_stream_session_test','bm_bridge_loopback_test'
    )
    switch -CaseSensitive ($Tag) {
        'v0.1.0-alpha.1' { return $alpha1 }
        'v0.1.0-alpha.2' {
            return @($alpha1[0..14] + 'ui_pipe_test' + $alpha1[15..($alpha1.Count - 1)])
        }
        'v0.1.0-alpha.3' {
            return @(
                'dmrd_test', 'direct_frame_test', 'hri_t_payload_test', 'hri_call_header_test', 'hri_t_record_test',
                'hri_lcd_identity_candidate_test', 'direct_stream_test', 'hri_session_test', 'hri_ptt_gate_test',
                'hri_p_status_test', 'hri_downlink_session_test', 'hri_radio_protocol_test',
                'operation_audio_cleanup_test', 'audio_input_cleanup_test', 'wave_output_open_test', 'session_timing_test',
                'wave_file_test', 'pcm_gain_test', 'bounded_pipe_writer_test', 'ui_pipe_test', 'console_lifecycle_test',
                'session_report_test', 'dmr_call_test', 'bm_session_test', 'bm_udp_test', 'dmr_vocoder_test',
                'ambe_dmr72_test', 'ysf_vd2_vch_test', 'voice_transcode_buffer_test', 'pcm_resampler_test',
                'bm_voice_pipeline_test', 'bm_test_profile_test', 'bm_connection_config_test', 'hri_stream_session_test',
                'bm_bridge_loopback_test'
            )
        }
        'v0.1.0-alpha.4' { return @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.3') }
        'v0.1.0-alpha.5' { return @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.4') + 'ui_control_protocol_v2_test') }
        'v0.1.0-alpha.6' { return @((Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.5') + 'talkgroup_routing_test' + 'bm_routing_lifecycle_test' + 'routing_state_test') }
        'v0.1.0-alpha.7' { return @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.6') }
        'v0.1.0-alpha.8' { return @(Get-ExpectedReleaseTests -Tag 'v0.1.0-alpha.7') }
        default { throw 'Only v0.1.0-alpha.1, v0.1.0-alpha.2, v0.1.0-alpha.3, v0.1.0-alpha.4, v0.1.0-alpha.5, v0.1.0-alpha.6, v0.1.0-alpha.7, and v0.1.0-alpha.8 are supported.' }
    }
}

function Get-ExpectedReleaseFiles {
    param([string]$Tag = 'v0.1.0-alpha.1')
    $alpha1 = @(
        [pscustomobject]@{ Path='wirex_bridge.exe'; AssetName='wirex_bridge.exe'; MaximumBytes=134217728L },
        [pscustomobject]@{ Path='build-provenance.json'; AssetName='build-provenance.json'; MaximumBytes=2097152L },
        [pscustomobject]@{ Path='start-bm-radio-bridge.cmd'; AssetName='start-bm-radio-bridge.cmd'; MaximumBytes=524288L },
        [pscustomobject]@{ Path='start-bm-radio-bridge.ps1'; AssetName='start-bm-radio-bridge.ps1'; MaximumBytes=524288L },
        [pscustomobject]@{ Path='start-listen-91.cmd'; AssetName='start-listen-91.cmd'; MaximumBytes=524288L },
        [pscustomobject]@{ Path='start-profile.cmd'; AssetName='start-profile.cmd'; MaximumBytes=524288L },
        [pscustomobject]@{ Path='README.md'; AssetName='README.md'; MaximumBytes=4194304L },
        [pscustomobject]@{ Path='SOURCE.txt'; AssetName='SOURCE.txt'; MaximumBytes=1048576L },
        [pscustomobject]@{ Path='docs/连接配置.md'; AssetName='docs__connection-profile.md'; MaximumBytes=4194304L },
        [pscustomobject]@{ Path='docs/音量调节.md'; AssetName='docs__audio-gain.md'; MaximumBytes=4194304L },
        [pscustomobject]@{ Path='licenses/dmr_signal/COPYING.GPL-3.0.txt'; AssetName='licenses__dmr-signal__COPYING.GPL-3.0.txt'; MaximumBytes=4194304L },
        [pscustomobject]@{ Path='licenses/dmr_signal/NOTICE.md'; AssetName='licenses__dmr-signal__NOTICE.md'; MaximumBytes=1048576L },
        [pscustomobject]@{ Path='licenses/droidstar_mbe/COPYING.GPL-3.0.txt'; AssetName='licenses__droidstar-mbe__COPYING.GPL-3.0.txt'; MaximumBytes=4194304L },
        [pscustomobject]@{ Path='licenses/droidstar_mbe/ISC-NOTICE.txt'; AssetName='licenses__droidstar-mbe__ISC-NOTICE.txt'; MaximumBytes=1048576L },
        [pscustomobject]@{ Path='licenses/droidstar_mbe/source-manifest.json'; AssetName='licenses__droidstar-mbe__source-manifest.json'; MaximumBytes=4194304L },
        [pscustomobject]@{ Path='private/device-y.bin'; AssetName='private__device-y.bin'; MaximumBytes=100L }
    )
    switch -CaseSensitive ($Tag) {
        'v0.1.0-alpha.1' { return $alpha1 }
        'v0.1.0-alpha.2' {
            $alpha2 = @($alpha1)
            $alpha2 += [pscustomobject]@{ Path='start-user-config.cmd'; AssetName='start-user-config.cmd'; MaximumBytes=524288L }
            $alpha2 += [pscustomobject]@{ Path='start-user-config.ps1'; AssetName='start-user-config.ps1'; MaximumBytes=524288L }
            $alpha2 += [pscustomobject]@{ Path='bridge-user-config.psm1'; AssetName='bridge-user-config.psm1'; MaximumBytes=1048576L }
            $alpha2 += [pscustomobject]@{ Path='start-ui.cmd'; AssetName='start-ui.cmd'; MaximumBytes=524288L }
            $alpha2 += [pscustomobject]@{ Path='start-ui.ps1'; AssetName='start-ui.ps1'; MaximumBytes=1048576L }
            $alpha2 += [pscustomobject]@{ Path='docs/配置与桌面操作.md'; AssetName='docs__desktop-user-config.md'; MaximumBytes=4194304L }
            $alpha2 += [pscustomobject]@{ Path='ui/windows/bridge-ui.ps1'; AssetName='ui__windows__bridge-ui.ps1'; MaximumBytes=2097152L }
            $alpha2 += [pscustomobject]@{ Path='ui/windows/BridgeSupervisor.cs'; AssetName='ui__windows__BridgeSupervisor.cs'; MaximumBytes=2097152L }
            $alpha2 += [pscustomobject]@{ Path='ui/windows/MainWindow.xaml'; AssetName='ui__windows__MainWindow.xaml'; MaximumBytes=4194304L }
            $alpha2 += [pscustomobject]@{ Path='ui/windows/SettingsWindow.xaml'; AssetName='ui__windows__SettingsWindow.xaml'; MaximumBytes=4194304L }
            return $alpha2
        }
        'v0.1.0-alpha.3' {
            $alpha3 = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.2')
            $alpha3 += [pscustomobject]@{
                Path='docs/BM来话身份显示.md'
                AssetName='docs__bm-call-identity.md'
                MaximumBytes=4194304L
            }
            return $alpha3
        }
        'v0.1.0-alpha.4' { return @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.3') }
        'v0.1.0-alpha.5' {
            $alpha5 = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.4')
            $alpha5 += [pscustomobject]@{
                Path='docs/R106_IPC第二版.md'
                AssetName='docs__r106-ipc-v2.md'
                MaximumBytes=4194304L
            }
            $alpha5 += [pscustomobject]@{
                Path='docs/R106_配置迁移与测试.md'
                AssetName='docs__r106-profile-migration-test.md'
                MaximumBytes=4194304L
            }
            $alpha5 += [pscustomobject]@{ Path='start-step1-test.cmd'; AssetName='start-step1-test.cmd'; MaximumBytes=524288L }
            $alpha5 += [pscustomobject]@{ Path='start-step1-test.ps1'; AssetName='start-step1-test.ps1'; MaximumBytes=1048576L }
            $alpha5 += [pscustomobject]@{ Path='test-control.cmd'; AssetName='test-control.cmd'; MaximumBytes=524288L }
            $alpha5 += [pscustomobject]@{ Path='test-control.ps1'; AssetName='test-control.ps1'; MaximumBytes=1048576L }
            return $alpha5
        }
        'v0.1.0-alpha.6' {
            $alpha6 = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.5')
            $alpha6 += [pscustomobject]@{
                Path='docs/R108_收发路由状态与alpha6验收.md'
                AssetName='docs__r108-routing-state-alpha6.md'
                MaximumBytes=4194304L
            }
            $alpha6 += [pscustomobject]@{ Path='start-merged-test.cmd'; AssetName='start-merged-test.cmd'; MaximumBytes=524288L }
            $alpha6 += [pscustomobject]@{ Path='start-merged-test.ps1'; AssetName='start-merged-test.ps1'; MaximumBytes=1048576L }
            return $alpha6
        }
        'v0.1.0-alpha.7' {
            $alpha7 = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.6')
            $alpha7 += [pscustomobject]@{
                Path='docs/R109_下行状态与动态组修复.md'
                AssetName='docs__r109-downlink-dynamic-groups.md'
                MaximumBytes=4194304L
            }
            $alpha7 += [pscustomobject]@{
                Path='docs/R109_动态组激活实现.md'
                AssetName='docs__r109-dynamic-group-activation.md'
                MaximumBytes=4194304L
            }
            return $alpha7
        }
        'v0.1.0-alpha.8' {
            $excludedPaths = @(
                'start-bm-radio-bridge.cmd', 'start-listen-91.cmd', 'start-profile.cmd',
                'start-ui.cmd', 'start-user-config.cmd', 'start-user-config.ps1',
                'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1',
                'start-merged-test.cmd', 'start-merged-test.ps1'
            )
            $alpha8 = @(Get-ExpectedReleaseFiles -Tag 'v0.1.0-alpha.7' | Where-Object {
                $excludedPaths -cnotcontains [string]$_.Path
            })
            $alpha8 += [pscustomobject]@{ Path='start-wirex-bridge.cmd'; AssetName='start-wirex-bridge.cmd'; MaximumBytes=524288L }
            $alpha8 += [pscustomobject]@{ Path='tools/start-wirex-bridge.ps1'; AssetName='tools__start-wirex-bridge.ps1'; MaximumBytes=1048576L }
            return $alpha8
        }
        default { throw 'Only v0.1.0-alpha.1, v0.1.0-alpha.2, v0.1.0-alpha.3, v0.1.0-alpha.4, v0.1.0-alpha.5, v0.1.0-alpha.6, v0.1.0-alpha.7, and v0.1.0-alpha.8 are supported.' }
    }
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

function Test-ManifestDocument {
    param([Parameter(Mandatory=$true)][object]$Manifest, [Parameter(Mandatory=$true)][string]$RequestedTag)
    Assert-ExactJsonObject -Value $Manifest -ExpectedNames @(
        'schema_version', 'package_kind', 'package_status', 'version', 'tag_candidate',
        'tag_created', 'github_release_published', 'source', 'build', 'release_scope',
        'not_included', 'hardware_validation', 'approved_y_fixture', 'excluded_private_files',
        'runtime_directories', 'manifest_asset_name', 'files') -Label 'release manifest'
    if (-not (Test-JsonUnsignedInteger $Manifest.schema_version 1 1) -or
        [string]$Manifest.package_kind -cne 'wirex_bridge_private_alpha_release_green_directory' -or
        [string]$Manifest.package_status -cne 'root_audit_passed') {
        throw 'release manifest 版本、包类型或审计状态无效。'
    }
    if (-not (Test-ReleaseTag -Tag $RequestedTag) -or
        [string]$Manifest.version -cne $RequestedTag -or [string]$Manifest.tag_candidate -cne $RequestedTag) {
        throw 'Release tag 与 manifest 版本不一致。'
    }
    if ($Manifest.tag_created -isnot [bool] -or $Manifest.github_release_published -isnot [bool]) {
        throw 'manifest tag/release 状态字段必须为布尔值。'
    }
    if ([string]$Manifest.manifest_asset_name -cne 'manifest.json') { throw 'manifest_asset_name 必须为 manifest.json。' }

    Assert-ExactJsonObject -Value $Manifest.source -ExpectedNames @('repository', 'commit', 'working_tree_clean') -Label 'manifest.source'
    if ([string]$Manifest.source.repository -cne 'https://github.com/iCassius/WIREX_Bridge.git' -or
        [string]$Manifest.source.commit -cnotmatch '^[0-9a-f]{40}$' -or $Manifest.source.working_tree_clean -ne $true) {
        throw 'manifest 源码仓库或 clean source commit 信息无效。'
    }

    Assert-ExactJsonObject -Value $Manifest.build -ExpectedNames @(
        'source_commit', 'source_tree_clean', 'compile_only', 'build_completed', 'output_directory',
        'evidence_log', 'evidence_log_sha256', 'provenance_asset', 'provenance_sha256', 'result',
        'passed_test_count', 'passed_tests', 'compiler_warnings', 'compiler_errors', 'executable_sha256') -Label 'manifest.build'
    if ([string]$Manifest.build.source_commit -cne [string]$Manifest.source.commit -or
        $Manifest.build.source_tree_clean -ne $true -or $Manifest.build.compile_only -ne $false -or
        $Manifest.build.build_completed -ne $true -or [string]$Manifest.build.result -cne 'passed' -or
        -not (Test-JsonUnsignedInteger $Manifest.build.compiler_warnings 0 0) -or
        -not (Test-JsonUnsignedInteger $Manifest.build.compiler_errors 0 0)) {
        throw 'manifest 未证明 clean source 的完整成功构建。'
    }
    [void](Assert-RelativeMetadataPath -Path ([string]$Manifest.build.output_directory) -Label 'build.output_directory')
    [void](Assert-RelativeMetadataPath -Path ([string]$Manifest.build.evidence_log) -Label 'build.evidence_log')
    if ([string]$Manifest.build.provenance_asset -cne 'build-provenance.json' -or
        -not (Test-Sha256Text $Manifest.build.provenance_sha256) -or
        -not (Test-Sha256Text $Manifest.build.evidence_log_sha256) -or
        -not (Test-Sha256Text $Manifest.build.executable_sha256)) {
        throw 'manifest 构建 provenance 或 hash 字段无效。'
    }
    if (-not (Test-JsonUnsignedInteger $Manifest.build.passed_test_count 1 1000)) { throw 'manifest 测试数量无效。' }
    $manifestTestNames = @($Manifest.build.passed_tests)
    $expectedTestNames = @(Get-ExpectedReleaseTests -Tag $RequestedTag)
    if ($manifestTestNames.Count -ne [int]$Manifest.build.passed_test_count -or
        $manifestTestNames.Count -ne $expectedTestNames.Count) { throw 'manifest 测试数量与该版本固定测试清单不一致。' }
    $testNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    for ($testIndex = 0; $testIndex -lt $manifestTestNames.Count; $testIndex++) {
        $testName = $manifestTestNames[$testIndex]
        if ($testName -isnot [string] -or $testName -cnotmatch '^[A-Za-z0-9_]+$' -or -not $testNameSet.Add([string]$testName)) {
            throw 'manifest 测试清单含无效或重复名称。'
        }
        if ([string]$testName -cne $expectedTestNames[$testIndex]) { throw 'manifest 测试名称或顺序与该版本固定测试清单不一致。' }
    }

    Assert-ExactJsonObject -Value $Manifest.approved_y_fixture -ExpectedNames @('path', 'length_bytes', 'sha256') -Label 'manifest.approved_y_fixture'
    if ([string]$Manifest.approved_y_fixture.path -cne 'private/device-y.bin' -or
        -not (Test-JsonUnsignedInteger $Manifest.approved_y_fixture.length_bytes 100 100) -or
        [string]$Manifest.approved_y_fixture.sha256 -cne $script:approvedYFixtureSha256) {
        throw 'manifest 中的 Y 素材不符合获批文件。'
    }
    if ([string]$Manifest.release_scope -notmatch 'DIRECT' -or
        @($Manifest.not_included).Count -lt 1 -or @($Manifest.runtime_directories).Count -lt 1) {
        throw 'manifest 缺少 release 范围或运行目录说明。'
    }
    $excluded = @($Manifest.excluded_private_files | ForEach-Object { [string]$_ })
    foreach ($required in @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')) {
        if ($excluded -cnotcontains $required) { throw 'manifest 未明确排除私有配置文件。' }
    }

    $records = @($Manifest.files)
    $expectedFiles = @(Get-ExpectedReleaseFiles -Tag $RequestedTag)
    if ($records.Count -ne $expectedFiles.Count) { throw 'manifest 文件数量与发布清单不一致。' }
    $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $assetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $totalBytes = [long]0
    foreach ($record in $records) {
        Assert-ExactJsonObject -Value $record -ExpectedNames @('path', 'asset_name', 'length_bytes', 'sha256', 'source') -Label 'manifest.files[]'
        $relativePath = [string]$record.path
        [void](Assert-RelativeMetadataPath -Path $relativePath -Label 'manifest.files[].path')
        $expected = @($expectedFiles | Where-Object { $_.Path -ceq $relativePath })
        if ($expected.Count -ne 1) { throw "manifest 包含不允许的文件路径：$relativePath" }
        if (-not $pathSet.Add($relativePath)) { throw "manifest 文件路径重复：$relativePath" }
        $assetName = [string]$record.asset_name
        if ($assetName -cnotmatch '^[A-Za-z0-9._-]+$' -or $assetName -cne [string]$expected[0].AssetName -or
            -not $assetSet.Add($assetName)) { throw "manifest asset_name 无效或重复：$relativePath" }
        if (-not (Test-JsonUnsignedInteger $record.length_bytes 1 ([long]$expected[0].MaximumBytes)) -or
            -not (Test-Sha256Text $record.sha256) -or $record.source -isnot [string] -or
            [string]$record.source -match '(?i)[A-Z]:\\|\\\\') {
            throw "manifest 文件长度、SHA-256 或来源字段无效：$relativePath"
        }
        $totalBytes += [long]$record.length_bytes
        if ($totalBytes -gt $script:maximumPackageBytes) { throw 'release package 超过下载总大小上限。' }
        if ($relativePath -ceq 'private/device-y.bin' -and
            ([long]$record.length_bytes -ne 100 -or [string]$record.sha256 -cne $script:approvedYFixtureSha256)) {
            throw 'manifest 文件记录中的 Y 素材与获批文件不一致。'
        }
    }
    foreach ($expected in $expectedFiles) {
        if (-not $pathSet.Contains([string]$expected.Path)) { throw "manifest 缺少发布文件：$($expected.Path)" }
    }
    $provenanceRecord = @($records | Where-Object { [string]$_.path -ceq 'build-provenance.json' })
    $exeRecord = @($records | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })
    if ($provenanceRecord.Count -ne 1 -or $exeRecord.Count -ne 1 -or
        [string]$provenanceRecord[0].sha256 -cne [string]$Manifest.build.provenance_sha256 -or
        [string]$exeRecord[0].sha256 -cne [string]$Manifest.build.executable_sha256) {
        throw 'manifest 的 EXE 或 builder provenance hash 不一致。'
    }
    return [pscustomobject]@{ Manifest=$Manifest; Files=$records; TotalBytes=$totalBytes }
}

function Test-BuildProvenanceDocument {
    param(
        [Parameter(Mandatory=$true)][object]$Provenance,
        [Parameter(Mandatory=$true)][object]$ValidatedManifest
    )
    Assert-ExactJsonObject -Value $Provenance -ExpectedNames @(
        'schema_version', 'source_commit', 'source_tree_clean', 'compile_only', 'build_completed',
        'result', 'output_directory', 'started_utc', 'completed_utc', 'executable', 'tests') -Label 'build provenance'
    $manifest = $ValidatedManifest.Manifest
    if (-not (Test-JsonUnsignedInteger $Provenance.schema_version 1 1) -or
        [string]$Provenance.source_commit -cne [string]$manifest.source.commit -or
        $Provenance.source_tree_clean -ne $true -or $Provenance.compile_only -ne $false -or
        $Provenance.build_completed -ne $true -or [string]$Provenance.result -cne 'passed') {
        throw 'builder provenance 未证明同一 clean source commit 的完整成功构建。'
    }
    [void](Assert-RelativeMetadataPath -Path ([string]$Provenance.output_directory) -Label 'provenance.output_directory')
    Assert-ExactJsonObject -Value $Provenance.executable -ExpectedNames @('path', 'length_bytes', 'sha256') -Label 'provenance.executable'
    $exeRecord = @($ValidatedManifest.Files | Where-Object { [string]$_.path -ceq 'wirex_bridge.exe' })[0]
    if ([string]$Provenance.executable.path -cne 'wirex_bridge.exe' -or
        [long]$Provenance.executable.length_bytes -ne [long]$exeRecord.length_bytes -or
        [string]$Provenance.executable.sha256 -cne [string]$exeRecord.sha256) {
        throw 'builder provenance 中的 EXE 与发布清单不一致。'
    }
    $provenanceTests = @($Provenance.tests)
    $manifestTests = @($manifest.build.passed_tests)
    $expectedTestNames = @(Get-ExpectedReleaseTests -Tag ([string]$manifest.version))
    if ($provenanceTests.Count -ne $expectedTestNames.Count -or
        $provenanceTests.Count -ne [int]$manifest.build.passed_test_count -or
        $provenanceTests.Count -ne $manifestTests.Count) { throw 'builder provenance 测试清单数量不一致。' }
    for ($index = 0; $index -lt $provenanceTests.Count; $index++) {
        Assert-ExactJsonObject -Value $provenanceTests[$index] -ExpectedNames @('name', 'result', 'exit_code') -Label 'provenance.tests[]'
        if ([string]$provenanceTests[$index].name -cne [string]$manifestTests[$index] -or
            [string]$provenanceTests[$index].name -cne [string]$expectedTestNames[$index] -or
            [string]$provenanceTests[$index].result -cne 'passed' -or
            -not (Test-JsonUnsignedInteger $provenanceTests[$index].exit_code 0 0)) {
            throw 'builder provenance 含未通过、重复或与 manifest 不一致的测试。'
        }
    }
    return $true
}

function Select-ReleaseCandidate {
    param([object[]]$Releases, [Parameter(Mandatory=$true)][string]$RequestedTag, [switch]$AllowDraft)
    if (-not (Test-ReleaseTag -Tag $RequestedTag)) { throw 'Only v0.1.0-alpha.1, v0.1.0-alpha.2, v0.1.0-alpha.3, v0.1.0-alpha.4, v0.1.0-alpha.5, v0.1.0-alpha.6, v0.1.0-alpha.7, and v0.1.0-alpha.8 are supported.' }
    $matches = @($Releases | Where-Object { [string]$_.tag_name -ceq $RequestedTag })
    if ($matches.Count -ne 1) { throw 'GitHub Release 列表中没有唯一匹配的 tag。' }
    $release = $matches[0]
    if ($AllowDraft) {
        if ($release.draft -ne $true -or $release.prerelease -ne $true) {
            throw '-AllowDraft 只接受唯一匹配的 draft prerelease。'
        }
    } elseif ($release.draft -ne $false -or $release.prerelease -ne $true) {
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
    param([Parameter(Mandatory=$true)][object]$Release, [Parameter(Mandatory=$true)][object]$ValidatedManifest)
    $expectedNames = @('manifest.json', $script:releaseDownloaderAssetName) + @($ValidatedManifest.Files | ForEach-Object { [string]$_.asset_name })
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $expectedNames) {
        if ($name -cnotmatch '^[A-Za-z0-9._-]+$' -or -not $expectedSet.Add($name)) {
            throw 'manifest 含重复或非法 asset_name。'
        }
    }
    $apiAssets = @($Release.assets)
    if ($apiAssets.Count -ne $expectedNames.Count) { throw 'GitHub Release asset 数量与 manifest 不一致。' }
    $assetMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    $idSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($asset in $apiAssets) {
        $name = [string]$asset.name
        if ($name -cnotmatch '^[A-Za-z0-9._-]+$' -or -not $expectedSet.Contains($name) -or $assetMap.ContainsKey($name)) {
            throw 'GitHub Release 含重复或未列入 manifest 的 asset。'
        }
        if (-not (Test-JsonUnsignedInteger $asset.id 1 9223372036854775807) -or
            -not $idSet.Add(([long]$asset.id).ToString([Globalization.CultureInfo]::InvariantCulture)) -or
            [string]$asset.state -cne 'uploaded' -or
            -not (Test-JsonUnsignedInteger $asset.size 0 ([long]$script:maximumAssetBytes))) {
            throw "GitHub Release asset 元数据无效：$name"
        }
        if ($name -ceq $script:releaseDownloaderAssetName -and
            -not (Test-JsonUnsignedInteger $asset.size 1 ([long]$script:maximumDownloaderAssetBytes))) {
            throw '固定下载器 Release asset 长度超出允许范围。'
        }
        $assetMap[$name] = $asset
    }
    foreach ($record in $ValidatedManifest.Files) {
        $name = [string]$record.asset_name
        if (-not $assetMap.ContainsKey($name) -or [long]$assetMap[$name].size -ne [long]$record.length_bytes) {
            throw "GitHub Release asset 缺失或长度不匹配：$name"
        }
    }
    if (-not $assetMap.ContainsKey('manifest.json') -or
        [long]$assetMap['manifest.json'].size -lt 1 -or
        [long]$assetMap['manifest.json'].size -gt [long]$script:maximumManifestBytes) {
        throw 'GitHub Release 缺少有效的 manifest.json asset。'
    }
    if (-not $assetMap.ContainsKey($script:releaseDownloaderAssetName)) {
        throw 'GitHub Release 缺少固定的 download-release.ps1 asset。'
    }
    return $assetMap
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
            if (-not (Test-ReleaseTag -Tag $Tag)) { throw 'Only v0.1.0-alpha.1, v0.1.0-alpha.2, v0.1.0-alpha.3, v0.1.0-alpha.4, v0.1.0-alpha.5, v0.1.0-alpha.6, v0.1.0-alpha.7, and v0.1.0-alpha.8 are supported.' }
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
    if ($Response.ContentLength -gt $MaximumBytes) { throw 'GitHub 响应超过允许的大小上限。' }
    $stream = $Response.GetResponseStream()
    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 65536
    $total = [long]0
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaximumBytes) { throw 'GitHub 响应超过允许的大小上限。' }
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
    if ([long]$Asset.size -ne $ExpectedLength -or $ExpectedLength -gt $MaximumBytes) {
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
            if ($total -gt $ExpectedLength -or $total -gt $MaximumBytes) { throw "Release asset 超出 manifest 大小：$($Asset.name)" }
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

function Invoke-ReleaseDownload {
    param([Parameter(Mandatory=$true)][string]$RequestedTag,
          [Parameter(Mandatory=$true)][string]$OutputDirectory,
          [switch]$AllowDraft)
    if (-not (Test-ReleaseTag -Tag $RequestedTag)) { throw 'Only v0.1.0-alpha.1, v0.1.0-alpha.2, v0.1.0-alpha.3, v0.1.0-alpha.4, v0.1.0-alpha.5, v0.1.0-alpha.6, v0.1.0-alpha.7, and v0.1.0-alpha.8 are supported.' }
    $context = Get-DownloadDestinationContext -Destination $OutputDirectory
    $token = Get-GitCredentialToken
    $stagingCreated = $false
    $primaryError = $null
    try {
        $release = Get-ReleaseForTag -RequestedTag $RequestedTag -Token $token -AllowDraft:$AllowDraft
        if ([string]$release.tag_name -cne $RequestedTag) { throw 'GitHub Release 返回了不同的 tag。' }
        $apiAssets = @($release.assets)
        $manifestAssets = @($apiAssets | Where-Object { [string]$_.name -ceq 'manifest.json' })
        if ($manifestAssets.Count -ne 1) { throw 'Release 必须包含唯一的 manifest.json asset。' }
        $manifestAsset = $manifestAssets[0]
        if (-not (Test-JsonUnsignedInteger $manifestAsset.id 1 9223372036854775807) -or
            [string]$manifestAsset.state -cne 'uploaded' -or
            -not (Test-JsonUnsignedInteger $manifestAsset.size 1 ([long]$script:maximumManifestBytes))) {
            throw 'Release manifest asset 元数据无效。'
        }
        $manifestBytes = Read-ReleaseManifestAsset -Asset $manifestAsset -Token $token
        $manifestText = [System.Text.Encoding]::UTF8.GetString($manifestBytes)
        if ($manifestText.Length -gt 0 -and $manifestText[0] -eq [char]0xfeff) { $manifestText = $manifestText.Substring(1) }
        $manifestDocument = ConvertFrom-StrictJson -JsonText $manifestText -Label 'release manifest'
        $validatedManifest = Test-ManifestDocument -Manifest $manifestDocument -RequestedTag $RequestedTag
        [void](Assert-ReleaseTargetCommitish -Release $release -SourceCommit ([string]$manifestDocument.source.commit))
        $assetMap = Resolve-ReleaseAssetInventory -Release $release -ValidatedManifest $validatedManifest

        [System.IO.Directory]::CreateDirectory($context.Staging) | Out-Null
        $stagingCreated = $true
        $manifestPath = Join-Path $context.Staging 'manifest.json'
        [System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
        foreach ($record in $validatedManifest.Files) {
            $relativePath = [string]$record.path
            $pathParts = $relativePath.Split('/')
            $destinationPath = $context.Staging
            for ($index = 0; $index -lt $pathParts.Length; $index++) {
                $destinationPath = Join-Path $destinationPath $pathParts[$index]
                if ($index -lt ($pathParts.Length - 1) -and -not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
                    New-Item -ItemType Directory -Path $destinationPath -ErrorAction Stop | Out-Null
                }
            }
            if (-not (Test-PathWithinDirectory -Path $destinationPath -Directory $context.Staging)) {
                throw '发布文件路径越出安全暂存目录。'
            }
            $asset = $assetMap[[string]$record.asset_name]
            $temporaryFile = Join-Path $context.Staging ('.asset-' + ([long]$asset.id).ToString([Globalization.CultureInfo]::InvariantCulture) + '.part')
            $expectedFile = @(Get-ExpectedReleaseFiles -Tag $RequestedTag | Where-Object { $_.Path -ceq $relativePath })
            if ($expectedFile.Count -ne 1) { throw "发布文件路径不在固定清单中：$relativePath" }
            Write-ReleaseAssetToFile -Asset $asset -Token $token -Path $temporaryFile `
                -ExpectedLength ([long]$record.length_bytes) -MaximumBytes ([long]$expectedFile[0].MaximumBytes)
            [void](Test-DownloadedFile -Path $temporaryFile -ExpectedLength ([long]$record.length_bytes) -ExpectedSha256 ([string]$record.sha256))
            [System.IO.File]::Move($temporaryFile, $destinationPath)
        }
        $provenancePath = Join-Path $context.Staging 'build-provenance.json'
        $provenanceText = [System.IO.File]::ReadAllText($provenancePath, [System.Text.Encoding]::UTF8)
        $provenance = ConvertFrom-StrictJson -JsonText $provenanceText -Label 'build provenance'
        [void](Test-BuildProvenanceDocument -Provenance $provenance -ValidatedManifest $validatedManifest)
        $sourceText = [System.IO.File]::ReadAllText((Join-Path $context.Staging 'SOURCE.txt'), [System.Text.Encoding]::UTF8)
        if ($sourceText -match '(?i)[A-Z]:\\|\\\\') { throw 'SOURCE.txt 含本机绝对路径。' }
        $logsDirectory = Join-Path $context.Staging 'logs'
        New-Item -ItemType Directory -Path $logsDirectory -ErrorAction Stop | Out-Null
        if ((Get-ChildItem -LiteralPath $logsDirectory -Force).Count -ne 0) { throw 'logs 目录必须为空。' }
        if (Test-Path -LiteralPath $context.Destination) { throw 'Destination 在下载期间已出现，拒绝覆盖。' }
        [System.IO.Directory]::Move($context.Staging, $context.Destination)
        $stagingCreated = $false
        Write-Host "Release $RequestedTag 已校验并下载到：$($context.Destination)"
        Write-Host "已校验下载文件数：$($validatedManifest.Files.Count + 1)（包含 manifest.json）；另已校验 download-release.ps1 asset 元数据。未安装或运行任何文件。"
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
                    Remove-Item -LiteralPath $context.Staging -Recurse -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath $context.Staging) { throw '暂存目录删除后仍然存在。' }
                } catch { $cleanupFailure = $_.Exception.Message }
            }
        }
        $token = $null
        $manifestBytes = $null
        $manifestText = $null
        $provenanceText = $null
        $sourceText = $null
        if ($null -ne $cleanupFailure) {
            $cleanupMessage = "下载暂存目录清理失败，残留路径：$($context.Staging)。清理错误：$cleanupFailure"
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
