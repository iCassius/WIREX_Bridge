#pragma once

#include "wirex/hri_t_payload.hpp"

#include <array>
#include <cstdint>
#include <string_view>

namespace wirex::hri_lcd_identity_candidate {

enum class CallsignField {
    destination,
    source,
    local,
};

enum class Error {
    none,
    invalid_base_body,
    invalid_field,
    invalid_callsign,
    invalid_source_id,
};

struct Result {
    Error error{Error::none};
    hri_t_payload::CandidateBody body{};

    [[nodiscard]] explicit operator bool() const noexcept { return error == Error::none; }
};

using SourceIdTestLabel = std::array<char, 10U>;

struct SourceIdResult {
    Error error{Error::none};
    hri_t_payload::CandidateBody body{};
    SourceIdTestLabel label{};

    [[nodiscard]] explicit operator bool() const noexcept { return error == Error::none; }
};

/// 将字段名转换为可写入报告的稳定标识。
[[nodiscard]] std::string_view field_name(CallsignField field) noexcept;

/// 只接受 1..8 个可见 ASCII 字符（`!`..`~`），至少含一个英文字母。
[[nodiscard]] bool is_valid_callsign_input(std::string_view callsign) noexcept;

/// 仅把一个已定位呼号字段写入官方空头 mode4 起始正文副本。
/// 输入呼号不得含空格；输出字段右侧补空格到 10 字节。
/// 该实验变换不属于官方非空 T 头构造路径，也不证明电台会显示字段。
[[nodiscard]] Result overlay_single_callsign(
    const hri_t_payload::CandidateBody& start_body,
    CallsignField field,
    std::string_view callsign) noexcept;

/// 为 BM DMR source ID 构造单次 T90 测试标签 `ID`+十进制数字+空格。
/// 该标签占用 HRI source 10 字节字段，不是呼号，也不改变原始呼号校验；函数不判断电台是否显示它。
[[nodiscard]] SourceIdResult overlay_source_id_test_label(
    const hri_t_payload::CandidateBody& start_body,
    std::uint32_t source_id) noexcept;

} // namespace wirex::hri_lcd_identity_candidate
