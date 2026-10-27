#include "wirex/talkgroup_routing.hpp"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string_view>

namespace {

using namespace wirex::talkgroup_routing;
using wirex::dmr_call::CallConfig;
using wirex::dmr_call::CallKind;
using wirex::dmr_call::Slot;

constexpr std::uint32_t local_id = 4611355U;
int failures = 0;

} // 匿名命名空间

namespace wirex::talkgroup_routing {

struct RouterTestAccess {
    static void set_rx_revision(Router& router, std::uint64_t revision)
    {
        router.rx_policy_revision_ = revision;
    }

    static void set_next_rx_generation(Router& router, std::uint64_t generation)
    {
        router.next_rx_generation_ = generation;
        router.rx_generation_exhausted_ = false;
    }

    static void set_next_lease_id(Router& router, std::uint64_t lease_id)
    {
        router.next_lease_id_ = lease_id;
        router.lease_id_exhausted_ = false;
    }
};

} // 命名空间 wirex::talkgroup_routing

namespace {

void check(bool condition, std::string_view message)
{
    if (condition) return;
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
}

CallConfig make_call(std::uint32_t source,
                     std::uint32_t destination,
                     Slot slot,
                     CallKind kind,
                     std::uint8_t stream = 1U)
{
    CallConfig call{};
    call.source_id = source;
    call.destination_id = destination;
    call.gateway_id = 4611355U;
    call.stream_id = {{0U, 0U, 0U, stream}};
    call.slot = slot;
    call.kind = kind;
    return call;
}

bool install_rx(Router& router, const RxPolicy& policy)
{
    const auto revision = router.snapshot().rx_policy_revision;
    return static_cast<bool>(router.replace_rx_policy(revision, policy));
}

bool install_tx(Router& router, const TxPolicy& policy)
{
    const auto revision = router.snapshot().tx_policy_revision;
    return static_cast<bool>(router.replace_tx_policy(revision, policy));
}

TxPolicy make_tx_policy(std::uint32_t destination,
                        CallKind kind = CallKind::private_call,
                        Slot slot = Slot::ts2,
                        bool enabled = true)
{
    TxPolicy policy{};
    policy.transmit_enabled = enabled;
    policy.dynamic_join_enabled = enabled;
    policy.target = TxTarget{destination, kind, slot};
    return policy;
}

void test_selected_groups_and_slot_scoped_block()
{
    Router router(local_id);
    RxPolicy policy{};
    policy.group_mode = GroupMode::selected;
    policy.allowed_groups = {{91U, Slot::ts1}, {46001U, Slot::ts2}};
    policy.blocked_groups = {{91U, Slot::ts2}};
    check(install_rx(router, policy), "a valid multi-group policy should install");

    check(router.match_receive(make_call(1001U, 91U, Slot::ts1, CallKind::group)) == RouteMatch::allowed,
        "an explicitly selected group on TS1 should be allowed");
    check(router.match_receive(make_call(1001U, 91U, Slot::ts2, CallKind::group)) == RouteMatch::blocked_group,
        "blocking TG91 TS2 should override its allow entry");
    check(router.match_receive(make_call(1001U, 91U, Slot::ts1, CallKind::group)) == RouteMatch::allowed,
        "a TG91 TS2 block must not block TG91 TS1");
    check(router.match_receive(make_call(1001U, 46001U, Slot::ts2, CallKind::group)) == RouteMatch::allowed,
        "a second selected group should also be allowed");
    check(router.match_receive(make_call(1001U, 91U, Slot::ts2, CallKind::private_call)) == RouteMatch::policy_denied,
        "group routes must not accept private calls");

    policy.blocked_source_ids.push_back(1001U);
    check(install_rx(router, policy), "source deny should install atomically");
    check(router.match_receive(make_call(1001U, 46001U, Slot::ts2, CallKind::group)) == RouteMatch::blocked_source,
        "a blocked speaker should be excluded across every group route");
}

void test_all_delivered_mode_and_blocks()
{
    Router router(local_id);
    RxPolicy policy{};
    policy.group_mode = GroupMode::all_delivered;
    policy.blocked_groups = {{91U, Slot::ts2}};
    policy.blocked_source_ids = {777U};
    check(install_rx(router, policy), "all-delivered mode should install without group allow entries");
    check(router.match_receive(make_call(1001U, 3100U, Slot::ts1, CallKind::group)) == RouteMatch::allowed,
        "all-delivered mode should allow a valid group received from BM");
    check(router.match_receive(make_call(1001U, 91U, Slot::ts1, CallKind::group)) == RouteMatch::allowed,
        "a route block for TG91 TS2 should leave TG91 TS1 allowed");
    check(router.match_receive(make_call(1001U, 91U, Slot::ts2, CallKind::group)) == RouteMatch::blocked_group,
        "all-delivered mode must still honor route blocks");
    check(router.match_receive(make_call(777U, 3100U, Slot::ts1, CallKind::group)) == RouteMatch::blocked_source,
        "all-delivered mode must still honor source blocks");
}

void test_private_peer_and_local_destination_are_distinct()
{
    Router router(local_id);
    RxPolicy policy{};
    policy.private_mode = PrivateMode::selected_peers;
    policy.private_peers = {{460997U, local_id, Slot::ts2}};
    check(install_rx(router, policy), "a selected private peer should install");
    check(router.match_receive(make_call(460997U, local_id, Slot::ts2, CallKind::private_call)) == RouteMatch::allowed,
        "private peer matches incoming Source ID and local destination ID");
    check(router.match_receive(make_call(1234U, local_id, Slot::ts2, CallKind::private_call)) == RouteMatch::policy_denied,
        "a different private Source ID must not match the selected peer");
    check(router.match_receive(make_call(460997U, 1234U, Slot::ts2, CallKind::private_call)) == RouteMatch::policy_denied,
        "a private call addressed to another radio must never be received");
    check(router.match_receive(make_call(460997U, local_id, Slot::ts1, CallKind::private_call)) == RouteMatch::policy_denied,
        "private peer route must match its configured timeslot");

    policy.private_mode = PrivateMode::all_peers_to_local;
    policy.private_peers.clear();
    policy.local_private_routes = {{local_id, Slot::ts1}};
    check(install_rx(router, policy), "all peers addressed locally should be an independent private mode");
    check(router.match_receive(make_call(1234U, local_id, Slot::ts1, CallKind::private_call)) == RouteMatch::allowed,
        "all-peers mode should accept different peers addressed to the local ID");
    check(router.match_receive(make_call(1234U, 5555U, Slot::ts1, CallKind::private_call)) == RouteMatch::policy_denied,
        "all-peers mode must not receive a private call to another destination");

    policy.blocked_source_ids = {1234U};
    check(install_rx(router, policy), "private speaker block should install");
    check(router.match_receive(make_call(1234U, local_id, Slot::ts1, CallKind::private_call)) == RouteMatch::blocked_source,
        "source block must override all-peers private mode");
}

void test_all_local_private_routes_union_with_exact_peers_on_other_slots()
{
    Router router(local_id);
    RxPolicy policy{};
    policy.private_mode = PrivateMode::all_peers_to_local;
    policy.local_private_routes = {{local_id, Slot::ts1}};
    policy.private_peers = {{460997U, local_id, Slot::ts2}};
    check(install_rx(router, policy), "all-local and exact-peer routes should install together");
    check(router.match_receive(make_call(1234U, local_id, Slot::ts1, CallKind::private_call)) == RouteMatch::allowed,
        "all peers to the local ID should be allowed on the configured local route");
    check(router.match_receive(make_call(460997U, local_id, Slot::ts2, CallKind::private_call)) == RouteMatch::allowed,
        "the exact peer route should be allowed on its separate timeslot");
    check(router.match_receive(make_call(1234U, local_id, Slot::ts2, CallKind::private_call)) == RouteMatch::policy_denied,
        "the exact peer timeslot must not become an all-peers route");

    policy.blocked_source_ids = {1234U, 460997U};
    check(install_rx(router, policy), "source blocks should apply to both private route sets");
    check(router.match_receive(make_call(1234U, local_id, Slot::ts1, CallKind::private_call)) == RouteMatch::blocked_source &&
          router.match_receive(make_call(460997U, local_id, Slot::ts2, CallKind::private_call)) == RouteMatch::blocked_source,
        "source blocks must override the union of local and exact-peer private routes");
}

void test_candidate_observation_does_not_change_policy_or_claim_playback()
{
    Router router(local_id);
    const auto before = router.snapshot();
    const auto group = make_call(3141592U, 91U, Slot::ts2, CallKind::group);
    const auto candidate = router.observe_candidate(group, ObservationLevel::outer_header_seen);
    check(candidate.has_value(), "a valid outer header should return a group route candidate");
    check(candidate && candidate->group_route == std::optional<GroupRoute>{{91U, Slot::ts2}},
        "the candidate should preserve TG and slot as one route key");
    check(candidate && candidate->observation_level == ObservationLevel::outer_header_seen,
        "candidate should preserve that only an outer header was observed");
    check(router.snapshot().media_owner == MediaOwner::idle &&
          router.snapshot().rx_policy_revision == before.rx_policy_revision,
        "candidate discovery must not change RX policy or claim media ownership");

    const auto denied = router.admit_rx(group, true);
    check(denied.decision == RxDecision::candidate_only && denied.candidate_group.has_value(),
        "unselected group should be returned as a candidate rather than played");
    check(router.snapshot().media_owner == MediaOwner::idle,
        "candidate-only outcome must not reserve the RX lane");

    const auto private_to_other = make_call(3141592U, 5555U, Slot::ts2, CallKind::private_call);
    check(!router.observe_candidate(private_to_other, ObservationLevel::outer_header_seen),
        "a private call addressed to another radio must not become a local peer candidate");
    const auto local_private = make_call(3141592U, local_id, Slot::ts2, CallKind::private_call);
    const auto private_candidate = router.observe_candidate(local_private,
        ObservationLevel::link_control_validated);
    check(private_candidate && private_candidate->private_peer_source_id == 3141592U,
        "a local private candidate should identify the peer Source ID");
    check(private_candidate && private_candidate->observation_level == ObservationLevel::link_control_validated,
        "a candidate must carry the actual LC observation level supplied by the caller");
}

void test_single_stream_arbiter_keeps_owner_until_hri_stop_confirmation()
{
    Router router(local_id);
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(install_rx(router, rx), "all-delivered policy should install");
    check(install_tx(router, make_tx_policy(460997U)), "enabled TX policy should install");

    const auto first_call = make_call(1001U, 91U, Slot::ts2, CallKind::group, 1U);
    const auto first = router.admit_rx(first_call, true);
    check(first.decision == RxDecision::admitted && first.generation != 0U,
        "the first allowed stream should acquire one RX generation");
    const auto repeated = router.admit_rx(make_call(1001U, 91U, Slot::ts2, CallKind::group, 1U), false);
    check(repeated.decision == RxDecision::same_active_call && repeated.generation == first.generation,
        "voice packets from the owner stream should retain its generation");
    const auto second = router.admit_rx(make_call(2002U, 91U, Slot::ts2, CallKind::group, 2U), true);
    check(second.decision == RxDecision::media_busy && second.generation == 0U,
        "a second stream should be dropped without displacing or queueing the first");
    check(router.snapshot().active_rx_generation == first.generation,
        "collision must preserve the active RX generation");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "PTT must be rejected while RX owns the lane");

