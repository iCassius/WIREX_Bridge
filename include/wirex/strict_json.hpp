#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace wirex::strict_json {

struct Value {
    enum class Type { null_value, boolean, unsigned_integer, string, array, object };
    Type type{Type::null_value};
    bool boolean_value{};
    std::uint64_t integer_value{};
    std::string string_value{};
    std::vector<Value> array_value{};
    std::vector<std::pair<std::string, Value>> object_value{};

    [[nodiscard]] const Value* find(std::string_view key) const noexcept;
};

inline constexpr std::size_t max_input_bytes = 65536U;

// Strict UTF-8 JSON reader. Duplicate object keys and non-integral/negative
// numbers are rejected because all Native numeric fields are unsigned integers.
[[nodiscard]] bool parse(std::string_view input, Value& output) noexcept;
[[nodiscard]] bool valid_utf8(std::string_view input) noexcept;

} // namespace wirex::strict_json
