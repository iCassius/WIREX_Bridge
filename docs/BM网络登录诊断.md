# BM 4602 网络登录诊断

本文记录 2026-10-24 对 BrandMeister 4602 的两次有界 network-only 探测，以及对公开 BM、MMDVM 与 DroidStar 实现和配置说明的核对。探测没有进入 `ready`，不能作为设备已上线或生产验收的证据。

## 范围与基线

- 仓库探测基线：`d8ae96d90c5887d7fe70ce4d66d77ae73637702f`。BM + FTX-1 候选代码来自其祖先提交 `17f3433ae4cd6820622033ddb1910c030cb260f2`。
- 目标：BM 4602，`43.129.83.124:62031`。探测直接使用这个 IP，不经 DNS。
- 两次都链接当前生产 `wirex::bm::Session` 与 `UdpTransport`，单次 deadline 为 15 秒；实际每次不到 1 秒就收到拒绝并结束。探测每种控制包最多发送一次，不自动循环重试。
- 没有启动 native bridge、COM、WinMM、PTT 或 RF；没有发 `RPTO`、TG、DMRD 或语音，也没有收到成功后的业务数据。密码只从本机被 `.gitignore` 排除的私有文件读取；正文、盐、challenge 字节、摘要和认证载荷均未记录。
- 两次探测都由同一份生产 `Session` 状态机处理。没有修改 `src/bm_session.cpp` 或 `src/bm_udp.cpp`。
- 两次执行的绝对时刻没有由 probe 记录，本文只保留日期和每次小于 1 秒的实际耗时，不补造时间戳。

## 两次配置与实测结果

两次使用相同呼号和 gateway ID（RadioID 信息已由用户核实），其余 RPTC 字段也完全一致。第一次复制当时 native 的 DIRECT 配置；第二次只改变坐标字符串格式。

| RPTC 字段 | 第一次 | 第二次 |
| --- | --- | --- |
| callsign / gateway ID | `BI7KGD` / `461135501` | 相同 |
| RX/TX frequency | `0` / `0` | 相同 |
| power / color code | `0` / `0` | 相同 |
| latitude / longitude | `0` / `0`，按字段宽度补尾部空格 | `0.000000` / `00.000000` |
| height / slot flags | `0` / `'4'` | 相同 |
| location / description | `DIRECT` / `FTX-1` | 相同 |
| URL / version / software | 空 / `1.0` / `WIREX Bridge` | 相同 |
| options | 空 | 空 |

两次收到的控制交换相同：

1. 发送 `RPTL` 8 字节；收到 `RPTACK` 10 字节 challenge，生产状态机接受。
2. 发送 `RPTK` 40 字节；收到 `RPTACK` 10 字节。仅在内存中比较其尾部是否匹配 challenge 或 gateway ID；结果为 `matches_salt=false`、`matches_gateway=true`，生产状态机接受。
3. 发送 `RPTC` 302 字节；收到 `MSTNAK` 10 字节，生产状态机返回 `InputResult=master_rejected`、`Failure=master_rejected` 并进入 `backoff`。

第二次仅改变坐标字符串，结果仍为相同的 `MSTNAK`。两次从未进入 `ready`，因此没有发送 `RPTCL`。

这组证据表明 UDP 往返和 RPTL/RPTK 认证阶段都已推进到配置提交；不能把这次失败归因于登录 challenge 长度、RPTK 长度或认证 ACK 的 ID 检查。Master 在 RPTC 后拒绝了配置，但 `MSTNAK` 没有提供可识别的具体字段错误原因。当前不能确定是哪个 RPTC 字段或服务端策略触发拒绝。

## 实现与公开默认值对照

