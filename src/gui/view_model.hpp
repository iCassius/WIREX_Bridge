#pragma once

// 主控制台 ViewModel：视图只读这里的状态并调用这里的命令。
// - 引擎侧只通过 EngineApi（与 engine::Engine 方法一一对应）交互；
// - CAT/配置/设备/BM API 通过 services::Services 占位接口交互；
// - 所有成员只在 UI 线程访问；其它线程的回调经 post_to_ui() 排队，在 pump() 中执行。

#include "engine_api.hpp"
#include "services.hpp"
#include "startup_group_activation.hpp"
#include "strings.hpp"

#include <array>
#include <chrono>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace wirex::gui {

struct CallRecord {
    engine::CallInfo call{};
    std::chrono::system_clock::time_point started_wall{};
};

struct ChannelKey {
    std::uint32_t id{};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    [[nodiscard]] bool operator==(const ChannelKey& o) const noexcept {
        return id == o.id && kind == o.kind && slot == o.slot;
    }
    [[nodiscard]] bool operator<(const ChannelKey& o) const noexcept {
        if (id != o.id) return id < o.id;
        if (kind != o.kind) return kind < o.kind;
        return slot < o.slot;
    }
};

struct ChannelView {
    services::ChannelEntry entry{};
    ChannelKey key{};
    std::string title{};          // "组呼 46001 · 全国 · 动态组"
    std::string tooltip{};
    bool is_tx_target{};
    bool is_tx_active{};
    bool is_muted{};
    bool is_static{};
    bool quick_call_sent{};
    bool quick_call_pending{};
    bool quick_call_allowed{};    // 组呼且不是 TG 4000
    std::optional<engine::CallInfo> current_call{};
    std::optional<CallRecord> last_call{};  // 空闲时显示该频道最近一次来话
};

// BM 静态组面板（对应 ui/windows/BmManagementUi.ps1）。
struct StaticGroupsView {
    static constexpr std::size_t page_size = 3U;
    std::vector<services::StaticGroup> groups{};
    std::optional<int> add_slot{};          // 设备状态 4 → 0，0..3 → 2；空：添加禁用
    std::optional<std::int64_t> device_status{};
    bool loaded{};                          // groups 属于 observed_device/observed_key
    bool busy{};
    bool refresh_pending{};
    std::uint32_t observed_device{};
    std::string observed_key{};
    std::size_t page{};
    std::optional<std::size_t> selected{};  // groups 下标
    std::string status{};
    bool status_failed{};
    std::string tg_input{};
};

enum class FontStatus : std::uint8_t { segoe_deng, segoe_simhei, fallback_default };

struct CatForm {
    std::string port{};
    int baud_index{3};            // 4800/9600/19200/38400/115200
    int mode_index{-1};           // FM/FM-N/C4FM-DN/C4FM-VW
    std::string frequency_mhz{};
    int power_index{-1};          // 5/10/15/25/50 W；-1 表示尚无可信 CAT 读回
};

enum class CatFormField : std::uint8_t { mode, frequency, power };

// 单次 pump 中完成的多条命令结果会逐条入队，避免短暂错误被后续结果覆盖。
struct OperationEvent {
    std::uint64_t sequence{};
    Str operation{Str::core};
    std::string message{};
    bool failed{};
};

class ViewModel {
public:
    static constexpr std::size_t channel_page_size = 6U;
    static constexpr std::size_t history_page_size = 5U;
    static constexpr std::size_t history_limit = 200U;

    ViewModel(EngineApi& engine, services::Services services, bool fake);
    ViewModel(const ViewModel&) = delete;
    ViewModel& operator=(const ViewModel&) = delete;
    ~ViewModel();

    // UI 线程唤醒回调（main 设置为 SetEvent）；引擎与 services 回调会调用它。
    void set_wakeup(std::function<void()> wakeup);
    // 每帧开头调用：取快照、取事件、完成到期命令、执行排队回调。返回 true 表示有状态变化。
    bool pump();
    // 下一次需要重绘的等待时间（毫秒）；INFINITE 语义用 nullopt 表示。
    [[nodiscard]] std::optional<std::uint32_t> idle_timeout_ms() const;

