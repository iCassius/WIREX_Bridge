#include "wirex/app/radio_cat.hpp"
#include "wirex/app/radio_info.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cwctype>
#include <exception>
#include <utility>

namespace wirex::app {
namespace {

using steady = std::chrono::steady_clock;
using std::chrono::milliseconds;

struct ModeEntry {
    CatMode mode;
    char code;
    std::string_view name;
};

constexpr std::array<ModeEntry, 18> mode_table{{
    {CatMode::unused, '0', "UNUSED"},
    {CatMode::lsb, '1', "LSB"},
    {CatMode::usb, '2', "USB"},
    {CatMode::cw_u, '3', "CW-U"},
    {CatMode::fm, '4', "FM"},
    {CatMode::am, '5', "AM"},
    {CatMode::rtty_l, '6', "RTTY-L"},
    {CatMode::cw_l, '7', "CW-L"},
    {CatMode::data_l, '8', "DATA-L"},
    {CatMode::rtty_u, '9', "RTTY-U"},
    {CatMode::data_fm, 'A', "DATA-FM"},
    {CatMode::fm_n, 'B', "FM-N"},
    {CatMode::data_u, 'C', "DATA-U"},
    {CatMode::am_n, 'D', "AM-N"},
    {CatMode::psk, 'E', "PSK"},
    {CatMode::data_fm_n, 'F', "DATA-FM-N"},
    {CatMode::c4fm_dn, 'H', "C4FM-DN"},
    {CatMode::c4fm_vw, 'I', "C4FM-VW"},
}};

constexpr std::array<std::uint32_t, 5> supported_baud_rates{4800U, 9600U, 19200U, 38400U, 115200U};

bool is_digit(char c) noexcept { return c >= '0' && c <= '9'; }

bool all_digits(std::string_view text) noexcept
{
    return !text.empty() && std::all_of(text.begin(), text.end(), is_digit);
}

std::uint32_t digits_value(std::string_view text) noexcept
{
    std::uint32_t value = 0U;
    for (const char c : text) value = value * 10U + static_cast<std::uint32_t>(c - '0');
    return value;
}

char ascii_upper(char c) noexcept { return c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c; }

bool iequals(std::string_view a, std::string_view b) noexcept
{
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0U; i < a.size(); ++i) {
        if (ascii_upper(a[i]) != ascii_upper(b[i])) return false;
    }
    return true;
}

CatFrame frame_error(CatFrameStatus status, CatError error)
{
    CatFrame frame;
    frame.status = status;
    frame.error = error;
    return frame;
}

bool parse_frequency_body(std::string_view frame, std::string_view prefix, CatFrame& out)
{
    // ^XX([0-9]{9});$
    if (frame.size() != 12U || frame.substr(0U, 2U) != prefix || frame.back() != ';') return false;
    const auto digits = frame.substr(2U, 9U);
    if (!all_digits(digits)) return false;
    out.frequency_hz = digits_value(digits);
    return true;
}

} // namespace

// ---------- 字符串映射 ----------

std::string_view to_string(CatMode mode) noexcept
{
    for (const auto& entry : mode_table) {
        if (entry.mode == mode) return entry.name;
    }
    return "UNKNOWN";
}

std::string_view to_string(CatError error) noexcept
{
    switch (error) {
    case CatError::none: return "none";
    case CatError::invalid_frame: return "invalid_frame";
    case CatError::radio_rejected_command: return "radio_rejected_command";
    case CatError::unexpected_response: return "unexpected_response";
    case CatError::frequency_out_of_range: return "frequency_out_of_range";
    case CatError::unknown_mode_code: return "unknown_mode_code";
    case CatError::power_out_of_range: return "power_out_of_range";
    case CatError::side_mismatch: return "side_mismatch";
    case CatError::identity_mismatch: return "identity_mismatch";
    case CatError::busy: return "busy";
    case CatError::hri_port_conflict: return "hri_port_conflict";
    case CatError::invalid_request: return "invalid_request";
    case CatError::power_mode_not_supported: return "power_mode_not_supported";
    case CatError::readback_mismatch: return "readback_mismatch";
    case CatError::core_not_stopped: return "core_not_stopped";
    case CatError::core_not_idle: return "core_not_idle";
    case CatError::write_not_authorized: return "write_not_authorized";
    case CatError::timeout: return "timeout";
    case CatError::cancelled: return "cancelled";
    case CatError::port_busy_or_denied: return "port_busy_or_denied";
    case CatError::serial_io_error: return "serial_io_error";
    case CatError::serial_close_failed: return "serial_close_failed";
    }
    return "error";
}

std::string_view to_string(CatResultStatus status) noexcept
{
    switch (status) {
    case CatResultStatus::confirmed: return "confirmed";
    case CatResultStatus::busy: return "busy";
    case CatResultStatus::identity_mismatch: return "identity_mismatch";
    case CatResultStatus::rejected: return "rejected";
    case CatResultStatus::mismatch: return "mismatch";
    case CatResultStatus::unknown: return "unknown";
    }
    return "unknown";
}

std::optional<CatMode> cat_mode_from_code(char code) noexcept
{
    for (const auto& entry : mode_table) {
        if (entry.code == code) return entry.mode;
    }
    return std::nullopt;
}

std::optional<CatMode> cat_mode_from_name(std::string_view name) noexcept
{
    for (const auto& entry : mode_table) {
        if (iequals(entry.name, name)) return entry.mode;
    }
    return std::nullopt;
}

char cat_mode_code(CatMode mode) noexcept
{
    for (const auto& entry : mode_table) {
        if (entry.mode == mode) return entry.code;
    }
    return '0';
}

bool cat_is_voice_mode(CatMode mode) noexcept
{
    return mode == CatMode::fm || mode == CatMode::fm_n || mode == CatMode::c4fm_dn || mode == CatMode::c4fm_vw;
}

int cat_power_path_max_watts(CatPowerPath path) noexcept
{
    return path == CatPowerPath::field_head ? 10 : cat_app_max_power_watts;
}

CatResultStatus cat_status_for_error(CatError error) noexcept
{
    switch (error) {
    case CatError::none: return CatResultStatus::confirmed;
    case CatError::busy: return CatResultStatus::busy;
    case CatError::identity_mismatch: return CatResultStatus::identity_mismatch;
    case CatError::hri_port_conflict:
    case CatError::power_out_of_range:
    case CatError::frequency_out_of_range:
    case CatError::power_mode_not_supported:
    case CatError::invalid_request:
    case CatError::radio_rejected_command:
    case CatError::core_not_stopped:
    case CatError::core_not_idle:
    case CatError::write_not_authorized:
        return CatResultStatus::rejected;
    case CatError::readback_mismatch: return CatResultStatus::mismatch;
    default: return CatResultStatus::unknown;
    }
}

// ---------- 帧构造 ----------

