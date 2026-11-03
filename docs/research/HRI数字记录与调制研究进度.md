# HRI 数字记录、头字段与调制控件研究进度

日期：2026-10-27。本页合并 R95 的 G 帧/头字段、R96 的 Modulation 控件、R97 的 R 记录路径和 R99 的 FrameAdd 队列闭合结论，并记录 R100 BM 来话身份处理的核心代码状态。WIRES-X 样本均为 2.0.1.0。静态函数与 PE 资源结果来自本机固定文件；研究期间没有加载厂商 DLL 或启动官方客户端。R91、R93 的既有被动观察只按各自报告的范围引用。

固定目标 SHA-256：`WIRES_X.EXE` `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`；`HRI_UART.dll` `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed`；`RIGDATAIF.DLL` `94d1217feb047288329e79e0d5de2167c79450f1945119b2ed6c6376b02a7410`；`SETTINGDLG.DLL` `e83b2ee0070a127ab33ebe0dca936bc214cca0b8fcb484c3d7fce3e0c455def5`。

## R95：G/H 走 FrameAdd，E/R 走 AmbeAdd

主程序 `FUN_0043d810` 对 RAW 子记录按首字节分流：G/H 调主程序 RigDataIf 函数表 `+0x38`，resolver 名 `TOHRIFRAMEADD`；E/R 调 `+0x3c`，resolver 名 `TOHRIAMBEADD`。对应 Evidence：`FUN_0043d810` `ev_c1d5cceea752e3ff69cc6c5ff7c4a2ad7c3283755c0cd1cf54f23e54afbc7210`；`FUN_004fd0c0` `ev_1ab59d3d6ababf4aa5c6d3de34fb6531ce3c994e475687fac33ee38e2e395063`。

HRI resolver `FUN_100251d0` 登记的回调名如下；此表与 EXE 的 RigDataIf 调用表分属不同对象：

| HRI 表偏移 | 已由 `GetProcAddress` 名称确认的入口 |
|---:|---|
| `+0x38` | `TOHRIFRAMEADD` |
| `+0x3c` | `TOHRIAMBEADD` |
| `+0x40` | `TOHRITOPFRAMEGET` |
| `+0x44` | `TOHRIAMBEGET` |
| `+0x48` | `TOHRIAMBEGETCOUNT` |
| `+0x60` | `TOANATOPFRAMEGET` |
| `+0x64` | `TOANAAMBEGET` |
| `+0x68` | `TOANAAMBEGETCOUNT` |

HRI `FUN_10014dd0` 的 G/H 分支通过 `+0x44` 或 `+0x64` 取记录；它没有调用 `+0x40` 或 `+0x60` 的 TopFrameGet 槽。表项名称来自 HRI resolver `FUN_100251d0` 的 Evidence `ev_b24f6fe7c7a23517a4205c80f233802c6b45fb400063e341d8564aa35b3dd24f`；`TOHRITOPFRAMEGET` 字符串在 `0x1002539b` 的引用及函数归属分别见 `ev_3c6f265c5d0f8d1d2b016fda433c012f40803f727e80991015b69f6b989935f9`、`ev_d54dee5d12a476cae6183601b731ab5064d5c630e6501f8351b7b682bcdae273`。G/H 消费循环见 R82 Evidence `ev_5b0823e547bc0fb0a3fecd6484054ee080a5e9b94d083ae4cc791ef7ab4afe1d`。

因此，主程序把 G/H 交给 `ToHriFrameAdd`；R99 随后确认该入口写入的队列对象地址与 HRI 的 `ToHriAmbeGet` head 完全相同。HRI 的 G/H 处理循环按模式选择 HRI Get 或 ANA Get，但 ANA Get 使用另一队列。记录仍不能称为来自 `ToHriAmbeAdd`；G/H 与 E/R 是主程序分发到不同 Add 入口的两类记录。

### G 记录和 68 字节头的偏移

