# WIREX Bridge 系统架构（现行）

本文描述 main 当前代码（R126 起）的组成与运行方式，不记录历史。逐轮演进见 git 历史与 `docs/research/`。标“待核实”的条目未在本轮重新验证。

## 1. 总览

WIREX Bridge 让开启 HRI 模式的 Yaesu FTX-1 把电脑当作 WIRES-X 节点，同时以 Homebrew/MMDVM 热点身份登录 BrandMeister（BM），实现电台 WIRES-X（DIRECT/AP）与 BM DMR 网络互通。

```text
WirexBridge.exe (C# launcher, Job Object)
  └─ powershell.exe 5.1 -STA  runtime/start-ui.ps1
       └─ ui/windows/bridge-ui.ps1  (WPF 主窗口，PowerShell 模块)
            ├─ RadioCat 后台 runspace ── COM (CAT-1) ── FTX-1
            ├─ BmManagement / RadioIdentity ── HTTPS (BM API、RadioID)
            └─ BridgeSupervisor (C#, Job Object, 匿名管道)
                 └─ runtime/wirex_bridge.exe  (Native C++)
                      ├─ HRI 串口 (COM) ── FTX-1
                      ├─ WinMM WaveIn/WaveOut ── 电台 USB 音频
                      └─ UDP Homebrew/DMRD ── BM Master
```

## 2. Native：`wirex_bridge.exe`

入口为 `src/probe_main.cpp`，以 `WIREX_ENABLE_BM_BRIDGE` 编译；同一源码不带该宏时编译出诊断用 `wirex_probe.exe`。头文件在 `include/wirex/`，实现在 `src/`，第三方在 `third_party/`。

| 层 | 模块 | 职责 |
| --- | --- | --- |
| HRI 帧与会话 | `direct_frame`、`direct_stream`、`hri_session`、`hri_radio_protocol` | HRI/DIRECT 串口帧编解码、会话状态机（不直接访问设备） |
| HRI 下行 | `hri_t_payload`、`hri_t_record`、`hri_call_header`、`hri_stream_session`、`hri_downlink_session` | 组装 T 记录与 68 字节呼叫头；单条下行语音的 T3 起播 / T0 收尾门控 |
| HRI 上行 | `hri_ptt_gate` | 手咪 PTT 边沿门控：ready 后先见松开，再接受新按下 |
| LCD 实验 | `hri_lcd_identity_candidate`、`radio_identity_cache` | 呼号字段候选写入（实验性，LCD 显示未证实）；DMR ID→呼号缓存（最多 128 项） |
| BM 网络 | `bm_session`、`bm_udp`、`bm_connection_control`、`bm_connection_config`、`bm_network_metadata`、`bm_test_profile` | Homebrew 登录状态机（RPTL/RPTK/RPTC/RPTO/RPTPING/RPTCL）、非阻塞 WinSock UDP、运行中启停 BM 会话、RPTC 元数据、预设 |
| DMR 语音 | `dmrd`、`dmr_call`、`dmr_vocoder`、`bm_voice_pipeline`、`pcm_resampler`、`quick_call` | DMRD 55 字节数据报、DMR 通话帧/LC、AMBE+2 2450x1150 编解码（DroidStar MBE/IMBE）、48 kHz↔8 kHz 重采样、Quick Call 激活动态组 |
| 路由 | `talkgroup_routing`、`routing_state` | RX 允许集合/TX 目标策略；`--routing-state-file` 的 schema_version=1 策略文件 |
| 控制与报告 | `ui_control_protocol`、`strict_json`、`bounded_pipe_writer`、`session_report`、`session_timing`、`console_lifecycle` | control-v2 JSONL、严格 JSON、非阻塞 stdout、JSONL 状态报告、有界收尾时限 |
| 音频 | `wave_file`、`pcm_gain`、`wave_output_open`、`audio_input_cleanup`、`operation_audio_cleanup` | WAV、增益与削波统计、WaveOut/WaveIn 打开与关闭失败记录 |
| 未接入运行时 | `ysf_vd2_vch`、`voice_transcode_buffer`、`ambe_dmr72`、`ambe2450_parameters`、`hri_p_status` | 仅有离线测试，未链接进 `wirex_bridge`（C4FM VCH↔AMBE 参数映射等研究成果） |

第三方：`third_party/droidstar_mbe`（固定 DroidStar 提交的 MBE/IMBE 源码，GPL-3.0 + ISC，清单 `source-manifest.json`）、`third_party/dmr_signal`（DMR FEC/LC，GPL-3.0）。

