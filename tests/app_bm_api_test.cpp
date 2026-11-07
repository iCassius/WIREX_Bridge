// BM API / BM 服务器目录离线测试；样例取自 tools/test-bm-management.ps1 与 BmServers.psm1。
// 只使用注入的假 transport，不访问网络。

#include "wirex/app/bm_api.hpp"
#include "wirex/app/bm_servers.hpp"

#include <atomic>
#include <cstdlib>
#include <optional>
#include <stdexcept>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

using namespace wirex::app;
using namespace wirex::app::bm_api;

int assertions = 0;

void check(bool condition, const std::string& description)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

const std::string fake_token = std::string(100U, 'a') + "." + std::string(100U, 'b') + "." + std::string(100U, 'c');

ApiKey make_key()
{
    auto key = ApiKey::from_text(fake_token);
    check(key.has_value(), "fake token is a valid key");
    return std::move(*key);
}

struct Recorded {
    std::string method;
    std::string url;
    std::string authorization;
    std::string accept;
    std::string content_type;
    std::string body;
    std::uint32_t timeout_ms{};
    bool read_body{};
};

struct FakeServer {
    std::deque<HttpResponse> responses;
    std::vector<Recorded> requests;

    HttpTransport transport()
    {
        return [this](const HttpRequest& request, const std::atomic<bool>*) {
            Recorded record{request.method, request.url, {}, {}, {}, request.body, request.timeout_ms,
                            request.read_body_on_success};
            for (const auto& header : request.headers) {
                if (header.name == "Authorization") record.authorization = header.value;
                if (header.name == "Accept") record.accept = header.value;
                if (header.name == "Content-Type") record.content_type = header.value;
            }
            requests.push_back(record);
            if (responses.empty()) return HttpResponse{HttpErrorKind::transport, 0, {}, 0U};
            auto next = responses.front();
            responses.pop_front();
            return next;
        };
    }

    void reset(std::vector<HttpResponse> next)
    {
        responses.assign(next.begin(), next.end());
        requests.clear();
    }
};

HttpResponse ok(int status, std::string body) { return HttpResponse{HttpErrorKind::none, status, std::move(body), 0U}; }
HttpResponse err(HttpErrorKind kind) { return HttpResponse{kind, 0, {}, 0U}; }

bool contains_token(const std::string& text) { return text.find(fake_token) != std::string::npos; }

void test_key_validation()
{
    struct Case { const char* name; std::string text; bool valid; };
    const std::vector<Case> cases{
        {"three base64url segments >=200 chars", fake_token, true},
        {"surrounding whitespace is trimmed", "  " + fake_token + "\n", true},
        {"short token rejected", "synthetic-invalid-direct-key", false},
        {"two segments rejected", std::string(150U, 'a') + "." + std::string(150U, 'b'), false},
        {"illegal character rejected", std::string(100U, 'a') + ".b+b." + std::string(100U, 'c'), false},
        {"empty segment rejected", std::string(200U, 'a') + "..c", false},
        {"empty rejected", "", false},
    };
    for (const auto& c : cases) {
        Error error{};
        const auto key = ApiKey::from_text(c.text, &error);
        check(key.has_value() == c.valid, std::string("key: ") + c.name);
        if (!c.valid) {
            check(error.kind == ErrorKind::invalid_key, std::string("key error kind: ") + c.name);
            check(error.message.find(c.text.empty() ? "\x01" : c.text) == std::string::npos,
                  std::string("key error does not echo input: ") + c.name);
        }
    }

    check(extract_key_from_file_content("[key]\napikey=" + fake_token + "\n") == fake_token,
          "Pi-Star style apikey= line is extracted");
    check(extract_key_from_file_content("\xEF\xBB\xBF  " + fake_token + "\r\n") == fake_token,
          "BOM and whitespace are stripped from key files");
    check(extract_key_from_file_content(" APIKEY = " + fake_token) == fake_token, "apikey match is case-insensitive");

    const auto dir = std::filesystem::absolute("tmp/svc-bm/keyfiles");
    std::filesystem::create_directories(dir);
    {
        std::ofstream(dir / "pistar.ini", std::ios::binary) << "[key]\napikey=" << fake_token << "\n";
        std::ofstream(dir / "invalid.txt", std::ios::binary) << "synthetic-invalid-token-content";
    }
    Error error{};
    check(ApiKey::from_file(dir / "pistar.ini", &error).has_value(), "Pi-Star style key file accepted");
    const auto invalid = ApiKey::from_file(dir / "invalid.txt", &error);
    check(!invalid && error.kind == ErrorKind::invalid_key &&
              error.message.find("synthetic-invalid-token-content") == std::string::npos,
          "invalid key file rejected without echoing content");
    check(!ApiKey::from_file("relative.txt", &error) && error.kind == ErrorKind::invalid_key,
          "relative key file path rejected");
    check(!ApiKey::from_file(dir / "missing.txt", &error), "missing key file rejected");
}

