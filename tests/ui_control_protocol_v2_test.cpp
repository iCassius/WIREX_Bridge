#include "wirex/ui_control_protocol.hpp"
#include "wirex/pcm_gain.hpp"

#include <array>
#include <fstream>
#include <iostream>
#include <stdexcept>
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

std::string request_with_parameters(std::string_view run_id, std::string_view request_id,
                                    std::string_view command, std::string_view parameters)
{
    return "{\"schema_version\":2,\"run_id\":\"" + std::string(run_id) +
        "\",\"request_id\":\"" + std::string(request_id) + "\",\"command\":\"" +
        std::string(command) + "\",\"parameters\":" + std::string(parameters) + "}";
}

std::string radio_identity_request(std::string_view run_id,
                                   std::uint64_t revision,
                                   std::uint32_t source_id,
                                   std::string_view callsign)
{
    return request_with_parameters(run_id,
        "radioid-" + std::to_string(revision),
        "radio_identity.cache_upsert",
        "{\"source_id\":" + std::to_string(source_id) +
            ",\"revision\":" + std::to_string(revision) +
            ",\"callsign\":\"" + std::string(callsign) + "\"}");
}

std::string radio_identity_clear_request(std::string_view run_id,
                                         std::uint64_t revision,
                                         std::uint32_t source_id)
{
    return request_with_parameters(run_id,
        "radioid-" + std::to_string(revision),
        "radio_identity.cache_upsert",
        "{\"source_id\":" + std::to_string(source_id) +
            ",\"revision\":" + std::to_string(revision) +
            ",\"callsign\":null}");
}

std::string audio_gains_request(std::string_view run_id, std::uint64_t revision,
                                std::uint32_t radio_playback_gain_milli,
                                std::uint32_t mic_transmit_gain_milli)
{
    return request_with_parameters(run_id, "audio-gains-" + std::to_string(revision), "audio.gains.set",
        "{\"revision\":" + std::to_string(revision) +
            ",\"radio_playback_gain_milli\":" + std::to_string(radio_playback_gain_milli) +
            ",\"mic_transmit_gain_milli\":" + std::to_string(mic_transmit_gain_milli) + "}");
}

std::string bm_connection_request(std::string_view run_id, std::string_view request_id,
                                  bool enabled, std::uint64_t revision)
{
    return request_with_parameters(run_id, request_id, "bm.connection.set",
        std::string("{\"enabled\":") + (enabled ? "true" : "false") +
            ",\"revision\":" + std::to_string(revision) + "}");
}

constexpr std::string_view empty_rx_policy =
    "{\"group_mode\":\"selected\",\"private_mode\":\"disabled\",\"allow_groups\":[],"
    "\"allow_private_peers\":[],\"local_private_routes\":[],\"blocked_groups\":[],"
    "\"blocked_source_ids\":[]}";

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
    snapshot.bm_state = "stopped";
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
          status.json_line.find("\"bm_state\":\"stopped\"") != std::string::npos &&
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

    const auto future = dispatcher.handle(request("run-1", "future", "future.operation"), snapshot);
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

