// ViewModel R131：频道“静音 / 停用 / 启用”状态机、BM 重连冷却、Windows 端点音量、CAT 门控草稿。
// - 静态组静音：不改 RX 策略，调用 set_muted_groups；来话照常显示；持久化 muted；
// - 动态组停用：移出 RX 策略并发送 TG4000（disconnect_dynamic_groups）；持久化 disabled；
// - 启用：加回 RX 策略后 Quick Call；
// - BM 断开后 5 s 冷却；断开后 master_rejected 视为“旧会话未释放”并自动重试；
// - 音量滑块读写所选端点；CAT 门控拒绝保留草稿并在门控解除后自动重试一次。
#include "../src/gui/view_model.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace wirex;
using namespace std::chrono_literals;
using dmr_call::CallKind;
using dmr_call::Slot;
using gui::ChannelKey;
using gui::ChannelState;
using gui::EngineApi;
using gui::services::BmApiDone;
using gui::services::BmApiResult;
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

std::future<engine::CommandResult> ready(engine::CommandStatus status = engine::CommandStatus::accepted,
                                         std::string detail = {})
{
    std::promise<engine::CommandResult> promise;
    promise.set_value(engine::CommandResult{status, 0U, std::move(detail)});
    return promise.get_future();
}

class RecordingEngine final : public EngineApi {
public:
    RecordingEngine()
    {
        auto initial = std::make_shared<engine::Snapshot>();
        initial->seq = 1U;
        initial->phase = engine::Phase::running;
        initial->bm_link = engine::BmLink::connected;
        initial->bm_requested_enabled = true;
        published = std::move(initial);
    }

    std::future<engine::CommandResult> start(engine::StartConfig) override { return ready(); }
    std::future<engine::CommandResult> stop() override { return ready(); }
    std::future<engine::CommandResult> set_bm_connection(bool enabled, std::uint64_t) override
    {
        bm_requests.push_back(enabled);
        return ready();
    }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget) override
    {
        ++configures;
        return ready();
    }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig) override { return ready(); }
    std::future<engine::CommandResult> disconnect_radio() override { return ready(); }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t, talkgroup_routing::RxPolicy policy) override
    {
        rx_policies.push_back(std::move(policy));
        return ready();
    }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t, talkgroup_routing::TxTarget, bool) override
    {
        return ready();
    }
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute route) override
    {
        quick_calls.push_back(route);
        return ready(quick_status, quick_detail);
    }
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t, std::uint32_t) override { return ready(); }
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints) override { return ready(); }
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t, std::uint64_t,
                                                              std::optional<std::string>) override
    {
        return ready();
    }
    std::future<engine::CommandResult> set_muted_groups(std::vector<talkgroup_routing::GroupRoute> groups) override
    {
        muted_sets.push_back(std::move(groups));
        return ready();
    }
    std::future<engine::CommandResult> disconnect_dynamic_groups(Slot slot) override
    {
        disconnects.push_back(slot);
        return ready(disconnect_status, disconnect_detail);
    }

    std::shared_ptr<const engine::Snapshot> snapshot() const override { return published; }
    std::vector<engine::Event> drain_events(std::size_t) override { return {}; }
    void set_wakeup(std::function<void()>) override {}

    template <class F>
    void publish(F&& edit)
    {
        auto next = std::make_shared<engine::Snapshot>(*published);
        ++next->seq;
        edit(*next);
        published = std::move(next);
    }

    std::shared_ptr<const engine::Snapshot> published{};
    std::vector<talkgroup_routing::GroupRoute> quick_calls{};
    std::vector<talkgroup_routing::RxPolicy> rx_policies{};
    std::vector<std::vector<talkgroup_routing::GroupRoute>> muted_sets{};
    std::vector<Slot> disconnects{};
    std::vector<bool> bm_requests{};
    engine::CommandStatus quick_status{engine::CommandStatus::accepted};
    std::string quick_detail{};
    engine::CommandStatus disconnect_status{engine::CommandStatus::accepted};
    std::string disconnect_detail{};
    int configures{};
};

bool allows(const talkgroup_routing::RxPolicy& p, std::uint32_t tg)
{
    return std::any_of(p.allowed_groups.begin(), p.allowed_groups.end(),
                       [&](const auto& g) { return g.destination_id == tg; });
}