在 EXE `FUN_0043d810` 的局部 G 字符串中，索引 `0` 是 `G`，索引 `1..4` 是四个 ASCII HEX 字符。模式判断读取 `local_18f & 3`；`local_18f` 位于字符串基址 `local_198+9`，所以索引 `9` 的低两位控制该分支。头部从字符串索引 `5` 开始时，索引 `9` 正好是头部偏移 `+4`。在 HRI 端，`FUN_10014dd0` 从返回节点 `+4` 读取类型；它把该节点指针传入 `FUN_10014330`，后者从节点 `+9` 复制连续 68 字节到对象 `+0x1420`。R99 对 `ToHriFrameAdd` 的直接反编译确认字符串缓冲从节点 `+4` 开始，因此 `node+9` 对应原始 G 字符串索引 `5`，也就是四个 HEX 字符后的 68 字节头起点。头内偏移 `+4` 对应原始 G 字符串索引 `9`。R99 的函数地址和 Evidence ID 见下节。

EXE 只将四位 HEX 转成整数并作记录长度检查：低两位为 0/1 时不执行该检查；为 2 时要求记录长度等于 `uVar3+1`；为 3 时要求等于 `uVar3+5`。代码没有说明 `uVar3` 是 payload 字节数、HEX 字符数还是帧数。HRI `FUN_10014330` 的 `param_3+0x4d` 是以 HRI 节点为基址的后续文本读取地址；在节点 `+4` 存放原始字符串的条件下，它对应字符串索引 73，不能把该内部指针偏移原样写成 EXE 输入字符串索引 77。原始 G 记录的尾部编码用途尚未确认。

HRI 头解析器 `FUN_10014330` 把 68 字节复制到 `this+0x1420`，写头部偏移 `+3` 为 ASCII `'1'`，并对复制头部执行 `header[4] |= 0x04`；随后 `FUN_10014070` 从头部 `+8` 读 10 字节目的呼号、从 `+0x12` 读 10 字节源呼号。头部 `+0x1c` 的 10 字节来自 HRI 本机 `DGKEY_STR_CALL_SIGN`；`+0x30` 的 5 字节来自本机 `DGKEY_STR_NODE_RADIO_ID`。Evidence：`FUN_10014330` `ev_dd4741e6a283be5d7a5c88c8e35f4a98f22825de30ac56f6d3e015d8ee702ad9`；`FUN_10014070` `ev_af377ccbc045e89e9964c53d4ab86c39d7534f358fda167ec8bf64bfc7435d28`；本机配置读取 `FUN_1000d370` `ev_872f6848966086fe1393376f10eb179c48305a1cb4bb8a541d52f14b9878c888`。

`FUN_10017ee0` 会清空 HRI 对象的 `+0x1420` 内部头缓存。静态材料没有显示它发送电台 LCD 清屏命令。头字段的写入、内部缓存清理和 FTX-1 屏幕呈现是三个不同结果；本轮只恢复了前两者的部分软件路径。

### R99：FrameAdd 与 HRI G/H consumer 使用同一队列

RIGDATAIF.DLL 的 `ToHriFrameAdd`（VA `0x100028e0`）把输入字符串和第二参数交给 `FUN_100011c0`，并把队列对象 `0x1016830c` 传给该函数。`FUN_100011c0`（VA `0x100011c0`）使用该对象的 head `+0`、tail `+4`、mutex `+8`、count `+0x10`；新节点为 `0x330` 字节，next 链接位于 `+0x324`。`FUN_10001000` 初始化节点，把类型值写入 node[0]，并在 node+4 建立最多 800 字节的字符串缓冲；G 输入的字符串复制到该缓冲。函数级 Evidence ID 依次为 `ev_48c102f231f757edf2ca0da003dee6fe267c4b877856b667d2be86e8c7657758`、`ev_511b4f33a6adc48d3c215a27f46494f7f554aebeae5cde3615a017388025c893`、`ev_b251db448306d067410166d7899b176c0c0968f06659d731f841df8329ea0be2`。

