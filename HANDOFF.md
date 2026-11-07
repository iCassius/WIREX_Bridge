# WIREX Bridge 交接入口

更新：2026-11-07（R128–R135）。本文只记录当前状态；更早的交接（R103–R127）可用 `git log -- HANDOFF.md` 查看。系统组成见 [ARCHITECTURE](docs/ARCHITECTURE.md)，待办以 [TODO](TODO.md) 为准。

## 当前版本

| 项 | 状态 |
| --- | --- |
| `feat/r128-native-gui` | 单进程原生 C++ GUI（Dear ImGui + DX11）+ 进程内引擎 + C++ 服务；R132–R134 动态 Y 记录与实机修复。已发布 `v0.2.0`（`e23dff9`）与 `v0.2.1`（电台/BM 解耦、未收听提示、身份占位与 GPL-3.0 LICENSE）；main 与 tag 均已推送。 |
| 旧 WPF UI | `ui/windows/`、launcher、`tools/start-*.ps1`、`--ui-pipe` 适配层仍在仓库中，实机验收通过后退役 |
| stable `v0.1.0` | tag 指向 `c12b50a`，GitHub Release 已发布；发布审计见 [R124_RELEASE](docs/R124_RELEASE.md) |
| `v0.2.0` 发布包 | 单 EXE ZIP profile：`wirex build --gui --release` 后用 `wirex package-gui --version v0.2.0` 生成（`package-gui` 由另一 Agent 实现中）；包内为 `WirexBridge.exe` + `licenses/` + `README.md`，不含 `private/device-y.bin` |

## R135 版本号与更新提示（2026-11-07）

- 版本/作者单一来源：`include/wirex/version_rc.h`（普通宏，供 rc.exe 与 C++ 共用），`include/wirex/version.hpp` 由它派生；`src/gui/wirex_gui.rc` 写入 VERSIONINFO（版本、ProductName、CompanyName=BI7KGD、GPL 版权）。
- `wirex package-gui --version` 校验 `--version`（去掉 `v`）与 `version_rc.h` 一致，不一致直接拒绝；`manifest.json` 记录 `app_version`。
- GUI：标题栏版本标签 + `by BI7KGD`，检测到新版本时标签变绿并链接发布页；不弹窗，启动后检查一次、之后每 6 h，`ui.update_check: false` 可关闭；窗口标题含版本。
- 文档：README 版本指针改为 v0.2.2，新增 [docs/releases/v0.2.2.md](docs/releases/v0.2.2.md)。

## 发版步骤

1. 修改 `include/wirex/version_rc.h`（版本与作者；`version.hpp` 自动派生）。
2. 编写 `docs/releases/vX.Y.Z.md`。
3. 提交改动。
4. `wirex build --gui --release`。
5. `wirex package-gui --version vX.Y.Z`（与版本头文件不一致会被拒绝）。

## HRI 动态 Y 记录与实机修复（R132–R134）

已修复 `clock_regressed`（`connect_radio` 后主循环用旧时钟驱动 HRI 会话），见提交 `a50b234`。HRI 固定 115200 8N1，CAT 按配置波特率 8N2；握手时序见 ARCHITECTURE 第 6 节。

- **功率弹回 25 W（R132）**：根因是内嵌 Y 模板 `2f..32`（`LCH_TXPWR`，0.1 W）为 `0250`，电台每收到一次 Y 就把功率重设为 25 W，CAT `PC` 写入只能维持到下一次 Y。逆向报告见 [`research/planning/R132_Y动态字段与官方生成时机.md`](../research/planning/R132_Y动态字段与官方生成时机.md)，专项交接见 [`HANDOFF_Y记录动态生成.md`](../HANDOFF_Y记录动态生成.md)。
- **P0 实现（`71565d4..d275bbc`）**：Y 正文构造器白名单 `05`、`0C`、`2f..32`（功率 5–50 W 整瓦）；引擎 `set_hri_tx_power` 在下行中挂起、重连后保持，首条 Y 即目标功率；GUI/CAT 联动并持久化 `devices.desired_power_watts`。实机 5 W / 10 W 经 Y 下发后周期 `PC;` 读回不再弹回 25 W。
- **R133 频率与模式（`3165915..850e761`）**：白名单加 `0x0E`（'1' FM / '2' C4FM-DN）与 `0x10..0x19`（Hz，仅 144–148 / 430–440 MHz，1 kHz 整倍）；功率、频率、模式共用同一份 Y 字段状态。HRI 已连接时频率/模式只走 Y（不发 CAT `FA`/`MD`）并约 1.2 s 读回，功率走 Y + CAT `PC2` 回显；`devices.hri_frequency_hz`/`hri_mode` 持久化（默认不写入，PS 默认配置保持逐字节兼容）。2026-11-07 实机确认频率与模式生效。
- **R134 修复**：动态组停用/启用遇来话时引擎排队到来话结束再执行（`73f2786`），GUI 仅在引擎接受后移出收听（`f2c9f0f`）；Y 功率挂起期间不再立即发 CAT `PC` 回显（`c1db99a`）；选择 C4FM-DN 显示“PC 语音不支持”（`f73d536`、`7f51526`）；dev 日志增加 Y/X 字节转储与 `ptt_pressed_but_radio_not_transmitting` 告警（`a7fa513`）。
- **PTT 问题（2026-11-07）**：`_bisect/13` 中手咪 PTT 期间 CAT 一直 `TX0;`，采集到接收底噪；`_bisect/14` 重测 PTT、频率、功率、模式均正常，问题未复现，按已解决记录。

