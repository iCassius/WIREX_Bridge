#include "wirex/app/json.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <limits>
#include <unordered_set>

namespace wirex::app::json {
namespace {

constexpr std::string_view newline = "\r\n";

void append_utf8(std::string& out, std::uint32_t cp)
{
    if (cp < 0x80U) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800U) {
        out.push_back(static_cast<char>(0xC0U | (cp >> 6U)));
        out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
    } else if (cp < 0x10000U) {
        out.push_back(static_cast<char>(0xE0U | (cp >> 12U)));
        out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
        out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
    } else {
        out.push_back(static_cast<char>(0xF0U | (cp >> 18U)));
        out.push_back(static_cast<char>(0x80U | ((cp >> 12U) & 0x3FU)));
        out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
        out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
    }
}

// Decodes one UTF-8 sequence at `index`; returns false on malformed input.
bool decode_utf8(std::string_view input, std::size_t& index, std::uint32_t& cp) noexcept
{
    const auto byte = [&](std::size_t i) { return static_cast<unsigned char>(input[i]); };
    const unsigned char lead = byte(index);
    std::size_t length = 0;
    std::uint32_t minimum = 0;
    if (lead < 0x80U) { cp = lead; ++index; return true; }
    if (lead >= 0xC2U && lead <= 0xDFU) { length = 2; cp = lead & 0x1FU; minimum = 0x80U; }
    else if (lead >= 0xE0U && lead <= 0xEFU) { length = 3; cp = lead & 0x0FU; minimum = 0x800U; }
    else if (lead >= 0xF0U && lead <= 0xF4U) { length = 4; cp = lead & 0x07U; minimum = 0x10000U; }
    else return false;
    if (index + length > input.size()) return false;
    for (std::size_t i = 1; i < length; ++i) {
        const unsigned char next = byte(index + i);
        if ((next & 0xC0U) != 0x80U) return false;
        cp = (cp << 6U) | (next & 0x3FU);
    }
    if (cp < minimum || cp > 0x10FFFFU || (cp >= 0xD800U && cp <= 0xDFFFU)) return false;
    index += length;
    return true;
}

// .NET OrdinalIgnoreCase folding, used to mirror ConvertFrom-Json's
// case-insensitive duplicate key rejection.
std::wstring fold_key(std::string_view key)
{
    if (key.empty()) return {};
    const int wide_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, key.data(),
        static_cast<int>(key.size()), nullptr, 0);
    if (wide_length <= 0) return {};
    std::wstring wide(static_cast<std::size_t>(wide_length), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, key.data(), static_cast<int>(key.size()), wide.data(), wide_length);
    std::wstring folded(wide.size(), L'\0');
    const int mapped = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, wide.c_str(), wide_length,
        folded.data(), wide_length, nullptr, nullptr, 0);
    if (mapped != wide_length) return wide;
    return folded;
}

class Parser {
public:
    explicit Parser(std::string_view input) : input_(input) {}

    ParseResult run(Value& output)
    {
        if (input_.size() >= 3 && input_.substr(0, 3) == "\xEF\xBB\xBF") pos_ = 3;
        if (!valid_utf8(input_.substr(pos_))) return {ParseError::invalid_utf8, pos_};
        skip_ws();
        if (!parse_value(output, 0)) return {error_, pos_};
        skip_ws();
        if (pos_ != input_.size()) return {ParseError::syntax, pos_};
        return {};
    }

private:
    bool fail(ParseError error) { error_ = error; return false; }
    [[nodiscard]] bool at_end() const noexcept { return pos_ >= input_.size(); }
    [[nodiscard]] char peek() const noexcept { return at_end() ? '\0' : input_[pos_]; }

    void skip_ws() noexcept
    {
        while (!at_end()) {
            const char c = input_[pos_];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
            ++pos_;
        }
    }

    bool literal(std::string_view word)
    {
        if (input_.substr(pos_, word.size()) != word) return fail(ParseError::syntax);
        pos_ += word.size();
        return true;
    }

