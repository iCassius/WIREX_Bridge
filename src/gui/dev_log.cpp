#include "dev_log.hpp"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <system_error>

namespace wirex::gui {

struct DevLog::Impl {
    std::mutex mutex;
    std::ofstream out;
    std::filesystem::path path;
    std::uint64_t run_seq{};
};

namespace {

std::string local_timestamp(bool for_file_name)
{
    SYSTEMTIME t{};
    GetLocalTime(&t);
    char buffer[40]{};
    if (for_file_name) {
        std::snprintf(buffer, sizeof(buffer), "%04u%02u%02u-%02u%02u%02u", t.wYear, t.wMonth, t.wDay, t.wHour,
                      t.wMinute, t.wSecond);
    } else {
        std::snprintf(buffer, sizeof(buffer), "%02u:%02u:%02u.%03u", t.wHour, t.wMinute, t.wSecond,
                      t.wMilliseconds);
    }
    return buffer;
}

std::string printable_type(std::uint8_t byte)
{
    if (byte >= 0x21U && byte <= 0x7EU) return std::string(1, static_cast<char>(byte));
    char buffer[8]{};
    std::snprintf(buffer, sizeof(buffer), "0x%02X", byte);
    return buffer;
}

std::mutex g_instance_mutex;
std::shared_ptr<DevLog> g_instance;

} // namespace

DevLog::DevLog() : impl_(std::make_unique<Impl>()) {}
DevLog::~DevLog() = default;

std::shared_ptr<DevLog> DevLog::open(const std::filesystem::path& exe_directory)
{
    std::error_code ec;
    const auto directory = exe_directory / L"logs";
    std::filesystem::create_directories(directory, ec);
    if (ec) return nullptr;
    std::shared_ptr<DevLog> log(new DevLog());
    log->impl_->path = directory / (L"wirex-" + std::filesystem::path(local_timestamp(true)).wstring() + L".log");
    log->impl_->out.open(log->impl_->path, std::ios::binary | std::ios::app);
    if (!log->impl_->out) return nullptr;
    log->line("dev", "dev log opened (WIREX_DEV_BUILD=" + std::to_string(WIREX_DEV_BUILD) + ")");
    return log;
}

const std::filesystem::path& DevLog::path() const noexcept { return impl_->path; }

void DevLog::line(std::string_view category, std::string_view text)
{
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->out) return;
    try {
        impl_->out << local_timestamp(false) << " [" << category << "] " << text;
        if (text.empty() || text.back() != '\n') impl_->out << '\n';
        impl_->out.flush();
    } catch (...) {
    }
}

void DevLog::attach(engine::DiagnosticsHooks& hooks, std::string_view run_label)
{
    std::uint64_t run_seq = 0U;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        run_seq = ++impl_->run_seq;
    }
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

void set_dev_log(std::shared_ptr<DevLog> log)
{
    std::lock_guard<std::mutex> lock(g_instance_mutex);
    g_instance = std::move(log);
}

std::shared_ptr<DevLog> dev_log()
{
    std::lock_guard<std::mutex> lock(g_instance_mutex);
    return g_instance;
}

} // namespace wirex::gui
