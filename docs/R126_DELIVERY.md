# R126 便携交付方案

## 决定

R126 保留当前 WPF 应用实际调用的 PowerShell 脚本和模块，不在本轮重写 UI 宿主。新的 `v0.1.1-test.2` 与后续 `v0.1.1` 使用独立 ZIP-only 发布配置；现有 `v0.1.0` 包和 GitHub Release 不修改。

用户 ZIP 解压后，根目录只含 `WirexBridge.exe`。程序首次启动时在同一目录生成 `config.json`。其余运行文件统一位于 `runtime/`，用户下载页只发布一个 ZIP。README 与 Release 正文仅介绍 WIRES-X 三种连接方式和启动步骤；构建、清单、哈希、测试日志等交付审计保存在仓库私有目录，不随 ZIP 分发。

## 当前运行依赖

启动调用链可以从 [launcher](../ui/launcher/WirexBridgeLauncher.cs)、[入口脚本](../tools/start-ui.ps1)、[WPF 主脚本](../ui/windows/bridge-ui.ps1) 和 [Native 启动脚本](../tools/start-bm-radio-bridge.ps1) 复核：

1. `WirexBridge.exe` 从自身位置定位根目录和 `runtime/`。它检查 Native EXE、WPF 主脚本、入口脚本和统一配置模块都存在，再启动 Windows PowerShell 5.1 的 STA 会话。
2. `runtime/start-ui.ps1` 导入 `PortableConfig.psm1`，随后载入 `ui/windows/bridge-ui.ps1`。该 WPF 脚本读取两个 XAML 窗口、动态编译 `BridgeSupervisor.cs`、加载 CAT/BM/设备/身份/频道模块，并点载 CAT 与 BM 界面脚本。
3. 界面通过 `runtime/start-bm-radio-bridge.ps1` 组织 Native 启动参数；该脚本调用 `runtime/wirex_bridge.exe`，并读取固定的 `runtime/private/device-y.bin` HRI 模板。
4. launcher 把 PowerShell 子进程放入专属 Job Object。退出窗口会先进入现有停止和清理流程；launcher 结束时关闭 Job，清理仍属于该次启动的进程后代。

当前完整功能包需要以下文件：

```text
WirexBridge.exe
runtime/bridge-user-config.psm1
runtime/start-bm-radio-bridge.ps1
runtime/start-ui.ps1
runtime/wirex_bridge.exe
runtime/private/device-y.bin
runtime/licenses/dmr_signal/COPYING.GPL-3.0.txt
runtime/licenses/dmr_signal/NOTICE.md
runtime/licenses/droidstar_mbe/COPYING.GPL-3.0.txt
runtime/licenses/droidstar_mbe/ISC-NOTICE.txt
runtime/ui/windows/BmManagement.psm1
runtime/ui/windows/BmManagementUi.ps1
runtime/ui/windows/BmServers.psm1
runtime/ui/windows/bridge-ui.ps1
runtime/ui/windows/BridgeSupervisor.cs
runtime/ui/windows/ChannelActivationState.psm1
runtime/ui/windows/MainWindow.xaml
runtime/ui/windows/PortableConfig.psm1
runtime/ui/windows/UiLocalization.psm1
runtime/ui/windows/RadioCat.psm1
runtime/ui/windows/RadioCatUi.ps1
runtime/ui/windows/RadioDevices.psm1
runtime/ui/windows/RadioIdentity.psm1
runtime/ui/windows/SettingsWindow.xaml
```

当前 launcher 通过 `-STA -WindowStyle Hidden -File runtime/start-ui.ps1` 承载图形界面，并给子进程传入 `-ExecutionPolicy Bypass`。这项参数只作用于该 PowerShell 子进程，但它确实覆盖了该进程的默认脚本执行策略。R126 不新增持久的系统策略修改、脚本混淆或下载执行逻辑，也不把该参数描述为杀毒软件解决方案。若后续移除它，需要单独验证从网络下载并解压的未签名脚本在目标 Windows 策略下能否启动；本轮没有改变这一现有启动行为。

## PowerShell 宿主选项

