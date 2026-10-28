#pragma once

#include "wirex/talkgroup_routing.hpp"
#include "wirex/strict_json.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::ui_control {

enum class Result {
    pending,
    shutdown,
    invalid
};

// WPF 管理的 native run 只接受一个大写 Q 行或输入流 EOF 作为停止请求。
class Parser final {
public:
    [[nodiscard]] Result feed(std::string_view bytes) noexcept
    {
        if (state_ == State::invalid) return Result::invalid;
        if (state_ == State::shutdown) return bytes.empty() ? Result::shutdown : invalidate();
        for (const char byte : bytes) {
            switch (state_) {
            case State::waiting_q:
                if (byte == 'Q') state_ = State::waiting_terminator;
                else return invalidate();
                break;
            case State::waiting_terminator:
                if (byte == '\n') state_ = State::shutdown;
                else if (byte == '\r') state_ = State::waiting_lf;
                else return invalidate();
                break;
            case State::waiting_lf:
                if (byte == '\n') state_ = State::shutdown;
                else return invalidate();
                break;
            case State::shutdown:
                return invalidate();
            case State::invalid:
                return Result::invalid;
            }
        }
        return state_ == State::shutdown ? Result::shutdown : Result::pending;
    }

    [[nodiscard]] Result eof() noexcept
    {
        if (state_ == State::invalid) return Result::invalid;
        state_ = State::shutdown;
        return Result::shutdown;
    }

private:
    enum class State {
        waiting_q,
        waiting_terminator,
        waiting_lf,
        shutdown,
        invalid
    };

    [[nodiscard]] Result invalidate() noexcept
    {
        state_ = State::invalid;
        return Result::invalid;
    }

    State state_{State::waiting_q};
};

inline constexpr std::size_t max_json_line_bytes = 4096U;
inline constexpr std::size_t max_cached_requests = 512U;

enum class JsonLineStatus {
    pending,
    complete,
    invalid
};

// v2 stdin 只接受有界的 JSONL 帧；控制 envelope 与标识符使用 ASCII。
class JsonLineParser final {
public:
    [[nodiscard]] JsonLineStatus feed(std::string_view bytes, std::vector<std::string>& lines);
    // EOF 有未结束帧时返回 false，调用方拒绝该帧并进入有界收尾。
    [[nodiscard]] bool eof_at_frame_boundary() const noexcept { return line_.empty() && !pending_cr_; }
    [[nodiscard]] bool invalid() const noexcept { return invalid_; }

private:
    std::string line_{};
    bool pending_cr_{false};
    bool invalid_{false};
};

struct StatusSnapshot {
    std::string mode{"running"};
    std::string status{"running"};
    std::string phase{"starting"};
    std::string bm_state{"unknown"};
    std::string hri_phase{"not_started"};
    std::string radio_state{"unknown"};
    std::uint64_t media_seq{};
    bool diagnostic{false};
    bool hri_ready{false};
    bool serial_open{false};
    bool wavein_open{false};
    bool waveout_open{false};
};

struct DispatchResult {
    std::string json_line{};
    bool shutdown_requested{false};
    bool protocol_error{false};
};

struct RoutingCallbacks {
    std::uint32_t local_source_id{};
    std::function<talkgroup_routing::PolicyUpdateResult(
        std::uint64_t, const talkgroup_routing::RxPolicy&)> replace_rx_policy{};
    std::function<talkgroup_routing::PolicyUpdateResult(
        std::uint64_t, const talkgroup_routing::TxTarget&, bool)> replace_tx_policy{};
    enum class QuickCallStatus : std::uint8_t {
        sent,
        not_ready,
        busy,
        invalid_target,
        forbidden_target,
        send_failed,
        partial_send,
    };
    struct QuickCallOutcome {
        QuickCallStatus status{QuickCallStatus::not_ready};
        std::uint8_t packets_sent{};
    };
    std::function<QuickCallOutcome(const talkgroup_routing::GroupRoute&)> quick_call_join{};
    std::function<std::string()> snapshot_json{};
};

// v2 控制分派；未提供 RoutingCallbacks 时保留协议诊断的只读首阶段能力。
class Dispatcher final {
public:
    explicit Dispatcher(std::string run_id, bool diagnostic = false,
                        RoutingCallbacks routing = {});

    [[nodiscard]] std::string ready_line(std::uint32_t process_id);
    [[nodiscard]] DispatchResult handle(std::string_view json_line, const StatusSnapshot& snapshot);
    [[nodiscard]] DispatchResult reject(std::string_view error_code);
    [[nodiscard]] std::string routing_state_line();
    [[nodiscard]] bool hello_seen() const noexcept { return hello_seen_; }
    [[nodiscard]] bool supports_routing() const noexcept { return routing_enabled_; }
    [[nodiscard]] bool supports_quick_call() const noexcept { return quick_call_enabled_; }
    [[nodiscard]] std::uint64_t control_seq() const noexcept { return control_seq_; }
    [[nodiscard]] std::size_t cached_result_count() const noexcept
    {
        return cache_.size() + (cache_full_rejection_ ? 1U : 0U);
    }

private:
    struct CachedResult {
        std::string body{};
        std::string request_id{};
        std::string command{};
        std::string result{};
        std::string extra_json{};
        bool shutdown_requested{false};
    };

    [[nodiscard]] std::string serialize_result(std::string_view request_id,
                                              std::string_view command,
                                              std::string_view result,
                                              std::string_view extra_json,
                                              bool replayed);
    [[nodiscard]] std::string serialize_rejection(std::string_view request_id,
                                                  std::string_view command,
                                                  std::string_view error_code);

    std::string run_id_{};
    bool diagnostic_{false};
    bool routing_enabled_{false};
    bool quick_call_enabled_{false};
    RoutingCallbacks routing_{};
    bool ready_emitted_{false};
    bool hello_seen_{false};
    bool shutdown_requested_{false};
    bool shutdown_slot_used_{false};
    bool cache_exhausted_{false};
    std::uint64_t control_seq_{};
    std::size_t non_shutdown_requests_{};
    std::map<std::string, CachedResult, std::less<>> cache_{};
    std::optional<CachedResult> cache_full_rejection_{};
};

} // namespace wirex::ui_control