    check(router.rx_network_eot(first.generation) == OperationStatus::completed,
        "network EOT should begin RX drain");
    check(router.snapshot().media_owner == MediaOwner::rx_draining,
        "network EOT does not release the lane before playback completes");
    check(router.rx_playback_finished(first.generation) == OperationStatus::completed,
        "playback completion should request HRI stop");
    check(router.snapshot().media_owner == MediaOwner::rx_stopping,
        "playback completion still waits for HRI stop confirmation");
    check(router.admit_rx(make_call(2002U, 91U, Slot::ts2, CallKind::group, 3U), true).decision == RxDecision::stopping,
        "new RX stays blocked while HRI stop is pending");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "PTT stays blocked while HRI stop is pending");
    check(router.complete_rx_stop(first.generation, false) == OperationStatus::cleanup_failed,
        "failed HRI cleanup should keep the media owner faulted");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "cleanup failure must not expose the lane to PTT");
    check(router.request_rx_stop() == first.generation,
        "the same RX generation may explicitly retry cleanup");
    check(router.complete_rx_stop(first.generation, true) == OperationStatus::completed,
        "successful retry should release the RX lane");
    check(router.rx_network_eot(first.generation) == OperationStatus::stale_generation,
        "a completed generation must reject late EOT");
    check(router.admit_rx(first_call, false).decision == RxDecision::not_call_start,
        "a late continuation from the stopped call must not start a fresh generation");
    const auto next = router.admit_rx(make_call(2002U, 91U, Slot::ts2, CallKind::group, 3U), true);
    check(next.decision == RxDecision::admitted && next.generation > first.generation,
        "a fresh stream may start after stop confirmation with a new generation");
}

