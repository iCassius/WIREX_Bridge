# R121 Native 检查点

## 已确认

- Alpha16 手动保存失败的根因是 `Get-UiComboValue` 把 `ComboBoxItem.Tag` 中的选项对象转成字符串；`Save-WirexPortableConfig` 随后拒绝该设备值。WinPS 5.1 的 WPF 临时窗口复现了 `Save-SettingsFromWindow` 返回失败、显示通用错误且未写配置文件。没有读取真实配置或凭据。
- 生产 Native 当前由单个 `bm::Session` 与 `bm::UdpTransport` 管 BM 网络；HRI 会话由同一主循环独立驱动。HRI standalone 诊断模式不能与生产进程并行占用同一串口/音频资源。

## R121 Native 合同

- UI v2 命令：`bm.connection.set`，参数只含 `{enabled:boolean, revision:uint64正数}`。不从管道接收密码或 Master 地址。
- 状态与命令应答都包含 `bm_connection:{requested_enabled,revision,transport_open}`、`bm_resolving:boolean`、`bm_connection_error:string` 及顶层 `bm_state`。
- 顶层 `bm_state` 始终序列化真实 `bm::Session` 状态：`idle`、`waiting_login_ack`、`waiting_auth_ack`、`waiting_config_ack`、`waiting_options_ack`、`ready`、`backoff`、`stopped`。DNS 等待时由 `requested_enabled=true`、`bm_resolving=true`、`transport_open=false`、`bm_state=stopped` 表示。
- 安全 `bm_connection_error`：`none`、`password_required`、`master_resolution_failed`、`master_resolution_timeout`、`resolver_cancel_timeout`、`profile_invalid`、`transport_open_failed`、`media_cleanup_timeout`。旧 `bm_failure` 保留原含义。
- `bm_resolving=true` 不只表示启用中的DNS查询；disable取消旧查询时也会保持为true，直到系统resolver上下文真正回收。两类合法快照分别为：启用解析 `{requested_enabled=true, transport_open=false, bm_state=stopped, error=none}`；取消解析 `{requested_enabled=false, transport_open=false, bm_state=stopped, error=none|master_resolution_timeout|resolver_cancel_timeout}`。
- 有界媒体收尾失败时，manager会先报告 `{requested_enabled=false, transport_open=true, bm_state=<当前真实Session状态>, bm_resolving=false, error=media_cleanup_timeout}`，之后尽力发RPTCL并关闭UDP，最终transport_open=false、bm_state=stopped，保留该安全错误码。
- 同 revision、同 enabled 重放前一结果，不重复 DNS 或连接；同 revision 不同 enabled 和旧 revision 拒绝。更高 revision 才允许重试。
- `--bm-start-disconnected` 启动 HRI，不启动 BM session/UDP；无需 DNS 或密码。CAT 由 UI 单独管理。没有 flag 时保持原 BM 启动流程。
- BM disable 先阻止新媒体，有限等待 TX EOT / HRI T0 / 下行清理，再停止 BM session、尝试发送 RPTCL 并关闭 UDP。BM disable 不停止 HRI core。用户持续按住 PTT 时，重新连接必须等松开后的新按键边沿才可上行。
- 延迟 DNS 在主循环零等待轮询；disable/退出取消请求，旧 generation 结果不得开启 UDP。最多保留一个未完成的 resolver 操作。

## 文件 owner

- Native owner：`include/wirex/bm_connection_control.hpp`、`src/bm_connection_control.cpp`、`src/probe_main.cpp`、Native v2 协议头/实现、`CMakeLists.txt`、`tools/build-bm-bridge.ps1`、既有 Native C++ 测试。
- Runtime owner：WPF / PowerShell UI、`BridgeSupervisor.cs`、UI fake 与 UI parser 测试。Native 不修改这些文件。

## 当前进度

- 实现并接入完成。`ConnectionControl` 管理生产 `bm::Session` 与 `bm::UdpTransport`，支持 IPv4 字面量、异步 DNS、取消回收、revision 冲突/重放和 on/off/on 重启。
- BM session 在 `stopped` 后可安全重新启动；每轮启动会清除上一轮应用包、认证状态和计时状态。
- UI v2 协议支持 `bm.connection.set`，并输出真实 Session `bm_state`、BM 连接快照和受限安全错误码。
- `probe_main.cpp` 已接入 `--bm-start-disconnected`、v2 BM 命令回调、非阻塞 resolver 轮询和有界断连媒体屏障。paused 模式跳过初启 DNS，但会读取有效的本地 password-file；密码缺失时 HRI 仍可启动，用户点击 BM 连接后收到 `password_required`。
- paused 进程退出时，用户若从未发起 BM 连接，不会被记录成 BM 登录故障。取消中的 DNS 会保持 `bm_resolving=true` 直到 resolver 上下文回收；断连媒体超时会先如实报告 `media_cleanup_timeout` 和当前 Session/UDP 状态，再执行有界关闭。
- 最新 `probe_main.cpp`、`bm_connection_control.cpp`、`ui_control_protocol.cpp` 均由 MSVC 2019 以 `/W4 /permissive- /utf-8 /std:c++17` 单独编译通过。loopback 与协议测试源码也编译通过。
- Native 测试 owner 报告 `bm_bridge_loopback_test` 与 `ui_control_protocol_v2_test` 当前源码构建后均 exit 0。交接入口：[BM loopback / manager lifecycle tests](../tests/bm_bridge_loopback_test.cpp)、[UI v2 protocol tests](../tests/ui_control_protocol_v2_test.cpp)、[CMake test/source registration](../CMakeLists.txt)、[MSVC build registration](../tools/build-bm-bridge.ps1)。
- 全套40项测试尚未运行；没有运行真实 HRI/CAT 串口、音频设备、BM 外网或 RF 验收。
- `git diff --check` 通过；本次Native源文件、头文件与文档均为 UTF-8 无 BOM。Save 失败的合成复现已完成，没有读取真实配置或凭据。

## 后续集成边界

root 负责审阅跨 Native/UI 的最终 diff、运行完整40项集成测试并判断是否需要后续修正。本轮证据只覆盖源文件编译、两个 Native 离线测试目标和合成 Save 复现；不覆盖真实电台、串口、音频设备、BM 外网或 RF 行为。
