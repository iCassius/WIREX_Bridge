#include "wirex/app/radio_identity.hpp"

#include "wirex/radio_identity_cache.hpp"
#include "wirex/app/json.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <random>
#include <unordered_set>

namespace wirex::app::radio_identity {
namespace {

using json::Value;
constexpr json::ParseOptions response_options{false};

bool is_space(char ch) noexcept
{
    return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '\v' || ch == '\f';
}

std::string_view trim(std::string_view text) noexcept
{
    while (!text.empty() && is_space(text.front())) text.remove_prefix(1U);
    while (!text.empty() && is_space(text.back())) text.remove_suffix(1U);
    return text;
}

std::string_view strip_bom(std::string_view text) noexcept
{
    if (text.size() >= 3U && static_cast<unsigned char>(text[0]) == 0xefU &&
        static_cast<unsigned char>(text[1]) == 0xbbU && static_cast<unsigned char>(text[2]) == 0xbfU) {
        text.remove_prefix(3U);
    }
    return text;
}

char ascii_lower(char ch) noexcept
{
    return ch >= 'A' && ch <= 'Z' ? static_cast<char>(ch - 'A' + 'a') : ch;
}

// PowerShell 的 [string]$value：字符串原样；整数/小数字面量保持原文（PS 5.1 实测 460997.0 → "460997.0"，
// -3 → "-3"）；指数写法会被 PS 规范化（1e2 → "100"），此处视为缺失；bool → True/False。
std::optional<std::string> value_text(const Value* value)
{
    if (value == nullptr) return std::nullopt;
    if (value->type == Value::Type::string) return value->text;
    if (value->type == Value::Type::number) {
        if (value->text.find_first_of("eE") != std::string::npos) return std::nullopt;
        return value->text;
    }
    if (value->type == Value::Type::boolean) return std::string(value->boolean_value ? "True" : "False");
    return std::nullopt;
}

// [uint32]::TryParse([string]x, NumberStyles.None)
std::optional<std::uint32_t> value_uint32(const Value* value)
{
    const auto text = value_text(value);
    if (!text || text->empty()) return std::nullopt;
    std::uint64_t number = 0U;
    for (const char ch : *text) {
        if (ch < '0' || ch > '9') return std::nullopt;
        number = number * 10U + static_cast<std::uint64_t>(ch - '0');
        if (number > 0xffffffffULL) return std::nullopt;
    }
    return static_cast<std::uint32_t>(number);
}

std::optional<std::string> field_text(const Value& object, std::string_view key)
{
    const auto raw = value_text(object.find(key));
    if (!raw) return std::nullopt;
    return sanitize_text(*raw);
}

std::int64_t days_from_civil(std::int64_t y, unsigned m, unsigned d) noexcept
{
    y -= m <= 2U ? 1 : 0;
    const std::int64_t era = (y >= 0 ? y : y - 399) / 400;
    const auto yoe = static_cast<unsigned>(y - era * 400);
    const unsigned doy = (153U * (m + (m > 2U ? static_cast<unsigned>(-3) : 9U)) + 2U) / 5U + d - 1U;
    const unsigned doe = yoe * 365U + yoe / 4U - yoe / 100U + doy;
    return era * 146097 + static_cast<std::int64_t>(doe) - 719468;
}

void civil_from_days(std::int64_t z, std::int64_t& y, unsigned& m, unsigned& d) noexcept
{
    z += 719468;
    const std::int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    const auto doe = static_cast<unsigned>(z - era * 146097);
    const unsigned yoe = (doe - doe / 1460U + doe / 36524U - doe / 146096U) / 365U;
    y = static_cast<std::int64_t>(yoe) + era * 400;
    const unsigned doy = doe - (365U * yoe + yoe / 4U - yoe / 100U);
    const unsigned mp = (5U * doy + 2U) / 153U;
    d = doy - (153U * mp + 2U) / 5U + 1U;
    m = mp < 10U ? mp + 3U : mp - 9U;
    y += m <= 2U ? 1 : 0;
}

void append_json_string(std::string& out, const std::string& text)
{
    out.push_back('"');
    for (const char ch : text) {
        const auto byte = static_cast<unsigned char>(ch);
        switch (ch) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (byte < 0x20U || byte == 0x7fU) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x", static_cast<unsigned>(byte));
                out += buffer;
            } else {
                out.push_back(ch);
            }
        }
    }
    out.push_back('"');
}

