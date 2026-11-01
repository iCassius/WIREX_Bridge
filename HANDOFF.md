# WIREX Bridge 交接入口

## R119 / Alpha 15 当前交接（2026-11-01）

本轮 CAT/UI 与 Native 源码已经冻结，独立 review 未发现 P1/P2。R119 为 CAT 首次全状态查询及自动周期同步、查询期间编辑器与滑块保持稳定、单 worker 写操作门控、断连撤销写授权但保留观测值，以及运行时播放/麦克风增益能力协商。UI 通过既有观测字段显示 CAT readback；实时音量仅在 Native 同一 run 的 ready/hello 均声明 `audio.gains.set` 时启用，alpha14 旧命令集仍获兼容。测试和边界见 [R119 发布交接](docs/R119_发布交接.md)、[CAT 记录](docs/R119_CAT.md)、[UI 记录](docs/R119_UI.md) 和 [实时音量记录](docs/R119_实时音量.md)。

源码提交 `a9b2d6ad0d96b7dadd995d28e8b42bbd9ff9f080` 已推送到 `origin/main`。由干净提交完成 fresh Native 40/40 构建，`source_tree_clean=true`、`compile_only=false`、MSVC warning/error 各 0。alpha15 绿色目录 `build/releases/v0.1.0-alpha.15` 有 41 条 manifest 资产、37 项源码映射、42 个通用文件；root 独立审计通过，`package_status=root_audit_passed`。manifest SHA-256 为 `5f224b57bd50f1f00c279e3de6f3ad3ad002224631215d56f440c22bb207a2eb`；构建、EXE、provenance、日志及包级测试哈希见 [alpha15 本机候选记录](docs/releases/v0.1.0-alpha.15.md) 与 [R119 发布交接](docs/R119_发布交接.md)。

Windows PowerShell 5.1 的 package-startup、test-control、包目录下的 `test-ui-control-v2.ps1 -UiPackageDirectory` 和 package/publish/download 离线测试均通过。包内 capability 检查覆盖 alpha14 旧能力命令集与新增 `audio.gains.set`，IPC 真实诊断通过。个人 alpha15 配置从当前 alpha14 `config.json` 原字节复制并由 source PortableConfig 只读校验，包含在本机目录但不在通用 manifest 或 Git 中；本轮未读取 legacy canonical、未修改 alpha14 配置。根启动器备份后改为相对调用 alpha15 唯一 CMD，没有运行正常启动。没有制作 ZIP/tag/GitHub Release，也没有操作真实 COM、BrandMeister、HRI、音频、PTT 或 RF。后续个人配置变更从当前 alpha15 覆盖文件继续，不从 legacy canonical 重新导入。

收尾归档已由 root 独立核对：`private/build-retired/R119/` 下6个源根共281个文件、50,305,486字节，全部长度与280个非敏感文件的SHA-256均无差异；个人配置与alpha15副本逐字节一致，所有源路径已移走。计划 `private/build-history/R119/R119-cleanup-plan.json` 的SHA-256为 `93deda77e6b684ba3f6d964d619aaa4335a37eeb341915de23c62f41706e1e2e`，移动日志 `R119-cleanup-move-journal.jsonl` 的SHA-256为 `07feaaf2ad4d90b335830fe756529fb8f3318f779a30f4bbc7cef6f2b4bd3c03`。7个本轮验证日志已可恢复移动到 `private/build-history/R119/verification-logs/`，逐项搬前/搬后长度和SHA-256见 `R119-verification-logs-move-manifest.json`（SHA-256 `c5ee1ec878d42cdb6fc5c6b0b2d33894339411f32a86a35c10e453ac795eb051`）。`build/_work/` 仅保留 alpha15 最终构建目录和它的 clean-build 日志；`build/releases/` 仅保留 alpha15。真实设备与RF HIL仍待用户验收。

## R118 / Alpha 14 历史交接（2026-11-01）

源码提交 f0105d7da667c2dbc1ca24d78f2b3b11e9be9eb6 已推送。由该提交 fresh Native clean build：source_tree_clean=true、compile_only=false、40/40 测试通过，MSVC warning/error 诊断为0。root 独立审计确认 41 项 manifest 资产、37 项源码映射、40 项 Native 测试结果及 EXE/provenance 哈希一致；package_status=root_audit_passed，manifest SHA-256 为 09a8448cd96c2f9a1c949b621d85d0add996d36756f25cfb6f596ad3747467b0。通用包含 42 个物理文件，本机迁移后另有未纳入 manifest 的 config.json，因此发行目录共 43 个文件。

旧构建已可恢复地归档至 `private/build-retired/R118/`，目录和日志保留原名称。归档涵盖7个源根项目，共503个文件、88,485,916字节；独立验收逐项核对源与目标的长度和哈希，结果0差异，且源路径均已不存在。归档计划位于 `private/build-history/R118/R118-build-retirement-plan.md`（SHA-256 `7593198430f3e8cc70970a644e7fe2a1a485d8a7a17332b3241b33d91e49e88d`），移动日志位于 `private/build-history/R118/R118-build-retirement-move-journal.jsonl`（SHA-256 `8d4c2ae37e298263e9697f96cfd4eb41efa683a1996389e97af92af466527e1d`）。`build/_work/` 仅保留最终 f0105d7 clean build 和对应日志；`build/releases/` 仅保留 alpha14。

PortableConfig/BM模块为55/45项断言；package/publish/download为579/124/2,137项离线断言；status、identity、lifecycle、radio-cat、channels五项WPF回归在PS5.1/PS7 STA均通过，channels每版74项。包和构建哈希、命令及证据见 [R118 发布交接](docs/R118_发布交接.md)。

旧设置已按显式目录迁移到 alpha14 根目录 config.json。频道顺序为 private:460997:2、group:46001:2、group:91:2，TX 目标保持 private:460997:2；追加 TG91 只保存频道，没有发起 QuickCall。旧 local_private_routes 只归档在 legacy 快照中，没有转换为本机 ID 私呼频道。迁移发现凭据存在（true），文档和日志未记录凭据值或外部凭据路径。4 份迁移前已存在的受保护旧设置文件在迁移后逐字节未变；旧收藏未读取或迁移，canonical 指针未修改。

根目录 start-my-bridge.cmd 已备份到 private/config-backups/R118/start-my-bridge.before-alpha14.20261101-123807.cmd，并改为相对调用 alpha14 的唯一 CMD；静态检查确认目标存在，未运行正常启动。没有连接真实 BM/COM/HRI/音频/PTT/RF，也没有制作 ZIP、tag 或 GitHub Release。

alpha14 当时的验收细节以 [R118 发布交接](docs/R118_发布交接.md) 为准；以下为更早阶段记录。
## R115 FTX-1 模式范围与后续开发计划（2026-10-30）

本轮仅更新文档；没有改源码、配置、发行包或操作设备。详细功能范围、手册页码、验收门槛和未来实机记录要求见 [R115 模式范围与开发计划](docs/R115_文档功能范围与后续开发计划.md)。

用户报告：相同 HRI/DIRECT 下官方 WIRES-X 程序也没有 LCD 内容或图标，底部按键无反应；BM 网络来话时看到红灯；用户确认 AP 模式下网络语音可经电台 RF 输出。红灯观察不作为 RF 证据；AP 报告尚未闭合实际 Node Mode、PTT 和空中语音。用户认为 AP RADIO/AP PC 在选择电台 RF 与电脑路径，仍需结合设备实际模式核对。

官方《FTX-1 WIRES-X Edition ENG 2603-B》第 29 页定义 AP RADIO、AP PC 与 DIRECT 的差别；第 8–12 页的 ALL/SEARCH/ENTER ID 属于 C4FM DG-ID、本地节点频率和 GM/X 的 RF 节点流程；第 16 页的呼号/位置显示属于含 GPS 的 C4FM DN(V/D)。第 1 页有 HRI MODE 开关；《HRI-200 Manual 2603-Q》第 23–24 页称 FTX-1 支持 HRI-200 模式，PC 设置会反映到电台并可选 RX/TX 数字或 FM；第 23 页给出进入 HRI 节点模式后的 `WIRES-X HRI` 屏显，第 76 页将来话呼号等信息列在 PC 端 `User monitoring`。用户观察没有单独记录状态字样是否出现；手册未规定 HRI/DIRECT 底部软键或 LCD 来话列表。WIRES-X Ver.2.0xx 的“仅显示已连接节点信息”说明限定在 PDN；官方节点比较页另列 FTX-1+PC full-spec 节点，PDN 说明不能代替 FTX-1 HRI/DIRECT 的屏显定义。普通数字 News/GM 流程也不属于 HRI 网络来话显示目标。《FTX-1 Basic Manual》印刷第 10 页仅定义通用 BUSY/TX 红灯为发射提示。2026-08-28 官方固件说明未列出 HRI 空屏问题，因此不能据此判定固件未完成。

