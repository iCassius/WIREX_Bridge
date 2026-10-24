# BM + FTX-1 本地桥接候选

此入口把 BrandMeister DMRD 与 FTX-1 DIRECT 扬声器路径接在一个可见的 native 控制台进程中。它目前是供离线 fake Master 和后续受控联合测试使用的候选程序；构建、loopback 或状态报告都不证明真实 BM 登录、HRI 声音或 RF 效果。

## 构建

在 Windows PowerShell 5.1 中，从仓库运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-bm-bridge.ps1
```

脚本使用已安装的 VS 2019 x64 工具，不安装依赖。它先核对固定 DroidStar commit `becf1dede57c4a70a865e9cb4cac9247e505599a` 的 manifest 中全部 57 个本地文件 SHA-256，再从源码构建 `wirex_bridge.exe` 和原链接清单下的 `wirex_probe.exe`，编译并运行离线测试。产物写入唯一的 `build/_work/wirex-bridge-<commit>-<状态>-<UTC 时间>/` 目录；脏工作树目录带 `-dirty`。脚本不会打包旧 EXE、写 ZIP、修改共享依赖或连接 BM。现有 `003020` 脏构建的 24 项测试发生在最后的状态报告写入门限与 16x 上行软件增益修复之前，当前工作树仍需根会话审阅后重新 clean build 并运行全套测试。

如只需检查编译和链接：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-bm-bridge.ps1 -CompileOnly
```

## 启动前检查和运行

交付便携包时，把 `start-bm-radio-bridge.ps1`、`start-bm-radio-bridge.cmd` 和 `wirex_bridge.exe` 放在包根目录，并把 Y 素材放在根目录的 `private\device-y.bin`。操作者双击根目录的 `start-bm-radio-bridge.cmd`；默认状态报告写入根目录的 `logs\`。启动器只从该目录读取 EXE 和 Y 素材，不扫描源码仓库或包外构建目录。

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

启动联合候选前，关闭官方 WIRES-X 程序，将 FTX-1 设为 HRI `ON`、Node Mode `DIRECT` 并确认 USB 连接；下行只使用本机电台扬声器。上行需要操作者手动按住/松开手咪 PTT，软件只在按 `T` 后产生 DMRD 网络语音，不会替操作者按 PTT。

native 在可见控制台中依次询问呼号、Gateway ID、本机 Source ID、目标 Talkgroup 或单呼 Radio ID、呼叫类型（`G` 组呼 / `P` 单呼）、Timeslot、Color Code、Master 地址和端口。组呼收包按所选 TG 过滤；单呼发送目标是用户输入的远端 ID，接收过滤按本机 Source ID 识别返回单呼。不会硬编码 TG、回声号或单呼目标。Master 地址可输入 IPv4 或 ASCII 主机名；主机名会通过 Windows 有界解析转换为 IPv4，控制台显示固定地址供核对。当前只支持 IPv4。DIRECT 没有可声明的地理坐标或 RF 频率，配置包中的 latitude/longitude 采用合法数值 `0` 表示未配置，不代表设备所在位置；该零值元数据被真实 Master 接受仍待后续联调验证。

输入 `START` 后 native 才会读取 BM 密码并打开 COM、WinMM 音频和 BM UDP。密码通过关闭 echo 的本机控制台输入，允许空格，当前仅接受可打印 ASCII 字符；密码不放入命令行、环境变量、配置文件或状态报告。取消或退出路径会恢复控制台输入模式并擦除密码缓冲。

本次运行最长 120 秒，关闭流程最多等待 3 秒。`T` 显式开始或结束 BM DMRD 上行；操作者仍需手动操作电台手咪 PTT。上行进入 codec 前固定应用 16x 软件 PCM 增益，并将既有 `pcm_gain::SignalStats` 的增益前后样本数、RMS、峰值及削顶数写入状态报告；该固定倍率沿用用户确认的旧独立原型人工试听结果，新 BM 链路的声音仍待真实联合测试验证。网络下行只播放到选定的 Radio WaveOut。程序不发送 RF/PTT 控制命令，不自动上行，也不自动重连旧语音。HRI 的 T3/T0 `T` 记录只用于推进本机串口播放阶段，不作为严格 ACK 或 RF/PTT 行为证明。`Q` 或 Ctrl+C 会进入有界收尾。启动前首次状态报告写入/刷新失败时，native 会清除密码并在打开设备前以退出码 2 结束；运行中状态报告写入/刷新失败会触发同一有界收尾并返回 2。屏幕和 `logs\bm-bridge-*.jsonl` 只记录状态与计数，不记录密码、原始 DMRD 或语音内容。

若有界收尾期间没有观察到 HRI T0 对应的 `T` 记录，状态报告会保留 `downlink_call_bounded_cleanup_incomplete`，桥接会阻止后续下行并以退出码 2 结束；该本机串口观察仍不能证明电台已恢复或 RF/PTT 状态。

本地构建、fake Master loopback 和设备能力查询没有连接真实 Master 或电台。native 会先询问 BM 配置并显示解析后的 Master IPv4；操作者在本机 native 控制台确认 `START` 后，程序才连接用户输入的 Master 并打开所选 COM 和 WinMM 电台端点。这是之后的真实端点联合测试，尚未由当前离线证据验证。若 PowerShell 在 native 已调用后报告异常，资源状态需根据 native 控制台和 JSONL 报告确认，启动器不会猜测其已安全退出。

## 已知验证边界

- 源码构建与 fake Master loopback 测试属于离线软件证据。
- 设备能力查询只读取本机 WinMM 列表和格式支持，不打开音频流。
- 当前开发验证还没有运行真实 BrandMeister Master、FTX-1 COM/WinMM 会话、真实音频或 RF 测试；操作者输入 `START` 后会显式连接本次输入的真实 Master 并打开所选设备。
- HRI T3/T0 的 `T` 记录只是阶段观察，不作为严格硬件 ACK；`radio_state` 保持 `unknown`。
- BM 语音、网络断线、HRI 收尾和资源关闭的候选行为仍需在后续明确授权的联合测试中验证。
