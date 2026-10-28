#pragma once

#include "wirex/dmr_call.hpp"
#include "wirex/dmr_vocoder.hpp"
#include "wirex/pcm_resampler.hpp"
#include "wirex/talkgroup_routing.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

namespace wirex::bm_voice {

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

inline constexpr std::size_t pcm48_samples_per_frame = 960U;
inline constexpr std::size_t max_tx_audio_samples_per_push = 4800U;
inline constexpr std::size_t max_tx_queued_codewords = 36U;
inline constexpr std::size_t tx_start_prebuffer_codewords = 6U;
inline constexpr std::size_t max_rx_queued_bursts = 50U;
inline constexpr std::size_t max_rx_queued_pcm_frames = 150U;
inline constexpr std::size_t max_unconfirmed_playback_frames = 3U;
inline constexpr std::size_t max_pipeline_events = 16U;
inline constexpr std::uint32_t max_missing_bursts_to_compensate = 4U;
inline constexpr std::size_t max_routed_rx_staging_datagrams = 8U;
inline constexpr auto receive_start_timeout = std::chrono::seconds{3};
inline constexpr auto voice_schedule_reanchor_lateness = std::chrono::milliseconds{20};
inline constexpr auto max_voice_schedule_lateness = std::chrono::milliseconds{120};

using Pcm48Frame = std::array<std::int16_t, pcm48_samples_per_frame>;

struct PlaybackFrame {
    Pcm48Frame pcm{};
    std::size_t sample_count{pcm48_samples_per_frame};
    std::uint64_t generation{};
};

enum class Error : std::uint8_t {
    none,
    busy,
    bm_not_ready,
    hri_not_ready,
    codec_failure,
    generation_exhausted,
    invalid_call,
    not_active,
    invalid_playback_ack,
    stale_playback_ack,
    tx_input_too_large,
    tx_queue_full,
    rx_queue_full,
    event_queue_full,
    playback_not_waiting,
    no_receive_call,
    filtered,
    playback_start_timeout,
    half_duplex_collision,
    clock_reversed,
    deadline_missed,
    resource_failure,
};

struct Readiness {
    bool bm_ready{};
    bool hri_ready{};
};

struct TxPushResult {
    Error error{Error::none};
    std::size_t encoded_frames{};

