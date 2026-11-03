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

截至 2026-11-03，R124 源码阶段离线回归结果如下。publisher 的 161 项合成断言是在源码树有修改时运行，跳过了仓库 Git 检查；这条结果只记录合成校验，不作为 clean-commit Git 检查结果。downloader 的初始 3,262 项断言通过，跳过 0 项；发布后修复稳定下载时 ZIP/checksum 临时文件落在解压库存根目录的问题，加入实际 `Invoke-StableArchiveDownload` fake-HTTP 集成路径后，完整离线回归为 3,264 项，跳过 0 项。

| 检查 | 通过断言 |
| --- | ---: |
| PortableConfig | 63 |
| launcher 启动、诊断与生命周期 | 45 |
| stable/alpha package | 795 |
| publisher 合成校验 | 161 |
| downloader | 3,264 |
| ChannelActivationState | 345 |
| channels | 171 |
| console | 121 |
| status | 87 |
| CAT | 197 |
| WPF UI 交互 | 63 |
| RenderOnly | 1,951 |
| gain | 85 |
| R123 固定回归 | 54 |

这些检查用于源码阶段离线验证，不包含设备、BM、音频、PTT 或 RF 实测。routing diagnostic 的主窗口 Loaded 分支现在会在 `NoAutoConnect` 通用早退前直接启动隔离 `Start-BridgeRun`，并跳过设备发现；普通 `NoAutoConnect` 路径保持离线显示。为验证该流程，曾将更新后的 `bridge-ui.ps1` 单独覆盖到按候选 manifest 逐项复制的临时包中，并用候选 EXE 完成 PowerShell 5.1、WPF、Native、内存发送与正常关闭流程；该临时覆盖只用于预检，最终发行文件须来自同一干净源码提交的正式构建与打包记录。构建来源和文件哈希以 candidate manifest/provenance 为准。本阶段没有创建 tag 或发布 GitHub Release。

此前的实际 WPF 输入回归通过 63 项断言，root 接受该证据。另一次后续尝试时 Dota 2 在前台，WPF 窗口没有收到输入事件；该次没有形成有效 UI 输入结果，也不覆盖此前通过的 63 项结果。没有再次抢占前台输入。

打包工具在初次形成 stable package 时会生成 `awaiting_root_audit` 状态的中间 ZIP。root 审核 generic 目录并将 manifest 标记为 `root_audit_passed` 后，中间分发需从候选位置移出并保留到私有归档，再通过 `New-StableReleaseDistribution` 在独立路径重新生成最终 ZIP、manifest 原字节副本和 SHA256SUMS；root 对这三项最终资产复核后，才进入发布步骤。

## 正式 stable Release（2026-11-03）

Root 审核 generic 目录和最终三项资产后，正式发布 tag `v0.1.0`。该 annotated tag 指向产品源码提交 `c12b50a9f339417ffd49d37b7acab6057fa51bcf`，普通推送到 `origin`；GitHub 仓库为 private，Release 已发布且 `prerelease=false`：[WIREX Bridge v0.1.0](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0)。stable manifest 记录 `package_status=root_audit_passed`、42 条文件记录、43 个 ZIP 条目、8 个目录和 36 个源码映射。package 在 tag 发布前完成；发布后没有重打 ZIP、改 tag 或改动 manifest。

| 分发资产 | 长度（字节） | SHA-256 |
| --- | ---: | --- |
| `WIREX_Bridge_v0.1.0.zip` | 768,471 | `891c5028ed682b158acf17c39e3e1f699750111750f2ebd0bba22d8fbd0456ed` |
| `manifest.json` | 22,534 | `1bdc80890cd8aa0b51b19c8f6385d312014b11c006b4643e2b31862cd980cc0e` |
| `SHA256SUMS.txt` | 170 | `f81e1a2132323543041c3fac160b8885657e5670f4e7badd4eb31008a7c1567d` |

