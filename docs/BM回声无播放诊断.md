# BM 回声无播放诊断

## 旧日志证据

检查对象是 `build/bm-radio-bridge-2183cef/logs/bm-bridge-20261024-124530-759-490bf9a5.jsonl`。BM 在约 202 ms 到达 `ready`，HRI 的 Y0 确认后记录 speaker ready；日志累计 `application_rx_datagrams=291`、`rx_datagrams=291`，但 `calls_started=0`、`calls_ended=0`、`playback_frames=0`、`rejected_calls=0`。该日志未记录 DMRD 头、LC、流标识或过滤结果，单凭这些计数不能认定收到的是鹦鹉回声。

## 有界私呼回声实测

之后获授权进行了两次各发送一通合成私呼的 network-only 实测。工具使用生产 `bm::Session`、`UdpTransport`、`dmr_call::Transmitter` 和 RX-only `BmVoicePipeline`；没有打开 HRI、COM、WinMM、音频设备或射频设备。私有密码只由工具读入生产会话，没有打印、哈希或写入日志。两次都使用目标 460997，不读取、保存或记录语音负载。

第一次实测使用旧 TS1 preset，呼叫为 source 4611355 → Echo 460997、CC1。它发送 1 个 header、33 个按 60 ms 间隔发送的 voice burst 和 1 个 terminator；合成 500 Hz PCM 振幅为 1200，voice 帧共 1.98 秒（99 个 20 ms 帧，适配 60 ms DMR burst）。BM 进入 `ready`，35 个出站 DMRD 数据报均发送成功。发送 EOT 后，工具最多接收 15 秒，总运行时限为 24.9 秒；退出前实际发送 RPTCL 成功，退出码为 0。工具和日志位于 `build/_work/bm-private-echo-20261024-161800/`。

BM 在 EOT 后 3.250 秒回送一条完整私呼流，共 37 个 DMRD 数据报，首包约 5.379 秒、末包约 7.298 秒。实测头字段如下：

- header：seq=1，flags=`0xE1`，TS2、private、data-sync/type 1，stream ID `00000000`。
- terminator：seq=36，flags=`0xE2`，TS2、private、data-sync/type 2，同一 stream ID。
- 外层身份：src=460997、dst=4611355、private。
- 解出的完整 LC 身份：src=460997、dst=4611355、FLCO=3、CC=1；头字段与 LC 一致。该流有 4 个有效 LC header 记录、1 个有效 terminator 记录。

当时 native 的接收过滤器要求本机 ID 4611355、TS1、private。RX-only pipeline 收到的 37 个数据报因此全部返回 `Error::filtered`；Receiver 没有 start、voice 或 end 事件。回声确实已经返回，根因是三个单时隙 DIRECT 预设将时隙设为 TS1，而实际 BM 回送流在 TS2。目的 ID、呼叫类型、LC 和色码都匹配。这个 network-only 结果没有验证 HRI 或真实音频播放。

根线程据该头字段把三个 preset 的 slot 改成 TS2 后，又获授权进行一次独立实测。诊断工具从生产 `bm_test_profile::find("parrot-cn")` 读取 Gateway、source、destination、slot、call kind、CC 和 master 配置，并从同一 preset 构造 RX filter，没有在工具中硬编码时隙。工具与日志位于 `build/_work/bm-private-echo-preset-ts2-20261024-154510z/`。出站 header、33 个 voice burst 和 EOT 共 35 个 DMRD 数据报均实际发送成功；BM 约 92 ms 进入 `ready`。EOT 后 3.275 秒收到回声首包，返回 37 个 DMRD 数据报。首包为 `src=460997 dst=4611355 slot=2 call=P flags=0xE1 type=1 seq=1 stream=00000000`；有效 header LC 与外层身份一致，`FLCO=3 CC=1`。流内 terminator LC 也有效并与外层身份一致。

TS2 preset filter 对该流的 37 个数据报全部匹配。生产 Receiver 发出 1 个 `call_started`、32 个 `voice` 和 1 个 `call_ended` 事件；pipeline 发出 `receive_started` 和 `network_ended`。RX-only pipeline 没有设置 playback readiness，所以随后报告 `playback_start_timeout`；没有 PCM 被取出或送到音频设备。这证明 TS2 preset 修复了过滤和 Receiver 呼叫识别，不证明 HRI 或真实音频播放。工具在 17.148 秒结束前实际发送 RPTCL 成功，退出码为 0。

## 代码路径与策略

- `probe_main.cpp` 用当前通话模板的 source ID 作为私呼下行过滤目标，并按模板 slot、呼叫类型筛选。`BmVoicePipeline::filter_accepts_datagram` 在进入 `dmr_call::Receiver` 前检查目的 ID、时隙和 private/group 标志；所以旧日志中的 `rejected_calls=0` 不能说明 Receiver 接受了回声。
- 根线程依据实际回包头，将三个单时隙 DIRECT 预设 `parrot-cn`、`parrot-global` 和 `listen-46001` 的 slot 修正为 TS2。预设 source/destination、Gateway ID 和 CC1 不变；手动配置仍保留操作者选择的时隙。
- 接收过滤仍限制本机目的 ID、所选时隙和呼叫类型；不会扩大到所有 Talkgroup 或两个时隙。`listen-46001` 仍禁止发射。
- 合成回归已确认：旧 TS1 filter 会过滤整条 TS2 流且不产生 call 事件；预设 TS2 filter 能产生 call-start、voice 和 call-end；其他目标 ID 和 group 呼叫仍被过滤。profile 测试确认三个 preset 都使用 TS2，手动选择 TS1 仍会发 TS1 header，46001 仍禁止发射。回归不模拟 HRI ready 或实际播放。

## 证据边界

已确认：该 BM Echo 服务对这次 TS1 私呼返回 TS2 private stream，目的为本机 source ID；TS1 filter 因时隙不符拒绝了全部 37 个包。已用有界网络测试证明控制会话达到 ready、合成 DMRD 发射调用成功、回声头元数据与 LC 一致且 RPTCL 本机 UDP send 成功。

尚未确认：HRI T3、音频设备播放、实体电台或 RF 行为。Receiver/pipeline 的协议事件不等于音频已播放。
