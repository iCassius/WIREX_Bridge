#pragma once

// 进程内桥接引擎 API（R128 起）。替代 control-v2 匿名管道 + status.jsonl 轮询：
// - UI 线程通过 Engine 的方法投递命令，结果以 std::future 返回；
// - 引擎线程在状态变化时发布不可变 Snapshot，UI 每帧调用 snapshot() 取最新值（无锁读开销仅一次 shared_ptr 拷贝）；
// - 离散事件（来话开始/结束、日志）进入有界事件队列，UI 每帧 drain_events()。
// 引擎语义与原 run_bm_bridge 一致；旧 --ui-pipe 入口成为本 API 之上的管道适配层。

#include "wirex/bm_session.hpp"
#include "wirex/bm_local_playback.hpp"
#include "wirex/dmr_call.hpp"
#include "wirex/engine_diagnostics.hpp"
#include "wirex/hri_y_body.hpp"
#include "wirex/talkgroup_routing.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <future>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wirex::engine {

class Devices;  // wirex/engine_devices.hpp（R128 增补）

// ---------- 启动配置 ----------

struct AudioEndpoints {
    unsigned wave_in_id{};                 // WinMM 设备编号（由 endpoint id 解析得到）
    unsigned wave_out_id{};
    std::wstring expected_wave_in_endpoint_id{};   // MMDevice endpoint id；打开前核对，防止编号漂移
    std::wstring expected_wave_out_endpoint_id{};
};

// 电台端点的独立配置。BM runtime 可以先运行；该配置只用于显式连接 HRI/USB Audio。
struct RadioStartConfig {
    std::wstring hri_port{};
    std::filesystem::path hri_body_file{};
    AudioEndpoints audio{};
    // R130 增补（只增不改）：AP PC 模式（中继开启时）。hri_body_file 为空时使用 offset 0x05 为 '1' 的内嵌 AP 变体，
    // 非空时文件须为 DIRECT 或 AP 两个已批准哈希之一；HRI 会话按此接受 '2' 或 '1'。
    bool ap_mode{false};
    // 首条周期 Y 使用的 A 通道发射功率，单位 0.1 W；省略时使用批准模板默认值 250。
    std::optional<std::uint16_t> initial_tx_power_deciwatts{};
    std::optional<std::uint32_t> initial_lch_frequency_hz{};
    std::optional<hri_y::LchMode> initial_lch_mode{};
};

struct BmTarget {
    std::string master_host{};             // IPv4 或主机名；引擎线程内解析
    std::uint16_t master_port{62031U};
    bm::Profile profile{};                 // 含密码；引擎持有期间负责擦除
    std::uint32_t local_source_id{};
    talkgroup_routing::RxPolicy rx_policy{};
    talkgroup_routing::TxPolicy tx_policy{};
};

struct StartConfig {
    std::wstring hri_port{};               // "COM5"
    std::filesystem::path hri_body_file{}; // 空路径使用内置已批准模板；非空路径可显式覆盖
    AudioEndpoints audio{};
    BmTarget bm{};
    bool bm_start_disconnected{true};      // 先接 HRI，BM 由 set_bm_connection 单独开关
    std::uint32_t local_source_id{};
    talkgroup_routing::RxPolicy rx_policy{};
    talkgroup_routing::TxPolicy tx_policy{};
    std::uint32_t radio_playback_gain_milli{1000U};  // 250..16000
    std::uint32_t mic_transmit_gain_milli{16000U};
    std::filesystem::path diagnostics_log{};          // 可空；非空时追加 JSONL 诊断（替代 status-file 的取证用途）
    // 初次启动时的 radio 结果与 BM runtime 分开。start_radio=false 时保留 Engine/BM loop，
    // radio_start_error 仅说明这次没有打开电台；不会自动尝试其它端口。
    bool start_radio{true};
    std::string radio_start_error{};
    // GUI BM-only playback can report why no unique output was configured;
    // BM runtime still starts and keeps validated incoming calls visible.
    std::string local_audio_start_error{};

