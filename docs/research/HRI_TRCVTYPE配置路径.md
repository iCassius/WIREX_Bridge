# TRCVTYPE 配置来源：有限静态切片

日期：2026-10-26。此记录只读检查 WIRES-X 2.010 固定 PE 和既有 R57/R14/R22/R64/R77/R11 结果；没有启动官方程序、加载厂商 DLL、打开 COM/音频或操作电台。

## 固定样本

- 外层研究样本 [`WIRES_X.EXE`](../../../research/inputs/v2.010/payload/WIRES_X.EXE)，SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`。
- 外层研究样本 [`HRI_UART.dll`](../../../research/inputs/v2.010/payload/HRI_UART.dll)，SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed`。
- EXE 由本机 VS2019 `dumpbin.exe` 14.29.30159.0 用 `/headers` 和有界 `/disasm:bytes /range` 检查；数据表从原始 PE 字节读取。地址均为 PE VA；未用反汇编结果冒充运行时行为。
- WIRES-X EXE `.rdata` 的 PE VA 起点为 `0x709000`、文件偏移为 `0x307c00`；下文消息表行同时记录 VA 与原始文件偏移，按完整六 DWORD 读取。

## 当前能闭合的数据关系

HRI 的 `OnRdoStsInd`（`0x10023eb0`）在配置导入分支读取 X 正文偏移 `0x0e` 的一个字符，经过 `HexToBin` 与查表后写入 `DGKEY_NUM_TRX`；相同解码结果还派生 `DGKEY_NUM_OPE_MODE` 字符 `'4'` 或 `'5'`。R57 记录没有显示该 X 处理函数直接写 `DGKEY_NUM_TRCVTYPE`，也没有给出该位置原始字符到 `TRX` 数值的完整查表。因此目前只能把 `body[0x0e] → TRX setter` 写成已证链，不能把字符 `'2'` 直接解释为 `TRX=2`。

EXE 的 `0x489d50` 从传入的配置对象读取 `DGKEY_NUM_TRX`（key 字符串 VA `0x722e68`），以返回值作为行号查 PE 数据表 VA `0x7bf4b0`（文件偏移 `0x3bdeb0`）。每行 12 字节；代码把第一列写入全局 `0x7bfe78`。代码比较第二列与 3：若不是 3，才把第二列和第三列分别写入全局 `0x7bfe7c`、`0x7bfe84`；若等于 3，则在 `0x489d8f` 跳到 `0x489da2`，跳过这两次写入。下面列的是第二列的原始表值，不表示该值每次都会写入全局：

| `DGKEY_NUM_TRX` 返回值 | 第二列原始表值 |
|---:|---:|
| 0 | 1 |
| 1 | 1 |
| 2 | 2 |
| 3 | 2 |
| 4 | 1 |
| 5 | 3 |
| 6 | 3 |
| 7 | 2 |
| 8 | 3 |
| 9 | 3 |
| 10 | 1 |
| 11 | 2 |
| 12 | 3 |
| 13 | 3 |
| 14 | 3 |

`0x48ac18` 是调用 `0x489d50` 的一个静态调用点；其分支条件来自全局 `0x02f1c6d8`。另有 `0x48a000` 附近的另一条取 `DGKEY_NUM_TRX` 并使用重复表 VA `0x7bf568` 的路径。该路径在 `0x48a090` 比较第二列与 3，并在相等时跳过更新，和 `0x489d50` 的处理一致。前置字符串比较的产品模式含义尚未恢复。

主程序还有一个 `TrsvContrlModeAms` 设置分支：`0x4898f2` 先检查全局 `0x7bfe78`；满足一支条件时在 `0x489915` 将 `DGKEY_NUM_TRCVTYPE` 设为 2、`DGKEY_NUM_OPE_MODE` 设为 1，并把相应配置写入 key `TrsvContrlModeAms`（字符串 VA `0x722b40`）；另一支在 `0x489948` 将两键设为 1 和 0。`0x725e0c` 对应 `DGKEY_NUM_CONTROLMODE`，会被写到全局 `0x7bfe78`；这是 WIRES-X 内的控制配置，不能称为电台 `NodeMode`。两支进入条件所用 `EAX/ECX` 的上游值、该设置与 X 更新的调用时序仍未查明。

