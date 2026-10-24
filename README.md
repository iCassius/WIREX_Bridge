# WIREX Bridge：协议、本地诊断与 BM 语音桥接候选

这是 WIREX Bridge 的 C++17 子项目，提供 DMRD 固定 55 字节数据报和 DIRECT 单记录 envelope 的解析与编码、Windows 本地诊断入口，以及 AMBE+2 声码器、DMR 通话、BrandMeister Homebrew 会话与 native 语音桥接候选。当前 `wirex_bridge.exe` 将 BM 网络音频接到 FTX-1 DIRECT 电台扬声器，并由操作者显式控制 BM DMRD 上行；上行编码前固定应用 16x 软件 PCM 增益，状态报告记录增益前后统计和削顶数。真实 BM、COM/WinMM 音频和电台联合测试尚未运行，新 BM 链路的声音结果仍待验，候选不代表实机或 RF 验收。当前源码末尾的状态报告门限和固定增益修复尚未重新执行完整构建与 24 项离线测试；当前阶段、构建产物及接续步骤见 [BM 联调推进](docs/BM联调推进.md)。

解析只接受长度恰为 55 字节且首四字节为 `DMRD` 的数据报。24-bit source/destination ID 按大端读写；超出 `0xFFFFFF` 的编码请求返回错误，不截断。flags、四个 stream ID 字节和 33 字节 payload 均按原样保留；stream ID 不转成整数，也不推断其主机序。BER 与 RSSI 是各一个原始字节。

该 codec 不验证 flags 位含义、DMR Link Control、FEC、AMBE/语音编码或消息上下文。数据报解析成功只表示长度和 magic 符合本切片格式，不表示数据内容有效或可上网、可发射。

这里的 codec 指数据包字段的解析与编码，不是语音 codec 或 vocoder。

## 构建与测试

MSVC x64 开发者命令行中可直接构建，不依赖第三方库：

```powershell
New-Item -ItemType Directory -Force build | Out-Null
cl /nologo /std:c++17 /EHsc /W4 /permissive- /I include src\dmrd.cpp tests\dmrd_test.cpp /Fe:build\dmrd_test.exe
build\dmrd_test.exe
```

DIRECT 单记录 envelope 的独立测试可在同一 x64 开发者命令行运行：

```powershell
New-Item -ItemType Directory -Force build\review-s1a | Out-Null
cl /nologo /std:c++17 /EHsc /W4 /permissive- /DNDEBUG /I include /Fo:build\review-s1a\ src\direct_frame.cpp tests\direct_frame_test.cpp /Fe:build\review-s1a\direct_frame_test.exe
build\review-s1a\direct_frame_test.exe
```

仓库也提供 `CMakeLists.txt`，用于已有 CMake 环境；本项目不安装或下载 CMake。

DMRD 测试含独立硬编码的 55-byte 黄金向量，逐字段检查解码结果并要求编码字节与向量完全一致；另覆盖 54/56-byte 长度、bad magic、24-bit 最大值与两个溢出方向、stream ID 原始字节序以及 flags/payload 透明保留。断言由显式检查函数实现，不依赖 `assert` 或 `NDEBUG`。

协议布局来源和本切片验收记录见 [S3-A 验收文档](docs/S3-A验收.md)。

DIRECT 单记录 envelope 的字段规则、来源和 S1-A 本地验收见 [S1-A 验收文档](docs/S1-A验收.md)。该 codec 原样保留 type 与 payload，不解释 X/Y 状态或其他类型的语义。

Windows 本地诊断 CLI 的参数、固定音频格式、资源清理和验证边界见 [S1-B 本地诊断入口](docs/S1-B本地诊断入口.md)。

绑定本机 COM5、WaveIn 1、WaveOut 0 的可见 HRI 监听启动器说明见[本机 HRI 诊断启动器](tools/README.md)。这是最长 120 秒的本机诊断切片，不代表双向语音验收或完整 HRI 初始化。

启动器还保留 `last-session-status.json` 元数据快照，用于区分正常收尾和控制台关闭后留下的未完成状态；该报告不保存音频、协议正文或设备身份。报告和启动器行为见上面的工具说明。

纯函数 HRI 状态层的时序、超时和边界测试见 `tests/hri_session_test.cpp`；CLI 会话输出只表示本机观察到的有限控制交换，不代表完整初始化或人耳确认。

S1-T HRI T 空 header/空 AMBE 候选正文及离线验收见 [S1-T 验收文档](docs/S1-T验收.md)。

控制台关闭时取消、主线程资源清理和有界等待的实现与验收边界见 [S1-C 关闭窗口清理](docs/S1-C关闭窗口清理.md)。

固定 T3/T0 候选和 WAV 下行流程、本机按键启动、阶段报告及离线验证边界见 [S1-D 本机下行候选验收](docs/S1-D本机下行候选验收.md) 与 [本机测试启动器说明](tools/README.md)。
供本机测试包复制到根目录的操作者说明源文件位于 [tools/downlink-test-README.md](tools/downlink-test-README.md)。
