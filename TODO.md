# WIREX Bridge 待办与架构演进清单

更新时间：2026-11-05。权威版本为 `app/TODO.md`；父工作区根目录与 worktree 根目录同步保持一致。

---

## R128 当前交接与待核查（2026-11-05）

- **HRI 实机连接：** 用户报告当前版本无法连接；“两串口波特率混淆”仍是待证假说。源码路径相对 `app/`：HRI 为 115200、8N1；CAT 按配置波特率、8N2 工作且默认 38400，界面波特率只控制 CAT。待核实 COM 与设备对应、电台当前设置、旧/新版本差异及 V/Y 收发记录。实机操作须先取得用户授权，保留现有配置且不发射。
- **BM/射频：** BM 本机 WaveOut 离线测试通过，真实 BM 来话听音待验；AP/PC C4FM/FM 转发尚未实现，旧文档中的相关推断待证。
- **界面/交付：** 100% DPI 同尺寸截图只显示有限的字体边缘改善，125% 未验证。本机 R128 单 EXE `a7081af` 未推送；交付时目录仅有 EXE，运行后生成 `config.json` 和 `private/`，现存文件保留。

> 下方预先存在的音频专项全文保持原样；其中根因判断与修复建议仍待验证，不作为已确认事实。

---

## 零、 音频解码与播放断续/破音专项修复任务（交给 Claude 的完整 Prompt）

> **使用说明**：以下是一份可以直接复制并完整提供给 Claude（或下一任开发 Agent）的任务提示词（Prompt）。它详细阐述了当前版本音频在真实播放时出现“短暂断开抽搐”与“密集兹拉爆音”的深层根因，并给出了精准的文件位置、修复指导原则与回归验收标准。