开发顺序：P0 查清是否可读取真实 Node Mode/RX-TX 调制；若读不到就把 `unknown` 记入内部日志，主界面隐藏无读值字段，通过已有有效操作收集人工确认，不暗切 Node Mode，也不宣称软件锁定物理 DIRECT 或禁止 RF。明确 `BM transmit_enabled` 只约束 BM 网络上行，并单独定义 AP 射频转发许可与 DIRECT 确认。保留官方指示灯行为，不追求“网络呼入亮蓝灯”；通话方向显示真实 BM/HRI 字段。P1 沿现有音频链验收 BM→FTX-1→FM RF 与 FM RF→FTX-1→BM 两个方向，核对 TG91 只监听语义、RX 来源是否经 AP 转发、目标/组选择、PTT 释放、超时和回灌；不新写电脑 FM/IQ 调制器，也不重复已通过的手咪 DIRECT 双向回声。用户已确认 AP 模式下网络语音可经电台 RF 输出，空口验收仍需届时确定可观察的接收手段；当前不要求 MMDVM 或第二台电台。P2 独立查明 C4FM 的 AMBE/帧与元数据后再验证 RF，不从 FM 推断数字通过。

LCD 已按用户最新决定改为独立实验方向，不作为 alpha.12 主线，也不阻挡 CAT、声路或 RF 工作。用户在 DIRECT/HRI 环境观察到没有来话或列表内容、底部软键无响应，红色指示灯与 Bridge 环境相同；这些现象没有映射到具体底层故障。R114 记录的 Native T 帧完整写出不证明 LCD 已绘制；不再重复同一 mode 4 十字节字段尝试。详细离线研究见 [R116 LCD 实验报告](../research/r116/lcd-lab/R116_LCD实验性独立逆向报告.md)。

## R116 alpha.12 CAT 控制接入（2026-10-30）

alpha.12 增加 FTX-1 CAT-1 单操作查询与设置：MAIN/SUB 频率、无线机模式和 PC 功率控制值可查询；MAIN 频率、无线机模式和 PC 值可设置。每次设置前核对 ID0840 与 TX0，发送一次后读回，不自动重试。设置 MAIN 频率或模式会先停止 Bridge 核心，完成后保持断开；应用功率还需最近 3 秒内核心状态空闲、无活动通话、接收媒体空闲或已过滤且队列为空。CAT 手册没有 HRI MODE 或 Node Mode 指令，本版不显示这两项自动切换，也不猜 EX 地址。本版没有新增 RF 控制入口；用户报告 AP 模式下既有 HRI 声路可经电台 RF 输出。软件不读取或锁定 Node Mode，不能以 BM 网络上行开关证明既有电台 RF 声路关闭；该观察不构成本版 FM/C4FM RF 完整验收。若后续验证 CAT 设置写入，须处于 DIRECT/HRI；AP 声路研究另按明确的频率和功率参数规划。

电台偏好使用本机 UserConfigDirectory 中的 radio-control-preferences.json；打开设置窗不会创建文件，只有用户保存时才写。初始偏好为 COM11、38400/8N2、25 W。Windows 未枚举出 COM11 时不会创建假的设备项。期望功率不会在启动、查询或保存偏好时自动发送。通用发行包清单排除此文件。R112 网络音频指标与 R113 历史文档保留。

CAT fake 测试在 PowerShell 7 和 Windows PowerShell 5.1 各通过 52 项断言。UI 的 `tools/test-ui-radio-cat.ps1` 用 fake callback 验证真实 WPF 控件和操作生命周期，在 PS5 STA 与 PS7 STA 均通过；根会话另以 Windows PowerShell 5.1 独立运行退出码 0。RenderOnly 在两种窗口尺寸、缺少 CAT 模块和坏偏好文件场景均通过，根会话完成视检；现有 UI status/lifecycle 检查也通过，status 检查新增的 stub 仅补齐局部依赖，没有放宽断言。发行包 profile 沿用 40 项 Native 测试；package-release 合成断言 516 项、download-release 1783 项、publish-release 离线断言 109 项均通过。

根会话最近一次 Windows PowerShell 5.1.26100.8737 的 COM11、38400/8N2 查询返回来源 `FTX-1 CAT-1`、ID0840、MAIN FM、SPA-1 功率路径设定 25 W，FA/FB 均读回；清理为 `closed`、错误为 `null`，CAT 配置写入次数为 0。该查询没有执行任何设置命令。HRI MODE 与 WIRES-X Node Mode 仍未实现 CAT 写控制。

完整 clean build 已通过：commit `059610c0585a68403b06c64c4f662a815782fa90`，provenance 为 `source_tree_clean=true`、`compile_only=false`、`result=passed`；40 项 Native 测试按 profile 顺序全部通过，编译 warning/error 为 0。构建目录 `build/_work/wirex-bridge-059610c-20261029-214258`，日志 `build/_work/alpha12-clean-build-059610c-20261030-054258.log`，EXE SHA-256 `87215708e9f98d143d476fe0202ed58718de4755f24c4e9ddcbe98244256a64c`，长度 968192 字节。

alpha.12 本机测试包位于 `build/releases/v0.1.0-alpha.12`，profile 的 35 项资产与 manifest 完全匹配；加入 manifest 外的个人 `private/user-config-directory.txt` 后共 37 个物理文件。根只读包审已通过，manifest 的 `package_status` 为 `root_audit_passed`，SHA-256 为 `fe6669abd331ef4e6539a80009a6f3a16ff2ff0d86c4ded53ad2904aa45338af`。获批 Y fixture 为 100 字节且 SHA-256 与固定值相同。个人 overlay 指向 canonical `private/user-config`；canonical `bridge-directory.txt` 已切换到 alpha.12，切换前原始字节备份位于 `private/config-backups/R116/bridge-directory.before-alpha12.txt`，长度 36 字节、SHA-256 `2c96e5c52917133123551638ba541bc169fb9489fedd4ec60b5ebf5223aa2228`。`connection-profile.json`、`audio-settings.json`、`password-file-path.txt` 的 SHA-256 仍分别为 `e4f053bdd1c9f08380cda7c2d3efc77877f7e15ae8c2538a40cf85221fa821ec`、`aa91098ae5cb5fe76d44b9e5062917bce922ed7c94f65214ee587574b283fe51`、`bb7cbf045f4057b191fbea0ee3127511f201a86cb748c95a25911f26cf0ab2ae`；没有创建 `radio-control-preferences.json`。通用包不含本机 RadioID 缓存、频道收藏或密码文件。`tools/test-package-startup.ps1` 由 Windows PowerShell 5.1 实际运行并以退出码 0 结束；包内 CMD 经 PS5.1 进入 PrepareOnly 与隔离 RoutingDiagnosticAutoTest。新包 EXE 的 `test-control.ps1` 与 `test-ui-control-v2.ps1` 均通过，只运行本地协议/路由诊断，没有启动 BM、HRI、串口、音频或 RF。没有生成 ZIP、Git tag 或 GitHub Release。完整接线见 [R116 总交接](docs/R116_总交接.md)、[CAT 实现说明](docs/R116_CAT能力与控制实现.md)、[电台控制界面说明](docs/R116_电台控制界面.md) 和 [alpha.12 本机测试版记录](docs/releases/v0.1.0-alpha.12.md)。

根批准的归档计划 SHA-256 为 `835c995092c0242f5cfd78bc206ff4ccc1433b27a5b5c231501be550c305448f`；执行记录位于 `private/build-history/R116/retire-journal-alpha12.jsonl`，SHA-256 为 `ea4a9ce0fe8e78edbdf02dcadcd616e6d4d0678b1181d36147a9eee186d2739b`。计划内 5 项、254 个文件、43,065,413 字节已用 `Move-Item -LiteralPath` 移入 `private/build-retired/R116/build/` 镜像；源目录均已消失，目标逐文件长度、SHA-256 与计划树摘要一致，没有永久删除文件。alpha.11 包、旧 b05c3a6 构建与日志以及两组 R116 UI 测试产物均在该镜像中；新的 alpha.12 构建、日志和本机测试包未移动。

## R114 alpha.11 LCD 实测与日志审计（2026-10-30）

用户确认 alpha.11 App 呼号显示正常；FTX-1 LCD 两个内容区仍为空白。截图左上角有一个红色 WIRES-X 图标，顶部另有 WIRES-X HRI、DIRECT、HRI MODE 和 FM 字样；当前没有证据把红色图标对应到具体底层故障。详细记录见 [R114 LCD 实测审计](docs/R114_LCD实测审计.md)。

