# WIREX Bridge 待办与架构演进清单

更新时间：2026-11-05。权威版本为 `app/TODO.md`，父工作区根目录保留同步副本。当前状态摘要见 [HANDOFF](HANDOFF.md)，架构见 [ARCHITECTURE](docs/ARCHITECTURE.md)。

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
- [ ] HRI 实机连接：按 `FTX1_project/_bisect/` 5 个目录二分排查（方法见 HANDOFF），定位并修复。
- [ ] 不带 `--fake` 启动，验证 HRI/CAT 串口、BM 连接、BM-only 本机播放、Quick Call、CAT 门控、身份写回、关窗有界收尾。
- [ ] TG46001 动态组真实收听：首次激活、再次激活、多组切换，以及启动组呼自动激活与 BM 连接的联动。已确认的鹦鹉私呼和 TG91 收听不列为待办。
- [ ] BM RTT 接入 `Snapshot` 与主界面（当前显示“暂无数据”）。
- [ ] 125% DPI 下验收字体、控件边界；人工验证 IME 中文输入与候选窗。
- [ ] 确认窗口与任务栏图标正常显示。

### 1.2 电台与射频实机核对
- [ ] BM 与 FM/C4FM 射频双向联测：确认实际模式和路径后，分别完成 RF→BM 与 BM→RF。
- [ ] 实机核对 CAT 指令能否开启/关闭 HRI、切换 DIRECT/AP，以及读写模式、频率和功率；没有对应指令的列出需在电台菜单手动设置的项目。
- [ ] FTX-1 LCD 显示可重复性观察：先核对官方说明，再按可重复步骤观察；软件状态或 PC 面板文字不作为 LCD 证据。
- [ ] 获准听音时对照回放与上行增益、削波统计和主观音质。

### 1.3 AP PC 中继（RF ↔ BM）

背景研究：父工作区 `WIREX_Bridge/docs/17_AP_PC模式RF转发与握手判定机制.md`。当前 `hri_session.cpp` 与 `win_io::load_hri_y_template` 都要求 Y 模板 offset 0x05 为 `'2'`（DIRECT），上行只由手咪 PTT（X 记录）与声卡录音驱动。

- [ ] **独立开关，默认关闭**：中继功能有单独的启用开关，关闭时行为与当前完全一致。
- [ ] **右上角按钮**：标题栏右侧放中英文切换（已有）与中继开关两个按钮。
- [ ] **Y 模板 AP 变体**：随中继功能一起做 offset 0x05 为 `'1'`（AP）的模板变体，放宽 `hri_session` 与模板校验；只在中继开启时使用，DIRECT 模板与 SHA-256 校验保持不变。
- [ ] **默认 C4FM 中继**：中继开启后默认走 C4FM。解析 HRI 的 `G`（呼叫头，取呼号）、`R`（语音帧）、`P`/`E`（起止与结束）记录，AMBE 直接转发到 BM，不经声卡和本地声码器重编码。
- [ ] **FM 中继（需单独再开启）**：在中继开关之外另设 FM 开关。通过 CAT `RI0;` 轮询 SQL 状态，开门时启动声卡采集，软件 AMBE 编码后发往 BM，关门时结束。这是官方未支持的功能，界面需明确标注。
- [ ] **记录传入用户**：C4FM 从 `G` 记录取呼号；FM 无呼号，记录开始时间与时长。
- [ ] **半双工仲裁**：在 `engine_loop` 中仲裁 RF 上行与 BM 下行发射，同一时刻只允许一个方向，防止冲突与射频回环；梳理 BM 下行触发电台发射的键控方式（HRI 协议键控与 CAT 键控）。

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

- [ ] 为单 EXE 建立 ZIP profile（`WirexBridge.exe` + 所需 `licenses/`，不再带 `private/device-y.bin`），由 `wirex package` 生成，剔除用户配置、日志与审计材料。
- [ ] 在干净目录验证首次启动生成默认配置、`--check-config`，以及退出时线程全部结束、无残留进程。
- [ ] 生成 manifest 与 `SHA256SUMS.txt`，验证下载完整性。
- [ ] 端到端实机通话联测；输出重构前后文件数、包体积、内存占用与启动耗时对比。
