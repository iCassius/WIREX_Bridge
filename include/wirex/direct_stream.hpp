#pragma once

#include "wirex/direct_frame.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wirex::direct_stream {

enum class Error {
    none,
    null_input,
    invalid_length,
    payload_too_large,
    invalid_record,
};

struct Event {
    direct_frame::Record record{};
    Error error{Error::invalid_record};
    bool has_record{false};
};

struct FeedResult {
    std::vector<Event> events;
};

class Parser {
public:
    explicit Parser(std::size_t max_payload_size = direct_frame::max_payload_size);

    [[nodiscard]] FeedResult feed(const std::uint8_t* bytes, std::size_t size);

    // I/O 出现间断或完成字节数未知时调用；下条记录必须从 SOH 开始。
    void reset() noexcept;

    [[nodiscard]] std::size_t buffered_bytes() const noexcept;
    [[nodiscard]] std::size_t max_payload_size() const noexcept;

private:
    std::size_t max_payload_size_;
    std::vector<std::uint8_t> frame_;
    std::size_t expected_size_{0};
    std::size_t discard_remaining_{0};

    void consume(std::uint8_t byte, FeedResult& result);
};

} // namespace wirex::direct_stream
