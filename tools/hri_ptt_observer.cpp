#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <conio.h>

#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"
#include "wirex/hri_session.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
std::atomic_bool g_cancel_requested{false};

class UniqueHandle {
public:
    explicit UniqueHandle(HANDLE handle = INVALID_HANDLE_VALUE) noexcept : handle_(handle) {}
    ~UniqueHandle() { reset(); }
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;

    [[nodiscard]] HANDLE get() const noexcept { return handle_; }
    [[nodiscard]] bool valid() const noexcept { return handle_ != INVALID_HANDLE_VALUE && handle_ != nullptr; }
    void reset(HANDLE handle = INVALID_HANDLE_VALUE) noexcept
    {
        if (valid()) CloseHandle(handle_);
        handle_ = handle;
    }

private:
    HANDLE handle_;
};

BOOL WINAPI console_control_handler(DWORD control) noexcept
{
    if (control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT || control == CTRL_CLOSE_EVENT) {
        g_cancel_requested.store(true, std::memory_order_relaxed);
        return TRUE;
    }
    return FALSE;
}

std::wstring win_error(DWORD code)
{
    wchar_t* message = nullptr;
    const DWORD count = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code, 0, reinterpret_cast<LPWSTR>(&message), 0, nullptr);
    std::wstring result = count != 0 && message != nullptr ? message : L"Windows error";
    if (message != nullptr) LocalFree(message);
    while (!result.empty() && (result.back() == L'\r' || result.back() == L'\n' || result.back() == L' ')) result.pop_back();
    return result;
}

bool parse_com_name(std::wstring_view name, std::wstring& path)
{
    if (name.size() < 4 || name.size() > 6 ||
        (name[0] != L'C' && name[0] != L'c') ||
        (name[1] != L'O' && name[1] != L'o') ||
        (name[2] != L'M' && name[2] != L'm')) return false;
    unsigned number = 0;
    for (const wchar_t ch : name.substr(3)) {
        if (ch < L'0' || ch > L'9') return false;
        number = number * 10U + static_cast<unsigned>(ch - L'0');
    }
    if (number == 0 || number > 999U) return false;
    path = L"\\\\.\\" + std::wstring(name);
    return true;
}

bool load_y_body(const std::filesystem::path& path, std::vector<std::uint8_t>& body)
{
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    if (error || size != wirex::hri_session::y_body_size) return false;

    std::ifstream file(path, std::ios::binary);
    if (!file) return false;
    body.assign(wirex::hri_session::y_body_size, 0);
    file.read(reinterpret_cast<char*>(body.data()), static_cast<std::streamsize>(body.size()));
    if (file.gcount() != static_cast<std::streamsize>(body.size()) || file.bad() || body[5] != '2') {
        body.clear();
        return false;
    }
    return true;
}

bool configure_serial(HANDLE port)
{
    DCB dcb{};
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(port, &dcb)) {
        std::wcerr << L"GetCommState failed: " << win_error(GetLastError()) << L"\n";
        return false;
    }
    dcb.BaudRate = CBR_115200;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    dcb.fParity = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDsrSensitivity = FALSE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;
    dcb.fDtrControl = DTR_CONTROL_DISABLE;
    dcb.fRtsControl = RTS_CONTROL_DISABLE;
    dcb.fNull = FALSE;
    dcb.fErrorChar = FALSE;
    dcb.fAbortOnError = FALSE;
    if (!SetCommState(port, &dcb)) {
        std::wcerr << L"SetCommState failed: " << win_error(GetLastError()) << L"\n";
        return false;
    }

    COMMTIMEOUTS timeouts{};
    timeouts.ReadIntervalTimeout = 20;
    timeouts.ReadTotalTimeoutConstant = 100;
    timeouts.WriteTotalTimeoutConstant = 250;
    if (!SetCommTimeouts(port, &timeouts)) {
        std::wcerr << L"SetCommTimeouts failed: " << win_error(GetLastError()) << L"\n";
        return false;
    }
    if (!SetupComm(port, 4096, 4096)) {
        std::wcerr << L"SetupComm failed: " << win_error(GetLastError()) << L"\n";
        return false;
    }
    return true;
}