    [[nodiscard]] constexpr explicit operator bool() const noexcept
    {
        return error == Error::none;
    }
};

enum class TxState : std::uint8_t {
    idle,
    active,
    draining,
};

enum class RxState : std::uint8_t {
    idle,
    filtered,
    waiting_for_playback,
    buffering,
    playing,
    draining,
    stopping,
};

enum class EventKind : std::uint8_t {
    receive_started,
    network_ended,
    playback_drained,
    receive_cancelled,
    playback_start_timeout,
    collision,
    queue_overflow,
};

struct Event {
    EventKind kind{EventKind::receive_started};
    dmr_call::CallConfig call{};
    dmr_call::CallEndReason end_reason{dmr_call::CallEndReason::terminator};
    std::uint32_t missing_packets{};
    // 本接收代中、结束或取消前已接收并入队的有效DMR语音burst数。
    std::uint64_t accepted_voice_bursts{};
    bool link_control_validated{};
    bool color_code_known{};
    std::uint64_t generation{};
};

struct ReceiveFilter {
    std::uint32_t destination_id{}; // 0 表示不限制目标 ID。
    bool match_slot{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    bool match_call_kind{};
    dmr_call::CallKind call_kind{dmr_call::CallKind::group};
    std::uint32_t source_id{}; // 仅在 match_source_id 时参与过滤。
    bool match_source_id{};
};

struct ReceiveResult {
    dmr_call::ReceiveResult protocol{};
    Error error{Error::none};
};

struct Snapshot {
    TxState tx_state{TxState::idle};
    RxState rx_state{RxState::idle};
    dmr_call::CallConfig receive_call{};
    std::size_t queued_tx_codewords{};
    std::size_t queued_rx_bursts{};
    std::size_t queued_playback_frames{};
    std::size_t unconfirmed_playback_frames{};
    std::size_t buffered_receive_frames{};
    std::uint64_t receive_generation{};
    bool receive_generation_exhausted{};
    std::uint64_t accepted_receive_voice_bursts{};
    bool receive_link_control_validated{};
    bool receive_color_code_known{};
    // EOT 后本地播放队列可能仍在排空；UI 的当前网络话者应在此为 true 时清除。
    bool receive_network_ended{};
};

enum class ReceiveHriStartDecision : std::uint8_t {
    inactive,
    wait_for_voice,
    start_hri,
    discard_empty_ended_call,
};

// 原生协调器与离线测试共用：只有已准入且收到有效语音媒体的接收代才能启动HRI T3。
[[nodiscard]] ReceiveHriStartDecision receive_hri_start_decision(
    const Snapshot& snapshot) noexcept;

struct RxGenerationMapping {
    // Router和pipeline分别分配generation；外层必须按这组映射回报cleanup。
    std::uint64_t router_generation{};
    std::uint64_t pipeline_generation{};
};

struct RoutedSnapshot {
    talkgroup_routing::Snapshot router{};
    // active在接收/排空阶段有效；stopping保留到外层确认WinMM与HRI清理。
    std::optional<RxGenerationMapping> active_rx_mapping;
    std::optional<RxGenerationMapping> stopping_rx_mapping;
};

// 纯软件双向语音管线；外层负责 HRI、BM session 和真实设备的生命周期。
// 输入输出按 48 kHz PCM16、单声道分块；内部每 20 ms 运行一个 codec 帧，
// 再按 dmr_call 的 60 ms DMRD 语音 burst 节奏交付网络数据报。
class BmVoicePipeline final {
public:
    BmVoicePipeline();
    ~BmVoicePipeline();
    BmVoicePipeline(const BmVoicePipeline&) = delete;
    BmVoicePipeline& operator=(const BmVoicePipeline&) = delete;

    [[nodiscard]] Error set_receive_filter(const ReceiveFilter& filter) noexcept;
    [[nodiscard]] Error set_secondary_receive_filter(
        const std::optional<ReceiveFilter>& filter) noexcept;
    [[nodiscard]] Error enable_routing(std::uint32_t local_source_id,
                                       const talkgroup_routing::RxPolicy& rx_policy,
                                       const talkgroup_routing::TxPolicy& tx_policy) noexcept;
    [[nodiscard]] talkgroup_routing::PolicyUpdateResult replace_rx_policy(
        std::uint64_t expected_revision,
        const talkgroup_routing::RxPolicy& policy) noexcept;
    [[nodiscard]] talkgroup_routing::PolicyUpdateResult replace_tx_policy(
        std::uint64_t expected_revision,
        const talkgroup_routing::TxPolicy& policy) noexcept;
    [[nodiscard]] RoutedSnapshot routing_snapshot() const noexcept;
    [[nodiscard]] std::uint32_t routed_local_source_id() const noexcept;
    [[nodiscard]] const talkgroup_routing::RxPolicy* routed_rx_policy() const noexcept;
    [[nodiscard]] const talkgroup_routing::TxPolicy* routed_tx_policy() const noexcept;
    // 已撤销租约保持禁止发送语音，即使全局TX权限随后恢复；header/EOT由外层单独放行。
    [[nodiscard]] bool routed_tx_voice_permitted() const noexcept;
    [[nodiscard]] Error begin_routed_tx(const dmr_call::CallConfig& identity_template,
                                        Readiness readiness,
                                        TimePoint now) noexcept;
    [[nodiscard]] talkgroup_routing::OperationStatus observe_routed_ptt_release() noexcept;
    [[nodiscard]] talkgroup_routing::OperationStatus complete_routed_rx_cleanup(
        std::uint64_t pipeline_generation,
        bool cleanup_succeeded) noexcept;
    [[nodiscard]] talkgroup_routing::OperationStatus complete_routed_tx_eot(
        std::uint64_t lease_id,
        bool sent) noexcept;
    [[nodiscard]] talkgroup_routing::OperationStatus complete_routed_tx_cleanup(
        std::uint64_t lease_id,
        bool cleanup_succeeded) noexcept;
    [[nodiscard]] Error begin_tx(const dmr_call::CallConfig& call,
                                 Readiness readiness,
                                 TimePoint now) noexcept;
    [[nodiscard]] TxPushResult push_tx_audio(const std::int16_t* samples,
                                             std::size_t sample_count,
                                             TimePoint now) noexcept;
    [[nodiscard]] Error end_tx(TimePoint now) noexcept;
    // 丢弃尚未发送的语音并生成一个终止 LC；用于BM仍在线时用户主动停止。
    [[nodiscard]] Error stop_tx(TimePoint now) noexcept;
    // BM断线等无法发送终止包的场景只清本地媒体和待发数据报。
    void cancel_tx() noexcept;
    [[nodiscard]] std::optional<dmr_call::TxPacket> take_outbound() noexcept;

