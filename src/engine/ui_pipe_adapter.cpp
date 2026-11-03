// --ui-pipe / 控制台前端：Engine 之上的薄适配层。
// - control-v2：stdin JSONL → ui_control::JsonLineParser/Dispatcher（协议校验与重放缓存不变）
//   → RoutingCallbacks 转发到 Engine 方法并等待 future → stdout control_result；
// - control-v1：Q 换行或 EOF 停止；控制台模式：Q 停止、T 手动 PTT（--manual-ptt）；
// - --status-file：Engine 诊断钩子在引擎线程同步写入，字段与 R127 append_bridge_status 逐字节一致。

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "ui_pipe_adapter.hpp"

#include "wirex/bounded_pipe_writer.hpp"
#include "wirex/engine_diagnostics.hpp"
#include "wirex/pcm_gain.hpp"
#include "wirex/ui_control_protocol.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <exception>
#include <stdexcept>
#include <future>
#include <limits>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::engine::adapter {
namespace {

using Callbacks = ui_control::RoutingCallbacks;

constexpr auto command_wait = std::chrono::seconds{10};
constexpr std::uint64_t routing_check_interval_ms = 250U;

bool write_bytes(HANDLE output, const void* data, std::size_t size) noexcept
{
    if (output == nullptr || output == INVALID_HANDLE_VALUE) return false;
    const auto* bytes = static_cast<const std::uint8_t*>(data);
    std::size_t offset = 0U;
    while (offset < size) {
        const DWORD count = static_cast<DWORD>(std::min<std::size_t>(size - offset, 0x7fffffffU));
        DWORD written = 0U;
        if (!WriteFile(output, bytes + offset, count, &written, nullptr) || written == 0U) return false;
        offset += written;
    }
    return true;
}

// 原 write_bm_utf8：控制台用 WriteConsoleW，管道/文件写 UTF-8 字节。
void write_console_utf8(HANDLE output, std::string_view text) noexcept
{
    if (output == nullptr || output == INVALID_HANDLE_VALUE || text.empty()) return;
    DWORD mode = 0U;
    if (!GetConsoleMode(output, &mode)) {
        (void)write_bytes(output, text.data(), text.size());
        return;
    }
    if (text.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) return;
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0);
    if (required <= 0) return;
    try {
        std::wstring wide(static_cast<std::size_t>(required), L'\0');
        if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
            static_cast<int>(text.size()), wide.data(), required) != required) return;
        DWORD written = 0U;
        (void)WriteConsoleW(output, wide.data(), static_cast<DWORD>(wide.size()), &written, nullptr);
    } catch (...) {
    }
}

CommandResult await(std::future<CommandResult> future) noexcept
{
    try {
        if (future.wait_for(command_wait) != std::future_status::ready) {
            return CommandResult{CommandStatus::failed, 0U, "engine_command_timeout"};
        }
        return future.get();
    } catch (...) {
        return CommandResult{CommandStatus::failed, 0U, "engine_command_failed"};
    }
}

talkgroup_routing::PolicyUpdateResult to_policy_result(const CommandResult& result)
{
    using talkgroup_routing::PolicyUpdateStatus;
    PolicyUpdateStatus status = PolicyUpdateStatus::invalid_policy;
    if (result.status == CommandStatus::accepted || result.status == CommandStatus::idempotent) {
        status = PolicyUpdateStatus::applied;
    } else if (result.detail == "revision_conflict") {
        status = PolicyUpdateStatus::revision_conflict;
    } else if (result.detail == "revision_exhausted") {
        status = PolicyUpdateStatus::revision_exhausted;
    } else if (result.detail == "resource_failure") {
        status = PolicyUpdateStatus::resource_failure;
    }
    return talkgroup_routing::PolicyUpdateResult{status, result.revision, std::nullopt, std::nullopt};
}