    // R128 增补（只增不改）：
    // 已在调用方解析好的 Master 地址；bm_start_disconnected=false 时优先使用，省略则在引擎线程有界解析。
    std::optional<bm::Endpoint> resolved_master{};
    // CLI 键盘诊断模式（原 --manual-ptt）：PTT 由 manual_ptt_toggle() 驱动，运行窗口限 120 s。
    bool manual_ptt{false};
    // 原始诊断钩子（status.jsonl 兼容输出、控制台提示、收尾通知）；GUI 可留空。
    DiagnosticsHooks diagnostics{};
    // R130 增补：FM 中继单段最长时长（默认 relay_fm_max_duration_ms = 180 s；离线测试可调小）。0 视为默认值。
    std::uint64_t relay_fm_max_duration_ms{0U};
    // R131 增补：HRI 自动重连间隔（0 = 默认 hri_reconnect_interval_ms / hri_reconnect_max_interval_ms；离线测试可调小）。
    std::uint64_t hri_reconnect_interval_ms{0U};
    std::uint64_t hri_reconnect_max_interval_ms{0U};
    // 启动时首条 HRI Y 使用的 A 通道功率，单位 0.1 W；省略时使用 250。
    std::optional<std::uint16_t> initial_tx_power_deciwatts{};
    std::optional<std::uint32_t> initial_lch_frequency_hz{};
    std::optional<hri_y::LchMode> initial_lch_mode{};
};

// ---------- 状态快照（只读、不可变） ----------

enum class Phase : std::uint8_t { stopped, starting, running, stopping, failed };
enum class BmLink : std::uint8_t { disabled, resolving, connecting, connected, backoff, failed };

struct CallInfo {
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    std::string callsign{};                // 身份缓存命中时填写
    std::uint64_t started_ms{};            // 引擎单调时钟
};

struct AudioLevels {
    float rx_peak{};                       // 0..1，最近 200 ms 的输出峰值
    float tx_peak{};
    std::uint64_t rx_clipped_samples{};
    std::uint64_t tx_clipped_samples{};
};

struct Counters {
    std::uint64_t calls_started{};
    std::uint64_t calls_ended{};
    std::uint64_t rejected_calls{};
    std::uint64_t rx_datagrams{};
    std::uint64_t tx_datagrams{};
    std::uint64_t reconnects{};
    std::uint64_t ptt_tx_starts{};
    std::uint64_t ptt_tx_timeouts{};
    // BM 已送达但不在收听策略内（Router 未准入）的语音包；用于提示“有流量但未收听”。
    std::uint64_t rx_filtered_datagrams{};
    // R130 增补：FM 中继 start 因 BM 下行/HRI 下行或手咪 PTT 占用而被拒绝的次数。
    std::uint64_t relay_fm_rejected_busy{};
};

// BM 网络质量：RTT 来自 RPTPING/MSTPONG 往返；丢包来自 DMRD 序号（本次 BM 会话累计 + 当前/最近一次通话）。
struct NetworkQuality {
    bool rtt_valid{};
    std::uint64_t rtt_last_ms{};
    double rtt_avg_ms{};
    std::uint64_t rtt_min_ms{};
    std::uint64_t rtt_max_ms{};
    std::uint64_t rtt_samples{};
    bool session_loss_valid{};
    std::uint64_t session_expected{};
    std::uint64_t session_missing{};
    bool call_loss_valid{};
    std::uint64_t call_expected{};
    std::uint64_t call_missing{};
};

// 最近一次被收听策略过滤的 BM 流（只用于界面提示，不参与路由）。
struct FilteredTraffic {
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    std::uint64_t last_ms{};               // 相对 clock_origin_ms
};

