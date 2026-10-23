#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

#include "wirex/session_report.hpp"

#include <array>
#include <iomanip>
#include <sstream>
#include <string_view>
#include <vector>

namespace wirex::session_report {
namespace {

std::string win32_error(DWORD code)
{
    std::ostringstream text;
    text << "Win32 error " << code;
    return text.str();
}

std::string utc_time(const FILETIME& file_time)
{
    SYSTEMTIME utc{};
    if (!FileTimeToSystemTime(&file_time, &utc)) return {};
    std::ostringstream text;
    text << std::setfill('0') << std::setw(4) << utc.wYear << '-'
         << std::setw(2) << utc.wMonth << '-' << std::setw(2) << utc.wDay << 'T'
         << std::setw(2) << utc.wHour << ':' << std::setw(2) << utc.wMinute << ':'
         << std::setw(2) << utc.wSecond << '.' << std::setw(3) << utc.wMilliseconds << 'Z';
    return text.str();
}

std::string now_utc()
{
    SYSTEMTIME utc{};
    GetSystemTime(&utc);
    std::ostringstream text;
    text << std::setfill('0') << std::setw(4) << utc.wYear << '-'
         << std::setw(2) << utc.wMonth << '-' << std::setw(2) << utc.wDay << 'T'
         << std::setw(2) << utc.wHour << ':' << std::setw(2) << utc.wMinute << ':'
         << std::setw(2) << utc.wSecond << '.' << std::setw(3) << utc.wMilliseconds << 'Z';
    return text.str();
}

std::string hex_id(const std::array<std::uint8_t, 16>& bytes)
{
    static constexpr char digits[] = "0123456789abcdef";
    std::string id;
    id.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        id.push_back(digits[byte >> 4]);
        id.push_back(digits[byte & 0x0f]);
    }
    return id;
}

std::string json_string(std::string_view value)
{
    std::string escaped;
    escaped.reserve(value.size() + 2);
    escaped.push_back('"');
    for (const unsigned char byte : value) {
        switch (byte) {
        case '"': escaped += "\\\""; break;
        case '\\': escaped += "\\\\"; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (byte < 0x20) {
                static constexpr char digits[] = "0123456789abcdef";
                escaped += "\\u00";
                escaped.push_back(digits[byte >> 4]);
                escaped.push_back(digits[byte & 0x0f]);
            } else {
                escaped.push_back(static_cast<char>(byte));
            }
        }
    }
    escaped.push_back('"');
    return escaped;
}

const char* phase_name(hri_session::Phase phase) noexcept
{
    using hri_session::Phase;
    switch (phase) {
    case Phase::not_started: return "not_started";
    case Phase::awaiting_version_write: return "awaiting_version_write";
    case Phase::awaiting_version: return "awaiting_version";
    case Phase::waiting_for_y_due: return "waiting_for_y_due";
    case Phase::exchanging: return "exchanging";
    case Phase::stopped: return "stopped";
    }
    return "unknown";
}

const char* stop_reason_name(hri_session::StopReason reason) noexcept
{
    using hri_session::StopReason;
    switch (reason) {
    case StopReason::none: return "none";
    case StopReason::invalid_configuration: return "invalid_configuration";
    case StopReason::invalid_y_template: return "invalid_y_template";
    case StopReason::already_started: return "already_started";
    case StopReason::time_overflow: return "time_overflow";
    case StopReason::clock_regressed: return "clock_regressed";
    case StopReason::deadline: return "deadline";
    case StopReason::version_timeout: return "version_timeout";
    case StopReason::cancelled: return "cancelled";
    case StopReason::malformed_record: return "malformed_record";
    case StopReason::version_mismatch: return "version_mismatch";
    case StopReason::unexpected_version_record: return "unexpected_version_record";
    case StopReason::receive_limit: return "receive_limit";
    case StopReason::record_limit: return "record_limit";
    case StopReason::transmit_limit: return "transmit_limit";
    case StopReason::y_write_limit: return "y_write_limit";
    case StopReason::y_ack_timeout: return "y_ack_timeout";
    case StopReason::x_ack_limit: return "x_ack_limit";
    case StopReason::write_failed: return "write_failed";
    case StopReason::unexpected_write_completion: return "unexpected_write_completion";
    case StopReason::incomplete_record: return "incomplete_record";
    case StopReason::caller_stopped: return "caller_stopped";
    case StopReason::transport_failure: return "transport_failure";
    case StopReason::audio_failure: return "audio_failure";
    case StopReason::report_failure: return "report_failure";
    }
    return "unknown";
}

bool write_atomic(const std::filesystem::path& path, std::string_view contents, const std::string& run_id,
                  std::string& error)
{
    auto temporary_path = path;
    temporary_path += L".tmp.";
    temporary_path += std::wstring(run_id.begin(), run_id.end());
    HANDLE file = CreateFileW(temporary_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        error = win32_error(GetLastError());
        return false;
    }

    bool okay = true;
    std::size_t offset = 0;
    while (okay && offset < contents.size()) {
        const auto remaining = contents.size() - offset;
        const DWORD chunk = static_cast<DWORD>((remaining > 0xffffffffULL) ? 0xffffffffULL : remaining);
        DWORD written = 0;
        const BOOL wrote = WriteFile(file, contents.data() + offset, chunk, &written, nullptr);
        if (wrote == FALSE) {
            okay = false;
        } else if (written != chunk || written == 0) {
            SetLastError(ERROR_WRITE_FAULT);
            okay = false;
        } else {
            offset += written;
        }
    }
    if (okay) okay = FlushFileBuffers(file) != FALSE;
    const DWORD write_error = okay ? ERROR_SUCCESS : GetLastError();
    const bool close_ok = CloseHandle(file) != FALSE;
    if (!okay || !close_ok) {
        error = win32_error(okay ? GetLastError() : write_error);
        DeleteFileW(temporary_path.c_str());
        return false;
    }

    if (!MoveFileExW(temporary_path.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const DWORD move_error = GetLastError();
        DeleteFileW(temporary_path.c_str());
        error = win32_error(move_error);
        return false;
    }
    return true;
}

} // namespace

bool Writer::create(const std::filesystem::path& path, Writer& writer, std::string& error)
{
    error.clear();
    if (path.empty()) {
        error = "report path is empty";
        return false;
    }
    std::error_code path_error;
    const auto absolute_path = std::filesystem::absolute(path, path_error);
    if (path_error) {
        error = "cannot resolve report path";
        return false;
    }

    std::array<std::uint8_t, 16> random{};
    const NTSTATUS random_status = BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()),
        BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (random_status < 0) {
        error = "BCryptGenRandom failed";
        return false;
    }

    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user)) {
        error = win32_error(GetLastError());
        return false;
    }
    writer.path_ = absolute_path;
    writer.run_id_ = hex_id(random);
    writer.process_id_ = GetCurrentProcessId();
    ULARGE_INTEGER created{};
    created.LowPart = creation.dwLowDateTime;
    created.HighPart = creation.dwHighDateTime;
    writer.process_created_filetime_utc_ = created.QuadPart;
    writer.process_created_utc_ = utc_time(creation);
    if (writer.process_created_utc_.empty()) {
        error = win32_error(GetLastError());
        return false;
    }
    return true;
}

