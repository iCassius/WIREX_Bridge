#pragma once

// BM API 与 RadioID 查询共用的同步 HTTP 抽象。默认实现基于 WinHTTP，
// 必须在 worker 线程中调用；测试通过 HttpTransport 注入假实现，不访问网络。

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace wirex::app {

struct HttpHeader {
    std::string name{};
    std::string value{};
};

struct HttpRequest {
    std::string method{};                  // GET / POST / DELETE
    std::string url{};                     // 完整 http(s) URL
    std::string user_agent{"WIREX Bridge"};
    std::vector<HttpHeader> headers{};     // 可能含 Authorization；调用方用完后 wipe()
    std::string body{};
    std::uint32_t timeout_ms{3000U};       // 整个请求（连接+发送+接收+读正文）的总时限
    std::size_t max_response_bytes{1048576U};
    bool read_body_on_success{true};       // 仅在 2xx 时读取正文

    // 擦除 header 值与 body（含 Bearer token），避免敏感数据残留在内存中。
    void wipe() noexcept;
};

enum class HttpErrorKind : std::uint8_t {
    none,
    canceled,
    timeout,
    too_large,
    transport,
    invalid_request,
};

struct HttpResponse {
    HttpErrorKind error{HttpErrorKind::none};
    int status_code{};
    std::string body{};
    std::uint32_t system_error{};          // WinHTTP / Win32 错误码，仅供诊断
};

// cancel 可为空；实现应在取消后尽快返回 HttpErrorKind::canceled。
using HttpTransport = std::function<HttpResponse(const HttpRequest&, const std::atomic<bool>* cancel)>;

// WinHTTP 同步实现：禁止重定向和 Cookie，总时限由 watchdog 线程强制（关闭请求句柄）。
[[nodiscard]] HttpResponse winhttp_send(const HttpRequest& request, const std::atomic<bool>* cancel);

void secure_wipe(std::string& value) noexcept;
void secure_wipe(std::wstring& value) noexcept;

} // namespace wirex::app