    bool parse_value(Value& out, std::size_t depth)
    {
        if (depth > max_depth) return fail(ParseError::too_deep);
        switch (peek()) {
        case '{': return parse_object(out, depth);
        case '[': return parse_array(out, depth);
        case '"': out = Value::string({}); return parse_string(out.text, nullptr);
        case 't': out = Value::boolean(true); return literal("true");
        case 'f': out = Value::boolean(false); return literal("false");
        case 'n': out = Value::null(); return literal("null");
        default: return parse_number(out);
        }
    }

    bool parse_number(Value& out)
    {
        const std::size_t start = pos_;
        if (peek() == '-') ++pos_;
        if (peek() == '0') {
            ++pos_;
        } else if (peek() >= '1' && peek() <= '9') {
            while (peek() >= '0' && peek() <= '9') ++pos_;
        } else {
            return fail(ParseError::syntax);
        }
        if (peek() == '.') {
            ++pos_;
            if (!(peek() >= '0' && peek() <= '9')) return fail(ParseError::syntax);
            while (peek() >= '0' && peek() <= '9') ++pos_;
        }
        if (peek() == 'e' || peek() == 'E') {
            ++pos_;
            if (peek() == '+' || peek() == '-') ++pos_;
            if (!(peek() >= '0' && peek() <= '9')) return fail(ParseError::syntax);
            while (peek() >= '0' && peek() <= '9') ++pos_;
        }
        out = Value::number_literal(std::string(input_.substr(start, pos_ - start)));
        return true;
    }

    bool parse_hex4(std::uint32_t& value)
    {
        if (pos_ + 4 > input_.size()) return fail(ParseError::syntax);
        value = 0;
        for (int i = 0; i < 4; ++i) {
            const char c = input_[pos_++];
            value <<= 4U;
            if (c >= '0' && c <= '9') value |= static_cast<std::uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') value |= static_cast<std::uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') value |= static_cast<std::uint32_t>(c - 'A' + 10);
            else return fail(ParseError::syntax);
        }
        return true;
    }

    bool parse_string(std::string& out, bool* had_escape)
    {
        ++pos_;  // opening quote
        while (true) {
            if (at_end()) return fail(ParseError::syntax);
            const char c = input_[pos_];
            if (c == '"') { ++pos_; return true; }
            if (static_cast<unsigned char>(c) < 0x20U) return fail(ParseError::syntax);
            if (c != '\\') { out.push_back(c); ++pos_; continue; }
            if (had_escape != nullptr) *had_escape = true;
            ++pos_;
            if (at_end()) return fail(ParseError::syntax);
            const char e = input_[pos_++];
            switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                std::uint32_t cp = 0;
                if (!parse_hex4(cp)) return false;
                if (cp >= 0xDC00U && cp <= 0xDFFFU) return fail(ParseError::syntax);
                if (cp >= 0xD800U && cp <= 0xDBFFU) {
                    std::uint32_t low = 0;
                    if (input_.substr(pos_, 2) != "\\u") return fail(ParseError::syntax);
                    pos_ += 2;
                    if (!parse_hex4(low)) return false;
                    if (low < 0xDC00U || low > 0xDFFFU) return fail(ParseError::syntax);
                    cp = 0x10000U + ((cp - 0xD800U) << 10U) + (low - 0xDC00U);
                }
                append_utf8(out, cp);
                break;
            }
            default: return fail(ParseError::syntax);
            }
        }
    }

    bool parse_array(Value& out, std::size_t depth)
    {
        out = Value::array();
        ++pos_;
        skip_ws();
        if (peek() == ']') { ++pos_; return true; }
        while (true) {
            Value item;
            if (!parse_value(item, depth + 1)) return false;
            out.items.push_back(std::move(item));
            skip_ws();
            if (peek() == ',') { ++pos_; skip_ws(); continue; }
            if (peek() == ']') { ++pos_; return true; }
            return fail(ParseError::syntax);
        }
    }

    bool parse_object(Value& out, std::size_t depth)
    {
        out = Value::object();
        ++pos_;
        skip_ws();
        if (peek() == '}') { ++pos_; return true; }
        std::unordered_set<std::wstring> seen;
        while (true) {
            if (peek() != '"') return fail(ParseError::syntax);
            const std::size_t key_start = pos_;
            std::string key;
            bool had_escape = false;
            if (!parse_string(key, &had_escape)) return false;
            if (had_escape) { pos_ = key_start; return fail(ParseError::escaped_key); }
            if (!seen.insert(fold_key(key)).second) { pos_ = key_start; return fail(ParseError::duplicate_key); }
            skip_ws();
            if (peek() != ':') return fail(ParseError::syntax);
            ++pos_;
            skip_ws();
            Value member;
            if (!parse_value(member, depth + 1)) return false;
            out.members.emplace_back(std::move(key), std::move(member));
            skip_ws();
            if (peek() == ',') { ++pos_; skip_ws(); continue; }
            if (peek() == '}') { ++pos_; return true; }
            return fail(ParseError::syntax);
        }
    }

    std::string_view input_;
    std::size_t pos_{};
    ParseError error_{ParseError::syntax};
};

