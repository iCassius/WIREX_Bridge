#include "../src/gui/view_model.hpp"

#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace wirex;
using gui::EngineApi;
using gui::services::GuiConfig;
using gui::services::Services;

int assertions = 0;

void check(bool condition, const char* message)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::future<engine::CommandResult> ready(engine::CommandResult result = {})
{
    std::promise<engine::CommandResult> promise;
    promise.set_value(std::move(result));
    return promise.get_future();
}

class TestEngine final : public EngineApi {
public:
    TestEngine()
    {
        auto initial = std::make_shared<engine::Snapshot>();
        initial->seq = 1U;
        initial->phase = engine::Phase::running;
        initial->bm_link = engine::BmLink::disabled;
        initial->bm_connection_revision = 0U;
        initial->bm_requested_enabled = false;
        published = std::move(initial);
    }

    std::future<engine::CommandResult> start(engine::StartConfig) override { return ready(); }
    std::future<engine::CommandResult> stop() override { return ready(); }
    std::future<engine::CommandResult> set_bm_connection(bool enabled, std::uint64_t revision) override
    {
        connection_requests.push_back({enabled, revision});
        return queue_future(connection_completions);
    }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget config) override
    {
        configured_targets.push_back(std::move(config));
        return queue_future(configure_completions);
    }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig) override { return ready(); }
    std::future<engine::CommandResult> disconnect_radio() override { return ready(); }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t, talkgroup_routing::RxPolicy) override {
        return ready();
    }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t, talkgroup_routing::TxTarget, bool) override {
        return ready();
    }
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute) override { return ready(); }
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t, std::uint32_t) override { return ready(); }
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints) override { return ready(); }
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t, std::uint64_t,
                                                              std::optional<std::string>) override {
        return ready();
    }

    std::shared_ptr<const engine::Snapshot> snapshot() const override { return published; }
    std::vector<engine::Event> drain_events(std::size_t) override { return {}; }
    void set_wakeup(std::function<void()>) override {}

    void complete_configure(std::size_t index, engine::CommandStatus status, std::uint64_t revision = 0U)
    {
        configure_completions.at(index)->set_value({status, revision, {}});
    }

    void complete_connection(std::size_t index, engine::CommandStatus status)
    {
        connection_completions.at(index)->set_value(
            {status, connection_requests.at(index).revision, {}});
    }

    void publish_connection(bool enabled, engine::BmLink link, std::uint64_t revision)
    {
        auto next = std::make_shared<engine::Snapshot>(*published);
        ++next->seq;
        next->bm_requested_enabled = enabled;
        next->bm_link = link;
        next->bm_connection_revision = revision;
        published = std::move(next);
    }

    struct ConnectionRequest {
        bool enabled{};
        std::uint64_t revision{};
    };

    std::shared_ptr<const engine::Snapshot> published{};
    std::vector<engine::BmTarget> configured_targets{};
    std::vector<ConnectionRequest> connection_requests{};
    std::vector<std::shared_ptr<std::promise<engine::CommandResult>>> configure_completions{};
    std::vector<std::shared_ptr<std::promise<engine::CommandResult>>> connection_completions{};

private:
    static std::future<engine::CommandResult> queue_future(
        std::vector<std::shared_ptr<std::promise<engine::CommandResult>>>& completions)
    {
        auto promise = std::make_shared<std::promise<engine::CommandResult>>();
        auto future = promise->get_future();
        completions.push_back(std::move(promise));
        return future;
    }
};

GuiConfig initial_config()
{
    GuiConfig config;
    config.callsign = "N0CALL";
    config.dmr_id = 4609100U;
    config.gateway_id = 460910001U;
    config.master_host = "old-master.invalid";
    config.bm_password = "offline-old-profile";
    return config;
}

Services services_for(GuiConfig initial, std::size_t& saves)
{
    Services services;
    services.config.load = [initial = std::move(initial)](std::string&) mutable -> std::optional<GuiConfig> {
        return initial;
    };
    services.config.save = [&saves](const GuiConfig&, std::string&) {
        ++saves;
        return true;
    };
    services.config.make_runtime_config = [](const GuiConfig& config, std::string&) {
        engine::StartConfig runtime;
        runtime.bm.master_host = config.master_host;
        runtime.bm.profile.callsign = config.callsign;
        runtime.bm.profile.gateway_id = gui::services::effective_gateway_id(config);
        runtime.bm.profile.password = config.bm_password;
        runtime.local_source_id = config.dmr_id;
        return std::optional<engine::StartConfig>(std::move(runtime));
    };
    return services;
}

