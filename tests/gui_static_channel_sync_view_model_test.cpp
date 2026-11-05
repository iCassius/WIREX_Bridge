// ViewModel：BM 静态组与收听频道双向同步。
// - 启动读取静态组后，把不在收听表中的静态组补进频道（保存配置），已存在的不重复添加；
// - 启动组呼等首次静态组读取结束后才激活，并跳过静态组频道（无需 Quick Call）；
// - 卡片移除静态组频道：BM remove 成功才取消收听，失败保留频道；无 API Key 时只取消收听。
#include "../src/gui/fake_engine.hpp"
#include "../src/gui/view_model.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace wirex;
using dmr_call::CallKind;
using dmr_call::Slot;
using gui::EngineApi;
using gui::services::BmApiDone;
using gui::services::BmApiResult;
using gui::services::ChannelEntry;
using gui::services::GuiConfig;
using gui::services::Services;
using gui::services::StaticGroup;

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
    engine::CommandResult result;
    result.status = engine::CommandStatus::accepted;
    std::promise<engine::CommandResult> promise;
    promise.set_value(std::move(result));
    return promise.get_future();
}

// 记录 Quick Call 目标；其它命令立即 accepted。
class RecordingEngine final : public EngineApi {
public:
    RecordingEngine()
    {
        auto initial = std::make_shared<engine::Snapshot>();
        initial->seq = 1U;
        published = std::move(initial);
    }

    std::future<engine::CommandResult> start(engine::StartConfig) override { return ready(); }
    std::future<engine::CommandResult> stop() override { return ready(); }
    std::future<engine::CommandResult> set_bm_connection(bool, std::uint64_t) override { return ready(); }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget) override { return ready(); }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig) override { return ready(); }
    std::future<engine::CommandResult> disconnect_radio() override { return ready(); }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t, talkgroup_routing::RxPolicy policy) override
    {
        rx_policies.push_back(std::move(policy));
        return ready();
    }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t, talkgroup_routing::TxTarget, bool) override {
        return ready();
    }
    std::future<engine::CommandResult> quick_call_join(talkgroup_routing::GroupRoute route) override
    {
        routes.push_back(route);
        return ready();
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

    void publish(engine::Phase phase, engine::BmLink link)
    {
        auto next = std::make_shared<engine::Snapshot>(*published);
        ++next->seq;
        next->phase = phase;
        next->bm_link = link;
        next->bm_requested_enabled = link != engine::BmLink::disabled;
        published = std::move(next);
    }

    std::shared_ptr<const engine::Snapshot> published{};
    std::vector<talkgroup_routing::GroupRoute> routes{};
    std::vector<talkgroup_routing::RxPolicy> rx_policies{};
};

// 手动完成的 BM API：测试决定何时、以何种结果回调。
struct ManualBmApi {
    std::vector<StaticGroup> groups{};
    std::vector<BmApiDone> pending_list{};
    struct Write {
        bool add{};
        std::uint32_t tg{};
        int slot{};
        BmApiDone done{};
    };
    std::vector<Write> writes{};

    void finish_list()
    {
        auto pending = std::move(pending_list);
        pending_list.clear();
        for (auto& done : pending) {
            BmApiResult r;
            r.groups = groups;
            r.groups_valid = true;
            r.add_slot = 2;
            r.device_status = 0;
            r.message = "listed";
            done(std::move(r));
        }
    }

    void finish_write(std::size_t index, bool ok)
    {
        auto& w = writes.at(index);
        BmApiResult r;
        if (ok) {
            if (w.add) {
                groups.push_back({w.tg, w.slot});
            } else {
                groups.erase(std::remove_if(groups.begin(), groups.end(),
                                            [&](const auto& g) { return g.talkgroup == w.tg && g.slot == w.slot; }),
                             groups.end());
            }
            r.groups = groups;
            r.groups_valid = true;
            r.message = "BM 已接受静态组更改，读取列表已确认。";
        } else {
            r.failed = true;
            r.message = "BM API 操作超时；请刷新列表确认服务器状态。";
        }
        w.done(std::move(r));
    }
};

struct Harness {
    std::shared_ptr<ManualBmApi> api{std::make_shared<ManualBmApi>()};
    std::shared_ptr<int> saves{std::make_shared<int>(0)};
    std::shared_ptr<GuiConfig> saved{std::make_shared<GuiConfig>()};