```markdown
# 任务目标：彻底修复 WIREX Bridge 音频播放“很短暂的断开感”与“兹拉兹拉破音/爆音”

## 一、 背景与故障现象
在 WIREX Bridge 当前版本（基于 R128 原生 GUI / BM 本机播放与电台链路）中，通过本机声卡（WaveOut）或电台扬声器收听 BrandMeister (BM) 下行音频时，虽然离线 41 项 Native 自动化测试全绿，但真实听感存在明显缺陷：
1. **很短暂的断开感**：声音连续性差，每隔数十至上百毫秒就出现微小的抽搐、停顿与音频空白；
2. **兹拉兹拉的声音**：伴随断音出现密集、刺耳的电杂音、咔嗒声（Clicks / Pops / Glitches）。

---

## 二、 深度根因分析（已完成代码级审计）

经过对代码库的完整排查，问题并不是 DMR 协议解析错误或 AMBE 解码算法崩溃，而是**音频驱动缓冲深度极度苛刻、调度时钟脱节、以及双缓冲复用瑕疵共同导致的“高频声卡欠载（Buffer Underrun）”与“波形硬阶跃”**：

### 1. 声卡“在飞（In-flight）缓冲”上限仅 60ms（最核心瓶颈）
- **定位**：`app/include/wirex/bm_voice_pipeline.hpp`（第 26 行）及 `app/src/bm_voice_pipeline.cpp`（`take_playback_pcm` 第 884 行）：
  ```cpp
  inline constexpr std::size_t max_unconfirmed_playback_frames = 3U;
  ```
- **分析**：
  - 每帧 PCM 仅 20ms（48 kHz 下 960 个样本，`Pcm48Frame`）。
  - 管线强制限制 `playback_inflight_ == max_unconfirmed_playback_frames` 时直接拒绝输出新 PCM 帧。
  - 这导致在 Windows WaveOut 驱动队列中流转的音频数据**最多只能排队 3 帧 = 60ms**！
  - 硬件声卡 DAC 依靠板载石英晶振以严格恒定速率（48000 Hz）消耗这 60ms 音频；而 Windows 用户态普通线程调度、锁竞争、UI 渲染和定时器（默认 5~15.6ms）存在天然的 Jitter。一旦供给稍有 5~10ms 延迟，声卡硬件缓冲区便瞬间播空，发生 **Buffer Underrun（欠载）**！
  - 欠载时声卡静音（产生**很短暂的断开感**）；新数据再次送入声卡时波形瞬间从 0 突变阶跃，喇叭产生冲击爆音（Click/Pop）；每隔数十毫秒发生一次，连贯起来就是**密集的“兹拉兹拉”电杂音**。

### 2. `tick_rx` 的 20ms Reanchor 惩罚性推迟放大卡顿
- **定位**：`app/src/bm_voice_pipeline.cpp`（`tick_rx` 第 1253 行）：
  ```cpp
  next_rx_due_ = rx_lateness > voice_schedule_reanchor_lateness
      ? now + voice_period
      : next_rx_due_ + voice_period;
  ```
- **分析**：
  - `voice_schedule_reanchor_lateness` 设为了极短的 **20ms**。
  - 当系统发生微小线程调度滞后（`rx_lateness > 20ms`），RX 端本应尽快将已解码的帧送出填补声卡饥饿，但代码反而将 `next_rx_due_` 强行重锚定到 `now + 60ms`（`voice_period`），导致下一次解码被**额外延后 60ms**，直接在声卡输出中撕开一个巨大的空洞。

### 3. `WaveOutput` 缓冲数量过小且复用未清 `WHDR_DONE`
- **定位**：`app/src/engine/win_io.hpp`（`WaveOutput` 类）：
  ```cpp
  static constexpr std::size_t buffer_count = WaveInput::buffer_count; // 仅 4 个缓冲
  ```
- **分析**：
  - 4 个缓冲若每块只填 20ms，总容量仅 80ms，且受制于上述 3 帧上限，起不到防抖（Jitter Buffer）作用。
  - 在 `reap()` 回收已播放的 buffer 时，代码仅设置了 `buffer.queued = false`，但**没有清除 `buffer.header.dwFlags` 中的 `WHDR_DONE` 标志位**。
  - 部分 Windows 声卡驱动在重复传入未清 `WHDR_DONE` 的 `WAVEHDR` 时，会导致下一次 `reap()` 立即误判该块“已播放完成”，在声卡 DAC 正在读取时就提前将新帧覆写进去（Buffer Tearing / 内存踩踏），产生刺耳的毛刺杂音。

### 4. 丢包/网络抖动补偿时硬塞全 0 导致方波冲击
- **定位**：`app/src/bm_voice_pipeline.cpp`（第 1223 行）：
  ```cpp
  playback_frames_[write].pcm.fill(0);
  ```
- **分析**：
  - 遇到丢失包或轻微乱序时，直接硬插入全 0 帧，且未通知 `PcmResampler8To48`，在非零采样与 0 之间没有任何淡入淡出（Cross-fade / Windowing），造成波形垂直截断并引发破音。

### 5. 声码器未做标准标度增益放大底噪与毛刺
- **定位**：`app/third_party/droidstar_mbe/upstream/mbe/mbevocoder.cpp`（`processAudio`）：
  - `mbe_processAmbe3600x2450Framef` 输出的 float 幅度标准约为 1000~4000，原版 mbelib 在 `mbe_floattoshort` 中乘了 `again = 7`。
  - 当前 `processAudio` 直接按 1:1 截断强转为 `short`，导致原生 PCM 信号衰减约 17 dB；用户在外置扬声器或系统端提高音量后，微小的欠载冲击和台阶噪声被不成比例地放大。

---

## 三、 执行计划与改造要求

请按照以下模块化步骤实施修复，严禁破坏既有业务逻辑与离线测试契约：

### 步骤 1：重构/扩大播放端缓冲深度（弹性防抖）
1. **扩大在飞帧上限**：
   - 将 `bm_voice_pipeline.hpp` 中的 `max_unconfirmed_playback_frames` 从 3U 调整至合理范围（例如 10U ~ 12U，对应 200ms ~ 240ms 水位）。
2. **扩充 `WaveOutput` 缓冲池**：
   - 在 `win_io.hpp` 中，将 `WaveOutput` 的 `buffer_count` 与 `WaveInput` 解耦，扩充为足够的块数（如 12 ~ 16 块），使驱动具备防御 150ms 以上系统抖动的能力。
3. **修复 `WHDR_DONE` 标志清除**：
   - 在 `WaveOutput::reap()` 或 `submit_for_generation()` 重新提交前，规范清除 `buffer.header.dwFlags &= ~WHDR_DONE;`，确保驱动状态机一致，杜绝内存覆写。

### 步骤 2：优化 RX 管道的解码驱动与调度策略
1. **消除 20ms Reanchor 惩罚**：
   - 在 `bm_voice_pipeline.cpp` 的 `tick_rx` 中，消除 `rx_lateness > 20ms` 时惩罚性向后跳 60ms 的行为；
   - 只要网络队列中有积压的 voice burst，且 `playback_frames_` 和声卡仍有容量，允许以追赶方式及时解码并填入缓冲，快速拉升声卡水位。
2. **合理的起播预缓冲（Jitter Buffer Watermark）**：
   - 保持接收 2 个 burst 起播（或根据需要预填 120ms~180ms），起播后以声卡消费为主导，平滑输出。

### 步骤 3：丢包平滑与波形连续性保护
1. **补零帧的平滑衔接**：
   - 在插入丢包静音时，实现简易的边缘淡出/淡入（几个采样的简易斜坡或保持连续），避免方波截断。
2. **重采样器历史连续性**：
   - 避免在正常来话期间意外 reset 重采样器历史，保持 FIR 滤波器的连续平滑。

### 步骤 4：声码器输出增益合理化（可选/渐进）
1. 检查 `MBEVocoder::processAudio()` 的幅度标度，确保转入 `int16_t` 时的有效动态范围适中（防止削波的同时提供饱满电平）。

---

## 四、 验收与回归要求
1. **本地自动化回归**：
   - 必须通过全量 Native 离线单元测试（包含 `dmr_vocoder_test`、`pcm_resampler_test`、`bm_voice_pipeline_test`、`engine_test`、`bm_local_playback_test` 等所有现有测试）；
   - 若修改了 `max_unconfirmed_playback_frames` 常量，需同步更新断言测试，保证测试套件 100% 退出码为 0、0 warning。
2. **真实听音与稳定性验收**：
   - 编译 Release 版本并在 Windows 11 环境下接入真实/测试 BM 语音流进行听音；
   - 验证声音连贯饱满，无“一卡一卡/抽搐”感；
   - 验证音频起止与连续说话过程中无“兹拉兹拉”电杂音与爆音；
   - 验证 CPU 占用率与内存占用保持在轻量水准（< 1% CPU）。
```

