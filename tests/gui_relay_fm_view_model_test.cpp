// R130 FM 中继：ViewModel 开关持久化、静噪轮询开关、静噪事件 → 引擎 relay_fm_start/stop、
// relay_fm_ended → 来话历史 FM 记录与 relay-log 行、ap_mode 透传。全部离线（FakeEngine + 内存 services）。

#include "../src/gui/fake_engine.hpp"
#include "../src/gui/view_model.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using wirex::engine::CommandResult;
using wirex::engine::CommandStatus;
namespace services = wirex::gui::services;

int assertions = 0;

void check(bool condition, const std::string& message)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

// FakeEngine 包装：记录 relay/connect_radio 调用。
class RecordingEngine final : public wirex::gui::EngineApi {
public:
    explicit RecordingEngine(wirex::gui::FakeEngine& engine) : engine_(engine) {}
    std::future<CommandResult> start(wirex::engine::StartConfig config) override { return engine_.start(std::move(config)); }
    std::future<CommandResult> stop() override { return engine_.stop(); }
    std::future<CommandResult> set_bm_connection(bool enabled, std::uint64_t revision) override {
        return engine_.set_bm_connection(enabled, revision);
    }
    std::future<CommandResult> configure_bm(wirex::engine::BmTarget config) override {
        return engine_.configure_bm(std::move(config));
    }
    std::future<CommandResult> connect_radio(wirex::engine::RadioStartConfig config) override {
        last_ap_mode = config.ap_mode;
        ++connect_calls;
        return engine_.connect_radio(std::move(config));
    }
    std::future<CommandResult> disconnect_radio() override { return engine_.disconnect_radio(); }
    std::future<CommandResult> replace_rx_policy(std::uint64_t revision, wirex::talkgroup_routing::RxPolicy policy) override {
        return engine_.replace_rx_policy(revision, std::move(policy));
    }
    std::future<CommandResult> replace_tx_policy(std::uint64_t revision, wirex::talkgroup_routing::TxTarget target,
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
    std::future<CommandResult> relay_fm_start() override {
        ++relay_starts;
        return engine_.relay_fm_start();
    }
    std::future<CommandResult> relay_fm_stop() override {
        ++relay_stops;
        return engine_.relay_fm_stop();
    }
    std::shared_ptr<const wirex::engine::Snapshot> snapshot() const override { return engine_.snapshot(); }
    std::vector<wirex::engine::Event> drain_events(std::size_t max) override { return engine_.drain_events(max); }
    void set_wakeup(std::function<void()> wakeup) override { engine_.set_wakeup(std::move(wakeup)); }

    std::atomic<int> relay_starts{0};
    std::atomic<int> relay_stops{0};
    std::atomic<int> connect_calls{0};
    std::atomic<bool> last_ap_mode{false};

private:
    wirex::gui::FakeEngine& engine_;
};

struct Probe {
    std::mutex mutex;
    std::vector<bool> polling_calls{};
    services::SquelchCallback callback{};
    std::vector<services::GuiConfig> saves{};
    std::vector<std::string> relay_lines{};
    bool fail_next_save{};
};

template <typename Predicate>
bool pump_until(wirex::gui::ViewModel& vm, Predicate predicate, std::chrono::milliseconds timeout = 5000ms)
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

services::Services probe_services(wirex::gui::FakeEngine& fake, const std::shared_ptr<Probe>& probe)
{
    auto sv = wirex::gui::make_fake_services(fake);
    services::GuiConfig config;
    std::string ignored;
    if (auto loaded = sv.config.load(ignored)) config = *loaded;
    sv.config.load = [config](std::string&) -> std::optional<services::GuiConfig> { return config; };
    sv.config.save = [probe](const services::GuiConfig& next, std::string& error) {
        std::lock_guard<std::mutex> lock(probe->mutex);
        if (probe->fail_next_save) {
            probe->fail_next_save = false;
            error = "disk full (test)";
            return false;
        }
        probe->saves.push_back(next);
        return true;
    };
    // 与真实 config_bridge 一致：runtime 携带 PTT 目标并允许发射（fake services 默认不带 TX 策略）。
    auto runtime = sv.config.make_runtime_config;
    sv.config.make_runtime_config = [runtime](const services::GuiConfig& gui, std::string& error)
        -> std::optional<wirex::engine::StartConfig> {
        auto sc = runtime(gui, error);
        if (sc && gui.tx_target) {
            sc->tx_policy.target = *gui.tx_target;
            sc->tx_policy.transmit_enabled = true;
        }
        return sc;
    };
    // 替换静噪接线：测试直接驱动回调，不使用 fake 的定时开门。
    sv.cat.set_squelch_polling = [probe](bool enabled) {
        std::lock_guard<std::mutex> lock(probe->mutex);
        probe->polling_calls.push_back(enabled);
    };
    sv.cat.set_squelch_callback = [probe](services::SquelchCallback callback) {
        std::lock_guard<std::mutex> lock(probe->mutex);
        probe->callback = std::move(callback);
    };
    sv.append_relay_log = [probe](const std::string& line) {
        std::lock_guard<std::mutex> lock(probe->mutex);
        probe->relay_lines.push_back(line);
        return true;
    };
    return sv;
}

void fire(const std::shared_ptr<Probe>& probe, services::SquelchEvent event)
{
    services::SquelchCallback callback;
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        callback = probe->callback;
    }
    check(static_cast<bool>(callback), "ViewModel registers a squelch callback");
    // 模拟 CAT 线程回调。
    std::thread([callback, event]() { callback(event); }).join();
}

