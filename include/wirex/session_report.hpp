#pragma once

#include "wirex/hri_session.hpp"

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

namespace wirex::session_report {

struct DownlinkFields {
    bool enabled{false};
    std::string phase{"not_started"};
    std::string operation_result{"not_started"};
    std::string failure_reason{};
    std::uint64_t start_t_write_attempts{};
    std::uint64_t start_t_write_completions{};
    std::uint64_t start_matching_t_records{};
    bool start_matching_t_payload_observed{false};
    std::uint64_t start_matching_t_payload_bytes{};
    std::uint64_t stop_t_write_attempts{};
    std::uint64_t stop_t_write_completions{};
    std::uint64_t stop_matching_t_records{};
    bool stop_matching_t_payload_observed{false};
    std::uint64_t stop_matching_t_payload_bytes{};
    std::uint64_t pcm_submitted_bytes{};
    bool pcm_drained{false};
    std::string operation_audio_cleanup{"not_started"};
};

struct RadioSessionFields {
    bool enabled{false};
    std::uint64_t seq{};
    std::string phase{"starting"};
    std::string active_request_id{};
    std::string last_request_id{};
    std::string request_status{"none"};
    std::string request_failure_reason{};
    std::uint64_t operation_count{};
    std::string radio_audio_input{"not_started"};
    std::string pc_audio_output{"not_started"};
    std::string microphone_capture{"idle"};
    std::uint64_t microphone_capture_bytes{};
};

struct RuntimeFields {
    bool final{false};
    bool audio_started{false};
    bool report_write_failed{false};
    std::string status{"running"};
    std::string phase{"starting"};
    std::string failure_reason{};
    std::string audio_input_cleanup{"not_started"};
    std::string audio_output_cleanup{"not_started"};
    std::string serial_cleanup{"not_opened"};
    std::uint64_t elapsed_ms{};
    std::uint64_t captured_bytes{};
    std::uint64_t submitted_bytes{};
    std::uint64_t dropped_blocks{};
    std::uint64_t clipped_samples{};
    DownlinkFields downlink{};
    RadioSessionFields radio_session{};
};

// 请求与操作结果只更新各自字段；仅snapshot/session_result推进会话顶层状态。
void apply_radio_event(RuntimeFields& runtime, std::string_view type, std::string_view status,
                       std::string_view phase);

class Writer {
public:
    Writer() = default;

    static bool create(const std::filesystem::path& path, Writer& writer, std::string& error);

    bool write(const hri_session::Snapshot& hri, const RuntimeFields& runtime, std::string& error) const;

    [[nodiscard]] const std::string& run_id() const noexcept { return run_id_; }
    [[nodiscard]] std::uint32_t process_id() const noexcept { return process_id_; }
    [[nodiscard]] std::uint64_t process_created_filetime_utc() const noexcept { return process_created_filetime_utc_; }

private:
    std::filesystem::path path_{};
    std::string run_id_{};
    std::uint32_t process_id_{};
    std::uint64_t process_created_filetime_utc_{};
    std::string process_created_utc_{};
};

} // namespace wirex::session_report