bool Writer::write(const hri_session::Snapshot& hri, const RuntimeFields& runtime, std::string& error) const
{
    error.clear();
    const auto& c = hri.counters;
    std::ostringstream json;
    json << "{\"schema_version\":1"
         << ",\"run_id\":" << json_string(run_id_)
         << ",\"pid\":" << process_id_
         << ",\"process_created_filetime_utc\":" << json_string(std::to_string(process_created_filetime_utc_))
         << ",\"process_created_utc\":" << json_string(process_created_utc_)
         << ",\"snapshot_utc\":" << json_string(now_utc())
         << ",\"final\":" << (runtime.final ? "true" : "false")
         << ",\"status\":" << json_string(runtime.status)
         << ",\"phase\":" << json_string(runtime.phase)
         << ",\"elapsed_ms\":" << runtime.elapsed_ms
         << ",\"stop_reason\":" << json_string(stop_reason_name(hri.stop_reason))
         << ",\"failure_reason\":" << json_string(runtime.failure_reason)
         << ",\"version_query_write_requested\":" << c.version_query_write_requested
         << ",\"version_query_write_completed\":" << c.version_query_write_completed
         << ",\"version_response_validated\":" << (hri.version_response_validated ? "true" : "false")
         << ",\"y_write_requested\":" << c.y_write_requested
         << ",\"y_write_completed\":" << c.y_write_completed
         << ",\"y_zero_ack_received\":" << c.y_zero_ack_received
         << ",\"x100_received\":" << c.x100_received
         << ",\"unsupported_config_import_records\":" << c.unsupported_config_import_records
         << ",\"x_copy_branch_count\":" << c.x_copy_branch_count
         << ",\"y_byte12_changed_count\":" << c.y_byte12_changed_count
         << ",\"x0_write_requested\":" << c.x0_write_requested
         << ",\"x0_write_completed\":" << c.x0_write_completed
         << ",\"other_valid_records\":" << c.other_valid_records
         << ",\"malformed_records\":" << c.malformed_records
         << ",\"valid_records\":" << c.valid_records
         << ",\"receive_bytes\":" << c.receive_bytes
         << ",\"transmit_bytes_requested\":" << c.transmit_bytes_requested
         << ",\"write_calls_completed\":" << c.write_calls_completed
         << ",\"audio_started\":" << (runtime.audio_started ? "true" : "false")
         << ",\"captured_bytes\":" << runtime.captured_bytes
         << ",\"submitted_bytes\":" << runtime.submitted_bytes
         << ",\"dropped_blocks\":" << runtime.dropped_blocks
         << ",\"clipped_samples\":" << runtime.clipped_samples
         << ",\"report_write_failed\":" << (runtime.report_write_failed ? "true" : "false")
         << ",\"pc_cleanup\":{\"audio_input\":" << json_string(runtime.audio_input_cleanup)
         << ",\"audio_output\":" << json_string(runtime.audio_output_cleanup)
         << ",\"serial_handle\":" << json_string(runtime.serial_cleanup) << '}';
    if (runtime.downlink.enabled) {
        const auto& downlink = runtime.downlink;
        json << ",\"downlink\":{\"phase\":" << json_string(downlink.phase)
             << ",\"operation_result\":" << json_string(downlink.operation_result)
             << ",\"failure_reason\":" << json_string(downlink.failure_reason)
             << ",\"start_t_write_attempts\":" << downlink.start_t_write_attempts
             << ",\"start_t_write_completions\":" << downlink.start_t_write_completions
             << ",\"start_matching_t_records\":" << downlink.start_matching_t_records
             << ",\"start_matching_t_payload_bytes\":";
        if (downlink.start_matching_t_payload_observed) json << downlink.start_matching_t_payload_bytes;
        else json << "null";
        json << ",\"stop_t_write_attempts\":" << downlink.stop_t_write_attempts
             << ",\"stop_t_write_completions\":" << downlink.stop_t_write_completions
             << ",\"stop_matching_t_records\":" << downlink.stop_matching_t_records
             << ",\"stop_matching_t_payload_bytes\":";
        if (downlink.stop_matching_t_payload_observed) json << downlink.stop_matching_t_payload_bytes;
        else json << "null";
        json << ",\"pcm_submitted_bytes\":" << downlink.pcm_submitted_bytes
             << ",\"pcm_drained\":" << (downlink.pcm_drained ? "true" : "false")
             << ",\"radio_state\":\"unknown\",\"radio_state_unknown\":true}";
    }
    json << ",\"radio_state\":\"unknown\",\"radio_state_unknown\":true}\n";
    const auto contents = json.str();
    return write_atomic(path_, contents, run_id_, error);
}

} // namespace wirex::session_report
