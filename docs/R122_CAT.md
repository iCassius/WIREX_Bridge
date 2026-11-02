# R122 CAT 单次应用

## 依据

八重洲《FTX-1 Series CAT Operation Reference Manual》（2508-C）将 Enhanced COM / CAT-1 用于频率和通信模式设置，并列出 CAT 控制命令。手册第 2–3 页说明 CAT-1、CAT-2 的用途；第 17 页列出 MAIN 频率 `FA`；第 20 页列出模式 `MD`。手册没有说通过 CAT-1 设置 MAIN 模式或频率前必须停止 HRI，也没有明确说明这些设置与所有 HRI 固件组合都可同时工作。后一问题仍需实机核对，不能从手册未提限制推定为已验证。

- 官方手册：[FTX-1 Series CAT Operation Reference Manual (2508-C)](https://www.yaesu.com/Files/4CB893D7-1018-01AF-FA97E9E9AD48B50C/FTX-1_CAT_OM_ENG_2508-C.pdf)
- 本地研究副本：`../../../firmware/docs/FTX-1_CAT_OM_ENG_2508-C.pdf`
- R116 当时为 MAIN VFO 设置增加 `StopAsync(5000)`，是项目采取的保守流程；R121 保留了这个流程。现有手册没有提供必须停 HRI 的依据，本轮移除 CAT 应用主动停止核心的动作。

## 单次应用行为

用户在唯一的“应用”按钮点击时，界面冻结 MAIN 模式、频率、功率以及 CAT 端口、串口格式和 CAT generation。点击先启动 CAT query，要求本次读取确认设备 ID `0840`、`TX=0`、MAIN 模式/频率及功率路径和值；运行中的核心还必须在最近 3 秒内报告 PTT released、没有活动通话、接收媒体空闲或已过滤、接收队列为空。

界面按 MAIN 模式、MAIN 频率、功率顺序处理冻结目标。查询已读到等于目标的字段时跳过设置帧并记录该字段一致。需要修改的字段各自使用 CAT 模块的短期单字段操作：再次核对设备身份与 TX 状态、读取当前字段、在实际写入前复核 `TX=0`、最多写入一次、读取并精确比较回值，随后确认串口关闭。每一步完成后再启动下一步，因此失败、忙碌或 CAT/core 状态过期会停止后续字段。

处理顺序不构成原子事务。界面逐字段显示已确认、原本一致、未获确认和未执行的结果；后续失败时不尝试逆向恢复此前已读回的射频设置，也不把整组标为成功。断开 CAT 或停止并退出会清除冻结请求、递增 CAT generation 并取消当前 worker；迟到结果不能启动后续写入。没有 HRI/BM 会话时仍可执行 CAT-only 应用。

## 文件与检查

- `ui/windows/RadioCatUi.ps1`：唯一按钮接线、冻结目标、状态门、逐字段调度与取消。
- `ui/windows/RadioCat.psm1`：复用现有 `setMode`、`setFrequency`、`setPower` 单字段 CAT query/write/readback；本轮不增加命令或 Native 协议。
- `tools/test-radio-cat.ps1`：fake CAT transport 回归通过，56 项断言；包含 MAIN 模式和频率相同目标跳过写帧、模式/频率/功率写入读回、拒绝与TX忙状态。
- `tools/test-ui-radio-cat.ps1`：WPF fake 回归通过，168 项断言；覆盖单按钮冻结三项目标、HRI supervisor `StopAsync` 调用为零、逐项读回、未变字段不写、仅功率变化、失败后不执行后续字段、核心空闲忙碌和过期门禁、断开和退出取消迟到操作。
- 集成和界面检查：`tools/test-ui-console.ps1` 由并行实现者在 Windows PowerShell 5.1 STA 通过，121 项断言，包含 MainWindow 单次应用、三字段回读和 FieldHead 9 W；`tools/test-ui-render.ps1` 的 RenderOnly 通过，2,128 项断言。
- PowerShell parser 检查通过；上述三个 CAT PowerShell 文件均保留 UTF-8 BOM。本文记录基线 `b5482832d1c259645bfee7b7cecd1bf15cfee7fc`。
- 本轮没有连接真实 CAT COM、FTX-1、HRI、BrandMeister，没有发送 PTT 或发射 RF；CAT 写入与 HRI 同时运行的效果仍未实机验证。