void append_optional(std::string& out, const char* key, const std::optional<std::string>& value, bool last = false)
{
    out += "      \"";
    out += key;
    out += "\": ";
    if (value) append_json_string(out, *value);
    else out += "null";
    out += last ? "\n" : ",\n";
}

enum class ReadOutcome { missing, ok, unreadable };

ReadOutcome read_cache_file(const std::filesystem::path& path, std::vector<CacheEntry>& entries)
{
    entries.clear();
    std::error_code ec;
    if (!std::filesystem::is_regular_file(path, ec)) return ReadOutcome::missing;
    const auto size = std::filesystem::file_size(path, ec);
    if (ec || size > max_cache_file_bytes) return ReadOutcome::unreadable;
    std::string content;
    try {
        std::ifstream stream(path, std::ios::binary);
        if (!stream) return ReadOutcome::unreadable;
        content.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
        if (stream.bad()) return ReadOutcome::unreadable;
    } catch (...) {
        return ReadOutcome::unreadable;
    }
    const auto text = trim(strip_bom(content));
    return parse_cache_document(text, entries) ? ReadOutcome::ok : ReadOutcome::unreadable;
}

Result fallback(std::uint32_t id, const std::filesystem::path& path, std::string code, std::string message,
                std::string type, std::string detail)
{
    Result result{};
    const auto entry = find_cache_entry(path, id);
    if (entry) {
        result = make_result(id, &*entry, Status::stale);
    } else {
        result = make_result(id, nullptr, Status::unavailable);
        result.source = std::string(source_name);
    }
    result.error_code = std::move(code);
    result.error_message = std::move(message);
    result.error_type = std::move(type);
    result.error_detail = std::move(detail);
    return result;
}

} // namespace

std::string_view to_string(Status status) noexcept
{
    switch (status) {
    case Status::found: return "found";
    case Status::not_found: return "not_found";
    case Status::stale: return "stale";
    case Status::unavailable: return "unavailable";
    }
    return "unavailable";
}

std::optional<Status> parse_status(std::string_view text) noexcept
{
    if (text == "found") return Status::found;
    if (text == "not_found") return Status::not_found;
    if (text == "stale") return Status::stale;
    if (text == "unavailable") return Status::unavailable;
    return std::nullopt;
}

bool is_valid_radio_id(std::uint32_t id) noexcept
{
    return id >= 1U && id <= max_radio_id;
}

std::filesystem::path cache_path(const std::filesystem::path& user_config_directory)
{
    return user_config_directory / std::string(cache_file_name);
}

std::optional<std::string> sanitize_text(std::string_view value)
{
    std::string cleaned;
    cleaned.reserve(value.size());
    for (const char ch : value) {
        const auto byte = static_cast<unsigned char>(ch);
        if (byte < 0x20U || byte == 0x7fU) continue;
        cleaned.push_back(ch);
    }
    const auto trimmed = trim(cleaned);
    if (trimmed.empty()) return std::nullopt;
    // 按 UTF-16 单元截断到 128（与 .NET Substring 一致），但不拆分 UTF-8 序列或代理对。
    std::size_t units = 0U;
    std::size_t end = 0U;
    while (end < trimmed.size()) {
        const auto lead = static_cast<unsigned char>(trimmed[end]);
        std::size_t length = 1U;
        std::size_t cost = 1U;
        if (lead >= 0xf0U) { length = 4U; cost = 2U; }
        else if (lead >= 0xe0U) length = 3U;
        else if (lead >= 0xc0U) length = 2U;
        if (units + cost > max_text_units) break;
        units += cost;
        end = std::min(trimmed.size(), end + length);
    }
    return std::string(trimmed.substr(0U, end));
}

