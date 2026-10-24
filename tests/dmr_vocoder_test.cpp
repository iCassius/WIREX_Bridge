#include "wirex/dmr_vocoder.hpp"
#include "mbe/mbevocoder.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <utility>
#include <vector>

namespace {

using wirex::dmr_vocoder::Codeword;
using wirex::dmr_vocoder::DecodeStatus;
using wirex::dmr_vocoder::PcmFrame;

const std::array<Codeword, 8> kTriangleCodewords{{
    Codeword{{0xD5, 0xEE, 0x22, 0x07, 0x41, 0xB9, 0x68, 0x0B, 0x2F}},
    Codeword{{0x51, 0x88, 0x62, 0x71, 0x74, 0x81, 0x16, 0x4A, 0xEF}},
    Codeword{{0x3D, 0x5F, 0x6D, 0xB0, 0xFA, 0x9E, 0xEA, 0x50, 0x59}},
    Codeword{{0xAB, 0xD4, 0x66, 0x14, 0x5E, 0xD2, 0x3B, 0xA0, 0xA4}},
    Codeword{{0xEB, 0x90, 0x22, 0x56, 0x91, 0x57, 0xA7, 0x24, 0xAC}},
    Codeword{{0xEB, 0xB0, 0x01, 0x54, 0xF2, 0x07, 0xA7, 0x60, 0xEC}},
    Codeword{{0xCA, 0xB0, 0x21, 0x12, 0xD2, 0x52, 0xE3, 0x60, 0xAC}},
    Codeword{{0xEB, 0xB0, 0x00, 0x54, 0xF2, 0x07, 0xA7, 0x60, 0xEC}},
}};
const std::array<Codeword, 8> kSilenceCodewords{{
    Codeword{{0xD5, 0xEE, 0x22, 0x07, 0x41, 0xB9, 0x68, 0x0B, 0x2F}},
    Codeword{{0xD5, 0x6F, 0x66, 0x63, 0x40, 0xB5, 0x00, 0xA3, 0xFB}},
    Codeword{{0x0E, 0xE8, 0x06, 0x72, 0x03, 0x81, 0x38, 0x8F, 0xEF}},
    Codeword{{0x7D, 0x08, 0x04, 0x31, 0x65, 0xF1, 0xE1, 0x67, 0xE7}},
    Codeword{{0x40, 0x9A, 0x40, 0x73, 0x76, 0x90, 0x25, 0x6A, 0xAB}},
    Codeword{{0x15, 0x86, 0x60, 0x67, 0x47, 0xB1, 0x4C, 0x82, 0x6F}},
    Codeword{{0x66, 0x44, 0x62, 0x43, 0x50, 0xF1, 0xC0, 0x4C, 0x05}},
    Codeword{{0x46, 0x44, 0x60, 0x22, 0x04, 0xC5, 0x94, 0x0C, 0x45}},
}};

PcmFrame triangle_frame()
{
    PcmFrame pcm{};
    for (int i = 0; i < static_cast<int>(pcm.size()); ++i) {
        const int phase = i % 20;
        pcm[static_cast<std::size_t>(i)] = static_cast<std::int16_t>(
            phase < 10 ? -20000 + phase * 4000 : 20000 - (phase - 10) * 4000);
    }
    return pcm;
}

bool check(bool condition, const char* label)
{
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", label);
        return false;
    }
    return true;
}

bool test_encode_golden_and_reset()
{
    using wirex::dmr_vocoder::Encoder;
    Encoder encoder;
    const auto pcm = triangle_frame();
    for (std::size_t i = 0; i < kTriangleCodewords.size(); ++i) {
        if (!check(encoder.encode(pcm) == kTriangleCodewords[i], "pinned upstream DMR codeword sequence")) {
            return false;
        }
    }

    encoder.reset();
    if (!check(encoder.encode(pcm) == kTriangleCodewords[0], "TX reset returns encoder to initial history")) {
        return false;
    }

    Encoder first;
    Encoder second;
    for (const auto& expected : kTriangleCodewords) {
        const auto a = first.encode(pcm);
        const auto b = second.encode(pcm);
        if (!check(a == expected && b == expected, "separate TX instances keep independent state")) {
            return false;
        }
    }
    return true;
}

bool test_silence_golden()
{
    using wirex::dmr_vocoder::Encoder;
    Encoder encoder;
    const PcmFrame silence{};
    for (std::size_t frame = 0; frame < kSilenceCodewords.size(); ++frame) {
        if (!check(encoder.encode(silence) == kSilenceCodewords[frame],
                   "continuous PCM silence matches pinned upstream DMR codeword sequence")) {
            return false;
        }
    }
    return true;
}

