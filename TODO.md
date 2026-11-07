# WIREX Bridge 待办与架构演进清单

更新时间：2026-11-07。权威版本为 `app/TODO.md`，父工作区根目录保留同步副本。当前状态摘要见 [HANDOFF](HANDOFF.md)，架构见 [ARCHITECTURE](docs/ARCHITECTURE.md)。

---

## 零、音频解码与播放断续/破音专项

现象：BM 下行经本机 WaveOut 或电台播放时，每隔数十到上百毫秒出现短暂断音，并伴有密集“兹拉”破音。离线测试全部通过，问题只在真实听音中出现。另有 agent 正在修复，以下为待验证的候选根因，不是已确认结论。

- [ ] 播放在飞帧上限仅 3 帧（20 ms/帧 = 60 ms），调度抖动即可能欠载：`include/wirex/bm_voice_pipeline.hpp` `max_unconfirmed_playback_frames`，`src/bm_voice_pipeline.cpp` `take_playback_pcm`。
- [ ] RX 调度迟到超过 20 ms 时重锚到 `now + voice_period`，可能放大空洞：`voice_schedule_reanchor_lateness`，`src/bm_voice_pipeline.cpp` `tick_rx`。
- [ ] `WaveOutput` 缓冲只有 4 块，且与 `WaveInput::buffer_count` 绑定：`src/engine/win_io.hpp` `WaveOutput::buffer_count`。
- [x] ~~`reap()` 复用缓冲时未清除 `WHDR_DONE`~~：经源码核对不成立，`waveOutWrite` 提交时会自行清除该标志。
- [ ] 丢包/补帧时直接插入全 0 帧，无淡入淡出：`src/bm_voice_pipeline.cpp` 中 `playback_frames_[...].pcm.fill(0)`；同时核对重采样器历史是否在来话中被重置（`pcm_resampler`）。
- [ ] 声码器输出增益（`third_party/droidstar_mbe/upstream/mbe/mbevocoder.cpp` `processAudio`）：是否偏低待测量后再定，暂不改动。
- [ ] 验收：Native 41 项与 app 测试全部通过、0 warning；真实 BM 语音流听音无断续与破音；CPU 占用保持轻量。

---

## 一、当前业务验收（短期优先）

### 1.1 R128 实机验收
- [x] HRI 实机连接不上：已修复 `clock_regressed`（`a50b234`，`connect_radio` 后重新取主循环时钟）。
- [ ] 不带 `--fake` 启动，验证 HRI/CAT 串口、BM 连接、BM-only 本机播放、Quick Call、CAT 门控、身份写回、关窗有界收尾。
- [ ] TG46001 动态组真实收听：首次激活、再次激活、多组切换，以及启动组呼自动激活与 BM 连接的联动。已确认的鹦鹉私呼和 TG91 收听不列为待办。
- [x] BM RTT 与丢包接入 `Snapshot::network` 与主界面。
- [ ] 125% DPI 下验收字体、控件边界；人工验证 IME 中文输入与候选窗。
- [ ] 确认窗口与任务栏图标正常显示。

### 1.2 电台与射频实机核对
- [ ] BM 与 FM/C4FM 射频双向联测：确认实际模式和路径后，分别完成 RF→BM 与 BM→RF。
- [ ] 实机核对 CAT 指令能否开启/关闭 HRI、切换 DIRECT/AP，以及读写模式、频率和功率；没有对应指令的列出需在电台菜单手动设置的项目。
- [ ] FTX-1 LCD 显示可重复性观察：先核对官方说明，再按可重复步骤观察；软件状态或 PC 面板文字不作为 LCD 证据。
- [ ] 获准听音时对照回放与上行增益、削波统计和主观音质。

### 1.2b HRI 模式下功率被 Y 记录重置（R132）

