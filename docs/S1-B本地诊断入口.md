# S1-B：Windows 本地诊断入口

`wirex_probe.exe` 是一个便携式 Windows 命令行诊断切片。它不安装服务或登录启动项，不创建后台进程；`--hri-listen` 最长 120 秒，其他音频操作最长 30 秒，并只打开调用者明确指定的端口或音频设备 ID。Windows 构建使用静态 MSVC 运行库 `/MT`。这不是完整的 HRI 会话或语音桥接程序。

```text
wirex_probe.exe --help
wirex_probe.exe --version --port COM5
wirex_probe.exe --hri-listen --port COM5 --body-file C:\path\to\approved-y-body.bin --input 1 --output 0 --seconds 120 --gain 8
wirex_probe.exe --list-audio
wirex_probe.exe --monitor --input 1 --seconds 5
wirex_probe.exe --audio-loop --input 1 --output 2 --seconds 5
wirex_probe.exe --audio-loop --input 1 --output 2 --seconds 5 --gain 8
wirex_probe.exe --play-wav --file .\speech.wav --output 2
```

在已有的 MSVC x64 开发者命令行中可直接生成静态运行库版本，不需要安装第三方库：

```powershell
New-Item -ItemType Directory -Force build | Out-Null
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include `
  src\direct_frame.cpp src\direct_stream.cpp src\hri_session.cpp src\wave_file.cpp src\pcm_gain.cpp src\probe_main.cpp winmm.lib bcrypt.lib `
  /Fe:build\wirex_probe.exe
```

`--version` 只打开指定串口并发送一条已验证格式的 DIRECT `V0000` 查询，等待应答最多 2500 ms。串口参数是 115200、8N1、无握手、DTR/RTS 关闭；程序只显示经过检查的型号和版本字段，不显示 Radio ID。成功文字明确写“版本查询成功，完整 HRI 初始化尚未确认”。它不发送 Y、PTT 或其他设置帧。该命令本轮只完成编译，没有在本机执行。

`--list-audio` 只枚举 WinMM 的 WaveIn/WaveOut 设备编号和名称，不选择默认设备。`--monitor` 只打开指定 WaveIn 编号，要求设备接受 48 kHz、单声道、有符号 16-bit PCM；不支持时拒绝打开。它每秒输出采样数、RMS dBFS 和峰值，不保存或播放 PCM。

`--audio-loop` 同时对命令行给出的 WaveIn 与 WaveOut 编号分别执行 `WAVE_FORMAT_QUERY`，仅接受 48 kHz、单声道、有符号 16-bit PCM；任一端不接受该格式，程序就拒绝开始。它把输入缓冲复制到固定的四个 100 ms 输出缓冲中，不写文件，也不自动选择设备。可选的 `--gain X` 是 PCM 样本的软件增益，默认 `1.0`（原样转发），范围为 `0.25` 到 `16.0`，最多三位小数；它不调用系统混音器或改设备音量，也不做自动增益。增益处理采用有符号 16-bit 饱和裁剪，并统计被裁剪的样本数。结束摘要分别报告采集输入、实际提交前的输入和提交后的输出 RMS/峰值（dBFS），便于判断源电平偏低或增益造成过载。输出队列满时丢弃新输入块并报告丢弃数；输入摘要包含采集到的块，提交摘要仅包含成功排入 WaveOut 的块。输入采集和输出播放最多持续 30 秒；它不自动发 PTT。

`--play-wav` 只读入调用者给定的 RIFF/WAVE 文件，并只打开显式选择的 WaveOut 编号。解析器要求 RIFF 长度与整个文件完全相等，且只有一个 `fmt ` 和一个 `data` chunk；格式必须是 48 kHz、单声道、有符号 16-bit PCM，`block align` 为 2，数据长度按完整采样对齐。它按 chunk 长度和 RIFF 奇数长度 padding 跳过未知 chunk。音频数据最多 30 秒；整个文件最多为 30 秒 PCM 数据加 64 KiB 元数据。程序不重采样。