std::string_view cat_read_command(CatCommand command) noexcept
{
    switch (command) {
    case CatCommand::id: return "ID;";
    case CatCommand::ai: return "AI;";
    case CatCommand::tx: return "TX;";
    case CatCommand::fa: return "FA;";
    case CatCommand::fb: return "FB;";
    case CatCommand::md: return "MD0;";
    case CatCommand::pc: return "PC;";
    }
    return "ID;";
}

std::string_view cat_mode_read_command(CatSide side) noexcept
{
    return side == CatSide::main ? "MD0;" : "MD1;";
}

std::optional<std::string> cat_frequency_command(std::uint32_t frequency_hz)
{
    if (frequency_hz < cat_min_frequency_hz || frequency_hz > cat_max_frequency_hz) return std::nullopt;
    char buffer[16]{};
    const int written = std::snprintf(buffer, sizeof(buffer), "FA%09u;", static_cast<unsigned>(frequency_hz));
    if (written != 12) return std::nullopt;
    return std::string(buffer, static_cast<std::size_t>(written));
}

std::optional<std::string> cat_mode_command(CatSide side, CatMode mode)
{
    if (!cat_is_voice_mode(mode)) return std::nullopt;
    std::string frame = "MD";
    frame.push_back(side == CatSide::main ? '0' : '1');
    frame.push_back(cat_mode_code(mode));
    frame.push_back(';');
    return frame;
}

std::optional<std::string> cat_power_command(CatPowerPath path, int watts)
{
    if (watts < cat_app_min_power_watts || watts > cat_power_path_max_watts(path)) return std::nullopt;
    char buffer[16]{};
    const int written = std::snprintf(buffer, sizeof(buffer), "PC%c%03d;",
                                      path == CatPowerPath::field_head ? '1' : '2', watts);
    if (written != 7) return std::nullopt;
    return std::string(buffer, static_cast<std::size_t>(written));
}

// ---------- 解析 ----------

bool cat_frame_command(std::string_view frame, std::string_view& command) noexcept
{
    if (frame.size() < 3U || frame.back() != ';') return false;
    for (std::size_t i = 0U; i < 2U; ++i) {
        if (frame[i] < 'A' || frame[i] > 'Z') return false;
    }
    for (std::size_t i = 2U; i + 1U < frame.size(); ++i) {
        const auto byte = static_cast<unsigned char>(frame[i]);
        if (byte < 0x20U || byte > 0x7eU) return false;
    }
    command = frame.substr(0U, 2U);
    return true;
}

CatFrame cat_parse_frame(std::string_view frame, CatCommand expected)
{
    if (frame.empty() || frame.size() > cat_max_frame_length) {
        return frame_error(CatFrameStatus::protocol_error, CatError::invalid_frame);
    }
    const auto is_space = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'; };
    if (is_space(frame.front()) || is_space(frame.back())) {
        return frame_error(CatFrameStatus::protocol_error, CatError::invalid_frame);
    }
    if (frame == "?;") return frame_error(CatFrameStatus::radio_error, CatError::radio_rejected_command);

    CatFrame out;
    out.status = CatFrameStatus::ok;
    out.error = CatError::none;
    const auto unexpected = frame_error(CatFrameStatus::protocol_error, CatError::unexpected_response);
    switch (expected) {
    case CatCommand::id:
        if (frame.size() != 7U || frame.substr(0U, 2U) != "ID" || frame.back() != ';' ||
            !all_digits(frame.substr(2U, 4U))) return unexpected;
        out.radio_id = std::string(frame.substr(2U, 4U));
        return out;
    case CatCommand::ai:
        if (frame.size() != 4U || frame.substr(0U, 2U) != "AI" || frame.back() != ';' ||
            (frame[2] != '0' && frame[2] != '1')) return unexpected;
        out.auto_information = frame[2] == '1';
        return out;
    case CatCommand::tx:
        if (frame.size() != 4U || frame.substr(0U, 2U) != "TX" || frame.back() != ';' ||
            frame[2] < '0' || frame[2] > '2') return unexpected;
        out.tx_state = frame[2] - '0';
        return out;
    case CatCommand::fa:
    case CatCommand::fb:
        if (!parse_frequency_body(frame, expected == CatCommand::fa ? "FA" : "FB", out)) return unexpected;
        if (out.frequency_hz < cat_min_frequency_hz || out.frequency_hz > cat_max_frequency_hz) {
            return frame_error(CatFrameStatus::protocol_error, CatError::frequency_out_of_range);
        }
        return out;
    case CatCommand::md: {
        // ^MD([01])([0-9A-I]);$
        if (frame.size() != 5U || frame.substr(0U, 2U) != "MD" || frame.back() != ';' ||
            (frame[2] != '0' && frame[2] != '1')) return unexpected;
        const char code = frame[3];
        if (!is_digit(code) && (code < 'A' || code > 'I')) return unexpected;
        const auto mode = cat_mode_from_code(code);
        if (!mode) return frame_error(CatFrameStatus::protocol_error, CatError::unknown_mode_code);
        out.mode = {frame[2] == '0' ? CatSide::main : CatSide::sub, *mode};
        return out;
    }
    case CatCommand::pc: {
        // ^PC([12])([0-9]{3});$；解析范围 FieldHead 5..10，路径 2 5..100（应用写入上限另为 50）
        if (frame.size() != 7U || frame.substr(0U, 2U) != "PC" || frame.back() != ';' ||
            (frame[2] != '1' && frame[2] != '2') || !all_digits(frame.substr(3U, 3U))) return unexpected;
        const auto path = frame[2] == '1' ? CatPowerPath::field_head : CatPowerPath::spa1;
        const int watts = static_cast<int>(digits_value(frame.substr(3U, 3U)));
        const int maximum = path == CatPowerPath::field_head ? 10 : 100;
        if (watts < 5 || watts > maximum) {
            return frame_error(CatFrameStatus::protocol_error, CatError::power_out_of_range);
        }
        out.power = {path, watts};
        return out;
    }
    }
    return unexpected;
}

CatFrameAssembler::Step CatFrameAssembler::push(char byte, std::string& complete_frame)
{
    if (byte == ';') {
        buffer_.push_back(';');
        complete_frame = std::move(buffer_);
        buffer_.clear();
        return Step::complete;
    }
    const auto value = static_cast<unsigned char>(byte);
    if (value < 0x20U || value > 0x7eU) {
        buffer_.clear();
        return Step::invalid;
    }
    buffer_.push_back(byte);
    if (buffer_.size() > cat_max_frame_length) {
        buffer_.clear();
        return Step::invalid;
    }
    return Step::need_more;
}

