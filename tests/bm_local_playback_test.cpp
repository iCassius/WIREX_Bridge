#include "wirex/bm_local_playback.hpp"

#include <iostream>

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const char* message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void radio_route_has_priority() {
    using namespace wirex::bm_local_playback;
    Session session;
    session.set_environment(true, true);

    check(session.begin_call(1U) == BeginResult::radio, "ready HRI selects the existing radio path");
    check(session.should_send_hri(), "radio route permits HRI start/stop handling");
    check(session.should_submit_audio(), "radio route submits decoded frames to WaveOut");
    check(!session.should_discard_audio(), "radio route does not silently drop frames");
    check(session.end_call(1U), "radio call releases its generation");
}

void local_audio_and_silent_receive_routes() {
    using namespace wirex::bm_local_playback;
    Session session;
    session.set_environment(false, true);

    check(session.begin_call(7U) == BeginResult::local_output,
          "radio offline with selected output starts local computer playback");
    check(!session.should_send_hri(), "local playback never sends HRI commands");
    check(session.should_submit_audio(), "local playback submits decoded frames");
    check(session.end_call(7U), "local call releases its generation");

    session.set_environment(false, false);
    check(session.begin_call(8U) == BeginResult::silent,
          "unavailable output still admits a BM call for visible receive state");
    check(session.snapshot().call_active, "silent receive route keeps the call active");
    check(session.should_discard_audio(), "unavailable output explicitly selects silent draining");
    check(!session.should_send_hri(), "silent receive route never sends HRI commands");
    check(session.end_call(8U), "silent receive route releases its generation");
}

void output_failure_does_not_hide_or_retarget_call() {
    using namespace wirex::bm_local_playback;
    Session session;
    session.set_environment(false, true);
    check(session.begin_call(11U) == BeginResult::local_output, "local route starts before output failure");

    check(session.output_failed(OutputError::submit_failed), "submit failure is recorded");
    check(session.snapshot().call_active, "output failure leaves the BM call visible");
    check(session.snapshot().generation == 11U, "output failure preserves the active call generation");
    check(session.snapshot().output_error == OutputError::submit_failed, "specific output failure is retained");
    check(session.should_discard_audio(), "remaining audio drains without claiming it was played");
    check(!session.should_send_hri(), "output failure does not fall back to HRI");

    session.set_environment(true, true);
    check(session.snapshot().route == Route::silent,
          "radio becoming ready mid-call does not retarget the active stream");
    check(session.should_discard_audio(), "mid-call radio change leaves the active route fixed");
    check(session.end_call(11U), "failed-output call can still finish and release media ownership");
    check(session.begin_call(12U) == BeginResult::radio,
          "the next call can use HRI after the radio becomes ready");
}

void output_changes_and_shutdown_are_bounded_by_call_lifecycle() {
    using namespace wirex::bm_local_playback;
    Session session;
    session.set_environment(false, true);
    check(session.begin_call(21U) == BeginResult::local_output, "local call begins for switching test");
    check(!session.can_change_output(true, true), "active call blocks output switching even if Router says idle");
    check(!session.can_change_output(false, true), "busy Router blocks output switching");
    check(!session.can_change_output(true, false), "undrained WaveOut blocks output switching");
    check(!session.end_call(22U), "stale generation cannot finish the active call");

    session.request_shutdown();
    check(session.begin_call(23U) == BeginResult::shutting_down,
          "shutdown request prevents a new BM call from starting");
    check(!session.can_change_output(true, true), "shutdown prevents endpoint changes");
    check(session.end_call(21U), "active call can finish its bounded drain during shutdown");
    // finish_shutdown receives the actual WaveOut close state from the engine.
    check(!session.finish_shutdown(true), "shutdown remains pending when the audio handle stays open");
    check(session.snapshot().output_error == OutputError::close_failed,
          "failed audio close remains visible in the shutdown state");
    check(session.finish_shutdown(false), "shutdown completes after the output is confirmed closed");
    check(!session.snapshot().output_open, "stopped session reports output closed");
    check(session.begin_call(24U) == BeginResult::shutting_down,
          "stopped session cannot accept another incoming call");
}

} // namespace

int main() {
    radio_route_has_priority();
    local_audio_and_silent_receive_routes();
    output_failure_does_not_hide_or_retarget_call();
    output_changes_and_shutdown_are_bounded_by_call_lifecycle();
    if (failures != 0) {
        std::cerr << "bm_local_playback_test: " << failures << " / " << checks << " checks failed\n";
        return 1;
    }
    std::cout << "bm_local_playback_test: all " << checks << " checks passed\n";
    return 0;
}
