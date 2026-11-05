# R128 全原生 GUI 重构（设计决定）

更新：2026-11-06。分支 `feat/r128-native-gui`。系统现状见 [ARCHITECTURE](ARCHITECTURE.md)，待办见 [TODO](../TODO.md)。本文记录 R128–R130 的设计决定与行为规则；逐轮验证记录见 git 历史。

## 选型

| 项 | 选择 | 理由 |
| --- | --- | --- |
| GUI | **Dear ImGui + Win32 + DirectX 11**，静态链接进单个 `WirexBridge.exe` | 约 10 个源文件 vendor 到 `third_party/imgui`（MIT，兼容 GPL-3）；沿用 MSVC 2019 `cl.exe`，不新增 CMake/Rust/Qt SDK；即时模式每帧直接读引擎快照，不需要绑定层 |
| 未选 Slint | — | 需要 Rust 工具链 + CMake 生成 C++ 绑定，构建链变长 |
| 未选 Qt 6 | — | SDK 数 GB，静态链接需自行编译 Qt，对固定尺寸控制台过重 |
| 进程模型 | **单进程**：UI 线程 + 引擎线程 + CAT worker + HTTP worker | 取消 launcher → PowerShell → WPF → 匿名管道 → Native 这条链 |
| 通信 | `include/wirex/engine.hpp`：类型化命令 → `std::future<CommandResult>`；不可变 `shared_ptr<const Snapshot>`；有界事件队列（1024）+ 唤醒回调 | 去掉 JSON 序列化/解析、重放缓存、`status.jsonl` 轮询和 3 秒“状态过期”判定 |

字体从 Windows Fonts 运行时读取，不随 exe 打包：拉丁字符用 Segoe UI，CJK 优先合并等线，缺少时回退黑体，最后用 ImGui 默认字体；不使用微软雅黑。仍由 ImGui stb 栅格化（启用 `PixelSnapH`），不使用 DirectWrite。

## 迁移步骤（新旧并存）

1. **engine-extract**：`run_bm_bridge` 移入 `src/engine/`；`wirex_bridge.exe --ui-pipe` 改为 Engine 之上的管道适配层，`status.jsonl` 字段保持兼容，旧 WPF UI 不改也能用。
2. **gui-shell**：ImGui 外壳 + fake engine，可离线截图（`--fake --screenshot`）。
3. **app services**：`config.json`（schema v1 与 PortableConfig 逐条一致、保留未知字段）、设备枚举（SetupAPI + MMDevice）、CAT-1、BM API、RadioID 全部用 C++/Win32 实现。
4. **集成**：GUI 接真实 Engine 和服务；HRI Y 模板编入源码（见 ARCHITECTURE 第 6 节）。
5. **退役**：功能对等并完成实机验收后，删除 `ui/windows/`、launcher、`tools/start-*.ps1` 和 control-v2 适配层。

验收门槛：编译 0 warning；Native 与 app 测试全部通过；退役前 PS 侧离线回归保持通过；中英文截图人工视检；TODO 第一节实机项用新 GUI 重新验收后才能删除旧 UI。

## 连接生命周期规则

- Engine runtime、BM、HRI/电台分别管理状态。HRI 模板、串口打开或握手失败记入 `radio_error`，不结束 BM runtime；BM 资料无效或认证被拒时 BM 保持断开并保留错误，HRI 仍可启动。认证拒绝不自动重试，用户换入有效资料后可在同一 runtime 内重新连接。
- `configure_bm` 失败后 Engine 暂停后续 enable 并返回 `bm_profile_reconfigure_required`；必须再成功配置一次才允许连接，避免新资料被拒后静默用旧 profile 登录。
- 电台断开只收尾串口与音频，不停止 runtime 或已连接 BM。音频 `close()` 失败且驱动仍报告句柄打开时，快照保留真实打开状态与错误，拒绝重复连接，用户可再次断开重试；Engine stop 在清理预算内结束，未释放的句柄在最终快照中仍显示为打开。
- 正常模式下 ViewModel 创建时自动启动：常驻 Engine/BM runtime、CAT worker 和电台连接按各自结果更新状态。HRI/USB Audio 无唯一设备时 runtime 与 BM 仍运行并保留 radio 错误。Fake 模式不自动连接。
- 主界面电台按钮同时发起 Engine/HRI 与 CAT 连接，停止时请求两侧断开；两侧状态分别来自 `Snapshot` 与 `CatState`，部分成功分别显示。CAT 连接任务带代次，停止后取消排队任务并丢弃过期回调（迟到的 connect 报 `cat_connection_cancelled`）。
- BM 密码：`Engine::Impl::enqueue()` 拒绝新命令及 worker 结束清理遗留命令时，先擦除字符串当前长度内字节，再兑现 `engine_not_running` / `engine_stopped`。

## 启动组呼自动激活（原 R129）