std::wstring cat_normalize_port_name(std::wstring_view port)
{
    std::size_t begin = 0U;
    std::size_t end = port.size();
    while (begin < end && std::iswspace(port[begin])) ++begin;
    while (end > begin && std::iswspace(port[end - 1U])) --end;
    std::wstring normalized(port.substr(begin, end - begin));
    for (auto& c : normalized) {
        if (c >= L'a' && c <= L'z') c = static_cast<wchar_t>(c - L'a' + L'A');
    }
    if (normalized.rfind(L"\\\\.\\", 0U) == 0U) normalized.erase(0U, 4U);
    if (normalized.size() > 3U && normalized.compare(0U, 3U, L"COM") == 0) {
        std::size_t index = 3U;
        bool digits = true;
        for (std::size_t i = 3U; i < normalized.size(); ++i) {
            if (normalized[i] < L'0' || normalized[i] > L'9') { digits = false; break; }
        }
        if (digits) {
            while (index + 1U < normalized.size() && normalized[index] == L'0') ++index;
            normalized = L"COM" + normalized.substr(index);
        }
    }
    return normalized;
}

bool cat_is_valid_port_name(std::wstring_view port) noexcept
{
    if (port.size() < 4U || port.size() > 6U || port.substr(0U, 3U) != L"COM") return false;
    if (port[3] < L'1' || port[3] > L'9') return false;
    for (std::size_t i = 4U; i < port.size(); ++i) {
        if (port[i] < L'0' || port[i] > L'9') return false;
    }
    return true;
}

bool cat_is_supported_baud_rate(std::uint32_t baud_rate) noexcept
{
    return std::find(supported_baud_rates.begin(), supported_baud_rates.end(), baud_rate) != supported_baud_rates.end();
}

std::wstring cat_connection_key(const CatConnection& connection)
{
    return cat_normalize_port_name(connection.port_name) + L"|" + std::to_wstring(connection.baud_rate) +
           (connection.stop_bits == CatStopBits::two ? L"|Two" : L"|One");
}

// ---------- 门控 ----------

CatGateDecision cat_gate_mode_or_frequency(const CatCoreState& core) noexcept
{
    return core.core_stopped ? CatGateDecision::allowed : CatGateDecision::core_not_stopped;
}

CatGateDecision cat_gate_power(const CatCoreState& core, steady::time_point now) noexcept
{
    if (core.core_stopped) return CatGateDecision::allowed;
    if (!core.idle_status_at || *core.idle_status_at > now || now - *core.idle_status_at > cat_idle_status_max_age) {
        return CatGateDecision::core_not_idle;
    }
    if (core.active_call || core.tx_active || !core.receive_media_idle) return CatGateDecision::core_not_idle;
    return CatGateDecision::allowed;
}

CatGateDecision cat_gate_for(CatOperation operation, const CatCoreState& core, steady::time_point now) noexcept
{
    switch (operation) {
    case CatOperation::query: return CatGateDecision::allowed;
    case CatOperation::set_mode:
    case CatOperation::set_frequency: return cat_gate_mode_or_frequency(core);
    case CatOperation::set_power: return cat_gate_power(core, now);
    }
    return CatGateDecision::core_not_stopped;
}

void cat_merge_observed(CatObserved& existing, const CatObserved& fresh)
{
    const auto merge = [](auto& target, const auto& source) {
        if (source && !source->source.empty()) target = source;
    };
    merge(existing.radio_id, fresh.radio_id);
    merge(existing.auto_information, fresh.auto_information);
    merge(existing.tx_state, fresh.tx_state);
    merge(existing.main_frequency_hz, fresh.main_frequency_hz);
    merge(existing.sub_frequency_hz, fresh.sub_frequency_hz);
    merge(existing.main_mode, fresh.main_mode);
    merge(existing.sub_mode, fresh.sub_mode);
    merge(existing.power, fresh.power);
}

// ---------- Win32 串口 ----------

namespace {

class Win32CatTransport final : public CatTransport {
public:
    explicit Win32CatTransport(CatConnection connection) : connection_(std::move(connection)) {}
    ~Win32CatTransport() override
    {
        if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
    }
    Win32CatTransport(const Win32CatTransport&) = delete;
    Win32CatTransport& operator=(const Win32CatTransport&) = delete;

    CatIo open() override
    {
        const auto name = L"\\\\.\\" + cat_normalize_port_name(connection_.port_name);
        handle_ = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) {
            const DWORD error = GetLastError();
            return error == ERROR_ACCESS_DENIED || error == ERROR_SHARING_VIOLATION ? CatIo::denied : CatIo::io_error;
        }
        DCB dcb{};
        dcb.DCBlength = sizeof(dcb);
        if (!GetCommState(handle_, &dcb)) return CatIo::io_error;
        dcb.BaudRate = connection_.baud_rate;
        dcb.ByteSize = 8;
        dcb.Parity = NOPARITY;
        dcb.StopBits = connection_.stop_bits == CatStopBits::two ? TWOSTOPBITS : ONESTOPBIT;
        dcb.fBinary = TRUE;
        dcb.fParity = FALSE;
        dcb.fOutxCtsFlow = FALSE;
        dcb.fOutxDsrFlow = FALSE;
        dcb.fDtrControl = DTR_CONTROL_DISABLE;
        dcb.fRtsControl = RTS_CONTROL_DISABLE;
        dcb.fDsrSensitivity = FALSE;
        dcb.fOutX = FALSE;
        dcb.fInX = FALSE;
        dcb.fNull = FALSE;
        dcb.fAbortOnError = FALSE;
        if (!SetCommState(handle_, &dcb)) return CatIo::io_error;
        if (!EscapeCommFunction(handle_, CLRDTR) || !EscapeCommFunction(handle_, CLRRTS)) return CatIo::io_error;
        return CatIo::ok;
    }

    CatIo clear_input() override
    {
        pending_.clear();
        assembler_.reset();
        return PurgeComm(handle_, PURGE_RXCLEAR) ? CatIo::ok : CatIo::io_error;
    }

    CatIo write_frame(std::string_view frame, milliseconds timeout) override
    {
        COMMTIMEOUTS timeouts{};
        timeouts.ReadIntervalTimeout = MAXDWORD;
        timeouts.WriteTotalTimeoutConstant = clamp_ms(timeout);
        if (!SetCommTimeouts(handle_, &timeouts)) return CatIo::io_error;
        DWORD written = 0;
        if (!WriteFile(handle_, frame.data(), static_cast<DWORD>(frame.size()), &written, nullptr)) {
            return CatIo::io_error;
        }
        return written == frame.size() ? CatIo::ok : CatIo::timeout;
    }

