# RF 节点功能实现计划

状态：方案与证据边界，2026-10-26。本文只依据本机保存的官方 FTX-1 WIRES-X 手册、WIRES-X 2.010 CHM、已保存的静态研究和当前源码整理；没有启动官方客户端、打开 COM/CAT/音频设备、连接 BrandMeister、操作电台或发射 RF。

## 当前结论

FTX-1 手册把 Node Mode 分成三项：`AP RADIO` 可使 FTX-1 作为 standalone access point；`AP PC` 是电脑连接 FTX-1 后以 C4FM 进行空中通信；`DIRECT` 经连接的电脑使用 FTX-1，手册明确写明该模式不经空中发送或接收。默认值是 `AP RADIO`。手册没有进一步定义 AP RADIO 下电脑使用哪条路径，也没有给出 Bridge 的 BM 语音如何进入射频链路；同样没有说明另一个 VFO 在 DIRECT 下是否仍可普通接收。

用户实测补充：145.1 MHz 的 RF 音频和 S 表信号是在 Bridge 已关闭后观察到。此事实不能用于声称 Bridge 运行时仍在接收，也不能独自解释 DIRECT 模式与观察结果的关系。后续功能不得从该观察推导 RF 音频已经进入 USB、RF 发射已经可控，或 Bridge 可以安全切换 Node Mode。

当前软件可以把 BM 音频送到 FTX-1 的指定 USB WaveOut，并能从指定 USB WaveIn 采集上行音频；HRI 的 Y0 就绪和物理 PTT 观测门控现有 BM 上行。源码没有证明这条 WaveOut 会使射频发射，也没有证明 WaveIn 包含普通 RF 接收音频或有对应的接收忙/静噪信号。因而当前可实施范围是纯软件的 RF 路由策略与状态显示；在输入与发射通路各自完成验证前，不开放 RF→BM 自动转发或 BM→RF 发射。

## 证据与可依赖边界

| 来源 | 已确认内容 | 不可据此推断 |
|---|---|---|
| FTX-1 WIRES-X 官方手册 2603-B，第 29 页 | `AP RADIO`、`AP PC`、`DIRECT` 的文字定义、默认值及面板 Node Mode 设置位置。抽取文本见 `firmware/analysis/pdf-text/FTX-1_WIRES-X_ENG_2603-B.txt`；PDF 在 `firmware/docs/FTX-1_WIRES-X_ENG_2603-B.pdf`。 | 手册没有说明 BM、Bridge、USB WaveIn/WaveOut 的 RF 路由，也没有说 DIRECT 下的另一 VFO 状态。不可把一个用户观察判定为模式错误。 |
| WIRES-X 2.010 CHM：`research/rea/wiresx-chm-static/html/Transceiver.html` | Voice CH 使用 WIRES-X 经 Internet；FTX-1 可用 USB 直接连接 PC。帮助还把 PDN 数字工作与 HRI/FTX-1 支持路径分开描述。 | 官方 WIRES-X 客户端的 Voice CH 不等同于外部 BM DMR 到 FTX-1 的 RF 桥接。 |
| WIRES-X 2.010 CHM：`research/rea/wiresx-chm-static/html/AudioAdj.html` | 帮助区分模拟音频电平与数字语音；不使用 HRI-200 时，WIRES-X 软件不调音量并指向 Windows 音量设置。 | 这不是 Bridge 的音量或音频路径说明，也不能标注 FTX-1 哪个 USB 端点承载普通 FM 接收。 |
| [`WIRESX屏幕与路由软件研究.md`](WIRESX屏幕与路由软件研究.md) 与配套 REA 记录 | HRI DLL 的 `DGKEY_NUM_NDDIRECT` 控件路径只证明 PC DigiPanel 的 `Direct:OFF/ON` 和内部 Y 字符候选一致；尚无证据把它映射到 FTX-1 的三态 Node Mode 或 RF 开关。 | 不把该布尔字段当成 Node Mode，不用它自动写入 RF 模式。 |
| 当前源码 `src/probe_main.cpp` | `process_ptt_observation` 接受已确认 Y0 后的 HRI PTT 事件；新 BM 上行调用 `radio_input.open`，读取 PCM 并交给 BM pipeline。BM 下行在 HRI 播放许可后取 PCM，送到 `radio_output` 的 WaveOut。 | `radio_input`、`radio_output` 是 USB 音频端点角色名，不等于已经证明的 RF RX/TX 角色。HRI T 控制记录、WaveOut 完成和 PTT 观测都不单独证明射频发射或接收。 |
| 用户本轮补充观察 | Bridge 关闭后，145.1 MHz 有 RF 音频且 S 表有信号。 | 未观察 Bridge 运行期间的接收状态；没有据此确认接收音频进入 PC 或 BM，也没有做发射验证。 |

