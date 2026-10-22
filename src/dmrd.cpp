#include "wirex/dmrd.hpp"

namespace wirex::dmrd {
namespace {

constexpr std::array<std::uint8_t, 4> magic{{'D', 'M', 'R', 'D'}};

std::uint32_t read_be24(const std::uint8_t* bytes) noexcept
{
    return (static_cast<std::uint32_t>(bytes[0]) << 16U) |
           (static_cast<std::uint32_t>(bytes[1]) << 8U) |
           static_cast<std::uint32_t>(bytes[2]);
}

std::uint32_t read_be32(const std::uint8_t* bytes) noexcept
{
    return (static_cast<std::uint32_t>(bytes[0]) << 24U) |
           (static_cast<std::uint32_t>(bytes[1]) << 16U) |
           (static_cast<std::uint32_t>(bytes[2]) << 8U) |
           static_cast<std::uint32_t>(bytes[3]);
}

void write_be24(std::uint8_t* bytes, std::uint32_t value) noexcept
{
    bytes[0] = static_cast<std::uint8_t>((value >> 16U) & 0xffU);
    bytes[1] = static_cast<std::uint8_t>((value >> 8U) & 0xffU);
    bytes[2] = static_cast<std::uint8_t>(value & 0xffU);
}

void write_be32(std::uint8_t* bytes, std::uint32_t value) noexcept
{
    bytes[0] = static_cast<std::uint8_t>((value >> 24U) & 0xffU);
    bytes[1] = static_cast<std::uint8_t>((value >> 16U) & 0xffU);
    bytes[2] = static_cast<std::uint8_t>((value >> 8U) & 0xffU);
    bytes[3] = static_cast<std::uint8_t>(value & 0xffU);
}

} // namespace

DecodeResult decode(const std::uint8_t* bytes, std::size_t size) noexcept
{
    DecodeResult result{};
    if (bytes == nullptr) {
        result.error = DecodeError::null_input;
        return result;
    }
    if (size != datagram_size) {
        result.error = DecodeError::wrong_size;
        return result;
    }
    for (std::size_t i = 0; i < magic.size(); ++i) {
        if (bytes[i] != magic[i]) {
            result.error = DecodeError::bad_magic;
            return result;
        }
    }

    result.datagram.sequence = bytes[4];
    result.datagram.source_id = read_be24(bytes + 5);
    result.datagram.destination_id = read_be24(bytes + 8);
    result.datagram.gateway_id = read_be32(bytes + 11);
    result.datagram.flags = bytes[15];
    for (std::size_t i = 0; i < result.datagram.stream_id.size(); ++i) {
        result.datagram.stream_id[i] = bytes[16 + i];
    }
    for (std::size_t i = 0; i < result.datagram.payload.size(); ++i) {
        result.datagram.payload[i] = bytes[20 + i];
    }
    result.datagram.ber = bytes[53];
    result.datagram.rssi = bytes[54];
    return result;
}

EncodeResult encode(const Datagram& datagram) noexcept
{
    EncodeResult result{};
    if (datagram.source_id > max_id24) {
        result.error = EncodeError::source_id_out_of_range;
        return result;
    }
    if (datagram.destination_id > max_id24) {
        result.error = EncodeError::destination_id_out_of_range;
        return result;
    }

    for (std::size_t i = 0; i < magic.size(); ++i) {
        result.bytes[i] = magic[i];
    }
    result.bytes[4] = datagram.sequence;
    write_be24(result.bytes.data() + 5, datagram.source_id);
    write_be24(result.bytes.data() + 8, datagram.destination_id);
    write_be32(result.bytes.data() + 11, datagram.gateway_id);
    result.bytes[15] = datagram.flags;
    for (std::size_t i = 0; i < datagram.stream_id.size(); ++i) {
        result.bytes[16 + i] = datagram.stream_id[i];
    }
    for (std::size_t i = 0; i < datagram.payload.size(); ++i) {
        result.bytes[20 + i] = datagram.payload[i];
    }
    result.bytes[53] = datagram.ber;
    result.bytes[54] = datagram.rssi;
    return result;
}

} // namespace wirex::dmrd
