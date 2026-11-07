#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::gui::hri_diagnostics {

inline std::string hex_byte(std::uint8_t value)
{
    constexpr char digits[] = "0123456789ABCDEF";
    return {digits[value >> 4U], digits[value & 0x0FU]};
}

inline std::string offset(std::size_t value)
{
    constexpr char digits[] = "0123456789ABCDEF";
    std::string result;
    do {
        result.push_back(digits[value & 0x0FU]);
        value >>= 4U;
    } while (value != 0U);
    while (result.size() < 2U) result.push_back('0');
    std::reverse(result.begin(), result.end());
    return "0x" + result;
}

inline std::string type_name(std::uint8_t type)
{
    return type >= 0x21U && type <= 0x7EU ? std::string(1, static_cast<char>(type)) : offset(type);
}

template <typename Emit>
void dump(std::uint8_t type, bool tx, const std::vector<std::uint8_t>& body, std::size_t cap, Emit emit)
{
    constexpr std::size_t chunk_size = 80U;
    const auto length = std::min(body.size(), cap);
    for (std::size_t start = 0U; start < length || (start == 0U && length == 0U); start += chunk_size) {
        const auto end = std::min(start + chunk_size, length);
        std::string hex;
        std::string ascii;
        for (auto i = start; i < end; ++i) {
            if (!hex.empty()) hex.push_back(' ');
            hex += hex_byte(body[i]);
            ascii.push_back(body[i] >= 0x20U && body[i] <= 0x7EU ? static_cast<char>(body[i]) : '.');
        }
        emit("dump " + type_name(type) + " dir=" + (tx ? "TX" : "RX") + " n=" +
             std::to_string(body.size()) + " offset=" + offset(start) +
             (length < body.size() ? " capped=256" : "") + " hex=" + hex + " ascii=" + ascii);
        if (length == 0U) break;
    }
}

template <typename Emit>
void emit_parts(std::string_view prefix, const std::vector<std::string>& parts, Emit emit)
{
    std::string line(prefix);
    for (const auto& part : parts) {
        if (line.size() + part.size() + 1U > 400U && line.size() > prefix.size()) {
            emit(line);
            line = std::string(prefix);
        }
        if (line.size() > prefix.size()) line.push_back(',');
        line += part;
    }
    if (line.size() > prefix.size()) emit(line);
}

inline std::vector<std::size_t> changed_offsets(const std::vector<std::uint8_t>& old_body,
                                                 const std::vector<std::uint8_t>& body)
{
    std::vector<std::size_t> result;
    for (std::size_t i = 0U; i < std::max(old_body.size(), body.size()); ++i) {
        if (i >= old_body.size() || i >= body.size() || old_body[i] != body[i]) result.push_back(i);
    }
    return result;
}

class Records {
public:
    void reset() { previous_y_.reset(); previous_x_.reset(); counts_.fill(0U); }

    template <typename Emit, typename Ptt>
    void record(bool tx, std::uint8_t type, const std::vector<std::uint8_t>& body, Emit emit, Ptt ptt)
    {
        if (type == 'Y') {
            if (!tx) return;
            if (!previous_y_ || *previous_y_ != body) {
                if (previous_y_) {
                    const auto changes = changed_offsets(*previous_y_, body);
                    std::vector<std::string> ranges;
                    for (std::size_t i = 0U; i < changes.size();) {
                        const auto first = changes[i];
                        auto last = first;
                        while (++i < changes.size() && changes[i] == last + 1U) last = changes[i];
                        ranges.push_back(offset(first) + (last == first ? "" : "-" + offset(last)));
                    }
                    emit_parts("Y changed=", ranges, emit);
                }
                dump(type, tx, body, body.size(), emit);
            }
            previous_y_ = body;
        } else if (type == 'X') {
            if (tx) return;
            const auto changes = previous_x_ ? changed_offsets(*previous_x_, body) : std::vector<std::size_t>{};
            if (previous_x_ && !changes.empty()) {
                std::vector<std::string> parts;
                for (const auto i : changes) {
                    parts.push_back(offset(i) + ":" + (i < previous_x_->size() ? hex_byte((*previous_x_)[i]) : "--") +
                                    "->" + (i < body.size() ? hex_byte(body[i]) : "--"));
                }
                emit_parts("X diff=", parts, emit);
            }
            const bool interesting = !previous_x_ || std::any_of(changes.begin(), changes.end(),
                [](std::size_t i) { return i >= 0x0BU && i <= 0x0FU; });
            if (interesting) dump(type, tx, body, body.size(), emit);
            previous_x_ = body;
            ptt(body.size() > 0x0CU && body[0x0CU] == '2');
        } else if (type == 'T') {
            dump(type, tx, body, body.size(), emit);
        } else {
            const auto count = ++counts_[type];
            if (count <= 20U) dump(type, tx, body, 256U, emit);
            else emit("count " + type_name(type) + " n=" + std::to_string(count));
        }
    }

private:
    std::optional<std::vector<std::uint8_t>> previous_y_;
    std::optional<std::vector<std::uint8_t>> previous_x_;
    std::array<std::uint64_t, 256U> counts_{};
};

class PttCorrelation {
public:
    using Clock = std::chrono::steady_clock;
    void reset() { pressed_at_.reset(); tx_zero_ = false; warned_ = false; }
    bool ptt(bool pressed, Clock::time_point now)
    {
        if (!pressed) { reset(); return false; }
        if (!pressed_at_) { pressed_at_ = now; tx_zero_ = false; warned_ = false; }
        return check(now);
    }
    bool tick(Clock::time_point now) { return check(now); }
    bool cat(std::string_view frame, Clock::time_point now)
    {
        if (!pressed_at_ || frame.size() != 4U || frame.substr(0U, 2U) != "TX" ||
            frame[2] < '0' || frame[2] > '9' || frame[3] != ';') return false;
        tx_zero_ = frame[2] == '0';
        return check(now);
    }
private:
    bool check(Clock::time_point now)
    {
        if (!warned_ && pressed_at_ && tx_zero_ && now - *pressed_at_ > std::chrono::milliseconds(1500)) {
            warned_ = true;
            return true;
        }
        return false;
    }
    std::optional<Clock::time_point> pressed_at_;
    bool tx_zero_{};
    bool warned_{};
};

} // namespace wirex::gui::hri_diagnostics