void test_device_id_and_request_building()
{
    struct IdCase { const char* text; bool valid; };
    const std::vector<IdCase> ids{
        {"460999901", true}, {"1", true}, {"4294967295", true}, {"0", false}, {"4294967296", false},
        {"460999901/elsewhere", false}, {"", false}, {"-1", false}, {"12345678901", false},
    };
    for (const auto& c : ids) check(parse_device_id(c.text).has_value() == c.valid, std::string("device id ") + c.text);

    const auto key = make_key();
    struct ReqCase {
        const char* name; const char* method; const char* resource; const char* suffix;
        const char* url; bool valid;
    };
    const std::vector<ReqCase> cases{
        {"static list GET", "GET", "talkgroup", "", "https://api.brandmeister.network/v2/device/460999901/talkgroup", true},
        {"device GET", "GET", "", "", "https://api.brandmeister.network/v2/device/460999901", true},
        {"add POST", "POST", "talkgroup", "", "https://api.brandmeister.network/v2/device/460999901/talkgroup", true},
        {"remove DELETE", "DELETE", "talkgroup", "/2/91",
         "https://api.brandmeister.network/v2/device/460999901/talkgroup/2/91", true},
        {"device only allows GET", "POST", "", "", "", false},
        {"suffix only on DELETE", "GET", "talkgroup", "/2/91", "", false},
        {"suffix must be digits", "DELETE", "talkgroup", "/2/../x", "", false},
        {"unknown resource", "GET", "profile", "", "", false},
        {"unknown method", "PUT", "talkgroup", "", "", false},
    };
    for (const auto& c : cases) {
        auto request = build_request(c.method, 460999901U, c.resource, c.suffix, key, 2500U);
        check(request.method.empty() == !c.valid, std::string("request validity: ") + c.name);
        if (!c.valid) continue;
        check(request.url == c.url, std::string("request url: ") + c.name);
        check(request.timeout_ms == 2500U, std::string("timeout reaches request: ") + c.name);
        bool bearer = false;
        bool accept = false;
        bool content_type = false;
        for (const auto& h : request.headers) {
            if (h.name == "Authorization" && h.value == "Bearer " + fake_token) bearer = true;
            if (h.name == "Accept" && h.value == "application/json") accept = true;
            if (h.name == "Content-Type" && h.value == "application/json; charset=utf-8") content_type = true;
        }
        check(bearer && accept, std::string("bearer+accept headers: ") + c.name);
        check(content_type == (std::string(c.method) == "POST"), std::string("content type only on POST: ") + c.name);
        check(request.read_body_on_success == (std::string(c.method) == "GET"), std::string("body read only for GET: ") + c.name);
        request.wipe();
        check(request.headers.empty(), std::string("wipe clears headers: ") + c.name);
    }
    check(build_request("GET", 1U, "talkgroup", "", key, 0U).method.empty(), "timeout 0 rejected");
    check(build_request("GET", 1U, "talkgroup", "", key, 10001U).method.empty(), "timeout above 10000 rejected");
    check(build_add_body(12345U, 1) == "{\"slot\":1,\"group\":12345}", "POST body contains only slot and group");
    check(build_add_body(91U, 0) == "{\"slot\":0,\"group\":91}", "slot 0 POST body preserved");
}

