#include "fake_engine.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <random>
#include <thread>
#include <unordered_map>
#include <utility>

namespace wirex::gui {
namespace {

using engine::BmLink;
using engine::CommandResult;
using engine::CommandStatus;
using engine::Event;
using engine::EventKind;
using engine::Phase;
using talkgroup_routing::MediaOwner;
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

std::uint64_t now_ms() {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count());
}

CommandResult result(CommandStatus status, std::uint64_t revision = 0U, std::string detail = {}) {
    CommandResult r;
    r.status = status;
    r.revision = revision;
    r.detail = std::move(detail);
    return r;
}

struct FakeCaller {
    std::uint32_t source_id;
    const char* callsign; // nullptr：身份缓存未命中
};

// 虚构呼号与 ID，仅用于离线演示。
constexpr std::array<FakeCaller, 8> kCallers{{
    {4609001U, "BA0TST"},
    {4609002U, "BG0DMO"},
    {4609003U, "BH0SIM"},
    {4609004U, nullptr},
    {4609005U, "BD0LAB"},
    {4609006U, "BI0FAK"},
    {3109007U, "N0CALL"},
    {4609008U, nullptr},
}};

bool same_group(const talkgroup_routing::GroupRoute& a, const talkgroup_routing::GroupRoute& b) {
    return a.destination_id == b.destination_id && a.slot == b.slot;
}

} // namespace

struct FakeEngine::Impl {
    explicit Impl(FakeEngineOptions opts) : options(opts), rng(opts.seed) {}

    FakeEngineOptions options;
    std::mt19937 rng;

    // ---- 只在模拟线程访问 ----
    engine::Snapshot state{};
    talkgroup_routing::RxPolicy rx_policy{};
    bool transmit_enabled{};
    std::uint32_t local_id{};
    bool bm_profile_valid{};
    std::string bm_profile_error{"profile_invalid"};
    std::uint64_t bm_epoch{};   // BM 断开/引擎停止时 +1，使旧的来话任务失效
    std::atomic<std::uint64_t> radio_generation{};
    std::atomic<bool> startup_pending{};
    std::uint64_t call_epoch{}; // 每通来话 +1
    std::uint32_t calls_until_tx{4U};
    std::unordered_map<std::uint32_t, std::string> identities{};

    // ---- 跨线程 ----
    mutable std::mutex mutex;
    std::condition_variable cv;
    std::multimap<Clock::time_point, std::function<void()>> tasks;
    bool stopping{};
    std::shared_ptr<const engine::Snapshot> published{std::make_shared<const engine::Snapshot>()};
    std::deque<Event> events;
    std::function<void()> wakeup;
    std::thread worker;

