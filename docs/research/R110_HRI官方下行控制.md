# R110：官方 HRI 下行、PTT 与语音队列路径

更新：2026-10-28。本文只分析 WIRES-X 2.010 官方 `HRI-UART.dll` 的静态代码，重点核对 T/S 记录选择、G/H/R/E 队列输入、语音首部与 PTT 状态方向。没有运行厂商程序或 DLL，没有打开串口、访问电台、播放音频、连接网络或触发 PTT/RF。REA 伪代码来自 Ghidra 反编译，不是原始源代码。

## 目标和证据范围

| 项目 | 观察 |
| --- | --- |
| 固定样本 | `research/inputs/v2.010/payload/HRI_UART.dll`，SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed` |
| 安装文件 | `C:\Program Files (x86)\YAESUMUSEN\WIRES-X\HRI-UART.dll`，SHA-256 与样本相同 |
| REA | `rea-agents 6.7.0`、Ghidra `12.1.4`，目标 PE32/x86；唯一 document 为 `target-56e0050ef6af.dll` |
| 加载证据 | `list_documents`：`ev_34f07c46038aecc34dcc91836e35576786e9dc6e393ded88f820e4c55cdea1b9` |

静态结果确认代码里的函数、字段读写、队列类型和窗口消息。它们没有证明官方程序在用户这次呼叫中实际走过这些分支，也没有证明设备接受了记录或扬声器播出了语音。

## 结论

1. `SetIncallFirstVoice` 不是“设置首音方向”的写入函数。它只返回 `DAT_10191d38[index] != 0`，也就是询问指定 HRI 对象槽是否已有对象。当前 HRI DLL 代码本身没有在这个函数里设置呼叫方向、PTT、首部或音频状态。Evidence：`ev_a34393d8e0306fff8abad4af4d42d10cff7ecbe9b962c0f42353b3bd2ffede3d`。
2. 官方 `SendTrcvPttCmd(index, value)` 先查同一对象表，再把 `value` 写进 owner `+0x44`（字符串日志称 `PttSw`）。`PttSw` 变化后，子对象 `+0x2c4 == 5` 才走 T 构造；其它子状态变化走 S 构造。这证明了两个内部候选队列分支，不足以把 S 叫作 Busy 命令，也不足以把 `+0x2c4==5` 等同于 DIRECT、电台接收或用户界面模式。Evidence：`ev_5bb834fbcfd1fd2c1e3f0b21a61ab52e8f3b2588a5ed9ca632cb4884182cbc2f`、`ev_d5a284cd9091cf6f0d70feafdd14a48e6faca271131dff6b9d04dfb135378791`、`ev_23add9b801ea1fb07a79cb312a6c003b13a152421b16f7c3387a866c014e3f5a`。
3. 官方 T 记录有带数据的路径。HRI 从接口队列收到 G 记录后，会把 68 字节首部放到 owner `+0x1420`，再把首部后的尾串解码并缓存；H/R/E 记录和结束标记也进入状态处理。T 构造函数会复制非空首部及其尾部。当前应用固定发 T3、源 ID 另行覆盖的测试路径没有执行这段 H/G/R/E 记录解析，也没有提交这 68 字节首部和队列中的语音块。因此只改 source ID 不能复现官方记录数据流。Evidence：`ev_e0eaf1ab2302ef45109d91a9cda53cd175c911718409b7dc5f66a0ff0f138d2e`、`ev_dd4741e6a283be5d7a5c88c8e35f4a98f22825de30ac56f6d3e015d8ee702ad9`、`ev_0b9ed8732ace5fbca14b93278f85c286ae2354053325a9da2b7c36b1e0c320b4`。
4. G 记录首部尾随数据的前 3 个解码字节有专门用途：第 1 字节写 owner `+0x289c` 并与旧值比较；接下来的 2 字节写 owner `+0x2490`，后续状态处理会用这个值选择不同分支。解码循环把这 3 字节和剩余字节作为同一连续块处理。HRI 代码没有进一步把剩余块切成 5 份，所以 48/68/93 字节长度与 `3 + 5×9/13/18` 的吻合只能作为待核线索，不能当成 HRI 已经识别出五个声码器分片的证据。Evidence：`ev_ff3b86eb2d794e9b21e25e777ed5b79fbc7ba58efb404a9b41d4cf1f61dda27c`、`ev_af377ccbc045e89e9964c53d4ab86c39d7534f358fda167ec8bf64bfc7435d28`、`ev_41dd62f0ba0e27eee32dc1c33bd25314f9ca62f9a933fd434341a2c6eac45d78`。
5. HRI 静态字符串分别列出 `1:Analog RX(PTT OFF)`、`3:Digital RX(PTT OFF)`、`2:Analog TX(PTT ON)`、`4:Digital TX(PTT ON)`。这说明官方代码区分接收且 PTT 关闭的状态与发送且 PTT 开启的状态；字符串不能说明 FTX-1 机身 BUSY/TX LED 的颜色含义或点亮逻辑。Evidence：`ev_310b7faf6deb14ed2813c5715b5ac35e01746472cdb523ffbe7a4533571daa30`。

## HRI 对象、模式字段与序列化分支

`FUN_1000dcb0` 通过配置接口读取 `DGKEY_NUM_TRCVTYPE` 到 owner `+0x50`，读取 `DGKEY_NUM_OPE_MODE` 到 owner `+0x58`。它用 `+0x50` 选择 0–3 的状态文字。这里的 `owner+0x50` 是配置字段；它不是 Ghidra 把栈变量命名成 `+0x50`，也不是 `+0x2c4` 子状态。Evidence：`ev_9bc2cafd6346899991119b9750b7e0b00869e56fc93562ba588b1099e0a93281`。

另一条独立选择发生在 `FUN_1000a070`：构造参数低字节为 `0xff` 或高字节为 `1` 时，选择 `CDigiDataFuncDirect` 虚表，否则选择 `CDigiDataFuncHri` 虚表。这个条件控制记录序列化器。代码没有把它与 owner `+0x50` 的 `DGKEY_NUM_TRCVTYPE` 或线程子状态 `+0x2c4` 合并成同一个“DIRECT”开关。Evidence：`ev_67cf25295bc7fbadae50dda6ebac3950bc0e3cc0b77b371ce12a93dd2979c231`。

## PTT 请求会分到 T 或 S 队列

`SendTrcvPttCmd` 的第一参数索引全局对象表 `DAT_10191d38`；对象存在时调用 `FUN_1000f100`。后者比较和更新 owner `+0x44`，并记录 `PttSw` 状态变化日志。

- 若 `owner->child + 0x2c4 == 5`，状态变化时调用 `FUN_10014b50(owner, 0)` 生成 T 候选；若状态未变化，则只有新值为 1 且 owner `+0x50==1` 或 owner `+0x2c8!=0` 才再次走 T 路径。
- 若子状态不为 5，只有 `PttSw` 变化时才调用 `FUN_1000afb0`。它以内部类型 `S`、长度参数 10 构造记录，正文首字符为 `PttSw + '0'`，随后加入内部队列。函数没有字符串或解析分支把 S 命名为 Busy。
- `FUN_10014b50` 构造内部类型 `T`。它会读取 AMBE 数据并用 owner `+0x50`、`+0x248c` 等字段形成首字符和头部。其 T 文本最后由 `FUN_1000b130` 包装成类型 `0x54` 的内部队列项，再调用 `FUN_1000a140` 入队。`FUN_1000a140` 对队列使用互斥量并按长度/内容做去重；这些代码仍属于 DLL 内队列，不能单独证明物理串口写入或电台动作。

现有主程序 R68 静态记录显示，`StartRcvVoice` 会在条件成立时选 `Hearing` 行 9（ToHRI-PTT 值 1），结束播放的一条路径会选 `Talk_Idle` 行 8（值 0），再由公共封装调用 HRI 导出。该信息来自 EXE 的旧静态分析，不能代替这轮 HRI DLL 分支运行证据；参见 [R68 报告](../../research/planning/R68_SendTrcvPttCmd调用与状态边界.md)。它也没有把 `1/0` 单独定义成电台的开始/停止协议值。

## 官方队列记录怎样进入 T 首部与数据尾部

`FUN_10014dd0` 根据 owner `+0x28f8` 选择两组接口回调：值为 2 时使用接口偏移 `+0x48/+0x44`，其它值使用 `+0x68/+0x64`。它从回调取记录，读取 node `+4` 的记录类型：

| 类型 | 代码行为 | 边界 |
| --- | --- | --- |
| `#` | 记录 Start Mark，调用释放/推进回调 | 这是队列记录字符，不等于已经有网络呼叫事件 |
| `H` | 记录 Call pre indication；调用 `FUN_10014070` 解析头信息 | 函数只更新本地头/类型状态，不证明对端或 UI 显示结果 |
| `G` | 调用 `FUN_10014330` 解析首部和尾随 hex 数据；按状态更新 owner 首部 | 记录来自两个接口槽之一；HRI 静态代码不能说明实际生产者是哪个网络/音频来源 |
| `R` / `E` | 发送窗口消息 `0x1434`；在头部长度与数据类型条件满足时，把记录改标为 `E` 并复制给 AMBE 输出缓冲 | 这是缓冲区处理，不证明声码器已播放或 RF 已发送 |
| `$` | End Mark；`param_1 != 1` 时返回结束状态并清空计数，`param_1==1` 时释放记录后继续读取 | 结束符在不同调用参数下有不同处理 |