void test_list_parsing()
{
    struct Case { const char* name; std::string json; bool ok; std::size_t count; };
    const std::vector<Case> cases{
        {"two items with extra fields",
         R"([{"talkgroup":91,"slot":2,"repeaterid":460999901},{"talkgroup":46001,"slot":1,"repeaterid":460999901}])", true, 2U},
        {"empty array", "[]", true, 0U},
        {"slot 0 simplex", R"([{"talkgroup":91,"slot":0}])", true, 1U},
        {"string numbers accepted like PS", R"([{"talkgroup":"91","slot":"2"}])", true, 1U},
        {"BOM + whitespace", "\xEF\xBB\xBF [ ] ", true, 0U},
        {"legacy profile object rejected", R"({"staticSubscriptions":[{"talkgroup":91,"slot":2}]})", false, 0U},
        {"malformed TG", R"([{"talkgroup":"<script>","slot":2}])", false, 0U},
        {"wrong field name", R"([{"group":91,"slot":2}])", false, 0U},
        {"slot 3 rejected", R"([{"talkgroup":91,"slot":3}])", false, 0U},
        {"TG 0 rejected", R"([{"talkgroup":0,"slot":2}])", false, 0U},
        {"TG above 24-bit rejected", R"([{"talkgroup":16777216,"slot":2}])", false, 0U},
        {"duplicates rejected", R"([{"talkgroup":91,"slot":2},{"talkgroup":91,"slot":2}])", false, 0U},
        {"invalid json", "[{", false, 0U},
        {"unrelated negative/decimal fields accepted", R"([{"talkgroup":91,"slot":2,"x":-1,"y":1.5}])", true, 1U},
        {"negative TG rejected", R"([{"talkgroup":-91,"slot":2}])", false, 0U},
        {"decimal TG rejected", R"([{"talkgroup":91.0,"slot":2}])", false, 0U},
        {"exponent slot rejected", R"([{"talkgroup":91,"slot":2e0}])", false, 0U},
        {"escaped member name accepted", R"([{"talkgroup":91,"slot":2}])", true, 1U},
    };
    for (const auto& c : cases) {
        std::vector<StaticGroup> groups;
        Error error{};
        const bool ok = parse_static_group_list(c.json, 460999901U, groups, &error);
        check(ok == c.ok, std::string("list parse: ") + c.name);
        if (ok) check(groups.size() == c.count, std::string("list count: ") + c.name);
        else check(error.kind == ErrorKind::invalid_response, std::string("list error kind: ") + c.name);
    }
    std::vector<StaticGroup> groups;
    check(parse_static_group_list(R"([{"talkgroup":91,"slot":2}])", 460999901U, groups) &&
              groups[0].talkgroup == 91U && groups[0].slot == 2 && groups[0].device_id == 460999901U,
          "list preserves TG, slot and device id");
}

void test_add_context()
{
    struct Case { const char* name; std::string json; bool success; std::optional<std::int64_t> status; std::optional<int> slot; };
    const std::vector<Case> cases{
        {"status 4 → slot 0", R"({"id":460999901,"status":4,"callsign":"PRIVATE-CALL"})", true, 4, 0},
        {"status 0 → slot 2", R"({"id":460999901,"status":0})", true, 0, 2},
        {"status 1 → slot 2", R"({"id":460999901,"status":1})", true, 1, 2},
        {"status 2 → slot 2", R"({"id":460999901,"status":2})", true, 2, 2},
        {"status 3 → slot 2", R"({"id":460999901,"status":3})", true, 3, 2},
        {"null status", R"({"id":460999901,"status":null})", false, std::nullopt, std::nullopt},
        {"unknown numeric status kept", R"({"id":460999901,"status":5})", false, 5, std::nullopt},
        {"string status", R"({"id":460999901,"status":"4"})", false, std::nullopt, std::nullopt},
        {"bool status", R"({"id":460999901,"status":true})", false, std::nullopt, std::nullopt},
        {"missing status", R"({"id":460999901})", false, std::nullopt, std::nullopt},
        {"mismatched id", R"({"id":460999902,"status":4})", false, std::nullopt, std::nullopt},
        {"array body", "[]", false, std::nullopt, std::nullopt},
        // 真实设备响应含经纬度等负数/小数字段：与 PS ConvertFrom-Json 一致，不影响 id/status 解析。
        {"negative/decimal fields ignored", R"({"id":460999901,"status":4,"lat":-33.5,"lng":151.2})", true, 4, 0},
        {"negative status rejected", R"({"id":460999901,"status":-1})", false, std::nullopt, std::nullopt},
        {"decimal status rejected", R"({"id":460999901,"status":4.0})", false, std::nullopt, std::nullopt},
    };
    for (const auto& c : cases) {
        const auto ctx = parse_add_context(c.json, 460999901U);
        check(ctx.success == c.success, std::string("context success: ") + c.name);
        check(ctx.status == c.status, std::string("context status: ") + c.name);
        check(ctx.add_slot == c.slot, std::string("context slot: ") + c.name);
    }
}