void pad(std::string& out, std::size_t columns) { out.append(columns, ' '); }

void write_value(std::string& out, const Value& value, std::size_t column)
{
    switch (value.type) {
    case Value::Type::null_value: out += "null"; return;
    case Value::Type::boolean: out += value.boolean_value ? "true" : "false"; return;
    case Value::Type::number: out += value.text; return;
    case Value::Type::string: out += escape_string(value.text); return;
    case Value::Type::array:
        out += '[';
        out += newline;
        if (value.items.empty()) out += newline;
        for (std::size_t i = 0; i < value.items.size(); ++i) {
            pad(out, column + 4);
            write_value(out, value.items[i], column + 4);
            if (i + 1 < value.items.size()) out += ',';
            out += newline;
        }
        pad(out, column);
        out += ']';
        return;
    case Value::Type::object:
        out += '{';
        out += newline;
        if (value.members.empty()) out += newline;
        for (std::size_t i = 0; i < value.members.size(); ++i) {
            const auto& [key, member] = value.members[i];
            const std::string escaped_key = escape_string(key);
            pad(out, column + 4);
            out += escaped_key;
            out += ":  ";
            // PowerShell aligns nested brackets by UTF-16 column, not by byte.
            const std::size_t key_columns = utf16_length(escaped_key).value_or(escaped_key.size());
            write_value(out, member, column + 4 + key_columns + 3);
            if (i + 1 < value.members.size()) out += ',';
            out += newline;
        }
        pad(out, column);
        out += '}';
        return;
    }
}

} // namespace

Value Value::null() { return Value{}; }
Value Value::boolean(bool value) { Value v; v.type = Type::boolean; v.boolean_value = value; return v; }
Value Value::number(std::uint64_t value) { return number_literal(std::to_string(value)); }
Value Value::number_literal(std::string literal) { Value v; v.type = Type::number; v.text = std::move(literal); return v; }
Value Value::string(std::string value) { Value v; v.type = Type::string; v.text = std::move(value); return v; }
Value Value::array() { Value v; v.type = Type::array; return v; }
Value Value::object() { Value v; v.type = Type::object; return v; }

const Value* Value::find(std::string_view key) const noexcept
{
    if (type != Type::object) return nullptr;
    for (const auto& [name, value] : members) if (name == key) return &value;
    return nullptr;
}

Value* Value::find(std::string_view key) noexcept
{
    return const_cast<Value*>(static_cast<const Value*>(this)->find(key));
}

Value& Value::set(std::string_view key, Value value)
{
    if (Value* existing = find(key)) {
        *existing = std::move(value);
        return *existing;
    }
    members.emplace_back(std::string(key), std::move(value));
    return members.back().second;
}

bool Value::erase(std::string_view key)
{
    for (auto it = members.begin(); it != members.end(); ++it) {
        if (it->first == key) { members.erase(it); return true; }
    }
    return false;
}

