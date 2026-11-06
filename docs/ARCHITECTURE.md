# WIREX Bridge 系统架构（现行）

本文只描述 `feat/r128-native-gui` 当前代码的组成与运行方式，不记录历史（逐轮演进见 git 历史、`docs/research/`）。标“待核实”的条目未从代码中确认。

## 1. 总览

WIREX Bridge 让开启 HRI 模式的 Yaesu FTX-1 把电脑当作 WIRES-X 节点，同时以 Homebrew/MMDVM 热点身份登录 BrandMeister（BM），实现电台与 BM DMR 网络之间的语音互通。

当前产品形态是**单进程原生 C++** 程序 `WirexBridge.exe`（MSVC 2019，`/MT` 静态链接）：

```text
WirexBridge.exe
  ├─ UI 线程      Win32 + DirectX 11 + Dear ImGui（src/gui/）
  ├─ 引擎线程      engine::Engine（src/engine/）── HRI 串口 / WinMM WaveIn·WaveOut / BM UDP
  ├─ CAT 线程      CatRunner + app::CatWorker ── CAT-1 串口（src/app/radio_cat.cpp）
  └─ HTTP 线程     BM API v2 runner、RadioID 查询 runner（WinHTTP，src/app/）
```

| 目录 | 内容 |
| --- | --- |
| `src/gui/` | 入口 `gui_main.cpp`、`ViewModel`、`AppView`（ImGui 绘制）、`config_bridge`、`real_services`/`fake_engine`、`strings.hpp`（中英文案）、`dev_log` |
| `src/engine/` | `engine.cpp`（命令队列/快照/事件）、`engine_loop.cpp`（主循环，原 `run_bm_bridge`）、`engine_status.cpp`、`engine_devices_win.cpp`、`win_io.hpp`（串口与 WinMM 封装）、`ui_pipe_adapter.*`（遗留管道适配） |
| `src/app/` | `config`、`devices`、`radio_cat`、`bm_api`、`bm_servers`、`radio_identity`、`http_client`、`json` |
| `src/*.cpp`、`include/wirex/` | 协议与语音核心：HRI 帧/会话、DMRD/DMR 通话、AMBE+2 声码器、重采样、BM 会话、路由等 |
| `third_party/` | `imgui`（MIT）、`droidstar_mbe`（MBE/IMBE，GPL-3.0 + ISC，`source-manifest.json` 锁定 SHA-256）、`dmr_signal`（DMR FEC/LC，GPL-3.0） |

## 2. 线程模型

- **UI 线程**：`MsgWaitForMultipleObjectsEx` 等待窗口消息和一个唤醒事件。引擎和 CAT 服务通过 `set_wakeup` 回调 `SetEvent` 唤醒 UI；只在消息、唤醒或动画需要时重绘（引擎事件驱动重绘限速 10 fps，悬停/输入光标 10 fps，空闲时无限等待）。窗口逻辑尺寸 1360×900，最小 1180×780，按 DPI 缩放。收到 `WM_DEVICECHANGE` 时重新枚举设备，只刷新显示，不连接。
- **引擎线程**：`Engine::start()` 创建，运行原 `run_bm_bridge` 主循环；HRI 串口、WinMM（`CALLBACK_EVENT`）和 BM UDP 都在这个线程内驱动。
- **CAT 线程**：`real_services.cpp` 的 `CatRunner` 串行执行连接、应用、每秒轮询以及 FM 中继开启时约 100 ms 一次的静噪采样（第 9 节），内部通过 `app::CatWorker`（自带线程和可取消任务队列）访问串口。
- **HTTP 线程**：`BmApiRunner`（BM API，单任务串行）与 `IdentityRunner`（radioid.net，队列 16，请求间隔 ≥1 s，失败后指数冷却）。
- 服务回调都在后台线程触发，由 `ViewModel` 切回 UI 线程。`Services::shutdown` 停止并等待全部服务线程；`Engine` 析构时如仍在运行，会请求停止并有界等待 5 s。

## 3. 引擎接口：`include/wirex/engine.hpp`

三类通道，取代旧 control-v2 JSONL 与 `status.jsonl` 轮询：

