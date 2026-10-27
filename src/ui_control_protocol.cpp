#include "wirex/ui_control_protocol.hpp"

#include <array>
#include <utility>

namespace wirex::ui_control {
namespace {

constexpr std::string_view supported_commands_json = "[\"hello\",\"status\",\"shutdown\"]";

bool is_space(char value) noexcept
{
    return value == ' ' || value == '\t' || value == '\r';
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
};

class FlatJsonReader final {
public:
    explicit FlatJsonReader(std::string_view input) noexcept : input_(input) {}

    bool parse(Request& request)
    {
        skip_space();
        if (!consume('{')) return false;
        bool have_schema = false;
        bool have_run_id = false;
        bool have_request_id = false;
        bool have_command = false;
        skip_space();
        if (consume('}')) return false;
        while (position_ < input_.size()) {
            std::string key;
            if (!parse_string(key)) return false;
            skip_space();
            if (!consume(':')) return false;
            skip_space();
            if (key == "schema_version") {
                if (have_schema || !parse_unsigned(request.schema_version)) return false;
                have_schema = true;
            } else if (key == "run_id") {
                if (have_run_id || !parse_string(request.run_id)) return false;
                have_run_id = true;
            } else if (key == "request_id") {
                if (have_request_id || !parse_string(request.request_id)) return false;
                have_request_id = true;
            } else if (key == "command") {
                if (have_command || !parse_string(request.command)) return false;
                have_command = true;
            } else {
                return false;
            }
            skip_space();
            if (consume('}')) break;
            if (!consume(',')) return false;
            skip_space();
        }
        skip_space();
        return position_ == input_.size() && have_schema && have_run_id &&
            have_request_id && have_command && valid_identifier(request.run_id, 128U) &&
            valid_identifier(request.request_id, 128U) && valid_command_name(request.command);
    }

private:
    bool consume(char expected) noexcept
    {
        if (position_ >= input_.size() || input_[position_] != expected) return false;
        ++position_;
        return true;
    }

    void skip_space() noexcept
    {
        while (position_ < input_.size() && is_space(input_[position_])) ++position_;
    }

    bool parse_string(std::string& output)
    {
        if (!consume('"')) return false;
        output.clear();
        while (position_ < input_.size()) {
            const unsigned char ch = static_cast<unsigned char>(input_[position_++]);
            if (ch == '"') return true;
            if (ch < 0x20U || ch > 0x7eU) return false;
            if (ch != '\\') {
                output.push_back(static_cast<char>(ch));
                continue;
            }
            if (position_ >= input_.size()) return false;
            const char escaped = input_[position_++];
            switch (escaped) {
            case '"': output.push_back('"'); break;
            case '\\': output.push_back('\\'); break;
            case '/': output.push_back('/'); break;
            case 'b': output.push_back('\b'); break;
            case 'f': output.push_back('\f'); break;
            case 'n': output.push_back('\n'); break;
            case 'r': output.push_back('\r'); break;
            case 't': output.push_back('\t'); break;
            case 'u': {
                if (input_.size() - position_ < 4U) return false;
                unsigned int codepoint = 0U;
                for (unsigned int index = 0U; index < 4U; ++index) {
                    const char digit = input_[position_++];
                    unsigned int value = 0U;
                    if (digit >= '0' && digit <= '9') value = static_cast<unsigned int>(digit - '0');
                    else if (digit >= 'a' && digit <= 'f') value = static_cast<unsigned int>(digit - 'a' + 10);
                    else if (digit >= 'A' && digit <= 'F') value = static_cast<unsigned int>(digit - 'A' + 10);
                    else return false;
                    codepoint = (codepoint << 4U) | value;
                }
                if (codepoint < 0x20U || codepoint > 0x7eU) return false;
                output.push_back(static_cast<char>(codepoint));
                break;
            }
            default: return false;
            }
        }
        return false;
    }

    bool parse_unsigned(std::uint32_t& output) noexcept
    {
        if (position_ >= input_.size() || input_[position_] < '0' || input_[position_] > '9') return false;
        if (input_[position_] == '0' && position_ + 1U < input_.size() &&
            input_[position_ + 1U] >= '0' && input_[position_ + 1U] <= '9') return false;
        std::uint64_t value = 0U;
        while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
            const auto digit = static_cast<unsigned int>(input_[position_] - '0');
            if (value > (UINT32_MAX - digit) / 10U) return false;
            value = value * 10U + digit;
            ++position_;
        }
        output = static_cast<std::uint32_t>(value);
        return true;
    }

