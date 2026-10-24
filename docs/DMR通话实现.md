<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# DMR 通话帧与流状态

本文记录 `dmr_call` 离线模块的帧格式、状态规则、上游来源和验证证据。它不代表 BrandMeister、HRI、音频设备或射频已联调。

## 接口与时序

接口位于 `include/wirex/dmr_call.hpp`。发送端 `Transmitter` 不持有时钟，也不发送网络包：

1. `start(CallConfig)` 校验 24 位源/目的 ID、时隙和色码，返回带完整 voice LC header 的 `dmrd::Datagram`，序号从 0 开始。
2. 每次 `voice(AmbeVoiceBurst)` 接收三个连续的 9 字节 AMBE/FEC 码字，按 DMR payload 布局合成为 33 字节 burst。第一个 burst 是 audio sync A，之后按 B、C、D、E、F 循环。序号每个 DMRD 数据报递增，并按 8 位回绕。
3. 调用者每 60 ms 调用一次 `voice`；`voice_burst_period` 只提供节拍常量，模块本身不等待或创建调度线程。
4. `finish()` 返回带完整 LC 的 terminator/EOT 并结束本地发送状态。重复 `start`、非活动状态下 `voice/finish` 返回错误。重复发 header 的策略属于传输层；模块返回的 header 数据报可原样重复。

`Receiver::ingest(datagram, now)` 接收已经由外层 DMRD 解出的数据报，时间由调用方用 `steady_clock` 提供。接收端按 TS1/TS2 分开保留最多两条通话状态，并输出固定容量事件数组，不缓存 PCM。事件类型有 `call_started`、`voice`、`link_control_confirmed` 和 `call_ended`。即使结果状态为 `malformed`，调用方也应先处理结果中已产生的事件；例如当前时隙在包校验前刚好超时时，结束事件仍会返回。

一次 `ingest` 只检查该数据报所在时隙的超时，所以事件上限为三项：旧流 watchdog 结束、新流开始、当前 burst 语音。`poll(now)` 扫描两个时隙，最多返回两项 watchdog 结束事件。集成方应在没有数据报到达时仍调用 `poll`，以便另一时隙按时结束。

默认 watchdog 为 360 ms；`poll` 在活动流最后一次有效包之后达到该时限时发出 `call_ended/watchdog`。已结束的 stream ID 默认保留 2 秒，阻止迟到的 voice-sync A 或旧包重开流。相同通话的重复/迟到 LC header 不重发 `call_started`；如果此前从 A burst 加入且 LC 尚未验证，收到身份匹配的 header 时只发一次 `link_control_confirmed`。

若 receiver 错过 LC header，它可用通过 MS/BS audio-sync 检查的 A burst 建流并同时发出 `call_started`、`voice`。此时 `link_control_validated=false`，身份和时隙暂按 DMRD 外层字段表示；后续嵌入 LC 或有效重复 header 校验通过才发确认事件。对已知 LC 的 stream，嵌入 LC 或 full LC 的源 ID、目的 ID、group/private 类型必须匹配 DMRD 字段。相同 TS 和 stream ID 不能在活动期间从 group 切换成 private 或反向切换。

## 33 字节 burst 与 LC/FEC

三个 9 字节 AMBE 码字不重新编码。比特按 DroidStar 的 voice payload 位置放入 33 字节 burst：最前 108 bit 原位写入，剩余 108 bit 跳过中央 48 bit 的 sync/EMB 区后写入；接收端执行相反映射，恢复原来的 27 字节。中央区在 A burst 放 audio sync，在 B-E burst 放 EMB/嵌入 LC，在 F burst 放空嵌入区和终结 LCSS。AMBE 码字内的 FEC 已由 codec 层提供，本模块既不生成也不纠正语音 FEC。

Full LC header 和 terminator 包含 72 位 Link Control、RS(12,9) 校验及相应 CRC mask，经 BPTC(196,96) 的 Hamming(15,11) 行码、Hamming(13,9) 列码和交织后放入 33 字节数据 burst。Slot Type 用 Golay(20,8) 编码，携带色码与数据类型；数据 sync 使用 MS-sourced 模式发送。接收端检查同步、Slot Type、BPTC/RS 结果，并验证 DMRD 外层 ID 与 LC 内容一致。

嵌入 LC 将 72 位 LC 数据加 CRC-5，置入 128 位矩阵并做 Hamming(16,11) 行码和列奇偶校验，再交织成四块。B-E burst 的 LCSS 顺序为 1、3、3、2。EMB 字段用 QR(16,7) 校验；接收端可纠正 QR/Hamming 可纠正的位错误，并在四块完整、CRC-5 正确且 LC 与 DMRD 身份一致后发出 LC 确认事件。