struct Snapshot {
    std::uint64_t seq{};                   // 每次发布 +1
    // 本次运行起点（steady_clock::time_since_epoch 毫秒）。CallInfo::started_ms 与 Event::at_ms 都是相对它的毫秒数；
    // 显示墙钟时间时用 clock_origin_ms + at_ms 与 steady_clock::now() 比较。
    std::uint64_t clock_origin_ms{};
    Phase phase{Phase::stopped};
    std::string failure_reason{};          // phase==failed 时的机器可读原因
    std::string radio_error{};             // 电台串口/HRI/USB Audio 子系统错误；BM runtime 可继续工作
    bool serial_open{};
    std::wstring hri_port{};                // 本次运行实际打开的 HRI COM 端口
    bool hri_ready{};
    bool wave_in_open{};
    bool wave_out_open{};
    std::wstring wave_in_endpoint_id{};
    std::wstring wave_out_endpoint_id{};
    std::uint64_t audio_endpoints_revision{};
    bm_local_playback::Snapshot local_audio{};
    std::string local_audio_error{};
    BmLink bm_link{BmLink::disabled};
    bool bm_requested_enabled{};
    std::uint64_t bm_connection_revision{};
    std::string bm_error{"none"};
    talkgroup_routing::MediaOwner media_owner{talkgroup_routing::MediaOwner::idle};
    std::uint64_t rx_policy_revision{1U};
    std::uint64_t tx_policy_revision{1U};
    talkgroup_routing::TxTarget tx_target{};
    std::optional<CallInfo> active_rx_call{};
    bool tx_active{};
    std::uint32_t radio_playback_gain_milli{1000U};
    std::uint32_t mic_transmit_gain_milli{16000U};
    std::uint64_t audio_gains_revision{};
    AudioLevels levels{};
    Counters counters{};
    std::optional<FilteredTraffic> last_filtered{};
    NetworkQuality network{};

    // R128 增补（只增不改）：原 control-v2 status / routing.status 需要的原始状态。
    bm::State bm_state{bm::State::stopped};
    hri_session::Phase hri_phase{hri_session::Phase::not_started};
    bool hri_t3_record_observed{};
    bool hri_t0_record_observed{};
    bool bm_transport_open{};
    bool bm_resolving{};
    std::string routing_json{};            // routing_state::routing_json 视图；未启用路由时为空
    // failure_reason 在 phase==stopping 且本次运行已失败时也会填写（有界收尾进行中）。

    // R130 增补（只增不改）：FM 中继上行（CAT 静噪触发，经 WaveIn → AMBE → BM）。
    bool relay_fm_active{};
    std::uint64_t relay_fm_started_ms{};   // 相对 clock_origin_ms；relay_fm_active=false 时为 0

    // R131 增补（只增不改）：按组静音输出。set_muted_groups 集合变化时 +1。
    std::uint64_t muted_groups_revision{};
    // R131 增补（只增不改）：
    bool relay_fm_muted{};                 // 中继段内 relay_fm_mute(true) 生效中（上行送静音）
    // HRI 掉线（串口错误、Y/0 超时、会话异常停止）后按 connect_radio 时的配置自动重连；用户断开即停止。
    bool hri_reconnecting{};
    std::uint64_t hri_reconnect_attempts{};  // 本轮自动重连已尝试次数（下一轮掉线时清零）
    // 当前已装入会话、尚未被下行锁定延后的 Y 功率。
    std::uint16_t hri_y_tx_power_deciwatts{250U};
    bool hri_y_tx_power_pending{};
    std::uint32_t hri_y_lch_frequency_hz{hri_y::default_lch_frequency_hz};
    hri_y::LchMode hri_y_lch_mode{hri_y::LchMode::fm};
    bool hri_y_channel_pending{};
};

// FM 中继单段上行的最长时长；超时后引擎自动结束本段（end_reason "timeout"）。
inline constexpr std::uint64_t relay_fm_max_duration_ms = 180000U;

// R131：FM 中继上行在 WaveIn 与 AMBE 管线之间的前瞻延迟。relay_fm_mute(true) 到达时缓冲内尚未送出的样本一并清零，
// 用来覆盖 CAT 静噪检测（约 100 ms 轮询）之前已采集到的尾噪。只用于 FM 中继，手咪 PTT 不经过该缓冲。
inline constexpr std::uint64_t kRelayLookaheadMs = 120U;

// R131：HRI 自动重连。串口可打开时按固定间隔重试握手；串口打开失败（设备拔出）逐次加倍退避到最长间隔。
inline constexpr std::uint64_t hri_reconnect_interval_ms = 3000U;
inline constexpr std::uint64_t hri_reconnect_max_interval_ms = 10000U;

