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
#include <vector>

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

// ---------------------------------------------------------------- 布局常量（逻辑像素，使用时经 AppView::px() 按 DPI 缩放取整）

namespace layout {
constexpr float kGap = 4.0F;               // 面板之间、频道卡片之间
constexpr float kInlineGap = 6.0F;         // 同一行内相邻控件
constexpr float kLabelGap = 5.0F;          // 标签与其值之间
constexpr float kGroupGap = 12.0F;         // 同一行内“标签 值”组之间
constexpr float kTitleGap = 8.0F;          // 标题与其后的附注/按钮组之间
constexpr float kRowGap = 3.0F;            // 段内行距
constexpr float kSectionGapMin = 6.0F;     // 面板内段间距下限（内容放不下时出现滚动条）
constexpr float kSectionGapMax = 16.0F;    // 面板内段间距上限（更大的窗口把剩余空间留在底部）
constexpr float kPanelPadX = 10.0F;        // 电台/日常控制面板内边距
constexpr float kPanelPadY = 6.0F;
constexpr float kCardPad = 6.0F;           // 频道卡片、来话卡片内边距
constexpr float kRowHeight = 22.0F;        // 标题行、状态行、小按钮高度
constexpr float kHeaderHeight = 32.0F;
constexpr float kHeaderButtonHeight = 26.0F;
constexpr float kActionWidth = 104.0F;     // 表单行首/行尾按钮、短字段列宽，各行一致
constexpr float kPagerWidth = 25.0F;       // ‹ › 翻页按钮
constexpr float kFontTitle = 14.0F;        // 面板/卡片标题
constexpr float kFontSubtitle = 13.0F;     // 面板内小节标题
constexpr float kFontBody = 13.0F;         // 状态行、列表
constexpr float kFontCaption = 12.0F;      // 字段标题、弱提示
} // namespace layout

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

// 单行布局：同一行内字号/高度不同的控件按行高垂直居中，行结束后光标落在 top + h + ItemSpacing.y。
struct Row {
    float x0;
    float top;
    float h;
    void place(float item_h) const { ImGui::SetCursorPosY(std::round(top + (h - item_h) * 0.5F)); }
    void end() const {
        ImGui::SetCursorPos(ImVec2(x0, top));
        ImGui::Dummy(ImVec2(0.0F, h));
    }
};

Row begin_row(float h) {
    const ImVec2 c = ImGui::GetCursorPos();
    return {c.x, c.y, h};
}

float line_height(ImFont* font, float size) {
    ImGui::PushFont(font, size);
    const float h = ImGui::GetTextLineHeight();
    ImGui::PopFont();
    return h;
}

void row_text(const Row& row, const char* text, ImU32 col, ImFont* font, float size) {
    ImGui::PushFont(font, size);
    row.place(ImGui::GetTextLineHeight());
    ImGui::GetCurrentWindow()->DC.CurrLineTextBaseOffset = 0.0F;
    ImGui::PushStyleColor(ImGuiCol_Text, col);
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
    ImGui::PopFont();
}

// 面板内按“段”排布：段间距由上一帧测得的段内容总高度推算，使内容恰好填满面板高度
// （在 [kSectionGapMin, kSectionGapMax] 内取整）；段内行距固定为 kRowGap。
class SectionFlow {
public:
    SectionFlow(float& fixed_h, int gaps, float gap_min, float gap_max) : fixed_h_(fixed_h), gaps_(gaps) {
        start_y_ = ImGui::GetCursorPosY();
        const float avail = ImGui::GetContentRegionAvail().y;
        gap_ = fixed_h_ > 0.0F ? std::clamp(std::floor((avail - fixed_h_) / static_cast<float>(gaps_)), gap_min, gap_max)
                               : gap_min;
    }
    // 结束当前段；line 为 true 时在段间距中线画分隔线。
    void next(bool line) {
        const float spacing = ImGui::GetStyle().ItemSpacing.y;
        const float bottom = ImGui::GetCursorPosY() - spacing;
        if (line) {
            const ImVec2 p = ImGui::GetCursorScreenPos();
            const float y = std::round(p.y - spacing + gap_ * 0.5F);
            const float w = ImGui::GetContentRegionAvail().x;
            ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x, y), ImVec2(p.x + w, y),
                                                ImGui::GetColorU32(ImGuiCol_Separator));
        }
        ImGui::SetCursorPosY(bottom + gap_);
        ++used_;
    }
    // 面板末尾调用：记录不含段间距的内容高度供下一帧使用；高度变化（例如提示行出现/消失）时返回 true，
    // 调用方应再绘制一帧，让段间距立即按新高度收敛，避免残留滚动条或底部空白。
    [[nodiscard]] bool finish() {
        const float bottom = ImGui::GetCursorPosY() - ImGui::GetStyle().ItemSpacing.y;
        const float measured = std::max(0.0F, bottom - start_y_ - gap_ * static_cast<float>(used_));
        const bool changed = std::abs(measured - fixed_h_) >= 1.0F;
        fixed_h_ = measured;
        return changed;
    }

private:
    float& fixed_h_;
    int gaps_;
    int used_{};
    float start_y_{};
    float gap_{};
};

void caption(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
    ImGui::PushFont(nullptr, layout::kFontCaption);
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

void section_title(const char* text, ImFont* bold, float size = layout::kFontTitle) {
    ImGui::PushFont(bold, size);
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
        {Str::core, "waveout", Str::err_core_waveout},
    };
    for (const auto& mapping : mappings) {
        if (source == mapping.source && detail.find(mapping.token) != std::string::npos) {
            // 核心失败保留机器码，便于对照 dev 日志。
            if (source == Str::core) return std::string(tr(mapping.message)) + "（" + detail + "）";
            return tr(mapping.message);
        }
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

} // namespace

// 面板表单网格（对应 WPF 的 Grid 列）：同一面板内各行共用列边界，标题在上、控件在下，
// 因此不同行的标题与控件左缘严格对齐。fixed > 0 为固定宽度（物理像素），0 为平分剩余宽度。
struct FieldGrid {
    static constexpr int kMaxColumns = 6;
    int count{};
    float x[kMaxColumns]{};
    float w[kMaxColumns]{};

    FieldGrid(float x0, float inner_w, float gap, std::initializer_list<float> fixed) {
        float fixed_sum = 0.0F;
        int stretch = 0;
        for (const float f : fixed) {
            if (count == kMaxColumns) break;
            w[count++] = f;
            if (f > 0.0F) fixed_sum += f;
            else ++stretch;
        }
        const float free_w = std::max(0.0F, inner_w - fixed_sum - gap * static_cast<float>(count - 1));
        const float stretch_w = stretch > 0 ? std::floor(free_w / static_cast<float>(stretch)) : 0.0F;
        float cursor = x0;
        for (int i = 0; i < count; ++i) {
            if (w[i] <= 0.0F) w[i] = stretch_w;
            x[i] = cursor;
            cursor += w[i] + gap;
        }
        // 取整余量给最后一个弹性列之前的列不会改变右缘：让最后一列右缘贴齐 inner_w。
        w[count - 1] = std::max(0.0F, x0 + inner_w - x[count - 1]);
    }
    [[nodiscard]] float span(int col, int n) const { return x[col + n - 1] + w[col + n - 1] - x[col]; }
};

namespace {

class FieldRow {
public:
    FieldRow(const FieldGrid& grid, float caption_h, float row_gap) : grid_(grid) {
        top_ = ImGui::GetCursorPosY();
        control_y_ = top_ + caption_h + row_gap;
    }
    // 在 col 列（跨 n 列）写标题并把光标移到控件位置；返回控件宽度。
    float cell(int col, const char* text, int n = 1) {
        if (text != nullptr && text[0] != '\0') {
            ImGui::SetCursorPos(ImVec2(grid_.x[col], top_));
            caption(text);
        }
        ImGui::SetCursorPos(ImVec2(grid_.x[col], control_y_));
        return grid_.span(col, n);
    }
    void end() const {
        ImGui::SetCursorPos(ImVec2(grid_.x[0], control_y_));
        ImGui::Dummy(ImVec2(0.0F, ImGui::GetFrameHeight()));
    }

private:
    const FieldGrid& grid_;
    float top_{};
    float control_y_{};
};

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

// 0..100 的 Windows 音量滑块（外观同 gain_slider）。changed：本帧数值有变化；active：正在拖动（外部同步暂停覆盖）。
struct PercentSliderResult {
    bool changed{};
    bool active{};
};
PercentSliderResult percent_slider(const char* id, int& value, float width, float scale) {
    const ImVec2 pos = ImGui::GetCursorScreenPos();
    const float h = ImGui::GetFrameHeight();
    const float rail_h = 16.0F * scale;
    const float y0 = pos.y + (h - rail_h) * 0.5F;
    auto* dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(ImVec2(pos.x, y0), ImVec2(pos.x + width, y0 + rail_h), rgb(color::slider_rail), rail_h * 0.5F);
    const float grab_padding = 2.0F;
    const float slider_sz = width - grab_padding * 2.0F;
    const float grab_sz = std::max(slider_sz / 101.0F, ImGui::GetStyle().GrabMinSize);
    const float t = static_cast<float>(std::clamp(value, 0, 100)) / 100.0F;
    const float grab_center = pos.x + grab_padding + grab_sz * 0.5F + t * (slider_sz - grab_sz);
    dl->AddRectFilled(ImVec2(pos.x, y0), ImVec2(grab_center, y0 + rail_h), rgb(color::slider_fill), rail_h * 0.5F,
                      ImDrawFlags_RoundCornersLeft);
    ImGui::PushStyleColor(ImGuiCol_FrameBg, IM_COL32(0, 0, 0, 0));
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, IM_COL32(255, 255, 255, 12));
    ImGui::PushStyleColor(ImGuiCol_FrameBgActive, IM_COL32(255, 255, 255, 20));
    ImGui::PushStyleColor(ImGuiCol_SliderGrab, vec(0xFFFFFF));
    ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, vec(0xDDE7FF));
    ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(0, 0, 0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, h * 0.5F);
    ImGui::PushStyleVar(ImGuiStyleVar_GrabRounding, h * 0.5F);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0F);
    ImGui::SetNextItemWidth(width);
    PercentSliderResult r;
    r.changed = ImGui::SliderInt(id, &value, 0, 100, "%d", ImGuiSliderFlags_AlwaysClamp);
    r.active = ImGui::IsItemActive();
    ImGui::PopStyleVar(3);
    ImGui::PopStyleColor(6);
    return r;
}

