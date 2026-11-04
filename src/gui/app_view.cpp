#include "app_view.hpp"

#include "imgui.h"
#include "imgui_internal.h"
#include "item_id_scope.hpp"

#include "wirex/bm_local_playback.hpp"
#include "wirex/app/bm_servers.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>

namespace wirex::gui {
namespace {

using engine::BmLink;
using engine::Phase;

// ---------------------------------------------------------------- 配色（取自 ui/windows/MainWindow.xaml 与 bridge-ui.ps1）

constexpr ImU32 rgb(std::uint32_t hex) {
    return IM_COL32((hex >> 16) & 0xFFU, (hex >> 8) & 0xFFU, hex & 0xFFU, 0xFFU);
}
ImVec4 vec(std::uint32_t hex) { return ImGui::ColorConvertU32ToFloat4(rgb(hex)); }

namespace color {
constexpr std::uint32_t window = 0x111619;
constexpr std::uint32_t text = 0xEDF3F4;
constexpr std::uint32_t panel = 0x1D2529;
constexpr std::uint32_t inset = 0x151C20;
constexpr std::uint32_t line = 0x46545B;
constexpr std::uint32_t muted = 0xA8B5BB;
constexpr std::uint32_t green = 0x9BE0AE;
constexpr std::uint32_t input_bg = 0x12191C;
constexpr std::uint32_t input_border = 0x64747C;
constexpr std::uint32_t button = 0x2B383E;
constexpr std::uint32_t button_border = 0x718189;
constexpr std::uint32_t button_hover = 0x34474F;
constexpr std::uint32_t button_pressed = 0x26343A;
constexpr std::uint32_t disabled_text = 0x8A969B;
constexpr std::uint32_t popup = 0x182126;
constexpr std::uint32_t selected = 0x28533B;
constexpr std::uint32_t ok_button = 0x28583C;
constexpr std::uint32_t ok_border = 0x64A477;
constexpr std::uint32_t stop_button = 0x69422E;
constexpr std::uint32_t stop_border = 0xA06F4D;
constexpr std::uint32_t history_bg = 0x172024;
constexpr std::uint32_t slider_fill = 0x4C7FF5;
constexpr std::uint32_t slider_rail = 0x56595E;
constexpr std::uint32_t warn = 0xEFC36F;
constexpr std::uint32_t error = 0xF28B82;
constexpr std::uint32_t link = 0x78B8FF;
constexpr std::uint32_t callsign = 0x90EE90; // WPF LightGreen
// 频道卡片（Get-UiChannelCardPresentation）
constexpr std::uint32_t card_tx_active = 0x713237;
constexpr std::uint32_t card_tx_selected = 0x28583C;
constexpr std::uint32_t card_muted = 0x1A2023;
constexpr std::uint32_t call_tx_active = 0x60272D;
constexpr std::uint32_t call_tx_selected = 0x244C35;
constexpr std::uint32_t call_active = 0x17241D;
constexpr std::uint32_t call_border = 0x35434A;
constexpr std::uint32_t empty_border = 0x303B40;
} // namespace color

enum class Tone { normal, ok, stop };

// ---------------------------------------------------------------- 小部件

std::string fmt(const char* format, ...) {
    char buffer[512];
    va_list args;
    va_start(args, format);
    const int n = std::vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    if (n < 0) return {};
    return std::string(buffer, static_cast<std::size_t>(std::min<int>(n, static_cast<int>(sizeof(buffer)) - 1)));
}

int string_resize(ImGuiInputTextCallbackData* data) {
    if (data->EventFlag == ImGuiInputTextFlags_CallbackResize) {
        auto* s = static_cast<std::string*>(data->UserData);
        s->resize(static_cast<std::size_t>(data->BufTextLen));
        data->Buf = s->data();
    }
    return 0;
}

bool input_text(const char* id, std::string& s, ImGuiInputTextFlags flags = 0) {
    return ImGui::InputText(id, s.data(), s.capacity() + 1U, flags | ImGuiInputTextFlags_CallbackResize, string_resize, &s);
}

bool button(const char* label, ImVec2 size, Tone tone = Tone::normal, bool enabled = true) {
    int colors = 0;
    if (tone == Tone::ok) {
        ImGui::PushStyleColor(ImGuiCol_Button, vec(color::ok_button));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, vec(0x2F6A48));
        ImGui::PushStyleColor(ImGuiCol_Border, vec(color::ok_border));
        colors = 3;
    } else if (tone == Tone::stop) {
        ImGui::PushStyleColor(ImGuiCol_Button, vec(color::stop_button));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, vec(0x7D5037));
        ImGui::PushStyleColor(ImGuiCol_Border, vec(color::stop_border));
        colors = 3;
    }
    ImGui::BeginDisabled(!enabled);
    const bool clicked = ImGui::Button(label, size);
    ImGui::EndDisabled();
    ImGui::PopStyleColor(colors);
    return clicked && enabled;
}

void caption(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
    ImGui::PushFont(nullptr, 12.0F);
    ImGui::TextUnformatted(text);
    ImGui::PopFont();
    ImGui::PopStyleColor();
}

// 单行文本，超宽时以省略号截断。
void text_ellipsis(const char* text, float width, ImU32 col) {
    const ImVec2 pos = ImGui::GetCursorScreenPos();
    const float h = ImGui::GetTextLineHeight();
    ImGui::PushStyleColor(ImGuiCol_Text, col);
    ImGui::RenderTextEllipsis(ImGui::GetWindowDrawList(), pos, ImVec2(pos.x + width, pos.y + h), pos.x + width, text,
                              nullptr, nullptr);
    ImGui::PopStyleColor();
    ImGui::Dummy(ImVec2(width, h));
}

void section_title(const char* text, ImFont* bold) {
    ImGui::PushFont(bold, 14.0F);
    ImGui::TextUnformatted(text);
    ImGui::PopFont();
}

std::string known_name_for_static(std::uint32_t tg) {
    services::ChannelEntry e;
    e.id = tg;
    e.kind = dmr_call::CallKind::group;
    return channel_display_name(e);
}

const char* bm_short_text(BmLink link) {
    if (link == BmLink::resolving) return tr(Str::bm_connecting);
    return bm_link_text(link);
}

const char* phase_short_text(Phase phase) {
    switch (phase) {
    case Phase::stopped: return tr(Str::phase_short_stopped);
    case Phase::starting: return tr(Str::phase_short_starting);
    case Phase::running: return tr(Str::phase_short_running);
    case Phase::stopping: return tr(Str::phase_short_stopping);
    case Phase::failed: return tr(Str::phase_short_failed);
    }
    return tr(Str::phase_short_stopped);
}

const char* device_state_text(services::DeviceResolutionState state) {
    switch (state) {
    case services::DeviceResolutionState::resolved: return tr(Str::device_resolved);
    case services::DeviceResolutionState::ambiguous: return tr(Str::device_ambiguous);
    case services::DeviceResolutionState::missing: return tr(Str::device_missing);
    case services::DeviceResolutionState::conflict: return tr(Str::device_conflict);
    case services::DeviceResolutionState::unavailable: return tr(Str::device_unavailable);
    case services::DeviceResolutionState::manual_unclassified: return tr(Str::device_manual_unclassified);
    case services::DeviceResolutionState::active_not_enumerated: return tr(Str::device_active_missing);
    }
    return tr(Str::device_unavailable);
}

const char* local_playback_state_text(wirex::bm_local_playback::AudioState state) {
    using wirex::bm_local_playback::AudioState;
    switch (state) {
    case AudioState::inactive: return tr(Str::local_playback_inactive);
    case AudioState::ready: return tr(Str::local_playback_ready);
    case AudioState::playing: return tr(Str::local_playback_playing);
    case AudioState::unavailable: return tr(Str::local_playback_unavailable);
    case AudioState::failed: return tr(Str::local_playback_failed);
    }
    return tr(Str::local_playback_inactive);
}

const char* local_playback_route_text(wirex::bm_local_playback::Route route) {
    using wirex::bm_local_playback::Route;
    switch (route) {
    case Route::inactive: return tr(Str::local_playback_inactive);
    case Route::radio: return tr(Str::local_playback_route_radio);
    case Route::local_output: return tr(Str::local_playback_route_output);
    case Route::silent: return tr(Str::local_playback_route_silent);
    }
    return tr(Str::local_playback_inactive);
}

const char* local_playback_error_text(wirex::bm_local_playback::OutputError error) {
    using wirex::bm_local_playback::OutputError;
    switch (error) {
    case OutputError::none: return "";
    case OutputError::selection_unavailable: return tr(Str::local_playback_error_selection);
    case OutputError::open_failed: return tr(Str::local_playback_error_open);
    case OutputError::submit_failed: return tr(Str::local_playback_error_submit);
    case OutputError::device_lost: return tr(Str::local_playback_error_lost);
    case OutputError::close_failed: return tr(Str::local_playback_error_close);
    }
    return tr(Str::local_playback_error_open);
}

std::uint32_t local_playback_color(wirex::bm_local_playback::AudioState state) {
    using wirex::bm_local_playback::AudioState;
    switch (state) {
    case AudioState::ready: return color::green;
    case AudioState::playing: return color::green;
    case AudioState::unavailable: return color::warn;
    case AudioState::failed: return color::error;
    case AudioState::inactive: return color::muted;
    }
    return color::muted;
}

std::string friendly_error_detail(Str source, const std::string& detail) {
    struct Mapping {
        Str source;
        std::string_view token;
        Str message;
    };
    static constexpr Mapping mappings[] = {
        {Str::radio_control, "hri_port_missing", Str::err_radio_selection},
        {Str::radio_control, "radio_selection_unresolved", Str::err_radio_selection},
        {Str::radio_control, "y_template_invalid", Str::err_radio_template},
        {Str::radio_control, "serial_open_or_configure_failed", Str::err_radio_serial},
        {Str::radio_control, "radio_state_allocation_failed", Str::err_radio_resources},
        {Str::radio_control, "hri_version_timeout", Str::err_hri_version_timeout},
        {Str::radio_control, "hri_version_mismatch", Str::err_hri_version_mismatch},
        {Str::radio_control, "hri_malformed_record", Str::err_hri_malformed_record},
        {Str::radio_control, "hri_y_ack_timeout", Str::err_hri_y_ack_timeout},
        {Str::brandmeister, "password_required", Str::err_bm_password},
        {Str::brandmeister, "profile_invalid", Str::err_bm_profile},
        {Str::brandmeister, "master_resolution_failed", Str::err_bm_dns},
        {Str::brandmeister, "master_resolution_timeout", Str::err_bm_dns_timeout},
        {Str::brandmeister, "resolver_cancel_timeout", Str::err_bm_cancel_timeout},
        {Str::brandmeister, "transport_open_failed", Str::err_bm_transport},
        {Str::brandmeister, "media_cleanup_timeout", Str::err_bm_cleanup},
        {Str::brandmeister, "master_rejected", Str::err_bm_rejected},
        {Str::brandmeister, "session_failed", Str::err_bm_session},
        {Str::dynamic_group, "quick_call_partial_send", Str::err_quick_call_partial},
    };
    for (const auto& mapping : mappings) {
        if (source == mapping.source && detail.find(mapping.token) != std::string::npos) return tr(mapping.message);
    }
    return detail;
}

bool contains_radio_error_hint(const std::string& detail) {
    constexpr std::string_view hints[] = {"HRI", "电台", "串口", "USB Audio", "WaveIn", "WaveOut",
                                          "hri_port", "radio_selection", "serial_open_or_configure"};
    for (const auto hint : hints) {
        if (detail.find(hint) != std::string::npos) return true;
    }
    return false;
}

Str operation_log_source(Str operation, const std::string& message) {
    switch (operation) {
    case Str::op_bm:
        return Str::brandmeister;
    case Str::op_start:
    case Str::op_stop:
        return Str::radio_control;
    case Str::op_cat:
        return Str::status_cat;
    case Str::op_audio_devices:
    case Str::op_gains:
        return Str::audio_devices;
    case Str::op_quick_call:
    case Str::op_auto_quick_call:
    case Str::op_rx_policy:
    case Str::op_tx_policy:
        return Str::dynamic_group;
    case Str::save_settings:
        return Str::save_settings;
    case Str::bm_static_groups:
        return Str::brandmeister;
    default:
        break;
    }
    const Str operations[] = {Str::op_bm, Str::op_start, Str::op_stop, Str::op_cat,
                              Str::op_audio_devices, Str::op_quick_call, Str::op_auto_quick_call};
    const Str sources[] = {Str::brandmeister, Str::radio_control, Str::radio_control,
                           Str::status_cat, Str::audio_devices, Str::dynamic_group, Str::dynamic_group};
    for (std::size_t i = 0; i < 7U; ++i) {
        const std::string prefix = fmt("%s:", tr(operations[i]));
        const std::string full_width_prefix = fmt("%s：", tr(operations[i]));
        if (message.rfind(prefix, 0U) == 0U || message.rfind(full_width_prefix, 0U) == 0U) {
            return sources[i];
        }
    }
    const std::string settings_prefix = fmt(tr(Str::settings_save_failed), "");
    if (message.rfind(settings_prefix, 0U) == 0U) return Str::save_settings;
    if (contains_radio_error_hint(message)) return Str::radio_control;
    if (message.find("CAT") != std::string::npos || message.find("cat_") != std::string::npos) {
        return Str::status_cat;
    }
    if (message.find("BM") != std::string::npos || message.find("bm_") != std::string::npos) {
        return Str::brandmeister;
    }
    if (message.find("音频") != std::string::npos || message.find("audio") != std::string::npos ||
        message.find("WaveIn") != std::string::npos || message.find("WaveOut") != std::string::npos) {
        return Str::audio_devices;
    }
    return Str::core;
}

