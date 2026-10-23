#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::hri_t_payload {

inline constexpr std::size_t candidate_body_size = 90;
using CandidateBody = std::array<std::uint8_t, candidate_body_size>;

/// 按 R63 静态映射组装空 header、空 AMBE 的 90 字节 T 候选正文。
/// 返回固定长度 ASCII 字节，不含 NUL；这不代表正文已发送、播放或产生射频效果。
[[nodiscard]] CandidateBody build_empty_header_empty_ambe_candidate_body(
    std::int32_t ptt_sw,
    std::int32_t field50,
    std::uint8_t flags248c) noexcept;

} // namespace wirex::hri_t_payload
