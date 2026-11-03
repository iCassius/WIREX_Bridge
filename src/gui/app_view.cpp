#include "app_view.hpp"

#include "imgui.h"
#include "imgui_internal.h"

#include <algorithm>
#include <cctype>
#include <cstdarg>
#include <cstdio>
#include <string>

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

// 只保留 A-Z0-9/ 的呼号，用于构造资料页链接。
std::string safe_callsign(const std::string& raw) {
    std::string out;
    for (char c : raw) {
        const auto u = static_cast<unsigned char>(c);
        if (std::isalnum(u) != 0 || c == '/') out.push_back(static_cast<char>(std::toupper(u)));
    }
    return out.size() >= 3U && out.size() <= 16U ? out : std::string{};
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
    if (!ImGui::BeginTable(id, static_cast<int>(columns.size()), ImGuiTableFlags_SizingStretchProp | ImGuiTableFlags_NoPadOuterX)) {
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

bool simple_combo(const char* id, int& index, const char* const* items, int count, float width) {
    bool changed = false;
    ImGui::SetNextItemWidth(width);
    const char* preview = index >= 0 && index < count ? items[index] : "";
    if (ImGui::BeginCombo(id, preview)) {
        for (int i = 0; i < count; ++i) {
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
    style.ChildRounding = 2.0F;
    style.FrameRounding = 2.0F;
    style.PopupRounding = 2.0F;
    style.GrabRounding = 2.0F;
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
    style.FontScaleDpi = dpi_scale;
    // ImGui 的字号是 ascent+descent 像素高度，WPF FontSize 是 em 尺寸；微软雅黑 ascent+descent ≈ 1.32 em。
    // 乘上该系数后，代码中的字号可直接沿用 XAML 中的数值。
    style.FontScaleMain = 1.3F;
}

// ---------------------------------------------------------------- 视图

AppView::AppView(ViewModel& vm, Fonts fonts) : vm_(vm), fonts_(fonts) {}

void AppView::open_settings() {
    draft_ = vm_.config();
    draft_dmr_id_ = draft_.dmr_id != 0U ? std::to_string(draft_.dmr_id) : std::string{};
    draft_master_port_ = std::to_string(draft_.master_port);
    draft_hri_port_ = to_utf8(draft_.hri_port);
    settings_error_.clear();
    settings_requested_ = true;
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

    const float gap = px(6.0F);
    const float footer_h = ImGui::GetFrameHeight() + px(16.0F);
    draw_header();
    const ImVec2 avail = ImGui::GetContentRegionAvail();
    const float body_h = avail.y - footer_h - gap;
    // 频道卡片 : 来话 : 控制区 ≈ 39% : 20% : 剩余（来话区刚好容纳 5 行历史）
    const float cards_h = std::max(px(240.0F), body_h * 0.39F);
    const float calls_h = std::max(px(150.0F), body_h * 0.205F);
    const float panels_h = body_h - cards_h - calls_h - gap * 2.0F;

    draw_channels(cards_h);
    ImGui::Dummy(ImVec2(0.0F, gap - ImGui::GetStyle().ItemSpacing.y * 2.0F));
    draw_calls(calls_h);
    ImGui::Dummy(ImVec2(0.0F, gap - ImGui::GetStyle().ItemSpacing.y * 2.0F));
    const float half = (avail.x - gap) * 0.5F;
    draw_radio_panel(half, panels_h);
    ImGui::SameLine(0.0F, gap);
    draw_daily_panel(half, panels_h);
    draw_footer();
    draw_settings();

    ImGuiIO& io = ImGui::GetIO();
    if (ImGui::IsAnyItemActive() || ImGui::IsMouseDown(ImGuiMouseButton_Left) || io.MouseWheel != 0.0F) continuous_ = true;
    ImGui::End();
}

void AppView::draw_header() {
    const auto& s = vm_.snapshot();
    const float row_h = px(32.0F);
    const ImVec2 start = ImGui::GetCursorPos();

    ImGui::PushFont(fonts_.bold, 19.0F);
    ImGui::SetCursorPosY(start.y + (row_h - ImGui::GetTextLineHeight()) * 0.5F);
    ImGui::TextUnformatted(tr(Str::app_title));
    ImGui::PopFont();
    if (vm_.fake()) {
        ImGui::SameLine(0.0F, px(10.0F));
        ImGui::SetCursorPosY(start.y + (row_h - ImGui::GetTextLineHeight()) * 0.5F);
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::warn));
        ImGui::Text("[%s]", tr(Str::fake_banner));
        ImGui::PopStyleColor();
    }

    // 中部状态：BrandMeister · 核心 · 提示（从窗口宽度的 32% 处开始，接近 WPF 的居中状态卡）
    ImGui::SameLine(std::max(ImGui::GetCursorPosX() + px(24.0F), ImGui::GetWindowWidth() * 0.32F));
    ImGui::SetCursorPosY(start.y + (row_h - ImGui::GetTextLineHeight()) * 0.5F);
    caption(tr(Str::brandmeister));
    ImGui::SameLine();
    ImGui::PushFont(fonts_.bold, 13.0F);
    const bool bm_ok = s.bm_link == BmLink::connected;
    const bool bm_bad = s.bm_link == BmLink::failed || s.bm_link == BmLink::backoff;
    ImGui::PushStyleColor(ImGuiCol_Text, bm_ok ? vec(color::green) : bm_bad ? vec(color::warn) : vec(color::text));
    ImGui::TextUnformatted(bm_link_text(s.bm_link));
    ImGui::PopStyleColor();
    ImGui::PopFont();
    ImGui::SameLine(0.0F, px(14.0F));
    caption(tr(Str::rtt));
    ImGui::SameLine();
    ImGui::TextUnformatted("—"); // TODO(engine): Snapshot 暂无 RTT 字段
    ImGui::SameLine(0.0F, px(18.0F));
    caption(tr(Str::core));
    ImGui::SameLine();
    ImGui::PushFont(fonts_.bold, 13.0F);
    const bool core_ok = s.phase == Phase::running;
    ImGui::PushStyleColor(ImGuiCol_Text,
                          core_ok ? vec(color::green) : s.phase == Phase::failed ? vec(color::error) : vec(color::text));
    ImGui::TextUnformatted(phase_text(s));
    ImGui::PopStyleColor();
    ImGui::PopFont();
    if (s.phase == Phase::failed && !s.failure_reason.empty()) ImGui::SetItemTooltip("%s", s.failure_reason.c_str());

    // 右侧按钮
    const float stop_w = px(120.0F);
    const float settings_w = px(64.0F);
    const float right = ImGui::GetWindowContentRegionMax().x;
    const float text_x = ImGui::GetCursorPosX();
    std::string hint;
    ImU32 hint_color = rgb(color::warn);
    if (vm_.transient_visible()) {
        hint = vm_.transient_text();
        hint_color = vm_.transient_failed() ? rgb(color::warn) : rgb(color::green);
    } else if (vm_.font_status() == FontStatus::simhei) {
        hint = tr(Str::font_simhei);
    } else if (vm_.font_status() == FontStatus::fallback_default) {
        hint = tr(Str::font_default);
    }
    if (!hint.empty()) {
        ImGui::SameLine(0.0F, px(16.0F));
        const float w = right - stop_w - settings_w - px(24.0F) - (text_x + px(16.0F));
        if (w > px(40.0F)) {
            ImGui::PushFont(nullptr, 12.0F);
            text_ellipsis(hint.c_str(), w, hint_color);
            ImGui::PopFont();
            ImGui::SetItemTooltip("%s", hint.c_str());
        }
    }
    const float btn_h = px(26.0F);
    ImGui::SetCursorPos(ImVec2(right - stop_w - settings_w - px(6.0F), start.y + (row_h - btn_h) * 0.5F));
    if (button(tr(Str::settings), ImVec2(settings_w, btn_h))) open_settings();
    ImGui::SameLine(0.0F, px(6.0F));
    if (button(tr(Str::stop_exit), ImVec2(stop_w, btn_h), Tone::stop)) {
        if (vm_.snapshot().phase != Phase::stopped) vm_.stop();
        vm_.request_exit();
    }
    ImGui::SetCursorPos(ImVec2(start.x, start.y + row_h + px(4.0F)));
}

void AppView::draw_channels(float height) {
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(color::panel));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(6.0F)));
    ImGui::BeginChild("##channels", ImVec2(0.0F, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    const bool paged = vm_.channel_page_count() > 1U;
    const float nav_h = paged ? px(22.0F) : 0.0F;
    const ImVec2 avail = ImGui::GetContentRegionAvail();
    const float gap = px(4.0F);
    const float card_w = (avail.x - gap * 2.0F) / 3.0F;
    const float card_h = (avail.y - nav_h - gap) / 2.0F;
    const auto page = vm_.channel_page();
    for (std::size_t i = 0; i < ViewModel::channel_page_size; ++i) {
        if (i % 3U != 0U) ImGui::SameLine(0.0F, gap);
        if (i == 3U) ImGui::Dummy(ImVec2(0.0F, gap - ImGui::GetStyle().ItemSpacing.y * 2.0F));
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
        const float bw = px(28.0F);
        const float bh = px(19.0F);
        ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(0.0F, 0.0F));
        if (button("‹##chprev", ImVec2(bw, bh), Tone::normal, vm_.channel_page_index() > 0U)) {
            vm_.set_channel_page(vm_.channel_page_index() - 1U);
        }
        const auto label = fmt("%zu / %zu", vm_.channel_page_index() + 1U, vm_.channel_page_count());
        ImGui::SameLine((avail.x - ImGui::CalcTextSize(label.c_str()).x) * 0.5F);
        caption(label.c_str());
        ImGui::SameLine(avail.x - bw + ImGui::GetStyle().WindowPadding.x);
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
    const float buttons_w = std::min(px(170.0F), inner.x * 0.36F);
    const float call_w = inner.x - buttons_w - px(5.0F);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(call_bg));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(color::call_border));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(6.0F), px(4.0F)));
    ImGui::BeginChild("##call", ImVec2(call_w, content_h), ImGuiChildFlags_Borders,
                      ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    if (ch.current_call) {
        caller_block(*ch.current_call, fonts_.bold, 23.0F, 17.0F, ch.is_tx_active ? rgb(0xFFFFFF) : rgb(color::callsign));
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
    if (button(ch.is_tx_target ? tr(Str::btn_tx_target) : tr(Str::btn_set_tx), bsize,
               ch.is_tx_target ? Tone::ok : Tone::normal, can_mutate && !ch.is_tx_target && !tx_busy)) {
        vm_.set_tx_target(ch.key);
    }
    ImGui::SetItemTooltip("%s", ch.is_tx_target ? tr(Str::tip_tx_selected) : tr(Str::tip_set_tx));
    ImGui::SameLine();
    if (button(tr(Str::btn_remove), bsize, Tone::normal, can_mutate)) vm_.remove_channel(ch.key);
    if (button(ch.is_muted ? tr(Str::btn_unmute) : tr(Str::btn_mute), bsize, Tone::normal, can_mutate)) {
        vm_.toggle_mute(ch.key);
    }
    ImGui::SameLine();
    if (ch.quick_call_allowed) {
        const bool any_pending = vm_.pending(Str::op_quick_call);
        const char* label = ch.is_static            ? tr(Str::static_group)
                            : ch.quick_call_pending ? tr(Str::btn_joining)
                            : ch.quick_call_sent    ? tr(Str::btn_rejoin)
                                                    : tr(Str::btn_join);
        const bool bm_ready = vm_.snapshot().bm_link == BmLink::connected;
        if (button(label, bsize, Tone::normal, !ch.is_static && !any_pending && bm_ready && !ch.is_muted)) {
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
        const auto from = source_label(rec.call);
        const auto text = rec.call.kind == dmr_call::CallKind::group
                              ? fmt(tr(Str::history_group), clock.c_str(), rec.call.destination_id, from.c_str())
                              : fmt(tr(Str::history_private), clock.c_str(), rec.call.destination_id, from.c_str());
        ImGui::PushID(static_cast<int>(i));
        const bool selected = vm_.selected_history() == i;
        if (ImGui::Selectable(text.c_str(), selected, ImGuiSelectableFlags_None, ImVec2(inner_w, 0.0F))) {
            vm_.select_history(selected ? std::nullopt : std::optional<std::size_t>(i));
        }
        ImGui::PopID();
    }
    ImGui::PopStyleVar();
    ImGui::PopFont();
    ImGui::EndChild();
    ImGui::PopStyleColor();
}

void AppView::draw_current_call(float width, float height) {
    const auto& s = vm_.snapshot();
    const bool rx = s.active_rx_call.has_value();
    ImGui::PushStyleColor(ImGuiCol_ChildBg, vec(s.tx_active ? color::call_tx_active : rx ? color::call_active : color::panel));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(rx ? 0x3E8A5C : color::line));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(8.0F), px(5.0F)));
    ImGui::BeginChild("##current", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    section_title(tr(Str::current_call), fonts_.bold);
    if (rx) {
        const auto& call = *s.active_rx_call;
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
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(10.0F), px(8.0F)));
    ImGui::BeginChild("##radio", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const float gap = ImGui::GetStyle().ItemSpacing.x;
    section_title(tr(Str::radio_control), fonts_.bold);
    ImGui::Spacing();

    // CAT 串口 / 波特率 / 连接
    const auto& cat = vm_.cat();
    std::vector<std::string> ports;
    for (const auto& p : vm_.devices().serial_ports) ports.push_back(to_utf8(p.port));
    if (begin_fields("##catrow", {{tr(Str::cat_port), 1.0F, 0.0F}, {tr(Str::baud_rate), 1.0F, 0.0F}, {" ", 1.0F, 0.0F}})) {
        ImGui::TableNextColumn();
        ImGui::BeginDisabled(cat.connected || cat.busy);
        if (const int picked = editable_combo("##catport", vm_.cat_form.port, ports, ImGui::GetContentRegionAvail().x); picked >= 0) {
            vm_.cat_form.port = ports[static_cast<std::size_t>(picked)];
        }
        ImGui::TableNextColumn();
        static const char* const baud_labels[] = {"4800", "9600", "19200", "38400", "115200"};
        simple_combo("##baud", vm_.cat_form.baud_index, baud_labels, 5, -FLT_MIN);
        ImGui::EndDisabled();
        ImGui::TableNextColumn();
        if (button(cat.connected ? tr(Str::disconnect_cat) : tr(Str::connect_cat), ImVec2(-FLT_MIN, 0.0F),
                   cat.connected ? Tone::normal : Tone::ok, vm_.cat_available() && !cat.busy && !vm_.cat_form.port.empty())) {
            vm_.cat_toggle_connection();
        }
        ImGui::EndTable();
    }
    ImGui::Spacing();

    // MAIN 模式 / 频率 / 功率 / 应用
    ImGui::BeginDisabled(!cat.connected || cat.busy);
    if (begin_fields("##mainrow", {{tr(Str::main_mode), 1.0F, 0.0F},
                                   {tr(Str::frequency_mhz), 1.0F, 0.0F},
                                   {tr(Str::power_w), 1.0F, 0.0F},
                                   {" ", 0.0F, px(80.0F)}})) {
        ImGui::TableNextColumn();
        simple_combo("##mode", vm_.cat_form.mode_index, kCatModes, 4, -FLT_MIN);
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text("##freq", vm_.cat_form.frequency_mhz, ImGuiInputTextFlags_CharsDecimal);
        ImGui::TableNextColumn();
        static const char* const power_labels[] = {"5 W", "10 W", "15 W", "25 W", "50 W"};
        simple_combo("##power", vm_.cat_form.power_index, power_labels, 5, -FLT_MIN);
        ImGui::TableNextColumn();
        if (button(tr(Str::apply), ImVec2(-FLT_MIN, 0.0F), Tone::normal, vm_.cat_form.mode_index >= 0)) vm_.cat_apply();
        ImGui::EndTable();
    }
    ImGui::EndDisabled();

    // 读取值
    ImGui::PushFont(nullptr, 12.0F);
    if (cat.connected && cat.observed_mode && cat.observed_frequency_hz && cat.observed_power_w) {
        ImGui::PushStyleColor(ImGuiCol_Text, vec(color::green));
        ImGui::Text(tr(Str::cat_observed), kCatModes[static_cast<int>(*cat.observed_mode)],
                    static_cast<double>(*cat.observed_frequency_hz) / 1'000'000.0, *cat.observed_power_w);
        ImGui::PopStyleColor();
    } else {
        ImGui::PushStyleColor(ImGuiCol_Text, vec(cat.error.empty() ? color::muted : color::warn));
        ImGui::TextUnformatted(cat.error.empty() ? tr(Str::cat_disconnected) : cat.error.c_str());
        ImGui::PopStyleColor();
    }
    ImGui::PopFont();

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    // 连接概况：Wires-X 串口、音频端点、核心各项状态
    const auto& s = vm_.snapshot();
    const auto& cfg = vm_.config();
    auto endpoint_name = [](const std::vector<services::AudioEndpointInfo>& list, const std::wstring& id) {
        for (const auto& e : list) {
            if (e.endpoint_id == id) return e.name;
        }
        return id.empty() ? std::string("—") : to_utf8(id);
    };
    const float label_w = px(96.0F);
    auto row = [&](const char* label, const std::string& value) {
        caption(label);
        ImGui::SameLine(label_w);
        text_ellipsis(value.c_str(), inner_w - label_w, rgb(color::text));
    };
    row(tr(Str::wiresx_port), cfg.hri_port.empty() ? std::string("—") : to_utf8(cfg.hri_port));
    row(tr(Str::input), endpoint_name(vm_.devices().wave_in, cfg.wave_in_endpoint_id));
    row(tr(Str::output), endpoint_name(vm_.devices().wave_out, cfg.wave_out_endpoint_id));
    caption(tr(Str::core));
    ImGui::SameLine(label_w);
    status_dot(s.serial_open, "Serial");
    ImGui::SameLine(0.0F, px(12.0F));
    status_dot(s.hri_ready, "HRI");
    ImGui::SameLine(0.0F, px(12.0F));
    status_dot(s.wave_in_open, "WaveIn");
    ImGui::SameLine(0.0F, px(12.0F));
    status_dot(s.wave_out_open, "WaveOut");
    ImGui::SameLine(0.0F, px(12.0F));
    status_dot(s.bm_link == BmLink::connected, "BM");
    ImGui::EndChild();
}

