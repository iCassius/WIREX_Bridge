#include "dev_log.hpp"

// DevLog::attach 依赖引擎的 append_status_line，单独成文件，使只用 line() 的 ViewModel 单元测试不必链接引擎。

#include <atomic>
#include <cstdio>
#include <sstream>
#include <string>

namespace wirex::gui {

namespace {

std::string printable_type(std::uint8_t byte)
{
    if (byte >= 0x21U && byte <= 0x7EU) return std::string(1, static_cast<char>(byte));
    char buffer[8]{};
    std::snprintf(buffer, sizeof(buffer), "0x%02X", byte);
    return buffer;
}

} // namespace

void DevLog::attach(engine::DiagnosticsHooks& hooks, std::string_view run_label)
{
    const std::uint64_t run_seq = next_run_seq();
    const std::string run_id = std::string(run_label) + "-" + std::to_string(run_seq);
    auto self = this; // DevLog 由 shared_ptr 持有，进程退出前不释放；钩子只在引擎运行期间调用。
    auto seq = std::make_shared<std::atomic<std::uint64_t>>(0U);

    auto previous_status = hooks.status;
    hooks.status = [self, previous_status, seq, run_id](const engine::StatusRecord& record) {
        bool ok = true;
        if (previous_status) ok = previous_status(record);
        std::ostringstream text;
        if (engine::append_status_line(text, run_id, ++*seq, record)) {
            auto s = text.str();
            while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
            self->line("status", s);
        }
        return ok; // dev 日志写入失败不影响引擎
    };

    auto previous_console = hooks.console;
    hooks.console = [self, previous_console](std::string_view text, bool error_stream) {
        if (previous_console) previous_console(text, error_stream);
        self->line(error_stream ? "stderr" : "stdout", text);
    };

    auto previous_serial = hooks.serial;
    hooks.serial = [self, previous_serial](bool tx, std::uint8_t first_byte, std::size_t bytes,
                                           std::uint64_t elapsed_ms) {
        if (previous_serial) previous_serial(tx, first_byte, bytes, elapsed_ms);
        self->line("hri", std::string(tx ? "TX " : "RX ") + printable_type(first_byte) + " bytes=" +
                              std::to_string(bytes) + " t=" + std::to_string(elapsed_ms) + "ms");
    };
    line("dev", "engine hooks attached run=" + run_id);
}

} // namespace wirex::gui
