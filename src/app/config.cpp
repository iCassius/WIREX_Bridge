#include "wirex/app/config.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objbase.h>
#include <icu.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <optional>
#include <set>
#include <system_error>
#include <unordered_set>

namespace wirex::app {
namespace {

using json::Value;

// ---------------------------------------------------------------------------
// Errors

ConfigError make_error(ConfigErrorCode code, std::string field, std::string message)
{
    return ConfigError{code, std::move(field), std::move(message)};
}

ConfigError invalid_number(const std::string& label)
{
    return make_error(ConfigErrorCode::invalid_value, label, label + " 数值无效。");
}

ConfigError out_of_range(const std::string& label)
{
    return make_error(ConfigErrorCode::out_of_range, label, label + " 超出允许范围。");
}

// ---------------------------------------------------------------------------
// .NET / PowerShell text semantics

// .NET Char.IsWhiteSpace / regex \s (identical sets for BMP code points).
bool is_dotnet_whitespace(char32_t cp) noexcept
{
    return (cp >= 0x09 && cp <= 0x0D) || cp == 0x20 || cp == 0x85 || cp == 0xA0 || cp == 0x1680 ||
        (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F ||
        cp == 0x3000;
}

bool is_null_or_whitespace(std::string_view utf8)
{
    const auto cps = json::to_code_points(utf8);
    if (!cps) return false;
    for (const char32_t cp : *cps) if (!is_dotnet_whitespace(cp)) return false;
    return true;
}

bool contains_whitespace(std::string_view utf8)
{
    const auto cps = json::to_code_points(utf8);
    if (!cps) return true;
    for (const char32_t cp : *cps) if (is_dotnet_whitespace(cp)) return true;
    return false;
}

// Regex \p{C} as evaluated by .NET on UTF-16 code units: any non-BMP code point
// is a surrogate pair (Cs) and therefore matches.
bool contains_other_category(std::string_view utf8)
{
    const auto cps = json::to_code_points(utf8);
    if (!cps) return true;
    for (const char32_t cp : *cps) {
        if (cp >= 0x10000U) return true;
        switch (u_charType(static_cast<UChar32>(cp))) {
        case U_UNASSIGNED: case U_CONTROL_CHAR: case U_FORMAT_CHAR: case U_PRIVATE_USE_CHAR: case U_SURROGATE:
            return true;
        default: break;
        }
    }
    return false;
}

std::size_t utf16_len(std::string_view utf8)
{
    return json::utf16_length(utf8).value_or(std::numeric_limits<std::size_t>::max());
}

// .NET `$` matches at the very end or before one final '\n'. PowerShell's
// `-cmatch '^...$'` therefore also accepts the pattern followed by "\n".
template <class Pred>
bool ps_anchored_match(std::string_view text, Pred pred)
{
    if (pred(text)) return true;
    return !text.empty() && text.back() == '\n' && pred(text.substr(0, text.size() - 1));
}

bool all_digits(std::string_view s) noexcept
{
    if (s.empty()) return false;
    for (const char c : s) if (c < '0' || c > '9') return false;
    return true;
}

bool is_canonical_uint(std::string_view s) noexcept  // ^(0|[1-9][0-9]*)$
{
    return all_digits(s) && (s.size() == 1 || s[0] != '0');
}

bool is_com_port(std::string_view s) noexcept  // ^COM[1-9][0-9]{0,2}$ (case-sensitive)
{
    return s.size() >= 4 && s.size() <= 6 && s.substr(0, 3) == "COM" && s[3] >= '1' && s[3] <= '9' &&
        (s.size() == 4 || all_digits(s.substr(4)));
}

bool is_callsign(std::string_view s) noexcept  // ^[\x20-\x7e]{1,8}$
{
    if (s.empty() || s.size() > 8) return false;
    for (const char c : s) if (c < 0x20 || c > 0x7e) return false;
    return true;
}

bool is_server_selection(std::string_view s) noexcept  // ^(custom|bm-[a-z0-9-]+)$
{
    if (s == "custom") return true;
    if (s.size() < 4 || s.substr(0, 3) != "bm-") return false;
    for (const char c : s.substr(3)) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    return true;
}

bool is_gain_text(std::string_view s) noexcept  // ^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?$
{
    const auto dot = s.find('.');
    const auto whole = s.substr(0, dot);
    if (!is_canonical_uint(whole)) return false;
    if (dot == std::string_view::npos) return true;
    const auto fraction = s.substr(dot + 1);
    return fraction.size() >= 1 && fraction.size() <= 3 && all_digits(fraction);
}

// ---------------------------------------------------------------------------
// ConvertFrom-Json number typing. Integer literals become Int32/Int64 when
// they fit, otherwise Decimal; literals with a fraction become Decimal and
// literals with an exponent become Double.

enum class PsNumberKind : std::uint8_t { integer, decimal, floating };

struct PsNumber {
    PsNumberKind kind{PsNumberKind::integer};
    bool negative{};
    std::string digits{};  // integer kind: magnitude digits without sign
};

PsNumber classify(const std::string& literal)
{
    PsNumber result;
    result.negative = !literal.empty() && literal[0] == '-';
    if (literal.find_first_of("eE") != std::string::npos) { result.kind = PsNumberKind::floating; return result; }
    if (literal.find('.') != std::string::npos) { result.kind = PsNumberKind::decimal; return result; }
    result.digits = literal.substr(result.negative ? 1 : 0);
    // Int64 range: magnitude up to 9223372036854775807 (or ...808 when negative).
    static constexpr std::string_view int64_max = "9223372036854775807";
    static constexpr std::string_view int64_min_magnitude = "9223372036854775808";
    const std::string_view limit = result.negative ? int64_min_magnitude : int64_max;
    if (result.digits.size() > limit.size() ||
        (result.digits.size() == limit.size() && std::string_view(result.digits) > limit)) {
        result.kind = PsNumberKind::decimal;
    }
    return result;
}

bool parse_u64(std::string_view digits, std::uint64_t& value) noexcept
{
    if (!all_digits(digits)) return false;
    std::uint64_t parsed = 0;
    for (const char c : digits) {
        const auto digit = static_cast<std::uint64_t>(c - '0');
        if (parsed > (std::numeric_limits<std::uint64_t>::max() - digit) / 10U) return false;
        parsed = parsed * 10U + digit;
    }
    value = parsed;
    return true;
}

// ConvertTo-WirexUnsigned.
Result<std::uint64_t, ConfigError> to_unsigned(const Value* value, const std::string& label, std::uint64_t maximum,
    bool allow_zero)
{
    if (value == nullptr || value->is_null() || value->is_bool()) return invalid_number(label);
    std::string text;
    if (value->is_string()) {
        if (!ps_anchored_match(value->text, is_canonical_uint)) return invalid_number(label);
        text = value->text;
    } else if (value->is_number()) {
        const PsNumber number = classify(value->text);
        if (number.kind != PsNumberKind::integer) return invalid_number(label);
        const bool zero = number.digits.find_first_not_of('0') == std::string::npos;
        text = (number.negative && !zero) ? "-" + number.digits : number.digits;
    } else {
        return invalid_number(label);
    }
    std::uint64_t parsed = 0;
    if (!parse_u64(text, parsed) || parsed > maximum || (!allow_zero && parsed == 0)) return out_of_range(label);
    return parsed;
}

// ConvertTo-WirexGain. Returns the decimal text PowerShell keeps (scale preserved).
struct GainValue {
    std::uint32_t milli{};
    std::string literal{};
};

std::string double_to_decimal_text(double value)
{
    // System.Decimal(double) keeps 15 significant digits.
    std::array<char, 64> buffer{};
    std::snprintf(buffer.data(), buffer.size(), "%.15g", value);
    return buffer.data();
}

Result<GainValue, ConfigError> to_gain(const Value* value, const std::string& label)
{
    if (value == nullptr || value->is_null() || value->is_bool()) return invalid_number(label);
    std::string text;
    if (value->is_string()) {
        text = value->text;
    } else if (value->is_number()) {
        const PsNumber number = classify(value->text);
        if (number.kind == PsNumberKind::floating) {
            const double parsed = std::strtod(value->text.c_str(), nullptr);
            text = double_to_decimal_text(parsed == 0.0 ? 0.0 : parsed);
            if (text.find_first_of("eE") != std::string::npos) {
                return parsed > 16.0 ? out_of_range(label) : invalid_number(label);  // huge: range; tiny: >3 decimals
            }
        } else {
            text = value->text;
            if (number.negative) {
                const bool zero = text.find_first_of("123456789") == std::string::npos;
                if (!zero) return invalid_number(label);
                text.erase(0, 1);
            }
        }
    } else {
        return invalid_number(label);
    }
    if (!ps_anchored_match(text, is_gain_text)) return invalid_number(label);
    if (text.back() == '\n') return out_of_range(label);  // decimal.TryParse rejects the trailing newline
    const auto dot = text.find('.');
    const std::string whole = text.substr(0, dot);
    std::string fraction = dot == std::string::npos ? std::string() : text.substr(dot + 1);
    if (whole.size() > 2) return out_of_range(label);
    fraction.resize(3, '0');
    const std::uint32_t milli = static_cast<std::uint32_t>(std::stoul(whole)) * 1000U +
        static_cast<std::uint32_t>(std::stoul(fraction));
    if (milli < gain_min_milli || milli > gain_max_milli) return out_of_range(label);
    return GainValue{milli, text};
}

// ---------------------------------------------------------------------------
// Document helpers mirroring PortableConfig.psm1 merge semantics.

// [string] cast used for channel tuple keys during merge.
std::string ps_string(const Value& value)
{
    switch (value.type) {
    case Value::Type::null_value: return {};
    case Value::Type::boolean: return value.boolean_value ? "True" : "False";
    case Value::Type::string: return value.text;
    case Value::Type::number: {
        const PsNumber number = classify(value.text);
        if (number.kind == PsNumberKind::integer && number.digits.find_first_not_of('0') == std::string::npos) return "0";
        return value.text;
    }
    case Value::Type::array: return "System.Object[]";
    case Value::Type::object: return "System.Collections.Specialized.OrderedDictionary";
    }
    return {};
}

std::optional<std::string> merge_channel_key(const Value& channel)
{
    if (!channel.is_object()) return std::nullopt;
    const Value* id = channel.find("id");
    const Value* kind = channel.find("kind");
    const Value* slot = channel.find("slot");
    if (id == nullptr || kind == nullptr || slot == nullptr) return std::nullopt;
    return ps_string(*kind) + ":" + ps_string(*id) + ":" + ps_string(*slot);
}

Value merge_objects(const Value& base, const Value& override_value);

Value merge_channel_arrays(const Value& base, const Value& override_value)
{
    Value merged = Value::array();
    for (const Value& channel : override_value.items) {
        const Value* existing = nullptr;
        if (const auto key = merge_channel_key(channel)) {
            for (const Value& prior : base.items) {
                const auto prior_key = merge_channel_key(prior);
                if (prior_key && *prior_key == *key) { existing = &prior; break; }
            }
        }
        merged.items.push_back(existing != nullptr ? merge_objects(*existing, channel) : channel);
    }
    return merged;
}

// Merge-WirexConfigObjects. PowerShell's [ordered] dictionary is
// case-insensitive: a case-variant override key replaces the base value but
// keeps the base key's spelling.
Value merge_objects(const Value& base, const Value& override_value)
{
    if (!base.is_object() || !override_value.is_object()) return override_value;
    Value merged = base;
    for (const auto& [name, value] : override_value.members) {
        Value* exact = merged.find(name);
        if (exact != nullptr && exact->is_object() && value.is_object()) {
            *exact = merge_objects(*exact, value);
        } else if (name == "channels" && exact != nullptr && exact->is_array() && value.is_array()) {
            *exact = merge_channel_arrays(*exact, value);
        } else {
            Value* target = exact;
            if (target == nullptr) {
                for (auto& [existing_name, existing_value] : merged.members) {
                    if (json::equals_ignore_case(existing_name, name)) { target = &existing_value; break; }
                }
            }
            if (target != nullptr) *target = value;
            else merged.members.emplace_back(name, value);
        }
    }
    return merged;
}

bool has_credential_path_key(const Value& value)
{
    if (value.is_array()) {
        for (const Value& item : value.items) if (has_credential_path_key(item)) return true;
        return false;
    }
    if (!value.is_object()) return false;
    for (const auto& [name, member] : value.members) {
        if (json::equals_ignore_case(name, "password_file_path") || json::equals_ignore_case(name, "api_key_file_path") ||
            json::equals_ignore_case(name, "apikey_file_path")) {
            return true;
        }
        if (has_credential_path_key(member)) return true;
    }
    return false;
}

Value default_document()
{
    Value root = Value::object();
    root.set("schema_version", Value::number(1));
    Value connection = Value::object();
    connection.set("callsign", Value::string(""));
    connection.set("gateway_id", Value::number(0));
    connection.set("source_id", Value::number(0));
    connection.set("master", Value::string("43.129.83.124"));
    connection.set("master_port", Value::number(62031));
    connection.set("color_code", Value::number(1));
    connection.set("password", Value::string(""));
    connection.set("api_key", Value::string(""));
    root.set("connection", std::move(connection));
    Value devices = Value::object();
    devices.set("serial_port", Value::string("auto"));
    devices.set("hri_port", Value::string("auto"));
    devices.set("cat_port", Value::string("auto"));
    devices.set("cat_baud_rate", Value::number(38400));
    devices.set("cat_stop_bits", Value::string("Two"));
    devices.set("wave_in_endpoint_id", Value::string("auto"));
    devices.set("wave_out_endpoint_id", Value::string("auto"));
    devices.set("desired_power_watts", Value::number(25));
    root.set("devices", std::move(devices));
    Value audio = Value::object();
    // `[decimal]1.0` in PowerShell source is a double cast, so it serializes as 1.
    audio.set("radio_playback_gain", Value::number_literal("1"));
    audio.set("mic_transmit_gain", Value::number_literal("16"));
    root.set("audio", std::move(audio));
    Value channel = Value::object();
    channel.set("id", Value::number(460997));
    channel.set("kind", Value::string("private"));
    channel.set("slot", Value::number(2));
    channel.set("name", Value::string("460997"));
    Value channels = Value::array();
    channels.items.push_back(std::move(channel));
    root.set("channels", std::move(channels));
    root.set("tx_channel_id", Value::string("private:460997:2"));
    Value routing = Value::object();
    routing.set("blocked_source_ids", Value::array());
    root.set("routing", std::move(routing));
    Value ui = Value::object();
    ui.set("bm_server_selection_id", Value::string("bm-china-4602"));
    ui.set("legacy_rx_policy", Value::null());
    ui.set("language", Value::string("zh-CN"));
    root.set("ui", std::move(ui));
    root.set("window", Value::object());
    return root;
}

// Assert-WirexStoredConfigShape (load path only).
std::optional<ConfigError> check_stored_shape(const Value& root)
{
    if (!root.is_object()) {
        return make_error(ConfigErrorCode::not_object, {}, "config.json 必须是 JSON 对象；原文件已保留。");
    }
    for (const char* name : {"schema_version", "connection", "devices", "audio", "channels", "tx_channel_id",
             "routing", "ui", "window"}) {
        if (root.find(name) == nullptr) {
            return make_error(ConfigErrorCode::missing_required_field, name, "config.json 缺少必需字段；原文件已保留。");
        }
    }
    struct Section {
        const char* name;
        std::vector<const char*> keys;
    };
    const std::array<Section, 5> sections{{
        {"connection", {"callsign", "gateway_id", "source_id", "master", "master_port", "color_code", "password", "api_key"}},
        {"devices", {"serial_port", "hri_port", "cat_port", "cat_baud_rate", "cat_stop_bits", "wave_in_endpoint_id",
                         "wave_out_endpoint_id", "desired_power_watts"}},
        {"audio", {"radio_playback_gain", "mic_transmit_gain"}},
        {"routing", {"blocked_source_ids"}},
        {"ui", {"bm_server_selection_id", "legacy_rx_policy"}},
    }};
    for (const Section& section : sections) {
        const Value* value = root.find(section.name);
        if (value == nullptr || !value->is_object()) {
            return make_error(ConfigErrorCode::incomplete_section, section.name, "config.json 含有不完整字段组；原文件已保留。");
        }
        for (const char* key : section.keys) {
            if (value->find(key) == nullptr) {
                return make_error(ConfigErrorCode::incomplete_section, std::string(section.name) + "." + key,
                    "config.json 含有不完整字段组；原文件已保留。");
            }
        }
    }
    return std::nullopt;
}

std::string gain_literal_for(const Value* existing, std::uint32_t milli)
{
    if (existing != nullptr && existing->is_number()) {
        const auto parsed = to_gain(existing, "gain");
        if (parsed && parsed.value().milli == milli) return parsed.value().literal;
    }
    return format_gain_milli(milli);
}

// Overlays typed fields on `doc` (which already holds every default member).
void write_typed(Value& doc, const AppConfig& config, const Value* gain_source)
{
    Value& connection = *doc.find("connection");
    connection.set("callsign", Value::string(config.connection.callsign));
    connection.set("gateway_id", Value::number(config.connection.gateway_id));
    connection.set("source_id", Value::number(config.connection.source_id));
    connection.set("master", Value::string(config.connection.master));
    connection.set("master_port", Value::number(config.connection.master_port));
    connection.set("color_code", Value::number(config.connection.color_code));
    connection.set("password", Value::string(config.connection.password));
    connection.set("api_key", Value::string(config.connection.api_key));

    Value& devices = *doc.find("devices");
    devices.set("serial_port", Value::string(config.devices.hri_port));
    devices.set("hri_port", Value::string(config.devices.hri_port));
    devices.set("cat_port", Value::string(config.devices.cat_port));
    devices.set("cat_baud_rate", Value::number(config.devices.cat_baud_rate));
    devices.set("cat_stop_bits", Value::string(config.devices.cat_stop_bits));
    devices.set("wave_in_endpoint_id", Value::string(config.devices.wave_in_endpoint_id));
    devices.set("wave_out_endpoint_id", Value::string(config.devices.wave_out_endpoint_id));
    devices.set("desired_power_watts", Value::number(config.devices.desired_power_watts));

    Value& audio = *doc.find("audio");
    const Value* source_audio = gain_source != nullptr ? gain_source->find("audio") : nullptr;
    const auto source_gain = [&](const char* name) { return source_audio != nullptr ? source_audio->find(name) : nullptr; };
    audio.set("radio_playback_gain", Value::number_literal(
        gain_literal_for(source_gain("radio_playback_gain"), config.audio.radio_playback_gain_milli)));
    audio.set("mic_transmit_gain", Value::number_literal(
        gain_literal_for(source_gain("mic_transmit_gain"), config.audio.mic_transmit_gain_milli)));

    const Value* old_channels = gain_source != nullptr ? gain_source->find("channels") : nullptr;
    Value channels = Value::array();
    for (const ChannelConfig& channel : config.channels) {
        Value item = Value::object();
        if (old_channels != nullptr && old_channels->is_array()) {
            for (const Value& prior : old_channels->items) {
                const auto prior_key = merge_channel_key(prior);
                if (prior_key && *prior_key == channel.key()) { item = prior; break; }
            }
        }
        item.set("id", Value::number(channel.id));
        item.set("kind", Value::string(channel_kind_name(channel.kind)));
        item.set("slot", Value::number(channel.slot));
        item.set("name", Value::string(channel.name));
        channels.items.push_back(std::move(item));
    }
    doc.set("channels", std::move(channels));
    doc.set("tx_channel_id", Value::string(config.tx_channel_id));

    Value& routing = *doc.find("routing");
    Value blocked = Value::array();
    for (const std::uint32_t id : config.routing.blocked_source_ids) blocked.items.push_back(Value::number(id));
    routing.set("blocked_source_ids", std::move(blocked));

    Value& ui = *doc.find("ui");
    ui.set("bm_server_selection_id", Value::string(config.ui.bm_server_selection_id));
    ui.set("legacy_rx_policy", config.ui.legacy_rx_policy);
    ui.set("language", Value::string(config.ui.language));
    doc.set("window", config.window);

    // relay（R130，原生扩展）：文件已有该节或任一开关为 true 时才写入；默认配置保持与 PS 生成的字节一致。
    Value* relay = doc.find("relay");
    if (relay == nullptr && (config.relay.enabled || config.relay.fm_enabled)) {
        relay = &doc.set("relay", Value::object());
    }
    if (relay != nullptr && relay->is_object()) {
        relay->set("enabled", Value::boolean(config.relay.enabled));
        relay->set("fm_enabled", Value::boolean(config.relay.fm_enabled));
    }
}

// ConvertTo-WirexPortableConfig.
ConfigResult<AppConfig> validate(const Value& input)
{
    if (!input.is_object()) return make_error(ConfigErrorCode::not_object, {}, "便携配置必须是 JSON 对象。");
    Value merged = merge_objects(default_document(), input);
    AppConfig config;

    const auto schema = to_unsigned(merged.find("schema_version"), "schema_version", 1, false);
    if (!schema) return schema.error();
    if (schema.value() != 1) {
        return make_error(ConfigErrorCode::unsupported_version, "schema_version", "便携配置版本不受支持。");
    }
    for (const char* name : {"connection", "devices", "audio", "routing", "ui", "window"}) {
        const Value* section = merged.find(name);
        if (section == nullptr || !section->is_object()) {
            return make_error(ConfigErrorCode::not_object, name, std::string("便携配置 ") + name + " 必须是对象。");
        }
    }
    const Value* channels_value = merged.find("channels");
    if (channels_value == nullptr || !channels_value->is_array()) {
        return make_error(ConfigErrorCode::invalid_format, "channels", "便携配置 channels 必须是有序数组。");
    }

    // connection
    const Value& connection = *merged.find("connection");
    const Value* callsign = connection.find("callsign");
    const Value* master = connection.find("master");
    const Value* password = connection.find("password");
    const Value* api_key = connection.find("api_key");
    if (callsign == nullptr || !callsign->is_string() ||
        (!callsign->text.empty() && !ps_anchored_match(callsign->text, is_callsign)) ||
        master == nullptr || !master->is_string() ||
        (!master->text.empty() && (utf16_len(master->text) > 253 || contains_whitespace(master->text))) ||
        password == nullptr || !password->is_string() || utf16_len(password->text) > 4096 ||
        api_key == nullptr || !api_key->is_string() || utf16_len(api_key->text) > 8192) {
        return make_error(ConfigErrorCode::invalid_format, "connection", "connection 字段格式无效。");
    }
    config.connection.callsign = callsign->text;
    config.connection.master = master->text;
    config.connection.password = password->text;
    config.connection.api_key = api_key->text;
    const auto gateway = to_unsigned(connection.find("gateway_id"), "connection.gateway_id", 4294967295ULL, true);
    if (!gateway) return gateway.error();
    const auto source = to_unsigned(connection.find("source_id"), "connection.source_id", 16777215ULL, true);
    if (!source) return source.error();
    const auto port = to_unsigned(connection.find("master_port"), "connection.master_port", 65535ULL, true);
    if (!port) return port.error();
    const auto color = to_unsigned(connection.find("color_code"), "connection.color_code", 15ULL, true);
    if (!color) return color.error();
    config.connection.gateway_id = static_cast<std::uint32_t>(gateway.value());
    config.connection.source_id = static_cast<std::uint32_t>(source.value());
    config.connection.master_port = static_cast<std::uint16_t>(port.value());
    config.connection.color_code = static_cast<std::uint8_t>(color.value());

    // devices
    const Value& devices = *merged.find("devices");
    for (const char* name : {"serial_port", "hri_port", "cat_port"}) {
        const Value* value = devices.find(name);
        if (value == nullptr || !value->is_string() ||
            (value->text != "auto" && !ps_anchored_match(value->text, is_com_port))) {
            return make_error(ConfigErrorCode::invalid_format, std::string("devices.") + name,
                std::string("devices.") + name + " 必须是 auto 或 COM1 到 COM999。");
        }
    }
    // Validated values are already "auto" or upper-case, so ToUpperInvariant is a no-op.
    config.devices.hri_port = devices.find("hri_port")->text;
    config.devices.cat_port = devices.find("cat_port")->text;
    for (const char* name : {"wave_in_endpoint_id", "wave_out_endpoint_id"}) {
        const Value* value = devices.find(name);
        if (value == nullptr || !value->is_string() || is_null_or_whitespace(value->text) ||
            utf16_len(value->text) > 4096) {
            return make_error(ConfigErrorCode::invalid_format, std::string("devices.") + name,
                std::string("devices.") + name + " 字段格式无效。");
        }
    }
    config.devices.wave_in_endpoint_id = devices.find("wave_in_endpoint_id")->text;
    config.devices.wave_out_endpoint_id = devices.find("wave_out_endpoint_id")->text;
    const auto baud = to_unsigned(devices.find("cat_baud_rate"), "devices.cat_baud_rate", 115200ULL, false);
    if (!baud) return baud.error();
    const Value* stop_bits = devices.find("cat_stop_bits");
    const std::uint64_t b = baud.value();
    if ((b != 4800 && b != 9600 && b != 19200 && b != 38400 && b != 115200) || stop_bits == nullptr ||
        !stop_bits->is_string() || stop_bits->text != "Two") {
        return make_error(ConfigErrorCode::invalid_format, "devices.cat_baud_rate", "CAT 串口设置无效；停止位固定为 Two。");
    }
    config.devices.cat_baud_rate = static_cast<std::uint32_t>(b);
    const auto power = to_unsigned(devices.find("desired_power_watts"), "devices.desired_power_watts", 50ULL, false);
    if (!power) return power.error();
    if (power.value() < 5) return out_of_range("devices.desired_power_watts");
    config.devices.desired_power_watts = static_cast<std::uint32_t>(power.value());

    // audio
    const Value& audio = *merged.find("audio");
    const auto playback = to_gain(audio.find("radio_playback_gain"), "audio.radio_playback_gain");
    if (!playback) return playback.error();
    const auto mic = to_gain(audio.find("mic_transmit_gain"), "audio.mic_transmit_gain");
    if (!mic) return mic.error();
    config.audio.radio_playback_gain_milli = playback.value().milli;
    config.audio.mic_transmit_gain_milli = mic.value().milli;

    // channels
    if (channels_value->items.size() > config_max_channels) {
        return make_error(ConfigErrorCode::out_of_range, "channels", "频道数量超出允许范围。");
    }
    std::set<std::string> seen_channels;
    for (const Value& channel : channels_value->items) {
        if (!channel.is_object()) return make_error(ConfigErrorCode::not_object, "channels", "频道项目必须是对象。");
        for (const char* name : {"id", "kind", "slot", "name"}) {
            if (channel.find(name) == nullptr) {
                return make_error(ConfigErrorCode::missing_required_field, std::string("channels.") + name,
                    std::string("频道项目缺少字段 ") + name + "。");
            }
        }
        const auto id = to_unsigned(channel.find("id"), "channel.id", 16777215ULL, false);
        if (!id) return id.error();
        const auto slot = to_unsigned(channel.find("slot"), "channel.slot", 2ULL, false);
        if (!slot) return slot.error();
        const Value& kind = *channel.find("kind");
        const Value& name = *channel.find("name");
        if (!kind.is_string() || (kind.text != "group" && kind.text != "private") || !name.is_string() ||
            is_null_or_whitespace(name.text) || utf16_len(name.text) > 40 || contains_other_category(name.text)) {
            return make_error(ConfigErrorCode::invalid_format, "channels", "频道项目字段格式无效。");
        }
        ChannelConfig typed;
        typed.id = static_cast<std::uint32_t>(id.value());
        typed.kind = kind.text == "group" ? ChannelKind::group : ChannelKind::private_call;
        typed.slot = static_cast<std::uint8_t>(slot.value());
        typed.name = name.text;
        if (!seen_channels.insert(typed.key()).second) {
            return make_error(ConfigErrorCode::duplicate_entry, "channels", "频道列表存在重复的类型、ID 和时隙。");
        }
        config.channels.push_back(std::move(typed));
    }
    const Value* tx = merged.find("tx_channel_id");
    if (tx == nullptr || !tx->is_string()) {
        return make_error(ConfigErrorCode::invalid_format, "tx_channel_id", "tx_channel_id 必须是频道 tuple key 字符串。");
    }
    config.tx_channel_id = tx->text;
    if (config.channels.empty() && !config.tx_channel_id.empty()) {
        return make_error(ConfigErrorCode::invalid_format, "tx_channel_id", "频道列表为空时 tx_channel_id 必须为空。");
    }
    if (!config.channels.empty() && config.tx_channel_id.empty()) config.tx_channel_id = config.channels.front().key();
    if (!config.tx_channel_id.empty() && seen_channels.count(config.tx_channel_id) == 0) {
        return make_error(ConfigErrorCode::invalid_format, "tx_channel_id", "tx_channel_id 没有对应的频道项目。");
    }

    // routing
    const Value* blocked = merged.find("routing")->find("blocked_source_ids");
    if (blocked == nullptr || !blocked->is_array()) {
        return make_error(ConfigErrorCode::invalid_format, "routing.blocked_source_ids", "routing.blocked_source_ids 必须是数组。");
    }
    std::set<std::uint32_t> seen_blocked;
    for (const Value& item : blocked->items) {
        const auto id = to_unsigned(&item, "routing.blocked_source_ids", 16777215ULL, false);
        if (!id) return id.error();
        const auto narrow = static_cast<std::uint32_t>(id.value());
        if (!seen_blocked.insert(narrow).second) {
            return make_error(ConfigErrorCode::duplicate_entry, "routing.blocked_source_ids", "routing.blocked_source_ids 存在重复 ID。");
        }
        config.routing.blocked_source_ids.push_back(narrow);
    }

    // ui
    const Value& ui = *merged.find("ui");
    const Value* selection = ui.find("bm_server_selection_id");
    if (selection == nullptr || !selection->is_string() ||
        (!selection->text.empty() && !ps_anchored_match(selection->text, is_server_selection))) {
        return make_error(ConfigErrorCode::invalid_format, "ui.bm_server_selection_id", "ui.bm_server_selection_id 字段格式无效。");
    }
    config.ui.bm_server_selection_id = selection->text;
    const Value* legacy = ui.find("legacy_rx_policy");
    if (legacy != nullptr && !legacy->is_null() && !legacy->is_object()) {
        return make_error(ConfigErrorCode::not_object, "ui.legacy_rx_policy", "ui.legacy_rx_policy 必须是对象或 null。");
    }
    config.ui.legacy_rx_policy = legacy != nullptr ? *legacy : Value::null();
    const Value* language = ui.find("language");
    if (language == nullptr || !language->is_string() || (language->text != "zh-CN" && language->text != "en-US")) {
        return make_error(ConfigErrorCode::invalid_format, "ui.language", "ui.language 只接受 zh-CN 或 en-US。");
    }
    config.ui.language = language->text;
    config.window = *merged.find("window");

    // relay（可选根节，R130）：缺省或缺字段为 false；存在时必须是对象且已知字段为布尔值，其它成员原样保留。
    if (const Value* relay = merged.find("relay")) {
        if (!relay->is_object()) {
            return make_error(ConfigErrorCode::not_object, "relay", "便携配置 relay 必须是对象。");
        }
        const auto relay_flag = [&](const char* key, bool& out) -> std::optional<ConfigError> {
            const Value* flag = relay->find(key);
            if (flag == nullptr) return std::nullopt;
            if (!flag->is_bool()) {
                return ConfigError{ConfigErrorCode::invalid_value, std::string("relay.") + key,
                                   std::string("relay.") + key + " 必须是 true 或 false。"};
            }
            out = flag->boolean_value;
            return std::nullopt;
        };
        if (auto error = relay_flag("enabled", config.relay.enabled)) return *error;
        if (auto error = relay_flag("fm_enabled", config.relay.fm_enabled)) return *error;
    }

    if (has_credential_path_key(merged)) {
        return make_error(ConfigErrorCode::credential_path_field, {}, "config.json 不能保存凭据文件路径；请把凭据值存入 connection。");
    }

    // Normalized document: same values PowerShell assigns back into $merged.
    const Value original = merged;
    write_typed(merged, config, &original);
    // PS writes the gain as the parsed decimal, preserving its scale.
    merged.find("audio")->set("radio_playback_gain", Value::number_literal(playback.value().literal));
    merged.find("audio")->set("mic_transmit_gain", Value::number_literal(mic.value().literal));
    config.document = std::move(merged);
    return config;
}

// ---------------------------------------------------------------------------
// File I/O

std::wstring absolute_path(const std::filesystem::path& path)
{
    std::error_code error;
    const auto absolute = std::filesystem::absolute(path, error);
    return (error ? path : absolute).lexically_normal().wstring();
}

class Handle {
public:
    explicit Handle(HANDLE handle) noexcept : handle_(handle) {}
    ~Handle() { if (valid()) CloseHandle(handle_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    [[nodiscard]] bool valid() const noexcept { return handle_ != INVALID_HANDLE_VALUE && handle_ != nullptr; }
    [[nodiscard]] HANDLE get() const noexcept { return handle_; }
private:
    HANDLE handle_;
};

bool file_exists(const std::wstring& path)
{
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool directory_exists(const std::wstring& path)
{
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

enum class ReadStatus : std::uint8_t { ok, missing, too_large, failed };

ReadStatus read_file(const std::wstring& path, std::string& bytes)
{
    Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!file.valid()) {
        const DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? ReadStatus::missing : ReadStatus::failed;
    }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file.get(), &size)) return ReadStatus::failed;
    if (size.QuadPart > static_cast<LONGLONG>(config_max_bytes)) return ReadStatus::too_large;
    bytes.assign(static_cast<std::size_t>(size.QuadPart), '\0');
    std::size_t total = 0;
    while (total < bytes.size()) {
        DWORD read = 0;
        if (!ReadFile(file.get(), bytes.data() + total, static_cast<DWORD>(bytes.size() - total), &read, nullptr)) {
            return ReadStatus::failed;
        }
        if (read == 0) break;
        total += read;
    }
    char extra = 0;
    DWORD extra_read = 0;
    if (total != bytes.size() || (ReadFile(file.get(), &extra, 1, &extra_read, nullptr) && extra_read != 0)) {
        return ReadStatus::failed;  // file changed while being read
    }
    return ReadStatus::ok;
}

bool write_new_file(const std::wstring& path, std::string_view bytes)
{
    Handle file(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!file.valid()) return false;
    std::size_t total = 0;
    while (total < bytes.size()) {
        DWORD written = 0;
        if (!WriteFile(file.get(), bytes.data() + total, static_cast<DWORD>(bytes.size() - total), &written, nullptr) ||
            written == 0) {
            return false;
        }
        total += written;
    }
    return FlushFileBuffers(file.get()) != 0;
}

std::wstring unique_suffix()
{
    GUID guid{};
    if (FAILED(CoCreateGuid(&guid))) {
        return std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
    }
    std::array<wchar_t, 40> text{};
    std::swprintf(text.data(), text.size(), L"%08lx%04x%04x%02x%02x%02x%02x%02x%02x%02x%02x", guid.Data1, guid.Data2,
        guid.Data3, guid.Data4[0], guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],
        guid.Data4[6], guid.Data4[7]);
    return text.data();
}

ConfigError io_error(std::string message) { return make_error(ConfigErrorCode::io_error, {}, std::move(message)); }

struct RawFile {
    std::string bytes{};
    Value document{};
};

// Read-WirexPortableConfigFile up to (and including) the stored-shape check.
Result<RawFile, ConfigError> read_raw(const std::wstring& path)
{
    RawFile raw;
    switch (read_file(path, raw.bytes)) {
    case ReadStatus::ok: break;
    case ReadStatus::missing: return make_error(ConfigErrorCode::file_not_found, {}, "config.json 不存在。");
    case ReadStatus::too_large: return make_error(ConfigErrorCode::too_large, {}, "config.json 超过 128 KiB；原文件已保留。");
    case ReadStatus::failed: return io_error("config.json 无法读取；原文件已保留。");
    }
    const json::ParseResult parsed = json::parse(raw.bytes, raw.document);
    switch (parsed.error) {
    case json::ParseError::none: break;
    case json::ParseError::duplicate_key:
        return make_error(ConfigErrorCode::duplicate_key, {}, "config.json 存在重复字段；原文件已保留。");
    case json::ParseError::escaped_key:
        return make_error(ConfigErrorCode::escaped_key, {}, "config.json 字段名不能使用转义写法；原文件已保留。");
    default:
        return make_error(ConfigErrorCode::invalid_json, {}, "config.json JSON 无效；原文件已保留。");
    }
    if (auto shape_error = check_stored_shape(raw.document)) return *shape_error;
    return raw;
}

// Writes bytes to a temp file next to `path` and atomically installs it.
// allow_replace=false never overwrites a file that appeared concurrently.
std::optional<ConfigError> install_atomically(const std::wstring& path, const std::string& bytes,
    const std::wstring& temp_tag, bool allow_replace, const char* failure_message)
{
    const std::wstring temporary = path + temp_tag + unique_suffix();
    if (!write_new_file(temporary, bytes)) {
        DeleteFileW(temporary.c_str());
        return io_error(failure_message);
    }
    std::optional<ConfigError> result;
    if (allow_replace && file_exists(path)) {
        SYSTEMTIME now{};
        GetSystemTime(&now);
        std::array<wchar_t, 32> stamp{};
        std::swprintf(stamp.data(), stamp.size(), L"%04u%02u%02uT%02u%02u%02u%03uZ", now.wYear, now.wMonth, now.wDay,
            now.wHour, now.wMinute, now.wSecond, now.wMilliseconds);
        const std::wstring backup = path + L".backup-" + stamp.data() + L"-" + unique_suffix();
        if (ReplaceFileW(path.c_str(), temporary.c_str(), backup.c_str(), REPLACEFILE_IGNORE_MERGE_ERRORS, nullptr, nullptr)) {
            DeleteFileW(backup.c_str());
        } else {
            const DWORD error = GetLastError();
            // 1177: the original was moved to the backup name and the new file
            // could not be installed; put the original back.
            if (error == ERROR_UNABLE_TO_MOVE_REPLACEMENT_2 && !file_exists(path) && file_exists(backup)) {
                MoveFileExW(backup.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH);
            }
            result = io_error(failure_message);
        }
    } else if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH)) {
        const DWORD error = GetLastError();
        if (allow_replace || (error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS)) {
            result = io_error(failure_message);
        }
    }
    if (file_exists(temporary)) DeleteFileW(temporary.c_str());
    return result;
}

std::wstring parent_directory(const std::wstring& path)
{
    return std::filesystem::path(path).parent_path().wstring();
}

} // namespace