Root 审计 generic 目录后，只修订 manifest 的人工审核元数据：将静态组说明更新为 `Static labels require current BM API readback; local listening routes alone do not establish server static bindings.`，并把 `release_scope` 更新为 R124 频道来源标记、激活去重、纯 ID 中文预设、频道点击控件、胶囊增益滑块和 EXE/自动配置初始化。42 条文件记录、36 个源码映射及 Native/launcher 构建 provenance 未改；root 随后复核了标记后的目录和最终 ZIP 的每条文件长度、SHA-256 与配置排除状态。

publisher 先创建 draft 并核验三个资产，再将其发布为 stable Release。发布后用真实 downloader 从私有 GitHub Release 下载到隔离审计目录 `build/_work/downloaded-v0.1.0-r124-audit`。下载器验证 Release 状态、manifest、checksum、ZIP 条目路径/类型/大小/hash、provenance 和固定库存；结果为 43 个文件、8 个目录，42 条 manifest 记录及外部 manifest 均与获审 generic 目录逐字节相同，无 `config.json`、reparse point 或遗留 staging。最初下载暴露出 `.part` 临时资产与精确解压库存处于同一路径的真实错误。后续 downloader 修复把临时资产放到同级独立 scratch 根，解压目录仍执行完整精确库存与 provenance 校验；fake-HTTP 生产路径回归及真实私有 Release 下载均通过。此工具修订在 v0.1.0 tag 之后，不属于已发布资产，tag 仍指向 `c12b50a`。

发布包不包含用户配置；本机 stable 目录的配置迁移及 Alpha 19 归档按本机交接记录单独执行，配置内容和哈希不写入文档。此前 63 项真实 WPF 输入回归获 root 接受；后一次前台 Dota 2 环境没有让 WPF 窗口收到输入，不作为通过结果。本轮未进行设备、BM、音频、PTT 或 RF 实测。

## 本机旧版本归档与启动入口（2026-11-03）

正式发布后的 downloader sibling-scratch 修复及交接提交 `3ce22aee7d080311be0821228d59072bd8de6f57` 推送到 `origin/codex/r124-stable-release`。它没有更新 `origin/main`、`v0.1.0` tag、Release 或三项已发布资产；tag 仍指向 `c12b50a9f339417ffd49d37b7acab6057fa51bcf`。

为保留旧版和离线构建证据，以下内容已按原相对路径可恢复移动到 `private/build-retired/R124/build/`：Alpha 19 本机包、7 个 R124 launcher 旧构建目录、R123 `b102cd6` Native 构建目录及其 `r123-b102cd6-clean-full40.log`，合计 10 项、230 个文件、70 个目录。操作前逐项解析了绝对源路径，确认路径仍在 `app/build/`、源树没有 reparse point、文件可独占打开、没有来自该 build 的进程，且归档目标不存在；目录使用 `Directory.Move`，日志使用 `File.Move`。操作后源路径均消失，目标文件和目录计数与移动前一致，目标树没有 reparse point。现在 `build/_work/` 为空，`build/releases/` 只留 `v0.1.0`。

Alpha 19 目录内的 config、日志和缓存随目录原样保留；没有读取该旧 config 的字段、打印其内容或计算哈希。当前 stable `build/releases/v0.1.0/config.json` 保持原位，用 `WirexBridge.exe --validate-config` 完成只读 schema 校验，退出码为 0；校验前后文件长度和修改时间相同，没有与 Alpha 19 配置比较或覆盖。

根目录被 `.git/info/exclude` 忽略的 `start-my-bridge.cmd` 长 103 字节，调用 Alpha 19 的启动器。已用 `File.Move` 原样移动到 `private/build-retired/R124/legacy-entrypoints/start-my-bridge.cmd`，移动前后逐字节比较相同；没有创建新的 CMD 入口。用户当前保留的 stable 启动目录和配置未被移动或覆盖。本次归档及配置检查没有连接电台、BM、音频或 RF。