std::optional<std::string> native_callsign(std::string_view value)
{
    const auto callsign = trim(value);
    if (callsign.empty() || callsign.size() > radio_identity_cache::max_callsign_bytes) return std::nullopt;
    std::string upper;
    upper.reserve(callsign.size());
    for (const char ch : callsign) {
        upper.push_back(ch >= 'a' && ch <= 'z' ? static_cast<char>(ch - 'a' + 'A') : ch);
    }
    if (!radio_identity_cache::Cache::is_valid_callsign(upper)) return std::nullopt;
    return upper;
}

std::optional<TimePoint> parse_timestamp(std::string_view text) noexcept
{
    text = trim(text);
    const auto digits = [&](std::size_t pos, std::size_t count, unsigned& out) {
        if (pos + count > text.size()) return false;
        out = 0U;
        for (std::size_t i = pos; i < pos + count; ++i) {
            if (text[i] < '0' || text[i] > '9') return false;
            out = out * 10U + static_cast<unsigned>(text[i] - '0');
        }
        return true;
    };
    unsigned year{}, month{}, day{}, hour{}, minute{}, second{};
    if (!digits(0U, 4U, year) || text.size() < 19U || text[4] != '-' || !digits(5U, 2U, month) || text[7] != '-' ||
        !digits(8U, 2U, day) || (text[10] != 'T' && text[10] != 't' && text[10] != ' ') ||
        !digits(11U, 2U, hour) || text[13] != ':' || !digits(14U, 2U, minute) || text[16] != ':' ||
        !digits(17U, 2U, second)) {
        return std::nullopt;
    }
    if (month < 1U || month > 12U || day < 1U || day > 31U || hour > 23U || minute > 59U || second > 59U) {
        return std::nullopt;
    }
    std::size_t pos = 19U;
    std::int64_t ticks = 0;   // 100 ns
    if (pos < text.size() && text[pos] == '.') {
        ++pos;
        std::size_t count = 0U;
        std::int64_t scale = 1000000;
        while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') {
            if (count < 7U) {
                ticks += static_cast<std::int64_t>(text[pos] - '0') * scale;
                scale /= 10;
            }
            ++count;
            ++pos;
        }
        if (count == 0U) return std::nullopt;
    }
    std::int64_t offset_minutes = 0;
    if (pos < text.size()) {
        if (text[pos] == 'Z' || text[pos] == 'z') {
            ++pos;
        } else if (text[pos] == '+' || text[pos] == '-') {
            const bool negative = text[pos] == '-';
            unsigned oh{}, om{};
            if (!digits(pos + 1U, 2U, oh) || pos + 3U >= text.size() || text[pos + 3U] != ':' ||
                !digits(pos + 4U, 2U, om) || oh > 14U || om > 59U) {
                return std::nullopt;
            }
            offset_minutes = static_cast<std::int64_t>(oh) * 60 + om;
            if (negative) offset_minutes = -offset_minutes;
            pos += 6U;
        } else {
            return std::nullopt;
        }
    }
    if (pos != text.size()) return std::nullopt;
    const auto days = days_from_civil(static_cast<std::int64_t>(year), month, day);
    std::int64_t seconds = days * 86400 + static_cast<std::int64_t>(hour) * 3600 +
        static_cast<std::int64_t>(minute) * 60 + second - offset_minutes * 60;
    const auto since_epoch = std::chrono::seconds(seconds) + std::chrono::duration<std::int64_t, std::ratio<1, 10000000>>(ticks);
    return TimePoint(std::chrono::duration_cast<Clock::duration>(since_epoch));
}

