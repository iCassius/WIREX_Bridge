#pragma once

#include <cstdint>
#include <limits>

namespace wirex::session_timing {

inline constexpr std::uint64_t active_window_ms = 120000;
inline constexpr std::uint64_t cleanup_grace_ms = 3000;

[[nodiscard]] constexpr bool active_window_expired(std::uint64_t elapsed_ms) noexcept
{
    return elapsed_ms >= active_window_ms;
}

// 固定首次进入收尾时刻的期限；后续取消不能延长清理窗口。
class StopBudget {
public:
    explicit constexpr StopBudget(std::uint64_t grace_ms) noexcept
        : grace_ms_(grace_ms)
    {
    }

    [[nodiscard]] constexpr bool begin_shutdown(std::uint64_t now_ms) noexcept
    {
        if (started_) return false;
        started_ = true;
        deadline_ms_ = now_ms > std::numeric_limits<std::uint64_t>::max() - grace_ms_
            ? std::numeric_limits<std::uint64_t>::max()
            : now_ms + grace_ms_;
        return true;
    }

    [[nodiscard]] constexpr bool started() const noexcept { return started_; }
    [[nodiscard]] constexpr std::uint64_t deadline_ms() const noexcept { return deadline_ms_; }

    [[nodiscard]] constexpr bool expired(std::uint64_t now_ms) const noexcept
    {
        return started_ && now_ms >= deadline_ms_;
    }

private:
    std::uint64_t grace_ms_;
    std::uint64_t deadline_ms_{0};
    bool started_{false};
};

} // namespace wirex::session_timing
