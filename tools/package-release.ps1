[CmdletBinding()]
param(
    [string]$Version,
    [string]$BuildDirectory,
    [string]$BuildLogPath,
    [string]$YFixturePath
)

$ErrorActionPreference = 'Stop'

$script:approvedYFixtureSha256 = '82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f'
$script:alpha1TestNames = @(
    'dmrd_test',
    'direct_frame_test',
    'hri_t_payload_test',
    'direct_stream_test',
    'hri_session_test',
    'hri_ptt_gate_test',
    'hri_downlink_session_test',
    'hri_radio_protocol_test',
    'operation_audio_cleanup_test',
    'audio_input_cleanup_test',
    'wave_output_open_test',
    'session_timing_test',
    'wave_file_test',
    'pcm_gain_test',
    'bounded_pipe_writer_test',
    'console_lifecycle_test',
    'session_report_test',
    'dmr_call_test',
    'bm_session_test',
    'bm_udp_test',
    'dmr_vocoder_test',
    'pcm_resampler_test',
    'bm_voice_pipeline_test',
    'bm_test_profile_test',
    'bm_connection_config_test',
    'hri_stream_session_test',
    'bm_bridge_loopback_test'
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
$script:alpha4TestNames = @($script:alpha3TestNames)
$script:alpha5TestNames = @($script:alpha4TestNames + 'ui_control_protocol_v2_test')
$script:alpha6TestNames = @($script:alpha5TestNames + 'talkgroup_routing_test' + 'bm_routing_lifecycle_test' + 'routing_state_test')
$script:activeReleaseVersion = 'v0.1.0-alpha.1'

function Get-ReleaseProfile {
    param([Parameter(Mandatory=$true)][string]$Version)
    switch -CaseSensitive ($Version) {
        'v0.1.0-alpha.1' {
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.1'
                TestNames = $script:alpha1TestNames
                SourceFiles = @(
                    @{ Source='tools\start-bm-radio-bridge.cmd'; Destination='start-bm-radio-bridge.cmd' },
                    @{ Source='tools\start-bm-radio-bridge.ps1'; Destination='start-bm-radio-bridge.ps1' },
                    @{ Source='tools\start-listen-91.cmd'; Destination='start-listen-91.cmd' },
                    @{ Source='tools\start-profile.cmd'; Destination='start-profile.cmd' },
                    @{ Source='docs\releases\v0.1.0-alpha.1-package-README.md'; Destination='README.md' },
                    @{ Source='docs\连接配置.md'; Destination='docs\连接配置.md' },
                    @{ Source='docs\音量调节.md'; Destination='docs\音量调节.md' },
                    @{ Source='third_party\dmr_signal\COPYING.GPL-3.0.txt'; Destination='licenses\dmr_signal\COPYING.GPL-3.0.txt' },
                    @{ Source='third_party\dmr_signal\NOTICE.md'; Destination='licenses\dmr_signal\NOTICE.md' },
                    @{ Source='third_party\droidstar_mbe\COPYING.GPL-3.0.txt'; Destination='licenses\droidstar_mbe\COPYING.GPL-3.0.txt' },
                    @{ Source='third_party\droidstar_mbe\ISC-NOTICE.txt'; Destination='licenses\droidstar_mbe\ISC-NOTICE.txt' },
                    @{ Source='third_party\droidstar_mbe\source-manifest.json'; Destination='licenses\droidstar_mbe\source-manifest.json' }
                )
                PackageFiles = @(
                    'wirex_bridge.exe', 'build-provenance.json', 'start-bm-radio-bridge.cmd', 'start-bm-radio-bridge.ps1',
                    'start-listen-91.cmd', 'start-profile.cmd', 'README.md', 'SOURCE.txt', 'manifest.json',
                    'docs/连接配置.md', 'docs/音量调节.md',
                    'licenses/dmr_signal/COPYING.GPL-3.0.txt', 'licenses/dmr_signal/NOTICE.md',
                    'licenses/droidstar_mbe/COPYING.GPL-3.0.txt', 'licenses/droidstar_mbe/ISC-NOTICE.txt',
                    'licenses/droidstar_mbe/source-manifest.json', 'private/device-y.bin'
                )
                Directories = @('docs', 'licenses', 'licenses/dmr_signal', 'licenses/droidstar_mbe', 'logs', 'private')
                AssetMap = [ordered]@{
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
                PackageReadme = 'docs\releases\v0.1.0-alpha.1-package-README.md'
                ReleaseScope = 'FTX-1 DIRECT personal terminal with BrandMeister voice bridging'
                NotIncluded = @('LCD text/routing integration', 'RF node operation', 'graphical UI')
            }
        }
        'v0.1.0-alpha.2' {
            $alpha2SourceFiles = @(
                @{ Source='tools\start-bm-radio-bridge.cmd'; Destination='start-bm-radio-bridge.cmd' },
                @{ Source='tools\start-bm-radio-bridge.ps1'; Destination='start-bm-radio-bridge.ps1' },
                @{ Source='tools\start-listen-91.cmd'; Destination='start-listen-91.cmd' },
                @{ Source='tools\start-profile.cmd'; Destination='start-profile.cmd' },
                @{ Source='tools\start-ui.cmd'; Destination='start-ui.cmd' },
                @{ Source='tools\start-ui.ps1'; Destination='start-ui.ps1' },
                @{ Source='tools\start-user-config.cmd'; Destination='start-user-config.cmd' },
                @{ Source='tools\start-user-config.ps1'; Destination='start-user-config.ps1' },
                @{ Source='tools\bridge-user-config.psm1'; Destination='bridge-user-config.psm1' },
                @{ Source='ui\windows\bridge-ui.ps1'; Destination='ui\windows\bridge-ui.ps1' },
                @{ Source='ui\windows\BridgeSupervisor.cs'; Destination='ui\windows\BridgeSupervisor.cs' },
                @{ Source='ui\windows\MainWindow.xaml'; Destination='ui\windows\MainWindow.xaml' },
                @{ Source='ui\windows\SettingsWindow.xaml'; Destination='ui\windows\SettingsWindow.xaml' },
                @{ Source='docs\releases\v0.1.0-alpha.2-package-README.md'; Destination='README.md' },
                @{ Source='docs\配置与桌面操作.md'; Destination='docs\配置与桌面操作.md' },
                @{ Source='docs\连接配置.md'; Destination='docs\连接配置.md' },
                @{ Source='docs\音量调节.md'; Destination='docs\音量调节.md' },
                @{ Source='third_party\dmr_signal\COPYING.GPL-3.0.txt'; Destination='licenses\dmr_signal\COPYING.GPL-3.0.txt' },
                @{ Source='third_party\dmr_signal\NOTICE.md'; Destination='licenses\dmr_signal\NOTICE.md' },
                @{ Source='third_party\droidstar_mbe\COPYING.GPL-3.0.txt'; Destination='licenses\droidstar_mbe\COPYING.GPL-3.0.txt' },
                @{ Source='third_party\droidstar_mbe\ISC-NOTICE.txt'; Destination='licenses\droidstar_mbe\ISC-NOTICE.txt' },
                @{ Source='third_party\droidstar_mbe\source-manifest.json'; Destination='licenses\droidstar_mbe\source-manifest.json' }
            )
            $alpha2AssetMap = [ordered]@{
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
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.2'
                TestNames = $script:alpha2TestNames
                SourceFiles = $alpha2SourceFiles
                PackageFiles = @(
                    'wirex_bridge.exe', 'build-provenance.json', 'start-bm-radio-bridge.cmd', 'start-bm-radio-bridge.ps1',
                    'start-listen-91.cmd', 'start-profile.cmd', 'start-ui.cmd', 'start-ui.ps1',
                    'start-user-config.cmd', 'start-user-config.ps1', 'bridge-user-config.psm1',
                    'README.md', 'SOURCE.txt', 'manifest.json',
                    'docs/配置与桌面操作.md', 'docs/连接配置.md', 'docs/音量调节.md',
                    'ui/windows/bridge-ui.ps1', 'ui/windows/BridgeSupervisor.cs',
                    'ui/windows/MainWindow.xaml', 'ui/windows/SettingsWindow.xaml',
                    'licenses/dmr_signal/COPYING.GPL-3.0.txt', 'licenses/dmr_signal/NOTICE.md',
                    'licenses/droidstar_mbe/COPYING.GPL-3.0.txt', 'licenses/droidstar_mbe/ISC-NOTICE.txt',
                    'licenses/droidstar_mbe/source-manifest.json', 'private/device-y.bin'
                )
                Directories = @('docs', 'licenses', 'licenses/dmr_signal', 'licenses/droidstar_mbe', 'logs', 'private', 'ui', 'ui/windows')
                AssetMap = $alpha2AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.2-package-README.md'
                ReleaseScope = 'FTX-1 DIRECT personal terminal and BrandMeister voice bridge with Windows desktop UI and user configuration'
                NotIncluded = @('LCD text/routing integration', 'RF node operation')
            }
        }
        'v0.1.0-alpha.3' {
            $alpha2 = Get-ReleaseProfile -Version 'v0.1.0-alpha.2'
            $alpha3SourceFiles = @($alpha2.SourceFiles | Where-Object { [string]$_.Destination -cne 'README.md' }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.3-package-README.md'; Destination='README.md' },
                @{ Source='docs\BM来话身份显示.md'; Destination='docs\BM来话身份显示.md' }
            )
            $alpha3AssetMap = [ordered]@{}
            foreach ($path in $alpha2.AssetMap.Keys) { $alpha3AssetMap[$path] = $alpha2.AssetMap[$path] }
            $alpha3AssetMap['docs/BM来话身份显示.md'] = 'docs__bm-call-identity.md'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.3'
                TestNames = $script:alpha3TestNames
                SourceFiles = $alpha3SourceFiles
                PackageFiles = @($alpha2.PackageFiles) + 'docs/BM来话身份显示.md'
                Directories = $alpha2.Directories
                AssetMap = $alpha3AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.3-package-README.md'
                ReleaseScope = 'FTX-1 DIRECT BrandMeister bridge with Windows desktop controls and a per-accepted-call DMR Source ID label in the HRI start record; LCD display remains unverified'
                NotIncluded = @('C4FM RF node operation is not implemented', 'FTX-1 LCD display result is not verified')
            }
        }
        'v0.1.0-alpha.4' {
            $alpha3 = Get-ReleaseProfile -Version 'v0.1.0-alpha.3'
            $alpha4SourceFiles = @($alpha3.SourceFiles | Where-Object { [string]$_.Destination -cne 'README.md' }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.4-package-README.md'; Destination='README.md' }
            )
            $alpha4AssetMap = [ordered]@{}
            foreach ($path in $alpha3.AssetMap.Keys) { $alpha4AssetMap[$path] = $alpha3.AssetMap[$path] }
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.4'
                TestNames = $script:alpha4TestNames
                SourceFiles = $alpha4SourceFiles
                PackageFiles = @($alpha3.PackageFiles)
                Directories = $alpha3.Directories
                AssetMap = $alpha4AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.4-package-README.md'
                ReleaseScope = 'FTX-1 DIRECT BrandMeister bridge with independent receive and transmit targets, a listen-only TG91 profile, a constrained private Echo return rule, and BM China 4602 preset'
                NotIncluded = @(
                    'C4FM RF node operation is not implemented',
                    'FTX-1 LCD display result is not verified',
                    'Radio PTT behavior during Echo playback still requires alpha.4 device verification'
                )
            }
        }
        'v0.1.0-alpha.5' {
            $alpha4 = Get-ReleaseProfile -Version 'v0.1.0-alpha.4'
            $alpha5SourceFiles = @($alpha4.SourceFiles | Where-Object { [string]$_.Destination -cne 'README.md' }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.5-package-README.md'; Destination='README.md' },
                @{ Source='docs\R106_IPC第二版.md'; Destination='docs\R106_IPC第二版.md' },
                @{ Source='docs\R106_配置迁移与测试.md'; Destination='docs\R106_配置迁移与测试.md' },
                @{ Source='tools\start-step1-test.cmd'; Destination='start-step1-test.cmd' },
                @{ Source='tools\start-step1-test.ps1'; Destination='start-step1-test.ps1' },
                @{ Source='tools\test-control.cmd'; Destination='test-control.cmd' },
                @{ Source='tools\test-control.ps1'; Destination='test-control.ps1' }
            )
            $alpha5AssetMap = [ordered]@{}
            foreach ($path in $alpha4.AssetMap.Keys) { $alpha5AssetMap[$path] = $alpha4.AssetMap[$path] }
            $alpha5AssetMap['docs/R106_IPC第二版.md'] = 'docs__r106-ipc-v2.md'
            $alpha5AssetMap['docs/R106_配置迁移与测试.md'] = 'docs__r106-profile-migration-test.md'
            $alpha5AssetMap['start-step1-test.cmd'] = 'start-step1-test.cmd'
            $alpha5AssetMap['start-step1-test.ps1'] = 'start-step1-test.ps1'
            $alpha5AssetMap['test-control.cmd'] = 'test-control.cmd'
            $alpha5AssetMap['test-control.ps1'] = 'test-control.ps1'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.5'
                TestNames = $script:alpha5TestNames
                SourceFiles = $alpha5SourceFiles
                PackageFiles = @($alpha4.PackageFiles) + @(
                    'docs/R106_IPC第二版.md', 'docs/R106_配置迁移与测试.md', 'start-step1-test.cmd', 'start-step1-test.ps1',
                    'test-control.cmd', 'test-control.ps1'
                )
                Directories = @($alpha4.Directories)
                AssetMap = $alpha5AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.5-package-README.md'
                ReleaseScope = 'R106 Step 1 test build: explicit IPC v2 hello/status/shutdown, schema-2 configuration migration, and lossless projection for legacy single-RX profiles; multi-group runtime is not implemented'
                NotIncluded = @(
                    'Multi-group runtime is not implemented; policies that cannot map to one legacy RX target are rejected before core startup',
                    'No BM subscription API, multi-group delivery, quick-call, or new audio pipeline behavior',
                    'No new serial, audio, PTT, RF, or BrandMeister hardware validation'
                )
            }
        }
        'v0.1.0-alpha.6' {
            $alpha5 = Get-ReleaseProfile -Version 'v0.1.0-alpha.5'
            $alpha6SourceFiles = @($alpha5.SourceFiles | Where-Object { [string]$_.Destination -cne 'README.md' }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.6-package-README.md'; Destination='README.md' },
                @{ Source='docs\R108_收发路由状态与alpha6验收.md'; Destination='docs\R108_收发路由状态与alpha6验收.md' },
                @{ Source='tools\start-merged-test.cmd'; Destination='start-merged-test.cmd' },
                @{ Source='tools\start-merged-test.ps1'; Destination='start-merged-test.ps1' }
            )
            $alpha6AssetMap = [ordered]@{}
            foreach ($path in $alpha5.AssetMap.Keys) { $alpha6AssetMap[$path] = $alpha5.AssetMap[$path] }
            $alpha6AssetMap['docs/R108_收发路由状态与alpha6验收.md'] = 'docs__r108-routing-state-alpha6.md'
            $alpha6AssetMap['start-merged-test.cmd'] = 'start-merged-test.cmd'
            $alpha6AssetMap['start-merged-test.ps1'] = 'start-merged-test.ps1'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.6'
                TestNames = $script:alpha6TestNames
                SourceFiles = $alpha6SourceFiles
                PackageFiles = @($alpha5.PackageFiles) + @(
                    'docs/R108_收发路由状态与alpha6验收.md', 'start-merged-test.cmd', 'start-merged-test.ps1'
                )
                Directories = @($alpha5.Directories)
                AssetMap = $alpha6AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.6-package-README.md'
                ReleaseScope = 'R108 Stage 3: full schema-2 receive-policy runtime routing through a strict per-run routing-state file, with the merged alpha.6 desktop entry'
                NotIncluded = @(
                    'Serial, audio, BrandMeister, PTT, and RF behavior has no alpha.6 hardware acceptance record',
                    'The package IPC diagnostic does not exercise radio, audio, or network operation'
                )
            }
        }
        default { throw 'Only v0.1.0-alpha.1, v0.1.0-alpha.2, v0.1.0-alpha.3, v0.1.0-alpha.4, v0.1.0-alpha.5, and v0.1.0-alpha.6 release profiles are supported.' }
    }
}

