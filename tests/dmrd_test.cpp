#include "wirex/dmrd.hpp"

#include <array>
#include <cstdlib>
#include <iostream>

namespace {

using wirex::dmrd::Datagram;

constexpr std::array<std::uint8_t, wirex::dmrd::datagram_size> golden{{
    0x44, 0x4d, 0x52, 0x44, 0xa5,
    0x12, 0x34, 0x56, 0xab, 0xcd, 0xef,
    0x89, 0xab, 0xcd, 0xef, 0xe7,
    0x01, 0x23, 0xfe, 0x80,
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0x20, 0x5a, 0xc3,
}};

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void check_equal(const Datagram& actual, const Datagram& expected, const char* description)
{
    check(actual.sequence == expected.sequence, description);
    check(actual.source_id == expected.source_id, description);
    check(actual.destination_id == expected.destination_id, description);
    check(actual.gateway_id == expected.gateway_id, description);
    check(actual.flags == expected.flags, description);
    check(actual.stream_id == expected.stream_id, description);
    check(actual.payload == expected.payload, description);
    check(actual.ber == expected.ber, description);
    check(actual.rssi == expected.rssi, description);
}

void test_golden_vector()
{
    Datagram expected{};
    expected.sequence = 0xa5;
    expected.source_id = 0x123456U;
    expected.destination_id = 0xabcdefU;
    expected.gateway_id = 0x89abcdefU;
    expected.flags = 0xe7;
    expected.stream_id = {{0x01, 0x23, 0xfe, 0x80}};
    for (std::size_t i = 0; i < expected.payload.size(); ++i) {
        expected.payload[i] = static_cast<std::uint8_t>(i);
    }
    expected.ber = 0x5a;
    expected.rssi = 0xc3;

    const auto decoded = wirex::dmrd::decode(golden.data(), golden.size());
    check(static_cast<bool>(decoded), "decode hard-coded 55-byte golden vector");
    check_equal(decoded.datagram, expected, "decoded fields match manually constructed record");

    const auto encoded = wirex::dmrd::encode(expected);
    check(static_cast<bool>(encoded), "encode manually constructed golden record");
    check(encoded.bytes == golden, "encoded bytes exactly equal independent hard-coded golden vector");
}

void test_invalid_datagrams()
{
    std::array<std::uint8_t, wirex::dmrd::datagram_size - 1> short_packet{};
    std::array<std::uint8_t, wirex::dmrd::datagram_size + 1> long_packet{};
    for (std::size_t i = 0; i < golden.size(); ++i) {
        long_packet[i] = golden[i];
    }
    check(wirex::dmrd::decode(short_packet.data(), short_packet.size()).error ==
              wirex::dmrd::DecodeError::wrong_size,
          "reject 54-byte datagram");
    check(wirex::dmrd::decode(long_packet.data(), long_packet.size()).error ==
              wirex::dmrd::DecodeError::wrong_size,
          "reject 56-byte datagram");
    check(wirex::dmrd::decode(nullptr, golden.size()).error ==
              wirex::dmrd::DecodeError::null_input,
          "reject null input");

    auto bad_magic = golden;
    bad_magic[0] = 0x58;
    check(wirex::dmrd::decode(bad_magic.data(), bad_magic.size()).error ==
              wirex::dmrd::DecodeError::bad_magic,
          "reject non-DMRD magic");
}

void test_id_limits_and_overflow()
{
    auto max_ids = wirex::dmrd::decode(golden.data(), golden.size()).datagram;
    max_ids.source_id = wirex::dmrd::max_id24;
    max_ids.destination_id = wirex::dmrd::max_id24;
    const auto encoded = wirex::dmrd::encode(max_ids);
    check(static_cast<bool>(encoded), "encode maximum 24-bit source and destination IDs");
    check(encoded.bytes[5] == 0xff && encoded.bytes[6] == 0xff && encoded.bytes[7] == 0xff,
          "maximum source ID encoded as three FF bytes");
    check(encoded.bytes[8] == 0xff && encoded.bytes[9] == 0xff && encoded.bytes[10] == 0xff,
          "maximum destination ID encoded as three FF bytes");
    const auto decoded = wirex::dmrd::decode(encoded.bytes.data(), encoded.bytes.size());
    check(static_cast<bool>(decoded), "decode maximum-ID datagram");
    check(decoded.datagram.source_id == wirex::dmrd::max_id24 &&
              decoded.datagram.destination_id == wirex::dmrd::max_id24,
          "maximum 24-bit IDs survive encode/decode");

    auto overflow_source = max_ids;
    overflow_source.source_id = wirex::dmrd::max_id24 + 1U;
    check(wirex::dmrd::encode(overflow_source).error ==
              wirex::dmrd::EncodeError::source_id_out_of_range,
          "reject source ID above 24 bits without truncation");

    auto overflow_destination = max_ids;
    overflow_destination.destination_id = wirex::dmrd::max_id24 + 1U;
    check(wirex::dmrd::encode(overflow_destination).error ==
              wirex::dmrd::EncodeError::destination_id_out_of_range,
          "reject destination ID above 24 bits without truncation");
}

void test_transparent_fields()
{
    auto record = wirex::dmrd::decode(golden.data(), golden.size()).datagram;
    record.flags = 0xff;
    record.stream_id = {{0x80, 0x00, 0x7f, 0xfe}};
    for (std::size_t i = 0; i < record.payload.size(); ++i) {
        record.payload[i] = static_cast<std::uint8_t>(0xffU - i);
    }

    const auto encoded = wirex::dmrd::encode(record);
    check(static_cast<bool>(encoded), "encode arbitrary flags, stream bytes, and payload");
    check(encoded.bytes[15] == 0xff, "unknown flags bits retained unchanged");
    check(encoded.bytes[16] == 0x80 && encoded.bytes[17] == 0x00 &&
              encoded.bytes[18] == 0x7f && encoded.bytes[19] == 0xfe,
          "stream bytes retained in supplied order");
    const auto decoded = wirex::dmrd::decode(encoded.bytes.data(), encoded.bytes.size());
    check(static_cast<bool>(decoded), "decode arbitrary-field datagram");
    check_equal(decoded.datagram, record, "transparent fields preserved");
}

} // namespace

int main()
{
    test_golden_vector();
    test_invalid_datagrams();
    test_id_limits_and_overflow();
    test_transparent_fields();
    std::cout << "All DMRD codec checks passed.\n";
    return EXIT_SUCCESS;
}
