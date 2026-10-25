# WIRES-X 2.010 屏幕字段与模式路由静态研究

状态：静态研究，更新于 2026-10-26。只检查官方 WIRES-X 2.010 文件、既有 REA 记录和手册；没有启动官方程序，没有打开 COM/CAT/BM/audio，没有操作电台或发射 RF。

## 结论

- 官方软件中能确认本机身份配置字段，也能确认 HRI DLL 把 `Direct:OFF/ON` 写入自己的 `CDigiPanelDlg` 控件。现有证据没有把这些 PC 面板字段映射到 FTX-1 LCD、截图中的左右列表或 `ALL SEARCH / ENTER ID / CATEGORY / DISCONNECT / LOG` 软键。
- HRI DLL 导出的 `FrameTrxDataToTrcvFrame` 会解析一串按 ASCII 十六进制字段码和长度切分的文本，并把字段写入内部结构；没有确认它的上游调用者或数据来自 UART、网络还是其他模块。因此这不是已恢复的 UART 线上帧规范。
- HRI 的 `DGKEY_NUM_NDDIRECT` 有两处明确软件行为：值为 0 时，DigiPanel 显示 `Direct:OFF`，Y 正文候选偏移 5 写字符 `'1'`；值非 0 时显示 `Direct:ON`，正文写字符 `'2'`。没有证据证明这个布尔配置等同 FTX-1 的三态 Node Mode（AP RADIO / AP PC / DIRECT），也没有证明它关闭独立 VFO 的普通 RF 接收。
- 当前 Bridge 把候选 Y[5] 固定为 `'2'`，只与官方 `DGKEY_NUM_NDDIRECT` 非零时的字符编码相同。这个字节相同不能证明语义相同；不能据此声称 Bridge 正在选择电台 DIRECT 模式或关闭 RF。
- 用户已确认 FTX-1 Node Mode 为 DIRECT。145.1 MHz RF 音频在 Bridge 关闭后出现；S 表指示与该音频是否同一时刻尚未确认。Bridge 运行期间是否仍接收 RF 尚无结果；本轮没有读取或操作电台。
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

这个 key 的 `Direct:OFF/ON` 文本和 Y 字符映射只是在 HRI 软件内部彼此一致。FTX-1 手册第 29 页另列 AP RADIO、AP PC、DIRECT 三种 Node Mode，并描述 DIRECT 为经连接 PC 与 FTX-1 通信、不经空中发送/接收；默认模式为 AP RADIO。用户已确认电台当前 Node Mode 为 DIRECT，但静态代码没有证明 `DGKEY_NUM_NDDIRECT` 就是该三态 Node Mode 中的 DIRECT，也没有证明这个布尔字段控制普通 VFO 的 RF 接收。用户澄清，145.1 MHz RF 音频在 Bridge 关闭后出现；S 表指示与该音频的时间关系尚未确认。Bridge 运行期间是否仍接收 RF 尚无结果。

## `SetDigiTrcvData` 与语音队列边界

HRI `SetDigiTrcvData` 导出 `0x10001D00` 进入 `FUN_10001d20`，将输入交给对象的 `+0x1d8f8` 队列，再向该对象记录的线程 ID 投递 `0x1401`。R61 已确认 `0x1401` 处理器向状态分派器提交 event 1；它与 event `0x11` 是两个事件。旧 R60/R61 尚未连通队列与 UART；R77 补齐了对象索引和条件发送路径，细节见下节。原导出名本身不能确定电台 LCD 字段含义。

`RigDataIf.dll` 的 `ToHriAmbeAdd` / `ToHriAmbeGet` 是名为 AMBE 的字符串节点队列。HRI 内部 `FUN_10014600` 在 `+0x28f8 == 2` 时取一组 HRI AMBE 队列槽，在其他值时取另一组槽；未证明该字段等于 `DGKEY_NUM_NDDIRECT`，也未证明两路队列对应 AP/DIRECT、RF 接收或电台扬声器。队列布局和调用路径见 [`R62_RigDataIf队列消费与HRI绑定.md`](../../research/planning/R62_RigDataIf队列消费与HRI绑定.md) 及 REA `ev_7e3f0a…062091`、`ev_63dd0e…b7564e`、`ev_75021a…9bcb8a`。

S/T 控制路径另有 HRI 语音活动状态记录；已经看到的 `T3` 启播与 `T0` 收尾不能据此归类为 RF 节点模式切换，也不用于补足上面未闭合的 LCD 路径。

### R77：同一 HRI 对象到条件 UART 写入路径

R77 将 EXE 调用点、HRI 对象表、event 17 回调、HRI outgoing queue 和 EXE `WriteFile` 路径按证据连接。官方样本仍是 HRI-UART.dll SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed` 与 WIRES_X.EXE SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`。

