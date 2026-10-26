#include "wirex/hri_lcd_identity_candidate.hpp"

#include "wirex/hri_call_header.hpp"

#include <array>
#include <charconv>
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

SourceIdResult overlay_source_id_test_label(
    const hri_t_payload::CandidateBody& start_body,
    std::uint32_t source_id) noexcept
{
    constexpr std::uint32_t max_source_id = 16777215U;
    if (source_id == 0U || source_id > max_source_id) {
        return {Error::invalid_source_id, {}, {}};
    }

    const auto expected_start = hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    if (start_body != expected_start) {
        return {Error::invalid_base_body, {}, {}};
    }

    SourceIdTestLabel label{};
    label.fill(' ');
    label[0] = 'I';
    label[1] = 'D';
    const auto converted = std::to_chars(label.data() + 2, label.data() + label.size(), source_id);
    if (converted.ec != std::errc{}) {
        return {Error::invalid_source_id, {}, {}};
    }

    constexpr std::size_t body_header_offset = hri_call_header::t_body_header_offset;
    std::array<char, hri_call_header::header_size> header_bytes{};
    for (std::size_t index = 0; index < header_bytes.size(); ++index) {
        header_bytes[index] = static_cast<char>(start_body[body_header_offset + index]);
    }
    auto header = hri_call_header::parse_header(std::string_view(header_bytes.data(), header_bytes.size()));
    if (!header || !hri_call_header::set_source_callsign(
            *header, std::string_view(label.data(), label.size()))) {
        return {Error::invalid_base_body, {}, {}};
    }

    SourceIdResult result{};
    result.label = label;
    result.body = start_body;
    for (std::size_t index = 0; index < header_bytes.size(); ++index) {
        result.body[body_header_offset + index] = static_cast<std::uint8_t>((*header)[index]);
    }
    return result;
}

} // namespace wirex::hri_lcd_identity_candidate
