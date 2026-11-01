# R119 CAT 轮询稳定与 API Key 门控核对

日期：2026-11-01。此切片修复 CAT 每秒读取时 MAIN 编辑器和功率滑块反复禁用的问题，保留 R118 的串口清理、断开重连、同端口确认和 fresh-query 写入许可。另以只读源码检查及隔离 WPF fixture 核对 API Key 是否参与 BM 连接预检。

## CAT 自动同步链

- 正常连接完成后，`Complete-BridgePreparation` 启动 supervisor 并调用 `Start-UiRadioCatPolling`。该函数按当前 CAT 端口和串口参数建立 connection key，立即开始首读；主窗口的 250 ms dispatcher tick 按默认 1000 ms 轮询间隔安排后续 query。测试 fixture 的 Connect 分支也调用同一个启动函数。
- `Invoke-UiRadioCatPollTick` 在 CAT worker 未结束时跳过本周期，不累计查询。配置变化、端口离开设备目录、HRI 停止和窗口关闭仍走已有取消与收尾路径。
- 用户看到的观测值由 `Update-UiRadioCatObservationDisplay` 显示现有 `CatObservedMainModeText`、`CatObservedFrequencyText` 和 `CatObservedPowerText`；对应来源是 `main_mode`、`main_frequency_hz` 和 `power`。面板可见性由 CAT 模块可用状态决定，不随 query 的忙闲切换。

## 闪烁修复和写入门控

- `Update-UiRadioCatControls` 现在区分读 query 与写操作。普通 query 在途时，模式、频率编辑框和功率滑块保持可用；读取按钮和三个 Apply 按钮明确禁用。设置操作、连接准备、断开及其异步收尾期间仍会锁定编辑器。
- 单 worker 检查没有放宽。query 在途时，直接启动写操作仍会被拒绝；写权限仍要求当前 CAT connection key 对应的成功读取、有效能力、匹配的电台观测和现有运行空闲检查。query 失败或端口变化会清除写许可，但保留最近一次真实成功观测供界面显示。
- `Set-UiRadioCatPowerSliderRange` 只在范围或目标值实际变化时赋值；观测显示不再重复写入同一组滑块范围和值。正常轮询不会改变滑块值、触发 `ValueChanged`，也不会覆盖用户功率草稿。
- R118 中的旧 worker 收尾、COM 端口重枚举后的新会话首读、MAIN 模式/频率事务前的新 query、失败 query 不授权写操作等约束继续保留。

## API Key 与 BM 连接

- 统一配置要求 `connection.api_key` 字段存在并为字符串，但允许空字符串；PortableConfig 只限制类型和长度，不要求用户填写 API Key。
- 连接 profile 由 `ConvertFrom-UiPortableConfigToProfile` 生成，只包含呼号、设备 ID、服务器、端口、色码、频道和 HRI/音频端点，不带 password 或 API Key。普通 `Start-BridgeRun` 的连接预检明确检查 BM password 是否为空；准备阶段将 password 单独写入本次 session 的临时 password 文件并作为 `PasswordFile` 交给启动脚本。API Key 不参与该检查或 profile。
- `BmManagementUi.ps1` 将 API Key 用于 BM 静态组管理：没有 API Key 时静态组面板隐藏，刷新、添加和移除控件不可用。BM 的运行连接状态来自核心状态记录中的 `bm_state` / `bm_failure`；`ready` 显示为“已连接”，认证错误和超时由 BM 会话报告。
- 因此，空 API Key 会阻止静态组 API 请求，但源码没有用它阻止 BM 登录。空 API Key 与 BM 状态已连接可以同时出现；这也与用户提供的 Alpha 14 截图相符。此项结论来自源码和合成 fixture，没有检查本机真实配置、password、API Key 或运行日志。

## 隔离验证

`test-ui-radio-cat.ps1` 和 `test-ui-console.ps1` 均分别在 Windows PowerShell 5.1 与 PowerShell 7.6.5 通过。WPF 测试使用临时目录、fake CAT worker、fake supervisor 和 synthetic status record，没有打开真实 COM，也没有连接 BrandMeister、发送 PTT 或发射 RF。

- CAT 周期 query 测试在 worker busy 时重复刷新控制状态和观测显示，确认面板/控件可见性与 IsEnabled 不跳变，模式/频率文字、观测值、滑块范围和值保持稳定；功率草稿仍保留。三个写按钮及读取按钮在 query 在途时禁用，直接写入入口也由单 worker 门控拒绝。
- 空 API Key 测试确认 `BmApiKeyBox.Password` 和隔离配置 `api_key` 都为空时，WPF Connect 按钮仍进入 fake supervisor 路径。通过普通 metadata 验证的 synthetic record 随后显示 BM“已连接”和 HRI“就绪”；静态组面板继续隐藏，刷新与添加按钮保持禁用。该测试不声明真实 BM 网络登录成功。
- R118 的 CAT 超时、COM detach/re-enumeration、旧 worker 取消与清理、fresh-query 授权和 rejected readback 回归仍由两个脚本覆盖。

未执行真实电台、BM、PTT 或 RF 操作；未构建、发布或迁移个人配置。
