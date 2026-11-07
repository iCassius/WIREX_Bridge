#include "../src/gui/fake_engine.hpp"
#include "../src/gui/view_model.hpp"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <utility>

namespace {

using namespace std::chrono_literals;
using wirex::engine::CommandResult;
using wirex::engine::CommandStatus;

int assertions = 0;

void check(bool condition, const char* message)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

class RecordingEngine final : public wirex::gui::EngineApi {
public:
    explicit RecordingEngine(wirex::gui::FakeEngine& engine) : engine_(engine) {}

    std::future<CommandResult> start(wirex::engine::StartConfig config) override {
        started_local_source_id = config.local_source_id;
        started_rx_policy = config.rx_policy;
        started_tx_policy = config.tx_policy;
        return engine_.start(std::move(config));
    }
    std::future<CommandResult> stop() override { return engine_.stop(); }
    std::future<CommandResult> set_bm_connection(bool enabled, std::uint64_t revision) override {
        return engine_.set_bm_connection(enabled, revision);
    }
    std::future<CommandResult> configure_bm(wirex::engine::BmTarget config) override {
        configured_password = config.profile.password;
        return engine_.configure_bm(std::move(config));
    }
    std::future<CommandResult> connect_radio(wirex::engine::RadioStartConfig config) override {
        return engine_.connect_radio(std::move(config));
    }
    std::future<CommandResult> disconnect_radio() override {
        ++disconnect_calls;
        return engine_.disconnect_radio();
    }
    std::future<CommandResult> replace_rx_policy(std::uint64_t revision,
                                                  wirex::talkgroup_routing::RxPolicy policy) override {
        return engine_.replace_rx_policy(revision, std::move(policy));
    }
    std::future<CommandResult> replace_tx_policy(std::uint64_t revision,
                                                  wirex::talkgroup_routing::TxTarget target,
                                                  bool enabled) override {
        return engine_.replace_tx_policy(revision, target, enabled);
    }
    std::future<CommandResult> quick_call_join(wirex::talkgroup_routing::GroupRoute route) override {
        return engine_.quick_call_join(route);
    }
    std::future<CommandResult> set_audio_gains(std::uint32_t playback, std::uint32_t transmit) override {
        return engine_.set_audio_gains(playback, transmit);
    }
    std::future<CommandResult> set_audio_endpoints(wirex::engine::AudioEndpoints audio) override {
        return engine_.set_audio_endpoints(std::move(audio));
    }
    std::future<CommandResult> upsert_radio_identity(std::uint32_t id, std::uint64_t revision,
                                                      std::optional<std::string> callsign) override {
        return engine_.upsert_radio_identity(id, revision, std::move(callsign));
    }
    std::shared_ptr<const wirex::engine::Snapshot> snapshot() const override { return engine_.snapshot(); }
    std::vector<wirex::engine::Event> drain_events(std::size_t max) override {
        return engine_.drain_events(max);
    }
    void set_wakeup(std::function<void()> wakeup) override { engine_.set_wakeup(std::move(wakeup)); }

    std::string configured_password{}; // test-only observation; never printed
    int disconnect_calls{};
    std::uint32_t started_local_source_id{};
    wirex::talkgroup_routing::RxPolicy started_rx_policy{};
    wirex::talkgroup_routing::TxPolicy started_tx_policy{};

private:
    wirex::gui::FakeEngine& engine_;
};

wirex::gui::services::GuiConfig usable_config()
{
    wirex::gui::services::GuiConfig config;
    config.callsign = "N0CALL";
    config.dmr_id = 4609100U;
    config.gateway_id = 4609100U;
    config.master_host = "127.0.0.1";
    config.master_port = 62031U;
    config.bm_password = "offline-old-profile";
    config.hri_port = L"COM5";
    config.wave_in_endpoint_id = L"offline-wave-in";
    config.wave_out_endpoint_id = L"offline-wave-out";
    return config;
}

template <typename Predicate>
bool pump_until(wirex::gui::ViewModel& vm, Predicate predicate,
                std::chrono::milliseconds timeout = 5000ms)
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    do {
        (void)vm.pump();
        if (predicate()) return true;
        std::this_thread::sleep_for(10ms);
    } while (std::chrono::steady_clock::now() < deadline);
    (void)vm.pump();
    return predicate();
}