播放器用该 WaveOut 编号执行 `WAVE_FORMAT_QUERY`；设备不接受文件格式时拒绝播放。PCM `fmt ` chunk 只接受 16 字节格式块，或 `cbSize=0` 的 18 字节块。程序把最多 30 秒文件读入有上限的内存，然后按四个固定输出缓冲排队。

播放使用固定四个 100 ms 输出缓冲。队列满时等待 WaveOut 完成事件后再提交下一块，不丢 WAV 文件数据；播放与排空共用 35 秒整体截止时间。只有所有数据块都已提交并排空、WaveOut 清理调用成功后才报告播放完成。Ctrl+C/Ctrl+Break 取消后重置已排队输出并退出，不发送 PTT。

一次 `--audio-loop` 只沿指定的“输入设备 → 输出设备”方向路由。若要分别检查电台到电脑和电脑到电台，需要依据 `--list-audio` 的结果为每个方向选择相应端点并各自运行；设备名称本身不能证明某个端点实际连接到 FTX-1。R46 操作者确认电脑可辨认手咪语句但主要是声音较小；未确认失真；本次新增增益代码没有在硬件上运行，不能据此判断失真来自电台输入、PC音量、设备路由或软件增益。`--audio-loop` 尚未完成双向语音验收。

## S1-H：单进程 HRI 监听原型

`--hri-listen` 把已有纯 DIRECT frame/stream、HRI 会话状态层和 WinMM 实时 PCM 路由接在同一个进程中。它要求 `--body-file` 是绝对路径，文件必须恰好100字节、偏移5为ASCII `2`，并与代码内固定SHA-256一致；正文不会写入仓库、日志或控制台。串口采用115200 8N1、无握手、DTR/RTS关闭，读清最多250 ms、最多4096字节并要求20 ms安静，然后只发一次V0000。V响应须完整、SUM正确且48字节payload以`FTX-1`开头；版本应答等待2500 ms。通过后按约1000 ms节拍发送外部Y/100模板；首个Y/0等待最多3000 ms。仅在有效Y/0收到后，程序才打开用户指定的WaveIn与WaveOut设备并开始48000 Hz、单声道、有符号16-bit PCM路由。两个端点成功打开且会话期限仍有效后，标准输出立即刷新“音频路由已打开，进入本次 HRI 监听窗口。”提示；此提示不确认电台配置已同步。

程序在同一主循环每20 ms轮询串口并推进状态，WinMM使用`CALLBACK_EVENT`，不在音频回调中等待串口，也不创建额外线程、子进程或常驻服务。HRI窗口最多120秒；累计接收最多256 KiB、发送最多32 KiB、有效记录最多1024条、Y发送最多120次、X/0应答最多256次，单帧上限仍为4096字节。`X/100`正文偏移`0x0b`为ASCII`1`时，DLL会进入配置导入分支并调用多组DGKEY设置；当前CLI没有实现这些配置校验/导入，只在摘要计为`unsupported_config_import`，不报告配置同步成功。该分支成功时，官方DLL还会把`X.body[0x0c]`写入内部状态；此原型不拥有DLL状态对象，因而不会据此改写本地Y模板。只有正文偏移`0x0b`不为`1`的X/100，原型才按窄证据规则把偏移`0x0c`复制到本地下一Y模板。详见 [R47](../../research/planning/R47_Y状态字节与手咪PTT.md) 和 [R49](../../research/planning/R49_HRI空闲状态指针关联观察准备.md)。超时、串口错误、坏帧或音频错误都会停止路由并关闭本进程打开的资源；程序单独检查串口`CloseHandle`结果，并在清理失败时返回错误。它不会猜测发送退出帧，也不会额外调用PTT/CAT软件命令；记录字段的RF作用尚未测量。

结束摘要分别报告已验证V/48、观察到的Y/0、X/100接收数、`unsupported_config_import`数、X/0写完成数、本地模板复制条件与变化计数和音频RMS/峰值/裁剪数。显示“有效Y/0已观察”只表示本进程观察到该记录；它不证明完整HRI初始化、配置同步、语音codec、RF链路或人耳可听。外部Y正文和实际串口帧正文均不打印。本地准备阶段没有运行此命令或打开设备。

