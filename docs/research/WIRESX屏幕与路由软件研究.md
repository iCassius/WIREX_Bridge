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

REA 静态分析使用 Ghidra 12.1.4 x86。三份官方文件均与外层 `research/inputs/v2.010/payload/` 中已校验的同名样本具有相同 SHA-256。新增证据摘要在 [`r71_hri_screen_route_followup_20261025.json`](../../../research/rea/v2.010/r71_hri_screen_route_followup_20261025.json)。本轮尝试从 REA 会话导出全量证据时，`get_evidence_bundle` 返回 0 条保留记录，因此 R71 JSON 仅是摘要，不能代替完整反编译。完整的 `FUN_10023eb0` 分析已保存在 [`r31_usb_branch_evidence_bundle.json`](../../../research/rea/v2.010/r31_usb_branch_evidence_bundle.json)，Evidence `ev_01d61fb7cb4474099c6b033fac4464466ccef9e2d3bf36ad936a95d9f54c77dd`，覆盖函数 3,007 字节并包含伪代码、汇编和限制说明。EXE 字段记录在 [`wiresx-exe-ui-followups-20261025.evidence.json`](../../../research/rea/v2.010/wiresx-exe-ui-followups-20261025.evidence.json)。

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

关键偏移与代码路径见 HRI REA `ev_b79c7e…db0d65d2`、`ev_872f684…9878c888`，以及外层 [`R14_HRI初始化与模式状态.md`](../../../research/planning/R14_HRI初始化与模式状态.md)。这些是 HRI 配置载入事实，不证明字段会发到电台屏幕或远端节点列表。

### HRI 自己的 DigiPanel

HRI 构造函数 `FUN_1000c3d0` 创建资源 ID `0xF3` 的 `CDigiPanelDlg`；`FUN_10007b40` 从 `DGRP_VOICE` 或 `DGRP_DATA` 读取频率、接收/发射参数等，并刷新该面板。它读取 `DGKEY_NUM_NDDIRECT`，按零/非零选择 `Direct:OFF` 或 `Direct:ON`，再把文本交给 `FUN_1002a8f0`。后者在直达分支调用 `SetDlgItemTextA(hwnd, control_id, text)`，控件 ID 为 `0x671`。

这闭合的是 PC 端 HRI DigiPanel 的文本控件更新。窗口创建、窗口类与模式标签证据见 `ev_419922…e453e758c`、`ev_5057df…ba022ab`、`ev_0111c3…00a32bef`；直接字符串引用见 `ev_ac9fa6…4f79d28b`。不要把该控件当成 FTX-1 LCD。

## HRI 文本字段解析与模式响应

### `FrameTrxDataToTrcvFrame`

HRI 导出 `FrameTrxDataToTrcvFrame` 位于 VA `0x100020B0`，导出 ordinal 31。REA 反编译 `ev_282fad…47bc2cfe` 显示它调用 `UdpComFuncs.dll!CutOutString`，再按稀疏字段码 `C0–C5`、`D1–D8`、`DA–DD`、`DE–E1`、`E3–E6` 写入 `param_2` 结构。`CutOutString` 把前两位 ASCII 十六进制字符解为字段码，后两位解为字符数，再复制后续字符；完整复核见 [`R10_HRI语音文本与载荷.md`](../../../research/planning/R10_HRI语音文本与载荷.md)。

例如，`C0` 与 `C1–C5` 会向 `param_2+0x87` 拼接文本；`DA–DD` 分别写入四个最多 10 字节、先以空格填充的区域；`DE–E1` 分别写入四个最多 5 字节的区域。这些偏移没有已验证的业务名称。该导出在 DLL 内没有已解析直接调用者，未确认其输入来自串口、网络或其他模块，也未把其输出连到 FTX-1 显示器。

### 模式响应更新的是 HRI 配置与 PC 面板

HRI 内部通用分派 `FUN_10022730` 按字符类型把 `M`/`W` 送到 `FUN_10022fe0`，把 `X` 送到 `FUN_10023eb0`。`FUN_10022fe0` 将 `param_1+1+iVar4` 处的四个 ASCII 十六进制字符解成长度值；可见接受值为 `0x43`、`0x45`、`0x6B`、`0x48`。`0x48` 分支会校验若干配置值；`DGKEY_NUM_NDDIRECT` 只接受 ASCII `'0'` 或 `'1'`，写回当前 HRI 配置组，然后调用 `FUN_10007b40` 刷新 DigiPanel。`FUN_10023eb0` 的 `X` 分支也把 `local_15f` 限定为 ASCII `'0'`/`'1'` 后写入同一配置键；X 入口输入是否来自 UART 仍未知。

