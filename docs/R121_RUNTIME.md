# R121 运行时交接

## 当前实现

- Save 缺陷由 fake 复现并修复：设备 ComboBox 的 Tag 对象含 Value，旧逻辑把整个对象转成字符串，PortableConfig 因 HRI 端口值无效而拒绝保存。现在会读取 Tag.Value，并兼容标量 Tag 与原始对象值。
- Save 先在保留未知字段的候选配置中收集控件值、校验并原子保存；保存成功后才更新内存配置、profile 和选中项。失败会保留原磁盘与内存值，错误消息包含字段或安全错误类型，不回显异常原文或凭据。
- 空 BM 密码可用于串口暂停准备：UI 不创建空密码文件，不传 PasswordFile 或 RequirePasswordFile；暂停模式跳过 legacy 默认密码文件。实际点击“连接 BM”仍要求填写密码，缺失时显示字段错误且不发 BM 命令。
- 五个按钮按冻结的五按钮合同接线：串口连接以 BM 暂停模式启动 HRI，并在就绪后连接 CAT；BM 连接/断开独立控制；串口断开先请求 BM 关闭，收到真正关闭快照后清理 CAT 与 HRI；保存仅保存；退出清理所有会话。断开等待有 15 秒整体期限。
- BM parser 按真实协议接受 DNS 取消中的 resolving 状态、媒体清理超时但 UDP 仍开着的状态，以及关闭后的最终快照；accepted ACK 只表示 Native 收到请求。它也接受旧核心返回的 unsupported+snapshot、hello_required 和 invalid_bm_connection_parameters，并按新 control_ready 重置下一 run 的 parser 上下文。
- 无 BM handler 的 protocol diagnostic 不广告 BM capability，且快照必须保持 `bm_state=not_started`；诊断状态若声明 BM capability 或把从未启动的 Session 写成 `stopped` 会被拒绝。正常 BM handler 的快照仍由真实 Session 状态枚举及连接状态关系严格校验。
- BM 状态恢复以新鲜 JSONL 状态为主。只有新鲜 status_jsonl 能重置恢复额度；ACK 和一次性 control_status 不会续期额度。状态缺失时最多发送 3 个恢复查询，新的 BM 用户请求可建立独立额度。串口断开意图会等待 DNS 或媒体清理状态继续到实际关闭，超时后显示仍在线的真实状态。
- CAT 功率操作在 BM paused 时不依赖 ptt_gate_ready，但仍要求新鲜空闲状态、PTT released、无活动呼叫、媒体队列为空、CAT TX=0 和身份代际有效。MAIN 模式/频率操作保留“停止 HRI、保留 CAT、fresh query、一次写入并读回”流程。CAT 串口活动或操作期间锁定端口、波特率和设备刷新，核心停止后仍不解锁被占用的 CAT 串口。
- 呼号历史保留完整 50 条模型并分页显示三条；key 去重、新来话插入、目标稳定和离页身份回写均覆盖 fake。频道固定 3×2；按钮区约为 R120 宽度的 76%，RenderOnly 可见六个槽。历史和静态组分页保持固定尺寸且无滚动条。

## 最新检查结果

以下均为 fake、临时隔离配置、WPF 离线交互、RenderOnly 或真实 Native Dispatcher 生成的无网络协议帧：

- `tools/test-ui-radio-cat.ps1`：190 项断言通过；覆盖空密码暂停准备、520 个无新鲜 JSONL tick 且每次 control_status 都成功时总计仍只发 3 次恢复查询，以及新 BM 请求反向断开仍可用。
- `tools/test-ui-console.ps1`：130 项真实 WPF 断言通过；操作日志确认 fresh query 后恰好一次 setMode，并收到确认读回；CAT 独立占用时端口与设备刷新保持锁定。
- `tools/test-ui-channels.ps1`：112 项断言通过。
- `tools/test-ui-audio-gain.ps1`：82 项断言通过。
- `tools/test-ui-status.ps1` 与 `tools/test-ui-identity.ps1`：通过。
- `tools/test-ui-render.ps1`：214 项 RenderOnly 布局/对比度断言通过，历史当前页三行完整可见，静态组与六个频道槽均使用合成数据。
- `tools/test-ui-control-v2.ps1 -ParserOnly -BmProtocolFramesPath`：PowerShell parser 解析 Native 生产 Dispatcher 的 13 行帧通过，覆盖 prehello、malformed、unsupported、DNS 取消、media timeout、最终关闭和多 run capability 隔离。
- `tools/test-start-bm-radio-bridge.ps1` 与 `tools/test-ui-preparation.ps1`：通过；runner fake 验证 BM 暂停无密码时不继承 legacy 密码文件，显式密码仍使用指定临时文件。

## 宿主复核状态

- Runtime owner 与 root 在 Windows PowerShell 5.1 -STA 下分别独立运行 RadioCat 190 项、Console 130 项，均 exit 0；WinPS 5.1 发布入口检查已有三方通过结果。
- Root 又独立运行 Windows PowerShell 5.1 的 `tools/test-control.ps1` 和 source `tools/test-ui-control-v2.ps1` WPF `BridgeSupervisor`→Native 匿名管道联测，均 exit 0；使用临时诊断核心，没有打开真实串口、音频或 BM 网络。旧 alpha17 候选包仍含修复前的 parser，不能用作本轮结果。
- 13 帧 Native Dispatcher 样本已由实际 PowerShell parser 解析通过。PowerShell 7 遇到的间歇 fixture 结果保留另查，不作为本版 UI 验收依据；最终独立 review 未发现可复现 P1/P2。

上述宿主复核使用 fake、临时隔离配置、WPF 离线交互或合成 Dispatcher 帧。未连接真实 COM、CAT、音频、PTT、RF 或 BM，也未读取真实配置、凭据或哈希。full40、alpha.17 完整包和包级验证以 source freeze 后的正式构建记录为准。

## 文件所有者

| 所有者 | 文件 |
| --- | --- |
| R121 runtime | `ui/windows/bridge-ui.ps1`、`ui/windows/RadioCatUi.ps1`、`ui/windows/BridgeSupervisor.cs`、`tools/start-bm-radio-bridge.ps1`、`tools/test-start-bm-radio-bridge.ps1`、`tools/test-ui-preparation.ps1`、`tools/test-ui-radio-cat.ps1`、`tools/test-ui-console.ps1`、`tools/test-ui-audio-gain.ps1`、`tools/test-ui-control-v2.ps1`、`docs/R121_RUNTIME.md` |
| R121 layout | `ui/windows/MainWindow.xaml`、`ui/windows/BmManagementUi.ps1`、`tools/test-bm-management-ui.ps1`、`tools/test-ui-render.ps1`、`docs/R121_UI.md` |
| R121 Native | `include/wirex/bm_connection_control.hpp`、`src/bm_connection_control.cpp`、`src/bm_session.cpp`、`src/ui_control_protocol.cpp`、相关 Native C++ tests 与 BM loopback 工具、`docs/R121_NATIVE.md`、`docs/R121_NATIVE_TESTS.md` |
| Alpha17 发布准备 | `tools/package-release.ps1`、`tools/publish-release.ps1`、`tools/download-release.ps1`、对应 tests、Alpha17 启动器与 package README |
