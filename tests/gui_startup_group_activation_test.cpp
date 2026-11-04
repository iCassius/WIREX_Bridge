#include "../src/gui/startup_group_activation.hpp"

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using namespace std::chrono_literals;
using wirex::dmr_call::CallKind;
using wirex::dmr_call::Slot;
using wirex::engine::CommandStatus;
using wirex::gui::services::ChannelEntry;
using wirex::gui::StartupGroupActivation;

int assertions = 0;

void check(bool condition, const char* message)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void test_startup_plan_filters_and_deduplicates()
{
    StartupGroupActivation activation;
    const std::vector<ChannelEntry> channels{
        {91U, CallKind::group, Slot::ts2, ""},
        {460997U, CallKind::private_call, Slot::ts2, ""},
        {4000U, CallKind::group, Slot::ts1, ""},
        {91U, CallKind::group, Slot::ts2, "duplicate"},
        {91U, CallKind::group, Slot::ts1, "other slot"},
        {46001U, CallKind::group, Slot::ts2, ""},
        {0U, CallKind::group, Slot::ts1, "invalid"},
    };

    check(activation.freeze(channels), "startup configuration is frozen once");
    check(!activation.freeze({}), "runtime channel edits cannot replace the frozen startup plan");
    check(activation.next(true, StartupGroupActivation::TimePoint{}).kind ==
              StartupGroupActivation::DecisionKind::wait,
          "frozen plan does not send before the first BM connection activates it");
    check(activation.activate(), "first BM connection starts the frozen plan");
    check(!activation.activate(), "a later BM reconnect cannot restart the sequence");
    const auto& stats = activation.stats();
    check(stats.target_count == 3U && stats.private_skipped == 1U &&
          stats.disconnect_group_skipped == 1U && stats.duplicate_skipped == 1U &&
          stats.invalid_skipped == 1U,
          "plan captures saved groups and counts private, TG4000, duplicate, and invalid entries");

    const auto now = StartupGroupActivation::TimePoint{};
    const auto first = activation.next(true, now);
    check(first.kind == StartupGroupActivation::DecisionKind::send &&
          first.target.destination_id == 91U && first.target.slot == Slot::ts2,
          "first target follows saved channel order");
    check(activation.next(true, now).kind == StartupGroupActivation::DecisionKind::wait,
          "only one command can be in flight");
    activation.complete(CommandStatus::accepted, true, now);

    const auto second = activation.next(true, now);
    check(second.kind == StartupGroupActivation::DecisionKind::send &&
          second.target.destination_id == 91U && second.target.slot == Slot::ts1,
          "same TG on a different slot remains a separate target");
    activation.complete(CommandStatus::failed, true, now);
    const auto third = activation.next(true, now);
    check(third.kind == StartupGroupActivation::DecisionKind::send &&
          third.target.destination_id == 46001U,
          "failure advances to the next saved target without retrying the failed target");
    activation.complete(CommandStatus::accepted, true, now);
    check(activation.finished() && activation.stats().locally_sent == 2U &&
          activation.stats().failed == 1U,
          "sequence ends after every target has one terminal result");
}

void test_busy_retries_only_until_bounded_timeout()
{
    StartupGroupActivation activation;
    check(activation.freeze({{46001U, CallKind::group, Slot::ts2, ""}}) && activation.activate(),
          "single-target busy plan starts");
    const auto start = StartupGroupActivation::TimePoint{};
    auto decision = activation.next(true, start);
    check(decision.kind == StartupGroupActivation::DecisionKind::send,
          "first target dispatches when BM is ready");
    activation.complete(CommandStatus::busy, true, start);
    check(activation.next(true, start + 250ms).kind == StartupGroupActivation::DecisionKind::wait,
          "busy retry waits for its interval");
    decision = activation.next(true, start + 500ms);
    check(decision.kind == StartupGroupActivation::DecisionKind::send &&
          decision.target.destination_id == 46001U,
          "busy response retries the same target after the interval");
    activation.complete(CommandStatus::busy, true, start + 500ms);
    decision = activation.next(true, start + StartupGroupActivation::busy_timeout);
    check(decision.kind == StartupGroupActivation::DecisionKind::finished && activation.finished() &&
          activation.stats().busy_skipped == 1U && activation.stats().locally_sent == 0U,
          "persistent busy ends the sequence and reports the target skipped without sending it");
}

void test_disconnect_pauses_and_resumes_remaining_targets()
{
    StartupGroupActivation activation;
    check(activation.freeze({
              {91U, CallKind::group, Slot::ts2, ""},
              {46001U, CallKind::group, Slot::ts2, ""},
          }) && activation.activate(), "two-target disconnect plan starts");
    const auto now = StartupGroupActivation::TimePoint{};
    auto decision = activation.next(true, now);
    check(decision.kind == StartupGroupActivation::DecisionKind::send,
          "first target dispatches before disconnect");
    activation.complete(CommandStatus::not_ready, false, now);
    check(activation.observe_connection(false) == StartupGroupActivation::ConnectionChange::paused &&
          activation.remaining() == 2U,
          "not-ready during disconnect leaves both unsent targets queued");
    check(activation.next(false, now + 1s).kind == StartupGroupActivation::DecisionKind::wait,
          "disconnected BM does not dispatch queued targets");
    check(activation.observe_connection(true) == StartupGroupActivation::ConnectionChange::resumed,
          "reconnection resumes the same startup sequence");
    decision = activation.next(true, now + 2s);
    check(decision.kind == StartupGroupActivation::DecisionKind::send &&
          decision.target.destination_id == 91U,
          "first target is retried after a pre-send not-ready result");
    activation.complete(CommandStatus::accepted, true, now + 2s);
    decision = activation.next(true, now + 2s);
    check(decision.kind == StartupGroupActivation::DecisionKind::send &&
          decision.target.destination_id == 46001U,
          "remaining target continues after reconnect");
    activation.complete(CommandStatus::accepted, true, now + 2s);
    check(activation.finished() && activation.stats().locally_sent == 2U,
          "reconnection does not restart or duplicate completed targets");
}

void test_offline_pause_does_not_consume_busy_timeout()
{
    StartupGroupActivation activation;
    check(activation.freeze({{91U, CallKind::group, Slot::ts2, ""}}) && activation.activate(),
          "offline pause test starts");
    const auto start = StartupGroupActivation::TimePoint{};
    (void)activation.next(true, start);
    activation.complete(CommandStatus::busy, true, start);
    check(activation.observe_connection(false) == StartupGroupActivation::ConnectionChange::paused,
          "disconnect pauses a busy startup queue");
    check(activation.next(false, start + std::chrono::hours(2)).kind ==
              StartupGroupActivation::DecisionKind::wait,
          "disconnected BM never receives a queued Quick Call");
    check(activation.observe_connection(true) == StartupGroupActivation::ConnectionChange::resumed,
          "same process resumes after a later BM reconnect");
    const auto decision = activation.next(true, start + std::chrono::hours(2));
    check(decision.kind == StartupGroupActivation::DecisionKind::send &&
          decision.target.destination_id == 91U,
          "time spent disconnected does not expire the busy target");
}

} // namespace

int main()
{
    test_startup_plan_filters_and_deduplicates();
    test_busy_retries_only_until_bounded_timeout();
    test_disconnect_pauses_and_resumes_remaining_targets();
    test_offline_pause_does_not_consume_busy_timeout();
    std::cout << "PASS: " << assertions << " startup group activation assertions\n";
    return EXIT_SUCCESS;
}