- **命令**：`Engine` 的方法投递类型化命令，返回 `std::future<CommandResult>`。`CommandStatus` 取值：`accepted`、`idempotent`、`stale_revision`、`busy`、`not_ready`、`invalid`、`forbidden`、`failed`；附生效后的 `revision` 与机器可读 `detail`。主要命令：
  - 生命周期：`start(StartConfig)`、`stop()`、`stop_with_reason()`、`force_stop_now()`、`wait_stopped()`
  - BM：`configure_bm(BmTarget)`、`set_bm_connection(enabled, requested_revision)`
  - 电台：`connect_radio(RadioStartConfig)`、`disconnect_radio()`
  - 路由与音频：`replace_rx_policy`、`replace_tx_policy`、`quick_call_join`、`set_audio_gains`、`set_audio_endpoints`
  - FM 中继：`relay_fm_start()`、`relay_fm_stop()`（见下文“FM 中继上行”）
  - 其他：`upsert_radio_identity`、`manual_ptt_toggle()`（CLI 键盘诊断）
- **快照**：`snapshot()` 返回不可变 `shared_ptr<const Snapshot>`，每次发布 `seq` +1。内容包括 `phase`、`radio_error`、HRI/串口/音频打开状态与实际端口和 endpoint、`local_audio`（本机播放状态）、`bm_link`/`bm_error`/`bm_connection_revision`、`media_owner`、策略 revision、`active_rx_call`、增益、电平（最近 200 ms 增益后峰值，削波样本为累计值）和计数器。另有：
  - `network`（`NetworkQuality`）：RTT 取自 RPTPING/MSTPONG 往返（最近/平均/最小/最大/样本数，`rtt_valid`）；丢包按 DMRD 序号统计，分本次 BM 会话累计（`session_expected/missing`）与当前或最近一次通话（`call_expected/missing`）。主界面显示 RTT 与会话丢包率，悬停提示给出明细。
  - `last_filtered`（`FilteredTraffic`）：最近一次被收听策略过滤的 BM 流（源、目标、时隙、类型、时刻），只用于界面提示“有流量但未收听”，不参与路由。
  - `relay_fm_active`、`relay_fm_started_ms`（相对 `clock_origin_ms`，未在中继时为 0）。
  - `Counters` 除通话/数据报/重连/PTT 计数外，还有 `rx_filtered_datagrams`（BM 已送达但 Router 未准入的语音包数）和 `relay_fm_rejected_busy`（FM 中继 start 因占用被拒次数）。
- **事件**：`drain_events()` 取出离散事件（`rx_call_started/ended`、`tx_started/ended`、`bm_link_changed`、`quick_call_result`、`warning`、`fatal`、`relay_fm_started`、`relay_fm_ended`）。`relay_fm_*` 事件附 `RelayFmInfo`（本段 tx_policy 目标、开始时刻、时长），`relay_fm_ended` 的 `end_reason` 见下。队列上限 1024（`engine_internal.hpp`），溢出时丢弃最旧事件并计入 warning。
- **诊断钩子**：`StartConfig::diagnostics`（`DiagnosticsHooks`，`engine_diagnostics.hpp`）可选回调：`status`（兼容 `status.jsonl` 的状态行）、`console`（操作员提示）、`cleanup_complete`（收尾通知）、`serial`（HRI 串口每次读写的方向、帧类型与字节数，不含正文；供 dev 日志）、`rx_policy`（RX 策略生效时的可读摘要；供 dev 日志）。GUI 可全部留空。
- `Engine(std::shared_ptr<Devices>)` 可注入假设备（`engine_devices.hpp`），供 `engine_test` 使用。

**FM 中继上行**（`engine_loop.cpp`）：`relay_fm_start()` 复用手咪 PTT 上行管线（WaveIn → 增益 → AMBE → DMRD → BM），目标为当前 `tx_policy.target`，与手咪共用同一个 Router 发射许可。

