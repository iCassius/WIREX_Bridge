# R128 全原生 GUI 重构（设计决定）

更新：2026-11-04。对应 TODO 3.3。分支 `feat/r128-native-gui`。

## 决定

| 项 | 选择 | 理由 |
| --- | --- | --- |
| GUI | **Dear ImGui + Win32 + DirectX 11**，静态链接进单个 `WirexBridge.exe` | 约 10 个源文件 vendor 到 `third_party/imgui`（MIT，兼容 GPL-3）；沿用现有 MSVC 2019 `cl.exe` 构建，不新增 CMake/Rust/Qt SDK；即时模式每帧直接读引擎快照，不需要绑定层；中文字体运行时读系统自带的 `msyh.ttc`，exe 不用内嵌字体 |
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
4. **集成**：GUI 接真实 Engine 和服务；ZIP 内容变成 `WirexBridge.exe` + `licenses/` + `private/device-y.bin`。
5. **退役**：新 GUI 达到功能对等并完成实机验收后，删除 `ui/windows/`、launcher、`tools/start-*.ps1` 和 control-v2 适配层。

## 验收门槛

- 编译 0 warning；Native 测试与新增 engine/app 测试全部通过。
- 原有离线回归（PS 侧）在退役前保持通过。
- GUI 离线截图（中/英）人工视检；空闲 CPU 与内存给出实测值。
- 实机：TODO 第一节各项要用新 GUI 重新验收一遍，才能删除旧 UI。

## 进度（2026-11-04）

步骤 1–4 的代码已全部合入 `feat/r128-native-gui`。真实设备、BM 网络和 RF 都还没实机验收，所以步骤 5（退役旧 UI）暂不进行。

| 项 | 结果（主 checkout 实测） |
| --- | --- |
| 引擎 | `src/engine/`；`probe_main.cpp` 由 8321 行降到约 4670 行。`--ui-pipe` 适配层的 `status.jsonl` 与 R127 exe 对比逐字节一致（run_id/时间戳规范化后）；`--control-diagnostic`/`--routing-diagnostic` 输出逐行一致 |
| Native 测试 | full40 + `engine_test` = 41/41，0 warning |
| app 服务测试 | `tools/build-app-tests.ps1`：config 392、devices 83、CAT 163、BM API 285、RadioID 234、gui_config_bridge 83，0 warning |
| 离线回归 | `wirex test --offline` 53 项（Native 41 + PowerShell 12）通过；`test-ui-console` 偶发失败一次（真实串口枚举相关，连续重跑 3 次均通过） |
| GUI | `wirex build --gui` 产出单个 `WirexBridge.exe`（约 2.1 MB，/MT 静态链接，引擎在进程内，0 warning） |
| 资源 | 真实引擎、未连接设备时：空闲 CPU 0.00%，工作集约 86 MiB（主要是 D3D11 与中文字体图集） |

### GUI 启动参数

- 无参数：真实引擎 + 真实服务；`config.json` 放在 exe 同目录，首次运行自动生成。HRI 模板从 `<exe>/private/device-y.bin` 或 `<exe>/runtime/private/` 读取。
- `--fake`：模拟引擎 + 真实服务。`--fake --fake-services`：完全离线。
- `--screenshot <png>`、`--open-settings`、`--config <json>`、`--check-config`。

### 与旧版的行为差异（实机验收时确认）

- CAT 设置模式/频率：要求核心**已停止**（app::radio_cat 门控）；旧版只要求核心空闲。
- CAT 功率的“接收队列为空”条件：快照里没有队列深度，暂时用 `media_owner==idle` 代替。
- `Snapshot::levels` 是累计峰值，不是实时电平。
- 窗口大小可调整（最小 1180×780）；连接配置、Wires-X 串口和音频端点移到了设置弹窗里。

### 待办

1. 实机：不带 `--fake` 启动，依次验证连接串口 → 连接 BM → TG 收听/发射 → Quick Call → CAT 门控 → 身份写回 → 关闭窗口时有界收尾。
2. 打包：在 `ZipOnlyRelease.psm1` 新增 GUI profile（`WirexBridge.exe` + `private/device-y.bin` + `licenses/`），替代 launcher + `runtime/` 的结构。
3. IME 中文输入人工验证一次；中英文截图视检。
4. 实机通过后进入步骤 5：删除 WPF/PowerShell UI、launcher 和 control-v2 适配层。
