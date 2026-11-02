# R123 CAT 界面

## 控件与交互

- 主窗口的 `SerialConnectButton` 是唯一串口连接按钮。空闲且断开时显示“连接串口”；HRI 或 CAT 会话活动时显示“断开串口”；HRI 正在准备连接时显示“取消连接”。点击分别调用现有 `Connect-UiSerialCombo` / `Disconnect-UiSerialCombo` 流程，保持 BM 关闭后再收尾 HRI 与 CAT 的顺序。
- CAT 模式、MAIN 频率和功率使用三个并列输入控件，并共享一个 `ApplyCatSettingsButton`。频率控件保持可编辑；用户输入由 `PART_EditableTextBox.TextChanged` 创建草稿，电台当前频率作为可选项显示，不添加其他频率预设。
- 功率默认选中 25 W，但加载或读取状态时不会发送写入。预设为 5、10、15、25、50 W。读取到 9 W、40 W 等非预设当前值时，界面追加并选中该读值；仅在用户明确选择后才把它作为草稿。
- FieldHead 路径只允许最高 10 W。高于上限的条目保持可见并禁选；如果已有功率草稿超过新读到的上限，界面保留原草稿、禁用 Apply，等待用户重新选择合法功率。
- Apply 先重新读取身份、MAIN 模式、MAIN 频率、功率路径与 TX 状态，再按模式、频率、功率顺序逐项发送变化字段并逐项核对读回。相同字段跳过写入；过程保留 CAT 端口冲突检查、会话代次、HRI 空闲状态新鲜度和原有 CAT 通信门限。
- 操作结果通过运行时 `Set-UiTransientStatus` 显示约 5 秒；完整说明可由提示工具显示。界面不再依赖 `SerialDisconnectButton`、`CatSessionStatusText`、`CatPowerSlider`、`CatDesiredPowerText` 或 `CatOperationStatusText`。

## 离线验证

使用 Windows PowerShell 5.1 STA 运行 `tools/test-ui-radio-cat.ps1`。该脚本加载实际 WPF 窗口和 UI 函数，并以 fake transport 覆盖连接按钮状态、连接失败、准备中取消、非预设功率读值、FieldHead 上限、频率编辑与选取、统一 Apply、端口冲突、忙状态、取消收尾，以及串口/BM 关闭顺序。来话历史测试按每页五行覆盖分页、选中项、页外身份回写、去重和最近 50 条保留。

本轮完整 STA 回归通过，197 条 fake 断言通过。测试没有打开真实串口，也没有操作真实音频、BM 或 RF。
