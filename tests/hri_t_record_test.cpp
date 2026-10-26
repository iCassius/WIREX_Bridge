#include "wirex/hri_t_record.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

struct ModeFixture {
    char input_header_mode;
    char output_mode;
    const char* count_token;
    std::size_t payload_chars;
};

constexpr std::array<ModeFixture, 3> mode_fixtures{{
    {'4', '0', "0061", 0x60},
    {'6', '2', "0089", 0x88},
    {'7', '3', "00BB", 0xba},
}};

wirex::hri_call_header::Header fixture_header(char mode)
{
    wirex::hri_call_header::Header header{};
    header.fill('Q');
    header[wirex::hri_call_header::header_mode_offset] = mode;
    header[wirex::hri_call_header::destination_callsign_offset] = 'D';
    header[wirex::hri_call_header::source_callsign_offset] = 'S';
    header[wirex::hri_call_header::local_callsign_offset] = 'L';
    return header;
}

void test_static_mode_count_fixtures()
{
    using namespace wirex::hri_t_record;

    BodyPrefixFields prefix{{'2', 'A', 'B', 'C', 'D', 'E', '0'}};
    const std::string raw_trailer("\x12\xA0", 2);
    const auto encoded_trailer = encode_tail_with_03_checksum(raw_trailer);
    check(encoded_trailer == "12A003B5",
          "R84 FUN_100139f0 fixture uses HEX plus ASCII 03 plus sum8-and-3");

    for (const auto& fixture : mode_fixtures) {
        const auto original_header = fixture_header(fixture.input_header_mode);
        const auto result = build_nonempty_t_text_body(
            prefix,
            original_header,
            fixture.count_token,
            std::string(fixture.payload_chars, 'A'),
            raw_trailer);
        check(static_cast<bool>(result), "official mode/length pair builds an offline T text body");

        auto expected_header = original_header;
        expected_header[wirex::hri_call_header::header_mode_offset] = fixture.output_mode;
        std::string expected(prefix.bytes.data(), prefix.bytes.size());
        expected.append(expected_header.data(), expected_header.size());
        expected.append(fixture.payload_chars, 'A');
        expected.append("*****12A003B5");

        check(result.body == expected,
              "body preserves opaque prefix, 68-byte header, payload, separator, and trailer order");
        check(result.body.size() == 7 + 68 + fixture.payload_chars + 5 + encoded_trailer.size(),
              "body length follows the observed HRI field and payload boundaries");
        check(result.body[7 + 4] == fixture.output_mode,
              "mode normalization modifies only copied header byte +4 at body offset 0x0b");
        check(original_header[4] == fixture.input_header_mode,
              "building a T body leaves the caller's original 68-byte header unchanged");
        check(result.body.substr(7 + 68 + fixture.payload_chars, 5) == "*****",
              "HRI's five-star separator precedes the appended trailer");
        check(result.body.substr(result.body.size() - encoded_trailer.size()) == encoded_trailer,
              "upstream raw trailer encoding remains at the end of the T text body");
    }
}

void test_mode2_golden_offsets()
{
    using namespace wirex::hri_t_record;

    const BodyPrefixFields prefix{{'2', 'A', 'B', 'C', 'D', 'E', '0'}};
    const auto input_header = fixture_header('6');
    const std::string payload(136, 'A');
    const std::string trailer_raw("\x12\xA0", 2);
    const auto result = build_nonempty_t_text_body(
        prefix, input_header, "0089", payload, trailer_raw);
    check(static_cast<bool>(result), "mode 2 golden fixture builds");
    check(result.body.size() == 224, "mode 2 golden body is 224 ASCII characters");

    constexpr std::string_view expected_prefix = "2ABCDE0";
    for (std::size_t offset = 0; offset < expected_prefix.size(); ++offset) {
        check(result.body[offset] == expected_prefix[offset],
              "body bytes 0..6 are the explicit prefix fixture");
    }

    auto expected_header = input_header;
    expected_header[4] = '2';
    for (std::size_t offset = 0; offset < expected_header.size(); ++offset) {
        check(result.body[7 + offset] == expected_header[offset],
              "body bytes 7..74 preserve the 68-byte header except normalized byte +4");
    }
    for (std::size_t offset = 75; offset < 211; ++offset) {
        check(result.body[offset] == 'A', "body bytes 75..210 are the 136-character payload");
    }
    check(result.body.substr(211, 5) == "*****",
          "body bytes 211..215 are the five-character separator");
    check(result.body.substr(216, 8) == "12A003B5",
          "body bytes 216..223 are the static tail checksum fixture");
    check(result.body[0x0b] == '2', "mode 2 selector sits at body offset 0x0b");
}

