# R124 频道运行状态与启动配置

## 动态组请求

界面将 `network_subscription.quick_call_join` 发给本机 Native。Native 只有在本机 transport 确认 header 与 EOT 两帧都已发送后，才返回 `activation_status=request_sent` 和 `frames_sent=2`。该结果只证明本机发送了激活请求；当前控制协议没有 BM 侧加入确认或组状态持续读取字段，不能据此声称 BM 服务端已激活。卡片仅在本地收到有效发送确认后标注“动态组”，悬停说明显示 TG、时隙和“激活请求已发送”；卡片标题和悬停说明不显示 Native 字段、传输帧数或无回读说明，其他状态与事件区域仍保留本机结果和错误原因。[R109 实现记录](R109_动态组激活实现.md) 与 [BM 订阅和收听优先级记录](R111_BM订阅与收听优先级.md) 记载了该发送边界。

只有与未完成请求的 `run_id`、`request_id`、TG、slot 相符，且状态为 `request_sent`、发送帧数为 2 的响应，才会创建本机会话记录。状态按运行 ID、频道 key、时隙分开保存。请求等待结果时所有动态组按钮变灰，代码也会拒绝替换未完成请求。收到确认后，该频道按钮显示“已发送”并禁用重复请求。

本地请求记录在 BM 离开 `ready`、核心运行更换或同一 slot 有新的组激活请求时清除。实际组呼 PTT 只有在核心报告合法组号且目标与该 slot 已标记的 `request_sent` 组号不同时，才清除旧记录；同组 PTT 会保留记录，私呼及缺少或非法组号的事件不会清除记录。超时只表示 UI 没收到本机结果；它不会证明发送失败或动态组过期，也不会自动重发。用户可以检查连接后手动重试。单独收到来话不会创建或刷新激活成功记录。

## 频道卡来源与静态组

卡片标题使用“组呼 ID”或“单呼 ID”，并在有名称时显示名称。只有来源可核实时才追加“静态组”或“动态组”：静态组来自当前 BM API 静态组回读，动态组来自当前会话的有效发送确认。来源不明时不添加分类。已知名称只有 91=`World-wide`、组呼 46001=`全国`、单呼 460997=`中国鹦鹉`；未知名称不显示占位文字。单呼不显示组分类。

只有 BM 静态组 API 已加载，当前设备 ID 与当前 API 身份仍匹配回读身份，卡片才会显示“静态组”并禁用动态激活按钮；按钮文字也是“静态组”，悬停说明显示 TG、时隙和“静态组已读取”。BM 回读的 API slot 1/2 只匹配相同软件 slot。`BmManagement.psm1` 将设备 status 4 映射为添加 API slot 0，将 status 0–3 映射为 API slot 2；因此 API slot 0 只在同设备 context 明确为 status 4/add_slot 0 时，才可映射到该 TG 唯一配置的软件 slot。若同一 TG 同时配置软件 slot 1 和 2，或 context/设备身份不匹配，界面不猜测映射关系，也不把回读记录标到任一频道卡。

静态组回读必须带有当前设备 ID，当前 API 身份仍须与读取时记录相同。过期或不完整的来源不会产生静态/动态标签。