- 根因已确认（2026-11-07 实机日志）：Y 正文 `2f..32`（R57：`LCH_TXPWR`，单位 0.1 W）在内嵌模板中为 `0250`，电台每收到一次 Y 就把功率重设为 25 W；CAT `PC` 写入只能维持到下一次 Y。
- [x] **R132 逆向研究已闭环**：Q1–Q6 逆向研究、C4FM/FM 制式与全 100 字节字段解密已完成。见报告 [R132_Y动态字段与官方生成时机](../research/planning/R132_Y动态字段与官方生成时机.md) 及 [HANDOFF_Y记录动态生成](../HANDOFF_Y记录动态生成.md)。
- [x] **P0 实施**（`71565d4..d275bbc`）：Y 正文构造器（白名单 `05`、`0C`、`2f..32`，功率 5–50 W 整瓦）→ 引擎 `set_hri_tx_power`（下行中 pending、重连保持、首条 Y 即目标功率）→ GUI/CAT 联动与持久化。Native 42/42、app 20 项、GUI 0 warning。
- [x] 实机（2026-11-07）：5 W / 10 W 经 Y 下发后周期 `PC;` 读回保持（不再弹回 25 W）；电台屏幕不回显 → R133 加 CAT `PC2` 回显。
- [x] UI 回归：自动组呼汇总改单行省略 + tooltip（R133），1360×900 两侧无滚动条。
- [x] **R133 频率/调制（P1）**（`3165915..850e761`，约定见父目录 `R133_接口约定.md`）：白名单加 `0x0E`（'1' FM / '2' C4FM-DN）与 `0x10..0x19`（Hz，仅 144–148 / 430–440 MHz，1 kHz 整倍）；频偏不开放；功率/频率/模式同一份 Y 字段状态，下行中 pending、重连保持；GUI HRI 已连接时频率/模式只走 Y（不发 CAT `FA`/`MD`）+ 约 1.2 s 读回，功率走 Y + CAT `PC2` 回显；`devices.hri_frequency_hz`/`hri_mode` 持久化（默认不写入，PS 默认配置逐字节兼容）。Native 42/42、app 20 项、GUI 0 warning。
- [x] 实机确认 R133（2026-11-07）：频率与模式调节生效。
- [x] **R134 手咪 PTT 电台不发射**（2026-11-07 `_bisect/13` 日志）：X[0x0C]='2' 被识别、软件开始上行，但 PTT 期间 CAT 一直 `TX0;`，采集到的是接收底噪（RMS −26 dBFS、峰值恒 3400；正常版本讲话为 −63~−48 dBFS）。此时已是 FM（非 C4FM 引起）。与旧正常版本的差异只剩 Y 中 LCH 频率/功率不再是模板值（145.2 MHz / 5 W）及曾切过一次 C4FM。`a7fa513` 已在 dev 日志加 Y/X 字节转储与 `ptt_pressed_but_radio_not_transmitting` 告警。**已解决**：2026-11-07 重测 `_bisect/14`，PTT、频率、功率、模式均正常，问题未复现。
- [x] R134 停用/激活动态组遇来话返回 `media_busy` 但 GUI 仍移出收听，BM 持续占用 TS2 导致鹦鹉回声延迟或丢失（FM 中继“只回一次”的真正原因）：引擎排队待来话结束执行（`73f2786`），GUI 仅在引擎接受后移出（`f2c9f0f`）。
- [x] R134 Y 功率延后时不再立即发 CAT `PC` 回显（之前被拒 `write_not_authorized`）；频率/模式读回等 pending 清除（`c1db99a`）；选择 C4FM-DN 显示“PC 语音不支持”（`f73d536`、`7f51526`）。
- [ ] engine_test 音频设备切换断言偶发失败一次（基线 1b9def2 即有，重跑通过），时序原因待查。

### 1.3 AP PC 中继（RF ↔ BM）

背景研究：父工作区 `WIREX_Bridge/docs/17_AP_PC模式RF转发与握手判定机制.md`。FM 中继已实现（`914b346..27e4da4`，行为规则见 [R128_NATIVE_GUI](docs/R128_NATIVE_GUI.md)“FM 中继”）；中继关闭时 `hri_session.cpp` 与 `win_io::load_hri_y_template` 仍只接受 offset 0x05 为 `'2'`（DIRECT）。