1. **两个 EXE 调用都选择 HRI 对象表槽 0。** R22 的 `FUN_0040cf70` 调 `CreateDigiConnect` 时，第二个形式参数是常数 `0`（Evidence `ev_36c9dd5570469949787faaac6caa3cb0d2e5fe61f4b360b016db1aa1af4b822b`）。R51 的 `FUN_004e5580` 生成 D1–E4 等字段文本，然后调用表项 `+0x1c` 的 `SetDigiTrcvData(0, local_310)`（Evidence `ev_5a1c56f443db2913fbc51c4d24d7b930ea3e428f8a41e82b1f831a64e7118d8c`）。
2. **HRI 把两个 0 都用作同一全局表索引。** `CreateDigiConnect` 将第二个形式参数放入 ESI；`FUN_10001a40` 用该索引检查/写入 `DAT_10191d38[index]`，在新建对象后以该表项指针调用 `CWinThread::CreateThread`（R76 Evidence `ev_32e3c92a787db9ab6c6b7844f650fd743cbc38368ab93998fd98c3e3410d6f12`）。对象构造函数 `FUN_1000c3d0` 初始化 `this+0x1d8f8` 队列，并以同一 `this` 建状态表（Evidence `ev_247af966646237563f95176751203bca4db4c1a5da7a91873234c061f26603bd`）。`SetDigiTrcvData(int,char*)` 将第一个形式参数放入 ESI；其 helper `FUN_10001d20` 读取 `DAT_10191d38[index]`，向该对象 `+0x1d8f8` 队列添加记录（本轮 Evidence `ev_022b9112c799f2a464e512799a0f1aa59da66756905053fca08d1e1232de2b6b`、`ev_6a527e6e20f196148da00b15cd68f52d5f913453c3efc7aedff82c101e4a36e4`）。因为两个 EXE 调用的索引均为 0，静态代码把 producer 和线程对象连到 `DAT_10191d38[0]` 的同一实例。
3. **state 6/event `0x11` 是该对象队列的消费者。** 构造器将 event `0x11` 的回调登记为 `FUN_10017ee0`（R61 Evidence `ev_df7a82b059437d563de83ff1834d59c4cdc6846028d1e60851a9940ed8a4d0c2`）；该回调用 `param_1+0x1d8f8` 读取并在分支中摘出队首，随后按状态和记录条件调用 `FUN_1000aa40`。部分调用第三参数为 0，只格式化记录；一个 voice-frame 分支用第三参数 1，`FUN_1000aa40` 随后把内部 `F` 类型记录交给 outgoing queue `FUN_1000a140`（Evidence `ev_41dd62f0ba0e27eee32dc1c33bd25314f9ca62f9a933fd434341a2c6eac45d78`、`ev_3b65fb6614f18fcbf72824b4ab87211134c20722cc1b245cc8e061978083b9c0`、`ev_d2cb94ab9856ade391cafa317db90ee3e41483196e01938c10f962920b9e1785`）。
4. **outgoing queue 的一条路径把缓冲区和长度交给主程序，再到 `WriteFile`。** `FUN_1000a240` 取 outgoing queue 项目并对主程序窗口发送 `WM 0x618`，参数是记录缓冲区和长度（Evidence `ev_d655b4be6bd24449c7d460909fb95eb74c345ca85c26e342499d88757dac4967`）。EXE 的 `0x618` handler `FUN_00497b50` 调 `FUN_0040d260`，随后由 `FUN_0040f7e0` 将同一指针、长度传给 `WriteFile`（R8 Evidence `ev_b0aafad446c77fafe5688ec5b109f00275059ba97725657cec6ad39d60b3a61e`、`ev_04ee7da9fa2b802698348a29437077dde6f1ee9f1a5c5153e1affbf52d9d1f62`、`ev_6ab289bddeecbdb0bb70ba859d2d9238b403c368bcbe8ab3a51451f573216cca`）。这条 `0x618` 写入路径不会先经过 EXE 的另一条 `0x40c570` XOR 封装路径。

**R77 当时的缺口，已由 R78 部分闭合：** event `0x11` 通过 timer 2 / WM_TIMER / message `0x1411` 进入状态分派器的路径已恢复，具体见下一节。内部 `F` 记录和 EXE 的 D1–E4 输入字段仍没有 LCD 业务名称；静态证据没有把这些字节对应到 FTX-1 的呼号、房间/节点列表、软键文字或屏幕刷新动作。已恢复软件条件路径的输入、计时门控和 `WriteFile` 出口，尚未恢复设备端显示协议。

本轮新增 HRI 全量 REA bundle：[`r77_hri_lcd_chain_20261026.evidence.json`](../../research/rea/v2.010/r77_hri_lcd_chain_20261026.evidence.json)（target SHA 和每条 Evidence 记录均在 bundle 中）。它合并加载的 R61/R76 HRI 静态记录和本轮直接函数分析；EXE 侧 R22、R51、R8 证据仍引用各自完整 bundle。