本轮只审计了指定 Native JSONL 的身份字段，共 285 条记录。8 个接收代次（1、3、5、7、9、11、13、15）均经历 `serial_write_state=pending` 到 `sent`；6 次使用 `dmr_id` 回退，2 次 cache hit 后使用 `callsign`（代次 13、15）。日志所有 `lcd_source_identity.display` 值仍为 `unknown`。`sent` 记录完整 T 帧写出；它没有记录 LCD 的实际绘制结果。该 JSONL 没有身份 `cache_upsert`/ACK 专属事件或字段，无法据此确认 UI→Native 的逐项发送和 ACK 状态。收尾从 seq 282 `shutdown_requested` 到 seq 285 `stopped`，BM/HRI 进入 stopped 且 HRI 串口关闭；8 通来话均有 start/end 计数。seq 253 同时记录 `downlink_call_bounded_cleanup_incomplete` 与 `rx_cleanup_result=completed`，原因待查。该 JSONL 没有进程退出码字段。未读取运行目录中的配置正文，未启动设备、BM 或音频，也未改用户配置；alpha.11 源码保持不变。

官方 `HRI_UART.dll` 的本轮静态查询补充了来话回调输入进入 PC 侧字段/状态处理的证据：`FUN_1001b190`（`ev_1661a89f0094fc4f67961e11cffb463af5f8a11d5e8ddd7114c1066cafdea137`）将输入传给 `FUN_10013e60`（`ev_f163cab598682a7d4398cebf41abf88e4fa1ffa34addf0175b4dbac405ba14b5`），可见 `WM 0x650` 和未解析目标的间接回调。`FUN_10013e10` 校验证据为 `ev_e30a5696922437631fd87255737c0b9bb5fa016d2f1ae6edcfc75390e44a6ed9`；全局对象 xrefs 查询为 `ev_ca1c3c2f44f893e34318f2d779d626726cedf20ad91e4f04f3458fba4487bc52`。本轮查到的函数和回调链没有呈现 PC→LCD 命令构造或 LCD 绘制路径，也不能据此断言整个 DLL 不存在其他输出路径。完整静态分析边界见 [HRI 来话回调与 LCD 写出边界](../research/r114/hri-dll/R114_HRI来话回调与LCD写出边界.md)。

官方 `WIRES_X.EXE` 查询没有产生新的函数证据：`xrefs(0x004e0790)` 导出为 0 条记录，`procedure_callers(0x004e0790)` 在 330000 ms 后返回 `provider_timeout`。既有 R79 `FUN_004e0790`（`ev_61089f387cfdec5258766bf18d61b16af8cbbcb26a6d044f4fc464c9a41abcba`）追到响应字段 `0x0A` 写入连接对象 `+0x12F`；`FUN_004e5580`（`ev_5131b0c70d73a5f6b72c69e23fb4ff735ce3e5d673ac8d5c9bd16a32e39d8ef9`）显示该字段可在条件满足时覆盖 HRI `SetDigiTrcvData` 的 DE 字段，但没有把这些字段映射到 LCD。该 dossier 还列有 DATA 引用 `0x4e24e1` / `FUN_004e1200` 指向 `FUN_004e0790`；这不是直接调用或运行时已派发的证据。当前仍未找到从列表请求/响应到完整 HRI 记录、再到 LCD 区域刷新的闭合路径。详见 [EXE 列表信息发送链与 LCD 缺口](../research/r114/screen-exe/R114_EXE列表信息发送链与LCD缺口.md)。

根会话完成了一次 45,009 ms 被动 `WriteFile` 观察（Evidence `ev_cededd928e87d751af14080fa91e33e270ada3e0788a63c6e42a5cc0760cc2f1`）：134 次调用中有 90 个输入缓冲区以 SOH 开头；白名单识别出 Y 帧 45 条，正文各 100 字节（含 Direct 外层后每帧 109 字节），F/T/V 为 0，未保存 payload。观察器已 detach，清理无错误；随后 session 关闭但 PID 8116 仍运行。该窗口没有由观察器或根会话发起节点/房间连接或来话操作，不能据此判断 LCD 显示能力或其他记录类型。详细证据见 [被动 WriteFile 观察记录](../research/r114/runtime-observer/r114_official_idle_metadata.evidence.json)。用户已选择在现有 DIRECT/HRI 连接的节点或房间继续观察屏幕，目视结果待反馈；当前事实仍是 App 呼号显示正常、FTX-1 LCD 两个内容区空白。

## R113 起点（2026-10-29）

用户确认 alpha.10 上 FTX-1 收听和鹦鹉回放正常。这项确认只涉及听音与鹦鹉路径；FTX-1 LCD 来话呼号显示仍待实物观察，R113 不把软件状态或 Native ACK 记作屏幕验收。当前工作只接入 RadioID 缓存到 Native 的后续来话呼号映射，不修改路由、用户配置、密码路径或音量。

## R113 alpha.11 源码与本机测试版（2026-10-29）

Native/UI 实现已由作者冻结；独立代码审查未发现 P1/P2 问题，并按审查意见修正了 `lcd_source_identity` 的通话代次说明。呼号字段已实际接入后续来话的现有 mode 4 T90 起始记录；真实 LCD 绘制仍待本轮用户目视测试。活动通话内的映射更新只影响后续通话，不发送第二条 T，也不热写活动记录。

alpha.11 已从干净源码提交 `b05c3a65cb725d75364e4e8189e13f1257707369` 构建，40 项 Native 离线测试全部通过（新增 `radio_identity_cache_test` 位于 `hri_lcd_identity_candidate_test` 之后），编译警告/错误均为 0。构建目录为 `build/_work/wirex-bridge-b05c3a6-20261029-132957`，完整日志为 `build/_work/R113-alpha11-clean-build-b05c3a6.log`。alpha.11 本机包位于 `build/releases/v0.1.0-alpha.11`，独立包审通过后 `package_status=root_audit_passed`；最终 manifest SHA-256 为 `93298af7365b1ab2da4b39ce0945fa4f739bc3c09cfe6386ce9d409281bd6e72`。Windows PowerShell 5.1 包启动链、针对包内 EXE 的 `test-control` 和真实 WPF→Native `test-ui-control-v2` 均通过。协议诊断确认 BM、HRI、串口及音频没有启动；未连接真实设备或网络。发行器离线合成检查为 package 486、publisher 101、downloader 1620 项断言通过，它们没有生成其他发行包或启动 EXE。alpha11 personal overlay 指向原 canonical 配置目录；canonical `bridge-directory.txt` 已切换到 alpha11，旧指针原始字节备份 SHA-256 为 `9793193b85f25bf11412b335839f028ee7578f87f31baefba847fe1409b7cb2c`。三项连接/音量/密码路径文件的哈希保持不变，未读密码正文，也未重建 RadioID cache。详细哈希与每项证据见 [R113 总交接](docs/R113_总交接.md)。

alpha.11 profile 将 alpha10 的身份查询与 UI 精简文档替换为两份 R113 接线说明，保留未变的 R112 网络音频指标说明；唯一启动入口仍是包根目录 `start-wirex-bridge.cmd`。通用包排除 RadioID 缓存、频道收藏、连接/音量配置、密码和密码路径。独立包审通过后，本机包增加一份不在 manifest 中的 `private/user-config-directory.txt`，目录共有34个文件。alpha10 包已保存在可恢复路径 `private/build-retired/R113/build/releases/v0.1.0-alpha.10`，移动前后文件哈希相同；恢复核对方法见 [R113 总交接](docs/R113_总交接.md)。没有创建 ZIP、Git tag 或 GitHub Release。呼号字段已接入现有来话起始记录；FTX-1 LCD 的真实绘制待本轮用户目视测试。

下一步仅在既有 DIRECT/WIRES-X HRI 与旧 Bridge 用户环境中观察已缓存呼号来话的真实 LCD；根会话确认当前五个 fresh 缓存可预置，ID `460997` 没有呼号，按现有 TG91 来话观察呼号显示，不用鹦鹉路径验证。未命中缓存时程序发送数字 ID 标签；屏幕实际显示待用户观察。另核对后续已解析映射供下一通来话使用及通话结束后的屏幕变化。不新增设备、不改变 RF/数字模式；Native `sent` 状态只说明完整写出，电台实际显示待用户观察。

## R112-A alpha10 集成状态（2026-10-29）

