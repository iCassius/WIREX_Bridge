# BM 来话 Source ID 显示实验

状态：R98 源码中的显式实验开关已实现；native clean build 和启动失败状态 smoke 已通过。尚未用真实 BM 呼叫观察 FTX-1 LCD，屏幕状态仍为 `unknown`。

## 实验做什么

Native 参数 `--experimental-lcd-source-id` 默认关闭。开启后，程序在 BM 语音管线给出活动接收 Snapshot 时，读取其中的 DMR Source ID，把它格式化为 `ID` 加十进制数字，并写入 HRI T 起始正文中已定位的 10 字节 source 字段（68 字节头内偏移 `+0x12`）。其余头字段和正文保持原值。DMR Source ID 最多为 8 位十进制数，标签最多正好占满 10 字节，例如 `ID12345678`；较短标签在右侧补空格。这个字符串用于辨认数字 ID，不是经过验证的 WIRES-X callsign。程序不查询呼号数据库，也不把 DMR ID 填成本机呼号。

开关只改变已接受来话的起始正文。它保留现有 mode4 起始正文、T0 收尾正文和 PCM 下行会话顺序，不改变接收目标、通话类型、既有 PCM 语音内容或本机身份字段。`lcd_experiment.candidate_prepared=true` 记录 `stream_session` 接受了本次通话起始正文；电台 LCD 读取结果仍为 `unknown`。

## 接收验证边界

生成标签时，Native 检查 Snapshot 处于非 idle、非 filtered 状态且 `receive_generation` 非零。该路径没有要求 `link_control_validated=true`。当语音同步已使 pipeline 接受来话、但嵌入或完整 LC 尚未验证时，程序仍可能根据外层 DMR Source ID 生成标签。应同时查看 `current_call_link_control_validated`：值为 `false` 时，标签仅复述 DMRD 外层 Source ID，不能当作已由 Link Control 确认的呼号。

状态 JSON 的 `lcd_experiment` 对象含 `enabled`、`display`、`candidate_prepared`、`candidate_source_id`、`receive_generation` 和 `candidate_label`。`display` 当前固定为 `unknown`；程序没有读取电台 LCD 状态。BM→HRI 的既有下行仍按原会话工作。此选项不产生手咪 PTT 或 RF 发射命令，也不增加 BM→RF 路由；它不会读取或设置 FTX-1 Node Mode。

## 启动方式与版本范围

标准 PowerShell 启动器 `tools/start-bm-radio-bridge.ps1` 提供 `-ExperimentalLcdSourceId` 开关，并在本次启动时向 Native 传入 `--experimental-lcd-source-id`。每次启动都要显式指定；连接 profile 和音量设置不会保存该开关。WPF 界面目前没有对应控件。

本机 `start-my-bridge.cmd` 仍指向已发布的 `v0.1.0-alpha.2`，该包没有 R98 Native。该入口不会启动这项实验。实验开关属于源码提交 `fef55067164e1ac12b410b5199db68546d78bc76` 的功能；只有运行包含该源码构建的 Native 和对应启动器时才可使用。当前没有为此功能发布新版本。

## 软件验证

R98 正式 clean build 有 35 项测试全部通过，compiler/linker warning/error 为 0。构建目录为 `build/_work/wirex-bridge-fef5506-20261026-183908`，完整日志为 `build/_work/r98-fef5506-build.log`，EXE SHA-256 为 `a95051d4c2fd10978310904d68d1a0bd5552e11b7444c2a4ef4ad91d7ebd6b6c`。

COM999 离线 smoke 对比了开关关闭和开启的启动状态：两次均产生 `preflight_passed`、`serial_open_or_configure_failed` 两条状态记录，WPF 的 `Test-UiStatusRecord` 都接受了记录；开关分别呈现 `enabled=false/true`，两次 `display=unknown`、`candidate_prepared=false`、候选 Source ID 和 generation 为零、标签为空。重复传入开关在创建状态文件或进入设备启动前以退出码2拒绝。测试使用不存在的 COM999、loopback 地址、合成密码文件和只查询格式的音频枚举；串口未打开、WaveIn/WaveOut 流未打开、UDP TX/RX/control 计数为零，合成密码已删除，Native 进程已退出。记录目录为 `build/_work/r98-lcd-status-smoke-d9188b3948784828828de307ab3a4e69`。这组 smoke 没有接收 BM 呼叫，也没有验证电台显示。

## 最终集中联测

后续在用户安排的合并联测中，先让 FTX-1 进入 WIRES-X HRI 界面并选择 DIRECT；关闭官方 WIRES-X 和其他 Bridge，确认 COM5 由本 Bridge 独占，并保持手咪 PTT 松开。先用 `listen-91` 被动收听一通来话，记录 WPF/Native 的 Source ID、LC 验证状态、实验标签、FTX-1 屏幕实际文本和清除时机。屏幕结果按实物观察填写，不能用 `candidate_prepared` 推断显示成功。

双向回声只在最终合并联测中使用 BM Parrot 目标；TG91 阶段只接收，不按 PTT、不发语音。完整联测还需观察原 T0 后屏幕是否清除，并分别记录软件状态和人工看到的 LCD 结果。本轮没有执行这些设备步骤。
