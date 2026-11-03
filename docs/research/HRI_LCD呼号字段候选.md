# HRI LCD 呼号字段候选

## 当前实现

新增 `--hri-lcd-identity-candidate` 作为独立实验命令。它复用已有的 8 秒以内本地 WAV 下行流程、T3/PCM 路径和原 T0 收尾。普通 `--hri-downlink-candidate` 命令与默认运行不变。

实验正文从现有 90 字节空头 mode4 起始正文生成，只覆盖用户显式选中的一个 10 字节字段：`destination`、`source` 或 `local`。输入呼号要求 1..8 个 `!` 至 `~` 的可见 ASCII 字符，不含空格且至少含一个英文字母；程序在右侧补空格到 10 字节。其他 80 个正文位置保持原值，mode4、空 AMBE 占位、五个星号和 `3033` 尾部均不变。停止正文仍使用未修改的原 T0。

命令行字段和呼号在创建串口或打开 WaveOut 流之前解析。纯变换函数还要求收到的起始正文与原 90 字节模板完全一致；它拒绝未知字段、空格、不可见或非 ASCII 字符、没有字母的纯数字文本、9 个以上字符以及 T0 正文。

## 官方软件证据与边界

WIRES-X 2.010 的 `FUN_10014b50` 空头分支生成 mode4 和空 AMBE 占位。该分支把 68 字节头填为默认值，随后构造 `00001F*****3033`。非空头分支把头部模式字节归一到 mode0..3，并要求对应的非空 AMBE 文本长度。因此本实验没有调用官方非空头构造逻辑，而是在现有 mode4 起始正文完成后只替换一个已定位的呼号字段。

`FUN_10014070` 从 68 字节头的偏移 `+8` 与 `+0x12` 读取十字节字段，并以 `DestCallSign`、`Src CallSign` 写入缓存日志。`FUN_1000d370` 把 HRI 本机呼号复制到头部偏移 `+0x1c`。这些证据定位了字段来源和宽度，没有说明 FTX-1 LCD 如何显示它们，也没有证明电台接受本实验正文。

函数依据见 [WIRES-X 屏幕与路由软件研究](WIRESX屏幕与路由软件研究.md)：空头构造函数 Evidence `ev_0b9ed8732ace5fbca14b93278f85c286ae2354053325a9da2b7c36b1e0c320b4`，呼号读取 Evidence `ev_af377ccbc045e89e9964c53d4ab86c39d7534f358fda167ec8bf64bfc7435d28`，本机呼号配置 Evidence `ev_872f6848966086fe1393376f10eb179c48305a1cb4bb8a541d52f14b9878c888`。空头 mode4 的字段/偏移 fixture 见 [R63 记录](../../../research/planning/R63_T候选空载构造与应答映射.md)。

BrandMeister 当前来话的 DMR Source ID 不是经验证的 WIRES-X 呼号，不能把 DMR 数字 ID 填进 `source` 呼号字段。为测试 LCD 字段位置，可以把本机实际配置的呼号用于 `destination`、`source` 或 `local` 任意一个位置；这只检查位置，不能称为 BM 当前远端发话者身份。后续要显示真实 BM 呼号时再接入已验证映射。程序报告只记录所选字段，不记录呼号正文。

运行报告会写入实验类型、字段名、起始正文是否已构造、T 写入计数和现有音频/串口清理结果。`lcd_display` 固定记录为 `unknown`；报告不声称电台已显示内容。没有测试台、音频硬件、COM 或 RF 验证结果。

## 命令形状

```text
wirex_bridge.exe --hri-lcd-identity-candidate --port COMn --body-file <绝对Y模板路径> --file <绝对WAV路径> --report-file <绝对报告路径> --field destination|source|local --callsign <1至8个无空格可见ASCII字符且含字母>
```

命令只使用本地 WAV，不启动 BrandMeister 会话，也不会修改停止用的 T0 正文。Y 模板、串口、WaveOut 和运行时仍由既有 bounded downlink 流程处理。

## 后续单次现场对照条件

现场对照前将电台置于 WIRES-X HRI 界面并把 Node Mode 设为 DIRECT；关闭官方 WIRES-X 和其他 Bridge，松开手咪 PTT。使用本机实际配置的呼号，每次选择一个 `destination`、`source` 或 `local` 字段；这里仅检查字段位置，不描述 BM 来话身份。按既有命令使用单个不超过 8 秒的本地固定 WAV，观察起始 T 是否只改选定的十字节字段、PCM 是否沿既有路径播放、T0 是否照常收尾。单独记录 LCD 实际显示和清除时机；软件报告里的 `unknown` 不变成成功结论。此文档本身没有执行现场测试。

## 集成与诊断候选交接

LCD 呼号字段候选由 commit `ad77d75` 加入。该版本把严格参数解析放在 `WIREX_ENABLE_BM_BRIDGE` 分支内部；release builder 生成的 `wirex_bridge.exe` 会先进入 `bm_bridge_main`，所以新命令未被调用。commit `9c47b1b` 将这个命令的严格分派移到该预处理分支之前，并保留原 BM 入口的异常保护。第一次实际检查又发现 `std::wcerr` 重定向后只写出 `--field ` 前缀；commit `7775ccf` 将候选参数、用法和异常诊断改为 ASCII `std::cerr`。

固定的 native 候选来自 clean source commit `7775ccfeeddd8aaeffa7d36503ec5ea0c8113f99`：31 项离线测试全部通过，EXE 为 782336 字节，SHA-256 `2e1bb14402166fbc101108b2e3bece6448997b90cf807817e40e3daaffa4ce5d`。四项 CLI smoke 分别检查帮助可见、无效字段拒绝、纯数字 DMR ID 拒绝，以及有效参数配缺失 Y 模板时在串口与 WaveOut 打开前退出。后者报告 `y_template_invalid`、`serial_handle=not_opened`、`audio_output=not_started`。这些结果不包括电台/LCD验证。

忽略目录 `build/candidates/lcd-identity-7775ccf/` 保存本地诊断候选。其 manifest 有 13 项文件哈希记录，加 manifest 共 14 个文件；最终 manifest SHA-256 为 `8552439fe006a31f8888734b7a365273ba15e8b732d642ba4617267e3b98c3ac`。manifest 分开记录 native source `7775ccf` 与菜单/README source `7e1b1750ec0ab6b9ea7f49cb0d7e0d31a7f2734b`。菜单还通过 Windows PowerShell 5.1 AST/六项呼号校验和合成输入后选 Q 退出检查。目录内 `reports/` 为空，未放入本机连接配置或密码；这个候选仍记录 `lcd_display=unknown`。

没有用这套候选连接 COM、音频、BM 或 RF，尚未观察 LCD 是否显示或清除字段。后续更高 commit 的 P 状态纯模块不属于 native `7775ccf` 候选；不要把它替换进本目录或将其测试结果合并到这 31 项构建记录。