### R78：timer 2 驱动 event `0x11`

R77 已闭合对象槽 0 和同一队列；R78 找到 state 6/event `0x11` 的调度链：

1. 状态分派器 `FUN_100152c0` 在旧状态 `<4`、新状态 `>3` 且新状态不等于 5 的转移分支，对 `this+0x2b8` 窗口设置 timer ID 2、周期 200 ms；该条件覆盖转入 state 6。另一个从更高状态转入 state 6 的分支调用 `FUN_1000ff40`，把 `this+0x1d8dc` 初始化为 2。证据 `ev_959e3cadf730233725fd198f64e03665147c07287cf542369f3ce6789afc74e8`。
2. HRI `.rdata` 的消息表记录 `0x10166288` 为 `WM_TIMER` (`0x0113`) 项，签名 `0x14`，处理器指针为 `FUN_10006a70` (`0x10006a70`)。该处理器在 timer ID 1 时向工作线程投递 `0x1401`；timer ID 2 时向同一对象记录的线程 ID 投递 `0x1411`。函数证据 `ev_e31bf97a49b8b34eaa68e3d35b7e6e651962c552153096b85c58b76db027f04d`，消息表原始字节证据 `ev_24e914bf2989ec98b281da805c8fe17380bdc1c8aef59c4745520855649cba66`。
3. HRI `.rdata` 中 `0x10167de8` 和 `0x10168410` 两条消息表记录均列出消息 `0x1411`、签名 `0x1e`、处理器地址 `0x10022d40`。地址 `0x10022d40` 的原始 64 字节证据为 `ev_92a8b5cbd2cdc941557312cd8a589796a36be63e5aabaa8d6318f5837951f3c6`；Ghidra 未把该地址单独登记成 procedure，因此本结论按消息表指针与原始代码字节复核。
4. `0x10022d40` 读取 `this+0x1d8dc`：计数为正时减 1 并返回；计数为 0 或负时，以 `param_1=0x11,param_2=0,param_3=0` 调用 `FUN_100152c0`。相对调用机器码 `E8 5E 25 FF FF` 位于 `0x10022D5D`，完整字节搜索证据 `ev_ee3b9ee46546a28375514e9d178125168f6ff2caad3d78033583ddecb5733c37`。
5. `SetDigiTrcvData(0, ...)` 路径将对象 `+0x1d8dc` 清零并投递 `0x1401`。所以在 timer 2 处于运行状态时，下一次 `0x1411` 处理可以通过计数门控进入 event `0x11`；随后 state 6 的 `FUN_10017ee0` 读取同一对象的 `+0x1d8f8` 队列，符合 R77 恢复的同实例数据流。

R78 的新证据并未观察任何实际定时器、线程或电台运行；它闭合的是官方代码中的消息表、计数器与状态分派调用关系。完整新增记录合并在 [`r78_hri_event11_timer_20261026.evidence.json`](../../research/rea/v2.010/r78_hri_event11_timer_20261026.evidence.json)。

## 显示 DMR 呼号的安全数据来源

当前 Bridge 的 `CallConfig` / `ReceiveEvent` 有远端 Source ID、目标 TG、时隙、CC 等，不含远端呼号或 TA 文本。远端呼号不能使用本机 `BI7KGD`、`USER_INF/CallSign` 或静态订阅值代替。

建议显示时先以当前通话的 Source ID 作身份主值；可选地按单个 ID 查询官方 RadioID 服务，并把结果标为外部映射及记录更新时间。缓存应带 TTL/检索时间，离线或无记录时继续显示数字 ID；不要把整份 Radio ID 目录镜像进便携包。call-start 建立远端身份，收到同一通话的补充资料时更新，call-end、断线或会话切换时清除临时身份。本机呼号始终作为本机资料单独显示。

## 下一步最小闭合条件

下一步只追 EXE `FUN_004e5580` 构造的 D1–E4 字段源对象和相关配置键，确认其中哪些承载呼号、节点或房间文字；再核对这些值如何经过 HRI 队列变成内部 F 记录。即便字段来源闭合，也需找到设备端 LCD 对字段的显示语义后才能实现 LCD 更新协议。当前没有为 LCD 构造或发送任何命令。

下一步分析官方会话启动和退出时配置的加载、保存与恢复行为，并确认 Bridge 运行期间 RF 接收状态。S 表指示与 Bridge 关闭后出现的 RF 音频是否同一时刻，仍需确认。若要发送新的 RF 模式写入命令，应先恢复该命令的协议和作用路径。本轮只做静态研究，没有进行这些观察或写入。