// R131：电台 WaveOut 重开失败后的退避（200 ms、500 ms、1 s、2 s、4 s、5 s…）。
// 同一 USB 声卡的 WaveIn 关闭后，空闲预重开至少等待 radio_output_after_input_close_settle_ms。
inline constexpr std::uint64_t radio_output_retry_initial_ms = 200U;
inline constexpr std::uint64_t radio_output_retry_max_ms = 5000U;
inline constexpr std::uint64_t radio_output_after_input_close_settle_ms = 300U;

// relay_fm_started / relay_fm_ended 事件附带的信息。
struct RelayFmInfo {
    talkgroup_routing::TxTarget target{};  // 本段使用的 tx_policy 目标
    std::uint64_t started_ms{};            // 相对 clock_origin_ms
    std::uint64_t duration_ms{};           // relay_fm_ended：开始到结束请求的时长；started 时为 0
};

// ---------- 离散事件 ----------

enum class EventKind : std::uint8_t {
    rx_call_started,
    rx_call_ended,
    tx_started,
    tx_ended,
    bm_link_changed,
    quick_call_result,
    warning,      // 可恢复问题；text 为中文源文案（UI 负责翻译）
    fatal,        // 引擎即将进入 failed
    // R130 增补（只增不改，追加在末尾）：
    relay_fm_started,
    relay_fm_ended,  // end_reason: squelch_closed / timeout / transmit_disabled / bm_not_ready / radio_lost / aborted / shutdown
    // R131 增补（只增不改，追加在末尾）：
    hri_lost,      // HRI 掉线并开始自动重连；end_reason 为机器可读原因（如 hri_y_ack_timeout、serial_transport_error）
    hri_restored,  // 自动重连成功（Y/0 已确认，hri_ready 恢复）
};

struct Event {
    EventKind kind{};
    std::uint64_t at_ms{};
    std::optional<CallInfo> call{};        // rx_call_* 事件
    std::string end_reason{};              // rx_call_ended: terminator/watchdog/...；relay_fm_ended 见上
    std::string text{};
    std::optional<RelayFmInfo> relay_fm{}; // relay_fm_* 事件（R130 增补）
};

// ---------- 命令结果 ----------

enum class CommandStatus : std::uint8_t {
    accepted,
    idempotent,
    stale_revision,
    busy,
    not_ready,
    invalid,
    forbidden,
    failed,
};

struct CommandResult {
    CommandStatus status{CommandStatus::failed};
    std::uint64_t revision{};              // 生效后的 revision（policy/gains/bm connection）
    std::string detail{};                  // 机器可读原因
};

// ---------- 引擎 ----------

class Engine final {
public:
    Engine();
    ~Engine();                             // 若仍在运行：请求停止并有界等待（≤5 s）
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    // 打开 HRI/音频并启动引擎线程。已在运行时返回 busy。
    std::future<CommandResult> start(StartConfig config);
    // 有界停止：BM 先发 RPTCL，HRI T0 收尾，关闭音频与串口。
    std::future<CommandResult> stop();

    // requested_revision 是本次请求的新 revision（初始快照 0 时首次请求传 1）。
    std::future<CommandResult> set_bm_connection(bool enabled, std::uint64_t requested_revision);
    std::future<CommandResult> configure_bm(BmTarget config);
    std::future<CommandResult> connect_radio(RadioStartConfig config);
    // 更新下一条 HRI Y 的 A 通道发射功率，单位 0.1 W。
    std::future<CommandResult> set_hri_tx_power(std::uint16_t deciwatts);
    std::future<CommandResult> set_hri_channel(std::uint32_t lch_frequency_hz, hri_y::LchMode mode);
    std::future<CommandResult> disconnect_radio();
    std::future<CommandResult> replace_rx_policy(std::uint64_t expected_revision,
                                                 talkgroup_routing::RxPolicy policy);
    std::future<CommandResult> replace_tx_policy(std::uint64_t expected_revision,
                                                 talkgroup_routing::TxTarget target,
                                                 bool transmit_enabled);
    std::future<CommandResult> quick_call_join(talkgroup_routing::GroupRoute route);
    std::future<CommandResult> set_audio_gains(std::uint32_t radio_playback_gain_milli,
                                               std::uint32_t mic_transmit_gain_milli);
    std::future<CommandResult> set_audio_endpoints(AudioEndpoints audio);
    std::future<CommandResult> upsert_radio_identity(std::uint32_t source_id, std::uint64_t revision,
                                                     std::optional<std::string> callsign);