std::string format_timestamp(TimePoint time)
{
    using Ticks = std::chrono::duration<std::int64_t, std::ratio<1, 10000000>>;
    const auto total = std::chrono::duration_cast<Ticks>(time.time_since_epoch()).count();
    std::int64_t seconds = total / 10000000;
    std::int64_t fraction = total % 10000000;
    if (fraction < 0) { fraction += 10000000; --seconds; }
    std::int64_t days = seconds / 86400;
    std::int64_t rem = seconds % 86400;
    if (rem < 0) { rem += 86400; --days; }
    std::int64_t year{};
    unsigned month{}, day{};
    civil_from_days(days, year, month, day);
    char buffer[48];
    std::snprintf(buffer, sizeof(buffer), "%04lld-%02u-%02uT%02lld:%02lld:%02lld.%07lld+00:00",
                  static_cast<long long>(year), month, day, static_cast<long long>(rem / 3600),
                  static_cast<long long>((rem / 60) % 60), static_cast<long long>(rem % 60),
                  static_cast<long long>(fraction));
    return buffer;
}

std::string build_query_url(std::string_view base_uri, std::uint32_t id)
{
    while (!base_uri.empty() && base_uri.back() == '/') base_uri.remove_suffix(1U);
    std::string url(base_uri);
    url += "/?id=";
    url += std::to_string(id);
    url += "&id_sel=%3D";
    return url;
}

bool is_allowed_base_uri(std::string_view base_uri) noexcept
{
    if (base_uri == official_base_uri) return true;
    // 本机回环 HTTP 测试夹具：http://127.x.x.x[:port]/... 或 http://localhost / [::1]，不得带 userinfo。
    constexpr std::string_view http = "http://";
    if (base_uri.size() <= http.size()) return false;
    for (std::size_t i = 0U; i < http.size(); ++i) if (ascii_lower(base_uri[i]) != http[i]) return false;
    auto authority = base_uri.substr(http.size());
    const auto slash = authority.find('/');
    if (slash != std::string_view::npos) authority = authority.substr(0U, slash);
    if (authority.empty() || authority.find('@') != std::string_view::npos) return false;
    std::string_view host = authority;
    if (host.front() == '[') {
        const auto close = host.find(']');
        if (close == std::string_view::npos) return false;
        host = host.substr(0U, close + 1U);
    } else {
        const auto colon = host.find(':');
        if (colon != std::string_view::npos) host = host.substr(0U, colon);
    }
    std::string lowered;
    for (const char ch : host) lowered.push_back(ascii_lower(ch));
    if (lowered == "localhost" || lowered == "[::1]") return true;
    if (lowered.rfind("127.", 0U) != 0U) return false;
    for (const char ch : lowered) if (!(ch == '.' || (ch >= '0' && ch <= '9'))) return false;
    return true;
}

bool is_valid_user_agent(std::string_view agent) noexcept
{
    std::string lowered;
    for (const char ch : agent) lowered.push_back(ascii_lower(ch));
    // (?i)WIREX\s+Bridge
    bool product = false;
    for (std::size_t pos = lowered.find("wirex"); pos != std::string::npos; pos = lowered.find("wirex", pos + 1U)) {
        std::size_t i = pos + 5U;
        std::size_t spaces = 0U;
        while (i < lowered.size() && is_space(lowered[i])) { ++i; ++spaces; }
        if (spaces > 0U && lowered.compare(i, 6U, "bridge") == 0) { product = true; break; }
    }
    // (?i)contact\s*:
    bool contact = false;
    for (std::size_t pos = lowered.find("contact"); pos != std::string::npos; pos = lowered.find("contact", pos + 1U)) {
        std::size_t i = pos + 7U;
        while (i < lowered.size() && is_space(lowered[i])) ++i;
        if (i < lowered.size() && lowered[i] == ':') { contact = true; break; }
    }
    return product && contact;
}

