#include "wirex/approved_hri_y_template.hpp"
#include "wirex/hri_y_body.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <string>

namespace {

int failures = 0;
int assertions = 0;

void check(bool condition, const std::string& message)
{
    ++assertions;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

std::string power_text(const std::array<std::uint8_t, wirex::hri_y::body_size>& body)
{
    return std::string(reinterpret_cast<const char*>(body.data() + wirex::hri_y::tx_power_offset),
                       wirex::hri_y::tx_power_length);
}

void test_default_template_and_modes()
{
    const auto result = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
                                             wirex::hri_y::DynamicFields{}, false);
    check(result.ok, "default DIRECT body should build");
    check(result.body == wirex::approved_resources::hri_y_template,
          "default 250 deciwatts DIRECT body must equal the approved template");

    const auto ap = wirex::hri_y::build(wirex::approved_resources::hri_y_template_ap,
                                        wirex::hri_y::DynamicFields{}, true);
    check(ap.ok && ap.body[wirex::hri_y::mode_offset] == '1',
          "AP mode should encode ASCII 1 at byte 5");
}

void test_power_encoding()
{
    struct Case { std::uint16_t value; const char* text; };
    constexpr Case cases[]{{50U, "0050"}, {100U, "0100"}, {150U, "0150"},
                           {250U, "0250"}, {500U, "0500"}};
    for (const auto& test : cases) {
        const auto result = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
            wirex::hri_y::DynamicFields{test.value}, false);
        check(result.ok && power_text(result.body) == test.text,
              std::string("power should encode as ") + test.text);
    }
}

void test_channel_encoding()
{
    struct Case { std::uint32_t hz; const char* text; };
    constexpr Case cases[]{{145100000U, "0145100000"}, {145200000U, "0145200000"},
        {144000000U, "0144000000"}, {148000000U, "0148000000"},
        {430000000U, "0430000000"}, {439995000U, "0439995000"}, {440000000U, "0440000000"}};
    for (const auto& test : cases) {
        for (const auto mode : {wirex::hri_y::LchMode::fm, wirex::hri_y::LchMode::c4fm_dn}) {
            const auto result = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
                wirex::hri_y::DynamicFields{250U, test.hz, mode}, false);
            check(result.ok && std::string(result.body.begin() + wirex::hri_y::lch_frequency_offset,
                  result.body.begin() + wirex::hri_y::lch_frequency_offset + wirex::hri_y::lch_frequency_length) == test.text &&
                  result.body[wirex::hri_y::lch_mode_offset] == (mode == wirex::hri_y::LchMode::fm ? '1' : '2'),
                  std::string("channel encoding ") + test.text);
        }
    }
    for (const auto hz : {143999000U, 148001000U, 145100500U, 0U, 439999500U}) {
        const auto result = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
            wirex::hri_y::DynamicFields{250U, hz, wirex::hri_y::LchMode::fm}, false);
        check(!result.ok && result.error == "invalid_hri_y_frequency", "invalid frequency rejected");
    }
    const auto bad_mode = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
        wirex::hri_y::DynamicFields{250U, 145100000U, static_cast<wirex::hri_y::LchMode>(99)}, false);
    check(!bad_mode.ok && bad_mode.error == "invalid_hri_y_mode", "invalid mode rejected");
}

void test_rejections_and_whitelist()
{
    for (const auto value : {std::uint16_t{0U}, std::uint16_t{49U}, std::uint16_t{55U},
                              std::uint16_t{510U}}) {
        const auto result = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
            wirex::hri_y::DynamicFields{value}, false);
        check(!result.ok, "out-of-range or non-10-deciewatt power must be rejected");
    }

    const auto valid = wirex::hri_y::build(wirex::approved_resources::hri_y_template,
                                           wirex::hri_y::DynamicFields{250U}, false);
    auto changed = valid.body;
    for (std::size_t offset = 0U; offset < valid.body.size(); ++offset) {
        if (offset == 0x05U || offset == 0x0CU || offset == 0x0EU ||
            (offset >= 0x10U && offset <= 0x19U) || (offset >= 0x2FU && offset <= 0x32U)) continue;
        changed = valid.body;
        changed[offset] ^= 1U;
        check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                      changed.data(), changed.size(), false),
              "non-whitelisted byte rejected at " + std::to_string(offset));
    }
    changed = valid.body;
    changed[0x10U] = 'x';
    check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                  changed.data(), changed.size(), false),
          "non-digit frequency must be rejected");
    for (const auto offset : {0x1AU, 0x25U}) {
        changed = valid.body;
        changed[offset] = '?';
        check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                      changed.data(), changed.size(), false),
              "offset and squelch outside the whitelist must be rejected");
    }
    changed = valid.body;
    changed[wirex::hri_y::lch_mode_offset] = '0';
    check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                  changed.data(), changed.size(), false), "invalid mode text rejected");
    for (const std::string value : {"9999999999", "0143999000", "0145100500", "0440001000"}) {
        changed = valid.body;
        std::copy(value.begin(), value.end(), changed.begin() + wirex::hri_y::lch_frequency_offset);
        check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                      changed.data(), changed.size(), false), "invalid frequency text " + value);
    }
    changed = valid.body;
    changed[0x5BU] = '9';
    check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                  changed.data(), changed.size(), false),
          "B-channel power outside the whitelist must be rejected");
    changed = valid.body;
    changed[0x00U] = '9';
    check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                  changed.data(), changed.size(), false),
          "station identity outside the whitelist must be rejected");
    changed = valid.body;
    changed[wirex::hri_y::ptt_mirror_offset] = '2';
    check(wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                 changed.data(), changed.size(), false),
          "PTT mirror ASCII 2 should be accepted");
    changed[wirex::hri_y::ptt_mirror_offset] = '?';
    check(wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                 changed.data(), changed.size(), false),
          "unrecognized X mirror bytes are preserved as the session already permits");
    for (const std::string value : {"0000", "0049", "0055", "0510", "0x50"}) {
        changed = valid.body;
        std::copy(value.begin(), value.end(), changed.begin() + wirex::hri_y::tx_power_offset);
        check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                      changed.data(), changed.size(), false),
              "validator rejects invalid power text " + value);
    }
    check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template, nullptr, 100U, false),
          "null body is rejected");
    check(!wirex::hri_y::validate(wirex::approved_resources::hri_y_template,
                                  valid.body.data(), 99U, false), "short body is rejected");
}

} // namespace

int main()
{
    test_default_template_and_modes();
    test_power_encoding();
    test_channel_encoding();
    test_rejections_and_whitelist();
    if (failures != 0) {
        std::cerr << failures << " HRI Y body check(s) failed.\n";
        return 1;
    }
    std::cout << "PASS: " << assertions << " HRI Y body assertions\n";
    return 0;
}
