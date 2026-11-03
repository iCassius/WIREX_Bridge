# R114 alpha.11 FTX-1 LCD 实测与日志审计

- 日期：2026-10-30
- 代码审计基点：`main` / `f09e35159b3ceff315411563d59b661b2b88e441`
- 对象：用户反馈的 alpha.11 实机观察，以及 `private/user-config/ui-runs/3d349209ac2146e5b19f198b213c0348/bm-bridge-20261029-160743-229-76a561ac.jsonl`

## 用户现场观察

- 用户确认 alpha.11 App 的呼号显示正常。
- 用户观察到 FTX-1 LCD 的两个内容区域仍为空白，来话没有让这两个区域出现内容。
- 用户提供的截图左上角有一个红色 WIRES-X 图标；顶部另有 WIRES-X HRI、DIRECT、HRI MODE 和 FM 字样。本文只记录截图可见元素，不据此推断某个串口、网络或电台故障原因。

## 日志审计范围

只读取上述 Native JSONL 的事件名和身份相关字段，没有读取同一运行目录中的连接配置、准备状态或路由配置文件正文。日志含 285 条记录。没有启动电台、BrandMeister 或音频设备，也没有改动用户配置。

## 官方 HRI DLL 来话回调的静态证据

本节仅引用官方 `HRI_UART.dll`（SHA-256 `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed`）的离线静态分析。查询范围和完整边界见 [R114 HRI 回调与 LCD 写出边界研究](../../../research/r114/hri-dll/R114_HRI来话回调与LCD写出边界.md)。

- 既有 `FUN_1001b190` 证据 `ev_1661a89f0094fc4f67961e11cffb463af5f8a11d5e8ddd7114c1066cafdea137` 与本轮 `FUN_10013e60` 证据 `ev_f163cab598682a7d4398cebf41abf88e4fa1ffa34addf0175b4dbac405ba14b5` 显示：来话回调把输入记录传入 PC 侧处理；可见动作包括投递 `WM 0x650`、调用未解析目标的间接表项，以及把若干定长字段复制到进程对象状态区。这个链路支持“来话元数据进入 PC 侧处理”，但窗口接收端、间接回调目标和字段业务名称仍未解析。
- `FUN_10013e10`（`ev_e30a5696922437631fd87255737c0b9bb5fa016d2f1ae6edcfc75390e44a6ed9`）是两处十字节复制分支共用的字符校验；字符规则还依赖一个本轮未反编译的外部函数。该校验本身不能说明字段是呼号、房间或节点名。
- `xrefs(0x10191d60)`（`ev_ca1c3c2f44f893e34318f2d779d626726cedf20ad91e4f04f3458fba4487bc52`）只返回三个引用地址，未解析表项的赋值位置和目标函数。

本轮查询的来话回调链和函数体中没有找到 PC→LCD 命令构造、T/F 串口记录构造或 `WriteFile` 路径；这不扩展为对整个 DLL 所有路径的否定结论。R113 当前 mode 4 空头 T 的呼号字段写入，与静态证据中官方非空 T 路径使用已填充头并进入 mode 0、2 或 3 的观察存在差异，但字段语义和电台显示行为仍未由此确认。更完整的地址、偏移和分支边界见上述研究文档。

## 官方 EXE 列表信息路径与 LCD 缺口

本节仅引用官方 `WIRES_X.EXE`（SHA-256 `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671`）的离线静态分析和既有 R79 证据。详细记录见 [R114 EXE 列表信息发送链与 LCD 缺口](../../../research/r114/screen-exe/R114_EXE列表信息发送链与LCD缺口.md)。

- 本轮 `xrefs(0x004e0790)` 的导出 bundle 有 0 条记录，不能作为有效引用结论；`procedure_callers(0x004e0790)` 在 330000 ms 启动期限后返回 `provider_timeout`（REA run ID `4c5e876d-4cb1-4684-966d-8f9e3e1f57ec`），没有得到 caller Evidence。
- 既有 R79 `FUN_004e0790`（`ev_61089f387cfdec5258766bf18d61b16af8cbbcb26a6d044f4fc464c9a41abcba`）显示响应字段 `0x0A` 可写入连接对象 `+0x12F` 的 8 字符槽；既有 `FUN_004e5580`（`ev_5131b0c70d73a5f6b72c69e23fb4ff735ce3e5d673ac8d5c9bd16a32e39d8ef9`）显示 `+0x12F` 在特定条件下可覆盖传给 `SetDigiTrcvData` 的 DE 字段。字段 `0x0A`、`+0x12F` 和 DE 的业务语义没有被证据映射为 LCD 房间列表或来话呼号。`FUN_004e0790` 的既有 dossier 还列出一条 DATA 引用：source `0x4e24e1` / `FUN_004e1200` 指向该函数；它不是直接调用证据，也没有证明运行时已派发该响应。
- 因此目前仍缺少一条经证据闭合的“请求/响应 → PC 状态字段 → 完整 HRI 记录 → 对应 LCD 区域刷新”链，也没有可据此给出的列表命令或显示前置条件。caller 查询超时不提供额外代码结论。