alpha10 由干净源码提交 e234a55aeff6fe2cff1985ef47fc4d94378ab474 构建。构建目录为 build/_work/wirex-bridge-e234a55-20261029-061534，clean full39 的构建日志为 build/_work/R112-A-alpha10-clean-full39-e234a55-build.log，日志 SHA-256 为 797da23c0672d0b0ef03f6bad80ba09cacbe547cc6953f00fa2b00ff2e1db930。39 项离线测试通过，编译警告和错误均为 0；EXE SHA-256 为 ffe5cda0f530595f5007ac54b2f0a3e27dfd8e1ca03c903ee328130dcb684a3d。

本机测试包在 build/releases/v0.1.0-alpha.10，共 34 个文件：32 条 manifest 资产记录、manifest.json 和 manifest 外的个人 user-config-directory.txt。根审已将 package_status 更新为 root_audit_passed；manifest SHA-256 为 2774f3a956e6c4bdf1dd639be41a6ffd1c1935d8a342767807ccc58971daf8c1。用户配置指针现指向 alpha10，切换前备份为 private/config-backups/R112/bridge-directory.before-alpha10.txt，SHA-256 为 e31e4a40179313bd395e4c1bcb72c1d7e5778699ae5b2f2772e52b6c35b40797。

Windows PowerShell 5.1 包启动检查通过；唯一 ASCII CMD 在含中文和空格的路径下完成 PrepareOnly 和 WPF → Supervisor → Native RoutingDiagnosticAutoTest 路径检查，失败路径退出码为 2，fake-timeout 退出后没有残留。Native test-control 的 ready、hello、status、shutdown 检查也以退出码 0 结束。这些隔离检查没有启动真实 BM、HRI、COM 或音频设备。本轮没有进行 alpha10 硬件验收，也没有查询真实 RadioID 或 BrandMeister、连接电台、触发 PTT/RF。

本机 canonical 配置位于 private/user-config，顶层有 17 个文件，递归共 33 个文件。三份受保护配置在切换前后哈希一致；密码文件正文未读取。RadioID 缓存保持原样，频道收藏文件原先不存在，本轮没有创建替代配置。包外 user-config-directory.txt 指向该 canonical 目录。详细验收、静态分析边界和本机归档清单见 [R112-A 集成总交接](docs/R112_总交接.md)。

根批准的 cleanup-plan-alpha10-final.json 共 11 项；614 个文件、116903217 字节已镜像移动到 private/build-retired/R112/build，逐项树哈希与计划一致，没有永久删除。移动日志 SHA-256 为 e3e9f8620bfe6b607322a571a75e36b821e83216e37b11a78c98fd44918eb018。build 只保留 e234 构建、对应日志和 alpha10 包。先前 d413 的未通过发行包仍保存在独立 rejected 目录。

alpha9 闪退日志没有可核对的异常文本，因此没有确认其根因。d413 包级检查发现两处问题：helper 硬编码 alpha9；Windows PowerShell 5.1 下单条 observed_sources 解包后的 .Count 为 null，诊断卡片没有生成。e234 将 observed_sources 始终保持为数组，并用 Tag.Action 定位实际按钮；基于 e234 的测试包通过包级 PS5.1 检查。未创建 ZIP、Git tag 或 GitHub Release。本文、R112 总交接和 alpha10 发布说明的提交晚于 e234 构建，三者均不在包内 manifest 映射中。

## R111 alpha.9 集成当前状态（2026-10-29）


本轮从 `main` / `d2c098452247f26fbe8a0d23d84b5c1f415ce747` 开始。RadioIdentity、UI/发布集成和文案修正分别经 `222f71d`、`e7ec9a0`、`c4597e9` 提交；最终交接文档提交 `15e60753f201d92937d5ca3ccaf3d5ee0d29c313`。这些提交已普通推送到 `origin/main`，本机 `main` 与远端均为 `15e60753`，源码工作树干净。clean full39、alpha.9 通用包和唯一 CMD 包级检查均已通过，alpha.9 是当前验收包。详细证据见 [R111 alpha.9 集成总交接](docs/R111_总交接.md) 与 [alpha.9 构建和交付审计](docs/R111_alpha9_最终交付审计.md)。

R111 UI 实施者负责的主窗口、设置页、`bridge-ui.ps1`、目标/状态/渲染测试和 `docs/R111_UI与音量.md` 已冻结。PS5.1/PS7 目标测试、状态测试、路由动作、路由诊断和生命周期测试通过；1280×900、1024×728 RenderOnly 结果已查看，1024 音量摘要无裁切，截图在 `build/_work/ui-render-r111-final`。路由诊断实际启动隔离 Native 诊断进程并用内存 sink；它没有连接 BM、COM、电台音频或射频。BM 身份模块已将网络流读取改为共享 deadline 下的 `ReadAsync`，PS7 与 Windows PowerShell 5.1 最新离线测试各通过 37 项断言。根会话另用 PS5.1 对公开 RadioID SourceID 做了一次真实 HTTPS 单 ID 查询，返回 HTTP 200 且 ID/呼号匹配；未写缓存，也未输出用户个人资料。该查询检查了 HTTP 响应解析和 ID 匹配；没有访问 BM、电台或音频链路。模块仅由用户明确点击后查询单个 DMR ID；缓存写到 canonical `UserConfigDirectory/radio-identity-cache.json`。用户频道收藏在 `UserConfigDirectory/channel-favorites.json`，其中 `static` 只用于本机分类，程序没有查询或修改服务器订阅。缓存、收藏、`test-radio-identity.ps1` 和 `test-radio-identity-http-server.ps1` 都不能进入通用发行包。

alpha.9 profile 保留唯一 `start-wirex-bridge.cmd` 调用链，增加 RadioIdentity 运行模块和三份 R111 说明；个人 cache、favorites、配置与密码不在通用包。package/publisher/downloader 离线测试分别通过 403、83、1304 项。clean full39 通过 39/39 项；正式包含32条manifest资产记录，root审核状态为 `root_audit_passed`，包级PS5.1启动检查通过。根已复跑 helper，Native `test-control` 的 schema 2 hello/status/shutdown 也通过；这些是隔离诊断，没有连接 BM、真实 COM、电台音频或 RF。

alpha.8 TG91 听感正常但略小；该次会话启动记录带有效增益 1.000x、clipped samples 为 0。canonical `audio-settings.json` 在该会话启动约61秒后才保存为5.959x，因此这次播放没有使用后保存的值；alpha.9 的设置提示修改后重连生效。R111 保持机身 BUSY/TX LED 与串口行为不变。多路由排列不形成优先级，当前媒体 owner 忙时新流不抢断也不排队补播。TS 按路由保存；CC 仅用于 DMR 发射编码/上报，接收不按 CC 过滤。RadioID 只在用户显式操作时查询单个 ID。FTX-1 LCD 实际显示仍未知；C4FM RF 双向 codec/serializer 尚未接入运行链，尚未完成实现。未连接真实 COM、音频或 BM，未触发 PTT 或 RF。

本机 alpha.9 包的 `private/user-config-directory.txt` 指向 canonical `private/user-config`；canonical `bridge-directory.txt` 已切换到 alpha.9。切换前版本指针原样备份在 `private/config-backups/R111/bridge-directory.before-alpha9.txt`，SHA-256 为 `93a4d757d768b2c6c85cfe807f5ade3c74d5c73cd66b53c674d70ace0e48d4e5`。连接 profile、音量设置和密码路径文件的内容未读取或修改；三文件哈希在归档前后保持一致。获批的 retire plan `a27acd1b1b4bf4b5e7e9eabdb6a2a4288b3799ecb27d03d619a13fc9de17d522` 已用 `Move-Item` 将7项、264个文件和72个目录移至 `private/build-retired/R111/build` 镜像；journal 有16条逐行JSON记录，SHA-256 为 `b64b7f7c80c43729d385e91b863a718c3d6eab29c679327ea5021710365c2d48`。build 现在仅保留 alpha.9、15e6075 clean build 和构建日志，没有永久删除。通用包 README 对 C4FM RF 仅写未经硬件验证，没有明确指出 codec/serializer 还未接入；本机仓库交接已明确该实现缺口，后续若更新通用 README 需重新审查并重建包。

## R110 alpha.8 当前交接（2026-10-29）

R110 从 `main` / `cf9775f47812d2b25bc155156803ad8b2fb7ea22` 开始。Windows PowerShell 5.1 `Parser.ParseFile` 在实际 alpha.7 包的 `start-merged-test.ps1` 复现 5 个错误：无 BOM 的 UTF-8 中文消息被按 ANSI 代码页误读，随后报告字符串和括号错误。源码 `tools/start-merged-test-alpha7.ps1` 已补 UTF-8 BOM，正文未改；alpha.7 已发包保持原样。

