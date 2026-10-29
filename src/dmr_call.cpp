/* SPDX-License-Identifier: GPL-3.0-or-later
 * 通话帧状态依据 DroidStar dmr.cpp（固定提交
 * becf1dede57c4a70a865e9cb4cac9247e505599a，GPL-3.0-or-later）；DMRD 布局
 * 复用本项目 dmrd::Datagram。LC/FEC 算法来源和逐文件许可见
 * third_party/dmr_signal/dmr_signal.cpp。
 */
#include "wirex/dmr_call.hpp"

#include "dmr_signal.hpp"

#include <algorithm>
#include <array>
#include <cstdint>

namespace wirex::dmr_call {
namespace {

constexpr std::uint8_t flag_ts2 = 0x80U;
constexpr std::uint8_t flag_private = 0x40U;
constexpr std::uint8_t flag_data_sync = 0x20U;
constexpr std::uint8_t flag_voice_sync = 0x10U;
constexpr std::uint8_t data_type_mask = 0x0FU;
constexpr std::uint8_t max_voice_burst_index = 5U;
constexpr std::uint8_t no_voice_index = 0xFFU;

[[nodiscard]] bool valid_slot(Slot slot) noexcept
{
    return slot == Slot::ts1 || slot == Slot::ts2;
}

[[nodiscard]] std::size_t slot_index(Slot slot) noexcept
{
    return slot == Slot::ts2 ? 1U : 0U;
}

[[nodiscard]] bool same_stream_identity(const CallConfig& left, const CallConfig& right) noexcept
{
    return left.source_id == right.source_id &&
           left.destination_id == right.destination_id &&
           left.slot == right.slot &&
           left.stream_id == right.stream_id;
}

[[nodiscard]] bool same_stream_identity(const CallConfig& call, const dmrd::Datagram& datagram, Slot slot) noexcept
{
    return call.source_id == datagram.source_id &&
           call.destination_id == datagram.destination_id &&
           call.slot == slot &&
           call.stream_id == datagram.stream_id;
}

[[nodiscard]] bool same_stream(const CallConfig& left, const CallConfig& right) noexcept
{
    return same_stream_identity(left, right) && left.kind == right.kind;
}

[[nodiscard]] bool same_stream(const CallConfig& call, const dmrd::Datagram& datagram, Slot slot) noexcept
{
    const auto kind = (datagram.flags & flag_private) != 0U ? CallKind::private_call : CallKind::group;
    return same_stream_identity(call, datagram, slot) && call.kind == kind;
}

[[nodiscard]] bool same_stream_id(const CallConfig& call, const dmrd::Datagram& datagram, Slot slot) noexcept
{
    return call.slot == slot && call.stream_id == datagram.stream_id;
}

[[nodiscard]] std::uint8_t call_flags(const CallConfig& call) noexcept
{
    return static_cast<std::uint8_t>((call.slot == Slot::ts2 ? flag_ts2 : 0U) |
                                     (call.kind == CallKind::private_call ? flag_private : 0U));
}

[[nodiscard]] bool metadata_matches_lc(const CallConfig& call,
                                        const dmr_signal::LinkControl& lc) noexcept
{
    const auto expected_flco = call.kind == CallKind::private_call ? 0x03U : 0x00U;
    return lc.source_id == call.source_id &&
           lc.destination_id == call.destination_id &&
           lc.flco == expected_flco;
}

void append_event(ReceiveResult& result, const ReceiveEvent& event) noexcept
{
    if (result.event_count < result.events.size()) {
        result.events[result.event_count++] = event;
    }
}

[[nodiscard]] ReceiveEvent make_event(ReceiveEventKind kind,
                                      const CallConfig& call,
                                      bool lc_validated,
                                      bool color_code_known) noexcept
{
    ReceiveEvent event{};
    event.kind = kind;
    event.call = call;
    event.link_control_validated = lc_validated;
    event.color_code_known = color_code_known;
    return event;
}

[[nodiscard]] bool valid_call_ids(const dmrd::Datagram& datagram) noexcept
{
    return datagram.source_id != 0U && datagram.destination_id != 0U &&
           datagram.source_id <= dmrd::max_id24 && datagram.destination_id <= dmrd::max_id24;
}

[[nodiscard]] bool sequence_is_newer(std::uint8_t next, std::uint8_t previous) noexcept
{
    const auto delta = static_cast<std::uint8_t>(next - previous);
    return delta != 0U && delta < 128U;
}

[[nodiscard]] std::uint32_t sequence_gap(std::uint8_t next, std::uint8_t previous) noexcept
{
    const auto delta = static_cast<std::uint8_t>(next - previous);
    return delta > 1U && delta < 128U ? static_cast<std::uint32_t>(delta - 1U) : 0U;
}

[[nodiscard]] dmr_signal::LinkControl to_link_control(const CallConfig& call) noexcept
{
    dmr_signal::LinkControl lc{};
    lc.flco = call.kind == CallKind::private_call ? 0x03U : 0x00U;
    lc.destination_id = call.destination_id;
    lc.source_id = call.source_id;
    return lc;
}

[[nodiscard]] CallConfig call_from_datagram(const dmrd::Datagram& datagram, Slot slot) noexcept
{
    CallConfig call{};
    call.source_id = datagram.source_id;
    call.destination_id = datagram.destination_id;
    call.gateway_id = datagram.gateway_id;
    call.stream_id = datagram.stream_id;
    call.slot = slot;
    call.kind = (datagram.flags & flag_private) != 0U ? CallKind::private_call : CallKind::group;
    return call;
}

[[nodiscard]] bool valid_lc_for_datagram(const dmr_signal::DecodedFullLc& decoded,
                                         const dmrd::Datagram& datagram,
                                         Slot slot) noexcept
{
    if (!decoded.valid) {
        return false;
    }
    const auto packet_call = call_from_datagram(datagram, slot);
    return metadata_matches_lc(packet_call, decoded.link_control);
}

} // namespace

TxResult Transmitter::start(const CallConfig& call) noexcept
{
    TxResult result{};
    if (active_) {
        result.error = TxError::already_active;
        return result;
    }
    if (call.source_id == 0U || call.source_id > dmrd::max_id24) {
        result.error = TxError::invalid_source_id;
        return result;
    }
    if (call.destination_id == 0U || call.destination_id > dmrd::max_id24) {
        result.error = TxError::invalid_destination_id;
        return result;
    }
    if (!valid_slot(call.slot)) {
        result.error = TxError::invalid_slot;
        return result;
    }
    if (call.color_code > 15U) {
        result.error = TxError::invalid_color_code;
        return result;
    }

    call_ = call;
    active_ = true;
    sequence_ = 0U;
    next_voice_index_ = 0U;
    result.packet = make_control(PacketKind::voice_lc_header, 0x01U);
    sequence_ = static_cast<std::uint8_t>(sequence_ + 1U);
    return result;
}

TxResult Transmitter::voice(const AmbeVoiceBurst& ambe) noexcept
{
    TxResult result{};
    if (!active_) {
        result.error = TxError::not_active;
        return result;
    }

    const auto index = next_voice_index_;
    result.packet.kind = index == 0U ? PacketKind::voice_sync : PacketKind::voice;
    result.packet.voice_burst_index = index;
    result.packet.datagram.sequence = sequence_;
    result.packet.datagram.source_id = call_.source_id;
    result.packet.datagram.destination_id = call_.destination_id;
    result.packet.datagram.gateway_id = call_.gateway_id;
    result.packet.datagram.stream_id = call_.stream_id;
    result.packet.datagram.flags = static_cast<std::uint8_t>(call_flags(call_) |
        (index == 0U ? flag_voice_sync : index));
    result.packet.datagram.payload = dmr_signal::encode_voice_burst(
        ambe, to_link_control(call_), call_.color_code, index);
    sequence_ = static_cast<std::uint8_t>(sequence_ + 1U);
    next_voice_index_ = static_cast<std::uint8_t>((next_voice_index_ + 1U) % 6U);
    return result;
}

TxResult Transmitter::finish() noexcept
{
    TxResult result{};
    if (!active_) {
        result.error = TxError::not_active;
        return result;
    }
    result.packet = make_control(PacketKind::terminator_with_lc, 0x02U);
    sequence_ = static_cast<std::uint8_t>(sequence_ + 1U);
    active_ = false;
    return result;
}

void Transmitter::reset() noexcept
{
    call_ = {};
    active_ = false;
    sequence_ = 0U;
    next_voice_index_ = 0U;
}

TxPacket Transmitter::make_control(PacketKind kind, std::uint8_t data_type) const noexcept
{
    TxPacket packet{};
    packet.kind = kind;
    packet.voice_burst_index = no_voice_index;
    packet.datagram.sequence = sequence_;
    packet.datagram.source_id = call_.source_id;
    packet.datagram.destination_id = call_.destination_id;
    packet.datagram.gateway_id = call_.gateway_id;
    packet.datagram.flags = static_cast<std::uint8_t>(call_flags(call_) | flag_data_sync | data_type);
    packet.datagram.stream_id = call_.stream_id;
    const auto lc = to_link_control(call_);
    packet.datagram.payload = dmr_signal::encode_full_lc(
        lc, kind == PacketKind::voice_lc_header ? dmr_signal::FullLcType::voice_header
                                                : dmr_signal::FullLcType::terminator,
        call_.color_code);
    return packet;
}

Receiver::Receiver(ReceiveOptions options) noexcept : options_(options)
{
    if (options_.watchdog.count() <= 0) {
        options_.watchdog = default_receive_timeout;
    }
    if (options_.retired_stream_lifetime.count() < 0) {
        options_.retired_stream_lifetime = default_retired_stream_lifetime;
    }
}

ReceiveResult Receiver::poll(Receiver::Clock::time_point now) noexcept
{
    ReceiveResult result{};
    for (auto& retired : retired_) {
        if (retired.valid && now >= retired.expires_at) {
            retired.valid = false;
        }
    }
    for (auto& state : slots_) {
        if (!state.active || now < state.last_activity || now - state.last_activity < options_.watchdog) {
            continue;
        }
        auto event = make_event(ReceiveEventKind::call_ended, state.call,
                                state.link_control_validated, state.color_code_known);
        event.end_reason = CallEndReason::watchdog;
        append_event(result, event);
        retired_[retired_cursor_ % retired_.size()] = RetiredStream{
            true, state.call, now + options_.retired_stream_lifetime};
        retired_cursor_ = static_cast<std::uint8_t>((retired_cursor_ + 1U) % retired_.size());
        state = {};
    }
    if (result.event_count != 0U) {
        result.status = ReceiveStatus::accepted;
    }
    return result;
}

ReceiveResult Receiver::ingest(const dmrd::Datagram& datagram, Receiver::Clock::time_point now) noexcept
{
    ReceiveResult result{};
    const Slot slot = (datagram.flags & flag_ts2) != 0U ? Slot::ts2 : Slot::ts1;
    const auto index = slot_index(slot);
    auto& state = slots_[index];

    for (auto& retired : retired_) {
        if (retired.valid && now >= retired.expires_at) {
            retired.valid = false;
        }
    }
    if (state.active && now >= state.last_activity && now - state.last_activity >= options_.watchdog) {
        auto event = make_event(ReceiveEventKind::call_ended, state.call,
                                state.link_control_validated, state.color_code_known);
        event.end_reason = CallEndReason::watchdog;
        append_event(result, event);
        retired_[retired_cursor_ % retired_.size()] = RetiredStream{
            true, state.call, now + options_.retired_stream_lifetime};
        retired_cursor_ = static_cast<std::uint8_t>((retired_cursor_ + 1U) % retired_.size());
        state = {};
    }

    if (!valid_call_ids(datagram)) {
        result.status = ReceiveStatus::malformed;
        result.error = ReceiveError::invalid_call_id;
        return result;
    }

    const bool data_sync = (datagram.flags & flag_data_sync) != 0U;
    const bool voice_sync = (datagram.flags & flag_voice_sync) != 0U;
    const auto low_flags = static_cast<std::uint8_t>(datagram.flags & data_type_mask);
    if (data_sync && voice_sync) {
        result.status = ReceiveStatus::malformed;
        result.error = ReceiveError::unsupported_flags;
        return result;
    }

    enum class IncomingKind : std::uint8_t { header, voice_sync, voice, terminator };
    IncomingKind incoming_kind{};
    std::uint8_t voice_index = no_voice_index;
    dmr_signal::DecodedFullLc decoded_lc{};

    if (data_sync) {
        if (low_flags == 0x01U) {
            incoming_kind = IncomingKind::header;
            decoded_lc = dmr_signal::decode_full_lc(datagram.payload, dmr_signal::FullLcType::voice_header);
        } else if (low_flags == 0x02U) {
            incoming_kind = IncomingKind::terminator;
            decoded_lc = dmr_signal::decode_full_lc(datagram.payload, dmr_signal::FullLcType::terminator);
        } else {
            result.status = ReceiveStatus::malformed;
            result.error = ReceiveError::unsupported_flags;
            return result;
        }
        if (!valid_lc_for_datagram(decoded_lc, datagram, slot)) {
            result.status = ReceiveStatus::malformed;
            result.error = decoded_lc.valid ? ReceiveError::link_control_mismatch : ReceiveError::invalid_full_lc;
            return result;
        }
    } else if (voice_sync) {
        if (low_flags != 0U) {
            result.status = ReceiveStatus::malformed;
            result.error = ReceiveError::invalid_burst_index;
            return result;
        }
        incoming_kind = IncomingKind::voice_sync;
        if (!dmr_signal::has_audio_sync(datagram.payload)) {
            result.status = ReceiveStatus::malformed;
            result.error = ReceiveError::invalid_sync;
            return result;
        }
        voice_index = 0U;
    } else {
        if (low_flags == 0U || low_flags > max_voice_burst_index) {
            result.status = ReceiveStatus::malformed;
            result.error = ReceiveError::invalid_burst_index;
            return result;
        }
        incoming_kind = IncomingKind::voice;
        voice_index = low_flags;
    }

    const auto candidate = call_from_datagram(datagram, slot);
    const auto is_retired = [this, &candidate, now]() noexcept {
        for (const auto& retired : retired_) {
            if (retired.valid && now < retired.expires_at && same_stream_identity(retired.call, candidate)) {
                return true;
            }
        }
        return false;
    };

    if (incoming_kind == IncomingKind::header) {
        if (is_retired()) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_stream;
            return result;
        }
        if (state.active && same_stream(state.call, candidate)) {
            if (now < state.last_activity) {
                result.status = ReceiveStatus::ignored;
                result.error = ReceiveError::stale_or_duplicate_sequence;
                return result;
            }
            const auto delta = static_cast<std::uint8_t>(datagram.sequence - state.last_sequence);
            if (state.has_sequence && (delta == 0U || delta >= 128U)) {
                result.sequence = SequenceObservation{true, false, delta == 0U, delta != 0U,
                                                      false, false, state.call, 0U};
                if (!state.link_control_validated) {
                    state.link_control_validated = true;
                    state.call.color_code = decoded_lc.color_code;
                    state.color_code_known = true;
                    auto event = make_event(ReceiveEventKind::link_control_confirmed, state.call, true, true);
                    event.link_control_origin = LinkControlOrigin::full_lc_header;
                    append_event(result, event);
                    result.status = ReceiveStatus::accepted;
                    return result;
                }
                result.status = ReceiveStatus::ignored;
                result.error = ReceiveError::stale_or_duplicate_sequence;
                return result;
            }
            std::uint32_t missing = 0U;
            if (state.has_sequence) {
                missing = sequence_gap(datagram.sequence, state.last_sequence);
            }
            state.last_sequence = datagram.sequence;
            state.has_sequence = true;
            state.last_activity = now;
            state.call.gateway_id = datagram.gateway_id;
            state.call.color_code = decoded_lc.color_code;
            state.color_code_known = true;
            if (!state.link_control_validated) {
                state.link_control_validated = true;
                auto event = make_event(ReceiveEventKind::link_control_confirmed, state.call, true, true);
                event.link_control_origin = LinkControlOrigin::full_lc_header;
                event.missing_packets = missing;
                append_event(result, event);
            }
            result.sequence = SequenceObservation{true, true, false, false,
                                                  false, false, state.call, missing};
            result.status = ReceiveStatus::accepted;
            return result;
        }

        if (state.active) {
            if (same_stream_id(state.call, datagram, slot)) {
                result.status = ReceiveStatus::malformed;
                result.error = ReceiveError::link_control_mismatch;
                return result;
            }
            auto ended = make_event(ReceiveEventKind::call_ended, state.call,
                                    state.link_control_validated, state.color_code_known);
            ended.end_reason = CallEndReason::replaced_by_new_stream;
            append_event(result, ended);
            retired_[retired_cursor_ % retired_.size()] = RetiredStream{
                true, state.call, now + options_.retired_stream_lifetime};
            retired_cursor_ = static_cast<std::uint8_t>((retired_cursor_ + 1U) % retired_.size());
        }
        state = {};
        state.active = true;
        state.has_sequence = true;
        state.link_control_validated = true;
        state.color_code_known = true;
        state.call = candidate;
        state.call.color_code = decoded_lc.color_code;
        state.last_sequence = datagram.sequence;
        state.last_activity = now;
        result.sequence = SequenceObservation{true, true, false, false,
                                              true, false, state.call, 0U};
        append_event(result, make_event(ReceiveEventKind::call_started, state.call, true, true));
        result.status = ReceiveStatus::accepted;
        return result;
    }

