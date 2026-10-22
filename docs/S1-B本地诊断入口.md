# S1-B：Windows 本地诊断入口

`wirex_probe.exe` 是一个便携式 Windows 命令行诊断切片。它不安装服务或登录启动项，不创建后台进程；音频操作有 1–30 秒上限，并只打开调用者明确指定的端口或音频设备 ID。Windows 构建使用静态 MSVC 运行库 `/MT`。这不是完整的 HRI 会话或语音桥接程序。

```text
wirex_probe.exe --help
wirex_probe.exe --version --port COM5
wirex_probe.exe --list-audio
wirex_probe.exe --monitor --input 1 --seconds 5
wirex_probe.exe --audio-loop --input 1 --output 2 --seconds 5
```

在已有的 MSVC x64 开发者命令行中可直接生成静态运行库版本，不需要安装第三方库：

```powershell
New-Item -ItemType Directory -Force build | Out-Null
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include `
  src\direct_frame.cpp src\direct_stream.cpp src\probe_main.cpp winmm.lib `
  /Fe:build\wirex_probe.exe
```

`--version` 只打开指定串口并发送一条已验证格式的 DIRECT `V0000` 查询，等待应答最多 2500 ms。串口参数是 115200、8N1、无握手、DTR/RTS 关闭；程序只显示经过检查的型号和版本字段，不显示 Radio ID。成功文字明确写“版本查询成功，完整 HRI 初始化尚未确认”。它不发送 Y、PTT 或其他设置帧。该命令本轮只完成编译，没有在本机执行。

`--list-audio` 只枚举 WinMM 的 WaveIn/WaveOut 设备编号和名称，不选择默认设备。`--monitor` 只打开指定 WaveIn 编号，要求设备接受 48 kHz、单声道、有符号 16-bit PCM；不支持时拒绝打开。它每秒输出采样数、RMS dBFS 和峰值，不保存或播放 PCM。

`--audio-loop` 同时对命令行给出的 WaveIn 与 WaveOut 编号分别执行 `WAVE_FORMAT_QUERY`，仅接受 48 kHz、单声道、有符号 16-bit PCM；任一端不接受该格式，程序就拒绝开始。它把输入缓冲中的 PCM 复制到固定的四个 100 ms 输出缓冲中，不写文件，也不自动选择设备。输出队列满时丢弃新输入块并在结束时报告丢弃块数。输入采集和输出播放最多持续 30 秒；它不自动发 PTT。

一次 `--audio-loop` 只沿指定的“输入设备 → 输出设备”方向路由。若要分别检查电台到电脑和电脑到电台，需要依据 `--list-audio` 的结果为每个方向选择相应端点并各自运行；设备名称本身不能证明某个端点实际连接到 FTX-1。该命令没有在本轮运行，尚无电台音路或双向语音实测结论。

正常超时以及 Ctrl+C/Ctrl+Break 请求停止时，程序尝试重置、解除准备并关闭自己打开的 WinMM 缓冲和句柄。控制台关闭或进程被强制终止时，不能据此保证应用清理代码已经完成；进程结束后 Windows 会回收进程句柄。这里没有 PTT 状态需要释放。音频设备驱动的行为仍需由主会话受控验证。

## 本轮验证

- MSVC x64 使用 `/std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT` 编译 `wirex_probe.exe`，退出码 0，无编译警告。
- `--help` 和只读 `--list-audio` 执行成功；未执行 `--version`、`--monitor` 或 `--audio-loop`，未打开串口或音频流。
- DIRECT stream、DIRECT frame 和 DMRD 纯函数测试以独立离线命令构建运行。CMake 配置未运行：本机没有可用的 `cmake` 命令。
