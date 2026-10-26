#pragma once

#include "wirex/direct_stream.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wirex::hri_stream_session {

inline constexpr std::uint64_t default_start_record_timeout_ms = 3000U;
inline constexpr std::uint64_t default_stop_record_timeout_ms = 500U;
inline constexpr std::uint64_t max_call_window_ms = 120000U;
inline constexpr std::size_t max_record_payload_size = 4096U;

using CandidateFrame = std::vector<std::uint8_t>;

enum class Phase : std::uint8_t {
    idle,
    start_write_pending,
    start_write_in_progress,
    awaiting_start_record,
    playing,
    draining,
    stop_write_pending,
    stop_write_in_progress,
    awaiting_stop_record,
    faulted,
};

enum class Reason : std::uint8_t {
    none,
    invalid_configuration,
    invalid_candidate_frame,
    start_write_failed,
    start_record_timeout,
    stop_write_failed,
    stop_record_timeout,
    call_window_expired,
    cancelled,
    network_lost,
    transport_failed,
};

enum class ActionKind : std::uint8_t {
    write_start_candidate,
    playback_permitted,
    cancel_playback,
    write_stop_candidate,
    call_finished,
};

struct Action {
    ActionKind kind{ActionKind::call_finished};
    std::uint64_t write_id{};
    CandidateFrame frame;
};

enum class Error : std::uint8_t {
    none,
    invalid_phase,
    invalid_write_id,
    duplicate_write_attempt,
    duplicate_write_completion,
    write_not_attempted,
    invalid_time,
    null_input,
    invalid_candidate_frame,
};

struct Config {
    std::uint64_t start_record_timeout_ms{default_start_record_timeout_ms};
    std::uint64_t stop_record_timeout_ms{default_stop_record_timeout_ms};
    std::uint64_t max_call_window_ms{wirex::hri_stream_session::max_call_window_ms};
};

struct Snapshot {
    Phase phase{Phase::idle};
    Reason reason{Reason::none};
    bool start_write_attempted{};
    bool start_write_completed{};
    bool start_write_succeeded{};
    bool start_t_record_observed{};
    bool playback_permitted{};
    bool playback_drained{};
    bool stop_write_attempted{};
    bool stop_write_completed{};
    bool stop_write_succeeded{};
    bool stop_t_record_observed{};
    bool radio_state_unknown{true};
    std::uint64_t completed_calls{};
    std::uint64_t malformed_records{};
    std::uint64_t unmatched_t_records{};
};

struct Update {
    std::vector<Action> actions;
    Snapshot state{};
    Error error{Error::none};
};

// 单条 DIRECT 下行语音的 T3/T0 门控；不访问串口、音频设备或网络。
class Session final {
public:
    Session(CandidateFrame start_candidate, CandidateFrame stop_candidate, Config config = {});

    [[nodiscard]] Update begin_call(std::uint64_t now_ms, std::uint64_t call_window_ms = max_call_window_ms);
    /// 仅用传入的 start frame 创建本通 write_start Action，不修改会话默认候选。
    [[nodiscard]] Update begin_call_with_start_candidate(
        const CandidateFrame& candidate, std::uint64_t now_ms,
        std::uint64_t call_window_ms = max_call_window_ms);
    [[nodiscard]] Update write_attempted(std::uint64_t write_id, std::uint64_t now_ms);
    [[nodiscard]] Update write_completed(std::uint64_t write_id, bool succeeded, std::uint64_t now_ms);
    [[nodiscard]] Update feed(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms);
    [[nodiscard]] Update network_ended(std::uint64_t now_ms);
    [[nodiscard]] Update playback_drained(std::uint64_t now_ms);
    [[nodiscard]] Update cancel(Reason reason, std::uint64_t now_ms);
    [[nodiscard]] Update tick(std::uint64_t now_ms);
    [[nodiscard]] Snapshot snapshot() const noexcept;

private:
    static constexpr std::uint64_t start_write_id = 1U;
    static constexpr std::uint64_t stop_write_id = 2U;

    CandidateFrame start_candidate_;
    CandidateFrame stop_candidate_;
    Config config_{};
    Snapshot state_{};
    direct_stream::Parser parser_;
    std::uint64_t call_deadline_ms_{};
    std::uint64_t record_deadline_ms_{};
    std::uint64_t last_observed_ms_{};
    bool active_call_{};
    bool stop_scheduled_{};
    bool network_ended_pending_{};

    [[nodiscard]] Update begin_call_impl(
        const CandidateFrame& start_candidate, bool one_shot_override,
        std::uint64_t now_ms, std::uint64_t call_window_ms);
    [[nodiscard]] Update make_update() const;
    [[nodiscard]] bool observe_time(std::uint64_t now_ms, Update& update);
    void process_bytes(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms, Update& update);
    void process_record(std::uint8_t type, std::size_t payload_size, std::uint64_t now_ms, Update& update);
    void schedule_stop(Update& update);
    void finish_call(Update& update, bool faulted);
    void reset_call_state() noexcept;
};

} // namespace wirex::hri_stream_session