`FUN_10014330` 的偏移关系可以直接复核：

1. G node `+9..+0x4c` 的 68 字节复制到 owner `+0x1420`。
2. owner 头部字节 `+4` 执行 `|=4`，字节 `+3` 写 ASCII `'1'`，owner `+0x248c` 取头部字节 `+4` 的低 4 位。
3. G node `+0x4d..+0x4e` 两个 hex 字符解成 1 字节，写 owner `+0x289c`。这字节只在此函数内与上一次值比较，并通过输出参数报告是否变化；它的业务名称没有恢复。
4. G node `+0x4f..+0x52` 四个 hex 字符解成 2 字节，写 owner `+0x2490`。`FUN_10017ee0` 会按 `0x5d4d/0x5d50/0x5d52/0x5d51/0x5d55/0x5d53/0x5d54/0x5d56` 分支，修改 `+0x2498` 或 `+0x3e4`；字段的产品含义未恢复。
5. 解码循环仍从 node `+0x4d` 开始，所以这 3 字节也计入整块长度。循环把尾随 hex 一次性解码成二进制，没有出现固定的 5 段循环或 9/13/18 字节分段。

`FUN_10014070` 从 G/H 首部字节取数据类型 `(byte & 0x0b) | 4`。类型 4、6、7 分别令 owner `+0x28e8` 为 `0x66`、`0x8e`、`0xc0` 个字符；`FUN_10014b50` 对 AMBE 字符串检查的长度分别是 `0x60`、`0x88`、`0xba` 个字符，两组数相差 6 个 hex 字符，也就是 3 字节。G 路径则明确解析这 3 字节为 `+0x289c` 的 1 字节和 `+0x2490` 的 2 字节，因此可以把这 6 个 hex 字符对应的额外数据定位到输入尾串开头。HRI 没有进一步证明剩余字节是五个声码器帧，也没有给出各帧分隔符；这些需继续查记录生产者或声码器搬运函数。

