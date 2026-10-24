# BM 语音管线与重采样

日期：2026-10-24。范围：纯软件模块 `include/wirex/bm_voice_pipeline.hpp`、`src/bm_voice_pipeline.cpp`、`include/wirex/pcm_resampler.hpp` 与 `src/pcm_resampler.cpp`。本切片没有修改 `CMakeLists.txt`、`probe_main.cpp`、HRI/COM、WinMM、BM socket session 或 UI，也没有访问真实 BM、音频设备、串口或 RF。

## 模块边界

`BmVoicePipeline` 在 48 kHz 单声道 PCM16 与 `dmr_call::Transmitter`/`Receiver` 之间运行已选定的 [AMBE+2 编解码器](BM声码器实现.md)。网络侧每个 DMRD voice burst 的 33 字节负载由三个 9 字节码字组成。BM session 将 `take_outbound()` 返回的 datagram 交给自己的 `send_dmrd()`；管线本身不创建 socket，也不调用 HRI。

调用者统一传入 `std::chrono::steady_clock::time_point`。运行期负责把 BM/HRI 实际状态放入 `Readiness`；只在 `bm_ready` 和 `hri_ready` 都为真时，`begin_tx()` 才开始发通话头。调用者在 native 层限制总运行时间；pipeline 没有固定 8 秒或 20 秒的音频时长假设。

上行每次最多接受 4800 个 48 kHz 样本（100 ms）。管线保留 TX 编码状态，把重采样后的样本累计成 160 样本/20 ms 帧，并以 3 帧组成 60 ms DMRD burst。起播前至少缓冲 6 个码字（120 ms PCM），可容纳两次 100 ms WaveInput 分块的交错；凑够后 60 ms 才发送首个 voice burst。

起播后 TX/RX 都按绝对 60 ms deadline 推进，每次 `tick()` 最多处理一个 burst。最多 20 ms 的调度抖动不会让后续 deadline 漂移；迟到 20–120 ms 时只处理一个 burst，并从实际处理时间重新安排 60 ms；积压语音超过 120 ms 时，TX 以 `deadline_missed` 结束通话并只保留一个 EOT，RX 以同一错误清除过期媒体，由外层完成 HRI 收尾。空队列不会发静音 burst，也不会让下一包为了追赶而紧贴前一包发送。

- `end_tx()` 停止接收新 PCM，排出降采样滤波器尾部，将不足 160 样本的最后一帧补静音，最后补齐 3 码字 burst，再按 60 ms 节奏发完并输出 terminator-with-LC。
- `stop_tx()` 用于 BM 仍在线时用户主动停止：立即丢弃未发 PCM、码字和 voice datagram，若 LC header 尚在 pipeline 队列则保留它，然后输出至多一个保持当前 stream ID 和 DMRD sequence 的 terminator-with-LC。
- `cancel_tx()` 用于 BM 断线等无法发送 EOT 的情形，只清除本地队列和 transmitter 状态，不伪造成功 EOT。

## 下行呼叫与 HRI 播放

`ingest_rx()` 先按 DMRD 的目标 ID、时隙和 group/private 标志应用 `ReceiveFilter`，再交给 `dmr_call::Receiver` 校验 DMR 通话控制字段；处理 Receiver 事件时还按 `CallConfig` 再过滤一次。未选中的 TG/TS 数据报不会打断当前播放流，也不会让另一个时隙的 EOT 结束当前通话。

收到通过 filter 的 `call_started` 后，事件队列产生 `receive_started`，其中包括 LC 校验状态、颜色码已知状态和播放代次。外层收到事件后启动 HRI T3；只有 HRI 确认开始成功才调用 `playback_ready()`。此前管线保留媒体，不把头几帧送出。最多保留 50 个 voice burst，即 3 秒启动缓冲；自 `receive_started` 起 3 秒仍未 `playback_ready()` 时会清队列并产生 `playback_start_timeout`。HRI 启动失败时，外层应立即 `cancel_rx()`，无需等到超时。

启动播放后仍使用 50-burst 上限；管线同时按 20 ms 等效帧统计待解码 burst、待取 PCM、HRI 已取但未确认播放的 PCM，以及丢包补偿帧，总量不超过 150 帧（3 秒）。另有 150 个 playback slot 的固定 heap 队列，约 288 KB；该存储不会放在 native 线程栈上。每次 `tick()` 至多解码一个 60 ms burst，输出三个 20 ms 帧，不会一次把几秒预缓冲推入 WinMM。至少缓冲两个 burst（120 ms）后开始正常播放；短通话在网络结束后可以排空剩余 burst。

`take_playback_pcm(PlaybackFrame&)` 只把一帧 PCM 交给 HRI，不代表声卡已经播放。每帧包含最多 960 个 PCM16 样本、实际 `sample_count` 和 `generation`。一个 HRI 20 ms frame 完成 `WHDR_DONE` 后，外层按该 buffer 保存的 generation 调用 `acknowledge_playback(generation, 1, now)`。最多允许 3 个未确认帧。