std::string ChannelConfig::key() const
{
    return channel_kind_name(kind) + ":" + std::to_string(id) + ":" + std::to_string(slot);
}

std::string channel_kind_name(ChannelKind kind) { return kind == ChannelKind::group ? "group" : "private"; }

std::string format_gain_milli(std::uint32_t milli)
{
    std::string text = std::to_string(milli / 1000U);
    std::uint32_t fraction = milli % 1000U;
    if (fraction != 0) {
        std::array<char, 8> digits{};
        std::snprintf(digits.data(), digits.size(), "%03u", fraction);
        std::string part = digits.data();
        while (!part.empty() && part.back() == '0') part.pop_back();
        text += "." + part;
    }
    return text;
}

AppConfig default_config()
{
    auto result = validate(default_document());
    return std::move(result).value();  // the built-in defaults always validate
}

ConfigResult<AppConfig> from_document(const json::Value& document)
{
    try {
        return validate(document);
    } catch (const std::exception&) {
        return make_error(ConfigErrorCode::io_error, {}, "config.json 处理失败（内存不足或内部错误）。");
    }
}

ConfigResult<AppConfig> parse_text(std::string_view json_text)
{
    if (json_text.size() > config_max_bytes) {
        return make_error(ConfigErrorCode::too_large, {}, "config.json 超过 128 KiB；原文件已保留。");
    }
    Value document;
    const json::ParseResult parsed = json::parse(json_text, document);
    if (parsed.error == json::ParseError::duplicate_key) {
        return make_error(ConfigErrorCode::duplicate_key, {}, "config.json 存在重复字段；原文件已保留。");
    }
    if (parsed.error == json::ParseError::escaped_key) {
        return make_error(ConfigErrorCode::escaped_key, {}, "config.json 字段名不能使用转义写法；原文件已保留。");
    }
    if (!parsed.ok()) return make_error(ConfigErrorCode::invalid_json, {}, "config.json JSON 无效；原文件已保留。");
    if (auto shape_error = check_stored_shape(document)) return *shape_error;
    return from_document(document);
}

