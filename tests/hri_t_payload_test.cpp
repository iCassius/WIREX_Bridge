#include "wirex/direct_frame.hpp"
#include "wirex/hri_t_payload.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using wirex::hri_t_payload::CandidateBody;

// 以下 literal 直接取自 R63 合成 fixture，独立于正文组装函数。
constexpr char r63_fixture_body[] =
    "30000002011400000000000000000000000000000000000000000000000000000000000000000001F*****3033";
static_assert(sizeof(r63_fixture_body) == wirex::hri_t_payload::candidate_body_size + 1,
              "R63 body literal must contain exactly 90 ASCII bytes plus its C++ terminator");

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void check_body_matches_r63_tail(const CandidateBody& body, const char* description)
{
    for (std::size_t i = 1; i < body.size(); ++i) {
        check(body[i] == static_cast<std::uint8_t>(r63_fixture_body[i]), description);
    }
}

void test_full_r63_fixture_literal()
{
    const auto body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9);
    check(body.size() == 90, "R63 candidate body has exactly 90 bytes");
    for (std::size_t i = 0; i < body.size(); ++i) {
        check(body[i] == static_cast<std::uint8_t>(r63_fixture_body[i]),
              "candidate body exactly matches the independent full R63 literal");
        check(body[i] != 0, "candidate body contains no NUL byte");
    }
    check(body[7] == '2' && body[9] == '1' && body[10] == '1' && body[11] == '4',
          "default header markers occupy absolute body offsets 7, 9, 10, and 11");
}

struct SelectorCase {
    std::int32_t ptt_sw;
    std::int32_t field50;
    std::uint8_t flags248c;
    std::uint8_t selector;
    std::array<std::uint8_t, 2> checksum_ascii;
};

void test_selector_branches_and_direct_envelope()
{
    constexpr std::array<SelectorCase, 4> cases{{
        {0, 1, 0xff, '0', {{'1', '9'}}},
        {1, 1, 0xff, '3', {{'1', 'C'}}},
        {1, -7, 0x84, '1', {{'1', 'A'}}},
        {1, 0, 0x03, '2', {{'1', 'B'}}},
    }};
    constexpr std::array<std::uint8_t, 6> expected_prefix{{0x01, 'T', '0', '0', '5', 'A'}};

    for (const auto& item : cases) {
        const auto body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(
            item.ptt_sw, item.field50, item.flags248c);
        check(body[0] == item.selector, "selector follows the requested PttSw/field50/flags branch");
        check_body_matches_r63_tail(body, "all selector branches retain the R63 fixed body bytes");

        const std::vector<std::uint8_t> payload(body.begin(), body.end());
        const auto frame = wirex::direct_frame::encode(wirex::direct_frame::Record{'T', payload});
        check(static_cast<bool>(frame), "existing DIRECT frame encoder accepts the candidate body");
        check(frame.bytes.size() == 99, "T envelope is exactly 99 bytes");
        for (std::size_t i = 0; i < expected_prefix.size(); ++i) {
            check(frame.bytes[i] == expected_prefix[i], "T envelope prefix is SOH+T005A");
        }
        for (std::size_t i = 0; i < body.size(); ++i) {
            check(frame.bytes[6 + i] == body[i], "T envelope carries all 90 body bytes in order");
        }
        check(frame.bytes[96] == 0x04, "T envelope ends its payload with EOT");
        check(frame.bytes[97] == item.checksum_ascii[0] &&
                  frame.bytes[98] == item.checksum_ascii[1],
              "T envelope checksum matches the independent selector-specific ASCII value");
    }
}

} // namespace

int main()
{
    test_full_r63_fixture_literal();
    test_selector_branches_and_direct_envelope();
    std::cout << "All HRI T candidate payload checks passed.\n";
    return EXIT_SUCCESS;
}