- [x] **独立开关，默认关闭**：`config.json` 可选根节 `relay`（`enabled`、`fm_enabled`，默认 false）；关闭时行为与之前一致。
- [x] **右上角按钮**：标题栏右侧为中英文切换与“启用中继 / 停用中继”；中继开启时再出现 FM 按钮。
- [x] **Y 模板 AP 变体**：offset 0x05 为 `'1'`，SHA-256 `0cff0cc9…e638ca`；只在中继开启（`RadioStartConfig::ap_mode`）时使用，`hri_session` 仅在 ap_mode 下额外接受 `'1'`；DIRECT 模板与哈希不变（`914b346`）。
- [ ] **默认 C4FM 中继**：中继开启后默认走 C4FM。解析 HRI 的 `G`（呼叫头，取呼号）、`R`（语音帧）、`P`/`E`（起止与结束）记录，AMBE 直接转发到 BM，不经声卡和本地声码器重编码。
  - **前置阻塞（2026-11-06 核对）**：`G` 记录的 68 字节头与目的/源呼号偏移已有静态证据（`docs/research/HRI数字记录与调制研究进度.md`），但 **`R` 记录正文到 AMBE/YSF 帧的格式没有恢复**（静态研究只证明官方程序把 R 字符串原样封进 RAW 转发）。须先在 AP 模式下用 dev 日志抓取真实 `G/R/P/E` 记录（需单独的正文采集开关），对照 `ysf_vd2_vch` / `ambe2450_parameters` 离线模块确认帧结构后才能实现。
- [x] **FM 中继（需单独再开启）**：在中继开关之外另设 FM 开关。通过 CAT `RI0;` 轮询 SQL 状态，开门时启动声卡采集，软件 AMBE 编码后发往 BM，关门时结束。这是官方未支持的功能，界面需明确标注。
  - [x] `RI0;` 应答解析与静噪门控（`src/app/radio_info.*`，`857e5ff`）：P8 为 SQL、P4 为 TX；连续 2 次开门、600 ms 挂起关门、电台发射或 CAT 失联 1 s 立即关门。
  - [x] CAT 周期查询：中继与 FM 都开启且 CAT 已连接时，每 100 ms 只读短会话 `RI0;`+`SM0;`（`real_services.cpp` `CatRunner`）；门控事件 → 引擎 `relay_fm_start()`/`relay_fm_stop()` → WaveIn 采集 + AMBE 编码 + BM 上行（复用手咪 PTT 上行管线，单段最长 180 s）。
  - [x] 实机确认 FM 开门时 P8 变为 1（2026-11-06，145.200 MHz：按键后下一次 100 ms 轮询内 P8 0→1，松开后回 0）。
  - [x] 实机验证 AP 模板与 DIRECT 模板在 AP PC 电台上的握手（2026-11-06：两者都能握手，中继效果无区别；中继默认改回 DIRECT，`relay.y_template` 可选 `ap`）。
  - [x] 实机验证 FM 中继端到端（2026-11-06：RF → BM 有效）。
  - [ ] 实机确认尾音修复：120 ms 前瞻 + hang 期间上行静音（R131 `relay_fm_mute`）是否消除松手后 0.5–1 s 的尾噪；语句间短停顿是否被截字；多出的 120 ms 延迟是否可接受。
  - [ ] 100 ms CAT 轮询负载：确认对 CAT 口、1 s 周期查询与 CAT 设置操作的影响。
- [ ] **记录传入用户**：
  - [x] FM：无呼号，来话历史黄色“FM 中继 → TG …”，并追加 `<exe>/private/runtime/relay-log.jsonl`（开始时间、时长、目标、时隙、S 表峰值、结束原因）。
  - [ ] C4FM：从 `G` 记录取呼号。
