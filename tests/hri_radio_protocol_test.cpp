#include "wirex/hri_radio_protocol.hpp"

#include <iostream>
#include <string>

namespace {

int failures = 0;

void check(bool condition, const char* message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void test_commands_and_request_identity()
{
    wirex::hri_radio_protocol::Parser parser("0123456789abcdef");
    wirex::hri_radio_protocol::Command command{};
    check(parser.parse("1 0123456789abcdef req_1 send_fixed", command) ==
        wirex::hri_radio_protocol::ParseError::none && command.kind ==
        wirex::hri_radio_protocol::CommandKind::send_fixed && command.request_id == "req_1",
        "固定语句命令应解析并保留request_id");
    check(parser.parse("1 0123456789abcdef req_2 capture_mic", command) ==
        wirex::hri_radio_protocol::ParseError::none && command.kind ==
        wirex::hri_radio_protocol::CommandKind::capture_mic,
        "麦克风采集命令应可解析");
    check(parser.parse("1 0123456789abcdef req_3 cancel_operation", command) ==
        wirex::hri_radio_protocol::ParseError::none && command.kind ==
        wirex::hri_radio_protocol::CommandKind::cancel_operation,
        "取消当前操作命令应可解析");
    check(parser.parse("1 0123456789abcdef req_4 shutdown", command) ==
        wirex::hri_radio_protocol::ParseError::none && command.kind ==
        wirex::hri_radio_protocol::CommandKind::shutdown,
        "退出命令应可解析");
    check(parser.accepted_request_count() == 4, "每个已接受请求ID都应只记录一次");
}

void test_rejection_does_not_change_accepted_command()
{
    wirex::hri_radio_protocol::Parser parser("run_A");
    wirex::hri_radio_protocol::Command command{};
    check(parser.parse("1 run_A one send_fixed", command) ==
        wirex::hri_radio_protocol::ParseError::none, "第一条请求应被接受");
    const auto saved = command;
    check(parser.parse("1 old_run two shutdown", command) ==
        wirex::hri_radio_protocol::ParseError::stale_run_id,
        "旧run_id请求应被拒绝");
    check(parser.parse("1 run_A one shutdown", command) ==
        wirex::hri_radio_protocol::ParseError::duplicate_request_id,
        "重复request_id应被拒绝");
    check(parser.accepted_request_count() == 1 && saved.request_id == "one",
        "拒绝旧run或重复请求不应消耗已接受请求槽位");
}

void test_strict_ascii_shape_and_bounds()
{
    wirex::hri_radio_protocol::Parser parser("r");
    wirex::hri_radio_protocol::Command command{};
    using wirex::hri_radio_protocol::ParseError;
    check(parser.parse("1  r x shutdown", command) == ParseError::invalid_syntax,
        "重复空格应拒绝");
    check(parser.parse("1 r x  shutdown", command) == ParseError::invalid_syntax,
        "多余字段/空字段应拒绝");
    check(parser.parse("2 r x shutdown", command) == ParseError::unsupported_version,
        "不支持的协议版本应拒绝");
    check(parser.parse("1 r x unknown", command) == ParseError::unknown_command,
        "未知命令应拒绝");
    check(parser.parse(std::string(257, 'a'), command) == ParseError::line_too_long,
        "超过256字节的命令行应拒绝");
    std::string non_ascii("1 r ", 4);
    non_ascii.push_back(static_cast<char>(0x80));
    non_ascii += " shutdown";
    check(parser.parse(non_ascii, command) == ParseError::invalid_ascii,
        "非ASCII请求应拒绝");
    check(parser.parse("1 r bad.id shutdown", command) == ParseError::invalid_identifier,
        "含点号的request ID应拒绝");
    check(parser.accepted_request_count() == 0, "拒绝的请求不应占用request ID");
}

} // namespace

int main()
{
    test_commands_and_request_identity();
    test_rejection_does_not_change_accepted_command();
    test_strict_ascii_shape_and_bounds();
    if (failures != 0) {
        std::cerr << failures << " assertion(s) failed\n";
        return 1;
    }
    std::cout << "hri_radio_protocol_test passed\n";
    return 0;
}
