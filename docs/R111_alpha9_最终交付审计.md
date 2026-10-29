# R111 alpha.9 最终交付审计

## 源码与构建

- 最终源码 HEAD：`15e60753f201d92937d5ca3ccaf3d5ee0d29c313`。该提交及之前 R111 源码提交已普通推送到 `origin/main`；本机和远端 `main` 在本次构建时均为该提交，工作树干净。
- clean build：`build/_work/wirex-bridge-15e6075-20261029-001540`。
- build log：`build/_work/r111-15e6075-clean-build.log`。
- provenance 记录 `source_tree_clean=true`、`compile_only=false`、`build_completed=true`、`result=passed`，39/39 测试通过。构建日志中没有 compiler/linker warning 或 error。
- EXE 大小 950,784 字节，SHA-256：`53cbfafaef31890451cab4e77a4b4faf20d55084fe7422b8c04801283d523ab1`。

## 通用包与包级检查

- 正式包：`build/releases/v0.1.0-alpha.9`。
- 32 条 manifest 资产记录的文件长度与 SHA-256 均通过核验。通用包含32项资产和 `manifest.json`，共33个文件；本机额外加入一个不在 manifest 内的 `private/user-config-directory.txt`，所以本机包目录有34个文件。
- 根审计后的 manifest 状态为 `root_audit_passed`，manifest SHA-256：`90224a05e962731170d3e56d5a21310ae9810e50dcca39b0bdd0675f311aa462`。package、publisher、downloader 三个脚本的32项文件路径及资产名与 manifest 一致。
- 包含唯一根目录 `start-wirex-bridge.cmd` 与运行所需 `ui/windows/RadioIdentity.psm1`。六个包内 PowerShell 文件均带 UTF-8 BOM；Windows PowerShell 5.1 `Parser.ParseFile` 解析结果为0个错误。通用包没有 RadioID 测试脚本、测试 HTTP helper、缓存、频道收藏、个人 profile、密码路径文件或运行日志。
- 本会话与根会话分别在 Windows PowerShell 5.1 运行正式包 helper并通过。检查覆盖中文与空格目录中的唯一 CMD、`PrepareOnly`、隔离 WPF/Native routing diagnostic、无参数启动失败提示与 exit 2、fake timeout 子进程收尾。包内 `test-control.ps1` 的 schema 2 hello/status/shutdown 也通过。
- routing diagnostic 启动隔离 Native 进程并使用内存 sink；检查未连接 BM、真实 COM、电台音频或 RF。没有进行 PTT、官方程序运行或硬件验收。
- 根和独立审计均核对包内清单与 provenance。RadioIdentity、UI、包发布说明和启动入口都在包中。包内 README 把 RF 行为写为未经硬件验证，但没有进一步写明 C4FM RF codec/serializer 尚未接入运行链；仓库本审计、交接和非包内 release notes 已准确记录该实现边界。

## 离线测试与界面检查

- package release 离线测试：403 项断言通过。
- publisher 离线测试：83 项断言通过。
- downloader 离线测试：1304 项断言通过。
- RadioIdentity 测试在 PowerShell 7 与 Windows PowerShell 5.1 分别通过37项 fake/local 断言；根另对公开 RadioID SourceID 做了一次 PS5.1 HTTPS 单 ID 查询，HTTP 200，响应 ID 与呼号匹配，没有写缓存或输出个人资料。
- UI 目标、状态、路由动作、routing diagnostic、生命周期检查通过。1280×900 与1024×728 RenderOnly 主窗口、底栏和展开详情截图已人工查看；RenderOnly 没启动 Native。routing diagnostic 才启动隔离 Native 进程。

## 本机配置指针

- alpha.9 包内本机 `private/user-config-directory.txt` 只有 canonical `app/private/user-config` 的绝对目录路径；通用包来源没有该个人文件。
- canonical `bridge-directory.txt` 已从 alpha.8 切换为 alpha.9。切换前文件原样备份到 `private/config-backups/R111/bridge-directory.before-alpha9.txt`；备份与切换前文件 SHA-256 相同。
- `connection-profile.json`、`audio-settings.json` 和 `password-file-path.txt` 在指针更新前后哈希相同。没有读取或复制密码文件内容，也没有将个人配置写入 Git 或通用包。

## 运行结果与功能边界

- alpha.8 TG91 用户听感正常但略小。该次会话启动记录的播放增益为1.000x、clipped samples为0；canonical 音量设置约61秒后才写入5.959x。因此那次播放没有使用后写入的增益。alpha.9 显示运行增益、保存值和削波计数，并提示修改后重连生效；目前没有 alpha.9 实机听音结果。
- A 收听规则与 B 起呼目标独立。历史最多显示50条真实呼叫记录。TS 按软件路由保存；BM `slot_flags` 默认值及网络 metadata 为 `4`（simplex），设备没有经过双时隙 RF 验收。CC 是高级 DMR 发射编码/上报参数，接收规则不按 CC 过滤。
- 列表顺序只是显示排序。本版没有新来话自动仲裁；当前媒体 owner 播放来话时，新流不会抢断或排队补播。本机也收不到 BM Master 未转发给它的语音。
- 频道收藏中的 `static`/`dynamic` 是本机分类，程序没有查询或修改 BM 服务器订阅；没有静默添加动态组的官方 API 实现。Dynamic Quick Call 会发送空呼叫控制帧，用户观察到 BrandMeister Dashboard 显示记录，其他终端展示方式未知。
- RadioID 查询仅由用户明确操作后查询单个 ID，cache 写入当前 canonical `UserConfigDirectory/radio-identity-cache.json`。不自动批量查询，不把数字 DMR ID 当成真实呼号。
- FTX-1 实际 LCD 内容仍未知。静态研究只定位到10字节 HRI `Src CallSign` 字段，设备屏幕显示尚未确认；机身 BUSY/TX LED 和串口行为未修改。C4FM RF 双向 codec/serializer 尚未接入运行链，相关功能尚未实现。

## build 归档

根批准的 `retire-plan.json` SHA-256 `a27acd1b1b4bf4b5e7e9eabdb6a2a4288b3799ecb27d03d619a13fc9de17d522` 已执行。7个指定源路径已通过 `Move-Item` 镜像移至 `private/build-retired/R111/build`，共264个文件、72个目录、43,045,757字节；7个目标存在、所有原路径消失。没有永久删除。

移动 journal `private/build-history/R111/retire-move-journal.jsonl` 有16行，每行是一个压缩JSON对象：操作开始/完成各1条，7项移动各有开始和完成记录，失败记录为0。journal SHA-256：`b64b7f7c80c43729d385e91b863a718c3d6eab29c679327ea5021710365c2d48`。build 现在只保留 alpha.9 包、15e6075 clean build 与 clean-build log。归档前后 canonical `connection-profile.json`、`audio-settings.json` 和 `password-file-path.txt` 哈希相同；密码文件内容没有读取。

alpha.9 personal pointer 指向 canonical `app/private/user-config`，canonical `bridge-directory.txt` 指向 alpha.9。旧 bridge pointer 备份为 `private/config-backups/R111/bridge-directory.before-alpha9.txt`，SHA-256：`93a4d757d768b2c6c85cfe807f5ade3c74d5c73cd66b53c674d70ace0e48d4e5`。旧指针内容和密码目标内容均未写入 Git 或交付包。

本候选没有生成 ZIP、tag 或 GitHub Release。
