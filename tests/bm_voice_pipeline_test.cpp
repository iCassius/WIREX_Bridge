#include "wirex/bm_voice_pipeline.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

using namespace std::chrono_literals;
using wirex::bm_voice::BmVoicePipeline;
using wirex::bm_voice::Error;
using wirex::bm_voice::EventKind;
using wirex::bm_voice::PlaybackFrame;
using wirex::bm_voice::Readiness;
using wirex::bm_voice::TimePoint;

[[nodiscard]] bool require(bool condition, const char* message)
{
    if (!condition) {
        std::cerr << message << '\n';
    }
    return condition;
}

[[nodiscard]] wirex::dmr_call::CallConfig make_call(std::uint32_t source,
                                                   std::uint32_t destination,
                                                   std::uint8_t stream_tail,
                                                   wirex::dmr_call::Slot slot = wirex::dmr_call::Slot::ts1,
                                                   wirex::dmr_call::CallKind kind = wirex::dmr_call::CallKind::group)
{
    wirex::dmr_call::CallConfig call{};
    call.source_id = source;
    call.destination_id = destination;
    call.gateway_id = 0x001234U;
    call.stream_id = {0x51U, 0x22U, 0x33U, stream_tail};
    call.slot = slot;
    call.kind = kind;
    call.color_code = 3U;
    return call;
}

[[nodiscard]] wirex::dmr_call::AmbeVoiceBurst test_burst()
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

struct RxSource {
    wirex::dmr_call::Transmitter transmitter;
    wirex::dmr_call::CallConfig call;
    wirex::dmr_call::AmbeVoiceBurst burst{test_burst()};

    [[nodiscard]] bool start(wirex::dmr_call::CallConfig config,
                             wirex::dmr_call::TxPacket& header)
    {
        call = config;
        const auto result = transmitter.start(call);
        if (!result) {
            return false;
        }
        header = result.packet;
        return true;
    }

    [[nodiscard]] bool voice(wirex::dmr_call::TxPacket& packet)
    {
        const auto result = transmitter.voice(burst);
        if (!result) {
            return false;
        }
        packet = result.packet;
        return true;
    }

    [[nodiscard]] bool finish(wirex::dmr_call::TxPacket& packet)
    {
        const auto result = transmitter.finish();
        if (!result) {
            return false;
        }
        packet = result.packet;
        return true;
    }
};

[[nodiscard]] bool drain_events(BmVoicePipeline& pipeline, EventKind expected)
{
    bool found = false;
    while (const auto event = pipeline.take_event()) {
        found = found || event->kind == expected;
    }
    return found;
}

[[nodiscard]] bool test_tx_pacing_and_drain()
{
    BmVoicePipeline pipeline;
    const auto start = TimePoint{} + 10s;
    const auto call = make_call(1001U, 91U, 1U);
    if (!require(pipeline.begin_tx(call, Readiness{false, true}, start) == Error::bm_not_ready,
                 "TX began before BM was ready") ||
        !require(pipeline.begin_tx(call, Readiness{true, false}, start) == Error::hri_not_ready,
                 "TX began before HRI was ready") ||
        !require(pipeline.begin_tx(call, Readiness{true, true}, start) == Error::none,
                 "TX did not begin when both endpoints were ready")) {
        return false;
    }
    auto invalid_call = call;
    invalid_call.source_id = 0U;
    BmVoicePipeline invalid_pipeline;
    if (!require(invalid_pipeline.begin_tx(invalid_call, Readiness{true, true}, start) == Error::invalid_call,
                 "pipeline accepted an invalid source ID")) {
        return false;
    }
    const auto header = pipeline.take_outbound();
    if (!require(header.has_value() && header->kind == wirex::dmr_call::PacketKind::voice_lc_header,
                 "TX did not produce a voice LC header")) {
        return false;
    }

    std::array<std::int16_t, wirex::bm_voice::max_tx_audio_samples_per_push> input{};
    for (std::size_t index = 0U; index < input.size(); ++index) {
        const auto value = static_cast<std::int32_t>((index % 200U) * 100U) - 10000;
        input[index] = static_cast<std::int16_t>(value);
    }
    const auto first = pipeline.push_tx_audio(input.data(), input.size(), start + 1ms);
    const auto second = pipeline.push_tx_audio(input.data(), input.size(), start + 2ms);
    if (!require(first.error == Error::none && first.encoded_frames == 5U,
                 "first 100ms TX audio block did not produce 5 codec frames") ||
        !require(second.error == Error::none && second.encoded_frames == 5U,
                 "second 100ms TX audio block did not produce 5 codec frames")) {
        return false;
    }

    if (!require(pipeline.tick(start + 59ms) == Error::none && !pipeline.take_outbound().has_value(),
                 "TX sent a voice burst before 60ms")) {
        return false;
    }
    if (!require(pipeline.tick(start + 61ms) == Error::none && !pipeline.take_outbound().has_value() &&
                 pipeline.tick(start + 62ms) == Error::none,
                 "TX did not wait for its bounded two-burst startup buffer")) {
        return false;
    }
    const auto first_voice = pipeline.take_outbound();
    if (!require(first_voice.has_value() && first_voice->kind == wirex::dmr_call::PacketKind::voice_sync,
                 "first voice burst did not carry DMR voice sync")) {
        return false;
    }

    if (!require(pipeline.end_tx(start + 63ms) == Error::none,
                 "TX could not flush and enter drain state")) {
        return false;
    }
    std::vector<wirex::dmr_call::PacketKind> packet_kinds;
    std::vector<TimePoint> voice_times{start + 62ms};
    for (int step = 2; step <= 5; ++step) {
        const auto now = start + std::chrono::milliseconds{step * 60 + 2};
        if (!require(pipeline.tick(now) == Error::none, "paced TX tick failed during drain")) {
            return false;
        }
        const auto packet = pipeline.take_outbound();
        if (packet) {
            packet_kinds.push_back(packet->kind);
            if (packet->kind == wirex::dmr_call::PacketKind::voice ||
                packet->kind == wirex::dmr_call::PacketKind::voice_sync) {
                voice_times.push_back(now);
            }
        }
    }
    const auto snapshot = pipeline.snapshot();
    if (!require(snapshot.tx_state == wirex::bm_voice::TxState::idle,
                 "TX did not return to idle after EOT") ||
        !require(!packet_kinds.empty() && packet_kinds.back() == wirex::dmr_call::PacketKind::terminator_with_lc,
                 "TX drain did not end with terminator-with-LC") ||
        !require(voice_times.size() == 4U, "TX did not send all final padded speech frames") ||
        !require(std::adjacent_find(voice_times.begin(), voice_times.end(),
                                    [](TimePoint left, TimePoint right) { return right - left != 60ms; }) ==
                 voice_times.end(), "TX voice bursts were not separated by 60ms")) {
        return false;
    }
    if (!require(pipeline.begin_tx(call, Readiness{true, true}, start + 500ms) == Error::none,
                 "TX could not re-enter after EOT was consumed")) {
        return false;
    }
    if (!require(pipeline.push_tx_audio(input.data(), input.size(), start + 501ms).error == Error::none &&
                 pipeline.tick(start + 560ms) == Error::none &&
                 pipeline.stop_tx(start + 561ms) == Error::none,
                 "TX stop did not drop media and create a network terminator")) {
        return false;
    }
    const auto stop_header = pipeline.take_outbound();
    const auto stop_eot = pipeline.take_outbound();
    if (!require(stop_header.has_value() &&
                 stop_header->kind == wirex::dmr_call::PacketKind::voice_lc_header &&
                 stop_eot.has_value() &&
                 stop_eot->kind == wirex::dmr_call::PacketKind::terminator_with_lc &&
                 stop_eot->datagram.stream_id == call.stream_id &&
                 stop_eot->datagram.sequence == 1U &&
                 !pipeline.take_outbound().has_value() &&
                 pipeline.snapshot().queued_tx_codewords == 0U,
                 "TX stop did not preserve call identity and emit only one EOT after its header")) {
        return false;
    }
    wirex::dmr_call::Receiver receiver;
    const auto receive_header = receiver.ingest(stop_header->datagram, start + 562ms);
    const auto receive_eot = receiver.ingest(stop_eot->datagram, start + 563ms);
    bool saw_end = false;
    for (std::size_t index = 0U; index < receive_eot.event_count; ++index) {
        saw_end = saw_end || receive_eot.events[index].kind == wirex::dmr_call::ReceiveEventKind::call_ended;
    }
    if (!require(receive_header.accepted() && receive_eot.accepted() && saw_end,
                 "TX stop EOT did not close the call while preserving its sequence gap")) {
        return false;
    }
    return require(pipeline.snapshot().tx_state == wirex::bm_voice::TxState::idle,
                   "TX stop left a live transmitter state");
}

