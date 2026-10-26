# BM 来话身份显示

状态：R100 将该处理作为 Bridge 核心功能实现。当前工作区已经为每通已接受来话生成标签并写入 Native 状态 JSON，focused 检查已通过；clean build 待执行。随后在最终合并联测中观察 FTX-1 LCD。`display` 在取得电台屏幕证据前保持 `unknown`。

## 核心处理

每通经过 BM 语音管线接收过滤并进入活动状态的来话，Native 读取 DMR Source ID，将它格式化成 `ID` 加十进制数字，并写入 HRI T3 起始记录中已定位的 10 字节 source 字段，即 68 字节头内偏移 `+0x12`。较短标签右侧补空格；8 位 Source ID 的标签正好占满 10 字节，例如 `ID12345678`。Bridge 不查询呼号数据库；这个标签用于显示数字身份，不是经核实的无线电呼号。

该字段更新属于每通来话的核心路径，程序会自动处理每个已接受来话，不提供用户切换开关。T3/T0 仍用于现有 HRI 呼叫起始和收尾流程，语音内容保持现有 PCM 下行；身份字段不会改变接收目标、本机身份或 RF 路由。当前 Native 状态 JSON 的 `lcd_source_identity` 对象含 `prepared`、`source_id`、`receive_generation`、`label` 和 `display`。未准备时前三项中的布尔和数字字段为 false/0，标签为空；`display` 固定为 `unknown`，直到实际观察屏幕。

Source ID 取自已接受的 DMR 来话状态，不会自动转成呼号。`current_call_link_control_validated` 与 `lcd_source_identity.source_id` 分开保留；如果语音同步先使 pipeline 接受来话、完整 LC 尚未验证，Native 仍按该来话的外层 Source ID 生成标签。状态页面应分别显示 Source ID 和 LC 校验结果。

Native 在通话收尾、接收取消、T3 启动超时、网络丢失、运行异常和进程退出路径清空身份元数据；新 run 从空状态开始。WPF 目前只解析和显示 R94 的 `current_call_*` 当前来话字段，还没有读取或显示 `lcd_source_identity`。Native 的 `display=unknown` 说明尚无电台屏幕观察；T3/T0 状态记录本身不会确认 FTX-1 已显示或已清除字段。

## 版本与验证状态

R98 的已提交源码 `fef55067164e1ac12b410b5199db68546d78bc76` 使用默认关闭的开关构造单通 Source ID 标签。当前 R100 工作区将其改为每通已接受来话都执行的核心处理，并移除了该 Native 与 PowerShell 开关。R98 clean build 的 35 项测试和 COM999 状态 smoke 保留为旧实现的历史结果；它们没有验证 R100 的默认来话映射。

`v0.1.0-alpha.2` 仍是已发布版本，本机默认入口也仍指向 alpha.2。alpha.2 没有本页所述的 R100 核心处理；本页不表示新版本已发布。

R100 focused 检查已通过；clean build 和完整软件验收待执行。测试需覆盖每通已接受来话的 10 字节 `ID` 标签与 `source_id`、`receive_generation` 一致；未验证 LC 时状态分别保留外层 ID 和 LC 标志；通话收尾、取消、T3 启动超时、断网、异常及新 run 后 Native 元数据清空；原 PCM 语音与 T0 收尾保持有效。WPF 仍显示 R94 `current_call_*` 字段；新对象接入严格校验和界面显示待后续 UI 切片。软件测试完成后还要单独执行设备验收。

## 最终合并联测

设备联测集中进行，不作为继续其他软件功能的前置条件。测试 Source ID 标签时，FTX-1 进入 WIRES-X HRI 界面并设为 DIRECT；关闭官方 WIRES-X 和其他 Bridge，确认 COM5 由 Bridge 独占，手咪 PTT 保持松开。先用 `listen-91` 被动收听一通来话，记录实际 Source ID、LC 校验状态、身份标签、FTX-1 屏幕文字及通话结束后的屏幕变化。只按实物观察记录 LCD 结果。

TG91 阶段只收听，不按 PTT、不发送语音。双向回声只在最终联测中使用 BM Parrot 目标。R100 当前没有 C4FM RF 节点或 BM→RF 发射功能；RF 功能仍需独立实现和后续验收。本轮没有执行设备步骤。
