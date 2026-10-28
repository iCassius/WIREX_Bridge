# R110 启动故障修复与 alpha.8 准备

## 目标与边界

R110 修复 alpha.7 测试包在 Windows PowerShell 5.1 下解析合并启动入口失败的问题，并为 alpha.8 准备唯一的用户启动命令和包级回归检查。源码映射启动链已通过 Windows PowerShell 5.1；正式 clean build 与 alpha.8 包将在该源码提交后执行。全过程不连接 COM 设备、音频流或 BrandMeister。

R110 从仓库 `main` 分支提交 `cf9775f47812d2b25bc155156803ad8b2fb7ea22` 开始；该基点当时工作树干净。

## 故障复现与原因

检查对象是现存包 `build/releases/v0.1.0-alpha.7/start-merged-test.ps1`，由 `powershell.exe -NoLogo -NoProfile` 启动 Windows PowerShell `5.1.26100.8737`，再调用 `System.Management.Automation.Language.Parser.ParseFile`。该入口文件没有 BOM，文件开头是 ASCII `[`；解析器报告 5 个语法错误。首个错误位于第 18 行：原本的中文错误消息被按当前 Windows ANSI 代码页误读，随后出现 `UnexpectedToken`；第 30 行起又连带报告字符串和括号未闭合。

同一 alpha.7 包中的另外 7 个 `.ps1`/`.psm1` 文件均通过 Windows PowerShell 5.1 解析。`start-ui.ps1` 和 `ui/windows/bridge-ui.ps1` 含 UTF-8 BOM。此前只覆盖 Native 控制管道和源码入口，没有对包内真实 `start-merged-test.ps1` 调用 Windows PowerShell 5.1 解析；这是本次查出的漏测。

`tools/start-merged-test-alpha7.ps1` 的正文是 UTF-8，但缺少 BOM。修复只为该源码增加 UTF-8 BOM，原有正文逐字节保持不变。已发布的 alpha.7 包不改写；修复随 alpha.8 新包生效。

## alpha.8 启动入口

alpha.8 包根目录只放置 `start-wirex-bridge.cmd` 作为用户启动命令。该 ASCII CMD 使用同一个 `powershell.exe -STA` 进程启动 `tools/start-wirex-bridge.ps1`，由它解析包根目录并进入根目录的 `start-ui.ps1`。正常 Start 与隔离路由诊断使用相同的 `start-wirex-bridge.ps1 → start-ui.ps1 → ui/windows/bridge-ui.ps1` 调用链；诊断只多传递现有的 `-RoutingDiagnostic` 和 `-RoutingDiagnosticAutoTest` 开关。两个 PowerShell 启动器以 dot-source 方式进入下一脚本，使 WPF 事件闭包能找到 UI 脚本函数，不额外创建 PowerShell 进程。Native、用户配置模块和 UI 文件仍在原路径。

alpha.8 启动入口在包内 `private/user-config-directory.txt` 存在时读取其中唯一一行绝对路径，并将其作为本机长期配置目录；该本机指针不属于通用 manifest。没有指针的副本继续使用包内 `private/user-config`。入口拒绝空文件、多行和相对路径。

本机 canonical 配置原来通过 `app/private/user-config/bridge-directory.txt` 保存 alpha.4 的路径。比对后发现 canonical 与 alpha.7 的呼号、Gateway ID、Source ID、Master 地址和端口、色码相同；音量配置及密码路径也相同，但发送目标和接收策略不同。为保留最近 alpha.7 操作的完整收发选择，R110 已先把 canonical 的 `connection-profile.json`、`audio-settings.json`、`password-file-path.txt` 和 `bridge-directory.txt` 逐文件备份到 `app/private/config-backups/R110`，再将 alpha.7 的前三个文件复制为 canonical 文件。旧备份仍可用于回滚；密码文件内容没有读取或移动。`bridge-directory.txt` 暂未改动，待 alpha.8 包审计通过后再切换到新包。

alpha.8 profile 去掉旧的多入口 `.cmd`、`start-merged-test.ps1`、`start-step1-test.ps1`、`test-control.ps1` 及已不再向用户公开的配置入口；保留唯一 `start-wirex-bridge.cmd`、其 `tools/start-wirex-bridge.ps1` 启动器，以及 UI 运行所需的 `start-ui.ps1`、`start-bm-radio-bridge.ps1`、`bridge-user-config.psm1`、UI、Native、设备模板、说明和许可证。包级检查确认恰有一个 `.cmd`。

## 回归验收

已用 Windows PowerShell 5.1 `5.1.26100.8737` 的 `Parser.ParseFile` 检查 alpha.7 实际发布目录。真实包的 `start-merged-test.ps1` 有 5 项解析错误：第 18 行中文字符串因无 BOM 按 ANSI 代码页误读，后续出现 `UnexpectedToken`、未终止字符串和括号错误；其余 7 个脚本通过。该 alpha.7 目录保持原样。源码 `tools/start-merged-test-alpha7.ps1` 加入 UTF-8 BOM 后，正文仍与旧包文件逐字节相同，PS5.1 解析错误为 0。

`Start-UiRoutingDiagnosticAutoTest` 在 Source ID guard 通过后初始化设置窗和点击路由按钮。旧逻辑在窗口已由 `control_ready` 显示时再次调用 `ShowDialog()`，会抛出“只能在隐藏窗口上调用 ShowDialog”的异常。由于异常被 UI timer 捕获后只更新状态，后续 Native ACK 仍可能继续；旧 runner 曾因此输出 passed，掩盖初始化异常。R110 改为仅在窗口未显示时非模态调用 `Show()`，并在自动验收初始化块中捕获异常类型和脚本栈、写入隔离 `routing-diagnostic-progress.txt`，记录失败并请求正常退出。验收脚本还拒绝“结果 passed，但 progress 含 `auto-test-initialization-failed:`”的组合。

