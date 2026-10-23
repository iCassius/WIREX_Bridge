#include "wirex/hri_session.hpp"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

using wirex::direct_frame::Record;
using wirex::hri_session::Command;
using wirex::hri_session::CommandKind;
using wirex::hri_session::Config;
using wirex::hri_session::Phase;
using wirex::hri_session::Session;
using wirex::hri_session::StopReason;

int failures = 0;

void check(bool condition, const std::string& message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

std::vector<std::uint8_t> synthetic_y_body()
{
    std::vector<std::uint8_t> body(wirex::hri_session::y_body_size, '0');
    body[5] = '2';
    body[12] = '0';
    return body;
}

std::vector<std::uint8_t> version_payload()
{
    std::vector<std::uint8_t> payload(48, '0');
    payload[0] = 'F';
    payload[1] = 'T';
    payload[2] = 'X';
    payload[3] = '-';
    payload[4] = '1';
    return payload;
}

std::vector<std::uint8_t> encode_record(const Record& record)
{
    const auto result = wirex::direct_frame::encode(record);
    check(static_cast<bool>(result), "synthetic DIRECT record should encode");
    return result.bytes;
}

wirex::hri_session::Update feed_record(Session& session, const Record& record, std::uint64_t now_ms)
{
    const auto frame = encode_record(record);
    return session.feed(frame.data(), frame.size(), now_ms);
}

bool equal_bytes(const std::vector<std::uint8_t>& left, const std::vector<std::uint8_t>& right)
{
    return left == right;
}

void complete_write(Session& session, const Command& command, std::uint64_t now_ms)
{
    const auto result = session.write_completed(command.id, true, now_ms);
    check(result.state.stop_reason == StopReason::none, "successful mock write should keep the session active");
}

void begin_with_valid_version(Session& session, std::uint64_t start_ms, std::uint64_t version_ms)
{
    auto started = session.start(start_ms);
    check(started.commands.size() == 1 && started.commands[0].kind == CommandKind::version_query,
        "start should request exactly one V query");
    if (started.commands.empty()) return;
    complete_write(session, started.commands[0], start_ms);
    const auto response = encode_record(Record{'V', version_payload()});
    const auto received = session.feed(response.data(), response.size(), version_ms);
    check(received.state.version_response_validated, "valid V/48 with FTX-1 prefix should be accepted");
}

void test_template_gate_and_fixed_version_request()
{
    Session invalid_length(std::vector<std::uint8_t>(99, '0'));
    auto rejected = invalid_length.start(10);
    check(rejected.commands.empty() && rejected.state.phase == Phase::stopped &&
        rejected.state.stop_reason == StopReason::invalid_y_template,
        "non-100-byte Y body should stop before the V request");

    auto wrong_mode = synthetic_y_body();
    wrong_mode[5] = '1';
    Session invalid_mode(std::move(wrong_mode));
    rejected = invalid_mode.start(10);
    check(rejected.commands.empty() && rejected.state.stop_reason == StopReason::invalid_y_template,
        "Y body with byte 5 other than ASCII 2 should stop before the V request");

    Session session(synthetic_y_body());
    const auto started = session.start(100);
    const std::vector<std::uint8_t> v_expected{0x01, 0x56, 0x30, 0x30, 0x30, 0x30, 0x04, 0x31, 0x42};
    check(started.commands.size() == 1 && equal_bytes(started.commands[0].frame, v_expected),
        "start should emit the fixed nine-byte V0000 request once");
    check(session.start(101).commands.empty(), "a second start must not emit another V query");
}

void test_version_gate_and_periodic_y()
{
    Session session(synthetic_y_body());
    const auto start = session.start(0);
    complete_write(session, start.commands.front(), 0);

    auto bad_model_payload = version_payload();
    bad_model_payload[0] = 'X';
    auto mismatch = feed_record(session, Record{'V', std::move(bad_model_payload)}, 10);
    check(mismatch.state.phase == Phase::stopped && mismatch.state.stop_reason == StopReason::version_mismatch,
        "valid envelope with a different model prefix should stop the session");

    Session valid(synthetic_y_body());
    begin_with_valid_version(valid, 0, 100);
    check(valid.tick(1099).commands.empty(), "Y should wait one second after a valid V response");
    auto first_y = valid.tick(1100);
    check(first_y.commands.size() == 1 && first_y.commands[0].kind == CommandKind::y_record,
        "first Y request should be due at one second");
    if (first_y.commands.empty()) return;
    const auto decoded_y = wirex::direct_frame::decode(first_y.commands[0].frame.data(), first_y.commands[0].frame.size());
    check(decoded_y && decoded_y.record.type == 'Y' && decoded_y.record.payload == synthetic_y_body(),
        "Y request should contain the caller-supplied synthetic 100-byte body exactly");
    complete_write(valid, first_y.commands[0], 1200);
    check(valid.tick(2199).commands.empty(), "next Y period should start from completed write time");
    const auto second_y = valid.tick(2200);
    check(second_y.commands.size() == 1 && second_y.commands[0].kind == CommandKind::y_record,
        "next Y should be due one second after the completed write");
}

void test_y_ack_x_ack_and_conditional_next_y_byte()
{
    Session session(synthetic_y_body());
    begin_with_valid_version(session, 0, 100);

    auto early_y0 = feed_record(session, Record{'Y', {}}, 200);
    check(early_y0.state.counters.y_zero_ack_received == 0 && !early_y0.state.may_start_audio_route,
        "Y0 before a completed Y write must not open the audio-route gate");

    const auto y = session.tick(1100);
    check(y.commands.size() == 1, "Y command should be available for the mock write");
    if (y.commands.empty()) return;
    complete_write(session, y.commands[0], 1110);
    auto y0 = feed_record(session, Record{'Y', {}}, 1120);
    check(y0.state.counters.y_zero_ack_received == 1 && y0.state.may_start_audio_route,
        "valid Y0 after a completed Y write should open the bounded audio-route gate");
    check(!y0.state.limited_exchange_observed,
        "one successful Y write and Y0 response before the window ends is not a final exchange result");

    std::vector<std::uint8_t> x_body(100, '0');
    x_body[11] = '0';
    x_body[12] = '7';
    auto x = feed_record(session, Record{'X', x_body}, 1130);
    const std::vector<std::uint8_t> x0_expected{0x01, 0x58, 0x30, 0x30, 0x30, 0x30, 0x04, 0x31, 0x44};
    check(x.state.counters.x100_received == 1 && x.state.counters.x0_write_requested == 1,
        "a complete X/100 after Y should count and request one X/0 acknowledgement");
    check(x.state.counters.x_copy_branch_count == 1 && x.state.counters.y_byte12_changed_count == 1,
        "the eligible X branch and an actual next-Y offset-12 change should be counted separately");
    check(x.commands.size() == 1 && x.commands[0].kind == CommandKind::x_ack &&
        equal_bytes(x.commands[0].frame, x0_expected),
        "X acknowledgement should be the fixed empty-payload X/0 envelope");
    if (!x.commands.empty()) complete_write(session, x.commands[0], 1140);
    check(session.snapshot().counters.x0_write_completed == 1,
        "X acknowledgement completion should be counted separately from request");

    const auto next_y = session.tick(2110);
    check(next_y.commands.size() == 1, "next Y should be schedulable after the X acknowledgement");
    if (next_y.commands.empty()) return;
    const auto decoded = wirex::direct_frame::decode(next_y.commands[0].frame.data(), next_y.commands[0].frame.size());
    check(decoded && decoded.record.payload.size() == 100 && decoded.record.payload[12] == '7',
        "X body byte 12 should copy to the next Y body byte 12 when X byte 11 is not ASCII 1");

    Session other_branch(synthetic_y_body());
    begin_with_valid_version(other_branch, 0, 100);
    const auto branch_y = other_branch.tick(1100);
    if (branch_y.commands.empty()) {
        check(false, "second session should produce its first Y");
        return;
    }
    complete_write(other_branch, branch_y.commands[0], 1110);
    std::vector<std::uint8_t> x_other(100, '0');
    x_other[11] = '1';
    x_other[12] = '9';
    auto x_other_result = feed_record(other_branch, Record{'X', x_other}, 1120);
    check(x_other_result.commands.size() == 1, "X byte-11 alternate branch should still receive X/0 acknowledgement");
    check(x_other_result.state.counters.x_copy_branch_count == 0 &&
        x_other_result.state.counters.y_byte12_changed_count == 0,
        "the alternate X branch should not count a copy or a next-Y byte change");
    check(x_other_result.state.counters.unsupported_config_import_records == 1,
        "X byte-11 ASCII 1 should be counted as a configuration import the prototype does not implement");
    if (!x_other_result.commands.empty()) complete_write(other_branch, x_other_result.commands[0], 1130);
    const auto unchanged_y = other_branch.tick(2110);
    if (unchanged_y.commands.empty()) {
        check(false, "alternate branch should still schedule the next Y");
        return;
    }
    const auto unchanged_decoded = wirex::direct_frame::decode(unchanged_y.commands[0].frame.data(), unchanged_y.commands[0].frame.size());
    check(unchanged_decoded && unchanged_decoded.record.payload[12] == '0',
        "X byte 12 should not be copied when X byte 11 is ASCII 1");
}

void test_extended_hri_bounds()
{
    check(wirex::hri_session::max_window_ms == 120000 &&
        wirex::hri_session::max_y_write_calls == 120 &&
        wirex::hri_session::max_x_ack_write_calls == 256 &&
        wirex::hri_session::max_receive_bytes == 256 * 1024 &&
        wirex::hri_session::max_transmit_bytes == 32 * 1024 &&
        wirex::hri_session::max_valid_records == 1024,
        "HRI-only duration and protocol budgets should use the approved bounded 120-second envelope");

    Session maximum_window(synthetic_y_body(), Config{wirex::hri_session::max_window_ms});
    const auto start = maximum_window.start(0);
    check(start.commands.size() == 1 && start.state.phase == Phase::awaiting_version_write,
        "the full 120-second session window should be accepted");
    const auto expired = maximum_window.tick(wirex::hri_session::max_window_ms);
    check(expired.state.phase == Phase::stopped && expired.state.stop_reason == StopReason::deadline,
        "the maximum HRI window should stop at its exact deadline");

    Session overlong_window(synthetic_y_body(), Config{wirex::hri_session::max_window_ms + 1});
    const auto rejected = overlong_window.start(0);
    check(rejected.commands.empty() && rejected.state.stop_reason == StopReason::invalid_configuration,
        "an HRI window above 120 seconds should be rejected before any command is queued");

    Session over_receive(synthetic_y_body());
    const auto receive_start = over_receive.start(0);
    if (!receive_start.commands.empty()) complete_write(over_receive, receive_start.commands[0], 0);
    std::vector<std::uint8_t> too_many_bytes(wirex::hri_session::max_receive_bytes + 1, 0);
    const auto receive_result = over_receive.feed(too_many_bytes.data(), too_many_bytes.size(), 1);
    check(receive_result.state.stop_reason == StopReason::receive_limit && receive_result.commands.empty(),
        "bytes beyond the 256-KiB HRI receive budget should fail closed");

    Session over_records(synthetic_y_body());
    begin_with_valid_version(over_records, 0, 10);
    std::vector<std::uint8_t> record_batch;
    for (std::uint32_t i = 0; i < wirex::hri_session::max_valid_records + 1; ++i) {
        const auto frame = encode_record(Record{'Q', {}});
        record_batch.insert(record_batch.end(), frame.begin(), frame.end());
    }
    const auto record_result = over_records.feed(record_batch.data(), record_batch.size(), 20);
    check(record_result.state.stop_reason == StopReason::record_limit && record_result.commands.empty(),
        "more than 1024 valid records in one bounded session should fail closed");
}

void test_fail_closed_no_exit_frames_and_deadlines()
{
    Session no_version(synthetic_y_body(), Config{1000});
    const auto start = no_version.start(0);
    complete_write(no_version, start.commands.front(), 0);
    const auto timed_out = no_version.tick(1000);
    check(timed_out.commands.empty() && timed_out.state.phase == Phase::stopped &&
        timed_out.state.stop_reason == StopReason::deadline,
        "no V response at the bounded deadline should stop without an exit frame");

    Session late_version(synthetic_y_body());
    const auto late_start = late_version.start(0);
    complete_write(late_version, late_start.commands.front(), 0);
    const auto late_v_frame = encode_record(Record{'V', version_payload()});
    const auto late_v = late_version.feed(late_v_frame.data(), late_v_frame.size(),
        wirex::hri_session::version_response_timeout_ms);
    check(late_v.state.stop_reason == StopReason::version_timeout &&
        !late_v.state.version_response_validated && late_v.commands.empty(),
        "V arriving at its 2500 ms deadline must not revive the session");

    Session bad_frame(synthetic_y_body());
    const auto bad_start = bad_frame.start(0);
    complete_write(bad_frame, bad_start.commands.front(), 0);
    auto bad_v = encode_record(Record{'V', version_payload()});
    bad_v.back() = bad_v.back() == '0' ? '1' : '0';
    auto rejected = bad_frame.feed(bad_v.data(), bad_v.size(), 10);
    check(rejected.commands.empty() && rejected.state.stop_reason == StopReason::malformed_record,
        "bad SUM should stop without generating any follow-on frame");

    Session incomplete(synthetic_y_body(), Config{1000});
    const auto incomplete_start = incomplete.start(0);
    complete_write(incomplete, incomplete_start.commands.front(), 0);
    const auto prefix = encode_record(Record{'V', version_payload()});
    (void)incomplete.feed(prefix.data(), 5, 100);
    const auto partial_end = incomplete.tick(1000);
    check(partial_end.commands.empty() && partial_end.state.stop_reason == StopReason::incomplete_record,
        "a partial record at the deadline should stop without completing or replying to it");

    Session ack_timeout(synthetic_y_body());
    begin_with_valid_version(ack_timeout, 0, 100);
    const auto y = ack_timeout.tick(1100);
    if (y.commands.empty()) {
        check(false, "ack timeout case should produce Y");
        return;
    }
    complete_write(ack_timeout, y.commands[0], 1100);
    const auto no_ack = ack_timeout.tick(4100);
    check(no_ack.commands.empty() && no_ack.state.stop_reason == StopReason::y_ack_timeout,
        "missing Y0 by the bounded acknowledgement deadline should stop without another frame");

    Session late_y0(synthetic_y_body());
    begin_with_valid_version(late_y0, 0, 100);
    const auto late_y0_y = late_y0.tick(1100);
    if (!late_y0_y.commands.empty()) {
        complete_write(late_y0, late_y0_y.commands.front(), 1100);
        const auto y0_frame = encode_record(Record{'Y', {}});
        const auto expired_y0 = late_y0.feed(y0_frame.data(), y0_frame.size(), 4100);
        check(expired_y0.state.stop_reason == StopReason::y_ack_timeout &&
            expired_y0.state.counters.y_zero_ack_received == 0 && !expired_y0.state.may_start_audio_route,
            "Y0 arriving at the 3000 ms acknowledgement deadline must not open or revive the route");
    } else {
        check(false, "late Y0 case should produce Y");
    }

    Session discarded_action(synthetic_y_body());
    begin_with_valid_version(discarded_action, 0, 100);
    const auto discard_y = discarded_action.tick(1100);
    if (!discard_y.commands.empty()) {
        complete_write(discarded_action, discard_y.commands.front(), 1100);
        auto x_frame = encode_record(Record{'X', std::vector<std::uint8_t>(100, '0')});
        auto bad_following = encode_record(Record{'Y', {}});
        bad_following.back() = bad_following.back() == '0' ? '1' : '0';
        x_frame.insert(x_frame.end(), bad_following.begin(), bad_following.end());
        const auto batch = discarded_action.feed(x_frame.data(), x_frame.size(), 1120);
        check(batch.state.stop_reason == StopReason::malformed_record && batch.commands.empty() &&
            batch.state.counters.x0_write_requested == 0,
            "a malformed record later in one read batch must not leave an earlier action command to execute");
    } else {
        check(false, "discarded-action case should produce Y");
    }

    Session unexpected_version_after_action(synthetic_y_body());
    begin_with_valid_version(unexpected_version_after_action, 0, 100);
    const auto action_y = unexpected_version_after_action.tick(1100);
    if (!action_y.commands.empty()) {
        complete_write(unexpected_version_after_action, action_y.commands.front(), 1100);
        auto x_before_v = encode_record(Record{'X', std::vector<std::uint8_t>(100, '0')});
        const auto repeated_v = encode_record(Record{'V', version_payload()});
        x_before_v.insert(x_before_v.end(), repeated_v.begin(), repeated_v.end());
        const auto batch = unexpected_version_after_action.feed(x_before_v.data(), x_before_v.size(), 1120);
        check(batch.state.stop_reason == StopReason::unexpected_version_record && batch.commands.empty(),
            "a later unexpected V record in a batch must discard any earlier queued X acknowledgement");
    } else {
        check(false, "unexpected-version case should produce Y");
    }

    Session cancelled(synthetic_y_body());
    const auto cancel_start = cancelled.start(0);
    complete_write(cancelled, cancel_start.commands.front(), 0);
    const auto cancel = cancelled.cancel();
    check(cancel.commands.empty() && cancel.state.stop_reason == StopReason::cancelled,
        "cancellation should stop without emitting an exit record");

    Session report_failed(synthetic_y_body());
    const auto report_start = report_failed.start(0);
    complete_write(report_failed, report_start.commands.front(), 0);
    const auto report_abort = report_failed.abort(StopReason::report_failure);
    check(report_abort.state.phase == Phase::stopped && report_abort.state.stop_reason == StopReason::report_failure,
        "metadata persistence failure should stop with its own failure reason");
}

void test_limited_exchange_requires_version_y_and_y0()
{
    Session session(synthetic_y_body(), Config{3000});
    begin_with_valid_version(session, 0, 100);
    const auto y = session.tick(1100);
    if (y.commands.empty()) {
        check(false, "limited exchange should issue Y after the initial period");
        return;
    }
    complete_write(session, y.commands.front(), 1100);
    const auto y0 = feed_record(session, Record{'Y', {}}, 1200);
    check(!y0.state.limited_exchange_observed, "Y0 before the window ends is not yet a completed bounded observation");
    const auto end = session.tick(3000);
    check(end.state.stop_reason == StopReason::deadline && end.state.limited_exchange_observed,
        "bounded result should require a validated V response, completed Y write and Y0 response");

    Session write_only(synthetic_y_body(), Config{3000});
    begin_with_valid_version(write_only, 0, 100);
    const auto only_y = write_only.tick(1100);
    if (only_y.commands.empty()) {
        check(false, "write-only case should issue Y");
        return;
    }
    complete_write(write_only, only_y.commands.front(), 1100);
    const auto no_ack_end = write_only.tick(3000);
    check(!no_ack_end.state.limited_exchange_observed,
        "a completed write without a Y0 response must never report a limited exchange");
}

} // namespace

int main()
{
    test_template_gate_and_fixed_version_request();
    test_version_gate_and_periodic_y();
    test_y_ack_x_ack_and_conditional_next_y_byte();
    test_extended_hri_bounds();
    test_fail_closed_no_exit_frames_and_deadlines();
    test_limited_exchange_requires_version_y_and_y0();
    if (failures != 0) {
        std::cerr << failures << " HRI session check(s) failed.\n";
        return 1;
    }
    std::cout << "All pure HRI session checks passed.\n";
    return 0;
}
