#include "wirex/radio_identity_cache.hpp"

#include <limits>

namespace wirex::radio_identity_cache {

bool Cache::is_valid_callsign(std::string_view callsign) noexcept
{
    if (callsign.empty() || callsign.size() > max_callsign_bytes) return false;

    bool contains_letter = false;
    for (const char value : callsign) {
        const auto byte = static_cast<unsigned char>(value);
        const bool letter = byte >= 'A' && byte <= 'Z';
        const bool digit = byte >= '0' && byte <= '9';
        if (!letter && !digit && byte != '/' && byte != '-') return false;
        if (letter) {
            contains_letter = true;
        }
    }
    return contains_letter;
}

UpsertResult Cache::upsert(std::uint32_t source_id,
                           std::uint64_t revision,
                           std::string_view callsign) noexcept
{
    if (source_id == 0U || source_id > max_source_id) return UpsertResult::invalid_source_id;
    if (revision == 0U) return UpsertResult::invalid_revision;
    if (!is_valid_callsign(callsign)) return UpsertResult::invalid_callsign;

    if (revision < highest_revision_) return UpsertResult::stale_revision;
    if (revision == highest_revision_) {
        return latest_has_callsign_ && latest_source_id_ == source_id &&
                std::string_view(latest_callsign_.data(), latest_callsign_size_) == callsign
            ? UpsertResult::replayed : UpsertResult::revision_conflict;
    }

    std::array<char, max_callsign_bytes> incoming{};
    for (std::size_t index = 0U; index < callsign.size(); ++index) incoming[index] = callsign[index];

    const auto slot = find_slot(source_id);
    const bool is_new = slot == max_entries;
    const auto target = is_new ? choose_slot() : slot;
    auto& entry = entries_[target];
    const bool was_occupied = entry.occupied;
    entry.source_id = source_id;
    entry.callsign = incoming;
    entry.callsign_size = callsign.size();
    entry.revision = revision;
    entry.occupied = true;
    if (!was_occupied) ++size_;
    touch(entry);
    remember_latest(source_id, revision,
        std::string_view(incoming.data(), callsign.size()), true);
    return is_new ? UpsertResult::inserted : UpsertResult::updated;
}

UpsertResult Cache::remove(std::uint32_t source_id, std::uint64_t revision) noexcept
{
    if (source_id == 0U || source_id > max_source_id) return UpsertResult::invalid_source_id;
    if (revision == 0U) return UpsertResult::invalid_revision;

    if (revision < highest_revision_) return UpsertResult::stale_revision;
    if (revision == highest_revision_) {
        return !latest_has_callsign_ && latest_source_id_ == source_id
            ? UpsertResult::replayed : UpsertResult::revision_conflict;
    }

    const auto slot = find_slot(source_id);
    const bool was_present = slot != max_entries;
    if (was_present) {
        entries_[slot] = {};
        --size_;
    }
    remember_latest(source_id, revision, {}, false);
    return was_present ? UpsertResult::removed : UpsertResult::cleared;
}

std::optional<EntryView> Cache::find(std::uint32_t source_id) noexcept
{
    if (source_id == 0U || source_id > max_source_id) return std::nullopt;
    const auto slot = find_slot(source_id);
    if (slot == max_entries) return std::nullopt;
    auto& entry = entries_[slot];
    touch(entry);
    return EntryView{std::string_view(entry.callsign.data(), entry.callsign_size), entry.revision};
}

void Cache::clear() noexcept
{
    entries_ = {};
    size_ = 0U;
    recency_clock_ = 0U;
    highest_revision_ = 0U;
    latest_source_id_ = 0U;
    latest_has_callsign_ = false;
    latest_callsign_.fill('\0');
    latest_callsign_size_ = 0U;
}

std::size_t Cache::find_slot(std::uint32_t source_id) const noexcept
{
    for (std::size_t index = 0U; index < entries_.size(); ++index) {
        if (entries_[index].occupied && entries_[index].source_id == source_id) return index;
    }
    return max_entries;
}

std::size_t Cache::choose_slot() const noexcept
{
    for (std::size_t index = 0U; index < entries_.size(); ++index) {
        if (!entries_[index].occupied) return index;
    }

    std::size_t oldest = 0U;
    for (std::size_t index = 1U; index < entries_.size(); ++index) {
        if (entries_[index].last_used < entries_[oldest].last_used) oldest = index;
    }
    return oldest;
}

void Cache::touch(Entry& entry) noexcept
{
    if (recency_clock_ == std::numeric_limits<std::uint64_t>::max()) {
        // 将最多128条记录按旧顺序重新编号，避免计数器回绕改变淘汰顺序。
        std::array<bool, max_entries> ranked{};
        std::uint64_t rank = 0U;
        for (std::size_t step = 0U; step < size_; ++step) {
            std::size_t oldest = max_entries;
            for (std::size_t index = 0U; index < entries_.size(); ++index) {
                if (!entries_[index].occupied || ranked[index]) continue;
                if (oldest == max_entries || entries_[index].last_used < entries_[oldest].last_used) {
                    oldest = index;
                }
            }
            if (oldest == max_entries) break;
            ranked[oldest] = true;
            entries_[oldest].last_used = ++rank;
        }
        recency_clock_ = rank;
    }
    entry.last_used = ++recency_clock_;
}

void Cache::remember_latest(std::uint32_t source_id,
                            std::uint64_t revision,
                            std::string_view callsign,
                            bool has_callsign) noexcept
{
    highest_revision_ = revision;
    latest_source_id_ = source_id;
    latest_has_callsign_ = has_callsign;
    latest_callsign_.fill('\0');
    for (std::size_t index = 0U; index < callsign.size(); ++index) {
        latest_callsign_[index] = callsign[index];
    }
    latest_callsign_size_ = has_callsign ? callsign.size() : 0U;
}

} // namespace wirex::radio_identity_cache
