#include "wirex/hri_radio_protocol.hpp"

#include <array>
#include <utility>

namespace wirex::hri_radio_protocol {
namespace {

bool valid_identifier(std::string_view value) noexcept
{
    if (value.empty() || value.size() > 64) return false;
    for (const unsigned char ch : value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '_' || ch == '-')) return false;
    }
    return true;
}

} // namespace

Parser::Parser(std::string expected_run_id) : expected_run_id_(std::move(expected_run_id))
{
}

ParseError Parser::parse(std::string_view line, Command& command)
{
    command = {};
    if (line.size() > max_command_line_bytes) return ParseError::line_too_long;
    for (const unsigned char ch : line) {
        if (ch < 0x20 || ch > 0x7e) return ParseError::invalid_ascii;
    }

    std::array<std::string_view, 4> fields{};
    std::size_t field_index = 0;
    std::size_t start = 0;
    for (std::size_t index = 0; index <= line.size(); ++index) {
        if (index != line.size() && line[index] != ' ') continue;
        if (field_index >= fields.size() || index == start) return ParseError::invalid_syntax;
        fields[field_index++] = line.substr(start, index - start);
        start = index + 1;
    }
    if (field_index != fields.size()) return ParseError::invalid_syntax;
    if (fields[0] != "1") return ParseError::unsupported_version;
    if (!valid_identifier(fields[1]) || !valid_identifier(fields[2])) return ParseError::invalid_identifier;
    command.run_id.assign(fields[1]);
    command.request_id.assign(fields[2]);
    if (fields[1] != expected_run_id_) return ParseError::stale_run_id;
    if (request_ids_.find(std::string(fields[2])) != request_ids_.end()) return ParseError::duplicate_request_id;
    if (request_ids_.size() >= max_requests_per_session) return ParseError::request_limit;

    CommandKind kind{};
    if (fields[3] == "send_fixed") kind = CommandKind::send_fixed;
    else if (fields[3] == "capture_mic") kind = CommandKind::capture_mic;
    else if (fields[3] == "cancel_operation") kind = CommandKind::cancel_operation;
    else if (fields[3] == "shutdown") kind = CommandKind::shutdown;
    else return ParseError::unknown_command;

    // 合法run/request ID先占用，避免重放同一控制请求；拒绝的旧run/未知命令不占用。
    request_ids_.emplace(fields[2]);
    command.kind = kind;
    return ParseError::none;
}

const char* command_name(CommandKind kind) noexcept
{
    switch (kind) {
    case CommandKind::send_fixed: return "send_fixed";
    case CommandKind::capture_mic: return "capture_mic";
    case CommandKind::cancel_operation: return "cancel_operation";
    case CommandKind::shutdown: return "shutdown";
    }
    return "unknown";
}

const char* error_name(ParseError error) noexcept
{
    switch (error) {
    case ParseError::none: return "none";
    case ParseError::line_too_long: return "line_too_long";
    case ParseError::invalid_ascii: return "invalid_ascii";
    case ParseError::invalid_syntax: return "invalid_syntax";
    case ParseError::unsupported_version: return "unsupported_version";
    case ParseError::invalid_identifier: return "invalid_identifier";
    case ParseError::stale_run_id: return "stale_run_id";
    case ParseError::duplicate_request_id: return "duplicate_request_id";
    case ParseError::unknown_command: return "unknown_command";
    case ParseError::request_limit: return "request_limit";
    }
    return "unknown";
}

} // namespace wirex::hri_radio_protocol
