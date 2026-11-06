#pragma once

#include "wirex/dmr_call.hpp"
#include "wirex/talkgroup_routing.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::quick_call {

enum class PlanError : std::uint8_t {
    none,
    invalid_source_id,
    invalid_group_id,
    disconnect_group_forbidden,
    invalid_slot,
    invalid_color_code,
    transmitter_failure,
};

struct Plan {
    talkgroup_routing::GroupRoute group{};
    std::array<dmr_call::TxPacket, 2U> frames{};
};

struct PlanResult {
    Plan plan{};
    PlanError error{PlanError::none};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == PlanError::none;
    }
};

// Quick Call 由有效组呼 LC header 和终止帧组成，不生成语音或调用声码器。
// TG4000 用于断开动态组，不能作为加入目标。
[[nodiscard]] inline PlanResult make_group_plan(std::uint32_t source_id,
                                                std::uint32_t gateway_id,
                                                const talkgroup_routing::GroupRoute& group,
                                                std::uint8_t color_code,
                                                const std::array<std::uint8_t, 4U>& stream_id) noexcept
{
    PlanResult result{};
    if (source_id == 0U || source_id > dmrd::max_id24) {
        result.error = PlanError::invalid_source_id;
        return result;
    }
    if (group.destination_id == 0U || group.destination_id > dmrd::max_id24) {
        result.error = PlanError::invalid_group_id;
        return result;
    }
    if (group.destination_id == 4000U) {
        result.error = PlanError::disconnect_group_forbidden;
        return result;
    }
    if (group.slot != dmr_call::Slot::ts1 && group.slot != dmr_call::Slot::ts2) {
        result.error = PlanError::invalid_slot;
        return result;
    }
    if (color_code > 15U) {
        result.error = PlanError::invalid_color_code;
        return result;
    }

    dmr_call::CallConfig call{};
    call.source_id = source_id;
    call.destination_id = group.destination_id;
    call.gateway_id = gateway_id;
    call.stream_id = stream_id;
    call.slot = group.slot;
    call.kind = dmr_call::CallKind::group;
    call.color_code = color_code;

    dmr_call::Transmitter transmitter;
    const auto header = transmitter.start(call);
    if (!header) {
        result.error = PlanError::transmitter_failure;
        return result;
    }
    const auto terminator = transmitter.finish();
    if (!terminator) {
        result.error = PlanError::transmitter_failure;
        return result;
    }
    result.plan.group = group;
    result.plan.frames[0U] = header.packet;
    result.plan.frames[1U] = terminator.packet;
    return result;
}

// R131 增补：TG4000 断开计划（停用该时隙全部动态组）。帧结构与 make_group_plan 相同，目标固定为 4000，
// 不做 disconnect_group_forbidden 检查。make_group_plan 对 4000 仍然禁止。
inline constexpr std::uint32_t disconnect_group_id = 4000U;

[[nodiscard]] inline PlanResult make_disconnect_plan(std::uint32_t source_id,
                                                     std::uint32_t gateway_id,
                                                     dmr_call::Slot slot,
                                                     std::uint8_t color_code,
                                                     const std::array<std::uint8_t, 4U>& stream_id) noexcept
{
    PlanResult result{};
    if (source_id == 0U || source_id > dmrd::max_id24) {
        result.error = PlanError::invalid_source_id;
        return result;
    }
    if (slot != dmr_call::Slot::ts1 && slot != dmr_call::Slot::ts2) {
        result.error = PlanError::invalid_slot;
        return result;
    }
    if (color_code > 15U) {
        result.error = PlanError::invalid_color_code;
        return result;
    }

    dmr_call::CallConfig call{};
    call.source_id = source_id;
    call.destination_id = disconnect_group_id;
    call.gateway_id = gateway_id;
    call.stream_id = stream_id;
    call.slot = slot;
    call.kind = dmr_call::CallKind::group;
    call.color_code = color_code;

    dmr_call::Transmitter transmitter;
    const auto header = transmitter.start(call);
    if (!header) {
        result.error = PlanError::transmitter_failure;
        return result;
    }
    const auto terminator = transmitter.finish();
    if (!terminator) {
        result.error = PlanError::transmitter_failure;
        return result;
    }
    result.plan.group = talkgroup_routing::GroupRoute{disconnect_group_id, slot};
    result.plan.frames[0U] = header.packet;
    result.plan.frames[1U] = terminator.packet;
    return result;
}

enum class GateStatus : std::uint8_t {
    ready,
    not_ready,
    busy,
};

struct Readiness {
    bool control_ready{};
    bool bm_ready{};
    bool transport_open{};
    bool pipeline_idle{};
    bool media_owner_idle{};
    bool hri_stream_idle{};
    bool cleanup_idle{};
};

[[nodiscard]] constexpr GateStatus check_readiness(const Readiness& state) noexcept
{
    if (!state.control_ready || !state.bm_ready || !state.transport_open) {
        return GateStatus::not_ready;
    }
    if (!state.pipeline_idle || !state.media_owner_idle || !state.hri_stream_idle || !state.cleanup_idle) {
        return GateStatus::busy;
    }
    return GateStatus::ready;
}

enum class SendStatus : std::uint8_t {
    sent,
    send_failed,
    partial_send,
};

struct SendOutcome {
    SendStatus status{SendStatus::send_failed};
    std::uint8_t packets_sent{};
};

// 每帧只调用一次注入的发送器，首个失败后立即停止。重试必须由用户再次明确操作，
// 并使用新的 request_id。
template <typename SendFrame>
[[nodiscard]] SendOutcome send_once(const Plan& plan, SendFrame&& send_frame) noexcept
{
    std::uint8_t sent = 0U;
    for (const auto& frame : plan.frames) {
        bool succeeded = false;
        try { succeeded = send_frame(frame); }
        catch (...) { succeeded = false; }
        if (!succeeded) {
            return {sent == 0U ? SendStatus::send_failed : SendStatus::partial_send, sent};
        }
        ++sent;
    }
    return {SendStatus::sent, sent};
}

[[nodiscard]] inline bool same_datagram(const dmr_call::TxPacket& expected,
                                        const dmr_call::TxPacket& actual) noexcept
{
    const auto& left = expected.datagram;
    const auto& right = actual.datagram;
    return expected.kind == actual.kind && expected.voice_burst_index == actual.voice_burst_index &&
        left.sequence == right.sequence && left.source_id == right.source_id &&
        left.destination_id == right.destination_id && left.gateway_id == right.gateway_id &&
        left.flags == right.flags && left.stream_id == right.stream_id &&
        left.payload == right.payload && left.ber == right.ber && left.rssi == right.rssi;
}

[[nodiscard]] inline bool same_datagram(const dmr_call::TxPacket& expected,
                                        const dmrd::Datagram& actual) noexcept
{
    const auto& left = expected.datagram;
    return left.sequence == actual.sequence && left.source_id == actual.source_id &&
        left.destination_id == actual.destination_id && left.gateway_id == actual.gateway_id &&
        left.flags == actual.flags && left.stream_id == actual.stream_id &&
        left.payload == actual.payload && left.ber == actual.ber && left.rssi == actual.rssi;
}

} // namespace wirex::quick_call