void AppView::draw_daily_panel(float width, float height) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(px(10.0F), px(8.0F)));
    ImGui::BeginChild("##daily", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    const float inner_w = ImGui::GetContentRegionAvail().x;
    const float gap = ImGui::GetStyle().ItemSpacing.x;
    section_title(tr(Str::daily_controls), fonts_.bold);
    ImGui::Spacing();

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

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    // 音量
    section_title(tr(Str::volume), fonts_.bold);
    bool commit = false;
    if (ImGui::BeginTable("##gains", 2, ImGuiTableFlags_SizingStretchSame | ImGuiTableFlags_NoPadOuterX)) {
        // 标题行与滑块行分开：同一表格行内各列共享文本基线，滑块的 FramePadding 会把另一列的标题推低。
        auto label_cell = [&](const char* label, int value) {
            ImGui::TableNextColumn();
            const float right = ImGui::GetCursorScreenPos().x + ImGui::GetContentRegionAvail().x - px(8.0F);
            caption(label);
            const auto v = fmt("%d×", value);
            ImGui::SameLine();
            // 表格列内 SameLine(x) 的 x 相对列起点，这里直接用屏幕坐标右对齐。
            ImGui::SetCursorScreenPos(ImVec2(right - ImGui::CalcTextSize(v.c_str()).x, ImGui::GetCursorScreenPos().y));
            ImGui::PushStyleColor(ImGuiCol_Text, vec(color::green));
            ImGui::TextUnformatted(v.c_str());
            ImGui::PopStyleColor();
        };
        auto slider_cell = [&](const char* id, int& value) {
            ImGui::TableNextColumn();
            ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px(4.0F), px(6.0F)));
            commit = gain_slider(id, value, ImGui::GetContentRegionAvail().x - px(8.0F), scale_) || commit;
            ImGui::PopStyleVar();
        };
        ImGui::TableNextRow();
        label_cell(tr(Str::playback_gain), vm_.playback_step);
        label_cell(tr(Str::transmit_gain), vm_.transmit_step);
        ImGui::TableNextRow();
        slider_cell("##playback", vm_.playback_step);
        slider_cell("##transmit", vm_.transmit_step);
        ImGui::EndTable();
    }
    if (commit) vm_.commit_gains();

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    // 接收电平与计数
    const auto& s = vm_.snapshot();
    caption(tr(Str::rx_level));
    ImGui::PushStyleColor(ImGuiCol_PlotHistogram, vec(s.levels.rx_peak > 0.9F ? color::warn : color::green));
    ImGui::PushStyleColor(ImGuiCol_FrameBg, vec(color::inset));
    ImGui::ProgressBar(std::clamp(s.levels.rx_peak, 0.0F, 1.0F), ImVec2(inner_w, px(10.0F)), "");
    ImGui::PopStyleColor(2);
    ImGui::PushFont(nullptr, 12.0F);
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
    ImGui::Text("RX %llu · TX %llu · Reconnect %llu · Rejected %llu",
                static_cast<unsigned long long>(s.counters.calls_started),
                static_cast<unsigned long long>(s.counters.ptt_tx_starts),
                static_cast<unsigned long long>(s.counters.reconnects),
                static_cast<unsigned long long>(s.counters.rejected_calls));
    ImGui::PopStyleColor();
    ImGui::PopFont();
    ImGui::EndChild();
}