### 命令行（`wirex_bridge.exe --help`）

- `--run --port COMn --body-file ABS --input N --output N --status-file ABS --expected-wavein-endpoint ID --expected-waveout-endpoint ID ...`：正式运行；BM 资料用 9 个 `--profile-*` 字段或 `--test-preset`，密码只经 `--password-file` 传路径。
- `--ui-pipe --ui-control-version 2`：由 WPF 托管，stdin/stdout 必须是匿名管道。
- `--bm-start-disconnected`：先连 HRI/CAT，BM 会话由 `bm.connection.set` 单独开关。
- `--routing-state-file ABS`、`--listen-only`、`--manual-ptt`、`--radio-playback-gain`/`--mic-transmit-gain`（0.25–16.0）。
- 诊断：`--list-audio-json`、`--control-diagnostic`、`--routing-diagnostic`（合成本机 ID=1，不访问网络或设备）、`--hri-lcd-identity-candidate`（本地 WAV 实验）。

### 音路

- **上行（RF→BM）**：电台手咪 PTT 经 HRI 上报 → `hri_ptt_gate` 放行 → WaveIn 48 kHz PCM16 → 麦克风增益 → 降采样到 8 kHz → AMBE+2 编码 → 每 60 ms 一个 DMRD voice burst（3 个 9 字节码字）→ UDP 发往 BM。默认由手咪 PTT 驱动，`--manual-ptt` 为键盘诊断模式。
- **下行（BM→RF）**：DMRD 先按目标 ID/时隙/组呼私呼过滤 → `dmr_call::Receiver` 校验 → 发出 `receive_started` 后 Native 写 HRI T3 → 确认后才放音 → AMBE+2 解码 → 升采样 48 kHz → 播放增益 → WaveOut 输出到电台 → 网络结束（终止帧或 360 ms 看门狗）后排空并写 T0 收尾。起播前最多缓冲 3 秒。
- 只有 WaveOut 关闭失败、T0 未写入/未观察/超时等情况才报 `downlink_call_bounded_cleanup_incomplete`（R126 规则）。
- C4FM 数字直通未实现：上述路径在电脑侧处理 PCM，电台空中调制由电台自身决定（实测范围见 TODO 第一节）。

## 3. WPF UI（PowerShell 5.1）

`ui/windows/` 下的文件都随包进入 `runtime/ui/windows/`：

| 文件 | 职责 |
| --- | --- |
| `bridge-ui.ps1`（约 8900 行） | 主程序：加载 XAML、模块与点载脚本；状态轮询、频道卡片（3×2/页）、来话历史、BM 启停、音量、控制协议收发 |
| `MainWindow.xaml`、`SettingsWindow.xaml` | 主窗口（固定 1360×900）与设置窗口 |
| `BridgeSupervisor.cs` | 运行时 `Add-Type` 编译；`CreateProcessW` + Job Object 启动 Native，匿名管道收发 control-v2，`StopAsync(5000)` 有界停止 |
| `PortableConfig.psm1` | `config.json` 读取、校验、原子保存、首次生成（`Initialize-PortableConfig`） |
| `RadioCat.psm1` / `RadioCatUi.ps1` | FTX-1 CAT-1：ID/AI/TX/FA/FB/MD/PC 查询，MAIN 频率、模式、功率设置；后台 runspace 执行，写前核对 ID0840 与 TX0 |
| `RadioDevices.psm1` | 枚举串口（注册表 + CIM）与端口选择 |
| `BmManagement.psm1` / `BmManagementUi.ps1` | BM API v2 `/v2/device/{id}/talkgroup` 静态组查询、添加、删除（Bearer API Key） |
| `BmServers.psm1` | 内置 BM Master 列表（离线快照，来源 Pi-Star `DMR_Hosts.txt`），默认 `bm-china-4602` |
| `RadioIdentity.psm1` | 经 radioid.net 查询 DMR ID 呼号，本地缓存 `radio-identity-cache.json` |
| `ChannelActivationState.psm1` | 动态组 Quick Call 激活请求状态与超时 |
| `UiLocalization.psm1` | 中英文词典；R126 起界面固定中文，切换入口隐藏（TODO 2.1） |

`tools/` 中随包的运行脚本：`start-ui.ps1`（入口，初始化配置后点载 `bridge-ui.ps1`）、`start-bm-radio-bridge.ps1`（`-PrepareOnly` 生成并校验 Native 启动参数、读取 `runtime/private/device-y.bin` HRI 模板）、`bridge-user-config.psm1`（旧版用户配置目录与密码文件辅助）。

