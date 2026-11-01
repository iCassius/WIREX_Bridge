# R120 CAT 独立会话与稳定显示

## 目标与当前状态

用户在 alpha15 上仍观察到 CAT 区域闪烁。R120 把 CAT 串口会话从 Wires-X/HRI 生命周期中拆开，并追踪 CAT 轮询期间的 WPF 控件状态。此文档记录源代码与离线回归；真实电台和 COM 端口尚未验证。

本次改动涉及 `ui/windows/RadioCatUi.ps1`、CAT/UI 回归脚本以及 `MainWindow.xaml` 的 CAT 控件布局。没有新增 CAT 持久化字段或运行时资产。当前 UI 将 CAT 端口、波特率、“连接串口”“断开串口”和会话状态放在 CAT 区域；旧“读取电台”按钮已移除，首次读取由连接动作启动，后续由轮询更新。

CAT 控制器、桥接生命周期接线和两套 WPF 回归现已通过完整离线运行。回归通过 fake worker 检查了多轮刷新、独立串口会话、写入门控与worker收尾。真实电台、真实 COM 和用户 alpha15 实机闪烁现象仍未验证。

## 根因证据与代码变化

对原 CAT 控制器逐阶段检查发现，普通查询也被当作全局“忙”状态处理：worker 开始时改变 CAT 操作控件的 `IsEnabled`，查询结束后再恢复。轮询每隔一秒重复这一过程，即使串口读值没有变化，按钮状态仍会来回改变。

原观测刷新流程还会在每次调用时先清空若干读数，再写入观测值。WPF 会把清空和回填分别渲染，用户会看到读数短暂消失。Mode、频率编辑器和功率滑块也容易被观测刷新重复回填。只看一次 fake query 的最终值，无法发现这些跨 worker 的中间变化。

R120 控制器当前采用以下规则：

- 正常 query 保持会话状态为“已连接”；连接首读、失败、断开和退出分别使用独立状态，不在每轮 query 中切换状态文案。
- 读数只有在新文本与屏幕文本不相同时才赋值。保留用户编辑草稿时，观测刷新不覆盖 mode、频率或功率编辑器。
- 功率滑块在范围和值均未变化时不重设范围和值；程序回填期间屏蔽 `ValueChanged` 草稿事件。
- 普通 query 不反复禁用 action 按钮。query 在途时用户明确提交的动作冻结目标、端口、波特率、停止位和 CAT generation；当前 query 完成并通过硬件身份与 TX 状态检查后最多写一次。失败、取消、断开或 CAT identity 变化会丢弃待办，不重试写入。

回归用例必须在多个完整 query worker 周期的“worker 在途”“worker 完成并回写”两个边界分别快照 `Enabled`、`Visibility`、显示文字、编辑器选中项与草稿、slider range/value、session state 和 action 按钮。读数变化时允许新观测文字更新一次；同一值的重复 query 不应清空或重写读数。只比较最终画面不能证明闪烁问题已经解决。

## CAT 生命周期合同

`Get-UiRadioCatSessionState` 返回 `requested`、`connected`、`polling`、`operation`、`error`、`shutdown`、`generation` 和 `state`。它是 CAT 自己的会话状态；CAT ready 不从 Wires-X supervisor 或 HRI status 推断。

此状态对象另含派生字段 `user_action_busy`：CAT write worker、冻结的单槽用户动作、mode/frequency fresh-query 请求或等待 core stop 的 mode/frequency 请求存在时为 true；普通 query 为 false。桥接在保存/启动 Wires-X 时用此字段识别用户正在等待的 CAT 写动作，普通 CAT query 不锁住 Wires-X 启动。

`Test-UiRadioCatPortConflictWithHri -HriPortName <最终HRI端口>` 用于检查准备启动的 HRI 端口是否与 CAT 正在使用的端口或仍在收尾的 CAT worker 端口相同。该检查不把 HRI port 加入 CAT connection key；CAT-only 操作不会被闲置的已保存 HRI 端口阻止。

`Connect-UiRadioCatSession`、`Disconnect-UiRadioCatSession`、`Stop-UiRadioCatSession` 的合同如下：

