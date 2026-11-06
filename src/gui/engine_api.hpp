#pragma once

// GUI 使用的引擎抽象。方法与 wirex::engine::Engine 一一对应（名字、参数、返回值相同），
// 因此 FakeEngine 与真实引擎可以互换：真实引擎接入时只需
//     wirex::engine::Engine engine;
//     wirex::gui::EngineAdapter<wirex::engine::Engine> api{engine};
// 适配器是模板，未实例化时不会引入对真实引擎实现的链接依赖。

#include "wirex/engine.hpp"

#include <cstddef>
#include <functional>
#include <future>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wirex::gui {

class EngineApi {
public:
    EngineApi() = default;
    EngineApi(const EngineApi&) = delete;
    EngineApi& operator=(const EngineApi&) = delete;
    virtual ~EngineApi() = default;

    virtual std::future<engine::CommandResult> start(engine::StartConfig config) = 0;
    virtual std::future<engine::CommandResult> stop() = 0;
    virtual std::future<engine::CommandResult> set_bm_connection(bool enabled, std::uint64_t requested_revision) = 0;
    virtual std::future<engine::CommandResult> configure_bm(engine::BmTarget config) = 0;
    virtual std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig config) = 0;
    virtual std::future<engine::CommandResult> disconnect_radio() = 0;
    virtual std::future<engine::CommandResult> replace_rx_policy(std::uint64_t expected_revision,
                                                                 talkgroup_routing::RxPolicy policy) = 0;
    virtual std::future<engine::CommandResult> replace_tx_policy(std::uint64_t expected_revision,
                                                                 talkgroup_routing::TxTarget target,
                                                                 bool transmit_enabled) = 0;
    virtual std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute route) = 0;
    virtual std::future<engine::CommandResult> set_audio_gains(std::uint32_t radio_playback_gain_milli,
                                                               std::uint32_t mic_transmit_gain_milli) = 0;
    virtual std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints audio) = 0;
    virtual std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t source_id, std::uint64_t revision,
                                                                     std::optional<std::string> callsign) = 0;

    // R130 FM 中继。默认实现返回 forbidden，测试中的旧桩无需改动。
    virtual std::future<engine::CommandResult> relay_fm_start() {
        return ready_result(engine::CommandStatus::forbidden, "relay_fm_unsupported");
    }
    virtual std::future<engine::CommandResult> relay_fm_stop() {
        return ready_result(engine::CommandStatus::idempotent, "relay_fm_unsupported");
    }
    // R131：静噪 hang 期间静音上行。默认实现 idempotent。
    virtual std::future<engine::CommandResult> relay_fm_mute(bool) {
        return ready_result(engine::CommandStatus::idempotent, "relay_fm_unsupported");
    }

    // R131 按组静音输出 / TG4000 断开动态组。默认实现返回 forbidden，测试中的旧桩无需改动。
    virtual std::future<engine::CommandResult> set_muted_groups(std::vector<talkgroup_routing::GroupRoute>) {
        return ready_result(engine::CommandStatus::forbidden, "muted_groups_unsupported");
    }
    virtual std::future<engine::CommandResult> disconnect_dynamic_groups(dmr_call::Slot) {
        return ready_result(engine::CommandStatus::forbidden, "disconnect_dynamic_groups_unsupported");
    }

    [[nodiscard]] virtual std::shared_ptr<const engine::Snapshot> snapshot() const = 0;
    [[nodiscard]] virtual std::vector<engine::Event> drain_events(std::size_t max) = 0;
    virtual void set_wakeup(std::function<void()> wakeup) = 0;

protected:
    [[nodiscard]] static std::future<engine::CommandResult> ready_result(engine::CommandStatus status,
                                                                         std::string detail) {
        std::promise<engine::CommandResult> promise;
        promise.set_value(engine::CommandResult{status, 0U, std::move(detail)});
        return promise.get_future();
    }
};

template <class E>
class EngineAdapter final : public EngineApi {
public:
    explicit EngineAdapter(E& engine) : engine_(engine) {}

    std::future<engine::CommandResult> start(engine::StartConfig config) override {
        return engine_.start(std::move(config));
    }
    std::future<engine::CommandResult> stop() override { return engine_.stop(); }
    std::future<engine::CommandResult> set_bm_connection(bool enabled, std::uint64_t requested_revision) override {
        return engine_.set_bm_connection(enabled, requested_revision);
    }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget config) override {
        return engine_.configure_bm(std::move(config));
    }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig config) override {
        return engine_.connect_radio(std::move(config));
    }
    std::future<engine::CommandResult> disconnect_radio() override {
        return engine_.disconnect_radio();
    }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t expected_revision,
                                                         talkgroup_routing::RxPolicy policy) override {
        return engine_.replace_rx_policy(expected_revision, std::move(policy));
    }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t expected_revision,
                                                         talkgroup_routing::TxTarget target,
                                                         bool transmit_enabled) override {
        return engine_.replace_tx_policy(expected_revision, target, transmit_enabled);
    }
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute route) override {
        return engine_.quick_call_join(route);
    }
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t radio_playback_gain_milli,
                                                       std::uint32_t mic_transmit_gain_milli) override {
        return engine_.set_audio_gains(radio_playback_gain_milli, mic_transmit_gain_milli);
    }
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints audio) override {
        return engine_.set_audio_endpoints(std::move(audio));
    }
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t source_id, std::uint64_t revision,
                                                             std::optional<std::string> callsign) override {
        return engine_.upsert_radio_identity(source_id, revision, std::move(callsign));
    }
    std::future<engine::CommandResult> relay_fm_start() override { return engine_.relay_fm_start(); }
    std::future<engine::CommandResult> relay_fm_stop() override { return engine_.relay_fm_stop(); }
    std::future<engine::CommandResult> set_muted_groups(std::vector<talkgroup_routing::GroupRoute> groups) override {
        return engine_.set_muted_groups(std::move(groups));
    }
    std::future<engine::CommandResult> disconnect_dynamic_groups(dmr_call::Slot slot) override {
        return engine_.disconnect_dynamic_groups(slot);
    }
    std::future<engine::CommandResult> relay_fm_mute(bool muted) override { return engine_.relay_fm_mute(muted); }
    [[nodiscard]] std::shared_ptr<const engine::Snapshot> snapshot() const override { return engine_.snapshot(); }
    [[nodiscard]] std::vector<engine::Event> drain_events(std::size_t max) override {
        return engine_.drain_events(max);
    }
    void set_wakeup(std::function<void()> wakeup) override { engine_.set_wakeup(std::move(wakeup)); }

private:
    E& engine_;
};

} // namespace wirex::gui