std::string device_selection_text(const services::ResolvedDeviceSelection& selection, bool include_id) {
    const std::string requested = selection.requested_id.empty() ? tr(Str::auto_select)
                                                                  : to_utf8(selection.requested_id);
    const std::string id = to_utf8(selection.resolved_id);
    std::string target = selection.name;
    if (include_id && !id.empty()) {
        std::string upper_id = id;
        std::string upper_target = target;
        std::transform(upper_id.begin(), upper_id.end(), upper_id.begin(),
                       [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
        std::transform(upper_target.begin(), upper_target.end(), upper_target.begin(),
                       [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
        if (upper_target.rfind(upper_id, 0U) != 0U) {
            target = target.empty() ? id : fmt("%s · %s", id.c_str(), target.c_str());
        }
    }
    if (target.empty()) target = id.empty() ? "—" : id;

    if (selection.state == services::DeviceResolutionState::resolved) {
        const std::string selected = selection.requested_id.empty() ? tr(Str::auto_select) : requested;
        if (selection.active) {
            if (selection.requested_id.empty()) {
                return fmt("%s · %s (%s)", selected.c_str(), target.c_str(), tr(Str::device_active));
            }
            return fmt("%s (%s)", target.c_str(), tr(Str::device_active));
        }
        if (selection.requested_id.empty()) return fmt("%s · %s", selected.c_str(), target.c_str());
        return target;
    }
    if (target != "—") {
        if (!id.empty() && id == to_utf8(selection.requested_id)) {
            return fmt("%s · %s", target.c_str(), device_state_text(selection.state));
        }
        return fmt("%s · %s · %s", requested.c_str(), target.c_str(), device_state_text(selection.state));
    }
    return fmt("%s · %s", requested.c_str(), device_state_text(selection.state));
}

// 只保留 A-Z0-9/ 的呼号，用于构造资料页链接。
std::string safe_callsign(const std::string& raw) {
    std::string out;
    for (char c : raw) {
        const auto u = static_cast<unsigned char>(c);
        if (std::isalnum(u) != 0 || c == '/') out.push_back(static_cast<char>(std::toupper(u)));
    }
    return out.size() >= 3U && out.size() <= 16U ? out : std::string{};
}

bool is_auto_selection(const std::wstring& value) {
    std::string normalized = to_utf8(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return normalized.empty() || normalized == "AUTO";
}

std::string uppercase_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return value;
}

void center_item_in_row(float row_height, float item_height) {
    const float top = ImGui::GetCursorPosY();
    ImGui::SetCursorPosY(std::round(top + (row_height - item_height) * 0.5F));
}

// 可编辑下拉：左侧输入框 + 右侧箭头下拉列表。返回选中的下拉项索引。
int editable_combo(const char* id, std::string& text, const std::vector<std::string>& items, float width) {
    int picked = -1;
    const float arrow = ImGui::GetFrameHeight();
    ImGui::PushID(id);
    ImGui::SetNextItemWidth(width - arrow);
    input_text("##text", text);
    ImGui::SameLine(0.0F, 0.0F);
    ImGui::SetNextWindowSizeConstraints(ImVec2(width, 0.0F), ImVec2(FLT_MAX, FLT_MAX));
    if (ImGui::BeginCombo("##list", nullptr, ImGuiComboFlags_NoPreview | ImGuiComboFlags_PopupAlignLeft)) {
        for (std::size_t i = 0; i < items.size(); ++i) {
            // Distinct choices can have the same visible name; the index is stable for this fixed preset list.
            detail::ItemIdScope item_id(nullptr, static_cast<int>(i));
            if (ImGui::Selectable(items[i].c_str(), items[i] == text)) picked = static_cast<int>(i);
        }
        ImGui::EndCombo();
    }
    ImGui::PopID();
    return picked;
}

// 一行“标题在上、控件在下”的字段组，对应 WPF 的 Grid 行：同一行各列的标题和控件严格对齐。
// fixed > 0 为固定宽度（逻辑像素，已乘 DPI），否则按 weight 分配剩余宽度。
struct FieldColumn {
    const char* caption;
    float weight;
    float fixed;
};

bool begin_fields(const char* id, std::initializer_list<FieldColumn> columns) {
    if (!ImGui::BeginTable(id, static_cast<int>(columns.size()), ImGuiTableFlags_SizingStretchProp)) {
        return false;
    }
    for (const auto& c : columns) {
        ImGui::TableSetupColumn("", c.fixed > 0.0F ? ImGuiTableColumnFlags_WidthFixed : ImGuiTableColumnFlags_WidthStretch,
                                c.fixed > 0.0F ? c.fixed : c.weight);
    }
    ImGui::TableNextRow();
    for (const auto& c : columns) {
        ImGui::TableNextColumn();
        caption(c.caption);
    }
    ImGui::TableNextRow();
    return true;
}

bool simple_combo(const char* id, int& index, const char* const* items, int count, float width,
                  const char* empty_preview = "", const char* const* item_ids = nullptr) {
    bool changed = false;
    ImGui::SetNextItemWidth(width);
    const char* preview = index >= 0 && index < count ? items[index] : empty_preview;
    if (ImGui::BeginCombo(id, preview)) {
        for (int i = 0; i < count; ++i) {
            // Use device identity when supplied; otherwise a fixed option index is unique and stable.
            detail::ItemIdScope item_id(item_ids != nullptr ? item_ids[i] : nullptr, i);
            if (ImGui::Selectable(items[i], i == index)) {
                index = i;
                changed = true;
            }
        }
        ImGui::EndCombo();
    }
    return changed;
}

// 圆角整数增益滑块（对应 WPF AudioGainSliderStyle：灰色轨道 + 蓝色已选段 + 白色圆形滑块）。
// 返回 true 表示用户松开并且数值有变化，此时应提交。
bool gain_slider(const char* id, int& value, float width, float scale) {
    const ImVec2 pos = ImGui::GetCursorScreenPos();
    const float h = ImGui::GetFrameHeight();
    const float rail_h = 16.0F * scale;
    const float y0 = pos.y + (h - rail_h) * 0.5F;
    auto* dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(ImVec2(pos.x, y0), ImVec2(pos.x + width, y0 + rail_h), rgb(color::slider_rail), rail_h * 0.5F);
    // 与 ImGui::SliderBehaviorT 的整数滑块几何一致：grab_padding=2，grab_sz=max(slider_sz/(range+1), GrabMinSize)
    const float grab_padding = 2.0F;
    const float slider_sz = width - grab_padding * 2.0F;
    const float grab_sz = std::max(slider_sz / 16.0F, ImGui::GetStyle().GrabMinSize);
    const float t = static_cast<float>(std::clamp(value, 1, 16) - 1) / 15.0F;
    const float grab_center = pos.x + grab_padding + grab_sz * 0.5F + t * (slider_sz - grab_sz);
    dl->AddRectFilled(ImVec2(pos.x, y0), ImVec2(grab_center, y0 + rail_h), rgb(color::slider_fill), rail_h * 0.5F,
                      ImDrawFlags_RoundCornersLeft);
    for (int i = 0; i < 16; i += 3) {
        const float tx = pos.x + grab_padding + grab_sz * 0.5F + static_cast<float>(i) / 15.0F * (slider_sz - grab_sz);
        if (tx > grab_center + grab_sz * 0.5F) dl->AddCircleFilled(ImVec2(tx, pos.y + h * 0.5F), 2.0F * scale, rgb(0x92959A));
    }

    ImGui::PushStyleColor(ImGuiCol_FrameBg, IM_COL32(0, 0, 0, 0));
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, IM_COL32(255, 255, 255, 12));
    ImGui::PushStyleColor(ImGuiCol_FrameBgActive, IM_COL32(255, 255, 255, 20));
    ImGui::PushStyleColor(ImGuiCol_SliderGrab, vec(0xFFFFFF));
    ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, vec(0xDDE7FF));
    ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(0, 0, 0, 0)); // 数值在标题行显示
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, h * 0.5F);
    ImGui::PushStyleVar(ImGuiStyleVar_GrabRounding, h * 0.5F);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0F);
    ImGui::SetNextItemWidth(width);
    ImGui::SliderInt(id, &value, 1, 16, "%d", ImGuiSliderFlags_AlwaysClamp);
    const bool commit = ImGui::IsItemDeactivatedAfterEdit();
    ImGui::PopStyleVar(3);
    ImGui::PopStyleColor(6);
    return commit;
}

void status_dot(bool on, const char* label) {
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float h = ImGui::GetTextLineHeight();
    ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(p.x + h * 0.3F, p.y + h * 0.5F), h * 0.22F,
                                                on ? rgb(color::green) : rgb(0x5A666C));
    ImGui::Dummy(ImVec2(h * 0.7F, h));
    ImGui::SameLine(0.0F, 2.0F);
    ImGui::PushStyleColor(ImGuiCol_Text, on ? vec(color::text) : vec(color::muted));
    ImGui::TextUnformatted(label);
    ImGui::PopStyleColor();
}

std::string source_label(const engine::CallInfo& call) {
    if (!call.callsign.empty()) return fmt("%s · DMR ID %u", call.callsign.c_str(), call.source_id);
    return fmt("DMR ID %u", call.source_id);
}

std::string call_target_text(const engine::CallInfo& call) {
    if (call.kind == dmr_call::CallKind::group) {
        return fmt(tr(Str::call_target_group), call.destination_id, static_cast<int>(call.slot));
    }
    return fmt(tr(Str::call_target_private), static_cast<int>(call.slot));
}

// 呼号（大号、可点击打开 QRZ）+ DMR ID（可点击打开 BM 资料页）。
void caller_block(const engine::CallInfo& call, ImFont* bold, float big, float small, ImU32 callsign_color) {
    const auto cs = safe_callsign(call.callsign);
    ImGui::PushFont(bold, big);
    if (!cs.empty()) {
        ImGui::PushStyleColor(ImGuiCol_TextLink, callsign_color);
        ImGui::TextLinkOpenURL(cs.c_str(), ("https://www.qrz.com/db/" + cs).c_str());
        ImGui::PopStyleColor();
    } else {
        ImGui::PushStyleColor(ImGuiCol_Text, callsign_color);
        ImGui::Text("DMR ID %u", call.source_id);
        ImGui::PopStyleColor();
    }
    ImGui::PopFont();
    if (!cs.empty()) {
        ImGui::PushFont(nullptr, small);
        const auto id = fmt("DMR ID %u", call.source_id);
        ImGui::PushStyleColor(ImGuiCol_TextLink, vec(color::link));
        ImGui::TextLinkOpenURL(id.c_str(), ("https://brandmeister.network/#/profile/" + cs).c_str());
        ImGui::PopStyleColor();
        ImGui::PopFont();
    }
}

} // namespace

// ---------------------------------------------------------------- 主题

void apply_theme(float dpi_scale) {
    ImGuiStyle& style = ImGui::GetStyle();
    style = ImGuiStyle();
    ImGui::StyleColorsDark(&style);
    style.WindowPadding = ImVec2(12.0F, 12.0F);
    style.FramePadding = ImVec2(7.0F, 5.0F);
    style.ItemSpacing = ImVec2(6.0F, 5.0F);
    style.ItemInnerSpacing = ImVec2(5.0F, 4.0F);
    style.WindowRounding = 0.0F;
    // Qt Fusion 风格：克制的小圆角、明确的控件边界和一致的交互反馈。
    style.ChildRounding = 3.0F;
    style.FrameRounding = 3.0F;
    style.PopupRounding = 3.0F;
    style.GrabRounding = 3.0F;
    style.GrabMinSize = 18.0F;
    style.WindowBorderSize = 0.0F;
    style.ChildBorderSize = 1.0F;
    style.FrameBorderSize = 1.0F;
    style.PopupBorderSize = 1.0F;
    style.ScrollbarSize = 12.0F;
    style.FontSizeBase = 14.0F;

    ImVec4* c = style.Colors;
    c[ImGuiCol_Text] = vec(color::text);
    c[ImGuiCol_TextDisabled] = vec(color::disabled_text);
    c[ImGuiCol_WindowBg] = vec(color::window);
    c[ImGuiCol_ChildBg] = vec(color::panel);
    c[ImGuiCol_PopupBg] = vec(color::popup);
    c[ImGuiCol_Border] = vec(color::line);
    c[ImGuiCol_FrameBg] = vec(color::input_bg);
    c[ImGuiCol_FrameBgHovered] = vec(0x18232A);
    c[ImGuiCol_FrameBgActive] = vec(0x1C2A31);
    c[ImGuiCol_TitleBg] = vec(color::panel);
    c[ImGuiCol_TitleBgActive] = vec(color::panel);
    c[ImGuiCol_Button] = vec(color::button);
    c[ImGuiCol_ButtonHovered] = vec(color::button_hover);
    c[ImGuiCol_ButtonActive] = vec(color::button_pressed);
    c[ImGuiCol_Header] = vec(color::selected);
    c[ImGuiCol_HeaderHovered] = vec(color::button_hover);
    c[ImGuiCol_HeaderActive] = vec(color::selected);
    c[ImGuiCol_CheckMark] = vec(color::green);
    c[ImGuiCol_SliderGrab] = vec(0xFFFFFF);
    c[ImGuiCol_SliderGrabActive] = vec(0xDDE7FF);
    c[ImGuiCol_PlotHistogram] = vec(color::green);
    c[ImGuiCol_TextLink] = vec(color::link);
    c[ImGuiCol_NavCursor] = vec(color::green);
    c[ImGuiCol_ModalWindowDimBg] = ImVec4(0.0F, 0.0F, 0.0F, 0.55F);
    c[ImGuiCol_Separator] = vec(color::line);
    c[ImGuiCol_ScrollbarBg] = vec(color::inset);
    // ImGui 默认无输入框描边颜色区分；FrameBorder 使用 Border 颜色，这里调亮接近 WPF 的 #64747C。
    c[ImGuiCol_BorderShadow] = ImVec4(0.0F, 0.0F, 0.0F, 0.0F);

    style.ScaleAllSizes(dpi_scale);
    // ImGui backend 按物理像素布局。DPI 缩放后的间距和内边距取整，避免 125% 缩放时
    // 文本起点、输入框边线落在半像素上。
    const auto snap = [](float value) { return std::round(value); };
    const auto snap_vec = [&snap](ImVec2& value) {
        value.x = snap(value.x);
        value.y = snap(value.y);
    };
    snap_vec(style.WindowPadding);
    snap_vec(style.FramePadding);
    snap_vec(style.ItemSpacing);
    snap_vec(style.ItemInnerSpacing);
    snap_vec(style.CellPadding);
    snap_vec(style.TouchExtraPadding);
    snap_vec(style.SeparatorTextPadding);
    snap_vec(style.DisplayWindowPadding);
    snap_vec(style.DisplaySafeAreaPadding);
    style.IndentSpacing = snap(style.IndentSpacing);
    style.ColumnsMinSpacing = snap(style.ColumnsMinSpacing);
    style.ScrollbarSize = snap(style.ScrollbarSize);
    style.ScrollbarRounding = snap(style.ScrollbarRounding);
    style.GrabMinSize = snap(style.GrabMinSize);
    style.GrabRounding = snap(style.GrabRounding);
    style.FrameRounding = snap(style.FrameRounding);
    style.ChildRounding = snap(style.ChildRounding);
    style.PopupRounding = snap(style.PopupRounding);
    style.ChildBorderSize = std::max(1.0F, std::round(style.ChildBorderSize));
    style.FrameBorderSize = std::max(1.0F, std::round(style.FrameBorderSize));
    style.FontScaleDpi = dpi_scale;
    // ImGui 的字号是字体实际字高，WPF FontSize 是 em 尺寸；此系数使代码字号接近 XAML 中的数值。
    style.FontScaleMain = 1.3F;
}

