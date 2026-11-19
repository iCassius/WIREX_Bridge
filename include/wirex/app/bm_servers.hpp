#pragma once

// Offline snapshot of Pi-Star's BrandMeister section, updated and checked 2026-11-19.
// Source: https://www.pistar.uk/downloads/DMR_Hosts.txt

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace wirex::app::bm_servers {

inline constexpr std::string_view catalog_source_url = "https://www.pistar.uk/downloads/DMR_Hosts.txt";
inline constexpr std::string_view catalog_hostfile_updated = "2026-11-19";
inline constexpr std::string_view catalog_checked = "2026-11-19";
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
inline constexpr std::array<ServerEntry, 42> catalog{{
    {"bm-europe-hamnet-2001", "BM Europe HAMNET · 2001", 2001U, "Europe HAMNET", "44.148.230.201", 62031U,
     {"44.148.230.201", ""}},
    {"bm-greece-2022", "BM Greece · 2022", 2022U, "Greece", "2022.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-netherlands-2041", "BM Netherlands · 2041", 2041U, "Netherlands", "2041.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-belgium-2061", "BM Belgium · 2061", 2061U, "Belgium", "2061.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-france-2081", "BM France · 2081", 2081U, "France", "2081.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-france-2082", "BM France · 2082", 2082U, "France", "2082.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-spain-2141", "BM Spain · 2141", 2141U, "Spain", "2141.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-hungary-2162", "BM Hungary · 2162", 2162U, "Hungary", "2162.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-italy-2222", "BM Italy · 2222", 2222U, "Italy", "2222.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-romania-2262", "BM Romania · 2262", 2262U, "Romania", "2262.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-switzerland-2282", "BM Switzerland · 2282", 2282U, "Switzerland", "2282.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-czech-republic-2302", "BM Czech Republic · 2302", 2302U, "Czech Republic", "2302.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-austria-2322", "BM Austria · 2322", 2322U, "Austria", "2322.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-united-kingdom-2341", "BM United Kingdom · 2341", 2341U, "United Kingdom", "2341.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-denmark-2382", "BM Denmark · 2382", 2382U, "Denmark", "2382.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-sweden-2402", "BM Sweden · 2402", 2402U, "Sweden", "2402.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-norway-2421", "BM Norway · 2421", 2421U, "Norway", "2421.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-finland-2441", "BM Finland · 2441", 2441U, "Finland", "2441.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-russia-2502", "BM Russia · 2502", 2502U, "Russia", "2502.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-russia-2503", "BM Russia · 2503", 2503U, "Russia", "2503.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-poland-2602", "BM Poland · 2602", 2602U, "Poland", "2602.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-germany-2621", "BM Germany · 2621", 2621U, "Germany", "2621.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-germany-2622", "BM Germany · 2622", 2622U, "Germany", "2622.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-portugal-2682", "BM Portugal · 2682", 2682U, "Portugal", "2682.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-ireland-2721", "BM Ireland · 2721", 2721U, "Ireland", "2721.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-bulgaria-2841", "BM Bulgaria · 2841", 2841U, "Bulgaria", "2841.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-slovenia-2931", "BM Slovenia · 2931", 2931U, "Slovenia", "2931.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-canada-3021", "BM Canada · 3021", 3021U, "Canada", "3021.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-us-3102", "BM United States · 3102", 3102U, "United States", "3102.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-united-states-3103", "BM United States · 3103", 3103U, "United States", "3103.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-united-states-3104", "BM United States · 3104", 3104U, "United States", "3104.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-mexico-3341", "BM Mexico · 3341", 3341U, "Mexico", "3341.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-israel-4251", "BM Israel · 4251", 4251U, "Israel", "4251.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-south-korea-4501", "BM South Korea · 4501", 4501U, "South Korea", "4501.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-china-4602", "BM China · 4602", 4602U, "China", "4602.master.brandmeister.network", 62031U,
     {"43.129.83.124", ""}},
    {"bm-malaysia-5021", "BM Malaysia · 5021", 5021U, "Malaysia", "5021.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-australia-5051", "BM Australia · 5051", 5051U, "Australia", "5051.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-philippines-5151", "BM Philippines · 5151", 5151U, "Philippines", "5151.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-south-africa-6551", "BM South Africa · 6551", 6551U, "South Africa", "6551.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-brazil-7242", "BM Brazil · 7242", 7242U, "Brazil", "7242.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-chile-7301", "BM Chile · 7301", 7301U, "Chile", "7301.master.brandmeister.network", 62031U,
     {"", ""}},
    {"bm-ukraine-2551", "BM Ukraine · 2551", 2551U, "Ukraine", "23.111.17.39", 62031U,
     {"23.111.17.39", ""}},
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