[[nodiscard]] bool test_tx_backpressure_and_cancel()
{
    BmVoicePipeline pipeline;
    const auto start = TimePoint{} + 20s;
    const auto call = make_call(1002U, 92U, 2U);
    if (!require(pipeline.begin_tx(call, Readiness{true, true}, start) == Error::none,
                 "TX begin failed in backpressure case")) {
        return false;
    }
    (void)pipeline.take_outbound();
    std::array<std::int16_t, wirex::bm_voice::max_tx_audio_samples_per_push> input{};
    for (int index = 0; index < 7; ++index) {
        const auto result = pipeline.push_tx_audio(input.data(), input.size(), start + std::chrono::milliseconds{index});
        if (!require(result.error == Error::none, "bounded TX codeword queue filled too early")) {
            return false;
        }
    }
    const auto overflow = pipeline.push_tx_audio(input.data(), input.size(), start + 8ms);
    if (!require(overflow.error == Error::tx_queue_full &&
                 pipeline.snapshot().queued_tx_codewords <= wirex::bm_voice::max_tx_queued_codewords,
                 "TX backlog was not rejected at its fixed bound")) {
        return false;
    }
    pipeline.cancel_tx();
    if (!require(pipeline.snapshot().queued_tx_codewords == 0U &&
                 pipeline.snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                 !pipeline.take_outbound().has_value(),
                 "TX cancellation retained audio or packet state")) {
        return false;
    }
    return require(pipeline.begin_tx(call, Readiness{true, true}, start + 9ms) == Error::none,
                   "TX did not re-enter after cancellation");
}

[[nodiscard]] bool test_rx_filter_startup_timeout_and_delayed_ready()
{
    BmVoicePipeline pipeline;
    wirex::bm_voice::ReceiveFilter filter{};
    filter.destination_id = 91U;
    filter.match_slot = true;
    filter.slot = wirex::dmr_call::Slot::ts2;
    filter.match_call_kind = true;
    filter.call_kind = wirex::dmr_call::CallKind::group;
    if (!require(pipeline.set_receive_filter(filter) == Error::none,
                 "RX filter configuration failed")) {
        return false;
    }

    const auto base = TimePoint{} + 30s;
    RxSource mismatch;
    wirex::dmr_call::TxPacket header{};
    if (!require(mismatch.start(make_call(2001U, 92U, 3U, wirex::dmr_call::Slot::ts2), header),
                 "could not create filtered test call")) {
        return false;
    }
    const auto filtered = pipeline.ingest_rx(header.datagram, base);
    if (!require(filtered.error == Error::filtered &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle,
                 "RX did not reject the wrong TG")) {
        return false;
    }
    wirex::dmr_call::TxPacket end{};
    (void)mismatch.finish(end);
    (void)pipeline.ingest_rx(end.datagram, base + 1ms);

    RxSource wrong_slot;
    if (!require(wrong_slot.start(make_call(2004U, 91U, 14U, wirex::dmr_call::Slot::ts1), header) &&
                 pipeline.ingest_rx(header.datagram, base + 2ms).error == Error::filtered,
                 "RX filter did not reject the wrong timeslot")) {
        return false;
    }
    (void)wrong_slot.finish(end);
    (void)pipeline.ingest_rx(end.datagram, base + 3ms);

    RxSource wrong_kind;
    if (!require(wrong_kind.start(make_call(2005U, 91U, 15U, wirex::dmr_call::Slot::ts2,
                                             wirex::dmr_call::CallKind::private_call), header) &&
                 pipeline.ingest_rx(header.datagram, base + 4ms).error == Error::filtered,
                 "RX filter did not reject the wrong call kind")) {
        return false;
    }
    (void)wrong_kind.finish(end);
    (void)pipeline.ingest_rx(end.datagram, base + 5ms);

    RxSource pending;
    if (!require(pending.start(make_call(2002U, 91U, 4U, wirex::dmr_call::Slot::ts2), header),
                 "could not create delayed-start RX call") ||
        !require(pipeline.ingest_rx(header.datagram, base + 10ms).error == Error::none,
                 "matching RX header was rejected")) {
        return false;
    }
    if (!require(drain_events(pipeline, EventKind::receive_started),
                 "matching RX call did not request HRI start")) {
        return false;
    }
    const auto started_snapshot = pipeline.snapshot();
    if (!require(started_snapshot.rx_state == wirex::bm_voice::RxState::waiting_for_playback &&
                 !started_snapshot.receive_network_ended &&
                 started_snapshot.receive_call.source_id == pending.call.source_id &&
                 started_snapshot.receive_call.destination_id == pending.call.destination_id &&
                 started_snapshot.receive_call.slot == pending.call.slot &&
                 started_snapshot.receive_call.kind == pending.call.kind &&
                 started_snapshot.receive_link_control_validated &&
                 started_snapshot.receive_color_code_known &&
                 started_snapshot.receive_call.color_code == pending.call.color_code,
                 "accepted RX snapshot did not expose its current call before EOT")) {
        return false;
    }

    for (std::size_t index = 0U; index < 50U; ++index) {
        wirex::dmr_call::TxPacket voice{};
        if (!require(pending.voice(voice), "RX source failed to generate voice burst")) {
            return false;
        }
        const auto now = base + 20ms + std::chrono::milliseconds{static_cast<std::int64_t>(index * 60U)};
        const auto result = pipeline.ingest_rx(voice.datagram, now);
        if (!require(result.error == Error::none &&
                     pipeline.snapshot().queued_rx_bursts <= wirex::bm_voice::max_rx_queued_bursts,
                     "RX startup buffer overflowed before the 3s readiness deadline")) {
            return false;
        }
    }
    PlaybackFrame held_frame{};
    if (!require(pipeline.snapshot().queued_rx_bursts == 50U &&
                 !pipeline.take_playback_pcm(held_frame),
                 "RX startup did not hold all media until playback_ready")) {
        return false;
    }
    const auto timeout_at = base + 10ms + wirex::bm_voice::receive_start_timeout;
    if (!require(pipeline.tick(timeout_at) == Error::playback_start_timeout &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle &&
                 pipeline.snapshot().queued_rx_bursts == 0U &&
                 drain_events(pipeline, EventKind::playback_start_timeout),
                 "RX startup timeout retained media or failed to notify the wrapper")) {
        return false;
    }

    BmVoicePipeline delayed;
    RxSource delayed_source;
    if (!require(delayed_source.start(make_call(2003U, 91U, 5U, wirex::dmr_call::Slot::ts2), header) &&
                 delayed.ingest_rx(header.datagram, base).error == Error::none,
                 "delayed RX start failed")) {
        return false;
    }
    (void)delayed.take_event();
    for (std::size_t index = 0U; index < 17U; ++index) {
        wirex::dmr_call::TxPacket voice{};
        (void)delayed_source.voice(voice);
        const auto now = base + 10ms + std::chrono::milliseconds{static_cast<std::int64_t>(index * 60U)};
        if (!require(delayed.ingest_rx(voice.datagram, now).error == Error::none,
                     "RX could not buffer a one-second HRI startup delay")) {
            return false;
        }
    }
    const auto ready_at = base + 1010ms;
    if (!require(delayed.playback_ready(ready_at) == Error::none &&
                 delayed.snapshot().queued_rx_bursts == 17U &&
                 delayed.tick(ready_at) == Error::none &&
                 delayed.snapshot().queued_playback_frames == 3U,
                 "RX delayed-ready startup did not decode exactly one 60ms burst")) {
        return false;
    }
    PlaybackFrame frame{};
    std::uint64_t playback_generation{};
    for (std::size_t index = 0U; index < 3U; ++index) {
        if (!require(delayed.take_playback_pcm(frame), "HRI could not pull a 20ms PCM frame")) {
            return false;
        }
        playback_generation = frame.generation;
    }
    if (!require(!delayed.take_playback_pcm(frame) &&
                 delayed.snapshot().unconfirmed_playback_frames == 3U &&
                 delayed.acknowledge_playback(playback_generation, 3U, ready_at + 1ms) == Error::none,
                 "RX did not apply the 60ms hardware-ack bound")) {
        return false;
    }
    return true;
}