    void post_after(std::chrono::milliseconds delay, std::function<void()> action) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (stopping) return;
            tasks.emplace(Clock::now() + delay, std::move(action));
        }
        cv.notify_one();
    }

    void run() {
        std::unique_lock<std::mutex> lock(mutex);
        while (!stopping) {
            if (tasks.empty()) {
                cv.wait(lock);
                continue;
            }
            const auto due = tasks.begin()->first;
            if (Clock::now() < due) {
                cv.wait_until(lock, due);
                continue;
            }
            auto action = std::move(tasks.begin()->second);
            tasks.erase(tasks.begin());
            lock.unlock();
            action();
            lock.lock();
        }
    }

    void publish() {
        std::function<void()> wake;
        {
            std::lock_guard<std::mutex> lock(mutex);
            ++state.seq;
            published = std::make_shared<const engine::Snapshot>(state);
            wake = wakeup;
        }
        if (wake) wake();
    }

    void push_event(Event event) {
        std::lock_guard<std::mutex> lock(mutex);
        if (events.size() >= 1024U) {
            events.pop_front();
        }
        events.push_back(std::move(event));
    }

    void push_simple(EventKind kind, std::string text = {}) {
        Event e;
        e.kind = kind;
        e.at_ms = now_ms();
        e.text = std::move(text);
        push_event(std::move(e));
    }

    // 在模拟线程上执行 body 并完成 promise；body 负责发布状态。
    std::future<CommandResult> command(std::chrono::milliseconds delay, std::function<CommandResult()> body) {
        auto promise = std::make_shared<std::promise<CommandResult>>();
        auto future = promise->get_future();
        post_after(delay, [this, promise, body = std::move(body)]() {
            CommandResult r;
            try {
                r = body();
            } catch (const std::exception& e) {
                r = result(CommandStatus::failed, 0U, e.what());
            }
            promise->set_value(std::move(r));
            publish();
        });
        return future;
    }

    std::optional<engine::CallInfo> pick_call() {
        std::vector<engine::CallInfo> candidates;
        for (const auto& g : rx_policy.allowed_groups) {
            const bool blocked = std::any_of(rx_policy.blocked_groups.begin(), rx_policy.blocked_groups.end(),
                                             [&](const auto& b) { return same_group(b, g); });
            if (blocked) continue;
            engine::CallInfo c;
            c.destination_id = g.destination_id;
            c.slot = g.slot;
            c.kind = dmr_call::CallKind::group;
            candidates.push_back(c);
        }
        if (rx_policy.private_mode == talkgroup_routing::PrivateMode::selected_peers) {
            for (const auto& p : rx_policy.private_peers) {
                engine::CallInfo c;
                c.source_id = p.source_id;
                c.destination_id = p.local_destination_id;
                c.slot = p.slot;
                c.kind = dmr_call::CallKind::private_call;
                candidates.push_back(c);
            }
        }
        if (candidates.empty()) return std::nullopt;
        std::uniform_int_distribution<std::size_t> pick(0U, candidates.size() - 1U);
        auto call = candidates[pick(rng)];
        if (call.kind == dmr_call::CallKind::group) {
            std::uniform_int_distribution<std::size_t> who(0U, kCallers.size() - 1U);
            const auto& caller = kCallers[who(rng)];
            call.source_id = caller.source_id;
        }
        call.callsign = lookup_callsign(call.source_id);
        call.started_ms = now_ms();
        return call;
    }

    std::string lookup_callsign(std::uint32_t source_id) const {
        if (auto it = identities.find(source_id); it != identities.end()) return it->second;
        for (const auto& c : kCallers) {
            if (c.source_id == source_id && c.callsign != nullptr) return c.callsign;
        }
        if (source_id == 460997U) return "PARROT";
        return {};
    }

    void schedule_next_call(std::chrono::milliseconds delay) {
        const auto epoch = bm_epoch;
        post_after(delay, [this, epoch]() { begin_call(epoch); });
    }

    void begin_call(std::uint64_t epoch) {
        if (epoch != bm_epoch || state.bm_link != BmLink::connected || state.phase != Phase::running) return;
        std::uniform_int_distribution<int> gap(2500, 7000);
        if (state.media_owner != MediaOwner::idle) {
            schedule_next_call(std::chrono::milliseconds(gap(rng)));
            return;
        }
        if (transmit_enabled && --calls_until_tx == 0U) {
            calls_until_tx = 5U;
            begin_tx(epoch);
            return;
        }
        auto call = pick_call();
        if (!call) {
            schedule_next_call(std::chrono::milliseconds(gap(rng)));
            return;
        }
        state.active_rx_call = call;
        state.media_owner = MediaOwner::rx_active;
        ++state.counters.calls_started;
        Event e;
        e.kind = EventKind::rx_call_started;
        e.at_ms = call->started_ms;
        e.call = call;
        push_event(std::move(e));
        publish();
        const auto this_call = ++call_epoch;
        std::uniform_int_distribution<int> length(2000, 7000);
        const int ticks = length(rng) / 100;
        level_tick(epoch, this_call, ticks);
    }

    void level_tick(std::uint64_t epoch, std::uint64_t this_call, int remaining) {
        post_after(100ms, [this, epoch, this_call, remaining]() {
            if (epoch != bm_epoch || this_call != call_epoch || !state.active_rx_call) return;
            if (remaining <= 0) {
                end_call("terminator");
                std::uniform_int_distribution<int> gap(2500, 7000);
                schedule_next_call(std::chrono::milliseconds(gap(rng)));
                return;
            }
            std::uniform_real_distribution<float> level(0.15F, 0.85F);
            state.levels.rx_peak = 0.6F * state.levels.rx_peak + 0.4F * level(rng);
            ++state.counters.rx_datagrams;
            publish();
            level_tick(epoch, this_call, remaining - 1);
        });
    }

    void end_call(const char* reason) {
        if (!state.active_rx_call) return;
        Event e;
        e.kind = EventKind::rx_call_ended;
        e.at_ms = now_ms();
        e.call = state.active_rx_call;
        e.end_reason = reason;
        push_event(std::move(e));
        state.active_rx_call.reset();
        state.media_owner = MediaOwner::idle;
        state.levels.rx_peak = 0.0F;
        ++state.counters.calls_ended;
        publish();
    }

    void begin_tx(std::uint64_t epoch) {
        state.tx_active = true;
        state.media_owner = MediaOwner::tx_active;
        ++state.counters.ptt_tx_starts;
        push_simple(EventKind::tx_started);
        publish();
        post_after(2500ms, [this, epoch]() {
            if (epoch != bm_epoch) return;
            state.tx_active = false;
            state.media_owner = MediaOwner::idle;
            state.levels.tx_peak = 0.0F;
            push_simple(EventKind::tx_ended);
            publish();
            schedule_next_call(3000ms);
        });
    }

    void drop_bm() {
        ++bm_epoch;
        ++call_epoch;
        end_call("bm_disconnected");
        state.tx_active = false;
        state.media_owner = MediaOwner::idle;
        state.bm_link = BmLink::disabled;
        push_simple(EventKind::bm_link_changed);
    }

    void bm_step(std::uint64_t epoch, BmLink next, std::chrono::milliseconds delay) {
        post_after(delay, [this, epoch, next]() {
            if (epoch != bm_epoch || !state.bm_requested_enabled) return;
            state.bm_link = next;
            push_simple(EventKind::bm_link_changed);
            publish();
            if (next == BmLink::resolving) {
                bm_step(epoch, BmLink::connecting, 400ms);
            } else if (next == BmLink::connecting) {
                bm_step(epoch, BmLink::connected, 800ms);
            } else if (next == BmLink::connected) {
                schedule_next_call(1500ms);
            }
        });
    }

    void seed_demo() {
        local_id = 4609100U;
        state.phase = Phase::running;
        state.serial_open = state.hri_ready = state.wave_in_open = state.wave_out_open = true;
        state.bm_link = BmLink::connected;
        state.bm_requested_enabled = true;
        state.bm_connection_revision = 1U;
        state.tx_target = {46001U, dmr_call::CallKind::group, dmr_call::Slot::ts2};
        state.radio_playback_gain_milli = 4000U;
        state.mic_transmit_gain_milli = 16000U;
        transmit_enabled = true;
        rx_policy.group_mode = talkgroup_routing::GroupMode::selected;
        for (std::uint32_t tg : {46001U, 91U, 4600U, 46025U}) {
            rx_policy.allowed_groups.push_back({tg, dmr_call::Slot::ts2});
        }
        rx_policy.private_mode = talkgroup_routing::PrivateMode::selected_peers;
        rx_policy.private_peers.push_back({460997U, local_id, dmr_call::Slot::ts2});

        // 历史来话：过去 20 分钟内的 11 通，最后一通仍在进行。
        const auto now = now_ms();
        constexpr std::array<std::pair<std::size_t, std::uint32_t>, 12> history{{
            {0U, 46001U}, {1U, 91U}, {3U, 46001U}, {2U, 4600U}, {4U, 91U}, {6U, 46025U},
            {5U, 46001U}, {1U, 4600U}, {7U, 91U}, {0U, 46001U}, {2U, 91U}, {4U, 46001U},
        }};
        for (std::size_t i = 0; i < history.size(); ++i) {
            engine::CallInfo c;
            c.source_id = kCallers[history[i].first].source_id;
            c.destination_id = history[i].second;
            c.kind = dmr_call::CallKind::group;
            c.slot = dmr_call::Slot::ts2;
            c.callsign = lookup_callsign(c.source_id);
            c.started_ms = now - (history.size() - i) * 97'000U;
            Event start;
            start.kind = EventKind::rx_call_started;
            start.at_ms = c.started_ms;
            start.call = c;
            push_event(start);
            if (i + 1U < history.size()) {
                Event end = start;
                end.kind = EventKind::rx_call_ended;
                end.at_ms = c.started_ms + 6000U;
                end.end_reason = "terminator";
                push_event(std::move(end));
            } else {
                c.started_ms = now - 12'000U;
                state.active_rx_call = c;
                state.media_owner = MediaOwner::rx_active;
                state.levels.rx_peak = 0.62F;
            }
        }
        state.counters.calls_started = history.size();
        state.counters.calls_ended = history.size() - 1U;
        state.seq = 1U;
        published = std::make_shared<const engine::Snapshot>(state);
        // 演示用的进行中来话持续约 30 s，之后进入随机来话循环。
        const auto this_call = ++call_epoch;
        level_tick(bm_epoch, this_call, 300);
    }
};