struct Harness {
    std::shared_ptr<GuiConfig> saved{std::make_shared<GuiConfig>()};
    std::shared_ptr<int> saves{std::make_shared<int>(0)};
    std::vector<gui::services::StaticGroup> static_groups{{46001U, 2}};
    std::shared_ptr<std::vector<BmApiDone>> pending_list{std::make_shared<std::vector<BmApiDone>>()};

    Services make(std::vector<ChannelEntry> channels)
    {
        Services sv;
        GuiConfig config;
        config.dmr_id = 4609100U;
        config.device_number = "01";
        config.callsign = "N0CALL";
        config.bm_password = "offline";
        config.bm_api_key = "demo-api-key";
        config.channels = std::move(channels);
        sv.config.load = [config](std::string&) -> std::optional<GuiConfig> { return config; };
        sv.config.save = [saves = saves, saved = saved](const GuiConfig& c, std::string&) {
            ++*saves;
            *saved = c;
            return true;
        };
        sv.config.make_runtime_config = [](const GuiConfig& c, std::string&) -> std::optional<engine::StartConfig> {
            engine::StartConfig runtime;
            runtime.bm.profile.password = c.bm_password;
            runtime.local_source_id = c.dmr_id;
            return runtime;
        };
        sv.bm_api.list_static_groups = [list = pending_list](std::uint32_t, std::string, BmApiDone done) {
            list->push_back(std::move(done));
        };
        return sv;
    }

    void finish_list()
    {
        auto pending = std::move(*pending_list);
        pending_list->clear();
        for (auto& done : pending) {
            BmApiResult r;
            r.groups = static_groups;
            r.groups_valid = true;
            r.add_slot = 2;
            r.device_status = 0;
            done(std::move(r));
        }
    }
};

std::vector<ChannelEntry> demo_channels()
{
    return {
        {46001U, CallKind::group, Slot::ts2, "", false, false},   // 静态组
        {3100U, CallKind::group, Slot::ts2, "", false, false},    // 动态组
        {460997U, CallKind::private_call, Slot::ts2, "", false, false},
    };
}

std::optional<gui::ChannelView> view_of(const gui::ViewModel& vm, std::uint32_t id)
{
    for (const auto& ch : vm.channel_page()) {
        if (ch.key.id == id) return ch;
    }
    return std::nullopt;
}

const ChannelEntry* saved_entry(const GuiConfig& c, std::uint32_t id)
{
    for (const auto& e : c.channels) {
        if (e.id == id) return &e;
    }
    return nullptr;
}

constexpr ChannelKey kStatic{46001U, CallKind::group, Slot::ts2};
constexpr ChannelKey kDynamic{3100U, CallKind::group, Slot::ts2};

void test_static_mute_keeps_policy_and_call_visible()
{
    RecordingEngine engine;
    Harness h;
    gui::ViewModel vm(engine, h.make(demo_channels()), true);
    h.finish_list();
    (void)vm.pump();
    check(view_of(vm, 46001U)->state == ChannelState::static_live, "static group starts live");

    const auto policies_before = engine.rx_policies.size();
    vm.channel_primary_action(kStatic);
    (void)vm.pump();
    check(engine.rx_policies.size() == policies_before, "muting a static group does not touch the RX policy");
    check(!engine.muted_sets.empty() && engine.muted_sets.back().size() == 1U &&
              engine.muted_sets.back()[0].destination_id == 46001U && engine.muted_sets.back()[0].slot == Slot::ts2,
          "muting calls set_muted_groups with the static TG/slot");
    check(view_of(vm, 46001U)->state == ChannelState::static_muted && view_of(vm, 46001U)->is_muted,
          "the card shows the muted state");
    check(saved_entry(*h.saved, 46001U) && saved_entry(*h.saved, 46001U)->muted, "muted flag is persisted");

    // 来话照常显示在静音卡片上。
    engine.publish([](engine::Snapshot& s) {
        engine::CallInfo call;
        call.source_id = 4609005U;
        call.destination_id = 46001U;
        call.slot = Slot::ts2;
        s.active_rx_call = call;
    });
    (void)vm.pump();
    check(view_of(vm, 46001U)->current_call.has_value(), "a muted static group still shows the incoming call");

    vm.channel_primary_action(kStatic);
    (void)vm.pump();
    check(engine.muted_sets.back().empty(), "unmute clears the muted set");
    check(view_of(vm, 46001U)->state == ChannelState::static_live && !saved_entry(*h.saved, 46001U)->muted,
          "unmute returns to static_live and persists muted=false");
}

