# WIREX Bridge 交接入口

> **BM + FTX-1 接续入口：** 用户已授权继续实现 BM + 电台联合测试候选。步骤进度、当前基线、文件所有权和未启动项见 [`docs/BM联调推进.md`](docs/BM联调推进.md)。当前 BM 状态机仅通过 localhost fake Master；真实 BM、设备/HRI 联测、UI 与 RF 节点实测尚未开始。

本仓库是 native 程序和 UI 的 Git 根目录。本文和 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md) 为接续实施或审查的自包含入口；不要依赖仓库外的 research 目录。较早的 `app/docs` 文档仍有指向 `../../research/...` 的链接，只克隆本仓库时这些链接无法解析。

## 当前 BM + FTX-1 候选

步骤 1–4 native 候选源码提交为 `17f3433ae4cd6820622033ddb1910c030cb260f2`，基线为 `3c943413928e1443a2eaa722f730a1e95fdd15b2`。Windows PowerShell 5.1 / VS 2019 clean build 已运行 24 项离线测试并通过，产物目录与完整测试名单见 [`docs/BM联调推进.md`](docs/BM联调推进.md) 及本地包 `build/bm-radio-bridge-17f3433/manifest.json`。本地非 ZIP 便携候选目录为 `build/bm-radio-bridge-17f3433`；根会话已复核其 12 个文件、manifest 中 11 项文件长度/SHA-256、EXE 与 clean build 一致、`--help` 和 `--list-audio-json` 结果及静态 DLL 导入。离线 fake Master 只监听 localhost；真实 Master、COM、WinMM 与电台联合测试尚未运行。BM 上行编码前固定应用 16x 软件 PCM 增益，复用 `pcm_gain::SignalStats` 记录增益前后统计和削顶数；该倍率沿用用户确认的旧独立原型人工试听结果，新 BM 链路的声音效果仍待真实联合测试。步骤 5 身份已由用户准备，UI 与 RF 节点实测暂缓。

## 产品目标与当前里程碑

完整产品目标是让 FTX-1 接入 BrandMeister，并支持两种同等重要、分别验收的真实用途：FTX-1 个人终端（DIRECT；本机手咪上行，网络语音由本机扬声器播放，不因网络下行自动做 RF 发射）和本地 C4FM RF 节点（附近 C4FM 电台经 FTX-1 进入网络，网络语音经 FTX-1 发出）。电脑音频是诊断辅助，不是第三种产品用途。S1-E 是较早的本地双向语音测试里程碑；BM codec、网络和个人终端 native 桥接现在已有离线候选，仍需用户安排真实 BM 和电台端点验收。C4FM RF 节点的设计与实测另行推进。

S1-E native 实现提交为 `732e418bf5b60a99790b00c692601bc95fb1b43c`，随后文档澄清提交为 `df62855c2dd77c5716d3dabffe92211ea6e679b8`。基础会话持续监听，并由操作者按 F/M/C/Q 操作：F 使用固定 WAV，M 先录入最多 8 秒 PC 麦克风内存片段再下行，C 取消当前操作，Q 收尾退出。单一 native 进程独占 HRI COM、WaveIn 和 WaveOut；多轮操作串行进行。主动运行窗口最多 120 秒，首次收尾另有不超过 3 秒的一次性停止/清理预算。S1-E 尚未进行电台实机验证，不代表完整冷启动、BrandMeister、RF 或 UI 已通过。

