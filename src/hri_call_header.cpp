#include "wirex/hri_call_header.hpp"

namespace wirex::hri_call_header {

namespace {

bool is_ascii_header_byte(char value) noexcept
{
    const auto byte = static_cast<unsigned char>(value);
    return byte != 0U && byte <= 0x7fU;
}

bool is_printable_ascii(std::string_view value) noexcept
{
    for (const char character : value) {
        const auto byte = static_cast<unsigned char>(character);
        if (byte < 0x20U || byte > 0x7eU) {
            return false;
        }
    }
    return true;
}

std::optional<std::string_view> callsign_field(
    const Header& header,
    std::size_t offset) noexcept
{
    if (!is_valid_header(header)) {
        return std::nullopt;
    }

    const std::string_view field(header.data() + offset, callsign_size);
    if (!is_printable_ascii(field)) {
        return std::nullopt;
    }
    return field;
}

bool replace_callsign_field(
    Header& header,
    std::size_t offset,
    std::string_view callsign) noexcept
{
    if (!is_valid_header(header) || callsign.size() != callsign_size ||
        !is_printable_ascii(callsign)) {
        return false;
    }

    for (std::size_t index = 0; index < callsign_size; ++index) {
        header[offset + index] = callsign[index];
    }
    return true;
}

} // namespace

std::optional<Header> parse_header(std::string_view input) noexcept
{
    if (input.size() != header_size) {
        return std::nullopt;
    }

    Header header{};
    for (std::size_t index = 0; index < header_size; ++index) {
        if (!is_ascii_header_byte(input[index])) {
            return std::nullopt;
        }
        header[index] = input[index];
    }
    return header;
}

bool is_valid_header(const Header& header) noexcept
{
    for (const char value : header) {
        if (!is_ascii_header_byte(value)) {
            return false;
        }
    }
    return true;
}

std::optional<std::string_view> destination_callsign(const Header& header) noexcept
{
    return callsign_field(header, destination_callsign_offset);
}

std::optional<std::string_view> source_callsign(const Header& header) noexcept
{
    return callsign_field(header, source_callsign_offset);
}

std::optional<std::string_view> local_callsign(const Header& header) noexcept
{
    return callsign_field(header, local_callsign_offset);
}

bool set_destination_callsign(Header& header, std::string_view callsign) noexcept
{
    return replace_callsign_field(header, destination_callsign_offset, callsign);
}

bool set_source_callsign(Header& header, std::string_view callsign) noexcept
{
    return replace_callsign_field(header, source_callsign_offset, callsign);
}

bool set_local_callsign(Header& header, std::string_view callsign) noexcept
{
    return replace_callsign_field(header, local_callsign_offset, callsign);
}

std::optional<char> nonempty_t_body_mode_character(const Header& header) noexcept
{
    if (!is_valid_header(header)) {
        return std::nullopt;
    }

    const auto field = static_cast<unsigned char>(header[header_mode_offset]);
    return static_cast<char>('0' + (field & 0x03U));
}

} // namespace wirex::hri_call_header
