#include "wirex/ambe_dmr72.hpp"

#include <array>
#include <cstdint>
#include <cstdio>

namespace {

using wirex::ambe2450::DmrCodeword;
using wirex::ambe2450::Parameters;

struct MbeGolden {
    DmrCodeword codeword;
    Parameters parameters;
};

// 这些72位码字来自现有 dmr_vocoder_test.cpp 的固定零PCM编码序列。
// 它们检查MBE Golay/PRNG输出，不是b0=124/125的保留静音码字。
constexpr std::array<MbeGolden, 8U> kMbeZeroPcmGoldens{{
    MbeGolden{DmrCodeword{{0xD5, 0xEE, 0x22, 0x07, 0x41, 0xB9, 0x68, 0x0B, 0x2F}},
              Parameters{0x0B03, 0x02B9, 0x09F05C5}},
    MbeGolden{DmrCodeword{{0xD5, 0x6F, 0x66, 0x63, 0x40, 0xB5, 0x00, 0xA3, 0xFB}},
              Parameters{0x0902, 0x02D9, 0x03F44C7}},
    MbeGolden{DmrCodeword{{0x0E, 0xE8, 0x06, 0x72, 0x03, 0x81, 0x38, 0x8F, 0xEF}},
              Parameters{0x0702, 0x02B3, 0x09C0965}},
    MbeGolden{DmrCodeword{{0x7D, 0x08, 0x04, 0x31, 0x65, 0xF1, 0xE1, 0x67, 0xE7}},
              Parameters{0x0502, 0x02B9, 0x0BF0DD5}},
    MbeGolden{DmrCodeword{{0x40, 0x9A, 0x40, 0x73, 0x76, 0x90, 0x25, 0x6A, 0xAB}},
              Parameters{0x0302, 0x02D4, 0x0BC8E91}},
    MbeGolden{DmrCodeword{{0x15, 0x86, 0x60, 0x67, 0x47, 0xB1, 0x4C, 0x82, 0x6F}},
              Parameters{0x0202, 0x02B9, 0x01F05C1}},
    MbeGolden{DmrCodeword{{0x66, 0x44, 0x62, 0x43, 0x50, 0xF1, 0xC0, 0x4C, 0x05}},
              Parameters{0x0002, 0x09A9, 0x00006C1}},
    MbeGolden{DmrCodeword{{0x46, 0x44, 0x60, 0x22, 0x04, 0xC5, 0x94, 0x0C, 0x45}},
              Parameters{0x0002, 0x02D3, 0x0000061}},
}};

constexpr DmrCodeword kDmrSilence{{0xB9, 0xE8, 0x81, 0x52, 0x61, 0x73, 0x00, 0x2A, 0x6B}};
constexpr Parameters kSilenceParameters{0x0F80, 0x01A9, 0x13F19C1};
constexpr std::array<std::uint8_t, 7U> kPackedSilenceParameters{{
    0xF8, 0x01, 0xA9, 0x9F, 0x8C, 0xE0, 0x80,
}};

bool check(bool condition, const char* label)
{
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", label);
        return false;
    }
    return true;
}

std::array<std::uint8_t, 7U> pack_parameters(const Parameters& parameters)
{
    std::array<std::uint8_t, 7U> packed{};
    std::uint32_t bit_index = 0U;
    const auto append = [&packed, &bit_index](std::uint32_t value, std::uint32_t width) {
        for (std::uint32_t i = 0U; i < width; ++i, ++bit_index) {
            const auto source_bit = (value >> (width - 1U - i)) & 1U;
            if (source_bit != 0U) {
                packed[bit_index / 8U] |= static_cast<std::uint8_t>(0x80U >> (bit_index % 8U));
            }
        }
    };
    append(parameters.a, 12U);
    append(parameters.b, 12U);
    append(parameters.c, 25U);
    return packed;
}

bool test_pinned_silence_vectors()
{
    const auto decoded = wirex::ambe2450::decode_dmr72(kDmrSilence);
    if (!check(decoded.parameters.a == kSilenceParameters.a &&
                   decoded.parameters.b == kSilenceParameters.b &&
                   decoded.parameters.c == kSilenceParameters.c,
               "MMDVM DMR silence vector yields the cross-checked 49-bit parameters")) {
        return false;
    }
    if (!check(decoded.reencode_matches, "DMR silence vector exactly re-encodes")) {
        return false;
    }
    if (!check(pack_parameters(decoded.parameters) == kPackedSilenceParameters,
               "49-bit parameters match the pinned YSF silence vector extraction")) {
        return false;
    }

    DmrCodeword encoded{};
    return check(wirex::ambe2450::encode_dmr72(kSilenceParameters, encoded) && encoded == kDmrSilence,
                 "49-bit silence parameters encode to the pinned DMR silence vector");
}

