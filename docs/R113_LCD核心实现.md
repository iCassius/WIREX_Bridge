# R113 Native 身份与 T90 字段接线

## 已实现的数据路径

Native control v2 仅在注册了身份更新 callback 时，于 `control_ready` 和 `hello` 的 `supported_commands` 中声明 `radio_identity.cache_upsert`。请求仍使用 schema 2 envelope，parameters 精确为 `{source_id,revision,callsign}`，`request_id` 必须是 `radioid-<revision>`。Source ID 为 `1..16777215`，revision 是当前 Native run 内递增的正整数。

呼号只接受大写 ASCII `[A-Z0-9/-]`，长度为 1–10 字节并至少含一个字母。`callsign:null` 表示权威删除：例如 RadioID 明确返回 not-found，或 found 结果带有无法安全显示的呼号。Native 删除该 ID 的缓存项并推进全局 revision；即使该 ID 原本不在缓存，也会推进 revision，阻止旧帧随后恢复旧映射。网络超时或服务不可用不应发送 null。

身份命令在普通 512 项 control request replay cache 之前处理，不消耗路由和关闭请求的缓存配额。Native 只保留最新 revision 的 payload 用于重放判断，以及最多 128 个 Source ID→呼号映射。相同最新 payload 会返回 `ok` 和 `replayed:true`；较小 revision 返回 `stale_identity_revision`；相同 revision 的不同 Source ID、呼号或 null 返回 `identity_revision_conflict`。新 ID 达到容量时按最近查找/更新顺序淘汰最久未使用项。删除不占 LRU 槽位。

RadioID 命中缓存后，接收 admission 从其 Source ID 查询一次映射，并冻结到该接收 generation。命中时只把规范化呼号写进现有 mode4 T90 start candidate 的已知 SrcCallSign 十字节字段，短呼号右补空格。未命中或之前已删除映射时，继续使用原来的 `ID<decimal>` 字段。候选正文其余字节、DIRECT T 帧类型、帧长度、音频路径和 PTT 顺序保持不变。identity worker 不阻塞语音 admission；活动通话内到达的更新只供后续接收使用，不发送第二条 T。

## 状态记录

`lcd_source_identity` 固定包含以下八个键，严格解析器应同时识别旧五键和新八键格式：

| 键 | 类型与取值 |
| --- | --- |
| `prepared` | 布尔值；仅在接收 start candidate 已准备时为 `true`。 |
| `source_id` | uint32；未准备时为 `0`。 |
| `receive_generation` | uint64；未准备时为 `0`。 |
| `label` | 字符串；已准备时为候选中的 10 字节标签，未准备时为空字符串。 |
| `display` | 固定为 `unknown`。 |
| `label_kind` | `callsign`、`dmr_id` 或 `none`。 |
| `cache_revision` | 呼号命中时的 revision；fallback 或未准备时为 `0`。 |
| `serial_write_state` | `not_sent`、`pending`、`attempted`、`sent` 或 `failed`。 |

新接收选择后 state 为 `pending`；开始调用串口 `WriteFile` 时为 `attempted`；只有完整写出该 T 帧后为 `sent`，写入失败或短写为 `failed`。清理记录后恢复未准备值、`label_kind=none`、revision `0` 和 state `not_sent`。`sent` 只说明 Native 的串口写调用完整写出了帧；它不确认电台 LCD 实际绘制了呼号。`display` 在用户查看 FTX-1 屏幕前始终为 `unknown`。

## 离线验证边界

`tools/build-bm-bridge.ps1` 只构建本地 Native 代码和运行离线测试，不连接 COM、音频、BM、RadioID 或电台，不发送 PTT/RF。最终 builder 结果为 40 项通过、0 项失败，产物位于 `build/_work/wirex-bridge-c93c8c5-dirty-20261029-131452`。身份缓存测试覆盖输入边界、128 项 LRU、权威删除、null 重放、revision 冲突/迟到帧和运行隔离。T90 candidate 测试逐字节比较 DMR ID fallback 与缓存呼号版本，确认两者只有 SrcCallSign 十字节不同，并用现有 DIRECT T frame encoder/decoder 校验包络校验和。

`tools/test-ui-control-v2.ps1 -NativeExecutable <最终 wirex_bridge.exe 路径>` 通过实际 WPF BridgeSupervisor 匿名管道启动 Native routing diagnostic，验证 capability、hello、身份 upsert/重放/更新/null 删除/null 重放/旧 revision 拒绝，并继续验证原路由及 shutdown 流程。该诊断模式使用 Native 内存身份缓存与既有内存路由 sink，不连接设备或网络。UI agent 的 PowerShell 5.1/7 identity、status 和 WPF render 测试也已通过。

软件测试不能确认 FTX-1 显示效果。最终设备步骤是在用户控制的实机运行中，让一个已缓存且有呼号的 DMR Source ID 呼入，查看 LCD 是否显示呼号；再验证未命中 Source ID 仍显示 ID fallback，并确认通话结束时的原有屏幕行为。
