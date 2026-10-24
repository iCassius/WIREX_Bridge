# BM + FTX-1 本地桥接候选

此入口把 BrandMeister DMRD 与 FTX-1 DIRECT 音频路径接在一个可见的 native 控制台进程中。两次有界 network-only 私呼测试已从真实 BM Echo 服务收到 TS2 回声：旧 TS1 filter 曾拒绝整条回声；调整三个 DIRECT preset 为 TS2 后，RX-only pipeline 产生了呼叫开始、voice 和结束事件。测试使用合成 PCM，没有打开 HRI 或音频设备，也不证明真实用户语音、扬声器播放或 RF 效果。详见 [BM 回声诊断](../docs/BM回声无播放诊断.md)。

旧 profile 的 `MSTNAK` 和其原因仍是历史诊断；`2183cef` clean build 的 25 项测试及旧便携包审计也只适用于该提交。源码提交 `1c8c6fd00081ea8b029c756f537168f4efce4994` 的正式 clean build 与 26 项离线测试全部通过；构建输出位于 `build/_work/wirex-bridge-1c8c6fd-20261024-161127`，日志为 `build/_work/bm-auto-ptt-1c8c6fd-build.log`。便携候选 `build/bm-radio-bridge-1c8c6fd` 已通过 root 包审计。随后发现该旧候选在配置标记 `X[11]=0x31` 的 X/100 分支不产生 PTT observations；当前源码工作树已修复该提取路径并通过聚焦 HRI Session 测试，但尚未执行新的正式 26 项全测或制作新包。旧便携目录保持冻结。真实自动 PTT + BM + 电台扬声器回声仍待端到端验证；历史网络登录过程见 [BM 4602 网络登录诊断](../docs/BM网络登录诊断.md)。

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

默认预设为中国鹦鹉单呼 460997，不显示预设菜单。也可用 `-Preset parrot-cn`、`-Preset parrot-global`、`-Preset listen-46001` 或 `-Preset manual` 指定；手工入口保留原先逐项输入。固定预设使用下表中的呼号、身份、Master、端口、时隙、色码和目标。预设密码从 `private\bm-device-password.txt` 读取，密码值不进入进程参数，PowerShell 启动器也不读取或显示文件正文。可以用 `-PasswordFile ABS` 指定另一处本机文件。

| 预设 | 目标 | 类型 | 默认上行 |
| --- | ---: | --- | --- |
| `parrot-cn`（默认） | 460997 | P 单呼 | ready 后有效手咪 PTT 按下边沿开始，松开边沿结束 |
| `parrot-global` | 9990 | P 单呼 | ready 后有效手咪 PTT 按下边沿开始，松开边沿结束 |
| `listen-46001` | 46001 | G 组呼 | 严格仅接收 |