void test_dynamic_disable_and_enable()
{
    RecordingEngine engine;
    Harness h;
    auto channels = demo_channels();
    channels.push_back({3200U, CallKind::group, Slot::ts2, "", false, false});
    gui::ViewModel vm(engine, h.make(channels), true);
    check(view_of(vm, 3100U)->state == ChannelState::dynamic_inactive, "dynamic group starts inactive");
    h.finish_list();
    for (int i = 0; i < 6; ++i) (void)vm.pump();
    // 启动组呼（跳过静态组 46001 与私呼）把两个动态组激活。
    check(engine.quick_calls.size() == 2U && view_of(vm, 3100U)->state == ChannelState::dynamic_active &&
              view_of(vm, 3200U)->state == ChannelState::dynamic_active,
          "startup Quick Calls mark the dynamic groups active");

    // 停用：RX 策略移除 + TG4000；同时隙另一个动态组回到“未激活”。
    vm.channel_primary_action(kDynamic);
    (void)vm.pump();
    check(!engine.rx_policies.empty() && !allows(engine.rx_policies.back(), 3100U) &&
              allows(engine.rx_policies.back(), 46001U) && allows(engine.rx_policies.back(), 3200U),
          "disable removes only the dynamic group from the RX policy");
    check(engine.disconnects.size() == 1U && engine.disconnects[0] == Slot::ts2,
          "disable sends TG4000 on the group slot");
    check(view_of(vm, 3100U)->state == ChannelState::disabled && view_of(vm, 3100U)->is_disabled,
          "the card shows the disabled state");
    check(view_of(vm, 3200U)->state == ChannelState::dynamic_inactive,
          "TG4000 drops the other dynamic group on the same slot to inactive");
    check(saved_entry(*h.saved, 3100U) && saved_entry(*h.saved, 3100U)->disabled, "disabled flag is persisted");

    // 未激活（未停用）的动态组：“启用”就是 Quick Call 激活。
    vm.channel_primary_action(ChannelKey{3200U, CallKind::group, Slot::ts2});
    (void)vm.pump();
    check(engine.quick_calls.size() == 3U && engine.quick_calls.back().destination_id == 3200U &&
              view_of(vm, 3200U)->state == ChannelState::dynamic_active,
          "enable on an inactive dynamic group sends a Quick Call and marks it active");

    // 启用已停用的组：加回策略后 Quick Call。
    vm.channel_primary_action(kDynamic);
    (void)vm.pump();
    (void)vm.pump();
    check(allows(engine.rx_policies.back(), 3100U), "enable puts the group back into the RX policy");
    check(engine.quick_calls.size() == 4U && engine.quick_calls.back().destination_id == 3100U,
          "enable re-activates the disabled dynamic group with a Quick Call");
    check(view_of(vm, 3100U)->state == ChannelState::dynamic_active && !saved_entry(*h.saved, 3100U)->disabled,
          "enabled group is active again and persisted as enabled");
}

void test_dynamic_disconnect_failure_and_deferred_feedback()
{
    for (const auto status : {engine::CommandStatus::busy, engine::CommandStatus::not_ready,
                              engine::CommandStatus::failed}) {
        RecordingEngine engine;
        Harness h;
        gui::ViewModel vm(engine, h.make(demo_channels()), true);
        h.finish_list();
        for (int i = 0; i < 6; ++i) (void)vm.pump();
        engine.disconnect_status = status;
        engine.disconnect_detail = "test_disconnect_error";
        const auto policies_before = engine.rx_policies.size();
        vm.disable_channel(kDynamic);
        check(!view_of(vm, 3100U)->is_disabled && engine.rx_policies.size() == policies_before,
              "disconnect does not remove the group before the result");
        (void)vm.pump();
        check(!view_of(vm, 3100U)->is_disabled && engine.rx_policies.size() == policies_before &&
              view_of(vm, 3100U)->state == ChannelState::dynamic_active,
              "disconnect failure preserves listening and the active marker");
        check(vm.transient_failed() && vm.transient_text().find("test_disconnect_error") != std::string::npos,
              "disconnect failure is visible");
    }

    RecordingEngine engine;
    Harness h;
    gui::ViewModel vm(engine, h.make(demo_channels()), true);
    h.finish_list();
    for (int i = 0; i < 6; ++i) (void)vm.pump();
    engine.disconnect_detail = "deferred_media_busy";
    vm.disable_channel(kDynamic);
    (void)vm.pump();
    check(view_of(vm, 3100U)->is_disabled && !allows(engine.rx_policies.back(), 3100U),
          "deferred disconnect is accepted and removes the group from the local policy");
    check(!vm.transient_failed() && vm.transient_text() == gui::tr(gui::Str::quick_call_deferred),
          "deferred disconnect shows the localized waiting message instead of claiming it was sent");
    (void)vm.pump();
    engine.quick_detail = "deferred_media_busy";
    vm.enable_channel(kDynamic);
    (void)vm.pump();
    (void)vm.pump();
    check(view_of(vm, 3100U)->state == ChannelState::dynamic_active &&
          !vm.transient_failed() && vm.transient_text() == gui::tr(gui::Str::quick_call_deferred),
          "deferred activation is accepted and shows the localized waiting message");
}

