#pragma once

// Windows 设备辅助：串口、WinMM WaveIn/WaveOut、HRI Y 模板。
// 原先位于 probe_main.cpp 匿名命名空间；wirex_probe 诊断工具与 Native 引擎共用同一实现。

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <mmsystem.h>
#include <mmddk.h>
#include <bcrypt.h>

#include "wirex/console_lifecycle.hpp"
#include "wirex/hri_session.hpp"
#include "wirex/approved_hri_y_template.hpp"
#include "wirex/wave_output_open.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::win_io {

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

inline std::wstring win_error(DWORD code)
{
    wchar_t* message = nullptr;
    const DWORD count = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code, 0, reinterpret_cast<LPWSTR>(&message), 0, nullptr);
    std::wstring result = count != 0 && message != nullptr ? message : L"Windows error";
    if (message != nullptr) LocalFree(message);
    while (!result.empty() && (result.back() == L'\r' || result.back() == L'\n' || result.back() == L' ')) result.pop_back();
    return result;
}

inline void secure_wipe(void* data, std::size_t size) noexcept
{
    if (data != nullptr && size != 0) SecureZeroMemory(data, size);
}

inline std::wstring mm_error(MMRESULT code)
{
    std::array<wchar_t, 256> message{};
    if (waveInGetErrorTextW(code, message.data(), static_cast<UINT>(message.size())) == MMSYSERR_NOERROR) {
        return message.data();
    }
    return L"MMRESULT " + std::to_wstring(code);
}

inline std::optional<std::wstring> wave_endpoint_id(bool input, UINT device_id)
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

inline bool wave_endpoint_matches(bool input, UINT device_id, std::wstring_view expected_endpoint_id)
{
    if (expected_endpoint_id.empty()) return false;
    const auto current = wave_endpoint_id(input, device_id);
    return current && *current == expected_endpoint_id;
}

inline std::wstring device_name(const wchar_t* name, std::size_t capacity)
{
    std::size_t length = 0;
    while (length < capacity && name[length] != L'\0') ++length;
    if (length == 0) return L"<empty name>";
    return std::wstring(name, length);
}

inline bool parse_uint(std::wstring_view text, unsigned long& value)
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

inline bool parse_port(std::wstring_view port, std::wstring& device_path)
{
    if (port.size() < 4 || (port[0] != L'C' && port[0] != L'c') ||
        (port[1] != L'O' && port[1] != L'o') || (port[2] != L'M' && port[2] != L'm')) return false;
    unsigned long number = 0;
    if (!parse_uint(port.substr(3), number) || number == 0 || number > 999) return false;
    device_path = L"\\\\.\\" + std::wstring(port);
    return true;
}

inline WAVEFORMATEX pcm_format() noexcept
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

inline bool configure_serial(HANDLE port, bool purge_queues = true)
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
    // 与 WaveInput 解耦：BM 下行按 20 ms 帧提交，需要容纳 bm_voice 的 10 帧（200 ms）
    // 在途上限再留余量；probe 的 100 ms 块路径只在设备欠载时才会排满。
    static constexpr std::size_t buffer_count = 12U;
    struct Buffer {
        std::array<std::int16_t, WaveInput::sample_count> samples{};
        WAVEHDR header{};
        bool prepared{false};
        bool queued{false};
        std::uint64_t playback_generation{};
    };
    enum class SubmitResult { queued, full, failed, cancelled, timed_out };
    enum class DrainResult { complete, failed, cancelled, timed_out };
    // 每个已完成缓冲产生一个令牌；按缓冲数的两倍留出调用方晚取的余量。
    static constexpr std::size_t max_completion_tokens = buffer_count * 2U;
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
            if (wirex::ConsoleLifecycle::process().cancel_requested()) return SubmitResult::cancelled;
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
            if (wirex::ConsoleLifecycle::process().cancel_requested()) return DrainResult::cancelled;
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

inline bool load_hri_y_template(const std::filesystem::path& path, std::vector<std::uint8_t>& body)
{
    body.clear();
    if (path.empty()) {
        body.assign(wirex::approved_resources::hri_y_template.begin(),
                    wirex::approved_resources::hri_y_template.end());
    } else {
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
    }
    if (body.size() != wirex::hri_session::y_body_size) {
        std::wcerr << L"The bundled HRI body has an invalid length.\n";
        body.clear();
        return false;
    }
    if (body[5] != '2') {
        std::wcerr << L"The HRI body does not have ASCII '2' at byte offset 5.\n";
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
        std::wcerr << L"The HRI body does not match the approved 100-byte template SHA-256.\n";
        body.clear();
        return false;
    }
    return true;
}

inline bool prepare_hri_audio_devices(UINT input_id, UINT output_id)
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

inline bool pre_drain_hri_serial(HANDLE port, std::uint64_t& discarded_bytes)
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

inline bool resolve_candidate_output(UINT& output_id, std::wstring_view expected_endpoint_id)
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

} // namespace wirex::win_io
