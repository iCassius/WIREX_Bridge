#pragma once

// 过滤流去重：同一路 BM 流的每个语音包都会返回 Error::filtered，
// 但状态事件与 dev 日志只应记录一次。键包含源/目标/流 ID/时隙/呼叫类型。

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::engine {

struct FilteredStreamKey {
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    std::array<std::uint8_t, 4U> stream_id{};
    std::uint8_t slot{};
    std::uint8_t kind{};

    [[nodiscard]] constexpr bool operator==(const FilteredStreamKey& other) const noexcept
    {
        return source_id == other.source_id && destination_id == other.destination_id &&
               stream_id == other.stream_id && slot == other.slot && kind == other.kind;
    }
};

class FilteredStreamEvidence {
public:
    static constexpr std::size_t capacity = 8U;
    static constexpr std::uint64_t default_window_ms = 30'000U;

    // 首次见到该流（或在窗口外再次出现）返回 true；窗口内重复出现只续期并返回 false。
    [[nodiscard]] bool note(const FilteredStreamKey& key, std::uint64_t now_ms,
                            std::uint64_t window_ms = default_window_ms) noexcept
    {
        for (auto& entry : entries_) {
            if (!entry.valid) continue;
            if (now_ms >= entry.expires_ms) {
                entry.valid = false;
                continue;
            }
            if (entry.key == key) {
                entry.expires_ms = now_ms + window_ms;
                return false;
            }
        }
        entries_[cursor_] = Entry{key, now_ms + window_ms, true};
        cursor_ = (cursor_ + 1U) % capacity;
        return true;
    }

private:
    struct Entry {
        FilteredStreamKey key{};
        std::uint64_t expires_ms{};
        bool valid{};
    };

    std::array<Entry, capacity> entries_{};
    std::size_t cursor_{};
};

} // namespace wirex::engine
