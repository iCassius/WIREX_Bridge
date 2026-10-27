#include "wirex/bm_voice_pipeline.hpp"
#include "wirex/dmr_call.hpp"
#include "wirex/dmr_vocoder.hpp"
#include "wirex/hri_ptt_gate.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <optional>
#include <string_view>

namespace {

using namespace std::chrono_literals;
using wirex::bm_voice::BmVoicePipeline;
using wirex::bm_voice::Error;
using wirex::bm_voice::EventKind;
using wirex::bm_voice::PlaybackFrame;
using wirex::bm_voice::Readiness;
using wirex::bm_voice::TimePoint;
using wirex::dmr_call::CallConfig;
using wirex::dmr_call::CallKind;
using wirex::dmr_call::PacketKind;
using wirex::dmr_call::Slot;
using wirex::dmr_call::Transmitter;
using wirex::hri_ptt_gate::Action;
using wirex::hri_ptt_gate::Gate;
using wirex::hri_ptt_gate::Level;
using wirex::talkgroup_routing::GroupMode;
using wirex::talkgroup_routing::MediaOwner;
using wirex::talkgroup_routing::PrivateMode;
using wirex::talkgroup_routing::RxPolicy;
using wirex::talkgroup_routing::TxPolicy;
using wirex::talkgroup_routing::TxTarget;

constexpr std::uint32_t local_id = 4611355U;
int failures = 0;

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
                     std::uint8_t stream_tail)
{
    CallConfig call{};
    call.source_id = source;
    call.destination_id = destination;
    call.gateway_id = 0x001234U;
    call.stream_id = {{0x51U, 0x22U, 0x33U, stream_tail}};
    call.slot = slot;
    call.kind = kind;
    call.color_code = 3U;
    return call;
}

wirex::dmr_call::AmbeVoiceBurst make_silence_burst()
{
    wirex::dmr_vocoder::Encoder encoder;
    wirex::dmr_vocoder::PcmFrame pcm{};
    const auto codeword = encoder.encode(pcm);
    wirex::dmr_call::AmbeVoiceBurst burst{};
    for (std::size_t index = 0U; index < wirex::dmr_call::codewords_per_burst; ++index) {
        std::copy(codeword.begin(), codeword.end(),
                  burst.begin() + static_cast<std::ptrdiff_t>(index * codeword.size()));
    }
    return burst;
}

struct SyntheticSource {
    Transmitter transmitter;
    wirex::dmr_call::AmbeVoiceBurst burst{make_silence_burst()};

    bool start(const CallConfig& call, wirex::dmr_call::TxPacket& packet)
    {
        const auto result = transmitter.start(call);
        if (!result) return false;
        packet = result.packet;
        return true;
    }

    bool voice(wirex::dmr_call::TxPacket& packet)
    {
        const auto result = transmitter.voice(burst);
        if (!result) return false;
        packet = result.packet;
        return true;
    }

    bool finish(wirex::dmr_call::TxPacket& packet)
    {
        const auto result = transmitter.finish();
        if (!result) return false;
        packet = result.packet;
        return true;
    }
};

TxPolicy disabled_tx_policy()
{
    TxPolicy policy{};
    policy.target = TxTarget{460997U, CallKind::private_call, Slot::ts2};
    return policy;
}

TxPolicy enabled_tx_policy(std::uint32_t destination = 460997U,
                           CallKind kind = CallKind::private_call,
                           Slot slot = Slot::ts2)
{
    auto policy = disabled_tx_policy();
    policy.transmit_enabled = true;
    policy.dynamic_join_enabled = true;
    policy.target = TxTarget{destination, kind, slot};
    return policy;
}

bool enable_routing(BmVoicePipeline& pipeline,
                    const RxPolicy& rx,
                    const TxPolicy& tx = disabled_tx_policy())
{
    return pipeline.enable_routing(local_id, rx, tx) == Error::none;
}

bool feed_header(BmVoicePipeline& pipeline,
                 const CallConfig& call,
                 TimePoint now,
                 Error expected = Error::none)
{
    SyntheticSource source;
    wirex::dmr_call::TxPacket header{};
    if (!source.start(call, header)) return false;
    return pipeline.ingest_rx(header.datagram, now).error == expected;
}

bool route_admits(const RxPolicy& policy, const CallConfig& call)
{
    BmVoicePipeline pipeline;
    if (!enable_routing(pipeline, policy)) return false;
    return feed_header(pipeline, call, TimePoint{} + 10s) &&
           pipeline.routing_snapshot().router.media_owner == MediaOwner::rx_active;
}

bool route_rejects(const RxPolicy& policy, const CallConfig& call)
{
    BmVoicePipeline pipeline;
    if (!enable_routing(pipeline, policy)) return false;
    SyntheticSource source;
    wirex::dmr_call::TxPacket header{};
    if (!source.start(call, header)) return false;
    const auto result = pipeline.ingest_rx(header.datagram, TimePoint{} + 10s).error;
    return result != Error::none &&
           pipeline.routing_snapshot().router.media_owner == MediaOwner::idle &&
           !pipeline.routing_snapshot().active_rx_mapping;
}

