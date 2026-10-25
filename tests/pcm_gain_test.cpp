#include "wirex/pcm_gain.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>

namespace {

int failures = 0;

void check(bool condition, const char* message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void test_unity_preserves_pcm_and_stats()
{
    std::array<std::int16_t, 5> samples{-32768, -1000, 0, 1000, 32767};
    const auto original = samples;
    const auto result = wirex::pcm_gain::apply(samples.data(), samples.size(), wirex::pcm_gain::unity_milli);
    check(result.valid, "unity gain should be accepted");
    check(samples == original, "unity gain should preserve every sample exactly");
    check(result.clipped_samples == 0, "unity gain should not count clipping");
    check(result.before.sample_count == 5 && result.after.sample_count == 5,
        "before and after stats should count all samples");
    check(result.before.sum_squares == result.after.sum_squares && result.before.peak == result.after.peak,
        "unity gain should preserve measured RMS input and peak");
}

void test_attenuation_rounds_to_nearest()
{
    std::array<std::int16_t, 4> samples{32767, -32768, 1, -1};
    const auto result = wirex::pcm_gain::apply(samples.data(), samples.size(), 500);
    check(result.valid, "0.5x gain should be accepted");
    check(samples == std::array<std::int16_t, 4>{16384, -16384, 1, -1},
        "0.5x gain should round half-way values away from zero");
    check(result.clipped_samples == 0, "attenuation should not clip full-scale input");
}

void test_amplification_saturates_and_counts_clips()
{
    std::array<std::int16_t, 4> samples{22000, -22000, 1000, -1000};
    const auto result = wirex::pcm_gain::apply(samples.data(), samples.size(), 1500);
    check(result.valid, "1.5x gain should be accepted");
    check(samples == std::array<std::int16_t, 4>{32767, -32768, 1500, -1500},
        "amplification should saturate at signed 16-bit limits");
    check(result.clipped_samples == 2, "each saturated sample should increment the clipping count");
    check(result.after.peak == 32768, "post-gain peak should report the negative full-scale magnitude");

    std::array<std::int16_t, 4> high_gain_samples{2, -2, 32767, -32768};
    const auto high_gain = wirex::pcm_gain::apply(high_gain_samples.data(), high_gain_samples.size(), 16000);
    check(high_gain.valid, "16x diagnostic gain should be accepted");
    check(high_gain_samples == std::array<std::int16_t, 4>{32, -32, 32767, -32768},
        "16x diagnostic gain should scale below-full-scale samples and saturate peaks");
    check(high_gain.clipped_samples == 2, "16x diagnostic gain should count both clipped peak samples");
}

void test_radio_playback_gain_is_independent_from_microphone_gain()
{
    std::array<std::int16_t, 3> playback_samples{1000, -1000, 22000};
    const auto playback = wirex::pcm_gain::apply(playback_samples.data(), playback_samples.size(), 1500U);
    check(playback.valid, "radio playback gain should accept an independently selected value");
    check(playback_samples == std::array<std::int16_t, 3>{1500, -1500, 32767},
        "radio playback gain should scale the receive frame once and saturate its high sample");
    check(playback.clipped_samples == 1U,
        "radio playback clipping statistics should describe the receive gain result");

    std::array<std::int16_t, 3> microphone_samples{1000, -1000, 2};
    const auto microphone = wirex::pcm_gain::apply(
        microphone_samples.data(), microphone_samples.size(), 16000U);
    check(microphone.valid, "microphone transmit gain should accept its independent default");
    check(microphone_samples == std::array<std::int16_t, 3>{16000, -16000, 32},
        "microphone transmit gain should preserve the existing 16x default");
    check(microphone.clipped_samples == 0U,
        "microphone clipping statistics should remain separate from playback clipping");
}

void test_invalid_gain_does_not_modify_samples()
{
    for (const auto gain : {0U, 249U, 16001U}) {
        std::array<std::int16_t, 3> samples{1234, -2345, 32767};
        const auto original = samples;
        const auto result = wirex::pcm_gain::apply(samples.data(), samples.size(), gain);
        check(!result.valid, "out-of-range gain should be rejected");
        check(samples == original, "rejected gain should leave PCM unchanged");
    }
    check(!wirex::pcm_gain::supported_gain(249), "gain below 0.25x should be unsupported");
    check(wirex::pcm_gain::supported_gain(250) && wirex::pcm_gain::supported_gain(16000),
        "inclusive gain bounds should be supported");
    check(!wirex::pcm_gain::supported_gain(16001), "gain above 16.0x should be unsupported");
}

void test_gain_argument_parser()
{
    std::uint32_t gain = 0;
    check(wirex::pcm_gain::parse_gain(L"1", gain) && gain == 1000,
        "integer gain should parse as a milli multiplier");
    check(wirex::pcm_gain::parse_gain(L"0.25", gain) && gain == 250,
        "minimum fractional gain should parse exactly");
    check(wirex::pcm_gain::parse_gain(L"8.5", gain) && gain == 8500,
        "high diagnostic gain should parse exactly");
    check(wirex::pcm_gain::parse_gain(L"16.000", gain) && gain == 16000,
        "maximum gain should parse exactly");
    for (const auto invalid : {L"0.249", L"16.001", L"1.0000", L"-1", L"1e0", L".5", L"1."}) {
        check(!wirex::pcm_gain::parse_gain(invalid, gain), "malformed or out-of-range gain text should be rejected");
    }
}

void test_dbfs_and_accumulation()
{
    const std::array<std::int16_t, 2> samples{32767, 0};
    auto total = wirex::pcm_gain::measure(samples.data(), samples.size());
    check(std::abs(wirex::pcm_gain::rms_dbfs(total) - (-3.0103)) < 0.01,
        "RMS of half-full-scale energy should be about -3.01 dBFS");
    check(wirex::pcm_gain::peak_dbfs(total) < 0.0 && wirex::pcm_gain::peak_dbfs(total) > -0.001,
        "32767 peak should be just below 0 dBFS");
    const auto silence = wirex::pcm_gain::measure(nullptr, 0);
    check(wirex::pcm_gain::rms_dbfs(silence) == -120.0 && wirex::pcm_gain::peak_dbfs(silence) == -120.0,
        "empty/silent stats should use the documented -120 dBFS floor");

    wirex::pcm_gain::accumulate(total, silence);
    check(total.sample_count == 2 && total.peak == 32767,
        "accumulating an empty block should preserve sample count and peak");
}

} // namespace

int main()
{
    test_unity_preserves_pcm_and_stats();
    test_attenuation_rounds_to_nearest();
    test_amplification_saturates_and_counts_clips();
    test_radio_playback_gain_is_independent_from_microphone_gain();
    test_invalid_gain_does_not_modify_samples();
    test_gain_argument_parser();
    test_dbfs_and_accumulation();
    if (failures != 0) {
        std::cerr << failures << " PCM gain check(s) failed.\n";
        return 1;
    }
    std::cout << "All PCM gain checks passed.\n";
    return 0;
}