    CatIo read_frame(std::string& frame, milliseconds timeout, const std::atomic<bool>* cancel) override
    {
        const auto deadline = steady::now() + timeout;
        for (;;) {
            while (!pending_.empty()) {
                const char byte = pending_.front();
                pending_.erase(pending_.begin());
                switch (assembler_.push(byte, frame)) {
                case CatFrameAssembler::Step::complete: return CatIo::ok;
                case CatFrameAssembler::Step::invalid: return CatIo::invalid_data;
                case CatFrameAssembler::Step::need_more: break;
                }
            }
            if (cancel && cancel->load()) return CatIo::cancelled;
            const auto now = steady::now();
            if (now >= deadline) return CatIo::timeout;
            // 以 ≤100 ms 切片等待，便于检查取消。
            const auto slice = std::min<milliseconds>(
                std::chrono::duration_cast<milliseconds>(deadline - now) + milliseconds(1), milliseconds(100));
            COMMTIMEOUTS timeouts{};
            timeouts.ReadIntervalTimeout = MAXDWORD;
            timeouts.ReadTotalTimeoutMultiplier = MAXDWORD;
            timeouts.ReadTotalTimeoutConstant = clamp_ms(slice);
            timeouts.WriteTotalTimeoutConstant = clamp_ms(timeout);
            if (!SetCommTimeouts(handle_, &timeouts)) return CatIo::io_error;
            std::array<char, 64> buffer{};
            DWORD read = 0;
            if (!ReadFile(handle_, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) {
                return CatIo::io_error;
            }
            pending_.insert(pending_.end(), buffer.begin(), buffer.begin() + read);
        }
    }

    CatIo close() override
    {
        if (handle_ == INVALID_HANDLE_VALUE) return CatIo::ok;
        const BOOL closed = CloseHandle(handle_);
        handle_ = INVALID_HANDLE_VALUE;
        return closed ? CatIo::ok : CatIo::io_error;
    }

    std::string source_label() const override { return std::string(cat_source_serial); }

private:
    static DWORD clamp_ms(milliseconds value) noexcept
    {
        return static_cast<DWORD>(std::clamp<long long>(value.count(), 1, cat_max_timeout.count()));
    }

    CatConnection connection_;
    HANDLE handle_{INVALID_HANDLE_VALUE};
    std::string pending_{};
    CatFrameAssembler assembler_{};
};

} // namespace

std::unique_ptr<CatTransport> make_win32_cat_transport(const CatConnection& connection)
{
    return std::make_unique<Win32CatTransport>(connection);
}

// ---------- 同步客户端 ----------

struct CatClient::Request {
    CatOperation operation{CatOperation::query};
    const CatConnection* connection{};
    CatSide side{CatSide::main};
    CatMode mode{CatMode::fm};
    std::uint32_t frequency_hz{};
    int watts{};
    const CatCoreStateProvider* core{};
    const std::atomic<bool>* cancel{};
};

namespace {

struct CatFailure final : std::exception {
    CatFailure(CatError code_value, std::string text) : code(code_value), message(std::move(text)) {}
    const char* what() const noexcept override { return message.c_str(); }
    CatError code;
    std::string message;
};

CatError io_error_code(CatIo io) noexcept
{
    switch (io) {
    case CatIo::timeout: return CatError::timeout;
    case CatIo::cancelled: return CatError::cancelled;
    case CatIo::denied: return CatError::port_busy_or_denied;
    default: return CatError::serial_io_error;
    }
}

CatCapabilities make_capabilities(std::optional<CatPowerPath> power_path, bool power_readable, bool power_writable,
                                  bool radio_available, bool settings_writable)
{
    CatCapabilities caps;
    caps.query_available = radio_available;
    caps.set_frequency_available = settings_writable;
    caps.set_mode_available = settings_writable;
    caps.set_power_available = power_readable && power_writable && settings_writable;
    caps.power_readable = power_readable;
    caps.power_path = power_path;
    if (power_path) caps.power_maximum_watts = cat_power_path_max_watts(*power_path);
    return caps;
}

class Session final {
public:
    Session(CatTransport& transport, steady::time_point deadline, const std::atomic<bool>* cancel, std::string source)
        : transport_(transport), deadline_(deadline), cancel_(cancel), source_(std::move(source)) {}

    [[nodiscard]] milliseconds remaining() const
    {
        const auto left = std::chrono::duration_cast<milliseconds>(deadline_ - steady::now());
        return left.count() > 0 ? left : milliseconds(0);
    }

    void check_cancel() const
    {
        if (cancel_ && cancel_->load()) throw CatFailure(CatError::cancelled, "CAT 操作已取消；没有发送后续命令。");
    }

    void write(std::string_view frame, std::string_view context)
    {
        check_cancel();
        const auto left = remaining();
        if (left.count() <= 0) {
            throw CatFailure(CatError::timeout, "CAT session deadline elapsed before " + std::string(context) + ".");
        }
        const auto io = transport_.write_frame(frame, left);
        if (io != CatIo::ok) throw CatFailure(io_error_code(io), "CAT-1 串口写入失败；本次没有报告设置已生效。");
    }

    CatFrame read_value(std::string_view command, CatCommand expected, std::optional<CatSide> expected_side = {})
    {
        write(command, "write");
        for (;;) {
            check_cancel();
            const auto left = remaining();
            const std::string no_match = "CAT 命令 " + std::string(command) + " 在 session deadline 内没有收到匹配响应。";
            if (left.count() <= 0) throw CatFailure(CatError::timeout, no_match);
            std::string frame;
            const auto io = transport_.read_frame(frame, left, cancel_);
            if (io == CatIo::timeout) throw CatFailure(CatError::timeout, no_match);
            if (io == CatIo::cancelled) throw CatFailure(CatError::cancelled, "CAT 操作已取消。");
            if (io != CatIo::ok) throw CatFailure(io_error_code(io), "CAT-1 串口读写失败；本次没有报告设置已生效。");
            if (frame == "?;") {
                throw CatFailure(CatError::radio_rejected_command,
                                 "FTX-1 CAT 在请求 " + std::string(command) + " 时返回错误帧 ?;。");
            }
            std::string_view frame_command;
            if (!cat_frame_command(frame, frame_command)) {
                throw CatFailure(CatError::invalid_frame, "FTX-1 CAT 返回语法无效的完整帧：" + frame);
            }
            const auto expected_text = cat_read_command(expected).substr(0U, 2U);
            if (frame_command != expected_text) continue;  // 异步 AI 帧等，跳过
            if (expected == CatCommand::md && expected_side && frame.size() >= 3U &&
                (frame[2] == '0' || frame[2] == '1') &&
                (frame[2] == '0' ? CatSide::main : CatSide::sub) != *expected_side) {
                continue;  // 另一侧的完整 MD 帧
            }
            auto parsed = cat_parse_frame(frame, expected);
            if (parsed.status != CatFrameStatus::ok) {
                throw CatFailure(parsed.error, "FTX-1 CAT 响应无效：" + frame);
            }
            if (expected_side && parsed.mode.side != *expected_side) {
                throw CatFailure(CatError::side_mismatch, "CAT 响应侧别与请求不符：" + frame);
            }
            return parsed;
        }
    }

