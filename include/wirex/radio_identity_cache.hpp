#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace wirex::radio_identity_cache {

inline constexpr std::uint32_t max_source_id = 0x00ffffffU;
inline constexpr std::size_t max_callsign_bytes = 10U;
inline constexpr std::size_t max_entries = 128U;
struct EntryView { std::string_view callsign{}; std::uint64_t revision{}; };

enum class UpsertResult {
    inserted,
    updated,
    replayed,
    invalid_source_id,
    invalid_revision,
    invalid_callsign,
    stale_revision,
    revision_conflict,
    removed,
    cleared,
};

/// 缓存最多 128 个正向 DMR ID→呼号映射；单独记录最新一次更新或删除 payload 作为重放栅栏。
/// 姓名、城市和地区字段不会进入 Native。
class Cache final {
public:
    /// 校验长度 1..10 的大写 ASCII 呼号；仅允许 [A-Z0-9/-]，且至少包含一个英文字母。
    [[nodiscard]] static bool is_valid_callsign(std::string_view callsign) noexcept;

    /// revision 在单个 Native run 内全局递增。更高 revision 生效；最新相同 payload 可重放；
    /// 旧 revision 与同 revision 的不同 payload 会被拒绝。满容量时按 LRU 淘汰新 ID 的旧条目。
    [[nodiscard]] UpsertResult upsert(std::uint32_t source_id,
                                      std::uint64_t revision,
                                      std::string_view callsign) noexcept;

    /// 权威 not-found 或无效呼号会删除该 ID 并推进 run revision 栅栏；未知 ID 也会推进栅栏，
    /// 使迟到的旧更新不能恢复过期映射。
    [[nodiscard]] UpsertResult remove(std::uint32_t source_id,
                                     std::uint64_t revision) noexcept;

    /// 查询会刷新 LRU 顺序。返回的 string_view 在对应 ID 被更新、淘汰或清空前有效。
    [[nodiscard]] std::optional<EntryView> find(std::uint32_t source_id) noexcept;

    void clear() noexcept;
    [[nodiscard]] std::size_t size() const noexcept { return size_; }
    [[nodiscard]] std::uint64_t highest_revision() const noexcept { return highest_revision_; }

private:
    struct Entry {
        std::uint32_t source_id{};
        std::array<char, max_callsign_bytes> callsign{};
        std::size_t callsign_size{};
        std::uint64_t revision{};
        std::uint64_t last_used{};
        bool occupied{false};
    };

    [[nodiscard]] std::size_t find_slot(std::uint32_t source_id) const noexcept;
    [[nodiscard]] std::size_t choose_slot() const noexcept;
    void touch(Entry& entry) noexcept;
    void remember_latest(std::uint32_t source_id,
                         std::uint64_t revision,
                         std::string_view callsign,
                         bool has_callsign) noexcept;

    std::array<Entry, max_entries> entries_{};
    std::size_t size_{};
    std::uint64_t recency_clock_{};
    std::uint64_t highest_revision_{};
    std::uint32_t latest_source_id_{};
    bool latest_has_callsign_{};
    std::array<char, max_callsign_bytes> latest_callsign_{};
    std::size_t latest_callsign_size_{};
};

} // namespace wirex::radio_identity_cache