实现边界、8 项离线测试、无设备安全失败路径与下一步验收见 [`docs/S1-E本地会话验收.md`](docs/S1-E本地会话验收.md) 和 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md)。从 `app` Git 根目录用 Windows PowerShell 5.1 重复构建并运行测试：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\build-radio-session.ps1
```

脚本只使用本机已安装的 VS 2019 Build Tools，产物写入 `build\_work`；未提交源码的开发构建目录带 `-dirty`，不能作为交付核心。该命令已对干净源码提交构建并通过 8 项离线测试。当前本地候选为 `build/local-radio-session-732e418`；主会话核对其恰有 7 个文件、manifest 的 6 个文件记录长度与 SHA-256 全部吻合，核心 EXE 与 `build/_work/radio-session-732e418/wirex_probe.exe` 完全一致，且包内 `--help` 退出码为 0。候选只提供给操作者后续 HIL，尚未运行设备。本阶段已通过主会话审阅，当前按用户授权推送到 `main`；后续阶段仍须先经主会话审阅再推送。当前不把图形 UI 或自动启动作为本机基础测试入口。

## 当前 native 入口与后续 UI 接入

当前本地候选由操作者在可见 PowerShell 控制台运行 `tools/start-local-radio-session.cmd`，明确确认本次串口和音频设备后输入 `START`。native 启动后用 F/M/C/Q 键触发固定 WAV、麦克风捕获、取消和退出；不要求手工输入下面的 stdin 协议文本。一个 native 会话仍是唯一的 COM 和音频资源 owner。native 入口不会在启动时自动发 T3 或开始麦克风采集。

UI 协议/状态层作为后续 UI 接入基础保留，但真实 UI 对 native 子进程的启动监督和可分发打包移至后续阶段，不阻塞本次 native 基础功能验收。届时 UI 应先创建 suspended 进程，再加入本次运行的 Job Object 并启用 kill-on-close，最后恢复运行；UI 保留进程和 Job 句柄，超时只处理本次创建且由这些句柄确认的子进程或 Job，窗口线程不等待串口、音频或子进程退出。

为后续 UI/自动化接入保留的 stdin ASCII 命令，每行一条：

```text
1 <run_id> <request_id> send_fixed
1 <run_id> <request_id> capture_mic
1 <run_id> <request_id> cancel_operation
1 <run_id> <request_id> shutdown
```

native 通过 stdout 输出 JSON 协议 v1 事件。事件类型为 `snapshot`、`request_result`、`operation_event`、`operation_result` 和 `session_result`。每条事件带当前 `run_id` 和 native 在本次 run 内递增的 `seq`；关联操作的事件带 `request_id`。字段包含 `status`、`phase`、`hri`、`audio`、`pc_cleanup` 和 `radio_state`。UI 忽略旧 run 或重复、倒退的 seq，并分别处理请求结果、操作进展、操作结果和会话结束。`accepted` 只说明请求已收到，不能显示成操作完成。

本次进程启动、操作完成、停止记录、PC 端 PCM 排空或 Windows 句柄清理成功，都不能证明电台恢复接收、PTT 释放或 RF 停止。`radio_state` 保持 `unknown`。native 启动不自动发起下行播放、PTT 或 RF 操作。

## 退出与数据边界

`cancel_operation`、显式 `shutdown`、stdin EOF、设备错误和 120 秒运行期限都走有界清理。后续 UI 接入时，窗口关闭也请求相同的收尾，并等待 native 的会话结果和自己持有的进程句柄退出；如需强制结束，只能作用于本次 child/Job。强制结束显示“核心已强制结束，设备收尾未知”。

若 T3 尚未尝试，取消不得发送 T0；若 T3 已尝试，错误或取消清理至多尝试一次有界 T0。每个操作结束后恢复监听。固定 WAV、麦克风 PCM、设备私有 fixture 和原始协议数据不得写入日志、报告或 Git。

用户可按本机已授权流程获取、重采或准备需要的 fixture；Git 仓库不保存或推送设备私有 fixture、操作者语音、临时抓包、厂商二进制、凭据或包含原始载荷的报告。未来若需将人工合成 WAV 作为离线测试数据，先审查具体文件，再为准确测试路径增加窄范围的 ignore 例外，不提交操作者录音。

## 现有证据及其范围

仓库包含 DIRECT 帧与流解析、HRI 状态机、下行协调器、WAV 校验、WinMM 输入/输出和离线测试。S1-D/R69 记录一次独立固定 WAV 下行人工试听：用户确认听到清晰报数，播放后声音停止且电台界面恢复；软件报告记录本机清理成功并将 `radio_state` 保留为 `unknown`。此前也有独立 radio-to-PC 原型人工结果。这两次单向原型结果不等于同一 native 会话的基础功能、S1-E 取消/EOF 或重复启动已经通过；UI 子进程监督另列为后续阶段。

R63 的脱敏结论只支持构造固定 T3/T0 软件候选；R68 的脱敏结论只支持有限的软件状态请求路径。它们没有证明候选记录在电台侧的 PTT 含义、是否已到达 UART、射频行为或电台已恢复。S1-E 当前证据与待做 HIL 项见 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md)。

## Git 与阶段交付

每个阶段使用用户已核实的 GitHub 账户身份 author/committer。推送前检查准确提交范围、所有待提交文件和私有仓库状态；不重写已有历史、不 force-push，也不使用 `git add -A` 把代理工作树中的改动一起暂存。S1-E 已通过主会话审阅，当前按用户授权推送；后续阶段仍须先审阅再推送。

S1-E native 与文档本地提交已记录在上方并通过主会话审阅；当前按用户授权推送 `main`，之后等待操作者安排 HIL。阶段文档记录实际执行的离线命令与结果、候选核对、未执行的硬件步骤及剩余风险。未执行的验证不能写为通过。外侧 research 树不纳入 Git；本文和阶段验收文档已保留接续所需设计与证据摘要，审查不需要原始研究抓包或二进制。
