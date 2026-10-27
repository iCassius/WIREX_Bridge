#include "wirex/routing_state.hpp"

#include <array>
#include <iostream>
#include <limits>
#include <string>
#include <string_view>

namespace {

int failures{};

void check(bool condition, std::string_view label)
{
    if (condition) return;
    std::cerr << "FAILED: " << label << '\n';
    ++failures;
}

constexpr std::string_view rx_policy =
    "{\"group_mode\":\"selected\",\"private_mode\":\"selected_peers\","
    "\"allow_groups\":[{\"destination_id\":91,\"slot\":2}],"
    "\"allow_private_peers\":[{\"source_id\":42,\"local_destination_id\":1,\"slot\":1}],"
    "\"local_private_routes\":[],\"blocked_groups\":[],\"blocked_source_ids\":[]}";

std::string startup(std::uint32_t local_id = 1U, std::string_view target =
    "{\"destination_id\":1452,\"kind\":\"group\",\"slot\":1}",
    std::string_view enabled = "true", std::string_view policy = rx_policy)
{
    return "{\"schema_version\":1,\"local_source_id\":" + std::to_string(local_id) +
        ",\"rx_policy\":" + std::string(policy) + ",\"tx_target\":" +
        std::string(target) + ",\"transmit_enabled\":" + std::string(enabled) + "}";
}

void test_strict_json_bounds_and_syntax()
{
    using wirex::strict_json::Value;
    Value parsed{};
    check(wirex::strict_json::parse("{\"n\":18446744073709551615,\"s\":\"ok\"}", parsed) &&
          parsed.find("n") != nullptr && parsed.find("n")->integer_value ==
              std::numeric_limits<std::uint64_t>::max(),
          "strict JSON accepts unsigned 64-bit boundary values");
    check(!wirex::strict_json::parse("{\"n\":18446744073709551616}", parsed),
          "strict JSON rejects unsigned integer overflow");
    check(!wirex::strict_json::parse("{\"n\":1.0}", parsed) &&
          !wirex::strict_json::parse("{\"n\":-1}", parsed),
          "routing JSON rejects floating and negative numeric forms");
    check(!wirex::strict_json::parse("{\"a\":1,\"a\":2}", parsed),
          "strict JSON rejects duplicate object keys");
    check(wirex::strict_json::parse("{\"s\":\"\\ud83d\\ude00\"}", parsed) &&
          parsed.find("s") != nullptr && parsed.find("s")->string_value.size() == 4U,
          "strict JSON accepts valid paired Unicode escapes");
    const std::string invalid_utf8{"\xc0\x80", 2U};
    check(!wirex::strict_json::parse(invalid_utf8, parsed),
          "strict JSON rejects overlong invalid UTF-8");
    const std::string over_limit(wirex::strict_json::max_input_bytes + 1U, ' ');
    check(!wirex::strict_json::parse(over_limit, parsed),
          "strict JSON enforces the 64 KiB input boundary");
}

void test_policy_and_startup_validation()
{
    using wirex::dmr_call::CallKind;
    using wirex::dmr_call::Slot;
    using wirex::routing_state::StartupConfig;
    using wirex::talkgroup_routing::RxPolicy;
    using wirex::talkgroup_routing::TxTarget;
    const TxTarget cli_target{1452U, CallKind::group, Slot::ts1};
    StartupConfig config{};
    check(wirex::routing_state::parse_startup_config(startup(), 1U, cli_target, true, config) &&
          config.local_source_id == 1U &&
          config.tx_policy.target.destination_id == cli_target.destination_id &&
          config.tx_policy.target.kind == cli_target.kind && config.tx_policy.target.slot == cli_target.slot &&
          config.tx_policy.transmit_enabled && config.rx_policy.allowed_groups.size() == 1U &&
          config.rx_policy.private_peers.size() == 1U,
          "startup file parses a complete schema-1 RX/TX policy");
    check(!wirex::routing_state::parse_startup_config(startup(2U), 1U, cli_target, true, config),
          "startup file local source ID must match the CLI source ID");
    check(!wirex::routing_state::parse_startup_config(startup(), 1U, cli_target, false, config),
          "startup transmit permission must match the legacy CLI preset");
    check(!wirex::routing_state::parse_startup_config(startup(1U,
          "{\"destination_id\":1453,\"kind\":\"group\",\"slot\":1}"),
          1U, cli_target, true, config),
          "startup target must match the CLI TX target");
    check(!wirex::routing_state::parse_startup_config(startup(1U,
          "{\"destination_id\":91,\"kind\":\"group\",\"slot\":2}"),
          1U, TxTarget{91U, CallKind::group, Slot::ts2}, true, config),
          "protected TG91 startup target cannot enable transmit");
    check(wirex::routing_state::parse_startup_config(startup(1U,
          "{\"destination_id\":46001,\"kind\":\"group\",\"slot\":2}", "false"),
          1U, TxTarget{46001U, CallKind::group, Slot::ts2}, false, config),
          "protected TG46001 is accepted as receive-only");
    check(!wirex::routing_state::parse_startup_config(startup(1U,
          "{\"destination_id\":1,\"kind\":\"private\",\"slot\":3}"),
          1U, TxTarget{1U, CallKind::private_call, Slot::ts1}, true, config),
          "invalid TX slot is rejected");

    wirex::strict_json::Value value{};
    RxPolicy policy{};
    check(wirex::strict_json::parse(std::string(rx_policy), value) &&
          wirex::routing_state::parse_rx_policy(value, 1U, policy),
          "the exact seven-field schema-2 RX policy is accepted");
    check(wirex::strict_json::parse(
          "{\"group_mode\":\"selected\",\"private_mode\":\"disabled\","
          "\"allow_groups\":[],\"allow_private_peers\":[],\"local_private_routes\":[],"
          "\"blocked_groups\":[],\"blocked_source_ids\":[],\"extra\":true}", value) &&
          !wirex::routing_state::parse_rx_policy(value, 1U, policy),
          "unknown RX policy fields are rejected");
    check(wirex::strict_json::parse(
          "{\"group_mode\":\"selected\",\"private_mode\":\"disabled\","
          "\"allow_groups\":[],\"allow_private_peers\":[],"
          "\"local_private_routes\":[{\"local_destination_id\":2,\"slot\":1}],"
          "\"blocked_groups\":[],\"blocked_source_ids\":[]}", value) &&
          !wirex::routing_state::parse_rx_policy(value, 1U, policy),
          "private route destination must be the local source ID");
    check(wirex::strict_json::parse(
          "{\"group_mode\":\"selected\",\"private_mode\":\"disabled\","
          "\"allow_groups\":[{\"destination_id\":91,\"slot\":2}],"
          "\"allow_private_peers\":[],\"local_private_routes\":[],"
          "\"blocked_groups\":[{\"destination_id\":91,\"slot\":2}],"
          "\"blocked_source_ids\":[]}", value) &&
          !wirex::routing_state::parse_rx_policy(value, 1U, policy),
          "a group route cannot be both allowed and blocked");
}

wirex::dmrd::Datagram group_datagram(std::uint32_t source, std::uint32_t destination,
                                     std::uint8_t flags = 0x21U)
{
    wirex::dmrd::Datagram datagram{};
    datagram.source_id = source;
    datagram.destination_id = destination;
    datagram.flags = flags;
    return datagram;
}

void test_observed_source_filtering_and_capacity()
{
    using wirex::dmr_call::CallKind;
    using wirex::dmr_call::Slot;
    using wirex::routing_state::ObservedSources;
    ObservedSources observed{};
    observed.observe(group_datagram(10U, 91U), 1U);
    observed.observe(group_datagram(11U, 91U), 1U);
    check(observed.entries().size() == 1U && observed.entries().front().source_id == 11U &&
          observed.entries().front().destination_id == 91U && observed.entries().front().slot == Slot::ts1 &&
          observed.entries().front().kind == CallKind::group,
          "group observations are keyed by TG and slot and retain the latest source");
    observed.observe(group_datagram(12U, 91U, 0xa1U), 1U);
    check(observed.entries().size() == 2U && observed.entries().back().destination_id == 91U &&
          observed.entries().back().slot == Slot::ts2,
          "the same talkgroup on a different timeslot has its own observation");
    observed.observe(group_datagram(12U, 1U, 0x61U), 1U);
    check(observed.entries().size() == 3U && observed.entries().back().kind == CallKind::private_call &&
          observed.entries().back().destination_id == 1U,
          "local-destination private outer headers can be observed");
    observed.observe(group_datagram(13U, 2U, 0x61U), 1U);
    observed.observe(group_datagram(0U, 93U), 1U);
    observed.observe(group_datagram(14U, 94U, 0x2fU), 1U);
    observed.observe(group_datagram(15U, 95U, 0x30U), 1U);
    check(observed.entries().size() == 3U,
          "foreign private destinations, zero IDs, and unsupported voice flags are ignored");
    for (std::uint32_t id = 1000U; id < 1064U; ++id) {
        observed.observe(group_datagram(20U, id), 1U);
    }
    check(observed.entries().size() == ObservedSources::capacity &&
          observed.entries().front().destination_id == 1000U &&
          observed.entries().back().destination_id == 1063U,
          "observed-source storage remains bounded to 64 and evicts the oldest key");
}

void test_routing_snapshot_shape()
{
    using namespace wirex;
    routing_state::ObservedSources observed{};
    observed.observe(group_datagram(42U, 91U), 1U);
    bm_voice::RoutedSnapshot snapshot{};
    snapshot.router.rx_policy_revision = 3U;
    snapshot.router.tx_policy_revision = 4U;
    snapshot.router.media_owner = talkgroup_routing::MediaOwner::rx_active;
    snapshot.router.active_rx_call = dmr_call::CallConfig{
        42U, 91U, 1U, {{1U, 2U, 3U, 4U}}, dmr_call::Slot::ts2,
        dmr_call::CallKind::group, 0U};
    snapshot.router.active_rx_generation = 9U;
    snapshot.router.active_tx_lease = talkgroup_routing::TxLease{};
    snapshot.router.active_tx_lease->id = 12U;
    snapshot.router.active_tx_lease->target = {
        1452U, dmr_call::CallKind::private_call, dmr_call::Slot::ts1};
    talkgroup_routing::RxPolicy rx{};
    talkgroup_routing::TxPolicy tx{};
    tx.target = {1452U, dmr_call::CallKind::group, dmr_call::Slot::ts2};
    tx.transmit_enabled = true;
    const auto json = routing_state::routing_json(snapshot, 1U, rx, tx, observed);
    check(json.find("\"local_source_id\":1") != std::string::npos &&
          json.find("\"rx_policy_revision\":3") != std::string::npos &&
          json.find("\"tx_policy_revision\":4") != std::string::npos &&
          json.find("\"media_owner\":\"rx_active\"") != std::string::npos,
          "routing snapshot reports current identity, revisions, and media owner");
    check(json.find("\"active_rx\":{\"source_id\":42,\"destination_id\":91,\"slot\":2,\"kind\":\"group\",\"generation\":9}") != std::string::npos &&
          json.find("\"active_tx_lease\":{\"lease_id\":12,\"destination_id\":1452,\"slot\":1,\"kind\":\"private\"}") != std::string::npos,
          "active RX and TX lease objects use the frozen ID, slot, kind, and generation fields");
    check(json.find("\"observation_level\":\"outer_header_seen\"") != std::string::npos &&
          json.find("\"callsign\"") == std::string::npos,
          "observations identify only the validated outer header without invented callsigns");
}

} // namespace

int main()
{
    test_strict_json_bounds_and_syntax();
    test_policy_and_startup_validation();
    test_observed_source_filtering_and_capacity();
    test_routing_snapshot_shape();
    if (failures != 0) return 1;
    std::cout << "routing_state_test: all assertions passed\n";
    return 0;
}
