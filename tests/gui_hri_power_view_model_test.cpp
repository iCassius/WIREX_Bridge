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
    std::future<engine::CommandResult> set_hri_channel(std::uint32_t hz, wirex::hri_y::LchMode mode) override {
        calls.push_back("channel:" + std::to_string(hz));
        auto next = std::make_shared<engine::Snapshot>(*state);
        ++next->seq;
        if (defer_channel) {
            next->hri_y_channel_pending = true;
            pending_channel_hz = hz;
            pending_channel_mode = mode;
        } else {
            next->hri_y_lch_frequency_hz = hz;
            next->hri_y_lch_mode = mode;
        }
        state = std::move(next);
        if (!defer_channel) return ready();
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
    void finish_channel() {
        auto next = std::make_shared<engine::Snapshot>(*state);
        ++next->seq;
        next->hri_y_lch_frequency_hz = pending_channel_hz;
        next->hri_y_lch_mode = pending_channel_mode;
        next->hri_y_channel_pending = false;
        state = std::move(next);
    }
    std::shared_ptr<const engine::Snapshot> snapshot() const override { return state; }
    std::vector<engine::Event> drain_events(std::size_t) override { return {}; }
    void set_wakeup(std::function<void()>) override {}
    std::shared_ptr<engine::Snapshot> state{};
    bool defer_power{};
    std::uint16_t pending_power{};
    bool defer_channel{};
    std::uint32_t pending_channel_hz{};
    wirex::hri_y::LchMode pending_channel_mode{wirex::hri_y::LchMode::fm};
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
                calls.push_back(std::string(s.force_power_write ? "PC-forced:" : "PC:") + std::to_string(s.power_w));
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
        config.hri_frequency_hz = 430125000U;
        config.hri_mode = wirex::hri_y::LchMode::c4fm_dn;
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
    check(engine.last_radio && engine.last_radio->initial_lch_frequency_hz == 430125000U &&
          engine.last_radio->initial_lch_mode == wirex::hri_y::LchMode::c4fm_dn,
          "connect_radio receives saved HRI frequency and mode");
}