正常超时以及 Ctrl+C/Ctrl+Break 请求停止时，程序尝试重置、解除准备并关闭自己打开的 WinMM 缓冲和句柄。控制台关闭或进程被强制终止时，不能据此保证应用清理代码已经完成；进程结束后 Windows 会回收进程句柄。这里没有 PTT 状态需要释放。音频设备驱动的行为仍需由主会话受控验证。

## 本轮验证

- MSVC x64 使用 `/std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT` 编译 `wirex_probe.exe`，退出码 0，无编译警告。
- `--help` 和只读 `--list-audio` 执行成功；未执行 `--version`、`--monitor`、`--audio-loop` 或 `--play-wav`，未打开串口或音频流。
- WAV 播放器仅通过固定 RIFF 字节向量及离线边界测试验证；没有在本轮播放音频。DIRECT stream、DIRECT frame 和 DMRD 纯函数测试以独立离线命令构建运行。CMake 配置未运行：本机没有可用的 `cmake` 命令。

PCM 增益纯函数使用固定数值测试检查单位增益、衰减舍入、放大饱和裁剪、范围拒绝和 dBFS 统计。本次没有打开音频设备验证增益后的听感或硬件音量变化。

WAV 解析器的纯函数测试可单独重建：

```powershell
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include `
  src\wave_file.cpp tests\wave_file_test.cpp /Fe:build\wave_file_test.exe
build\wave_file_test.exe
```

PCM 增益纯函数可单独离线构建测试：

```powershell
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT /I include `
  src\pcm_gain.cpp tests\pcm_gain_test.cpp /Fe:build\pcm_gain_test.exe
build\pcm_gain_test.exe
```

## 本次软件增益增量验证

本次增益切片从 app 源码 HEAD `dee4b59` 开始，只修改 CLI 的音频路由、PCM 增益纯函数和相关文档/测试；没有改 UI，当前 app native HEAD 为 `2275290`。使用 MSVC x64 `/std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT` 独立编译 `pcm_gain_test`、既有四组 codec/parser 测试和 `wirex_probe.exe`，均退出码 0、无编译警告；dumpbin /dependents 显示 CLI 仅依赖 WINMM.dll 与 KERNEL32.dll。增益测试检查默认单位增益、衰减舍入、放大饱和及裁剪数、增益参数格式/范围和 RMS/峰值计算；全部通过。`wirex_probe.exe --help` 正常显示新参数；越界 `--gain 16.001` 在打开音频端点前以退出码 2 拒绝。

本次没有运行 `--audio-loop`、`--monitor` 或 `--play-wav`，没有打开音频设备。R46 操作者确认电脑能辨认手咪语句但主要是声音较小；未确认失真；新增软件增益尚未通过硬件试听，不能据此声称已修复音质。下一次受控路由可从 `--gain 8` 开始，并依据提交前/后 RMS、峰值和饱和样本数判断是否继续；实际端点选择与试听由主会话控制。

## S1-H 本地构建与离线验证

本地使用 MSVC x64 `/std:c++17 /EHsc /W4 /permissive- /utf-8 /DNDEBUG /MT` 编译 `hri_session_test.exe` 和包含 `--hri-listen` 的 `wirex_probe.exe`，均退出码0且无编译警告。纯状态测试覆盖固定V0000字节、V/48型号校验、写完成后2500 ms版本应答期限、1000 ms Y节拍、Y/0门控、3000 ms迟到Y/0拒绝、X/0应答、偏移12条件复制计数、同一读批坏帧丢弃动作、取消与期限停止。测试全部通过。

`wirex_probe.exe --help` 退出码0并显示新用法。用相对路径调用`--hri-listen`时，程序在音频设备查询和串口打开前以退出码2拒绝；本轮没有提供外部正文、打开串口或音频流、发送协议帧或执行硬件测试。CMake配置未运行。代码要求外部100字节正文与固定摘要匹配，但不把正文放入项目。
