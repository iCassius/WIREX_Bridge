# R116 CAT 能力与控制实现

## 结论

FTX-1 的 CAT-1 可以设置无线机自身的 MAIN/SUB 频率和通信模式，也可以读取并设置 `PC` 功率控制值。FM/C4FM 应由 FTX-1 的无线机模式命令 `MD` 控制；应用不应把 HRI 音频改成 PC 数字调制链路。`MD` 的设置读回只证明 CAT 参数一致，不证明 HRI 正在用相同的语音/DN/Wide 路径。

本次实现只开放一个短时 CAT-1 串口会话。每个会话先读 `ID;`，核对固定 ID `0840`；设置操作先读 `TX;`，仅 `TX0;` 继续。任何实际设置帧发出前，再读一次 `TX;`，并且要求仍为 `TX0;`。若当前值已等于期望值，不发设置帧，也不多做这次写前 TX 查询。设置命令最多写一次，随后必须读回同一参数并逐值比较。会话以 2.5 秒为默认总时限，可由调用方设为 100–3000 毫秒；额外 TX 检查共用原 deadline；失败不重发。RTS/DTR 均关闭，`finally` 路径关闭串口。模块不发送 PTT/TX、HRI 开关、`EX` 菜单、AI 设置或功率开关命令。

## 官方命令证据

当前 Yaesu FTX-1 产品支持页列出的 CAT 手册是日文 `FTX-1_CAT_OM_JPN_2512-D.pdf`。实现对照了该最新版与本地英文 `FTX-1_CAT_OM_ENG_2508-C.pdf`；与本次使用的命令有关的枚举和值域相符。CAT 手册页码是手册印刷页码。

| 用途 | 命令和官方参数 | 本次代码行为 |
|---|---|---|
| 机型识别 | `ID;` → `ID0840;`，0840 为固定值，p.18 | 每次操作先读并精确核对；不匹配即停止；查询和所有写操作都执行。 |
| 发送状态保护 | `TX;` → `TX0;` / `TX1;` / `TX2;`，p.25 | 仅读。设置操作开始时及每条实际设置帧发出前都要求 `TX0;`；若目标值已相同而不发设置帧，则不做第二次查询。模块不构造任何 `TXn;` 设置命令。 |
| MAIN/SUB 模式 | `MD0;` / `MD1;`；FM=`4`、FM-N=`B`、C4FM-DN=`H`、C4FM-VW=`I`，p.20 | 允许单侧设置这四种模式，读回须侧别、模式均精确相同。其它模式不开放为写操作。 |
| MAIN 频率 | `FA;` 读；`FA` 加 9 位 Hz 参数设置，30,000–470,000,000 Hz，p.4、p.17 | 允许 MAIN `FA` 读写；设置前读旧频率，单次写入后精确读回 Hz。UI 只在 Bridge 核心停止时允许此操作。 |
| SUB 频率 | `FB;` 读；`FB` 可设置，p.5–6、p.17 | 只查询；本次不提供 SUB 改频按钮。 |
| 功率控制值 | `PC;` 读；`PC{路径}{3位瓦数};` 写，路径1=FTX-1 Field Head 官方范围5–10 W；路径2=SPA-1官方范围5–100 W，p.22 | 只允许从本次 `PC;` 读数识别路径，再设置对应值并读回。应用限值：路径1为5–10 W；路径2限制为5–50 W。官方给路径2的上限是100 W；50 W 是本应用为满足用户范围与避免向更高功率扩展而设的上限。 |
| AI 状态 | `AI;` → `AI0;` / `AI1;`，p.8 | 只读并显示。AI=1 时无线机可能异步送出 AI 命令状态；读取时会在同一总时限内忽略其它完整 CAT 帧，等待本次命令和侧别对应的响应。模块从不发送 `AI0;` 或 `AI1;` 设置。 |

