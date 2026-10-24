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

`COPYING.GPL-3.0.txt` is the complete GNU General Public License version 3 text. The original upstream notices and license grants remain applicable; no upstream author's work is represented as first-party code.