void test_policy_removal_cancels_rx_but_waits_for_cleanup()
{
    Router router(local_id);
    RxPolicy rx{};
    rx.group_mode = GroupMode::selected;
    rx.allowed_groups = {{91U, Slot::ts2}};
    check(install_rx(router, rx), "selected RX policy should install");
    check(install_tx(router, make_tx_policy(460997U)), "TX policy should install");
    const auto active = router.admit_rx(make_call(1001U, 91U, Slot::ts2, CallKind::group), true);
    check(active.decision == RxDecision::admitted, "selected group should start");

    RxPolicy replacement{};
    replacement.group_mode = GroupMode::selected;
    replacement.allowed_groups = {{46001U, Slot::ts2}};
    const auto changed = router.replace_rx_policy(router.snapshot().rx_policy_revision, replacement);
    check(changed.status == PolicyUpdateStatus::applied &&
          changed.cancelled_rx_generation == active.generation,
        "removing the active group should return its generation for external cancellation");
    check(router.snapshot().media_owner == MediaOwner::rx_stopping,
        "policy update must retain the RX owner until external cleanup finishes");
    check(router.admit_rx(make_call(1001U, 46001U, Slot::ts2, CallKind::group, 2U), true).decision == RxDecision::stopping,
        "even an allowed replacement group waits until the old HRI playback stops");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "PTT cannot collide with the stopping RX generation");
    check(router.complete_rx_stop(active.generation, true) == OperationStatus::completed,
        "external cleanup acknowledgement releases the canceled owner");
    check(router.admit_rx(make_call(1001U, 46001U, Slot::ts2, CallKind::group, 2U), true).decision == RxDecision::admitted,
        "replacement route becomes usable after cleanup confirmation");

    const auto current_revision = router.snapshot().rx_policy_revision;
    const auto conflict = router.replace_rx_policy(current_revision - 1U, rx);
    check(conflict.status == PolicyUpdateStatus::revision_conflict &&
          router.snapshot().rx_policy_revision == current_revision,
        "stale compare-and-swap must not alter the live policy");
}