[[nodiscard]] bool test_independent_tg91_receive_and_private_parrot_return_filters()
{
    using wirex::dmr_call::CallKind;
    using wirex::dmr_call::Slot;
    BmVoicePipeline pipeline;
    wirex::bm_voice::ReceiveFilter primary{};
    primary.destination_id = 91U;
    primary.match_slot = true;
    primary.slot = Slot::ts2;
    primary.match_call_kind = true;
    primary.call_kind = CallKind::group;
    if (!require(pipeline.set_receive_filter(primary) == Error::none,
                 "independent TG91 receive filter setup failed")) return false;

    wirex::bm_voice::ReceiveFilter parrot_return{};
    parrot_return.destination_id = 4611355U;
    parrot_return.source_id = 460997U;
    parrot_return.slot = Slot::ts2;
    parrot_return.call_kind = CallKind::private_call;
    parrot_return.match_slot = true;
    parrot_return.match_call_kind = true;
    parrot_return.match_source_id = true;
    if (!require(pipeline.set_secondary_receive_filter(parrot_return) == Error::none,
                 "narrow private parrot return filter setup failed")) return false;

    auto filter_check_now = TimePoint{} + 60s;
    auto check_header = [&](wirex::dmr_call::CallConfig call, bool expected, const char* message) {
        RxSource source;
        wirex::dmr_call::TxPacket header{};
        if (!source.start(call, header)) return require(false, "failed to create RX filter header");
        const auto result = pipeline.ingest_rx(header.datagram, filter_check_now);
        filter_check_now += 1ms;
        const bool accepted = result.error == Error::none;
        if (accepted) pipeline.cancel_rx();
        return require(accepted == expected, message);
    };

    RxSource tg91;
    wirex::dmr_call::TxPacket tg91_header{};
    const auto tg91_start = TimePoint{} + 60s;
    if (!require(tg91.start(make_call(3149876U, 91U, 31U, Slot::ts2, CallKind::group), tg91_header),
                 "could not create TG91 receive call")) return false;
    if (!require(pipeline.ingest_rx(tg91_header.datagram, tg91_start).error == Error::none &&
                 pipeline.playback_ready(tg91_start) == Error::none,
                 "independent TG91 TS2 group receive was not accepted")) return false;
    (void)pipeline.take_event();
    wirex::dmr_call::TxPacket tg91_voice{};
    if (!require(tg91.voice(tg91_voice) &&
                 pipeline.ingest_rx(tg91_voice.datagram, tg91_start + 1ms).error == Error::none &&
                 pipeline.tick(tg91_start + 60ms) == Error::none &&
                 tg91.voice(tg91_voice) &&
                 pipeline.ingest_rx(tg91_voice.datagram, tg91_start + 61ms).error == Error::none &&
                 pipeline.tick(tg91_start + 120ms) == Error::none,
                 "TG91 voice packets did not reach the DMR decoder")) return false;
    PlaybackFrame tg91_pcm{};
    if (!require(pipeline.snapshot().rx_state == wirex::bm_voice::RxState::playing &&
                 pipeline.take_playback_pcm(tg91_pcm) && tg91_pcm.sample_count > 0U &&
                 pipeline.acknowledge_playback(tg91_pcm.generation, 1U, tg91_start + 121ms) == Error::none,
                 "accepted TG91 call did not produce PCM for the configured playback route")) return false;
    wirex::dmr_call::TxPacket tg91_end{};
    if (!require(tg91.finish(tg91_end) &&
                 pipeline.ingest_rx(tg91_end.datagram, tg91_start + 122ms).error == Error::none,
                 "TG91 terminator did not reach the receive call state")) return false;
    bool tg91_network_end = false;
    while (const auto event = pipeline.take_event()) {
        tg91_network_end = tg91_network_end ||
            (event->kind == EventKind::network_ended && event->call.source_id == 3149876U &&
             event->call.destination_id == 91U);
    }
    if (!require(tg91_network_end, "TG91 EOT did not end the decoded receive call")) return false;
    pipeline.cancel_rx();
    filter_check_now = tg91_start + 200ms;

    RxSource parrot;
    wirex::dmr_call::TxPacket parrot_header{};
    const auto parrot_start = TimePoint{} + 61s;
    if (!require(parrot.start(make_call(460997U, 4611355U, 32U, Slot::ts2, CallKind::private_call),
                              parrot_header), "could not create private parrot return")) return false;
    if (!require(pipeline.ingest_rx(parrot_header.datagram, parrot_start).error == Error::none &&
                 pipeline.playback_ready(parrot_start) == Error::none,
                 "private echo reply from the selected parrot to the local Source ID was not accepted")) return false;
    (void)pipeline.take_event();
    wirex::dmr_call::TxPacket parrot_voice{};
    if (!require(parrot.voice(parrot_voice) &&
                 pipeline.ingest_rx(parrot_voice.datagram, parrot_start + 1ms).error == Error::none &&
                 pipeline.tick(parrot_start + 60ms) == Error::none &&
                 parrot.voice(parrot_voice) &&
                 pipeline.ingest_rx(parrot_voice.datagram, parrot_start + 61ms).error == Error::none &&
                 pipeline.tick(parrot_start + 120ms) == Error::none,
                 "parrot return voice packets did not reach the DMR decoder")) return false;
    PlaybackFrame pcm{};
    if (!require(pipeline.snapshot().rx_state == wirex::bm_voice::RxState::playing &&
                 pipeline.take_playback_pcm(pcm) && pcm.sample_count > 0U &&
                 pipeline.acknowledge_playback(pcm.generation, 1U, parrot_start + 121ms) == Error::none,
                 "accepted parrot return did not produce PCM for the configured playback route")) return false;
    wirex::dmr_call::TxPacket parrot_end{};
    if (!require(parrot.finish(parrot_end) &&
                 pipeline.ingest_rx(parrot_end.datagram, parrot_start + 122ms).error == Error::none,
                 "parrot return terminator did not reach the receive call state")) return false;
    bool parrot_network_end = false;
    while (const auto event = pipeline.take_event()) {
        parrot_network_end = parrot_network_end ||
            (event->kind == EventKind::network_ended && event->call.source_id == 460997U &&
             event->call.destination_id == 4611355U);
    }
    if (!require(parrot_network_end, "parrot return EOT did not end the decoded receive call")) return false;
    pipeline.cancel_rx();

    filter_check_now = parrot_start + 1s;
    if (!check_header(make_call(3149876U, 4611355U, 33U, Slot::ts2, CallKind::private_call), false,
                      "private call from an unselected source was accepted as the parrot reply")) return false;
    if (!check_header(make_call(460997U, 1234567U, 34U, Slot::ts2, CallKind::private_call), false,
                      "private reply to another Radio ID was accepted")) return false;
    if (!check_header(make_call(460997U, 4611355U, 35U, Slot::ts1, CallKind::private_call), false,
                      "private reply on a different timeslot was accepted")) return false;
    if (!check_header(make_call(460997U, 4611355U, 36U, Slot::ts2, CallKind::group), false,
                      "group call was accepted by the private parrot return filter")) return false;
    if (!check_header(make_call(3149876U, 91U, 38U, Slot::ts2, CallKind::group), true,
                      "RX filter changed after a completed parrot return")) return false;
    if (!require(pipeline.set_secondary_receive_filter(std::nullopt) == Error::none,
                 "secondary receive rule did not clear for listen-only mode")) return false;
    if (!check_header(make_call(460997U, 4611355U, 39U, Slot::ts2, CallKind::private_call), false,
                      "listen-only mode retained the optional private parrot return rule")) return false;
    if (!check_header(make_call(3149876U, 91U, 37U, Slot::ts1, CallKind::group), false,
                      "TG91 group on a different timeslot was accepted")) return false;

    wirex::bm_voice::ReceiveFilter invalid_source{};
    invalid_source.match_source_id = true;
    invalid_source.source_id = 0U;
    if (!require(pipeline.set_secondary_receive_filter(invalid_source) == Error::invalid_call,
                 "source constrained filter accepted an invalid source ID")) return false;

    return true;
}

