# BM + FTX-1 联调推进交接

## 目标与当前状态

用户授权完成步骤 1–4，交付一个可以开始真实 BM 与电台联合测试的候选；UI 和 RF 节点实测暂缓。四项工作是：

1. 打通 PCM ↔ DMR 语音声码器并完成采样率转换。
2. 实现 BM Homebrew UDP 登录、挑战认证、配置、保活、退避、关闭和 fake Master。
3. 实现 DMR 语音 payload、LC 头/结束、FEC、序号与 60 ms 发送节奏。
4. 在单个 native 控制台接入 HRI 与 BM，处理半双工、限长队列、超时、取消和离线联调。

核心基线为 `3c943413928e1443a2eaa722f730a1e95fdd15b2`，本地集成提交为 `17f3433ae4cd6820622033ddb1910c030cb260f2`。根会话已审阅源码、离线构建和便携候选；阶段文档按用户授权同步到 `main`，实际远端结果以 `git log` 和 `git ls-remote` 为准。步骤 5 的真实 BM 联调身份已由用户准备，接续时不要重复索取。

## 2026-10-25 当前轮状态

- `2183cef` 旧候选的 clean build 曾通过 25 项离线测试并通过便携包审计。随后 native 日志显示 BM 到达 `ready` 且收到了 291 个 DMRD 数据报，但 `calls_started=0`、`calls_ended=0`；原日志没有 DMRD 头元数据，不能仅凭计数认定收到回声。
- 两次有界 network-only 私呼测试使用生产 Session、UDP transport、Transmitter 和 RX-only pipeline，均只向 460997 发送一通 1.98 秒合成 PCM。首次从 TS1 发出后，BM 实际回送 TS2 private stream；本机 ID、呼叫类型、LC 与 CC1 匹配，旧 TS1 filter 将 37 个包全部拒绝。三个 DIRECT preset 因此改为 TS2，过滤仍精确匹配本机目的 ID、单一时隙和呼叫类型。
- 第二次测试从新 `parrot-cn` preset 动态取得呼叫参数，BM 回声被 TS2 filter 接受；Receiver 产生 1 个 start、32 个 voice、1 个 end 事件。RX-only 测试未启用播放，也没有真实 HRI/扬声器路径。
- 用户完成的五轮 HRI DIRECT 手咪观察支持当前 FTX-1 + HRI DIRECT 下，Y/0 ready 后有效 X/100 的 X[12] 按住值为 ASCII `2`、松开值为 ASCII `0`。另一次 120 秒 idle observer 在 120006 ms 正常退出，记录 119 个 Y/0、119 个 X/100；119 个 X/100 均为配置标记 `X[11]=0x31`，Session 产生 119 个 PTT observations，传输未失败。该次运行没有手咪按键动作，不能用 idle observations 作为实机 PTT 边沿验证。
- 用户实测旧 native 候选时，BM 保持 ready 约 194.9 秒，但 `ptt_observations=0`、TX 计数均为 0。对照记录显示，Y/0 ready 后 X[11] 均为 `0x31`；此前两轮手咪按住/松开时 X[12] 分别出现 `0x32`/`0x30`。根因是旧 Session 只在非配置的 Y 模板复制分支产生 PTT observation。当前工作树已把 PTT 字节提取独立于 Y 模板复制，配置分支仍不导入配置且不改 Y 模板规则；聚焦 HRI Session 测试通过。此修复尚未完成正式 clean build 和 26 项全测。
- Windows PowerShell 5.1 的只读生产设备发现函数已通过：唯一选择 COM5、WaveIn 1、WaveOut 3，耗时 10398 ms。启动器按名称关键词 `USB Audio` 选择唯一输入和输出，并把 endpoint ID 交给 native 核对。设备枚举没有打开 COM、音频流或 BM。
- 历史源码提交 `1c8c6fd00081ea8b029c756f537168f4efce4994` 的正式 clean build、26 项离线测试和便携包审计已通过；这些证据不覆盖本轮 Session、console、launcher 修改。旧便携候选 `build/bm-radio-bridge-1c8c6fd` 保持冻结。当前修改尚未正式 clean build、运行全套 26 项测试或打包；自动 PTT + BM + FTX-1 扬声器回声联合实测仍待执行。