EXE 字符串和 setter 调用点另证实实际写 key 的两个路径：

1. 在 `0x4a1600`，程序通过共享配置接口取 `DGRP_VOICE`（字符串 VA `0x722ad0`）；随后 `0x4a16b6` 从全局 `0x7bfe7c` 取值，并于 `0x4a16b7–0x4a16bd` 经接口虚表 `+0x18` 把该值写到 key `DGKEY_NUM_TRCVTYPE`（VA `0x725df8`）。其直接调用者 `0x49ebb0` 在 `0x49ebbd–0x49ebc1` 压入两个零后调用 `0x4a1600`。
2. `0x4a1900` 的配置路径在 `0x4a1923` 取 `DGRP_DATA`（字符串 VA `0x722b18`）；`0x4a195d–0x4a1965` 对 `DGKEY_NUM_TRCVTYPE` 直接写常数 2，之后 `0x4a1970–0x4a1978` 对 `DGKEY_NUM_TRX` 写常数 5。它前面还把 `DGKEY_NUM_DW_SW` 设成 0。

按完整六 DWORD MFC 项重新对齐后，当前核实的关联为：VA `0x727b38` / 文件偏移 `0x326738` `[0x1653, 0, 0, 0, 0x0e, 0x004a1600]`，VA `0x727b50` / 文件偏移 `0x326750` `[0x1654, 0, 0, 0, 0x0e, 0x004a1900]`，VA `0x727b68` / 文件偏移 `0x326768` `[0x1655, 0, 0, 0, 0x0e, 0x004b04c0]`。因此 `0x1653` 分派到 VOICE 的 `0x4a1600`，`0x1654` 分派到 DATA 的 `0x4a1900`，而 `0x1655` 指向另一个函数 `0x4b04c0`。此前把 `0x1654` 配到 `0x4a1600`、把 `0x1655` 配到 `0x4a1900` 的说法是错误的，已按原始完整表行撤回。

HRI 在对象 `+0x50` 使用 `TRCVTYPE` 数值索引 VA `0x1018a758` 的文本表；已核对索引 0/1/2/3 显示 `OFF`/`Analog`/`Digital`/`AMS`。因此数值与这些 WIRES-X 字符串的对应关系已确认。数值 3 在 `0x489d50`/`0x48a000` 映射流程里保留此前全局值，而不写入全局；`TrsvContrlModeAms` 路径也会在特定条件下把值改成 1 或 2。`DGRP_DATA` handler 的固定 `TRCVTYPE=2`、`TRX=5` 属于另一组显式设置，不应与 `TRX` 映射路径合并为同一条事务。

## X 配置后的窗口消息链：有限闭合

HRI `OnRdoStsInd` 的 X 配置成功尾部在执行若干配置 setter 后，于 `0x10024949–0x10024952` 调用 `SendMessageA`：目标 HWND 从 HRI 对象的 owner 字段取得，消息为 `0x1426`，`wParam` 是对象 `+0x1d4` 保存的原始 mode 低字节值（以 DWORD 保存），`lParam=0`。R14 的构造指令在 `0x1000c5f4` 对构造参数执行 `AND 0xff`，并于 `0x1000c5fa` 写入 `+0x1d4`；高字节另写到 `+0x1dc`。按完整六 DWORD MFC 行读取 EXE `.rdata`，VA `0x723b28` / 文件偏移 `0x322728` 的表项为 `[0x1426, 0, 0, 0, 0x0e, 0x0048ab80]`，所以该消息的 handler 是 `0x48ab80`；前一条 `0x1424` 行尾部包含 `0x489490`，不能把那个相邻函数地址配给 `0x1426`。

