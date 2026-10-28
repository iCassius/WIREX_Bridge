#include "wirex/ui_control_protocol.hpp"
#include "wirex/routing_state.hpp"

#include <array>
#include <limits>
#include <utility>

namespace wirex::ui_control {
namespace {

constexpr std::string_view basic_commands_json = "[\"hello\",\"status\",\"shutdown\"]";
constexpr std::string_view routing_commands_json =
    "[\"hello\",\"status\",\"shutdown\",\"routing.status\",\"rx_policy.replace\",\"tx_policy.replace\"]";
constexpr std::string_view quick_call_commands_json =
    "[\"hello\",\"status\",\"shutdown\",\"routing.status\",\"rx_policy.replace\",\"tx_policy.replace\",\"network_subscription.quick_call_join\"]";

bool valid_identifier(std::string_view value, std::size_t maximum) noexcept
{
    if (value.empty() || value.size() > maximum) return false;
    for (const unsigned char ch : value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.')) return false;
    }
    return true;
}

bool valid_command_name(std::string_view value) noexcept
{
    if (value.empty() || value.size() > 64U) return false;
    for (const unsigned char ch : value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
              ch == '_' || ch == '-' || ch == '.')) return false;
    }
    return value.front() >= 'a' && value.front() <= 'z';
}

std::string json_escape(std::string_view value)
{
    std::string output;
    output.reserve(value.size() + 2U);
    output.push_back('"');
    constexpr char hex[] = "0123456789abcdef";
    for (const unsigned char ch : value) {
        switch (ch) {
        case '"': output.append("\\\""); break;
        case '\\': output.append("\\\\"); break;
        case '\b': output.append("\\b"); break;
        case '\f': output.append("\\f"); break;
        case '\n': output.append("\\n"); break;
        case '\r': output.append("\\r"); break;
        case '\t': output.append("\\t"); break;
        default:
            if (ch < 0x20U) {
                output.append("\\u00");
                output.push_back(hex[ch >> 4U]);
                output.push_back(hex[ch & 0x0fU]);
            } else {
                output.push_back(static_cast<char>(ch));
            }
            break;
        }
    }
    output.push_back('"');
    return output;
}

struct Request {
    std::uint32_t schema_version{};
    std::string run_id{};
    std::string request_id{};
    std::string command{};
    const strict_json::Value* parameters{};
};

bool parse_request(std::string_view input, Request& request, strict_json::Value& envelope)
{
    if (!strict_json::parse(input, envelope) || envelope.type != strict_json::Value::Type::object) return false;
    const auto* schema = envelope.find("schema_version");
    const auto* run = envelope.find("run_id");
    const auto* request_id = envelope.find("request_id");
    const auto* command = envelope.find("command");
    if (schema == nullptr || schema->type != strict_json::Value::Type::unsigned_integer ||
        schema->integer_value > UINT32_MAX || run == nullptr || run->type != strict_json::Value::Type::string ||
        request_id == nullptr || request_id->type != strict_json::Value::Type::string ||
        command == nullptr || command->type != strict_json::Value::Type::string) return false;
    request.schema_version = static_cast<std::uint32_t>(schema->integer_value);
    request.run_id = run->string_value;
    request.request_id = request_id->string_value;
    request.command = command->string_value;
    request.parameters = envelope.find("parameters");
    const bool mutating = request.command == "rx_policy.replace" || request.command == "tx_policy.replace" ||
        request.command == "network_subscription.quick_call_join";
    const auto expected_size = mutating ? 5U : 4U;
    if (envelope.object_value.size() != expected_size || (mutating &&
        (request.parameters == nullptr || request.parameters->type != strict_json::Value::Type::object)) ||
        (!mutating && request.parameters != nullptr)) return false;
    return valid_identifier(request.run_id, 128U) && valid_identifier(request.request_id, 128U) &&
        valid_command_name(request.command);
}

std::string snapshot_json(const StatusSnapshot& snapshot)
{
    std::string output = "{\"mode\":" + json_escape(snapshot.mode) +
        ",\"status\":" + json_escape(snapshot.status) +
        ",\"phase\":" + json_escape(snapshot.phase) +
        ",\"media_seq\":" + std::to_string(snapshot.media_seq) +
        ",\"diagnostic\":" + (snapshot.diagnostic ? "true" : "false") +
        ",\"bm_state\":" + json_escape(snapshot.bm_state) +
        ",\"hri_phase\":" + json_escape(snapshot.hri_phase) +
        ",\"hri_ready\":" + (snapshot.hri_ready ? "true" : "false") +
        ",\"serial_open\":" + (snapshot.serial_open ? "true" : "false") +
        ",\"wavein_open\":" + (snapshot.wavein_open ? "true" : "false") +
        ",\"waveout_open\":" + (snapshot.waveout_open ? "true" : "false") +
        ",\"radio_state\":" + json_escape(snapshot.radio_state) + "}";
    return output;
}

} // namespace

