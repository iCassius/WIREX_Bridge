/*
 * 本文件的 DMR A/B/C 位映射依照以下上游实现改写：
 * Copyright (C) 2010, 2014, 2016 and 2018 Jonathan Naylor G4KLX
 * Copyright (C) 2016 Mathias Weyland HB9FRV
 * Copyright (C) 2018 Andy Uribe CA6JAU
 * 来源：research/sources/upstream/juribeparada__MMDVM_CM/YSF2DMR/ModeConv.cpp
 * MMDVM_CM 提交：7328c9e9532d29cf4d9d7d24541d57f825207be4
 * SHA-256：b2f7a4a82ec64f169e5d98fcb34e17994611d7ebcc94d1774bcb35dfe5ce8844
 * 上游许可为 GPL-2.0-or-later；本项目将本文件按 GPL-3.0-or-later 发布。
 *
 * Golay 生成掩码取自 DroidStar MBE 的 mbevocoder.cpp；PRNG_TABLE 引自
 * 同一固定提交的 mbe/vocoder_tables.h：
 * 提交 becf1dede57c4a70a865e9cb4cac9247e505599a；上游 SHA-256 分别为
 * 7464a9d9cb27a7ab04eb3bf65b725268ddaefc6d85e4666ef600b568a76b07b1 和
 * 3ef6900a2e0f47c50e1fda1b4912f76a819348467d810223b5858684da0e727a。
 * 两文件采用 ISC 许可，保留原始第三方文本 third_party/droidstar_mbe/ISC-NOTICE.txt。
 */
#include "wirex/ambe_dmr72.hpp"

#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4305) // 只屏蔽固定上游浮点表的 double 转 float 初始化警告。
#endif
#include "mbe/vocoder_tables.h"
#if defined(_MSC_VER)
#pragma warning(pop)
#endif

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::ambe2450 {
namespace {

// DMR 位位置表遵循固定的 MMDVM_CM/YSF2DMR/ModeConv.cpp（提交
// 7328c9e9532d29cf4d9d7d24541d57f825207be4，GPL-2.0-or-later）。
constexpr std::array<std::uint8_t, 24U> kDmrATable{{
    0U, 4U, 8U, 12U, 16U, 20U, 24U, 28U, 32U, 36U, 40U, 44U,
    48U, 52U, 56U, 60U, 64U, 68U, 1U, 5U, 9U, 13U, 17U, 21U,
}};

constexpr std::array<std::uint8_t, 23U> kDmrBTable{{
    25U, 29U, 33U, 37U, 41U, 45U, 49U, 53U, 57U, 61U, 65U, 69U,
    2U, 6U, 10U, 14U, 18U, 22U, 26U, 30U, 34U, 38U, 42U,
}};

constexpr std::array<std::uint8_t, 25U> kDmrCTable{{
    46U, 50U, 54U, 58U, 62U, 66U, 70U, 3U, 7U, 11U, 15U, 19U, 23U,
    27U, 31U, 35U, 39U, 43U, 47U, 51U, 55U, 59U, 63U, 67U, 71U,
}};

// 这些生成掩码与固定 DroidStar MBE/mbevocoder.cpp 的 golay_24_encode 一致
// （提交 becf1dede57c4a70a865e9cb4cac9247e505599a，ISC notice）。
constexpr std::array<std::uint32_t, 12U> kGolay24Generators{{
    040006165U, 020003073U, 010007550U, 04003664U,
    02001732U, 01006631U, 0403315U, 0201547U,
    0106706U, 045227U, 024476U, 014353U,
}};

[[nodiscard]] std::uint32_t golay24_encode(std::uint16_t value) noexcept
{
    std::uint32_t codeword = 0U;
    for (std::size_t i = 0U; i < kGolay24Generators.size(); ++i) {
        const auto input_mask = static_cast<std::uint16_t>(1U << (11U - i));
        if ((value & input_mask) != 0U) {
            codeword ^= kGolay24Generators[i];
        }
    }
    return codeword;
}

[[nodiscard]] std::uint32_t golay23_encode(std::uint16_t value) noexcept
{
    return golay24_encode(value) >> 1U;
}

template <std::size_t N>
void write_indexed_bits(DmrCodeword& codeword,
                        const std::array<std::uint8_t, N>& positions,
                        std::uint32_t value,
                        std::uint32_t width) noexcept
{
    for (std::size_t i = 0U; i < positions.size(); ++i) {
        const auto source_mask = std::uint32_t{1U} << (width - 1U - static_cast<std::uint32_t>(i));
        if ((value & source_mask) != 0U) {
            const auto position = positions[i];
            codeword[position / 8U] |= static_cast<std::uint8_t>(0x80U >> (position % 8U));
        }
    }
}

template <std::size_t N>
[[nodiscard]] std::uint32_t read_indexed_bits(const DmrCodeword& codeword,
                                              const std::array<std::uint8_t, N>& positions) noexcept
{
    std::uint32_t value = 0U;
    for (const auto position : positions) {
        const auto bit = (codeword[position / 8U] >> (7U - (position % 8U))) & 1U;
        value = (value << 1U) | bit;
    }
    return value;
}

} // namespace

bool encode_dmr72(const Parameters& parameters, DmrCodeword& output) noexcept
{
    if (!is_valid(parameters)) {
        return false;
    }

    DmrCodeword encoded{};
    const auto a_codeword = golay24_encode(parameters.a);
    // PRNG_TABLE 来自同一固定上游的 mbe/vocoder_tables.h（ISC notice）。
    const auto b_prng = PRNG_TABLE[parameters.a] >> 1U;
    const auto b_codeword = golay23_encode(parameters.b) ^ b_prng;

    write_indexed_bits(encoded, kDmrATable, a_codeword, 24U);
    write_indexed_bits(encoded, kDmrBTable, b_codeword, 23U);
    write_indexed_bits(encoded, kDmrCTable, parameters.c, 25U);

    output = encoded;
    return true;
}

DmrDecodeResult decode_dmr72(const DmrCodeword& codeword) noexcept
{
    const auto a_codeword = read_indexed_bits(codeword, kDmrATable);
    const auto b_codeword = read_indexed_bits(codeword, kDmrBTable);
    const auto c = read_indexed_bits(codeword, kDmrCTable);

    DmrDecodeResult result;
    result.parameters.a = static_cast<std::uint16_t>(a_codeword >> 12U);
    result.parameters.b = static_cast<std::uint16_t>(
        (b_codeword ^ (PRNG_TABLE[result.parameters.a] >> 1U)) >> 11U);
    result.parameters.c = c;

    DmrCodeword regenerated{};
    result.reencode_matches = encode_dmr72(result.parameters, regenerated) && regenerated == codeword;
    return result;
}

} // namespace wirex::ambe2450
