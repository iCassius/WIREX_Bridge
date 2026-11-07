// R135 更新检查离线测试：版本解析/比较、GitHub releases/latest 正文解析、请求构造与传输结果。
// 只使用注入的假 transport，不访问网络。

#include "wirex/app/update_check.hpp"
#include "wirex/version.hpp"

#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

using namespace wirex::app::update;
using wirex::app::HttpErrorKind;
using wirex::app::HttpRequest;
using wirex::app::HttpResponse;
using wirex::app::HttpTransport;

int assertions = 0;

void check(bool condition, const std::string& message) {
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

Version make_version(std::uint32_t major, std::uint32_t minor, std::uint32_t patch, std::string prerelease = {}) {
    Version version;
    version.major = major;
    version.minor = minor;
    version.patch = patch;
    version.prerelease = std::move(prerelease);
    return version;
}

bool same_version(const Version& a, const Version& b) {
    return a.major == b.major && a.minor == b.minor && a.patch == b.patch && a.prerelease == b.prerelease;
}

void test_parse_version() {
    struct Case {
        std::string_view text;
        std::optional<Version> expected;
    };
    const std::vector<Case> cases{
        {"1.2.3", make_version(1U, 2U, 3U)},
        {"v0.2.2", make_version(0U, 2U, 2U)},
        {"V10.20.30", make_version(10U, 20U, 30U)},
        {"0.0.0", make_version(0U, 0U, 0U)},
        {"1.2.3-rc.1", make_version(1U, 2U, 3U, "rc.1")},
        {"1.2.3-0", make_version(1U, 2U, 3U, "0")},
        {"1.2.3-alpha-1", make_version(1U, 2U, 3U, "alpha-1")},
        {"4294967295.0.0", make_version(4294967295U, 0U, 0U)},
        {"", std::nullopt},
        {"v", std::nullopt},
        {"1", std::nullopt},
        {"1.2", std::nullopt},
        {"1.2.3.4", std::nullopt},
        {"1.2.x", std::nullopt},
        {"01.2.3", std::nullopt},
        {"1.02.3", std::nullopt},
        {"1.2.03", std::nullopt},
        {"1.2.3-", std::nullopt},
        {"1.2.3-01", std::nullopt},
        {"1.2.3+build", std::nullopt},
        {" 1.2.3", std::nullopt},
        {"1.2.3 ", std::nullopt},
        {"-1.2.3", std::nullopt},
        {"1..3", std::nullopt},
        {"1.2.3-rc..1", std::nullopt},
        {"1.2.3-rc_1", std::nullopt},
        {"vv1.2.3", std::nullopt},
        {"4294967296.0.0", std::nullopt},
    };
    for (const auto& c : cases) {
        const auto parsed = parse_version(c.text);
        const std::string label = "parse_version(\"" + std::string(c.text) + "\")";
        if (c.expected) {
            check(parsed.has_value() && same_version(*parsed, *c.expected), label + " parses");
        } else {
            check(!parsed.has_value(), label + " is rejected");
        }
    }
}

void test_compare() {
    struct Case {
        std::string_view left;
        std::string_view right;
        int expected;
    };
    const std::vector<Case> cases{
        {"1.2.3", "1.2.3", 0},
        {"v1.2.3", "1.2.3", 0},
        {"1.2.4", "1.2.3", 1},
        {"1.3.0", "1.2.9", 1},
        {"2.0.0", "1.99.99", 1},
        {"1.2.3", "1.2.3-rc.1", 1},
        {"1.2.3-rc.1", "1.2.3", -1},
        {"1.2.3-alpha", "1.2.3-beta", -1},
        {"1.2.3-alpha.1", "1.2.3-alpha", 1},
        {"1.2.3-alpha", "1.2.3-alpha.1", -1},
        {"1.2.3-alpha.1", "1.2.3-alpha.beta", -1},
        {"1.2.3-2", "1.2.3-10", -1},
        {"1.2.3-rc.10", "1.2.3-rc.9", 1},
        {"1.2.3-alpha.beta", "1.2.3-alpha.1", 1},
    };
    for (const auto& c : cases) {
        const auto left = parse_version(c.left);
        const auto right = parse_version(c.right);
        check(left && right, "compare operands parse: " + std::string(c.left) + " / " + std::string(c.right));
        if (!left || !right) continue;
        const int actual = compare(*left, *right);
        check((actual < 0 ? -1 : actual > 0 ? 1 : 0) == c.expected,
              "compare(" + std::string(c.left) + ", " + std::string(c.right) + ")");
        const int reversed = compare(*right, *left);
        check((reversed < 0 ? -1 : reversed > 0 ? 1 : 0) == -c.expected,
              "compare is antisymmetric: " + std::string(c.left) + " / " + std::string(c.right));
    }
}

constexpr std::string_view good_release_json =
    R"({"tag_name":"v0.2.3","html_url":"https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.2.3",)"
    R"("prerelease":false,"draft":false,"name":"v0.2.3"})";

void test_parse_latest_release() {
    {
        const auto release = parse_latest_release(good_release_json);
        check(release.has_value(), "valid release JSON parses");
        if (release) {
            check(release->tag == "v0.2.3", "tag_name is kept");
            check(release->html_url == "https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.2.3",
                  "html_url is kept");
            check(!release->prerelease && !release->draft, "flags default to false");
        }
    }
    {
        const auto release = parse_latest_release(
            R"({"tag_name":"v0.3.0-rc.1","html_url":"https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.3.0-rc.1",)"
            R"("prerelease":true,"draft":false})");
        check(release.has_value() && release->prerelease && !release->draft, "prerelease flag is parsed");
    }
    {
        const auto release = parse_latest_release(
            R"({"tag_name":"v0.3.0","html_url":"https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.3.0",)"
            R"("prerelease":false,"draft":true})");
        check(release.has_value() && release->draft && !release->prerelease, "draft flag is parsed");
    }
    {
        const auto release = parse_latest_release(
            R"({"tag_name":"v0.2.3","html_url":"https://example.com/iCassius/WIREX_Bridge/releases/tag/v0.2.3",)"
            R"("prerelease":false,"draft":false})");
        check(!release.has_value(), "foreign html_url is rejected");
    }
    {
        const auto release = parse_latest_release(
            R"({"tag_name":"v0.2.3","html_url":"https://github.com/other/WIREX_Bridge/releases/tag/v0.2.3",)"
            R"("prerelease":false,"draft":false})");
        check(!release.has_value(), "html_url from another repository is rejected");
    }
    {
        const auto release = parse_latest_release(
            R"({"tag_name":"v0.2.3","html_url":"http://github.com/iCassius/WIREX_Bridge/releases/tag/v0.2.3",)"
            R"("prerelease":false,"draft":false})");
        check(!release.has_value(), "non-https html_url is rejected");
    }
    check(!parse_latest_release(R"({"html_url":"https://github.com/iCassius/WIREX_Bridge/releases/tag/v1"})")
               .has_value(),
          "missing tag_name is rejected");
    check(!parse_latest_release(R"({"tag_name":"v1"})").has_value(), "missing html_url is rejected");
    check(!parse_latest_release(R"({"tag_name":1,"html_url":"https://github.com/iCassius/WIREX_Bridge/x"})")
               .has_value(),
          "non-string tag_name is rejected");
    check(!parse_latest_release(
               R"({"tag_name":"v1","html_url":"https://github.com/iCassius/WIREX_Bridge/x","prerelease":"no"})")
               .has_value(),
          "non-boolean prerelease is rejected");
    check(!parse_latest_release(R"({"tag_name":"v1","html_url":"https://github.com/iCassius/WIREX_Bridge/x","draft":0})")
               .has_value(),
          "non-boolean draft is rejected");
    check(!parse_latest_release("not json").has_value(), "garbage body is rejected");
    check(!parse_latest_release("[]").has_value(), "non-object body is rejected");
    check(!parse_latest_release("").has_value(), "empty body is rejected");
}

HttpTransport fixed_transport(HttpResponse response, HttpRequest* captured = nullptr) {
    return [response = std::move(response), captured](const HttpRequest& request,
                                                      const std::atomic<bool>*) mutable {
        if (captured != nullptr) *captured = request;
        return response;
    };
}

void test_fetch_latest_release() {
    HttpResponse ok;
    ok.status_code = 200;
    ok.body = std::string(good_release_json);
    HttpRequest captured;
    const auto release = fetch_latest_release(fixed_transport(ok, &captured), nullptr);
    check(release.has_value() && release->tag == "v0.2.3", "HTTP 200 parses the release");
    check(captured.method == "GET", "request method is GET");
    check(std::string_view(captured.url) == latest_release_api_url, "request URL is releases/latest");
    check(captured.user_agent == std::string("WIREX Bridge/") + wirex::app_version,
          "User-Agent carries the app version");
    check(captured.timeout_ms == 5000U, "request timeout is 5000 ms");
    check(captured.max_response_bytes == std::size_t{256U * 1024U}, "response cap is 256 KiB");
    bool has_accept = false;
    for (const auto& header : captured.headers) {
        if (header.name == "Accept" && header.value == "application/vnd.github+json") has_accept = true;
    }
    check(has_accept, "Accept header requests the GitHub JSON media type");

    HttpResponse not_found;
    not_found.status_code = 404;
    check(!fetch_latest_release(fixed_transport(not_found), nullptr).has_value(),
          "HTTP 404 (no releases) returns nullopt");

    HttpResponse server_error;
    server_error.status_code = 500;
    server_error.body = std::string(good_release_json);
    check(!fetch_latest_release(fixed_transport(server_error), nullptr).has_value(),
          "HTTP 500 returns nullopt");

    HttpResponse timeout;
    timeout.error = HttpErrorKind::timeout;
    timeout.status_code = 200;
    timeout.body = std::string(good_release_json);
    check(!fetch_latest_release(fixed_transport(timeout), nullptr).has_value(),
          "transport timeout returns nullopt");

    HttpResponse garbage;
    garbage.status_code = 200;
    garbage.body = "not json";
    check(!fetch_latest_release(fixed_transport(garbage), nullptr).has_value(),
          "invalid JSON body returns nullopt");

    std::atomic<bool> cancel{false};
    bool saw_cancel = false;
    const auto transport = [&](const HttpRequest&, const std::atomic<bool>* flag) {
        saw_cancel = flag == &cancel;
        return ok;
    };
    (void)fetch_latest_release(transport, &cancel);
    check(saw_cancel, "cancel flag is forwarded to the transport");
}

} // namespace

int main() {
    test_parse_version();
    test_compare();
    test_parse_latest_release();
    test_fetch_latest_release();
    std::cout << "app_update_check_test: " << assertions << " assertions passed\n";
    return EXIT_SUCCESS;
}
