#include "wirex/hri_ptt_gate.hpp"

namespace wirex::hri_ptt_gate {

Action Gate::set_ready(bool ready) noexcept
{
    if (ready_ == ready) return Action::none;
    ready_ = ready;
    armed_ = false;
    call_timer_started_ = false;
    call_started_ms_ = 0U;
    if (!ready && tx_active_) {
        tx_active_ = false;
        return Action::abort_tx;
    }
    return Action::none;
}

Action Gate::observe(Level level, bool tx_start_permitted) noexcept
{
    if (level == Level::unknown) {
        armed_ = false;
        pressed_latched_ = false;
        call_timer_started_ = false;
        call_started_ms_ = 0U;
        if (tx_active_) {
            tx_active_ = false;
            return Action::abort_tx;
        }
        return Action::none;
    }

    if (!ready_) {
        pressed_latched_ = level == Level::pressed;
        armed_ = false;
        return Action::none;
    }

    if (level == Level::released) {
        pressed_latched_ = false;
        armed_ = true;
        call_timer_started_ = false;
        call_started_ms_ = 0U;
        if (tx_active_) {
            tx_active_ = false;
            return Action::end_tx;
        }
        return Action::none;
    }

    if (pressed_latched_) return Action::none;
    pressed_latched_ = true;
    if (!armed_) return Action::none;
    armed_ = false;
    if (!tx_start_permitted) return Action::none;
    tx_active_ = true;
    return Action::start_tx;
}

bool Gate::start_succeeded(std::uint64_t now_ms) noexcept
{
    if (!tx_active_ || call_timer_started_) return false;
    call_timer_started_ = true;
    call_started_ms_ = now_ms;
    return true;
}

Action Gate::tick(std::uint64_t now_ms) noexcept
{
    if (!tx_active_ || !call_timer_started_) return Action::none;
    if (now_ms < call_started_ms_) {
        tx_active_ = false;
        armed_ = false;
        pressed_latched_ = true;
        call_timer_started_ = false;
        call_started_ms_ = 0U;
        return Action::abort_tx;
    }
    if (now_ms - call_started_ms_ < max_call_duration_ms) return Action::none;
    tx_active_ = false;
    armed_ = false;
    pressed_latched_ = true;
    call_timer_started_ = false;
    call_started_ms_ = 0U;
    return Action::call_timeout;
}

void Gate::start_failed() noexcept
{
    tx_active_ = false;
    armed_ = false;
    pressed_latched_ = true;
    call_timer_started_ = false;
    call_started_ms_ = 0U;
}

void Gate::disarm_until_release() noexcept
{
    tx_active_ = false;
    armed_ = false;
    pressed_latched_ = true;
    call_timer_started_ = false;
    call_started_ms_ = 0U;
}

Snapshot Gate::snapshot() const noexcept
{
    return Snapshot{ready_, armed_, pressed_latched_, tx_active_};
}

} // namespace wirex::hri_ptt_gate
