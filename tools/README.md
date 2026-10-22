# 本机 HRI 诊断启动器

`start-hri-test.cmd` 是绑定本机测试包的可见控制台入口。它只调用同目录的 `wirex_probe.exe` 和 `private\device-y.bin`，固定使用 COM5、WaveIn 1、WaveOut 0、120 秒和增益 16；不安装服务、不创建托盘或登录启动项，不自动重启进程。PowerShell 通过 Windows 内置 `powershell.exe -NoLogo -NoProfile -File` 运行，不改执行策略。

开始前请确认电台 USB 已连接、电台菜单中的 HRI Mode 已开启且 Node Mode 为 DIRECT、官方 WIRES-X 程序已退出，并准备好接在 WaveOut 0 上的耳机。双击 CMD 后，在可见控制台阅读提示并按任意键启动。等程序显示“音频路由已打开”后，可用手咪发言不超过 15 秒，然后松开 PTT；本次监听最长 120 秒。请保持控制台可见，程序结束后窗口会直接退出，不会停在末尾等待按键。

`last-test.log` 使用 Windows PowerShell 默认的 UTF-16LE 文本编码，启动时先清空，再只收集统计摘要、预检错误类别、原生错误诊断、串口关闭结果和进程退出码。PowerShell 按 UTF-8 解码 CLI 输出，以正确显示 ready 中文行；控制台显示程序运行输出。启动器不保存 PCM 录音或 HRI 正文。此工具包是本机电台诊断切片，不是完整双向语音验收版；它不验证语音 codec、完整 HRI 初始化、RF 效果或人耳确认。

仓库中的源脚本位于 `tools/`。维护人员可运行 `powershell.exe -NoLogo -NoProfile -File tools\test-start-hri-test.ps1` 做离线模拟验证；测试只使用唯一 GUID 子目录中的临时 100 字节文件和 PowerShell 假程序，不打开电台或音频设备。清理前会解析并检查目标仍位于系统临时目录、目录名与本次 GUID 完全相符且不是临时根；校验不通过会报错并保留目录。此测试脚本只随源码仓库提供，不包含在私有电台包内。