BrandMeister 的 [DMRHost `DMRNetwork.cpp`](https://github.com/BrandMeister/DMRHost/blob/dev/DMRNetwork.cpp) 与其采用的 MMDVM Homebrew 客户端流程使用 8 字节 `RPTL`、40 字节 `RPTK` 和 302 字节 `RPTC`。其中 RPTC 坐标由数值转换为固定小数格式；零值会形成 `0.000000` 和 `00.000000`。第一次的 `"0"` 补空格与此格式不同，第二次已按此格式发送，但 Master 仍拒绝 RPTC。

DMRHost 的网络对象构造函数会把 RX/TX frequency、power、color code、latitude、longitude 和 height 初始化为零，随后由 `setConfig()` 写入配置。这个客户端的内存初值不能证明服务器接受以这些零值发送的 RPTC，也不能证明生产配置应该保留零值。

[DroidStar 的 `dmr.cpp`](https://github.com/nostar/DroidStar/blob/main/dmr.cpp) 采用相同的 302 字节布局。它把频率同时写入 RX/TX 字段，把 power 和 color code 写成 `1`，height 写成 `0`，slot flags 写成 `'4'`，并把 software ID 与 package ID 放在 RPTC 尾部。[DroidStar 的设置默认值](https://github.com/nostar/DroidStar/blob/main/droidstar.cpp) 包括 latitude/longitude 字符串 `"0"`、频率 `438800000`、URL `www.qrz.com`、software ID `20200922`、package ID `MMDVM_MMDVM_HS_Hat`；连接时坐标会先转成数值再格式化。其 [README](https://github.com/nostar/DroidStar) 也明确提示，不同服务器对 DMR 配置字段的要求可能不同。

这些是公开客户端的组包方式和本地默认值，不是 BM 4602 接受某一字段值的服务器端证明。本文没有修改 `WIREX Bridge` 标识来冒充 MMDVM/DroidStar，也没有把 DroidStar 默认值当成 BM 必须值。

## BrandMeister 官方配置说明能确认的范围

- [Pi-Star / MMDVM 热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/pi-star-mmdvm/) 要求设置 simplex frequency，允许坐标保留当前值或输入坐标，并要求选择 color code。它还把 GPS 坐标无效或格式不正确（常见情况是小数点缺失）列为网络状态异常的可能原因。
- [OpenSpot 热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/openspot-shark-rf/) 要求 RX/TX 使用相同的有效 UHF 业余无线电频率，并使用 callsign、7 位 DMR ID 加两位热点别名和 hotspot security password。
- [通用热点说明](https://help.brandmeister.network/hotspots/connecting-hotspots/) 要求已分配的 7 位 DMR ID、BrandMeister 账户与 hotspot security，并说明实际电台与热点一般需要使用一致的频率、色码和 talkgroup 设置。
- 在已查阅的 BM 官方热点/MMDVM说明中，没有找到禁止 `power=0`、`CC=0`、`version=1.0` 或要求某个固定 RPTC software/package ID 的协议条款；也没有找到解释 RPTC 后 `MSTNAK` 的字段级错误码。官方说明要求 RF 热点配置有效频率，但没有明确写出 BM Master 对 Homebrew RPTC 中 `frequency=0` 必定返回 `MSTNAK`。

因此，零频率是当前 profile 与 BM RF 热点官方配置要求之间唯一已找到的明确差异；它是需要保留的待核对项，尚不能据此断言就是本次拒绝原因。`power=0`、`CC=0`、版本和软件/package 字符串是否触发服务端规则仍无官方证据。DIRECT 没有声明 RF 频率，不能从实际电台频率缺失处自行填造数值。下一步若要继续验证，需要先确定 BM 对这种 DIRECT 节点允许的配置，或由用户提供可合法声明的实际频率/色码；在此之前不改生产 Session、不伪装其他客户端，也不继续发送 BM 登录请求。

## 独立诊断工具

[`tools/bm_network_probe.cpp`](../tools/bm_network_probe.cpp) 是用于同一生产 Session/UdpTransport 流程的独立源码，保存的 profile 与当前 native 配置一致；第二次试验的坐标格式差异只记录在上文。它固定指向 BM 4602，最多运行 15 秒，只发送唯一的 RPTL/RPTK/RPTC；只有生产 Session 确认 `ready` 时才发送 RPTCL。无参数或 `--help` 只显示用法，不读取密码、不创建 socket；只有显式传入 `--run-network-only` 才会开始真实网络诊断。它只读取本机私有密码文件，不接受密码命令行参数。这个工具不能由通用构建脚本、自动测试或默认启动流程调用；每次未来人工执行前都需要确认网络目标和用户授权。
