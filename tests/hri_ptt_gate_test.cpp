#include "wirex/hri_ptt_gate.hpp"

#include <cstdlib>
#include <iostream>

namespace {

using wirex::hri_ptt_gate::Action;
using wirex::hri_ptt_gate::Gate;
using wirex::hri_ptt_gate::Level;

int failures = 0;

void check(bool condition, const char* message)
{
    if (condition) return;
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
}

void test_requires_ready_then_release_then_fresh_press()
{
    Gate gate;
    check(gate.observe(Level::pressed, true) == Action::none,
        "startup pressed state must not start TX before readiness");
    check(gate.set_ready(true) == Action::none,
        "readiness alone must not treat a startup press as a new edge");
    check(gate.observe(Level::pressed, true) == Action::none,
        "a held press observed before readiness must remain ignored");
    check(gate.observe(Level::released, true) == Action::none,
        "a ready release should arm the next fresh press");
    check(gate.snapshot().armed, "the first ready release should arm the gate");
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "a fresh ready press should start one TX call");

    Gate early_release;
    (void)early_release.observe(Level::released, true);
    (void)early_release.set_ready(true);
    check(early_release.observe(Level::pressed, true) == Action::none,
        "a release observed before readiness must not arm a later press");
    (void)early_release.observe(Level::released, true);
    check(early_release.observe(Level::pressed, true) == Action::start_tx,
        "the gate should arm only after a release observed while ready");
}

void test_repeated_edges_do_not_toggle()
{
    Gate gate;
    (void)gate.set_ready(true);
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "first press edge should start TX");
    check(gate.start_succeeded(100U), "successful TX startup should arm one per-call timer");
    check(gate.observe(Level::pressed, true) == Action::none,
        "repeated pressed samples must not start or toggle TX");
    check(gate.observe(Level::released, true) == Action::end_tx,
        "release edge should end the current TX call once");
    check(gate.tick(100U + wirex::hri_ptt_gate::max_call_duration_ms) == Action::none,
        "a normal release must clear the old call timer");
    check(gate.observe(Level::released, true) == Action::none,
        "repeated released samples must not end TX twice");
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "a new press after release may start the next call");
}

void test_busy_down_requires_release_before_retry()
{
    Gate gate;
    (void)gate.set_ready(true);
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, false) == Action::none,
        "a press while another path is busy must be rejected");
    check(!gate.snapshot().armed && gate.snapshot().pressed_latched,
        "a rejected press must disarm until the operator releases PTT");
    check(gate.observe(Level::pressed, true) == Action::none,
        "a busy press must not start later merely because the pipeline becomes free");
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "a release followed by a fresh press should allow a later call");
}

void test_unknown_and_link_loss_abort_and_require_release()
{
    Gate gate;
    (void)gate.set_ready(true);
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "a valid edge should establish an active TX call");
    check(gate.start_succeeded(1000U), "successful TX should start its timeout clock");
    check(gate.observe(Level::unknown, true) == Action::abort_tx,
        "unknown PTT state during a call must request immediate safe abort");
    check(gate.observe(Level::pressed, true) == Action::none,
        "unknown state must disarm the next pressed sample");
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "release is required before a new call after unknown state");
    check(gate.start_succeeded(2000U), "second call should start a fresh timer");
    check(gate.set_ready(false) == Action::abort_tx,
        "readiness loss during TX must abort the active call");
    check(gate.tick(2000U + wirex::hri_ptt_gate::max_call_duration_ms) == Action::none,
        "readiness loss must clear the previous call timer");
    (void)gate.set_ready(true);
    check(gate.observe(Level::pressed, true) == Action::none,
        "reconnection must not replay a held press");
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "reconnected PTT requires a fresh release and press edge");
}

void test_start_failure_and_call_deadline_require_release()
{
    Gate start_failed;
    (void)start_failed.set_ready(true);
    (void)start_failed.observe(Level::released, true);
    check(start_failed.observe(Level::pressed, true) == Action::start_tx,
        "test should start a call before simulating audio-open failure");
    start_failed.start_failed();
    check(start_failed.observe(Level::pressed, true) == Action::none,
        "a failed TX start must not retry while the same press remains held");
    (void)start_failed.observe(Level::released, true);
    check(start_failed.observe(Level::pressed, true) == Action::start_tx,
        "release should rearm after TX start failure");

    Gate deadline;
    (void)deadline.set_ready(true);
    (void)deadline.observe(Level::released, true);
    check(deadline.observe(Level::pressed, true) == Action::start_tx,
        "test should start a call before simulating its per-call deadline");
    deadline.disarm_until_release();
    check(deadline.observe(Level::pressed, true) == Action::none,
        "per-call timeout must not restart transmission while PTT remains pressed");
    (void)deadline.observe(Level::released, true);
    check(deadline.observe(Level::pressed, true) == Action::start_tx,
        "a fresh edge may start after the deadline call has been released");
}

void test_call_timer_120s_boundary_and_fresh_call()
{
    Gate gate;
    (void)gate.set_ready(true);
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "first PTT edge should start the timed call");
    check(gate.start_succeeded(10000U), "successful input startup should record the call start time");
    check(gate.tick(129999U) == Action::none,
        "a call must remain active at exactly 119999 milliseconds");
    check(gate.observe(Level::pressed, true) == Action::none,
        "repeated down observations must not restart or extend the call timer");
    check(gate.tick(130000U) == Action::call_timeout,
        "a call must time out at exactly 120000 milliseconds");
    check(!gate.snapshot().tx_active && !gate.snapshot().armed && gate.snapshot().pressed_latched,
        "timeout must stop the active call and require a PTT release");
    check(gate.tick(250000U) == Action::none,
        "one call timeout must be emitted only once");
    check(gate.observe(Level::pressed, true) == Action::none,
        "continued down after timeout must not start another call");
    (void)gate.observe(Level::released, true);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
        "a new call may start only after an observed release and fresh press");
    check(gate.start_succeeded(400000U), "the next call should receive an independent timer origin");
    check(gate.tick(519999U) == Action::none &&
        gate.tick(520000U) == Action::call_timeout,
        "the next call should use its own 120-second duration");
}

} // namespace

int main()
{
    test_requires_ready_then_release_then_fresh_press();
    test_repeated_edges_do_not_toggle();
    test_busy_down_requires_release_before_retry();
    test_unknown_and_link_loss_abort_and_require_release();
    test_start_failure_and_call_deadline_require_release();
    test_call_timer_120s_boundary_and_fresh_call();
    if (failures != 0) {
        std::cerr << failures << " HRI PTT gate assertion(s) failed.\n";
        return EXIT_FAILURE;
    }
    std::cout << "HRI PTT gate tests passed.\n";
    return EXIT_SUCCESS;
}
