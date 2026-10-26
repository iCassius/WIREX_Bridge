#include "wirex/hri_lcd_identity_candidate.hpp"

#include "wirex/hri_call_header.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <string_view>

namespace {

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void verify_one_field(
    wirex::hri_lcd_identity_candidate::CallsignField field,
    std::size_t header_offset)
{
    using namespace wirex::hri_lcd_identity_candidate;
    const auto base = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    const auto result = overlay_single_callsign(base, field, "N0CALL/P");
    check(static_cast<bool>(result), "one explicit callsign builds an offline candidate");

    auto expected = base;
    constexpr std::string_view padded = "N0CALL/P  ";
    constexpr std::size_t body_field_offset = wirex::hri_call_header::t_body_header_offset;
    for (std::size_t index = 0; index < padded.size(); ++index) {
        expected[body_field_offset + header_offset + index] =
            static_cast<unsigned char>(padded[index]);
    }
    check(result.body == expected, "the output changes exactly the selected ten-byte field");
    check(result.body.size() == 90U, "the mode4 candidate retains its 90-byte length");
    check(result.body[wirex::hri_call_header::t_body_mode_offset] == '4',
          "the T start body remains on the existing mode4 PCM path");
    check(result.body[75] == '0' && result.body[80] == 'F',
          "the empty AMBE placeholder remains unchanged");
    check(result.body[81] == '*' && result.body[85] == '*' && result.body[86] == '3',
          "the five-star separator and existing 3033 tail remain unchanged");
}

void test_each_known_field_offset()
{
    verify_one_field(wirex::hri_lcd_identity_candidate::CallsignField::destination,
                     wirex::hri_call_header::destination_callsign_offset);
    verify_one_field(wirex::hri_lcd_identity_candidate::CallsignField::source,
                     wirex::hri_call_header::source_callsign_offset);
    verify_one_field(wirex::hri_lcd_identity_candidate::CallsignField::local,
                     wirex::hri_call_header::local_callsign_offset);
}

void test_input_rejections()
{
    using namespace wirex::hri_lcd_identity_candidate;
    const auto base = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    check(overlay_single_callsign(base, static_cast<CallsignField>(255), "N0CALL").error == Error::invalid_field,
          "unknown field selectors are rejected");
    check(overlay_single_callsign(base, CallsignField::source, "").error == Error::invalid_callsign,
          "an empty callsign is rejected");
    check(overlay_single_callsign(base, CallsignField::source, "123456789").error == Error::invalid_callsign,
          "callsigns longer than eight ASCII characters are rejected");
    check(overlay_single_callsign(base, CallsignField::source, "4611355").error == Error::invalid_callsign,
          "numeric DMR source IDs cannot be substituted for callsigns");
    check(overlay_single_callsign(base, CallsignField::source, "A B").error == Error::invalid_callsign,
          "input spaces are rejected because the builder adds its own right padding");
    check(overlay_single_callsign(base, CallsignField::source, std::string_view("A\x80", 2)).error == Error::invalid_callsign,
          "non-ASCII callsign bytes are rejected");

    auto stop_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(0, 1, 9U);
    check(overlay_single_callsign(stop_body, CallsignField::source, "N0CALL").error == Error::invalid_base_body,
          "the helper rejects a stop T body so it cannot alter the existing T0 cleanup");
}

} // namespace

int main()
{
    test_each_known_field_offset();
    test_input_rejections();
    std::cout << "All offline HRI LCD identity candidate checks passed.\n";
    return EXIT_SUCCESS;
}