alpha.8 唯一启动命令 `start-wirex-bridge.cmd` 和同一 Start/隔离诊断 dot-source 链已通过 package helper。源码提交 `23680b33a6280224baf61458a5909ef68331cf8f` 的 clean full39 构建通过全部39项离线测试，warning/error为0；build `build/_work/wirex-bridge-23680b3-20261028-185941`，日志 `build/_work/r110-23680b3-clean-build.log`，EXE SHA-256 `2b31cbd62f5368dabecde23680fdce837aa2e451fed6a1feb202b3c0bde2211f`。候选包 `build/releases/v0.1.0-alpha.8` 通用内容29个文件，manifest列28项，唯一根CMD，logs为空；根审计后的 manifest SHA-256 `3c32141814b960b46be70d3aa6f33455ab04049aa056dd0012d4f6d5490f828f`，状态 `root_audit_passed`。本机包另有 manifest 外的个人 `private/user-config-directory.txt`，仅指向 `private/user-config` canonical 配置目录。

Windows PowerShell 5.1 包级 helper 与 root 独立复跑均 exit 0：5 个包内 PowerShell 文件解析成功；唯一 ASCII CMD 在中文空格路径下运行 `PrepareOnly` 与隔离 `RoutingDiagnosticAutoTest`；无参数失败提示与 exit 2、fake-sleep 超时退出也通过。自动用例通过重定向 stdin，不模拟人工按键或关窗。root 另以 Native test-control 诊断验证 schema 2 hello/status/shutdown exit 0，BM、HRI、串口和音频都未启动。根审计后已将 manifest 状态改为 `root_audit_passed`，包内个人配置指针和 canonical `bridge-directory.txt` 均已指向 alpha.8，切换前 pointer 备份保存在 `private/config-backups/R110`。没有创建 ZIP 或 GitHub Release。

R110 的路由初始化诊断异常会写入隔离结果并失败退出；此前 modal `ShowDialog()` 异常曾被 UI timer 仅记状态，后续 ACK 可能使旧 runner 错误报告 passed。新的 Start 与诊断入口走相同 WPF 脚本作用域。

canonical 配置三文件已在 `private/config-backups/R110` 做回滚备份，并按用户最近 alpha.7 的完整 RX/TX profile 更新；`bridge-directory.txt` 已切换 alpha.8，切换前备份与原文件 SHA 相同。密码文件内容未读取或复制。root 批准的 retire plan SHA-256 `504ca460a26b495f0fcafb8a031c0e2f482e1eb7bf0532e34b26d944f7e586be` 已执行：306 项、20,900 文件、2,900,948,337 字节通过 `Move-Item` 移至 `private/build-retired/R110/build`。614 条移动事件逐行解析通过，含 1 条开始记录、306 对开始/完成记录、1 条完成汇总、0 条失败；旧多行记录副本保存在 `private/build-history/R110/retire-move-journal.pretty-json-stream.txt`。没有永久删除。build 现在只保留 alpha.8 package、23680b3 clean build 和构建 log。

静态研究没有修复或解释 FTX-1 机身 BUSY/TX LED；官方程序的实际调用与 LED 变化还需受控运行观察。UI `lcd_source_identity.display` 仍为 `unknown`，HRI T 记录候选不证明实际电台显示。C4FM RF 双向 codec/serializer 尚未接入运行链。R110 没有连接 COM、音频、BrandMeister，没有做 PTT、LED、LCD 或 RF 硬件验收。详细状态见 [R110 启动故障修复与 alpha.8 准备](docs/R110_启动故障修复与alpha8准备.md)。

## R105 多目标改造状态（2026-10-27）

R105 核心契约与纯内存路由模型已完成；12 个独立模型测试函数由本会话及 root 独立运行通过。BM API 静态请求 mock 的一次运行通过 99 条断言，Windows PowerShell 5.1 及 root 独立复跑均 exit 0。独立 HTML 交互原型模拟检查 40/40 通过、`failed=0`；root 检查了 RX 等待 T0 清理截图，UI agent 对 router 的只读交叉审查没有阻断项。这些结果不表示 WPF/Native 已运行。R105 尚未接入 Native pipeline、IPC、WPF 或 BM live transport，也没有真实设备/Quick call/RF 验证。实施顺序和复跑命令见[R105 执行交接与实施顺序](docs/R105_执行交接与实施顺序.md)。本轮工作以 `main` / `71a45c7` 为提交基点，当前发布继续保持 `v0.1.0-alpha.4`。

## 当前版本与本机入口

