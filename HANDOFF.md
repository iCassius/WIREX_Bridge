# WIREX Bridge 交接入口

## 当前版本与本机入口

- 最新 `main` 源码提交为 `4ebec0cf2fe16e7a3ad5ead80393dd31ce1371cb`，增加 WPF 当前 BM 来话状态显示；alpha.2 tag 和发布资产保持原样。该提交的正式 clean build 有 35 项 C++ 测试全部通过，构建与 provenance 位于 `build/_work/wirex-bridge-4ebec0c-20261026-124823`，日志 `build/_work/r94-4ebec0c-build.log`，EXE SHA-256 `3f2e39f9cb930e7e047acba46ae8f3262cec976d834f72214e8b174b0043b8ad`，compiler/linker warning/error 为 0。
- R95–R97 静态研究汇总见[HRI 数字记录与调制研究进度](docs/HRI数字记录与调制研究进度.md)：EXE 将 G/H 交给 `ToHriFrameAdd`、E/R 交给 `ToHriAmbeAdd`；HRI 的 G/H handler 与 68B header 有可复核字段偏移，但 `ToHriFrameAdd` 到 Get 队列的同实例链仍待确认，内部缓存清理也没有对应的电台 LCD 清屏事务证据。R96 找到资源1028的 Modulation ComboBox 候选和未闭合的虚函数回调；R93 操作中选 DIGITAL 后未点击 Apply/OK，主会话随后选择 Cancel。R97 修正 parser 输入指针基址，R 分支只闭合到有条件的 `ToNetAmbeAdd` 字符串队列和 RAW 封装，没恢复语音 payload 格式。现有 `hri_call_header` / `hri_t_record` 是纯内存构造器，FTX-1 LCD 实际显示仍未验证。
- R94 状态JSON基于通过BM过滤后的 pipeline Snapshot 显示当前 Source ID、目标、呼叫类型、时隙、CC、LC验证情况和接收阶段；没有呼号资料时显示 DMR ID。BM EOT 到达后当前话者立即清除，本机尾音排空另行显示。取消、网络丢失、状态过期、native进程退出和新run均清理旧活动话者；左侧“最近来话”字段保留原有最近解码头语义。Windows PowerShell 5.1 状态测试和 WPF 离线渲染通过，渲染目录为 `build/_work/ui-render-5add0d5b83db4079b2bb6164551a8cd8`。COM999 启动失败集成 smoke 已通过：native 写出 `preflight_passed` 与 `serial_open_or_configure_failed` 两条状态记录，UI 严格校验器均接受；native以预期退出码2结束，11个当前来话字段均为zero/idle；不存在的 COM999 前后均未出现，音频端点只查询格式，串口未打开，UDP TX/RX/control计数均为0，音频流未打开，临时合成密码文件已删除。完整摘要及状态文件位于 `build/_work/r94-status-smoke-6807b5f2ffbf4098b5098e8d7ddaadf9`。
- R94 只增加 WPF/BM 当前来话状态，不是 FTX-1 LCD 显示功能；LCD协议、来话呼号映射和实际屏幕更新仍未完成。新增 AMBE 参数映射和 YSF 转换缓冲尚未接入运行媒体链；仍需确认 HRI 语音记录的格式及 RF 路由。
- HRI `TRCVTYPE` 配置路径静态研究见[报告](docs/HRI_TRCVTYPE配置路径.md)；[R91 双实例只读观察](docs/R91双实例只读观察.md)已完成一次约10秒采样，共57个样本、0次字段变化，随后会话查询确认已不再附加且 `cleanup_error` 为空。主会话已正常关闭本次启动的官方程序并确认进程退出。表项1在本次窗口显示 `TRCVTYPE=0`、`OPE_MODE=0` 并处于 OFF/未运行状态；实例与 `DGRP_DATA`、`DGRP_VOICE` 的对应关系及 LCD 路径仍待证据确认。
- R93 的设置窗口中，Modulation 显示 `RX:FM - TX:FM`，下拉项为 `FM` 和 `DIGITAL`；点击 DIGITAL 和键盘 Down/Return 后显示值仍为 FM。主会话没有点 Apply/OK，随后 Cancel，主窗口仍显示 ANALOG，因此未确认 Digital 设置已生效或保存。取消后 10 秒只读快照记录 54 个样本、0 次字段变化；HRI 表项 0 `+0x50=1/+0x58=0`，表项 1 `+0x50=0` 且队列计数和 header 长度为 0。报告见 [R93 调制选项观察](docs/R93调制选项与取消后状态观察.md)。这次结果没有判定电台拒绝 Digital，也没有把 HRI 字段映射到 Node Mode、LCD 或 RF 路由。
- 私有预发布 [v0.1.0-alpha.2](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.2) 已于 2026-10-26 05:26:14（中国标准时间）发布，Release ID `423670400`。源码 tag `v0.1.0-alpha.2` 指向 `a965df0ccd6649a972a0be6242a6ba2a1bd83dff`，annotated tag object 为 `848ee23ceb96adbb352e8106b2925c15eace2652`。
- 该源码的正式 clean build 通过 28 项 C++ 测试，compiler/linker warning/error 为 0。构建目录 `build/_work/wirex-bridge-a965df0-20261025-170232`，日志 `build/_work/alpha2-a965df0-clean-build.log`，EXE SHA-256 `b9c7541a453345bc1bc18539e8ba7964a927a3fdd7c2581e2952f556fb740205`。
- 本机目录 `build/releases/v0.1.0-alpha.2` 有 27 个文件：manifest 列 26 项并包含 `manifest.json`；GitHub Release 有 28 个独立 asset。manifest SHA-256 为 `634cc13cd3280deb3d3718ae3cdec0ecf1573a009f721d0aa363018a76b19e48`。草稿与普通 published 下载均通过核对；普通下载重建 27 个文件，字节与本机目录一致，临时目录和下载 helper 进程均已清理。
- 8 组 PowerShell 检查及 WPF 离线渲染均通过。另以不存在的 COM999 端口运行启动失败路径，该路径写入磁盘的 native 状态记录；loopback 测试只查询音频格式，没有打开真实串口、发送 UDP 或启动音频流。UI 状态校验通过；证据目录为 `build/_work/ui-status-integration-a965df0-3dd6a47764524de1a7fd3dc7dd395af8`。alpha.2 的设备实机联测仍待集中执行。
- alpha.2 发布后，`main` 增加了纯 AMBE+2 2450 参数映射与分组缓冲切片，源码提交为 `a5c5a8770305f9f6899895301cb5cee92c830267`。该提交 clean build 成功，35 项离线测试通过；构建来源记录在 `build/_work/wirex-bridge-a5c5a87-20261026-071313/build-provenance.json`，EXE SHA-256 为 `B4C3BC4E9621A4B975AFF26B39220361A883966FEF1FBAF0169C3B5D7178FACD`。root 按 provenance 列表独立重跑 35 项也全部通过，完整测试输出为 `build/_work/a5c5a87-root-tests.log`。新模块目前只用于独立离线测试，没有接入默认运行链；HRI 串口与 13 字节 YSF VCH 的对应格式及真实设备互通仍待确认。该提交没有更改 alpha.2 tag、Release 资产或两个已冻结候选目录。
- 本机 `start-my-bridge.cmd` 已改为启动所选 alpha.2 WPF 界面。本机 `private/user-config` 中的连接配置和音量设置保持在 Git 忽略目录；版本指针已指向 alpha.2。密码仍通过原有本机文件路径提供，本轮没有读取或复制密码正文。
- alpha.1 的一通 DIRECT 手咪→BM 鹦鹉→FTX-1 扬声器回声及退出确认继续作为 alpha.1 历史验收，详细计数和日志见下文。alpha.2 尚无新的设备 HIL 结果。下一阶段继续集中进行音量、TG91、长时间待机、断网恢复、退出和 RF 路由联测；R94 已增加 WPF 当前 BM 来话状态，FTX-1 LCD 显示和 C4FM RF 收发尚未实现，R77–R79 仍是软件研究证据。UI 运行日志的有界保留也列入后续工作。阶段细节见[下一阶段推进计划](docs/下一阶段推进计划.md)。

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

