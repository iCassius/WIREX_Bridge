#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wirex::direct_frame {

inline constexpr std::size_t fixed_overhead = 9;
inline constexpr std::size_t max_payload_size = 0xffffU;

struct Record {
    std::uint8_t type{};
    std::vector<std::uint8_t> payload;
};

enum class DecodeError {
    none,
    null_input,
    too_short,
    bad_start,
    bad_length_hex,
    wrong_size,
    bad_end,
    bad_checksum_hex,
    bad_checksum,
};

struct DecodeResult {
    Record record{};
    DecodeError error{DecodeError::none};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == DecodeError::none;
    }
};

enum class EncodeError {
    none,
    payload_too_large,
};

struct EncodeResult {
    std::vector<std::uint8_t> bytes;
    EncodeError error{EncodeError::none};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == EncodeError::none;
    }
};

[[nodiscard]] DecodeResult decode(const std::uint8_t* bytes, std::size_t size);
[[nodiscard]] EncodeResult encode(const Record& record);

} // namespace wirex::direct_frame
