[CmdletBinding()]
param(
    [string]$ReleaseDirectory,
    [string]$ExpectedCommit,
    [string]$Tag,
    [string]$NotesPath,
    [ValidateSet('Draft', 'Publish')][string]$Mode
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

$script:repositoryFullName = 'iCassius/WIREX_Bridge'
$script:repositoryUrl = 'https://github.com/iCassius/WIREX_Bridge.git'
$script:approvedFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:publishTag = 'v0.1.0-alpha.1'
$script:alpha1TestNames = @(
    'dmrd_test','direct_frame_test','hri_t_payload_test','direct_stream_test','hri_session_test','hri_ptt_gate_test',
    'hri_downlink_session_test','hri_radio_protocol_test','operation_audio_cleanup_test','audio_input_cleanup_test',
    'wave_output_open_test','session_timing_test','wave_file_test','pcm_gain_test','bounded_pipe_writer_test',
    'console_lifecycle_test','session_report_test','dmr_call_test','bm_session_test','bm_udp_test','dmr_vocoder_test',
    'pcm_resampler_test','bm_voice_pipeline_test','bm_test_profile_test','bm_connection_config_test',
    'hri_stream_session_test','bm_bridge_loopback_test'
)
$script:alpha2TestNames = @(
    $script:alpha1TestNames[0..14] + 'ui_pipe_test' +
    $script:alpha1TestNames[15..($script:alpha1TestNames.Count - 1)]
)
$script:alpha3TestNames = @(
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
$script:alpha5TestNames = @($script:alpha3TestNames + 'ui_control_protocol_v2_test')
$script:alpha6TestNames = @($script:alpha5TestNames + 'talkgroup_routing_test' + 'bm_routing_lifecycle_test' + 'routing_state_test')
$script:alpha7TestNames = @($script:alpha6TestNames)
$script:alpha8TestNames = @($script:alpha7TestNames)
$script:alpha9TestNames = @($script:alpha8TestNames)
$script:alpha10TestNames = @($script:alpha9TestNames)
$script:alpha11TestNames = @(
    $script:alpha10TestNames[0..5] + 'radio_identity_cache_test' +
    $script:alpha10TestNames[6..($script:alpha10TestNames.Count - 1)]
)
$script:alpha12TestNames = @($script:alpha11TestNames)
$script:alpha13TestNames = @($script:alpha12TestNames)
$script:alpha14TestNames = @($script:alpha13TestNames)

function Set-PublishProfile {
    param([Parameter(Mandatory=$true)][string]$Tag)
    switch -CaseSensitive ($Tag) {
        'v0.1.0-alpha.1' {
            $assetMap = [ordered]@{
                'wirex_bridge.exe'='wirex_bridge.exe'
                'build-provenance.json'='build-provenance.json'
                'start-bm-radio-bridge.cmd'='start-bm-radio-bridge.cmd'
                'start-bm-radio-bridge.ps1'='start-bm-radio-bridge.ps1'
                'start-listen-91.cmd'='start-listen-91.cmd'
                'start-profile.cmd'='start-profile.cmd'
                'README.md'='README.md'
                'SOURCE.txt'='SOURCE.txt'
                'docs/连接配置.md'='docs__connection-profile.md'
                'docs/音量调节.md'='docs__audio-gain.md'
                'licenses/dmr_signal/COPYING.GPL-3.0.txt'='licenses__dmr-signal__COPYING.GPL-3.0.txt'
                'licenses/dmr_signal/NOTICE.md'='licenses__dmr-signal__NOTICE.md'
                'licenses/droidstar_mbe/COPYING.GPL-3.0.txt'='licenses__droidstar-mbe__COPYING.GPL-3.0.txt'
                'licenses/droidstar_mbe/ISC-NOTICE.txt'='licenses__droidstar-mbe__ISC-NOTICE.txt'
                'licenses/droidstar_mbe/source-manifest.json'='licenses__droidstar-mbe__source-manifest.json'
                'private/device-y.bin'='private__device-y.bin'
            }
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @('docs', 'licenses', 'licenses/dmr_signal', 'licenses/droidstar_mbe', 'logs', 'private')
            $script:expectedTestNames = $script:alpha1TestNames
        }
        'v0.1.0-alpha.2' {
            $assetMap = [ordered]@{
                'wirex_bridge.exe'='wirex_bridge.exe'
                'build-provenance.json'='build-provenance.json'
                'start-bm-radio-bridge.cmd'='start-bm-radio-bridge.cmd'
                'start-bm-radio-bridge.ps1'='start-bm-radio-bridge.ps1'
                'start-listen-91.cmd'='start-listen-91.cmd'
                'start-profile.cmd'='start-profile.cmd'
                'start-ui.cmd'='start-ui.cmd'
                'start-ui.ps1'='start-ui.ps1'
                'start-user-config.cmd'='start-user-config.cmd'
                'start-user-config.ps1'='start-user-config.ps1'
                'bridge-user-config.psm1'='bridge-user-config.psm1'
                'README.md'='README.md'
                'SOURCE.txt'='SOURCE.txt'
                'docs/配置与桌面操作.md'='docs__desktop-user-config.md'
                'docs/连接配置.md'='docs__connection-profile.md'
                'docs/音量调节.md'='docs__audio-gain.md'
                'ui/windows/bridge-ui.ps1'='ui__windows__bridge-ui.ps1'
                'ui/windows/BridgeSupervisor.cs'='ui__windows__BridgeSupervisor.cs'
                'ui/windows/MainWindow.xaml'='ui__windows__MainWindow.xaml'
                'ui/windows/SettingsWindow.xaml'='ui__windows__SettingsWindow.xaml'
                'licenses/dmr_signal/COPYING.GPL-3.0.txt'='licenses__dmr-signal__COPYING.GPL-3.0.txt'
                'licenses/dmr_signal/NOTICE.md'='licenses__dmr-signal__NOTICE.md'
                'licenses/droidstar_mbe/COPYING.GPL-3.0.txt'='licenses__droidstar-mbe__COPYING.GPL-3.0.txt'
                'licenses/droidstar_mbe/ISC-NOTICE.txt'='licenses__droidstar-mbe__ISC-NOTICE.txt'
                'licenses/droidstar_mbe/source-manifest.json'='licenses__droidstar-mbe__source-manifest.json'
                'private/device-y.bin'='private__device-y.bin'
            }
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @('docs', 'licenses', 'licenses/dmr_signal', 'licenses/droidstar_mbe', 'logs', 'private', 'ui', 'ui/windows')
            $script:expectedTestNames = $script:alpha2TestNames
        }
        'v0.1.0-alpha.3' {
            $alpha2 = Set-PublishProfile -Tag 'v0.1.0-alpha.2'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha2.AssetPathMap.Keys) { $assetMap[$path] = $alpha2.AssetPathMap[$path] }
            $assetMap['docs/BM来话身份显示.md'] = 'docs__bm-call-identity.md'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha2.Directories)
            $script:expectedTestNames = $script:alpha3TestNames
        }
        'v0.1.0-alpha.4' {
            $alpha3 = Set-PublishProfile -Tag 'v0.1.0-alpha.3'
            $script:publishTag = $Tag
            $script:assetPathMap = [ordered]@{}
            foreach ($path in $alpha3.AssetPathMap.Keys) { $script:assetPathMap[$path] = $alpha3.AssetPathMap[$path] }
            $script:expectedDirectories = @($alpha3.Directories)
            $script:expectedTestNames = @($alpha3.TestNames)
        }
        'v0.1.0-alpha.5' {
            $alpha4 = Set-PublishProfile -Tag 'v0.1.0-alpha.4'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha4.AssetPathMap.Keys) { $assetMap[$path] = $alpha4.AssetPathMap[$path] }
            $assetMap['docs/R106_IPC第二版.md'] = 'docs__r106-ipc-v2.md'
            $assetMap['docs/R106_配置迁移与测试.md'] = 'docs__r106-profile-migration-test.md'
            $assetMap['start-step1-test.cmd'] = 'start-step1-test.cmd'
            $assetMap['start-step1-test.ps1'] = 'start-step1-test.ps1'
            $assetMap['test-control.cmd'] = 'test-control.cmd'
            $assetMap['test-control.ps1'] = 'test-control.ps1'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha4.Directories)
            $script:expectedTestNames = $script:alpha5TestNames
        }
        'v0.1.0-alpha.6' {
            $alpha5 = Set-PublishProfile -Tag 'v0.1.0-alpha.5'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha5.AssetPathMap.Keys) { $assetMap[$path] = $alpha5.AssetPathMap[$path] }
            $assetMap['docs/R108_收发路由状态与alpha6验收.md'] = 'docs__r108-routing-state-alpha6.md'
            $assetMap['start-merged-test.cmd'] = 'start-merged-test.cmd'
            $assetMap['start-merged-test.ps1'] = 'start-merged-test.ps1'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha5.Directories)
            $script:expectedTestNames = $script:alpha6TestNames
        }
        'v0.1.0-alpha.7' {
            $alpha6 = Set-PublishProfile -Tag 'v0.1.0-alpha.6'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha6.AssetPathMap.Keys) { $assetMap[$path] = $alpha6.AssetPathMap[$path] }
            $assetMap['docs/R109_下行状态与动态组修复.md'] = 'docs__r109-downlink-dynamic-groups.md'
            $assetMap['docs/R109_动态组激活实现.md'] = 'docs__r109-dynamic-group-activation.md'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha6.Directories)
            $script:expectedTestNames = $script:alpha7TestNames
        }
        'v0.1.0-alpha.8' {
            $alpha7 = Set-PublishProfile -Tag 'v0.1.0-alpha.7'
            $excludedPaths = @(
                'start-bm-radio-bridge.cmd', 'start-listen-91.cmd', 'start-profile.cmd',
                'start-ui.cmd', 'start-user-config.cmd', 'start-user-config.ps1',
                'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1',
                'start-merged-test.cmd', 'start-merged-test.ps1'
            )
            $assetMap = [ordered]@{}
            foreach ($path in $alpha7.AssetPathMap.Keys) {
                if ($excludedPaths -cnotcontains [string]$path) { $assetMap[$path] = $alpha7.AssetPathMap[$path] }
            }
            $assetMap['start-wirex-bridge.cmd'] = 'start-wirex-bridge.cmd'
            $assetMap['tools/start-wirex-bridge.ps1'] = 'tools__start-wirex-bridge.ps1'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha7.Directories) + 'tools'
            $script:expectedTestNames = $script:alpha8TestNames
        }
        'v0.1.0-alpha.9' {
            $alpha8 = Set-PublishProfile -Tag 'v0.1.0-alpha.8'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha8.AssetPathMap.Keys) { $assetMap[$path] = $alpha8.AssetPathMap[$path] }
            $assetMap['ui/windows/RadioIdentity.psm1'] = 'ui__windows__radio-identity.psm1'
            $assetMap['docs/R111_UI与音量.md'] = 'docs__r111-ui-audio.md'
            $assetMap['docs/R111_BM订阅与收听优先级.md'] = 'docs__r111-bm-listening-policy.md'
            $assetMap['docs/R111_用户资料与电台显示.md'] = 'docs__r111-radio-identity-display.md'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha8.Directories)
            $script:expectedTestNames = $script:alpha9TestNames
        }
        'v0.1.0-alpha.10' {
            $alpha9 = Set-PublishProfile -Tag 'v0.1.0-alpha.9'
            $assetMap = [ordered]@{}
            $excludedAlpha9Docs = @(
                'docs/R111_UI与音量.md',
                'docs/R111_BM订阅与收听优先级.md',
                'docs/R111_用户资料与电台显示.md'
            )
            foreach ($path in $alpha9.AssetPathMap.Keys) {
                if ($excludedAlpha9Docs -cnotcontains ([string]$path)) { $assetMap[$path] = $alpha9.AssetPathMap[$path] }
            }
            $assetMap['docs/R112_A_身份查询实施.md'] = 'docs__r112-a-identity-lookup.md'
            $assetMap['docs/R112_A_网络音频指标.md'] = 'docs__r112-a-network-audio-metrics.md'
            $assetMap['docs/R112_A_UI精简.md'] = 'docs__r112-a-ui-compact.md'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha9.Directories)
            $script:expectedTestNames = $script:alpha10TestNames
        }
        'v0.1.0-alpha.11' {
            $alpha10 = Set-PublishProfile -Tag 'v0.1.0-alpha.10'
            $assetMap = [ordered]@{}
            $excludedAlpha10Docs = @(
                'docs/R112_A_身份查询实施.md',
                'docs/R112_A_UI精简.md'
            )
            foreach ($path in $alpha10.AssetPathMap.Keys) {
                if ($excludedAlpha10Docs -cnotcontains ([string]$path)) { $assetMap[$path] = $alpha10.AssetPathMap[$path] }
            }
            $assetMap['docs/R113_LCD核心实现.md'] = 'docs__r113-lcd-core-implementation.md'
            $assetMap['docs/R113_身份与LCD接线.md'] = 'docs__r113-identity-lcd-integration.md'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha10.Directories)
            $script:expectedTestNames = $script:alpha11TestNames
        }
        'v0.1.0-alpha.12' {
            $alpha11 = Set-PublishProfile -Tag 'v0.1.0-alpha.11'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha11.AssetPathMap.Keys) { $assetMap[$path] = $alpha11.AssetPathMap[$path] }
            $assetMap['ui/windows/RadioCat.psm1'] = 'ui__windows__radio-cat.psm1'
            $assetMap['docs/R116_CAT能力与控制实现.md'] = 'docs__r116-cat-controls.md'
            $assetMap['docs/R116_电台控制界面.md'] = 'docs__r116-radio-controls-ui.md'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha11.Directories)
            $script:expectedTestNames = $script:alpha12TestNames
        }
        'v0.1.0-alpha.13' {
            $alpha12 = Set-PublishProfile -Tag 'v0.1.0-alpha.12'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha12.AssetPathMap.Keys) { $assetMap[$path] = $alpha12.AssetPathMap[$path] }
            $assetMap['ui/windows/RadioCatUi.ps1'] = 'ui__windows__radio-cat-ui.ps1'
            $assetMap['ui/windows/RadioDevices.psm1'] = 'ui__windows__radio-devices.psm1'
            $assetMap['ui/windows/BmServers.psm1'] = 'ui__windows__bm-servers.psm1'
            $assetMap['ui/windows/BmManagement.psm1'] = 'ui__windows__bm-management.psm1'
            $assetMap['ui/windows/BmManagementUi.ps1'] = 'ui__windows__bm-management-ui.ps1'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha12.Directories)
            $script:expectedTestNames = $script:alpha13TestNames
        }
        'v0.1.0-alpha.14' {
            $alpha13 = Set-PublishProfile -Tag 'v0.1.0-alpha.13'
            $assetMap = [ordered]@{}
            foreach ($path in $alpha13.AssetPathMap.Keys) { $assetMap[$path] = $alpha13.AssetPathMap[$path] }
            $assetMap['ui/windows/PortableConfig.psm1'] = 'ui__windows__portable-config.psm1'
            $script:publishTag = $Tag
            $script:assetPathMap = $assetMap
            $script:expectedDirectories = @($alpha13.Directories)
            $script:expectedTestNames = $script:alpha14TestNames
        }
        default { throw 'Only v0.1.0-alpha.1 through v0.1.0-alpha.14 release profiles are supported.' }
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

