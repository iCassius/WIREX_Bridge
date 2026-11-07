// R136：来话呼号后的国家/地区。
// - 身份查询结果（preload / lookup）中的 country/state 进入 ViewModel 缓存；
// - 频道卡片当前来话、当前来话面板与最近来话都拿到同一份显示文本；
// - 格式化规则：country + " " + state，state 为空或与 country 相同则省略；未知为空；
// - 长文本原样保留（截断只在绘制阶段处理）。
#include "../src/gui/view_model.hpp"

#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace wirex;
using namespace std::chrono_literals;
using dmr_call::CallKind;
using dmr_call::Slot;
using gui::EngineApi;
using gui::services::ChannelEntry;
using gui::services::GuiConfig;
using gui::services::IdentityDone;
using gui::services::IdentityResult;
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

std::future<engine::CommandResult> ready()
{
    std::promise<engine::CommandResult> promise;
    promise.set_value(engine::CommandResult{engine::CommandStatus::accepted, 0U, {}});
    return promise.get_future();
}

class RecordingEngine final : public EngineApi {
public:
    RecordingEngine()
    {
        auto initial = std::make_shared<engine::Snapshot>();
        initial->seq = 1U;
        initial->phase = engine::Phase::starting;
        published = std::move(initial);
    }

    std::future<engine::CommandResult> start(engine::StartConfig) override { return ready(); }
    std::future<engine::CommandResult> stop() override { return ready(); }
    std::future<engine::CommandResult> set_bm_connection(bool, std::uint64_t) override { return ready(); }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget) override { return ready(); }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig) override { return ready(); }
    std::future<engine::CommandResult> disconnect_radio() override { return ready(); }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t, talkgroup_routing::RxPolicy) override
    {
        return ready();
    }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t, talkgroup_routing::TxTarget, bool) override
    {
        return ready();
    }
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute) override { return ready(); }
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t, std::uint32_t) override { return ready(); }
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints) override { return ready(); }
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t, std::uint64_t,
                                                             std::optional<std::string>) override
    {
        return ready();
    }
    std::shared_ptr<const engine::Snapshot> snapshot() const override { return published; }
    std::vector<engine::Event> drain_events(std::size_t) override
    {
        auto out = std::move(events);
        events.clear();
        return out;
    }
    void set_wakeup(std::function<void()>) override {}

    template <class F>
    void publish(F&& edit)
    {
        auto next = std::make_shared<engine::Snapshot>(*published);
        ++next->seq;
        edit(*next);
        published = std::move(next);
    }

    void push_event(engine::Event event) { events.push_back(std::move(event)); }

    std::shared_ptr<const engine::Snapshot> published{};
    std::vector<engine::Event> events{};
};

Services base_services()
{
    Services sv;
    GuiConfig config;
    config.dmr_id = 4609100U;
    config.channels = {{46001U, CallKind::group, Slot::ts2, "", false, false}};
    sv.config.load = [config](std::string&) -> std::optional<GuiConfig> { return config; };
    return sv;
}

engine::Event started_event(std::uint32_t source_id, std::string callsign)
{
    engine::CallInfo call;
    call.source_id = source_id;
    call.destination_id = 46001U;
    call.slot = Slot::ts2;
    call.kind = CallKind::group;
    call.callsign = std::move(callsign);
    call.started_ms = 1000U;
    engine::Event event;
    event.kind = engine::EventKind::rx_call_started;
    event.at_ms = call.started_ms;
    event.call = std::move(call);
    return event;
}

engine::CallInfo active_call(std::uint32_t source_id, std::string callsign)
{
    engine::CallInfo call;
    call.source_id = source_id;
    call.destination_id = 46001U;
    call.slot = Slot::ts2;
    call.kind = CallKind::group;
    call.callsign = std::move(callsign);
    call.started_ms = 2000U;
    return call;
}

void test_formatting_rules()
{
    using gui::format_caller_region;
    check(format_caller_region("China", "Guangdong") == "China Guangdong", "country + state");
    check(format_caller_region("China", "") == "China", "empty state omitted");
    check(format_caller_region("China", "China") == "China", "duplicate state omitted");
    check(format_caller_region("", "Guangdong") == "Guangdong", "state alone is shown");
    check(format_caller_region("", "") == "", "unknown region is empty");

    // 长值不截断：截断只在绘制阶段发生。
    const std::string long_state(300U, 'x');
    check(format_caller_region("A", long_state) == "A " + long_state, "long values pass intact");
}

void test_preload_region_reaches_call_views()
{
    RecordingEngine engine;
    Services sv = base_services();
    sv.identity.preload = [] {
        return std::vector<IdentityResult>{
            {4609005U, true, std::string("BD0LAB"), std::string("China"), std::string("Guangdong")},
            {3109007U, true, std::string("N0CALL"), std::string("United States"), std::string("Colorado")},
        };
    };
    gui::ViewModel vm(engine, std::move(sv), true);
    engine.publish([](engine::Snapshot& s) { s.phase = engine::Phase::running; });
    (void)vm.pump();

    check(vm.caller_region(4609005U) == "China Guangdong", "preload country/state reaches the ViewModel cache");

    engine.publish([](engine::Snapshot& s) { s.active_rx_call = active_call(4609005U, "BD0LAB"); });
    (void)vm.pump();
    const auto channels = vm.channel_page();
    check(channels.size() == 1U && channels[0].current_call.has_value(), "active call is on the channel card");
    check(channels[0].current_call_region == "China Guangdong", "channel card current call carries the region");

    engine.push_event(started_event(3109007U, "N0CALL"));
    (void)vm.pump();
    const auto recent = vm.recent_callers(4U);
    check(recent.size() == 1U && recent[0].caller_region == "United States Colorado",
          "recent callers carry the region");

    check(vm.caller_region(999999U).empty(), "unknown identity shows nothing");
}

void test_lookup_region_reaches_call_views()
{
    RecordingEngine engine;
    Services sv = base_services();
    sv.identity.preload = [] { return std::vector<IdentityResult>{}; };
    sv.identity.lookup = [](std::uint32_t id, IdentityDone done) {
        done(IdentityResult{id, true, std::string("BY0QRY"), std::string("China"), std::string("Guangdong")});
    };
    gui::ViewModel vm(engine, std::move(sv), true);
    engine.publish([](engine::Snapshot& s) { s.phase = engine::Phase::running; });
    (void)vm.pump();

    // 呼号缺失的来话触发身份查询；结果在下一次 UI 回调中进入缓存。
    engine.push_event(started_event(4609004U, ""));
    (void)vm.pump();
    check(vm.caller_region(4609004U) == "China Guangdong", "lookup country/state reaches the ViewModel cache");
    const auto recent = vm.recent_callers(4U);
    check(recent.size() == 1U && recent[0].caller_region == "China Guangdong", "lookup region reaches recent callers");

    engine.publish([](engine::Snapshot& s) { s.active_rx_call = active_call(4609004U, ""); });
    (void)vm.pump();
    const auto channels = vm.channel_page();
    check(channels.size() == 1U && channels[0].current_call_region == "China Guangdong",
          "lookup region reaches the channel card");
}

} // namespace

int main()
{
    test_formatting_rules();
    test_preload_region_reaches_call_views();
    test_lookup_region_reaches_call_views();
    std::cout << "gui_caller_region_view_model_test: " << assertions << " assertions passed\n";
    return EXIT_SUCCESS;
}
