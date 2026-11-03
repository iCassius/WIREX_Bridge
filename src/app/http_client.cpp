#include "wirex/app/http_client.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace wirex::app {

void secure_wipe(std::string& value) noexcept
{
    if (!value.empty()) SecureZeroMemory(value.data(), value.size());
    value.clear();
}

void secure_wipe(std::wstring& value) noexcept
{
    if (!value.empty()) SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
    value.clear();
}

void HttpRequest::wipe() noexcept
{
    for (auto& header : headers) secure_wipe(header.value);
    headers.clear();
    secure_wipe(body);
}

namespace {

bool to_wide(const std::string& input, std::wstring& output)
{
    output.clear();
    if (input.empty()) return true;
    if (input.size() > static_cast<std::size_t>(INT32_MAX)) return false;
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                                         static_cast<int>(input.size()), nullptr, 0);
    if (size <= 0) return false;
    output.resize(static_cast<std::size_t>(size));
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()),
                               output.data(), size) == size;
}

struct HandleCloser {
    HINTERNET handle{};
    ~HandleCloser() { if (handle != nullptr) WinHttpCloseHandle(handle); }
};

// 请求句柄由 watchdog 与调用线程共享：谁先关闭谁负责，另一方不再触碰。
class RequestGuard final {
public:
    explicit RequestGuard(HINTERNET handle) noexcept : handle_(handle) {}
    RequestGuard(const RequestGuard&) = delete;
    RequestGuard& operator=(const RequestGuard&) = delete;
    ~RequestGuard() { close(); }

    void close() noexcept
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (handle_ != nullptr) {
            WinHttpCloseHandle(handle_);
            handle_ = nullptr;
        }
    }

    [[nodiscard]] HINTERNET get() const noexcept { return handle_; }

private:
    std::mutex mutex_{};
    HINTERNET handle_{};
};

enum class StopReason { none, timeout, canceled };

class Watchdog final {
public:
    Watchdog(RequestGuard& guard, std::chrono::steady_clock::time_point deadline, const std::atomic<bool>* cancel)
        : guard_(guard), deadline_(deadline), cancel_(cancel), thread_([this] { run(); })
    {
    }
    Watchdog(const Watchdog&) = delete;
    Watchdog& operator=(const Watchdog&) = delete;
    ~Watchdog()
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            done_ = true;
        }
        condition_.notify_all();
        if (thread_.joinable()) thread_.join();
    }

    [[nodiscard]] StopReason reason() const noexcept { return reason_.load(); }

private:
    void run()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            if (done_) return;
            if (cancel_ != nullptr && cancel_->load()) { reason_ = StopReason::canceled; break; }
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline_) { reason_ = StopReason::timeout; break; }
            const auto wait = std::min<std::chrono::steady_clock::duration>(deadline_ - now, std::chrono::milliseconds(50));
            condition_.wait_for(lock, wait);
        }
        lock.unlock();
        guard_.close();
    }

    RequestGuard& guard_;
    std::chrono::steady_clock::time_point deadline_;
    const std::atomic<bool>* cancel_;
    std::mutex mutex_{};
    std::condition_variable condition_{};
    bool done_{false};
    std::atomic<StopReason> reason_{StopReason::none};
    std::thread thread_;
};

HttpResponse fail(HttpErrorKind kind, DWORD error = 0U)
{
    HttpResponse response{};
    response.error = kind;
    response.system_error = error;
    return response;
}

} // namespace