- [ ] **半双工仲裁**（FM 部分已完成，C4FM 待做）：在 `engine_loop` 中仲裁 RF 上行与 BM 下行发射，同一时刻只允许一个方向，防止冲突与射频回环；梳理 BM 下行触发电台发射的键控方式（HRI 协议键控与 CAT 键控）。
  - [x] FM：与手咪共用一个 Router 发射许可；中继上行时 BM 来话按 Router 规则拒绝；下行进行中拒绝中继启动（`relay_fm_busy_downlink`）；手咪不能打断或结束中继段。
  - [ ] C4FM。

---

## 二、客户端交互与多语言（i18n）

### 2.1 中英文支持
- [x] 原生 GUI 右上角语言按钮可实时切换中英文，偏好写回 `config.json` 的 `ui.language`（`src/gui/app_view.cpp`、`strings.hpp`）。
- [ ] 完整翻译覆盖：逐页核对英文界面无中文残留（设备解析原因等部分文案目前只在中文界面显示），并人工验收真实英文界面。
- [ ] 验证语言偏好在首次生成、损坏恢复、手动编辑配置等情况下的保存与读取。

---

## 三、架构现代化（中长期）

### 3.1 代码库瘦身
- [ ] 核心 C++ 协议资产（`dmrd`、HRI 协议、`direct_frame` 及 golden 离线测试）在退役旧 UI 时保持不变。
- [x] 历史归档剥离主树（R127，已压缩到 `FTX1_project/_archive/` 并删除）。
- [x] `.gitignore` 规范化（R127，`1283f86`）。

### 3.2 Go 运维工具链
- [ ] `tools/wirex`：已有 doctor/build/test/package，`build --gui` 已接入；build/package 仍包装 ps1，`--cmake` 路径未在本机验证。下一步改用 Go 原生实现后删除对应 ps1。
- [ ] 网络抓包与协议回放测试只保留少量清晰的验证脚本。

### 3.3 全 C++ 原生 UI（R128）
- [x] 技术栈：Dear ImGui + Win32 + DirectX 11，单个 `WirexBridge.exe`（设计见 [R128_NATIVE_GUI](docs/R128_NATIVE_GUI.md)）。
- [x] 消除跨进程 IPC：进程内 `engine::Engine`（命令 future / 不可变快照 / 有界事件队列），UI、引擎、CAT、HTTP 分线程。
- [x] config、设备枚举、CAT、BM API、RadioID 用 C++/Win32 重写（`src/app/`）。
- [x] 电台与 BM 分开连接；无电台时 BM 来话本机播放；启动组呼自动激活。
- [x] HRI Y 模板内嵌（`include/wirex/approved_hri_y_template.hpp`，SHA-256 校验）。
- [x] 隐藏 dev 日志（`src/gui/dev_log.*`，`--dev-log` / `--no-dev-log`）。
- [ ] 实机验收通过后，删除 `ui/windows/`、launcher、`tools/start-*.ps1` 与 `--ui-pipe` 适配层，彻底移除 PowerShell 5.1 胶水层。
- [ ] 评估是否需要从 WinMM 切到 WASAPI（视音频专项结果再定）。

---

## 四、打包分发与端到端验证

- [x] v0.2.0 单 EXE ZIP profile：`wirex build --gui --release` + `wirex package-gui --version v0.2.0`（Go 原生，精确清单：exe + licenses + README；确定性 ZIP、`SHA256SUMS.txt`、`manifest.json`）。
- [x] 干净目录冒烟（2026-11-07，release 构建）：首次启动生成无个人数据的默认配置；正式版无 dev 日志；关窗 10 s 内退出无残留；仅系统 DLL。
- [ ] 冒烟遗留：损坏配置不备份且 `--check-config` 静默（仅退出码 3）；`--fake` 也会创建 `private/runtime/` 并访问 RadioID.net；`icuuc.dll` 需 Win10 1703+；`build-gui.ps1` 在 `NoDefaultCurrentDirectoryInExePath=1` 下 vswhere 失败（Invoke-MsvcStep 内临时清除）。
- [ ] engine_test 音频设备切换断言偶发失败（基线即有），时序原因待查。
- [ ] 端到端实机通话联测；输出重构前后文件数、包体积、内存占用与启动耗时对比。