FakeEngine::FakeEngine(FakeEngineOptions options) : impl_(std::make_unique<Impl>(options)) {
    if (options.seed_demo) impl_->seed_demo();
    impl_->worker = std::thread([impl = impl_.get()]() { impl->run(); });
}

FakeEngine::~FakeEngine() {
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->stopping = true;
        impl_->tasks.clear(); // 未完成的 promise 被销毁，调用方 future 得到 broken_promise
    }
    impl_->cv.notify_one();
    if (impl_->worker.joinable()) impl_->worker.join();
}

void FakeEngine::post_after(std::chrono::milliseconds delay, std::function<void()> action) {
    impl_->post_after(delay, std::move(action));
}

std::future<CommandResult> FakeEngine::start(engine::StartConfig config) {
    auto* s = impl_.get();
    auto promise = std::make_shared<std::promise<CommandResult>>();
    auto future = promise->get_future();
    bool expected = false;
    if (!s->startup_pending.compare_exchange_strong(expected, true)) {
        promise->set_value(result(CommandStatus::busy, 0U, "start_already_pending"));
        return future;
    }
    const auto generation = s->radio_generation.fetch_add(1U) + 1U;
    s->post_after(50ms, [s, promise, generation, config = std::move(config)]() mutable {
        if (generation != s->radio_generation.load()) {
            s->startup_pending = false;
            promise->set_value(result(CommandStatus::not_ready, 0U, "start_cancelled"));
            return;
        }
        if (s->state.phase != Phase::stopped && s->state.phase != Phase::failed) {
            s->startup_pending = false;
            promise->set_value(result(CommandStatus::busy, 0U, "already_running"));
            return;
        }
        s->state = engine::Snapshot{s->state.seq};
        s->state.phase = Phase::starting;
        s->state.serial_open = config.start_radio && !config.hri_port.empty();
        s->state.hri_port = s->state.serial_open ? config.hri_port : std::wstring{};
        s->state.radio_error = s->state.serial_open ? config.radio_start_error
            : (config.radio_start_error.empty() ? "radio_not_started" : config.radio_start_error);
        s->publish();
        s->post_after(600ms, [s, promise, generation, config = std::move(config)]() mutable {
            if (generation != s->radio_generation.load()) {
                s->startup_pending = false;
                promise->set_value(result(CommandStatus::not_ready, 0U, "start_cancelled"));
                return;
            }
            s->state.phase = Phase::running;
            s->state.hri_ready = s->state.serial_open;
            s->state.wave_in_open = s->state.serial_open;
            s->state.wave_out_open = s->state.serial_open;
            if (s->state.serial_open) {
                s->state.wave_in_endpoint_id = config.audio.expected_wave_in_endpoint_id;
                s->state.wave_out_endpoint_id = config.audio.expected_wave_out_endpoint_id;
                s->state.radio_error.clear();
            }
            s->state.radio_playback_gain_milli = config.radio_playback_gain_milli;
            s->state.mic_transmit_gain_milli = config.mic_transmit_gain_milli;
            s->state.tx_target = config.tx_policy.target;
            s->transmit_enabled = config.tx_policy.transmit_enabled;
            s->rx_policy = config.rx_policy;
            s->local_id = config.local_source_id;
            s->bm_profile_valid = !config.bm.profile.password.empty() &&
                !config.bm.profile.callsign.empty() && config.bm.profile.gateway_id != 0U &&
                !config.bm.master_host.empty() && config.bm.master_port != 0U;
            s->bm_profile_error = config.bm.profile.password.empty() ? "password_required" :
                (s->bm_profile_valid ? "none" : "profile_invalid");
            std::fill(config.bm.profile.password.begin(), config.bm.profile.password.end(), '\0');
            config.bm.profile.password.clear();
            s->state.bm_requested_enabled = !config.bm_start_disconnected;
            s->startup_pending = false;
            promise->set_value(result(CommandStatus::accepted));
            s->publish();
        });
    });
    return future;
}

