# BM + FTX-1 联调推进交接

## 目标与当前状态

用户授权完成步骤 1–4，交付一个可以开始真实 BM 与电台联合测试的候选；UI 和 RF 节点实测暂缓。四项工作是：

1. 打通 PCM ↔ DMR 语音声码器并完成采样率转换。
2. 实现 BM Homebrew UDP 登录、挑战认证、配置、保活、退避、关闭和 fake Master。
3. 实现 DMR 语音 payload、LC 头/结束、FEC、序号与 60 ms 发送节奏。
4. 在单个 native 控制台接入 HRI 与 BM，处理半双工、限长队列、超时、取消和离线联调。

核心基线为 `3c943413928e1443a2eaa722f730a1e95fdd15b2`，本地集成提交为 `17f3433ae4cd6820622033ddb1910c030cb260f2`。根会话已审阅源码、离线构建和便携候选；阶段文档按用户授权同步到 `main`，实际远端结果以 `git log` 和 `git ls-remote` 为准。步骤 5 的真实 BM 联调身份已由用户准备，接续时不要重复索取。

## 当前候选与离线证据

已接入 Windows native 控制台入口 `wirex_bridge.exe`。它把 BM 私呼或组呼下行 PCM 播放到所选 FTX-1 DIRECT Radio WaveOut；操作者按 `T` 后才开始 BM DMRD 上行，手咪 PTT 仍由操作者物理操作。上行编码前固定应用 16x 软件 PCM 增益，并用既有 `pcm_gain::SignalStats` 记录增益前后样本数、RMS、峰值及削顶样本数。固定倍率沿用用户确认的旧独立原型人工试听结果；新 BM 链路的声音效果尚未试听验证。程序不发送 RF/PTT 控制命令，`radio_state` 保持 `unknown`。总运行窗口为 120 秒，收尾最多等待 3 秒；BM 断线清空应用媒体，不回灌旧语音。BM EOT 状态只有本地 WinSock `send()` 成功后才记录发送成功；RPTCL 状态也只说明本机 UDP 发送结果，不代表 Master 确认。

启动前状态报告的首次写入或刷新失败时，native 会清除密码并在打开设备前以退出码 2 结束。运行中状态报告写入或刷新失败时，native 标记失败、停止尝试继续写状态报告、执行同一有界收尾并以退出码 2 结束。

HRI T0 写入完成后若在有界等待期内没有观察到对应 `T` 记录，native 会保留 `downlink_call_bounded_cleanup_incomplete` 状态、阻止后续下行，并将会话标记为失败；用户按 `Q` 或运行期限触发收尾时，退出码为 2。

正式 Windows PowerShell 5.1 / VS 2019 builder 从干净提交 `17f3433` 构建 `wirex_bridge.exe`、原有 `wirex_probe.exe` 和所有测试，并运行 24 项离线测试，全部通过。测试包括 DMRD、DIRECT、HRI、音频清理、BM Session/UDP、DMR 通话、声码器、重采样、语音管线、HRI streaming session 和 `bm_bridge_loopback_test`。完整命令输出记录在 `build/_work/bm-final-17f3433-build.log`；本次源码构建目录为：

```text
build/_work/wirex-bridge-17f3433-20261024-044905/
```

此前的 `003020` 脏构建早于最后的状态报告写入门限与 16x 上行软件增益修复；它的测试结果不作为当前候选验收依据。

本地非 ZIP 便携候选位于 `build/bm-radio-bridge-17f3433/`，包含清洁构建的 `wirex_bridge.exe`、同版本启动器与 README、空 `logs/`、经长度/SHA-256 核对的本机 Y 素材、GPL/ISC 原文及来源说明。`manifest.json` 列出其余每个文件的长度、SHA-256、来源、24 项测试和限制；manifest 自身不在哈希列表中。该包位于 Git 忽略的 `build/` 下，不含旧 EXE、`wirex_probe.exe` 或 ZIP。

根会话审阅确认便携目录共 12 个文件，其中 11 条 manifest 文件记录的长度和 SHA-256 与磁盘一致，包内 EXE 与上述 clean build 产物相同。包内 `--help` 退出码为 0 且显示完整中文帮助；`--list-audio-json` 退出码为 0，输出 schema version 1、3 个输入设备和 5 个输出设备，未打开音频流。静态依赖检查只列出 4 个 Windows 系统 DLL，未发现 Qt 或厂商 DLL。这些检查不等同于真实 BM、HRI、音频或电台联合验收。

`bm_bridge_loopback_test` 使用生产 BM Session、WinSock UDP、DMR codec/pipeline 和 HRI stream coordinator；fake Master 仅绑定 localhost，HRI T3/T0 与音频播放回执由测试替身提供。它覆盖 TX/EOT、短呼叫先于 T3 结束、private Echo 回包按本机 ID 筛选、丢 EOT watchdog、断线代次隔离和取消后 EOT/RPTCL 顺序。测试没有打开 COM/WinMM，也没有连接真实 Master。

便携包把 `start-bm-radio-bridge.ps1`、`.cmd`、`wirex_bridge.exe`、`private/device-y.bin` 和 `logs/` 放在同一根目录；默认启动只访问这几个包内路径，不搜索包外仓库。源码开发时调用 `tools/start-bm-radio-bridge.ps1` 必须显式指定 `-BridgePath`、`-BodyFile` 与 `-StatusDirectory`；缺少状态目录时，启动器在调用 native 前拒绝运行。构建和启动说明见 [`../tools/bm-radio-bridge-README.md`](../tools/bm-radio-bridge-README.md)。

## 当前文件范围

本集成切片由根会话统一审查。`probe_main.cpp`、`CMakeLists.txt`、`tools/build-bm-bridge.ps1`、BM 启动器/README、`hri_stream_session` 模块及测试、本文和 `HANDOFF.md` 属于 native 集成 owner 范围。声码器、采样率转换、DMR 通话和 BM pipeline/loopback 的实现文件由对应模块 owner 提供；此次正式 builder 已将它们全部编译并实际链接运行。

## 未完成的现场验收

- 尚未连接任何真实 BrandMeister Master；登录兼容性和真实网络持续运行未验证。
- 尚未打开真实 HRI COM、WinMM WaveIn/WaveOut 或电台；没有验证真实设备上的 T3/T0 时序、播放、串口恢复或声音效果。
- 步骤 5 真实 BM 联调和步骤 6 电台联合端到端测试尚未开始。根会话已完成源码、clean build 和便携包审阅；接下来由操作者按准备情况安排真实 BM 与 FTX-1 端点联合测试，不把离线 fake Master 结果写成实机通过。
- DIRECT 电台扬声器路径是本候选目标；C4FM RF 节点、自动 PTT、UI 和 RF 节点实测均不在本轮范围内。
