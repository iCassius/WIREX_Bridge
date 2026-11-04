#pragma once

// 进程内桥接引擎 API（R128 起）。替代 control-v2 匿名管道 + status.jsonl 轮询：
// - UI 线程通过 Engine 的方法投递命令，结果以 std::future 返回；
// - 引擎线程在状态变化时发布不可变 Snapshot，UI 每帧调用 snapshot() 取最新值（无锁读开销仅一次 shared_ptr 拷贝）；
// - 离散事件（来话开始/结束、日志）进入有界事件队列，UI 每帧 drain_events()。
// 引擎语义与原 run_bm_bridge 一致；旧 --ui-pipe 入口成为本 API 之上的管道适配层。

#include "wirex/bm_session.hpp"
#include "wirex/dmr_call.hpp"
#include "wirex/engine_diagnostics.hpp"
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

struct BmTarget {
    std::string master_host{};             // IPv4 或主机名；引擎线程内解析
    std::uint16_t master_port{62031U};
    bm::Profile profile{};                 // 含密码；引擎持有期间负责擦除
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

    // R128 增补（只增不改）：
    // 已在调用方解析好的 Master 地址；bm_start_disconnected=false 时优先使用，省略则在引擎线程有界解析。
    std::optional<bm::Endpoint> resolved_master{};
    // CLI 键盘诊断模式（原 --manual-ptt）：PTT 由 manual_ptt_toggle() 驱动，运行窗口限 120 s。
    bool manual_ptt{false};
    // 原始诊断钩子（status.jsonl 兼容输出、控制台提示、收尾通知）；GUI 可留空。
    DiagnosticsHooks diagnostics{};
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
};

struct Snapshot {
    std::uint64_t seq{};                   // 每次发布 +1
    // 本次运行起点（steady_clock::time_since_epoch 毫秒）。CallInfo::started_ms 与 Event::at_ms 都是相对它的毫秒数；
    // 显示墙钟时间时用 clock_origin_ms + at_ms 与 steady_clock::now() 比较。
    std::uint64_t clock_origin_ms{};
    Phase phase{Phase::stopped};
    std::string failure_reason{};          // phase==failed 时的机器可读原因
    bool serial_open{};
    std::wstring hri_port{};                // 本次运行实际打开的 HRI COM 端口
    bool hri_ready{};
    bool wave_in_open{};
    bool wave_out_open{};
    std::wstring wave_in_endpoint_id{};
    std::wstring wave_out_endpoint_id{};
    std::uint64_t audio_endpoints_revision{};
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

    // R128 增补（只增不改）：原 control-v2 status / routing.status 需要的原始状态。
    bm::State bm_state{bm::State::stopped};
    hri_session::Phase hri_phase{hri_session::Phase::not_started};
    bool bm_transport_open{};
    bool bm_resolving{};
    std::string routing_json{};            // routing_state::routing_json 视图；未启用路由时为空
    // failure_reason 在 phase==stopping 且本次运行已失败时也会填写（有界收尾进行中）。
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
};

struct Event {
    EventKind kind{};
    std::uint64_t at_ms{};
    std::optional<CallInfo> call{};        // rx_call_* 事件
    std::string end_reason{};              // rx_call_ended: terminator/watchdog/...
    std::string text{};
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

    std::future<CommandResult> set_bm_connection(bool enabled, std::uint64_t expected_revision);
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

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace wirex::engine