    std::string_view input_;
    std::size_t position_{};
};

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

Dispatcher::Dispatcher(std::string run_id, bool diagnostic)
    : run_id_(std::move(run_id)), diagnostic_(diagnostic)
{
}

std::string Dispatcher::ready_line(std::uint32_t process_id)
{
    if (ready_emitted_) return {};
    ready_emitted_ = true;
    control_seq_ = 1U;
    return "{\"schema_version\":2,\"type\":\"control_ready\",\"run_id\":" +
        json_escape(run_id_) + ",\"control_seq\":1,\"process_id\":" +
        std::to_string(process_id) + ",\"control_version\":2,\"supported_commands\":" +
        std::string(supported_commands_json) + ",\"diagnostic\":" +
        (diagnostic_ ? "true" : "false") + "}";
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
    FlatJsonReader reader(json_line);
    if (!reader.parse(request)) {
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
    CachedResult cached{};
    cached.body.assign(json_line);
    cached.request_id = request.request_id;
    cached.command = request.command;
    if (cache_exhausted_ && !may_use_shutdown_slot) {
        // 缓存已满后不再接受新状态查询或操作；第二个溢出ID使运行进入有界收尾。
        shutdown_requested_ = true;
        return {serialize_rejection(request.request_id, request.command, "cache_full"), true, false};
    } else if (request.schema_version != 2U) {
        cached.result = "rejected";
        cached.extra_json = "\"error\":\"unsupported_schema\"";
    } else if (shutdown_requested_) {
        cached.result = "rejected";
        cached.extra_json = "\"error\":\"shutdown_in_progress\"";
    } else if (request.command == "hello") {
        cached.result = "ok";
        cached.extra_json = "\"supported_commands\":" + std::string(supported_commands_json);
    } else if (request.command == "status") {
        if (!hello_seen_) {
            cached.result = "rejected";
            cached.extra_json = "\"error\":\"hello_required\"";
        } else {
            cached.result = "ok";
            cached.extra_json = "\"snapshot\":" + snapshot_json(snapshot);
        }
    } else if (request.command == "shutdown") {
        cached.result = "ok";
        cached.shutdown_requested = true;
        cached.extra_json = "\"shutdown_requested\":true";
    } else {
        cached.result = "unsupported";
        cached.extra_json = "\"error\":\"command_not_supported\"";
    }

    const std::size_t current_cached_result_count = cached_result_count();
    if (cached.shutdown_requested && (shutdown_slot_used_ || current_cached_result_count >= max_cached_requests)) {
        shutdown_requested_ = true;
        return {serialize_rejection(request.request_id, request.command,
                                    "cache_full"), true, false};
    }
    if (!cached.shutdown_requested && !cache_full_rejection_ &&
        non_shutdown_requests_ >= max_cached_requests - 2U) {
        cached.result = "rejected";
        cached.extra_json = "\"error\":\"cache_full\"";
        cache_full_rejection_ = cached;
        cache_exhausted_ = true;
        return {serialize_result(request.request_id, cached.command, cached.result,
                                 cached.extra_json, false), shutdown_requested_, false};
    }
    if (!cached.shutdown_requested && current_cached_result_count >= max_cached_requests) {
        // 此路径发生在溢出拒绝已绑定后；关闭本 run，避免无空间记录新 request_id。
        shutdown_requested_ = true;
        return {serialize_rejection(request.request_id, request.command, "cache_full"), true, false};
    }

    cache_.emplace(request.request_id, cached);
    if (request.command == "hello" && cached.result == "ok") hello_seen_ = true;
    if (request.command == "shutdown" && cached.result == "ok") {
        shutdown_requested_ = true;
        shutdown_slot_used_ = true;
    }
    if (!cached.shutdown_requested) ++non_shutdown_requests_;
    return {serialize_result(request.request_id, cached.command, cached.result,
                             cached.extra_json, false), cached.shutdown_requested, false};
}

DispatchResult Dispatcher::reject(std::string_view error_code)
{
    return {serialize_rejection({}, {}, error_code), false, true};
}

} // namespace wirex::ui_control