void test_tx_target_is_frozen_and_rx_identity_never_rewrites_it()
{
    Router router(local_id);
    RxPolicy rx{};
    rx.private_mode = PrivateMode::all_peers_to_local;
    rx.local_private_routes = {{local_id, Slot::ts2}};
    check(install_rx(router, rx), "private return route should install");
    auto tx = make_tx_policy(460997U, CallKind::private_call, Slot::ts2);
    check(install_tx(router, tx), "initial parrot TX target should install");

    const auto started = router.begin_ptt();
    check(started && started.lease->target.destination_id == 460997U,
        "PTT should freeze the target present at call start");
    auto next_policy = tx;
    next_policy.target = TxTarget{3100U, CallKind::group, Slot::ts2};
    check(install_tx(router, next_policy), "a new target should update the next-call policy");
    check(router.snapshot().active_tx_lease &&
          router.snapshot().active_tx_lease->target.destination_id == 460997U,
        "changing the pending target must not change the active TX lease");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "a second PTT must not start inside the current lease");
    check(router.release_tx(started.lease->id) == OperationStatus::completed,
        "PTT release should move the original target into EOT drain");
    check(router.snapshot().active_tx_lease->target.destination_id == 460997U &&
          router.snapshot().active_tx_lease->eot_pending,
        "EOT drain should continue using the frozen target");
    check(router.complete_tx_eot(started.lease->id, true) == OperationStatus::completed &&
          router.snapshot().media_owner == MediaOwner::tx_draining &&
          router.snapshot().active_tx_lease.has_value(),
        "successful EOT should retain the lease until local cleanup is acknowledged");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "a new PTT must remain blocked after EOT but before cleanup");
    check(router.complete_tx_cleanup(started.lease->id, true) == OperationStatus::completed,
        "successful local cleanup should release the completed lease");

    const auto next = router.begin_ptt();
    check(next && next.lease->target.destination_id == 3100U &&
          next.lease->target.kind == CallKind::group,
        "the new target should apply only to the next PTT call");
    check(router.admit_rx(make_call(460997U, local_id, Slot::ts2, CallKind::private_call), true).decision == RxDecision::media_busy,
        "a private return observed during TX cannot change the TX target or overlap media");
    check(router.snapshot().active_tx_lease->target.destination_id == 3100U,
        "incoming Source ID must never rewrite the pending or active TX target");
}

