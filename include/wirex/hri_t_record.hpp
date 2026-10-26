#pragma once

#include "wirex/hri_call_header.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace wirex::hri_t_record {

inline constexpr std::size_t body_prefix_size = 7;
inline constexpr std::size_t voice_separator_size = 5;

struct BodyPrefixFields {
    // HRI 的 7 个前缀字符由状态与全局字段提供；未知字段由调用方原样传递。
    std::array<char, body_prefix_size> bytes{};
};

enum class BuildError {
    none,
    invalid_prefix,
    invalid_header,
    unsupported_header_mode,
    invalid_count_token,
    payload_count_mismatch,
    invalid_payload_hex,
};

struct BuildResult {
    BuildError error{BuildError::none};
    std::string body;

    [[nodiscard]] explicit operator bool() const noexcept { return error == BuildError::none; }
};

/// 按 FUN_100139f0 将原始尾块编码为 HEX、ASCII "03" 和 sum8 校验文本。
[[nodiscard]] std::string encode_tail_with_03_checksum(std::string_view raw_bytes);

/// 构造 FUN_10014b50 的非空头部 T 文本正文。
/// count_token_hex 是输入计数字段的 4 个 HEX 字符，值等于 payload_hex 长度加 1。
/// trailer_raw 会先按 FUN_100139f0 编码，再放到五个星号之后。
/// 本函数不生成 COM/USB 外层帧，也不表示正文已交给设备。
[[nodiscard]] BuildResult build_nonempty_t_text_body(
    const BodyPrefixFields& prefix,
    const hri_call_header::Header& header,
    std::string_view count_token_hex,
    std::string_view payload_hex,
    std::string_view trailer_raw);

} // namespace wirex::hri_t_record
