#include "wirex/hri_t_record.hpp"

#include <utility>

namespace wirex::hri_t_record {

namespace {

constexpr char hex_digits[] = "0123456789ABCDEF";

bool is_ascii_hex(char value) noexcept
{
    return (value >= '0' && value <= '9') ||
        (value >= 'A' && value <= 'F') ||
        (value >= 'a' && value <= 'f');
}

std::uint8_t hex_nibble(char value) noexcept
{
    if (value >= '0' && value <= '9') {
        return static_cast<std::uint8_t>(value - '0');
    }
    if (value >= 'A' && value <= 'F') {
        return static_cast<std::uint8_t>(value - 'A' + 10);
    }
    return static_cast<std::uint8_t>(value - 'a' + 10);
}

bool parse_count_token(std::string_view token, std::size_t& count) noexcept
{
    if (token.size() != 4) {
        return false;
    }

    std::uint16_t value = 0;
    for (const char digit : token) {
        if (!is_ascii_hex(digit)) {
            return false;
        }
        value = static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(value << 4U) | hex_nibble(digit));
    }
    count = value;
    return true;
}

bool is_valid_prefix(const BodyPrefixFields& prefix) noexcept
{
    if (prefix.bytes[0] < '0' || prefix.bytes[0] > '3') {
        return false;
    }

    if (prefix.bytes[6] != '0') {
        return false;
    }
    for (const char value : prefix.bytes) {
        const auto byte = static_cast<unsigned char>(value);
        if (byte == 0U || byte > 0x7fU) {
            return false;
        }
    }
    return true;
}

std::size_t required_payload_size(char mode) noexcept
{
    switch (mode) {
    case '0': return 0x60;
    case '2': return 0x88;
    case '3': return 0xba;
    default: return 0;
    }
}

} // namespace

std::string encode_tail_with_03_checksum(std::string_view raw_bytes)
{
    std::string encoded;
    if (raw_bytes.size() <= (encoded.max_size() - 4U) / 2U) {
        encoded.reserve(raw_bytes.size() * 2U + 4U);
    }

    std::uint8_t sum = 0;
    for (const char raw_byte : raw_bytes) {
        const auto byte = static_cast<std::uint8_t>(static_cast<unsigned char>(raw_byte));
        sum = static_cast<std::uint8_t>(sum + byte);
        encoded.push_back(hex_digits[(byte >> 4U) & 0x0fU]);
        encoded.push_back(hex_digits[byte & 0x0fU]);
    }

    const auto checksum = static_cast<std::uint8_t>(sum + 3U);
    encoded.append("03");
    encoded.push_back(hex_digits[(checksum >> 4U) & 0x0fU]);
    encoded.push_back(hex_digits[checksum & 0x0fU]);
    return encoded;
}

BuildResult build_nonempty_t_text_body(
    const BodyPrefixFields& prefix,
    const hri_call_header::Header& header,
    std::string_view count_token_hex,
    std::string_view payload_hex,
    std::string_view trailer_raw)
{
    if (!is_valid_prefix(prefix)) {
        return {BuildError::invalid_prefix, {}};
    }
    if (!hri_call_header::is_valid_header(header)) {
        return {BuildError::invalid_header, {}};
    }

    const auto mode = hri_call_header::nonempty_t_body_mode_character(header);
    if (!mode.has_value()) {
        return {BuildError::invalid_header, {}};
    }
    const std::size_t expected_payload_size = required_payload_size(*mode);
    if (expected_payload_size == 0) {
        return {BuildError::unsupported_header_mode, {}};
    }

    std::size_t count = 0;
    if (!parse_count_token(count_token_hex, count)) {
        return {BuildError::invalid_count_token, {}};
    }
    if (count == 0 || count - 1U != payload_hex.size() ||
        payload_hex.size() != expected_payload_size) {
        return {BuildError::payload_count_mismatch, {}};
    }
    for (const char value : payload_hex) {
        if (!is_ascii_hex(value)) {
            return {BuildError::invalid_payload_hex, {}};
        }
    }

    std::string body;
    const auto trailer = encode_tail_with_03_checksum(trailer_raw);
    body.reserve(body_prefix_size + header.size() + payload_hex.size() +
                 voice_separator_size + trailer.size());
    body.append(prefix.bytes.data(), prefix.bytes.size());
    body.append(header.data(), header.size());
    body[body_prefix_size + hri_call_header::header_mode_offset] = *mode;
    body.append(payload_hex.data(), payload_hex.size());
    body.append(voice_separator_size, '*');
    body.append(trailer);

    return {BuildError::none, std::move(body)};
}

} // namespace wirex::hri_t_record