void test_dynamic_join_requires_explicit_enabled_idle_and_allowed_target()
{
    Router router(local_id);
    auto tx = make_tx_policy(460997U, CallKind::private_call, Slot::ts2, false);
    tx.dynamic_join_enabled = true;
    tx.dynamic_join_blocked_group_ids = {91U, 46001U};
    check(install_tx(router, tx), "disabled TX policy with join deny list should validate");
    check(router.request_dynamic_join({3100U, Slot::ts2}, true).status == TxStartStatus::transmit_disabled,
        "disabled TX must prevent dynamic Quick call activation");
    check(router.snapshot().media_owner == MediaOwner::idle,
        "a denied dynamic join must not reserve media");

    tx.transmit_enabled = true;
    check(install_tx(router, tx), "enabled TX should update policy");
    check(router.request_dynamic_join({3100U, Slot::ts2}, false).status == TxStartStatus::explicit_action_required,
        "dynamic join must require a direct user action");
    check(router.request_dynamic_join({91U, Slot::ts2}, true).status == TxStartStatus::dynamic_join_blocked,
        "listen-only TG91 must remain blocked from dynamic join");
    check(router.request_dynamic_join({46001U, Slot::ts2}, true).status == TxStartStatus::dynamic_join_blocked,
        "listen-only TG46001 must remain blocked from dynamic join");

    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(install_rx(router, rx), "all-delivered mode should install for the busy check");
    const auto active_rx = router.admit_rx(make_call(1001U, 91U, Slot::ts2, CallKind::group), true);
    check(active_rx.decision == RxDecision::admitted, "RX should own the media lane before join attempt");
    check(router.request_dynamic_join({3100U, Slot::ts2}, true).status == TxStartStatus::media_busy,
        "a dynamic join requested during RX must fail immediately without queuing");
    check(router.snapshot().media_owner == MediaOwner::rx_active,
        "a busy dynamic join must not displace RX");
    check(router.request_rx_stop() == active_rx.generation, "test should request RX cleanup");
    check(router.complete_rx_stop(active_rx.generation, true) == OperationStatus::completed,
        "RX cleanup should release media before dynamic join");

    const auto joined = router.request_dynamic_join({3100U, Slot::ts1}, true);
    check(joined && joined.lease->purpose == TxPurpose::quick_call_join &&
          joined.lease->target.destination_id == 3100U,
        "explicit dynamic join should acquire a real short-call TX lease");
    check(router.tx_policy().target.destination_id == 460997U,
        "a dynamic join target must not replace the user's regular TX target");
    check(router.release_tx(joined.lease->id) == OperationStatus::completed,
        "the dynamic short call must release into its EOT phase");
    check(router.complete_tx_eot(joined.lease->id, true) == OperationStatus::completed,
        "dynamic short call EOT result should be recorded");
    check(router.complete_tx_cleanup(joined.lease->id, true) == OperationStatus::completed,
        "dynamic short call lease ends only after cleanup confirmation");

    Router mandatory_guard_router(local_id);
    auto no_custom_deny = make_tx_policy(91U, CallKind::group, Slot::ts2, true);
    no_custom_deny.dynamic_join_blocked_group_ids.clear();
    check(install_tx(mandatory_guard_router, no_custom_deny),
        "a target policy with an empty caller denylist should remain structurally valid");
    check(mandatory_guard_router.begin_ptt().status == TxStartStatus::policy_forbidden_target,
        "TG91 group TX must be blocked by a built-in receive-only guard");
    check(mandatory_guard_router.request_dynamic_join({91U, Slot::ts2}, true).status == TxStartStatus::dynamic_join_blocked,
        "TG91 Quick call must be blocked even when caller denylist is empty");
    no_custom_deny.target.destination_id = 46001U;
    check(install_tx(mandatory_guard_router, no_custom_deny),
        "TG46001 policy should pass structural validation before mandatory guard");
    check(mandatory_guard_router.begin_ptt().status == TxStartStatus::policy_forbidden_target,
        "TG46001 group TX must be blocked by a built-in receive-only guard");
    check(mandatory_guard_router.request_dynamic_join({46001U, Slot::ts2}, true).status == TxStartStatus::dynamic_join_blocked,
        "TG46001 Quick call must be blocked even when caller denylist is empty");
}

