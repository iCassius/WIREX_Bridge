#include "../src/gui/view_model.hpp"

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
namespace gui = wirex::gui;
namespace engine = wirex::engine;
using namespace std::chrono_literals;

int assertions = 0;
void check(bool condition, const char* message)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::future<engine::CommandResult> ready(engine::CommandStatus status = engine::CommandStatus::accepted)
{
    std::promise<engine::CommandResult> promise;
    promise.set_value({status, 0U, {}});
    return promise.get_future();
}

class RecordingEngine final : public gui::EngineApi {
public:
    explicit RecordingEngine(bool hri) {
        state = std::make_shared<engine::Snapshot>();
        state->seq = 1U;
        state->phase = engine::Phase::running;
        state->hri_ready = hri;
        state->serial_open = hri;
    }
    std::future<engine::CommandResult> start(engine::StartConfig) override { return ready(); }
    std::future<engine::CommandResult> stop() override { return ready(); }
    std::future<engine::CommandResult> set_bm_connection(bool, std::uint64_t) override { return ready(); }
    std::future<engine::CommandResult> configure_bm(engine::BmTarget) override { return ready(); }
    std::future<engine::CommandResult> connect_radio(engine::RadioStartConfig c) override {
        last_radio = std::move(c);
        return ready();
    }
    std::future<engine::CommandResult> disconnect_radio() override { return ready(); }
    std::future<engine::CommandResult> replace_rx_policy(std::uint64_t, wirex::talkgroup_routing::RxPolicy) override { return ready(); }
    std::future<engine::CommandResult> replace_tx_policy(std::uint64_t, wirex::talkgroup_routing::TxTarget, bool) override { return ready(); }
    std::future<engine::CommandResult> quick_call_join(wirex::talkgroup_routing::GroupRoute) override { return ready(); }
    std::future<engine::CommandResult> set_audio_gains(std::uint32_t, std::uint32_t) override { return ready(); }
    std::future<engine::CommandResult> set_audio_endpoints(engine::AudioEndpoints) override { return ready(); }
    std::future<engine::CommandResult> upsert_radio_identity(std::uint32_t, std::uint64_t, std::optional<std::string>) override { return ready(); }
    std::future<engine::CommandResult> set_hri_tx_power(std::uint16_t value) override {
        calls.push_back("Y:" + std::to_string(value));
        auto next = std::make_shared<engine::Snapshot>(*state);
        ++next->seq;
        if (defer_power) {
            next->hri_y_tx_power_pending = true;
            pending_power = value;
        } else {
            next->hri_y_tx_power_deciwatts = value;
        }
        state = std::move(next);
        if (!defer_power) return ready();
        std::promise<engine::CommandResult> promise;
        promise.set_value({engine::CommandStatus::accepted, 0U, "deferred_hri_downlink"});
        return promise.get_future();
    }
    void finish_downlink() {
        auto next = std::make_shared<engine::Snapshot>(*state);
        ++next->seq;
        next->hri_y_tx_power_deciwatts = pending_power;
        next->hri_y_tx_power_pending = false;
        state = std::move(next);
    }
    std::shared_ptr<const engine::Snapshot> snapshot() const override { return state; }
    std::vector<engine::Event> drain_events(std::size_t) override { return {}; }
    void set_wakeup(std::function<void()>) override {}
    std::shared_ptr<engine::Snapshot> state{};
    bool defer_power{};
    std::uint16_t pending_power{};
    std::vector<std::string> calls{};
    std::optional<engine::RadioStartConfig> last_radio{};
};

struct Harness {
    gui::services::CatState cat{};
    gui::services::GuiConfig saved{};
    std::vector<std::string> calls{};
    bool mismatch{};
    bool reject_frequency{};
    int saves{};

    gui::services::Services services() {
        cat.connected = true;
        cat.observed_mode = gui::services::CatMode::fm;
        cat.observed_frequency_hz = 145000000U;
        cat.observed_power_w = 25U;
        cat.power_maximum_watts = 50U;
        cat.observed_revision = 1U;
        cat.revision = 1U;
        gui::services::Services services;
        services.config.load = [](std::string&) -> std::optional<gui::services::GuiConfig> {
            return gui::services::GuiConfig{};
        };
        services.config.save = [this](const gui::services::GuiConfig& c, std::string&) {
            saved = c;
            ++saves;
            return true;
        };
        services.cat.state = [this]() { return cat; };
        services.cat.apply = [this](gui::services::CatSettings s, gui::services::Done done) {
            if (s.power_w != 0U) {
                calls.push_back("PC:" + std::to_string(s.power_w));
                cat.observed_power_w = s.power_w;
                ++cat.observed_revision;
                ++cat.revision;
                done({engine::CommandStatus::accepted, 0U, {}});
            } else {
                calls.push_back("mode-frequency");
                if (reject_frequency) done({engine::CommandStatus::failed, 0U, "frequency_rejected"});
                else done({engine::CommandStatus::accepted, 0U, {}});
            }
        };
        services.cat.query = [this](gui::services::Done done) {
            calls.push_back("query");
            if (mismatch) cat.observed_power_w = 25U;
            ++cat.observed_revision;
            ++cat.revision;
            done({engine::CommandStatus::accepted, 0U, {}});
        };
        return services;
    }
};