## FM 中继（R130）

- 右上角“启用中继”写 `relay.enabled`；中继开启后 FM 按钮写 `relay.fm_enabled`。连接电台默认用 DIRECT Y 模板（实测 AP PC 电台下与 AP 变体无区别），`relay.y_template: "ap"` 可切到 AP 变体。电台已连接时切换只提示需重连。
- 尾音（R131）：静噪第一个关门采样即 `relay_fm_mute(true)`，hang 内重新开门恢复；FM 上行经 120 ms 前瞻缓冲，静音时缓冲内未送出部分一并清零。
- 中继与 FM 都开启且 CAT 已连接时，每 100 ms 只读 `RI0;`+`SM0;`，静噪开门/关门驱动引擎 `relay_fm_start()`/`relay_fm_stop()`；单段最长 180 s。
- 记录：来话历史黄色“FM 中继 → TG …”与 `<exe>/private/runtime/relay-log.jsonl`。
- 2026-11-06 实测：145.200 MHz FM 下按键后 P8 在下一次轮询内 0→1；原始数据在父目录 `research/hil/2026-11-06_fm_squelch_capture2.jsonl`。
- 规则与结束原因见 [R128_NATIVE_GUI](docs/R128_NATIVE_GUI.md)“FM 中继”。

## R131 实机反馈修复（2026-11-06）

- **HRI 自动重连**：电台曾 hri_ready 后掉线（串口错误、Y/0 超时、会话异常停止）自动重试：能开串口每 3 s，打不开时 3→6→10 s 退避；用户断开即停。期间 BM 与本机播放照常。事件 `hri_lost`/`hri_restored`，快照 `hri_reconnecting`/`hri_reconnect_attempts`。
- **频道状态机**：静态组主按钮“静音/取消静音”（照常接收显示，只是 `set_muted_groups` 清零播放 PCM）；动态组“停用/启用”（停用移出 RX 策略并发 TG4000 `disconnect_dynamic_groups`，会断开同时隙全部动态组；启用重新加入并 Quick Call）。徽标：静态组/静音/动态·已激活/动态·未激活/已停用。`channels[].muted/disabled` 持久化。
- **音量**：两条滑块直接设所选 WaveOut/WaveIn 端点的 Windows 音量（`IAudioEndpointVolume`，外部改动同步）；软件数字增益默认 1× 收进“高级”。电平表改 dBFS，虚线 −18 dBFS 为平均电平参考（实测舒适峰值约 −9 dBFS）。
- **CAT 门控**：频率/模式只在发射中或 HRI 正在向电台播放时禁止；功率只在发射中禁止。被拦时保留草稿、门控解除后自动重试一次；电台拒绝时如实显示。
- **BM 重连**：断开后“连接BM”冷却 5 s；60 s 内同一 profile 的 `master_rejected` 视为旧会话未释放，界面每 5 s 自动重试（最多 4 次）。

## dev 日志

- 开发版构建（`tools/build-gui.ps1` 不带 `-Release`，`WIREX_DEV_BUILD=1`）默认开启；`-Release` 构建默认关闭。
- 命令行覆盖：`WirexBridge.exe --dev-log` 强制开启，`--no-dev-log` 强制关闭。
- 输出：`<exe 目录>/logs/wirex-<本地时间>.log`，逐行 flush。内容为引擎状态行、操作员提示、GUI 操作结果、HRI 帧类型/字节数；不含密码、API Key、串口正文和音频。

## 已知差异与待办

与旧版的行为差异（实机确认）：
- 窗口可调整大小（最小 1180×780），设备与 BM 配置都在主界面，没有设置弹窗。
- BM 静态组与收听频道双向同步；主界面显示 BM RTT 与会话丢包率。

待办（详见 TODO）：
- [ ] 实机（不带 `--fake`）验证 HRI/CAT、BM 连接、BM-only 本机播放、TG46001 收听、启动组呼、CAT 门控、关窗有界收尾。
- [ ] 实机确认 R131：FM 尾音、HRI 退出/重入自动恢复、静音/停用行为、Windows 音量联动、CAT 改频（HRI 模式下电台是否接受）、BM 冷却。
- [ ] 评估 100 ms CAT 轮询负载。
- [ ] C4FM 中继（阻塞于 `R` 记录格式，见 TODO 1.3）。
- [ ] 125% DPI 下验收字体与布局；人工验证 IME 中文输入。
- [ ] 单 EXE ZIP profile（v0.2.0）：`wirex build --gui --release` + `wirex package-gui --version v0.2.0`（`package-gui` 实现中）；完成后在干净目录核对首次启动配置生成。
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
