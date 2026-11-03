#pragma once

// BrandMeister API v2 静态组管理（对齐 ui/windows/BmManagement.psm1）。
// 所有调用都是同步阻塞的，由调用方放到 worker 线程执行。
// API key 只存在于 ApiKey 对象与单次请求的 Authorization header 中，用完即擦除；
// 不进入任何错误消息、结果结构或日志。

#include "wirex/app/http_client.hpp"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::app::bm_api {

inline constexpr std::string_view api_origin = "https://api.brandmeister.network";
inline constexpr std::string_view api_prefix = "/v2/device/";
inline constexpr std::size_t max_response_bytes = 1048576U;
inline constexpr std::uint32_t default_timeout_ms = 3000U;
inline constexpr std::uint32_t max_timeout_ms = 10000U;
inline constexpr std::uint32_t max_device_id = 4294967295U;
inline constexpr std::uint32_t max_talkgroup = 16777215U;

enum class ErrorKind : std::uint8_t {
    none,
    canceled,          // 调用方取消（PS: OperationCanceledException）
    timeout,           // 超过时限（PS: TimeoutException）
    http_status,       // 非 2xx；http_status 字段给出状态码
    transport,         // 网络/TLS/连接失败，写操作结果未知
    too_large,         // 响应超过 1 MiB
    invalid_response,  // 正文不是预期 JSON 结构
    invalid_request,   // 设备 ID / TG / slot / 超时参数无效（未发出请求）
    invalid_key,       // API key 缺失、格式无效或来源不唯一（未发出请求）
};

[[nodiscard]] std::string_view to_string(ErrorKind kind) noexcept;

struct Error {
    ErrorKind kind{ErrorKind::none};
    int http_status{};
    std::string message{};             // 中文、固定文案，绝不包含 key 或响应正文
    [[nodiscard]] explicit operator bool() const noexcept { return kind != ErrorKind::none; }
};

// 持有 key 的不可复制对象；析构时 SecureZeroMemory。
class ApiKey final {
public:
    ApiKey() = default;
    ~ApiKey();
    ApiKey(ApiKey&& other) noexcept;
    ApiKey& operator=(ApiKey&& other) noexcept;
    ApiKey(const ApiKey&) = delete;
    ApiKey& operator=(const ApiKey&) = delete;

    // 直接 key：trim 后长度 >= 200 且形如 base64url.base64url.base64url。
    [[nodiscard]] static std::optional<ApiKey> from_text(std::string_view text, Error* error = nullptr);
    // 兼容旧 key 文件（必须绝对路径）；支持 Pi-Star 风格 `apikey=...` 行。
    [[nodiscard]] static std::optional<ApiKey> from_file(const std::filesystem::path& path, Error* error = nullptr);

    [[nodiscard]] bool empty() const noexcept { return value_.empty(); }
    [[nodiscard]] std::size_t size() const noexcept { return value_.size(); }

private:
    friend HttpRequest build_request(std::string_view, std::uint32_t, std::string_view, std::string_view,
                                     const ApiKey&, std::uint32_t);
    std::string value_{};
};

// key 格式校验（纯函数）。
[[nodiscard]] bool is_valid_key_format(std::string_view candidate) noexcept;
// 从 key 文件内容中取出 key（trim + 可选 `apikey=` 行）；不校验格式。
[[nodiscard]] std::string extract_key_from_file_content(std::string_view content);

// 设备 ID：1..10 位十进制、1..4294967295（拒绝路径注入）。
[[nodiscard]] std::optional<std::uint32_t> parse_device_id(std::string_view text) noexcept;

// 纯函数：构造请求。method ∈ GET/POST/DELETE；resource ∈ "" (device) / "talkgroup"；
// suffix 只允许 DELETE talkgroup 的 "/{slot}/{tg}"。参数非法时返回 method 为空的请求。
[[nodiscard]] HttpRequest build_request(std::string_view method, std::uint32_t device_id,
                                        std::string_view resource, std::string_view suffix,
                                        const ApiKey& key, std::uint32_t timeout_ms);
