# BM 来话身份显示

状态：R100 已将该处理作为 Bridge 核心功能实现。源码提交 `ddeee3105002e5f923c9f727f8ad2811f61a829a` 的 clean build 通过 35 项 C++ 测试，warning/error 为 0；pipeline 与 BM loopback 测试覆盖每通已接受来话的标签生成和清理。COM999 状态 smoke 验证了无来话启动时 Native JSON 的身份对象。FTX-1 LCD 实际显示仍待最终合并联测；`display` 在取得电台屏幕证据前保持 `unknown`。

## 核心处理

每通经过 BM 语音管线接收过滤并进入活动状态的来话，Native 读取 DMR Source ID，将它格式化成 `ID` 加十进制数字，并写入 HRI T3 起始记录中已定位的 10 字节 source 字段，即 68 字节头内偏移 `+0x12`。较短标签右侧补空格；8 位 Source ID 的标签正好占满 10 字节，例如 `ID12345678`。Bridge 不查询呼号数据库；这个标签用于显示数字身份，不是经核实的无线电呼号。

该字段更新属于每通来话的核心路径，程序会自动处理每个已接受来话，不提供用户切换开关。T3/T0 仍用于现有 HRI 呼叫起始和收尾流程，语音内容保持现有 PCM 下行；身份字段不会改变接收目标、本机身份或 RF 路由。当前 Native 状态 JSON 的 `lcd_source_identity` 对象含 `prepared`、`source_id`、`receive_generation`、`label` 和 `display`。未准备时前三项中的布尔和数字字段为 false/0，标签为空；`display` 固定为 `unknown`，直到实际观察屏幕。

Source ID 取自已接受的 DMR 来话状态，不会自动转成呼号。`current_call_link_control_validated` 与 `lcd_source_identity.source_id` 分开保留；如果语音同步先使 pipeline 接受来话、完整 LC 尚未验证，Native 仍按该来话的外层 Source ID 生成标签。状态页面应分别显示 Source ID 和 LC 校验结果。

Native 在通话收尾、接收取消、T3 启动超时、网络丢失、运行异常和进程退出路径清空身份元数据；新 run 从空状态开始。WPF 目前只解析和显示 R94 的 `current_call_*` 当前来话字段，还没有读取或显示 `lcd_source_identity`。Native 的 `display=unknown` 说明尚无电台屏幕观察；T3/T0 状态记录本身不会确认 FTX-1 已显示或已清除字段。

## 版本与验证状态

R98 的已提交源码 `fef55067164e1ac12b410b5199db68546d78bc76` 使用默认关闭的开关构造单通 Source ID 标签。R100 提交将其改为每通已接受来话都执行的核心处理，并移除了该 Native 与 PowerShell 开关。R98 clean build 的 35 项测试和 COM999 状态 smoke 保留为旧实现的历史结果；它们没有验证 R100 的默认来话映射。

`v0.1.0-alpha.2` 仍是已发布版本，本机默认入口也仍指向 alpha.2。alpha.2 没有本页所述的 R100 核心处理；本页不表示新版本已发布。

R100 clean build 通过 35 项 C++ 测试，compiler/linker warning/error 为 0。构建目录为 `build/_work/wirex-bridge-ddeee31-20261026-191001`，正式构建日志为 `build/_work/r100-ddeee31-build.log`，EXE SHA-256 为 `0060826d02433a6fe90c7d57f631e6991cec7f07eb6d4b2a7cadf28a8ebe9649`。COM999 smoke 目录为 `build/_work/r100-lcd-source-identity-smoke-1f558b50b3fa4d7591f4ae5045cabe06`：两条实际 Native JSON 事件均包含空闲身份对象（`prepared=false`、`source_id=0`、`receive_generation=0`、`label=""`、`display="unknown"`），没有 `lcd_experiment`。Native 以预期退出码 2 报告串口打开失败；HRI 串口、WaveIn/WaveOut 保持关闭，TX/RX/control 计数均为 0。该 smoke 只核验默认启动状态 JSON 和 COM999 失败路径，未验证来话映射。测试使用 loopback 地址 `127.0.0.1`、仅查询音频格式，并使用已删除的临时合成密码文件；COM999 测试前确认不存在，未打开音频流或串口，也未发送 UDP。两条记录及结果摘要保存在该目录的 `native-status.jsonl` 和 `result.txt`。每通已接受来话的 10 字节 `ID` 标签与 `source_id`、`receive_generation` 对应关系，以及 LC 状态独立保留、通话结束/取消/T3 启动超时/断网/异常/新 run 清理，由 R100 pipeline 与 BM loopback 离线测试覆盖；原 PCM 语音与 T0 收尾也保留在测试范围内。WPF 仍只显示 R94 的 `current_call_*` 字段，尚未解析或显示 `lcd_source_identity`。实际电台显示需要最终设备联测。

## 最终合并联测

设备联测集中进行，不作为继续其他软件功能的前置条件。测试 Source ID 标签时，FTX-1 进入 WIRES-X HRI 界面并设为 DIRECT；关闭官方 WIRES-X 和其他 Bridge，确认 COM5 由 Bridge 独占，手咪 PTT 保持松开。先用 `listen-91` 被动收听一通来话，记录实际 Source ID、LC 校验状态、身份标签、FTX-1 屏幕文字及通话结束后的屏幕变化。只按实物观察记录 LCD 结果。

TG91 阶段只收听，不按 PTT、不发送语音。双向回声只在最终联测中使用 BM Parrot 目标。R100 当前没有 C4FM RF 节点或 BM→RF 发射功能；RF 功能仍需独立实现和后续验收。本轮没有执行设备步骤。
