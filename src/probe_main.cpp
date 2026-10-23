#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <bcrypt.h>

#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"
#include "wirex/hri_downlink_session.hpp"
#include "wirex/hri_session.hpp"
#include "wirex/hri_t_payload.hpp"
#include "wirex/console_lifecycle.hpp"
#include "wirex/pcm_gain.hpp"
#include "wirex/session_report.hpp"
#include "wirex/wave_file.hpp"

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
#include <iomanip>
#include <iostream>
#include <optional>
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

std::wstring mm_error(MMRESULT code)
{
    std::array<wchar_t, 256> message{};
    if (waveInGetErrorTextW(code, message.data(), static_cast<UINT>(message.size())) == MMSYSERR_NOERROR) {
        return message.data();
    }
    return L"MMRESULT " + std::to_wstring(code);
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

    bool open(UINT device_id)
    {
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
        return waveInAddBuffer(device_, &buffer.header, sizeof(buffer.header));
    }

    bool close() noexcept
    {
        if (device_ == nullptr) {
            event_.reset();
            return true;
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
        started_ = false;
        if (device_ == nullptr) event_.reset();
        return cleanup_ok;
    }

private:
    HWAVEIN device_{nullptr};
    WinHandle event_{};
    std::array<Buffer, buffer_count> buffers_{};
    bool started_{false};
};

class WaveOutput {
public:
    static constexpr std::size_t buffer_count = WaveInput::buffer_count;
    struct Buffer {
        std::array<std::int16_t, WaveInput::sample_count> samples{};
        WAVEHDR header{};
        bool prepared{false};
        bool queued{false};
    };
    enum class SubmitResult { queued, full, failed, cancelled, timed_out };
    enum class DrainResult { complete, failed, cancelled, timed_out };

    ~WaveOutput() { close(); }
    WaveOutput(const WaveOutput&) = delete;
    WaveOutput& operator=(const WaveOutput&) = delete;
    WaveOutput() = default;

    bool open(UINT device_id)
    {
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
        for (auto& buffer : buffers_) {
            buffer.header.lpData = reinterpret_cast<LPSTR>(buffer.samples.data());
            buffer.header.dwBufferLength = static_cast<DWORD>(sizeof(buffer.samples));
            const auto prepared = waveOutPrepareHeader(device_, &buffer.header, sizeof(buffer.header));
            if (prepared != MMSYSERR_NOERROR) {
                std::wcerr << L"waveOutPrepareHeader failed: " << mm_error(prepared) << L"\n";
                close();
                return false;
            }
            buffer.prepared = true;
        }
        return true;
    }

    [[nodiscard]] HANDLE event() const noexcept { return event_.get(); }

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
            }
        }
    }

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
            return true;
        }
        bool cleanup_ok = true;
        const auto reset = waveOutReset(device_);
        if (reset != MMSYSERR_NOERROR) {
            std::wcerr << L"waveOutReset cleanup failed: " << mm_error(reset) << L"\n";
            cleanup_ok = false;
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
            } else {
                std::wcerr << L"waveOutUnprepareHeader cleanup failed: " << mm_error(result) << L"\n";
                cleanup_ok = false;
            }
        }
        const auto closed = waveOutClose(device_);
        if (closed == MMSYSERR_NOERROR) {
            device_ = nullptr;
        } else {
            std::wcerr << L"waveOutClose cleanup failed: " << mm_error(closed) << L"\n";
            cleanup_ok = false;
        }
        if (device_ == nullptr) event_.reset();
        return cleanup_ok;
    }

private:
    HWAVEOUT device_{nullptr};
    WinHandle event_{};
    std::array<Buffer, buffer_count> buffers_{};
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
               << L"  --list-audio                List explicit WaveIn/WaveOut device IDs and names.\n"
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
    if (argc == 2 && std::wstring_view(argv[1]) == L"--help") {
        print_help();
        return 0;
    }
    if (argc == 2 && std::wstring_view(argv[1]) == L"--list-audio") {
        list_audio_devices();
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
}