这证明 HRI DLL 内有接收解析候选、配置值校验和 PC 面板刷新，不证明 `M`、`W`、`X` 是 UART 线上命令类型或这些消息由电台屏幕产生。R57 的既有静态字段恢复将 X 配置处理函数 `FUN_10023eb0` 检查的 `local_15f` 定位到 100 字节正文偏移 `0x05`；结合 R49 已记录的 6 字节 parser 前缀，对应完整记录偏移 `0x0B`。X 输入是否来自 UART 仍未知。对应 REA 记录为 `ev_e85c52…2806ca2`、`ev_ed6ea7…b5fec7`、`ev_ae4eeb…c49c812` 和调用者记录 `ev_0db3c3…87acffe`，字段表见 [`R57_X配置接收字段与只读校验.md`](../../../research/planning/R57_X配置接收字段与只读校验.md)。

### DIRECT 配置与 100 字节 Y 正文候选

HRI `FUN_1000cc80` 将 `DGKEY_NUM_NDDIRECT` 注册到配置接口，传入参数 `(1,1)`；配置接口的函数实现不在该 DLL 内，不能据这两个参数推导初值或三态模式含义。

`CDigiPanelDlg` 的 Y 正文候选处理函数 `FUN_100095c0` 先将目的区域填为 100 个 ASCII `'0'`，再调用 getter 读取 **`DGKEY_NUM_NDDIRECT`**：零值写到偏移 `0x05` 的字符为 `'1'`，非零值为 `'2'`。这部分由 REA `ev_e7404…791c2c4` 直接确认。HRI 的消息表将 `0x1435` 指向该 handler，消息表属于 `CDigiPanelDlg`；R36 仍未闭合发送侧 HWND 与实际接收窗口实例，也未证明该正文最终进入串口或被电台 LCD 显示。见 [`R34_Y正文生成函数与字段表.md`](../../../research/planning/R34_Y正文生成函数与字段表.md) 和 [`R36_Y消息表与发送窗口关联.md`](../../../research/planning/R36_Y消息表与发送窗口关联.md)。

这个 key 的 `Direct:OFF/ON` 文本和 Y 字符映射只是在 HRI 软件内部彼此一致。FTX-1 手册第 29 页另列 AP RADIO、AP PC、DIRECT 三种 Node Mode，并描述 DIRECT 为经连接 PC 与 FTX-1 通信、不经空中发送/接收；默认模式为 AP RADIO。用户已确认电台当前 Node Mode 为 DIRECT，但静态代码没有证明 `DGKEY_NUM_NDDIRECT` 就是该三态 Node Mode 中的 DIRECT，也没有证明这个布尔字段控制普通 VFO 的 RF 接收。用户澄清，145.1 MHz RF 音频在 Bridge 关闭后出现；S 表指示与该音频的时间关系尚未确认。Bridge 运行期间是否仍接收 RF 尚无结果。

## `SetDigiTrcvData` 与语音队列边界

HRI `SetDigiTrcvData` 导出 `0x10001D00` 进入 `FUN_10001d20`，将输入交给对象的 `+0x1d8f8` 队列，再向该对象记录的线程 ID 投递 `0x1401`。R61 已确认 `0x1401` 处理器向状态分派器提交 event 1；它与 event `0x11` 是两个事件。旧 R60/R61 尚未连通队列与 UART；R77 补齐了对象索引和条件发送路径，细节见下节。原导出名本身不能确定电台 LCD 字段含义。

`RigDataIf.dll` 的 `ToHriAmbeAdd` / `ToHriAmbeGet` 是名为 AMBE 的字符串节点队列。HRI 内部 `FUN_10014600` 在 `+0x28f8 == 2` 时取一组 HRI AMBE 队列槽，在其他值时取另一组槽；未证明该字段等于 `DGKEY_NUM_NDDIRECT`，也未证明两路队列对应 AP/DIRECT、RF 接收或电台扬声器。队列布局和调用路径见 [`R62_RigDataIf队列消费与HRI绑定.md`](../../../research/planning/R62_RigDataIf队列消费与HRI绑定.md) 及 REA `ev_7e3f0a…062091`、`ev_63dd0e…b7564e`、`ev_75021a…9bcb8a`。

S/T 控制路径另有 HRI 语音活动状态记录；已经看到的 `T3` 启播与 `T0` 收尾不能据此归类为 RF 节点模式切换，也不用于补足上面未闭合的 LCD 路径。

### R77：同一 HRI 对象到条件 UART 写入路径

R77 将 EXE 调用点、HRI 对象表、event 17 回调、HRI outgoing queue 和 EXE `WriteFile` 路径按证据连接。官方样本仍是 HRI-UART.dll SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed` 与 WIRES_X.EXE SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`。