ParseResult parse_response(std::string_view body, std::uint32_t requested_id)
{
    ParseResult result{};
    if (body.size() > max_response_bytes) return result;
    Value root{};
    if (!json::parse(trim(strip_bom(body)), root, response_options).ok()) return result;

    std::vector<const Value*> records;
    if (root.type == Value::Type::null_value) {
        return result;
    } else if (root.type == Value::Type::array) {
        for (const auto& item : root.items) records.push_back(&item);
    } else if (root.type == Value::Type::object && root.find("results") != nullptr) {
        const auto* results = root.find("results");
        if (results->type == Value::Type::array) {
            for (const auto& item : results->items) records.push_back(&item);
        } else if (results->type != Value::Type::null_value) {
            return result;
        }
    } else if (root.type == Value::Type::object && (root.find("id") != nullptr || root.find("radio_id") != nullptr)) {
        records.push_back(&root);
    } else {
        return result;
    }

    if (records.empty()) {
        result.state = ParseState::not_found;
        return result;
    }

    std::vector<const Value*> exact;
    std::size_t valid_ids = 0U;
    for (const auto* candidate : records) {
        if (candidate->type != Value::Type::object) continue;
        const Value* raw = candidate->find("id");
        if (raw == nullptr || raw->type == Value::Type::null_value) raw = candidate->find("radio_id");
        const auto id = value_uint32(raw);
        if (!id) continue;
        ++valid_ids;
        if (*id == requested_id) exact.push_back(candidate);
    }
    if (exact.empty()) {
        result.state = valid_ids > 0U ? ParseState::mismatch : ParseState::invalid;
        return result;
    }

    std::vector<ParsedRecord> normalized;
    for (const auto* candidate : exact) {
        ParsedRecord record{};
        record.callsign = field_text(*candidate, "callsign");
        record.name = field_text(*candidate, "name");
        record.city = field_text(*candidate, "city");
        record.state = field_text(*candidate, "state");
        record.country = field_text(*candidate, "country");
        if (!record.name) {
            const auto first = field_text(*candidate, "fname");
            const auto last = field_text(*candidate, "surname");
            if (first && last) record.name = *first + " " + *last;
            else if (first) record.name = first;
            else if (last) record.name = last;
        }
        normalized.push_back(std::move(record));
    }
    const auto same = [](const std::optional<std::string>& a, const std::optional<std::string>& b) {
        return a.value_or(std::string()) == b.value_or(std::string());
    };
    const auto& selected = normalized.front();
    for (std::size_t i = 1U; i < normalized.size(); ++i) {
        const auto& other = normalized[i];
        if (!same(other.callsign, selected.callsign) || !same(other.name, selected.name) ||
            !same(other.city, selected.city) || !same(other.state, selected.state) ||
            !same(other.country, selected.country)) {
            result.state = ParseState::conflict;
            return result;
        }
    }
    result.state = ParseState::found;
    result.record = selected;
    return result;
}

bool is_fresh(const CacheEntry& entry, TimePoint now) noexcept
{
    if (entry.status != "found" && entry.status != "not_found") return false;
    if (!entry.fetched_at_utc) return false;
    const auto fetched = parse_timestamp(*entry.fetched_at_utc);
    if (!fetched) return false;
    if (*fetched > now + future_tolerance) return false;
    const auto ttl = entry.status == "not_found" ? Clock::duration(negative_ttl) : Clock::duration(positive_ttl);
    return now - *fetched < ttl;
}

Result make_result(std::uint32_t id, const CacheEntry* record, Status status)
{
    Result result{};
    result.id = id;
    result.status = status;
    if (record != nullptr) {
        const auto clean = [](const std::optional<std::string>& value) -> std::optional<std::string> {
            return value ? sanitize_text(*value) : std::nullopt;
        };
        result.callsign = clean(record->callsign);
        result.name = clean(record->name);
        result.city = clean(record->city);
        result.state = clean(record->state);
        result.country = clean(record->country);
        result.source = record->source;
        if (record->fetched_at_utc) {
            const auto parsed = parse_timestamp(*record->fetched_at_utc);
            if (parsed) result.fetched_at_utc = format_timestamp(*parsed);
        }
    }
    result.display_name = "DMR ID " + std::to_string(id);
    if (status == Status::found && result.callsign) {
        result.display_name = *result.callsign;
        if (result.name) result.display_name += " (" + *result.name + ")";
    } else if (status == Status::found && result.name) {
        result.display_name = *result.name;
    }
    return result;
}