    // ---------- 读取 ----------
    [[nodiscard]] const engine::Snapshot& snapshot() const noexcept { return *snapshot_; }
    [[nodiscard]] bool fake() const noexcept { return fake_; }
    [[nodiscard]] const services::GuiConfig& config() const noexcept { return config_; }
    [[nodiscard]] const services::DeviceInventory& devices() const noexcept { return devices_; }
    [[nodiscard]] services::DeviceSelectionSnapshot device_selection() const;
    [[nodiscard]] const services::CatState& cat() const noexcept { return cat_; }
    [[nodiscard]] bool cat_available() const noexcept { return static_cast<bool>(services_.cat.connect); }
    [[nodiscard]] std::vector<ChannelView> channel_page() const;
    [[nodiscard]] std::size_t channel_count() const noexcept { return config_.channels.size(); }
    [[nodiscard]] std::size_t channel_page_index() const noexcept { return channel_page_; }
    [[nodiscard]] std::size_t channel_page_count() const noexcept;
    [[nodiscard]] const std::deque<CallRecord>& history() const noexcept { return history_; }
    [[nodiscard]] std::size_t history_page_index() const noexcept { return history_page_; }
    [[nodiscard]] std::size_t history_page_count() const noexcept;
    [[nodiscard]] std::optional<std::size_t> selected_history() const noexcept { return selected_history_; }
    [[nodiscard]] std::vector<CallRecord> recent_callers(std::size_t max) const;
    [[nodiscard]] std::optional<std::chrono::system_clock::time_point> current_call_started() const;
    // 当前来话（呼号缺失时用身份查询结果补全）。
    [[nodiscard]] std::optional<engine::CallInfo> active_call() const;
    [[nodiscard]] engine::CallInfo with_callsign(engine::CallInfo call) const;
    [[nodiscard]] const StaticGroupsView& static_groups() const noexcept { return static_; }
    [[nodiscard]] std::uint32_t bm_device_id() const noexcept { return services::effective_gateway_id(config_); }
    [[nodiscard]] bool bm_api_available() const noexcept { return static_cast<bool>(services_.bm_api.list_static_groups); }
    [[nodiscard]] bool pending(Str op) const;
    [[nodiscard]] const std::string& transient_text() const noexcept { return transient_text_; }
    [[nodiscard]] bool transient_failed() const noexcept { return transient_failed_; }
    [[nodiscard]] bool transient_visible() const;
    [[nodiscard]] std::vector<OperationEvent> drain_operation_events();
    [[nodiscard]] const std::string& startup_group_activation_status() const noexcept {
        return startup_group_activation_status_;
    }
    [[nodiscard]] bool startup_group_activation_active() const noexcept {
        return startup_group_activation_.active();
    }
    [[nodiscard]] bool engine_running() const noexcept;
    [[nodiscard]] bool can_mutate_channels() const noexcept;
    [[nodiscard]] FontStatus font_status() const noexcept { return font_status_; }
    void set_font_status(FontStatus status) noexcept { font_status_ = status; }

    // 视图可直接编辑的表单状态
    CatForm cat_form{};
    int playback_step{1};
    int transmit_step{16};
    std::string add_channel_id{};
    int add_channel_kind{0};      // 0 请选择 / 1 单呼 / 2 组呼

    // ---------- 命令（对应 engine::Engine 方法） ----------
    void start();                 // engine.start（连接串口）
    void stop();                  // engine.stop（断开串口）
    void toggle_bm();             // engine.set_bm_connection
    void set_tx_target(const ChannelKey& key);   // engine.replace_tx_policy
    void remove_channel(const ChannelKey& key);  // engine.replace_rx_policy
    void toggle_mute(const ChannelKey& key);     // engine.replace_rx_policy
    void add_channel();                          // engine.replace_rx_policy
    void quick_call(const ChannelKey& key);      // engine.quick_call_join
    void commit_gains();                         // engine.set_audio_gains
    void set_audio_devices(std::wstring wave_in_endpoint_id, std::wstring wave_out_endpoint_id);
    void set_audio_output(std::wstring wave_out_endpoint_id); // BM-only output selection; no HRI/WaveIn required
    void set_history_target();                   // engine.replace_tx_policy（来话历史所选条目）

    // ---------- 其它服务 ----------
    void cat_toggle_connection();
    void cat_apply();
    void set_cat_form_editing(CatFormField field, bool editing) noexcept;
    void mark_cat_form_edited(CatFormField field) noexcept;
    void refresh_devices();
    [[nodiscard]] bool save_config(const services::GuiConfig& next, std::string& error);
    void set_channel_page(std::size_t page);
    void set_history_page(std::size_t page);
    // BM 静态组
    void static_refresh();
    void static_add();
    void static_remove();
    void static_set_page(std::size_t page);
    void static_select(std::optional<std::size_t> index);
    StaticGroupsView& static_form() noexcept { return static_; }
    void select_history(std::optional<std::size_t> index);
    void request_exit() noexcept { exit_requested_ = true; }
    [[nodiscard]] bool exit_requested() const noexcept { return exit_requested_; }

private:
    struct PendingOp {
        Str op;
        std::future<engine::CommandResult> future;
        std::function<void(const engine::CommandResult&)> on_done;
    };

    // 跨线程投递：后台回调只持有 Mailbox 的 shared_ptr；ViewModel 析构时关闭信箱，之后的投递被丢弃。
    struct Mailbox {
        std::mutex mutex;
        std::vector<std::function<void()>> actions;
        std::function<void()> wakeup;
        bool closed{};
        void post(std::function<void()> action);
    };