bool take_event(BmVoicePipeline& pipeline, EventKind wanted)
{
    bool found = false;
    while (const auto event = pipeline.take_event()) {
        found = found || event->kind == wanted;
    }
    return found;
}

void test_routed_receive_waits_for_lc_and_keeps_one_owner_through_hri_stop()
{
    BmVoicePipeline pipeline;
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(enable_routing(pipeline, rx, enabled_tx_policy()), "routed pipeline should enable policies");

    const auto start = TimePoint{} + 100s;
    const auto first_call = make_call(1001U, 3100U, Slot::ts2, CallKind::group, 1U);
    SyntheticSource first;
    wirex::dmr_call::TxPacket packet{};
    check(first.start(first_call, packet), "synthetic source should produce a DMRD stream");

    // Late entry begins with voice sync. Embedded LC validation arrives four bursts later.
    check(first.voice(packet), "voice sync A should be generated by the real DMR transmitter");
    auto received = pipeline.ingest_rx(packet.datagram, start);
    auto state = pipeline.routing_snapshot();
    check(received.error == Error::filtered && state.router.media_owner == MediaOwner::idle &&
          !state.active_rx_mapping,
          "voice sync A alone must remain a candidate without claiming media or opening playback");
    PlaybackFrame frame{};
    check(!pipeline.take_playback_pcm(frame), "unvalidated late entry must not deliver PCM to fake HRI");

    bool lc_admitted = false;
    TimePoint now = start;
    for (std::uint8_t index = 0U; index < 5U; ++index) {
        now += 1ms;
        check(first.voice(packet), "late-entry voice burst should be generated");
        received = pipeline.ingest_rx(packet.datagram, now);
        state = pipeline.routing_snapshot();
        if (state.active_rx_mapping) {
            lc_admitted = true;
            break;
        }
        check(state.router.media_owner == MediaOwner::idle,
              "partial embedded LC must not reserve the media owner");
        check(!pipeline.take_playback_pcm(frame),
              "partial embedded LC must not reach playback before LC validation");
    }
    check(lc_admitted && received.error == Error::none,
          "validated embedded LC should admit the routed stream");
    state = pipeline.routing_snapshot();
    const auto mapping = state.active_rx_mapping;
    const auto router_generation = mapping ? mapping->router_generation : 0U;
    const auto pipeline_generation = mapping ? mapping->pipeline_generation : 0U;
    check(mapping && mapping->router_generation != 0U && mapping->pipeline_generation != 0U &&
          state.router.active_rx_call && state.router.active_rx_call->source_id == first_call.source_id &&
          state.router.active_rx_call->destination_id == first_call.destination_id,
          "RX ownership should retain explicit router and pipeline generation mapping");
    check(take_event(pipeline, EventKind::receive_started),
          "validated late-entry should produce a receive-start event for fake HRI");
    check(pipeline.playback_ready(now) == Error::none,
          "fake HRI should acknowledge playback readiness only after route admission");

    const auto competing_call = make_call(2002U, 46001U, Slot::ts2, CallKind::group, 2U);
    SyntheticSource competitor;
    wirex::dmr_call::TxPacket competing_header{};
    check(competitor.start(competing_call, competing_header), "competing stream header should be generated");
    now += 1ms;
    const auto competing_result = pipeline.ingest_rx(competing_header.datagram, now);
    state = pipeline.routing_snapshot();
    check(competing_result.error != Error::none && state.active_rx_mapping &&
          state.active_rx_mapping->router_generation == router_generation &&
          state.router.active_rx_call && state.router.active_rx_call->source_id == first_call.source_id &&
          pipeline.snapshot().receive_call.source_id == first_call.source_id,
          "a different TG on the same slot must be discarded before it replaces the active receiver");

    check(first.voice(packet), "owner stream continuation should be generated");
    now += 1ms;
    check(pipeline.ingest_rx(packet.datagram, now).error == Error::none,
          "the original owner stream should remain accepted after a competing header");
    check(first.finish(packet), "owner stream terminator should be generated");
    now += 1ms;
    check(pipeline.ingest_rx(packet.datagram, now).error == Error::none,
          "the owner stream terminator should reach the real pipeline");
    state = pipeline.routing_snapshot();
    check(state.router.media_owner == MediaOwner::rx_draining &&
          pipeline.snapshot().receive_network_ended,
          "network EOT should start draining without releasing the RX owner");
    check(pipeline.begin_routed_tx(make_call(local_id, 999U, Slot::ts1, CallKind::group, 9U),
                                   Readiness{true, true}, now + 1ms) == Error::busy,
          "PTT must remain busy between network EOT and playback drain");

    std::optional<PlaybackFrame> held_ack;
    bool playback_drained = false;
    for (std::size_t attempt = 0U; attempt < 40U &&
         pipeline.routing_snapshot().router.media_owner == MediaOwner::rx_draining; ++attempt) {
        now += 60ms;
        (void)pipeline.tick(now);
        while (pipeline.take_playback_pcm(frame)) {
            if (!held_ack) {
                held_ack = frame;
            } else {
                check(pipeline.acknowledge_playback(frame.generation, 1U, now) == Error::none,
                      "fake HRI should acknowledge completed PCM frames");
            }
        }
        playback_drained = take_event(pipeline, EventKind::playback_drained) || playback_drained;
    }
    check(held_ack.has_value(), "fake HRI should retain one delayed playback completion");
    state = pipeline.routing_snapshot();
    check(!playback_drained && state.router.media_owner == MediaOwner::rx_draining &&
          pipeline.snapshot().rx_state == wirex::bm_voice::RxState::draining,
          "an outstanding playback acknowledgement must keep RX draining after EOT");

    if (held_ack) {
        check(pipeline.acknowledge_playback(held_ack->generation, 1U, now + 1ms) == Error::none,
              "fake HRI delayed playback acknowledgement should complete the final frame");
        playback_drained = take_event(pipeline, EventKind::playback_drained) || playback_drained;
    }
    state = pipeline.routing_snapshot();
    check(playback_drained && state.router.media_owner == MediaOwner::rx_stopping &&
          !state.active_rx_mapping && state.stopping_rx_mapping &&
          state.stopping_rx_mapping->pipeline_generation == pipeline_generation,
          "playback drain should request HRI stop and retain the owner until stop acknowledgement");
    check(pipeline.begin_routed_tx(make_call(local_id, 999U, Slot::ts1, CallKind::group, 10U),
                                   Readiness{true, true}, now + 2ms) == Error::busy,
          "PTT must remain busy while fake HRI stop is pending");
    check(pipeline.complete_routed_rx_cleanup(pipeline_generation, false) ==
              wirex::talkgroup_routing::OperationStatus::cleanup_failed,
          "failed fake HRI stop should leave a faulted owner");
    check(pipeline.begin_routed_tx(make_call(local_id, 999U, Slot::ts1, CallKind::group, 11U),
                                   Readiness{true, true}, now + 3ms) == Error::busy,
          "failed RX cleanup must continue to block PTT");
    check(pipeline.complete_routed_rx_cleanup(pipeline_generation, true) ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "successful retry of fake HRI stop should release the RX owner");
}