JsonLineStatus JsonLineParser::feed(std::string_view bytes, std::vector<std::string>& lines)
{
    if (invalid_) return JsonLineStatus::invalid;
    bool completed = false;
    for (const char byte : bytes) {
        if (pending_cr_) {
            pending_cr_ = false;
            if (byte == '\n') {
                if (line_.empty()) {
                    invalid_ = true;
                    return JsonLineStatus::invalid;
                }
                lines.push_back(std::move(line_));
                line_.clear();
                completed = true;
                continue;
            }
            if (line_.size() >= max_json_line_bytes) {
                invalid_ = true;
                return JsonLineStatus::invalid;
            }
            line_.push_back('\r');
        }
        if (byte == '\r') {
            pending_cr_ = true;
            continue;
        }
        if (byte == '\n') {
            if (line_.empty()) {
                invalid_ = true;
                return JsonLineStatus::invalid;
            }
            lines.push_back(std::move(line_));
            line_.clear();
            completed = true;
            continue;
        }
        if (line_.size() >= max_json_line_bytes) {
            invalid_ = true;
            return JsonLineStatus::invalid;
        }
        line_.push_back(byte);
    }
    return completed ? JsonLineStatus::complete : JsonLineStatus::pending;
}

Dispatcher::Dispatcher(std::string run_id, bool diagnostic, RoutingCallbacks routing)
    : run_id_(std::move(run_id)), diagnostic_(diagnostic),
      routing_enabled_(static_cast<bool>(routing.replace_rx_policy) &&
                       static_cast<bool>(routing.replace_tx_policy) &&
                       static_cast<bool>(routing.snapshot_json)),
      quick_call_enabled_(routing_enabled_ && static_cast<bool>(routing.quick_call_join)),
      routing_(std::move(routing))
{
}

std::string Dispatcher::ready_line(std::uint32_t process_id)
{
    if (ready_emitted_) return {};
    ready_emitted_ = true;
    control_seq_ = 1U;
    const auto commands = !routing_enabled_ ? basic_commands_json :
        (quick_call_enabled_ ? quick_call_commands_json : routing_commands_json);
    return "{\"schema_version\":2,\"type\":\"control_ready\",\"run_id\":" +
        json_escape(run_id_) + ",\"control_seq\":1,\"process_id\":" +
        std::to_string(process_id) + ",\"control_version\":2,\"supported_commands\":" +
        std::string(commands) + ",\"diagnostic\":" +
        (diagnostic_ ? "true" : "false") + "}";
}

std::string Dispatcher::routing_state_line()
{
    if (!routing_enabled_ || !hello_seen_) return {};
    std::string routing_json;
    try { routing_json = routing_.snapshot_json(); }
    catch (...) { return {}; }
    if (routing_json.empty()) return {};
    ++control_seq_;
    return "{\"schema_version\":2,\"type\":\"routing_state\",\"run_id\":" +
        json_escape(run_id_) + ",\"control_seq\":" + std::to_string(control_seq_) +
        ",\"routing\":" + routing_json + "}";
}

std::string Dispatcher::serialize_result(std::string_view request_id, std::string_view command,
                                         std::string_view result, std::string_view extra_json,
                                         bool replayed)
{
    ++control_seq_;
    std::string output = "{\"schema_version\":2,\"type\":\"control_result\",\"run_id\":" +
        json_escape(run_id_) + ",\"control_seq\":" + std::to_string(control_seq_) +
        ",\"request_id\":" + json_escape(request_id) + ",\"command\":" +
        json_escape(command) + ",\"result\":" + json_escape(result) +
        ",\"replayed\":" + (replayed ? "true" : "false");
    if (!extra_json.empty()) {
        output.push_back(',');
        output.append(extra_json);
    }
    output.push_back('}');
    return output;
}