1. **两个 EXE 调用都选择 HRI 对象表槽 0。** R22 的 `FUN_0040cf70` 调 `CreateDigiConnect` 时，第二个形式参数是常数 `0`（Evidence `ev_36c9dd5570469949787faaac6caa3cb0d2e5fe61f4b360b016db1aa1af4b822b`）。R51 的 `FUN_004e5580` 生成 D1–E4 等字段文本，然后调用表项 `+0x1c` 的 `SetDigiTrcvData(0, local_310)`（Evidence `ev_5a1c56f443db2913fbc51c4d24d7b930ea3e428f8a41e82b1f831a64e7118d8c`）。
2. **HRI 把两个 0 都用作同一全局表索引。** `CreateDigiConnect` 将第二个形式参数放入 ESI；`FUN_10001a40` 用该索引检查/写入 `DAT_10191d38[index]`，在新建对象后以该表项指针调用 `CWinThread::CreateThread`（R76 Evidence `ev_32e3c92a787db9ab6c6b7844f650fd743cbc38368ab93998fd98c3e3410d6f12`）。对象构造函数 `FUN_1000c3d0` 初始化 `this+0x1d8f8` 队列，并以同一 `this` 建状态表（Evidence `ev_247af966646237563f95176751203bca4db4c1a5da7a91873234c061f26603bd`）。`SetDigiTrcvData(int,char*)` 将第一个形式参数放入 ESI；其 helper `FUN_10001d20` 读取 `DAT_10191d38[index]`，向该对象 `+0x1d8f8` 队列添加记录（本轮 Evidence `ev_022b9112c799f2a464e512799a0f1aa59da66756905053fca08d1e1232de2b6b`、`ev_6a527e6e20f196148da00b15cd68f52d5f913453c3efc7aedff82c101e4a36e4`）。因为两个 EXE 调用的索引均为 0，静态代码把 producer 和线程对象连到 `DAT_10191d38[0]` 的同一实例。
3. **state 6/event `0x11` 是该对象队列的消费者。** 构造器将 event `0x11` 的回调登记为 `FUN_10017ee0`（R61 Evidence `ev_df7a82b059437d563de83ff1834d59c4cdc6846028d1e60851a9940ed8a4d0c2`）；该回调用 `param_1+0x1d8f8` 读取并在分支中摘出队首，随后按状态和记录条件调用 `FUN_1000aa40`。部分调用第三参数为 0，只格式化记录；一个 voice-frame 分支用第三参数 1，`FUN_1000aa40` 随后把内部 `F` 类型记录交给 outgoing queue `FUN_1000a140`（Evidence `ev_41dd62f0ba0e27eee32dc1c33bd25314f9ca62f9a933fd434341a2c6eac45d78`、`ev_3b65fb6614f18fcbf72824b4ab87211134c20722cc1b245cc8e061978083b9c0`、`ev_d2cb94ab9856ade391cafa317db90ee3e41483196e01938c10f962920b9e1785`）。
4. **outgoing queue 的一条路径把缓冲区和长度交给主程序，再到 `WriteFile`。** `FUN_1000a240` 取 outgoing queue 项目并对主程序窗口发送 `WM 0x618`，参数是记录缓冲区和长度（Evidence `ev_d655b4be6bd24449c7d460909fb95eb74c345ca85c26e342499d88757dac4967`）。EXE 的 `0x618` handler `FUN_00497b50` 调 `FUN_0040d260`，随后由 `FUN_0040f7e0` 将同一指针、长度传给 `WriteFile`（R8 Evidence `ev_b0aafad446c77fafe5688ec5b109f00275059ba97725657cec6ad39d60b3a61e`、`ev_04ee7da9fa2b802698348a29437077dde6f1ee9f1a5c5153e1affbf52d9d1f62`、`ev_6ab289bddeecbdb0bb70ba859d2d9238b403c368bcbe8ab3a51451f573216cca`）。这条 `0x618` 写入路径不会先经过 EXE 的另一条 `0x40c570` XOR 封装路径。

**R77 当时的缺口，已由 R78 部分闭合：** event `0x11` 通过 timer 2 / WM_TIMER / message `0x1411` 进入状态分派器的路径已恢复，具体见下一节。内部 `F` 记录和 EXE 的 D1–E4 输入字段仍没有 LCD 业务名称；静态证据没有把这些字节对应到 FTX-1 的呼号、房间/节点列表、软键文字或屏幕刷新动作。已恢复软件条件路径的输入、计时门控和 `WriteFile` 出口，尚未恢复设备端显示协议。

本轮新增 HRI 全量 REA bundle：[`r77_hri_lcd_chain_20261026.evidence.json`](../../../research/rea/v2.010/r77_hri_lcd_chain_20261026.evidence.json)（target SHA 和每条 Evidence 记录均在 bundle 中）。它合并加载的 R61/R76 HRI 静态记录和本轮直接函数分析；EXE 侧 R22、R51、R8 证据仍引用各自完整 bundle。

### R78：timer 2 驱动 event `0x11`

R77 已闭合对象槽 0 和同一队列；R78 找到 state 6/event `0x11` 的调度链：

