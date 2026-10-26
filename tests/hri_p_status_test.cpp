#include "wirex/hri_p_status.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using wirex::direct_frame::Record;
using namespace wirex::hri_p_status;

int failures = 0;

void check(bool condition, const char* message)
{
    if (condition) return;
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
}

FilterContext short_context(std::uint8_t state_gate)
{
    FilterContext context;
    context.short_state_gate_raw = state_gate;
    return context;
}

FilterContext long_context()
{
    FilterContext context;
    context.compare_dword_raw = std::array<std::uint8_t, 4>{{0x10, 0x20, 0x30, 0x40}};
    context.compare_byte_raw = static_cast<std::uint8_t>(0x50);
    return context;
}

void test_input_validation_and_raw_preservation()
{
    const Record wrong_type{'R', {0x31, 0x32, 0x33, 0x34}};
    const auto wrong_type_result = analyze(wrong_type, StateClass::transceiver, short_context(0x20));
    check(wrong_type_result.status == AnalysisStatus::wrong_record_type,
          "only an already-decoded P record is analyzed");
    check(wrong_type_result.raw_payload == wrong_type.payload,
          "raw payload is preserved when record type is rejected");

    const Record short_payload{'P', {0x31, 0x32, 0x33}};
    check(analyze(short_payload, StateClass::transceiver, short_context(0x20)).status ==
              AnalysisStatus::unsupported_payload_length,
          "three-byte P payload is rejected");
    const Record other_payload{'P', {0x31, 0x32, 0x33, 0x34, 0x35}};
    check(analyze(other_payload, StateClass::transceiver, short_context(0x20)).status ==
              AnalysisStatus::unsupported_payload_length,
          "five-byte P payload is rejected");

    const Record p4{'P', {0x31, 0x32, 0x33, 0x34}};
    const auto invalid_class = analyze(p4, static_cast<StateClass>(0xff), short_context(0x20));
    check(invalid_class.status == AnalysisStatus::invalid_state_class,
          "unknown state class is explicitly rejected");
    check(invalid_class.raw_payload == p4.payload,
          "raw payload remains available when state class is invalid");
}

void test_short_filter_uses_signed_byte_jle_ranges()
{
    const Record record{'P', {0x31, 0x32, '4', 0x34}};

    const auto at_limit = analyze(record, StateClass::transceiver, short_context(0x20));
    check(at_limit.context == ContextDisposition::eligible,
          "signed JLE accepts raw 0x20");
    check(at_limit.internal_digital_ptt_predicate == true,
          "eligible transceiver state returns the internal +0x18 predicate");

    const auto above_limit = analyze(record, StateClass::transceiver, short_context(0x21));
    check(above_limit.context == ContextDisposition::rejected,
          "signed JLE rejects raw 0x21");

    const auto signed_max = analyze(record, StateClass::transceiver, short_context(0x7f));
    check(signed_max.context == ContextDisposition::rejected,
          "signed JLE rejects raw 0x7f");

    for (const std::uint8_t raw : {std::uint8_t{0x80}, std::uint8_t{0xff}}) {
        const auto signed_negative = analyze(record, StateClass::transceiver, short_context(raw));
        check(signed_negative.context == ContextDisposition::eligible,
              "signed JLE accepts raw bytes in the signed-negative range");
    }

    const auto no_context = analyze(record, StateClass::transceiver, FilterContext{});
    check(no_context.context == ContextDisposition::unknown,
          "missing session gate remains unknown");
    check(!no_context.internal_digital_ptt_predicate.has_value(),
          "unknown session gate does not synthesize a virtual-method result");
}

void test_short_state_class_offsets()
{
    const Record record{'P', {0x31, '8', 'A', 'C'}};
    const auto trcv = analyze(record, StateClass::transceiver, short_context(0x20));
    check(trcv.vtable28_input == std::array<std::uint8_t, 4>{{0x31, '8', 'A', 'C'}},
          "four-byte transceiver input keeps all four mapped raw bytes");
    check(trcv.predicate_payload_offset == 2U && trcv.predicate_raw == 'A',
          "transceiver +0x18 tests payload byte 2");
    check(trcv.internal_digital_ptt_predicate == false,
          "transceiver predicate is true only for byte '4'");

    const auto repeater = analyze(record, StateClass::repeater, short_context(0x20));
    check(repeater.predicate_payload_offset == 3U && repeater.predicate_raw == 'C',
          "repeater +0x18 tests payload byte 3");
    check(repeater.internal_digital_ptt_predicate == true,
          "repeater accepts the recovered byte 'C' predicate case");
}

