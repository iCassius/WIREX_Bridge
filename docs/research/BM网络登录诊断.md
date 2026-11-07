# BM 4602 网络登录诊断

本文保留旧 RPTC profile 的四轮拒绝记录，并补充 2026-10-24 对照 DroidStar/DMRHost 配置后的 A、D、E1、E2、E3 有界 network-only 结果。旧 profile 全部收到 `MSTNAK`；E3 组合 profile 到达 `ready` 并由诊断工具本机 UDP 发送 `RPTCL` 成功。E3 只验证 BM 控制配置阶段，不代表已完成 DMR Echo 语音、HRI/COM、WinMM 或 RF 联测。

用户确认其 Android 成功登录 BM 的客户端是 DroidStar；截图 Gateway ID 为 `460999902`。本轮配置对照使用用户授权的独立 Gateway ID `460999901`，没有修改或复用 ESSID `02` 的配置。

## 范围与基线

- 仓库探测基线：`d8ae96d90c5887d7fe70ce4d66d77ae73637702f`。BM + FTX-1 候选代码来自其祖先提交 `17f3433ae4cd6820622033ddb1910c030cb260f2`。
- 目标：BM 4602，`43.129.83.124:62031`。探测直接使用这个 IP，不经 DNS。
- 四次都链接当前生产 `wirex::bm::Session` 与 `UdpTransport`，单次 deadline 为 15 秒；实际每次不到 1 秒就收到拒绝并结束，第三次运行 0.567 秒，第四次运行 0.588 秒。探测每种控制包最多发送一次，不自动循环重试。
- 没有启动 native bridge、COM、WinMM、PTT 或 RF；没有发 `RPTO`、TG、DMRD 或语音，也没有收到成功后的业务数据。密码只从本机被 `.gitignore` 排除的私有文件读取；正文、盐、challenge 字节、摘要和认证载荷均未记录。
- 四次探测都由同一份生产 `Session` 状态机处理。没有修改 `src/bm_session.cpp` 或 `src/bm_udp.cpp`。
- 执行的绝对时刻没有由 probe 记录，本文保留日期和已知的实际耗时，不补造时间戳。

用户另提供了旧 aec0471 候选的一次 native 会话日志：会话约 26.6 秒，期间有五次 BM 登录尝试；每次都通过 challenge/auth ACK，但旧 RPTC profile 收到 `MSTNAK`，BM 从未进入 `ready`。该次会话确实打开 COM/HRI，用户观察到 BM 红 X/PTT 状态；日志中的 HRI/Y0 控制握手耗时约 1.125 秒，BM TX/RX 与音频计数均为 0。HRI 控制握手和用户界面观察不代表 BM DMRD 语音通话成功。这些记录对应 E3 之前的 profile，不代表当前可接受的 RPTC 元数据。

## 历史：旧 profile 的四次配置与实测结果

四次使用相同呼号和 gateway ID（RadioID 信息已由用户核实）。第一次复制当时 native 的 DIRECT 配置；第二次只改变坐标字符串格式；第三次复制第二次配置，仅把 RX/TX frequency 从零改成用户提供的 145.100 MHz 元数据；第四次复制第三次配置，仅把 color code 从 0 改成 1。后两次没有修改电台配置或发射 RF。

| RPTC 字段 | 第一次 | 第二次 | 第三次 | 第四次 |
| --- | --- | --- | --- | --- |
| callsign / gateway ID | `N0CALL` / `460999901` | 相同 | 相同 | 相同 |
| RX/TX frequency | `0` / `0` | `0` / `0` | `145100000` / `145100000`（145.100 MHz） | 相同 |
| power / color code | `0` / `0` | 相同 | 相同 | `0` / `1` |
| latitude / longitude | `0` / `0`，按字段宽度补尾部空格 | `0.000000` / `00.000000` | 相同 | 相同 |
| height / slot flags | `0` / `'4'` | 相同 | 相同 | 相同 |
| location / description | `DIRECT` / `FTX-1` | 相同 | 相同 | 相同 |
| URL / version / software | 空 / `1.0` / `WIREX Bridge` | 相同 | 相同 | 相同 |
| options | 空 | 空 | 空 | 空 |

四次都收到相同的控制交换：