本地 CAT 研究把 `EX010706` 列为 Node Mode 查询候选，但数值与标签尚未完成全值域验证；一条历史只读回包不足以建立完整映射。公开 CAT 手册也没有列出 WIRES-X Node Mode 的可写命令。实现不得依候选值自动切换模式、发射或恢复设置。详见外层 `research/planning/R17_CAT官方能力与手动配置.md` 与 `R18_CAT菜单映射与自动配置边界.md`。

## RF 路由策略模块的落地顺序

目标是把射频规则与 HRI/BM 传输层隔离在一个纯函数策略模块中。为避免模块只有硬编码拒绝分支，先从官方控制/接收路径恢复真实状态输入，再按证据实现决策；模块不得自己构造 CAT、HRI、USB 音频或 PTT 帧。

策略接口候选：

```cpp
enum class NodeMode { unknown, ap_radio, ap_pc, direct };
enum class RfPath { receive_to_bm, bm_to_rf };
enum class RfDecision { deny, allow_receive_forward, allow_transmit };
enum class RadioRfState { unknown, idle, receiving, transmitting };
enum class AudioRouteState { unknown, rf_rx_to_usb_verified, bm_to_radio_usb_verified };
enum class RfDenyReason {
    mode_unknown, mode_stale, mode_path_unresolved,
    rx_source_unverified, rx_busy_unknown,
    tx_path_unverified, radio_tx_state_unknown,
    session_not_ready, half_duplex_conflict,
    operator_disabled
};

struct RfRouteInputs {
    NodeMode node_mode;
    bool node_mode_fresh;
    RadioRfState rf_status;            // 由已证明的状态输入适配器生成
    AudioRouteState audio_route;       // 由已证明的 RF↔USB 音路生成
    bool bm_call_active;
    bool receive_forward_enabled;
    bool bm_to_rf_enabled;
};
```

其中 `RadioRfState` 和 `AudioRouteState` 必须来自能对应到官方软件/设备状态字段的真实 provider；若字段含义仍未知，就不创建能把该未知字段强制归类为 RX/TX 的适配器。首轮应先追清[外层 RF 路由研究报告](../../research/rf/RF路由官方资料与实现边界.md)中的官方路径，再决定这些类型的字段。

决策规则：

1. 任一必需状态未知、过期或矛盾时返回 `deny`，并保留具体拒绝原因。
2. 已确认处于 `DIRECT` 时，Bridge 不生成经电台空中发射的决策；按手册，该 PC 路径不经空中收发。手册没有说明另一个 VFO 的普通 RF 接收，继续单独标成未知；不能自动改成 `AP PC`。
3. `AP RADIO`、`AP PC`、`DIRECT` 各自可允许的 BM 业务动作要依据官方软件实际数据流和设备状态来定；`AP RADIO` 的 standalone access point 定义没有说明电脑路径，`AP PC` 的 WIRES-X C4FM 说明也不等于任意 BM DMR 语音会由 FTX-1 发射。
4. RF→BM 需要真实 RF 接收 busy/squelch 事件与对应 USB 输入音频。HRI 手咪 PTT 相关状态不能直接代替 RF 接收 busy 触发器；如果官方接收链能提供状态与音频相关路径，策略应使用恢复出的状态，而不是用音量阈值猜开关。
5. BM→RF 需要恢复发射键控和退出路径。当前不应根据 CAT `TX1`、未经确认的 HRI 记录或 WaveOut 成功试发；先从官方静态路径确立键控调用的输入/输出语义，再单独安排受控验证。
6. 对同一台 FTX-1 实施半双工仲裁。模块在已知 RF TX、BM 下行与射频操作冲突或状态不全时作出可解释决策；项目没有第二台 C4FM 电台，不假设存在独立 RF 收发链。

