<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# DMR signal implementation notices

`dmr_signal.cpp` is a reworked implementation of selected DMR signaling and FEC algorithms. It does not contain the upstream source files verbatim and does not contain a vocoder. The copyright notices below are retained for the specific upstream components used.

## MMDVM_CM

Source: [`juribeparada/MMDVM_CM`, commit `7328c9e9532d29cf4d9d7d24541d57f825207be4`](https://github.com/juribeparada/MMDVM_CM/tree/7328c9e9532d29cf4d9d7d24541d57f825207be4/USRP2DMR). The referenced source files state GNU GPL version 2 or, at the recipient's option, any later version. This implementation is distributed under GPL-3.0-or-later under that grant. The full selected license text is in [`COPYING.GPL-3.0.txt`](COPYING.GPL-3.0.txt).

The source copyright notices retained for the used components are:

| Source files | Original notices |
| --- | --- |
| `BPTC19696.cpp`, `DMRFullLC.cpp` | `Copyright (C) 2012 by Ian Wraith`; `Copyright (C) 2015 by Jonathan Naylor G4KLX`; those files carry the GPL version 2-or-later notice. |
| `DMRSlotType.cpp`, `Golay2087.cpp`, `DMREMB.cpp`, `Hamming.cpp`, `QR1676.cpp`, `DMRDefines.h` | `Copyright (C) 2015,2016 by Jonathan Naylor G4KLX`; these files carry the GPL version 2-or-later notice. |
| `DMREmbeddedData.cpp` | `Copyright (C) 2015,2016,2017 by Jonathan Naylor G4KLX`; the file carries the GPL version 2-or-later notice. |
| `RS129.cpp` | `Copyright (C) 2015 by Jonathan Naylor G4KLX`; the file carries the GPL version 2-or-later notice. |
| `CRC.cpp`, `Sync.cpp` | `Copyright (C) 2015,2016 by Jonathan Naylor G4KLX`; `Copyright (C) 2018 by Andy Uribe CA6JAU`; these files carry the GPL version 2-or-later notice. |

No MMDVM_CM source file is included in this directory. The local implementation reworks the listed algorithms and retains the applicable author notices here and in the `dmr_signal.cpp` header.

## DroidStar

Source: [`nostar/DroidStar`, `dmr.cpp` at commit `becf1dede57c4a70a865e9cb4cac9247e505599a`](https://github.com/nostar/DroidStar/blob/becf1dede57c4a70a865e9cb4cac9247e505599a/dmr.cpp). The relevant 33-byte AMBE placement and extraction in that file carry the notice `Copyright (C) 2019-2021 Doug McLain` and are distributed under GNU GPL version 3 or, at the recipient's option, any later version. The local code reworks that payload layout; the full selected license text is in [`COPYING.GPL-3.0.txt`](COPYING.GPL-3.0.txt).

## AMBE+2 2450 参数映射

`include/wirex/ambe2450_parameters.hpp` 定义本项目使用的 12+12+25 位参数结构。`src/ysf_vd2_vch.cpp` 和 `src/ambe_dmr72.cpp` 分别实现 YSF V/D Mode 2 的 13 字节 VCH 映射，以及 DMR 的 9 字节码字映射。两个本地实现重新组织了位操作；下表记录算法、掩码和测试常量所参考的固定上游文件及其 SHA-256。

| 本地用途 | 固定上游来源 | 原始许可和版权 | 上游 SHA-256 |
| --- | --- | --- | --- |
| YSF VCH 白化、交织、A/B/C 位映射；`DMR_SILENCE`、`YSF_SILENCE` 常量及五 VCH/三 DMR 码字分组 | [`MMDVM_CM/YSF2DMR/ModeConv.cpp`](https://github.com/juribeparada/MMDVM_CM/blob/7328c9e9532d29cf4d9d7d24541d57f825207be4/YSF2DMR/ModeConv.cpp), commit `7328c9e9532d29cf4d9d7d24541d57f825207be4` | Copyright (C) 2010, 2014, 2016 and 2018 Jonathan Naylor G4KLX; Copyright (C) 2016 Mathias Weyland HB9FRV; Copyright (C) 2018 Andy Uribe CA6JAU; GPL-2.0-or-later | `b2f7a4a82ec64f169e5d98fcb34e17994611d7ebcc94d1774bcb35dfe5ce8844` |
| YSF V/D2 五段 VCH 处理的交叉核对 | [`DroidStar/ysf.cpp`](https://github.com/nostar/DroidStar/blob/becf1dede57c4a70a865e9cb4cac9247e505599a/ysf.cpp), commit `becf1dede57c4a70a865e9cb4cac9247e505599a` | Copyright (C) 2019-2021 Doug McLain; GPL-3.0-or-later | `39b58855c77cba760d463a200b44d7d8af282bb9f19d5df1169d9eb74add5497` |
| DMR A/B Golay 生成掩码 | `DroidStar/mbe/mbevocoder.cpp`, commit `becf1dede57c4a70a865e9cb4cac9247e505599a` | Copyright (C) 2010 mbelib Author; ISC | 上游 `7464a9d9cb27a7ab04eb3bf65b725268ddaefc6d85e4666ef600b568a76b07b1`；本地改动版 `4d6bc0459ecc52d818367ffa96f3fdc71bd59eb20b01580a02446deb9350fbcb` |
| DMR B 字段 PRNG 表 | `DroidStar/mbe/vocoder_tables.h`, commit `becf1dede57c4a70a865e9cb4cac9247e505599a` | Copyright (C) 2010 mbelib Author; ISC | `3ef6900a2e0f47c50e1fda1b4912f76a819348467d810223b5858684da0e727a` |

MMDVM_CM 文件允许选择 GPL version 2 或后续版本；本项目对这些组合实现选择 GPL-3.0-or-later，并保留其原始许可声明。完整 GPL-3.0 文本见本目录的 [`COPYING.GPL-3.0.txt`](COPYING.GPL-3.0.txt)。DroidStar MBE 的完整 ISC 许可见 [`../droidstar_mbe/ISC-NOTICE.txt`](../droidstar_mbe/ISC-NOTICE.txt)，逐文件上游和本地哈希见 [`../droidstar_mbe/source-manifest.json`](../droidstar_mbe/source-manifest.json)。

测试和 `voice_transcode_buffer.cpp` 中的 `YSF_SILENCE`、`DMR_SILENCE` 是固定源码常量，不是实机捕获。YSF 侧另外四组输入/输出是由固定映射规则离线生成；DMR 侧八组 9 字节值来自本项目 `tests/dmr_vocoder_test.cpp` 的全零 PCM 冻结编码序列。分组缓冲测试复用这些固定位向量检查 FIFO 顺序和显式结束填充。这些 fixture 不含呼号、用户语音、网络包或电台数据。

`COPYING.GPL-3.0.txt` is the complete GNU General Public License version 3 text. The original upstream notices and license grants remain applicable; no upstream author's work is represented as first-party code.