[[nodiscard]] bool test_rx_eot_drain_and_ack()
{
    BmVoicePipeline pipeline;
    RxSource source;
    wirex::dmr_call::TxPacket header{};
    const auto start = TimePoint{} + 40s;
    if (!require(source.start(make_call(3001U, 93U, 6U, wirex::dmr_call::Slot::ts1), header) &&
                 pipeline.ingest_rx(header.datagram, start).error == Error::none &&
                 pipeline.playback_ready(start) == Error::none,
                 "RX EOT test could not start HRI playback")) {
        return false;
    }
    (void)pipeline.take_event();

    wirex::dmr_call::TxPacket voice{};
    (void)source.voice(voice);
    if (!require(pipeline.ingest_rx(voice.datagram, start + 1ms).error == Error::none &&
                 pipeline.tick(start + 60ms) == Error::none &&
                 pipeline.snapshot().queued_playback_frames == 0U,
                 "RX played before its two-burst jitter prebuffer")) {
        return false;
    }
    (void)source.voice(voice);
    if (!require(pipeline.ingest_rx(voice.datagram, start + 61ms).error == Error::none &&
                 pipeline.tick(start + 120ms) == Error::none,
                 "RX failed to decode after its prebuffer filled")) {
        return false;
    }
    PlaybackFrame frame{};
    std::uint64_t playback_generation{};
    for (std::size_t index = 0U; index < 3U; ++index) {
        if (!require(pipeline.take_playback_pcm(frame), "first RX burst did not produce PCM")) {
            return false;
        }
        playback_generation = frame.generation;
    }
    if (!require(pipeline.acknowledge_playback(playback_generation, 3U, start + 121ms) == Error::none &&
                 pipeline.tick(start + 180ms) == Error::none,
                 "RX first hardware completion was not acknowledged")) {
        return false;
    }
    for (std::size_t index = 0U; index < 3U; ++index) {
        if (!require(pipeline.take_playback_pcm(frame), "second RX burst did not produce PCM")) {
            return false;
        }
        playback_generation = frame.generation;
    }
    wirex::dmr_call::TxPacket end{};
    (void)source.finish(end);
    const auto ended = pipeline.ingest_rx(end.datagram, start + 181ms);
    if (!require(ended.error == Error::none && drain_events(pipeline, EventKind::network_ended),
                 "RX did not report the DMRD EOT event")) {
        return false;
    }
    const auto network_ended_snapshot = pipeline.snapshot();
    if (!require(network_ended_snapshot.rx_state == wirex::bm_voice::RxState::draining &&
                 network_ended_snapshot.receive_network_ended &&
                 network_ended_snapshot.receive_call.source_id == source.call.source_id,
                 "EOT did not separate ended network speech from local playback draining")) {
        return false;
    }
    if (!require(pipeline.tick(start + 240ms) == Error::none &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::draining &&
                 !drain_events(pipeline, EventKind::playback_drained),
                 "RX reported hardware playback drained before HRI completion")) {
        return false;
    }
    if (!require(pipeline.acknowledge_playback(playback_generation, 3U, start + 241ms) == Error::none &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::draining &&
                 !drain_events(pipeline, EventKind::playback_drained) &&
                 pipeline.take_playback_pcm(frame) && frame.sample_count == 126U &&
                 pipeline.acknowledge_playback(frame.generation, 1U, start + 242ms) == Error::none &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle &&
                 !pipeline.snapshot().receive_network_ended &&
                 drain_events(pipeline, EventKind::playback_drained),
                 "RX did not flush its filter tail and report drained after hardware completion")) {
        return false;
    }
    return true;
}