void test_classification()
{
    struct Case { const char* name; HttpResponse response; ErrorKind kind; int http; };
    const std::vector<Case> cases{
        {"200 ok", ok(200, "[]"), ErrorKind::none, 0},
        {"201 ok", ok(201, ""), ErrorKind::none, 0},
        {"204 ok", ok(204, ""), ErrorKind::none, 0},
        {"403 http", ok(403, "{\"message\":\"denied\",\"echo\":\"" + fake_token + "\"}"), ErrorKind::http_status, 403},
        {"401 http", ok(401, ""), ErrorKind::http_status, 401},
        {"302 redirect is error", ok(302, ""), ErrorKind::http_status, 302},
        {"500 http", ok(500, ""), ErrorKind::http_status, 500},
        {"timeout", err(HttpErrorKind::timeout), ErrorKind::timeout, 0},
        {"canceled", err(HttpErrorKind::canceled), ErrorKind::canceled, 0},
        {"transport", err(HttpErrorKind::transport), ErrorKind::transport, 0},
        {"too large", err(HttpErrorKind::too_large), ErrorKind::too_large, 0},
    };
    for (const auto& c : cases) {
        const auto error = classify(c.response);
        check(error.kind == c.kind, std::string("classify kind: ") + c.name);
        check(error.http_status == c.http, std::string("classify http: ") + c.name);
        check(!contains_token(error.message), std::string("classify message has no token: ") + c.name);
    }
}