void test_connect_waits_for_cat_power_path()
{
    RecordingEngine engine(false);
    Harness h;
    auto services = h.services();
    h.cat.connected = false;
    h.cat.power_maximum_watts.reset();
    gui::services::Done connected;
    services.cat.connect = [&](std::wstring, std::uint32_t, gui::services::Done done) {
        connected = std::move(done);
    };
    services.config.load = [](std::string&) -> std::optional<gui::services::GuiConfig> {
        gui::services::GuiConfig config;
        config.desired_power_watts = 25U;
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
    check(static_cast<bool>(connected) && !engine.last_radio,
          "HRI attach waits for the in-progress CAT capability query");
    h.cat.connected = true;
    h.cat.power_maximum_watts = 10U;
    ++h.cat.revision;
    connected({engine::CommandStatus::accepted, 0U, {}});
    (void)vm.pump();
    check(engine.last_radio && engine.last_radio->initial_tx_power_deciwatts == 100U,
          "first Y honors the newly observed head power limit");
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
    engine.state->media_owner = wirex::talkgroup_routing::MediaOwner::rx_active;
    Harness h;
    gui::ViewModel vm(engine, h.services(), true);
    select_5w(vm);
    vm.cat_apply();
    (void)vm.pump();
    check(h.calls.empty() && !vm.transient_failed(), "deferred Y does not send CAT or report an error");
    vm.cat_form.power_index = 1;
    vm.mark_cat_form_edited(gui::CatFormField::power);
    vm.cat_apply();
    (void)vm.pump();
    check(engine.calls.size() == 2U && engine.calls.back() == "Y:100" && h.calls.empty(),
          "a newer power replaces the deferred request without a CAT write");
    engine.finish_downlink();
    (void)vm.pump();
    check(h.calls.empty(), "cleared pending flag alone does not bypass active downlink");
    engine.state = std::make_shared<engine::Snapshot>(*engine.state);
    ++engine.state->seq;
    engine.state->media_owner = wirex::talkgroup_routing::MediaOwner::idle;
    (void)vm.pump();
    (void)vm.pump();
    check(h.calls.size() == 1U && h.calls[0] == "PC-forced:10", "only the latest deferred power is echoed");
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    (void)vm.pump();
    check(h.calls.size() == 2U && h.calls[1] == "query" && h.saves == 1 &&
          h.saved.desired_power_watts == 10U, "deferred echo is read back and persisted");
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

void test_with_hri(bool mismatch)
{
    RecordingEngine engine(true);
    Harness h;
    h.mismatch = mismatch;
    gui::ViewModel vm(engine, h.services(), true);
    select_5w(vm);
    vm.cat_apply();
    check(engine.calls.size() == 1U && engine.calls[0] == "Y:50" && h.calls.empty(),
          "HRI power waits for the engine result before sending CAT");
    (void)vm.pump();
    check(!h.calls.empty() && h.calls[0] == "PC-forced:5", "accepted HRI power sends CAT echo");
    (void)vm.pump();
    check(h.saves == 0, "HRI power is not persisted before post-Y confirmation");
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    (void)vm.pump();
    check(!h.calls.empty() && h.calls.back() == "query", "post-Y confirmation explicitly queries CAT");
    if (mismatch) {
        check(h.saves == 0 && vm.transient_failed() && vm.transient_text().find("电台未保持设定功率") != std::string::npos,
              "mismatched readback reports that power was not retained and does not persist");
    } else {
        check(h.saves == 1 && h.saved.desired_power_watts == 5U, "confirmed HRI power persists");
    }
}

void test_channel(bool hri)
{
    RecordingEngine engine(hri);
    Harness h;
    gui::ViewModel vm(engine, h.services(), true);
    (void)vm.pump();
    vm.cat_form.frequency_mhz = "146.000";
    vm.cat_form.mode_index = 2;
    vm.mark_cat_form_edited(gui::CatFormField::frequency);
    vm.mark_cat_form_edited(gui::CatFormField::mode);
    vm.cat_apply();
    (void)vm.pump();
    if (!hri) {
        check(engine.calls.empty() && !h.calls.empty() && h.calls[0] == "mode-frequency",
              "without HRI channel uses CAT");
        return;
    }
    check(engine.calls.size() == 1U && engine.calls[0] == "channel:146000000" && h.calls.empty(),
          "HRI channel goes to engine without CAT writes");
    check(h.saves == 1 && h.saved.hri_frequency_hz == 146000000U &&
          h.saved.hri_mode == wirex::hri_y::LchMode::c4fm_dn, "HRI channel is persisted");
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    (void)vm.pump();
    check(!h.calls.empty() && h.calls.back() == "query" && vm.transient_failed() &&
          vm.transient_text().find("电台未保持设定频率/模式") != std::string::npos,
          "HRI channel mismatch is reported after readback");
}

void test_deferred_channel()
{
    RecordingEngine engine(true);
    engine.defer_channel = true;
    Harness h;
    gui::ViewModel vm(engine, h.services(), true);
    (void)vm.pump();
    vm.cat_form.frequency_mhz = "146.000";
    vm.mark_cat_form_edited(gui::CatFormField::frequency);
    vm.cat_apply();
    (void)vm.pump();
    check(vm.transient_text().find("延后") != std::string::npos && h.calls.empty(),
          "deferred channel reports delay without CAT writes");
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    check(h.calls.empty(), "deferred channel does not query before engine applies it");
    engine.finish_channel();
    h.cat.observed_frequency_hz = 146000000U;
    ++h.cat.observed_revision;
    ++h.cat.revision;
    (void)vm.pump();
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    (void)vm.pump();
    check(!h.calls.empty() && h.calls.back() == "query" && !vm.transient_failed(),
          "deferred channel queries after Y and accepts matching readback");
}

void test_channel_readback_waits_for_pending()
{
    RecordingEngine engine(true);
    Harness h;
    gui::ViewModel vm(engine, h.services(), true);
    (void)vm.pump();
    vm.cat_form.frequency_mhz = "146.000";
    vm.mark_cat_form_edited(gui::CatFormField::frequency);
    vm.cat_apply();
    (void)vm.pump();
    engine.state = std::make_shared<engine::Snapshot>(*engine.state);
    ++engine.state->seq;
    engine.state->hri_y_channel_pending = true;
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    check(h.calls.empty(), "channel readback waits whenever the engine reports a pending channel");
    engine.state = std::make_shared<engine::Snapshot>(*engine.state);
    ++engine.state->seq;
    engine.state->hri_y_channel_pending = false;
    h.cat.observed_frequency_hz = 146000000U;
    (void)vm.pump();
    std::this_thread::sleep_for(1300ms);
    (void)vm.pump();
    (void)vm.pump();
    check(h.calls.size() == 1U && h.calls[0] == "query" && !vm.transient_failed(),
          "channel readback resumes after pending clears");
}

void test_invalid_frequency()
{
    for (const char* text : {"143.999", "148.001", "429.999", "440.001", "145.1001", "invalid"}) {
        RecordingEngine engine(true);
        Harness h;
        gui::ViewModel vm(engine, h.services(), true);
        (void)vm.pump();
        vm.cat_form.frequency_mhz = text;
        vm.mark_cat_form_edited(gui::CatFormField::frequency);
        vm.cat_apply();
        check(engine.calls.empty() && h.calls.empty() && vm.transient_failed(),
              "invalid frequency is rejected without submitting");
    }
}

} // namespace

int main()
{
    test_connect_uses_saved_power();
    test_connect_waits_for_cat_power_path();
    test_head_power_limit();
    test_deferred_hri_power();
    test_without_hri();
    test_with_hri(false);
    test_with_hri(true);
    test_channel(false);
    test_channel(true);
    test_deferred_channel();
    test_channel_readback_waits_for_pending();
    test_invalid_frequency();
    std::cout << "PASS: " << assertions << " HRI power ViewModel assertions\n";
    return 0;
}
