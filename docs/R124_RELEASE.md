# R124 v0.1.0 便携启动入口与发布结构

## 目录合同

用户启动 `WirexBridge.exe`。发布目录根部只放 launcher、Native 构建 provenance、launcher 构建 provenance、`README.md`、`SOURCE.txt` 与 `manifest.json`；首次启动后还会出现 `config.json`。Native EXE、WPF 界面、PowerShell 入口、配置模块、用户文档、许可证材料和经固定 SHA-256 审计的 HRI 协议模板放在 `runtime/`。发布包不带用户 `config.json`、凭据、运行日志或机器私有路径。

launcher 从自身 EXE 所在目录计算所有路径，再以 `runtime/` 为 PackageDirectory、EXE 根目录为 PortableDirectory 启动 Windows PowerShell 5.1。工作目录和调用者当前目录不会影响配置或资源解析。

## 配置初始化顺序

`tools/start-ui.ps1` 在正常启动收到 `-PortableDirectory` 后，先导入 `ui/windows/PortableConfig.psm1` 并调用 `Initialize-PortableConfig`，然后才 dot-source bridge-ui。bridge-ui 通过同一个 helper 幂等验证配置。缺少配置时 helper 以临时文件加同目录原子 move 创建唯一默认 schema；已有配置只读验证，保留原始字节及未知字段。创建失败、权限失败或 JSON/schema 无效时以 terminating error 退出，不进入 Native、设备或 BrandMeister 初始化。

`--no-connect` 启动实际 UI，并传入 `NoAutoConnect`，阻止自动连接 CAT、HRI、BrandMeister 与音频。`--validate-config` 只执行上述配置初始化与验证，然后退出，不启动 UI。`--routing-diagnostic <隔离目录>` 启动完整的 WPF/Native 离线路由诊断；EXE 根目录只作为 forbidden-root 路径边界使用，不调用配置 helper、不读取或写入 EXE 根 `config.json`。direct `start-ui.ps1` 调用若未给出 `PortableDirectory`，会从 stable `runtime/` 的父目录中识别 `WirexBridge.exe`；无法识别 launcher 时至少把 `PackageDirectory` 本身作为禁止边界。

## 子进程与退出

launcher 用 Windows Job Object 托管自己启动的 PowerShell 子进程，并设置 `KILL_ON_JOB_CLOSE`。PowerShell 进程先以 `CREATE_SUSPENDED` 创建，成功加入 launcher 专属 job 后才 `ResumeThread`。正常关闭等待 WPF/Native 现有 supervisor 清理并让 PowerShell 退出；随后关闭 launcher job，清除仍属于本次启动树的遗留子进程。launcher 不按进程名或 PID 终止其他进程。

## 构建与清单

Native C++ 构建继续由现有构建流程单独证明。launcher 由本机 .NET Framework `csc.exe` 编译，使用 `/codepage:65001` 解析 UTF-8 C# 源码，输出只放在 `build/_work/`；EXE 产品名为 WIREX Bridge，文件版本和程序集版本为 `0.1.0.0`，公司字段为 `iCassius`。`launcher-build-provenance.json` 记录 C# 源文件路径和 SHA-256、源码提交、编译器版本及完整编译命令、x64 GUI 输出路径、文件长度和 SHA-256。发布 manifest 将两种构建记录分开，并逐项列出发布文件的来源路径、长度和 SHA-256。

stable profile 使用 tag `v0.1.0`；alpha.1–alpha.19 的历史资产路径和下载检查继续按旧 profile 处理。v0.1.0 的 generic 包不把用户 config 或本机状态打进资产。

## 源码阶段状态

截至 2026-11-03，源码阶段离线回归结果如下。publisher 的 161 项合成断言通过，但因源码树尚有修改而跳过仓库 Git 检查；提交后必须重跑完整 Git 检查。downloader 的 3,262 项断言通过，跳过 0 项。

| 检查 | 通过断言 |
| --- | ---: |
| PortableConfig | 63 |
| launcher 启动、诊断与生命周期 | 45 |
| stable/alpha package | 795 |
| publisher 合成校验 | 161 |
| downloader | 3,262 |
| ChannelActivationState | 345 |
| channels | 170 |
| console | 121 |
| status | 87 |
| CAT | 197 |
| WPF UI 交互 | 63 |
| RenderOnly | 1,951 |
| gain | 85 |
| R123 固定回归 | 54 |

这些检查用于源码阶段离线验证，不包含设备、BM、音频、PTT 或 RF 实测。正式 launcher 必须从真实干净源码提交重新构建；Native fresh40、generic 目录实测和 root 文件审计尚未完成。root 审核 generic 目录并标记通过前，不生成最终 ZIP；发行前还需 root 审核 ZIP、原字节 manifest 副本及 SHA256SUMS 三项资产。本阶段没有创建 tag 或发布 GitHub Release。

此前的实际 WPF 输入回归通过 63 项断言，root 接受该证据。另一次后续尝试时 Dota 2 在前台，WPF 窗口没有收到输入事件；该次没有形成有效 UI 输入结果，也不覆盖此前通过的 63 项结果。没有再次抢占前台输入。

打包工具在初次形成 stable package 时会生成 `awaiting_root_audit` 状态的中间 ZIP。root 审核 generic 目录并将 manifest 标记为 `root_audit_passed` 后，中间分发需从候选位置移出并保留到私有归档，再通过 `New-StableReleaseDistribution` 在独立路径重新生成最终 ZIP、manifest 原字节副本和 SHA256SUMS；root 对这三项最终资产复核后，才进入发布步骤。
