# BM + FTX-1 本地桥接候选

此入口把 BrandMeister DMRD 与 FTX-1 DIRECT 扬声器路径接在一个可见的 native 控制台进程中。它目前是供离线 fake Master 和后续受控联合测试使用的候选程序；构建、loopback 或状态报告都不证明真实 BM 语音回声、HRI 声音或 RF 效果。

较早四轮纯 network-only 探测，以及用户在 `aec0471` 旧候选上运行的一次 native 会话中的五次登录尝试，都在旧 RPTC profile 收到 `MSTNAK`，Master 拒绝原因仍未知。aec0471 会话约持续 26.6 秒，打开了 COM/HRI；用户观察到 BM 红 X/PTT 状态。日志显示 HRI/Y0 控制握手约 1.125 秒，但 BM 未进入 `ready`，没有 BM DMRD 语音往返。之后独立的 E3 network-only 对照到达 `ready`，诊断工具也成功调用本机 UDP 发送 `RPTCL`。E3 只验证 BM 控制配置阶段和本机关闭包发送，不证明 native 桥接、BM 语音 Echo 或电台声音可用。当前源码采用 E3 的 BM 节点元数据及 CC1；新的 native 便携包尚待根会话审查和 clean build。纯 network-only 探测没有启动 native、COM、WinMM、PTT 或 RF；aec0471 的 native 会话属于另一类证据。详见 [BM 4602 网络登录诊断](../docs/BM网络登录诊断.md)。

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

启动器会从脚本同目录的 `private\device-y.bin` 校验固定的 100 字节 Y 素材及 SHA-256，检查同目录 `logs` 可写，查询 COM 与音频设备，并显示唯一完整名称为 `扬声器 (2- USB Audio Device)` 且支持 48 kHz / 单声道 / s16 的 Radio WaveOut。操作者从本次枚举中选择 Radio WaveIn 和 COM；COM5 不会被硬编码。PC monitor 不参与此版本。若素材、端点能力或唯一 radio 输出检查失败，启动器不会运行 native 核心。

启动器先显示四项文本菜单，直接回车默认选择中国鹦鹉测试。也可用 `-Preset parrot-cn`、`-Preset parrot-global`、`-Preset listen-46001` 或 `-Preset manual` 指定；手工入口保留原先逐项输入。固定预设使用下表中的呼号、身份、Master、端口、时隙、色码和目标；COM、WaveIn、WaveOut 仍从本次枚举后由操作者选择。预设密码从 `private\bm-device-password.txt` 读取，密码值不进入进程参数，PowerShell 启动器也不读取或显示文件正文。可以用 `-PasswordFile ABS` 指定另一处本机文件。

| 预设 | 目标 | 类型 | T 键 |
| --- | ---: | --- | --- |
| `parrot-cn`（默认） | 460997 | P 单呼 | 手动按下 T 才允许上行 |
| `parrot-global` | 9990 | P 单呼 | 手动按下 T 才允许上行 |
| `listen-46001` | 46001 | G 组呼 | 严格仅接收，T 被 native 拒绝 |

