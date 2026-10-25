# WIRES-X 2.010 屏幕字段与模式路由静态研究

状态：静态研究，2026-10-25。只检查官方 WIRES-X 2.010 文件、既有 REA 记录和手册；没有启动官方程序，没有打开 COM/CAT/BM/audio，没有操作电台或发射 RF。

## 结论

- 官方软件中能确认本机身份配置字段，也能确认 HRI DLL 把 `Direct:OFF/ON` 写入自己的 `CDigiPanelDlg` 控件。现有证据没有把这些 PC 面板字段映射到 FTX-1 LCD、截图中的左右列表或 `ALL SEARCH / ENTER ID / CATEGORY / DISCONNECT / LOG` 软键。
- HRI DLL 导出的 `FrameTrxDataToTrcvFrame` 会解析一串按 ASCII 十六进制字段码和长度切分的文本，并把字段写入内部结构；没有确认它的上游调用者或数据来自 UART、网络还是其他模块。因此这不是已恢复的 UART 线上帧规范。
- HRI 的 `DGKEY_NUM_NDDIRECT` 有两处明确软件行为：值为 0 时，DigiPanel 显示 `Direct:OFF`，Y 正文候选偏移 5 写字符 `'1'`；值非 0 时显示 `Direct:ON`，正文写字符 `'2'`。没有证据证明这个布尔配置等同 FTX-1 的三态 Node Mode（AP RADIO / AP PC / DIRECT），也没有证明它关闭独立 VFO 的普通 RF 接收。
- 当前 Bridge 把候选 Y[5] 固定为 `'2'`，只与官方 `DGKEY_NUM_NDDIRECT` 非零时的字符编码相同。这个字节相同不能证明语义相同；不能据此声称 Bridge 正在选择电台 DIRECT 模式或关闭 RF。
- 用户报告在 HRI 显示 145.1 MHz 时实际听到 RF 声音，S 表也有信号。当前实际 Node Mode、活动 VFO/频率状态以及该声音与 `NDDIRECT` 配置的关系仍未查明；本轮没有读取或操作电台。
- BrandMeister 收包事件目前提供远端 DMR Source ID、TG、时隙等字段，没有远端呼号或 TA 文本。显示层应以 Source ID 作可靠回退，并把目录查询结果作为可选补充；本机呼号必须与当前远端发话者分开。

## 检查对象

| 文件 | 版本 | SHA-256 | 用途 |
| --- | --- | --- | --- |
| `Wires-X.exe` | 2.0.1.0 | `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671` | PC 客户端配置和用户资料 |
| `HRI-UART.dll` | 2.0.1.0 | `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed` | HRI 配置字段、内部面板、文本解析和队列 |
| `RigDataIf.dll` | 2.0.1.0 | `94d1217feb047288329e79e0d5de2167c79450f1945119b2ed6c6376b02a7410` | 名为 AMBE 的数据队列 |

REA 静态分析使用 Ghidra 12.1.4 x86。三份官方文件均与外层 `research/inputs/v2.010/payload/` 中已校验的同名样本具有相同 SHA-256。新增证据摘要在 [`r71_hri_screen_route_followup_20261025.json`](../../research/rea/v2.010/r71_hri_screen_route_followup_20261025.json)。本轮尝试从 REA 会话导出全量证据时，`get_evidence_bundle` 返回 0 条保留记录，因此 R71 JSON 仅是摘要，不能代替完整反编译。完整的 `FUN_10023eb0` 分析已保存在 [`r31_usb_branch_evidence_bundle.json`](../../research/rea/v2.010/r31_usb_branch_evidence_bundle.json)，Evidence `ev_01d61fb7cb4474099c6b033fac4464466ccef9e2d3bf36ad936a95d9f54c77dd`，覆盖函数 3,007 字节并包含伪代码、汇编和限制说明。EXE 字段记录在 [`wiresx-exe-ui-followups-20261025.evidence.json`](../../research/rea/v2.010/wiresx-exe-ui-followups-20261025.evidence.json)。