bool parse_cache_document(std::string_view json, std::vector<CacheEntry>& entries)
{
    entries.clear();
    Value root{};
    if (!json::parse(trim(strip_bom(json)), root, response_options).ok() || root.type != Value::Type::object) return false;
    const auto schema = value_uint32(root.find("schema_version"));
    if (!schema || *schema != 1U) return false;
    const auto* list = root.find("entries");
    if (list == nullptr || list->type == Value::Type::null_value) return false;
    std::vector<const Value*> items;
    if (list->type == Value::Type::array) {
        for (const auto& item : list->items) items.push_back(&item);
    } else {
        items.push_back(list);   // PS 的 @($document.entries) 会把单个对象包成数组
    }
    for (const auto* item : items) {
        if (item->type != Value::Type::object) continue;
        const auto id = value_uint32(item->find("id"));
        if (!id) continue;   // PS 保存时同样丢弃无法解析 ID 的条目
        CacheEntry entry{};
        entry.id = *id;
        entry.callsign = value_text(item->find("callsign"));
        entry.name = value_text(item->find("name"));
        entry.city = value_text(item->find("city"));
        entry.state = value_text(item->find("state"));
        entry.country = value_text(item->find("country"));
        entry.source = value_text(item->find("source"));
        entry.fetched_at_utc = value_text(item->find("fetched_at_utc"));
        entry.status = value_text(item->find("status")).value_or(std::string());
        entries.push_back(std::move(entry));
    }
    return true;
}

std::string serialize_cache_document(const std::vector<CacheEntry>& entries)
{
    std::string out = "{\n  \"schema_version\": 1,\n  \"entries\": [";
    for (std::size_t i = 0U; i < entries.size(); ++i) {
        const auto& entry = entries[i];
        out += i == 0U ? "\n    {\n" : ",\n    {\n";
        out += "      \"id\": " + std::to_string(entry.id) + ",\n";
        append_optional(out, "callsign", entry.callsign);
        append_optional(out, "name", entry.name);
        append_optional(out, "city", entry.city);
        append_optional(out, "state", entry.state);
        append_optional(out, "country", entry.country);
        append_optional(out, "source", entry.source);
        append_optional(out, "fetched_at_utc", entry.fetched_at_utc);
        append_optional(out, "status", entry.status, true);
        out += "    }";
    }
    out += entries.empty() ? "]\n}\n" : "\n  ]\n}\n";
    return out;
}

std::vector<CacheEntry> read_cache(const std::filesystem::path& path)
{
    std::vector<CacheEntry> entries;
    try {
        if (read_cache_file(path, entries) != ReadOutcome::ok) entries.clear();
    } catch (...) {
        entries.clear();
    }
    return entries;
}

std::optional<CacheEntry> find_cache_entry(const std::filesystem::path& path, std::uint32_t id)
{
    for (auto& entry : read_cache(path)) {
        if (entry.id == id) return std::move(entry);
    }
    return std::nullopt;
}

