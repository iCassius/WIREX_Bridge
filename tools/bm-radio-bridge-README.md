# BM + FTX-1 本地桥接候选

此入口把 BrandMeister DMRD 与 FTX-1 DIRECT 音频路径接在一个可见的 native 控制台进程中。两次有界 network-only 私呼测试已从真实 BM Echo 服务收到 TS2 回声：旧 TS1 filter 曾拒绝整条回声；调整三个 DIRECT preset 为 TS2 后，RX-only pipeline 产生了呼叫开始、voice 和结束事件。测试使用合成 PCM，没有打开 HRI 或音频设备，也不证明真实用户语音、扬声器播放或 RF 效果。详见 [BM 回声诊断](../docs/BM回声无播放诊断.md)。

旧 profile 的 `MSTNAK` 和其原因仍是历史诊断；`2183cef` clean build 的 25 项测试及旧便携包审计也只适用于该提交。当前工作树加入 TS2 preset 和串口 PTT 自动触发后，新的 26 项全测及 clean build 尚待 root 执行。真实自动 PTT + BM + 电台扬声器回声仍待用户联合实测；历史网络登录过程见 [BM 4602 网络登录诊断](../docs/BM网络登录诊断.md)。

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

启动器会从脚本同目录的 `private\device-y.bin` 校验固定的 100 字节 Y 素材及 SHA-256，检查同目录 `logs` 可写，并只读查询当前 PnP/COM 与音频端点。HRI 串口按 USB VID `26AA`、PID `0030` 或更高、PnP 总线描述中的 `HRI` 以及当前 COM 登记联合识别；只有唯一候选才自动选择，多个或缺失时显示实例 ID、父实例和容器并等待手工选择。它不会打开候选 COM 来扫描。

WaveIn/WaveOut 不按本地化名称或第一个 USB 设备猜选。native 用 `DRV_QUERYFUNCTIONINSTANCEIDSIZE` 和 `DRV_QUERYFUNCTIONINSTANCEID` 将当前 WinMM ID 对应到 Windows 音频 endpoint ID；这两个消息只查询标识，不打开音频流。启动器要求只有一个 USB Audio `VID_0D8C&PID_0016` 设备，其最近的非根 USB Hub 与唯一 HRI 串口相同，并且该音频设备的 PnP AudioEndpoint 实例能按 endpoint ID 唯一映射到一个 WaveIn 和一个 WaveOut。只有满足这些条件且两端都支持目标 PCM 时才自动选择。

