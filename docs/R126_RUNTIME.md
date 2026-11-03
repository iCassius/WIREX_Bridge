# R126 运行状态与来话历史

## 任务与基线

R126 从 R125 本机测试包源码提交 `2d8b7ea` 开始。本记录覆盖来话收尾事件分类、主界面历史分页、动态频道卡片字号和主窗体图标入口；没有连接 BM、CAT、串口、电台音频、PTT 或射频设备。

## R125 日志核查与根因

核查仅读取 R125 包 `runtime/private/runtime` 下 BM 运行日志的事件码及状态字段。没有读取 `preparation.json`、RadioID 缓存、实际配置或凭据，也没有输出或计算配置哈希。

两条 `downlink_call_bounded_cleanup_incomplete` 记录都带有 `rx_call_end_reason=cancelled`、`rx_cleanup_result=completed`、`media_owner=idle`、`receive_media_state=idle`、`bm_failure=none` 和 `waveout_state=closed`。日志格式没有记录 `stop_write_succeeded` 或 `stop_t_record_observed`，所以事件码本身不能证明 T0 超时。

源码原先只在 `reason=none` 且 T0 已观察时报告 `downlink_call_drained_t0_observed`，其他结束原因都会报告“清理未完成”。实际设置 `downlink_blocked` 的条件则更窄，只包括 T0 写入失败、未观察到 T0、明确的 T0 写入失败或 T0 记录超时。因取消结束但已完成 T0 和音频关闭的通话会收到错误的清理失败事件。

正常结束期间的状态快照会短暂出现 `media_owner=rx_draining`、`rx_stopping` 和 `receive_media_state=draining/stopping`，之后转为 `idle` 与 `rx_cleanup_result=completed`。这些状态是状态快照，不是清理失败事件。

## R126 行为

- Native 只在 WaveOut 关闭失败、已启动 HRI 但未成功写入或观察到 T0，或明确记录 T0 写入失败/超时时发出 `downlink_call_bounded_cleanup_incomplete`。取消或其他结束原因在清理成功时不再发出该错误事件；正常 T0 收尾事件继续要求无结束原因、T0 已确认且音频关闭成功。已有 `downlink_blocked` 和失败记录路径保持原条件。
- UI 将真实清理失败显示为红色的“来话结束清理失败；电台状态待核实”。正常完成文案收短为“来话结束”。UI 不把 `rx_draining` 或 `rx_stopping` 快照转成错误提示。
- 来话历史只在 `run_id + current_call_generation` 首次出现时插入新记录。新记录回到第 0 页并选中最新记录；同一状态 tick 的重复记录在分页和选中状态更新前去重，因此用户可暂时翻看历史，下一条新来话再回到最新页。
- 动态频道卡片标题、来话身份、DMR ID 和操作按钮字号各增加 1，固定卡片高度不变；RenderOnly 输出记录动态字号与布局高度，以便发现裁切。
- `CatObservedPanel` 在 XAML 中折叠，`CatObservedMainModeText` 保留名称。桥接脚本仍按名称更新观测文本，因此 CAT 状态读取与电台同步路径继续运行。
- 主窗体从便携根目录的 `WirexBridge.exe` 读取 `WIREX.ico` 程序集资源。图标缺失、损坏或无法解码时保持默认图标并继续启动。

## 离线验证

- Windows PowerShell 5.1 STA 对 `bridge-ui.ps1` 解析成功；文件保留 UTF-8 BOM。
- MSVC 针对性构建并运行现有 `hri_stream_session_test` 通过；新增断言覆盖正常取消、网络结束、T3 写入失败但 T0 收尾成功、T0 写入失败、T0 记录超时、T0 未观察、音频关闭失败及未启动 HRI 的路径，没有新增测试 target。
- `src/probe_main.cpp` 的 BM bridge 编译单元以 R125 配置参数编译通过。
- Windows PowerShell 5.1 STA 的 RenderOnly 回归通过 6,410 项布局/边界断言并目视检查截图。内置来话历史 probe 确认新记录回第 0 页、重复状态 tick 保持用户第 1 页；cleanup probe 确认失败文案显示红色、正常收尾文案为“来话结束”。
- 当前 R125 测试运行的 `main_window_icon_loaded=false`，因为该启动器尚未嵌入 `WIREX.ico`。已验证资源缺失时 UI 可以继续运行；图标资源的加载和实际显示待含资源的 launcher/package 验收。
- 本记录不构成完整 Native full40、真实 BM、CAT、音频、PTT、RF 或硬件验收。
