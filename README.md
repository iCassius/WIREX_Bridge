# WIREX Bridge：协议与本地诊断切片

这是后续 WIREX Bridge 的独立 C++17 子项目。本地切片提供 DMRD 固定 55 字节数据报和 DIRECT 单记录 envelope 的纯函数解析与编码，也提供 Windows 本地诊断入口，可查询一次 DIRECT 版本、枚举音频设备、测量输入电平、把指定 PCM 输入短时路由到指定 PCM 输出（可显式指定有限软件增益并检查饱和裁剪），播放受限格式的短 WAV 文件，或运行有界的单进程 HRI 监听原型。它还没有完整 HRI 初始化、语音编解码、网络/BM 或 RF 桥接。

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

纯函数 HRI 状态层的时序、超时和边界测试见 `tests/hri_session_test.cpp`；CLI 会话输出只表示本机观察到的有限控制交换，不代表完整初始化或人耳确认。