1. 状态分派器 `FUN_100152c0` 在旧状态 `<4`、新状态 `>3` 且新状态不等于 5 的转移分支，对 `this+0x2b8` 窗口设置 timer ID 2、周期 200 ms；该条件覆盖转入 state 6。另一个从更高状态转入 state 6 的分支调用 `FUN_1000ff40`，把 `this+0x1d8dc` 初始化为 2。证据 `ev_959e3cadf730233725fd198f64e03665147c07287cf542369f3ce6789afc74e8`。
2. HRI `.rdata` 的消息表记录 `0x10166288` 为 `WM_TIMER` (`0x0113`) 项，签名 `0x14`，处理器指针为 `FUN_10006a70` (`0x10006a70`)。该处理器在 timer ID 1 时向工作线程投递 `0x1401`；timer ID 2 时向同一对象记录的线程 ID 投递 `0x1411`。函数证据 `ev_e31bf97a49b8b34eaa68e3d35b7e6e651962c552153096b85c58b76db027f04d`，消息表原始字节证据 `ev_24e914bf2989ec98b281da805c8fe17380bdc1c8aef59c4745520855649cba66`。
3. HRI `.rdata` 中 `0x10167de8` 和 `0x10168410` 两条消息表记录均列出消息 `0x1411`、签名 `0x1e`、处理器地址 `0x10022d40`。地址 `0x10022d40` 的原始 64 字节证据为 `ev_92a8b5cbd2cdc941557312cd8a589796a36be63e5aabaa8d6318f5837951f3c6`；Ghidra 未把该地址单独登记成 procedure，因此本结论按消息表指针与原始代码字节复核。
4. `0x10022d40` 读取 `this+0x1d8dc`：计数为正时减 1 并返回；计数为 0 或负时，以 `param_1=0x11,param_2=0,param_3=0` 调用 `FUN_100152c0`。相对调用机器码 `E8 5E 25 FF FF` 位于 `0x10022D5D`，完整字节搜索证据 `ev_ee3b9ee46546a28375514e9d178125168f6ff2caad3d78033583ddecb5733c37`。
5. `SetDigiTrcvData(0, ...)` 路径将对象 `+0x1d8dc` 清零并投递 `0x1401`。所以在 timer 2 处于运行状态时，下一次 `0x1411` 处理可以通过计数门控进入 event `0x11`；随后 state 6 的 `FUN_10017ee0` 读取同一对象的 `+0x1d8f8` 队列，符合 R77 恢复的同实例数据流。

R78 的新证据并未观察任何实际定时器、线程或电台运行；它闭合的是官方代码中的消息表、计数器与状态分派调用关系。完整新增记录合并在 [`r78_hri_event11_timer_20261026.evidence.json`](../../../research/rea/v2.010/r78_hri_event11_timer_20261026.evidence.json)。

### R79：EXE D/E 字段中的本机身份来源

