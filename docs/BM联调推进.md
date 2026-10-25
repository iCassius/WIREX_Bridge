# BM + FTX-1 联调推进交接

## 目标与当前状态

用户授权完成步骤 1–4，交付一个可以开始真实 BM 与电台联合测试的候选；UI 和 RF 节点实测暂缓。四项工作是：

1. 打通 PCM ↔ DMR 语音声码器并完成采样率转换。
2. 实现 BM Homebrew UDP 登录、挑战认证、配置、保活、退避、关闭和 fake Master。
3. 实现 DMR 语音 payload、LC 头/结束、FEC、序号与 60 ms 发送节奏。
4. 在单个 native 控制台接入 HRI 与 BM，处理半双工、限长队列、超时、取消和离线联调。

核心基线为 `3c943413928e1443a2eaa722f730a1e95fdd15b2`，本地集成提交为 `17f3433ae4cd6820622033ddb1910c030cb260f2`。根会话已审阅源码、离线构建和便携候选；阶段文档按用户授权同步到 `main`，实际远端结果以 `git log` 和 `git ls-remote` 为准。步骤 5 的真实 BM 联调身份已由用户准备，接续时不要重复索取。

## 2026-10-25 当前轮状态

- 最新源码提交为 `5e3343372d9b0427b5c25943a731292e65b1f7ca`，新增 BM→电台回放与手咪→BM 上行的独立 PCM 增益设置，默认 `1.0x`/`16x`。正式 clean build 与 26 项离线测试全部通过，compiler warning/error 均为 0；构建目录 `build/_work/wirex-bridge-5e33433-20261025-064748`，日志 `build/_work/bm-audio-5e33433-build.log`，EXE SHA-256 `C04D62F13173AD11676A3339EEA250B27745BF1056DB36CF53273AAE1DA34B06`。便携候选 `build/bm-radio-bridge-5e33433` 已通过 root 审计：13 项非秘密文件的长度和 SHA-256 与实际清单一致，EXE 与 clean build 一致，三份启动器与源码一致，PS5.1 配置 AST 检查、native safe help、空 logs、无旧 settings 和凭据仅存在状态均通过。新音量倍率尚未实机听音验收。参数和本机设置文件见 [`音量调节.md`](音量调节.md)。
- 最新源码提交 `ab3c5fab358aaf56a697a8e2a79f09f02d8a75ee` 新增全球 TG91 被动收听预设 `listen-91`，固定 BI7KGD、Gateway 461135501、Source 4611355、43.129.83.124:62031、TS2、CC1；过滤只接受 TG91/TS2/G。`policy_for` 继续拒绝 TG91 与 TG46001 组呼的键盘 T 和手咪 PTT 上行，默认仍为 `parrot-cn`。用户为 Gateway 461135501 配置 TS2 TG91 静态订阅后，已确认实机收听正常；这条后续确认没有附通话次数或时长。版本刚交付时的记录尚待收听验收，现已由用户确认完成。
- `ab3c5fa` clean build 的 26 项离线测试全部通过，compiler warning/error 为 0；构建目录 `build/_work/wirex-bridge-ab3c5fa-20261024-212438`，日志 `build/_work/bm-tg91-ab3c5fa-build.log`，EXE SHA-256 `6FAC95A48D51D2C8033220139B8884CAC0CA83DB15625928C04F2CAC349A1464`。便携包 `build/bm-radio-bridge-ab3c5fa` 已通过 root 审计：12 项非秘密文件记录、EXE/launcher、PS5.1 AST、safe help、audio schema、空 logs 和本机凭据仅存在检查均通过。
- 按用户调整的研究次序，本轮先推进软件侧路径分析。官方 WIRES-X 帮助文件的 45 页功能目录与桥接取舍见 [`WIRESX官方功能目录与桥接取舍.md`](WIRESX官方功能目录与桥接取舍.md)；HRI DLL 屏幕字段、模式路由与队列路径见 [`WIRESX屏幕与路由软件研究.md`](WIRESX屏幕与路由软件研究.md)。静态代码已确认 `DGKEY_NUM_NDDIRECT` 为 0 时写入 Y 正文候选偏移 5 的 `'1'`，非零时写入 `'2'`，但尚未将该 HRI 布尔值映射到 FTX-1 的三态 Node Mode。HRI 字段到电台 LCD 的 serializer 和写入路径仍未闭合。用户已确认 FTX-1 Node Mode 为 DIRECT，并澄清 145.1 MHz RF 音频是在 Bridge 关闭后出现；S 表指示与该音频是否同一时刻尚未确认。Bridge 运行期间是否仍接收 RF 尚无结果，因此待核实的是运行与退出前后的路由差异，不是重新确认 Node Mode。本轮没有新增 LCD 文本显示消息或 RF 模式写入。
- `2183cef` 旧候选的 clean build 曾通过 25 项离线测试并通过便携包审计。随后 native 日志显示 BM 到达 `ready` 且收到了 291 个 DMRD 数据报，但 `calls_started=0`、`calls_ended=0`；原日志没有 DMRD 头元数据，不能仅凭计数认定收到回声。
- 两次有界 network-only 私呼测试使用生产 Session、UDP transport、Transmitter 和 RX-only pipeline，均只向 460997 发送一通 1.98 秒合成 PCM。首次从 TS1 发出后，BM 实际回送 TS2 private stream；本机 ID、呼叫类型、LC 与 CC1 匹配，旧 TS1 filter 将 37 个包全部拒绝。三个 DIRECT preset 因此改为 TS2，过滤仍精确匹配本机目的 ID、单一时隙和呼叫类型。
- 第二次测试从新 `parrot-cn` preset 动态取得呼叫参数，BM 回声被 TS2 filter 接受；Receiver 产生 1 个 start、32 个 voice、1 个 end 事件。RX-only 测试未启用播放，也没有真实 HRI/扬声器路径。
- 用户完成的五轮 HRI DIRECT 手咪观察支持当前 FTX-1 + HRI DIRECT 下，Y/0 ready 后有效 X/100 的 X[12] 按住值为 ASCII `2`、松开值为 ASCII `0`。另一次 120 秒 idle observer 在 120006 ms 正常退出，记录 119 个 Y/0、119 个 X/100；119 个 X/100 均为配置标记 `X[11]=0x31`，Session 产生 119 个 PTT observations，传输未失败。该次运行没有手咪按键动作，不能用 idle observations 作为实机 PTT 边沿验证。
- 用户实测旧 native 候选时，BM 保持 ready 约 194.9 秒，但 `ptt_observations=0`、TX 计数均为 0。对照记录显示，Y/0 ready 后 X[11] 均为 `0x31`；此前两轮手咪按住/松开时 X[12] 分别出现 `0x32`/`0x30`。根因是旧 Session 只在非配置的 Y 模板复制分支产生 PTT observation。源码提交 `005c5e8e6d95a3ce2f29cf928d59e90c7551ffb1` 已把 PTT 字节提取独立于 Y 模板复制，配置分支仍不导入配置且不改 Y 模板规则；聚焦 HRI Session 测试和正式 26 项全测均通过。
- Windows PowerShell 5.1 的只读生产设备发现函数已通过：唯一选择 COM5、WaveIn 1、WaveOut 3，耗时 10398 ms。启动器按名称关键词 `USB Audio` 选择唯一输入和输出，并把 endpoint ID 交给 native 核对。设备枚举没有打开 COM、音频流或 BM。
- 源码提交 `005c5e8e6d95a3ce2f29cf928d59e90c7551ffb1` 的正式 clean build 与 26 项离线测试已通过。构建目录为 `build/_work/wirex-bridge-005c5e8-20261024-203101/`，日志为 `build/_work/bm-ptt-config-005c5e8-build.log`，EXE SHA-256 为 `981715B37518DE6821F0F3F57F8BF743E53C91C0C85126AC34D40159DE2D1B2C`。builder 的 safe `--help` 和音频列表 schema/endpoint 检查通过；Windows PowerShell 5.1 只读设备发现于 10398 ms 内选出 COM5、WaveIn 1 和 WaveOut 3。新便携候选 `build/bm-radio-bridge-005c5e8` 已由 root 验包通过：11 项非秘密文件长度/SHA-256 与实物一致，实际 inventory 完整，EXE 与 clean build 一致，launcher 与源码一致；PS1 BOM、PS5.1 AST、safe help、audio schema/endpoint、26 测试记录、空 logs 和本机凭据仅存在检查均通过。旧便携候选 `build/bm-radio-bridge-1c8c6fd` 保持冻结。首轮自动 PTT 上行 + BM 鹦鹉回声 + FTX-1 扬声器闭环已通过，用户确认回声清晰；详细事件和计数见 [`DIRECT首轮联测验收.md`](DIRECT首轮联测验收.md)。
- 用户随后确认本轮首个完整 DIRECT 个人终端闭环通过，回声清晰。包内 JSONL 报告显示 native 会话运行 33,475 ms 后正常 `stopped`：PTT observations 37、start/end 各 1、timeout/reject 为 0，TX/RX 为 54/56，BM 呼叫开始/结束各 1，播放 157 帧，上行音频 149,280 样本，reconnect/rejected call 为 0，`bm_failure=none`，RPTCL 本机 UDP send succeeded。报告位置及 HRI 事件顺序见 [`DIRECT首轮联测验收.md`](DIRECT首轮联测验收.md)。
- `5e33433` 两路增益配置与 PCM 处理已通过离线验证；包审计通过。此次音量值没有实机听音结果，旧版本清晰回声和 TG91 收听不能代替本次增益听音验收。

