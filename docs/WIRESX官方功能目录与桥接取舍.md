# WIRES-X 2.010 官方软件功能目录与桥接取舍

状态：只读静态研究草稿（2026-10-25）
适用对象：官方 WIRES-X 2.010A 客户端及其随附帮助文件；此文不说明其他版本的行为。

## 结论摘要

- 官方客户端围绕 Yaesu WIRES-X 节点和房间运行：先注册本机节点身份，再发现、连接和管理远端 Node/Room，并提供音频、列表、位置、QSL、News、Chat 和运维窗口。
- `USER_INF/CallSign`、`User ID`、Room Name 等属于 WIRES-X 本机或远端 Node/Room 信息。当前证据没有把它们映射到 FTX-1 LCD，也没有证明它们就是 BrandMeister 当前 DMR 发话者资料。
- 已追到 EXE 的 Direct COM 配置读取、提交和本机用户资料更新路径。`FUN_004fd630` 已确认装载 `HRI-UART.dll`、按导出名取得 `FrameTrxDataToTrcvFrame` 与 `SetDigiTrcvData`，并初始化对象 `+0x48`、`+0x1c` 两个函数指针槽；后续间接调用者、输入/输出数据、UART 写入与 LCD 绑定仍待追踪。
- 对现有 WIREX Bridge，沿用已通过 `005c5e8` 首轮 DIRECT 实际语音闭环的 HRI/PTT/audio 路径。P1 的 Node/Room/当前发话者显示以及 LCD/路由字段是本轮新研究重点。News、图片、注册管理列为 P2，只有需求明确后再接。

## 取证范围与覆盖边界

