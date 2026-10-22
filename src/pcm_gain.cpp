#include "wirex/pcm_gain.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace wirex::pcm_gain {
namespace {

std::uint64_t saturating_add(std::uint64_t left, std::uint64_t right) noexcept
{
    if (right > std::numeric_limits<std::uint64_t>::max() - left) {
        return std::numeric_limits<std::uint64_t>::max();
    }
    return left + right;
}

SignalStats measure_samples(const std::int16_t* samples, std::size_t count) noexcept
{
    SignalStats stats{};
    stats.sample_count = count;
    for (std::size_t i = 0; i < count; ++i) {
        const auto value = static_cast<std::int32_t>(samples[i]);
        const auto magnitude = static_cast<std::uint32_t>(value < 0 ? -value : value);
        stats.peak = std::max(stats.peak, magnitude);
        const auto wide = static_cast<std::int64_t>(value);
        stats.sum_squares = saturating_add(stats.sum_squares, static_cast<std::uint64_t>(wide * wide));
    }
    return stats;
}

double to_dbfs(double amplitude) noexcept
{
    if (amplitude <= 0.0) return -120.0;
    return 20.0 * std::log10(amplitude / 32768.0);
}

} // 匿名命名空间

bool supported_gain(std::uint32_t gain_milli) noexcept
{
    return gain_milli >= minimum_milli && gain_milli <= maximum_milli;
}

bool parse_gain(std::wstring_view text, std::uint32_t& gain_milli) noexcept
{
    if (text.empty()) return false;
    std::uint32_t whole = 0;
    std::uint32_t fraction = 0;
    std::uint32_t scale = 100;
    std::size_t index = 0;
    bool saw_whole_digit = false;
    while (index < text.size() && text[index] != L'.') {
        const wchar_t ch = text[index++];
        if (ch < L'0' || ch > L'9') return false;
        saw_whole_digit = true;
        const auto digit = static_cast<std::uint32_t>(ch - L'0');
        if (whole >= maximum_milli / unity_milli) return false;
        whole = whole * 10U + digit;
    }
    if (!saw_whole_digit) return false;

    if (index < text.size()) {
        ++index;
        if (index == text.size()) return false;
        std::size_t fractional_digits = 0;
        while (index < text.size()) {
            const wchar_t ch = text[index++];
            if (ch < L'0' || ch > L'9' || fractional_digits >= 3) return false;
            fraction += static_cast<std::uint32_t>(ch - L'0') * scale;
            scale /= 10U;
            ++fractional_digits;
        }
    }
    const auto parsed = whole * unity_milli + fraction;
    if (!supported_gain(parsed)) return false;
    gain_milli = parsed;
    return true;
}

SignalStats measure(const std::int16_t* samples, std::size_t count) noexcept
{
    if (samples == nullptr && count != 0) return {};
    return measure_samples(samples, count);
}

Result apply(std::int16_t* samples, std::size_t count, std::uint32_t gain_milli) noexcept
{
    Result result{};
    if ((!supported_gain(gain_milli)) || (samples == nullptr && count != 0)) return result;
    result.valid = true;
    result.before = measure_samples(samples, count);

    for (std::size_t i = 0; i < count; ++i) {
        const auto original = static_cast<std::int64_t>(samples[i]);
        const auto product = original * static_cast<std::int64_t>(gain_milli);
        const auto rounded = product >= 0 ? (product + 500) / 1000 : (product - 500) / 1000;
        if (rounded > std::numeric_limits<std::int16_t>::max()) ++result.clipped_samples;
        else if (rounded < std::numeric_limits<std::int16_t>::min()) ++result.clipped_samples;
        const auto limited = std::clamp<std::int64_t>(rounded,
            std::numeric_limits<std::int16_t>::min(), std::numeric_limits<std::int16_t>::max());
        samples[i] = static_cast<std::int16_t>(limited);
    }
    result.after = measure_samples(samples, count);
    return result;
}

void accumulate(SignalStats& total, const SignalStats& block) noexcept
{
    total.sample_count = saturating_add(total.sample_count, block.sample_count);
    total.sum_squares = saturating_add(total.sum_squares, block.sum_squares);
    total.peak = std::max(total.peak, block.peak);
}

double rms_dbfs(const SignalStats& stats) noexcept
{
    if (stats.sample_count == 0) return -120.0;
    const auto mean_square = static_cast<double>(stats.sum_squares) / static_cast<double>(stats.sample_count);
    return to_dbfs(std::sqrt(mean_square));
}

double peak_dbfs(const SignalStats& stats) noexcept
{
    return to_dbfs(static_cast<double>(stats.peak));
}

} // namespace wirex::pcm_gain
