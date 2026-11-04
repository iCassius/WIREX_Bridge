# R128 全原生 GUI 重构（设计决定）

更新：2026-11-05。对应 TODO 3.3。分支 `feat/r128-native-gui`。

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

## 进度（2026-11-05）

R128 的原生界面、Engine/BM/HRI 分层连接、启动组呼自动激活、BM-only 本机来话播放和串口/音频设备显示均已进入当前 dirty tree。最新验证源码的 HEAD 基线是 `8e2ce8ea2dde08e452565645107675a4c489953a`；下列产物由该基线上的未提交改动生成，不是正式发布。Native、app 和 GUI 离线检查通过；真实 BM、HRI/CAT 串口、音频驱动、PTT 和 RF 验收仍未进行。用户报告的 HRI 实机握手失败根因尚未确认；ImGui 重复 ID 问题已单独修复，不能据此推断 HRI 握手根因。

| 项 | 结果 |
| --- | --- |
| Native 与 Engine | `tools/build-bm-bridge.ps1` provenance 显示 41/41 个 Native 测试通过，包含 `engine_test`。构建来自 HEAD `8e2ce8ea2dde08e452565645107675a4c489953a` 的 dirty tree，产物记录在 `build/_work/wirex-bridge-8e2ce8e-dirty-20261104-232649/build-provenance.json`。Engine fake 集成覆盖 BM-only 来话、隔离 WaveOut、FakeSerial T3/T0 确认、队列/未确认帧/设备排空门控以及首通后续呼叫；这些测试没有连接实际电台或 BM 服务器。 |
| app 测试 | `tools/build-app-tests.ps1` 本轮实际执行 14 个目标，全部通过、0 warning：`app_config_test`、`app_devices_test`、`app_radio_cat_test`、`gui_fake_cat_lifecycle_test`、`gui_cat_form_sync_test`、`bm_local_playback_test`、`gui_startup_group_activation_test`、`gui_startup_group_view_model_test`、`gui_bm_profile_race_view_model_test`、`gui_operation_event_queue_test`、`gui_radio_lifecycle_view_model_test`、`app_bm_api_test`、`app_radio_identity_test`、`gui_config_bridge_test`。运行产物在 `build/app-tests/`。另有 `audio_peak_window_test` 的 6 项滑窗、过期、范围夹紧和 NaN 检查通过。 |
| GUI 构建与截图 | GUI Release provenance 位于 `build/_work/wirex-gui-8e2ce8e-dirty-20261104-232914/gui-build-provenance.json`，MSVC 2019 项目代码 0 warning，EXE SHA-256 为 `eeeb71434bfb434b67fda49065f65653fd48fab5812910eb890ab124a23ea7df`。新旧中文/英文界面对照及标题行对齐检查通过；1360×900、100% DPI 截图位于 `build/_work/ui-header-alignment-20261105/zh-1360.png`、`build/_work/ui-header-alignment-20261105/en-isolated/en-1360.png`。这组 FakeEngine 截图没有连接真实设备。 |
| 重复 ID harness | `tools/run-gui-duplicate-item-harness.ps1` 使用生产环境共用的 `ItemIdScope` 编译并运行通过。Harness 检查三组相同可见标签（Auto/手动 COM5、重复 COM5、同名 USB 音频端点）的 ID 冲突，并执行 5 次点击确认选择结果；输出位于 `build/_work/ui-id-harness-20261104-233433/`。 |
| BM RTT | 引擎侧既有状态报告含 RTT 字段，但 GUI `Snapshot` 尚未接入这些字段；主界面目前明确显示“暂无数据 / No data”。GUI RTT 显示与实际 BM 连接测量仍待完成。 |

### BM/HRI 生命周期与配置安全增补（2026-11-04）

