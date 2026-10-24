# BM + FTX-1 联调推进交接

## 目标与当前状态

用户授权完成步骤 1–4，交付一个可以开始真实 BM 与电台联合测试的候选；UI 和 RF 节点实测暂缓。四项工作是：

1. 打通 PCM ↔ DMR 语音声码器并完成采样率转换。
2. 实现 BM Homebrew UDP 登录、挑战认证、配置、保活、退避、关闭和 fake Master。
3. 实现 DMR 语音 payload、LC 头/结束、FEC、序号与 60 ms 发送节奏。
4. 在单个 native 控制台接入 HRI 与 BM，处理半双工、限长队列、超时、取消和离线联调。

核心基线为 `3c943413928e1443a2eaa722f730a1e95fdd15b2`，本地集成提交为 `17f3433ae4cd6820622033ddb1910c030cb260f2`。根会话已审阅源码、离线构建和便携候选；阶段文档按用户授权同步到 `main`，实际远端结果以 `git log` 和 `git ls-remote` 为准。步骤 5 的真实 BM 联调身份已由用户准备，接续时不要重复索取。

## 2026-10-24 BM 网络诊断与当前增量

旧 profile 的四次有界 network-only 探测都通过 RPTL/RPTK challenge 和认证 ACK，随后在 RPTC 配置阶段收到 Master 的 `MSTNAK`，生产状态机报告 `master_rejected` 并退回 `backoff`。用户在 `aec0471` 旧候选上运行的一次 native 会话也在 26.6 秒内出现五次同类登录拒绝；该会话打开了 COM/HRI，用户观察到 BM 红 X/PTT，HRI/Y0 握手约 1.125 秒，但没有 BM DMRD 语音往返。之后 A/D/E1/E2/E3 纯 network-only 对照中，E3 组合 profile 到达 BM `ready`，诊断工具也成功调用本机 UDP 发送 `RPTCL`。旧 profile 的服务端拒绝原因仍未知；E3 结果不证明某一个字段是旧拒绝原因，也不代表已完成 DMRD Echo 语音或新源码 native 桥接。认证 ACK 不等于 BM 登录成功，也没有证明密码错误。详细字段、阶段记录和实现资料见 [`BM网络登录诊断.md`](BM网络登录诊断.md)。

`aec04710e9d5b32f416b3b78c3812615fedd1988` 是上一个完成正式构建的源码提交，其中三项测试预设、本机密码文件读取、46001 组呼发射拒绝和 BM 登录状态诊断经 25 项离线测试通过。当前未提交源码增加共用的 BM RPTC 元数据 helper、预设 CC1、基于 BM 与 HRI Y0 双就绪的中文操作提示，以及使用生产 Session 生成 RPTC 并检查 metadata 的离线断言；这些改动待根会话审查和 clean build。旧提交的 25 项测试结果不覆盖当前增量。探测工具默认不由 builder 或自动化调用；真实网络执行仍需显式 `--run-network-only`。

本轮 E3 组合 profile 使用呼号 `BI7KGD`、Gateway ID `461135501`，RX/TX `438800000`、power `0`、CC `1`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、节点类型 `MMDVM_WIREX_Bridge`、options 空。对照实际到达 `ready`，并由诊断工具成功调用本机 UDP 发送 `RPTCL`。native 和 network-only 工具现共用 `apply_network_metadata(Profile&)`，helper 不覆盖呼号、Gateway、密码或调用方 color code；三个预设按 E3 使用 CC1，手工入口继续使用操作者输入的 CC。频率是 BM 节点元数据，不会调整 CAT 或 RF；节点类型表示虚拟 MMDVM 兼容 WIREX 节点，不表示物理 Hat。DroidStar 的参考截图是用户另一个 Gateway ID `461135502`，该身份和配置没有被修改。

## 当前候选与离线证据

已接入 Windows native 控制台入口 `wirex_bridge.exe`。它把 BM 私呼或组呼下行 PCM 播放到所选 FTX-1 DIRECT Radio WaveOut；操作者按 `T` 后才开始 BM DMRD 上行，手咪 PTT 仍由操作者物理操作。上行编码前固定应用 16x 软件 PCM 增益，并用既有 `pcm_gain::SignalStats` 记录增益前后样本数、RMS、峰值及削顶样本数。固定倍率沿用用户确认的旧独立原型人工试听结果；新 BM 链路的声音效果尚未试听验证。程序不发送 RF/PTT 控制命令，`radio_state` 保持 `unknown`。总运行窗口为 120 秒，收尾最多等待 3 秒；BM 断线清空应用媒体，不回灌旧语音。BM EOT 状态只有本地 WinSock `send()` 成功后才记录发送成功；RPTCL 状态也只说明本机 UDP 发送结果，不代表 Master 确认。

启动前状态报告的首次写入或刷新失败时，native 会清除密码并在打开设备前以退出码 2 结束。运行中状态报告写入或刷新失败时，native 标记失败、停止尝试继续写状态报告、执行同一有界收尾并以退出码 2 结束。

HRI T0 写入完成后若在有界等待期内没有观察到对应 `T` 记录，native 会保留 `downlink_call_bounded_cleanup_incomplete` 状态、阻止后续下行，并将会话标记为失败；用户按 `Q` 或运行期限触发收尾时，退出码为 2。

正式 Windows PowerShell 5.1 / VS 2019 builder 曾从干净提交 `17f3433` 构建 `wirex_bridge.exe`、原有 `wirex_probe.exe` 和所有测试，并运行 24 项离线测试，全部通过。测试包括 DMRD、DIRECT、HRI、音频清理、BM Session/UDP、DMR 通话、声码器、重采样、语音管线、HRI streaming session 和 `bm_bridge_loopback_test`。这是 17f3433 版本的历史验证，不覆盖本次尚未 clean-build 的源码增量。完整命令输出记录在 `build/_work/bm-final-17f3433-build.log`；本次源码构建目录为：

