# R125 本机测试包集成记录

> 状态：所有 owners 已冻结源码；root 已审核 UI 截图和 UI reviewer 生命周期审查。本文记录提交前的集成证据；本机测试目录、真实 producer 验收和旧 EXE 离线诊断将在 clean source commit 后执行。

## 范围和交付边界

计划生成 `app/build/releases/v0.1.1-test.1/` 本机测试目录。它不对应 Git tag 或 GitHub Release，不生成 ZIP，不调用正式 publisher 或 downloader。只有 root 审核 generic 目录后，才可另行把当前 stable 配置原字节迁入测试目录；本轮打包工具不会读取、复制或输出配置字段，也不会计算配置哈希。

打包器固定写入 main app 下的 `build/releases/v0.1.1-test.1`，发现目标已存在就停止，不覆盖。它从已审核的 v0.1.0 generic 清单复用 43 文件布局、8 个目录和 36 条 source mapping；Native/launcher 及各自 provenance 从 stable 目录按清单校验后复用。打包期间不连接设备、BM、音频、PTT 或 RF。

## 固定输入与 provenance

- v0.1.0 `manifest.json` 原始字节 SHA-256 固定为 `1bdc80890cd8aa0b51b19c8f6385d312014b11c006b4643e2b31862cd980cc0e`。打包器先核对该值，之后才解析 manifest 并读取 36 条 source mapping。
- Native 与 launcher 的原始 source commit 都是 `c12b50a9f339417ffd49d37b7acab6057fa51bcf`。Native SHA-256 为 `8f629aefbaaba3b865f09b3d1cb4b012e6b1953a7ec58d340edbec460225ca32`，原记录有 40 项通过；launcher SHA-256 为 `de4d0b113cd7a25a907b3fe96a0a4b1579730c1a884175930ad6db9412b60638`。本地 manifest 保留原 build records，并另列复用理由，不把它们改写成 R125 构建。
- 获准的 HRI 模板限定为 `runtime/private/device-y.bin`，长度 100 字节，SHA-256 `82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f`。
- R125 UI source commit 与最终 source diff 尚未冻结。打包前必须确认 Native C++、third-party、`BridgeSupervisor.cs`、C# launcher 和相关构建输入相对 `c12b50a` 均无变化；否则停止复用流程并重新评估构建证据。

测试 manifest 使用 `package_kind=wirex_bridge_local_test_directory`、`package_status=local_test_only`、`version=v0.1.1-test.1`，不设置 v0.1.0 tag，也不声称已发布。正式 publisher 要求稳定包 kind、`root_audit_passed`、`v0.1.0` version 和 tag；本地测试 manifest 不满足这些条件。

## 当前验证状态

| 项目 | 结果 |
| --- | --- |
| ChannelActivationState | 348 项断言通过；开始请求和 NACK 保留旧本机记录，有效两帧 ACK 后才替换（root 提供） |
| gain | 92 项断言通过；整数范围、步进和旧值运行时转换（root 提供） |
| channels | 186 项断言通过；覆盖队列生命周期和 Stop、最后频道删除、断开后的取消（owner 提供） |
| console | Windows PowerShell 5.1 STA 下 121 项真实 WPF 交互断言通过；使用合成串口/CAT/supervisor fixture，未启用 `-LiveSerialReadOnly` |
| status | Windows PowerShell 5.1 STA 下 87 项断言通过；同步修正一条频道标题 regex，使其匹配当前 `组呼 91` 显示文案 |
| RenderOnly | Windows PowerShell 5.1 STA 最终回归 6,155 项通过；六张主窗图为 1360×900，gain 1/8/16 各重复两次（UI owner 提供） |
| 中文 UI 截图与独立审查 | root 已接受 UI owner 最终截图；独立 UI 生命周期审查没有 P1/P2 项 |
| local-test pack producer | 两个 PowerShell 文件语法解析通过；脏源码树门禁此前按预期拒绝，未创建测试目录；需在 clean source commit 后运行 producer |
| 实际测试目录、manifest 验收与旧 EXE 离线诊断 | 尚未执行；root 已授权在 clean source commit 后执行 |
| Native rebuild | 未执行；相对 c12 的 Native/third-party/CMake/Supervisor/launcher/build-input 改动为 0，计划复用已审核 v0.1.0 Native/launcher |

`tools/test-package-local-test.ps1` 会在真实 producer 生成测试目录后检查该目录中的 manifest、全部文件记录与哈希、36 条 source mapping、8 个目录、二进制复用记录、受保护输入差异，以及配置和日志排除状态。它不构造 synthetic 镜像；测试只能在获准生成真实本机测试目录后运行。

## 当前工作树 exact-path 快照

以下清单来自冻结前工作树状态；最终提交前必须重新核对并按实际 diff 更新。

已修改：

- `tools/test-channel-activation-state.ps1`
- `tools/test-ui-audio-gain.ps1`
- `tools/test-ui-channels.ps1`
- `tools/test-ui-render.ps1`
- `tools/test-ui-status.ps1`（一行断言标题从 `组呼 TG 91` 修正为当前标题 `组呼 91`）
- `ui/windows/ChannelActivationState.psm1`
- `ui/windows/MainWindow.xaml`
- `ui/windows/bridge-ui.ps1`

未跟踪：

- `docs/R125_UI.md`（UI owner 文档）
- `docs/releases/v0.1.1-test.1-local-README.md`
- `tools/package-local-test.ps1`
- `tools/test-package-local-test.ps1`
- `docs/R125_LOCAL_TEST_HANDOFF.md`（本文）

提交前核对：R125 exact paths 共 14 项；路径名未包含 config、log、credential、secret 或 API key 文件。相对 c12 的 Native、include、third-party、CMake、Supervisor、launcher 和 Native/launcher build input 差异均为空。正式 stable Native 与 launcher 仍分别是 `8f629aefbaaba3b865f09b3d1cb4b012e6b1953a7ec58d340edbec460225ca32` 和 `de4d0b113cd7a25a907b3fe96a0a4b1579730c1a884175930ad6db9412b60638`。

以上 console/status 与 owners 回归均使用离线合成数据；未读取、输出或计算用户实际配置字段或哈希。尚未运行正常应用、连接设备/BM、启动音频/PTT/RF，亦未迁移 stable 配置。本机测试目录生成后须由 root 独立审核；本文件不将测试目录称为正式发行。