function Set-ReleaseVersion {
    param([Parameter(Mandatory=$true)][string]$Version)
    $profile = Get-ReleaseProfile -Version $Version
    $script:activeReleaseVersion = $profile.Version
    return $profile
}

function Test-ReleaseVersion {
    param([Parameter(Mandatory=$true)][string]$Value)
    try { [void](Get-ReleaseProfile -Version $Value); return $true } catch { return $false }
}

function Get-ReleaseAssetName {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $profile = Get-ReleaseProfile -Version $script:activeReleaseVersion
    $normalized = $RelativePath.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.StartsWith('/') -or
        $normalized -match '(^|/)\.\.?(/|$)' -or $normalized.Contains(':')) {
        throw "发布文件路径无效：$RelativePath"
    }
    if (@($profile.PackageFiles | Where-Object { [string]$_ -ceq $normalized }).Count -ne 1) {
        throw "发布清单没有为此路径定义 ASCII asset_name：$normalized"
    }
    if ($profile.AssetMap.Contains($normalized)) { return [string]$profile.AssetMap[$normalized] }
    throw "发布清单没有为此路径定义 ASCII asset_name：$normalized"
}

function Resolve-ReleasePath {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$BaseDirectory
    )
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Test-PathWithinDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Directory
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ApprovedYFixture {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到 Y 素材：$Path" }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -ne 100) { throw 'Y 素材必须为获批的 100 字节文件。' }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $script:approvedYFixtureSha256) { throw 'Y 素材 SHA-256 与获批文件不符。' }
    return $hash
}

