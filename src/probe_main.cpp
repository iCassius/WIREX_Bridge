#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#ifdef WIREX_ENABLE_BM_BRIDGE
#include <winsock2.h>
#include <ws2tcpip.h>
#endif
#include <windows.h>
#include <mmsystem.h>
#include <mmddk.h>
#include <bcrypt.h>

#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"
#include "wirex/hri_downlink_session.hpp"
#include "wirex/hri_radio_protocol.hpp"
#include "wirex/hri_session.hpp"
#include "wirex/hri_t_payload.hpp"
#include "wirex/operation_audio_cleanup.hpp"
#include "wirex/console_lifecycle.hpp"
#include "wirex/audio_input_cleanup.hpp"
#include "wirex/bounded_pipe_writer.hpp"
#include "wirex/pcm_gain.hpp"
#include "wirex/session_report.hpp"
#include "wirex/session_timing.hpp"
#include "wirex/wave_output_open.hpp"
#include "wirex/wave_file.hpp"
#ifdef WIREX_ENABLE_BM_BRIDGE
#include "wirex/bm_session.hpp"
#include "wirex/bm_connection_config.hpp"
#include "wirex/bm_network_metadata.hpp"
#include "wirex/bm_test_profile.hpp"
#include "wirex/bm_udp.hpp"
#include "wirex/bm_voice_pipeline.hpp"
#include "wirex/dmrd.hpp"
#include "wirex/hri_stream_session.hpp"
#include "wirex/hri_ptt_gate.hpp"
#include "wirex/ui_control_protocol.hpp"
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <deque>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <memory>
#include <new>
#include <sstream>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace {

wirex::ConsoleLifecycle& console_lifecycle() noexcept
{
    return wirex::ConsoleLifecycle::process();
}

class WinHandle {
public:
    explicit WinHandle(HANDLE value = INVALID_HANDLE_VALUE) noexcept : value_(value) {}
    ~WinHandle() { reset(); }
    WinHandle(const WinHandle&) = delete;
    WinHandle& operator=(const WinHandle&) = delete;
    WinHandle(WinHandle&& other) noexcept : value_(other.release()) {}
    WinHandle& operator=(WinHandle&& other) noexcept
    {
        if (this != &other) reset(other.release());
        return *this;
    }
    [[nodiscard]] HANDLE get() const noexcept { return value_; }
    [[nodiscard]] bool valid() const noexcept { return value_ != nullptr && value_ != INVALID_HANDLE_VALUE; }
    [[nodiscard]] HANDLE release() noexcept
    {
        const HANDLE old = value_;
        value_ = INVALID_HANDLE_VALUE;
        return old;
    }
    void reset(HANDLE value = INVALID_HANDLE_VALUE) noexcept
    {
        if (valid()) CloseHandle(value_);
        value_ = value;
    }
private:
    HANDLE value_;
};

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

void secure_wipe(void* data, std::size_t size) noexcept
{
    if (data != nullptr && size != 0) SecureZeroMemory(data, size);
}

std::wstring mm_error(MMRESULT code)
{
    std::array<wchar_t, 256> message{};
    if (waveInGetErrorTextW(code, message.data(), static_cast<UINT>(message.size())) == MMSYSERR_NOERROR) {
        return message.data();
    }
    return L"MMRESULT " + std::to_wstring(code);
}

std::optional<std::wstring> wave_endpoint_id(bool input, UINT device_id)
{
    const auto wave_id = static_cast<UINT_PTR>(device_id);
    DWORD size_bytes = 0U;
    const auto size_result = input
        ? waveInMessage(reinterpret_cast<HWAVEIN>(wave_id), DRV_QUERYFUNCTIONINSTANCEIDSIZE,
            reinterpret_cast<DWORD_PTR>(&size_bytes), 0U)
        : waveOutMessage(reinterpret_cast<HWAVEOUT>(wave_id), DRV_QUERYFUNCTIONINSTANCEIDSIZE,
            reinterpret_cast<DWORD_PTR>(&size_bytes), 0U);
    if (size_result != MMSYSERR_NOERROR || size_bytes < sizeof(wchar_t) ||
        size_bytes > 65536U || size_bytes % sizeof(wchar_t) != 0U) {
        return std::nullopt;
    }

    std::vector<wchar_t> buffer(static_cast<std::size_t>(size_bytes) / sizeof(wchar_t), L'\0');
    const auto id_result = input
        ? waveInMessage(reinterpret_cast<HWAVEIN>(wave_id), DRV_QUERYFUNCTIONINSTANCEID,
            reinterpret_cast<DWORD_PTR>(buffer.data()), size_bytes)
        : waveOutMessage(reinterpret_cast<HWAVEOUT>(wave_id), DRV_QUERYFUNCTIONINSTANCEID,
            reinterpret_cast<DWORD_PTR>(buffer.data()), size_bytes);
    if (id_result != MMSYSERR_NOERROR) return std::nullopt;
    const auto terminator = std::find(buffer.begin(), buffer.end(), L'\0');
    if (terminator == buffer.begin() || terminator == buffer.end()) return std::nullopt;
    return std::wstring(buffer.begin(), terminator);
}

bool wave_endpoint_matches(bool input, UINT device_id, std::wstring_view expected_endpoint_id)
{
    if (expected_endpoint_id.empty()) return false;
    const auto current = wave_endpoint_id(input, device_id);
    return current && *current == expected_endpoint_id;
}

std::wstring device_name(const wchar_t* name, std::size_t capacity)
{
    std::size_t length = 0;
    while (length < capacity && name[length] != L'\0') ++length;
    if (length == 0) return L"<empty name>";
    return std::wstring(name, length);
}

std::string to_utf8(std::wstring_view text)
{
    if (text.empty()) return {};
    const int required = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0) return "<name encoding failed>";
    std::string result(static_cast<std::size_t>(required), '\0');
    const int written = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), required, nullptr, nullptr);
    if (written != required) return "<name encoding failed>";
    return result;
}

std::string json_escape(std::string_view value)
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

bool parse_uint(std::wstring_view text, unsigned long& value)
{
    if (text.empty()) return false;
    unsigned long parsed = 0;
    for (const wchar_t ch : text) {
        if (ch < L'0' || ch > L'9') return false;
        const auto digit = static_cast<unsigned long>(ch - L'0');
        if (parsed > (0xffffffffUL - digit) / 10UL) return false;
        parsed = parsed * 10UL + digit;
    }
    value = parsed;
    return true;
}

bool parse_port(std::wstring_view port, std::wstring& device_path)
{
    if (port.size() < 4 || (port[0] != L'C' && port[0] != L'c') ||
        (port[1] != L'O' && port[1] != L'o') || (port[2] != L'M' && port[2] != L'm')) return false;
    unsigned long number = 0;
    if (!parse_uint(port.substr(3), number) || number == 0 || number > 999) return false;
    device_path = L"\\\\.\\" + std::wstring(port);
    return true;
}

WAVEFORMATEX pcm_format() noexcept
{
    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = 48000;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 2;
    format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
    return format;
}

bool configure_serial(HANDLE port, bool purge_queues = true)
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
    if (purge_queues && !PurgeComm(port, PURGE_RXCLEAR | PURGE_TXCLEAR)) {
        std::wcerr << L"PurgeComm failed: " << win_error(GetLastError()) << L"\n";
        return false;
    }
    return true;
}

std::string printable_field(const std::vector<std::uint8_t>& payload, std::size_t offset, std::size_t length)
{
    if (offset > payload.size() || length > payload.size() - offset) return {};
    std::string value;
    value.reserve(length);
    for (std::size_t i = offset; i < offset + length; ++i) {
        const auto byte = payload[i];
        if (byte == 0) break;
        if (byte < 0x20 || byte > 0x7e) return {};
        value.push_back(static_cast<char>(byte));
    }
    while (!value.empty() && value.back() == ' ') value.pop_back();
    while (!value.empty() && value.front() == ' ') value.erase(value.begin());
    return value;
}

bool is_safe_version_field(const std::string& value)
{
    if (value.size() != 6 || value[0] != 'V' || value[3] != '-') return false;
    return value[1] >= '0' && value[1] <= '9' && value[2] >= '0' && value[2] <= '9' &&
        value[4] >= '0' && value[4] <= '9' && value[5] >= '0' && value[5] <= '9';
}

int query_version(const std::wstring& port_name)
{
    std::wstring path;
    if (!parse_port(port_name, path)) {
        std::wcerr << L"Invalid port. Use a COM name such as COM5.\n";
        return 2;
    }
    WinHandle port(CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!port.valid()) {
        std::wcerr << L"Cannot open " << port_name << L": " << win_error(GetLastError()) << L"\n";
        return 2;
    }
    if (!configure_serial(port.get())) return 2;
    std::cout << "Port config: 115200 8N1, Handshake=None, DTR=false, RTS=false; one query, 2500 ms response window.\n";

    const auto query = wirex::direct_frame::encode({0x56, {}});
    if (!query || query.bytes != std::vector<std::uint8_t>({0x01, 0x56, 0x30, 0x30, 0x30, 0x30, 0x04, 0x31, 0x42})) {
        std::wcerr << L"Internal V0000 request construction failed.\n";
        return 3;
    }

    DWORD written = 0;
    if (!WriteFile(port.get(), query.bytes.data(), static_cast<DWORD>(query.bytes.size()), &written, nullptr)) {
        std::wcerr << L"Version query write failed: " << win_error(GetLastError()) << L"\n";
        return 2;
    }
    if (written != query.bytes.size()) {
        std::wcerr << L"Version query write was short (" << written << L"/" << query.bytes.size() << L" bytes).\n";
        return 2;
    }

    wirex::direct_stream::Parser parser;
    std::array<std::uint8_t, 512> bytes{};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(2500);
    bool saw_v_record = false;
    while (std::chrono::steady_clock::now() < deadline) {
        DWORD count = 0;
        if (!ReadFile(port.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr)) {
            std::wcerr << L"Version query read failed: " << win_error(GetLastError()) << L"\n";
            return 2;
        }
        if (count == 0) continue;
        const auto result = parser.feed(bytes.data(), count);
        for (const auto& event : result.events) {
            if (!event.has_record || event.record.type != 0x56) continue;
            saw_v_record = true;
            if (event.record.payload.size() != 48) {
                std::wcerr << L"A valid V record arrived, but its length differs from the observed 48-byte version layout; fields withheld.\n";
                return 2;
            }
            const auto model = printable_field(event.record.payload, 0, 16);
            const auto version = printable_field(event.record.payload, 22, 6);
            if (model != "FTX-1" || !is_safe_version_field(version)) {
                std::wcerr << L"A valid V record arrived, but model/version fields did not match the redacted display layout; fields withheld.\n";
                return 2;
            }
            std::cout << "版本查询成功，完整 HRI 初始化尚未确认。\n"
                      << "型号: " << model << "\n软件版本: " << version << "\n";
            return 0;
        }
    }
    std::wcerr << (saw_v_record ? L"No usable version fields arrived" : L"No valid V response arrived") << L" within 2500 ms.\n";
    return 2;
}

bool read_wav_file(const std::wstring& path, std::vector<std::uint8_t>& bytes)
{
    std::error_code error;
    const auto file_size = std::filesystem::file_size(std::filesystem::path(path), error);
    if (error) {
        std::wcerr << L"Could not determine WAV file size.\n";
        return false;
    }
    if (file_size > wirex::wave_file::max_file_bytes) {
        std::wcerr << L"WAV file exceeds the configured 30-second audio plus metadata size limit.\n";
        return false;
    }
    if (file_size < 12) {
        std::wcerr << L"WAV file is too small for a RIFF/WAVE header.\n";
        return false;
    }

    std::ifstream file(std::filesystem::path(path), std::ios::binary);
    if (!file) {
        std::wcerr << L"Could not open WAV file for reading.\n";
        return false;
    }
    bytes.resize(static_cast<std::size_t>(file_size));
    file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (file.gcount() != static_cast<std::streamsize>(bytes.size())) {
        std::wcerr << L"WAV file changed or ended while being read.\n";
        bytes.clear();
        return false;
    }
    char extra = 0;
    file.read(&extra, 1);
    if (file.gcount() != 0 || file.bad()) {
        std::wcerr << L"WAV file changed while being read; refusing to play an unstable file.\n";
        bytes.clear();
        return false;
    }
    return true;
}

void list_audio_devices()
{
    const UINT inputs = waveInGetNumDevs();
    const UINT outputs = waveOutGetNumDevs();
    std::cout << "Wave input devices (select an ID explicitly; no default is chosen):\n";
    for (UINT id = 0; id < inputs; ++id) {
        WAVEINCAPSW caps{};
        const auto result = waveInGetDevCapsW(id, &caps, sizeof(caps));
        if (result == MMSYSERR_NOERROR) std::cout << "  input " << id << ": " << to_utf8(device_name(caps.szPname, MAXPNAMELEN)) << "\n";
        else std::cout << "  input " << id << ": query failed: " << to_utf8(mm_error(result)) << "\n";
    }
    std::cout << "Wave output devices (select an ID explicitly; no default is chosen):\n";
    for (UINT id = 0; id < outputs; ++id) {
        WAVEOUTCAPSW caps{};
        const auto result = waveOutGetDevCapsW(id, &caps, sizeof(caps));
        if (result == MMSYSERR_NOERROR) std::cout << "  output " << id << ": " << to_utf8(device_name(caps.szPname, MAXPNAMELEN)) << "\n";
        else std::cout << "  output " << id << ": query failed: " << to_utf8(mm_error(result)) << "\n";
    }
    if (inputs == 0) std::cout << "  (none)\n";
    if (outputs == 0) std::cout << "  (none)\n";
}

void list_audio_devices_json()
{
    std::cout << "{\"schema_version\":1,\"type\":\"audio_devices\",\"wave_inputs\":[";
    for (UINT id = 0; id < waveInGetNumDevs(); ++id) {
        if (id != 0) std::cout << ',';
        WAVEINCAPSW caps{};
        const auto result = waveInGetDevCapsW(id, &caps, sizeof(caps));
        const auto name = result == MMSYSERR_NOERROR ? to_utf8(device_name(caps.szPname, MAXPNAMELEN)) : "";
        const auto endpoint_id = result == MMSYSERR_NOERROR ? wave_endpoint_id(true, id) : std::nullopt;
        const auto format = pcm_format();
        const bool pcm_supported = result == MMSYSERR_NOERROR &&
            waveInOpen(nullptr, id, &format, 0, 0, WAVE_FORMAT_QUERY) == MMSYSERR_NOERROR;
        std::cout << "{\"id\":" << id << ",\"name\":" << json_escape(name)
                  << ",\"endpoint_id\":";
        if (endpoint_id) std::cout << json_escape(to_utf8(*endpoint_id));
        else std::cout << "null";
        std::cout
                  << ",\"pcm_48000_mono_s16_supported\":" << (pcm_supported ? "true" : "false") << '}';
    }
    std::cout << "],\"wave_outputs\":[";
    for (UINT id = 0; id < waveOutGetNumDevs(); ++id) {
        if (id != 0) std::cout << ',';
        WAVEOUTCAPSW caps{};
        const auto result = waveOutGetDevCapsW(id, &caps, sizeof(caps));
        const auto name = result == MMSYSERR_NOERROR ? to_utf8(device_name(caps.szPname, MAXPNAMELEN)) : "";
        const auto endpoint_id = result == MMSYSERR_NOERROR ? wave_endpoint_id(false, id) : std::nullopt;
        const auto format = pcm_format();
        const bool pcm_supported = result == MMSYSERR_NOERROR &&
            waveOutOpen(nullptr, id, &format, 0, 0, WAVE_FORMAT_QUERY) == MMSYSERR_NOERROR;
        std::cout << "{\"id\":" << id << ",\"name\":" << json_escape(name)
                  << ",\"endpoint_id\":";
        if (endpoint_id) std::cout << json_escape(to_utf8(*endpoint_id));
        else std::cout << "null";
        std::cout
                  << ",\"pcm_48000_mono_s16_supported\":" << (pcm_supported ? "true" : "false") << '}';
    }
    std::cout << "]}\n" << std::flush;
}

class WaveInput {
public:
    static constexpr std::size_t sample_count = 4800; // 48 kHz 下每块 100 ms。
    static constexpr std::size_t buffer_count = 4;
    struct Buffer {
        std::array<std::int16_t, sample_count> samples{};
        WAVEHDR header{};
        bool prepared{false};
    };

    ~WaveInput() { close(); }
    WaveInput(const WaveInput&) = delete;
    WaveInput& operator=(const WaveInput&) = delete;
    WaveInput() = default;

    bool open(UINT device_id, const std::wstring* expected_endpoint_id = nullptr)
    {
        if (device_ != nullptr || close_failed_) return false;
        if (expected_endpoint_id != nullptr &&
            !wave_endpoint_matches(true, device_id, *expected_endpoint_id)) {
            std::wcerr << L"WaveIn endpoint ID 与启动前核对值不同；拒绝打开其他音频设备。\n";
            return false;
        }
        auto format = pcm_format();
        const auto query = waveInOpen(nullptr, device_id, &format, 0, 0, WAVE_FORMAT_QUERY);
        if (query != MMSYSERR_NOERROR) {
            std::wcerr << L"Input device does not accept PCM 48000 Hz, mono, signed 16-bit: " << mm_error(query) << L"\n";
            return false;
        }
        event_.reset(CreateEventW(nullptr, FALSE, FALSE, nullptr));
        if (!event_.valid()) {
            std::wcerr << L"CreateEvent failed: " << win_error(GetLastError()) << L"\n";
            return false;
        }
        const auto opened = waveInOpen(&device_, device_id, &format, reinterpret_cast<DWORD_PTR>(event_.get()), 0, CALLBACK_EVENT);
        if (opened != MMSYSERR_NOERROR) {
            device_ = nullptr;
            std::wcerr << L"waveInOpen failed: " << mm_error(opened) << L"\n";
            return false;
        }
        for (auto& buffer : buffers_) {
            buffer.header = {};
            buffer.header.lpData = reinterpret_cast<LPSTR>(buffer.samples.data());
            buffer.header.dwBufferLength = static_cast<DWORD>(sizeof(buffer.samples));
            const auto prepared = waveInPrepareHeader(device_, &buffer.header, sizeof(buffer.header));
            if (prepared != MMSYSERR_NOERROR) {
                std::wcerr << L"waveInPrepareHeader failed: " << mm_error(prepared) << L"\n";
                close();
                return false;
            }
            buffer.prepared = true;
            const auto queued = waveInAddBuffer(device_, &buffer.header, sizeof(buffer.header));
            if (queued != MMSYSERR_NOERROR) {
                std::wcerr << L"waveInAddBuffer failed: " << mm_error(queued) << L"\n";
                close();
                return false;
            }
        }
        const auto started = waveInStart(device_);
        if (started != MMSYSERR_NOERROR) {
            std::wcerr << L"waveInStart failed: " << mm_error(started) << L"\n";
            close();
            return false;
        }
        started_ = true;
        return true;
    }

    [[nodiscard]] HANDLE event() const noexcept { return event_.get(); }
    [[nodiscard]] std::array<Buffer, buffer_count>& buffers() noexcept { return buffers_; }
    [[nodiscard]] MMRESULT requeue(Buffer& buffer) noexcept
    {
        secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
        return waveInAddBuffer(device_, &buffer.header, sizeof(buffer.header));
    }

    bool stop_capture() noexcept
    {
        if (device_ == nullptr || !started_) return device_ != nullptr;
        const auto stopped = waveInStop(device_);
        if (stopped != MMSYSERR_NOERROR) {
            std::wcerr << L"waveInStop failed while ending capture: " << mm_error(stopped) << L"\n";
            return false;
        }
        started_ = false;
        return true;
    }

    [[nodiscard]] bool is_open() const noexcept { return device_ != nullptr; }
    [[nodiscard]] bool close_failed() const noexcept { return close_failed_; }

    bool close() noexcept
    {
        if (device_ == nullptr) {
            event_.reset();
            return !close_failed_;
        }
        bool cleanup_ok = true;
        if (started_) {
            const auto stopped = waveInStop(device_);
            if (stopped != MMSYSERR_NOERROR) {
                std::wcerr << L"waveInStop cleanup failed: " << mm_error(stopped) << L"\n";
                cleanup_ok = false;
            }
        }
        const auto reset = waveInReset(device_);
        if (reset != MMSYSERR_NOERROR) {
            std::wcerr << L"waveInReset cleanup failed: " << mm_error(reset) << L"\n";
            cleanup_ok = false;
        } else {
            for (auto& buffer : buffers_) secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
        }
        for (auto& buffer : buffers_) {
            if (!buffer.prepared) continue;
            MMRESULT result = WAVERR_STILLPLAYING;
            for (int retry = 0; retry < 20 && result == WAVERR_STILLPLAYING; ++retry) {
                result = waveInUnprepareHeader(device_, &buffer.header, sizeof(buffer.header));
                if (result == WAVERR_STILLPLAYING) Sleep(5);
            }
            if (result == MMSYSERR_NOERROR) {
                buffer.prepared = false;
            } else {
                std::wcerr << L"waveInUnprepareHeader cleanup failed: " << mm_error(result) << L"\n";
                cleanup_ok = false;
            }
        }
        const auto closed = waveInClose(device_);
        if (closed == MMSYSERR_NOERROR) {
            device_ = nullptr;
        } else {
            std::wcerr << L"waveInClose cleanup failed: " << mm_error(closed) << L"\n";
            cleanup_ok = false;
        }
        if (!cleanup_ok) close_failed_ = true;
        started_ = false;
        if (device_ == nullptr) {
            event_.reset();
            for (auto& buffer : buffers_) secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
        }
        return cleanup_ok;
    }

private:
    HWAVEIN device_{nullptr};
    WinHandle event_{};
    std::array<Buffer, buffer_count> buffers_{};
    bool started_{false};
    bool close_failed_{false};
};

class WaveOutput {
public:
    static constexpr std::size_t buffer_count = WaveInput::buffer_count;
    struct Buffer {
        std::array<std::int16_t, WaveInput::sample_count> samples{};
        WAVEHDR header{};
        bool prepared{false};
        bool queued{false};
        std::uint64_t playback_generation{};
    };
    enum class SubmitResult { queued, full, failed, cancelled, timed_out };
    enum class DrainResult { complete, failed, cancelled, timed_out };
    static constexpr std::size_t max_completion_tokens = 8U;
    struct CompletedFrames {
        std::uint64_t generation{};
        std::size_t count{};
    };

    ~WaveOutput() { close(); }
    WaveOutput(const WaveOutput&) = delete;
    WaveOutput& operator=(const WaveOutput&) = delete;
    WaveOutput() = default;

    bool open(UINT device_id, const std::wstring* expected_endpoint_id = nullptr)
    {
        if (device_ != nullptr || !device_cleanup_state_.reopen_allowed()) return false;
        if (expected_endpoint_id != nullptr &&
            !wave_endpoint_matches(false, device_id, *expected_endpoint_id)) {
            std::wcerr << L"WaveOut endpoint ID 与启动前核对值不同；拒绝打开其他音频设备。\n";
            return false;
        }
        auto format = pcm_format();
        const auto query = waveOutOpen(nullptr, device_id, &format, 0, 0, WAVE_FORMAT_QUERY);
        if (query != MMSYSERR_NOERROR) {
            std::wcerr << L"Output device does not accept PCM 48000 Hz, mono, signed 16-bit: " << mm_error(query) << L"\n";
            return false;
        }
        event_.reset(CreateEventW(nullptr, FALSE, FALSE, nullptr));
        if (!event_.valid()) {
            std::wcerr << L"CreateEvent failed: " << win_error(GetLastError()) << L"\n";
            return false;
        }
        const auto opened = waveOutOpen(&device_, device_id, &format, reinterpret_cast<DWORD_PTR>(event_.get()), 0, CALLBACK_EVENT);
        if (opened != MMSYSERR_NOERROR) {
            device_ = nullptr;
            std::wcerr << L"waveOutOpen failed: " << mm_error(opened) << L"\n";
            return false;
        }
        return wirex::wave_output_open::prepare_all_or_close(buffers_.size(), [&](std::size_t index) {
            auto& buffer = buffers_[index];
            buffer.header = {};
            buffer.header.lpData = reinterpret_cast<LPSTR>(buffer.samples.data());
            buffer.header.dwBufferLength = static_cast<DWORD>(sizeof(buffer.samples));
            const auto prepared = waveOutPrepareHeader(device_, &buffer.header, sizeof(buffer.header));
            if (prepared != MMSYSERR_NOERROR) {
                std::wcerr << L"waveOutPrepareHeader failed: " << mm_error(prepared) << L"\n";
                return false;
            }
            buffer.prepared = true;
            return true;
        }, [&]() { return close(); }, device_cleanup_state_);
    }

    [[nodiscard]] HANDLE event() const noexcept { return event_.get(); }
    [[nodiscard]] bool is_open() const noexcept { return device_ != nullptr; }
    [[nodiscard]] bool close_failed() const noexcept { return device_cleanup_state_.close_failed(); }

    [[nodiscard]] bool has_capacity() noexcept
    {
        reap();
        if (device_ == nullptr) return false;
        for (const auto& buffer : buffers_) {
            if (!buffer.queued) return true;
        }
        return false;
    }

    void reap() noexcept
    {
        if (device_ == nullptr) return;
        for (auto& buffer : buffers_) {
            if (buffer.queued && (buffer.header.dwFlags & WHDR_DONE) != 0) {
                buffer.queued = false;
                buffer.header.dwBufferLength = static_cast<DWORD>(sizeof(buffer.samples));
                if (buffer.playback_generation != 0U) {
                    if (completion_count_ < completions_.size()) {
                        const std::size_t write = (completion_read_ + completion_count_) % completions_.size();
                        completions_[write] = CompletedFrames{buffer.playback_generation, 1U};
                        ++completion_count_;
                    } else {
                        completion_overflow_ = true;
                    }
                    buffer.playback_generation = 0U;
                }
            }
        }
    }

    // 回报本次已完成的20 ms PCM缓冲，供声码器管线回收其有界未确认帧。
    [[nodiscard]] bool take_completed_frames(CompletedFrames& completed) noexcept
    {
        // 完成标志只在访问WAVEHDR时回收；即使调用方只取完成计数，也必须先扫描。
        reap();
        if (completion_count_ == 0U) return false;
        completed = completions_[completion_read_];
        completion_read_ = (completion_read_ + 1U) % completions_.size();
        --completion_count_;
        while (completion_count_ != 0U &&
               completions_[completion_read_].generation == completed.generation) {
            completed.count += completions_[completion_read_].count;
            completion_read_ = (completion_read_ + 1U) % completions_.size();
            --completion_count_;
        }
        return true;
    }

    [[nodiscard]] bool completion_overflowed() const noexcept { return completion_overflow_; }

    [[nodiscard]] bool all_drained() noexcept
    {
        reap();
        for (const auto& buffer : buffers_) {
            if (buffer.queued) return false;
        }
        return true;
    }

    SubmitResult submit(const void* samples, DWORD byte_count) noexcept
    {
        return submit_for_generation(samples, byte_count, 0U);
    }

    SubmitResult submit_playback_frame(const void* samples, DWORD byte_count,
                                       std::uint64_t generation) noexcept
    {
        if (generation == 0U) return SubmitResult::failed;
        return submit_for_generation(samples, byte_count, generation);
    }

    SubmitResult submit_for_generation(const void* samples, DWORD byte_count,
                                       std::uint64_t generation) noexcept
    {
        if (device_ == nullptr || samples == nullptr || byte_count == 0 ||
            byte_count > sizeof(buffers_[0].samples) || byte_count % sizeof(std::int16_t) != 0) {
            return SubmitResult::failed;
        }
        reap();
        for (auto& buffer : buffers_) {
            if (buffer.queued) continue;
            std::memcpy(buffer.samples.data(), samples, byte_count);
            buffer.header.dwBufferLength = byte_count;
            buffer.header.dwBytesRecorded = 0;
            const auto written = waveOutWrite(device_, &buffer.header, sizeof(buffer.header));
            if (written != MMSYSERR_NOERROR) return SubmitResult::failed;
            buffer.queued = true;
            buffer.playback_generation = generation;
            return SubmitResult::queued;
        }
        return SubmitResult::full;
    }

    SubmitResult submit_wait(const void* samples, DWORD byte_count,
                             std::chrono::steady_clock::time_point deadline) noexcept
    {
        for (;;) {
            if (console_lifecycle().cancel_requested()) return SubmitResult::cancelled;
            const auto submitted = submit(samples, byte_count);
            if (submitted != SubmitResult::full) return submitted;
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) return SubmitResult::timed_out;
            const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
            if (remaining <= 0) return SubmitResult::timed_out;
            const auto wait_ms = static_cast<DWORD>(std::min<std::int64_t>(100, remaining));
            const DWORD result = WaitForSingleObject(event_.get(), wait_ms);
            if (result != WAIT_OBJECT_0 && result != WAIT_TIMEOUT) return SubmitResult::failed;
        }
    }

    DrainResult drain_until(std::chrono::steady_clock::time_point deadline) noexcept
    {
        for (;;) {
            reap();
            bool any_queued = false;
            for (const auto& buffer : buffers_) any_queued = any_queued || buffer.queued;
            if (!any_queued) return DrainResult::complete;
            if (console_lifecycle().cancel_requested()) return DrainResult::cancelled;
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) return DrainResult::timed_out;
            const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
            if (remaining <= 0) return DrainResult::timed_out;
            const auto wait_ms = static_cast<DWORD>(std::min<std::int64_t>(100, remaining));
            const DWORD result = WaitForSingleObject(event_.get(), wait_ms);
            if (result != WAIT_OBJECT_0 && result != WAIT_TIMEOUT) return DrainResult::failed;
        }
    }

    bool close() noexcept
    {
        if (device_ == nullptr) {
            event_.reset();
            for (auto& buffer : buffers_) secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
            clear_playback_completions();
            return !device_cleanup_state_.close_failed();
        }
        bool cleanup_ok = true;
        const auto reset = waveOutReset(device_);
        if (reset != MMSYSERR_NOERROR) {
            std::wcerr << L"waveOutReset cleanup failed: " << mm_error(reset) << L"\n";
            cleanup_ok = false;
        } else {
            for (auto& buffer : buffers_) secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
        }
        for (auto& buffer : buffers_) {
            if (!buffer.prepared) continue;
            MMRESULT result = WAVERR_STILLPLAYING;
            for (int retry = 0; retry < 20 && result == WAVERR_STILLPLAYING; ++retry) {
                result = waveOutUnprepareHeader(device_, &buffer.header, sizeof(buffer.header));
                if (result == WAVERR_STILLPLAYING) Sleep(5);
            }
            if (result == MMSYSERR_NOERROR) {
                buffer.prepared = false;
                buffer.queued = false;
                secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
            } else {
                std::wcerr << L"waveOutUnprepareHeader cleanup failed: " << mm_error(result) << L"\n";
                cleanup_ok = false;
            }
        }
        const auto closed = waveOutClose(device_);
        if (closed == MMSYSERR_NOERROR) {
            device_ = nullptr;
            for (auto& buffer : buffers_) secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
        } else {
            std::wcerr << L"waveOutClose cleanup failed: " << mm_error(closed) << L"\n";
            cleanup_ok = false;
        }
        device_cleanup_state_.record_close_result(cleanup_ok);
        if (device_ == nullptr) {
            event_.reset();
            clear_playback_completions();
        }
        return cleanup_ok && !device_cleanup_state_.close_failed();
    }

private:
    void clear_playback_completions() noexcept
    {
        completion_read_ = 0U;
        completion_count_ = 0U;
        completion_overflow_ = false;
        for (auto& buffer : buffers_) buffer.playback_generation = 0U;
    }

    HWAVEOUT device_{nullptr};
    WinHandle event_{};
    std::array<Buffer, buffer_count> buffers_{};
    std::array<CompletedFrames, max_completion_tokens> completions_{};
    std::size_t completion_read_{};
    std::size_t completion_count_{};
    bool completion_overflow_{};
    wirex::wave_output_open::State device_cleanup_state_{};
};

int audio_loop(UINT input_id, UINT output_id, unsigned long seconds, std::uint32_t gain_milli)
{
    if (input_id >= waveInGetNumDevs() || output_id >= waveOutGetNumDevs()) {
        std::wcerr << L"Input or output ID is outside the enumerated device range. Run --list-audio and select IDs explicitly.\n";
        return 2;
    }
    WAVEINCAPSW input_caps{};
    WAVEOUTCAPSW output_caps{};
    const auto input_query = waveInGetDevCapsW(input_id, &input_caps, sizeof(input_caps));
    const auto output_query = waveOutGetDevCapsW(output_id, &output_caps, sizeof(output_caps));
    if (input_query != MMSYSERR_NOERROR || output_query != MMSYSERR_NOERROR) {
        std::wcerr << L"Could not query the selected audio device names.\n";
        return 2;
    }
    wirex::ConsoleHandlerScope control_scope;

    std::cout << "Routing selected input to selected output for " << seconds << " s; PCM 48000 Hz, mono, signed 16-bit.\n"
              << "Explicit software gain=" << gain_milli / 1000U << "." << std::setw(3) << std::setfill('0') << gain_milli % 1000U
              << std::setfill(' ') << "x; no system mixer level is changed.\n"
              << "Input " << input_id << ": " << to_utf8(device_name(input_caps.szPname, MAXPNAMELEN)) << "\n"
              << "Output " << output_id << ": " << to_utf8(device_name(output_caps.szPname, MAXPNAMELEN)) << "\n"
              << "No default device, file recording, or PTT is used. Unsupported formats are refused.\n";

    WaveOutput output;
    if (!output.open(output_id)) return 2;
    WaveInput input;
    if (!input.open(input_id)) {
        const bool output_cleanup_ok = output.close();
        return output_cleanup_ok ? 2 : 3;
    }

    if (!control_scope.start()) {
        std::wcerr << L"Could not register the console control handler: " << win_error(GetLastError()) << L"\n";
        const bool input_cleanup_ok = input.close();
        const bool output_cleanup_ok = output.close();
        return input_cleanup_ok && output_cleanup_ok ? 2 : 3;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    std::uint64_t captured_bytes = 0;
    std::uint64_t submitted_bytes = 0;
    std::uint64_t dropped_blocks = 0;
    std::uint64_t clipped_samples = 0;
    wirex::pcm_gain::SignalStats captured_stats{};
    wirex::pcm_gain::SignalStats routed_input_stats{};
    wirex::pcm_gain::SignalStats submitted_stats{};
    std::array<std::int16_t, WaveInput::sample_count> routed_samples{};
    bool failed = false;
    HANDLE events[] = {input.event(), output.event()};

    while (!control_scope.cancel_requested() && std::chrono::steady_clock::now() < deadline) {
        const DWORD wait_result = WaitForMultipleObjects(2, events, FALSE, 100);
        if (wait_result == WAIT_FAILED) {
            std::wcerr << L"WaitForMultipleObjects failed: " << win_error(GetLastError()) << L"\n";
            failed = true;
            break;
        }
        output.reap();
        for (auto& buffer : input.buffers()) {
            if ((buffer.header.dwFlags & WHDR_DONE) == 0) continue;
            const auto recorded = buffer.header.dwBytesRecorded;
            if (recorded > buffer.header.dwBufferLength || recorded % sizeof(std::int16_t) != 0) {
                std::wcerr << L"WaveIn returned an invalid byte count or a partial 16-bit PCM sample; stopping.\n";
                failed = true;
                break;
            }
            captured_bytes += recorded;
            if (recorded != 0) {
                const auto sample_count = static_cast<std::size_t>(recorded / sizeof(std::int16_t));
                const auto input_block_stats = wirex::pcm_gain::measure(buffer.samples.data(), sample_count);
                wirex::pcm_gain::accumulate(captured_stats, input_block_stats);
                if (!output.has_capacity()) {
                    ++dropped_blocks;
                } else {
                    std::copy_n(buffer.samples.begin(), sample_count, routed_samples.begin());
                    const auto gain_result = wirex::pcm_gain::apply(routed_samples.data(), sample_count, gain_milli);
                    if (!gain_result.valid) {
                        std::wcerr << L"The selected software gain was rejected by the PCM processor.\n";
                        failed = true;
                        break;
                    }
                    const auto result = output.submit(routed_samples.data(), recorded);
                    if (result == WaveOutput::SubmitResult::queued) {
                        submitted_bytes += recorded;
                        clipped_samples += gain_result.clipped_samples;
                        wirex::pcm_gain::accumulate(routed_input_stats, gain_result.before);
                        wirex::pcm_gain::accumulate(submitted_stats, gain_result.after);
                    } else if (result == WaveOutput::SubmitResult::full) {
                        ++dropped_blocks;
                    } else {
                        std::wcerr << L"waveOutWrite failed or received invalid PCM block metadata.\n";
                        failed = true;
                        break;
                    }
                }
            }
            buffer.header.dwBytesRecorded = 0;
            const auto requeued = input.requeue(buffer);
            if (requeued != MMSYSERR_NOERROR) {
                std::wcerr << L"waveInAddBuffer failed during audio routing: " << mm_error(requeued) << L"\n";
                failed = true;
                break;
            }
        }
        if (failed) break;
    }

    const bool input_cleanup_ok = input.close();
    const bool output_cleanup_ok = output.close();
    if (!control_scope.signal_cleanup_complete()) failed = true;
    if (!control_scope.unregister_now()) {
        std::wcerr << L"Could not unregister the console control handler: " << win_error(GetLastError()) << L"\n";
        failed = true;
    }
    if (input_cleanup_ok && output_cleanup_ok) {
        if (control_scope.cancel_requested()) std::cout << "Audio route cancelled; reset and close calls succeeded for owned audio resources.\n";
        else std::cout << "Audio route stopped; reset and close calls succeeded for owned audio resources.\n";
    } else {
        std::cout << "Audio route stopped, but at least one audio cleanup call failed; inspect the error output.\n";
    }
    std::cout << "Captured PCM bytes=" << captured_bytes << ", submitted to output bytes=" << submitted_bytes
              << ", dropped input blocks=" << dropped_blocks << ".\n";
    std::cout << std::fixed << std::setprecision(1)
              << "Captured input: samples=" << captured_stats.sample_count
              << ", RMS=" << wirex::pcm_gain::rms_dbfs(captured_stats) << " dBFS"
              << ", peak=" << wirex::pcm_gain::peak_dbfs(captured_stats) << " dBFS.\n"
              << "Submitted pre-gain input: samples=" << routed_input_stats.sample_count
              << ", RMS=" << wirex::pcm_gain::rms_dbfs(routed_input_stats) << " dBFS"
              << ", peak=" << wirex::pcm_gain::peak_dbfs(routed_input_stats) << " dBFS.\n"
              << "Submitted post-gain output: samples=" << submitted_stats.sample_count
              << ", RMS=" << wirex::pcm_gain::rms_dbfs(submitted_stats) << " dBFS"
              << ", peak=" << wirex::pcm_gain::peak_dbfs(submitted_stats) << " dBFS"
              << ", saturated samples=" << clipped_samples << ".\n";
    return failed || !input_cleanup_ok || !output_cleanup_ok ? 2 : 0;
}

bool load_hri_y_template(const std::filesystem::path& path, std::vector<std::uint8_t>& body)
{
    if (!path.is_absolute()) {
        std::wcerr << L"--body-file must be an absolute path.\n";
        return false;
    }
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        std::wcerr << L"Could not read the external HRI body file.\n";
        return false;
    }
    std::array<std::uint8_t, wirex::hri_session::y_body_size + 1> bytes{};
    file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (file.gcount() != static_cast<std::streamsize>(wirex::hri_session::y_body_size) ||
        bytes[wirex::hri_session::y_body_size] != 0 || file.bad()) {
        std::wcerr << L"The external HRI body must contain exactly 100 bytes.\n";
        return false;
    }
    body.assign(bytes.begin(), bytes.begin() + wirex::hri_session::y_body_size);
    if (body[5] != '2') {
        std::wcerr << L"The external HRI body does not have ASCII '2' at byte offset 5.\n";
        body.clear();
        return false;
    }

    constexpr std::string_view expected_hash =
        "82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f";
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD object_length = 0;
    DWORD returned = 0;
    std::vector<UCHAR> object_buffer;
    std::array<UCHAR, 32> actual_hash{};
    std::string actual_hash_hex;
    NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (status >= 0) {
        status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
            reinterpret_cast<PUCHAR>(&object_length), sizeof(object_length), &returned, 0);
    }
    if (status >= 0 && (returned != sizeof(object_length) || object_length == 0)) status = static_cast<NTSTATUS>(-1);
    if (status >= 0) {
        object_buffer.resize(object_length);
        status = BCryptCreateHash(algorithm, &hash, object_buffer.data(), object_length, nullptr, 0, 0);
    }
    if (status >= 0) {
        status = BCryptHashData(hash, body.data(), static_cast<ULONG>(body.size()), 0);
    }
    if (status >= 0) {
        status = BCryptFinishHash(hash, actual_hash.data(), static_cast<ULONG>(actual_hash.size()), 0);
    }
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
    if (status >= 0) {
        constexpr char hex_digits[] = "0123456789abcdef";
        actual_hash_hex.reserve(actual_hash.size() * 2);
        for (const auto byte : actual_hash) {
            actual_hash_hex.push_back(hex_digits[byte >> 4U]);
            actual_hash_hex.push_back(hex_digits[byte & 0x0fU]);
        }
    }
    if (status < 0 || actual_hash_hex != expected_hash) {
        std::wcerr << L"The external HRI body does not match the approved 100-byte fixture SHA-256.\n";
        body.clear();
        return false;
    }
    return true;
}