void test_disabled_flags_restore_from_config()
{
    RecordingEngine engine;
    Harness h;
    auto channels = demo_channels();
    channels[0].muted = true;
    channels[1].disabled = true;
    gui::ViewModel vm(engine, h.make(channels), true);
    h.finish_list();
    (void)vm.pump();
    check(view_of(vm, 46001U)->state == ChannelState::static_muted, "persisted muted flag restores the static state");
    check(view_of(vm, 3100U)->state == ChannelState::disabled, "persisted disabled flag restores the disabled state");
    check(!engine.muted_sets.empty() && engine.muted_sets.front().size() == 1U &&
              engine.muted_sets.front()[0].destination_id == 46001U,
          "the persisted muted set is pushed to a running engine at startup");
    // 停用频道：私呼“停用”只改策略，不发 TG4000。
    vm.channel_primary_action(ChannelKey{460997U, CallKind::private_call, Slot::ts2});
    (void)vm.pump();
    check(engine.disconnects.empty() && engine.rx_policies.back().private_peers.empty(),
          "disabling a private channel only changes the RX policy");
}

void test_bm_cooldown_and_stale_session_retry()
{
    RecordingEngine engine;
    Harness h;
    gui::ViewModel vm(engine, h.make(demo_channels()), true);
    check(vm.bm_cooldown_remaining_s() == 0U, "no cooldown before any disconnect");

    engine.publish([](engine::Snapshot& s) {
        s.bm_link = engine::BmLink::disabled;
        s.bm_requested_enabled = false;
    });
    (void)vm.pump();
    const auto left = vm.bm_cooldown_remaining_s();
    check(left >= 4U && left <= 5U, "disconnecting starts a 5 s reconnect cooldown");
    check(!vm.bm_stale_session_retry_s().has_value(), "a clean disconnect is not a stale-session retry");

    // 用户（冷却后）重连，Master 返回 master_rejected → 自动重试而不是失败。
    engine.publish([](engine::Snapshot& s) {
        s.bm_link = engine::BmLink::connecting;
        s.bm_requested_enabled = true;
    });
    (void)vm.pump();
    engine.publish([](engine::Snapshot& s) {
        s.bm_link = engine::BmLink::failed;
        s.bm_requested_enabled = false;
        s.bm_error = "master_rejected";
    });
    (void)vm.pump();
    const auto retry = vm.bm_stale_session_retry_s();
    check(retry.has_value() && *retry >= 4U && *retry <= 5U,
          "master_rejected right after a session ends schedules an automatic retry");
}

