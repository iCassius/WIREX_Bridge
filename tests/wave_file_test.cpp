#include "wirex/wave_file.hpp"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const char* message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

const std::vector<std::uint8_t> golden_wav{
    'R','I','F','F', 0x28,0x00,0x00,0x00, 'W','A','V','E',
    'f','m','t',' ', 0x10,0x00,0x00,0x00, 0x01,0x00, 0x01,0x00,
    0x80,0xBB,0x00,0x00, 0x00,0x77,0x01,0x00, 0x02,0x00, 0x10,0x00,
    'd','a','t','a', 0x04,0x00,0x00,0x00, 0x00,0x80,0xFF,0x7F
};

void write_u32_le(std::vector<std::uint8_t>& bytes, std::size_t offset, std::uint32_t value)
{
    for (unsigned shift = 0; shift < 32; shift += 8) {
        bytes[offset + shift / 8] = static_cast<std::uint8_t>(value >> shift);
    }
}

void write_u16_le(std::vector<std::uint8_t>& bytes, std::size_t offset, std::uint16_t value)
{
    bytes[offset] = static_cast<std::uint8_t>(value);
    bytes[offset + 1] = static_cast<std::uint8_t>(value >> 8U);
}

std::vector<std::uint8_t> make_pcm_file(std::size_t data_size)
{
    const auto padding = data_size & 1U;
    const auto riff_size = static_cast<std::uint32_t>(4 + 24 + 8 + data_size + padding);
    std::vector<std::uint8_t> bytes{
        'R','I','F','F', 0,0,0,0, 'W','A','V','E',
        'f','m','t',' ', 0x10,0x00,0x00,0x00, 0x01,0x00, 0x01,0x00,
        0x80,0xBB,0x00,0x00, 0x00,0x77,0x01,0x00, 0x02,0x00, 0x10,0x00,
        'd','a','t','a', 0,0,0,0
    };
    write_u32_le(bytes, 4, riff_size);
    write_u32_le(bytes, 40, static_cast<std::uint32_t>(data_size));
    bytes.resize(bytes.size() + data_size + padding, 0);
    return bytes;
}

void test_fixed_golden_vector_and_odd_unknown_chunk()
{
    auto parsed = wirex::wave_file::parse(golden_wav.data(), golden_wav.size());
    check(static_cast<bool>(parsed), "fixed independent RIFF/WAVE vector should parse");
    check(parsed.info.data_offset == 44 && parsed.info.data_size == 4, "fixed vector data bounds should match literal offsets");
    check(parsed.info.rate == 48000 && parsed.info.channel_count == 1 && parsed.info.sample_bits == 16,
        "fixed vector PCM format should match the accepted format");

    auto with_odd_junk = golden_wav;
    const std::vector<std::uint8_t> junk{'J','U','N','K', 3,0,0,0, 'a','b','c',0};
    with_odd_junk.insert(with_odd_junk.begin() + 36, junk.begin(), junk.end());
    write_u32_le(with_odd_junk, 4, 52);
    parsed = wirex::wave_file::parse(with_odd_junk.data(), with_odd_junk.size());
    check(static_cast<bool>(parsed), "odd-sized unknown chunk and padding should be skipped");
    check(parsed.info.data_offset == 56 && parsed.info.data_size == 4, "data offset should follow the padded unknown chunk");

    auto oversized_metadata = golden_wav;
    std::vector<std::uint8_t> large_junk{'J','U','N','K', 0,0,1,0};
    large_junk.resize(8 + 65536, 0);
    oversized_metadata.insert(oversized_metadata.begin() + 36, large_junk.begin(), large_junk.end());
    write_u32_le(oversized_metadata, 4, static_cast<std::uint32_t>(oversized_metadata.size() - 8));
    parsed = wirex::wave_file::parse(oversized_metadata.data(), oversized_metadata.size());
    check(parsed.error == wirex::wave_file::Error::file_too_large,
        "metadata overhead above 64 KiB must be rejected even when the whole file is under the global cap");
}

void test_truncation_and_chunk_bounds()
{
    using wirex::wave_file::Error;
    auto truncated = golden_wav;
    truncated.pop_back();
    auto parsed = wirex::wave_file::parse(truncated.data(), truncated.size());
    check(parsed.error == Error::riff_size_mismatch, "truncated file must fail exact RIFF size check");

    auto bad_chunk = golden_wav;
    write_u32_le(bad_chunk, 40, 0xffffffffU);
    parsed = wirex::wave_file::parse(bad_chunk.data(), bad_chunk.size());
    check(parsed.error == Error::malformed_chunk, "chunk length beyond RIFF boundary must be rejected");

    auto odd_data = golden_wav;
    write_u32_le(odd_data, 40, 3);
    parsed = wirex::wave_file::parse(odd_data.data(), odd_data.size());
    check(parsed.error == Error::data_alignment, "odd data size must be rejected for 16-bit PCM");

    auto trailing = golden_wav;
    trailing.push_back(0);
    parsed = wirex::wave_file::parse(trailing.data(), trailing.size());
    check(parsed.error == Error::riff_size_mismatch, "bytes beyond declared RIFF size must be rejected");
}

void test_format_and_duration_limits()
{
    using wirex::wave_file::Error;
    auto unsupported = golden_wav;
    write_u16_le(unsupported, 20, 3);
    auto parsed = wirex::wave_file::parse(unsupported.data(), unsupported.size());
    check(parsed.error == Error::unsupported_format, "non-PCM encoding must be rejected");

    unsupported = golden_wav;
    write_u32_le(unsupported, 24, 44100);
    parsed = wirex::wave_file::parse(unsupported.data(), unsupported.size());
    check(parsed.error == Error::invalid_format_fields, "44.1 kHz PCM must be rejected without resampling");

    auto over_30_seconds = make_pcm_file(wirex::wave_file::max_audio_bytes + 2);
    parsed = wirex::wave_file::parse(over_30_seconds.data(), over_30_seconds.size());
    check(parsed.error == Error::duration_exceeded, "PCM data longer than 30 seconds must be rejected");

    std::vector<std::uint8_t> over_file_limit(wirex::wave_file::max_file_bytes + 1, 0);
    parsed = wirex::wave_file::parse(over_file_limit.data(), over_file_limit.size());
    check(parsed.error == Error::file_too_large, "file larger than the configured strict limit must be rejected");
}

} // 匿名命名空间

int main()
{
    test_fixed_golden_vector_and_odd_unknown_chunk();
    test_truncation_and_chunk_bounds();
    test_format_and_duration_limits();
    if (failures != 0) return 1;
    std::cout << "All WAV parser checks passed.\n";
    return 0;
}