// 状态行圆点项：圆点 + 文字作为一个整体（一个 item，悬停提示覆盖两者），与 row_text 同样按行高居中。
void status_dot(const Row& row, ImU32 dot_col, ImU32 text_col, const char* label) {
    const float h = ImGui::GetTextLineHeight();
    const float dot_w = std::round(h * 0.7F);
    const float gap = 2.0F;
    row.place(h);
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const ImVec2 text_sz = ImGui::CalcTextSize(label);
    ImGui::Dummy(ImVec2(dot_w + gap + text_sz.x, h));
    auto* draw = ImGui::GetWindowDrawList();
    draw->AddCircleFilled(ImVec2(p.x + std::round(h * 0.3F), p.y + std::round(h * 0.5F)), h * 0.22F, dot_col);
    draw->AddText(ImVec2(p.x + dot_w + gap, p.y), text_col, label);
}

ImU32 dot_on(bool on) { return on ? rgb(color::green) : rgb(0x5A666C); }
ImU32 dot_text(bool on) { return on ? rgb(color::text) : rgb(color::muted); }

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

// 来话三栏共用：相同内边距 + 相同标题行高，使三栏标题与“设为PTT目标”按钮处在同一水平线上。
void begin_call_card(const char* id, float width, float height, ImVec2 padding) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, padding);
    ImGui::BeginChild(id, ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
}

Row card_title_row(const char* text, ImFont* bold, float row_h) {
    const Row row = begin_row(row_h);
    row_text(row, text, rgb(color::text), bold, layout::kFontTitle);
    return row;
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
    const float gap = px(layout::kGap);
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
    draw_static_remove_modal();
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
    // 核心异常停止：标题栏优先显示失败原因（友好文案 + 机器码），直到重新启动。
    const std::string engine_banner = vm_.engine_failure_banner();
    const ConnectionLogEntry banner_entry{std::string{}, Str::core, engine_banner, true, false};
    if (!engine_banner.empty()) summary = &banner_entry;
    const bool summary_error = summary && summary->failed && !summary->resolved;
    std::string summary_text;
    if (summary) {
        summary_text = fmt("%s · %s", tr(summary->source), summary->message.c_str());
        if (summary->failed && summary->resolved) summary_text += fmt(" · %s", tr(Str::log_resolved));
    }
    const float row_h = px(layout::kHeaderHeight);
    const float btn_h = px(layout::kHeaderButtonHeight);
    const float inline_gap = px(layout::kInlineGap);
    // 右侧四个按钮：等高、等间距；列宽由按钮宽度推算，避免魔法总宽度。
    const float lang_w = px(64.0F);
    const float action_w = px(108.0F);
    const float log_w = px(48.0F);
    // 中继开启时在“停用中继”右侧追加 FM 开关与“官方未支持”标注（宽度取上一帧实测值）。
    const bool relay_on = vm_.relay_enabled();
    const float fm_group_w = relay_on ? (header_relay_w_ > 0.0F ? header_relay_w_ : px(150.0F)) + inline_gap : 0.0F;
    const float actions_w = lang_w + action_w * 2.0F + log_w + inline_gap * 3.0F + fm_group_w;
    if (ImGui::BeginTable("##header", 3, ImGuiTableFlags_SizingStretchProp | ImGuiTableFlags_NoPadOuterX |
                                           ImGuiTableFlags_NoBordersInBody)) {
        ImGui::TableSetupColumn("##title", ImGuiTableColumnFlags_WidthStretch, 1.0F);
        ImGui::TableSetupColumn("##status", ImGuiTableColumnFlags_WidthStretch, 1.1F);
        ImGui::TableSetupColumn("##actions", ImGuiTableColumnFlags_WidthFixed, actions_w);
        ImGui::TableNextRow(ImGuiTableRowFlags_None, row_h);

        // 同一行内所有元素按 row_h 垂直居中（各列共用行顶）。
        ImGui::TableSetColumnIndex(0);
        const Row row{ImGui::GetCursorPosX(), ImGui::GetCursorPosY(), row_h};
        row_text(row, tr(Str::app_title), rgb(color::text), fonts_.bold, 19.0F);
        if (vm_.fake()) {
            ImGui::SameLine(0.0F, px(layout::kTitleGap));
            row_text(row, fmt("[%s]", tr(Str::fake_banner)).c_str(), rgb(color::warn), nullptr, layout::kFontBody);
        }

        // RTT/丢包：连接日志摘要显示时靠右，否则与 BM/核心状态一起居中；宽度取上一帧实测值。
        const auto draw_net_metrics = [&]() {
            const float metrics_x0 = ImGui::GetCursorScreenPos().x;
            const auto& net = s.network;
            row_text(row, tr(Str::rtt), rgb(color::muted), nullptr, layout::kFontCaption);
            ImGui::SameLine(0.0F, px(layout::kLabelGap));
            const auto rtt_text = net.rtt_valid ? fmt(tr(Str::rtt_value_fmt), static_cast<unsigned long long>(net.rtt_last_ms))
                                                : std::string("—");
            row_text(row, rtt_text.c_str(), net.rtt_valid ? rgb(color::text) : rgb(color::muted), nullptr, layout::kFontBody);
            if (net.rtt_valid) {
                ImGui::SetItemTooltip(tr(Str::rtt_tip_fmt), static_cast<unsigned long long>(net.rtt_last_ms),
                                      static_cast<unsigned long long>(net.rtt_min_ms), net.rtt_avg_ms,
                                      static_cast<unsigned long long>(net.rtt_max_ms),
                                      static_cast<unsigned long long>(net.rtt_samples));
            } else {
                ImGui::SetItemTooltip("%s", tr(Str::rtt_tip_none));
            }
            ImGui::SameLine(0.0F, px(layout::kGroupGap));
            const auto percent = [](std::uint64_t missing, std::uint64_t expected) {
                return expected == 0U ? 0.0 : 100.0 * static_cast<double>(missing) / static_cast<double>(expected);
            };
            const bool loss_ok = net.session_loss_valid && net.session_expected != 0U;
            const double loss_pct = loss_ok ? percent(net.session_missing, net.session_expected) : 0.0;
            row_text(row, tr(Str::loss), rgb(color::muted), nullptr, layout::kFontCaption);
            ImGui::SameLine(0.0F, px(layout::kLabelGap));
            const auto loss_text = loss_ok ? fmt(tr(Str::loss_value_fmt), loss_pct) : std::string("—");
            row_text(row, loss_text.c_str(),
                     !loss_ok ? rgb(color::muted) : loss_pct >= 5.0 ? rgb(color::error) : loss_pct >= 1.0 ? rgb(color::warn)
                                                                                                         : rgb(color::text),
                     nullptr, layout::kFontBody);
            {
                std::string tip = loss_ok ? fmt(tr(Str::loss_tip_session_fmt),
                                                static_cast<unsigned long long>(net.session_missing),
                                                static_cast<unsigned long long>(net.session_expected), loss_pct)
                                          : std::string(tr(Str::loss_tip_session_none));
                if (s.active_rx_call) {
                    tip += "\n";
                    tip += net.call_loss_valid && net.call_expected != 0U
                               ? fmt(tr(Str::loss_tip_call_fmt), static_cast<unsigned long long>(net.call_missing),
                                     static_cast<unsigned long long>(net.call_expected),
                                     percent(net.call_missing, net.call_expected))
                               : std::string(tr(Str::loss_tip_call_none));
                }
                ImGui::SetItemTooltip("%s", tip.c_str());
            }
            const float measured = std::round(ImGui::GetItemRectMax().x - metrics_x0);
            if (std::abs(measured - header_metrics_w_) >= 1.0F) {
                header_metrics_w_ = measured;
                continuous_ = true;
            }
        };

        ImGui::TableSetColumnIndex(1);
        if (summary) {
            const float metrics_w = header_metrics_w_ > 0.0F ? header_metrics_w_ : px(160.0F);
            const float column_right = ImGui::GetCursorPosX() + ImGui::GetContentRegionAvail().x;
            row_text(row, tr(summary_error ? Str::log_error : Str::log_events), rgb(color::muted), nullptr,
                     layout::kFontCaption);
            ImGui::SameLine(0.0F, inline_gap);
            const float clear_w = summary_error ? px(layout::kRowHeight) + px(layout::kRowGap) : 0.0F;
            const float available = std::max(px(24.0F), ImGui::GetContentRegionAvail().x - clear_w - metrics_w -
                                                             px(layout::kGroupGap));
            ImGui::PushFont(nullptr, layout::kFontBody);
            row.place(ImGui::GetTextLineHeight());
            text_ellipsis(summary_text.c_str(), available, rgb(summary_error ? color::error : color::muted));
            ImGui::PopFont();
            ImGui::SetItemTooltip("%s", summary_text.c_str());
            if (summary_error) {
                ImGui::SameLine(0.0F, px(layout::kRowGap));
                row.place(px(layout::kRowHeight));
                if (button("×##clear-error", ImVec2(px(layout::kRowHeight), px(layout::kRowHeight)))) {
                    connection_events_.clear();
                }
                ImGui::SetItemTooltip("%s", tr(Str::log_clear));
            }
            // 表格单元格内 SameLine(offset) 会叠加列偏移；先 SameLine 再按光标坐标右对齐。
            ImGui::SameLine(0.0F, px(layout::kGroupGap));
            ImGui::SetCursorPosX(std::max(ImGui::GetCursorPosX(), column_right - metrics_w));
            draw_net_metrics();
        } else {
            // 宽度取上一帧实测值（首帧用估计值），使状态组在列内居中。
            const float status_w = header_status_w_ > 0.0F ? header_status_w_ : px(470.0F);
            const float status_x = ImGui::GetCursorPosX() + std::max(0.0F, (ImGui::GetContentRegionAvail().x - status_w) * 0.5F);
            ImGui::SetCursorPosX(status_x);
            const float status_screen_x = ImGui::GetCursorScreenPos().x;
            const bool bm_ok = s.bm_link == BmLink::connected;
            const bool bm_bad = s.bm_link == BmLink::failed || s.bm_link == BmLink::backoff;
            const bool core_ok = s.phase == Phase::running;
            row_text(row, tr(Str::brandmeister), rgb(color::muted), nullptr, layout::kFontCaption);
            ImGui::SameLine(0.0F, px(layout::kLabelGap));
            const bool bm_stale = vm_.bm_stale_session_retry_s().has_value();
            row_text(row, bm_stale ? tr(Str::bm_waiting_release) : bm_short_text(s.bm_link),
                     bm_ok ? rgb(color::green) : bm_bad || bm_stale ? rgb(color::warn) : rgb(color::text),
                     fonts_.bold, layout::kFontBody);
            if (const auto retry = vm_.bm_stale_session_retry_s()) {
                ImGui::SetItemTooltip("%s", *retry == 0U ? tr(Str::bm_stale_retrying)
                                                         : fmt(tr(Str::bm_stale_retry_fmt), *retry).c_str());
            }
            ImGui::SameLine(0.0F, px(layout::kGroupGap));
            draw_net_metrics();
            ImGui::SameLine(0.0F, px(layout::kGroupGap));
            row_text(row, tr(Str::core), rgb(color::muted), nullptr, layout::kFontCaption);
            ImGui::SameLine(0.0F, px(layout::kLabelGap));
            row_text(row, phase_short_text(s.phase),
                     core_ok ? rgb(color::green) : s.phase == Phase::failed ? rgb(color::error) : rgb(color::text),
                     fonts_.bold, layout::kFontBody);
            if (s.phase == Phase::failed && !s.failure_reason.empty()) ImGui::SetItemTooltip("%s", s.failure_reason.c_str());
            else ImGui::SetItemTooltip("%s", phase_text(s));
            const float measured = std::round(ImGui::GetItemRectMax().x - status_screen_x);
            if (std::abs(measured - header_status_w_) >= 1.0F) {
                header_status_w_ = measured;
                continuous_ = true; // 再绘一帧让居中按实测宽度收敛
            }
        }

        ImGui::TableSetColumnIndex(2);
        row.place(btn_h);
        if (button(language() == Language::zh_cn ? tr(Str::language_english) : tr(Str::language_chinese),
                   ImVec2(lang_w, btn_h))) toggle_language();
        if (!language_notice_.empty()) {
            ImGui::SetItemTooltip("%s", language_notice_.c_str());
        } else if (vm_.font_status() == FontStatus::segoe_simhei) {
            ImGui::SetItemTooltip("%s", tr(Str::font_simhei));
        } else if (vm_.font_status() == FontStatus::fallback_default) {
            ImGui::SetItemTooltip("%s", tr(Str::font_default));
        }
        ImGui::SameLine(0.0F, inline_gap);
        row.place(btn_h);
        if (button(fmt("%s##relay-toggle", tr(relay_on ? Str::relay_disable : Str::relay_enable)).c_str(),
                   ImVec2(action_w, btn_h), relay_on ? Tone::ok : Tone::normal)) {
            vm_.toggle_relay();
        }
        ImGui::SetItemTooltip("%s", tr(relay_on ? Str::relay_tip_on : Str::relay_tip_off));
        ImGui::SameLine(0.0F, inline_gap);
        if (relay_on) {
            draw_relay_fm_controls(row.x0, row.top, row.h, btn_h);
            ImGui::SameLine(0.0F, inline_gap);
        }
        row.place(btn_h);
        if (button(tr(Str::stop_exit), ImVec2(action_w, btn_h), Tone::stop)) {
            if (vm_.snapshot().phase != Phase::stopped || vm_.cat().connected || vm_.cat().busy) vm_.stop();
            vm_.request_exit();
        }
        ImGui::SameLine(0.0F, inline_gap);
        row.place(btn_h);
        const auto log_label = fmt("≡ %zu##connection-log", connection_events_.size());
        if (button(log_label.c_str(), ImVec2(log_w, btn_h), Tone::normal,
                   !connection_events_.empty())) {
            ImGui::OpenPopup("##connection-log");
        }
        ImGui::SetItemTooltip("%s (%zu)", tr(Str::log_events), connection_events_.size());
        ImGui::EndTable();
    }

    draw_connection_log_popup();
    const ImVec2 pos = ImGui::GetCursorPos();
    ImGui::SetCursorPos(ImVec2(pos.x, pos.y + px(layout::kGap)));
}