- 返回值：`accepted`；`idempotent`（已在中继）；`forbidden`（发射关闭 `relay_fm_transmit_disabled`，或 CLI `manual_ptt` 模式 `relay_fm_manual_ptt_mode`）；`not_ready`（`relay_fm_bm_not_ready` / `relay_fm_radio_not_ready`，引擎停机中为 `engine_stopping`）；`busy`（手咪 PTT 上行中 `relay_fm_busy_ptt`，BM/HRI 下行进行中 `relay_fm_busy_downlink`，上行管线启动失败 `relay_fm_busy`），三种 busy 都计入 `relay_fm_rejected_busy`。
- 单段最长 `relay_fm_max_duration_ms` = 180 s（`StartConfig::relay_fm_max_duration_ms` 可调小供测试，0 为默认）。
- `relay_fm_stop()` 正常结束本段（`squelch_closed`），未在中继时 `idempotent`；终止帧发送失败时以 `aborted` 结束并返回 `failed`。
- `end_reason`：`squelch_closed`、`timeout`、`transmit_disabled`、`bm_not_ready`、`radio_lost`、`shutdown`、`aborted`（其他路径终止上行时按当时状态推断）。
- 中继进行中手咪松开不释放中继 lease；中继段只由静噪门控、超时或上述异常结束。

## 4. 电台与 BM 分开连接

- Engine runtime 与 BM 会话常驻；HRI 电台是可单独接入和断开的子系统。`StartConfig::start_radio=false` 时只启动 runtime 和 BM loop，`radio_start_error` 说明本次未打开电台的原因，不会自动尝试其他端口。
- `connect_radio` / `disconnect_radio` 只打开或收尾 HRI 串口与 USB 音频，不影响已连接的 BM。HRI 模板、串口打开或握手失败记入 `radio_error`，BM 继续运行。
- `set_bm_connection` 由 `bm_connection::ConnectionControl` 实现：关闭时先登记意图，等 TX/RX/HRI 有界收尾后发送 RPTCL，再关闭 UDP。`configure_bm` 失败后必须再成功配置一次才允许 enable，防止拿旧 profile 静默登录（`bm_profile_reconfigure_required`）。Master 拒绝认证时不自动重试。
- BM 会话：RPTL/RPTK/RPTC 登录，RPTPING 每 10 s 一次，60 s 无响应视为超时（`src/bm_session.cpp`）。
- GUI 侧（`view_model.cpp`）：启动时自动 `start`，按配置连接 BM；主界面“连接电台”同时发起 Engine `connect_radio` 和 CAT 连接，两侧分别报告状态，单侧成功不显示为全部成功。Fake 模式不自动连接。
- **启动组呼自动激活**（`src/gui/startup_group_activation.hpp`）：ViewModel 创建时冻结已保存频道顺序；BM 首次进入 `connected` 后逐个发送 Quick Call，不等待 HRI ready。排除私呼、TG4000（断开控制）、无效目标，重复 `(TG, TS)` 合并。同一时刻只有一项在发送；`busy` 每 500 ms 重试，BM 保持连接且持续 busy 30 s 后跳过当前及剩余目标；BM 断开时暂停，重连后继续未处理项。运行中新增的频道不进队列。`accepted` 只表示两帧已交给本机 UDP，不代表 BM 已确认订阅，界面文案不得写成“已加入”。

## 5. 无电台时 BM 来话本机播放

`include/wirex/bm_local_playback.hpp` 在每通 BM 来话被接纳时选一次路由：`radio`（HRI 就绪，经电台播放）、`local_output`（无电台，送到用户选择的 WaveOut）、`silent`（输出不可用，来话照常显示，PCM 有界静默排空）。这条路径不打开 HRI 串口，也不发送 T3/T0。通话中途输出丢失时转为 `silent` 继续收尾，后续重新选择可用输出即可恢复。输出解析见第 7 节 `resolve_audio_output`。

## 6. HRI Y 模板

- 已授权的 100 字节 Y 模板以 `constexpr` 数组编入 `include/wirex/approved_hri_y_template.hpp`，默认启动不再读取 `private/device-y.bin`。
- 同一头文件还给出 **AP PC 变体** `hri_y_template_ap`：只把 offset 0x05 改为 ASCII `'1'`，其余 99 字节与 DIRECT 相同。两个固定 SHA-256：
  - DIRECT：`82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f`
  - AP：`0cff0cc909604b83b04de3c06b7fdb46501885fde0cb34daee8a2951a6e638ca`
- `win_io::load_hri_y_template(path, body, ap_mode)`：路径为空时用内嵌模板（`ap_mode` 时用 AP 变体）；非空时必须是绝对路径且恰好 100 字节。随后校验 offset 5 并用 BCrypt 计算 SHA-256：
  - `ap_mode=false`：只接受 `'2'` 与 DIRECT 哈希（与中继功能加入前相同）。
  - `ap_mode=true`：接受 DIRECT 或 AP 两个哈希之一，通过后统一把 offset 5 设为 `'1'` 使用。