三个预设均固定为 `BI7KGD`、Gateway ID `461135501`（Source ID `4611355` 加 ESSID `01`）、Source ID `4611355`、Master `43.129.83.124:62031`、TS1、CC1。服务器列表把 `4602.master.brandmeister.network` 列为 `BM_4602_China`、UDP 62031；本机使用已核实的 IPv4 固定值，不使用本地可能返回的 DNS fake-IP。[Pi-Star 主机列表](https://www.pistar.uk/downloads/DMR_Hosts.txt)，[本次公共 DNS A 记录核查](https://dns.google/resolve?name=4602.master.brandmeister.network&type=A)。中国鹦鹉目标 460997 依据 BM 4602 发布者说明；9990 是 SharkRF Homebrew/MMDVM Connector 手册记录的通用 private echo 目标。[BM 4602 发布者说明](https://forum.hamcq.cn/d/5228)，[SharkRF 手册](https://manuals.sharkrf.com/openspot4/en/homebrew-mmdvm-connector.html)。服务器列表中的通用 `password` 文本不是本机 SelfCare 设备密码，不会被采用。

所有 native 配置和 network-only 探测共用同一组 BM 节点元数据：RX/TX `438800000`、power `0`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、软件类型 `MMDVM_WIREX_Bridge`，options 为空。手工入口仍保留用户输入的 CC；三个预设使用经 E3 组合测试的 CC1。`438800000` 只作为 BM RPTC 节点元数据，不会设置 CAT 频率或使电台发射。BM 网页节点详情中的 `Firmware`/类型文字是程序上报的软件节点标识，不是 FTX-1 固件，也不表示连接了实体 MMDVM Hat。

启动联合候选前，关闭官方 WIRES-X 程序，将 FTX-1 设为 HRI `ON`、Node Mode `DIRECT` 并确认 USB 连接；下行只使用本机电台扬声器。鹦鹉预设需要操作者手动按住/松开手咪 PTT，并在 native 控制台按 `T` 后才产生 DMRD 网络语音；软件不会替操作者按 PTT。手工入口目标若是组呼 46001，native 同样会拒绝 `T`，且不创建发送管线、不产生 LC 或 DMRD 数据报；其他手工目标保持原有行为。

选择手工入口时，native 仍逐项询问呼号、Gateway ID、本机 Source ID、目标 Talkgroup 或单呼 Radio ID、呼叫类型（`G` 组呼 / `P` 单呼）、Timeslot、Color Code、Master 地址和端口。组呼收包按所选 TG 过滤；单呼发送目标是用户输入的远端 ID，接收过滤按本机 Source ID 识别返回单呼。Master 地址可输入 IPv4 或 ASCII 主机名；主机名会通过 Windows 有界解析转换为 IPv4，控制台显示固定地址供核对。当前只支持 IPv4。DIRECT 没有可声明的地理坐标或 RF 频率；RPTC 中使用上述固定格式的空位置坐标和节点元数据，不代表设备所在位置或 CAT/RF 频率。手工 Color Code 仍按用户输入传给 BM。

`listen-46001` 只登录 BM 并被动处理已经转发到本机的 46001 组呼。要收听该 TG，操作者必须先在 BrandMeister SelfCare 为此 Gateway/TS 配置静态订阅；程序不会发送组呼激活包，也不保证登录后自动收到该 TG。预设的 46001 发射策略同样应用于手工入口。

输入 `START` 后 native 才会打开 COM、WinMM 音频和 BM UDP。手工入口在 native 控制台隐藏输入密码；预设入口在提示 `START` 前从指定私有文件读取密码。文件最多 128 字节，只接受非空可打印 ASCII 内容和至多一个文件行尾；密码值不放入命令行、环境变量、日志、报告或 Git。native 在打开设备前验证文件，并在运行结束时擦除其进程内密码缓冲。手工隐藏输入仍允许空格。

本次运行最长 120 秒，关闭流程最多等待 3 秒。发射许可的入口中，`T` 显式开始/结束 BM DMRD 上行；操作者仍需手动操作电台手咪 PTT。46001 组呼的 `T` 会被 native 策略拒绝，不启动 TX 管线，网络发送边界也拒绝任何应用层 DMRD 包。上行进入 codec 前固定应用 16x 软件 PCM 增益，并将既有 `pcm_gain::SignalStats` 的增益前后样本数、RMS、峰值及削顶数写入状态报告；该固定倍率沿用用户确认的旧独立原型人工试听结果，新 BM 链路的声音仍待真实联合测试验证。网络下行只播放到选定的 Radio WaveOut。程序不发送 RF/PTT 控制命令，不自动上行，也不自动重连旧语音。HRI 的 T3/T0 `T` 记录只用于推进本机串口播放阶段，不作为严格 ACK 或 RF/PTT 行为证明。`Q` 或 Ctrl+C 会进入有界收尾。启动前首次状态报告写入/刷新失败时，native 会清除密码并在打开设备前以退出码 2 结束；运行中状态报告写入/刷新失败会触发同一有界收尾并返回 2。屏幕和 `logs\bm-bridge-*.jsonl` 记录 `bm_state`、`bm_failure`、连续失败数、控制 UDP 收发计数和最近 `InputResult`，只记录状态/计数，不记录密码、挑战盐、认证散列、原始 DMRD 或语音内容。若本次运行从未达到 BM `ready`，最终报告明确标记未确认 BM 连接，native 返回退出码 2；这和 HRI 状态分开判断。

当 BM 已进入 `ready` 且 HRI 已确认 Y0 时，控制台才会显示就绪操作提示。鹦鹉预设提示操作者先按电脑 `T` 开始网络上行，再按住手咪 PTT 说话，松开后再按 `T` 结束并等待回声；程序不会自动按 PTT 或开始上行。46001 仅接收预设会显示收听提示，不给出上行操作指引。

若有界收尾期间没有观察到 HRI T0 对应的 `T` 记录，状态报告会保留 `downlink_call_bounded_cleanup_incomplete`，桥接会阻止后续下行并以退出码 2 结束；该本机串口观察仍不能证明电台已恢复或 RF/PTT 状态。

本地构建、fake Master loopback 和设备能力查询没有连接真实 Master 或电台。预设已显示固定参数，手工入口会询问 BM 配置；操作者在本机 native 控制台确认 `START` 后，程序才连接本次配置的 Master 并打开所选 COM 和 WinMM 电台端点。真实端点联合测试尚未由离线证据验证。若 PowerShell 在 native 已调用后报告异常，资源状态需根据 native 控制台和 JSONL 报告确认，启动器不会猜测其已安全退出。

## 已知验证边界

- 源码构建与 fake Master loopback 测试属于离线软件证据。
- 设备能力查询只读取本机 WinMM 列表和格式支持，不打开音频流。
- 旧 profile 的四轮纯 network-only 探测和 `aec0471` 一次 native 会话中的五次登录尝试都在 RPTC 阶段收到 `MSTNAK`；aec0471 会话确实打开了 COM/HRI并观察到 HRI/Y0 握手，但 BM 未进入 `ready`，没有 BM DMRD 语音往返。之后独立 E3 profile 到达 BM `ready` 并成功本机发送 `RPTCL`，但还没有完成真实 DMRD Echo 语音往返或新源码的 native 联测。新源码改用 E3 metadata 与 CC1，需根会话 clean build 后才形成新便携包。详见 [网络登录诊断](../docs/BM网络登录诊断.md)。操作者输入 `START` 后，预设入口才会尝试连接固定 Master 并打开所选设备。
- 真实 native + COM/WinMM 联测、声音和 RF 仍未执行；离线构建和真实 BM network-only 探测都不构成这些结果。
- HRI T3/T0 的 `T` 记录只是阶段观察，不作为严格硬件 ACK；`radio_state` 保持 `unknown`。
- BM 语音、网络断线、HRI 收尾和资源关闭的候选行为仍需在后续明确授权的联合测试中验证。