// FM 开关（中继开启时显示在“停用中继”右侧）。状态并入按钮本身：
// 关闭“○ FM”；开启后“● FM · 等待静噪开启 / FM 中继进行中 / CAT 未连接”，颜色随状态；
// “官方未支持”与 C4FM 未支持提示放在 tooltip，避免在标题栏下方再插一行而推移整页布局。
void AppView::draw_relay_fm_controls(float row_x, float row_top, float row_h, float btn_h) {
    const Row row{row_x, row_top, row_h};
    const float x0 = ImGui::GetCursorScreenPos().x;
    const bool fm_on = vm_.relay_fm_enabled();
    const bool supported = vm_.relay_fm_supported();
    const auto status = vm_.relay_status();
    std::string label = std::string(fm_on ? "● " : "○ ") + tr(Str::relay_fm);
    Tone tone = Tone::normal;
    if (fm_on) {
        switch (status) {
        case RelayStatus::active: label += std::string(" · ") + tr(Str::relay_status_active); tone = Tone::ok; break;
        case RelayStatus::waiting: label += std::string(" · ") + tr(Str::relay_status_waiting); tone = Tone::ok; break;
        case RelayStatus::no_cat: label += std::string(" · ") + tr(Str::relay_status_no_cat); tone = Tone::normal; break;
        case RelayStatus::off:
        case RelayStatus::c4fm_only: break;
        }
    }
    label += "##relay-fm";
    row.place(btn_h);
    const float text_w = ImGui::CalcTextSize(label.c_str(), nullptr, true).x;
    const float w = std::max(px(54.0F), std::round(text_w + px(20.0F)));
    if (button(label.c_str(), ImVec2(w, btn_h), tone, supported)) vm_.toggle_relay_fm();
    std::string tip = tr(Str::relay_fm_tip);
    if (!fm_on) tip = std::string(tr(Str::relay_c4fm_unsupported)) + "\n" + tip;
    if (fm_on && (vm_.config().hri_mode == hri_y::LchMode::c4fm_dn ||
                  (vm_.snapshot().hri_ready && vm_.snapshot().hri_y_lch_mode == hri_y::LchMode::c4fm_dn))) {
        tip += std::string("\n") + tr(Str::hri_c4fm_voice_warning);
    }
    ImGui::SetItemTooltip("%s", tip.c_str());
    const float measured = std::round(ImGui::GetItemRectMax().x - x0);
    if (std::abs(measured - header_relay_w_) >= 1.0F) {
        header_relay_w_ = measured;
        continuous_ = true;
    }
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
        if (s.bm_error == "master_rejected" && vm_.bm_stale_session_retry_s()) {
            // 服务器尚未释放上次会话：ViewModel 自动重试，不记为失败。
            const auto retry = *vm_.bm_stale_session_retry_s();
            add_connection_event(Str::brandmeister, fmt(tr(Str::bm_stale_retry_fmt), retry), false);
        } else if (!s.bm_error.empty() && s.bm_error != "none") {
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
            } else if (s.bm_link == BmLink::failed && !vm_.bm_stale_session_retry_s()) {
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
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(layout::kCardPad), px(layout::kCardPad)));
    ImGui::BeginChild("##channels", ImVec2(0.0F, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    const bool paged = vm_.channel_page_count() > 1U;
    const ImVec2 avail = ImGui::GetContentRegionAvail();
    const float gap = px(layout::kGap);
    const float nav_button_h = paged ? px(layout::kRowHeight) : 0.0F;
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
        const float bw = px(layout::kPagerWidth);
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
                             : ch.is_disabled  ? color::card_muted
                                               : color::panel;
    const std::uint32_t call_bg = ch.is_tx_active   ? color::call_tx_active
                                  : ch.is_tx_target ? color::call_tx_selected
                                  : ch.current_call ? color::call_active
                                                    : color::inset;
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(ch.current_call ? color::green : color::line));
    // 卡片四边内边距一致；标题行固定 kRowHeight，按钮列宽度对所有卡片相同（卡片等宽），因此各卡按钮列对齐。
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(layout::kCardPad), px(layout::kCardPad)));
    ImGui::BeginChild("##card", ImVec2(width, height), ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleVar();

    const ImVec2 inner = ImGui::GetContentRegionAvail();
    // 标题行：频道名 + 右侧状态徽标，按 kRowHeight 垂直居中
    const Row title_row = begin_row(px(layout::kRowHeight));
    ImGui::PushFont(fonts_.bold, 15.0F);
    title_row.place(ImGui::GetTextLineHeight());
    // 右上角：状态徽标（静态组 / 静音 / 动态·已激活 / 动态·未激活 / 已停用）+ 发射/PTT 徽标。
    struct Badge {
        const char* text;
        ImU32 bg;
        ImU32 fg;
    };
    std::vector<Badge> badges;
    switch (ch.state) {
    case ChannelState::static_live: badges.push_back({tr(Str::ch_badge_static), rgb(0x2E5E8A), rgb(0xFFFFFF)}); break;
    case ChannelState::static_muted: badges.push_back({tr(Str::ch_badge_muted), rgb(0x8A6A2E), rgb(0xFFFFFF)}); break;
    case ChannelState::dynamic_active: badges.push_back({tr(Str::ch_badge_dyn_active), rgb(0x3E8A5C), rgb(0xFFFFFF)}); break;
    case ChannelState::dynamic_inactive: badges.push_back({tr(Str::ch_badge_dyn_inactive), rgb(0x3D484D), rgb(0xD0D6D9)}); break;
    case ChannelState::disabled: badges.push_back({tr(Str::ch_badge_disabled), rgb(0x2A3236), rgb(0x8A969B)}); break;
    case ChannelState::listen: break;
    }
    if (ch.is_tx_active) {
        badges.push_back({tr(Str::tx_active_badge), rgb(0xC0474F), rgb(0xFFFFFF)});
    } else if (ch.is_tx_target) {
        badges.push_back({"PTT", rgb(0x3E8A5C), rgb(0xFFFFFF)});
    }
    ImGui::PushFont(fonts_.bold, 12.0F);
    const float badge_pad = px(5.0F);
    const float badge_gap = px(3.0F);
    float badges_w = 0.0F;
    for (const auto& b : badges) badges_w += ImGui::CalcTextSize(b.text).x + badge_pad * 2.0F + badge_gap;
    ImGui::PopFont();
    text_ellipsis(ch.title.c_str(), inner.x - badges_w - px(2.0F), ch.is_disabled ? rgb(0x8A969B) : rgb(0xFFFFFF));
    ImGui::SetItemTooltip("%s", ch.tooltip.c_str());
    if (!badges.empty()) {
        ImGui::PushFont(fonts_.bold, 12.0F);
        float x = ImGui::GetCursorStartPos().x + inner.x - badges_w + badge_gap;
        for (const auto& b : badges) {
            const ImVec2 sz = ImGui::CalcTextSize(b.text);
            ImGui::SameLine(x);
            title_row.place(sz.y);
            const ImVec2 p = ImGui::GetCursorScreenPos();
            ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(p.x, p.y - px(2.0F)),
                                                      ImVec2(p.x + sz.x + badge_pad * 2.0F, p.y + sz.y + px(2.0F)),
                                                      b.bg, px(3.0F));
            ImGui::SetCursorScreenPos(ImVec2(p.x + badge_pad, p.y));
            ImGui::PushStyleColor(ImGuiCol_Text, ImGui::ColorConvertU32ToFloat4(b.fg));
            ImGui::TextUnformatted(b.text);
            ImGui::PopStyleColor();
            ImGui::SetItemTooltip("%s", ch.tooltip.c_str());
            x += sz.x + badge_pad * 2.0F + badge_gap;
        }
        ImGui::PopFont();
    }
    ImGui::PopFont();
    title_row.end();

    // 来话区（左）+ 操作按钮 2×2（右）
    const float content_h = ImGui::GetContentRegionAvail().y;
    const float buttons_w = std::floor(std::min(px(190.0F), inner.x * 0.42F));
    const float call_w = inner.x - buttons_w - px(layout::kGap);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(call_bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(color::call_border));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(layout::kCardPad), px(layout::kRowGap)));
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

    ImGui::SameLine(0.0F, px(layout::kGap));
    ImGui::BeginGroup();
    const float bgap = px(layout::kRowGap);
    const ImVec2 bsize(std::floor((buttons_w - bgap) * 0.5F), std::floor((content_h - bgap) * 0.5F));
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
    if (button(tr(Str::btn_remove_short), bsize, Tone::normal, can_mutate)) {
        if (ch.is_static) {
            static_remove_confirm_ = ch.key; // 静态组：先确认是否同时从 BM 移除
        } else {
            vm_.remove_channel(ch.key);
        }
    }
    // 主操作按钮（整行宽）：按状态机显示 静音/取消静音（静态组）或 停用/启用（动态组、其它频道）。
    {
        const bool bm_ready = vm_.snapshot().bm_link == BmLink::connected;
        const bool qc_busy = vm_.pending(Str::op_quick_call) || vm_.pending(Str::op_disconnect_dynamic) ||
                             vm_.startup_group_activation_active();
        const char* label = tr(Str::ch_btn_disable);
        const char* tip = tr(Str::ch_tip_disable_listen);
        bool enabled = can_mutate;
        Tone tone = Tone::normal;
        switch (ch.state) {
        case ChannelState::static_live:
            label = tr(Str::ch_btn_mute);
            tip = tr(Str::ch_tip_mute);
            break;
        case ChannelState::static_muted:
            label = tr(Str::ch_btn_unmute);
            tip = tr(Str::ch_tip_unmute);
            tone = Tone::ok;
            break;
        case ChannelState::dynamic_active:
            label = ch.quick_call_pending ? tr(Str::ch_btn_working) : tr(Str::ch_btn_disable);
            tip = tr(Str::ch_tip_disable);
            enabled = can_mutate && !qc_busy;
            break;
        case ChannelState::dynamic_inactive:
            label = ch.quick_call_pending ? tr(Str::ch_btn_working) : tr(Str::ch_btn_enable);
            tip = bm_ready ? tr(Str::ch_tip_enable) : tr(Str::ch_tip_need_bm);
            enabled = can_mutate && !qc_busy && bm_ready;
            tone = Tone::ok;
            break;
        case ChannelState::disabled:
            label = tr(Str::ch_btn_enable);
            tip = ch.quick_call_allowed ? tr(Str::ch_tip_enable) : tr(Str::ch_tip_enable_listen);
            enabled = can_mutate && (!ch.quick_call_allowed || !qc_busy);
            tone = Tone::ok;
            break;
        case ChannelState::listen:
            break;
        }
        if (button(fmt("%s##primary", label).c_str(), ImVec2(bsize.x * 2.0F + bgap, bsize.y), tone, enabled)) {
            vm_.channel_primary_action(ch.key);
        }
        ImGui::SetItemTooltip("%s", tip);
    }
    ImGui::PopFont();
    ImGui::PopStyleVar(2);
    ImGui::EndGroup();

    ImGui::EndChild();
    ImGui::PopStyleColor(2);
}