void install_config(wirex::gui::services::Services& services,
                    wirex::gui::services::GuiConfig config)
{
    services.config.load = [config](std::string&) -> std::optional<wirex::gui::services::GuiConfig> {
        return config;
    };
    services.config.save = [](const wirex::gui::services::GuiConfig&, std::string&) { return true; };
}

void test_production_mode_autostarts_independent_services_and_radio_stop_keeps_bm()
{
    wirex::gui::FakeEngine fake;
    RecordingEngine engine(fake);
    auto services = wirex::gui::make_fake_services(fake);
    install_config(services, usable_config());
    wirex::gui::ViewModel vm(engine, std::move(services), false); // false models a production launch

    check(pump_until(vm, [&]() {
        return vm.snapshot().phase == wirex::engine::Phase::running &&
            vm.snapshot().serial_open && vm.snapshot().bm_link == wirex::engine::BmLink::connected &&
            vm.cat().connected;
    }), "production-mode construction independently starts runtime, radio, BM, and CAT with fake services");
    const auto connected_revision = vm.snapshot().bm_connection_revision;
    check(connected_revision == 1U, "first automatic BM enable uses request revision 1 from initial revision 0");

    vm.stop();
    check(pump_until(vm, [&]() {
        return vm.snapshot().phase == wirex::engine::Phase::running && !vm.snapshot().serial_open &&
            vm.snapshot().bm_link == wirex::engine::BmLink::connected && !vm.cat().connected;
    }), "radio disconnect keeps the BM runtime and BM connection alive while CAT disconnects");

    vm.start();
    check(pump_until(vm, [&]() {
        return vm.snapshot().serial_open && vm.snapshot().bm_link == wirex::engine::BmLink::connected &&
            vm.cat().connected;
    }), "manual radio reconnect works without restarting or retrying the existing BM session");
    check(vm.snapshot().bm_connection_revision == connected_revision,
          "radio reconnect does not issue another BM connection request");

    vm.toggle_bm();
    check(pump_until(vm, [&]() {
        return !vm.snapshot().bm_requested_enabled && vm.snapshot().bm_link == wirex::engine::BmLink::disabled;
    }), "BM can be disconnected while radio remains attached");
    auto updated = vm.config();
    updated.bm_password = "offline-new-profile";
    std::string save_error;
    check(vm.save_config(updated, save_error), "updated BM profile saves through the existing config service");
    vm.toggle_bm();
    check(pump_until(vm, [&]() {
        return vm.snapshot().bm_link == wirex::engine::BmLink::connected;
    }), "BM reconnect after configuration update succeeds without restarting radio");
    check(engine.configured_password == "offline-new-profile",
          "BM reconnect submits the newly saved password instead of a stale startup copy");
    check(vm.snapshot().serial_open && vm.snapshot().phase == wirex::engine::Phase::running,
          "BM profile changes leave the existing radio runtime attached");
}

