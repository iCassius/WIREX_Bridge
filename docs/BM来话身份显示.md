# BM 来话身份显示

状态：R100 将 Source ID 标签纳入 Bridge 核心处理；R101 增加了 WPF 来源标签状态显示。WPF 会显示 Native 报告的标签是否已准备，并持续把 FTX-1 屏幕结果标为未知。小工作区画面已复核，活动来话、来源标签和详情均可见。FTX-1 LCD 实际显示仍待最终合并联测。

## 核心处理

每通经过 BM 语音管线接收过滤并进入活动状态的来话，Native 读取 DMR Source ID，将它格式化成 `ID` 加十进制数字，并写入 HRI T3 起始记录中已定位的 10 字节 source 字段，即 68 字节头内偏移 `+0x12`。较短标签右侧补空格；8 位 Source ID 的标签正好占满 10 字节，例如 `ID12345678`。Bridge 不查询呼号数据库；这个标签用于显示数字身份，不是经核实的无线电呼号。

该字段更新属于每通来话的核心路径，程序会自动处理每个已接受来话，不提供用户切换开关。T3/T0 仍用于现有 HRI 呼叫起始和收尾流程，语音内容保持现有 PCM 下行；身份字段不会改变接收目标、本机身份或 RF 路由。当前 Native 状态 JSON 的 `lcd_source_identity` 对象含 `prepared`、`source_id`、`receive_generation`、`label` 和 `display`。未准备时前三项中的布尔和数字字段为 false/0，标签为空；`display` 固定为 `unknown`，直到实际观察屏幕。

Source ID 取自已接受的 DMR 来话状态，不会自动转成呼号。`current_call_link_control_validated` 与 `lcd_source_identity.source_id` 分开保留；如果语音同步先使 pipeline 接受来话、完整 LC 尚未验证，Native 仍按该来话的外层 Source ID 生成标签。WPF 分别显示当前来话信息、HRI 来源标签状态和 LC 校验结果。

Native 在通话收尾、接收取消、T3 启动超时、网络丢失、运行异常和进程退出路径清空身份元数据；新 run 从空状态开始。WPF 读取 `lcd_source_identity` 并显示准备好的数字标签或当前状态。Native 与 WPF 的 `display=unknown` 表明尚未观察到电台屏幕结果；T3/T0 状态记录和桌面标签不会确认 FTX-1 已显示或已清除字段。

## 版本与验证状态

R98 的已提交源码 `fef55067164e1ac12b410b5199db68546d78bc76` 使用默认关闭的开关构造单通 Source ID 标签。R100 提交将其改为每通已接受来话都执行的核心处理，并移除了该 Native 与 PowerShell 开关。R98 clean build 的 35 项测试和 COM999 状态 smoke 保留为旧实现的历史结果；它们没有验证 R100 的默认来话映射。

R98 的默认关闭开关和 COM999 smoke 是历史实现及验证记录。R100 将标签改为每通已接受来话自动生成，并移除了 Native 与 PowerShell 的实验开关；后续 R101 加入 WPF 状态显示。alpha.2 发布包仍保留其发布时的功能范围，本节描述的是后续源码演进，不用它推断某个发布包已包含后续变更。

R100 clean build 通过 35 项 C++ 测试，compiler/linker warning/error 为 0。构建目录为 `build/_work/wirex-bridge-ddeee31-20261026-191001`，正式构建日志为 `build/_work/r100-ddeee31-build.log`，EXE SHA-256 为 `0060826d02433a6fe90c7d57f631e6991cec7f07eb6d4b2a7cadf28a8ebe9649`。COM999 smoke 目录为 `build/_work/r100-lcd-source-identity-smoke-1f558b50b3fa4d7591f4ae5045cabe06`：两条实际 Native JSON 事件均包含空闲身份对象（`prepared=false`、`source_id=0`、`receive_generation=0`、`label=""`、`display="unknown"`），没有 `lcd_experiment`。Native 以预期退出码 2 报告串口打开失败；HRI 串口、WaveIn/WaveOut 保持关闭，TX/RX/control 计数均为 0。该 smoke 只核验默认启动状态 JSON 和 COM999 失败路径，未验证来话映射。测试使用 loopback 地址 `127.0.0.1`、仅查询音频格式，并使用已删除的临时合成密码文件；COM999 测试前确认不存在，未打开音频流或串口，也未发送 UDP。两条记录及结果摘要保存在该目录的 `native-status.jsonl` 和 `result.txt`。每通已接受来话的 10 字节 `ID` 标签与 `source_id`、`receive_generation` 对应关系，以及 LC 状态独立保留、通话结束/取消/T3 启动超时/断网/异常/新 run 清理，由 R100 pipeline 与 BM loopback 离线测试覆盖；原 PCM 语音与 T0 收尾也保留在测试范围内。R101 WPF 已加入来源标签状态显示；小工作区渲染复核通过。实际电台显示仍需最终设备联测。

## 桌面状态与运行日志

WPF 从当前 Native 状态记录读取 `lcd_source_identity`。准备完成时，界面显示数字 Source ID 标签及“已准备”；没有标签、状态过期或进程结束时，界面清除旧标签并显示对应状态。界面另显示“FTX-1 屏幕：未知”，直到最终设备联测观察到实际屏幕内容。

开始新运行前，界面会清理可确认已结束的旧运行目录，最多保留 10 个目录且总量不超过 50 MiB。清理跳过当前运行目录、状态文件不完整或无法确认已结束的目录。当前 Native run 的 `status.jsonl` 不受此保留上限约束，长时间运行时仍可能继续增长。

## 最终合并联测

设备联测集中进行，不作为继续其他软件功能的前置条件。测试 Source ID 标签时，FTX-1 进入 WIRES-X HRI 界面并设为 DIRECT；关闭官方 WIRES-X 和其他 Bridge，确认 COM5 由 Bridge 独占，手咪 PTT 保持松开。先用 `listen-91` 被动收听一通来话，记录实际 Source ID、LC 校验状态、桌面身份标签、FTX-1 屏幕文字及通话结束后的屏幕变化。只按实物观察记录 LCD 结果。

TG91 阶段只收听，不按 PTT、不发送语音。双向回声只在最终联测中使用 BM Parrot 目标。R100 当前没有 C4FM RF 节点或 BM→RF 发射功能；RF 功能仍需独立实现和后续验收。本轮没有执行设备步骤。