void test_permission_revocation_stops_active_tx_and_requires_ptt_release()
{
    Router router(local_id);
    auto tx = make_tx_policy(460997U);
    check(install_tx(router, tx), "enabled TX policy should install");
    const auto started = router.begin_ptt();
    check(static_cast<bool>(started), "PTT should start before permission revocation");

    auto disabled = tx;
    disabled.transmit_enabled = false;
    disabled.dynamic_join_enabled = false;
    disabled.target = TxTarget{3100U, CallKind::group, Slot::ts2};
    const auto revoked = router.replace_tx_policy(router.snapshot().tx_policy_revision, disabled);
    check(revoked.status == PolicyUpdateStatus::applied &&
          revoked.stop_tx_lease_id == started.lease->id,
        "turning off TX permission should return the active lease for immediate PCM stop");
    check(router.snapshot().media_owner == MediaOwner::tx_draining &&
          router.snapshot().active_tx_lease->admission_revoked &&
          router.snapshot().active_tx_lease->eot_pending,
        "permission revocation should stop new PCM and drain the current lease to EOT");
    check(router.snapshot().active_tx_lease->target.destination_id == 460997U,
        "permission revocation and target update must preserve the active lease target");
    check(router.begin_ptt().status == TxStartStatus::transmit_disabled,
        "disabled permission must reject a new PTT immediately");
    check(router.complete_tx_eot(started.lease->id, true) == OperationStatus::completed,
        "the revoked call should record the successful EOT result");
    check(router.snapshot().media_owner == MediaOwner::tx_draining &&
          router.complete_tx_cleanup(started.lease->id, true) == OperationStatus::completed,
        "the revoked call releases its owner only after local cleanup confirmation");

    auto enabled_again = disabled;
    enabled_again.transmit_enabled = true;
    enabled_again.dynamic_join_enabled = true;
    check(install_tx(router, enabled_again), "TX permission may be re-enabled after drain");
    check(router.begin_ptt().status == TxStartStatus::ptt_release_required,
        "re-enabling while the original PTT is still held must wait for a physical release");
    check(router.observe_ptt_release() == OperationStatus::completed,
        "the observed physical PTT release should clear the safety latch");
    const auto next = router.begin_ptt();
    check(next && next.lease->target.destination_id == 3100U &&
          next.lease->target.kind == CallKind::group,
        "the next PTT uses the pending target only after release and EOT");

    Router join_router(local_id);
    auto join_policy = make_tx_policy(460997U);
    check(install_tx(join_router, join_policy), "dynamic join policy should install");
    const auto quick_call = join_router.request_dynamic_join({3100U, Slot::ts2}, true);
    check(static_cast<bool>(quick_call), "explicit dynamic join should start its TX lease");
    auto join_disabled = join_policy;
    join_disabled.transmit_enabled = false;
    join_disabled.dynamic_join_enabled = false;
    const auto join_revoked = join_router.replace_tx_policy(
        join_router.snapshot().tx_policy_revision, join_disabled);
    check(join_revoked.stop_tx_lease_id == quick_call.lease->id &&
          join_router.snapshot().active_tx_lease->admission_revoked,
        "revoking permission should end an already started Quick call without retry");
    check(join_router.request_dynamic_join({3100U, Slot::ts2}, true).status == TxStartStatus::transmit_disabled,
        "revoked TX permission blocks later dynamic joins");
    check(join_router.complete_tx_eot(quick_call.lease->id, true) == OperationStatus::completed,
        "the existing Quick call records its current EOT result");
    check(join_router.complete_tx_cleanup(quick_call.lease->id, true) == OperationStatus::completed,
        "the existing Quick call releases only after local cleanup");
    check(!join_router.snapshot().ptt_release_required,
        "a dynamic Quick call does not latch the physical radio PTT release gate");

    Router forced_stop_router(local_id);
    check(install_tx(forced_stop_router, make_tx_policy(460997U)),
        "forced-stop TX policy should install");
    const auto forced = forced_stop_router.begin_ptt();
    check(forced && forced_stop_router.request_tx_stop(forced.lease->id) == OperationStatus::completed,
        "explicit forced stop should end TX admission without claiming a physical PTT release");
    check(forced_stop_router.snapshot().active_tx_lease &&
          !forced_stop_router.snapshot().active_tx_lease->ptt_release_seen,
        "forced stop must retain the lease's truthful PTT release observation");
    check(forced_stop_router.complete_tx_eot(forced.lease->id, true) == OperationStatus::completed &&
          forced_stop_router.complete_tx_cleanup(forced.lease->id, true) == OperationStatus::completed,
        "forced stop may release its lease after both EOT and local cleanup complete");
    check(forced_stop_router.begin_ptt().status == TxStartStatus::ptt_release_required,
        "a completed forced stop must still wait for physical PTT release");
    check(forced_stop_router.observe_ptt_release() == OperationStatus::completed &&
          static_cast<bool>(forced_stop_router.begin_ptt()),
        "only an observed physical release should permit the next PTT");
}