void test_empty_bm_profile_does_not_block_radio_and_startup_stop_cancels_only_radio()
{
    {
        wirex::gui::FakeEngine fake;
        RecordingEngine engine(fake);
        auto services = wirex::gui::make_fake_services(fake);
        auto config = usable_config();
        config.callsign.clear();
        config.dmr_id = 0U;
        config.gateway_id = 0U;
        config.bm_password.clear();
        install_config(services, std::move(config));
        wirex::gui::ViewModel vm(engine, std::move(services), false);

        check(pump_until(vm, [&]() {
            return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().serial_open &&
                vm.snapshot().bm_link == wirex::engine::BmLink::disabled;
        }), "empty BM identity/password leaves BM not configured while the radio starts");
        check(!vm.bm_profile_complete(), "empty BM profile is reported as incomplete");
        check(!vm.snapshot().bm_requested_enabled && !vm.snapshot().bm_transport_open,
              "incomplete BM profile never opens a BM transport");
        check(vm.snapshot().bm_connection_revision == 0U,
              "startup with an incomplete BM profile does not issue a BM connection request");
        const auto revision = vm.snapshot().bm_connection_revision;
        std::this_thread::sleep_for(1300ms);
        (void)vm.pump();
        check(vm.snapshot().bm_connection_revision == revision &&
              vm.snapshot().bm_link == wirex::engine::BmLink::disabled,
              "an incomplete BM profile does not trigger an automatic retry loop");
    }

    {
        wirex::gui::FakeEngine fake;
        RecordingEngine engine(fake);
        auto services = wirex::gui::make_fake_services(fake);
        install_config(services, usable_config());
        wirex::gui::ViewModel vm(engine, std::move(services), false);
        vm.stop(); // stop during the initial runtime transition cancels only the radio attach generation
        check(pump_until(vm, [&]() {
            return vm.snapshot().phase == wirex::engine::Phase::running && !vm.snapshot().serial_open &&
                vm.snapshot().bm_link == wirex::engine::BmLink::connected && !vm.cat().connected;
        }), "startup-time radio disconnect prevents late radio attach but still completes automatic BM startup");
        check(vm.snapshot().phase == wirex::engine::Phase::running,
              "startup-time radio disconnect never stops the BM runtime");
    }
}

// 回归：DMR ID 未配置（0）时，runtime 的 local_source_id 默认为 1，RX 策略里的私呼 peer 必须使用同一个
// local_destination_id；否则引擎 enable_routing 返回 routing_policy_invalid，启动即“核心已停止”，
// 界面提示点“连接电台”但每次重试都失败（v0.2.0 首启空 BM 配置的现场）。
void test_empty_bm_profile_rx_policy_matches_engine_local_source_id()
{
    wirex::gui::FakeEngine fake;
    RecordingEngine engine(fake);
    auto services = wirex::gui::make_fake_services(fake);
    auto config = usable_config();
    config.callsign.clear();
    config.dmr_id = 0U;
    config.gateway_id = 0U;
    config.bm_password.clear();
    // 与首次启动生成的默认配置一致：含鹦鹉私呼频道，才能覆盖私呼 peer 的本地源 ID。
    config.channels.push_back({460997U, wirex::dmr_call::CallKind::private_call, wirex::dmr_call::Slot::ts2});
    install_config(services, std::move(config));
    // 模拟真实 config_bridge::make_runtime_config：DMR ID 为 0 时使用本地源 ID 1。
    auto base_runtime = services.config.make_runtime_config;
    services.config.make_runtime_config = [base_runtime](const wirex::gui::services::GuiConfig& gui,
                                                          std::string& error) {
        auto sc = base_runtime(gui, error);
        if (sc) sc->local_source_id = wirex::gui::services::effective_source_id(gui);
        return sc;
    };
    wirex::gui::ViewModel vm(engine, std::move(services), false);
    check(pump_until(vm, [&]() {
        return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().serial_open;
    }), "empty BM profile still reaches a running engine with the radio attached");
    check(vm.engine_failure_banner().empty(), "empty BM profile does not produce a core error banner");
    check(engine.started_local_source_id == 1U, "runtime local source ID defaults to 1 without a DMR ID");

    wirex::talkgroup_routing::Router router(engine.started_local_source_id);
    check(static_cast<bool>(router.replace_rx_policy(1U, engine.started_rx_policy)),
          "RX policy built by the view model is valid for the runtime local source ID");
    check(static_cast<bool>(router.replace_tx_policy(1U, engine.started_tx_policy)),
          "TX policy built by the view model is valid for the runtime local source ID");
    check(!engine.started_rx_policy.private_peers.empty() &&
              engine.started_rx_policy.private_peers.front().local_destination_id ==
                  engine.started_local_source_id,
          "private peer routes use the same local source ID as StartConfig");
}

