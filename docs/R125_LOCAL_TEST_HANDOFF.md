# R125 本机测试包集成记录

> 状态：源码提交 `654dfb3f96c9c5f860f75e739bbf18559b77dbe3` 已推送；root 已审核 generic 测试目录并批准随后迁移当前 stable 配置原字节。本文件更新只改交接文档，不改 pack 映射、runtime 或 manifest。

## 范围和交付边界

`app/build/releases/v0.1.1-test.1/` 是本机测试目录，不对应 Git tag 或 GitHub Release，不生成 ZIP，不调用正式 publisher 或 downloader。root 先审核了 43 文件、8 目录的 generic 目录，之后才批准从 stable `v0.1.0/config.json` 把当前配置原字节复制到测试目录根目录。两份配置长度均为 5,091 字节且逐字节相同；包内 `PortableConfig.psm1` 的 `Get-WirexPortableConfig` 只读 schema 校验通过。没有读取、输出或计算配置哈希，stable 源文件仍保留。

打包器固定写入 main app 下的 `build/releases/v0.1.1-test.1`，发现目标已存在就停止，不覆盖。它从已审核的 v0.1.0 generic 清单复用 42 条文件记录、8 个目录和 36 条 source mapping；Native/launcher 及各自 provenance 从 stable 目录按清单校验后复用。root 审核后复制的 `config.json` 不在 manifest 记录内，所以当前本机测试目录有 44 个物理文件（42 项资产、manifest、配置）和 8 个目录。打包和验证没有连接设备、BM、音频、PTT 或 RF。

## 固定输入与 provenance

- v0.1.0 `manifest.json` 原始字节 SHA-256 固定为 `1bdc80890cd8aa0b51b19c8f6385d312014b11c006b4643e2b31862cd980cc0e`。打包器先核对该值，之后才解析 manifest 并读取 36 条 source mapping。
- Native 与 launcher 的原始 source commit 都是 `c12b50a9f339417ffd49d37b7acab6057fa51bcf`。Native SHA-256 为 `8f629aefbaaba3b865f09b3d1cb4b012e6b1953a7ec58d340edbec460225ca32`，原记录有 40 项通过；launcher SHA-256 为 `de4d0b113cd7a25a907b3fe96a0a4b1579730c1a884175930ad6db9412b60638`。本地 manifest 保留原 build records，并另列复用理由，不把它们改写成 R125 构建。
- 获准的 HRI 模板限定为 `runtime/private/device-y.bin`，长度 100 字节，SHA-256 `82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f`。
- R125 source commit 为 `654dfb3f96c9c5f860f75e739bbf18559b77dbe3`。相对 `c12b50a` 的 Native、include、third-party、CMake、Supervisor、launcher 和 Native/launcher build-input 改动均为 0；本轮复用 stable 二进制，没有重建 Native。

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
| local-test pack producer | Windows PowerShell 5.1 `-File` 成功生成目标目录：42 项 manifest 资产、43 个 generic 文件、8 个目录；UTF-8 BOM 修复记录在提交 `654dfb3` |
| 实际 generic 目录与 manifest 验收 | 配置迁移前对真实 producer 目录通过 199 项检查；manifest SHA-256 为 `c2e2a7fd296c8e88adf284551dbb0a654496af2ae762be44a03e17d2811a69fd` |
| 旧 launcher 离线路由诊断 | 对上述 generic 目录调用旧 `WirexBridge.exe --routing-diagnostic`，PS5.1 exit 0；WPF/Native QuickCall 使用两帧内存 sink，BM=false，正常关闭 |
| stable 配置迁移 | root 审核 generic 目录后，从 stable 原字节复制；源和目标均 5,091 字节、逐字节相同，public schema 只读验证通过，未计算配置 hash |
| Native rebuild | 未执行；无受保护构建输入差异，复用已审核 v0.1.0 Native/launcher |

`tools/test-package-local-test.ps1` 在 stable 配置迁移前对真实 producer 目录检查 manifest、全部资产记录与哈希、36 条 source mapping、8 个目录、二进制复用记录和受保护输入差异，共 199 项通过。它不构造 synthetic 镜像。配置之后按 root 授权单独原字节迁入，未重写 manifest。

## R125 implementation exact-path 快照

R125 产品与打包实现提交为 `fac3faaa39c7622d51607364ec606022e5827d24`；PS5.1 UTF-8 BOM 兼容修复提交为 `654dfb3f96c9c5f860f75e739bbf18559b77dbe3`。这两个提交的 exact path 清单如下：

已修改：

- `tools/test-channel-activation-state.ps1`
- `tools/test-ui-audio-gain.ps1`
- `tools/test-ui-channels.ps1`
- `tools/test-ui-render.ps1`
- `tools/test-ui-status.ps1`（一行断言标题从 `组呼 TG 91` 修正为当前标题 `组呼 91`）
- `ui/windows/ChannelActivationState.psm1`
- `ui/windows/MainWindow.xaml`
- `ui/windows/bridge-ui.ps1`

其余 6 项为新增文件：

- `docs/R125_UI.md`（UI owner 文档）
- `docs/R125_RUNTIME.md`（runtime/state owner 文档）
- `docs/releases/v0.1.1-test.1-local-README.md`
- `tools/package-local-test.ps1`
- `tools/test-package-local-test.ps1`
- `docs/R125_LOCAL_TEST_HANDOFF.md`（本文）

generic manifest 中的 Native 和 launcher SHA-256 仍分别是 `8f629aefbaaba3b865f09b3d1cb4b012e6b1953a7ec58d340edbec460225ca32` 和 `de4d0b113cd7a25a907b3fe96a0a4b1579730c1a884175930ad6db9412b60638`；两项 build provenance 都指向 c12。通用 manifest 仍不包含配置、日志、凭据或缓存；本机配置文件只额外存在于测试目录根部，且不属于 manifest。

所有 WPF/Native 诊断均使用隔离 synthetic fixture；没有启动正常 app、设备、BM/API、CAT/COM、音频、PTT 或 RF。实际 TG46001 动态组激活及收发仍待后续用户授权的实机 BM 联测。stable `v0.1.0` 目录、配置、tag 与已发布 Release 均保留；R125 测试目录不是正式发行。
