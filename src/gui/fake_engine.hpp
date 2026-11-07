#pragma once

// 离线模拟引擎（--fake）。在单个后台线程上模拟：
// - 命令延迟后返回 CommandResult（start ≈ 0.6 s，BM 连接分解析/连接两步 ≈ 1.2 s，Quick Call ≈ 0.5 s）；
// - BM 连接后按随机间隔产生来话（rx_call_started/ended，通话期间 10 Hz 更新电平），偶尔模拟本机 PTT；
// - 每次状态变化发布新 Snapshot 并调用唤醒回调。
// 同时提供内存版 services（设备枚举、CAT、配置），供 GUI 在没有真实模块时完整运行。

#include "engine_api.hpp"
#include "services.hpp"

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>

namespace wirex::gui {

struct FakeEngineOptions {
    // true：以“已连接串口 + BM 已连接 + 正有来话 + 已有若干历史”的状态启动，用于截图验收。
    bool seed_demo{};
    // FM 中继单段上限（模拟引擎内同样按 180 s 自动结束）。
    std::uint64_t relay_fm_max_duration_ms{engine::relay_fm_max_duration_ms};
    // 随机来话的种子；固定值让截图可复现。
    std::uint32_t seed{20261103U};
};

class FakeEngine final : public EngineApi {
public:
    explicit FakeEngine(FakeEngineOptions options = {});
    ~FakeEngine() override;

    std::future<engine::CommandResult> start(engine::StartConfig config) override;
    std::future<engine::CommandResult> stop() override;
    std::future<engine::CommandResult> set_bm_connection(bool enabled, std::uint64_t requested_revision) override;
    std::future<engine::CommandResult> configure_bm(engine::BmTarget config) override;
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig config) override;
    std::future<engine::CommandResult> set_hri_tx_power(std::uint16_t deciwatts) override;
    std::future<engine::CommandResult> set_hri_channel(std::uint32_t hz, hri_y::LchMode mode) override;
    std::future<engine::CommandResult> disconnect_radio() override;
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t expected_revision,
                                                         talkgroup_routing::RxPolicy policy) override;
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t expected_revision,
                                                         talkgroup_routing::TxTarget target,
                                                         bool transmit_enabled) override;
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute route) override;
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t radio_playback_gain_milli,
                                                       std::uint32_t mic_transmit_gain_milli) override;
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints audio) override;
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t source_id, std::uint64_t revision,
                                                             std::optional<std::string> callsign) override;
    // R130 FM 中继（简化规则：需 running + BM connected + 允许发射 + 媒体空闲）。
    std::future<engine::CommandResult> relay_fm_start() override;
    std::future<engine::CommandResult> relay_fm_stop() override;
    // R131 按组静音（静音组的来话照常发布，rx_peak 记 0）/ TG4000 断开动态组。
    std::future<engine::CommandResult> set_muted_groups(std::vector<talkgroup_routing::GroupRoute> groups) override;
    std::future<engine::CommandResult> disconnect_dynamic_groups(dmr_call::Slot slot) override;
    // 仅截图验收：立即注入一段已结束的 FM 中继（relay_fm_started/ended 事件）。
    void seed_relay_fm_demo();
    // 仅截图验收（--screenshot-bm-cooldown）：模拟“刚断开 BM”（bm_link disabled），触发界面冷却倒计时。
    void seed_bm_disconnected_demo();
    std::future<engine::CommandResult> relay_fm_mute(bool muted) override;
    // R131 离线测试：模拟 HRI 掉线进入自动重连（hri_lost）与重连成功（hri_restored）。disconnect_radio 停止重连。
    void simulate_hri_lost(std::string reason);
    void simulate_hri_restored();
    // R131 离线测试：模拟引擎线程异常结束（phase=failed）。keep_stale_links=true 时保留串口/HRI/音频标志，
    // 复现旧版最后快照沿用运行状态的问题，用于验证界面不再显示“已连接”且“连接”能重新启动引擎。
    void simulate_runtime_failure(std::string reason, bool keep_stale_links);

    [[nodiscard]] std::shared_ptr<const engine::Snapshot> snapshot() const override;
    [[nodiscard]] std::vector<engine::Event> drain_events(std::size_t max) override;
    void set_wakeup(std::function<void()> wakeup) override;

    // 在模拟线程上延迟执行（供 fake services 模拟串口耗时）。
    void post_after(std::chrono::milliseconds delay, std::function<void()> action);

    struct Impl;

private:
    std::unique_ptr<Impl> impl_;
};

// 内存版 services。返回值持有对 engine 的引用，engine 必须比 services 活得久。
[[nodiscard]] services::Services make_fake_services(FakeEngine& engine);

} // namespace wirex::gui