void test_route_union_blocks_and_stale_generation_cleanup()
{
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    rx.blocked_groups = {{91U, Slot::ts2}};
    rx.blocked_source_ids = {7777U};
    rx.private_mode = PrivateMode::all_peers_to_local;
    rx.local_private_routes = {{local_id, Slot::ts1}};
    rx.private_peers = {{460997U, local_id, Slot::ts2}};

    check(route_admits(rx, make_call(1001U, 3100U, Slot::ts1, CallKind::group, 1U)),
          "AllDelivered should admit an unblocked group without a route entry");
    check(route_rejects(rx, make_call(1001U, 91U, Slot::ts2, CallKind::group, 2U)),
          "route-level group block should override AllDelivered");
    check(route_rejects(rx, make_call(7777U, 3100U, Slot::ts1, CallKind::group, 3U)),
          "source block should override an otherwise accepted AllDelivered group");
    check(route_admits(rx, make_call(1234U, local_id, Slot::ts1, CallKind::private_call, 4U)),
          "all-local private route should accept a peer on its configured timeslot");
    check(route_admits(rx, make_call(460997U, local_id, Slot::ts2, CallKind::private_call, 5U)),
          "an exact private peer on another timeslot should union with the local route");
    check(route_rejects(rx, make_call(1234U, local_id, Slot::ts2, CallKind::private_call, 6U)),
          "the exact peer route must not become all-peers on its timeslot");
    check(route_rejects(rx, make_call(7777U, local_id, Slot::ts1, CallKind::private_call, 7U)),
          "source block should also suppress the all-local private route");

    BmVoicePipeline pipeline;
    check(enable_routing(pipeline, rx), "lifecycle pipeline should accept the union policy");
    const auto call = make_call(1001U, 3100U, Slot::ts1, CallKind::group, 8U);
    SyntheticSource source;
    wirex::dmr_call::TxPacket header{};
    check(source.start(call, header), "cancellation stream header should be generated");
    auto now = TimePoint{} + 200s;
    check(pipeline.ingest_rx(header.datagram, now).error == Error::none,
          "allowed cancellation stream should acquire routed ownership");
    const auto old = pipeline.routing_snapshot().active_rx_mapping;
    const auto old_router_generation = old ? old->router_generation : 0U;
    const auto old_pipeline_generation = old ? old->pipeline_generation : 0U;
    check(old && pipeline.playback_ready(now) == Error::none,
          "fake HRI should start the allowed cancellation stream");

    wirex::dmr_call::TxPacket voice{};
    check(source.voice(voice), "voice sync for cancellation stream should be generated");
    now += 1ms;
    (void)pipeline.ingest_rx(voice.datagram, now);
    check(source.voice(voice), "voice for cancellation stream should be generated");
    now += 1ms;
    (void)pipeline.ingest_rx(voice.datagram, now);
    now += 60ms;
    (void)pipeline.tick(now);
    PlaybackFrame delayed{};
    const bool has_delayed_frame = pipeline.take_playback_pcm(delayed);
    if (has_delayed_frame) {
        check(delayed.generation == old_pipeline_generation,
              "fake HRI callback should carry the currently mapped pipeline generation");
    }

    auto blocked = rx;
    blocked.blocked_source_ids.push_back(call.source_id);
    const auto revision = pipeline.routing_snapshot().router.rx_policy_revision;
    const auto update = pipeline.replace_rx_policy(revision, blocked);
    check(update && update.cancelled_rx_generation == old_router_generation,
          "revoking the active source should request outer cleanup for its router generation");
    auto state = pipeline.routing_snapshot();
    check(state.router.media_owner == MediaOwner::rx_stopping && state.stopping_rx_mapping &&
          state.stopping_rx_mapping->pipeline_generation == old_pipeline_generation,
          "policy cancellation must retain the owner while fake HRI cleanup is pending");
    check(pipeline.complete_routed_rx_cleanup(old_pipeline_generation, true) ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "fake HRI should confirm cleanup for the canceled generation");

    if (has_delayed_frame) {
        now += 1ms;
        check(pipeline.acknowledge_playback(delayed.generation, 1U, now) == Error::stale_playback_ack,
              "late playback acknowledgement from the canceled generation must be rejected");
    }
    check(pipeline.complete_routed_rx_cleanup(old_pipeline_generation, true) ==
              wirex::talkgroup_routing::OperationStatus::stale_generation,
          "duplicate cleanup acknowledgement for the old pipeline generation must be rejected");

    check(source.voice(voice), "blocked stream continuation should be generated");
    now += 1ms;
    check(pipeline.ingest_rx(voice.datagram, now).error != Error::none &&
          pipeline.routing_snapshot().router.media_owner == MediaOwner::idle &&
          !pipeline.routing_snapshot().active_rx_mapping,
          "same-stream voice after cancellation must not create a new routed call");

    const auto next_call = make_call(2002U, 3100U, Slot::ts1, CallKind::group, 9U);
    check(feed_header(pipeline, next_call, now + 1ms),
          "a fresh allowed stream may start after cleanup");
    state = pipeline.routing_snapshot();
    check(state.active_rx_mapping && state.active_rx_mapping->router_generation > old_router_generation &&
          state.active_rx_mapping->pipeline_generation != old_pipeline_generation &&
          state.router.media_owner == MediaOwner::rx_active,
          "new stream should use fresh generations after cancellation");
    check(pipeline.complete_routed_rx_cleanup(old_pipeline_generation, true) ==
              wirex::talkgroup_routing::OperationStatus::stale_generation &&
          pipeline.routing_snapshot().router.media_owner == MediaOwner::rx_active,
          "late cleanup acknowledgement must not release the newer stream owner");
}