    void track(Str op, std::future<engine::CommandResult> future,
               std::function<void(const engine::CommandResult&)> on_done = {});
    void post_to_ui(std::function<void()> action);
    void report(Str op, const engine::CommandResult& result);
    void flash(std::string text, bool failed, Str operation = Str::core);
    void enqueue_operation_event(Str operation, const std::string& message, bool failed);
    void handle_event(const engine::Event& event);
    [[nodiscard]] talkgroup_routing::RxPolicy build_rx_policy() const;
    [[nodiscard]] std::optional<talkgroup_routing::TxTarget> current_tx_target() const;
    void push_rx_policy();
    void persist();
    [[nodiscard]] std::chrono::system_clock::time_point to_wall(std::uint64_t engine_ms) const;
    // BM 静态组 / 身份查询
    void static_sync();
    void static_status(std::string text, bool failed);
    void static_apply(const services::BmApiResult& result, bool write);
    [[nodiscard]] bool is_static_channel(const services::ChannelEntry& entry) const;
    void lookup_identity(const engine::CallInfo& call);
    void apply_identity(const services::IdentityResult& result);
    void push_identity(std::uint32_t source_id, std::optional<std::string> callsign);
    void on_engine_running();
    [[nodiscard]] bool pump_startup_group_activation();
    void update_startup_group_activation_status();
    void sync_cat_form_from_observed(const services::CatState& state);
    [[nodiscard]] std::optional<engine::RadioStartConfig> make_radio_start_config(std::string& error) const;
    [[nodiscard]] std::optional<engine::BmTarget> make_bm_target(std::string& error) const;

    EngineApi& engine_;
    services::Services services_;
    bool fake_;
    std::shared_ptr<const engine::Snapshot> snapshot_;
    services::GuiConfig config_{};
    services::DeviceInventory devices_{};
    services::CatState cat_{};
    std::array<bool, 3> cat_form_dirty_{};
    std::array<bool, 3> cat_form_editing_{};
    std::array<std::uint64_t, 3> cat_form_edit_revision_{};
    std::uint64_t last_cat_observed_revision_{};
    std::set<ChannelKey> muted_{};
    std::set<ChannelKey> quick_call_sent_{};
    std::optional<ChannelKey> quick_call_pending_{};
    StartupGroupActivation startup_group_activation_{};
    std::optional<ChannelKey> startup_group_activation_last_target_{};
    std::string startup_group_activation_status_{};
    StaticGroupsView static_{};
    std::map<std::uint32_t, std::string> callsigns_{};     // RadioID 查询得到的呼号
    std::set<std::uint32_t> identity_requested_{};
    std::uint64_t identity_revision_{};                    // 每次引擎进入 running 从 0 开始
    std::uint64_t radio_connection_generation_{};            // 取消过期的并行 CAT 连接回调
    std::uint64_t bm_profile_generation_{};                  // 保存 BM 会话字段后递增，使旧 configure 回调失效
    bool bm_configure_pending_{};                           // 允许保存新配置，但旧配置完成后不得发起连接
    std::vector<std::future<engine::CommandResult>> identity_ops_{};
    engine::Phase last_phase_{engine::Phase::stopped};
    std::deque<CallRecord> history_{};
    std::size_t channel_page_{};
    std::size_t history_page_{};
    std::optional<std::size_t> selected_history_{};
    std::vector<PendingOp> pending_{};
    std::string transient_text_{};
    bool transient_failed_{};
    std::chrono::steady_clock::time_point transient_until_{};
    std::deque<OperationEvent> operation_events_{};
    std::uint64_t next_operation_event_sequence_{1U};
    FontStatus font_status_{FontStatus::segoe_deng};
    bool exit_requested_{};
    bool suppress_cancelled_start_report_{};

    std::shared_ptr<Mailbox> mailbox_{std::make_shared<Mailbox>()};
};

// 显示用的小工具
[[nodiscard]] std::string to_utf8(const std::wstring& w);
[[nodiscard]] std::wstring from_utf8(const std::string& s);
[[nodiscard]] std::string channel_display_name(const services::ChannelEntry& entry);
[[nodiscard]] std::string format_clock(std::chrono::system_clock::time_point t);
[[nodiscard]] const char* bm_link_text(engine::BmLink link);
[[nodiscard]] const char* phase_text(const engine::Snapshot& s);
[[nodiscard]] const char* command_status_text(engine::CommandStatus status);

inline constexpr std::uint32_t kBaudRates[] = {4800U, 9600U, 19200U, 38400U, 115200U};
inline constexpr std::uint32_t kPowerWatts[] = {5U, 10U, 15U, 25U, 50U};
inline constexpr const char* kCatModes[] = {"FM", "FM-N", "C4FM-DN", "C4FM-VW"};

} // namespace wirex::gui
