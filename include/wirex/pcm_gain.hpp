#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace wirex::pcm_gain {

inline constexpr std::uint32_t unity_milli = 1000;
inline constexpr std::uint32_t minimum_milli = 250;
inline constexpr std::uint32_t maximum_milli = 16000;

struct SignalStats {
    std::uint64_t sample_count{0};
    std::uint64_t sum_squares{0};
    std::uint32_t peak{0};
};

struct Result {
    SignalStats before{};
    SignalStats after{};
    std::uint64_t clipped_samples{0};
    bool valid{false};
};

[[nodiscard]] bool supported_gain(std::uint32_t gain_milli) noexcept;
[[nodiscard]] bool parse_gain(std::wstring_view text, std::uint32_t& gain_milli) noexcept;
[[nodiscard]] SignalStats measure(const std::int16_t* samples, std::size_t count) noexcept;
[[nodiscard]] Result apply(std::int16_t* samples, std::size_t count, std::uint32_t gain_milli) noexcept;
void accumulate(SignalStats& total, const SignalStats& block) noexcept;
[[nodiscard]] double rms_dbfs(const SignalStats& stats) noexcept;
[[nodiscard]] double peak_dbfs(const SignalStats& stats) noexcept;

} // namespace wirex::pcm_gain