void test_invalid_counts_modes_and_payloads_are_rejected()
{
    using namespace wirex::hri_t_record;
    BodyPrefixFields prefix{{'2', 'A', 'B', 'C', 'D', 'E', '0'}};
    const std::string trailer;
    const auto payload = std::string(0x88, 'B');

    auto result = build_nonempty_t_text_body(
        prefix, fixture_header('6'), "0088", payload, trailer);
    check(result.error == BuildError::payload_count_mismatch,
          "count token must equal copied ASCII HEX length plus one");

    result = build_nonempty_t_text_body(
        prefix, fixture_header('6'), "00G9", payload, trailer);
    check(result.error == BuildError::invalid_count_token,
          "count token rejects non-HEX characters");

    std::string non_hex_payload = payload;
    non_hex_payload[12] = 'Z';
    result = build_nonempty_t_text_body(
        prefix, fixture_header('6'), "0089", non_hex_payload, trailer);
    check(result.error == BuildError::invalid_payload_hex,
          "payload body requires ASCII HEX even though the DLL only checks its length");

    result = build_nonempty_t_text_body(
        prefix, fixture_header('5'), "0061", std::string(0x60, 'C'), trailer);
    check(result.error == BuildError::unsupported_header_mode,
          "mode one is rejected by the voice-body builder");

    auto invalid_header = fixture_header('6');
    invalid_header[20] = '\0';
    result = build_nonempty_t_text_body(
        prefix, invalid_header, "0089", payload, trailer);
    check(result.error == BuildError::invalid_header,
          "a nonempty T body rejects a malformed 68-byte header");

    auto invalid_prefix = prefix;
    invalid_prefix.bytes[2] = static_cast<char>(0x80);
    result = build_nonempty_t_text_body(
        invalid_prefix, fixture_header('6'), "0089", payload, trailer);
    check(result.error == BuildError::invalid_prefix,
          "opaque HRI prefix still rejects NUL and non-ASCII bytes");

    invalid_prefix = prefix;
    invalid_prefix.bytes[6] = '1';
    result = build_nonempty_t_text_body(
        invalid_prefix, fixture_header('6'), "0089", payload, trailer);
    check(result.error == BuildError::invalid_prefix,
          "the seventh HRI prefix byte must remain the observed ASCII zero");

    invalid_prefix = prefix;
    invalid_prefix.bytes[0] = '4';
    result = build_nonempty_t_text_body(
        invalid_prefix, fixture_header('6'), "0089", payload, trailer);
    check(result.error == BuildError::invalid_prefix,
          "the HRI selector prefix accepts only observed characters zero through three");
}

void test_empty_raw_trailer_still_has_terminator_and_sum()
{
    check(wirex::hri_t_record::encode_tail_with_03_checksum({}) == "0303",
          "the FUN_100139f0 tail helper emits 03 and checksum 03 for an empty raw block");
    const std::string raw_wrap("\xFF\x02", 2);
    check(wirex::hri_t_record::encode_tail_with_03_checksum(raw_wrap) == "FF020304",
          "the sum wraps at eight bits before adding three and emitting HEX");
}

} // namespace

int main()
{
    test_static_mode_count_fixtures();
    test_mode2_golden_offsets();
    test_invalid_counts_modes_and_payloads_are_rejected();
    test_empty_raw_trailer_still_has_terminator_and_sum();
    std::cout << "All offline HRI T record checks passed.\n";
    return EXIT_SUCCESS;
}
