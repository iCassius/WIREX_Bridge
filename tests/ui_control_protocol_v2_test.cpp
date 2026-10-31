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

} // namespace

int main()
{
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
    if (failures != 0) return 1;
    std::cout << "ui_control_protocol_v2_test: all assertions passed\n";
    return 0;
}