同一 DLL 的 `ToHriAmbeGet`（VA `0x10002950`）读取 head `0x1016830c`、count `0x1016831c`，与 `ToHriFrameAdd` 使用的队列对象地址相同。`ToAnaAmbeGet`（VA `0x10002a40`）读取 head `0x10168324`、count `0x10168334`，属于独立队列。Get 参数非零时各自把 head 移至旧节点 `+0x324` 的 next；参数为零时仅窥读 head。由此，R95 中的 G/H 输入→`ToHriFrameAdd`→HRI Get 队首链在静态对象指针上闭合；HRI consumer 选择 ANA Get 时会读另一队列。

完整 R99 摘要位于 [`research/rf/R99_ToHriFrameAdd与HRI队列闭合.md`](../../../research/rf/R99_ToHriFrameAdd与HRI队列闭合.md)，私有静态 Evidence bundle 为 `research/rea/v2.010/r99_rigdataif_frameadd_queue_20261027.json`，SHA-256 `069c5a9287a9ed3d7d2d01cfd508a341cd4e794e1c6cb1c8203cd281a0fde092`。这些结果来自固定 DLL 的静态指令，没有运行时读取队列；`param_2` 语义、节点释放责任及 Get 的上游条件仍未知。

### 与现有 Bridge 代码的关系

`hri_call_header` 已提供 68 字节头和目的/源 10 字节字段的纯内存访问；`hri_t_record` 已按静态证据构造内部 T 正文和尾文本。它们没有把头字段写入 FTX-1 屏幕的证据。旧的 `hri_lcd_identity_candidate` 固定 WAV 工具仍可用于了解已定位字段的位置；R100 的 BM 来话身份处理会自动更新每通已接受来话的核心路径。Bridge 的 WPF 来话卡片显示 pipeline 接受的 DMR Source ID/TG 等状态，与电台 LCD 是两类输出。

R98 已提交源码曾把数字 Source ID 标签放在默认关闭的开关后，并针对该版本做过 COM999 启动失败状态 smoke。R100 源码提交 `ddeee3105002e5f923c9f727f8ad2811f61a829a` 已改为每通已接受 BM 来话自动生成标签：`ID` 加十进制 DMR Source ID，写入 mode4 起始正文的 10 字节 source 字段；T0 与 PCM 下行收尾保持现有顺序。标签不是 WIRES-X callsign，也不依赖呼号查询。Native 状态字段为 `lcd_source_identity.prepared`、`source_id`、`receive_generation`、`label` 和 `display`；`display` 固定为 `unknown`，直到有实际屏幕观察。R100 clean build 通过 35 项 C++ 测试，warning/error 为 0；COM999 smoke 的两条实际 JSON 事件含空闲身份对象，详细构建和 smoke 回执见[BM 来话身份显示](../BM来话身份显示.md)。该 smoke 不覆盖来话映射或电台显示。WPF 当前仍只读取 R94 的 `current_call_*`，尚未读取 `lcd_source_identity`。本机默认入口仍指向 alpha.2，该发布包没有 R100 代码。

没有远端 DMR ID→WIRES-X Callsign 数据源。R100 把 `ID` 加十进制 DMR Source ID 作为数字身份标签写入头部的 10 字节 source 字段；例如 `ID1234` 是 DMR 数字身份标签，不是已映射出的真实呼号。实际 FTX-1 显示内容仍待设备观察。

## R96：Modulation 下拉项的资源候选

PE 资源 246 的 `Transceiver` 模板中，`Modulation` 旁的 ID `0x59E` 控件 class atom 是 `0x81 / EDIT`；不能把这份模板的该字段描述为 ComboBox。另一个资源 1028 含 `Modulation` 标签及同一行 class atom `0x85 / ComboBox`、ID `0x4A3`，这是目前最接近下拉框截图的资源候选。资源 1028 的运行时对话框类仍未识别。