- ViewModel 创建时冻结已保存频道顺序。BM 第一次进入 `connected` 后，本次进程一次性按此顺序发送组呼 Quick Call。首次连接前不设超时、不发送；状态显示等待首次连接。运行中新增频道不加入队列。
- 只看 BM link，不等待 HRI ready；Engine 仍要求 BM transport ready、TX/RX pipeline 与 router 空闲、HRI stream cleanup 空闲。BM-only 运行时满足这些条件即可执行。
- 忽略私呼、TG4000（动态组断开控制）、无效目标，重复 `(TG, TS)` 合并。不读取或推断 BM 静态/动态订阅状态，静态组 API 不参与筛选。
- 同一时刻只发一项。发送失败或部分发送不自动重发当前目标；Busy（未发出帧）每 500 ms 重试，BM 保持连接且持续 Busy 30 s 后当前及剩余目标一起跳过。BM 断开时队列无限期暂停，不计入 Busy 超时，同进程内重连后继续未处理项、不重发已完成项。退出即结束；重启按当时保存的频道重建队列。
- `accepted` 只表示两帧已交给本机 UDP transport，不表示服务端确认动态组或已收到语音。界面应分别报告：等待首次连接、正在本机发送、因断开暂停、重连后继续、完成计数；任何状态都不得写成“BM 已订阅”或“服务器已确认加入”。

## BM-only 来话与本机播放

- BM 收到有效 DMRD 来话后，即使 HRI 未连接，Engine 仍处理来话并发布活动呼叫与通话历史。所选 WaveOut 可用时解码 PCM 送往本机输出；该路径不打开 HRI 串口，也不发送 T3/T0 或电台命令。
- WaveOut 无法唯一解析、打开失败、提交失败或设备丢失时，保留来话与历史，PCM 有界静默排空并确认，BM 不退出；快照保留本地音频错误，重新选择可用输出即可恢复。Auto 只接受唯一解析结果。
- HRI 会话异常停止时，`radio_error` 记录具体原因（版本/模板/记录确认超时、串口写入或传输失败）。`hri_t3_record_observed` / `hri_t0_record_observed` 只在 Engine 观察到对应 T 记录后置位。对仍被隔离的 WaveOut，只有 T0 已确认、pipeline 排队与未确认 PCM 为零、设备报告已排空或关闭，才释放来话 Router 占用；句柄状态不确定时继续跟踪并阻止播放。

## 音频端点切换与电平

- 运行中切换音频端点：媒体占用时最多等待 30 s，待空闲后验证并切换；超时或停机明确失败。成功后快照发布实际 HRI COM、WaveIn/WaveOut endpoint ID 与 `audio_endpoints_revision`。旧 WaveOut 清理失败但句柄已关闭时接受新路由并报告清理警告；旧句柄仍打开则保留旧路由。界面在引擎确认后才保存配置。
- `levels.rx_peak` / `tx_peak` 为最近 200 ms 增益后 PCM 的归一化峰值（0–1）；削波样本数为累计值。

## 设备显示与热插拔

- HRI、CAT、音频输入/输出选择框显示当前配置的解析结果：唯一候选显示友好名（HRI/CAT 附 COM 号）；歧义、未枚举、冲突、手动未分类分别显示原因。Engine 快照中已打开的端口/端点、`CatState.connected` 确认的 CAT 端口优先显示；CAT 仅 busy 未确认时显示配置候选，主按钮显示“连接中”。
- Auto 解析只用于显示和启动，不写回具体 ID；候选不唯一时不自动选择，也不逐口试开。手动选中的未分类 CAT COM 标为“手动未分类”。
- `WM_DEVICECHANGE`（到达、移除、节点变化）和手动刷新只重新枚举，不改变保存选择、不连接或重连。手动选择的设备被拔出后保留 requested ID 并显示缺失，同 ID 重插后恢复。

## CAT 读回与表单联动

- CAT 服务只把本次结果明确确认的 MAIN 模式、频率和 PC 功率发布为新观测：普通连接/忙碌/错误沿用 `CatState.revision`，只有接受可信读回或使旧读数失效时才递增 `observed_revision`。查询失败保留最近可信读数，不把失败响应中的部分值当新数据；电台 ID 不符时清除旧观测。
- ViewModel 只在 `observed_revision` 变化时更新控件。频率以 MHz 显示，精度 1 Hz；功率只匹配 5/10/15/25/50 W，`CatForm::power_index` 默认 `-1`，无读数或不在档位时保持未选择，不代填默认值。
- 正在编辑或有用户草稿的字段不被异步读回覆盖。Apply 成功只清除本次提交且之后未再改动的字段草稿；失败不清草稿。频率为空时 Apply 不提交频率；模式与功率都有效选择后才允许 Apply。
- CAT 新配置及缺字段合并默认 38400 baud；但磁盘配置严格 shape 检查要求 `devices.cat_baud_rate` 存在，缺失时作为不完整配置拒绝并保留原文件。

## FM 中继（R130）

官方未支持的功能：电台 FM 收到信号、静噪开启时，把 USB 声卡录到的音频经 AMBE 编码发往 BM。实现分布见 ARCHITECTURE 第 3、6、8、9 节。

