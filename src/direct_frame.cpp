#include "wirex/direct_frame.hpp"

#include <array>

namespace wirex::direct_frame {
namespace {

constexpr std::uint8_t soh = 0x01;
constexpr std::uint8_t eot = 0x04;
constexpr std::array<std::uint8_t, 16> upper_hex{{
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
}};

int parse_upper_hex(std::uint8_t value) noexcept
{
    if (value >= '0' && value <= '9') {
        return static_cast<int>(value - '0');
    }
    if (value >= 'A' && value <= 'F') {
        return static_cast<int>(value - 'A') + 10;
    }
    return -1;
}

std::uint8_t sum_low_byte(const std::uint8_t* bytes, std::size_t size) noexcept
{
    std::uint8_t sum = 0;
    for (std::size_t i = 0; i < size; ++i) {
        sum = static_cast<std::uint8_t>(sum + bytes[i]);
    }
    return sum;
}

} // namespace

DecodeResult decode(const std::uint8_t* bytes, std::size_t size)
{
    DecodeResult result{};
    if (bytes == nullptr) {
        result.error = DecodeError::null_input;
        return result;
    }
    if (size < fixed_overhead) {
        result.error = DecodeError::too_short;
        return result;
    }
    if (bytes[0] != soh) {
        result.error = DecodeError::bad_start;
        return result;
    }

    std::size_t payload_size = 0;
    for (std::size_t i = 2; i < 6; ++i) {
        const int digit = parse_upper_hex(bytes[i]);
        if (digit < 0) {
            result.error = DecodeError::bad_length_hex;
            return result;
        }
        payload_size = (payload_size << 4U) | static_cast<std::size_t>(digit);
    }

    const std::size_t expected_size = fixed_overhead + payload_size;
    if (size != expected_size) {
        result.error = DecodeError::wrong_size;
        return result;
    }

    const std::size_t eot_index = 6 + payload_size;
    if (bytes[eot_index] != eot) {
        result.error = DecodeError::bad_end;
        return result;
    }

    const int checksum_high = parse_upper_hex(bytes[eot_index + 1]);
    const int checksum_low = parse_upper_hex(bytes[eot_index + 2]);
    if (checksum_high < 0 || checksum_low < 0) {
        result.error = DecodeError::bad_checksum_hex;
        return result;
    }

    const auto checksum = sum_low_byte(bytes, eot_index + 1);
    const auto expected_checksum = static_cast<std::uint8_t>(
        (static_cast<unsigned int>(checksum_high) << 4U) |
        static_cast<unsigned int>(checksum_low));
    if (checksum != expected_checksum) {
        result.error = DecodeError::bad_checksum;
        return result;
    }

    result.record.type = bytes[1];
    result.record.payload.assign(bytes + 6, bytes + eot_index);
    return result;
}

EncodeResult encode(const Record& record)
{
    EncodeResult result{};
    if (record.payload.size() > max_payload_size) {
        result.error = EncodeError::payload_too_large;
        return result;
    }

    const auto payload_size = record.payload.size();
    result.bytes.reserve(fixed_overhead + payload_size);
    result.bytes.push_back(soh);
    result.bytes.push_back(record.type);
    for (int shift = 12; shift >= 0; shift -= 4) {
        const auto digit = static_cast<std::size_t>((payload_size >> shift) & 0x0fU);
        result.bytes.push_back(upper_hex[digit]);
    }
    result.bytes.insert(result.bytes.end(), record.payload.begin(), record.payload.end());
    result.bytes.push_back(eot);

    const auto checksum = sum_low_byte(result.bytes.data(), result.bytes.size());
    result.bytes.push_back(upper_hex[(checksum >> 4U) & 0x0fU]);
    result.bytes.push_back(upper_hex[checksum & 0x0fU]);
    return result;
}

} // namespace wirex::direct_frame