三个预设均固定为 `BI7KGD`、Gateway ID `461135501`（Source ID `4611355` 加 ESSID `01`）、Source ID `4611355`、Master `43.129.83.124`、UDP 端口 `62031`、TS2、CC1。`62031` 是 Master 的 UDP 端口，不是 Source ID。两次受控 Echo 观察的返回头和 LC 均指向 TS2；过滤仍只匹配 preset 指定的时隙、呼叫类型及目标 ID，不监听全部时隙或 TG。服务器列表把 `4602.master.brandmeister.network` 列为 `BM_4602_China`、UDP 62031；本机使用已核实的 IPv4 固定值，不使用本地可能返回的 DNS fake-IP。[Pi-Star 主机列表](https://www.pistar.uk/downloads/DMR_Hosts.txt)，[本次公共 DNS A 记录核查](https://dns.google/resolve?name=4602.master.brandmeister.network&type=A)。中国鹦鹉目标 460997 依据 BM 4602 发布者说明；9990 是 SharkRF Homebrew/MMDVM Connector 手册记录的通用 private echo 目标。[BM 4602 发布者说明](https://forum.hamcq.cn/d/5228)，[SharkRF 手册](https://manuals.sharkrf.com/openspot4/en/homebrew-mmdvm-connector.html)。服务器列表中的通用 `password` 文本不是本机 SelfCare 设备密码，不会被采用。

所有 native 配置和 network-only 探测共用同一组 BM 节点元数据：RX/TX `438800000`、power `0`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、软件类型 `MMDVM_WIREX_Bridge`，options 为空。手工入口仍保留用户输入的 CC；三个预设使用经 E3 组合测试的 CC1。`438800000` 只作为 BM RPTC 节点元数据，不会设置 CAT 频率或使电台发射。BM 网页节点详情中的 `Firmware`/类型文字是程序上报的软件节点标识，不是 FTX-1 固件，也不表示连接了实体 MMDVM Hat。

连接电台前，关闭官方 WIRES-X 程序，并将 FTX-1 设为 HRI `ON`、Node Mode `DIRECT`。当前有效 HRI X/100 在 Y/0 ready 后，正文 `X[0x0c]` 的 ASCII `2`（`0x32`）表示按住，ASCII `0`（`0x30`）表示松开；用户两轮受控观察还确认这两种值也出现在 `X[0x0b]=0x31` 的记录中。native 在 Y/0 ready 后从有效 X/100 独立提取 PTT 字节；配置导入分支仍不导入配置，也不修改既有 Y 模板复制规则。修复后的 idle observer 运行中，119 条配置分支 X/100 产生 119 个 Session PTT observations；该次没有手咪动作，因此不作为新的按键边沿验证。启动期 Y/0 尚未确认时的记录不会产生 PTT 观察。每次通话结束、忙碌、未知状态或链路失效后，必须重新观察到松开才能接受下一次按下。`-ManualPtt` 显式启用键盘 `T` 诊断路径。完整观察记录和适用范围见 [HRI 手咪 PTT 研究](../docs/HRI手咪PTT事件研究.md)。

选择手工入口时，native 仍逐项询问呼号、Gateway ID、本机 Source ID、目标 Talkgroup 或单呼 Radio ID、呼叫类型（`G` 组呼 / `P` 单呼）、Timeslot、Color Code、Master 地址和端口。组呼收包按所选 TG 过滤；单呼发送目标是用户输入的远端 ID，接收过滤按本机 Source ID 识别返回单呼。Master 地址可输入 IPv4 或 ASCII 主机名；主机名会通过 Windows 有界解析转换为 IPv4，控制台显示固定地址供核对。当前只支持 IPv4。DIRECT 没有可声明的地理坐标或 RF 频率；RPTC 中使用上述固定格式的空位置坐标和节点元数据，不代表设备所在位置或 CAT/RF 频率。手工 Color Code 仍按用户输入传给 BM。

`listen-46001` 只登录 BM 并被动处理已经转发到本机的 46001 组呼。要收听该 TG，操作者必须先在 BrandMeister SelfCare 为此 Gateway/TS 配置静态订阅；程序不会发送组呼激活包，也不保证登录后自动收到该 TG。预设的 46001 发射策略同样应用于手工入口。

完成必要的设备选择后，启动器直接运行 native，不再要求输入 `START`。手工入口在 native 控制台隐藏输入密码；预设入口从指定私有文件读取密码。文件最多 128 字节，只接受非空可打印 ASCII 内容和至多一个文件行尾；密码值不放入命令行、环境变量、日志、报告或 Git。native 在打开设备前验证文件，并在运行结束时擦除其进程内密码缓冲。手工隐藏输入仍允许空格。

默认连接会在可见前台进程中持续待机，直到 `Q`、Ctrl+C、窗口关闭或错误触发有界收尾；没有全局 120 秒自动退出，也不创建后台服务。单通话最多 120 秒；每次通话结束或 PTT 状态失效后，须重新观察到松开再按下。显式 `-ManualPtt` 才启用键盘 `T` 诊断路径，并保留旧的 120 秒诊断窗口。上行进入 codec 前固定应用 16x 软件 PCM 增益，并将既有 `pcm_gain::SignalStats` 的增益前后样本数、RMS、峰值及削顶数写入状态报告；该固定倍率沿用用户确认的旧独立原型人工试听结果，新 BM 链路的声音仍待真实联合测试验证。网络下行只播放到所选 Radio WaveOut。状态报告保留最近一个已解码 DMRD 头的源/目标 ID、时隙、组呼/单呼类型，以及按目标、时隙、呼叫类型和协议头统计的过滤数量；不会记录原始 DMRD 或语音内容。native 每至少 5 秒向 `logs\bm-bridge-*.jsonl` 写入一条运行快照，并在 PTT observation 状态变化时写事件；详细 HRI、Y 模板复制、配置分支、gate 和上行计数只写入该 JSONL。控制台显示连接状态和操作者下一步动作。日志不记录密码、挑战盐、认证散列、原始协议正文或音频。若本次运行从未达到 BM `ready`，最终报告明确标记未确认 BM 连接，native 返回退出码 2；BM 与 HRI 状态分别记录。

当 BM 已进入 `ready` 且 HRI 已确认 Y0 时，控制台显示等待手咪 PTT 的状态。按下边沿开始 BM 上行，松开边沿结束；忙碌期间按下会被拒绝，松开后重新按下才会再启动。`-ManualPtt` 诊断入口改用显式键盘 `T`。46001 仅接收预设始终拒绝上行。

若有界收尾期间没有观察到 HRI T0 对应的 `T` 记录，状态报告会保留 `downlink_call_bounded_cleanup_incomplete`，桥接会阻止后续下行并以退出码 2 结束；该本机串口观察仍不能证明电台已恢复或 RF/PTT 状态。

root 对当前启动选择逻辑作了只读核对，唯一 HRI 候选为 COM5，WaveIn 1 与 WaveOut 3 匹配到同组音频 endpoint；这次核对没有打开 COM、音频流或 BM。预设使用固定参数，手工入口会询问 BM 配置；完成必要的本机设备选择后，程序直接连接本次配置的 Master 并打开所选 COM 和 WinMM 端点。若 PowerShell 在 native 已调用后报告异常，资源状态需根据 native 控制台和 JSONL 报告确认，启动器不会猜测其已安全退出。

## 已知验证边界

- 源码构建与 fake Master loopback 测试属于离线软件证据。
- 设备能力查询只读取本机 WinMM 列表和格式支持，不打开音频流。
- 旧 profile 的 RPTC `MSTNAK` 仍是历史结果，拒绝原因未知。之后两次真实 BM network-only Echo 测试已回送 TS2 private stream；第二次使用 TS2 preset 后 RX-only pipeline 产生了 start/voice/end。这不是“无真实 Echo”，但仍没有验证 native 自动 PTT、HRI/COM/WinMM 播放或电台端到端回声。详见 [网络登录诊断](../docs/BM网络登录诊断.md) 和 [BM 回声诊断](../docs/BM回声无播放诊断.md)。
- 源码提交 1c8c6fd00081ea8b029c756f537168f4efce4994 的正式 clean build 与 26 项离线测试全部通过；构建输出位于 build/_work/wirex-bridge-1c8c6fd-20261024-161127，日志为 build/_work/bm-auto-ptt-1c8c6fd-build.log。便携候选 build/bm-radio-bridge-1c8c6fd 已通过 root 包审计；自动 PTT + BM + FTX-1 扬声器回声联合实测仍待用户执行。
- HRI T3/T0 的 `T` 记录只是阶段观察，不作为严格硬件 ACK；`radio_state` 保持 `unknown`。
- BM 语音、网络断线、HRI 收尾和资源关闭的候选行为仍需在后续明确授权的联合测试中验证。
