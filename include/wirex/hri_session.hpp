#pragma once

#include "wirex/direct_stream.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wirex::hri_session {

inline constexpr std::size_t y_body_size = 100;
inline constexpr std::uint64_t y_period_ms = 1000;
inline constexpr std::uint64_t version_response_timeout_ms = 2500;
inline constexpr std::uint64_t y_ack_timeout_ms = 3000;
inline constexpr std::uint64_t max_window_ms = 120000;
inline constexpr std::size_t max_frame_bytes = 4096;
inline constexpr std::size_t max_receive_bytes = 256 * 1024;
inline constexpr std::size_t max_transmit_bytes = 32 * 1024;
inline constexpr std::uint32_t max_valid_records = 1024;
inline constexpr std::uint32_t max_y_write_calls = 120;
inline constexpr std::uint32_t max_x_ack_write_calls = 256;
inline constexpr std::size_t max_continuous_feed_bytes = 2048;
inline constexpr std::size_t max_continuous_records_per_feed = 512;
inline constexpr std::size_t max_pending_writes = 256;

enum class Phase {
    not_started,
    awaiting_version_write,
    awaiting_version,
    waiting_for_y_due,
    exchanging,
    stopped,
};

enum class StopReason {
    none,
    invalid_configuration,
    invalid_y_template,
    already_started,
    time_overflow,
    clock_regressed,
    deadline,
    version_timeout,
    cancelled,
    malformed_record,
    version_mismatch,
    unexpected_version_record,
    receive_limit,
    record_limit,
    transmit_limit,
    y_write_limit,
    y_ack_timeout,
    x_ack_limit,
    write_failed,
    unexpected_write_completion,
    incomplete_record,
    pending_write_limit,
    caller_stopped,
    transport_failure,
    audio_failure,
    report_failure,
};

enum class CommandKind {
    version_query,
    y_record,
    x_ack,
};

enum class PttLevel {
    unknown,
    pressed,
    released,
};

struct PttObservation {
    PttLevel level{PttLevel::unknown};
    // True only when a valid Y0 record had already been accepted before this X100.
    bool y_zero_acknowledged{};
};

struct Command {
    std::uint64_t id{};
    CommandKind kind{CommandKind::version_query};
    std::vector<std::uint8_t> frame;
};

struct Counters {
    std::uint64_t version_query_write_requested{};
    std::uint64_t version_query_write_completed{};
    std::uint64_t version_response_validated{};
    std::uint64_t y_write_requested{};
    std::uint64_t y_write_completed{};
    std::uint64_t y_zero_ack_received{};
    std::uint64_t x100_received{};
    std::uint64_t x_copy_branch_count{};
    std::uint64_t y_byte12_changed_count{};
    std::uint64_t x0_write_requested{};
    std::uint64_t x0_write_completed{};
    std::uint64_t unsupported_config_import_records{};
    std::uint64_t other_valid_records{};
    std::uint64_t malformed_records{};
    std::uint64_t valid_records{};
    std::uint64_t receive_bytes{};
    std::uint64_t transmit_bytes_requested{};
    std::uint64_t write_calls_completed{};
};

struct Snapshot {
    Phase phase{Phase::not_started};
    StopReason stop_reason{StopReason::none};
    Counters counters{};
    bool y_template_valid{false};
    bool version_response_validated{false};
    bool y_zero_acknowledged{false};
    bool may_start_audio_route{false};
    bool limited_exchange_observed{false};
};

struct Update {
    std::vector<Command> commands;
    std::vector<PttObservation> ptt_observations;
    Snapshot state{};
};

struct Config {
    std::uint64_t window_ms{max_window_ms};
    bool continuous{false};
};

// 纯函数状态机：调用者通过 write_completed() 报告串口写入结果；本类不访问设备。
class Session {
public:
    explicit Session(std::vector<std::uint8_t> external_y_body, Config config = {});

    [[nodiscard]] Update start(std::uint64_t now_ms);
    [[nodiscard]] Update tick(std::uint64_t now_ms);
    [[nodiscard]] Update feed(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms);
    [[nodiscard]] Update write_completed(std::uint64_t command_id, bool succeeded, std::uint64_t now_ms);
    [[nodiscard]] Update cancel();
    [[nodiscard]] Update abort(StopReason reason);
    [[nodiscard]] Update finish(std::uint64_t now_ms);
    [[nodiscard]] Snapshot snapshot() const noexcept;
    [[nodiscard]] std::size_t buffered_receive_bytes() const noexcept;

private:
    struct PendingWrite {
        std::uint64_t id{};
        CommandKind kind{CommandKind::version_query};
    };

    std::vector<std::uint8_t> y_body_;
    Config config_{};
    direct_stream::Parser parser_;
    Phase phase_{Phase::not_started};
    StopReason stop_reason_{StopReason::none};
    Counters counters_{};
    std::vector<PendingWrite> pending_writes_;
    std::uint64_t next_command_id_{1};
    std::uint64_t started_at_ms_{};
    std::uint64_t last_observed_ms_{};
    std::uint64_t deadline_ms_{};
    std::uint64_t version_deadline_ms_{};
    std::uint64_t next_y_due_ms_{};
    std::uint64_t y_ack_deadline_ms_{};
    bool config_valid_{false};
    bool y_template_valid_{false};
    bool started_{false};
    bool version_response_validated_{false};
    bool limited_exchange_observed_{false};
    bool y_ack_timeout_armed_{false};

    [[nodiscard]] bool observe_time(std::uint64_t now_ms);
    [[nodiscard]] bool queue_command(CommandKind kind, direct_frame::Record record, Update& update);
    void stop(StopReason reason) noexcept;
    [[nodiscard]] Snapshot make_snapshot() const noexcept;
};

} // namespace wirex::hri_session