本轮继续检查官方 `WIRES_X.EXE` 2.0.1.0，SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`。在 `FUN_004e5580` 中，程序从全局缓冲区复制 `DAT_02f1c7ee` 到 `local_3c`，调用 `FUN_004b38d0` 处理后，再用 `EditLenString` 填入 D/E 字段。结合配置加载函数 `FUN_004bdb50`，可确认其中四个字段与本机资料键的关系：这些是本机 WIRES-X 身份资料，不能用来标记 BrandMeister 当前远端发话者。Bridge 的远端身份仍应取当前接收事件的 DMR Source ID。

| `FUN_004e5580` 字段 | 输入来源 | `FUN_004bdb50` 的配置加载 | 结论范围 |
| --- | --- | --- | --- |
| `DB` | `DAT_02f1c7c4` | `USER_INF/ID_No` | 本机资料中的 User ID/编号文本 |
| `DC` | `DAT_02f1c800` | `USER_INF/CallSign` | 本机呼号文本 |
| `DE` | `local_3c` | `USER_INF/User_RadioID` → `DAT_02f1c7ee` | 默认来自本机 Radio ID；另一个分支可用 `this+0x1b5c8+0x12f` 的字符串覆盖，具体分支条件见完整函数证据 |
| `E1` | `local_3c` | `USER_INF/User_RadioID` → `DAT_02f1c7ee` | 本机 Radio ID 经 `FUN_004b38d0` 处理后的文本 |

`FUN_004bdb50` 还读取 `USER_INF/SvNodeID` 和 `CONF_ROOM/Conf_RadioID`（分别存入 `DAT_02f1c7d9`、`DAT_02f1ceaa`），但本轮在 `FUN_004e5580` 中没有找到它们直接进入 `DD`、`DE` 或其他 D/E 字段的证据。不要把这些配置键直接标成 FTX-1 的当前节点或房间显示值。

`FUN_004b38d0` 的可见处理是：输入最多取 7 个字符；若内容全为十进制数字，数值小于 100000 时格式化为 5 位十进制文本；数值在 1000000 到 `1000000+0x834e0` 范围时，减去 1000000 后按 `0123456789ABCD` 字符表拆成 5 位文本；其他输入不会覆盖调用方缓冲区的转换结果。加载路径中的 `FUN_004b3350` 则把允许的 5 位 `0123456789ABCD` 文本转换成 7 位十进制文本；不足 5 位时先左侧补零。6 位输入以 `0` 开头时会先去掉该字符，再按 5 位格式处理；不以 `0` 开头的 6 位输入走十进制校验和解析。这说明程序对 `User_RadioID` 做格式转换；这些函数没有给出 FTX-1 LCD 的字段语义。

其余字段仍有明确来源缺口：`D7` 来自全局 `DAT_007bff04`，本轮没有追到该全局的配置键；`DD` 来自 `this+0x1b5c8+0x11a`，所属对象及字段名未识别；`DE` 可被同一对象的 `+0x12f` 字符串覆盖；`E3` 由表项 `+0x38` 的函数指针填写，`E4` 的 `pcVar11` 来源还未映射。`D1`、`D2`、`D4`–`D6` 是固定短文本，`D3` 根据 `TRANSV1/TrcvKind` 是否为 1 选择字符 `2` 或 `0`，`DA` 传入固定十个星号。没有证据把这些值命名为远端节点名、房间名、呼号列表或 LCD 控件内容。

新增 EXE Evidence：`FUN_004e5580` 为 `ev_5131b0c70d73a5f6b72c69e23fb4ff735ce3e5d673ac8d5c9bd16a32e39d8ef9`；`FUN_004bdb50` 为 `ev_69c0d7a75eeb03b5c49eed4754457f21bde1e9eea5b38a659ed5a88df7b9afa9`；`FUN_004b38d0` 为 `ev_459b683155f93cac683fe76c8ba0738df62dd045d310b7ae8ec8113059e2ca53`；`FUN_004b3350` 为 `ev_199862d7adfbb45f0ef5d253a87f59d9951043c7e67809eaa5fc513920075727`。完整 EXE 会话证据包位于 [`r79_exe_hri_identity_fields_20261026.evidence.json`](../../../research/rea/v2.010/r79_exe_hri_identity_fields_20261026.evidence.json)。`FUN_004184f0` 的配置写入侧记录仍见既有 Evidence `ev_682a085bde8acbeda5e36bb8b31c3d2d73bf6bc7a1552b0eb50864813298aba8`。

## R82：68 字符呼叫头进入 T 记录的静态路径

本轮使用 HRI-UART.dll 2.0.1.0，SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed`。REA Ghidra 12.1.4 x86 全量证据包为 [`r82_hri_t_header_callsign_20261026.evidence.json`](../../../research/rea/v2.010/r82_hri_t_header_callsign_20261026.evidence.json)；bundle 包含本节引用的函数伪代码、汇编和目标身份。

### 头缓冲区来源和呼号字段

`FUN_10017ee0` 在处理状态事件时先清空 `this+0x1420`。处理 HRI 的 `G` 帧时，`FUN_10014330` 从输入记录 `param_3+9` 复制连续 68 个字节到 `this+0x1420`，再改写若干控制字符。这个 68 字节区就是后续 T 记录复用的头部，而不是 R79 的本机 `USER_INF` 文本。Evidence `ev_dd4741e6a283be5d7a5c88c8e35f4a98f22825de30ac56f6d3e015d8ee702ad9`。

R83 追到 `FUN_10014330` 的两个直接调用者 `FUN_10014600`、`FUN_10014dd0`。它们从对象 `+0x1d8ec` 的虚函数槽取记录，查看记录 `+4` 的类型字符；遇到 `'G'` 时调用 `FUN_10014330`，并把返回块送入后续 AMBE 处理。调用者会同时读取 `'H'`、`'R'`、`'E'` 和其他类型记录，但这只确认了 HRI 内部数据源到头部解析器的路径。当前静态证据没有解析 `+0x1d8ec` 虚函数实现的上游数据来源，因此还不能把这个头部判为来自 BM、宿主身份配置或电台接收内容。直接调用者列表为 R83 Evidence `ev_f3e1c57ea4cca311d67fe7c3a95e36350a930b58d9caee8530c44155fb9ae0d9`，两个调用循环分别见 `ev_21b36e37a883e46e15a6f0a4e6713d46f1347d0a6528dbbac0a305b4fb74e872` 与 `ev_e0eaf1ab2302ef45109d91a9cda53cd175c911718409b7dc5f66a0ff0f138d2e`。

`FUN_10014070` 处理该头部时，从相对偏移 `+8` 与 `+0x12` 各读取 10 个字符，并按日志字段 `DestCallSign` 和 `Src CallSign` 保存到对象 `+0x28cf` 与 `+0x28c4`。它检查字段首字符大于空格后才更新缓存；因此字段长度和缓冲偏移有代码证据，但空白/数字填充、显示格式及其最终 LCD 含义尚未完全验证。Evidence `ev_af377ccbc045e89e9964c53d4ab86c39d7534f358fda167ec8bf64bfc7435d28`。