## 软件保存的本机资料与 HRI 配置

### PC 客户端本机资料

EXE 的 `FUN_004bdb50` 从 `USER_INF` 读取 `CallSign`、`CityName`、`StateName`、`Country`、`ID_No`、`SvNodeID`、`User_RadioID` 等本机资料。`FUN_004184f0` 处理本机资料提交，`FUN_004834a0` 处理 User ID 校验和更新。证据分别见 EXE REA 记录 `ev_f378677e…899ccee48`、`ev_916addca…739f55e`、`ev_76d711aa…637845b`。

这些路径证明 PC 客户端保存和更新本机配置；没有找到把这些键映射到某个 FTX-1 LCD 控件或 HRI UART serializer 的调用链。它们也不是 BrandMeister 当前远端通话者资料。

### HRI DLL 本机节点/房间配置

HRI 的 `FUN_1000d370` 通过配置接口从 `DGRP_COMMON` 读取以下键并写入 HRI 对象：

| 配置键 | 静态观察到的用途 |
| --- | --- |
| `DGKEY_STR_NODE_ID`、`DGKEY_STR_NODE_RADIO_ID` | 本机 Node ID 和 Radio ID 字符串 |
| `DGKEY_STR_ROOM_ID`、`DGKEY_STR_ROOM_RADIO_ID` | Room ID 和 Radio ID 字符串 |
| `DGKEY_STR_CALL_SIGN`、`DGKEY_STR_ROOM_NAM` | 本机 Call Sign 和 Room Name 字符串 |
| `DGKEY_NUM_ACKFLAG`、`DGKEY_NUM_DIVIDEINFO`、`DGKEY_STR_MYPOSITION` | 其他本机配置字段 |

关键偏移与代码路径见 HRI REA `ev_b79c7e…db0d65d2`、`ev_872f684…9878c888`，以及外层 [`R14_HRI初始化与模式状态.md`](../../research/planning/R14_HRI初始化与模式状态.md)。这些是 HRI 配置载入事实，不证明字段会发到电台屏幕或远端节点列表。

### HRI 自己的 DigiPanel

HRI 构造函数 `FUN_1000c3d0` 创建资源 ID `0xF3` 的 `CDigiPanelDlg`；`FUN_10007b40` 从 `DGRP_VOICE` 或 `DGRP_DATA` 读取频率、接收/发射参数等，并刷新该面板。它读取 `DGKEY_NUM_NDDIRECT`，按零/非零选择 `Direct:OFF` 或 `Direct:ON`，再把文本交给 `FUN_1002a8f0`。后者在直达分支调用 `SetDlgItemTextA(hwnd, control_id, text)`，控件 ID 为 `0x671`。

这闭合的是 PC 端 HRI DigiPanel 的文本控件更新。窗口创建、窗口类与模式标签证据见 `ev_419922…e453e758c`、`ev_5057df…ba022ab`、`ev_0111c3…00a32bef`；直接字符串引用见 `ev_ac9fa6…4f79d28b`。不要把该控件当成 FTX-1 LCD。

## HRI 文本字段解析与模式响应

### `FrameTrxDataToTrcvFrame`

HRI 导出 `FrameTrxDataToTrcvFrame` 位于 VA `0x100020B0`，导出 ordinal 31。REA 反编译 `ev_282fad…47bc2cfe` 显示它调用 `UdpComFuncs.dll!CutOutString`，再按稀疏字段码 `C0–C5`、`D1–D8`、`DA–DD`、`DE–E1`、`E3–E6` 写入 `param_2` 结构。`CutOutString` 把前两位 ASCII 十六进制字符解为字段码，后两位解为字符数，再复制后续字符；完整复核见 [`R10_HRI语音文本与载荷.md`](../../research/planning/R10_HRI语音文本与载荷.md)。