| 方案 | 对 R126 的影响 | 结论 |
| --- | --- | --- |
| 将所需 `.ps1`、`.psm1` 保留在 `runtime/` | 沿用当前 STA WPF、模块载入和 Native 生命周期。只需改变打包白名单，运行时仍需要 Windows PowerShell 5.1。 | R126 采用。 |
| 将脚本嵌入程序集并在 STA 线程创建 in-process Runspace | 可以不启动单独的 `powershell.exe`，但程序仍运行 PowerShell。当前脚本依赖 `$PSScriptRoot`、文件路径、模块导入、点载脚本、独立 runspace 和有界关闭；宿主须为嵌入资源提供模块作用域和资源解析，并重新验证 WPF Dispatcher 与关闭清理。 | 需要单独设计宿主并做完整回归，不作为打包层面的删除方式。 |
| 把控制台和模块逻辑改写为 C# / .NET | 能真正取消 PowerShell 运行依赖，但要重写大型 WPF 界面及 CAT、设备发现、配置、BM 管理和后台工作流。 | 属于后续重构，不纳入 R126。 |

因此，保留运行所需的脚本文件并放到二级目录，是当前能维持完整功能的最小包；移除它们会让 launcher 找不到主脚本、配置模块、Native 启动器或界面模块。

## 图标

`assets/wiresx-official.ico` 是从 `C:/Program Files (x86)/YAESUMUSEN/WIRES-X/Wires-X.exe` 读取的 PE 图标资源；提取过程没有启动官方程序或访问 COM。launcher 编译时把该文件嵌入为 Windows EXE 图标及名为 `WIREX.ico` 的程序集资源。WPF 窗口从根目录的 `WirexBridge.exe` 读取 `WIREX.ico`；ZIP 不另放 ICO 文件。README 简单标注素材来源。

## 新版包和审计位置

新配置的预期文件布局如下。打包白名单只包含代码块内所列的 24 个运行文件；首次启动产生的 `config.json` 不加入通用 ZIP。

```text
WIREX_Bridge_v0.1.1-test.2.zip
├─ WirexBridge.exe
└─ runtime/
   ├─ bridge-user-config.psm1
   ├─ start-bm-radio-bridge.ps1
   ├─ start-ui.ps1
   ├─ wirex_bridge.exe
   ├─ private/device-y.bin
   ├─ licenses/...
   └─ ui/windows/...
```

`runtime/docs/`、根目录 `README.md`、`SOURCE.txt`、Native 与 launcher provenance、`manifest.json`、`SHA256SUMS.txt` 以及 `runtime/licenses/droidstar_mbe/source-manifest.json` 不进入 ZIP。GPL 的 `COPYING`、DMR `NOTICE` 和 ISC `NOTICE` 继续放在 `runtime/licenses/`。逐文件来源、长度、SHA-256、ZIP 检查结果和构建记录放在 `private/release-audits/R126/<tag>/`，由新 pack/publish/download 检查读取；GitHub Release 只上传与 tag 对应的 ZIP。

新 profile 支持 `v0.1.1-test.2`（预发布）和 `v0.1.1`（正式发布）。先制作并审查 `v0.1.1-test.2`；Root 完成候选包审计后，可决定正式 `v0.1.1` 的打包与发布。两版工具都保留 `v0.1.0` 历史配置，不覆盖旧 Release。Native 构建使用同一仓库的独立 worktree；私有审计保存 Native 构建提交及最终 UI 源码提交，并逐项确认 Native 源码和构建脚本在两提交间未变化。

## 集成验收

源码冻结后按新 profile 重新构建 launcher；Native 用已验证的 9170bad 独立 clean full40 构建证据，并校验 Native 源文件、测试、依赖目录和构建脚本相对最终提交没有变化。launcher fresh compile 后运行 Windows PowerShell 5.1 的 45 项生命周期检查。打包器要从自身输出的实际目录核对文件与目录白名单、许可证文件和 HRI 模板，并确认 ZIP 只有一个根文件 `WirexBridge.exe`，ZIP 没有实际 `config.json`、README、SOURCE、provenance、manifest、checksum 或旧运行文档。

对由该 ZIP 解压出的隔离副本，执行一次正常配置初始化和 `--validate-config`，只检查退出状态以及配置文件是否在 launcher 同目录出现，不读取或输出配置字段或哈希。接着在独立临时目录执行离线路由诊断，并从窗口关闭到 launcher 退出检查本次创建的进程后代都已结束。以上步骤不连接真实电台、COM、BrandMeister、音频、PTT 或 RF。
