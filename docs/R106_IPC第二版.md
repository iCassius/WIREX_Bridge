# R106 IPC v2 Native 控制协议

状态：2026-10-27，Native IPC v2 第一阶段实现与离线验证。它只提供协议握手、只读状态摘要和有界关闭；多目标运行时策略尚未接入。

## CLI 与兼容方式

- 现有桌面管道默认仍使用 v1：stdin 收到独立大写 `Q` 加换行或 EOF 时进入原有有界收尾。
- BM bridge 可在 `--ui-pipe` 后显式指定 `--ui-control-version 1` 或 `2`。未指定时默认为 1；该选项不能脱离 `--ui-pipe` 使用。
- v2 的 Native stdout 在设备启动前先发出 `control_ready`。它有独立的 schema 和 `control_seq`，不更改现有 v1 media/status JSONL 与磁盘状态报告。
- `hello` 成功只确认 Native 已识别控制协议；它不表示 BM、HRI、串口或音频设备已经就绪。

## v2 请求帧

stdin 使用以 LF 或 CRLF 结束的 JSONL；每帧最多 4096 字节。对象必须恰好包含四个字段，不能含重复键、额外键、嵌套对象或数组：

```json
{"schema_version":2,"run_id":"<control_ready中的run_id>","request_id":"<本run唯一ID>","command":"hello"}
```

`schema_version` 必须是 JSON 整数 `2`。`run_id` 与 `request_id` 为 1–128 字节 ASCII 标识符；命令名为最多 64 字节的 ASCII 小写命令名。第一阶段只实现：

| 命令 | 结果 |
|---|---|
| `hello` | 返回第一阶段支持的命令清单。收到 `hello` 前的 `status` 会被拒绝。 |
| `status` | 返回当时 Native 持有的媒体状态摘要。未确认的 BM/HRI 状态按实际状态返回；电台 RF 状态保持 `unknown`。 |
| `shutdown` | 调用现有有界关闭流程。结果 `ok` 表示 Native 收到了请求；是否完成以最终状态和子进程退出为准。 |

`rx_policy.*`、`tx_target.*`、订阅和其他未知命令返回 `unsupported`，不会改变路由或启动远端操作。旧 profile 到新 schema 的迁移由 R106 配置层处理，不属于 Native IPC 请求体。

## v2 stdout 控制记录

Native 启动控制端先发 `control_ready`。示例：

```json
{"schema_version":2,"type":"control_ready","run_id":"1234-5678","control_seq":1,"process_id":1234,"control_version":2,"supported_commands":["hello","status","shutdown"],"diagnostic":false}
```

每条命令返回单独的 `control_result`，控制记录以 `control_seq` 单调递增；该序号与 v1 media/status 序号分开校验。所有结果都带 `run_id`、`request_id`、`command`、`result` 和 `replayed`。`hello`/`status`/`shutdown` 成功时 `result` 为 `ok`；未实现命令返回 `unsupported`；无效请求返回 `rejected` 和稳定错误码。

同一 `request_id`、同一 JSON 正文重试时，Native 从本 run 的有界缓存取回原结果，并为重放分配新的 `control_seq`、设置 `replayed=true`。同 ID 不同正文返回 `request_id_body_conflict`，不执行新命令。所有字段合法且 `run_id` 匹配的请求都会绑定正文和结果，包括 `hello_required`、`unsupported_schema`、`unsupported` 等拒绝结果；畸形帧和过期 `run_id` 不绑定。

缓存最多保存 512 个请求结果，不驱逐旧记录：最多 510 个普通请求、一个 `cache_full` 哨兵，以及一个供本 run 首次成功的有效 v2 `shutdown` 使用的保留槽。被拒绝的旧 schema `shutdown` 按普通请求计数，不能占用 shutdown 保留槽。同一 `request_id`、同一正文仍从缓存重放；首次成功的 shutdown 之后，新 ID 的 shutdown 按普通容量处理，不会再次使用保留槽。普通请求达到 510 个后，首个无法按普通配额接收的新请求记录为 `cache_full`，该 ID 仍可安全重放或检测异正文。该哨兵之后若又收到无法绑定的新 ID，Native 立即进入有界收尾；已缓存请求仍可重放，若 shutdown 保留槽尚未使用，首次有效 v2 `shutdown` 仍可使用它完成收尾。重复的 `cache_full` 正文不会触发关闭。

例如 `status` 的摘要结构如下；值来自当前 Native 状态对象：

```json
{"mode":"running","status":"running","phase":"starting","media_seq":1,"diagnostic":false,"bm_state":"connecting","hri_phase":"starting","hri_ready":false,"serial_open":false,"wavein_open":false,"waveout_open":false,"radio_state":"unknown"}
```

控制记录独立于旧 v1 media/status 记录，不向媒体状态注入控制 ACK。诊断模式状态明确使用 `mode=diagnostic`、`diagnostic=true`、`bm_state=not_started`、`hri_phase=not_started`、设备打开字段为 `false`、`radio_state=unknown`。

## EOF 与有界收尾

- v1 EOF 仍按现有规则请求关闭。
- v2 完整帧边界上的 EOF 请求同一有界关闭流程。
- v2 EOF 遇到未结束 JSON 帧时，Native 拒绝该帧并以协议输入错误原因进入有界收尾。
- 超过 4096 字节的帧、空帧或控制管道读写失败不会部分执行命令。Native 发出有界错误 ACK（若 stdout 可写），再按错误路径收尾。
- 可完整分帧但内容不符合请求契约的帧（如 envelope 错误、过期 `run_id`、请求 ID 正文冲突或 unsupported schema）返回 `rejected` 并继续读取后续帧；`rejected` 本身不会终止进程。只有帧边界损坏、传输故障、EOF 残帧或缓存空间耗尽到无法绑定新请求时才进入有界收尾。

## 无设备协议诊断

使用以下参数启动独立诊断进程：

```text
wirex_bridge.exe --control-diagnostic --ui-pipe --ui-control-version 2
```

该入口只接受这组参数和匿名 stdin/stdout 管道，不读取 profile、密码或 HRI 文件，不枚举或打开音频设备，不连接串口、BM 或其他网络。启动后发出 `diagnostic=true` 的 `control_ready`；父进程可按顺序发送 `hello`、`status`、`shutdown`。有效 `shutdown` 或完整帧边界 EOF 以退出码 0 结束；残帧、管道错误或 10 秒总时限到期以退出码 2 结束。

## 离线验证

新增 `ui_control_protocol_v2_test` 覆盖 v1 兼容、分片与粘连、LF/CRLF、4096 字节边界、残帧 EOF、严格 envelope、重复键、嵌套/额外字段、类型错误、Unicode 转义与非法 UTF-8、run 隔离、请求 ID 去重、重放序号递增、unsupported 和缓存满时的 shutdown 槽位。

该测试已登记在 CMake/CTest 和 `tools/build-bm-bridge.ps1`，作为原 35 项后的第 36 项；原有测试顺序不变。包内 `test-control.cmd` 会通过匿名管道启动上述 Native 诊断入口，并实际执行 `control_ready → hello → status → shutdown → exit 0`；它不接触设备或 BM 网络。