频率和模式是 CAT 在无线机侧设置的 VFO 属性；PC 端无需先把 HRI 语音变成 PC 数字调制。C4FM-DN 和 C4FM-VW 是两种不同的 FTX-1 模式，命令表分别列为 `H` 和 `I`。仅凭 CAT 枚举无法确认 HRI 的“Digital”选项最终使用 DN 还是 VW，因此界面保留两个明确选项，不将二者统称为一个已验证的“HRI C4FM”状态。

## 其余 RF 通话设置候选

下表按常见 FM/C4FM 通话的直接使用价值排列。它们是后续研究项；除 `FA`、`MD`、`PC` 外，本次不增加 CAT 写入口。CAT 手册列出命令合法和值域，但没有证明在 HRI 会话运行时修改它们不会打断音频、节点或数字身份状态。

| 顺序 | 设置 | 官方命令 / 范围 | 目前判断 |
|---:|---|---|---|
| 1 | MAIN/SUB 工作频率 | `FA` / `FB`，9 位 Hz，30 kHz–470 MHz；p.17 | 已将 MAIN `FA` 加入最小写操作；SUB `FB` 留作后续。频率选择直接决定收发频点。 |
| 2 | 无线机模式 | `MD`；FM=`4`、FM-N=`B`、C4FM-DN=`H`、C4FM-VW=`I`；p.20 | 已加入。它控制 FTX-1 的无线侧模式，不改变 HRI 的 TRCVTYPE、WIRES-X Voice CH Modulation 或 Node Mode。 |
| 3 | FM 亚音/数字静噪码与中继偏移方向 | `CT` 选择关闭/CTCSS 编码/编解码/DCS/PR FREQ/REV TONE，p.10；`CN` 选择 CTCSS 号码 000–049 或 DCS 号码 000–103，p.9；`OS` 选择 simplex/+/-/ARS，FM 模式才有效，p.22 | 可由公开 CAT 命令设置；`OS` 只选方向，具体各频段偏移量由另外的菜单项决定。本次不写。DCS 三位码不等于 C4FM DG-ID。 |
| 4 | 发射功率设定 | `PC`，见上表 | 已加入受限写入。PC 读回的是无线机功率控制值，不是天线端或负载端测得的 RF 输出功率。 |
| 5 | 静噪阈值 | `SQ` MAIN/SUB，000–255，p.25 | 公开 CAT 可读写；适合调节接收静噪，不是 DG-ID 或接收音量。本次不写。 |
| 6 | 接收音量 / AF 增益 | `AG` MAIN/SUB，000–255，p.8 | 手册命令名是 `AG`（AF GAIN），不是 `AF`。可以单独调无线机接收音频电平；尚未验证它对当前 HRI 取音支路的效果。本次不写。 |
| 7 | 麦克风增益 | `MG`，000–100，p.20 | 调整无线机麦克风输入；公开命令和值域明确，但不能据此认定它控制 HRI 送入的 USB/数据音频。本次不写。 |
| 未映射 | C4FM DG-ID、HRI 开关、WIRES-X Node Mode | 公共 CAT 手册未列出独立 DG-ID 命令，也未给出可核实的 HRI/Node Mode 菜单编号 | 不使用未经官方确认的 `EX` 菜单编号，不把 DCS 码或 FTX-1 `MD` 模式当成 DG-ID/HRI/Node Mode。由用户在无线机或 HRI 界面手动配置。 |

## 串口和会话规则

- `PortRole` 必须显式为 `CAT-1`。模块不根据 `COM11`、`COM5` 等名字推断角色。Yaesu 手册说明 Enhanced COM 是 CAT-1、Standard COM 是 CAT-2；端口号随电脑而变（p.2–3）。
- 每次调用必须传 `HriPortName`。归一化后 CAT 端口和 HRI 端口相同则在打开串口前拒绝。当前实机观察到 CAT-1 为 COM11、HRI 为 COM5，但这只是本机当日配置，不能写成固定映射。
- CAT-1 默认38400、8数据位、无校验、1停止位；手册允许 CAT-1 选择1或2停止位、4800/9600/19200/38400/115200波特（p.4）。模块默认38400/8N1；用户可显式选择合法波特率和1/2停止位。RTS/DTR/硬件流控关闭。
- 一个操作在串口打开后先发送 `ID;`，然后读 `AI;` 和 `TX;`。设置操作要求无线机空闲。每个请求只发送一次；读取循环只丢弃完整的异步帧或另一侧 MD 响应，不会把它们当成目标值。目标帧必须命中请求命令和侧别；目标帧格式错误、无线机返回 `?;`、总时限耗尽、读回不相同都会得到明确错误状态。
- 成功和失败路径均尽力关闭串口。应用不在后台轮询或长期占用 CAT COM；UI 应把请求排队为串行单操作，禁止操作期间重复触发，超时后不自动重发。Bridge 核心运行时 UI 禁止 CAT 写操作；读查询可以由 UI 按单操作调度。