- 当前私有预发布 [v0.1.0-alpha.4](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.4) 已发布，Release ID `425043325`；annotated tag object `28fb07f617366c678f74c4e588d5a576aa240ab9` 指向 source `6b9e9be28565250b3565bac2dee9911b9c6b1337`。Release 有 29 个 asset；本机包 `build/releases/v0.1.0-alpha.4` 有 28 个文件，manifest 列 27 项，manifest SHA-256 `60699cd05e8d250a1b202eb6c1247181df103f3ae50560f2818bcf66797d6c37`。clean build 通过 35 项 C++ 测试且 warning/error 为 0；普通下载 `build/_work/alpha4-published-download-6b9e9be` 的 28 个文件与本机包逐项哈希匹配。root 与 Native 子会话均完成独立包审查。
- alpha.3 source 的正式 clean build 通过 35 项 C++ 测试，warning/error 为 0；构建目录 `build/_work/wirex-bridge-e93c340-20261026-194306`，日志 `build/_work/alpha3-e93c340-build.log`，EXE SHA-256 `5ea91a4cc59126db70a87f509d4c60df84f991d933e6af3d8ca4bdcc9eed5dcc`。另有 8 组 Windows PowerShell 5.1 检查、常规与 1024×728 WPF RenderOnly、COM999 Native JSON→当前 UI status/run-envelope validator smoke 全部通过；详见本节后续验收摘要。
- alpha.3 已把 Native `lcd_source_identity` 状态接入 WPF：界面显示已准备的 HRI Source ID 标签，同时把 FTX-1 实际屏幕保持为“未知”。界面日志保留最多 12 条事件；旧 UI run 目录只在终态记录通过状态校验且所属进程已退出后纳入清理，对可确认已结束的目录按最近 10 个、总量 50 MiB 保留，活跃或状态未知的目录保留。LCD 实机显示仍待最终合并联测，C4FM RF ingress/egress 尚未实现。
- 本机 `start-my-bridge.cmd` 已切换到 alpha.4。`private/user-config` 中连接参数与音量设置继续跨版本复用；版本指针备份保存在同目录，密码仍引用原有本机路径，本次未读取或复制密码正文。
- R103 静态研究已证明官方 HRI T 记录队列项经 EXE `WM 0x618` 数据流到达 `WriteFile` 的指针/长度参数；factory 额外字节布局、实际设备接收和显示、数字 RF serializer/codec 仍待确认。自包含摘要见 [R103 HRI 记录到 WriteFile 路径摘要](docs/R103_HRI记录到WriteFile路径摘要.md)。
- alpha.4 已加入独立 BM 收听目标与发射目标、只收模式、BM China 4602 预设及对应 UI/配置迁移。alpha.3 私有运行日志记录了 1,881 个 BM DMRD 数据报，其中 1,809 个按目的 ID/呼叫类型过滤；日志曾记录 TG91 组呼头，例如 `src=3175445,dst=91,TS2,G`，但该头不是日志最后一帧。因此 alpha.3 虽显示 TG91 来话，但本机按鹦鹉发射目标过滤器丢弃帧。分析、MMDVM 网络/射频方向和 Pi-Star 4602 主机资料见 [R104 MMDVM 收发目标与4602研究](docs/R104_MMDVM收发目标与4602研究.md)。
- 新 profile 增加 `receive.destination_id/slot/call_kind` 与 `transmit_enabled`；旧 profile 缺少 `receive` 时，组呼沿用发射组呼目标，私呼默认收本机 Source ID。TG91 收听预设禁止 BM 上行；若要同时听 TG91 并用鹦鹉私呼上行，可在设置中分别选 `91/G/TS2` 与 `460997/P/TS2` 并打开发射许可。启用私呼上行时，Native 另外允许来自当前私呼发射目标、发往本机 Source ID、类型与时隙相符的回音；只收模式不启用这条回音规则。UI/config/启动参数交接见 [R104 UI 收发目标与服务预设](docs/R104_UI收发目标与服务器预设.md)。
- alpha.4 已发布为私有 prerelease。源码提交 `6b9e9be28565250b3565bac2dee9911b9c6b1337` 的 provenance 记录 `source_tree_clean=true`、`compile_only=false`、`result=passed`，35/35 项测试通过，EXE SHA-256 `25f3521aabf6a380aca713447f7d34dc308c163b036a078289f8c6c449fd4fcf`；构建目录 `build/_work/wirex-bridge-6b9e9be-20261027-043833`，日志 `build/_work/alpha4-6b9e9be-build.log`。离线发布脚本检查 package-release 144 项、download-release 533 项、publish-release 52 项通过；UI/config/target/status/render 检查通过。包审查确认只包含批准的 `private/device-y.bin`，不包含个人 user-config 或密码。
- 鹦鹉回音期间电台似乎继续触发 PTT 的现象仍需 alpha.4 实机观察，本工作没有声称已修复。本轮未打开串口、音频流或 RF；该验收保留到最终合并验证。FTX-1 LCD 显示仍未知，C4FM RF→BM/BM→RF 也未实现。R104 source/UI 验收已由根会话 sign-off；Native、UI/config 和 alpha.4 发布资料分别记录在 `624650e4dbbc33b354a6539f6038401813612291`、`705d8d038863bfe42bd9bc3c9056596637e3139e`、`6b9e9be28565250b3565bac2dee9911b9c6b1337`。草稿与普通下载均通过 28 个文件的哈希校验，Release 有 29 个 asset。下一步按[合并联测清单](docs/合并联测清单.md)完成人工设备验证。
- R98 clean-build Native 源码提交为 `fef55067164e1ac12b410b5199db68546d78bc76`，正式构建有 35 项 C++ 测试全部通过，构建与 provenance 位于 `build/_work/wirex-bridge-fef5506-20261026-183908`，日志 `build/_work/r98-fef5506-build.log`，EXE SHA-256 `a95051d4c2fd10978310904d68d1a0bd5552e11b7444c2a4ef4ad91d7ebd6b6c`，compiler/linker warning/error 为 0。R100 源码提交 `ddeee3105002e5f923c9f727f8ad2811f61a829a` 已完成正式 clean build，35 项 C++ 测试全部通过；具体构建与状态 smoke 见下文。alpha.2 tag 和发布资产保持原样。
- R95–R99 静态研究汇总见[HRI 数字记录与调制研究进度](docs/HRI数字记录与调制研究进度.md)。R99 已静态闭合 `ToHriFrameAdd` 与 `ToHriAmbeGet` 的队列地址：两者使用 `0x1016830c`；`ToAnaAmbeGet` 使用独立的 `0x10168324` 队列。HRI 记录经所选 serializer 写入电台及 FTX-1 LCD 的显示和清屏事务仍待验证。R96 找到资源1028的 Modulation ComboBox 候选和未闭合的虚函数回调；R93 操作中选 DIGITAL 后未点击 Apply/OK，主会话随后选择 Cancel。R97 修正 parser 输入指针基址，R 分支只闭合到有条件的 `ToNetAmbeAdd` 字符串队列和 RAW 封装，语音 payload 格式仍未知。`hri_call_header` / `hri_t_record` 继续作为纯内存构造器，FTX-1 LCD 实际显示尚未观察。
- R100 核心身份处理：每通已接受 BM 来话自动把数字 Source ID 格式化为 `ID` 加十进制数字，写入 HRI T3 起始记录的 10 字节 source 字段；状态对象 `lcd_source_identity` 含 `prepared`、`source_id`、`receive_generation`、`label` 和固定为 `unknown` 的 `display`。DMR ID 标签不作为 WIRES-X 呼号，功能不增加 RF 路由。R100 提交本身未接入 WPF；R101 后续接入并显示 Native 报告的标签状态，仍将实际 FTX-1 屏幕结果标为未知。详见[BM 来话身份显示](docs/BM来话身份显示.md)。
- R100 clean build 与 COM999 状态 smoke：构建目录 `build/_work/wirex-bridge-ddeee31-20261026-191001`，日志 `build/_work/r100-ddeee31-build.log`，EXE SHA-256 `0060826d02433a6fe90c7d57f631e6991cec7f07eb6d4b2a7cadf28a8ebe9649`；35 项测试全部通过，compiler/linker warning/error 为 0。smoke 目录 `build/_work/r100-lcd-source-identity-smoke-1f558b50b3fa4d7591f4ae5045cabe06` 中的两条真实状态 JSON 分别记录 `preflight_passed` 和预期的 `serial_open_or_configure_failed`。两条记录都带 `lcd_source_identity`，字段为 `prepared=false`、`source_id=0`、`receive_generation=0`、`label=""`、`display="unknown"`，没有旧版 `lcd_experiment` 字段；HRI 串口与 WaveIn/WaveOut 均关闭，TX/RX/control 计数为 0。该 smoke 只验证无来话时的启动状态与 COM999 失败路径，不验证实际来话映射或 LCD 显示。测试使用 `127.0.0.1` loopback 和临时合成密码文件；COM999 测试前确认不存在，音频仅查询格式，未打开音频流或串口，未发送 UDP；合成文件已删除，测试进程已退出。完整结果见该目录的 `result.txt` 与 `native-status.jsonl`。
- R98 COM999 状态 smoke 属于前一版带开关的代码历史：当时关闭与开启实验开关的运行各输出两条由 WPF 严格校验器接受的 native 状态记录；两次均在串口打开失败处结束，音频流保持关闭，UDP TX/RX/control 计数为零。旧 `lcd_experiment` 对象按两种开关值输出，屏幕字段保持 `unknown`，重复开关在状态文件和设备启动前以退出码2拒绝。COM999 不存在，临时合成密码文件已删除，进程已退出。结果目录为 `build/_work/r98-lcd-status-smoke-d9188b3948784828828de307ab3a4e69`；这些记录没有覆盖 R100 新状态或默认每通来话处理。
- R94 状态JSON基于通过BM过滤后的 pipeline Snapshot 显示当前 Source ID、目标、呼叫类型、时隙、CC、LC验证情况和接收阶段；没有呼号资料时显示 DMR ID。BM EOT 到达后当前话者立即清除，本机尾音排空另行显示。取消、网络丢失、状态过期、native进程退出和新run均清理旧活动话者；左侧“最近来话”字段保留原有最近解码头语义。Windows PowerShell 5.1 状态测试和 WPF 离线渲染通过，渲染目录为 `build/_work/ui-render-5add0d5b83db4079b2bb6164551a8cd8`。COM999 启动失败集成 smoke 已通过：native 写出 `preflight_passed` 与 `serial_open_or_configure_failed` 两条状态记录，UI 严格校验器均接受；native以预期退出码2结束，11个当前来话字段均为zero/idle；不存在的 COM999 前后均未出现，音频端点只查询格式，串口未打开，UDP TX/RX/control计数均为0，音频流未打开，临时合成密码文件已删除。完整摘要及状态文件位于 `build/_work/r94-status-smoke-6807b5f2ffbf4098b5098e8d7ddaadf9`。
- R94 只增加 WPF/BM 当前来话状态，不是 FTX-1 LCD 显示功能；LCD协议、来话呼号映射和实际屏幕更新仍未完成。新增 AMBE 参数映射和 YSF 转换缓冲尚未接入运行媒体链；仍需确认 HRI 语音记录的格式及 RF 路由。
- HRI `TRCVTYPE` 配置路径静态研究见[报告](docs/HRI_TRCVTYPE配置路径.md)；[R91 双实例只读观察](docs/R91双实例只读观察.md)已完成一次约10秒采样，共57个样本、0次字段变化，随后会话查询确认已不再附加且 `cleanup_error` 为空。主会话已正常关闭本次启动的官方程序并确认进程退出。表项1在本次窗口显示 `TRCVTYPE=0`、`OPE_MODE=0` 并处于 OFF/未运行状态；实例与 `DGRP_DATA`、`DGRP_VOICE` 的对应关系及 LCD 路径仍待证据确认。
- R93 的设置窗口中，Modulation 显示 `RX:FM - TX:FM`，下拉项为 `FM` 和 `DIGITAL`；点击 DIGITAL 和键盘 Down/Return 后显示值仍为 FM。主会话没有点 Apply/OK，随后 Cancel，主窗口仍显示 ANALOG，因此未确认 Digital 设置已生效或保存。取消后 10 秒只读快照记录 54 个样本、0 次字段变化；HRI 表项 0 `+0x50=1/+0x58=0`，表项 1 `+0x50=0` 且队列计数和 header 长度为 0。报告见 [R93 调制选项观察](docs/R93调制选项与取消后状态观察.md)。这次结果没有判定电台拒绝 Digital，也没有把 HRI 字段映射到 Node Mode、LCD 或 RF 路由。
- 私有预发布 [v0.1.0-alpha.2](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.2) 已于 2026-10-26 05:26:14（中国标准时间）发布，Release ID `423670400`。源码 tag `v0.1.0-alpha.2` 指向 `a965df0ccd6649a972a0be6242a6ba2a1bd83dff`，annotated tag object 为 `848ee23ceb96adbb352e8106b2925c15eace2652`。
- 该源码的正式 clean build 通过 28 项 C++ 测试，compiler/linker warning/error 为 0。构建目录 `build/_work/wirex-bridge-a965df0-20261025-170232`，日志 `build/_work/alpha2-a965df0-clean-build.log`，EXE SHA-256 `b9c7541a453345bc1bc18539e8ba7964a927a3fdd7c2581e2952f556fb740205`。
- 本机目录 `build/releases/v0.1.0-alpha.2` 有 27 个文件：manifest 列 26 项并包含 `manifest.json`；GitHub Release 有 28 个独立 asset。manifest SHA-256 为 `634cc13cd3280deb3d3718ae3cdec0ecf1573a009f721d0aa363018a76b19e48`。草稿与普通 published 下载均通过核对；普通下载重建 27 个文件，字节与本机目录一致，临时目录和下载 helper 进程均已清理。
- 8 组 PowerShell 检查及 WPF 离线渲染均通过。另以不存在的 COM999 端口运行启动失败路径，该路径写入磁盘的 native 状态记录；loopback 测试只查询音频格式，没有打开真实串口、发送 UDP 或启动音频流。UI 状态校验通过；证据目录为 `build/_work/ui-status-integration-a965df0-3dd6a47764524de1a7fd3dc7dd395af8`。alpha.2 的设备实机联测仍待集中执行。
- alpha.2 发布后，`main` 增加了纯 AMBE+2 2450 参数映射与分组缓冲切片，源码提交为 `a5c5a8770305f9f6899895301cb5cee92c830267`。该提交 clean build 成功，35 项离线测试通过；构建来源记录在 `build/_work/wirex-bridge-a5c5a87-20261026-071313/build-provenance.json`，EXE SHA-256 为 `B4C3BC4E9621A4B975AFF26B39220361A883966FEF1FBAF0169C3B5D7178FACD`。root 按 provenance 列表独立重跑 35 项也全部通过，完整测试输出为 `build/_work/a5c5a87-root-tests.log`。新模块目前只用于独立离线测试，没有接入默认运行链；HRI 串口与 13 字节 YSF VCH 的对应格式及真实设备互通仍待确认。该提交没有更改 alpha.2 tag、Release 资产或两个已冻结候选目录。
- 本机 `start-my-bridge.cmd` 已选择 alpha.3 WPF 界面。本机 profile 和音量设置仍在 Git 忽略目录，密码仅使用原有本机路径。alpha.1 一通 DIRECT 用户回声确认保留为历史验收；alpha.3 的设备启停、LCD 实际显示、长时待机和断网恢复留在最终合并联测。R103 仍是静态 `WriteFile` 路径证据；FTX-1 C4FM RF 收发功能尚未实现。阶段细节见[下一阶段推进计划](docs/下一阶段推进计划.md)。

