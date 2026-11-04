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
    std::future<CommandResult> disconnect_radio() override { return engine_.disconnect_radio(); }
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
                vm.snapshot().bm_link == wirex::engine::BmLink::failed;
        }), "empty BM identity/password leaves BM failed and disconnected while radio starts");
        check(!vm.snapshot().bm_requested_enabled && vm.snapshot().bm_error == "password_required",
              "empty saved password reports a concrete BM error without claiming a connection");
        const auto revision = vm.snapshot().bm_connection_revision;
        std::this_thread::sleep_for(1300ms);
        (void)vm.pump();
        check(vm.snapshot().bm_connection_revision == revision &&
              vm.snapshot().bm_link == wirex::engine::BmLink::failed,
              "a failed BM profile does not trigger an automatic retry loop");
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

} // namespace

int main()
{
    test_production_mode_autostarts_independent_services_and_radio_stop_keeps_bm();
    test_empty_bm_profile_does_not_block_radio_and_startup_stop_cancels_only_radio();
    std::cout << "PASS: " << assertions << " VM radio/BM lifecycle assertions\n";
    return EXIT_SUCCESS;
}