bool prepare_hri_audio_devices(UINT input_id, UINT output_id)
{
    if (input_id >= waveInGetNumDevs() || output_id >= waveOutGetNumDevs()) {
        std::wcerr << L"Input or output ID is outside the enumerated device range; no default device is selected.\n";
        return false;
    }
    auto format = pcm_format();
    const auto input_query = waveInOpen(nullptr, input_id, &format, 0, 0, WAVE_FORMAT_QUERY);
    const auto output_query = waveOutOpen(nullptr, output_id, &format, 0, 0, WAVE_FORMAT_QUERY);
    if (input_query != MMSYSERR_NOERROR || output_query != MMSYSERR_NOERROR) {
        std::wcerr << L"Selected audio devices must both accept PCM 48000 Hz, mono, signed 16-bit. Input query: "
                   << mm_error(input_query) << L"; output query: " << mm_error(output_query) << L"\n";
        return false;
    }
    return true;
}

bool pre_drain_hri_serial(HANDLE port, std::uint64_t& discarded_bytes)
{
    constexpr std::uint64_t max_drain_bytes = 4096;
    constexpr auto max_drain_time = std::chrono::milliseconds(250);
    constexpr auto quiet_time = std::chrono::milliseconds(20);
    std::array<std::uint8_t, 512> buffer{};
    const auto started = std::chrono::steady_clock::now();
    auto quiet_since = started;
    discarded_bytes = 0;
    while (std::chrono::steady_clock::now() - started < max_drain_time) {
        DWORD errors = 0;
        COMSTAT state{};
        if (!ClearCommError(port, &errors, &state) || errors != 0) {
            std::wcerr << L"Serial pre-drain could not establish a clean read state.\n";
            return false;
        }
        if (state.cbInQue != 0) {
            if (discarded_bytes >= max_drain_bytes) {
                std::wcerr << L"Serial pre-drain reached its 4096-byte discard limit.\n";
                return false;
            }
            const auto remaining = static_cast<DWORD>(max_drain_bytes - discarded_bytes);
            const DWORD requested = std::min<DWORD>(state.cbInQue,
                std::min<DWORD>(static_cast<DWORD>(buffer.size()), remaining));
            DWORD actual = 0;
            if (!ReadFile(port, buffer.data(), requested, &actual, nullptr) || actual > requested) {
                std::wcerr << L"Serial pre-drain read failed or returned an invalid count.\n";
                return false;
            }
            if (actual != 0) {
                discarded_bytes += actual;
                quiet_since = std::chrono::steady_clock::now();
            }
            continue;
        }
        if (std::chrono::steady_clock::now() - quiet_since >= quiet_time) return true;
        Sleep(2);
    }
    std::wcerr << L"Serial pre-drain did not reach 20 ms of quiet within 250 ms.\n";
    return false;
}

const wchar_t* hri_stop_reason_name(wirex::hri_session::StopReason reason) noexcept
{
    using wirex::hri_session::StopReason;
    switch (reason) {
    case StopReason::none: return L"none";
    case StopReason::invalid_configuration: return L"invalid_configuration";
    case StopReason::invalid_y_template: return L"invalid_y_template";
    case StopReason::already_started: return L"already_started";
    case StopReason::time_overflow: return L"time_overflow";
    case StopReason::clock_regressed: return L"clock_regressed";
    case StopReason::deadline: return L"deadline";
    case StopReason::version_timeout: return L"version_timeout";
    case StopReason::cancelled: return L"cancelled";
    case StopReason::malformed_record: return L"malformed_record";
    case StopReason::version_mismatch: return L"version_mismatch";
    case StopReason::unexpected_version_record: return L"unexpected_version_record";
    case StopReason::receive_limit: return L"receive_limit";
    case StopReason::record_limit: return L"record_limit";
    case StopReason::transmit_limit: return L"transmit_limit";
    case StopReason::y_write_limit: return L"y_write_limit";
    case StopReason::y_ack_timeout: return L"y_ack_timeout";
    case StopReason::x_ack_limit: return L"x_ack_limit";
    case StopReason::write_failed: return L"write_failed";
    case StopReason::unexpected_write_completion: return L"unexpected_write_completion";
    case StopReason::incomplete_record: return L"incomplete_record";
    case StopReason::pending_write_limit: return L"pending_write_limit";
    case StopReason::caller_stopped: return L"caller_stopped";
    case StopReason::transport_failure: return L"transport_failure";
    case StopReason::audio_failure: return L"audio_failure";
    case StopReason::report_failure: return L"report_failure";
    }
    return L"unknown";
}