bool pre_drain_serial(HANDLE port, std::uint64_t& discarded_bytes)
{
    constexpr std::uint64_t max_drain_bytes = 4096;
    constexpr auto max_drain_time = std::chrono::milliseconds(250);
    constexpr auto quiet_time = std::chrono::milliseconds(20);
    std::array<std::uint8_t, 512> buffer{};
    const auto started = Clock::now();
    auto quiet_since = started;
    discarded_bytes = 0;
    while (Clock::now() - started < max_drain_time) {
        DWORD errors = 0;
        COMSTAT state{};
        if (!ClearCommError(port, &errors, &state) || errors != 0) {
            std::cerr << "Serial pre-drain could not establish a clean read state.\n";
            return false;
        }
        if (state.cbInQue != 0) {
            if (discarded_bytes >= max_drain_bytes) {
                std::cerr << "Serial pre-drain reached its 4096-byte discard limit.\n";
                return false;
            }
            const auto remaining = static_cast<DWORD>(max_drain_bytes - discarded_bytes);
            const DWORD requested = std::min<DWORD>(state.cbInQue,
                std::min<DWORD>(static_cast<DWORD>(buffer.size()), remaining));
            DWORD actual = 0;
            if (!ReadFile(port, buffer.data(), requested, &actual, nullptr) || actual > requested) {
                std::cerr << "Serial pre-drain read failed or returned an invalid count.\n";
                return false;
            }
            if (actual != 0) {
                discarded_bytes += actual;
                quiet_since = Clock::now();
            }
            continue;
        }
        if (Clock::now() - quiet_since >= quiet_time) return true;
        Sleep(2);
    }
    std::cerr << "Serial pre-drain did not reach 20 ms of quiet within 250 ms.\n";
    return false;
}

bool safe_command(const wirex::hri_session::Command& command)
{
    const auto decoded = wirex::direct_frame::decode(command.frame.data(), command.frame.size());
    if (!decoded) return false;
    switch (command.kind) {
    case wirex::hri_session::CommandKind::version_query:
        return decoded.record.type == 'V' && decoded.record.payload.empty();
    case wirex::hri_session::CommandKind::y_record:
        return decoded.record.type == 'Y' && decoded.record.payload.size() == wirex::hri_session::y_body_size &&
            decoded.record.payload[5] == '2';
    case wirex::hri_session::CommandKind::x_ack:
        return decoded.record.type == 'X' && decoded.record.payload.empty();
    }
    return false;
}

const char* stop_reason_name(wirex::hri_session::StopReason reason) noexcept
{
    using wirex::hri_session::StopReason;
    switch (reason) {
    case StopReason::none: return "none";
    case StopReason::deadline: return "120s_deadline";
    case StopReason::version_timeout: return "version_timeout";
    case StopReason::y_ack_timeout: return "y_ack_timeout";
    case StopReason::cancelled: return "cancelled";
    case StopReason::malformed_record: return "malformed_record";
    case StopReason::version_mismatch: return "version_mismatch";
    case StopReason::transport_failure: return "transport_failure";
    case StopReason::write_failed: return "write_failed";
    case StopReason::y_write_limit: return "y_write_limit";
    case StopReason::x_ack_limit: return "x_ack_limit";
    default: return "session_stopped";
    }
}