- `RadioStartConfig::ap_mode` 由 GUI 按 `relay.enabled` 设置（`view_model.cpp`），引擎据此选模板，并把 `hri_session::Config::ap_mode` 传给会话：`hri_session` 默认只接受 `y_body_[5] == '2'`，`ap_mode` 时另外接受 `'1'`。dev 日志记录本次使用的模板（`hri_y_template_direct` / `hri_y_template_ap`）。启动时随 `start()` 打开电台的路径（`StartConfig`）不带 `ap_mode`，只用 DIRECT；GUI 实际通过 `connect_radio` 连接电台。
- **动态 Y 正文（R132 P0）**：HRI 模式下电台每收到一次 Y 就按正文重设射频参数，PC 是功率/频率的权威来源。`src/hri_y_body.*` 以已批准模板为底板生成正文，白名单只有 `0x05`（DIRECT `'2'` / AP `'1'`）、`0x0C`（X→Y PTT 镜像，任意字节，更新时保留当前值）、`0x2F..0x32`（LCH 发射功率，`%04d`，单位 0.1 W，允许 50–500 且为 10 的倍数）；其余 94 字节与底板逐字节相同。默认 250（25 W）生成的正文与 DIRECT 模板逐字节一致。`Session::set_y_body` 经 `hri_y::validate` 后在下一次周期 Y 生效。
- 功率命令 `Engine::set_hri_tx_power(deciwatts)`；`RadioStartConfig::initial_tx_power_deciwatts` 使首条 Y 即为目标功率；HRI 正在向电台播放下行时请求记为 pending（`deferred_hri_downlink`），下行结束后应用；自动重连沿用最近设定值。Snapshot：`hri_y_tx_power_deciwatts`、`hri_y_tx_power_pending`；dev 日志 `y_tx_power=<dw>`。GUI 在 HRI 已连接时功率走“引擎 Y + CAT `PC` + 约 1.2 s 后 `PC;` 读回”，功率与模式/频率分开提交，结果写 `devices.desired_power_watts`。字段依据见父目录 `research/planning/R132_Y动态字段与官方生成时机.md`。
- HRI 串口固定 115200、8N1、无流控（`win_io::configure_serial`）。打开后先预排空（最多 250 ms / 4096 B，需 20 ms 安静），等待 V 响应最多 2500 ms，然后每 1000 ms 发 Y，等待 Y/0 最多 3000 ms（`hri_session.hpp`）。

## 7. 设备自动识别（`src/app/devices.cpp`）

串口来自注册表 `HARDWARE\DEVICEMAP\SERIALCOMM` 与 SetupAPI（`GUID_DEVCLASS_PORTS`），按 COM 名合并：

- **HRI**：实例/硬件 ID 含 `VID_26AA&PID_0030`，或友好名/ID 中出现独立单词 `HRI`。`resolve_port_selection`：已保存端口且当前唯一存在则沿用，否则仅当恰好一个 HRI 口时自动选中；设置默认值优先 HRI 中的 COM5。
- **CAT**：非 HRI 口按描述打分：CP210x/CP2105 + Enhanced 或 `MI_00`、`VID_10C4&PID_EA70`+`MI_00` 为 300；CP2105 250；CP210x 220；`VID_10C4` 180；USB serial / USB-to-UART 100。优先级：手动输入 > 已保存且存在 > 最高分且唯一。与 HRI 相同或被识别为 HRI 的端口一律拒绝。
- **音频**：可用 = 支持 48 kHz 单声道 16 位且有 endpoint ID。电台音频 Auto（`resolve_audio_endpoints`）只在 HRI 已唯一识别时考虑，要求输入、输出各恰好一个名字含 `USB Audio` 的可用设备；显式 endpoint 必须唯一枚举到。BM 本机播放（`resolve_audio_output`）独立解析：Auto 取唯一的 USB Audio 输出，没有则取唯一可用输出，否则报错让用户选择。
- 不逐口试连；候选不唯一时保留歧义并提示手动选择。Auto 只用于显示和启动解析，不把具体 ID 写回配置。

## 8. 配置：`config.json`

