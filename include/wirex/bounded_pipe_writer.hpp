#pragma once

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace wirex::bounded_pipe_writer {

// 仅将完整行写入已设为PIPE_NOWAIT的stdout管道，不等待读端无限期读取。
class Writer {
public:
    explicit Writer(HANDLE handle) noexcept : handle_(handle) {}

    [[nodiscard]] bool enable_nonblocking() noexcept
    {
        if (handle_ == nullptr || handle_ == INVALID_HANDLE_VALUE) return false;
        DWORD mode = PIPE_NOWAIT;
        enabled_ = SetNamedPipeHandleState(handle_, &mode, nullptr, nullptr) != FALSE;
        return enabled_;
    }

    [[nodiscard]] bool write_line(std::string_view line, std::uint64_t deadline_ms = 75) const
    {
        if (!enabled_ || handle_ == nullptr || handle_ == INVALID_HANDLE_VALUE || deadline_ms == 0) return false;
        std::string bytes(line);
        if (bytes.empty() || bytes.back() != '\n') bytes.push_back('\n');
        const ULONGLONG deadline = GetTickCount64() + deadline_ms;
        std::size_t offset = 0;
        while (offset < bytes.size()) {
            DWORD written = 0;
            const auto remaining = bytes.size() - offset;
            const DWORD requested = static_cast<DWORD>(remaining > MAXDWORD ? MAXDWORD : remaining);
            if (WriteFile(handle_, bytes.data() + offset, requested, &written, nullptr) != FALSE && written != 0) {
                offset += written;
                continue;
            }
            const DWORD error = GetLastError();
            if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED || error == ERROR_INVALID_HANDLE) return false;
            if (GetTickCount64() >= deadline) return false;
            Sleep(1);
        }
        return true;
    }

private:
    HANDLE handle_{INVALID_HANDLE_VALUE};
    bool enabled_{false};
};

} // namespace wirex::bounded_pipe_writer