bool save_cache_entry(const std::filesystem::path& path, const CacheEntry& entry, std::string* error)
{
    const auto fail = [&](const char* message) {
        if (error != nullptr) *error = message;
        return false;
    };
    try {
        std::error_code ec;
        const auto full = std::filesystem::absolute(path, ec);
        if (ec) return fail("CachePath 无法解析为完整路径。");
        const auto directory = full.parent_path();
        if (directory.empty() || full.filename().empty()) return fail("CachePath 必须包含父目录。");
        std::filesystem::create_directories(directory, ec);
        if (ec) return fail("无法创建缓存目录。");

        std::vector<CacheEntry> existing;
        (void)read_cache_file(full, existing);
        std::vector<CacheEntry> all;
        all.reserve(existing.size() + 1U);
        all.push_back(entry);
        for (auto& current : existing) {
            if (current.id == entry.id) continue;
            if (all.size() >= cache_entry_limit) break;
            all.push_back(std::move(current));
        }

        const std::string json = "\xEF\xBB\xBF" + serialize_cache_document(all);

        std::random_device random;
        char suffix[40];
        std::snprintf(suffix, sizeof(suffix), "%08x%08x%08x%08x", random(), random(), random(), random());
        const auto temp = directory / (std::string(".radio-identity-cache-") + suffix + ".tmp");
        {
            std::ofstream stream(temp, std::ios::binary | std::ios::trunc);
            if (!stream) return fail("无法写入缓存临时文件。");
            stream.write(json.data(), static_cast<std::streamsize>(json.size()));
            stream.flush();
            if (!stream) {
                stream.close();
                std::filesystem::remove(temp, ec);
                return fail("无法写入缓存临时文件。");
            }
        }

        BOOL moved = FALSE;
        if (std::filesystem::is_regular_file(full, ec)) {
            moved = ReplaceFileW(full.c_str(), temp.c_str(), nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS, nullptr, nullptr);
        } else {
            moved = MoveFileExW(temp.c_str(), full.c_str(), MOVEFILE_WRITE_THROUGH);
        }
        if (!moved) {
            std::filesystem::remove(temp, ec);
            return fail("缓存文件替换失败。");
        }
        return true;
    } catch (...) {
        return fail("缓存文件保存失败。");
    }
}

Result resolve(std::uint32_t id, const std::filesystem::path& path, TimePoint now)
{
    if (!is_valid_radio_id(id)) {
        auto result = make_result(id, nullptr, Status::unavailable);
        result.error_code = "invalid_request";
        result.error_message = "RadioId 必须是 1 到 16777215 之间的 24 位 DMR ID。";
        return result;
    }
    const auto entry = find_cache_entry(path, id);
    if (!entry || (entry->status != "found" && entry->status != "not_found")) {
        return make_result(id, nullptr, Status::unavailable);
    }
    const auto status = is_fresh(*entry, now) ? *parse_status(entry->status) : Status::stale;
    return make_result(id, &*entry, status);
}

std::vector<NativeMapping> native_mappings(const std::filesystem::path& path, std::size_t limit, TimePoint now)
{
    std::vector<NativeMapping> mappings;
    if (limit < 1U || limit > cache_entry_limit) return mappings;
    std::unordered_set<std::uint32_t> seen;
    for (const auto& entry : read_cache(path)) {
        if (entry.status != "found") continue;
        if (!is_valid_radio_id(entry.id)) continue;
        if (!seen.insert(entry.id).second) continue;
        if (!is_fresh(entry, now)) continue;
        if (!entry.callsign) continue;
        auto callsign = native_callsign(*entry.callsign);
        if (!callsign) continue;
        mappings.push_back({entry.id, std::move(*callsign)});
        if (mappings.size() >= limit) break;
    }
    return mappings;
}

