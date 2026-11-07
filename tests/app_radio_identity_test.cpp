// RadioID 查询与缓存兼容性离线测试；响应样例取自 tools/test-radio-identity.ps1。
// 缓存文件写到 tmp/svc-bm/identity/，不访问网络。

#include "wirex/app/radio_identity.hpp"
#include "wirex/radio_identity_cache.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace {

using namespace wirex::app;
using namespace wirex::app::radio_identity;

int assertions = 0;

void check(bool condition, const std::string& description)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

const std::string valid_body =
    R"({"page":1,"pages":1,"count":1,"per_page":100,"results":[{"id":7654321,"radio_id":7654321,"callsign":"N0TEST","name":"Test Operator","fname":"Test","surname":"Operator","city":"Fixture City","state":"ZZ","country":"Fixtureland"}]})";

std::filesystem::path test_dir()
{
    const auto dir = std::filesystem::absolute("tmp/svc-bm/identity");
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
    std::filesystem::create_directories(dir);
    return dir;
}

std::string read_file(const std::filesystem::path& path)
{
    std::ifstream stream(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
}

HttpTransport respond(int status, std::string body, std::vector<HttpRequest>* seen = nullptr)
{
    return [status, body, seen](const HttpRequest& request, const std::atomic<bool>*) {
        if (seen != nullptr) seen->push_back(request);
        return HttpResponse{HttpErrorKind::none, status, body, 0U};
    };
}

HttpTransport fail_with(HttpErrorKind kind)
{
    return [kind](const HttpRequest&, const std::atomic<bool>*) { return HttpResponse{kind, 0, {}, 0U}; };
}

void test_pure_helpers()
{
    struct CallsignCase { const char* input; const char* expected; };
    const std::vector<CallsignCase> callsigns{
        {"N0CALL", "N0CALL"}, {" N0CALL/p ", "N0CALL/P"}, {"a123456789", "A123456789"},
        {"1234567890", nullptr}, {"A1234567890", nullptr}, {"N0 CALL", nullptr}, {"", nullptr},
        {"N0CALL\"", nullptr}, {"N0-CALL", "N0-CALL"},
    };
    for (const auto& c : callsigns) {
        const auto result = native_callsign(c.input);
        check(result.has_value() == (c.expected != nullptr), std::string("native callsign validity: ") + c.input);
        if (result) {
            check(*result == c.expected, std::string("native callsign value: ") + c.input);
            check(wirex::radio_identity_cache::Cache::is_valid_callsign(*result),
                  std::string("native callsign passes Native validator: ") + c.input);
        }
    }

    check(sanitize_text("  a\x01" "b\x7f  ") == std::optional<std::string>("ab"), "control bytes removed and trimmed");
    check(!sanitize_text(" \t ").has_value(), "blank text becomes null");
    check(sanitize_text(std::string(200U, 'x'))->size() == 128U, "text truncated to 128 units");
    const std::string chinese = "\xE4\xB8\xAD";   // 中（1 个 UTF-16 单元）
    std::string many;
    for (int i = 0; i < 130; ++i) many += chinese;
    check(sanitize_text(many)->size() == 128U * 3U, "CJK truncation counts UTF-16 units without splitting bytes");

    check(build_query_url(official_base_uri, 7654321U) == "https://radioid.net/api/dmr/user/?id=7654321&id_sel=%3D",
          "official query URL matches PS");
    check(is_allowed_base_uri("https://radioid.net/api/dmr/user/"), "official base allowed");
    check(is_allowed_base_uri("http://127.0.0.1:8080/api/"), "loopback HTTP fixture allowed");
    check(!is_allowed_base_uri("http://user@127.0.0.1/"), "userinfo rejected");
    check(!is_allowed_base_uri("https://example.org/api/"), "other HTTPS host rejected");
    check(!is_allowed_base_uri("http://radioid.net/api/dmr/user/"), "plain HTTP remote rejected");
    check(is_valid_user_agent(user_agent), "default UA valid");
    check(!is_valid_user_agent("curl/8"), "UA without product rejected");
    check(!is_valid_user_agent("WIREX Bridge/0.1"), "UA without contact rejected");

    const auto t = parse_timestamp("2026-11-03T12:34:56.1234567+00:00");
    check(t.has_value() && format_timestamp(*t) == "2026-11-03T12:34:56.1234567+00:00", "timestamp round trip");
    const auto offset = parse_timestamp("2026-11-03T20:34:56+08:00");
    check(offset && format_timestamp(*offset) == "2026-11-03T12:34:56.0000000+00:00", "offset normalized to UTC");
    check(parse_timestamp("2026-11-03T12:34:56Z").has_value(), "Z suffix accepted");
    check(parse_timestamp("2026-11-03T12:34:56").has_value(), "no zone assumed UTC");
    check(!parse_timestamp("not a date").has_value(), "garbage rejected");
}

void test_response_parsing()
{
    struct Case { const char* name; std::string body; std::uint32_t id; ParseState state; const char* callsign; const char* name_value; };
    const std::vector<Case> cases{
        {"results wrapper", valid_body, 7654321U, ParseState::found, "N0TEST", "Test Operator"},
        {"fname+surname synthesize name",
         R"({"count":1,"results":[{"id":7654325,"radio_id":7654325,"callsign":"N1TEST","fname":"First","surname":"Last","city":"Fixture City"}]})",
         7654325U, ParseState::found, "N1TEST", "First Last"},
        {"empty results", R"({"count":0,"page":1,"pages":1,"per_page":100,"results":[]})", 1U, ParseState::not_found, nullptr, nullptr},
        {"null results", R"({"results":null})", 1U, ParseState::not_found, nullptr, nullptr},
        {"id mismatch", R"({"results":[{"id":7654999,"callsign":"N9OTHER"}]})", 7654323U, ParseState::mismatch, nullptr, nullptr},
        {"conflict", R"({"results":[{"id":7654324,"callsign":"N4ONE"},{"id":7654324,"callsign":"N4OTHER"}]})",
         7654324U, ParseState::conflict, nullptr, nullptr},
        {"identical duplicates", R"({"results":[{"id":5,"callsign":"N5A"},{"id":5,"callsign":"N5A"}]})", 5U, ParseState::found, "N5A", nullptr},
        {"bare array", R"([{"radio_id":"42","callsign":"K42"}])", 42U, ParseState::found, "K42", nullptr},
        {"single object", R"({"id":43,"callsign":"K43"})", 43U, ParseState::found, "K43", nullptr},
        {"no ids", R"({"results":[{"callsign":"X"}]})", 1U, ParseState::invalid, nullptr, nullptr},
        {"unrelated object", R"({"foo":1})", 1U, ParseState::invalid, nullptr, nullptr},
        {"results not array", R"({"results":{}})", 1U, ParseState::invalid, nullptr, nullptr},
        {"bad json", "{", 1U, ParseState::invalid, nullptr, nullptr},
        {"oversized", std::string(262145U, ' '), 1U, ParseState::invalid, nullptr, nullptr},
    };
    for (const auto& c : cases) {
        const auto parsed = parse_response(c.body, c.id);
        check(parsed.state == c.state, std::string("parse state: ") + c.name);
        if (c.callsign != nullptr) check(parsed.record.callsign == std::optional<std::string>(c.callsign), std::string("callsign: ") + c.name);
        if (c.name_value != nullptr) check(parsed.record.name == std::optional<std::string>(c.name_value), std::string("name: ") + c.name);
    }
}

void test_cache_compat_and_query()
{
    const auto dir = test_dir();
    const auto path = cache_path(dir);
    check(path.filename() == "radio-identity-cache.json", "cache file name matches PS");

    // PS ConvertTo-Json 风格（BOM、4 空格缩进、null 字段、数字 id）
    const auto now = Clock::now();
    const auto fresh = format_timestamp(now - std::chrono::hours(1));
    const auto old = format_timestamp(now - std::chrono::hours(24 * 31));
    const std::string ps_file = "\xEF\xBB\xBF{\r\n    \"schema_version\":  1,\r\n    \"entries\":  [\r\n"
        "                    {\r\n                        \"id\":  1001,\r\n                        \"callsign\":  \"bi7abc\",\r\n"
        "                        \"name\":  \"Test\",\r\n                        \"city\":  null,\r\n                        \"state\":  null,\r\n"
        "                        \"country\":  \"China\",\r\n                        \"source\":  \"RadioID.net\",\r\n"
        "                        \"fetched_at_utc\":  \"" + fresh + "\",\r\n                        \"status\":  \"found\"\r\n                    },\r\n"
        "                    {\r\n                        \"id\":  1002,\r\n                        \"callsign\":  \"N0OLD\",\r\n"
        "                        \"source\":  \"RadioID.net\",\r\n                        \"fetched_at_utc\":  \"" + old + "\",\r\n"
        "                        \"status\":  \"found\"\r\n                    },\r\n"
        "                    {\r\n                        \"id\":  1001,\r\n                        \"callsign\":  \"DUP\",\r\n"
        "                        \"fetched_at_utc\":  \"" + fresh + "\",\r\n                        \"status\":  \"found\"\r\n                    }\r\n"
        "                ]\r\n}";
    {
        std::ofstream stream(path, std::ios::binary);
        stream << ps_file;
    }
    const auto entries = read_cache(path);
    check(entries.size() == 3U && entries[0].id == 1001U && !entries[0].city.has_value(), "PS cache file is readable");

    auto resolved = resolve(1001U, path);
    check(resolved.status == Status::found && resolved.callsign == std::optional<std::string>("bi7abc") &&
              resolved.display_name == "bi7abc (Test)", "fresh entry resolves found");
    resolved = resolve(1002U, path);
    check(resolved.status == Status::stale, "entry older than 30 days is stale");
    resolved = resolve(1003U, path);
    check(resolved.status == Status::unavailable && resolved.display_name == "DMR ID 1003", "missing entry unavailable");

    const auto mappings = native_mappings(path);
    check(mappings.size() == 1U && mappings[0].source_id == 1001U && mappings[0].callsign == "BI7ABC",
          "native mappings: fresh, first-per-id, uppercase");
    check(mappings[0].country == std::optional<std::string>("China") && !mappings[0].state.has_value(),
          "native mappings carry country/state for call display");

    // 新鲜度规则
    CacheEntry entry{};
    entry.status = "not_found";
    entry.fetched_at_utc = format_timestamp(now - std::chrono::hours(23));
    check(is_fresh(entry, now), "negative entry within 1 day is fresh");
    entry.fetched_at_utc = format_timestamp(now - std::chrono::hours(25));
    check(!is_fresh(entry, now), "negative entry after 1 day is stale");
    entry.status = "found";
    entry.fetched_at_utc = format_timestamp(now + std::chrono::minutes(10));
    check(!is_fresh(entry, now), "future timestamp beyond 5 minutes not fresh");
    entry.status = "stale";
    entry.fetched_at_utc = format_timestamp(now);
    check(!is_fresh(entry, now), "unknown status not fresh");

    // 查询 → 保存：新条目置顶，去掉同 ID 旧条目
    std::vector<HttpRequest> seen;
    QueryOptions options{};
    options.transport = respond(200, R"({"results":[{"id":1001,"callsign":"BI7NEW","fname":"New","surname":"Name"}]})", &seen);
    auto result = query(1001U, path, options);
    check(result.status == Status::found && result.cache_saved && result.display_name == "BI7NEW (New Name)",
          "query found and saved");
    check(seen.size() == 1U && seen[0].url == "https://radioid.net/api/dmr/user/?id=1001&id_sel=%3D" &&
              seen[0].user_agent == user_agent && seen[0].timeout_ms == 5000U, "query request matches PS");
    const auto saved_text = read_file(path);
    check(saved_text.rfind("\xEF\xBB\xBF{", 0U) == 0U, "saved cache has UTF-8 BOM");
    const auto saved = read_cache(path);
    check(saved.size() == 2U && saved[0].id == 1001U && saved[0].callsign == std::optional<std::string>("BI7NEW") &&
              saved[1].id == 1002U, "new entry first, duplicates removed");
    check(saved[0].source == std::optional<std::string>("RadioID.net") && saved[0].status == "found" &&
              !saved[0].city.has_value(), "saved fields follow PS schema");

    options.transport = respond(200, R"({"count":0,"results":[]})");
    result = query(1005U, path, options);
    check(result.status == Status::not_found && result.display_name == "DMR ID 1005", "empty results → not_found");
    check(read_cache(path).front().status == "not_found", "negative entry persisted");

    // 失败回退表
    struct FailCase { const char* name; HttpTransport transport; std::uint32_t id; Status status; const char* code; };
    const std::vector<FailCase> failures{
        {"timeout with cache", fail_with(HttpErrorKind::timeout), 1001U, Status::stale, "timeout"},
        {"canceled", fail_with(HttpErrorKind::canceled), 1001U, Status::stale, "cancelled"},
        {"network no cache", fail_with(HttpErrorKind::transport), 9999U, Status::unavailable, "network"},
        {"http 503", respond(503, ""), 9999U, Status::unavailable, "http_503"},
        {"mismatch", respond(200, R"({"results":[{"id":7654999,"callsign":"N9OTHER"}]})"), 9999U, Status::unavailable, "invalid_response"},
        {"conflict", respond(200, R"({"results":[{"id":9999,"callsign":"N4ONE"},{"id":9999,"callsign":"N4OTHER"}]})"),
         9999U, Status::unavailable, "invalid_response"},
        {"oversized", respond(200, std::string(262145U, ' ')), 9999U, Status::unavailable, "invalid_response"},
    };
    for (const auto& c : failures) {
        options.transport = c.transport;
        result = query(c.id, path, options);
        check(result.status == c.status, std::string("fallback status: ") + c.name);
        check(result.error_code == std::optional<std::string>(c.code), std::string("fallback code: ") + c.name);
    }

    // 参数校验
    options.transport = respond(200, valid_body);
    check(query(0U, path, options).error_code == std::optional<std::string>("invalid_request"), "ID 0 rejected");
    check(query(16777216U, path, options).error_code == std::optional<std::string>("invalid_request"), "ID > 24 bit rejected");
    auto bad = options;
    bad.timeout_seconds = 6U;
    check(query(1U, path, bad).error_code == std::optional<std::string>("invalid_request"), "timeout > 5 s rejected");
    bad = options;
    bad.base_uri = "https://evil.example/";
    check(query(1U, path, bad).error_code == std::optional<std::string>("invalid_request"), "foreign base URI rejected");

    // 128 条上限
    for (std::uint32_t id = 2000U; id < 2140U; ++id) {
        CacheEntry e{};
        e.id = id;
        e.callsign = "N" + std::to_string(id);
        e.status = "found";
        e.source = std::string(source_name);
        e.fetched_at_utc = format_timestamp(now);
        std::string error;
        check(save_cache_entry(path, e, &error), "bulk save succeeds");
    }
    const auto capped = read_cache(path);
    check(capped.size() == cache_entry_limit && capped.front().id == 2139U, "cache capped to 128, newest first");
    std::error_code ec;
    std::size_t leftovers = 0U;
    for (const auto& item : std::filesystem::directory_iterator(dir, ec)) {
        if (item.path().filename().string().rfind(".radio-identity-cache-", 0U) == 0U) ++leftovers;
    }
    check(leftovers == 0U, "no temporary files left behind");

    // 损坏的缓存不报错，读为空
    {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        stream << "{\"schema_version\":2,\"entries\":[]}";
    }
    check(read_cache(path).empty(), "unknown schema treated as empty cache");
}

} // namespace

int main()
{
    test_pure_helpers();
    test_response_parsing();
    test_cache_compat_and_query();
    std::cout << "PASS: app_radio_identity_test (" << assertions << " assertions, no network)\n";
    return EXIT_SUCCESS;
}