- 主连接首次完成准备后可调用 `Connect-UiRadioCatSession -Automatic`。正常应用中允许自动开始 CAT 首读；同一会话重复请求不会并发开第二个 worker。
- 用户可在没有 BM/HRI 核心时单独连接 CAT、读取状态及执行被 fresh query 授权的 CAT 操作。
- 用户断开 CAT 会递增 CAT generation，清除单槽用户动作、等待 Wires stop 的 mode/frequency 请求和等待 fresh query 的请求，再仅取消 CAT worker。它不停止 supervisor、不改变 Wires stop 任务。
- 同一 app session 中，用户手动断开后，HRI reconnect 与 unexpected exit 不会自动重开 CAT。用户再次点击“连接串口”可解除该 latch。
- 普通 Wires stop 和 native unexpected exit 不取消或等待独立 CAT worker；用户明确设置 MAIN mode/frequency 时仍走原有“先停止活核心、fresh query、再写入”的事务。
- CAT-only 仅指 supervisor 不存在或已退出。活 supervisor 即使当前 status 报告 `hri_serial_open=false`，也不能直接写 MAIN mode/frequency；status 过期或忙时拒绝，空闲时先停止核心并 fresh query。
- app shutdown 必须取消 CAT 请求并收尾 worker。`Stop-UiRadioCatSession -Reason app_shutdown` 在没有 worker 时返回 `$true`；worker 仍在结束时请求停止并返回 `$false`。窗口需等 CAT operation completion 清理 runspace 与串口后再关闭。
- `Connect` 在旧 CAT worker 释放前返回失败，UI 连接按钮保持禁用，避免断开后马上打开第二个 CAT worker。

CAT generation/连接身份使用 CAT 端口、波特率、停止位及本次 CAT generation；硬件身份由 CAT 模块确认 FTX-1 Hardware ID `0840`。HRI port/run ID 不参与 CAT session key。HRI fresh idle/TX 状态只在写操作时作为安全门。

端口选择继续使用 Enhanced 关键词和现有自动挑选逻辑；端口目录发现不会打开串口。CAT 端口和波特率只在 CAT 断开、worker 不存在时可修改，不随 Wires-X 配置锁定。

## 隔离模式与离线边界

`RenderOnly`、`OfflinePreview` 和 `RoutingDiagnostic` 不能因枚举到 COM 端口、主窗口加载或核心准备而触发 CAT 串口 I/O。RadioCat controller 在这些隔离模式下仅允许带有显式 `uiTestHooks.CatOperation` fake worker 的测试调用；缺少该 hook 时，Connect 返回失败，Start operation 在创建 worker 前拒绝。

普通 `NoAutoConnect` 不属于隔离预览：它只阻止 CAT 自动连接，用户仍可手动连接 CAT-only 会话。无 supervisor 的手动 mode/frequency 写仍要求新鲜 CAT query、身份、端口、generation 和 TX 状态检查。

## 验证范围

自动化回归使用真实 WPF 控件和显式 fake CAT worker，不打开真实 COM，不访问 BM 网络，不执行真实 PTT/RF，不运行普通启动流程，不读取或写入用户真实配置。

已完成的离线回归：

- `tools/test-ui-radio-cat.ps1`：139 项断言通过。测试覆盖隔离模式 fake hook、NoAutoConnect、四轮多值 query 中控件属性快照、独立 CAT 会话、单槽动作、活 core 下 mode/frequency stop + fresh query、断开撤销等待 stop/fresh query 的事务、过期 TX、取消和 app shutdown worker 清理。
- `tools/test-ui-console.ps1`：130 项真实 WPF fake 交互断言通过。测试覆盖 BM/HRI 未启动时 CAT 手动连接、Disconnect 不停止活 HRI、HRI ready/reconnect 不越过手动断开 latch、普通 Wires stop/native exit 保留 CAT 会话、延迟 CAT query 的 worker 关闭后才开始 replacement query，以及 MAIN mode/frequency 写入。
- 两套脚本都分别在 PowerShell 7.6.5 与 Windows PowerShell 5.1.26100.8737 下通过。CAT controller 和相关脚本的 PowerShell parser 检查也通过。

这些结果只说明 fake worker、源代码和本机 WPF 回归路径的行为。没有测试打开真实 COM、BM 网络、PTT/RF 或用户配置。只有接上目标电台及已知 COM 口并完成单独授权的实机验证后，才能记录 alpha15 用户看到的闪烁是否在真实串口轮询中消失。
