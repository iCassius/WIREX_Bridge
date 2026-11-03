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
