# WIREX Bridge 交接入口

更新：2026-11-04（R127）。本文只记录当前状态。更早的逐轮交接（R103–R125）可通过 `git log -- HANDOFF.md` 或 `git show 1283f86:HANDOFF.md` 查看。系统组成见 [ARCHITECTURE](docs/ARCHITECTURE.md)，待办以 [TODO](TODO.md) 为准。

## 当前版本

| 项 | 状态 |
| --- | --- |
| `main` | 已包含 R126（运行状态收尾修正、来话历史分页、UI 调整、ZIP-only 发布工具、图标）以及 R127 清理 |
| stable `v0.1.0` | tag 指向 `c12b50a9f339417ffd49d37b7acab6057fa51bcf`，GitHub Release 已发布（`prerelease=false`）；发布审计见 [R124_RELEASE](docs/R124_RELEASE.md) |
| 本机测试目录 | `build/releases/v0.1.1-test.1`（R125 本机测试包，不是正式 release）；回退版本 `build/releases/v0.1.0` |
| R126 ZIP-only | profile `v0.1.1-test.2`/`v0.1.1` 已在 `tools/ZipOnlyRelease.psm1` 中；**尚未打包**，也没有 tag 或 Release |

R126 的设计与验收：[R126_DELIVERY](docs/R126_DELIVERY.md)、[R126_RUNTIME](docs/R126_RUNTIME.md)、[R126_UI](docs/R126_UI.md)、[R126_I18N](docs/R126_I18N.md)。

## R127 清理（2026-11-04）

- **tools/**：文件数从 112 降到 57。删除了 alpha8–19 启动器、旧 alpha release profile、HRI 诊断启动器及其测试。v0.1.0 profile 已内联到 `tools/package-release.ps1`，并已与已发布的 manifest 逐项核对，结果一致。
- **编译中间产物**：删除了根目录和 `app/` 下散落的 `*.obj`；`.gitignore` 现在在任意层级忽略 `build/`、`tmp/`、`*.obj`、`__pycache__/` 等。
- **私有历史**：`private/build-retired` 与 `build-history`（R110–R124，共 26407 个文件、3.85 GB）先压缩为 `FTX1_project/_archive/wirex-private-history-R110-R124.7z`（434 MB，`7z t` 校验通过），然后从工作区删除。
- **旧 worktree**：`native-build-R126` 和 `r124-stable-release` 的 `build/` 已归档为 `_archive/wirex-worktree-builds-R124-R126.7z`（910 个文件），两个 worktree 均已移除。
- **docs/**：
  - 删除 112 份过时文档：`docs/` 下 70 份（R104–R125 的逐轮交接、发布交接、UI/CAT/RUNTIME 记录，S1-*/S3-A 验收，早期计划与联测清单）和 `docs/releases/` 下 42 份（`v0.1.0-alpha.*` 的发布说明、包 README 和构建审计）。这些文件仍可从 git 历史找回。
  - 移到 `docs/research/` 的有 22 份研究资料，以及 2 份 R110 证据索引（`docs/research/evidence/`）。移动后已修正相对链接，指向已删文档的链接改为纯文本。
  - 留在 `docs/` 根目录的有 20 份，另加新建的 `ARCHITECTURE.md`；`docs/releases/` 保留 5 份。

## 环境注意事项

- **从 Git Bash 调用 Windows PowerShell 5.1**：必须先重置模块路径，否则会继承 PowerShell 7 的路径，导致 `Get-FileHash` 等命令找不到：
  ```sh
  PSModulePath='C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules' \
    powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-console.ps1
  ```
- **编码**：`.ps1`/`.psm1` 必须保留 UTF-8 BOM。PS5.1 会把无 BOM 的文件按本机 ANSI 读取，中文字符串会变成乱码，甚至导致解析失败。
- **测试前置条件**：`private/fixtures/device-y.bin`（HRI 模板）、`build/releases/v0.1.0`（已发布包目录）和本地 `v0.1.0` tag。三者都不在 Git 工作树中，新 worktree 需要另行准备。

## 离线测试基线

在 main `1283f86` 上用 Windows PowerShell 5.1 实测。

全部通过：

| 测试 | 断言数 |
| --- | --- |
| `test-package-release` | 214 |
| `test-publish-release` | 66 |
| `test-download-release` | 通过 |
| `test-r126-zip-only` | 26 |
| `test-bridge-user-config` | 通过 |
| `test-start-bm-radio-bridge` | 通过 |
| `test-portable-config` | 69 |
| `test-ui-channels` | 通过 |
| `test-ui-console` | 121 |
| `test-ui-status` | 87 |
| `test-channel-activation-state` | 348 |

已知失败（R126 之前就存在，main `405426f` 上同样失败，与本轮清理无关）：

- `test-ui-render`：断言 [117]，BM 静态组按钮文字。
- `test-ui-r124`：SerialBox 下拉列表。
- `test-package-ui-contract`：R123 UI 合同。

Native 40 项测试（`tools/build-bm-bridge.ps1`）本轮没有重跑。R126 Native 源码最近一次 clean full40 是在 `9170bad` 上 40/40 通过（见 R126_RUNTIME）。

## 实机待办

见 [TODO](TODO.md) 第一节：
- 1.1 R126 收尾：集成运行复核、TG46001 动态组实际收听、图标显示。
- 1.2 电台与射频实机核对：BM↔FM/C4FM 双向、CAT 能力边界、LCD 可重复性观察、听音对照。

本仓库目前没有任何实机验收结果覆盖 R126。

## 文档索引

| 文档 | 用途 |
| --- | --- |
| [README.md](README.md) | 用户使用说明（用户维护，不随交接修改） |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 当前系统架构：组件、进程、IPC、配置、发布结构、构建与测试入口 |
| [TODO.md](TODO.md) | 权威待办清单 |
| `docs/R126_*.md` | 当前轮次的设计与验收记录 |
| [docs/R124_RELEASE.md](docs/R124_RELEASE.md) | v0.1.0 发布审计记录 |
| `docs/releases/` | `v0.1.0.md`、`v0.1.1-test.2.md`、`v0.1.1.md` 是 Release 正文，由 `publish-release.ps1` 按 tag 读取；`v0.1.0-package-README.md`、`v0.1.1-test.1-local-README.md` 是打包脚本使用的包内 README |
| `docs/` 下其余 14 份（`BM来话身份显示`、`R106_*`、`R108_*`、`R109_*`、`R112_A_网络音频指标`、`R113_*`、`R116_*`、`连接配置`、`配置与桌面操作`、`音量调节`） | v0.1.0 包内 `runtime/docs/` 文档。打包、下载脚本和测试按路径与内容引用它们，**不能改名，也不能修改内容**（即使里面有失效链接） |
| `docs/DMR通话实现.md` | DMR FEC/LC 上游来源说明，`include/wirex/dmr_call.hpp` 按路径引用 |
| `docs/research/` | 独立研究资料：AMBE/C4FM 参数映射、BM 协议与 API、HRI 记录与 PTT、WIRES-X 官方软件功能与屏幕研究、RF 节点计划、LCD 审计等。只记录研究当时的结论，不代表当前实现 |

改动 `docs/` 前，先用下面的命令确认文件没有被代码引用：

```sh
git grep -ohE "docs[\\\\/][^'\" )\`|]+\.md" -- tools ui src tests include
```
