#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// Minimal JSON DOM for config.json. Numbers keep their source literal so
// unknown fields round-trip unchanged; object members keep insertion order.
namespace wirex::app::json {

struct Value {
    enum class Type : std::uint8_t { null_value, boolean, number, string, array, object };

    Type type{Type::null_value};
    bool boolean_value{};
    std::string text{};  // number literal (RFC 8259 grammar) or UTF-8 string contents
    std::vector<Value> items{};
    std::vector<std::pair<std::string, Value>> members{};

    [[nodiscard]] static Value null();
    [[nodiscard]] static Value boolean(bool value);
    [[nodiscard]] static Value number(std::uint64_t value);
    // Caller must pass a valid JSON number literal (see is_number_literal).
    [[nodiscard]] static Value number_literal(std::string literal);
    [[nodiscard]] static Value string(std::string value);
    [[nodiscard]] static Value array();
    [[nodiscard]] static Value object();

    [[nodiscard]] bool is_null() const noexcept { return type == Type::null_value; }
    [[nodiscard]] bool is_bool() const noexcept { return type == Type::boolean; }
    [[nodiscard]] bool is_number() const noexcept { return type == Type::number; }
    [[nodiscard]] bool is_string() const noexcept { return type == Type::string; }
    [[nodiscard]] bool is_array() const noexcept { return type == Type::array; }
    [[nodiscard]] bool is_object() const noexcept { return type == Type::object; }

    // Exact (case-sensitive) member lookup.
    [[nodiscard]] const Value* find(std::string_view key) const noexcept;
    [[nodiscard]] Value* find(std::string_view key) noexcept;
    // Replaces the exact member in place or appends it at the end.
    Value& set(std::string_view key, Value value);
    bool erase(std::string_view key);

    // Integer view of a number literal without fraction/exponent; nullopt otherwise.
    [[nodiscard]] std::optional<std::uint64_t> as_uint64() const noexcept;

    friend bool operator==(const Value& left, const Value& right);
    friend bool operator!=(const Value& left, const Value& right) { return !(left == right); }
};

enum class ParseError : std::uint8_t {
    none,
    invalid_utf8,
    syntax,
    duplicate_key,  // exact or ASCII case-insensitive repeat (PowerShell ConvertFrom-Json rejects both)
    escaped_key,    // PortableConfig.psm1 rejects backslash escapes inside member names
    too_deep,
};

struct ParseResult {
    ParseError error{ParseError::none};
    std::size_t offset{};
    [[nodiscard]] bool ok() const noexcept { return error == ParseError::none; }
};

inline constexpr std::size_t max_depth = 64U;

struct ParseOptions {
    // PortableConfig.psm1 rejects escaped member names; server responses (BM API, radioid.net) may use them.
    bool reject_escaped_keys{true};
};

// Parses one RFC 8259 document (optionally preceded by a UTF-8 BOM).
[[nodiscard]] ParseResult parse(std::string_view input, Value& output, ParseOptions options = {});
[[nodiscard]] bool is_number_literal(std::string_view literal) noexcept;
[[nodiscard]] bool valid_utf8(std::string_view input) noexcept;
// UTF-16 code unit count (what .NET String.Length reports); nullopt on invalid UTF-8.
[[nodiscard]] std::optional<std::size_t> utf16_length(std::string_view input) noexcept;
[[nodiscard]] std::optional<std::u32string> to_code_points(std::string_view utf8);
// .NET StringComparer.OrdinalIgnoreCase equivalent for UTF-8 keys.
[[nodiscard]] bool equals_ignore_case(std::string_view left, std::string_view right);

// Windows PowerShell 5.1 `ConvertTo-Json` layout: CRLF line breaks, `"key":  value`,
// nested containers indented four columns past their opening bracket, empty
// containers rendered with one blank line, and HTML-sensitive characters
// escaped as < etc. No trailing newline is added.
[[nodiscard]] std::string serialize(const Value& value);
[[nodiscard]] std::string escape_string(std::string_view utf8);

} // namespace wirex::app::json
