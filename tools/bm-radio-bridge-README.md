# BM + FTX-1 本地桥接候选

此入口把 BrandMeister DMRD 与 FTX-1 DIRECT 音频路径接在一个可见的 native 控制台进程中。两次有界 network-only 私呼测试已从真实 BM Echo 服务收到 TS2 回声：旧 TS1 filter 曾拒绝整条回声；调整三个 DIRECT preset 为 TS2 后，RX-only pipeline 产生了呼叫开始、voice 和结束事件。测试使用合成 PCM，没有打开 HRI 或音频设备。此后用户确认 TG91 实机收听正常；用户没有提供该次收听的通话次数或时长。详见 [BM 回声诊断](../docs/BM回声无播放诊断.md)。

源码提交 `ab3c5fab358aaf56a697a8e2a79f09f02d8a75ee` 的正式 clean build 与 26 项离线测试全部通过；`build/bm-radio-bridge-ab3c5fa` 便携包也已通过 root 审计。该源码新增 `listen-91`，首次收听前需在 SelfCare 为 Gateway `461135501` 的 TS2 添加 TG91 静态订阅；用户已确认实机收听正常，未提供通话次数或时长。此前用户在 `005c5e8` 的 `parrot-cn` 闭环中确认 FTX-1 扬声器回声清晰，这是单独的 460997 私呼结果。
当前按功能覆盖优先推进：先完成软件切片与离线测试，不等待每项实机结果再继续。官方 WIRES-X 功能目录和 HRI 字段/模式研究见 [官方功能目录与桥接取舍](../docs/WIRESX官方功能目录与桥接取舍.md) 与 [屏幕与路由软件研究](../docs/WIRESX屏幕与路由软件研究.md)；FTX-1 Node Mode 矩阵、已恢复的软件动作和后续功能顺序见[下一阶段计划](../docs/下一阶段推进计划.md)。`DGKEY_NUM_NDDIRECT` 是 HRI DigiPanel 的布尔显示/配置字段；它尚未映射到 FTX-1 的 AP RADIO、AP PC、DIRECT 三态。用户已确认 FTX-1 Node Mode 为 DIRECT，并澄清 145.1 MHz RF 音频是在 Bridge 关闭后出现；S 表指示与该音频是否同一时刻尚未确认。Bridge 运行期间的路由尚未对照，FTX-1 LCD serializer 和写入路径也未闭合。已确认的语音结果保留为相应版本证据；剩余实机项目统一见 [合并联测清单](../docs/合并联测清单.md)，待软件功能和最终构建完成后集中执行。

以下构建和包信息记录的是对应提交时的历史状态。旧 profile 的 `MSTNAK` 和其原因仍是历史诊断；`2183cef` clean build 的 25 项测试及旧便携包审计也只适用于该提交。源码提交 `1c8c6fd00081ea8b029c756f537168f4efce4994` 的正式 clean build 与 26 项离线测试全部通过；构建输出位于 `build/_work/wirex-bridge-1c8c6fd-20261024-161127`，日志为 `build/_work/bm-auto-ptt-1c8c6fd-build.log`。便携候选 `build/bm-radio-bridge-1c8c6fd` 已通过 root 包审计。随后发现该旧候选在配置标记 `X[11]=0x31` 的 X/100 分支不产生 PTT observations；源码提交 `005c5e8e6d95a3ce2f29cf928d59e90c7551ffb1` 已修复该提取路径并通过正式 clean build 和 26 项离线测试。构建目录为 `build/_work/wirex-bridge-005c5e8-20261024-203101`，日志为 `build/_work/bm-ptt-config-005c5e8-build.log`，EXE SHA-256 为 `981715B37518DE6821F0F3F57F8BF743E53C91C0C85126AC34D40159DE2D1B2C`。便携候选 `build/bm-radio-bridge-005c5e8` 已通过 root 独立验包。DIRECT 首轮闭环已通过，用户确认电台回声清晰；会话计数和验收边界见 [DIRECT 首轮联测验收](../docs/DIRECT首轮联测验收.md)。构建、测试和包审计的版本边界见 [BM 联调推进](../docs/BM联调推进.md)。

