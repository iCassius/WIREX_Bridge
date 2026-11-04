#include "../src/gui/fake_engine.hpp"
#include "../src/gui/view_model.hpp"

#include <cstdlib>
#include <future>
#include <iostream>
#include <string>
#include <utility>

namespace {

using wirex::engine::CommandResult;
using wirex::engine::CommandStatus;
using wirex::gui::EngineApi;
using wirex::gui::FakeEngine;

int assertions = 0;

void check(bool condition, const char* message) {
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

class ControlledEngine final : public EngineApi {
public:
    explicit ControlledEngine(FakeEngine& engine) : engine_(engine) {}

    std::future<CommandResult> start(wirex::engine::StartConfig config) override {
        return engine_.start(std::move(config));
    }
    std::future<CommandResult> stop() override { return engine_.stop(); }
    std::future<CommandResult> set_bm_connection(bool enabled, std::uint64_t revision) override {
        return engine_.set_bm_connection(enabled, revision);
    }
    std::future<CommandResult> configure_bm(wirex::engine::BmTarget config) override {
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
    std::future<CommandResult> quick_call_join(wirex::talkgroup_routing::GroupRoute) override {
        return quick_call_result_.get_future();
    }
    std::future<CommandResult> set_audio_gains(std::uint32_t, std::uint32_t) override {
        return audio_result_.get_future();
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

    void fail_both(const std::string& secret) {
        CommandResult quick;
        quick.status = CommandStatus::failed;
        quick.detail = "quick-call failure " + secret;
        quick_call_result_.set_value(std::move(quick));

        CommandResult audio;
        audio.status = CommandStatus::failed;
        audio.detail = "audio failure " + secret + " " + api_key_;
        audio_result_.set_value(std::move(audio));
    }

    void set_api_key(std::string api_key) { api_key_ = std::move(api_key); }

private:
    FakeEngine& engine_;
    std::promise<CommandResult> quick_call_result_;
    std::promise<CommandResult> audio_result_;
    std::string api_key_{};
};

void test_two_failures_in_one_pump_are_retained_and_redacted() {
    constexpr const char* password = "test-only-bm-password";
    constexpr const char* api_key = "test-only-bm-api-key";

    FakeEngine fake({true, 20261104U});
    ControlledEngine engine(fake);
    engine.set_api_key(api_key);
    auto services = wirex::gui::make_fake_services(fake);
    wirex::gui::services::GuiConfig config;
    config.dmr_id = 4609100U;
    config.gateway_id = 4609100U;
    config.bm_password = password;
    config.bm_api_key = api_key;
    services.config.load = [config](std::string&) -> std::optional<wirex::gui::services::GuiConfig> {
        return config;
    };
    services.config.save = [](const wirex::gui::services::GuiConfig&, std::string&) { return true; };

    wirex::gui::ViewModel vm(engine, std::move(services), true);
    check(vm.snapshot().phase == wirex::engine::Phase::running,
          "seeded fake engine supplies a running state for both operations");
    (void)vm.drain_operation_events(); // Exclude any constructor-time static-group status.

    vm.quick_call({46001U, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts1});
    vm.commit_gains();
    engine.fail_both(password);
    (void)vm.pump(); // Both futures are ready before the same pump begins.

    auto events = vm.drain_operation_events();
    if (events.size() != 2U) {
        std::cerr << "queued event count: " << events.size() << '\n';
        for (const auto& event : events) {
            std::cerr << "operation=" << static_cast<unsigned>(event.operation)
                      << " message=" << event.message << '\n';
        }
    }
    check(events.size() == 2U, "one pump retains both failed operation results");
    check(events[0].operation == wirex::gui::Str::op_quick_call &&
          events[1].operation == wirex::gui::Str::op_gains,
          "each retained result keeps its operation source and completion order");
    check(events[0].failed && events[1].failed, "both events are marked failed");
    for (const auto& event : events) {
        check(event.message.find(password) == std::string::npos,
              "BM password is removed from queued event text");
        check(event.message.find(api_key) == std::string::npos,
              "BM API key is removed from queued event text");
    }
    check(vm.drain_operation_events().empty(), "drain returns each queued event only once");
}

} // namespace

int main() {
    test_two_failures_in_one_pump_are_retained_and_redacted();
    std::cout << "PASS: " << assertions << " operation-event queue assertions\n";
    return EXIT_SUCCESS;
}
