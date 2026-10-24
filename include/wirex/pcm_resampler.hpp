#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::audio {

inline constexpr std::size_t resample_ratio_48k_8k = 6U;
inline constexpr std::size_t resampler_fir_taps = 127U;
inline constexpr std::size_t downsample_flush_input_samples = resampler_fir_taps - 1U;
inline constexpr std::size_t upsample_flush_input_samples = resampler_fir_taps / resample_ratio_48k_8k;

struct ResampleResult {
    std::size_t input_consumed{};
    std::size_t output_written{};
    bool invalid_buffer{};
};

// 48 kHz 到 8 kHz 的单声道 PCM16 流式抗混叠滤波器。
// process 保留滤波历史和六分频相位；finish 以零输入排出滤波尾部。
class PcmResampler48To8 final {
public:
    [[nodiscard]] ResampleResult process(const std::int16_t* input,
                                         std::size_t input_count,
                                         std::int16_t* output,
                                         std::size_t output_capacity) noexcept;
    [[nodiscard]] ResampleResult finish(std::int16_t* output,
                                        std::size_t output_capacity) noexcept;
    void reset() noexcept;

private:
    void push_sample(std::int16_t sample) noexcept;
    [[nodiscard]] std::int16_t filtered_sample() const noexcept;

    std::array<std::int16_t, resampler_fir_taps> history_{};
    std::size_t cursor_{};
    std::size_t phase_{};
    std::size_t flush_remaining_{};
    bool finished_{};
};

// 8 kHz 到 48 kHz 的单声道 PCM16 流式插值滤波器。
// 每个输入样本产生 6 个抗镜像滤波输出样本。
class PcmResampler8To48 final {
public:
    [[nodiscard]] ResampleResult process(const std::int16_t* input,
                                         std::size_t input_count,
                                         std::int16_t* output,
                                         std::size_t output_capacity) noexcept;
    [[nodiscard]] ResampleResult finish(std::int16_t* output,
                                        std::size_t output_capacity) noexcept;
    void reset() noexcept;

private:
    void push_sample(std::int16_t sample) noexcept;
    [[nodiscard]] std::int16_t filtered_phase(std::size_t phase) const noexcept;

    std::array<std::int16_t, resampler_fir_taps> history_{};
    std::size_t cursor_{};
    std::size_t flush_remaining_{};
    bool finished_{};
};

} // namespace wirex::audio