    [[nodiscard]] ReceiveResult ingest_rx(const dmrd::Datagram& datagram,
                                          TimePoint now) noexcept;
    [[nodiscard]] Error playback_ready(TimePoint now) noexcept;
    void cancel_rx() noexcept;
    [[nodiscard]] bool take_playback_pcm(PlaybackFrame& frame) noexcept;
    [[nodiscard]] Error acknowledge_playback(std::uint64_t generation,
                                             std::size_t completed_frames,
                                             TimePoint now) noexcept;
    [[nodiscard]] std::optional<Event> take_event() noexcept;

    // 每次调用最多发送一个 DMRD 语音 burst，并最多解码一个接收 burst；不会追赶补发。
    [[nodiscard]] Error tick(TimePoint now) noexcept;
    void reset() noexcept;
    [[nodiscard]] Snapshot snapshot() const noexcept;

private:
    struct StagedRxDatagram {
        dmrd::Datagram datagram{};
        TimePoint time{};
    };

    struct RetiredRoutedStream {
        bool valid{};
        dmr_call::CallConfig call{};
        TimePoint expires_at{};
    };

    struct RxBurst {
        dmr_call::AmbeVoiceBurst voice{};
        std::uint8_t missing_before{};
    };

    struct QueuedPlaybackFrame {
        Pcm48Frame pcm{};
        std::size_t sample_count{};
    };

    [[nodiscard]] bool tx_output_available(std::size_t required) const noexcept;
    [[nodiscard]] bool enqueue_tx_packet(const dmr_call::TxPacket& packet) noexcept;
    [[nodiscard]] bool enqueue_codeword(const dmr_vocoder::Codeword& codeword) noexcept;
    [[nodiscard]] bool append_downsampled(const std::int16_t* samples,
                                          std::size_t count,
                                          std::size_t& encoded_frames);
    void try_finalize_tx();
    [[nodiscard]] Error tick_tx(TimePoint now);
    [[nodiscard]] Error tick_rx(TimePoint now);
    [[nodiscard]] bool queue_event(const Event& event) noexcept;
    [[nodiscard]] bool filter_accepts(const dmr_call::CallConfig& call) const noexcept;
    [[nodiscard]] static bool filter_matches(const ReceiveFilter& filter,
                                             const dmr_call::CallConfig& call) noexcept;
    [[nodiscard]] bool filter_accepts_datagram(const dmrd::Datagram& datagram) const noexcept;
    [[nodiscard]] ReceiveResult ingest_routed_rx(const dmrd::Datagram& datagram,
                                                 TimePoint now) noexcept;
    void clear_routed_rx_staging() noexcept;
    void retire_routed_stream(const dmr_call::CallConfig& call, TimePoint now) noexcept;
    [[nodiscard]] bool routed_stream_retired(const dmr_call::CallConfig& call,
                                             TimePoint now) noexcept;
    [[nodiscard]] Error stop_routed_rx(bool router_already_stopping) noexcept;
    [[nodiscard]] Error begin_tx_media(const dmr_call::CallConfig& call,
                                       Readiness readiness,
                                       TimePoint now) noexcept;
    [[nodiscard]] static dmr_call::CallConfig call_from_datagram(
        const dmrd::Datagram& datagram) noexcept;
    [[nodiscard]] bool accept_time(TimePoint now) noexcept;
    [[nodiscard]] bool advance_rx_generation() noexcept;
    [[nodiscard]] std::size_t buffered_rx_frames() const noexcept;
    [[nodiscard]] Error process_receive_result(const dmr_call::ReceiveResult& result,
                                              TimePoint now);
    void clear_rx_media() noexcept;
    [[nodiscard]] Error timeout_rx_start() noexcept;
    void finish_rx_if_drained() noexcept;