- Engine runtime、BM 和 HRI/电台串口分别管理连接状态。HRI 模板、串口打开或握手失败保留在 `radio_error`，不结束 BM runtime；BM 初始资料无效或 Master 返回认证拒绝时，BM 保持断开并保留 BM 错误，HRI 仍可启动。认证拒绝不自动重试；用户换入有效资料后可在同一 runtime 内显式重新连接。
- HRI 电台断开只收尾串口与音频，不停止 Engine runtime 或已连接 BM。音频 `close()` 若返回失败且驱动仍报告句柄打开，Snapshot 保留真实打开状态与错误；重复连接会被拒绝，用户可再次断开尝试清理。Engine stop 在清理预算内结束；仍未释放的句柄在最终 Snapshot 中继续显示为打开，不能报告完全清理成功。
- 正常产品模式创建 ViewModel 时自动调用启动流程：常驻 Engine/BM runtime、CAT worker 和电台连接按各自服务结果更新状态。HRI/USB Audio 无唯一设备时，Engine 与 BM runtime 仍可运行并保留 radio 错误；BM 无效或认证失败时，HRI/CAT 仍按各自结果连接或报错。电台停止只断开 CAT 与 HRI，不停止常驻 runtime 或 BM。Fake 模式不自动连接，供截图和演示使用。
- 启动组呼自动激活在 BM 第一次达到 connected 后，按 ViewModel 创建时冻结的已保存频道顺序逐项发送 Quick Call；排除私呼、TG4000、无效目标和重复 `(TG, TS)`。它不等待 HRI ready，也不依赖静态组 API。`accepted` 只表示本机发送到 UDP transport；BM 服务器确认、真实动态组接收和 RF 均没有这项离线测试证据，详见 [R129 启动组呼自动激活](R129_启动组呼自动激活.md)。
- `configure_bm` 最终失败后，Engine 暂停后续 BM enable，并返回 `bm_profile_reconfigure_required`。只有一次有效 `configure_bm` 成功后才允许 enable，防止界面刚保存的新资料被拒绝后又静默拿旧 profile 登录。失败配置后重新连接必须先成功配置。
- BM 密码在 `Engine::Impl::enqueue()` 拒绝新命令和 worker 结束时清理遗留命令的路径中，先擦除字符串当前长度内的字节，再兑现 `engine_not_running` 或 `engine_stopped` future。延迟 BM 命令在成功、失败、超时、停机和析构路径沿用现有清理守卫。C++ `std::string` 移动后的源对象状态由实现决定；当前检查确认拒绝入队和 worker leftovers 此时仍持有未消费的命令字符串，清理会覆盖其有效长度。本轮没有引入新的密码容器或重构 BM 协议资料的整体所有权。
- 验证：最新 `tools/build-bm-bridge.ps1` 来源为 dirty tree 提交 `16caaa7b6e9cdaa331e20af4b8b59a83e5a6089d`，41/41 离线测试通过；`engine_test` 使用 fake 串口/音频和 localhost 假 Master，不访问真实 BM、CAT、HRI、音频设备或 RF。新断言覆盖配置失败后没有旧 profile 的第二组 RPTL/RPTK/RPTC，之后有效配置才重新连接；也覆盖拒绝命令 helper 在 future 返回前清空密码，并分别检查 `engine_not_running` 与 `engine_stopped` 结果。测试直接调用共享清理 helper 检查 `engine_stopped` 分支语义，没有用时序竞争强迫真实 worker 在停机瞬间遗留一条 configure 命令。
- 本轮 app 测试由 ap_pc 另行构建，13 个目标通过、0 warning；BM profile race 用例有 16 项检查，operation event queue 用例有 9 项检查。startup group helper/VM 用例覆盖配置频道过滤、首次 BM connected 只启动一次、串行发起、断线暂停和重连续接。它们使用 fake Engine/Service，不发真实 BM 数据报。
- 构建来源记录：Native 为 `build/_work/wirex-bridge-16caaa7-dirty-20261104-112441/build-provenance.json`，41 个测试全部通过；GUI 为 `build/_work/wirex-gui-16caaa7-dirty-20261104-113212/gui-build-provenance.json`，项目警告数为 0。隔离截图和配置目录在 `build/_work/validation-16caaa7-20261104-113212/`。Native、app 和 GUI 验证均未连接真实 CAT/HRI/BM、音频设备或 RF；125% DPI、IME 人工输入、真实设备热插拔和射频行为仍未验证。上述构建均为本地 dirty tree 产物，不是交付包。

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