void test_client_flows()
{
    FakeServer server;
    Client client(server.transport());
    const auto key = make_key();

    server.reset({ok(200, R"([{"talkgroup":91,"slot":2,"repeaterid":460999901},{"talkgroup":46001,"slot":1}])")});
    auto list = client.list_static_groups(key, "460999901", 2500U);
    check(!list.error && list.groups.size() == 2U, "GET returns static groups");
    check(server.requests.size() == 1U && server.requests[0].method == "GET" &&
              server.requests[0].url == "https://api.brandmeister.network/v2/device/460999901/talkgroup",
          "GET targets the static talkgroup endpoint");
    check(server.requests[0].authorization == "Bearer " + fake_token, "explicit token becomes Bearer authorization");
    check(server.requests[0].timeout_ms == 2500U, "caller timeout reaches transport");

    server.reset({ok(200, R"({"id":460999901,"status":4,"callsign":"PRIVATE-CALL"})")});
    auto context = client.get_add_context(key, "460999901");
    check(!context.error && context.context.success && context.context.add_slot == 0, "device context selects slot 0");
    check(server.requests[0].url == "https://api.brandmeister.network/v2/device/460999901", "device endpoint used");
    check(server.requests[0].timeout_ms == default_timeout_ms, "default timeout 3000 ms");

    server.reset({ok(403, "{\"message\":\"denied\",\"echo\":\"" + fake_token + "\"}")});
    context = client.get_add_context(key, "460999901");
    check(context.error.kind == ErrorKind::http_status && context.error.http_status == 403 &&
              !contains_token(context.error.message), "device HTTP 403 rejected without echoing token");

    server.reset({ok(201, ""), ok(200, R"([{"talkgroup":91,"slot":2},{"talkgroup":12345,"slot":1}])")});
    auto add = client.add_static_group(key, "460999901", 12345U, 1);
    check(!add.error && add.write_accepted && add.readback_status == ReadbackStatus::confirmed, "POST then confirming GET");
    check(server.requests.size() == 2U && server.requests[0].method == "POST" && server.requests[1].method == "GET",
          "add order POST then GET");
    check(server.requests[0].body == "{\"slot\":1,\"group\":12345}" &&
              server.requests[0].content_type == "application/json; charset=utf-8", "POST body and content type");

    server.reset({ok(204, ""), ok(200, "[]")});
    auto remove = client.remove_static_group(key, "460999901", 91U, 2);
    check(!remove.error && remove.readback_status == ReadbackStatus::confirmed, "DELETE then confirming GET");
    check(server.requests[0].method == "DELETE" &&
              server.requests[0].url == "https://api.brandmeister.network/v2/device/460999901/talkgroup/2/91",
          "DELETE URI includes slot and talkgroup");

    server.reset({ok(200, R"({"success":true})"), ok(200, R"([{"talkgroup":91,"slot":0}])")});
    add = client.add_static_group(key, "460999901", 91U, 0);
    check(add.readback_status == ReadbackStatus::confirmed && server.requests[0].body == "{\"slot\":0,\"group\":91}",
          "slot 0 add confirmed");

    server.reset({ok(201, ""), ok(200, "[]")});
    add = client.add_static_group(key, "460999901", 12345U, 1);
    check(add.write_accepted && add.readback_status == ReadbackStatus::not_confirmed, "absent after add is not_confirmed");

    // 写后回读失败的表驱动场景
    struct ReadbackCase { const char* name; HttpResponse readback; ReadbackStatus status; const char* error; };
    const std::vector<ReadbackCase> readbacks{
        {"readback timeout", err(HttpErrorKind::timeout), ReadbackStatus::unavailable, "timeout"},
        {"readback canceled", err(HttpErrorKind::canceled), ReadbackStatus::canceled, "canceled"},
        {"readback transport", err(HttpErrorKind::transport), ReadbackStatus::unavailable, "unavailable"},
        {"readback http 500", ok(500, ""), ReadbackStatus::unavailable, "unavailable"},
        {"readback bad json", ok(200, "{"), ReadbackStatus::unavailable, "unavailable"},
    };
    for (const auto& c : readbacks) {
        server.reset({ok(201, ""), c.readback});
        add = client.add_static_group(key, "460999901", 23456U, 2);
        check(!add.error && add.write_accepted && add.readback_status == c.status && add.readback_error == c.error,
              std::string("write accepted, ") + c.name);
        check(server.requests.size() == 2U && server.requests[0].method == "POST",
              std::string("no write retry after ") + c.name);
    }

    // 写失败：不回读、不重试
    struct WriteFailCase { const char* name; bool remove; HttpResponse response; ErrorKind kind; };
    const std::vector<WriteFailCase> write_failures{
        {"POST 403", false, ok(403, "{\"echo\":\"" + fake_token + "\"}"), ErrorKind::http_status},
        {"DELETE 403", true, ok(403, "{\"echo\":\"" + fake_token + "\"}"), ErrorKind::http_status},
        {"POST transport loss", false, err(HttpErrorKind::transport), ErrorKind::transport},
        {"POST canceled", false, err(HttpErrorKind::canceled), ErrorKind::canceled},
        {"POST timeout", false, err(HttpErrorKind::timeout), ErrorKind::timeout},
    };
    for (const auto& c : write_failures) {
        server.reset({c.response, ok(200, "[]")});
        const auto result = c.remove ? client.remove_static_group(key, "460999901", 91U, 2)
                                     : client.add_static_group(key, "460999901", 23457U, 2);
        check(result.error.kind == c.kind && !result.write_accepted, std::string("write failure kind: ") + c.name);
        check(server.requests.size() == 1U, std::string("no readback or retry: ") + c.name);
        check(!contains_token(result.error.message), std::string("write error has no token: ") + c.name);
    }

    // 请求前即被拒绝的情况
    std::atomic<bool> canceled{true};
    server.reset({ok(200, "[]")});
    list = client.list_static_groups(key, "460999901", default_timeout_ms, &canceled);
    check(list.error.kind == ErrorKind::canceled && server.requests.empty(), "pre-canceled GET makes no request");

    server.reset({ok(200, "[]")});
    list = client.list_static_groups(key, "460999901/elsewhere");
    check(list.error.kind == ErrorKind::invalid_request && server.requests.empty(), "path injection rejected before transport");

    server.reset({ok(201, "")});
    add = client.add_static_group(key, "460999901", 91U, 3);
    check(add.error.kind == ErrorKind::invalid_request && server.requests.empty(), "slot 3 add rejected before transport");

    server.reset({ok(201, "")});
    add = client.add_static_group(key, "460999901", 0U, 2);
    check(add.error.kind == ErrorKind::invalid_request && server.requests.empty(), "TG 0 rejected before transport");

    server.reset({ok(200, "[]")});
    list = client.list_static_groups(ApiKey{}, "460999901");
    check(list.error.kind == ErrorKind::invalid_key && server.requests.empty(), "empty key rejected before transport");

    server.reset({ok(200, "[]")});
    list = client.list_static_groups(key, "460999901", 20000U);
    check(list.error.kind == ErrorKind::invalid_request && server.requests.empty(), "timeout above 10 s rejected");

    // 抛异常的 transport 被归类为 transport，不泄露 token
    Client throwing([](const HttpRequest&, const std::atomic<bool>*) -> HttpResponse { throw std::runtime_error(fake_token); });
    list = throwing.list_static_groups(key, "460999901");
    check(list.error.kind == ErrorKind::transport && !contains_token(list.error.message), "throwing transport classified");
}

