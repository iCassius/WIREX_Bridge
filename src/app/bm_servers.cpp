#include "wirex/app/bm_servers.hpp"

namespace wirex::app::bm_servers {
namespace {

bool is_space(char ch) noexcept
{
    return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '\v' || ch == '\f';
}

bool blank(std::string_view text) noexcept
{
    for (const char ch : text) if (!is_space(ch)) return false;
    return true;
}

bool iequals(std::string_view a, std::string_view b) noexcept
{
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0U; i < a.size(); ++i) {
        char x = a[i];
        char y = b[i];
        if (x >= 'A' && x <= 'Z') x = static_cast<char>(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = static_cast<char>(y - 'A' + 'a');
        if (x != y) return false;
    }
    return true;
}

} // namespace

const ServerEntry* find_entry(std::string_view selection_id) noexcept
{
    for (const auto& entry : catalog) {
        if (entry.selection_id == selection_id) return &entry;
    }
    return nullptr;
}

bool address_matches(const ServerEntry& entry, std::string_view address) noexcept
{
    if (iequals(address, entry.hostname)) return true;
    for (const auto alias : entry.address_aliases) {
        if (!alias.empty() && iequals(address, alias)) return true;
    }
    return false;
}

std::string_view to_string(SelectionSource source) noexcept
{
    switch (source) {
    case SelectionSource::custom: return "custom";
    case SelectionSource::preference: return "preference";
    case SelectionSource::profile: return "profile";
    case SelectionSource::default_entry: return "default";
    }
    return "custom";
}

Selection resolve_selection(std::string_view selection_id, std::string_view actual_address, std::uint16_t port) noexcept
{
    Selection result{};
    const ServerEntry* selected = nullptr;
    auto source = SelectionSource::custom;

    if (!blank(selection_id)) {
        if (iequals(selection_id, custom_selection_id)) {
            source = SelectionSource::preference;
        } else {
            selected = find_entry(selection_id);
            if (selected != nullptr) source = SelectionSource::preference;
        }
    }
    if (selected == nullptr && source != SelectionSource::preference && !blank(actual_address) && port > 0U) {
        for (const auto& entry : catalog) {
            if (port == entry.port && address_matches(entry, actual_address)) {
                selected = &entry;
                source = SelectionSource::profile;
                break;
            }
        }
    }
    if (selected == nullptr && source != SelectionSource::preference && blank(actual_address) && port == 0U) {
        selected = find_entry(default_selection_id);
        source = SelectionSource::default_entry;
    }

    try {
        result.selection_id = selected != nullptr ? std::string(selected->selection_id) : std::string(custom_selection_id);
        result.label = selected != nullptr ? std::string(selected->label) : std::string(custom_label);
        result.profile_address.assign(actual_address.data(), actual_address.size());
        if (!blank(actual_address)) result.effective_address.assign(actual_address.data(), actual_address.size());
        else if (selected != nullptr) result.effective_address.assign(selected->hostname.data(), selected->hostname.size());
    } catch (...) {
        // 分配失败时返回空字符串，由调用方视为自定义且无地址。
    }
    result.source = source;
    result.is_custom = selected == nullptr;
    result.profile_port = port;
    result.effective_port = port > 0U ? port : (selected != nullptr ? selected->port : std::uint16_t{0U});
    result.profile_matches_selection = selected != nullptr && !blank(actual_address) && port > 0U &&
        port == selected->port && address_matches(*selected, actual_address);
    result.entry = selected;
    return result;
}

std::optional<SelectionValues> new_selection_values(std::string_view selection_id, std::string_view actual_address,
                                                    std::uint16_t port, std::string* error)
{
    const auto fail = [&](const char* message) -> std::optional<SelectionValues> {
        if (error != nullptr) *error = message;
        return std::nullopt;
    };
    if (selection_id.empty()) return fail("服务器选择不能为空。");

    SelectionValues values{};
    if (iequals(selection_id, custom_selection_id)) {
        if (blank(actual_address)) return fail("自定义服务器地址不能为空。");
        bool has_space = false;
        for (const char ch : actual_address) if (is_space(ch)) has_space = true;
        if (actual_address.size() > 253U || has_space) {
            return fail("自定义服务器地址必须是不含空格且不超过 253 个字符的地址。");
        }
        if (port < 1U) return fail("自定义服务器 UDP 端口必须为 1 到 65535。");
        values.master.assign(actual_address.data(), actual_address.size());
        values.master_port = port;
        values.selection_id = std::string(custom_selection_id);
        return values;
    }

    const auto* entry = find_entry(selection_id);
    if (entry == nullptr) return fail("所选服务器不在离线目录中；请使用自定义服务器或刷新应用目录。");
    // 选择同一个已知 Master 时保留已保存的地址（例如 4602 的 IPv4），否则使用目录主机名。
    const bool same_saved_endpoint = !blank(actual_address) && port == entry->port && address_matches(*entry, actual_address);
    if (same_saved_endpoint) values.master.assign(actual_address.data(), actual_address.size());
    else values.master.assign(entry->hostname.data(), entry->hostname.size());
    values.master_port = entry->port;
    values.selection_id.assign(entry->selection_id.data(), entry->selection_id.size());
    return values;
}

} // namespace wirex::app::bm_servers