function Get-PublishAssetName {
    param([string]$RelativePath)
    if (@($script:assetPathMap.Keys | Where-Object { [string]$_ -ceq $RelativePath }).Count -ne 1) {
        throw 'Package contains a path outside the fixed release allowlist.'
    }
    return [string]$script:assetPathMap[$RelativePath]
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
    param([string]$PackageRoot, [string]$ExpectedCommit, [string]$Tag = $script:publishTag)
    [void](Set-PublishProfile -Tag $Tag)
    $root = [System.IO.Path]::GetFullPath($PackageRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'ReleaseDirectory does not exist.' }
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Package is missing manifest.json.' }
    try { $manifest = (Get-StrictUtf8Text -Path $manifestPath) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'manifest.json is invalid JSON.' }
    if ([int]$manifest.schema_version -ne 1 -or
        [string]$manifest.manifest_asset_name -cne 'manifest.json' -or
        [string]$manifest.package_kind -cne 'wirex_bridge_private_alpha_release_green_directory' -or
        [string]$manifest.package_status -cne 'root_audit_passed' -or
        [string]$manifest.version -cne $Tag -or
        [string]$manifest.tag_candidate -cne $Tag -or
        [string]$manifest.source.repository -cne $script:repositoryUrl -or
        ([string]$manifest.source.commit).ToLowerInvariant() -cne $ExpectedCommit -or
        $manifest.source.working_tree_clean -ne $true -or
        ([string]$manifest.build.source_commit).ToLowerInvariant() -cne $ExpectedCommit -or
        $manifest.build.source_tree_clean -ne $true -or $manifest.build.compile_only -ne $false -or
        $manifest.build.build_completed -ne $true -or [string]$manifest.build.result -cne 'passed') {
        throw 'Package metadata does not attest the audited clean build for the expected commit and tag.'
    }
    $manifestTests = @($manifest.build.passed_tests | ForEach-Object { [string]$_ })
    if ([int]$manifest.build.passed_test_count -ne $script:expectedTestNames.Count -or
        $manifestTests.Count -ne $script:expectedTestNames.Count) {
        throw 'Package metadata does not record the exact offline test set for this release tag.'
    }
    for ($index = 0; $index -lt $script:expectedTestNames.Count; $index++) {
        if ($manifestTests[$index] -cne $script:expectedTestNames[$index]) {
            throw 'Package metadata does not record the exact offline test set for this release tag.'
        }
    }
    if ([string]$manifest.approved_y_fixture.path -cne 'private/device-y.bin' -or
        [long]$manifest.approved_y_fixture.length_bytes -ne 100 -or
        ([string]$manifest.approved_y_fixture.sha256).ToLowerInvariant() -cne $script:approvedFixtureSha256) {
        throw 'Package metadata does not identify the approved 100-byte Y fixture.'
    }
    if ($Tag -ceq 'v0.1.0-alpha.13') {
        $excludedPrivateFiles = @($manifest.excluded_private_files | ForEach-Object { [string]$_ })
        foreach ($requiredPath in @(
            'private/user-config/radio-control-preferences.json',
            'private/user-config/bm-management-preferences.json',
            'private/user-config/bm-server-preferences.json'
        )) {
            if ($excludedPrivateFiles -cnotcontains $requiredPath) {
                throw 'Alpha 13 manifest must explicitly exclude the local radio and BM preference files.'
            }
        }
    }
    if ($Tag -ceq 'v0.1.0-alpha.14') {
        $excludedPrivateFiles = @($manifest.excluded_private_files | ForEach-Object { [string]$_ })
        foreach ($requiredPath in @(
            'config.json',
            'config.*.backup*',
            'credentials/',
            'tempSecrets/',
            'private/user-config-directory.txt',
            'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json',
            'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json',
            'private/user-config/bm-management-preferences.json',
            'private/user-config/bm-server-preferences.json'
        )) {
            if ($excludedPrivateFiles -cnotcontains $requiredPath) {
                throw 'Alpha 14 manifest must explicitly exclude the package-root configuration, backups, credentials, and legacy local preferences.'
            }
        }
    }

    $actualFiles = [System.Collections.Generic.List[string]]::new()
    $actualDirectories = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package may not contain reparse points.' }
        $relative = $item.FullName.Substring($root.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1).Replace('\', '/')
        if ($item.PSIsContainer) { $actualDirectories.Add($relative) } else { $actualFiles.Add($relative) }
    }
    $expectedFiles = @($script:assetPathMap.Keys) + 'manifest.json'
    $actualFileText = (@($actualFiles | Sort-Object -CaseSensitive) -join "`n")
    $expectedFileText = (@($expectedFiles | Sort-Object -CaseSensitive) -join "`n")
    $actualDirectoryText = (@($actualDirectories | Sort-Object -CaseSensitive) -join "`n")
    $expectedDirectoryText = (@($script:expectedDirectories | Sort-Object -CaseSensitive) -join "`n")
    if ($actualFileText -cne $expectedFileText -or $actualDirectoryText -cne $expectedDirectoryText) {
        throw 'Package contains missing, extra, or misplaced files or directories.'
    }
    if (@($manifest.files).Count -ne $script:assetPathMap.Count) { throw 'manifest.files does not match the fixed package inventory.' }

    $seenPaths = @{}
    $seenAssets = @{}
    $assetPlan = New-Object System.Collections.ArrayList
    foreach ($record in @($manifest.files)) {
        $path = [string]$record.path
        if (-not $script:assetPathMap.Contains($path) -or $seenPaths.ContainsKey($path)) { throw 'manifest.files contains an unknown or duplicate path.' }
        $seenPaths[$path] = $true
        $assetName = [string]$record.asset_name
        if ($assetName -cne (Get-PublishAssetName -RelativePath $path) -or $assetName -notmatch '^[A-Za-z0-9._-]+$' -or $seenAssets.ContainsKey($assetName)) {
            throw 'manifest contains an invalid or duplicate asset name.'
        }
        $seenAssets[$assetName] = $true
        $fullPath = Join-Path $root $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([long]$record.length_bytes -ne [long]$item.Length -or ([string]$record.sha256).ToLowerInvariant() -cne $hash) {
            throw 'A package file does not match its manifest length and SHA-256.'
        }
        if ($path -ceq 'private/device-y.bin' -and ([long]$item.Length -ne 100 -or $hash -cne $script:approvedFixtureSha256)) {
            throw 'The package Y fixture does not match the approved length and SHA-256.'
        }
        [void]$assetPlan.Add([pscustomobject]@{ Name=$assetName; Path=$fullPath; Length=[long]$item.Length; Sha256=$hash })
    }
    $manifestItem = Get-Item -LiteralPath $manifestPath
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$assetPlan.Add([pscustomobject]@{ Name='manifest.json'; Path=$manifestPath; Length=[long]$manifestItem.Length; Sha256=$manifestHash })
    return ,([pscustomobject]@{ Manifest=$manifest; Assets=@($assetPlan) })
}

