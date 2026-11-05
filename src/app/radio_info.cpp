#include "wirex/app/radio_info.hpp"

namespace wirex::app::radio_info {

namespace {

constexpr std::size_t answer_length = 11U;  // R I P1 P2 P3 P4 P5 P6 P7 P8 ;

bool digit_in(char c, char max) noexcept { return c >= '0' && c <= max; }

} // namespace

std::optional<RadioInfo> parse(std::string_view answer) noexcept
{
    if (answer.size() != answer_length || answer[0] != 'R' || answer[1] != 'I' || answer[10] != ';') {
        return std::nullopt;
    }
    const char p1 = answer[2], p2 = answer[3], p3 = answer[4], p4 = answer[5];
    const char p5 = answer[6], p6 = answer[7], p7 = answer[8], p8 = answer[9];
    if (p1 != '0' || p5 != '0' || !digit_in(p2, '1') || !digit_in(p3, '2') || !digit_in(p4, '2') ||
        !digit_in(p6, '1') || !digit_in(p7, '2') || !digit_in(p8, '1')) {
        return std::nullopt;
    }
    RadioInfo info{};
    info.hi_swr = p2 == '1';
    info.playback = static_cast<unsigned char>(p3 - '0');
    info.tx = p4 == '0' ? TxState::rx : (p4 == '1' ? TxState::tx : TxState::tx_inhibit);
    info.tuning = p6 == '1';
    info.scan = p7 == '0' ? ScanState::stopped : (p7 == '1' ? ScanState::scanning : ScanState::paused);
    info.squelch_open = p8 == '1';
    return info;
}

GateEvent SquelchGate::close_gate() noexcept
{
    consecutive_open_ = 0U;
    closed_since_.reset();
    if (!open_) return GateEvent::none;
    open_ = false;
    return GateEvent::closed;
}

void SquelchGate::reset() noexcept
{
    open_ = false;
    consecutive_open_ = 0U;
    closed_since_.reset();
    last_good_sample_.reset();
}

GateEvent SquelchGate::sample(const std::optional<RadioInfo>& info, Clock::time_point now) noexcept
{
    if (!info) return tick(now);
    last_good_sample_ = now;
    if (info->tx != TxState::rx) return close_gate();  // 电台在发射：不是来话
    if (info->squelch_open) {
        closed_since_.reset();
        if (open_) return GateEvent::none;
        if (++consecutive_open_ >= config_.open_samples) {
            open_ = true;
            consecutive_open_ = 0U;
            return GateEvent::opened;
        }
        return GateEvent::none;
    }
    consecutive_open_ = 0U;
    if (!open_) return GateEvent::none;
    if (!closed_since_) closed_since_ = now;
    if (now - *closed_since_ >= config_.hang) return close_gate();
    return GateEvent::none;
}

GateEvent SquelchGate::tick(Clock::time_point now) noexcept
{
    if (!open_) return GateEvent::none;
    if (!last_good_sample_ || now - *last_good_sample_ >= config_.stale) return close_gate();
    if (closed_since_ && now - *closed_since_ >= config_.hang) return close_gate();
    return GateEvent::none;
}

} // namespace wirex::app::radio_info