1. 发送 `RPTL` 8 字节；收到 `RPTACK` 10 字节 challenge，生产状态机接受。
2. 发送 `RPTK` 40 字节；收到 `RPTACK` 10 字节。仅在内存中比较其尾部是否匹配 challenge 或 gateway ID；结果为 `matches_salt=false`、`matches_gateway=true`，生产状态机接受。
3. 发送 `RPTC` 302 字节；收到 `MSTNAK` 10 字节，生产状态机返回 `InputResult=master_rejected`、`Failure=master_rejected` 并进入 `backoff`。

第二次仅改变坐标字符串，仍收到 `MSTNAK`。第三次仅相对第二次改变 RX/TX frequency 后仍被拒绝；第四次仅相对第三次把 color code 改为 1，仍收到 `MSTNAK`。四次都从未进入 `ready`，因此没有发送 `RPTCL`。

这组证据表明 UDP 往返和 RPTL/RPTK 认证阶段都已推进到配置提交；不能把失败归因于登录 challenge 长度、RPTK 长度或认证 ACK 的 ID 检查。第三轮说明只改频率不足以让 profile 被接受；第四轮说明只改 color code 也不足以让 profile 被接受。Master 在 RPTC 后拒绝了配置，但 `MSTNAK` 没有提供可识别的具体字段错误原因。当前不能确定是哪个 RPTC 字段或服务端策略触发拒绝。

## 实现与公开默认值对照