- 字体从 Windows Fonts 读取：拉丁字符使用 Segoe UI，CJK 优先合并等线，缺少等线时回退黑体，最后使用 ImGui 默认字体；未使用微软雅黑。当前仍由 ImGui stb 栅格化，不使用 DirectWrite。`PixelSnapH` 与物理像素对齐后，“电台控制”标题局部字形覆盖更集中，但改善有限；该结果是局部截图目视比较，不是更换渲染引擎或可读性测量。
- 主界面标题行对齐、频道卡片和控件布局的中英文新旧截图对比已通过；六张频道卡、底部按钮、BM 控件、增益、meter 和状态指示均完整可见。截图为 1360×900、100% DPI。125% DPI 下的显示尚未验证；没有测量文字与背景的量化对比度，也没有在目标显示器上做可读性验收。

### 设备选择显示与热插拔

- 主界面的 HRI、CAT、音频输入和音频输出选择框显示当前配置的解析状态；唯一候选显示 COM 口或音频端点的友好名称，HRI/CAT 同时显示 COM ID。歧义、未枚举、冲突和手动未分类状态各自显示原因。Engine `Snapshot` 的已打开端口/音频端点，以及 `CatState.connected` 确认的 CAT 端口优先显示；CAT 仅 busy 但尚未 confirmed connected 时仍显示配置解析候选，此时主连接按钮显示“连接中”，CAT 指示灯保持未连接。查询成功后才把 CAT 实际端口标为活动端口。如果设备目录刷新后找不到实际活动 ID，界面保留并显示状态报告中的 ID。
- Auto 仍保存在原配置字段中，解析结果只用于显示，不把当前 COM 或音频 endpoint ID 写回配置。HRI 继续使用唯一识别规则；CAT 使用 `resolve_port_selection` 的候选排序和 HRI 排除规则；音频使用 `resolve_audio_endpoints` 的唯一 USB Audio 配对规则。候选不唯一时不自动选择，也不逐个试开未知 COM 口。用户手动选中的未分类 CAT COM 会标为“手动未分类”，不会伪装为已识别设备。
- 收到 Windows `WM_DEVICECHANGE` 到达、移除或设备节点变化消息后，GUI 重新枚举并刷新设备显示；主界面也保留手动刷新入口。刷新不改变保存选择、不发起连接或重连。手动选择的 COM/endpoint 被拔出后仍保留为 requested ID 并显示缺失；相同 ID 再次出现时恢复解析。Auto 会按最新枚举重新解析，COM 编号变化后只在规则可唯一确定时显示新候选。
- 离线测试使用模拟设备目录和既有纯选择函数，检查 Auto 候选与启动/CAT helper 结果一致、多个候选保持歧义、配置不被解析结果改写，以及拔出和重插后的显示状态。CAT 表单测试检查未读回时功率为未知、断开清除可信读数、草稿保留，以及重连成功读回后更新表单。截图用 FakeEngine，并仅只读枚举本机设备目录；没有打开实体串口或实际电台音频流。100% DPI 截图不验证 125% DPI；离线检查也不验证目标机器收到热插拔通知、驱动兼容、CAT/HRI 连接或 RF 行为。

### 待办

1. HRI 实机：复现用户报告的握手失败并记录非敏感诊断字段。当前 fake HRI 覆盖了版本、Y/0、T3/T0 等协议阶段，但无法确定用户设备实际失败的根因。
2. 实机：不带 `--fake` 启动，验证 HRI/CAT 串口、BM 连接、BM-only 本机播放、TG 收听/发射、Quick Call、CAT 门控、身份写回和关闭窗口时有界收尾。BM-only 本机播放目前只在 FakeMaster/FakeWaveOut 环境验证。
3. 打包：在 `ZipOnlyRelease.psm1` 新增 GUI profile（单个 `WirexBridge.exe` 与所需 `licenses/`）；内置 HRI 模板不再作为随包的 `private/device-y.bin` 文件。完成 profile 检查后再交付候选包。
4. 接入 BM RTT 到引擎 `Snapshot` 与 GUI，展示有效值和无数据状态；当前界面仍显示“暂无数据”。
5. 人工验证 IME 中文输入，并在 125% DPI 下复查布局、字体和对比度。
6. 实机通过后再删除 WPF/PowerShell UI、launcher 和 control-v2 适配层。
