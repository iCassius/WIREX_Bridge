#include "wirex/app/update_check.hpp"

#include "wirex/app/json.hpp"
#include "wirex/version.hpp"

#include <algorithm>
#include <limits>
#include <string>

namespace wirex::app::update {
namespace {

bool is_digit(char c) noexcept { return c >= '0' && c <= '9'; }

bool is_identifier_char(char c) noexcept {
    return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-';
}

bool is_numeric_identifier(std::string_view text) noexcept {
    return !text.empty() && std::all_of(text.begin(), text.end(), is_digit);
}

bool parse_core_number(std::string_view text, std::uint32_t& out) noexcept {
    if (text.empty() || text.size() > 10U) return false;
    if (text.size() > 1U && text.front() == '0') return false; // semver：不允许前导零
    std::uint64_t value = 0U;
    for (const char c : text) {
        if (!is_digit(c)) return false;
        value = value * 10U + static_cast<std::uint64_t>(c - '0');
        if (value > std::numeric_limits<std::uint32_t>::max()) return false;
    }
    out = static_cast<std::uint32_t>(value);
    return true;
}

bool valid_prerelease(std::string_view text) noexcept {
    if (text.empty()) return false;
    std::size_t start = 0U;
    for (;;) {
        const auto dot = text.find('.', start);
        const std::string_view identifier = text.substr(start, dot == std::string_view::npos ? std::string_view::npos
                                                                                           : dot - start);
        if (identifier.empty() || !std::all_of(identifier.begin(), identifier.end(), is_identifier_char)) return false;
        if (is_numeric_identifier(identifier) && identifier.size() > 1U && identifier.front() == '0') return false;
        if (dot == std::string_view::npos) return true;
        start = dot + 1U;
    }
}

// 去掉前导零（已验证的版本不会有，但 compare 对任意 Version 也要稳定）。
std::string_view trim_leading_zeros(std::string_view text) noexcept {
    const auto first = text.find_first_not_of('0');
    return first == std::string_view::npos ? std::string_view{} : text.substr(first);
}

int compare_identifier(std::string_view a, std::string_view b) noexcept {
    const bool a_numeric = is_numeric_identifier(a);
    const bool b_numeric = is_numeric_identifier(b);
    if (a_numeric && b_numeric) {
        const auto a_digits = trim_leading_zeros(a);
        const auto b_digits = trim_leading_zeros(b);
        if (a_digits.size() != b_digits.size()) return a_digits.size() < b_digits.size() ? -1 : 1;
        if (a_digits == b_digits) return 0;
        return a_digits < b_digits ? -1 : 1;
    }
    if (a_numeric != b_numeric) return a_numeric ? -1 : 1; // 数字标识优先级低于字母数字标识
    if (a == b) return 0;
    return a < b ? -1 : 1; // ASCII 字典序
}

int compare_prerelease(std::string_view a, std::string_view b) noexcept {
    std::size_t a_start = 0U;
    std::size_t b_start = 0U;
    for (;;) {
        const auto a_dot = a.find('.', a_start);
        const auto b_dot = b.find('.', b_start);
        const std::string_view a_id = a.substr(a_start, a_dot == std::string_view::npos ? std::string_view::npos
                                                                                       : a_dot - a_start);
        const std::string_view b_id = b.substr(b_start, b_dot == std::string_view::npos ? std::string_view::npos
                                                                                       : b_dot - b_start);
        if (const int result = compare_identifier(a_id, b_id); result != 0) return result;
        const bool a_done = a_dot == std::string_view::npos;
        const bool b_done = b_dot == std::string_view::npos;
        if (a_done && b_done) return 0;
        if (a_done) return -1; // 前缀相同：标识更多者优先级更高
        if (b_done) return 1;
        a_start = a_dot + 1U;
        b_start = b_dot + 1U;
    }
}

} // namespace

std::optional<Version> parse_version(std::string_view text) noexcept {
    try {
        if (!text.empty() && (text.front() == 'v' || text.front() == 'V')) text.remove_prefix(1U);
        if (text.empty() || text.find('+') != std::string_view::npos) return std::nullopt;

        Version version;
        std::string_view core = text;
        std::string_view prerelease;
        if (const auto dash = text.find('-'); dash != std::string_view::npos) {
            core = text.substr(0U, dash);
            prerelease = text.substr(dash + 1U);
            if (!valid_prerelease(prerelease)) return std::nullopt;
        }

        const auto first_dot = core.find('.');
        if (first_dot == std::string_view::npos) return std::nullopt;
        const auto second_dot = core.find('.', first_dot + 1U);
        if (second_dot == std::string_view::npos || core.find('.', second_dot + 1U) != std::string_view::npos) {
            return std::nullopt;
        }
        if (!parse_core_number(core.substr(0U, first_dot), version.major) ||
            !parse_core_number(core.substr(first_dot + 1U, second_dot - first_dot - 1U), version.minor) ||
            !parse_core_number(core.substr(second_dot + 1U), version.patch)) {
            return std::nullopt;
        }
        version.prerelease.assign(prerelease);
        return version;
    } catch (...) {
        return std::nullopt;
    }
}

int compare(const Version& a, const Version& b) noexcept {
    if (a.major != b.major) return a.major < b.major ? -1 : 1;
    if (a.minor != b.minor) return a.minor < b.minor ? -1 : 1;
    if (a.patch != b.patch) return a.patch < b.patch ? -1 : 1;
    const bool a_prerelease = !a.prerelease.empty();
    const bool b_prerelease = !b.prerelease.empty();
    if (!a_prerelease && !b_prerelease) return 0;
    if (!a_prerelease) return 1;  // 正式版 > 同核心预发布版
    if (!b_prerelease) return -1;
    return compare_prerelease(a.prerelease, b.prerelease);
}

std::optional<LatestRelease> parse_latest_release(std::string_view json) {
    json::Value document;
    json::ParseOptions options;
    options.reject_escaped_keys = false; // 服务器响应允许转义键名
    if (!json::parse(json, document, options).ok() || !document.is_object()) return std::nullopt;

    const json::Value* tag = document.find("tag_name");
    const json::Value* url = document.find("html_url");
    if (tag == nullptr || !tag->is_string() || tag->text.empty()) return std::nullopt;
    if (url == nullptr || !url->is_string() ||
        std::string_view(url->text).compare(0U, release_page_prefix.size(), release_page_prefix) != 0) {
        return std::nullopt;
    }

    LatestRelease release;
    release.tag = tag->text;
    release.html_url = url->text;
    if (const json::Value* prerelease = document.find("prerelease")) {
        if (!prerelease->is_bool()) return std::nullopt;
        release.prerelease = prerelease->boolean_value;
    }
    if (const json::Value* draft = document.find("draft")) {
        if (!draft->is_bool()) return std::nullopt;
        release.draft = draft->boolean_value;
    }
    return release;
}

HttpRequest make_latest_release_request() {
    HttpRequest request;
    request.method = "GET";
    request.url.assign(latest_release_api_url);
    request.user_agent = std::string("WIREX Bridge/") + app_version;
    request.headers.push_back(HttpHeader{"Accept", "application/vnd.github+json"});
    request.timeout_ms = 5000U;
    request.max_response_bytes = 256U * 1024U;
    return request;
}

std::optional<LatestRelease> fetch_latest_release(const HttpTransport& transport, const std::atomic<bool>* cancel) {
    if (!transport) return std::nullopt;
    const HttpResponse response = transport(make_latest_release_request(), cancel);
    if (response.error != HttpErrorKind::none || response.status_code != 200) return std::nullopt;
    return parse_latest_release(response.body);
}

} // namespace wirex::app::update