当前工作树的 native 候选已将有效 X/100 的 X[12] 状态观察与 Y 模板复制解耦；它仍需新的正式 clean build、全套离线测试和端到端验收。设计目标是由有效手咪 PTT 边沿开始/结束 BM 上行，进程在可见前台持续待机，由 `Q` 等停止请求退出；单通话最多 120 秒。`-ManualPtt` 是显式诊断入口。分层实测与过滤原因见 [`BM回声无播放诊断.md`](BM回声无播放诊断.md)，手咪状态观察见 [`HRI手咪PTT事件研究.md`](HRI手咪PTT事件研究.md)。

## 2026-10-24 网络诊断历史

旧 profile 的四次有界 network-only 探测都通过 RPTL/RPTK challenge 和认证 ACK，随后在 RPTC 配置阶段收到 Master 的 `MSTNAK`，生产状态机报告 `master_rejected` 并退回 `backoff`。用户在 `aec0471` 旧候选上运行的一次 native 会话也在 26.6 秒内出现五次同类登录拒绝；该会话打开了 COM/HRI，用户观察到 BM 红 X/PTT，HRI/Y0 握手约 1.125 秒，但没有 BM DMRD 语音往返。之后 A/D/E1/E2/E3 纯 network-only 对照中，E3 组合 profile 到达 BM `ready`，诊断工具也成功调用本机 UDP 发送 `RPTCL`。旧 profile 的服务端拒绝原因仍未知；E3 结果不证明某一个字段是旧拒绝原因，也不代表已完成 DMRD Echo 语音或新源码 native 桥接。认证 ACK 不等于 BM 登录成功，也没有证明密码错误。详细字段、阶段记录和实现资料见 [`BM网络登录诊断.md`](BM网络登录诊断.md)。

功能源码提交 `2183cef8c2e7364f4c73ee89f8b674c7a7c28750` 已由根会话从 clean HEAD 使用 Windows PowerShell 5.1 / VS 2019 x64 正式构建，25 项离线测试全部通过，包括 RPTC 元数据断言、receive-only 策略、combined 和 console child 测试。构建目录为 `build/_work/wirex-bridge-2183cef-20261024-123605/`，日志为 `build/_work/bm-ready-2183cef-build.log`。network-only 探测工具默认不由 builder 或自动化调用；真实网络执行仍需显式 `--run-network-only`。

本轮 E3 组合 profile 使用呼号 `BI7KGD`、Gateway ID `461135501`，RX/TX `438800000`、power `0`、CC `1`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、节点类型 `MMDVM_WIREX_Bridge`、options 空。对照实际到达 `ready`，并由诊断工具成功调用本机 UDP 发送 `RPTCL`。native 和 network-only 工具现共用 `apply_network_metadata(Profile&)`，helper 不覆盖呼号、Gateway、密码或调用方 color code；三个预设按 E3 使用 CC1，手工入口继续使用操作者输入的 CC。频率是 BM 节点元数据，不会调整 CAT 或 RF；节点类型表示虚拟 MMDVM 兼容 WIREX 节点，不表示物理 Hat。DroidStar 的参考截图是用户另一个 Gateway ID `461135502`，该身份和配置没有被修改。

根会话随后用 commit `2183cef8c2e7364f4c73ee89f8b674c7a7c28750` 的当前共享 helper 编译 `build/_work/bm-probe-final-e3-20261024/bm_network_probe.exe` 并真实运行一次 network-only probe。118 ms 内 BM 对 RPTC 配置返回 ACK，生产 Session 到达 `ready`；程序实际本机发送 9 字节 `RPTCL` 成功后进入 `stopped`，退出码为 0。原始 stdout、summary 和源 SHA 清单保存在该 ignored build 目录中。此结果确认生产源码生成的 E3 元数据可通过 BM 控制配置阶段，但没有打开 HRI/COM/WinMM，也没有验证 DMRD Echo、音频或电台声音。

## 当前候选与离线证据