function Get-ExpectedReleaseTests {
    return (Get-ReleaseProfile -Version $script:activeReleaseVersion).TestNames
}

function Test-ReleaseBuildEvidence {
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$SourceCommit,
        [Parameter(Mandatory=$true)][string]$BuildDirectory,
        [Parameter(Mandatory=$true)][string]$BuildLogPath
    )
    if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw '源码提交必须是完整的小写 SHA-1。' }
    $repo = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $workRoot = [System.IO.Path]::GetFullPath((Join-Path $repo 'build\_work'))
    $build = [System.IO.Path]::GetFullPath($BuildDirectory)
    $log = [System.IO.Path]::GetFullPath($BuildLogPath)
    if (-not (Test-PathWithinDirectory -Path $build -Directory $workRoot) -or
        -not (Test-Path -LiteralPath $build -PathType Container)) {
        throw '构建目录必须是本仓库 build\_work 下的现存目录。'
    }
    if (-not (Test-PathWithinDirectory -Path $log -Directory $workRoot) -or
        -not (Test-Path -LiteralPath $log -PathType Leaf)) {
        throw '构建日志必须是本仓库 build\_work 下的现存文件。'
    }
    $buildName = [System.IO.Path]::GetFileName($build)
    $expectedBuildPrefix = 'wirex-bridge-' + $SourceCommit.Substring(0, 7) + '-'
    if (-not $buildName.StartsWith($expectedBuildPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $buildName -match '-dirty-' -or $buildName -notmatch '^wirex-bridge-[0-9a-f]{7}-[0-9]{8}-[0-9]{6}$') {
        throw '构建目录名未标识当前源码提交的干净正式构建。'
    }

    $exePath = Join-Path $build 'wirex_bridge.exe'
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw '正式构建目录中缺少 wirex_bridge.exe。' }
    $provenancePath = Join-Path $build 'build-provenance.json'
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
        throw '正式构建目录缺少 builder 生成的 build-provenance.json。'
    }
    try {
        $provenance = [System.IO.File]::ReadAllText($provenancePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw "build-provenance.json 无法解析：$($_.Exception.Message)"
    }
    if ($provenance.schema_version -ne 1 -or
        ([string]$provenance.source_commit).ToLowerInvariant() -cne $SourceCommit -or
        $provenance.source_tree_clean -ne $true -or $provenance.compile_only -ne $false -or
        $provenance.build_completed -ne $true -or $provenance.result -cne 'passed') {
        throw 'builder provenance 未证明当前 clean source commit 的完整正式构建。'
    }
    $buildRelative = Get-RepoRelativePath -RepositoryRoot $repo -Path $build
    if (([string]$provenance.output_directory).Replace('\', '/') -cne $buildRelative) {
        throw 'builder provenance 的输出目录与指定构建目录不一致。'
    }
    if ([string]$provenance.executable.path -cne 'wirex_bridge.exe') { throw 'provenance 可执行文件路径无效。' }
    $actualExe = Get-Item -LiteralPath $exePath -ErrorAction Stop
    $actualExeHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([long]$provenance.executable.length_bytes -ne [long]$actualExe.Length -or
        ([string]$provenance.executable.sha256).ToLowerInvariant() -cne $actualExeHash) {
        throw 'wirex_bridge.exe 与 builder provenance 中的长度或 SHA-256 不一致。'
    }
    $expectedTestNames = @(Get-ExpectedReleaseTests)
    $provenanceTests = @($provenance.tests)
    if ($provenanceTests.Count -ne $expectedTestNames.Count) {
        throw "builder provenance 记录的测试数目不符：$($provenanceTests.Count) / $($expectedTestNames.Count)"
    }
    for ($index = 0; $index -lt $expectedTestNames.Count; $index++) {
        if ([string]$provenanceTests[$index].name -cne $expectedTestNames[$index] -or
            [string]$provenanceTests[$index].result -cne 'passed' -or
            [int]$provenanceTests[$index].exit_code -ne 0) {
            throw "builder provenance 未记录测试 $($expectedTestNames[$index]) 成功。"
        }
    }
    $logText = [System.IO.File]::ReadAllText($log, [System.Text.Encoding]::UTF8)
    $expectedOutputLine = '构建产物：' + $build
    $expectedExeLine = '可执行文件：' + $exePath
    if ($logText.IndexOf($expectedOutputLine, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $logText.IndexOf($expectedExeLine, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw '构建日志中的产物目录或可执行文件路径与指定目录不一致。'
    }
    if ($logText -notmatch 'DroidStar 固定 commit 的 57 个本地源文件 SHA-256 全部通过。') {
        throw '构建日志缺少固定 DroidStar 源文件校验结果。'
    }
    $testMatches = [regex]::Matches($logText, '(?m)^运行离线测试：([A-Za-z0-9_]+)\s*$')
    $actualTests = @($testMatches | ForEach-Object { $_.Groups[1].Value })
    if ($actualTests.Count -ne $expectedTestNames.Count) {
        throw "构建日志中的离线测试数目不符：$($actualTests.Count) / $($expectedTestNames.Count)"
    }
    for ($index = 0; $index -lt $expectedTestNames.Count; $index++) {
        if ($actualTests[$index] -cne $expectedTestNames[$index]) {
            throw "构建日志测试顺序或名称不符：索引 $index。"
        }
    }
    $lastTestIndex = $logText.LastIndexOf('运行离线测试：', [System.StringComparison]::Ordinal)
    $outputIndex = $logText.IndexOf($expectedOutputLine, [System.StringComparison]::OrdinalIgnoreCase)
    if ($outputIndex -lt $lastTestIndex) { throw '构建日志未在完整测试后写入成功构建结束标记。' }
    $warnings = [regex]::Matches($logText, '(?im)^.*\bwarning\s+[A-Z]+[0-9]+\b.*$').Count
    $errors = [regex]::Matches($logText, '(?im)^.*\b(?:fatal\s+error|error)\s+[A-Z]+[0-9]+\b.*$').Count
    if ($warnings -ne 0 -or $errors -ne 0) { throw "构建日志包含编译诊断：warning=$warnings error=$errors。" }

    $exe = Get-Item -LiteralPath $exePath -ErrorAction Stop
    return [pscustomobject]@{
        build_directory = $build
        build_log = $log
        executable = $exePath
        executable_length_bytes = [long]$exe.Length
        executable_sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
        build_log_sha256 = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
        build_provenance = $provenancePath
        build_provenance_sha256 = (Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        source_tree_clean = [bool]$provenance.source_tree_clean
        compile_only = [bool]$provenance.compile_only
        build_completed = [bool]$provenance.build_completed
        passed_test_count = $actualTests.Count
        passed_tests = @($actualTests)
        compiler_warnings = $warnings
        compiler_errors = $errors
    }
}

function Get-ReleaseSourceFiles {
    return (Get-ReleaseProfile -Version $script:activeReleaseVersion).SourceFiles
}

function Get-ExpectedReleasePackageFiles {
    return (Get-ReleaseProfile -Version $script:activeReleaseVersion).PackageFiles
}

function Get-ReleaseFileRecord {
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Source
    )
    $relativeNormalized = $RelativePath.Replace('\', '/')
    $fullPath = Join-Path $PackageRoot ($relativeNormalized.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "发布文件缺失：$relativeNormalized" }
    $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    return [ordered]@{
        path = $relativeNormalized
        asset_name = Get-ReleaseAssetName -RelativePath $relativeNormalized
        length_bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source = $Source
    }
}

function Assert-ReleasePackageInventory {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [string]$Version = $script:activeReleaseVersion)
    $profile = Set-ReleaseVersion -Version $Version
    $expectedFiles = @($profile.PackageFiles | Sort-Object)
    $actualFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($PackageRoot.Length + 1).Replace('\', '/')
    } | Sort-Object)
    if ($actualFiles.Count -ne $expectedFiles.Count) { throw "发布目录文件数不符：$($actualFiles.Count) / $($expectedFiles.Count)" }
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        if ($actualFiles[$index] -cne $expectedFiles[$index]) { throw "发布目录含意外文件或缺失文件：$($actualFiles[$index])" }
    }
    $expectedDirectories = @($profile.Directories | Sort-Object)
    $actualDirectories = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Directory | ForEach-Object {
        $_.FullName.Substring($PackageRoot.Length + 1).Replace('\', '/')
    } | Sort-Object)
    if ($actualDirectories.Count -ne $expectedDirectories.Count) { throw '发布目录包含额外目录或缺失目录。' }
    for ($index = 0; $index -lt $expectedDirectories.Count; $index++) {
        if ($actualDirectories[$index] -cne $expectedDirectories[$index]) { throw "发布目录树不符：$($actualDirectories[$index])" }
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'logs') -Force).Count -ne 0) {
        throw '发布包 logs 目录必须为空。'
    }
    $fixturePath = Join-Path $PackageRoot 'private\device-y.bin'
    $fixtureHash = Test-ApprovedYFixture -Path $fixturePath
    $forbidden = @($actualFiles | Where-Object {
        $_ -match '(^|/)(?:bm-device-password\.txt|connection-profile\.json|audio-settings\.json)$' -or
        $_ -match '(^|/)logs/|\.log$'
    })
    if ($forbidden.Count -gt 0) { throw "发布目录含禁止文件：$($forbidden[0])" }
    $manifestPath = Join-Path $PackageRoot 'manifest.json'
    try {
        $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw "发布 manifest 无法解析：$($_.Exception.Message)"
    }
    if ([string]$manifest.version -cne $profile.Version -or
        [string]$manifest.tag_candidate -cne $profile.Version -or $manifest.schema_version -ne 1 -or
        [string]$manifest.package_status -notin @('awaiting_root_audit', 'root_audit_passed')) {
        throw 'manifest schema_version 或 package_status 不受支持。'
    }
    if ([string]$manifest.approved_y_fixture.path -cne 'private/device-y.bin' -or
        [long]$manifest.approved_y_fixture.length_bytes -ne 100 -or
        ([string]$manifest.approved_y_fixture.sha256).ToLowerInvariant() -cne $fixtureHash) {
        throw 'manifest 中的 Y 素材记录与获批文件不一致。'
    }
    $records = @($manifest.files)
    if ($records.Count -ne ($expectedFiles.Count - 1)) { throw 'manifest 记录数与发布文件清单不符。' }
    $sortedRecords = @($records | Sort-Object { ([string]$_.path).Replace('\', '/') })
    $recordPaths = @($sortedRecords | ForEach-Object { ([string]$_.path).Replace('\', '/') })
    $manifestFilePaths = @($expectedFiles | Where-Object { $_ -cne 'manifest.json' })
    if ($recordPaths.Count -ne $manifestFilePaths.Count) { throw 'manifest 路径数与预期文件数不符。' }
    $assetNames = @()
    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $sortedRecords[$index]
        if ($recordPaths[$index] -cne $manifestFilePaths[$index]) { throw "manifest 路径与发布目录不符：$($record.path)" }
        $fullPath = Join-Path $PackageRoot ([string]$record.path).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedAssetName = [string]$profile.AssetMap[([string]$record.path).Replace('\', '/')]
        if ([long]$record.length_bytes -ne [long]$item.Length -or
            ([string]$record.sha256).ToLowerInvariant() -cne $actualHash -or
            [string]$record.asset_name -cne $expectedAssetName -or
            [string]$record.asset_name -notmatch '^[A-Za-z0-9._-]+$') {
            throw "manifest 长度、SHA-256 或 asset_name 与文件不符：$($record.path)"
        }
        $assetNames += [string]$record.asset_name
    }
    $assetNames += [string]$manifest.manifest_asset_name
    if (@($assetNames | Sort-Object -Unique).Count -ne $assetNames.Count) { throw 'manifest asset_name 不唯一。' }
    if ([string]$manifest.manifest_asset_name -cne 'manifest.json' -or
        [string]$manifest.manifest_asset_name -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'manifest_asset_name 必须是 ASCII 名称 manifest.json。'
    }
}

function Invoke-ReleasePackaging {
    param(
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$BuildDirectory,
        [Parameter(Mandatory=$true)][string]$BuildLogPath,
        [Parameter(Mandatory=$true)][string]$YFixturePath,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot
    )
    $profile = Set-ReleaseVersion -Version $Version
    $repo = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $gitRootLines = @(& git -C $repo rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $gitRootLines.Count -lt 1 -or
        -not ([System.IO.Path]::GetFullPath(([string]$gitRootLines[0]).Trim()).Equals($repo, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw '打包脚本必须从 WIREX Bridge Git 仓库运行。'
    }
    $commitLines = @(& git -C $repo rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $commitLines.Count -lt 1) { throw '无法读取当前源码提交。' }
    $sourceCommit = ([string]$commitLines[0]).Trim().ToLowerInvariant()
    if ($sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw '当前源码提交号格式不正确。' }
    $statusLines = @(& git -C $repo status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0 -or $statusLines.Count -ne 0) { throw '发布打包要求 Git 工作树干净且没有未跟踪文件。' }
    $existingTag = @(& git -C $repo tag --list $Version 2>$null | Where-Object { $_ -ceq $Version })
    if ($LASTEXITCODE -ne 0) { throw '无法检查本地 tag 列表。' }
    if ($existingTag.Count -gt 0) { throw "本地已存在 tag $Version；打包器不会复用该版本。" }

    $buildPath = Resolve-ReleasePath -Path $BuildDirectory -BaseDirectory $repo
    $logPath = Resolve-ReleasePath -Path $BuildLogPath -BaseDirectory $repo
    $buildEvidence = Test-ReleaseBuildEvidence -RepositoryRoot $repo -SourceCommit $sourceCommit `
        -BuildDirectory $buildPath -BuildLogPath $logPath
    $fixturePath = Resolve-ReleasePath -Path $YFixturePath -BaseDirectory $repo
    $fixtureHash = Test-ApprovedYFixture -Path $fixturePath

    $releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $repo 'build\releases'))
    if (Test-Path -LiteralPath $releaseRoot -PathType Leaf) { throw 'build\releases 已存在为文件。' }
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $releaseRoot -ErrorAction Stop | Out-Null
    }
    $outputPath = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot $Version))
    if (-not (Test-PathWithinDirectory -Path $outputPath -Directory $releaseRoot)) { throw '发布目录越出 build\releases。' }
    if (Test-Path -LiteralPath $outputPath) { throw "发布目录已存在，拒绝覆盖：$outputPath" }
    $stagingPath = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot ('.staging-' + $Version + '-' + [guid]::NewGuid().ToString('N'))))
    if (-not (Test-PathWithinDirectory -Path $stagingPath -Directory $releaseRoot) -or
        (Test-Path -LiteralPath $stagingPath)) { throw '临时发布目录路径无效或已存在。' }
    New-Item -ItemType Directory -Path $stagingPath -ErrorAction Stop | Out-Null
    $createdOutput = $false
    try {
        $exeSource = Join-Path $buildPath 'wirex_bridge.exe'
        Copy-Item -LiteralPath $exeSource -Destination (Join-Path $stagingPath 'wirex_bridge.exe') -ErrorAction Stop
        Copy-Item -LiteralPath (Join-Path $buildPath 'build-provenance.json') `
            -Destination (Join-Path $stagingPath 'build-provenance.json') -ErrorAction Stop
        foreach ($entry in (Get-ReleaseSourceFiles)) {
            $sourcePath = Join-Path $repo $entry.Source
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "发布源文件不存在：$($entry.Source)" }
            $destinationPath = Join-Path $stagingPath $entry.Destination
            $destinationDirectory = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -ErrorAction Stop
        }
        $yDestinationDirectory = Join-Path $stagingPath 'private'
        New-Item -ItemType Directory -Path $yDestinationDirectory -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $yDestinationDirectory 'device-y.bin') -ErrorAction Stop
        New-Item -ItemType Directory -Path (Join-Path $stagingPath 'logs') -ErrorAction Stop | Out-Null

        $notIncludedText = @($profile.NotIncluded) -join '、'
        $sourceText = @"
WIREX Bridge $Version alpha 候选

源码提交：$sourceCommit
构建源码提交：$sourceCommit
干净正式构建目录：$(Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath)
构建日志：$(Get-RepoRelativePath -RepositoryRoot $repo -Path $logPath)
构建来源记录 SHA-256：$($buildEvidence.build_provenance_sha256)
离线测试：$($buildEvidence.passed_test_count) 项全部通过；编译警告/错误：0/0
wirex_bridge.exe SHA-256：$($buildEvidence.executable_sha256)
批准的 Y 素材：100 字节；SHA-256：$fixtureHash
Release 标签候选：$Version（打包器不创建标签，也不发布 Release）

功能范围：$($profile.ReleaseScope)。
未包含：$notIncludedText。

此前用户确认的实机结果分别来自旧源码：005c5e8 的 DIRECT 鹦鹉回声清晰；ab3c5fa 的 TG91 收听正常。这些结果不属于当前源码版本。当前版本尚未实机联测，连接配置和音量设置也尚未在当前版本实机验证。

发布目录不含 BM 密码、连接配置、音量设置或运行日志；创建时 logs 目录为空。程序运行时会在本机创建所需设置和日志。
"@
        [System.IO.File]::WriteAllText((Join-Path $stagingPath 'SOURCE.txt'), $sourceText.TrimStart(), (New-Object System.Text.UTF8Encoding($false)))

        $records = @()
        $exeRelative = 'wirex_bridge.exe'
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath $exeRelative `
            -Source ((Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath) + '/wirex_bridge.exe'))
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'build-provenance.json' `
            -Source ((Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath) + '/build-provenance.json'))
        foreach ($entry in (Get-ReleaseSourceFiles)) {
            $destination = $entry.Destination.Replace('\', '/')
            $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath $destination `
                -Source ('source commit ' + $sourceCommit + ': ' + $entry.Source.Replace('\', '/')))
        }
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'SOURCE.txt' `
            -Source 'generated from verified source and build evidence')
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'private/device-y.bin' `
            -Source ('approved 100-byte Y fixture; SHA-256 ' + $fixtureHash))
        $assetNames = @($records | ForEach-Object { [string]$_.asset_name })
        if (@($assetNames | Sort-Object -Unique).Count -ne $assetNames.Count) { throw '生成的 release asset_name 存在重复。' }

        $manifest = [ordered]@{
            schema_version = 1
            package_kind = 'wirex_bridge_private_alpha_release_green_directory'
            package_status = 'awaiting_root_audit'
            version = $Version
            tag_candidate = $Version
            tag_created = $false
            github_release_published = $false
            source = [ordered]@{
                repository = 'https://github.com/iCassius/WIREX_Bridge.git'
                commit = $sourceCommit
                working_tree_clean = $true
            }
            build = [ordered]@{
                source_commit = $sourceCommit
                source_tree_clean = $buildEvidence.source_tree_clean
                compile_only = $buildEvidence.compile_only
                build_completed = $buildEvidence.build_completed
                output_directory = (Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath)
                evidence_log = (Get-RepoRelativePath -RepositoryRoot $repo -Path $logPath)
                evidence_log_sha256 = $buildEvidence.build_log_sha256
                provenance_asset = 'build-provenance.json'
                provenance_sha256 = $buildEvidence.build_provenance_sha256
                result = 'passed'
                passed_test_count = $buildEvidence.passed_test_count
                passed_tests = @($buildEvidence.passed_tests)
                compiler_warnings = $buildEvidence.compiler_warnings
                compiler_errors = $buildEvidence.compiler_errors
                executable_sha256 = $buildEvidence.executable_sha256
            }
            release_scope = $profile.ReleaseScope
            not_included = @($profile.NotIncluded)
            hardware_validation = [ordered]@{
                current_release_hil = 'not performed; final HIL remains pending'
                current_profile_and_volume_settings = 'not tested on hardware in this release source'
                previous_direct_parrot_echo = 'user confirmed clear echo on predecessor source 005c5e8 only'
                previous_tg91_listening = 'user confirmed normal listening on predecessor source ab3c5fa only'
                radio_state = 'unknown'
                rf_transmission = 'not tested'
            }
            approved_y_fixture = [ordered]@{
                path = 'private/device-y.bin'
                length_bytes = 100
                sha256 = $fixtureHash
            }
            excluded_private_files = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
            runtime_directories = @('logs/ (empty at package creation)')
            manifest_asset_name = 'manifest.json'
            files = @($records)
        }
        $manifestJson = ConvertTo-Json -InputObject $manifest -Depth 12
        [System.IO.File]::WriteAllText((Join-Path $stagingPath 'manifest.json'), $manifestJson + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Assert-ReleasePackageInventory -PackageRoot $stagingPath -Version $Version

        if (Test-Path -LiteralPath $outputPath) { throw "发布目录已出现，拒绝覆盖：$outputPath" }
        [System.IO.Directory]::Move($stagingPath, $outputPath)
        $createdOutput = $true
        Write-Host "绿色发布候选已创建：$outputPath"
        Write-Host "清单 asset 数：$($records.Count + 1)（含 manifest.json；未生成 ZIP）"
        Write-Host 'package_status=awaiting_root_audit'
    } catch {
        $originalFailure = $_
        if (-not $createdOutput -and (Test-Path -LiteralPath $stagingPath -PathType Container)) {
            $safeStagingPath = (Test-PathWithinDirectory -Path $stagingPath -Directory $releaseRoot) -and
                [System.IO.Path]::GetFileName($stagingPath).StartsWith(
                    '.staging-' + $Version + '-', [System.StringComparison]::Ordinal)
            if (-not $safeStagingPath) {
                throw "发布失败：$($originalFailure.Exception.Message)；未清理临时目录，因为路径安全校验失败：$stagingPath"
            }
            try {
                Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction Stop
            } catch {
                throw "发布失败：$($originalFailure.Exception.Message)；临时目录清理失败：$stagingPath；清理错误：$($_.Exception.Message)"
            }
            if (Test-Path -LiteralPath $stagingPath -PathType Container) {
                throw "发布失败：$($originalFailure.Exception.Message)；清理后临时目录仍存在：$stagingPath"
            }
        }
        throw $originalFailure
    }
}

function Get-RepoRelativePath {
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径不在源码仓库内：$fullPath"
    }
    return $fullPath.Substring($prefix.Length).Replace('\', '/')
}

if ($MyInvocation.InvocationName -ne '.') {
    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Invoke-ReleasePackaging -Version $Version -BuildDirectory $BuildDirectory -BuildLogPath $BuildLogPath `
        -YFixturePath $YFixturePath -RepositoryRoot $repositoryRoot
}