void select_5w(gui::ViewModel& vm)
{
    (void)vm.pump();
    vm.cat_form.power_index = 0;
    vm.mark_cat_form_edited(gui::CatFormField::power);
}

void test_connect_uses_saved_power()
{
    RecordingEngine engine(false);
    Harness h;
    auto services = h.services();
    services.config.load = [](std::string&) -> std::optional<gui::services::GuiConfig> {
        gui::services::GuiConfig config;
        config.desired_power_watts = 15U;
        return config;
    };
    services.config.make_start_config = [](const gui::services::GuiConfig&, std::string&)
        -> std::optional<engine::StartConfig> {
        engine::StartConfig config;
        config.start_radio = true;
        config.hri_port = L"COM5";
        config.audio.expected_wave_in_endpoint_id = L"input";
        config.audio.expected_wave_out_endpoint_id = L"output";
        return config;
    };
    gui::ViewModel vm(engine, std::move(services), true);
    (void)vm.pump();
    vm.start();
    check(engine.last_radio && engine.last_radio->initial_tx_power_deciwatts == 150U,
          "connect_radio receives saved power in deciwatts");
}

void test_head_power_limit()
{
    RecordingEngine engine(true);
    Harness h;
    auto services = h.services();
    h.cat.power_maximum_watts = 10U;
    gui::ViewModel vm(engine, std::move(services), true);
    (void)vm.pump();
    vm.cat_form.power_index = 2;
    vm.mark_cat_form_edited(gui::CatFormField::power);
    vm.cat_apply();
    check(engine.calls.empty() && h.calls.empty() && vm.transient_failed(),
          "head supply rejects power above its CAT capability before changing Y or CAT");
}

void test_deferred_hri_power()
{
    RecordingEngine engine(true);
    engine.defer_power = true;
    Harness h;
    gui::ViewModel vm(engine, h.services(), true);
    select_5w(vm);
    vm.cat_apply();
    (void)vm.pump();
    (void)vm.pump();
    check(h.calls.empty() && h.saves == 0, "deferred downlink does not change CAT power early");
    engine.finish_downlink();
    (void)vm.pump();
    (void)vm.pump();
    check(!h.calls.empty() && h.calls[0] == "PC:5", "CAT power is applied after the queued Y power is sent");
}

void test_without_hri()
{
    RecordingEngine engine(false);
    Harness h;
    gui::ViewModel vm(engine, h.services(), true);
    select_5w(vm);
    vm.cat_apply();
    (void)vm.pump();
    check(engine.calls.empty(), "CAT-only path must not send an HRI command");
    check(!h.calls.empty() && h.calls.front() == "PC:5", "CAT-only path sets power");
    check(h.saves == 1 && h.saved.desired_power_watts == 5U, "CAT-only success persists desired power");
}

void test_with_hri(bool mismatch, bool reject_frequency)
{
    RecordingEngine engine(true);
    Harness h;
    h.mismatch = mismatch;
    h.reject_frequency = reject_frequency;
    gui::ViewModel vm(engine, h.services(), true);
    select_5w(vm);
    if (reject_frequency) {
        vm.cat_form.frequency_mhz = "146.000";
        vm.mark_cat_form_edited(gui::CatFormField::frequency);
    }
    vm.cat_apply();
    check(engine.calls.size() == 1U && engine.calls[0] == "Y:50" && h.calls.empty(),
          "HRI command is sent before CAT power");
    (void)vm.pump();
    (void)vm.pump();
    check(!h.calls.empty() && h.calls[0] == "PC:5", "HRI path sets CAT power independently");
    check(h.saves == 0, "HRI power is not persisted before post-Y confirmation");
    if (reject_frequency) check(h.calls.size() >= 2U && h.calls[1] == "mode-frequency",
                                 "frequency change is submitted separately after power");
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    (void)vm.pump();
    check(!h.calls.empty() && h.calls.back() == "query", "post-Y confirmation explicitly queries CAT");
    if (mismatch) {
        check(h.saves == 0 && vm.transient_failed() && vm.transient_text().find("电台未保持设定功率") != std::string::npos,
              "mismatched readback reports that power was not retained and does not persist");
    } else {
        check(h.saves == 1 && h.saved.desired_power_watts == 5U,
              "confirmed HRI power persists even if frequency was rejected");
    }
}

} // namespace

int main()
{
    test_connect_uses_saved_power();
    test_head_power_limit();
    test_deferred_hri_power();
    test_without_hri();
    test_with_hri(false, false);
    test_with_hri(true, false);
    test_with_hri(false, true);
    std::cout << "PASS: " << assertions << " HRI power ViewModel assertions\n";
    return 0;
}
