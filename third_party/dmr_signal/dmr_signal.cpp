/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Portions reworked from MMDVM_CM USRP2DMR files BPTC19696.cpp,
 * DMRFullLC.cpp, DMRSlotType.cpp, Golay2087.cpp, DMREMB.cpp,
 * DMREmbeddedData.cpp, QR1676.cpp, RS129.cpp, Hamming.cpp, CRC.cpp,
 * Sync.cpp and DMRDefines.h. Original copyright notices for the portions
 * used are retained in third_party/dmr_signal/NOTICE.md:
 * Copyright (C) 2012 by Ian Wraith.
 * Copyright (C) 2015,2016,2017 by Jonathan Naylor G4KLX.
 * Copyright (C) 2018 by Andy Uribe CA6JAU.
 * Voice-burst placement also follows DroidStar dmr.cpp:
 * Copyright (C) 2019-2021 Doug McLain.
 * Fixed source: juribeparada/MMDVM_CM commit
 * 7328c9e9532d29cf4d9d7d24541d57f825207be4 (GPL-2.0-or-later).
 * Voice-burst placement follows nostar/DroidStar dmr.cpp at commit
 * becf1dede57c4a70a865e9cb4cac9247e505599a (GPL-3.0-or-later).
 *
 * This implementation is distributed under GPL-3.0-or-later, which is
 * permitted by the MMDVM_CM source's "or later" grant. It contains no AMBE
 * vocoder implementation.
 */
#include "dmr_signal.hpp"

#include <algorithm>
#include <array>
#include <bitset>
#include <cstdint>