const char* hri_phase_name(wirex::hri_session::Phase phase) noexcept
{
    using wirex::hri_session::Phase;
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

int hri_listen(const std::wstring& port_name, const std::filesystem::path& body_path,
               UINT input_id, UINT output_id, unsigned long seconds, std::uint32_t gain_milli,
               const std::optional<std::filesystem::path>& report_path)
{
    wirex::ConsoleHandlerScope control_scope;
    WinHandle port;
    const bool report_enabled = report_path.has_value();
    wirex::session_report::Writer report_writer;
    wirex::session_report::RuntimeFields report_runtime{};
    wirex::hri_session::Snapshot report_hri_state{};
    std::string report_error;
    if (report_enabled) {
        if (!wirex::session_report::Writer::create(*report_path, report_writer, report_error)) {
            std::cerr << "Could not initialize HRI status report: " << report_error << ".\n";
            return 2;
        }
        report_runtime.phase = "preflight";
        report_runtime.audio_input_cleanup = "not_started";
        report_runtime.audio_output_cleanup = "not_started";
        report_runtime.serial_cleanup = "not_opened";
        if (!report_writer.write(report_hri_state, report_runtime, report_error)) {
            std::cerr << "Could not create HRI status report before opening the serial port: "
                      << report_error << ".\n";
            return 2;
        }
    }

    auto finish_early = [&](const char* phase, const char* failure_reason) {
        const bool serial_was_opened = port.valid();
        bool serial_close_ok = true;
        if (port.valid()) {
            const HANDLE serial_handle = port.release();
            serial_close_ok = serial_handle != nullptr && serial_handle != INVALID_HANDLE_VALUE &&
                CloseHandle(serial_handle) != FALSE;
        }
        if (report_enabled) {
            report_runtime.final = true;
            report_runtime.status = "failed";
            report_runtime.phase = phase;
            report_runtime.failure_reason = failure_reason;
            report_runtime.serial_cleanup = !serial_was_opened ? "not_opened" :
                (serial_close_ok ? "succeeded" : "failed");
            if (!report_writer.write(report_hri_state, report_runtime, report_error)) {
                std::cerr << "Could not finalize HRI status report: " << report_error << ".\n";
            }
        }
        return 2;
    };

    auto write_preflight_stage = [&](const char* phase) {
        if (!report_enabled) return true;
        report_runtime.phase = phase;
        report_runtime.serial_cleanup = port.valid() ? "pending" : "not_opened";
        if (report_writer.write(report_hri_state, report_runtime, report_error)) return true;
        report_runtime.report_write_failed = true;
        std::cerr << "HRI status report update failed before session start: " << report_error << ".\n";
        return false;
    };

    std::vector<std::uint8_t> y_body;
    if (!load_hri_y_template(body_path, y_body)) return finish_early("preflight_failed", "y_template_invalid");
    if (!prepare_hri_audio_devices(input_id, output_id)) return finish_early("preflight_failed", "audio_preflight_failed");

    std::wstring device_path;
    if (!parse_port(port_name, device_path)) {
        std::wcerr << L"Invalid port. Use an explicit COM name such as COM5.\n";
        return finish_early("preflight_failed", "port_name_invalid");
    }
    port.reset(CreateFileW(device_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!port.valid()) {
        std::wcerr << L"Cannot open " << port_name << L": " << win_error(GetLastError()) << L"\n";
        return finish_early("serial_open_failed", "serial_open_failed");
    }
    if (!write_preflight_stage("serial_opened")) return finish_early("report_update_failed", "metadata_write_failure");
    if (!configure_serial(port.get(), false)) return finish_early("serial_configuration_failed", "serial_configuration_failed");
    COMMTIMEOUTS serial_timeouts{};
    serial_timeouts.ReadIntervalTimeout = 5;
    serial_timeouts.ReadTotalTimeoutConstant = 10;
    serial_timeouts.WriteTotalTimeoutConstant = 100;
    if (!SetCommTimeouts(port.get(), &serial_timeouts)) {
        std::wcerr << L"Could not set bounded HRI serial timeouts: " << win_error(GetLastError()) << L"\n";
        return finish_early("serial_configuration_failed", "serial_timeout_configuration_failed");
    }
    std::uint64_t discarded_bytes = 0;
    if (!pre_drain_hri_serial(port.get(), discarded_bytes)) return finish_early("serial_pre_drain_failed", "serial_pre_drain_failed");
    if (!write_preflight_stage("serial_prepared")) return finish_early("report_update_failed", "metadata_write_failure");

    WAVEINCAPSW input_caps{};
    WAVEOUTCAPSW output_caps{};
    if (waveInGetDevCapsW(input_id, &input_caps, sizeof(input_caps)) != MMSYSERR_NOERROR ||
        waveOutGetDevCapsW(output_id, &output_caps, sizeof(output_caps)) != MMSYSERR_NOERROR) {
        std::wcerr << L"Could not query selected audio device names.\n";
        return finish_early("audio_preflight_failed", "audio_device_query_failed");
    }
    std::cout << "Starting one bounded HRI observation window: " << seconds << " s, selected serial "
              << to_utf8(port_name) << " at 115200 8N1, handshake=None, DTR=false, RTS=false.\n"
              << "External Y body SHA-256 and 100-byte length verified; body contents are not displayed.\n"
              << "Pre-session serial bytes discarded=" << discarded_bytes << "; parser starts empty after 20 ms quiet.\n"
              << "Audio is gated until a complete, checksum-valid Y/0 is observed. Gain="
              << gain_milli / 1000U << "." << std::setw(3) << std::setfill('0') << gain_milli % 1000U
              << std::setfill(' ') << "x. Only the bounded V/Y/X records are sent; no extra software PTT/CAT command is called, and RF behavior is unmeasured.\n"
              << "unsupported_config_import=not_implemented; X/100 byte 0x0b ASCII '1' is counted, not applied; configuration synchronization is unconfirmed.\n"
              << "Input " << input_id << ": " << to_utf8(device_name(input_caps.szPname, MAXPNAMELEN))
              << "; output " << output_id << ": " << to_utf8(device_name(output_caps.szPname, MAXPNAMELEN)) << "\n";
    std::cout.flush();

    COMMTIMEOUTS active_timeouts{};
    active_timeouts.ReadIntervalTimeout = 5;
    active_timeouts.ReadTotalTimeoutConstant = 10;
    active_timeouts.WriteTotalTimeoutConstant = 100;
    if (!SetCommTimeouts(port.get(), &active_timeouts)) {
        std::wcerr << L"Could not initialize active HRI serial timeouts.\n";
        return finish_early("serial_configuration_failed", "active_serial_timeout_configuration_failed");
    }

    if (!control_scope.start()) {
        std::wcerr << L"Could not register the console control handler: " << win_error(GetLastError()) << L"\n";
        return finish_early("console_handler_failed", "console_handler_registration_failed");
    }

    using Clock = std::chrono::steady_clock;
    const auto session_started = Clock::now();
    auto elapsed_ms = [&]() -> std::uint64_t {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - session_started).count();
        return elapsed < 0 ? 0 : static_cast<std::uint64_t>(elapsed);
    };
    wirex::hri_session::Session session(std::move(y_body),
        wirex::hri_session::Config{static_cast<std::uint64_t>(seconds) * 1000U});
    bool io_failed = false;
    bool audio_failed = false;
    bool audio_started = false;
    bool input_open_attempted = false;
    bool output_open_attempted = false;
    bool report_write_failed = report_runtime.report_write_failed;
    std::string io_failure_detail;
    std::string report_failure_detail;
    WaveInput input;
    WaveOutput output;
    std::uint64_t captured_bytes = 0;
    std::uint64_t submitted_bytes = 0;
    std::uint64_t dropped_blocks = 0;
    std::uint64_t clipped_samples = 0;
    wirex::pcm_gain::SignalStats captured_stats{};
    wirex::pcm_gain::SignalStats routed_input_stats{};
    wirex::pcm_gain::SignalStats submitted_stats{};
    std::array<std::int16_t, WaveInput::sample_count> routed_samples{};

    auto refresh_report_fields = [&](std::string_view phase, bool final, std::string_view status,
                                     std::string_view failure_reason, bool input_cleanup_known,
                                     bool input_cleanup_ok, bool output_cleanup_known,
                                     bool output_cleanup_ok, std::string_view serial_cleanup) {
        report_runtime.phase.assign(phase);
        report_runtime.final = final;
        report_runtime.status.assign(status);
        report_runtime.failure_reason.assign(failure_reason);
        report_runtime.audio_started = audio_started;
        report_runtime.elapsed_ms = elapsed_ms();
        report_runtime.captured_bytes = captured_bytes;
        report_runtime.submitted_bytes = submitted_bytes;
        report_runtime.dropped_blocks = dropped_blocks;
        report_runtime.clipped_samples = clipped_samples;
        report_runtime.report_write_failed = report_write_failed;
        report_runtime.audio_input_cleanup = !input_open_attempted ? "not_started" :
            (input_cleanup_known ? (input_cleanup_ok ? "succeeded" : "failed") : "pending");
        report_runtime.audio_output_cleanup = !output_open_attempted ? "not_started" :
            (output_cleanup_known ? (output_cleanup_ok ? "succeeded" : "failed") : "pending");
        report_runtime.serial_cleanup.assign(serial_cleanup);
    };

    std::string last_report_phase;
    std::uint64_t next_report_ms = 0;
    auto write_runtime_report = [&](bool force) -> bool {
        if (!report_enabled) return true;
        const auto state = session.snapshot();
        const std::string phase = audio_started ? "audio_active" : hri_phase_name(state.phase);
        const auto now = elapsed_ms();
        if (!force && phase == last_report_phase && now < next_report_ms) return true;
        refresh_report_fields(phase, false, "running", "", false, false, false, false, "pending");
        if (!report_writer.write(state, report_runtime, report_error)) {
            report_write_failed = true;
            io_failed = true;
            report_failure_detail = report_error;
            io_failure_detail = "session status report update failed";
            std::cerr << "HRI status report update failed: " << report_error << ".\n" << std::flush;
            return false;
        }
        last_report_phase = phase;
        next_report_ms = now + 1000;
        return true;
    };

    auto dispatch_commands = [&](const wirex::hri_session::Update& update) -> bool {
        for (const auto& command : update.commands) {
            if (session.snapshot().phase == wirex::hri_session::Phase::stopped) return false;
            if (control_scope.cancel_requested()) {
                (void)session.cancel();
                return false;
            }
            DWORD actual = 0;
            const BOOL wrote = WriteFile(port.get(), command.frame.data(),
                static_cast<DWORD>(command.frame.size()), &actual, nullptr);
            const bool full_write = wrote != FALSE && actual == command.frame.size();
            const auto completion = session.write_completed(command.id, full_write, elapsed_ms());
            if (!full_write) {
                io_failed = true;
                io_failure_detail = wrote == FALSE ? "serial WriteFile failed" : "serial WriteFile returned a short count";
                return false;
            }
            if (completion.state.phase == wirex::hri_session::Phase::stopped) return false;
        }
        if (!write_runtime_report(false)) {
            (void)session.abort(wirex::hri_session::StopReason::report_failure);
            return false;
        }
        return session.snapshot().phase != wirex::hri_session::Phase::stopped;
    };

    const auto initial = session.start(0);
    bool active = dispatch_commands(initial);
    std::array<std::uint8_t, 1024> receive_buffer{};
    while (active) {
        if (control_scope.cancel_requested()) {
            (void)session.cancel();
            break;
        }

        auto update = session.tick(elapsed_ms());
        if (update.state.phase == wirex::hri_session::Phase::stopped) break;
        if (!dispatch_commands(update)) break;
        if (!write_runtime_report(false)) {
            (void)session.abort(wirex::hri_session::StopReason::report_failure);
            break;
        }
        if (session.snapshot().phase == wirex::hri_session::Phase::stopped) break;

        DWORD comm_errors = 0;
        COMSTAT comm_state{};
        if (!ClearCommError(port.get(), &comm_errors, &comm_state) || comm_errors != 0) {
            io_failed = true;
            io_failure_detail = "serial status reported an error";
            (void)session.abort(wirex::hri_session::StopReason::transport_failure);
            break;
        }
        if (comm_state.cbInQue != 0) {
            const DWORD requested = std::min<DWORD>(comm_state.cbInQue, static_cast<DWORD>(receive_buffer.size()));
            DWORD actual = 0;
            if (!ReadFile(port.get(), receive_buffer.data(), requested, &actual, nullptr) || actual > requested) {
                io_failed = true;
                io_failure_detail = "serial ReadFile failed or returned an invalid count";
                (void)session.abort(wirex::hri_session::StopReason::transport_failure);
                break;
            }
            if (actual != 0) {
                update = session.feed(receive_buffer.data(), actual, elapsed_ms());
                if (!dispatch_commands(update)) break;
                if (!write_runtime_report(false)) {
                    (void)session.abort(wirex::hri_session::StopReason::report_failure);
                    break;
                }
                if (update.state.phase == wirex::hri_session::Phase::stopped ||
                    session.snapshot().phase == wirex::hri_session::Phase::stopped) break;
            }
        }

        if (!audio_started && session.snapshot().may_start_audio_route) {
            output_open_attempted = true;
            if (!output.open(output_id)) {
                audio_failed = true;
                (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                break;
            }
            input_open_attempted = true;
            if (!input.open(input_id)) {
                audio_failed = true;
                (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                break;
            }
            // WinMM 打开设备可能耗时；在开始处理任何音频缓冲前重新检查会话期限。
            update = session.tick(elapsed_ms());
            if (update.state.phase == wirex::hri_session::Phase::stopped ||
                !dispatch_commands(update) ||
                session.snapshot().phase == wirex::hri_session::Phase::stopped) {
                break;
            }
            audio_started = true;
            // 直接输出UTF-8字节，避免窄/宽标准流混用时依赖宽字符区域设置转换。
            std::cout << u8"音频路由已打开，进入本次 HRI 监听窗口。\n" << std::flush;
            if (!write_runtime_report(true)) {
                (void)session.abort(wirex::hri_session::StopReason::report_failure);
                break;
            }
        }

        if (audio_started) {
            HANDLE events[] = {input.event(), output.event()};
            const DWORD waited = WaitForMultipleObjects(2, events, FALSE, 20);
            if (waited == WAIT_FAILED) {
                audio_failed = true;
                (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                break;
            }
            output.reap();
            for (auto& buffer : input.buffers()) {
                if ((buffer.header.dwFlags & WHDR_DONE) == 0) continue;
                const auto recorded = buffer.header.dwBytesRecorded;
                if (recorded > buffer.header.dwBufferLength || recorded % sizeof(std::int16_t) != 0) {
                    audio_failed = true;
                    (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                    break;
                }
                captured_bytes += recorded;
                if (recorded != 0) {
                    const auto sample_count = static_cast<std::size_t>(recorded / sizeof(std::int16_t));
                    const auto block_stats = wirex::pcm_gain::measure(buffer.samples.data(), sample_count);
                    wirex::pcm_gain::accumulate(captured_stats, block_stats);
                    if (!output.has_capacity()) {
                        ++dropped_blocks;
                    } else {
                        std::copy_n(buffer.samples.begin(), sample_count, routed_samples.begin());
                        const auto gain_result = wirex::pcm_gain::apply(routed_samples.data(), sample_count, gain_milli);
                        if (!gain_result.valid) {
                            audio_failed = true;
                            (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                            break;
                        }
                        const auto submitted = output.submit(routed_samples.data(), recorded);
                        if (submitted == WaveOutput::SubmitResult::queued) {
                            submitted_bytes += recorded;
                            clipped_samples += gain_result.clipped_samples;
                            wirex::pcm_gain::accumulate(routed_input_stats, gain_result.before);
                            wirex::pcm_gain::accumulate(submitted_stats, gain_result.after);
                        } else if (submitted == WaveOutput::SubmitResult::full) {
                            ++dropped_blocks;
                        } else {
                            audio_failed = true;
                            (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                            break;
                        }
                    }
                }
                buffer.header.dwBytesRecorded = 0;
                if (input.requeue(buffer) != MMSYSERR_NOERROR) {
                    audio_failed = true;
                    (void)session.abort(wirex::hri_session::StopReason::audio_failure);
                    break;
                }
            }
            if (audio_failed) break;
        } else {
            Sleep(10);
        }
        if (!write_runtime_report(false)) {
            (void)session.abort(wirex::hri_session::StopReason::report_failure);
            break;
        }
    }

    if (control_scope.cancel_requested() && session.snapshot().phase != wirex::hri_session::Phase::stopped) {
        (void)session.cancel();
    }
    const auto final_state = session.snapshot();
    const bool input_cleanup_ok = input.close();
    const bool output_cleanup_ok = output.close();
    const HANDLE serial_handle = port.release();
    const bool serial_close_ok = serial_handle != nullptr && serial_handle != INVALID_HANDLE_VALUE &&
        CloseHandle(serial_handle) != FALSE;
    const bool cancelled = final_state.stop_reason == wirex::hri_session::StopReason::cancelled;
    const bool ended_by_deadline = final_state.stop_reason == wirex::hri_session::StopReason::deadline;
    const bool limited_exchange = final_state.limited_exchange_observed;
    const bool cleanup_ok = input_cleanup_ok && output_cleanup_ok && serial_close_ok;
    const bool report_failed_run = report_write_failed || io_failed || audio_failed || !cleanup_ok ||
        !ended_by_deadline || !limited_exchange;
    const bool close_wait_timed_out = control_scope.close_wait_timed_out();
    bool final_report_write_failed = false;
    if (report_enabled && !close_wait_timed_out) {
        const char* run_status = report_failed_run ? (cancelled ? "cancelled" : "failed") : "completed";
        std::string failure_reason;
        if (report_write_failed) {
            failure_reason = "metadata_write_failure";
            if (!report_failure_detail.empty()) failure_reason += ":" + report_failure_detail;
        }
        else if (io_failed) failure_reason = io_failure_detail.empty() ? "serial_or_control_failure" : io_failure_detail;
        else if (audio_failed) failure_reason = "audio_failure";
        else if (!cleanup_ok) failure_reason = "pc_cleanup_failure";
        else if (cancelled) failure_reason = "cancelled_before_deadline";
        else if (!limited_exchange) failure_reason = "limited_exchange_not_observed";
        refresh_report_fields("stopped", true, run_status, failure_reason, true, input_cleanup_ok,
            true, output_cleanup_ok, serial_close_ok ? "succeeded" : "failed");
        if (!report_writer.write(final_state, report_runtime, report_error)) {
            report_write_failed = true;
            final_report_write_failed = true;
        }
    }

    const bool cleanup_signal_ok = control_scope.signal_cleanup_complete();
    const DWORD cleanup_signal_error = cleanup_signal_ok ? ERROR_SUCCESS : GetLastError();
    const bool handler_unregister_ok = control_scope.unregister_now();
    const DWORD handler_unregister_error = handler_unregister_ok ? ERROR_SUCCESS : GetLastError();
    if (!cleanup_signal_ok) io_failed = true;
    if (!handler_unregister_ok) io_failed = true;

    if (report_enabled && !close_wait_timed_out && (!cleanup_signal_ok || !handler_unregister_ok)) {
        std::string lifecycle_failure_reason;
        if (!cleanup_signal_ok) lifecycle_failure_reason = "console_cleanup_signal_failed";
        if (!handler_unregister_ok) {
            if (!lifecycle_failure_reason.empty()) lifecycle_failure_reason += ";";
            lifecycle_failure_reason += "console_handler_unregister_failed";
        }
        if (!report_runtime.failure_reason.empty()) {
            lifecycle_failure_reason += ";prior_failure=" + report_runtime.failure_reason;
        }
        report_write_failed = report_write_failed || final_report_write_failed;
        refresh_report_fields("stopped", true, "failed", lifecycle_failure_reason,
            true, input_cleanup_ok, true, output_cleanup_ok, serial_close_ok ? "succeeded" : "failed");
        std::string lifecycle_report_error;
        if (!report_writer.write(final_state, report_runtime, lifecycle_report_error)) {
            report_write_failed = true;
            final_report_write_failed = true;
            report_runtime.report_write_failed = true;
            report_error = lifecycle_report_error;
        } else {
            final_report_write_failed = false;
        }
    }

    if (!cleanup_signal_ok) {
        std::wcerr << L"Could not signal main-thread cleanup completion: " << win_error(cleanup_signal_error) << L"\n";
    }
    if (!handler_unregister_ok) {
        std::wcerr << L"Could not unregister the console control handler: " << win_error(handler_unregister_error) << L"\n";
    }
    if (final_report_write_failed) {
        std::cerr << "Could not write final HRI status report: " << report_error << ".\n" << std::flush;
    }
    if (!io_failure_detail.empty()) std::cerr << "Serial transport stopped: " << io_failure_detail << ".\n";
    std::wcout << L"HRI state stopped: " << hri_stop_reason_name(final_state.stop_reason)
               << L"; V query writes=" << final_state.counters.version_query_write_requested << L"/"
               << final_state.counters.version_query_write_completed
               << L", V/48 FTX-1 validated=" << (final_state.version_response_validated ? L"yes" : L"no")
               << L", Y/100 writes=" << final_state.counters.y_write_requested << L"/"
               << final_state.counters.y_write_completed
               << L", valid Y/0 records=" << final_state.counters.y_zero_ack_received
               << L", X/100 received=" << final_state.counters.x100_received
               << L", unsupported_config_import records (not applied)=" << final_state.counters.unsupported_config_import_records
               << L", X non-config local-template-copy branches=" << final_state.counters.x_copy_branch_count
               << L", local next-Y offset-12 changes=" << final_state.counters.y_byte12_changed_count
               << L", X/0 writes=" << final_state.counters.x0_write_requested << L"/"
               << final_state.counters.x0_write_completed << L", other valid records="
               << final_state.counters.other_valid_records << L", malformed records="
               << final_state.counters.malformed_records << L", valid records="
               << final_state.counters.valid_records << L", RX bytes=" << final_state.counters.receive_bytes
               << L", TX requested bytes=" << final_state.counters.transmit_bytes_requested
               << L", completed writes=" << final_state.counters.write_calls_completed << L".\n";
    std::cout << "Audio route started after valid Y/0=" << (audio_started ? "yes" : "no")
              << "; captured bytes=" << captured_bytes << ", submitted bytes=" << submitted_bytes
              << ", dropped blocks=" << dropped_blocks << ".\n"
              << "HRI observation is not a full initialization, codec or RF test; a valid Y/0 does not confirm human audibility.\n";
    std::cout << std::fixed << std::setprecision(1)
              << "Captured input: samples=" << captured_stats.sample_count
              << ", RMS=" << wirex::pcm_gain::rms_dbfs(captured_stats) << " dBFS, peak="
              << wirex::pcm_gain::peak_dbfs(captured_stats) << " dBFS.\n"
              << "Submitted pre-gain: samples=" << routed_input_stats.sample_count
              << ", RMS=" << wirex::pcm_gain::rms_dbfs(routed_input_stats) << " dBFS, peak="
              << wirex::pcm_gain::peak_dbfs(routed_input_stats) << " dBFS.\n"
              << "Submitted post-gain: samples=" << submitted_stats.sample_count
              << ", RMS=" << wirex::pcm_gain::rms_dbfs(submitted_stats) << " dBFS, peak="
              << wirex::pcm_gain::peak_dbfs(submitted_stats) << " dBFS, saturated samples=" << clipped_samples << ".\n";
    if (!input_cleanup_ok || !output_cleanup_ok) {
        std::cout << "At least one WinMM reset/close operation failed; inspect cleanup diagnostics.\n";
    }
    std::cout << "serial_close_success=" << (serial_close_ok ? "yes" : "no") << ".\n";
    if (!serial_close_ok) std::wcerr << L"CloseHandle failed for the serial port.\n";
    if (final_state.limited_exchange_observed) {
        std::cout << "Limited V/Y exchange observed; complete HRI initialization remains unconfirmed.\n";
    }
    return close_wait_timed_out || io_failed || audio_failed || !input_cleanup_ok || !output_cleanup_ok || !serial_close_ok ||
        report_write_failed || !final_state.limited_exchange_observed ? 2 : 0;
}

const char* downlink_phase_name(wirex::hri_downlink_session::Phase phase) noexcept
{
    using wirex::hri_downlink_session::Phase;
    switch (phase) {
    case Phase::idle: return "waiting_for_first_y0";
    case Phase::start_write_pending:
    case Phase::start_write_in_progress: return "start_write";
    case Phase::awaiting_start_record: return "awaiting_start_t_record";
    case Phase::pcm_ready: return "pcm_ready";
    case Phase::pcm_active: return "pcm_active";
    case Phase::pcm_stop_pending: return "pcm_stopping";
    case Phase::stop_write_pending:
    case Phase::stop_write_in_progress: return "stop_write";
    case Phase::awaiting_stop_record: return "awaiting_stop_t_record";
    case Phase::cleanup_pending: return "cleanup";
    case Phase::finished: return "finished";
    }
    return "unknown";
}

const char* downlink_status_name(wirex::hri_downlink_session::Status status) noexcept
{
    using wirex::hri_downlink_session::Status;
    switch (status) {
    case Status::running: return "running";
    case Status::completed: return "completed";
    case Status::cancelled: return "cancelled";
    case Status::failed: return "failed";
    }
    return "failed";
}

const char* downlink_stop_reason_name(wirex::hri_downlink_session::StopReason reason) noexcept
{
    using wirex::hri_downlink_session::StopReason;
    switch (reason) {
    case StopReason::none: return "none";
    case StopReason::cancelled_before_start_attempt: return "cancelled_before_start_attempt";
    case StopReason::cancelled: return "cancelled";
    case StopReason::invalid_candidate_frame: return "invalid_candidate_frame";
    case StopReason::invalid_configuration: return "invalid_configuration";
    case StopReason::invalid_pcm_window: return "invalid_pcm_window";
    case StopReason::start_write_failed: return "start_write_failed";
    case StopReason::start_record_timeout: return "start_record_timeout";
    case StopReason::pcm_failed: return "pcm_failed";
    case StopReason::pcm_window_expired: return "pcm_window_expired";
    case StopReason::stop_write_failed: return "stop_write_failed";
    case StopReason::stop_record_timeout: return "stop_record_timeout";
    case StopReason::overall_timeout: return "overall_timeout";
    case StopReason::transport_failed: return "transport_failed";
    case StopReason::pc_cleanup_failed: return "pc_cleanup_failed";
    }
    return "unknown";
}

bool resolve_candidate_output(UINT& output_id)
{
    const std::wstring expected_name = L"扬声器 (2- USB Audio Device)";
    std::vector<UINT> matches;
    const auto device_count = waveOutGetNumDevs();
    for (UINT index = 0; index < device_count; ++index) {
        WAVEOUTCAPSW caps{};
        if (waveOutGetDevCapsW(index, &caps, sizeof(caps)) != MMSYSERR_NOERROR) continue;
        const auto name = device_name(caps.szPname, MAXPNAMELEN);
        if (name == expected_name && name.find(L"USB") != std::wstring::npos) matches.push_back(index);
    }
    if (matches.size() != 1) {
        std::wcerr << L"下行候选要求当前设备列表中恰有一个名称完全匹配的 USB WaveOut；拒绝默认设备或含糊匹配。\n";
        return false;
    }
    auto format = pcm_format();
    if (waveOutOpen(nullptr, matches[0], &format, 0, 0, WAVE_FORMAT_QUERY) != MMSYSERR_NOERROR) {
        std::wcerr << L"唯一匹配的 USB WaveOut 不接受 48 kHz、单声道、16 位 PCM。\n";
        return false;
    }
    output_id = matches[0];
    return true;
}

bool resolve_candidate_output(UINT& output_id, std::wstring_view expected_endpoint_id)
{
    if (expected_endpoint_id.empty()) {
        std::wcerr << L"BM bridge 需要本次 WinMM 枚举返回的 WaveOut endpoint ID。\n";
        return false;
    }
    std::vector<UINT> matches;
    const auto device_count = waveOutGetNumDevs();
    for (UINT index = 0U; index < device_count; ++index) {
        if (wave_endpoint_matches(false, index, expected_endpoint_id)) matches.push_back(index);
    }
    if (matches.size() != 1U) {
        std::wcerr << L"指定的 WaveOut endpoint ID 未在当前 WinMM 列表中唯一出现。\n";
        return false;
    }
    const auto format = pcm_format();
    if (waveOutOpen(nullptr, matches[0], &format, 0U, 0U, WAVE_FORMAT_QUERY) != MMSYSERR_NOERROR) {
        std::wcerr << L"所选 WaveOut endpoint 已不支持 48 kHz、单声道、16 位 PCM。\n";
        return false;
    }
    output_id = matches[0];
    return true;
}

int hri_downlink_candidate(const std::wstring& port_name,
                           const std::filesystem::path& body_path,
                           const std::filesystem::path& wav_path,
                           const std::filesystem::path& report_path)
{
    using Clock = std::chrono::steady_clock;
    using DownlinkSession = wirex::hri_downlink_session::Session;
    using DownlinkAction = wirex::hri_downlink_session::Action;
    using DownlinkActionKind = wirex::hri_downlink_session::ActionKind;
    using DownlinkPhase = wirex::hri_downlink_session::Phase;
    constexpr std::uint64_t overall_window_ms = wirex::hri_downlink_session::max_flow_duration_ms;
    constexpr std::size_t max_wav_data_bytes = 8U * 48000U * 2U;

    if (!report_path.is_absolute()) {
        std::wcerr << L"报告文件路径必须是绝对路径。\n";
        return 2;
    }

    wirex::ConsoleHandlerScope control_scope;
    if (!control_scope.start()) {
        std::wcerr << L"无法注册控制台取消处理器：" << win_error(GetLastError()) << L"\n";
        return 2;
    }

    WinHandle port;
    WaveOutput output;
    bool output_open_attempted = false;
    bool output_cleanup_known = false;
    bool output_cleanup_ok = true;
    bool report_write_failed = false;
    bool report_created = false;
    wirex::session_report::Writer report_writer;
    wirex::session_report::RuntimeFields report_runtime{};
    report_runtime.audio_input_cleanup = "not_used";
    report_runtime.audio_output_cleanup = "not_started";
    report_runtime.serial_cleanup = "not_opened";
    report_runtime.downlink.enabled = true;
    wirex::hri_session::Snapshot hri_state{};
    wirex::hri_downlink_session::Snapshot downlink_state{};
    bool native_start_write_attempted = false;
    bool native_start_write_completed = false;
    bool native_stop_write_attempted = false;
    bool native_stop_write_completed = false;
    std::string downlink_report_operation_override;
    std::string downlink_report_failure_override;
    std::string report_error;

    if (!wirex::session_report::Writer::create(report_path, report_writer, report_error)) {
        std::cerr << "无法创建候选测试报告：" << report_error << ".\n";
        (void)control_scope.signal_cleanup_complete();
        (void)control_scope.unregister_now();
        return 2;
    }
    report_created = true;
    report_runtime.phase = "hri_downlink_candidate";
    report_runtime.downlink.phase = "waiting_for_first_y0";
    if (!report_writer.write(hri_state, report_runtime, report_error)) {
        std::cerr << "无法写入候选测试初始报告：" << report_error << ".\n";
        report_write_failed = true;
    }

    auto update_downlink_report = [&](bool session_started) {
        auto& fields = report_runtime.downlink;
        fields.phase = session_started ? downlink_phase_name(downlink_state.phase) : "waiting_for_first_y0";
        fields.operation_result = session_started ? downlink_status_name(downlink_state.status) : "not_started";
        fields.failure_reason = !downlink_report_failure_override.empty() ? downlink_report_failure_override :
            (session_started ? downlink_stop_reason_name(downlink_state.stop_reason) : "none");
        fields.start_t_write_attempts = native_start_write_attempted ? 1U : 0U;
        fields.start_t_write_completions = native_start_write_completed ? 1U : 0U;
        fields.start_matching_t_records = downlink_state.start_matching_t_record_observed ? 1U : 0U;
        fields.start_matching_t_payload_observed = downlink_state.start_matching_t_record_observed;
        fields.start_matching_t_payload_bytes = downlink_state.start_matching_t_payload_bytes;
        fields.stop_t_write_attempts = native_stop_write_attempted ? 1U : 0U;
        fields.stop_t_write_completions = native_stop_write_completed ? 1U : 0U;
        fields.stop_matching_t_records = downlink_state.stop_matching_t_record_observed ? 1U : 0U;
        fields.stop_matching_t_payload_observed = downlink_state.stop_matching_t_record_observed;
        fields.stop_matching_t_payload_bytes = downlink_state.stop_matching_t_payload_bytes;
        fields.pcm_submitted_bytes = report_runtime.submitted_bytes;
        fields.pcm_drained = downlink_state.pcm_succeeded;
        if (!downlink_report_operation_override.empty()) fields.operation_result = downlink_report_operation_override;
    };

    auto finish_preflight = [&](const char* phase, const std::string& reason) {
        output_cleanup_ok = output.close();
        output_cleanup_known = output_open_attempted;
        const HANDLE raw_port = port.release();
        const bool serial_close_ok = raw_port == INVALID_HANDLE_VALUE || raw_port == nullptr || CloseHandle(raw_port) != FALSE;
        const bool early_cleanup_ok = output_cleanup_ok && serial_close_ok;
        report_runtime.final = true;
        report_runtime.status = control_scope.cancel_requested() && early_cleanup_ok ? "cancelled" : "failed";
        report_runtime.phase = phase;
        report_runtime.failure_reason = reason;
        if (!early_cleanup_ok) report_runtime.failure_reason += ";pc_cleanup_failure";
        report_runtime.audio_output_cleanup = !output_cleanup_known ? "not_started" :
            (output_cleanup_ok ? "succeeded" : "failed");
        report_runtime.serial_cleanup = raw_port == INVALID_HANDLE_VALUE || raw_port == nullptr ? "not_opened" :
            (serial_close_ok ? "succeeded" : "failed");
        report_runtime.report_write_failed = report_write_failed;
        if (report_created) {
            update_downlink_report(false);
            if (!report_writer.write(hri_state, report_runtime, report_error)) report_write_failed = true;
        }
        const bool signal_ok = control_scope.signal_cleanup_complete();
        const DWORD signal_error = signal_ok ? ERROR_SUCCESS : GetLastError();
        const bool unregister_ok = control_scope.unregister_now();
        const DWORD unregister_error = unregister_ok ? ERROR_SUCCESS : GetLastError();
        if ((!signal_ok || !unregister_ok) && report_created) {
            report_runtime.status = "failed";
            report_runtime.failure_reason = !signal_ok ? "console_cleanup_signal_failed" : "console_handler_unregister_failed";
            if (!signal_ok && !unregister_ok) report_runtime.failure_reason += ";console_handler_unregister_failed";
            report_runtime.report_write_failed = report_write_failed;
            if (!report_writer.write(hri_state, report_runtime, report_error)) report_write_failed = true;
        }
        if (!signal_ok) std::wcerr << L"无法发出主线程清理完成信号：" << win_error(signal_error) << L"\n";
        if (!unregister_ok) std::wcerr << L"无法注销控制台处理器：" << win_error(unregister_error) << L"\n";
        return 2;
    };

    if (!report_created || report_write_failed) return finish_preflight("preflight_failed", "metadata_write_failure");
    if (!body_path.is_absolute() || !wav_path.is_absolute() || !report_path.is_absolute()) {
        return finish_preflight("preflight_failed", "paths_must_be_absolute");
    }
    std::vector<std::uint8_t> y_body;
    if (!load_hri_y_template(body_path, y_body)) return finish_preflight("preflight_failed", "y_template_invalid");
    std::vector<std::uint8_t> wav_bytes;
    if (!read_wav_file(wav_path.wstring(), wav_bytes)) return finish_preflight("preflight_failed", "wav_invalid");
    const auto wav = wirex::wave_file::parse(wav_bytes.data(), wav_bytes.size());
    if (!wav || wav.info.data_size > max_wav_data_bytes) {
        std::wcerr << L"下行候选只接受长度不超过 8 秒的 48 kHz 单声道 16 位 PCM WAV。\n";
        return finish_preflight("preflight_failed", "wav_format_or_duration_invalid");
    }
    UINT output_id = 0;
    if (!resolve_candidate_output(output_id)) return finish_preflight("preflight_failed", "unique_usb_waveout_not_found");

    std::wstring device_path;
    if (!parse_port(port_name, device_path)) {
        std::wcerr << L"端口名无效；请明确指定 COM 名称，例如 COM5。\n";
        return finish_preflight("preflight_failed", "port_name_invalid");
    }
    port.reset(CreateFileW(device_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!port.valid()) {
        std::wcerr << L"无法打开串口：" << win_error(GetLastError()) << L"\n";
        return finish_preflight("serial_open_failed", "serial_open_failed");
    }
    if (!configure_serial(port.get(), false)) return finish_preflight("serial_configuration_failed", "serial_configuration_failed");
    COMMTIMEOUTS serial_timeouts{};
    serial_timeouts.ReadIntervalTimeout = 5;
    serial_timeouts.ReadTotalTimeoutConstant = 10;
    serial_timeouts.WriteTotalTimeoutConstant = 100;
    if (!SetCommTimeouts(port.get(), &serial_timeouts)) {
        std::wcerr << L"无法设置有界串口超时：" << win_error(GetLastError()) << L"\n";
        return finish_preflight("serial_configuration_failed", "serial_timeout_configuration_failed");
    }
    std::uint64_t discarded_bytes = 0;
    if (!pre_drain_hri_serial(port.get(), discarded_bytes)) {
        return finish_preflight("serial_pre_drain_failed", "serial_pre_drain_failed");
    }
    if (control_scope.cancel_requested()) return finish_preflight("cancelled_before_session", "cancelled_before_session");

    using namespace wirex::hri_downlink_session;
    const auto start_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9);
    const auto stop_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(0, 1, 9);
    const auto start_frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(start_body.begin(), start_body.end())});
    const auto stop_frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(stop_body.begin(), stop_body.end())});
    if (!start_frame || !stop_frame) return finish_preflight("preflight_failed", "fixed_candidate_frame_build_failed");

    const auto pcm_duration_ms = (static_cast<std::uint64_t>(wav.info.data_size) * 1000U + 95999U) / 96000U;
    const auto pcm_window_ms = pcm_duration_ms + 1000U;
    wirex::hri_session::Session hri_session(std::move(y_body), wirex::hri_session::Config{overall_window_ms});
    std::optional<DownlinkSession> downlink_session;
    bool downlink_started = false;
    bool hri_active = false;
    bool control_failed = false;
    bool serial_transport_failed = false;
    bool downlink_write_failed = false;
    bool audio_failed = false;
    bool pcm_drained = false;
    bool cleanup_requested = false;
    bool final_report_write_failed = false;
    bool audio_route_started = false;
    std::string control_failure_reason;
    std::uint64_t receive_generation = 0;
    std::uint64_t downlink_feed_generation = 0;
    std::size_t pcm_offset = wav.info.data_offset;
    const std::size_t pcm_end = wav.info.data_offset + wav.info.data_size;
    std::deque<DownlinkAction> pending_actions;
    std::array<std::uint8_t, 2048> receive_buffer{};
    const auto session_started = Clock::now();
    auto elapsed_ms = [&]() -> std::uint64_t {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - session_started).count();
        return elapsed < 0 ? 0U : static_cast<std::uint64_t>(elapsed);
    };
    if (!SetCommTimeouts(port.get(), &serial_timeouts)) {
        return finish_preflight("serial_configuration_failed", "active_serial_timeout_configuration_failed");
    }
    hri_state = hri_session.snapshot();

    auto refresh_report = [&](bool final, std::string_view status, std::string_view failure_reason,
                              std::string_view phase, bool serial_cleanup_known, bool serial_cleanup_ok) {
        report_runtime.final = final;
        report_runtime.status.assign(status);
        report_runtime.phase.assign(phase);
        report_runtime.failure_reason.assign(failure_reason);
        report_runtime.audio_started = audio_route_started;
        report_runtime.elapsed_ms = elapsed_ms();
        report_runtime.submitted_bytes = report_runtime.downlink.pcm_submitted_bytes;
        report_runtime.report_write_failed = report_write_failed;
        report_runtime.audio_output_cleanup = !output_open_attempted ? "not_started" :
            (output_cleanup_known ? (output_cleanup_ok ? "succeeded" : "failed") : "pending");
        report_runtime.serial_cleanup = port.valid() ? "pending" :
            (serial_cleanup_known ? (serial_cleanup_ok ? "succeeded" : "failed") : "not_opened");
        update_downlink_report(downlink_started);
    };

    auto note_control_failure = [&](std::string reason) {
        if (!control_failed) control_failure_reason = std::move(reason);
        control_failed = true;
    };

    auto close_candidate_output = [&]() {
        if (!output_open_attempted || output_cleanup_known) return;
        output_cleanup_ok = output.close();
        output_cleanup_known = true;
        if (!output_cleanup_ok) note_control_failure("waveout_cleanup_failed");
    };

    auto queue_downlink_update = [&](wirex::hri_downlink_session::Update update) {
        const bool event_rejected = update.error != wirex::hri_downlink_session::EventError::none;
        downlink_state = update.state;
        for (auto& action : update.actions) pending_actions.push_back(std::move(action));
        if (!event_rejected) return;

        note_control_failure("downlink_state_event_rejected");
        if (downlink_started && downlink_session && downlink_state.start_write_attempted &&
            !serial_transport_failed && port.valid() && downlink_state.phase != DownlinkPhase::cleanup_pending &&
            downlink_state.phase != DownlinkPhase::finished) {
            const auto recovery = downlink_session->cancel(elapsed_ms());
            if (recovery.error == wirex::hri_downlink_session::EventError::none) {
                downlink_state = recovery.state;
                for (const auto& action : recovery.actions) pending_actions.push_back(action);
                return;
            }
        }
        cleanup_requested = true;
    };

    auto urgent_stop_pending = [&]() {
        if (!downlink_started) return false;
        const auto phase = downlink_state.phase;
        return phase == DownlinkPhase::stop_write_pending || phase == DownlinkPhase::stop_write_in_progress ||
            phase == DownlinkPhase::awaiting_stop_record || phase == DownlinkPhase::cleanup_pending ||
            phase == DownlinkPhase::finished;
    };

    auto cancel_downlink = [&]() {
        if (!downlink_started || !downlink_session || downlink_state.phase == DownlinkPhase::cleanup_pending ||
            downlink_state.phase == DownlinkPhase::finished) return;
        queue_downlink_update(downlink_session->cancel(elapsed_ms()));
    };

    auto dispatch_hri_commands = [&](const wirex::hri_session::Update& update) {
        for (const auto& command : update.commands) {
            if (!hri_active || control_scope.cancel_requested() || urgent_stop_pending()) break;
            if (!port.valid()) {
                serial_transport_failed = true;
                note_control_failure("serial_handle_unavailable");
                break;
            }
            DWORD actual = 0;
            const BOOL wrote = WriteFile(port.get(), command.frame.data(),
                static_cast<DWORD>(command.frame.size()), &actual, nullptr);
            const DWORD write_error = wrote == FALSE ? GetLastError() : ERROR_SUCCESS;
            const bool full_write = wrote != FALSE && actual == command.frame.size();
            const auto completion = hri_session.write_completed(command.id, full_write, elapsed_ms());
            hri_state = completion.state;
            if (!full_write) {
                note_control_failure(wrote == FALSE ? "hri_control_write_failed" : "hri_control_short_write");
                hri_active = false;
                if (!port.valid() || write_error == ERROR_INVALID_HANDLE) {
                    serial_transport_failed = true;
                    note_control_failure("serial_handle_unavailable");
                    if (downlink_started && downlink_session) {
                        queue_downlink_update(downlink_session->transport_failed(elapsed_ms()));
                    } else {
                        cleanup_requested = true;
                    }
                }
                break;
            }
            if (completion.state.phase == wirex::hri_session::Phase::stopped) {
                note_control_failure(to_utf8(hri_stop_reason_name(completion.state.stop_reason)));
                hri_active = false;
                break;
            }
        }
    };

    auto consume_hri_update = [&](const wirex::hri_session::Update& update) {
        hri_state = update.state;
        hri_active = update.state.phase != wirex::hri_session::Phase::stopped;
        if (!hri_active) {
            const auto reason = update.state.stop_reason;
            if (reason != wirex::hri_session::StopReason::caller_stopped) {
                note_control_failure(to_utf8(hri_stop_reason_name(reason)));
            }
        }
        dispatch_hri_commands(update);
        if (!hri_active && downlink_started && hri_state.stop_reason != wirex::hri_session::StopReason::deadline) {
            cancel_downlink();
        }
        if (hri_state.y_zero_acknowledged && !downlink_started && hri_active && !control_failed) {
            const auto now = elapsed_ms();
            if (now >= overall_window_ms) {
                note_control_failure("overall_window_expired_before_downlink_start");
                cleanup_requested = true;
                return;
            }
            Config config{};
            config.overall_timeout_ms = overall_window_ms - now;
            downlink_session.emplace(start_frame.bytes, stop_frame.bytes, config);
            downlink_started = true;
            queue_downlink_update(downlink_session->start(now, pcm_window_ms));
        }
    };

    auto service_actions = [&]() {
        while (!pending_actions.empty() && !cleanup_requested) {
            auto action = std::move(pending_actions.front());
            pending_actions.pop_front();
            if (action.kind == DownlinkActionKind::write_start_candidate && control_scope.cancel_requested()) {
                cancel_downlink();
                continue;
            }
            switch (action.kind) {
            case DownlinkActionKind::write_start_candidate:
            case DownlinkActionKind::write_stop_candidate: {
                if (!port.valid()) {
                    serial_transport_failed = true;
                    note_control_failure("serial_handle_unavailable");
                    queue_downlink_update(downlink_session->transport_failed(elapsed_ms()));
                    break;
                }
                const auto attempted = downlink_session->write_attempted(action.write_id, elapsed_ms());
                if (attempted.error != wirex::hri_downlink_session::EventError::none) {
                    note_control_failure("candidate_write_attempt_rejected");
                    cleanup_requested = true;
                    break;
                }
                downlink_state = attempted.state;
                if (action.kind == DownlinkActionKind::write_start_candidate) native_start_write_attempted = true;
                else native_stop_write_attempted = true;
                DWORD actual = 0;
                const BOOL wrote = WriteFile(port.get(), action.frame.data(),
                    static_cast<DWORD>(action.frame.size()), &actual, nullptr);
                const DWORD write_error = wrote == FALSE ? GetLastError() : ERROR_SUCCESS;
                const bool full_write = wrote != FALSE && actual == action.frame.size();
                if (action.kind == DownlinkActionKind::write_start_candidate) native_start_write_completed = full_write;
                else native_stop_write_completed = full_write;
                downlink_feed_generation = receive_generation;
                if (!full_write) {
                    downlink_write_failed = true;
                    note_control_failure(wrote == FALSE ? "candidate_t_write_failed" : "candidate_t_short_write");
                }
                if (!port.valid() || write_error == ERROR_INVALID_HANDLE) {
                    serial_transport_failed = true;
                    note_control_failure("serial_handle_unavailable");
                    queue_downlink_update(downlink_session->transport_failed(elapsed_ms()));
                }
                queue_downlink_update(downlink_session->write_completed(action.write_id, full_write, elapsed_ms()));
                if (action.kind == DownlinkActionKind::write_stop_candidate) close_candidate_output();
                break;
            }
            case DownlinkActionKind::allow_pcm:
                output_open_attempted = true;
                if (!output.open(output_id)) {
                    audio_failed = true;
                    note_control_failure("waveout_open_failed");
                    queue_downlink_update(downlink_session->pcm_completed(false, elapsed_ms()));
                    break;
                }
                audio_route_started = true;
                queue_downlink_update(downlink_session->pcm_started(elapsed_ms()));
                break;
            case DownlinkActionKind::request_pcm_stop:
                pcm_drained = false;
                queue_downlink_update(downlink_session->pcm_completed(false, elapsed_ms()));
                break;
            case DownlinkActionKind::cleanup_required:
                cleanup_requested = true;
                break;
            }
        }
    };

    auto request_transport_failure = [&]() {
        serial_transport_failed = true;
        note_control_failure("serial_transport_failure");
        if (hri_active) {
            hri_state = hri_session.abort(wirex::hri_session::StopReason::transport_failure).state;
            hri_active = false;
        }
        if (downlink_started && downlink_session) {
            queue_downlink_update(downlink_session->transport_failed(elapsed_ms()));
        } else {
            cleanup_requested = true;
        }
    };

    consume_hri_update(hri_session.start(0));
    service_actions();

    std::string last_report_phase;
    std::uint64_t next_report_ms = 0;
    while (!cleanup_requested) {
        if (control_scope.cancel_requested()) {
            note_control_failure("cancelled_by_user");
            if (hri_active) {
                hri_state = hri_session.cancel().state;
                hri_active = false;
            }
            cancel_downlink();
        }

        if (downlink_started && downlink_session && !cleanup_requested) {
            queue_downlink_update(downlink_session->tick(elapsed_ms()));
            service_actions();
        }
        if (cleanup_requested) break;

        if (hri_active) {
            consume_hri_update(hri_session.tick(elapsed_ms()));
            service_actions();
        }
        if (cleanup_requested) break;

        if (!port.valid()) {
            request_transport_failure();
            service_actions();
            break;
        }
        DWORD comm_errors = 0;
        COMSTAT comm_state{};
        if (!ClearCommError(port.get(), &comm_errors, &comm_state)) {
            request_transport_failure();
            service_actions();
            break;
        }
        if (comm_errors != 0) {
            note_control_failure("serial_line_or_receive_error");
            if (hri_active) {
                hri_state = hri_session.cancel().state;
                hri_active = false;
            }
            cancel_downlink();
            service_actions();
        }
        if (comm_state.cbInQue != 0) {
            const DWORD requested = std::min<DWORD>(comm_state.cbInQue, static_cast<DWORD>(receive_buffer.size()));
            DWORD actual = 0;
            if (!ReadFile(port.get(), receive_buffer.data(), requested, &actual, nullptr) || actual > requested) {
                request_transport_failure();
                service_actions();
                break;
            }
            if (actual != 0) {
                ++receive_generation;
                if (hri_active) consume_hri_update(hri_session.feed(receive_buffer.data(), actual, elapsed_ms()));
                if (downlink_started && downlink_session && receive_generation > downlink_feed_generation &&
                    downlink_state.phase != DownlinkPhase::cleanup_pending && downlink_state.phase != DownlinkPhase::finished) {
                    queue_downlink_update(downlink_session->feed(receive_buffer.data(), actual, elapsed_ms()));
                }
                service_actions();
            }
        }
        if (cleanup_requested) break;

        if (downlink_started && downlink_session && downlink_state.phase == DownlinkPhase::pcm_active && !audio_failed) {
            if (control_scope.cancel_requested()) {
                cancel_downlink();
                service_actions();
            } else if (pcm_offset < pcm_end && output.has_capacity()) {
                const auto chunk_size = std::min<std::size_t>(WaveInput::sample_count * sizeof(std::int16_t), pcm_end - pcm_offset);
                const auto submitted = output.submit(wav_bytes.data() + pcm_offset, static_cast<DWORD>(chunk_size));
                if (submitted == WaveOutput::SubmitResult::queued) {
                    pcm_offset += chunk_size;
                    report_runtime.submitted_bytes += chunk_size;
                    report_runtime.downlink.pcm_submitted_bytes = report_runtime.submitted_bytes;
                } else if (submitted != WaveOutput::SubmitResult::full) {
                    audio_failed = true;
                    note_control_failure("waveout_submit_failed");
                    queue_downlink_update(downlink_session->pcm_completed(false, elapsed_ms()));
                    service_actions();
                }
            } else if (pcm_offset == pcm_end && output.all_drained()) {
                pcm_drained = true;
                queue_downlink_update(downlink_session->pcm_completed(true, elapsed_ms()));
                service_actions();
            }
        }
        if (cleanup_requested) break;

        const auto current_phase = std::string(downlink_started ? downlink_phase_name(downlink_state.phase) : "waiting_for_first_y0") + "/" +
            hri_phase_name(hri_state.phase);
        if (!report_write_failed && (current_phase != last_report_phase || elapsed_ms() >= next_report_ms)) {
            refresh_report(false, "running", "", "hri_downlink_candidate", false, false);
            if (!report_writer.write(hri_state, report_runtime, report_error)) {
                report_write_failed = true;
                note_control_failure("metadata_write_failure");
                if (hri_active) {
                    hri_state = hri_session.cancel().state;
                    hri_active = false;
                }
                cancel_downlink();
            } else {
                last_report_phase = current_phase;
                next_report_ms = elapsed_ms() + 1000U;
            }
        }

        if (!hri_active && !downlink_started) cleanup_requested = true;
        if (!cleanup_requested) Sleep(10);
    }

    if (hri_active) {
        hri_state = hri_session.finish(elapsed_ms()).state;
        hri_active = false;
        if (hri_state.stop_reason != wirex::hri_session::StopReason::caller_stopped) {
            note_control_failure(to_utf8(hri_stop_reason_name(hri_state.stop_reason)));
        }
    }
    if (downlink_started && native_start_write_attempted && !native_stop_write_attempted &&
        port.valid() && !serial_transport_failed) {
        native_stop_write_attempted = true;
        DWORD actual = 0;
        const BOOL wrote = WriteFile(port.get(), stop_frame.bytes.data(),
            static_cast<DWORD>(stop_frame.bytes.size()), &actual, nullptr);
        const DWORD write_error = wrote == FALSE ? GetLastError() : ERROR_SUCCESS;
        native_stop_write_completed = wrote != FALSE && actual == stop_frame.bytes.size();
        downlink_write_failed = downlink_write_failed || wrote == FALSE || actual != stop_frame.bytes.size();
        downlink_report_operation_override = "failed";
        downlink_report_failure_override = "native_cleanup_stop_attempt_after_state_error";
        if (!port.valid() || write_error == ERROR_INVALID_HANDLE) {
            serial_transport_failed = true;
            note_control_failure("serial_handle_unavailable_during_final_stop_attempt");
        }
    }
    output_cleanup_ok = output.close();
    output_cleanup_known = output_open_attempted;
    const HANDLE raw_port = port.release();
    const bool serial_close_ok = raw_port != nullptr && raw_port != INVALID_HANDLE_VALUE && CloseHandle(raw_port) != FALSE;
    if (!output_cleanup_ok) note_control_failure("waveout_cleanup_failed");
    if (!serial_close_ok) note_control_failure("serial_cleanup_failed");
    if (downlink_started && downlink_session && downlink_state.phase == DownlinkPhase::cleanup_pending) {
        queue_downlink_update(downlink_session->cleanup_completed(output_cleanup_ok,
            serial_close_ok, elapsed_ms()));
        downlink_state = downlink_session->snapshot();
    }

    if (downlink_started && native_start_write_attempted &&
        !downlink_state.stop_matching_t_record_observed &&
        (downlink_state.status == wirex::hri_downlink_session::Status::cancelled ||
         downlink_state.status == wirex::hri_downlink_session::Status::running)) {
        downlink_report_operation_override = "failed";
        if (downlink_report_failure_override.empty()) {
            downlink_report_failure_override = "stop_matching_t_record_not_observed";
        }
    }

    const bool control_cancelled = control_scope.cancel_requested();
    const bool candidate_complete = downlink_started && downlink_state.final &&
        downlink_state.status == wirex::hri_downlink_session::Status::completed &&
        downlink_state.start_matching_t_record_observed && downlink_state.stop_matching_t_record_observed &&
        downlink_state.pcm_succeeded && pcm_drained;
    bool run_failed = control_failed || report_write_failed || downlink_write_failed || audio_failed ||
        serial_transport_failed || !output_cleanup_ok || !serial_close_ok || !candidate_complete;
    std::string final_failure = control_failure_reason;
    if (report_write_failed) final_failure = "metadata_write_failure";
    else if (serial_transport_failed) final_failure = "serial_transport_failure";
    else if (downlink_started && downlink_state.stop_reason != wirex::hri_downlink_session::StopReason::none &&
        downlink_state.status == wirex::hri_downlink_session::Status::failed) {
        final_failure = downlink_stop_reason_name(downlink_state.stop_reason);
    } else if (audio_failed) final_failure = "pcm_submission_or_output_failed";
    else if (!output_cleanup_ok || !serial_close_ok) final_failure = "pc_cleanup_failure";
    else if (control_cancelled && !final_failure.empty()) final_failure = "cancelled_by_user;" + final_failure;
    else if (!candidate_complete && final_failure.empty()) final_failure = "candidate_flow_incomplete";
    const bool cancellation_only = control_cancelled && control_failure_reason == "cancelled_by_user" &&
        !report_write_failed && !serial_transport_failed && !downlink_write_failed && !audio_failed &&
        output_cleanup_ok && serial_close_ok &&
        (!downlink_started || (downlink_state.status == wirex::hri_downlink_session::Status::cancelled &&
            (!downlink_state.start_write_attempted || downlink_state.stop_matching_t_record_observed)));
    const char* final_status = !run_failed && candidate_complete ? "completed" :
        (cancellation_only ? "cancelled" : "failed");
    refresh_report(true, final_status, final_failure, "stopped", true, serial_close_ok);
    if (!report_writer.write(hri_state, report_runtime, report_error)) {
        report_write_failed = true;
        final_report_write_failed = true;
        report_runtime.report_write_failed = true;
    }

    const bool cleanup_signal_ok = control_scope.signal_cleanup_complete();
    const DWORD cleanup_signal_error = cleanup_signal_ok ? ERROR_SUCCESS : GetLastError();
    const bool handler_unregister_ok = control_scope.unregister_now();
    const DWORD handler_unregister_error = handler_unregister_ok ? ERROR_SUCCESS : GetLastError();
    if (!cleanup_signal_ok || !handler_unregister_ok) {
        run_failed = true;
        std::string lifecycle_failure;
        if (!cleanup_signal_ok) lifecycle_failure = "console_cleanup_signal_failed";
        if (!handler_unregister_ok) {
            if (!lifecycle_failure.empty()) lifecycle_failure += ";";
            lifecycle_failure += "console_handler_unregister_failed";
        }
        if (!final_failure.empty()) lifecycle_failure += ";prior_failure=" + final_failure;
        refresh_report(true, "failed", lifecycle_failure, "stopped", true, serial_close_ok);
        if (!report_writer.write(hri_state, report_runtime, report_error)) final_report_write_failed = true;
    }
    if (!cleanup_signal_ok) std::wcerr << L"无法发出主线程清理完成信号：" << win_error(cleanup_signal_error) << L"\n";
    if (!handler_unregister_ok) std::wcerr << L"无法注销控制台处理器：" << win_error(handler_unregister_error) << L"\n";
    if (final_report_write_failed) std::cerr << "无法写入最终候选测试报告：" << report_error << ".\n";
    if (candidate_complete && !run_failed) {
        std::cout << "候选软件流程和本机PCM队列清理完成；这不证明无线电已恢复或人耳已听到音频。\n";
        return 0;
    }
    std::cout << "候选流程未完整完成；报告保留实际写入、T记录长度、PCM排空和本机清理结果，radio_state仍为unknown。\n";
    return 2;
}

int hri_radio_session(const std::wstring& port_name,
                      const std::filesystem::path& body_path,
                      const std::filesystem::path& fixed_wav_path,
                      UINT radio_input_id,
                      UINT pc_output_id,
                      UINT microphone_input_id,
                      const std::filesystem::path& report_path,
                      bool interactive)
{
    using Clock = std::chrono::steady_clock;
    using DownlinkSession = wirex::hri_downlink_session::Session;
    using DownlinkAction = wirex::hri_downlink_session::Action;
    using DownlinkActionKind = wirex::hri_downlink_session::ActionKind;
    using DownlinkPhase = wirex::hri_downlink_session::Phase;
    using HriPhase = wirex::hri_session::Phase;
    constexpr std::size_t max_pcm_bytes = 8U * 48000U * sizeof(std::int16_t);
    constexpr std::uint64_t microphone_capture_ms = 8000;
    constexpr std::uint64_t microphone_capture_grace_ms = 300;
    wirex::session_timing::StopBudget stop_budget(wirex::session_timing::cleanup_grace_ms);

    wirex::bounded_pipe_writer::Writer protocol_writer(GetStdHandle(STD_OUTPUT_HANDLE));
    const bool protocol_writer_ready = interactive || protocol_writer.enable_nonblocking();
    wirex::session_report::Writer report_writer;
    wirex::session_report::RuntimeFields report_runtime{};
    report_runtime.radio_session.enabled = true;
    report_runtime.downlink.enabled = true;
    report_runtime.audio_input_cleanup = "not_started";
    report_runtime.audio_output_cleanup = "not_started";
    report_runtime.serial_cleanup = "not_opened";
    wirex::hri_session::Snapshot hri_state{};
    std::string report_error;
    bool report_write_failed = false;
    bool protocol_output_failed = false;
    bool cleanup_deadline_forced = false;
    std::uint64_t event_seq = 0;
    std::string interactive_last_phase{"starting"};
    auto emit_unbound_failure = [interactive, protocol_writer_ready, &protocol_writer](std::string_view reason) {
        if (interactive) {
            std::cerr << "启动失败：" << reason << "\n" << std::flush;
        } else if (!protocol_writer_ready) {
            std::cerr << "协议模式无法将stdout设置为有界非阻塞管道写入；未打开硬件。\n" << std::flush;
        } else {
            std::ostringstream line;
            line << "{\"protocol_version\":1,\"type\":\"session_result\",\"run_id\":null,"
                    "\"seq\":1,\"request_id\":null,\"status\":\"failed\","
                    "\"phase\":\"startup_failed\",\"failure_reason\":" << json_escape(reason) << '}';
            (void)protocol_writer.write_line(line.str());
        }
        return 2;
    };
    if (!protocol_writer_ready) return emit_unbound_failure("stdout_nonblocking_pipe_required");
    if (!report_path.is_absolute()) return emit_unbound_failure("report_path_must_be_absolute");
    if (!wirex::session_report::Writer::create(report_path, report_writer, report_error)) {
        std::cerr << "无法创建本机受控会话报告。\n";
        return emit_unbound_failure("report_init_failed");
    }
    auto emit_event = [&](std::string_view type, std::string_view status,
                          std::string_view phase, std::string_view request_id,
                          std::string_view extra = {}, std::string_view failure_reason = {}) {
        ++event_seq;
        report_runtime.radio_session.seq = event_seq;
        wirex::session_report::apply_radio_event(report_runtime, type, status, phase);
        if (!report_writer.write(hri_state, report_runtime, report_error)) {
            report_write_failed = true;
            report_runtime.report_write_failed = true;
        }
        if (interactive) {
            if (type == "snapshot" && phase == "listening" && interactive_last_phase != "listening") {
                std::cerr << u8"HRI监听已就绪。F：发送固定语句；M：录入最多8秒后发送；C：取消当前操作；Q：停止并退出。\n"
                             u8"本次运行窗口最长120秒；到期后仅进行最多3秒的本机停止收尾，不会自动重启。\n" << std::flush;
            } else if (type == "operation_event" && phase == "capturing") {
                std::cerr << u8"开始麦克风录入；最多8秒，录入结束后才开始下行。\n" << std::flush;
            } else if (type == "operation_event" && phase == "waiting_start_t") {
                std::cerr << u8"已接受下行操作，正在等待有效的T类型记录。\n" << std::flush;
            } else if (type == "operation_event" && phase == "pcm_active") {
                std::cerr << u8"收到窗口内有效T类型记录，正在提交PCM；这不代表电台或RF确认。\n" << std::flush;
            } else if (type == "operation_result") {
                std::cerr << "Operation " << status << " (" << phase << ")";
                if (!failure_reason.empty()) std::cerr << ": " << failure_reason;
                std::cerr << "\n" << std::flush;
            } else if (type == "session_result") {
                std::cerr << "Session " << status << " (" << phase << ")";
                if (!failure_reason.empty()) std::cerr << ": " << failure_reason;
                std::cerr << "\n" << std::flush;
            }
            interactive_last_phase.assign(phase);
        } else {
            std::ostringstream line;
            line << "{\"protocol_version\":1,\"type\":" << json_escape(type)
                 << ",\"run_id\":" << json_escape(report_writer.run_id())
                 << ",\"seq\":" << event_seq << ",\"request_id\":";
            if (request_id.empty()) line << "null";
            else line << json_escape(request_id);
            line << ",\"status\":" << json_escape(status)
                 << ",\"phase\":" << json_escape(phase)
                 << ",\"radio_state\":\"unknown\",\"radio_state_unknown\":true";
            if (!extra.empty()) line << ',' << extra;
            line << '}';
            if (!protocol_writer.write_line(line.str())) {
                protocol_output_failed = true;
            }
        }
    };

    // 先创建本轮报告并发送首个快照；串口与 WinMM 设备此时都尚未打开。
    emit_event("snapshot", "running", "starting", {},
        "\"components\":{\"serial\":\"not_opened\",\"hri\":\"not_started\","
        "\"radio_audio_input\":\"not_started\",\"pc_audio_output\":\"not_started\","
        "\"radio_audio_output\":\"not_started\",\"microphone_capture\":\"idle\"}");
    if (protocol_output_failed) {
        report_runtime.final = true;
        report_runtime.status = "failed";
        report_runtime.phase = "startup_failed";
        report_runtime.failure_reason = "protocol_stdout_write_failed";
        report_runtime.elapsed_ms = 0;
        if (!report_writer.write(hri_state, report_runtime, report_error)) report_write_failed = true;
        std::cerr << "协议stdout写入失败；未打开硬件。\n" << std::flush;
        return 2;
    }
    if (report_write_failed) {
        report_runtime.final = true;
        report_runtime.status = "failed";
        report_runtime.phase = "startup_failed";
        report_runtime.failure_reason = "report_write_failed";
        report_runtime.report_write_failed = true;
        report_runtime.elapsed_ms = 0;
        (void)report_writer.write(hri_state, report_runtime, report_error);
        emit_event("session_result", "failed", "startup_failed", {},
            "\"failure_reason\":\"report_write_failed\"", "report_write_failed");
        std::cerr << "初始会话报告写入失败；未打开硬件。\n" << std::flush;
        return 2;
    }

    WinHandle port;
    WaveInput radio_input;
    WaveInput microphone_input;
    WaveOutput pc_output;
    WaveOutput radio_output;
    wirex::ConsoleHandlerScope control_scope;
    bool handler_started = false;
    bool session_started = false;
    bool serial_opened_once = false;
    bool session_ending = false;
    bool hri_active = false;
    bool hri_ready = false;
    bool serial_transport_failed = false;
    bool audio_failed = false;
    bool control_failed = false;
    bool radio_input_open = false;
    bool microphone_open = false;
    bool pc_output_open = false;
    bool pc_output_started = false;
    bool radio_output_open = false;
    bool radio_output_started = false;
    bool radio_input_started = false;
    bool microphone_input_started = false;
    wirex::audio_input_cleanup::State radio_input_cleanup_state;
    wirex::audio_input_cleanup::State microphone_input_cleanup_state;
    wirex::operation_audio_cleanup::State radio_output_cleanup_state;
    bool cleanup_ok = true;
    bool natural_deadline = false;
    bool parent_pipe_closed = false;
    bool console_cancelled = false;
    bool shutdown_requested = false;
    bool session_final_report_failed = false;
    std::string final_failure_reason;
    std::string radio_input_name;
    std::string microphone_input_name;
    std::string pc_output_name;
    std::string radio_output_name;
    auto clock_origin = Clock::now();
    auto elapsed_ms = [&]() -> std::uint64_t {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - clock_origin).count();
        return elapsed < 0 ? 0U : static_cast<std::uint64_t>(elapsed);
    };
    auto set_failure = [&](std::string reason) {
        if (!control_failed) final_failure_reason = std::move(reason);
        control_failed = true;
    };
    auto close_radio_input = [&]() {
        if (!radio_input_open) {
            if (!radio_input_cleanup_state.close_failed()) return true;
            audio_failed = true;
            set_failure("radio_input_cleanup_failed");
            session_ending = true;
            return false;
        }
        const bool closed = radio_input.close();
        radio_input_open = radio_input.is_open();
        radio_input_cleanup_state.record_close_result(closed);
        const bool cleanup_succeeded = closed && !radio_input_cleanup_state.close_failed();
        if (!cleanup_succeeded) {
            audio_failed = true;
            set_failure("radio_input_cleanup_failed");
            session_ending = true;
        }
        return cleanup_succeeded;
    };
    auto close_microphone_input = [&]() {
        if (!microphone_open) {
            if (!microphone_input_cleanup_state.close_failed()) return true;
            audio_failed = true;
            set_failure("microphone_cleanup_failed");
            session_ending = true;
            return false;
        }
        const bool closed = microphone_input.close();
        microphone_open = microphone_input.is_open();
        microphone_input_cleanup_state.record_close_result(closed);
        const bool cleanup_succeeded = closed && !microphone_input_cleanup_state.close_failed();
        if (!cleanup_succeeded) {
            audio_failed = true;
            set_failure("microphone_cleanup_failed");
            session_ending = true;
        }
        return cleanup_succeeded;
    };
    auto close_radio_output = [&]() {
        if (!radio_output_open && !radio_output.is_open()) {
            return !radio_output_cleanup_state.close_failed() && !radio_output.close_failed();
        }
        const bool closed = radio_output.close();
        radio_output_open = radio_output.is_open();
        radio_output_cleanup_state.record_close_result(closed);
        const bool cleanup_succeeded = closed && !radio_output_cleanup_state.close_failed() &&
            !radio_output.close_failed();
        if (!cleanup_succeeded) {
            audio_failed = true;
            set_failure("radio_waveout_cleanup_failed");
            session_ending = true;
        }
        return cleanup_succeeded;
    };
    auto close_pc_output = [&]() {
        if (!pc_output_open && !pc_output.is_open()) return !pc_output.close_failed();
        const bool closed = pc_output.close();
        pc_output_open = pc_output.is_open();
        const bool cleanup_succeeded = closed && !pc_output.close_failed();
        if (!cleanup_succeeded) {
            audio_failed = true;
            set_failure("pc_audio_output_cleanup_failed");
            session_ending = true;
        }
        return cleanup_succeeded;
    };
    auto component_json = [&]() {
        const auto hri_component = hri_active ? "active" : (hri_state.phase == HriPhase::stopped ? "stopped" : "not_started");
        const auto input_component = radio_input_cleanup_state.close_failed() ? "failed" :
            (radio_input_open ? "open" : (hri_ready ? "paused" : "not_started"));
        const auto mic_component = microphone_input_cleanup_state.close_failed() ? "failed" : (microphone_open ? "capturing" :
            (report_runtime.radio_session.microphone_capture == "complete" ? "complete" : "idle"));
        std::string json = "\"components\":{";
        json += "\"serial\":" + json_escape(port.valid() ? "open" : (serial_opened_once ? "closed" : "not_opened"));
        json += ",\"hri\":" + json_escape(hri_component);
        json += ",\"radio_audio_input\":" + json_escape(input_component);
        json += ",\"pc_audio_output\":" + json_escape(pc_output.close_failed() ? "failed" :
            (pc_output_open ? "open" : (pc_output_started ? "closed" : "not_started")));
        json += ",\"radio_audio_output\":" + json_escape(radio_output.close_failed() || radio_output_cleanup_state.close_failed() ? "failed" :
            (radio_output_open ? "open" : (radio_output_started ? "closed" : "not_started")));
        json += ",\"microphone_capture\":" + json_escape(mic_component);
        json += ",\"radio_input_name\":" + json_escape(radio_input_name);
        json += ",\"microphone_input_name\":" + json_escape(microphone_input_name);
        json += ",\"pc_output_name\":" + json_escape(pc_output_name);
        json += ",\"radio_output_name\":" + json_escape(radio_output_name) + "}";
        return json;
    };
    auto finalize_early_failure = [&](std::string_view phase, std::string_view reason) {
        set_failure(std::string(reason));
        const bool input_cleanup_started = radio_input_open || microphone_open || radio_input_started ||
            microphone_input_started || radio_input_cleanup_state.close_failed() || microphone_input_cleanup_state.close_failed();
        bool input_cleanup_ok = true;
        if (radio_input_open) input_cleanup_ok = close_radio_input() && input_cleanup_ok;
        if (microphone_open) input_cleanup_ok = close_microphone_input() && input_cleanup_ok;
        input_cleanup_ok = !radio_input_cleanup_state.close_failed() && !microphone_input_cleanup_state.close_failed() && input_cleanup_ok;
        const bool output_cleanup_started = pc_output_open || pc_output_started || pc_output.close_failed() ||
            radio_output_open || radio_output.is_open() || radio_output_started || radio_output.close_failed() ||
            radio_output_cleanup_state.close_failed();
        bool output_cleanup_ok = true;
        if (pc_output_open || pc_output.is_open() || pc_output.close_failed()) output_cleanup_ok = close_pc_output() && output_cleanup_ok;
        if (radio_output_open || radio_output.is_open() || radio_output_cleanup_state.close_failed() || radio_output.close_failed()) {
            output_cleanup_ok = close_radio_output() && output_cleanup_ok;
        }
        const bool serial_cleanup_started = port.valid();
        bool serial_cleanup_ok = true;
        if (serial_cleanup_started) {
            const HANDLE raw = port.release();
            serial_cleanup_ok = raw != nullptr && raw != INVALID_HANDLE_VALUE && CloseHandle(raw) != FALSE;
        }
        cleanup_ok = input_cleanup_ok && output_cleanup_ok && serial_cleanup_ok;
        report_runtime.final = true;
        report_runtime.status = "failed";
        report_runtime.failure_reason.assign(reason);
        report_runtime.audio_input_cleanup = !input_cleanup_started ? "not_started" :
            (input_cleanup_ok ? "succeeded" : "failed");
        report_runtime.audio_output_cleanup = !output_cleanup_started ? "not_started" :
            (output_cleanup_ok ? "succeeded" : "failed");
        report_runtime.serial_cleanup = !serial_cleanup_started ? "not_opened" :
            (serial_cleanup_ok ? "succeeded" : "failed");
        report_runtime.downlink.operation_audio_cleanup.assign(radio_output_cleanup_state.status(false));
        report_runtime.report_write_failed = report_write_failed;
        report_runtime.elapsed_ms = elapsed_ms();
        if (!report_writer.write(hri_state, report_runtime, report_error)) report_write_failed = true;
        emit_event("session_result", "failed", phase, {},
            "\"failure_reason\":" + json_escape(reason) + "," + component_json(), reason);
        if (handler_started) {
            (void)control_scope.signal_cleanup_complete();
            (void)control_scope.unregister_now();
        }
        return 2;
    };

    if (!body_path.is_absolute() || !fixed_wav_path.is_absolute()) {
        return finalize_early_failure("preflight_failed", "input_paths_must_be_absolute");
    }
    std::vector<std::uint8_t> y_body;
    if (!load_hri_y_template(body_path, y_body)) return finalize_early_failure("preflight_failed", "y_template_invalid");
    std::vector<std::uint8_t> wav_bytes;
    if (!read_wav_file(fixed_wav_path.wstring(), wav_bytes)) return finalize_early_failure("preflight_failed", "fixed_wav_invalid");
    const auto fixed_wav = wirex::wave_file::parse(wav_bytes.data(), wav_bytes.size());
    if (!fixed_wav || fixed_wav.info.data_size == 0 || fixed_wav.info.data_size > max_pcm_bytes) {
        return finalize_early_failure("preflight_failed", "fixed_wav_format_or_duration_invalid");
    }
    if (radio_input_id >= waveInGetNumDevs() || microphone_input_id >= waveInGetNumDevs() ||
        pc_output_id >= waveOutGetNumDevs() || radio_input_id == microphone_input_id) {
        return finalize_early_failure("preflight_failed", "audio_device_ids_invalid_or_conflicting");
    }
    UINT radio_output_id = 0;
    if (!resolve_candidate_output(radio_output_id) || radio_output_id == pc_output_id) {
        return finalize_early_failure("preflight_failed", "radio_waveout_missing_ambiguous_or_conflicting");
    }
    auto format = pcm_format();
    if (waveInOpen(nullptr, radio_input_id, &format, 0, 0, WAVE_FORMAT_QUERY) != MMSYSERR_NOERROR ||
        waveInOpen(nullptr, microphone_input_id, &format, 0, 0, WAVE_FORMAT_QUERY) != MMSYSERR_NOERROR ||
        waveOutOpen(nullptr, pc_output_id, &format, 0, 0, WAVE_FORMAT_QUERY) != MMSYSERR_NOERROR) {
        return finalize_early_failure("preflight_failed", "selected_audio_format_unsupported");
    }
    WAVEINCAPSW radio_input_caps{};
    WAVEINCAPSW microphone_caps{};
    WAVEOUTCAPSW pc_output_caps{};
    WAVEOUTCAPSW radio_output_caps{};
    if (waveInGetDevCapsW(radio_input_id, &radio_input_caps, sizeof(radio_input_caps)) != MMSYSERR_NOERROR ||
        waveInGetDevCapsW(microphone_input_id, &microphone_caps, sizeof(microphone_caps)) != MMSYSERR_NOERROR ||
        waveOutGetDevCapsW(pc_output_id, &pc_output_caps, sizeof(pc_output_caps)) != MMSYSERR_NOERROR ||
        waveOutGetDevCapsW(radio_output_id, &radio_output_caps, sizeof(radio_output_caps)) != MMSYSERR_NOERROR) {
        return finalize_early_failure("preflight_failed", "selected_audio_device_query_failed");
    }
    radio_input_name = to_utf8(device_name(radio_input_caps.szPname, MAXPNAMELEN));
    microphone_input_name = to_utf8(device_name(microphone_caps.szPname, MAXPNAMELEN));
    pc_output_name = to_utf8(device_name(pc_output_caps.szPname, MAXPNAMELEN));
    radio_output_name = to_utf8(device_name(radio_output_caps.szPname, MAXPNAMELEN));

    emit_event("snapshot", "running", "preflight", {}, component_json());
    if (protocol_output_failed) return finalize_early_failure("preflight_failed", "protocol_stdout_write_failed");
    if (interactive) {
        std::cerr << u8"当前设备：无线电输入=" << radio_input_id << " " << radio_input_name
                  << u8"；电脑扬声器=" << pc_output_id << " " << pc_output_name
                  << u8"；麦克风输入=" << microphone_input_id << " " << microphone_input_name
                  << u8"；下行USB输出=" << radio_output_id << " " << radio_output_name << "\n"
                  << u8"正在初始化HRI。只有监听就绪后才会接受F/M按键。\n" << std::flush;
    }

    const HANDLE stdin_handle = GetStdHandle(STD_INPUT_HANDLE);
    DWORD console_mode = 0;
    if (stdin_handle == nullptr || stdin_handle == INVALID_HANDLE_VALUE ||
        (interactive ? !GetConsoleMode(stdin_handle, &console_mode) : GetFileType(stdin_handle) != FILE_TYPE_PIPE)) {
        return finalize_early_failure("preflight_failed", interactive ? "interactive_console_required" : "stdin_control_pipe_required");
    }
    std::wstring device_path;
    if (!parse_port(port_name, device_path)) return finalize_early_failure("preflight_failed", "port_name_invalid");
    if (!control_scope.start()) return finalize_early_failure("preflight_failed", "console_handler_registration_failed");
    handler_started = true;

    port.reset(CreateFileW(device_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!port.valid()) return finalize_early_failure("serial_open_failed", "serial_open_failed");
    serial_opened_once = true;
    if (!configure_serial(port.get(), false)) return finalize_early_failure("serial_configuration_failed", "serial_configuration_failed");
    COMMTIMEOUTS timeouts{};
    timeouts.ReadIntervalTimeout = 5;
    timeouts.ReadTotalTimeoutConstant = 10;
    timeouts.WriteTotalTimeoutConstant = 100;
    if (!SetCommTimeouts(port.get(), &timeouts)) return finalize_early_failure("serial_configuration_failed", "serial_timeout_configuration_failed");
    std::uint64_t discarded_bytes = 0;
    if (!pre_drain_hri_serial(port.get(), discarded_bytes)) return finalize_early_failure("serial_pre_drain_failed", "serial_pre_drain_failed");

    wirex::hri_session::Session hri_session(std::move(y_body), wirex::hri_session::Config{
        wirex::session_timing::active_window_ms});
    using namespace wirex::hri_downlink_session;
    const auto start_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9);
    const auto stop_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(0, 1, 9);
    const auto start_frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(start_body.begin(), start_body.end())});
    const auto stop_frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(stop_body.begin(), stop_body.end())});
    if (!start_frame || !stop_frame) return finalize_early_failure("preflight_failed", "candidate_frame_build_failed");

    struct ActiveOperation {
        bool active{false};
        bool capture{false};
        bool capturing{false};
        bool pcm_cancelled{false};
        std::string request_id;
        std::string cancel_request_id;
        std::vector<std::uint8_t> pcm;
        std::size_t pcm_offset{};
        std::uint64_t capture_started_ms{};
        std::uint64_t capture_deadline_ms{};
        std::uint64_t pcm_window_ms{};
        std::string failure_reason;
    } operation;
    auto wipe_operation_pcm = [&]() {
        secure_wipe(operation.pcm.data(), operation.pcm.size());
        operation.pcm.clear();
        operation.pcm.shrink_to_fit();
        operation.pcm_offset = 0;
    };
    std::optional<DownlinkSession> downlink;
    wirex::hri_downlink_session::Snapshot downlink_state{};
    std::deque<DownlinkAction> pending_actions;
    bool start_write_attempted = false;
    bool start_write_completed = false;
    bool stop_write_attempted = false;
    bool stop_write_completed = false;
    bool pcm_drained = false;
    std::uint64_t receive_generation = 0;
    std::uint64_t downlink_feed_generation = 0;
    std::uint64_t downlink_operation_count = 0;
    std::uint64_t captured_bytes = 0;
    std::uint64_t monitor_submitted_bytes = 0;
    std::uint64_t pcm_submitted_bytes = 0;
    std::uint64_t dropped_blocks = 0;
    std::uint64_t clipped_samples = 0;
    std::array<std::int16_t, WaveInput::sample_count> routed_samples{};
    std::array<std::uint8_t, 2048> serial_buffer{};
    std::string command_buffer;
    bool discard_long_line = false;
    bool command_eof = false;
    wirex::hri_radio_protocol::Parser command_parser(report_writer.run_id());
    std::uint64_t next_snapshot_ms = 1000;
    std::string last_request_id;
    std::string accepted_shutdown_id;
    std::string shutdown_reason;
    std::uint64_t interactive_request_count = 0;
    auto current_phase = [&]() -> std::string {
        if (session_ending) return "stopping";
        if (operation.active && operation.capturing) return "capturing";
        if (operation.active && downlink) return "downlink";
        if (hri_ready) return "listening";
        return "initializing_hri";
    };
    auto sync_downlink_report = [&]() {
        auto& fields = report_runtime.downlink;
        fields.phase = downlink ? downlink_phase_name(downlink_state.phase) : (cleanup_deadline_forced ? "finished" : "not_started");
        fields.operation_result = downlink ? downlink_status_name(downlink_state.status) : (cleanup_deadline_forced ? "failed" : "not_started");
        fields.failure_reason = downlink ? downlink_stop_reason_name(downlink_state.stop_reason) :
            (cleanup_deadline_forced ? "session_cleanup_deadline_exceeded" : "none");
        fields.start_t_write_attempts = start_write_attempted ? 1U : 0U;
        fields.start_t_write_completions = start_write_completed ? 1U : 0U;
        fields.start_matching_t_records = downlink_state.start_matching_t_record_observed ? 1U : 0U;
        fields.start_matching_t_payload_observed = downlink_state.start_matching_t_record_observed;
        fields.start_matching_t_payload_bytes = downlink_state.start_matching_t_payload_bytes;
        fields.stop_t_write_attempts = stop_write_attempted ? 1U : 0U;
        fields.stop_t_write_completions = stop_write_completed ? 1U : 0U;
        fields.stop_matching_t_records = downlink_state.stop_matching_t_record_observed ? 1U : 0U;
        fields.stop_matching_t_payload_observed = downlink_state.stop_matching_t_record_observed;
        fields.stop_matching_t_payload_bytes = downlink_state.stop_matching_t_payload_bytes;
        fields.pcm_submitted_bytes = pcm_submitted_bytes;
        fields.pcm_drained = pcm_drained;
        fields.operation_audio_cleanup.assign(radio_output_cleanup_state.status(radio_output_open));
    };
    auto set_report_components = [&]() {
        report_runtime.radio_session.active_request_id = operation.active ? operation.request_id : "";
        report_runtime.radio_session.last_request_id = last_request_id;
        report_runtime.radio_session.operation_count = downlink_operation_count;
        report_runtime.radio_session.radio_audio_input = radio_input_cleanup_state.close_failed() ? "failed" :
            (radio_input_open ? "open" : (hri_ready ? "paused" : "not_started"));
        report_runtime.radio_session.pc_audio_output = pc_output.close_failed() ? "failed" :
            (pc_output_open ? "open" : (pc_output_started ? "closed" : "not_started"));
        report_runtime.radio_session.microphone_capture = microphone_input_cleanup_state.close_failed() ? "failed" : (microphone_open ? "capturing" :
            (report_runtime.radio_session.microphone_capture == "complete" ? "complete" : "idle"));
        report_runtime.radio_session.microphone_capture_bytes = captured_bytes;
        report_runtime.elapsed_ms = elapsed_ms();
        report_runtime.captured_bytes = captured_bytes;
        report_runtime.submitted_bytes = monitor_submitted_bytes + pcm_submitted_bytes;
        report_runtime.dropped_blocks = dropped_blocks;
        report_runtime.clipped_samples = clipped_samples;
        sync_downlink_report();
    };
    // 包装report写入；事件流与磁盘报告共享同一个native run_id与seq。
    auto publish = [&](std::string_view type, std::string_view status,
                       std::string_view phase, std::string_view request_id,
                       std::string_view extra = {}, std::string_view failure_reason = {}) {
        ++event_seq;
        report_runtime.radio_session.seq = event_seq;
        wirex::session_report::apply_radio_event(report_runtime, type, status, phase);
        set_report_components();
        if (!report_runtime.final && !report_writer.write(hri_state, report_runtime, report_error)) {
            report_write_failed = true;
            report_runtime.report_write_failed = true;
        }
        if (interactive) {
            if (type == "snapshot" && phase == "listening" && interactive_last_phase != "listening") {
                std::cerr << u8"HRI监听已就绪。F：发送固定语句；M：录入最多8秒后发送；C：取消当前操作；Q：停止并退出。\n"
                             u8"本次运行窗口最长120秒；到期后仅进行最多3秒的本机停止收尾，不会自动重启。\n" << std::flush;
            } else if (type == "operation_event" && phase == "capturing") {
                std::cerr << u8"开始麦克风录入；最多8秒，录入结束后才开始下行。\n" << std::flush;
            } else if (type == "operation_event" && phase == "waiting_start_t") {
                std::cerr << u8"已接受下行操作，正在等待有效的T类型记录。\n" << std::flush;
            } else if (type == "operation_event" && phase == "pcm_active") {
                std::cerr << u8"收到窗口内有效T类型记录，正在提交PCM；这不代表电台或RF确认。\n" << std::flush;
            } else if (type == "operation_result") {
                std::cerr << "Operation " << status << " (" << phase << ")";
                if (!failure_reason.empty()) std::cerr << ": " << failure_reason;
                std::cerr << "\n" << std::flush;
            } else if (type == "session_result") {
                std::cerr << "Session " << status << " (" << phase << ")";
                if (!failure_reason.empty()) std::cerr << ": " << failure_reason;
                std::cerr << "\n" << std::flush;
            }
            interactive_last_phase.assign(phase);
        } else {
            std::ostringstream line;
            line << "{\"protocol_version\":1,\"type\":" << json_escape(type)
                 << ",\"run_id\":" << json_escape(report_writer.run_id())
                 << ",\"seq\":" << event_seq << ",\"request_id\":";
            if (request_id.empty()) line << "null";
            else line << json_escape(request_id);
            line << ",\"status\":" << json_escape(status)
                 << ",\"phase\":" << json_escape(phase)
                 << ",\"radio_state\":\"unknown\",\"radio_state_unknown\":true";
            if (!extra.empty()) line << ',' << extra;
            line << '}';
            if (!protocol_writer.write_line(line.str())) {
                protocol_output_failed = true;
                set_failure("protocol_stdout_write_failed");
                session_ending = true;
            }
        }
    };

    clock_origin = Clock::now();
    session_started = true;
    hri_state = hri_session.snapshot();
    auto open_radio_monitor = [&]() {
        if (!hri_ready || session_ending || serial_transport_failed) return false;
        if (!radio_input_cleanup_state.reopen_allowed()) return false;
        if (!pc_output_open) {
            if (!pc_output.open(pc_output_id)) {
                pc_output_open = pc_output.is_open();
                if (pc_output_open || pc_output.close_failed()) pc_output_started = true;
                if (pc_output.close_failed()) {
                    audio_failed = true;
                    set_failure("pc_audio_output_open_cleanup_failed");
                    session_ending = true;
                }
                return false;
            }
            pc_output_open = true;
            pc_output_started = true;
        }
        if (!radio_input_open) {
            if (!radio_input.open(radio_input_id)) {
                if (radio_input.close_failed()) radio_input_cleanup_state.record_close_result(false);
                return false;
            }
            radio_input_open = true;
            radio_input_started = true;
        }
        return true;
    };
    auto close_radio_monitor = [&]() {
        if (!radio_input_open) return !radio_input_cleanup_state.close_failed();
        return close_radio_input();
    };
    auto begin_downlink = [&]() {
        if (!operation.active || operation.capturing || operation.pcm.empty() || session_ending || !port.valid()) return false;
        if (!radio_output_cleanup_state.reopen_allowed()) {
            audio_failed = true;
            set_failure("radio_waveout_cleanup_failed");
            session_ending = true;
            return false;
        }
        radio_output_cleanup_state.begin_operation();
        if (!close_radio_monitor()) {
            audio_failed = true;
            operation.failure_reason = "radio_input_cleanup_failed";
            return false;
        }
        Config config{};
        config.overall_timeout_ms = max_flow_duration_ms;
        downlink.emplace(start_frame.bytes, stop_frame.bytes, config);
        auto started = downlink->start(elapsed_ms(), operation.pcm_window_ms);
        downlink_state = started.state;
        downlink_feed_generation = receive_generation;
        start_write_attempted = false;
        start_write_completed = false;
        stop_write_attempted = false;
        stop_write_completed = false;
        pcm_drained = false;
        pcm_submitted_bytes = 0;
        report_runtime.downlink.operation_audio_cleanup = "not_started";
        ++downlink_operation_count;
        report_runtime.radio_session.microphone_capture = operation.capture ? "complete" : "idle";
        publish("operation_event", "running", "waiting_start_t", operation.request_id,
            "\"source\":" + json_escape(operation.capture ? "microphone_memory" : "fixed_wav"));
        for (auto& action : started.actions) {
            pending_actions.push_back(std::move(action));
        }
        return true;
    };

    if (!SetCommTimeouts(port.get(), &timeouts)) return finalize_early_failure("serial_configuration_failed", "active_serial_timeout_configuration_failed");
    auto finish_operation = [&](std::string_view status, std::string_view reason) {
        const std::string request_id = operation.request_id;
        const bool can_resume = !session_ending && !serial_transport_failed &&
            (!start_write_attempted || downlink_state.stop_matching_t_record_observed);
        operation.active = false;
        operation.capturing = false;
        secure_wipe(operation.pcm.data(), operation.pcm.size());
        wipe_operation_pcm();
        report_runtime.downlink.operation_audio_cleanup.assign(radio_output_cleanup_state.status(radio_output_open));
        downlink.reset();
        pending_actions.clear();
        publish("operation_result", status, "operation_finished", request_id,
            std::string("\"failure_reason\":") + json_escape(reason) + "," + component_json(), reason);
        if (!operation.cancel_request_id.empty()) {
            publish("operation_result", status == "cancelled" ? "completed" :
                (status == "completed" ? "completed" : "failed"), "cancel_request_finished",
                operation.cancel_request_id, std::string("\"failure_reason\":") + json_escape(reason));
        }
        last_request_id = request_id;
        secure_wipe(operation.pcm.data(), operation.pcm.size());
        operation = {};
        if (can_resume && hri_active && hri_ready) {
            if (!open_radio_monitor()) {
                audio_failed = true;
                set_failure("radio_monitor_reopen_failed");
                session_ending = true;
            } else {
                publish("snapshot", "running", "listening", {}, component_json());
            }
        } else if (!session_ending && start_write_attempted && !downlink_state.stop_matching_t_record_observed) {
            set_failure("stop_matching_t_not_observed_radio_state_unknown");
            session_ending = true;
        }
    };

    auto update_downlink = [&](wirex::hri_downlink_session::Update update) {
        if (update.error != wirex::hri_downlink_session::EventError::none) {
            set_failure("downlink_state_event_rejected");
            if (downlink && downlink_state.start_write_attempted && !serial_transport_failed && port.valid() &&
                !stop_write_attempted && downlink_state.phase != DownlinkPhase::cleanup_pending &&
                downlink_state.phase != DownlinkPhase::finished) {
                auto recovery = downlink->cancel(elapsed_ms());
                downlink_state = recovery.state;
                for (auto& action : recovery.actions) pending_actions.push_back(std::move(action));
            } else {
                session_ending = true;
            }
            return;
        }
        downlink_state = update.state;
        for (auto& action : update.actions) pending_actions.push_back(std::move(action));
    };
    auto service_downlink_actions = [&]() {
        while (!pending_actions.empty() && downlink && !serial_transport_failed) {
            auto action = std::move(pending_actions.front());
            pending_actions.pop_front();
            if (action.kind == DownlinkActionKind::write_start_candidate &&
                (control_scope.cancel_requested() || session_ending)) {
                update_downlink(downlink->cancel(elapsed_ms()));
                continue;
            }
            switch (action.kind) {
            case DownlinkActionKind::write_start_candidate:
            case DownlinkActionKind::write_stop_candidate: {
                const auto attempted = downlink->write_attempted(action.write_id, elapsed_ms());
                if (attempted.error != wirex::hri_downlink_session::EventError::none) {
                    set_failure("candidate_write_attempt_rejected");
                    session_ending = true;
                    break;
                }
                downlink_state = attempted.state;
                if (action.kind == DownlinkActionKind::write_start_candidate) start_write_attempted = true;
                else stop_write_attempted = true;
                DWORD actual = 0;
                const BOOL wrote = WriteFile(port.get(), action.frame.data(),
                    static_cast<DWORD>(action.frame.size()), &actual, nullptr);
                const DWORD write_error = wrote == FALSE ? GetLastError() : ERROR_SUCCESS;
                const bool full_write = wrote != FALSE && actual == action.frame.size();
                if (action.kind == DownlinkActionKind::write_start_candidate) start_write_completed = full_write;
                else stop_write_completed = full_write;
                downlink_feed_generation = receive_generation;
                if (!full_write) set_failure(wrote == FALSE ? "candidate_t_write_failed" : "candidate_t_short_write");
                if (!port.valid() || write_error == ERROR_INVALID_HANDLE) {
                    serial_transport_failed = true;
                    set_failure("serial_handle_unavailable");
                    update_downlink(downlink->transport_failed(elapsed_ms()));
                    break;
                }
                update_downlink(downlink->write_completed(action.write_id, full_write, elapsed_ms()));
                break;
            }
            case DownlinkActionKind::allow_pcm:
                if (!radio_output_cleanup_state.reopen_allowed()) {
                    audio_failed = true;
                    set_failure("radio_waveout_cleanup_failed");
                    session_ending = true;
                    update_downlink(downlink->pcm_completed(false, elapsed_ms()));
                } else if (!radio_output.open(radio_output_id)) {
                    radio_output_open = radio_output.is_open();
                    if (radio_output_open || radio_output.close_failed()) radio_output_started = true;
                    if (radio_output.close_failed()) {
                        radio_output_cleanup_state.record_close_result(false);
                        session_ending = true;
                    }
                    audio_failed = true;
                    set_failure("radio_waveout_open_failed");
                    update_downlink(downlink->pcm_completed(false, elapsed_ms()));
                } else {
                    radio_output_open = true;
                    radio_output_started = true;
                    update_downlink(downlink->pcm_started(elapsed_ms()));
                    publish("operation_event", "running", "pcm_active", operation.request_id,
                        "\"pcm_source\":" + json_escape(operation.capture ? "microphone_memory" : "fixed_wav"));
                }
                break;
            case DownlinkActionKind::request_pcm_stop:
                operation.pcm_cancelled = true;
                update_downlink(downlink->pcm_completed(false, elapsed_ms()));
                break;
            case DownlinkActionKind::cleanup_required:
                break;
            }
        }
    };
    auto complete_operation_cleanup = [&]() {
        if (!downlink || downlink_state.phase != DownlinkPhase::cleanup_pending) return;
        const bool output_ok = close_radio_output();
        if (!output_ok) {
            audio_failed = true;
            set_failure("radio_waveout_cleanup_failed");
            session_ending = true;
        }
        report_runtime.downlink.operation_audio_cleanup.assign(radio_output_cleanup_state.status(false));
        update_downlink(downlink->operation_cleanup_completed(output_ok, elapsed_ms()));
        downlink_state = downlink->snapshot();
        const bool operation_ok = downlink_state.status == wirex::hri_downlink_session::Status::completed &&
            downlink_state.start_write_succeeded && downlink_state.start_matching_t_record_observed &&
            downlink_state.stop_write_succeeded && downlink_state.stop_matching_t_record_observed &&
            downlink_state.pcm_succeeded && pcm_drained && output_ok;
        const bool operation_cancelled = downlink_state.status == wirex::hri_downlink_session::Status::cancelled &&
            (!start_write_attempted || downlink_state.stop_matching_t_record_observed) && output_ok;
        const auto reason = operation_ok ? "none" :
            (downlink_state.stop_reason == wirex::hri_downlink_session::StopReason::none ?
             (downlink_state.stop_matching_t_record_observed ? "pcm_or_cleanup_incomplete" : "stop_matching_t_not_observed") :
             downlink_stop_reason_name(downlink_state.stop_reason));
        finish_operation(operation_ok ? "completed" : (operation_cancelled ? "cancelled" :
            (downlink_state.stop_reason == wirex::hri_downlink_session::StopReason::start_record_timeout ||
             downlink_state.stop_reason == wirex::hri_downlink_session::StopReason::stop_record_timeout ||
             downlink_state.stop_reason == wirex::hri_downlink_session::StopReason::overall_timeout ? "timed_out" : "failed")), reason);
    };

    auto cancel_current_operation = [&](std::string_view reason) {
        if (!operation.active) return;
        operation.failure_reason.assign(reason);
        if (operation.capturing) {
            const bool mic_ok = close_microphone_input();
            report_runtime.radio_session.microphone_capture = "cancelled";
            if (!mic_ok) { audio_failed = true; set_failure("microphone_cleanup_failed"); }
            operation.capturing = false;
            wipe_operation_pcm();
            if (!session_ending && hri_active && hri_ready && !open_radio_monitor()) {
                audio_failed = true;
                set_failure("radio_monitor_reopen_failed");
                session_ending = true;
            }
            const std::string req = operation.request_id;
            publish("operation_result", "cancelled", "capture_cancelled", req,
                std::string("\"failure_reason\":") + json_escape(reason), reason);
            if (!operation.cancel_request_id.empty()) publish("operation_result", "completed", "cancel_request_finished", operation.cancel_request_id);
            last_request_id = req;
            wipe_operation_pcm();
            operation = {};
            return;
        }
        if (downlink && downlink_state.phase != DownlinkPhase::cleanup_pending && downlink_state.phase != DownlinkPhase::finished) {
            update_downlink(downlink->cancel(elapsed_ms()));
        }
    };

    auto start_capture = [&]() {
        if (!close_radio_monitor()) return false;
        if (!microphone_input_cleanup_state.reopen_allowed()) return false;
        report_runtime.radio_session.microphone_capture = "capturing";
        if (!microphone_input.open(microphone_input_id)) {
            if (microphone_input.close_failed()) microphone_input_cleanup_state.record_close_result(false);
            return false;
        }
        microphone_open = true;
        microphone_input_started = true;
        operation.capturing = true;
        operation.capture_started_ms = elapsed_ms();
        operation.capture_deadline_ms = operation.capture_started_ms + microphone_capture_ms;
        wipe_operation_pcm();
        operation.pcm.reserve(max_pcm_bytes);
        captured_bytes = 0;
        publish("operation_event", "running", "capturing", operation.request_id,
            "\"capture_limit_ms\":8000,\"capture_memory_only\":true");
        return true;
    };
    auto start_operation = [&](const wirex::hri_radio_protocol::Command& command) {
        wipe_operation_pcm();
        operation = {};
        operation.active = true;
        operation.capture = command.kind == wirex::hri_radio_protocol::CommandKind::capture_mic;
        operation.request_id = command.request_id;
        report_runtime.radio_session.active_request_id = command.request_id;
        report_runtime.radio_session.last_request_id = command.request_id;
        report_runtime.radio_session.microphone_capture = "idle";
        if (operation.capture) {
            if (!start_capture()) {
                audio_failed = true;
                operation.active = false;
                if (microphone_input_cleanup_state.close_failed()) session_ending = true;
                set_failure("microphone_capture_start_failed");
                publish("operation_result", "failed", "capture_start_failed", command.request_id,
                    "\"failure_reason\":\"microphone_capture_start_failed\"", "microphone_capture_start_failed");
                if (hri_active && hri_ready && !open_radio_monitor()) session_ending = true;
                return;
            }
        } else {
            const auto begin = fixed_wav.info.data_offset;
            const auto end = begin + fixed_wav.info.data_size;
            operation.pcm.assign(wav_bytes.begin() + static_cast<std::ptrdiff_t>(begin),
                wav_bytes.begin() + static_cast<std::ptrdiff_t>(end));
            operation.pcm_window_ms = (static_cast<std::uint64_t>(operation.pcm.size()) * 1000U + 95999U) / 96000U + 1000U;
            if (!begin_downlink()) {
                operation.active = false;
                const std::string reason = operation.failure_reason.empty() ? "downlink_start_failed" : operation.failure_reason;
                set_failure(reason);
                publish("operation_result", "failed", "operation_start_failed", command.request_id,
                    std::string("\"failure_reason\":") + json_escape(reason), reason);
                wipe_operation_pcm();
                operation = {};
                if (hri_active && hri_ready && !open_radio_monitor()) session_ending = true;
            }
        }
    };

    auto dispatch_command = [&](const wirex::hri_radio_protocol::Command& command) {
        last_request_id = command.request_id;
        if (command.kind == wirex::hri_radio_protocol::CommandKind::shutdown) {
            if (shutdown_requested) {
                publish("request_result", "busy", current_phase(), command.request_id,
                    "\"failure_reason\":\"shutdown_already_pending\"");
                return;
            }
            shutdown_requested = true;
            accepted_shutdown_id = command.request_id;
            shutdown_reason = "shutdown_requested";
            publish("request_result", "accepted", "stopping", command.request_id);
            session_ending = true;
            if (hri_active) { hri_state = hri_session.cancel().state; hri_active = false; }
            cancel_current_operation("shutdown_requested");
            return;
        }
        if (command.kind == wirex::hri_radio_protocol::CommandKind::cancel_operation) {
            if (!operation.active) {
                publish("request_result", "busy", current_phase(), command.request_id,
                    "\"failure_reason\":\"no_active_operation\"");
                return;
            }
            operation.cancel_request_id = command.request_id;
            publish("request_result", "accepted", current_phase(), command.request_id);
            cancel_current_operation("cancelled_by_request");
            return;
        }
        if (!hri_ready || !hri_active || session_ending) {
            publish("request_result", "rejected", current_phase(), command.request_id,
                "\"failure_reason\":\"session_not_listening\"");
            return;
        }
        if (operation.active) {
            publish("request_result", "busy", current_phase(), command.request_id,
                "\"failure_reason\":\"operation_in_progress\"");
            return;
        }
        publish("request_result", "accepted", current_phase(), command.request_id);
        if (protocol_output_failed) return;
        start_operation(command);
    };

    auto process_command_line = [&](std::string line) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        wirex::hri_radio_protocol::Command command{};
        const auto parse_error = command_parser.parse(line, command);
        if (parse_error != wirex::hri_radio_protocol::ParseError::none) {
            const auto request_id = command.request_id;
            publish("request_result", "rejected", current_phase(), request_id,
                std::string("\"failure_reason\":") + json_escape(wirex::hri_radio_protocol::error_name(parse_error)));
            return;
        }
        dispatch_command(command);
    };

    auto poll_commands = [&]() {
        if (interactive) {
            DWORD queued = 0;
            if (!GetNumberOfConsoleInputEvents(stdin_handle, &queued)) {
                set_failure("console_input_query_failed");
                session_ending = true;
                return;
            }
            std::array<INPUT_RECORD, 32> records{};
            while (queued != 0) {
                DWORD read = 0;
                const DWORD wanted = std::min<DWORD>(queued, static_cast<DWORD>(records.size()));
                if (!ReadConsoleInputW(stdin_handle, records.data(), wanted, &read) || read == 0 || read > wanted) {
                    set_failure("console_input_read_failed");
                    session_ending = true;
                    return;
                }
                queued -= read;
                for (DWORD index = 0; index < read; ++index) {
                    const auto& record = records[index];
                    if (record.EventType != KEY_EVENT || !record.Event.KeyEvent.bKeyDown) continue;
                    wchar_t key = record.Event.KeyEvent.uChar.UnicodeChar;
                    if (key >= L'a' && key <= L'z') key = static_cast<wchar_t>(key - L'a' + L'A');
                    wirex::hri_radio_protocol::Command command{};
                    command.run_id = report_writer.run_id();
                    command.request_id = "interactive_" + std::to_string(++interactive_request_count);
                    if (key == L'F') command.kind = wirex::hri_radio_protocol::CommandKind::send_fixed;
                    else if (key == L'M') command.kind = wirex::hri_radio_protocol::CommandKind::capture_mic;
                    else if (key == L'C') command.kind = wirex::hri_radio_protocol::CommandKind::cancel_operation;
                    else if (key == L'Q') command.kind = wirex::hri_radio_protocol::CommandKind::shutdown;
                    else continue;
                    dispatch_command(command);
                }
            }
            return;
        }
        DWORD available = 0;
        if (!PeekNamedPipe(stdin_handle, nullptr, 0, nullptr, &available, nullptr)) {
            const DWORD error = GetLastError();
            if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA) {
                command_eof = true;
                parent_pipe_closed = true;
                return;
            }
            set_failure("stdin_pipe_read_failed");
            session_ending = true;
            return;
        }
        std::array<char, 256> input{};
        while (available != 0) {
            DWORD actual = 0;
            const DWORD wanted = std::min<DWORD>(available, static_cast<DWORD>(input.size()));
            if (!ReadFile(stdin_handle, input.data(), wanted, &actual, nullptr) || actual == 0 || actual > wanted) {
                set_failure("stdin_pipe_read_failed");
                session_ending = true;
                return;
            }
            available -= actual;
            for (DWORD index = 0; index < actual; ++index) {
                const char ch = input[index];
                if (ch == '\n') {
                    if (discard_long_line) {
                        publish("request_result", "rejected", current_phase(), {}, "\"failure_reason\":\"line_too_long\"");
                        discard_long_line = false;
                        command_buffer.clear();
                    } else {
                        process_command_line(std::move(command_buffer));
                        command_buffer.clear();
                    }
                } else if (!discard_long_line) {
                    command_buffer.push_back(ch);
                    if (command_buffer.size() > wirex::hri_radio_protocol::max_command_line_bytes) {
                        discard_long_line = true;
                        command_buffer.clear();
                    }
                }
            }
        }
    };

    bool command_started = false;
    auto start_control_session = [&]() {
        if (command_started) return;
        command_started = true;
        auto initial = hri_session.start(elapsed_ms());
        hri_state = initial.state;
        hri_active = hri_state.phase != HriPhase::stopped;
        for (const auto& command : initial.commands) {
            DWORD actual = 0;
            const BOOL wrote = WriteFile(port.get(), command.frame.data(),
                static_cast<DWORD>(command.frame.size()), &actual, nullptr);
            const bool full_write = wrote != FALSE && actual == command.frame.size();
            hri_state = hri_session.write_completed(command.id, full_write, elapsed_ms()).state;
            hri_active = hri_state.phase != HriPhase::stopped;
            if (!full_write) {
                serial_transport_failed = true;
                set_failure("version_query_write_failed");
                session_ending = true;
                break;
            }
        }
    };
    start_control_session();

    auto service_actions = [&]() {
        service_downlink_actions();
        complete_operation_cleanup();
    };
    auto handle_serial_failure = [&](std::string_view reason) {
        serial_transport_failed = true;
        set_failure(std::string(reason));
        session_ending = true;
        if (hri_active) { hri_state = hri_session.abort(wirex::hri_session::StopReason::transport_failure).state; hri_active = false; }
        if (downlink && downlink_state.phase != DownlinkPhase::finished && downlink_state.phase != DownlinkPhase::cleanup_pending) {
            update_downlink(downlink->transport_failed(elapsed_ms()));
        }
    };
    auto process_radio_monitor = [&]() {
        if (!radio_input_open || !pc_output_open || operation.active) return;
        const DWORD waited = WaitForSingleObject(radio_input.event(), 0);
        if (waited == WAIT_FAILED) {
            audio_failed = true;
            set_failure("radio_input_wait_failed");
            session_ending = true;
            return;
        }
        pc_output.reap();
        for (auto& buffer : radio_input.buffers()) {
            if ((buffer.header.dwFlags & WHDR_DONE) == 0) continue;
            const DWORD bytes = buffer.header.dwBytesRecorded;
            if (bytes > buffer.header.dwBufferLength || bytes % sizeof(std::int16_t) != 0) {
                audio_failed = true;
                set_failure("radio_input_pcm_invalid");
                session_ending = true;
                return;
            }
            captured_bytes += bytes;
            if (bytes != 0) {
                if (!pc_output.has_capacity()) ++dropped_blocks;
                else {
                    const auto sample_count = static_cast<std::size_t>(bytes / sizeof(std::int16_t));
                    std::copy_n(buffer.samples.begin(), sample_count, routed_samples.begin());
                    const auto submitted = pc_output.submit(routed_samples.data(), bytes);
                    if (submitted == WaveOutput::SubmitResult::queued) monitor_submitted_bytes += bytes;
                    else if (submitted == WaveOutput::SubmitResult::full) ++dropped_blocks;
                    else { audio_failed = true; set_failure("pc_monitor_output_failed"); session_ending = true; return; }
                }
            }
            buffer.header.dwBytesRecorded = 0;
            if (radio_input.requeue(buffer) != MMSYSERR_NOERROR) {
                audio_failed = true;
                set_failure("radio_input_requeue_failed");
                session_ending = true;
                return;
            }
        }
    };

    bool protocol_failure_handled = false;
    while (!session_ending || operation.active || downlink.has_value()) {
        const auto now = elapsed_ms();
        if (protocol_output_failed && !protocol_failure_handled) {
            protocol_failure_handled = true;
            set_failure("protocol_stdout_write_failed");
            shutdown_reason = "protocol_stdout_write_failed";
            session_ending = true;
            if (hri_active) { hri_state = hri_session.cancel().state; hri_active = false; }
            cancel_current_operation("protocol_stdout_write_failed");
        }
        if (control_scope.cancel_requested() && !session_ending) {
            console_cancelled = true;
            shutdown_reason = "console_cancelled";
            session_ending = true;
            if (hri_active) { hri_state = hri_session.cancel().state; hri_active = false; }
            cancel_current_operation("console_cancelled");
        }
        if (command_eof && !session_ending) {
            shutdown_reason = "parent_pipe_eof";
            session_ending = true;
            if (hri_active) { hri_state = hri_session.cancel().state; hri_active = false; }
            cancel_current_operation("parent_pipe_eof");
        }
        if (!session_ending && wirex::session_timing::active_window_expired(now)) {
            natural_deadline = true;
            shutdown_reason = "radio_session_deadline";
            (void)stop_budget.begin_shutdown(now);
            session_ending = true;
            if (hri_active) { hri_state = hri_session.tick(now).state; hri_active = false; }
            cancel_current_operation("radio_session_deadline");
        }
        poll_commands();
        if (session_ending) (void)stop_budget.begin_shutdown(elapsed_ms());

        if (hri_active && !session_ending) {
            auto update = hri_session.tick(elapsed_ms());
            hri_state = update.state;
            hri_active = hri_state.phase != HriPhase::stopped;
            for (const auto& command : update.commands) {
                DWORD actual = 0;
                const BOOL wrote = WriteFile(port.get(), command.frame.data(),
                    static_cast<DWORD>(command.frame.size()), &actual, nullptr);
                const bool full_write = wrote != FALSE && actual == command.frame.size();
                hri_state = hri_session.write_completed(command.id, full_write, elapsed_ms()).state;
                hri_active = hri_state.phase != HriPhase::stopped;
                if (!full_write) { handle_serial_failure("hri_heartbeat_write_failed"); break; }
            }
            if (!hri_active && hri_state.stop_reason != wirex::hri_session::StopReason::caller_stopped) {
                if (hri_state.stop_reason == wirex::hri_session::StopReason::deadline) natural_deadline = true;
                else set_failure(to_utf8(hri_stop_reason_name(hri_state.stop_reason)));
                shutdown_reason = to_utf8(hri_stop_reason_name(hri_state.stop_reason));
                session_ending = true;
                cancel_current_operation(shutdown_reason);
            }
            if (hri_state.y_zero_acknowledged && hri_active && !hri_ready) {
                hri_ready = true;
                if (!open_radio_monitor()) {
                    audio_failed = true;
                    set_failure("radio_monitor_open_failed");
                    session_ending = true;
                } else {
                    publish("snapshot", "running", "listening", {}, component_json());
                }
            }
        }

        if (downlink && !serial_transport_failed && downlink_state.phase != DownlinkPhase::cleanup_pending &&
            downlink_state.phase != DownlinkPhase::finished) {
            update_downlink(downlink->tick(elapsed_ms()));
            service_actions();
        }

        if (port.valid() && !serial_transport_failed) {
            DWORD comm_errors = 0;
            COMSTAT comm_state{};
            if (!ClearCommError(port.get(), &comm_errors, &comm_state)) {
                handle_serial_failure("serial_clear_comm_error_failed");
            } else if (comm_errors != 0) {
                set_failure("serial_line_or_receive_error");
                if (hri_active) { hri_state = hri_session.cancel().state; hri_active = false; }
                session_ending = true;
                cancel_current_operation("serial_line_or_receive_error");
            } else if (comm_state.cbInQue != 0) {
                const DWORD wanted = std::min<DWORD>(comm_state.cbInQue, static_cast<DWORD>(serial_buffer.size()));
                DWORD actual = 0;
                if (!ReadFile(port.get(), serial_buffer.data(), wanted, &actual, nullptr) || actual > wanted) {
                    handle_serial_failure("serial_read_failed");
                } else if (actual != 0) {
                    ++receive_generation;
                    if (hri_active && !session_ending) {
                        auto update = hri_session.feed(serial_buffer.data(), actual, elapsed_ms());
                        hri_state = update.state;
                        hri_active = hri_state.phase != HriPhase::stopped;
                        for (const auto& command : update.commands) {
                            DWORD written = 0;
                            const BOOL ok = WriteFile(port.get(), command.frame.data(),
                                static_cast<DWORD>(command.frame.size()), &written, nullptr);
                            const bool full = ok != FALSE && written == command.frame.size();
                            hri_state = hri_session.write_completed(command.id, full, elapsed_ms()).state;
                            hri_active = hri_state.phase != HriPhase::stopped;
                            if (!full) { handle_serial_failure("hri_response_write_failed"); break; }
                        }
                        if (hri_state.y_zero_acknowledged && hri_active && !hri_ready) {
                            hri_ready = true;
                            if (!open_radio_monitor()) { audio_failed = true; set_failure("radio_monitor_open_failed"); session_ending = true; }
                            else publish("snapshot", "running", "listening", {}, component_json());
                        }
                    }
                    if (downlink && receive_generation > downlink_feed_generation &&
                        downlink_state.phase != DownlinkPhase::cleanup_pending && downlink_state.phase != DownlinkPhase::finished) {
                        update_downlink(downlink->feed(serial_buffer.data(), actual, elapsed_ms()));
                        service_actions();
                    }
                }
            }
        }

        if (operation.active && operation.capturing && microphone_open) {
            const DWORD waited = WaitForSingleObject(microphone_input.event(), 0);
            if (waited == WAIT_FAILED) {
                audio_failed = true;
                operation.failure_reason = "microphone_capture_wait_failed";
                cancel_current_operation(operation.failure_reason);
            } else {
                for (auto& buffer : microphone_input.buffers()) {
                    if ((buffer.header.dwFlags & WHDR_DONE) == 0) continue;
                    const auto bytes = buffer.header.dwBytesRecorded;
                    if (bytes > buffer.header.dwBufferLength || bytes % sizeof(std::int16_t) != 0) {
                        audio_failed = true;
                        operation.failure_reason = "microphone_capture_pcm_invalid";
                        cancel_current_operation(operation.failure_reason);
                        break;
                    }
                    const auto remaining = max_pcm_bytes - operation.pcm.size();
                    const auto accepted = std::min<std::size_t>(bytes, remaining);
                    const auto* pcm_bytes = reinterpret_cast<const std::uint8_t*>(buffer.samples.data());
                    operation.pcm.insert(operation.pcm.end(), pcm_bytes, pcm_bytes + accepted);
                    captured_bytes = operation.pcm.size();
                    if (operation.pcm.size() < max_pcm_bytes &&
                        microphone_input.requeue(buffer) != MMSYSERR_NOERROR) {
                        audio_failed = true;
                        operation.failure_reason = "microphone_capture_requeue_failed";
                        cancel_current_operation(operation.failure_reason);
                        break;
                    }
                    buffer.header.dwBytesRecorded = 0;
                }
                const auto capture_elapsed = elapsed_ms() - operation.capture_started_ms;
                if (operation.active && operation.capturing &&
                    (operation.pcm.size() >= max_pcm_bytes || capture_elapsed >= microphone_capture_ms)) {
                    const bool mic_ok = close_microphone_input();
                    operation.capturing = false;
                    report_runtime.radio_session.microphone_capture = mic_ok ? "complete" : "failed";
                    if (!mic_ok || operation.pcm.empty()) {
                        audio_failed = true;
                        operation.failure_reason = !mic_ok ? "microphone_cleanup_failed" : "microphone_capture_empty";
                        set_failure(operation.failure_reason);
                        const auto request_id = operation.request_id;
                        publish("operation_result", "failed", "capture_failed", request_id,
                            std::string("\"failure_reason\":") + json_escape(operation.failure_reason), operation.failure_reason);
                        wipe_operation_pcm();
                        operation = {};
                        if (hri_active && hri_ready && !open_radio_monitor()) session_ending = true;
                    } else {
                        operation.pcm_window_ms = (static_cast<std::uint64_t>(operation.pcm.size()) * 1000U + 95999U) / 96000U + 1000U;
                        publish("operation_event", "running", "capture_complete", operation.request_id,
                            "\"captured_pcm_bytes\":" + std::to_string(operation.pcm.size()) + ",\"memory_only\":true");
                        if (!begin_downlink()) {
                            operation.failure_reason = "downlink_start_after_capture_failed";
                            set_failure(operation.failure_reason);
                            const auto request_id = operation.request_id;
                            publish("operation_result", "failed", "operation_start_failed", request_id,
                                std::string("\"failure_reason\":") + json_escape(operation.failure_reason), operation.failure_reason);
                            wipe_operation_pcm();
                            operation = {};
                            if (hri_active && hri_ready && !open_radio_monitor()) session_ending = true;
                        }
                    }
                } else if (operation.active && operation.capturing && capture_elapsed > microphone_capture_ms + microphone_capture_grace_ms) {
                    operation.failure_reason = "microphone_capture_timeout";
                    audio_failed = true;
                    cancel_current_operation(operation.failure_reason);
                }
            }
        }

        service_actions();
        if (downlink && downlink_state.phase == DownlinkPhase::pcm_active && radio_output_open && !operation.pcm_cancelled) {
            if (operation.pcm_offset < operation.pcm.size() && radio_output.has_capacity()) {
                const auto count = std::min<std::size_t>(WaveInput::sample_count * sizeof(std::int16_t),
                    operation.pcm.size() - operation.pcm_offset);
                const auto submitted = radio_output.submit(operation.pcm.data() + operation.pcm_offset,
                    static_cast<DWORD>(count));
                if (submitted == WaveOutput::SubmitResult::queued) {
                    operation.pcm_offset += count;
                    pcm_submitted_bytes += count;
                } else if (submitted != WaveOutput::SubmitResult::full) {
                    audio_failed = true;
                    set_failure("radio_pcm_submit_failed");
                    update_downlink(downlink->pcm_completed(false, elapsed_ms()));
                    service_actions();
                }
            } else if (operation.pcm_offset == operation.pcm.size() && radio_output.all_drained()) {
                pcm_drained = true;
                update_downlink(downlink->pcm_completed(true, elapsed_ms()));
                service_actions();
            }
        }
        complete_operation_cleanup();

        if (hri_ready && radio_input_open && !operation.active && !session_ending) process_radio_monitor();
        if (!report_write_failed && elapsed_ms() >= next_snapshot_ms && !session_ending) {
            publish("snapshot", "running", current_phase(), {}, component_json());
            next_snapshot_ms = elapsed_ms() + 1000U;
        }
        if (session_ending) (void)stop_budget.begin_shutdown(elapsed_ms());
        if (stop_budget.expired(elapsed_ms()) &&
            (operation.active || downlink.has_value())) {
            cleanup_deadline_forced = true;
            set_failure("session_cleanup_deadline_exceeded");
            if (downlink && downlink_state.start_write_attempted && !stop_write_attempted &&
                !serial_transport_failed && port.valid() &&
                downlink_state.phase != DownlinkPhase::cleanup_pending && downlink_state.phase != DownlinkPhase::finished) {
                update_downlink(downlink->cancel(elapsed_ms()));
                service_actions();
            }
            if (downlink && downlink_state.phase == DownlinkPhase::cleanup_pending) complete_operation_cleanup();
            if (operation.active || downlink) {
                if (operation.capturing) (void)close_microphone_input();
                const bool output_ok = close_radio_output();
                if (!output_ok) {
                    audio_failed = true;
                    set_failure("radio_waveout_cleanup_failed");
                }
                const std::string request_id = operation.request_id;
                const std::string cancel_request_id = operation.cancel_request_id;
                operation.active = false;
                operation.capturing = false;
                wipe_operation_pcm();
                downlink.reset();
                pending_actions.clear();
                last_request_id = request_id;
                publish("operation_result", "failed", "cleanup_deadline_exceeded", request_id,
                    std::string("\"failure_reason\":\"session_cleanup_deadline_exceeded\",") + component_json(),
                    "session_cleanup_deadline_exceeded");
                if (!cancel_request_id.empty()) {
                    publish("operation_result", "failed", "cancel_request_finished", cancel_request_id,
                        "\"failure_reason\":\"session_cleanup_deadline_exceeded\"");
                }
                operation = {};
            }
        }
        if (session_ending && !operation.active && !downlink) break;
        Sleep(10);
    }

    if (hri_active && hri_state.phase != HriPhase::stopped) {
        hri_state = hri_session.finish(elapsed_ms()).state;
        hri_active = false;
    }
    const bool radio_input_cleanup_ok = close_radio_input();
    const bool microphone_cleanup_ok = close_microphone_input();
    const bool pc_output_cleanup_ok = close_pc_output();
    const bool radio_output_cleanup_ok = close_radio_output();
    const HANDLE raw_port = port.release();
    const bool serial_cleanup_ok = raw_port != nullptr && raw_port != INVALID_HANDLE_VALUE && CloseHandle(raw_port) != FALSE;
    wipe_operation_pcm();
    cleanup_ok = radio_input_cleanup_ok && microphone_cleanup_ok && pc_output_cleanup_ok && radio_output_cleanup_ok && serial_cleanup_ok;
    if (!cleanup_ok) set_failure("pc_or_serial_cleanup_failed");

    const bool ended_normally = shutdown_requested && !report_write_failed && !control_failed && cleanup_ok;
    std::string final_status = "failed";
    if (report_write_failed || protocol_output_failed || control_failed || !cleanup_ok || serial_transport_failed || audio_failed) final_status = "failed";
    else if (natural_deadline) final_status = "timed_out";
    else if (parent_pipe_closed) final_status = "unknown";
    else if (shutdown_requested || console_cancelled) final_status = "completed";
    else final_status = "unknown";
    std::string final_reason = final_failure_reason;
    if (final_reason.empty()) {
        if (natural_deadline) final_reason = "radio_session_deadline";
        else if (parent_pipe_closed) final_reason = "parent_pipe_eof";
        else if (shutdown_requested) final_reason = "shutdown_requested";
        else if (console_cancelled) final_reason = "console_cancelled";
    }
    report_runtime.final = true;
    report_runtime.status = final_status;
    report_runtime.phase = "stopped";
    report_runtime.failure_reason = final_reason;
    report_runtime.report_write_failed = report_write_failed;
    const bool input_cleanup_started = radio_input_started || microphone_input_started ||
        radio_input_cleanup_state.close_failed() || microphone_input_cleanup_state.close_failed();
    report_runtime.audio_input_cleanup = !input_cleanup_started ? "not_started" :
        (radio_input_cleanup_ok && microphone_cleanup_ok ? "succeeded" : "failed");
    const bool output_cleanup_started = pc_output_started || pc_output.close_failed() || radio_output_started ||
        radio_output.close_failed() || radio_output_cleanup_state.close_failed();
    report_runtime.audio_output_cleanup = !output_cleanup_started ? "not_started" :
        (pc_output_cleanup_ok && radio_output_cleanup_ok ? "succeeded" : "failed");
    report_runtime.serial_cleanup = serial_cleanup_ok ? "succeeded" : "failed";
    report_runtime.elapsed_ms = elapsed_ms();
    report_runtime.downlink.operation_audio_cleanup.assign(radio_output_cleanup_state.status(false));
    set_report_components();
    if (!report_writer.write(hri_state, report_runtime, report_error)) {
        report_write_failed = true;
        session_final_report_failed = true;
        final_status = "failed";
        final_reason = "report_write_failed";
        report_runtime.status = final_status;
        report_runtime.failure_reason = final_reason;
        report_runtime.report_write_failed = true;
        (void)report_writer.write(hri_state, report_runtime, report_error);
    }
    const bool signal_ok = handler_started && control_scope.signal_cleanup_complete();
    const DWORD signal_error = signal_ok ? ERROR_SUCCESS : GetLastError();
    const bool unregister_ok = !handler_started || control_scope.unregister_now();
    const DWORD unregister_error = unregister_ok ? ERROR_SUCCESS : GetLastError();
    if (!signal_ok || !unregister_ok) {
        final_status = "failed";
        final_reason = !signal_ok ? "console_cleanup_signal_failed" : "console_handler_unregister_failed";
        if (!signal_ok && !unregister_ok) final_reason += ";console_handler_unregister_failed";
        report_runtime.status = final_status;
        report_runtime.failure_reason = final_reason;
        if (!report_writer.write(hri_state, report_runtime, report_error)) session_final_report_failed = true;
    }
    if (!signal_ok) std::wcerr << L"无法发出会话清理完成信号：" << win_error(signal_error) << L"\n";
    if (!unregister_ok) std::wcerr << L"无法注销控制台处理器：" << win_error(unregister_error) << L"\n";
    publish("session_result", final_status, "stopped", accepted_shutdown_id,
        std::string("\"failure_reason\":") + json_escape(final_reason) + "," + component_json(), final_reason);
    if (protocol_output_failed && final_status != "failed") {
        final_status = "failed";
        final_reason = "protocol_stdout_write_failed";
        report_runtime.status = final_status;
        report_runtime.failure_reason = final_reason;
        report_runtime.report_write_failed = report_write_failed;
        (void)report_writer.write(hri_state, report_runtime, report_error);
    }
    if (report_write_failed || session_final_report_failed || final_status == "failed") return 2;
    if (ended_normally || (console_cancelled && cleanup_ok && !control_failed)) return 0;
    return final_status == "timed_out" || final_status == "unknown" ? 0 : 2;
}