// ---------------------------------------------------------------- 视图

AppView::AppView(ViewModel& vm, Fonts fonts) : vm_(vm), fonts_(fonts), draft_(vm.config()) {
    draft_dmr_id_ = draft_.dmr_id == 0U ? std::string{} : std::to_string(draft_.dmr_id);
    draft_master_port_ = std::to_string(draft_.master_port);
}

void AppView::draw(float dpi_scale) {
    scale_ = dpi_scale;
    continuous_ = false;
    const ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->WorkPos);
    ImGui::SetNextWindowSize(vp->WorkSize);
    constexpr ImGuiWindowFlags root_flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                            ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus |
                                            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse;
    ImGui::Begin("##root", nullptr, root_flags);

    const auto snap_to_pixel = [](float value) { return std::round(value); };
    const float gap = snap_to_pixel(px(4.0F));
    update_connection_log();
    draw_header();
    const ImVec2 avail = ImGui::GetContentRegionAvail();
    const float body_h = std::max(0.0F, avail.y - gap);
    // 保持频道卡片完整显示；把设备选择提前放到电台区上方，减少滚动才能调整音频的情况。
    const float cards_h = snap_to_pixel(std::max(px(185.0F), body_h * 0.31F));
    const float calls_h = snap_to_pixel(std::max(px(130.0F), body_h * 0.15F));
    const float panels_h = body_h - cards_h - calls_h - gap * 2.0F;
    const ImVec2 body_origin = ImGui::GetCursorPos();

    draw_channels(cards_h);
    ImGui::SetCursorPos(ImVec2(body_origin.x, body_origin.y + cards_h + gap));
    draw_calls(calls_h);
    ImGui::SetCursorPos(ImVec2(body_origin.x, body_origin.y + cards_h + gap + calls_h + gap));
    const float radio_w = snap_to_pixel((avail.x - gap) * 0.5F);
    const float daily_w = std::max(0.0F, avail.x - gap - radio_w);
    draw_radio_panel(radio_w, panels_h);
    ImGui::SameLine(0.0F, gap);
    draw_daily_panel(daily_w, panels_h);
    ImGuiIO& io = ImGui::GetIO();
    if (ImGui::IsAnyItemActive() || ImGui::IsMouseDown(ImGuiMouseButton_Left) || io.MouseWheel != 0.0F) continuous_ = true;
    ImGui::End();
}

void AppView::draw_header() {
    const auto& s = vm_.snapshot();
    const ConnectionLogEntry* summary = nullptr;
    for (auto it = connection_events_.rbegin(); it != connection_events_.rend(); ++it) {
        if (it->failed && !it->resolved) {
            summary = &*it;
            break;
        }
    }
    if (!summary && !connection_events_.empty()) summary = &connection_events_.back();
    const bool summary_error = summary && summary->failed && !summary->resolved;
    std::string summary_text;
    if (summary) {
        summary_text = fmt("%s · %s", tr(summary->source), summary->message.c_str());
        if (summary->failed && summary->resolved) summary_text += fmt(" · %s", tr(Str::log_resolved));
    }
    const float row_h = px(32.0F);
    if (ImGui::BeginTable("##header", 3, ImGuiTableFlags_SizingStretchProp | ImGuiTableFlags_NoPadOuterX |
                                           ImGuiTableFlags_NoBordersInBody)) {
        ImGui::TableSetupColumn("##title", ImGuiTableColumnFlags_WidthStretch, 1.0F);
        ImGui::TableSetupColumn("##status", ImGuiTableColumnFlags_WidthStretch, 1.1F);
        ImGui::TableSetupColumn("##actions", ImGuiTableColumnFlags_WidthFixed, px(356.0F));
        ImGui::TableNextRow(ImGuiTableRowFlags_None, row_h);

        ImGui::TableSetColumnIndex(0);
        ImGui::PushFont(fonts_.bold, 19.0F);
        center_item_in_row(row_h, ImGui::GetTextLineHeight());
        ImGui::TextUnformatted(tr(Str::app_title));
        ImGui::PopFont();
        if (vm_.fake()) {
            ImGui::SameLine(0.0F, px(8.0F));
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::warn));
            ImGui::Text("[%s]", tr(Str::fake_banner));
            ImGui::PopStyleColor();
        }

        ImGui::TableSetColumnIndex(1);
        center_item_in_row(row_h, ImGui::GetTextLineHeight());
        if (summary) {
            caption(tr(summary_error ? Str::log_error : Str::log_events));
            ImGui::SameLine(0.0F, px(6.0F));
            ImGui::PushStyleColor(ImGuiCol_Text, vec(summary_error ? color::error : color::muted));
            const float available = std::max(px(24.0F), ImGui::GetContentRegionAvail().x - px(28.0F));
            text_ellipsis(summary_text.c_str(), available, rgb(summary_error ? color::error : color::muted));
            ImGui::SetItemTooltip("%s", summary_text.c_str());
            ImGui::PopStyleColor();
            ImGui::SameLine(0.0F, px(3.0F));
            if (summary_error && button("×##clear-error", ImVec2(px(20.0F), px(22.0F)))) {
                connection_events_.clear();
            }
            if (summary_error) ImGui::SetItemTooltip("%s", tr(Str::log_clear));
        } else {
            const float status_w = px(390.0F);
            const float status_x = ImGui::GetCursorPosX() + std::max(0.0F, (ImGui::GetContentRegionAvail().x - status_w) * 0.5F);
            ImGui::SetCursorPosX(status_x);
            caption(tr(Str::brandmeister));
            ImGui::SameLine(0.0F, px(5.0F));
            ImGui::PushFont(fonts_.bold, 13.0F);
            const bool bm_ok = s.bm_link == BmLink::connected;
            const bool bm_bad = s.bm_link == BmLink::failed || s.bm_link == BmLink::backoff;
            ImGui::PushStyleColor(ImGuiCol_Text, bm_ok ? vec(color::green) : bm_bad ? vec(color::warn) : vec(color::text));
            ImGui::TextUnformatted(bm_short_text(s.bm_link));
            ImGui::PopStyleColor();
            ImGui::PopFont();
            ImGui::SameLine(0.0F, px(12.0F));
            caption(tr(Str::rtt));
            ImGui::SameLine(0.0F, px(5.0F));
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
            ImGui::TextUnformatted(tr(Str::rtt_no_data));
            ImGui::PopStyleColor();
            ImGui::SameLine(0.0F, px(12.0F));
            caption(tr(Str::core));
            ImGui::SameLine(0.0F, px(5.0F));
            ImGui::PushFont(fonts_.bold, 13.0F);
            const bool core_ok = s.phase == Phase::running;
            ImGui::PushStyleColor(ImGuiCol_Text,
                                  core_ok ? vec(color::green) : s.phase == Phase::failed ? vec(color::error) : vec(color::text));
            ImGui::TextUnformatted(phase_short_text(s.phase));
            ImGui::PopStyleColor();
            ImGui::PopFont();
            if (s.phase == Phase::failed && !s.failure_reason.empty()) ImGui::SetItemTooltip("%s", s.failure_reason.c_str());
            else ImGui::SetItemTooltip("%s", phase_text(s));
        }

        ImGui::TableSetColumnIndex(2);
        const float btn_h = px(26.0F);
        const float action_button_y = std::round(ImGui::GetCursorPosY() + (row_h - btn_h) * 0.5F);
        ImGui::SetCursorPosY(action_button_y);
        if (button(language() == Language::zh_cn ? tr(Str::language_english) : tr(Str::language_chinese),
                   ImVec2(px(64.0F), btn_h))) toggle_language();
        if (!language_notice_.empty()) {
            ImGui::SetItemTooltip("%s", language_notice_.c_str());
        } else if (vm_.font_status() == FontStatus::segoe_simhei) {
            ImGui::SetItemTooltip("%s", tr(Str::font_simhei));
        } else if (vm_.font_status() == FontStatus::fallback_default) {
            ImGui::SetItemTooltip("%s", tr(Str::font_default));
        }
        ImGui::SameLine(0.0F, px(5.0F));
        ImGui::SetCursorPosY(action_button_y);
        if (button(tr(Str::relay_enable), ImVec2(px(108.0F), btn_h), Tone::normal, false)) {}
        ImGui::SetItemTooltip("%s", tr(Str::relay_state_unknown));
        ImGui::SameLine(0.0F, px(5.0F));
        ImGui::SetCursorPosY(action_button_y);
        if (button(tr(Str::stop_exit), ImVec2(px(108.0F), btn_h), Tone::stop)) {
            if (vm_.snapshot().phase != Phase::stopped || vm_.cat().connected || vm_.cat().busy) vm_.stop();
            vm_.request_exit();
        }
        ImGui::SameLine(0.0F, px(5.0F));
        ImGui::SetCursorPosY(action_button_y);
        const auto log_label = fmt("≡ %zu##connection-log", connection_events_.size());
        if (button(log_label.c_str(), ImVec2(px(48.0F), btn_h), Tone::normal,
                   !connection_events_.empty())) {
            ImGui::OpenPopup("##connection-log");
        }
        ImGui::SetItemTooltip("%s (%zu)", tr(Str::log_events), connection_events_.size());
        ImGui::EndTable();
    }

    draw_connection_log_popup();
    const ImVec2 pos = ImGui::GetCursorPos();
    ImGui::SetCursorPos(ImVec2(pos.x, pos.y + px(4.0F)));
}