如果产品实例重复、最近非根 USB Hub 不同或 WinMM ID 不能唯一对应到 PnP AudioEndpoint，启动器会显示当前实例、父链和 Hub 信息，再等待手工选择 WaveIn/WaveOut。完成自动或手工选择后，启动器把这次 WinMM 枚举返回的 WaveIn/WaveOut endpoint ID 传给 native；native 在启动前核对 ID 和 48 kHz PCM 能力，并在每次打开或重开音频流前再次核对，设备 ID若已改指向别的端点就停止。若 Windows 无法查询任一 endpoint ID，启动器会明确失败，不能通过手工挑选绕过身份核对。此 BM 入口不按本地化设备名称拒绝端点；旧的独立诊断入口仍保留原有唯一名称 guard。[Microsoft：Endpoint ID strings](https://learn.microsoft.com/en-us/windows/win32/coreaudio/endpoint-id-strings)，[Microsoft：waveInMessage](https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-waveinmessage)。

默认预设为中国鹦鹉单呼 460997，不显示预设菜单。也可用 `-Preset parrot-cn`、`-Preset parrot-global`、`-Preset listen-46001` 或 `-Preset manual` 指定；手工入口保留原先逐项输入。固定预设使用下表中的呼号、身份、Master、端口、时隙、色码和目标。预设密码从 `private\bm-device-password.txt` 读取，密码值不进入进程参数，PowerShell 启动器也不读取或显示文件正文。可以用 `-PasswordFile ABS` 指定另一处本机文件。

| 预设 | 目标 | 类型 | 默认上行 |
| --- | ---: | --- | --- |
| `parrot-cn`（默认） | 460997 | P 单呼 | ready 后有效手咪 PTT 按下边沿开始，松开边沿结束 |
| `parrot-global` | 9990 | P 单呼 | ready 后有效手咪 PTT 按下边沿开始，松开边沿结束 |
| `listen-46001` | 46001 | G 组呼 | 严格仅接收 |

三个预设均固定为 `BI7KGD`、Gateway ID `461135501`（Source ID `4611355` 加 ESSID `01`）、Source ID `4611355`、Master `43.129.83.124`、UDP 端口 `62031`、TS2、CC1。`62031` 是 Master 的 UDP 端口，不是 Source ID。两次受控 Echo 观察的返回头和 LC 均指向 TS2；过滤仍只匹配 preset 指定的时隙、呼叫类型及目标 ID，不监听全部时隙或 TG。服务器列表把 `4602.master.brandmeister.network` 列为 `BM_4602_China`、UDP 62031；本机使用已核实的 IPv4 固定值，不使用本地可能返回的 DNS fake-IP。[Pi-Star 主机列表](https://www.pistar.uk/downloads/DMR_Hosts.txt)，[本次公共 DNS A 记录核查](https://dns.google/resolve?name=4602.master.brandmeister.network&type=A)。中国鹦鹉目标 460997 依据 BM 4602 发布者说明；9990 是 SharkRF Homebrew/MMDVM Connector 手册记录的通用 private echo 目标。[BM 4602 发布者说明](https://forum.hamcq.cn/d/5228)，[SharkRF 手册](https://manuals.sharkrf.com/openspot4/en/homebrew-mmdvm-connector.html)。服务器列表中的通用 `password` 文本不是本机 SelfCare 设备密码，不会被采用。

所有 native 配置和 network-only 探测共用同一组 BM 节点元数据：RX/TX `438800000`、power `0`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、软件类型 `MMDVM_WIREX_Bridge`，options 为空。手工入口仍保留用户输入的 CC；三个预设使用经 E3 组合测试的 CC1。`438800000` 只作为 BM RPTC 节点元数据，不会设置 CAT 频率或使电台发射。BM 网页节点详情中的 `Firmware`/类型文字是程序上报的软件节点标识，不是 FTX-1 固件，也不表示连接了实体 MMDVM Hat。

启动联合候选前，关闭官方 WIRES-X 程序，将 FTX-1 设为 HRI `ON`、Node Mode `DIRECT` 并确认 USB 连接；下行只使用本机电台扬声器。默认入口读取通过 HRI 校验的非配置 X/100 记录中 `X[0x0c]`：在 Y/0 已 ready 后，ASCII `2`（`0x32`）作为按住边沿，ASCII `0`（`0x30`）作为松开边沿。三轮观察都得到此映射，但只在当前 FTX-1 + HRI DIRECT 条件下支持它；启动期 Y/0 尚未确认时的 `0x31` 不作为 PTT。有效的新按下边沿开始 BM 上行采集，松开结束并排空本次音频；忙碌、未知状态、链路丢失和单通话 120 秒到期会解除许可，须再次松开后才允许下一通。默认不响应键盘 `T`，也不用 VOX 或音频噪声发起上行；程序不发送电台 PTT/RF 控制命令。显式传入 `-ManualPtt` 才启用键盘 `T` 诊断路径。手工入口目标若是组呼 46001，native 策略仍严格仅接收。PTT 状态观察的设备范围和限制见 [HRI 手咪 PTT 研究](../docs/HRI手咪PTT事件研究.md)。

选择手工入口时，native 仍逐项询问呼号、Gateway ID、本机 Source ID、目标 Talkgroup 或单呼 Radio ID、呼叫类型（`G` 组呼 / `P` 单呼）、Timeslot、Color Code、Master 地址和端口。组呼收包按所选 TG 过滤；单呼发送目标是用户输入的远端 ID，接收过滤按本机 Source ID 识别返回单呼。Master 地址可输入 IPv4 或 ASCII 主机名；主机名会通过 Windows 有界解析转换为 IPv4，控制台显示固定地址供核对。当前只支持 IPv4。DIRECT 没有可声明的地理坐标或 RF 频率；RPTC 中使用上述固定格式的空位置坐标和节点元数据，不代表设备所在位置或 CAT/RF 频率。手工 Color Code 仍按用户输入传给 BM。

`listen-46001` 只登录 BM 并被动处理已经转发到本机的 46001 组呼。要收听该 TG，操作者必须先在 BrandMeister SelfCare 为此 Gateway/TS 配置静态订阅；程序不会发送组呼激活包，也不保证登录后自动收到该 TG。预设的 46001 发射策略同样应用于手工入口。

完成必要的设备选择后，启动器直接运行 native，不再要求输入 `START`。手工入口在 native 控制台隐藏输入密码；预设入口从指定私有文件读取密码。文件最多 128 字节，只接受非空可打印 ASCII 内容和至多一个文件行尾；密码值不放入命令行、环境变量、日志、报告或 Git。native 在打开设备前验证文件，并在运行结束时擦除其进程内密码缓冲。手工隐藏输入仍允许空格。

默认连接会在可见前台进程中持续待机，直到 `Q`、Ctrl+C、窗口关闭或错误触发有界收尾；没有全局 120 秒自动退出，也不创建后台服务。单通话最多 120 秒；每次通话结束或 PTT 状态失效后，须重新观察到松开再按下。显式 `-ManualPtt` 才启用键盘 `T` 诊断路径，并保留旧的 120 秒诊断窗口。上行进入 codec 前固定应用 16x 软件 PCM 增益，并将既有 `pcm_gain::SignalStats` 的增益前后样本数、RMS、峰值及削顶数写入状态报告；该固定倍率沿用用户确认的旧独立原型人工试听结果，新 BM 链路的声音仍待真实联合测试验证。网络下行只播放到所选 Radio WaveOut。程序不发送 RF/PTT 控制命令。状态报告保留最近一个已解码 DMRD 头的源/目标 ID、时隙、组呼/单呼类型，以及按目标、时隙、呼叫类型和协议头统计的过滤数量；不会记录原始 DMRD 或语音内容。屏幕和 `logs\bm-bridge-*.jsonl` 记录 `bm_state`、`bm_failure`、连续失败数、控制 UDP 收发计数和最近 `InputResult`，不记录密码、挑战盐或认证散列。若本次运行从未达到 BM `ready`，最终报告明确标记未确认 BM 连接，native 返回退出码 2；这和 HRI 状态分开判断。

当 BM 已进入 `ready` 且 HRI 已确认 Y0 时，控制台显示等待手咪 PTT 的状态。按下边沿开始 BM 上行，松开边沿结束；忙碌期间按下会被拒绝，松开后重新按下才会再启动。`-ManualPtt` 诊断入口改用显式键盘 `T`。46001 仅接收预设始终拒绝上行。

若有界收尾期间没有观察到 HRI T0 对应的 `T` 记录，状态报告会保留 `downlink_call_bounded_cleanup_incomplete`，桥接会阻止后续下行并以退出码 2 结束；该本机串口观察仍不能证明电台已恢复或 RF/PTT 状态。

root 对当前启动选择逻辑作了只读核对，唯一 HRI 候选为 COM5，WaveIn 1 与 WaveOut 3 匹配到同组音频 endpoint；这次核对没有打开 COM、音频流或 BM。预设使用固定参数，手工入口会询问 BM 配置；完成必要的本机设备选择后，程序直接连接本次配置的 Master 并打开所选 COM 和 WinMM 端点。若 PowerShell 在 native 已调用后报告异常，资源状态需根据 native 控制台和 JSONL 报告确认，启动器不会猜测其已安全退出。

## 已知验证边界

- 源码构建与 fake Master loopback 测试属于离线软件证据。
- 设备能力查询只读取本机 WinMM 列表和格式支持，不打开音频流。
- 旧 profile 的 RPTC `MSTNAK` 仍是历史结果，拒绝原因未知。之后两次真实 BM network-only Echo 测试已回送 TS2 private stream；第二次使用 TS2 preset 后 RX-only pipeline 产生了 start/voice/end。这不是“无真实 Echo”，但仍没有验证 native 自动 PTT、HRI/COM/WinMM 播放或电台端到端回声。详见 [网络登录诊断](../docs/BM网络登录诊断.md) 和 [BM 回声诊断](../docs/BM回声无播放诊断.md)。
- `2183cef` 旧源码 clean build 的 25 项离线测试和包审计已通过；当前包含 26 项测试的工作树尚待 root 在 source commit 后 clean build 并全测。真实自动 PTT + BM + 电台回声仍待用户执行。
- HRI T3/T0 的 `T` 记录只是阶段观察，不作为严格硬件 ACK；`radio_state` 保持 `unknown`。
- BM 语音、网络断线、HRI 收尾和资源关闭的候选行为仍需在后续明确授权的联合测试中验证。