| 项目 | 核对结果 | 证据边界 |
|---|---|---|
| 主程序 | `research/inputs/v2.010/payload/WIRES_X.EXE`，SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671` | REA 的 Ghidra 12.1.4 x86 会话确认目标路径与哈希。文件版本为 2.0.1.0；程序内有 2.010A 字样。 |
| 帮助文件 | `research/inputs/v2.010/payload/WIRES_X.CHM`，SHA-256 `EACF2FDC55788665966F4ED2B4D0D1028DE070BA07A3B5F7357532B9E8E615A3` | 静态抽取到 `research/rea/wiresx-chm-static/`。`html/` 下有 45 个 HTML 主题文件；目录树文件有 48 个 HTML 引用、45 个不同页面。目录节点共 61 个 Name 项、58 个不同标题（包含菜单/分组节点）。帮助树有英文标题和注释中的日文标题；抽取结果只有一个 `html/` 目录，没有独立日文目录。 |
| PE 资源 | 633 个资源目录项、358 个资源项 | REA 资源检查只枚举资源及图标关系；没有解码全部对话框、菜单模板或资源数据。因此不能将资源枚举称为完整 GUI 结构恢复。 |
| EXE 字符串/函数 | Ghidra 报告 8,849 个已定义字符串、26,964 个过程 | 未定义或压缩数据中的字符串可能没有进入该清单。函数数量仅说明可见的过程规模，不表示已恢复了全部实现。 |
| 重点函数 | 跟踪了 `FUN_004bdb50`、`FUN_00497b90`、`FUN_004184f0`、`FUN_004834a0`，并检查 `FUN_004cda90` 等相关入口 | 这些函数覆盖配置载入、Direct COM 选择、本机资料提交和 User ID 更新等关键路径；没有逐个反编译全部函数。 |
| 运行证据 | 本次不运行官方程序、不连接网络、不打开串口、CAT、PTT 或 RF | 本文只记录帮助文档、PE 静态信息和 REA 反编译证据。不能据此声称实机音频、无线电模式或 BM 联测通过。 |

相关 REA 记录位于 `research/rea/v2.010/wiresx-exe-ui-followups-20261025.evidence.json`。同批证据中的程序身份和关键记录包括：PE 总览 `ev_a7ba4d14…3636c9f9`、资源枚举 `ev_17e4d23e…5de70f3`、Direct COM 初始化 `ev_f378677e…899ccee48`、COM 选择 `ev_41e12f3a…9b3cc88`、用户资料提交 `ev_916addca…39f55e`、User ID 更新 `ev_76d711aa…37845b`。记录中保存了完整证据 ID 和反编译内容。

文中以 `research/` 开头的路径均相对于外层 `WIREX_Bridge` 工作区。原始 binary 和 REA 证据保存在外层 research 目录，不属于 `app` Git 仓库。本文已列出关键程序哈希、函数和结论；这些外部路径仅供本机追证。

## CHM 功能入口目录

下表覆盖抽取目录中的全部 45 个 HTML 页面。页面标题以英文 HHC/CHM 标题为准；“功能”是帮助文件说明，不表示 WIREX Bridge 已实现该项。

| 分组 | 页面文件 | 帮助文件描述的功能 |
|---|---|---|
| 入门与程序生命周期 | `WIRES-X.html`, `Help.html`, `Activation.html`, `Defaultset.html`, `Import_export.html`, `Exit.html`, `YMLAN.html` | 欢迎/操作帮助；使用电台 Radio ID 或 HRI 序列号及 Yaesu 发放的 DTMF ID 完成节点激活；重试激活或恢复默认设置；导入/导出 WIRES-X 注册表设置；退出；YMLAN 支持程序监视并可重新启动 WIRES-X.exe。 |
| 设备与音频 | `Transceiver.html`, `Def_Transceiver.html`, `Repeater.html`, `COMport.html`, `HRI-200.html`, `AudioAdj.html` | 设置受支持的收发机或中继机；选择 COM 与音频设备并打开系统声音设置；配置 HRI-200 模拟接口电平/静噪/PTT/滤波；调整音量。帮助说明 FTX-1 直接连接电脑时使用 USB Type-C；PDN 模式参数由电台设置，电脑端显示但不能编辑。 |
| 节点、房间与本机身份 | `Personal.html`, `RoundQSOset.html`, `Location.html`, `Callsettings.html`, `GeneralSet.html`, `DigitalID.html` | 配置 WIRES ID、本机呼号、User ID、位置、评论和节点风格；创建/设置 Round QSO Room；设置连接许可、进入/返回房间、DTMF 操作、TOT、数字 ID 发送和位置读取。User ID 是 WIRES-X 节点身份；Room Name 帮助明确说它用于电脑列表，不发送给数字电台。 |
| 网络与兼容 | `IPspec.html`, `RoomCompatible.html`, `PortCheck.html`, `Plugin.html` | 选择 IPv4/IPv6；选择新旧 Room 兼容路径；检查 WIRES-X 服务器、Node/Room 控制、语音及 News 所需网络；设置插件。旧版本兼容 Room 的端口规则属于官方旧路径说明，本文没有执行网络检测。 |
| 连接与在线目录 | `Connect.html`, `Refresh.html`, `ActiveList.html`, `GroupWindowCHG.html`, `Bookmark.html`, `Guide_GM.html`, `Status.html`, `ConIDwindow.html` | 连接当前选中的 Node/Room、按 ID 连接、断开、GM 自动连接、刷新列表；浏览 Group/在线 Node/在线 Room；管理书签；显示 GM 指引、状态和已连接房间内用户活动。 |
| Node/Room 信息与列表 | `NodeInfo.html`, `RoomInfo.html`, `MobileUsers.html`, `Makelist.html` | 查看节点/房间 ID、DTMF ID、活动状态、开放策略和访问控制；显示通过 C4FM 节点/房间收到的移动电台呼号、Radio ID、接收时间、接收路径和位置；导出 Group、Active ID、Room ID 和 MyRoom 登录列表的 HTML/XML/CSV。 |
| 语音、消息与记录 | `SoundSet.html`, `News.html`, `Chat.html`, `DTMF.html`, `Log.html`, `Log_window.html`, `ViewQSL.html` | 设置模拟语音播报；查看或传送文字、图片、语音/紧急 News；向远端发送字符 Chat；查看 FM DTMF 操作；记录 Node/News/Room 活动；查看远端 QSL 图片及其公开的身份/位置资料。 |
| 界面与显示 | `Font.html`, `Status_bar.html` | 调整界面字体和状态栏显示。 |

### 帮助文件记录的身份与服务器边界

1. 首次激活需要本机 HRI 序列号或电台 Radio ID、Yaesu 发放的 DTMF ID，并与 WIRES-X 服务器通信。服务器返回本机 WIRES User ID 和登记资料。此流程是 WIRES-X 注册，不是 BM 登录流程。
2. `Personal.html` 中的 CallSign、User ID、城市/州/国家和评论描述本机 WIRES-X Node。`RoundQSOset.html` 中的 Room ID、Room Name、Room comment 描述本机 Room。它们不能直接拿来填充 BM 当前远端发话者。
   - Room Name 的原文位于 `research/rea/wiresx-chm-static/html/RoundQSOset.html` 的 `[Room Name]` 段（HTML 锚点 `#room_roomname`）：“This name will not be sent to digital transceivers. (Only used on the computer list screen.)”