void test_long_filter_sentinel_and_raw_byte_ten()
{
    const Record matching{'P', {0x60, 'a', 'b', 'c', '0', 0x10, 0x20, 0x30, 0x40, 0x50, 0xfe}};
    const auto match = analyze(matching, StateClass::transceiver, long_context());
    check(match.status == AnalysisStatus::analyzed && match.context == ContextDisposition::eligible,
          "eleven-byte record is eligible only when the four-byte and one-byte session fields match");
    check(match.raw_payload == matching.payload && match.raw_payload[10] == 0xfe,
          "eleventh payload byte is preserved without assigning it a new meaning");
    check(match.vtable28_input == std::array<std::uint8_t, 4>{{'a', 'b', 'c', '0'}},
          "eleven-byte input maps payload bytes 1 through 4 to the virtual +0x28 state");
    check(match.predicate_payload_offset == 3U && match.predicate_raw == 'c',
          "eleven-byte transceiver predicate tests payload byte 3");
    check(match.internal_digital_ptt_predicate == false,
          "non-'4' transceiver byte produces false only for the internal predicate");

    auto transceiver_true_payload = matching.payload;
    transceiver_true_payload[3] = '4';
    const auto transceiver_true = analyze(
        Record{'P', transceiver_true_payload}, StateClass::transceiver, long_context());
    check(transceiver_true.internal_digital_ptt_predicate == true,
          "eleven-byte transceiver predicate reads payload byte 3 when session filters pass");

    const auto no_context = analyze(matching, StateClass::transceiver, FilterContext{});
    check(no_context.context == ContextDisposition::unknown,
          "missing long-record session comparison values remain unknown");
    check(!no_context.vtable28_input.has_value() && !no_context.internal_digital_ptt_predicate.has_value(),
          "no virtual-method inputs are reported when the session rejects dispatch as unknown");

    auto bad_word = long_context();
    (*bad_word.compare_dword_raw)[0] ^= 0x01;
    check(analyze(matching, StateClass::transceiver, bad_word).context == ContextDisposition::rejected,
          "mismatched four-byte session value rejects dispatch");
    auto bad_byte = long_context();
    *bad_byte.compare_byte_raw ^= 0x01;
    check(analyze(matching, StateClass::transceiver, bad_byte).context == ContextDisposition::rejected,
          "mismatched fifth session byte rejects dispatch");

    auto sentinel_payload = matching.payload;
    sentinel_payload[3] = 'D';
    const auto sentinel = analyze(Record{'P', sentinel_payload}, StateClass::repeater, long_context());
    check(sentinel.status == AnalysisStatus::reset_sentinel &&
              sentinel.context == ContextDisposition::sentinel,
          "payload byte 3 'D' is reported as the separate no-dispatch sentinel");
    check(!sentinel.internal_digital_ptt_predicate.has_value(),
          "sentinel is not converted into a false digital PTT result");
}

void test_long_repeater_predicate_values()
{
    const std::array<std::uint8_t, 4> accepted{{'4', '8', 'A', 'C'}};
    for (const auto value : accepted) {
        Record payload{'P', {0x60, '0', '1', '2', value, 0x10, 0x20, 0x30, 0x40, 0x50, 0x00}};
        const auto result = analyze(payload, StateClass::repeater, long_context());
        check(result.internal_digital_ptt_predicate == true,
              "repeater returns one for each statically recovered byte value");
    }

    const Record other{'P', {0x60, '0', '1', '2', '5', 0x10, 0x20, 0x30, 0x40, 0x50, 0x00}};
    const auto rejected_value = analyze(other, StateClass::repeater, long_context());
    check(rejected_value.internal_digital_ptt_predicate == false,
          "other repeater byte produces false only for the internal predicate");
}

} // namespace

int main()
{
    test_input_validation_and_raw_preservation();
    test_short_filter_uses_signed_byte_jle_ranges();
    test_short_state_class_offsets();
    test_long_filter_sentinel_and_raw_byte_ten();
    test_long_repeater_predicate_values();

    if (failures != 0) {
        std::cerr << failures << " HRI P-status assertion(s) failed.\n";
        return EXIT_FAILURE;
    }
    std::cout << "HRI P-status tests passed.\n";
    return EXIT_SUCCESS;
}