[[nodiscard]] bool test_nonmatching_calls_do_not_interrupt_active_rx()
{
    BmVoicePipeline pipeline;
    wirex::bm_voice::ReceiveFilter filter{};
    filter.destination_id = 77U;
    filter.match_slot = true;
    filter.slot = wirex::dmr_call::Slot::ts1;
    filter.match_call_kind = true;
    filter.call_kind = wirex::dmr_call::CallKind::group;
    const auto start = TimePoint{} + 45s;
    if (!require(pipeline.set_receive_filter(filter) == Error::none,
                 "active RX filter setup failed")) {
        return false;
    }

    RxSource selected;
    wirex::dmr_call::TxPacket header{};
    if (!require(selected.start(make_call(3101U, 77U, 20U), header) &&
                 pipeline.ingest_rx(header.datagram, start).error == Error::none &&
                 pipeline.playback_ready(start) == Error::none,
                 "selected RX call did not start")) {
        return false;
    }
    (void)pipeline.take_event();
    wirex::dmr_call::TxPacket voice{};
    (void)selected.voice(voice);
    (void)pipeline.ingest_rx(voice.datagram, start + 1ms);
    (void)pipeline.tick(start + 60ms);
    (void)selected.voice(voice);
    (void)pipeline.ingest_rx(voice.datagram, start + 61ms);
    if (!require(pipeline.tick(start + 120ms) == Error::none,
                 "selected RX call did not enter playback")) {
        return false;
    }

    RxSource other_slot;
    wirex::dmr_call::TxPacket other_header{};
    if (!require(other_slot.start(make_call(3102U, 77U, 21U, wirex::dmr_call::Slot::ts2), other_header) &&
                 pipeline.ingest_rx(other_header.datagram, start + 121ms).error == Error::filtered,
                 "nonselected timeslot header was not filtered")) {
        return false;
    }
    (void)other_slot.voice(voice);
    if (!require(pipeline.ingest_rx(voice.datagram, start + 122ms).error == Error::filtered,
                 "nonselected timeslot voice was not filtered")) {
        return false;
    }
    wirex::dmr_call::TxPacket other_end{};
    (void)other_slot.finish(other_end);
    if (!require(pipeline.ingest_rx(other_end.datagram, start + 123ms).error == Error::filtered,
                 "nonselected timeslot EOT was not filtered")) {
        return false;
    }

    RxSource other_talkgroup;
    if (!require(other_talkgroup.start(make_call(3103U, 78U, 22U), other_header) &&
                 pipeline.ingest_rx(other_header.datagram, start + 124ms).error == Error::filtered,
                 "nonselected talkgroup header was not filtered")) {
        return false;
    }
    (void)other_talkgroup.voice(voice);
    (void)pipeline.ingest_rx(voice.datagram, start + 125ms);
    (void)other_talkgroup.finish(other_end);
    (void)pipeline.ingest_rx(other_end.datagram, start + 126ms);
    const auto during = pipeline.snapshot();
    if (!require(during.rx_state == wirex::bm_voice::RxState::playing &&
                 during.receive_call.source_id == selected.call.source_id &&
                 during.receive_call.destination_id == selected.call.destination_id &&
                 during.queued_rx_bursts == 1U && during.queued_playback_frames == 3U,
                 "nonselected stream changed the active RX state or media queues")) {
        return false;
    }

    (void)selected.voice(voice);
    if (!require(pipeline.ingest_rx(voice.datagram, start + 130ms).error == Error::none &&
                 pipeline.tick(start + 180ms) == Error::none,
                 "selected stream did not continue after other TG/TS packets")) {
        return false;
    }
    wirex::dmr_call::TxPacket selected_end{};
    (void)selected.finish(selected_end);
    const auto end_result = pipeline.ingest_rx(selected_end.datagram, start + 181ms);
    bool selected_network_end = false;
    while (const auto event = pipeline.take_event()) {
        selected_network_end = selected_network_end ||
            (event->kind == EventKind::network_ended &&
             event->call.source_id == selected.call.source_id);
    }
    pipeline.cancel_rx();
    return require(end_result.error == Error::none && selected_network_end,
                   "selected RX EOT was lost after filtering interleaved calls");
}

[[nodiscard]] bool test_half_duplex_collision()
{
    BmVoicePipeline pipeline;
    const auto now = TimePoint{} + 50s;
    if (!require(pipeline.begin_tx(make_call(4001U, 94U, 7U), Readiness{true, true}, now) == Error::none,
                 "half-duplex TX setup failed")) {
        return false;
    }
    (void)pipeline.take_outbound();
    RxSource source;
    wirex::dmr_call::TxPacket header{};
    if (!require(source.start(make_call(4002U, 95U, 8U), header), "half-duplex RX setup failed")) {
        return false;
    }
    const auto result = pipeline.ingest_rx(header.datagram, now + 1ms);
    const bool collision = result.error == Error::half_duplex_collision &&
                           pipeline.snapshot().tx_state == wirex::bm_voice::TxState::active &&
                           pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle;
    pipeline.cancel_tx();
    return require(collision, "pipeline accepted RX while transmitting");
}