`ui/main.py`、`ui/preview/`、`ui/prototypes/` 是早期 PySide6/静态原型，不参与当前构建或发布。

## 4. Launcher：`WirexBridge.exe`

源码 `ui/launcher/WirexBridgeLauncher.cs`，用 .NET Framework `csc.exe` 编译为 x64 GUI 程序，嵌入 `assets/wiresx-official.ico`（同时作为 `WIREX.ico` 程序集资源供 WPF 窗口读取）。

- 参数：无参数正常启动；`--no-connect`；`--validate-config`（只校验/生成 `config.json` 后退出）；`--routing-diagnostic <绝对隔离目录>`。
- 检查 `runtime/` 下 `start-ui.ps1`、`ui/windows/bridge-ui.ps1`、`PortableConfig.psm1`、`wirex_bridge.exe` 存在后，启动 `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File runtime\start-ui.ps1 -PackageDirectory runtime -PortableDirectory <exe 目录>`。
- 子进程放入带 `KILL_ON_JOB_CLOSE` 的 Job Object；launcher 退出时关闭 Job，清理本次启动的全部后代进程。

## 5. 进程与生命周期

1. launcher → PowerShell STA → `start-ui.ps1` → `Initialize-PortableConfig`（exe 同目录无 `config.json` 时写默认值）→ `bridge-ui.ps1`。
2. UI 打开后加载 CAT/BM/身份等模块；运行数据写入 `runtime/private/runtime/`（每次运行一个 `ui-runs/<run>/status.jsonl` 等）。
3. 用户点「连接串口」：UI 在后台 runspace 调 `start-bm-radio-bridge.ps1 -PrepareOnly` 得到参数，校验必须包含 `--ui-pipe --ui-control-version 2`，BM 密码写入会话临时文件，再由 `BridgeSupervisor.Start(..., 2)` 启动 Native（通常带 `--bm-start-disconnected`）。
4. 「连接 BrandMeister」：经控制协议发送 `bm.connection.set`，Native 内部开关 BM UDP 会话，HRI 不重启。
5. 停止：`StopAsync(5000)` 发送 control-v2 `shutdown`（v1 为 `Q\r\n`）并关闭 stdin；5 秒内未退出则关闭 Job，再兜底 `TerminateProcess`。BM 会话先发 RPTCL 再关 UDP。
6. 关闭窗口走同一停止流程；launcher 结束时 Job 关闭兜底。

## 6. IPC：control-v2

- 传输：Native stdin/stdout 匿名管道，UTF-8 JSONL，每行最多 4096 字节；请求 ID 缓存 512 条用于重放判定。stdin EOF 视为停止。
- 请求 envelope 恰好 4 个字段（`schema_version`=2、`run_id`、`request_id`、`command`）；变更类命令另加对象 `parameters`，共 5 个字段。多余字段或重复键都拒绝。
- 命令：`hello`、`status`、`routing.status`、`rx_policy.replace`、`tx_policy.replace`、`network_subscription.quick_call_join`、`radio_identity.cache_upsert`、`audio.gains.set`、`bm.connection.set`、`shutdown`。
- Native 输出类型：`control_ready`（含 `supported_commands`、`process_id`、`run_id`）、`control_result`、`routing_state`；UI 核对 `run_id` 的 PID 前缀与子进程一致。
- 能力协商：UI 只在 `control_ready`/`hello` 声明支持时启用实时音量等功能。
- 运行状态另写入 `--status-file` 指定的 JSONL（`session_report`），UI 轮询读取。

## 7. 配置：`config.json`

位于 `WirexBridge.exe` 同目录，首次启动生成，明文保存凭据，不进入发布包或 Git。上限 128 KiB，`schema_version` 必须为 1，重复键拒绝，保存时临时文件 + `File.Replace` 原子替换。