bool dispatch_commands(const wirex::hri_session::Update& update,
                       wirex::hri_session::Session& session,
                       HANDLE port,
                       std::uint64_t now_ms)
{
    for (const auto& command : update.commands) {
        if (session.snapshot().phase == wirex::hri_session::Phase::stopped) return false;
        if (!safe_command(command)) {
            std::cerr << "Refusing a command outside the V query, validated Y fixture, and empty X acknowledgement allowlist.\n";
            (void)session.abort(wirex::hri_session::StopReason::transport_failure);
            return false;
        }

        DWORD written = 0;
        const BOOL ok = WriteFile(port, command.frame.data(), static_cast<DWORD>(command.frame.size()), &written, nullptr);
        const bool full_write = ok != FALSE && written == command.frame.size();
        const auto completed = session.write_completed(command.id, full_write, now_ms);
        if (!full_write) {
            std::cerr << "Allowed HRI command write failed or was short; error=" << GetLastError() << ".\n";
            return false;
        }
        if (completed.state.phase == wirex::hri_session::Phase::stopped) return false;
        if (command.kind == wirex::hri_session::CommandKind::y_record) {
            std::cout << "t_ms=" << now_ms << " event=Y_write_completed y_writes="
                      << completed.state.counters.y_write_completed << "\n" << std::flush;
        }
    }
    return session.snapshot().phase != wirex::hri_session::Phase::stopped;
}

void log_records(const wirex::direct_stream::FeedResult& parsed,
                 std::uint64_t now_ms,
                 std::uint64_t completed_y_writes)
{
    for (const auto& event : parsed.events) {
        if (!event.has_record) {
            std::cout << "t_ms=" << now_ms << " event=invalid_record y_writes=" << completed_y_writes << "\n";
            continue;
        }
        const auto& record = event.record;
        std::cout << "t_ms=" << now_ms << " record_type=0x" << std::hex << std::uppercase
                  << static_cast<unsigned>(record.type) << std::dec << std::nouppercase
                  << " payload_len=" << record.payload.size();
        if (record.type == 'X' && record.payload.size() == wirex::hri_session::y_body_size) {
            const auto config_marker = record.payload[11];
            const auto candidate = record.payload[12];
            std::cout << " x11_config_marker=0x" << std::hex << std::uppercase
                      << static_cast<unsigned>(config_marker)
                      << " x12_candidate=0x" << static_cast<unsigned>(candidate)
                      << std::dec << std::nouppercase;
        }
        std::cout << " y_writes=" << completed_y_writes << "\n" << std::flush;
    }
}

enum class OperatorMarkerState {
    none,
    baseline_released,
    press_marked,
    release_marked,
};

void process_operator_markers(std::uint64_t now_ms,
                              std::uint64_t completed_y_writes,
                              OperatorMarkerState& state)
{
    while (_kbhit() != 0) {
        const int key = _getch();
        const char marker = static_cast<char>(key);
        if (marker == '1' && state != OperatorMarkerState::press_marked) {
            state = OperatorMarkerState::baseline_released;
            std::cout << "t_ms=" << now_ms << " operator_marker=baseline_released"
                      << " y_writes=" << completed_y_writes << "\n" << std::flush;
        } else if (marker == '2' && (state == OperatorMarkerState::baseline_released ||
                                     state == OperatorMarkerState::release_marked)) {
            state = OperatorMarkerState::press_marked;
            std::cout << "t_ms=" << now_ms << " operator_marker=press_marked"
                      << " y_writes=" << completed_y_writes << "\n" << std::flush;
        } else if (marker == '3' && state == OperatorMarkerState::press_marked) {
            state = OperatorMarkerState::release_marked;
            std::cout << "t_ms=" << now_ms << " operator_marker=release_marked"
                      << " y_writes=" << completed_y_writes << "\n" << std::flush;
        } else if (marker == '1' || marker == '2' || marker == '3') {
            std::cout << "t_ms=" << now_ms << " operator_marker_rejected=" << marker
                      << " reason=unexpected_order y_writes=" << completed_y_writes << "\n" << std::flush;
        }
    }
}

