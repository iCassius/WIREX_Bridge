#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace wirex::hri_call_header {

inline constexpr std::size_t header_size = 68;
inline constexpr std::size_t destination_callsign_offset = 8;
inline constexpr std::size_t source_callsign_offset = 0x12;
inline constexpr std::size_t local_callsign_offset = 0x1c;
inline constexpr std::size_t callsign_size = 10;
inline constexpr std::size_t header_mode_offset = 4;
inline constexpr std::size_t t_body_header_offset = 7;
inline constexpr std::size_t t_body_mode_offset = 0x0b;

static_assert(t_body_header_offset + header_mode_offset == t_body_mode_offset,
              "HRI T mode byte is body offset 0x0b and header offset 4");

using Header = std::array<char, header_size>;

/// 解析恰好 68 个非 NUL ASCII 字节；不解释未知字段。
[[nodiscard]] std::optional<Header> parse_header(std::string_view input) noexcept;

/// 读取或修改字段前，先验证定长头部。
[[nodiscard]] bool is_valid_header(const Header& header) noexcept;

/// 存储字节有效时，返回定宽可打印 ASCII 字段。
[[nodiscard]] std::optional<std::string_view> destination_callsign(
    const Header& header) noexcept;
[[nodiscard]] std::optional<std::string_view> source_callsign(const Header& header) noexcept;
/// 从 DGRP_COMMON 配置复制到头部 +0x1c 的 HRI 本机呼号。
[[nodiscard]] std::optional<std::string_view> local_callsign(const Header& header) noexcept;

/// 仅在输入恰好为 10 个可打印 ASCII 字节时替换定宽字段。
[[nodiscard]] bool set_destination_callsign(Header& header, std::string_view callsign) noexcept;
[[nodiscard]] bool set_source_callsign(Header& header, std::string_view callsign) noexcept;
[[nodiscard]] bool set_local_callsign(Header& header, std::string_view callsign) noexcept;

/// 按 FUN_10014b50 的非空头部逻辑转换头部相对偏移 4 的字节。
[[nodiscard]] std::optional<char> nonempty_t_body_mode_character(
    const Header& header) noexcept;

} // namespace wirex::hri_call_header