std::string Dispatcher::serialize_rejection(std::string_view request_id, std::string_view command,
                                            std::string_view error_code)
{
    ++control_seq_;
    const std::string request_json = request_id.empty() ? "null" : json_escape(request_id);
    const std::string command_json = command.empty() ? "null" : json_escape(command);
    return "{\"schema_version\":2,\"type\":\"control_result\",\"run_id\":" +
        json_escape(run_id_) + ",\"control_seq\":" + std::to_string(control_seq_) +
        ",\"request_id\":" + request_json + ",\"command\":" + command_json +
        ",\"result\":\"rejected\",\"replayed\":false,\"error\":" +
        json_escape(error_code) + "}";
}

DispatchResult Dispatcher::handle(std::string_view json_line, const StatusSnapshot& snapshot)
{
    if (json_line.size() > max_json_line_bytes) {
        return {serialize_rejection({}, {}, "frame_too_long"), false, true};
    }
    Request request{};
    strict_json::Value envelope{};
    if (!parse_request(json_line, request, envelope)) {
        return {serialize_rejection({}, {}, "invalid_request"), false, true};
    }
    if (request.run_id != run_id_) {
        return {serialize_rejection(request.request_id, request.command, "stale_run_id"), false, true};
    }
    const bool valid_shutdown = request.schema_version == 2U && request.command == "shutdown";

    const auto existing = cache_.find(request.request_id);
    if (existing != cache_.end()) {
        if (existing->second.body == json_line) {
            return {serialize_result(request.request_id, existing->second.command,
                                     existing->second.result, existing->second.extra_json, true),
                    existing->second.shutdown_requested, false};
        }
        return {serialize_rejection(request.request_id, request.command,
                                    "request_id_body_conflict"), false, true};
    }
    if (cache_full_rejection_ && cache_full_rejection_->body.size() != 0U) {
        // cache-full 首次拒绝也绑定 request_id/body，后续可安全重放或识别异正文。
        if (cache_full_rejection_->request_id == request.request_id) {
            if (cache_full_rejection_->body == json_line) {
                return {serialize_result(request.request_id, cache_full_rejection_->command,
                                         cache_full_rejection_->result,
                                         cache_full_rejection_->extra_json, true), false, false};
            }
            return {serialize_rejection(request.request_id, request.command,
                                        "request_id_body_conflict"), false, true};
        }
    }

    const bool may_use_shutdown_slot = valid_shutdown && !shutdown_slot_used_ && !shutdown_requested_;
    if (cache_exhausted_ && !may_use_shutdown_slot) {
        // 哨兵后的第二个新ID立即触发有界收尾；后端不会收到该请求。
        shutdown_requested_ = true;
        return {serialize_rejection(request.request_id, request.command, "cache_full"), true, false};
    }

    if (!may_use_shutdown_slot && !cache_full_rejection_ &&
        non_shutdown_requests_ >= max_cached_requests - 2U) {
        CachedResult sentinel{};
        try {
            sentinel.body.assign(json_line);
            sentinel.request_id = request.request_id;
            sentinel.command = request.command;
            sentinel.result = "rejected";
            sentinel.extra_json = "\"error\":\"cache_full\"";
            cache_full_rejection_ = std::move(sentinel);
            cache_exhausted_ = true;
        } catch (...) {
            shutdown_requested_ = true;
            return {serialize_rejection(request.request_id, request.command,
                                        "cache_full_allocation_failed"), true, false};
        }
        return {serialize_result(request.request_id, request.command, "rejected",
                                 "\"error\":\"cache_full\"", false), shutdown_requested_, false};
    }

    if (cached_result_count() >= max_cached_requests) {
        shutdown_requested_ = true;
        return {serialize_rejection(request.request_id, request.command,
                                    "cache_full"), true, false};
    }

    CachedResult seed{};
    try {
        seed.body.assign(json_line);
        seed.request_id = request.request_id;
        seed.command = request.command;
        // 先将request_id/body放入有界缓存，再允许后端产生任何副作用。
        const auto inserted = cache_.emplace(request.request_id, std::move(seed));
        if (!inserted.second) {
            return {serialize_rejection(request.request_id, request.command,
                                        "request_id_conflict"), false, true};
        }
    } catch (...) {
        shutdown_requested_ = true;
        return {serialize_rejection(request.request_id, request.command,
                                    "request_cache_allocation_failed"), true, false};
    }

    auto& cached = cache_.find(request.request_id)->second;
    bool mark_hello = false;
    bool accept_shutdown = false;
    bool routing_mutation_applied = false;
    try {
        if (request.schema_version != 2U) {
            cached.result = "rejected";
            cached.extra_json = "\"error\":\"unsupported_schema\"";
        } else if (shutdown_requested_) {
            cached.result = "rejected";
            cached.extra_json = "\"error\":\"shutdown_in_progress\"";
        } else if (request.command == "hello") {
            cached.result = "ok";
            const auto commands = !routing_enabled_ ? basic_commands_json :
                (quick_call_enabled_ ? quick_call_commands_json : routing_commands_json);
            cached.extra_json = "\"supported_commands\":" +
                std::string(commands);
            mark_hello = true;
        } else if (request.command == "status") {
            if (!hello_seen_) {
                cached.result = "rejected";
                cached.extra_json = "\"error\":\"hello_required\"";
            } else {
                cached.result = "ok";
                cached.extra_json = "\"snapshot\":" + snapshot_json(snapshot);
            }
        } else if (request.command == "routing.status") {
            if (!hello_seen_) {
                cached.result = "rejected";
                cached.extra_json = "\"error\":\"hello_required\"";
            } else if (!routing_enabled_) {
                cached.result = "unsupported";
                cached.extra_json = "\"error\":\"command_not_supported\"";
            } else {
                cached.result = "ok";
                cached.extra_json = "\"routing\":" + routing_.snapshot_json();
            }
        } else if (request.command == "rx_policy.replace" || request.command == "tx_policy.replace") {
            if (!hello_seen_) {
                cached.result = "rejected";
                cached.extra_json = "\"error\":\"hello_required\"";
            } else if (!routing_enabled_) {
                cached.result = "unsupported";
                cached.extra_json = "\"error\":\"command_not_supported\"";
            } else {
                const auto* params = request.parameters;
                const auto* revision = params->find("expected_revision");
                bool valid = revision != nullptr && revision->type == strict_json::Value::Type::unsigned_integer;
                talkgroup_routing::PolicyUpdateResult update{};
                if (request.command == "rx_policy.replace") {
                    valid = valid && params->object_value.size() == 2U && params->find("rx_policy") != nullptr;
                    talkgroup_routing::RxPolicy policy{};
                    valid = valid && routing_state::parse_rx_policy(
                        *params->find("rx_policy"), routing_.local_source_id, policy);
                    if (valid) update = routing_.replace_rx_policy(revision->integer_value, policy);
                } else {
                    const auto* target_value = params->find("tx_target");
                    const auto* enabled_value = params->find("transmit_enabled");
                    valid = valid && params->object_value.size() == 3U && target_value != nullptr &&
                        enabled_value != nullptr && enabled_value->type == strict_json::Value::Type::boolean;
                    talkgroup_routing::TxTarget target{};
                    valid = valid && routing_state::parse_tx_target(*target_value, target);
                    const bool enabled = enabled_value != nullptr && enabled_value->boolean_value;
                    const bool protected_target = target.kind == dmr_call::CallKind::group &&
                        (target.destination_id == 91U || target.destination_id == 46001U);
                    if (valid && protected_target && enabled) valid = false;
                    if (valid) update = routing_.replace_tx_policy(revision->integer_value, target, enabled);
                }
                if (!valid) {
                    cached.result = "rejected";
                    cached.extra_json = "\"error\":\"invalid_parameters\"";
                } else if (!update) {
                    cached.result = "rejected";
                    std::string_view error = "invalid_policy";
                    switch (update.status) {
                    case talkgroup_routing::PolicyUpdateStatus::revision_conflict: error = "revision_conflict"; break;
                    case talkgroup_routing::PolicyUpdateStatus::revision_exhausted: error = "revision_exhausted"; break;
                    case talkgroup_routing::PolicyUpdateStatus::resource_failure: error = "resource_failure"; break;
                    case talkgroup_routing::PolicyUpdateStatus::invalid_policy: error = "invalid_policy"; break;
                    case talkgroup_routing::PolicyUpdateStatus::applied: break;
                    }
                    cached.extra_json = "\"error\":" + json_escape(error);
                } else {
                    routing_mutation_applied = true;
                    cached.result = "ok";
                    cached.extra_json = "\"routing\":" + routing_.snapshot_json();
                }
            }
        } else if (request.command == "network_subscription.quick_call_join") {
            if (!hello_seen_) {
                cached.result = "rejected";
                cached.extra_json = "\"error\":\"hello_required\"";
            } else if (!routing_enabled_ || !quick_call_enabled_) {
                cached.result = "unsupported";
                cached.extra_json = "\"error\":\"command_not_supported\"";
            } else {
                const auto* params = request.parameters;
                const auto* group_value = params->find("group");
                const auto* destination_value = group_value != nullptr ? group_value->find("destination_id") : nullptr;
                const auto* slot_value = group_value != nullptr ? group_value->find("slot") : nullptr;
                const bool valid = params->object_value.size() == 1U &&
                    group_value != nullptr && group_value->type == strict_json::Value::Type::object &&
                    group_value->object_value.size() == 2U &&
                    destination_value != nullptr &&
                    destination_value->type == strict_json::Value::Type::unsigned_integer &&
                    destination_value->integer_value >= 1U && destination_value->integer_value <= 0x00ffffffU &&
                    destination_value->integer_value != 4000U &&
                    slot_value != nullptr && slot_value->type == strict_json::Value::Type::unsigned_integer &&
                    slot_value->integer_value >= 1U && slot_value->integer_value <= 2U;
                if (!valid) {
                    cached.result = "rejected";
                    cached.extra_json = "\"error\":\"invalid_or_forbidden_group\"";
                } else {
                    const talkgroup_routing::GroupRoute group{
                        static_cast<std::uint32_t>(destination_value->integer_value),
                        static_cast<dmr_call::Slot>(slot_value->integer_value)};
                    RoutingCallbacks::QuickCallOutcome outcome{};
                    try { outcome = routing_.quick_call_join(group); }
                    catch (...) { outcome.status = RoutingCallbacks::QuickCallStatus::send_failed; }
                    using QuickCallStatus = RoutingCallbacks::QuickCallStatus;
                    if (outcome.status == QuickCallStatus::sent && outcome.packets_sent == 2U) {
                        cached.result = "ok";
                        cached.extra_json = "\"activation_status\":\"request_sent\",\"destination_id\":" +
                            std::to_string(group.destination_id) + ",\"slot\":" +
                            std::to_string(static_cast<unsigned int>(group.slot)) + ",\"frames_sent\":2";
                    } else {
                        cached.result = "rejected";
                        std::string_view error = "quick_call_send_failed";
                        switch (outcome.status) {
                        case QuickCallStatus::not_ready: error = "quick_call_not_ready"; break;
                        case QuickCallStatus::busy: error = "media_busy"; break;
                        case QuickCallStatus::invalid_target: error = "invalid_or_forbidden_group"; break;
                        case QuickCallStatus::forbidden_target: error = "disconnect_group_forbidden"; break;
                        case QuickCallStatus::partial_send: error = "quick_call_partial_send"; break;
                        case QuickCallStatus::send_failed: error = "quick_call_send_failed"; break;
                        case QuickCallStatus::sent: error = "quick_call_send_incomplete"; break;
                        }
                        cached.extra_json = "\"error\":" + json_escape(error);
                    }
                }
            }
        } else if (request.command == "shutdown") {
            cached.result = "ok";
            cached.shutdown_requested = true;
            cached.extra_json = "\"shutdown_requested\":true";
            accept_shutdown = true;
        } else {
            cached.result = "unsupported";
            cached.extra_json = "\"error\":\"command_not_supported\"";
        }

        const auto output = serialize_result(request.request_id, cached.command, cached.result,
                                             cached.extra_json, false);
        if (mark_hello && cached.result == "ok") hello_seen_ = true;
        if (accept_shutdown && cached.result == "ok") {
            shutdown_requested_ = true;
            shutdown_slot_used_ = true;
        }
        if (!accept_shutdown) ++non_shutdown_requests_;
        return {output, accept_shutdown && cached.result == "ok", false};
    } catch (...) {
        // request_id/body已经进入缓存，所以应用后序列化失败也不能让相同ID再次执行。
        cached.result = "rejected";
        cached.extra_json = routing_mutation_applied
            ? "\"error\":\"applied_result_serialization_failed\""
            : "\"error\":\"fatal\"";
        cached.shutdown_requested = false;
        shutdown_requested_ = true;
        ++non_shutdown_requests_;
        return {serialize_result(request.request_id, cached.command, cached.result,
                                 cached.extra_json, false), true, false};
    }
}

DispatchResult Dispatcher::reject(std::string_view error_code)
{
    return {serialize_rejection({}, {}, error_code), false, true};
}

} // namespace wirex::ui_control