void AppView::update_connection_log() {
    const auto& s = vm_.snapshot();
    for (auto& event : vm_.drain_operation_events()) {
        if (event.operation == Str::op_audio_devices && event.failed) audio_operation_failed_ = true;
        const Str source = operation_log_source(event.operation, event.message);
        add_connection_event(source, friendly_error_detail(source, event.message), event.failed);
    }

    if (s.bm_error != last_bm_error_) {
        const bool was_error = !last_bm_error_.empty() && last_bm_error_ != "none";
        last_bm_error_ = s.bm_error;
        if (!s.bm_error.empty() && s.bm_error != "none") {
            const auto detail = friendly_error_detail(Str::brandmeister, s.bm_error);
            add_connection_event(Str::brandmeister, fmt(tr(Str::bm_error_fmt), detail.c_str()), true);
        } else if (was_error) {
            if (s.bm_link == BmLink::connected) {
                resolve_connection_error(Str::brandmeister, tr(Str::bm_connected));
            } else if (s.bm_link == BmLink::disabled) {
                resolve_connection_error(Str::brandmeister, tr(Str::bm_disabled));
            }
        }
    }
    if (s.radio_error != last_radio_error_) {
        const bool was_error = !last_radio_error_.empty();
        last_radio_error_ = s.radio_error;
        if (!s.radio_error.empty()) {
            const auto detail = friendly_error_detail(Str::radio_control, s.radio_error);
            add_connection_event(Str::radio_control, fmt(tr(Str::radio_error_fmt), detail.c_str()), true);
        } else if (was_error) {
            resolve_connection_error(Str::radio_control,
                s.hri_ready ? tr(Str::log_radio_ready)
                : s.serial_open ? tr(Str::log_radio_open) : tr(Str::log_radio_disconnected));
        }
    }
    if (vm_.cat().error != last_cat_error_) {
        const bool was_error = !last_cat_error_.empty();
        last_cat_error_ = vm_.cat().error;
        if (!last_cat_error_.empty()) {
            const auto detail = friendly_error_detail(Str::status_cat, last_cat_error_);
            add_connection_event(Str::status_cat, fmt(tr(Str::cat_error_fmt), detail.c_str()), true);
        } else if (was_error) {
            resolve_connection_error(Str::status_cat,
                vm_.cat().connected ? tr(Str::log_cat_connected) : tr(Str::log_cat_disconnected));
        }
    }
    if (s.failure_reason != last_core_failure_) {
        const bool was_error = !last_core_failure_.empty();
        last_core_failure_ = s.failure_reason;
        if (!s.failure_reason.empty()) {
            const auto detail = friendly_error_detail(Str::core, s.failure_reason);
            add_connection_event(Str::core, fmt(tr(Str::core_error_fmt), detail.c_str()), true);
        } else if (was_error && s.phase == Phase::running) {
            resolve_connection_error(Str::core, tr(Str::log_core_ready));
        }
    }
    if (settings_error_ != last_settings_error_) {
        const bool was_error = !last_settings_error_.empty();
        last_settings_error_ = settings_error_;
        if (!settings_error_.empty()) {
            add_connection_event(Str::save_settings, settings_error_, true);
        } else if (was_error) {
            resolve_connection_error(Str::save_settings, tr(Str::log_settings_saved));
        }
    }

    if (!connection_states_initialized_) {
        connection_states_initialized_ = true;
        last_bm_link_ = s.bm_link;
        last_core_phase_ = s.phase;
        last_serial_open_ = s.serial_open;
        last_hri_ready_ = s.hri_ready;
        last_cat_connected_ = vm_.cat().connected;
        last_bm_connection_revision_ = s.bm_connection_revision;
        last_audio_endpoints_revision_ = s.audio_endpoints_revision;
        last_cat_revision_ = vm_.cat().revision;
        if (s.bm_link == BmLink::connected && (s.bm_error.empty() || s.bm_error == "none")) {
            resolve_connection_error(Str::brandmeister, tr(Str::bm_connected));
        }
        if (s.hri_ready) {
            resolve_connection_error(Str::radio_control, tr(Str::log_radio_ready));
        } else if (s.serial_open) {
            add_connection_event(Str::radio_control, tr(Str::log_radio_open), false);
        }
        if (vm_.cat().connected) resolve_connection_error(Str::status_cat, tr(Str::log_cat_connected));
        if (s.phase == Phase::running) resolve_connection_error(Str::core, tr(Str::log_core_ready));
    } else {
        if (s.bm_link != last_bm_link_) {
            if (s.bm_link == BmLink::connected && (s.bm_error.empty() || s.bm_error == "none")) {
                resolve_connection_error(Str::brandmeister, tr(Str::bm_connected));
            } else if (s.bm_link == BmLink::disabled &&
                       (s.bm_error.empty() || s.bm_error == "none")) {
                resolve_connection_error(Str::brandmeister, tr(Str::bm_disabled));
            } else if (s.bm_link == BmLink::resolving || s.bm_link == BmLink::connecting) {
                add_connection_event(Str::brandmeister, tr(Str::bm_connecting), false);
            } else if (s.bm_link == BmLink::backoff) {
                add_connection_event(Str::brandmeister, tr(Str::bm_backoff), false);
            } else if (s.bm_link == BmLink::failed) {
                add_connection_event(Str::brandmeister, tr(Str::bm_failed), true);
            }
        }
        if (s.serial_open != last_serial_open_) {
            if (s.serial_open && !s.hri_ready) {
                add_connection_event(Str::radio_control, tr(Str::log_radio_open), false);
            } else if (!s.serial_open) {
                resolve_connection_error(Str::radio_control, tr(Str::log_radio_disconnected));
            }
        }
        if (s.hri_ready != last_hri_ready_ && s.hri_ready) {
            resolve_connection_error(Str::radio_control, tr(Str::log_radio_ready));
        }
        if (vm_.cat().connected != last_cat_connected_) {
            resolve_connection_error(Str::status_cat,
                vm_.cat().connected ? tr(Str::log_cat_connected) : tr(Str::log_cat_disconnected));
        }
        if (s.phase != last_core_phase_ && s.phase == Phase::running) {
            resolve_connection_error(Str::core, tr(Str::log_core_ready));
        }
    }

    if (s.bm_connection_revision != last_bm_connection_revision_) {
        last_bm_connection_revision_ = s.bm_connection_revision;
        add_connection_event(Str::brandmeister,
            s.bm_requested_enabled ? tr(Str::log_bm_connect_requested)
                                   : tr(Str::log_bm_disconnect_requested), false);
    }
    if (s.audio_endpoints_revision != last_audio_endpoints_revision_) {
        last_audio_endpoints_revision_ = s.audio_endpoints_revision;
        if (s.local_audio_error.empty() &&
            s.local_audio.output_error == wirex::bm_local_playback::OutputError::none &&
            last_local_audio_error_.empty() &&
            last_local_audio_output_error_ == static_cast<std::uint8_t>(wirex::bm_local_playback::OutputError::none)) {
            resolve_connection_error(Str::audio_devices, tr(Str::log_audio_changed));
        } else {
            add_connection_event(Str::audio_devices, tr(Str::log_audio_changed), false);
        }
    }
    const bool local_audio_detail_changed = s.local_audio_error != last_local_audio_error_;
    if (local_audio_detail_changed) {
        const bool had_error = !last_local_audio_error_.empty();
        last_local_audio_error_ = s.local_audio_error;
        if (!s.local_audio_error.empty()) {
            if (had_error) resolve_connection_error(Str::audio_devices, tr(Str::local_playback_failed));
            const char* localized = local_playback_error_text(s.local_audio.output_error);
            const std::string message = language() == Language::en_us && localized[0] != '\0'
                                            ? localized : s.local_audio_error;
            add_connection_event(Str::audio_devices, message, true);
        } else if (had_error && s.local_audio.output_error == wirex::bm_local_playback::OutputError::none) {
            resolve_connection_error(Str::audio_devices, tr(Str::local_playback_ready));
        }
    }
    const auto output_error_value = static_cast<std::uint8_t>(s.local_audio.output_error);
    if (output_error_value != last_local_audio_output_error_) {
        if (!local_audio_detail_changed && s.local_audio.output_error != wirex::bm_local_playback::OutputError::none) {
            add_connection_event(Str::audio_devices,
                                local_playback_error_text(s.local_audio.output_error), true);
        } else if (!local_audio_detail_changed && s.local_audio.output_error == wirex::bm_local_playback::OutputError::none &&
                   last_local_audio_output_error_ != static_cast<std::uint8_t>(wirex::bm_local_playback::OutputError::none) &&
                   s.local_audio_error.empty()) {
            resolve_connection_error(Str::audio_devices, tr(Str::local_playback_ready));
        }
        last_local_audio_output_error_ = output_error_value;
    }
    if (vm_.cat().revision != last_cat_revision_) last_cat_revision_ = vm_.cat().revision;

    last_bm_link_ = s.bm_link;
    last_core_phase_ = s.phase;
    last_serial_open_ = s.serial_open;
    last_hri_ready_ = s.hri_ready;
    last_cat_connected_ = vm_.cat().connected;
}

void AppView::add_connection_event(Str source, std::string message, bool failed) {
    if (message.empty()) return;
    const auto& config = vm_.config();
    const std::string secrets[] = {config.bm_password, config.bm_api_key,
                                   draft_.bm_password, draft_.bm_api_key};
    for (const auto& secret : secrets) {
        if (secret.empty()) continue;
        std::size_t pos = 0U;
        while ((pos = message.find(secret, pos)) != std::string::npos) {
            message.replace(pos, secret.size(), "[redacted]");
            pos += sizeof("[redacted]") - 1U;
        }
    }
    if (!connection_events_.empty()) {
        const auto& last = connection_events_.back();
        if (last.source == source && last.message == message && last.failed == failed && !last.resolved) return;
    }
    connection_events_.push_back({format_clock(std::chrono::system_clock::now()),
                                  std::move(source), std::move(message), failed, false});
    constexpr std::size_t max_events = 12U;
    while (connection_events_.size() > max_events) connection_events_.pop_front();
}

void AppView::resolve_connection_error(Str source, std::string message) {
    for (auto it = connection_events_.rbegin(); it != connection_events_.rend(); ++it) {
        if (it->source == source && it->failed && !it->resolved) it->resolved = true;
    }
    add_connection_event(source, std::move(message), false);
}

void AppView::draw_connection_log_popup() {
    if (ImGui::IsPopupOpen("##connection-log")) {
        const ImVec2 viewport = ImGui::GetMainViewport()->WorkSize;
        ImGui::SetNextWindowSize(ImVec2(std::min(px(560.0F), viewport.x * 0.9F),
                                        std::min(px(320.0F), viewport.y * 0.75F)), ImGuiCond_Appearing);
    }
    if (!ImGui::BeginPopup("##connection-log")) return;

    section_title(tr(Str::log_events), fonts_.bold);
    ImGui::SameLine();
    if (button(tr(Str::log_clear), ImVec2(px(52.0F), px(22.0F)), Tone::normal,
               !connection_events_.empty())) {
        connection_events_.clear();
    }
    ImGui::Separator();
    if (connection_events_.empty()) {
        ImGui::TextUnformatted(tr(Str::log_empty));
    } else {
        ImGui::BeginChild("##connection-log-items", ImVec2(0.0F, px(245.0F)),
                          ImGuiChildFlags_None, ImGuiWindowFlags_AlwaysVerticalScrollbar);
        for (auto it = connection_events_.rbegin(); it != connection_events_.rend(); ++it) {
            const ImU32 tint = it->failed && !it->resolved ? rgb(color::error)
                               : it->resolved ? rgb(color::muted) : rgb(color::green);
            ImGui::PushStyleColor(ImGuiCol_Text, tint);
            ImGui::Text("%s  %s", it->time.c_str(), tr(it->source));
            ImGui::PopStyleColor();
            const std::string suffix = it->resolved ? fmt(" · %s", tr(Str::log_resolved)) : std::string{};
            ImGui::TextWrapped("%s%s", it->message.c_str(), suffix.c_str());
            ImGui::Spacing();
        }
        ImGui::EndChild();
    }
    ImGui::EndPopup();
}

void AppView::draw_channels(float height) {
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(color::panel));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(6.0F)));
    ImGui::BeginChild("##channels", ImVec2(0.0F, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    const bool paged = vm_.channel_page_count() > 1U;
    const ImVec2 avail = ImGui::GetContentRegionAvail();
    const float gap = px(4.0F);
    const float nav_button_h = paged ? px(19.0F) : 0.0F;
    const float nav_gap = paged ? gap : 0.0F;
    const auto snap_nearest = [](float value) { return std::round(value); };
    const auto snap_down = [](float value) { return std::floor(value); };
    const float card_w = snap_down((avail.x - gap * 2.0F) / 3.0F);
    const float card_h = snap_down((avail.y - gap - nav_gap - nav_button_h) / 2.0F);
    const ImVec2 cursor = ImGui::GetCursorPos();
    const ImVec2 origin(snap_nearest(cursor.x), snap_nearest(cursor.y));
    const auto page = vm_.channel_page();
    for (std::size_t i = 0; i < ViewModel::channel_page_size; ++i) {
        // 显式定位网格单元，避免 ImGui 默认换行间距改变卡片行距。
        const float x = origin.x + static_cast<float>(i % 3U) * (card_w + gap);
        const float y = origin.y + static_cast<float>(i / 3U) * (card_h + gap);
        ImGui::SetCursorPos(ImVec2(x, y));
        ImGui::PushID(static_cast<int>(i));
        if (i < page.size()) {
            draw_channel_card(page[i], card_w, card_h);
        } else {
            ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(color::inset));
            ImGui::PushStyleColor(ImGuiCol_Border, vec(color::empty_border));
            ImGui::BeginChild("##empty", ImVec2(card_w, card_h), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
            if (vm_.channel_count() == 0U && i == 0U) {
                ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
                ImGui::TextWrapped("%s", tr(Str::empty_channels));
                ImGui::PopStyleColor();
            }
            ImGui::EndChild();
            ImGui::PopStyleColor(2);
        }
        ImGui::PopID();
    }
    if (paged) {
        ImGui::SetCursorPos(ImVec2(origin.x, origin.y + card_h * 2.0F + gap + nav_gap));
        const float bw = px(28.0F);
        const float bh = nav_button_h;
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(0.0F, 0.0F));
        if (button("‹##chprev", ImVec2(bw, bh), Tone::normal, vm_.channel_page_index() > 0U)) {
            vm_.set_channel_page(vm_.channel_page_index() - 1U);
        }
        const auto label = fmt("%zu / %zu", vm_.channel_page_index() + 1U, vm_.channel_page_count());
        ImGui::SameLine((avail.x - ImGui::CalcTextSize(label.c_str()).x) * 0.5F);
        caption(label.c_str());
        ImGui::SameLine(std::max(0.0F, avail.x - bw));
        if (button("›##chnext", ImVec2(bw, bh), Tone::normal, vm_.channel_page_index() + 1U < vm_.channel_page_count())) {
            vm_.set_channel_page(vm_.channel_page_index() + 1U);
        }
        ImGui::PopStyleVar();
    }
    ImGui::EndChild();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
}

