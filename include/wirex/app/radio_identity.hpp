#pragma once

// radioid.net DMR ID → 呼号查询与本地缓存（对齐 ui/windows/RadioIdentity.psm1）。
// 缓存文件 radio-identity-cache.json 与 PS 版格式兼容，可共用同一个文件。
// 查询为同步阻塞调用，由调用方放到 worker 线程执行。

#include "wirex/app/http_client.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::app::radio_identity {

using Clock = std::chrono::system_clock;
using TimePoint = Clock::time_point;

inline constexpr std::string_view source_name = "RadioID.net";
inline constexpr std::string_view user_agent = "WIREX Bridge/0.1 (contact: https://github.com/iCassius)";
inline constexpr std::string_view official_base_uri = "https://radioid.net/api/dmr/user/";
inline constexpr std::string_view cache_file_name = "radio-identity-cache.json";
inline constexpr std::uint32_t max_radio_id = 16777215U;
inline constexpr std::size_t max_response_bytes = 262144U;   // PS 上限；strict_json 实际只解析 ≤64 KiB
inline constexpr std::uintmax_t max_cache_file_bytes = 1048576U;
inline constexpr std::size_t cache_entry_limit = 128U;
inline constexpr std::chrono::hours positive_ttl{24 * 30};
inline constexpr std::chrono::hours negative_ttl{24};
inline constexpr std::chrono::minutes future_tolerance{5};
inline constexpr std::size_t max_text_units = 128U;

enum class Status : std::uint8_t { found, not_found, stale, unavailable };
[[nodiscard]] std::string_view to_string(Status status) noexcept;
[[nodiscard]] std::optional<Status> parse_status(std::string_view text) noexcept;

// 缓存条目：字段名与 PS 版一致（id, callsign, name, city, state, country, source, fetched_at_utc, status）。
struct CacheEntry {
    std::uint32_t id{};
    std::optional<std::string> callsign{};
    std::optional<std::string> name{};
    std::optional<std::string> city{};
    std::optional<std::string> state{};
    std::optional<std::string> country{};
    std::optional<std::string> source{};
    std::optional<std::string> fetched_at_utc{};
    std::string status{};                  // 原样保留；只有 found/not_found 被视为有效
};

struct Result {
    std::uint32_t id{};
    std::optional<std::string> callsign{};
    std::optional<std::string> name{};
    std::optional<std::string> city{};
    std::optional<std::string> state{};
    std::optional<std::string> country{};
    std::optional<std::string> source{};
    std::optional<std::string> fetched_at_utc{};
    Status status{Status::unavailable};
    std::string display_name{};
    bool cache_saved{true};
    std::optional<std::string> error_code{};    // cancelled/timeout/http_NNN/network/invalid_response/request_failed/cache_write
    std::optional<std::string> error_message{};
    std::optional<std::string> error_type{};
    std::optional<std::string> error_detail{};
};

// ---------- 纯函数 ----------

[[nodiscard]] bool is_valid_radio_id(std::uint32_t id) noexcept;
[[nodiscard]] std::filesystem::path cache_path(const std::filesystem::path& user_config_directory);

// ConvertTo-RadioIdentityText：去 C0/DEL 控制字符、trim、截断到 128 个 UTF-16 单元；空 → nullopt。
[[nodiscard]] std::optional<std::string> sanitize_text(std::string_view value);
// ConvertTo-RadioIdentityNativeCallsign：trim，1..10 字节 [A-Za-z0-9/-] 且含字母，转大写；
// 结果同时满足 wirex::radio_identity_cache::Cache::is_valid_callsign。
[[nodiscard]] std::optional<std::string> native_callsign(std::string_view value);

// ISO-8601（DateTimeOffset "o" 及常见变体；无时区按 UTC）。
[[nodiscard]] std::optional<TimePoint> parse_timestamp(std::string_view text) noexcept;
// 输出与 .NET "o" 相同的格式：yyyy-MM-ddTHH:mm:ss.fffffff+00:00。
[[nodiscard]] std::string format_timestamp(TimePoint time);

[[nodiscard]] std::string build_query_url(std::string_view base_uri, std::uint32_t id);
// 基址只允许官方 HTTPS 或本机回环 HTTP（测试夹具），且不得带 userinfo。
[[nodiscard]] bool is_allowed_base_uri(std::string_view base_uri) noexcept;
[[nodiscard]] bool is_valid_user_agent(std::string_view agent) noexcept;

enum class ParseState : std::uint8_t { found, not_found, mismatch, conflict, invalid };
struct ParsedRecord {
    std::optional<std::string> callsign{};
    std::optional<std::string> name{};
    std::optional<std::string> city{};
    std::optional<std::string> state{};
    std::optional<std::string> country{};
};
struct ParseResult {
    ParseState state{ParseState::invalid};
    ParsedRecord record{};
};
// ConvertFrom-RadioIdentityResponse：数组 / {results:[...]} / 单对象；id 或 radio_id。
[[nodiscard]] ParseResult parse_response(std::string_view body, std::uint32_t requested_id);

[[nodiscard]] bool is_fresh(const CacheEntry& entry, TimePoint now) noexcept;
[[nodiscard]] Result make_result(std::uint32_t id, const CacheEntry* record, Status status);

// ---------- 缓存文件 ----------

// 读取失败、超过 1 MiB、schema 不符时返回空列表（与 PS 一致：缓存损坏不报错）。
[[nodiscard]] std::vector<CacheEntry> read_cache(const std::filesystem::path& path);
[[nodiscard]] bool parse_cache_document(std::string_view json, std::vector<CacheEntry>& entries);
[[nodiscard]] std::string serialize_cache_document(const std::vector<CacheEntry>& entries);
[[nodiscard]] std::optional<CacheEntry> find_cache_entry(const std::filesystem::path& path, std::uint32_t id);
// 新条目置顶、去重、保留 128 条；UTF-8 BOM + 临时文件 + ReplaceFileW/MoveFileExW。失败返回 false 并写原因。
[[nodiscard]] bool save_cache_entry(const std::filesystem::path& path, const CacheEntry& entry,
                                    std::string* error = nullptr);

// Resolve-RadioIdentity：仅查缓存，不联网。
[[nodiscard]] Result resolve(std::uint32_t id, const std::filesystem::path& path, TimePoint now = Clock::now());

struct NativeMapping {
    std::uint32_t source_id{};
    std::string callsign{};
};
// Get-RadioIdentityNativeMappings：新鲜 found 条目、同 ID 只取第一条、呼号需合规。
[[nodiscard]] std::vector<NativeMapping> native_mappings(const std::filesystem::path& path,
                                                         std::size_t limit = cache_entry_limit,
                                                         TimePoint now = Clock::now());

// ---------- 联网查询 ----------

struct QueryOptions {
    std::uint32_t timeout_seconds{5U};          // 1..5
    std::string base_uri{official_base_uri};
    std::string agent{user_agent};
    HttpTransport transport{};                  // 空 → WinHTTP
    const std::atomic<bool>* cancel{};
};

// Invoke-RadioIdentityQuery：查询失败时回退到缓存（stale）或 unavailable；
// 参数非法（ID/超时/UA/基址）时返回 unavailable + error_code "invalid_request"。
[[nodiscard]] Result query(std::uint32_t id, const std::filesystem::path& path, const QueryOptions& options = {});

} // namespace wirex::app::radio_identity