---

## 一、 当前业务验收与阶段收尾（短期优先）

### 1.1 R126 业务收尾与主分支合入
- [ ] root 审核后再将 R126 工作分支（`f73f60f` @ `codex/r124-stable-release`）合入 `app/main`；未经审核不快进主分支。
- [ ] 合并后复核集成运行：BM 静态组刷新、正常与异常来话结束提示、新来话后历史列表回到最新页，以及主窗口字体、行距和留白。实际应用集成仍待检查。
- [ ] 完成 TG46001 动态组的真实收听验收，覆盖首次激活、再次激活和多个组之间切换；确认实际来话与播放。已确认的鹦鹉私呼和 TG91 收听不列为待办。
- [ ] 构建后确认应用窗口与任务栏图标正常显示。

### 1.2 电台与射频实机核对
- [ ] BM 与 FM/C4FM 射频双向联测：优先由电台配置承担调制；确认实际模式和路径后，分别完成 RF→BM 与 BM→RF 联测，不预设需要额外 MMDVM 盒子。
- [ ] 实机核对 CAT 指令能否开启/关闭 HRI、切换 DIRECT/AP，以及读写模式、频率和功率；若没有对应指令，列出需要在电台菜单手动设置的项目。
- [ ] FTX-1 LCD 显示状态可重复性观察：先核对官方对相同模式下不显示的说明，再按可重复步骤观察屏幕内容、出现时机和清除；软件状态或 PC 面板文字不作为 LCD 证据。
- [ ] 后续获准听音时分别对照回放与上行增益、削波统计和主观音质；目前没有声码器已修复的结论。

### 1.3 空口射频中继转发方案实施（AP PC 模式 RF ↔ BM Gateway）