void test_routing_commands_use_typed_backend_and_live_snapshots()
{
    using namespace wirex::talkgroup_routing;
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::RoutingCallbacks;
    using wirex::ui_control::StatusSnapshot;
    std::uint64_t rx_revision = 1U;
    std::uint64_t tx_revision = 1U;
    unsigned rx_calls = 0U;
    unsigned tx_calls = 0U;
    RxPolicy current_rx{};
    TxTarget current_target{91U, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts2};
    bool current_tx_enabled = false;
    RoutingCallbacks callbacks{};
    callbacks.local_source_id = 1U;
    callbacks.replace_rx_policy = [&](std::uint64_t expected, const RxPolicy& policy) {
        ++rx_calls;
        if (expected != rx_revision) {
            return PolicyUpdateResult{PolicyUpdateStatus::revision_conflict, rx_revision,
                                      std::nullopt, std::nullopt};
        }
        current_rx = policy;
        ++rx_revision;
        return PolicyUpdateResult{PolicyUpdateStatus::applied, rx_revision, std::nullopt, std::nullopt};
    };
    callbacks.replace_tx_policy = [&](std::uint64_t expected, const TxTarget& target, bool enabled) {
        ++tx_calls;
        if (expected != tx_revision) {
            return PolicyUpdateResult{PolicyUpdateStatus::revision_conflict, tx_revision,
                                      std::nullopt, std::nullopt};
        }
        current_target = target;
        current_tx_enabled = enabled;
        ++tx_revision;
        return PolicyUpdateResult{PolicyUpdateStatus::applied, tx_revision, std::nullopt, std::nullopt};
    };
    callbacks.snapshot_json = [&]() {
        return "{\"local_source_id\":1,\"rx_policy_revision\":" + std::to_string(rx_revision) +
            ",\"tx_policy_revision\":" + std::to_string(tx_revision) +
            ",\"transmit_enabled\":" + (current_tx_enabled ? "true" : "false") + "}";
    };
    Dispatcher dispatcher("route-run", false, std::move(callbacks));
    const auto ready = dispatcher.ready_line(2U);
    check(ready.find("\"routing.status\"") != std::string::npos &&
          ready.find("\"rx_policy.replace\"") != std::string::npos &&
          ready.find("\"tx_policy.replace\"") != std::string::npos,
          "routing-enabled control_ready advertises read and both replace commands");
    StatusSnapshot snapshot{};
    const auto hello = dispatcher.handle(request("route-run", "hello", "hello"), snapshot);
    check(hello.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          hello.json_line.find("\"routing.status\"") != std::string::npos,
          "hello advertises routing support on the real routing backend");
    const auto initial_push = dispatcher.routing_state_line();
    check(initial_push.find("\"type\":\"routing_state\"") != std::string::npos &&
          initial_push.find("\"rx_policy_revision\":1") != std::string::npos,
          "initial routing push contains the current policy revision");

    const auto status = dispatcher.handle(request("route-run", "route-status", "routing.status"), snapshot);
    check(status.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          status.json_line.find("\"routing\":{\"local_source_id\":1") != std::string::npos,
          "routing.status returns the typed current snapshot in its control_result");

    const auto rx_body = request_with_parameters("route-run", "rx-one", "rx_policy.replace",
        "{\"expected_revision\":1,\"rx_policy\":" + std::string(empty_rx_policy) + "}");
    const auto rx_result = dispatcher.handle(rx_body, snapshot);
    check(rx_result.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          rx_result.json_line.find("\"rx_policy_revision\":2") != std::string::npos &&
          rx_calls == 1U && rx_revision == 2U,
          "rx_policy.replace invokes the typed backend and reports its applied snapshot");

    const auto tg91_tx = request_with_parameters("route-run", "tx-91", "tx_policy.replace",
        "{\"expected_revision\":1,\"tx_target\":{\"destination_id\":91,\"kind\":\"group\",\"slot\":2},\"transmit_enabled\":true}");
    const auto tg91_result = dispatcher.handle(tg91_tx, snapshot);
    check(tg91_result.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          tg91_result.json_line.find("\"tx_policy_revision\":2") != std::string::npos &&
          tx_calls == 1U && tx_revision == 2U && current_target.destination_id == 91U && current_tx_enabled,
          "a manually selected TG91 target reaches the typed transmit-policy backend");

    const auto tg46001_tx = request_with_parameters("route-run", "tx-46001", "tx_policy.replace",
        "{\"expected_revision\":2,\"tx_target\":{\"destination_id\":46001,\"kind\":\"group\",\"slot\":2},\"transmit_enabled\":true}");
    const auto tg46001_result = dispatcher.handle(tg46001_tx, snapshot);
    check(tg46001_result.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          tg46001_result.json_line.find("\"tx_policy_revision\":3") != std::string::npos &&
          tx_calls == 2U && tx_revision == 3U && current_target.destination_id == 46001U && current_tx_enabled,
          "a manually selected TG46001 target reaches the typed transmit-policy backend");

    const auto tx_body = request_with_parameters("route-run", "tx-one", "tx_policy.replace",
        "{\"expected_revision\":3,\"tx_target\":{\"destination_id\":1452,\"kind\":\"group\",\"slot\":1},\"transmit_enabled\":true}");
    const auto tx_result = dispatcher.handle(tx_body, snapshot);
    check(tx_result.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          tx_result.json_line.find("\"tx_policy_revision\":4") != std::string::npos &&
          tx_calls == 3U && tx_revision == 4U && current_target.destination_id == 1452U && current_tx_enabled,
          "tx_policy.replace applies the next target and live permission through the backend");

    const auto conflict = dispatcher.handle(request_with_parameters("route-run", "rx-stale", "rx_policy.replace",
        "{\"expected_revision\":1,\"rx_policy\":" + std::string(empty_rx_policy) + "}"), snapshot);
    check(conflict.json_line.find("\"result\":\"rejected\"") != std::string::npos &&
          conflict.json_line.find("\"error\":\"revision_conflict\"") != std::string::npos &&
          conflict.json_line.find("\"routing\":") == std::string::npos,
          "stale CAS is rejected without an extra routing snapshot");

    const auto replay = dispatcher.handle(rx_body, snapshot);
    check(replay.json_line.find("\"replayed\":true") != std::string::npos &&
          replay.json_line.find("\"rx_policy_revision\":2") != std::string::npos &&
          rx_calls == 2U,
          "a replay preserves the original cached routing result and never re-runs mutation");
    const auto current_push = dispatcher.routing_state_line();
    check(current_push.find("\"rx_policy_revision\":2") != std::string::npos &&
          current_push.find("\"tx_policy_revision\":4") != std::string::npos,
          "a separate routing_state push reports current revisions after replay");

    const auto missing_parameters = dispatcher.handle(request("route-run", "missing", "rx_policy.replace"), snapshot);
    check(missing_parameters.json_line.find("\"error\":\"invalid_request\"") != std::string::npos &&
          rx_calls == 2U,
          "rx_policy.replace without its exact parameters object is rejected before backend dispatch");
}