源码提交 `005c5e8e6d95a3ce2f29cf928d59e90c7551ffb1` 的 native 候选已将有效 X/100 的 X[12] 状态观察与 Y 模板复制解耦，并通过正式 clean build 和 26 项离线测试。120006 ms idle observer 在配置标记分支记录 119 个 PTT observations；该 idle 对照没有手咪动作。之后一通用户手咪联测成功开始上行、完成 BM 回声接收与 FTX-1 扬声器播放。该证据覆盖一次 33,475 ms 会话和一通呼叫；长时待机及断网恢复仍未验收。候选进程在可见前台持续待机，由 `Q` 等停止请求退出；单通话最多 120 秒。`-ManualPtt` 是显式诊断入口。当前上行增益默认为 16x、回放增益默认为 1x，可在启动参数中调整并保存到便携设置文件；新倍率实机听音仍待验收。分层实测与过滤原因见 [`BM回声无播放诊断.md`](BM回声无播放诊断.md)，手咪状态观察见 [`HRI手咪PTT事件研究.md`](HRI手咪PTT事件研究.md)。

## 2026-10-24 网络诊断历史

旧 profile 的四次有界 network-only 探测都通过 RPTL/RPTK challenge 和认证 ACK，随后在 RPTC 配置阶段收到 Master 的 `MSTNAK`，生产状态机报告 `master_rejected` 并退回 `backoff`。用户在 `aec0471` 旧候选上运行的一次 native 会话也在 26.6 秒内出现五次同类登录拒绝；该会话打开了 COM/HRI，用户观察到 BM 红 X/PTT，HRI/Y0 握手约 1.125 秒，但没有 BM DMRD 语音往返。之后 A/D/E1/E2/E3 纯 network-only 对照中，E3 组合 profile 到达 BM `ready`，诊断工具也成功调用本机 UDP 发送 `RPTCL`。旧 profile 的服务端拒绝原因仍未知；E3 结果不证明某一个字段是旧拒绝原因，也不代表已完成 DMRD Echo 语音或新源码 native 桥接。认证 ACK 不等于 BM 登录成功，也没有证明密码错误。详细字段、阶段记录和实现资料见 [`BM网络登录诊断.md`](BM网络登录诊断.md)。