3. `MobileUsers.html` 和 `ConIDwindow.html` 描述的是 WIRES-X/C4FM 收到的终端/节点活动。文档没有说明 BM DMR 当前发话者列表或 FTX-1 LCD 如何显示这些字段。
4. `Import_export.html` 的 `.wsv` 文件可以携带本机 WIRES-X 设置，并要求设备身份和 DTMF 身份匹配；本次没有读取任何用户 `.wsv` 文件。

## EXE 已追踪的配置与数据路径

| 入口/路径 | 已证行为 | 尚未证明 |
|---|---|---|
| 启动配置 `FUN_004bdb50` | 从应用配置读入 `REPEATER/DirectComPort`、`USER_INF/HriEnable`、`HriNoneMode`、`SerialNo`、`CallSign`、`CityName`、`StateName`、`Country`、`ID_No`、`SvNodeID`、`User_RadioID` 等值；当 DirectComPort 为正时调用 COM 处理路径。 | 这些键不等同于 FTX-1 CAT `Node Mode` 命令；没有证据显示启动读取会设置无线电 LCD 或 BM talker 字段。 |
| Direct COM 选择 `FUN_00497b90` | 把选择值交给 `FUN_0040cbc0`；成功后保存 `REPEATER/DirectComPort` 并更新 PC 程序状态。 | 该路径说明 PC 软件选择连接端口，未证明切换电台 AP RADIO/AP PC/DIRECT。 |
| 本机资料提交 `FUN_004184f0` | 提交 HRI/设备身份选择及用户资料，保存 `USER_INF/CallSign`、City、State 等本地配置。 | 没有追到从本机资料到 HRI UART 屏幕文本字段的 serializer 或无线电 LCD 更新调用。 |
| User ID 更新 `FUN_004834a0` | 校验输入的 Node User ID，处理本机身份更新并调用后续更新函数。帮助文件说明该功能会向 WIRES-X 注册资料。 | 网络请求完整链路和 BM 身份关系没有在本次追踪。 |
| Direct / Node Mode 搜索 | 在 8,849 个 Ghidra 已定义字符串中查 `Node Mode` 未找到定义字符串；查到 `DirectComPort` 与 `DGKEY_NUM_NDDIRECT` 字符串。 | 这不是对全部指令、数值协议或未定义数据的排除。不能据此说 EXE 不含 Node Mode 数值控制。 |
| HRI DLL 装载与导出表 `FUN_004fd630` | EXE 用 `LoadLibraryA("HRI-UART.dll")` 装载模块，再用 `GetProcAddress` 按名称取得导出。函数指针 `SETDIGITRCVDATA` 存在对象偏移 `+0x1c`（槽 `this[7]`）；`FRAMETRXDATATOTRCVFRAME` 存在偏移 `+0x48`（槽 `this[0x12]`）。 | 已证实 EXE 的动态装载和两个目标函数指针的初始化；本批未追踪后续调用这些槽位的函数，也未把它们连接到具体 UI 控件或 FTX-1 LCD。 |

`DirectComPort` 是 WIRES-X PC 程序连接配置的一项。FTX-1 的 Node Mode 是电台设置。仅因软件字符串都包含 Direct 一词，不能把二者看作同一控制。