// 空 BM 配置 → 电台可用、BM 未配置；之后保存完整设置即可连接 BM，无需重启或断开电台。
void test_incomplete_bm_settings_can_be_completed_without_radio_restart()
{
    wirex::gui::FakeEngine fake;
    RecordingEngine engine(fake);
    auto services = wirex::gui::make_fake_services(fake);
    auto config = usable_config();
    config.callsign.clear();
    config.dmr_id = 0U;
    config.gateway_id = 0U;
    config.bm_password.clear();
    install_config(services, std::move(config));
    wirex::gui::ViewModel vm(engine, std::move(services), false);

    check(pump_until(vm, [&]() {
        return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().serial_open;
    }), "radio connects with an incomplete BM profile");
    check(!vm.bm_profile_complete(), "incomplete BM settings are detected");
    check(vm.snapshot().bm_link == wirex::engine::BmLink::disabled && !vm.snapshot().bm_requested_enabled,
          "BM stays disabled instead of failing at startup");

    vm.toggle_bm();
    check(pump_until(vm, [&]() { return !vm.pending(wirex::gui::Str::op_bm); }),
          "toggle_bm with an incomplete profile resolves without a BM command");
    check(engine.configured_password.empty() && !vm.snapshot().bm_requested_enabled &&
              vm.snapshot().bm_link == wirex::engine::BmLink::disabled,
          "BM connect is refused while the profile is incomplete");
    check(vm.snapshot().serial_open && vm.snapshot().phase == wirex::engine::Phase::running,
          "refusing BM does not disturb the connected radio");

    auto updated = vm.config();
    updated.callsign = "N0CALL";
    updated.dmr_id = 4609100U;
    updated.device_number = "01";
    updated.bm_password = "offline-completed-profile";
    std::string save_error;
    check(vm.save_config(updated, save_error), "completed BM settings save through the existing config service");
    check(vm.bm_profile_complete(), "saved BM settings are complete (API Key stays optional)");

    vm.toggle_bm();
    check(pump_until(vm, [&]() { return vm.snapshot().bm_link == wirex::engine::BmLink::connected; }),
          "BM connects after settings are completed");
    check(engine.configured_password == "offline-completed-profile",
          "BM uses the newly saved password");
    check(vm.snapshot().serial_open && vm.snapshot().phase == wirex::engine::Phase::running &&
              engine.disconnect_calls == 0,
          "BM connects without restarting the engine or disconnecting the radio");
}

} // namespace

// R131：HRI 掉线后引擎自动重连；界面提示 hri_lost/hri_restored，重连期间“断开”会发 disconnect_radio 停止重连。
void test_hri_auto_reconnect_wiring()
{
    wirex::gui::FakeEngine fake;
    RecordingEngine engine(fake);
    auto services = wirex::gui::make_fake_services(fake);
    install_config(services, usable_config());
    wirex::gui::ViewModel vm(engine, std::move(services), false);
    check(pump_until(vm, [&]() {
        return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().hri_ready &&
            vm.snapshot().bm_link == wirex::engine::BmLink::connected;
    }), "fake radio and BM connect before the HRI loss");

    fake.simulate_hri_lost("hri_y_ack_timeout");
    check(pump_until(vm, [&]() { return vm.snapshot().hri_reconnecting && !vm.snapshot().serial_open; }),
          "snapshot reports hri_reconnecting after hri_lost");
    check(!vm.transient_failed() && vm.transient_text().find("hri_y_ack_timeout") != std::string::npos,
          "hri_lost shows a non-error reconnect notice with the reason");
    fake.simulate_hri_restored();
    check(pump_until(vm, [&]() { return vm.snapshot().hri_ready && !vm.snapshot().hri_reconnecting; }),
          "hri_restored brings hri_ready back");
    check(vm.transient_text() == wirex::gui::tr(wirex::gui::Str::hri_restored), "hri_restored notice is shown");

    fake.simulate_hri_lost("serial_transport_error");
    check(pump_until(vm, [&]() { return vm.snapshot().hri_reconnecting; }), "second loss reconnects again");
    const int before = engine.disconnect_calls;
    vm.stop();
    check(engine.disconnect_calls == before + 1,
          "stop() during reconnect sends disconnect_radio even though serial_open is false");
    check(pump_until(vm, [&]() {
        return !vm.pending(wirex::gui::Str::op_stop) && !vm.snapshot().hri_reconnecting;
    }), "user disconnect ends the reconnect");
    check(vm.snapshot().bm_link == wirex::engine::BmLink::connected, "BM stays connected through the reconnect");
}