int play_wav(const std::wstring& path, UINT output_id)
{
    std::vector<std::uint8_t> file_bytes;
    if (!read_wav_file(path, file_bytes)) return 2;
    const auto wav = wirex::wave_file::parse(file_bytes.data(), file_bytes.size());
    if (!wav) {
        std::cerr << "WAV rejected: " << wirex::wave_file::error_name(wav.error) << "\n";
        return 2;
    }
    if (output_id >= waveOutGetNumDevs()) {
        std::wcerr << L"Output ID is outside the enumerated WaveOut device range. Run --list-audio and select an ID.\n";
        return 2;
    }
    WAVEOUTCAPSW caps{};
    const auto cap_result = waveOutGetDevCapsW(output_id, &caps, sizeof(caps));
    if (cap_result != MMSYSERR_NOERROR) {
        std::wcerr << L"Output device query failed: " << mm_error(cap_result) << L"\n";
        return 2;
    }

    std::cout << "Playing explicit output " << output_id << " (" << to_utf8(device_name(caps.szPname, MAXPNAMELEN))
              << "); PCM 48000 Hz, mono, signed 16-bit; WAV data=" << wav.info.data_size << " bytes.\n"
              << "No default device, resampling, file writing, or PTT is used.\n";

    wirex::ConsoleHandlerScope control_scope;
    WaveOutput output;
    if (!output.open(output_id)) return 2;
    if (!control_scope.start()) {
        std::wcerr << L"Could not register the console control handler: " << win_error(GetLastError()) << L"\n";
        return output.close() ? 2 : 3;
    }

    constexpr auto playback_grace = std::chrono::seconds(5);
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(wirex::wave_file::max_duration_seconds) + playback_grace;
    const std::size_t chunk_capacity = WaveInput::sample_count * sizeof(std::int16_t);
    std::size_t offset = wav.info.data_offset;
    const std::size_t data_end = wav.info.data_offset + wav.info.data_size;
    std::uint64_t submitted_bytes = 0;
    bool cancelled = false;
    bool timed_out = false;
    bool failed = false;

    while (offset < data_end) {
        if (control_scope.cancel_requested()) {
            cancelled = true;
            break;
        }
        const auto byte_count = std::min(chunk_capacity, data_end - offset);
        const auto result = output.submit_wait(file_bytes.data() + offset, static_cast<DWORD>(byte_count), deadline);
        if (result == WaveOutput::SubmitResult::queued) {
            offset += byte_count;
            submitted_bytes += byte_count;
            continue;
        }
        if (result == WaveOutput::SubmitResult::cancelled) cancelled = true;
        else if (result == WaveOutput::SubmitResult::timed_out) timed_out = true;
        else failed = true;
        break;
    }

    bool drained = false;
    if (!cancelled && !timed_out && !failed && offset == data_end) {
        const auto drain = output.drain_until(deadline);
        if (drain == WaveOutput::DrainResult::complete) drained = true;
        else if (drain == WaveOutput::DrainResult::cancelled) cancelled = true;
        else if (drain == WaveOutput::DrainResult::timed_out) timed_out = true;
        else failed = true;
    }

    const bool cleanup_ok = output.close();
    if (!cleanup_ok) failed = true;
    if (!control_scope.signal_cleanup_complete()) failed = true;
    if (!control_scope.unregister_now()) {
        std::wcerr << L"Could not unregister the console control handler: " << win_error(GetLastError()) << L"\n";
        failed = true;
    }

    if (drained && cleanup_ok && !failed) {
        std::cout << "WAV playback completed; all " << submitted_bytes << " PCM bytes were submitted and drained.\n";
        return 0;
    }
    if (cancelled) std::cout << "WAV playback cancelled; queued output was reset. Submitted " << submitted_bytes << " of " << wav.info.data_size << " bytes.\n";
    else if (timed_out) std::cout << "WAV playback deadline expired; queued output was reset. Submitted " << submitted_bytes << " of " << wav.info.data_size << " bytes.\n";
    else std::cout << "WAV playback did not complete; queued output was reset. Submitted " << submitted_bytes << " of " << wav.info.data_size << " bytes.\n";
    return 2;
}

