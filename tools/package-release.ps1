[CmdletBinding()]
param(
    [string]$Version,
    [string]$BuildDirectory,
    [string]$BuildLogPath,
    [string]$YFixturePath,
    [string]$LauncherBuildDirectory
)

$ErrorActionPreference = 'Stop'
$script:stableReleaseContractPath = Join-Path $PSScriptRoot 'StableReleaseContract.psm1'
if (-not [System.IO.File]::Exists($script:stableReleaseContractPath)) { throw 'StableReleaseContract.psm1 is missing.' }
Import-Module -Name $script:stableReleaseContractPath -Force -Scope Global -ErrorAction Stop

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
$script:alpha15TestNames = @($script:alpha14TestNames)
$script:alpha16TestNames = @($script:alpha15TestNames)
$script:alpha17TestNames = @($script:alpha16TestNames)
$script:alpha18TestNames = @($script:alpha17TestNames)
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
        'v0.1.0-alpha.7' {
            $alpha6 = Get-ReleaseProfile -Version 'v0.1.0-alpha.6'
            $alpha7SourceFiles = @($alpha6.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Destination -cne 'start-merged-test.cmd' -and
                [string]$_.Destination -cne 'start-merged-test.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.7-package-README.md'; Destination='README.md' },
                @{ Source='docs\R109_下行状态与动态组修复.md'; Destination='docs\R109_下行状态与动态组修复.md' },
                @{ Source='docs\R109_动态组激活实现.md'; Destination='docs\R109_动态组激活实现.md' },
                @{ Source='tools\start-merged-test-alpha7.cmd'; Destination='start-merged-test.cmd' },
                @{ Source='tools\start-merged-test-alpha7.ps1'; Destination='start-merged-test.ps1' }
            )
            $alpha7AssetMap = [ordered]@{}
            foreach ($path in $alpha6.AssetMap.Keys) { $alpha7AssetMap[$path] = $alpha6.AssetMap[$path] }
            $alpha7AssetMap['docs/R109_下行状态与动态组修复.md'] = 'docs__r109-downlink-dynamic-groups.md'
            $alpha7AssetMap['docs/R109_动态组激活实现.md'] = 'docs__r109-dynamic-group-activation.md'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.7'
                TestNames = $script:alpha7TestNames
                SourceFiles = $alpha7SourceFiles
                PackageFiles = @($alpha6.PackageFiles) + @(
                    'docs/R109_下行状态与动态组修复.md', 'docs/R109_动态组激活实现.md'
                )
                Directories = @($alpha6.Directories)
                AssetMap = $alpha7AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.7-package-README.md'
                ReleaseScope = 'R109: dynamic talkgroup input with separate local-listen and one-shot dynamic-group activation controls; wait for accepted voice before HRI T3 and discard empty ended calls without starting HRI playback'
                NotIncluded = @(
                    'No alpha.7 hardware acceptance record for serial, audio, BrandMeister, PTT, or RF behavior',
                    'The red LED reported on this and the older local-hri-downlink-0304eff build is not fixed or explained by this slice',
                    'TG91 disconnect causes outside the documented empty-call case remain unconfirmed'
                )
            }
        }
        'v0.1.0-alpha.8' {
            $alpha7 = Get-ReleaseProfile -Version 'v0.1.0-alpha.7'
            $alpha8ExcludedPaths = @(
                'start-bm-radio-bridge.cmd', 'start-listen-91.cmd', 'start-profile.cmd',
                'start-ui.cmd', 'start-user-config.cmd', 'start-user-config.ps1',
                'start-step1-test.cmd', 'start-step1-test.ps1', 'test-control.cmd', 'test-control.ps1',
                'start-merged-test.cmd', 'start-merged-test.ps1'
            )
            $alpha8SourceFiles = @($alpha7.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                $alpha8ExcludedPaths -cnotcontains [string]$_.Destination
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.8-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha8.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha8.ps1'; Destination='tools\start-wirex-bridge.ps1' }
            )
            $alpha8PackageFiles = @($alpha7.PackageFiles | Where-Object {
                $alpha8ExcludedPaths -cnotcontains [string]$_
            }) + @('start-wirex-bridge.cmd', 'tools/start-wirex-bridge.ps1')
            $alpha8AssetMap = [ordered]@{}
            foreach ($path in $alpha7.AssetMap.Keys) {
                if ($alpha8ExcludedPaths -cnotcontains [string]$path) {
                    $alpha8AssetMap[$path] = $alpha7.AssetMap[$path]
                }
            }
            $alpha8AssetMap['start-wirex-bridge.cmd'] = 'start-wirex-bridge.cmd'
            $alpha8AssetMap['tools/start-wirex-bridge.ps1'] = 'tools__start-wirex-bridge.ps1'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.8'
                TestNames = $script:alpha8TestNames
                SourceFiles = $alpha8SourceFiles
                PackageFiles = $alpha8PackageFiles
                Directories = @($alpha7.Directories) + 'tools'
                AssetMap = $alpha8AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.8-package-README.md'
                ReleaseScope = 'R110: alpha.7 runtime with a single user-facing command prompt entry and Windows PowerShell 5.1 package parsing and isolated launcher verification'
                NotIncluded = @(
                    'No alpha.8 hardware acceptance record for serial, audio, BrandMeister, PTT, FTX-1 physical BUSY/TX LED, or RF behavior',
                    'The FTX-1 physical BUSY/TX LED reported on this and the older local-hri-downlink-0304eff build is not fixed or explained by this slice',
                    'TG91 disconnect causes outside the documented empty-call case remain unconfirmed'
                )
            }
        }
        'v0.1.0-alpha.9' {
            $alpha8 = Get-ReleaseProfile -Version 'v0.1.0-alpha.8'
            $alpha9SourceFiles = @($alpha8.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha8.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha8.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.9-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha9.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha9.ps1'; Destination='tools\start-wirex-bridge.ps1' },
                @{ Source='ui\windows\RadioIdentity.psm1'; Destination='ui\windows\RadioIdentity.psm1' },
                @{ Source='docs\R111_UI与音量.md'; Destination='docs\R111_UI与音量.md' },
                @{ Source='docs\R111_BM订阅与收听优先级.md'; Destination='docs\R111_BM订阅与收听优先级.md' },
                @{ Source='docs\R111_用户资料与电台显示.md'; Destination='docs\R111_用户资料与电台显示.md' }
            )
            $alpha9PackageFiles = @($alpha8.PackageFiles) + @(
                'ui/windows/RadioIdentity.psm1',
                'docs/R111_UI与音量.md',
                'docs/R111_BM订阅与收听优先级.md',
                'docs/R111_用户资料与电台显示.md'
            )
            $alpha9AssetMap = [ordered]@{}
            foreach ($path in $alpha8.AssetMap.Keys) { $alpha9AssetMap[$path] = $alpha8.AssetMap[$path] }
            $alpha9AssetMap['ui/windows/RadioIdentity.psm1'] = 'ui__windows__radio-identity.psm1'
            $alpha9AssetMap['docs/R111_UI与音量.md'] = 'docs__r111-ui-audio.md'
            $alpha9AssetMap['docs/R111_BM订阅与收听优先级.md'] = 'docs__r111-bm-listening-policy.md'
            $alpha9AssetMap['docs/R111_用户资料与电台显示.md'] = 'docs__r111-radio-identity-display.md'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.9'
                TestNames = $script:alpha9TestNames
                SourceFiles = $alpha9SourceFiles
                PackageFiles = $alpha9PackageFiles
                Directories = @($alpha8.Directories)
                AssetMap = $alpha9AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.9-package-README.md'
                ReleaseScope = 'R111 DIRECT: separate local listening selection from call target selection; preserve real recent-call history, per-route DMR timeslots, transmit Color Code, explicit single-ID RadioID lookup with local cache, and user-visible volume controls'
                NotIncluded = @(
                    'No alpha.9 hardware acceptance for COM, audio, BrandMeister, PTT, LCD display, physical BUSY/TX LED, or RF behavior',
                    'The FTX-1 LCD display remains unknown; the located Src CallSign field is not a verified radio-screen result',
                    'bm_session.Profile.slot_flags defaults to 4 (simplex); software TS1/TS2 route fields do not establish FTX-1 dual-slot DMR RF or simultaneous two-slot playback',
                    'The FTX-1 physical BUSY/TX LED behavior is unchanged; this release does not repair or explain the earlier observation',
                    'Color Code is a DMR transmit encoding/reporting parameter, not C4FM DG-ID; receive route filters do not compare Color Code',
                    'Quick Call can appear as an empty call in the BrandMeister Dashboard; no silent dynamic-group API is claimed',
                    'No BrandMeister static-subscription readback is integrated; the UI does not label local RX allow_groups as server static bindings',
                    'Multiple local routes do not create playback priority or automatic interruption of an active call'
                )
            }
        }
        'v0.1.0-alpha.10' {
            $alpha9 = Get-ReleaseProfile -Version 'v0.1.0-alpha.9'
            $alpha10R111Paths = @(
                'docs/R111_UI与音量.md',
                'docs/R111_BM订阅与收听优先级.md',
                'docs/R111_用户资料与电台显示.md'
            )
            $alpha10SourceFiles = @($alpha9.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha9.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha9.ps1' -and
                $alpha10R111Paths -cnotcontains ([string]$_.Destination).Replace('\', '/')
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.10-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha10.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha10.ps1'; Destination='tools/start-wirex-bridge.ps1' },
                @{ Source='docs\R112_A_身份查询实施.md'; Destination='docs\R112_A_身份查询实施.md' },
                @{ Source='docs\R112_A_网络音频指标.md'; Destination='docs\R112_A_网络音频指标.md' },
                @{ Source='docs\R112_A_UI精简.md'; Destination='docs\R112_A_UI精简.md' }
            )
            $alpha10PackageFiles = @($alpha9.PackageFiles | Where-Object { $alpha10R111Paths -cnotcontains ([string]$_).Replace('\', '/') }) + @(
                'docs/R112_A_身份查询实施.md',
                'docs/R112_A_网络音频指标.md',
                'docs/R112_A_UI精简.md'
            )
            $alpha10AssetMap = [ordered]@{}
            foreach ($path in $alpha9.AssetMap.Keys) {
                if ($alpha10R111Paths -cnotcontains ([string]$path)) { $alpha10AssetMap[$path] = $alpha9.AssetMap[$path] }
            }
            $alpha10AssetMap['docs/R112_A_身份查询实施.md'] = 'docs__r112-a-identity-lookup.md'
            $alpha10AssetMap['docs/R112_A_网络音频指标.md'] = 'docs__r112-a-network-audio-metrics.md'
            $alpha10AssetMap['docs/R112_A_UI精简.md'] = 'docs__r112-a-ui-compact.md'
            $alpha10NotIncluded = @($alpha9.NotIncluded | ForEach-Object { ([string]$_).Replace('alpha.9', 'alpha.10') })
            $alpha10NotIncluded += @(
                'BM RTT is a client-measured round-trip estimate; it does not report one-way delay or server CPU load',
                'DMRD loss is inferred only between accepted sequence numbers; filtered, busy, and post-watchdog traffic is not counted as lost packets',
                'The new metrics do not change DSP, audio scheduling, or the established voice path',
                'FTX-1 LCD source-identity display is not implemented',
                'FM and C4FM RF transmit paths are not implemented'
            )
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.10'
                TestNames = $script:alpha10TestNames
                SourceFiles = $alpha10SourceFiles
                PackageFiles = $alpha10PackageFiles
                Directories = @($alpha9.Directories)
                AssetMap = $alpha10AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.10-package-README.md'
                ReleaseScope = 'R112 A: query one incoming DMR ID in the background and display measured BM round-trip, accepted DMRD sequence-loss, receive-queue, and existing PCM clipping data'
                NotIncluded = $alpha10NotIncluded
            }
        }
        'v0.1.0-alpha.11' {
            $alpha10 = Get-ReleaseProfile -Version 'v0.1.0-alpha.10'
            $alpha11R112Paths = @(
                'docs/R112_A_身份查询实施.md',
                'docs/R112_A_UI精简.md'
            )
            $alpha11SourceFiles = @($alpha10.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha10.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha10.ps1' -and
                $alpha11R112Paths -cnotcontains ([string]$_.Destination).Replace('\', '/')
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.11-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha11.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha11.ps1'; Destination='tools/start-wirex-bridge.ps1' },
                @{ Source='docs\R113_LCD核心实现.md'; Destination='docs\R113_LCD核心实现.md' },
                @{ Source='docs\R113_身份与LCD接线.md'; Destination='docs\R113_身份与LCD接线.md' }
            )
            $alpha11PackageFiles = @($alpha10.PackageFiles | Where-Object {
                $alpha11R112Paths -cnotcontains ([string]$_).Replace('\', '/')
            }) + @(
                'docs/R113_LCD核心实现.md',
                'docs/R113_身份与LCD接线.md'
            )
            $alpha11AssetMap = [ordered]@{}
            foreach ($path in $alpha10.AssetMap.Keys) {
                if ($alpha11R112Paths -cnotcontains ([string]$path)) { $alpha11AssetMap[$path] = $alpha10.AssetMap[$path] }
            }
            $alpha11AssetMap['docs/R113_LCD核心实现.md'] = 'docs__r113-lcd-core-implementation.md'
            $alpha11AssetMap['docs/R113_身份与LCD接线.md'] = 'docs__r113-identity-lcd-integration.md'
            $alpha11NotIncluded = @($alpha10.NotIncluded | Where-Object {
                [string]$_ -cne 'FTX-1 LCD source-identity display is not implemented' -and
                [string]$_ -cne 'FM and C4FM RF transmit paths are not implemented' -and
                [string]$_ -cne 'The FTX-1 LCD display remains unknown; the located Src CallSign field is not a verified radio-screen result'
            } | ForEach-Object { ([string]$_).Replace('alpha.10', 'alpha.11') })
            $alpha11NotIncluded += @(
                'The FTX-1 LCD display result remains unknown pending direct visual confirmation; mode-4 LCD semantics are unverified',
                'Only a later callStart can use the cached callsign in the existing mode-4 T90 SrcCallSign field; active calls receive no second T record or hot update',
                'FM and C4FM RF transmit paths are not implemented'
            )
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.11'
                TestNames = $script:alpha11TestNames
                SourceFiles = $alpha11SourceFiles
                PackageFiles = $alpha11PackageFiles
                Directories = @($alpha10.Directories)
                AssetMap = $alpha11AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.11-package-README.md'
                ReleaseScope = 'R113 DIRECT: asynchronously transfer fresh RadioID mappings into the bounded Native identity cache and use a cached callsign only in the existing mode-4 T90 SrcCallSign field for later callStart records'
                NotIncluded = $alpha11NotIncluded
            }
        }
        'v0.1.0-alpha.12' {
            $alpha11 = Get-ReleaseProfile -Version 'v0.1.0-alpha.11'
            $alpha12SourceFiles = @($alpha11.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha11.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha11.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.12-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha12.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha12.ps1'; Destination='tools/start-wirex-bridge.ps1' },
                @{ Source='ui\windows\RadioCat.psm1'; Destination='ui\windows\RadioCat.psm1' },
                @{ Source='docs\R116_CAT能力与控制实现.md'; Destination='docs\R116_CAT能力与控制实现.md' },
                @{ Source='docs\R116_电台控制界面.md'; Destination='docs\R116_电台控制界面.md' }
            )
            $alpha12PackageFiles = @($alpha11.PackageFiles) + @(
                'ui/windows/RadioCat.psm1',
                'docs/R116_CAT能力与控制实现.md',
                'docs/R116_电台控制界面.md'
            )
            $alpha12AssetMap = [ordered]@{}
            foreach ($path in $alpha11.AssetMap.Keys) { $alpha12AssetMap[$path] = $alpha11.AssetMap[$path] }
            $alpha12AssetMap['ui/windows/RadioCat.psm1'] = 'ui__windows__radio-cat.psm1'
            $alpha12AssetMap['docs/R116_CAT能力与控制实现.md'] = 'docs__r116-cat-controls.md'
            $alpha12AssetMap['docs/R116_电台控制界面.md'] = 'docs__r116-radio-controls-ui.md'
            $alpha12NotIncluded = @($alpha11.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.11', 'alpha.12')
            })
            $alpha12NotIncluded += @(
                'HRI MODE and Node Mode cannot be switched by a documented CAT command; no guessed EX address is exposed',
                'The FTX-1 LCD remains experimental and is not an alpha.12 product feature; no incoming-call or list contents were observed in the documented DIRECT/HRI checks'
            )
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.12'
                TestNames = $script:alpha12TestNames
                SourceFiles = $alpha12SourceFiles
                PackageFiles = $alpha12PackageFiles
                Directories = @($alpha11.Directories)
                AssetMap = $alpha12AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.12-package-README.md'
                ReleaseScope = 'R116 DIRECT: user-triggered CAT queries and readback-checked MAIN frequency, radio mode, and PC power-control settings using documented FTX-1 CAT commands'
                NotIncluded = $alpha12NotIncluded
            }
        }
        'v0.1.0-alpha.13' {
            $alpha12 = Get-ReleaseProfile -Version 'v0.1.0-alpha.12'
            $alpha13SourceFiles = @($alpha12.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha12.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha12.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.13-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha13.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha13.ps1'; Destination='tools/start-wirex-bridge.ps1' },
                @{ Source='ui\windows\RadioCatUi.ps1'; Destination='ui\windows\RadioCatUi.ps1' },
                @{ Source='ui\windows\RadioDevices.psm1'; Destination='ui\windows\RadioDevices.psm1' },
                @{ Source='ui\windows\BmServers.psm1'; Destination='ui\windows\BmServers.psm1' },
                @{ Source='ui\windows\BmManagement.psm1'; Destination='ui\windows\BmManagement.psm1' },
                @{ Source='ui\windows\BmManagementUi.ps1'; Destination='ui\windows\BmManagementUi.ps1' }
            )
            $alpha13PackageFiles = @($alpha12.PackageFiles) + @(
                'ui/windows/RadioCatUi.ps1',
                'ui/windows/RadioDevices.psm1',
                'ui/windows/BmServers.psm1',
                'ui/windows/BmManagement.psm1',
                'ui/windows/BmManagementUi.ps1'
            )
            $alpha13AssetMap = [ordered]@{}
            foreach ($path in $alpha12.AssetMap.Keys) { $alpha13AssetMap[$path] = $alpha12.AssetMap[$path] }
            $alpha13AssetMap['ui/windows/RadioCatUi.ps1'] = 'ui__windows__radio-cat-ui.ps1'
            $alpha13AssetMap['ui/windows/RadioDevices.psm1'] = 'ui__windows__radio-devices.psm1'
            $alpha13AssetMap['ui/windows/BmServers.psm1'] = 'ui__windows__bm-servers.psm1'
            $alpha13AssetMap['ui/windows/BmManagement.psm1'] = 'ui__windows__bm-management.psm1'
            $alpha13AssetMap['ui/windows/BmManagementUi.ps1'] = 'ui__windows__bm-management-ui.ps1'
            $alpha13NotIncluded = @($alpha12.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.12', 'alpha.13')
            })
            $alpha13NotIncluded += 'BM API keys and per-user configuration remain outside the generic release package'
            $alpha13NotIncluded += '本机服务器选择偏好 private/user-config/bm-server-preferences.json 不随通用发行包分发'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.13'
                TestNames = $script:alpha13TestNames
                SourceFiles = $alpha13SourceFiles
                PackageFiles = $alpha13PackageFiles
                Directories = @($alpha12.Directories)
                AssetMap = $alpha13AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.13-package-README.md'
                ReleaseScope = 'R117 DIRECT: offline BM master selection, independent radio port discovery and CAT UI synchronization, plus user-triggered BM static talkgroup management'
                NotIncluded = $alpha13NotIncluded
            }
        }
        'v0.1.0-alpha.14' {
            $alpha13 = Get-ReleaseProfile -Version 'v0.1.0-alpha.13'
            $alpha14SourceFiles = @($alpha13.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha13.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha13.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.14-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha14.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha14.ps1'; Destination='tools/start-wirex-bridge.ps1' },
                @{ Source='ui\windows\PortableConfig.psm1'; Destination='ui\windows\PortableConfig.psm1' }
            )
            $alpha14AssetMap = [ordered]@{}
            foreach ($path in $alpha13.AssetMap.Keys) { $alpha14AssetMap[$path] = $alpha13.AssetMap[$path] }
            $alpha14AssetMap['ui/windows/PortableConfig.psm1'] = 'ui__windows__portable-config.psm1'
            $alpha14NotIncluded = @($alpha13.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.13', 'alpha.14')
            })
            $alpha14NotIncluded += 'Generic package does not contain the user-created package-root config.json, its backups, or credentials.'
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.14'
                TestNames = $script:alpha14TestNames
                SourceFiles = $alpha14SourceFiles
                PackageFiles = @($alpha13.PackageFiles) + 'ui/windows/PortableConfig.psm1'
                Directories = @($alpha13.Directories)
                AssetMap = $alpha14AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.14-package-README.md'
                ReleaseScope = 'R118 DIRECT: portable package-root settings, in-window radio credentials, device/audio preferences, and user-managed listen/PTT channel configuration'
                NotIncluded = $alpha14NotIncluded
            }
        }
        'v0.1.0-alpha.15' {
            $alpha14 = Get-ReleaseProfile -Version 'v0.1.0-alpha.14'
            $alpha15SourceFiles = @($alpha14.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha14.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha14.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.15-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha15.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha15.ps1'; Destination='tools/start-wirex-bridge.ps1' }
            )
            $alpha15NotIncluded = @($alpha14.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.14', 'alpha.15')
            })
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.15'
                TestNames = $script:alpha15TestNames
                SourceFiles = $alpha15SourceFiles
                PackageFiles = @($alpha14.PackageFiles)
                Directories = @($alpha14.Directories)
                AssetMap = $alpha14.AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.15-package-README.md'
                ReleaseScope = 'R119 DIRECT: CAT polling stability and runtime audio gain control with alpha.14 package-root configuration compatibility'
                NotIncluded = $alpha15NotIncluded
            }
        }
        'v0.1.0-alpha.16' {
            $alpha15 = Get-ReleaseProfile -Version 'v0.1.0-alpha.15'
            $alpha16SourceFiles = @($alpha15.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha15.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha15.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.16-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha16.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha16.ps1'; Destination='tools/start-wirex-bridge.ps1' }
            )
            $alpha16NotIncluded = @($alpha15.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.15', 'alpha.16')
            })
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.16'
                TestNames = $script:alpha16TestNames
                SourceFiles = $alpha16SourceFiles
                PackageFiles = @($alpha15.PackageFiles)
                Directories = @($alpha15.Directories)
                AssetMap = $alpha15.AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.16-package-README.md'
                ReleaseScope = 'R120 DIRECT: refreshed BrandMeister static talkgroup list and device-status-driven add slot selection, inheriting alpha.15 runtime assets and Native test sequence'
                NotIncluded = $alpha16NotIncluded
            }
        }
        'v0.1.0-alpha.17' {
            $alpha16 = Get-ReleaseProfile -Version 'v0.1.0-alpha.16'
            $alpha17SourceFiles = @($alpha16.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha16.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha16.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.17-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha17.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha17.ps1'; Destination='tools/start-wirex-bridge.ps1' }
            )
            $alpha17NotIncluded = @($alpha16.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.16', 'alpha.17')
            })
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.17'
                TestNames = $script:alpha17TestNames
                SourceFiles = $alpha17SourceFiles
                PackageFiles = @($alpha16.PackageFiles)
                Directories = @($alpha16.Directories)
                AssetMap = $alpha16.AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.17-package-README.md'
                ReleaseScope = 'R121 DIRECT: fixed no-scroll console layout and independent serial/BM connection controls, inheriting alpha.16 runtime assets and Native test sequence'
                NotIncluded = $alpha17NotIncluded
            }
        }
        'v0.1.0-alpha.18' {
            $alpha17 = Get-ReleaseProfile -Version 'v0.1.0-alpha.17'
            $alpha18SourceFiles = @($alpha17.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha17.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha17.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.18-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha18.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha18.ps1'; Destination='tools/start-wirex-bridge.ps1' }
            )
            $alpha18NotIncluded = @($alpha17.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.17', 'alpha.18')
            })
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.18'
                TestNames = $script:alpha18TestNames
                SourceFiles = $alpha18SourceFiles
                PackageFiles = @($alpha17.PackageFiles)
                Directories = @($alpha17.Directories)
                AssetMap = $alpha17.AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.18-package-README.md'
                ReleaseScope = 'R122 DIRECT: 50:50 fixed console layout, consolidated CAT settings, DMR device number and relocated audio controls; inherit alpha.17 runtime assets and Native test sequence'
                NotIncluded = $alpha18NotIncluded
            }
        }
        'v0.1.0-alpha.19' {
            $alpha18 = Get-ReleaseProfile -Version 'v0.1.0-alpha.18'
            $alpha19SourceFiles = @($alpha18.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha18.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha18.ps1'
            }) + @(
                @{ Source='docs\releases\v0.1.0-alpha.19-package-README.md'; Destination='README.md' },
                @{ Source='tools\start-wirex-bridge-alpha19.cmd'; Destination='start-wirex-bridge.cmd' },
                @{ Source='tools\start-wirex-bridge-alpha19.ps1'; Destination='tools/start-wirex-bridge.ps1' }
            )
            $alpha19NotIncluded = @($alpha18.NotIncluded | ForEach-Object {
                ([string]$_).Replace('alpha.18', 'alpha.19')
            })
            return [pscustomobject]@{
                Version = 'v0.1.0-alpha.19'
                TestNames = $script:alpha18TestNames
                SourceFiles = $alpha19SourceFiles
                PackageFiles = @($alpha18.PackageFiles)
                Directories = @($alpha18.Directories)
                AssetMap = $alpha18.AssetMap
                PackageReadme = 'docs\releases\v0.1.0-alpha.19-package-README.md'
                ReleaseScope = 'R123 DIRECT: fixed WPF console layout, one-line status and transient events, equal-height connection rows, and refreshed channel/history presentation; inherit alpha.18 runtime asset inventory and Native test sequence'
                NotIncluded = $alpha19NotIncluded
            }
        }
        'v0.1.0' {
            $alpha19 = Get-ReleaseProfile -Version 'v0.1.0-alpha.19'
            $excludedPackageFiles = @(
                'wirex_bridge.exe', 'build-provenance.json', 'README.md', 'SOURCE.txt', 'manifest.json',
                'private/device-y.bin', 'start-wirex-bridge.cmd', 'tools/start-wirex-bridge.ps1'
            )
            $runtimePackageFiles = @($alpha19.PackageFiles | Where-Object {
                $excludedPackageFiles -cnotcontains [string]$_
            } | ForEach-Object { 'runtime/' + [string]$_ })
            $runtimePackageFiles += 'runtime/wirex_bridge.exe'
            $runtimePackageFiles += 'runtime/private/device-y.bin'
            $runtimePackageFiles += 'runtime/ui/windows/ChannelActivationState.psm1'
            $sourceFiles = @($alpha19.SourceFiles | Where-Object {
                [string]$_.Destination -cne 'README.md' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha19.cmd' -and
                [string]$_.Source -cne 'tools\start-wirex-bridge-alpha19.ps1'
            } | ForEach-Object {
                [pscustomobject]@{ Source=[string]$_.Source; Destination=('runtime/' + ([string]$_.Destination).Replace('\','/')) }
            })
            $sourceFiles += [pscustomobject]@{
                Source='docs\releases\v0.1.0-package-README.md'; Destination='README.md'
            }
            $sourceFiles += [pscustomobject]@{
                Source='ui\windows\ChannelActivationState.psm1'; Destination='runtime/ui/windows/ChannelActivationState.psm1'
            }
            $runtimeDirectories = @($alpha19.Directories | Where-Object {
                [string]$_ -cne 'logs' -and [string]$_ -cne 'tools'
            } | ForEach-Object { 'runtime/' + [string]$_ })
            $assetMap = [ordered]@{
                'WirexBridge.exe'='WirexBridge.exe'
                'build-provenance.json'='build-provenance.json'
                'launcher-build-provenance.json'='launcher-build-provenance.json'
                'README.md'='README.md'
                'SOURCE.txt'='SOURCE.txt'
                'runtime/wirex_bridge.exe'='runtime__wirex_bridge.exe'
                'runtime/private/device-y.bin'='runtime__private__device-y.bin'
                'runtime/ui/windows/ChannelActivationState.psm1'='runtime__ui__windows__channel-activation-state.psm1'
            }
            foreach ($sourcePath in $alpha19.AssetMap.Keys) {
                if ($excludedPackageFiles -ccontains [string]$sourcePath) { continue }
                $runtimePath = 'runtime/' + [string]$sourcePath
                $assetMap[$runtimePath] = 'runtime__' + [string]$alpha19.AssetMap[$sourcePath]
            }
            return [pscustomobject]@{
                Version = 'v0.1.0'
                TestNames = $alpha19.TestNames
                SourceFiles = $sourceFiles
                PackageFiles = @('WirexBridge.exe','build-provenance.json','launcher-build-provenance.json',
                    'README.md','SOURCE.txt','manifest.json','runtime/wirex_bridge.exe') +
                    @($runtimePackageFiles | Where-Object { $_ -cne 'runtime/wirex_bridge.exe' })
                Directories = @('runtime') + $runtimeDirectories
                AssetMap = $assetMap
                PackageReadme = 'docs\releases\v0.1.0-package-README.md'
                ReleaseScope = 'R124: stable v0.1.0 portable folder with one EXE launch entry, shared portable config initialization, and the R123 WPF runtime in runtime/'
                NotIncluded = @($alpha19.NotIncluded + 'user callsign, password, BM API key, current-release device/HRI/audio/PTT/RF acceptance')
            }
        }
        default { throw 'Only v0.1.0 and v0.1.0-alpha.1 through v0.1.0-alpha.19 release profiles are supported.' }
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

function Test-ReleaseLauncherBuildEvidence {
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [Parameter(Mandatory=$true)][string]$SourceCommit,
        [Parameter(Mandatory=$true)][string]$BuildDirectory
    )
    $repo = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $workRoot = [System.IO.Path]::GetFullPath((Join-Path $repo 'build\_work'))
    $build = [System.IO.Path]::GetFullPath($BuildDirectory)
    if (-not (Test-PathWithinDirectory -Path $build -Directory $workRoot) -or
        -not (Test-Path -LiteralPath $build -PathType Container)) {
        throw 'Launcher 构建目录必须是仓库 build\_work 下的现存目录。'
    }
    $executablePath = Join-Path $build 'WirexBridge.exe'
    $provenancePath = Join-Path $build 'launcher-build-provenance.json'
    $logPath = Join-Path $build 'launcher-build.log'
    foreach ($requiredPath in @($executablePath, $provenancePath, $logPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw 'Launcher 构建目录缺少 EXE、provenance 或编译日志。' }
    }
    try {
        $provenance = [System.IO.File]::ReadAllText($provenancePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { throw 'launcher-build-provenance.json 无法解析。' }
    if ([int]$provenance.schema_version -ne 1 -or [string]$provenance.result -cne 'passed') {
        throw 'Launcher provenance 未记录成功的本机编译。'
    }
    if ([string]$provenance.source.path -cne 'ui/launcher/WirexBridgeLauncher.cs' -or
        [string]$provenance.source.commit -cne $SourceCommit -or
        [string]$provenance.compiler.family -cne 'Microsoft .NET Framework csc.exe' -or
        [string]$provenance.compiler.command -cne 'csc.exe /nologo /target:winexe /platform:x64 /optimize+ /debug- /codepage:65001' -or
        [string]$provenance.compiler.target -cne 'x64 Windows GUI executable' -or
        [string]$provenance.output.path -cne 'WirexBridge.exe') {
        throw 'Launcher provenance 的源码、编译器或输出类型不符合固定合同。'
    }
    $sourcePath = Join-Path $repo 'ui\launcher\WirexBridgeLauncher.cs'
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$provenance.source.sha256 -cne $sourceHash) {
        throw 'Launcher provenance 的源码 SHA-256 与当前发行源码不一致。'
    }
    $buildRelative = Get-RepoRelativePath -RepositoryRoot $repo -Path $build
    if ([string]$provenance.output.directory -cne $buildRelative) {
        throw 'Launcher provenance 的输出目录与给定 build 目录不一致。'
    }
    $executable = Get-Item -LiteralPath $executablePath -ErrorAction Stop
    $executableHash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([long]$provenance.output.length_bytes -ne [long]$executable.Length -or
        [string]$provenance.output.sha256 -cne $executableHash) {
        throw 'Launcher EXE 长度或 SHA-256 与 provenance 不一致。'
    }
    if ([string]$provenance.build_log.path -cne ($buildRelative + '/launcher-build.log') -or
        [string]$provenance.build_log.sha256 -cne (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Launcher build log 与 provenance 不一致。'
    }
    $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8)
    if ($logText -match '(?im)\bwarning\s+CS[0-9]+|\berror\s+CS[0-9]+') { throw 'Launcher 编译日志包含 warning 或 error。' }
    return [pscustomobject]@{
        build_directory = $build
        executable = $executablePath
        executable_length_bytes = [long]$executable.Length
        executable_sha256 = $executableHash
        provenance = $provenancePath
        provenance_sha256 = (Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        source_path = [string]$provenance.source.path
        source_sha256 = $sourceHash
        compiler_family = [string]$provenance.compiler.family
        compiler_version = [string]$provenance.compiler.version
        target = [string]$provenance.compiler.target
        build_log = $logPath
        build_log_sha256 = (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-ReleaseSourceFiles {
    return (Get-ReleaseProfile -Version $script:activeReleaseVersion).SourceFiles
}

function Get-ExpectedReleasePackageFiles {
    return (Get-ReleaseProfile -Version $script:activeReleaseVersion).PackageFiles
}

function Get-ReleaseExcludedPrivateFiles {
    param([Parameter(Mandatory=$true)][string]$Version)
    $excluded = @('private/bm-device-password.txt', 'connection-profile.json', 'audio-settings.json')
    if ($Version -ceq 'v0.1.0') {
        return @(
            'config.json', 'config.*.backup*', 'credentials/', 'tempSecrets/', 'logs/',
            'runtime/config.json', 'runtime/config.*.backup*', 'runtime/credentials/', 'runtime/tempSecrets/', 'runtime/logs/',
            'private/user-config-directory.txt', 'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json', 'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json', 'private/user-config/bm-management-preferences.json',
            'private/user-config/bm-server-preferences.json', 'runtime/private/user-config-directory.txt',
            'runtime/private/user-config/', 'runtime/private/credentials/', 'runtime/private/tempSecrets/',
            'callsign', 'password', 'api_key'
        )
    }
    if ($Version -ceq 'v0.1.0-alpha.9') {
        $excluded += @(
            'private/user-config-directory.txt',
            'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json'
        )
    }
    if ($Version -ceq 'v0.1.0-alpha.10') {
        $excluded += @(
            'private/user-config-directory.txt',
            'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json',
            'private/user-config/password-file-path.txt'
        )
    }
    if ($Version -ceq 'v0.1.0-alpha.11') {
        $excluded += @(
            'private/user-config-directory.txt',
            'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json',
            'private/user-config/password-file-path.txt'
        )
    }
    if ($Version -ceq 'v0.1.0-alpha.12') {
        $excluded += @(
            'private/user-config-directory.txt',
            'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json',
            'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json'
        )
    }
    if ($Version -ceq 'v0.1.0-alpha.13') {
        $excluded += @(
            'private/user-config-directory.txt',
            'private/user-config/radio-identity-cache.json',
            'private/user-config/channel-favorites.json',
            'private/user-config/password-file-path.txt',
            'private/user-config/radio-control-preferences.json',
            'private/user-config/bm-management-preferences.json',
            'private/user-config/bm-server-preferences.json'
        )
    }
if ($Version -cin @('v0.1.0-alpha.14', 'v0.1.0-alpha.15', 'v0.1.0-alpha.16', 'v0.1.0-alpha.17', 'v0.1.0-alpha.18', 'v0.1.0-alpha.19')) {
        $excluded += @(
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
        )
    }
    return @($excluded)
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

function Assert-ReleaseArchivePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or
        $Path.StartsWith('/') -or $Path -match '(^|/)\.{1,2}(/|$)' -or $Path.EndsWith('/')) {
        throw 'ZIP entry path is not a safe relative file path.'
    }
}

function Test-ReleaseArchiveMatchesPackage {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [Parameter(Mandatory=$true)][string]$ArchivePath,
        [string]$Version = 'v0.1.0')
    $profile = Get-ReleaseProfile -Version $Version
    if ($Version -cne 'v0.1.0') { throw 'The archive verifier only supports the stable v0.1.0 package.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $package = [System.IO.Path]::GetFullPath($PackageRoot)
    $expectedPaths = @(@($profile.PackageFiles | Where-Object { $_ -cne 'manifest.json' }) + 'manifest.json')
    $canonicalPathMap = New-WirexStableCanonicalPathMap -Paths $expectedPaths
    $limits = Get-WirexStableReleaseLimits
    $records = @{}
    $manifest = [System.IO.File]::ReadAllText((Join-Path $package 'manifest.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    foreach ($record in @($manifest.files)) { $records[[string]$record.path] = $record }
    $manifestBytes = [System.IO.File]::ReadAllBytes((Join-Path $package 'manifest.json'))
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $package 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $archiveItem = Get-Item -LiteralPath $ArchivePath -ErrorAction Stop
    if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$archiveItem.Length) -MaximumBytes ([long]$limits.MaximumArchiveBytes))) {
        throw 'ZIP archive exceeds the fixed 512 MiB download limit.'
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -ne $canonicalPathMap.Count) { throw 'ZIP file count does not match the audited folder package.' }
        $totalLength = [long]0
        foreach ($entry in $archive.Entries) {
            $path = [string]$entry.FullName
            Assert-ReleaseArchivePath -Path $path
            $canonicalPath = Resolve-WirexStableCanonicalPath -Path $path -CanonicalPathMap $canonicalPathMap
            if (-not $seen.Add($canonicalPath)) {
                throw 'ZIP contains an unexpected or case-insensitive duplicate entry.'
            }
            if (-not (Test-WirexStableRegularZipEntry -ExternalAttributes ([int]$entry.ExternalAttributes) -Length ([long]$entry.Length))) {
                throw 'ZIP contains a non-regular file entry.'
            }
            $targetPath = Join-Path $package $canonicalPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $expectedLength = [long]0
            $expectedHash = ''
            if ($canonicalPath -ceq 'manifest.json') {
                $expectedLength = [long]$manifestBytes.Length
                $expectedHash = $manifestHash
            } else {
                if (-not $records.ContainsKey($canonicalPath)) { throw 'ZIP entry has no manifest file record.' }
                $expectedLength = [long]$records[$canonicalPath].length_bytes
                $expectedHash = [string]$records[$canonicalPath].sha256
            }
            $maximumFileBytes = [long](Get-WirexStableMaximumFileBytes -Path $canonicalPath)
            if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$entry.Length) -MaximumBytes $maximumFileBytes)) {
                throw "ZIP entry exceeds its fixed per-file download limit: $canonicalPath"
            }
            if ([long]$entry.Length -ne $expectedLength) { throw 'ZIP entry length does not match the package manifest.' }
            $totalLength += [long]$entry.Length
            if (-not (Test-WirexStableLengthWithinLimit -Length $totalLength -MaximumBytes ([long]$limits.MaximumUncompressedBytes))) {
                throw 'ZIP contents exceed the fixed 2 GiB package limit.'
            }
            $entryStream = $entry.Open()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $fileStream = $null
            try {
                $fileStream = [System.IO.File]::OpenRead($targetPath)
                $buffer = New-Object byte[] 65536
                $position = [long]0
                while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $position += $read
                    if ($position -gt $expectedLength) { throw 'ZIP entry exceeded its manifest length.' }
                    [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
                }
                [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
                $zipHash = [System.BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant()
                if ($zipHash -cne $expectedHash) { throw 'ZIP entry SHA-256 does not match the package manifest.' }
                $bufferHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($bufferHash -cne $zipHash) { throw 'ZIP bytes do not match the audited folder file.' }
            } finally {
                if ($null -ne $fileStream) { $fileStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
                $sha.Dispose()
            }
        }
        if ($seen.Count -ne $canonicalPathMap.Count) { throw 'ZIP is missing one or more audited package files.' }
        return [pscustomobject]@{ EntryCount=$seen.Count; TotalLengthBytes=$totalLength; ManifestSha256=$manifestHash }
    } finally { $archive.Dispose() }
}

function New-StableReleaseDistribution {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [string]$DistributionDirectory)
    $package = [System.IO.Path]::GetFullPath($PackageRoot)
    $repo = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($DistributionDirectory)) {
        $DistributionDirectory = Join-Path $repo 'build\_work\r124-distribution\v0.1.0'
    }
    $finalDirectory = [System.IO.Path]::GetFullPath($DistributionDirectory)
    $workRoot = [System.IO.Path]::GetFullPath((Join-Path $repo 'build\_work'))
    if (-not (Test-PathWithinDirectory -Path $finalDirectory -Directory $workRoot)) {
        throw 'Stable ZIP and checksum outputs must stay under build/_work.'
    }
    if (Test-Path -LiteralPath $finalDirectory) { throw 'Stable ZIP output directory already exists; the archive will not be overwritten.' }
    [void](Assert-ReleasePackageInventory -PackageRoot $package -Version 'v0.1.0')
    $limits = Get-WirexStableReleaseLimits
    $uncompressedLength = [long]0
    foreach ($relativePath in (Get-ReleaseProfile -Version 'v0.1.0').PackageFiles) {
        $sourcePath = Join-Path $package ([string]$relativePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $sourceInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        $maximumFileBytes = [long](Get-WirexStableMaximumFileBytes -Path ([string]$relativePath))
        if (-not (Test-WirexStableLengthWithinLimit -Length ([long]$sourceInfo.Length) -MaximumBytes $maximumFileBytes)) {
            throw "Stable package file exceeds its fixed download limit: $relativePath"
        }
        $uncompressedLength += [long]$sourceInfo.Length
        if (-not (Test-WirexStableLengthWithinLimit -Length $uncompressedLength -MaximumBytes ([long]$limits.MaximumUncompressedBytes))) {
            throw 'Stable package exceeds the fixed 2 GiB download limit.'
        }
    }
    $parent = Split-Path -Parent $finalDirectory
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $stage = Join-Path $parent ('.staging-v0.1.0-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $stage) { throw 'Stable ZIP staging path already exists.' }
    [System.IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zipName = 'WIREX_Bridge_v0.1.0.zip'
        $zipPath = Join-Path $stage $zipName
        $zipStream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($zipStream,
                [System.IO.Compression.ZipArchiveMode]::Create, $false)
            foreach ($relativePath in (Get-ReleaseProfile -Version 'v0.1.0').PackageFiles | Sort-Object) {
                $entry = $archive.CreateEntry([string]$relativePath,
                    [System.IO.Compression.CompressionLevel]::Optimal)
                $sourcePath = Join-Path $package ([string]$relativePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $sourceStream = [System.IO.File]::OpenRead($sourcePath)
                $entryStream = $entry.Open()
                try { $sourceStream.CopyTo($entryStream) }
                finally { $entryStream.Dispose(); $sourceStream.Dispose() }
            }
        } finally {
            if ($null -ne $archive) { $archive.Dispose() }
            $zipStream.Dispose()
        }
        $archiveFacts = Test-ReleaseArchiveMatchesPackage -PackageRoot $package -ArchivePath $zipPath
        $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestPath = Join-Path $package 'manifest.json'
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $distributionManifestPath = Join-Path $stage 'manifest.json'
        $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
        [System.IO.File]::WriteAllBytes($distributionManifestPath, $manifestBytes)
        $distributionManifestHash = (Get-FileHash -LiteralPath $distributionManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($distributionManifestHash -cne $manifestHash) { throw 'Standalone manifest copy differs from the audited package manifest bytes.' }
        $checksumPath = Join-Path $stage 'SHA256SUMS.txt'
        $checksumText = $zipHash + '  ' + $zipName + "`n" + $manifestHash + '  manifest.json' + "`n"
        [System.IO.File]::WriteAllText($checksumPath, $checksumText, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $finalDirectory) { throw 'Stable ZIP output directory appeared during packaging; no overwrite was attempted.' }
        [System.IO.Directory]::Move($stage, $finalDirectory)
        return [pscustomobject]@{
            directory = $finalDirectory
            archive = (Join-Path $finalDirectory $zipName)
            archive_sha256 = $zipHash
            archive_length_bytes = [long](Get-Item -LiteralPath (Join-Path $finalDirectory $zipName)).Length
            manifest = (Join-Path $finalDirectory 'manifest.json')
            manifest_sha256 = $manifestHash
            checksum = (Join-Path $finalDirectory 'SHA256SUMS.txt')
            archive_entry_count = $archiveFacts.EntryCount
            archive_uncompressed_bytes = $archiveFacts.TotalLengthBytes
        }
    } catch {
        if ((Test-Path -LiteralPath $stage -PathType Container) -and
            (Test-PathWithinDirectory -Path $stage -Directory $parent) -and
            [System.IO.Path]::GetFileName($stage).StartsWith('.staging-v0.1.0-', [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
        }
        throw
    }
}

function Assert-ReleasePackageInventory {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [string]$Version = $script:activeReleaseVersion)
    $profile = Set-ReleaseVersion -Version $Version
    $expectedFiles = @($profile.PackageFiles | Sort-Object)
    $expectedPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($expectedPath in $expectedFiles) {
        if (-not $expectedPathSet.Add([string]$expectedPath)) { throw '发布清单含大小写不敏感的重复路径。' }
    }
    $expectedAssetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($expectedPath in $expectedFiles | Where-Object { $_ -cne 'manifest.json' }) {
        $assetName = [string]$profile.AssetMap[[string]$expectedPath]
        if ([string]::IsNullOrWhiteSpace($assetName) -or -not $expectedAssetSet.Add($assetName)) {
            throw '发布清单含缺失或大小写不敏感的重复 asset_name。'
        }
    }
    $allItems = @(Get-ChildItem -LiteralPath $PackageRoot -Force -Recurse)
    foreach ($item in $allItems) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '发布目录不能包含 reparse point 或目录联接。'
        }
    }
    $actualFiles = @($allItems | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $_.FullName.Substring($PackageRoot.Length + 1).Replace('\', '/')
    } | Sort-Object)
    if ($actualFiles.Count -ne $expectedFiles.Count) { throw "发布目录文件数不符：$($actualFiles.Count) / $($expectedFiles.Count)" }
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        if ($actualFiles[$index] -cne $expectedFiles[$index]) { throw "发布目录含意外文件或缺失文件：$($actualFiles[$index])" }
    }
    $expectedDirectories = @($profile.Directories | Sort-Object)
    $actualDirectories = @($allItems | Where-Object { $_.PSIsContainer } | ForEach-Object {
        $_.FullName.Substring($PackageRoot.Length + 1).Replace('\', '/')
    } | Sort-Object)
    if ($actualDirectories.Count -ne $expectedDirectories.Count) {
        throw ('发布目录包含额外目录或缺失目录：actual=' + ($actualDirectories -join ',') +
            '; expected=' + ($expectedDirectories -join ','))
    }
    for ($index = 0; $index -lt $expectedDirectories.Count; $index++) {
        if ($actualDirectories[$index] -cne $expectedDirectories[$index]) { throw "发布目录树不符：$($actualDirectories[$index])" }
    }
    $isStableRelease = $profile.Version -ceq 'v0.1.0'
    if (-not $isStableRelease -and @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'logs') -Force).Count -ne 0) {
        throw '发布包 logs 目录必须为空。'
    }
    if ($isStableRelease) {
        $fixturePath = Join-Path $PackageRoot 'runtime\private\device-y.bin'
        $fixtureHash = Test-ApprovedYFixture -Path $fixturePath
        if (@($actualFiles | Where-Object { $_ -match '^(private|logs)(/|$)|(^|/)logs/|\.log$' }).Count -gt 0 -or
            @($actualFiles | Where-Object { $_ -match '^runtime/private/' -and $_ -cne 'runtime/private/device-y.bin' }).Count -gt 0) {
            throw '稳定版 generic 发布包不能包含用户 private 数据或运行日志；runtime/private 仅允许获批协议模板。'
        }
    } else {
        $fixturePath = Join-Path $PackageRoot 'private\device-y.bin'
        $fixtureHash = Test-ApprovedYFixture -Path $fixturePath
    }
    $forbidden = @($actualFiles | Where-Object {
        $_ -match '(^|/)(?:bm-device-password\.txt|password-file-path\.txt|connection-profile\.json|audio-settings\.json)$' -or
        $_ -match '(^|/)bm-management-preferences\.json$' -or
        $_ -match '(^|/)(?:radio-identity-cache\.json|channel-favorites\.json|user-config-directory\.txt|test-radio-identity(?:-http-server)?\.ps1)$' -or
        $_ -match '^private/user-config/' -or
        $_ -match '(^|/)logs/|\.log$'
    })
    if ($forbidden.Count -gt 0) { throw "发布目录含禁止文件：$($forbidden[0])" }
    $manifestPath = Join-Path $PackageRoot 'manifest.json'
    try {
        $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw "发布 manifest 无法解析：$($_.Exception.Message)"
    }
    $expectedPackageKind = if ($isStableRelease) { 'wirex_bridge_stable_release_green_directory' } else { 'wirex_bridge_private_alpha_release_green_directory' }
    if ([string]$manifest.version -cne $profile.Version -or
        [string]$manifest.tag_candidate -cne $profile.Version -or $manifest.schema_version -ne 1 -or
        [string]$manifest.package_kind -cne $expectedPackageKind -or
        [string]$manifest.package_status -notin @('awaiting_root_audit', 'root_audit_passed')) {
        throw ('manifest schema_version、package_kind 或 package_status 不受支持：version={0}; kind={1}; status={2}; schema={3}; expectedKind={4}' -f `
            [string]$manifest.version,[string]$manifest.package_kind,[string]$manifest.package_status,[string]$manifest.schema_version,$expectedPackageKind)
    }
    if (-not $isStableRelease) {
        if ([string]$manifest.approved_y_fixture.path -cne 'private/device-y.bin' -or
            [long]$manifest.approved_y_fixture.length_bytes -ne 100 -or
            ([string]$manifest.approved_y_fixture.sha256).ToLowerInvariant() -cne $fixtureHash) {
            throw 'manifest 中的 Y 素材记录与获批文件不一致。'
        }
    } else {
        if ([string]$manifest.approved_y_fixture.path -cne 'runtime/private/device-y.bin' -or
            [long]$manifest.approved_y_fixture.length_bytes -ne 100 -or
            ([string]$manifest.approved_y_fixture.sha256).ToLowerInvariant() -cne $fixtureHash) {
            throw 'manifest 中的 runtime HRI 协议模板与获批文件不一致。'
        }
        if ($null -eq $manifest.launcher_build -or
            [string]$manifest.launcher_build.source_commit -cne [string]$manifest.source.commit -or
            [string]$manifest.launcher_build.source_path -cne 'ui/launcher/WirexBridgeLauncher.cs' -or
            [string]$manifest.launcher_build.provenance_asset -cne 'launcher-build-provenance.json' -or
            [string]$manifest.launcher_build.executable_asset -cne 'WirexBridge.exe' -or
            [string]$manifest.launcher_build.compiler_family -cne 'Microsoft .NET Framework csc.exe' -or
            [string]$manifest.launcher_build.target -cne 'x64 Windows GUI executable') {
            throw '稳定版 manifest 缺少 launcher 源码与构建来源记录。'
        }
        $launcherExeRecord = @($manifest.files | Where-Object { [string]$_.path -ceq 'WirexBridge.exe' })
        $launcherProvenanceRecord = @($manifest.files | Where-Object { [string]$_.path -ceq 'launcher-build-provenance.json' })
        $nativeExeRecord = @($manifest.files | Where-Object { [string]$_.path -ceq 'runtime/wirex_bridge.exe' })
        $nativeProvenanceRecord = @($manifest.files | Where-Object { [string]$_.path -ceq 'build-provenance.json' })
        if ($launcherExeRecord.Count -ne 1 -or $launcherProvenanceRecord.Count -ne 1 -or
            $nativeExeRecord.Count -ne 1 -or $nativeProvenanceRecord.Count -ne 1 -or
            [string]$manifest.launcher_build.executable_sha256 -cne [string]$launcherExeRecord[0].sha256 -or
            [string]$manifest.launcher_build.provenance_sha256 -cne [string]$launcherProvenanceRecord[0].sha256 -or
            [string]$manifest.build.executable_sha256 -cne [string]$nativeExeRecord[0].sha256 -or
            [string]$manifest.build.provenance_sha256 -cne [string]$nativeProvenanceRecord[0].sha256) {
            throw '稳定版 manifest 中的两类 EXE 与两份 build provenance hash 未能一一对应。'
        }
    }
    $records = @($manifest.files)
    if ($records.Count -ne ($expectedFiles.Count - 1)) { throw 'manifest 记录数与发布文件清单不符。' }
    $sortedRecords = @($records | Sort-Object { ([string]$_.path).Replace('\', '/') })
    $recordPaths = @($sortedRecords | ForEach-Object { ([string]$_.path).Replace('\', '/') })
    $manifestFilePaths = @($expectedFiles | Where-Object { $_ -cne 'manifest.json' })
    if ($recordPaths.Count -ne $manifestFilePaths.Count) { throw 'manifest 路径数与预期文件数不符。' }
    $assetNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
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
        if (-not $assetNameSet.Add([string]$record.asset_name)) { throw 'manifest asset_name 存在大小写不敏感的重复。' }
    }
    if (-not $assetNameSet.Add([string]$manifest.manifest_asset_name)) { throw 'manifest asset_name 不唯一。' }
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
        [string]$YFixturePath,
        [string]$LauncherBuildDirectory,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot
    )
    $profile = Set-ReleaseVersion -Version $Version
    $isStableRelease = $profile.Version -ceq 'v0.1.0'
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
    $launcherBuildEvidence = $null
    $fixturePath = $null
    $fixtureHash = $null
    if ($isStableRelease) {
        if ([string]::IsNullOrWhiteSpace($LauncherBuildDirectory)) { throw 'v0.1.0 需要明确的 LauncherBuildDirectory。' }
        if ([string]::IsNullOrWhiteSpace($YFixturePath)) { throw 'v0.1.0 需要获批的 HRI 协议模板路径。' }
        $launcherBuildPath = Resolve-ReleasePath -Path $LauncherBuildDirectory -BaseDirectory $repo
        $launcherBuildEvidence = Test-ReleaseLauncherBuildEvidence -RepositoryRoot $repo -SourceCommit $sourceCommit `
            -BuildDirectory $launcherBuildPath
    }
    if (-not $isStableRelease -and [string]::IsNullOrWhiteSpace($YFixturePath)) { throw 'alpha 发布需要批准的 Y 素材路径。' }
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
        $exeRelativePath = if ($isStableRelease) { 'runtime\wirex_bridge.exe' } else { 'wirex_bridge.exe' }
        $exeDestination = Join-Path $stagingPath $exeRelativePath
        $exeDestinationDirectory = Split-Path -Parent $exeDestination
        if (-not (Test-Path -LiteralPath $exeDestinationDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $exeDestinationDirectory -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $exeSource -Destination $exeDestination -ErrorAction Stop
        Copy-Item -LiteralPath (Join-Path $buildPath 'build-provenance.json') `
            -Destination (Join-Path $stagingPath 'build-provenance.json') -ErrorAction Stop
        if ($isStableRelease) {
            Copy-Item -LiteralPath $launcherBuildEvidence.executable -Destination (Join-Path $stagingPath 'WirexBridge.exe') -ErrorAction Stop
            Copy-Item -LiteralPath $launcherBuildEvidence.provenance -Destination (Join-Path $stagingPath 'launcher-build-provenance.json') -ErrorAction Stop
        }
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
        if ($isStableRelease) {
            $yDestinationDirectory = Join-Path $stagingPath 'runtime\private'
        } else {
            $yDestinationDirectory = Join-Path $stagingPath 'private'
        }
        New-Item -ItemType Directory -Path $yDestinationDirectory -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $yDestinationDirectory 'device-y.bin') -ErrorAction Stop
        if (-not $isStableRelease) {
            New-Item -ItemType Directory -Path (Join-Path $stagingPath 'logs') -ErrorAction Stop | Out-Null
        }

        $notIncludedText = @($profile.NotIncluded) -join '、'
        $excludedPrivateFiles = @(Get-ReleaseExcludedPrivateFiles -Version $Version)
        if ($isStableRelease) {
            $sourceText = @"
WIREX Bridge $Version generic portable release candidate

Source commit: $sourceCommit
Native build directory: $(Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath)
Native build evidence: $(Get-RepoRelativePath -RepositoryRoot $repo -Path $logPath)
Native build provenance SHA-256: $($buildEvidence.build_provenance_sha256)
Native offline tests: $($buildEvidence.passed_test_count) passed; compiler warnings/errors: 0/0
Native runtime SHA-256: $($buildEvidence.executable_sha256)
Launcher source: $($launcherBuildEvidence.source_path)
Launcher source SHA-256: $($launcherBuildEvidence.source_sha256)
Launcher compiler: $($launcherBuildEvidence.compiler_family) $($launcherBuildEvidence.compiler_version)
Launcher output: $(Get-RepoRelativePath -RepositoryRoot $repo -Path $launcherBuildEvidence.build_directory)/WirexBridge.exe
Launcher SHA-256: $($launcherBuildEvidence.executable_sha256)
Release tag candidate: $Version; the packager does not create a tag or publish a release.

Scope: $($profile.ReleaseScope).
Not included: $notIncludedText.

The generic package contains no user config, callsign, password, API key, machine-specific directory, or runtime log. The approved HRI protocol template is retained as runtime/private/device-y.bin and checked against its fixed SHA-256. On first launch, WirexBridge.exe creates config.json in its own directory using the shared PortableConfig module. The launcher uses Windows PowerShell 5.1 as its internal runtime and keeps its Native, UI, and script components under runtime/.

No current-release device, HRI, audio, PTT, or RF validation was performed. The UI package and launch checks use synthetic configuration in temporary directories.
"@
        } else {
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
        }
        [System.IO.File]::WriteAllText((Join-Path $stagingPath 'SOURCE.txt'), $sourceText.TrimStart(), (New-Object System.Text.UTF8Encoding($false)))

        $records = @()
        $exeRelative = if ($isStableRelease) { 'runtime/wirex_bridge.exe' } else { 'wirex_bridge.exe' }
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath $exeRelative `
            -Source ((Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath) + '/wirex_bridge.exe'))
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'build-provenance.json' `
            -Source ((Get-RepoRelativePath -RepositoryRoot $repo -Path $buildPath) + '/build-provenance.json'))
        if ($isStableRelease) {
            $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'WirexBridge.exe' `
                -Source ((Get-RepoRelativePath -RepositoryRoot $repo -Path $launcherBuildEvidence.build_directory) + '/WirexBridge.exe'))
            $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'launcher-build-provenance.json' `
                -Source ((Get-RepoRelativePath -RepositoryRoot $repo -Path $launcherBuildEvidence.build_directory) + '/launcher-build-provenance.json'))
        }
        foreach ($entry in (Get-ReleaseSourceFiles)) {
            $destination = $entry.Destination.Replace('\', '/')
            $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath $destination `
                -Source ('source commit ' + $sourceCommit + ': ' + $entry.Source.Replace('\', '/')))
        }
        $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'SOURCE.txt' `
            -Source 'generated from verified source and build evidence')
        if (-not $isStableRelease) {
            $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'private/device-y.bin' `
                -Source ('approved 100-byte Y fixture; SHA-256 ' + $fixtureHash))
        } else {
            $records += ,(Get-ReleaseFileRecord -PackageRoot $stagingPath -RelativePath 'runtime/private/device-y.bin' `
                -Source ('approved 100-byte HRI protocol template; SHA-256 ' + $fixtureHash))
        }
        $assetNames = @($records | ForEach-Object { [string]$_.asset_name })
        if (@($assetNames | Sort-Object -Unique).Count -ne $assetNames.Count) { throw '生成的 release asset_name 存在重复。' }

        $manifest = [ordered]@{
            schema_version = 1
            package_kind = if ($isStableRelease) { 'wirex_bridge_stable_release_green_directory' } else { 'wirex_bridge_private_alpha_release_green_directory' }
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
                path = if ($isStableRelease) { 'runtime/private/device-y.bin' } else { 'private/device-y.bin' }
                length_bytes = 100
                sha256 = $fixtureHash
            }
            excluded_private_files = $excludedPrivateFiles
            runtime_directories = if ($isStableRelease) {
                @($profile.Directories | Where-Object { [string]$_ -like 'runtime*' })
            } else { @('logs/ (empty at package creation)') }
            manifest_asset_name = 'manifest.json'
            files = @($records)
        }
        if ($isStableRelease) {
            $manifest['launcher_build'] = [ordered]@{
                source_commit = $sourceCommit
                source_path = $launcherBuildEvidence.source_path
                source_sha256 = $launcherBuildEvidence.source_sha256
                compiler_family = $launcherBuildEvidence.compiler_family
                compiler_version = $launcherBuildEvidence.compiler_version
                target = $launcherBuildEvidence.target
                output_directory = (Get-RepoRelativePath -RepositoryRoot $repo -Path $launcherBuildEvidence.build_directory)
                executable_asset = 'WirexBridge.exe'
                executable_sha256 = $launcherBuildEvidence.executable_sha256
                provenance_asset = 'launcher-build-provenance.json'
                provenance_sha256 = $launcherBuildEvidence.provenance_sha256
                build_log_path = (Get-RepoRelativePath -RepositoryRoot $repo -Path $launcherBuildEvidence.build_log)
                build_log_sha256 = $launcherBuildEvidence.build_log_sha256
            }
        }
        $manifestJson = ConvertTo-Json -InputObject $manifest -Depth 12
        [System.IO.File]::WriteAllText((Join-Path $stagingPath 'manifest.json'), $manifestJson + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Assert-ReleasePackageInventory -PackageRoot $stagingPath -Version $Version

        if (Test-Path -LiteralPath $outputPath) { throw "发布目录已出现，拒绝覆盖：$outputPath" }
        [System.IO.Directory]::Move($stagingPath, $outputPath)
        $createdOutput = $true
        Write-Host "绿色发布候选已创建：$outputPath"
        if ($isStableRelease) {
            Write-Host "文件清单记录数：$($records.Count)；GitHub 分发资产将为 ZIP、manifest.json、SHA256SUMS.txt。"
        } else {
            Write-Host "清单 asset 数：$($records.Count + 1)（含 manifest.json；未生成 ZIP）"
        }
        Write-Host 'package_status=awaiting_root_audit'
        if ($isStableRelease) {
            $distribution = New-StableReleaseDistribution -PackageRoot $outputPath -RepositoryRoot $repo
            Write-Host ('stable 分发 ZIP 已创建：' + (Get-RepoRelativePath -RepositoryRoot $repo -Path $distribution.archive))
            Write-Host ('SHA256SUMS 已创建：' + (Get-RepoRelativePath -RepositoryRoot $repo -Path $distribution.checksum))
            Write-Host ('stable GitHub Release 固定为 3 个资产：ZIP、manifest.json、SHA256SUMS.txt；不会逐项上传 runtime 文件。')
        }
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
        -YFixturePath $YFixturePath -LauncherBuildDirectory $LauncherBuildDirectory -RepositoryRoot $repositoryRoot
}