- 位置：`WirexBridge.exe` 同目录（可用 `--config` 覆盖），不存在时生成默认配置。明文保存凭据，不进 Git 或发布包。
- 规则：`schema_version` 必须为 1；上限 128 KiB；严格 UTF-8 JSON，拒绝重复键和转义键名；必需字段缺失时拒绝并保留原文件。保存时写临时文件后 `ReplaceFileW` / `MoveFileExW` 原子替换，并保留未知字段（`AppConfig::document`）。
- 字段（默认值见 `include/wirex/app/config.hpp`）：
  - `connection`：`callsign`、`gateway_id`、`source_id`、`master`（`43.129.83.124`）、`master_port`（62031）、`color_code`（1）、`password`、`api_key`
  - `devices`：`hri_port`/`cat_port`（`auto`），`serial_port` 为旧别名（始终等于 `hri_port`）；`cat_baud_rate`（38400）、`cat_stop_bits`（`Two`）；`wave_in_endpoint_id`/`wave_out_endpoint_id`（`auto`）；`desired_power_watts`（25）
  - `audio`：`radio_playback_gain`（1.0）、`mic_transmit_gain`（16.0），内存中以千分值保存（`*_gain_milli`，范围 250–16000）
  - `channels`、`tx_channel_id`（默认 `private:460997:2`，BM 鹦鹉）、`routing.blocked_source_ids`
  - `ui`：`bm_server_selection_id`（`bm-china-4602`）、`legacy_rx_policy`、`language`（`zh-CN`/`en-US`）；`window`
  - `relay`（可选根节，仅原生版使用；PS 侧按未知节保留）：`enabled`（中继总开关，连接电台时使用 AP Y 模板）、`fm_enabled`（FM 中继），默认均为 false。缺节或缺字段视为 false；存在时必须是对象且两个字段为布尔值，其他成员原样保留。保存时只有文件中已有该节或任一开关为 true 才写入，默认配置与 PS 生成的字节保持一致。
- 界面右上角语言按钮切换中英文并写回 `ui.language`。RadioID 缓存位于 `<exe>/private/runtime/radio-identity-cache.json`。
- FM 中继记录追加写 `<exe>/private/runtime/relay-log.jsonl`（行由 `view_model.cpp` 生成，`real_services.cpp` 追加），每段一行，不含凭据：`started_utc`（ISO 8601 UTC）、`duration_ms`、`target_kind`（`group`/`private`）、`target_id`、`slot`（1/2）、`s_meter_peak`（开门期间 `SM0` 最大值，无读数为 `null`）、`end_reason`（引擎结束原因）。写入失败只记 dev 日志。

## 9. CAT 与 BM API

- **CAT**（`src/app/radio_cat.cpp`）：CAT-1 串口，8N2，波特率取配置（4800/9600/19200/38400/115200）。界面波特率只作用于 CAT，与 HRI 无关。只有可信只读查询成功后才发布 `CatState.connected`；设置模式/频率要求 Engine `phase==stopped`；设置功率要求核心已停止，或运行中无活动来话、无发射且接收媒体空闲（`real_services.cpp` 用 `media_owner==idle` 近似“接收队列为空”）。
- **FM 中继静噪采样**：`relay.enabled`、`relay.fm_enabled` 都为 true 且 CAT 已连接时，ViewModel 打开 `CatService::set_squelch_polling`。`CatRunner` 线程约每 100 ms 做一次只读短会话 `CatClient::query_squelch`：打开 CAT 口、发 `RI0;`（必须得到通过 `radio_info::parse` 的 11 字节应答）、再尽力发 `SM0;`（失败只让 S 表值为空），然后关闭；会话期限 400 ms，不发 ID/AI，不改写授权或观测值，与 1 s 周期查询和其他 CAT 任务串行（CAT 忙时跳过）。
- 结果交给 `radio_info::SquelchGate`（`src/app/radio_info.*`）：`RI0;` 的 P8 为 SQL、P4 为 TX；连续 2 次 SQL 开才开门；SQL 关持续 600 ms 才关门；电台发射（P4≠0）或连续 1 s 无有效采样立即关门。开门事件触发引擎 `relay_fm_start()`，关门触发 `relay_fm_stop()`；轮询关闭、CAT 断开或电台 ID 不符时门控复位，若门处于开启状态则发 closed。开门期间记录 `SM0` 峰值用于中继记录。
- **BM API**：`https://api.brandmeister.network/v2/`，Bearer API Key；用于静态组查询与增删。动态组用 Quick Call 激活。
- **BM Master 列表**：`src/app/bm_servers.cpp` 内置离线快照，默认 `bm-china-4602`。

