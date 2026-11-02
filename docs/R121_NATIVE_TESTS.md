# R121 Native 定向测试交接

## 本轮改动

- `CMakeLists.txt` 新增 `wirex_bm_connection_control` 库，注册 `src/bm_connection_control.cpp`，并将它链接到 `wirex_bridge` 与 `bm_bridge_loopback_test`。
- `tools/build-bm-bridge.ps1` 将管理器源加入既有 Native 源集合；脚本仍为 UTF-8 BOM，PowerShell 解析无错误。
- `tests/ui_control_protocol_v2_test.cpp` 增加 BM 切换能力声明、请求去重、请求 ID 冲突、修订号校验、无处理器时拒绝命令，以及媒体清理期间和超时后的真实状态序列化检查。
- `tests/bm_bridge_loopback_test.cpp` 增加 manager、FakeResolver 与 localhost FakeMaster 测试。测试通过生产 `bm::Session`、`bm::UdpTransport` 建立本机 UDP 登录握手，验证暂停无 UDP、enable/off/on、相同修订重放与冲突、异步解析取消、迟到解析结果不重开 socket、HRI tick 不等待解析，以及媒体清理超时后发送 RPTCL 并关闭 UDP。

## 定向验证

- MSVC 2019 对当前 `src/probe_main.cpp`、`src/bm_connection_control.cpp`、`src/ui_control_protocol.cpp`、`tests/ui_control_protocol_v2_test.cpp`、`tests/bm_bridge_loopback_test.cpp` 做 `/c` 编译，全部通过。
- 当前 `ui_control_protocol_v2_test.exe` 运行通过，输出：`ui_control_protocol_v2_test: all assertions passed`。
- 当前 `bm_bridge_loopback_test.exe` 运行通过，输出：`BM Bridge component loopback checks passed (localhost UDP, real codec/DMR/pipeline, synthetic HRI/audio sink).`
- 两个已运行的可执行文件位于 `C:\Users\cassi\AppData\Local\Temp\wirex-r121-native-targets\ui_control_protocol_v2_test.exe` 和 `C:\Users\cassi\AppData\Local\Temp\wirex-r121-native-targets\bm_bridge_loopback_test.exe`。`/c` 编译对象保存在同目录下的 `wirex-r121-native-obj` 与 `wirex-r121-native-targets\bm-loopback-*` 子目录。
- 跨端验收重新从当前 `tests/ui_control_protocol_v2_test.cpp`、`src/ui_control_protocol.cpp`、`src/routing_state.cpp`、`src/strict_json.cpp`、`src/radio_identity_cache.cpp` 与 `src/pcm_gain.cpp` 编译并链接 UI v2 定向目标。运行默认断言、生成真实 Dispatcher 帧后，将同一 JSONL 交给 `tools/test-ui-control-v2.ps1 -ParserOnly -BmProtocolFramesPath <path>`；两项均 exit 0。最终 exe、构建/解析记录和 13 帧样本分别位于 `C:\Users\cassi\AppData\Local\Temp\wirex-r121-native-targets\r121-bm-protocol-current-20261102-113605-536\ui_control_protocol_v2_test.exe`、`C:\Users\cassi\AppData\Local\Temp\wirex-r121-native-targets\r121-bm-protocol-current-20261102-113605-536\targeted-build-and-parser.log` 和 `C:\Users\cassi\AppData\Local\Temp\wirex-r121-native-targets\r121-bm-protocol-current-20261102-113605-536\r121-bm-protocol-frames.jsonl`。parser 输出确认它实际解析了 13 行，覆盖异步状态、revision=0 拒绝、安全错误码和 capability 隔离。
- 帧由 Dispatcher 的生产 JSON serializer 输出：第一 run 的 `run_id` 为 `9010-123456`、第二 run 为 `9020-123456`，普通 `request_id` 均为唯一 GUID。样本包含 pre-hello 与非法参数拒绝、DNS pending 与取消、transition busy、恢复连接、media cleanup timeout transport-open 快照、关闭后的 status，以及不支持 BM handler 的旧能力快照。
- CMake 与 `tools/build-bm-bridge.ps1` 各自仍登记 40 个 Native 测试；逐项按原顺序和 HEAD 比较，名字与顺序均未改变。
- `tools/build-bm-bridge.ps1` UTF-8 BOM 检查通过，PowerShell AST parser 错误数为 0；本轮文件 `git diff --check` 通过。

## 最终集成构建与包验证

- 最终源码提交 `245ed0348f66cbd6d181655185d5db849fe1c724` 上的干净构建通过 40/40 Native 测试，provenance 标记 `source_tree_clean=true`、`compile_only=false`，MSVC warning/error 均为 0。构建目录为 `build/_work/wirex-bridge-245ed03-20261102-042419`；完整日志为 `build/_work/r121-245ed0348f66cbd6d181655185d5db849fe1c724-clean-build-20261102-122418.log`。
- Root 独立审核 alpha17 包后，manifest 状态为 `root_audit_passed`。WinPS 5.1 的 package-startup、包 `test-control` 和包 UI control-v2 检查均 exit 0；最后一项把 Native Dispatcher 生成的13帧 JSONL交给实际 PowerShell parser。相关记录位于 `private/build-history/R121/verification-logs/`，13帧样本也保存在该目录。
- 包含 41 项 manifest 资产和 manifest 在内的通用包共42个文件；本机配置副本不属于 manifest。包、provenance、可执行文件和测试记录的 SHA-256 见 [Alpha 17 本机目录记录](releases/v0.1.0-alpha.17.md)。

## 验证边界

loopback 用例只在 localhost 上运行 FakeMaster 与测试 resolver，并使用合成 HRI/audio sink；完整 Native 构建使用离线测试。所有这些检查都没有连接真实 BrandMeister、串口、电台或音频设备，也没有验证 PTT、空口射频或设备侧行为。Alpha 17 为本机绿色目录，没有创建 ZIP、tag 或 GitHub Release。
