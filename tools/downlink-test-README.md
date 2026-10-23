# WIREX Bridge 下行候选本机测试

本包用于一次受限的本机下行候选测试。它不会改写既有上行人工通过结果，也不包含上行监听入口。测试不验证 BrandMeister、网络桥接或射频效果；包内不含厂家 DLL，也不安装 Windows 服务。

开始前请确认：

- 电台已通过 USB 直接连接到这台电脑。
- 电台的 HRI 已开启，节点模式为 DIRECT，屏幕停留在 WIRES-X HRI 界面。
- 官方 WIRES-X 程序已经退出。
- 手咪 PTT 已松开；测试期间不要按手咪 PTT。
- 电台扬声器音量已调到合适水平。

双击 `start-hri-downlink-test.cmd`，阅读可见控制台中的检查结果和提示，再在本机按任意键开始。程序会播放一段约 7.25 秒的固定测试语句；约 20 秒控制流程和收尾完成后自动退出。需要取消时按 `Ctrl+C`。如果出现持续音频或其它异常活动，请关闭电台并反馈情况。

测试完成后请回传 `last-downlink-status.json` 和 `last-downlink-test.log`，并告知：是否听到语句、音质和音量如何、结束后电台界面与音频状态如何。报告只记录有限软件流程和本机清理结果；它不能证明电台已恢复接收、实际射频行为或 BrandMeister 通路。

本机测试包预期仅含以下七项：`wirex_probe.exe`、`start-hri-downlink-test.cmd`、`start-hri-downlink-test.ps1`、本说明 `README.md`、`manifest.json`、`private/device-y.bin` 和 `assets/voice-test.wav`。请勿加入上行旧入口或测试脚本，以免误启动其它流程。
