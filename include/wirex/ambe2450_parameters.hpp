#pragma once

#include <cstdint>

namespace wirex::ambe2450 {

// AMBE+2 2450x1150 的49位原始参数，已去除 DMR Golay 与扰码封装。
struct Parameters {
    std::uint16_t a{};
    std::uint16_t b{};
    std::uint32_t c{};
};

// A、B 字段各占12位，C 字段占25位。
[[nodiscard]] constexpr bool is_valid(const Parameters& parameters) noexcept
{
    return parameters.a < 0x1000U && parameters.b < 0x1000U && parameters.c < 0x02000000U;
}

} // namespace wirex::ambe2450
