/* SPDX-License-Identifier: GPL-3.0-or-later
 * 本接口定义 DMRD 通话帧和流状态，不包含声码器实现。
 * FEC/LC 算法来源和固定上游提交见 docs/DMR通话实现.md。
 */
#pragma once

#include "wirex/dmrd.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>

namespace wirex::dmr_call {

inline constexpr std::size_t ambe_codeword_size = 9U;
inline constexpr std::size_t codewords_per_burst = 3U;
inline constexpr std::size_t ambe_burst_size = ambe_codeword_size * codewords_per_burst;
inline constexpr std::chrono::milliseconds voice_burst_period{60};
inline constexpr std::chrono::milliseconds default_receive_timeout{360};
inline constexpr std::chrono::milliseconds default_retired_stream_lifetime{2000};

enum class Slot : std::uint8_t {
    ts1 = 1U,
    ts2 = 2U,
};

enum class CallKind : std::uint8_t {
    group,
    private_call,
};

enum class PacketKind : std::uint8_t {
    voice_lc_header,
    voice_sync,
    voice,
    terminator_with_lc,
};

enum class CallEndReason : std::uint8_t {
    terminator,
    watchdog,
    replaced_by_new_stream,
};

enum class LinkControlOrigin : std::uint8_t {
    full_lc_header,
    embedded_lc,
};

struct CallConfig {
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    std::uint32_t gateway_id{};
    std::array<std::uint8_t, 4U> stream_id{};
    Slot slot{Slot::ts1};
    CallKind kind{CallKind::group};
    std::uint8_t color_code{};
};

using AmbeVoiceBurst = std::array<std::uint8_t, ambe_burst_size>;

struct TxPacket {
    dmrd::Datagram datagram{};
    PacketKind kind{PacketKind::voice_lc_header};
    std::uint8_t voice_burst_index{};
};

enum class TxError : std::uint8_t {
    none,
    invalid_source_id,
    invalid_destination_id,
    invalid_slot,
    invalid_color_code,
    already_active,
    not_active,
};

struct TxResult {
    TxPacket packet{};
    TxError error{TxError::none};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == TxError::none;
    }
};

class Transmitter final {
public:
    [[nodiscard]] TxResult start(const CallConfig& call) noexcept;
    [[nodiscard]] TxResult voice(const AmbeVoiceBurst& ambe) noexcept;
    [[nodiscard]] TxResult finish() noexcept;
    void reset() noexcept;

    [[nodiscard]] bool active() const noexcept { return active_; }
    [[nodiscard]] std::uint8_t next_sequence() const noexcept { return sequence_; }

private:
    [[nodiscard]] TxPacket make_control(PacketKind kind, std::uint8_t data_type) const noexcept;

    CallConfig call_{};
    bool active_{};
    std::uint8_t sequence_{};
    std::uint8_t next_voice_index_{};
};

enum class ReceiveEventKind : std::uint8_t {
    call_started,
    voice,
    link_control_confirmed,
    call_ended,
};

struct ReceiveEvent {
    ReceiveEventKind kind{ReceiveEventKind::call_started};
    CallConfig call{};
    AmbeVoiceBurst voice{};
    CallEndReason end_reason{CallEndReason::terminator};
    LinkControlOrigin link_control_origin{LinkControlOrigin::full_lc_header};
    std::uint8_t voice_burst_index{};
    std::uint32_t missing_packets{};
    bool link_control_validated{};
    bool color_code_known{};
};

enum class ReceiveStatus : std::uint8_t {
    accepted,
    ignored,
    malformed,
};

enum class ReceiveError : std::uint8_t {
    none,
    invalid_call_id,
    unsupported_flags,
    invalid_burst_index,
    invalid_sync,
    invalid_slot_type,
    invalid_full_lc,
    link_control_mismatch,
    stale_or_duplicate_sequence,
    stale_stream,
    no_active_stream,
};

struct ReceiveResult {
    ReceiveStatus status{ReceiveStatus::ignored};
    ReceiveError error{ReceiveError::none};
    // ingest 最多返回旧流结束、新流开始和当前语音三项；poll 可返回双时隙各一项。
    std::array<ReceiveEvent, 3U> events{};
    std::uint8_t event_count{};

    [[nodiscard]] constexpr bool accepted() const noexcept
    {
        return status == ReceiveStatus::accepted;
    }
};

struct ReceiveOptions {
    std::chrono::milliseconds watchdog{default_receive_timeout};
    std::chrono::milliseconds retired_stream_lifetime{default_retired_stream_lifetime};
};

class Receiver final {
public:
    using Clock = std::chrono::steady_clock;

    explicit Receiver(ReceiveOptions options = {}) noexcept;

    // 只检查当前包所在时隙的超时；poll 会扫描双时隙，避免一次 ingest 丢失结束事件。
    // 允许以校验通过的 voice-sync A 建流；LC 解出前用 DMRD 字段标识通话。
    [[nodiscard]] ReceiveResult ingest(const dmrd::Datagram& datagram, Clock::time_point now) noexcept;
    [[nodiscard]] ReceiveResult poll(Clock::time_point now) noexcept;
    void reset() noexcept;

private:
    struct SlotState {
        bool active{};
        bool has_sequence{};
        bool link_control_validated{};
        bool color_code_known{};
        CallConfig call{};
        std::uint8_t last_sequence{};
        std::uint8_t last_voice_burst_index{};
        std::uint8_t embedded_block_count{};
        std::array<bool, 128U> embedded_data{};
        Clock::time_point last_activity{};
    };

    struct RetiredStream {
        bool valid{};
        CallConfig call{};
        Clock::time_point expires_at{};
    };

    ReceiveOptions options_{};
    std::array<SlotState, 2U> slots_{};
    std::array<RetiredStream, 8U> retired_{};
    std::uint8_t retired_cursor_{};
};

} // namespace wirex::dmr_call