int monitor_input(UINT input_id, unsigned long seconds)
{
    if (input_id >= waveInGetNumDevs()) {
        std::wcerr << L"Input ID is outside the enumerated WaveIn device range. Run --list-audio and select an ID.\n";
        return 2;
    }
    WAVEINCAPSW caps{};
    const auto cap_result = waveInGetDevCapsW(input_id, &caps, sizeof(caps));
    if (cap_result != MMSYSERR_NOERROR) {
        std::wcerr << L"Input device query failed: " << mm_error(cap_result) << L"\n";
        return 2;
    }
    std::cout << "Monitoring input " << input_id << " (" << to_utf8(device_name(caps.szPname, MAXPNAMELEN)) << ") for " << seconds
              << " s; PCM 48000 Hz, mono, signed 16-bit; no audio is saved or played.\n";

    wirex::ConsoleHandlerScope control_scope;
    WaveInput input;
    if (!input.open(input_id)) return 2;
    if (!control_scope.start()) {
        std::wcerr << L"Could not register the console control handler: " << win_error(GetLastError()) << L"\n";
        const bool cleanup_ok = input.close();
        return cleanup_ok ? 2 : 3;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    auto report_at = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    long double sum_squares = 0.0L;
    std::uint64_t samples = 0;
    std::uint32_t peak = 0;
    bool failed = false;

    while (!control_scope.cancel_requested() && std::chrono::steady_clock::now() < deadline) {
        const DWORD wait_result = WaitForSingleObject(input.event(), 250);
        if (wait_result == WAIT_FAILED) {
            std::wcerr << L"WaitForSingleObject failed: " << win_error(GetLastError()) << L"\n";
            failed = true;
            break;
        }
        for (auto& buffer : input.buffers()) {
            if ((buffer.header.dwFlags & WHDR_DONE) == 0) continue;
            const auto recorded = buffer.header.dwBytesRecorded;
            if (recorded > buffer.header.dwBufferLength || recorded % sizeof(std::int16_t) != 0) {
                std::wcerr << L"WaveIn returned an invalid byte count or a partial 16-bit PCM sample; stopping.\n";
                failed = true;
                break;
            }
            const auto count = recorded / sizeof(std::int16_t);
            for (DWORD i = 0; i < count; ++i) {
                const auto sample = static_cast<std::int32_t>(buffer.samples[i]);
                const auto magnitude = static_cast<std::uint32_t>(sample < 0 ? -sample : sample);
                peak = std::max(peak, magnitude);
                sum_squares += static_cast<long double>(sample) * static_cast<long double>(sample);
            }
            samples += count;
            buffer.header.dwBytesRecorded = 0;
            const auto queued = input.requeue(buffer);
            if (queued != MMSYSERR_NOERROR) {
                std::wcerr << L"waveInAddBuffer failed while monitoring: " << mm_error(queued) << L"\n";
                failed = true;
                break;
            }
        }
        if (failed) break;
        const auto now = std::chrono::steady_clock::now();
        if (now >= report_at) {
            if (samples == 0) {
                std::wcout << L"PCM: no samples completed yet.\n";
            } else {
                const auto rms = std::sqrt(static_cast<double>(sum_squares / samples));
                const auto dbfs = rms == 0.0 ? -120.0 : 20.0 * std::log10(rms / 32768.0);
                std::wcout << L"PCM samples=" << samples << L" RMS=" << std::fixed << std::setprecision(1) << dbfs
                           << L" dBFS peak=" << peak << L"\n";
            }
            sum_squares = 0.0L;
            samples = 0;
            peak = 0;
            report_at = now + std::chrono::seconds(1);
        }
    }
    const bool cleanup_ok = input.close();
    if (!control_scope.signal_cleanup_complete()) failed = true;
    if (!control_scope.unregister_now()) {
        std::wcerr << L"Could not unregister the console control handler: " << win_error(GetLastError()) << L"\n";
        failed = true;
    }
    if (cleanup_ok) {
        if (control_scope.cancel_requested()) std::wcout << L"Monitor cancelled; reset and close calls succeeded for audio input.\n";
        else std::wcout << L"Monitor stopped; reset and close calls succeeded for audio input.\n";
    } else {
        std::wcout << L"Monitor stopped, but at least one audio cleanup call failed; inspect the error output.\n";
    }
    return failed || !cleanup_ok ? 2 : 0;
}

#ifdef WIREX_ENABLE_BM_BRIDGE

constexpr std::uint64_t bm_bridge_window_ms = 120000U;
constexpr std::uint64_t bm_bridge_cleanup_ms = 3000U;

bool write_bm_bytes(HANDLE output, const void* data, std::size_t size) noexcept
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

bool write_bm_wide(HANDLE output, std::wstring_view text) noexcept
{
    if (output == nullptr || output == INVALID_HANDLE_VALUE) return false;
    DWORD mode = 0U;
    if (GetConsoleMode(output, &mode)) {
        std::size_t offset = 0U;
        while (offset < text.size()) {
            const DWORD count = static_cast<DWORD>(std::min<std::size_t>(text.size() - offset, 0x7fffffffU));
            DWORD written = 0U;
            if (!WriteConsoleW(output, text.data() + offset, count, &written, nullptr) || written == 0U) return false;
            offset += written;
        }
        return true;
    }
    if (text.empty()) return true;
    if (text.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) return false;
    const int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0) return false;
    try {
        std::string utf8(static_cast<std::size_t>(required), '\0');
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
            static_cast<int>(text.size()), utf8.data(), required, nullptr, nullptr) != required) return false;
        return write_bm_bytes(output, utf8.data(), utf8.size());
    } catch (...) {
        return false;
    }
}

bool write_bm_utf8(HANDLE output, std::string_view text) noexcept
{
    if (output == nullptr || output == INVALID_HANDLE_VALUE) return false;
    DWORD mode = 0U;
    if (!GetConsoleMode(output, &mode)) return write_bm_bytes(output, text.data(), text.size());
    if (text.empty()) return true;
    if (text.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) return false;
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0);
    if (required <= 0) return false;
    try {
        std::wstring wide(static_cast<std::size_t>(required), L'\0');
        if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
            static_cast<int>(text.size()), wide.data(), required) != required) return false;
        return write_bm_wide(output, wide);
    } catch (...) {
        return false;
    }
}

bool bm_stderr(std::wstring_view text) noexcept
{
    return write_bm_wide(GetStdHandle(STD_ERROR_HANDLE), text);
}

bool bm_stdout(std::string_view text) noexcept
{
    return write_bm_utf8(GetStdHandle(STD_OUTPUT_HANDLE), text);
}

bool parse_ascii_uint(std::string_view text, std::uint32_t& value) noexcept
{
    return wirex::bm_connection_config::parse_decimal_u32(text, value);
}

bool narrow_ascii_text(std::wstring_view text, std::string& value, std::size_t max_size,
                       bool allow_empty = false) noexcept
{
    if (text.size() > max_size || (!allow_empty && text.empty())) return false;
    try {
        value.clear();
        value.reserve(text.size());
        for (const wchar_t ch : text) {
            if (ch < 0x20 || ch > 0x7e) return false;
            value.push_back(static_cast<char>(ch));
        }
        return allow_empty || !value.empty();
    } catch (...) {
        value.clear();
        return false;
    }
}

bool validate_manual_connection(const std::string& callsign, std::uint32_t gateway_id,
                                std::uint32_t source_id, std::uint32_t destination_id,
                                std::uint32_t slot_number, std::uint32_t color_code,
                                const std::string& master, std::uint32_t master_port,
                                const std::string& call_kind) noexcept
{
    return wirex::bm_connection_config::validate({callsign, gateway_id, source_id, master,
        master_port, destination_id, slot_number, color_code, call_kind});
}

bool read_ascii_line(const wchar_t* prompt, std::string& value, std::size_t max_size,
                     bool allow_empty = false)
{
    std::wstring line;
    if (!bm_stderr(prompt)) return false;
    if (!std::getline(std::wcin, line)) return false;
    if (line.size() > max_size || (!allow_empty && line.empty())) return false;
    value.clear();
    value.reserve(line.size());
    for (const wchar_t ch : line) {
        if (ch < 0x20 || ch > 0x7e) return false;
        value.push_back(static_cast<char>(ch));
    }
    return allow_empty || !value.empty();
}

bool read_uint_line(const wchar_t* prompt, std::uint32_t& value)
{
    std::string line;
    return read_ascii_line(prompt, line, 10U) && parse_ascii_uint(line, value);
}

class ConsoleInputModeRestore final {
public:
    explicit ConsoleInputModeRestore(HANDLE input) noexcept : input_(input)
    {
        if (input_ != nullptr && input_ != INVALID_HANDLE_VALUE && GetConsoleMode(input_, &original_)) {
            const DWORD hidden = original_ & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
            active_ = hidden != original_ && SetConsoleMode(input_, hidden) != FALSE;
            if (hidden == original_) active_ = true;
        }
    }

    ~ConsoleInputModeRestore()
    {
        (void)restore();
    }

    ConsoleInputModeRestore(const ConsoleInputModeRestore&) = delete;
    ConsoleInputModeRestore& operator=(const ConsoleInputModeRestore&) = delete;
    [[nodiscard]] bool active() const noexcept { return active_; }
    [[nodiscard]] bool restore() noexcept
    {
        if (!active_) return true;
        if (SetConsoleMode(input_, original_) == FALSE) return false;
        active_ = false;
        return true;
    }

private:
    HANDLE input_{};
    DWORD original_{};
    bool active_{};
};

struct WidePasswordBufferWiper final {
    std::array<wchar_t, 257U>& buffer;
    ~WidePasswordBufferWiper() { SecureZeroMemory(buffer.data(), sizeof(buffer)); }
};

bool read_hidden_password(std::string& password, const wirex::ConsoleHandlerScope& control_scope)
{
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    ConsoleInputModeRestore mode(input);
    if (!mode.active()) return false;
    std::array<wchar_t, 257U> buffer{};
    const WidePasswordBufferWiper buffer_wiper{buffer};
    (void)buffer_wiper;
    std::size_t length = 0U;
    if (!bm_stderr(L"BM 密码（隐藏输入；不会写入文件或日志）：")) return false;
    bool accepted = false;
    const ULONGLONG deadline = GetTickCount64() + 300000U;
    for (;;) {
        if (control_scope.cancel_requested() || GetTickCount64() >= deadline) break;
        const DWORD wait = WaitForSingleObject(input, 100U);
        if (wait == WAIT_TIMEOUT) continue;
        if (wait != WAIT_OBJECT_0) break;
        wchar_t ch{};
        DWORD read = 0U;
        if (!ReadConsoleW(input, &ch, 1U, &read, nullptr) || read != 1U) break;
        if (ch == L'\r' || ch == L'\n') {
            accepted = length != 0U;
            break;
        }
        if (ch == L'\x1b' || ch == L'\x03' || ch == L'\x1a') break;
        if (ch == L'\b') {
            if (length != 0U) buffer[--length] = L'\0';
            continue;
        }
        if (ch < 0x20 || ch > 0x7e || length == 256U) break;
        buffer[length++] = ch;
    }
    (void)bm_stderr(L"\n");
    if (accepted) {
        if (!password.empty()) SecureZeroMemory(password.data(), password.size());
        password.clear();
        password.reserve(length);
        for (std::size_t index = 0U; index < length; ++index) {
            password.push_back(static_cast<char>(buffer[index]));
        }
    }
    const bool mode_restored = mode.restore();
    (void)FlushConsoleInputBuffer(input);
    return accepted && mode_restored;
}

