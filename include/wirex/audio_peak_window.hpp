#pragma once

// 最近 200 ms 的归一化音频峰值，用于实时状态表。

#include <algorithm>
#include <chrono>
#include <cmath>
#include <deque>
#include <utility>

namespace wirex::audio_meter {

class PeakWindow final {
public:
    using Clock = std::chrono::steady_clock;
    static constexpr auto window = std::chrono::milliseconds{200};

    void push(float peak, Clock::time_point at) {
        const float normalized = std::isfinite(peak) ? std::clamp(peak, 0.0F, 1.0F) : 0.0F;
        samples_.emplace_back(at, normalized);
        expire(at);
    }

    [[nodiscard]] float value(Clock::time_point now) {
        expire(now);
        float peak = 0.0F;
        for (const auto& sample : samples_) peak = std::max(peak, sample.second);
        return peak;
    }

private:
    void expire(Clock::time_point now) {
        while (!samples_.empty() && now - samples_.front().first > window) samples_.pop_front();
    }

    std::deque<std::pair<Clock::time_point, float>> samples_{};
};

} // namespace wirex::audio_meter
