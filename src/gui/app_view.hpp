#pragma once

// 主控制台视图（Dear ImGui）。只依赖 ViewModel：读取其状态并调用其命令。
// 深色控制台布局：对齐标题/状态栏 / 频道卡片 3×2 / 来话三卡 / 电台与音频控制 + 频道/增益面板；
// 串口和 BM 账户配置直接在主界面编辑。

#include "services.hpp"
#include "view_model.hpp"

#include <cstdint>
#include <deque>
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
    // 有需要持续重绘的交互（拖动滑块、弹窗动画等）时返回 true。
    [[nodiscard]] bool wants_continuous() const noexcept { return continuous_; }

private:
    struct ConnectionLogEntry {
        std::string time;
        Str source{Str::core};
        std::string message;
        bool failed{};
        bool resolved{};
    };

    void draw_header();
    void draw_connection_log_popup();
    void add_connection_event(Str source, std::string message, bool failed);
    void resolve_connection_error(Str source, std::string message);
    void draw_channels(float height);
    void draw_channel_card(const ChannelView& ch, float width, float height);
    void draw_calls(float height);
    void draw_history(float width, float height);
    void draw_current_call(float width, float height);
    void draw_recent_calls(float width, float height);
    void draw_radio_panel(float width, float height);
    void draw_daily_panel(float width, float height);
    void update_connection_log();
    void draw_audio_devices(float inner_w);
    void draw_static_groups(float inner_w);
    void toggle_language();
    void toggle_radio();
    void toggle_bm();
    void save_bm_config();
    [[nodiscard]] float px(float logical) const noexcept { return logical * scale_; }

    ViewModel& vm_;
    Fonts fonts_;
    float scale_{1.0F};
    bool continuous_{};
    // 主界面 BM 配置草稿
    services::GuiConfig draft_{};
    std::string draft_dmr_id_{};
    std::string draft_master_port_{};
    std::string settings_error_{};
    std::string language_notice_{};
    std::string audio_notice_{};
    std::deque<ConnectionLogEntry> connection_events_{};
    std::string last_settings_error_{};
    std::string last_bm_error_{};
    std::string last_radio_error_{};
    std::string last_core_failure_{};
    std::string last_cat_error_{};
    std::uint64_t last_bm_connection_revision_{};
    std::uint64_t last_audio_endpoints_revision_{};
    std::uint64_t last_cat_revision_{};
    engine::BmLink last_bm_link_{engine::BmLink::disabled};
    engine::Phase last_core_phase_{engine::Phase::stopped};
    bool connection_states_initialized_{};
    bool last_serial_open_{};
    bool last_hri_ready_{};
    bool last_cat_connected_{};
    std::wstring pending_wave_in_{};
    std::wstring pending_wave_out_{};
    bool audio_selection_pending_{};
};

} // namespace wirex::gui
