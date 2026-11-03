#pragma once

// 内置 BM Master 离线目录（照搬 ui/windows/BmServers.psm1）。

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace wirex::app::bm_servers {

inline constexpr std::string_view catalog_source_url = "https://www.pistar.uk/downloads/DMR_Hosts.txt";
inline constexpr std::string_view catalog_hostfile_updated = "2026-10-28";
inline constexpr std::string_view catalog_checked = "2026-10-30";
inline constexpr std::string_view default_selection_id = "bm-china-4602";
inline constexpr std::string_view custom_selection_id = "custom";
inline constexpr std::string_view custom_label = "自定义服务器";

struct ServerEntry {
    std::string_view selection_id;
    std::string_view label;
    std::uint32_t master_id;
    std::string_view region;
    std::string_view hostname;
    std::uint16_t port;
    std::array<std::string_view, 2> address_aliases;   // 空字符串表示无
};

// 4602 的 IPv4 作为别名保留，使旧本地配置仍能被识别。
inline constexpr std::array<ServerEntry, 5> catalog{{
    {"bm-china-4602", "BM China · 4602", 4602U, "China", "4602.master.brandmeister.network", 62031U,
     {"43.129.83.124", ""}},
    {"bm-south-korea-4501", "BM South Korea · 4501", 4501U, "South Korea", "4501.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-malaysia-5021", "BM Malaysia · 5021", 5021U, "Malaysia", "5021.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-us-3102", "BM United States · 3102", 3102U, "United States", "3102.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-greece-2022", "BM Greece · 2022", 2022U, "Greece", "2022.master.brandmeister.network", 62031U,
     {"", ""}},
}};

[[nodiscard]] const ServerEntry* find_entry(std::string_view selection_id) noexcept;   // 区分大小写
[[nodiscard]] bool address_matches(const ServerEntry& entry, std::string_view address) noexcept;  // ASCII 大小写不敏感

enum class SelectionSource : std::uint8_t { custom, preference, profile, default_entry };
[[nodiscard]] std::string_view to_string(SelectionSource source) noexcept;

struct Selection {
    std::string selection_id{};
    std::string label{};
    SelectionSource source{SelectionSource::custom};
    bool is_custom{true};
    bool profile_matches_selection{};
    std::string profile_address{};
    std::uint16_t profile_port{};
    std::string effective_address{};
    std::uint16_t effective_port{};
    const ServerEntry* entry{};
};

// 对应 Resolve-BmServerSelection：偏好 → 配置地址匹配 → 空配置用默认 4602。
[[nodiscard]] Selection resolve_selection(std::string_view selection_id, std::string_view actual_address,
                                          std::uint16_t port) noexcept;

struct SelectionValues {
    std::string master{};
    std::uint16_t master_port{};
    std::string selection_id{};
};

// 对应 New-BmServerSelectionValues；参数无效时返回 nullopt 并写中文原因。
[[nodiscard]] std::optional<SelectionValues> new_selection_values(std::string_view selection_id,
                                                                  std::string_view actual_address,
                                                                  std::uint16_t port,
                                                                  std::string* error = nullptr);

} // namespace wirex::app::bm_servers
