#include "wirex/direct_frame.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using wirex::direct_frame::DecodeError;
using wirex::direct_frame::EncodeError;
using wirex::direct_frame::Record;

constexpr std::array<std::uint8_t, 9> golden_v0000{{
    0x01, 0x56, 0x30, 0x30, 0x30, 0x30, 0x04, 0x31, 0x42,
}};

constexpr std::array<std::uint8_t, 14> golden_opaque_x{{
    0x01, 0x58, 0x30, 0x30, 0x30, 0x35, 0x00, 0x01,
    0x03, 0x04, 0xff, 0x04, 0x32, 0x39,
}};

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

template <std::size_t Size>
std::vector<std::uint8_t> as_vector(const std::array<std::uint8_t, Size>& bytes)
{
    return {bytes.begin(), bytes.end()};
}

template <std::size_t Size>
void check_equal(const std::vector<std::uint8_t>& actual,
                 const std::array<std::uint8_t, Size>& expected,
                 const char* description)
{
    check(actual.size() == expected.size(), description);
    for (std::size_t i = 0; i < expected.size(); ++i) {
        check(actual[i] == expected[i], description);
    }
}

void test_independent_golden_records()
{
    const auto decoded_v = wirex::direct_frame::decode(golden_v0000.data(), golden_v0000.size());
    check(static_cast<bool>(decoded_v), "decode independent V0000 golden record");
    check(decoded_v.record.type == 0x56, "V0000 type retained as raw byte");
    check(decoded_v.record.payload.empty(), "V0000 payload is empty");

    const auto encoded_v = wirex::direct_frame::encode(Record{0x56, {}});
    check(static_cast<bool>(encoded_v), "encode independent V0000 record");
    check_equal(encoded_v.bytes, golden_v0000, "V0000 encoding equals hard-coded device-verified bytes");

    const auto decoded_x = wirex::direct_frame::decode(golden_opaque_x.data(), golden_opaque_x.size());
    check(static_cast<bool>(decoded_x), "decode independent opaque X golden record");
    check(decoded_x.record.type == 0x58, "X type retained as raw byte");
    check(decoded_x.record.payload == std::vector<std::uint8_t>({0x00, 0x01, 0x03, 0x04, 0xff}),
          "opaque payload preserves NUL, control bytes, EOT, and FF");

    const auto encoded_x = wirex::direct_frame::encode(
        Record{0x58, {0x00, 0x01, 0x03, 0x04, 0xff}});
    check(static_cast<bool>(encoded_x), "encode independent opaque X record");
    check_equal(encoded_x.bytes, golden_opaque_x, "opaque X encoding equals independent hand-calculated bytes");
}