    dmr_call::Transmitter transmitter_{};
    dmr_call::Receiver receiver_{};
    dmr_call::Receiver routed_staging_receiver_{};
    dmr_vocoder::Encoder encoder_{};
    dmr_vocoder::Decoder decoder_{};
    audio::PcmResampler48To8 downsampler_{};
    audio::PcmResampler8To48 upsampler_{};
    ReceiveFilter receive_filter_{};
    ReceiveFilter secondary_receive_filter_{};
    bool secondary_receive_filter_enabled_{};
    std::unique_ptr<talkgroup_routing::Router> router_;
    std::optional<RxGenerationMapping> active_rx_mapping_;
    std::optional<RxGenerationMapping> stopping_rx_mapping_;
    std::array<StagedRxDatagram, max_routed_rx_staging_datagrams> routed_rx_staging_{};
    std::array<RetiredRoutedStream, 8U> retired_routed_streams_{};
    std::size_t retired_routed_stream_cursor_{};
    std::size_t routed_rx_staging_count_{};
    std::optional<dmr_call::CallConfig> routed_staging_call_;
    TimePoint routed_staging_started_at_{};
    bool routed_staging_has_call_start_{};
    bool routed_rx_cleanup_pending_{};
    std::optional<std::uint64_t> routed_tx_lease_id_;
    bool routed_tx_stop_queued_{};
    TxState tx_state_{TxState::idle};
    RxState rx_state_{RxState::idle};
    dmr_call::CallConfig rx_call_{};

    std::array<dmr_vocoder::Codeword, max_tx_queued_codewords> tx_codewords_{};
    std::size_t tx_codeword_read_{};
    std::size_t tx_codeword_count_{};
    dmr_vocoder::PcmFrame tx_pcm_frame_{};
    std::size_t tx_pcm_fill_{};
    dmr_vocoder::PcmFrame tx_pending_frame_{};
    bool tx_has_pending_frame_{};
    bool tx_finalize_requested_{};
    bool tx_finalized_{};
    bool tx_clock_started_{};
    std::array<dmr_call::TxPacket, 8U> outbound_{};
    std::size_t outbound_read_{};
    std::size_t outbound_count_{};
    TimePoint next_tx_due_{};

    std::array<RxBurst, max_rx_queued_bursts> rx_bursts_{};
    std::size_t rx_burst_read_{};
    std::size_t rx_burst_count_{};
    std::unique_ptr<QueuedPlaybackFrame[]> playback_frames_;
    std::size_t playback_read_{};
    std::size_t playback_count_{};
    std::size_t playback_inflight_{};
    std::array<Event, max_pipeline_events> events_{};
    std::size_t event_read_{};
    std::size_t event_count_{};
    std::uint8_t trailing_missing_bursts_{};
    bool rx_playback_ready_{};
    bool rx_network_ended_{};
    bool rx_have_link_control_{};
    bool rx_color_code_known_{};
    bool rx_upsampler_finished_{};
    std::uint64_t rx_accepted_voice_bursts_{};
    TimePoint next_rx_due_{};
    TimePoint rx_start_deadline_{};
    TimePoint last_now_{};
    bool has_last_now_{};
    std::uint64_t rx_generation_{};
    bool rx_generation_exhausted_{};
};

} // namespace wirex::bm_voice
