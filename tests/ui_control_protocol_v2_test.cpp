#include "wirex/ui_control_protocol.hpp"

#include <iostream>
#include <string>
#include <string_view>
#include <vector>

namespace {

int failures{};

void check(bool condition, std::string_view label)
{
    if (condition) return;
    std::cerr << "FAILED: " << label << '\n';
    ++failures;
}

std::string request(std::string_view run_id, std::string_view request_id,
                    std::string_view command, std::string_view prefix = "")
{
    return std::string(prefix) + "{\"schema_version\":2,\"run_id\":" +
        std::string("\"") + std::string(run_id) + "\",\"request_id\":\"" +
        std::string(request_id) + "\",\"command\":\"" + std::string(command) + "\"}";
}

void test_v1_compatibility()
{
    using wirex::ui_control::Parser;
    using wirex::ui_control::Result;
    Parser parser;
    check(parser.feed("Q\r\n") == Result::shutdown, "v1 keeps accepting Q CRLF");
    Parser eof_parser;
    check(eof_parser.eof() == Result::shutdown, "v1 EOF remains a shutdown request");
}

void test_json_line_framing()
{
    using wirex::ui_control::JsonLineParser;
    using wirex::ui_control::JsonLineStatus;
    std::vector<std::string> lines;
    JsonLineParser parser;
    const auto one = request("run-1", "a", "hello");
    const auto two = request("run-1", "b", "status");
    check(parser.feed(one.substr(0U, 17U), lines) == JsonLineStatus::pending,
          "fragment is held until LF");
    check(parser.feed(one.substr(17U) + "\r\n" + two + "\n", lines) == JsonLineStatus::complete,
          "one write can complete a fragment and contain a second frame");
    check(lines.size() == 2U && lines[0U] == one && lines[1U] == two,
          "split and coalesced JSONL frames preserve exact request bodies");
    check(parser.eof_at_frame_boundary(), "complete JSONL frames leave a clean EOF boundary");

    JsonLineParser partial;
    std::vector<std::string> partial_lines;
    check(partial.feed(one, partial_lines) == JsonLineStatus::pending,
          "unterminated JSON remains buffered");
    check(!partial.eof_at_frame_boundary(), "EOF after partial JSON is distinguishable from clean EOF");

    JsonLineParser partial_crlf;
    std::vector<std::string> partial_crlf_lines;
    check(partial_crlf.feed(one + "\r", partial_crlf_lines) == JsonLineStatus::pending &&
          !partial_crlf.eof_at_frame_boundary(),
          "a trailing CR remains pending and is an incomplete frame at EOF");
    check(partial_crlf.feed("\n", partial_crlf_lines) == JsonLineStatus::complete &&
          partial_crlf_lines.size() == 1U && partial_crlf_lines.front() == one &&
          partial_crlf.eof_at_frame_boundary(),
          "a CR followed by LF is stripped as one CRLF frame terminator");

    JsonLineParser embedded_cr;
    std::vector<std::string> embedded_cr_lines;
    check(embedded_cr.feed(one + "\rX\n", embedded_cr_lines) == JsonLineStatus::complete &&
          embedded_cr_lines.size() == 1U && embedded_cr_lines.front() == one + "\rX",
          "a CR not followed by LF remains part of the frame body");

    JsonLineParser blank;
    std::vector<std::string> blank_lines;
    check(blank.feed("\n", blank_lines) == JsonLineStatus::invalid,
          "empty JSONL frame is rejected");
}

void test_frame_size_boundaries()
{
    using wirex::ui_control::JsonLineParser;
    using wirex::ui_control::JsonLineStatus;
    using wirex::ui_control::max_json_line_bytes;
    const auto base = request("run-1", "x", "hello");
    const std::string exact = base + std::string(max_json_line_bytes - base.size(), ' ');
    std::vector<std::string> exact_lines;
    JsonLineParser exact_parser;
    check(exact.size() == max_json_line_bytes, "boundary fixture is exactly the configured limit");
    check(exact_parser.feed(exact + "\n", exact_lines) == JsonLineStatus::complete,
          "a frame at exactly the configured byte limit is accepted");
    check(exact_lines.size() == 1U && exact_lines.front() == exact,
          "exact-limit frame is emitted in full");
    JsonLineParser exact_crlf_parser;
    std::vector<std::string> exact_crlf_lines;
    check(exact_crlf_parser.feed(exact + "\r\n", exact_crlf_lines) == JsonLineStatus::complete &&
          exact_crlf_lines.size() == 1U && exact_crlf_lines.front() == exact,
          "a 4096-byte JSON body is accepted with a CRLF terminator");
    JsonLineParser repeated_cr_parser;
    std::vector<std::string> repeated_cr_lines;
    check(repeated_cr_parser.feed(exact + "\r\r\n", repeated_cr_lines) == JsonLineStatus::invalid,
          "only the single CR in CRLF is excluded from the 4096-byte body limit");
    wirex::ui_control::Dispatcher exact_dispatcher("run-1", false);
    (void)exact_dispatcher.ready_line(1U);
    const auto exact_result = exact_dispatcher.handle(exact_lines.front(), {});
    check(exact_result.json_line.find("\"result\":\"ok\"") != std::string::npos,
          "valid JSON with trailing whitespace is accepted at exactly 4096 bytes");

    const std::string too_long(max_json_line_bytes + 1U, 'x');
    JsonLineParser too_long_parser;
    std::vector<std::string> too_long_lines;
    check(too_long_parser.feed(too_long + "\n", too_long_lines) == JsonLineStatus::invalid,
          "a 4097-byte JSON body is rejected with an LF terminator");
    JsonLineParser too_long_crlf_parser;
    std::vector<std::string> too_long_crlf_lines;
    check(too_long_crlf_parser.feed(too_long + "\r\n", too_long_crlf_lines) == JsonLineStatus::invalid,
          "a 4097-byte JSON body is rejected with a CRLF terminator");
}

void test_ready_and_handshake()
{
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::StatusSnapshot;
    Dispatcher dispatcher("run-1", true);
    const auto ready = dispatcher.ready_line(1234U);
    check(ready.find("\"type\":\"control_ready\"") != std::string::npos &&
          ready.find("\"run_id\":\"run-1\"") != std::string::npos &&
          ready.find("\"control_seq\":1") != std::string::npos &&
          ready.find("\"process_id\":1234") != std::string::npos &&
          ready.find("\"diagnostic\":true") != std::string::npos,
          "control_ready exposes native run identity and diagnostic mode only");
    check(dispatcher.ready_line(999U).empty(), "control_ready is emitted once per run");

    StatusSnapshot snapshot{};
    snapshot.mode = "diagnostic";
    snapshot.phase = "protocol_diagnostic";
    snapshot.diagnostic = true;
    snapshot.bm_state = "not_started";
    snapshot.hri_ready = false;
    snapshot.radio_state = "unknown";
    const auto before_hello = dispatcher.handle(request("run-1", "pre", "status"), snapshot);
    check(before_hello.json_line.find("\"result\":\"rejected\"") != std::string::npos &&
          before_hello.json_line.find("\"error\":\"hello_required\"") != std::string::npos,
          "status is rejected until hello completes");
    const auto reused_pre_hello_id = dispatcher.handle(request("run-1", "pre", "hello"), snapshot);
    check(reused_pre_hello_id.json_line.find("\"error\":\"request_id_body_conflict\"") != std::string::npos,
          "a valid same-run rejection binds its request ID and rejects a different body");
    const auto hello_body = request("run-1", "hello-1", "hello");
    const auto hello = dispatcher.handle(hello_body, snapshot);
    check(hello.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          hello.json_line.find("\"supported_commands\":[\"hello\",\"status\",\"shutdown\"]") != std::string::npos &&
          hello.json_line.find("\"replayed\":false") != std::string::npos,
          "hello negotiates the implemented command set");
    const auto escaped_ascii = dispatcher.handle(
        "{\"schema_version\":2,\"run_id\":\"run-1\",\"request_id\":\"escaped\",\"command\":\"\\u0068ello\"}",
        snapshot);
    check(escaped_ascii.json_line.find("\"result\":\"ok\"") != std::string::npos,
          "valid ASCII JSON Unicode escapes are decoded before command matching");
    const auto status = dispatcher.handle(request("run-1", "status-1", "status"), snapshot);
    check(status.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          status.json_line.find("\"mode\":\"diagnostic\"") != std::string::npos &&
          status.json_line.find("\"bm_state\":\"not_started\"") != std::string::npos &&
          status.json_line.find("\"hri_ready\":false") != std::string::npos &&
          status.json_line.find("\"radio_state\":\"unknown\"") != std::string::npos,
          "diagnostic status explicitly reports no BM, HRI, or radio readiness");
}

void test_dispatch_isolation_and_replay()
{
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::StatusSnapshot;
    Dispatcher dispatcher("run-1", false);
    (void)dispatcher.ready_line(1234U);
    StatusSnapshot snapshot{};
    const auto hello = request("run-1", "hello", "hello");
    const auto first = dispatcher.handle(hello, snapshot);
    const auto replay = dispatcher.handle(hello, snapshot);
    check(replay.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          replay.json_line.find("\"replayed\":true") != std::string::npos,
          "same request body replays cached hello result");
    check(replay.json_line.find("\"control_seq\":" + std::to_string(dispatcher.control_seq())) != std::string::npos &&
          first.json_line != replay.json_line,
          "replayed ACK gets a new strictly increasing control sequence");

    const auto wrong_run = dispatcher.handle(request("old-run", "old", "shutdown"), snapshot);
    check(wrong_run.json_line.find("\"error\":\"stale_run_id\"") != std::string::npos &&
          !wrong_run.shutdown_requested,
          "stale run cannot stop the current run");
    const auto conflict = dispatcher.handle(request("run-1", "hello", "shutdown"), snapshot);
    check(conflict.json_line.find("\"error\":\"request_id_body_conflict\"") != std::string::npos &&
          !conflict.shutdown_requested,
          "same request ID with a different body is rejected without executing shutdown");

    const auto future = dispatcher.handle(request("run-1", "future", "rx_policy.replace"), snapshot);
    check(future.json_line.find("\"result\":\"unsupported\"") != std::string::npos &&
          !future.shutdown_requested,
          "future policy changes are explicitly unsupported");
    const auto shutdown_body = request("run-1", "stop", "shutdown");
    const auto shutdown = dispatcher.handle(shutdown_body, snapshot);
    const auto shutdown_replay = dispatcher.handle(shutdown_body, snapshot);
    check(shutdown.json_line.find("\"shutdown_requested\":true") != std::string::npos &&
          shutdown.shutdown_requested,
          "only shutdown requests process termination");
    check(shutdown_replay.shutdown_requested &&
          shutdown_replay.json_line.find("\"replayed\":true") != std::string::npos,
          "replayed shutdown acknowledges the cached result without changing its meaning");
    const auto after_shutdown = dispatcher.handle(request("run-1", "after-stop", "status"), snapshot);
    check(after_shutdown.json_line.find("\"error\":\"shutdown_in_progress\"") != std::string::npos,
          "new control work is rejected after shutdown begins");
}

void test_strict_json_envelope()
{
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::StatusSnapshot;
    Dispatcher dispatcher("run-1", false);
    (void)dispatcher.ready_line(1U);
    StatusSnapshot snapshot{};
    const std::vector<std::string> invalid{
        "{\"schema_version\":true,\"run_id\":\"run-1\",\"request_id\":\"a\",\"command\":\"hello\"}",
        "{\"schema_version\":2.0,\"run_id\":\"run-1\",\"request_id\":\"b\",\"command\":\"hello\"}",
        "{\"schema_version\":2,\"schema_version\":2,\"run_id\":\"run-1\",\"request_id\":\"c\",\"command\":\"hello\"}",
        "{\"schema_version\":2,\"run_id\":\"run-1\",\"request_id\":\"d\",\"command\":\"hello\",\"args\":{}}",
        "{\"schema_version\":2,\"run_id\":\"run-1\",\"request_id\":\"e\",\"command\":\"hello\",\"args\":[1]}",
        "{\"schema_version\":2,\"run_id\":\"run-1\",\"request_id\":\"f\",\"command\":\"hello\",\"request_id\":\"g\"}",
        "{\"schema_version\":2,\"run_id\":\"r\\u00e9\",\"request_id\":\"g\",\"command\":\"hello\"}",
        "{\"schema_version\":2,\"run_id\":\"run-1\",\"request_id\":\"h\",\"command\":\"hello\"} trailing"
    };
    for (const auto& body : invalid) {
        const auto result = dispatcher.handle(body, snapshot);
        check(result.json_line.find("\"result\":\"rejected\"") != std::string::npos,
              "wrong types, duplicate keys, nested/extra fields, Unicode escapes, and trailing bytes are rejected");
    }
    const std::string unsupported_version =
        "{\"schema_version\":1,\"run_id\":\"run-1\",\"request_id\":\"old-schema\",\"command\":\"shutdown\"}";
    const auto unsupported_result = dispatcher.handle(unsupported_version, snapshot);
    check(unsupported_result.json_line.find("\"error\":\"unsupported_schema\"") != std::string::npos &&
          !unsupported_result.shutdown_requested,
          "an integer but unsupported schema is bound as a rejected request and cannot shut down the run");
    const auto unsupported_replay = dispatcher.handle(unsupported_version, snapshot);
    check(unsupported_replay.json_line.find("\"replayed\":true") != std::string::npos,
          "unsupported-schema rejection remains bound to its request ID");
    const auto unsupported_conflict = dispatcher.handle(request("run-1", "old-schema", "shutdown"), snapshot);
    check(unsupported_conflict.json_line.find("\"error\":\"request_id_body_conflict\"") != std::string::npos &&
          !unsupported_conflict.shutdown_requested,
          "an unsupported-schema shutdown cannot reserve the valid shutdown cache slot");
    std::string invalid_utf8 = request("run-1", "utf8", "hello");
    invalid_utf8.insert(invalid_utf8.begin() + 1, static_cast<char>(0xc3));
    invalid_utf8.insert(invalid_utf8.begin() + 2, static_cast<char>(0x28));
    check(dispatcher.handle(invalid_utf8, snapshot).json_line.find("\"result\":\"rejected\"") != std::string::npos,
          "invalid UTF-8 bytes are rejected");
}

void test_cache_capacity_reserves_shutdown()
{
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::StatusSnapshot;
    using wirex::ui_control::max_cached_requests;
    StatusSnapshot snapshot{};

    Dispatcher early_shutdown("run-1", false);
    (void)early_shutdown.ready_line(1U);
    const auto early_one = early_shutdown.handle(request("run-1", "early-ordinary-1", "rx_policy.replace"), snapshot);
    const auto early_two = early_shutdown.handle(request("run-1", "early-ordinary-2", "rx_policy.replace"), snapshot);
    check(early_one.json_line.find("\"result\":\"unsupported\"") != std::string::npos &&
          early_two.json_line.find("\"result\":\"unsupported\"") != std::string::npos &&
          early_shutdown.cached_result_count() == 2U,
          "ordinary results are counted before shutdown reserves its single slot");
    const auto early_stop = early_shutdown.handle(request("run-1", "early-stop", "shutdown"), snapshot);
    check(early_stop.shutdown_requested && early_stop.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          early_shutdown.cached_result_count() == 3U,
          "the first valid shutdown uses one reserved cache slot");
    const auto extra_stop_body = request("run-1", "extra-stop", "shutdown");
    const auto extra_stop = early_shutdown.handle(extra_stop_body, snapshot);
    check(!extra_stop.shutdown_requested &&
          extra_stop.json_line.find("\"error\":\"shutdown_in_progress\"") != std::string::npos &&
          early_shutdown.cached_result_count() == 4U,
          "a different-ID shutdown after shutdown begins uses ordinary capacity and cannot succeed again");
    const auto extra_stop_replay = early_shutdown.handle(extra_stop_body, snapshot);
    check(extra_stop_replay.json_line.find("\"replayed\":true") != std::string::npos &&
          extra_stop_replay.json_line.find("\"error\":\"shutdown_in_progress\"") != std::string::npos &&
          early_shutdown.cached_result_count() == 4U,
          "the post-shutdown rejection remains bound and replays without growing the cache");

    Dispatcher dispatcher("run-1", false);
    (void)dispatcher.ready_line(1U);
    std::string first_body;
    for (std::size_t index = 0U; index < max_cached_requests - 2U; ++index) {
        const auto body = request("run-1", "ordinary-" + std::to_string(index), "rx_policy.replace");
        if (index == 0U) first_body = body;
        const auto result = dispatcher.handle(body, snapshot);
        check(result.json_line.find("\"result\":\"unsupported\"") != std::string::npos &&
              dispatcher.cached_result_count() == index + 1U &&
              dispatcher.cached_result_count() <= max_cached_requests,
              "each ordinary result is bound while the cache stays within its 512-result limit");
    }
    check(dispatcher.cached_result_count() == max_cached_requests - 2U,
          "510 ordinary results leave exactly the cache-full and shutdown slots");

    const auto shutdown_body = request("run-1", "first-stop", "shutdown");
    const auto stop = dispatcher.handle(shutdown_body, snapshot);
    check(stop.shutdown_requested && stop.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests - 1U,
          "the first valid shutdown uses one slot beyond 510 ordinary requests");
    const auto stop_replay = dispatcher.handle(shutdown_body, snapshot);
    check(stop_replay.shutdown_requested && stop_replay.json_line.find("\"replayed\":true") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests - 1U,
          "shutdown replay uses its bound body and does not consume another reserved slot");

    const auto overflow_body = request("run-1", "second-stop", "shutdown");
    const auto full = dispatcher.handle(overflow_body, snapshot);
    check(full.shutdown_requested && full.json_line.find("\"error\":\"cache_full\"") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests,
          "the different-ID shutdown cannot use a second reserved slot and becomes the sole cache-full sentinel");
    const auto overflow_replay = dispatcher.handle(overflow_body, snapshot);
    check(overflow_replay.json_line.find("\"replayed\":true") != std::string::npos &&
          overflow_replay.json_line.find("\"error\":\"cache_full\"") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests,
          "the cache-full sentinel replays with a new control sequence and no extra cache entry");
    const auto overflow_conflict = dispatcher.handle(request("run-1", "second-stop", "hello"), snapshot);
    check(overflow_conflict.json_line.find("\"error\":\"request_id_body_conflict\"") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests,
          "the sentinel ID remains bound to its original request body");
    const auto unbound_ordinary_body = request("run-1", "after-sentinel", "status");
    const auto unbound_ordinary = dispatcher.handle(unbound_ordinary_body, snapshot);
    check(unbound_ordinary.shutdown_requested &&
          unbound_ordinary.json_line.find("\"error\":\"cache_full\"") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests,
          "a new ordinary request after the sentinel triggers bounded close without writing a 513th result");
    const auto unbound_shutdown = dispatcher.handle(request("run-1", "third-stop", "shutdown"), snapshot);
    check(unbound_shutdown.shutdown_requested &&
          unbound_shutdown.json_line.find("\"error\":\"cache_full\"") != std::string::npos &&
          dispatcher.cached_result_count() == max_cached_requests,
          "another new shutdown ID cannot reuse the consumed shutdown slot or grow the cache");
    const auto replay = dispatcher.handle(first_body, snapshot);
    check(replay.json_line.find("\"replayed\":true") != std::string::npos &&
          replay.json_line.find("\"result\":\"unsupported\"") != std::string::npos,
          "bounded cache retains old request IDs and results for the full run");
    check(dispatcher.cached_result_count() == max_cached_requests,
          "replaying an older cached result leaves the cache at its fixed capacity");
}

} // namespace

int main()
{
    test_v1_compatibility();
    test_json_line_framing();
    test_frame_size_boundaries();
    test_ready_and_handshake();
    test_dispatch_isolation_and_replay();
    test_strict_json_envelope();
    test_cache_capacity_reserves_shutdown();
    if (failures != 0) return 1;
    std::cout << "ui_control_protocol_v2_test: all assertions passed\n";
    return 0;
}