bool test_mbe_encoder_goldens()
{
    for (const auto& golden : kMbeZeroPcmGoldens) {
        const auto decoded = wirex::ambe2450::decode_dmr72(golden.codeword);
        if (!check(decoded.parameters.a == golden.parameters.a &&
                       decoded.parameters.b == golden.parameters.b &&
                       decoded.parameters.c == golden.parameters.c,
                   "pinned MBE 72-bit fixture yields its independently extracted parameters")) {
            return false;
        }
        if (!check(decoded.reencode_matches, "pinned MBE 72-bit fixture satisfies Golay/PRNG re-encoding")) {
            return false;
        }

        DmrCodeword encoded{};
        if (!check(wirex::ambe2450::encode_dmr72(golden.parameters, encoded) && encoded == golden.codeword,
                   "parameters re-encode to the pinned MBE 72-bit fixture")) {
            return false;
        }
    }
    return true;
}

bool test_parameter_bounds_and_output_preservation()
{
    if (!check(wirex::ambe2450::is_valid(Parameters{0x0FFF, 0x0FFF, 0x01FFFFFF}),
               "largest 12/12/25-bit parameter values are valid")) {
        return false;
    }
    if (!check(!wirex::ambe2450::is_valid(Parameters{0x1000, 0x0000, 0x00000000}) &&
                   !wirex::ambe2450::is_valid(Parameters{0x0000, 0x1000, 0x00000000}) &&
                   !wirex::ambe2450::is_valid(Parameters{0x0000, 0x0000, 0x02000000}),
               "each parameter field rejects the first out-of-range value")) {
        return false;
    }

    const std::array<Parameters, 3U> invalid{{
        Parameters{0x1000, 0x0000, 0x00000000},
        Parameters{0x0000, 0x1000, 0x00000000},
        Parameters{0x0000, 0x0000, 0x02000000},
    }};
    for (const auto& parameters : invalid) {
        DmrCodeword output{};
        output.fill(0xA5);
        if (!check(!wirex::ambe2450::encode_dmr72(parameters, output), "out-of-range parameters are rejected")) {
            return false;
        }
        if (!check(output == DmrCodeword{{0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5}},
                   "rejected encoding leaves the caller output unchanged")) {
            return false;
        }
    }

    const Parameters maximum{0x0FFF, 0x0FFF, 0x01FFFFFF};
    DmrCodeword max_codeword{};
    if (!check(wirex::ambe2450::encode_dmr72(maximum, max_codeword), "maximum valid parameters encode")) {
        return false;
    }
    const auto max_decoded = wirex::ambe2450::decode_dmr72(max_codeword);
    return check(max_decoded.parameters.a == maximum.a && max_decoded.parameters.b == maximum.b &&
                     max_decoded.parameters.c == maximum.c && max_decoded.reencode_matches,
                 "maximum valid parameters remain within all declared bit widths");
}

bool test_parity_mismatch_is_not_corrected()
{
    auto corrupted = kDmrSilence;
    // DMR_A_TABLE第13项（0起）是Golay A字段校验位，不影响提取出的12个系统位。
    corrupted[6] ^= 0x80U;
    const auto decoded = wirex::ambe2450::decode_dmr72(corrupted);
    return check(decoded.parameters.a == kSilenceParameters.a &&
                     decoded.parameters.b == kSilenceParameters.b &&
                     decoded.parameters.c == kSilenceParameters.c,
                 "parity-bit error preserves the systematic parameter candidate") &&
           check(!decoded.reencode_matches, "parity-bit error is reported without claiming correction");
}

} // namespace

int main()
{
    if (!test_pinned_silence_vectors() || !test_mbe_encoder_goldens() ||
        !test_parameter_bounds_and_output_preservation() || !test_parity_mismatch_is_not_corrected()) {
        return 1;
    }
    std::puts("AMBE 49-bit parameters and DMR 72-bit mapping checks passed.");
    return 0;
}