`0x48ab80` 的分支条件检查消息 `wParam`。在值为 `1` 或 `0xff` 的分支，它通过共享配置接口取 `DGRP_VOICE`，随后在 `0x48ac18` 调用 `0x489d50`，另一分支路径在 `0x48ac1f` 调用 `0x489f40`。`0x489d50` 读取 `DGKEY_NUM_TRX` 并按前述表更新控制全局值。因此静态上已经闭合“X 配置成功 → HRI 同步通知 owner `0x1426` → EXE 的 `0x48ab80` → 条件分支读取 VOICE 配置并调用 TRX 映射函数”这条候选路径；具体分支取决于 HRI 对象当时 `+0x1d4` 保存的低字节值，不能把它简化成每次 X 配置都会调用 `0x489d50`。

另有 `0x497aa0` 异步 `PostMessageA` `0x1654(0,0)` 和 `0x1401(0,0)`；`0x1654` 的完整 MFC 表项对应 DATA setter `0x4a1900`，不是 VOICE setter。该异步消息生产者的上游触发时序仍未恢复，也不能和 X 尾部的同步 `0x1426` 分支混为同一事务。

R57 的 X 配置导入会写 `DGKEY_NUM_TRX`，故静态上存在候选间接关系 `X body[0x0e] → TRX → EXE 映射 → VOICE 的 TRCVTYPE`。但尚未证明 X setter 与 EXE getter 使用同一组对象、同一配置组或连续执行。即便 WIRES-X 配置显示 `Digital`，这仍不能单独证明 FTX-1 面板显示 `DN`，也不能把 `DGKEY_NUM_CONTROLMODE` 当作电台 `NodeMode`。

## 与 HRI 对象组及 COM 的边界

不要把 HRI 对象表槽号当成 `DGRP_DATA` 或 `DGRP_VOICE` 的编号。R22 中 EXE 的 `CreateDigiConnect` 调用第二实参为 0，HRI 用它索引 `DAT_10191d38[0]` 对象槽；构造函数的模式 word 是另一实参。R14 显示构造函数按这个 word 的字节分支选择 `DGRP_VOICE` 或 `DGRP_DATA`，但没有把所有调用点的实参或分支正式映射到用户可见模式。R64 的 Direct 工厂空闲观察只证明当时 HRI 对象 `+0x50=1`；它没有采样上述两个 EXE 设置 handler。

`DGRP_DATA` 和 `DGRP_VOICE` 是共享配置接口传入的组名。已有 R77/R11 静态资料把单个 HRI 对象线程的队列消息接到 EXE 的 `WriteFile`，并把所选 COM 路径接到同一全局串口句柄字段；R64 的一次运行观察看到 Direct 实例，但没有测量这些设置 handler 的调用。现有证据没有显示两个组分别创建 COM，也没有证据证明 `0x4a1600` 或 `0x4a1900` 改变了该 COM 句柄。COM5 是此前本机硬件/运行观察，不是这些静态配置写入推导出来的值。

## 官方帮助术语与 R91 观测边界

固定 WIRES-X 2.010 CHM 的 `Transceiver.html` 将 Voice CH 的 `[Modulation]` 定义为 WIRES-X 的语音通道设置：`Digital` 表示 RX/TX 均为 C4FM digital，`Analog` 表示 RX/TX 均为 FM analog。该页还说明 Analog/FM 只用于 Voice CH，不能在 GM 模式下选择；FTX-1 可用 USB 线直连 PC。`Status.html` 把状态标签 `HRI` 定义为 Fullspec Node operation（列举 FTX-1），并把 `P-HRI`、`PDN` 列为其他操作类别。`Transceiver.html` 对 PDN 的数字模式限制针对 PDN 配置；不能把它套用到该页归为 Fullspec Node 的 FTX-1。

R91 的一次 10 秒窗口记录的是 HRI 实例字段：表项 0 的 `+0x50=1`，按 HRI 文本表显示为 `Analog`；表项 1 的 `+0x50=0`，按同一表显示为 `OFF`；两个表项的 `+0x58=0`。这组字段描述当次 HRI 对象状态。现有证据没有把它们映射到电台菜单中的 `Node Mode`，也没有证明它们决定 FTX-1 的 RF 音频路由或 LCD 内容。