void AppView::draw_channel_card(const ChannelView& ch, float width, float height) {
    const std::uint32_t bg = ch.is_tx_active ? color::card_tx_active
                             : ch.is_tx_target ? color::card_tx_selected
                             : ch.is_muted     ? color::card_muted
                                               : color::panel;
    const std::uint32_t call_bg = ch.is_tx_active   ? color::call_tx_active
                                  : ch.is_tx_target ? color::call_tx_selected
                                  : ch.current_call ? color::call_active
                                                    : color::inset;
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(ch.current_call ? color::green : color::line));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(5.0F)));
    ImGui::BeginChild("##card", ImVec2(width, height), ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleVar();

    const ImVec2 inner = ImGui::GetContentRegionAvail();
    // 标题行：频道名 + 右侧状态徽标
    ImGui::PushFont(fonts_.bold, 15.0F);
    std::string badge;
    if (ch.is_tx_active) {
        badge = tr(Str::tx_active_badge);
    } else if (ch.is_muted) {
        badge = tr(Str::muted_badge);
    } else if (ch.is_tx_target) {
        badge = std::string("PTT");
    }
    const float badge_w = badge.empty() ? 0.0F : ImGui::CalcTextSize(badge.c_str()).x + px(12.0F);
    text_ellipsis(ch.title.c_str(), inner.x - badge_w - px(4.0F), ch.is_muted ? rgb(0x8A969B) : rgb(0xFFFFFF));
    ImGui::SetItemTooltip("%s", ch.tooltip.c_str());
    if (!badge.empty()) {
        ImGui::SameLine(inner.x - badge_w + ImGui::GetStyle().WindowPadding.x);
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const ImVec2 sz = ImGui::CalcTextSize(badge.c_str());
        const ImU32 badge_bg = ch.is_tx_active ? rgb(0xC0474F) : ch.is_muted ? rgb(0x3D484D) : rgb(0x3E8A5C);
        ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(p.x, p.y - px(1.0F)), ImVec2(p.x + sz.x + px(10.0F), p.y + sz.y + px(1.0F)),
                                                  badge_bg, px(3.0F));
        ImGui::SetCursorScreenPos(ImVec2(p.x + px(5.0F), p.y));
        ImGui::TextUnformatted(badge.c_str());
    }
    ImGui::PopFont();

    // 来话区（左）+ 操作按钮 2×2（右）
    const float content_h = ImGui::GetContentRegionAvail().y;
    const float buttons_w = std::min(px(190.0F), inner.x * 0.42F);
    const float call_w = inner.x - buttons_w - px(5.0F);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(call_bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(color::call_border));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(4.0F)));
    ImGui::BeginChild("##call", ImVec2(call_w, content_h), ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    if (ch.current_call) {
        caller_block(*ch.current_call, fonts_.bold, 23.0F, 17.0F, ch.is_tx_active ? rgb(0xFFFFFF) : rgb(color::callsign));
    } else {
        // 空闲：显示该频道最近一次来话（呼号 + 时间），没有记录时显示“空闲”。
        const float call_inner = ImGui::GetContentRegionAvail().x;
        ImGui::PushFont(nullptr, 13.0F);
        caption(tr(Str::channel_idle));
        ImGui::PopFont();
        if (ch.last_call) {
            const auto& last = ch.last_call->call;
            const auto cs = safe_callsign(last.callsign);
            ImGui::PushFont(fonts_.bold, 17.0F);
            text_ellipsis(cs.empty() ? fmt("DMR ID %u", last.source_id).c_str() : cs.c_str(), call_inner,
                          cs.empty() ? rgb(color::muted) : rgb(0x8FBF9A));
            ImGui::PopFont();
            ImGui::PushFont(nullptr, 12.0F);
            const auto when = fmt(tr(Str::last_call_fmt), format_clock(ch.last_call->started_wall).c_str());
            const auto id = cs.empty() ? when : fmt("%s · %u", when.c_str(), last.source_id);
            text_ellipsis(id.c_str(), call_inner, rgb(color::muted));
            ImGui::PopFont();
        }
    }
    ImGui::EndChild();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(2);

    ImGui::SameLine(0.0F, px(5.0F));
    ImGui::BeginGroup();
    const float bgap = px(3.0F);
    const ImVec2 bsize((buttons_w - bgap) * 0.5F, (content_h - bgap) * 0.5F);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(bgap, bgap));
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(2.0F), px(1.0F)));
    ImGui::PushFont(nullptr, 14.0F);
    const bool can_mutate = vm_.can_mutate_channels();
    const bool tx_busy = vm_.snapshot().tx_active;
    if (button(ch.is_tx_target ? tr(Str::btn_tx_target_short) : tr(Str::btn_set_tx_short), bsize,
               ch.is_tx_target ? Tone::ok : Tone::normal, can_mutate && !ch.is_tx_target && !tx_busy)) {
        vm_.set_tx_target(ch.key);
    }
    ImGui::SetItemTooltip("%s", ch.is_tx_target ? tr(Str::tip_tx_selected) : tr(Str::tip_set_tx));
    ImGui::SameLine();
    if (button(tr(Str::btn_remove_short), bsize, Tone::normal, can_mutate)) vm_.remove_channel(ch.key);
    if (button(ch.is_muted ? tr(Str::btn_unmute_short) : tr(Str::btn_mute_short), bsize, Tone::normal, can_mutate)) {
        vm_.toggle_mute(ch.key);
    }
    ImGui::SameLine();
    if (ch.quick_call_allowed) {
        const bool any_pending = vm_.pending(Str::op_quick_call);
        const char* label = ch.is_static            ? tr(Str::static_group)
                            : ch.quick_call_pending ? tr(Str::btn_joining_short)
                            : ch.quick_call_sent    ? tr(Str::btn_rejoin_short)
                                                    : tr(Str::btn_join_short);
        const bool bm_ready = vm_.snapshot().bm_link == BmLink::connected;
        if (button(label, bsize, Tone::normal,
                   !ch.is_static && !any_pending && !vm_.startup_group_activation_active() &&
                       bm_ready && !ch.is_muted)) {
            vm_.quick_call(ch.key);
        }
        ImGui::SetItemTooltip("%s", ch.is_static ? ch.tooltip.c_str()
                                    : any_pending ? tr(Str::tip_quick_pending)
                                                  : tr(Str::tip_quick_call));
    } else {
        ImGui::Dummy(bsize);
    }
    ImGui::PopFont();
    ImGui::PopStyleVar(2);
    ImGui::EndGroup();

    ImGui::EndChild();
    ImGui::PopStyleColor(2);
}

void AppView::draw_calls(float height) {
    const float gap = px(6.0F);
    const float w = ImGui::GetContentRegionAvail().x;
    const float history_w = (w - gap * 2.0F) * 0.5F;
    const float side_w = (w - gap * 2.0F - history_w) * 0.5F;
    draw_history(history_w, height);
    ImGui::SameLine(0.0F, gap);
    draw_current_call(side_w, height);
    ImGui::SameLine(0.0F, gap);
    draw_recent_calls(side_w, height);
}

void AppView::draw_history(float width, float height) {
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(color::history_bg));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(4.0F)));
    ImGui::BeginChild("##history", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const float bh = px(22.0F);
    ImGui::PushFont(fonts_.bold, 13.0F);
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(tr(Str::call_history));
    ImGui::PopFont();
    ImGui::SameLine(0.0F, px(10.0F));
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(6.0F), px(2.0F)));
    const auto page = vm_.history_page_index();
    const auto pages = vm_.history_page_count();
    if (button("‹##hprev", ImVec2(px(25.0F), bh), Tone::normal, page > 0U)) vm_.set_history_page(page - 1U);
    ImGui::SameLine();
    ImGui::AlignTextToFramePadding();
    caption(fmt("%zu / %zu", page + 1U, pages).c_str());
    ImGui::SameLine();
    if (button("›##hnext", ImVec2(px(25.0F), bh), Tone::normal, page + 1U < pages)) vm_.set_history_page(page + 1U);
    const float target_w = px(104.0F);
    ImGui::SameLine(inner_w - target_w + ImGui::GetStyle().WindowPadding.x);
    if (button(tr(Str::set_history_target), ImVec2(target_w, bh), Tone::normal,
               vm_.selected_history().has_value() && vm_.can_mutate_channels())) {
        vm_.set_history_target();
    }
    ImGui::SetItemTooltip("%s", tr(Str::tip_history_target));
    ImGui::PopStyleVar();

    const auto& history = vm_.history();
    ImGui::PushFont(nullptr, 13.0F);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0.0F, px(1.0F)));
    const std::size_t begin = page * ViewModel::history_page_size;
    for (std::size_t i = begin; i < history.size() && i < begin + ViewModel::history_page_size; ++i) {
        const auto& rec = history[i];
        const auto clock = format_clock(rec.started_wall);
        const auto from = source_label(vm_.with_callsign(rec.call));
        const auto text = rec.call.kind == dmr_call::CallKind::group
                              ? fmt(tr(Str::history_group), clock.c_str(), rec.call.destination_id, from.c_str())
                              : fmt(tr(Str::history_private), clock.c_str(), rec.call.destination_id, from.c_str());
        ImGui::PushID(static_cast<int>(i));
        const bool selected = vm_.selected_history() == i;
        const float row_h = ImGui::GetTextLineHeightWithSpacing();
        const bool clicked = ImGui::Selectable("##history-row", selected, ImGuiSelectableFlags_None, ImVec2(inner_w, row_h));
        const ImVec2 row_pos = ImGui::GetItemRectMin();
        ImGui::SetCursorScreenPos(row_pos);
        text_ellipsis(text.c_str(), inner_w, rgb(color::text));
        ImGui::SetItemTooltip("%s", text.c_str());
        if (clicked) vm_.select_history(selected ? std::nullopt : std::optional<std::size_t>(i));
        ImGui::PopID();
    }
    ImGui::PopStyleVar();
    ImGui::PopFont();
    ImGui::EndChild();
    ImGui::PopStyleColor();
}

void AppView::draw_current_call(float width, float height) {
    const auto& s = vm_.snapshot();
    const auto active = vm_.active_call();
    const bool rx = active.has_value();
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(s.tx_active ? color::call_tx_active : rx ? color::call_active : color::panel));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(rx ? 0x3E8A5C : color::line));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(8.0F), px(5.0F)));
    ImGui::BeginChild("##current", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    section_title(tr(Str::current_call), fonts_.bold);
    if (rx) {
        const auto& call = *active;
        if (auto started = vm_.current_call_started()) {
            const auto secs = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now() - *started).count();
            const auto dur = fmt("%02lld:%02lld", static_cast<long long>(secs / 60), static_cast<long long>(secs % 60));
            ImGui::SameLine(inner_w - ImGui::CalcTextSize(dur.c_str()).x + ImGui::GetStyle().WindowPadding.x);
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::green));
            ImGui::TextUnformatted(dur.c_str());
            ImGui::PopStyleColor();
        }
        caller_block(call, fonts_.bold, 22.0F, 15.0F, rgb(color::callsign));
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
        ImGui::TextUnformatted(call_target_text(call).c_str());
        ImGui::PopStyleColor();
        ImGui::PushStyleColor(ImGuiCol_PlotHistogram, vec(color::green));
        ImGui::PushStyleColor(ImGuiCol_FrameBg, vec(color::inset));
        ImGui::ProgressBar(std::clamp(s.levels.rx_peak, 0.0F, 1.0F), ImVec2(inner_w, px(6.0F)), "");
        ImGui::PopStyleColor(2);
    } else if (s.tx_active) {
        ImGui::PushFont(fonts_.bold, 22.0F);
        ImGui::TextUnformatted(tr(Str::tx_active_badge));
        ImGui::PopFont();
        if (s.tx_target.destination_id != 0U) {
            engine::CallInfo target;
            target.destination_id = s.tx_target.destination_id;
            target.kind = s.tx_target.kind;
            target.slot = s.tx_target.slot;
            caption(call_target_text(target).c_str());
        }
    } else {
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
        ImGui::TextUnformatted(tr(Str::no_call));
        ImGui::PopStyleColor();
    }
    ImGui::EndChild();
    ImGui::PopStyleColor(2);
}

void AppView::draw_recent_calls(float width, float height) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(8.0F), px(5.0F)));
    ImGui::BeginChild("##recent", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    section_title(tr(Str::recent_calls), fonts_.bold);
    const float line_h = ImGui::GetTextLineHeightWithSpacing();
    const auto max_rows = static_cast<std::size_t>(std::max(1.0F, ImGui::GetContentRegionAvail().y / line_h));
    const auto recent = vm_.recent_callers(max_rows);
    if (recent.empty()) {
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
        ImGui::TextUnformatted(tr(Str::no_call));
        ImGui::PopStyleColor();
    }
    for (const auto& rec : recent) {
        const auto clock = format_clock(rec.started_wall);
        const float clock_w = ImGui::CalcTextSize(clock.c_str()).x;
        const auto cs = safe_callsign(rec.call.callsign);
        ImGui::PushFont(fonts_.bold, 14.0F);
        ImGui::PushStyleColor(ImGuiCol_Text, cs.empty() ? vec(color::text) : vec(color::callsign));
        const std::string who = cs.empty() ? fmt("DMR ID %u", rec.call.source_id) : cs;
        ImGui::TextUnformatted(who.c_str());
        ImGui::PopStyleColor();
        ImGui::PopFont();
        if (!cs.empty()) {
            ImGui::SameLine(0.0F, px(8.0F));
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::link));
            ImGui::Text("%u", rec.call.source_id);
            ImGui::PopStyleColor();
        }
        ImGui::SameLine(inner_w - clock_w + ImGui::GetStyle().WindowPadding.x);
        caption(clock.c_str());
    }
    ImGui::EndChild();
}

