/* SPDX-License-Identifier: GPL-3.0-or-later
 * 固定 MMDVM_CM 向量由 build/_work/dmr-call/upstream-reference.cpp 生成；
 * 测试本身保留独立 golden bytes，不依赖被测实现做自往返验证。
 */
#include "wirex/dmr_call.hpp"
#include "wirex/dmrd.hpp"
#include "wirex/quick_call.hpp"
#include "dmr_signal.hpp"

#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>

namespace {

using namespace wirex::dmr_call;
using namespace std::chrono_literals;

int failures = 0;

void check(bool condition, const char* name)
{
    if (!condition) {
        std::printf("FAIL: %s\n", name);
        ++failures;
    }
}

template <std::size_t N>
void check_equal(const std::array<std::uint8_t, N>& actual,
                 const std::array<std::uint8_t, N>& expected,
                 const char* name)
{
    for (std::size_t i = 0U; i < N; ++i) {
        if (actual[i] != expected[i]) {
            std::printf("FAIL: %s byte[%zu]: got %02X expected %02X\n",
                        name, i, static_cast<unsigned int>(actual[i]),
                        static_cast<unsigned int>(expected[i]));
            ++failures;
            return;
        }
    }
}

constexpr std::array<std::uint8_t, 33U> header_vector{{
    0x06U, 0xF3U, 0x22U, 0x96U, 0x05U, 0x04U, 0x7DU, 0xD8U, 0x6BU, 0x21U, 0xCCU,
    0xC3U, 0xDCU, 0x4DU, 0x5DU, 0x7FU, 0x77U, 0xFDU, 0x75U, 0x73U, 0x63U, 0xF0U,
    0x77U, 0xE0U, 0x90U, 0x50U, 0x30U, 0x43U, 0x1EU, 0x81U, 0x6CU, 0x86U, 0x54U}};
constexpr std::array<std::uint8_t, 33U> terminator_vector{{
    0x06U, 0x9CU, 0x22U, 0x42U, 0x05U, 0xB4U, 0x7DU, 0xA0U, 0x6BU, 0x51U, 0xCCU,
    0x63U, 0xDCU, 0x8DU, 0x5DU, 0x7FU, 0x77U, 0xFDU, 0x75U, 0x74U, 0x36U, 0xE4U,
    0x74U, 0xD8U, 0x97U, 0x30U, 0x3CU, 0x03U, 0x16U, 0x81U, 0x75U, 0x86U, 0x67U}};
constexpr std::array<std::array<std::uint8_t, 33U>, 6U> voice_vectors{{
    {{0x13U, 0x38U, 0x5DU, 0x82U, 0xA7U, 0xCCU, 0xF1U, 0x16U, 0x3BU, 0x60U, 0x85U,
      0xAAU, 0xCFU, 0xF7U, 0xF7U, 0xD5U, 0xDDU, 0x57U, 0xDFU, 0xD4U, 0x19U, 0x3EU,
      0x63U, 0x88U, 0xADU, 0xD2U, 0xF7U, 0x1CU, 0x41U, 0x66U, 0x8BU, 0xB0U, 0xD5U}},
    {{0x13U, 0x38U, 0x5DU, 0x82U, 0xA7U, 0xCCU, 0xF1U, 0x16U, 0x3BU, 0x60U, 0x85U,
      0xAAU, 0xCFU, 0xF7U, 0x30U, 0x91U, 0x10U, 0x50U, 0xA3U, 0x84U, 0x19U, 0x3EU,
      0x63U, 0x88U, 0xADU, 0xD2U, 0xF7U, 0x1CU, 0x41U, 0x66U, 0x8BU, 0xB0U, 0xD5U}},
    {{0x13U, 0x38U, 0x5DU, 0x82U, 0xA7U, 0xCCU, 0xF1U, 0x16U, 0x3BU, 0x60U, 0x85U,
      0xAAU, 0xCFU, 0xF7U, 0x72U, 0x81U, 0xB0U, 0x51U, 0x7DU, 0xD4U, 0x19U, 0x3EU,
      0x63U, 0x88U, 0xADU, 0xD2U, 0xF7U, 0x1CU, 0x41U, 0x66U, 0x8BU, 0xB0U, 0xD5U}},
    {{0x13U, 0x38U, 0x5DU, 0x82U, 0xA7U, 0xCCU, 0xF1U, 0x16U, 0x3BU, 0x60U, 0x85U,
      0xAAU, 0xCFU, 0xF7U, 0x72U, 0x23U, 0xC2U, 0xD3U, 0x9DU, 0xD4U, 0x19U, 0x3EU,
      0x63U, 0x88U, 0xADU, 0xD2U, 0xF7U, 0x1CU, 0x41U, 0x66U, 0x8BU, 0xB0U, 0xD5U}},
    {{0x13U, 0x38U, 0x5DU, 0x82U, 0xA7U, 0xCCU, 0xF1U, 0x16U, 0x3BU, 0x60U, 0x85U,
      0xAAU, 0xCFU, 0xF7U, 0x52U, 0xD3U, 0xA0U, 0xA2U, 0x1AU, 0xE4U, 0x19U, 0x3EU,
      0x63U, 0x88U, 0xADU, 0xD2U, 0xF7U, 0x1CU, 0x41U, 0x66U, 0x8BU, 0xB0U, 0xD5U}},
    {{0x13U, 0x38U, 0x5DU, 0x82U, 0xA7U, 0xCCU, 0xF1U, 0x16U, 0x3BU, 0x60U, 0x85U,
      0xAAU, 0xCFU, 0xF7U, 0x10U, 0x00U, 0x00U, 0x00U, 0x04U, 0xB4U, 0x19U, 0x3EU,
      0x63U, 0x88U, 0xADU, 0xD2U, 0xF7U, 0x1CU, 0x41U, 0x66U, 0x8BU, 0xB0U, 0xD5U}},
}};

CallConfig test_call()
{
    CallConfig call{};
    call.source_id = 0x123456U;
    call.destination_id = 0x234567U;
    call.gateway_id = 0x89ABCDEFU;
    call.stream_id = {{0x01U, 0x23U, 0x45U, 0x67U}};
    call.slot = Slot::ts2;
    call.kind = CallKind::group;
    call.color_code = 7U;
    return call;
}

AmbeVoiceBurst test_ambe()
{
    AmbeVoiceBurst ambe{};
    for (std::size_t i = 0U; i < ambe.size(); ++i) {
        ambe[i] = static_cast<std::uint8_t>((i * 37U + 0x13U) & 0xFFU);
    }
    return ambe;
}

struct TxFixture {
    wirex::dmrd::Datagram header{};
    std::array<wirex::dmrd::Datagram, 6U> voice{};
    wirex::dmrd::Datagram terminator{};
};

TxFixture make_tx_fixture()
{
    Transmitter tx;
    TxFixture fixture{};
    auto start = tx.start(test_call());
    check(static_cast<bool>(start), "tx starts with valid call fields");
    fixture.header = start.packet.datagram;
    for (std::size_t i = 0U; i < fixture.voice.size(); ++i) {
        const auto result = tx.voice(test_ambe());
        check(static_cast<bool>(result), "tx emits one voice burst");
        fixture.voice[i] = result.packet.datagram;
        check(result.packet.voice_burst_index == i, "tx rotates A through F burst index");
    }
    const auto end = tx.finish();
    check(static_cast<bool>(end), "tx emits terminator");
    fixture.terminator = end.packet.datagram;
    return fixture;
}

void test_upstream_vectors_and_outer_fields()
{
    const auto fixture = make_tx_fixture();
    check_equal(fixture.header.payload, header_vector, "MMDVM_CM full LC header vector");
    check_equal(fixture.terminator.payload, terminator_vector, "MMDVM_CM terminator vector");
    for (std::size_t i = 0U; i < voice_vectors.size(); ++i) {
        check_equal(fixture.voice[i].payload, voice_vectors[i], "MMDVM_CM voice burst A-F vector");
    }

    check(fixture.header.sequence == 0U, "header starts DMRD sequence at zero");
    check(fixture.header.flags == 0xA1U, "TS2 group header flags include data-sync and LC type");
    check(fixture.voice[0U].flags == 0x90U, "TS2 group voice A has voice-sync flag");
    for (std::size_t i = 1U; i < fixture.voice.size(); ++i) {
        check(fixture.voice[i].flags == static_cast<std::uint8_t>(0x80U | i), "voice B-F carry burst index");
    }
    check(fixture.terminator.flags == 0xA2U, "TS2 group terminator flags include data-sync and EOT type");
    check(fixture.terminator.sequence == 7U, "sequence advances through head, six voice bursts, and EOT");
    check(fixture.header.source_id == 0x123456U && fixture.header.destination_id == 0x234567U,
          "DMRD source and destination IDs are retained");
    check(fixture.header.gateway_id == 0x89ABCDEFU, "DMRD gateway ID is retained");
    check(fixture.header.stream_id == test_call().stream_id, "DMRD stream ID bytes are retained");
    check(voice_burst_period == 60ms, "the integration cadence is one three-codeword burst per 60 ms");
}

void test_tx_errors_and_sequence_wrap()
{
    Transmitter tx;
    const auto not_active = tx.voice(test_ambe());
    check(not_active.error == TxError::not_active, "tx rejects voice before start");
    auto invalid = test_call();
    invalid.source_id = 0x1000000U;
    check(tx.start(invalid).error == TxError::invalid_source_id, "tx rejects source ID overflow");
    invalid = test_call();
    invalid.slot = static_cast<Slot>(3U);
    check(tx.start(invalid).error == TxError::invalid_slot, "tx rejects invalid timeslot");

    auto first = tx.start(test_call());
    check(static_cast<bool>(first), "tx can start after rejected configuration");
    check(tx.start(test_call()).error == TxError::already_active, "tx rejects overlapping local call");
    TxResult wrapped{};
    for (unsigned int i = 0U; i < 255U; ++i) {
        wrapped = tx.voice(test_ambe());
    }
    check(wrapped.packet.datagram.sequence == 255U, "DMRD sequence reaches 255");
    wrapped = tx.voice(test_ambe());
    check(wrapped.packet.datagram.sequence == 0U, "DMRD sequence wraps at 8 bits");
    check(wrapped.packet.voice_burst_index == 3U, "voice burst A-F cycle repeats after F");
    check(tx.finish().packet.datagram.sequence == 1U, "EOT sequence continues after wrap");
    check(tx.finish().error == TxError::not_active, "tx rejects second finish");
}

void test_header_receive_duplicate_and_fec()
{
    const auto fixture = make_tx_fixture();
    Receiver rx;
    const auto t0 = Receiver::Clock::time_point{};
    auto header = fixture.header;
    header.payload[0U] ^= 0x80U;
    auto received = rx.ingest(header, t0);
    check(received.status == ReceiveStatus::accepted && received.event_count == 1U,
          "receiver accepts a full LC header after one BPTC bit error");
    check(received.events[0U].kind == ReceiveEventKind::call_started &&
          received.events[0U].link_control_validated && received.events[0U].call.color_code == 7U,
          "header event reports decoded LC and color code");

    const auto duplicate = rx.ingest(header, t0 + 1ms);
    check(duplicate.status == ReceiveStatus::ignored && duplicate.event_count == 0U,
          "the repeated same-sequence header is ignored without restarting the call");
    auto voice_a = fixture.voice[0U];
    received = rx.ingest(voice_a, t0 + 60ms);
    check(received.event_count == 1U && received.events[0U].kind == ReceiveEventKind::voice,
          "voice A follows the valid header without another call-start event");
    check_equal(received.events[0U].voice, test_ambe(), "received AMBE codewords are restored");

    auto bad_sync = fixture.header;
    bad_sync.payload[13U] ^= 0x01U;
    Receiver sync_rx;
    received = sync_rx.ingest(bad_sync, t0);
    check(received.status == ReceiveStatus::malformed && received.error == ReceiveError::invalid_full_lc,
          "header with damaged data sync is rejected");

    auto mismatched = fixture.header;
    ++mismatched.source_id;
    Receiver mismatch_rx;
    received = mismatch_rx.ingest(mismatched, t0);
    check(received.status == ReceiveStatus::malformed && received.error == ReceiveError::link_control_mismatch,
          "header LC IDs must match DMRD IDs");
}

void test_voice_sync_join_embedded_lc_and_terminator()
{
    const auto fixture = make_tx_fixture();
    Receiver rx;
    const auto t0 = Receiver::Clock::time_point{};
    auto received = rx.ingest(fixture.voice[0U], t0);
    check(received.event_count == 2U && received.events[0U].kind == ReceiveEventKind::call_started &&
          received.events[1U].kind == ReceiveEventKind::voice,
          "voice-sync A can start a receiver stream when the LC header was missed");
    check(!received.events[0U].link_control_validated,
          "sync-A start clearly reports that LC is not yet validated");
    check_equal(received.events[1U].voice, test_ambe(), "sync-A joins with three complete AMBE codewords");

    bool embedded_confirmed = false;
    for (std::size_t i = 1U; i <= 4U; ++i) {
        auto result = rx.ingest(fixture.voice[i], t0 + std::chrono::milliseconds(60 * i));
        check(result.status == ReceiveStatus::accepted, "receiver accepts subsequent voice burst");
        check(result.events[0U].kind == ReceiveEventKind::voice, "each valid DMR voice burst emits voice data");
        check_equal(result.events[0U].voice, test_ambe(), "each burst restores the original three codewords");
        if (result.event_count == 2U && result.events[1U].kind == ReceiveEventKind::link_control_confirmed) {
            embedded_confirmed = result.events[1U].link_control_origin == LinkControlOrigin::embedded_lc;
        }
    }
    check(embedded_confirmed, "four embedded-LC blocks pass CRC and Hamming checks");

    auto end = rx.ingest(fixture.terminator, t0 + 420ms);
    check(end.status == ReceiveStatus::accepted && end.event_count == 1U &&
          end.events[0U].kind == ReceiveEventKind::call_ended &&
          end.events[0U].end_reason == CallEndReason::terminator,
          "validated terminator ends the matching stream");
    check(end.sequence.valid && end.sequence.forward_packet && end.sequence.terminator,
          "normal terminator is included as a forward DMRD packet");
    const auto late = rx.ingest(fixture.voice[0U], t0 + 480ms);
    check(late.status == ReceiveStatus::ignored && late.error == ReceiveError::stale_stream,
          "late voice-sync from a terminated stream cannot reopen it");
}

void test_sequence_gaps_and_stream_replacement()
{
    const auto fixture = make_tx_fixture();
    Receiver rx;
    const auto t0 = Receiver::Clock::time_point{};
    auto start = fixture.voice[0U];
    start.sequence = 254U;
    auto received = rx.ingest(start, t0);
    check(received.sequence.valid && received.sequence.forward_packet && received.sequence.starts_call &&
              received.sequence.call.stream_id == start.stream_id,
          "first accepted stream packet is reported as the sequence baseline");

    auto next = fixture.voice[1U];
    next.sequence = 255U;
    received = rx.ingest(next, t0 + 60ms);
    check(received.status == ReceiveStatus::accepted && received.events[0U].missing_packets == 0U,
          "sequential packet counter advances without a gap");
    check(received.sequence.valid && received.sequence.forward_packet &&
              received.sequence.missing_packets == 0U,
          "forward packet sequence observation has no missing frames");

    next = fixture.voice[2U];
    next.sequence = 1U;
    received = rx.ingest(next, t0 + 120ms);
    check(received.status == ReceiveStatus::accepted && received.events[0U].missing_packets == 1U,
          "8-bit sequence wrap records one lost packet");
    check(received.sequence.forward_packet && received.sequence.missing_packets == 1U,
          "8-bit wrap observation counts the inferred gap once");
    const auto duplicate = rx.ingest(next, t0 + 121ms);
    check(duplicate.status == ReceiveStatus::ignored && duplicate.error == ReceiveError::stale_or_duplicate_sequence,
          "duplicate sequence is ignored");
    check(duplicate.sequence.valid && duplicate.sequence.duplicate && !duplicate.sequence.forward_packet,
          "duplicate sequence is categorized separately from packet loss");

    auto old = fixture.voice[4U];
    old.sequence = 0U;
    const auto stale = rx.ingest(old, t0 + 122ms);
    check(stale.status == ReceiveStatus::ignored && stale.error == ReceiveError::stale_or_duplicate_sequence,
          "out-of-order packet behind the current sequence is ignored");
    check(stale.sequence.valid && stale.sequence.out_of_order && !stale.sequence.forward_packet,
          "backward sequence is categorized separately from packet loss");

    Receiver replace_rx;
    auto original = fixture.voice[0U];
    original.sequence = 10U;
    (void)replace_rx.ingest(original, t0);
    auto replacement = fixture.voice[0U];
    replacement.sequence = 11U;
    replacement.stream_id = {{0x89U, 0xABU, 0xCDU, 0xEFU}};
    received = replace_rx.ingest(replacement, t0 + 60ms);
    check(received.status == ReceiveStatus::accepted && received.event_count == 3U &&
          received.events[0U].kind == ReceiveEventKind::call_ended &&
          received.events[0U].end_reason == CallEndReason::replaced_by_new_stream &&
          received.events[1U].kind == ReceiveEventKind::call_started &&
          received.events[2U].kind == ReceiveEventKind::voice,
          "a newer sync-A stream replaces the current slot in ordered events");
    original.sequence = 12U;
    const auto late_old = replace_rx.ingest(original, t0 + 120ms);
    check(late_old.status == ReceiveStatus::ignored && late_old.error == ReceiveError::stale_stream,
          "a retired stream cannot displace the replacement stream");
}

void test_timeout_and_two_timeslots()
{
    const auto fixture = make_tx_fixture();
    Receiver rx;
    const auto t0 = Receiver::Clock::time_point{};
    (void)rx.ingest(fixture.voice[0U], t0);
    check(rx.poll(t0 + 359ms).event_count == 0U, "watchdog waits through the 359 ms boundary");
    auto result = rx.poll(t0 + 360ms);
    check(result.event_count == 1U && result.events[0U].kind == ReceiveEventKind::call_ended &&
          result.events[0U].end_reason == CallEndReason::watchdog,
          "watchdog closes a stream at the configured 360 ms boundary");
    check(!result.sequence.valid,
          "watchdog supplies no sequence observation for unknown tail packets");

    auto ts1_call = test_call();
    ts1_call.slot = Slot::ts1;
    auto ts2_call = test_call();
    ts2_call.slot = Slot::ts2;
    Transmitter ts1_tx;
    Transmitter ts2_tx;
    const auto ts1 = ts1_tx.start(ts1_call).packet.datagram;
    const auto ts2 = ts2_tx.start(ts2_call).packet.datagram;
    (void)ts1;
    (void)ts2;
    const auto ts1_voice = ts1_tx.voice(test_ambe()).packet.datagram;
    const auto ts2_voice = ts2_tx.voice(test_ambe()).packet.datagram;
    Receiver two_slots;
    check(two_slots.ingest(ts1_voice, t0).event_count == 2U, "TS1 sync-A starts its own call");
    check(two_slots.ingest(ts2_voice, t0 + 1ms).event_count == 2U, "TS2 sync-A starts independently");
    result = two_slots.poll(t0 + 361ms);
    check(result.event_count == 2U && result.events[0U].call.slot == Slot::ts1 &&
          result.events[1U].call.slot == Slot::ts2,
          "poll reports watchdog closure for both independent timeslots");

    Transmitter first_slot_tx;
    Transmitter second_slot_tx;
    auto first_slot_call = test_call();
    first_slot_call.slot = Slot::ts1;
    auto second_slot_call = test_call();
    second_slot_call.slot = Slot::ts2;
    const auto first_slot_voice = first_slot_tx.start(first_slot_call).packet.datagram;
    const auto second_slot_voice = second_slot_tx.start(second_slot_call).packet.datagram;
    (void)first_slot_voice;
    (void)second_slot_voice;
    const auto first_a = first_slot_tx.voice(test_ambe()).packet.datagram;
    const auto second_a = second_slot_tx.voice(test_ambe()).packet.datagram;
    Receiver bounded_events;
    (void)bounded_events.ingest(first_a, t0);
    (void)bounded_events.ingest(second_a, t0 + 1ms);

    auto replacement_call = first_slot_call;
    replacement_call.stream_id = {{0x89U, 0xABU, 0xCDU, 0xEFU}};
    Transmitter replacement_tx;
    const auto replacement_head = replacement_tx.start(replacement_call).packet.datagram;
    (void)replacement_head;
    const auto replacement_a = replacement_tx.voice(test_ambe()).packet.datagram;
    result = bounded_events.ingest(replacement_a, t0 + 360ms);
    check(result.event_count == result.events.size() &&
          result.events[0U].kind == ReceiveEventKind::call_ended &&
          result.events[0U].call.slot == Slot::ts1 &&
          result.events[0U].end_reason == CallEndReason::watchdog &&
          result.events[1U].kind == ReceiveEventKind::call_started &&
          result.events[2U].kind == ReceiveEventKind::voice,
          "one ingest expires only its own timeslot and returns all three events");
    result = bounded_events.poll(t0 + 361ms);
    check(result.event_count == 1U && result.events[0U].call.slot == Slot::ts2 &&
          result.events[0U].end_reason == CallEndReason::watchdog,
          "poll closes the other expired timeslot on its next sweep");
}

void test_embedded_qr_and_fec_correction()
{
    const auto fixture = make_tx_fixture();
    auto damaged_b = fixture.voice[1U];
    damaged_b.payload[13U] ^= 0x01U;
    damaged_b.payload[19U] ^= 0x10U;
    const auto signaling = wirex::dmr_signal::decode_embedded_signaling(damaged_b.payload);
    check(signaling.valid && signaling.color_code == 7U && signaling.lcss == 1U,
          "QR(16,7) corrects two EMB signaling bit errors");

    Receiver rx;
    const auto t0 = Receiver::Clock::time_point{};
    (void)rx.ingest(fixture.voice[0U], t0);
    (void)rx.ingest(damaged_b, t0 + 60ms);
    (void)rx.ingest(fixture.voice[2U], t0 + 120ms);
    (void)rx.ingest(fixture.voice[3U], t0 + 180ms);
    auto damaged_e = fixture.voice[4U];
    damaged_e.payload[15U] ^= 0x80U;
    const auto result = rx.ingest(damaged_e, t0 + 240ms);
    check(result.event_count == 2U && result.events[1U].kind == ReceiveEventKind::link_control_confirmed,
          "embedded Hamming blocks correct a single LC bit error before CRC5 validation");
}

void test_private_call_and_invalid_flags()
{
    auto call = test_call();
    call.slot = Slot::ts1;
    call.kind = CallKind::private_call;
    call.destination_id = 0x000042U;
    call.color_code = 2U;
    Transmitter tx;
    const auto header = tx.start(call).packet.datagram;
    check(header.flags == 0x61U, "private TS1 LC header flags are encoded");
    Receiver rx;
    const auto received = rx.ingest(header, Receiver::Clock::time_point{});
    check(received.status == ReceiveStatus::accepted && received.events[0U].call.kind == CallKind::private_call &&
          received.events[0U].call.destination_id == 0x000042U,
          "private-call LC and DMRD identities are decoded");

    auto bad = make_tx_fixture().voice[1U];
    bad.flags = static_cast<std::uint8_t>((bad.flags & 0xF0U) | 0x06U);
    Receiver invalid_rx;
    const auto invalid = invalid_rx.ingest(bad, Receiver::Clock::time_point{});
    check(invalid.status == ReceiveStatus::malformed && invalid.error == ReceiveError::invalid_burst_index,
          "unsupported voice burst index is rejected");
}

void test_call_kind_cannot_flip_in_stream()
{
    const auto group = make_tx_fixture();
    auto private_call = test_call();
    private_call.kind = CallKind::private_call;
    Transmitter private_tx;
    const auto private_head = private_tx.start(private_call).packet.datagram;
    const auto private_a = private_tx.voice(test_ambe()).packet.datagram;

    Receiver rx;
    const auto t0 = Receiver::Clock::time_point{};
    auto started = rx.ingest(group.voice[0U], t0);
    check(started.status == ReceiveStatus::accepted && started.event_count == 2U,
          "group voice-sync starts before the missed head");
    auto flipped = rx.ingest(private_a, t0 + 60ms);
    check(flipped.status == ReceiveStatus::malformed && flipped.event_count == 0U &&
          flipped.error == ReceiveError::link_control_mismatch,
          "private flag cannot relabel an active group stream with the same IDs");
    flipped = rx.ingest(private_head, t0 + 61ms);
    check(flipped.status == ReceiveStatus::malformed && flipped.event_count == 0U &&
          flipped.error == ReceiveError::link_control_mismatch,
          "a duplicate stream ID cannot switch LC group/private identity");
    const auto resumed = rx.ingest(group.voice[1U], t0 + 120ms);
    check(resumed.status == ReceiveStatus::accepted && resumed.event_count == 1U &&
          resumed.events[0U].kind == ReceiveEventKind::voice,
          "the original call remains active after a mismatched private packet");
    const auto ended = rx.ingest(group.terminator, t0 + 180ms);
    check(ended.status == ReceiveStatus::accepted && ended.events[0U].kind == ReceiveEventKind::call_ended,
          "the original group stream can finish after the mismatched packets");
    flipped = rx.ingest(private_a, t0 + 240ms);
    check(flipped.status == ReceiveStatus::ignored && flipped.error == ReceiveError::stale_stream,
          "private flag changes cannot reopen a recently retired stream ID");
}

void test_group_quick_call_is_a_two_frame_control_call()
{
    using wirex::quick_call::GateStatus;
    using wirex::quick_call::PlanError;
    using wirex::quick_call::Readiness;
    using wirex::quick_call::SendStatus;
    const wirex::talkgroup_routing::GroupRoute group{91U, Slot::ts2};
    const std::array<std::uint8_t, 4U> stream_id{{0x10U, 0x20U, 0x30U, 0x40U}};
    const auto planned = wirex::quick_call::make_group_plan(0x123456U, 0x89abcdefU,
                                                            group, 7U, stream_id);
    check(static_cast<bool>(planned), "Quick Call planner accepts a valid group and timeslot");
    if (!planned) return;
    check(planned.plan.frames.size() == 2U &&
          planned.plan.frames[0U].kind == PacketKind::voice_lc_header &&
          planned.plan.frames[1U].kind == PacketKind::terminator_with_lc,
          "Quick Call plan contains only a group header and its EOT");
    check(planned.plan.frames[0U].datagram.flags == 0xa1U &&
          planned.plan.frames[1U].datagram.flags == 0xa2U &&
          planned.plan.frames[0U].datagram.sequence == 0U &&
          planned.plan.frames[1U].datagram.sequence == 1U,
          "Quick Call frames use DMRD group LC header and EOT sequence values");
    check(planned.plan.frames[0U].datagram.destination_id == group.destination_id &&
          planned.plan.frames[1U].datagram.destination_id == group.destination_id &&
          planned.plan.frames[0U].datagram.stream_id == stream_id &&
          planned.plan.frames[1U].datagram.stream_id == stream_id,
          "both Quick Call frames retain the selected target and stream identity");

    for (std::size_t index = 0U; index < planned.plan.frames.size(); ++index) {
        const auto& frame = planned.plan.frames[index];
        const auto encoded = wirex::dmrd::encode(frame.datagram);
        const auto decoded = wirex::dmrd::decode(encoded.bytes.data(), encoded.bytes.size());
        const auto type = index == 0U ? wirex::dmr_signal::FullLcType::voice_header
                                      : wirex::dmr_signal::FullLcType::terminator;
        const auto lc = wirex::dmr_signal::decode_full_lc(frame.datagram.payload, type);
        check(static_cast<bool>(encoded) && static_cast<bool>(decoded) &&
              decoded.datagram.flags == frame.datagram.flags &&
              decoded.datagram.source_id == 0x123456U &&
              decoded.datagram.destination_id == 91U &&
              decoded.datagram.gateway_id == 0x89abcdefU &&
              wirex::quick_call::same_datagram(frame, decoded.datagram),
              "Quick Call serializes as a valid 55-byte DMRD datagram");
        check(lc.valid && lc.link_control.flco == 0U &&
              lc.link_control.source_id == 0x123456U &&
              lc.link_control.destination_id == 91U && lc.color_code == 7U,
              "Quick Call LC payload validates as a group voice header or terminator");
    }

    std::size_t sends = 0U;
    const auto completed = wirex::quick_call::send_once(planned.plan, [&](const auto&) {
        ++sends;
        return true;
    });
    check(completed.status == SendStatus::sent && completed.packets_sent == 2U && sends == 2U,
          "one explicit Quick Call sends each planned control frame once");

    sends = 0U;
    const auto partial = wirex::quick_call::send_once(planned.plan, [&](const auto&) {
        ++sends;
        return sends == 1U;
    });
    check(partial.status == SendStatus::partial_send && partial.packets_sent == 1U && sends == 2U,
          "a failed EOT reports a partial send and does not retry either frame");
    sends = 0U;
    const auto no_send = wirex::quick_call::send_once(planned.plan, [&](const auto&) {
        ++sends;
        return false;
    });
    check(no_send.status == SendStatus::send_failed && no_send.packets_sent == 0U && sends == 1U,
          "a failed header stops the operation before the EOT and does not retry");

    auto readiness = Readiness{true, true, true, false, false, true, true};
    check(wirex::quick_call::check_readiness(readiness) == GateStatus::busy,
          "Quick Call gate refuses an active voice/media owner");
    readiness.pipeline_idle = true;
    readiness.media_owner_idle = true;
    readiness.hri_stream_idle = false;
    check(wirex::quick_call::check_readiness(readiness) == GateStatus::busy,
          "Quick Call gate refuses an active HRI stream");
    readiness.hri_stream_idle = true;
    readiness.cleanup_idle = false;
    check(wirex::quick_call::check_readiness(readiness) == GateStatus::busy,
          "Quick Call gate refuses pending media cleanup");
    readiness.cleanup_idle = true;
    readiness.bm_ready = false;
    check(wirex::quick_call::check_readiness(readiness) == GateStatus::not_ready,
          "Quick Call gate refuses a BM session that is not ready");

    auto listen_46001 = group;
    listen_46001.destination_id = 46001U;
    check(static_cast<bool>(wirex::quick_call::make_group_plan(0x123456U, 0x89abcdefU,
          listen_46001, 7U, stream_id)),
          "TG46001 remains valid as an isolated dynamic Quick Call target");
    auto forbidden = group;
    forbidden.destination_id = 4000U;
    check(wirex::quick_call::make_group_plan(0x123456U, 0x89abcdefU,
          forbidden, 7U, stream_id).error == PlanError::disconnect_group_forbidden,
          "TG4000 is rejected because it is a dynamic-group disconnect action");
}

} // namespace

int main()
{
    test_upstream_vectors_and_outer_fields();
    test_tx_errors_and_sequence_wrap();
    test_header_receive_duplicate_and_fec();
    test_voice_sync_join_embedded_lc_and_terminator();
    test_sequence_gaps_and_stream_replacement();
    test_timeout_and_two_timeslots();
    test_embedded_qr_and_fec_correction();
    test_private_call_and_invalid_flags();
    test_call_kind_cannot_flip_in_stream();
    test_group_quick_call_is_a_two_frame_control_call();

    if (failures != 0) {
        std::printf("%d DMR call checks failed.\n", failures);
        return 1;
    }
    std::printf("All DMR call/FEC checks passed.\n");
    return 0;
}