功能源码提交 `2183cef8c2e7364f4c73ee89f8b674c7a7c28750` 已由根会话从 clean HEAD 使用 Windows PowerShell 5.1 / VS 2019 x64 正式构建，25 项离线测试全部通过，包括 RPTC 元数据断言、receive-only 策略、combined 和 console child 测试。构建目录为 `build/_work/wirex-bridge-2183cef-20261024-123605/`，日志为 `build/_work/bm-ready-2183cef-build.log`。network-only 探测工具默认不由 builder 或自动化调用；真实网络执行仍需显式 `--run-network-only`。

本轮 E3 组合 profile 使用呼号 `BI7KGD`、Gateway ID `461135501`，RX/TX `438800000`、power `0`、CC `1`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、节点类型 `MMDVM_WIREX_Bridge`、options 空。对照实际到达 `ready`，并由诊断工具成功调用本机 UDP 发送 `RPTCL`。native 和 network-only 工具现共用 `apply_network_metadata(Profile&)`，helper 不覆盖呼号、Gateway、密码或调用方 color code；三个预设按 E3 使用 CC1，手工入口继续使用操作者输入的 CC。频率是 BM 节点元数据，不会调整 CAT 或 RF；节点类型表示虚拟 MMDVM 兼容 WIREX 节点，不表示物理 Hat。DroidStar 的参考截图是用户另一个 Gateway ID `461135502`，该身份和配置没有被修改。