std::future<CommandResult> FakeEngine::stop() {
    auto* s = impl_.get();
    auto promise = std::make_shared<std::promise<CommandResult>>();
    auto future = promise->get_future();
    const auto generation = s->radio_generation.fetch_add(1U) + 1U;
    s->startup_pending = false;
    s->post_after(30ms, [s, promise, generation]() {
        if (generation != s->radio_generation.load()) {
            promise->set_value(result(CommandStatus::not_ready, 0U, "stop_cancelled"));
            return;
        }
        if (s->state.phase == Phase::stopped) {
            promise->set_value(result(CommandStatus::idempotent));
            return;
        }
        s->drop_bm();
        s->state.bm_requested_enabled = false;
        s->state.phase = Phase::stopping;
        s->publish();
        s->post_after(400ms, [s, promise, generation]() {
            if (generation != s->radio_generation.load()) {
                promise->set_value(result(CommandStatus::not_ready, 0U, "stop_cancelled"));
                return;
            }
            const auto seq = s->state.seq;
            const auto bm_rev = s->state.bm_connection_revision;
            s->state = engine::Snapshot{};
            s->state.seq = seq;
            s->state.bm_connection_revision = bm_rev;
            promise->set_value(result(CommandStatus::accepted));
            s->publish();
        });
    });
    return future;
}

std::future<CommandResult> FakeEngine::connect_radio(engine::RadioStartConfig config) {
    auto* s = impl_.get();
    auto promise = std::make_shared<std::promise<CommandResult>>();
    auto future = promise->get_future();
    const auto generation = s->radio_generation.fetch_add(1U) + 1U;
    s->post_after(250ms, [s, promise, generation, config = std::move(config)]() mutable {
        if (generation != s->radio_generation.load()) {
            promise->set_value(result(CommandStatus::not_ready, 0U, "radio_connect_cancelled"));
            return;
        }
        if (s->state.phase != Phase::running) {
            promise->set_value(result(CommandStatus::not_ready, 0U, "runtime_not_running"));
            return;
        }
        if (config.hri_port.empty() || config.audio.expected_wave_in_endpoint_id.empty() ||
            config.audio.expected_wave_out_endpoint_id.empty()) {
            s->state.radio_error = "radio_selection_unresolved";
            promise->set_value(result(CommandStatus::invalid, 0U, s->state.radio_error));
            return;
        }
        s->state.hri_port = config.hri_port;
        s->state.serial_open = true;
        s->state.hri_ready = true;
        s->state.wave_in_open = true;
        s->state.wave_out_open = true;
        s->state.wave_in_endpoint_id = std::move(config.audio.expected_wave_in_endpoint_id);
        s->state.wave_out_endpoint_id = std::move(config.audio.expected_wave_out_endpoint_id);
        s->state.radio_error.clear();
        promise->set_value(result(CommandStatus::accepted));
        s->publish();
    });
    return future;
}