模块返回示意：

```cpp
struct RfRouteResult {
    RfDecision decision;
    RfPath path;
    RfDenyReason reason;
};
```

UI 只展示有对应数据源的状态，并分别显示 RF 状态和 BM/HRI 状态。`BM 已连接`、`HRI ready`、有 PCM 或音量条跳动，均不得自动把 UI 状态提升为 RF 收发已验证。

## 分阶段实现与验收

### 阶段 A：恢复官方实现边

- 沿 `SendTrcvPttCmd → HRI内部状态/队列 → EXE 消息 0x618 → WriteFile` 查明官方软件 PTT 的真实输入值、输出记录消费者及其与 FTX-1 RF Node Mode 的关系。
- 并行沿 EXE 串口接收缓冲解析器查找官方返回的 RF RX busy/squelch、TX 状态或模式状态字段；只有字段类型和值域闭合后，才把它们适配为策略输入。
- 依据恢复出的真实输入实施独立、无 I/O 的 `rf_route_policy`，用合成状态测试模式、收发冲突、PTT 上/下沿、状态过期和退出条件。测试不使用真实 HRI 帧或运行记录正文。
- UI 分开展示已恢复且有 provider 的 Node Mode 来源/新鲜度、RF RX busy、RF audio path、RF TX 状态和 BM/HRI 会话。尚无 provider 的字段明确显示未知。

### 阶段 B：只读 RF 接收观察

先由主会话安排有边界的实机计划。记录用户面板看到的 Node Mode、当前 VFO/频率/模式、Bridge 进程时间、S 表和音频出现时间；如使用 CAT，仅采用已经批准的只读命令，保存脱敏后的原始状态摘要。音频采集只在明确核对目标 USB endpoint 后进行，写入 null sink，不保存录音。此阶段不得发射或切换 Node Mode。

通过门槛：有独立证据证明哪个 USB 输入携带普通 RF 接收语音，并且能将它与频率、RF busy/squelch 或 S 表状态按时间关联。仅有低电平、设备能打开、手咪按下或用户在 Bridge 关闭后听到声音，不满足门槛。

### 阶段 C：RF→BM 接收转发

在阶段 A 的官方 receiver/parser 路径与阶段 B 的输入音频关联具备证据后，将 RF PCM source 接到现有 BM uplink pipeline。触发条件来自已恢复并验证的 RF RX/busy 信号，而不是 HRI PTT。首轮接收-only、限时并设置 call-end/静噪超时；BM 帧、呼叫目标、时隙过滤沿用已验证配置。任何 source 身份或 busy 状态丢失都停止转发。

### 阶段 D：BM→RF 发射

当前缺少足以实现此阶段的已恢复协议与状态关系。下一步先沿官方 PTT 记录的生产者、serial consumer 和 FTX-1 状态响应字段继续静态追踪，确认从 BM PCM 到 FTX-1 RF TX 的真实音频编码、键控来源、按下/释放动作、超时、错误和清台路径，再把这些结果映射到纯策略模块。进入射频验证时还需明确目标频率、模式、功率、DG-ID 和测试窗口。验收应使用受控 RF 接收观察确认实际发射和停止，不以 `WaveOut` 成功、HRI T0 收到、CAT `TX` 状态或界面显示代替。

## 当前交接

alpha2 可先推进官方 PTT/串口收发路径的静态恢复与有证据的数据类型，再实现与 UI 分离的纯 RF route policy。RF→BM 的 RF 音频源/busy 语义仍待官方路径分析和受控设备验证；BM→RF 的射频键控协议与停止证据尚未恢复。LCD 协议与 UI/屏幕字段由另一个研究任务继续，本计划不将 HRI PC 面板或当前 UI 显示说成 FTX-1 LCD。