struct ByteBufferWiper final {
    std::vector<char>& buffer;
    ~ByteBufferWiper()
    {
        if (!buffer.empty()) SecureZeroMemory(buffer.data(), buffer.size());
    }
};

bool read_profile_password_file(const std::filesystem::path& path, std::string& password) noexcept
{
    std::error_code error;
    const auto file_size = std::filesystem::file_size(path, error);
    if (error || file_size == 0U || file_size > 128U) return false;
    try {
        std::ifstream input(path, std::ios::binary);
        if (!input) return false;
        std::vector<char> bytes(static_cast<std::size_t>(file_size));
        const ByteBufferWiper buffer_wiper{bytes};
        (void)buffer_wiper;
        input.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        if (input.gcount() != static_cast<std::streamsize>(bytes.size()) ||
            input.peek() != std::char_traits<char>::eof()) return false;

        std::size_t length = bytes.size();
        if (length != 0U && bytes[length - 1U] == '\n') {
            --length;
            if (length != 0U && bytes[length - 1U] == '\r') --length;
        }
        if (length == 0U || length > 128U) return false;
        for (std::size_t index = 0U; index < length; ++index) {
            const auto value = static_cast<unsigned char>(bytes[index]);
            if (value < 0x20U || value > 0x7eU) return false;
        }
        password.assign(bytes.data(), length);
        return true;
    } catch (...) {
        if (!password.empty()) SecureZeroMemory(password.data(), password.size());
        password.clear();
        return false;
    }
}

void wipe_password(std::string& value) noexcept
{
    if (!value.empty()) SecureZeroMemory(value.data(), value.size());
    value.clear();
}

bool parse_ipv4_literal(std::string_view text, std::array<std::uint8_t, 4U>& address) noexcept
{
    std::size_t offset = 0U;
    for (std::size_t octet = 0U; octet < address.size(); ++octet) {
        const auto separator = text.find('.', offset);
        const auto end = separator == std::string_view::npos ? text.size() : separator;
        const auto part = text.substr(offset, end - offset);
        std::uint32_t value = 0U;
        if (part.empty() || part.size() > 3U || !parse_ascii_uint(part, value) || value > 255U) return false;
        address[octet] = static_cast<std::uint8_t>(value);
        if (octet + 1U == address.size()) return end == text.size();
        if (separator == std::string_view::npos) return false;
        offset = separator + 1U;
    }
    return false;
}

struct AddressLookup final {
    OVERLAPPED overlapped{};
    HANDLE event{};
    PADDRINFOEXW result{};
};

// 只解析操作者输入的主机名，限定等待时间并固定首个 IPv4 结果；不会猜测 Master。
bool resolve_master_ipv4(std::string_view host,
                         std::array<std::uint8_t, 4U>& address) noexcept
{
    if (parse_ipv4_literal(host, address)) return true;
    if (host.empty() || host.size() > 253U) return false;
    std::wstring wide_host;
    try {
        wide_host.reserve(host.size());
        for (const unsigned char ch : host) {
            if (ch <= 0x20U || ch >= 0x7fU) return false;
            wide_host.push_back(static_cast<wchar_t>(ch));
        }
    } catch (...) {
        return false;
    }

    WSADATA wsa_data{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) return false;
    AddressLookup* lookup = new (std::nothrow) AddressLookup{};
    if (lookup == nullptr) {
        WSACleanup();
        return false;
    }
    lookup->event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (lookup->event == nullptr) {
        delete lookup;
        WSACleanup();
        return false;
    }
    lookup->overlapped.hEvent = lookup->event;
    ADDRINFOEXW hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    timeval timeout{};
    timeout.tv_sec = 3;
    HANDLE operation = nullptr;
    const INT started = GetAddrInfoExW(wide_host.c_str(), nullptr, NS_DNS, nullptr,
        &hints, &lookup->result, &timeout, &lookup->overlapped, nullptr, &operation);
    INT completion = started;
    bool safe_to_release = true;
    if (started == WSA_IO_PENDING) {
        const DWORD waited = WaitForSingleObject(lookup->event, 3500U);
        if (waited == WAIT_OBJECT_0) {
            completion = GetAddrInfoExOverlappedResult(&lookup->overlapped);
        } else {
            if (operation != nullptr) (void)GetAddrInfoExCancel(&operation);
            // 取消会通知重叠事件；若提供程序未及时完成，保留操作上下文直到进程退出，避免悬空 OVERLAPPED。
            if (WaitForSingleObject(lookup->event, 500U) == WAIT_OBJECT_0) {
                completion = GetAddrInfoExOverlappedResult(&lookup->overlapped);
            } else {
                safe_to_release = false;
            }
        }
    }

    bool resolved = false;
    if (safe_to_release && completion == 0 && lookup->result != nullptr) {
        for (const auto* item = lookup->result; item != nullptr; item = item->ai_next) {
            if (item->ai_family != AF_INET || item->ai_addr == nullptr ||
            item->ai_addrlen < sizeof(sockaddr_in)) continue;
            const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(item->ai_addr);
            std::memcpy(address.data(), &ipv4->sin_addr, address.size());
            resolved = true;
            break;
        }
    }
    if (safe_to_release) {
        if (lookup->result != nullptr) FreeAddrInfoExW(lookup->result);
        CloseHandle(lookup->event);
        delete lookup;
        WSACleanup();
    }
    return resolved;
}

std::string ipv4_text(const std::array<std::uint8_t, 4U>& address)
{
    return std::to_string(address[0]) + "." + std::to_string(address[1]) + "." +
        std::to_string(address[2]) + "." + std::to_string(address[3]);
}

const char* bm_state_name(wirex::bm::State state) noexcept
{
    using wirex::bm::State;
    switch (state) {
    case State::idle: return "idle";
    case State::waiting_login_ack: return "waiting_login_ack";
    case State::waiting_auth_ack: return "waiting_auth_ack";
    case State::waiting_config_ack: return "waiting_config_ack";
    case State::waiting_options_ack: return "waiting_options_ack";
    case State::ready: return "ready";
    case State::backoff: return "backoff";
    case State::stopped: return "stopped";
    }
    return "unknown";
}

const char* bm_failure_name(wirex::bm::Failure failure) noexcept
{
    using wirex::bm::Failure;
    switch (failure) {
    case Failure::none: return "none";
    case Failure::invalid_profile: return "invalid_profile";
    case Failure::login_timeout: return "login_timeout";
    case Failure::auth_timeout: return "auth_timeout";
    case Failure::config_timeout: return "config_timeout";
    case Failure::options_timeout: return "options_timeout";
    case Failure::pong_timeout: return "pong_timeout";
    case Failure::master_rejected: return "master_rejected";
    case Failure::master_closed: return "master_closed";
    case Failure::malformed_response: return "malformed_response";
    case Failure::unexpected_response: return "unexpected_response";
    case Failure::wrong_peer_id: return "wrong_peer_id";
    case Failure::authentication_error: return "authentication_error";
    case Failure::inbound_queue_full: return "inbound_queue_full";
    case Failure::transport_lost: return "transport_lost";
    case Failure::outbound_queue_full: return "outbound_queue_full";
    }
    return "unknown";
}

const char* bm_input_result_name(wirex::bm::InputResult result) noexcept
{
    using wirex::bm::InputResult;
    switch (result) {
    case InputResult::accepted: return "accepted";
    case InputResult::application_datagram: return "application_datagram";
    case InputResult::ignored_wrong_endpoint: return "ignored_wrong_endpoint";
    case InputResult::ignored_unknown_packet: return "ignored_unknown_packet";
    case InputResult::rejected_wrong_state: return "rejected_wrong_state";
    case InputResult::rejected_malformed: return "rejected_malformed";
    case InputResult::rejected_application_queue_full: return "rejected_application_queue_full";
    case InputResult::ignored_duplicate_ack: return "ignored_duplicate_ack";
    case InputResult::master_rejected: return "master_rejected";
    case InputResult::master_closed: return "master_closed";
    }
    return "unknown";
}

const char* hri_stream_phase_name(wirex::hri_stream_session::Phase phase) noexcept
{
    using wirex::hri_stream_session::Phase;
    switch (phase) {
    case Phase::idle: return "idle";
    case Phase::start_write_pending: return "start_write_pending";
    case Phase::start_write_in_progress: return "start_write_in_progress";
    case Phase::awaiting_start_record: return "awaiting_start_record";
    case Phase::playing: return "playing";
    case Phase::draining: return "draining";
    case Phase::stop_write_pending: return "stop_write_pending";
    case Phase::stop_write_in_progress: return "stop_write_in_progress";
    case Phase::awaiting_stop_record: return "awaiting_stop_record";
    case Phase::faulted: return "faulted";
    }
    return "unknown";
}

void print_bm_bridge_help()
{
    (void)write_bm_wide(GetStdHandle(STD_OUTPUT_HANDLE),
        L"wirex_bridge - 本地 DIRECT / BrandMeister 声音桥接候选\n"
        L"  --help\n"
        L"  --list-audio-json\n"
        L"  --run --port COMn --body-file ABS --input N --output N --status-file ABS --expected-wavein-endpoint ID --expected-waveout-endpoint ID [--test-preset parrot-cn|parrot-global|listen-46001|listen-91 --password-file ABS] [完整手工配置字段] [--manual-ptt] [--radio-playback-gain N] [--mic-transmit-gain N]\n"
        L"手工配置字段：--profile-callsign、--profile-gateway-id、--profile-source-id、--profile-master、--profile-master-port、--profile-destination-id、--profile-slot、--profile-color-code、--profile-call-kind（G 或 P）。九项必须同时提供。\n"
        L"手工配置字段省略时保留逐项交互输入；密码文件为本机私有明文 UTF-8 文本，启动参数只传文件路径。\n"
        L"WaveIn/WaveOut endpoint ID来自本次 WinMM 枚举；打开和重开音频流前都会核对。\n"
        L"默认在 BM/HRI ready 后用有效 HRI 手咪PTT边沿控制上行；--manual-ptt 显式启用键盘 T 诊断模式。\n"
        L"Q 停止并退出；电台手咪 PTT 控制 BM 上行。\n"
        L"--radio-playback-gain 和 --mic-transmit-gain 接受 0.25..16.0，最多 3 位小数；默认分别为 1x 和 16x。\n"
        L"状态报告按成功提交的 PCM 记录两条音频路径增益前后的统计和削波样本数。\n"
        L"Master 支持 IPv4 字面量或主机名；手工密码在控制台隐藏输入，预设从私有 UTF-8 文件读取。\n"
        L"两种密码入口只接受可打印 ASCII；手工隐藏输入允许空格。\n"
        L"--ui-pipe 仅供桌面 UI 使用；必须提供完整配置或预设、显式密码文件、状态文件与匿名 stdin 管道，只接受 Q 换行或 EOF 停止。\n");
}

struct BmBridgeCounters {
    std::string run_id;
    std::uint64_t status_sequence{};
    bool audio_endpoints_validated{};
    bool hri_serial_open{};
    bool hri_ready{};
    bool hri_y_zero_ready{};
    bool wavein_open{};
    bool waveout_open{};
    std::uint64_t tx_datagrams{};
    std::uint64_t rx_datagrams{};
    std::uint64_t control_tx_attempted{};
    std::uint64_t control_tx_succeeded{};
    std::uint64_t control_rx_datagrams{};
    std::uint64_t application_rx_datagrams{};
    wirex::bm::InputResult last_input_result{wirex::bm::InputResult::accepted};
    bool has_last_input_result{};
    std::uint64_t tx_audio_samples{};
    std::uint32_t tx_input_gain_milli{16000U};
    wirex::pcm_gain::SignalStats tx_pcm_input_stats{};
    wirex::pcm_gain::SignalStats tx_pcm_gained_stats{};
    std::uint64_t tx_pcm_clipped_samples{};
    std::uint32_t rx_output_gain_milli{wirex::pcm_gain::unity_milli};
    std::uint64_t rx_audio_samples{};
    wirex::pcm_gain::SignalStats rx_pcm_input_stats{};
    wirex::pcm_gain::SignalStats rx_pcm_gained_stats{};
    std::uint64_t rx_pcm_clipped_samples{};
    std::uint64_t pcm_playback_frames{};
    std::uint64_t calls_started{};
    std::uint64_t calls_ended{};
    std::uint64_t rejected_calls{};
    std::uint64_t reconnects{};
    std::uint64_t ptt_observations{};
    std::uint64_t ptt_unknown_observations{};
    std::uint64_t ptt_tx_starts{};
    std::uint64_t ptt_tx_ends{};
    std::uint64_t ptt_tx_timeouts{};
    std::uint64_t ptt_start_rejections{};
    wirex::hri_session::PttLevel last_ptt_level{wirex::hri_session::PttLevel::unknown};
    bool has_last_rx_header{};
    std::uint32_t last_rx_source_id{};
    std::uint32_t last_rx_destination_id{};
    std::uint8_t last_rx_slot{1U};
    char last_rx_call_kind{'G'};
    std::uint64_t rx_filtered_datagrams{};
    std::uint64_t rx_filtered_destination_id{};
    std::uint64_t rx_filtered_slot{};
    std::uint64_t rx_filtered_call_kind{};
    std::uint64_t rx_filtered_protocol{};
};

const char* ptt_level_name(wirex::hri_session::PttLevel level) noexcept
{
    using wirex::hri_session::PttLevel;
    switch (level) {
    case PttLevel::unknown: return "unknown";
    case PttLevel::pressed: return "pressed";
    case PttLevel::released: return "released";
    }
    return "unknown";
}

std::string make_bridge_run_id()
{
    return std::to_string(GetCurrentProcessId()) + "-" + std::to_string(GetTickCount64());
}

std::uint64_t current_utc_epoch_ms() noexcept
{
    const auto elapsed = std::chrono::system_clock::now().time_since_epoch();
    const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
    return milliseconds > 0 ? static_cast<std::uint64_t>(milliseconds) : 0U;
}

enum class UiPipeInspection {
    waiting,
    shutdown_requested,
    invalid_input,
    failed
};

UiPipeInspection inspect_ui_pipe(HANDLE handle) noexcept
{
    std::array<char, 4U> peeked{};
    DWORD bytes_read = 0U;
    DWORD bytes_available = 0U;
    if (!PeekNamedPipe(handle, peeked.data(), static_cast<DWORD>(peeked.size()),
                       &bytes_read, &bytes_available, nullptr)) {
        const DWORD error = GetLastError();
        if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA || error == ERROR_HANDLE_EOF) {
            return UiPipeInspection::shutdown_requested;
        }
        return UiPipeInspection::failed;
    }
    if (bytes_available == 0U) return UiPipeInspection::waiting;
    wirex::ui_control::Parser parser;
    const auto result = parser.feed(std::string_view(peeked.data(), bytes_read));
    if (result == wirex::ui_control::Result::shutdown) return UiPipeInspection::shutdown_requested;
    if (result == wirex::ui_control::Result::invalid) return UiPipeInspection::invalid_input;
    return UiPipeInspection::waiting;
}

bool append_bridge_status(std::ofstream& file, std::string_view event, std::uint64_t elapsed_ms,
                          const wirex::bm::Snapshot& bm_snapshot,
                          const wirex::hri_session::Snapshot& hri_snapshot,
                          const wirex::hri_ptt_gate::Snapshot& ptt_gate_snapshot,
                          BmBridgeCounters& counters)
{
    if (!file || counters.run_id.empty() || counters.status_sequence == std::numeric_limits<std::uint64_t>::max()) return false;
    ++counters.status_sequence;
    file << "{\"run_id\":\"" << counters.run_id << "\",\"seq\":" << counters.status_sequence
         << ",\"timestamp_utc_ms\":" << current_utc_epoch_ms()
         << ",\"event\":\"" << event << "\",\"elapsed_ms\":" << elapsed_ms
         << ",\"bm_state\":\"" << bm_state_name(bm_snapshot.state)
         << "\",\"bm_failure\":\"" << bm_failure_name(bm_snapshot.last_failure)
         << "\",\"bm_consecutive_failures\":" << bm_snapshot.consecutive_failures
         << ",\"radio_state\":\"unknown\""
         << ",\"audio_endpoints_validated\":" << (counters.audio_endpoints_validated ? "true" : "false")
         << ",\"hri_serial_open\":" << (counters.hri_serial_open ? "true" : "false")
         << ",\"hri_ready\":" << (counters.hri_ready ? "true" : "false")
         << ",\"hri_y_zero_ready\":" << (counters.hri_y_zero_ready ? "true" : "false")
         << ",\"wavein_state\":\"" << (counters.wavein_open ? "open" : "closed") << "\""
         << ",\"waveout_state\":\"" << (counters.waveout_open ? "open" : "closed") << "\""
         << ",\"control_tx_attempted\":" << counters.control_tx_attempted
         << ",\"control_tx_succeeded\":" << counters.control_tx_succeeded
         << ",\"control_rx_datagrams\":" << counters.control_rx_datagrams
         << ",\"application_rx_datagrams\":" << counters.application_rx_datagrams
         << ",\"last_input_result\":\""
         << (counters.has_last_input_result ? bm_input_result_name(counters.last_input_result) : "none")
         << "\",\"hri_phase\":\"" << hri_phase_name(hri_snapshot.phase)
         << "\",\"hri_y_zero_ack_records\":" << hri_snapshot.counters.y_zero_ack_received
         << ",\"hri_y_writes\":" << hri_snapshot.counters.y_write_completed
         << ",\"hri_x100_records\":" << hri_snapshot.counters.x100_received
         << ",\"hri_x_copy_records\":" << hri_snapshot.counters.x_copy_branch_count
         << ",\"hri_x_config_records\":" << hri_snapshot.counters.unsupported_config_import_records
         << ",\"hri_x_ack_writes\":" << hri_snapshot.counters.x0_write_completed
         << ",\"hri_x_ack_requested\":" << hri_snapshot.counters.x0_write_requested
         << ",\"hri_other_valid_records\":" << hri_snapshot.counters.other_valid_records
         << ",\"hri_malformed_records\":" << hri_snapshot.counters.malformed_records
         << ",\"hri_valid_records\":" << hri_snapshot.counters.valid_records
         << ",\"ptt_gate_ready\":" << (ptt_gate_snapshot.ready ? "true" : "false")
         << ",\"ptt_gate_armed\":" << (ptt_gate_snapshot.armed ? "true" : "false")
         << ",\"ptt_gate_pressed_latched\":" << (ptt_gate_snapshot.pressed_latched ? "true" : "false")
         << ",\"ptt_gate_tx_active\":" << (ptt_gate_snapshot.tx_active ? "true" : "false")
         << ",\"ptt_last_state\":\"" << ptt_level_name(counters.last_ptt_level)
         << "\",\"ptt_observations\":" << counters.ptt_observations
         << ",\"ptt_unknown_observations\":" << counters.ptt_unknown_observations
         << ",\"ptt_tx_starts\":" << counters.ptt_tx_starts
         << ",\"ptt_tx_ends\":" << counters.ptt_tx_ends
         << ",\"ptt_tx_timeouts\":" << counters.ptt_tx_timeouts
         << ",\"ptt_start_rejections\":" << counters.ptt_start_rejections
         << ",\"last_rx_header_valid\":" << (counters.has_last_rx_header ? "true" : "false")
         << ",\"last_rx_source_id\":" << counters.last_rx_source_id
         << ",\"last_rx_destination_id\":" << counters.last_rx_destination_id
         << ",\"last_rx_slot\":" << static_cast<unsigned int>(counters.last_rx_slot)
         << ",\"last_rx_call_kind\":\"" << counters.last_rx_call_kind << "\""
         << ",\"rx_filtered_datagrams\":" << counters.rx_filtered_datagrams
         << ",\"rx_filtered_destination_id\":" << counters.rx_filtered_destination_id
         << ",\"rx_filtered_slot\":" << counters.rx_filtered_slot
         << ",\"rx_filtered_call_kind\":" << counters.rx_filtered_call_kind
         << ",\"rx_filtered_protocol\":" << counters.rx_filtered_protocol
         << ",\"tx_datagrams\":" << counters.tx_datagrams
         << ",\"rx_datagrams\":" << counters.rx_datagrams
         << ",\"tx_audio_samples\":" << counters.tx_audio_samples
         << ",\"tx_input_gain_milli\":" << counters.tx_input_gain_milli
         << ",\"tx_pcm_input_samples\":" << counters.tx_pcm_input_stats.sample_count
         << ",\"tx_pcm_input_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.tx_pcm_input_stats)
         << ",\"tx_pcm_input_peak\":" << counters.tx_pcm_input_stats.peak
         << ",\"tx_pcm_gained_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.tx_pcm_gained_stats)
         << ",\"tx_pcm_gained_peak\":" << counters.tx_pcm_gained_stats.peak
         << ",\"tx_pcm_clipped_samples\":" << counters.tx_pcm_clipped_samples
         << ",\"rx_output_gain_milli\":" << counters.rx_output_gain_milli
         << ",\"rx_audio_samples\":" << counters.rx_audio_samples
         << ",\"rx_pcm_input_samples\":" << counters.rx_pcm_input_stats.sample_count
         << ",\"rx_pcm_input_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.rx_pcm_input_stats)
         << ",\"rx_pcm_input_peak\":" << counters.rx_pcm_input_stats.peak
         << ",\"rx_pcm_gained_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.rx_pcm_gained_stats)
         << ",\"rx_pcm_gained_peak\":" << counters.rx_pcm_gained_stats.peak
         << ",\"rx_pcm_clipped_samples\":" << counters.rx_pcm_clipped_samples
         << ",\"playback_frames\":" << counters.pcm_playback_frames
         << ",\"calls_started\":" << counters.calls_started
         << ",\"calls_ended\":" << counters.calls_ended
         << ",\"rejected_calls\":" << counters.rejected_calls
         << ",\"reconnects\":" << counters.reconnects << "}\n";
    if (!file) return false;
    file.flush();
    return static_cast<bool>(file);
}

struct ProfileSecretGuard {
    wirex::bm::Profile& profile;
    ~ProfileSecretGuard() { wipe_password(profile.password); }
};

int run_bm_bridge(const std::wstring& port_name, const std::filesystem::path& body_path,
                  UINT input_id, UINT output_id,
                  const std::wstring& expected_wavein_endpoint_id,
                  const std::wstring& expected_waveout_endpoint_id,
                  wirex::bm::Endpoint master,
                  wirex::bm::Profile profile, wirex::dmr_call::CallConfig call_template,
                  wirex::bm_test_profile::TxPolicy tx_policy,
                  bool manual_ptt,
                  bool ui_pipe,
                  std::uint32_t radio_playback_gain_milli,
                  std::uint32_t mic_transmit_gain_milli,
                  BmBridgeCounters counters,
                  std::ofstream& status_file, wirex::ConsoleHandlerScope& control_scope);

int bm_bridge_main(int argc, wchar_t* argv[])
{
    if (argc == 2 && std::wstring_view(argv[1]) == L"--help") {
        print_bm_bridge_help();
        return 0;
    }
    if (argc == 2 && std::wstring_view(argv[1]) == L"--list-audio-json") {
        list_audio_devices_json();
        return 0;
    }
    const bool common_shape = argc >= 12 && std::wstring_view(argv[1]) == L"--run" &&
        std::wstring_view(argv[2]) == L"--port" && std::wstring_view(argv[4]) == L"--body-file" &&
        std::wstring_view(argv[6]) == L"--input" && std::wstring_view(argv[8]) == L"--output" &&
        std::wstring_view(argv[10]) == L"--status-file";
    if (!common_shape) {
        print_bm_bridge_help();
        return 2;
    }

    std::optional<wirex::bm_test_profile::Preset> selected_preset;
    std::filesystem::path password_file_path;
    std::wstring preset_id;
    std::wstring expected_wavein_endpoint_id;
    std::wstring expected_waveout_endpoint_id;
    bool manual_ptt = false;
    bool manual_ptt_seen = false;
    bool ui_pipe = false;
    bool ui_pipe_seen = false;
    bool preset_seen = false;
    bool password_file_seen = false;
    bool wavein_endpoint_seen = false;
    bool waveout_endpoint_seen = false;
    bool radio_playback_gain_seen = false;
    bool mic_transmit_gain_seen = false;
    std::array<std::wstring, 9U> manual_field_values{};
    std::array<bool, 9U> manual_field_seen{};
    std::uint32_t radio_playback_gain_milli = wirex::pcm_gain::unity_milli;
    std::uint32_t mic_transmit_gain_milli = 16000U;
    for (int index = 12; index < argc;) {
        const std::wstring_view option(argv[index]);
        if (option == L"--manual-ptt") {
            if (manual_ptt_seen) {
                (void)bm_stderr(L"--manual-ptt 不可重复指定。\n");
                return 2;
            }
            manual_ptt = true;
            manual_ptt_seen = true;
            ++index;
            continue;
        }
        if (option == L"--ui-pipe") {
            if (ui_pipe_seen) {
                (void)bm_stderr(L"--ui-pipe 不可重复指定。\n");
                return 2;
            }
            ui_pipe = true;
            ui_pipe_seen = true;
            ++index;
            continue;
        }
        if (index + 1 >= argc) {
            (void)bm_stderr(L"BM bridge 可选参数缺少取值。\n");
            return 2;
        }
        const std::wstring_view value(argv[index + 1]);
        if (option == L"--test-preset") {
            if (preset_seen || value.empty()) {
                (void)bm_stderr(L"--test-preset 不可重复或留空。\n");
                return 2;
            }
            preset_id.assign(value);
            preset_seen = true;
        } else if (option == L"--password-file") {
            if (password_file_seen || value.empty()) {
                (void)bm_stderr(L"--password-file 不可重复或留空。\n");
                return 2;
            }
            password_file_path = std::filesystem::path(std::wstring(value));
            password_file_seen = true;
        } else if (option == L"--expected-wavein-endpoint") {
            if (wavein_endpoint_seen || value.empty() || value.size() > 4096U) {
                (void)bm_stderr(L"--expected-wavein-endpoint 不可重复、留空或超过长度上限。\n");
                return 2;
            }
            expected_wavein_endpoint_id.assign(value);
            wavein_endpoint_seen = true;
        } else if (option == L"--expected-waveout-endpoint") {
            if (waveout_endpoint_seen || value.empty() || value.size() > 4096U) {
                (void)bm_stderr(L"--expected-waveout-endpoint 不可重复、留空或超过长度上限。\n");
                return 2;
            }
            expected_waveout_endpoint_id.assign(value);
            waveout_endpoint_seen = true;
        } else if (option == L"--profile-callsign" || option == L"--profile-gateway-id" ||
                   option == L"--profile-source-id" || option == L"--profile-master" ||
                   option == L"--profile-master-port" || option == L"--profile-destination-id" ||
                   option == L"--profile-slot" || option == L"--profile-color-code" ||
                   option == L"--profile-call-kind") {
            const std::array<std::wstring_view, 9U> field_options{{
                L"--profile-callsign", L"--profile-gateway-id", L"--profile-source-id",
                L"--profile-master", L"--profile-master-port", L"--profile-destination-id",
                L"--profile-slot", L"--profile-color-code", L"--profile-call-kind"}};
            const auto found = std::find(field_options.begin(), field_options.end(), option);
            const auto field_index = static_cast<std::size_t>(std::distance(field_options.begin(), found));
            if (field_index >= manual_field_values.size() || manual_field_seen[field_index] || value.empty()) {
                (void)bm_stderr(L"连接配置字段不可重复或留空。\n");
                return 2;
            }
            manual_field_values[field_index].assign(value);
            manual_field_seen[field_index] = true;
        } else if (option == L"--radio-playback-gain") {
            if (radio_playback_gain_seen || !wirex::pcm_gain::parse_gain(value, radio_playback_gain_milli)) {
                (void)bm_stderr(L"--radio-playback-gain 必须唯一指定为 0.25..16.0 的十进制数，最多 3 位小数。\n");
                return 2;
            }
            radio_playback_gain_seen = true;
        } else if (option == L"--mic-transmit-gain") {
            if (mic_transmit_gain_seen || !wirex::pcm_gain::parse_gain(value, mic_transmit_gain_milli)) {
                (void)bm_stderr(L"--mic-transmit-gain 必须唯一指定为 0.25..16.0 的十进制数，最多 3 位小数。\n");
                return 2;
            }
            mic_transmit_gain_seen = true;
        } else {
            (void)bm_stderr(L"BM bridge 收到未知可选参数。\n");
            return 2;
        }
        index += 2;
    }
    const bool any_manual_field = wirex::bm_connection_config::any_field_seen(manual_field_seen);
    const bool all_manual_fields = wirex::bm_connection_config::all_fields_seen(manual_field_seen);
    if (preset_seen && (!password_file_seen || any_manual_field)) {
        (void)bm_stderr(L"固定预设必须单独使用 --test-preset 和 --password-file，不能混入手工配置字段。\n");
        return 2;
    }
    if (any_manual_field && !all_manual_fields) {
        (void)bm_stderr(L"手工连接配置字段必须九项完整提供。\n");
        return 2;
    }
    if (ui_pipe && (manual_ptt || !password_file_seen || (!preset_seen && !all_manual_fields))) {
        (void)bm_stderr(L"--ui-pipe 需要完整预设或九项手工连接配置、显式密码文件，并且不能启用键盘诊断输入。\n");
        return 2;
    }
    if (password_file_seen && !password_file_path.is_absolute()) {
        (void)bm_stderr(L"BM 私有密码文件必须使用绝对路径。\n");
        return 2;
    }
    if (!wavein_endpoint_seen || !waveout_endpoint_seen) {
        (void)bm_stderr(L"BM bridge 必须提供本次 WinMM 枚举的 WaveIn/WaveOut endpoint ID；当前系统无法查询ID时不能确认设备归属。\n");
        return 2;
    }
    if (preset_seen) {
        const std::wstring_view selected_id(preset_id);
        if (selected_id == L"parrot-cn") selected_preset = wirex::bm_test_profile::find("parrot-cn");
        else if (selected_id == L"parrot-global") selected_preset = wirex::bm_test_profile::find("parrot-global");
        else if (selected_id == L"listen-46001") selected_preset = wirex::bm_test_profile::find("listen-46001");
        else if (selected_id == L"listen-91") selected_preset = wirex::bm_test_profile::find("listen-91");
        if (!selected_preset) {
            (void)bm_stderr(L"测试预设无效；没有打开 COM、WinMM 或 UDP。\n");
            return 2;
        }
    }

    unsigned long input_number = 0UL;
    unsigned long output_number = 0UL;
    if (!parse_uint(argv[7], input_number) || input_number > 0xffffffffUL ||
        !parse_uint(argv[9], output_number) || output_number > 0xffffffffUL) {
        (void)bm_stderr(L"WaveIn/WaveOut 必须是本次枚举得到的非负设备 ID。\n");
        return 2;
    }
    const UINT input_id = static_cast<UINT>(input_number);
    const UINT output_id = static_cast<UINT>(output_number);
    const std::filesystem::path body_path(argv[5]);
    const std::filesystem::path status_path(argv[11]);
    if (!body_path.is_absolute() || !status_path.is_absolute()) {
        (void)bm_stderr(L"Y 素材与状态报告都必须使用绝对路径。\n");
        return 2;
    }

    wirex::bm::Profile profile{};
    ProfileSecretGuard secret_guard{profile};
    std::string callsign;
    std::string host_text;
    std::string call_kind_text;
    std::uint32_t gateway_id = 0U;
    std::uint32_t source_id = 0U;
    std::uint32_t talkgroup_id = 0U;
    std::uint32_t master_port = 0U;
    std::uint32_t slot_number = 0U;
    std::uint32_t color_code = 0U;
    wirex::bm::Endpoint endpoint{};
    wirex::dmr_call::CallConfig call_template{};
    auto tx_policy = wirex::bm_test_profile::TxPolicy::enabled;
    bool connection_ready = false;
    const auto finish_connection = [&]() -> bool {
        if (!selected_preset && !validate_manual_connection(callsign, gateway_id, source_id, talkgroup_id,
                slot_number, color_code, host_text, master_port, call_kind_text)) return false;
        profile.gateway_id = gateway_id;
        profile.callsign = callsign;
        wirex::bm::apply_network_metadata(profile);
        profile.color_code = static_cast<std::uint8_t>(color_code);
        call_template.source_id = source_id;
        call_template.destination_id = talkgroup_id;
        call_template.gateway_id = gateway_id;
        call_template.slot = slot_number == 1U ? wirex::dmr_call::Slot::ts1 : wirex::dmr_call::Slot::ts2;
        call_template.kind = call_kind_text == "G" ? wirex::dmr_call::CallKind::group
                                                    : wirex::dmr_call::CallKind::private_call;
        call_template.color_code = static_cast<std::uint8_t>(color_code);
        tx_policy = wirex::bm_test_profile::policy_for(call_template);
        return true;
    };
    const auto resolve_connection_and_read_password = [&]() -> bool {
        const bool resolved = selected_preset
            ? parse_ipv4_literal(host_text, endpoint.address)
            : resolve_master_ipv4(host_text, endpoint.address);
        if (!resolved) {
            (void)bm_stderr(L"Master IPv4 地址解析失败或超出 3.5 秒有界等待；没有打开设备。\n");
            return false;
        }
        endpoint.port = static_cast<std::uint16_t>(master_port);
        if (password_file_seen && !read_profile_password_file(password_file_path, profile.password)) {
            (void)bm_stderr(L"本机 BM 私有密码文件缺失或格式无效；要求 1–128 字节的可打印 ASCII，至多一个行尾；尚未打开设备。\n");
            return false;
        }
        return true;
    };
    if (selected_preset) {
        callsign.assign(selected_preset->callsign);
        host_text.assign(selected_preset->master_ipv4);
        call_kind_text = selected_preset->kind == wirex::dmr_call::CallKind::group ? "G" : "P";
        gateway_id = selected_preset->gateway_id;
        source_id = selected_preset->source_id;
        talkgroup_id = selected_preset->destination_id;
        master_port = selected_preset->master_port;
        slot_number = static_cast<std::uint32_t>(selected_preset->slot);
        color_code = selected_preset->color_code;
        connection_ready = finish_connection();
        if (!connection_ready) return 2;
    } else if (all_manual_fields) {
        std::array<std::string, 9U> fields{};
        const std::array<std::size_t, 9U> limits{{8U, 10U, 8U, 253U, 5U, 8U, 1U, 2U, 1U}};
        bool fields_valid = true;
        for (std::size_t index = 0U; index < fields.size(); ++index) {
            fields_valid = fields_valid && narrow_ascii_text(manual_field_values[index], fields[index], limits[index]);
        }
        fields_valid = fields_valid && parse_ascii_uint(fields[1], gateway_id) &&
            parse_ascii_uint(fields[2], source_id) && parse_ascii_uint(fields[4], master_port) &&
            parse_ascii_uint(fields[5], talkgroup_id) && parse_ascii_uint(fields[6], slot_number) &&
            parse_ascii_uint(fields[7], color_code);
        callsign = std::move(fields[0]);
        host_text = std::move(fields[3]);
        call_kind_text = std::move(fields[8]);
        if (!fields_valid || !validate_manual_connection(callsign, gateway_id, source_id, talkgroup_id,
                slot_number, color_code, host_text, master_port, call_kind_text)) {
            (void)bm_stderr(L"连接配置字段无效；没有打开 COM、WinMM 或 UDP。\n");
            return 2;
        }
        connection_ready = finish_connection();
        if (!connection_ready) return 2;
    }

    std::wstring device_path;
    if (!parse_port(argv[3], device_path)) {
        (void)bm_stderr(L"串口名无效；请输入明确的 COM 端口。\n");
        return 2;
    }

    HANDLE stdin_handle = GetStdHandle(STD_INPUT_HANDLE);
    DWORD console_mode = 0U;
    if (stdin_handle == nullptr || stdin_handle == INVALID_HANDLE_VALUE ||
        (ui_pipe ? GetFileType(stdin_handle) != FILE_TYPE_PIPE : !GetConsoleMode(stdin_handle, &console_mode))) {
        (void)bm_stderr(ui_pipe
            ? L"--ui-pipe 需要由 UI 管理器提供匿名输入管道。\n"
            : L"BM 联合测试入口需要可见的本机控制台。\n");
        return 2;
    }

    if (ui_pipe) {
        const auto inspection = inspect_ui_pipe(stdin_handle);
        if (inspection == UiPipeInspection::shutdown_requested) return 0;
        if (inspection == UiPipeInspection::invalid_input) {
            (void)bm_stderr(L"UI 控制管道只接受单独的 Q 换行或 EOF；没有启动设备。\n");
            return 2;
        }
        if (inspection == UiPipeInspection::failed) {
            (void)bm_stderr(L"无法检查 UI 控制管道；没有启动设备。\n");
            return 2;
        }
    }

    if (connection_ready && !resolve_connection_and_read_password()) return 2;

    std::ofstream status_file(status_path, std::ios::binary | std::ios::trunc);
    if (!status_file) {
        (void)bm_stderr(L"无法在指定目录创建状态报告；尚未打开设备。\n");
        return 2;
    }
    std::vector<std::uint8_t> y_body;
    if (!load_hri_y_template(body_path, y_body)) return 2;
    if (input_id >= waveInGetNumDevs() || output_id >= waveOutGetNumDevs() ||
        !prepare_hri_audio_devices(input_id, output_id)) {
        (void)bm_stderr(L"所选 WaveIn/WaveOut 设备未通过范围和 48 kHz PCM 能力查询。尚未打开音频流。\n");
        return 2;
    }
    if (!wave_endpoint_matches(true, input_id, expected_wavein_endpoint_id) ||
        !wave_endpoint_matches(false, output_id, expected_waveout_endpoint_id)) {
        (void)bm_stderr(L"所选WinMM设备的endpoint ID与本次启动器枚举结果不一致或无法查询；尚未打开音频流。\n");
        return 2;
    }
    WAVEINCAPSW input_caps{};
    WAVEOUTCAPSW output_caps{};
    if (waveInGetDevCapsW(input_id, &input_caps, sizeof(input_caps)) != MMSYSERR_NOERROR ||
        waveOutGetDevCapsW(output_id, &output_caps, sizeof(output_caps)) != MMSYSERR_NOERROR) {
        (void)bm_stderr(L"无法读取所选 WaveIn/WaveOut 设备信息；尚未打开设备。\n");
        return 2;
    }
    UINT exact_radio_output_id = 0U;
    if (!resolve_candidate_output(exact_radio_output_id, expected_waveout_endpoint_id) ||
        output_id != exact_radio_output_id) {
        (void)bm_stderr(L"本次选择的 WaveOut endpoint ID未唯一匹配到当前WinMM设备，或未通过PCM能力查询。\n");
        return 2;
    }

    if (!connection_ready) {
        if (!read_ascii_line(L"呼号（最多 8 个 ASCII 字符）：", callsign, 8U) ||
            !read_uint_line(L"Gateway ID（1..4294967295）：", gateway_id) ||
            !read_uint_line(L"本机 DMR Source ID（1..16777215）：", source_id) ||
            !read_uint_line(L"目标 Talkgroup ID 或单呼 Radio ID（1..16777215）：", talkgroup_id) ||
            !read_uint_line(L"Timeslot（1 或 2）：", slot_number) ||
            !read_uint_line(L"Color Code（0..15）：", color_code) ||
            !read_ascii_line(L"BM Master IPv4 地址或主机名（例如 master.example.net）：", host_text, 253U) ||
            !read_uint_line(L"BM Master UDP 端口（1..65535）：", master_port) ||
            !read_ascii_line(L"呼叫类型（G=组呼，P=单呼）：", call_kind_text, 1U) ||
            !validate_manual_connection(callsign, gateway_id, source_id, talkgroup_id,
                slot_number, color_code, host_text, master_port, call_kind_text)) {
            (void)bm_stderr(L"连接配置字段无效；没有打开 COM、WinMM 或 UDP。\n");
            return 2;
        }
        connection_ready = finish_connection();
        if (!connection_ready) return 2;
        if (!resolve_connection_and_read_password()) return 2;
    }

    wirex::ConsoleHandlerScope control_scope;
    if (!control_scope.start()) {
        (void)bm_stderr(L"无法注册控制台收尾处理器；没有打开设备。\n");
        return 2;
    }
    if (ui_pipe && !selected_preset && profile.password.empty()) {
        (void)bm_stderr(L"UI 管道模式必须从显式密码文件读取密码；尚未打开设备。\n");
        wipe_password(profile.password);
        return 2;
    }
    if (!ui_pipe && !selected_preset && profile.password.empty() && !read_hidden_password(profile.password, control_scope)) {
        (void)bm_stderr(L"隐藏密码输入已取消或无效；没有打开设备。\n");
        wipe_password(profile.password);
        return control_scope.cancel_requested() ? 0 : 2;
    }

    BmBridgeCounters counters{};
    counters.run_id = make_bridge_run_id();
    counters.audio_endpoints_validated = true;
    counters.rx_output_gain_milli = radio_playback_gain_milli;
    counters.tx_input_gain_milli = mic_transmit_gain_milli;
    const wirex::hri_session::Snapshot hri_preflight_snapshot{};
    const wirex::hri_ptt_gate::Snapshot ptt_preflight_snapshot{};
    if (!append_bridge_status(status_file, "preflight_passed", 0U, wirex::bm::Snapshot{},
                              hri_preflight_snapshot, ptt_preflight_snapshot, counters)) {
        wipe_password(profile.password);
        (void)bm_stderr(L"无法写入或刷新启动前状态报告；已清除隐藏密码，尚未打开设备。\n");
        return 2;
    }
    return run_bm_bridge(argv[3], body_path, input_id, output_id,
                         expected_wavein_endpoint_id, expected_waveout_endpoint_id, endpoint,
                         std::move(profile), call_template, tx_policy, manual_ptt,
                         ui_pipe, radio_playback_gain_milli, mic_transmit_gain_milli,
                         std::move(counters), status_file, control_scope);
}