    if (incoming_kind == IncomingKind::terminator) {
        if (is_retired()) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_stream;
            return result;
        }
        if (!state.active || !same_stream(state.call, candidate)) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::no_active_stream;
            return result;
        }
        if (now < state.last_activity) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_or_duplicate_sequence;
            return result;
        }
        const auto delta = static_cast<std::uint8_t>(datagram.sequence - state.last_sequence);
        if (state.has_sequence && (delta == 0U || delta >= 128U)) {
            result.sequence = SequenceObservation{true, false, delta == 0U, delta != 0U,
                                                  false, false, state.call, 0U};
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_or_duplicate_sequence;
            return result;
        }
        auto ended = make_event(ReceiveEventKind::call_ended, state.call, true, true);
        ended.end_reason = CallEndReason::terminator;
        if (state.has_sequence) {
            ended.missing_packets = sequence_gap(datagram.sequence, state.last_sequence);
        }
        result.sequence = SequenceObservation{true, true, false, false,
                                              false, true, state.call, ended.missing_packets};
        append_event(result, ended);
        retired_[retired_cursor_ % retired_.size()] = RetiredStream{
            true, state.call, now + options_.retired_stream_lifetime};
        retired_cursor_ = static_cast<std::uint8_t>((retired_cursor_ + 1U) % retired_.size());
        state = {};
        result.status = ReceiveStatus::accepted;
        return result;
    }

    std::uint32_t missing = 0U;
    bool starts_call = false;
    if (state.active && same_stream_id(state.call, datagram, slot) && !same_stream(state.call, candidate)) {
        result.status = ReceiveStatus::malformed;
        result.error = ReceiveError::link_control_mismatch;
        return result;
    }
    if (state.active && same_stream(state.call, candidate)) {
        if (now < state.last_activity) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_or_duplicate_sequence;
            return result;
        }
        const auto delta = static_cast<std::uint8_t>(datagram.sequence - state.last_sequence);
        if (state.has_sequence && (delta == 0U || delta >= 128U)) {
            result.sequence = SequenceObservation{true, false, delta == 0U, delta != 0U,
                                                  false, false, state.call, 0U};
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_or_duplicate_sequence;
            return result;
        }
        if (state.has_sequence) {
            missing = sequence_gap(datagram.sequence, state.last_sequence);
        }
        state.last_sequence = datagram.sequence;
        state.has_sequence = true;
        state.last_activity = now;
        state.call.gateway_id = datagram.gateway_id;
    } else if (state.active) {
        if (is_retired()) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_stream;
            return result;
        }
        const auto inactive_for = now >= state.last_activity ? now - state.last_activity : Clock::duration::zero();
        const bool sequence_forward = state.has_sequence && sequence_is_newer(datagram.sequence, state.last_sequence);
        const bool enough_idle = inactive_for >= voice_burst_period * 2;
        if (incoming_kind != IncomingKind::voice_sync || (!sequence_forward && !enough_idle)) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_stream;
            return result;
        }
        auto ended = make_event(ReceiveEventKind::call_ended, state.call,
                                state.link_control_validated, state.color_code_known);
        ended.end_reason = CallEndReason::replaced_by_new_stream;
        append_event(result, ended);
        retired_[retired_cursor_ % retired_.size()] = RetiredStream{
            true, state.call, now + options_.retired_stream_lifetime};
        retired_cursor_ = static_cast<std::uint8_t>((retired_cursor_ + 1U) % retired_.size());
        state = {};
        state.active = true;
        state.has_sequence = true;
        starts_call = true;
        state.call = candidate;
        state.last_sequence = datagram.sequence;
        state.last_voice_burst_index = 0U;
        state.last_activity = now;
        state.embedded_block_count = 0U;
        append_event(result, make_event(ReceiveEventKind::call_started, state.call, false, false));
    } else {
        if (incoming_kind != IncomingKind::voice_sync) {
            result.status = ReceiveStatus::ignored;
            result.error = is_retired() ? ReceiveError::stale_stream : ReceiveError::no_active_stream;
            return result;
        }
        if (is_retired()) {
            result.status = ReceiveStatus::ignored;
            result.error = ReceiveError::stale_stream;
            return result;
        }
        state = {};
        state.active = true;
        state.has_sequence = true;
        starts_call = true;
        state.call = candidate;
        state.last_sequence = datagram.sequence;
        state.last_voice_burst_index = 0U;
        state.last_activity = now;
        append_event(result, make_event(ReceiveEventKind::call_started, state.call, false, false));
    }

    if (incoming_kind == IncomingKind::voice_sync) {
        state.last_voice_burst_index = 0U;
        state.embedded_block_count = 0U;
        state.embedded_data.fill(false);
    } else {
        state.last_voice_burst_index = voice_index;
    }

    const auto signaling = incoming_kind == IncomingKind::voice
        ? dmr_signal::decode_embedded_signaling(datagram.payload)
        : dmr_signal::EmbeddedSignaling{};
    if (signaling.valid && !state.color_code_known) {
        state.call.color_code = signaling.color_code;
        state.color_code_known = true;
    }

    auto voice_event = make_event(ReceiveEventKind::voice, state.call,
                                  state.link_control_validated, state.color_code_known);
    voice_event.voice = dmr_signal::decode_voice_burst(datagram.payload);
    voice_event.voice_burst_index = voice_index;
    voice_event.missing_packets = missing;
    result.sequence = SequenceObservation{true, true, false, false,
                                          starts_call, false, state.call, missing};
    append_event(result, voice_event);

    if (incoming_kind == IncomingKind::voice) {
        if (signaling.valid) {
            std::array<bool, 32U> block{};
            if (signaling.lcss == 1U && dmr_signal::decode_embedded_lc_block(datagram.payload, block)) {
                state.embedded_data.fill(false);
                std::copy(block.begin(), block.end(), state.embedded_data.begin());
                state.embedded_block_count = 1U;
            } else if (signaling.lcss == 3U && state.embedded_block_count >= 1U && state.embedded_block_count <= 2U &&
                       dmr_signal::decode_embedded_lc_block(datagram.payload, block)) {
                std::copy(block.begin(), block.end(), state.embedded_data.begin() + state.embedded_block_count * 32U);
                ++state.embedded_block_count;
            } else if (signaling.lcss == 2U && state.embedded_block_count == 3U &&
                       dmr_signal::decode_embedded_lc_block(datagram.payload, block)) {
                std::copy(block.begin(), block.end(), state.embedded_data.begin() + 96U);
                dmr_signal::LinkControl embedded_lc{};
                if (dmr_signal::decode_embedded_lc(state.embedded_data, embedded_lc) &&
                    metadata_matches_lc(state.call, embedded_lc)) {
                    state.link_control_validated = true;
                    auto lc_event = make_event(ReceiveEventKind::link_control_confirmed,
                                               state.call, true, state.color_code_known);
                    lc_event.link_control_origin = LinkControlOrigin::embedded_lc;
                    append_event(result, lc_event);
                }
                state.embedded_block_count = 0U;
            } else if (signaling.lcss != 3U) {
                state.embedded_block_count = 0U;
            }
        }
    }

    result.status = ReceiveStatus::accepted;
    return result;
}

void Receiver::reset() noexcept
{
    slots_ = {};
    retired_ = {};
    retired_cursor_ = 0U;
}

} // namespace wirex::dmr_call