例如，`C0` 与 `C1–C5` 会向 `param_2+0x87` 拼接文本；`DA–DD` 分别写入四个最多 10 字节、先以空格填充的区域；`DE–E1` 分别写入四个最多 5 字节的区域。这些偏移没有已验证的业务名称。该导出在 DLL 内没有已解析直接调用者，未确认其输入来自串口、网络或其他模块，也未把其输出连到 FTX-1 显示器。

### 模式响应更新的是 HRI 配置与 PC 面板

HRI 内部通用分派 `FUN_10022730` 按字符类型把 `M`/`W` 送到 `FUN_10022fe0`，把 `X` 送到 `FUN_10023eb0`。`FUN_10022fe0` 将 `param_1+1+iVar4` 处的四个 ASCII 十六进制字符解成长度值；可见接受值为 `0x43`、`0x45`、`0x6B`、`0x48`。`0x48` 分支会校验若干配置值；`DGKEY_NUM_NDDIRECT` 只接受 ASCII `'0'` 或 `'1'`，写回当前 HRI 配置组，然后调用 `FUN_10007b40` 刷新 DigiPanel。`FUN_10023eb0` 的 `X` 分支也把 `local_15f` 限定为 ASCII `'0'`/`'1'` 后写入同一配置键；X 入口输入是否来自 UART 仍未知。

这证明 HRI DLL 内有接收解析候选、配置值校验和 PC 面板刷新，不证明 `M`、`W`、`X` 是 UART 线上命令类型或这些消息由电台屏幕产生。R57 的既有静态字段恢复将 X 配置处理函数 `FUN_10023eb0` 检查的 `local_15f` 定位到 100 字节正文偏移 `0x05`；结合 R49 已记录的 6 字节 parser 前缀，对应完整记录偏移 `0x0B`。X 输入是否来自 UART 仍未知。对应 REA 记录为 `ev_e85c52…2806ca2`、`ev_ed6ea7…b5fec7`、`ev_ae4eeb…c49c812` 和调用者记录 `ev_0db3c3…87acffe`，字段表见 [`R57_X配置接收字段与只读校验.md`](../../research/planning/R57_X配置接收字段与只读校验.md)。

### DIRECT 配置与 100 字节 Y 正文候选

HRI `FUN_1000cc80` 将 `DGKEY_NUM_NDDIRECT` 注册到配置接口，传入参数 `(1,1)`；配置接口的函数实现不在该 DLL 内，不能据这两个参数推导初值或三态模式含义。

`CDigiPanelDlg` 的 Y 正文候选处理函数 `FUN_100095c0` 先将目的区域填为 100 个 ASCII `'0'`，再调用 getter 读取 **`DGKEY_NUM_NDDIRECT`**：零值写到偏移 `0x05` 的字符为 `'1'`，非零值为 `'2'`。这部分由 REA `ev_e7404…791c2c4` 直接确认。HRI 的消息表将 `0x1435` 指向该 handler，消息表属于 `CDigiPanelDlg`；R36 仍未闭合发送侧 HWND 与实际接收窗口实例，也未证明该正文最终进入串口或被电台 LCD 显示。见 [`R34_Y正文生成函数与字段表.md`](../../research/planning/R34_Y正文生成函数与字段表.md) 和 [`R36_Y消息表与发送窗口关联.md`](../../research/planning/R36_Y消息表与发送窗口关联.md)。

这个 key 的 `Direct:OFF/ON` 文本和 Y 字符映射只是在 HRI 软件内部彼此一致。FTX-1 手册第 29 页另列 AP RADIO、AP PC、DIRECT 三种 Node Mode，并描述 DIRECT 为经连接 PC 与 FTX-1 通信、不经空中发送/接收；默认模式为 AP RADIO。二者虽然名称相似，但静态代码没有证明 `DGKEY_NUM_NDDIRECT` 就是该三态 Node Mode 中的 DIRECT，也没有证明这个布尔字段控制普通 VFO 的 RF 接收。用户报告在 HRI 显示 145.1 MHz 时实际听到 RF 声音且 S 表有信号；本轮没有记录实际 Node Mode、活动 VFO 或 RF 声音来自哪条接收路径，因此 `NDDIRECT` 与该现象的关系仍未知。