// R131 实机：引擎异常停止后界面仍显示 HRI 已连接，点“连接/断开”只发 stop()（idempotent）没有反应。
void test_engine_failure_display_and_reconnect_restarts_engine()
{
    for (const bool stale_links : {true, false}) {
        wirex::gui::FakeEngine fake;
        RecordingEngine engine(fake);
        auto services = wirex::gui::make_fake_services(fake);
        install_config(services, usable_config());
        wirex::gui::ViewModel vm(engine, std::move(services), false);
        check(pump_until(vm, [&]() {
            return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().hri_ready &&
                vm.snapshot().bm_link == wirex::engine::BmLink::connected && !vm.pending(wirex::gui::Str::op_start);
        }), "fake radio and BM connect before the engine failure");
        check(vm.radio_link_active() && !vm.engine_stopped() && vm.engine_failure_banner().empty(),
              "running engine reports an active radio link and no failure banner");

        fake.simulate_runtime_failure("radio_waveout_reopen_failed", stale_links);
        check(pump_until(vm, [&]() { return vm.snapshot().phase == wirex::engine::Phase::failed; }),
              "the view model observes the failed engine phase");
        check(vm.engine_stopped() && !vm.engine_running(), "failed phase counts as stopped");
        check(!vm.radio_link_active(),
              "a stopped engine never reports an active radio link, even with stale serial/HRI flags");
        const auto banner = vm.engine_failure_banner();
        check(banner.find("radio_waveout_reopen_failed") != std::string::npos &&
                  banner.find(wirex::gui::tr(wirex::gui::Str::err_core_waveout)) != std::string::npos,
              "the failure banner carries the friendly WaveOut text and the machine detail");

        const int disconnects_before = engine.disconnect_calls;
        vm.start(); // “连接电台”：引擎已停止时重新 start() 引擎再连接电台与 BM
        check(pump_until(vm, [&]() {
            return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().hri_ready &&
                vm.snapshot().serial_open && vm.snapshot().bm_link == wirex::engine::BmLink::connected;
        }), "connect after an engine failure restarts the engine, reattaches the radio and reconnects BM");
        check(engine.disconnect_calls == disconnects_before,
              "reconnecting a stopped engine does not send disconnect_radio");
        check(vm.engine_failure_banner().empty() && vm.radio_link_active(),
              "the failure banner clears once the restarted engine is running");
    }
}

int main()
{
    test_production_mode_autostarts_independent_services_and_radio_stop_keeps_bm();
    test_empty_bm_profile_does_not_block_radio_and_startup_stop_cancels_only_radio();
    test_empty_bm_profile_rx_policy_matches_engine_local_source_id();
    test_incomplete_bm_settings_can_be_completed_without_radio_restart();
    test_hri_auto_reconnect_wiring();
    test_engine_failure_display_and_reconnect_restarts_engine();
    std::cout << "PASS: " << assertions << " VM radio/BM lifecycle assertions\n";
    return EXIT_SUCCESS;
}
