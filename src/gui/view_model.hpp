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
#include <limits>
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
    // R130 FM 中继记录（与 BM 来话混排）：relay_fm=true 时 call 只用 destination_id/kind/slot 表示上行目标，
    // source_id 为 0（FM 无呼号）。
    bool relay_fm{};
    std::uint64_t relay_duration_ms{};
    std::optional<unsigned> relay_s_peak{};
    std::string relay_end_reason{};
};

// FM 中继状态（右上角提示）。
enum class RelayStatus : std::uint8_t { off, c4fm_only, no_cat, waiting, active };

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

// ---------------------------------------------------------------- 频道卡片状态机（R131）
//
// 每张卡片右上角一个状态徽标，按钮只有“设为PTT”“移除”和一个主操作按钮。
//
//   状态                徽标             主按钮      主按钮事件 → 新状态
//   static_live         静态组           静音        toggle_mute → static_muted（引擎静音输出，仍收听）
//   static_muted        静音             取消静音    toggle_mute → static_live
//   dynamic_inactive    动态·未激活      启用        enable → Quick Call；accepted → dynamic_active
//   dynamic_active      动态·已激活      停用        disable → 移出 RX 策略 + TG4000 → disabled
//   disabled            已停用（灰卡）   启用        enable → 加回 RX 策略 + Quick Call → dynamic_active
//   listen              —（私呼/TG4000） 停用        disable → disabled（只改 RX 策略）
//
// 其它事件：
//   - 启动组呼 / Quick Call accepted                   → dynamic_inactive → dynamic_active
//   - TG4000 accepted（断开该时隙全部动态组）          → 同时隙其它 dynamic_active → dynamic_inactive
//   - BM 静态组读回包含该 TG                           → dynamic_* → static_live（保留 muted 标志）
//   - Quick Call 只表示两帧已由本机发出，不表示 BM 已确认（见 R128_NATIVE_GUI“启动组呼”）。
// muted / disabled 持久化到 config.json channels[].muted / disabled；dynamic_active 只在本次进程内有效。
enum class ChannelState : std::uint8_t { listen, static_live, static_muted, dynamic_inactive, dynamic_active, disabled };

struct ChannelView {
    services::ChannelEntry entry{};
    ChannelKey key{};
    std::string title{};          // "组呼 46001 · 全国 · 动态组"
    std::string tooltip{};
    bool is_tx_target{};
    bool is_tx_active{};
    bool is_muted{};              // 静音输出（照常接收显示）
    bool is_disabled{};           // 已停用（不在 RX 策略中）
    bool is_static{};
    ChannelState state{ChannelState::listen};
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

// 最近被收听策略过滤的 BM 流量（Snapshot::last_filtered），只在 window 内显示提示。
struct FilteredHint {
    static constexpr std::chrono::seconds window{30};
    engine::FilteredTraffic traffic{};
    std::uint32_t age_s{};
    ChannelKey key{};             // “加入收听”要加入的频道：组呼为 TG，私呼为对端 ID
};

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
    [[nodiscard]] std::optional<FilteredHint> filtered_hint() const;
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
    // 引擎线程已结束（stopped/failed）：串口、HRI、音频、BM 都不可能仍在工作。
    [[nodiscard]] bool engine_stopped() const noexcept;
    // 电台链路是否处于“已连接/连接中”（决定连接按钮是断开还是连接）。引擎已停止时恒为 false，
    // 即使最后一份快照仍残留 serial_open/hri_ready。
    [[nodiscard]] bool radio_link_active() const noexcept;
    // 引擎停止且带失败原因时的标题栏文案（友好文案 + 机器码 detail）；否则为空。
    [[nodiscard]] std::string engine_failure_banner() const;
    [[nodiscard]] bool can_mutate_channels() const noexcept;
    [[nodiscard]] FontStatus font_status() const noexcept { return font_status_; }
    // R130 中继
    [[nodiscard]] bool relay_enabled() const noexcept { return config_.relay_enabled; }
    [[nodiscard]] bool relay_fm_enabled() const noexcept { return config_.relay_fm_enabled; }
    [[nodiscard]] bool relay_fm_supported() const noexcept { return static_cast<bool>(services_.cat.set_squelch_polling); }
    [[nodiscard]] RelayStatus relay_status() const noexcept;
    // R131 BM 重连冷却：断开后 5 s 内“连接 BM”不可用，返回剩余整秒（向上取整）；0 表示可连接。
    static constexpr std::chrono::seconds bm_reconnect_cooldown{5};
    [[nodiscard]] unsigned bm_cooldown_remaining_s() const;
    // R131 服务器尚未释放上次会话（master_rejected，紧随本进程内一次成功连接后的断开）：
    // ViewModel 自动重试；返回距下次重试的整秒（0 表示正在重试）。无此状态时为空。
    [[nodiscard]] std::optional<unsigned> bm_stale_session_retry_s() const;
    // R131 Windows 端点音量（0..100），未知时为空；error 为最近一次读写失败原因。
    [[nodiscard]] const std::optional<int>& playback_volume() const noexcept { return playback_volume_.percent; }
    [[nodiscard]] const std::optional<int>& transmit_volume() const noexcept { return transmit_volume_.percent; }
    [[nodiscard]] const std::string& playback_volume_error() const noexcept { return playback_volume_.error; }
    [[nodiscard]] const std::string& transmit_volume_error() const noexcept { return transmit_volume_.error; }
    // R131 CAT：被门控拒绝、等待自动重试的提示（空表示无）。
    [[nodiscard]] const std::string& cat_deferred_text() const noexcept { return cat_deferred_text_; }
    void set_font_status(FontStatus status) noexcept { font_status_ = status; }