Callbacks::QuickCallOutcome to_quick_call_outcome(const CommandResult& result)
{
    using Status = Callbacks::QuickCallStatus;
    const auto frames = static_cast<std::uint8_t>(std::min<std::uint64_t>(result.revision, 2U));
    if (result.status == CommandStatus::accepted) return {Status::sent, frames};
    if (result.detail == "quick_call_not_ready" || result.detail == "engine_not_running") {
        return {Status::not_ready, frames};
    }
    if (result.detail == "media_busy") return {Status::busy, frames};
    if (result.detail == "invalid_or_forbidden_group") return {Status::invalid_target, frames};
    if (result.detail == "disconnect_group_forbidden") return {Status::forbidden_target, frames};
    if (result.detail == "quick_call_partial_send") return {Status::partial_send, frames};
    if (result.detail == "quick_call_send_incomplete") return {Status::sent, frames};  // 协议层据帧数判定
    return {Status::send_failed, frames};
}

radio_identity_cache::UpsertResult to_identity_result(const CommandResult& result, bool has_callsign)
{
    using Update = radio_identity_cache::UpsertResult;
    if (result.status == CommandStatus::accepted) return has_callsign ? Update::updated : Update::removed;
    if (result.status == CommandStatus::idempotent) return Update::replayed;
    if (result.detail == "stale_identity_revision") return Update::stale_revision;
    if (result.detail == "identity_revision_conflict") return Update::revision_conflict;
    if (result.detail == "invalid_identity") return Update::invalid_callsign;
    throw std::runtime_error("identity_cache_update_failed");  // Dispatcher 捕获后报告 identity_cache_update_failed
}

Callbacks::BmConnectionResult to_bm_result(const CommandResult& result)
{
    using Result = Callbacks::BmConnectionResult;
    if (result.status == CommandStatus::accepted) return Result::accepted;
    if (result.status == CommandStatus::idempotent) return Result::idempotent;
    const auto& detail = result.detail;
    if (detail == "bm_revision_stale") return Result::stale_revision;
    if (detail == "bm_revision_conflict") return Result::revision_conflict;
    if (detail == "bm_password_required") return Result::password_required;
    if (detail == "bm_master_resolution_failed") return Result::master_resolution_failed;
    if (detail == "bm_profile_invalid") return Result::profile_invalid;
    if (detail == "bm_transport_open_failed") return Result::transport_open_failed;
    return Result::transition_busy;
}

class Frontend final {
public:
    Frontend(const FrontendOptions& options, std::ofstream& status_file, ConsoleHandlerScope& control_scope)
        : options_(options), status_file_(status_file), control_scope_(control_scope),
          status_sequence_(options.status_sequence),
          writer_(GetStdHandle(STD_OUTPUT_HANDLE)) {}

    int run(StartConfig config);

private:
    void install_hooks(StartConfig& config);
    [[nodiscard]] Callbacks make_callbacks();
    [[nodiscard]] ui_control::StatusSnapshot control_snapshot() const;
    void request_stop(std::string_view failure_reason);
    void emit_routing_state_if_changed();
    void poll_ui_pipe();
    void poll_console_keys();

    const FrontendOptions& options_;
    std::ofstream& status_file_;
    ConsoleHandlerScope& control_scope_;
    std::uint64_t status_sequence_;  // 仅引擎线程在运行期写；主线程只读近似值用于 media_seq
    Engine engine_{};
    bounded_pipe_writer::Writer writer_;
    ui_control::Parser v1_parser_{};
    ui_control::JsonLineParser json_parser_{};
    std::unique_ptr<ui_control::Dispatcher> dispatcher_{};
    bool stop_requested_{};
    bool input_closed_{};
    bool initial_routing_state_sent_{};
    std::string last_routing_payload_{};
    ULONGLONG last_routing_check_tick_{};
    bool t_key_down_{};
    bool q_key_down_{};
    std::atomic<std::uint64_t> published_status_sequence_{0U};
};

void Frontend::install_hooks(StartConfig& config)
{
    config.diagnostics.status = [this](const StatusRecord& record) {
        if (status_sequence_ == std::numeric_limits<std::uint64_t>::max()) return false;
        ++status_sequence_;
        published_status_sequence_.store(status_sequence_, std::memory_order_relaxed);
        return append_status_line(status_file_, options_.run_id, status_sequence_, record);
    };
    config.diagnostics.console = [](std::string_view text, bool error_stream) {
        write_console_utf8(GetStdHandle(error_stream ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE), text);
    };
    // 原收尾顺序：关闭串口与 RPTCL 之后释放控制台关闭处理器，再写最终 stopped 状态。
    config.diagnostics.cleanup_complete = [this]() {
        const bool signal_ok = control_scope_.signal_cleanup_complete();
        const bool unregister_ok = control_scope_.unregister_now();
        return signal_ok && unregister_ok;
    };
    // 操作员提示沿用 R127：写往 stdout。BridgeSupervisor 只把含 "type":"control_*"/"routing_state"
    // 的行当协议帧，其余进入诊断日志。
}

