# HRI 数字记录、头字段与调制控件研究进度

日期：2026-10-27。本页合并 R95 的 G 帧/头字段、R96 的 Modulation 控件和 R97 的 R 记录路径结论，方便后续软件实现与联测复核。WIRES-X 样本均为 2.0.1.0。静态函数与 PE 资源结果来自本机固定文件；研究期间没有加载厂商 DLL 或启动官方客户端。R91、R93 的既有被动观察只按各自报告的范围引用。

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

因此，主程序把 G/H 交给 `ToHriFrameAdd`；HRI 的 G/H 处理循环随后从按模式选择的 `ToHriAmbeGet` 或 `ToAnaAmbeGet` 回调取一条记录。RIGDATAIF 的 `ToHriFrameAdd` 节点实现和运行时表对象尚未单独核对，所以当前没有把这两个 API 直接描述成同一条链表，也不把 G 输入称为来自 `AmbeAdd` 或 `AmbeGet`。

### G 记录和 68 字节头的偏移

在 EXE `FUN_0043d810` 的局部 G 字符串中，索引 `0` 是 `G`，索引 `1..4` 是四个 ASCII HEX 字符。模式判断读取 `local_18f & 3`；`local_18f` 位于字符串基址 `local_198+9`，所以索引 `9` 的低两位控制该分支。头部从字符串索引 `5` 开始时，索引 `9` 正好是头部偏移 `+4`。在 HRI 端，`FUN_10014dd0` 从返回节点 `+4` 读取类型；它把该节点指针传入 `FUN_10014330`，后者从节点 `+9` 复制连续 68 字节到对象 `+0x1420`。这两个读址与“节点字符串缓冲从 `+4` 开始、G 后接四个 HEX 字符、68 字节头从原始字符串索引 5 开始”的布局相符。R6 对 RigDataIf 其他 Add 队列记录了节点字符串缓冲 `+4`，但 `ToHriFrameAdd` 本身实现仍未单独反编译，故这项 Add 到 Get 的精确节点布局还需闭合。

EXE 只将四位 HEX 转成整数并作记录长度检查：低两位为 0/1 时不执行该检查；为 2 时要求记录长度等于 `uVar3+1`；为 3 时要求等于 `uVar3+5`。代码没有说明 `uVar3` 是 payload 字节数、HEX 字符数还是帧数。HRI `FUN_10014330` 的 `param_3+0x4d` 是以 HRI 节点为基址的后续文本读取地址；在节点 `+4` 存放原始字符串的条件下，它对应字符串索引 73，不能把该内部指针偏移原样写成 EXE 输入字符串索引 77。原始 G 记录的尾部编码用途尚未确认。

HRI 头解析器 `FUN_10014330` 把 68 字节复制到 `this+0x1420`，写头部偏移 `+3` 为 ASCII `'1'`，并对复制头部执行 `header[4] |= 0x04`；随后 `FUN_10014070` 从头部 `+8` 读 10 字节目的呼号、从 `+0x12` 读 10 字节源呼号。头部 `+0x1c` 的 10 字节来自 HRI 本机 `DGKEY_STR_CALL_SIGN`；`+0x30` 的 5 字节来自本机 `DGKEY_STR_NODE_RADIO_ID`。Evidence：`FUN_10014330` `ev_dd4741e6a283be5d7a5c88c8e35f4a98f22825de30ac56f6d3e015d8ee702ad9`；`FUN_10014070` `ev_af377ccbc045e89e9964c53d4ab86c39d7534f358fda167ec8bf64bfc7435d28`；本机配置读取 `FUN_1000d370` `ev_872f6848966086fe1393376f10eb179c48305a1cb4bb8a541d52f14b9878c888`。

`FUN_10017ee0` 会清空 HRI 对象的 `+0x1420` 内部头缓存。静态材料没有显示它发送电台 LCD 清屏命令。头字段的写入、内部缓存清理和 FTX-1 屏幕呈现是三个不同结果；本轮只恢复了前两者的部分软件路径。

### 与现有 Bridge 代码的关系

`hri_call_header` 已提供 68 字节头和目的/源 10 字节字段的纯内存访问；`hri_t_record` 已按静态证据构造内部 T 正文和尾文本。它们没有把头字段写入 FTX-1 屏幕的证据。当前独立 LCD identity candidate 可在原 T90 候选上替换一个呼号字段，作为单字段对照原型；它没有接入 BM 默认运行链，也没有经过 LCD 实机观察。BRIDGE 的 WPF 来话卡片显示的是 pipeline 接受的 DMR Source ID/TG 等状态，不是电台 LCD。

没有远端 DMR ID→WIRES-X Callsign 数据源。DMR 数字 ID 不应直接写到头部 10 字节呼号字段；若后续测试选用 `ID1234` 这种可见文本，它只是一项明确的屏幕候选标签，不是已映射出的真实呼号。

