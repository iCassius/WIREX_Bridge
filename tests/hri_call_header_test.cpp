#include "wirex/hri_call_header.hpp"
#include "wirex/hri_t_payload.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>

namespace {

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void test_fixed_ascii_header_contract_and_fields()
{
    using namespace wirex::hri_call_header;

    std::string fixture(header_size, 'Q');
    fixture[0] = 'A';
    fixture[7] = 'B';
    fixture[header_size - 1] = 'Z';
    fixture[destination_callsign_offset] = 'D';
    fixture.replace(destination_callsign_offset, callsign_size, "DEST000001");
    fixture.replace(source_callsign_offset, callsign_size, "SRC0000001");
    fixture.replace(local_callsign_offset, callsign_size, "LOCAL00001");
    fixture[60] = '\x01'; // 未命名的 ASCII 控制字节应原样保留。

    auto parsed = parse_header(fixture);
    check(parsed.has_value(), "exactly 68 non-NUL ASCII bytes parse");
    check(is_valid_header(*parsed), "parsed header satisfies the fixed ASCII contract");
    check((*parsed)[0] == 'A' && (*parsed)[7] == 'B' &&
              (*parsed)[60] == '\x01' && (*parsed)[header_size - 1] == 'Z',
          "parser preserves unknown header bytes in place");

    const auto destination = destination_callsign(*parsed);
    const auto source = source_callsign(*parsed);
    const auto local = local_callsign(*parsed);
    check(destination.has_value() && *destination == "DEST000001",
          "destination callsign accessor reads exactly header bytes +8 through +17");
    check(source.has_value() && *source == "SRC0000001",
          "source callsign accessor reads exactly header bytes +0x12 through +0x1b");
    check(local.has_value() && *local == "LOCAL00001",
          "HRI-local callsign accessor reads exactly header bytes +0x1c through +0x25");

    check(set_destination_callsign(*parsed, "ROOM000001"),
          "destination setter accepts one exact 10-character ASCII field");
    check(set_source_callsign(*parsed, "N0CALL1234"),
          "source setter accepts one exact 10-character ASCII field");
    check(set_local_callsign(*parsed, "NODE000001"),
          "HRI-local callsign setter accepts one exact 10-character ASCII field");
    check(*destination_callsign(*parsed) == "ROOM000001" &&
              *source_callsign(*parsed) == "N0CALL1234" &&
              *local_callsign(*parsed) == "NODE000001",
          "setters update only the three independently identified call-sign slots");
    check((*parsed)[0] == 'A' && (*parsed)[7] == 'B' &&
              (*parsed)[60] == '\x01' && (*parsed)[header_size - 1] == 'Z',
          "call-sign replacement leaves every unrelated header byte unchanged");

    const Header before_invalid_update = *parsed;
    check(!set_source_callsign(*parsed, "TOOSHORT"),
          "setter rejects call-sign values shorter than ten bytes");
    const std::string non_ascii("123456789\x80", 10);
    check(!set_destination_callsign(*parsed, non_ascii),
          "setter rejects non-ASCII call-sign bytes");
    check(!set_local_callsign(*parsed, "NODE"),
          "HRI-local setter rejects a call-sign value shorter than ten bytes");
    check(*parsed == before_invalid_update,
          "rejected setter inputs leave the original header unchanged");
}

void test_malformed_headers_are_rejected()
{
    using namespace wirex::hri_call_header;

    const std::string short_header(header_size - 1, '0');
    const std::string long_header(header_size + 1, '0');
    check(!parse_header(short_header).has_value(), "67-byte header is rejected");
    check(!parse_header(long_header).has_value(), "69-byte header is rejected");

    std::string with_nul(header_size, '0');
    with_nul[12] = '\0';
    check(!parse_header(with_nul).has_value(), "embedded NUL is rejected");

    std::string with_non_ascii(header_size, '0');
    with_non_ascii[45] = static_cast<char>(0x80);
    check(!parse_header(with_non_ascii).has_value(), "non-ASCII byte is rejected");
}

void test_t_body_mode_offset_and_existing_empty_candidate()
{
    using namespace wirex::hri_call_header;

    Header header{};
    header.fill('0');
    for (std::size_t digit = 0; digit < 4; ++digit) {
        header[header_mode_offset] = static_cast<char>('4' + digit);
        const auto mode_character = nonempty_t_body_mode_character(header);
        check(mode_character.has_value() &&
                  *mode_character == static_cast<char>('0' + digit),
              "nonempty T mode digit comes from header-relative offset 4 low two bits");
    }

    const auto empty_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(
        1, 1, 9);
    check(empty_body.size() == 90, "existing empty-header T candidate remains 90 bytes");
    check(empty_body[t_body_header_offset + header_mode_offset] == '4' &&
              empty_body[t_body_mode_offset] == '4',
          "empty-header branch retains its original header byte at T-body offset 0x0b");

    const auto parsed_empty_header = parse_header(std::string_view(
        reinterpret_cast<const char*>(empty_body.data() + t_body_header_offset), header_size));
    check(parsed_empty_header.has_value(),
          "existing empty-header candidate satisfies the fixed header contract");
}

} // namespace

int main()
{
    test_fixed_ascii_header_contract_and_fields();
    test_malformed_headers_are_rejected();
    test_t_body_mode_offset_and_existing_empty_candidate();
    std::cout << "All HRI call-header offline checks passed.\n";
    return EXIT_SUCCESS;
}
