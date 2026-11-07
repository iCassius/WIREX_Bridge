// R135 更新提示 ViewModel 测试：5 s 首次检查、available/up_to_date/failed、
// ui.update_check=false 与 fake 模式跳过、open_update_page 使用发布页 URL。全部离线。

#include "../src/gui/view_model.hpp"

#include "wirex/version.hpp"

#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using namespace wirex;
using gui::EngineApi;
using gui::services::GuiConfig;
using gui::services::Services;
using gui::UpdateStatus;

int assertions = 0;

void check(bool condition, const std::string& message) {
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::future<engine::CommandResult> ready(engine::CommandResult result = {}) {
    std::promise<engine::CommandResult> promise;
    promise.set_value(std::move(result));
    return promise.get_future();
}

class TestEngine final : public EngineApi {
public:
    TestEngine() {
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

    std::shared_ptr<const engine::Snapshot> published{};
};

struct UpdateProbe {
    int checks{};
    bool fail{};
    std::optional<app::update::LatestRelease> release{};
    std::vector<std::string> opened{};
};

app::update::LatestRelease make_release(std::string tag) {
    app::update::LatestRelease release;
    release.tag = std::move(tag);
    release.html_url = std::string(app::update::release_page_prefix) + "releases/tag/" + release.tag;
    return release;
}

Services make_services(UpdateProbe& probe, bool update_check) {
    Services services;
    services.config.load = [update_check](std::string&) -> std::optional<GuiConfig> {
        GuiConfig config;
        config.update_check = update_check;
        return config;
    };
    // 同步完成：回调仍在 pump 线程，经 ViewModel 信箱在下一轮 pump 生效。
    services.update.check_latest = [&probe](std::function<void(std::optional<app::update::LatestRelease>)> done) {
        ++probe.checks;
        if (probe.fail) {
            done(std::nullopt);
        } else {
            done(probe.release);
        }
    };
    services.update.open_url = [&probe](const std::string& url) { probe.opened.push_back(url); };
    return services;
}

struct Pending {
    gui::ViewModel* vm{};
    UpdateProbe* probe{};
};

bool pump_until_checked(const std::vector<Pending>& pending) {
    const auto deadline = std::chrono::steady_clock::now() + 8000ms;
    while (std::chrono::steady_clock::now() < deadline) {
        bool all_checked = true;
        for (const auto& item : pending) {
            (void)item.vm->pump();
            if (item.probe->checks == 0) all_checked = false;
        }
        if (all_checked) return true;
        std::this_thread::sleep_for(20ms);
    }
    return false;
}

void test_schedule_and_results() {
    UpdateProbe available_probe;
    available_probe.release = make_release("v0.2.3");
    TestEngine available_engine;
    gui::ViewModel available(available_engine, make_services(available_probe, true), false);

    UpdateProbe up_to_date_probe;
    up_to_date_probe.release = make_release("v0.2.2");
    TestEngine up_to_date_engine;
    gui::ViewModel up_to_date(up_to_date_engine, make_services(up_to_date_probe, true), false);

    UpdateProbe failed_probe;
    failed_probe.fail = true;
    TestEngine failed_engine;
    gui::ViewModel failed(failed_engine, make_services(failed_probe, true), false);

    UpdateProbe prerelease_probe;
    prerelease_probe.release = make_release("v0.3.0-rc.1");
    prerelease_probe.release->prerelease = true;
    TestEngine prerelease_engine;
    gui::ViewModel prerelease(prerelease_engine, make_services(prerelease_probe, true), false);

    UpdateProbe draft_probe;
    draft_probe.release = make_release("v0.4.0");
    draft_probe.release->draft = true;
    TestEngine draft_engine;
    gui::ViewModel draft(draft_engine, make_services(draft_probe, true), false);

    check(available.update_status().current == std::string("v") + app_version, "current is v + app_version");
    check(available.update_status().state == UpdateStatus::State::unknown, "state starts unknown");
    check(available.update_status().url == app_releases_url, "unknown state opens the releases page");
    check(available.idle_timeout_ms().has_value(), "a first check is scheduled");
    (void)available.pump();
    check(available_probe.checks == 0, "no check before 5 s");
    check(available.update_status().state == UpdateStatus::State::unknown, "state stays unknown before 5 s");

    const std::vector<Pending> pending{
        {&available, &available_probe},
        {&up_to_date, &up_to_date_probe},
        {&failed, &failed_probe},
        {&prerelease, &prerelease_probe},
        {&draft, &draft_probe},
    };
    check(pump_until_checked(pending), "first check runs after 5 s");
    // 服务的同步回调经信箱排队，下一轮 pump 应用结果。
    for (const auto& item : pending) (void)item.vm->pump();

    check(available.update_status().state == UpdateStatus::State::available, "newer tag becomes available");
    check(available.update_status().latest == "v0.2.3", "latest is normalized with a v prefix");
    check(available.update_status().url == available_probe.release->html_url,
          "available state opens the release page");
    available.open_update_page();
    check(available_probe.opened.size() == 1U && available_probe.opened.back() == available_probe.release->html_url,
          "open_update_page opens the release URL");

    check(up_to_date.update_status().state == UpdateStatus::State::up_to_date, "same version is up to date");
    check(up_to_date.update_status().latest.empty(), "up_to_date has no latest text");
    check(up_to_date.update_status().url == app_releases_url, "up_to_date opens the releases page");
    up_to_date.open_update_page();
    check(up_to_date_probe.opened.size() == 1U && up_to_date_probe.opened.back() == app_releases_url,
          "up_to_date click opens the releases URL");

    check(failed.update_status().state == UpdateStatus::State::failed, "failed check is reported silently");
    check(failed.update_status().url == app_releases_url, "failed state opens the releases page");

    check(prerelease.update_status().state == UpdateStatus::State::up_to_date,
          "prerelease release is not offered as an update");
    check(draft.update_status().state == UpdateStatus::State::up_to_date,
          "draft release is not offered as an update");
}

void test_disabled_and_fake_skip_checks() {
    {
        UpdateProbe probe;
        TestEngine engine;
        gui::ViewModel vm(engine, make_services(probe, false), false);
        (void)vm.pump();
        std::this_thread::sleep_for(100ms);
        (void)vm.pump();
        check(probe.checks == 0, "ui.update_check=false skips the check");
        check(vm.update_status().state == UpdateStatus::State::unknown, "disabled check stays unknown");
    }
    {
        UpdateProbe probe;
        TestEngine engine;
        gui::ViewModel vm(engine, make_services(probe, true), true);
        (void)vm.pump();
        std::this_thread::sleep_for(100ms);
        (void)vm.pump();
        check(probe.checks == 0, "fake mode skips the check");
        check(vm.update_status().state == UpdateStatus::State::unknown, "fake mode stays unknown");
    }
    {
        UpdateProbe probe;
        TestEngine engine;
        Services services;
        services.config.load = [](std::string&) -> std::optional<GuiConfig> {
            GuiConfig config;
            config.update_check = true;
            return config;
        };
        gui::ViewModel vm(engine, std::move(services), false);
        (void)vm.pump();
        std::this_thread::sleep_for(100ms);
        (void)vm.pump();
        check(vm.update_status().state == UpdateStatus::State::unknown, "missing update service stays unknown");
    }
}

} // namespace

int main() {
    test_schedule_and_results();
    test_disabled_and_fake_skip_checks();
    std::cout << "gui_update_view_model_test: " << assertions << " assertions passed\n";
    return EXIT_SUCCESS;
}