void AppView::draw_radio_panel(float width, float height) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(10.0F), px(2.0F)));
    ImGui::BeginChild("##radio", ImVec2(width, height), ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_AlwaysVerticalScrollbar);
    ImGui::PopStyleVar();
    const ImVec2 item_spacing = ImGui::GetStyle().ItemSpacing;
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(item_spacing.x, px(2.0F)));
    const float inner_w = ImGui::GetContentRegionAvail().x;
    section_title(tr(Str::radio_control), fonts_.bold);
    const auto& s = vm_.snapshot();
    const auto& cfg = vm_.config();

    // 单一按钮协调 HRI 与 CAT；两种真实状态仍分别显示，不把单边成功当作整体成功。
    const auto& cat = vm_.cat();
    const auto selections = vm_.device_selection();
    std::vector<std::string> serial_ports;
    std::vector<std::string> serial_port_labels;
    std::vector<std::string> serial_port_ids;
    std::unordered_set<std::string> seen_serial_ports;
    for (const auto& p : vm_.devices().serial_ports) {
        const std::string port = to_utf8(p.port);
        const std::string stable_id = uppercase_ascii(port);
        if (!seen_serial_ports.insert(stable_id).second) continue;
        serial_ports.push_back(port);
        serial_port_labels.push_back(p.caption.empty() ? port : p.caption);
        serial_port_ids.push_back(stable_id);
    }
    const bool hri_auto_selected = is_auto_selection(cfg.hri_port);
    const std::string hri_auto_label = hri_auto_selected ? device_selection_text(selections.hri, true)
                                                          : std::string(tr(Str::auto_select));
    std::vector<std::string> hri_port_labels{hri_auto_label};
    std::vector<std::string> hri_port_ids{"auto"};
    hri_port_labels.insert(hri_port_labels.end(), serial_port_labels.begin(), serial_port_labels.end());
    hri_port_ids.insert(hri_port_ids.end(), serial_port_ids.begin(), serial_port_ids.end());
    const bool cat_auto_selected = is_auto_selection(cfg.cat_port);
    const std::string cat_auto_label = cat_auto_selected ? device_selection_text(selections.cat, true)
                                                          : std::string(tr(Str::auto_select));
    std::vector<std::string> cat_port_labels{cat_auto_label};
    std::vector<std::string> cat_port_ids{"auto"};
    cat_port_labels.insert(cat_port_labels.end(), serial_port_labels.begin(), serial_port_labels.end());
    cat_port_ids.insert(cat_port_ids.end(), serial_port_ids.begin(), serial_port_ids.end());
    const bool radio_idle = !s.serial_open && !s.hri_ready && !cat.connected && !cat.busy;
    const bool radio_active = s.serial_open || s.hri_ready || cat.connected || cat.busy;
    const bool radio_start_pending = vm_.pending(Str::op_start);
    const bool radio_stop_pending = vm_.pending(Str::op_stop);
    const bool radio_cancelable = radio_start_pending || (s.phase == Phase::starting && !radio_active);
    const bool port_settings_enabled = radio_idle && s.phase != Phase::starting && s.phase != Phase::stopping &&
                                       !radio_start_pending && !radio_stop_pending;
    const bool radio_connecting = cat.busy || (s.serial_open && !s.hri_ready);
    const char* radio_label = radio_stop_pending || s.phase == Phase::stopping ? tr(Str::disconnecting_serial)
                              : radio_cancelable ? tr(Str::disconnect_serial)
                              : radio_connecting ? tr(Str::connecting_radio)
                              : radio_active ? tr(Str::disconnect_serial) : tr(Str::connect_serial);
    const bool radio_button_enabled = s.phase != Phase::stopping && !radio_stop_pending;
    if (begin_fields("##serials", {{tr(Str::radio_link), 0.0F, px(104.0F)}, {tr(Str::wiresx_port), 1.0F, 0.0F},
                                    {tr(Str::cat_port), 1.0F, 0.0F}, {tr(Str::baud_rate), 0.0F, px(84.0F)}})) {
        ImGui::TableNextColumn();
        if (button(radio_label, ImVec2(-FLT_MIN, 0.0F),
                   (radio_active || radio_cancelable) ? Tone::normal : Tone::ok,
                   radio_button_enabled)) toggle_radio();
        ImGui::SetItemTooltip("%s", tr(Str::radio_link_hint));
        ImGui::TableNextColumn();
        ImGui::BeginDisabled(!port_settings_enabled);
        int hri_port_index = 0;
        if (!is_auto_selection(cfg.hri_port)) {
            const std::string selected = to_utf8(cfg.hri_port);
            const std::string stable_selected = uppercase_ascii(selected);
            const auto it = std::find(serial_port_ids.begin(), serial_port_ids.end(), stable_selected);
            if (it != serial_port_ids.end()) {
                hri_port_index = static_cast<int>(std::distance(serial_port_ids.begin(), it)) + 1;
                hri_port_labels[static_cast<std::size_t>(hri_port_index)] = device_selection_text(selections.hri, true);
            } else {
                hri_port_labels.emplace_back(device_selection_text(selections.hri, true));
                hri_port_ids.emplace_back("missing:" + stable_selected);
                hri_port_index = static_cast<int>(hri_port_labels.size()) - 1;
            }
        }
        std::vector<const char*> hri_port_items;
        std::vector<const char*> hri_port_item_ids;
        for (const auto& label : hri_port_labels) hri_port_items.push_back(label.c_str());
        for (const auto& item_id : hri_port_ids) hri_port_item_ids.push_back(item_id.c_str());
        if (simple_combo("##hriport", hri_port_index, hri_port_items.data(),
                         static_cast<int>(hri_port_items.size()), -FLT_MIN, "", hri_port_item_ids.data())) {
            auto next = cfg;
            next.hri_port = hri_port_index == 0 ? std::wstring{}
                             : static_cast<std::size_t>(hri_port_index) <= serial_ports.size()
                                 ? from_utf8(serial_ports[static_cast<std::size_t>(hri_port_index) - 1U])
                                 : cfg.hri_port;
            std::string error;
            if (!vm_.save_config(next, error)) settings_error_ = fmt(tr(Str::settings_save_failed), error.c_str());
        }
        if (!selections.hri.reason.empty() && language() == Language::zh_cn) {
            ImGui::SetItemTooltip("%s", selections.hri.reason.c_str());
        } else if (selections.hri.state != services::DeviceResolutionState::resolved) {
            ImGui::SetItemTooltip("%s", device_state_text(selections.hri.state));
        }
        ImGui::EndDisabled();
        ImGui::TableNextColumn();
        ImGui::BeginDisabled(!port_settings_enabled);
        int cat_port_index = 0;
        cat_port_labels[0] = cat_auto_selected ? device_selection_text(selections.cat, true)
                                               : std::string(tr(Str::auto_select));
        if (!is_auto_selection(cfg.cat_port)) {
            const auto selected = to_utf8(cfg.cat_port);
            const std::string stable_selected = uppercase_ascii(selected);
            const auto it = std::find(serial_port_ids.begin(), serial_port_ids.end(), stable_selected);
            if (it != serial_port_ids.end()) {
                cat_port_index = static_cast<int>(std::distance(serial_port_ids.begin(), it)) + 1;
                cat_port_labels[static_cast<std::size_t>(cat_port_index)] = device_selection_text(selections.cat, true);
            } else {
                cat_port_labels.emplace_back(device_selection_text(selections.cat, true));
                cat_port_ids.emplace_back("missing:" + stable_selected);
                cat_port_index = static_cast<int>(cat_port_labels.size()) - 1;
            }
        }
        std::vector<const char*> cat_port_items;
        std::vector<const char*> cat_port_item_ids;
        for (const auto& label : cat_port_labels) cat_port_items.push_back(label.c_str());
        for (const auto& item_id : cat_port_ids) cat_port_item_ids.push_back(item_id.c_str());
        if (simple_combo("##catport", cat_port_index, cat_port_items.data(),
                         static_cast<int>(cat_port_items.size()), -FLT_MIN, "", cat_port_item_ids.data())) {
            const std::size_t selected_index = static_cast<std::size_t>(cat_port_index);
            const std::string next_port = cat_port_index == 0 ? "auto"
                : selected_index < serial_ports.size() + 1U ? serial_ports[selected_index - 1U]
                                                              : to_utf8(cfg.cat_port);
            auto next = vm_.config();
            next.cat_port = from_utf8(next_port);
            std::string error;
            if (vm_.save_config(next, error)) {
                vm_.cat_form.port = next_port;
            } else {
                cat_port_index = cfg.cat_port.empty() || cfg.cat_port == L"auto" ? 0 : cat_port_index;
                settings_error_ = fmt(tr(Str::settings_save_failed), error.c_str());
            }
        }
        if (!selections.cat.reason.empty() && language() == Language::zh_cn) {
            ImGui::SetItemTooltip("%s", selections.cat.reason.c_str());
        } else if (selections.cat.state != services::DeviceResolutionState::resolved) {
            ImGui::SetItemTooltip("%s", device_state_text(selections.cat.state));
        }
        ImGui::TableNextColumn();
        static const char* const baud_labels[] = {"4800", "9600", "19200", "38400", "115200"};
        if (simple_combo("##baud", vm_.cat_form.baud_index, baud_labels, 5, -FLT_MIN)) {
            auto next = vm_.config();
            next.cat_baud_rate = vm_.cat_form.baud_index >= 0 && vm_.cat_form.baud_index < 5
                                     ? kBaudRates[vm_.cat_form.baud_index] : next.cat_baud_rate;
            std::string error;
            if (!vm_.save_config(next, error)) {
                for (int i = 0; i < 5; ++i) if (kBaudRates[i] == cfg.cat_baud_rate) vm_.cat_form.baud_index = i;
                settings_error_ = fmt(tr(Str::settings_save_failed), error.c_str());
            }
        }
        ImGui::EndDisabled();
        ImGui::EndTable();
    }

    draw_audio_devices(inner_w);

    // MAIN 模式 / 频率 / 功率 / 应用
    ImGui::BeginDisabled(!cat.connected || cat.busy);
    if (begin_fields("##mainrow", {{tr(Str::main_mode), 1.0F, 0.0F},
                                   {tr(Str::frequency_mhz), 1.0F, 0.0F},
                                   {tr(Str::power_w), 1.0F, 0.0F},
                                   {" ", 0.0F, px(80.0F)}})) {
        ImGui::TableNextColumn();
        const bool mode_changed = simple_combo("##mode", vm_.cat_form.mode_index, kCatModes, 4, -FLT_MIN,
                                               tr(Str::unknown));
        vm_.set_cat_form_editing(CatFormField::mode, ImGui::IsItemActive());
        if (mode_changed) vm_.mark_cat_form_edited(CatFormField::mode);
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        const bool frequency_changed = input_text("##freq", vm_.cat_form.frequency_mhz,
                                                   ImGuiInputTextFlags_CharsDecimal);
        vm_.set_cat_form_editing(CatFormField::frequency, ImGui::IsItemActive());
        if (frequency_changed) vm_.mark_cat_form_edited(CatFormField::frequency);
        ImGui::TableNextColumn();
        static const char* const power_labels[] = {"5 W", "10 W", "15 W", "25 W", "50 W"};
        const bool power_changed = simple_combo("##power", vm_.cat_form.power_index, power_labels, 5, -FLT_MIN,
                                                tr(Str::unknown));
        vm_.set_cat_form_editing(CatFormField::power, ImGui::IsItemActive());
        if (power_changed) vm_.mark_cat_form_edited(CatFormField::power);
        ImGui::TableNextColumn();
        const bool cat_form_valid = vm_.cat_form.mode_index >= 0 && vm_.cat_form.mode_index < 4 &&
                                    vm_.cat_form.power_index >= 0 && vm_.cat_form.power_index < 5;
        if (button(tr(Str::apply), ImVec2(-FLT_MIN, 0.0F), Tone::normal, cat_form_valid)) vm_.cat_apply();
        ImGui::EndTable();
    }
    ImGui::EndDisabled();

    const bool bm_connecting = s.bm_requested_enabled && s.bm_link != BmLink::connected;
    const char* bm_label = !s.bm_requested_enabled ? tr(Str::connect_bm)
                           : bm_connecting ? tr(Str::connecting_bm) : tr(Str::disconnect_bm);
    if (vm_.pending(Str::op_bm)) bm_label = s.bm_requested_enabled ? tr(Str::disconnecting_bm) : tr(Str::connecting_bm);
    const bool bm_runtime_available = s.phase == Phase::running;
    section_title(tr(Str::bm_account), fonts_.bold);
    if (begin_fields("##bm-identity", {{tr(Str::callsign), 1.0F, 0.0F},
                                        {tr(Str::manual_dmr_id), 1.0F, 0.0F},
                                        {tr(Str::device_no), 1.0F, 0.0F}})) {
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text("##bm-callsign", draft_.callsign,
                   ImGuiInputTextFlags_CharsUppercase | ImGuiInputTextFlags_CharsNoBlank);
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text("##bm-dmr-id", draft_dmr_id_, ImGuiInputTextFlags_CharsDecimal);
        ImGui::SetItemTooltip("%s", tr(Str::manual_dmr_id_hint));
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text("##bm-device-no", draft_.device_number, ImGuiInputTextFlags_CharsDecimal);
        ImGui::EndTable();
    }

    std::vector<std::string> server_labels;
    int preset = static_cast<int>(app::bm_servers::catalog.size());
    for (std::size_t i = 0; i < app::bm_servers::catalog.size(); ++i) {
        const auto& e = app::bm_servers::catalog[i];
        server_labels.emplace_back(e.label);
        if (draft_.master_preset == e.selection_id) preset = static_cast<int>(i);
    }
    server_labels.emplace_back(tr(Str::custom));
    std::vector<const char*> server_items;
    for (const auto& label : server_labels) server_items.push_back(label.c_str());
    if (begin_fields("##bm-server", {{tr(Str::bm_server), 1.0F, 0.0F},
                                      {tr(Str::udp_port), 0.65F, 0.0F},
                                      {tr(Str::host_ipv4), 1.35F, 0.0F}})) {
        ImGui::TableNextColumn();
        if (simple_combo("##bm-preset", preset, server_items.data(), static_cast<int>(server_items.size()), -FLT_MIN)) {
            if (preset == static_cast<int>(app::bm_servers::catalog.size())) {
                draft_.master_preset = "custom";
            } else {
                const auto& e = app::bm_servers::catalog[static_cast<std::size_t>(preset)];
                draft_.master_preset = std::string(e.selection_id);
                if (!app::bm_servers::address_matches(e, draft_.master_host)) draft_.master_host = std::string(e.hostname);
                draft_master_port_ = std::to_string(e.port);
            }
        }
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        if (input_text("##bm-port", draft_master_port_, ImGuiInputTextFlags_CharsDecimal)) draft_.master_preset = "custom";
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        if (input_text("##bm-host", draft_.master_host, ImGuiInputTextFlags_CharsNoBlank)) draft_.master_preset = "custom";
        ImGui::EndTable();
    }

    const std::string saved_id = cfg.dmr_id == 0U ? std::string{} : std::to_string(cfg.dmr_id);
    const bool bm_config_dirty = draft_.callsign != cfg.callsign || draft_dmr_id_ != saved_id ||
        draft_.device_number != cfg.device_number || draft_.master_preset != cfg.master_preset ||
        draft_.master_host != cfg.master_host || draft_master_port_ != std::to_string(cfg.master_port) ||
        draft_.bm_password != cfg.bm_password || draft_.bm_api_key != cfg.bm_api_key;
    const bool bm_config_complete = cfg.dmr_id != 0U && !cfg.callsign.empty() &&
                                    !cfg.bm_password.empty() && !cfg.master_host.empty();
    if (begin_fields("##bm-secrets", {{tr(Str::bm_password), 1.0F, 0.0F},
                                       {tr(Str::bm_api_key), 1.0F, 0.0F},
                                       {" ", 0.0F, px(94.0F)}, {" ", 0.0F, px(104.0F)}})) {
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text("##bm-password", draft_.bm_password, ImGuiInputTextFlags_Password);
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text("##bm-api-key", draft_.bm_api_key, ImGuiInputTextFlags_Password);
        ImGui::TableNextColumn();
        if (button(tr(Str::save_settings), ImVec2(-FLT_MIN, 0.0F), Tone::normal)) save_bm_config();
        ImGui::TableNextColumn();
        if (button(bm_label, ImVec2(-FLT_MIN, 0.0F), s.bm_requested_enabled ? Tone::normal : Tone::ok,
                   bm_runtime_available && !vm_.pending(Str::op_bm) &&
                       (s.bm_requested_enabled || (!bm_config_dirty && bm_config_complete)))) toggle_bm();
        if (!s.bm_requested_enabled && (bm_config_dirty || !bm_config_complete)) {
            ImGui::SetItemTooltip("%s", tr(Str::bm_save_before_connect));
        }
        ImGui::EndTable();
    }
    ImGui::PushFont(nullptr, 11.0F);
    ImGui::PushStyleColor(ImGuiCol_Text, vec(settings_error_.empty() ? color::muted : color::warn));
    ImGui::TextWrapped("%s", settings_error_.empty() ? tr(Str::bm_changes_next_connection) : settings_error_.c_str());
    ImGui::PopStyleColor();
    ImGui::PopFont();
    if (vm_.pending(Str::op_start) || vm_.pending(Str::op_bm) || s.phase == Phase::starting ||
        s.bm_link == BmLink::resolving || s.bm_link == BmLink::connecting) continuous_ = true;

    ImGui::PopStyleVar();
    ImGui::EndChild();
}

