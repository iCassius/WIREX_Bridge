#include "wirex/app/bm_api.hpp"

#include "wirex/strict_json.hpp"

#include <fstream>
#include <iterator>
#include <sstream>
#include <utility>

namespace wirex::app::bm_api {
namespace {

constexpr std::uintmax_t max_key_file_bytes = 65536U;

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

bool is_base64url(char ch) noexcept
{
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
}

char ascii_lower(char ch) noexcept
{
    return ch >= 'A' && ch <= 'Z' ? static_cast<char>(ch - 'A' + 'a') : ch;
}

Error make_error(ErrorKind kind, std::string message, int http_status = 0)
{
    Error error{};
    error.kind = kind;
    error.message = std::move(message);
    error.http_status = http_status;
    return error;
}

// PS 版对 talkgroup/slot 使用 [string] 转换后匹配正则，因此数字与十进制字符串都被接受。
bool decimal_field(const strict_json::Value* value, std::size_t max_digits, std::uint64_t& output) noexcept
{
    if (value == nullptr) return false;
    if (value->type == strict_json::Value::Type::unsigned_integer) {
        output = value->integer_value;
        std::uint64_t digits = 1U;
        for (auto n = output; n >= 10U; n /= 10U) ++digits;
        return digits <= max_digits;
    }
    if (value->type != strict_json::Value::Type::string) return false;
    const auto& text = value->string_value;
    if (text.empty() || text.size() > max_digits) return false;
    std::uint64_t number = 0U;
    for (const char ch : text) {
        if (ch < '0' || ch > '9') return false;
        number = number * 10U + static_cast<std::uint64_t>(ch - '0');
    }
    output = number;
    return true;
}

bool parse_body(std::string_view json, strict_json::Value& root)
{
    const auto text = trim(strip_bom(trim(json)));
    return strict_json::parse(text, root);
}

} // namespace

std::string_view to_string(ErrorKind kind) noexcept
{
    switch (kind) {
    case ErrorKind::none: return "none";
    case ErrorKind::canceled: return "canceled";
    case ErrorKind::timeout: return "timeout";
    case ErrorKind::http_status: return "http_status";
    case ErrorKind::transport: return "transport";
    case ErrorKind::too_large: return "too_large";
    case ErrorKind::invalid_response: return "invalid_response";
    case ErrorKind::invalid_request: return "invalid_request";
    case ErrorKind::invalid_key: return "invalid_key";
    }
    return "unknown";
}

std::string_view to_string(ReadbackStatus status) noexcept
{
    switch (status) {
    case ReadbackStatus::confirmed: return "confirmed";
    case ReadbackStatus::not_confirmed: return "not_confirmed";
    case ReadbackStatus::unavailable: return "unavailable";
    case ReadbackStatus::canceled: return "canceled";
    }
    return "unavailable";
}

// ---------- ApiKey ----------

ApiKey::~ApiKey() { secure_wipe(value_); }

ApiKey::ApiKey(ApiKey&& other) noexcept : value_(std::move(other.value_))
{
    secure_wipe(other.value_);
}

ApiKey& ApiKey::operator=(ApiKey&& other) noexcept
{
    if (this != &other) {
        secure_wipe(value_);
        value_ = std::move(other.value_);
        secure_wipe(other.value_);
    }
    return *this;
}

bool is_valid_key_format(std::string_view candidate) noexcept
{
    if (candidate.size() < 200U) return false;
    std::size_t segments = 1U;
    std::size_t segment_length = 0U;
    for (const char ch : candidate) {
        if (ch == '.') {
            if (segment_length == 0U) return false;
            ++segments;
            segment_length = 0U;
            continue;
        }
        if (!is_base64url(ch)) return false;
        ++segment_length;
    }
    return segments == 3U && segment_length > 0U;
}

std::string extract_key_from_file_content(std::string_view content)
{
    const auto text = trim(strip_bom(content));
    // 兼容 Pi-Star 风格：任一行 `apikey = VALUE`（大小写不敏感，VALUE 不含空白）。
    std::size_t start = 0U;
    while (start <= text.size()) {
        auto end = text.find('\n', start);
        if (end == std::string_view::npos) end = text.size();
        auto line = trim(text.substr(start, end - start));
        constexpr std::string_view name = "apikey";
        if (line.size() > name.size()) {
            bool match = true;
            for (std::size_t i = 0U; i < name.size(); ++i) {
                if (ascii_lower(line[i]) != name[i]) { match = false; break; }
            }
            if (match) {
                auto rest = trim(line.substr(name.size()));
                if (!rest.empty() && rest.front() == '=') {
                    rest = trim(rest.substr(1U));
                    bool single_token = !rest.empty();
                    for (const char ch : rest) if (is_space(ch)) single_token = false;
                    if (single_token) return std::string(rest);
                }
            }
        }
        if (end == text.size()) break;
        start = end + 1U;
    }
    return std::string(text);
}

std::optional<ApiKey> ApiKey::from_text(std::string_view text, Error* error)
{
    const auto candidate = trim(text);
    if (candidate.empty()) {
        if (error != nullptr) *error = make_error(ErrorKind::invalid_key, "必须且只能提供一个 BM API key 来源。");
        return std::nullopt;
    }
    if (!is_valid_key_format(candidate)) {
        if (error != nullptr) *error = make_error(ErrorKind::invalid_key, "BM API key 格式无效；需要 BrandMeister API v2 token。");
        return std::nullopt;
    }
    ApiKey key;
    key.value_.assign(candidate.data(), candidate.size());
    return key;
}

std::optional<ApiKey> ApiKey::from_file(const std::filesystem::path& path, Error* error)
{
    const auto fail = [&](std::string message) -> std::optional<ApiKey> {
        if (error != nullptr) *error = make_error(ErrorKind::invalid_key, std::move(message));
        return std::nullopt;
    };
    if (path.empty()) return fail("必须且只能提供一个 BM API key 来源。");
    if (!path.is_absolute()) return fail("BM API 文件必须使用完整路径。");
    std::error_code ec;
    if (!std::filesystem::is_regular_file(path, ec)) return fail("找不到 BM API 文件。");
    const auto size = std::filesystem::file_size(path, ec);
    if (ec || size > max_key_file_bytes) return fail("无法读取已指定的 BM API 文件。");

    std::string content;
    try {
        std::ifstream stream(path, std::ios::binary);
        if (!stream) return fail("无法读取已指定的 BM API 文件。");
        content.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
        if (stream.bad()) {
            secure_wipe(content);
            return fail("无法读取已指定的 BM API 文件。");
        }
    } catch (...) {
        secure_wipe(content);
        return fail("无法读取已指定的 BM API 文件。");
    }
    std::string candidate = extract_key_from_file_content(content);
    secure_wipe(content);
    auto key = from_text(candidate, error);
    secure_wipe(candidate);
    return key;
}

// ---------- 纯函数 ----------

std::optional<std::uint32_t> parse_device_id(std::string_view text) noexcept
{
    if (text.empty() || text.size() > 10U) return std::nullopt;
    std::uint64_t value = 0U;
    for (const char ch : text) {
        if (ch < '0' || ch > '9') return std::nullopt;
        value = value * 10U + static_cast<std::uint64_t>(ch - '0');
    }
    if (value < 1U || value > max_device_id) return std::nullopt;
    return static_cast<std::uint32_t>(value);
}

std::string build_add_body(std::uint32_t talkgroup, int slot)
{
    return "{\"slot\":" + std::to_string(slot) + ",\"group\":" + std::to_string(talkgroup) + "}";
}

HttpRequest build_request(std::string_view method, std::uint32_t device_id, std::string_view resource,
                          std::string_view suffix, const ApiKey& key, std::uint32_t timeout_ms)
{
    HttpRequest invalid{};
    const bool known_method = method == "GET" || method == "POST" || method == "DELETE";
    if (!known_method || device_id == 0U || key.empty() || timeout_ms < 1U || timeout_ms > max_timeout_ms) return invalid;
    if (resource.empty() && (method != "GET" || !suffix.empty())) return invalid;
    if (!resource.empty() && resource != "talkgroup") return invalid;
    if (!suffix.empty()) {
        // 只允许 DELETE talkgroup 的 /{digits}/{digits}
        if (resource != "talkgroup" || method != "DELETE" || suffix.front() != '/') return invalid;
        const auto second = suffix.find('/', 1U);
        if (second == std::string_view::npos || second == 1U || second + 1U >= suffix.size()) return invalid;
        for (std::size_t i = 1U; i < suffix.size(); ++i) {
            if (i == second) continue;
            if (suffix[i] < '0' || suffix[i] > '9') return invalid;
        }
    }

    HttpRequest request{};
    request.method.assign(method.data(), method.size());
    request.url.assign(api_origin.data(), api_origin.size());
    request.url.append(api_prefix.data(), api_prefix.size());
    request.url += std::to_string(device_id);
    if (!resource.empty()) {
        request.url += '/';
        request.url.append(resource.data(), resource.size());
        request.url.append(suffix.data(), suffix.size());
    }
    request.user_agent = "WIREX Bridge";
    request.timeout_ms = timeout_ms;
    request.max_response_bytes = max_response_bytes;
    request.read_body_on_success = method == "GET";
    request.headers.push_back({"Authorization", "Bearer " + key.value_});
    request.headers.push_back({"Accept", "application/json"});
    if (method == "POST") request.headers.push_back({"Content-Type", "application/json; charset=utf-8"});
    return request;
}

bool parse_static_group_list(std::string_view json, std::uint32_t device_id, std::vector<StaticGroup>& groups,
                             Error* error)
{
    const auto fail = [&](const char* message) {
        if (error != nullptr) *error = make_error(ErrorKind::invalid_response, message);
        return false;
    };
    const auto text = trim(strip_bom(trim(json)));
    if (text.size() < 2U || text.front() != '[' || text.back() != ']') return fail("BM API 静态组列表必须是 JSON 数组。");
    strict_json::Value root{};
    if (!strict_json::parse(text, root) || root.type != strict_json::Value::Type::array) {
        return fail("BM API 返回的静态组列表不是有效 JSON。");
    }
    std::vector<StaticGroup> parsed;
    parsed.reserve(root.array_value.size());
    for (const auto& item : root.array_value) {
        const auto* talkgroup = item.find("talkgroup");
        const auto* slot = item.find("slot");
        if (item.type != strict_json::Value::Type::object || talkgroup == nullptr || slot == nullptr) {
            return fail("BM API 静态组项目缺少 TG 或时隙。");
        }
        std::uint64_t tg = 0U;
        std::uint64_t slot_value = 0U;
        if (!decimal_field(talkgroup, 8U, tg) || tg < 1U || tg > max_talkgroup ||
            !decimal_field(slot, 1U, slot_value) || slot_value > 2U) {
            return fail("BM API 静态组项目含有无效 TG 或时隙。");
        }
        for (const auto& existing : parsed) {
            if (existing.talkgroup == tg && existing.slot == static_cast<int>(slot_value)) {
                return fail("BM API 静态组列表含有重复项目。");
            }
        }
        parsed.push_back({device_id, static_cast<std::uint32_t>(tg), static_cast<int>(slot_value)});
    }
    groups = std::move(parsed);
    return true;
}

AddContext parse_add_context(std::string_view json, std::uint32_t device_id)
{
    AddContext context{};
    strict_json::Value root{};
    if (!parse_body(json, root) || root.type != strict_json::Value::Type::object) return context;
    const auto* id = root.find("id");
    const auto* status = root.find("status");
    if (id == nullptr || status == nullptr) return context;
    std::uint64_t returned_id = 0U;
    if (!decimal_field(id, 10U, returned_id) || returned_id != device_id) return context;
    if (status->type != strict_json::Value::Type::unsigned_integer) return context;
    if (status->integer_value > static_cast<std::uint64_t>(INT64_MAX)) return context;
    context.status = static_cast<std::int64_t>(status->integer_value);
    if (status->integer_value > 4U) return context;
    context.success = true;
    context.add_slot = status->integer_value == 4U ? 0 : 2;
    return context;
}

Error classify(const HttpResponse& response)
{
    switch (response.error) {
    case HttpErrorKind::none: break;
    case HttpErrorKind::canceled: return make_error(ErrorKind::canceled, "BM API 操作已取消。");
    case HttpErrorKind::timeout: return make_error(ErrorKind::timeout, "BM API 操作超过时限。");
    case HttpErrorKind::too_large: return make_error(ErrorKind::too_large, "BM API 返回内容超过大小上限。");
    case HttpErrorKind::invalid_request: return make_error(ErrorKind::invalid_request, "BM API 请求参数无效。");
    case HttpErrorKind::transport:
        return make_error(ErrorKind::transport, "BM API 请求失败；没有保存或显示 API token。");
    }
    if (response.status_code < 200 || response.status_code >= 300) {
        return make_error(ErrorKind::http_status, "BM API 返回 HTTP " + std::to_string(response.status_code) + "。",
                          response.status_code);
    }
    if (response.body.size() > max_response_bytes) {
        return make_error(ErrorKind::too_large, "BM API 返回内容超过大小上限。");
    }
    return {};
}

// ---------- Client ----------

Client::Client(HttpTransport transport) : transport_(std::move(transport))
{
    if (!transport_) transport_ = winhttp_send;
}

Error Client::send(HttpRequest& request, const std::atomic<bool>* cancel, HttpResponse& response) const
{
    if (cancel != nullptr && cancel->load()) {
        request.wipe();
        return make_error(ErrorKind::canceled, "BM API 操作已取消。");
    }
    try {
        response = transport_(request, cancel);
    } catch (...) {
        request.wipe();
        return make_error(ErrorKind::transport, "BM API 请求失败；没有保存或显示 API token。");
    }
    request.wipe();
    if (cancel != nullptr && cancel->load()) return make_error(ErrorKind::canceled, "BM API 操作已取消。");
    return classify(response);
}

namespace {

Error validate_common(std::string_view device_text, std::uint32_t timeout_ms, const ApiKey& key,
                      std::uint32_t& device_id)
{
    const auto parsed = parse_device_id(device_text);
    if (!parsed) return make_error(ErrorKind::invalid_request, "BM 设备 ID 必须是 1 到 4294967295 的十进制整数。");
    if (timeout_ms < 1U || timeout_ms > max_timeout_ms) {
        return make_error(ErrorKind::invalid_request, "BM API 超时必须为 1 到 10000 毫秒。");
    }
    if (key.empty()) return make_error(ErrorKind::invalid_key, "必须且只能提供一个 BM API key 来源。");
    device_id = *parsed;
    return {};
}

} // namespace

ListResult Client::list_static_groups(const ApiKey& key, std::string_view device_id, std::uint32_t timeout_ms,
                                      const std::atomic<bool>* cancel) const
{
    ListResult result{};
    if (cancel != nullptr && cancel->load()) {
        result.error = make_error(ErrorKind::canceled, "BM API 操作已取消。");
        return result;
    }
    std::uint32_t id = 0U;
    result.error = validate_common(device_id, timeout_ms, key, id);
    if (result.error) return result;
    auto request = build_request("GET", id, "talkgroup", "", key, timeout_ms);
    HttpResponse response{};
    result.error = send(request, cancel, response);
    if (result.error) return result;
    if (!parse_static_group_list(response.body, id, result.groups, &result.error)) result.groups.clear();
    return result;
}

AddContextResult Client::get_add_context(const ApiKey& key, std::string_view device_id, std::uint32_t timeout_ms,
                                         const std::atomic<bool>* cancel) const
{
    AddContextResult result{};
    if (cancel != nullptr && cancel->load()) {
        result.error = make_error(ErrorKind::canceled, "BM API 操作已取消。");
        return result;
    }
    std::uint32_t id = 0U;
    result.error = validate_common(device_id, timeout_ms, key, id);
    if (result.error) return result;
    auto request = build_request("GET", id, "", "", key, timeout_ms);
    HttpResponse response{};
    result.error = send(request, cancel, response);
    if (result.error) return result;
    result.context = parse_add_context(response.body, id);
    return result;
}

WriteResult Client::write(const char* method, const ApiKey& key, std::string_view device_id,
                          std::uint32_t talkgroup, int slot, std::uint32_t timeout_ms,
                          const std::atomic<bool>* cancel, bool expected_present) const
{
    WriteResult result{};
    if (cancel != nullptr && cancel->load()) {
        result.error = make_error(ErrorKind::canceled, "BM API 操作已取消。");
        return result;
    }
    if (talkgroup < 1U || talkgroup > max_talkgroup || slot < 0 || slot > 2) {
        result.error = make_error(ErrorKind::invalid_request, "BM 静态组 TG 必须为 1..16777215，slot 必须为 0..2。");
        return result;
    }
    std::uint32_t id = 0U;
    result.error = validate_common(device_id, timeout_ms, key, id);
    if (result.error) return result;

    const std::string_view method_view(method);
    HttpRequest request{};
    if (method_view == "POST") {
        request = build_request("POST", id, "talkgroup", "", key, timeout_ms);
        request.body = build_add_body(talkgroup, slot);
    } else {
        const auto suffix = "/" + std::to_string(slot) + "/" + std::to_string(talkgroup);
        request = build_request("DELETE", id, "talkgroup", suffix, key, timeout_ms);
    }
    HttpResponse response{};
    result.error = send(request, cancel, response);
    if (result.error) return result;   // 写失败或结果未知：不回读、不重试
    result.write_accepted = true;

    auto readback = list_static_groups(key, device_id, timeout_ms, cancel);
    if (readback.error.kind == ErrorKind::canceled) {
        result.readback_status = ReadbackStatus::canceled;
        result.readback_error = "canceled";
    } else if (readback.error.kind == ErrorKind::timeout) {
        result.readback_status = ReadbackStatus::unavailable;
        result.readback_error = "timeout";
    } else if (readback.error) {
        result.readback_status = ReadbackStatus::unavailable;
        result.readback_error = "unavailable";
    } else {
        bool present = false;
        for (const auto& group : readback.groups) {
            if (group.talkgroup == talkgroup && group.slot == slot) present = true;
        }
        result.readback_status = present == expected_present ? ReadbackStatus::confirmed : ReadbackStatus::not_confirmed;
        result.groups = std::move(readback.groups);
    }
    return result;
}

WriteResult Client::add_static_group(const ApiKey& key, std::string_view device_id, std::uint32_t talkgroup, int slot,
                                     std::uint32_t timeout_ms, const std::atomic<bool>* cancel) const
{
    return write("POST", key, device_id, talkgroup, slot, timeout_ms, cancel, true);
}

WriteResult Client::remove_static_group(const ApiKey& key, std::string_view device_id, std::uint32_t talkgroup,
                                        int slot, std::uint32_t timeout_ms, const std::atomic<bool>* cancel) const
{
    return write("DELETE", key, device_id, talkgroup, slot, timeout_ms, cancel, false);
}

} // namespace wirex::app::bm_api
