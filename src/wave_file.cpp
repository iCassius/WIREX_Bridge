#include "wirex/wave_file.hpp"

#include <cstring>

namespace wirex::wave_file {
namespace {

std::uint16_t read_u16_le(const std::uint8_t* bytes) noexcept
{
    return static_cast<std::uint16_t>(bytes[0]) |
        static_cast<std::uint16_t>(static_cast<std::uint16_t>(bytes[1]) << 8U);
}

std::uint32_t read_u32_le(const std::uint8_t* bytes) noexcept
{
    return static_cast<std::uint32_t>(bytes[0]) |
        (static_cast<std::uint32_t>(bytes[1]) << 8U) |
        (static_cast<std::uint32_t>(bytes[2]) << 16U) |
        (static_cast<std::uint32_t>(bytes[3]) << 24U);
}

bool is_id(const std::uint8_t* bytes, const char (&id)[5]) noexcept
{
    return std::memcmp(bytes, id, 4) == 0;
}

} // 匿名命名空间

Result parse(const std::uint8_t* bytes, std::size_t size) noexcept
{
    if (bytes == nullptr && size != 0) return {{}, Error::null_input};
    if (size < 12) return {{}, Error::too_small};
    if (size > max_file_bytes) return {{}, Error::file_too_large};
    if (!is_id(bytes, "RIFF") || !is_id(bytes + 8, "WAVE")) return {{}, Error::invalid_riff};

    const auto riff_size = static_cast<std::size_t>(read_u32_le(bytes + 4));
    if (riff_size < 4 || riff_size > size - 8 || riff_size + 8 != size) {
        return {{}, Error::riff_size_mismatch};
    }

    const std::size_t riff_end = size;
    std::size_t offset = 12;
    bool have_format = false;
    bool have_data = false;
    Info info{};

    while (offset < riff_end) {
        if (riff_end - offset < 8) return {{}, Error::malformed_chunk};
        const auto chunk_size = static_cast<std::size_t>(read_u32_le(bytes + offset + 4));
        const std::size_t body_offset = offset + 8;
        const std::size_t remaining = riff_end - body_offset;
        if (chunk_size > remaining) return {{}, Error::malformed_chunk};
        const std::size_t padded_size = chunk_size + (chunk_size & 1U);
        if (padded_size > remaining) return {{}, Error::malformed_chunk};

        if (is_id(bytes + offset, "fmt ")) {
            if (have_format) return {{}, Error::duplicate_format};
            if (chunk_size != 16 && chunk_size != 18) return {{}, Error::unsupported_format};
            const auto* format = bytes + body_offset;
            const auto tag = read_u16_le(format);
            info.channel_count = read_u16_le(format + 2);
            info.rate = read_u32_le(format + 4);
            const auto average_bytes_per_second = read_u32_le(format + 8);
            info.sample_align = read_u16_le(format + 12);
            info.sample_bits = read_u16_le(format + 14);
            if (chunk_size == 18 && read_u16_le(format + 16) != 0) {
                return {{}, Error::unsupported_format};
            }
            if (tag != 1) return {{}, Error::unsupported_format};
            const auto expected_average = info.rate * info.sample_align;
            if (info.channel_count != channels || info.rate != sample_rate ||
                info.sample_align != block_align || info.sample_bits != bits_per_sample ||
                average_bytes_per_second != expected_average) {
                return {{}, Error::invalid_format_fields};
            }
            have_format = true;
        } else if (is_id(bytes + offset, "data")) {
            if (!have_format) return {{}, Error::missing_format};
            if (have_data) return {{}, Error::duplicate_data};
            if (chunk_size == 0) return {{}, Error::empty_data};
            if (chunk_size % block_align != 0) return {{}, Error::data_alignment};
            if (chunk_size > max_audio_bytes) return {{}, Error::duration_exceeded};
            info.data_offset = body_offset;
            info.data_size = chunk_size;
            have_data = true;
        }

        offset = body_offset + padded_size;
    }

    if (!have_format) return {{}, Error::missing_format};
    if (!have_data) return {{}, Error::missing_data};
    if (size - info.data_size > max_metadata_bytes) return {{}, Error::file_too_large};
    return {info, Error::none};
}

const char* error_name(Error error) noexcept
{
    switch (error) {
    case Error::none: return "none";
    case Error::null_input: return "null input";
    case Error::too_small: return "file is too small for RIFF/WAVE";
    case Error::file_too_large: return "file exceeds the configured size limit";
    case Error::invalid_riff: return "RIFF/WAVE signature is invalid";
    case Error::riff_size_mismatch: return "RIFF size does not exactly match the file size";
    case Error::malformed_chunk: return "chunk length or padding exceeds the RIFF boundary";
    case Error::duplicate_format: return "multiple fmt chunks are not supported";
    case Error::duplicate_data: return "multiple data chunks are not supported";
    case Error::missing_format: return "fmt chunk is missing";
    case Error::missing_data: return "data chunk is missing";
    case Error::unsupported_format: return "only integer PCM with a standard fmt chunk is supported";
    case Error::invalid_format_fields: return "format must be 48000 Hz mono signed 16-bit PCM with matching alignment";
    case Error::empty_data: return "data chunk is empty";
    case Error::data_alignment: return "data size is not aligned to a complete PCM sample";
    case Error::duration_exceeded: return "PCM data exceeds 30 seconds";
    }
    return "unknown WAV error";
}

} // namespace wirex::wave_file