void AppView::begin_panel(const char* id, float width, float height) {
    // 不强制滚动条：1360×900 下内容由 SectionFlow 恰好放下；窗口更小时 ImGui 自动出现滚动条。
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(layout::kPanelPadX), px(layout::kPanelPadY)));
    ImGui::BeginChild(id, ImVec2(width, height), ImGuiChildFlags_Borders);
    ImGui::PopStyleVar();
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(px(layout::kInlineGap), px(layout::kInlineGap)));
}

void AppView::end_panel() {
    ImGui::PopStyleVar();
    ImGui::EndChild();
}

ImVec2 AppView::call_card_padding() const noexcept {
    return ImVec2(px(layout::kCardPad), px(layout::kCardPad));
}

void AppView::draw_calls(float height) {
    const float gap = px(layout::kGap);
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
    begin_call_card("##history", width, height, call_card_padding());
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const float bh = px(layout::kRowHeight);
    const Row title = card_title_row(tr(Str::call_history), fonts_.bold, px(layout::kRowHeight));
    ImGui::SameLine(0.0F, px(layout::kTitleGap));
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(layout::kInlineGap), 0.0F));
    const auto page = vm_.history_page_index();
    const auto pages = vm_.history_page_count();
    title.place(bh);
    if (button("‹##hprev", ImVec2(px(layout::kPagerWidth), bh), Tone::normal, page > 0U)) vm_.set_history_page(page - 1U);
    ImGui::SameLine();
    row_text(title, fmt("%zu / %zu", page + 1U, pages).c_str(), rgb(color::muted), nullptr, layout::kFontCaption);
    ImGui::SameLine();
    title.place(bh);
    if (button("›##hnext", ImVec2(px(layout::kPagerWidth), bh), Tone::normal, page + 1U < pages)) vm_.set_history_page(page + 1U);
    const float target_w = px(layout::kActionWidth);
    ImGui::SameLine(inner_w - target_w + ImGui::GetCursorStartPos().x);
    title.place(bh);
    if (button(tr(Str::set_history_target), ImVec2(target_w, bh), Tone::normal,
               vm_.selected_history().has_value() && vm_.can_mutate_channels())) {
        vm_.set_history_target();
    }
    ImGui::SetItemTooltip("%s", tr(Str::tip_history_target));
    ImGui::PopStyleVar();
    title.end();

    const auto& history = vm_.history();
    ImGui::PushFont(nullptr, layout::kFontBody);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0.0F, px(1.0F)));
    const std::size_t begin = page * ViewModel::history_page_size;
    for (std::size_t i = begin; i < history.size() && i < begin + ViewModel::history_page_size; ++i) {
        const auto& rec = history[i];
        const auto clock = format_clock(rec.started_wall);
        std::string text;
        if (rec.relay_fm) {
            // FM 中继：无呼号；以“FM 中继 →”前缀与警示色区分 BM 来话。
            const auto peak = rec.relay_s_peak ? std::to_string(*rec.relay_s_peak) : std::string("—");
            const double secs = static_cast<double>(rec.relay_duration_ms) / 1000.0;
            text = rec.call.kind == dmr_call::CallKind::group
                       ? fmt(tr(Str::relay_history_group_fmt), clock.c_str(), rec.call.destination_id,
                             static_cast<int>(rec.call.slot), secs, peak.c_str())
                       : fmt(tr(Str::relay_history_private_fmt), clock.c_str(), rec.call.destination_id,
                             static_cast<int>(rec.call.slot), secs, peak.c_str());
        } else {
            const auto from = source_label(vm_.with_callsign(rec.call));
            text = rec.call.kind == dmr_call::CallKind::group
                       ? fmt(tr(Str::history_group), clock.c_str(), rec.call.destination_id, from.c_str())
                       : fmt(tr(Str::history_private), clock.c_str(), rec.call.destination_id, from.c_str());
        }
        ImGui::PushID(static_cast<int>(i));
        const bool selected = vm_.selected_history() == i;
        const float row_h = ImGui::GetTextLineHeightWithSpacing();
        const bool clicked = ImGui::Selectable("##history-row", selected, ImGuiSelectableFlags_None, ImVec2(inner_w, row_h));
        const ImVec2 row_pos = ImGui::GetItemRectMin();
        ImGui::SetCursorScreenPos(row_pos);
        text_ellipsis(text.c_str(), inner_w, rec.relay_fm ? rgb(color::warn) : rgb(color::text));
        if (rec.relay_fm) {
            const auto tip = text + "\n" + fmt(tr(Str::relay_history_tip),
                                               rec.relay_end_reason.empty() ? "—" : rec.relay_end_reason.c_str());
            ImGui::SetItemTooltip("%s", tip.c_str());
        } else {
            ImGui::SetItemTooltip("%s", text.c_str());
        }
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
    begin_call_card("##current", width, height, call_card_padding());
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const Row title = card_title_row(tr(Str::current_call), fonts_.bold, px(layout::kRowHeight));
    if (rx) {
        if (auto started = vm_.current_call_started()) {
            const auto secs = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now() - *started).count();
            const auto dur = fmt("%02lld:%02lld", static_cast<long long>(secs / 60), static_cast<long long>(secs % 60));
            ImGui::PushFont(nullptr, layout::kFontBody);
            const float dur_w = ImGui::CalcTextSize(dur.c_str()).x;
            ImGui::PopFont();
            ImGui::SameLine(inner_w - dur_w + ImGui::GetCursorStartPos().x);
            row_text(title, dur.c_str(), rgb(color::green), nullptr, layout::kFontBody);
        }
    }
    title.end();
    if (rx) {
        const auto& call = *active;
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
    begin_call_card("##recent", width, height, call_card_padding());
    const float inner_w = ImGui::GetContentRegionAvail().x;
    card_title_row(tr(Str::recent_calls), fonts_.bold, px(layout::kRowHeight)).end();
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
            ImGui::SameLine(0.0F, px(layout::kTitleGap));
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::link));
            ImGui::Text("%u", rec.call.source_id);
            ImGui::PopStyleColor();
        }
        ImGui::SameLine(inner_w - clock_w + ImGui::GetCursorStartPos().x);
        caption(clock.c_str());
    }
    ImGui::EndChild();
}

