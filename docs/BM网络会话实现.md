# BrandMeister Homebrew 网络会话实现

## 范围和状态

本切片实现 Homebrew/MMDVM 登录状态机、DMRD 入口与出口、Windows UDP transport，以及只绑定 localhost 的 fake Master 测试。状态机不创建线程或 socket；调用方传入单调毫秒并收发队列中的 UDP 数据报。`probe_main.cpp`、`CMakeLists.txt`、HRI、UI 和 RF 路径没有接入本切片。

实现基线为 `cc26db32913db45ff56068800d12f0b683dfd2f3`。代码和两项离线测试已经在 `build/_work/bm-session` 编译并运行成功；这只证明本机编译、合成协议处理和 loopback UDP 行为，不代表真实 BrandMeister 登录、FTX-1 联调、codec 或电台/RF 验收。

## 接口与状态

- `wirex::bm::Session::start()` 接管 Profile 和固定 IPv4 Master endpoint；`on_datagram()` 检查来源端点、阶段、长度和 ID；`tick()` 驱动重试、超时、保活及退避；`stop()` 结束会话。
- `take_outbound()` 交出待发控制包或应用包。ready 前 `send_dmrd()` 拒绝发送；ready 后它只接受 55 字节且以 `DMRD` 开头的数据报。ready 状态收到同样严格检查的 DMRD 后，调用方用 `take_received_dmrd()` 取出。
- `Snapshot` 仅提供状态、最后故障类别、计时点和排队数量；模块没有日志接口，不记录凭据、RPTK、DMRD 正文或语音 payload。收到超时、拒绝、畸形包、传输故障、队列溢出或 stop 后，排队的应用数据立即清除，重连不会回灌旧语音。
- Profile 的固定文本字段限制为 ASCII 和各自协议宽度；呼号最多 8 字符，Color Code 为 0–15。RPTC 总长固定 302 字节。IPv4 endpoint 必须包含非零地址和端口，DNS 名称解析由未来调用方负责。
- 运行期 password 由 move 传入后保留至 `stop()` 或析构，以便退避后重新认证；每次哈希后立即清零 `salt || password` 临时输入、哈希临时对象和 digest，stop 或析构时覆盖清零内部 password 缓冲。接口、快照和 transport 都不提供打印 secret 的路径。

## Homebrew/MMDVM 报文策略

| 报文 | 本实现检查和动作 |
|---|---|
| `RPTL` | 4 字节标记加 4 字节大端 gateway ID，共 8 字节。登录阶段每 10 秒重发。 |
| challenge `RPTACK` | 只接受精确 10 字节；最后 4 字节作为 salt，发送 `RPTK`。哈希输入是 `salt[4] || password bytes`，由系统 BCrypt SHA-256 计算。 |
| 后续 `RPTACK` | 等待认证、配置、options 的阶段分别只允许下一步。接受 6 字节标记形式，或 10 字节且附带匹配 gateway ID 的形式；ready 后合法重复确认会被忽略，错误 ID 会断开并退避。 |
| `RPTK` | 4 字节标记、4 字节大端 gateway ID、32 字节 SHA-256，总长 40 字节。 |
| `RPTC` | 固定 302 字节；采用 MMDVM_CM/DroidStar 的字段顺序和固定宽度。 |
| `RPTO` | 8 字节标记和 gateway ID 前缀，再加 0–292 个可打印 ASCII options 字节；非空 options 要等下一次确认后才进入 ready。 |
| `RPTPING` / `MSTPONG` | 每 10 秒发 11 字节 RPTPING；只接受精确 11 字节、来源正确且 ID 匹配的 MSTPONG。60 秒没有有效 pong 则退避。 |
| `MSTNAK` | 接受 6 字节标记形式，或 10 字节且 ID 匹配的形式；两种情况均作为 Master 拒绝处理。 |
| `MSTCL` | 接受 5 字节标记形式，或 9 字节且 ID 匹配的形式；作为 Master 关闭处理。 |
| `RPTCL` | stop 时只有 ready 会话发送；总长 9 字节，包含 5 字节标记和 gateway ID。 |
| DMRD | 收发都检查精确 55 字节和 `DMRD` 标记；收包仅在 ready 且来源 endpoint 正确时交给调用层。 |

固定 MMDVM_CM `DMRNetwork.cpp` 使用六字节前缀判断后续 `RPTACK` 和 `MSTNAK`，以及五字节前缀判断 `MSTCL`，代码没有验证这些应答的总长度。因此本实现把 6/5 字节形式保留为兼容项，并同时支持 HomeBrew 常见的 ID-bearing 10/9 字节应答。后续 10 字节 RPTACK 与 MSTNAK、9 字节 MSTCL 必须匹配本地 gateway ID。固定 MMDVM_CM 源在校验报文阶段、长度和来源 endpoint 上不够严格，不能据此推导出服务器对所有合法报文长度的完整规范。

