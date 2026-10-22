#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"

#include <cstdint>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

wirex::direct_frame::Record record(std::uint8_t type, std::vector<std::uint8_t> payload)
{
    return {type, std::move(payload)};
}

std::vector<std::uint8_t> encode_bytes(const wirex::direct_frame::Record& value)
{
    const auto encoded = wirex::direct_frame::encode(value);
    check(static_cast<bool>(encoded), "test record should encode");
    return encoded.bytes;
}

void append(std::vector<std::uint8_t>& destination, const std::vector<std::uint8_t>& source)
{
    destination.insert(destination.end(), source.begin(), source.end());
}

void test_split_and_merge()
{
    using wirex::direct_stream::Parser;
    const auto a = encode_bytes(record('V', {}));
    const auto b = encode_bytes(record('Q', {0x00, 0x01, 0x04, 0xFE, 0x04}));
    Parser parser;
    std::vector<wirex::direct_stream::Event> events;

    auto first = parser.feed(a.data(), 2);
    events.insert(events.end(), first.events.begin(), first.events.end());
    check(events.empty(), "partial header must not emit an event");
    auto second = parser.feed(a.data() + 2, a.size() - 2);
    events.insert(events.end(), second.events.begin(), second.events.end());
    check(events.size() == 1 && events[0].has_record, "segmented V record should decode");
    if (!events.empty() && events[0].has_record) {
        check(events[0].record.type == 'V' && events[0].record.payload.empty(), "V record fields should match");
    }

    std::vector<std::uint8_t> joined = b;
    append(joined, a);
    auto merged = parser.feed(joined.data(), joined.size());
    check(merged.events.size() == 2, "merged records should emit two events");
    if (merged.events.size() == 2) {
        check(merged.events[0].has_record && merged.events[1].has_record, "both merged records should be valid");
        check(merged.events[0].record.payload == std::vector<std::uint8_t>({0, 1, 4, 0xFE, 4}), "embedded SOH/EOT bytes must remain payload");
    }
    check(parser.buffered_bytes() == 0, "parser should be empty after complete records");
}

void test_bad_checksum_and_oversize()
{
    using wirex::direct_stream::Error;
    using wirex::direct_stream::Parser;
    auto bad = encode_bytes(record('V', {}));
    bad.back() = bad.back() == '0' ? '1' : '0';
    Parser parser;
    auto rejected = parser.feed(bad.data(), bad.size());
    check(rejected.events.size() == 1 && !rejected.events[0].has_record, "bad checksum must be rejected");

    Parser bounded(4);
    const auto too_large = encode_bytes(record('Q', {1, 2, 3, 4, 5}));
    auto dropped = bounded.feed(too_large.data(), too_large.size());
    check(dropped.events.size() == 1 && dropped.events[0].error == Error::payload_too_large, "configured payload cap must reject oversized frame");
    check(bounded.buffered_bytes() == 0, "oversized record must not remain buffered");

    std::vector<std::uint8_t> after_oversize = too_large;
    const auto valid = encode_bytes(record('V', {}));
    append(after_oversize, valid);
    auto recovered = bounded.feed(after_oversize.data(), after_oversize.size());
    check(recovered.events.size() == 2 && !recovered.events[0].has_record && recovered.events[0].error == Error::payload_too_large,
        "oversized payload must be skipped by its declared length");
    check(recovered.events.size() == 2 && recovered.events[1].has_record, "parser should resume after oversized record boundary");
}

void test_gap_reset_and_reuse()
{
    using wirex::direct_stream::Parser;
    const auto expected = encode_bytes(record('V', {}));
    Parser parser;
    auto prefix = parser.feed(expected.data(), 5);
    check(prefix.events.empty() && parser.buffered_bytes() == 5, "prefix should remain pending before a gap");

    parser.reset(); // I/O 层遇到失败、重叠传输或完成字节数未知时重置。
    auto suffix = parser.feed(expected.data() + 5, expected.size() - 5);
    check(suffix.events.empty(), "bytes after a gap must not complete the previous prefix");
    check(parser.buffered_bytes() == 0, "suffix without SOH must not be buffered");

    auto recovered = parser.feed(expected.data(), expected.size());
    check(recovered.events.size() == 1 && recovered.events[0].has_record, "parser must accept a fresh complete V after a gap");
}

} // 匿名命名空间

int main()
{
    test_split_and_merge();
    test_bad_checksum_and_oversize();
    test_gap_reset_and_reuse();
    if (failures != 0) return 1;
    std::cout << "All DIRECT stream checks passed.\n";
    return 0;
}