void AppView::draw_radio_panel(float width, float height) {
    begin_panel("##radio", width, height);
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const float row_gap = px(layout::kRowGap);
    const float caption_h = line_height(nullptr, layout::kFontCaption);
    const float frame_h = ImGui::GetFrameHeight();
    const float inline_gap = px(layout::kInlineGap);
    const float action_w = px(layout::kActionWidth);
    // 全面板共用一套 6 列网格：首尾为固定按钮列，中间 4 列平分；每行的控件都按整列跨度放置，
    // 因此所有行的标题与控件左缘落在同一组列边界上。
    const FieldGrid grid(ImGui::GetCursorPosX(), inner_w, inline_gap,
                         {action_w, 0.0F, 0.0F, 0.0F, 0.0F, action_w});
    SectionFlow flow(radio_fixed_h_, 2, px(layout::kSectionGapMin), px(layout::kSectionGapMax));
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
    // 引擎已停止时最后一份快照可能残留连接标志；按停止处理（按钮显示“连接”）。
    const bool engine_down = vm_.engine_stopped();
    const bool radio_active = !engine_down && (s.serial_open || s.hri_ready || cat.connected || cat.busy);
    const bool radio_idle = !radio_active && !cat.busy;
    const bool radio_start_pending = vm_.pending(Str::op_start);
    const bool radio_stop_pending = vm_.pending(Str::op_stop);
    const bool radio_cancelable = radio_start_pending || (s.phase == Phase::starting && !radio_active);
    const bool port_settings_enabled = radio_idle && s.phase != Phase::starting && s.phase != Phase::stopping &&
                                       !radio_start_pending && !radio_stop_pending;
    const bool radio_connecting = !engine_down && (cat.busy || (s.serial_open && !s.hri_ready));
    const char* radio_label = radio_stop_pending || s.phase == Phase::stopping ? tr(Str::disconnecting_serial)
                              : radio_cancelable ? tr(Str::disconnect_serial)
                              : radio_connecting ? tr(Str::connecting_radio)
                              : radio_active ? tr(Str::disconnect_serial) : tr(Str::connect_serial);
    const bool radio_button_enabled = s.phase != Phase::stopping && !radio_stop_pending;
    {
        FieldRow row(grid, caption_h, row_gap);
        float cell_w = row.cell(0, tr(Str::radio_link));
        if (button(radio_label, ImVec2(cell_w, frame_h),
                   (radio_active || radio_cancelable) ? Tone::normal : Tone::ok,
                   radio_button_enabled)) toggle_radio();
        ImGui::SetItemTooltip("%s", tr(Str::radio_link_hint));
        cell_w = row.cell(1, tr(Str::wiresx_port), 2);
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
                         static_cast<int>(hri_port_items.size()), cell_w, "", hri_port_item_ids.data())) {
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
        cell_w = row.cell(3, tr(Str::cat_port), 2);
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
                         static_cast<int>(cat_port_items.size()), cell_w, "", cat_port_item_ids.data())) {
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
        cell_w = row.cell(5, tr(Str::baud_rate));
        static const char* const baud_labels[] = {"4800", "9600", "19200", "38400", "115200"};
        if (simple_combo("##baud", vm_.cat_form.baud_index, baud_labels, 5, cell_w)) {
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
        row.end();
    }

    // MAIN 模式 / 频率 / 功率 / 应用（CAT，与串口行同属电台段）
    ImGui::BeginDisabled(!cat.connected || cat.busy);
    {
        FieldRow row(grid, caption_h, row_gap);
        const bool digital_mode = vm_.cat_form.mode_index == 2;
        float cell_w = row.cell(0, digital_mode ? nullptr : tr(Str::main_mode));
        if (digital_mode) {
            const ImVec2 control_pos = ImGui::GetCursorPos();
            ImGui::SetCursorPos(ImVec2(control_pos.x, control_pos.y - caption_h - row_gap));
            ImGui::PushFont(nullptr, layout::kFontCaption);
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::warn));
            ImGui::TextUnformatted(tr(Str::hri_c4fm_voice_short));
            ImGui::PopStyleColor();
            ImGui::SetItemTooltip("%s", tr(Str::hri_c4fm_voice_warning));
            ImGui::PopFont();
            ImGui::SetCursorPos(control_pos);
        }
        const bool mode_changed = simple_combo("##mode", vm_.cat_form.mode_index, kCatModes, 4, cell_w,
                                               tr(Str::unknown));
        vm_.set_cat_form_editing(CatFormField::mode, ImGui::IsItemActive());
        if (vm_.cat_form.mode_index == 2) {
            ImGui::SetItemTooltip("%s", tr(Str::hri_c4fm_voice_warning));
        } else if (vm_.snapshot().hri_ready) {
            ImGui::SetItemTooltip("%s", tr(Str::hri_channel_tooltip));
        }
        if (mode_changed) vm_.mark_cat_form_edited(CatFormField::mode);
        cell_w = row.cell(1, tr(Str::frequency_mhz), 2);
        ImGui::SetNextItemWidth(cell_w);
        const bool frequency_changed = input_text("##freq", vm_.cat_form.frequency_mhz,
                                                   ImGuiInputTextFlags_CharsDecimal);
        vm_.set_cat_form_editing(CatFormField::frequency, ImGui::IsItemActive());
        if (vm_.snapshot().hri_ready) ImGui::SetItemTooltip("%s", tr(Str::hri_channel_tooltip));
        if (frequency_changed) vm_.mark_cat_form_edited(CatFormField::frequency);
        cell_w = row.cell(3, tr(Str::power_w), 2);
        static const char* const power_labels[] = {"5 W", "10 W", "15 W", "25 W", "50 W"};
        const bool power_changed = simple_combo("##power", vm_.cat_form.power_index, power_labels, 5, cell_w,
                                                tr(Str::unknown));
        vm_.set_cat_form_editing(CatFormField::power, ImGui::IsItemActive());
        if (vm_.snapshot().hri_ready) ImGui::SetItemTooltip("%s", tr(Str::hri_power_tooltip));
        if (power_changed) vm_.mark_cat_form_edited(CatFormField::power);
        cell_w = row.cell(5, nullptr);
        const bool cat_form_valid = vm_.cat_form.mode_index >= 0 && vm_.cat_form.mode_index < 4 &&
                                    vm_.cat_form.power_index >= 0 && vm_.cat_form.power_index < 5;
        if (button(tr(Str::apply), ImVec2(cell_w, frame_h), Tone::normal, cat_form_valid)) vm_.cat_apply();
        row.end();
    }
    ImGui::EndDisabled();
    if (!vm_.cat_deferred_text().empty()) {
        ImGui::PushFont(nullptr, layout::kFontCaption);
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::warn));
        ImGui::TextWrapped("%s", vm_.cat_deferred_text().c_str());
        ImGui::PopStyleColor();
        ImGui::PopFont();
    }
    flow.next(true);
    draw_audio_devices(grid, caption_h);
    flow.next(true);

    const bool bm_connecting = s.bm_requested_enabled && s.bm_link != BmLink::connected;
    const char* bm_label = !s.bm_requested_enabled ? tr(Str::connect_bm)
                           : bm_connecting ? tr(Str::connecting_bm) : tr(Str::disconnect_bm);
    if (vm_.pending(Str::op_bm)) bm_label = s.bm_requested_enabled ? tr(Str::disconnecting_bm) : tr(Str::connecting_bm);
    // R131：断开后 5 s 冷却（服务器释放上次会话需要时间），按钮显示倒计时。
    const unsigned bm_cooldown = s.bm_requested_enabled ? 0U : vm_.bm_cooldown_remaining_s();
    const auto bm_stale_retry = vm_.bm_stale_session_retry_s();
    std::string bm_label_text = bm_label;
    if (!s.bm_requested_enabled && !vm_.pending(Str::op_bm)) {
        if (bm_stale_retry) bm_label_text = fmt("%s##bm", tr(Str::bm_waiting_release));
        else if (bm_cooldown != 0U) bm_label_text = fmt(tr(Str::bm_cooldown_fmt), bm_cooldown);
    }
    if (bm_cooldown != 0U || bm_stale_retry) continuous_ = true;
    const bool bm_runtime_available = s.phase == Phase::running;
    section_title(tr(Str::bm_account), fonts_.bold, layout::kFontSubtitle);
    {
        FieldRow row(grid, caption_h, row_gap);
        float cell_w = row.cell(0, tr(Str::callsign), 3);
        ImGui::SetNextItemWidth(cell_w);
        input_text("##bm-callsign", draft_.callsign,
                   ImGuiInputTextFlags_CharsUppercase | ImGuiInputTextFlags_CharsNoBlank);
        cell_w = row.cell(3, tr(Str::manual_dmr_id), 2);
        ImGui::SetNextItemWidth(cell_w);
        input_text("##bm-dmr-id", draft_dmr_id_, ImGuiInputTextFlags_CharsDecimal);
        ImGui::SetItemTooltip("%s", tr(Str::manual_dmr_id_hint));
        cell_w = row.cell(5, tr(Str::device_no));
        ImGui::SetNextItemWidth(cell_w);
        input_text("##bm-device-no", draft_.device_number, ImGuiInputTextFlags_CharsDecimal);
        row.end();
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
    {
        FieldRow row(grid, caption_h, row_gap);
        float cell_w = row.cell(0, tr(Str::bm_server), 3);
        if (simple_combo("##bm-preset", preset, server_items.data(), static_cast<int>(server_items.size()), cell_w)) {
            if (preset == static_cast<int>(app::bm_servers::catalog.size())) {
                draft_.master_preset = "custom";
            } else {
                const auto& e = app::bm_servers::catalog[static_cast<std::size_t>(preset)];
                draft_.master_preset = std::string(e.selection_id);
                if (!app::bm_servers::address_matches(e, draft_.master_host)) draft_.master_host = std::string(e.hostname);
                draft_master_port_ = std::to_string(e.port);
            }
        }
        cell_w = row.cell(3, tr(Str::host_ipv4), 2);
        ImGui::SetNextItemWidth(cell_w);
        if (input_text("##bm-host", draft_.master_host, ImGuiInputTextFlags_CharsNoBlank)) draft_.master_preset = "custom";
        cell_w = row.cell(5, tr(Str::udp_port));
        ImGui::SetNextItemWidth(cell_w);
        if (input_text("##bm-port", draft_master_port_, ImGuiInputTextFlags_CharsDecimal)) draft_.master_preset = "custom";
        row.end();
    }

    const std::string saved_id = cfg.dmr_id == 0U ? std::string{} : std::to_string(cfg.dmr_id);
    const bool bm_config_dirty = draft_.callsign != cfg.callsign || draft_dmr_id_ != saved_id ||
        draft_.device_number != cfg.device_number || draft_.master_preset != cfg.master_preset ||
        draft_.master_host != cfg.master_host || draft_master_port_ != std::to_string(cfg.master_port) ||
        draft_.bm_password != cfg.bm_password || draft_.bm_api_key != cfg.bm_api_key;
    // BM 与电台解耦：登录字段不完整只禁用 BM 连接，不影响电台。
    const bool bm_config_complete = vm_.bm_profile_complete();
    {
        // 两个按钮各占一个按钮列，与左侧输入框同一控件行、等高（frame_h）。
        FieldRow row(grid, caption_h, row_gap);
        float cell_w = row.cell(0, tr(Str::bm_password), 2);
        ImGui::SetNextItemWidth(cell_w);
        input_text("##bm-password", draft_.bm_password, ImGuiInputTextFlags_Password);
        cell_w = row.cell(2, tr(Str::bm_api_key), 2);
        ImGui::SetNextItemWidth(cell_w);
        input_text("##bm-api-key", draft_.bm_api_key, ImGuiInputTextFlags_Password);
        cell_w = row.cell(4, nullptr);
        if (button(tr(Str::save_settings), ImVec2(cell_w, frame_h), Tone::normal)) save_bm_config();
        cell_w = row.cell(5, nullptr);
        const bool bm_cooling = !s.bm_requested_enabled && (bm_cooldown != 0U || bm_stale_retry.has_value());
        if (button(fmt("%s##bm-toggle", bm_label_text.c_str()).c_str(), ImVec2(cell_w, frame_h),
                   s.bm_requested_enabled ? Tone::normal : Tone::ok,
                   bm_runtime_available && !vm_.pending(Str::op_bm) && !bm_cooling &&
                       (s.bm_requested_enabled || (!bm_config_dirty && bm_config_complete)))) toggle_bm();
        if (bm_cooling) {
            ImGui::SetItemTooltip("%s", tr(Str::bm_cooldown_tip));
        } else if (!s.bm_requested_enabled && !bm_config_complete) {
            ImGui::SetItemTooltip("%s", tr(Str::bm_connect_disabled_tip));
        } else if (!s.bm_requested_enabled && bm_config_dirty) {
            ImGui::SetItemTooltip("%s", tr(Str::bm_save_before_connect));
        }
        row.end();
    }
    ImGui::PushFont(nullptr, layout::kFontCaption);
    std::string bm_note = settings_error_.empty() ? tr(Str::bm_changes_next_connection) : settings_error_;
    if (settings_error_.empty() && !bm_config_complete) {
        bm_note = tr(Str::bm_not_configured); // 非错误提示：电台可独立使用
    } else if (settings_error_.empty() && bm_stale_retry) {
        bm_note = *bm_stale_retry == 0U ? std::string(tr(Str::bm_stale_retrying))
                                        : fmt(tr(Str::bm_stale_retry_fmt), *bm_stale_retry);
    }
    ImGui::PushStyleColor(ImGuiCol_Text, vec(settings_error_.empty() && !bm_stale_retry ? color::muted : color::warn));
    ImGui::TextWrapped("%s", bm_note.c_str());
    ImGui::PopStyleColor();
    ImGui::PopFont();
    if (vm_.pending(Str::op_start) || vm_.pending(Str::op_bm) || s.phase == Phase::starting ||
        s.bm_link == BmLink::resolving || s.bm_link == BmLink::connecting) continuous_ = true;

    if (flow.finish()) continuous_ = true;
    end_panel();
}

