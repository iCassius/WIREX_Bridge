#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>

#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"
#include "wirex/pcm_gain.hpp"
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
#include <iomanip>
#include <iostream>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace {

std::atomic_bool cancel_requested{false};

BOOL WINAPI console_control_handler(DWORD control)
{
    if (control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT) {
        cancel_requested.store(true);
        return TRUE;
    }
    return FALSE;
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
    if (!PurgeComm(port, PURGE_RXCLEAR | PURGE_TXCLEAR)) {
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
            if (cancel_requested.load()) return SubmitResult::cancelled;
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
            if (cancel_requested.load()) return DrainResult::cancelled;
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

    cancel_requested.store(false);
    if (!SetConsoleCtrlHandler(console_control_handler, TRUE)) {
        std::wcerr << L"Could not register the Ctrl+C handler: " << win_error(GetLastError()) << L"\n";
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

    while (!cancel_requested.load() && std::chrono::steady_clock::now() < deadline) {
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

    if (!SetConsoleCtrlHandler(console_control_handler, FALSE)) {
        std::wcerr << L"Could not unregister the Ctrl+C handler: " << win_error(GetLastError()) << L"\n";
        failed = true;
    }
    const bool input_cleanup_ok = input.close();
    const bool output_cleanup_ok = output.close();
    if (input_cleanup_ok && output_cleanup_ok) {
        if (cancel_requested.load()) std::cout << "Audio route cancelled; reset and close calls succeeded for owned audio resources.\n";
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

    WaveOutput output;
    if (!output.open(output_id)) return 2;
    cancel_requested.store(false);
    if (!SetConsoleCtrlHandler(console_control_handler, TRUE)) {
        std::wcerr << L"Could not register the Ctrl+C handler: " << win_error(GetLastError()) << L"\n";
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
        if (cancel_requested.load()) {
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

    if (!SetConsoleCtrlHandler(console_control_handler, FALSE)) {
        std::wcerr << L"Could not unregister the Ctrl+C handler: " << win_error(GetLastError()) << L"\n";
        failed = true;
    }
    const bool cleanup_ok = output.close();
    if (!cleanup_ok) failed = true;

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

    WaveInput input;
    if (!input.open(input_id)) return 2;
    cancel_requested.store(false);
    if (!SetConsoleCtrlHandler(console_control_handler, TRUE)) {
        std::wcerr << L"Could not register the Ctrl+C handler: " << win_error(GetLastError()) << L"\n";
        const bool cleanup_ok = input.close();
        return cleanup_ok ? 2 : 3;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    auto report_at = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    long double sum_squares = 0.0L;
    std::uint64_t samples = 0;
    std::uint32_t peak = 0;
    bool failed = false;

    while (!cancel_requested.load() && std::chrono::steady_clock::now() < deadline) {
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
    if (!SetConsoleCtrlHandler(console_control_handler, FALSE)) {
        std::wcerr << L"Could not unregister the Ctrl+C handler: " << win_error(GetLastError()) << L"\n";
        failed = true;
    }
    const bool cleanup_ok = input.close();
    if (cleanup_ok) {
        if (cancel_requested.load()) std::wcout << L"Monitor cancelled; reset and close calls succeeded for audio input.\n";
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