### 开关

- 标题栏右上角“启用中继 / 停用中继”按钮切换 `relay.enabled` 并立即保存。中继开启后，下次连接电台使用 AP PC 模式 Y 模板（`RadioStartConfig::ap_mode`）。电台已连接（或正在连接）时切换只提示“需重新连接电台后生效”，不自动断开或重连。
- 中继开启时按钮右侧出现 FM 按钮，切换 `relay.fm_enabled`（中继关闭时不可切换）。状态并入按钮文字：`○ FM`（FM 关闭）、`● FM · 等待静噪开启`、`● FM · FM 中继进行中`、`● FM · CAT 未连接`。“官方未支持”说明放在 tooltip；FM 关闭时 tooltip 另加“C4FM 中继尚未支持，当前仅 FM 可用”。
- 中继与 FM 都开启且 CAT 已连接时才启动 100 ms `RI0;`/`SM0;` 静噪采样；任一条件不满足即停止采样，若中继段正在进行则请求引擎结束。
- 截图验收：`--fake --screenshot <png> --screenshot-relay-demo`。

### 半双工规则

- FM 中继与手咪 PTT 共用一个上行管线和同一个 Router 发射许可，目标都是当前 PTT 目标（`tx_policy.target`）。
- 中继上行进行中，BM 来话按 Router 规则拒绝，不会经电台播放。
- BM/HRI 下行进行中（来话播放、排空或收尾），静噪开门触发的 `relay_fm_start` 返回 `busy`（`relay_fm_busy_downlink`），不打断来话；手咪上行中返回 `relay_fm_busy_ptt`。两者都计入 `relay_fm_rejected_busy`，界面提示“FM 中继未开始：…”。
- 中继段进行中，手咪按下或松开都不能打断或结束本段；中继段只由静噪关门、超时或异常结束。
- 发射关闭（`transmit_enabled=false`）时返回 `forbidden`；BM 或电台未就绪时返回 `not_ready`。
- 本节只覆盖 FM。C4FM 中继及其仲裁待 `R` 记录格式确认后再做（见 TODO 1.3）。

### 结束原因

单段最长 180 s。`relay_fm_ended.end_reason`：`squelch_closed`（静噪关门，正常结束）、`timeout`（达到 180 s）、`transmit_disabled`（发射被关闭）、`bm_not_ready`（BM 断开或断开中）、`radio_lost`（电台断开）、`shutdown`（引擎停止）、`aborted`（其他原因或终止帧发送失败）。

### 记录

- 来话历史中以黄色显示一行“时刻 · FM 中继 → TG …（或私呼）· TS · 时长 · S 峰值”，FM 没有呼号；tooltip 给出结束原因。
- 每段追加一行到 `<exe>/private/runtime/relay-log.jsonl`：`started_utc`、`duration_ms`、`target_kind`、`target_id`、`slot`、`s_meter_peak`、`end_reason`。超时等先于静噪关门结束的段，等关门事件补上 S 表峰值后再写入。

### 实测证据（2026-11-06，AP PC 模式，145.200 MHz FM）

- 用 `tools/research/cat_squelch_probe.py` 以 100 ms 间隔只读采样（COM11，38400 8N2），由第二台电台按键发射。原始数据在仓库外父目录 `research/hil/2026-11-06_fm_squelch_capture2.jsonl`（448 次采样，0 次失败）。
- `RI0;` 的 P8 在按键后下一次 100 ms 轮询内由 0 变 1，松开后变回 0；P4 全程为 0（本机未发射）。
- `SM0;`：空闲时 72–94，开门时 134–212（开关门过渡采样可落在两者之间）。`SM1;`（副收信机）始终不应答。
- 以上只确认静噪检测；AP 模板握手、RF → BM 端到端和转发音量尚未实机验证（见 TODO 1.3）。

## 与旧版的行为差异（实机验收时确认）

- CAT 设置模式/频率要求核心**已停止**；旧版只要求核心空闲。
- CAT 功率的“接收队列为空”条件：快照没有队列深度，暂用 `media_owner==idle` 代替。
- 窗口可调整大小（最小 1180×780）；设备与 BM 配置直接在主界面面板中，没有单独的设置弹窗。
- 无 `--open-settings` 参数。
- BM 静态组与收听频道双向同步：每个设备/API Key 首次成功读取静态组后，把不在收听表中的静态组补进频道并保存；面板添加静态组同时加入收听频道，面板移除同时取消收听；在频道卡片上移除静态组频道时先调 BM remove，成功才取消收听，失败保留频道，无 API Key 时只取消收听。启动组呼等首次静态组读取结束（最多 10 s）后再激活，并跳过静态组频道。
- 主界面显示 BM RTT（RPTPING/MSTPONG 往返，悬停显示最近/最小/平均/最大和样本数）与本次会话丢包率（DMRD 序号统计，≥1% 黄色、≥5% 红色，悬停另显示当前通话丢包）；无数据时显示“—”。