std::future<CommandResult> FakeEngine::disconnect_radio() {
    auto* s = impl_.get();
    auto promise = std::make_shared<std::promise<CommandResult>>();
    auto future = promise->get_future();
    const auto generation = s->radio_generation.fetch_add(1U) + 1U;
    s->post_after(150ms, [s, promise, generation]() {
        if (generation != s->radio_generation.load()) {
            promise->set_value(result(CommandStatus::not_ready, 0U, "radio_disconnect_cancelled"));
            return;
        }
        if (s->state.phase != Phase::running) {
            promise->set_value(result(CommandStatus::not_ready, 0U, "runtime_not_running"));
            return;
        }
        s->state.serial_open = false;
        s->state.hri_ready = false;
        s->state.wave_in_open = false;
        s->state.wave_out_open = false;
        s->state.hri_port.clear();
        s->state.wave_in_endpoint_id.clear();
        s->state.wave_out_endpoint_id.clear();
        s->end_call("radio_disconnected");
        promise->set_value(result(CommandStatus::accepted));
        s->publish();
    });
    return future;
}

std::future<CommandResult> FakeEngine::set_bm_connection(bool enabled, std::uint64_t requested_revision) {
    auto* s = impl_.get();
    return s->command(150ms, [s, enabled, requested_revision]() {
        auto& st = s->state;
        if (requested_revision == 0U) {
            return result(CommandStatus::stale_revision, st.bm_connection_revision, "bm_revision_conflict");
        }
        if (requested_revision < st.bm_connection_revision) {
            return result(CommandStatus::stale_revision, st.bm_connection_revision);
        }
        if (requested_revision == st.bm_connection_revision) {
            if (enabled == st.bm_requested_enabled) return result(CommandStatus::idempotent, st.bm_connection_revision);
            return result(CommandStatus::stale_revision, st.bm_connection_revision, "bm_revision_conflict");
        }
        if (st.phase != Phase::running && st.phase != Phase::starting) {
            return result(CommandStatus::not_ready, st.bm_connection_revision, "runtime_not_running");
        }
        st.bm_connection_revision = requested_revision;
        if (enabled) {
            if (!s->bm_profile_valid) {
                st.bm_requested_enabled = false;
                st.bm_link = BmLink::failed;
                st.bm_error = s->bm_profile_error;
                return result(CommandStatus::invalid, st.bm_connection_revision, st.bm_error);
            }
            st.bm_requested_enabled = true;
            st.bm_error = "none";
            s->bm_step(s->bm_epoch, BmLink::resolving, 0ms);
        } else {
            st.bm_requested_enabled = false;
            s->drop_bm();
        }
        return result(CommandStatus::accepted, st.bm_connection_revision);
    });
}

std::future<CommandResult> FakeEngine::configure_bm(engine::BmTarget config) {
    auto* s = impl_.get();
    return s->command(100ms, [s, config = std::move(config)]() mutable {
        auto& st = s->state;
        if (st.phase != Phase::running) {
            return result(CommandStatus::not_ready, st.bm_connection_revision, "runtime_not_running");
        }
        if (st.bm_requested_enabled || st.bm_link == BmLink::connected || st.bm_link == BmLink::connecting ||
            st.bm_link == BmLink::resolving) {
            return result(CommandStatus::busy, st.bm_connection_revision, "bm_disconnect_before_configure");
        }
        const bool password_present = !config.profile.password.empty();
        s->bm_profile_valid = password_present && !config.profile.callsign.empty() &&
            config.profile.gateway_id != 0U && !config.master_host.empty() && config.master_port != 0U;
        s->bm_profile_error = !password_present ? "password_required" :
            (s->bm_profile_valid ? "none" : "profile_invalid");
        s->local_id = config.local_source_id;
        s->rx_policy = std::move(config.rx_policy);
        s->transmit_enabled = config.tx_policy.transmit_enabled;
        st.tx_target = config.tx_policy.target;
        st.bm_error = s->bm_profile_error;
        if (st.bm_link == BmLink::failed) st.bm_link = BmLink::disabled;
        std::fill(config.profile.password.begin(), config.profile.password.end(), '\0');
        config.profile.password.clear();
        return result(CommandStatus::accepted, st.bm_connection_revision);
    });
}

std::future<CommandResult> FakeEngine::replace_rx_policy(std::uint64_t expected_revision,
                                                         talkgroup_routing::RxPolicy policy) {
    auto* s = impl_.get();
    return s->command(120ms, [s, expected_revision, policy = std::move(policy)]() {
        auto& st = s->state;
        if (expected_revision != st.rx_policy_revision) return result(CommandStatus::stale_revision, st.rx_policy_revision);
        s->rx_policy = policy;
        ++st.rx_policy_revision;
        return result(CommandStatus::accepted, st.rx_policy_revision);
    });
}