void print_usage()
{
    std::wcout << L"Usage: hri_ptt_observer.exe --port COMn --body-file <private-100-byte-Y-fixture>\n"
        L"Runs one foreground observation window of at most 120 seconds.\n"
        L"The log contains record type/length/time, X[11]/X[12] single-byte metadata, HRI counters, and PTT observation counts.\n"
        L"The observer sends only the existing V query, the supplied validated Y fixture, and empty X acknowledgements.\n"
        L"It does not send T/PTT/CAT commands, open audio, connect to a network service, or save received payloads.\n";
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCtrlHandler(console_control_handler, TRUE);

    std::wstring port_name;
    std::filesystem::path body_path;
    for (int i = 1; i < argc; ++i) {
        const std::wstring_view arg(argv[i]);
        if (arg == L"--help" || arg == L"-h") {
            print_usage();
            return 0;
        }
        if ((arg == L"--port" || arg == L"--body-file") && i + 1 < argc) {
            const std::wstring_view value(argv[++i]);
            if (arg == L"--port") port_name.assign(value);
            else body_path.assign(value);
            continue;
        }
        std::wcerr << L"Unknown or incomplete argument.\n";
        print_usage();
        return 2;
    }

    std::wstring device_path;
    if (!parse_com_name(port_name, device_path) || body_path.empty()) {
        print_usage();
        return 2;
    }

    std::vector<std::uint8_t> y_body;
    if (!load_y_body(body_path, y_body)) {
        std::wcerr << L"The private Y fixture must be readable, exactly 100 bytes, and have ASCII '2' at byte 5.\n";
        return 2;
    }

    std::wcout << L"HRI hand-mic PTT candidate observer: " << port_name << L", maximum 120 seconds.\n"
        L"The tool will open the specified COM port and send only V, the supplied Y fixture, and empty X acknowledgements.\n"
        L"It never writes T/PTT/CAT commands, opens audio, or starts network speech. Press Ctrl+C to stop.\n"
        L"No raw HRI payload is logged.\n"
        L"Local timing markers: press 1 for released baseline, 2 when physically pressing and holding, 3 after releasing.\n"
        L"These keys only annotate the console log; they never write to COM.\n"
        L"No raw payload or audio is written to disk.\n" << std::flush;

    UniqueHandle port(CreateFileW(device_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!port.valid()) {
        std::wcerr << L"Cannot open " << port_name << L": " << win_error(GetLastError()) << L"\n";
        return 2;
    }
    if (!configure_serial(port.get())) return 2;
    COMMTIMEOUTS hri_timeouts{};
    hri_timeouts.ReadIntervalTimeout = 5;
    hri_timeouts.ReadTotalTimeoutConstant = 10;
    hri_timeouts.WriteTotalTimeoutConstant = 100;
    if (!SetCommTimeouts(port.get(), &hri_timeouts)) {
        std::wcerr << L"Could not set the native HRI serial timeouts: " << win_error(GetLastError()) << L"\n";
        return 2;
    }
    std::uint64_t discarded_bytes = 0;
    if (!pre_drain_serial(port.get(), discarded_bytes)) return 2;
    std::wcout << L"Port config: 115200 8N1, flow control off, DTR=false, RTS=false; pre-drain discarded "
               << discarded_bytes << L" bytes, then observed 20 ms quiet (250 ms maximum).\n" << std::flush;

    wirex::hri_session::Session session(std::move(y_body),
        wirex::hri_session::Config{wirex::hri_session::max_window_ms});
    wirex::direct_stream::Parser metadata_parser(wirex::hri_session::max_frame_bytes -
        wirex::direct_frame::fixed_overhead);
    const auto started_at = Clock::now();
    auto elapsed_ms = [&]() -> std::uint64_t {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - started_at).count();
        return elapsed < 0 ? 0U : static_cast<std::uint64_t>(elapsed);
    };

    auto initial = session.start(0);
    if (!dispatch_commands(initial, session, port.get(), elapsed_ms())) {
        std::cerr << "Could not start the bounded HRI exchange.\n";
        return 2;
    }

    std::array<std::uint8_t, 1024> receive_buffer{};
    bool transport_failed = false;
    bool announced_y0 = false;
    std::uint64_t ptt_observations_total = 0;
    OperatorMarkerState marker_state = OperatorMarkerState::none;
    while (session.snapshot().phase != wirex::hri_session::Phase::stopped) {
        if (g_cancel_requested.load(std::memory_order_relaxed)) {
            (void)session.cancel();
            break;
        }

        const auto now = elapsed_ms();
        process_operator_markers(now, session.snapshot().counters.y_write_completed, marker_state);
        auto update = session.tick(now);
        if (update.state.phase == wirex::hri_session::Phase::stopped) break;
        if (!dispatch_commands(update, session, port.get(), now)) break;

        DWORD comm_errors = 0;
        COMSTAT comm_state{};
        if (!ClearCommError(port.get(), &comm_errors, &comm_state) || comm_errors != 0) {
            std::cerr << "Serial status error; no further commands will be sent.\n";
            transport_failed = true;
            (void)session.abort(wirex::hri_session::StopReason::transport_failure);
            break;
        }
        if (comm_state.cbInQue != 0) {
            const DWORD request = std::min<DWORD>(comm_state.cbInQue, static_cast<DWORD>(receive_buffer.size()));
            DWORD actual = 0;
            if (!ReadFile(port.get(), receive_buffer.data(), request, &actual, nullptr) || actual > request) {
                std::cerr << "Serial read failed; no further commands will be sent.\n";
                transport_failed = true;
                (void)session.abort(wirex::hri_session::StopReason::transport_failure);
                break;
            }
            if (actual != 0) {
                const auto read_at = elapsed_ms();
                const auto metadata = metadata_parser.feed(receive_buffer.data(), actual);
                log_records(metadata, read_at, session.snapshot().counters.y_write_completed);

                update = session.feed(receive_buffer.data(), actual, read_at);
                const auto& counts = update.state.counters;
                ptt_observations_total += update.ptt_observations.size();
                std::cout << "t_ms=" << read_at
                          << " event=session_update"
                          << " hri_phase=" << static_cast<unsigned>(update.state.phase)
                          << " y0_records=" << counts.y_zero_ack_received
                          << " x100_records=" << counts.x100_received
                          << " x_copy_records=" << counts.x_copy_branch_count
                          << " x_config_records=" << counts.unsupported_config_import_records
                          << " ptt_observations_in_update=" << update.ptt_observations.size()
                          << " ptt_observations_total=" << ptt_observations_total
                          << "\n" << std::flush;
                if (!dispatch_commands(update, session, port.get(), read_at)) break;
                if (update.state.y_zero_acknowledged && !announced_y0) {
                    announced_y0 = true;
                    std::cout << "t_ms=" << read_at << " event=Y0_observed; continue only with separately authorized manual observation.\n"
                              << std::flush;
                }
            }
        } else {
            Sleep(10);
        }
    }

    const auto final = session.snapshot();
    std::cout << "observer_stopped reason=" << stop_reason_name(final.stop_reason)
              << " elapsed_ms=" << elapsed_ms()
              << " y0_records=" << final.counters.y_zero_ack_received
              << " x100_records=" << final.counters.x100_received
              << " x_copy_records=" << final.counters.x_copy_branch_count
              << " x_config_records=" << final.counters.unsupported_config_import_records
              << " ptt_observations=" << ptt_observations_total
              << " y_writes=" << final.counters.y_write_completed
              << " x_ack_writes=" << final.counters.x0_write_completed
              << " transport_failed=" << (transport_failed ? "true" : "false") << "\n" << std::flush;
    return (final.stop_reason == wirex::hri_session::StopReason::deadline ||
            final.stop_reason == wirex::hri_session::StopReason::cancelled) && !transport_failed ? 0 : 2;
}
