# S1-E 本地 native 会话验收

## 本切片范围

S1-E 将已分别验证过的 HRI 监听与固定 T3/PCM/T0 下行原型接入一个 native 会话。操作者通过 `tools/start-local-radio-session.cmd` 启动可见控制台，在检查本次枚举到的串口、radio USB WaveIn、PC WaveOut 和 PC 麦克风 WaveIn 后，输入 `START` 才启动 native。启动不会自动向电台发起下行播放或自动采集麦克风。

会话由一个 native 进程独占 HRI 串口和本次打开的 WaveIn/WaveOut。进入监听后，`F` 请求播放包内固定约 7.25 秒测试语句；`M` 开始最多 8 秒的 PC 麦克风内存采集，采集结束后才进入 T3/PCM/T0；`C` 取消当前操作；`Q` 收尾并退出。操作串行执行，已有操作进行时的新操作请求会被拒绝，不会覆盖当前操作。native 启动不会自动向电台发起下行播放或自动采集麦克风；进入监听后仍会按已选路径将 radio USB 输入送至 PC 输出。麦克风 PCM 只在内存缓冲区中暂存并在收尾时清理，不写成 WAV，也不写入报告或日志。

native 对串口控制记录、PC 音频提交与排空、进程资源清理分别记录结果。收到窗口内完整且校验通过的 T 类型记录只表示观察到了匹配阶段的记录；协议没有序号，延迟的完整记录仍可能无法严格关联。停止请求、PCM 排空、电台界面恢复或本机资源清理均不能证明电台 PTT 已释放、无线发射已经停止或 RF 状态已恢复，软件报告中的 `radio_state` 始终是 `unknown`。

## 时间和退出边界

会话主动运行窗口最多为 120 秒。操作者按 `Q`、stdin EOF、取消、错误或主动窗口到期后，若本次会话已经尝试 T3，native 至多再尝试一次有界 T0 收尾。首次进入收尾时最多保留 3 秒的停止记录/进程清理预算；重复取消不会重启或延长这个预算，所以总经过时间可以超过 120 秒，但收尾不会重新获得新的 120 秒。若系统提前终止进程或设备清理失败，报告可能只保留非最终状态或失败状态，不能据此推断电台恢复。

## 可重复构建与离线验证

从 `app` Git 根目录使用 Windows PowerShell 5.1 和本机已安装的 VS 2019 Build Tools：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-radio-session.ps1
```

脚本用本机 `vswhere.exe` 查找 VS 2019 x64 C++ 工具，不安装工具；使用 C++17、`/W4`、`/DNDEBUG`、`/MT` 编译 native 核心和 8 个离线测试，随后运行这 8 项测试。产物仅写入 `build\_work\radio-session-<HEAD短号>`；如果 Git 工作树有改动，目录名带 `-dirty`，并明确标记为开发验证产物。脚本不删除文件。提交并确认工作树干净后再运行，才会生成可用于本地候选目录的干净提交构建。

本次开发构建命令已在 Windows PowerShell 5.1 中实际执行，8 项测试全部退出码为 0：

1. `hri_downlink_session_test`：下行协调器取消、超时、stop 收尾、重复/延迟记录与串行操作状态。
2. `hri_radio_protocol_test`：本机控制协议解析。
3. `operation_audio_cleanup_test`：操作级音频清理状态。
4. `audio_input_cleanup_test`：WaveIn 清理失败状态保持。
5. `wave_output_open_test`：WaveOut 部分准备失败后的关闭与句柄保持。
6. `session_report_test`：会话报告字段和状态。
7. `bounded_pipe_writer_test`：真实匿名 pipe 写满但无人读取、以及读端断开时的有界写入失败。
8. `session_timing_test`：120 秒主动期限与一次性 3 秒收尾预算。

同一提交的 native 核心以 VS 2019、`/W4 /DNDEBUG /MT` 独立编译，无编译警告。安全失败路径也已用独立子进程验证：缺少 Y 模板时退出码为 2；有效 Y/WAV 配合不存在的报告父目录时，native 在访问串口和音频前报告 `report_write_failed` 并以 2 退出；stdout 匿名 pipe 被填满且父进程不读取时，native 有界退出、报告 `protocol_stdout_write_failed`，串口保持 `not_opened`，采集与提交的 PCM 字节数均为 0。另在隐藏的新控制台用交互入口配合无效串口名进行前置检查，结果为 `port_name_invalid`，没有打开 COM，也没有采集音频。以上均未启动 HRI 会话，未操作电台。

## 尚未验证的内容

固定 WAV 下行曾作为独立原型获得用户听音确认，上行监听也有独立原型结果；两者不能替代对 S1-E 同一会话的人工验收。本切片尚未进行 HRI 实机运行、麦克风下行听音、连续多轮人工操作、完整冷启动、BrandMeister 接入、完整 UI 接入或 RF 验证。UI 可在基础会话稳定后接入；当前操作者只使用可见控制台。后续实机步骤必须由操作者明确启动，并按现场测试流程确认声音及电台界面；任何自动报告仍只反映软件观察，不是 RF 验收。
