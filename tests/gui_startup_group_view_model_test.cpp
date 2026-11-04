#include "../src/gui/view_model.hpp"

#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace {

using namespace wirex;
using gui::EngineApi;
using gui::services::ChannelEntry;
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
        initial->phase = engine::Phase::stopped;
        initial->bm_link = engine::BmLink::disabled;
        published = std::move(initial);
    }

    std::future<engine::CommandResult> start(engine::StartConfig) override { return ready(); }
    std::future<engine::CommandResult> stop() override { return ready(); }
    std::future<engine::CommandResult> set_bm_connection(bool, std::uint64_t) override { return ready(); }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget) override { return ready(); }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig) override { return ready(); }
    std::future<engine::CommandResult> disconnect_radio() override { return ready(); }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t, talkgroup_routing::RxPolicy) override {
        return ready();
    }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t, talkgroup_routing::TxTarget, bool) override {
        return ready();
    }
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute route) override
    {
        routes.push_back(route);
        auto promise = std::make_shared<std::promise<engine::CommandResult>>();
        auto future = promise->get_future();
        completions.push_back(std::move(promise));
        return future;
    }
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t, std::uint32_t) override { return ready(); }
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints) override { return ready(); }
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t, std::uint64_t,
                                                              std::optional<std::string>) override {
        return ready();
    }

    std::shared_ptr<const engine::Snapshot> snapshot() const override { return published; }
    std::vector<engine::Event> drain_events(std::size_t) override { return {}; }
    void set_wakeup(std::function<void()>) override {}

    void publish_bm(engine::BmLink link, engine::Phase phase = engine::Phase::starting)
    {
        auto next = std::make_shared<engine::Snapshot>(*published);
        ++next->seq;
        next->phase = phase;
        next->bm_link = link;
        next->bm_requested_enabled = link != engine::BmLink::disabled;
        published = std::move(next);
    }

    void complete(std::size_t index, engine::CommandStatus status, std::string detail = {})
    {
        engine::CommandResult result;
        result.status = status;
        result.detail = std::move(detail);
        completions.at(index)->set_value(std::move(result));
    }

    std::shared_ptr<const engine::Snapshot> published{};
    std::vector<talkgroup_routing::GroupRoute> routes{};
    std::vector<std::shared_ptr<std::promise<engine::CommandResult>>> completions{};
};

Services services_for(std::vector<ChannelEntry> channels)
{
    Services services;
    services.config.load = [channels = std::move(channels)](std::string&) mutable -> std::optional<GuiConfig> {
        GuiConfig config;
        config.channels = channels;
        return config;
    };
    // BM static-group API is intentionally absent: auto activation must not depend on it.
    return services;
}

void test_bm_ready_starts_one_frozen_queue_without_hri_or_static_api()
{
    using dmr_call::CallKind;
    using dmr_call::Slot;
    TestEngine engine;
    auto services = services_for({
        {91U, CallKind::group, Slot::ts2, ""},
        {460997U, CallKind::private_call, Slot::ts2, "private"},
        {4000U, CallKind::group, Slot::ts1, "disconnect control"},
        {91U, CallKind::group, Slot::ts2, "duplicate"},
        {46001U, CallKind::group, Slot::ts1, ""},
    });
    gui::ViewModel vm(engine, std::move(services), true);

    vm.pump();
    check(engine.routes.empty(), "saved channels wait without sending before BM is connected");
    engine.publish_bm(engine::BmLink::connected, engine::Phase::starting);
    vm.pump();
    check(engine.routes.size() == 1U && engine.routes[0].destination_id == 91U &&
          engine.routes[0].slot == Slot::ts2,
          "first BM ready dispatches the first saved group even while radio phase is not ready");
    vm.pump();
    check(engine.routes.size() == 1U,
          "another UI pump cannot dispatch a second route while the first future is pending");

    engine.complete(0U, engine::CommandStatus::accepted);
    vm.pump();
    check(engine.routes.size() == 2U && engine.routes[1].destination_id == 46001U &&
          engine.routes[1].slot == Slot::ts1,
          "accepted local send advances in saved order and removes duplicate TG/slot");

    vm.quick_call({46001U, CallKind::group, Slot::ts1});
    check(engine.routes.size() == 2U,
          "manual Quick Call cannot interleave with the startup sequence");

    engine.publish_bm(engine::BmLink::backoff);
    vm.pump();
    engine.complete(1U, engine::CommandStatus::not_ready, "quick_call_not_ready");
    vm.pump();
    check(engine.routes.size() == 2U,
          "BM disconnect pauses the current unsent target");

    engine.publish_bm(engine::BmLink::connected, engine::Phase::starting);
    vm.pump();
    check(engine.routes.size() == 3U && engine.routes[2].destination_id == 46001U,
          "reconnect resumes the same pending target without restarting the queue");
    engine.complete(2U, engine::CommandStatus::accepted);
    vm.pump();
    check(engine.routes.size() == 3U && vm.startup_group_activation_status().find("2/2") != std::string::npos,
          "final status reports two local sends and does not repeat after completion");
    engine.publish_bm(engine::BmLink::backoff);
    vm.pump();
    engine.publish_bm(engine::BmLink::connected, engine::Phase::starting);
    vm.pump();
    check(engine.routes.size() == 3U,
          "a later BM reconnect cannot reactivate the completed startup sequence");
}

void test_partial_send_is_reported_with_target_and_failure_detail()
{
    using dmr_call::CallKind;
    using dmr_call::Slot;
    TestEngine engine;
    gui::ViewModel vm(engine, services_for({{91U, CallKind::group, Slot::ts2, ""}}), true);

    engine.publish_bm(engine::BmLink::connected, engine::Phase::starting);
    vm.pump();
    check(engine.routes.size() == 1U, "BM ready dispatches the saved group for failure reporting");

    engine.complete(0U, engine::CommandStatus::failed, "quick_call_partial_send");
    vm.pump();
    check(vm.transient_visible() && vm.transient_failed(),
          "partial Quick Call failure is retained as a visible failed transient");
    check(vm.transient_text().find("TG 91") != std::string::npos &&
          vm.transient_text().find("TS2") != std::string::npos &&
          vm.transient_text().find("quick_call_partial_send") != std::string::npos,
          "failure text keeps the target route and engine partial-send detail for the UI log");
    check(vm.startup_group_activation_status().find("失败 1 个") != std::string::npos,
          "persistent startup summary records the failed local attempt");
}

} // namespace

int main()
{
    test_bm_ready_starts_one_frozen_queue_without_hri_or_static_api();
    test_partial_send_is_reported_with_target_and_failure_detail();
    std::cout << "PASS: " << assertions << " startup group ViewModel assertions\n";
    return EXIT_SUCCESS;
}
