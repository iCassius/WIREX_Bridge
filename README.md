# WIREX Bridge：FTX-1 DIRECT 与 BrandMeister 语音桥接

## 当前工作：R118 / Alpha 14 源码冻结与本机包准备

R118 已完成统一便携配置（迁移保留 TX target 为首项，本机私呼接收路由只归档不伪造 peer 频道）、BM API Key 内存接入、自定义频道监听/发射目标、CAT 重连与频道事务收尾，以及 alpha14 固定清单和启动器集成。配置/BM 模块、发布工具合成检查与 status、identity、lifecycle、radio-cat、channels 五项 WPF 回归均在 Windows PowerShell 5.1 和 PowerShell 7 通过。频道回归每种 PowerShell 各 74 项断言通过；Native 40 项 clean build 和 alpha14 本机文件夹将在本次迁移修复提交后生成。没有读取或迁移真实配置，没有启动真实 BM、COM/HRI、音频、PTT 或 RF。未创建 ZIP、tag 或 GitHub Release。当前证据见 [R118 发布交接](docs/R118_发布交接.md)，用户操作说明源见 [Alpha 14 包内说明](docs/releases/v0.1.0-alpha.14-package-README.md)。

以下为历史阶段记录；当前进度以 [R118 发布交接](docs/R118_发布交接.md) 为准。
## R111 / alpha.9 源码集成准备

当前默认用户绿色目录是 R110 验收的 `build/releases/v0.1.0-alpha.8`；alpha.9 源已冻结，clean build 和正式包尚未生成。alpha.9 包含分开的本机收听与起呼目标、真实通话记录、逐路由 TS、发射 CC 设置、单 ID RadioID 查询和本机音量显示。查询只由用户点击触发，查询缓存和频道收藏留在 canonical 配置目录；“静态”类别只整理本机收藏，程序没有读取或修改 BM 服务器订阅。音量设置与当前运行实际增益分别显示；RadioIdentity 模块已修复 Windows 网络读取 deadline 并通过根架构审查，UI 两尺寸 RenderOnly 与定向测试也已通过根审查。

RadioIdentity 的 Windows 网络读取 deadline 已改为受共享时钟约束的 `ReadAsync`；PS7 与 Windows PowerShell 5.1 最新离线测试各通过 37 项断言。根会话还做过一次只读 HTTPS 单 ID 查询，收到 HTTP 200 且 ID/呼号匹配，没有写缓存或显示个人资料。UI 两尺寸 RenderOnly 与定向测试已通过根审查，alpha.9 源码提交为 `222f71d`、`e7ec9a0` 和 `c4597e9`。clean full39、正式包与 PS5.1 包启动 helper 尚待完成；本机当前仍指向 alpha.8。

alpha.8 TG91 收听听感正常但略小；该次运行实际增益为 1.000x、clipped samples 为 0，保存的 5.959x 与那次运行记录不同。FTX-1 机身 BUSY/TX LED 观察保留，R111 不更改 LED 或串口。LCD 实际显示仍 unknown；本轮没有连接设备、音频、BM，没有触发 PTT 或 RF。

- [alpha.8 已审计交付说明](docs/releases/v0.1.0-alpha.8.md)
- [alpha.9 包内说明草案](docs/releases/v0.1.0-alpha.9-package-README.md)
- [alpha.9 交付说明与验收边界](docs/releases/v0.1.0-alpha.9.md)
- [R111 alpha.9 集成总交接](docs/R111_总交接.md)

## v0.1.0-alpha.1 私有预发布

私有 GitHub 预发布 [v0.1.0-alpha.1](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.1) 已于 2026-10-25 19:49:48（中国标准时间）发布，Release ID 为 423365682，源码 tag 指向 `312e7142a419566c47a335fb83a33c756aaf69f3`。该 tag 的 clean build 通过 27 项离线测试，warning/error 为 0；逐文件清单和实机验证范围见 Release 中的 `manifest.json` 与[发布说明](docs/releases/v0.1.0-alpha.1.md)。

本机绿色目录为 `build/releases/v0.1.0-alpha.1`，清单列出的 16 个文件，加上 manifest.json，共 17 个文件；GitHub Release 有 18 个独立 asset，另含单独发布的下载脚本。发布不使用 ZIP，包内不含密码、连接 profile、音量设置或运行日志。该版本 HIL 留待最终集中联测；`005c5e8` 的 DIRECT Echo 和 `ab3c5fa` 的 TG91 收听是前序版本的用户确认。

- [v0.1.0-alpha.1 发布说明](docs/releases/v0.1.0-alpha.1.md)
- [包内操作说明源](docs/releases/v0.1.0-alpha.1-package-README.md)
- [首个 Release 验收清单](docs/首个Release验收.md)

这是前台控制台程序；正常运行不用 `START` 或键盘 `T`，就绪后使用手咪 PTT，按 `Q` 停止并退出。拿到便携包后，首次使用自己的 BM 身份，请在包目录运行 `start-profile.cmd` 并将 BM 密码与连接 profile 分开保存。FTX-1 LCD 当前话者显示、DIRECT 运行时 RF 路由、BM 到 RF 发射和真实图形 UI 不在本 alpha 范围内。

## 协议与本地开发

这是 WIREX Bridge 的 C++17 子项目，包含 DMRD 固定 55 字节数据报和 DIRECT 单记录 envelope 的解析/编码、Windows 本地诊断入口、AMBE+2 声码器、DMR 通话和 BrandMeister Homebrew 会话。当前实现与构建边界见 [BM 联调推进](docs/BM联调推进.md)。

解析只接受长度恰为 55 字节且首四字节为 `DMRD` 的数据报。24-bit source/destination ID 按大端读写；超出 `0xFFFFFF` 的编码请求返回错误，不截断。flags、四个 stream ID 字节和 33 字节 payload 均按原样保留；stream ID 不转成整数，也不推断其主机序。BER 与 RSSI 是各一个原始字节。

该 codec 没有验证 flags 位含义、DMR Link Control、FEC、AMBE/语音编码或消息上下文。数据报解析只检查长度和 magic 是否符合本切片格式；数据内容的有效性、联网行为和发射行为仍未验证。

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

绑定本机 COM5、WaveIn 1、WaveOut 0 的可见 HRI 监听启动器说明见[本机 HRI 诊断启动器](tools/README.md)。这是最长 120 秒的本机诊断切片；该切片没有验证双向语音，也没有完成 HRI 初始化。

启动器还保留 `last-session-status.json` 元数据快照，用于区分正常收尾和控制台关闭后留下的未完成状态；该报告不保存音频、协议正文或设备身份。报告和启动器行为见上面的工具说明。

纯函数 HRI 状态层的时序、超时和边界测试见 `tests/hri_session_test.cpp`；CLI 会话输出记录本机观察到的有限控制交换，尚未验证完整初始化或人耳听音。

S1-T HRI T 空 header/空 AMBE 候选正文及离线验收见 [S1-T 验收文档](docs/S1-T验收.md)。

控制台关闭时取消、主线程资源清理和有界等待的实现与验收边界见 [S1-C 关闭窗口清理](docs/S1-C关闭窗口清理.md)。

固定 T3/T0 候选和 WAV 下行流程、本机按键启动、阶段报告及离线验证边界见 [S1-D 本机下行候选验收](docs/S1-D本机下行候选验收.md) 与 [本机测试启动器说明](tools/README.md)。
供本机测试包复制到根目录的操作者说明源文件位于 [tools/downlink-test-README.md](tools/downlink-test-README.md)。