## 构建

在 Windows PowerShell 5.1 中，从仓库运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-bm-bridge.ps1
```

脚本使用已安装的 VS 2019 x64 工具，不安装依赖。它先核对固定 DroidStar commit `becf1dede57c4a70a865e9cb4cac9247e505599a` 的 manifest 中全部 57 个本地文件 SHA-256，再从源码构建 `wirex_bridge.exe` 和原链接清单下的 `wirex_probe.exe`，编译并运行离线测试。产物写入唯一的 `build/_work/wirex-bridge-<commit>-<状态>-<UTC 时间>/` 目录；脏工作树目录带 `-dirty`。脚本不会打包旧 EXE、写 ZIP、修改共享依赖或连接 BM。提交 `17f3433ae4cd6820622033ddb1910c030cb260f2` 已在干净工作树通过正式构建和全部 24 项离线测试；产物位于 `build/_work/wirex-bridge-17f3433-20261024-044905/`，日志为 `build/_work/bm-final-17f3433-build.log`。本地非 ZIP 便携候选在 `build/bm-radio-bridge-17f3433/`，不包含 `wirex_probe.exe`。

如只需检查编译和链接：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-bm-bridge.ps1 -CompileOnly
```

## 启动前检查和运行

交付便携包时，把 `start-bm-radio-bridge.ps1`、`start-bm-radio-bridge.cmd` 和 `wirex_bridge.exe` 放在包根目录，并把 Y 素材放在根目录的 `private\device-y.bin`。经用户批准的本机测试凭据只放在 `private\bm-device-password.txt`；该文件是本机明文 UTF-8 文本，已由 `.gitignore` 排除，不得复制到源码、EXE、公开目录、日志或 manifest。便携目录应由用户本人保管，不公开或上传。操作者双击根目录的 `start-bm-radio-bridge.cmd`；默认状态报告写入根目录的 `logs\`。启动器只从该目录读取 EXE、Y 素材和密码文件路径，不扫描源码仓库或包外构建目录。

开发树里的构建输出在 `build\_work`，应明确传入 native、Y 素材和状态报告目录。只要传入 `-BridgePath` 或 `-BodyFile`，就必须同时传入 `-StatusDirectory`；启动器不会把报告写进 `tools\logs` 或猜测仓库目录：

```powershell
.\tools\start-bm-radio-bridge.ps1 `
  -BridgePath .\build\_work\wirex-bridge-<构建目录>\wirex_bridge.exe `
  -BodyFile .\private\device-y.bin `
  -StatusDirectory .\build\_work\wirex-bridge-<构建目录>\logs
```

在便携目录的 PowerShell 中也可运行根目录脚本：

```powershell
.\start-bm-radio-bridge.ps1
```

## 快速操作

1. 运行 `start-bm-radio-bridge.cmd`，确认显示的 COM 端口、USB Audio 和 BM 预设。
2. 等待 BM 和电台连接。
3. 连接就绪后，先松开一次手咪 PTT，再按住手咪讲话；松开后等待 BM 回声。
4. 按 `Q` 停止并退出。

如果设备列表没有唯一显示 COM5 或 USB Audio，按窗口提示选择 HRI 串口、WaveIn 和 WaveOut。

启动器从脚本目录读取 Y 素材和本机 BM 密码文件，自动优先选择唯一、经 PnP 确认为 HRI 的 COM5。WaveIn 和 WaveOut 分别按设备名中唯一的 `USB Audio` 关键词选择，并要求两端支持 48 kHz 单声道 16 位 PCM。若候选不唯一，启动器显示可选设备并等待本次选择。Windows PowerShell 5.1 的只读设备发现函数已实测在约 10.4 秒内选择 COM5、WaveIn 1 和 WaveOut 3；不同系统的设备枚举耗时可能不同。