ui_control::StatusSnapshot Frontend::control_snapshot() const
{
    const auto current = engine_.snapshot();
    ui_control::StatusSnapshot snapshot{};
    const bool failed = current->phase == Phase::failed || !current->failure_reason.empty();
    const bool stopping = stop_requested_ || current->phase == Phase::stopping ||
        current->phase == Phase::stopped || current->phase == Phase::failed;
    snapshot.mode = "running";
    snapshot.status = failed ? "failed" : (stopping ? "stopping" : "running");
    snapshot.phase = stopping ? "stopping" : (current->hri_ready ? "ready" : "starting");
    snapshot.media_seq = published_status_sequence_.load(std::memory_order_relaxed);
    snapshot.bm_connection.requested_enabled = current->bm_requested_enabled;
    snapshot.bm_connection.revision = current->bm_connection_revision;
    snapshot.bm_connection.transport_open = current->bm_transport_open;
    snapshot.bm_resolving = current->bm_resolving;
    snapshot.bm_connection_error = current->bm_error;
    snapshot.bm_state = bm_state_name(current->bm_state);
    snapshot.hri_phase = hri_phase_name(current->hri_phase);
    snapshot.hri_ready = current->hri_ready;
    snapshot.serial_open = current->serial_open;
    snapshot.wavein_open = current->wave_in_open;
    snapshot.waveout_open = current->wave_out_open;
    if (dispatcher_ && dispatcher_->supports_audio_gains()) {
        snapshot.audio_gains = ui_control::StatusSnapshot::AudioGains{
            dispatcher_->audio_gains_revision(),
            current->radio_playback_gain_milli, current->mic_transmit_gain_milli};
    }
    return snapshot;
}

Callbacks Frontend::make_callbacks()
{
    Callbacks callbacks{};
    // local_source_id 由 run() 设置。
    callbacks.replace_rx_policy = [this](std::uint64_t revision, const talkgroup_routing::RxPolicy& policy) {
        return to_policy_result(await(engine_.replace_rx_policy(revision, policy)));
    };
    callbacks.replace_tx_policy = [this](std::uint64_t revision, const talkgroup_routing::TxTarget& target,
                                         bool enabled) {
        return to_policy_result(await(engine_.replace_tx_policy(revision, target, enabled)));
    };
    callbacks.quick_call_join = [this](const talkgroup_routing::GroupRoute& group) {
        return to_quick_call_outcome(await(engine_.quick_call_join(group)));
    };
    callbacks.update_radio_identity = [this](std::uint32_t source_id, std::uint64_t revision,
                                             std::optional<std::string_view> callsign) {
        std::optional<std::string> owned;
        if (callsign.has_value()) owned.emplace(*callsign);
        return to_identity_result(await(engine_.upsert_radio_identity(source_id, revision, std::move(owned))),
                                  callsign.has_value());
    };
    callbacks.set_audio_gains = [this](std::uint32_t radio_gain, std::uint32_t mic_gain) {
        const auto result = await(engine_.set_audio_gains(radio_gain, mic_gain));
        const auto current = engine_.snapshot();
        const bool applied = result.status == CommandStatus::accepted;
        return Callbacks::AudioGainApplyResult{applied,
            current->radio_playback_gain_milli, current->mic_transmit_gain_milli};
    };
    callbacks.snapshot_json = [this]() { return engine_.snapshot()->routing_json; };
    callbacks.set_bm_connection = [this](bool enabled, std::uint64_t revision) {
        const auto result = await(engine_.set_bm_connection(enabled, revision));
        return Callbacks::BmConnectionOutcome{to_bm_result(result), control_snapshot()};
    };
    return callbacks;
}

void Frontend::request_stop(std::string_view failure_reason)
{
    if (stop_requested_) return;
    stop_requested_ = true;
    (void)engine_.stop_with_reason(std::string(failure_reason));
}