std::future<CommandResult> FakeEngine::replace_tx_policy(std::uint64_t expected_revision,
                                                         talkgroup_routing::TxTarget target, bool transmit_enabled) {
    auto* s = impl_.get();
    return s->command(120ms, [s, expected_revision, target, transmit_enabled]() {
        auto& st = s->state;
        if (expected_revision != st.tx_policy_revision) return result(CommandStatus::stale_revision, st.tx_policy_revision);
        if (st.tx_active) return result(CommandStatus::busy, st.tx_policy_revision, "tx_active");
        st.tx_target = target;
        s->transmit_enabled = transmit_enabled;
        ++st.tx_policy_revision;
        return result(CommandStatus::accepted, st.tx_policy_revision);
    });
}

std::future<CommandResult> FakeEngine::quick_call_join(talkgroup_routing::GroupRoute route) {
    auto* s = impl_.get();
    return s->command(500ms, [s, route]() {
        const auto& st = s->state;
        if (st.phase != Phase::running || st.bm_link != BmLink::connected) return result(CommandStatus::not_ready, 0U, "bm_not_ready");
        if (st.tx_active) return result(CommandStatus::busy, 0U, "media_busy");
        if (route.destination_id == 0U || route.destination_id == 4000U) return result(CommandStatus::invalid, 0U, "invalid_group");
        Event e;
        e.kind = EventKind::quick_call_result;
        e.at_ms = now_ms();
        e.text = "TG " + std::to_string(route.destination_id) + " 激活请求已发送";
        s->push_event(std::move(e));
        return result(CommandStatus::accepted, 0U, "sent");
    });
}

std::future<CommandResult> FakeEngine::set_audio_gains(std::uint32_t radio_playback_gain_milli,
                                                       std::uint32_t mic_transmit_gain_milli) {
    auto* s = impl_.get();
    return s->command(80ms, [s, radio_playback_gain_milli, mic_transmit_gain_milli]() {
        auto& st = s->state;
        const auto in_range = [](std::uint32_t v) { return v >= 250U && v <= 16000U; };
        if (!in_range(radio_playback_gain_milli) || !in_range(mic_transmit_gain_milli)) {
            return result(CommandStatus::invalid, st.audio_gains_revision, "gain_out_of_range");
        }
        if (st.radio_playback_gain_milli == radio_playback_gain_milli && st.mic_transmit_gain_milli == mic_transmit_gain_milli) {
            return result(CommandStatus::idempotent, st.audio_gains_revision);
        }
        st.radio_playback_gain_milli = radio_playback_gain_milli;
        st.mic_transmit_gain_milli = mic_transmit_gain_milli;
        ++st.audio_gains_revision;
        return result(CommandStatus::accepted, st.audio_gains_revision);
    });
}

std::future<CommandResult> FakeEngine::set_audio_endpoints(engine::AudioEndpoints audio) {
    auto* s = impl_.get();
    return s->command(80ms, [s, audio = std::move(audio)]() mutable {
        auto& st = s->state;
        if (audio.expected_wave_in_endpoint_id.empty() || audio.expected_wave_out_endpoint_id.empty()) {
            return result(CommandStatus::invalid, st.audio_endpoints_revision, "invalid_audio_endpoints");
        }
        if (st.phase != engine::Phase::running && st.phase != engine::Phase::starting) {
            return result(CommandStatus::not_ready, st.audio_endpoints_revision, "engine_not_running");
        }
        if (st.wave_in_endpoint_id == audio.expected_wave_in_endpoint_id &&
            st.wave_out_endpoint_id == audio.expected_wave_out_endpoint_id) {
            return result(CommandStatus::idempotent, st.audio_endpoints_revision);
        }
        st.wave_in_endpoint_id = std::move(audio.expected_wave_in_endpoint_id);
        st.wave_out_endpoint_id = std::move(audio.expected_wave_out_endpoint_id);
        ++st.audio_endpoints_revision;
        return result(CommandStatus::accepted, st.audio_endpoints_revision);
    });
}

std::future<CommandResult> FakeEngine::upsert_radio_identity(std::uint32_t source_id, std::uint64_t revision,
                                                             std::optional<std::string> callsign) {
    auto* s = impl_.get();
    return s->command(20ms, [s, source_id, revision, callsign = std::move(callsign)]() {
        if (callsign) {
            s->identities[source_id] = *callsign;
        } else {
            s->identities.erase(source_id);
        }
        return result(CommandStatus::accepted, revision);
    });
}

std::shared_ptr<const engine::Snapshot> FakeEngine::snapshot() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->published;
}

std::vector<Event> FakeEngine::drain_events(std::size_t max) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    std::vector<Event> out;
    while (!impl_->events.empty() && out.size() < max) {
        out.push_back(std::move(impl_->events.front()));
        impl_->events.pop_front();
    }
    return out;
}

