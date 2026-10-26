/*
 * Copyright (C) 2010, 2014, 2016 and 2018 by Jonathan Naylor G4KLX
 * Copyright (C) 2016 Mathias Weyland, HB9FRV
 * Copyright (C) 2018 by Andy Uribe CA6JAU
 *
 * This file derives its YSF V/D Mode 2 VCH mapping from
 * MMDVM_CM YSF2DMR/ModeConv.cpp, pinned at commit
 * 7328c9e9532d29cf4d9d7d24541d57f825207be4.
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
#pragma once

#include "wirex/ambe2450_parameters.hpp"

#include <array>
#include <cstdint>

namespace wirex::ysf_vd2_vch {

using Vch = std::array<std::uint8_t, 13>;

// 从固定长度 VCH 中去白化、逆交织并按 MSB 顺序提取 12+12+25 位。
// 输入的任意 13 字节都能映射成参数；这里不执行 CRC 或纠错。
[[nodiscard]] wirex::ambe2450::Parameters decode_vch(const Vch& vch) noexcept;

// 把参数按上游重复编码、白化和交织规则写成 13 字节 VCH。
// 参数超出字段宽度时返回 false，且不修改 vch。
[[nodiscard]] bool encode_vch(
    const wirex::ambe2450::Parameters& parameters,
    Vch& vch) noexcept;

} // namespace wirex::ysf_vd2_vch
