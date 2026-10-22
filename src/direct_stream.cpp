#include "wirex/direct_stream.hpp"

#include <algorithm>
#include <limits>
#include <utility>

namespace wirex::direct_stream {
namespace {

constexpr std::uint8_t soh = 0x01;

int parse_upper_hex(std::uint8_t value) noexcept
{
    if (value >= '0' && value <= '9') {
        return static_cast<int>(value - '0');
    }
    if (value >= 'A' && value <= 'F') {
        return static_cast<int>(value - 'A') + 10;
    }
    return -1;
}

std::size_t declared_payload(const std::vector<std::uint8_t>& frame, bool& valid) noexcept
{
    std::size_t payload = 0;
    valid = frame.size() >= 6;
    if (!valid) return 0;
    for (std::size_t i = 2; i < 6; ++i) {
        const int digit = parse_upper_hex(frame[i]);
        if (digit < 0) {
            valid = false;
            return 0;
        }
        payload = (payload << 4U) | static_cast<std::size_t>(digit);
    }
    return payload;
}

} // 匿名命名空间

Parser::Parser(std::size_t max_payload_size)
    : max_payload_size_(std::min(max_payload_size, direct_frame::max_payload_size))
{
    frame_.reserve(direct_frame::fixed_overhead + max_payload_size_);
}

FeedResult Parser::feed(const std::uint8_t* bytes, std::size_t size)
{
    FeedResult result{};
    if (bytes == nullptr && size != 0) {
        reset();
        result.events.push_back(Event{{}, Error::null_input, false});
        return result;
    }

    for (std::size_t i = 0; i < size; ++i) {
        consume(bytes[i], result);
    }
    return result;
}

void Parser::consume(std::uint8_t byte, FeedResult& result)
{
    if (discard_remaining_ != 0) {
        --discard_remaining_;
        return;
    }

    if (frame_.empty()) {
        if (byte == soh) frame_.push_back(byte);
        return;
    }

    frame_.push_back(byte);
    if (frame_.size() == 6) {
        bool valid_length = false;
        const auto payload_size = declared_payload(frame_, valid_length);
        if (!valid_length) {
            result.events.push_back(Event{{}, Error::invalid_length, false});
            reset();
            if (byte == soh) frame_.push_back(soh);
            return;
        }
        if (payload_size > max_payload_size_ ||
            payload_size > std::numeric_limits<std::size_t>::max() - direct_frame::fixed_overhead) {
            result.events.push_back(Event{{}, Error::payload_too_large, false});
            frame_.clear();
            expected_size_ = 0;
            discard_remaining_ = payload_size + 3; // 跳过正文、EOT 和两个校验 ASCII 字节。
            return;
        }
        expected_size_ = direct_frame::fixed_overhead + payload_size;
        frame_.reserve(expected_size_);
    }

    if (expected_size_ == 0 || frame_.size() < expected_size_) return;
    if (frame_.size() > expected_size_) {
        result.events.push_back(Event{{}, Error::invalid_record, false});
        reset();
        if (byte == soh) frame_.push_back(soh);
        return;
    }

    auto decoded = direct_frame::decode(frame_.data(), frame_.size());
    if (decoded) {
        result.events.push_back(Event{std::move(decoded.record), Error::none, true});
    } else {
        result.events.push_back(Event{{}, Error::invalid_record, false});
    }
    reset();
}

void Parser::reset() noexcept
{
    frame_.clear();
    expected_size_ = 0;
    discard_remaining_ = 0;
}

std::size_t Parser::buffered_bytes() const noexcept
{
    return frame_.size();
}

std::size_t Parser::max_payload_size() const noexcept
{
    return max_payload_size_;
}

} // namespace wirex::direct_stream