## R96：Modulation 下拉项的资源候选

PE 资源 246 的 `Transceiver` 模板中，`Modulation` 旁的 ID `0x59E` 控件 class atom 是 `0x81 / EDIT`；不能把这份模板的该字段描述为 ComboBox。另一个资源 1028 含 `Modulation` 标签及同一行 class atom `0x85 / ComboBox`、ID `0x4A3`，这是目前最接近下拉框截图的资源候选。资源 1028 的运行时对话框类仍未识别。

`0x4A3` 有四条 `WM_COMMAND / CBN_SELCHANGE` 消息映射行，回调落到三个短虚函数 thunk，再分派到对象 vtable `+0x1BC`、`+0x1C8` 或 `+0x1CC`。控件所属类、读选项、保存到模式字段的函数和 Apply/OK/Cancel 路径都未恢复。R93 中选择 `DIGITAL` 后读数仍是 FM，随后主会话选择 Cancel；没有点击 Apply 或 OK，因此没有验证数字模式已保存。静态证据没有解释 FM 读数为何保持不变，也没有证明 DIRECT 模式会修改这个设置。完整静态摘要见 `research/rf/R96_Modulation控件模板与有限消息路由.md`，私有 Evidence 位于 `research/hil/2026-10-27_r96_modulation_control_private_bundle.json`。

## R97：R 记录到网络队列的分支

R97 已修正输入偏移表达式：parser context 为 `ctx=*(this+0x2b4)`，读取 `o=*(ctx+0x10)`；入口参数 EDI 是 parser 输入基址，类型字符位于 `EDI+o`。在 R 分支，HRI `+0x58 == 1` 才继续；state 21/22 的 event `0x13` 路径到 wrapper `FUN_1001b2a0`，以条件指针偏移将 NUL 结尾字符串传给 `ToNetAmbeAdd` (`+0x7c`)。`RigDataIf.ToNetAmbeAdd` 保存文本队列节点，主程序 consumer 再把字符串原样封入 RAW 子封套。此路径没有恢复 HEX→语音载荷、AMBE/YSF/DMR codec 或五分片循环；四位字段只验证与整体字符串长度的关系。此结论只适用于 R 路径，不能移植到 G 记录。详细证据见 `research/rf/R97_数字语音记录格式.md`；其中函数 Evidence ID 与摘要均保留在该报告内。

## 后续工作边界

下一步如把 BM 活动来话用于 T90 单字段对照，应只在已接受的 `receive_started`/有效 Snapshot 上生成候选标签，保持目的 TG、本机呼号与头部其余 58 字节及整个既有控制记录的其他内容原样；`ID1234` 应明确显示为由 DMR ID 生成的测试标签，不应冒充真实 callsign。开关必须显式 opt-in，默认 T90/T0 内容完全保持。交付候选供最终集中联测；本页没有发送该记录或验证屏幕结果。

要把“当前呼叫者显示在 FTX-1”做成已完成功能，还需补证：`ToHriFrameAdd` 与 HRI G/H 消费者的实际队列实例对应；HRI 内部 68B 头如何通过所选串口 serializer 变成最终电台写入；电台对头字段的接受规则；呼叫结束时的实际清屏事务；以及一次有界 LCD 屏幕观察。

### 三个明确的下一步代码入口

1. **补齐 G/H 队列连接。** 在 `RIGDATAIF.DLL!ToHriFrameAdd`（导出 VA `0x100028e0`）检查其队列对象和节点布局，再与 HRI `FUN_10014dd0` 的 `+0x44/+0x64` Get 分支、`FUN_10014330` 的 `node+9` 头复制逐字节核对。R6 只详查 `ToHriAmbeAdd` 共用节点 Add 入口，不覆盖 `ToHriFrameAdd`。
2. **跟到最终串口写入和清理。** 从 HRI `FUN_10014330` / `FUN_10017ee0` 查生成的内部记录是否经过 `FUN_1000b130`、公共队列和 EXE `WM 0x618` handler，最终落到哪个串口 serializer 及 `WriteFile`。分别确认头部更新和呼叫结束时实际发送的清理记录；静态缓存置零不作为屏幕清除。
3. **定位 Modulation 控件所属类。** 从 `SETTINGDLG.DLL` 资源1028/ID `0x4A3` 开始，定位四条 `CBN_SELCHANGE` 映射属于哪个 dialog 类，再查其 vtable `+0x1BC/+0x1C8/+0x1CC` 和 `Apply/OK/Cancel` 写入路径。保留 R93 用户操作为“选择后读数仍为 FM，主会话选择 Cancel”，不推断其保存结果。
