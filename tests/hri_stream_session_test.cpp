#include "wirex/direct_frame.hpp"
#include "wirex/hri_stream_session.hpp"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void check(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

wirex::hri_stream_session::CandidateFrame candidate(bool start)
{
    std::vector<std::uint8_t> payload(90U, static_cast<std::uint8_t>('0'));
    payload[0] = static_cast<std::uint8_t>(start ? '3' : '0');
    const auto frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'), std::move(payload)});
    check(static_cast<bool>(frame), "T candidate encoding failed");
    return frame.bytes;
}

std::vector<std::uint8_t> t_record(std::size_t payload_size)
{
    std::vector<std::uint8_t> payload(payload_size, static_cast<std::uint8_t>('x'));
    const auto frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'), std::move(payload)});
    check(static_cast<bool>(frame), "T response encoding failed");
    return frame.bytes;
}

void complete_write(wirex::hri_stream_session::Session& session,
                    std::uint64_t write_id, std::uint64_t now_ms)
{
    const auto attempted = session.write_attempted(write_id, now_ms);
    check(attempted.error == wirex::hri_stream_session::Error::none, "write attempt rejected");
    const auto completed = session.write_completed(write_id, true, now_ms + 1U);
    check(completed.error == wirex::hri_stream_session::Error::none, "write completion rejected");
}

std::uint64_t write_id(const wirex::hri_stream_session::Update& update,
                       wirex::hri_stream_session::ActionKind kind)
{
    for (const auto& action : update.actions) {
        if (action.kind == kind) return action.write_id;
    }
    throw std::runtime_error("expected serial write action was not queued");
}

void test_streamed_call_waits_for_audio_tail_before_t0()
{
    using namespace wirex::hri_stream_session;
    Session session(candidate(true), candidate(false));
    auto update = session.begin_call(10U);
    if (update.state.phase != Phase::start_write_pending) {
        std::cerr << "begin_call state=" << static_cast<int>(update.state.phase)
                  << " reason=" << static_cast<int>(update.state.reason)
                  << " actions=" << update.actions.size() << '\n';
    }
    check(update.state.phase == Phase::start_write_pending && update.actions.size() == 1U &&
          update.actions[0].kind == ActionKind::write_start_candidate,
          "begin_call did not request one T3 write");
    complete_write(session, update.actions[0].write_id, 11U);

    const auto response = t_record(7U);
    update = session.feed(response.data(), response.size(), 13U);
    check(update.state.phase == Phase::playing && update.state.playback_permitted &&
          update.state.start_t_record_observed && update.actions.size() == 1U &&
          update.actions[0].kind == ActionKind::playback_permitted,
          "valid T record did not open playback gate");
    check(update.state.radio_state_unknown, "HRI observation changed radio state certainty");

    update = session.network_ended(20U);
    check(update.state.phase == Phase::draining && update.actions.empty(),
          "network EOT stopped playback before the buffered tail drained");
    update = session.playback_drained(30U);
    check(update.state.phase == Phase::stop_write_pending && update.actions.size() == 1U &&
          update.actions[0].kind == ActionKind::write_stop_candidate,
          "T0 was not deferred until playback drain");
    complete_write(session, update.actions[0].write_id, 31U);
    const auto stop_response = t_record(0U);
    update = session.feed(stop_response.data(), stop_response.size(), 34U);
    check(update.state.phase == Phase::idle && update.state.stop_t_record_observed &&
          update.state.completed_calls == 1U,
          "observed T record did not complete the first call");

    update = session.begin_call(40U);
    check(update.state.phase == Phase::start_write_pending,
          "coordinator did not accept a later call after bounded T0 completion");
}

void test_start_timeout_sends_one_bounded_t0()
{
    using namespace wirex::hri_stream_session;
    Session session(candidate(true), candidate(false));
    auto update = session.begin_call(0U);
    const auto start_id = update.actions.front().write_id;
    complete_write(session, start_id, 1U);
    update = session.tick(default_start_record_timeout_ms + 2U);
    check(update.state.reason == Reason::start_record_timeout &&
          update.state.phase == Phase::stop_write_pending &&
          write_id(update, ActionKind::write_stop_candidate) == 2U,
          "missing T3 observation did not schedule bounded T0 cleanup");
    complete_write(session, write_id(update, ActionKind::write_stop_candidate), default_start_record_timeout_ms + 3U);

    update = session.tick(default_start_record_timeout_ms + default_stop_record_timeout_ms + 4U);
    check(update.state.phase == Phase::idle && update.state.completed_calls == 1U &&
          !update.state.stop_t_record_observed && update.state.reason == Reason::start_record_timeout &&
          update.state.radio_state_unknown,
          "missing T0 observation incorrectly blocked the listener or claimed radio state");
}

