#include "wirex/ui_control_protocol.hpp"

#include <iostream>
#include <string_view>

namespace {

int failures{};

void check(bool condition, std::string_view label)
{
    if (condition) return;
    std::cerr << "FAILED: " << label << '\n';
    ++failures;
}

} // namespace

int main()
{
    using wirex::ui_control::Parser;
    using wirex::ui_control::Result;

    {
        Parser parser;
        check(parser.feed("Q") == Result::pending, "Q waits for a line terminator");
        check(parser.feed("\n") == Result::shutdown, "Q newline requests shutdown");
    }
    {
        Parser parser;
        check(parser.feed("Q\r\n") == Result::shutdown, "Windows CRLF Q requests shutdown");
    }
    {
        Parser parser;
        check(parser.eof() == Result::shutdown, "EOF requests safe shutdown");
    }
    {
        Parser parser;
        check(parser.feed("Q") == Result::pending, "partial Q before EOF remains pending");
        check(parser.eof() == Result::shutdown, "EOF after partial Q requests safe shutdown");
    }
    for (const auto invalid : {std::string_view{"T\n"}, std::string_view{"q\n"},
                               std::string_view{"Q\nT"}, std::string_view{"QQ\n"},
                               std::string_view{"\n"}}) {
        Parser parser;
        check(parser.feed(invalid) == Result::invalid, "only one uppercase Q line is accepted");
    }
    {
        Parser parser;
        check(parser.feed("T") == Result::invalid, "PTT-like input is rejected");
        check(parser.eof() == Result::invalid, "invalid input cannot become a shutdown success");
    }
    if (failures != 0) return 1;
    std::cout << "ui_pipe_test: all assertions passed\n";
    return 0;
}
