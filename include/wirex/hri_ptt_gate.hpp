#pragma once

#include <cstdint>

namespace wirex::hri_ptt_gate {

inline constexpr std::uint64_t max_call_duration_ms = 120000U;

enum class Level : std::uint8_t {
    unknown,
    pressed,
    released,
};

enum class Action : std::uint8_t {
    none,
    start_tx,
    end_tx,
    abort_tx,
    call_timeout,
};

struct Snapshot {
    bool ready{};
    bool armed{};
    bool pressed_latched{};
    bool tx_active{};
};

// 纯状态门：ready后必须先观察到松开，再接受新的按下边沿。
class Gate final {
public:
    [[nodiscard]] Action set_ready(bool ready) noexcept;
    [[nodiscard]] Action observe(Level level, bool tx_start_permitted) noexcept;
    [[nodiscard]] bool start_succeeded(std::uint64_t now_ms) noexcept;
    [[nodiscard]] Action tick(std::uint64_t now_ms) noexcept;

    // 开始流程失败后解除活动状态，必须再次松开才能重试。
    void start_failed() noexcept;

    // 单次通话被强制停止后保持未授权，直到观察到松开。
    void disarm_until_release() noexcept;

    [[nodiscard]] Snapshot snapshot() const noexcept;

private:
    bool ready_{};
    bool armed_{};
    bool pressed_latched_{};
    bool tx_active_{};
    bool call_timer_started_{};
    std::uint64_t call_started_ms_{};
};

} // namespace wirex::hri_ptt_gate