DMRD terminator 或 `dmr_call::Receiver` 的 360 ms watchdog 会发出 `network_ended`，之后按 60 ms 时间线补偿最多 4 个缺失 burst。最后一个 RX burst 完成后，插值器排出 126 个 48 kHz 滤波尾样本；尾块可能短于 960 样本，外层按 `PlaybackFrame.sample_count` 只提交有效长度。只有网络已结束、burst/PCM 队列已空且所有 in-flight frame 均收到硬件完成确认后，管线才发出 `playback_drained`。外层在该事件及 HRI 队列清空后才发送 HRI T0。

`cancel_rx()` 会清空软件 PCM、burst 和 in-flight 计数，并递增接收代次。它不能撤回已经交给 WinMM 的 WAVEHDR，因此外层断线或取消时还需 `waveOutReset`/清空其硬件队列。旧 `WHDR_DONE` 若在新通话开始后迟到，generation 不匹配会返回 `stale_playback_ack`，不会减少新通话的 in-flight 数。generation 跨 `reset()` 单调递增且不会复用；到达 `uint64_t` 上限后，新接收流返回 `generation_exhausted`，调用者需重建进程。

## 48 kHz 与 8 kHz 重采样

两个方向共用一个 127 tap、Blackman 窗、3.5 kHz 截止频率的低通 FIR 系数。48→8 kHz 路径保留历史和六分频相位，每 6 个输入样本输出 1 个滤波样本；结束时补 126 个零输入排出尾部。8→48 kHz 路径用六相 polyphase 插值，每个 8 kHz 输入样本产生 6 个滤波样本；结束时补 21 个低速率零样本，排出 126 个 48 kHz 尾样本。两类重采样器都保留跨输入块的滤波状态；调用 `reset()` 才开始新流。

## MSVC Release 离线验证

克隆后使用仓库正式构建入口。它从固定源码重新构建 WIREX/BM 模块和各离线测试，不安装系统依赖；构建与测试产物写入新的 `build/_work/` 子目录。

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-bm-bridge.ps1
```

本次模块开发另用 Visual Studio 2019 x64 MSVC `19.29.30159.0` 的隔离脚本单独构建了 `dmr_call`、`dmr_signal`、固定 MBEVocoder 源码、重采样器与 pipeline；第一方 C++ 使用 `/O2 /MT /EHsc /std:c++17 /W4 /permissive-`，未见编译警告。单项临时构建目录位于 ignored `build/_work/`，不作为克隆后的构建入口。

重采样测试检查：1 秒 1 kHz 输入通过、6 kHz 下采样混叠被压低（本次整数 PCM 的测量 RMS 为 0）、直流均值、首尾样本计数、分块大小变化不会改输出、8→48 kHz 插值输出恰好为 6 倍输入样本并带 126 个尾样本。本次 48→8 kHz 输出 8,021 个样本（48,000 个输入加 21 个滤波尾样本），1 kHz 输出 RMS 为 8485.81，直流均值为 12000。

pipeline 测试使用真实 codec 与 `dmr_call`，但虚拟单调时钟和合成 PCM。它检查 BM/HRI readiness 门控、上行 60 ms 节奏和 EOT、主动 stop 与断线 cancel 的差别、TX/RX 背压、合法 TG/TS/call-kind filter、活动通话期间插入其他 TG/TS 的 header/voice/EOT、3 秒 HRI 启动窗口及 1 秒延迟、2-burst prebuffer、RX burst/PCM 总缓冲上限、EOT/360 ms 丢 EOT watchdog、尾帧 filter drain、HRI hardware ack、取消后重入和迟到旧 generation ack。另有 120 秒输入测试：每 100 ms 输入 4800 个样本，tick 以 7/11 ms 交替推进；每 60 ms 发一个 burst，即约 16.67 个 burst/s（每秒 50 个 20 ms 码字）。本次测试发出 1,996 个 burst，首末发送时间相差 119,700 ms，TX 码字队列峰值 13 个。一次 70 ms 延迟能继续按 60 ms 稳定发送；一次 2 秒停顿会报错并只输出 EOT，不会连续喷出陈旧语音。

`tests/bm_bridge_loopback_test.cpp` 将生产 BM Session、WinSock UDP transport、声码器、DMR call、pipeline 和 HRI T3/T0 session 串在一起。localhost fake Master 完成真实 UDP 登录，接收 TX 编码语音与 EOT，并向 production session 回送合成 DMRD；fake HRI 记录 T3/T0 写入，PCM sink 逐帧模拟 `WHDR_DONE`。测试覆盖 EOT 在 T3 许可前到达、等 1 秒 T3 后完整播放和最后一帧 ack 后才发 T0、private-call Echo 目标 ID 筛选、丢 EOT watchdog、断线后旧 generation ack 被拒绝，以及用户取消 TX 后先发 EOT 再发 RPTCL。测试只使用 localhost UDP、合成 PCM 和假 HRI/音频回执，没有运行真实 WinMM、COM、BM 服务或 RF。

`acknowledge_playback()` 本身只验证外层报告的完成帧数量和 generation；MSVC 离线测试以函数调用模拟该回执，没有运行 WinMM。该模块切片撰写时尚未接入 native；当前 native 组合及正式构建结果见 [BM 联调推进](BM联调推进.md)。localhost loopback 不证明真实 HRI、BM 服务器、COM、音频播放设备或 RF 联调通过。