json::Value to_document(const AppConfig& config)
{
    Value doc = merge_objects(default_document(), config.document.is_object() ? config.document : default_document());
    write_typed(doc, config, config.document.is_object() ? &config.document : nullptr);
    return doc;
}

std::string serialize_config(const json::Value& document)
{
    return json::serialize(document) + "\n";
}

ConfigResult<AppConfig> load(const std::filesystem::path& path)
{
    try {
        auto raw = read_raw(absolute_path(path));
        if (!raw) return raw.error();
        return validate(raw.value().document);
    } catch (const std::exception&) {
        return io_error("config.json 无法读取；原文件已保留。");
    }
}

ConfigResult<AppConfig> save(const std::filesystem::path& path, const AppConfig& config, SaveOptions options)
{
    try {
        const std::wstring full = absolute_path(path);
        if (!directory_exists(parent_directory(full))) {
            return make_error(ConfigErrorCode::directory_missing, {}, "config.json 所在目录不存在；没有写入配置。");
        }
        Value base = default_document();
        bool existing_has_language = false;
        auto raw = read_raw(full);
        if (raw) {
            auto existing = validate(raw.value().document);
            if (!existing) return existing.error();
            base = std::move(existing.value().document);
            const Value* raw_ui = raw.value().document.find("ui");
            existing_has_language = raw_ui != nullptr && raw_ui->find("language") != nullptr;
        } else if (raw.error().code != ConfigErrorCode::file_not_found) {
            return raw.error();
        }
        auto validated = validate(merge_objects(base, to_document(config)));
        if (!validated) return validated.error();
        AppConfig result = std::move(validated.value());
        if (!options.persist_ui_language && !existing_has_language) result.document.find("ui")->erase("language");
        const std::string bytes = serialize_config(result.document);
        if (bytes.size() > config_max_bytes) {
            return make_error(ConfigErrorCode::too_large, {}, "config.json 超过 128 KiB；没有写入配置。");
        }
        if (auto error = install_atomically(full, bytes, L".backup-tmp-", true, "config.json 无法写入；原文件已保留。")) {
            return *error;
        }
        return result;
    } catch (const std::exception&) {
        return io_error("config.json 无法写入；原文件已保留。");
    }
}