    [[nodiscard]] std::shared_ptr<const Snapshot> snapshot() const;
    // 取出最多 max 条事件；队列上限 1024，溢出时丢弃最旧并计入 warning。
    [[nodiscard]] std::vector<Event> drain_events(std::size_t max = 256U);

    // UI 可注册唤醒回调（例如 PostMessage 唤醒消息循环）；在引擎线程调用，必须非阻塞。
    void set_wakeup(std::function<void()> wakeup);

    // ---------- R128 增补（只增不改） ----------
    // 注入设备实现（离线测试用假设备）；nullptr 等同默认的 Windows 设备。
    explicit Engine(std::shared_ptr<Devices> devices);
    // 与 stop() 相同，但把非空 failure_reason 记为本次运行失败（原 ui_control_* 失败路径）。
    std::future<CommandResult> stop_with_reason(std::string failure_reason);
    // 跳过剩余的有界媒体收尾，立即释放资源（原控制台关闭等待超时路径）。非阻塞。
    void force_stop_now(std::string failure_reason);
    // 有界等待引擎线程结束（结束则回收线程）；超时返回 false，可再次调用。
    [[nodiscard]] bool wait_stopped(std::chrono::milliseconds timeout);
    // 键盘诊断模式（StartConfig::manual_ptt）：等价于原 T 键。
    std::future<CommandResult> manual_ptt_toggle();

    // ---------- R130 增补（只增不改）：FM 中继 ----------
    // 开始一段 FM 中继上行：复用手咪 PTT 上行管线（WaveIn → 增益 → AMBE → DMRD → BM），目标为当前 tx_policy.target。
    //   accepted；idempotent（已在中继）；busy（BM/HRI 下行进行中或手咪 PTT 上行中，detail relay_fm_busy_*）；
    //   not_ready（BM 未就绪 / 电台未就绪）；forbidden（transmit_enabled=false 或 manual_ptt 模式）。
    std::future<CommandResult> relay_fm_start();
    // 结束当前 FM 中继段（end_reason "squelch_closed"）。未在中继时 idempotent。
    std::future<CommandResult> relay_fm_stop();

    // ---------- R131 增补（只增不改）：按组静音输出 ----------
    // 整体替换静音集合（重复项合并）。只影响组呼：当前来话 kind==group 且 destination_id、slot 匹配时，
    // 播放 PCM 清零（本机 WaveOut 与 HRI 下行同经 radio_output，均不出声）；来话照常接收与发布
    // （active_rx_call、rx_call_started/ended 事件不变），不改 RX/TX 策略。
    //   accepted（集合变化，revision = Snapshot::muted_groups_revision）；idempotent（集合相同）；
    //   invalid "invalid_muted_group"（destination_id==0 或 >16777215）。
    std::future<CommandResult> set_muted_groups(std::vector<talkgroup_routing::GroupRoute> groups);
    // 向 BM 发送 TG4000 组呼 header+terminator，断开该时隙全部动态组。就绪/忙碌门控与返回码与
    // quick_call_join 完全一致（accepted；busy "media_busy"；not_ready "quick_call_not_ready"；
    // failed "quick_call_send_failed" / "quick_call_partial_send"）；结果同样推送 quick_call_result 事件。
    std::future<CommandResult> disconnect_dynamic_groups(dmr_call::Slot slot);
    // ---------- R131 增补（只增不改） ----------
    // 中继段内静音/恢复上行（静噪疑似关门/重新开门）。muted=true 时送入管线的样本清零（帧节奏不变），
    // 前瞻缓冲内尚未送出的部分一并清零；段结束自动恢复。未在中继时 idempotent（relay_fm_not_active）。
    std::future<CommandResult> relay_fm_mute(bool muted);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace wirex::engine