## 两个方向的 PTT/数据事件

HRI 的状态函数把软件控制请求和电台侧 PTT 指示分开处理：

- `FUN_10018a70` 的字符串称 `rSt38_FrameCheckTime`。它通过配置过的接口回调检查首尾呼号；子状态为 5 时调用 T 构造，其它状态调用 `FUN_10014600(0)` 的 F 路径。无数据分支递增计数、通知主程序并重试；有结束状态时再检查接口 PTT 状态。
- `FUN_10019730` 的字符串称 `rSt38_RcvAmbeResp`。处理 T/F 路径的返回值；返回 3 或 4 后读取接口 `+0x18`。读取值为 0 时，它把状态字段 `+0x28fc/+0x2900` 置 3，日志写“Switching to PTT-ON progress”；否则排一个 PTT-OFF 定时消息。
- `FUN_1001df60` 的字符串称 `rSt32_RcvFrameResp`。分隔符分支日志为 `PTT-OFF`；AMBE 数据分支日志为 `* PTT ON *`，并向 owner 窗口发送 `0x141a`，WPARAM 为 `+0x248c`，LPARAM 为 `+0x1d4`。
- `FUN_1001e1c0` 的字符串称 `rSt60_RcvPttSwInd`。它检查来自 transceiver 的 PTT 指示；数字 PTT 已开启时向主程序发送窗口消息 `0x0c2a` 请求 binary frame，再调用 `FUN_10013720` 组织数据。这是电台侧 PTT 指示后向主程序取数据的路径，不能与主程序 `SendTrcvPttCmd` 的下行请求混为一谈。