ConfigResult<AppConfig> set_language(const std::filesystem::path& path, std::string_view language)
{
    try {
        if (language != "zh-CN" && language != "en-US") {
            return make_error(ConfigErrorCode::invalid_format, "ui.language", "ui.language 只接受 zh-CN 或 en-US。");
        }
        const std::wstring full = absolute_path(path);
        auto raw = read_raw(full);
        if (!raw) {
            if (raw.error().code == ConfigErrorCode::file_not_found) {
                return make_error(ConfigErrorCode::file_not_found, {}, "config.json 尚未初始化；没有写入语言设置。");
            }
            return raw.error();
        }
        if (auto existing = validate(raw.value().document); !existing) return existing.error();
        Value document = std::move(raw.value().document);
        document.find("ui")->set("language", Value::string(std::string(language)));
        if (auto checked = validate(document); !checked) return checked.error();
        const std::string bytes = serialize_config(document);
        if (bytes.size() > config_max_bytes) {
            return make_error(ConfigErrorCode::too_large, {}, "config.json 超过 128 KiB；没有写入语言设置。");
        }
        if (auto error = install_atomically(full, bytes, L".language-tmp-", true, "config.json 无法写入；原文件已保留。")) {
            return *error;
        }
        return load(full);
    } catch (const std::exception&) {
        return io_error("config.json 无法写入；原文件已保留。");
    }
}

ConfigResult<AppConfig> create_default(const std::filesystem::path& path)
{
    try {
        const std::wstring full = absolute_path(path);
        if (!directory_exists(parent_directory(full))) {
            return make_error(ConfigErrorCode::directory_missing, {}, "便携配置目录不存在或无法访问；没有启动 WIREX Bridge。");
        }
        if (!file_exists(full)) {
            const std::string bytes = serialize_config(default_config().document);
            if (auto error = install_atomically(full, bytes, L".init-", false,
                    "无法创建或验证 config.json；请检查便携目录的写入权限。没有启动 WIREX Bridge。")) {
                return *error;
            }
        }
        return load(full);
    } catch (const std::exception&) {
        return io_error("无法创建或验证 config.json；请检查便携目录的写入权限。没有启动 WIREX Bridge。");
    }
}

} // namespace wirex::app