本机 HRI 配置也有一个单独的呼号槽。`FUN_1000d370` 从 `DGRP_COMMON/DGKEY_STR_CALL_SIGN` 读取文本，经 `StrFixSizeCopy` 保存到对象 `+0x322`；`FUN_10014330` 再把 10 字节复制到头部相对偏移 `+0x1c`（对象 `+0x143c`）。头部因此包含不同位置的目的呼号 `+8`、源呼号 `+0x12` 和 HRI 本机呼号 `+0x1c`。这只确认了配置到 HRI 缓冲区的复制关系；它没有证明 `DGKEY_STR_CALL_SIGN` 与 EXE 的 `USER_INF/CallSign` 是同一配置来源，也没有证明 `+0x1c` 在电台 LCD 上的呈现方式。`FUN_1000d370` 的完整静态记录为 R14 Evidence `ev_872f6848966086fe1393376f10eb179c48305a1cb4bb8a541d52f14b9878c888`；头部复制位置见本节 R82 Evidence `ev_dd4741e6a283be5d7a5c88c8e35f4a98f22825de30ac56f6d3e015d8ee702ad9`。

同一配置函数还从 `DGRP_COMMON/DGKEY_STR_NODE_RADIO_ID` 读取本机 Node Radio ID。输入长度正好为 5 时，HRI 原样复制到对象 `+0x2f9`；其他非负长度会交给 `FUN_1000f660`，该函数对纯十进制文本作格式转换：小于 100000 时写为 5 位十进制文本；在 1000000 到 `1000000+0x834e0` 范围时按 `0123456789ABCD` 字符表编码为 5 位。`FUN_10014330` 把对象 `+0x2f9` 的 5 字节复制到头部 `+0x30`。`FUN_1000f7e0` 会依据对象 `+0x1d900` 的转换模式选择 `FUN_1000f660`、`FUN_1000f4e0` 或 `FUN_1000f2d0`；当前没有把该模式映射到电台 Node Mode 的证据。函数证据见 R14 `ev_872f6848966086fe1393376f10eb179c48305a1cb8a541d52f14b9878c888` 与本轮 R83 的 `ev_e5ea93510aac680beb57e163f5abf9ebec9b22fbd8c1bd3fca6328630a1047e`、`ev_848f27e53e6881e3629cc52e26242b1b1356f2a57745cc50f9e60d3140504f3b`。R83 全量证据包为 [`r83_hri_header_identity_conversion_20261026.evidence.json`](../../../research/rea/v2.010/r83_hri_header_identity_conversion_20261026.evidence.json)（43 条记录，目标 SHA 与函数内容均在包内）。这 5 字节是本机 Node Radio ID 编码字段；不能据此把 BrandMeister DMR Source ID 直接转成 WIRES-X 呼号。

`FUN_1000bee0` 另把队列节点的 68 字节头复制到 scratch `+8`，并把头部相对偏移 `+4` 固定为 ASCII `'1'`。它按记录标志保留后续正文原字节或从 ASCII HEX 解码，在正文前另加入 3 个记录字节，再追加 `0x03`；输出时将这一段逐字节编码为 ASCII HEX，并对整段（包括 `0x03`）求低 8 位和作为两位 HEX 校验值。非空 T 路径由 `FUN_1000adb0` 处理 AMBE 二进制块：它也按字节转 ASCII HEX，追加 `03`，再对该块与 `0x03` 的和取低 8 位作为校验值。两段代码分别提供头部/记录边界和语音块尾部格式的静态证据，没有把这些字段接到某个 LCD 控件。`FUN_1000adb0` 记录为 R83 Evidence `ev_130fa47a6bbaa0c2b88fa89cbd51d4005c8f482ddc51ac167ddb5417e2b61739`，`FUN_1000bee0` 记录为 R82 Evidence `ev_3ca4f025b37919a32d0df5dad3ece722ff905e56d06ef89cd0fc8b3920579047`。

### T 记录的内部正文与条件写入路径

`FUN_10014b50` 的非空头分支从 `this+0x1420` 复制 68 字节到 T 正文偏移 `+7`。随后它写的是 T 正文绝对偏移 `0x0b`，也就是68字节头内部相对偏移 `+4`：将该字节低两位加 ASCII `'0'`。函数随后附加 AMBE 文本或空帧占位、五个星号和结尾字段，再调用 `FUN_1000b130` 建立类型 `'T'` 的队列记录。空头分支生成固定的 68 字节默认头；当前 Bridge 的 90 字节模板只实现了该空头、空 AMBE 数据候选。Evidence `ev_0b9ed8732ace5fbca14b93278f85c286ae2354053325a9da2b7c36b1e0c320b4` 和 `ev_a7403527ad5f9eaab9f38ff1a63fdbbf87e569244700d4f2384c3d427c833851`。