void AppView::draw_audio_devices(float inner_w) {
    const auto& snapshot = vm_.snapshot();
    const bool radio_attached = snapshot.serial_open || snapshot.hri_ready;
    const auto& config = vm_.config();
    auto selected_in = radio_attached && !snapshot.wave_in_endpoint_id.empty()
                           ? snapshot.wave_in_endpoint_id : config.wave_in_endpoint_id;
    auto selected_out = radio_attached && !snapshot.wave_out_endpoint_id.empty()
                            ? snapshot.wave_out_endpoint_id : config.wave_out_endpoint_id;
    // In BM-only mode the selector represents the saved request (including Auto).
    // The preview still shows the resolved endpoint through device_selection().
    auto output_selector = radio_attached ? selected_out : config.wave_out_endpoint_id;
    if (audio_selection_pending_) {
        if (!vm_.pending(Str::op_audio_devices)) {
            const bool confirmed = !audio_operation_failed_ && (pending_radio_audio_change_
                ? snapshot.wave_in_endpoint_id == pending_wave_in_ &&
                  snapshot.wave_out_endpoint_id == pending_wave_out_
                : (snapshot.local_audio.output_error == wirex::bm_local_playback::OutputError::none &&
                   snapshot.local_audio.output_open &&
                   (pending_wave_out_.empty() || snapshot.wave_out_endpoint_id == pending_wave_out_)));
            audio_selection_pending_ = false;
            pending_radio_audio_change_ = false;
            audio_operation_failed_ = false;
            if (confirmed) {
                if (radio_attached) {
                    selected_in = snapshot.wave_in_endpoint_id;
                    selected_out = snapshot.wave_out_endpoint_id;
                } else {
                    selected_in = config.wave_in_endpoint_id;
                    selected_out = config.wave_out_endpoint_id;
                    output_selector = config.wave_out_endpoint_id;
                }
                audio_notice_ = tr(Str::audio_devices_applied);
            } else {
                audio_notice_ = vm_.transient_visible() ? vm_.transient_text() : tr(Str::audio_devices_failed);
            }
        } else {
            if (pending_radio_audio_change_) {
                selected_in = pending_wave_in_;
                selected_out = pending_wave_out_;
            } else {
                output_selector = pending_wave_out_;
            }
            continuous_ = true;
        }
    }

    ImGui::PushFont(fonts_.bold, 13.0F);
    ImGui::TextUnformatted(tr(Str::audio_devices));
    ImGui::PopFont();
    if (!audio_notice_.empty()) {
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_Text, vec(audio_selection_pending_ ? color::warn : color::muted));
        const float notice_w = std::max(0.0F, ImGui::GetContentRegionAvail().x - px(4.0F));
        text_ellipsis(audio_notice_.c_str(), notice_w, rgb(audio_selection_pending_ ? color::warn : color::muted));
        ImGui::SetItemTooltip("%s", audio_notice_.c_str());
        ImGui::PopStyleColor();
    }

    auto endpoint_combo = [&](const char* id, const std::vector<services::AudioEndpointInfo>& devices,
                              const services::ResolvedDeviceSelection& resolution,
                              std::wstring& selected, const std::wstring& current, bool allow_auto,
                              bool show_pending_selection) {
        ImGui::TableNextColumn();
        std::string preview = device_selection_text(resolution, false);
        if (audio_selection_pending_ && show_pending_selection) {
            preview = current.empty() ? std::string(tr(Str::auto_select)) : to_utf8(current);
            for (const auto& endpoint : devices) {
                if (endpoint.endpoint_id == current) preview = endpoint.name;
            }
        }
        const std::string auto_label = resolution.requested_id.empty()
                                           ? device_selection_text(resolution, false)
                                           : std::string(tr(Str::auto_select));
        ImGui::SetNextItemWidth(-FLT_MIN);
        ImGui::BeginDisabled(audio_selection_pending_);
        if (ImGui::BeginCombo(id, preview.c_str())) {
            if (allow_auto) {
                detail::ItemIdScope item_id("auto", 0);
                if (ImGui::Selectable(auto_label.c_str(), current.empty())) selected.clear();
                if (ImGui::IsItemHovered() && auto_label != tr(Str::auto_select)) {
                    ImGui::SetItemTooltip("%s", auto_label.c_str());
                }
            }
            std::unordered_set<std::wstring> seen_endpoint_ids;
            for (std::size_t i = 0; i < devices.size(); ++i) {
                const auto& endpoint = devices[i];
                if (!endpoint.endpoint_id.empty() && !seen_endpoint_ids.insert(endpoint.endpoint_id).second) continue;
                const std::string label = endpoint.name.empty() ? to_utf8(endpoint.endpoint_id) : endpoint.name;
                const std::string stable_id = to_utf8(endpoint.endpoint_id);
                detail::ItemIdScope item_id(stable_id.empty() ? nullptr : stable_id.c_str(), static_cast<int>(i));
                if (ImGui::Selectable(label.c_str(), endpoint.endpoint_id == current)) selected = endpoint.endpoint_id;
                if (ImGui::IsItemHovered() && !label.empty()) {
                    if (!stable_id.empty()) ImGui::SetItemTooltip("%s\n%s", label.c_str(), stable_id.c_str());
                    else ImGui::SetItemTooltip("%s", label.c_str());
                }
            }
            ImGui::EndCombo();
        }
        if (!audio_selection_pending_) {
            if (!resolution.name.empty()) {
                std::string tooltip = resolution.name;
                if (!resolution.resolved_id.empty()) tooltip += "\n" + to_utf8(resolution.resolved_id);
                if (!resolution.reason.empty()) tooltip += "\n" + resolution.reason;
                ImGui::SetItemTooltip("%s", tooltip.c_str());
            } else if (!resolution.reason.empty()) {
                ImGui::SetItemTooltip("%s", resolution.reason.c_str());
            } else if (resolution.state != services::DeviceResolutionState::resolved) {
                ImGui::SetItemTooltip("%s", device_state_text(resolution.state));
            }
        }
        ImGui::EndDisabled();
    };

    if (begin_fields("##audio-main", {{tr(Str::input), 1.0F, 0.0F}, {tr(Str::output), 1.0F, 0.0F},
                                       {" ", 0.0F, px(104.0F)}})) {
        std::wstring next_in = selected_in;
        std::wstring next_out = output_selector;
        const auto selection = vm_.device_selection();
        endpoint_combo("##wavein-main", vm_.devices().wave_in, selection.wave_in, next_in, selected_in,
                       !radio_attached, pending_radio_audio_change_);
        endpoint_combo("##waveout-main", vm_.devices().wave_out, selection.wave_out, next_out, output_selector,
                       !radio_attached, true);
        ImGui::TableNextColumn();
        if (button(tr(Str::refresh_devices), ImVec2(-FLT_MIN, 0.0F), Tone::normal, !audio_selection_pending_)) {
            vm_.refresh_devices();
        }
        ImGui::EndTable();

        if (next_in != selected_in || next_out != selected_out) {
            if (radio_attached) {
                // HRI 已附着时，运行中的音频设备需要成对切换。
                if (!next_in.empty() && !next_out.empty()) {
                    pending_wave_in_ = next_in;
                    pending_wave_out_ = next_out;
                    pending_radio_audio_change_ = true;
                    audio_operation_failed_ = false;
                    audio_selection_pending_ = true;
                    audio_notice_ = tr(Str::audio_devices_switching);
                    vm_.set_audio_devices(next_in, next_out);
                    if (!vm_.pending(Str::op_audio_devices)) {
                        audio_selection_pending_ = false;
                        pending_radio_audio_change_ = false;
                        audio_notice_ = vm_.transient_visible() ? vm_.transient_text() : tr(Str::audio_devices_failed);
                    }
                }
            } else {
                if (next_in != selected_in) {
                    auto next = vm_.config();
                    next.wave_in_endpoint_id = next_in == L"auto" || next_in == L"AUTO" ? std::wstring{} : next_in;
                    std::string error;
                    if (!vm_.save_config(next, error)) {
                        audio_notice_ = fmt(tr(Str::settings_save_failed), error.c_str());
                    } else {
                        audio_notice_ = tr(Str::audio_devices_next_connection);
                    }
                }
                if (next_out != output_selector) {
                    pending_wave_out_ = next_out.empty() || next_out == L"auto" || next_out == L"AUTO"
                                            ? std::wstring{} : next_out;
                    // Auto has no configured ID. A successful output-only command must
                    // publish an open WaveOut in the snapshot before the UI accepts it.
                    pending_radio_audio_change_ = false;
                    audio_operation_failed_ = false;
                    audio_notice_ = tr(Str::audio_devices_switching);
                    vm_.set_audio_output(next_out);
                    audio_selection_pending_ = vm_.pending(Str::op_audio_devices);
                    if (!audio_selection_pending_) {
                        if (vm_.transient_visible() && vm_.transient_failed()) {
                            audio_notice_ = vm_.transient_text();
                        } else if (snapshot.phase == Phase::running || snapshot.phase == Phase::starting) {
                            audio_notice_ = tr(Str::audio_devices_failed);
                        } else {
                            audio_notice_ = tr(Str::audio_devices_next_connection);
                        }
                    }
                }
            }
        }
    }
    (void)inner_w;
}

