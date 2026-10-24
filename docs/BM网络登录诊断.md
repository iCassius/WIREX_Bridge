# BM 4602 网络登录诊断

本文记录 2026-10-24 对 BrandMeister 4602 的四次有界 network-only 探测，以及对公开 BM、MMDVM 与 DroidStar 实现和配置说明的核对。探测没有进入 `ready`，不能作为设备已上线或生产验收的证据。

## 范围与基线

- 仓库探测基线：`d8ae96d90c5887d7fe70ce4d66d77ae73637702f`。BM + FTX-1 候选代码来自其祖先提交 `17f3433ae4cd6820622033ddb1910c030cb260f2`。
- 目标：BM 4602，`43.129.83.124:62031`。探测直接使用这个 IP，不经 DNS。
- 四次都链接当前生产 `wirex::bm::Session` 与 `UdpTransport`，单次 deadline 为 15 秒；实际每次不到 1 秒就收到拒绝并结束，第三次运行 0.567 秒，第四次运行 0.588 秒。探测每种控制包最多发送一次，不自动循环重试。
- 没有启动 native bridge、COM、WinMM、PTT 或 RF；没有发 `RPTO`、TG、DMRD 或语音，也没有收到成功后的业务数据。密码只从本机被 `.gitignore` 排除的私有文件读取；正文、盐、challenge 字节、摘要和认证载荷均未记录。
- 四次探测都由同一份生产 `Session` 状态机处理。没有修改 `src/bm_session.cpp` 或 `src/bm_udp.cpp`。
- 执行的绝对时刻没有由 probe 记录，本文保留日期和已知的实际耗时，不补造时间戳。

## 四次配置与实测结果

四次使用相同呼号和 gateway ID（RadioID 信息已由用户核实）。第一次复制当时 native 的 DIRECT 配置；第二次只改变坐标字符串格式；第三次复制第二次配置，仅把 RX/TX frequency 从零改成用户提供的 145.100 MHz 元数据；第四次复制第三次配置，仅把 color code 从 0 改成 1。后两次没有修改电台配置或发射 RF。

| RPTC 字段 | 第一次 | 第二次 | 第三次 | 第四次 |
| --- | --- | --- | --- | --- |
| callsign / gateway ID | `BI7KGD` / `461135501` | 相同 | 相同 | 相同 |
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

当前 WIREX profile 的 `version="1.0"` 写入第一个字段，`software="WIREX Bridge"` 写入第二个、即 DMRHost 称为 `hwType` 的字段。这是可能影响 BM 配置接受度的候选差异，但没有 BM 服务端字段规则或单字段实测证明它导致 `MSTNAK`。目前也没有找到公开的通用软件节点 package token 或注册流程；不能据 DroidStar 默认值把本软件标成物理 `MMDVM_MMDVM_HS_Hat`，也不能据此认定拒绝原因。

## BrandMeister 官方配置说明能确认的范围

- [Pi-Star / MMDVM 热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/pi-star-mmdvm/) 要求设置 simplex frequency，允许坐标保留当前值或输入坐标，并要求选择 color code。它还把 GPS 坐标无效或格式不正确（常见情况是小数点缺失）列为网络状态异常的可能原因。
- [OpenSpot 热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/openspot-shark-rf/) 针对 OpenSpot RF 热点示例要求 RX/TX 使用相同的有效 UHF 业余无线电频率，并使用 callsign、7 位 DMR ID 加两位热点别名和 hotspot security password。这是该产品的配置说明，不能据此推导 BM Homebrew 服务端对所有客户端或 DIRECT 节点的统一频率规则。
- [通用热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/) 要求已分配的 7 位 DMR ID、BrandMeister 账户与 hotspot security，并说明实际电台与热点一般需要使用一致的频率、色码和 talkgroup 设置。
- 在已查阅的 BM 官方热点/MMDVM说明中，没有找到禁止 `power=0`、`CC=0`、`version=1.0` 或要求某个固定 RPTC software/package ID 的协议条款；也没有找到解释 RPTC 后 `MSTNAK` 的字段级错误码。官方说明要求 RF 热点配置有效频率，但没有明确写出 BM Master 对 Homebrew RPTC 中 `frequency=0` 必定返回 `MSTNAK`。

第三轮在其他字段不变时把 RX/TX 从零改为用户提供的 145.100 MHz 元数据，仍收到 `MSTNAK`；第四轮仅把 color code 从 0 改为 1，仍收到 `MSTNAK`。用户确认其既往成功配置可使用 CC0 或 CC1，且 MMDVM 配置可使用 VHF/UHF 频率。这两轮结果只说明单独改频率或单独改色码都未解决当前 DIRECT profile 的拒绝，不能据此判断服务端拒绝规则。两项改动仅用于独立 network-only 探测；native 测试预设仍保持用户原先确认的 CC0，没有随诊断更改。BM OpenSpot 页面只描述该产品 RF 热点的配置，不能外推为 BM 全网频率规则。Pi-Star 说明允许坐标沿用默认值或输入位置，并把坐标格式问题列为连接异常的可能原因；第二轮已按 MMDVM 的固定小数格式发送，但结果仍是 `MSTNAK`。`power=0`、版本和软件/package 字符串是否触发服务端规则仍无官方证据。`MSTNAK` 没有提供字段级错误码；继续前需要 BM 服务端侧的拒绝原因或 DIRECT 节点的明确配置要求。在获得该信息前停止探测，不改生产 Session，也不伪装其他客户端。

## 独立诊断工具

[`tools/bm_network_probe.cpp`](../tools/bm_network_probe.cpp) 是用于同一生产 Session/UdpTransport 流程的独立源码，保存的 profile 与当前 native 配置一致；第二次试验的坐标格式差异只记录在上文。它固定指向 BM 4602，最多运行 15 秒，只发送唯一的 RPTL/RPTK/RPTC；只有生产 Session 确认 `ready` 时才发送 RPTCL。无参数或 `--help` 只显示用法，不读取密码、不创建 socket；只有显式传入 `--run-network-only` 才会开始真实网络诊断。它只读取本机私有密码文件，不接受密码命令行参数。这个工具不能由通用构建脚本、自动测试或默认启动流程调用；每次未来人工执行前都需要确认网络目标和用户授权。
