#include "dev_log.hpp"
#include "hri_diagnostics.hpp"
#include "wirex/direct_stream.hpp"

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
        if (record.event == "radio_detached_bm_runtime_preserved") self->reset_hri_correlation();
        else if (record.event == "runtime_snapshot") self->poll_hri_correlation();
        if (record.event == "bm_rx_filtered_stream") {
            const auto& c = record.counters;
            std::ostringstream readable;
            readable << "source=" << c.rx_filtered_source_id
                     << " destination=" << c.rx_filtered_destination_id
                     << " kind=" << (c.rx_filtered_call_kind == 'P' ? "private" : "group")
                     << " slot=TS" << c.rx_filtered_slot
                     << " reason=" << c.rx_filtered_reason
                     << " stream=0x" << std::hex << c.rx_filtered_stream_id << std::dec
                     << " t=" << record.elapsed_ms << "ms";
            self->line("rx-filtered", readable.str());
        }
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
    hooks.serial = [self, previous_serial](bool tx, std::uint8_t record_type, std::size_t bytes,
                                           std::uint64_t elapsed_ms) {
        if (previous_serial) previous_serial(tx, record_type, bytes, elapsed_ms);
        self->line("hri", std::string(tx ? "TX " : "RX ") +
                              (record_type == 0U ? std::string("(cont)") : printable_type(record_type)) + " bytes=" +
                              std::to_string(bytes) + " t=" + std::to_string(elapsed_ms) + "ms");
    };
    struct SerialDiagnostics {
        direct_stream::Parser tx;
        direct_stream::Parser rx;
        hri_diagnostics::Records records;
    };
    auto serial_diagnostics = std::make_shared<SerialDiagnostics>();
    auto previous_serial_data = hooks.serial_data;
    hooks.serial_data = [self, previous_serial_data, serial_diagnostics](bool tx, const std::uint8_t* data,
                                                                       std::size_t size) {
        if (previous_serial_data) previous_serial_data(tx, data, size);
        auto& parser = tx ? serial_diagnostics->tx : serial_diagnostics->rx;
        const auto parsed = parser.feed(data, size);
        for (const auto& event : parsed.events) {
            if (!event.has_record) continue;
            if (tx && event.record.type == 'V' && event.record.payload.empty()) {
                serial_diagnostics->records.reset();
                serial_diagnostics->rx.reset();
                self->reset_hri_correlation();
            }
            serial_diagnostics->records.record(tx, event.record.type, event.record.payload,
                [self](const std::string& text) { self->line("hri", text); },
                [self](bool pressed) { self->observe_hri_ptt(pressed); });
        }
    };
    auto previous_rx_policy = hooks.rx_policy;
    hooks.rx_policy = [self, previous_rx_policy](std::string_view summary) {
        if (previous_rx_policy) previous_rx_policy(summary);
        self->line("rx-policy", summary);
    };
    line("dev", "engine hooks attached run=" + run_id);
}

} // namespace wirex::gui