Sources:

- `juribeparada/MMDVM_CM`, commit `7328c9e9532d29cf4d9d7d24541d57f825207be4`, [`USRP2DMR/DMRNetwork.cpp`](https://github.com/juribeparada/MMDVM_CM/blob/7328c9e9532d29cf4d9d7d24541d57f825207be4/USRP2DMR/DMRNetwork.cpp)
- `nostar/DroidStar`, commit `becf1dede57c4a70a865e9cb4cac9247e505599a`, [`dmr.cpp`](https://github.com/nostar/DroidStar/blob/becf1dede57c4a70a865e9cb4cac9247e505599a/dmr.cpp)
- `HBLink-org/hblink3`, commit `1db27305c29024a47f6c2243cb44c5df47198c13`, [`hblink.py`](https://github.com/HBLink-org/hblink3/blob/1db27305c29024a47f6c2243cb44c5df47198c13/hblink.py) lines 397, 401, 418, 422, 434, 459, 471 and 482 show challenge salt, ID-bearing acknowledgements, rejection, close, and keepalive responses.

## 时限、传输和排队

每个登录阶段每 10 秒重发当前请求，60 秒无阶段确认便清除队列并进入退避。失败退避从 1 秒开始按指数增加，最大 30 秒；ready 后每 10 秒发 RPTPING，60 秒无有效 pong 即视为传输失联。调用方若 WinSock 发送或接收返回 socket error，应调用 `transport_lost()`；backoff 到期后 Session 输出新 RPTL，调用方负责让 UDP transport 可用。

Outbound 与 inbound 应用队列最多各 128 个数据报。队列溢出会记录具体 failure 并退避；超时、拒绝、畸形应答、错误 peer ID、transport loss 和 stop 都清空应用队列。stop 只在 ready 状态排入 RPTCL，并在 stop 时清除内存中的 password。模块不自行开始上行，也不会周期性生成 DMRD；未来主循环只应在经过上层发送请求后调用 `send_dmrd()`。

`UdpTransport` 用 WinSock2 非阻塞 UDP socket。每次 `receive()` 都通过 `select()` 等待，实际等待上限 100 ms；接收缓冲区为 2048 字节，超大数据报明确返回 oversized 结果。socket 收到任意来源的数据都交给调用方，Session 再与已配置的 IPv4 和端口逐项比较。

## 复现

使用本机 VS 2019 Build Tools；本切片不新增依赖。以下命令把可执行文件和中间文件写入 `build/_work/bm-session`，不改动 CMake 或 probe。

```powershell
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = (& $vswhere -all -products '*' -version '[16.0,17.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1).Trim()
$vcvarsall = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
New-Item -ItemType Directory -Path 'build\_work\bm-session' -Force | Out-Null
& $env:ComSpec /d /s /c ('call "{0}" amd64 >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include /Fo:build\_work\bm-session\ /Fe:build\_work\bm-session\bm_session_test.exe tests\bm_session_test.cpp src\bm_session.cpp /link bcrypt.lib' -f $vcvarsall)
if ($LASTEXITCODE -ne 0) { throw 'bm_session_test compile failed' }
& 'build\_work\bm-session\bm_session_test.exe'
if ($LASTEXITCODE -ne 0) { throw 'bm_session_test failed' }
& $env:ComSpec /d /s /c ('call "{0}" amd64 >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include /Fo:build\_work\bm-session\ /Fe:build\_work\bm-session\bm_udp_test.exe tests\bm_udp_test.cpp src\bm_udp.cpp src\bm_session.cpp /link bcrypt.lib ws2_32.lib' -f $vcvarsall)
if ($LASTEXITCODE -ne 0) { throw 'bm_udp_test compile failed' }
& 'build\_work\bm-session\bm_udp_test.exe'
if ($LASTEXITCODE -ne 0) { throw 'bm_udp_test failed' }
```

实际结果：`bm_session_test` 输出 `All BM session state-machine checks passed.`；`bm_udp_test` 输出 `All BM loopback UDP checks passed.`。测试使用临时 fake password、127.0.0.1 与动态端口，覆盖 SHA-256 golden vector、RPTC/RPTO 字节、ACK 阶段和 ID、超时退避、queue 清理、DMRD 收发、WinSock 实际超时、超长数据报、Master 拒绝/关闭、来源端点伪造和有序 RPTCL 退出。测试没有打开 HRI/音频/RF 设备，也没有连接真实 Master。