当前交付版本为私有 GitHub 预发布 [`v0.1.0-alpha.2`](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.2)，源码 tag `a965df0ccd6649a972a0be6242a6ba2a1bd83dff`，对应 28 项离线测试通过的正式构建和本机绿色目录 `build/releases/v0.1.0-alpha.2`。alpha.2 的实机 HIL 尚未执行；alpha.1 的一通 DIRECT 用户确认保留为前序版本证据。下方其余旧提交、原型和研究记录按各自版本保留。

步骤 1–4 的 `17f3433`、`aec0471` 和 `2183cef` 构建、测试与便携包结果均是各自版本的历史验证；`2183cef` 的干净构建有 25 项测试通过。之后两次 network-only 私呼回声确认 BM 返回 TS2：第一次因旧 TS1 filter 被全部过滤，三个 preset 随后调整为 TS2；第二次由 RX-only pipeline 识别出完整呼叫事件。源码提交 `1c8c6fd` 和 `005c5e8` 的正式 clean build 均通过 26 项离线测试；`005c5e8` 便携包审计通过，用户确认该版本一通 DIRECT 手咪→BM 鹦鹉→电台扬声器回声清晰。用户也确认 `ab3c5fa` 的 TG91 实机收听正常。长时间待机、断网恢复、46001 订阅收听、DIRECT RF 路由与 C4FM RF 节点仍待集中验收。alpha.2 已交付可连接桌面 UI；其真实设备状态和生命周期仍需最终 HIL 验收，当前状态见本文件顶部。

