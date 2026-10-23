# 本机 HRI 诊断启动器

`start-hri-test.cmd` 是绑定本机测试包的可见控制台入口。它只调用同目录的 `wirex_probe.exe` 和 `private\device-y.bin`，固定使用 COM5、WaveIn 1、WaveOut 0、120 秒和增益 16；不安装服务、不创建托盘或登录启动项，不自动重启进程。PowerShell 通过 Windows 内置 `powershell.exe -NoLogo -NoProfile -File` 运行，不改执行策略。

开始前请确认电台 USB 已连接、电台菜单中的 HRI Mode 已开启且 Node Mode 为 DIRECT、官方 WIRES-X 程序已退出，并准备好接在 WaveOut 0 上的耳机。双击 CMD 后，在可见控制台阅读提示并按任意键启动。等程序显示“音频路由已打开”后，可用手咪发言不超过 15 秒，然后松开 PTT；本次监听最长 120 秒。请保持控制台可见，程序结束后窗口会直接退出，不会停在末尾等待按键。

`last-test.log` 使用 Windows PowerShell 默认的 UTF-16LE 文本编码，启动时先清空，再只收集统计摘要、预检错误类别、原生错误诊断、串口关闭结果和进程退出码。`last-session-status.json` 则由启动器和 native probe 共同写入不含音频、协议正文或设备身份的状态快照；native 在阶段变化时更新，并在运行期间最多每秒更新一次，使用同目录临时文件原子替换。它记录进程 PID/创建时间、阶段、V/Y/X 与 I/O 计数、PCM 字节统计、PC 清理状态和独立的 `radio_state=unknown`。只有音频与串口清理结果都已取得后，native 才把最终快照标为 `final=true`；这不表示电台状态或 RF 已验证。

如果用户关闭控制台导致进程来不及写最终快照，最近的快照会保留 `final=false`，其中未完成的 PC 清理结果仍为 pending，电台状态为 unknown。下次运行时，启动器会核对报告中的 PID 和进程创建时间：确认旧进程仍活动或无法确认报告所有者时，会拒绝启动并保留现有文件；确认旧进程已结束后，会先把旧快照的阶段和计数记为 incomplete、cleanup unknown，再开始新一轮。此机制保留关窗前的元数据，不保证 Windows 关闭控制台时应用清理代码已运行。PowerShell 按 UTF-8 解码 CLI 输出，以正确显示 ready 中文行；控制台显示程序运行输出。启动器不保存 PCM 录音或 HRI 正文。此工具包是本机电台诊断切片，不是完整双向语音验收版；它不验证语音 codec、完整 HRI 初始化、RF 效果或人耳确认。

仓库中的源脚本位于 `tools/`。维护人员可运行 `powershell.exe -NoLogo -NoProfile -File tools\test-start-hri-test.ps1` 做离线模拟验证；测试覆盖固定参数、退出码、日志过滤、旧未完成快照、活动进程和无法核对的所有者，并只使用唯一 GUID 子目录中的临时 100 字节文件和 PowerShell 假程序，不打开电台或音频设备。清理前会解析并检查目标仍位于系统临时目录、目录名与本次 GUID 完全相符且不是临时根；校验不通过会报错并保留目录。此测试脚本只随源码仓库提供，不包含在私有电台包内。

## 本地下行候选测试

start-hri-downlink-test.cmd 是独立的可见控制台入口。生产预检要求同目录存在 wirex_probe.exe、private/device-y.bin（100 字节，SHA-256 为 82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f）和 assets/voice-test.wav（SHA-256 为 4beaf3d5539084f33ae05ba02112823edb75985d2f9e03668e2bdf28cd75570d）。启动器只读调用 --list-audio，要求 WaveOut 中恰好有一个名称为“扬声器 (2- USB Audio Device)”的设备；它不固定或传入输出编号，原生候选流程会重新枚举并按名称选择当前编号。

预检完成后，控制台提醒操作者保持 HRI Mode 为 ON、Node Mode 为 DIRECT、关闭官方 WIRES-X 程序、松开手咪 PTT 并调好电台扬声器音量。按任意键后原生流程运行约 20 秒并播放约 7.25 秒的固定语句；无需赶到远程窗口操作，运行中可按 Ctrl+C 取消。启动器同步等待原生程序正常退出，不安装服务、不启动后台进程、不自动重试。

last-downlink-test.log 只保存计数、经过净化的诊断类别和退出码，不记录音频、协议正文或设备身份。last-downlink-status.json 延续 PID 与进程创建时间的所有者保护，并记录下行阶段、T 写入及匹配记录计数、PCM 进度和 PC 清理状态。报告中的 radio_state 始终是 unknown；operation_result=completed 只代表软件流程和 PC 清理完成，不能证明电台实际出声或停止，需操作者现场确认。此入口使用独立的下行报告和日志，不覆盖上行监听报告。

源码维护人员可运行 powershell.exe -NoLogo -NoProfile -File app/tools/test-start-hri-downlink-test.ps1 做离线 mock 检查。它覆盖动态变化的 WaveOut 编号、目标名称重复、固定 CLI 参数、资产摘要失败、报告所有者保护、日志过滤和非零退出结果；不运行原生 EXE、不打开串口或音频设备。测试只使用带 GUID 的临时目录，清理前核对绝对路径和完整目录名。TestMode 只接受 PowerShell mock 与显式临时资产，允许测试副本模拟固定摘要；生产路径仍严格校验上面两份 SHA-256。这个测试脚本只在源码树中，不放入本地测试包。
