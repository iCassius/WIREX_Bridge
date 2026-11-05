# WIREX Bridge 交接入口

更新：2026-11-05（R128）。本文只记录当前状态；更早的交接（R103–R127）可用 `git log -- HANDOFF.md` 查看。系统组成见 [ARCHITECTURE](docs/ARCHITECTURE.md)，待办以 [TODO](TODO.md) 为准。

## 当前版本

| 项 | 状态 |
| --- | --- |
| `feat/r128-native-gui` | 单进程原生 C++ GUI（Dear ImGui + DX11）+ 进程内引擎 + C++ 服务；头部为 dev 日志提交 `89d2a72` 之后的文档整理提交。**未推送** |
| 旧 WPF UI | `ui/windows/`、launcher、`tools/start-*.ps1`、`--ui-pipe` 适配层仍在仓库中，实机验收通过后退役 |
| stable `v0.1.0` | tag 指向 `c12b50a`，GitHub Release 已发布；发布审计见 [R124_RELEASE](docs/R124_RELEASE.md) |
| 本机单 EXE | R128 单 EXE 仅在本机交付，未打包；单 EXE 的 ZIP profile 尚未建立 |

## HRI 实机连接：二分排查中

用户报告当前版本连接不上电台（HRI 不就绪）。正在用 `FTX1_project/_bisect/` 下 5 个目录逐个对照，按版本二分定位引入问题的改动。尚无结论。

方法：全程不按 PTT、不发射；每个目录测完关闭程序再测下一个；记录能否 HRI 就绪及报错原文（截图即可）。

| 目录 | 内容 | 说明 |
| --- | --- | --- |
| `0-wpf-v010-original` | 已发布 v0.1.0（旧 WPF + 旧引擎） | 基线，预期可连 |
| `1-wpf-v010-new-engine` | v0.1.0 的 WPF，`runtime/wirex_bridge.exe` 换成当前引擎（`89d2a72`） | 区分 UI 与引擎 |
| `2-gui-ff2bb16` | 第一个接上真实引擎的原生 GUI | 需 `private/device-y.bin`（已放好） |
| `3-gui-9e789c9` | codex 第一次改动（内嵌 Y 模板、串口识别、联合启停） | 需 `private/device-y.bin`（已放好） |
| `4-gui-current` | 当前版本 + dev 日志（`logs/` 目录） | 使用内嵌模板 |

0/1 使用 v0.1.0 包内自带的 `config.json`；2/3/4 使用用户个人的 `config.json`。目录 4 的 dev 日志会记录 HRI 帧类型与字节数，可用于对照 V/Y 握手阶段。

相关源码事实（不是结论）：HRI 固定 115200 8N1（`src/engine/win_io.hpp` `configure_serial`）；CAT 按配置波特率 8N2，默认 38400，界面波特率只作用于 CAT。握手时序见 ARCHITECTURE 第 6 节。

## dev 日志

- 开发版构建（`tools/build-gui.ps1` 不带 `-Release`，`WIREX_DEV_BUILD=1`）默认开启；`-Release` 构建默认关闭。
- 命令行覆盖：`WirexBridge.exe --dev-log` 强制开启，`--no-dev-log` 强制关闭。
- 输出：`<exe 目录>/logs/wirex-<本地时间>.log`，逐行 flush。内容为引擎状态行、操作员提示、GUI 操作结果、HRI 帧类型/字节数；不含密码、API Key、串口正文和音频。

## 已知差异与待办

与旧版的行为差异（实机确认）：
- CAT 设置模式/频率要求核心已停止（旧版为核心空闲）；功率门控用 `media_owner==idle` 近似“接收队列为空”。
- 窗口可调整大小（最小 1180×780），设备与 BM 配置都在主界面，没有设置弹窗。
- BM RTT 尚未接入 `Snapshot`，主界面显示“暂无数据”。

