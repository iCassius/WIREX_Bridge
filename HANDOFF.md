# WIREX Bridge 交接入口

更新：2026-11-06（R128–R130）。本文只记录当前状态；更早的交接（R103–R127）可用 `git log -- HANDOFF.md` 查看。系统组成见 [ARCHITECTURE](docs/ARCHITECTURE.md)，待办以 [TODO](TODO.md) 为准。

## 当前版本

| 项 | 状态 |
| --- | --- |
| `feat/r128-native-gui` | 单进程原生 C++ GUI（Dear ImGui + DX11）+ 进程内引擎 + C++ 服务 + FM 中继（R130，`914b346..27e4da4`）；头部为 `27e4da4` 之后的 FM 中继文档同步提交。**未推送** |
| 旧 WPF UI | `ui/windows/`、launcher、`tools/start-*.ps1`、`--ui-pipe` 适配层仍在仓库中，实机验收通过后退役 |
| stable `v0.1.0` | tag 指向 `c12b50a`，GitHub Release 已发布；发布审计见 [R124_RELEASE](docs/R124_RELEASE.md) |
| 本机单 EXE | R128 单 EXE 仅在本机交付，未打包；单 EXE 的 ZIP profile 尚未建立 |

## HRI 实机连接

已修复 `clock_regressed`（`connect_radio` 后主循环用旧时钟驱动 HRI 会话），见提交 `a50b234`。HRI 固定 115200 8N1，CAT 按配置波特率 8N2；握手时序见 ARCHITECTURE 第 6 节。

## FM 中继（R130）

- 右上角“启用中继”写 `relay.enabled`，下次连接电台使用 AP Y 模板（offset 0x05 为 `'1'`）；中继开启后 FM 按钮写 `relay.fm_enabled`。电台已连接时切换只提示需重连。
- 中继与 FM 都开启且 CAT 已连接时，每 100 ms 只读 `RI0;`+`SM0;`，静噪开门/关门驱动引擎 `relay_fm_start()`/`relay_fm_stop()`；单段最长 180 s。
- 记录：来话历史黄色“FM 中继 → TG …”与 `<exe>/private/runtime/relay-log.jsonl`。
- 2026-11-06 实测：145.200 MHz FM 下按键后 P8 在下一次轮询内 0→1；原始数据在父目录 `research/hil/2026-11-06_fm_squelch_capture2.jsonl`。
- 规则与结束原因见 [R128_NATIVE_GUI](docs/R128_NATIVE_GUI.md)“FM 中继”。

## dev 日志

- 开发版构建（`tools/build-gui.ps1` 不带 `-Release`，`WIREX_DEV_BUILD=1`）默认开启；`-Release` 构建默认关闭。
- 命令行覆盖：`WirexBridge.exe --dev-log` 强制开启，`--no-dev-log` 强制关闭。
- 输出：`<exe 目录>/logs/wirex-<本地时间>.log`，逐行 flush。内容为引擎状态行、操作员提示、GUI 操作结果、HRI 帧类型/字节数；不含密码、API Key、串口正文和音频。

## 已知差异与待办

与旧版的行为差异（实机确认）：
- CAT 设置模式/频率要求核心已停止（旧版为核心空闲）；功率门控用 `media_owner==idle` 近似“接收队列为空”。
- 窗口可调整大小（最小 1180×780），设备与 BM 配置都在主界面，没有设置弹窗。
- BM 静态组与收听频道双向同步；主界面显示 BM RTT 与会话丢包率。

待办（详见 TODO）：
- [ ] 实机（不带 `--fake`）验证 HRI/CAT、BM 连接、BM-only 本机播放、TG46001 收听、启动组呼、CAT 门控、关窗有界收尾。
- [ ] 音频断续/破音专项（另有 agent 处理，见 TODO 第零节）。
- [ ] 实机验证 AP 模板与 DIRECT 模板在 AP PC 电台上的握手。
- [ ] 实机验证 FM 中继端到端（RF → BM）与转发音量。
- [ ] 评估 100 ms CAT 轮询负载。
- [ ] C4FM 中继（阻塞于 `R` 记录格式，见 TODO 1.3）。
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
- app/GUI 逻辑测试：`tools/build-app-tests.ps1`（18 个目标，输出 `build/app-tests/`）。
- 当前基线（主 checkout 实测）：Native 41/41、app 18 项全部通过，GUI 编译 0 warning。
- ImGui 重复 ID 检查：`tools/run-gui-duplicate-item-harness.ps1`。
- 所有离线测试使用 fake 设备与 localhost 假 Master，不代表实机或 RF 验收。

## 文档索引

| 文档 | 用途 |
| --- | --- |
| [README.md](README.md) | 用户使用说明（用户维护，不随交接修改） |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 当前系统架构 |
| [docs/R128_NATIVE_GUI.md](docs/R128_NATIVE_GUI.md) | R128 原生 GUI 设计决定与行为规则（含原 R129 启动组呼、R130 FM 中继） |
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