[[nodiscard]] bool test_rx_queue_bound_cancel_and_reentry()
{
    BmVoicePipeline pipeline;
    RxSource source;
    wirex::dmr_call::TxPacket header{};
    const auto start = TimePoint{} + 60s;
    if (!require(source.start(make_call(5001U, 96U, 9U), header) &&
                 pipeline.ingest_rx(header.datagram, start).error == Error::none &&
                 pipeline.playback_ready(start) == Error::none,
                 "RX queue-bound call did not start")) {
        return false;
    }
    (void)pipeline.take_event();

    wirex::dmr_call::TxPacket voice{};
    for (std::size_t index = 0U; index < 50U; ++index) {
        (void)source.voice(voice);
        const auto now = start + std::chrono::milliseconds{static_cast<std::int64_t>((index + 1U) * 60U)};
        if (!require(pipeline.ingest_rx(voice.datagram, now).error == Error::none &&
                     pipeline.tick(now) == Error::none,
                     "RX playback failed while filling the bounded PCM queue")) {
            return false;
        }
    }
    if (!require(pipeline.snapshot().buffered_receive_frames == wirex::bm_voice::max_rx_queued_pcm_frames &&
                 pipeline.snapshot().queued_playback_frames == 147U &&
                 pipeline.snapshot().queued_rx_bursts == 1U &&
                 pipeline.tick(start + 3060ms) == Error::none &&
                 pipeline.snapshot().queued_playback_frames == wirex::bm_voice::max_rx_queued_pcm_frames,
                 "RX media backlog did not stop at its fixed three-second frame bound")) {
        return false;
    }
    (void)source.voice(voice);
    const auto overflow_at = start + 3061ms;
    if (!require(pipeline.ingest_rx(voice.datagram, overflow_at).error == Error::rx_queue_full &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle &&
                 pipeline.snapshot().queued_rx_bursts == 0U &&
                 pipeline.snapshot().queued_playback_frames == 0U &&
                 pipeline.snapshot().unconfirmed_playback_frames == 0U &&
                 drain_events(pipeline, EventKind::queue_overflow),
                 "RX queue overflow did not clear stale burst and PCM state")) {
        return false;
    }

    RxSource cancelled;
    if (!require(cancelled.start(make_call(5002U, 97U, 10U), header) &&
                 pipeline.ingest_rx(header.datagram, overflow_at + 1ms).error == Error::none &&
                 pipeline.playback_ready(overflow_at + 1ms) == Error::none,
                 "RX did not re-enter after overflow cleanup")) {
        return false;
    }
    (void)pipeline.take_event();
    for (std::size_t index = 0U; index < 2U; ++index) {
        (void)cancelled.voice(voice);
        const auto now = overflow_at + std::chrono::milliseconds{2 + static_cast<std::int64_t>(index * 60U)};
        if (!require(pipeline.ingest_rx(voice.datagram, now).error == Error::none,
                     "re-entered RX could not buffer voice")) {
            return false;
        }
        if (index == 1U && !require(pipeline.tick(now) == Error::none,
                                    "re-entered RX could not decode its first burst")) {
            return false;
        }
    }
    PlaybackFrame frame{};
    std::uint64_t old_generation{};
    if (!require(pipeline.take_playback_pcm(frame) &&
                 pipeline.snapshot().unconfirmed_playback_frames == 1U,
                 "re-entered RX did not hand PCM to HRI")) {
        return false;
    }
    old_generation = frame.generation;
    pipeline.cancel_rx();
    if (!require(pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle &&
                 pipeline.snapshot().queued_rx_bursts == 0U &&
                 pipeline.snapshot().queued_playback_frames == 0U &&
                 pipeline.snapshot().unconfirmed_playback_frames == 0U &&
                 !pipeline.take_playback_pcm(frame) &&
                 drain_events(pipeline, EventKind::receive_cancelled),
                 "RX cancel retained queued or in-flight audio")) {
        return false;
    }

    RxSource after_cancel;
    const auto new_start = overflow_at + 130ms;
    if (!require(after_cancel.start(make_call(5003U, 98U, 11U), header) &&
                 pipeline.ingest_rx(header.datagram, new_start).error == Error::none &&
                 pipeline.playback_ready(new_start) == Error::none &&
                 pipeline.snapshot().receive_generation > old_generation,
                 "RX did not accept a fresh stream after cancellation")) {
        return false;
    }
    for (std::size_t index = 0U; index < 2U; ++index) {
        (void)after_cancel.voice(voice);
        const auto now = new_start + std::chrono::milliseconds{2 + static_cast<std::int64_t>(index * 60U)};
        if (!require(pipeline.ingest_rx(voice.datagram, now).error == Error::none,
                     "fresh RX after cancellation could not buffer voice")) {
            return false;
        }
        if (index == 1U && !require(pipeline.tick(now) == Error::none,
                                    "fresh RX after cancellation could not decode voice")) {
            return false;
        }
    }
    if (!require(pipeline.take_playback_pcm(frame) && frame.generation > old_generation &&
                 pipeline.snapshot().unconfirmed_playback_frames == 1U,
                 "fresh RX after cancellation did not produce a new generation frame")) {
        return false;
    }
    const auto new_generation = frame.generation;
    if (!require(pipeline.acknowledge_playback(old_generation, 1U, new_start + 63ms) ==
                     Error::stale_playback_ack &&
                 pipeline.snapshot().unconfirmed_playback_frames == 1U &&
                 pipeline.acknowledge_playback(new_generation, 1U, new_start + 64ms) == Error::none,
                 "late WaveOut completion from the cancelled call acknowledged a new stream")) {
        return false;
    }
    pipeline.reset();
    const auto after_reset = TimePoint{} + 80s;
    if (!require(pipeline.snapshot().receive_generation > new_generation &&
                 !pipeline.snapshot().receive_generation_exhausted,
                 "pipeline reset reused or cleared its playback generation")) {
        return false;
    }
    RxSource after_reset_source;
    if (!require(after_reset_source.start(make_call(5004U, 98U, 12U), header) &&
                 pipeline.ingest_rx(header.datagram, after_reset).error == Error::none &&
                 pipeline.snapshot().receive_generation > new_generation &&
                 pipeline.acknowledge_playback(new_generation, 1U, after_reset + 1ms) ==
                     Error::stale_playback_ack,
                 "pipeline reset allowed a prior-call playback token to match")) {
        return false;
    }
    return true;
}

[[nodiscard]] bool test_rx_missing_eot_watchdog()
{
    BmVoicePipeline pipeline;
    RxSource source;
    wirex::dmr_call::TxPacket header{};
    const auto start = TimePoint{} + 70s;
    if (!require(source.start(make_call(6001U, 99U, 12U), header) &&
                 pipeline.ingest_rx(header.datagram, start).error == Error::none &&
                 pipeline.playback_ready(start) == Error::none,
                 "watchdog RX call did not start")) {
        return false;
    }
    (void)pipeline.take_event();
    wirex::dmr_call::TxPacket voice{};
    (void)source.voice(voice);
    (void)pipeline.ingest_rx(voice.datagram, start + 1ms);
    (void)pipeline.tick(start + 60ms);
    (void)source.voice(voice);
    (void)pipeline.ingest_rx(voice.datagram, start + 61ms);
    (void)pipeline.tick(start + 120ms);
    PlaybackFrame frame{};
    std::uint64_t playback_generation{};
    for (std::size_t index = 0U; index < 3U; ++index) {
        if (!require(pipeline.take_playback_pcm(frame), "watchdog first burst did not produce PCM")) {
            return false;
        }
        playback_generation = frame.generation;
    }
    if (!require(pipeline.acknowledge_playback(playback_generation, 3U, start + 121ms) == Error::none &&
                 pipeline.tick(start + 180ms) == Error::none,
                 "watchdog playback setup did not advance")) {
        return false;
    }
    const auto timed_out_at = start + 421ms;
    if (!require(pipeline.tick(timed_out_at) == Error::none,
                 "lost EOT did not end the receive call at its watchdog deadline")) {
        return false;
    }
    bool watchdog_reason = false;
    while (const auto event = pipeline.take_event()) {
        watchdog_reason = watchdog_reason ||
            (event->kind == EventKind::network_ended &&
             event->end_reason == wirex::dmr_call::CallEndReason::watchdog);
    }
    if (!require(watchdog_reason && pipeline.snapshot().rx_state == wirex::bm_voice::RxState::draining,
                 "lost-EOT watchdog reason was not preserved while the audio tail drained")) {
        return false;
    }
    for (std::size_t index = 0U; index < 3U; ++index) {
        if (!require(pipeline.take_playback_pcm(frame), "watchdog tail PCM was dropped")) {
            return false;
        }
        playback_generation = frame.generation;
    }
    if (!require(pipeline.acknowledge_playback(playback_generation, 3U, timed_out_at + 1ms) == Error::none &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::draining &&
                 pipeline.take_playback_pcm(frame) && frame.sample_count == 126U &&
                 pipeline.acknowledge_playback(frame.generation, 1U, timed_out_at + 2ms) == Error::none &&
                 pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle &&
                 drain_events(pipeline, EventKind::playback_drained),
                 "watchdog tail did not finish after HRI acknowledged the filter tail")) {
        return false;
    }
    return true;
}