待办（详见 TODO）：
- [ ] 完成 HRI 二分排查并修复。
- [ ] 实机（不带 `--fake`）验证 HRI/CAT、BM 连接、BM-only 本机播放、TG46001 收听、启动组呼、CAT 门控、关窗有界收尾。
- [ ] 音频断续/破音专项（另有 agent 处理，见 TODO 第零节）。
- [ ] BM RTT 接入快照与界面。
- [ ] 125% DPI 下验收字体与布局；人工验证 IME 中文输入。
- [ ] 为单 EXE 建立 ZIP profile 并核对首次启动配置生成。
- [ ] 实机通过后退役 WPF/PowerShell UI、launcher 与 control-v2 适配层。

## 环境注意事项

- **从 Git Bash 调用 Windows PowerShell 5.1**：必须先重置模块路径，否则会继承 PowerShell 7 的路径，导致 `Get-FileHash` 等命令找不到：
  ```sh
  PSModulePath='C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules' \
    powershell.exe -NoLogo -NoProfile -File tools/build-gui.ps1
  ```
- **编码**：`.ps1`/`.psm1` 必须保留 UTF-8 BOM。PS5.1 会把无 BOM 文件按本机 ANSI 读取，中文字符串变乱码甚至解析失败。
- **测试前置条件**：旧 PS 离线回归与打包测试需要 `private/fixtures/device-y.bin`（HRI 模板）、`build/releases/v0.1.0`（已发布包目录）和本地 `v0.1.0` tag。三者都不在 Git 工作树中，新 worktree 需另行准备（`wirex` 会回退到主 checkout 的 fixture）。GUI 本身使用内嵌模板，不需要 fixture。
- **vendor 字节**：`third_party/droidstar_mbe/upstream/**` 标记为 `-text`，由 `source-manifest.json` 锁定 SHA-256，不得改动行尾。

## 构建与测试

```sh
go build -o build/wirex.exe ./tools/wirex   # 仓库根
build/wirex.exe doctor                      # 环境检查
build/wirex.exe build --gui                 # 原生 GUI（= tools/build-gui.ps1，开发版）
build/wirex.exe build [--compile-only]      # Native 核心 + 41 项测试（tools/build-bm-bridge.ps1）
build/wirex.exe test --offline              # Native + PowerShell 离线回归（旧 UI）
```

- 正式版 GUI：`tools/build-gui.ps1 -Release`（dev 日志默认关闭）。产物在 `build/_work/wirex-gui-<commit7>[-dirty]-<UTC>/`。
- app/GUI 逻辑测试：`tools/build-app-tests.ps1`（14 个目标，输出 `build/app-tests/`）。
- ImGui 重复 ID 检查：`tools/run-gui-duplicate-item-harness.ps1`。
- 所有离线测试使用 fake 设备与 localhost 假 Master，不代表实机或 RF 验收。

## 文档索引

| 文档 | 用途 |
| --- | --- |
| [README.md](README.md) | 用户使用说明（用户维护，不随交接修改） |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 当前系统架构 |
| [docs/R128_NATIVE_GUI.md](docs/R128_NATIVE_GUI.md) | R128 原生 GUI 设计决定与行为规则（含原 R129 启动组呼） |
| [TODO.md](TODO.md) | 权威待办清单 |
| `docs/R126_*.md`、[docs/R124_RELEASE.md](docs/R124_RELEASE.md) | 旧 WPF 版 R126 设计记录与 v0.1.0 发布审计 |
| `docs/releases/` | Release 正文与包内 README，由打包/发布脚本按路径读取 |
| `docs/` 下其余 14 份（`BM来话身份显示`、`R106_*`、`R108_*`、`R109_*`、`R112_A_网络音频指标`、`R113_*`、`R116_*`、`连接配置`、`配置与桌面操作`、`音量调节`） | v0.1.0 包内 `runtime/docs/` 文档，脚本和测试按路径与内容引用，**不能改名或修改内容** |
| `docs/DMR通话实现.md` | DMR FEC/LC 上游来源说明，`include/wirex/dmr_call.hpp` 按路径引用 |
| `docs/research/` | 研究资料，只代表研究当时的结论 |

改动 `docs/` 前，先确认文件没有被代码引用：

```sh
git grep -ohE "docs[\\\\/][^'\" )\`|]+\.md" -- tools ui src tests include
```