function Export-CommitHelperBlob {
    param([string]$RepositoryRoot, [string]$ExpectedCommit)
    $helperObjectPath = ($ExpectedCommit + ':tools/download-release.ps1')
    $blobId = Get-GitText -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', $helperObjectPath)
    if ($blobId -cnotmatch '^[0-9a-f]{40}$') { throw 'The download helper is absent from the expected source commit.' }
    $workRoot = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'build/_work'))
    if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) { throw 'The repository build/_work directory is unavailable.' }
    $tempPath = Join-Path $workRoot ('publish-helper-' + [guid]::NewGuid().ToString('N') + '.bin')
    if (-not (Test-PublishPathWithin -Path $tempPath -Directory $workRoot) -or (Test-Path -LiteralPath $tempPath)) {
        throw 'Could not allocate a safe temporary helper file.'
    }
    $process = $null
    $stderrTask = $null
    try {
        $gitCommand = Get-Command git -ErrorAction Stop
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $gitCommand.Source
        $quotedRoot = '"' + $RepositoryRoot.Replace('"', '\"') + '"'
        $start.Arguments = '-C ' + $quotedRoot + ' cat-file blob ' + $blobId
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'Could not start local Git.' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $output = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($output)
            if (-not $process.WaitForExit(15000)) {
                try { $process.Kill() } catch { }
                $stopped = $false
                try { $stopped = $process.WaitForExit(5000) } catch { }
                if (-not $stopped) { throw 'The Git blob process did not stop after timeout; a temporary file may remain under build/_work.' }
                throw 'Reading the expected helper Git blob timed out.'
            }
            [void]$copyTask.GetAwaiter().GetResult()
        } finally { $output.Dispose() }
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'The expected helper Git blob could not be read.' }
        $item = Get-Item -LiteralPath $tempPath
        if ($item.Length -le 0) { throw 'The expected helper Git blob is empty.' }
        $hash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
        return [pscustomobject]@{ Name='download-release.ps1'; Path=$tempPath; Length=[long]$item.Length; Sha256=$hash; Temporary=$true }
    } catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop }
            catch { throw 'Could not remove the temporary helper file under build/_work.' }
        }
        if ($_.Exception.Message -match 'timed out') { throw 'Reading the expected helper Git blob timed out.' }
        if ($_.Exception.Message -match 'did not stop') { throw 'The Git blob process did not stop after timeout; a temporary file may remain under build/_work.' }
        throw 'The expected helper Git blob could not be verified.'
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
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
        [string]$Release.body -cne $Notes -or $Release.prerelease -ne $true -or
        $Release.draft -ne $MustBeDraft) {
        throw 'The existing GitHub release does not match the expected tag, notes, commit, or prerelease state.'
    }
}