void FakeEngine::set_wakeup(std::function<void()> wakeup) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->wakeup = std::move(wakeup);
}

// ---------------------------------------------------------------- fake services

namespace {

struct FakeServiceState {
    std::mutex mutex;
    services::CatState cat{};
    std::uint64_t cat_generation{};
    services::GuiConfig config{};
    std::vector<services::StaticGroup> static_groups{{46001U, 2}, {4600U, 2}, {91U, 2}, {46025U, 2}};
};

services::GuiConfig demo_config() {
    services::GuiConfig c;
    c.callsign = "N0CALL";
    c.dmr_id = 4609100U;
    c.device_number = "01";
    c.gateway_id = 460910001U;
    c.bm_password = "demo-password";
    c.bm_api_key = "demo-api-key";
    c.hri_port = L"COM5";
    c.cat_port = L"COM6";
    c.wave_in_endpoint_id = L"{0.0.1.00000000}.{fake-in}";
    c.wave_out_endpoint_id = L"{0.0.0.00000000}.{fake-out}";
    c.playback_gain_step = 4U;
    c.transmit_gain_step = 16U;
    using dmr_call::CallKind;
    using dmr_call::Slot;
    c.channels = {
        {46001U, CallKind::group, Slot::ts2, ""},
        {91U, CallKind::group, Slot::ts2, ""},
        {460997U, CallKind::private_call, Slot::ts2, "中国鹦鹉"},
        {4600U, CallKind::group, Slot::ts2, ""},
        {46025U, CallKind::group, Slot::ts2, ""},
    };
    c.tx_target = talkgroup_routing::TxTarget{46001U, CallKind::group, Slot::ts2};
    return c;
}

} // namespace

