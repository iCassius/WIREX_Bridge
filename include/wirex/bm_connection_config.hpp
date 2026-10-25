#pragma once

#include <cstdint>
#include <array>
#include <string_view>

namespace wirex::bm_connection_config {

struct Fields {
    std::string_view callsign;
    std::uint64_t gateway_id{};
    std::uint64_t source_id{};
    std::string_view master;
    std::uint64_t master_port{};
    std::uint64_t destination_id{};
    std::uint64_t slot{};
    std::uint64_t color_code{};
    std::string_view call_kind;
};

[[nodiscard]] bool parse_decimal_u32(std::string_view text, std::uint32_t& value) noexcept;
[[nodiscard]] bool any_field_seen(const std::array<bool, 9U>& seen) noexcept;
[[nodiscard]] bool all_fields_seen(const std::array<bool, 9U>& seen) noexcept;
[[nodiscard]] bool validate(const Fields& fields) noexcept;

} // namespace wirex::bm_connection_config
