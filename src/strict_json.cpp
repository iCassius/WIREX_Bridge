#include "wirex/strict_json.hpp"

#include <limits>

namespace wirex::strict_json {
namespace {

bool append_codepoint(std::string& out, std::uint32_t codepoint)
{
    if (codepoint <= 0x7fU) {
        out.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ffU) {
        out.push_back(static_cast<char>(0xc0U | (codepoint >> 6U)));
        out.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else if (codepoint <= 0xffffU) {
        out.push_back(static_cast<char>(0xe0U | (codepoint >> 12U)));
        out.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
        out.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else if (codepoint <= 0x10ffffU) {
        out.push_back(static_cast<char>(0xf0U | (codepoint >> 18U)));
        out.push_back(static_cast<char>(0x80U | ((codepoint >> 12U) & 0x3fU)));
        out.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
        out.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else {
        return false;
    }
    return true;
}

class Reader final {
public:
    explicit Reader(std::string_view input) noexcept : input_(input) {}

    bool read(Value& output)
    {
        whitespace();
        if (!value(output, 0U)) return false;
        whitespace();
        return position_ == input_.size();
    }

private:
    void whitespace() noexcept
    {
        while (position_ < input_.size() &&
               (input_[position_] == ' ' || input_[position_] == '\t' ||
                input_[position_] == '\r' || input_[position_] == '\n')) ++position_;
    }

    bool take(char expected) noexcept
    {
        if (position_ >= input_.size() || input_[position_] != expected) return false;
        ++position_;
        return true;
    }

    bool value(Value& output, unsigned depth)
    {
        if (depth > 32U || position_ >= input_.size()) return false;
        const char current = input_[position_];
        if (current == 'n') return literal("null", Value::Type::null_value, output);
        if (current == 't' || current == 'f') {
            if (current == 't') {
                if (!literal("true", Value::Type::boolean, output)) return false;
                output.boolean_value = true;
                return true;
            }
            if (!literal("false", Value::Type::boolean, output)) return false;
            output.boolean_value = false;
            return true;
        }
        if (current == '"') {
            output.type = Value::Type::string;
            return string(output.string_value);
        }
        if (current == '[') return array(output, depth + 1U);
        if (current == '{') return object(output, depth + 1U);
        if (current >= '0' && current <= '9') return integer(output);
        return false;
    }

    bool literal(std::string_view expected, Value::Type type, Value& output)
    {
        if (input_.substr(position_, expected.size()) != expected) return false;
        position_ += expected.size();
        output = {};
        output.type = type;
        return true;
    }

    bool hex4(std::uint32_t& result) noexcept
    {
        if (input_.size() - position_ < 4U) return false;
        result = 0U;
        for (unsigned index = 0U; index < 4U; ++index) {
            const char ch = input_[position_++];
            std::uint32_t digit{};
            if (ch >= '0' && ch <= '9') digit = static_cast<std::uint32_t>(ch - '0');
            else if (ch >= 'a' && ch <= 'f') digit = static_cast<std::uint32_t>(ch - 'a' + 10);
            else if (ch >= 'A' && ch <= 'F') digit = static_cast<std::uint32_t>(ch - 'A' + 10);
            else return false;
            result = (result << 4U) | digit;
        }
        return true;
    }

    bool string(std::string& output)
    {
        if (!take('"')) return false;
        output.clear();
        while (position_ < input_.size()) {
            const auto byte = static_cast<unsigned char>(input_[position_++]);
            if (byte == '"') return true;
            if (byte < 0x20U) return false;
            if (byte != '\\') {
                output.push_back(static_cast<char>(byte));
                continue;
            }
            if (position_ >= input_.size()) return false;
            switch (input_[position_++]) {
            case '"': output.push_back('"'); break;
            case '\\': output.push_back('\\'); break;
            case '/': output.push_back('/'); break;
            case 'b': output.push_back('\b'); break;
            case 'f': output.push_back('\f'); break;
            case 'n': output.push_back('\n'); break;
            case 'r': output.push_back('\r'); break;
            case 't': output.push_back('\t'); break;
            case 'u': {
                std::uint32_t cp{};
                if (!hex4(cp)) return false;
                if (cp >= 0xd800U && cp <= 0xdbffU) {
                    if (input_.size() - position_ < 6U || input_[position_] != '\\' ||
                        input_[position_ + 1U] != 'u') return false;
                    position_ += 2U;
                    std::uint32_t low{};
                    if (!hex4(low) || low < 0xdc00U || low > 0xdfffU) return false;
                    cp = 0x10000U + ((cp - 0xd800U) << 10U) + (low - 0xdc00U);
                } else if (cp >= 0xdc00U && cp <= 0xdfffU) {
                    return false;
                }
                if (!append_codepoint(output, cp)) return false;
                break;
            }
            default: return false;
            }
        }
        return false;
    }

    bool integer(Value& output) noexcept
    {
        const auto begin = position_;
        if (input_[position_] == '0') {
            ++position_;
            if (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') return false;
            output.integer_value = 0U;
        } else {
            std::uint64_t number = 0U;
            while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
                const auto digit = static_cast<std::uint64_t>(input_[position_] - '0');
                if (number > (std::numeric_limits<std::uint64_t>::max() - digit) / 10U) return false;
                number = number * 10U + digit;
                ++position_;
            }
            output.integer_value = number;
        }
        if (position_ == begin || (position_ < input_.size() &&
            (input_[position_] == '.' || input_[position_] == 'e' || input_[position_] == 'E'))) return false;
        output.type = Value::Type::unsigned_integer;
        return true;
    }

    bool array(Value& output, unsigned depth)
    {
        if (!take('[')) return false;
        output = {};
        output.type = Value::Type::array;
        whitespace();
        if (take(']')) return true;
        for (;;) {
            Value element{};
            if (!value(element, depth)) return false;
            output.array_value.push_back(std::move(element));
            whitespace();
            if (take(']')) return true;
            if (!take(',')) return false;
            whitespace();
        }
    }

    bool object(Value& output, unsigned depth)
    {
        if (!take('{')) return false;
        output = {};
        output.type = Value::Type::object;
        whitespace();
        if (take('}')) return true;
        for (;;) {
            std::string key;
            if (!string(key)) return false;
            for (const auto& field : output.object_value) if (field.first == key) return false;
            whitespace();
            if (!take(':')) return false;
            whitespace();
            Value field_value{};
            if (!value(field_value, depth)) return false;
            output.object_value.emplace_back(std::move(key), std::move(field_value));
            whitespace();
            if (take('}')) return true;
            if (!take(',')) return false;
            whitespace();
        }
    }

    std::string_view input_;
    std::size_t position_{};
};

} // namespace

const Value* Value::find(std::string_view key) const noexcept
{
    if (type != Type::object) return nullptr;
    for (const auto& field : object_value) if (field.first == key) return &field.second;
    return nullptr;
}

bool valid_utf8(std::string_view input) noexcept
{
    std::size_t i = 0U;
    while (i < input.size()) {
        const auto lead = static_cast<unsigned char>(input[i]);
        if (lead <= 0x7fU) { ++i; continue; }
        std::uint32_t cp{};
        std::size_t count{};
        if (lead >= 0xc2U && lead <= 0xdfU) { cp = lead & 0x1fU; count = 1U; }
        else if (lead >= 0xe0U && lead <= 0xefU) { cp = lead & 0x0fU; count = 2U; }
        else if (lead >= 0xf0U && lead <= 0xf4U) { cp = lead & 0x07U; count = 3U; }
        else return false;
        if (input.size() - i - 1U < count) return false;
        for (std::size_t j = 1U; j <= count; ++j) {
            const auto next = static_cast<unsigned char>(input[i + j]);
            if ((next & 0xc0U) != 0x80U) return false;
            cp = (cp << 6U) | (next & 0x3fU);
        }
        if ((count == 1U && cp < 0x80U) || (count == 2U && cp < 0x800U) ||
            (count == 3U && cp < 0x10000U) || (cp >= 0xd800U && cp <= 0xdfffU) || cp > 0x10ffffU) return false;
        i += count + 1U;
    }
    return true;
}

bool parse(std::string_view input, Value& output) noexcept
{
    if (input.size() > max_input_bytes || !valid_utf8(input)) return false;
    try {
        Reader reader(input);
        Value candidate{};
        if (!reader.read(candidate)) return false;
        output = std::move(candidate);
        return true;
    } catch (...) {
        return false;
    }
}

} // namespace wirex::strict_json