| 节 | 字段 |
| --- | --- |
| `connection` | `callsign`（≤8 ASCII）、`gateway_id`、`source_id`（≤16777215）、`master`（默认 `43.129.83.124`）、`master_port`（62031）、`color_code`（0–15）、`password`、`api_key` |
| `devices` | `hri_port`/`serial_port`/`cat_port`（`auto` 或 `COM1`–`COM999`）、`cat_baud_rate`（4800/9600/19200/38400/115200，默认 38400）、`cat_stop_bits`（固定 `Two`）、`wave_in_endpoint_id`/`wave_out_endpoint_id`（默认 `auto`）、`desired_power_watts`（5–50，默认 25） |
| `audio` | `radio_playback_gain`（默认 1.0）、`mic_transmit_gain`（默认 16.0） |
| `channels` | 数组，≤256 项：`id`、`kind`（`group`/`private`）、`slot`（1/2）、`name`（≤40）；默认 `private:460997:2`（BM 鹦鹉） |
| `tx_channel_id` | `kind:id:slot` 形式，必须对应已有频道 |
| `routing` | `blocked_source_ids` |
| `ui` | `bm_server_selection_id`（`custom` 或 `bm-*`）、`legacy_rx_policy`、`language`（`zh-CN`/`en-US`，当前不生效） |
| `window` | 窗口状态（对象） |

## 8. CAT 与 BM API

- **CAT**：CAT-1 串口，8N2。只读查询 ID/FA/FB/MD/PC；设置 MAIN 频率或模式前会先停止 Bridge 核心；设置功率需核心空闲。手册中没有 HRI MODE 与 Node Mode 的 CAT 指令，软件不切换这两项（实机核对见 TODO 1.2）。
- **BM API**：`https://api.brandmeister.network/v2/`，API Key 来自 `config.json`；静态组的 `slot` 是 API 字段，与 DMRD 时隙不同。动态组不走 API，用 Quick Call（空组呼头 + 终止帧）激活；TG4000 不能作为加入目标。
- **BM 网络**：Homebrew/MMDVM 协议，Master 支持 IPv4 或主机名；RPTK 由 BCrypt SHA-256 计算，RPTPING 每 10 秒一次，60 秒无 pong 即退避重连。

## 9. 发布结构

- **v0.1.0（已发布）**：根目录 `WirexBridge.exe`、`README.md`、`SOURCE.txt`、provenance 文件、`manifest.json`，加上 `runtime/`（含 `runtime/docs/` 下 14 份文档）。profile 内联在 `tools/package-release.ps1`；`tools/StableReleaseContract.psm1` 固定已发布资产的约束。这些文档（见 HANDOFF 文档索引）必须保持路径与内容不变。
- **ZIP-only（R126 起，`v0.1.1-test.2`、`v0.1.1`）**：profile 在 `tools/ZipOnlyRelease.psm1`。ZIP 根目录只有 `WirexBridge.exe`，其余 24 个运行文件都在 `runtime/` 下（脚本、UI、`wirex_bridge.exe`、`private/device-y.bin`、`licenses/`）。README、manifest、校验和、provenance 不进 ZIP，审计材料写到 `private/release-audits/R126/<tag>/`；GitHub Release 只上传 ZIP。尚未打包。
- `docs/releases/<tag>.md` 是对应 tag 的 Release 正文（`publish-release.ps1` 按路径读取）。

## 10. 构建与测试入口

所有脚本都按 Windows PowerShell 5.1 编写，必须保存为 UTF-8 BOM。从 Git Bash 调用时须重置 `PSModulePath`（见 HANDOFF）。

| 用途 | 入口 |
| --- | --- |
| Native 全量构建 + 40 项测试 | `tools/build-bm-bridge.ps1 [-CompileOnly]`：VS 2019 `vcvarsall amd64` + `cl.exe /MT /std:c++17`；输出到 `build/_work/wirex-bridge-<commit>-<time>/`，并写 provenance |
| CMake（等价目标） | `CMakeLists.txt`：42 个 executable，其中 40 个以 `add_test` 注册 |
| Launcher | `tools/build-launcher.ps1 -OutputDirectory <dir>`（.NET Framework `csc.exe`） |
| 打包 | `tools/package-release.ps1 -Version <tag> ...`；本机测试包用 `tools/package-local-test.ps1` |
| 发布 / 下载校验 | `tools/publish-release.ps1`、`tools/download-release.ps1` |
| 离线测试 | `tools/test-*.ps1`（UI 测试需 `-STA`），如 `test-ui-render.ps1`（RenderOnly 布局）、`test-ui-console.ps1`、`test-portable-config.ps1`、`test-r126-zip-only.ps1`、`test-package-release.ps1` |
| 研究工具 | `tools/research/*.js`（Frida 只读观察器及离线测试）、`tools/hri_ptt_observer.cpp`、`tools/bm_network_probe.cpp` |
| Python 原型测试 | `ui/tests/`（仅原型，不在发布路径上） |

测试所需的非 Git 资源：`private/fixtures/device-y.bin`（HRI 模板）、`build/releases/v0.1.0`（已发布包目录）以及 `v0.1.0` tag。