## `SetDigiTrcvData` 与语音队列边界

HRI `SetDigiTrcvData` 导出 `0x10001D00` 进入 `FUN_10001d20`，构造内部短记录并交给 `FUN_1000bc80`；随后以消息 `0x1401` 通知 HRI 线程。既有 R60/R61 把该消息接到内部 event 1 状态分派，但没有闭合队列节点到 UART `WriteFile` 或某个帧 serializer 的路径。故不能把该导出名直接解释成“把数据发到电台屏幕”。证据见新增 REA `ev_97979f…3061ad`、`ev_c24e07…1e04b`、`ev_e6b9f6…efc72` 及 [`R60_HRI队列语音路径与串口边界.md`](../../research/planning/R60_HRI队列语音路径与串口边界.md)、[`R61_HRI线程派发与出队交接.md`](../../research/planning/R61_HRI线程派发与出队交接.md)。

`RigDataIf.dll` 的 `ToHriAmbeAdd` / `ToHriAmbeGet` 是名为 AMBE 的字符串节点队列。HRI 内部 `FUN_10014600` 在 `+0x28f8 == 2` 时取一组 HRI AMBE 队列槽，在其他值时取另一组槽；未证明该字段等于 `DGKEY_NUM_NDDIRECT`，也未证明两路队列对应 AP/DIRECT、RF 接收或电台扬声器。队列布局和调用路径见 [`R62_RigDataIf队列消费与HRI绑定.md`](../../research/planning/R62_RigDataIf队列消费与HRI绑定.md) 及 REA `ev_7e3f0a…062091`、`ev_63dd0e…b7564e`、`ev_75021a…9bcb8a`。

S/T 控制路径另有 HRI 语音活动状态记录；已经看到的 `T3` 启播与 `T0` 收尾不能据此归类为 RF 节点模式切换，也不用于补足上面未闭合的 LCD 路径。

## 显示 DMR 呼号的安全数据来源

当前 Bridge 的 `CallConfig` / `ReceiveEvent` 有远端 Source ID、目标 TG、时隙、CC 等，不含远端呼号或 TA 文本。远端呼号不能使用本机 `BI7KGD`、`USER_INF/CallSign` 或静态订阅值代替。

建议显示时先以当前通话的 Source ID 作身份主值；可选地按单个 ID 查询官方 RadioID 服务，并把结果标为外部映射及记录更新时间。缓存应带 TTL/检索时间，离线或无记录时继续显示数字 ID；不要把整份 Radio ID 目录镜像进便携包。call-start 建立远端身份，收到同一通话的补充资料时更新，call-end、断线或会话切换时清除临时身份。本机呼号始终作为本机资料单独显示。

## 下一步最小闭合条件

EXE 的 `FUN_004fd630` 已确认装载 `HRI-UART.dll`、按名称取得 `FrameTrxDataToTrcvFrame` 和 `SetDigiTrcvData`，并初始化对象 `+0x48` 与 `+0x1c` 两个函数指针槽。下一步追踪这两个槽位的间接调用者、调用输入及返回/输出数据，再确认数据是否进入 UART 写入路径以及是否绑定到 FTX-1 LCD；这些调用关系和 LCD serializer 仍未闭合，因此暂不设计 LCD 更新命令。

为了判断用户听到的 145.1 MHz RF 声音与 WIRES-X 路由的关系，后续记录实际 Node Mode、活动 VFO 和频率，并在已知有接收的场景观察现有会话的配置状态。若要发送新的 RF 模式写入命令，应先恢复该命令的协议和作用路径。本轮只做静态研究，没有进行这些观察或写入。
