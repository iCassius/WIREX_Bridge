#include "wirex/pcm_resampler.hpp"

#include <algorithm>
#include <cmath>

namespace wirex::audio {
namespace {

[[nodiscard]] const std::array<double, resampler_fir_taps>& coefficients() noexcept
{
    static const std::array<double, resampler_fir_taps> values = []() noexcept {
        std::array<double, resampler_fir_taps> result{};
        constexpr double pi = 3.1415926535897932384626433832795;
        constexpr double cutoff_cycles_per_sample = 3500.0 / 48000.0;
        double sum = 0.0;
        for (std::size_t index = 0U; index < result.size(); ++index) {
            const double centered = static_cast<double>(index) -
                                    static_cast<double>(result.size() - 1U) / 2.0;
            const double argument = 2.0 * cutoff_cycles_per_sample * centered;
            const double sinc = centered == 0.0
                ? 1.0
                : std::sin(pi * argument) / (pi * argument);
            const double position = static_cast<double>(index) /
                                    static_cast<double>(result.size() - 1U);
            const double window = 0.42 - 0.5 * std::cos(2.0 * pi * position) +
                                  0.08 * std::cos(4.0 * pi * position);
            result[index] = 2.0 * cutoff_cycles_per_sample * sinc * window;
            sum += result[index];
        }
        if (sum != 0.0) {
            for (double& value : result) {
                value /= sum;
            }
        }
        return result;
    }();
    return values;
}

[[nodiscard]] std::int16_t saturate_pcm(double sample) noexcept
{
    const long rounded = std::lround(sample);
    const long bounded = std::clamp(rounded,
                                    static_cast<long>(-32768L),
                                    static_cast<long>(32767L));
    return static_cast<std::int16_t>(bounded);
}

} // namespace

ResampleResult PcmResampler48To8::process(const std::int16_t* input,
                                          std::size_t input_count,
                                          std::int16_t* output,
                                          std::size_t output_capacity) noexcept
{
    ResampleResult result{};
    if ((input_count != 0U && input == nullptr) ||
        (output_capacity != 0U && output == nullptr) || finished_) {
        result.invalid_buffer = true;
        return result;
    }

    for (; result.input_consumed < input_count; ++result.input_consumed) {
        const bool emits_output = phase_ + 1U == resample_ratio_48k_8k;
        if (emits_output && result.output_written == output_capacity) {
            break;
        }
        push_sample(input[result.input_consumed]);
        ++phase_;
        if (phase_ == resample_ratio_48k_8k) {
            output[result.output_written++] = filtered_sample();
            phase_ = 0U;
        }
    }
    return result;
}

ResampleResult PcmResampler48To8::finish(std::int16_t* output,
                                         std::size_t output_capacity) noexcept
{
    ResampleResult result{};
    if ((output_capacity != 0U && output == nullptr) || finished_) {
        result.invalid_buffer = true;
        return result;
    }
    if (flush_remaining_ == 0U) {
        finished_ = true;
        return result;
    }

    while (flush_remaining_ != 0U) {
        const bool emits_output = phase_ + 1U == resample_ratio_48k_8k;
        if (emits_output && result.output_written == output_capacity) {
            break;
        }
        push_sample(0);
        --flush_remaining_;
        ++result.input_consumed;
        ++phase_;
        if (phase_ == resample_ratio_48k_8k) {
            output[result.output_written++] = filtered_sample();
            phase_ = 0U;
        }
    }
    if (flush_remaining_ == 0U) {
        finished_ = true;
    }
    return result;
}

void PcmResampler48To8::reset() noexcept
{
    history_.fill(0);
    cursor_ = 0U;
    phase_ = 0U;
    flush_remaining_ = 0U;
    finished_ = false;
}

void PcmResampler48To8::push_sample(std::int16_t sample) noexcept
{
    cursor_ = (cursor_ + 1U) % history_.size();
    history_[cursor_] = sample;
    // 第一次输入到来时，开始在 flush 里排出 126 个零输入尾样本。
    if (flush_remaining_ == 0U && !finished_) {
        flush_remaining_ = downsample_flush_input_samples;
    }
}

std::int16_t PcmResampler48To8::filtered_sample() const noexcept
{
    const auto& taps = coefficients();
    double sum = 0.0;
    for (std::size_t tap = 0U; tap < taps.size(); ++tap) {
        const std::size_t index = (cursor_ + history_.size() - tap) % history_.size();
        sum += taps[tap] * static_cast<double>(history_[index]);
    }
    return saturate_pcm(sum);
}

ResampleResult PcmResampler8To48::process(const std::int16_t* input,
                                          std::size_t input_count,
                                          std::int16_t* output,
                                          std::size_t output_capacity) noexcept
{
    ResampleResult result{};
    if ((input_count != 0U && input == nullptr) ||
        (output_capacity != 0U && output == nullptr) || finished_) {
        result.invalid_buffer = true;
        return result;
    }

    for (; result.input_consumed < input_count; ++result.input_consumed) {
        if (output_capacity - result.output_written < resample_ratio_48k_8k) {
            break;
        }
        push_sample(input[result.input_consumed]);
        for (std::size_t phase = 0U; phase < resample_ratio_48k_8k; ++phase) {
            output[result.output_written++] = filtered_phase(phase);
        }
    }
    return result;
}

ResampleResult PcmResampler8To48::finish(std::int16_t* output,
                                         std::size_t output_capacity) noexcept
{
    ResampleResult result{};
    if ((output_capacity != 0U && output == nullptr) || finished_) {
        result.invalid_buffer = true;
        return result;
    }
    if (flush_remaining_ == 0U) {
        finished_ = true;
        return result;
    }
    while (flush_remaining_ != 0U) {
        if (output_capacity - result.output_written < resample_ratio_48k_8k) {
            break;
        }
        push_sample(0);
        --flush_remaining_;
        ++result.input_consumed;
        for (std::size_t phase = 0U; phase < resample_ratio_48k_8k; ++phase) {
            output[result.output_written++] = filtered_phase(phase);
        }
    }
    if (flush_remaining_ == 0U) {
        finished_ = true;
    }
    return result;
}

void PcmResampler8To48::reset() noexcept
{
    history_.fill(0);
    cursor_ = 0U;
    flush_remaining_ = 0U;
    finished_ = false;
}

void PcmResampler8To48::push_sample(std::int16_t sample) noexcept
{
    cursor_ = (cursor_ + 1U) % history_.size();
    history_[cursor_] = sample;
    if (flush_remaining_ == 0U && !finished_) {
        flush_remaining_ = upsample_flush_input_samples;
    }
}

std::int16_t PcmResampler8To48::filtered_phase(std::size_t phase) const noexcept
{
    const auto& taps = coefficients();
    double sum = 0.0;
    for (std::size_t tap = phase; tap < taps.size(); tap += resample_ratio_48k_8k) {
        const std::size_t delay = tap / resample_ratio_48k_8k;
        const std::size_t index = (cursor_ + history_.size() - delay) % history_.size();
        sum += taps[tap] * static_cast<double>(history_[index]);
    }
    return saturate_pcm(sum * static_cast<double>(resample_ratio_48k_8k));
}

} // namespace wirex::audio
