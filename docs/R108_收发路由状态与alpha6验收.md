# R108 收发路由状态与 alpha6 验收

## 运行时路由文件

alpha6 的手工连接启动会在本次运行目录生成独立的 `routing-state.json`，再把该文件路径传给 native。直接启动时，launcher 在状态目录下为每次手工运行创建独立子目录，状态报告和路由文件都写在这个子目录。桌面 UI 已创建 GUID 运行目录时，launcher 直接在该目录写文件。UI 预检记录包含 `routing_state_path`；它必须指向本次 GUID 运行目录内名为 `routing-state.json` 的文件。alpha6 launcher 不把策略拆成单一路由参数。

文件使用 UTF-8、无 BOM，大小最多 65,536 字节，顶层只包含以下五个字段：

```json
{
  "schema_version": 1,
  "local_source_id": 4609999,
  "rx_policy": {
    "group_mode": "selected",
    "private_mode": "disabled",
    "allow_groups": [{ "destination_id": 91, "slot": 2 }],
    "allow_private_peers": [],
    "local_private_routes": [],
    "blocked_groups": [],
    "blocked_source_ids": []
  },
  "tx_target": { "destination_id": 460997, "kind": "private", "slot": 2 },
  "transmit_enabled": true
}
```

`rx_policy` 必须是完整 schema 2 策略，恰有七个字段：`group_mode`、`private_mode`、`allow_groups`、`allow_private_peers`、`local_private_routes`、`blocked_groups` 和 `blocked_source_ids`。路由数组保留 profile 中的全部条目；launcher 会拒绝未知字段、无效 ID/时隙、重复路由、allow/block 冲突，以及任何不等于本机 `source_id` 的本地私呼目的 ID。

`group_mode` 取 `selected` 或 `all_delivered`。`private_mode` 取 `disabled`、`selected_peers` 或 `all_peers_to_local`。本机私呼目的 ID 始终等于 `local_source_id`。在 `selected_peers` 模式下，只放行与 `allow_private_peers` 中 `source_id`、本机目的 ID 和时隙完全匹配的 peer。在 `all_peers_to_local` 模式下，放行集合是两部分的并集：目的为本机且时隙列于 `local_private_routes` 的任意 peer，以及与 `allow_private_peers` 中完整三元组精确匹配的 peer。`blocked_source_ids` 会在这两种规则之前屏蔽来源，因此精确 peer 项也不能覆盖来源屏蔽。`disabled` 模式不放行私呼，且两个私呼允许列表必须为空。

路由文件不写入密码、密码路径、callsign、服务器地址或设备 ID。TX 启动参数从同一个 `tx_target` 读取，因此传给 native 的 destination、kind 和 slot 与路由文件一致。`local_source_id` 来自当前 profile 的 `connection.source_id`。

## 旧配置读取

launcher 通过用户配置模块读取 schema 1 profile；模块在内存中迁移并校验为 schema 2，再从完整策略生成本次 `routing-state.json`。读取过程不保存迁移结果，也不覆盖旧配置。音量和设备选择继续由原有独立配置处理。

alpha6 对手工 profile 启动只传 `--routing-state-file` 作为接收策略来源。Native 为其它旧调用者保留单路接收启动参数兼容；alpha6 launcher 不使用这些参数表达用户策略。

## 本机入口与隔离配置

`start-merged-test.cmd` 启动本包 UI，并显式使用 `private/r108-merged-test-config`。这一路径独立于 alpha5 的 `private/r106-step1-test-config`、包内默认配置和 canonical `private/user-config`；UI 保存的 alpha6 测试设置只落入这一路径。

本机通用 manifest 审计通过后，交付流程可以在此目录准备三份用户文件：`connection-profile.json`、`audio-settings.json` 和 `password-file-path.txt`。最后一个文件只保存现有密码文件的绝对路径；交付流程不读取或复制密码文件内容。个人文件不进入通用包 manifest。

`test-control.cmd` 是单独的 IPC 管道诊断入口。它仅检查本包 native 的 `ready`、`hello`、`status`、`shutdown` 往返与退出码，不枚举串口或音频设备，也不连接 BrandMeister。

## 验收记录

源码验收由 launcher、用户配置、UI 预检与控制管道的离线测试覆盖。最终 C++ 离线测试数和顺序以 alpha6 release profile、构建 provenance 与 package manifest 三处一致记录为准。包目录检查核对文件路径、大小、SHA-256 和 ASCII asset 名称。设备、音频、BrandMeister、PTT 与 RF 行为需要另行安排受控验收；仅凭离线检查不能报告这些行为已通过。