R109 的 `tools/test-ui-routing-diagnostic.ps1` 直接启动 `bridge-ui.ps1`，此前单独通过，但它没有覆盖 alpha.8 包装器增加的脚本作用域。R110 首次运行唯一 CMD 链时发现 WPF 动态按钮事件闭包无法解析 `Invoke-SettingsPolicyEditorAction`。此后让 alpha.8 的 Start 和隔离诊断都 dot-source 相同的 `start-ui.ps1`，再由该启动器 dot-source UI 脚本；同时仅给 `start-ui.ps1` 增加已有诊断开关的透传。修正后的真实 CMD 链通过同一 WPF 按钮、Supervisor 与 R109 Native 诊断流程。

最终包级检查器 `tools/test-package-startup.ps1` 会递归解析候选包全部 `.ps1`/`.psm1` 文件，要求包中恰有一个根目录 `.cmd`，再经 ASCII CMD 实际启动链执行 `PrepareOnly` 与隔离 `RoutingDiagnosticAutoTest`。源映射测试包完整复制 alpha.8 profile 文件，Native 和 provenance 来自获准的 R109 build；测试目录名包含空格和中文。Windows PowerShell 5.1 本轮确认包内 5 个脚本全部解析成功；`PrepareOnly` 输出指向本次 Unicode/空格路径包；无配置目录负例准确返回退出码 2 且不创建目录；隔离诊断的 WPF 按钮、路由策略、动态组激活和内存 sink 结果通过，BM 保持未启动。固定 fake-sleep 子进程超时测试也通过，脚本确认进程退出且没有进程继续引用临时路径。所有测试临时目录均已清理。

source-mapped 检查完整复制 alpha.8 profile 文件；Native 和 provenance 来自获准的 R109 build，Native SHA-256 为 `e3b9eeee7111414a29f65817b23b5be70516af59ea3a3ee5e4af587f40cafca7`。这是启动调用链的私有验证，不是官方完整构建或发行包；没有连接 COM、音频、BM，没有发射或 RF 验证。正式 full build 和 package 按后续交付步骤执行。

另以 Windows PowerShell 5.1 重跑 source-mapped 唯一 CMD 链，结果 exit 0。无参数失败负例通过真实 CMD 触发无效配置指针，确认显示 ASCII 错误提示并保留退出码 2；静态检查确认 `pause >nul` 只位于无参数且启动失败的分支。自动化用例通过重定向 stdin 驱动 CMD，因此没有模拟用户按键或验证人工关闭控制台。fake-sleep 负例确认超时后测试子进程已退出且没有继续引用临时路径；检查结束时没有 R110 启动测试进程残留。最新索引 `app/private/build-history/R110/source-mapped-startup-test-20261028-185632-545.json` 对应输出 SHA-256 `dff379f1d2dae49c4933110bfe92d853b5bea568dd0131522c14acc431277e3c`，测试包为 `app/build/_work/r110-source-mapped-alpha8-edc6fddb5581459da253acd5a319954f`。该包仍是 source-mapped 私有测试件，不是 alpha.8 正式包。

静态 HRI/EXE 研究没有修复或解释 FTX-1 机身 BUSY/TX LED 的实际行为。官方程序对设备的真实调用与 LED 变化仍待受控运行观察；R110 未进行 COM、音频、BM、PTT、LED 或 RF 硬件验收。

## build 目录盘点与后续清理

本轮只读取目录元数据，没有清除旧版或移动 build 内容。盘点时 `app/build/_work` 有 20,390 个文件、2,872,802,926 字节；`releases` 有 246 个文件、10,365,520 字节；`candidates` 有 37 个文件、2,657,213 字节；`_archive` 有 25 个文件、1,529,053 字节。另有旧 BM build 和 local test 目录。`_work/uv-cache` 为 5,844 个文件、696,573,805 字节，`_work/ui-venv` 为 5,781 个文件、691,480,216 字节；路径在 `app/build` 内、两个目录及其内容没有 reparse point，进程命令行/可执行路径检查均未发现占用者。按原获准动作发出的递归删除请求被本地执行策略拒绝，未有文件被删除，也没有换其他工具重试。

R110 已将 229 个文件、2,748,196 字节的轻量来源证据复制到 `app/private/build-history/R110/build`，保留相对路径并在 `archive-index.json` 中记录 SHA-256。归档不包含 EXE、对象文件、虚拟环境、音频样本或密码文件内容；`bm-device-password.txt` 没有读取、复制或写入报告。批准的 Y fixture 和合成语音样本位于 `app/private/fixtures`，密码文件仍留在其原位置。

待审批清单 `app/private/build-history/R110/retire-plan.json` 列出 301 个精确源目录/文件与 `app/private/build-retired/R110/build/<原 build 相对路径>` 目标，共 20,654 个文件、2,861,010,889 字节。清单保留当前 R109 full build `build/_work/wirex-bridge-201959e-20261028-073504` 和日志 `build/_work/alpha7-r109-full39-201959e-20261028-153450.log`；未来正式 alpha.8 包、full build 和日志尚不存在，生成后必须先添加为保留路径。计划生成时各源树 reparse point 为 0、目标冲突为 0、没有进程引用源路径；`private/build-retired/R110` 尚未创建。当前 canonical 密码路径指针只读核验为 build 外目标，目标文件内容没有读取。此 JSON 状态为 `proposed_not_authorized`，只用于根会话审核；alpha.8 官方包验收及本机指针切换完成、根会话逐路径批准前不移动或删除 build 内容。
