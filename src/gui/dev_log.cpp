#include "dev_log.hpp"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdio>
#include <fstream>
#include <mutex>
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

std::uint64_t DevLog::next_run_seq()
{
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return ++impl_->run_seq;
}

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
