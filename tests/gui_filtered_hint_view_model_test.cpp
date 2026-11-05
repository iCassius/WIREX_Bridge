// ViewModel::filtered_hint / listen_filtered：最近 30 秒内被收听策略过滤的 BM 流量提示，
// 以及“加入收听”把组呼 TG/时隙或私呼对端加入频道列表。
#include "../src/gui/fake_engine.hpp"
#include "../src/gui/view_model.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <utility>

namespace {

using wirex::dmr_call::CallKind;
using wirex::dmr_call::Slot;
using wirex::engine::CommandResult;
using wirex::engine::FilteredTraffic;
using wirex::engine::Snapshot;
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

std::uint64_t steady_ms() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                          std::chrono::steady_clock::now().time_since_epoch())
                                          .count());
}

// 委托给 FakeEngine，但 snapshot() 的 last_filtered 由测试控制（clock_origin_ms 设为非零，覆盖相对时间换算）。
class FilteredEngine final : public EngineApi {
public:
    explicit FilteredEngine(FakeEngine& engine) : engine_(engine) {}

    void set_filtered(std::optional<FilteredTraffic> traffic) {
        filtered_ = traffic;
        ++seq_bump_;
    }

    std::future<CommandResult> start(wirex::engine::StartConfig config) override { return engine_.start(std::move(config)); }
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
    std::future<CommandResult> replace_tx_policy(std::uint64_t revision, wirex::talkgroup_routing::TxTarget target,
                                                  bool enabled) override {
        return engine_.replace_tx_policy(revision, target, enabled);
    }
    std::future<CommandResult> quick_call_join(wirex::talkgroup_routing::GroupRoute route) override {
        return engine_.quick_call_join(route);
    }
    std::future<CommandResult> set_audio_gains(std::uint32_t a, std::uint32_t b) override {
        return engine_.set_audio_gains(a, b);
    }
    std::future<CommandResult> set_audio_endpoints(wirex::engine::AudioEndpoints audio) override {
        return engine_.set_audio_endpoints(std::move(audio));
    }
    std::future<CommandResult> upsert_radio_identity(std::uint32_t id, std::uint64_t revision,
                                                      std::optional<std::string> callsign) override {
        return engine_.upsert_radio_identity(id, revision, std::move(callsign));
    }
    std::shared_ptr<const Snapshot> snapshot() const override {
        auto copy = std::make_shared<Snapshot>(*engine_.snapshot());
        copy->clock_origin_ms = kOrigin;
        copy->last_filtered = filtered_;
        copy->seq += seq_bump_ * 1'000'000U;
        return copy;
    }
    std::vector<wirex::engine::Event> drain_events(std::size_t max) override { return engine_.drain_events(max); }
    void set_wakeup(std::function<void()> wakeup) override { engine_.set_wakeup(std::move(wakeup)); }

    static constexpr std::uint64_t kOrigin = 1'000U;

private:
    FakeEngine& engine_;
    std::optional<FilteredTraffic> filtered_{};
    std::uint64_t seq_bump_{};
};

FilteredTraffic traffic(CallKind kind, std::uint32_t src, std::uint32_t dst, std::uint64_t age_ms) {
    FilteredTraffic t;
    t.kind = kind;
    t.source_id = src;
    t.destination_id = dst;
    t.slot = Slot::ts2;
    t.last_ms = steady_ms() - FilteredEngine::kOrigin - age_ms;
    return t;
}

bool has_channel(const wirex::gui::ViewModel& vm, std::uint32_t id, CallKind kind) {
    const auto& chs = vm.config().channels;
    return std::any_of(chs.begin(), chs.end(),
                       [&](const auto& e) { return e.id == id && e.kind == kind && e.slot == Slot::ts2; });
}

void run() {
    FakeEngine fake({true, 20261106U});
    FilteredEngine engine(fake);
    auto services = wirex::gui::make_fake_services(fake);
    int saves = 0;
    services.config.save = [&saves](const wirex::gui::services::GuiConfig&, std::string&) {
        ++saves;
        return true;
    };
    wirex::gui::ViewModel vm(engine, std::move(services), true);
    check(vm.snapshot().bm_link == wirex::engine::BmLink::connected, "seeded fake engine is BM-connected");

    struct Case {
        const char* name;
        std::optional<FilteredTraffic> traffic;
        bool visible;
    };
    const Case cases[] = {
        {"no filtered traffic hides the hint", std::nullopt, false},
        {"recent group traffic shows the hint", traffic(CallKind::group, 2233333U, 3100U, 3'000U), true},
        {"traffic older than 30 s hides the hint", traffic(CallKind::group, 2233333U, 3100U, 31'000U), false},
        {"traffic on a listened TG hides the hint", traffic(CallKind::group, 2233333U, 46001U, 1'000U), false},
    };
    for (const auto& c : cases) {
        engine.set_filtered(c.traffic);
        (void)vm.pump();
        check(vm.filtered_hint().has_value() == c.visible, c.name);
    }

    // 年龄换算沿用 to_wall/clock_origin：3 秒前 → age_s 3（允许 1 秒抖动）。
    engine.set_filtered(traffic(CallKind::group, 2233333U, 3100U, 3'000U));
    (void)vm.pump();
    const auto hint = vm.filtered_hint();
    check(hint && hint->age_s >= 3U && hint->age_s <= 4U, "age is measured relative to clock_origin_ms");
    check(hint && hint->key.id == 3100U && hint->key.kind == CallKind::group, "group hint targets the TG");

    const int saves_before = saves;
    vm.listen_filtered();
    check(has_channel(vm, 3100U, CallKind::group), "listen adds the filtered TG/slot as a channel");
    check(saves == saves_before + 1, "listen persists the channel list");
    check(!vm.filtered_hint().has_value(), "hint disappears once the TG is listened to");

    // 收听策略下发期间频道不可修改（界面按钮同样禁用）；等 fake engine 完成后再继续。
    for (int i = 0; i < 100 && !vm.can_mutate_channels(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        (void)vm.pump();
    }
    check(vm.can_mutate_channels(), "rx policy update completes");

    // 私呼：频道 ID 为对端（来源）ID。
    engine.set_filtered(traffic(CallKind::private_call, 3109999U, 4609100U, 2'000U));
    (void)vm.pump();
    const auto priv = vm.filtered_hint();
    check(priv && priv->key.id == 3109999U && priv->key.kind == CallKind::private_call,
          "private hint targets the remote peer");
    vm.listen_filtered();
    check(has_channel(vm, 3109999U, CallKind::private_call), "listen adds the private peer as a private channel");
    check(!vm.filtered_hint().has_value(), "private hint disappears once the peer is listened to");
}

} // namespace

int main() {
    run();
    std::cout << "PASS: " << assertions << " filtered-traffic hint assertions\n";
    return EXIT_SUCCESS;
}