根会话随后用 commit `2183cef8c2e7364f4c73ee89f8b674c7a7c28750` 的当前共享 helper 编译 `build/_work/bm-probe-final-e3-20261024/bm_network_probe.exe` 并真实运行一次 network-only probe。118 ms 内 BM 对 RPTC 配置返回 ACK，生产 Session 到达 `ready`；程序实际本机发送 9 字节 `RPTCL` 成功后进入 `stopped`，退出码为 0。原始 stdout、summary 和源 SHA 清单保存在该 ignored build 目录中。此结果确认生产源码生成的 E3 元数据可通过 BM 控制配置阶段，但没有打开 HRI/COM/WinMM，也没有验证 DMRD Echo、音频或电台声音。

## 当前候选与离线证据

Windows native 控制台入口 `wirex_bridge.exe` 把 BM 下行 PCM 播放到所选 FTX-1 DIRECT Radio WaveOut；当前默认路径读取经校验的 HRI 串口 PTT 状态，按住边沿触发所选 WaveIn 上行采集，松开边沿结束本次 BM DMRD 呼叫。默认路径不依赖键盘 `T`，也不要求先输入 `START`；`-ManualPtt` 保留显式键盘诊断。默认进程在可见前台持续待机，由 `Q` 等停止请求结束；仅单通话限制 120 秒。上行默认应用 16x 软件 PCM 增益并可独立调整，回放默认 1x 并有独立增益；TX 在 BM 语音管线接受 PCM 后累计统计，RX 在 WaveOut 成功排队后累计统计。程序不发送 RF/PTT 控制命令，`radio_state` 保持 `unknown`；首轮真实自动 PTT + BM 回声 + FTX-1 扬声器闭环已通过；该会话持续 33,475 ms 并完成一通呼叫，长时间运行和网络恢复仍待验证。BM EOT 与 RPTCL 的事件只记录本机 UDP 发送调用返回成功；该日志没有 Master 对退出包的确认记录。

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

- TG91 当前收听验收已由用户确认正常；确认没有附通话次数或时长。它关闭了 TG91 是否能正常收听这一项，不能替代长时待机、断网恢复或其它 TG 的验收。
- 旧 profile 的 RPTC `MSTNAK` 与其拒绝原因仍是历史诊断；之后两次受控私呼网络测试已确认 BM 对该私呼返回 TS2，第二次 RX-only pipeline 已产生 start/voice/end 事件。这证明 BM Echo 网络回声路径存在，不等于用户实际语音或电台扬声器已通过。
- `ab3c5fa` 的 clean build、26 项离线测试和便携包审计均已通过；这些结果分别验证软件与文件，不替代现场长稳或网络恢复测试。
- 一次自动串口 PTT + BM 上行和真实电台回声/扬声器播放的端到端联测已通过，用户确认回声清晰；TG91 实机收听也已由用户确认正常。详细 DIRECT 会话记录见 [`DIRECT首轮联测验收.md`](DIRECT首轮联测验收.md)。
- 新增回放/上行音量值的实机听音、长时间待机、断网恢复、46001 订阅收听、Bridge 运行期间的 DIRECT/RF 路由与 C4FM RF 节点仍待验收；UI 按用户决定推迟。BM network-only、idle observer、clean build 和包审计分别覆盖不同的软件与设备行为。