void test_decode_rejections()
{
    check(wirex::direct_frame::decode(nullptr, 0).error == DecodeError::null_input,
          "reject null input");

    std::array<std::uint8_t, 8> too_short{};
    check(wirex::direct_frame::decode(too_short.data(), too_short.size()).error == DecodeError::too_short,
          "reject fewer than nine bytes");

    auto bad_start = as_vector(golden_v0000);
    bad_start[0] = 0x02;
    check(wirex::direct_frame::decode(bad_start.data(), bad_start.size()).error == DecodeError::bad_start,
          "reject a record without SOH");

    auto bad_length_hex = as_vector(golden_opaque_x);
    bad_length_hex[5] = 'a';
    check(wirex::direct_frame::decode(bad_length_hex.data(), bad_length_hex.size()).error ==
              DecodeError::bad_length_hex,
          "reject lowercase length hex under the documented uppercase-only policy");
    bad_length_hex[5] = 'G';
    check(wirex::direct_frame::decode(bad_length_hex.data(), bad_length_hex.size()).error ==
              DecodeError::bad_length_hex,
          "reject non-hex length byte");

    auto wrong_declared_size = as_vector(golden_v0000);
    wrong_declared_size[5] = '1';
    check(wirex::direct_frame::decode(wrong_declared_size.data(), wrong_declared_size.size()).error ==
              DecodeError::wrong_size,
          "reject length that does not match the complete record size");

    auto bad_end = as_vector(golden_v0000);
    bad_end[6] = 0x03;
    check(wirex::direct_frame::decode(bad_end.data(), bad_end.size()).error == DecodeError::bad_end,
          "reject a record without EOT at the declared payload boundary");

    auto bad_checksum_hex = as_vector(golden_opaque_x);
    bad_checksum_hex.back() = 'a';
    check(wirex::direct_frame::decode(bad_checksum_hex.data(), bad_checksum_hex.size()).error ==
              DecodeError::bad_checksum_hex,
          "reject lowercase checksum hex under the documented uppercase-only policy");

    // V0000 sums SOH through EOT to 0x1B. 1A is the result if SOH is omitted.
    auto checksum_omitting_soh = as_vector(golden_v0000);
    checksum_omitting_soh[7] = '1';
    checksum_omitting_soh[8] = 'A';
    check(wirex::direct_frame::decode(checksum_omitting_soh.data(), checksum_omitting_soh.size()).error ==
              DecodeError::bad_checksum,
          "reject checksum that omits SOH from the sum");

    auto truncated_payload_record = as_vector(golden_opaque_x);
    truncated_payload_record.pop_back();
    check(wirex::direct_frame::decode(truncated_payload_record.data(), truncated_payload_record.size()).error ==
              DecodeError::wrong_size,
          "reject truncated record with a declared payload length");

    auto concatenated = as_vector(golden_v0000);
    concatenated.insert(concatenated.end(), golden_v0000.begin(), golden_v0000.end());
    check(wirex::direct_frame::decode(concatenated.data(), concatenated.size()).error == DecodeError::wrong_size,
          "reject two concatenated records as one single-record input");
}

void test_payload_length_limits()
{
    Record maximum{};
    maximum.type = 0x5a;
    maximum.payload.assign(wirex::direct_frame::max_payload_size, 0x00);

    const auto encoded = wirex::direct_frame::encode(maximum);
    check(static_cast<bool>(encoded), "encode maximum 0xFFFF-byte payload");
    check(encoded.bytes.size() == 65544, "maximum record has payload length plus nine bytes");
    check(encoded.bytes[0] == 0x01 && encoded.bytes[1] == 0x5a,
          "maximum record starts with SOH and the raw type");
    check(encoded.bytes[2] == 'F' && encoded.bytes[3] == 'F' &&
              encoded.bytes[4] == 'F' && encoded.bytes[5] == 'F',
          "maximum payload length is canonical uppercase FFFF");
    check(encoded.bytes[6] == 0x00 && encoded.bytes[6 + 32767] == 0x00 &&
              encoded.bytes[6 + 65534] == 0x00,
          "maximum opaque payload bytes are retained");
    check(encoded.bytes[65541] == 0x04 && encoded.bytes[65542] == '7' && encoded.bytes[65543] == '7',
          "maximum record ends at the declared boundary with independent 77 checksum");

    const auto decoded = wirex::direct_frame::decode(encoded.bytes.data(), encoded.bytes.size());
    check(static_cast<bool>(decoded), "decode maximum 0xFFFF-byte payload");
    check(decoded.record.type == maximum.type && decoded.record.payload.size() == 65535,
          "maximum payload length survives decoding");

    Record oversized{};
    oversized.type = 0x5a;
    oversized.payload.assign(65536, 0x00);
    const auto rejected = wirex::direct_frame::encode(oversized);
    check(rejected.error == EncodeError::payload_too_large,
          "reject 0x10000-byte payload instead of truncating the length");
    check(rejected.bytes.empty(), "oversized encoding returns no partial record");
}

} // namespace

int main()
{
    test_independent_golden_records();
    test_decode_rejections();
    test_payload_length_limits();
    std::cout << "All DIRECT frame checks passed.\n";
    return EXIT_SUCCESS;
}