FTX-1 的 `Node Mode` 是电台自身设置。官方手册将 `AP RADIO` 描述为电台侧接入点模式，将 `AP PC` 描述为 PC 与电台配合、经 C4FM 空中链路工作的模式，将 `DIRECT` 描述为 PC 与 FTX-1 直连通信、该模式不经空中发送或接收；用户确认当前选择 `DIRECT`。WIRES-X 帮助里的 Voice CH `[Modulation]` 是另一项语音通道设置；Status 的 `HRI`/`PDN` 是连接/运行类别；R91 的 `TRCVTYPE`/`OPE_MODE` 是当次 HRI 对象字段。现有材料没有显示修改其中一项会设置另外几项，也没有解释 LCD 空白或 Bridge 运行期间的 RF 接收状态。Node Mode 的手册描述与待核对的运行/退出路由见下一阶段推进计划。

复核来源：原始 `WIRES_X.CHM` SHA-256 `EACF2FDC55788665966F4ED2B4D0D1028DE070BA07A3B5F7357532B9E8E615A3`；提取页 [`Transceiver.html`](../../../research/rea/wiresx-chm-static/html/Transceiver.html) SHA-256 `4579671A7D15B26B808CDD8E0941DCCF79281BFF2DAF44FB0DA26DE18B8D330E`；[`Status.html`](../../../research/rea/wiresx-chm-static/html/Status.html) SHA-256 `5DBE1126A090BDFBEAC21E0AB39E2EE876959B408319C8A02A9C1438797699B8`。R91 的观测条件及字段见 [R91 双实例只读观察](R91双实例只读观察.md)。

## 尚未确认的产品含义

- `TRCVTYPE` 显示文本与 FTX-1 面板的 `FM`、`DN`、`AMS` 是否对应仍未知。不能只凭 `Analog`/`Digital`/`AMS` 字符串推断电台当时的模式。
- `body[0x0e]` 原始字符到 `DGKEY_NUM_TRX` 结果的实际查表仍需补证；X 成功路径发送 `0x1426` 已确认，但实际走 `0x48ab80` 哪个 mode 分支取决于对象 `+0x1d4` 保存的原始低字节值，尚无这次 X 输入对应的取值观察。
- `DGRP_DATA` 的 `TRCVTYPE=2` / `TRX=5` 由 `0x4a1900` 写入，表项 `0x1654` 指向该函数；`0x1655` 则指向 `0x4b04c0`。`0x1654` 具体何时产生、其设置与 VOICE 组映射的先后覆盖关系尚未恢复。它与 `TRX` 表第二列原始值 3 的路径属于不同 handler/组上下文，不构成已证实的数值矛盾。

本轮没有做 UI 或 X 输入运行测试。下一静态切片应恢复 `0x1654` 的生产者条件，并核对 HRI X 导入 setter 使用的配置对象与 `0x48ab80`/`0x489d50` 的 VOICE getter 实参是否别名；之后才有依据设计 AP-PC 模式的条件判断。不得据此自动切换电台模式或生成发射命令。

## 复核材料

- 本文对应的原始研究稿：[TRCVTYPE 配置来源小切片](../../../research/rf/TRCVTYPE配置来源小切片.md)。
- [R57：X 配置接收字段与只读校验](../../../research/planning/R57_X配置接收字段与只读校验.md)
- [R14：HRI 初始化与模式状态](../../../research/planning/R14_HRI初始化与模式状态.md)
- [R22：HRI 连接参数与主程序调用](../../../research/planning/R22_HRI连接参数与主程序调用.md)
- [R64：HRI 对象与 Direct 工厂元数据观察器](../../../research/planning/R64_HRI对象与Direct工厂元数据观察器.md)
- [R77：HRI 同实例队列到 UART 路径](../../../research/planning/R77_HRI同实例队列到UART路径.md)
- [R11：HRI 串口句柄与收发对象的静态追踪](../../../research/planning/R11_HRI句柄与收发对象.md)
