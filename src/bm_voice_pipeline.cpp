#include "wirex/bm_voice_pipeline.hpp"

#include <algorithm>
#include <array>
#include <limits>

namespace wirex::bm_voice {
namespace {

constexpr std::size_t codewords_per_burst = dmr_call::codewords_per_burst;
constexpr std::size_t tx_burst_codeword_count = codewords_per_burst;
constexpr auto voice_period = dmr_call::voice_burst_period;
constexpr std::size_t max_downsampled_samples_per_push =
    (max_tx_audio_samples_per_push + audio::resample_ratio_48k_8k - 1U) /
    audio::resample_ratio_48k_8k;

[[nodiscard]] std::uint8_t cap_missing(std::uint32_t missing) noexcept
{
    return static_cast<std::uint8_t>(std::min<std::uint32_t>(missing,
                                                            max_missing_bursts_to_compensate));
}

} // namespace

BmVoicePipeline::BmVoicePipeline()
    : playback_frames_(std::make_unique<QueuedPlaybackFrame[]>(max_rx_queued_pcm_frames))
{
}

BmVoicePipeline::~BmVoicePipeline() = default;

Error BmVoicePipeline::set_receive_filter(const ReceiveFilter& filter) noexcept
{
    if (router_) return Error::busy;
    if (tx_state_ != TxState::idle || rx_state_ != RxState::idle) {
        return Error::busy;
    }
    if (filter.destination_id > dmrd::max_id24 ||
        (filter.match_source_id && (filter.source_id == 0U || filter.source_id > dmrd::max_id24)) ||
        (filter.match_slot && filter.slot != dmr_call::Slot::ts1 && filter.slot != dmr_call::Slot::ts2) ||
        (filter.match_call_kind && filter.call_kind != dmr_call::CallKind::group &&
         filter.call_kind != dmr_call::CallKind::private_call)) {
        return Error::invalid_call;
    }
    receive_filter_ = filter;
    secondary_receive_filter_ = {};
    secondary_receive_filter_enabled_ = false;
    return Error::none;
}

Error BmVoicePipeline::set_secondary_receive_filter(
    const std::optional<ReceiveFilter>& filter) noexcept
{
    if (router_) return Error::busy;
    if (tx_state_ != TxState::idle || rx_state_ != RxState::idle) return Error::busy;
    if (!filter) {
        secondary_receive_filter_ = {};
        secondary_receive_filter_enabled_ = false;
        return Error::none;
    }
    if (filter->destination_id > dmrd::max_id24 ||
        (filter->match_source_id && (filter->source_id == 0U || filter->source_id > dmrd::max_id24)) ||
        (filter->match_slot && filter->slot != dmr_call::Slot::ts1 && filter->slot != dmr_call::Slot::ts2) ||
        (filter->match_call_kind && filter->call_kind != dmr_call::CallKind::group &&
         filter->call_kind != dmr_call::CallKind::private_call)) {
        return Error::invalid_call;
    }
    secondary_receive_filter_ = *filter;
    secondary_receive_filter_enabled_ = true;
    return Error::none;
}

Error BmVoicePipeline::enable_routing(
    std::uint32_t local_source_id,
    const talkgroup_routing::RxPolicy& rx_policy,
    const talkgroup_routing::TxPolicy& tx_policy) noexcept
{
    if (router_ || tx_state_ != TxState::idle || rx_state_ != RxState::idle ||
        outbound_count_ != 0U || active_rx_mapping_ || stopping_rx_mapping_) {
        return Error::busy;
    }
    std::unique_ptr<talkgroup_routing::Router> candidate;
    try {
        candidate = std::make_unique<talkgroup_routing::Router>(local_source_id);
    } catch (...) {
        return Error::resource_failure;
    }
    if (!candidate->valid()) return Error::invalid_call;

    const auto rx_update = candidate->replace_rx_policy(1U, rx_policy);
    if (!rx_update) {
        return rx_update.status == talkgroup_routing::PolicyUpdateStatus::resource_failure
            ? Error::resource_failure
            : Error::invalid_call;
    }
    const auto tx_update = candidate->replace_tx_policy(1U, tx_policy);
    if (!tx_update) {
        return tx_update.status == talkgroup_routing::PolicyUpdateStatus::resource_failure
            ? Error::resource_failure
            : Error::invalid_call;
    }
    receive_filter_ = {};
    secondary_receive_filter_ = {};
    secondary_receive_filter_enabled_ = false;
    router_ = std::move(candidate);
    return Error::none;
}

talkgroup_routing::PolicyUpdateResult BmVoicePipeline::replace_rx_policy(
    std::uint64_t expected_revision,
    const talkgroup_routing::RxPolicy& policy) noexcept
{
    if (!router_) {
        return {talkgroup_routing::PolicyUpdateStatus::invalid_policy, 0U, std::nullopt};
    }
    auto result = router_->replace_rx_policy(expected_revision, policy);
    if (result && result.cancelled_rx_generation) {
        (void)stop_routed_rx(true);
    }
    return result;
}

talkgroup_routing::PolicyUpdateResult BmVoicePipeline::replace_tx_policy(
    std::uint64_t expected_revision,
    const talkgroup_routing::TxPolicy& policy) noexcept
{
    if (!router_) {
        return {talkgroup_routing::PolicyUpdateStatus::invalid_policy,
                0U, std::nullopt, std::nullopt};
    }
    auto result = router_->replace_tx_policy(expected_revision, policy);
    if (result && result.stop_tx_lease_id && tx_state_ != TxState::idle && has_last_now_) {
        (void)stop_tx(last_now_);
    }
    return result;
}

RoutedSnapshot BmVoicePipeline::routing_snapshot() const noexcept
{
    RoutedSnapshot result{};
    if (router_) result.router = router_->snapshot();
    result.active_rx_mapping = active_rx_mapping_;
    result.stopping_rx_mapping = stopping_rx_mapping_;
    return result;
}

std::uint32_t BmVoicePipeline::routed_local_source_id() const noexcept
{
    return router_ ? router_->local_source_id() : 0U;
}

const talkgroup_routing::RxPolicy* BmVoicePipeline::routed_rx_policy() const noexcept
{
    return router_ ? &router_->rx_policy() : nullptr;
}

const talkgroup_routing::TxPolicy* BmVoicePipeline::routed_tx_policy() const noexcept
{
    return router_ ? &router_->tx_policy() : nullptr;
}

bool BmVoicePipeline::routed_tx_voice_permitted() const noexcept
{
    if (!router_ || !router_->tx_policy().transmit_enabled) return false;
    const auto state = router_->snapshot();
    return state.active_tx_lease.has_value() && !state.active_tx_lease->admission_revoked;
}

Error BmVoicePipeline::begin_routed_tx(const dmr_call::CallConfig& identity_template,
                                      Readiness readiness,
                                      TimePoint now) noexcept
{
    if (!router_) return Error::busy;
    if (!accept_time(now)) return Error::clock_reversed;
    if (tx_state_ != TxState::idle || rx_state_ != RxState::idle || outbound_count_ != 0U) {
        return Error::busy;
    }
    if (!readiness.bm_ready) return Error::bm_not_ready;
    if (!readiness.hri_ready) return Error::hri_not_ready;
    if (identity_template.source_id != router_->local_source_id()) return Error::invalid_call;
    if (identity_template.color_code > 15U) return Error::invalid_call;

    const auto started = router_->begin_ptt();
    if (!started) {
        return started.status == talkgroup_routing::TxStartStatus::invalid_target
            ? Error::invalid_call
            : Error::busy;
    }
    auto call = identity_template;
    call.destination_id = started.lease->target.destination_id;
    call.kind = started.lease->target.kind;
    call.slot = started.lease->target.slot;
    const auto error = begin_tx_media(call, readiness, now);
    if (error != Error::none) {
        (void)router_->request_tx_stop(started.lease->id);
        (void)router_->complete_tx_eot(started.lease->id, false);
        (void)router_->complete_tx_cleanup(started.lease->id, true);
        return error;
    }
    routed_tx_lease_id_ = started.lease->id;
    routed_tx_stop_queued_ = false;
    return Error::none;
}

talkgroup_routing::OperationStatus BmVoicePipeline::observe_routed_ptt_release() noexcept
{
    if (!router_) return talkgroup_routing::OperationStatus::not_active;
    return router_->observe_ptt_release();
}

talkgroup_routing::OperationStatus BmVoicePipeline::complete_routed_rx_cleanup(
    std::uint64_t pipeline_generation,
    bool cleanup_succeeded) noexcept
{
    if (!router_ || !stopping_rx_mapping_ ||
        stopping_rx_mapping_->pipeline_generation != pipeline_generation) {
        return talkgroup_routing::OperationStatus::stale_generation;
    }
    const auto mapping = *stopping_rx_mapping_;
    const auto status = router_->complete_rx_stop(mapping.router_generation, cleanup_succeeded);
    if (status != talkgroup_routing::OperationStatus::completed) return status;

    stopping_rx_mapping_.reset();
    active_rx_mapping_.reset();
    routed_rx_cleanup_pending_ = false;
    receiver_.reset();
    routed_staging_receiver_.reset();
    clear_routed_rx_staging();
    upsampler_.reset();
    clear_rx_media();
    rx_state_ = RxState::idle;
    rx_call_ = {};
    rx_playback_ready_ = false;
    rx_network_ended_ = false;
    rx_start_deadline_ = {};
    rx_have_link_control_ = false;
    rx_color_code_known_ = false;
    rx_upsampler_finished_ = false;
    if (!advance_rx_generation()) return talkgroup_routing::OperationStatus::generation_exhausted;
    return status;
}

talkgroup_routing::OperationStatus BmVoicePipeline::complete_routed_tx_eot(
    std::uint64_t lease_id,
    bool sent) noexcept
{
    if (!router_) return talkgroup_routing::OperationStatus::stale_lease;
    return router_->complete_tx_eot(lease_id, sent);
}

talkgroup_routing::OperationStatus BmVoicePipeline::complete_routed_tx_cleanup(
    std::uint64_t lease_id,
    bool cleanup_succeeded) noexcept
{
    if (!router_) return talkgroup_routing::OperationStatus::stale_lease;
    const auto status = router_->complete_tx_cleanup(lease_id, cleanup_succeeded);
    if (status == talkgroup_routing::OperationStatus::completed &&
        routed_tx_lease_id_ == lease_id) {
        routed_tx_lease_id_.reset();
        routed_tx_stop_queued_ = false;
    }
    return status;
}

Error BmVoicePipeline::begin_tx(const dmr_call::CallConfig& call,
                                Readiness readiness,
                                TimePoint now) noexcept
{
    if (router_) return Error::busy;
    return begin_tx_media(call, readiness, now);
}

Error BmVoicePipeline::begin_tx_media(const dmr_call::CallConfig& call,
                                      Readiness readiness,
                                      TimePoint now) noexcept
{
    if (!accept_time(now)) {
        return Error::clock_reversed;
    }
    if (tx_state_ != TxState::idle || rx_state_ != RxState::idle || outbound_count_ != 0U) {
        return Error::busy;
    }
    if (!readiness.bm_ready) {
        return Error::bm_not_ready;
    }
    if (!readiness.hri_ready) {
        return Error::hri_not_ready;
    }

    try {
        encoder_.reset();
    } catch (...) {
        cancel_tx();
        return Error::codec_failure;
    }
    downsampler_.reset();
    tx_codeword_read_ = 0U;
    tx_codeword_count_ = 0U;
    tx_pcm_frame_.fill(0);
    tx_pcm_fill_ = 0U;
    tx_pending_frame_.fill(0);
    tx_has_pending_frame_ = false;
    tx_finalize_requested_ = false;
    tx_finalized_ = false;
    tx_clock_started_ = false;

    const auto started = transmitter_.start(call);
    if (!started) {
        transmitter_.reset();
        return Error::invalid_call;
    }
    if (!enqueue_tx_packet(started.packet)) {
        transmitter_.reset();
        return Error::tx_queue_full;
    }
    tx_state_ = TxState::active;
    next_tx_due_ = {};
    return Error::none;
}

TxPushResult BmVoicePipeline::push_tx_audio(const std::int16_t* samples,
                                           std::size_t sample_count,
                                           TimePoint now) noexcept
{
    TxPushResult result{};
    if (!accept_time(now)) {
        result.error = Error::clock_reversed;
        return result;
    }
    if (tx_state_ != TxState::active) {
        result.error = Error::not_active;
        return result;
    }
    if (router_ && !routed_tx_voice_permitted()) {
        result.error = Error::not_active;
        return result;
    }
    if (sample_count > max_tx_audio_samples_per_push ||
        (sample_count != 0U && samples == nullptr)) {
        result.error = sample_count > max_tx_audio_samples_per_push
            ? Error::tx_input_too_large
            : Error::invalid_call;
        return result;
    }
    if (sample_count == 0U) {
        return result;
    }

    const std::size_t max_8k_samples =
        (sample_count + audio::resample_ratio_48k_8k - 1U) /
        audio::resample_ratio_48k_8k;
    const std::size_t max_frames = (tx_pcm_fill_ + max_8k_samples) /
                                   dmr_vocoder::pcm_samples_per_frame;
    if (max_frames > max_tx_queued_codewords - tx_codeword_count_) {
        result.error = Error::tx_queue_full;
        return result;
    }

    std::array<std::int16_t, max_downsampled_samples_per_push> output{};
    const auto converted = downsampler_.process(samples, sample_count,
                                                output.data(), output.size());
    if (converted.invalid_buffer || converted.input_consumed != sample_count) {
        result.error = Error::tx_queue_full;
        return result;
    }
    try {
        if (!append_downsampled(output.data(), converted.output_written, result.encoded_frames)) {
            result.error = Error::tx_queue_full;
        } else if (!tx_clock_started_ && tx_codeword_count_ >= tx_start_prebuffer_codewords) {
            // 等有两组三码字 burst 可发后再起钟，避免 100 ms 采集分块导致首包欠载。
            next_tx_due_ = now + voice_period;
            tx_clock_started_ = true;
        }
    } catch (...) {
        cancel_tx();
        result.error = Error::codec_failure;
    }
    return result;
}

Error BmVoicePipeline::end_tx(TimePoint now) noexcept
{
    if (!accept_time(now)) {
        return Error::clock_reversed;
    }
    if (router_ && routed_tx_lease_id_) {
        (void)router_->release_tx(*routed_tx_lease_id_);
    }
    if (tx_state_ != TxState::active) {
        return Error::not_active;
    }

    try {
        std::array<std::int16_t, audio::downsample_flush_input_samples> tail{};
        const auto flushed = downsampler_.finish(tail.data(), tail.size());
        if (flushed.invalid_buffer) {
            return Error::tx_queue_full;
        }
        std::size_t ignored_encoded_frames = 0U;
        if (!append_downsampled(tail.data(), flushed.output_written, ignored_encoded_frames)) {
            return Error::tx_queue_full;
        }
        tx_finalize_requested_ = true;
        tx_state_ = TxState::draining;
        try_finalize_tx();
        if (!tx_clock_started_ && tx_codeword_count_ >= codewords_per_burst) {
            next_tx_due_ = now + voice_period;
            tx_clock_started_ = true;
        }
    } catch (...) {
        cancel_tx();
        return Error::codec_failure;
    }
    return Error::none;
}

Error BmVoicePipeline::stop_tx(TimePoint now) noexcept
{
    if (!accept_time(now)) {
        return Error::clock_reversed;
    }
    if (router_ && routed_tx_lease_id_) {
        (void)router_->request_tx_stop(*routed_tx_lease_id_);
        routed_tx_stop_queued_ = true;
    }
    if (tx_state_ == TxState::idle) {
        return Error::not_active;
    }

    std::optional<dmr_call::TxPacket> pending_header;
    for (std::size_t index = 0U; index < outbound_count_; ++index) {
        const std::size_t queued_index = (outbound_read_ + index) % outbound_.size();
        if (outbound_[queued_index].kind == dmr_call::PacketKind::voice_lc_header) {
            pending_header = outbound_[queued_index];
            break;
        }
    }
    outbound_read_ = 0U;
    outbound_count_ = 0U;
    if (pending_header && !enqueue_tx_packet(*pending_header)) {
        cancel_tx();
        return Error::tx_queue_full;
    }

    const auto terminator = transmitter_.finish();
    if (!terminator || !enqueue_tx_packet(terminator.packet)) {
        cancel_tx();
        return Error::not_active;
    }

    tx_codeword_read_ = 0U;
    tx_codeword_count_ = 0U;
    tx_pcm_frame_.fill(0);
    tx_pcm_fill_ = 0U;
    tx_pending_frame_.fill(0);
    tx_has_pending_frame_ = false;
    tx_finalize_requested_ = false;
    tx_finalized_ = false;
    downsampler_.reset();
    tx_state_ = TxState::idle;
    next_tx_due_ = {};
    tx_clock_started_ = false;
    return Error::none;
}

void BmVoicePipeline::cancel_tx() noexcept
{
    if (router_ && routed_tx_lease_id_) {
        (void)router_->request_tx_stop(*routed_tx_lease_id_);
        routed_tx_stop_queued_ = false;
    }
    transmitter_.reset();
    downsampler_.reset();
    tx_codeword_read_ = 0U;
    tx_codeword_count_ = 0U;
    tx_pcm_frame_.fill(0);
    tx_pcm_fill_ = 0U;
    tx_pending_frame_.fill(0);
    tx_has_pending_frame_ = false;
    tx_finalize_requested_ = false;
    tx_finalized_ = false;
    outbound_read_ = 0U;
    outbound_count_ = 0U;
    tx_state_ = TxState::idle;
    next_tx_due_ = {};
    tx_clock_started_ = false;
}

std::optional<dmr_call::TxPacket> BmVoicePipeline::take_outbound() noexcept
{
    if (outbound_count_ == 0U) {
        return std::nullopt;
    }
    const auto packet = outbound_[outbound_read_];
    outbound_read_ = (outbound_read_ + 1U) % outbound_.size();
    --outbound_count_;
    return packet;
}

ReceiveResult BmVoicePipeline::ingest_rx(const dmrd::Datagram& datagram,
                                         TimePoint now) noexcept
{
    ReceiveResult result{};
    if (!accept_time(now)) {
        result.error = Error::clock_reversed;
        return result;
    }
    if (rx_generation_exhausted_) {
        result.error = Error::generation_exhausted;
        return result;
    }
    if (router_) return ingest_routed_rx(datagram, now);
    if (rx_state_ != RxState::idle && rx_state_ != RxState::filtered &&
        !rx_playback_ready_ && now >= rx_start_deadline_) {
        result.error = timeout_rx_start();
        return result;
    }
    if (!filter_accepts_datagram(datagram)) {
        result.error = Error::filtered;
        return result;
    }
    try {
        result.protocol = receiver_.ingest(datagram, now);
        result.error = process_receive_result(result.protocol, now);
    } catch (...) {
        cancel_rx();
        result.error = Error::codec_failure;
        return result;
    }
    if (result.error == Error::none && rx_state_ == RxState::filtered) {
        result.error = Error::filtered;
    }
    return result;
}

ReceiveResult BmVoicePipeline::ingest_routed_rx(const dmrd::Datagram& datagram,
                                                TimePoint now) noexcept
{
    ReceiveResult result{};
    if (!router_) {
        result.error = Error::busy;
        return result;
    }

    const auto candidate = call_from_datagram(datagram);
    if (routed_stream_retired(candidate, now)) {
        result.error = Error::filtered;
        return result;
    }
    if (routed_rx_cleanup_pending_ || stopping_rx_mapping_) {
        result.error = Error::busy;
        return result;
    }
    const auto route_state = router_->snapshot();
    if (active_rx_mapping_) {
        if (!rx_playback_ready_ && now >= rx_start_deadline_) {
            result.error = timeout_rx_start();
            return result;
        }
        const auto admission = router_->admit_rx(candidate, false);
        if (admission.decision != talkgroup_routing::RxDecision::same_active_call) {
            result.error = admission.decision == talkgroup_routing::RxDecision::media_busy ||
                           admission.decision == talkgroup_routing::RxDecision::stopping
                ? Error::busy
                : Error::filtered;
            return result;
        }
        try {
            result.protocol = receiver_.ingest(datagram, now);
            result.error = process_receive_result(result.protocol, now);
        } catch (...) {
            cancel_rx();
            result.error = Error::codec_failure;
        }
        return result;
    }

    if (route_state.media_owner != talkgroup_routing::MediaOwner::idle ||
        tx_state_ != TxState::idle || rx_state_ != RxState::idle) {
        result.error = Error::busy;
        return result;
    }

    constexpr std::uint8_t flag_data_sync = 0x20U;
    constexpr std::uint8_t flag_voice_sync = 0x10U;
    constexpr std::uint8_t data_type_mask = 0x0fU;
    const auto low_flags = static_cast<std::uint8_t>(datagram.flags & data_type_mask);
    const bool starts_from_header = (datagram.flags & flag_data_sync) != 0U && low_flags == 0x01U;
    const bool starts_from_voice_sync = (datagram.flags & flag_voice_sync) != 0U && low_flags == 0U;
    if (routed_rx_staging_count_ != 0U &&
        now - routed_staging_started_at_ >= dmr_call::default_receive_timeout) {
        clear_routed_rx_staging();
        routed_staging_receiver_.reset();
    }
    if (routed_rx_staging_count_ == 0U) {
        if (!starts_from_header && !starts_from_voice_sync) {
            result.error = Error::filtered;
            return result;
        }
        if (routed_stream_retired(candidate, now)) {
            result.error = Error::filtered;
            return result;
        }
        routed_staging_call_ = candidate;
        routed_staging_started_at_ = now;
        routed_staging_has_call_start_ = true;
    } else {
        const auto& first = routed_rx_staging_[0U].datagram;
        const auto staged_call = call_from_datagram(first);
        const bool same_stream = staged_call.source_id == candidate.source_id &&
                                 staged_call.destination_id == candidate.destination_id &&
                                 staged_call.gateway_id == candidate.gateway_id &&
                                 staged_call.stream_id == candidate.stream_id &&
                                 staged_call.slot == candidate.slot &&
                                 staged_call.kind == candidate.kind;
        if (!same_stream) {
            if (starts_from_header && !routed_stream_retired(candidate, now)) {
                clear_routed_rx_staging();
                routed_staging_receiver_.reset();
                routed_staging_call_ = candidate;
                routed_staging_started_at_ = now;
                routed_staging_has_call_start_ = true;
            } else {
                result.error = Error::filtered;
                return result;
            }
        }
    }

    if (routed_rx_staging_count_ == routed_rx_staging_.size()) {
        clear_routed_rx_staging();
        routed_staging_receiver_.reset();
        result.error = Error::filtered;
        return result;
    }
    routed_rx_staging_[routed_rx_staging_count_++] = StagedRxDatagram{datagram, now};
    const auto staged = routed_staging_receiver_.ingest(datagram, now);
    result.protocol = staged;
    if (staged.status == dmr_call::ReceiveStatus::malformed) {
        clear_routed_rx_staging();
        routed_staging_receiver_.reset();
        result.error = Error::invalid_call;
        return result;
    }

    std::optional<dmr_call::CallConfig> validated_call;
    for (std::size_t index = 0U; index < staged.event_count; ++index) {
        const auto& event = staged.events[index];
        if ((event.kind == dmr_call::ReceiveEventKind::call_started ||
             event.kind == dmr_call::ReceiveEventKind::link_control_confirmed) &&
            event.link_control_validated) {
            validated_call = event.call;
        }
    }
    if (!validated_call) {
        result.error = Error::filtered;
        return result;
    }
    const bool validated_staged_stream = routed_staging_call_ &&
        routed_staging_call_->source_id == validated_call->source_id &&
        routed_staging_call_->destination_id == validated_call->destination_id &&
        routed_staging_call_->gateway_id == validated_call->gateway_id &&
        routed_staging_call_->stream_id == validated_call->stream_id &&
        routed_staging_call_->slot == validated_call->slot &&
        routed_staging_call_->kind == validated_call->kind;
    if (!routed_staging_has_call_start_ || !validated_staged_stream ||
        routed_stream_retired(*validated_call, now)) {
        clear_routed_rx_staging();
        routed_staging_receiver_.reset();
        result.error = Error::filtered;
        return result;
    }

    const auto admission = router_->admit_rx(*validated_call, true);
    if (!admission.admitted()) {
        clear_routed_rx_staging();
        routed_staging_receiver_.reset();
        result.error = admission.decision == talkgroup_routing::RxDecision::media_busy ||
                       admission.decision == talkgroup_routing::RxDecision::stopping
            ? Error::busy
            : Error::filtered;
        return result;
    }

    result.error = Error::none;
    try {
        for (std::size_t index = 0U; index < routed_rx_staging_count_; ++index) {
            const auto& pending = routed_rx_staging_[index];
            result.protocol = receiver_.ingest(pending.datagram, pending.time);
            const auto process_error = process_receive_result(result.protocol, pending.time);
            if (process_error != Error::none) {
                result.error = process_error;
                break;
            }
        }
    } catch (...) {
        cancel_rx();
        result.error = Error::codec_failure;
    }
    clear_routed_rx_staging();
    routed_staging_receiver_.reset();
    return result;
}

void BmVoicePipeline::clear_routed_rx_staging() noexcept
{
    for (auto& pending : routed_rx_staging_) pending = {};
    routed_rx_staging_count_ = 0U;
    routed_staging_call_.reset();
    routed_staging_started_at_ = {};
    routed_staging_has_call_start_ = false;
}

void BmVoicePipeline::retire_routed_stream(const dmr_call::CallConfig& call,
                                           TimePoint now) noexcept
{
    if (call.source_id == 0U || call.destination_id == 0U) return;
    retired_routed_streams_[retired_routed_stream_cursor_ % retired_routed_streams_.size()] =
        RetiredRoutedStream{true, call, now + dmr_call::default_retired_stream_lifetime};
    retired_routed_stream_cursor_ = (retired_routed_stream_cursor_ + 1U) % retired_routed_streams_.size();
}

bool BmVoicePipeline::routed_stream_retired(const dmr_call::CallConfig& call,
                                            TimePoint now) noexcept
{
    for (auto& retired : retired_routed_streams_) {
        if (!retired.valid) continue;
        if (now >= retired.expires_at) {
            retired.valid = false;
            continue;
        }
        if (retired.call.source_id == call.source_id &&
            retired.call.destination_id == call.destination_id &&
            retired.call.stream_id == call.stream_id && retired.call.slot == call.slot) {
            retired.expires_at = now + dmr_call::default_retired_stream_lifetime;
            return true;
        }
    }
    return false;
}

Error BmVoicePipeline::stop_routed_rx(bool router_already_stopping) noexcept
{
    if (!router_) return Error::busy;
    if (stopping_rx_mapping_) return Error::none;

    std::optional<std::uint64_t> router_generation;
    if (router_already_stopping) {
        const auto state = router_->snapshot();
        if (state.media_owner == talkgroup_routing::MediaOwner::rx_stopping ||
            (state.media_owner == talkgroup_routing::MediaOwner::fault && state.active_rx_generation != 0U)) {
            router_generation = state.active_rx_generation;
        }
    } else {
        router_generation = router_->request_rx_stop();
    }
    if (!router_generation) return Error::not_active;

    RxGenerationMapping mapping{};
    if (active_rx_mapping_ && active_rx_mapping_->router_generation == *router_generation) {
        mapping = *active_rx_mapping_;
    } else {
        mapping = RxGenerationMapping{*router_generation, rx_generation_};
    }
    active_rx_mapping_.reset();
    stopping_rx_mapping_ = mapping;
    routed_rx_cleanup_pending_ = true;
    if (rx_state_ != RxState::idle && rx_state_ != RxState::stopping) {
        Event cancelled{};
        cancelled.kind = EventKind::receive_cancelled;
        cancelled.call = rx_call_;
        cancelled.generation = mapping.pipeline_generation;
        (void)queue_event(cancelled);
    }
    retire_routed_stream(rx_call_, has_last_now_ ? last_now_ : TimePoint{});
    receiver_.reset();
    routed_staging_receiver_.reset();
    clear_routed_rx_staging();
    upsampler_.reset();
    clear_rx_media();
    rx_state_ = RxState::stopping;
    rx_playback_ready_ = false;
    rx_network_ended_ = true;
    rx_start_deadline_ = {};
    rx_upsampler_finished_ = true;
    return Error::none;
}

Error BmVoicePipeline::playback_ready(TimePoint now) noexcept
{
    if (!accept_time(now)) {
        return Error::clock_reversed;
    }
    if (routed_rx_cleanup_pending_ || rx_state_ == RxState::stopping) {
        return Error::playback_not_waiting;
    }
    if (rx_state_ == RxState::filtered) {
        return Error::filtered;
    }
    if (rx_state_ != RxState::idle && !rx_playback_ready_ && now >= rx_start_deadline_) {
        return timeout_rx_start();
    }
    if (rx_playback_ready_ ||
        (rx_state_ != RxState::waiting_for_playback && rx_state_ != RxState::draining)) {
        return Error::playback_not_waiting;
    }
    rx_playback_ready_ = true;
    if (!rx_network_ended_) {
        rx_state_ = RxState::buffering;
    }
    next_rx_due_ = now;
    return Error::none;
}

void BmVoicePipeline::cancel_rx() noexcept
{
    if (router_) {
        const auto owner = router_->snapshot();
        const bool router_has_rx_owner = owner.active_rx_generation != 0U &&
            (owner.media_owner == talkgroup_routing::MediaOwner::rx_active ||
             owner.media_owner == talkgroup_routing::MediaOwner::rx_draining ||
             owner.media_owner == talkgroup_routing::MediaOwner::rx_stopping ||
             owner.media_owner == talkgroup_routing::MediaOwner::fault);
        if (active_rx_mapping_ || stopping_rx_mapping_ || router_has_rx_owner) {
            (void)stop_routed_rx(false);
        } else {
            receiver_.reset();
            clear_routed_rx_staging();
            routed_staging_receiver_.reset();
            clear_rx_media();
            rx_state_ = RxState::idle;
            rx_call_ = {};
            rx_playback_ready_ = false;
            rx_network_ended_ = false;
            rx_start_deadline_ = {};
            rx_have_link_control_ = false;
            rx_color_code_known_ = false;
            rx_upsampler_finished_ = false;
        }
        return;
    }
    if (rx_state_ != RxState::idle) {
        Event event{};
        event.kind = EventKind::receive_cancelled;
        event.call = rx_call_;
        event.generation = rx_generation_;
        (void)queue_event(event);
    }
    receiver_.reset();
    upsampler_.reset();
    clear_rx_media();
    rx_state_ = RxState::idle;
    rx_call_ = {};
    rx_playback_ready_ = false;
    rx_network_ended_ = false;
    rx_start_deadline_ = {};
    rx_have_link_control_ = false;
    rx_color_code_known_ = false;
    (void)advance_rx_generation();
}

bool BmVoicePipeline::take_playback_pcm(PlaybackFrame& frame) noexcept
{
    if (routed_rx_cleanup_pending_ || !rx_playback_ready_ || playback_count_ == 0U ||
        playback_inflight_ == max_unconfirmed_playback_frames) {
        return false;
    }
    frame.pcm = playback_frames_[playback_read_].pcm;
    frame.sample_count = playback_frames_[playback_read_].sample_count;
    frame.generation = rx_generation_;
    playback_read_ = (playback_read_ + 1U) % max_rx_queued_pcm_frames;
    --playback_count_;
    ++playback_inflight_;
    finish_rx_if_drained();
    return true;
}

Error BmVoicePipeline::acknowledge_playback(std::uint64_t generation,
                                            std::size_t completed_frames,
                                            TimePoint now) noexcept
{
    if (!accept_time(now)) {
        return Error::clock_reversed;
    }
    if (generation != rx_generation_) {
        return Error::stale_playback_ack;
    }
    if (routed_rx_cleanup_pending_) return Error::stale_playback_ack;
    if (completed_frames == 0U || completed_frames > playback_inflight_) {
        return Error::invalid_playback_ack;
    }
    playback_inflight_ -= completed_frames;
    finish_rx_if_drained();
    return Error::none;
}

std::optional<Event> BmVoicePipeline::take_event() noexcept
{
    if (event_count_ == 0U) {
        return std::nullopt;
    }
    const auto event = events_[event_read_];
    event_read_ = (event_read_ + 1U) % events_.size();
    --event_count_;
    return event;
}

Error BmVoicePipeline::tick(TimePoint now) noexcept
{
    if (!accept_time(now)) {
        return Error::clock_reversed;
    }
    try {
        Error first_error = process_receive_result(receiver_.poll(now), now);
        const Error tx_error = tick_tx(now);
        if (first_error == Error::none) {
            first_error = tx_error;
        }
        const Error rx_error = tick_rx(now);
        if (first_error == Error::none) {
            first_error = rx_error;
        }
        return first_error;
    } catch (...) {
        cancel_tx();
        cancel_rx();
        return Error::codec_failure;
    }
}

void BmVoicePipeline::reset() noexcept
{
    cancel_tx();
    cancel_rx();
    event_read_ = 0U;
    event_count_ = 0U;
    if (router_) {
        return;
    }
    receive_filter_ = {};
    secondary_receive_filter_ = {};
    secondary_receive_filter_enabled_ = false;
    last_now_ = {};
    has_last_now_ = false;
}

Snapshot BmVoicePipeline::snapshot() const noexcept
{
    Snapshot result{};
    result.tx_state = tx_state_;
    result.rx_state = rx_state_;
    result.receive_call = rx_call_;
    result.queued_tx_codewords = tx_codeword_count_;
    result.queued_rx_bursts = rx_burst_count_;
    result.queued_playback_frames = playback_count_;
    result.unconfirmed_playback_frames = playback_inflight_;
    result.buffered_receive_frames = buffered_rx_frames();
    result.receive_generation = rx_generation_;
    result.receive_generation_exhausted = rx_generation_exhausted_;
    result.receive_link_control_validated = rx_have_link_control_;
    result.receive_color_code_known = rx_color_code_known_;
    result.receive_network_ended = rx_network_ended_;
    return result;
}

bool BmVoicePipeline::tx_output_available(std::size_t required) const noexcept
{
    return required <= max_tx_queued_codewords - tx_codeword_count_;
}

bool BmVoicePipeline::enqueue_tx_packet(const dmr_call::TxPacket& packet) noexcept
{
    if (outbound_count_ == outbound_.size()) {
        return false;
    }
    const std::size_t write = (outbound_read_ + outbound_count_) % outbound_.size();
    outbound_[write] = packet;
    ++outbound_count_;
    return true;
}

bool BmVoicePipeline::enqueue_codeword(const dmr_vocoder::Codeword& codeword) noexcept
{
    if (tx_codeword_count_ == tx_codewords_.size()) {
        return false;
    }
    const std::size_t write = (tx_codeword_read_ + tx_codeword_count_) % tx_codewords_.size();
    tx_codewords_[write] = codeword;
    ++tx_codeword_count_;
    return true;
}

bool BmVoicePipeline::append_downsampled(const std::int16_t* samples,
                                        std::size_t count,
                                        std::size_t& encoded_frames)
{
    encoded_frames = 0U;
    if (count != 0U && samples == nullptr) {
        return false;
    }
    for (std::size_t index = 0U; index < count; ++index) {
        tx_pcm_frame_[tx_pcm_fill_++] = samples[index];
        if (tx_pcm_fill_ != tx_pcm_frame_.size()) {
            continue;
        }
        if (!enqueue_codeword(encoder_.encode(tx_pcm_frame_))) {
            if (tx_has_pending_frame_) {
                return false;
            }
            tx_pending_frame_ = tx_pcm_frame_;
            tx_has_pending_frame_ = true;
        } else {
            ++encoded_frames;
        }
        tx_pcm_frame_.fill(0);
        tx_pcm_fill_ = 0U;
    }
    return true;
}

void BmVoicePipeline::try_finalize_tx()
{
    if (!tx_finalize_requested_ || tx_finalized_) {
        return;
    }
    if (tx_has_pending_frame_) {
        if (!tx_output_available(1U)) {
            return;
        }
        if (!enqueue_codeword(encoder_.encode(tx_pending_frame_))) {
            return;
        }
        tx_pending_frame_.fill(0);
        tx_has_pending_frame_ = false;
    }
    if (tx_pcm_fill_ != 0U) {
        if (!tx_output_available(1U)) {
            return;
        }
        std::fill(tx_pcm_frame_.begin() + static_cast<std::ptrdiff_t>(tx_pcm_fill_),
                  tx_pcm_frame_.end(), static_cast<std::int16_t>(0));
        if (!enqueue_codeword(encoder_.encode(tx_pcm_frame_))) {
            return;
        }
        tx_pcm_frame_.fill(0);
        tx_pcm_fill_ = 0U;
    }
    while (tx_codeword_count_ % tx_burst_codeword_count != 0U) {
        if (!tx_output_available(1U)) {
            return;
        }
        dmr_vocoder::PcmFrame silence{};
        if (!enqueue_codeword(encoder_.encode(silence))) {
            return;
        }
    }
    tx_finalized_ = true;
}

Error BmVoicePipeline::tick_tx(TimePoint now)
{
    if (tx_state_ == TxState::idle) {
        return Error::none;
    }
    if (router_ && routed_tx_lease_id_ && tx_state_ != TxState::idle &&
        !routed_tx_voice_permitted()) {
        // Permission撤销只清尚未发送的语音，并通过正常stop_tx路径保留租约EOT。
        (void)stop_tx(now);
        return Error::none;
    }
    if (tx_state_ == TxState::draining) {
        try_finalize_tx();
    }
    if (!tx_clock_started_) {
        const auto required_prebuffer = tx_state_ == TxState::draining
            ? codewords_per_burst
            : tx_start_prebuffer_codewords;
        if (tx_codeword_count_ >= required_prebuffer) {
            next_tx_due_ = now + voice_period;
            tx_clock_started_ = true;
        } else {
            return Error::none;
        }
    }
    if (now < next_tx_due_) {
        return Error::none;
    }
    const auto tx_lateness = now - next_tx_due_;
    if (tx_codeword_count_ >= codewords_per_burst) {
        if (tx_lateness > max_voice_schedule_lateness) {
            // 旧语音已太迟，结束这一通话，避免后续每次 tick 追赶发送积压 burst。
            (void)stop_tx(now);
            return Error::deadline_missed;
        }
        if (outbound_count_ == outbound_.size()) {
            return Error::tx_queue_full;
        }
        dmr_call::AmbeVoiceBurst burst{};
        for (std::size_t codeword_index = 0U; codeword_index < codewords_per_burst; ++codeword_index) {
            const auto& codeword = tx_codewords_[tx_codeword_read_];
            const std::size_t offset = codeword_index * dmr_vocoder::codeword_bytes;
            std::copy(codeword.begin(), codeword.end(), burst.begin() + static_cast<std::ptrdiff_t>(offset));
            tx_codeword_read_ = (tx_codeword_read_ + 1U) % tx_codewords_.size();
            --tx_codeword_count_;
        }
        const auto result = transmitter_.voice(burst);
        if (!result) {
            cancel_tx();
            return Error::not_active;
        }
        if (!enqueue_tx_packet(result.packet)) {
            cancel_tx();
            return Error::tx_queue_full;
        }
        next_tx_due_ = tx_lateness > voice_schedule_reanchor_lateness
            ? now + voice_period
            : next_tx_due_ + voice_period;
        if (tx_state_ == TxState::draining) {
            try_finalize_tx();
        }
        return Error::none;
    }

    if (tx_state_ == TxState::draining && tx_finalized_ && tx_codeword_count_ == 0U) {
        if (outbound_count_ == outbound_.size()) {
            return Error::tx_queue_full;
        }
        const auto result = transmitter_.finish();
        if (!result || !enqueue_tx_packet(result.packet)) {
            cancel_tx();
            return Error::not_active;
        }
        tx_state_ = TxState::idle;
        tx_finalize_requested_ = false;
        tx_finalized_ = false;
        tx_clock_started_ = false;
        downsampler_.reset();
        return Error::none;
    }
    // 没有可发媒体时跳过空时隙；小抖动仍沿绝对时钟前进，大停顿则重新等一个周期。
    if (tx_lateness > voice_schedule_reanchor_lateness) {
        next_tx_due_ = now + voice_period;
    } else {
        next_tx_due_ += voice_period;
    }
    return Error::none;
}

Error BmVoicePipeline::tick_rx(TimePoint now)
{
    if (routed_rx_cleanup_pending_ || rx_state_ == RxState::stopping) return Error::none;
    if (rx_state_ != RxState::idle && rx_state_ != RxState::filtered &&
        !rx_playback_ready_ && now >= rx_start_deadline_) {
        return timeout_rx_start();
    }
    if (!rx_playback_ready_ || rx_state_ == RxState::idle || rx_state_ == RxState::filtered ||
        rx_state_ == RxState::waiting_for_playback) {
        return Error::none;
    }
    if (rx_state_ == RxState::buffering) {
        if (rx_burst_count_ < 2U && !rx_network_ended_) {
            return Error::none;
        }
        rx_state_ = rx_network_ended_ ? RxState::draining : RxState::playing;
        next_rx_due_ = now;
    }
    if (now < next_rx_due_) {
        return Error::none;
    }
    const bool queued_voice = rx_burst_count_ != 0U || trailing_missing_bursts_ != 0U;
    const auto rx_lateness = now - next_rx_due_;
    if (queued_voice && rx_lateness > max_voice_schedule_lateness) {
        // 超期 burst 已不能按实时语音播放，清空通话并让调用方执行 HRI 收尾。
        cancel_rx();
        return Error::deadline_missed;
    }
    if (max_rx_queued_pcm_frames - playback_count_ < codewords_per_burst) {
        return Error::none;
    }

    if (rx_burst_count_ != 0U) {
        auto& queued = rx_bursts_[rx_burst_read_];
        if (queued.missing_before != 0U) {
            --queued.missing_before;
            for (std::size_t index = 0U; index < codewords_per_burst; ++index) {
                const std::size_t write = (playback_read_ + playback_count_) % max_rx_queued_pcm_frames;
                playback_frames_[write].pcm.fill(0);
                playback_frames_[write].sample_count = pcm48_samples_per_frame;
                ++playback_count_;
            }
            next_rx_due_ = rx_lateness > voice_schedule_reanchor_lateness
                ? now + voice_period
                : next_rx_due_ + voice_period;
            return Error::none;
        }

        for (std::size_t index = 0U; index < codewords_per_burst; ++index) {
            dmr_vocoder::Codeword codeword{};
            const std::size_t offset = index * dmr_vocoder::codeword_bytes;
            std::copy_n(queued.voice.begin() + static_cast<std::ptrdiff_t>(offset),
                        dmr_vocoder::codeword_bytes, codeword.begin());
            const auto decoded = decoder_.decode(codeword);
            Pcm48Frame frame{};
            const auto converted = upsampler_.process(decoded.pcm.data(), decoded.pcm.size(),
                                                       frame.data(), frame.size());
            if (converted.invalid_buffer || converted.input_consumed != decoded.pcm.size() ||
                converted.output_written != frame.size()) {
                frame.fill(0);
            }
            const std::size_t write = (playback_read_ + playback_count_) % max_rx_queued_pcm_frames;
            playback_frames_[write].pcm = frame;
            playback_frames_[write].sample_count = frame.size();
            ++playback_count_;
        }
        rx_burst_read_ = (rx_burst_read_ + 1U) % rx_bursts_.size();
        --rx_burst_count_;
        next_rx_due_ = rx_lateness > voice_schedule_reanchor_lateness
            ? now + voice_period
            : next_rx_due_ + voice_period;
        if (rx_state_ == RxState::draining) {
            return Error::none;
        }
        return Error::none;
    }

    if (trailing_missing_bursts_ != 0U) {
        --trailing_missing_bursts_;
        for (std::size_t index = 0U; index < codewords_per_burst; ++index) {
            const std::size_t write = (playback_read_ + playback_count_) % max_rx_queued_pcm_frames;
            playback_frames_[write].pcm.fill(0);
            playback_frames_[write].sample_count = pcm48_samples_per_frame;
            ++playback_count_;
        }
        next_rx_due_ = rx_lateness > voice_schedule_reanchor_lateness
            ? now + voice_period
            : next_rx_due_ + voice_period;
        return Error::none;
    }

    if (rx_network_ended_ && !rx_upsampler_finished_) {
        std::array<std::int16_t, audio::upsample_flush_input_samples *
                                 audio::resample_ratio_48k_8k> tail{};
        const auto flushed = upsampler_.finish(tail.data(), tail.size());
        if (!flushed.invalid_buffer && flushed.output_written != 0U &&
            playback_count_ < max_rx_queued_pcm_frames &&
            buffered_rx_frames() < max_rx_queued_pcm_frames) {
            const std::size_t write = (playback_read_ + playback_count_) % max_rx_queued_pcm_frames;
            playback_frames_[write].pcm.fill(0);
            std::copy_n(tail.begin(), flushed.output_written, playback_frames_[write].pcm.begin());
            playback_frames_[write].sample_count = flushed.output_written;
            ++playback_count_;
        }
        rx_upsampler_finished_ = true;
        finish_rx_if_drained();
        return Error::none;
    }
    if (rx_network_ended_) {
        rx_state_ = RxState::draining;
        finish_rx_if_drained();
    }
    return Error::none;
}

bool BmVoicePipeline::queue_event(const Event& event) noexcept
{
    if (event_count_ == events_.size()) {
        return false;
    }
    const std::size_t write = (event_read_ + event_count_) % events_.size();
    events_[write] = event;
    ++event_count_;
    return true;
}

bool BmVoicePipeline::filter_accepts(const dmr_call::CallConfig& call) const noexcept
{
    return filter_matches(receive_filter_, call) ||
        (secondary_receive_filter_enabled_ && filter_matches(secondary_receive_filter_, call));
}

bool BmVoicePipeline::filter_matches(const ReceiveFilter& filter,
                                     const dmr_call::CallConfig& call) noexcept
{
    return (filter.destination_id == 0U || filter.destination_id == call.destination_id) &&
           (!filter.match_slot || filter.slot == call.slot) &&
           (!filter.match_call_kind || filter.call_kind == call.kind) &&
           (!filter.match_source_id || filter.source_id == call.source_id);
}

bool BmVoicePipeline::filter_accepts_datagram(const dmrd::Datagram& datagram) const noexcept
{
    return filter_accepts(call_from_datagram(datagram));
}

dmr_call::CallConfig BmVoicePipeline::call_from_datagram(const dmrd::Datagram& datagram) noexcept
{
    constexpr std::uint8_t flag_ts2 = 0x80U;
    constexpr std::uint8_t flag_private_call = 0x40U;
    dmr_call::CallConfig candidate{};
    candidate.source_id = datagram.source_id;
    candidate.destination_id = datagram.destination_id;
    candidate.gateway_id = datagram.gateway_id;
    candidate.stream_id = datagram.stream_id;
    candidate.slot = (datagram.flags & flag_ts2) != 0U
        ? dmr_call::Slot::ts2
        : dmr_call::Slot::ts1;
    candidate.kind = (datagram.flags & flag_private_call) != 0U
        ? dmr_call::CallKind::private_call
        : dmr_call::CallKind::group;
    return candidate;
}

bool BmVoicePipeline::accept_time(TimePoint now) noexcept
{
    if (has_last_now_ && now < last_now_) {
        return false;
    }
    last_now_ = now;
    has_last_now_ = true;
    return true;
}

bool BmVoicePipeline::advance_rx_generation() noexcept
{
    if (rx_generation_ == std::numeric_limits<std::uint64_t>::max()) {
        rx_generation_exhausted_ = true;
        return false;
    }
    ++rx_generation_;
    return true;
}

std::size_t BmVoicePipeline::buffered_rx_frames() const noexcept
{
    std::size_t buffered = rx_burst_count_ * codewords_per_burst + playback_count_ + playback_inflight_ +
                           static_cast<std::size_t>(trailing_missing_bursts_) * codewords_per_burst;
    for (std::size_t index = 0U; index < rx_burst_count_; ++index) {
        const std::size_t queued_index = (rx_burst_read_ + index) % rx_bursts_.size();
        buffered += static_cast<std::size_t>(rx_bursts_[queued_index].missing_before) * codewords_per_burst;
    }
    return buffered;
}

Error BmVoicePipeline::process_receive_result(const dmr_call::ReceiveResult& result,
                                             TimePoint now)
{
    (void)now;
    for (std::size_t index = 0U; index < result.event_count; ++index) {
        const auto& protocol_event = result.events[index];
        if (!filter_accepts(protocol_event.call)) {
            continue;
        }
        switch (protocol_event.kind) {
        case dmr_call::ReceiveEventKind::call_started: {
            if (tx_state_ != TxState::idle ||
                (rx_state_ != RxState::idle && rx_state_ != RxState::filtered)) {
                Event collision{};
                collision.kind = EventKind::collision;
                collision.call = protocol_event.call;
                collision.generation = rx_generation_;
                (void)queue_event(collision);
                receiver_.reset();
                cancel_rx();
                return Error::half_duplex_collision;
            }
            if (!advance_rx_generation()) {
                receiver_.reset();
                cancel_rx();
                return Error::generation_exhausted;
            }
            rx_call_ = protocol_event.call;
            rx_have_link_control_ = protocol_event.link_control_validated;
            rx_color_code_known_ = protocol_event.color_code_known;
            if (router_) {
                const auto routed = router_->snapshot();
                if (routed.active_rx_call && routed.active_rx_generation != 0U) {
                    const auto& admitted = *routed.active_rx_call;
                    const bool same_stream = admitted.source_id == protocol_event.call.source_id &&
                                             admitted.destination_id == protocol_event.call.destination_id &&
                                             admitted.stream_id == protocol_event.call.stream_id &&
                                             admitted.slot == protocol_event.call.slot &&
                                             admitted.kind == protocol_event.call.kind;
                    if (same_stream) {
                        rx_call_ = admitted;
                        rx_have_link_control_ = true;
                        rx_color_code_known_ = true;
                        active_rx_mapping_ = RxGenerationMapping{
                            routed.active_rx_generation, rx_generation_};
                    }
                }
            }
            decoder_.reset();
            upsampler_.reset();
            clear_rx_media();
            rx_state_ = RxState::waiting_for_playback;
            rx_playback_ready_ = false;
            rx_network_ended_ = false;
            rx_start_deadline_ = now + receive_start_timeout;
            Event started{};
            started.kind = EventKind::receive_started;
            started.call = rx_call_;
            started.link_control_validated = rx_have_link_control_;
            started.color_code_known = rx_color_code_known_;
            started.generation = rx_generation_;
            if (!queue_event(started)) {
                receiver_.reset();
                cancel_rx();
                return Error::event_queue_full;
            }
            break;
        }
        case dmr_call::ReceiveEventKind::voice: {
            if (rx_state_ == RxState::filtered) {
                continue;
            }
            if (rx_state_ == RxState::idle) {
                return Error::no_receive_call;
            }
            if (rx_burst_count_ == rx_bursts_.size()) {
                Event overflow{};
                overflow.kind = EventKind::queue_overflow;
                overflow.call = rx_call_;
                overflow.generation = rx_generation_;
                (void)queue_event(overflow);
                receiver_.reset();
                cancel_rx();
                return Error::rx_queue_full;
            }
            const auto missing = cap_missing(protocol_event.missing_packets);
            const std::size_t incoming_frames =
                (static_cast<std::size_t>(missing) + 1U) * codewords_per_burst;
            if (buffered_rx_frames() + incoming_frames > max_rx_queued_pcm_frames) {
                Event overflow{};
                overflow.kind = EventKind::queue_overflow;
                overflow.call = rx_call_;
                overflow.generation = rx_generation_;
                (void)queue_event(overflow);
                receiver_.reset();
                cancel_rx();
                return Error::rx_queue_full;
            }
            const std::size_t write = (rx_burst_read_ + rx_burst_count_) % rx_bursts_.size();
            rx_bursts_[write].voice = protocol_event.voice;
            rx_bursts_[write].missing_before = missing;
            ++rx_burst_count_;
            rx_call_ = protocol_event.call;
            rx_have_link_control_ = protocol_event.link_control_validated;
            rx_color_code_known_ = protocol_event.color_code_known;
            if (rx_state_ == RxState::buffering && rx_burst_count_ >= 2U) {
                next_rx_due_ = now;
            }
            break;
        }
        case dmr_call::ReceiveEventKind::link_control_confirmed:
            rx_call_ = protocol_event.call;
            rx_have_link_control_ = true;
            rx_color_code_known_ = protocol_event.color_code_known;
            break;
        case dmr_call::ReceiveEventKind::call_ended: {
            if (rx_state_ == RxState::filtered) {
                rx_state_ = RxState::idle;
                rx_call_ = {};
                continue;
            }
            if (rx_state_ == RxState::idle) {
                continue;
            }
            if (router_ && active_rx_mapping_) {
                (void)router_->rx_network_eot(active_rx_mapping_->router_generation);
            }
            rx_network_ended_ = true;
            rx_state_ = RxState::draining;
            const auto missing = cap_missing(protocol_event.missing_packets);
            const std::size_t buffered = buffered_rx_frames();
            const std::size_t available = buffered < max_rx_queued_pcm_frames
                ? max_rx_queued_pcm_frames - buffered
                : 0U;
            trailing_missing_bursts_ = static_cast<std::uint8_t>(std::min<std::size_t>(
                missing, available / codewords_per_burst));
            rx_call_ = protocol_event.call;
            Event ended{};
            ended.kind = EventKind::network_ended;
            ended.call = protocol_event.call;
            ended.end_reason = protocol_event.end_reason;
            ended.missing_packets = protocol_event.missing_packets;
            ended.link_control_validated = protocol_event.link_control_validated;
            ended.color_code_known = protocol_event.color_code_known;
            ended.generation = rx_generation_;
            if (!queue_event(ended)) {
                receiver_.reset();
                cancel_rx();
                return Error::event_queue_full;
            }
            break;
        }
        }
    }
    return Error::none;
}

void BmVoicePipeline::clear_rx_media() noexcept
{
    for (std::size_t index = 0U; index < max_rx_queued_pcm_frames; ++index) {
        playback_frames_[index].pcm.fill(0);
        playback_frames_[index].sample_count = 0U;
    }
    rx_burst_read_ = 0U;
    rx_burst_count_ = 0U;
    playback_read_ = 0U;
    playback_count_ = 0U;
    playback_inflight_ = 0U;
    trailing_missing_bursts_ = 0U;
    next_rx_due_ = {};
    rx_upsampler_finished_ = false;
}

Error BmVoicePipeline::timeout_rx_start() noexcept
{
    Event timeout{};
    timeout.kind = EventKind::playback_start_timeout;
    timeout.call = rx_call_;
    timeout.link_control_validated = rx_have_link_control_;
    timeout.color_code_known = rx_color_code_known_;
    timeout.generation = rx_generation_;
    const bool event_queued = queue_event(timeout);
    if (router_ && active_rx_mapping_) {
        const auto stop_error = stop_routed_rx(false);
        if (stop_error != Error::none) return stop_error;
        return event_queued ? Error::playback_start_timeout : Error::event_queue_full;
    }
    receiver_.reset();
    upsampler_.reset();
    clear_rx_media();
    rx_state_ = RxState::idle;
    rx_call_ = {};
    rx_playback_ready_ = false;
    rx_network_ended_ = false;
    rx_have_link_control_ = false;
    rx_color_code_known_ = false;
    rx_upsampler_finished_ = false;
    rx_start_deadline_ = {};
    const bool generation_advanced = advance_rx_generation();
    if (!event_queued) {
        return Error::event_queue_full;
    }
    return generation_advanced ? Error::playback_start_timeout : Error::generation_exhausted;
}

void BmVoicePipeline::finish_rx_if_drained() noexcept
{
    if (!rx_network_ended_ || !rx_playback_ready_ || !rx_upsampler_finished_ || rx_burst_count_ != 0U ||
        playback_count_ != 0U || playback_inflight_ != 0U || trailing_missing_bursts_ != 0U) {
        return;
    }
    Event drained{};
    drained.kind = EventKind::playback_drained;
    drained.call = rx_call_;
    drained.link_control_validated = rx_have_link_control_;
    drained.color_code_known = rx_color_code_known_;
    drained.generation = rx_generation_;
    if (!queue_event(drained)) {
        return;
    }
    if (router_ && active_rx_mapping_) {
        const auto mapping = *active_rx_mapping_;
        if (router_->rx_playback_finished(mapping.router_generation) !=
            talkgroup_routing::OperationStatus::completed) {
            return;
        }
        active_rx_mapping_.reset();
        stopping_rx_mapping_ = mapping;
        routed_rx_cleanup_pending_ = true;
        retire_routed_stream(rx_call_, has_last_now_ ? last_now_ : TimePoint{});
        upsampler_.reset();
        receiver_.reset();
        rx_state_ = RxState::stopping;
        rx_playback_ready_ = false;
        rx_network_ended_ = true;
        rx_upsampler_finished_ = true;
        clear_rx_media();
        return;
    }
    upsampler_.reset();
    receiver_.reset();
    rx_state_ = RxState::idle;
    rx_call_ = {};
    rx_playback_ready_ = false;
    rx_network_ended_ = false;
    rx_have_link_control_ = false;
    rx_color_code_known_ = false;
    rx_start_deadline_ = {};
    clear_rx_media();
}

} // namespace wirex::bm_voice