    template <class T>
    CatObservation<T> observe(T value) const
    {
        return CatObservation<T>{std::move(value), std::chrono::system_clock::now(), source_};
    }

private:
    CatTransport& transport_;
    steady::time_point deadline_;
    const std::atomic<bool>* cancel_;
    std::string source_;
};

void enforce_gate(CatOperation operation, const CatCoreStateProvider* core)
{
    if (operation == CatOperation::query) return;
    if (!core || !*core) throw CatFailure(CatError::invalid_request, "设置操作需要核心状态输入。");
    // 先取核心状态再取 now：参数求值顺序不定，否则 idle_status_at 可能晚于 now 而被误判。
    const CatCoreState state = (*core)();
    const auto now = steady::now();
    const auto decision = cat_gate_for(operation, state, now);
    if (decision == CatGateDecision::core_not_stopped) {
        throw CatFailure(CatError::core_not_stopped, "设置 MAIN 频率或模式前必须先停止桥接核心；没有发送设置。");
    }
    if (decision == CatGateDecision::core_not_idle) {
        throw CatFailure(CatError::core_not_idle, "核心状态未确认电台空闲；设置操作已取消。");
    }
}

} // namespace

CatClient::CatClient() : factory_(make_win32_cat_transport) {}

CatClient::CatClient(CatTransportFactory factory) : factory_(std::move(factory)) {}

CatResult CatClient::query_all(const CatConnection& connection, const std::atomic<bool>* cancel) const
{
    Request request;
    request.operation = CatOperation::query;
    request.connection = &connection;
    request.cancel = cancel;
    return run(request);
}

CatResult CatClient::set_main_frequency(const CatConnection& connection, std::uint32_t frequency_hz,
                                        const CatCoreStateProvider& core, const std::atomic<bool>* cancel) const
{
    Request request;
    request.operation = CatOperation::set_frequency;
    request.connection = &connection;
    request.frequency_hz = frequency_hz;
    request.core = &core;
    request.cancel = cancel;
    return run(request);
}

CatResult CatClient::set_mode(const CatConnection& connection, CatSide side, CatMode mode,
                              const CatCoreStateProvider& core, const std::atomic<bool>* cancel) const
{
    Request request;
    request.operation = CatOperation::set_mode;
    request.connection = &connection;
    request.side = side;
    request.mode = mode;
    request.core = &core;
    request.cancel = cancel;
    return run(request);
}

CatResult CatClient::set_power(const CatConnection& connection, int watts, const CatCoreStateProvider& core,
                               const std::atomic<bool>* cancel) const
{
    Request request;
    request.operation = CatOperation::set_power;
    request.connection = &connection;
    request.watts = watts;
    request.core = &core;
    request.cancel = cancel;
    return run(request);
}

