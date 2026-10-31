#include "wirex/routing_state.hpp"

#include <algorithm>
#include <initializer_list>
#include <limits>
#include <new>

namespace wirex::routing_state {
namespace {

using strict_json::Value;
using ValueType = Value::Type;
using namespace talkgroup_routing;
constexpr std::uint32_t max_radio_id = 0x00ffffffU;

bool same_group_route(const GroupRoute& left, const GroupRoute& right) noexcept
{
    return left.destination_id == right.destination_id && left.slot == right.slot;
}

bool same_private_peer(const PrivatePeerRoute& left, const PrivatePeerRoute& right) noexcept
{
    return left.source_id == right.source_id &&
        left.local_destination_id == right.local_destination_id && left.slot == right.slot;
}

bool same_local_private_route(const LocalPrivateRoute& left, const LocalPrivateRoute& right) noexcept
{
    return left.local_destination_id == right.local_destination_id && left.slot == right.slot;
}

bool same_tx_target(const TxTarget& left, const TxTarget& right) noexcept
{
    return left.destination_id == right.destination_id && left.kind == right.kind && left.slot == right.slot;
}

bool exact_fields(const Value& value, std::initializer_list<std::string_view> names) noexcept
{
    if (value.type != ValueType::object || value.object_value.size() != names.size()) return false;
    for (const auto name : names) if (value.find(name) == nullptr) return false;
    return true;
}

bool uint_field(const Value& value, std::string_view name, std::uint64_t& output) noexcept
{
    const auto* field = value.find(name);
    if (field == nullptr || field->type != ValueType::unsigned_integer) return false;
    output = field->integer_value;
    return true;
}

bool slot_field(const Value& value, dmr_call::Slot& output) noexcept
{
    if (value.type != ValueType::unsigned_integer ||
        (value.integer_value != 1U && value.integer_value != 2U)) return false;
    output = value.integer_value == 1U ? dmr_call::Slot::ts1 : dmr_call::Slot::ts2;
    return true;
}

bool valid_id(std::uint64_t value) noexcept
{
    return value > 0U && value <= max_radio_id;
}

bool parse_group_routes(const Value& value, std::vector<GroupRoute>& routes) noexcept
{
    if (value.type != ValueType::array) return false;
    try {
        routes.clear();
        routes.reserve(value.array_value.size());
        for (const auto& entry : value.array_value) {
            if (!exact_fields(entry, {"destination_id", "slot"})) return false;
            std::uint64_t id{};
            dmr_call::Slot slot{};
            if (!uint_field(entry, "destination_id", id) || !valid_id(id) ||
                !slot_field(*entry.find("slot"), slot)) return false;
            routes.push_back({static_cast<std::uint32_t>(id), slot});
        }
    } catch (...) { return false; }
    return true;
}

bool parse_private_peers(const Value& value, std::uint32_t local_id,
                         std::vector<PrivatePeerRoute>& routes) noexcept
{
    if (value.type != ValueType::array) return false;
    try {
        routes.clear();
        routes.reserve(value.array_value.size());
        for (const auto& entry : value.array_value) {
            if (!exact_fields(entry, {"source_id", "local_destination_id", "slot"})) return false;
            std::uint64_t source{}, destination{};
            dmr_call::Slot slot{};
            if (!uint_field(entry, "source_id", source) || !valid_id(source) ||
                !uint_field(entry, "local_destination_id", destination) || destination != local_id ||
                !slot_field(*entry.find("slot"), slot)) return false;
            routes.push_back({static_cast<std::uint32_t>(source), static_cast<std::uint32_t>(destination), slot});
        }
    } catch (...) { return false; }
    return true;
}

bool parse_local_routes(const Value& value, std::uint32_t local_id,
                        std::vector<LocalPrivateRoute>& routes) noexcept
{
    if (value.type != ValueType::array) return false;
    try {
        routes.clear();
        routes.reserve(value.array_value.size());
        for (const auto& entry : value.array_value) {
            if (!exact_fields(entry, {"local_destination_id", "slot"})) return false;
            std::uint64_t destination{};
            dmr_call::Slot slot{};
            if (!uint_field(entry, "local_destination_id", destination) || destination != local_id ||
                !slot_field(*entry.find("slot"), slot)) return false;
            routes.push_back({static_cast<std::uint32_t>(destination), slot});
        }
    } catch (...) { return false; }
    return true;
}

bool parse_blocked_sources(const Value& value, std::vector<std::uint32_t>& ids) noexcept
{
    if (value.type != ValueType::array) return false;
    try {
        ids.clear();
        ids.reserve(value.array_value.size());
        for (const auto& entry : value.array_value) {
            if (entry.type != ValueType::unsigned_integer || !valid_id(entry.integer_value)) return false;
            ids.push_back(static_cast<std::uint32_t>(entry.integer_value));
        }
    } catch (...) { return false; }
    return true;
}

const char* kind_name(dmr_call::CallKind kind) noexcept
{
    return kind == dmr_call::CallKind::private_call ? "private" : "group";
}

const char* owner_name(MediaOwner owner) noexcept
{
    switch (owner) {
    case MediaOwner::idle: return "idle";
    case MediaOwner::rx_active: return "rx_active";
    case MediaOwner::rx_draining: return "rx_draining";
    case MediaOwner::rx_stopping: return "rx_stopping";
    case MediaOwner::tx_active: return "tx_active";
    case MediaOwner::tx_draining: return "tx_draining";
    case MediaOwner::fault: return "fault";
    }
    return "fault";
}

const char* group_mode_name(GroupMode mode) noexcept
{
    return mode == GroupMode::all_delivered ? "all_delivered" : "selected";
}

const char* private_mode_name(PrivateMode mode) noexcept
{
    switch (mode) {
    case PrivateMode::disabled: return "disabled";
    case PrivateMode::selected_peers: return "selected_peers";
    case PrivateMode::all_peers_to_local: return "all_peers_to_local";
    }
    return "disabled";
}

const char* observation_name(ObservationLevel level) noexcept
{
    switch (level) {
    case ObservationLevel::outer_header_seen: return "outer_header_seen";
    case ObservationLevel::link_control_validated: return "link_control_validated";
    case ObservationLevel::router_reserved: return "router_reserved";
    case ObservationLevel::playback_started: return "playback_started";
    }
    return "outer_header_seen";
}

void append_group_routes(std::string& out, const std::vector<GroupRoute>& routes)
{
    out.push_back('[');
    bool first = true;
    for (const auto& route : routes) {
        if (!first) out.push_back(',');
        first = false;
        out += "{\"destination_id\":" + std::to_string(route.destination_id) +
            ",\"slot\":" + std::to_string(static_cast<unsigned>(route.slot)) + "}";
    }
    out.push_back(']');
}

void append_policy(std::string& out, const RxPolicy& policy)
{
    out += "{\"group_mode\":\"";
    out += group_mode_name(policy.group_mode);
    out += "\",\"private_mode\":\"";
    out += private_mode_name(policy.private_mode);
    out += "\",\"allow_groups\":";
    append_group_routes(out, policy.allowed_groups);
    out += ",\"allow_private_peers\":[";
    bool first = true;
    for (const auto& peer : policy.private_peers) {
        if (!first) out.push_back(',');
        first = false;
        out += "{\"source_id\":" + std::to_string(peer.source_id) +
            ",\"local_destination_id\":" + std::to_string(peer.local_destination_id) +
            ",\"slot\":" + std::to_string(static_cast<unsigned>(peer.slot)) + "}";
    }
    out += "],\"local_private_routes\":[";
    first = true;
    for (const auto& route : policy.local_private_routes) {
        if (!first) out.push_back(',');
        first = false;
        out += "{\"local_destination_id\":" + std::to_string(route.local_destination_id) +
            ",\"slot\":" + std::to_string(static_cast<unsigned>(route.slot)) + "}";
    }
    out += "],\"blocked_groups\":";
    append_group_routes(out, policy.blocked_groups);
    out += ",\"blocked_source_ids\":[";
    first = true;
    for (const auto id : policy.blocked_source_ids) {
        if (!first) out.push_back(',');
        first = false;
        out += std::to_string(id);
    }
    out += "]}";
}

} // namespace

bool parse_rx_policy(const Value& value, std::uint32_t local_source_id,
                     RxPolicy& output) noexcept
{
    if (!exact_fields(value, {"group_mode", "private_mode", "allow_groups", "allow_private_peers",
                              "local_private_routes", "blocked_groups", "blocked_source_ids"})) return false;
    const auto* group_mode = value.find("group_mode");
    const auto* private_mode = value.find("private_mode");
    if (group_mode == nullptr || group_mode->type != ValueType::string ||
        private_mode == nullptr || private_mode->type != ValueType::string) return false;
    RxPolicy candidate{};
    if (group_mode->string_value == "selected") candidate.group_mode = GroupMode::selected;
    else if (group_mode->string_value == "all_delivered") candidate.group_mode = GroupMode::all_delivered;
    else return false;
    if (private_mode->string_value == "disabled") candidate.private_mode = PrivateMode::disabled;
    else if (private_mode->string_value == "selected_peers") candidate.private_mode = PrivateMode::selected_peers;
    else if (private_mode->string_value == "all_peers_to_local") candidate.private_mode = PrivateMode::all_peers_to_local;
    else return false;
    try {
        if (!parse_group_routes(*value.find("allow_groups"), candidate.allowed_groups) ||
            !parse_private_peers(*value.find("allow_private_peers"), local_source_id, candidate.private_peers) ||
            !parse_local_routes(*value.find("local_private_routes"), local_source_id, candidate.local_private_routes) ||
            !parse_group_routes(*value.find("blocked_groups"), candidate.blocked_groups) ||
            !parse_blocked_sources(*value.find("blocked_source_ids"), candidate.blocked_source_ids)) return false;
        for (std::size_t i = 0U; i < candidate.allowed_groups.size(); ++i) {
            for (std::size_t j = 0U; j < i; ++j) {
                if (same_group_route(candidate.allowed_groups[i], candidate.allowed_groups[j])) return false;
            }
        }
        for (std::size_t i = 0U; i < candidate.blocked_groups.size(); ++i) {
            for (std::size_t j = 0U; j < i; ++j) {
                if (same_group_route(candidate.blocked_groups[i], candidate.blocked_groups[j])) return false;
            }
            for (const auto& allow : candidate.allowed_groups) {
                if (same_group_route(candidate.blocked_groups[i], allow)) return false;
            }
        }
        for (std::size_t i = 0U; i < candidate.blocked_source_ids.size(); ++i) {
            for (std::size_t j = 0U; j < i; ++j) {
                if (candidate.blocked_source_ids[i] == candidate.blocked_source_ids[j]) return false;
            }
        }
        for (std::size_t i = 0U; i < candidate.private_peers.size(); ++i) {
            for (std::size_t j = 0U; j < i; ++j) {
                if (same_private_peer(candidate.private_peers[i], candidate.private_peers[j])) return false;
            }
        }
        for (std::size_t i = 0U; i < candidate.local_private_routes.size(); ++i) {
            for (std::size_t j = 0U; j < i; ++j) {
                if (same_local_private_route(candidate.local_private_routes[i], candidate.local_private_routes[j])) return false;
            }
        }
        if (candidate.private_mode == PrivateMode::disabled &&
            (!candidate.private_peers.empty() || !candidate.local_private_routes.empty())) return false;
        if (candidate.private_mode == PrivateMode::selected_peers &&
            !candidate.local_private_routes.empty()) return false;
        output = std::move(candidate);
        return true;
    } catch (...) { return false; }
}

bool parse_tx_target(const Value& value, TxTarget& output) noexcept
{
    if (!exact_fields(value, {"destination_id", "kind", "slot"})) return false;
    std::uint64_t destination{};
    if (!uint_field(value, "destination_id", destination) || !valid_id(destination)) return false;
    const auto* kind = value.find("kind");
    if (kind == nullptr || kind->type != ValueType::string) return false;
    dmr_call::CallKind call_kind{};
    if (kind->string_value == "group") call_kind = dmr_call::CallKind::group;
    else if (kind->string_value == "private") call_kind = dmr_call::CallKind::private_call;
    else return false;
    dmr_call::Slot slot{};
    if (!slot_field(*value.find("slot"), slot)) return false;
    output = {static_cast<std::uint32_t>(destination), call_kind, slot};
    return true;
}

bool parse_startup_config(std::string_view json, std::uint32_t cli_source_id,
                          const TxTarget& cli_target, bool cli_transmit_enabled,
                          StartupConfig& output) noexcept
{
    Value root{};
    if (!strict_json::parse(json, root) ||
        !exact_fields(root, {"schema_version", "local_source_id", "rx_policy", "tx_target", "transmit_enabled"})) return false;
    std::uint64_t schema{}, local_id{};
    const auto* enabled = root.find("transmit_enabled");
    if (!uint_field(root, "schema_version", schema) || schema != 1U ||
        !uint_field(root, "local_source_id", local_id) || !valid_id(local_id) ||
        local_id != cli_source_id || enabled == nullptr || enabled->type != ValueType::boolean ||
        enabled->boolean_value != cli_transmit_enabled) return false;
    StartupConfig candidate{};
    candidate.local_source_id = static_cast<std::uint32_t>(local_id);
    candidate.tx_policy.transmit_enabled = enabled->boolean_value;
    if (!parse_rx_policy(*root.find("rx_policy"), candidate.local_source_id, candidate.rx_policy) ||
        !parse_tx_target(*root.find("tx_target"), candidate.tx_policy.target) ||
        !same_tx_target(candidate.tx_policy.target, cli_target)) return false;
    output = std::move(candidate);
    return true;
}

void ObservedSources::observe(const dmrd::Datagram& datagram, std::uint32_t local_source_id) noexcept
{
    const auto slot = (datagram.flags & 0x80U) != 0U ? dmr_call::Slot::ts2 : dmr_call::Slot::ts1;
    const bool data_sync = (datagram.flags & 0x20U) != 0U;
    const bool voice_sync = (datagram.flags & 0x10U) != 0U;
    const auto low_flags = static_cast<std::uint8_t>(datagram.flags & 0x0fU);
    const bool supported_voice_flags = data_sync && !voice_sync
        ? (low_flags == 0x01U || low_flags == 0x02U)
        : (!data_sync && voice_sync ? low_flags == 0U
           : (!data_sync && !voice_sync && low_flags >= 1U && low_flags <= 5U));
    if (datagram.source_id == 0U || datagram.source_id > max_radio_id ||
        datagram.destination_id == 0U || datagram.destination_id > max_radio_id ||
        (slot != dmr_call::Slot::ts1 && slot != dmr_call::Slot::ts2) || !supported_voice_flags) return;
    const auto kind = (datagram.flags & 0x40U) != 0U
        ? dmr_call::CallKind::private_call : dmr_call::CallKind::group;
    if (kind == dmr_call::CallKind::private_call && datagram.destination_id != local_source_id) return;
    const ObservedSource candidate{datagram.source_id, datagram.destination_id, slot, kind,
                                   ObservationLevel::outer_header_seen};
    for (auto& current : entries_) {
        if (kind == dmr_call::CallKind::group) {
            if (current.kind == kind && current.destination_id == candidate.destination_id &&
                current.slot == candidate.slot) { current = candidate; return; }
        } else if (current.kind == kind && current.source_id == candidate.source_id &&
                   current.destination_id == candidate.destination_id && current.slot == candidate.slot) {
            current = candidate;
            return;
        }
    }
    try {
        if (entries_.size() == capacity) entries_.erase(entries_.begin());
        entries_.push_back(candidate);
    } catch (...) {
        // Bounded observation is optional; never let reporting allocation disturb media.
    }
}

std::string routing_json(const bm_voice::RoutedSnapshot& snapshot,
                         std::uint32_t local_source_id,
                         const RxPolicy& rx_policy,
                         const TxPolicy& tx_policy,
                         const ObservedSources& observed)
{
    const auto& state = snapshot.router;
    std::string out = "{\"local_source_id\":" + std::to_string(local_source_id) +
        ",\"rx_policy_revision\":" + std::to_string(state.rx_policy_revision) +
        ",\"tx_policy_revision\":" + std::to_string(state.tx_policy_revision) +
        ",\"rx_policy\":";
    append_policy(out, rx_policy);
    const auto& target = tx_policy.target;
    out += ",\"tx_target\":{\"destination_id\":" + std::to_string(target.destination_id) +
        ",\"slot\":" + std::to_string(static_cast<unsigned>(target.slot)) +
        ",\"kind\":\"" + kind_name(target.kind) + "\"},\"transmit_enabled\":" +
        (tx_policy.transmit_enabled ? "true" : "false") +
        ",\"media_owner\":\"" + owner_name(state.media_owner) + "\",\"active_rx\":";
    if (state.active_rx_call && state.active_rx_generation != 0U) {
        const auto& call = *state.active_rx_call;
        out += "{\"source_id\":" + std::to_string(call.source_id) +
            ",\"destination_id\":" + std::to_string(call.destination_id) +
            ",\"slot\":" + std::to_string(static_cast<unsigned>(call.slot)) +
            ",\"kind\":\"" + kind_name(call.kind) + "\",\"generation\":" +
            std::to_string(state.active_rx_generation) + "}";
    } else out += "null";
    out += ",\"active_tx_lease\":";
    if (state.active_tx_lease) {
        const auto& lease = *state.active_tx_lease;
        out += "{\"lease_id\":" + std::to_string(lease.id) +
            ",\"destination_id\":" + std::to_string(lease.target.destination_id) +
            ",\"slot\":" + std::to_string(static_cast<unsigned>(lease.target.slot)) +
            ",\"kind\":\"" + kind_name(lease.target.kind) + "\"}";
    } else out += "null";
    out += ",\"observed_sources\":[";
    bool first = true;
    for (const auto& item : observed.entries()) {
        if (!first) out.push_back(',');
        first = false;
        out += "{\"source_id\":" + std::to_string(item.source_id) +
            ",\"destination_id\":" + std::to_string(item.destination_id) +
            ",\"slot\":" + std::to_string(static_cast<unsigned>(item.slot)) +
            ",\"kind\":\"" + kind_name(item.kind) + "\",\"observation_level\":\"" +
            observation_name(item.observation_level) + "\"}";
    }
    out += "]}";
    return out;
}

} // namespace wirex::routing_state