bool test_upstream_decoder_comparison()
{
    using wirex::dmr_vocoder::Decoder;
    const auto& codeword = kTriangleCodewords[3];

    MBEVocoder upstream;
    PcmFrame reference{};
    auto reference_input = codeword;
    std::srand(7);
    upstream.decode_2450x1150(reference.data(), reference_input.data());

    Decoder adapter;
    std::srand(7);
    const auto actual = adapter.decode(codeword);
    if (!check(actual.pcm == reference, "adapter PCM exactly matches direct pinned upstream decoder")) {
        return false;
    }
    if (!check(actual.status == DecodeStatus::decoded && actual.corrected_fec_bits == 0,
               "clean upstream codeword reports clean FEC status")) {
        return false;
    }

    adapter.reset();
    std::srand(7);
    const auto after_reset = adapter.decode(codeword);
    if (!check(after_reset.pcm == reference && after_reset.status == DecodeStatus::decoded,
               "RX reset rebuilds decoder history")) {
        return false;
    }
    return true;
}

bool test_decode_fec_and_erasure_status()
{
    using wirex::dmr_vocoder::Decoder;
    auto one_bit_error = kTriangleCodewords[3];
    one_bit_error[0] ^= 0x80;
    Decoder corrected_decoder;
    const auto corrected = corrected_decoder.decode(one_bit_error);
    if (!check(corrected.status == DecodeStatus::corrected && corrected.corrected_fec_bits == 1,
               "one correctable channel bit is counted")) {
        return false;
    }

    const Codeword fec_failure{{0x75, 0xCD, 0x25, 0x4B, 0x84, 0xE2, 0xEA, 0xF2, 0xA6}};
    Decoder concealment_decoder;
    const auto concealed = concealment_decoder.decode(fec_failure);
    if (!check(concealed.status == DecodeStatus::concealed && concealed.corrected_fec_bits == 5,
               "uncorrectable FEC follows upstream previous-frame concealment")) {
        return false;
    }

    Decoder repeated_error_decoder;
    (void)repeated_error_decoder.decode(fec_failure);
    (void)repeated_error_decoder.decode(fec_failure);
    (void)repeated_error_decoder.decode(fec_failure);
    const auto muted = repeated_error_decoder.decode(fec_failure);
    if (!check(muted.status == DecodeStatus::muted_repeated_errors,
               "upstream repeated-error policy eventually mutes")) {
        return false;
    }
    if (!check(std::all_of(muted.pcm.begin(), muted.pcm.end(), [](std::int16_t sample) { return sample == 0; }),
               "upstream repeated-error mute is all-zero PCM")) {
        return false;
    }

    const Codeword erasure_frame{{0xAF, 0xBB, 0xA0, 0x28, 0x96, 0xF3, 0xB0, 0x8A, 0x2D}};
    Decoder erasure_decoder;
    const auto erasure = erasure_decoder.decode(erasure_frame);
    if (!check(erasure.status == DecodeStatus::erasure && erasure.corrected_fec_bits == 2,
               "upstream AMBE erasure is surfaced")) {
        return false;
    }
    if (!check(std::all_of(erasure.pcm.begin(), erasure.pcm.end(), [](std::int16_t sample) { return sample == 0; }),
               "upstream erasure emits silence")) {
        return false;
    }

    return true;
}

void print_timing(const char* label, std::vector<double> samples_us)
{
    std::sort(samples_us.begin(), samples_us.end());
    const double sum = std::accumulate(samples_us.begin(), samples_us.end(), 0.0);
    const std::size_t p99_index = (samples_us.size() - 1) * 99 / 100;
    std::printf("%s: n=%zu avg=%.3fus p50=%.3fus p99=%.3fus max=%.3fus\n",
                label,
                samples_us.size(),
                sum / static_cast<double>(samples_us.size()),
                samples_us[samples_us.size() / 2],
                samples_us[p99_index],
                samples_us.back());
}

void measure_release_timing()
{
    using wirex::dmr_vocoder::Decoder;
    using wirex::dmr_vocoder::Encoder;
    constexpr std::size_t frames = 512;
    constexpr std::size_t warmup = 16;
    const auto pcm = triangle_frame();

    Encoder encoder;
    for (std::size_t i = 0; i < warmup; ++i) {
        (void)encoder.encode(pcm);
    }
    std::vector<double> encode_us;
    encode_us.reserve(frames);
    for (std::size_t i = 0; i < frames; ++i) {
        const auto start = std::chrono::steady_clock::now();
        (void)encoder.encode(pcm);
        const auto stop = std::chrono::steady_clock::now();
        encode_us.push_back(std::chrono::duration<double, std::micro>(stop - start).count());
    }
    print_timing("encode_20ms", std::move(encode_us));

    Decoder decoder;
    std::vector<double> decode_us;
    decode_us.reserve(frames);
    for (std::size_t i = 0; i < frames; ++i) {
        const auto start = std::chrono::steady_clock::now();
        (void)decoder.decode(kTriangleCodewords[3]);
        const auto stop = std::chrono::steady_clock::now();
        decode_us.push_back(std::chrono::duration<double, std::micro>(stop - start).count());
    }
    print_timing("decode_20ms", std::move(decode_us));
}

} // namespace

int main()
{
    if (!test_silence_golden() ||
        !test_encode_golden_and_reset() ||
        !test_upstream_decoder_comparison() ||
        !test_decode_fec_and_erasure_status()) {
        return 1;
    }

    std::puts("DMR vocoder golden, upstream-decoder, reset, and FEC checks passed.");
    measure_release_timing();
    return 0;
}