void AppView::draw_audio_devices(const FieldGrid& grid, float caption_h) {
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

    ImGui::PushFont(fonts_.bold, layout::kFontSubtitle);
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
                              bool show_pending_selection, float width) {
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
        ImGui::SetNextItemWidth(width);
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

    {
        // 输入跨前两列、输出占第三列、刷新按钮占窄列：与串口行共用列边界。
        FieldRow row(grid, caption_h, px(layout::kRowGap));
        std::wstring next_in = selected_in;
        std::wstring next_out = output_selector;
        const auto selection = vm_.device_selection();
        float cell_w = row.cell(0, tr(Str::input), 3);
        endpoint_combo("##wavein-main", vm_.devices().wave_in, selection.wave_in, next_in, selected_in,
                       !radio_attached, pending_radio_audio_change_, cell_w);
        cell_w = row.cell(3, tr(Str::output), 2);
        endpoint_combo("##waveout-main", vm_.devices().wave_out, selection.wave_out, next_out, output_selector,
                       !radio_attached, true, cell_w);
        cell_w = row.cell(5, nullptr);
        if (button(tr(Str::refresh_devices), ImVec2(cell_w, ImGui::GetFrameHeight()), Tone::normal,
                   !audio_selection_pending_)) {
            vm_.refresh_devices();
        }
        row.end();

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
}

void AppView::draw_daily_panel(float width, float height) {
    begin_panel("##daily", width, height);
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const float row_gap = px(layout::kRowGap);
    const float inline_gap = px(layout::kInlineGap);
    const float caption_h = line_height(nullptr, layout::kFontCaption);
    const float row_h = px(layout::kRowHeight);
    SectionFlow flow(daily_fixed_h_, 4, px(layout::kSectionGapMin), px(layout::kSectionGapMax));
    section_title(tr(Str::daily_controls), fonts_.bold);

    // 增加动态组 频道ID / 类型 / 加入监听
    static const std::vector<std::string> presets = {"460997 中国鹦鹉", "46001 组呼", "91 组呼"};
    {
        const float label_w = ImGui::CalcTextSize(tr(Str::add_listen)).x + ImGui::GetStyle().FramePadding.x * 2.0F;
        const float action_w = std::max(px(layout::kActionWidth), std::ceil(label_w));
        const FieldGrid grid(ImGui::GetCursorPosX(), inner_w, inline_gap, {0.0F, px(layout::kActionWidth), action_w});
        FieldRow row(grid, caption_h, row_gap);
        float cell_w = row.cell(0, tr(Str::add_channel_id));
        if (const int picked = editable_combo("##chid", vm_.add_channel_id, presets, cell_w); picked >= 0) {
            vm_.add_channel_id = presets[static_cast<std::size_t>(picked)];
            vm_.add_channel_kind = picked == 0 ? 1 : 2;
        }
        cell_w = row.cell(1, tr(Str::type));
        const char* kinds[] = {tr(Str::select), tr(Str::private_call), tr(Str::group)};
        simple_combo("##kind", vm_.add_channel_kind, kinds, 3, cell_w);
        cell_w = row.cell(2, nullptr);
        if (button(tr(Str::add_listen), ImVec2(cell_w, ImGui::GetFrameHeight()), Tone::ok, vm_.can_mutate_channels())) {
            vm_.add_channel();
        }
        row.end();
    }

    const auto& startup_status = vm_.startup_group_activation_status();
    if (!startup_status.empty()) {
        const bool warning = startup_status.find("失败") != std::string::npos ||
                             startup_status.find("failed") != std::string::npos ||
                             startup_status.find("busy") != std::string::npos ||
                             startup_status.find("paused") != std::string::npos ||
                             startup_status.find("忙") != std::string::npos ||
                             startup_status.find("暂停") != std::string::npos;
        ImGui::PushFont(nullptr, layout::kFontCaption);
        text_ellipsis(startup_status.c_str(), ImGui::GetContentRegionAvail().x,
                      rgb(warning ? color::warn : color::muted));
        ImGui::SetItemTooltip("%s", startup_status.c_str());
        ImGui::PopFont();
    }

    flow.next(true);
    draw_static_groups(inner_w);
    flow.next(true);

    // 收发音量：直接对应所选 WaveOut / WaveIn 端点的 Windows 音量（0–100%）。标题与数值同一行，滑块在下。
    const auto& s = vm_.snapshot();
    const auto& cat = vm_.cat();
    const float slider_w = inner_w;
    auto volume_row = [&](const char* label, const char* id, const std::optional<int>& current,
                          const std::string& error, bool playback, const char* tip) {
        const Row row = begin_row(caption_h);
        row_text(row, label, rgb(color::muted), nullptr, layout::kFontCaption);
        ImGui::SetItemTooltip("%s", tip);
        int& edit = playback ? playback_volume_edit_ : transmit_volume_edit_;
        const bool editing = playback ? playback_volume_editing_ : transmit_volume_editing_;
        if (!editing) edit = current.value_or(0);
        const auto value = current ? fmt("%d%%", edit) : std::string(tr(Str::volume_unknown));
        ImGui::PushFont(nullptr, layout::kFontBody);
        const float value_w = ImGui::CalcTextSize(value.c_str()).x;
        ImGui::PopFont();
        ImGui::SameLine(ImGui::GetCursorStartPos().x + inner_w - value_w);
        row_text(row, value.c_str(), current ? rgb(color::green) : rgb(color::muted), nullptr, layout::kFontBody);
        if (!error.empty()) ImGui::SetItemTooltip("%s", error.c_str());
        else if (!current) ImGui::SetItemTooltip("%s", tr(Str::volume_no_device));
        row.end();
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() - ImGui::GetStyle().ItemSpacing.y + row_gap);
        ImGui::BeginDisabled(!current.has_value());
        const auto r = percent_slider(id, edit, slider_w, scale_);
        ImGui::EndDisabled();
        if (playback) playback_volume_editing_ = r.active;
        else transmit_volume_editing_ = r.active;
        if (r.changed) vm_.commit_volume(playback, edit); // 拖动中实时写入 Windows 音量
        ImGui::SetItemTooltip("%s", tip);
    };
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(4.0F), px(3.0F)));
    volume_row(tr(Str::volume_playback), "##playback-volume", vm_.playback_volume(), vm_.playback_volume_error(), true,
               tr(Str::volume_tip_playback));
    volume_row(tr(Str::volume_transmit), "##transmit-volume", vm_.transmit_volume(), vm_.transmit_volume_error(), false,
               tr(Str::volume_tip_transmit));
    ImGui::PopStyleVar();
    // 高级：额外数字增益（默认收起，默认 1×）
    ImGui::PushFont(nullptr, layout::kFontCaption);
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
    const bool advanced_open = ImGui::TreeNodeEx(tr(Str::advanced_gain), ImGuiTreeNodeFlags_NoTreePushOnOpen);
    ImGui::PopStyleColor();
    ImGui::PopFont();
    ImGui::SetItemTooltip("%s", tr(Str::advanced_gain_tip));
    if (advanced_open) {
        auto gain_row = [&](const char* label, const char* id, int& step) {
            const Row row = begin_row(caption_h);
            row_text(row, label, rgb(color::muted), nullptr, layout::kFontCaption);
            const auto value = fmt("%d×", step);
            ImGui::PushFont(nullptr, layout::kFontBody);
            const float value_w = ImGui::CalcTextSize(value.c_str()).x;
            ImGui::PopFont();
            ImGui::SameLine(ImGui::GetCursorStartPos().x + inner_w - value_w);
            row_text(row, value.c_str(), rgb(color::green), nullptr, layout::kFontBody);
            row.end();
            ImGui::SetCursorPosY(ImGui::GetCursorPosY() - ImGui::GetStyle().ItemSpacing.y + row_gap);
            if (gain_slider(id, step, slider_w, scale_)) vm_.commit_gains();
        };
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(4.0F), px(3.0F)));
        gain_row(tr(Str::playback_gain), "##playback", vm_.playback_step);
        gain_row(tr(Str::transmit_gain), "##transmit-right", vm_.transmit_step);
        ImGui::PopStyleVar();
    }
    flow.next(true);

    // 实时 RX/TX 峰值：标签列宽取两者最大值，进度条与百分比按行高垂直居中
    {
        ImGui::PushFont(nullptr, layout::kFontCaption);
        const float label_w = std::max(ImGui::CalcTextSize(tr(Str::rx_live_peak)).x,
                                       ImGui::CalcTextSize(tr(Str::tx_live_peak)).x);
        const float pct_w = ImGui::CalcTextSize("-60 dB").x;
        ImGui::PopFont();
        const float bar_h = px(8.0F);
        const float x0 = ImGui::GetCursorPosX();
        // 峰值（0..1，满刻度归一化）→ dBFS；刻度 -60..0 dBFS 线性映射到条长，-18 dBFS 处画参考线。
        auto meter = [&](const char* label, float value) {
            const float peak = std::clamp(value, 0.0F, 1.0F);
            const float db = peak > 0.001F ? 20.0F * std::log10(peak) : -60.0F;
            const float v = std::clamp((db + 60.0F) / 60.0F, 0.0F, 1.0F);
            const Row row = begin_row(caption_h);
            row_text(row, label, rgb(color::muted), nullptr, layout::kFontCaption);
            ImGui::SetItemTooltip("%s", tr(Str::meter_dbfs_tip));
            ImGui::SameLine(x0 + label_w + inline_gap * 2.0F);
            const float bar_w = std::max(px(40.0F), inner_w - label_w - pct_w - inline_gap * 4.0F);
            row.place(bar_h);
            const ImVec2 bar_pos = ImGui::GetCursorScreenPos();
            ImGui::PushStyleColor(ImGuiCol_PlotHistogram, vec(db > -3.0F ? color::warn : color::green));
            ImGui::PushStyleColor(ImGuiCol_FrameBg, vec(color::inset));
            ImGui::ProgressBar(v, ImVec2(bar_w, bar_h), "");
            ImGui::PopStyleColor(2);
            ImGui::SetItemTooltip("%s", tr(Str::meter_dbfs_tip));
            const float ref_x = std::round(bar_pos.x + bar_w * (60.0F - 18.0F) / 60.0F);
            auto* dl = ImGui::GetWindowDrawList();
            for (float y = bar_pos.y - px(2.0F); y < bar_pos.y + bar_h + px(2.0F); y += px(3.0F)) {
                dl->AddLine(ImVec2(ref_x, y), ImVec2(ref_x, std::min(y + px(2.0F), bar_pos.y + bar_h + px(2.0F))),
                            rgb(0xE0E0E0), 1.0F);
            }
            const auto text = peak > 0.001F ? fmt("%.0f dB", db) : std::string("-∞ dB");
            ImGui::PushFont(nullptr, layout::kFontCaption);
            const float w = ImGui::CalcTextSize(text.c_str()).x;
            ImGui::PopFont();
            ImGui::SameLine(ImGui::GetCursorStartPos().x + inner_w - w);
            row_text(row, text.c_str(), rgb(color::text), nullptr, layout::kFontCaption);
            row.end();
        };
        meter(tr(Str::rx_live_peak), s.levels.rx_peak);
        meter(tr(Str::tx_live_peak), s.levels.tx_peak);
    }
    flow.next(true);

    // 状态区：所有项共用 kRowHeight 行并垂直居中；放不下时整项换到下一行（同样的行高与左缘）。
    if (const auto hint = vm_.filtered_hint()) draw_filtered_hint(*hint, inner_w);
    {
        const float x0 = ImGui::GetCursorPosX();
        const float right = x0 + inner_w;
        Row row = begin_row(row_h);
        bool first = true;
        auto fit = [&](float w, float gap) {
            if (!first) {
                ImGui::SameLine(0.0F, gap);
                if (ImGui::GetCursorPosX() + w > right) {
                    row.end();
                    row = begin_row(row_h);
                    ImGui::SetCursorPosX(x0);
                }
            }
            first = false;
        };
        // 所有项（含“状态”标签）同一字号 kFontBody、同一行高居中，因此文字基线一致。
        ImGui::PushFont(nullptr, layout::kFontBody);
        const float dot_w = std::round(ImGui::GetTextLineHeight() * 0.7F) + 2.0F;
        auto text_w = [](const char* t) { return ImGui::CalcTextSize(t).x; };
        auto dot_colored = [&](ImU32 dot_col, ImU32 text_col, const char* label) {
            fit(dot_w + text_w(label), inline_gap * 1.5F);
            status_dot(row, dot_col, text_col, label);
        };
        const bool core_failed = s.phase == Phase::failed;
        auto dot = [&](bool on, const char* label) {
            // 核心异常停止：依赖引擎的灯显示红色（熄灭 + 错误色），提示需要重新连接。
            if (!on && core_failed) dot_colored(rgb(color::error), dot_text(false), label);
            else dot_colored(dot_on(on), dot_text(on), label);
        };

        fit(text_w(tr(Str::status)), 0.0F);
        row_text(row, tr(Str::status), rgb(color::muted), nullptr, layout::kFontBody);
        const auto device_status = vm_.device_selection();
        // 引擎停止（含异常）：所有依赖引擎的灯熄灭，不显示最后一份运行快照里的残留状态。
        const bool live = !vm_.engine_stopped();
        dot(live && s.serial_open, tr(Str::status_serial));
        dot(live && s.hri_ready, tr(Str::status_hri));
        ImGui::SetItemTooltip("%s", device_selection_text(device_status.hri, true).c_str());
        dot(cat.connected, tr(Str::status_cat));
        ImGui::SetItemTooltip("%s", cat.error.empty() ? device_selection_text(device_status.cat, true).c_str()
                                                       : cat.error.c_str());
        dot(live && s.bm_link == BmLink::connected, tr(Str::status_bm));
        dot(live && s.wave_in_open, tr(Str::status_wave_in));
        ImGui::SetItemTooltip("%s", device_selection_text(device_status.wave_in, false).c_str());
        if (live && !s.wave_out_open && s.hri_ready && s.local_audio_error == "radio_waveout_unavailable") {
            dot_colored(rgb(color::warn), rgb(color::warn), tr(Str::status_wave_out));
            ImGui::SetItemTooltip("%s", tr(Str::err_radio_waveout_unavailable));
        } else {
            dot(live && s.wave_out_open, tr(Str::status_wave_out));
        }
        ImGui::SetItemTooltip("%s", device_selection_text(device_status.wave_out, false).c_str());

        const auto& local_audio = s.local_audio;
        const auto audio_state = local_audio.audio_state;
        const bool output_error = !s.local_audio_error.empty() ||
            local_audio.output_error != wirex::bm_local_playback::OutputError::none;
        const bool radio_route = local_audio.radio_ready && !output_error;
        const char* playback_text = output_error ? tr(Str::local_playback_failed)
            : radio_route ? local_playback_route_text(wirex::bm_local_playback::Route::radio)
                          : local_playback_state_text(audio_state);
        // 电脑播放/音频路由：与其它项相同的圆点形式；圆点颜色表示状态，状态文字放在悬停提示里。
        const std::uint32_t playback_color =
            output_error ? color::error : radio_route ? color::green : local_playback_color(audio_state);
        const bool playback_on = playback_color != color::muted;
        const char* playback_label = radio_route ? playback_text : tr(Str::local_playback);
        dot_colored(playback_on ? rgb(playback_color) : dot_on(false), dot_text(playback_on || output_error),
                    playback_label);
        std::string playback_tip = fmt(tr(Str::status_local_playback_tip_fmt),
                                       tr(radio_route ? Str::local_audio_route_status : Str::local_playback), playback_text);
        if (output_error) {
            const char* category = local_playback_error_text(local_audio.output_error);
            const char* detail = !s.local_audio_error.empty() ? s.local_audio_error.c_str() : category;
            if (language() == Language::en_us && category[0] != '\0') detail = category;
            if (detail[0] != '\0') playback_tip += std::string("\n") + detail;
        } else {
            const auto& resolved = device_status.wave_out;
            const std::string device = !resolved.name.empty() ? resolved.name : device_selection_text(resolved, true);
            if (!device.empty()) playback_tip += "\n" + device;
        }
        ImGui::SetItemTooltip("%s", playback_tip.c_str());
        ImGui::PopFont();
        row.end();
    }
    if (flow.finish()) continuous_ = true;
    end_panel();
}