    Services make(std::vector<ChannelEntry> channels, std::string api_key = "demo-api-key")
    {
        Services sv;
        GuiConfig config;
        config.dmr_id = 4609100U;
        config.device_number = "01";
        config.bm_api_key = std::move(api_key);
        config.channels = std::move(channels);
        sv.config.load = [config](std::string&) -> std::optional<GuiConfig> { return config; };
        sv.config.save = [saves = saves, saved = saved](const GuiConfig& c, std::string&) {
            ++*saves;
            *saved = c;
            return true;
        };
        sv.bm_api.list_static_groups = [api = api](std::uint32_t, std::string, BmApiDone done) {
            api->pending_list.push_back(std::move(done));
        };
        sv.bm_api.add_static_group = [api = api](std::uint32_t, std::string, std::uint32_t tg, int slot, BmApiDone done) {
            api->writes.push_back({true, tg, slot, std::move(done)});
        };
        sv.bm_api.remove_static_group = [api = api](std::uint32_t, std::string, std::uint32_t tg, int slot,
                                                    BmApiDone done) {
            api->writes.push_back({false, tg, slot, std::move(done)});
        };
        return sv;
    }
};

std::size_t count_channel(const gui::ViewModel& vm, std::uint32_t id, Slot slot)
{
    const auto& chs = vm.config().channels;
    return static_cast<std::size_t>(std::count_if(chs.begin(), chs.end(), [&](const auto& e) {
        return e.kind == CallKind::group && e.id == id && e.slot == slot;
    }));
}

bool channel_is_static(const gui::ViewModel& vm, std::uint32_t id)
{
    // channel_page() 只返回当前页；测试频道少于一页。
    for (const auto& ch : vm.channel_page()) {
        if (ch.key.id == id && ch.key.kind == CallKind::group) return ch.is_static;
    }
    return false;
}

void test_startup_imports_missing_static_groups_without_duplicates()
{
    RecordingEngine engine;
    Harness h;
    h.api->groups = {{46001U, 2}, {3100U, 1}, {91U, 0}};
    gui::ViewModel vm(engine, h.make({
        {46001U, CallKind::group, Slot::ts2, ""},
        {460997U, CallKind::private_call, Slot::ts2, ""},
    }), true);

    check(h.api->pending_list.size() == 1U, "startup reads BM static groups once");
    h.api->finish_list();
    (void)vm.pump();

    check(count_channel(vm, 46001U, Slot::ts2) == 1U, "an already listened static group is not added again");
    check(count_channel(vm, 3100U, Slot::ts1) == 1U, "API slot 1 maps to a TS1 listen channel");
    check(count_channel(vm, 91U, Slot::ts2) == 1U, "API slot 0 (single-slot hotspot) maps to a TS2 listen channel");
    check(vm.config().channels.size() == 4U, "only the two missing static groups were appended");
    check(*h.saves >= 1 && h.saved->channels.size() == 4U, "imported channels are persisted to config");
    check(channel_is_static(vm, 46001U) && channel_is_static(vm, 3100U) && channel_is_static(vm, 91U),
          "imported and existing static channels are marked as static groups");
    check(vm.transient_text().find("TG 3100, 91") != std::string::npos, "import is reported with the added TGs");

    // 再次刷新同一设备：不重复补加。
    vm.static_refresh();
    h.api->finish_list();
    (void)vm.pump();
    check(vm.config().channels.size() == 4U, "a later refresh never duplicates listen channels");
}

void test_static_groups_skip_startup_quick_call()
{
    RecordingEngine engine;
    Harness h;
    h.api->groups = {{91U, 2}, {46001U, 0}};
    gui::ViewModel vm(engine, h.make({
        {91U, CallKind::group, Slot::ts2, ""},
        {46001U, CallKind::group, Slot::ts2, ""},
        {46025U, CallKind::group, Slot::ts2, ""},
    }), true);

    engine.publish(engine::Phase::running, engine::BmLink::connected);
    (void)vm.pump();
    check(engine.routes.empty(), "startup Quick Call waits for the first static-group read");

    h.api->finish_list();
    for (int i = 0; i < 4; ++i) (void)vm.pump();
    check(engine.routes.size() == 1U && engine.routes[0].destination_id == 46025U,
          "only the non-static group is activated with Quick Call");
    check(vm.startup_group_activation_status().find("1/1") != std::string::npos &&
              vm.startup_group_activation_status().find("静态组无需激活 2") != std::string::npos,
          "startup summary counts the skipped static groups");
}

