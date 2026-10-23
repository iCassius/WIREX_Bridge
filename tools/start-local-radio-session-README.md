# WIREX Bridge 本地电台会话启动器

这是首个本地链路测试版的可见控制台入口。它不安装服务、不启动图形 UI，也不连接 BrandMeister 或测试 RF。单文件夹便携包中，把本说明、`start-local-radio-session.ps1` 和 `.cmd` 与 `wirex_probe.exe` 放在同一目录，并放入 `private/device-y.bin` 和 `assets/voice-test.wav`。启动器只使用这个包内的相对路径；源码开发时可用 `-ProbePath`、`-BodyFile` 和 `-FixedWav` 显式指定构建文件。

已用项目内的 `app/build/_work/s1e/native-cleanup-review/wirex_probe.exe` 只读核对实际 native CLI：`--help` 列出的会话参数与启动器生成的参数一致，包括 `--hri-radio-session`、`--port`、`--body-file`、`--fixed-wav`、`--radio-input`、`--pc-output`、`--mic-input`、`--report-file` 和 `--interactive`；`--list-audio-json` 返回版本 1 的 `audio_devices` JSON，含 `wave_inputs`、`wave_outputs`、设备名称、当前 ID 和 PCM 格式查询结果。此次只运行帮助与音频能力枚举，没有启动 HRI 会话或打开采录音频流。启动器在未指定开发路径时，以脚本所在目录为包根，查找同目录的 `wirex_probe.exe`、`private/device-y.bin`、`assets/voice-test.wav`，并在同目录的 `logs` 中写报告；把文件按首段说明放在一起即可使用这个默认布局。

双击 `start-local-radio-session.cmd` 后，程序先校验核心文件、Y 模板和固定 WAV，再通过 native 的只读 `--list-audio-json` 列出本次 WaveIn/WaveOut 名称、ID 和 PCM 格式能力。枚举不会打开录音、播放或串口。操作者需明确选择当前 COM、radio USB WaveIn、PC WaveOut 和 PC 麦克风 WaveIn；不会默认选择音频设备。COM5 若出现在当前串口列表中，会作为可见提示值显示，按回车即表示确认 COM5。之前使用的 G6 只作为辨认 PC 输出的历史参考，必须从本次枚举中明确选择。radio WaveOut 必须由 native 枚举到唯一完整名称“扬声器 (2- USB Audio Device)”，其数字 ID 不会写入设置或传作固定 radio 输出 ID。PC WaveOut 不能选成该 radio 输出，同一个 WaveIn ID 也不能同时作为 radio 输入和 PC 麦克风。

启动前请确认官方 WIRES-X 程序已关闭、FTX-1 通过 USB 直连、屏幕停留在 WIRES-X HRI、HRI 为 ON、Node Mode 为 DIRECT；本测试不使用 CAT 端口。确认手咪 PTT 已松开后，在启动器最后提示处输入 `START`。只有此时才会运行 native；启动器直接在当前 PowerShell 控制台执行 `wirex_probe.exe ... --interactive`，不捕获它的标准输入，也不派生后台监控程序。native 接管设备和会话生命周期，并提供 F/M/C/Q 操作：F 播放固定 WAV；M 从已选择的 PC 麦克风在内存采集最多 8 秒，随后发送并回到监听；C 取消当前操作；Q 收尾退出。每次下行前都要松开手咪 PTT。会话窗口为 120 秒，结束后需重新启动本入口。

native 在 `logs` 目录写会话报告；若包目录不可写，启动器会在打开设备前报错退出。退出码和报告只描述软件流程，不能证明实际声音、射频发射或无线状态。请人工确认固定 WAV/M 语音是否从电台扬声器播放、完成后电台界面和声音是否恢复，并反馈结果。设备配置和数字 ID 每次启动时重新确认；首版不自动按上次设备名称恢复。CAT、BrandMeister 和 RF 节点保持未启用。

## 离线验证

在项目 `app` 目录运行：

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\test-start-local-radio-session.ps1
```

测试使用 fakeprobe 和模拟设备 JSON，不打开串口或音频设备，不运行本机核心，也不会触发 HRI 会话。