services::Services make_fake_services(FakeEngine& engine) {
    auto st = std::make_shared<FakeServiceState>();
    st->config = demo_config();
    services::Services sv;

    sv.devices.enumerate = []() {
        services::DeviceInventory inv;
        inv.serial_discovery_status = "synthetic";
        inv.serial_ports = {
            {L"COM3", "COM3 · USB Serial Device", false, true, 100, "USB 串行接口候选"},
            {L"COM5", "COM5 · Silicon Labs CP210x (Wires-X)", true, false, 0, "唯一 HRI 设备"},
            {L"COM6", "COM6 · Silicon Labs CP210x (CAT)", false, true, 220, "CP210x 串口匹配"},
        };
        inv.wave_in = {{L"{0.0.1.00000000}.{fake-in}", "麦克风 (USB Audio CODEC)", 0U, true}};
        inv.wave_out = {{L"{0.0.0.00000000}.{fake-out}", "扬声器 (USB Audio CODEC)", 0U, true}};
        return inv;
    };

    sv.cat.state = [st]() {
        std::lock_guard<std::mutex> lock(st->mutex);
        return st->cat;
    };
    sv.cat.connect = [st, &engine](std::wstring port, std::uint32_t baud, services::Done done) {
        std::uint64_t generation = 0U;
        {
            std::lock_guard<std::mutex> lock(st->mutex);
            generation = ++st->cat_generation;
            st->cat.busy = true;
            ++st->cat.revision;
        }
        engine.post_after(500ms, [st, generation, port = std::move(port), baud, done = std::move(done)]() {
            bool current = false;
            {
                std::lock_guard<std::mutex> lock(st->mutex);
                current = generation == st->cat_generation;
                if (current) {
                    st->cat.busy = false;
                    st->cat.connected = true;
                    st->cat.port = port.empty() || port == L"auto" ? L"COM6" : port;
                    st->cat.baud_rate = baud;
                    st->cat.observed_mode = services::CatMode::fm;
                    st->cat.observed_frequency_hz = 145'000'000U;
                    st->cat.observed_power_w = 25U;
                    ++st->cat.observed_revision;
                    st->cat.error.clear();
                    ++st->cat.revision;
                }
            }
            if (done) done(current ? result(CommandStatus::accepted)
                                   : result(CommandStatus::not_ready, 0U, "cat_connection_cancelled"));
        });
    };
    sv.cat.disconnect = [st, &engine](services::Done done) {
        std::uint64_t generation = 0U;
        {
            std::lock_guard<std::mutex> lock(st->mutex);
            generation = ++st->cat_generation;
            st->cat.busy = true;
            ++st->cat.revision;
        }
        engine.post_after(200ms, [st, generation, done = std::move(done)]() {
            bool current = false;
            {
                std::lock_guard<std::mutex> lock(st->mutex);
                current = generation == st->cat_generation;
                if (current) {
                    const auto revision = st->cat.revision + 1U;
                    st->cat = services::CatState{};
                    st->cat.revision = revision;
                }
            }
            if (done) done(current ? result(CommandStatus::accepted)
                                   : result(CommandStatus::not_ready, 0U, "cat_disconnect_cancelled"));
        });
    };
    sv.cat.apply = [st, &engine](services::CatSettings settings, services::Done done) {
        engine.post_after(400ms, [st, settings, done = std::move(done)]() {
            CommandResult r = result(CommandStatus::accepted);
            {
                std::lock_guard<std::mutex> lock(st->mutex);
                if (!st->cat.connected) {
                    r = result(CommandStatus::not_ready, 0U, "cat_not_connected");
                } else {
                    st->cat.observed_mode = settings.main_mode;
                    if (settings.main_frequency_hz != 0U) st->cat.observed_frequency_hz = settings.main_frequency_hz;
                    st->cat.observed_power_w = settings.power_w;
                    ++st->cat.observed_revision;
                    ++st->cat.revision;
                }
            }
            if (done) done(r);
        });
    };

    sv.config.load = [st](std::string&) -> std::optional<services::GuiConfig> {
        std::lock_guard<std::mutex> lock(st->mutex);
        return st->config;
    };
    sv.config.save = [st](const services::GuiConfig& config, std::string&) {
        std::lock_guard<std::mutex> lock(st->mutex);
        st->config = config;
        return true;
    };
    sv.config.make_runtime_config = [](const services::GuiConfig& config, std::string&) -> std::optional<engine::StartConfig> {
        engine::StartConfig sc;
        sc.start_radio = false;
        sc.radio_start_error = "radio_not_started";
        sc.bm.master_host = config.master_host;
        sc.bm.master_port = config.master_port;
        sc.bm.profile.gateway_id = config.dmr_id;
        sc.bm.profile.callsign = config.callsign;
        sc.bm.profile.password = config.bm_password;
        sc.local_source_id = config.dmr_id;
        return sc;
    };
    sv.config.make_start_config = [](const services::GuiConfig& config, std::string& error) -> std::optional<engine::StartConfig> {
        if (config.hri_port.empty() || config.wave_in_endpoint_id.empty() || config.wave_out_endpoint_id.empty()) {
            error = "未能解析 Wires-X 串口和 USB Audio 端点。";
            return std::nullopt;
        }
        engine::StartConfig sc;
        sc.hri_port = config.hri_port;
        sc.audio.expected_wave_in_endpoint_id = config.wave_in_endpoint_id;
        sc.audio.expected_wave_out_endpoint_id = config.wave_out_endpoint_id;
        sc.bm.master_host = config.master_host;
        sc.bm.master_port = config.master_port;
        sc.bm.profile.gateway_id = config.dmr_id;
        sc.bm.profile.callsign = config.callsign;
        sc.bm.profile.password = config.bm_password;
        sc.local_source_id = config.dmr_id;
        sc.start_radio = true;
        return sc;
    };

    // BM 静态组：内存列表，设备状态固定为 0（添加时隙 2）。
    auto list_result = [st]() {
        services::BmApiResult r;
        r.groups = st->static_groups;
        r.groups_valid = true;
        r.add_slot = 2;
        r.device_status = 0;
        r.message = "已读取 " + std::to_string(r.groups.size()) + " 条 BM 静态组；设备状态 0。";
        return r;
    };
    sv.bm_api.list_static_groups = [st, &engine, list_result](std::uint32_t, std::string, services::BmApiDone done) {
        engine.post_after(300ms, [st, list_result, done = std::move(done)]() {
            services::BmApiResult r;
            {
                std::lock_guard<std::mutex> lock(st->mutex);
                r = list_result();
            }
            done(std::move(r));
        });
    };
    auto write = [st, &engine](bool add, std::uint32_t tg, int slot, services::BmApiDone done) {
        engine.post_after(400ms, [st, add, tg, slot, done = std::move(done)]() {
            services::BmApiResult r;
            {
                std::lock_guard<std::mutex> lock(st->mutex);
                auto& g = st->static_groups;
                if (add) {
                    g.push_back({tg, slot});
                } else {
                    g.erase(std::remove_if(g.begin(), g.end(), [&](const auto& x) { return x.talkgroup == tg && x.slot == slot; }),
                            g.end());
                }
                r.groups = g;
            }
            r.groups_valid = true;
            r.message = "BM 已接受静态组更改，读取列表已确认。";
            done(std::move(r));
        });
    };
    sv.bm_api.add_static_group = [write](std::uint32_t, std::string, std::uint32_t tg, int slot, services::BmApiDone done) {
        write(true, tg, slot, std::move(done));
    };
    sv.bm_api.remove_static_group = [write](std::uint32_t, std::string, std::uint32_t tg, int slot, services::BmApiDone done) {
        write(false, tg, slot, std::move(done));
    };

    // RadioID：模拟查询（kCallers 中未命中的 ID 返回演示呼号）。
    sv.identity.lookup = [&engine](std::uint32_t id, services::IdentityDone done) {
        engine.post_after(700ms, [id, done = std::move(done)]() {
            services::IdentityResult r{id, true, std::nullopt};
            if (id == 4609004U) r.callsign = "BY0QRY";
            done(r);
        });
    };
    return sv;
}

} // namespace wirex::gui