void test_dynamic_quick_call_is_explicit_strict_and_replay_safe()
{
    using namespace wirex::talkgroup_routing;
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::RoutingCallbacks;
    using wirex::ui_control::StatusSnapshot;
    unsigned callback_count = 0U;
    unsigned rx_policy_mutations = 0U;
    unsigned tx_policy_mutations = 0U;
    RoutingCallbacks::QuickCallStatus next_status = RoutingCallbacks::QuickCallStatus::sent;
    std::uint8_t next_packets_sent = 2U;
    RoutingCallbacks callbacks{};
    callbacks.local_source_id = 0x123456U;
    callbacks.replace_rx_policy = [&](std::uint64_t revision, const RxPolicy&) {
        ++rx_policy_mutations;
        return PolicyUpdateResult{PolicyUpdateStatus::applied, revision + 1U, std::nullopt, std::nullopt};
    };
    callbacks.replace_tx_policy = [&](std::uint64_t revision, const TxTarget&, bool) {
        ++tx_policy_mutations;
        return PolicyUpdateResult{PolicyUpdateStatus::applied, revision + 1U, std::nullopt, std::nullopt};
    };
    callbacks.snapshot_json = []() { return "{}"; };
    callbacks.quick_call_join = [&](const GroupRoute&) {
        ++callback_count;
        return RoutingCallbacks::QuickCallOutcome{next_status, next_packets_sent};
    };
    Dispatcher dispatcher("quick-call-run", false, std::move(callbacks));
    const auto ready = dispatcher.ready_line(2U);
    check(ready.find("network_subscription.quick_call_join") != std::string::npos &&
          dispatcher.supports_quick_call(),
          "control_ready advertises Quick Call only when a sender callback is installed");
    StatusSnapshot snapshot{};
    (void)dispatcher.handle(request("quick-call-run", "hello", "hello"), snapshot);

    const auto join_body = request_with_parameters("quick-call-run", "join-91", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":91,\"slot\":2}}");
    const auto sent = dispatcher.handle(join_body, snapshot);
    check(sent.json_line.find("\"result\":\"ok\"") != std::string::npos &&
          sent.json_line.find("\"activation_status\":\"request_sent\"") != std::string::npos &&
          sent.json_line.find("\"frames_sent\":2") != std::string::npos && callback_count == 1U,
          "a valid explicit Quick Call reports two locally sent frames, not server confirmation");
    const auto replay = dispatcher.handle(join_body, snapshot);
    check(replay.json_line.find("\"replayed\":true") != std::string::npos && callback_count == 1U,
          "same request ID and body replay the stored result without another sender callback");
    check(rx_policy_mutations == 0U && tx_policy_mutations == 0U,
          "dynamic activation leaves local receive rules and speech transmit policy unchanged");

    const auto disconnect_body = request_with_parameters("quick-call-run", "join-4000", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":4000,\"slot\":2}}");
    const auto disconnect = dispatcher.handle(disconnect_body, snapshot);
    check(disconnect.json_line.find("\"error\":\"invalid_or_forbidden_group\"") != std::string::npos &&
          callback_count == 1U,
          "TG4000 is refused before the Quick Call sender is invoked");
    const auto bad_slot_body = request_with_parameters("quick-call-run", "join-bad-slot", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":91,\"slot\":0}}");
    const auto bad_slot = dispatcher.handle(bad_slot_body, snapshot);
    check(bad_slot.json_line.find("\"result\":\"rejected\"") != std::string::npos && callback_count == 1U,
          "Quick Call refuses invalid timeslots before dispatch");
    const auto zero_group = dispatcher.handle(request_with_parameters("quick-call-run", "join-zero", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":0,\"slot\":1}}"), snapshot);
    check(zero_group.json_line.find("\"result\":\"rejected\"") != std::string::npos && callback_count == 1U,
          "Quick Call refuses group zero before dispatch");
    const auto oversized_group = dispatcher.handle(request_with_parameters("quick-call-run", "join-overflow", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":16777216,\"slot\":1}}"), snapshot);
    check(oversized_group.json_line.find("\"result\":\"rejected\"") != std::string::npos && callback_count == 1U,
          "Quick Call refuses group IDs wider than 24 bits before dispatch");

    next_status = RoutingCallbacks::QuickCallStatus::busy;
    const auto busy = dispatcher.handle(request_with_parameters("quick-call-run", "join-busy", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":46001,\"slot\":1}}"), snapshot);
    check(busy.json_line.find("\"error\":\"media_busy\"") != std::string::npos && callback_count == 2U,
          "busy Quick Call is rejected and makes no success claim");

    next_status = RoutingCallbacks::QuickCallStatus::partial_send;
    next_packets_sent = 1U;
    const auto partial = dispatcher.handle(request_with_parameters("quick-call-run", "join-partial", "network_subscription.quick_call_join",
        "{\"group\":{\"destination_id\":12345,\"slot\":2}}"), snapshot);
    check(partial.json_line.find("\"error\":\"quick_call_partial_send\"") != std::string::npos &&
          partial.json_line.find("\"result\":\"ok\"") == std::string::npos,
          "one locally sent frame out of two is reported as failure instead of activation success");
    const auto partial_replay = dispatcher.handle(request_with_parameters("quick-call-run", "join-partial",
        "network_subscription.quick_call_join", "{\"group\":{\"destination_id\":12345,\"slot\":2}}"), snapshot);
    check(partial_replay.json_line.find("\"replayed\":true") != std::string::npos && callback_count == 3U,
          "replaying a partial-send request returns its cached failure without sending again");
    const auto body_conflict = dispatcher.handle(request_with_parameters("quick-call-run", "join-partial",
        "network_subscription.quick_call_join", "{\"group\":{\"destination_id\":12346,\"slot\":2}}"), snapshot);
    check(body_conflict.json_line.find("\"error\":\"request_id_body_conflict\"") != std::string::npos && callback_count == 3U,
          "request ID reuse with a different target does not dispatch another Quick Call");
}

void test_cache_full_sentinel_precedes_routing_mutation()
{
    using namespace wirex::talkgroup_routing;
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::RoutingCallbacks;
    using wirex::ui_control::StatusSnapshot;
    using wirex::ui_control::max_cached_requests;
    std::uint64_t rx_revision = 1U;
    unsigned callback_count = 0U;
    RoutingCallbacks callbacks{};
    callbacks.local_source_id = 1U;
    callbacks.replace_rx_policy = [&](std::uint64_t expected, const RxPolicy&) {
        ++callback_count;
        if (expected != rx_revision) {
            return PolicyUpdateResult{PolicyUpdateStatus::revision_conflict, rx_revision,
                                      std::nullopt, std::nullopt};
        }
        ++rx_revision;
        return PolicyUpdateResult{PolicyUpdateStatus::applied, rx_revision, std::nullopt, std::nullopt};
    };
    callbacks.replace_tx_policy = [](std::uint64_t expected, const TxTarget&, bool) {
        return PolicyUpdateResult{PolicyUpdateStatus::applied, expected + 1U, std::nullopt, std::nullopt};
    };
    callbacks.snapshot_json = [&]() { return "{\"rx_policy_revision\":" + std::to_string(rx_revision) + "}"; };
    Dispatcher dispatcher("capacity-run", false, std::move(callbacks));
    (void)dispatcher.ready_line(1U);
    StatusSnapshot snapshot{};
    (void)dispatcher.handle(request("capacity-run", "hello", "hello"), snapshot);
    const auto ordinary_count = max_cached_requests - 3U;
    for (std::size_t index = 0U; index < ordinary_count; ++index) {
        const auto body = request("capacity-run", "ordinary-" + std::to_string(index), "future.operation");
        const auto result = dispatcher.handle(body, snapshot);
        check(result.json_line.find("\"result\":\"unsupported\"") != std::string::npos,
              "ordinary unsupported request fills cache without invoking routing callbacks");
    }
    check(dispatcher.cached_result_count() == max_cached_requests - 2U && callback_count == 0U && rx_revision == 1U,
          "510 ordinary request results leave policy revision unchanged and reserve cache slots");
    const auto mutation = request_with_parameters("capacity-run", "last-rx", "rx_policy.replace",
        "{\"expected_revision\":1,\"rx_policy\":" + std::string(empty_rx_policy) + "}");
    const auto sentinel = dispatcher.handle(mutation, snapshot);
    check(sentinel.json_line.find("\"error\":\"cache_full\"") != std::string::npos &&
          !sentinel.shutdown_requested && callback_count == 0U && rx_revision == 1U,
          "the 511th ordinary ID binds cache_full before any policy callback runs");
    const auto sentinel_replay = dispatcher.handle(mutation, snapshot);
    check(sentinel_replay.json_line.find("\"replayed\":true") != std::string::npos &&
          sentinel_replay.json_line.find("\"error\":\"cache_full\"") != std::string::npos &&
          callback_count == 0U && rx_revision == 1U,
          "the policy-command cache-full sentinel safely replays without mutation");
}

