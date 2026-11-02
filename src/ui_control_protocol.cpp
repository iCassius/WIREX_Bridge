#include "wirex/ui_control_protocol.hpp"
#include "wirex/routing_state.hpp"

#include <array>
#include <charconv>
#include <limits>
#include <utility>

namespace wirex::ui_control {
namespace {

std::string supported_commands_json(bool routing_enabled,
                                    bool quick_call_enabled,
                                    bool radio_identity_enabled,
                                    bool audio_gains_enabled,
                                    bool bm_connection_enabled)
{
    std::string commands{"[\"hello\",\"status\",\"shutdown\""};
    if (routing_enabled) {
        commands.append(",\"routing.status\",\"rx_policy.replace\",\"tx_policy.replace\"");
        if (quick_call_enabled) commands.append(",\"network_subscription.quick_call_join\"");
    }
    if (radio_identity_enabled) commands.append(",\"radio_identity.cache_upsert\"");
    if (audio_gains_enabled) commands.append(",\"audio.gains.set\"");
    if (bm_connection_enabled) commands.append(",\"bm.connection.set\"");
    commands.push_back(']');
    return commands;
}

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
        request.command == "network_subscription.quick_call_join" ||
        request.command == "radio_identity.cache_upsert" ||
        request.command == "audio.gains.set" || request.command == "bm.connection.set";
    const auto expected_size = mutating ? 5U : 4U;
    if (envelope.object_value.size() != expected_size || (mutating &&
        (request.parameters == nullptr || request.parameters->type != strict_json::Value::Type::object)) ||
        (!mutating && request.parameters != nullptr)) return false;
    return valid_identifier(request.run_id, 128U) && valid_identifier(request.request_id, 128U) &&
        valid_command_name(request.command);
}

std::string expected_identity_request_id(std::uint64_t revision)
{
    std::array<char, 20U> decimal{};
    const auto converted = std::to_chars(decimal.data(), decimal.data() + decimal.size(), revision);
    if (converted.ec != std::errc{}) return {};
    std::string result{"radioid-"};
    result.append(decimal.data(), converted.ptr);
    return result;
}

std::string expected_audio_gains_request_id(std::uint64_t revision)
{
    std::array<char, 20U> decimal{};
    const auto converted = std::to_chars(decimal.data(), decimal.data() + decimal.size(), revision);
    if (converted.ec != std::errc{}) return {};
    std::string result{"audio-gains-"};
    result.append(decimal.data(), converted.ptr);
    return result;
}

bool valid_gain_milli(std::uint64_t value) noexcept
{
    return value >= 250U && value <= 16000U;
}

std::string audio_gains_json(const StatusSnapshot::AudioGains& gains)
{
    return "{\"revision\":" + std::to_string(gains.revision) +
        ",\"radio_playback_gain_milli\":" + std::to_string(gains.radio_playback_gain_milli) +
        ",\"mic_transmit_gain_milli\":" + std::to_string(gains.mic_transmit_gain_milli) + "}";
}

std::string bm_connection_json(const StatusSnapshot& snapshot)
{
    return "{\"requested_enabled\":" + std::string(snapshot.bm_connection.requested_enabled ? "true" : "false") +
        ",\"revision\":" + std::to_string(snapshot.bm_connection.revision) +
        ",\"transport_open\":" + std::string(snapshot.bm_connection.transport_open ? "true" : "false") + "}";
}

const char* safe_bm_connection_error(std::string_view error) noexcept
{
    constexpr std::array<std::string_view, 8U> allowed{{
        "none", "password_required", "master_resolution_failed", "master_resolution_timeout",
        "resolver_cancel_timeout", "profile_invalid", "transport_open_failed", "media_cleanup_timeout"}};
    for (const auto candidate : allowed) {
        if (error == candidate) return candidate.data();
    }
    return "none";
}

const char* safe_bm_state(std::string_view state) noexcept
{
    constexpr std::array<std::string_view, 8U> allowed{{
        "idle", "waiting_login_ack", "waiting_auth_ack", "waiting_config_ack",
        "waiting_options_ack", "ready", "backoff", "stopped"}};
    for (const auto candidate : allowed) {
        if (state == candidate) return candidate.data();
    }
    return "stopped";
}

std::string bm_connection_fields_json(const StatusSnapshot& snapshot)
{
    return "\"bm_connection\":" + bm_connection_json(snapshot) +
        ",\"bm_resolving\":" + std::string(snapshot.bm_resolving ? "true" : "false") +
        ",\"bm_connection_error\":" + json_escape(safe_bm_connection_error(snapshot.bm_connection_error)) +
        ",\"bm_state\":" + json_escape(safe_bm_state(snapshot.bm_state));
}

const char* bm_connection_request_error(RoutingCallbacks::BmConnectionResult result) noexcept
{
    using Result = RoutingCallbacks::BmConnectionResult;
    switch (result) {
    case Result::accepted:
    case Result::idempotent: return "";
    case Result::stale_revision: return "bm_revision_stale";
    case Result::revision_conflict: return "bm_revision_conflict";
    case Result::transition_busy: return "bm_transition_busy";
    case Result::password_required: return "bm_password_required";
    case Result::master_resolution_failed: return "bm_master_resolution_failed";
    case Result::profile_invalid: return "bm_profile_invalid";
    case Result::transport_open_failed: return "bm_transport_open_failed";
    }
    return "bm_invalid_request";
}

std::string snapshot_json(const StatusSnapshot& snapshot, bool include_audio_gains)
{
    std::string output = "{\"mode\":" + json_escape(snapshot.mode) +
        ",\"status\":" + json_escape(snapshot.status) +
        ",\"phase\":" + json_escape(snapshot.phase) +
        ",\"media_seq\":" + std::to_string(snapshot.media_seq) +
        ",\"diagnostic\":" + (snapshot.diagnostic ? "true" : "false") +
        ",\"bm_state\":" + json_escape(safe_bm_state(snapshot.bm_state)) +
        ",\"bm_connection\":" + bm_connection_json(snapshot) +
        ",\"bm_resolving\":" + (snapshot.bm_resolving ? "true" : "false") +
        ",\"bm_connection_error\":" + json_escape(safe_bm_connection_error(snapshot.bm_connection_error)) +
        ",\"hri_phase\":" + json_escape(snapshot.hri_phase) +
        ",\"hri_ready\":" + (snapshot.hri_ready ? "true" : "false") +
        ",\"serial_open\":" + (snapshot.serial_open ? "true" : "false") +
        ",\"wavein_open\":" + (snapshot.wavein_open ? "true" : "false") +
        ",\"waveout_open\":" + (snapshot.waveout_open ? "true" : "false") +
        ",\"radio_state\":" + json_escape(snapshot.radio_state);
    if (include_audio_gains && snapshot.audio_gains.has_value()) {
        output.append(",\"audio_gains\":");
        output.append(audio_gains_json(*snapshot.audio_gains));
    }
    output.push_back('}');
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
      radio_identity_enabled_(static_cast<bool>(routing.update_radio_identity)),
      audio_gains_enabled_(static_cast<bool>(routing.set_audio_gains)),
      bm_connection_enabled_(static_cast<bool>(routing.set_bm_connection)),
      routing_(std::move(routing))
{
}

std::string Dispatcher::ready_line(std::uint32_t process_id)
{
    if (ready_emitted_) return {};
    ready_emitted_ = true;
    control_seq_ = 1U;
    const auto commands = supported_commands_json(
        routing_enabled_, quick_call_enabled_, radio_identity_enabled_, audio_gains_enabled_, bm_connection_enabled_);
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

    // 音量只保留最新接受的 revision 和两路值，避免拖动滑块消耗普通控制的 512 条重放预算。
    if (request.command == "audio.gains.set") {
        std::string_view error;
        std::string result{"rejected"};
        bool replayed = false;
        std::optional<StatusSnapshot::AudioGains> actual;
        if (request.schema_version != 2U) {
            error = "unsupported_schema";
        } else if (shutdown_requested_) {
            error = "shutdown_in_progress";
        } else if (!hello_seen_) {
            error = "hello_required";
        } else if (!audio_gains_enabled_) {
            result = "unsupported";
            error = "command_not_supported";
        } else {
            const auto* parameters = request.parameters;
            const auto* revision = parameters != nullptr ? parameters->find("revision") : nullptr;
            const auto* radio_gain = parameters != nullptr ? parameters->find("radio_playback_gain_milli") : nullptr;
            const auto* mic_gain = parameters != nullptr ? parameters->find("mic_transmit_gain_milli") : nullptr;
            const bool valid_fields = parameters != nullptr && parameters->type == strict_json::Value::Type::object &&
                parameters->object_value.size() == 3U &&
                revision != nullptr && revision->type == strict_json::Value::Type::unsigned_integer &&
                revision->integer_value >= 1U &&
                radio_gain != nullptr && radio_gain->type == strict_json::Value::Type::unsigned_integer &&
                valid_gain_milli(radio_gain->integer_value) &&
                mic_gain != nullptr && mic_gain->type == strict_json::Value::Type::unsigned_integer &&
                valid_gain_milli(mic_gain->integer_value);
            if (!valid_fields) {
                error = "invalid_audio_gains";
            } else if (request.request_id != expected_audio_gains_request_id(revision->integer_value)) {
                error = "audio_gain_request_id_mismatch";
            } else {
                const auto requested_radio_gain = static_cast<std::uint32_t>(radio_gain->integer_value);
                const auto requested_mic_gain = static_cast<std::uint32_t>(mic_gain->integer_value);
                if (last_audio_gains_mutation_.has_value() &&
                    revision->integer_value == last_audio_gains_mutation_->revision) {
                    if (requested_radio_gain != last_audio_gains_mutation_->requested_radio_playback_gain_milli ||
                        requested_mic_gain != last_audio_gains_mutation_->requested_mic_transmit_gain_milli) {
                        error = "audio_gain_revision_conflict";
                    } else {
                        result = "ok";
                        replayed = true;
                        actual = last_audio_gains_mutation_->actual;
                    }
                } else if (last_audio_gains_mutation_.has_value() &&
                           revision->integer_value < last_audio_gains_mutation_->revision) {
                    error = "stale_audio_gain_revision";
                } else {
                    RoutingCallbacks::AudioGainApplyResult applied{};
                    try { applied = routing_.set_audio_gains(requested_radio_gain, requested_mic_gain); }
                    catch (...) { applied.applied = false; }
                    if (!applied.applied || !valid_gain_milli(applied.radio_playback_gain_milli) ||
                        !valid_gain_milli(applied.mic_transmit_gain_milli)) {
                        error = "audio_gain_update_failed";
                    } else {
                        StatusSnapshot::AudioGains current{};
                        current.revision = revision->integer_value;
                        current.radio_playback_gain_milli = applied.radio_playback_gain_milli;
                        current.mic_transmit_gain_milli = applied.mic_transmit_gain_milli;
                        last_audio_gains_mutation_ = AudioGainsMutation{
                            revision->integer_value, requested_radio_gain, requested_mic_gain, current};
                        result = "ok";
                        actual = current;
                    }
                }
            }
        }

        std::string extra_json;
        if (actual.has_value()) extra_json = "\"audio_gains\":" + audio_gains_json(*actual);
        if (!error.empty()) {
            if (!extra_json.empty()) extra_json.push_back(',');
            extra_json.append("\"error\":");
            extra_json.append(json_escape(error));
        }
        return {serialize_result(request.request_id, request.command, result, extra_json, replayed), false, false};
    }

    // 身份缓存有独立的全局 revision 和固定 128 条 LRU，不消耗普通控制请求的 512 条重放预算。
    if (request.command == "radio_identity.cache_upsert") {
        std::string_view error;
        std::string result{"rejected"};
        bool replayed = false;
        if (request.schema_version != 2U) {
            error = "unsupported_schema";
        } else if (shutdown_requested_) {
            error = "shutdown_in_progress";
        } else if (!hello_seen_) {
            error = "hello_required";
        } else if (!radio_identity_enabled_) {
            result = "unsupported";
            error = "command_not_supported";
        } else {
            const auto* parameters = request.parameters;
            const auto* source_id = parameters != nullptr ? parameters->find("source_id") : nullptr;
            const auto* revision = parameters != nullptr ? parameters->find("revision") : nullptr;
            const auto* callsign = parameters != nullptr ? parameters->find("callsign") : nullptr;
            const bool valid_callsign = callsign != nullptr &&
                (callsign->type == strict_json::Value::Type::null_value ||
                 (callsign->type == strict_json::Value::Type::string &&
                  radio_identity_cache::Cache::is_valid_callsign(callsign->string_value)));
            const bool valid_fields = parameters != nullptr && parameters->type == strict_json::Value::Type::object &&
                parameters->object_value.size() == 3U &&
                source_id != nullptr && source_id->type == strict_json::Value::Type::unsigned_integer &&
                source_id->integer_value >= 1U &&
                source_id->integer_value <= radio_identity_cache::max_source_id &&
                revision != nullptr && revision->type == strict_json::Value::Type::unsigned_integer &&
                revision->integer_value >= 1U && valid_callsign;
            if (!valid_fields) {
                error = "invalid_identity";
            } else if (request.request_id != expected_identity_request_id(revision->integer_value)) {
                error = "identity_request_id_mismatch";
            } else {
                std::optional<std::string_view> mapped_callsign;
                if (callsign->type == strict_json::Value::Type::string) {
                    mapped_callsign = callsign->string_value;
                }
                radio_identity_cache::UpsertResult update = radio_identity_cache::UpsertResult::revision_conflict;
                try {
                    update = routing_.update_radio_identity(
                        static_cast<std::uint32_t>(source_id->integer_value),
                        revision->integer_value,
                        mapped_callsign);
                } catch (...) {
                    error = "identity_cache_update_failed";
                }
                if (error.empty()) {
                    using Update = radio_identity_cache::UpsertResult;
                    switch (update) {
                    case Update::inserted:
                    case Update::updated:
                    case Update::removed:
                    case Update::cleared:
                        result = "ok";
                        break;
                    case Update::replayed:
                        result = "ok";
                        replayed = true;
                        break;
                    case Update::invalid_source_id:
                    case Update::invalid_revision:
                    case Update::invalid_callsign:
                        error = "invalid_identity";
                        break;
                    case Update::stale_revision:
                        error = "stale_identity_revision";
                        break;
                    case Update::revision_conflict:
                        error = "identity_revision_conflict";
                        break;
                    }
                }
            }
        }

        std::string extra_json;
        if (!error.empty()) extra_json = "\"error\":" + json_escape(error);
        return {serialize_result(request.request_id, request.command, result, extra_json, replayed), false, false};
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
            const auto commands = supported_commands_json(
                routing_enabled_, quick_call_enabled_, radio_identity_enabled_, audio_gains_enabled_, bm_connection_enabled_);
            cached.extra_json = "\"supported_commands\":" +
                std::string(commands);
            mark_hello = true;
        } else if (request.command == "status") {
            if (!hello_seen_) {
                cached.result = "rejected";
                cached.extra_json = "\"error\":\"hello_required\"";
            } else {
                cached.result = "ok";
                cached.extra_json = "\"snapshot\":" + snapshot_json(snapshot, audio_gains_enabled_);
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
        } else if (request.command == "bm.connection.set") {
            if (!hello_seen_) {
                cached.result = "rejected";
                cached.extra_json = "\"error\":\"hello_required\"," + bm_connection_fields_json(snapshot);
            } else if (!bm_connection_enabled_) {
                cached.result = "unsupported";
                cached.extra_json = "\"error\":\"command_not_supported\"," + bm_connection_fields_json(snapshot);
            } else {
                const auto* params = request.parameters;
                const auto* enabled = params != nullptr ? params->find("enabled") : nullptr;
                const auto* revision = params != nullptr ? params->find("revision") : nullptr;
                const bool valid = params != nullptr && params->type == strict_json::Value::Type::object &&
                    params->object_value.size() == 2U && enabled != nullptr &&
                    enabled->type == strict_json::Value::Type::boolean && revision != nullptr &&
                    revision->type == strict_json::Value::Type::unsigned_integer && revision->integer_value >= 1U;
                if (!valid) {
                    cached.result = "rejected";
                    cached.extra_json = "\"error\":\"invalid_bm_connection_parameters\"," +
                        bm_connection_fields_json(snapshot);
                } else {
                    RoutingCallbacks::BmConnectionOutcome outcome{};
                    try {
                        outcome = routing_.set_bm_connection(enabled->boolean_value, revision->integer_value);
                    } catch (...) {
                        outcome.result = RoutingCallbacks::BmConnectionResult::transition_busy;
                        outcome.actual = snapshot;
                    }
                    const bool accepted = outcome.result == RoutingCallbacks::BmConnectionResult::accepted ||
                        outcome.result == RoutingCallbacks::BmConnectionResult::idempotent;
                    cached.result = accepted ? "accepted" : "rejected";
                    cached.extra_json = bm_connection_fields_json(outcome.actual);
                    if (!accepted) {
                        cached.extra_json.append(",\"error\":");
                        cached.extra_json.append(json_escape(bm_connection_request_error(outcome.result)));
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
