#include "wirex/radio_identity_cache.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void test_callsign_validation()
{
    using wirex::radio_identity_cache::Cache;
    check(Cache::is_valid_callsign("N0CALL"), "a typical ASCII callsign is accepted");
    check(Cache::is_valid_callsign("N0CALL/P"), "a slash suffix is accepted as printable ASCII");
    check(Cache::is_valid_callsign("A123456789"), "a ten-byte callsign is accepted without truncation");
    check(!Cache::is_valid_callsign("n0call"), "lowercase callsigns are rejected and must be normalized by the UI");
    check(!Cache::is_valid_callsign(""), "an empty callsign is rejected");
    check(!Cache::is_valid_callsign("1234567890"), "an ID-like value with no letters is rejected");
    check(!Cache::is_valid_callsign("A1234567890"), "callsigns over ten bytes are rejected");
    check(!Cache::is_valid_callsign("N0 CALL"), "spaces are rejected before fixed-width padding");
    check(!Cache::is_valid_callsign(std::string("A\x80", 2U)), "non-ASCII bytes are rejected");
    check(!Cache::is_valid_callsign(std::string("A\x1f", 2U)), "control bytes are rejected");
    check(!Cache::is_valid_callsign("N0CALL\\X"), "backslashes are rejected so report JSON stays valid");
    check(!Cache::is_valid_callsign("N0CALL\""), "quotation marks are rejected so report JSON stays valid");
}

void test_source_id_boundaries_and_upsert()
{
    using namespace wirex::radio_identity_cache;
    Cache cache;
    check(cache.upsert(1U, 1U, "N0CALL") == UpsertResult::inserted,
          "source ID 1 creates one cache entry");
    check(cache.find(1U).has_value() && cache.find(1U)->callsign == "N0CALL" &&
              cache.find(1U)->revision == 1U && cache.size() == 1U,
          "lookup returns the exact mapped callsign");
    check(cache.upsert(max_source_id, 2U, "A123456789") == UpsertResult::inserted,
          "the maximum 24-bit DMR source ID is accepted");
    check(cache.find(max_source_id).has_value() && cache.find(max_source_id)->callsign == "A123456789",
          "the maximum ID keeps all ten callsign bytes");
    check(cache.upsert(0U, 1U, "N0CALL") == UpsertResult::invalid_source_id,
          "source ID zero is rejected");
    check(cache.upsert(max_source_id + 1U, 1U, "N0CALL") == UpsertResult::invalid_source_id,
          "source IDs above 24 bits are rejected");
    check(cache.upsert(1U, 0U, "N0CALL") == UpsertResult::invalid_revision,
          "revision zero is rejected");
    check(cache.upsert(1U, 3U, "W1ABC") == UpsertResult::updated,
          "the global revision can advance across intervening IDs");
    check(cache.upsert(1U, 3U, "W1ABC") == UpsertResult::replayed,
          "the latest identical payload is an idempotent replay");
    check(cache.upsert(2U, 3U, "W1ABC") == UpsertResult::revision_conflict,
          "the latest revision cannot be reused for another source ID");
    check(cache.upsert(1U, 2U, "N0CALL") == UpsertResult::stale_revision,
          "an older global revision cannot replace a newer identity");
    check(cache.upsert(1U, 4U, "W1ABC") == UpsertResult::updated && cache.size() == 2U &&
              cache.highest_revision() == 4U,
          "a higher global revision refreshes the existing ID");
    check(cache.find(1U)->revision == 4U,
          "the selected identity record carries the revision that supplied its mapping");
    const auto existing_view = cache.find(1U);
    check(existing_view.has_value() &&
              cache.upsert(1U, 5U, existing_view->callsign) == UpsertResult::updated &&
              cache.find(1U)->callsign == "W1ABC",
          "a lookup view can safely supply a later revision for the same cache entry");
    check(cache.upsert(2U, 1U, "4609999") == UpsertResult::invalid_callsign,
          "a numeric source ID cannot be stored as a callsign");
    check(cache.remove(1U, 6U) == UpsertResult::removed && !cache.find(1U).has_value() &&
              cache.size() == 1U,
          "an authoritative negative result removes the selected source mapping");
    check(cache.remove(1U, 6U) == UpsertResult::replayed,
          "the latest null payload is an idempotent deletion replay");
    check(cache.upsert(1U, 6U, "N0CALL") == UpsertResult::revision_conflict,
          "the same revision cannot change a deletion into a mapping");
    check(cache.upsert(1U, 5U, "W1ABC") == UpsertResult::stale_revision &&
              !cache.find(1U).has_value(),
          "an older delayed positive result cannot restore a deleted mapping");
    check(cache.remove(12345U, 7U) == UpsertResult::cleared && cache.highest_revision() == 7U &&
              cache.size() == 1U,
          "deleting an unknown ID advances the revision fence without using a cache slot");
    check(cache.upsert(12345U, 7U, "K2XYZ") == UpsertResult::revision_conflict &&
              cache.upsert(12345U, 6U, "K2XYZ") == UpsertResult::stale_revision,
          "older IPC cannot restore an ID cleared while it was absent from the LRU");
    check(cache.upsert(1U, 8U, "W1ABC") == UpsertResult::inserted &&
              cache.find(1U)->callsign == "W1ABC",
          "a later authoritative positive result can add the source again");
}

void test_capacity_uses_lru_and_revision_fence()
{
    using namespace wirex::radio_identity_cache;
    Cache cache;
    for (std::uint32_t id = 1U; id <= static_cast<std::uint32_t>(max_entries); ++id) {
        check(cache.upsert(id, id, "N0CALL") == UpsertResult::inserted,
              "each of 128 unique IDs fits the bounded cache");
    }
    check(cache.size() == max_entries, "cache size stops at its declared bound");
    check(cache.find(1U).has_value(), "a lookup refreshes source ID 1 recency");
    check(cache.upsert(static_cast<std::uint32_t>(max_entries + 1U), max_entries + 1U, "K2XYZ") ==
              UpsertResult::inserted,
          "a new ID replaces the least recently used entry at capacity");
    check(cache.size() == max_entries && cache.find(1U).has_value() &&
              !cache.find(2U).has_value() &&
              cache.find(static_cast<std::uint32_t>(max_entries + 1U)).has_value(),
          "LRU eviction preserves the recently used ID and the new mapping");
    check(cache.upsert(2U, 2U, "N0CALL") == UpsertResult::stale_revision,
          "an evicted identity cannot be reinserted by a late old result");
    check(cache.upsert(2U, max_entries + 2U, "N0CALL") == UpsertResult::inserted,
          "an evicted ID can return with a newer run revision");
    cache.clear();
    check(cache.size() == 0U && !cache.find(1U).has_value(), "clear removes run-local identity state");
    check(cache.highest_revision() == 0U, "clear resets the run-local revision fence");
}

} // namespace

int main()
{
    test_callsign_validation();
    test_source_id_boundaries_and_upsert();
    test_capacity_uses_lru_and_revision_fence();
    std::cout << "All offline radio identity cache checks passed.\n";
    return EXIT_SUCCESS;
}