// 频道卡片“移除”静态组频道时的确认弹窗：[从 BM 移除并取消收听] [仅取消收听] [取消]。
void AppView::draw_static_remove_modal() {
    constexpr const char* kId = "##static-remove";
    if (static_remove_confirm_ && !ImGui::IsPopupOpen(kId)) ImGui::OpenPopup(kId);
    const ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->GetCenter(), ImGuiCond_Appearing, ImVec2(0.5F, 0.5F));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(16.0F), px(12.0F)));
    const bool open = ImGui::BeginPopupModal(kId, nullptr,
        ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoSavedSettings);
    ImGui::PopStyleVar();
    if (!open) return;
    continuous_ = true;
    if (!static_remove_confirm_) {
        ImGui::CloseCurrentPopup();
        ImGui::EndPopup();
        return;
    }
    const auto key = *static_remove_confirm_;
    const bool has_key = !vm_.config().bm_api_key.empty();
    ImGui::PushFont(fonts_.bold, layout::kFontTitle);
    ImGui::TextUnformatted(tr(Str::static_remove_title));
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0.0F, px(layout::kRowGap)));
    ImGui::PushFont(nullptr, layout::kFontBody);
    ImGui::TextUnformatted(fmt(tr(Str::static_remove_ask_fmt), key.id).c_str());
    if (!has_key) {
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::warn));
        ImGui::TextUnformatted(tr(Str::static_remove_no_key));
        ImGui::PopStyleColor();
    }
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0.0F, px(layout::kSectionGapMin)));
    const float bh = px(layout::kHeaderButtonHeight);
    const auto bw = [this](const char* label) { return ImGui::CalcTextSize(label).x + px(24.0F); };
    const bool can_mutate = vm_.can_mutate_channels();
    if (button(tr(Str::static_remove_both), ImVec2(bw(tr(Str::static_remove_both)), bh), Tone::stop,
               has_key && can_mutate && !vm_.static_groups().busy)) {
        vm_.remove_static_channel(key);
        static_remove_confirm_.reset();
        ImGui::CloseCurrentPopup();
    }
    ImGui::SameLine(0.0F, px(layout::kInlineGap));
    if (button(tr(Str::static_remove_listen_only), ImVec2(bw(tr(Str::static_remove_listen_only)), bh), Tone::normal,
               can_mutate)) {
        vm_.remove_channel(key);
        static_remove_confirm_.reset();
        ImGui::CloseCurrentPopup();
    }
    ImGui::SameLine(0.0F, px(layout::kInlineGap));
    if (button(tr(Str::btn_cancel), ImVec2(bw(tr(Str::btn_cancel)), bh)) || ImGui::IsKeyPressed(ImGuiKey_Escape)) {
        static_remove_confirm_.reset();
        ImGui::CloseCurrentPopup();
    }
    ImGui::EndPopup();
}

