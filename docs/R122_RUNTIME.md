# R122 运行逻辑

## DMR ID 与设备编号

设置页保留 `SourceBox` 作为本机 DMR ID，新增 `DeviceNumberBox` 输入两位设备编号 `00`–`99`。保存或连接时，用户明确修改 DMR ID 或选择设备编号后，应用按 `Gateway = DMR ID × 100 + 设备编号` 生成 Native 所需的完整 Gateway。Native、CAT 以外的桥接协议字段仍使用完整 Gateway；配置 schema 不增加字段。

加载旧配置时，若正数 DMR ID 的 Gateway 位于 `DMR ID × 100` 至 `DMR ID × 100 + 99`，界面拆出末两位作为设备编号。若 Gateway 等于 DMR ID（旧 bare ID）或不在该范围（包括无法确认设备编号的旧长 ID），界面把编号留空。只要用户没有改动 DMR ID 或选择编号，保存和连接会保留原 DMR ID 与完整 Gateway。用户改了 DMR ID 却没有选择编号时，保存返回字段错误，不写磁盘也不替换内存配置。新的空配置显示默认编号 `01`；在 DMR ID 仍为空时保存继续保留 Gateway `0`。

界面不再显示色码。读取和保存继续保留配置中的既有 `color_code`；新配置沿用 PortableConfig 的默认值 `1`，BM 相关字段不会因保存界面设置而删除或清零。

## 频道添加与 PTT 目标

“同时设为 PTT 目标”复选框和重复的切换说明已移除。添加频道只写入监听列表；如果配置尚无任何 TX 目标，首个频道按既有默认规则初始化为目标。配置已有 TX 目标时，添加频道保留原目标。后续目标变更只能由频道卡片上的“设为呼叫”操作发起。

诊断的添加频道步骤验证监听列表更新及既有 TX 目标值保持不变。若 Native 已报告可用的 TX 目标，结果把 TX 记为 `unchanged`；若 Native 暂未启用该目标、主窗口需先用 `tx_policy.replace` 同步同一个原目标，诊断先核对该 TX ACK，再核对 `rx_policy.replace` ACK。结果的 `tx_command` 记录实际路径，`ptt_unchanged_after_add` 只在目标 key 和已保存配置仍是原值时置为 true。

## RenderOnly 布局诊断

`-RenderOnly` 仍使用隔离的临时配置目录，不连接 CAT、BM 或 HRI。输出 JSON 的 `layout.main.controls_bounds.<控件名>.actual` 提供窗口坐标下的实际位置和尺寸，`visible` 记录是否显示。静态 bounds 清单覆盖主窗口交互控件，包括 CAT 单一 Apply、DMR ID、设备编号、音频端点和音量、串口/BM/频道操作以及 CAT 状态文本。

频道卡片按钮矩形在 `layout.main.channel_card_layout.buttons_bounds` 中按数组输出，每项字段为 `name`、`action`、`text`、`x`、`y`、`width`、`height`、`visible`；没有频道卡片时输出空数组。

CAT 设置页现在只用 `ApplyCatSettingsButton`。bridge 的 WPF 回归通过真实 MainWindow 点击一次按钮，核对控制器按 query、mode、frequency、power 的顺序确认读回，并确认设置批次期间 HRI supervisor 没有收到 `StopAsync`。CAT 字段级失败、取消和读取回归由 `test-ui-radio-cat.ps1` 覆盖。

Fake supervisor 不提供状态管道。`test-ui-console.ps1` 在已接受合成空闲状态后，按 dispatcher 心跳刷新假的空闲/队列状态；如果状态字段显示 PTT 活跃或队列非空，fixture 不覆盖这些字段。这样保留生产代码的 3 秒状态新鲜度检查，同时让多个 CAT 操作的隔离测试能持续模拟健康空闲核心。

## 验证范围

WinPS 5.1 STA 的隔离 WPF/fake 回归用于验证配置转换、界面事件和控制器交接；它们没有连接真实设备、读写用户配置或发送射频。

以下命令在 Windows PowerShell 5.1 STA 下通过：

```powershell
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -STA -File 'tools\test-ui-r122.ps1'
# PASS: 29 DMR ID / Gateway compatibility assertions

& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -STA -File 'tools\test-ui-channels.ps1'
# PASS: 115 channel / PTT / WPF interaction assertions

& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -STA -File 'tools\test-ui-console.ps1'
# PASS: 121 real-WPF interaction assertions, including the shared CAT Apply batch and cancellation

& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -STA -File 'tools\test-ui-render.ps1'
# PASS: 2128 layout assertions; main/settings windows rendered and visually inspected
```

## alpha18 发布准备离线检查

- 源码阶段的 WPF、频道和 DMR ID 回归已按上方清单通过。主窗口布局另通过 2128 项 RenderOnly 断言，并检查主窗口与设置窗口截图。
- `tools/test-package-release.ps1` 通过 656 项断言；alpha18 profile 保留 41 项映射资产、37 个源码映射、9 个目录和原顺序的 40 项 Native 测试名。
- `tools/test-publish-release.ps1` 通过 136 项离线断言，`tools/test-download-release.ps1` 通过 2817 项离线断言。两个方向均校验 alpha18 沿用 alpha17 的资产/测试清单，并拒绝缺少 `config.json` 排除规则或将用户配置放进通用包的 manifest。
- 这些发布与下载检查使用合成 manifest 和文件，不发网络请求，也不下载或安装 Release。为定位原 alpha18 真实 IPC 失败，本轮在 `build/_work` 创建隔离副本，只替换副本中的 `bridge-ui.ps1` 并更新其 manifest 文件记录的长度/hash，然后运行 `tools/test-package-startup.ps1`。alpha18 包级检查通过，实际报告 `channel_flow_test.tx_command=tx_policy.replace`，并核对 Native 回执及已保存配置仍指向原 TX 目标；覆盖真实 WPF `BridgeSupervisor` → Native RoutingDiagnosticAutoTest。没有连接电台、BM、音频设备或 RF，也没有访问用户配置。原 alpha18 包没有修改。
- 该诊断副本用于定位源码修复，不作为发布包验收。冻结源码后仍须重新 clean build，并在原样 manifest 的新候选包上复跑包级检查。
- 本轮所有界面、CAT、BM、HRI、音频和射频行为仍没有连接实机验收；CAT 与 HRI 同时运行的效果仍需按独立实机流程确认。