namespace wirex::dmr_signal {
namespace {

constexpr std::array<std::uint8_t, 3U> voice_lc_header_mask{{0x96U, 0x96U, 0x96U}};
constexpr std::array<std::uint8_t, 3U> terminator_lc_mask{{0x99U, 0x99U, 0x99U}};
constexpr std::array<std::uint8_t, 7U> sync_mask{{0x0FU, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0xFFU, 0xF0U}};
constexpr std::array<std::uint8_t, 7U> bs_audio_sync{{0x07U, 0x55U, 0xFDU, 0x7DU, 0xF7U, 0x5FU, 0x70U}};
constexpr std::array<std::uint8_t, 7U> ms_audio_sync{{0x07U, 0xF7U, 0xD5U, 0xDDU, 0x57U, 0xDFU, 0xD0U}};
constexpr std::array<std::uint8_t, 7U> bs_data_sync{{0x0DU, 0xFFU, 0x57U, 0xD7U, 0x5DU, 0xF5U, 0xD0U}};
constexpr std::array<std::uint8_t, 7U> ms_data_sync{{0x0DU, 0x5DU, 0x7FU, 0x77U, 0xFDU, 0x75U, 0x70U}};

[[nodiscard]] bool get_bit(const std::uint8_t* bytes, std::size_t bit) noexcept
{
    return (bytes[bit / 8U] & static_cast<std::uint8_t>(0x80U >> (bit % 8U))) != 0U;
}

void set_bit(std::uint8_t* bytes, std::size_t bit, bool value) noexcept
{
    const auto mask = static_cast<std::uint8_t>(0x80U >> (bit % 8U));
    if (value) {
        bytes[bit / 8U] |= mask;
    } else {
        bytes[bit / 8U] &= static_cast<std::uint8_t>(~mask);
    }
}

void bytes_to_bits(const std::uint8_t* bytes, std::size_t byte_count, bool* bits) noexcept
{
    for (std::size_t i = 0U; i < byte_count; ++i) {
        for (std::size_t b = 0U; b < 8U; ++b) {
            bits[i * 8U + b] = (bytes[i] & static_cast<std::uint8_t>(0x80U >> b)) != 0U;
        }
    }
}

void bits_to_bytes(const bool* bits, std::size_t byte_count, std::uint8_t* bytes) noexcept
{
    for (std::size_t i = 0U; i < byte_count; ++i) {
        std::uint8_t value = 0U;
        for (std::size_t b = 0U; b < 8U; ++b) {
            if (bits[i * 8U + b]) {
                value |= static_cast<std::uint8_t>(0x80U >> b);
            }
        }
        bytes[i] = value;
    }
}

[[nodiscard]] std::uint32_t polynomial_remainder(
    std::uint32_t value, std::uint32_t generator, unsigned int degree) noexcept
{
    if (value == 0U) {
        return 0U;
    }
    for (int bit = 31; bit >= static_cast<int>(degree); --bit) {
        if ((value & (std::uint32_t{1U} << static_cast<unsigned int>(bit))) != 0U) {
            value ^= generator << (static_cast<unsigned int>(bit) - degree);
        }
    }
    return value;
}

[[nodiscard]] std::uint32_t golay19_codeword(std::uint8_t value) noexcept
{
    constexpr std::uint32_t generator = 0x0C75U;
    const auto message = static_cast<std::uint32_t>(value) << 11U;
    return message | polynomial_remainder(message, generator, 11U);
}

[[nodiscard]] const std::array<int, 2048U>& golay_error_table() noexcept
{
    static const auto table = [] {
        std::array<int, 2048U> values{};
        values.fill(-1);
        const auto add = [&values](std::uint32_t error) {
            const auto syndrome = polynomial_remainder(error, 0x0C75U, 11U);
            if (values[syndrome] == -1) {
                values[syndrome] = static_cast<int>(error);
            }
        };
        add(0U);
        for (std::uint32_t i = 0U; i < 19U; ++i) {
            add(std::uint32_t{1U} << i);
        }
        for (std::uint32_t i = 0U; i < 19U; ++i) {
            for (std::uint32_t j = i + 1U; j < 19U; ++j) {
                add((std::uint32_t{1U} << i) | (std::uint32_t{1U} << j));
            }
        }
        for (std::uint32_t i = 0U; i < 19U; ++i) {
            for (std::uint32_t j = i + 1U; j < 19U; ++j) {
                for (std::uint32_t k = j + 1U; k < 19U; ++k) {
                    add((std::uint32_t{1U} << i) | (std::uint32_t{1U} << j) | (std::uint32_t{1U} << k));
                }
            }
        }
        return values;
    }();
    return table;
}

[[nodiscard]] bool golay_decode(std::uint8_t byte0, std::uint8_t byte1, std::uint8_t byte2,
                                std::uint8_t& value) noexcept
{
    const std::uint32_t code = (static_cast<std::uint32_t>(byte0) << 11U) |
                               (static_cast<std::uint32_t>(byte1) << 3U) |
                               (static_cast<std::uint32_t>(byte2) >> 5U);
    const auto syndrome = polynomial_remainder(code, 0x0C75U, 11U);
    const int error = golay_error_table()[syndrome];
    if (error < 0) {
        return false;
    }
    const auto corrected = code ^ static_cast<std::uint32_t>(error);
    value = static_cast<std::uint8_t>(corrected >> 11U);
    return golay19_codeword(value) == corrected;
}

[[nodiscard]] std::uint16_t qr16_codeword(std::uint8_t value) noexcept
{
    constexpr std::uint32_t generator = 0x0139U;
    const auto message = static_cast<std::uint32_t>(value & 0x7FU) << 8U;
    const auto code = message | polynomial_remainder(message, generator, 8U);
    return static_cast<std::uint16_t>((code << 1U) | (std::bitset<15U>(code).count() & 1U));
}

[[nodiscard]] const std::array<int, 256U>& qr_error_table() noexcept
{
    static const auto table = [] {
        std::array<int, 256U> values{};
        values.fill(-1);
        const auto add = [&values](std::uint32_t error) {
            const auto syndrome = polynomial_remainder(error, 0x0139U, 8U);
            if (values[syndrome] == -1) {
                values[syndrome] = static_cast<int>(error);
            }
        };
        add(0U);
        for (std::uint32_t i = 0U; i < 15U; ++i) {
            add(std::uint32_t{1U} << i);
        }
        for (std::uint32_t i = 0U; i < 15U; ++i) {
            for (std::uint32_t j = i + 1U; j < 15U; ++j) {
                add((std::uint32_t{1U} << i) | (std::uint32_t{1U} << j));
            }
        }
        return values;
    }();
    return table;
}

[[nodiscard]] bool qr_decode(std::uint8_t byte0, std::uint8_t byte1, std::uint8_t& value) noexcept
{
    const std::uint32_t code = (static_cast<std::uint32_t>(byte0) << 7U) |
                               (static_cast<std::uint32_t>(byte1) >> 1U);
    const auto syndrome = polynomial_remainder(code, 0x0139U, 8U);
    const int error = qr_error_table()[syndrome];
    if (error < 0) {
        return false;
    }
    const auto corrected = code ^ static_cast<std::uint32_t>(error);
    value = static_cast<std::uint8_t>(corrected >> 8U);
    return static_cast<std::uint32_t>(qr16_codeword(value) >> 1U) == corrected;
}

[[nodiscard]] unsigned int gf_multiply(std::uint8_t left, std::uint8_t right) noexcept
{
    std::uint8_t product = 0U;
    while (right != 0U) {
        if ((right & 1U) != 0U) {
            product ^= left;
        }
        const bool high_bit = (left & 0x80U) != 0U;
        left = static_cast<std::uint8_t>(left << 1U);
        if (high_bit) {
            left ^= 0x1DU;
        }
        right = static_cast<std::uint8_t>(right >> 1U);
    }
    return product;
}

void rs129_encode(const std::uint8_t* message, std::array<std::uint8_t, 3U>& parity) noexcept
{
    constexpr std::array<std::uint8_t, 3U> polynomial{{64U, 56U, 14U}};
    parity.fill(0U);
    for (std::size_t i = 0U; i < 9U; ++i) {
        const auto dbyte = static_cast<std::uint8_t>(message[i] ^ parity[2U]);
        parity[2U] = static_cast<std::uint8_t>(parity[1U] ^ gf_multiply(polynomial[2U], dbyte));
        parity[1U] = static_cast<std::uint8_t>(parity[0U] ^ gf_multiply(polynomial[1U], dbyte));
        parity[0U] = static_cast<std::uint8_t>(gf_multiply(polynomial[0U], dbyte));
    }
}

[[nodiscard]] std::array<std::uint8_t, 9U> lc_bytes(const LinkControl& lc) noexcept
{
    return {{lc.flco, lc.feature_id, lc.options,
             static_cast<std::uint8_t>(lc.destination_id >> 16U),
             static_cast<std::uint8_t>(lc.destination_id >> 8U),
             static_cast<std::uint8_t>(lc.destination_id),
             static_cast<std::uint8_t>(lc.source_id >> 16U),
             static_cast<std::uint8_t>(lc.source_id >> 8U),
             static_cast<std::uint8_t>(lc.source_id)}};
}

[[nodiscard]] LinkControl parse_lc_bytes(const std::uint8_t* bytes) noexcept
{
    LinkControl lc{};
    lc.flco = static_cast<std::uint8_t>(bytes[0U] & 0x3FU);
    lc.feature_id = bytes[1U];
    lc.options = bytes[2U];
    lc.destination_id = (static_cast<std::uint32_t>(bytes[3U]) << 16U) |
                        (static_cast<std::uint32_t>(bytes[4U]) << 8U) |
                        static_cast<std::uint32_t>(bytes[5U]);
    lc.source_id = (static_cast<std::uint32_t>(bytes[6U]) << 16U) |
                   (static_cast<std::uint32_t>(bytes[7U]) << 8U) |
                   static_cast<std::uint32_t>(bytes[8U]);
    return lc;
}

void encode_hamming_15113_2(bool* bits) noexcept
{
    bits[11] = bits[0] ^ bits[1] ^ bits[2] ^ bits[3] ^ bits[5] ^ bits[7] ^ bits[8];
    bits[12] = bits[1] ^ bits[2] ^ bits[3] ^ bits[4] ^ bits[6] ^ bits[8] ^ bits[9];
    bits[13] = bits[2] ^ bits[3] ^ bits[4] ^ bits[5] ^ bits[7] ^ bits[9] ^ bits[10];
    bits[14] = bits[0] ^ bits[1] ^ bits[2] ^ bits[4] ^ bits[6] ^ bits[7] ^ bits[10];
}

[[nodiscard]] bool decode_hamming_15113_2(bool* bits) noexcept
{
    const bool c0 = bits[0] ^ bits[1] ^ bits[2] ^ bits[3] ^ bits[5] ^ bits[7] ^ bits[8];
    const bool c1 = bits[1] ^ bits[2] ^ bits[3] ^ bits[4] ^ bits[6] ^ bits[8] ^ bits[9];
    const bool c2 = bits[2] ^ bits[3] ^ bits[4] ^ bits[5] ^ bits[7] ^ bits[9] ^ bits[10];
    const bool c3 = bits[0] ^ bits[1] ^ bits[2] ^ bits[4] ^ bits[6] ^ bits[7] ^ bits[10];
    const auto syndrome = static_cast<std::uint8_t>((c0 != bits[11] ? 1U : 0U) |
                                                    (c1 != bits[12] ? 2U : 0U) |
                                                    (c2 != bits[13] ? 4U : 0U) |
                                                    (c3 != bits[14] ? 8U : 0U));
    switch (syndrome) {
    case 0x01U: bits[11] = !bits[11]; return true;
    case 0x02U: bits[12] = !bits[12]; return true;
    case 0x04U: bits[13] = !bits[13]; return true;
    case 0x08U: bits[14] = !bits[14]; return true;
    case 0x09U: bits[0] = !bits[0]; return true;
    case 0x0BU: bits[1] = !bits[1]; return true;
    case 0x0FU: bits[2] = !bits[2]; return true;
    case 0x07U: bits[3] = !bits[3]; return true;
    case 0x0EU: bits[4] = !bits[4]; return true;
    case 0x05U: bits[5] = !bits[5]; return true;
    case 0x0AU: bits[6] = !bits[6]; return true;
    case 0x0DU: bits[7] = !bits[7]; return true;
    case 0x03U: bits[8] = !bits[8]; return true;
    case 0x06U: bits[9] = !bits[9]; return true;
    case 0x0CU: bits[10] = !bits[10]; return true;
    default: return false;
    }
}

void encode_hamming_1393(bool* bits) noexcept
{
    bits[9] = bits[0] ^ bits[1] ^ bits[3] ^ bits[5] ^ bits[6];
    bits[10] = bits[0] ^ bits[1] ^ bits[2] ^ bits[4] ^ bits[6] ^ bits[7];
    bits[11] = bits[0] ^ bits[1] ^ bits[2] ^ bits[3] ^ bits[5] ^ bits[7] ^ bits[8];
    bits[12] = bits[0] ^ bits[2] ^ bits[4] ^ bits[5] ^ bits[8];
}

[[nodiscard]] bool decode_hamming_1393(bool* bits) noexcept
{
    const bool c0 = bits[0] ^ bits[1] ^ bits[3] ^ bits[5] ^ bits[6];
    const bool c1 = bits[0] ^ bits[1] ^ bits[2] ^ bits[4] ^ bits[6] ^ bits[7];
    const bool c2 = bits[0] ^ bits[1] ^ bits[2] ^ bits[3] ^ bits[5] ^ bits[7] ^ bits[8];
    const bool c3 = bits[0] ^ bits[2] ^ bits[4] ^ bits[5] ^ bits[8];
    const auto syndrome = static_cast<std::uint8_t>((c0 != bits[9] ? 1U : 0U) |
                                                    (c1 != bits[10] ? 2U : 0U) |
                                                    (c2 != bits[11] ? 4U : 0U) |
                                                    (c3 != bits[12] ? 8U : 0U));
    switch (syndrome) {
    case 0x01U: bits[9] = !bits[9]; return true;
    case 0x02U: bits[10] = !bits[10]; return true;
    case 0x04U: bits[11] = !bits[11]; return true;
    case 0x08U: bits[12] = !bits[12]; return true;
    case 0x0FU: bits[0] = !bits[0]; return true;
    case 0x07U: bits[1] = !bits[1]; return true;
    case 0x0EU: bits[2] = !bits[2]; return true;
    case 0x05U: bits[3] = !bits[3]; return true;
    case 0x0AU: bits[4] = !bits[4]; return true;
    case 0x0DU: bits[5] = !bits[5]; return true;
    case 0x03U: bits[6] = !bits[6]; return true;
    case 0x06U: bits[7] = !bits[7]; return true;
    case 0x0CU: bits[8] = !bits[8]; return true;
    default: return false;
    }
}

void encode_hamming_16114(bool* bits) noexcept
{
    bits[11] = bits[0] ^ bits[1] ^ bits[2] ^ bits[3] ^ bits[5] ^ bits[7] ^ bits[8];
    bits[12] = bits[1] ^ bits[2] ^ bits[3] ^ bits[4] ^ bits[6] ^ bits[8] ^ bits[9];
    bits[13] = bits[2] ^ bits[3] ^ bits[4] ^ bits[5] ^ bits[7] ^ bits[9] ^ bits[10];
    bits[14] = bits[0] ^ bits[1] ^ bits[2] ^ bits[4] ^ bits[6] ^ bits[7] ^ bits[10];
    bits[15] = bits[0] ^ bits[2] ^ bits[5] ^ bits[6] ^ bits[8] ^ bits[9] ^ bits[10];
}

[[nodiscard]] bool decode_hamming_16114(bool* bits) noexcept
{
    const bool c0 = bits[0] ^ bits[1] ^ bits[2] ^ bits[3] ^ bits[5] ^ bits[7] ^ bits[8];
    const bool c1 = bits[1] ^ bits[2] ^ bits[3] ^ bits[4] ^ bits[6] ^ bits[8] ^ bits[9];
    const bool c2 = bits[2] ^ bits[3] ^ bits[4] ^ bits[5] ^ bits[7] ^ bits[9] ^ bits[10];
    const bool c3 = bits[0] ^ bits[1] ^ bits[2] ^ bits[4] ^ bits[6] ^ bits[7] ^ bits[10];
    const bool c4 = bits[0] ^ bits[2] ^ bits[5] ^ bits[6] ^ bits[8] ^ bits[9] ^ bits[10];
    const auto syndrome = static_cast<std::uint8_t>((c0 != bits[11] ? 1U : 0U) |
                                                    (c1 != bits[12] ? 2U : 0U) |
                                                    (c2 != bits[13] ? 4U : 0U) |
                                                    (c3 != bits[14] ? 8U : 0U) |
                                                    (c4 != bits[15] ? 16U : 0U));
    switch (syndrome) {
    case 0x00U: return true;
    case 0x01U: bits[11] = !bits[11]; return true;
    case 0x02U: bits[12] = !bits[12]; return true;
    case 0x04U: bits[13] = !bits[13]; return true;
    case 0x08U: bits[14] = !bits[14]; return true;
    case 0x10U: bits[15] = !bits[15]; return true;
    case 0x19U: bits[0] = !bits[0]; return true;
    case 0x0BU: bits[1] = !bits[1]; return true;
    case 0x1FU: bits[2] = !bits[2]; return true;
    case 0x07U: bits[3] = !bits[3]; return true;
    case 0x0EU: bits[4] = !bits[4]; return true;
    case 0x15U: bits[5] = !bits[5]; return true;
    case 0x1AU: bits[6] = !bits[6]; return true;
    case 0x0DU: bits[7] = !bits[7]; return true;
    case 0x13U: bits[8] = !bits[8]; return true;
    case 0x16U: bits[9] = !bits[9]; return true;
    case 0x1CU: bits[10] = !bits[10]; return true;
    default: return false;
    }
}

[[nodiscard]] std::array<std::size_t, 96U> bptc_data_positions() noexcept
{
    std::array<std::size_t, 96U> positions{};
    std::size_t out = 0U;
    for (const std::size_t start : {4U, 16U, 31U, 46U, 61U, 76U, 91U, 106U, 121U}) {
        const auto length = start == 4U ? 8U : 11U;
        for (std::size_t i = 0U; i < length; ++i) {
            positions[out++] = start + i;
        }
    }
    return positions;
}

void bptc_encode(const std::uint8_t* input, std::array<std::uint8_t, payload_size>& payload) noexcept
{
    std::array<bool, 96U> payload_bits{};
    bytes_to_bits(input, 12U, payload_bits.data());

    std::array<bool, 196U> matrix{};
    const auto positions = bptc_data_positions();
    for (std::size_t i = 0U; i < positions.size(); ++i) {
        matrix[positions[i]] = payload_bits[i];
    }

    for (std::size_t row = 0U; row < 9U; ++row) {
        encode_hamming_15113_2(matrix.data() + row * 15U + 1U);
    }
    for (std::size_t col = 0U; col < 15U; ++col) {
        std::array<bool, 13U> column{};
        for (std::size_t row = 0U; row < 13U; ++row) {
            column[row] = matrix[col + 1U + row * 15U];
        }
        encode_hamming_1393(column.data());
        for (std::size_t row = 0U; row < 13U; ++row) {
            matrix[col + 1U + row * 15U] = column[row];
        }
    }

    std::array<bool, 196U> interleaved{};
    for (std::size_t i = 0U; i < matrix.size(); ++i) {
        interleaved[(i * 181U) % 196U] = matrix[i];
    }

    std::array<std::uint8_t, 13U> first{};
    bits_to_bytes(interleaved.data(), 12U, first.data());
    payload[0U] = first[0U];
    for (std::size_t i = 1U; i < 12U; ++i) {
        payload[i] = first[i];
    }
    std::array<bool, 8U> split{};
    for (std::size_t i = 0U; i < 8U; ++i) {
        split[i] = interleaved[96U + i];
    }
    std::uint8_t split_byte = 0U;
    bits_to_bytes(split.data(), 1U, &split_byte);
    payload[12U] = static_cast<std::uint8_t>((payload[12U] & 0x3FU) | (split_byte & 0xC0U));
    payload[20U] = static_cast<std::uint8_t>((payload[20U] & 0xFCU) | ((split_byte >> 4U) & 0x03U));

    std::array<bool, 96U> second{};
    for (std::size_t i = 0U; i < second.size(); ++i) {
        second[i] = interleaved[100U + i];
    }
    bits_to_bytes(second.data(), 12U, payload.data() + 21U);
}

void bptc_decode(const std::array<std::uint8_t, payload_size>& payload,
                 std::array<std::uint8_t, 12U>& output) noexcept
{
    std::array<bool, 196U> raw{};
    bytes_to_bits(payload.data(), 12U, raw.data());
    raw[96U] = (payload[12U] & 0x80U) != 0U;
    raw[97U] = (payload[12U] & 0x40U) != 0U;
    raw[98U] = (payload[20U] & 0x02U) != 0U;
    raw[99U] = (payload[20U] & 0x01U) != 0U;
    bytes_to_bits(payload.data() + 21U, 12U, raw.data() + 100U);

    std::array<bool, 196U> matrix{};
    for (std::size_t i = 0U; i < raw.size(); ++i) {
        matrix[i] = raw[(i * 181U) % 196U];
    }

    for (unsigned int pass = 0U; pass < 5U; ++pass) {
        bool fixed = false;
        for (std::size_t col = 0U; col < 15U; ++col) {
            std::array<bool, 13U> column{};
            for (std::size_t row = 0U; row < 13U; ++row) {
                column[row] = matrix[col + 1U + row * 15U];
            }
            if (decode_hamming_1393(column.data())) {
                fixed = true;
                for (std::size_t row = 0U; row < 13U; ++row) {
                    matrix[col + 1U + row * 15U] = column[row];
                }
            }
        }
        for (std::size_t row = 0U; row < 9U; ++row) {
            fixed = decode_hamming_15113_2(matrix.data() + row * 15U + 1U) || fixed;
        }
        if (!fixed) {
            break;
        }
    }

    const auto positions = bptc_data_positions();
    std::array<bool, 96U> data_bits{};
    for (std::size_t i = 0U; i < positions.size(); ++i) {
        data_bits[i] = matrix[positions[i]];
    }
    bits_to_bytes(data_bits.data(), 12U, output.data());
}

void encode_slot_type(std::array<std::uint8_t, payload_size>& payload,
                      std::uint8_t color_code, std::uint8_t data_type) noexcept
{
    const auto value = static_cast<std::uint8_t>(((color_code & 0x0FU) << 4U) | (data_type & 0x0FU));
    const auto code = golay19_codeword(value);
    const auto parity = code & 0x07FFU;
    const auto extended = static_cast<std::uint8_t>(std::bitset<19U>(code).count() & 1U);
    const std::uint8_t b0 = value;
    const std::uint8_t b1 = static_cast<std::uint8_t>((parity >> 3U) & 0xFFU);
    // Golay2087 的 11 个校验位按高三位在前排列，扩展奇偶位占末位。
    const std::uint8_t b2 = static_cast<std::uint8_t>((((parity & 0x07U) << 1U) | extended) << 4U);

    payload[12U] = static_cast<std::uint8_t>((payload[12U] & 0xC0U) | ((b0 >> 2U) & 0x3FU));
    payload[13U] = static_cast<std::uint8_t>((payload[13U] & 0x0FU) | ((b0 << 6U) & 0xC0U) | ((b1 >> 2U) & 0x30U));
    payload[19U] = static_cast<std::uint8_t>((payload[19U] & 0xF0U) | ((b1 >> 2U) & 0x0FU));
    payload[20U] = static_cast<std::uint8_t>((payload[20U] & 0x03U) | ((b1 << 6U) & 0xC0U) | ((b2 >> 2U) & 0x3CU));
}

[[nodiscard]] bool decode_slot_type(const std::array<std::uint8_t, payload_size>& payload,
                                    std::uint8_t& color_code, std::uint8_t& data_type) noexcept
{
    const std::uint8_t b0 = static_cast<std::uint8_t>((payload[12U] << 2U) | (payload[13U] >> 6U));
    const std::uint8_t b1 = static_cast<std::uint8_t>(((payload[13U] << 2U) & 0xC0U) |
                                                      ((payload[19U] << 2U) & 0x3CU) |
                                                      ((payload[20U] >> 6U) & 0x03U));
    const std::uint8_t b2 = static_cast<std::uint8_t>(payload[20U] << 2U);
    std::uint8_t value = 0U;
    if (!golay_decode(b0, b1, b2, value)) {
        return false;
    }
    color_code = static_cast<std::uint8_t>((value >> 4U) & 0x0FU);
    data_type = static_cast<std::uint8_t>(value & 0x0FU);
    return true;
}

void apply_sync(std::array<std::uint8_t, payload_size>& payload,
                const std::array<std::uint8_t, 7U>& sync) noexcept
{
    for (std::size_t i = 0U; i < sync.size(); ++i) {
        payload[13U + i] = static_cast<std::uint8_t>((payload[13U + i] & static_cast<std::uint8_t>(~sync_mask[i])) |
                                                     (sync[i] & sync_mask[i]));
    }
}

[[nodiscard]] bool matches_sync(const std::array<std::uint8_t, payload_size>& payload,
                                const std::array<std::uint8_t, 7U>& sync) noexcept
{
    for (std::size_t i = 0U; i < sync.size(); ++i) {
        if ((payload[13U + i] & sync_mask[i]) != (sync[i] & sync_mask[i])) {
            return false;
        }
    }
    return true;
}

void encode_qr1676(std::uint8_t value, std::array<std::uint8_t, 2U>& bytes) noexcept
{
    const auto word = qr16_codeword(static_cast<std::uint8_t>(value >> 1U));
    bytes[0U] = static_cast<std::uint8_t>(word >> 8U);
    bytes[1U] = static_cast<std::uint8_t>(word);
}

void write_embedded_signaling(std::array<std::uint8_t, payload_size>& payload,
                              std::uint8_t color_code, std::uint8_t lcss) noexcept
{
    std::array<std::uint8_t, 2U> emb{{static_cast<std::uint8_t>((color_code << 4U) | ((lcss & 0x03U) << 1U)), 0U}};
    encode_qr1676(emb[0U], emb);
    payload[13U] = static_cast<std::uint8_t>((payload[13U] & 0xF0U) | ((emb[0U] >> 4U) & 0x0FU));
    payload[14U] = static_cast<std::uint8_t>((payload[14U] & 0x0FU) | (emb[0U] << 4U));
    payload[18U] = static_cast<std::uint8_t>((payload[18U] & 0xF0U) | ((emb[1U] >> 4U) & 0x0FU));
    payload[19U] = static_cast<std::uint8_t>((payload[19U] & 0x0FU) | (emb[1U] << 4U));
}

void write_embedded_block(std::array<std::uint8_t, payload_size>& payload,
                          const std::array<bool, embedded_lc_bits>& encoded,
                          std::size_t block_index) noexcept
{
    std::array<bool, 40U> block_bits{};
    for (std::size_t i = 0U; i < 32U; ++i) {
        block_bits[i + 4U] = encoded[block_index * 32U + i];
    }
    std::array<std::uint8_t, 5U> block_bytes{};
    bits_to_bytes(block_bits.data(), block_bytes.size(), block_bytes.data());
    payload[14U] = static_cast<std::uint8_t>((payload[14U] & 0xF0U) | (block_bytes[0U] & 0x0FU));
    payload[15U] = block_bytes[1U];
    payload[16U] = block_bytes[2U];
    payload[17U] = block_bytes[3U];
    payload[18U] = static_cast<std::uint8_t>((payload[18U] & 0x0FU) | (block_bytes[4U] & 0xF0U));
}

[[nodiscard]] std::uint8_t crc5(const std::array<bool, 72U>& bits) noexcept
{
    std::array<std::uint8_t, 9U> bytes{};
    bits_to_bytes(bits.data(), bytes.size(), bytes.data());
    unsigned int total = 0U;
    for (const auto value : bytes) {
        total += value;
    }
    return static_cast<std::uint8_t>(total % 31U);
}

[[nodiscard]] bool decode_embedded_block_bits(const std::array<bool, 128U>& raw,
                                              std::array<bool, 72U>& output) noexcept
{
    std::array<bool, 128U> matrix{};
    std::size_t b = 0U;
    for (std::size_t i = 0U; i < raw.size(); ++i) {
        matrix[b] = raw[i];
        b += 16U;
        if (b > 127U) {
            b -= 127U;
        }
    }
    for (std::size_t row = 0U; row < 112U; row += 16U) {
        if (!decode_hamming_16114(matrix.data() + row)) {
            return false;
        }
    }
    for (std::size_t col = 0U; col < 16U; ++col) {
        bool parity = false;
        for (std::size_t row = 0U; row < 8U; ++row) {
            parity ^= matrix[col + row * 16U];
        }
        if (parity) {
            return false;
        }
    }

    std::size_t out = 0U;
    for (const std::size_t start : {0U, 16U, 32U, 48U, 64U, 80U, 96U}) {
        const auto count = (start == 0U || start == 16U) ? 11U : 10U;
        for (std::size_t i = 0U; i < count; ++i) {
            if (out < output.size()) {
                output[out++] = matrix[start + i];
            }
        }
    }
    if (out != output.size()) {
        return false;
    }

    std::uint8_t received_crc = 0U;
    received_crc |= matrix[42U] ? 0x10U : 0U;
    received_crc |= matrix[58U] ? 0x08U : 0U;
    received_crc |= matrix[74U] ? 0x04U : 0U;
    received_crc |= matrix[90U] ? 0x02U : 0U;
    received_crc |= matrix[106U] ? 0x01U : 0U;
    return crc5(output) == received_crc;
}

void lc_data_to_bits(const LinkControl& lc, std::array<bool, 72U>& bits) noexcept
{
    const auto bytes = lc_bytes(lc);
    bytes_to_bits(bytes.data(), bytes.size(), bits.data());
}

void put_slot_sync(std::array<std::uint8_t, payload_size>& payload, bool audio) noexcept
{
    if (audio) {
        apply_sync(payload, ms_audio_sync);
    } else {
        apply_sync(payload, ms_data_sync);
    }
}

} // namespace

std::array<std::uint8_t, payload_size> encode_full_lc(
    const LinkControl& lc, FullLcType type, std::uint8_t color_code) noexcept
{
    std::array<std::uint8_t, payload_size> payload{};
    put_slot_sync(payload, false);
    const auto data_type = static_cast<std::uint8_t>(type);
    encode_slot_type(payload, color_code, data_type);

    const auto bytes = lc_bytes(lc);
    std::array<std::uint8_t, 3U> parity{};
    rs129_encode(bytes.data(), parity);
    std::array<std::uint8_t, full_lc_size> full_lc{};
    std::copy(bytes.begin(), bytes.end(), full_lc.begin());
    const auto& mask = type == FullLcType::voice_header ? voice_lc_header_mask : terminator_lc_mask;
    full_lc[9U] = static_cast<std::uint8_t>(parity[2U] ^ mask[0U]);
    full_lc[10U] = static_cast<std::uint8_t>(parity[1U] ^ mask[1U]);
    full_lc[11U] = static_cast<std::uint8_t>(parity[0U] ^ mask[2U]);
    bptc_encode(full_lc.data(), payload);
    return payload;
}

DecodedFullLc decode_full_lc(
    const std::array<std::uint8_t, payload_size>& payload, FullLcType type) noexcept
{
    DecodedFullLc result{};
    std::uint8_t color_code = 0U;
    std::uint8_t data_type = 0U;
    if (!matches_sync(payload, bs_data_sync) && !matches_sync(payload, ms_data_sync)) {
        return result;
    }
    if (!decode_slot_type(payload, color_code, data_type) || data_type != static_cast<std::uint8_t>(type)) {
        return result;
    }

    std::array<std::uint8_t, full_lc_size> full_lc{};
    bptc_decode(payload, full_lc);
    const auto& mask = type == FullLcType::voice_header ? voice_lc_header_mask : terminator_lc_mask;
    full_lc[9U] ^= mask[0U];
    full_lc[10U] ^= mask[1U];
    full_lc[11U] ^= mask[2U];
    std::array<std::uint8_t, 3U> parity{};
    rs129_encode(full_lc.data(), parity);
    if (full_lc[9U] != parity[2U] || full_lc[10U] != parity[1U] || full_lc[11U] != parity[0U]) {
        return result;
    }

    result.link_control = parse_lc_bytes(full_lc.data());
    if ((result.link_control.flco != 0x00U && result.link_control.flco != 0x03U) ||
        result.link_control.source_id == 0U || result.link_control.destination_id == 0U) {
        result.link_control = {};
        return result;
    }
    result.valid = true;
    result.color_code = color_code;
    return result;
}

std::array<bool, embedded_lc_bits> encode_embedded_lc(const LinkControl& lc) noexcept
{
    std::array<bool, 72U> lc_bits{};
    lc_data_to_bits(lc, lc_bits);
    const auto crc = crc5(lc_bits);

    std::array<bool, 128U> matrix{};
    matrix[106U] = (crc & 0x01U) != 0U;
    matrix[90U] = (crc & 0x02U) != 0U;
    matrix[74U] = (crc & 0x04U) != 0U;
    matrix[58U] = (crc & 0x08U) != 0U;
    matrix[42U] = (crc & 0x10U) != 0U;

    std::size_t source = 0U;
    for (const std::size_t start : {0U, 16U, 32U, 48U, 64U, 80U, 96U}) {
        const auto count = (start == 0U || start == 16U) ? 11U : 10U;
        for (std::size_t i = 0U; i < count; ++i) {
            matrix[start + i] = lc_bits[source++];
        }
    }
    for (std::size_t row = 0U; row < 112U; row += 16U) {
        encode_hamming_16114(matrix.data() + row);
    }
    for (std::size_t col = 0U; col < 16U; ++col) {
        matrix[112U + col] = matrix[col] ^ matrix[16U + col] ^ matrix[32U + col] ^ matrix[48U + col] ^
                             matrix[64U + col] ^ matrix[80U + col] ^ matrix[96U + col];
    }

    std::array<bool, 128U> encoded{};
    std::size_t position = 0U;
    for (std::size_t i = 0U; i < encoded.size(); ++i) {
        encoded[i] = matrix[position];
        position += 16U;
        if (position > 127U) {
            position -= 127U;
        }
    }
    return encoded;
}

bool decode_embedded_lc(const std::array<bool, embedded_lc_bits>& bits, LinkControl& lc) noexcept
{
    std::array<bool, 72U> lc_bits{};
    if (!decode_embedded_block_bits(bits, lc_bits)) {
        return false;
    }
    std::array<std::uint8_t, 9U> bytes{};
    bits_to_bytes(lc_bits.data(), bytes.size(), bytes.data());
    lc = parse_lc_bytes(bytes.data());
    return (lc.flco == 0x00U || lc.flco == 0x03U) &&
           lc.source_id != 0U && lc.destination_id != 0U;
}

std::array<std::uint8_t, payload_size> encode_voice_burst(
    const std::array<std::uint8_t, ambe_size>& ambe,
    const LinkControl& lc,
    std::uint8_t color_code,
    std::uint8_t burst_index) noexcept
{
    std::array<std::uint8_t, payload_size> payload{};
    for (std::size_t source = 0U; source < ambe_size * 8U; ++source) {
        const std::size_t target = source < 108U ? source : source + 48U;
        set_bit(payload.data(), target, get_bit(ambe.data(), source));
    }

    if (burst_index == 0U) {
        put_slot_sync(payload, true);
        return payload;
    }

    std::uint8_t lcss = 0U;
    if (burst_index >= 1U && burst_index <= 4U) {
        constexpr std::array<std::uint8_t, 4U> lcss_values{{1U, 3U, 3U, 2U}};
        const auto embedded = encode_embedded_lc(lc);
        write_embedded_block(payload, embedded, static_cast<std::size_t>(burst_index - 1U));
        lcss = lcss_values[burst_index - 1U];
    } else {
        payload[14U] &= 0xF0U;
        payload[15U] = 0U;
        payload[16U] = 0U;
        payload[17U] = 0U;
        payload[18U] &= 0x0FU;
    }
    write_embedded_signaling(payload, color_code, lcss);
    return payload;
}

std::array<std::uint8_t, ambe_size> decode_voice_burst(
    const std::array<std::uint8_t, payload_size>& payload) noexcept
{
    std::array<std::uint8_t, ambe_size> ambe{};
    for (std::size_t source = 0U; source < ambe_size * 8U; ++source) {
        const std::size_t target = source < 108U ? source : source + 48U;
        set_bit(ambe.data(), source, get_bit(payload.data(), target));
    }
    return ambe;
}

bool has_audio_sync(const std::array<std::uint8_t, payload_size>& payload) noexcept
{
    return matches_sync(payload, bs_audio_sync) || matches_sync(payload, ms_audio_sync);
}

EmbeddedSignaling decode_embedded_signaling(
    const std::array<std::uint8_t, payload_size>& payload) noexcept
{
    EmbeddedSignaling result{};
    const std::uint8_t byte0 = static_cast<std::uint8_t>(((payload[13U] << 4U) & 0xF0U) | ((payload[14U] >> 4U) & 0x0FU));
    const std::uint8_t byte1 = static_cast<std::uint8_t>(((payload[18U] << 4U) & 0xF0U) | ((payload[19U] >> 4U) & 0x0FU));
    std::uint8_t decoded = 0U;
    if (!qr_decode(byte0, byte1, decoded)) {
        return result;
    }
    result.valid = true;
    // QR 解码返回 EMB 首字节右移一位后的 7 位字段。
    result.color_code = static_cast<std::uint8_t>((decoded >> 3U) & 0x0FU);
    result.lcss = static_cast<std::uint8_t>(decoded & 0x03U);
    return result;
}

bool decode_embedded_lc_block(const std::array<std::uint8_t, payload_size>& payload,
                              std::array<bool, 32U>& data_bits) noexcept
{
    std::array<std::uint8_t, 5U> bytes{{payload[14U], payload[15U], payload[16U], payload[17U], payload[18U]}};
    std::array<bool, 40U> bits{};
    bytes_to_bits(bytes.data(), bytes.size(), bits.data());
    std::copy(bits.begin() + 4, bits.begin() + 36, data_bits.begin());
    return true;
}

} // namespace wirex::dmr_signal
