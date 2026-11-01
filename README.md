# WIREX Bridge：FTX-1 DIRECT 与 BrandMeister 语音桥接

## 当前工作：R120 / Alpha 16 源码冻结与构建准备

R120 更新监听频道面板为每页固定 3×2 个卡片，增加紧凑分页；来话卡显示呼号和 DMR ID；BrandMeister 状态与延迟紧跟应用标题。CAT 串口控制与 Wires-X 核心分离，普通核心停止保留 CAT 会话，关闭应用时才收尾 CAT。连接配置和 CAT 设置仍写入用户自己的发行目录 `config.json`，包括用户要求持久保存的 BM API Key；Generic 发布 profile 不包含个人 `config.json`。

BrandMeister 静态组沿既有包路径读取 talkgroup 列表，并按设备状态选择添加 slot；删除时保留服务器返回的 slot。UI 在启动准备前和最终 HRI `--port` 确定后检查 CAT 端口冲突，相同 COM 会取消 Wires-X 启动并保留 CAT worker。离线 UI、CAT、BM 证据和发布边界见 [R120 发布交接](docs/R120_发布交接.md)、[UI 记录](docs/R120_UI.md)、[CAT 记录](docs/R120_CAT.md) 和 [BM 接口研究](docs/R120_BM接口研究.md)。Alpha 16 发布 profile 保留 Alpha 15 的 Generic 文件路径及 40 项 Native 测试顺序，只替换包内 README 与版本化启动器，不增加运行时资产。

当前离线用例通过：RenderOnly 139 项、channels 111 项、BM WPF 66 项、BM 模块 75 项、音量 81 项、便携配置 55 项；status 与 identity 通过。CAT WPF fake worker 专项 139 项、console 130 项在 PowerShell 7.6.5 与 Windows PowerShell 5.1 均通过。root 独立复核 channels、status、identity、音量、生命周期和 3×2 两尺寸截图；独立 review 未发现 P1/P2，源码已获准冻结。Alpha 16 包尚未构建，尚未运行正常启动，也未连接真实 BM、COM、HRI、音频、PTT 或 RF。本阶段没有读取、哈希、复制或写入 alpha15 个人配置；通用包不含个人 `config.json`。没有创建 ZIP、tag 或 GitHub Release。

## R119 / Alpha 15 本机目录（root 审计通过）

R119 接入 CAT 首次状态查询和周期同步，查询忙碌时保持编辑控件与滑块稳定；CAT 写操作仍要求当前连接代次和新鲜查询结果。实时音量只在 Native 明确公布 `audio.gains.set` 时提供运行中调整，alpha14 的旧能力集继续保留原启动增益行为。CAT 与 WPF 回归、旧能力兼容和离线 IPC 检查见 [R119 发布交接](docs/R119_发布交接.md)、[CAT 记录](docs/R119_CAT.md)、[UI 记录](docs/R119_UI.md) 和 [实时音量记录](docs/R119_实时音量.md)。

alpha15 源码提交为 `a9b2d6ad0d96b7dadd995d28e8b42bbd9ff9f080`。完整 Native build 在干净提交上通过 40/40 项，`compile_only=false`，MSVC warning/error 均为 0。绿色目录 `build/releases/v0.1.0-alpha.15` 有 41 项清单资产、37 项源码映射和 42 个通用文件（含 manifest）；root 独立审计通过，manifest 状态为 `root_audit_passed`。详细构建、包和测试哈希见 [alpha15 本机候选记录](docs/releases/v0.1.0-alpha.15.md) 与 [R119 发布交接](docs/R119_发布交接.md)。个人 `config.json` 作为本机覆盖文件存在于包目录，但不在 Generic 清单或 Git 中。本轮没有改 alpha14 配置或 legacy canonical；只在本机根目录启动器备份后切换到了 alpha15。没有制作 ZIP/tag/GitHub Release；没有操作真实 COM、BrandMeister、HRI、音频、PTT 或 RF。

R119 收尾时，旧 alpha14 和临时构建已可恢复归档至 `private/build-retired/R119/`。root 核对 6 个源根共281个文件、50,305,486字节：所有文件长度一致，280个非敏感文件的 SHA-256 一致；个人配置与 alpha15 副本逐字节相同，原源路径均已移走。移动计划与日志见 [R119 发布交接](docs/R119_发布交接.md)。7个包级验证日志已移至 `private/build-history/R119/verification-logs/`，逐项长度与哈希记录在私有移动清单中；`build/_work/` 仅保留 alpha15 最终 Native 构建目录与 clean-build 日志。alpha15 的 HIL 仍待用户后续验收。

## R118 / Alpha 14 历史记录（root 审核通过）

R118 源码最终提交为 f0105d7da667c2dbc1ca24d78f2b3b11e9be9eb6，已从干净工作树完成 Native 完整构建：40/40 项通过，日志没有 MSVC warning/error；provenance 标记 compile_only=false。Alpha14 本机目录位于 build/releases/v0.1.0-alpha.14，root 已独立核对包清单、构建来源、测试结果和 EXE，manifest.package_status 为 root_audit_passed。清单列出 41 项通用资产，连同 manifest 共 42 个文件；本机另有一份不纳入通用清单的 config.json。最终 manifest SHA-256 为 09a8448cd96c2f9a1c949b621d85d0add996d36756f25cfb6f596ad3747467b0。

旧构建已归档至可恢复目录 `private/build-retired/R118/`，独立校验了503个文件共88,485,916字节；`build/_work/` 仅保留本次 f0105d7 完整构建和日志，`build/releases/` 仅保留 alpha14。归档清单、计划和逐文件移动记录见 [R118 发布交接](docs/R118_发布交接.md)。

便携配置 55 项、BM 管理 45 项，以及 package/publish/download 579/124/2,137 项合成检查均在 PowerShell 5.1/7 通过。status、identity、lifecycle、radio-cat、channels 五项 WPF 回归在两版 PowerShell STA 均通过。详细哈希和命令见 [R118 发布交接](docs/R118_发布交接.md)，用户操作见 [Alpha 14 包内说明](docs/releases/v0.1.0-alpha.14-package-README.md)。

本机 alpha14 配置已从明确指定的旧配置目录迁移；频道依次为 private:460997:2、group:46001:2、group:91:2，TX 目标仍为 private:460997:2。添加 TG91 只保存收听偏好，没有发起 QuickCall。本机启动快捷方式现调用 alpha14 目录中的唯一 CMD，原文件备份在 private/config-backups/R118。canonical 指针和旧设置文件保持原样；没有读取收藏，没有连接真实 BM/COM/HRI/音频/PTT/RF，也没有创建 ZIP、tag 或 GitHub Release。

alpha14 当时的验收细节以 [R118 发布交接](docs/R118_发布交接.md) 为准；以下为更早阶段记录。
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
