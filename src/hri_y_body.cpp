#include "wirex/hri_y_body.hpp"

#include <cstddef>
#include <cstdint>

namespace wirex::hri_y {
namespace {

bool is_whitelisted(std::size_t offset) noexcept
{
    return offset == mode_offset || offset == ptt_mirror_offset ||
        (offset >= tx_power_offset && offset < tx_power_offset + tx_power_length);
}

bool valid_mode(std::uint8_t mode, bool ap_mode) noexcept
{
    return mode == static_cast<std::uint8_t>('2') ||
        (ap_mode && mode == static_cast<std::uint8_t>('1'));
}

bool parse_power(const std::uint8_t* bytes, std::uint16_t& value) noexcept
{
    if (bytes == nullptr) return false;
    unsigned parsed = 0U;
    for (std::size_t index = 0U; index < tx_power_length; ++index) {
        const auto byte = bytes[index];
        if (byte < static_cast<std::uint8_t>('0') || byte > static_cast<std::uint8_t>('9')) return false;
        parsed = parsed * 10U + static_cast<unsigned>(byte - static_cast<std::uint8_t>('0'));
    }
    value = static_cast<std::uint16_t>(parsed);
    return true;
}

} // namespace

bool valid_tx_power_deciwatts(std::uint16_t deciwatts) noexcept
{
    return deciwatts >= min_tx_power_deciwatts && deciwatts <= max_tx_power_deciwatts &&
        deciwatts % 10U == 0U;
}

BuildResult build(const std::array<std::uint8_t, body_size>& approved_template,
                  const DynamicFields& fields, bool ap_mode)
{
    BuildResult result{};
    if (!valid_tx_power_deciwatts(fields.lch_tx_power_deciwatts)) {
        result.error = "invalid_hri_y_tx_power";
        return result;
    }

    result.body = approved_template;
    result.body[mode_offset] = static_cast<std::uint8_t>(ap_mode ? '1' : '2');
    const auto power = fields.lch_tx_power_deciwatts;
    result.body[tx_power_offset] = static_cast<std::uint8_t>('0' + (power / 1000U) % 10U);
    result.body[tx_power_offset + 1U] = static_cast<std::uint8_t>('0' + (power / 100U) % 10U);
    result.body[tx_power_offset + 2U] = static_cast<std::uint8_t>('0' + (power / 10U) % 10U);
    result.body[tx_power_offset + 3U] = static_cast<std::uint8_t>('0' + power % 10U);
    result.ok = validate(approved_template, result.body.data(), result.body.size(), ap_mode);
    if (!result.ok) {
        result.body = {};
        result.error = "generated_hri_y_body_invalid";
    }
    return result;
}

bool validate(const std::array<std::uint8_t, body_size>& approved_template,
              const std::uint8_t* body, std::size_t size, bool ap_mode) noexcept
{
    if (body == nullptr || size != body_size || !valid_mode(body[mode_offset], ap_mode)) return false;
    // The non-import X branch mirrors this byte verbatim, including unknown PTT values.
    std::uint16_t power = 0U;
    if (!parse_power(body + tx_power_offset, power) || !valid_tx_power_deciwatts(power)) return false;

    for (std::size_t index = 0U; index < body_size; ++index) {
        if (!is_whitelisted(index) && body[index] != approved_template[index]) return false;
    }
    return true;
}

} // namespace wirex::hri_y
