# WIREX Bridge 交接入口

本仓库是 native 程序和 UI 的 Git 根目录。本文和 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md) 为接续实施或审查的自包含入口；不要依赖仓库外的 research 目录。较早的 `app/docs` 文档仍有指向 `../../research/...` 的链接，只克隆本仓库时这些链接无法解析。

## 产品目标与当前里程碑

完整产品目标是让 FTX-1 接入 BrandMeister，并支持两种同等重要、分别验收的真实用途：个人终端（本机手咪上行，网络语音由本机扬声器播放，不因网络下行自动做 RF 发射）和 C4FM RF 节点（附近 C4FM/FM 电台经 FTX-1 进入网络，网络语音经 FTX-1 发出）。电脑音频是诊断辅助，不是第三种产品用途。S1-E 只是首个本地双向语音测试里程碑；后续仍要处理 BrandMeister codec 转换、网络会话，以及这两种用途各自的射频验证。

S1-E 当前**正在实施**，目标是一个 native 会话持续监听电台 USB 音频，并在用户命令后播放固定 WAV 或不超过 8 秒的内存麦克风录音。native 在一次最长 120 秒的运行中独占 HRI COM、WaveIn 与 WaveOut；发送流程按候选 T3、PCM、T0 执行，然后恢复电台到电脑的监听。这里描述的是验收要求，不表示代码或硬件已经通过。

S1-E 起点为已验收提交 `87a76b17f245bd1bc183ac245815f7f0aa9f1296`。该提交记录 S1-D/R69 的边界，尚无 S1-E 单会话服务或真实 UI 到 native 的运行连接。实施结束后填写审查通过的结果提交和证据；工作树里出现代码不等于已接受。

## 核心与 UI 的职责

一个 native 子进程是唯一的 COM 和音频资源 owner。UI 只监督该子进程：先创建 suspended 进程，再加入本次运行的 Job Object 并启用 kill-on-close，最后恢复运行。UI 保留进程和 Job 句柄；超时只处理本次创建且由这些句柄确认的子进程或 Job。UI 窗口线程不等待串口、音频或子进程退出。

UI 在 stdin 发送 ASCII 命令，每行一条：

```text
1 <run_id> <request_id> send_fixed
1 <run_id> <request_id> capture_mic
1 <run_id> <request_id> cancel_operation
1 <run_id> <request_id> shutdown
```

native 通过 stdout 输出 JSON 协议 v1 事件。事件类型为 `snapshot`、`request_result`、`operation_event`、`operation_result` 和 `session_result`。每条事件带当前 `run_id` 和 native 在本次 run 内递增的 `seq`；关联操作的事件带 `request_id`。字段包含 `status`、`phase`、`hri`、`audio`、`pc_cleanup` 和 `radio_state`。UI 忽略旧 run 或重复、倒退的 seq，并分别处理请求结果、操作进展、操作结果和会话结束。`accepted` 只说明请求已收到，不能显示成操作完成。

本次进程启动、操作完成、停止记录、PC 端 PCM 排空或 Windows 句柄清理成功，都不能证明电台恢复接收、PTT 释放或 RF 停止。`radio_state` 保持 `unknown`。native 启动不自动发起下行播放、PTT 或 RF 操作。

## 退出与数据边界

`cancel_operation`、显式 `shutdown`、stdin EOF、设备错误和 120 秒运行期限都走有界清理。UI 关闭时也请求相同的收尾，并等待 native 的会话结果和自己持有的进程句柄退出；如需强制结束，只能作用于本次 child/Job。强制结束显示“核心已强制结束，设备收尾未知”。

若 T3 尚未尝试，取消不得发送 T0；若 T3 已尝试，错误或取消清理至多尝试一次有界 T0。每个操作结束后恢复监听。固定 WAV、麦克风 PCM、设备私有 fixture 和原始协议数据不得写入日志、报告或 Git。

用户可按本机已授权流程获取、重采或准备需要的 fixture；Git 仓库不保存或推送设备私有 fixture、操作者语音、临时抓包、厂商二进制、凭据或包含原始载荷的报告。未来若需将人工合成 WAV 作为离线测试数据，先审查具体文件，再为准确测试路径增加窄范围的 ignore 例外，不提交操作者录音。

## 现有证据及其范围

仓库包含 DIRECT 帧与流解析、HRI 状态机、下行协调器、WAV 校验、WinMM 输入/输出和离线测试。S1-D/R69 记录一次独立固定 WAV 下行人工试听：用户确认听到清晰报数，播放后声音停止且电台界面恢复；软件报告记录本机清理成功并将 `radio_state` 保留为 `unknown`。此前也有独立 radio-to-PC 原型人工结果。这两次单向原型结果不等于同一 native 会话、UI 监督、S1-E 取消/EOF 或重复启动已经通过。

R63 的脱敏结论只支持构造固定 T3/T0 软件候选；R68 的脱敏结论只支持有限的软件状态请求路径。它们没有证明候选记录在电台侧的 PTT 含义、是否已到达 UART、射频行为或电台已恢复。S1-E 具体验收场景、命令和证据空栏见 [`docs/交接与阶段同步.md`](docs/交接与阶段同步.md)。

## Git 与阶段交付

每个阶段使用用户已核实的 GitHub 账户身份 author/committer，并推送到用户私有仓库。推送前检查准确提交范围、所有待提交文件和私有仓库状态；不重写已有历史、不 force-push，也不使用 `git add -A` 把代理工作树中的改动一起暂存。当前用户已授权各阶段推送，不需要重复询问。

S1-E 需要报告起点提交、结果提交、精确改动、实际执行的离线命令与结果、未执行的硬件步骤及剩余风险。未执行的验证不能写为通过。外侧 research 树不纳入 Git；本文和阶段文档已保留 S1-E 所需设计与验收摘要，S1-E 审查不需要原始研究抓包或二进制。