void Frontend::emit_routing_state_if_changed()
{
    if (!dispatcher_ || !dispatcher_->hello_seen() || stop_requested_) return;
    const auto now = GetTickCount64();
    if (initial_routing_state_sent_ && now - last_routing_check_tick_ < routing_check_interval_ms) return;
    last_routing_check_tick_ = now;
    const auto current = engine_.snapshot()->routing_json;
    if (current.empty() || (initial_routing_state_sent_ && current == last_routing_payload_)) return;
    const auto line = dispatcher_->routing_state_line();
    if (line.empty()) return;
    if (!writer_.write_line(line)) {
        request_stop("ui_routing_state_stdout_write_failed");
        return;
    }
    initial_routing_state_sent_ = true;
    last_routing_payload_ = current;
}

void Frontend::poll_ui_pipe()
{
    if (input_closed_) return;
    const HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    const bool v2 = options_.ui_control_version == 2U;
    auto handle_eof = [&]() {
        input_closed_ = true;
        if (v2 && !json_parser_.eof_at_frame_boundary()) {
            (void)writer_.write_line(dispatcher_->reject("partial_frame_at_eof").json_line);
            request_stop("ui_control_partial_frame_at_eof");
        } else {
            (void)v1_parser_.eof();
            request_stop({});
        }
    };
    auto is_eof_error = [](DWORD error) {
        return error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA || error == ERROR_HANDLE_EOF ||
            error == ERROR_PIPE_NOT_CONNECTED;
    };
    DWORD available = 0U;
    if (!PeekNamedPipe(input, nullptr, 0U, nullptr, &available, nullptr)) {
        if (is_eof_error(GetLastError())) {
            handle_eof();
        } else {
            input_closed_ = true;
            request_stop("ui_control_pipe_poll_failed");
        }
        return;
    }
    if (available == 0U) return;
    std::array<char, 4096U> command_bytes{};
    DWORD actual = 0U;
    const DWORD wanted = std::min<DWORD>(available, static_cast<DWORD>(command_bytes.size()));
    const BOOL read_succeeded = ReadFile(input, command_bytes.data(), wanted, &actual, nullptr);
    if (read_succeeded != FALSE && actual == 0U) {
        handle_eof();
        return;
    }
    if (read_succeeded == FALSE || actual > wanted) {
        if (is_eof_error(GetLastError())) {
            handle_eof();
        } else {
            input_closed_ = true;
            request_stop("ui_control_pipe_read_failed");
        }
        return;
    }
    if (!v2) {
        const auto result = v1_parser_.feed(std::string_view(command_bytes.data(), actual));
        if (result == ui_control::Result::shutdown) {
            request_stop({});
        } else if (result == ui_control::Result::invalid) {
            input_closed_ = true;
            request_stop("ui_control_input_invalid");
        }
        return;
    }
    std::vector<std::string> control_lines;
    const auto feed = json_parser_.feed(std::string_view(command_bytes.data(), actual), control_lines);
    if (feed == ui_control::JsonLineStatus::invalid) {
        (void)writer_.write_line(dispatcher_->reject("invalid_or_oversized_frame").json_line);
        input_closed_ = true;
        request_stop("ui_control_frame_invalid");
        return;
    }
    for (const auto& control_line : control_lines) {
        const auto response = dispatcher_->handle(control_line, control_snapshot());
        if (!writer_.write_line(response.json_line)) {
            request_stop("ui_control_stdout_write_failed");
            break;
        }
        emit_routing_state_if_changed();
        if (response.shutdown_requested) {
            request_stop({});
            break;
        }
    }
}

