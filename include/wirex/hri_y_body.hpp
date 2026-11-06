#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace wirex::hri_y {

inline constexpr std::size_t body_size = 100U;
inline constexpr std::size_t mode_offset = 0x05U;
inline constexpr std::size_t ptt_mirror_offset = 0x0CU;
inline constexpr std::size_t tx_power_offset = 0x2FU;
inline constexpr std::size_t tx_power_length = 4U;
inline constexpr std::uint16_t min_tx_power_deciwatts = 50U;
inline constexpr std::uint16_t max_tx_power_deciwatts = 500U;
inline constexpr std::uint16_t default_tx_power_deciwatts = 250U;

struct DynamicFields {
    std::uint16_t lch_tx_power_deciwatts{default_tx_power_deciwatts};
};

struct BuildResult {
    bool ok{false};
    std::array<std::uint8_t, body_size> body{};
    std::string error{};
};

[[nodiscard]] bool valid_tx_power_deciwatts(std::uint16_t deciwatts) noexcept;

// 以已批准底板为基础，仅覆盖 P0 白名单字段。
[[nodiscard]] BuildResult build(const std::array<std::uint8_t, body_size>& approved_template,
                                const DynamicFields& fields, bool ap_mode);

// 严格校验：除 0x05、0x0C 和 0x2F..0x32 外，正文必须与底板逐字节相同。
[[nodiscard]] bool validate(const std::array<std::uint8_t, body_size>& approved_template,
                            const std::uint8_t* body, std::size_t size, bool ap_mode) noexcept;

} // namespace wirex::hri_y