Result query(std::uint32_t id, const std::filesystem::path& path, const QueryOptions& options)
{
    const auto invalid = [&](const char* message) {
        auto result = make_result(id, nullptr, Status::unavailable);
        result.source = std::string(source_name);
        result.error_code = "invalid_request";
        result.error_message = message;
        return result;
    };
    if (!is_valid_radio_id(id)) return invalid("RadioId 必须是 1 到 16777215 之间的 24 位 DMR ID。");
    if (options.timeout_seconds < 1U || options.timeout_seconds > 5U) return invalid("RadioID 查询超时必须为 1 到 5 秒。");
    if (!is_valid_user_agent(options.agent)) return invalid("User-Agent 必须标识 WIREX Bridge 并包含联系地址。");
    if (!is_allowed_base_uri(options.base_uri)) return invalid("RadioID 查询地址只接受官方 HTTPS 地址或本机 HTTP 测试夹具。");

    try {
        HttpRequest request{};
        request.method = "GET";
        request.url = build_query_url(options.base_uri, id);
        request.user_agent = std::string(trim(options.agent));
        request.headers.push_back({"Accept", "application/json"});
        request.timeout_ms = options.timeout_seconds * 1000U;
        request.max_response_bytes = max_response_bytes;
        request.read_body_on_success = true;

        if (options.cancel != nullptr && options.cancel->load()) {
            return fallback(id, path, "cancelled", "查询已取消", "canceled", "RadioID 查询已取消。");
        }
        HttpResponse response{};
        try {
            response = options.transport ? options.transport(request, options.cancel)
                                         : winhttp_send(request, options.cancel);
        } catch (...) {
            return fallback(id, path, "request_failed", "资料查询失败", "transport_exception", "RadioID 查询失败。");
        }
        switch (response.error) {
        case HttpErrorKind::none: break;
        case HttpErrorKind::canceled:
            return fallback(id, path, "cancelled", "查询已取消", "canceled", "RadioID 查询已取消。");
        case HttpErrorKind::timeout:
            return fallback(id, path, "timeout", "查询超时", "timeout", "RadioID 查询超过时间限制。");
        case HttpErrorKind::too_large:
            return fallback(id, path, "invalid_response", "资料服务响应无效", "too_large", "RadioID 响应超过大小限制。");
        case HttpErrorKind::transport:
            return fallback(id, path, "network", "网络查询失败", "transport",
                            "网络请求失败（系统错误 " + std::to_string(response.system_error) + "）。");
        case HttpErrorKind::invalid_request:
            return fallback(id, path, "request_failed", "资料查询失败", "invalid_request", "RadioID 请求无法构造。");
        }
        if (response.body.size() > max_response_bytes) {
            return fallback(id, path, "invalid_response", "资料服务响应无效", "too_large", "RadioID 响应缺失或超过大小限制。");
        }
        if (response.status_code != 200) {
            const auto code = std::to_string(response.status_code);
            return fallback(id, path, "http_" + code, "资料服务返回 HTTP " + code, "http_status",
                            "RadioID 查询返回 HTTP 状态 " + code + "。");
        }

        const auto parsed = parse_response(response.body, id);
        if (parsed.state != ParseState::found && parsed.state != ParseState::not_found) {
            const char* state = parsed.state == ParseState::mismatch ? "mismatch"
                : parsed.state == ParseState::conflict ? "conflict" : "invalid";
            return fallback(id, path, "invalid_response", "资料服务响应无效", "invalid_response",
                            std::string("RadioID 查询结果不唯一或 ID 不匹配（") + state + "）。");
        }

        CacheEntry entry{};
        entry.id = id;
        entry.source = std::string(source_name);
        entry.fetched_at_utc = format_timestamp(Clock::now());
        if (parsed.state == ParseState::found) {
            entry.callsign = parsed.record.callsign;
            entry.name = parsed.record.name;
            entry.city = parsed.record.city;
            entry.state = parsed.record.state;
            entry.country = parsed.record.country;
            entry.status = "found";
        } else {
            entry.status = "not_found";
        }
        const auto status = parsed.state == ParseState::found ? Status::found : Status::not_found;
        std::string save_error;
        auto result = make_result(id, &entry, status);
        if (!save_cache_entry(path, entry, &save_error)) {
            result.cache_saved = false;
            result.error_code = "cache_write";
            result.error_message = "本机缓存保存失败";
            result.error_type = "cache_write";
            result.error_detail = save_error;
        }
        return result;
    } catch (...) {
        return fallback(id, path, "request_failed", "资料查询失败", "exception", "RadioID 查询失败。");
    }
}

} // namespace wirex::app::radio_identity
