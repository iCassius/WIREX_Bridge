#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::dmrd {

inline constexpr std::size_t datagram_size = 55;
inline constexpr std::size_t payload_size = 33;
inline constexpr std::uint32_t max_id24 = 0x00ffffffU;

struct Datagram {
    std::uint8_t sequence{};
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    std::uint32_t gateway_id{};
    std::uint8_t flags{};
    std::array<std::uint8_t, 4> stream_id{};
    std::array<std::uint8_t, payload_size> payload{};
    std::uint8_t ber{};
    std::uint8_t rssi{};
};

enum class DecodeError {
    none,
    null_input,
    wrong_size,
    bad_magic,
};

struct DecodeResult {
    Datagram datagram{};
    DecodeError error{DecodeError::none};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == DecodeError::none;
    }
};

enum class EncodeError {
    none,
    source_id_out_of_range,
    destination_id_out_of_range,
};

struct EncodeResult {
    std::array<std::uint8_t, datagram_size> bytes{};
    EncodeError error{EncodeError::none};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == EncodeError::none;
    }
};

[[nodiscard]] DecodeResult decode(const std::uint8_t* bytes, std::size_t size) noexcept;
[[nodiscard]] EncodeResult encode(const Datagram& datagram) noexcept;

} // namespace wirex::dmrd