void Frontend::poll_console_keys()
{
    if (input_closed_) return;
    DWORD queued_keys = 0U;
    const HANDLE input_handle = GetStdHandle(STD_INPUT_HANDLE);
    if (input_handle == nullptr || input_handle == INVALID_HANDLE_VALUE ||
        !GetNumberOfConsoleInputEvents(input_handle, &queued_keys)) {
        input_closed_ = true;
        request_stop("console_key_poll_failed");
        return;
    }
    std::array<INPUT_RECORD, 32U> key_records{};
    while (queued_keys != 0U) {
        DWORD read = 0U;
        const DWORD count = std::min<DWORD>(queued_keys, static_cast<DWORD>(key_records.size()));
        if (!ReadConsoleInputW(input_handle, key_records.data(), count, &read) || read == 0U || read > count) {
            input_closed_ = true;
            request_stop("console_key_read_failed");
            return;
        }
        queued_keys -= read;
        for (DWORD index = 0U; index < read; ++index) {
            const auto& record = key_records[index];
            if (record.EventType != KEY_EVENT) continue;
            wchar_t key = record.Event.KeyEvent.uChar.UnicodeChar;
            if (key >= L'a' && key <= L'z') key = static_cast<wchar_t>(key - L'a' + L'A');
            if (record.Event.KeyEvent.bKeyDown) {
                if (key == L'T' && !t_key_down_) (void)await(engine_.manual_ptt_toggle());
                if (key == L'Q' && !q_key_down_) request_stop({});
                if (key == L'T') t_key_down_ = true;
                if (key == L'Q') q_key_down_ = true;
            } else {
                if (key == L'T') t_key_down_ = false;
                if (key == L'Q') q_key_down_ = false;
            }
        }
    }
}

int Frontend::run(StartConfig config)
{
    install_hooks(config);
    const bool v2 = options_.ui_pipe && options_.ui_control_version == 2U;
    if (v2) {
        auto callbacks = make_callbacks();
        callbacks.local_source_id = config.local_source_id;
        try {
            dispatcher_ = std::make_unique<ui_control::Dispatcher>(options_.run_id, false, std::move(callbacks));
        } catch (...) {
            return 2;
        }
        if (!writer_.enable_nonblocking() || !writer_.write_line(dispatcher_->ready_line(GetCurrentProcessId()))) {
            write_console_utf8(GetStdHandle(STD_ERROR_HANDLE),
                u8"无法发出 v2 control_ready；未打开 HRI、音频或BM传输。\n");
            return 2;
        }
    }

    auto started = engine_.start(std::move(config));
    // 引擎打开设备期间仍处理控制输入（原实现在设备打开前后检查 UI 管道）。
    bool start_resolved = false;
    CommandResult start_result{};
    for (;;) {
        if (!start_resolved && started.wait_for(std::chrono::milliseconds{0}) == std::future_status::ready) {
            try { start_result = started.get(); }
            catch (...) { start_result = CommandResult{CommandStatus::failed, 0U, "engine_start_failed"}; }
            start_resolved = true;
            if (start_result.status != CommandStatus::accepted) break;
        }
        if (!stop_requested_ && control_scope_.cancel_requested()) request_stop({});
        if (control_scope_.close_wait_timed_out()) {
            engine_.force_stop_now("console_close_cleanup_deadline_expired");
        }
        if (options_.ui_pipe) poll_ui_pipe();
        else poll_console_keys();
        if (v2) emit_routing_state_if_changed();
        if (engine_.wait_stopped(std::chrono::milliseconds{5})) break;
    }

    // 有界收尾：Engine 自身在 3 s 内完成媒体收尾；这里额外给控制台关闭等待留出余量。
    if (!engine_.wait_stopped(std::chrono::seconds{10})) {
        engine_.force_stop_now("cleanup_deadline_exceeded");
        if (!engine_.wait_stopped(std::chrono::seconds{2})) return 2;
    }
    // 启动阶段失败（没有打开设备或已在引擎内关闭）：与原实现相同退出码 2。
    if (start_resolved && start_result.status != CommandStatus::accepted) return 2;
    const auto final_snapshot = engine_.snapshot();
    return final_snapshot->phase == Phase::stopped ? 0 : 2;
}

} // namespace

int run_engine_frontend(StartConfig config, const FrontendOptions& options,
                        std::ofstream& status_file, ConsoleHandlerScope& control_scope)
{
    try {
        Frontend frontend(options, status_file, control_scope);
        return frontend.run(std::move(config));
    } catch (...) {
        write_console_utf8(GetStdHandle(STD_ERROR_HANDLE),
            u8"Native 引擎前端异常；已请求有界收尾。\n");
        return 2;
    }
}

} // namespace wirex::engine::adapter
