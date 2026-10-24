#include "wirex/hri_stream_session.hpp"

#include "wirex/direct_frame.hpp"

#include <algorithm>
#include <limits>
#include <utility>

namespace wirex::hri_stream_session {
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
    return config.start_record_timeout_ms != 0U &&
        config.start_record_timeout_ms <= max_call_window_ms &&
        config.stop_record_timeout_ms != 0U &&
        config.stop_record_timeout_ms <= max_call_window_ms &&
        config.max_call_window_ms != 0U &&
        config.max_call_window_ms <= max_call_window_ms;
}

void increment_saturated(std::uint64_t& value) noexcept
{
    if (value != std::numeric_limits<std::uint64_t>::max()) ++value;
}

} // namespace

Session::Session(CandidateFrame start_candidate, CandidateFrame stop_candidate, Config config)
    : start_candidate_(std::move(start_candidate)),
      stop_candidate_(std::move(stop_candidate)),
      config_(config),
      parser_(max_record_payload_size)
{
}

Update Session::begin_call(std::uint64_t now_ms, std::uint64_t call_window_ms)
{
    Update update = make_update();
    if (state_.phase != Phase::idle || active_call_) {
        update.error = Error::invalid_phase;
        return update;
    }
    if (now_ms < last_observed_ms_) {
        update.error = Error::invalid_time;
        return update;
    }
    last_observed_ms_ = now_ms;
    reset_call_state();
    if (!valid_config(config_) || call_window_ms == 0U || call_window_ms > config_.max_call_window_ms) {
        state_.reason = Reason::invalid_configuration;
        state_.phase = Phase::faulted;
        update.actions.push_back(Action{ActionKind::call_finished, 0U, {}});
    } else if (!valid_candidate(start_candidate_) || !valid_candidate(stop_candidate_)) {
        state_.reason = Reason::invalid_candidate_frame;
        state_.phase = Phase::faulted;
        update.actions.push_back(Action{ActionKind::call_finished, 0U, {}});
    } else {
        active_call_ = true;
        call_deadline_ms_ = add_bounded(now_ms, call_window_ms);
        state_.phase = Phase::start_write_pending;
        update.actions.push_back(Action{ActionKind::write_start_candidate, start_write_id, start_candidate_});
    }
    update.state = state_;
    return update;
}

Update Session::write_attempted(std::uint64_t write_id, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!observe_time(now_ms, update)) return update;

    if (write_id == start_write_id) {
        if (state_.start_write_attempted) {
            update.error = Error::duplicate_write_attempt;
        } else if (state_.phase != Phase::start_write_pending) {
            update.error = Error::invalid_phase;
        } else {
            state_.start_write_attempted = true;
            state_.phase = Phase::start_write_in_progress;
        }
    } else if (write_id == stop_write_id) {
        if (state_.stop_write_attempted) {
            update.error = Error::duplicate_write_attempt;
        } else if (state_.phase != Phase::stop_write_pending || !stop_scheduled_) {
            update.error = Error::invalid_phase;
        } else {
            state_.stop_write_attempted = true;
            state_.phase = Phase::stop_write_in_progress;
        }
    } else {
        update.error = Error::invalid_write_id;
    }
    update.state = state_;
    return update;
}

Update Session::write_completed(std::uint64_t write_id, bool succeeded, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!observe_time(now_ms, update)) return update;

    if (write_id == start_write_id) {
        if (state_.start_write_completed) {
            update.error = Error::duplicate_write_completion;
        } else if (!state_.start_write_attempted) {
            update.error = Error::write_not_attempted;
        } else if (state_.phase != Phase::start_write_in_progress) {
            update.error = Error::invalid_phase;
        } else {
            parser_.reset();
            state_.start_write_completed = true;
            state_.start_write_succeeded = succeeded;
            if (!succeeded) {
                state_.reason = Reason::start_write_failed;
                schedule_stop(update);
            } else if (now_ms >= call_deadline_ms_) {
                state_.reason = Reason::call_window_expired;
                update.actions.push_back(Action{ActionKind::cancel_playback, 0U, {}});
                schedule_stop(update);
            } else {
                state_.phase = Phase::awaiting_start_record;
                record_deadline_ms_ = std::min(add_bounded(now_ms, config_.start_record_timeout_ms), call_deadline_ms_);
            }
        }
    } else if (write_id == stop_write_id) {
        if (state_.stop_write_completed) {
            update.error = Error::duplicate_write_completion;
        } else if (!state_.stop_write_attempted) {
            update.error = Error::write_not_attempted;
        } else if (state_.phase != Phase::stop_write_in_progress) {
            update.error = Error::invalid_phase;
        } else {
            parser_.reset();
            state_.stop_write_completed = true;
            state_.stop_write_succeeded = succeeded;
            if (!succeeded) {
                state_.reason = Reason::stop_write_failed;
                finish_call(update, true);
            } else {
                state_.phase = Phase::awaiting_stop_record;
                record_deadline_ms_ = add_bounded(now_ms, config_.stop_record_timeout_ms);
            }
        }
    } else {
        update.error = Error::invalid_write_id;
    }
    update.state = state_;
    return update;
}

Update Session::feed(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!active_call_) {
        update.error = Error::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;
    if (bytes == nullptr && size != 0U) {
        update.error = Error::null_input;
        update.state = state_;
        return update;
    }
    if (size == 0U) {
        update.state = state_;
        return update;
    }

    const auto parsed = parser_.feed(bytes, size);
    for (const auto& event : parsed.events) {
        if (!event.has_record) {
            increment_saturated(state_.malformed_records);
            continue;
        }
        process_record(event.record.type, event.record.payload.size(), now_ms, update);
    }
    update.state = state_;
    return update;
}