CatResult CatClient::run(const Request& request) const
{
    const CatConnection& connection = *request.connection;
    CatResult result;
    result.operation = request.operation;
    result.port_name = connection.port_name;
    result.started_at = std::chrono::system_clock::now();

    std::unique_ptr<CatTransport> transport;
    bool is_open = false;
    bool open_completed = false;
    std::optional<std::string> close_error;
    std::string source;

    const auto close_transport = [&]() {
        if (!transport || !is_open) return;
        is_open = false;
        if (transport->close() != CatIo::ok) close_error = "CAT-1 串口关闭失败。";
    };

    try {
        // ---- 打开前校验（对应 PS 参数校验与 UI 门控） ----
        const auto port = cat_normalize_port_name(connection.port_name);
        if (port.empty()) throw CatFailure(CatError::invalid_request, "CAT-1 端口名不能为空。");
        if (!connection.hri_port_name.empty() && port == cat_normalize_port_name(connection.hri_port_name)) {
            throw CatFailure(CatError::hri_port_conflict,
                             "CAT-1 端口与当前 HRI 端口相同；为避免两个协议共用串口，本次未打开端口。");
        }
        if (!cat_is_valid_port_name(port)) throw CatFailure(CatError::invalid_request, "CAT 串口必须是 COM1 到 COM999。");
        if (!cat_is_supported_baud_rate(connection.baud_rate)) {
            throw CatFailure(CatError::invalid_request, "波特率不在 FTX-1 CAT 手册列出的选项内。");
        }
        if (connection.timeout < cat_min_timeout || connection.timeout > cat_max_timeout) {
            throw CatFailure(CatError::invalid_request, "CAT 会话期限必须为 100–3000 ms。");
        }
        if (request.operation == CatOperation::set_power &&
            (request.watts < cat_app_min_power_watts || request.watts > cat_app_max_power_watts)) {
            throw CatFailure(CatError::power_out_of_range, "本应用接受5–50 W的期望值；不会自动钳位。");
        }
        if (request.operation == CatOperation::set_frequency &&
            (request.frequency_hz < cat_min_frequency_hz || request.frequency_hz > cat_max_frequency_hz)) {
            throw CatFailure(CatError::frequency_out_of_range,
                             "MAIN FA 频率范围为 30,000–470,000,000 Hz；不会自动钳位。");
        }
        if (request.operation == CatOperation::set_mode && !cat_is_voice_mode(request.mode)) {
            throw CatFailure(CatError::invalid_request, "只允许 FM / FM-N / C4FM-DN / C4FM-VW。");
        }
        enforce_gate(request.operation, request.core);
        if (request.cancel && request.cancel->load()) throw CatFailure(CatError::cancelled, "CAT 操作已取消。");

        // ---- 打开短会话 ----
        if (!factory_) throw CatFailure(CatError::invalid_request, "CAT 传输未配置。");
        transport = factory_(connection);
        if (!transport) throw CatFailure(CatError::serial_io_error, "CAT 传输创建失败。");
        source = transport->source_label();
        const auto deadline = steady::now() + connection.timeout;
        const auto opened = transport->open();
        if (opened != CatIo::ok) {
            // 打开失败时句柄可能已部分创建；close 是幂等的。
            transport->close();
            if (opened == CatIo::denied) {
                throw CatFailure(CatError::port_busy_or_denied, "无法打开 CAT-1 端口；端口可能被其他程序占用或访问被拒绝。");
            }
            throw CatFailure(io_error_code(opened), "CAT-1 串口打开失败。");
        }
        is_open = true;
        open_completed = true;
        Session session(*transport, deadline, request.cancel, source);
        if (session.remaining().count() <= 0) {
            throw CatFailure(CatError::timeout, "CAT session deadline elapsed while opening the port.");
        }
        if (transport->clear_input() != CatIo::ok) throw CatFailure(CatError::serial_io_error, "CAT-1 串口清空输入失败。");

        // ---- 身份 / AI / TX ----
        const auto id = session.read_value("ID;", CatCommand::id);
        if (id.radio_id != cat_expected_radio_id) {
            throw CatFailure(CatError::identity_mismatch,
                             "CAT identification mismatch: expected FTX-1 ID 0840, received " + id.radio_id + ".");
        }
        result.observed.radio_id = session.observe(id.radio_id);
        result.capabilities = make_capabilities(std::nullopt, false, false, true, false);

        const auto ai = session.read_value("AI;", CatCommand::ai);
        result.observed.auto_information = session.observe(ai.auto_information);

        const auto tx = session.read_value("TX;", CatCommand::tx);
        result.observed.tx_state = session.observe(tx.tx_state);
        result.capabilities = make_capabilities(std::nullopt, false, false, true, tx.tx_state == 0);
        if (request.operation != CatOperation::query && tx.tx_state != 0) {
            throw CatFailure(CatError::busy, "Radio is not idle (TX state " + std::to_string(tx.tx_state) +
                                                 "); the requested CAT setting was not written.");
        }

        // 写帧前：重新读 TX 并重新评估核心门控。
        const auto write_gate = [&](std::string_view frame, std::string_view what,
                                    std::optional<CatPowerPath> power_path) {
            const auto again = session.read_value("TX;", CatCommand::tx);
            result.observed.tx_state = session.observe(again.tx_state);
            result.capabilities = make_capabilities(power_path, power_path.has_value(), power_path.has_value(), true,
                                                    again.tx_state == 0);
            if (again.tx_state != 0) {
                throw CatFailure(CatError::busy, "Radio became active before the " + std::string(what) + " write (TX state " +
                                                     std::to_string(again.tx_state) + "); the setting was not written.");
            }
            enforce_gate(request.operation, request.core);
            session.write(frame, std::string(what) + " write");
        };

        switch (request.operation) {
        case CatOperation::query: {
            result.observed.main_frequency_hz = session.observe(session.read_value("FA;", CatCommand::fa).frequency_hz);
            result.observed.sub_frequency_hz = session.observe(session.read_value("FB;", CatCommand::fb).frequency_hz);
            result.observed.main_mode = session.observe(session.read_value("MD0;", CatCommand::md, CatSide::main).mode);
            result.observed.sub_mode = session.observe(session.read_value("MD1;", CatCommand::md, CatSide::sub).mode);
            const auto power = session.read_value("PC;", CatCommand::pc).power;
            result.observed.power = session.observe(power);
            result.capabilities = make_capabilities(power.path, true, true, true, tx.tx_state == 0);
            result.updated_at = result.observed.power->updated_at;
            break;
        }
        case CatOperation::set_power: {
            const auto main_mode = session.read_value("MD0;", CatCommand::md, CatSide::main).mode;
            result.observed.main_mode = session.observe(main_mode);
            if (!cat_is_voice_mode(main_mode.mode)) {
                throw CatFailure(CatError::power_mode_not_supported,
                                 "Power change requires MAIN in FM/C4FM voice mode; observed " +
                                     std::string(to_string(main_mode.mode)) + ".");
            }
            const auto old_power = session.read_value("PC;", CatCommand::pc).power;
            result.observed.power = session.observe(old_power);
            result.capabilities = make_capabilities(old_power.path, true, true, true, true);
            result.prior_mode = main_mode;
            result.prior_power = old_power;
            const int maximum = cat_power_path_max_watts(old_power.path);
            if (request.watts < cat_app_min_power_watts || request.watts > maximum) {
                throw CatFailure(CatError::power_out_of_range,
                                 "当前功率路径的应用范围为 5-" + std::to_string(maximum) + " W；不会自动钳位。");
            }
            if (old_power.watts != request.watts) {
                const auto frame = cat_power_command(old_power.path, request.watts);
                if (!frame) throw CatFailure(CatError::power_out_of_range, "功率命令无法构造。");
                write_gate(*frame, "power", old_power.path);
            }
            const auto power = session.read_value("PC;", CatCommand::pc).power;
            result.observed.power = session.observe(power);
            if (power.path != old_power.path || power.watts != request.watts) {
                throw CatFailure(CatError::readback_mismatch, "Power readback was " + std::to_string(power.watts) +
                                                                  " W, not " + std::to_string(request.watts) + " W.");
            }
            result.updated_at = result.observed.power->updated_at;
            break;
        }
        case CatOperation::set_frequency: {
            const auto old_frequency = session.read_value("FA;", CatCommand::fa).frequency_hz;
            result.observed.main_frequency_hz = session.observe(old_frequency);
            result.prior_frequency_hz = old_frequency;
            result.capabilities = make_capabilities(std::nullopt, false, false, true, true);
            if (old_frequency != request.frequency_hz) {
                const auto frame = cat_frequency_command(request.frequency_hz);
                if (!frame) throw CatFailure(CatError::frequency_out_of_range, "频率命令无法构造。");
                write_gate(*frame, "MAIN frequency", std::nullopt);
            }
            const auto verified = session.read_value("FA;", CatCommand::fa).frequency_hz;
            result.observed.main_frequency_hz = session.observe(verified);
            if (verified != request.frequency_hz) {
                throw CatFailure(CatError::readback_mismatch, "MAIN frequency readback was " + std::to_string(verified) +
                                                                  " Hz, not " + std::to_string(request.frequency_hz) +
                                                                  " Hz.");
            }
            result.updated_at = result.observed.main_frequency_hz->updated_at;
            break;
        }
        case CatOperation::set_mode: {
            const auto read_command = cat_mode_read_command(request.side);
            auto& slot = request.side == CatSide::main ? result.observed.main_mode : result.observed.sub_mode;
            const auto old_mode = session.read_value(read_command, CatCommand::md, request.side).mode;
            slot = session.observe(old_mode);
            result.prior_mode = old_mode;
            result.capabilities = make_capabilities(std::nullopt, false, false, true, true);
            if (old_mode.mode != request.mode) {
                const auto frame = cat_mode_command(request.side, request.mode);
                if (!frame) throw CatFailure(CatError::invalid_request, "模式命令无法构造。");
                write_gate(*frame, "mode", std::nullopt);
            }
            const auto verified = session.read_value(read_command, CatCommand::md, request.side).mode;
            slot = session.observe(verified);
            if (verified.mode != request.mode) {
                throw CatFailure(CatError::readback_mismatch, "Mode readback was " + std::string(to_string(verified.mode)) +
                                                                  ", not " + std::string(to_string(request.mode)) + ".");
            }
            result.updated_at = slot->updated_at;
            break;
        }
        }

        // ---- 成功路径收尾 ----
        close_transport();
        result.cleanup = close_error ? CatCleanup::close_failed : CatCleanup::closed;
        result.status = CatResultStatus::confirmed;
        if (steady::now() > deadline) {
            result.status = CatResultStatus::unknown;
            result.error = CatError::timeout;
            result.error_message =
                "CAT session exceeded its bounded deadline; readback values are retained as observations, but this "
                "operation is not marked confirmed.";
        }
        if (close_error) {
            result.status = CatResultStatus::unknown;
            if (result.error == CatError::none) result.error = CatError::serial_close_failed;
            result.error_message = result.error_message.empty()
                ? "CAT 读回值与目标相符，但串口关闭失败；本次操作整体状态为 unknown。"
                : result.error_message + " 串口关闭失败。";
        }
        if (result.status == CatResultStatus::unknown) {
            const auto power_path = result.observed.power ? std::optional<CatPowerPath>(result.observed.power->value.path)
                                                          : std::nullopt;
            result.capabilities = make_capabilities(power_path, result.observed.power.has_value(), false, false, false);
        }
        result.source = result.updated_at ? source : std::string();
        return result;
    } catch (const CatFailure& failure) {
        result.error = failure.code;
        result.error_message = failure.message;
    } catch (const std::bad_alloc&) {
        result.error = CatError::serial_io_error;
        result.error_message = "内存不足；CAT 操作未完成。";
    } catch (const std::exception&) {
        result.error = CatError::serial_io_error;
        result.error_message = "CAT 操作内部错误；本次没有报告设置已生效。";
    }

    // ---- 失败路径收尾：关闭端口、撤销全部写授权 ----
    close_transport();
    result.status = cat_status_for_error(result.error);
    result.cleanup = close_error ? CatCleanup::close_failed
                                 : (open_completed && !is_open ? CatCleanup::closed : CatCleanup::not_opened);
    if (close_error) result.error_message += " Serial close failed.";
    const auto power_path = result.observed.power ? std::optional<CatPowerPath>(result.observed.power->value.path)
                                                  : std::nullopt;
    result.capabilities = make_capabilities(power_path, result.observed.power.has_value(), false, false, false);
    result.updated_at.reset();
    result.source.clear();
    return result;
}