[[nodiscard]] std::string build_add_body(std::uint32_t talkgroup, int slot);

// API slot：0（DMO/simplex）、1、2；与 DMRD 时隙不同。
struct StaticGroup {
    std::uint32_t device_id{};
    std::uint32_t talkgroup{};
    int slot{};
};

// 纯函数：解析 GET /talkgroup 数组（talkgroup 1..16777215，slot 0..2，禁止重复）。
// 接受数字或十进制字符串（PS 版对二者同样处理）。
[[nodiscard]] bool parse_static_group_list(std::string_view json, std::uint32_t device_id,
                                           std::vector<StaticGroup>& groups, Error* error = nullptr);

struct AddContext {
    bool success{};
    std::optional<std::int64_t> status{};  // BM device status；仅数值时保留
    std::optional<int> add_slot{};          // status 4 → 0，0..3 → 2
};

// 纯函数：解析 GET /device/{id}。解析失败或 ID 不符 → success=false。
// 注意：strict_json 不支持负数、小数、指数；含这类字段的设备响应会被判为 success=false。
[[nodiscard]] AddContext parse_add_context(std::string_view json, std::uint32_t device_id);

// 分类：把 transport 结果映射为 Error（纯函数，便于测试）。
[[nodiscard]] Error classify(const HttpResponse& response);

enum class ReadbackStatus : std::uint8_t { confirmed, not_confirmed, unavailable, canceled };
[[nodiscard]] std::string_view to_string(ReadbackStatus status) noexcept;

struct ListResult {
    Error error{};
    std::vector<StaticGroup> groups{};
};

struct AddContextResult {
    Error error{};
    AddContext context{};
};

struct WriteResult {
    Error error{};                       // 写请求本身失败时非空；此时没有回读、没有重试
    bool write_accepted{};
    ReadbackStatus readback_status{ReadbackStatus::unavailable};
    std::string readback_error{};        // "" / "timeout" / "canceled" / "unavailable"
    std::vector<StaticGroup> groups{};
};

class Client final {
public:
    // transport 为空时使用 WinHTTP。
    explicit Client(HttpTransport transport = {});

    [[nodiscard]] ListResult list_static_groups(const ApiKey& key, std::string_view device_id,
                                                std::uint32_t timeout_ms = default_timeout_ms,
                                                const std::atomic<bool>* cancel = nullptr) const;
    [[nodiscard]] AddContextResult get_add_context(const ApiKey& key, std::string_view device_id,
                                                   std::uint32_t timeout_ms = default_timeout_ms,
                                                   const std::atomic<bool>* cancel = nullptr) const;
    // POST 后 GET 回读；POST 失败直接返回 error，不回读、不重试。
    [[nodiscard]] WriteResult add_static_group(const ApiKey& key, std::string_view device_id,
                                               std::uint32_t talkgroup, int slot,
                                               std::uint32_t timeout_ms = default_timeout_ms,
                                               const std::atomic<bool>* cancel = nullptr) const;
    // DELETE /talkgroup/{slot}/{tg} 后 GET 回读。
    [[nodiscard]] WriteResult remove_static_group(const ApiKey& key, std::string_view device_id,
                                                  std::uint32_t talkgroup, int slot,
                                                  std::uint32_t timeout_ms = default_timeout_ms,
                                                  const std::atomic<bool>* cancel = nullptr) const;

private:
    [[nodiscard]] Error send(HttpRequest& request, const std::atomic<bool>* cancel, HttpResponse& response) const;
    [[nodiscard]] WriteResult write(const char* method, const ApiKey& key, std::string_view device_id,
                                    std::uint32_t talkgroup, int slot, std::uint32_t timeout_ms,
                                    const std::atomic<bool>* cancel, bool expected_present) const;
    HttpTransport transport_;
};

} // namespace wirex::app::bm_api