```text
build/_work/wirex-bridge-17f3433-20261024-044905/
```

此前的 `003020` 脏构建早于最后的状态报告写入门限与 16x 上行软件增益修复；它的测试结果不作为当前候选验收依据。

本地非 ZIP 便携候选位于 `build/bm-radio-bridge-17f3433/`，包含清洁构建的 `wirex_bridge.exe`、同版本启动器与 README、空 `logs/`、经长度/SHA-256 核对的本机 Y 素材、GPL/ISC 原文及来源说明。`manifest.json` 列出其余每个文件的长度、SHA-256、来源、24 项测试和限制；manifest 自身不在哈希列表中。该包位于 Git 忽略的 `build/` 下，不含旧 EXE、`wirex_probe.exe` 或 ZIP。

根会话审阅确认便携目录共 12 个文件，其中 11 条 manifest 文件记录的长度和 SHA-256 与磁盘一致，包内 EXE 与上述 clean build 产物相同。包内 `--help` 退出码为 0 且显示完整中文帮助；`--list-audio-json` 退出码为 0，输出 schema version 1、3 个输入设备和 5 个输出设备，未打开音频流。静态依赖检查只列出 4 个 Windows 系统 DLL，未发现 Qt 或厂商 DLL。这些检查不等同于真实 BM、HRI、音频或电台联合验收。

`17f3433` 和 `aec0471` 便携目录均为历史候选。`build/bm-radio-bridge-aec0471/` 来源于提交 `aec04710e9d5b32f416b3b78c3812615fedd1988` 的 clean build `build/_work/wirex-bridge-aec0471-20261024-104627/`。根会话确认 builder 退出码为 0，25 项离线测试全部通过；独立包审计确认目录有 13 个实际文件，其中 manifest 记录 11 个非秘密文件，长度和 SHA-256 全部匹配，EXE 与 clean build 产物一致。包内 `--help` 退出码为 0 并显示当时的中文预设，`--list-audio-json` 退出码为 0、schema version 为 1。用户授权的密码文件只保留在本机包的 `private/` 中；它没有进入 manifest 文件列表，也未读取、测量或哈希。`logs/` 为空；候选不是 ZIP，不含 `wirex_probe.exe`。该包使用旧 profile，不包含当前 E3 metadata 和 CC1 改动；包审计和离线测试都不证明真实 BM 桥接或电台行为。

`bm_bridge_loopback_test` 使用生产 BM Session、WinSock UDP、DMR codec/pipeline 和 HRI stream coordinator；fake Master 仅绑定 localhost，HRI T3/T0 与音频播放回执由测试替身提供。它覆盖 TX/EOT、短呼叫先于 T3 结束、private Echo 回包按本机 ID 筛选、丢 EOT watchdog、断线代次隔离和取消后 EOT/RPTCL 顺序。测试没有打开 COM/WinMM，也没有连接真实 Master。

便携包把 `start-bm-radio-bridge.ps1`、`.cmd`、`wirex_bridge.exe`、`private/device-y.bin` 和 `logs/` 放在同一根目录；默认启动只访问这几个包内路径，不搜索包外仓库。源码开发时调用 `tools/start-bm-radio-bridge.ps1` 必须显式指定 `-BridgePath`、`-BodyFile` 与 `-StatusDirectory`；缺少状态目录时，启动器在调用 native 前拒绝运行。构建和启动说明见 [`../tools/bm-radio-bridge-README.md`](../tools/bm-radio-bridge-README.md)。

## 当前文件范围

本集成切片由根会话统一审查。`probe_main.cpp`、`include/wirex/bm_network_metadata.hpp`、`CMakeLists.txt`、BM 测试预设与测试、`tools/bm_network_probe.cpp` 的 metadata 调用、BM 启动器/README、`hri_stream_session` 模块及测试、本文和 `HANDOFF.md` 属于 native 集成范围。声码器、采样率转换、DMR 通话和 BM pipeline/loopback 的实现文件由对应模块 owner 提供；此前正式 builder 已将它们全部编译并实际链接运行，但新 metadata 改动仍待 clean build。

## 未完成的现场验收

- 旧 profile 四轮纯 network-only 探测，以及 `aec0471` 一次 native 会话中的五次登录尝试，均在 RPTC 收到 `MSTNAK`；E3 纯 network-only 对照已到达 BM `ready` 并成功本机发送 `RPTCL`。旧 profile 拒绝原因未知；E3 尚未完成真实 DMRD Echo 语音往返，也未证明当前 native 桥接通过。
- 当前 E3 metadata/CC1 源码改动尚未 clean build；现存 `aec0471` 包只代表旧 profile。根会话审查后还需从 clean HEAD 构建、运行离线测试并生成新便携候选。
- 尚未打开真实 HRI COM、WinMM WaveIn/WaveOut 或电台；没有验证真实设备上的 T3/T0 时序、播放、串口恢复或声音效果。
- 步骤 5 的完整 BM 桥接联调和步骤 6 电台联合端到端测试尚未通过。待根会话审查、clean build 和候选包审计后，由操作者按准备情况安排真实 BM 与 FTX-1 端点联合测试；不把离线 fake Master、包内安全探测或 network-only 控制阶段写成完整桥接通过。
- DIRECT 电台扬声器路径是本候选目标；C4FM RF 节点、自动 PTT、UI 和 RF 节点实测均不在本轮范围内。