std::optional<std::uint64_t> Value::as_uint64() const noexcept
{
    if (type != Type::number || text.empty()) return std::nullopt;
    std::uint64_t result = 0;
    for (const char c : text) {
        if (c < '0' || c > '9') return std::nullopt;
        const auto digit = static_cast<std::uint64_t>(c - '0');
        if (result > (std::numeric_limits<std::uint64_t>::max() - digit) / 10U) return std::nullopt;
        result = result * 10U + digit;
    }
    return result;
}

bool operator==(const Value& left, const Value& right)
{
    if (left.type != right.type) return false;
    switch (left.type) {
    case Value::Type::null_value: return true;
    case Value::Type::boolean: return left.boolean_value == right.boolean_value;
    case Value::Type::number:
    case Value::Type::string: return left.text == right.text;
    case Value::Type::array: return left.items == right.items;
    case Value::Type::object: return left.members == right.members;
    }
    return false;
}

ParseResult parse(std::string_view input, Value& output)
{
    Value parsed;
    Parser parser(input);
    const ParseResult result = parser.run(parsed);
    if (result.ok()) output = std::move(parsed);
    return result;
}

bool is_number_literal(std::string_view literal) noexcept
{
    Value ignored;
    try {
        return !literal.empty() && literal[0] != ' ' && parse(literal, ignored).ok() && ignored.is_number();
    } catch (...) {
        return false;
    }
}

bool valid_utf8(std::string_view input) noexcept
{
    std::size_t index = 0;
    std::uint32_t cp = 0;
    while (index < input.size()) {
        if (!decode_utf8(input, index, cp)) return false;
    }
    return true;
}

std::optional<std::size_t> utf16_length(std::string_view input) noexcept
{
    std::size_t index = 0;
    std::size_t units = 0;
    std::uint32_t cp = 0;
    while (index < input.size()) {
        if (!decode_utf8(input, index, cp)) return std::nullopt;
        units += cp >= 0x10000U ? 2U : 1U;
    }
    return units;
}

bool equals_ignore_case(std::string_view left, std::string_view right)
{
    if (left == right) return true;
    return fold_key(left) == fold_key(right);
}

std::optional<std::u32string> to_code_points(std::string_view utf8)
{
    std::u32string result;
    result.reserve(utf8.size());
    std::size_t index = 0;
    std::uint32_t cp = 0;
    while (index < utf8.size()) {
        if (!decode_utf8(utf8, index, cp)) return std::nullopt;
        result.push_back(static_cast<char32_t>(cp));
    }
    return result;
}

std::string escape_string(std::string_view utf8)
{
    static constexpr char hex[] = "0123456789abcdef";
    const auto unicode_escape = [](std::string& out, std::uint32_t cp) {
        out += "\\u";
        out.push_back(hex[(cp >> 12U) & 0xFU]);
        out.push_back(hex[(cp >> 8U) & 0xFU]);
        out.push_back(hex[(cp >> 4U) & 0xFU]);
        out.push_back(hex[cp & 0xFU]);
    };
    std::string out;
    out.reserve(utf8.size() + 2);
    out.push_back('"');
    std::size_t index = 0;
    while (index < utf8.size()) {
        const std::size_t start = index;
        std::uint32_t cp = 0;
        if (!decode_utf8(utf8, index, cp)) {
            // Invalid input never comes from parse(); emit U+FFFD instead of raw bytes.
            unicode_escape(out, 0xFFFDU);
            index = start + 1;
            continue;
        }
        switch (cp) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        // JavaScriptSerializer (used by Windows PowerShell 5.1) escapes these.
        case '<': case '>': case '&': case '\'':
        case 0x85U: case 0x2028U: case 0x2029U:
            unicode_escape(out, cp);
            break;
        default:
            if (cp < 0x20U) unicode_escape(out, cp);
            else out.append(utf8.substr(start, index - start));
        }
    }
    out.push_back('"');
    return out;
}

std::string serialize(const Value& value)
{
    std::string out;
    write_value(out, value, 0);
    return out;
}

} // namespace wirex::app::json
