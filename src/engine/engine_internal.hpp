#pragma once

// Engine 内部共享状态：命令队列、事件队列、快照指针。只由 engine.cpp / engine_loop.cpp 使用。

#include "wirex/engine.hpp"
#include "wirex/engine_devices.hpp"
#include "wirex/engine_diagnostics.hpp"
#include "wirex/hri_stream_session.hpp"

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace wirex::engine::detail {

inline constexpr std::size_t event_queue_capacity = 1024U;

// 有界事件队列；不加锁，由 Shared::mutex 保护。溢出时丢弃最旧事件，下次 drain 先返回一条 warning。
class EventQueue final {
public:
    void push(Event event);
    [[nodiscard]] std::vector<Event> drain(std::size_t max);
    [[nodiscard]] std::size_t size() const noexcept { return events_.size(); }
    [[nodiscard]] std::uint64_t dropped_total() const noexcept { return dropped_total_; }

private:
    std::deque<Event> events_{};
    std::uint64_t dropped_pending_{};
    std::uint64_t dropped_total_{};
    std::uint64_t last_at_ms_{};
};

enum class CommandKind : std::uint8_t {
    set_bm_connection,
    configure_bm,
    connect_radio,
    disconnect_radio,
    replace_rx_policy,
    replace_tx_policy,
    quick_call_join,
    set_audio_gains,
    set_audio_endpoints,
    upsert_radio_identity,
    manual_ptt_toggle,
};

struct Command {
    CommandKind kind{};
    bool flag{};                                   // enabled / transmit_enabled
    std::uint64_t revision{};
    std::uint32_t first{};                         // source_id / radio gain
    std::uint32_t second{};                        // mic gain
    AudioEndpoints audio_endpoints{};
    std::optional<RadioStartConfig> radio_config{};
    std::optional<BmTarget> bm_target{};
    talkgroup_routing::RxPolicy rx_policy{};
    talkgroup_routing::TxTarget tx_target{};
    talkgroup_routing::GroupRoute group{};
    std::optional<std::string> callsign{};
    std::promise<CommandResult> promise{};
};

struct StopRequest {
    bool requested{};
    bool immediate{};
    std::string failure_reason{};
};

struct Shared {
    explicit Shared(std::shared_ptr<Devices> device_factory) : devices(std::move(device_factory)) {}

    std::shared_ptr<Devices> devices;
    std::mutex mutex{};
    std::condition_variable loop_cv{};     // 唤醒引擎循环（新命令或停止请求）
    std::condition_variable done_cv{};     // 引擎线程结束
    std::deque<Command> commands{};
    EventQueue events{};
    std::shared_ptr<const Snapshot> snapshot{std::make_shared<const Snapshot>()};
    std::uint64_t snapshot_seq{};
    std::function<void()> wakeup{};
    bool accepting{};                      // 引擎线程存活且接受命令
    bool thread_done{true};
    StopRequest stop{};
    std::vector<std::promise<CommandResult>> stop_promises{};
    std::optional<std::promise<CommandResult>> start_promise{};

    // 以下方法均自行加锁；wakeup 在锁外调用且吞掉异常。
    void publish(Snapshot next);
    void push_event(Event event);
    void resolve_start(CommandResult result);
    [[nodiscard]] std::deque<Command> take_commands();
    [[nodiscard]] StopRequest stop_state();
    void notify_wakeup() noexcept;
};

// BM 密码可能保存在尚未处理的命令中。兑现拒绝结果前先擦除命令中的密码。
[[nodiscard]] bool wipe_secret(std::string& secret) noexcept;
[[nodiscard]] bool wipe_command_secret(Command& command) noexcept;
[[nodiscard]] bool resolve_rejected_command(Command& command, CommandResult result) noexcept;

// 引擎线程主体。返回最终结果；所有 promise 由调用方（线程入口）兑现。
[[nodiscard]] CommandResult run_loop(Shared& shared, StartConfig config);

[[nodiscard]] const char* bm_failure_name(bm::Failure failure) noexcept;
[[nodiscard]] const char* bm_input_result_name(bm::InputResult result) noexcept;
[[nodiscard]] const char* ptt_level_name(hri_session::PttLevel level) noexcept;
[[nodiscard]] const char* media_owner_name(talkgroup_routing::MediaOwner owner) noexcept;
[[nodiscard]] const char* receive_media_state_name(bm_voice::RxState state) noexcept;
[[nodiscard]] const char* receive_end_reason_name(dmr_call::CallEndReason reason) noexcept;
[[nodiscard]] const char* hri_stream_phase_name(hri_stream_session::Phase phase) noexcept;

} // namespace wirex::engine::detail