void test_failed_tx_eot_keeps_owner_until_cleanup_and_validates_lease_id()
{
    Router router(local_id);
    check(install_tx(router, make_tx_policy(460997U)), "TX policy should install");
    const auto started = router.begin_ptt();
    check(static_cast<bool>(started), "PTT should start before simulating EOT send failure");
    check(router.release_tx(started.lease->id) == OperationStatus::completed,
        "PTT release should enter TX drain");
    check(router.release_tx(started.lease->id + 1U) == OperationStatus::stale_lease,
        "a stale lease ID must not release the current TX");
    check(router.complete_tx_eot(started.lease->id, false) == OperationStatus::send_failed,
        "failed EOT should be surfaced distinctly");
    check(router.snapshot().media_owner == MediaOwner::fault &&
          router.snapshot().active_tx_lease->eot_sent == std::optional<bool>{false},
        "failed EOT must retain a faulted lease and truthful send result");
    check(router.begin_ptt().status == TxStartStatus::media_busy,
        "new PTT remains blocked until failed TX cleanup is acknowledged");
    check(router.complete_tx_cleanup(started.lease->id, false) == OperationStatus::cleanup_failed,
        "failed cleanup keeps the TX fault active");
    check(router.complete_tx_cleanup(started.lease->id, true) == OperationStatus::send_failed,
        "local cleanup cannot erase a failed EOT send result");
    check(router.snapshot().media_owner == MediaOwner::fault &&
          router.begin_ptt().status == TxStartStatus::media_busy,
        "a failed EOT keeps the owner faulted even after local cleanup");
}

void test_invalid_policy_and_target_updates_are_atomic()
{
    Router router(local_id);
    RxPolicy invalid{};
    invalid.allowed_groups = {{91U, static_cast<Slot>(3U)}};
    const auto before_rx = router.snapshot().rx_policy_revision;
    check(router.replace_rx_policy(before_rx, invalid).status == PolicyUpdateStatus::invalid_policy,
        "invalid media slot must reject the complete RX policy");
    check(router.snapshot().rx_policy_revision == before_rx && router.rx_policy().allowed_groups.empty(),
        "invalid RX update must not partially mutate policy");

    RxPolicy overlapping{};
    overlapping.allowed_groups = {{91U, Slot::ts2}};
    overlapping.blocked_groups = {{91U, Slot::ts2}};
    check(router.replace_rx_policy(before_rx, overlapping).status == PolicyUpdateStatus::invalid_policy,
        "the same group route cannot be both allowed and blocked");

    RxPolicy disabled_private{};
    disabled_private.private_mode = PrivateMode::disabled;
    disabled_private.local_private_routes = {{local_id, Slot::ts1}};
    check(router.replace_rx_policy(before_rx, disabled_private).status == PolicyUpdateStatus::invalid_policy,
        "disabled private mode must not retain active local or exact-peer routes");
    RxPolicy selected_with_local{};
    selected_with_local.private_mode = PrivateMode::selected_peers;
    selected_with_local.private_peers = {{460997U, local_id, Slot::ts2}};
    selected_with_local.local_private_routes = {{local_id, Slot::ts1}};
    check(router.replace_rx_policy(before_rx, selected_with_local).status == PolicyUpdateStatus::invalid_policy,
        "selected-peer mode must not widen admission with a local all-peers route");

    TxPolicy tx = make_tx_policy(460997U);
    tx.dynamic_join_blocked_group_ids = {91U, 91U};
    const auto before_tx = router.snapshot().tx_policy_revision;
    check(router.replace_tx_policy(before_tx, tx).status == PolicyUpdateStatus::invalid_policy,
        "duplicate dynamic-join deny IDs must reject TX policy");
    check(router.snapshot().tx_policy_revision == before_tx,
        "invalid TX update must not advance revision");

    check(!Router(0U).valid(), "router must reject a missing local radio ID");
    check(router.match_receive(make_call(1001U, 91U, Slot::ts2, CallKind::group)) == RouteMatch::policy_denied,
        "unconfigured selected policy should not receive arbitrary calls");
}