[[nodiscard]] bool test_absolute_tx_clock_with_waveinput_chunks_and_jitter()
{
    BmVoicePipeline pipeline;
    const auto start = TimePoint{} + 30s;
    const auto call = make_call(1010U, 91U, 0x31U);
    if (!require(pipeline.begin_tx(call, Readiness{true, true}, start) == Error::none,
                 "long jitter TX did not start") ||
        !require(pipeline.take_outbound().has_value(), "long jitter TX did not produce its LC header")) {
        return false;
    }

    std::array<std::int16_t, wirex::bm_voice::max_tx_audio_samples_per_push> input{};
    for (std::size_t index = 0U; index < input.size(); ++index) {
        input[index] = static_cast<std::int16_t>((static_cast<int>(index % 80U) - 40) * 150);
    }

    std::vector<TimePoint> sent_voice_times;
    std::size_t maximum_queued_codewords = 0U;
    std::uint64_t now_ms = 0U;
    std::uint64_t next_waveinput_ms = 100U;
    bool next_step_is_seven_ms = true;
    while (now_ms <= 120000U) {
        const auto now = start + std::chrono::milliseconds{now_ms};
        if (now_ms >= next_waveinput_ms && next_waveinput_ms <= 120000U) {
            const auto pushed = pipeline.push_tx_audio(input.data(), input.size(), now);
            if (!require(pushed.error == Error::none,
                         "100 ms WaveInput chunk was rejected during 120-second pacing run")) {
                return false;
            }
            next_waveinput_ms += 100U;
        }
        const auto tick_result = pipeline.tick(now);
        if (!require(tick_result == Error::none,
                     "7/11 ms virtual timer jitter caused an unnecessary schedule failure")) {
            return false;
        }
        maximum_queued_codewords = std::max(maximum_queued_codewords,
                                             pipeline.snapshot().queued_tx_codewords);
        while (const auto packet = pipeline.take_outbound()) {
            if (packet->kind == wirex::dmr_call::PacketKind::voice_sync ||
                packet->kind == wirex::dmr_call::PacketKind::voice) {
                sent_voice_times.push_back(now);
            }
        }
        now_ms += next_step_is_seven_ms ? 7U : 11U;
        next_step_is_seven_ms = !next_step_is_seven_ms;
    }

    const auto finish_ms = now_ms + 1U;
    if (!require(pipeline.end_tx(start + std::chrono::milliseconds{finish_ms}) == Error::none,
                 "long jitter TX could not flush the final 100 ms audio chunk")) {
        return false;
    }
    now_ms = finish_ms;
    bool sent_eot = false;
    while (now_ms < finish_ms + 5000U && !sent_eot) {
        const auto now = start + std::chrono::milliseconds{now_ms};
        if (!require(pipeline.tick(now) == Error::none,
                     "long jitter TX drain failed after the capture ended")) {
            return false;
        }
        while (const auto packet = pipeline.take_outbound()) {
            sent_eot = sent_eot || packet->kind == wirex::dmr_call::PacketKind::terminator_with_lc;
        }
        maximum_queued_codewords = std::max(maximum_queued_codewords,
                                             pipeline.snapshot().queued_tx_codewords);
        now_ms += next_step_is_seven_ms ? 7U : 11U;
        next_step_is_seven_ms = !next_step_is_seven_ms;
    }
    if (!require(sent_eot && sent_voice_times.size() >= 1985U && sent_voice_times.size() <= 2005U,
                 "100 ms capture blocks did not sustain approximately 16.67 DMR bursts per second")) {
        return false;
    }
    if (!require(maximum_queued_codewords < 18U &&
                 pipeline.snapshot().tx_state == wirex::bm_voice::TxState::idle,
                 "ordinary timer jitter caused an unbounded TX backlog")) {
        return false;
    }
    const auto expected_span = std::chrono::milliseconds{60 *
        static_cast<std::int64_t>(sent_voice_times.size() - 1U)};
    const auto actual_span = sent_voice_times.back() - sent_voice_times.front();
    if (!require(actual_span >= expected_span - 20ms && actual_span <= expected_span + 20ms,
                 "absolute 60 ms deadlines accumulated timer drift over 120 seconds")) {
        return false;
    }
    std::cout << "120s_tx_voice_bursts=" << sent_voice_times.size()
              << " max_queued_codewords=" << maximum_queued_codewords
              << " deadline_span_ms="
              << std::chrono::duration_cast<std::chrono::milliseconds>(actual_span).count() << '\n';

    BmVoicePipeline delayed;
    const auto delayed_start = TimePoint{} + 40s;
    if (!require(delayed.begin_tx(call, Readiness{true, true}, delayed_start) == Error::none,
                 "delayed scheduler TX did not start")) {
        return false;
    }
    (void)delayed.take_outbound();
    if (!require(delayed.push_tx_audio(input.data(), input.size(), delayed_start + 100ms).error == Error::none &&
                 delayed.push_tx_audio(input.data(), input.size(), delayed_start + 200ms).error == Error::none,
                 "delayed scheduler test could not queue two real 100 ms capture blocks")) {
        return false;
    }
    const auto first_due = delayed_start + 260ms;
    if (!require(delayed.tick(first_due + 70ms) == Error::none,
                 "one 70 ms desktop scheduling delay should recover without cancelling TX")) {
        return false;
    }
    const auto first_after_delay = delayed.take_outbound();
    if (!require(first_after_delay && first_after_delay->kind == wirex::dmr_call::PacketKind::voice_sync &&
                 delayed.tick(first_due + 71ms) == Error::none && !delayed.take_outbound().has_value() &&
                 delayed.tick(first_due + 129ms) == Error::none && !delayed.take_outbound().has_value() &&
                 delayed.tick(first_due + 130ms) == Error::none,
                 "70 ms delay did not re-anchor the next burst at one 60 ms interval")) {
        return false;
    }
    const auto recovered = delayed.take_outbound();
    if (!require(recovered && recovered->kind == wirex::dmr_call::PacketKind::voice,
                 "TX did not resume at the re-anchored 60 ms deadline")) {
        return false;
    }
    if (!require(delayed.tick(first_due + 2130ms) == Error::deadline_missed,
                 "multi-second scheduler stop did not reject stale voice instead of bursting it")) {
        return false;
    }
    const auto termination = delayed.take_outbound();
    if (!require(termination && termination->kind == wirex::dmr_call::PacketKind::terminator_with_lc &&
                 !delayed.take_outbound().has_value() &&
                 delayed.snapshot().tx_state == wirex::bm_voice::TxState::idle,
                 "multi-second scheduler stop did not emit only one network terminator")) {
        return false;
    }
    return true;
}