## PowerShell 模块接口

文件：`ui/windows/RadioCat.psm1`。导出：

- `Invoke-Ftx1CatOperation`
- `New-Ftx1CatModeCommand`
- `New-Ftx1CatFrequencyCommand`
- `New-Ftx1CatPowerCommand`
- `ConvertFrom-Ftx1CatFrame`

统一操作调用参数：

```powershell
Invoke-Ftx1CatOperation `
  -Operation query|setPower|setMode|setFrequency `
  -PortName <COM名称> -PortRole CAT-1 -HriPortName <COM名称或空字符串> `
  [-BaudRate 4800|9600|19200|38400|115200] [-StopBits One|Two] [-TimeoutMs 100..3000] `
  [-PowerWatts 5..50] [-Side Main|Sub -Mode FM|FM-N|C4FM-DN|C4FM-VW] `
  [-Side Main -FrequencyHz <Int64 Hz>]
```

生产调用不传 `Transport`。模块仅为 fake tests 留了可注入的 `Transport`，这些测试不创建 `SerialPort`。

结果对象固定为 schema v1：

```text
schema_version, operation, status, source, port_name, port_role,
started_at_utc, updated_at_utc, desired, prior, observed, capabilities,
cleanup_status, error_code, error_message
```

`status` 为 `confirmed|busy|identity_mismatch|rejected|mismatch|unknown`。`confirmed` 表示操作所请求的 CAT 值已读回相符且串口清理成功；对 `query` 表示本次查询读数完整且串口清理成功。写入已发出但超时或未能精确读回时返回 `unknown` 或 `mismatch`，不能据此报告已应用。即使 CAT 读回目标值相同，只要串口关闭失败，整体状态也为 `unknown`，并报告 `error_code=serial_close_failed`、`cleanup_status=close_failed`。错误路径保留已经读到的单项 `observed`，未读取字段的 `value/source/updated_at_utc` 为 null。

`observed` 字段：

- `radio_id`：0840 字符串。
- `auto_information_enabled`：布尔值；AI=1不禁止操作。
- `tx_state`：整数0/1/2。
- `main_frequency_hz`、`sub_frequency_hz`：Int64 Hz。
- `main_mode`、`sub_mode`：`{ side, side_code, mode_code, mode }`。
- `power`：`{ path, path_code, watts }`；这是 CAT 设置值。

所有读数包装为 `{ value, source, updated_at_utc }`，真实串口调用的 `source` 为 `FTX-1 CAT-1`；fake transport 的顶层与各读数来源都标为 `CAT test transport`。`capabilities.set_frequency` 和 `set_mode` 的 `available` 反映本次已通过 `ID0840` 且最近一次 `TX;` 为 `TX0`；`set_power.available` 还要求同会话读到有效 `PC` 路径。模块无法读取 Bridge 核心生命周期，UI 还必须在核心停止时才允许写入。`capabilities.set_power.maximum_watts` 只从同一次 `PC;` 读回路径计算：FieldHead=10、SPA-1=50。期望瓦数独立保存在 `desired`；当前 CAT 功率在 `observed.power.value.watts`。25 W 是用户期望值，不会在查询或连接时自动写入。若设备读到路径1，25 W 请求返回拒绝；不把25自动夹到10。界面显示的是功率控制设定值，不写成“实际射频功率”。

`capabilities` 的字段与模块结果一致：`query={supported,available}`；`set_frequency={supported,available,target_side,minimum_hz,maximum_hz,step_hz}`；`set_mode={supported,available,modes,target_side}`；`set_power={supported,available,readable,active_path,minimum_watts,maximum_watts,step_watts,unavailable_reason,value_semantics}`；`hri_mode`、`node_mode` 的 `supported` 与 `available` 均为 false。

`cleanup_status` 取 `closed|close_failed|not_opened`。adapter 即使 `Close()` 抛错也会继续调用 `Dispose()`；若关闭或释放失败，结果保留已有读回数据并设置 `cleanup_status=close_failed`。成功读回后清理失败时，操作返回 `unknown` 和 `error_code=serial_close_failed`；若串口未成功打开则为 `not_opened`。

## 实机只读观察

主会话在2026-10-30对 CAT-1 COM11 做了一次38400/8N2只读会话；RTS/DTR关闭，`Open → ID/MD/PC/TX reads → Close`，没有发送设置、PTT或发射命令：

| 请求 | 读回 | 结论 |
|---|---|---|
| `ID;` | `ID0840;`，约24 ms | 当前 COM11 应答 FTX-1 固定 ID。 |
| `MD0;` | `MD04;`，约16 ms | MAIN 当前为 FM。 |
| `PC;` | `PC2025;`，约16 ms | CAT 功率控制配置为路径2、25 W；不是 RF 输出测量。 |
| `TX;` | `TX0;`，约16 ms | 采样时 radio TX 与 CAT TX 均关闭。 |

该串口随后关闭，CAT写入次数为0。之后第一次用模块运行完整查询时，发现串口adapter的`ReadFrame`闭包无法找到模块私有读帧函数；结果为`unknown`，但清理状态是`closed`，也没有发送任何设置命令。修复将读帧逻辑内联到adapter闭包后，以SerialPort-like fake覆盖同一个adapter封装，再运行完整CAT-1查询成功：`status=confirmed`、`cleanup_status=closed`，约328 ms；`ID0840`、AI关闭、`TX0`、MAIN/SUB的`FA/FB`频率与`MD`模式、`PC`路径和值均完成读回。配置写入仍为0。频率没有在本文件记录数值，因为这项验证只需证明查询结果完整。

这些观察证明当时 CAT-1 读查询请求/响应工作且串口已关闭；它们不验证 CAT 写操作、发射功率、天线端输出、HRI音频路由或实际通话。

## 离线验证

执行：

```powershell
pwsh -NoLogo -NoProfile -File tools/test-radio-cat.ps1
```

`52 CAT fake assertions (no physical serial ports opened)` 在 Windows PowerShell 5.1.26100.8737 与 PowerShell 7.6.5 均通过。覆盖大小写输入规范化、命令编码、响应解析、ID/TX双门槛、TX0后变TX2的写前竞态、same-value不额外查TX、AI开启时正常工作、完整异步帧过滤、频率与功率范围限制、精确读回、Close失败仍尝试Dispose、Dispose失败、整体清理失败不报成功、HRI/CAT同端口拒绝、fake来源标记、生产串口适配器的 `ReadFrame` 闭包与RTS/DTR关闭，以及不发送PTT/TX/EX命令。串口适配器测试向内部构造器注入SerialPort-like对象，没有创建实体串口。

## 参考资料

- [Yaesu FTX-1 产品支持页（列出当前 CAT 手册）](https://connect.yaesu.com/indivisual/items/ftx-1series/)
- [Yaesu FTX-1 CAT Operation Reference Manual 2512-D（日文 PDF）](https://connect.yaesu.com/indivisual/wp-content/uploads/2025/11/FTX-1_CAT_OM_JPN_2512-D.pdf)
- 本地英文 CAT 手册及文本提取：`../../../firmware/docs/FTX-1_CAT_OM_ENG_2508-C.pdf`、`../../../firmware/analysis/pdf-text/FTX-1_CAT_OM_ENG_2508-C.txt`（仅为本机研究副本，不复制到应用包）。
