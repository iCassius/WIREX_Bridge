#pragma once

// 主控制台视图（Dear ImGui）。只依赖 ViewModel：读取其状态并调用其命令。
// 布局对应 ui/windows/MainWindow.xaml（R126）：标题栏状态 / 频道卡片 3×2 / 来话历史 + 当前来话 + 最近来话 /
// 电台控制 + 日常控制 / 底部操作行；设置为模态弹窗。

#include "services.hpp"
#include "view_model.hpp"

#include <string>

struct ImFont;

namespace wirex::gui {

struct Fonts {
    ImFont* regular{};
    ImFont* bold{};   // 可能与 regular 相同（未找到粗体文件时）
};

// 设置深色主题（配色取自 MainWindow.xaml），并按 DPI 缩放尺寸。可在 DPI 变化时重复调用。
void apply_theme(float dpi_scale);

class AppView {
public:
    AppView(ViewModel& vm, Fonts fonts);

    // 绘制一帧（在 ImGui::NewFrame 与 ImGui::Render 之间调用）。
    void draw(float dpi_scale);
    void open_settings();
    // 有需要持续重绘的交互（拖动滑块、弹窗动画等）时返回 true。
    [[nodiscard]] bool wants_continuous() const noexcept { return continuous_; }

private:
    void draw_header();
    void draw_channels(float height);
    void draw_channel_card(const ChannelView& ch, float width, float height);
    void draw_calls(float height);
    void draw_history(float width, float height);
    void draw_current_call(float width, float height);
    void draw_recent_calls(float width, float height);
    void draw_radio_panel(float width, float height);
    void draw_daily_panel(float width, float height);
    void draw_footer();
    void draw_settings();
    [[nodiscard]] float px(float logical) const noexcept { return logical * scale_; }

    ViewModel& vm_;
    Fonts fonts_;
    float scale_{1.0F};
    bool continuous_{};
    bool settings_requested_{};

    // 设置弹窗草稿
    services::GuiConfig draft_{};
    std::string draft_dmr_id_{};
    std::string draft_master_port_{};
    std::string draft_hri_port_{};
    std::string settings_error_{};
};

} // namespace wirex::gui