void test_revision_generation_and_lease_id_exhaustion_never_wraps()
{
    constexpr auto max_id = std::numeric_limits<std::uint64_t>::max();
    Router router(local_id);
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(install_rx(router, rx), "RX policy should install before forcing counter exhaustion");
    RouterTestAccess::set_rx_revision(router, max_id);
    const auto revision_result = router.replace_rx_policy(max_id, rx);
    check(revision_result.status == PolicyUpdateStatus::revision_exhausted &&
          router.snapshot().rx_policy_revision == max_id &&
          router.rx_policy().group_mode == GroupMode::all_delivered,
        "revision exhaustion must reject policy changes without wrapping or partially applying");

    RouterTestAccess::set_next_rx_generation(router, max_id);
    const auto last_rx = router.admit_rx(make_call(1001U, 91U, Slot::ts2, CallKind::group), true);
    check(last_rx.decision == RxDecision::admitted && last_rx.generation == max_id,
        "the maximum RX generation may be issued exactly once");
    check(router.request_rx_stop() == max_id &&
          router.complete_rx_stop(max_id, true) == OperationStatus::completed,
        "the maximum RX generation should still complete its cleanup lifecycle");
    const auto after_rx_exhaustion = router.admit_rx(make_call(1002U, 91U, Slot::ts2, CallKind::group, 2U), true);
    check(after_rx_exhaustion.decision == RxDecision::generation_exhausted &&
          router.snapshot().media_owner == MediaOwner::idle,
        "RX generation exhaustion must reject new calls instead of reusing an ID");

    Router tx_router(local_id);
    check(install_tx(tx_router, make_tx_policy(460997U)), "TX policy should install before lease exhaustion");
    RouterTestAccess::set_next_lease_id(tx_router, max_id);
    const auto last_lease = tx_router.begin_ptt();
    check(last_lease && last_lease.lease->id == max_id,
        "the maximum TX lease ID may be issued exactly once");
    check(tx_router.release_tx(max_id) == OperationStatus::completed &&
          tx_router.complete_tx_eot(max_id, true) == OperationStatus::completed,
        "the maximum TX lease should still complete its EOT lifecycle");
    check(tx_router.complete_tx_cleanup(max_id, true) == OperationStatus::completed,
        "maximum lease cleanup should complete before checking exhaustion");
    check(tx_router.begin_ptt().status == TxStartStatus::lease_id_exhausted &&
          tx_router.snapshot().media_owner == MediaOwner::idle,
        "lease ID exhaustion must reject new TX rather than reusing an ID");
}

} // 匿名命名空间

int main()
{
    test_selected_groups_and_slot_scoped_block();
    test_all_delivered_mode_and_blocks();
    test_private_peer_and_local_destination_are_distinct();
    test_all_local_private_routes_union_with_exact_peers_on_other_slots();
    test_candidate_observation_does_not_change_policy_or_claim_playback();
    test_single_stream_arbiter_keeps_owner_until_hri_stop_confirmation();
    test_policy_removal_cancels_rx_but_waits_for_cleanup();
    test_tx_target_is_frozen_and_rx_identity_never_rewrites_it();
    test_dynamic_join_requires_explicit_enabled_idle_and_allowed_target();
    test_permission_revocation_stops_active_tx_and_requires_ptt_release();
    test_failed_tx_eot_keeps_owner_until_cleanup_and_validates_lease_id();
    test_invalid_policy_and_target_updates_are_atomic();
    test_revision_generation_and_lease_id_exhaustion_never_wraps();

    if (failures != 0) {
        std::cerr << failures << " routing test(s) failed.\n";
        return EXIT_FAILURE;
    }
    std::cout << "talkgroup_routing_test: all checks passed\n";
    return EXIT_SUCCESS;
}
