# R123 运行时 UI 交接

## 运行时行为

- 频道选择卡统一使用中性边框。当前 PTT 目标填充深绿 `#28583C`；只有该目标处于 `tx_active` 或 `tx_draining` 时改为深红 `#713237`。普通接收来话只显示来源呼号/ID，不把频道卡标成发射状态；静音也不改变 PTT 目标颜色。
- 呼号区与右侧 2×2 操作区使用同一个 78px 网格行。每页固定六个槽位。RenderOnly 实测卡片和两区域均落在自己的卡片边界内，第一排与第二排不重叠。
- 历史列表固定五行，分页显示；历史模型保留最多 50 条。
- 状态事件只在顶部损失指标后显示，使用现有 Dispatcher 计时约五秒。轮询重复旧消息不会延长期限或在过期后复现；新事件或显式 `-Restart` 才重新显示。长消息截短后仍可通过 Tooltip 查看原文。
- 无 BM API key 时静态组区保持原位，列表清空并禁用，整面显示“需启用BM API key”；输入、刷新、添加、移除和分页操作均禁用。具备 key 后沿用原有设备身份、模块、加载结果和 busy 条件恢复控件；此 UI 逻辑不发 BM 请求。
- 频道输入提供三个预设：460997 中国鹦鹉（private）、46001（group）、91（group）。来源为用户已实测的号码，本轮未通过在线资料核对或增加其他号码。手输会移除预设类型关联，类型由用户明确选择。加入监听仅在原 PTT 目标为空时用第一个频道初始化目标。
- 串口与 BM 各使用一个连接/断开按钮，并复用原有连接、断开、取消和 busy/错误重试路径；CAT 保留单一 Apply。

## 离线验证

使用 Windows PowerShell 5.1、STA 运行的集成 UI 回归已通过：console 121、channels 117、audio 85、R123 交互 54、BM 管理 80 项；status 状态记录回归通过。`test-ui-r123.ps1` 覆盖 transient 到期/重复 tick、新消息与显式重启、预设与手输、PTT 目标保留、卡片颜色、无 key 静态区，以及 BM toggle 的成功、拒绝和 busy 状态。BM 管理 UI 测试只使用本地 fake transport。RenderOnly 通过 1,919 项布局和实际边界断言，并输出截图。

Root review 曾发现重复的非法静态组 ID 错误在 transient 到期后不会重新显示；运行时现在只对这类新错误显式重启提示期限，普通轮询不续期。P2 修复已由集成回归复验。

Alpha 19 的正式候选已从修复提交 `b102cd630d49839eb99869f87958909cd365094d` 完成 clean Native full40 和重新打包。Windows PowerShell 5.1 的正式包 `test-package-startup.ps1`、`test-control.ps1`、`test-ui-control-v2.ps1` 均通过；最后一项使用 R121 保存的 13 帧 Native Dispatcher 数据并通过实际 parser。包启动诊断在 RX 更新 ACK 后找到“激活组”按钮，并观察到 `channel_flow_test.tx_command=tx_policy.replace`。定位时使用的隔离包副本与旧候选已保留归档，正式包未在生成后修改运行资产。

R123 离线 UI 回归和完整 Alpha 19 证据见 [R123 发布交接](R123_发布交接.md) 与 [Alpha 19 本机目录记录](releases/v0.1.0-alpha.19.md)。以上检查没有连接真实电台硬件、串口、BM API 或音频设备，也没有操作 PTT/RF。
```powershell
powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-console.ps1
powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-channels.ps1
powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-audio-gain.ps1
powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-status.ps1
powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-r123.ps1
powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-render.ps1
powershell.exe -NoLogo -NoProfile -STA -File tools/test-bm-management-ui.ps1
```

以上均为离线 UI 证据。本轮未连接电台硬件、串口或 BM API，也未操作 RF。