// ---------- R130：静噪快速采样 ----------

std::optional<unsigned> cat_parse_s_meter(std::string_view frame) noexcept
{
    // SM P1 P2P2P2 ;  P1 = 0（MAIN）；P2 = 000..255
    if (frame.size() != 7U || frame[0] != 'S' || frame[1] != 'M' || frame[2] != '0' || frame[6] != ';') {
        return std::nullopt;
    }
    unsigned value = 0U;
    for (std::size_t i = 3U; i < 6U; ++i) {
        if (frame[i] < '0' || frame[i] > '9') return std::nullopt;
        value = value * 10U + static_cast<unsigned>(frame[i] - '0');
    }
    if (value > 255U) return std::nullopt;
    return value;
}

CatSquelchSample CatClient::query_squelch(const CatConnection& connection, const std::atomic<bool>* cancel) const
{
    CatSquelchSample sample;
    std::unique_ptr<CatTransport> transport;
    bool is_open = false;
    const auto fail = [&](CatError error, std::string message) {
        sample.error = error;
        sample.error_message = std::move(message);
        sample.ri_frame.clear();
    };
    try {
        const auto port = cat_normalize_port_name(connection.port_name);
        if (port.empty() || !cat_is_valid_port_name(port)) {
            fail(CatError::invalid_request, "CAT 串口必须是 COM1 到 COM999。");
            return sample;
        }
        if (!connection.hri_port_name.empty() && port == cat_normalize_port_name(connection.hri_port_name)) {
            fail(CatError::hri_port_conflict, "CAT-1 端口与当前 HRI 端口相同；本次未打开端口。");
            return sample;
        }
        if (!cat_is_supported_baud_rate(connection.baud_rate) || connection.timeout < cat_min_timeout ||
            connection.timeout > cat_max_timeout) {
            fail(CatError::invalid_request, "CAT 连接参数无效。");
            return sample;
        }
        if (cancel && cancel->load()) {
            fail(CatError::cancelled, "CAT 操作已取消。");
            return sample;
        }
        if (!factory_) {
            fail(CatError::invalid_request, "CAT 传输未配置。");
            return sample;
        }
        transport = factory_(connection);
        if (!transport) {
            fail(CatError::serial_io_error, "CAT 传输创建失败。");
            return sample;
        }
        const auto deadline = steady::now() + connection.timeout;
        const auto opened = transport->open();
        if (opened != CatIo::ok) {
            (void)transport->close();
            fail(opened == CatIo::denied ? CatError::port_busy_or_denied : io_error_code(opened), "CAT-1 串口打开失败。");
            return sample;
        }
        is_open = true;
        if (transport->clear_input() != CatIo::ok) throw CatFailure(CatError::serial_io_error, "CAT-1 串口清空输入失败。");
        Session session(*transport, deadline, cancel, transport->source_label());

        // RI0：必须成功。只接受 radio_info::parse 通过的 11 字节应答；其它完整帧（异步 AI 等）跳过。
        session.write(radio_info::query_command, "RI0 write");
        for (;;) {
            session.check_cancel();
            const auto left = session.remaining();
            if (left.count() <= 0) throw CatFailure(CatError::timeout, "CAT 命令 RI0; 在期限内没有应答。");
            std::string frame;
            const auto io = transport->read_frame(frame, left, cancel);
            if (io == CatIo::timeout) throw CatFailure(CatError::timeout, "CAT 命令 RI0; 在期限内没有应答。");
            if (io != CatIo::ok) throw CatFailure(io_error_code(io), "CAT-1 串口读写失败。");
            if (frame == "?;") throw CatFailure(CatError::radio_rejected_command, "FTX-1 CAT 拒绝 RI0;。");
            if (frame.size() < 2U || frame[0] != 'R' || frame[1] != 'I') continue;
            if (!radio_info::parse(frame)) throw CatFailure(CatError::unexpected_response, "RI0; 应答无效：" + frame);
            sample.ri_frame = frame;
            break;
        }

        // SM0：尽力读取；任何失败都只让 s_meter 为空。
        try {
            session.write("SM0;", "SM0 write");
            for (;;) {
                const auto left = session.remaining();
                if (left.count() <= 0) break;
                std::string frame;
                if (transport->read_frame(frame, left, cancel) != CatIo::ok) break;
                if (frame == "?;") break;
                if (frame.size() >= 2U && frame[0] == 'S' && frame[1] == 'M') {
                    sample.s_meter = cat_parse_s_meter(frame);
                    break;
                }
            }
        } catch (const CatFailure&) {
            sample.s_meter.reset();
        }
    } catch (const CatFailure& failure) {
        fail(failure.code, failure.message);
    } catch (const std::exception&) {
        fail(CatError::serial_io_error, "CAT 静噪采样内部错误。");
    }
    if (transport && is_open) {
        if (transport->close() != CatIo::ok) {
            sample.cleanup = CatCleanup::close_failed;
            if (sample.error == CatError::none) fail(CatError::serial_close_failed, "CAT-1 串口关闭失败。");
        } else {
            sample.cleanup = CatCleanup::closed;
        }
    }
    return sample;
}

// ---------- 写授权 ----------

bool cat_query_grants_write_permit(const CatResult& r) noexcept
{
    return r.operation == CatOperation::query && r.status == CatResultStatus::confirmed &&
           r.cleanup == CatCleanup::closed && r.observed.radio_id && r.observed.radio_id->value == cat_expected_radio_id &&
           r.observed.tx_state && r.observed.tx_state->value == 0 && r.observed.main_frequency_hz &&
           r.observed.main_mode && r.observed.power && r.capabilities.set_power_available;
}