int run_bm_bridge(const std::wstring& port_name, const std::filesystem::path& body_path,
                  UINT input_id, UINT output_id,
                  const std::wstring& expected_wavein_endpoint_id,
                  const std::wstring& expected_waveout_endpoint_id,
                  wirex::bm::Endpoint master,
                  wirex::bm::Profile profile, wirex::dmr_call::CallConfig call_template,
                  wirex::bm_test_profile::TxPolicy tx_policy,
                  bool manual_ptt,
                  bool ui_pipe,
                  std::uint32_t radio_playback_gain_milli,
                  std::uint32_t mic_transmit_gain_milli,
                  BmBridgeCounters counters,
                  std::ofstream& status_file, wirex::ConsoleHandlerScope& control_scope)
{
    using Clock = std::chrono::steady_clock;
    using StreamSession = wirex::hri_stream_session::Session;
    using StreamAction = wirex::hri_stream_session::Action;
    using StreamActionKind = wirex::hri_stream_session::ActionKind;
    using StreamPhase = wirex::hri_stream_session::Phase;
    using StreamReason = wirex::hri_stream_session::Reason;
    using Pipeline = wirex::bm_voice::BmVoicePipeline;
    using PipelineEventKind = wirex::bm_voice::EventKind;
    using HriPhase = wirex::hri_session::Phase;
    using PttAction = wirex::hri_ptt_gate::Action;
    using PttGate = wirex::hri_ptt_gate::Gate;
    using PttLevel = wirex::hri_ptt_gate::Level;
    const bool continuous_run = !manual_ptt;
    ProfileSecretGuard secret_guard{profile};
    const HANDLE ui_pipe_handle = ui_pipe ? GetStdHandle(STD_INPUT_HANDLE) : INVALID_HANDLE_VALUE;
    wirex::ui_control::Parser ui_control_parser;
    PttGate ptt_gate;
    std::function<void(PttAction, std::string_view)> handle_ptt_gate_action;
    std::function<void()> synchronize_ptt_gate;
    std::function<void(const wirex::hri_session::PttObservation&)> process_ptt_observation;
    std::string failure_reason;
    bool failed = false;
    bool status_report_failed = false;
    bool shutdown_requested = false;
    bool cleanup_forced = false;
    bool hri_active = false;
    bool hri_ready = false;
    bool radio_input_open = false;
    bool radio_output_open = false;
    bool pending_receive_start = false;
    bool pending_receive_ended = false;
    bool pending_playback_drain = false;
    bool downlink_blocked = false;
    bool t_key_down = false;
    bool q_key_down = false;
    std::string shutdown_reason;
    std::optional<Clock::time_point> cleanup_deadline;
    const auto run_started = Clock::now();
    auto elapsed_ms = [&]() -> std::uint64_t {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - run_started).count();
        return elapsed < 0 ? 0U : static_cast<std::uint64_t>(elapsed);
    };
    auto set_failure = [&](std::string_view reason) {
        if (failure_reason.empty()) failure_reason.assign(reason);
        failed = true;
    };
    std::vector<std::uint8_t> y_body;
    if (!load_hri_y_template(body_path, y_body)) {
        failure_reason = "y_template_invalid";
        failed = true;
        return 2;
    }
    const auto start_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    const auto stop_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(0, 1, 9U);
    const auto start_frame_result = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(start_body.begin(), start_body.end())});
    const auto stop_frame_result = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(stop_body.begin(), stop_body.end())});
    if (!start_frame_result || !stop_frame_result) {
        (void)bm_stderr(L"Could not build the pinned HRI speaker start/stop candidates.\n");
        return 2;
    }

    std::unique_ptr<Pipeline> pipeline;
    std::unique_ptr<StreamSession> stream_session;
    try {
        pipeline = std::make_unique<Pipeline>();
        stream_session = std::make_unique<StreamSession>(start_frame_result.bytes, stop_frame_result.bytes,
            wirex::hri_stream_session::Config{wirex::hri_stream_session::default_start_record_timeout_ms,
                wirex::hri_stream_session::default_stop_record_timeout_ms,
                wirex::hri_stream_session::max_call_window_ms});
    } catch (...) {
        (void)bm_stderr(L"Bridge software state allocation failed before devices were opened.\n");
        return 2;
    }
    wirex::bm_voice::ReceiveFilter receive_filter{};
    receive_filter.destination_id = call_template.kind == wirex::dmr_call::CallKind::group
        ? call_template.destination_id : call_template.source_id;
    receive_filter.match_slot = true;
    receive_filter.slot = call_template.slot;
    receive_filter.match_call_kind = true;
    receive_filter.call_kind = call_template.kind;
    if (pipeline->set_receive_filter(receive_filter) != wirex::bm_voice::Error::none) {
        (void)bm_stderr(L"The selected DMR receive filter is invalid.\n");
        return 2;
    }

    if (ui_pipe) {
        const auto inspection = inspect_ui_pipe(ui_pipe_handle);
        if (inspection == UiPipeInspection::shutdown_requested) return 0;
        if (inspection == UiPipeInspection::invalid_input) {
            (void)bm_stderr(L"UI 控制管道只接受单独的 Q 换行或 EOF；没有启动设备。\n");
            return 2;
        }
        if (inspection == UiPipeInspection::failed) {
            (void)bm_stderr(L"无法检查 UI 控制管道；没有启动设备。\n");
            return 2;
        }
    }

    wirex::bm::Session bm_session;
    if (!bm_session.start(std::move(profile), master, 0U)) {
        (void)bm_stderr(L"BM profile validation failed; no socket or device was opened.\n");
        return 2;
    }
    wirex::bm::UdpTransport transport;
    WinHandle port;
    WaveInput radio_input;
    WaveOutput radio_output;
    wirex::hri_session::Session hri_session(std::move(y_body),
        wirex::hri_session::Config{wirex::session_timing::active_window_ms, continuous_run});
    wirex::hri_session::Snapshot hri_state{};
    std::wstring device_path;
    if (ui_pipe) {
        const auto inspection = inspect_ui_pipe(ui_pipe_handle);
        if (inspection == UiPipeInspection::shutdown_requested) {
            bm_session.stop(0U);
            return 0;
        }
        if (inspection == UiPipeInspection::invalid_input || inspection == UiPipeInspection::failed) {
            bm_session.stop(0U);
            (void)bm_stderr(inspection == UiPipeInspection::invalid_input
                ? L"UI 控制管道只接受单独的 Q 换行或 EOF；没有打开设备。\n"
                : L"无法检查 UI 控制管道；没有打开设备。\n");
            return 2;
        }
    }
    if (!parse_port(port_name, device_path)) {
        failure_reason = "port_name_invalid";
        failed = true;
    } else {
        port.reset(CreateFileW(device_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!port.valid() || !configure_serial(port.get(), false)) {
            failure_reason = "serial_open_or_configure_failed";
            failed = true;
        } else {
            COMMTIMEOUTS timeouts{};
            timeouts.ReadIntervalTimeout = 5U;
            timeouts.ReadTotalTimeoutConstant = 10U;
            timeouts.WriteTotalTimeoutConstant = 100U;
            if (!SetCommTimeouts(port.get(), &timeouts)) {
                failure_reason = "serial_timeout_config_failed";
                failed = true;
            }
        }
    }
    std::uint64_t discarded_serial_bytes = 0U;
    if (!failed && !pre_drain_hri_serial(port.get(), discarded_serial_bytes)) {
        failure_reason = "serial_pre_drain_failed";
        failed = true;
    }
    if (!failed && !transport.open(master)) {
        failure_reason = "udp_open_failed";
        failed = true;
    }
    if (failed) {
        bm_session.stop(0U);
        const HANDLE raw = port.release();
        if (raw != nullptr && raw != INVALID_HANDLE_VALUE) (void)CloseHandle(raw);
        (void)transport.close();
        std::wstring failure_text = L"Bridge startup failed before HRI or BM payload traffic: ";
        failure_text.append(failure_reason.begin(), failure_reason.end());
        failure_text.append(L".\n");
        (void)bm_stderr(failure_text);
        if (!append_bridge_status(status_file, failure_reason, 0U, bm_session.snapshot(),
                                  hri_state, ptt_gate.snapshot(), counters)) {
            (void)bm_stderr(L"无法写入或刷新启动失败状态报告。\n");
        }
        return 2;
    }

    auto status = [&](std::string_view event) {
        if (status_report_failed) return;
        counters.hri_serial_open = port.valid();
        counters.hri_ready = hri_ready;
        counters.hri_y_zero_ready = hri_state.y_zero_acknowledged;
        counters.wavein_open = radio_input_open;
        counters.waveout_open = radio_output_open;
        const auto snapshot = bm_session.snapshot();
        if (!append_bridge_status(status_file, event, elapsed_ms(), snapshot, hri_state,
                                  ptt_gate.snapshot(), counters)) {
            status_report_failed = true;
            set_failure("status_report_write_failed");
            (void)bm_stderr(L"运行状态报告写入或刷新失败；将执行有界收尾并以退出码 2 结束。\n");
        }
    };

    std::uint64_t next_runtime_snapshot_ms = 1000U;

    auto last_logged_bm_snapshot = bm_session.snapshot();
    auto log_bm_transition = [&](std::string_view event) {
        const auto current = bm_session.snapshot();
        if (current.state == last_logged_bm_snapshot.state &&
            current.last_failure == last_logged_bm_snapshot.last_failure &&
            current.consecutive_failures == last_logged_bm_snapshot.consecutive_failures) return;
        status(event);
        last_logged_bm_snapshot = current;
    };

    bool serial_failed = false;
    bool network_ready_seen = false;
    bool bm_ever_ready = false;
    bool operator_ready_instructions_shown = false;
    bool shutdown_tx_terminator_pending = false;
    bool shutdown_tx_terminator_reported = false;
    std::array<std::uint8_t, 4U> active_tx_stream_id{};
    std::array<std::uint8_t, 4U> shutdown_tx_stream_id{};
    auto maybe_show_operator_ready_instructions = [&]() {
        if (operator_ready_instructions_shown || shutdown_requested || failed || !network_ready_seen ||
            bm_session.snapshot().state != wirex::bm::State::ready || !hri_ready ||
            !hri_state.y_zero_acknowledged) {
            return;
        }
        operator_ready_instructions_shown = true;
        if (wirex::bm_test_profile::permits_transmit(tx_policy)) {
            if (!manual_ptt) {
                (void)bm_stdout(u8"已连接并就绪。先松开一次手咪 PTT，再按住手咪讲话；松开后等待 BM 回声。按 Q 停止并退出。\n");
            } else if (call_template.kind == wirex::dmr_call::CallKind::private_call &&
                (call_template.destination_id == 460997U || call_template.destination_id == 9990U)) {
                (void)bm_stdout(u8"已连接并就绪。按 T 开始 BM 上行，按住手咪讲话；松开后按 T 结束本次上行并等待回声。按 Q 退出。\n");
            } else {
                (void)bm_stdout(u8"已连接并就绪。按 T 开始 BM 上行，按住手咪讲话；松开后按 T 结束本次上行。按 Q 退出。\n");
            }
        } else if (call_template.kind == wirex::dmr_call::CallKind::group &&
                   call_template.destination_id == 91U) {
            if (call_template.slot == wirex::dmr_call::Slot::ts1) {
                (void)bm_stdout(u8"已连接并就绪。请在 BM SelfCare 为当前 Gateway 的 TS1 添加 TG91 静态订阅，然后在电台扬声器收听。按 Q 停止并退出。\n");
            } else {
                (void)bm_stdout(u8"已连接并就绪。请在 BM SelfCare 为当前 Gateway 的 TS2 添加 TG91 静态订阅，然后在电台扬声器收听。按 Q 停止并退出。\n");
            }
        } else {
            (void)bm_stdout(u8"已连接并就绪。可在所选电台扬声器收听 BM 组呼。按 Q 停止并退出。\n");
        }
    };
    auto stop_tx_input = [&]() -> bool {
        if (!radio_input_open) return !radio_input.close_failed();
        const bool closed = radio_input.close();
        radio_input_open = radio_input.is_open();
        return closed;
    };
    auto tx_start_permitted = [&]() {
        if (!wirex::bm_test_profile::permits_transmit(tx_policy) || shutdown_requested || failed ||
            !network_ready_seen || bm_session.snapshot().state != wirex::bm::State::ready ||
            !hri_ready || !hri_state.y_zero_acknowledged || hri_state.phase == HriPhase::stopped ||
            downlink_blocked || radio_input_open) {
            return false;
        }
        const auto pipeline_state = pipeline->snapshot();
        const auto stream_state = stream_session->snapshot();
        return pipeline_state.tx_state == wirex::bm_voice::TxState::idle &&
            pipeline_state.rx_state == wirex::bm_voice::RxState::idle &&
            stream_state.phase == StreamPhase::idle;
    };
    auto start_tx_call = [&]() {
        if (!tx_start_permitted()) {
            ++counters.rejected_calls;
            status("tx_start_rejected_busy_or_endpoint_not_ready");
            return false;
        }
        auto call = call_template;
        const auto random_result = BCryptGenRandom(nullptr, call.stream_id.data(),
            static_cast<ULONG>(call.stream_id.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        if (random_result < 0) {
            set_failure("stream_id_random_failed");
            return false;
        }
        const auto begin_result = wirex::bm_test_profile::begin_tx(tx_policy, *pipeline, call,
            wirex::bm_voice::Readiness{network_ready_seen, hri_ready}, Clock::now());
        if (begin_result.status != wirex::bm_test_profile::TxStartStatus::started) {
            ++counters.rejected_calls;
            status(begin_result.status == wirex::bm_test_profile::TxStartStatus::denied_receive_only
                ? "tx_start_rejected_receive_only_policy" : "tx_start_rejected_by_pipeline");
            return false;
        }
        if (!radio_input.open(input_id, &expected_wavein_endpoint_id)) {
            pipeline->cancel_tx();
            ++counters.rejected_calls;
            status("radio_wavein_open_failed_tx_cancelled");
            return false;
        }
        active_tx_stream_id = call.stream_id;
        radio_input_open = true;
        if (!manual_ptt) ++counters.ptt_tx_starts;
        status(manual_ptt ? "tx_started_explicitly_by_t_key" : "tx_started_from_radio_ptt_down");
        (void)bm_stdout(u8"上行已开始，请继续讲话。\n");
        return true;
    };
    auto consume_tx_wave_buffer = [&](WaveInput::Buffer& buffer, bool requeue) {
        const DWORD bytes = buffer.header.dwBytesRecorded;
        bool succeeded = bytes <= buffer.header.dwBufferLength && bytes % sizeof(std::int16_t) == 0U;
        if (succeeded) {
            const auto samples = static_cast<std::size_t>(bytes / sizeof(std::int16_t));
            if (samples != 0U) {
                const auto gain = wirex::pcm_gain::apply(buffer.samples.data(), samples, mic_transmit_gain_milli);
                succeeded = gain.valid;
                if (succeeded) {
                    const auto pushed = pipeline->push_tx_audio(buffer.samples.data(), samples, Clock::now());
                    succeeded = static_cast<bool>(pushed);
                    if (succeeded) {
                        counters.tx_audio_samples += samples;
                        wirex::pcm_gain::accumulate(counters.tx_pcm_input_stats, gain.before);
                        wirex::pcm_gain::accumulate(counters.tx_pcm_gained_stats, gain.after);
                        if (gain.clipped_samples >
                            std::numeric_limits<std::uint64_t>::max() - counters.tx_pcm_clipped_samples) {
                            counters.tx_pcm_clipped_samples = std::numeric_limits<std::uint64_t>::max();
                        } else {
                            counters.tx_pcm_clipped_samples += gain.clipped_samples;
                        }
                    }
                }
            }
        }
        buffer.header.dwBytesRecorded = 0U;
        if (requeue && succeeded) {
            return radio_input.requeue(buffer) == MMSYSERR_NOERROR;
        }
        secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
        return succeeded;
    };
    auto finish_tx_capture = [&]() {
        if (!radio_input_open) return !radio_input.close_failed();
        bool succeeded = radio_input.stop_capture();
        if (succeeded) {
            const DWORD wait_result = WaitForSingleObject(radio_input.event(), 100U);
            if (wait_result == WAIT_FAILED) succeeded = false;
            for (auto& buffer : radio_input.buffers()) {
                if ((buffer.header.dwFlags & WHDR_DONE) == 0U) continue;
                if (!consume_tx_wave_buffer(buffer, false)) succeeded = false;
            }
        }
        const bool closed = radio_input.close();
        radio_input_open = radio_input.is_open();
        return succeeded && closed;
    };
    auto end_tx_call = [&]() {
        if (!finish_tx_capture()) {
            pipeline->cancel_tx();
            set_failure("wavein_tx_release_cleanup_failed");
            return false;
        }
        const auto state = pipeline->snapshot();
        if (state.tx_state != wirex::bm_voice::TxState::active) {
            if (state.tx_state != wirex::bm_voice::TxState::idle) pipeline->cancel_tx();
            set_failure("tx_release_without_active_call");
            return false;
        }
        const auto ended = pipeline->end_tx(Clock::now());
        if (ended != wirex::bm_voice::Error::none) {
            pipeline->cancel_tx();
            set_failure("tx_audio_flush_failed");
            return false;
        }
        status("tx_audio_draining_after_radio_ptt_release");
        return true;
    };
    handle_ptt_gate_action = [&](PttAction action, std::string_view event) {
        if (action == PttAction::start_tx) {
            if (!start_tx_call()) {
                ++counters.ptt_start_rejections;
                ptt_gate.start_failed();
            } else if (!manual_ptt && !ptt_gate.start_succeeded(elapsed_ms())) {
                (void)stop_tx_input();
                pipeline->cancel_tx();
                ptt_gate.start_failed();
                set_failure("ptt_call_timer_start_failed");
            }
            return;
        }
        if (action == PttAction::end_tx) {
            if (end_tx_call()) {
                ++counters.ptt_tx_ends;
                if (call_template.kind == wirex::dmr_call::CallKind::private_call &&
                    (call_template.destination_id == 460997U || call_template.destination_id == 9990U)) {
                    (void)bm_stdout(u8"上行已结束，请等待 BM 回声。\n");
                } else {
                    (void)bm_stdout(u8"上行已结束，可继续收听。\n");
                }
            } else {
                ptt_gate.disarm_until_release();
            }
            return;
        }
        if (action == PttAction::call_timeout) {
            const bool capture_closed = finish_tx_capture();
            if (!capture_closed) set_failure("wavein_ptt_call_timeout_cleanup_failed");
            const auto state = pipeline->snapshot();
            if (state.tx_state != wirex::bm_voice::TxState::idle) {
                if (network_ready_seen && bm_session.snapshot().state == wirex::bm::State::ready) {
                    if (pipeline->stop_tx(Clock::now()) != wirex::bm_voice::Error::none) {
                        pipeline->cancel_tx();
                        set_failure("ptt_call_timeout_terminator_failed");
                    }
                } else {
                    pipeline->cancel_tx();
                }
            }
            ptt_gate.disarm_until_release();
            ++counters.ptt_tx_timeouts;
            status("radio_ptt_call_120s_limit_reached_release_required");
            return;
        }
        if (action != PttAction::abort_tx) return;
        if (!stop_tx_input()) set_failure("wavein_ptt_abort_cleanup_failed");
        const auto state = pipeline->snapshot();
        if (state.tx_state != wirex::bm_voice::TxState::idle) {
            if (bm_session.snapshot().state == wirex::bm::State::ready) {
                if (pipeline->stop_tx(Clock::now()) != wirex::bm_voice::Error::none) {
                    pipeline->cancel_tx();
                    set_failure("ptt_abort_terminator_failed");
                }
            } else {
                pipeline->cancel_tx();
            }
        }
        ptt_gate.disarm_until_release();
        status(event);
    };
    synchronize_ptt_gate = [&]() {
        if (manual_ptt) return;
        const bool ready = !shutdown_requested && !failed && !status_report_failed &&
            wirex::bm_test_profile::permits_transmit(tx_policy) && network_ready_seen &&
            bm_session.snapshot().state == wirex::bm::State::ready && hri_ready &&
            hri_state.y_zero_acknowledged && hri_state.phase != HriPhase::stopped;
        handle_ptt_gate_action(ptt_gate.set_ready(ready), "ptt_aborted_endpoint_not_ready");
    };
    process_ptt_observation = [&](const wirex::hri_session::PttObservation& observation) {
        if (manual_ptt || !observation.y_zero_acknowledged) return;
        synchronize_ptt_gate();
        PttLevel level = PttLevel::unknown;
        switch (observation.level) {
        case wirex::hri_session::PttLevel::pressed: level = PttLevel::pressed; break;
        case wirex::hri_session::PttLevel::released: level = PttLevel::released; break;
        case wirex::hri_session::PttLevel::unknown: level = PttLevel::unknown; break;
        }
        const bool ptt_level_changed = counters.last_ptt_level != observation.level;
        ++counters.ptt_observations;
        counters.last_ptt_level = observation.level;
        if (observation.level == wirex::hri_session::PttLevel::unknown) {
            ++counters.ptt_unknown_observations;
        }
        const bool can_start = tx_start_permitted();
        const auto before = ptt_gate.snapshot();
        const auto action = ptt_gate.observe(level, can_start);
        if (level == PttLevel::pressed && !before.pressed_latched && !can_start) {
            ++counters.ptt_start_rejections;
            ++counters.rejected_calls;
            status("radio_ptt_down_rejected_busy_release_required");
        }
        if (action == PttAction::abort_tx) {
            handle_ptt_gate_action(action, "tx_aborted_unknown_radio_ptt_state");
        } else {
            handle_ptt_gate_action(action, "radio_ptt_action");
        }
        if (ptt_level_changed) status("radio_ptt_level_changed");
    };
    auto is_shutdown_terminator = [&](const wirex::dmr_call::TxPacket& packet) {
        return shutdown_tx_terminator_pending &&
            packet.kind == wirex::dmr_call::PacketKind::terminator_with_lc &&
            packet.datagram.stream_id == shutdown_tx_stream_id;
    };
    auto report_shutdown_terminator_not_sent = [&](std::string_view reason) {
        if (!shutdown_tx_terminator_pending || shutdown_tx_terminator_reported) return;
        shutdown_tx_terminator_pending = false;
        shutdown_tx_terminator_reported = true;
        status(reason);
    };

    std::function<void(wirex::hri_stream_session::Update)> service_stream_update;
    service_stream_update = [&](wirex::hri_stream_session::Update update) {
        std::deque<StreamAction> pending;
        for (auto& action : update.actions) pending.push_back(std::move(action));
        while (!pending.empty()) {
            auto action = std::move(pending.front());
            pending.pop_front();
            switch (action.kind) {
            case StreamActionKind::write_start_candidate:
            case StreamActionKind::write_stop_candidate: {
                const auto now_ms = elapsed_ms();
                const auto attempted = stream_session->write_attempted(action.write_id, now_ms);
                if (attempted.error != wirex::hri_stream_session::Error::none) {
                    set_failure("hri_stream_write_state_error");
                    break;
                }
                DWORD written = 0U;
                const BOOL wrote = WriteFile(port.get(), action.frame.data(),
                    static_cast<DWORD>(action.frame.size()), &written, nullptr);
                const bool full = wrote != FALSE && written == action.frame.size();
                if (!full) {
                    serial_failed = true;
                    set_failure("hri_stream_serial_write_failed");
                }
                auto completed = stream_session->write_completed(action.write_id, full, elapsed_ms());
                for (auto& follow_up : completed.actions) pending.push_back(std::move(follow_up));
                if (completed.error != wirex::hri_stream_session::Error::none) {
                    set_failure("hri_stream_write_completion_error");
                }
                status(action.kind == StreamActionKind::write_start_candidate ? "hri_t3_write" : "hri_t0_write");
                break;
            }
            case StreamActionKind::playback_permitted: {
                const auto result = pipeline->playback_ready(Clock::now());
                if (result != wirex::bm_voice::Error::none) {
                    set_failure("pipeline_playback_start_failed");
                    downlink_blocked = true;
                    service_stream_update(stream_session->cancel(StreamReason::transport_failed, elapsed_ms()));
                } else {
                    status("hri_t3_observed_playback_enabled");
                }
                break;
            }
            case StreamActionKind::cancel_playback:
                pipeline->cancel_rx();
                pending_receive_start = false;
                pending_playback_drain = false;
                if (radio_output_open) {
                    const bool closed = radio_output.close();
                    radio_output_open = false;
                    if (!closed) set_failure("waveout_cancel_cleanup_failed");
                }
                status("playback_cancelled_and_queue_cleared");
                break;
            case StreamActionKind::call_finished: {
                const auto state = stream_session->snapshot();
                ++counters.calls_ended;
                if (state.reason == StreamReason::none && state.stop_write_succeeded &&
                    state.stop_t_record_observed) {
                    status("downlink_call_drained_t0_observed");
                } else {
                    if (!state.stop_write_succeeded || !state.stop_t_record_observed ||
                        state.reason == StreamReason::stop_write_failed ||
                        state.reason == StreamReason::stop_record_timeout) {
                        downlink_blocked = true;
                    }
                    if (state.reason == StreamReason::stop_write_failed) {
                        set_failure("hri_t0_write_failed");
                    }
                    if (state.stop_write_attempted && state.stop_write_succeeded &&
                        !state.stop_t_record_observed) {
                        set_failure("hri_t0_record_timeout");
                    }
                    status("downlink_call_bounded_cleanup_incomplete");
                }
                if (stream_session->snapshot().phase == StreamPhase::faulted) {
                    downlink_blocked = true;
                }
                break;
            }
            }
        }
    };

    auto apply_hri_update = [&](wirex::hri_session::Update update) {
        hri_state = update.state;
        bool command_writes_succeeded = true;
        for (const auto& command : update.commands) {
            DWORD written = 0U;
            const BOOL wrote = WriteFile(port.get(), command.frame.data(),
                static_cast<DWORD>(command.frame.size()), &written, nullptr);
            const bool full = wrote != FALSE && written == command.frame.size();
            hri_state = hri_session.write_completed(command.id, full, elapsed_ms()).state;
            if (!full) {
                serial_failed = true;
                command_writes_succeeded = false;
                set_failure("hri_control_serial_write_failed");
                break;
            }
        }
        if (update.state.phase == HriPhase::stopped &&
            update.state.stop_reason != wirex::hri_session::StopReason::none &&
            update.state.stop_reason != wirex::hri_session::StopReason::caller_stopped) {
            set_failure("hri_control_session_stopped");
        }
        if (hri_state.y_zero_acknowledged && !hri_ready && hri_state.phase != HriPhase::stopped) {
            if (!radio_output.open(output_id, &expected_waveout_endpoint_id)) {
                set_failure("radio_waveout_open_failed");
            } else {
                radio_output_open = true;
                hri_ready = true;
                status("hri_y0_observed_radio_speaker_ready");
                maybe_show_operator_ready_instructions();
            }
        }
        synchronize_ptt_gate();
        if (command_writes_succeeded) {
            for (const auto& observation : update.ptt_observations) {
                process_ptt_observation(observation);
            }
        }
    };

    auto begin_stream_for_pending_rx = [&]() {
        if (!pending_receive_start || !hri_ready || shutdown_requested) return;
        const auto pipeline_state = pipeline->snapshot();
        if (pipeline_state.rx_state == wirex::bm_voice::RxState::idle) {
            pending_receive_start = false;
            pending_receive_ended = false;
            return;
        }
        const auto stream_state = stream_session->snapshot();
        if (downlink_blocked || stream_state.phase != StreamPhase::idle || !network_ready_seen) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            if (stream_state.phase != StreamPhase::idle && stream_state.phase != StreamPhase::faulted) {
                // Receiver替换流时旧播放队列已不再属于当前通话；复位电台输出并收尾旧T会话。
                service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
            }
            if (radio_output_open) {
                if (!radio_output.close()) set_failure("radio_waveout_busy_cleanup_failed");
                radio_output_open = false;
            }
            status("downlink_call_rejected_busy_or_hri_cleanup_incomplete");
            return;
        }
        if (!radio_output_open) {
            if (!hri_state.y_zero_acknowledged ||
                !radio_output.open(output_id, &expected_waveout_endpoint_id)) {
                ++counters.rejected_calls;
                pending_receive_start = false;
                pending_receive_ended = false;
                pipeline->cancel_rx();
                downlink_blocked = true;
                set_failure("radio_waveout_reopen_failed");
                status("downlink_rejected_without_ready_radio_waveout");
                return;
            }
            radio_output_open = true;
            status("radio_waveout_reopened_after_network_reconnect");
        }
        const auto now_ms = elapsed_ms();
        if (!continuous_run && now_ms >= bm_bridge_window_ms) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            return;
        }
        const auto call_window_ms = continuous_run ? wirex::hri_stream_session::max_call_window_ms
            : std::min(wirex::hri_stream_session::max_call_window_ms, bm_bridge_window_ms - now_ms);
        auto update = stream_session->begin_call(now_ms, call_window_ms);
        pending_receive_start = false;
        const bool ended_before_hri_start = pending_receive_ended;
        pending_receive_ended = false;
        if (update.state.phase == StreamPhase::faulted) {
            ++counters.rejected_calls;
            downlink_blocked = true;
        } else {
            ++counters.calls_started;
        }
        service_stream_update(std::move(update));
        // BM 可以在电台首次 T3 之前结束短呼叫，保留这个顺序并在许可播放后排空尾音。
        if (ended_before_hri_start && stream_session->snapshot().phase != StreamPhase::idle &&
            stream_session->snapshot().phase != StreamPhase::faulted) {
            service_stream_update(stream_session->network_ended(elapsed_ms()));
        }
    };

    auto drain_pipeline_events = [&]() {
        while (const auto event = pipeline->take_event()) {
            switch (event->kind) {
            case PipelineEventKind::receive_started:
                pending_receive_start = true;
                begin_stream_for_pending_rx();
                break;
            case PipelineEventKind::network_ended:
                if (stream_session->snapshot().phase != StreamPhase::idle &&
                    stream_session->snapshot().phase != StreamPhase::faulted) {
                    service_stream_update(stream_session->network_ended(elapsed_ms()));
                } else if (pending_receive_start) {
                    pending_receive_ended = true;
                }
                break;
            case PipelineEventKind::playback_drained:
                pending_playback_drain = true;
                break;
            case PipelineEventKind::receive_cancelled:
                break;
            case PipelineEventKind::playback_start_timeout:
                pending_receive_start = false;
                pending_receive_ended = false;
                ++counters.rejected_calls;
                status("hri_t3_start_window_expired_media_cleared");
                break;
            case PipelineEventKind::collision:
                ++counters.rejected_calls;
                if (stream_session->snapshot().phase != StreamPhase::idle &&
                    stream_session->snapshot().phase != StreamPhase::faulted) {
                    service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
                }
                status("half_duplex_collision_rejected");
                break;
            case PipelineEventKind::queue_overflow:
                ++counters.rejected_calls;
                set_failure("pipeline_queue_bound_reached");
                break;
            }
        }
    };

    auto begin_shutdown = [&](std::string_view reason) {
        if (shutdown_requested) return;
        shutdown_requested = true;
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        shutdown_reason.assign(reason);
        cleanup_deadline = Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms};
        pending_receive_start = false;
        pending_receive_ended = false;
        (void)stop_tx_input();
        const auto now_ms = elapsed_ms();
        if (pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle) {
            shutdown_tx_stream_id = active_tx_stream_id;
            shutdown_tx_terminator_pending = true;
            shutdown_tx_terminator_reported = false;
            if (bm_session.snapshot().state == wirex::bm::State::ready) {
                const auto stopped = pipeline->stop_tx(Clock::now());
                if (stopped != wirex::bm_voice::Error::none) {
                    pipeline->cancel_tx();
                    set_failure("tx_exit_terminator_failed");
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_pipeline_rejected");
                } else {
                    status("shutdown_tx_terminator_queued_for_udp_send");
                }
            } else {
                pipeline->cancel_tx();
                report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_network_lost");
            }
        }
        if (hri_active && hri_state.phase != HriPhase::stopped) {
            hri_state = hri_session.cancel().state;
            hri_active = false;
        }
        const auto stream_phase = stream_session->snapshot().phase;
        if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
            service_stream_update(stream_session->cancel(StreamReason::cancelled, now_ms));
        } else if (pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle) {
            pipeline->cancel_rx();
            if (radio_output_open) {
                if (!radio_output.close()) set_failure("radio_waveout_shutdown_cleanup_failed");
                radio_output_open = false;
            }
        }
        status("shutdown_requested");
    };

    status("started");
    if (!status_report_failed) {
        if (wirex::bm_test_profile::permits_transmit(tx_policy)) {
            if (manual_ptt) {
                (void)bm_stdout(u8"诊断模式：按 T 开始或结束 BM 上行。按 Q 停止并退出。\n");
            } else {
                (void)bm_stdout(u8"等待 BM 与电台连接。\n"
                                u8"连接后按住手咪讲话；松开后等待回声。按 Q 或 Ctrl+C 停止并退出。\n");
            }
        } else {
            if (continuous_run) {
                (void)bm_stdout(u8"等待 BM 与电台连接。\n"
                                u8"连接后在所选电台扬声器收听 BM 组呼。按 Q 或 Ctrl+C 停止并退出。\n");
            } else {
                (void)bm_stdout(u8"等待 BM 与电台连接。\n"
                                u8"连接后在所选电台扬声器收听 BM 组呼。按 Q 或 Ctrl+C 停止并退出。\n");
            }
        }
    } else {
        begin_shutdown("status_report_write_failed");
    }

    auto handle_network_loss = [&](std::string_view reason) {
        const bool was_ready = network_ready_seen;
        network_ready_seen = false;
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        operator_ready_instructions_shown = false;
        if (was_ready) ++counters.reconnects;
        (void)stop_tx_input();
        pipeline->cancel_tx();
        pipeline->cancel_rx();
        pending_receive_start = false;
        pending_receive_ended = false;
        pending_playback_drain = false;
        if (radio_output_open) {
            if (!radio_output.close()) set_failure("radio_waveout_network_cleanup_failed");
            radio_output_open = false;
        }
        const auto phase = stream_session->snapshot().phase;
        if (shutdown_tx_terminator_pending) {
            report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_network_lost");
        }
        if (phase != StreamPhase::idle && phase != StreamPhase::faulted) {
            service_stream_update(stream_session->cancel(StreamReason::network_lost, elapsed_ms()));
        }
        status(reason);
        last_logged_bm_snapshot = bm_session.snapshot();
    };

    auto drain_bm_outbound = [&]() {
        for (auto& packet : bm_session.take_outbound()) {
            if (packet.kind == wirex::bm::PacketKind::control) ++counters.control_tx_attempted;
            if (packet.kind == wirex::bm::PacketKind::application &&
                !wirex::bm_test_profile::permits_transmit(tx_policy)) {
                ++counters.rejected_calls;
                status("bm_dmrd_packet_rejected_receive_only_policy");
                continue;
            }
            const bool is_rptcl = packet.kind == wirex::bm::PacketKind::control &&
                packet.bytes.size() == 9U && packet.bytes[0U] == 'R' && packet.bytes[1U] == 'P' &&
                packet.bytes[2U] == 'T' && packet.bytes[3U] == 'C' && packet.bytes[4U] == 'L';
            bool is_shutdown_terminator = false;
            if (shutdown_tx_terminator_pending && packet.kind == wirex::bm::PacketKind::application) {
                const auto decoded = wirex::dmrd::decode(packet.bytes.data(), packet.bytes.size());
                is_shutdown_terminator = decoded && decoded.datagram.stream_id == shutdown_tx_stream_id &&
                    (decoded.datagram.flags & 0x3FU) == 0x22U;
            }
            if (!transport.is_open() || !transport.send(packet.bytes.data(), packet.bytes.size())) {
                if (is_shutdown_terminator) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_udp_send_failed");
                }
                if (is_rptcl) status("bm_rptcl_local_udp_send_failed");
                transport.close();
                bm_session.transport_lost(elapsed_ms());
                log_bm_transition("bm_state_or_failure_changed_after_control_send_failure");
                handle_network_loss("bm_udp_send_lost");
                return false;
            }
            if (packet.kind == wirex::bm::PacketKind::control) ++counters.control_tx_succeeded;
            if (is_shutdown_terminator) {
                shutdown_tx_terminator_pending = false;
                shutdown_tx_terminator_reported = true;
                status("shutdown_tx_terminator_udp_send_succeeded");
            }
            if (is_rptcl) status("bm_rptcl_local_udp_send_succeeded");
            if (packet.kind == wirex::bm::PacketKind::application) ++counters.tx_datagrams;
        }
        return true;
    };

    auto pump_tx_datagrams = [&]() {
        while (auto packet = pipeline->take_outbound()) {
            if (!wirex::bm_test_profile::permits_transmit(tx_policy)) {
                pipeline->cancel_tx();
                (void)stop_tx_input();
                ptt_gate.disarm_until_release();
                ++counters.rejected_calls;
                status("tx_datagram_rejected_receive_only_policy");
                return;
            }
            if (bm_session.snapshot().state != wirex::bm::State::ready) {
                if (is_shutdown_terminator(*packet)) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_network_lost");
                }
                pipeline->cancel_tx();
                (void)stop_tx_input();
                (void)ptt_gate.set_ready(false);
                ptt_gate.disarm_until_release();
                status("tx_stopped_bm_not_ready");
                return;
            }
            const auto encoded = wirex::dmrd::encode(packet->datagram);
            if (!encoded || !bm_session.send_dmrd(encoded.bytes.data(), encoded.bytes.size(), elapsed_ms())) {
                if (is_shutdown_terminator(*packet)) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_bm_queue_rejected");
                }
                pipeline->cancel_tx();
                (void)stop_tx_input();
                ptt_gate.disarm_until_release();
                status("tx_datagram_rejected_and_queue_cleared");
                return;
            }
        }
    };

    auto process_t_key = [&]() {
        if (!wirex::bm_test_profile::permits_transmit(tx_policy)) {
            ++counters.rejected_calls;
            status("tx_start_rejected_receive_only_policy");
            return;
        }
        const auto pstate = pipeline->snapshot();
        if (pstate.tx_state == wirex::bm_voice::TxState::active) {
            (void)end_tx_call();
            return;
        }
        if (pstate.tx_state == wirex::bm_voice::TxState::draining) {
            status("tx_busy_draining");
            return;
        }
        (void)start_tx_call();
    };

    bool exception_while_running = false;
    try {
        if (!shutdown_requested) {
            const auto initial = hri_session.start(0U);
            hri_state = initial.state;
            hri_active = hri_state.phase != HriPhase::stopped;
            apply_hri_update(initial);
        }

        while (true) {
            const auto stream_phase_at_loop_start = stream_session->snapshot().phase;
            if (shutdown_requested && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                (stream_phase_at_loop_start == StreamPhase::idle || stream_phase_at_loop_start == StreamPhase::faulted)) {
                break;
            }
            if (failed && !shutdown_requested) begin_shutdown(failure_reason);
            const auto stream_phase_after_failure_check = stream_session->snapshot().phase;
            if (shutdown_requested && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                (stream_phase_after_failure_check == StreamPhase::idle ||
                 stream_phase_after_failure_check == StreamPhase::faulted)) {
                break;
            }
            synchronize_ptt_gate();
            const auto now = Clock::now();
            const auto now_ms = elapsed_ms();
            if (now_ms >= next_runtime_snapshot_ms) {
                status("runtime_snapshot");
                next_runtime_snapshot_ms = now_ms + 1000U;
            }
            if (!manual_ptt) {
                handle_ptt_gate_action(ptt_gate.tick(now_ms), "ptt_call_timer_event");
            }
            if (!shutdown_requested && !continuous_run && now_ms >= bm_bridge_window_ms) {
                begin_shutdown("120s_run_window_expired");
            }
            if (!shutdown_requested && control_scope.cancel_requested()) {
                begin_shutdown("console_cancel_requested");
            }
            if (control_scope.close_wait_timed_out()) {
                set_failure("console_close_cleanup_deadline_expired");
                cleanup_forced = true;
                break;
            }

            if (ui_pipe) {
                DWORD available = 0U;
                if (!PeekNamedPipe(ui_pipe_handle, nullptr, 0U, nullptr, &available, nullptr)) {
                    const DWORD error = GetLastError();
                    if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA || error == ERROR_HANDLE_EOF ||
                        error == ERROR_PIPE_NOT_CONNECTED) {
                        (void)ui_control_parser.eof();
                        begin_shutdown("ui_control_eof");
                    } else {
                        set_failure("ui_control_pipe_poll_failed");
                        begin_shutdown("ui_control_pipe_poll_failed");
                    }
                } else if (available != 0U) {
                    std::array<char, 16U> command_bytes{};
                    DWORD actual = 0U;
                    const DWORD wanted = std::min<DWORD>(available, static_cast<DWORD>(command_bytes.size()));
                    const BOOL read_succeeded = ReadFile(ui_pipe_handle, command_bytes.data(), wanted, &actual, nullptr);
                    if (read_succeeded != FALSE && actual == 0U) {
                        (void)ui_control_parser.eof();
                        begin_shutdown("ui_control_eof");
                    } else if (read_succeeded == FALSE || actual > wanted) {
                        const DWORD error = GetLastError();
                        if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA || error == ERROR_HANDLE_EOF ||
                            error == ERROR_PIPE_NOT_CONNECTED) {
                            (void)ui_control_parser.eof();
                            begin_shutdown("ui_control_eof");
                        } else {
                            set_failure("ui_control_pipe_read_failed");
                            begin_shutdown("ui_control_pipe_read_failed");
                        }
                    } else {
                        const auto result = ui_control_parser.feed(std::string_view(command_bytes.data(), actual));
                        if (result == wirex::ui_control::Result::shutdown) {
                            begin_shutdown("ui_q_requested");
                        } else if (result == wirex::ui_control::Result::invalid) {
                            set_failure("ui_control_input_invalid");
                            begin_shutdown("ui_control_input_invalid");
                        }
                    }
                }
            } else {
                DWORD queued_keys = 0U;
                HANDLE input_handle = GetStdHandle(STD_INPUT_HANDLE);
                if (input_handle == nullptr || input_handle == INVALID_HANDLE_VALUE ||
                    !GetNumberOfConsoleInputEvents(input_handle, &queued_keys)) {
                    set_failure("console_key_poll_failed");
                    begin_shutdown("console_key_poll_failed");
                } else {
                    std::array<INPUT_RECORD, 32U> key_records{};
                    while (queued_keys != 0U) {
                        DWORD read = 0U;
                        const DWORD count = std::min<DWORD>(queued_keys, static_cast<DWORD>(key_records.size()));
                        if (!ReadConsoleInputW(input_handle, key_records.data(), count, &read) || read == 0U || read > count) {
                            set_failure("console_key_read_failed");
                            begin_shutdown("console_key_read_failed");
                            break;
                        }
                        queued_keys -= read;
                        for (DWORD index = 0U; index < read; ++index) {
                            const auto& record = key_records[index];
                            if (record.EventType != KEY_EVENT) continue;
                            wchar_t key = record.Event.KeyEvent.uChar.UnicodeChar;
                            if (key >= L'a' && key <= L'z') key = static_cast<wchar_t>(key - L'a' + L'A');
                            if (record.Event.KeyEvent.bKeyDown) {
                                if (manual_ptt && key == L'T' && !t_key_down) process_t_key();
                                if (key == L'Q' && !q_key_down) begin_shutdown("user_requested_exit");
                                if (key == L'T') t_key_down = true;
                                if (key == L'Q') q_key_down = true;
                            } else {
                                if (key == L'T') t_key_down = false;
                                if (key == L'Q') q_key_down = false;
                            }
                        }
                    }
                }
            }

            if (!shutdown_requested && hri_active) {
                const auto update = hri_session.tick(now_ms);
                apply_hri_update(update);
                hri_active = hri_state.phase != HriPhase::stopped;
            }
            service_stream_update(stream_session->tick(now_ms));
            begin_stream_for_pending_rx();

            if (port.valid() && !serial_failed) {
                DWORD comm_errors = 0U;
                COMSTAT comm_state{};
                if (!ClearCommError(port.get(), &comm_errors, &comm_state) || comm_errors != 0U) {
                    serial_failed = true;
                    set_failure("serial_transport_error");
                    begin_shutdown("serial_transport_error");
                } else if (comm_state.cbInQue != 0U) {
                    std::array<std::uint8_t, 2048U> serial_bytes{};
                    const DWORD wanted = std::min<DWORD>(comm_state.cbInQue,
                        static_cast<DWORD>(serial_bytes.size()));
                    DWORD actual = 0U;
                    if (!ReadFile(port.get(), serial_bytes.data(), wanted, &actual, nullptr) || actual > wanted) {
                        serial_failed = true;
                        set_failure("serial_read_failed");
                        begin_shutdown("serial_read_failed");
                    } else if (actual != 0U) {
                        if (hri_active && !shutdown_requested) {
                            apply_hri_update(hri_session.feed(serial_bytes.data(), actual, elapsed_ms()));
                            hri_active = hri_state.phase != HriPhase::stopped;
                        }
                        const auto stream_phase = stream_session->snapshot().phase;
                        if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
                            service_stream_update(stream_session->feed(serial_bytes.data(), actual, elapsed_ms()));
                        }
                        begin_stream_for_pending_rx();
                    }
                }
            }

            auto network_before = bm_session.snapshot().state;
            bm_session.tick(now_ms);
            log_bm_transition("bm_session_state_or_failure_changed_after_tick");
            if (!transport.is_open() && bm_session.snapshot().state == wirex::bm::State::waiting_login_ack) {
                if (!transport.open(master)) {
                    bm_session.transport_lost(now_ms);
                    set_failure("udp_reopen_failed");
                    log_bm_transition("bm_session_state_or_failure_changed_after_udp_reopen_failure");
                }
            }
            if (transport.is_open() && !drain_bm_outbound()) {
                if (network_before == wirex::bm::State::ready) handle_network_loss("bm_reconnect_started");
            }
            for (std::size_t attempt = 0U; attempt < 8U && transport.is_open(); ++attempt) {
                auto received = transport.receive(0U);
                if (received.kind == wirex::bm::ReceiveKind::timeout) break;
                if (received.kind != wirex::bm::ReceiveKind::datagram) {
                    const bool was_ready = bm_session.snapshot().state == wirex::bm::State::ready;
                    transport.close();
                    bm_session.transport_lost(elapsed_ms());
                    log_bm_transition("bm_session_state_or_failure_changed_after_receive_failure");
                    if (was_ready) handle_network_loss("bm_udp_receive_lost");
                    break;
                }
                const auto prior_state = bm_session.snapshot().state;
                const bool dmrd_magic = received.bytes.size() >= 4U &&
                    std::memcmp(received.bytes.data(), "DMRD", 4U) == 0;
                if (!dmrd_magic) ++counters.control_rx_datagrams;
                const auto input_result = bm_session.on_datagram(received.bytes.data(), received.bytes.size(),
                    received.source, elapsed_ms());
                counters.last_input_result = input_result;
                counters.has_last_input_result = true;
                if (input_result == wirex::bm::InputResult::application_datagram) {
                    ++counters.application_rx_datagrams;
                }
                log_bm_transition("bm_session_state_or_failure_changed_after_datagram");
                if (input_result != wirex::bm::InputResult::accepted &&
                    input_result != wirex::bm::InputResult::application_datagram) {
                    status("bm_datagram_result_observed");
                }
                auto current_state = bm_session.snapshot().state;
                if (prior_state != wirex::bm::State::ready && current_state == wirex::bm::State::ready) {
                    network_ready_seen = true;
                    bm_ever_ready = true;
                    maybe_show_operator_ready_instructions();
                }
                if (prior_state == wirex::bm::State::ready && current_state != wirex::bm::State::ready) {
                    handle_network_loss("bm_session_left_ready_state");
                }
                while (auto incoming = bm_session.take_received_dmrd()) {
                    const auto decoded = wirex::dmrd::decode(incoming->bytes.data(), incoming->bytes.size());
                    if (!decoded) {
                        ++counters.rejected_calls;
                        continue;
                    }
                    constexpr std::uint8_t dmr_flag_ts2 = 0x80U;
                    constexpr std::uint8_t dmr_flag_private_call = 0x40U;
                    const auto& datagram = decoded.datagram;
                    const auto received_slot = (datagram.flags & dmr_flag_ts2) != 0U
                        ? wirex::dmr_call::Slot::ts2 : wirex::dmr_call::Slot::ts1;
                    const auto received_call_kind = (datagram.flags & dmr_flag_private_call) != 0U
                        ? wirex::dmr_call::CallKind::private_call : wirex::dmr_call::CallKind::group;
                    counters.has_last_rx_header = true;
                    counters.last_rx_source_id = datagram.source_id;
                    counters.last_rx_destination_id = datagram.destination_id;
                    counters.last_rx_slot = static_cast<std::uint8_t>(received_slot);
                    counters.last_rx_call_kind = received_call_kind == wirex::dmr_call::CallKind::private_call
                        ? 'P' : 'G';
                    const auto active_pipeline = pipeline->snapshot();
                    const auto active_hri = stream_session->snapshot();
                    const bool hri_busy = active_hri.phase != StreamPhase::idle;
                    if (downlink_blocked || (hri_busy &&
                        (active_pipeline.rx_state == wirex::bm_voice::RxState::idle ||
                         decoded.datagram.stream_id != active_pipeline.receive_call.stream_id))) {
                        // HRI仍在T0收尾或上一通话播放时，不允许新网络流覆盖当前呼叫状态。
                        ++counters.rejected_calls;
                        continue;
                    }
                    ++counters.rx_datagrams;
                    const auto accepted = pipeline->ingest_rx(decoded.datagram, Clock::now());
                    if (accepted.error == wirex::bm_voice::Error::filtered) {
                        ++counters.rx_filtered_datagrams;
                        bool had_header_mismatch = false;
                        if (receive_filter.destination_id != 0U &&
                            datagram.destination_id != receive_filter.destination_id) {
                            ++counters.rx_filtered_destination_id;
                            had_header_mismatch = true;
                        }
                        if (receive_filter.match_slot && received_slot != receive_filter.slot) {
                            ++counters.rx_filtered_slot;
                            had_header_mismatch = true;
                        }
                        if (receive_filter.match_call_kind && received_call_kind != receive_filter.call_kind) {
                            ++counters.rx_filtered_call_kind;
                            had_header_mismatch = true;
                        }
                        if (!had_header_mismatch) ++counters.rx_filtered_protocol;
                    }
                    if (accepted.error != wirex::bm_voice::Error::none &&
                        accepted.error != wirex::bm_voice::Error::filtered &&
                        accepted.error != wirex::bm_voice::Error::half_duplex_collision) {
                        ++counters.rejected_calls;
                    }
                    drain_pipeline_events();
                }
                if (!drain_bm_outbound()) break;
            }
            if (network_ready_seen && bm_session.snapshot().state != wirex::bm::State::ready) {
                handle_network_loss("bm_session_reconnecting");
            } else if (bm_session.snapshot().state == wirex::bm::State::ready) {
                network_ready_seen = true;
                bm_ever_ready = true;
                maybe_show_operator_ready_instructions();
            }
            synchronize_ptt_gate();

            const auto before_pipeline_tick = pipeline->snapshot();
            const auto pipeline_tick_error = pipeline->tick(Clock::now());
            if (pipeline_tick_error == wirex::bm_voice::Error::deadline_missed) {
                const auto after_pipeline_tick = pipeline->snapshot();
                if (before_pipeline_tick.tx_state != wirex::bm_voice::TxState::idle &&
                    after_pipeline_tick.tx_state == wirex::bm_voice::TxState::idle) {
                    if (!stop_tx_input()) set_failure("wavein_deadline_cleanup_failed");
                    if (!manual_ptt) ptt_gate.disarm_until_release();
                    ++counters.rejected_calls;
                    status("tx_deadline_missed_call_terminated_with_one_eot");
                }
                if (before_pipeline_tick.rx_state != wirex::bm_voice::RxState::idle &&
                    after_pipeline_tick.rx_state == wirex::bm_voice::RxState::idle) {
                    ++counters.rejected_calls;
                    pending_receive_start = false;
                    pending_receive_ended = false;
                    pending_playback_drain = false;
                    const auto stream_phase = stream_session->snapshot().phase;
                    if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
                        service_stream_update(stream_session->cancel(StreamReason::transport_failed, elapsed_ms()));
                    }
                    status("rx_deadline_missed_media_cleared_hri_t0_cleanup");
                }
            } else if (pipeline_tick_error != wirex::bm_voice::Error::none &&
                       pipeline_tick_error != wirex::bm_voice::Error::filtered &&
                       pipeline_tick_error != wirex::bm_voice::Error::half_duplex_collision) {
                set_failure("voice_pipeline_tick_failed");
            }
            drain_pipeline_events();
            begin_stream_for_pending_rx();

            if (radio_input_open && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::active) {
                const DWORD input_wait = WaitForSingleObject(radio_input.event(), 0U);
                if (input_wait == WAIT_FAILED) {
                    set_failure("radio_wavein_event_failed");
                } else {
                    for (auto& buffer : radio_input.buffers()) {
                        if ((buffer.header.dwFlags & WHDR_DONE) == 0) continue;
                        if (!consume_tx_wave_buffer(buffer, true)) {
                            set_failure("radio_wavein_pcm_or_requeue_failed");
                            break;
                        }
                    }
                }
            }
            if (failed && !shutdown_requested) begin_shutdown(failure_reason);

            pump_tx_datagrams();
            if (transport.is_open()) (void)drain_bm_outbound();

            if (radio_output_open) {
                radio_output.reap();
                if (radio_output.completion_overflowed()) {
                    set_failure("waveout_completion_queue_overflow");
                    begin_shutdown("waveout_completion_queue_overflow");
                }
                WaveOutput::CompletedFrames completed{};
                while (radio_output.take_completed_frames(completed)) {
                    const auto acknowledged = pipeline->acknowledge_playback(
                        completed.generation, completed.count, Clock::now());
                    if (acknowledged != wirex::bm_voice::Error::none &&
                        acknowledged != wirex::bm_voice::Error::stale_playback_ack) {
                        set_failure("playback_frame_ack_failed");
                    }
                    if (acknowledged == wirex::bm_voice::Error::none) {
                        counters.pcm_playback_frames += completed.count;
                    }
                }
                for (std::size_t submitted = 0U; submitted < 3U && radio_output.has_capacity(); ++submitted) {
                    wirex::bm_voice::PlaybackFrame frame{};
                    if (!pipeline->take_playback_pcm(frame)) break;
                    const auto gain = wirex::pcm_gain::apply(
                        frame.pcm.data(), frame.sample_count, radio_playback_gain_milli);
                    const auto byte_count = static_cast<DWORD>(frame.sample_count * sizeof(std::int16_t));
                    const auto result = gain.valid
                        ? radio_output.submit_playback_frame(frame.pcm.data(), byte_count, frame.generation)
                        : WaveOutput::SubmitResult::failed;
                    if (result == WaveOutput::SubmitResult::queued) {
                        if (gain.before.sample_count >
                            std::numeric_limits<std::uint64_t>::max() - counters.rx_audio_samples) {
                            counters.rx_audio_samples = std::numeric_limits<std::uint64_t>::max();
                        } else {
                            counters.rx_audio_samples += gain.before.sample_count;
                        }
                        wirex::pcm_gain::accumulate(counters.rx_pcm_input_stats, gain.before);
                        wirex::pcm_gain::accumulate(counters.rx_pcm_gained_stats, gain.after);
                        if (gain.clipped_samples >
                            std::numeric_limits<std::uint64_t>::max() - counters.rx_pcm_clipped_samples) {
                            counters.rx_pcm_clipped_samples = std::numeric_limits<std::uint64_t>::max();
                        } else {
                            counters.rx_pcm_clipped_samples += gain.clipped_samples;
                        }
                        secure_wipe(frame.pcm.data(), sizeof(frame.pcm));
                        continue;
                    }
                    secure_wipe(frame.pcm.data(), sizeof(frame.pcm));
                    pipeline->cancel_rx();
                    if (!radio_output.close()) set_failure("waveout_submit_cleanup_failed");
                    radio_output_open = false;
                    set_failure(gain.valid ? "waveout_playback_submit_failed" : "waveout_playback_gain_invalid");
                    break;
                }
                drain_pipeline_events();
                if (pending_playback_drain && radio_output.all_drained() &&
                    stream_session->snapshot().phase == StreamPhase::draining) {
                    pending_playback_drain = false;
                    service_stream_update(stream_session->playback_drained(elapsed_ms()));
                }
            }

            pump_tx_datagrams();
            if (transport.is_open()) (void)drain_bm_outbound();
            if (failed && !shutdown_requested) begin_shutdown(failure_reason);

            if (shutdown_requested && cleanup_deadline && Clock::now() >= *cleanup_deadline) {
                cleanup_forced = pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle ||
                    pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle ||
                    (stream_session->snapshot().phase != StreamPhase::idle &&
                     stream_session->snapshot().phase != StreamPhase::faulted);
                if (cleanup_forced) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_cleanup_deadline");
                    pipeline->cancel_tx();
                    pipeline->cancel_rx();
                    (void)stop_tx_input();
                    if (radio_output_open) {
                        (void)radio_output.close();
                        radio_output_open = false;
                    }
                    set_failure("cleanup_deadline_exceeded");
                }
                break;
            }
            const auto stream_phase = stream_session->snapshot().phase;
            if (shutdown_requested && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                (stream_phase == StreamPhase::idle || stream_phase == StreamPhase::faulted)) {
                break;
            }
            Sleep(5U);
        }
    } catch (...) {
        exception_while_running = true;
        set_failure("runtime_exception");
        shutdown_requested = true;
        shutdown_reason = "runtime_exception";
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        cleanup_deadline = Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms};
        pending_receive_start = false;
        (void)stop_tx_input();
        if (hri_active && hri_state.phase != HriPhase::stopped) {
            hri_state = hri_session.cancel().state;
            hri_active = false;
        }
        const auto state = stream_session->snapshot();
        if (state.start_write_attempted && !state.stop_write_attempted && port.valid()) {
            DWORD written = 0U;
            const BOOL wrote = WriteFile(port.get(), stop_frame_result.bytes.data(),
                static_cast<DWORD>(stop_frame_result.bytes.size()), &written, nullptr);
            if (wrote == FALSE || written != stop_frame_result.bytes.size()) {
                set_failure("exception_cleanup_t0_write_failed");
            }
        }
        pipeline->cancel_tx();
        pipeline->cancel_rx();
        if (radio_output_open) {
            (void)radio_output.close();
            radio_output_open = false;
        }
    }

    if (!shutdown_requested) begin_shutdown("runtime_loop_ended");
    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_cleanup_ended");
    if (pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle) {
        pipeline->cancel_tx();
    }
    pipeline->cancel_rx();
    const bool input_cleanup_ok = stop_tx_input();
    const bool output_cleanup_ok = radio_output.close();
    radio_output_open = false;
    const HANDLE raw_port = port.release();
    const bool serial_cleanup_ok = raw_port == nullptr || raw_port == INVALID_HANDLE_VALUE || CloseHandle(raw_port) != FALSE;
    if (!bm_ever_ready) {
        set_failure("bm_session_never_ready");
        status("bm_session_never_ready_no_connection_confirmed");
    }
    const bool bm_ready_before_stop = bm_session.snapshot().state == wirex::bm::State::ready;
    if (bm_session.snapshot().state != wirex::bm::State::stopped) {
        bm_session.stop(elapsed_ms());
        if (bm_ready_before_stop) {
            if (transport.is_open()) {
                status("bm_rptcl_local_send_queued");
                (void)drain_bm_outbound();
            } else {
                status("bm_rptcl_not_sent_transport_closed");
            }
        } else {
            status("bm_rptcl_not_queued_bm_not_ready");
        }
    }
    transport.close();
    const bool signal_ok = control_scope.signal_cleanup_complete();
    const bool unregister_ok = control_scope.unregister_now();
    if (!input_cleanup_ok || !output_cleanup_ok || !serial_cleanup_ok || !signal_ok || !unregister_ok) {
        set_failure("owned_resource_cleanup_failed");
    }
    if (exception_while_running) status("stopped_after_runtime_exception");
    else status(failed ? "stopped_with_failure" : "stopped");
    if (failed) {
        std::wstring final_text = L"BM + FTX-1 bridge stopped with bounded cleanup; reason=";
        final_text.append(failure_reason.begin(), failure_reason.end());
        if (!bm_ever_ready) {
            final_text.append(L"; BM session never reached ready, so a successful connection was not confirmed");
        }
        if (status_report_failed) final_text.append(L"; status_report=failed");
        final_text.append(L". radio_state=unknown.\n");
        (void)bm_stderr(final_text);
    } else {
        (void)bm_stderr(L"BM + FTX-1 bridge stopped; radio_state=unknown.\n");
    }
    return failed ? 2 : 0;
}