Update Session::network_ended(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!active_call_) {
        update.error = Error::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;

    if (state_.phase == Phase::playing) {
        state_.phase = Phase::draining;
    } else if (state_.phase == Phase::draining || state_.phase == Phase::stop_write_pending ||
               state_.phase == Phase::stop_write_in_progress || state_.phase == Phase::awaiting_stop_record) {
        // 重复的网络结束通知不会再触发停止写入。
    } else {
        // HRI T3 应答可能晚于短 BM 呼叫的 EOT；缓存语音仍须等待 T3 后播放。
        network_ended_pending_ = true;
    }
    update.state = state_;
    return update;
}

Update Session::playback_drained(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!active_call_) {
        update.error = Error::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;
    if (state_.phase != Phase::draining) {
        update.error = Error::invalid_phase;
    } else {
        state_.playback_drained = true;
        schedule_stop(update);
    }
    update.state = state_;
    return update;
}

Update Session::cancel(Reason reason, std::uint64_t now_ms)
{
    Update update = make_update();
    if (!active_call_) {
        update.error = Error::invalid_phase;
        return update;
    }
    if (!observe_time(now_ms, update)) return update;
    if (state_.phase == Phase::faulted || state_.phase == Phase::idle) {
        update.error = Error::invalid_phase;
        return update;
    }
    if (state_.reason == Reason::none) state_.reason = reason;
    update.actions.push_back(Action{ActionKind::cancel_playback, 0U, {}});
    if (state_.phase == Phase::start_write_pending && !state_.start_write_attempted) {
        finish_call(update, false);
    } else if (state_.phase != Phase::stop_write_pending && state_.phase != Phase::stop_write_in_progress &&
               state_.phase != Phase::awaiting_stop_record) {
        schedule_stop(update);
    }
    update.state = state_;
    return update;
}

Update Session::tick(std::uint64_t now_ms)
{
    Update update = make_update();
    if (!observe_time(now_ms, update)) return update;
    if (!active_call_) {
        update.state = state_;
        return update;
    }

    if (now_ms >= call_deadline_ms_ && state_.phase != Phase::stop_write_pending &&
        state_.phase != Phase::stop_write_in_progress && state_.phase != Phase::awaiting_stop_record) {
        if (state_.reason == Reason::none) state_.reason = Reason::call_window_expired;
        update.actions.push_back(Action{ActionKind::cancel_playback, 0U, {}});
        if (state_.phase == Phase::start_write_pending && !state_.start_write_attempted) {
            finish_call(update, false);
        } else {
            schedule_stop(update);
        }
    } else if (state_.phase == Phase::awaiting_start_record && now_ms >= record_deadline_ms_) {
        if (state_.reason == Reason::none) state_.reason = Reason::start_record_timeout;
        update.actions.push_back(Action{ActionKind::cancel_playback, 0U, {}});
        schedule_stop(update);
    } else if (state_.phase == Phase::awaiting_stop_record && now_ms >= record_deadline_ms_) {
        if (state_.reason == Reason::none) state_.reason = Reason::stop_record_timeout;
        finish_call(update, false);
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
    return Update{{}, state_, Error::none};
}

bool Session::observe_time(std::uint64_t now_ms, Update& update)
{
    if (now_ms < last_observed_ms_) {
        update.error = Error::invalid_time;
        update.state = state_;
        return false;
    }
    last_observed_ms_ = now_ms;
    return true;
}

void Session::process_record(std::uint8_t type, std::size_t payload_size,
                             std::uint64_t now_ms, Update& update)
{
    if (type != static_cast<std::uint8_t>('T')) return;
    if (state_.phase == Phase::awaiting_start_record && state_.start_write_completed &&
        state_.start_write_succeeded && now_ms < record_deadline_ms_ && now_ms < call_deadline_ms_) {
        state_.start_t_record_observed = true;
        state_.playback_permitted = true;
        state_.phase = network_ended_pending_ ? Phase::draining : Phase::playing;
        update.actions.push_back(Action{ActionKind::playback_permitted, 0U, {}});
    } else if (state_.phase == Phase::awaiting_stop_record && state_.stop_write_completed &&
               state_.stop_write_succeeded && now_ms < record_deadline_ms_) {
        state_.stop_t_record_observed = true;
        finish_call(update, false);
    } else {
        increment_saturated(state_.unmatched_t_records);
    }
    (void)payload_size; // T 记录是阶段观察，不把内容或长度当成 HRI ACK。
}

void Session::schedule_stop(Update& update)
{
    if (stop_scheduled_) return;
    if (!state_.start_write_attempted) {
        finish_call(update, false);
        return;
    }
    stop_scheduled_ = true;
    state_.phase = Phase::stop_write_pending;
    update.actions.push_back(Action{ActionKind::write_stop_candidate, stop_write_id, stop_candidate_});
}

void Session::finish_call(Update& update, bool faulted)
{
    if (!active_call_) return;
    active_call_ = false;
    state_.phase = faulted ? Phase::faulted : Phase::idle;
    increment_saturated(state_.completed_calls);
    parser_.reset();
    update.actions.push_back(Action{ActionKind::call_finished, 0U, {}});
}

void Session::reset_call_state() noexcept
{
    const auto completed_calls = state_.completed_calls;
    const auto malformed_records = state_.malformed_records;
    const auto unmatched_t_records = state_.unmatched_t_records;
    state_ = {};
    state_.completed_calls = completed_calls;
    state_.malformed_records = malformed_records;
    state_.unmatched_t_records = unmatched_t_records;
    state_.radio_state_unknown = true;
    parser_.reset();
    call_deadline_ms_ = 0U;
    record_deadline_ms_ = 0U;
    stop_scheduled_ = false;
    network_ended_pending_ = false;
}

} // namespace wirex::hri_stream_session