## v0.1.0-alpha.1 私有预发布状态

- 私有 GitHub 预发布 [v0.1.0-alpha.1](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.1) 已发布，Release ID `423365682`，于 2026-10-25 19:49:48（中国标准时间）发布；源码 tag 指向 `312e7142a419566c47a335fb83a33c756aaf69f3`。
- 该源码的正式 clean build 通过 27 项离线测试，warning/error 均为 0。构建目录 `build/_work/wirex-bridge-312e714-20261025-113013`，日志 `build/_work/release-312e714-build.log`，EXE SHA-256 `adbec34fde41565f437283fde3a7a46f28f3615dc1575d90086158e08a4fb1aa`。
- 本机绿色目录 `build/releases/v0.1.0-alpha.1` 清单列出的 16 个文件，加上 manifest.json，共 17 个文件；远端 Release 有 18 个独立 asset，额外包含单独发布的 `download-release.ps1`。不生成 ZIP，包中没有密码、连接 profile、音量设置或运行日志。manifest SHA-256：`21d2e617f7761b6cc28a467432fb4c9d50d7c5ecafe2c1524afb8f9562fab9f5`。
- 根会话确认远端 18 个资产均已上传。下载器分别通过草稿验收和普通 published 下载验收；后者重建 17 个文件，长度、SHA-256 与本机绿色目录相同。
- 发布操作使用的 `main` 提交为 `86e9d105e3095b18b1363b550d9dc6cda8e49552`，相对发布 tag 只新增 `tools/publish-release.ps1` 与其离线测试的发布器修复；后续交接文档提交不改变发布 tag 或资产，二进制和清单仍对应 tag `312e714...`。
- `005c5e8` DIRECT Echo 与 `ab3c5fa` TG91 收听保留为前序版本证据。用户现已在 `v0.1.0-alpha.1` 上完成一通 DIRECT 手咪→BM 鹦鹉→FTX-1 扬声器回声与退出验收，确认本次功能符合需求；状态日志有 32 条记录、TX 63、RX 222、一次呼叫开始/结束、一次 PTT 开始/结束、削顶样本 0，末状态 `stopped`。日志路径为 `build/releases/v0.1.0-alpha.1/logs/bm-bridge-20261025-145740-974-ef3755d4.jsonl`。这次只确认一通 DIRECT 和本次退出；长时间待机、断网恢复与独立音量调参仍待后续验收。LCD 当前话者、运行期间 RF 路由、BM 到 RF 发射与可连接图形 UI 不包含在 alpha.1 中。
- 发布说明、包内操作步骤和验收范围见[发布说明](docs/releases/v0.1.0-alpha.1.md)、[包内 README 源](docs/releases/v0.1.0-alpha.1-package-README.md)和[验收清单](docs/首个Release验收.md)。
> **alpha.1 历史验收：** 用户确认 alpha.1 上一通 DIRECT 自动 PTT 私呼鹦鹉回声清晰、退出符合需求；32 条运行记录末状态为 `stopped`。这项单通验收不替代 alpha.2 的新版本设备联测。

本仓库是 native 程序和 UI 的 Git 根目录。本文和 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md) 为接续实施或审查的自包含入口；不要依赖仓库外的 research 目录。较早的 `app/docs` 文档仍有指向 `../../research/...` 的链接，只克隆本仓库时这些链接无法解析。

## 当前 BM + FTX-1 候选

当前交付版本为私有 GitHub 预发布 [`v0.1.0-alpha.3`](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.3)，source `e93c340f525daf53e4abba0ed9431398a9bf969e`；35 项 C++ 测试、8 组 PS5.1 检查、WPF 离线渲染、COM999 status/UI 校验与发布下载审计均通过。alpha.3 的最终设备 HIL 尚待集中执行；alpha.1 的一通 DIRECT 用户确认与 alpha.2 历史包均保留为对应版本证据。下方其余旧提交、原型和研究记录按各自版本保留。

步骤 1–4 的 `17f3433`、`aec0471` 和 `2183cef` 构建、测试与便携包结果均是各自版本的历史验证；`2183cef` 的干净构建有 25 项测试通过。之后两次 network-only 私呼回声确认 BM 返回 TS2：第一次因旧 TS1 filter 被全部过滤，三个 preset 随后调整为 TS2；第二次由 RX-only pipeline 识别出完整呼叫事件。源码提交 `1c8c6fd` 和 `005c5e8` 的正式 clean build 均通过 26 项离线测试；`005c5e8` 便携包审计通过，用户确认该版本一通 DIRECT 手咪→BM 鹦鹉→电台扬声器回声清晰。用户也确认 `ab3c5fa` 的 TG91 实机收听正常。长时间待机、断网恢复、46001 订阅收听、DIRECT RF 路由与 C4FM RF 节点仍待集中验收。alpha.2 已交付可连接桌面 UI；其真实设备状态和生命周期仍需最终 HIL 验收，当前状态见本文件顶部。

`aec04710e9d5b32f416b3b78c3812615fedd1988` 是上一个已构建的源码提交。根会话从该 clean HEAD 使用 VS 2019 x64 正式 builder 运行全部 25 项离线测试并通过，产物在 `build/_work/wirex-bridge-aec0471-20261024-104627/`。根会话还审计了 `build/bm-radio-bridge-aec0471/`：13 个实际文件（含 manifest 和 excluded 本机凭据），manifest 中 11 个普通文件的长度与 SHA-256 全部匹配；EXE 与 clean build 相同，包内 `--help` 返回 0 并列出当时的中文预设，`--list-audio-json` 返回 0 且 schema version 为 1。凭据未被读取或哈希，日志目录为空。该提交和便携包是旧 profile 版本的历史验证，不含当前 E3 metadata helper、CC1 预设变更或就绪提示。