#endif // WIREX_ENABLE_BM_BRIDGE

void print_help()
{
    std::wcout << L"wirex_probe - offline-first FTX-1 DIRECT diagnostic CLI\n"
               << L"  --help\n"
               << L"  --version --port COM5       Send one Direct V0000 query; wait at most 2500 ms.\n"
               << L"  --hri-listen --port COM5 --body-file ABS --input N --output M --seconds N (1..120) [--gain X]\n"
               << L"                               External 100-byte Y body; start selected PCM route only after valid Y/0.\n"
               << L"                               Optional --report-file ABS writes bounded atomic metadata snapshots only.\n"
               << L"  --hri-downlink-candidate --port COM5 --body-file ABS --file WAV --report-file ABS\n"
               << L"                               Fixed local start/stop T candidates and one bounded WAV; software observations only.\n"
               << L"                               Requires one exact USB WaveOut match; radio state remains unknown.\n"
               << L"  --hri-radio-session --port COMn --body-file ABS --fixed-wav ABS --radio-input N --pc-output N --mic-input N --report-file ABS [--interactive]\n"
               << L"                               One 120 s runtime window plus a fixed, bounded local cleanup period; no automatic restart.\n"
               << L"                               Listens after Y/0, accepts sequential user-requested F/M sends, and returns to listening when safe.\n"
               << L"                               Interactive keys: F fixed WAV, M capture up to 8 s in memory then send, C cancel, Q quit. No automatic downlink.\n"
               << L"  --list-audio                List explicit WaveIn/WaveOut device IDs and names.\n"
               << L"  --list-audio-json           Emit device IDs, names, endpoint IDs, and PCM format support; open no audio streams.\n"
               << L"  --monitor --input N --seconds N (1..30)\n"
               << L"                               Measure input PCM; no save/playback/default device.\n"
               << L"  --play-wav --file PATH --output N\n"
               << L"                               Play PCM 48000 Hz mono s16 WAV, at most 30 s.\n"
               << L"  --audio-loop --input N --output M --seconds N\n"
               << L"                               Route explicit devices for 1..30 s; 48000 Hz mono signed 16-bit PCM.\n"
               << L"                               Optional trailing --gain X (0.25..16.0, default 1.0); no mixer change.\n";
}

} // namespace

int wmain(int argc, wchar_t* argv[])
{
#ifdef WIREX_ENABLE_BM_BRIDGE
    try {
        return bm_bridge_main(argc, argv);
    } catch (...) {
        (void)bm_stderr(L"Native BM bridge failed before or during controlled startup; no credential or payload details were recorded.\n");
        return 2;
    }
#else
    if (argc == 2 && std::wstring_view(argv[1]) == L"--help") {
        print_help();
        return 0;
    }
    if (argc == 2 && std::wstring_view(argv[1]) == L"--list-audio") {
        list_audio_devices();
        return 0;
    }
    if (argc == 2 && std::wstring_view(argv[1]) == L"--list-audio-json") {
        list_audio_devices_json();
        return 0;
    }
    if (argc == 4 && std::wstring_view(argv[1]) == L"--version" && std::wstring_view(argv[2]) == L"--port") {
        return query_version(argv[3]);
    }
    if (argc == 10 && std::wstring_view(argv[1]) == L"--hri-downlink-candidate" &&
        std::wstring_view(argv[2]) == L"--port" && std::wstring_view(argv[4]) == L"--body-file" &&
        std::wstring_view(argv[6]) == L"--file" && std::wstring_view(argv[8]) == L"--report-file") {
        return hri_downlink_candidate(argv[3], std::filesystem::path(argv[5]),
            std::filesystem::path(argv[7]), std::filesystem::path(argv[9]));
    }
    if (argc > 1 && std::wstring_view(argv[1]) == L"--hri-downlink-candidate") {
        std::wcerr << L"Usage: --hri-downlink-candidate --port COMn --body-file ABS --file ABS --report-file ABS.\n";
        return 2;
    }
    if (argc >= 2 && std::wstring_view(argv[1]) == L"--hri-radio-session") {
        bool interactive = false;
        for (int index = 2; index < argc; ++index) {
            if (std::wstring_view(argv[index]) == L"--interactive") interactive = true;
        }
        unsigned long radio_input = 0;
        unsigned long pc_output = 0;
        unsigned long microphone_input = 0;
        const bool shape_ok = (argc == 16 || (argc == 17 && interactive)) &&
            std::wstring_view(argv[2]) == L"--port" &&
            std::wstring_view(argv[4]) == L"--body-file" &&
            std::wstring_view(argv[6]) == L"--fixed-wav" &&
            std::wstring_view(argv[8]) == L"--radio-input" &&
            std::wstring_view(argv[10]) == L"--pc-output" &&
            std::wstring_view(argv[12]) == L"--mic-input" &&
            std::wstring_view(argv[14]) == L"--report-file" &&
            (argc == 16 || std::wstring_view(argv[16]) == L"--interactive");
        if (!shape_ok || !parse_uint(argv[9], radio_input) || radio_input > 0xffffffffUL ||
            !parse_uint(argv[11], pc_output) || pc_output > 0xffffffffUL ||
            !parse_uint(argv[13], microphone_input) || microphone_input > 0xffffffffUL) {
            if (interactive) {
                std::wcerr << L"用法：--hri-radio-session --port COMn --body-file ABS --fixed-wav ABS --radio-input N --pc-output N --mic-input N --report-file ABS [--interactive]。\n";
            } else {
                wirex::bounded_pipe_writer::Writer writer(GetStdHandle(STD_OUTPUT_HANDLE));
                if (writer.enable_nonblocking()) {
                    (void)writer.write_line("{\"protocol_version\":1,\"type\":\"session_result\",\"run_id\":null,\"seq\":1,\"request_id\":null,\"status\":\"failed\",\"phase\":\"startup_failed\",\"failure_reason\":\"arguments_invalid\"}");
                } else {
                    std::wcerr << L"协议模式要求可设置PIPE_NOWAIT的stdout管道；未打开硬件。\n";
                }
            }
            return 2;
        }
        return hri_radio_session(argv[3], std::filesystem::path(argv[5]), std::filesystem::path(argv[7]),
            static_cast<UINT>(radio_input), static_cast<UINT>(pc_output), static_cast<UINT>(microphone_input),
            std::filesystem::path(argv[15]), interactive);
    }
    if (argc >= 12 && std::wstring_view(argv[1]) == L"--hri-listen" &&
        std::wstring_view(argv[2]) == L"--port" && std::wstring_view(argv[4]) == L"--body-file" &&
        std::wstring_view(argv[6]) == L"--input" && std::wstring_view(argv[8]) == L"--output" &&
        std::wstring_view(argv[10]) == L"--seconds") {
        unsigned long input_id = 0;
        unsigned long output_id = 0;
        unsigned long seconds = 0;
        std::uint32_t gain_milli = wirex::pcm_gain::unity_milli;
        bool gain_seen = false;
        bool report_seen = false;
        std::optional<std::filesystem::path> report_path;
        if (!parse_uint(argv[7], input_id) || input_id > 0xffffffffUL ||
            !parse_uint(argv[9], output_id) || output_id > 0xffffffffUL ||
            !parse_uint(argv[11], seconds) || seconds < 1 || seconds > 120) {
            std::wcerr << L"--input/--output must be explicit device IDs, HRI --seconds must be 1..120, and optional --gain must be 0.25..16.0.\n";
            return 2;
        }
        for (int index = 12; index < argc;) {
            const std::wstring_view option(argv[index]);
            if (option == L"--gain" && !gain_seen && index + 1 < argc) {
                if (!wirex::pcm_gain::parse_gain(argv[index + 1], gain_milli)) {
                    std::wcerr << L"Optional --gain must be 0.25..16.0.\n";
                    return 2;
                }
                gain_seen = true;
                index += 2;
            } else if (option == L"--report-file" && !report_seen && index + 1 < argc) {
                report_path = std::filesystem::path(argv[index + 1]);
                report_seen = true;
                index += 2;
            } else {
                std::wcerr << L"Usage: --hri-listen --port COMn --body-file ABS --input N --output M --seconds 1..120 [--gain X] [--report-file ABS].\n";
                return 2;
            }
        }
        return hri_listen(argv[3], std::filesystem::path(argv[5]), static_cast<UINT>(input_id),
            static_cast<UINT>(output_id), seconds, gain_milli, report_path);
    }
    if (argc > 1 && std::wstring_view(argv[1]) == L"--hri-listen") {
        std::wcerr << L"Usage: --hri-listen --port COMn --body-file ABS --input N --output M --seconds 1..120 [--gain X] [--report-file ABS].\n";
        return 2;
    }
    if (argc == 6 && std::wstring_view(argv[1]) == L"--play-wav" && std::wstring_view(argv[2]) == L"--file" &&
        std::wstring_view(argv[4]) == L"--output") {
        unsigned long output_id = 0;
        if (!parse_uint(argv[5], output_id) || output_id > 0xffffffffUL) {
            std::wcerr << L"--output must be a non-negative WaveOut device ID.\n";
            return 2;
        }
        return play_wav(argv[3], static_cast<UINT>(output_id));
    }
    if (argc == 6 && std::wstring_view(argv[1]) == L"--monitor" && std::wstring_view(argv[2]) == L"--input" &&
        std::wstring_view(argv[4]) == L"--seconds") {
        unsigned long input_id = 0;
        unsigned long seconds = 0;
        if (!parse_uint(argv[3], input_id) || input_id > 0xffffffffUL || !parse_uint(argv[5], seconds) || seconds < 1 || seconds > 30) {
            std::wcerr << L"--input must be a non-negative device ID and --seconds must be 1..30.\n";
            return 2;
        }
        return monitor_input(static_cast<UINT>(input_id), seconds);
    }
    if ((argc == 8 || argc == 10) && std::wstring_view(argv[1]) == L"--audio-loop" && std::wstring_view(argv[2]) == L"--input" &&
        std::wstring_view(argv[4]) == L"--output" && std::wstring_view(argv[6]) == L"--seconds") {
        unsigned long input_id = 0;
        unsigned long output_id = 0;
        unsigned long seconds = 0;
        std::uint32_t gain_milli = wirex::pcm_gain::unity_milli;
        if (!parse_uint(argv[3], input_id) || input_id > 0xffffffffUL ||
            !parse_uint(argv[5], output_id) || output_id > 0xffffffffUL ||
            !parse_uint(argv[7], seconds) || seconds < 1 || seconds > 30 ||
            (argc == 10 && (std::wstring_view(argv[8]) != L"--gain" || !wirex::pcm_gain::parse_gain(argv[9], gain_milli)))) {
            std::wcerr << L"--input and --output must be non-negative device IDs, --seconds 1..30, and optional --gain 0.25..16.0 with at most 3 decimal places.\n";
            return 2;
        }
        return audio_loop(static_cast<UINT>(input_id), static_cast<UINT>(output_id), seconds, gain_milli);
    }
    if (argc > 1 && std::wstring_view(argv[1]) == L"--audio-loop") {
        std::wcerr << L"Usage: --audio-loop --input N --output M --seconds N [--gain X] (seconds 1..30, gain 0.25..16.0).\n";
        return 2;
    }
    print_help();
    return 2;
#endif
}