`FUN_1000b130` 以内部记录类型 `'T'` 建项，把 `FUN_10014b50` 生成的正文复制到该项，再交给公共队列。R77 已恢复该队列的一条条件路径：队首内容经 EXE 窗口消息 `0x618` 传到 `WriteFile`。相关 HRI Evidence 为 `ev_d655b4be6bd24449c7d460909fb95eb74c345ca85c26e342499d88757dac4967`；EXE 下游 Evidence 为 `ev_b0aafad446c77fafe5688ec5b109f00275059ba97725657cec6ad39d60b3a61e`、`ev_04ee7da9fa2b802698348a29437077dde6f1ee9f1a5c5153e1affbf52d9d1f62`、`ev_6ab289bddeecbdb0bb70ba859d2d9238b403c368bcbe8ab3a51451f573216cca`。静态链没有把每一种 `'T'` 内部项连接到所选 COM/USB 外层 serializer，也没有观察实际 `WriteFile` 成功或 FTX-1 LCD 显示。

`FUN_10013720` 是另一条 `this+0x1420` 写入路径：它向宿主窗口请求下一块数据后，把返回的原始字节交给 `FUN_100139f0`。后者将每个字节编码为大写 ASCII HEX，累加原始字节的低 8 位和，再追加 ASCII `03` 与 `HEX((sum + 3) mod 256)`。`FUN_10013720` 将这段文本追加到 `+0x1420` 后；非空头 T 构造随后会把 68 字节头之后已有的尾文本放到五个星号之后。R85 的 `ev_6eb636b3122b4ba2468e254b69150a3d8755dc68b2dd0a2b162e86c0b2e6a7a9` 记录 `FUN_100139f0`；R82 的 `ev_108646d7e00c6085f50e947ba0e8e6a4fdc9d97fc116d502d6a1c6428d95a92b` 与 `ev_998396d42019961c53dd6d500ad49bbf7dbdd12cc7b2168931fb53893a836b5d` 记录 `FUN_10013720`、`FUN_1001e1c0`。这些函数没有从 R79 的本机 `CallSign`、`ID_No`、`User_RadioID` 读取远端发话者身份。

### R84/R85：非空 T 正文和尾文本