## 45 秒被动 WriteFile 观察

根会话对 `Wires-X.exe`（PID 8116）进行了 45,009 ms 的被动 `KernelBase!WriteFile` 观察。结果记录在外部证据 [r114_official_idle_metadata.evidence.json](../../../research/r114/runtime-observer/r114_official_idle_metadata.evidence.json)，Evidence ID `ev_cededd928e87d751af14080fa91e33e270ada3e0788a63c6e42a5cc0760cc2f1`。

- 共观察到 134 次 `WriteFile` 调用；其中 90 个输入缓冲区以 SOH 开头。脚本记录 0 次 envelope rejection、0 次读取失败、0 个 oversized candidate。
- 白名单识别出 45 条 Y 帧，正文各 100 字节（含 Direct 外层后每帧 109 字节）；F/T/V 均为 0 条。脚本没有单独统计非白名单类型及其数量；未保存帧 payload。
- 观察窗口按 45 秒上限结束，`hook_detached=true`、`cleanup_error=null`。工具返回的 `running` 是结束时的观察快照；随后 session 状态为 `No open session`，PID 8116 仍运行。观察器没有关闭该进程。
- 这是一个被动时间窗口；期间没有由观察器或根会话发起节点/房间连接或来话操作。它只描述该窗口内可见的 WriteFile 调用，不能据此判断 LCD 显示能力，也不能推断官方程序不会发送其他类型的记录。

## 日志能确认的行为

- Native 为 8 个接收代次准备了 `lcd_source_identity`：1、3、5、7、9、11、13、15。
- 其中 6 次选择 `dmr_id` 数字标签回退；另 2 次命中呼号缓存并选择 `callsign`，发生在代次 13 和 15。日志摘要没有在本文记录呼号或 Source ID。
- 8 个代次的 `serial_write_state` 都从 `pending` 变为 `sent`。没有观察到 `attempted` 或 `failed` 状态。依据 [R113 LCD 核心实现说明](../R113_LCD核心实现.md)，`sent` 表示 Native 完整写出了对应的 T 帧。
- 这份 JSONL 的 285 条记录中，`lcd_source_identity.display` 均为 `unknown`。日志记录了 Native 的帧写入状态，没有记录电台实际绘制的屏幕内容。
- 该 JSONL 没有身份 `cache_upsert` 或身份 ACK 专属事件/字段。因此，仅凭这份日志无法确认 UI 对 Native 逐条发送了哪些缓存更新、Native 对哪些更新返回了 ACK。两次 cache hit 只确认接收准入时 Native 选中了呼号映射。

## 运行收尾记录

- `shutdown_requested` 出现在 seq 282，日志末条 seq 285 为 `stopped`。收尾状态中 BM 为 `stopped`、HRI phase 为 `stopped`，HRI 串口已关闭；`calls_started` 与 `calls_ended` 都为 8。
- 末条记录的 `rx_call_end_reason` 为 `cancelled`，`rx_cleanup_result` 为 `completed`。日志还在 seq 253 记录一条 `downlink_call_bounded_cleanup_incomplete` 事件，但该条的 `rx_cleanup_result` 也为 `completed`。本文保留事件名和字段值的原样记录，不推断两者为何并存。
- 这份 Native JSONL 没有操作系统进程退出码字段。因此，能确认 Native 运行日志到达 `stopped` 且串口关闭；无法从这份文件确认进程的 exit code。

## 验收边界与后续工作

用户实测仍是两个 LCD 内容区空白。日志同时显示八个接收代次均完成 T 帧串口写入，其中两个代次使用了呼号标签；它没有证明 LCD 接收、字段选择或实际绘制成功。截图左上角的红色 WIRES-X 图标也没有与这份 JSONL 中某个已确认的底层故障建立对应关系。

alpha.11 源码保持不变。根会话已完成一次 45,009 ms 被动 `WriteFile` 观察：共见 134 次调用、90 个以 SOH 开头的输入缓冲区；白名单只识别出 Y 帧 45 条，正文各 100 字节（含 Direct 外层后每帧 109 字节），F/T/V 均为 0，未保存 payload。观察器自动 detach 且清理无错误；随后查询显示 session 已关闭、PID 8116 仍运行。观察窗口没有由观察器或根会话发起节点/房间连接或来话操作，因此不能据此判断 LCD 显示能力或其它记录类型。用户已选择在现有 DIRECT/HRI 连接的节点或房间继续观察屏幕，目视结果仍待反馈；本轮没有切换设备模式或改变 RF 设置。后续核心 LCD 工作应以“Native 已为来话构造身份字段并记录完整 T 帧写入，但用户观察到 LCD 两区仍空白”为事实起点，继续核查电台接受的记录格式、字段选择与 LCD 绘制路径。屏幕显示和通话结束后的内容变化仍需由用户实机观察确认。