void test_retired_stream_is_extended_by_packets_and_expires_after_silence()
{
    BmVoicePipeline pipeline;
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(enable_routing(pipeline, rx), "retired-stream policy should enable");
    auto now = TimePoint{} + 250s;
    const auto call = make_call(3003U, 3100U, Slot::ts1, CallKind::group, 13U);
    SyntheticSource source;
    wirex::dmr_call::TxPacket header{};
    check(source.start(call, header) && pipeline.ingest_rx(header.datagram, now).error == Error::none,
          "retired-stream case should acquire an allowed RX owner");
    const auto mapping = pipeline.routing_snapshot().active_rx_mapping;
    const auto pipeline_generation = mapping ? mapping->pipeline_generation : 0U;
    check(mapping.has_value(), "retired-stream case should have a pipeline generation");

    pipeline.cancel_rx();
    check(pipeline.routing_snapshot().router.media_owner == MediaOwner::rx_stopping,
          "cancel should keep RX ownership until outer cleanup is acknowledged");
    check(pipeline.complete_routed_rx_cleanup(pipeline_generation, true) ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "fake HRI should acknowledge canceled-stream cleanup");

    wirex::dmr_call::TxPacket voice{};
    bool all_continuations_rejected = true;
    for (std::size_t index = 0U; index < 40U; ++index) {
        check(source.voice(voice), "retired stream should continue producing DMRD voice packets");
        now += 60ms;
        const auto result = pipeline.ingest_rx(voice.datagram, now);
        all_continuations_rejected = all_continuations_rejected && result.error != Error::none &&
            pipeline.routing_snapshot().router.media_owner == MediaOwner::idle;
    }
    check(all_continuations_rejected,
          "continuous packets for a canceled stream must refresh retirement and never reclaim the lane");

    now += 2s + 1ms;
    SyntheticSource restarted;
    check(restarted.start(call, header) && pipeline.ingest_rx(header.datagram, now).error == Error::none,
          "a fresh call start may be admitted after the retired stream has been silent past its window");
    const auto fresh = pipeline.routing_snapshot().active_rx_mapping;
    check(fresh && fresh->router_generation > (mapping ? mapping->router_generation : 0U) &&
          fresh->pipeline_generation != pipeline_generation,
          "the silent-expiry call should receive new router and pipeline generations");
}

