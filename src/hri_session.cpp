#include "wirex/hri_session.hpp"

#include <algorithm>
#include <limits>
#include <utility>

namespace wirex::hri_session {
namespace {

bool model_is_ftx1(const std::vector<std::uint8_t>& payload) noexcept
{
    return payload.size() == 48 && payload[0] == 'F' && payload[1] == 'T' &&
        payload[2] == 'X' && payload[3] == '-' && payload[4] == '1';
}

bool add_time(std::uint64_t base, std::uint64_t duration, std::uint64_t& result) noexcept
{
    if (duration > std::numeric_limits<std::uint64_t>::max() - base) return false;
    result = base + duration;
    return true;
}

} // 匿名命名空间

Session::Session(std::vector<std::uint8_t> external_y_body, Config config)
    : y_body_(std::move(external_y_body)),
      config_(config),
      parser_(max_frame_bytes - direct_frame::fixed_overhead),
      config_valid_(config_.continuous || (config_.window_ms > 0 && config_.window_ms <= max_window_ms)),
      y_template_valid_(y_body_.size() == y_body_size && y_body_[5] == '2')
{
}

Update Session::start(std::uint64_t now_ms)
{
    Update update{};
    if (started_) {
        stop(StopReason::already_started);
        update.state = make_snapshot();
        return update;
    }
    if (!config_valid_) {
        stop(StopReason::invalid_configuration);
        update.state = make_snapshot();
        return update;
    }
    if (!y_template_valid_) {
        stop(StopReason::invalid_y_template);
        update.state = make_snapshot();
        return update;
    }
    if (!config_.continuous && !add_time(now_ms, config_.window_ms, deadline_ms_)) {
        stop(StopReason::time_overflow);
        update.state = make_snapshot();
        return update;
    }
    if (config_.continuous) deadline_ms_ = std::numeric_limits<std::uint64_t>::max();

    started_ = true;
    started_at_ms_ = now_ms;
    last_observed_ms_ = now_ms;
    phase_ = Phase::awaiting_version_write;
    (void)queue_command(CommandKind::version_query, direct_frame::Record{'V', {}}, update);
    update.state = make_snapshot();
    return update;
}

Update Session::tick(std::uint64_t now_ms)
{
    Update update{};
    if (!observe_time(now_ms)) {
        update.state = make_snapshot();
        return update;
    }

    if (!version_response_validated_ || pending_writes_.size() != 0 || now_ms < next_y_due_ms_) {
        update.state = make_snapshot();
        return update;
    }
    if (!config_.continuous && counters_.y_write_requested >= max_y_write_calls) {
        stop(StopReason::y_write_limit);
        update.state = make_snapshot();
        return update;
    }

    (void)queue_command(CommandKind::y_record, direct_frame::Record{'Y', y_body_}, update);
    update.state = make_snapshot();
    return update;
}

Update Session::feed(const std::uint8_t* bytes, std::size_t size, std::uint64_t now_ms)
{
    Update update{};
    if (!observe_time(now_ms)) {
        update.state = make_snapshot();
        return update;
    }
    if (bytes == nullptr && size != 0) {
        counters_.malformed_records++;
        stop(StopReason::malformed_record);
        update.state = make_snapshot();
        return update;
    }
    if (config_.continuous && size > max_continuous_feed_bytes) {
        stop(StopReason::receive_limit);
        update.state = make_snapshot();
        return update;
    }
    if (!config_.continuous && size > max_receive_bytes -
        std::min<std::uint64_t>(counters_.receive_bytes, max_receive_bytes)) {
        stop(StopReason::receive_limit);
        update.state = make_snapshot();
        return update;
    }
    counters_.receive_bytes += size;

    const auto parsed = parser_.feed(bytes, size);
    const auto rejected = std::find_if(parsed.events.begin(), parsed.events.end(), [](const auto& event) {
        return !event.has_record;
    });
    if (rejected != parsed.events.end()) {
        counters_.malformed_records++;
        stop(StopReason::malformed_record);
        update.commands.clear();
        update.state = make_snapshot();
        return update;
    }
    if (config_.continuous && parsed.events.size() > max_continuous_records_per_feed) {
        stop(StopReason::record_limit);
        update.state = make_snapshot();
        return update;
    }
    if (!config_.continuous && parsed.events.size() >
        max_valid_records - std::min<std::uint64_t>(counters_.valid_records, max_valid_records)) {
        stop(StopReason::record_limit);
        update.state = make_snapshot();
        return update;
    }
    counters_.valid_records += parsed.events.size();

    for (const auto& event : parsed.events) {
        const auto& record = event.record;
        if (record.type == 'V') {
            if (version_response_validated_ || phase_ != Phase::awaiting_version) {
                stop(StopReason::unexpected_version_record);
                break;
            }
            if (!model_is_ftx1(record.payload)) {
                stop(StopReason::version_mismatch);
                break;
            }
            version_response_validated_ = true;
            counters_.version_response_validated++;
            if (!add_time(now_ms, y_period_ms, next_y_due_ms_)) {
                stop(StopReason::time_overflow);
                break;
            }
            phase_ = Phase::waiting_for_y_due;
            continue;
        }

        if (record.type == 'Y' && record.payload.empty() && counters_.y_write_completed != 0) {
            counters_.y_zero_ack_received++;
            if (!add_time(now_ms, y_ack_timeout_ms, y_ack_deadline_ms_)) {
                stop(StopReason::time_overflow);
                break;
            }
            y_ack_timeout_armed_ = true;
            phase_ = Phase::exchanging;
            continue;
        }

        if (record.type == 'X' && record.payload.size() == y_body_size && counters_.y_write_completed != 0) {
            counters_.x100_received++;
            if (record.payload[11] == '1') counters_.unsupported_config_import_records++;
            if (!config_.continuous && counters_.x0_write_requested >= max_x_ack_write_calls) {
                stop(StopReason::x_ack_limit);
                break;
            }
            // 只复制已确认的对象字段对应字节；不为该字节赋予业务名称或含义。
            if (record.payload[11] != '1') {
                counters_.x_copy_branch_count++;
                if (y_body_[12] != record.payload[12]) counters_.y_byte12_changed_count++;
                y_body_[12] = record.payload[12];
                PttLevel ptt_level = PttLevel::unknown;
                if (record.payload[12] == '2') ptt_level = PttLevel::pressed;
                else if (record.payload[12] == '0') ptt_level = PttLevel::released;
                update.ptt_observations.push_back(PttObservation{
                    ptt_level, counters_.y_zero_ack_received != 0U});
            }
            (void)queue_command(CommandKind::x_ack, direct_frame::Record{'X', {}}, update);
            if (phase_ == Phase::stopped) break;
            continue;
        }

        counters_.other_valid_records++;
    }

    if (phase_ == Phase::stopped) {
        update.commands.clear();
        update.ptt_observations.clear();
    }
    update.state = make_snapshot();
    return update;
}

Update Session::write_completed(std::uint64_t command_id, bool succeeded, std::uint64_t now_ms)
{
    Update update{};
    if (!observe_time(now_ms)) {
        update.state = make_snapshot();
        return update;
    }
    if (pending_writes_.empty() || pending_writes_.front().id != command_id) {
        stop(StopReason::unexpected_write_completion);
        update.state = make_snapshot();
        return update;
    }
    const auto kind = pending_writes_.front().kind;
    pending_writes_.erase(pending_writes_.begin());
    if (!succeeded) {
        stop(StopReason::write_failed);
        update.state = make_snapshot();
        return update;
    }

    counters_.write_calls_completed++;
    switch (kind) {
    case CommandKind::version_query:
        counters_.version_query_write_completed++;
        if (!add_time(now_ms, version_response_timeout_ms, version_deadline_ms_)) {
            stop(StopReason::time_overflow);
            update.state = make_snapshot();
            return update;
        }
        phase_ = Phase::awaiting_version;
        break;
    case CommandKind::y_record:
        counters_.y_write_completed++;
        if (!add_time(now_ms, y_period_ms, next_y_due_ms_) ||
            (!y_ack_timeout_armed_ && !add_time(now_ms, y_ack_timeout_ms, y_ack_deadline_ms_))) {
            stop(StopReason::time_overflow);
            update.state = make_snapshot();
            return update;
        }
        if (!y_ack_timeout_armed_) y_ack_timeout_armed_ = true;
        phase_ = counters_.y_zero_ack_received != 0 ? Phase::exchanging : Phase::waiting_for_y_due;
        break;
    case CommandKind::x_ack:
        counters_.x0_write_completed++;
        break;
    }

    update.state = make_snapshot();
    return update;
}

Update Session::cancel()
{
    Update update{};
    stop(StopReason::cancelled);
    update.state = make_snapshot();
    return update;
}

Update Session::abort(StopReason reason)
{
    Update update{};
    if (reason == StopReason::none || reason == StopReason::deadline ||
        reason == StopReason::version_timeout || reason == StopReason::y_ack_timeout ||
        reason == StopReason::caller_stopped || reason == StopReason::already_started) {
        reason = StopReason::transport_failure;
    }
    stop(reason);
    update.state = make_snapshot();
    return update;
}

Update Session::finish(std::uint64_t now_ms)
{
    Update update{};
    if (!observe_time(now_ms)) {
        update.state = make_snapshot();
        return update;
    }
    if (parser_.buffered_bytes() != 0) stop(StopReason::incomplete_record);
    else stop(StopReason::caller_stopped);
    update.state = make_snapshot();
    return update;
}

Snapshot Session::snapshot() const noexcept
{
    return make_snapshot();
}

std::size_t Session::buffered_receive_bytes() const noexcept
{
    return parser_.buffered_bytes();
}

bool Session::observe_time(std::uint64_t now_ms)
{
    if (!started_ || phase_ == Phase::stopped) return false;
    if (now_ms < last_observed_ms_) {
        stop(StopReason::clock_regressed);
        return false;
    }
    last_observed_ms_ = now_ms;
    if (!config_.continuous && now_ms >= deadline_ms_) {
        if (parser_.buffered_bytes() != 0) stop(StopReason::incomplete_record);
        else stop(StopReason::deadline);
        return false;
    }
    if (phase_ == Phase::awaiting_version && now_ms >= version_deadline_ms_) {
        stop(StopReason::version_timeout);
        return false;
    }
    if (y_ack_timeout_armed_ && now_ms >= y_ack_deadline_ms_) {
        stop(StopReason::y_ack_timeout);
        return false;
    }
    return true;
}

bool Session::queue_command(CommandKind kind, direct_frame::Record record, Update& update)
{
    if (phase_ == Phase::stopped) return false;
    if (pending_writes_.size() >= max_pending_writes) {
        stop(StopReason::pending_write_limit);
        return false;
    }
    const auto encoded = direct_frame::encode(record);
    if (!encoded || (!config_.continuous && encoded.bytes.size() > max_transmit_bytes -
        std::min<std::uint64_t>(counters_.transmit_bytes_requested, max_transmit_bytes))) {
        stop(StopReason::transmit_limit);
        return false;
    }

    Command command{};
    command.id = next_command_id_++;
    command.kind = kind;
    command.frame = encoded.bytes;
    counters_.transmit_bytes_requested += command.frame.size();
    switch (kind) {
    case CommandKind::version_query: counters_.version_query_write_requested++; break;
    case CommandKind::y_record: counters_.y_write_requested++; break;
    case CommandKind::x_ack: counters_.x0_write_requested++; break;
    }
    pending_writes_.push_back(PendingWrite{command.id, command.kind});
    update.commands.push_back(std::move(command));
    return true;
}

void Session::stop(StopReason reason) noexcept
{
    if (phase_ == Phase::stopped) return;
    phase_ = Phase::stopped;
    stop_reason_ = reason;
    limited_exchange_observed_ = reason == StopReason::deadline &&
        version_response_validated_ && counters_.y_write_completed != 0 &&
        counters_.y_zero_ack_received != 0 && parser_.buffered_bytes() == 0 && pending_writes_.empty();
    pending_writes_.clear();
    parser_.reset();
}

Snapshot Session::make_snapshot() const noexcept
{
    Snapshot result{};
    result.phase = phase_;
    result.stop_reason = stop_reason_;
    result.counters = counters_;
    result.y_template_valid = y_template_valid_;
    result.version_response_validated = version_response_validated_;
    result.y_zero_acknowledged = counters_.y_zero_ack_received != 0;
    result.may_start_audio_route = phase_ != Phase::stopped && result.y_zero_acknowledged;
    result.limited_exchange_observed = limited_exchange_observed_;
    return result;
}

} // namespace wirex::hri_session
