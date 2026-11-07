#pragma once

// R135 更新检查：版本解析/比较、GitHub releases/latest 正文解析与请求构造。
// 所有网络访问都经注入的 HttpTransport；测试用假 transport，不访问网络。

#include "wirex/app/http_client.hpp"

#include <atomic>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace wirex::app::update {

// semver 版本核心（不含 build metadata）；prerelease 为空表示正式版，例如 "v1.2.3-rc.1"。
struct Version {
    std::uint32_t major{};
    std::uint32_t minor{};
    std::uint32_t patch{};
    std::string prerelease;
};

// 接受可选的 'v'/'V' 前缀、MAJOR.MINOR.PATCH 与可选 "-prerelease"；其余一律拒绝。
[[nodiscard]] std::optional<Version> parse_version(std::string_view text) noexcept;

// semver 优先级：先比较核心；核心相同时正式版高于预发布版，预发布标识按 semver 规则比较。
// 返回 <0、0、>0。
[[nodiscard]] int compare(const Version& a, const Version& b) noexcept;

struct LatestRelease {
    std::string tag;
    std::string html_url;
    bool prerelease{};
    bool draft{};
};

// 解析 GitHub API releases/latest 正文；缺字段、类型不符或 html_url 不属于本项目时返回空。
[[nodiscard]] std::optional<LatestRelease> parse_latest_release(std::string_view json);

inline constexpr std::string_view latest_release_api_url =
    "https://api.github.com/repos/iCassius/WIREX_Bridge/releases/latest";
inline constexpr std::string_view release_page_prefix = "https://github.com/iCassius/WIREX_Bridge/";

// GET releases/latest：Accept、User-Agent、5 s 超时、正文上限 256 KiB。
[[nodiscard]] HttpRequest make_latest_release_request();

// 执行请求并解析正文；传输失败、超时、非 200（含 404 无发布）或正文无效时返回空。
// 默认使用 WinHTTP 实现，必须在 worker 线程调用。
[[nodiscard]] std::optional<LatestRelease> fetch_latest_release(
    const HttpTransport& transport = winhttp_send, const std::atomic<bool>* cancel = nullptr);

} // namespace wirex::app::update
