# BM PCM 与 DMR AMBE+2 声码器

日期：2026-10-24。任务：`BM-CODEC`。基线 app HEAD：`cc26db32913db45ff56068800d12f0b683dfd2f3`。本切片随步骤 1–3 核心实现形成独立本地 Git 检查点；该检查点是离线候选，不代表发布或真实 BM/HRI/RF 验收。

## 接口与数据边界

第一方接口位于 [`include/wirex/dmr_vocoder.hpp`](../../include/wirex/dmr_vocoder.hpp)，实现位于 [`src/dmr_vocoder.cpp`](../../src/dmr_vocoder.cpp)：

- 输入是 8 kHz、单声道、signed PCM16，每帧 160 个样本，正好 20 ms。
- `Encoder::encode` 输出 9 字节，即 AMBE+2 2450x1150 的 72-bit DMR 语音码字，包含语音参数和信道 FEC。它不是只有 49-bit 的语音参数。
- `Decoder::decode` 接收完整 9 字节 DMR 码字，返回 160 个 PCM16 样本、上游 FEC 纠错位计数和帧状态。
- 9 字节码字属于 DMR 语音单元；三个码字与其他字段组成 33 字节 burst 的工作留给 `dmr_call`。

编码器和解码器各自持有独立的 `MBEVocoder` 实例。每条连续 TX/RX 流应分别保留同一个对象，并在通话结束或断线后调用 `reset()`，或销毁并重新创建该对象。`reset()` 会重建本实例的编码/解码历史；TX 状态不会复用 RX 对象的历史。

上游解码器在非浊音合成中使用进程级 C `rand()`。适配器用互斥锁串行化自身的编码/解码调用，避免两个 codec 调用同时进入上游代码；各 RX 流仍共同消耗同一个随机序列，因此不同流的非浊音相位会受调用次序影响。声码器内部历史与该全局随机序列是两件事。

## 固定来源与许可证