void test_servers()
{
    using namespace wirex::app::bm_servers;
    check(catalog.size() == 5U, "catalog has five masters");
    check(find_entry("bm-china-4602") != nullptr && find_entry("bm-china-4602")->master_id == 4602U &&
              find_entry("bm-china-4602")->address_aliases[0] == "43.129.83.124", "4602 entry with IPv4 alias");
    check(find_entry("BM-CHINA-4602") == nullptr, "selection ids are case-sensitive");
    for (const auto& entry : catalog) check(entry.port == 62031U, std::string("port 62031: ") + std::string(entry.selection_id));

    struct Case {
        const char* name; const char* id; const char* address; std::uint16_t port;
        const char* expected_id; SelectionSource source; bool matches; const char* effective; std::uint16_t effective_port;
    };
    const std::vector<Case> cases{
        {"empty profile → default", "", "", 0U, "bm-china-4602", SelectionSource::default_entry, false,
         "4602.master.brandmeister.network", 62031U},
        {"preference wins", "bm-us-3102", "43.129.83.124", 62031U, "bm-us-3102", SelectionSource::preference, false,
         "43.129.83.124", 62031U},
        {"explicit custom preference", "CUSTOM", "", 0U, "custom", SelectionSource::preference, false, "", 0U},
        {"profile IPv4 alias", "", "43.129.83.124", 62031U, "bm-china-4602", SelectionSource::profile, true,
         "43.129.83.124", 62031U},
        {"profile hostname case-insensitive", "", "3102.MASTER.brandmeister.network", 62031U, "bm-us-3102",
         SelectionSource::profile, true, "3102.MASTER.brandmeister.network", 62031U},
        {"wrong port → custom", "", "43.129.83.124", 62030U, "custom", SelectionSource::custom, false,
         "43.129.83.124", 62030U},
        {"unknown preference falls through", "bm-unknown", "2022.master.brandmeister.network", 62031U,
         "bm-greece-2022", SelectionSource::profile, true, "2022.master.brandmeister.network", 62031U},
    };
    for (const auto& c : cases) {
        const auto s = resolve_selection(c.id, c.address, c.port);
        check(s.selection_id == c.expected_id, std::string("selection id: ") + c.name);
        check(s.source == c.source, std::string("selection source: ") + c.name);
        check(s.profile_matches_selection == c.matches, std::string("profile match: ") + c.name);
        check(s.effective_address == c.effective && s.effective_port == c.effective_port,
              std::string("effective endpoint: ") + c.name);
        check(s.is_custom == (s.entry == nullptr), std::string("is_custom consistent: ") + c.name);
    }

    std::string error;
    auto values = new_selection_values("bm-china-4602", "43.129.83.124", 62031U, &error);
    check(values && values->master == "43.129.83.124" && values->master_port == 62031U, "same master keeps saved IPv4");
    values = new_selection_values("bm-us-3102", "43.129.83.124", 62031U, &error);
    check(values && values->master == "3102.master.brandmeister.network", "different master uses hostname");
    values = new_selection_values("custom", "example.org", 1234U, &error);
    check(values && values->selection_id == "custom" && values->master_port == 1234U, "custom endpoint accepted");
    check(!new_selection_values("custom", "", 1234U, &error), "custom empty address rejected");
    check(!new_selection_values("custom", "a b", 1234U, &error), "custom address with space rejected");
    check(!new_selection_values("custom", std::string(254U, 'a'), 1234U, &error), "custom address >253 rejected");
    check(!new_selection_values("custom", "example.org", 0U, &error), "custom port 0 rejected");
    check(!new_selection_values("bm-unknown", "", 0U, &error) && !error.empty(), "unknown selection rejected");
}

} // namespace

int main()
{
    test_key_validation();
    test_device_id_and_request_building();
    test_list_parsing();
    test_add_context();
    test_classification();
    test_client_flows();
    test_servers();
    std::cout << "PASS: app_bm_api_test (" << assertions << " assertions, no network)\n";
    return EXIT_SUCCESS;
}