void test_cancel_before_and_after_t3_attempt()
{
    using namespace wirex::hri_stream_session;
    Session session(candidate(true), candidate(false));
    auto update = session.begin_call(0U);
    update = session.cancel(Reason::cancelled, 1U);
    check(update.state.phase == Phase::idle && update.state.completed_calls == 1U,
          "cancel before T3 attempt did not close without T0");
    for (const auto& action : update.actions) {
        check(action.kind != ActionKind::write_stop_candidate,
              "cancel before any T3 write attempted an unnecessary T0");
    }

    update = session.begin_call(2U);
    const auto start_id = update.actions.front().write_id;
    complete_write(session, start_id, 3U);
    update = session.cancel(Reason::network_lost, 5U);
    check(update.state.phase == Phase::stop_write_pending && update.state.reason == Reason::network_lost,
          "network loss after T3 did not schedule stop cleanup");
    std::size_t stop_requests = 0U;
    for (const auto& action : update.actions) {
        if (action.kind == ActionKind::write_stop_candidate) ++stop_requests;
    }
    const auto again = session.cancel(Reason::network_lost, 6U);
    for (const auto& action : again.actions) {
        if (action.kind == ActionKind::write_stop_candidate) ++stop_requests;
    }
    check(stop_requests == 1U, "repeated cancellation queued duplicate T0 writes");
}

void test_t0_observation_timeout_allows_reentry()
{
    using namespace wirex::hri_stream_session;
    Session session(candidate(true), candidate(false));
    auto update = session.begin_call(0U);
    complete_write(session, update.actions.front().write_id, 1U);
    const auto response = t_record(90U);
    update = session.feed(response.data(), response.size(), 2U);
    check(update.state.phase == Phase::playing, "T3 observation was not recognized");
    (void)session.network_ended(3U);
    update = session.playback_drained(4U);
    complete_write(session, write_id(update, ActionKind::write_stop_candidate), 5U);

    update = session.tick(6U + default_stop_record_timeout_ms);
    check(update.state.phase == Phase::idle && update.state.reason == Reason::stop_record_timeout &&
          !update.state.stop_t_record_observed,
          "missing T0 observation was reported as a strict acknowledgement failure");
    update = session.begin_call(1000U);
    check(update.state.phase == Phase::start_write_pending && update.state.completed_calls == 1U,
          "bounded stop observation timeout did not allow the listener to reenter");
}

void test_short_call_waits_for_late_t3_before_draining()
{
    using namespace wirex::hri_stream_session;
    Session session(candidate(true), candidate(false));
    auto update = session.begin_call(0U);
    const auto start_id = write_id(update, ActionKind::write_start_candidate);
    update = session.network_ended(300U);
    check(update.state.phase == Phase::start_write_pending && update.actions.empty() &&
          update.state.completed_calls == 0U,
          "early EOT discarded buffered speech before the T3 write was attempted");

    complete_write(session, start_id, 1000U);
    const auto start_response = t_record(21U);
    update = session.feed(start_response.data(), start_response.size(), 1003U);
    check(update.state.phase == Phase::draining && update.state.playback_permitted &&
          update.state.start_t_record_observed && update.actions.size() == 1U &&
          update.actions.front().kind == ActionKind::playback_permitted,
          "late T3 observation did not permit the buffered short call to play");

    update = session.playback_drained(1400U);
    check(update.state.phase == Phase::stop_write_pending &&
          write_id(update, ActionKind::write_stop_candidate) == 2U,
          "short-call PCM drain did not schedule exactly one T0");
    complete_write(session, 2U, 1401U);
    const auto stop_response = t_record(3U);
    update = session.feed(stop_response.data(), stop_response.size(), 1403U);
    check(update.state.phase == Phase::idle && update.state.stop_t_record_observed &&
          update.state.completed_calls == 1U,
          "short-call T0 did not finish after playback drained");
}

void test_malformed_and_wrong_phase_records_are_not_acknowledgements()
{
    using namespace wirex::hri_stream_session;
    Session session(candidate(true), candidate(false));
    auto update = session.begin_call(0U);
    const auto response = t_record(4U);
    update = session.feed(response.data(), response.size(), 1U);
    check(update.state.phase == Phase::start_write_pending && update.state.unmatched_t_records == 1U,
          "out-of-phase T record was treated as a start observation");

    auto malformed = t_record(4U);
    malformed.back() = static_cast<std::uint8_t>(malformed.back() == '0' ? '1' : '0');
    update = session.feed(malformed.data(), malformed.size(), 2U);
    check(update.state.malformed_records != 0U && update.state.radio_state_unknown,
          "malformed serial data changed readiness or radio state");
}

} // namespace

int main()
{
    try {
        test_streamed_call_waits_for_audio_tail_before_t0();
        test_start_timeout_sends_one_bounded_t0();
        test_cancel_before_and_after_t3_attempt();
        test_t0_observation_timeout_allows_reentry();
        test_short_call_waits_for_late_t3_before_draining();
        test_malformed_and_wrong_phase_records_are_not_acknowledgements();
        std::cout << "All HRI streaming session checks passed.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "HRI streaming session test failed: " << error.what() << '\n';
        return 1;
    }
}
