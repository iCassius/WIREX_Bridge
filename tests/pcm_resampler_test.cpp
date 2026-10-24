#include "wirex/pcm_resampler.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

[[nodiscard]] bool require(bool condition, const char* message)
{
    if (!condition) {
        std::cerr << message << '\n';
    }
    return condition;
}

[[nodiscard]] std::vector<std::int16_t> downsample(const std::vector<std::int16_t>& input,
                                                   std::size_t chunk_size)
{
    wirex::audio::PcmResampler48To8 resampler;
    std::vector<std::int16_t> output(input.size() / 6U + 64U);
    std::size_t output_count = 0U;
    for (std::size_t offset = 0U; offset < input.size();) {
        const std::size_t count = std::min(chunk_size, input.size() - offset);
        const auto result = resampler.process(input.data() + offset, count,
                                              output.data() + output_count,
                                              output.size() - output_count);
        if (result.invalid_buffer || result.input_consumed != count) {
            return {};
        }
        offset += result.input_consumed;
        output_count += result.output_written;
    }
    const auto tail = resampler.finish(output.data() + output_count, output.size() - output_count);
    if (tail.invalid_buffer || tail.input_consumed > wirex::audio::downsample_flush_input_samples) {
        return {};
    }
    output_count += tail.output_written;
    output.resize(output_count);
    return output;
}

[[nodiscard]] double rms(const std::vector<std::int16_t>& samples,
                         std::size_t start,
                         std::size_t count)
{
    double sum = 0.0;
    for (std::size_t index = start; index < start + count; ++index) {
        const double value = static_cast<double>(samples[index]);
        sum += value * value;
    }
    return std::sqrt(sum / static_cast<double>(count));
}

} // namespace

int main()
{
    constexpr double pi = 3.1415926535897932384626433832795;
    constexpr std::size_t input_count = 48000U;
    std::vector<std::int16_t> tone_1k(input_count);
    std::vector<std::int16_t> tone_6k(input_count);
    std::vector<std::int16_t> dc(input_count, 12000);
    for (std::size_t index = 0U; index < input_count; ++index) {
        const double time = static_cast<double>(index) / 48000.0;
        tone_1k[index] = static_cast<std::int16_t>(std::lround(12000.0 * std::sin(2.0 * pi * 1000.0 * time)));
        tone_6k[index] = static_cast<std::int16_t>(std::lround(12000.0 * std::sin(2.0 * pi * 6000.0 * time)));
    }

    const auto one_k = downsample(tone_1k, 480U);
    const auto one_k_split = downsample(tone_1k, 137U);
    const auto six_k = downsample(tone_6k, 733U);
    const auto dc_out = downsample(dc, 1920U);
    if (!require(!one_k.empty() && one_k.size() == 8021U, "48-to-8 kHz first/tail sample count mismatch") ||
        !require(one_k == one_k_split, "48-to-8 kHz output changed with input block boundaries") ||
        !require(six_k.size() == one_k.size(), "stopband sample count mismatch") ||
        !require(dc_out.size() == one_k.size(), "DC sample count mismatch")) {
        return 1;
    }

    const double pass_rms = rms(one_k, 100U, 7600U);
    const double stop_rms = rms(six_k, 100U, 7600U);
    const double dc_mean = [&dc_out]() {
        double sum = 0.0;
        for (std::size_t index = 100U; index < 7700U; ++index) {
            sum += static_cast<double>(dc_out[index]);
        }
        return sum / 7600.0;
    }();
    if (!require(pass_rms > 8200.0 && pass_rms < 8800.0, "1 kHz passband level outside tolerance") ||
        !require(stop_rms < pass_rms * 0.001, "6 kHz alias was not sufficiently attenuated") ||
        !require(dc_mean > 11900.0 && dc_mean < 12100.0, "48-to-8 kHz DC gain outside tolerance")) {
        return 1;
    }

    wirex::audio::PcmResampler8To48 upsampler;
    std::array<std::int16_t, 800U> up_input{};
    up_input.fill(10000);
    std::array<std::int16_t, 4800U + wirex::audio::upsample_flush_input_samples * 6U> up_output{};
    const auto up_result = upsampler.process(up_input.data(), up_input.size(),
                                             up_output.data(), up_output.size());
    const auto up_tail = upsampler.finish(up_output.data() + up_result.output_written,
                                          up_output.size() - up_result.output_written);
    if (!require(!up_result.invalid_buffer && up_result.input_consumed == up_input.size() &&
                 up_result.output_written == up_input.size() * 6U &&
                 !up_tail.invalid_buffer && up_tail.output_written == 126U &&
                 up_result.output_written + up_tail.output_written == up_output.size(),
                 "8-to-48 kHz first/tail sample count mismatch") ||
        !require(std::all_of(up_output.begin() + 1000, up_output.end() - 1000,
                             [](std::int16_t sample) { return sample > 9900 && sample < 10100; }),
                 "8-to-48 kHz DC gain outside tolerance")) {
        return 1;
    }

    wirex::audio::PcmResampler8To48 split_up;
    std::array<std::int16_t, 4800U + wirex::audio::upsample_flush_input_samples * 6U> split_output{};
    std::size_t output_offset = 0U;
    for (std::size_t offset = 0U; offset < up_input.size();) {
        const std::size_t count = std::min<std::size_t>(37U, up_input.size() - offset);
        const auto result = split_up.process(up_input.data() + offset, count,
                                             split_output.data() + output_offset,
                                             split_output.size() - output_offset);
        if (!require(!result.invalid_buffer && result.input_consumed == count,
                     "8-to-48 kHz split input was not fully consumed")) {
            return 1;
        }
        offset += result.input_consumed;
        output_offset += result.output_written;
    }
    const auto split_tail = split_up.finish(split_output.data() + output_offset,
                                            split_output.size() - output_offset);
    output_offset += split_tail.output_written;
    if (!require(!split_tail.invalid_buffer && output_offset == split_output.size() &&
                 split_output == up_output,
                 "8-to-48 kHz output changed with input block boundaries or tail count")) {
        return 1;
    }

    std::cout << "PCM resampler anti-alias, interpolation, count, DC, and block-boundary checks passed.\n";
    std::cout << "1kHz_RMS=" << pass_rms << " 6kHz_alias_RMS=" << stop_rms
              << " dc_mean=" << dc_mean << " down_samples=" << one_k.size() << '\n';
    return 0;
}
