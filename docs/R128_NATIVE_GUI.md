# R128 全原生 GUI 重构（设计决定）

更新：2026-11-04。对应 TODO 3.3。分支 `feat/r128-native-gui`。

## 决定

| 项 | 选择 | 理由 |
| --- | --- | --- |
| GUI | **Dear ImGui + Win32 + DirectX 11**，静态链接进单个 `WirexBridge.exe` | 约 10 个源文件 vendor 到 `third_party/imgui`（MIT，兼容 GPL-3）；沿用现有 MSVC 2019 `cl.exe` 构建，不新增 CMake/Rust/Qt SDK；即时模式每帧直接读引擎快照，不需要绑定层；字体不随 exe 打包，运行时从 Windows Fonts 读取，优先以 Segoe UI 显示拉丁字符并合并等线字形，缺少等线时回退黑体或 ImGui 默认字体 |
| 未选 Slint | — | 需要 Rust 工具链 + CMake 生成 C++ 绑定，本机都没有；构建链变长 |
| 未选 Qt 6 | — | SDK 有数 GB，静态链接要自己编译 Qt；对一个固定 1360×900 的控制台来说过重 |
| 进程模型 | **单进程**：UI 线程 + 引擎线程 + CAT worker + HTTP worker | 取消 launcher → PowerShell → WPF → 匿名管道 → Native 这条链 |
| 通信 | `include/wirex/engine.hpp`：类型化命令 → `std::future<CommandResult>`；不可变 `shared_ptr<const Snapshot>`；有界事件队列（1024）+ 唤醒回调 | 去掉 JSON 序列化/解析、重放缓存、`status.jsonl` 文件轮询和 3 秒“状态过期”判定 |

## 线程

```text
UI 线程 (ImGui/DX11, MsgWaitForMultipleObjects, 空闲 ≤10 fps)
  ├─ engine::Engine ──> 引擎线程：HRI 串口 / WinMM / BM UDP（原 run_bm_bridge 主循环）
  ├─ app::CatWorker ──> CAT-1 串口（单任务队列，可取消）
  └─ HTTP worker    ──> BM API v2 / radioid.net（WinHTTP）
```

引擎和 worker 发布状态后调用唤醒回调（`PostMessage`），UI 只在有变化时重绘。

## 迁移（新旧并存）

1. **engine-extract**：`run_bm_bridge` 移入 `src/engine/`；`wirex_bridge.exe --ui-pipe` 改为 Engine 外面的一层管道适配，`status.jsonl` 字段保持兼容。旧 WPF UI 不改也能用，full40 继续通过。
2. **gui-shell**：ImGui 外壳 + fake engine，可离线截图验收（`--fake --screenshot`）。
3. **app services**：`config.json`（schema v1 与 PortableConfig 逐条一致、保留未知字段）、设备枚举（SetupAPI + MMDevice）、CAT-1、BM API、RadioID，全部用 C++/Win32 实现。
4. **集成**：GUI 接真实 Engine 和服务。已授权的 100 字节 HRI Y 模板现以只读 `constexpr` 数据编入源码，GUI 默认启动不再查找 `private/device-y.bin`；引擎接口仍允许调用方显式提供外部模板路径，并校验长度、标记和 SHA-256。GUI 单 EXE 候选已构建，正式 ZIP profile 与交付验收仍待完成。
5. **退役**：新 GUI 达到功能对等并完成实机验收后，删除 `ui/windows/`、launcher、`tools/start-*.ps1` 和 control-v2 适配层。

## 验收门槛

- 编译 0 warning；Native 测试与新增 engine/app 测试全部通过。
- 原有离线回归（PS 侧）在退役前保持通过。
- GUI 离线截图（中/英）人工视检；空闲 CPU 与内存给出实测值。
- 实机：TODO 第一节各项要用新 GUI 重新验收一遍，才能删除旧 UI。

## 进度（2026-11-04）