void test_late_packet_times_out_unstarted_playback_without_tick()
{
    BmVoicePipeline pipeline;
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(enable_routing(pipeline, rx), "playback-timeout policy should enable");
    const auto start = TimePoint{} + 275s;
    const auto call = make_call(4004U, 3100U, Slot::ts2, CallKind::group, 14U);
    SyntheticSource source;
    wirex::dmr_call::TxPacket header{};
    check(source.start(call, header) && pipeline.ingest_rx(header.datagram, start).error == Error::none,
          "validated header should reserve an RX owner before playback opens");
    const auto active = pipeline.routing_snapshot().active_rx_mapping;
    const auto pipeline_generation = active ? active->pipeline_generation : 0U;
    check(active && pipeline.snapshot().rx_state == wirex::bm_voice::RxState::waiting_for_playback,
          "header-only admission should wait for the fake HRI playback-ready acknowledgement");

    wirex::dmr_call::TxPacket late_voice{};
    check(source.voice(late_voice), "late continuation packet should be generated");
    const auto late_time = start + wirex::bm_voice::receive_start_timeout + 1ms;
    const auto late = pipeline.ingest_rx(late_voice.datagram, late_time);
    auto state = pipeline.routing_snapshot();
    check(late.error == Error::playback_start_timeout &&
          state.router.media_owner == MediaOwner::rx_stopping &&
          !state.active_rx_mapping && state.stopping_rx_mapping &&
          state.stopping_rx_mapping->pipeline_generation == pipeline_generation &&
          pipeline.snapshot().rx_state == wirex::bm_voice::RxState::stopping,
          "a post-deadline packet must time out playback even without an outer tick and request HRI cleanup");
    check(take_event(pipeline, EventKind::playback_start_timeout),
          "the no-tick timeout should publish a playback-start timeout event");
    PlaybackFrame frame{};
    check(!pipeline.take_playback_pcm(frame),
          "a stream that timed out before HRI readiness must not deliver PCM");
    check(pipeline.complete_routed_rx_cleanup(pipeline_generation, true) ==
              wirex::talkgroup_routing::OperationStatus::completed &&
          pipeline.routing_snapshot().router.media_owner == MediaOwner::idle,
          "fake HRI cleanup acknowledgement should release the timed-out owner");
}