## 10. dev 日志（`src/gui/dev_log.*`）

- 开发版（`WIREX_DEV_BUILD=1`）默认开启，正式版（`=0`）默认关闭；命令行 `--dev-log` / `--no-dev-log` 覆盖默认值。
- 输出到 `<exe 目录>/logs/wirex-<本地时间>.log`，每行带时间戳并立即 flush；打开失败不影响运行。
- 记录：引擎状态行（与旧 `status.jsonl` 同字段）、操作员提示、GUI 操作结果、HRI 串口帧类型与字节数。不记录 BM 密码、API Key、串口正文和音频数据。

## 11. GUI 命令行

- 无参数：真实引擎 + 真实服务（需以 `WIREX_GUI_REAL_ENGINE=1` 编译，`build-gui.ps1` 已设置）。
- `--fake`：模拟引擎 + 真实服务；`--fake --fake-services`：完全离线。
- `--config <json>`、`--screenshot <png>`（渲染后保存并退出）、`--check-config`（生成/读取/写回检查后退出，0 为成功）、`--dev-log`、`--no-dev-log`。
- `--lang zh-CN|en-US`：覆盖 `ui.language`，只作用于本次运行，不保存。
- 截图验收专用（必须同时带 `--fake` 与 `--screenshot`）：`--screenshot-modal remove-static`（打开“移除静态组”确认弹窗后截图）、`--screenshot-relay-demo`（在内存中开启中继与 FM 并注入一段 FM 中继历史，不写配置）。

## 12. 构建与测试

所有 `.ps1` 为 Windows PowerShell 5.1 脚本，须保存为 UTF-8 BOM；从 Git Bash 调用前重置 `PSModulePath`（见 HANDOFF）。

| 用途 | 入口 |
| --- | --- |
| GUI（单 EXE） | `wirex build --gui`，或 `tools/build-gui.ps1 [-Release]`；`-Release` 编译 `WIREX_DEV_BUILD=0`，默认为开发版。产物 `build/_work/wirex-gui-<commit7>[-dirty]-<UTC>/WirexBridge.exe`，附 provenance；项目代码 `/W4 /WX`，ImGui 单独 `/W3` |
| Native 核心 + 测试 | `tools/build-bm-bridge.ps1 [-CompileOnly]`（`wirex build`）；Native 测试 41 项（`CMakeLists.txt` 中 41 个 `add_test`，含 `engine_test`） |
| app / GUI 逻辑测试 | `tools/build-app-tests.ps1`：18 个目标（config、devices、RI0 解析与静噪门控、CAT、BM API、RadioID、config_bridge、fake CAT、CAT 表单、本机播放、启动组呼、各 ViewModel 场景含静态组同步与 FM 中继），输出 `build/app-tests/` |
| 重复 ImGui ID 检查 | `tools/run-gui-duplicate-item-harness.ps1` |
| 打包 | 单 EXE 的 ZIP profile 尚未建立；`tools/package-release.ps1`、`ZipOnlyRelease.psm1` 仍是旧 WPF 包的 profile |

测试使用 fake 串口、fake WaveOut 和 localhost 假 Master，不接触真实设备或网络。

## 13. 遗留（待退役）

以下内容仍在仓库中，供实机验收对照，验收通过后删除：

- `ui/windows/`（PowerShell 5.1 + WPF 界面）、`ui/launcher/`（C# launcher）、`tools/start-*.ps1`。
- `runtime/wirex_bridge.exe`（`src/probe_main.cpp`，`WIREX_ENABLE_BM_BRIDGE`）的 `--ui-pipe --ui-control-version 2` 模式，现由 `src/engine/ui_pipe_adapter.cpp` 在 Engine 之上实现 control-v2 JSONL 与 `status.jsonl`。
- 旧链路：launcher → `powershell.exe -STA` → WPF → 匿名管道 → `wirex_bridge.exe`。v0.1.0 包及其 `runtime/docs/` 文档按这条链路发布。