void AppView::draw_footer() {
    const auto& s = vm_.snapshot();
    ImGui::Dummy(ImVec2(0.0F, px(2.0F)));
    const float bw = px(150.0F);

    const char* serial_label = tr(Str::connect_serial);
    Tone serial_tone = Tone::ok;
    bool serial_enabled = !vm_.pending(Str::op_start) && !vm_.pending(Str::op_stop);
    switch (s.phase) {
    case Phase::stopped:
    case Phase::failed: break;
    case Phase::starting:
        serial_label = tr(Str::disconnect_serial);
        serial_tone = Tone::normal;
        break;
    case Phase::running:
        serial_label = tr(Str::disconnect_serial);
        serial_tone = Tone::normal;
        break;
    case Phase::stopping:
        serial_label = tr(Str::disconnecting_serial);
        serial_tone = Tone::normal;
        serial_enabled = false;
        break;
    }
    if (button(serial_label, ImVec2(bw, 0.0F), serial_tone, serial_enabled)) {
        if (s.phase == Phase::stopped || s.phase == Phase::failed) {
            vm_.start();
        } else {
            vm_.stop();
        }
    }
    ImGui::SameLine();
    const bool connecting = s.bm_requested_enabled && s.bm_link != BmLink::connected;
    const char* bm_label = !s.bm_requested_enabled ? tr(Str::connect_bm)
                           : connecting            ? tr(Str::connecting_bm)
                                                   : tr(Str::disconnect_bm);
    if (vm_.pending(Str::op_bm)) bm_label = s.bm_requested_enabled ? tr(Str::disconnecting_bm) : tr(Str::connecting_bm);
    if (button(bm_label, ImVec2(bw, 0.0F), s.bm_requested_enabled ? Tone::normal : Tone::ok,
               s.phase == Phase::running && !vm_.pending(Str::op_bm))) {
        vm_.toggle_bm();
    }
    if (vm_.pending(Str::op_start) || vm_.pending(Str::op_bm) || s.phase == Phase::starting ||
        s.bm_link == BmLink::resolving || s.bm_link == BmLink::connecting) {
        continuous_ = true; // 显示等待动画
        ImGui::SameLine(0.0F, px(12.0F));
        static const char* const spinner[] = {"·  ", "·· ", "···"};
        const int frame = static_cast<int>(ImGui::GetTime() * 4.0) % 3;
        ImGui::AlignTextToFramePadding();
        caption(spinner[frame]);
    }

    const auto& cfg = vm_.config();
    const auto ident = cfg.callsign.empty() ? std::string("—") : fmt("%s · DMR ID %u", cfg.callsign.c_str(), cfg.dmr_id);
    const float ident_w = ImGui::CalcTextSize(ident.c_str()).x;
    ImGui::SameLine(ImGui::GetWindowContentRegionMax().x - ident_w);
    ImGui::AlignTextToFramePadding();
    ImGui::PushStyleColor(ImGuiCol_Text, vec(color::muted));
    ImGui::TextUnformatted(ident.c_str());
    ImGui::PopStyleColor();
}

