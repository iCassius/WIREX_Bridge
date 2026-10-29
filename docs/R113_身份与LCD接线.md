# R113：RadioID 身份缓存与 FTX-1 来话字段接线

状态：UI/Native 身份桥接的离线验收通过；真实 LCD 验收仍待实机。基线为 `c93c8c526faa66e1ebc9db11fda5b2e26d30bf2c`。本阶段只把已有 RadioID 呼号映射送入 Native，并让 Native 在下一通来话创建现有 HRI mode4 T90 起始记录时选择 source callsign 字段。用户确认 alpha.10 收听和鹦鹉回放正常；这项确认不包含 LCD 实际显示验收。

## 数据路径

1. WPF 从当前 `UserConfigDirectory/radio-identity-cache.json` 读取最多 128 条最新缓存记录。启动同步只接受缓存仍在正向有效期内、状态为 `found` 且呼号通过字符检查的项目；不查询 RadioID 网络。
2. Native 在 `control_ready` 声明 `radio_identity.cache_upsert` 后，WPF 完成 `hello` 确认，再逐条发送启动缓存。每个 run 使用全局递增的 revision、`request_id=radioid-<revision>` 和普通 schema 2 ACK。UI 同时只发送一条身份更新，并等待该 ACK 后再发送下一条；每条 ACK 最多等待 5 秒。超时或拒绝只停止本 run 的身份同步，并把待同步映射有界保存到后续 run，不等待网络、不影响路由命令、音频或关闭。
3. 身份更新使用 Native 专属 revision/重放状态，不占共享控制协议的 510 条普通请求配额。Native 以 DMR Source ID 为键保存最多 128 项呼号映射，新项目按 LRU 淘汰最久未用项。UI 的待发送队列和跨 run 暂存队列各自最多 128 个不同 ID，同一 ID 合并为最新值；满载时先丢弃最早的待同步项。每个新来话 generation 若 RadioIdentity 本机缓存已有 fresh 结果，UI 对该 Source ID 再排一次映射，以便 Native 的 LRU 淘汰后重新预热。ACK 只确认映射处理结果，不确认 HRI 写出或 LCD 显示。
4. 现有单 worker RadioID 查询保持原样，语音管线不等待 HTTP。查询返回新的正向结果后，PowerShell 先接收已有缓存写入结果，再把通过检查的呼号排入 Native 更新队列。权威 `not_found` 和 `found` 但呼号不合法时使用同一命令发送 `callsign:null`，按新 revision 删除该 Source ID 映射；超时、网络错误、`unavailable` 或过期缓存不会删除已有正向映射。只有规范化为大写且匹配 `[A-Z0-9/-]`、长度 1–10、至少含一个字母的呼号才会发送。姓名、城市、地区和国家从不进入 `callsign` 字段。
5. Native 只在后续来话 admission 时查 Source ID 映射。呼号存在时，使用现有 mode4 T90 起始正文里的唯一 SrcCallSign 10 字节字段；映射缺失或呼号不合法时保留原数字 ID 标签。其余记录字节、T 时序、媒体路由和语音数据不变。一次来话中途查到呼号只供后续通话使用，不发送额外 T，也不把迟到结果套到另一通话。已开始的来话记录保持冻结，删除映射只影响后续来话。

## Native 状态与 UI 验证

新状态 `lcd_source_identity` 必须精确包含 8 个字段：`prepared`、`source_id`、`receive_generation`、`label`、`display`、`label_kind`、`cache_revision` 和 `serial_write_state`。未准备记录的固定值是 `false/0/0/""/"unknown"/"none"/0/"not_sent"`。已准备记录的 `label` 为 10 个 ASCII 字节：呼号命中时使用规范呼号右补空格、`label_kind=callsign` 且 revision 为正数；没有命中时使用精确 `ID<Source ID>` 右补空格、`label_kind=dmr_id` 且 revision 为 0。来源 ID 与 receive generation 在活动媒体期间必须匹配父状态的当前来话。BM EOT 后若 Native 仍在 HRI 排空/停止阶段，可保留该通话的 generation 身份直到 `call_finished`；此时父状态的 `currentcall` 已清零不构成错配。`display` 保持 `unknown`，写入状态只允许 `pending`、`attempted`、`sent`、`failed`。PowerShell 保留旧的精确五字段状态格式兼容，不接受缺字段或额外身份字段。

界面保留已有折叠的诊断控件用于内部状态核对；R113 不展开它们，不显示“呼号已准备”或 LCD 未知文案，不把 Native 写出状态渲染成屏幕结果。`lcd_display` 仍只能由用户观察 FTX-1 实物屏幕后确认。

## 显示与验收边界

桌面上的呼号和 Native cache ACK只描述软件处理。`lcd_source_identity.display` 在用户观察到 FTX-1 实际屏幕前保持 `unknown`；不增加 LCD “已准备/未知”状态卡、调试按钮或备用候选开关。最终设备验收需要记录实际来话 Source ID、LCD 文本及通话结束后的屏幕变化。本阶段不连接真实 COM、音频、BM 或 RadioID，不触发 PTT/RF。

## 离线验收

离线验收结果：

- `tools/test-radio-identity.ps1`：47 项通过；只访问本机 HTTP fixture，不访问真实 RadioID 或 BrandMeister。
- `tools/test-ui-identity.ps1`：Windows PowerShell 5.1 与 PowerShell 7 均通过。覆盖 WPF Dispatcher、查询完成、正向缓存预热、`not_found`/非法呼号 tombstone、timeout 保留旧映射、按 run/generation 去重、128 项容量、5 秒 ACK timeout、拒绝 ACK 和关闭时不等待身份 ACK。
- `tools/test-ui-status.ps1`：Windows PowerShell 5.1 与 PowerShell 7 均通过。覆盖旧五字段状态、新八字段呼号/ID 标签、current Source ID 与 generation、枚举、字段缺失和非法标签。
- `tools/test-ui-control-v2.ps1` 使用最终 Native 诊断 EXE 经 `BridgeSupervisor` 匿名管道通过。覆盖 capability、hello、正向更新、相同 revision 幂等重放、更高 revision、`callsign:null` 删除与重放、旧 revision 拒绝、路由请求与正常关闭。Native 全量 builder 的 40 项离线用例均通过。
- `tools/test-ui-render.ps1`：Windows PowerShell 5.1 离线渲染 1280x900 与 1024x728 窗口通过；视觉树没有 LCD 未知/等待文案，无数据时来源和 LCD 区域隐藏。测试没有启动 Native 核心或访问设备。

测试夹具只使用临时目录、临时空配置和 `127.0.0.1`。Native 诊断构建包含纯内存身份 cache callback，不打开真实设备或网络。状态八字段由 PowerShell 状态合同 fixture 验证；普通 control-diagnostic 不执行 receive admission，也不生成虚构的 `lcd_source_identity` runtime 状态。未读取或改写 canonical 配置、密码路径或音量设置。未连接真实 RadioID/BM/COM/audio/PTT，也未确认真实 FTX-1 LCD 屏幕显示。