启动器将本次 WinMM 枚举得到的 WaveIn/WaveOut endpoint ID 传给 native。native 在启动前和每次打开或重开音频流前核对该 ID 与 PCM 能力。Windows 音频驱动提供的 endpoint ID 查询用于确认 WinMM ID 对应的 Windows 音频端点身份，不需要按设备本地化名称确定身份。[Microsoft：Endpoint ID strings](https://learn.microsoft.com/en-us/windows/win32/coreaudio/endpoint-id-strings)，[Microsoft：waveInMessage](https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-waveinmessage)。

默认预设为中国鹦鹉单呼 460997，不显示预设菜单。也可用 `-Preset parrot-cn`、`-Preset parrot-global`、`-Preset listen-46001`、`-Preset listen-91` 或 `-Preset manual` 指定。双击 `start-profile.cmd` 或使用 `-Preset manual` 进入通用配置：首次运行时收集一次连接参数和设备选择并保存到便携目录的 `connection-profile.json`，后续启动读取该文件。固定 preset 始终优先，不读取手工 profile；命令行设备参数只覆盖本次运行。字段和规则见[连接配置说明](../docs/连接配置.md)。固定预设使用下表中的呼号、身份、Master、端口、时隙、色码和目标。预设密码从 `private\bm-device-password.txt` 读取，密码值不进入进程参数，PowerShell 启动器也不读取或显示文件正文。可以用 `-PasswordFile ABS` 指定另一处本机文件。

TG91 收听入口为 `tools\start-listen-91.cmd`。先在 BrandMeister SelfCare 为 Gateway ID `461135501` 的 TS2 添加 TG91 静态订阅，再双击该命令开始连接和收听。BrandMeister 文档将 TG91 说明为 Worldwide，并按 TS1/TS2 配置静态组呼转发。[BrandMeister USA：Dynamic vs Static](https://help.brandmeister.us/talk-groups/dynamic-vs-static)，[BrandMeister：Static Talk Groups](https://help.brandmeister.network/repeaters/sysop-dashboard/static-talkgroups/)

| 预设 | 目标 | 类型 | 默认上行 |
| --- | ---: | --- | --- |
| `parrot-cn`（默认） | 460997 | P 单呼 | ready 后有效手咪 PTT 按下边沿开始，松开边沿结束 |
| `parrot-global` | 9990 | P 单呼 | ready 后有效手咪 PTT 按下边沿开始，松开边沿结束 |
| `listen-46001` | 46001 | G 组呼 | 严格仅接收 |
| `listen-91` | 全球 91 | G 组呼 | TS2 严格仅接收 |

四个预设均固定为 `BI7KGD`、Gateway ID `461135501`（Source ID `4611355` 加 ESSID `01`）、Source ID `4611355`、Master `43.129.83.124`、UDP 端口 `62031`、TS2、CC1。`62031` 是 Master 的 UDP 端口，不是 Source ID。两次受控 Echo 观察的返回头和 LC 均指向 TS2；过滤仍只匹配预设指定的时隙、呼叫类型及目标 ID，不监听全部时隙或 TG。服务器列表把 `4602.master.brandmeister.network` 列为 `BM_4602_China`、UDP 62031；本机使用已核实的 IPv4 固定值，不使用本地可能返回的 DNS fake-IP。[Pi-Star 主机列表](https://www.pistar.uk/downloads/DMR_Hosts.txt)，[本次公共 DNS A 记录核查](https://dns.google/resolve?name=4602.master.brandmeister.network&type=A)。中国鹦鹉目标 460997 依据 BM 4602 发布者说明；9990 是 SharkRF Homebrew/MMDVM Connector 手册记录的通用 private echo 目标。[BM 4602 发布者说明](https://forum.hamcq.cn/d/5228)，[SharkRF 手册](https://manuals.sharkrf.com/openspot4/en/homebrew-mmdvm-connector.html)。服务器列表中的通用 `password` 文本不是本机 SelfCare 设备密码，不会被采用。

所有 native 配置和 network-only 探测共用同一组 BM 节点元数据：RX/TX `438800000`、power `0`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、软件类型 `MMDVM_WIREX_Bridge`，options 为空。手工入口仍保留用户输入的 CC；三个预设使用经 E3 组合测试的 CC1。`438800000` 只作为 BM RPTC 节点元数据，不会设置 CAT 频率或使电台发射。BM 网页节点详情中的 `Firmware`/类型文字是程序上报的软件节点标识，不是 FTX-1 固件，也不表示连接了实体 MMDVM Hat。

连接电台前，关闭官方 WIRES-X 程序，并将 FTX-1 设为 HRI `ON`、Node Mode `DIRECT`。当前有效 HRI X/100 在 Y/0 ready 后，正文 `X[0x0c]` 的 ASCII `2`（`0x32`）表示按住，ASCII `0`（`0x30`）表示松开；用户两轮受控观察还确认这两种值也出现在 `X[0x0b]=0x31` 的记录中。native 在 Y/0 ready 后从有效 X/100 独立提取 PTT 字节；配置导入分支仍不导入配置，也不修改既有 Y 模板复制规则。修复后的 idle observer 运行中，119 条配置分支 X/100 产生 119 个 Session PTT observations；该次没有手咪动作，因此不作为新的按键边沿验证。之后的实际联测中 native 记录了 1 次手咪启动和 1 次松开结束，BM 呼叫和 FTX-1 播放均完成；具体事件顺序见 [DIRECT 首轮联测验收](../docs/DIRECT首轮联测验收.md)。启动期 Y/0 尚未确认时的记录不会产生 PTT 观察。每次通话结束、忙碌、未知状态或链路失效后，必须重新观察到松开才能接受下一次按下。`-ManualPtt` 显式启用键盘 `T` 诊断路径。完整观察记录和适用范围见 [HRI 手咪 PTT 研究](../docs/HRI手咪PTT事件研究.md)。

选择手工入口时，启动器在首次创建 profile 时询问呼号、Gateway ID、本机 Source ID、目标 Talkgroup 或单呼 Radio ID、呼叫类型（`G` 组呼 / `P` 单呼）、Timeslot、Color Code、Master 地址和端口，并将非秘密字段保存到 JSON。后续启动读取已保存配置；native 在 DNS 和设备打开前再次校验完整参数。组呼收包按所选 TG 过滤；单呼发送目标是用户输入的远端 ID，接收过滤按本机 Source ID 识别返回单呼。Master 地址可输入严格 IPv4 或符合 hostname 语法的 ASCII 主机名；主机名会通过 Windows 有界解析转换为 IPv4，控制台显示固定地址供核对。当前只支持 IPv4。DIRECT 没有可声明的地理坐标或 RF 频率；RPTC 中使用上述固定格式的空位置坐标和节点元数据，不表示设备位置或 CAT/RF 频率。手工 Color Code 仍按用户输入传给 BM。

`listen-46001` 和 `listen-91` 只登录 BM 并被动处理已经转发到本机的指定组呼。要收听 TG91，操作者先在 BrandMeister SelfCare 为 Gateway ID `461135501` 的 TS2 添加 TG91 静态订阅；程序按 TG91、TS2、G 过滤收到的 DMRD。这两个预设不发送组呼激活 DMRD。手工入口中，合法目标 ID（1 到 16,777,215）不会因号码是 91 或 46001 而自动禁发；发射许可按手工配置中的明确策略决定。选定目标本身不会启动发射，只有有效 PTT 按下边沿才开始上行。

完成必要的设备选择后，启动器直接运行 native，不再要求输入 `START`。显式 `-PasswordFile` 指向不存在的文件时，启动器报错；未指定时，优先使用便携目录的 `private\bm-device-password.txt`，该文件不存在则由 native 在控制台隐藏输入密码。固定预设从私有文件读取密码。文件最多 128 字节，只接受非空可打印 ASCII 内容和至多一个文件行尾；密码值不放入 profile、命令行、环境变量、日志、报告或 Git。native 在打开设备前验证文件，并在运行结束时擦除其进程内密码缓冲。手工隐藏输入仍允许空格。

默认连接会在可见前台进程中持续待机，直到 `Q`、Ctrl+C、窗口关闭或错误触发有界收尾；没有全局 120 秒自动退出，也不创建后台服务。单通话最多 120 秒；每次通话结束或 PTT 状态失效后，须重新观察到松开再按下。显式 `-ManualPtt` 才启用键盘 `T` 诊断路径，并保留旧的 120 秒诊断窗口。源码提交 `5e33433` 在麦克风上行进入 codec 前应用可配置的 PCM 增益，并对网络下行音频应用独立的电台回放增益；默认分别为 16x 和 1x，范围均为 0.25x–16x。状态报告中的发送统计仅计入 BM 语音管线接受的 PCM，接收统计仅计入成功排队到 WaveOut 的 PCM。该提交正式 clean build 与 26 项离线测试通过；本轮手工连接 profile 随后在源码提交 `4a5bb2e` 中加入，并由文档提交 HEAD `eafc8a1` 的 27 项正式 clean build 验证。DIRECT 清晰回声与 TG91 收听来自前序版本的用户实测。音量参数的本轮实机听音仍待验，长时间运行和断网恢复也待验证。状态报告保留最近一个已解码 DMRD 头的源/目标 ID、时隙、组呼/单呼类型，以及按目标、时隙、呼叫类型和协议头统计的过滤数量；不会记录原始 DMRD 或语音内容。native 每至少 5 秒向 `logs\bm-bridge-*.jsonl` 写入一条运行快照，并在 PTT observation 状态变化时写事件；详细 HRI、Y 模板复制、配置分支、gate 和上行计数只写入该 JSONL。控制台显示连接状态和操作者下一步动作。日志不记录密码、挑战盐、认证散列、原始协议正文或音频。若本次运行从未达到 BM `ready`，最终报告明确标记未确认 BM 连接，native 返回退出码 2；BM 与 HRI 状态分别记录。

**音量设置已完成代码与离线验证。** 音量功能源码提交 `5e3343372d9b0427b5c25943a731292e65b1f7ca` 的正式 clean build 与 26 项离线测试通过；便携包 `build/bm-radio-bridge-5e33433` 已通过 root 审计。回放默认 `1.0x`，麦克风上行默认 `16x`，范围均为 `0.25x–16x`。启动器参数 `-RadioPlaybackGain` / `-MicTransmitGain` 可覆盖并保存到便携目录的 `audio-settings.json`，下次启动恢复。当前没有运行时热调；新音量倍率的实机听音尚待验收。操作步骤见 [`../docs/音量调节.md`](../docs/音量调节.md)。

当 BM 已进入 `ready` 且 HRI 已确认 Y0 时，控制台显示等待手咪 PTT 的状态。按下边沿开始 BM 上行，松开边沿结束；忙碌期间按下会被拒绝，松开后重新按下才会再启动。`-ManualPtt` 诊断入口改用显式键盘 `T`。手工配置的 TG91 与 TG46001 起呼目标按当前发射许可处理，不会仅因目标号码而拒绝；选择目标不会自动发射。

若有界收尾期间没有观察到 HRI T0 对应的 `T` 记录，状态报告会保留 `downlink_call_bounded_cleanup_incomplete`，桥接会阻止后续下行并以退出码 2 结束；该本机串口观察仍不能证明电台已恢复或 RF/PTT 状态。

root 对启动器设备选择逻辑作过只读核对，唯一 HRI 候选为 COM5，WaveIn 1 与 WaveOut 3 匹配到同组音频 endpoint；该次核对没有打开 COM、音频流或 BM。连接 profile 源码位于提交 `4a5bb2e`；PowerShell 7 和 Windows PowerShell 5.1 离线测试通过。根会话从文档提交 HEAD `eafc8a1` 完成正式 clean build，27 项离线测试全部通过，warning/error 均为 0；构建目录 `build/_work/wirex-bridge-eafc8a1-20261025-071535`，日志 `build/_work/bm-profile-eafc8a1-build.log`，EXE SHA-256 `D41AC49258CC0C48A6C4766F32ADCA8129895C33D28643830927EAF0C165C1FD`。root 的 4 项 native 无效参数检查均以退出码 2 拒绝，未写状态文件、未查询 DNS 或设备。当前便携目录仍是 `5e33433` 音量候选，不含连接 profile；本轮尚未制作新包或进行实机连接。若 PowerShell 在 native 已调用后报告异常，资源状态需根据 native 控制台和 JSONL 报告确认，启动器不会猜测其已安全退出。

## 已知验证边界

- 源码构建与 fake Master loopback 测试属于离线软件证据。
- 设备能力查询只读取本机 WinMM 列表和格式支持，不打开音频流。
- 旧 profile 的 RPTC `MSTNAK` 仍是历史结果，拒绝原因未知。之后两次真实 BM network-only Echo 测试已回送 TS2 private stream；第二次使用 TS2 preset 后 RX-only pipeline 产生了 start/voice/end。这两次 network-only 结果仅验证 BM Echo 网络接收路径，没有打开 HRI、COM 或 WinMM；随后 native DIRECT 端到端联测已通过，见 [首轮验收记录](../docs/DIRECT首轮联测验收.md)。网络字段和过滤历史见 [网络登录诊断](../docs/BM网络登录诊断.md) 和 [BM 回声诊断](../docs/BM回声无播放诊断.md)。
- 源码提交 `ab3c5fab358aaf56a697a8e2a79f09f02d8a75ee` 的 clean build 与 26 项离线测试全部通过，便携候选 `build/bm-radio-bridge-ab3c5fa` 已通过 root 审计。manifest 列出 12 项非秘密文件且长度/SHA-256 与文件一致，EXE 与 clean build 一致，PS1 BOM/PS5.1 AST、native safe help、audio schema、空 logs 和本机凭据仅存在检查均通过。用户已配置 Gateway `461135501` 的 TS2 TG91 静态订阅，并确认实机收听正常；用户没有提供该次收听的次数或时长。此前 `005c5e8` 的用户听音确认是 parrot-cn 460997 私呼回声清晰，属于另一项验收。
- 源码提交 `005c5e8e6d95a3ce2f29cf928d59e90c7551ffb1` 的正式 clean build 与 26 项离线测试全部通过；构建目录为 `build/_work/wirex-bridge-005c5e8-20261024-203101`，日志为 `build/_work/bm-ptt-config-005c5e8-build.log`。便携候选 `build/bm-radio-bridge-005c5e8` 已通过 root 独立审计：11 项非秘密文件长度/SHA-256 与实际 inventory 匹配，EXE 与 clean build 一致，启动器源码、PS1 BOM/PS5.1 AST、safe help、audio schema/endpoint、空 logs 和本机凭据仅存在状态均通过。修复后 idle observer 正常运行 120006 ms，记录 119 个 Y/0、119 个配置分支 X/100 和 119 个 PTT observations；该次没有手咪动作。首轮实际联合联测已通过：PTT start/end 与呼叫 start/end 均为 1/1，播放 157 帧；用户确认电台回声清晰。完整计数和日志定位见 [DIRECT 首轮联测验收](../docs/DIRECT首轮联测验收.md)。
- 旧便携候选 `build/bm-radio-bridge-1c8c6fd` 的包审计只覆盖旧提交，旧目录保持冻结。
- HRI T3/T0 的 `T` 记录只是阶段观察，不作为严格硬件 ACK；`radio_state` 保持 `unknown`。
- `ab3c5fa` 的 TG91 实机收听和 `005c5e8` 的 DIRECT 鹦鹉回声已由用户分别确认正常；前者没有提供通话次数或时长。新音量、长时待机、断网恢复、46001 收听、145.1 MHz Bridge 运行路由和 C4FM RF 节点的后续实机项目统一列在 [合并联测清单](../docs/合并联测清单.md)，不作为继续实现软件功能的前置条件。HRI T3/T0 仅是程序事件记录，`radio_state` 仍为 `unknown`。UI 按用户决定推迟。