void AppView::draw_settings() {
    const std::string popup_label = std::string(tr(Str::settings_title)) + "##settings";
    const char* popup_id = popup_label.c_str();
    if (settings_requested_) {
        ImGui::OpenPopup(popup_id);
        settings_requested_ = false;
    }
    const ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->GetCenter(), ImGuiCond_Appearing, ImVec2(0.5F, 0.5F));
    ImGui::SetNextWindowSize(ImVec2(px(620.0F), 0.0F), ImGuiCond_Appearing);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, vec(color::panel));
    ImGui::PushStyleColor(ImGuiCol_Border, vec(color::input_border));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.0F);
    if (!ImGui::BeginPopupModal(popup_id, nullptr, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoSavedSettings)) {
        ImGui::PopStyleVar();
        ImGui::PopStyleColor(2);
        return;
    }
    continuous_ = true;
    const float w = ImGui::GetContentRegionAvail().x;
    const float gap = ImGui::GetStyle().ItemSpacing.x;
    auto input = [](const char* id, std::string& value, ImGuiInputTextFlags flags = 0) {
        ImGui::TableNextColumn();
        ImGui::SetNextItemWidth(-FLT_MIN);
        input_text(id, value, flags);
    };
    auto endpoint_combo = [](const char* id, const std::vector<services::AudioEndpointInfo>& list, std::wstring& value) {
        ImGui::TableNextColumn();
        std::string preview = "—";
        for (const auto& e : list) {
            if (e.endpoint_id == value) preview = e.name;
        }
        ImGui::SetNextItemWidth(-FLT_MIN);
        if (ImGui::BeginCombo(id, preview.c_str())) {
            for (const auto& e : list) {
                if (ImGui::Selectable(e.name.c_str(), e.endpoint_id == value)) value = e.endpoint_id;
            }
            ImGui::EndCombo();
        }
    };

    if (begin_fields("##ident", {{tr(Str::callsign), 1.0F, 0.0F}, {tr(Str::dmr_id), 1.0F, 0.0F}, {tr(Str::device_no), 1.0F, 0.0F}})) {
        input("##cs", draft_.callsign, ImGuiInputTextFlags_CharsUppercase | ImGuiInputTextFlags_CharsNoBlank);
        input("##id", draft_dmr_id_, ImGuiInputTextFlags_CharsDecimal);
        input("##devno", draft_.device_number, ImGuiInputTextFlags_CharsDecimal);
        ImGui::EndTable();
    }
    int preset = draft_.master_preset == "custom" ? 1 : 0;
    if (begin_fields("##server", {{tr(Str::bm_server), 1.0F, 0.0F}, {tr(Str::udp_port), 1.0F, 0.0F}, {tr(Str::host_ipv4), 1.0F, 0.0F}})) {
        ImGui::TableNextColumn();
        const char* presets[] = {"BM 4602", tr(Str::custom)};
        if (simple_combo("##preset", preset, presets, 2, -FLT_MIN)) {
            draft_.master_preset = preset == 1 ? "custom" : "bm-china-4602";
            if (preset == 0) {
                draft_.master_host = "43.129.83.124";
                draft_master_port_ = "62031";
            }
        }
        ImGui::BeginDisabled(preset == 0);
        input("##mport", draft_master_port_, ImGuiInputTextFlags_CharsDecimal);
        input("##mhost", draft_.master_host, ImGuiInputTextFlags_CharsNoBlank);
        ImGui::EndDisabled();
        ImGui::EndTable();
    }
    if (begin_fields("##secrets", {{tr(Str::bm_password), 1.0F, 0.0F}, {tr(Str::bm_api_key), 1.0F, 0.0F}})) {
        input("##pw", draft_.bm_password, ImGuiInputTextFlags_Password);
        input("##api", draft_.bm_api_key, ImGuiInputTextFlags_Password);
        ImGui::EndTable();
    }

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();
    section_title(tr(Str::audio_devices), fonts_.bold);
    if (begin_fields("##ports", {{tr(Str::wiresx_port), 1.0F, 0.0F}, {" ", 1.0F, 0.0F}})) {
        ImGui::TableNextColumn();
        std::vector<std::string> ports;
        for (const auto& p : vm_.devices().serial_ports) ports.push_back(to_utf8(p.port));
        if (const int picked = editable_combo("##hri", draft_hri_port_, ports, ImGui::GetContentRegionAvail().x); picked >= 0) {
            draft_hri_port_ = ports[static_cast<std::size_t>(picked)];
        }
        ImGui::TableNextColumn();
        if (button(tr(Str::refresh_devices), ImVec2(-FLT_MIN, 0.0F))) vm_.refresh_devices();
        ImGui::EndTable();
    }
    if (begin_fields("##audio", {{tr(Str::input), 1.0F, 0.0F}, {tr(Str::output), 1.0F, 0.0F}})) {
        endpoint_combo("##wavein", vm_.devices().wave_in, draft_.wave_in_endpoint_id);
        endpoint_combo("##waveout", vm_.devices().wave_out, draft_.wave_out_endpoint_id);
        ImGui::EndTable();
    }

    ImGui::Spacing();
    ImGui::PushFont(nullptr, 12.0F);
    ImGui::PushStyleColor(ImGuiCol_Text, vec(settings_error_.empty() ? color::muted : color::warn));
    ImGui::TextWrapped("%s", settings_error_.empty() ? tr(Str::settings_need_restart) : settings_error_.c_str());
    ImGui::PopStyleColor();
    ImGui::PopFont();
    ImGui::Spacing();

    const float bw = px(110.0F);
    ImGui::SetCursorPosX(ImGui::GetCursorPosX() + w - bw * 2.0F - gap);
    if (button(tr(Str::save_settings), ImVec2(bw, 0.0F), Tone::ok)) {
        auto next = draft_;
        bool ok = true;
        auto parse_u = [&](const std::string& text, std::uint32_t max, std::uint32_t& out) {
            if (text.empty()) {
                out = 0U;
                return true;
            }
            try {
                const auto v = std::stoul(text);
                if (v > max) return false;
                out = static_cast<std::uint32_t>(v);
                return true;
            } catch (const std::exception&) {
                return false;
            }
        };
        std::uint32_t port = 0U;
        if (!parse_u(draft_dmr_id_, 0xFFFFFFFFU, next.dmr_id)) {
            settings_error_ = fmt(tr(Str::settings_save_failed), tr(Str::dmr_id));
            ok = false;
        } else if (!parse_u(draft_master_port_, 65535U, port) || port == 0U) {
            settings_error_ = fmt(tr(Str::settings_save_failed), tr(Str::udp_port));
            ok = false;
        }
        if (ok) {
            next.master_port = static_cast<std::uint16_t>(port);
            next.hri_port = from_utf8(draft_hri_port_);
            std::string error;
            if (vm_.save_config(next, error)) {
                ImGui::CloseCurrentPopup();
            } else {
                settings_error_ = fmt(tr(Str::settings_save_failed), error.c_str());
            }
        }
    }
    ImGui::SameLine();
    if (button(tr(Str::close), ImVec2(bw, 0.0F)) || ImGui::IsKeyPressed(ImGuiKey_Escape)) ImGui::CloseCurrentPopup();
    ImGui::EndPopup();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(2);
}

} // namespace wirex::gui
