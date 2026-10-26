/*
 * Copyright (C) 2010, 2014, 2016 and 2018 by Jonathan Naylor G4KLX
 * Copyright (C) 2016 Mathias Weyland, HB9FRV
 * Copyright (C) 2018 by Andy Uribe CA6JAU
 *
 * This file derives its YSF V/D Mode 2 VCH mapping from
 * MMDVM_CM YSF2DMR/ModeConv.cpp, pinned at commit
 * 7328c9e9532d29cf4d9d7d24541d57f825207be4
 * (SHA-256 b2f7a4a82ec64f169e5d98fcb34e17994611d7ebcc94d1774bcb35dfe5ce8844).
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */
#include "wirex/ysf_vd2_vch.hpp"

#include <cstddef>

namespace {

constexpr std::array<std::uint8_t, 13> whitening_data{{
    0x93U, 0xD7U, 0x51U, 0x21U, 0x9CU, 0x2FU, 0x6CU,
    0xD0U, 0xEFU, 0x0FU, 0xF8U, 0x3DU, 0xF1U,
}};

constexpr std::size_t interleaved_position(std::size_t bit) noexcept
{
    // 与上游 INTERLEAVE_TABLE_26_4 的 4 列、26 行排列一致。
    return ((bit % 26U) * 4U) + (bit / 26U);
}

bool read_bit(const wirex::ysf_vd2_vch::Vch& bytes, std::size_t bit) noexcept
{
    const auto mask = static_cast<std::uint8_t>(0x80U >> (bit % 8U));
    return (bytes[bit / 8U] & mask) != 0U;
}

void write_bit(wirex::ysf_vd2_vch::Vch& bytes, std::size_t bit, bool value) noexcept
{
    const auto mask = static_cast<std::uint8_t>(0x80U >> (bit % 8U));
    auto& byte = bytes[bit / 8U];
    if (value) {
        byte = static_cast<std::uint8_t>(byte | mask);
    } else {
        byte = static_cast<std::uint8_t>(byte & static_cast<std::uint8_t>(~mask));
    }
}

void write_field_bit(
    wirex::ysf_vd2_vch::Vch& bits,
    std::size_t bit,
    std::uint32_t value,
    std::size_t value_bit) noexcept
{
    const bool set = ((value >> value_bit) & 1U) != 0U;
    write_bit(bits, bit, set);
}

void write_triplicated_field(
    wirex::ysf_vd2_vch::Vch& bits,
    std::size_t first_bit,
    std::uint32_t value,
    std::size_t width) noexcept
{
    for (std::size_t i = 0; i < width; ++i) {
        const bool set = ((value >> (width - 1U - i)) & 1U) != 0U;
        const auto position = first_bit + 3U * i;
        write_bit(bits, position, set);
        write_bit(bits, position + 1U, set);
        write_bit(bits, position + 2U, set);
    }
}

void whiten(wirex::ysf_vd2_vch::Vch& bits) noexcept
{
    for (std::size_t i = 0; i < whitening_data.size(); ++i) {
        bits[i] = static_cast<std::uint8_t>(bits[i] ^ whitening_data[i]);
    }
}

} // namespace

namespace wirex::ysf_vd2_vch {

wirex::ambe2450::Parameters decode_vch(const Vch& vch) noexcept
{
    Vch deinterleaved{};
    for (std::size_t bit = 0; bit < 104U; ++bit) {
        write_bit(deinterleaved, bit, read_bit(vch, interleaved_position(bit)));
    }
    whiten(deinterleaved);

    wirex::ambe2450::Parameters parameters{};
    for (std::size_t i = 0; i < 12U; ++i) {
        parameters.a = static_cast<std::uint16_t>(
            (parameters.a << 1U) | (read_bit(deinterleaved, 3U * i + 1U) ? 1U : 0U));
        parameters.b = static_cast<std::uint16_t>(
            (parameters.b << 1U) | (read_bit(deinterleaved, 3U * (i + 12U) + 1U) ? 1U : 0U));
    }

    for (std::size_t i = 0; i < 3U; ++i) {
        parameters.c = static_cast<std::uint32_t>(
            (parameters.c << 1U) | (read_bit(deinterleaved, 3U * (i + 24U) + 1U) ? 1U : 0U));
    }
    for (std::size_t i = 0; i < 22U; ++i) {
        parameters.c = static_cast<std::uint32_t>(
            (parameters.c << 1U) | (read_bit(deinterleaved, 81U + i) ? 1U : 0U));
    }

    return parameters;
}

bool encode_vch(const wirex::ambe2450::Parameters& parameters, Vch& vch) noexcept
{
    if (!wirex::ambe2450::is_valid(parameters)) {
        return false;
    }

    Vch deinterleaved{};
    write_triplicated_field(deinterleaved, 0U, parameters.a, 12U);
    write_triplicated_field(deinterleaved, 36U, parameters.b, 12U);
    write_triplicated_field(deinterleaved, 72U, parameters.c >> 22U, 3U);
    for (std::size_t i = 0; i < 22U; ++i) {
        write_field_bit(deinterleaved, 81U + i, parameters.c, 21U - i);
    }
    // bit 103 是上游固定写零的填充位；数组初始化已保持该值。

    whiten(deinterleaved);

    Vch encoded{};
    for (std::size_t bit = 0; bit < 104U; ++bit) {
        write_bit(encoded, interleaved_position(bit), read_bit(deinterleaved, bit));
    }
    vch = encoded;
    return true;
}

} // namespace wirex::ysf_vd2_vch
