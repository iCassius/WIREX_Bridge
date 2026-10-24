/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 本文件对应的实现参考：
 * - MMDVM_CM USRP2DMR 的 BPTC19696、DMRFullLC、DMRSlotType、Golay2087、
 *   DMREMB、DMREmbeddedData、QR1676、RS129、Hamming 和 DMRDefines。
 *   固定提交 7328c9e9532d29cf4d9d7d24541d57f825207be4，GPL-2.0-or-later。
 * - DroidStar 的 dmr.cpp，固定提交 becf1dede57c4a70a865e9cb4cac9247e505599a，
 *   GPL-3.0-or-later。
 *
 * 本接口为上述许可兼容的信令算法移植，不包含 AMBE 声码器。
 */
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::dmr_signal {

inline constexpr std::size_t payload_size = 33U;
inline constexpr std::size_t ambe_size = 27U;
inline constexpr std::size_t full_lc_size = 12U;
inline constexpr std::size_t embedded_lc_bits = 128U;

enum class FullLcType : std::uint8_t {
    voice_header = 0x01U,
    terminator = 0x02U,
};

struct LinkControl {
    std::uint8_t flco{};
    std::uint8_t feature_id{};
    std::uint8_t options{};
    std::uint32_t destination_id{};
    std::uint32_t source_id{};
};

struct DecodedFullLc {
    bool valid{};
    LinkControl link_control{};
    std::uint8_t color_code{};
};

struct EmbeddedSignaling {
    bool valid{};
    std::uint8_t color_code{};
    std::uint8_t lcss{};
};

[[nodiscard]] std::array<std::uint8_t, payload_size> encode_full_lc(
    const LinkControl& lc, FullLcType type, std::uint8_t color_code) noexcept;

[[nodiscard]] DecodedFullLc decode_full_lc(
    const std::array<std::uint8_t, payload_size>& payload, FullLcType type) noexcept;

[[nodiscard]] std::array<bool, embedded_lc_bits> encode_embedded_lc(
    const LinkControl& lc) noexcept;

[[nodiscard]] bool decode_embedded_lc(
    const std::array<bool, embedded_lc_bits>& bits, LinkControl& lc) noexcept;

[[nodiscard]] std::array<std::uint8_t, payload_size> encode_voice_burst(
    const std::array<std::uint8_t, ambe_size>& ambe,
    const LinkControl& lc,
    std::uint8_t color_code,
    std::uint8_t burst_index) noexcept;

[[nodiscard]] std::array<std::uint8_t, ambe_size> decode_voice_burst(
    const std::array<std::uint8_t, payload_size>& payload) noexcept;

[[nodiscard]] bool has_audio_sync(
    const std::array<std::uint8_t, payload_size>& payload) noexcept;

[[nodiscard]] EmbeddedSignaling decode_embedded_signaling(
    const std::array<std::uint8_t, payload_size>& payload) noexcept;

[[nodiscard]] bool decode_embedded_lc_block(
    const std::array<std::uint8_t, payload_size>& payload,
    std::array<bool, 32U>& data_bits) noexcept;

} // namespace wirex::dmr_signal