void test_endpoint_volume_slider()
{
    RecordingEngine engine;
    engine.publish([](engine::Snapshot& s) {
        s.wave_out_open = true;
        s.wave_out_endpoint_id = L"{out}";
        s.wave_in_open = true;
        s.wave_in_endpoint_id = L"{in}";
    });
    Harness h;
    auto sv = h.make(demo_channels());
    auto volumes = std::make_shared<std::map<std::wstring, float>>(std::map<std::wstring, float>{{L"{out}", 0.40F}, {L"{in}", 0.70F}});
    auto callbacks = std::make_shared<std::map<std::wstring, std::function<void(float)>>>();
    sv.audio_volume.get = [volumes](const std::wstring& id, std::string& error) -> std::optional<float> {
        auto it = volumes->find(id);
        if (it == volumes->end()) {
            error = "missing";
            return std::nullopt;
        }
        return it->second;
    };
    sv.audio_volume.set = [volumes](const std::wstring& id, float v, std::string&) {
        (*volumes)[id] = v;
        return true;
    };
    sv.audio_volume.watch = [callbacks](const std::wstring& id, std::function<void(float)> cb, std::string&) {
        (*callbacks)[id] = std::move(cb);
        return std::make_shared<int>(0);
    };
    gui::ViewModel vm(engine, std::move(sv), true);
    (void)vm.pump();
    check(vm.playback_volume() == 40 && vm.transmit_volume() == 70, "sliders start at the endpoint volumes");
    vm.commit_volume(false, 55);
    check(std::abs((*volumes)[L"{in}"] - 0.55F) < 0.001F && vm.transmit_volume() == 55,
          "transmit slider writes the WaveIn endpoint volume");
    (*callbacks)[L"{out}"](0.90F); // Windows 设置中被改动
    (void)vm.pump();
    check(vm.playback_volume() == 90, "external endpoint volume changes update the slider");

    // 引擎未运行时数字增益默认 1×（旧 config 的 transmit_gain_step=16 不再使用），且调节不写回 config。
    RecordingEngine stopped;
    stopped.publish([](engine::Snapshot& s) { s.phase = engine::Phase::stopped; });
    Harness h2;
    auto sv2 = h2.make(demo_channels());
    auto legacy = sv2.config.load;
    sv2.config.load = [legacy](std::string& e) -> std::optional<GuiConfig> {
        auto c = legacy(e);
        c->transmit_gain_step = 16U;
        c->playback_gain_step = 4U;
        return c;
    };
    gui::ViewModel vm2(stopped, std::move(sv2), true);
    check(vm2.playback_step == 1 && vm2.transmit_step == 1, "digital gain defaults to 1x, ignoring legacy steps");
    const int saves_before = *h2.saves;
    vm2.transmit_step = 3;
    vm2.commit_gains();
    check(*h2.saves == saves_before, "advanced digital gain is not written back to config");
}

void test_cat_gate_keeps_draft_and_retries_once()
{
    RecordingEngine engine;
    Harness h;
    auto sv = h.make(demo_channels());
    auto applies = std::make_shared<std::vector<gui::services::CatSettings>>();
    auto gate_open = std::make_shared<bool>(false);
    sv.cat.state = []() {
        gui::services::CatState s;
        s.connected = true;
        s.observed_power_w = 25U;
        s.observed_mode = gui::services::CatMode::fm;
        s.observed_revision = 1U;
        s.revision = 1U;
        return s;
    };
    sv.cat.apply = [applies, gate_open](gui::services::CatSettings s, gui::services::Done done) {
        applies->push_back(s);
        engine::CommandResult r;
        if (*gate_open) {
            r.status = engine::CommandStatus::accepted;
        } else {
            r.status = engine::CommandStatus::busy;
            r.detail = "cat_gate_transmitting";
        }
        done(r);
    };
    engine.publish([](engine::Snapshot& s) { s.tx_active = true; });
    gui::ViewModel vm(engine, std::move(sv), true);
    (void)vm.pump();
    check(vm.cat_form.power_index == 3, "form starts at the 25 W readback");
    vm.cat_form.power_index = 4; // 50 W 草稿
    vm.mark_cat_form_edited(gui::CatFormField::power);
    vm.cat_apply();
    (void)vm.pump();
    check(applies->size() == 1U && applies->back().power_w == 50U, "apply submits the drafted power");
    check(vm.cat_form.power_index == 4, "a gated rejection keeps the draft instead of reverting to 25 W");
    check(!vm.cat_deferred_text().empty(), "the gate reason and auto-apply hint are shown");
    (void)vm.pump();
    check(applies->size() == 1U, "no retry while still transmitting");

    *gate_open = true;
    engine.publish([](engine::Snapshot& s) { s.tx_active = false; });
    (void)vm.pump();
    (void)vm.pump();
    check(applies->size() == 2U && applies->back().power_w == 50U, "the draft is re-applied once after TX ends");
    check(vm.cat_deferred_text().empty(), "the deferred hint clears after the retry");
    (void)vm.pump();
    check(applies->size() == 2U, "only one automatic retry is made");
}

} // namespace

int main()
{
    test_static_mute_keeps_policy_and_call_visible();
    test_dynamic_disable_and_enable();
    test_dynamic_disconnect_failure_and_deferred_feedback();
    test_disabled_flags_restore_from_config();
    test_bm_cooldown_and_stale_session_retry();
    test_endpoint_volume_slider();
    test_cat_gate_keeps_draft_and_retries_once();
    std::cout << "PASS: " << assertions << " channel state ViewModel assertions\n";
    return EXIT_SUCCESS;
}