void test_routed_tx_target_permission_and_cleanup_gates()
{
    BmVoicePipeline pipeline;
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    auto tx = enabled_tx_policy();
    check(enable_routing(pipeline, rx, tx), "routed TX policy should enable");
    const auto start = TimePoint{} + 300s;
    auto identity = make_call(local_id, 999U, Slot::ts1, CallKind::group, 10U);
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start) == Error::none,
          "PTT should acquire a lease when both BM and HRI are ready");
    auto state = pipeline.routing_snapshot();
    check(state.router.active_tx_lease &&
          state.router.active_tx_lease->target == TxTarget{460997U, CallKind::private_call, Slot::ts2},
          "routed TX lease should freeze the configured target");
    const auto header = pipeline.take_outbound();
    check(header && header->kind == PacketKind::voice_lc_header &&
          header->datagram.destination_id == 460997U &&
          (header->datagram.flags & 0x3fU) == 0x21U &&
          (header->datagram.flags & 0xc0U) == 0xc0U,
          "routed TX header uses the actual DMRD voice-LC type and frozen lease target");

    auto next_policy = tx;
    next_policy.target = TxTarget{3100U, CallKind::group, Slot::ts1};
    const auto changed = pipeline.replace_tx_policy(state.router.tx_policy_revision, next_policy);
    check(changed && !changed.stop_tx_lease_id,
          "changing the configured target should affect only the next PTT lease");
    state = pipeline.routing_snapshot();
    const auto lease = state.router.active_tx_lease;
    check(lease && lease->target == TxTarget{460997U, CallKind::private_call, Slot::ts2},
          "active lease target must remain frozen after policy replacement");

    check(pipeline.stop_tx(start + 1ms) == Error::none,
          "strong stop should discard pending PCM and queue a terminator");
    const auto terminator = pipeline.take_outbound();
    check(terminator && terminator->kind == PacketKind::terminator_with_lc &&
          terminator->datagram.destination_id == 460997U &&
          (terminator->datagram.flags & 0xc0U) == 0xc0U,
          "strong-stop terminator should retain the active lease target");
    check(lease && pipeline.complete_routed_tx_eot(lease->id, true) ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "fake BM send acknowledgement should report successful EOT");
    check(pipeline.routing_snapshot().router.media_owner == MediaOwner::tx_draining &&
          pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 2ms) == Error::busy,
          "successful EOT must keep the lane owned until local TX cleanup is acknowledged");
    check(lease && pipeline.complete_routed_tx_cleanup(lease->id, false) ==
              wirex::talkgroup_routing::OperationStatus::cleanup_failed &&
          pipeline.routing_snapshot().router.media_owner == MediaOwner::fault,
          "failed local TX cleanup should preserve a faulted owner");
    check(lease && pipeline.complete_routed_tx_cleanup(lease->id, true) ==
              wirex::talkgroup_routing::OperationStatus::completed &&
          pipeline.routing_snapshot().router.media_owner == MediaOwner::idle,
          "successful cleanup retry should release a successful-EOT lease");
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 3ms) == Error::busy,
          "strong stop must not be treated as proof that the physical PTT was released");
    check(pipeline.observe_routed_ptt_release() ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "fake hardware should report the physical PTT release separately");

    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 4ms) == Error::none,
          "a new PTT may start after cleanup and physical release");
    state = pipeline.routing_snapshot();
    const auto next_lease = state.router.active_tx_lease;
    const auto next_header = pipeline.take_outbound();
    check(next_lease && next_lease->target == next_policy.target && next_header &&
          next_header->datagram.destination_id == 3100U &&
          (next_header->datagram.flags & 0xc0U) == 0U,
          "the updated target should be used by the next call only");

    TxPolicy disabled = next_policy;
    disabled.transmit_enabled = false;
    disabled.dynamic_join_enabled = false;
    const auto revoked = pipeline.replace_tx_policy(state.router.tx_policy_revision, disabled);
    check(revoked && next_lease && revoked.stop_tx_lease_id == next_lease->id,
          "revoking TX permission should stop the active lease immediately");
    const auto revoked_eot = pipeline.take_outbound();
    check(revoked_eot && revoked_eot->kind == PacketKind::terminator_with_lc &&
          revoked_eot->datagram.destination_id == 3100U,
          "permission revocation should stop the current target without rewriting its terminator");
    check(next_lease && pipeline.complete_routed_tx_eot(next_lease->id, true) ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "revoked lease should wait for its actual EOT send result");
    check(next_lease && pipeline.complete_routed_tx_cleanup(next_lease->id, true) ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "revoked lease cleanup should complete after successful EOT");
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 5ms) == Error::busy,
          "disabled permission must reject a new lease");

    auto reenabled = next_policy;
    state = pipeline.routing_snapshot();
    check(static_cast<bool>(pipeline.replace_tx_policy(state.router.tx_policy_revision, reenabled)),
          "TX permission may be restored after the revoked lease drains");
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 6ms) == Error::busy,
          "restoring permission while PTT remains held must wait for hardware release");
    check(pipeline.observe_routed_ptt_release() ==
              wirex::talkgroup_routing::OperationStatus::completed,
          "observed physical PTT release should clear the safety latch");
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 7ms) == Error::none,
          "TX should resume only after permission and physical release are both confirmed");
}