void AppView::preview_static_remove_modal() {
    for (const auto& ch : vm_.channel_page()) {
        if (ch.is_static) {
            static_remove_confirm_ = ch.key;
            return;
        }
    }
}

// 有 BM 流量但被收听策略过滤时的弱提示：一行文字 + “加入收听”小按钮，同一行垂直居中。
void AppView::draw_filtered_hint(const FilteredHint& hint, float inner_w) {
    const auto& t = hint.traffic;
    const int slot = static_cast<int>(t.slot);
    std::string text;
    if (t.kind == dmr_call::CallKind::group) {
        text = fmt(tr(Str::filtered_group_fmt), t.destination_id, slot, t.source_id, hint.age_s);
    } else {
        const std::string destination = hint.addressed_to_local
            ? std::string(tr(Str::filtered_local_dst)) : std::to_string(t.destination_id);
        text = fmt(tr(Str::filtered_private_fmt), t.source_id, destination.c_str(), slot, hint.age_s);
    }
    const bool show_join = hint.joinable;
    const float bh = px(layout::kRowHeight);
    ImGui::PushFont(nullptr, layout::kFontCaption);
    const float button_w = show_join
        ? ImGui::CalcTextSize(tr(Str::filtered_join)).x + px(layout::kInlineGap) * 2.0F : 0.0F;
    const Row row = begin_row(bh);
    row.place(ImGui::GetTextLineHeight());
    const float text_w = std::max(px(40.0F),
        inner_w - (show_join ? button_w + px(layout::kInlineGap) : 0.0F));
    text_ellipsis(text.c_str(), text_w, rgb(color::warn));
    if (show_join) ImGui::SetItemTooltip("%s", text.c_str());
    else ImGui::SetItemTooltip("%s\n%s", text.c_str(), tr(Str::tip_filtered_private_info));
    if (show_join) {
        ImGui::SameLine(ImGui::GetCursorStartPos().x + inner_w - button_w);
        row.place(bh);
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(0.0F, 0.0F));
        if (button(fmt("%s##listen-filtered", tr(Str::filtered_join)).c_str(), ImVec2(button_w, bh), Tone::normal,
                   vm_.can_mutate_channels())) {
            vm_.listen_filtered();
        }
        ImGui::PopStyleVar();
        ImGui::SetItemTooltip("%s", tr(t.kind == dmr_call::CallKind::group ? Str::tip_filtered_join
                                                                             : Str::tip_filtered_private_join));
    }
    ImGui::PopFont();
    row.end();
}

// BM 静态组（BmManagementUi.ps1）：标题行 [设备 · 分页 · 刷新 · 移除]，每页 3 条，下方 TG 输入 + 添加。
void AppView::draw_static_groups(float inner_w) {
    auto& sg = vm_.static_form();
    const auto& cfg = vm_.config();
    const bool has_key = !cfg.bm_api_key.empty();
    const std::size_t pages =
        std::max<std::size_t>(1U, (sg.groups.size() + StaticGroupsView::page_size - 1U) / StaticGroupsView::page_size);
    const float bh = px(layout::kRowHeight);
    const float small_w = px(layout::kPagerWidth);

    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(layout::kInlineGap), 0.0F));
    const Row title = begin_row(bh);
    row_text(title, tr(Str::bm_static_groups), rgb(color::text), fonts_.bold, layout::kFontSubtitle);
    ImGui::SameLine(0.0F, px(layout::kTitleGap));
    const auto device = vm_.bm_device_id();
    row_text(title, device != 0U ? fmt(tr(Str::static_device_fmt), device).c_str() : "—", rgb(color::muted), nullptr,
             layout::kFontCaption);

    const float refresh_w = ImGui::CalcTextSize(tr(Str::static_refresh)).x + px(14.0F);
    const float remove_w = ImGui::CalcTextSize(tr(Str::static_remove)).x + px(14.0F);
    const auto page_label = fmt("%zu / %zu", sg.page + 1U, pages);
    ImGui::PushFont(nullptr, layout::kFontCaption);
    const float page_w = ImGui::CalcTextSize(page_label.c_str()).x;
    ImGui::PopFont();
    const float spacing = ImGui::GetStyle().ItemSpacing.x;
    const float right_w = small_w * 2.0F + page_w + refresh_w + remove_w + spacing * 4.0F;
    ImGui::SameLine(ImGui::GetCursorStartPos().x + inner_w - right_w);
    title.place(bh);
    if (button("‹##sgprev", ImVec2(small_w, bh), Tone::normal, sg.loaded && sg.page > 0U)) vm_.static_set_page(sg.page - 1U);
    ImGui::SameLine();
    row_text(title, page_label.c_str(), rgb(color::muted), nullptr, layout::kFontCaption);
    ImGui::SameLine();
    title.place(bh);
    if (button("›##sgnext", ImVec2(small_w, bh), Tone::normal, sg.loaded && sg.page + 1U < pages)) {
        vm_.static_set_page(sg.page + 1U);
    }
    ImGui::SameLine();
    title.place(bh);
    if (button(tr(Str::static_refresh), ImVec2(refresh_w, bh), Tone::normal, vm_.bm_api_available() && has_key && !sg.busy)) {
        vm_.static_refresh();
    }
    ImGui::SameLine();
    title.place(bh);
    if (button(tr(Str::static_remove), ImVec2(remove_w, bh), Tone::normal, sg.loaded && sg.selected.has_value() && !sg.busy)) {
        vm_.static_remove();
    }
    ImGui::PopStyleVar();
    title.end();

    // 列表（固定 3 行高；左）+ TG 输入与添加（右）
    const float add_w = ImGui::CalcTextSize(tr(Str::static_add)).x + px(20.0F);
    const float list_outer_w = inner_w - add_w - spacing;
    const float row_h = line_height(nullptr, layout::kFontBody) + px(2.0F);
    const float list_h = std::max(row_h * static_cast<float>(StaticGroupsView::page_size) + px(8.0F),
                                  ImGui::GetFrameHeight() * 2.0F + spacing);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(color::input_bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(color::call_border));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(layout::kCardPad), px(layout::kGap)));
    ImGui::BeginChild("##sglist", ImVec2(list_outer_w, list_h), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    ImGui::PushFont(nullptr, layout::kFontBody);
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
    // 引擎已停止（含异常停止）时 radio_link_active() 为 false：按钮执行“连接”，ViewModel::start 重新启动引擎。
    const bool active = vm_.radio_link_active();
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