bool last_polling(const std::shared_ptr<Probe>& probe, bool expected)
{
    std::lock_guard<std::mutex> lock(probe->mutex);
    return !probe->polling_calls.empty() && probe->polling_calls.back() == expected;
}

void test_relay_fm_flow()
{
    wirex::gui::FakeEngine fake;
    RecordingEngine engine(fake);
    auto probe = std::make_shared<Probe>();
    wirex::gui::ViewModel vm(engine, probe_services(fake, probe), true);

    check(!vm.relay_enabled() && !vm.relay_fm_enabled(), "relay toggles default off");
    check(vm.relay_status() == wirex::gui::RelayStatus::off, "relay status off by default");
    vm.toggle_relay_fm();
    check(!vm.relay_fm_enabled(), "FM toggle is ignored while relay is off");

    vm.toggle_relay();
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        check(probe->saves.size() == 1U && probe->saves.back().relay_enabled && !probe->saves.back().relay_fm_enabled,
              "toggle_relay persists relay.enabled");
    }
    check(vm.relay_status() == wirex::gui::RelayStatus::c4fm_only, "relay on + FM off shows the C4FM notice");

    // 保存失败时回滚。
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        probe->fail_next_save = true;
    }
    vm.toggle_relay_fm();
    check(!vm.relay_fm_enabled(), "failed save keeps the FM toggle unchanged");
    vm.toggle_relay_fm();
    check(vm.relay_fm_enabled(), "FM toggle persists once relay is on");
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        check(probe->saves.back().relay_fm_enabled, "toggle_relay_fm persists relay.fm_enabled");
        check(probe->polling_calls.empty(), "squelch polling stays off until CAT is connected");
    }
    check(vm.relay_status() == wirex::gui::RelayStatus::no_cat, "relay status reports CAT not connected");

    // 启动 runtime + 电台 + BM + CAT。
    vm.start();
    check(pump_until(vm, [&]() {
        return vm.snapshot().phase == wirex::engine::Phase::running && vm.snapshot().serial_open &&
            vm.snapshot().bm_link == wirex::engine::BmLink::connected && vm.cat().connected;
    }), "fake runtime, radio, BM and CAT connect");
    check(engine.connect_calls.load() >= 1 && engine.last_ap_mode.load(), "relay on passes ap_mode=true to connect_radio");
    check(pump_until(vm, [&]() { return last_polling(probe, true); }), "CAT connected + relay + FM enables squelch polling");

    // 等 fake 随机来话结束、媒体空闲后开门。
    check(pump_until(vm, [&]() {
        return vm.snapshot().media_owner == wirex::talkgroup_routing::MediaOwner::idle && !vm.snapshot().tx_active;
    }, 15000ms), "fake media becomes idle before opening squelch");

    services::SquelchEvent open;
    open.edge = services::SquelchEdge::opened;
    open.s_meter = 150U;
    fire(probe, open);
    check(pump_until(vm, [&]() { return engine.relay_starts.load() == 1 && vm.snapshot().relay_fm_active; }),
          "squelch opened → relay_fm_start and engine reports relay_fm_active");
    check(vm.relay_status() == wirex::gui::RelayStatus::active, "relay status reports FM relay active");

    services::SquelchEvent closed;
    closed.edge = services::SquelchEdge::closed;
    closed.s_meter_peak = 212U;
    closed.reason = "squelch";
    fire(probe, closed);
    check(pump_until(vm, [&]() { return !vm.snapshot().relay_fm_active && !vm.history().empty() &&
                                        vm.history().front().relay_fm; }),
          "squelch closed → relay_fm_stop and an FM relay history record");
    check(engine.relay_stops.load() >= 1, "relay_fm_stop was requested");
    const auto& rec = vm.history().front();
    check(rec.relay_s_peak == 212U && rec.call.source_id == 0U && rec.call.destination_id != 0U &&
              rec.relay_end_reason == "squelch_closed",
          "FM record carries the S peak, target and end reason without a source ID");
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        check(probe->relay_lines.size() == 1U, "one relay-log line per segment");
        const auto& line = probe->relay_lines.front();
        check(line.find("\"s_meter_peak\":212") != std::string::npos && line.find("\"target_kind\":\"group\"") != std::string::npos &&
                  line.find("\"end_reason\":\"squelch_closed\"") != std::string::npos &&
                  line.find("\"started_utc\":\"") != std::string::npos && line.find("password") == std::string::npos,
              "relay-log line has the documented fields and no credentials");
    }
    check(vm.recent_callers(8U).end() == std::find_if(vm.recent_callers(8U).begin(), vm.recent_callers(8U).end(),
                                                       [](const wirex::gui::CallRecord& r) { return r.relay_fm; }),
          "FM records are excluded from recent callers");

    // 再开一次门，然后断开 CAT：服务发 closed(cat_disconnected) → stop。
    check(pump_until(vm, [&]() {
        return vm.snapshot().media_owner == wirex::talkgroup_routing::MediaOwner::idle && !vm.snapshot().tx_active;
    }, 15000ms), "media idle before second segment");
    fire(probe, open);
    check(pump_until(vm, [&]() { return vm.snapshot().relay_fm_active; }), "second segment starts");
    services::SquelchEvent lost;
    lost.edge = services::SquelchEdge::closed;
    lost.reason = "cat_disconnected";
    fire(probe, lost);
    check(pump_until(vm, [&]() { return !vm.snapshot().relay_fm_active; }), "CAT loss closes the gate and stops the relay");
    check(!vm.history().front().relay_s_peak, "segment without an S peak keeps it empty");

    // 关闭 FM：轮询关闭。
    vm.toggle_relay_fm();
    check(last_polling(probe, false), "turning FM off disables squelch polling");
    vm.toggle_relay_fm();
    check(last_polling(probe, true), "turning FM back on re-enables squelch polling");
    vm.toggle_relay();
    check(last_polling(probe, false) && vm.relay_fm_enabled(),
          "turning relay off disables polling while keeping the stored FM choice");
}

void test_opened_while_busy_does_not_flash_failure()
{
    wirex::gui::FakeEngine fake;
    RecordingEngine engine(fake);
    auto probe = std::make_shared<Probe>();
    wirex::gui::ViewModel vm(engine, probe_services(fake, probe), true);
    vm.toggle_relay();
    vm.toggle_relay_fm();
    services::SquelchEvent open;
    open.edge = services::SquelchEdge::opened;
    fire(probe, open);
    check(pump_until(vm, [&]() { return engine.relay_starts.load() == 1 && !vm.pending(wirex::gui::Str::op_relay_fm); }),
          "relay_fm_start is attempted even when the engine is not running");
    check(!vm.snapshot().relay_fm_active, "engine not running rejects the FM relay");
    check(vm.transient_failed(), "not_ready (BM not connected) is reported to the operator");
}

} // namespace

int main()
{
    test_relay_fm_flow();
    test_opened_while_busy_does_not_flash_failure();
    std::cout << "PASS: " << assertions << " relay FM ViewModel assertions\n";
    return EXIT_SUCCESS;
}
