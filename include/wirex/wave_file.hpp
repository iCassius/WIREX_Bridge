#pragma once

#include <cstddef>
#include <cstdint>

namespace wirex::wave_file {

inline constexpr std::uint32_t sample_rate = 48000;
inline constexpr std::uint16_t channels = 1;
inline constexpr std::uint16_t bits_per_sample = 16;
inline constexpr std::uint16_t block_align = 2;
inline constexpr std::size_t max_duration_seconds = 30;
inline constexpr std::size_t max_audio_bytes =
    static_cast<std::size_t>(sample_rate) * block_align * max_duration_seconds;
inline constexpr std::size_t max_metadata_bytes = 65536;
inline constexpr std::size_t max_file_bytes = max_audio_bytes + max_metadata_bytes;

enum class Error {
    none,
    null_input,
    too_small,
    file_too_large,
    invalid_riff,
    riff_size_mismatch,
    malformed_chunk,
    duplicate_format,
    duplicate_data,
    missing_format,
    missing_data,
    unsupported_format,
    invalid_format_fields,
    empty_data,
    data_alignment,
    duration_exceeded,
};

struct Info {
    std::size_t data_offset{0};
    std::size_t data_size{0};
    std::uint32_t rate{0};
    std::uint16_t channel_count{0};
    std::uint16_t sample_bits{0};
    std::uint16_t sample_align{0};
};

struct Result {
    Info info{};
    Error error{Error::too_small};

    [[nodiscard]] explicit operator bool() const noexcept { return error == Error::none; }
};

[[nodiscard]] Result parse(const std::uint8_t* bytes, std::size_t size) noexcept;
[[nodiscard]] const char* error_name(Error error) noexcept;

} // namespace wirex::wave_file