HttpResponse winhttp_send(const HttpRequest& request, const std::atomic<bool>* cancel)
{
    try {
        if (cancel != nullptr && cancel->load()) return fail(HttpErrorKind::canceled);
        if (request.timeout_ms == 0U) return fail(HttpErrorKind::invalid_request);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(request.timeout_ms);

        std::wstring url;
        std::wstring method;
        std::wstring agent;
        if (!to_wide(request.url, url) || !to_wide(request.method, method) || !to_wide(request.user_agent, agent)) {
            return fail(HttpErrorKind::invalid_request);
        }

        URL_COMPONENTS parts{};
        parts.dwStructSize = sizeof(parts);
        parts.dwHostNameLength = static_cast<DWORD>(-1);
        parts.dwUrlPathLength = static_cast<DWORD>(-1);
        parts.dwExtraInfoLength = static_cast<DWORD>(-1);
        if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &parts)) {
            return fail(HttpErrorKind::invalid_request, GetLastError());
        }
        if (parts.nScheme != INTERNET_SCHEME_HTTPS && parts.nScheme != INTERNET_SCHEME_HTTP) {
            return fail(HttpErrorKind::invalid_request);
        }
        const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
        std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
        if (parts.lpszExtraInfo != nullptr) path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
        if (path.empty()) path = L"/";

        HandleCloser session{WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                         WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
        if (session.handle == nullptr) {
            // Windows 8.1 之前不支持 AUTOMATIC_PROXY；退回默认代理配置。
            session.handle = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                         WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        }
        if (session.handle == nullptr) return fail(HttpErrorKind::transport, GetLastError());
        const int timeout = static_cast<int>(std::min<std::uint32_t>(request.timeout_ms, 600000U));
        if (!WinHttpSetTimeouts(session.handle, timeout, timeout, timeout, timeout)) {
            return fail(HttpErrorKind::transport, GetLastError());
        }

        HandleCloser connection{WinHttpConnect(session.handle, host.c_str(), parts.nPort, 0)};
        if (connection.handle == nullptr) return fail(HttpErrorKind::transport, GetLastError());

        const DWORD flags = parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0U;
        RequestGuard guard(WinHttpOpenRequest(connection.handle, method.c_str(), path.c_str(), nullptr,
                                              WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags));
        if (guard.get() == nullptr) return fail(HttpErrorKind::transport, GetLastError());

        DWORD disable = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES;
        if (!WinHttpSetOption(guard.get(), WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof(disable))) {
            return fail(HttpErrorKind::transport, GetLastError());
        }

        std::wstring header_block;
        for (const auto& header : request.headers) {
            std::wstring name;
            std::wstring value;
            if (!to_wide(header.name, name) || !to_wide(header.value, value)) {
                secure_wipe(value);
                secure_wipe(header_block);
                return fail(HttpErrorKind::invalid_request);
            }
            header_block += name;
            header_block += L": ";
            header_block += value;
            header_block += L"\r\n";
            secure_wipe(value);
        }

        Watchdog watchdog(guard, deadline, cancel);
        const auto stopped = [&]() -> HttpResponse {
            secure_wipe(header_block);
            const auto reason = watchdog.reason();
            if (reason == StopReason::canceled) return fail(HttpErrorKind::canceled);
            if (reason == StopReason::timeout) return fail(HttpErrorKind::timeout);
            const DWORD error = GetLastError();
            if (error == ERROR_WINHTTP_TIMEOUT) return fail(HttpErrorKind::timeout, error);
            return fail(HttpErrorKind::transport, error);
        };

        const BOOL sent = WinHttpSendRequest(
            guard.get(),
            header_block.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : header_block.c_str(),
            header_block.empty() ? 0U : static_cast<DWORD>(-1L),
            request.body.empty() ? WINHTTP_NO_REQUEST_DATA : const_cast<char*>(request.body.data()),
            static_cast<DWORD>(request.body.size()), static_cast<DWORD>(request.body.size()), 0);
        if (!sent) return stopped();
        secure_wipe(header_block);
        if (!WinHttpReceiveResponse(guard.get(), nullptr)) return stopped();

        DWORD status = 0U;
        DWORD status_size = sizeof(status);
        if (!WinHttpQueryHeaders(guard.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                 WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size, WINHTTP_NO_HEADER_INDEX)) {
            return stopped();
        }

        HttpResponse response{};
        response.status_code = static_cast<int>(status);
        if (status < 200U || status >= 300U || !request.read_body_on_success) return response;

        for (;;) {
            DWORD available = 0U;
            if (!WinHttpQueryDataAvailable(guard.get(), &available)) return stopped();
            if (available == 0U) break;
            if (response.body.size() + available > request.max_response_bytes) return fail(HttpErrorKind::too_large);
            const auto offset = response.body.size();
            response.body.resize(offset + available);
            DWORD read = 0U;
            if (!WinHttpReadData(guard.get(), response.body.data() + offset, available, &read)) return stopped();
            response.body.resize(offset + read);
            if (read == 0U) break;
        }
        if (watchdog.reason() == StopReason::canceled) return fail(HttpErrorKind::canceled);
        if (watchdog.reason() == StopReason::timeout) return fail(HttpErrorKind::timeout);
        return response;
    } catch (...) {
        return fail(HttpErrorKind::transport);
    }
}

} // namespace wirex::app