R128 的引擎拆分、原生界面和本轮串口/音频设备显示已在 `feat/r128-native-gui`。设备选择预览、保留 Auto 配置语义、设备目录变化刷新、CAT 未知值显示及主界面布局已完成源码集成。基于基线 `9e789c9` 的 GUI Release 构建和中英文隔离截图均已通过；构建时源码保持冻结。正式打包、BM RTT 在 GUI 的显示、真实设备与 RF 验收仍未完成。因此不退役旧 UI，也不把当前 EXE 候选称为正式发布。

| 项 | 结果 |
| --- | --- |
| Native 与引擎 | `tools/build-bm-bridge.ps1` 本次编译核心和固定第三方源通过，注册的离线测试全部通过；`engine_test` 覆盖模板嵌入、音频路由失败与排队切换、旧 WaveOut 清理失败但句柄关闭的状态处理。 |
| app 服务测试 | 最新 `tools/build-app-tests.ps1`：8 个测试目标通过、0 warning；config 396、devices 83、CAT 163、fake CAT 生命周期 6、CAT 表单同步 22、BM API 285、RadioID 234、GUI config bridge 109。GUI config bridge 检查 Auto 解析、候选歧义、拔出/重插、配置保持、预览 ID 与启动/CAT helper 一致，以及 CAT busy/断开时不把旧 COM 报成活动端口。 |
| 音频 meter | `audio_peak_window_test` 的 6 项滑窗、过期、范围夹紧和 NaN 检查通过。 |
| AP_PC GUI 构建 | 基于 HEAD `9e789c9` 的本轮 dirty 源码 GUI Release 编译通过，项目代码 0 warning；EXE 为 `build/_work/wirex-gui-9e789c9-dirty-20261104-042648/WirexBridge.exe`，SHA-256 `0152a00b773fb80e686386d869645f554a77261854cbb4165f43bf54fa1dd4fd`。首次配置检查退出码 0。中文、英文隔离截图均为 1360×900；FakeEngine 配合本机设备目录只读枚举，没有连接 HRI、CAT 或 BM。构建期间 126 个 src/include 文件哈希未变化。正式 ZIP、IME 人工验证、实机验收和提交后 clean HEAD 构建仍未完成。 |
| BM RTT | 引擎侧既有状态报告含 RTT 字段，但 GUI `Snapshot` 尚未接入这些字段；主界面目前明确显示“暂无数据 / No data”。GUI RTT 显示与实际 BM 连接测量仍待完成。 |

### GUI 启动参数

- 无参数：真实引擎 + 真实服务；`config.json` 放在 exe 同目录，首次运行自动生成。HRI Y 模板默认来自 EXE 内编译的批准模板。只有底层调用者显式设置 `engine::StartConfig::hri_body_file` 时才读取外部覆盖文件；该文件必须是绝对路径且通过固定校验。
- `--fake`：模拟引擎 + 真实服务。`--fake --fake-services`：完全离线。
- `--screenshot <png>`、`--config <json>`、`--check-config`。当前没有 `--open-settings` 参数。

### 与旧版的行为差异（实机验收时确认）

- CAT 设置模式/频率：要求核心**已停止**（app::radio_cat 门控）；旧版只要求核心空闲。
- CAT 功率的“接收队列为空”条件：快照里没有队列深度，暂时用 `media_owner==idle` 代替。
- `Snapshot::levels.rx_peak` 和 `tx_peak` 是增益处理后 PCM 在最近 200 ms 窗口内的最大归一化峰值；削波样本数仍为累计值。
- 窗口大小可调整（最小 1180×780）。Wires-X COM、CAT COM 与波特率、音频输入/输出设备及 BrandMeister 配置直接显示在主界面面板中，没有单独的设置弹窗。运行时音频下拉变更由引擎确认后再保存配置；连接期间切换等待媒体空闲，最多 30 秒。
- 电台连接按钮同时发起 HRI Engine 与 CAT 服务连接，停止时请求两侧断开；界面分别报告两侧真实状态和部分失败，不把单侧成功显示为全部连接成功。

### 本轮字体、布局与缩放验证