    // 视图可直接编辑的表单状态
    CatForm cat_form{};
    // 高级：额外数字增益（默认 1×，只在本次运行有效，不写入 config）。主控件是 Windows 端点音量。
    int playback_step{1};
    int transmit_step{1};
    std::string add_channel_id{};
    int add_channel_kind{0};      // 0 请选择 / 1 单呼 / 2 组呼

    // ---------- 命令（对应 engine::Engine 方法） ----------
    void start();                 // engine.start（连接串口）
    void stop();                  // engine.stop（断开串口）
    void toggle_bm();             // engine.set_bm_connection
    void set_tx_target(const ChannelKey& key);   // engine.replace_tx_policy
    void remove_channel(const ChannelKey& key);  // engine.replace_rx_policy
    // 静态组频道：先从 BM 移除静态组（保留原 API slot），成功后再取消收听；失败时频道保留。
    // 未设置 API Key 时只取消收听并提示 BM 未改动。
    void remove_static_channel(const ChannelKey& key);
    void toggle_mute(const ChannelKey& key);     // 静态组静音（engine.set_muted_groups；不改 RX 策略）
    void disable_channel(const ChannelKey& key); // 停用：移出 RX 策略；动态组另发 TG4000
    void enable_channel(const ChannelKey& key);  // 启用：加回 RX 策略；动态组 Quick Call 激活
    void channel_primary_action(const ChannelKey& key); // 按卡片状态执行主按钮（见状态机）
    void add_channel();                          // engine.replace_rx_policy
    void listen_filtered();                      // 把 filtered_hint() 的 TG/私呼加入频道（已屏蔽则恢复）
    void quick_call(const ChannelKey& key);      // engine.quick_call_join
    void commit_gains();                         // engine.set_audio_gains（高级数字增益，不保存）
    void commit_volume(bool playback, int percent); // 写所选 WaveOut / WaveIn 端点的 Windows 音量（0..100）
    void set_audio_devices(std::wstring wave_in_endpoint_id, std::wstring wave_out_endpoint_id);
    void set_audio_output(std::wstring wave_out_endpoint_id); // BM-only output selection; no HRI/WaveIn required
    void set_history_target();                   // engine.replace_tx_policy（来话历史所选条目）
    void toggle_relay();                         // relay.enabled（保存配置；电台需重连后生效）
    void toggle_relay_fm();                      // relay.fm_enabled（仅中继开启时可切换）
    // 仅截图验收（--screenshot-relay-demo）：在内存中开启中继与 FM，不写配置。
    void preview_relay_enabled() noexcept;
    // 仅截图验收（--screenshot-channel-states）：在内存中造出全部卡片状态（不写配置）：
    // 46001 静态组静音、2345 动态·未激活、3100 动态·已激活、46002 已停用、46010 静态组。
    void preview_channel_states();

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
    // 频道对应的 BM 静态组（API slot 原值）；不是静态组时为空。
    [[nodiscard]] std::optional<services::StaticGroup> static_group_for(const ChannelKey& key) const;
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
    void push_muted_groups();
    [[nodiscard]] std::vector<talkgroup_routing::GroupRoute> muted_groups() const;
    [[nodiscard]] services::ChannelEntry* find_channel(const ChannelKey& key);
    [[nodiscard]] ChannelState channel_state(const services::ChannelEntry& entry, bool is_static) const;
    void observe_bm_link();
    struct VolumeTarget {
        std::wstring endpoint_id{};
        std::optional<int> percent{};
        std::string error{};
        std::shared_ptr<void> watch{};
        std::uint64_t generation{};
    };
    void sync_volume_target(VolumeTarget& target, const std::wstring& endpoint_id, bool playback);
    void sync_volume_targets();
    void retry_deferred_cat();
    void submit_cat_mode_frequency(services::CatSettings settings,
                                   std::array<std::uint64_t, 3> revisions);
    void submit_cat_power(std::uint32_t watts, bool hri, std::uint64_t revision);
    void service_hri_power_confirmation();
    void persist_power(std::uint32_t watts, std::uint64_t revision);
    void add_channel_entry(services::ChannelEntry entry);
    [[nodiscard]] std::chrono::system_clock::time_point to_wall(std::uint64_t engine_ms) const;
    // BM 静态组 / 身份查询
    void static_sync();
    void static_status(std::string text, bool failed);
    void static_apply(const services::BmApiResult& result, bool write);
    [[nodiscard]] bool is_static_channel(const services::ChannelEntry& entry) const;
    void import_static_channels();
    void resolve_startup_static();
    void erase_channel(const ChannelKey& key);
    void lookup_identity(const engine::CallInfo& call);
    void apply_identity(const services::IdentityResult& result);
    void push_identity(std::uint32_t source_id, std::optional<std::string> callsign);
    void on_engine_running();
    [[nodiscard]] bool pump_startup_group_activation();
    void update_startup_group_activation_status();
    void sync_cat_form_from_observed(const services::CatState& state);
    [[nodiscard]] std::optional<engine::RadioStartConfig> make_radio_start_config(std::string& error) const;
    [[nodiscard]] std::optional<engine::BmTarget> make_bm_target(std::string& error) const;
    // R130 FM 中继
    void update_squelch_polling();
    void on_squelch(const services::SquelchEvent& event);
    void request_relay_fm_stop();
    void request_relay_fm_mute(bool muted);
    void finish_relay_record(const engine::Event& event);
    void write_relay_record(const CallRecord& record);

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
    std::set<ChannelKey> quick_call_sent_{};
    std::optional<ChannelKey> enable_after_policy_{};      // 启用动态组：RX 策略下发后再 Quick Call
    bool muted_groups_dirty_{};
    // BM 冷却 / 旧会话重试
    std::optional<std::chrono::steady_clock::time_point> bm_disconnected_at_{};
    std::optional<std::chrono::steady_clock::time_point> bm_last_connected_at_{};
    std::uint64_t bm_connected_profile_generation_{std::numeric_limits<std::uint64_t>::max()};
    std::optional<std::chrono::steady_clock::time_point> bm_stale_retry_at_{};
    unsigned bm_stale_retries_{};
    bool bm_stale_retry_pending_{};
    engine::BmLink last_bm_link_{engine::BmLink::disabled};
    bool last_bm_requested_{};
    // Windows 端点音量
    VolumeTarget playback_volume_{};
    VolumeTarget transmit_volume_{};
    // CAT 门控草稿
    std::optional<services::CatSettings> cat_deferred_{};
    std::string cat_deferred_text_{};
    bool cat_deferred_retried_{};
    bool cat_retry_now_{};
    struct HriPowerRequest {
        std::uint32_t watts{};
        std::uint64_t revision{};
        bool hri{};
        bool waiting_for_engine{};
        bool cat_submitted{};
        bool confirmation_requested{};
        std::optional<std::chrono::steady_clock::time_point> confirm_after{};
    };
    std::optional<HriPowerRequest> hri_power_request_{};
    std::optional<services::CatSettings> cat_mode_after_power_{};
    std::array<std::uint64_t, 3> cat_mode_after_power_revisions_{};
    std::optional<ChannelKey> quick_call_pending_{};
    StartupGroupActivation startup_group_activation_{};
    std::optional<ChannelKey> startup_group_activation_last_target_{};
    std::string startup_group_activation_status_{};
    StaticGroupsView static_{};
    bool static_import_pending_{};        // 当前设备/Key 的首次成功读取要把静态组补进收听频道
    bool startup_static_resolved_{};      // 启动组呼在首次静态组读取结束（或超时）后才激活
    std::optional<std::chrono::steady_clock::time_point> startup_static_wait_since_{};
    bool rx_policy_dirty_{};              // 频道已变但收听策略尚未下发（引擎未运行或策略命令在途）
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
    // R130 FM 中继
    bool squelch_polling_{};               // 最近一次下发给 CatService 的轮询开关
    bool squelch_open_{};                  // 最近一次静噪事件为 opened
    std::optional<unsigned> last_squelch_peak_{};
    std::optional<std::chrono::steady_clock::time_point> last_squelch_close_{};
    std::optional<CallRecord> relay_awaiting_peak_{}; // 超时等先于关门结束的段：等关门事件补 S 峰值后再写日志

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
