#include "wirex/hri_lcd_identity_candidate.hpp"

#include "wirex/hri_call_header.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace wirex::hri_lcd_identity_candidate {

namespace {

std::size_t field_offset(CallsignField field) noexcept
{
    switch (field) {
    case CallsignField::destination:
        return hri_call_header::destination_callsign_offset;
    case CallsignField::source:
        return hri_call_header::source_callsign_offset;
    case CallsignField::local:
        return hri_call_header::local_callsign_offset;
    }
    return hri_call_header::header_size;
}

bool valid_callsign_input(std::string_view callsign) noexcept
{
    if (callsign.empty() || callsign.size() > 8U) {
        return false;
    }
    bool contains_letter = false;
    for (const char value : callsign) {
        const auto byte = static_cast<unsigned char>(value);
        if (byte < 0x21U || byte > 0x7eU) {
            return false;
        }
        if ((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z')) {
            contains_letter = true;
        }
    }
    return contains_letter;
}

} // namespace

std::string_view field_name(CallsignField field) noexcept
{
    switch (field) {
    case CallsignField::destination: return "destination";
    case CallsignField::source: return "source";
    case CallsignField::local: return "local";
    }
    return "invalid";
}

bool is_valid_callsign_input(std::string_view callsign) noexcept
{
    return valid_callsign_input(callsign);
}

Result overlay_single_callsign(
    const hri_t_payload::CandidateBody& start_body,
    CallsignField field,
    std::string_view callsign) noexcept
{
    const auto field_byte_offset = field_offset(field);
    if (field_byte_offset == hri_call_header::header_size) {
        return {Error::invalid_field, {}};
    }
    if (!is_valid_callsign_input(callsign)) {
        return {Error::invalid_callsign, {}};
    }

    const auto expected_start = hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    if (start_body != expected_start) {
        return {Error::invalid_base_body, {}};
    }

    Result result{};
    result.body = start_body;
    std::array<char, hri_call_header::callsign_size> padded{};
    padded.fill(' ');
    for (std::size_t index = 0; index < callsign.size(); ++index) {
        padded[index] = callsign[index];
    }

    const auto body_field_offset = hri_call_header::t_body_header_offset + field_byte_offset;
    for (std::size_t index = 0; index < padded.size(); ++index) {
        result.body[body_field_offset + index] = static_cast<std::uint8_t>(padded[index]);
    }
    return result;
}

} // namespace wirex::hri_lcd_identity_candidate
