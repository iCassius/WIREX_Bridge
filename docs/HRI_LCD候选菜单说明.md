# HRI LCD 呼号字段候选菜单

## 目录内容

菜单随候选目录运行，不从源码目录直接启动。目标目录为 `build/candidates/lcd-identity-7775ccf/`，应包含 clean native、固定测试 WAV、获批 100 字节 Y 模板、完整许可证、来源说明、构建 provenance、manifest 和空 `reports/` 目录。菜单脚本通过固定字节数与 SHA-256 检查 native、WAV、Y 模板后才显示选项。

## 启动和选择

1. 电台进入 WIRES-X HRI 界面，Node Mode 设为 `DIRECT`；关闭官方 WIRES-X 和其他 Bridge，松开手咪 PTT。
2. 双击 `start-hri-lcd-identity-candidate.cmd`。默认端口是 `COM5`；连接端口不同可从命令行传 `-Port COMn`。
3. 菜单从包外 `private/user-config/connection-profile.json` 读取呼号字段。找不到有效呼号时，菜单会要求本次输入；它不会改写或复制该配置文件。若本机配置放在其他位置，可向 CMD 传入 `-ProfilePath ABS`。
4. 每轮手动选一个字段：`D` 目的、`S` 来源、`L` 本机、`Q` 退出。确认前置条件后输入 `Y`，程序才为这个字段启动一次 bounded 本地 WAV 流程。native 返回后菜单等待下一次人工选择，不自动发送余下字段。
5. 运行过程中按 `Ctrl+C` 可让 native 使用现有清理流程取消。每轮报告保存在 `reports/`，文件名只包含时间和字段名；native 报告不保存呼号。

固定 WAV 来自既有离线生成的测试语句，时长约 7.25 秒，大小 695836 字节，SHA-256 为 `4beaf3d5539084f33ae05ba02112823edb75985d2f9e03668e2bdf28cd75570d`。Y 模板大小 100 字节，SHA-256 为 `82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f`。native 来源 commit 为 `7775ccfeeddd8aaeffa7d36503ec5ea0c8113f99`，clean 构建含 31 项离线测试；菜单脚本自身由单独的后续 commit 提供，manifest 分别记录两者。

## 结果记录

这是单字段位置对照实验，不启动 BrandMeister，也不采集或发送手咪语音。报告把 `lcd_display` 固定记录为 `unknown`。人工查看 FTX-1 屏幕，并记录是否出现呼号、显示在哪个位置、T0 后何时清除；软件构建或报告本身不作为 LCD 显示成功证据。

当前候选构建通过 31 项离线测试。native CLI 另完成 4 项无设备 smoke：help 列出命令、无效字段拒绝、纯数字 DMR ID 拒绝、有效参数配缺失 Y 模板时在串口和 WaveOut 打开前退出。测试未连接 COM、音频硬件、BM 或 RF。