void test_permission_revocation_preserves_held_lease_eot()
{
    using namespace wirex::talkgroup_routing;
    using namespace wirex::bm_voice;
    using wirex::dmr_call::CallKind;
    using wirex::dmr_call::Slot;
    const auto start = TimePoint{} + 350s;
    const auto identity = make_call(local_id, 999U, Slot::ts1, CallKind::group, 16U);
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;

    BmVoicePipeline header_pending;
    const auto enabled = enabled_tx_policy(3100U, CallKind::group, Slot::ts1);
    check(enable_routing(header_pending, rx, enabled), "header-pending policy should enable");
    check(header_pending.begin_routed_tx(identity, Readiness{true, true}, start) == Error::none,
          "header-pending PTT should acquire a lease");
    auto state = header_pending.routing_snapshot();
    const auto pending_lease = state.router.active_tx_lease;
    auto disabled = enabled;
    disabled.transmit_enabled = false;
    const auto header_revoke = header_pending.replace_tx_policy(state.router.tx_policy_revision, disabled);
    check(header_revoke && pending_lease && header_revoke.stop_tx_lease_id == pending_lease->id &&
          !header_pending.routed_tx_voice_permitted(),
          "revoking before the first header marks the lease revoked and blocks voice");
    const auto retained_header = header_pending.take_outbound();
    const auto retained_eot = header_pending.take_outbound();
    check(retained_header && retained_header->kind == wirex::dmr_call::PacketKind::voice_lc_header &&
          (retained_header->datagram.flags & 0x3fU) == 0x21U && retained_eot &&
          retained_eot->kind == wirex::dmr_call::PacketKind::terminator_with_lc &&
          (retained_eot->datagram.flags & 0x3fU) == 0x22U,
          "an already-held lease may send its actual header and EOT after permission revocation");

    auto reenabled = enabled;
    state = header_pending.routing_snapshot();
    check(static_cast<bool>(header_pending.replace_tx_policy(state.router.tx_policy_revision, reenabled)) &&
          !header_pending.routed_tx_voice_permitted() &&
          header_pending.routing_snapshot().router.active_tx_lease->admission_revoked,
          "restoring global permission cannot revive an already-revoked lease");
    check(pending_lease && header_pending.complete_routed_tx_eot(pending_lease->id, true) ==
              OperationStatus::completed &&
          header_pending.complete_routed_tx_cleanup(pending_lease->id, true) ==
              OperationStatus::completed,
          "the revoked header-pending lease completes only after actual EOT and local cleanup");
    check(header_pending.begin_routed_tx(identity, Readiness{true, true}, start + 1ms) == Error::busy,
          "permission restoration cannot bypass the still-held physical PTT lock");
    check(header_pending.observe_routed_ptt_release() == OperationStatus::completed &&
          header_pending.begin_routed_tx(identity, Readiness{true, true}, start + 2ms) == Error::none,
          "a new lease may start after cleanup and a separate physical PTT release");

    BmVoicePipeline draining;
    check(enable_routing(draining, rx, enabled), "draining policy should enable");
    check(draining.begin_routed_tx(identity, Readiness{true, true}, start) == Error::none,
          "draining PTT should acquire a lease");
    const auto sent_header = draining.take_outbound();
    std::array<std::int16_t, max_tx_audio_samples_per_push> pcm{};
    check(sent_header && draining.push_tx_audio(pcm.data(), pcm.size(), start + 1ms),
          "draining fixture queues voice PCM after its header");
    check(draining.end_tx(start + 2ms) == Error::none &&
          draining.snapshot().tx_state == TxState::draining,
          "physical PTT release leaves queued voice in the draining phase");
    state = draining.routing_snapshot();
    const auto draining_lease = state.router.active_tx_lease;
    const auto draining_revoke = draining.replace_tx_policy(state.router.tx_policy_revision, disabled);
    check(draining_revoke && draining_lease && draining_revoke.stop_tx_lease_id == draining_lease->id &&
          !draining.routed_tx_voice_permitted(),
          "permission revocation also stops a lease that is already draining");
    bool saw_eot = false;
    bool saw_voice = false;
    while (const auto packet = draining.take_outbound()) {
        saw_eot = saw_eot || packet->kind == wirex::dmr_call::PacketKind::terminator_with_lc;
        saw_voice = saw_voice || packet->kind == wirex::dmr_call::PacketKind::voice;
    }
    check(saw_eot && !saw_voice,
          "draining revocation drops queued voice tail but retains the old lease EOT");
    state = draining.routing_snapshot();
    check(static_cast<bool>(draining.replace_tx_policy(state.router.tx_policy_revision, reenabled)) &&
          !draining.routed_tx_voice_permitted() &&
          draining.routing_snapshot().router.active_tx_lease->admission_revoked,
          "reenabling before cleanup does not reauthorize the previous lease tail");
    check(draining_lease && draining.complete_routed_tx_eot(draining_lease->id, true) ==
              OperationStatus::completed &&
          draining.complete_routed_tx_cleanup(draining_lease->id, true) ==
              OperationStatus::completed &&
          draining.begin_routed_tx(identity, Readiness{true, true}, start + 3ms) == Error::none,
          "released draining lease cleanup allows a new call under the restored policy");
}