void AppView::draw_daily_panel(float width, float height) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(10.0F), px(8.0F)));
    ImGui::BeginChild("##daily", ImVec2(width, height), ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_AlwaysVerticalScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    section_title(tr(Str::daily_controls), fonts_.bold);

    // 增加动态组 频道ID / 类型 / 加入监听
    static const std::vector<std::string> presets = {"460997 中国鹦鹉", "46001 组呼", "91 组呼"};
    if (begin_fields("##addrow", {{tr(Str::add_channel_id), 1.0F, 0.0F},
                                  {tr(Str::type), 0.0F, px(110.0F)},
                                  {" ", 0.0F, px(110.0F)}})) {
        ImGui::TableNextColumn();
        if (const int picked = editable_combo("##chid", vm_.add_channel_id, presets, ImGui::GetContentRegionAvail().x); picked >= 0) {
            vm_.add_channel_id = presets[static_cast<std::size_t>(picked)];
            vm_.add_channel_kind = picked == 0 ? 1 : 2;
        }
        ImGui::TableNextColumn();
        const char* kinds[] = {tr(Str::select), tr(Str::private_call), tr(Str::group)};
        simple_combo("##kind", vm_.add_channel_kind, kinds, 3, -FLT_MIN);
        ImGui::TableNextColumn();
        if (button(tr(Str::add_listen), ImVec2(-FLT_MIN, 0.0F), Tone::ok, vm_.can_mutate_channels())) vm_.add_channel();
        ImGui::EndTable();
    }

    const auto& startup_status = vm_.startup_group_activation_status();
    if (!startup_status.empty()) {
        const bool warning = startup_status.find("失败") != std::string::npos ||
                             startup_status.find("failed") != std::string::npos ||
                             startup_status.find("busy") != std::string::npos ||
                             startup_status.find("paused") != std::string::npos ||
                             startup_status.find("忙") != std::string::npos ||
                             startup_status.find("暂停") != std::string::npos;
        ImGui::PushFont(nullptr, 11.0F);
        ImGui::PushStyleColor(ImGuiCol_Text, vec(warning ? color::warn : color::muted));
        ImGui::TextWrapped("%s", startup_status.c_str());
        ImGui::PopStyleColor();
        ImGui::PopFont();
    }

    ImGui::Separator();
    draw_static_groups(inner_w);
    ImGui::Separator();
    // 右侧集中日常组控制、收发增益、实时 RX/TX 峰值 meter 和连接状态。
    const auto& s = vm_.snapshot();
    const auto& cat = vm_.cat();
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(4.0F), px(3.0F)));
    caption(tr(Str::playback_gain));
    ImGui::SameLine(inner_w - px(54.0F));
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::green));
    ImGui::Text("%d×", vm_.playback_step);
    ImGui::PopStyleColor();
    if (gain_slider("##playback", vm_.playback_step, std::max(px(90.0F), inner_w - px(8.0F)), scale_)) {
        vm_.commit_gains();
    }

    caption(tr(Str::transmit_gain));
    ImGui::SameLine(inner_w - px(54.0F));
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::green));
    ImGui::Text("%d×", vm_.transmit_step);
    ImGui::PopStyleColor();
    if (gain_slider("##transmit-right", vm_.transmit_step,
                    std::max(px(90.0F), inner_w - px(8.0F)), scale_)) {
        vm_.commit_gains();
    }
    ImGui::PopStyleVar();

    ImGui::Separator();
    ImGui::PushFont(nullptr, 12.0F);
    auto meter = [&](const char* label, float value) {
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
        ImGui::TextUnformatted(label);
        ImGui::PopStyleColor();
        ImGui::SameLine(px(106.0F));
        const float meter_w = std::max(px(40.0F), ImGui::GetContentRegionAvail().x - px(42.0F));
        ImGui::PushStyleColor(ImGuiCol_PlotHistogram, vec(value > 0.9F ? color::warn : color::green));
        ImGui::PushStyleColor(ImGuiCol_FrameBg, vec(color::inset));
        ImGui::ProgressBar(std::clamp(value, 0.0F, 1.0F), ImVec2(meter_w, px(9.0F)), "");
        ImGui::PopStyleColor(2);
        ImGui::SameLine();
        ImGui::Text("%d%%", static_cast<int>(std::lround(std::clamp(value, 0.0F, 1.0F) * 100.0F)));
    };
    meter(tr(Str::rx_live_peak), s.levels.rx_peak);
    meter(tr(Str::tx_live_peak), s.levels.tx_peak);
    ImGui::PopFont();

    ImGui::Separator();
    caption(tr(Str::status));
    ImGui::SameLine(0.0F, px(8.0F));
    status_dot(s.serial_open, tr(Str::status_serial));
    ImGui::SameLine(0.0F, px(7.0F));
    status_dot(s.hri_ready, tr(Str::status_hri));
    const auto device_status = vm_.device_selection();
    ImGui::SetItemTooltip("%s", device_selection_text(device_status.hri, true).c_str());
    ImGui::SameLine(0.0F, px(7.0F));
    status_dot(cat.connected, tr(Str::status_cat));
    ImGui::SetItemTooltip("%s", cat.error.empty() ? device_selection_text(device_status.cat, true).c_str()
                                                   : cat.error.c_str());
    ImGui::SameLine(0.0F, px(7.0F));
    status_dot(s.bm_link == BmLink::connected, tr(Str::status_bm));
    ImGui::SameLine(0.0F, px(10.0F));
    const auto& local_audio = s.local_audio;
    const auto audio_state = local_audio.audio_state;
    const bool output_error = !s.local_audio_error.empty() ||
        local_audio.output_error != wirex::bm_local_playback::OutputError::none;
    const bool radio_route = local_audio.radio_ready && !output_error;
    caption(tr(radio_route ? Str::local_audio_route_status : Str::local_playback));
    ImGui::SameLine(0.0F, px(6.0F));
    const char* playback_text = output_error ? tr(Str::local_playback_failed)
        : radio_route ? local_playback_route_text(wirex::bm_local_playback::Route::radio)
                      : local_playback_state_text(audio_state);
    ImGui::PushStyleColor(ImGuiCol_Text,
                          vec(output_error ? color::error : radio_route ? color::green : local_playback_color(audio_state)));
    ImGui::TextUnformatted(playback_text);
    ImGui::PopStyleColor();
    if (output_error) {
        const char* category = local_playback_error_text(local_audio.output_error);
        const char* detail = !s.local_audio_error.empty() ? s.local_audio_error.c_str() : category;
        if (language() == Language::en_us && category[0] != '\0') detail = category;
        ImGui::SetItemTooltip("%s", detail);
    } else {
        const auto& resolved = device_status.wave_out;
        const std::string tooltip = !resolved.name.empty() ? resolved.name : device_selection_text(resolved, true);
        ImGui::SetItemTooltip("%s", tooltip.c_str());
    }
    ImGui::NewLine();
    status_dot(s.wave_in_open, tr(Str::status_wave_in));
    ImGui::SetItemTooltip("%s", device_selection_text(device_status.wave_in, false).c_str());
    ImGui::SameLine(0.0F, px(7.0F));
    status_dot(s.wave_out_open, tr(Str::status_wave_out));
    ImGui::SetItemTooltip("%s", device_selection_text(device_status.wave_out, false).c_str());
    ImGui::SameLine(0.0F, px(10.0F));
    caption(phase_short_text(s.phase));
    ImGui::EndChild();
}

// BM 静态组（BmManagementUi.ps1）：标题行 [设备 · 分页 · 刷新 · 移除]，每页 3 条，下方 TG 输入 + 添加。
void AppView::draw_static_groups(float inner_w) {
    auto& sg = vm_.static_form();
    const auto& cfg = vm_.config();
    const bool has_key = !cfg.bm_api_key.empty();
    const std::size_t pages =
        std::max<std::size_t>(1U, (sg.groups.size() + StaticGroupsView::page_size - 1U) / StaticGroupsView::page_size);
    const float bh = px(22.0F);
    const float small_w = px(25.0F);

    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(6.0F), px(2.0F)));
    ImGui::AlignTextToFramePadding();
    section_title(tr(Str::bm_static_groups), fonts_.bold);
    ImGui::SameLine(0.0F, px(8.0F));
    ImGui::AlignTextToFramePadding();
    const auto device = vm_.bm_device_id();
    caption(device != 0U ? fmt(tr(Str::static_device_fmt), device).c_str() : "—");

    const float refresh_w = ImGui::CalcTextSize(tr(Str::static_refresh)).x + px(14.0F);
    const float remove_w = ImGui::CalcTextSize(tr(Str::static_remove)).x + px(14.0F);
    const auto page_label = fmt("%zu / %zu", sg.page + 1U, pages);
    const float page_w = ImGui::CalcTextSize(page_label.c_str()).x;
    const float spacing = ImGui::GetStyle().ItemSpacing.x;
    const float right_w = small_w * 2.0F + page_w + refresh_w + remove_w + spacing * 4.0F;
    ImGui::SameLine(ImGui::GetStyle().WindowPadding.x + inner_w - right_w);
    if (button("‹##sgprev", ImVec2(small_w, bh), Tone::normal, sg.loaded && sg.page > 0U)) vm_.static_set_page(sg.page - 1U);
    ImGui::SameLine();
    ImGui::AlignTextToFramePadding();
    caption(page_label.c_str());
    ImGui::SameLine();
    if (button("›##sgnext", ImVec2(small_w, bh), Tone::normal, sg.loaded && sg.page + 1U < pages)) {
        vm_.static_set_page(sg.page + 1U);
    }
    ImGui::SameLine();
    if (button(tr(Str::static_refresh), ImVec2(refresh_w, bh), Tone::normal, vm_.bm_api_available() && has_key && !sg.busy)) {
        vm_.static_refresh();
    }
    ImGui::SameLine();
    if (button(tr(Str::static_remove), ImVec2(remove_w, bh), Tone::normal, sg.loaded && sg.selected.has_value() && !sg.busy)) {
        vm_.static_remove();
    }
    ImGui::PopStyleVar();

    // 列表（固定 3 行高；左）+ TG 输入与添加（右）
    const float add_w = ImGui::CalcTextSize(tr(Str::static_add)).x + px(20.0F);
    const float list_outer_w = inner_w - add_w - spacing;
    ImGui::PushFont(nullptr, 13.0F);
    const float row_h = ImGui::GetTextLineHeight() + px(2.0F);
    ImGui::PopFont();
    const float list_h = std::max(row_h * static_cast<float>(StaticGroupsView::page_size) + px(8.0F),
                                  ImGui::GetFrameHeight() * 2.0F + spacing);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(color::input_bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(color::call_border));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(4.0F)));
    ImGui::BeginChild("##sglist", ImVec2(list_outer_w, list_h), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    ImGui::PushFont(nullptr, 13.0F);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0.0F, px(2.0F)));
    const float list_w = ImGui::GetContentRegionAvail().x;
    auto centered = [&](const char* text, std::uint32_t col) {
        const ImVec2 sz = ImGui::CalcTextSize(text);
        ImGui::SetCursorPos(ImVec2((ImGui::GetWindowWidth() - sz.x) * 0.5F, (list_h - sz.y) * 0.5F));
        ImGui::PushStyleColor(ImGuiCol_Text, vec(col));
        ImGui::TextUnformatted(text);
        ImGui::PopStyleColor();
    };
    if (!has_key) {
        centered(tr(Str::static_need_key), color::muted);
    } else if (sg.loaded && sg.groups.empty()) {
        centered(tr(Str::static_empty), color::muted);
    } else {
        const std::size_t begin = sg.page * StaticGroupsView::page_size;
        for (std::size_t i = begin; i < sg.groups.size() && i < begin + StaticGroupsView::page_size; ++i) {
            const auto& g = sg.groups[i];
            const auto slot = g.slot == 0 ? std::string(tr(Str::static_slot_dmo)) : fmt(tr(Str::static_slot_fmt), g.slot);
            auto label = fmt(tr(Str::static_row_fmt), g.talkgroup, slot.c_str());
            const auto name = known_name_for_static(g.talkgroup);
            if (!name.empty()) label += " · " + name;
            ImGui::PushID(static_cast<int>(i));
            const bool selected = sg.selected == i;
            const bool clicked = ImGui::Selectable("##static-row", selected, ImGuiSelectableFlags_None, ImVec2(list_w, row_h));
            const ImVec2 row_pos = ImGui::GetItemRectMin();
            ImGui::SetCursorScreenPos(row_pos);
            text_ellipsis(label.c_str(), list_w, rgb(color::text));
            ImGui::SetItemTooltip("%s", label.c_str());
            if (clicked) vm_.static_select(selected ? std::nullopt : std::optional<std::size_t>(i));
            ImGui::PopID();
        }
    }
    ImGui::PopStyleVar();
    ImGui::PopFont();
    ImGui::EndChild();
    ImGui::PopStyleColor(2);

    ImGui::SameLine();
    ImGui::BeginGroup();
    ImGui::SetNextItemWidth(add_w);
    ImGui::BeginDisabled(!has_key);
    input_text("##sgtg", sg.tg_input, ImGuiInputTextFlags_CharsDecimal);
    if (sg.tg_input.empty() && !ImGui::IsItemActive()) {
        const ImVec2 p = ImGui::GetItemRectMin();
        ImGui::GetWindowDrawList()->AddText(ImVec2(p.x + ImGui::GetStyle().FramePadding.x, p.y + ImGui::GetStyle().FramePadding.y),
                                            rgb(color::disabled_text), tr(Str::static_tg_hint));
    }
    ImGui::EndDisabled();
    if (button(tr(Str::static_add), ImVec2(add_w, 0.0F), Tone::normal,
               sg.loaded && sg.add_slot.has_value() && !sg.busy && !sg.tg_input.empty())) {
        vm_.static_add();
    }
    ImGui::EndGroup();
    if (sg.busy) continuous_ = true;
}

void AppView::toggle_language() {
    auto next = vm_.config();
    const auto selected = language() == Language::zh_cn ? Language::en_us : Language::zh_cn;
    set_language(selected);
    next.ui_language = selected == Language::en_us ? "en-US" : "zh-CN";
    std::string error;
    language_notice_.clear();
    if (!vm_.save_config(next, error)) language_notice_ = fmt(tr(Str::settings_save_failed), error.c_str());
}

void AppView::toggle_radio() {
    const auto& s = vm_.snapshot();
    const bool active = s.serial_open || s.hri_ready || vm_.cat().connected || vm_.cat().busy ||
                        vm_.pending(Str::op_start) || s.phase == Phase::starting;
    if (!active) {
        if (!vm_.pending(Str::op_start) && !vm_.pending(Str::op_stop)) vm_.start();
    } else if (s.phase != Phase::stopping && !vm_.pending(Str::op_stop)) {
        vm_.stop();
    }
}

void AppView::toggle_bm() {
    const auto& s = vm_.snapshot();
    if (s.phase == Phase::running && !vm_.pending(Str::op_bm)) vm_.toggle_bm();
}

void AppView::save_bm_config() {
    auto next = vm_.config();
    next.callsign = draft_.callsign;
    next.device_number = draft_.device_number;
    next.master_preset = draft_.master_preset;
    next.master_host = draft_.master_host;
    next.bm_password = draft_.bm_password;
    next.bm_api_key = draft_.bm_api_key;

    auto parse_u = [](const std::string& text, std::uint32_t max, std::uint32_t& out) {
        if (text.empty()) return false;
        try {
            std::size_t used = 0U;
            const auto value = std::stoul(text, &used);
            if (used != text.size() || value > max) return false;
            out = static_cast<std::uint32_t>(value);
            return true;
        } catch (const std::exception&) {
            return false;
        }
    };

    if (!parse_u(draft_dmr_id_, 16777215U, next.dmr_id) || next.dmr_id == 0U) {
        settings_error_ = fmt(tr(Str::settings_save_failed), tr(Str::dmr_id));
        return;
    }
    std::uint32_t port = 0U;
    if (!parse_u(draft_master_port_, 65535U, port) || port == 0U) {
        settings_error_ = fmt(tr(Str::settings_save_failed), tr(Str::udp_port));
        return;
    }
    next.master_port = static_cast<std::uint16_t>(port);
    std::string error;
    if (!vm_.save_config(next, error)) {
        settings_error_ = fmt(tr(Str::settings_save_failed), error.c_str());
        return;
    }

    const auto& saved = vm_.config();
    draft_.callsign = saved.callsign;
    draft_.dmr_id = saved.dmr_id;
    draft_.device_number = saved.device_number;
    draft_.master_preset = saved.master_preset;
    draft_.master_host = saved.master_host;
    draft_.master_port = saved.master_port;
    draft_.bm_password = saved.bm_password;
    draft_.bm_api_key = saved.bm_api_key;
    draft_dmr_id_ = std::to_string(saved.dmr_id);
    draft_master_port_ = std::to_string(saved.master_port);
    settings_error_.clear();
}

} // namespace wirex::gui
