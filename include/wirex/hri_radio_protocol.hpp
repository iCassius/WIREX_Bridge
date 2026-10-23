#pragma once

#include <cstddef>
#include <set>
#include <string>
#include <string_view>

namespace wirex::hri_radio_protocol {

inline constexpr std::size_t max_command_line_bytes = 256;
inline constexpr std::size_t max_requests_per_session = 4096;

enum class CommandKind {
    send_fixed,
    capture_mic,
    cancel_operation,
    shutdown,
};

enum class ParseError {
    none,
    line_too_long,
    invalid_ascii,
    invalid_syntax,
    unsupported_version,
    invalid_identifier,
    stale_run_id,
    duplicate_request_id,
    unknown_command,
    request_limit,
};

struct Command {
    std::string run_id;
    std::string request_id;
    CommandKind kind{CommandKind::shutdown};
};

// 解析来自本机控制端的严格 ASCII 行，不依赖 JSON 库或设备接口。
class Parser final {
public:
    explicit Parser(std::string expected_run_id);

    [[nodiscard]] ParseError parse(std::string_view line, Command& command);
    [[nodiscard]] std::size_t accepted_request_count() const noexcept { return request_ids_.size(); }

private:
    std::string expected_run_id_;
    std::set<std::string> request_ids_;
};

[[nodiscard]] const char* command_name(CommandKind kind) noexcept;
[[nodiscard]] const char* error_name(ParseError error) noexcept;

} // namespace wirex::hri_radio_protocol