BrandMeister 的 [DMRHost `DMRNetwork.cpp`](https://github.com/BrandMeister/DMRHost/blob/dev/DMRNetwork.cpp) 与其采用的 MMDVM Homebrew 客户端流程使用 8 字节 `RPTL`、40 字节 `RPTK` 和 302 字节 `RPTC`。其中 RPTC 坐标由数值转换为固定小数格式；零值会形成 `0.000000` 和 `00.000000`。第一次的 `"0"` 补空格与此格式不同，第二次已按此格式发送，但 Master 仍拒绝 RPTC。

DMRHost 的网络对象构造函数会把 RX/TX frequency、power、color code、latitude、longitude 和 height 初始化为零，随后由 `setConfig()` 写入配置。这个客户端的内存初值不能证明服务器接受以这些零值发送的 RPTC，也不能证明生产配置应该保留零值。

[DroidStar 的 `dmr.cpp`](https://github.com/nostar/DroidStar/blob/main/dmr.cpp) 采用相同的 302 字节布局。它把频率同时写入 RX/TX 字段，把 power 和 color code 写成 `1`，height 写成 `0`，slot flags 写成 `'4'`，并把 software ID 与 package ID 放在 RPTC 尾部。[DroidStar 的设置默认值](https://github.com/nostar/DroidStar/blob/main/droidstar.cpp) 包括 latitude/longitude 字符串 `"0"`、频率 `438800000`、URL `www.qrz.com`、software ID `20200922`、package ID `MMDVM_MMDVM_HS_Hat`；连接时坐标会先转成数值再格式化。其 [README](https://github.com/nostar/DroidStar) 也明确提示，不同服务器对 DMR 配置字段的要求可能不同。

这些是公开客户端的组包方式和本地默认值，不是 BM 4602 接受某一字段值的服务器端证明。本文没有修改 `WIREX Bridge` 标识来冒充 MMDVM/DroidStar，也没有把 DroidStar 默认值当成 BM 必须值。

### RPTC 尾部字段的实现语义

用户确认此前成功登录 BM 的 Android 客户端是 DroidStar；当时保存的实际 `Software ID` / `Package ID` 值未提供，不能假设其使用了上游默认值。DroidStar 上游默认 `Software ID=20200922`、`Package ID=MMDVM_MMDVM_HS_Hat`，并将这两个字符串写入 RPTC 尾部的两个 40 字节字段。[BM 自有 DMRHost 的 `DMRNetwork.h`](https://github.com/BrandMeister/DMRHost/blob/dev/DMRNetwork.h#L28-L68) 将相应成员命名为 `m_version` 和 `m_hwType`；其 [`MMDVMHost.cpp`](https://github.com/BrandMeister/DMRHost/blob/dev/MMDVMHost.cpp#L631-L676) 传入主机软件 `VERSION` 与实际调制解调器的 `getHWType()`，[`DMRNetwork.cpp`](https://github.com/BrandMeister/DMRHost/blob/dev/DMRNetwork.cpp#L492-L529) 再把它们写入这两个字段。因此，标准 MMDVMHost 实现把这两项作为软件版本和硬件类型发送；DroidStar 使用的是自己的 Software ID / Package ID 命名与默认值。

旧 WIREX profile 的 `version="1.0"` 写入第一个字段，`software="WIREX Bridge"` 写入第二个、即 DMRHost 称为 `hwType` 的字段。这可能影响 BM 配置接受度，但早期 A profile 即使只把第二字段改成 `MMDVM_MMDVM_HS_Hat` 仍被拒绝，因而不能把该字符串单独认定为旧拒绝原因。E 系列的结果和已接受的虚拟节点标识见下文。不能据 DroidStar 默认值把本软件标成物理 `MMDVM_MMDVM_HS_Hat`。

## 当前对照：A、D 与 E 系列配置

这些对照都使用生产 `Session`/`UdpTransport` 向固定 BM 4602 发送控制包，使用呼号 `N0CALL`、Gateway ID `460999901` 和同一份本机凭据。它们没有打开 native 桥接、COM、WinMM，也没有发送 DMRD 或语音。A 是旧 WIREX profile 的一次变体；D 是完整 DroidStar 参数参考；E1–E3 从 D 逐项改成适用于本程序的虚拟节点元数据。

| 配置 | 相对前项的差异 | 关键 RPTC 字段 | 观测结果 |
| --- | --- | --- | --- |
| A | 旧 WIREX profile 仅将第二个 40 字节尾字段替换成 `MMDVM_MMDVM_HS_Hat` | 旧频率 `0`/`0`、power `0`、CC `0`、坐标字符串 `0`/`0`、version `1.0` | RPTC 后 `MSTNAK` |
| D | 完整 DroidStar 参数参考 | 438800000/438800000、power `1`、CC `1`、`0.000000`/`00.000000`、URL `www.qrz.com`、version `20200922`、第二字段 `MMDVM_MMDVM_HS_Hat` | Session 到达 `ready` |
| E1 | 仅把 D 的第二个 40 字节字段改为 `MMDVM_WIREX_Bridge` | 其他字段与 D 相同 | 到达 `ready`；诊断工具报告本机 UDP `RPTCL` send 成功 |
| E2 | 仅把 E1 的第一个 40 字节字段改为 `20261024` | 其他字段与 E1 相同 | 到达 `ready`；诊断工具报告本机 UDP `RPTCL` send 成功 |
| E3 | 仅把 E2 的 power 从 `1` 改成 `0` | 其他字段与 E2 相同 | 到达 `ready`；诊断工具报告本机 UDP `RPTCL` send 成功 |

已确认可用于本程序的 E3 profile 为：呼号 `N0CALL`、Gateway ID `460999901`、RX/TX metadata `438800000`、power `0`、CC `1`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、第二个 40 字节字段 `MMDVM_WIREX_Bridge`、options 空。native 的 DMR 配置继续使用 TS1、Source ID `4609999` 与原有三个目标 ID。`438800000` 是 BM 节点配置元数据，不会修改 CAT 频率或发射 RF。`MMDVM_WIREX_Bridge` 表示本程序提供的虚拟 MMDVM 兼容节点类型，不声明存在实体 MMDVM Hat。

这些对照确认 E3 整体配置可通过 BM 控制配置阶段；它们没有证明旧 profile 的拒绝由某一个字段单独造成。D/E 系列在相同参考 profile 上的单项更改维持 `ready`，不等于已识别旧 profile 的服务端拒绝规则。`RPTCL` 的 send 成功只表示本机 UDP 调用成功，不表示 BM 返回了关闭确认。BM 网页显示的节点 `Firmware`/类型文本来自程序上报的 RPTC 标识，不是 FTX-1 电台固件，也不是实体 Hat 声明。

## 当前共享元数据 helper 的生产源码复核

这次复核与上面的历史 E3 A/D/E 对照分开记录。根会话从源码提交 `2183cef8c2e7364f4c73ee89f8b674c7a7c28750` 的共享 `apply_network_metadata(Profile&)` 编译 `build/_work/bm-probe-final-e3-20261024/bm_network_probe.exe`，并显式运行 `--run-network-only`。本次结果在 118 ms 内完成：BM 对 RPTC 返回 config ACK，生产 `Session` 进入 `ready`，程序实际调用本机 UDP 发送 9 字节 `RPTCL`（send 成功），随后报告 `stopped` 并以退出码 0 结束。root 已复核 `network.stdout.log`、`run_summary.txt` 和 `source_sha256.txt`，确认最终运行日志及编译源码清单对应这次探测。

本次只运行了 network-only 诊断工具，没有启动 native bridge、HRI、COM、WinMM 音频、PTT 或 RF，也没有残留进程。保存的构建和运行证据位于该 ignored build 目录，包括 `network.stdout.log`、`run_summary.txt`、`source_sha256.txt` 等文件。结果确认当前共享 helper 生成的 RPTC 配置可通过 BM 控制配置阶段；`RPTCL` 成功仍只表示本机 UDP send 成功，不代表 BM 确认关闭，也没有测试 DMRD、Echo 音频或真实电台声音。

当前源码 commit `2183cef` 的 Windows clean build 在 `build/_work/wirex-bridge-2183cef-20261024-123605/` 完成；正式 builder 实际运行的 25 项离线测试全部通过，日志为 `build/_work/bm-ready-2183cef-build.log`。对应便携包 `build/bm-radio-bridge-2183cef/` 的根会话审计也已通过。包和离线测试证据不提升为 BM Echo 语音或 HRI/电台联合验证。

## BrandMeister 官方配置说明能确认的范围

- [Pi-Star / MMDVM 热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/pi-star-mmdvm/) 要求设置 simplex frequency，允许坐标保留当前值或输入坐标，并要求选择 color code。它还把 GPS 坐标无效或格式不正确（常见情况是小数点缺失）列为网络状态异常的可能原因。
- [OpenSpot 热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/openspot-shark-rf/) 针对 OpenSpot RF 热点示例要求 RX/TX 使用相同的有效 UHF 业余无线电频率，并使用 callsign、7 位 DMR ID 加两位热点别名和 hotspot security password。这是该产品的配置说明，不能据此推导 BM Homebrew 服务端对所有客户端或 DIRECT 节点的统一频率规则。
- [通用热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/) 要求已分配的 7 位 DMR ID、BrandMeister 账户与 hotspot security，并说明实际电台与热点一般需要使用一致的频率、色码和 talkgroup 设置。
- 在已查阅的 BM 官方热点/MMDVM说明中，没有找到禁止 `power=0`、`CC=0`、`version=1.0` 或要求某个固定 RPTC software/package ID 的协议条款；也没有找到解释 RPTC 后 `MSTNAK` 的字段级错误码。官方说明要求 RF 热点配置有效频率，但没有明确写出 BM Master 对 Homebrew RPTC 中 `frequency=0` 必定返回 `MSTNAK`。

第三轮在其他字段不变时把 RX/TX 从零改为用户提供的 145.100 MHz 元数据，仍收到 `MSTNAK`；第四轮仅把 color code 从 0 改为 1，仍收到 `MSTNAK`。用户确认其既往配置可使用 CC0 或 CC1，且 MMDVM 配置可使用 VHF/UHF 频率。这些旧 profile 测试只说明单独改频率或色码不足以通过 RPTC；之后 A 变体也表明只换节点类型字符串仍不足。E3 通过的是完整组合，不能据此推导旧拒绝的单字段原因。native 测试预设现在按已接受的配置使用 CC1。BM OpenSpot 页面只描述该产品 RF 热点，不能外推为 BM 全网频率规则。Pi-Star 说明允许坐标保留默认值或输入位置，并把坐标格式列为可能因素；第二轮 canonical 坐标仍收到 `MSTNAK`。旧 profile 的 `power=0`、version 和软件/package 标识是否参与拒绝目前没有可识别的字段级服务端原因。

## 独立诊断工具

[`tools/bm_network_probe.cpp`](../../tools/bm_network_probe.cpp) 与 native 共用 `apply_network_metadata(Profile&)`，以免两处 RPTC 参数漂移；调用方单独给定 CC。它固定指向 BM 4602，最多运行 15 秒，只发送唯一的 RPTL/RPTK/RPTC；只有生产 Session 确认 `ready` 时才发送 RPTCL。此前工具把 RPTCL 按 RPTC 前缀归类的问题已修复：现在先检查完整 9 字节关闭包，并记录每个控制包本机 UDP send 成败；只有 RPTCL 实际 send 成功才返回成功退出码。无参数或 `--help` 只显示用法，不读取密码、不创建 socket；只有显式传入 `--run-network-only` 才会开始真实网络诊断。它只读取本机私有密码文件，不接受密码命令行参数，不能由通用 builder、自动测试或默认启动流程调用。