固定上游为 [`nostar/DroidStar`](https://github.com/nostar/DroidStar/tree/becf1dede57c4a70a865e9cb4cac9247e505599a)，commit `becf1dede57c4a70a865e9cb4cac9247e505599a`。具体 57 个源文件/头文件、各文件上游与本地 SHA-256、URL 和本地补丁说明见 [`source-manifest.json`](../../third_party/droidstar_mbe/source-manifest.json)。源码位于 `third_party/droidstar_mbe/upstream/`；完整 GPL v3 文本附于 [`COPYING.GPL-3.0.txt`](../../third_party/droidstar_mbe/COPYING.GPL-3.0.txt)。

上游 `mbe/` 文件头逐个附有 ISC 许可文本。`imbe_vocoder/` 中 46 个文件带有 GPL-3.0-or-later 正文；其余 5 个固定提交文件分别保留了开发者/项目归属说明但没有 GPL 正文，`imbe_vocoder.cc` 也没有许可证头。上游 README 将该库说明为来自 OP25；因此本实现按包含 GPL 编码器源的组件处理，并在逐文件清单中标出缺少许可证正文的文件。分发前需要完成逐文件许可证审查，不能仅凭目录名认定每个文件的许可范围。

DVSI 的官方资料称 AMBE+2 受其知识产权保护，软件库按许可提供；本切片没有做专利法律意见，也没有把厂商固件、DLL、SDK 或硬件代码纳入仓库。可核对 [DVSI AMBE+2 技术页](https://www.dvsinc.com/soft_products/ambe_p2.shtml) 和 [DVSI 软件算法页](https://www.dvsinc.com/soft_products/software.shtml)。GPL 代码许可与 AMBE+2 专利/商业使用许可是不同问题。

本地只做了三处上游源码修正，原始文件头均保留，manifest 同时记录了修正前后哈希：

1. `mbe/mbevocoder.h` 和 `mbe/ambe.cpp` 显式引入标准 `stdlib.h`，避免 MSVC 构建依赖其他头文件偶然声明 `malloc/free/rand/RAND_MAX`。
2. `MBEVocoder` 增加 `decode_2450x1150_with_status`，返回上游已有的 FEC 计数、错误标记和样本数；旧 `decode_2450x1150` 继续走同一解码路径。
3. 状态接口在复制 PCM 前要求恰好 160 个样本；长度异常时输出静音并返回无效状态。它没有改写编码、FEC、交织、扰码或解码算法。

## FEC 状态与静音策略

`DecodeResult.status` 直接反映固定上游 `m_errs2` 和 `m_err_str` 的结果：

| 状态 | 上游含义 | PCM 行为 |
|---|---|---|
| `decoded` | 参数可解、没有报告 FEC 纠错位 | 返回上游解码 PCM |
| `corrected` | 上游报告并修正了 FEC 位 | 返回纠错后的 PCM，并保留纠错位数 |
| `tone` | 上游 `T` tone-frame 标记 | 返回上游 tone PCM |
| `concealed` | 上游 `R` 标记；纠错超出其阈值后沿用前帧参数 | 保留上游 concealment PCM |
| `erasure` | 上游 `E` erasure 标记 | 静音 |
| `muted_repeated_errors` | 上游 `M` 标记；连续坏帧达到上游静音条件 | 静音 |
| `invalid_parameters` | 输出样本数异常或出现未知上游标记 | 静音 |

适配器没有自行设置“FEC 错误超过 N 位就静音”的门限。上游对一次不可纠错帧先执行 `R` 帧隐藏，在错误持续时才进入 `M` 并静音。

DMR 72-bit 语音码字没有独立 CRC。解码器可以报告它观察到的纠错、erasure、tone、concealment 和 mute 状态，但不能证明任意 9 字节串的来源或完整性；某些随机位串也可能落在可解参数或 tone 码字上。调用方不能把 `decoded` 当作网络包认证或通话来源验证。

## Windows 构建和离线测试

MSVC x64 Release 使用 Visual Studio 2019 Build Tools，编译器 `19.29.30159.0`。正式离线构建入口会核对固定 DroidStar manifest 的 57 个本地 SHA-256，分别以 `/W0` 编译上游 codec 源、以 `/W4 /permissive-` 编译第一方源，并用 `/O2 /MT /EHsc /std:c++17` 从源码构建 native 候选和测试；不依赖旧的忽略文件夹内脚本或预编译 EXE。

在 app Git 根目录使用 Windows PowerShell 5.1 执行正式构建并运行离线测试：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-bm-bridge.ps1
```

产物位于 `build/_work/wirex-bridge-<commit>-<状态>-<UTC 时间>/`，含 `dmr_vocoder_test.exe`。也可用 `-CompileOnly` 仅构建，不运行离线测试。正式入口会一并重建原 `wirex_probe.exe`，但保持它原有链接清单。

codec 测试运行输出示例：

```text
DMR vocoder golden, upstream-decoder, reset, and FEC checks passed.
encode_20ms: n=512 avg=246.838us p50=246.300us p99=282.200us max=389.500us
decode_20ms: n=512 avg=94.701us p50=93.100us p99=116.400us max=254.100us
```

测试文件 [`tests/dmr_vocoder_test.cpp`](../../tests/dmr_vocoder_test.cpp) 覆盖连续静音与确定三角波的固定 9 字节黄金序列、与直接调用固定上游 `MBEVocoder` decoder 的 PCM 逐样本比较、独立 TX 状态、TX/RX reset、单 bit FEC 修正、不可纠错 `R` conceal、连续错误后 `M` 静音和 `E` erasure 静音。测试向量来自固定上游源码的本地源代码对照和合成错误帧，不是空口录制或独立 DVSI 编码器参考；这些测试不作为 BrandMeister、设备互通或语音听感证据。

声码器独立切片当时没有修改 `CMakeLists.txt`，也没有把声码器接入 native 主程序、HRI 或 BM 网络；当前集成范围和正式构建结果见 BM 联调推进。整合候选的离线测试仍不证明真实 BM、COM/WinMM 音频或 FTX-1 实机通过。