相关 Evidence：`ev_60bf2c92db2c31c96f48b38fda45dedfde40a047e54960ec024eed8edda5bda9`、`ev_a45d11d05f862051b623ae94442bed3592e054deba70ffe457bf2ea7c6c571af`、`ev_6d707ad47e975d3cffc6fc9885b486d7bd657231ce9d184eb29c5da3e819d874`、`ev_998396d42019961c53dd6d500ad49bbf7dbdd12cc7b2168931fb53893a836b5d`。

HRI 可见状态字符串分别标记 RX/PTT OFF 与 TX/PTT ON；这些字符串不能说明 FTX-1 机身 BUSY/TX LED 为何在新来话时点亮、由何种状态驱动。DLL 中没有 LED GPIO、颜色字段或更新调用证据。静态分析不能判定机身指示灯的颜色含义或触发条件，也不能把指示灯当作 PTT 已开启或发生 RF 的证据。

## 静态代码能支持的接收控制边界

仅凭这份 HRI DLL，尚不能给出一份可直接实现并确保电台播放的完整接收控制契约。下面是已由静态代码支持的边界，不能单独当作可上机的替代实现：

1. 主程序先确认目标对象槽已创建，再走官方状态路径；`SetIncallFirstVoice` 只可用于槽存在性检查。
2. 主程序状态变化调用 `SendTrcvPttCmd` 后，应保留子状态 `+0x2c4` 的实际选择：值 5 进入 T 路径，其他值只在 PttSw 改变时进入 S 路径。不要在没恢复该子状态前把 T3 改成 S0/S1。
3. T 路径需有实际 G/H/R/E 记录：68 字节 G 首部、首部后的 3 字节元数据、按 header type 约束的完整 AMBE 数据长度，以及 R/E/结束记录状态。空首部默认填充值不等同于这组运行时数据。
4. 完成和停止要等待主程序/HRI 状态机中的结束与 PTT 响应分支；`SendTrcvPttCmd(...,0)`、`$` End Mark 或日志字符串单独都不能证明电台已释放 PTT。
5. 用户所说的“DIRECT”必须对应到 HRI factory 参数、owner `+0x50` 配置和 child `+0x2c4` 状态的实测来源后，才可确定命中哪条路径；DLL 静态代码没有提供三者间一一映射。

仍需确认的最小观测点：

- WIRES-X 主程序在实际新呼叫开始/结束时，哪个 HRI 对象索引、factory 参数、`+0x50/+0x58` 配置值及 child `+0x2c4` 生效。
- 实际一次下行期间，从 owner 两组接口槽中取到的 H/G/R/E/#/$ 记录顺序、总长度、首部 68 字节和尾部全部字节；其中呼号/个人字段需脱敏。
- 同一次呼叫中，T/S/F 项如何经过 DLL 队列到主程序串口写入，及 HRI/电台回来的 RcvFrameResp/AMBE 响应、PTT OFF 完成条件。
- `+0x289c` 第 1 字节和 `+0x2490` 2 字节的字段名，剩余 `45/65/90` 字节是否确实按 5 个 `9/13/18` 字节单元划分。
- FTX-1 机身 BUSY/TX LED 对应的状态、点亮条件及实际 RF 测量。HRI DLL 未提供 LED 颜色语义；不能通过串口 PTT 候选帧或软件日志代替测量。

## 证据索引

详细 Evidence ID、目标 SHA-256、函数范围和最小摘要见 [`r110_hri_evidence_index.json`](evidence/r110_hri_evidence_index.json)。REA 选定 document 名为 `target-56e0050ef6af.dll`；查询 ID 均来自该 HRI Ghidra 目标。请与同 SHA 的官方安装 DLL 一起复核，不要把 HRI 中间队列字符串当作未经转换的 USB 原始帧。