E3 network-only 对照使用 `BI7KGD`/Gateway ID `461135501`，RPTC 元数据为 RX/TX `438800000`、power `0`、CC `1`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、节点类型 `MMDVM_WIREX_Bridge`、options 空。结果到达 BM `ready`，工具本机发送 `RPTCL` 成功。当前 native 与诊断工具共用轻量元数据 helper，避免 RPTC 配置不一致；helper 不改 Gateway、呼号、密码或调用方色码。`438800000` 是 BM 节点元数据，不会改变 CAT 或 RF。该节点类型表示虚拟 MMDVM 兼容 WIREX 节点，不声明物理 Hat；BM 网页 Firmware/类型文字也不是 FTX-1 固件。E3 还没有经过真实 DMRD Echo、native + HRI/COM/WinMM 或电台端到端验证。

根会话另从当前共享 helper 编译 `build/_work/bm-probe-final-e3-20261024/bm_network_probe.exe` 并运行一次 network-only 诊断：118 ms 内收到配置 ACK、生产 Session 到达 `ready`，实际本机 UDP 发送 9 字节 `RPTCL` 成功，随后 `stopped`、退出码 0。最终 clean build 目录为 `build/_work/wirex-bridge-2183cef-20261024-123605/`，正式构建日志为 `build/_work/bm-ready-2183cef-build.log`。便携候选 `build/bm-radio-bridge-2183cef/` 的根会话审计通过：13 个物理文件含 excluded 凭据；manifest 中 11 项非秘密文件长度/hash 全匹配，EXE 与 clean build 相同，`--help` 完整中文且退出码 0，音频 JSON schema 1、type `audio_devices` 且 WaveIn ID 1 是麦克风，launcher parser 0 个错误；静态依赖仅有 WINMM、bcrypt、WS2_32 和 KERNEL32 系统 DLL。凭据只核实文件存在，未读取或哈希；`logs/` 为空。以上构建和包审计不等于真实语音或硬件联测通过。

## 产品目标与当前里程碑

完整产品目标是让 FTX-1 接入 BrandMeister，并支持两种同等重要、分别验收的真实用途：FTX-1 个人终端（DIRECT；本机手咪上行，网络语音由本机扬声器播放，不因网络下行自动做 RF 发射）和本地 C4FM RF 节点（附近 C4FM 电台经 FTX-1 进入网络，网络语音经 FTX-1 发出）。电脑音频是诊断辅助，不是第三种产品用途。S1-E 是较早的本地双向语音测试里程碑；BM codec、网络和个人终端 native 桥接已通过 26 项离线测试、便携包审计和一通真实 DIRECT 语音闭环验收；长时间运行、断网恢复和其他产品用途仍需分别验证。C4FM RF 节点的设计与实测另行推进。

S1-E native 实现提交为 `732e418bf5b60a99790b00c692601bc95fb1b43c`，随后文档澄清提交为 `df62855c2dd77c5716d3dabffe92211ea6e679b8`。基础会话持续监听，并由操作者按 F/M/C/Q 操作：F 使用固定 WAV，M 先录入最多 8 秒 PC 麦克风内存片段再下行，C 取消当前操作，Q 收尾退出。单一 native 进程独占 HRI COM、WaveIn 和 WaveOut；多轮操作串行进行。主动运行窗口最多 120 秒，首次收尾另有不超过 3 秒的一次性停止/清理预算。S1-E 尚未连接电台实测；完整冷启动、BrandMeister、RF 与 UI 都未在该切片中验证。

实现边界、8 项离线测试、无设备安全失败路径与下一步验收见 [`docs/S1-E本地会话验收.md`](docs/S1-E本地会话验收.md) 和 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md)。从 `app` Git 根目录用 Windows PowerShell 5.1 重复构建并运行测试：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-radio-session.ps1
```

脚本只使用本机已安装的 VS 2019 Build Tools，产物写入 `build\_work`；未提交源码的开发构建目录带 `-dirty`，不能作为交付核心。该段记录 S1-E 原型当时的 clean build 与 8 项离线测试；`build/local-radio-session-732e418` 不是当前发布包，原型当时也没有运行设备。当前可交付版本及桌面入口见本文件顶部。

## S1-E 本地会话原型历史记录

本节记录早期 S1-E 本地会话原型，不是 alpha.2 的启动说明。alpha.2 使用 WPF 桌面入口和 `--ui-pipe`，界面生命周期与真实设备状态验收仍待最终集中联测。

S1-E 原型当时由操作者在可见 PowerShell 控制台运行 `tools/start-local-radio-session.cmd`，确认串口和音频设备后输入 `START`。native 启动后用 F/M/C/Q 键触发固定 WAV、麦克风捕获、取消和退出；该入口不是当前 alpha.2 启动方式。一个 native 会话仍是唯一的 COM 和音频资源 owner。

当时设计的 S1-E stdin 文本命令仅属于该原型；alpha.2 界面不使用这组 F/M/C/Q 文本命令。alpha.2 的界面通过独立 stdin 管道请求 Q/EOF 收尾，并由 Supervisor 管理本次启动的 native 进程。

以下 stdin ASCII 命令属于 S1-E 原型历史，不是 alpha.2 的 UI 管道协议：

```text
1 <run_id> <request_id> send_fixed
1 <run_id> <request_id> capture_mic
1 <run_id> <request_id> cancel_operation
1 <run_id> <request_id> shutdown
```

native 通过 stdout 输出 JSON 协议 v1 事件。事件类型为 `snapshot`、`request_result`、`operation_event`、`operation_result` 和 `session_result`。每条事件带当前 `run_id` 和 native 在本次 run 内递增的 `seq`；关联操作的事件带 `request_id`。字段包含 `status`、`phase`、`hri`、`audio`、`pc_cleanup` 和 `radio_state`。UI 忽略旧 run 或重复、倒退的 seq，并分别处理请求结果、操作进展、操作结果和会话结束。`accepted` 只说明请求已收到，不能显示成操作完成。

本次进程启动、操作完成、停止记录、PC 端 PCM 排空或 Windows 句柄清理成功，都不能证明电台恢复接收、PTT 释放或 RF 停止。`radio_state` 保持 `unknown`。native 启动不自动发起下行播放、PTT 或 RF 操作。

## 退出与数据边界

上方 `cancel_operation`、显式 `shutdown` 和 120 秒运行期限属于 S1-E 原型。alpha.2 UI 通过本次运行的 stdin 管道发送 Q 并关闭输入请求有界收尾；窗口等待由 Supervisor 管理的本次 native 子进程退出。UI 运行时若收尾超时，只处理本次创建的 child/Job，并显示设备收尾状态未知；真实设备关闭过程仍待最终 HIL。

若 T3 尚未尝试，取消不得发送 T0；若 T3 已尝试，错误或取消清理至多尝试一次有界 T0。每个操作结束后恢复监听。固定 WAV、麦克风 PCM、设备私有 fixture 和原始协议数据不得写入日志、报告或 Git。

用户可按本机已授权流程获取、重采或准备需要的 fixture；Git 仓库不保存或推送设备私有 fixture、操作者语音、临时抓包、厂商二进制、凭据或包含原始载荷的报告。未来若需将人工合成 WAV 作为离线测试数据，先审查具体文件，再为准确测试路径增加窄范围的 ignore 例外，不提交操作者录音。

## 现有证据及其范围

仓库包含 DIRECT 帧与流解析、HRI 状态机、下行协调器、WAV 校验、WinMM 输入/输出和离线测试。S1-D/R69 记录一次独立固定 WAV 下行人工试听：用户确认听到清晰报数，播放后声音停止且电台界面恢复；软件报告记录本机清理成功并将 `radio_state` 保留为 `unknown`。alpha.2 另有离线 UI 状态、进程监督和合成 loopback 验证；这些记录不能替代本版本真实设备连接、音量、退出和 RF HIL。

R63 的脱敏结论只支持构造固定 T3/T0 软件候选；R68 的脱敏结论只支持有限的软件状态请求路径。它们没有证明候选记录在电台侧的 PTT 含义、是否已到达 UART、射频行为或电台已恢复。S1-E 当前证据与待做 HIL 项见 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md)。

## Git 与阶段交付

每个阶段使用用户已核实的 GitHub 账户身份 author/committer。推送前检查准确提交范围、所有待提交文件和私有仓库状态；不重写已有历史、不 force-push，也不使用 `git add -A` 把代理工作树中的改动一起暂存。alpha.2 的发布 tag 和资产已冻结；后续文档提交只推进 `main`，不改该 tag 或资产。

阶段文档记录实际执行的离线命令与结果、候选核对、未执行的硬件步骤及剩余风险。alpha.2 的设备 HIL 尚待安排；未执行的验证不能写为通过。外侧 research 树不纳入 Git；本文和阶段验收文档保留接续所需设计与证据摘要，审查不需要原始研究抓包或二进制。
