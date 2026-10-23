#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "wirex/session_report.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

namespace {

int failures = 0;

void check(bool condition, const char* message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

std::string read_all(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

} // namespace

int main()
{
    wirex::session_report::RuntimeFields event_runtime{};
    event_runtime.radio_session.enabled = true;
    wirex::session_report::apply_radio_event(event_runtime, "snapshot", "running", "listening");
    wirex::session_report::apply_radio_event(event_runtime, "request_result", "accepted", "stopping");
    wirex::session_report::apply_radio_event(event_runtime, "operation_result", "completed", "operation_finished");
    check(event_runtime.status == "running" && event_runtime.phase == "listening" &&
        event_runtime.radio_session.phase == "listening" && event_runtime.radio_session.request_status == "accepted",
        "request and operation results must not overwrite a live session's top-level state");
    wirex::session_report::apply_radio_event(event_runtime, "session_result", "completed", "stopped");
    check(event_runtime.status == "completed" && event_runtime.phase == "stopped",
        "only a session_result should finish the top-level session state");

    const auto root = std::filesystem::temp_directory_path() /
        ("wirex-session-report-test-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(GetTickCount64()));
    std::error_code create_error;
    if (!std::filesystem::create_directory(root, create_error) || create_error) {
        std::cerr << "FAIL: test must create a fresh private temporary directory\n";
        return 1;
    }
    const auto report_path = root / "status.json";
    wirex::session_report::Writer writer;
    std::string error;
    check(wirex::session_report::Writer::create(report_path, writer, error), "writer creation should succeed");
    check(error.empty(), "writer creation should not leave an error");

    wirex::hri_session::Snapshot hri{};
    hri.phase = wirex::hri_session::Phase::exchanging;
    hri.counters.version_query_write_completed = 1;
    hri.counters.version_response_validated = 1;
    hri.counters.y_write_completed = 3;
    hri.counters.y_zero_ack_received = 2;
    wirex::session_report::RuntimeFields runtime{};
    runtime.phase = "audio_active";
    runtime.elapsed_ms = 2500;
    runtime.audio_started = true;
    runtime.captured_bytes = 48000;
    runtime.submitted_bytes = 47900;
    runtime.dropped_blocks = 1;

    check(writer.write(hri, runtime, error), "running snapshot should be written atomically");
    auto text = read_all(report_path);
    check(text.find("\"final\":false") != std::string::npos, "running snapshot must be non-final");
    check(text.find("\"schema_version\":1") != std::string::npos, "schema version should be recorded");
    check(text.find("\"run_id\":\"") != std::string::npos && writer.run_id().size() == 32,
        "a per-run identifier should be recorded");
    check(text.find("\"pid\":") != std::string::npos, "process ID should be recorded");
    check(text.find("\"process_created_filetime_utc\":\"") != std::string::npos,
        "exact process creation time should be recorded");
    check(text.find("\"snapshot_utc\":\"") != std::string::npos, "snapshot time should be recorded");
    check(text.find("\"phase\":\"audio_active\"") != std::string::npos, "running phase should be recorded");
    check(text.find("\"y_write_completed\":3") != std::string::npos, "HRI counts should be recorded");
    check(text.find("\"radio_state\":\"unknown\"") != std::string::npos, "radio state must remain explicitly unknown");
    check(text.find("\"radio_state_unknown\":true") != std::string::npos, "radio state uncertainty must be explicit");
    check(text.find("\"downlink\"") == std::string::npos,
        "existing HRI reports must omit the optional downlink object");
    check(text.find("PCM_BODY_SENTINEL") == std::string::npos, "the report must not contain protocol or PCM body text");
    check(text.find("COM5") == std::string::npos && text.find("RadioID") == std::string::npos,
        "the report must not contain a port or radio identity");

    runtime.final = true;
    runtime.status = "cancelled";
    runtime.phase = "stopped";
    runtime.failure_reason.clear();
    runtime.audio_input_cleanup = "succeeded";
    runtime.audio_output_cleanup = "succeeded";
    runtime.serial_cleanup = "succeeded";
    runtime.downlink.enabled = true;
    runtime.downlink.phase = "finished";
    runtime.downlink.operation_result = "failed";
    runtime.downlink.failure_reason = "stop_record_timeout";
    runtime.downlink.start_t_write_attempts = 1;
    runtime.downlink.start_t_write_completions = 1;
    runtime.downlink.start_matching_t_records = 1;
    runtime.downlink.start_matching_t_payload_observed = true;
    runtime.downlink.start_matching_t_payload_bytes = 90;
    runtime.downlink.stop_t_write_attempts = 1;
    runtime.downlink.stop_t_write_completions = 1;
    runtime.downlink.stop_matching_t_records = 0;
    runtime.downlink.pcm_submitted_bytes = 9600;
    runtime.downlink.pcm_drained = false;
    runtime.downlink.operation_audio_cleanup = "succeeded";
    runtime.radio_session.enabled = true;
    runtime.radio_session.seq = 17;
    runtime.radio_session.phase = "listening";
    runtime.radio_session.last_request_id = "request_9";
    runtime.radio_session.request_status = "failed";
    runtime.radio_session.operation_count = 2;
    runtime.radio_session.radio_audio_input = "running";
    runtime.radio_session.pc_audio_output = "running";
    runtime.radio_session.microphone_capture = "idle";
    hri.phase = wirex::hri_session::Phase::stopped;
    hri.stop_reason = wirex::hri_session::StopReason::cancelled;
    check(writer.write(hri, runtime, error), "final snapshot should atomically replace the running one");
    text = read_all(report_path);
    check(text.find("\"final\":true") != std::string::npos, "final snapshot must be marked final");
    check(text.find("\"status\":\"cancelled\"") != std::string::npos, "cancellation must not be called completion");
    check(text.find("\"serial_handle\":\"succeeded\"") != std::string::npos, "PC cleanup results should be recorded");
    check(text.find("\"operation_result\":\"failed\"") != std::string::npos &&
        text.find("\"stop_matching_t_records\":0") != std::string::npos &&
        text.find("\"start_matching_t_payload_bytes\":90") != std::string::npos &&
        text.find("\"stop_matching_t_payload_bytes\":null") != std::string::npos &&
        text.find("\"pcm_submitted_bytes\":9600") != std::string::npos &&
        text.find("\"pcm_drained\":false") != std::string::npos,
        "candidate reports should record T observations and PCM progress separately");
    check(text.find("\"operation_audio_cleanup\":\"succeeded\"") != std::string::npos &&
        text.find("\"radio_session\":{\"seq\":17") != std::string::npos &&
        text.find("\"last_request_id\":\"request_9\"") != std::string::npos &&
        text.find("\"operation_count\":2") != std::string::npos &&
        text.find("\"serial_handle\":\"succeeded\"") != std::string::npos,
        "session report should separate last operation cleanup from final shared serial cleanup");
    check(text.find("\"radio_state\":\"unknown\"") != std::string::npos, "final snapshot must not infer radio state");
    check(!std::filesystem::exists(report_path.wstring() + L".tmp." + std::wstring(writer.run_id().begin(), writer.run_id().end())),
        "atomic replacement should remove its temporary file");

    const auto missing_parent_path = root / "missing" / "status.json";
    wirex::session_report::Writer missing_parent_writer;
    check(wirex::session_report::Writer::create(missing_parent_path, missing_parent_writer, error),
        "writer creation only resolves the path and may precede the first write");
    check(!missing_parent_writer.write(hri, runtime, error), "write failure should return immediately without retrying");
    check(!error.empty(), "write failure should expose a diagnostic");

    std::error_code cleanup_error;
    std::filesystem::remove(report_path, cleanup_error);
    if (cleanup_error) {
        ++failures;
        std::cerr << "FAIL: temporary report file cleanup failed\n";
    }
    cleanup_error.clear();
    std::filesystem::remove(root, cleanup_error);
    if (cleanup_error) {
        ++failures;
        std::cerr << "FAIL: temporary report directory was not empty\n";
    }
    if (failures != 0) return 1;
    std::cout << "All session report checks passed.\n";
    return 0;
}