bool cat_write_permit_fresh(steady::time_point permit_at, steady::time_point now) noexcept
{
    return now >= permit_at && now - permit_at <= cat_write_permit_max_age;
}

// ---------- Worker ----------

CatWorker::CatWorker(CatClient client, CatCoreStateProvider core_state)
    : client_(std::move(client)), core_state_(std::move(core_state))
{
    thread_ = std::thread([this]() { loop(); });
}

CatWorker::~CatWorker()
{
    std::deque<Pending> dropped;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        cancel_.store(true);
        dropped.swap(queue_);
    }
    wake_.notify_all();
    if (thread_.joinable()) thread_.join();
    for (auto& pending : dropped) pending.promise.set_value(cancelled_result(pending.job));
}

std::future<CatResult> CatWorker::submit(CatJob job, Callback callback)
{
    Pending pending;
    pending.job = std::move(job);
    pending.callback = std::move(callback);
    auto future = pending.promise.get_future();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) {
            pending.promise.set_value(cancelled_result(pending.job));
            return future;
        }
        pending.generation = state_.generation;
        queue_.push_back(std::move(pending));
    }
    wake_.notify_one();
    return future;
}

void CatWorker::cancel_current() noexcept { cancel_.store(true); }

void CatWorker::disconnect()
{
    std::deque<Pending> dropped;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ++state_.generation;
        cancel_.store(true);
        dropped.swap(queue_);
        state_.write_authorized = false;
        state_.write_permit_at.reset();
        state_.capabilities.reset();
        state_.last_result.reset();
        // observed / observed_connection_key 保留，用于断开后的只读显示。
    }
    for (auto& pending : dropped) {
        const auto result = cancelled_result(pending.job);
        if (pending.callback) {
            try { pending.callback(result); } catch (...) { /* 回调异常不影响取消 */ }
        }
        pending.promise.set_value(result);
    }
}

CatWorkerSnapshot CatWorker::snapshot() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    auto copy = state_;
    if (copy.write_permit_at && !cat_write_permit_fresh(*copy.write_permit_at, steady::now())) {
        copy.write_authorized = false;
    }
    return copy;
}

CatResult CatWorker::cancelled_result(const CatJob& job)
{
    CatResult result;
    result.operation = job.operation;
    result.port_name = job.connection.port_name;
    result.started_at = std::chrono::system_clock::now();
    result.status = CatResultStatus::unknown;
    result.error = CatError::cancelled;
    result.error_message = "CAT 会话已断开或取消；没有执行该操作。";
    return result;
}

void CatWorker::loop()
{
    for (;;) {
        Pending pending;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this]() { return stopping_ || !queue_.empty(); });
            if (stopping_) return;
            pending = std::move(queue_.front());
            queue_.pop_front();
            if (pending.generation != state_.generation) {
                lock.unlock();
                const auto result = cancelled_result(pending.job);
                if (pending.callback) {
                    try { pending.callback(result); } catch (...) {}
                }
                pending.promise.set_value(result);
                continue;
            }
            cancel_.store(false);
            state_.busy = true;
        }

        CatResult result;
        try {
            result = execute(pending.job, pending.generation);
        } catch (const std::exception&) {
            result = cancelled_result(pending.job);
            result.error = CatError::serial_io_error;
            result.error_message = "CAT worker 内部错误。";
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            state_.busy = false;
        }
        if (pending.callback) {
            try { pending.callback(result); } catch (...) { /* 回调异常不影响 future */ }
        }
        pending.promise.set_value(std::move(result));
    }
}

CatResult CatWorker::execute(const CatJob& job, std::uint64_t generation)
{
    const auto key = cat_connection_key(job.connection);
    if (job.operation != CatOperation::query) {
        bool permitted = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            permitted = state_.write_authorized && state_.write_permit_at && state_.observed_connection_key == key &&
                        cat_write_permit_fresh(*state_.write_permit_at, steady::now());
        }
        if (!permitted) {
            // 冻结目标后先读取一次；通过身份、TX0、端口与时效检查才写入。
            const auto query = client_.query_all(job.connection, &cancel_);
            CatJob query_job = job;
            query_job.operation = CatOperation::query;
            absorb(query, query_job, generation);
            bool granted = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                granted = state_.write_authorized && state_.generation == generation;
            }
            if (!granted) {
                CatResult rejected = query;
                rejected.operation = job.operation;
                if (rejected.error == CatError::none || rejected.status == CatResultStatus::confirmed) {
                    rejected.error = CatError::write_not_authorized;
                    rejected.error_message = "CAT 身份、TX=0、端口或读取时间未通过检查；没有发送设置。";
                }
                rejected.status = cat_status_for_error(rejected.error);
                rejected.capabilities = make_capabilities(std::nullopt, false, false, false, false);
                rejected.updated_at.reset();
                rejected.source.clear();
                return rejected;
            }
        }
    }

    CatResult result;
    switch (job.operation) {
    case CatOperation::query: result = client_.query_all(job.connection, &cancel_); break;
    case CatOperation::set_frequency:
        result = client_.set_main_frequency(job.connection, job.frequency_hz, core_state_, &cancel_);
        break;
    case CatOperation::set_mode: result = client_.set_mode(job.connection, job.side, job.mode, core_state_, &cancel_); break;
    case CatOperation::set_power: result = client_.set_power(job.connection, job.power_watts, core_state_, &cancel_); break;
    }
    absorb(result, job, generation);
    return result;
}

void CatWorker::absorb(const CatResult& result, const CatJob& job, std::uint64_t generation)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != state_.generation) return;  // 会话已变化：丢弃旧结果
    const auto key = cat_connection_key(job.connection);
    const auto adopt_observed = [&]() {
        if (state_.observed_connection_key != key) {
            state_.observed = {};
            state_.observed_connection_key = key;
        }
        cat_merge_observed(state_.observed, result.observed);
    };

    state_.last_result = result;
    if (result.status == CatResultStatus::confirmed) {
        adopt_observed();
        if (job.operation == CatOperation::query) {
            state_.write_authorized = cat_query_grants_write_permit(result);
            state_.write_permit_at = steady::now();
            state_.capabilities = result.capabilities;
        }
        // 已确认的写入不延长授权时效；授权仍以最近一次 query 的时间为准。
        return;
    }

    state_.write_authorized = false;
    state_.write_permit_at.reset();
    state_.capabilities.reset();
    if (result.status == CatResultStatus::identity_mismatch) {
        state_.observed = {};
        state_.observed_connection_key.clear();
    } else if (job.operation == CatOperation::set_power &&
               (result.status == CatResultStatus::rejected || result.status == CatResultStatus::mismatch) &&
               result.cleanup == CatCleanup::closed) {
        adopt_observed();  // 被拒绝的功率读回仍是可信观测
    }
}

} // namespace wirex::app