Windows native 控制台入口 `wirex_bridge.exe` 把 BM 下行 PCM 播放到所选 FTX-1 DIRECT Radio WaveOut；当前默认路径读取经校验的 HRI 串口 PTT 状态，按住边沿触发所选 WaveIn 上行采集，松开边沿结束本次 BM DMRD 呼叫。默认路径不依赖键盘 `T`，也不要求先输入 `START`；`-ManualPtt` 保留显式键盘诊断。默认进程在可见前台持续待机，由 `Q` 等停止请求结束；仅单通话限制 120 秒。上行编码前固定应用 16x 软件 PCM 增益，并记录样本统计。程序不发送 RF/PTT 控制命令，`radio_state` 保持 `unknown`；真实自动 PTT + BM + 扬声器回声仍待用户验证。BM EOT 与 RPTCL 的本地状态只说明本机 UDP send 结果，不代表 Master 确认。

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

当前便携候选为 `build/bm-radio-bridge-2183cef/`，来源为 clean source commit `2183cef8c2e7364f4c73ee89f8b674c7a7c28750` 及上述 25 项全通过的正式构建。根会话独立审计通过：13 个物理文件（含 manifest 与 excluded 凭据），manifest 记录 11 个非秘密文件且长度/hash 有 0 项不匹配；EXE 与正式构建产物相同。包内 `--help` 退出码 0，显示完整中文帮助；音频 JSON 退出码 0、schema 1、type 为 `audio_devices`，WaveIn ID 1 显示为麦克风（2- USB Audio Device）；launcher parser 有 0 个错误；静态依赖只有 WINMM、bcrypt、WS2_32 和 KERNEL32 系统 DLL。密码文件只核实存在，未读内容、长度或 hash；`logs/` 为空。包审计没有打开音频流，也不是 HRI、Echo 语音或电台验收。

`bm_bridge_loopback_test` 使用生产 BM Session、WinSock UDP、DMR codec/pipeline 和 HRI stream coordinator；fake Master 仅绑定 localhost，HRI T3/T0 与音频播放回执由测试替身提供。它覆盖 TX/EOT、短呼叫先于 T3 结束、private Echo 回包按本机 ID 筛选、丢 EOT watchdog、断线代次隔离和取消后 EOT/RPTCL 顺序。测试没有打开 COM/WinMM，也没有连接真实 Master。

便携包把 `start-bm-radio-bridge.ps1`、`.cmd`、`wirex_bridge.exe`、`private/device-y.bin` 和 `logs/` 放在同一根目录；默认启动只访问这几个包内路径，不搜索包外仓库。源码开发时调用 `tools/start-bm-radio-bridge.ps1` 必须显式指定 `-BridgePath`、`-BodyFile` 与 `-StatusDirectory`；缺少状态目录时，启动器在调用 native 前拒绝运行。构建和启动说明见 [`../tools/bm-radio-bridge-README.md`](../tools/bm-radio-bridge-README.md)。

## 当前文件范围

本集成切片由根会话统一审查。`probe_main.cpp`、`include/wirex/bm_network_metadata.hpp`、`CMakeLists.txt`、BM 测试预设与测试、`tools/bm_network_probe.cpp` 的 metadata 调用、BM 启动器/README、`hri_stream_session` 模块及测试、本文和 `HANDOFF.md` 属于 native 集成范围。commit `2183cef` 的正式 builder 已将这些组件全部编译并实际运行 25 项离线测试；声码器、重采样、DMR 通话和 BM pipeline/loopback 也已参与该构建与测试。

## 未完成的现场验收

- 旧 profile 的 RPTC `MSTNAK` 与其拒绝原因仍是历史诊断；之后两次受控私呼网络测试已确认 BM 对该私呼返回 TS2，第二次 RX-only pipeline 已产生 start/voice/end 事件。这证明 BM Echo 网络回声路径存在，不等于用户实际语音或电台扬声器已通过。
- `2183cef` clean build 的 25 项离线测试和旧候选包审计均已通过；它们不覆盖当前工作树的新 PTT 自动触发和 TS2 preset 修改。当前 26 项离线全测及 clean build 等 root 执行。
- 自动串口 PTT + BM 上行和真实电台回声/扬声器播放的端到端验证仍待用户执行。BM network-only、HRI PTT 状态观察、离线 fake Master 和包审计是不同证据，不能互相替代。
- DIRECT 电台扬声器路径是本候选目标；C4FM RF 节点、自动 PTT、UI 和 RF 节点实测均不在本轮范围内。
