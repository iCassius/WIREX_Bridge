#pragma once

#include "wirex/direct_stream.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wirex::hri_downlink_session {

inline constexpr std::uint64_t start_record_timeout_ms = 3000;
inline constexpr std::uint64_t normal_stop_record_timeout_ms = 3000;
inline constexpr std::uint64_t cancelled_stop_record_timeout_ms = 500;
inline constexpr std::uint64_t max_flow_duration_ms = 20000;
inline constexpr std::uint64_t default_pcm_window_ms = 7248;
inline constexpr std::size_t max_record_payload_size = 4096;

using CandidateFrame = std::vector<std::uint8_t>;

enum class Phase {
    idle,
    start_write_pending,
    start_write_in_progress,
    awaiting_start_record,
    pcm_ready,
    pcm_active,
    pcm_stop_pending,
    stop_write_pending,
    stop_write_in_progress,
    awaiting_stop_record,
    cleanup_pending,
    finished,
};

enum class Status {
    running,
    completed,
    cancelled,
    failed,
};

enum class StopReason {
    none,
    cancelled_before_start_attempt,
    cancelled,
    invalid_candidate_frame,
    invalid_configuration,
    invalid_pcm_window,
    start_write_failed,
    start_record_timeout,
    pcm_failed,
    pcm_window_expired,
    stop_write_failed,
    stop_record_timeout,
    overall_timeout,
    transport_failed,
    pc_cleanup_failed,
};

enum class ActionKind {
    write_start_candidate,
    allow_pcm,
    request_pcm_stop,
    write_stop_candidate,
    cleanup_required,
};

struct Action {
    ActionKind kind{ActionKind::cleanup_required};
    std::uint64_t write_id{};
    CandidateFrame frame{};
};

enum class EventError {
    none,
    invalid_phase,
    invalid_write_id,
    write_not_attempted,
    duplicate_write_attempt,
    duplicate_write_completion,
    invalid_time,
    null_input,
    cleanup_not_pending,
    cleanup_already_reported,
};

struct Snapshot {
    Phase phase{Phase::idle};
    Status status{Status::running};
    StopReason stop_reason{StopReason::none};
    bool start_write_attempted{false};
    bool start_write_completed{false};
    bool start_write_succeeded{false};
    bool start_matching_t_record_observed{false};
    std::size_t start_matching_t_payload_bytes{};
    bool pcm_permitted{false};
    bool pcm_started{false};
    bool pcm_completed{false};
    bool pcm_succeeded{false};
    bool stop_write_attempted{false};
    bool stop_write_completed{false};
    bool stop_write_succeeded{false};
    bool stop_matching_t_record_observed{false};
    std::size_t stop_matching_t_payload_bytes{};
    bool final{false};
    bool audio_cleanup_reported{false};
    bool audio_cleanup_succeeded{false};
    bool serial_cleanup_reported{false};
    bool serial_cleanup_succeeded{false};
    bool radio_state_unknown{true};
    std::uint64_t malformed_records{};
    std::uint64_t unmatched_t_records{};
};

struct Update {
    std::vector<Action> actions;
    Snapshot state{};
    EventError error{EventError::none};
};

struct Config {
    std::uint64_t start_timeout_ms{start_record_timeout_ms};
    std::uint64_t normal_stop_timeout_ms{normal_stop_record_timeout_ms};
    std::uint64_t cancelled_stop_timeout_ms{cancelled_stop_record_timeout_ms};
    std::uint64_t overall_timeout_ms{max_flow_duration_ms};
};

// 不访问设备；调用方提供完整 T 帧，并回报每次写入、PCM 和本机资源清理结果。
class Session final {
public:
    Session(CandidateFrame start_candidate, CandidateFrame stop_candidate, Config config = {});

    [[nodiscard]] Update start(std::uint64_t now_ms, std::uint64_t pcm_window_ms = default_pcm_window_ms);
    [[nodiscard]] Update write_attempted(std::uint64_t write_id, std::uint64_t now_ms);
    [[nodiscard]] Update write_completed(std::uint64_t write_id, bool succeeded, std::uint64_t now_ms);
    [[nodiscard]] Update feed(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms);
    [[nodiscard]] Update pcm_started(std::uint64_t now_ms);
    [[nodiscard]] Update pcm_completed(bool succeeded, std::uint64_t now_ms);
    [[nodiscard]] Update cancel(std::uint64_t now_ms);
    [[nodiscard]] Update transport_failed(std::uint64_t now_ms);
    [[nodiscard]] Update tick(std::uint64_t now_ms);
    [[nodiscard]] Update operation_cleanup_completed(bool audio_cleanup_succeeded,
                                                     std::uint64_t now_ms);
    [[nodiscard]] Update cleanup_completed(bool audio_cleanup_succeeded,
                                           bool serial_cleanup_succeeded,
                                           std::uint64_t now_ms);
    [[nodiscard]] Snapshot snapshot() const noexcept;

private:
    static constexpr std::uint64_t start_write_id = 1;
    static constexpr std::uint64_t stop_write_id = 2;

    CandidateFrame start_candidate_;
    CandidateFrame stop_candidate_;
    Config config_{};
    direct_stream::Parser parser_;
    Snapshot state_{};
    std::uint64_t started_at_ms_{};
    std::uint64_t last_observed_ms_{};
    std::uint64_t overall_deadline_ms_{};
    std::uint64_t pcm_window_ms_{};
    std::uint64_t pcm_deadline_ms_{};
    std::uint64_t record_deadline_ms_{};
    bool started_{false};
    bool stop_scheduled_{false};
    bool pcm_stop_requested_{false};
    bool cancellation_requested_{false};
    bool transport_failed_{false};
    bool overall_expired_{false};
    bool cleanup_reported_{false};
    bool operation_cleanup_only_{false};

    [[nodiscard]] Update make_update() const;
    [[nodiscard]] bool observe_time(std::uint64_t now_ms, Update& update);
    void advance_deadlines(std::uint64_t now_ms, Update& update);
    void process_record(const direct_frame::Record& record, std::uint64_t now_ms, Update& update);
    void schedule_stop(Update& update);
    void request_pcm_stop(Update& update);
    void enter_cleanup(Update& update);
    void set_failure(StopReason reason) noexcept;
    void finalize_status() noexcept;
};

} // namespace wirex::hri_downlink_session