void test_new_profile_invalidates_an_in_flight_configure_before_enable()
{
    TestEngine engine;
    std::size_t saves = 0U;
    gui::ViewModel vm(engine, services_for(initial_config(), saves), true);

    vm.toggle_bm();
    check(engine.configured_targets.size() == 1U &&
          engine.configured_targets.front().profile.password == "offline-old-profile",
          "first enable attempt configures the saved old profile");

    auto updated = vm.config();
    updated.callsign = "K1NEW";
    updated.dmr_id = 4609101U;
    updated.device_number = "02";
    updated.master_host = "new-master.invalid";
    updated.bm_password = "offline-new-profile";
    std::string error;
    check(vm.save_config(updated, error), "a newer profile can be saved while configure_bm is pending");
    check(saves == 1U && vm.config().bm_password == "offline-new-profile",
          "successful save publishes the new profile to the ViewModel");

    engine.complete_configure(0U, engine::CommandStatus::accepted, 0U);
    vm.pump();
    check(engine.connection_requests.empty(),
          "completion of an old configure_bm never starts a BM connection after a newer profile was saved");

    vm.toggle_bm();
    check(engine.configured_targets.size() == 2U &&
          engine.configured_targets.back().profile.password == "offline-new-profile" &&
          engine.configured_targets.back().master_host == "new-master.invalid" &&
          engine.configured_targets.back().profile.callsign == "K1NEW" &&
          engine.configured_targets.back().profile.gateway_id == 460910102U &&
          engine.configured_targets.back().local_source_id == 4609101U,
          "the next explicit attempt configures the saved identity, device, credentials, and master");
    engine.complete_configure(1U, engine::CommandStatus::accepted, 0U);
    vm.pump();
    check(engine.connection_requests.size() == 1U && engine.connection_requests.front().enabled &&
          engine.connection_requests.front().revision == 1U,
          "a current profile proceeds to a single enable request at the next BM revision");
}

void test_profile_save_is_rejected_while_enable_or_live_link_uses_old_config()
{
    TestEngine engine;
    std::size_t saves = 0U;
    gui::ViewModel vm(engine, services_for(initial_config(), saves), true);
    vm.toggle_bm();
    engine.complete_configure(0U, engine::CommandStatus::accepted, 0U);
    vm.pump();
    check(engine.connection_requests.size() == 1U,
          "accepted configuration queues the BM enable request");

    auto updated = vm.config();
    updated.bm_password = "offline-new-profile";
    std::string error;
    check(!vm.save_config(updated, error) && !error.empty() && saves == 0U &&
          vm.config().bm_password == "offline-old-profile",
          "profile save is rejected while the enable command is pending");

    engine.complete_connection(0U, engine::CommandStatus::accepted);
    engine.publish_connection(true, engine::BmLink::connecting, 1U);
    vm.pump();
    error.clear();
    check(!vm.save_config(updated, error) && !error.empty() && saves == 0U,
          "profile save remains blocked while the old-profile BM connection is active");

    vm.toggle_bm();
    check(engine.connection_requests.size() == 2U && !engine.connection_requests.back().enabled &&
          engine.connection_requests.back().revision == 2U,
          "disconnect uses the next revision before profile replacement");
    engine.complete_connection(1U, engine::CommandStatus::accepted);
    engine.publish_connection(false, engine::BmLink::disabled, 2U);
    vm.pump();
    error.clear();
    check(vm.save_config(updated, error) && saves == 1U &&
          vm.config().bm_password == "offline-new-profile",
          "profile can be saved after the BM link is disabled");
}

void test_immediate_reconnect_waits_for_configure_before_enable()
{
    TestEngine engine;
    engine.publish_connection(true, engine::BmLink::connected, 1U);
    std::size_t saves = 0U;
    gui::ViewModel vm(engine, services_for(initial_config(), saves), true);

    vm.toggle_bm();
    check(engine.connection_requests.size() == 1U && !engine.connection_requests[0].enabled &&
          engine.connection_requests[0].revision == 2U,
          "first click requests BM disconnect at the next revision");
    engine.complete_connection(0U, engine::CommandStatus::accepted);
    // The request was accepted, but transport cleanup is still pending in backoff.
    engine.publish_connection(false, engine::BmLink::backoff, 2U);
    vm.pump();

    vm.toggle_bm();
    check(engine.configured_targets.size() == 1U && engine.connection_requests.size() == 1U,
          "second click during disable cleanup queues configure but does not enable yet");
    engine.complete_configure(0U, engine::CommandStatus::accepted, 2U);
    vm.pump();
    check(engine.connection_requests.size() == 2U && engine.connection_requests[1].enabled &&
          engine.connection_requests[1].revision == 3U,
          "VM enables only after configure completes, preserving disable-configure-enable ordering");
}

void test_failed_configure_never_queues_bm_enable()
{
    TestEngine engine;
    std::size_t saves = 0U;
    gui::ViewModel vm(engine, services_for(initial_config(), saves), true);

    vm.toggle_bm();
    check(engine.configured_targets.size() == 1U,
          "BM enable begins by queuing profile configuration");
    engine.complete_configure(0U, engine::CommandStatus::failed);
    vm.pump();
    check(engine.connection_requests.empty(),
          "a failed configure_bm result never queues set_bm_connection(true)");
}

} // namespace

int main()
{
    test_new_profile_invalidates_an_in_flight_configure_before_enable();
    test_profile_save_is_rejected_while_enable_or_live_link_uses_old_config();
    test_immediate_reconnect_waits_for_configure_before_enable();
    test_failed_configure_never_queues_bm_enable();
    std::cout << "PASS: " << assertions << " BM profile ViewModel assertions\n";
    return EXIT_SUCCESS;
}