[[nodiscard]] bool test_dmrd_sequence_statistics()
{
    BmVoicePipeline pipeline;
    const auto start = TimePoint{} + 90s;
    RxSource source;
    wirex::dmr_call::TxPacket header{};
    if (!require(source.start(make_call(4101U, 91U, 41U), header),
                 "sequence test source did not create a header") ||
        !require(pipeline.ingest_rx(header.datagram, start).error == Error::none,
                 "sequence test pipeline rejected the initial header")) {
        return false;
    }

    wirex::dmr_call::TxPacket first_voice{};
    wirex::dmr_call::TxPacket second_voice{};
    if (!require(source.voice(first_voice) && source.voice(second_voice),
                 "sequence test source did not create voice packets")) {
        return false;
    }
    if (!require(pipeline.ingest_rx(first_voice.datagram, start + 60ms).error == Error::none,
                 "sequence test pipeline rejected the first voice packet")) {
        return false;
    }
    second_voice.datagram.sequence = 4U;
    if (!require(pipeline.ingest_rx(second_voice.datagram, start + 120ms).error == Error::none,
                 "sequence test pipeline rejected the forward packet after a gap")) {
        return false;
    }
    if (!require(pipeline.ingest_rx(second_voice.datagram, start + 121ms).protocol.sequence.duplicate,
                 "same sequence was not observed as a duplicate")) {
        return false;
    }
    auto out_of_order = second_voice.datagram;
    out_of_order.sequence = 3U;
    if (!require(pipeline.ingest_rx(out_of_order, start + 122ms).protocol.sequence.out_of_order,
                 "backward sequence was not observed as out of order")) {
        return false;
    }

    wirex::dmr_call::TxPacket terminator{};
    if (!require(source.finish(terminator), "sequence test source did not create an EOT") ) {
        return false;
    }
    terminator.datagram.sequence = 5U;
    if (!require(pipeline.ingest_rx(terminator.datagram, start + 180ms).error == Error::none,
                 "sequence test pipeline rejected normal EOT")) {
        return false;
    }
    auto snapshot = pipeline.snapshot().dmrd_sequence;
    if (!require(snapshot.call_valid && snapshot.call_received == 4U &&
                 snapshot.call_missing == 2U && snapshot.call_expected == 6U &&
                 snapshot.call_loss_complete,
                 "per-call stats count forward packets, wrapped gaps, and normal EOT") ||
        !require(snapshot.session_valid && snapshot.session_received == 4U &&
                 snapshot.session_missing == 2U && snapshot.session_expected == 6U &&
                 snapshot.session_duplicate == 1U && snapshot.session_out_of_order == 1U,
                 "session stats keep duplicates and reordering outside the loss denominator")) {
        return false;
    }

    pipeline.cancel_rx();
    RxSource second_call;
    wirex::dmr_call::TxPacket second_header{};
    wirex::dmr_call::TxPacket second_terminator{};
    if (!require(second_call.start(make_call(4102U, 91U, 42U), second_header),
                 "second sequence call did not create a header") ||
        !require(pipeline.ingest_rx(second_header.datagram, start + 500ms).error == Error::none,
                 "pipeline rejected the next call header") ||
        !require(second_call.finish(second_terminator), "second sequence call did not create EOT") ||
        !require(pipeline.ingest_rx(second_terminator.datagram, start + 560ms).error == Error::none,
                 "pipeline rejected second call EOT")) {
        return false;
    }
    snapshot = pipeline.snapshot().dmrd_sequence;
    if (!require(snapshot.call_received == 2U && snapshot.call_missing == 0U &&
                 snapshot.call_expected == 2U && snapshot.call_loss_complete,
                 "per-call counters reset for the next call") ||
        !require(snapshot.session_received == 6U && snapshot.session_missing == 2U &&
                 snapshot.session_expected == 8U && snapshot.session_duplicate == 1U &&
                 snapshot.session_out_of_order == 1U,
                 "session counters accumulate across calls")) {
        return false;
    }

    BmVoicePipeline filtered_pipeline;
    wirex::bm_voice::ReceiveFilter filter{};
    filter.destination_id = 92U;
    if (!require(filtered_pipeline.set_receive_filter(filter) == Error::none,
                 "filtered-sequence test could not set its receive filter")) {
        return false;
    }
    RxSource filtered_source;
    wirex::dmr_call::TxPacket filtered_header{};
    if (!require(filtered_source.start(make_call(4103U, 91U, 43U), filtered_header),
                 "filtered-sequence test could not create a source") ||
        !require(filtered_pipeline.ingest_rx(filtered_header.datagram, start).error == Error::filtered,
                 "pipeline did not reject a nonmatching receive destination")) {
        return false;
    }
    if (!require(!filtered_pipeline.snapshot().dmrd_sequence.session_valid,
                 "filtered packet does not increment network sequence statistics")) {
        return false;
    }

    BmVoicePipeline watchdog_pipeline;
    RxSource watchdog_source;
    wirex::dmr_call::TxPacket watchdog_header{};
    wirex::dmr_call::TxPacket watchdog_voice{};
    if (!require(watchdog_source.start(make_call(4104U, 91U, 44U), watchdog_header) &&
                 watchdog_source.voice(watchdog_voice),
                 "watchdog-sequence test could not create a voice-sync packet") ||
        !require(watchdog_pipeline.ingest_rx(watchdog_voice.datagram, start).error == Error::none,
                 "watchdog-sequence pipeline rejected its initial voice packet") ||
        !require(watchdog_pipeline.tick(start + wirex::dmr_call::default_receive_timeout) == Error::none,
                 "watchdog-sequence pipeline failed while closing the call")) {
        return false;
    }
    snapshot = watchdog_pipeline.snapshot().dmrd_sequence;
    return require(snapshot.call_valid && snapshot.call_received == 1U &&
                   snapshot.call_expected == 1U && !snapshot.call_loss_complete,
                   "watchdog leaves the observed call incomplete because its tail cannot be counted");
}

} // namespace

int main()
{
    if (!test_tx_pacing_and_drain() || !test_tx_backpressure_and_cancel() ||
        !test_rx_filter_startup_timeout_and_delayed_ready() || !test_rx_eot_drain_and_ack() ||
        !test_independent_tg91_receive_and_private_parrot_return_filters() ||
        !test_half_duplex_collision() || !test_rx_queue_bound_cancel_and_reentry() ||
        !test_rx_missing_eot_watchdog() || !test_nonmatching_calls_do_not_interrupt_active_rx() ||
        !test_absolute_tx_clock_with_waveinput_chunks_and_jitter() ||
        !test_dmrd_sequence_statistics()) {
        return 1;
    }
    std::cout << "BM voice pipeline offline pacing, filters, lifecycle, bounds, reset, and RX acknowledgement checks passed.\n";
    return 0;
}