`aec04710e9d5b32f416b3b78c3812615fedd1988` 是上一个已构建的源码提交。根会话从该 clean HEAD 使用 VS 2019 x64 正式 builder 运行全部 25 项离线测试并通过，产物在 `build/_work/wirex-bridge-aec0471-20261024-104627/`。根会话还审计了 `build/bm-radio-bridge-aec0471/`：13 个实际文件（含 manifest 和 excluded 本机凭据），manifest 中 11 个普通文件的长度与 SHA-256 全部匹配；EXE 与 clean build 相同，包内 `--help` 返回 0 并列出当时的中文预设，`--list-audio-json` 返回 0 且 schema version 为 1。凭据未被读取或哈希，日志目录为空。该提交和便携包是旧 profile 版本的历史验证，不含当前 E3 metadata helper、CC1 预设变更或就绪提示。

E3 network-only 对照使用 `BI7KGD`/Gateway ID `461135501`，RPTC 元数据为 RX/TX `438800000`、power `0`、CC `1`、latitude `0.000000`、longitude `00.000000`、height `0`、location `DIRECT`、description `FTX-1`、slot flags `'4'`、URL `www.qrz.com`、version `20261024`、节点类型 `MMDVM_WIREX_Bridge`、options 空。结果到达 BM `ready`，工具本机发送 `RPTCL` 成功。当前 native 与诊断工具共用轻量元数据 helper，避免 RPTC 配置不一致；helper 不改 Gateway、呼号、密码或调用方色码。`438800000` 是 BM 节点元数据，不会改变 CAT 或 RF。该节点类型表示虚拟 MMDVM 兼容 WIREX 节点，不声明物理 Hat；BM 网页 Firmware/类型文字也不是 FTX-1 固件。E3 还没有经过真实 DMRD Echo、native + HRI/COM/WinMM 或电台端到端验证。

根会话另从当前共享 helper 编译 `build/_work/bm-probe-final-e3-20261024/bm_network_probe.exe` 并运行一次 network-only 诊断：118 ms 内收到配置 ACK、生产 Session 到达 `ready`，实际本机 UDP 发送 9 字节 `RPTCL` 成功，随后 `stopped`、退出码 0。最终 clean build 目录为 `build/_work/wirex-bridge-2183cef-20261024-123605/`，正式构建日志为 `build/_work/bm-ready-2183cef-build.log`。便携候选 `build/bm-radio-bridge-2183cef/` 的根会话审计通过：13 个物理文件含 excluded 凭据；manifest 中 11 项非秘密文件长度/hash 全匹配，EXE 与 clean build 相同，`--help` 完整中文且退出码 0，音频 JSON schema 1、type `audio_devices` 且 WaveIn ID 1 是麦克风，launcher parser 0 个错误；静态依赖仅有 WINMM、bcrypt、WS2_32 和 KERNEL32 系统 DLL。凭据只核实文件存在，未读取或哈希；`logs/` 为空。以上构建和包审计不等于真实语音或硬件联测通过。

## 产品目标与当前里程碑

完整产品目标是让 FTX-1 接入 BrandMeister，并支持两种同等重要、分别验收的真实用途：FTX-1 个人终端（DIRECT；本机手咪上行，网络语音由本机扬声器播放，不因网络下行自动做 RF 发射）和本地 C4FM RF 节点（附近 C4FM 电台经 FTX-1 进入网络，网络语音经 FTX-1 发出）。电脑音频是诊断辅助，不是第三种产品用途。S1-E 是较早的本地双向语音测试里程碑；BM codec、网络和个人终端 native 桥接已通过 26 项离线测试、便携包审计和一通真实 DIRECT 语音闭环验收；长时间运行、断网恢复和其他产品用途仍需分别验证。C4FM RF 节点的设计与实测另行推进。

S1-E native 实现提交为 `732e418bf5b60a99790b00c692601bc95fb1b43c`，随后文档澄清提交为 `df62855c2dd77c5716d3dabffe92211ea6e679b8`。基础会话持续监听，并由操作者按 F/M/C/Q 操作：F 使用固定 WAV，M 先录入最多 8 秒 PC 麦克风内存片段再下行，C 取消当前操作，Q 收尾退出。单一 native 进程独占 HRI COM、WaveIn 和 WaveOut；多轮操作串行进行。主动运行窗口最多 120 秒，首次收尾另有不超过 3 秒的一次性停止/清理预算。S1-E 尚未进行电台实机验证，不代表完整冷启动、BrandMeister、RF 或 UI 已通过。

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