void test_card_remove_static_success_and_failure()
{
    RecordingEngine engine;
    Harness h;
    h.api->groups = {{46001U, 0}, {91U, 2}};
    gui::ViewModel vm(engine, h.make({
        {46001U, CallKind::group, Slot::ts2, ""},
        {91U, CallKind::group, Slot::ts2, ""},
    }), true);
    h.api->finish_list();
    (void)vm.pump();
    check(vm.config().channels.size() == 2U, "both channels are already static groups");

    // 失败：频道保留并提示。
    vm.remove_static_channel({91U, CallKind::group, Slot::ts2});
    check(h.api->writes.size() == 1U && !h.api->writes[0].add && h.api->writes[0].tg == 91U &&
              h.api->writes[0].slot == 2,
          "card remove calls BM remove for the static group");
    check(count_channel(vm, 91U, Slot::ts2) == 1U, "the channel stays until BM confirms the removal");
    h.api->finish_write(0U, false);
    (void)vm.pump();
    check(count_channel(vm, 91U, Slot::ts2) == 1U, "BM remove failure keeps the listen channel");
    check(vm.transient_failed() && vm.transient_text().find("TG 91") != std::string::npos &&
              vm.transient_text().find("频道已保留") != std::string::npos,
          "BM remove failure is reported as a failure naming the TG");

    // 成功：保留原 API slot 0，确认后取消收听。
    vm.remove_static_channel({46001U, CallKind::group, Slot::ts2});
    check(h.api->writes.size() == 2U && h.api->writes[1].tg == 46001U && h.api->writes[1].slot == 0,
          "BM remove keeps the original API slot (0) rather than the listen slot");
    h.api->finish_write(1U, true);
    (void)vm.pump();
    check(count_channel(vm, 46001U, Slot::ts2) == 0U, "BM remove success also stops listening");
    check(h.saved->channels.size() == 1U, "the removal is persisted");
    check(!vm.transient_failed() && vm.transient_text().find("TG 46001") != std::string::npos,
          "success is reported");
}

void test_card_remove_without_api_key_only_unlistens()
{
    RecordingEngine engine;
    Harness h;
    gui::ViewModel vm(engine, h.make({{46001U, CallKind::group, Slot::ts2, ""}}, ""), true);
    check(h.api->pending_list.empty(), "no API key: static groups are not read");

    vm.remove_static_channel({46001U, CallKind::group, Slot::ts2});
    check(h.api->writes.empty(), "no API key: BM is never called");
    check(vm.config().channels.empty(), "no API key: the channel is removed locally");
    check(vm.transient_text().find("未设置 API Key") != std::string::npos,
          "no API key: the user is told BM was not changed");
}

void test_panel_add_and_remove_follow_listen_channels()
{
    RecordingEngine engine;
    Harness h;
    h.api->groups = {};
    gui::ViewModel vm(engine, h.make({}), true);
    h.api->finish_list();
    (void)vm.pump();

    vm.static_form().tg_input = "46010";
    vm.static_add();
    check(h.api->writes.size() == 1U && h.api->writes[0].add && h.api->writes[0].slot == 2, "panel add calls BM add");
    h.api->finish_write(0U, true);
    (void)vm.pump();
    check(count_channel(vm, 46010U, Slot::ts2) == 1U, "panel add also adds the listen channel");

    vm.static_select(0U);
    vm.static_remove();
    h.api->finish_write(1U, true);
    (void)vm.pump();
    check(count_channel(vm, 46010U, Slot::ts2) == 0U, "panel remove also stops listening");
}

// 端到端：fake engine + fake services 的演示数据（46010 不在演示频道中）。
void test_fake_services_demo_import()
{
    gui::FakeEngine fake({true, 20261106U});
    gui::ViewModel vm(fake, gui::make_fake_services(fake), true);
    for (int i = 0; i < 100 && count_channel(vm, 46010U, Slot::ts2) == 0U; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        (void)vm.pump();
    }
    check(count_channel(vm, 46010U, Slot::ts2) == 1U, "fake services: missing static group 46010 is imported");
    check(count_channel(vm, 46001U, Slot::ts2) == 1U, "fake services: existing static group is not duplicated");
}

} // namespace

int main()
{
    test_startup_imports_missing_static_groups_without_duplicates();
    test_static_groups_skip_startup_quick_call();
    test_card_remove_static_success_and_failure();
    test_card_remove_without_api_key_only_unlistens();
    test_panel_add_and_remove_follow_listen_channels();
    test_fake_services_demo_import();
    std::cout << "PASS: " << assertions << " static channel sync ViewModel assertions\n";
    return EXIT_SUCCESS;
}