void test_ptt_gate_stays_ready_while_routed_tx_owns_the_lane()
{
    BmVoicePipeline pipeline;
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(enable_routing(pipeline, rx, enabled_tx_policy(3100U, CallKind::group, Slot::ts1)),
          "PTT integration policy should enable");
    Gate gate;
    check(gate.set_ready(true) == Action::none &&
          gate.observe(Level::released, true) == Action::none,
          "endpoint readiness and a real release should arm the PTT gate");

    const auto start = TimePoint{} + 500s;
    const auto identity = make_call(local_id, 0U, Slot::ts2, CallKind::private_call, 12U);
    check(gate.observe(Level::pressed, true) == Action::start_tx,
          "fresh permitted PTT press should request the routed TX start");
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start) == Error::none,
          "routed TX should start with ready BM and HRI endpoints");
    check(gate.start_succeeded(100U), "PTT gate should mark successful pipeline startup");
    auto state = pipeline.routing_snapshot();
    const auto lease = state.router.active_tx_lease;
    check(lease && state.router.media_owner == MediaOwner::tx_active,
          "the TX lease should own the half-duplex lane while PTT is held");

    const bool endpoints_ready = true;
    const bool new_tx_permitted = state.router.media_owner == MediaOwner::idle;
    check(!new_tx_permitted, "the occupied owner should reject a second TX start");
    check(gate.set_ready(endpoints_ready) == Action::none &&
          gate.observe(Level::pressed, new_tx_permitted) == Action::none &&
          gate.snapshot().tx_active,
          "busy media must not lower endpoint readiness or abort a continuing pressed PTT");

    std::array<std::int16_t, wirex::bm_voice::max_tx_audio_samples_per_push> audio{};
    check(static_cast<bool>(pipeline.push_tx_audio(audio.data(), audio.size(), start + 1ms)),
          "real codec pipeline should accept fake in-memory microphone PCM");
    check(gate.observe(Level::released, true) == Action::end_tx,
          "a real released PTT level should request one normal TX end");
    const auto release_time = start + 2ms;
    check(pipeline.end_tx(release_time) == Error::none,
          "normal PTT release should end the frozen lease through pipeline drain");

    bool eot_seen = false;
    TimePoint now = release_time;
    for (std::size_t attempt = 0U; attempt < 8U && !eot_seen; ++attempt) {
        now += 60ms;
        (void)pipeline.tick(now);
        while (const auto packet = pipeline.take_outbound()) {
            if (packet->kind == PacketKind::terminator_with_lc) {
                eot_seen = true;
                check(packet->datagram.destination_id == 3100U,
                      "normal PTT EOT should retain the lease's routed target");
            }
        }
    }
    check(eot_seen && lease.has_value(),
          "fake BM transport should observe the normal PTT terminator");
    if (lease) {
        check(pipeline.complete_routed_tx_eot(lease->id, true) ==
                  wirex::talkgroup_routing::OperationStatus::completed,
              "fake BM transport should acknowledge the normal PTT EOT");
        check(pipeline.complete_routed_tx_cleanup(lease->id, true) ==
                  wirex::talkgroup_routing::OperationStatus::completed,
              "fake audio cleanup should release the TX owner after EOT");
    }
    check(pipeline.routing_snapshot().router.media_owner == MediaOwner::idle &&
          gate.observe(Level::pressed, true) == Action::start_tx,
          "a fresh press should be accepted after release, EOT, and cleanup");
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, now + 1ms) == Error::none,
          "the next real routed TX lease should start after the preceding cleanup");
}

void test_failed_eot_remains_faulted_after_cleanup_attempt()
{
    BmVoicePipeline pipeline;
    RxPolicy rx{};
    rx.group_mode = GroupMode::all_delivered;
    check(enable_routing(pipeline, rx, enabled_tx_policy()), "failed-EOT policy should enable");
    const auto start = TimePoint{} + 400s;
    const auto identity = make_call(local_id, 999U, Slot::ts1, CallKind::group, 11U);
    check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start) == Error::none,
          "failed-EOT case should start a routed lease");
    const auto lease = pipeline.routing_snapshot().router.active_tx_lease;
    check(lease.has_value(), "failed-EOT case should expose its lease ID");
    check(pipeline.stop_tx(start + 1ms) == Error::none,
          "failed-EOT case should queue a terminator before send failure");
    (void)pipeline.take_outbound();
    if (lease) {
        check(pipeline.complete_routed_tx_eot(lease->id, false) ==
                  wirex::talkgroup_routing::OperationStatus::send_failed,
              "failed BM EOT send should be reported distinctly");
        check(pipeline.complete_routed_tx_cleanup(lease->id, true) !=
                  wirex::talkgroup_routing::OperationStatus::completed &&
              pipeline.routing_snapshot().router.media_owner == MediaOwner::fault,
              "local cleanup cannot erase a failed-EOT fault or reopen TX");
        check(pipeline.begin_routed_tx(identity, Readiness{true, true}, start + 2ms) == Error::busy,
              "failed-EOT owner must block new TX after cleanup is attempted");
    }
}

} // namespace

int main()
{
    test_routed_receive_waits_for_lc_and_keeps_one_owner_through_hri_stop();
    test_route_union_blocks_and_stale_generation_cleanup();
    test_retired_stream_is_extended_by_packets_and_expires_after_silence();
    test_late_packet_times_out_unstarted_playback_without_tick();
    test_routed_tx_target_permission_and_cleanup_gates();
    test_permission_revocation_preserves_held_lease_eot();
    test_ptt_gate_stays_ready_while_routed_tx_owns_the_lane();
    test_failed_eot_remains_faulted_after_cleanup_attempt();
    if (failures != 0) {
        std::cerr << failures << " 个离线路由生命周期检查失败。\n";
        return 1;
    }
    std::cout << "bm_routing_lifecycle_test: all checks passed\n";
    return 0;
}