> **技术背景与架构基线**（详见 [docs/17_AP_PC模式RF转发与握手判定机制.md](file:///C:/Users/cassi/Documents/Project/FTX1_project/WIREX_Bridge/docs/17_AP_PC模式RF转发与握手判定机制.md)）：  
> 当前版本代码（`hri_session.cpp` 第 30 行）强制校验 `y_body_[5] == '2'`（DIRECT 直连终端模式，电台固件因此关闭空口 RF 收发与中继），且上行逻辑仅绑定手咪物理 PTT 观测（X 记录 `payload[12] == '2'`）与声卡录音。电台在 `AP PC` 模式下作为空口中继网关工作时，收到 RF 信号向 PC 转发的处理方案分流如下：

#### 方案 A：C4FM 数字模式空口中继（DN 模式，原厂 AP 最佳实践，优先推进）
- [ ] **电台模式与配置调整**：
  - [ ] 电台调制模式由 `FM` 切换为 **`DN`**（C4FM 数字模式），工作频率保持 145.200 MHz。
  - [ ] 电台保持 `Node Mode: AP PC`，`DG-ID` 配置为 `Auto` 或 `00`（Open Node，允许任意数字电台接入）。
- [ ] **HRI 握手协议解除 DIRECT 限制**：
  - [ ] 改造 `app/src/hri_session.cpp`：放宽 `y_template_valid_` 校验逻辑，允许模板正文偏移 `0x05` 为 ASCII `'1'`（即声明 `Direct: OFF` / AP 接入点模式）。
  - [ ] 允许配置或动态下发 `y_body_[5] = '1'`，通知电台开启空中 C4FM 射频接收并向 HRI 串口上传数据流。
- [ ] **串口 C4FM 信令与数字语音帧解包**：
  - [ ] 在 HRI 串口监听流中接入 `'G'` 记录解析（提取 68 字节头中的发送方呼号 `Src CallSign` 与目标呼号 `Dest CallSign`，动态填充为 DMR 来话头）。
  - [ ] 接入 `'R'` 记录解析（提取电台硬件解调出的 AMBE 数字语音帧）。
  - [ ] 接入 `'P'` / `'E'` 记录解析（捕捉空口 Digital PTT 起止与传输结束标志，触发 DMR 话尾流结束符）。
- [ ] **零重编码直通转发管线**：
  - [ ] 将收到的 AMBE 语音帧免声卡、免本地声码器重编码，直接通过协议转换层组装为 DMR 数据包推送至 BrandMeister 网络（降低延迟、避免模拟二次失真与 CPU 占用）。

#### 方案 B：FM 模拟模式空口中继（兼容现有 FM 145.200 MHz 模拟对讲机）
- [ ] **模拟音频与信令通道识别**：
  - [ ] 确认物理事实：电台在纯模拟 FM 模式下空中无数字包，HRI 串口不产生 `G/R` 帧，必须走电台内置 USB 声卡麦克风/录音频道（WaveIn / `radio_input`）采集模拟 PCM 音频。
  - [ ] 确认 DG-ID 在纯模拟 FM 模式下不生效，电台工作于载波静噪（Carrier Squelch）开门。
- [ ] **模拟静噪开门检测（Squelch / VOX 触发器）**：
  - [ ] 评估并实现电台 X 状态帧中的 SQL 状态位解析，或在 App 音频输入管线增加轻量级 VOX（语音能量检测）算法，可靠识别外部模拟电台何时在 145.200 MHz 说话开门、何时松手关门。
- [ ] **自动化模拟转码与网络推送**：
  - [ ] 模拟静噪开门时自动触发 `start_tx_call()`，启动电台 USB 声卡录音采样。
  - [ ] 调用本地已有软件声码器（Vocoder），将 8kHz 16-bit PCM 模拟声音实时编码为 AMBE 帧。
  - [ ] 虚拟呼叫头生成：FM 信号无空中数字呼号，由 App 注入配置的本地呼号/DMR ID 与当前活动 Talkgroup 组装后推向 BrandMeister。

#### 方案 C：BM 网络下行至空口射频发射（BM → Radio RF TX 仲裁）
- [ ] 梳理 BM 网络来话触发电台空口射频发射的可靠键控命令（区分 HRI 串口协议键控与 CAT 键控）。
- [ ] 在 `engine_loop` 中实现严格的半双工冲突仲裁（Half-Duplex Arbitration），防止空口上行接收与网络下行发射在同一台 FTX-1 上产生冲突或射频回环。

---

## 二、 客户端交互与多语言国际化（i18n）

### 2.1 中英文多语言完整支持
- [ ] 启用语言切换入口：恢复中英文界面切换功能，支持实时动态无缝切换。
- [ ] 完整翻译覆盖：主控制台、BrandMeister 状态窗、CAT 配置面板、提示信息及异常弹窗的完整本地化字典。
  - R127 进度：词典新增 645 条；主窗、设置窗、CAT、BM 面板在 en-US 下的可视树检查已无中文（test-ui-localization 108 项）。遗留：`config.json` 损坏时的启动 MessageBox 仍为中文，因为它出现在语言初始化之前；仅内部使用的 throw 文案未收录。真实英文界面还没有人工验收。
- [ ] 偏好持久化与防护：验证语言偏好保存与读取、用户自定义设置保留，以及英文环境下 CAT 手动端口输入保护。

---

## 三、 架构现代化与全 C++ 深度重构（中长期演进）

> **重构愿景**：彻底解决当前仓库包含近 600 个 `.ps1`、8500 行弱类型 PowerShell 驱动 WPF 导致跨进程 IPC 脆弱、编码策略受限的问题；实现**全 C++ 单二进制原生交付**，并用 **Go 单文件 CLI** 统一收敛构建运维工具链。

### 3.1 阶段一：现有核心资产锁定与代码库深度瘦身（Clean & Audit）
- [ ] **核心 C++ 算法与协议资产锁定**：
  - 保护并审计已通过验证的 Native 核心模块（`dmrd` 封装、`hri` 协议解析、`direct_frame`、`ui_control_protocol` 及对应 golden 离线测试用例）。
- [x] **历史归档剥离主树**：
  - 将 `app/private/build-retired/`（含 299 个历史版本 `.ps1` 副本）与 `build-history/` 移出日常 Git 工作区，转为离线独立压缩归档或归档分支存储。
  - 清理根目录下散落的 `*.obj` 临时编译产物和冗余目录。
  - 已完成（R127）：两目录已压缩为 `FTX1_project/_archive/wirex-private-history-R110-R124.7z` 并校验后删除，散落的 `*.obj` 已清理。
- [x] **规范工程配置与 `.gitignore`**：
  - 重构 `.gitignore`，严禁任何 `*.obj`、`build/` 中间目录和临时测试日志再次污染主树。
  - 已完成（R127，`1283f86`）：`.gitignore` 在任意层级忽略 `build/`、`tmp/`、`*.obj`、`__pycache__/` 等中间产物。

### 3.2 阶段二：Go 运维工具链收敛（Tools Modernization）
- [ ] **构建单一 Go CLI 工具（`tools/wirex.exe`）**：
  - R127 进度：`tools/wirex` 第一版已落地，实现 doctor/build/test/package。build/package 目前包装现有的 ps1；`--cmake` 路径已写好，但本机没有 cmake，尚未验证。下一步把构建和打包逻辑改用 Go 原生实现，再删除对应的 ps1。
  - 彻底废除 `app/tools/` 下分散的 70+ 个 PowerShell 脚本，替换为单个开箱即用、无环境依赖的 Go 二进制工具：
    - `wirex build [--release|--debug]`：统一调用 CMake/MSVC 编译 Native 核心与测试套件。
    - `wirex test [--offline|--all]`：自动执行 40+ 项 Native 单元测试与 golden 离线协议断言。
    - `wirex package [--version]`：自动化生成文件清单、计算 SHA-256 校验和、制作纯净分发包。
    - `wirex doctor`：一键检测当前环境的 MSVC 编译链、串口 COM 分配与音频终结点。
- [ ] **辅助测试精简**：
  - 针对网络抓包与协议回放测试，仅保留少量清晰的 Python 验证脚本。

### 3.3 阶段三：全 C++ 原生 UI 合并（Native UI Integration）
- [ ] **确定现代 C++ GUI 技术栈**：
  - 首选评估 **Slint (C++)**（轻量级、现代声明式语法、单二进制静态链接编译、内存占用 < 30MB）或 **Qt 6 / Dear ImGui**。
- [ ] **消除跨进程 IPC 与重构事件驱动**：
  - 解析并迁移原 `MainWindow.xaml` 布局与 `bridge-ui.ps1` 中的状态机交互逻辑。
  - 核心架构改造为进程内统一调度：
    - **UI 主线程**：仪表盘、通话组 TG 切换、增益拖动与音频电平表绘制。
    - **CAT 控制线程**：电台串口状态轮询与频点同步。
    - **BM 协议线程**：UDP 异步收发与 DMRD 帧处理。
    - **音频缓冲线程**：WASAPI 低延迟环形缓冲区，消除音频卡顿与削波。
- [ ] **彻底废除 PowerShell 5.1 胶水层与黑框进程**。

---

## 四、 纯净打包分发体系与端到端交付验证

### 4.1 纯净发布包制作与全链路隔离验证
- [ ] **纯净包自动化生成**：由 `wirex package` 从冻结源码构建单一原生可执行文件（或纯净分发 ZIP），严格剔除用户配置、日志、README、历史脚本及审计材料。
- [ ] **沙箱隔离运行验证**：
  - 在完全干净的独立目录解压验证默认配置首次自动生成功能。
  - 验证命令行配置校验（`--validate-config`）有效性。
  - 验证全链离线路由诊断，确认进程树生命周期与子线程/后代进程 100% 干净退出（无后台孤儿进程遗留）。
- [ ] **分发资产校验**：生成严格的 `manifest` 资产清单与 `SHA256SUMS.txt`，验证远程下载完整性与逐文件哈希对齐。
- [ ] **端到端实机通信验收**：
  - 离线全量通过 golden 回归测试，确保 HRI/DMRD 编解码协议 0 退化。
  - 实机连接 FTX-1 电台与 BrandMeister 网络进行全链路通话联测。
  - 输出重构前后文件总数、安装包体积、内存占用及启动耗时对比报告。
