#pragma once

#include "wirex/direct_frame.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace wirex::hri_p_status {

enum class StateClass : std::uint8_t {
    transceiver,
    repeater,
};

enum class AnalysisStatus : std::uint8_t {
    analyzed,
    reset_sentinel,
    wrong_record_type,
    unsupported_payload_length,
    invalid_state_class,
};

enum class ContextDisposition : std::uint8_t {
    unknown,
    eligible,
    rejected,
    sentinel,
};

// 当前 HRI 会话中的比较值。数组按内存顺序保存 HRI+0x2c8 的四个原始字节；不作文本或十六进制解释。
struct FilterContext {
    std::optional<std::uint8_t> short_state_gate_raw;
    std::optional<std::array<std::uint8_t, 4>> compare_dword_raw;
    std::optional<std::uint8_t> compare_byte_raw;
};

struct Analysis {
    AnalysisStatus status{AnalysisStatus::wrong_record_type};
    ContextDisposition context{ContextDisposition::unknown};

    // 保留调用方提供的完整 payload，包括含义尚未恢复的字段。
    std::vector<std::uint8_t> raw_payload;

    // 会话过滤通过后，传给 HRI 对象虚方法 +0x28 的四个原始状态字节。
    std::optional<std::array<std::uint8_t, 4>> vtable28_input;

    // 所选 +0x18 虚方法检查的原始字节及其 P payload 偏移。结果仅表示 HRI 内部数字状态谓词，不是射频发射状态。
    std::optional<std::uint8_t> predicate_raw;
    std::optional<std::size_t> predicate_payload_offset;
    std::optional<bool> internal_digital_ptt_predicate;
};

// 分析已由 direct_frame 校验的记录。HRI 过滤值必须来自与该记录相同的实时 HRI 会话。
[[nodiscard]] Analysis analyze(const direct_frame::Record& record,
                               StateClass state_class,
                               const FilterContext& context);

} // namespace wirex::hri_p_status