function Get-PublishReleaseAction {
    param([object]$Release, [string]$ExpectedCommit, [string]$Notes)
    if ($null -eq $Release -or $Release.prerelease -ne $true) { throw 'A matching prerelease record is required.' }
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
        prerelease = $true
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
    $body = [ordered]@{ target_commitish=$ExpectedCommit; body=$Notes; draft=$false; prerelease=$true }
    try {
        return (Send-GitHubRequest -Method 'PATCH' -Uri ($script:repoBase + '/releases/' + [long]$Release.id) -Content (New-GitHubJsonContent -Value $body)).Data
    } catch {
        if (-not (Test-UnknownOutcomeError -Exception $_.Exception)) { throw }
        $recovered = Get-ReleaseByTag
        if ($null -eq $recovered -or $recovered.draft -ne $false -or $recovered.prerelease -ne $true -or
            [string]$recovered.target_commitish -cne $ExpectedCommit -or [string]$recovered.body -cne $Notes) {
            throw 'Release publication outcome is unknown; no retry was attempted.'
        }
        return $recovered
    }
}

function Invoke-ReleasePublisher {
    param([string]$PackagePath, [string]$Commit, [string]$NotesFile, [string]$PublisherMode, [string]$RepositoryRoot,
        [string]$Tag = 'v0.1.0-alpha.1')
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
    $helper = $null
    $script:githubClient = $null
    $script:anonymousClient = $null
    $script:token = $null
    try {
    $helper = Export-CommitHelperBlob -RepositoryRoot $root -ExpectedCommit $Commit
    $assets = @($package.Assets) + @($helper)
    $expectedRemoteAssetCount = $package.Assets.Count + 1
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
            Write-Output ('Verified published prerelease ' + $script:publishTag + '; assets=' + $assets.Count + '.')
            return
        }
        $published = Publish-VerifiedRelease -Release $release -ExpectedCommit $Commit -Notes $notes
        Assert-ReleaseIdentity -Release $published -ExpectedCommit $Commit -Notes $notes -MustBeDraft $false
        Write-Output ('Published prerelease ' + $script:publishTag + '; assets=' + $assets.Count + '.')
    } finally {
        if ($null -ne $script:githubClient) { $script:githubClient.Dispose(); $script:githubClient=$null }
        if ($null -ne $script:anonymousClient) { $script:anonymousClient.Dispose(); $script:anonymousClient=$null }
        $script:token = $null
        if ($null -ne $helper -and $helper.Temporary -and (Test-Path -LiteralPath $helper.Path -PathType Leaf) -and
            (Test-PublishPathWithin -Path $helper.Path -Directory (Join-Path $root 'build/_work')) -and
            [System.IO.Path]::GetFileName($helper.Path) -match '^publish-helper-[0-9a-f]{32}\.bin$') {
            try { Remove-Item -LiteralPath $helper.Path -Force -ErrorAction Stop }
            catch { throw 'Could not remove the temporary helper file under build/_work.' }
        }
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