代码不记录或设置动态组 TTL。BrandMeister 官方说明 USA Master 的动态组超时为 15 分钟，其他 Master 由各自配置决定；这不能推出 BM China 4602 的期限，因此界面仅使用实际回读结果，不写入固定中国 TTL。[动态与静态组说明](https://help.brandmeister.network/talk-groups/dynamic-vs-static/)

## 失败原因与诊断

Quick Call 拒绝信息会显示本机 Native 返回的错误码及对应本地状态：

- `media_busy`：本机收发、音频路由或清理流程仍忙。
- `quick_call_not_ready`：本机控制、BM 连接或 UDP transport 未就绪。
- `invalid_or_forbidden_group` / `disconnect_group_forbidden`：组号、时隙无效或目标被禁止；TG 4000 是断开组。
- `quick_call_send_failed` / `quick_call_partial_send` / `quick_call_send_incomplete`：Quick Call 帧未完整发送；部分发送不会自动重试。

运行诊断文件为 `private/runtime/quick-call-requests.jsonl`，最大 256 KiB。每行仅包含 UTC 时间、运行 ID、请求 ID、TG、slot、结果、错误码、Native 激活状态、帧数和 replay 标记；不会写入原始协议包、配置内容、BM API key 或密码。空间达到上限后停止追加。

对 Alpha 19 现有运行日志的只读检查没有找到 `quick_call_join` 或 Quick Call 拒绝结果，因此该日志不能解释用户报告的失败，也没有证据证明 BM 服务端因重复请求拒绝。检查期间没有读取 Alpha 19 的 `config.json`，也没有发起 BM 请求、连接电台或发送 RF。

## Portable 配置启动路径

正常启动时，bridge 将 `PackageDirectory` 视为 runtime 目录，将 `PortableDirectory` 视为 EXE 根目录。启动先调用 `Initialize-PortableConfig -PortableDirectory <exeRoot>`，校验它返回的绝对路径正是 EXE 根目录下的 `config.json`；该路径不得位于 runtime 目录内。`private/runtime` 仍用于日志和运行缓存。

如果 `config.json` 不存在，统一配置模块创建唯一默认结构；如果创建、读取或验证失败，界面显示具体错误并退出，随后不会加载设备、BM 或 Native 启动组件，也不会自动连接。默认配置不包含 API key 或密码。

`RoutingDiagnostic` 继续使用强制隔离的 `UserConfigDirectory`，不调用 portable 配置 helper，不初始化 EXE 根目录的 `config.json`。`PortableDirectory` 只用于路径比较，不读取该目录的配置。bridge 在其他启动初始化前拒绝相对路径，以及等于或位于 `PortableDirectory`/`PackageDirectory`（runtime）下的诊断目录。自动诊断还要求外部隔离目录中有严格校验的 fixture marker。

## 验收范围

频道集成回归使用临时配置与内存假核心，覆盖中文预设、纯 ID、手输类型、默认 PTT 目标保留、静态 API 回读、Native 成功/拒绝、重复请求、同槽清理、BM 重连、迟到响应和诊断目录隔离。模块独立 smoke 直接验证运行 ID、频道 key、slot、超时、重试、迟到确认、成功两帧要求及状态清理。以下回归均使用 Windows PowerShell 5.1 STA；RenderOnly 和 R124 实际交互结果由布局回归单独报告。检查不连接真实 BM、串口、HRI、音频设备或射频硬件。

| 回归 | 结果 | 覆盖范围 |
| --- | --- | --- |
| `test-channel-activation-state.ps1` | 通过，345 项断言 | 状态模块内存 smoke；不启动 Native/UI，不访问 BM 或硬件 |
| `test-ui-channels.ps1` | 通过，170 项断言 | 频道集成、R123 保留项、BM 静态回读、Quick Call、Portable/Runtime 诊断路径 canary 和真实 WPF 输入事件 |
| `test-ui-r124.ps1` | 通过，63 项断言 | 11 个 ComboBox 主体真实点击、编辑/预设/Add、音量滑块输入 |
| `test-ui-render.ps1` | 通过，1951 项断言 | RenderOnly 控件布局、频道标题边界和长名称 tooltip |
| `test-ui-console.ps1` | 通过，121 项断言 | 控制台与 CAT 生命周期、连接/清理交互 |
| `test-ui-status.ps1` | 通过，87 项断言 | run_id/序号/新鲜度、来源标签、频道来话状态、生命周期清理 |
| `test-ui-radio-cat.ps1` | 通过，197 项断言 | CAT 操作、轮询、写入/复核、设备选择及取消清理 |
| `test-ui-r123.ps1` | 通过，54 项断言 | R123 既有频道与交互行为 |
| `test-ui-audio-gain.ps1` | 通过，85 项断言 | 音频状态与增益交互 |

`test-ui-r124.ps1`、`test-ui-render.ps1`、`test-ui-r123.ps1` 与 `test-ui-audio-gain.ps1` 由布局回归报告通过；其余结果由本轮 PowerShell 5.1 STA 直接运行获得。

此前的 R124 实际 WPF 输入回归通过 63 项断言，root 接受该证据。另一次后续交互尝试时，Dota 2 窗口处于前台，WPF 窗口没有收到输入事件；该次尝试没有形成有效 UI 输入结果。此记录只说明当时的前台输入环境，不推翻此前 63 项通过结果，也不作为本轮交互验收；不再抢占或注入前台输入。