- 字体从 Windows Fonts 读取：拉丁字符使用 Segoe UI，CJK 优先合并等线，缺少等线时回退黑体，最后使用 ImGui 默认字体；未使用微软雅黑。ImGui 1.92 保留自动水平过采样（`OversampleH=0`），不启用 `PixelSnapH`，以保留分数字号和分数 DPI 下的排版能力。
- 主界面右侧显示发送增益和状态，频道卡片使用显式布局；中英文截图中六张频道卡、底部按钮、BM 控件、两种增益、meter 和状态指示均完整可见。当前视检为 1360×900、100% DPI。125% DPI 下的实机显示尚未检查；字体设置和像素对齐代码不作为该缩放比例的验证结果。

### 设备选择显示与热插拔

- 主界面的 HRI、CAT、音频输入和音频输出选择框显示当前配置的解析状态；唯一候选显示 COM 口或音频端点的友好名称，HRI/CAT 同时显示 COM ID。歧义、未枚举、冲突和手动未分类状态各自显示原因。Engine `Snapshot` 的已打开端口/音频端点，以及 `CatState.connected` 确认的 CAT 端口优先显示；CAT 仅 busy 但尚未 confirmed connected 时仍显示配置解析候选，此时主连接按钮显示“连接中”，CAT 指示灯保持未连接。查询成功后才把 CAT 实际端口标为活动端口。如果设备目录刷新后找不到实际活动 ID，界面保留并显示状态报告中的 ID。
- Auto 仍保存在原配置字段中，解析结果只用于显示，不把当前 COM 或音频 endpoint ID 写回配置。HRI 继续使用唯一识别规则；CAT 使用 `resolve_port_selection` 的候选排序和 HRI 排除规则；音频使用 `resolve_audio_endpoints` 的唯一 USB Audio 配对规则。候选不唯一时不自动选择，也不逐个试开未知 COM 口。用户手动选中的未分类 CAT COM 会标为“手动未分类”，不会伪装为已识别设备。
- 收到 Windows `WM_DEVICECHANGE` 到达、移除或设备节点变化消息后，GUI 重新枚举并刷新设备显示；主界面也保留手动刷新入口。刷新不改变保存选择、不发起连接或重连。手动选择的 COM/endpoint 被拔出后仍保留为 requested ID 并显示缺失；相同 ID 再次出现时恢复解析。Auto 会按最新枚举重新解析，COM 编号变化后只在规则可唯一确定时显示新候选。
- 离线测试使用模拟设备目录和既有纯选择函数，检查 Auto 候选与启动/CAT helper 结果一致、多个候选保持歧义、配置不被解析结果改写，以及拔出和重插后的显示状态。CAT 表单测试检查未读回时功率为未知、断开清除可信读数、草稿保留，以及重连成功读回后更新表单。截图用 FakeEngine，并仅只读枚举本机设备目录；没有打开实体串口或实际电台音频流。100% DPI 截图不验证 125% DPI；离线检查也不验证目标机器收到热插拔通知、驱动兼容、CAT/HRI 连接或 RF 行为。

### 待办

1. 实机：不带 `--fake` 启动，依次验证连接串口 → 连接 BM → TG 收听/发射 → Quick Call → CAT 门控 → 身份写回 → 关闭窗口时有界收尾。
2. 打包：在 `ZipOnlyRelease.psm1` 新增 GUI profile（单个 `WirexBridge.exe` 与所需 `licenses/`）；内置 HRI 模板不再作为随包的 `private/device-y.bin` 文件。完成 profile 检查后再交付候选包。
3. 接入 BM RTT 到引擎 `Snapshot` 与 GUI，展示有效值和无数据状态；当前界面仍显示“暂无数据”。
4. 人工验证 IME 中文输入并复查中英文截图；随后在 FTX-1、HRI-200、CAT 串口与音频设备上验证连接、切换和收尾行为。
5. 实机通过后进入步骤 5：删除 WPF/PowerShell UI、launcher 和 control-v2 适配层。
