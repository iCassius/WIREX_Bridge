# S1-D：本机下行 T 候选与 WAV 流程

## 范围与固定输入

本切片新增独立 `--hri-downlink-candidate` 入口及纯 C++17 下行协调器。入口仍使用现有 HRI V/Y/X 初始化和串口心跳；只有首次收到 checksum-valid Y/0 后，才开始候选流程。启动器预检后等待操作者在本机可见控制台按键，按键前不启动 native 命令；进程不创建后台服务、不自动重试。此命令不改变已有 HRI 监听或其它命令。

CLI 固定为 `--hri-downlink-candidate --port COM5 --body-file ABS --file WAV --report-file ABS`。候选帧不接受任意用户帧：启动帧以 R63 组装函数的 `(PttSw=1, field50=1, flags248c=9)` 构造 T3，停止帧以 `(0,1,9)` 构造 T0，随后由既有 DIRECT codec 编码。R68 只支持研究同一 ConnectCntl owner 上的 `(0,1)` 与 `(0,0)` 软件状态请求路径；它没有证明 1/0 的实机起停含义、候选帧已到达 UART 或射频已停止。候选依据见 [R63](../../research/planning/R63_T候选空载构造与应答映射.md) 和 [R68](../../research/planning/R68_SendTrcvPttCmd调用与状态边界.md)。

启动器要求随包存在 `private/device-y.bin`（100 字节，SHA-256 `82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f`）和 `assets/voice-test.wav`（SHA-256 `4beaf3d5539084f33ae05ba02112823edb75985d2f9e03668e2bdf28cd75570d`）。WAV 为固定约 7.2478 秒语句；native 只接受不超过 8 秒的 48 kHz、单声道、16 位 PCM。发送前重新枚举 WaveOut，要求恰有一个名称完全匹配“扬声器 (2- USB Audio Device)”且标记为 USB 的设备，并检查其格式；设备编号动态选择，不默认回退。

## 流程和报告含义

每次串口候选写入都有独立的“尝试”和“完整写入”计数。启动写入尝试后，不论启动响应超时、用户取消、PCM 失败或 PCM 完成，协调器都只安排一次停止候选写入；如果串口 API 明确失败或句柄失效，流程停止并将电台状态留为 unknown。若协调器因状态事件错误未能发出停止动作，native 会在音频回收之前至多直接尝试一次固定 T0；这次兜底不会重试，也不会伪造停止记录观察。启动写入尚未尝试时取消不会发送 T0。

只有启动 T 写入完整返回后收到 checksum-valid T 类型记录，协调器才允许 PCM 输出。PCM 以有限块提交，主循环继续处理 HRI 心跳和串口数据，并轮询输出队列排空。正常停止记录等待上限为 3 秒；取消后的停止等待上限为 500 毫秒；PCM 窗口为 WAV 向上取整后的时长加 1 秒；整个 V/Y、候选、PCM 和停止收尾流程共享 20 秒期限。超时后仍只允许一次短时停止写尝试，然后关闭本机资源。

DIRECT T 记录没有可用于本流程的序列号。协调器在候选写入完成时清空不完整解析片段，native 也丢弃写入前已读取的串口块；这能隔断跨越写入边界的半帧，但无法识别一条完整的延迟 T 记录。因此报告只称“matching T record”，不称设备确认或严格关联的 ACK。`start_matching_t_payload_bytes` 与 `stop_matching_t_payload_bytes` 只记录匹配正文长度；未观察时写 `null`，不保留正文、首字节或身份信息。

候选专用 `downlink` 报告对象包含阶段、软件流程结果、失败原因、启动/停止写尝试与完整写入计数、匹配 T 记录计数和正文长度、PCM 已提交字节数及队列排空结果。旧命令不输出该对象。顶层和下行对象的 `radio_state` 始终为 `unknown`。只有完整软件流程和本机串口、WaveOut 清理成功才可标 `completed`；它仍不证明电台回到接收状态、实际射频行为或人耳听到语音。取消后若未观察到匹配停止 T 记录，报告结果为 `failed`，并保留 `radio_state=unknown`。

## 离线验证

本机与主会话使用 VS2019 Build Tools x64、C++17、`/W4 /MT` 从源码独立编译了完整 probe、下行协调器测试、报告 schema 测试和启动器 mock。协调器测试覆盖正常完成、取消和超时、部分写入、重复/过期事件、迟到记录、跨写入边界的旧半帧、PCM/总期限以及本机清理结果；报告测试检查可选 schema 和未观察 payload 长度的 `null`。启动器 mock 检查动态 WaveOut 编号、设备名称重复、固定参数、摘要校验、所有者保护和退出结果。离线验证未运行候选 CLI、没有打开串口或 WaveOut，也没有发送 T 帧。

```powershell
powershell.exe -NoLogo -NoProfile -File tools\test-start-hri-downlink-test.ps1
```

该测试脚本只保留在源码仓库，不放入本机测试包。打包时由主会话从本地审阅通过的源码构建 probe，并重新核对包内文件清单和摘要；包中不包含厂家 DLL、测试脚本、运行日志或旧报告。