DMRD flags 与原 55 字节 transport 格式保持分层：TS2 为 `0x80`，private call 为 `0x40`，data sync 为 `0x20`，voice sync 为 `0x10`；低四位用于 full-LC data type 或 voice burst 序号。发送端用 header 类型 `0x01`、EOT 类型 `0x02`；voice A 为时隙/呼叫类型 flags 与 `0x10` 的按位或，voice B-F 为同一时隙/呼叫类型 flags 与低位 burst 序号 `1` 至 `5` 的按位或。例如 TS1 group voice B-F 为 `0x01` 至 `0x05`，TS2 group 为 `0x81` 至 `0x85`，TS1 private 为 `0x41` 至 `0x45`，TS2 private 为 `0xC1` 至 `0xC5`。以上值进入既有 `dmrd::Datagram`，本模块不建立 socket、不负责登录，也不重复封装 55 字节外层。

## 文件与许可来源

本目录新增的项目文件采用 `GPL-3.0-or-later`。第三方算法来源均固定到已审阅的上游提交；`third_party/dmr_signal/NOTICE.md` 保留原始作者与逐文件来源/许可信息，`COPYING.GPL-3.0.txt` 附完整 GPL-3 文本。`dmr_signal.cpp` 与 `.hpp` 接口文件均有独立 SPDX 标记。

| 本地文件 | 负责内容 | 固定上游来源 |
| --- | --- | --- |
| `include/wirex/dmr_call.hpp` | 公开 Tx/Rx 类型与事件 API | 项目接口；GPL-3.0-or-later |
| `src/dmr_call.cpp` | DMRD flags、序号、每 TS 流状态、超时、迟到包和事件 | DroidStar `dmr.cpp`，提交 [`becf1dede57c4a70a865e9cb4cac9247e505599a`](https://github.com/nostar/DroidStar/blob/becf1dede57c4a70a865e9cb4cac9247e505599a/dmr.cpp)，GPL-3.0-or-later |
| `third_party/dmr_signal/dmr_signal.hpp` | 信令算法边界类型 | 项目接口；GPL-3.0-or-later |
| `third_party/dmr_signal/dmr_signal.cpp` | Golay、QR、RS、BPTC、Hamming、LC、sync、EMB、33B 语音位映射 | MMDVM_CM `USRP2DMR/{BPTC19696,DMRFullLC,DMRSlotType,Golay2087,DMREMB,DMREmbeddedData,QR1676,RS129,Hamming,DMRDefines}.cpp/.h`，提交 [`7328c9e9532d29cf4d9d7d24541d57f825207be4`](https://github.com/juribeparada/MMDVM_CM/tree/7328c9e9532d29cf4d9d7d24541d57f825207be4/USRP2DMR)，GPL-2.0-or-later；33B AMBE 位布局另对照 DroidStar 上述 `dmr.cpp` |
| `tests/dmr_call_test.cpp` | 固定上游向量、身份/状态边界、错误纠正验证 | GPL-3.0-or-later；独立 golden bytes 由 pinned MMDVM_CM 类生成，测试运行时不链接其源码 |

MMDVM_CM 授权 GPL-2.0-or-later，因此该算法改写按 GPL-3.0-or-later 发布；没有复制或链接声码器代码。DroidStar 只作为 DMRD 通话标志与 AMBE payload 位布局的固定参考。`dmr_signal.cpp` 所处理的是信令及语音比特位置，不是 AMBE 编解码器。

## 离线验证与限制

`tests/dmr_call_test.cpp` 中的完整 33 字节 header、terminator、A-F 语音向量来自固定 MMDVM_CM 实现，并与本模块输出逐字节比较，不以本模块自往返作为唯一证据。测试还覆盖了 BPTC/QR/Hamming 单比特或多比特错误、嵌入 LC 身份确认、序号回绕/缺包/重复/迟到、voice-sync A 中途加入、重复 header、双时隙 watchdog、三事件容量、group/private 身份切换和非法 flags。

本阶段直接用 MSVC C++17 编译模块测试，没有改动 CMake：

```powershell
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /I include /I third_party/dmr_signal `
  /Fo:build\_work\dmr-call\ /Fe:build\_work\dmr-call\dmr_call_test.exe `
  tests\dmr_call_test.cpp src\dmr_call.cpp third_party\dmr_signal\dmr_signal.cpp src\dmrd.cpp
build\_work\dmr-call\dmr_call_test.exe
```

本机 MSVC 14.29 的编译没有告警，测试输出 `All DMR call/FEC checks passed.`。这些是离线单元和固定上游差分证据；没有使用真实 BrandMeister、串口、HRI、音频设备或 RF。当前接收端只输出三码字 AMBE burst 和通话事件；解码后的 PCM、声码器质量、实际网络时序和真实网络兼容性由后续集成及联合测试确认。