跨 DLL 装载证据位于 `research/rea/v2.010/wiresx-exe-hri-export-load-20261025.evidence.json`。目标为 `WIRES_X.EXE` SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`，Ghidra 12.1.4 x86；`FUN_004fd630` 的 dossier 为 `ev_63deaba48b89a66cbb6491b07918471eca390ae1e1dd6b6b2b679e3865a48ec8`。`FrameTrxDataToTrcvFrame` 由导出名字符串 `FRAMETRXDATATOTRCVFRAME` 取得；本次没有看到 EXE 按 ordinal 31 解析它。完整函数指针表的其他槽已保存在该 dossier 中。此证据只说明 EXE 装载 DLL 并缓存导出地址，未证明两个函数后续何时被调用或它们会更新无线电 LCD。

## FTX-1 HRI / DIRECT 屏幕问题

FTX-1 WIRES-X 手册的 Node Mode 段落（第 29 页）列出：AP RADIO 是独立接入点；AP PC 是连接电脑并通过 C4FM 空中通信；DIRECT 是通过所连电脑和 FTX-1 通信，手册原句写明 DIRECT 不经空中发送/接收；默认值是 AP RADIO。该原句没有解释独立活动 VFO 是否还能接收普通 FM。

用户报告实机在 HRI 页面下以 145.100 MHz 接收 RF 时，既听到了音频，S 表也有信号。用户提供的屏幕可确认当时显示 145.100 FM、HRI/WIRES-X 页面和左右空列表，以及 `ALL SEARCH / ENTER ID / CATEGORY / DISCONNECT / LOG` 软键。画面没有显示 BM 当前用户信息槽位，也不能单凭画面判断实际 Node Mode 或接收路径。

因此“DIRECT 下仍接收 145.100 FM”仍待解释。手册的模式描述与该观察需要逐项对照，不应据此直接判断用户设置错误。后续受控验证需要记录实际 `Node Mode`、HRI/PC 模式状态、活动 VFO/接收频率和 HRI 状态字段，并将监听接收与 WIRES-X 空中连接分开观察；本次未执行该验证。

固件研究中已有 `Node Mode EX010706`、`WIRES-X DG-ID EX010704` 两个 CAT 菜单映射候选，但尚未验证实际查询行为和值域。它们只是以后检查菜单/协议时的定位候选，当前不能作为已支持的 CAT 读写命令。

## WIREX Bridge 取舍矩阵

| 优先级 | 功能 | 输入 → 当前已知处理 | HRI / Yaesu 依赖 | 桥接建议与证据状态 |
|---|---|---|---|---|
| P0 | 电台/HRI 连接、PTT、音频 | HRI/电台 USB、COM 和音频端点 → 官方软件选择设备并建立本地电台连接；本次 CHM 说明接口与设置入口。 | HRI/电台设备必需；WIRES-X 激活服务仅用于官方 WIRES-X 注册。 | 沿用已通过 `005c5e8` 首轮 DIRECT 实际语音闭环的 HRI/PTT/audio 路径。该记录不能代替本轮尚未执行的 native 音频/BM 联测。 |
| P1 | Node/Room/当前发话者呈现 | HRI 帧/电台状态/远端话者资料 → 需要找到协议字段、EXE/DLL producer/consumer 和 GUI 控件的完整关系。 | 显示设备身份可能取自 HRI；WIRES-X Node/Room 列表依赖 Yaesu 服务。BM 发话者应取自 BM 网络数据。 | 单独追踪 EXE 动态 DLL 调用链并与 HRI parser 对照；在字段与窗口/屏幕绑定前，把 BM talker、Room/Node LCD 映射标成未知。 |
| P1 | DIRECT/AP PC/AP RADIO 和 RF 路由 | 电台 Node Mode 设置、PC/HRI 状态和活动 VFO → 官方手册定义模式名称和高层行为。 | FTX-1 固件/设置与 HRI 状态有关；CAT 候选值仍未验证。 | 保存实际模式和 VFO 状态后做受控验证；不要从 `DirectComPort` 或 HRI 设置对话框推断电台模式。 |
| P2 | News、图片、语音公告、Chat、QSL | WIRES-X 远端内容和 Node/Room 状态 → 官方客户端的独立窗口/消息能力。 | 依赖 WIRES-X 连接、服务器和部分 C4FM/Node 能力。 | 当前 BM 语音桥接没有证据需要这些客户端业务；只有提出对应功能需求时再分析协议、格式和权限。 |
| P2 | WIRES-X 激活、Node/Room 注册、远程管理、YMLAN | DTMF ID/设备身份/远程密码及服务器 → Yaesu 注册和运维功能。 | 强依赖 Yaesu 账号/服务器或 WIRES-X 管理链路。 | 不接入当前 PTT/音频桥接路径；不要复用或保存官方注册身份/远程口令。 |

## 待办与禁止外推

- 继续追踪 `+0x48`/`+0x1c` 两个函数指针槽的间接调用者、调用输入与返回/输出数据，并确认数据如何到达 UART 写入路径及是否绑定到电台 LCD；动态装载和函数指针初始化已经确认。
- 把 HRI DLL 的 `DGKEY_NUM_NDDIRECT`、`D5/D7/E4` 对象字段与 EXE UI/电台屏幕逐项对应；当前仅有部分对象读写证据，没有 LCD 映射证据。
- 如果目标是解释 BM 用户呼号，需要先确定 BM 当前 talker 元数据字段和屏幕目标控件；不要用 WIRES-X `CallSign`、本机 `User ID` 或远端 Room Name 代替。
- 不从 8,849 个定义字符串中未搜到某个标签推断数值协议不存在；不从 26,964 个可见过程推断完整实现已恢复。
- 本次未进行官方客户端启动、网络访问、串口/CAT、PTT、音频或射频操作；任何这些行为的成功状态仍需单独的受控验证证据。
