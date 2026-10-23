#include "wirex/hri_downlink_session.hpp"

#include "wirex/direct_frame.hpp"

#include <algorithm>
#include <limits>
#include <utility>

namespace wirex::hri_downlink_session {
namespace {

std::uint64_t add_bounded(std::uint64_t base, std::uint64_t delta) noexcept
{
    if (delta > std::numeric_limits<std::uint64_t>::max() - base) {
        return std::numeric_limits<std::uint64_t>::max();
    }
    return base + delta;
}

bool valid_candidate(const CandidateFrame& frame)
{
    const auto decoded = direct_frame::decode(frame.data(), frame.size());
    return decoded && decoded.record.type == 'T' && decoded.record.payload.size() <= max_record_payload_size;
}

bool valid_config(const Config& config) noexcept
{
    return config.start_timeout_ms != 0 &&
        config.start_timeout_ms <= max_flow_duration_ms &&
        config.normal_stop_timeout_ms != 0 &&
        config.normal_stop_timeout_ms <= max_flow_duration_ms &&
        config.cancelled_stop_timeout_ms != 0 &&
        config.cancelled_stop_timeout_ms <= max_flow_duration_ms &&
        config.overall_timeout_ms != 0 &&
        config.overall_timeout_ms <= max_flow_duration_ms;
}

void increment_saturated(std::uint64_t& value) noexcept
{
    if (value != std::numeric_limits<std::uint64_t>::max()) ++value;
}

} // 匿名命名空间

Session::Session(CandidateFrame start_candidate, CandidateFrame stop_candidate, Config config)
    : start_candidate_(std::move(start_candidate)),
      stop_candidate_(std::move(stop_candidate)),
      config_(config),
      parser_(max_record_payload_size)
{
}

Update Session::start(std::uint64_t now_ms, std::uint64_t pcm_window_ms)
{
    Update update = make_update();
    if (started_) {
        update.error = EventError::invalid_phase;
        return update;
    }

    started_ = true;
    started_at_ms_ = now_ms;
    last_observed_ms_ = now_ms;
    overall_deadline_ms_ = add_bounded(now_ms, config_.overall_timeout_ms);
    pcm_window_ms_ = pcm_window_ms;

    if (!valid_config(config_)) {
        set_failure(StopReason::invalid_configuration);
        enter_cleanup(update);
    } else if (!valid_candidate(start_candidate_) || !valid_candidate(stop_candidate_)) {
        set_failure(StopReason::invalid_candidate_frame);
        enter_cleanup(update);
    } else if (pcm_window_ms_ == 0 || pcm_window_ms_ > max_flow_duration_ms) {
        set_failure(StopReason::invalid_pcm_window);
        enter_cleanup(update);
    } else {
        state_.phase = Phase::start_write_pending;
        update.actions.push_back(Action{ActionKind::write_start_candidate, start_write_id, start_candidate_});
    }
    update.state = state_;
    return update;
}

Update Session::write_attempted(std::uint64_t write_id, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;

    if (write_id == start_write_id) {
        if (state_.start_write_attempted) {
            update.error = EventError::duplicate_write_attempt;
        } else if (state_.phase != Phase::start_write_pending) {
            update.error = EventError::invalid_phase;
        } else if (transport_failed_) {
            update.error = EventError::invalid_phase;
        } else {
            state_.start_write_attempted = true;
            state_.phase = Phase::start_write_in_progress;
        }
    } else if (write_id == stop_write_id) {
        if (state_.stop_write_attempted) {
            update.error = EventError::duplicate_write_attempt;
        } else if (state_.phase != Phase::stop_write_pending) {
            update.error = EventError::invalid_phase;
        } else if (!state_.start_write_attempted || !stop_scheduled_) {
            update.error = EventError::write_not_attempted;
        } else if (transport_failed_) {
            enter_cleanup(update);
            update.error = EventError::invalid_phase;
        } else {
            state_.stop_write_attempted = true;
            state_.phase = Phase::stop_write_in_progress;
        }
    } else {
        update.error = EventError::invalid_write_id;
    }

    update.state = state_;
    return update;
}

Update Session::write_completed(std::uint64_t write_id, bool succeeded, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;

    if (write_id == start_write_id) {
        if (state_.start_write_completed) {
            update.error = EventError::duplicate_write_completion;
            update.state = state_;
            return update;
        }
        if (!state_.start_write_attempted) {
            update.error = EventError::write_not_attempted;
            update.state = state_;
            return update;
        }
        if (state_.phase != Phase::start_write_in_progress) {
            update.error = EventError::invalid_phase;
            update.state = state_;
            return update;
        }

        // 写调用前到达的不完整记录不能跨越本次候选写入成为应答。
        parser_.reset();
        state_.start_write_completed = true;
        state_.start_write_succeeded = succeeded;
        if (transport_failed_) {
            enter_cleanup(update);
        } else if (!succeeded) {
            set_failure(StopReason::start_write_failed);
            schedule_stop(update);
        } else if (cancellation_requested_ || overall_expired_) {
            schedule_stop(update);
        } else {
            state_.phase = Phase::awaiting_start_record;
            record_deadline_ms_ = std::min(add_bounded(now_ms, config_.start_timeout_ms), overall_deadline_ms_);
            advance_deadlines(now_ms, update);
        }
    } else if (write_id == stop_write_id) {
        if (state_.stop_write_completed) {
            update.error = EventError::duplicate_write_completion;
            update.state = state_;
            return update;
        }
        if (!state_.stop_write_attempted) {
            update.error = EventError::write_not_attempted;
            update.state = state_;
            return update;
        }
        if (state_.phase != Phase::stop_write_in_progress) {
            update.error = EventError::invalid_phase;
            update.state = state_;
            return update;
        }

        // 写调用前到达的不完整记录不能跨越本次候选写入成为应答。
        parser_.reset();
        state_.stop_write_completed = true;
        state_.stop_write_succeeded = succeeded;
        if (transport_failed_) {
            enter_cleanup(update);
        } else if (!succeeded) {
            set_failure(StopReason::stop_write_failed);
            enter_cleanup(update);
        } else if (overall_expired_) {
            enter_cleanup(update);
        } else {
            state_.phase = Phase::awaiting_stop_record;
            const auto timeout = cancellation_requested_ ?
                config_.cancelled_stop_timeout_ms : config_.normal_stop_timeout_ms;
            record_deadline_ms_ = std::min(add_bounded(now_ms, timeout), overall_deadline_ms_);
            advance_deadlines(now_ms, update);
        }
    } else {
        update.error = EventError::invalid_write_id;
    }

    update.state = state_;
    return update;
}

Update Session::feed(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;

    const auto parsed = parser_.feed(bytes, size);
    for (const auto& event : parsed.events) {
        if (!event.has_record) {
            increment_saturated(state_.malformed_records);
            if (event.error == direct_stream::Error::null_input) update.error = EventError::null_input;
            continue;
        }
        process_record(event.record, now_ms, update);
    }
    update.state = state_;
    return update;
}

Update Session::pcm_started(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;

    if (state_.phase != Phase::pcm_ready || pcm_stop_requested_) {
        update.error = EventError::invalid_phase;
    } else {
        state_.pcm_started = true;
        state_.phase = Phase::pcm_active;
    }
    update.state = state_;
    return update;
}

Update Session::pcm_completed(bool succeeded, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;

    if (state_.pcm_completed || (state_.phase != Phase::pcm_ready &&
        state_.phase != Phase::pcm_active && state_.phase != Phase::pcm_stop_pending)) {
        update.error = EventError::invalid_phase;
    } else {
        state_.pcm_completed = true;
        state_.pcm_succeeded = succeeded;
        if (!succeeded) set_failure(StopReason::pcm_failed);
        schedule_stop(update);
    }
    update.state = state_;
    return update;
}

Update Session::cancel(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;
    if (state_.phase == Phase::finished || state_.phase == Phase::cleanup_pending) {
        update.error = EventError::invalid_phase;
        update.state = state_;
        return update;
    }

    if (!cancellation_requested_) {
        cancellation_requested_ = true;
        if (state_.stop_reason == StopReason::none) set_failure(StopReason::cancelled);
    }

    switch (state_.phase) {
    case Phase::idle:
        update.error = EventError::invalid_phase;
        break;
    case Phase::start_write_pending:
        if (!state_.start_write_attempted) {
            if (state_.stop_reason == StopReason::cancelled) {
                state_.stop_reason = StopReason::cancelled_before_start_attempt;
            }
            enter_cleanup(update);
        }
        break;
    case Phase::start_write_in_progress:
        break;
    case Phase::awaiting_start_record:
        schedule_stop(update);
        break;
    case Phase::pcm_ready:
    case Phase::pcm_active:
        request_pcm_stop(update);
        break;
    case Phase::pcm_stop_pending:
    case Phase::stop_write_pending:
    case Phase::stop_write_in_progress:
        break;
    case Phase::awaiting_stop_record:
        record_deadline_ms_ = std::min(record_deadline_ms_,
            add_bounded(now_ms, config_.cancelled_stop_timeout_ms));
        break;
    case Phase::cleanup_pending:
    case Phase::finished:
        update.error = EventError::invalid_phase;
        break;
    }

    update.state = state_;
    return update;
}

Update Session::transport_failed(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;
    if (state_.phase == Phase::finished) {
        update.error = EventError::invalid_phase;
        update.state = state_;
        return update;
    }

    transport_failed_ = true;
    set_failure(StopReason::transport_failed);
    switch (state_.phase) {
    case Phase::start_write_in_progress:
    case Phase::stop_write_in_progress:
        // 等待当前同步写入返回，调用方随后报告其结果并清理串口。
        break;
    case Phase::pcm_ready:
    case Phase::pcm_active:
        request_pcm_stop(update);
        break;
    case Phase::pcm_stop_pending:
        break;
    case Phase::cleanup_pending:
        break;
    case Phase::idle:
    case Phase::start_write_pending:
    case Phase::awaiting_start_record:
    case Phase::stop_write_pending:
    case Phase::awaiting_stop_record:
        enter_cleanup(update);
        break;
    case Phase::finished:
        break;
    }
    update.state = state_;
    return update;
}

Update Session::tick(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (observe_time(now_ms, update)) advance_deadlines(now_ms, update);
    update.state = state_;
    return update;
}

Update Session::cleanup_completed(bool audio_cleanup_succeeded,
                                  bool serial_cleanup_succeeded,
                                  std::uint64_t now_ms)
{
    Update update = make_update();
    if (!started_) {
        update.error = EventError::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;
    if (cleanup_reported_) {
        update.error = EventError::cleanup_already_reported;
    } else if (state_.phase != Phase::cleanup_pending) {
        update.error = EventError::cleanup_not_pending;
    } else {
        cleanup_reported_ = true;
        state_.audio_cleanup_reported = true;
        state_.audio_cleanup_succeeded = audio_cleanup_succeeded;
        state_.serial_cleanup_reported = true;
        state_.serial_cleanup_succeeded = serial_cleanup_succeeded;
        if (!audio_cleanup_succeeded || !serial_cleanup_succeeded) {
            set_failure(StopReason::pc_cleanup_failed);
        }
        state_.final = true;
        state_.phase = Phase::finished;
        finalize_status();
    }
    update.state = state_;
    return update;
}

Snapshot Session::snapshot() const noexcept
{
    return state_;
}

Update Session::make_update() const
{
    return Update{{}, state_, EventError::none};
}

bool Session::observe_time(std::uint64_t now_ms, Update& update)
{
    if (now_ms < last_observed_ms_) {
        update.error = EventError::invalid_time;
        update.state = state_;
        return false;
    }
    last_observed_ms_ = now_ms;
    advance_deadlines(now_ms, update);
    return true;
}

void Session::advance_deadlines(std::uint64_t now_ms, Update& update)
{
    if (!started_ || state_.phase == Phase::finished || state_.phase == Phase::idle) return;

    if (!overall_expired_ && now_ms >= overall_deadline_ms_) {
        overall_expired_ = true;
        set_failure(StopReason::overall_timeout);
        switch (state_.phase) {
        case Phase::start_write_pending:
            if (state_.start_write_attempted) break;
            enter_cleanup(update);
            return;
        case Phase::start_write_in_progress:
        case Phase::stop_write_in_progress:
        case Phase::stop_write_pending:
        case Phase::pcm_stop_pending:
        case Phase::cleanup_pending:
            return;
        case Phase::awaiting_start_record:
            schedule_stop(update);
            return;
        case Phase::pcm_ready:
        case Phase::pcm_active:
            request_pcm_stop(update);
            return;
        case Phase::awaiting_stop_record:
            enter_cleanup(update);
            return;
        case Phase::idle:
        case Phase::finished:
            return;
        }
    }

    if (overall_expired_) {
        switch (state_.phase) {
        case Phase::awaiting_start_record:
            schedule_stop(update);
            return;
        case Phase::pcm_ready:
        case Phase::pcm_active:
            request_pcm_stop(update);
            return;
        case Phase::awaiting_stop_record:
            enter_cleanup(update);
            return;
        default:
            return;
        }
    }

    if (state_.phase == Phase::awaiting_start_record && now_ms >= record_deadline_ms_) {
        set_failure(StopReason::start_record_timeout);
        schedule_stop(update);
    } else if ((state_.phase == Phase::pcm_ready || state_.phase == Phase::pcm_active) &&
               now_ms >= pcm_deadline_ms_) {
        set_failure(StopReason::pcm_window_expired);
        request_pcm_stop(update);
    } else if (state_.phase == Phase::awaiting_stop_record && now_ms >= record_deadline_ms_) {
        set_failure(StopReason::stop_record_timeout);
        enter_cleanup(update);
    }
}

void Session::process_record(const direct_frame::Record& record,
                             std::uint64_t now_ms,
                             Update& update)
{
    if (record.type != 'T') return;

    if (state_.phase == Phase::awaiting_start_record && state_.start_write_completed &&
        state_.start_write_succeeded && !cancellation_requested_ && !overall_expired_ &&
        now_ms < record_deadline_ms_) {
        state_.start_matching_t_record_observed = true;
        state_.start_matching_t_payload_bytes = record.payload.size();
        const auto stop_reserve_ms = config_.normal_stop_timeout_ms;
        const auto pcm_latest_end_ms = overall_deadline_ms_ > stop_reserve_ms ?
            overall_deadline_ms_ - stop_reserve_ms : started_at_ms_;
        if (pcm_latest_end_ms <= now_ms) {
            set_failure(StopReason::overall_timeout);
            schedule_stop(update);
            return;
        }
        state_.pcm_permitted = true;
        state_.phase = Phase::pcm_ready;
        pcm_deadline_ms_ = std::min(add_bounded(now_ms, pcm_window_ms_), pcm_latest_end_ms);
        update.actions.push_back(Action{ActionKind::allow_pcm, 0, {}});
        return;
    }

    if (state_.phase == Phase::awaiting_stop_record && state_.stop_write_completed &&
        state_.stop_write_succeeded && !overall_expired_ && now_ms < record_deadline_ms_) {
        state_.stop_matching_t_record_observed = true;
        state_.stop_matching_t_payload_bytes = record.payload.size();
        enter_cleanup(update);
        return;
    }

    increment_saturated(state_.unmatched_t_records);
}

void Session::schedule_stop(Update& update)
{
    if (stop_scheduled_) return;
    if (!state_.start_write_attempted || transport_failed_) {
        enter_cleanup(update);
        return;
    }

    stop_scheduled_ = true;
    state_.phase = Phase::stop_write_pending;
    update.actions.push_back(Action{ActionKind::write_stop_candidate, stop_write_id, stop_candidate_});
}

void Session::request_pcm_stop(Update& update)
{
    if (state_.pcm_completed) {
        schedule_stop(update);
        return;
    }
    if (!pcm_stop_requested_) {
        pcm_stop_requested_ = true;
        state_.phase = Phase::pcm_stop_pending;
        update.actions.push_back(Action{ActionKind::request_pcm_stop, 0, {}});
    }
}

void Session::enter_cleanup(Update& update)
{
    if (state_.phase == Phase::cleanup_pending || state_.phase == Phase::finished) return;
    state_.phase = Phase::cleanup_pending;
    update.actions.push_back(Action{ActionKind::cleanup_required, 0, {}});
}

void Session::set_failure(StopReason reason) noexcept
{
    if (reason == StopReason::none) return;
    if (state_.stop_reason == StopReason::none ||
        state_.stop_reason == StopReason::cancelled ||
        state_.stop_reason == StopReason::cancelled_before_start_attempt) {
        state_.stop_reason = reason;
    }
}

void Session::finalize_status() noexcept
{
    if (!state_.audio_cleanup_succeeded || !state_.serial_cleanup_succeeded) {
        state_.status = Status::failed;
        return;
    }

    if (state_.stop_reason == StopReason::cancelled ||
        state_.stop_reason == StopReason::cancelled_before_start_attempt) {
        state_.status = Status::cancelled;
        return;
    }

    const bool complete = state_.stop_reason == StopReason::none &&
        state_.start_write_attempted && state_.start_write_completed && state_.start_write_succeeded &&
        state_.start_matching_t_record_observed && state_.pcm_permitted && state_.pcm_started &&
        state_.pcm_completed && state_.pcm_succeeded && state_.stop_write_attempted &&
        state_.stop_write_completed && state_.stop_write_succeeded &&
        state_.stop_matching_t_record_observed;
    state_.status = complete ? Status::completed : Status::failed;
}

} // namespace wirex::hri_downlink_session