void test_cache_capacity_reserves_shutdown()
{
    using wirex::ui_control::Dispatcher;
    using wirex::ui_control::StatusSnapshot;
    using wirex::ui_control::max_cached_requests;
    StatusSnapshot snapshot{};

    Dispatcher early_shutdown("run-1", false);
    (void)early_shutdown.ready_line(1U);
    const auto early_one = early_shutdown.handle(request("run-1", "early-ordinary-1", "future.operation"), snapshot);
    const auto early_two = early_shutdown.handle(request("run-1", "early-ordinary-2", "future.operation"), snapshot);
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
        const auto body = request("run-1", "ordinary-" + std::to_string(index), "future.operation");
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

void test_radio_identity_upserts_use_independent_revision_and_cache_budget()
{
    using namespace wirex::radio_identity_cache;
    using namespace wirex::ui_control;
    Cache cache;
    RoutingCallbacks callbacks{};
    callbacks.update_radio_identity = [&](std::uint32_t source_id,
                                          std::uint64_t revision,
                                          std::optional<std::string_view> callsign) {
        return callsign.has_value()
            ? cache.upsert(source_id, revision, *callsign)
            : cache.remove(source_id, revision);
    };
    Dispatcher dispatcher("run-identity", false, std::move(callbacks));
    const auto ready = dispatcher.ready_line(9001U);
    check(ready.find("radio_identity.cache_upsert") != std::string::npos,
          "control_ready advertises identity upsert only when a Native callback is wired");

    const auto before_hello = dispatcher.handle(
        radio_identity_request("run-identity", 1U, 1001U, "N0CALL"), {});
    check(before_hello.json_line.find("\"error\":\"hello_required\"") != std::string::npos &&
              cache.size() == 0U,
          "identity entries cannot change before the v2 hello handshake");
    const auto hello = dispatcher.handle(request("run-identity", "hello-identity", "hello"), {});
    check(hello.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              hello.json_line.find("radio_identity.cache_upsert") != std::string::npos,
          "hello negotiates the same identity command that control_ready advertised");

    const auto first_body = radio_identity_request("run-identity", 1U, 1001U, "N0CALL");
    const auto first = dispatcher.handle(first_body, {});
    check(first.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              first.json_line.find("\"replayed\":false") != std::string::npos &&
              cache.find(1001U).has_value() && cache.find(1001U)->callsign == "N0CALL",
          "a valid positive mapping updates the bounded Native cache");
    const auto first_replay = dispatcher.handle(first_body, {});
    check(first_replay.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              first_replay.json_line.find("\"replayed\":true") != std::string::npos,
          "replaying the latest revision and payload is acknowledged idempotently");

    const auto conflict = dispatcher.handle(
        radio_identity_request("run-identity", 1U, 1001U, "W1ABC"), {});
    check(conflict.json_line.find("\"error\":\"identity_revision_conflict\"") != std::string::npos &&
              cache.find(1001U)->callsign == "N0CALL",
          "the latest revision cannot replace its callsign with a different payload");
    const auto second = dispatcher.handle(
        radio_identity_request("run-identity", 2U, 1002U, "W1ABC"), {});
    check(second.json_line.find("\"result\":\"ok\"") != std::string::npos,
          "a later global revision may add another source ID");
    const auto stale = dispatcher.handle(first_body, {});
    check(stale.json_line.find("\"error\":\"stale_identity_revision\"") != std::string::npos &&
              cache.find(1001U)->callsign == "N0CALL",
          "an older replay is rejected after a later identity upsert");

    const auto mismatched_request_id = request_with_parameters(
        "run-identity", "radioid-5", "radio_identity.cache_upsert",
        "{\"source_id\":1001,\"revision\":4,\"callsign\":\"N0CALL\"}");
    check(dispatcher.handle(mismatched_request_id, {}).json_line.find(
              "\"error\":\"identity_request_id_mismatch\"") != std::string::npos,
          "request IDs bind one command to its declared global revision");
    const auto invalid_callsign = dispatcher.handle(
        radio_identity_request("run-identity", 3U, 1003U, "n0call"), {});
    check(invalid_callsign.json_line.find("\"error\":\"invalid_identity\"") != std::string::npos &&
              cache.highest_revision() == 2U,
          "invalid lower-case input is rejected without advancing the revision fence");
    const auto wrong_run = dispatcher.handle(
        radio_identity_request("old-run", 3U, 1003U, "N0CALL"), {});
    check(wrong_run.json_line.find("\"error\":\"stale_run_id\"") != std::string::npos &&
              wrong_run.protocol_error && cache.highest_revision() == 2U,
          "an identity frame from another Native run cannot change this run's mapping");

    for (std::uint64_t revision = 3U; revision < 603U; ++revision) {
        const auto update = dispatcher.handle(radio_identity_request(
            "run-identity", revision,
            static_cast<std::uint32_t>(2000U + (revision % 180U)), "N0CALL"), {});
        check(update.json_line.find("\"result\":\"ok\"") != std::string::npos,
              "identity commands continue after the ordinary request-cache limit");
    }
    check(cache.size() == max_entries && cache.highest_revision() == 602U &&
              dispatcher.cached_result_count() == 1U,
          "identity upserts stay within 128 mappings and consume no ordinary request-cache slots");
    const auto deleted_body = radio_identity_clear_request("run-identity", 603U, 1001U);
    const auto deleted = dispatcher.handle(deleted_body, {});
    check(deleted.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              !cache.find(1001U).has_value() && cache.highest_revision() == 603U,
          "a nullable authoritative negative update removes a prior source mapping");
    const auto deleted_replay = dispatcher.handle(deleted_body, {});
    check(deleted_replay.json_line.find("\"replayed\":true") != std::string::npos &&
              deleted_replay.json_line.find("\"result\":\"ok\"") != std::string::npos,
          "the latest null update replays as an idempotent success");
    const auto null_conflict = dispatcher.handle(
        radio_identity_request("run-identity", 603U, 1001U, "N0CALL"), {});
    check(null_conflict.json_line.find("\"error\":\"identity_revision_conflict\"") != std::string::npos &&
              !cache.find(1001U).has_value(),
          "the latest deletion revision cannot be reused to restore an ID mapping");
    const auto cleared_unknown = dispatcher.handle(
        radio_identity_clear_request("run-identity", 604U, 999999U), {});
    check(cleared_unknown.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              cache.size() == max_entries && cache.highest_revision() == 604U,
          "a newer not-found update for an unknown ID advances the fence without changing cache size");
    check(dispatcher.handle(radio_identity_request("run-identity", 603U, 1001U, "N0CALL"), {})
                  .json_line.find("\"error\":\"stale_identity_revision\"") != std::string::npos &&
              !cache.find(1001U).has_value(),
          "a pre-deletion positive frame cannot restore the old mapping after the null update");
    const auto status = dispatcher.handle(request("run-identity", "status-after-identities", "status"), {});
    check(status.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              dispatcher.cached_result_count() == 2U,
          "ordinary control commands retain their budget after hundreds of identity updates");
}

void test_audio_gain_updates_use_independent_revision_and_cache_budget()
{
    using namespace wirex::ui_control;
    std::uint32_t current_radio_playback_gain_milli = 1000U;
    std::uint32_t current_mic_transmit_gain_milli = 16000U;
    unsigned callback_count = 0U;
    bool fail_callback = false;
    bool return_invalid_readback = false;
    bool throw_callback = false;
    RoutingCallbacks callbacks{};
    callbacks.set_audio_gains = [&](std::uint32_t radio_gain, std::uint32_t mic_gain) {
        ++callback_count;
        if (throw_callback) throw std::runtime_error("audio gain test callback failure");
        if (fail_callback) {
            return RoutingCallbacks::AudioGainApplyResult{
                false, current_radio_playback_gain_milli, current_mic_transmit_gain_milli};
        }
        if (return_invalid_readback) {
            return RoutingCallbacks::AudioGainApplyResult{true, 249U, mic_gain};
        }
        current_radio_playback_gain_milli = radio_gain;
        current_mic_transmit_gain_milli = mic_gain;
        return RoutingCallbacks::AudioGainApplyResult{
            true, current_radio_playback_gain_milli, current_mic_transmit_gain_milli};
    };
    Dispatcher dispatcher("run-audio-gains", false, std::move(callbacks));
    const auto ready = dispatcher.ready_line(9002U);
    check(dispatcher.supports_audio_gains() &&
              ready.find("\"supported_commands\":[\"hello\",\"status\",\"shutdown\",\"audio.gains.set\"]") != std::string::npos,
          "Native advertises audio gain mutation only when the typed handler exists");
    StatusSnapshot snapshot{};
    snapshot.audio_gains = StatusSnapshot::AudioGains{0U, 1000U, 16000U};
    const auto hello = dispatcher.handle(request("run-audio-gains", "hello-audio-gains", "hello"), snapshot);
    check(hello.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              hello.json_line.find("\"audio.gains.set\"") != std::string::npos,
          "hello confirms the audio gain capability published by control_ready");
    const auto startup = dispatcher.handle(request("run-audio-gains", "startup-gains", "status"), snapshot);
    check(startup.json_line.find(
              "\"audio_gains\":{\"revision\":0,\"radio_playback_gain_milli\":1000,\"mic_transmit_gain_milli\":16000}") != std::string::npos,
          "status reports the startup readback and revision zero");

    const auto first_body = audio_gains_request("run-audio-gains", 1U, 2000U, 500U);
    const auto first = dispatcher.handle(first_body, snapshot);
    check(first.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              first.json_line.find(
                  "\"audio_gains\":{\"revision\":1,\"radio_playback_gain_milli\":2000,\"mic_transmit_gain_milli\":500}") != std::string::npos &&
              callback_count == 1U && current_radio_playback_gain_milli == 2000U &&
              current_mic_transmit_gain_milli == 500U,
          "one typed request applies both gain values and acknowledges the handler readback");

    // These are the same two parameters consumed before each live playback/transmit PCM operation.
    std::array<std::int16_t, 1U> playback_sample{{100}};
    std::array<std::int16_t, 1U> microphone_sample{{100}};
    const auto playback_result = wirex::pcm_gain::apply(
        playback_sample.data(), playback_sample.size(), current_radio_playback_gain_milli);
    const auto microphone_result = wirex::pcm_gain::apply(
        microphone_sample.data(), microphone_sample.size(), current_mic_transmit_gain_milli);
    check(playback_result.valid && playback_sample[0U] == 200 &&
              microphone_result.valid && microphone_sample[0U] == 50,
          "updated readback values change both directions of the PCM gain operation immediately");

    const auto first_replay = dispatcher.handle(first_body, snapshot);
    check(first_replay.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              first_replay.json_line.find("\"replayed\":true") != std::string::npos && callback_count == 1U,
          "same latest revision and values are acknowledged without applying them twice");
    const auto conflict = dispatcher.handle(audio_gains_request("run-audio-gains", 1U, 250U, 500U), snapshot);
    check(conflict.json_line.find("\"error\":\"audio_gain_revision_conflict\"") != std::string::npos &&
              current_radio_playback_gain_milli == 2000U && current_mic_transmit_gain_milli == 500U &&
              callback_count == 1U,
          "reusing the latest revision with a different pair cannot alter either gain");
    const auto mismatched_id = request_with_parameters("run-audio-gains", "audio-gains-99", "audio.gains.set",
        "{\"revision\":2,\"radio_playback_gain_milli\":2000,\"mic_transmit_gain_milli\":500}");
    check(dispatcher.handle(mismatched_id, snapshot).json_line.find(
              "\"error\":\"audio_gain_request_id_mismatch\"") != std::string::npos && callback_count == 1U,
          "request ID must match the declared audio gain revision");

    const auto second = dispatcher.handle(audio_gains_request("run-audio-gains", 2U, 250U, 16000U), snapshot);
    check(second.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              current_radio_playback_gain_milli == 250U && current_mic_transmit_gain_milli == 16000U,
          "inclusive lower and upper gain limits can be applied atomically");
    const auto stale = dispatcher.handle(first_body, snapshot);
    check(stale.json_line.find("\"error\":\"stale_audio_gain_revision\"") != std::string::npos &&
              current_radio_playback_gain_milli == 250U && current_mic_transmit_gain_milli == 16000U,
          "an older audio gain revision cannot roll back a newer pair");

    fail_callback = true;
    const auto failed = dispatcher.handle(audio_gains_request("run-audio-gains", 3U, 1500U, 3000U), snapshot);
    check(failed.json_line.find("\"error\":\"audio_gain_update_failed\"") != std::string::npos &&
              dispatcher.audio_gains_revision() == 2U && current_radio_playback_gain_milli == 250U &&
              current_mic_transmit_gain_milli == 16000U,
          "a failed handler does not advance revision, mutate the pair, or return success");
    fail_callback = false;
    return_invalid_readback = true;
    const auto invalid_readback = dispatcher.handle(
        audio_gains_request("run-audio-gains", 3U, 1500U, 3000U), snapshot);
    check(invalid_readback.json_line.find("\"error\":\"audio_gain_update_failed\"") != std::string::npos &&
              dispatcher.audio_gains_revision() == 2U && current_radio_playback_gain_milli == 250U &&
              current_mic_transmit_gain_milli == 16000U,
          "an out-of-range handler readback cannot be reported as a successful application");
    return_invalid_readback = false;
    throw_callback = true;
    const auto thrown = dispatcher.handle(audio_gains_request("run-audio-gains", 3U, 1500U, 3000U), snapshot);
    check(thrown.json_line.find("\"error\":\"audio_gain_update_failed\"") != std::string::npos &&
              dispatcher.audio_gains_revision() == 2U && current_radio_playback_gain_milli == 250U &&
              current_mic_transmit_gain_milli == 16000U,
          "a throwing handler is rejected without pretending that either gain changed");
    throw_callback = false;
    const auto third = dispatcher.handle(audio_gains_request("run-audio-gains", 3U, 1500U, 3000U), snapshot);
    check(third.json_line.find("\"result\":\"ok\"") != std::string::npos &&
              dispatcher.audio_gains_revision() == 3U && callback_count == 6U,
          "failed revision can be retried and advances only after a valid readback");

    for (const auto invalid : {
             audio_gains_request("run-audio-gains", 4U, 249U, 3000U),
             audio_gains_request("run-audio-gains", 4U, 16001U, 3000U),
             audio_gains_request("run-audio-gains", 4U, 1500U, 0U)}) {
        check(dispatcher.handle(invalid, snapshot).json_line.find("\"error\":\"invalid_audio_gains\"") != std::string::npos,
              "out-of-range audio gain requests are explicitly rejected");
    }
    const auto invalid_type = request_with_parameters("run-audio-gains", "audio-gains-4", "audio.gains.set",
        "{\"revision\":4,\"radio_playback_gain_milli\":1.5,\"mic_transmit_gain_milli\":3000}");
    check(dispatcher.handle(invalid_type, snapshot).json_line.find(
              "\"error\":\"invalid_request\"") != std::string::npos,
          "gain parameters must be JSON unsigned integers, not decimal values");

    snapshot.audio_gains = StatusSnapshot::AudioGains{
        dispatcher.audio_gains_revision(), current_radio_playback_gain_milli, current_mic_transmit_gain_milli};
    const auto status = dispatcher.handle(request("run-audio-gains", "status-after-gains", "status"), snapshot);
    check(status.json_line.find(
              "\"audio_gains\":{\"revision\":3,\"radio_playback_gain_milli\":1500,\"mic_transmit_gain_milli\":3000}") != std::string::npos,
          "status returns the latest actual runtime values and accepted revision");

    for (std::uint64_t revision = 4U; revision <= 520U; ++revision) {
        const auto radio = static_cast<std::uint32_t>(250U + (revision % 15751U));
        const auto mic = static_cast<std::uint32_t>(16000U - (revision % 15751U));
        const auto update = dispatcher.handle(audio_gains_request("run-audio-gains", revision, radio, mic), snapshot);
        check(update.json_line.find("\"result\":\"ok\"") != std::string::npos,
              "audio gain updates continue beyond the ordinary control replay capacity");
    }
    check(dispatcher.audio_gains_revision() == 520U && callback_count == 523U &&
              dispatcher.cached_result_count() == 3U,
          "more than 512 audio gain updates use constant-size latest-revision state while ordinary requests remain cached");

    Dispatcher without_handler("run-no-audio-handler", false);
    const auto unsupported_ready = without_handler.ready_line(9003U);
    check(unsupported_ready.find("audio.gains.set") == std::string::npos,
          "control_ready omits audio gain support when the implementation has no handler");
    (void)without_handler.handle(request("run-no-audio-handler", "hello", "hello"), {});
    const auto unsupported = without_handler.handle(
        audio_gains_request("run-no-audio-handler", 1U, 1000U, 1000U), {});
    check(unsupported.json_line.find("\"result\":\"unsupported\"") != std::string::npos &&
              unsupported.json_line.find("\"error\":\"command_not_supported\"") != std::string::npos &&
              without_handler.cached_result_count() == 1U,
          "unsupported audio gain requests are rejected without consuming ordinary cache entries");
    RoutingCallbacks next_run_callbacks{};
    next_run_callbacks.set_audio_gains = [](std::uint32_t radio, std::uint32_t mic) {
        return RoutingCallbacks::AudioGainApplyResult{true, radio, mic};
    };
    Dispatcher next_run("run-audio-gains-next", false, std::move(next_run_callbacks));
    check(next_run.audio_gains_revision() == 0U,
          "audio gain revision fence resets when a new native run starts");
}

void test_bm_connection_requires_handler_and_serializes_live_transitions()
{
    using namespace wirex::ui_control;
    StatusSnapshot live{};
    live.bm_state = "stopped";
    live.bm_connection_error = "none";
    unsigned callback_count = 0U;
    bool requested_enabled = false;
    std::uint64_t requested_revision = 0U;
    RoutingCallbacks::BmConnectionOutcome next_outcome{};
    bool throw_callback = false;
    RoutingCallbacks callbacks{};
    callbacks.set_bm_connection = [&](bool enabled, std::uint64_t revision) {
        ++callback_count;
        requested_enabled = enabled;
        requested_revision = revision;
        if (throw_callback) throw std::runtime_error("BM manager callback failure");
        return next_outcome;
    };

    Dispatcher dispatcher("run-bm-connection", false, std::move(callbacks));
    const auto ready = dispatcher.ready_line(9010U);
    check(dispatcher.supports_bm_connection() &&
              ready.find("\"bm.connection.set\"") != std::string::npos,
          "control_ready advertises BM toggles only when the typed manager handler exists");
    const auto hello = dispatcher.handle(request("run-bm-connection", "hello", "hello"), live);
    check(hello.json_line.find("\"bm.connection.set\"") != std::string::npos,
          "hello confirms that this native run supports BM connection control");

    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {true, 1U, false};
    next_outcome.actual.bm_resolving = true;
    next_outcome.actual.bm_state = "stopped";
    const auto enable_body = bm_connection_request("run-bm-connection", "bm-on-1", true, 1U);
    const auto enabled = dispatcher.handle(enable_body, live);
    check(enabled.json_line.find("\"result\":\"accepted\"") != std::string::npos &&
              enabled.json_line.find("\"bm_connection\":{\"requested_enabled\":true,\"revision\":1,\"transport_open\":false}") != std::string::npos &&
              enabled.json_line.find("\"bm_resolving\":true") != std::string::npos &&
              enabled.json_line.find("\"bm_state\":\"stopped\"") != std::string::npos &&
              callback_count == 1U && requested_enabled && requested_revision == 1U,
          "accepted BM-on reports the manager's actual paused-DNS state without claiming an open transport");
    const auto enable_replay = dispatcher.handle(enable_body, live);
    check(enable_replay.json_line.find("\"replayed\":true") != std::string::npos && callback_count == 1U,
          "the same JSON request replay never invokes the BM manager twice");
    const auto request_id_conflict = dispatcher.handle(
        bm_connection_request("run-bm-connection", "bm-on-1", false, 2U), live);
    check(request_id_conflict.json_line.find("\"error\":\"request_id_body_conflict\"") != std::string::npos &&
              callback_count == 1U,
          "a request ID cannot be reused for a different BM toggle body");

    next_outcome.result = RoutingCallbacks::BmConnectionResult::idempotent;
    const auto duplicate_revision = dispatcher.handle(
        bm_connection_request("run-bm-connection", "bm-on-1-duplicate", true, 1U), live);
    check(duplicate_revision.json_line.find("\"result\":\"accepted\"") != std::string::npos &&
              callback_count == 2U && requested_enabled && requested_revision == 1U,
          "a new request ID can receive an idempotent acknowledgement for the manager's same revision");

    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {false, 2U, true};
    next_outcome.actual.bm_state = "ready";
    next_outcome.actual.bm_resolving = false;
    const auto disable_body = bm_connection_request("run-bm-connection", "bm-off-2", false, 2U);
    const auto disabling = dispatcher.handle(disable_body, live);
    check(disabling.json_line.find("\"result\":\"accepted\"") != std::string::npos &&
              disabling.json_line.find("\"bm_connection\":{\"requested_enabled\":false,\"revision\":2,\"transport_open\":true}") != std::string::npos &&
              disabling.json_line.find("\"bm_state\":\"ready\"") != std::string::npos,
          "accepted BM-off reports that the UDP transport remains open while media drains");

    live.bm_connection = {false, 2U, true};
    live.bm_state = "ready";
    live.bm_resolving = false;
    live.bm_connection_error = "media_cleanup_timeout";
    const auto status_during_deadline = dispatcher.handle(
        request("run-bm-connection", "bm-status-during-deadline", "status"), live);
    check(status_during_deadline.json_line.find("\"bm_connection_error\":\"media_cleanup_timeout\"") != std::string::npos &&
              status_during_deadline.json_line.find("\"bm_connection\":{\"requested_enabled\":false,\"revision\":2,\"transport_open\":true}") != std::string::npos &&
              status_during_deadline.json_line.find("\"bm_state\":\"ready\"") != std::string::npos,
          "status preserves a media cleanup error while the real session and UDP transport remain open");

    next_outcome.result = RoutingCallbacks::BmConnectionResult::transition_busy;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {false, 2U, true};
    next_outcome.actual.bm_state = "ready";
    const auto enable_while_draining = dispatcher.handle(
        bm_connection_request("run-bm-connection", "bm-on-during-drain", true, 3U), live);
    check(enable_while_draining.json_line.find("\"result\":\"rejected\"") != std::string::npos &&
              enable_while_draining.json_line.find("\"error\":\"bm_transition_busy\"") != std::string::npos &&
              enable_while_draining.json_line.find("\"transport_open\":true") != std::string::npos,
          "an enable request cannot race an outstanding BM/media disable transition");

    live.bm_connection = {false, 2U, false};
    live.bm_state = "stopped";
    live.bm_connection_error = "media_cleanup_timeout";
    const auto status_after_deadline = dispatcher.handle(
        request("run-bm-connection", "bm-status-after-deadline", "status"), live);
    check(status_after_deadline.json_line.find("\"bm_connection_error\":\"media_cleanup_timeout\"") != std::string::npos &&
              status_after_deadline.json_line.find("\"bm_connection\":{\"requested_enabled\":false,\"revision\":2,\"transport_open\":false}") != std::string::npos &&
              status_after_deadline.json_line.find("\"bm_state\":\"stopped\"") != std::string::npos,
          "status after a media deadline reports the stopped session and its explicit cleanup error");

    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {true, 4U, true};
    next_outcome.actual.bm_state = "waiting_login_ack";
    throw_callback = true;
    const auto thrown = dispatcher.handle(
        bm_connection_request("run-bm-connection", "bm-thrown-4", true, 4U), live);
    check(thrown.json_line.find("\"result\":\"rejected\"") != std::string::npos &&
              thrown.json_line.find("\"error\":\"bm_transition_busy\"") != std::string::npos &&
              thrown.json_line.find("\"bm_connection\":{\"requested_enabled\":false,\"revision\":2,\"transport_open\":false}") != std::string::npos,
          "a throwing manager handler returns current state and never fabricates a connected state");
    throw_callback = false;

    const unsigned calls_before_invalid = callback_count;
    const auto invalid = request_with_parameters("run-bm-connection", "bm-invalid-rev", "bm.connection.set",
        "{\"enabled\":true,\"revision\":0}");
    check(dispatcher.handle(invalid, live).json_line.find("\"error\":\"invalid_bm_connection_parameters\"") != std::string::npos &&
              callback_count == calls_before_invalid,
          "invalid BM revision is rejected before reaching the manager");

    Dispatcher without_handler("run-no-bm-handler", false);
    const auto legacy_ready = without_handler.ready_line(9011U);
    check(!without_handler.supports_bm_connection() &&
              legacy_ready.find("bm.connection.set") == std::string::npos,
          "legacy or diagnostic runs without a manager handler do not advertise BM toggle support");
    (void)without_handler.handle(request("run-no-bm-handler", "hello", "hello"), {});
    const auto unsupported = without_handler.handle(
        bm_connection_request("run-no-bm-handler", "bm-no-handler", true, 1U), {});
    check(unsupported.json_line.find("\"result\":\"unsupported\"") != std::string::npos &&
              unsupported.json_line.find("\"error\":\"command_not_supported\"") != std::string::npos &&
              unsupported.json_line.find("\"bm_state\":\"stopped\"") != std::string::npos,
          "a legacy run without a handler keeps BM stopped and rejects toggles as unsupported");
}

int emit_r121_bm_protocol_frames(const std::string& output_path)
{
    using namespace wirex::ui_control;
    constexpr std::string_view run_id = "9010-123456";
    constexpr std::string_view legacy_run_id = "9020-123456";

    StatusSnapshot live{};
    live.bm_state = "stopped";
    live.bm_connection_error = "none";
    RoutingCallbacks::BmConnectionOutcome next_outcome{};
    RoutingCallbacks callbacks{};
    callbacks.set_bm_connection = [&](bool, std::uint64_t) { return next_outcome; };
    Dispatcher dispatcher(std::string(run_id), false, std::move(callbacks));

    std::vector<std::string> frames;
    const auto ready = dispatcher.ready_line(9010U);
    if (ready.empty()) return 2;
    frames.push_back(ready);
    const auto before_hello = dispatcher.handle(
        bm_connection_request(run_id, "f15c0001-1210-4a21-9d01-000000000001", true, 1U), live);
    if (before_hello.json_line.find("\"error\":\"hello_required\"") == std::string::npos) return 2;
    frames.push_back(before_hello.json_line);
    const auto hello = dispatcher.handle(
        request(run_id, "f15c0001-1210-4a21-9d01-000000000002", "hello"), live);
    if (hello.json_line.empty()) return 2;
    frames.push_back(hello.json_line);
    const auto malformed = dispatcher.handle(request_with_parameters(
        run_id, "f15c0001-1210-4a21-9d01-000000000003", "bm.connection.set",
        "{\"enabled\":true,\"revision\":0}"), live);
    if (malformed.json_line.find("\"error\":\"invalid_bm_connection_parameters\"") == std::string::npos) return 2;
    frames.push_back(malformed.json_line);

    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {true, 1U, false};
    next_outcome.actual.bm_resolving = true;
    next_outcome.actual.bm_state = "stopped";
    next_outcome.actual.bm_connection_error = "none";
    auto result = dispatcher.handle(
        bm_connection_request(run_id, "f15c0001-1210-4a21-9d01-000000000004", true, 1U), live);
    if (result.json_line.empty()) return 2;
    frames.push_back(result.json_line);
    live = next_outcome.actual;

    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {false, 2U, false};
    next_outcome.actual.bm_resolving = true;
    next_outcome.actual.bm_state = "stopped";
    next_outcome.actual.bm_connection_error = "none";
    result = dispatcher.handle(
        bm_connection_request(run_id, "f15c0001-1210-4a21-9d01-000000000005", false, 2U), live);
    if (result.json_line.empty()) return 2;
    frames.push_back(result.json_line);
    live = next_outcome.actual;

    next_outcome.result = RoutingCallbacks::BmConnectionResult::transition_busy;
    next_outcome.actual = live;
    result = dispatcher.handle(
        bm_connection_request(run_id, "f15c0001-1210-4a21-9d01-000000000006", true, 3U), live);
    if (result.json_line.empty()) return 2;
    frames.push_back(result.json_line);

    // The fake resolver has now settled; no DNS or network code is used here.
    live.bm_resolving = false;
    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {true, 3U, true};
    next_outcome.actual.bm_resolving = false;
    next_outcome.actual.bm_state = "ready";
    next_outcome.actual.bm_connection_error = "none";
    result = dispatcher.handle(
        bm_connection_request(run_id, "f15c0001-1210-4a21-9d01-000000000007", true, 3U), live);
    if (result.json_line.empty()) return 2;
    frames.push_back(result.json_line);
    live = next_outcome.actual;

    next_outcome.result = RoutingCallbacks::BmConnectionResult::accepted;
    next_outcome.actual = live;
    next_outcome.actual.bm_connection = {false, 4U, true};
    next_outcome.actual.bm_resolving = false;
    next_outcome.actual.bm_state = "ready";
    next_outcome.actual.bm_connection_error = "media_cleanup_timeout";
    result = dispatcher.handle(
        bm_connection_request(run_id, "f15c0001-1210-4a21-9d01-000000000008", false, 4U), live);
    if (result.json_line.empty()) return 2;
    frames.push_back(result.json_line);

    live = next_outcome.actual;
    live.bm_connection.transport_open = false;
    live.bm_state = "stopped";
    const auto after_close = dispatcher.handle(
        request(run_id, "f15c0001-1210-4a21-9d01-000000000009", "status"), live);
    if (after_close.json_line.empty()) return 2;
    frames.push_back(after_close.json_line);

    RoutingCallbacks no_bm_callbacks{};
    Dispatcher without_handler(std::string(legacy_run_id), false, std::move(no_bm_callbacks));
    const auto legacy_ready = without_handler.ready_line(9020U);
    if (legacy_ready.empty() || legacy_ready.find("bm.connection.set") != std::string::npos) return 2;
    frames.push_back(legacy_ready);
    StatusSnapshot legacy_snapshot{};
    const auto legacy_hello = without_handler.handle(
        request(legacy_run_id, "f15c0001-1210-4a21-9d01-00000000000a", "hello"), legacy_snapshot);
    if (legacy_hello.json_line.empty()) return 2;
    frames.push_back(legacy_hello.json_line);
    const auto unsupported = without_handler.handle(
        bm_connection_request(legacy_run_id, "f15c0001-1210-4a21-9d01-00000000000b", true, 1U), legacy_snapshot);
    if (unsupported.json_line.find("\"result\":\"unsupported\"") == std::string::npos ||
        unsupported.json_line.find("\"bm_state\":\"stopped\"") == std::string::npos) return 2;
    frames.push_back(unsupported.json_line);

    std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
    if (!output.is_open()) return 2;
    for (const auto& frame : frames) {
        output.write(frame.data(), static_cast<std::streamsize>(frame.size()));
        output.put('\n');
    }
    output.flush();
    return output.good() && frames.size() == 13U ? 0 : 2;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc == 3 && std::string_view(argv[1]) == "--emit-r121-bm-frames") {
        return emit_r121_bm_protocol_frames(argv[2]);
    }
    if (argc != 1) {
        std::cerr << "usage: ui_control_protocol_v2_test [--emit-r121-bm-frames path]\n";
        return 2;
    }
    test_v1_compatibility();
    test_json_line_framing();
    test_frame_size_boundaries();
    test_ready_and_handshake();
    test_dispatch_isolation_and_replay();
    test_strict_json_envelope();
    test_routing_commands_use_typed_backend_and_live_snapshots();
    test_dynamic_quick_call_is_explicit_strict_and_replay_safe();
    test_cache_full_sentinel_precedes_routing_mutation();
    test_cache_capacity_reserves_shutdown();
    test_radio_identity_upserts_use_independent_revision_and_cache_budget();
    test_audio_gain_updates_use_independent_revision_and_cache_budget();
    test_bm_connection_requires_handler_and_serializes_live_transitions();
    if (failures != 0) return 1;
    std::cout << "ui_control_protocol_v2_test: all assertions passed\n";
    return 0;
}
