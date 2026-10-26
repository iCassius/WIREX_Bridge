#include "wirex/hri_p_status.hpp"

namespace wirex::hri_p_status {
namespace {

bool is_valid_state_class(StateClass state_class) noexcept
{
    return state_class == StateClass::transceiver || state_class == StateClass::repeater;
}

bool short_gate_allows(std::uint8_t raw) noexcept
{
    // 原始 x86 代码用有符号 JLE 将 BYTE 与 0x20 比较。
    // 直接写出该有符号字节范围，避免依赖 unsigned 到 signed 转换的实现定义行为。
    return raw <= 0x20U || raw >= 0x80U;
}

bool repeater_predicate(std::uint8_t raw) noexcept
{
    return raw == static_cast<std::uint8_t>('4') ||
           raw == static_cast<std::uint8_t>('8') ||
           raw == static_cast<std::uint8_t>('A') ||
           raw == static_cast<std::uint8_t>('C');
}

} // namespace

Analysis analyze(const direct_frame::Record& record,
                 StateClass state_class,
                 const FilterContext& context)
{
    Analysis result;
    result.raw_payload = record.payload;

    if (record.type != static_cast<std::uint8_t>('P')) {
        result.status = AnalysisStatus::wrong_record_type;
        return result;
    }

    if (record.payload.size() != 4U && record.payload.size() != 11U) {
        result.status = AnalysisStatus::unsupported_payload_length;
        return result;
    }

    if (!is_valid_state_class(state_class)) {
        result.status = AnalysisStatus::invalid_state_class;
        return result;
    }

    const bool short_record = record.payload.size() == 4U;
    if (!short_record && record.payload[3] == static_cast<std::uint8_t>('D')) {
        result.status = AnalysisStatus::reset_sentinel;
        result.context = ContextDisposition::sentinel;
        return result;
    }

    if (short_record) {
        if (!context.short_state_gate_raw.has_value()) {
            result.status = AnalysisStatus::analyzed;
            result.context = ContextDisposition::unknown;
            return result;
        }
        if (!short_gate_allows(*context.short_state_gate_raw)) {
            result.status = AnalysisStatus::analyzed;
            result.context = ContextDisposition::rejected;
            return result;
        }
    } else {
        if (!context.compare_dword_raw.has_value() || !context.compare_byte_raw.has_value()) {
            result.status = AnalysisStatus::analyzed;
            result.context = ContextDisposition::unknown;
            return result;
        }

        const auto payload_word = std::array<std::uint8_t, 4>{{
            record.payload[5], record.payload[6], record.payload[7], record.payload[8],
        }};
        if (payload_word != *context.compare_dword_raw ||
            record.payload[9] != *context.compare_byte_raw) {
            result.status = AnalysisStatus::analyzed;
            result.context = ContextDisposition::rejected;
            return result;
        }
    }

    result.status = AnalysisStatus::analyzed;
    result.context = ContextDisposition::eligible;

    const std::size_t state_offset = short_record ? 0U : 1U;
    result.vtable28_input = std::array<std::uint8_t, 4>{{
        record.payload[state_offset],
        record.payload[state_offset + 1U],
        record.payload[state_offset + 2U],
        record.payload[state_offset + 3U],
    }};

    const std::size_t predicate_offset =
        state_class == StateClass::transceiver
            ? (short_record ? 2U : 3U)
            : (short_record ? 3U : 4U);
    const std::uint8_t predicate_raw = record.payload[predicate_offset];
    result.predicate_raw = predicate_raw;
    result.predicate_payload_offset = predicate_offset;
    result.internal_digital_ptt_predicate =
        state_class == StateClass::transceiver
            ? predicate_raw == static_cast<std::uint8_t>('4')
            : repeater_predicate(predicate_raw);

    return result;
}

} // namespace wirex::hri_p_status