`0x4A3` 有四条 `WM_COMMAND / CBN_SELCHANGE` 消息映射行，回调落到三个短虚函数 thunk，再分派到对象 vtable `+0x1BC`、`+0x1C8` 或 `+0x1CC`。控件所属类、读选项、保存到模式字段的函数和 Apply/OK/Cancel 路径都未恢复。R93 中选择 `DIGITAL` 后读数仍是 FM，随后主会话选择 Cancel；没有点击 Apply 或 OK，因此没有验证数字模式已保存。静态证据没有解释 FM 读数为何保持不变，也没有证明 DIRECT 模式会修改这个设置。完整静态摘要见 `research/rf/R96_Modulation控件模板与有限消息路由.md`，私有 Evidence 位于 `research/hil/2026-10-27_r96_modulation_control_private_bundle.json`。

## R97：R 记录到网络队列的分支

R97 已修正输入偏移表达式：parser context 为 `ctx=*(this+0x2b4)`，读取 `o=*(ctx+0x10)`；入口参数 EDI 是 parser 输入基址，类型字符位于 `EDI+o`。在 R 分支，HRI `+0x58 == 1` 才继续；state 21/22 的 event `0x13` 路径到 wrapper `FUN_1001b2a0`，以条件指针偏移将 NUL 结尾字符串传给 `ToNetAmbeAdd` (`+0x7c`)。`RigDataIf.ToNetAmbeAdd` 保存文本队列节点，主程序 consumer 再把字符串原样封入 RAW 子封套。此路径没有恢复 HEX→语音载荷、AMBE/YSF/DMR codec 或五分片循环；四位字段只验证与整体字符串长度的关系。此结论只适用于 R 路径，不能移植到 G 记录。详细证据见 `research/rf/R97_数字语音记录格式.md`；其中函数 Evidence ID 与摘要均保留在该报告内。

## 后续工作边界

R100 核心路径从每通已接受 Snapshot 读取外层 DMR Source ID，并保留独立的 `link_control_validated` 状态。若 pipeline 在完整 LC 尚未验证时已接受来话，仍会按该 Snapshot 的 Source ID 生成身份标签；软件状态不得把这项数字标签写成已确认呼号。R100 clean build 的 35 项测试已通过；Native 在通话收尾、接收取消、T3 启动超时、网络丢失、运行异常和退出路径清空身份元数据。COM999 smoke 只验证无来话启动状态和串口失败路径，不验证身份标签显示。WPF 没有显示 `lcd_source_identity`，只显示 R94 的 `current_call_*` 状态。

要把“当前呼叫者显示在 FTX-1”做成已验证功能，还需确认 HRI G/H consumer 如何将内部记录交给实际选中的 UART serializer、设备如何接受该头字段、呼叫结束时实际清屏事务，以及一次受控 LCD 屏幕观察。R99 已闭合 Add/Get 队列地址，后续不再把该固定队列关系列为未知。R100 的软件状态和屏幕观察分别验收；Native 记录 `display=unknown` 时不能报告 LCD 已显示。

### 三个明确的下一步代码入口

1. **确认 G/H 记录进入哪种最终串口 serializer。** 从 HRI `FUN_10014dd0` 的 HRI Get/ANA Get 分支和 `FUN_10014330` 的 `node+9` 头复制继续跟踪内部记录，核对它是否经过 `FUN_1000b130`、公共队列、EXE `WM 0x618` handler 以及所选串口 serializer，直到 `WriteFile` 的输入缓冲区。R99 已确认 FrameAdd 和 HRI Get 使用 `0x1016830c`，ANA Get 使用 `0x10168324`。
2. **恢复呼叫结束的设备侧清屏事务。** 将 `FUN_10017ee0` 的 HRI 内部缓存清理与真正发往电台的记录分别追踪；只有找到设备写入和屏幕观察后，才记录显示清除结果。
3. **定位 Modulation 控件所属类。** 从 `SETTINGDLG.DLL` 资源1028/ID `0x4A3` 开始，定位四条 `CBN_SELCHANGE` 映射属于哪个 dialog 类，再查其 vtable `+0x1BC/+0x1C8/+0x1CC` 和 `Apply/OK/Cancel` 写入路径。保留 R93 用户操作为“选择后读数仍为 FM，主会话选择 Cancel”，不推断其保存结果。