HRI-UART.dll 目标仍为 SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed`。`FUN_10014b50` 从输入文本第 1 至第 4 位读取四位 HEX 计数，再减 1；复制的数据从输入偏移 `+6` 开始。计数字段只用于长度验证，不会复制到输出；有效 mode 的正文从偏移 `0x4b` 开始放载荷。根据复制头部 `+4` 低两位形成的模式字符，函数只接受以下“复制文本字符数 / 输入计数字段”组合：`0` 为 `96 / 0061`，`2` 为 `136 / 0089`，`3` 为 `186 / 00BB`。字符 `1` 的非空分支报告 `DataOnlyData has AMBE RAW` 并丢弃该长度。DLL 只检查计数和长度，没有验证数据字符是不是 HEX；新纯模块为避免构造畸形正文，还额外要求内容只含 ASCII HEX，并拒绝不支持的 mode 1。若长度非正，反编译显示另一分支在 `+0x4b` 写入固定 `00001F`；通过的非空 mode 0/2/3 不走这条占位分支。

生成的 T 正文前 7 字符分别来自状态选择值、全局 `DAT_10167c4c` 的 4 字节、`DAT_10167c50` 的 1 字节和固定 ASCII `'0'`。前 5 个字段的运行值/业务意义尚未恢复，所以纯模块要求调用方显式提供 7 字符前缀，只校验 ASCII、首字符范围和末位固定字符，不命名未知字段。随后复制 68 字节头；只在输出副本中把头偏移 `+4` 改为模式字符，形成正文绝对偏移 `0x0b`。原头其它 67 字节保持不变。数据文本后附五个星号，再附加上游已写入 `+0x1420` 的头部尾文本。

纯模块 `include/wirex/hri_t_record.hpp` / `src/hri_t_record.cpp` 只构造上述内部 T 文本正文，并提供与 `FUN_100139f0` 一致的 raw-tail HEX、ASCII `03`、sum8-plus-3 helper。它不添加 Direct/COM 或 USB 外层帧封装。C 的 R31 证据恢复了特定外层 vtable serializer，但尚未证明 HRI T 项在所有设备类型上都调用该 serializer；因此本模块没有自行追加第二个终止符或校验。模式、计数和尾部的离线边界样例位于 `tests/hri_t_record_test.cpp`，使用合成字符/字节，不是电台捕获，也没有发送到设备。原 `build_empty_header_empty_ambe_candidate_body` 的 90 字节 mode `'4'` PCM 候选保持不变。

R84 全量 bundle 为 [`r84_hri_t_mode_payload_chain_20261026.evidence.json`](../../../research/rea/v2.010/r84_hri_t_mode_payload_chain_20261026.evidence.json)；R85 补充尾文本函数，见 [`r85_hri_host_to_t_trailer_20261026.evidence.json`](../../../research/rea/v2.010/r85_hri_host_to_t_trailer_20261026.evidence.json)。R84/R85 保留了目标 DLL 身份和完整函数反编译；文档中的 YSF 布局比较仍是候选，不能据 `96/136/186` 长度宣布 HRI 与 YSF payload 兼容。

### 当前可以实现与仍未知的范围

已新增纯解析模块 `include/wirex/hri_call_header.hpp` / `src/hri_call_header.cpp`：它要求输入恰为 68 个非 NUL ASCII 字节，提供目的、源、HRI 本机呼号字段的 10 字符读取与替换，并可计算非空 T 路径在头部偏移 4 的 mode 字符。模块保留所有未解释的 ASCII 字节；替换字段要求调用方已经提供准确的 10 字符文本，不会把 DMR 数字 ID 转成 WIRES-X 呼号。新模块 `include/wirex/hri_t_record.hpp` / `src/hri_t_record.cpp` 依据 R84/R85 构造非空头部的内部 T 正文，并编码上游 raw 尾块；外层 COM/USB 传输帧仍未实现。离线测试 `tests/hri_call_header_test.cpp` 与 `tests/hri_t_record_test.cpp` 覆盖头部字段、mode/count组合、HEX和长度拒绝、原头保留、尾部 `03+sum8`，以及旧空头候选。

旧空头 90 字节 mode `'4'` 候选保持独立，没有拿它充当带呼号头部的模式。新 T 模块构造内部正文，不接 BM call-start/end 事件，不写 COM、不生成 USB 命令，也没有证明 FTX-1 接受或显示该正文。

这些静态链只说明软件把头部送入 UART 写入路径。它没有证明 FTX-1 LCD 会把两个字段显示在何处、是否需要设备侧响应或额外事件，也没有证明任意手工拼出的头部会被电台接受。当前 DMR `CallConfig`/`ReceiveEvent` 只有远端 DMR Source ID，没有呼号/TA 文本；从 DMR ID 到合法的 10 字符 Source CallSign 仍需要经核实的映射来源。没有进行官方程序启动、DLL 加载、串口或电台测试，也没有生成或发送新的 LCD 命令。

## 显示 DMR 呼号的安全数据来源

当前 Bridge 的 `CallConfig` / `ReceiveEvent` 有远端 Source ID、目标 TG、时隙、CC 等，不含远端呼号或 TA 文本。远端呼号不能使用本机 `N0CALL`、`USER_INF/CallSign` 或静态订阅值代替。

建议显示时先以当前通话的 Source ID 作身份主值；可选地按单个 ID 查询官方 RadioID 服务，并把结果标为外部映射及记录更新时间。缓存应带 TTL/检索时间，离线或无记录时继续显示数字 ID；不要把整份 Radio ID 目录镜像进便携包。call-start 建立远端身份，收到同一通话的补充资料时更新，call-end、断线或会话切换时清除临时身份。本机呼号始终作为本机资料单独显示。

## 接入 BM 来话 LCD 前的具体缺口

1. Bridge 有 DMR `Source ID` 和 `TG`，但 T 头的源呼号偏移 `+0x12` 是固定 10 字节的 `Src CallSign` 区。当前没有把 DMR Source ID 转成合法 WIRES-X 呼号的已验证来源。应用可先保留数值 Source ID 作自身状态；只有单 ID 查询或 DMR Talker Alias 的来源/编码经核实后，才可填入这 10 字节。不能把 DMR 数字 ID 直接写进该呼号区。
2. T 头目的呼号偏移 `+8` 和源呼号偏移 `+0x12` 已在 HRI 日志/缓冲区读出，但没有设备屏幕照片或电台侧响应证明两者在 FTX-1 LCD 的位置、显示时机和清除方式。Room/Node 浏览列表不是当前 BM 来话 LCD 的必要前置范围。
3. HRI 正文开头 7 字节中全局 `DAT_10167c4c`/`DAT_10167c50` 的实际值与含义未知。模式字符 `'0'`/`'2'`/`'3'` 只由静态代码和长度校验恢复；它们与 YSF DT 的关系没有证据。HRI 的空头 PCM 候选单独使用 mode `'4'`，本轮没有发现 PCM mode4 可独立更新呼号/StationInfo 的确定路径。
4. C 的 R31 静态证据显示 Direct 外层 vtable 与 ASCII factory 使用不同的记录序列化器；当前没有把内部 T 队列项沿 `0x618` 之后连续追到对应外层序列化器并对照设备接受响应。COM5 的 Direct vtable 选择是传输类别，不等于电台 Node Mode DIRECT。

下一步静态追踪应优先找 HRI 收包/来话消息里是否有独立的身份更新类型，以及它是否在 PCM mode4 路径也更新同一头部/呼号缓存；同时追 `FUN_004e5580` 及 `E3/E4` 的远端字段 producer，不把 PC Direct 面板或本机 `USER_INF` 身份当作远端 BM 呼号。若随后由主会话安排一次 DIRECT 设备对照，应先确定可用的合法 10 字节源呼号、6 个可见前缀值、mode 与 payload 是否配套、明确的单次结束/清除条件，并记录电台屏幕是否出现和清除相应字段。当前没有生成或发送这个试验正文，也没有连接真实 COM、RF、BM 或官方程序。
