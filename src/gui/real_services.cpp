#include "real_services.hpp"

#include "config_bridge.hpp"
#include "dev_log.hpp"
#include "cat_state_sync.hpp"

#include "wirex/app/bm_api.hpp"
#include "wirex/app/config.hpp"
#include "wirex/app/devices.hpp"
#include "wirex/app/radio_cat.hpp"
#include "wirex/app/radio_identity.hpp"
#include "wirex/app/radio_info.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

namespace wirex::gui {
namespace {

namespace fs = std::filesystem;
using engine::CommandResult;
using engine::CommandStatus;
using steady = std::chrono::steady_clock;
using namespace std::chrono_literals;

std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string out(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring out(static_cast<std::size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

void wipe(std::string& secret) noexcept {
    if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
    secret.clear();
}

CommandResult make_result(CommandStatus status, std::string detail = {}) {
    CommandResult r;
    r.status = status;
    r.detail = std::move(detail);
    return r;
}

// 单线程任务队列：任务按投递顺序串行执行；stop() 丢弃未执行任务并等待当前任务结束。
class TaskThread final {
public:
    TaskThread() : thread_([this]() { loop(); }) {}
    ~TaskThread() { stop(); }
    TaskThread(const TaskThread&) = delete;
    TaskThread& operator=(const TaskThread&) = delete;

    bool post(std::function<void()> task) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_ || queue_.size() >= 64U) return false;
            queue_.push_back(std::move(task));
        }
        wake_.notify_one();
        return true;
    }

    void stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
            queue_.clear();
        }
        wake_.notify_all();
        if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
    }

private:
    void loop() {
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                wake_.wait(lock, [this]() { return stopping_ || !queue_.empty(); });
                if (stopping_) return;
                task = std::move(queue_.front());
                queue_.pop_front();
            }
            try {
                task();
            } catch (...) {
                // 任务自身负责报告错误；这里只保证线程不因异常退出。
            }
        }
    }

    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<std::function<void()>> queue_;
    bool stopping_{};
    std::thread thread_; // 最后声明：其它成员先构造
};

// ---------------------------------------------------------------- 配置与设备

struct ConfigState {
    std::mutex mutex;
    fs::path path;
    fs::path exe_directory;
    bool lenient{};
    std::optional<app::AppConfig> base;        // 最近一次成功读取/保存的完整配置（含未知字段）
    app::devices::SerialCatalog last_serial;   // 最近一次串口枚举（CAT 的 HRI 冲突判断）
};

// --fake：真实检查未通过时给模拟引擎的最小启动参数。
engine::StartConfig lenient_start_config(const services::GuiConfig& gui) {
    engine::StartConfig sc;
    sc.hri_port = gui.hri_port.empty() ? std::wstring(L"COM5") : gui.hri_port;
    sc.audio.expected_wave_in_endpoint_id = gui.wave_in_endpoint_id;
    sc.audio.expected_wave_out_endpoint_id = gui.wave_out_endpoint_id;
    sc.bm.master_host = gui.master_host;
    sc.bm.master_port = gui.master_port;
    sc.bm.profile.gateway_id = services::effective_gateway_id(gui);
    sc.bm.profile.callsign = gui.callsign;
    sc.bm.profile.password = gui.bm_password;
    sc.local_source_id = gui.dmr_id;
    sc.rx_policy = config_bridge::make_rx_policy(gui.channels, {}, gui.dmr_id, gui.blocked_source_ids);
    if (gui.tx_target) {
        sc.tx_policy.target = *gui.tx_target;
        sc.tx_policy.transmit_enabled = true;
    }
    return sc;
}

services::ConfigService make_config_service(const std::shared_ptr<ConfigState>& st) {
    services::ConfigService svc;
    svc.load = [st](std::string& error) -> std::optional<services::GuiConfig> {
        // Initialize-PortableConfig：不存在时原子写入默认配置；存在时只校验，不改写。
        auto loaded = app::create_default(st->path);
        std::lock_guard<std::mutex> lock(st->mutex);
        if (!loaded) {
            error = loaded.error().message;
            st->base.reset();
            return std::nullopt;
        }
        st->base = loaded.value();
        return config_bridge::to_gui(*st->base);
    };
    svc.save = [st](const services::GuiConfig& gui, std::string& error) {
        std::lock_guard<std::mutex> lock(st->mutex);
        if (!st->base) {
            error = "config.json 尚未成功读取；为避免覆盖原文件，没有写入。";
            return false;
        }
        auto next = config_bridge::apply_gui(*st->base, gui, error);
        if (!next) return false;
        auto saved = app::save(st->path, *next);
        if (!saved) {
            error = saved.error().message;
            return false;
        }
        st->base = std::move(saved).value();
        return true;
    };
    svc.make_start_config = [st](const services::GuiConfig& gui, std::string& error) -> std::optional<engine::StartConfig> {
        config_bridge::StartInputs inputs;
        bool lenient = false;
        {
            std::lock_guard<std::mutex> lock(st->mutex);
            if (st->base) inputs.color_code = st->base->connection.color_code;
            lenient = st->lenient;
        }
        std::optional<engine::StartConfig> sc;
        inputs.serial = app::devices::enumerate_serial_ports();
        {
            std::lock_guard<std::mutex> lock(st->mutex);
            st->last_serial = inputs.serial;
        }
        auto audio = app::devices::enumerate_audio();
        inputs.wave_inputs = std::move(audio.wave_inputs);
        inputs.wave_outputs = std::move(audio.wave_outputs);
        sc = config_bridge::make_start_config(gui, inputs, error);
        if (!sc && lenient) {
            // 返回参数并保留 error：ViewModel 把它作为提示显示。
            error = "模拟引擎：真实启动检查未通过（" + error + "）";
            return lenient_start_config(gui);
        }
        return sc;
    };
    svc.make_runtime_config = [st](const services::GuiConfig& gui, std::string& error) -> std::optional<engine::StartConfig> {
        std::uint8_t color_code = 1U;
        {
            std::lock_guard<std::mutex> lock(st->mutex);
            if (st->base) color_code = st->base->connection.color_code;
        }
        auto runtime = config_bridge::make_runtime_config(gui, color_code, error);
        if (runtime) {
            if (auto log = dev_log()) log->attach(runtime->diagnostics, "engine");
        } else if (auto log = dev_log()) {
            log->line("gui", "runtime config rejected: " + error);
        }
        return runtime;
    };
    return svc;
}

services::DeviceService make_device_service(const std::shared_ptr<ConfigState>& st) {
    services::DeviceService svc;
    svc.enumerate = [st]() {
        services::DeviceInventory inv;
        auto serial = app::devices::enumerate_serial_ports();
        inv.serial_discovery_status = serial.discovery_status;
        for (const auto& p : serial.serial_ports) {
            std::string caption = p.port_name;
            if (!p.friendly_name.empty()) caption += " · " + p.friendly_name;
            if (p.is_hri) caption += " · HRI";
            inv.serial_ports.push_back({widen(p.port_name), std::move(caption), p.is_hri,
                                        p.is_cat_candidate, p.cat_match_rank, p.cat_match_reason});
        }
        {
            std::lock_guard<std::mutex> lock(st->mutex);
            st->last_serial = std::move(serial);
        }
        // Get-UiEndpointOptions：只列 48 kHz 单声道可用且有 endpoint ID 的 WinMM 设备；名称用 MMDevice 全名。
        const auto audio = app::devices::enumerate_audio();
        const auto add = [](const std::vector<app::devices::WaveDevice>& waves,
                            const std::vector<app::devices::AudioEndpoint>& endpoints,
                            std::vector<services::AudioEndpointInfo>& out) {
            for (const auto& w : waves) {
                if (!app::devices::usable(w)) continue;
                std::string name = w.name;
                for (const auto& e : endpoints) {
                    if (_stricmp(e.endpoint_id.c_str(), w.endpoint_id->c_str()) == 0 && !e.friendly_name.empty()) {
                        name = e.friendly_name;
                    }
                }
                out.push_back({widen(*w.endpoint_id), std::move(name), w.id,
                               app::devices::is_usb_audio_name(w.name)});
            }
        };
        add(audio.wave_inputs, audio.capture_endpoints, inv.wave_in);
        add(audio.wave_outputs, audio.render_endpoints, inv.wave_out);
        return inv;
    };
    return svc;
}

// ---------------------------------------------------------------- CAT

app::CatMode to_app_mode(services::CatMode mode) {
    switch (mode) {
    case services::CatMode::fm: return app::CatMode::fm;
    case services::CatMode::fm_n: return app::CatMode::fm_n;
    case services::CatMode::c4fm_dn: return app::CatMode::c4fm_dn;
    case services::CatMode::c4fm_vw: return app::CatMode::c4fm_vw;
    }
    return app::CatMode::fm;
}

CommandResult to_command_result(const app::CatResult& r) {
    switch (r.status) {
    case app::CatResultStatus::confirmed: return make_result(CommandStatus::accepted);
    case app::CatResultStatus::busy: return make_result(CommandStatus::busy, r.error_message);
    case app::CatResultStatus::identity_mismatch: return make_result(CommandStatus::forbidden, r.error_message);
    case app::CatResultStatus::rejected:
        switch (r.error) {
        case app::CatError::write_not_authorized:
        case app::CatError::hri_port_conflict: return make_result(CommandStatus::forbidden, r.error_message);
        case app::CatError::invalid_request:
        case app::CatError::power_out_of_range:
        case app::CatError::frequency_out_of_range: return make_result(CommandStatus::invalid, r.error_message);
        default: return make_result(CommandStatus::failed, r.error_message);
        }
    case app::CatResultStatus::mismatch:
    case app::CatResultStatus::unknown: break;
    }
    return make_result(CommandStatus::failed, r.error_message.empty() ? std::string(app::to_string(r.error)) : r.error_message);
}

// 核心门控输入（R131）：引擎常驻，只按发射中 / HRI 下行播放中门控，见 app::CatCoreState。
app::CatCoreState core_state_from(const std::shared_ptr<const engine::Snapshot>& s) {
    app::CatCoreState c;
    if (!s) return c;
    using talkgroup_routing::MediaOwner;
    c.transmitting = s->tx_active || s->relay_fm_active || s->media_owner == MediaOwner::tx_active ||
                     s->media_owner == MediaOwner::tx_draining;
    const bool rx_media = s->media_owner == MediaOwner::rx_active || s->media_owner == MediaOwner::rx_draining ||
                          s->media_owner == MediaOwner::rx_stopping;
    c.hri_downlink_active = s->hri_ready && rx_media;
    return c;
}

// R131 诊断：CatWorker 的每个会话（连接查询、1 s 周期查询、Apply 写入与读回）逐帧写入 dev 日志，
// 例如 "TX COM7 PC2005;" / "RX COM7 PC2025;"。CAT 帧不含凭据。100 ms 静噪采样（RI0;/SM0;）不记录，避免刷屏。
app::CatClient make_traced_cat_client() {
    return app::CatClient(app::make_traced_cat_transport_factory(
        app::make_win32_cat_transport, [](bool tx, std::string_view frame, std::string_view port) {
            if (auto log = dev_log()) {
                std::string line(tx ? "TX " : "RX ");
                line.append(port);
                line.push_back(' ');
                line.append(frame);
                log->line("cat-frame", line);
            }
        }));
}

class CatRunner final {
public:
    CatRunner(EngineApi& engine, std::shared_ptr<ConfigState> config)
        : config_(std::move(config)),
          worker_(make_traced_cat_client(), [e = &engine]() { return core_state_from(e->snapshot()); }),
          thread_([this]() { loop(); }) {}

    ~CatRunner() { stop(); }
    CatRunner(const CatRunner&) = delete;
    CatRunner& operator=(const CatRunner&) = delete;

    void stop() {
        std::deque<Task> canceled;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) return;
            stopping_ = true;
            ++task_generation_;
            canceled.swap(tasks_);
            state_.connected = false;
            state_.busy = false;
            connection_.reset();
            (void)cat_state_sync::invalidate_observation(state_);
            ++state_.revision;
            (void)reset_squelch_locked("cat_disconnected"); // 关闭服务：ViewModel 正在析构，不再回调
            squelch_callback_ = {};
        }
        squelch_cancel_.store(true);
        worker_.disconnect(); // 取消进行中的串口操作，解除 runner 对 future 的等待
        wake_.notify_all();
        if (thread_.joinable()) thread_.join();
        for (auto& task : canceled) {
            if (task.on_cancel) task.on_cancel(make_result(CommandStatus::not_ready, "CAT 操作已停止。"));
        }
    }

    void set_wakeup(std::function<void()> wakeup) {
        std::lock_guard<std::mutex> lock(mutex_);
        wakeup_ = std::move(wakeup);
    }

    services::CatState state() {
        std::lock_guard<std::mutex> lock(mutex_);
        return state_;
    }

    void connect(std::wstring port, std::uint32_t baud, services::Done done) {
        post([this, port = std::move(port), baud, done](std::uint64_t generation) {
            do_connect(port, baud, done, generation);
        }, done);
    }

    void disconnect(services::Done done) {
        std::deque<Task> canceled;
        std::optional<services::SquelchEvent> squelch_closed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++task_generation_;
            canceled.swap(tasks_);
            state_.connected = false;
            state_.busy = false;
            state_.error.clear();
            connection_.reset();
            (void)cat_state_sync::invalidate_observation(state_);
            ++state_.revision;
            squelch_closed = reset_squelch_locked("cat_disconnected");
        }
        squelch_cancel_.store(true);
        worker_.disconnect();
        emit_squelch(squelch_closed);
        notify();
        for (auto& task : canceled) {
            if (task.on_cancel) task.on_cancel(make_result(CommandStatus::not_ready, "CAT 连接请求已取消。"));
        }
        if (done) done(make_result(CommandStatus::accepted));
    }

    void apply(services::CatSettings settings, services::Done done) {
        post([this, settings, done](std::uint64_t generation) {
            do_apply(settings, done, generation);
        }, done);
    }

    void query(services::Done done) {
        post([this, done](std::uint64_t generation) {
            std::optional<app::CatConnection> conn;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                conn = connection_;
            }
            if (!conn) {
                finish(generation, done, make_result(CommandStatus::not_ready, "CAT 未连接。"), [](services::CatState&) {});
                return;
            }
            app::CatJob job;
            job.connection = *conn;
            job.operation = app::CatOperation::query;
            const auto r = run(job, generation);
            absorb_observed(r);
            finish(generation, done, to_command_result(r), [&](services::CatState& s) {
                s.error = r.status == app::CatResultStatus::confirmed ? std::string{} : r.error_message;
            });
        }, done);
    }

    // R130：中继与 FM 都开启且 CAT 已连接时每 100 ms 只读采样 RI0;/SM0;。关闭时门控 reset 并在开门状态下发 closed。
    void set_squelch_polling(bool enabled) {
        std::optional<services::SquelchEvent> closed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (squelch_enabled_ == enabled) return;
            squelch_enabled_ = enabled;
            if (!enabled) closed = reset_squelch_locked("polling_disabled");
            next_squelch_ = steady::now();
        }
        if (auto log = dev_log()) log->line("cat", std::string("squelch polling ") + (enabled ? "on" : "off"));
        emit_squelch(closed);
        wake_.notify_all();
    }

    void set_squelch_callback(services::SquelchCallback callback) {
        std::lock_guard<std::mutex> lock(mutex_);
        squelch_callback_ = std::move(callback);
    }

private:
    static constexpr auto squelch_period = 100ms;
    static constexpr std::chrono::milliseconds squelch_session_timeout{400};

    // 调用方持有 mutex_。门处于开启状态时返回待发送的 closed 事件。
    std::optional<services::SquelchEvent> reset_squelch_locked(const char* reason) {
        const bool was_open = gate_.open();
        gate_.reset();
        const auto peak = squelch_peak_;
        squelch_peak_.reset();
        last_squelch_info_.reset();
        if (!was_open) return std::nullopt;
        services::SquelchEvent e;
        e.edge = services::SquelchEdge::closed;
        e.at = steady::now();
        e.s_meter_peak = peak;
        e.reason = reason;
        return e;
    }

    void emit_squelch(const std::optional<services::SquelchEvent>& event) {
        if (!event) return;
        services::SquelchCallback callback;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            callback = squelch_callback_;
        }
        if (auto log = dev_log()) {
            const char* edge = event->edge == services::SquelchEdge::opened ? "squelch opened"
                             : event->edge == services::SquelchEdge::muted ? "squelch muted"
                             : event->edge == services::SquelchEdge::unmuted ? "squelch unmuted" : "squelch closed";
            std::string line = edge;
            if (event->s_meter) line += " s=" + std::to_string(*event->s_meter);
            if (event->s_meter_peak) line += " s_peak=" + std::to_string(*event->s_meter_peak);
            if (!event->reason.empty()) line += " reason=" + event->reason;
            log->line("cat", line);
        }
        if (!callback) return;
        try { callback(*event); } catch (...) { /* 回调错误不影响 CAT 线程 */ }
    }

    // 一次 100 ms 静噪采样：只读短会话（RI0;/SM0;），结果交给 SquelchGate。不经过 CatWorker，
    // 因而不改变写授权或观测值；与 worker 任务串行（同一 runner 线程等待 worker 的 future）。
    void squelch_sample(std::uint64_t generation) {
        std::optional<app::CatConnection> conn;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation != task_generation_ || stopping_ || !squelch_enabled_) return;
            conn = connection_;
            next_squelch_ = steady::now() + squelch_period;
            squelch_cancel_.store(false);
        }
        if (!conn) return;
        conn->timeout = squelch_session_timeout;
        const auto sample = squelch_client_.query_squelch(*conn, &squelch_cancel_);
        const auto now = steady::now();
        std::optional<app::radio_info::RadioInfo> info;
        if (sample.error == app::CatError::none) info = app::radio_info::parse(sample.ri_frame);
        std::optional<services::SquelchEvent> event;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation != task_generation_ || stopping_ || !squelch_enabled_ || !connection_) return;
            const bool was_open = gate_.open();
            const auto edge = gate_.sample(info, now);
            if (info) last_squelch_info_ = info;
            if (gate_.open() && sample.s_meter) {
                squelch_peak_ = squelch_peak_ ? std::max(*squelch_peak_, *sample.s_meter) : *sample.s_meter;
            }
            if (edge == app::radio_info::GateEvent::opened) {
                services::SquelchEvent e;
                e.edge = services::SquelchEdge::opened;
                e.at = now;
                e.s_meter = sample.s_meter;
                squelch_peak_ = sample.s_meter;
                event = e;
            } else if (edge == app::radio_info::GateEvent::muted || edge == app::radio_info::GateEvent::unmuted) {
                services::SquelchEvent e;
                e.edge = edge == app::radio_info::GateEvent::muted ? services::SquelchEdge::muted
                                                                   : services::SquelchEdge::unmuted;
                e.at = now;
                e.s_meter = sample.s_meter;
                event = e;
            } else if (edge == app::radio_info::GateEvent::closed && was_open) {
                services::SquelchEvent e;
                e.edge = services::SquelchEdge::closed;
                e.at = now;
                e.s_meter = sample.s_meter;
                e.s_meter_peak = squelch_peak_;
                e.reason = !info ? "stale" : (info->tx != app::radio_info::TxState::rx ? "radio_tx" : "squelch");
                squelch_peak_.reset();
                event = e;
            }
        }
        emit_squelch(event);
    }

    struct Task {
        std::uint64_t generation{};
        std::function<void(std::uint64_t)> run{};
        services::Done on_cancel{};
    };

    void post(std::function<void(std::uint64_t)> task, const services::Done& done) {
        bool accepted = false;
        bool stopped = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopped = stopping_;
            if (!stopping_ && !state_.busy && tasks_.empty()) {
                tasks_.push_back(Task{task_generation_, std::move(task), done});
                state_.busy = true;
                ++state_.revision;
                accepted = true;
            }
        }
        if (!accepted) {
            if (done) done(make_result(stopped ? CommandStatus::not_ready : CommandStatus::busy,
                                       stopped ? "CAT 服务已停止。" : "CAT 操作正在进行。"));
            return;
        }
        wake_.notify_one();
        notify();
    }

    template <class F>
    void update(F&& mutate) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            mutate(state_);
            ++state_.revision;
        }
        notify();
    }

    void notify() {
        std::function<void()> wakeup;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            wakeup = wakeup_;
        }
        if (wakeup) wakeup();
    }

    // 只接收本次 CAT 任务可信的新读回；失败查询保留旧读数和错误状态，不制造新鲜序号。
    void absorb_observed(const app::CatResult& result) {
        const auto snap = worker_.snapshot();
        if (result.status == app::CatResultStatus::identity_mismatch) {
            update([&](services::CatState& s) {
                (void)cat_state_sync::apply(s, result, snap.observed);
            });
            std::optional<services::SquelchEvent> closed;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                closed = reset_squelch_locked("identity_mismatch");
            }
            emit_squelch(closed);
            return;
        }
        if (!cat_state_sync::may_adopt_observation(result) || !cat_state_sync::has_observation(result.observed)) return;
        update([&](services::CatState& s) {
            (void)cat_state_sync::apply(s, result, snap.observed);
        });
    }

    std::optional<app::CatConnection> make_connection(const std::wstring& port, std::uint32_t baud, std::string& error) {
        app::CatConnection c;
        c.baud_rate = baud;
        c.stop_bits = app::CatStopBits::two;
        if (!app::cat_is_supported_baud_rate(baud)) {
            error = "CAT 波特率无效。";
            return std::nullopt;
        }

        // 使用一次新枚举，再按设备目录的唯一分类结果选择 CAT；Auto 不会尝试打开未分类端口。
        const auto catalog = app::devices::enumerate_serial_ports();
        std::string saved_hri = "auto";
        std::string saved_cat = "auto";
        {
            std::lock_guard<std::mutex> lock(config_->mutex);
            config_->last_serial = catalog;
            if (config_->base) {
                saved_hri = config_->base->devices.hri_port;
                saved_cat = config_->base->devices.cat_port;
            }
        }
        std::string requested = narrow(port);
        const bool automatic = requested.empty() || requested == "auto" || requested == "AUTO";
        app::devices::PortSelectionError selection_error{};
        const auto selection = app::devices::resolve_port_selection(catalog, saved_hri, saved_cat,
            automatic ? std::string_view{} : std::string_view(requested), selection_error);
        if (selection_error != app::devices::PortSelectionError::none) {
            error = "CAT 串口名称无效；请选择 COM1 到 COM999。";
            return std::nullopt;
        }
        if (!selection.cat_port) {
            error = selection.cat_conflict ? selection.cat_match_reason
                : "没有唯一且未与 HRI 冲突的 CAT 串口；请在 CAT 端口中明确选择。";
            return std::nullopt;
        }
        c.port_name = widen(*selection.cat_port);
        if (selection.hri_port) c.hri_port_name = widen(*selection.hri_port);
        return c;
    }

    app::CatResult canceled(const app::CatJob& job) const {
        app::CatResult result;
        result.operation = job.operation;
        result.port_name = job.connection.port_name;
        result.started_at = std::chrono::system_clock::now();
        result.status = app::CatResultStatus::unknown;
        result.error = app::CatError::cancelled;
        result.error_message = "CAT 会话已断开或取消；没有执行该操作。";
        return result;
    }

    app::CatResult run(const app::CatJob& job, std::uint64_t generation) {
        std::future<app::CatResult> future;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_ || generation != task_generation_) return canceled(job);
            future = worker_.submit(job);
        }
        auto result = future.get();
        if (auto log = dev_log()) {
            const char* op = job.operation == app::CatOperation::query ? "query"
                           : job.operation == app::CatOperation::set_power ? "set_power"
                           : job.operation == app::CatOperation::set_frequency ? "set_frequency" : "set_mode";
            std::string line = std::string("op=") + op;
            if (job.operation == app::CatOperation::set_power) line += " watts=" + std::to_string(job.power_watts);
            if (job.operation == app::CatOperation::set_frequency) line += " hz=" + std::to_string(job.frequency_hz);
            line += " status=" + std::string(app::to_string(result.status)) +
                    " error=" + std::string(app::to_string(result.error));
            if (result.observed.power) line += " observed_power_w=" + std::to_string(result.observed.power->value.watts);
            log->line("cat-op", line);
        }
        return result;
    }

    void do_connect(const std::wstring& port, std::uint32_t baud, const services::Done& done,
                    std::uint64_t generation) {
        std::string error;
        const auto conn = make_connection(port, baud, error);
        if (!conn) {
            finish(generation, done, make_result(CommandStatus::invalid, error),
                   [&](services::CatState& s) { s.error = error; });
            return;
        }
        app::CatJob job;
        job.operation = app::CatOperation::query;
        job.connection = *conn;
        const auto r = run(job, generation);
        absorb_observed(r);
        bool ok = r.status == app::CatResultStatus::confirmed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation == task_generation_ && !stopping_) {
                if (ok) connection_ = conn;
                last_poll_ = steady::now();
            } else {
                ok = false;
            }
        }
        finish(generation, done, ok ? to_command_result(r) : make_result(CommandStatus::not_ready, "CAT 连接已取消。"), [&](services::CatState& s) {
            s.connected = ok;
            s.port = conn->port_name;
            s.baud_rate = baud;
            s.error = ok ? std::string{} : r.error_message;
        });
    }

    // Apply-UiRadioCatSettings：先读取一次，再按 模式 → 频率 → 功率 顺序只写有变化的项；每步读回确认，失败即停止。
    void do_apply(const services::CatSettings& settings, const services::Done& done, std::uint64_t generation) {
        std::optional<app::CatConnection> conn;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            conn = connection_;
        }
        if (!conn) {
            finish(generation, done, make_result(CommandStatus::not_ready, "CAT 未连接。"), [](services::CatState&) {});
            return;
        }
        if (settings.main_frequency_hz != 0U && (settings.main_frequency_hz < app::cat_min_frequency_hz ||
                                                 settings.main_frequency_hz > app::cat_max_frequency_hz)) {
            finish(generation, done, make_result(CommandStatus::invalid, "频率超出 FTX-1 CAT 允许范围。"), [](services::CatState&) {});
            return;
        }
        app::CatJob job;
        job.connection = *conn;
        job.operation = app::CatOperation::query;
        auto r = run(job, generation);
        absorb_observed(r);
        if (r.status != app::CatResultStatus::confirmed) {
            finish(generation, done, to_command_result(r), [&](services::CatState& s) { s.error = r.error_message; });
            return;
        }
        const auto observed = worker_.snapshot().observed;
        int steps = 0;
        const auto step = [&](app::CatJob next) {
            next.connection = *conn;
            r = run(next, generation);
            absorb_observed(r);
            ++steps;
            return r.status == app::CatResultStatus::confirmed;
        };
        bool ok = true;
        const auto mode = to_app_mode(settings.main_mode);
        if (settings.apply_mode && (!observed.main_mode || observed.main_mode->value.mode != mode)) {
            app::CatJob j;
            j.operation = app::CatOperation::set_mode;
            j.side = app::CatSide::main;
            j.mode = mode;
            ok = step(j);
        }
        const auto hz = static_cast<std::uint32_t>(settings.main_frequency_hz);
        if (ok && hz != 0U && (!observed.main_frequency_hz || observed.main_frequency_hz->value != hz)) {
            app::CatJob j;
            j.operation = app::CatOperation::set_frequency;
            j.frequency_hz = hz;
            ok = step(j);
        }
        const int watts = static_cast<int>(settings.power_w);
        if (ok && watts != 0 && (!observed.power || observed.power->value.watts != watts)) {
            app::CatJob j;
            j.operation = app::CatOperation::set_power;
            j.power_watts = watts;
            ok = step(j);
        }
        if (!ok) {
            auto cr = to_command_result(r);
            // 门控（软件侧）在 busy 中带 gate_* 机器码，供 ViewModel 保留草稿并在门控解除后重试。
            if (r.error == app::CatError::gate_transmitting || r.error == app::CatError::busy) {
                cr.detail = "cat_gate_transmitting"; // busy 只来自电台 TX; 非 0
            }
            if (r.error == app::CatError::gate_hri_downlink) cr.detail = "cat_gate_hri_downlink";
            // 电台自己拒绝（?; 或读回不符）：如实说明，不归咎于软件门控。
            if (r.operation == app::CatOperation::set_frequency &&
                (r.error == app::CatError::radio_rejected_command || r.error == app::CatError::readback_mismatch)) {
                cr.status = CommandStatus::failed;
                cr.detail = "电台拒绝修改频率（可能处于 HRI/WIRES-X 模式）。";
            } else if (r.operation == app::CatOperation::set_mode &&
                       (r.error == app::CatError::radio_rejected_command || r.error == app::CatError::readback_mismatch)) {
                cr.status = CommandStatus::failed;
                cr.detail = "电台拒绝修改模式（可能处于 HRI/WIRES-X 模式）。";
            }
            if (steps > 1) cr.detail += "（已完成的步骤不回滚）";
            finish(generation, done, cr, [&](services::CatState& s) { s.error = r.error_message; });
            return;
        }
        finish(generation, done, make_result(steps == 0 ? CommandStatus::idempotent : CommandStatus::accepted),
               [](services::CatState& s) { s.error.clear(); });
    }

    template <class F>
    void finish(std::uint64_t generation, const services::Done& done, const CommandResult& result, F&& mutate) {
        bool changed = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation == task_generation_ && !stopping_) {
                mutate(state_);
                state_.busy = false;
                ++state_.revision;
                changed = true;
            }
        }
        if (changed) notify();
        if (done) {
            try { done(result); } catch (...) { /* 回调错误不影响 CAT 状态机 */ }
        }
    }

    // 连接后每秒只读查询一次（RadioCatUi.ps1 轮询 1000 ms）；用户操作进行中时跳过。
    void poll(std::uint64_t generation) {
        std::optional<app::CatConnection> conn;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation != task_generation_ || stopping_) return;
            conn = connection_;
            last_poll_ = steady::now();
        }
        if (!conn) return;
        app::CatJob job;
        job.operation = app::CatOperation::query;
        job.connection = *conn;
        const auto r = run(job, generation);
        absorb_observed(r);
        std::lock_guard<std::mutex> lock(mutex_);
        if (!connection_ || generation != task_generation_ || stopping_) return; // 期间已断开
        const std::string error = r.status == app::CatResultStatus::confirmed ? std::string{} : r.error_message;
        if (state_.error != error) {
            state_.error = error;
            ++state_.revision;
        }
    }

    void loop() {
        for (;;) {
            Task task;
            bool do_poll = false;
            bool do_squelch = false;
            std::uint64_t poll_generation = 0U;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                // 静噪轮询开启时缩短等待，保证约 100 ms 一次采样；其它查询仍为 1 s。
                const auto wait = squelch_enabled_ && connection_ ? 20ms : 250ms;
                wake_.wait_for(lock, wait, [this]() { return stopping_ || !tasks_.empty(); });
                if (stopping_) return;
                const auto now = steady::now();
                if (!tasks_.empty()) {
                    task = std::move(tasks_.front());
                    tasks_.pop_front();
                } else if (connection_ && now - last_poll_ >= 1s) {
                    do_poll = true;
                    poll_generation = task_generation_;
                } else if (connection_ && squelch_enabled_ && !state_.busy && now >= next_squelch_) {
                    do_squelch = true;
                    poll_generation = task_generation_;
                }
            }
            try {
                if (task.run) task.run(task.generation);
                if (do_poll) {
                    poll(poll_generation);
                    notify();
                }
                if (do_squelch) squelch_sample(poll_generation);
            } catch (...) {
                if (task.run) {
                    finish(task.generation, task.on_cancel, make_result(CommandStatus::failed, "CAT 内部错误。"),
                           [](services::CatState& s) { s.error = "CAT 内部错误。"; });
                } else if (do_poll) {
                    bool changed = false;
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        if (poll_generation == task_generation_ && !stopping_) {
                            state_.error = "CAT 内部错误。";
                            ++state_.revision;
                            changed = true;
                        }
                    }
                    if (changed) notify();
                }
            }
        }
    }

    std::shared_ptr<ConfigState> config_;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Task> tasks_;
    std::uint64_t task_generation_{};
    bool stopping_{};
    services::CatState state_{};
    std::optional<app::CatConnection> connection_{};
    steady::time_point last_poll_{};
    std::function<void()> wakeup_{};
    // R130 静噪轮询（mutex_ 保护）
    bool squelch_enabled_{};
    services::SquelchCallback squelch_callback_{};
    app::radio_info::SquelchGate gate_{};
    steady::time_point next_squelch_{};
    std::optional<unsigned> squelch_peak_{};
    std::optional<app::radio_info::RadioInfo> last_squelch_info_{};
    std::atomic<bool> squelch_cancel_{false};
    app::CatClient squelch_client_{};
    app::CatWorker worker_;
    std::thread thread_; // 最后声明
};

// ---------------------------------------------------------------- BM API

std::string bm_error_text(const app::bm_api::Error& e, bool write) {
    using app::bm_api::ErrorKind;
    switch (e.kind) {
    case ErrorKind::canceled: return write ? "静态组写入结果未确认；请刷新列表后再操作。" : "BM 静态组读取已取消。";
    case ErrorKind::timeout: return "BM API 操作超时；请刷新列表确认服务器状态。";
    case ErrorKind::invalid_key:
    case ErrorKind::invalid_request: return e.message.empty() ? "BM API 参数无效。" : e.message;
    default: return "BM API 操作失败；请检查 API Key 与网络后刷新。";
    }
}

std::vector<services::StaticGroup> to_gui_groups(const std::vector<app::bm_api::StaticGroup>& groups) {
    std::vector<services::StaticGroup> out;
    for (const auto& g : groups) out.push_back({g.talkgroup, g.slot});
    return out;
}

class BmApiRunner final {
public:
    void list(std::uint32_t device_id, std::string api_key, services::BmApiDone done) {
        post(std::move(api_key), done, [this, device_id, done](const app::bm_api::ApiKey& key) {
            const std::string dev = std::to_string(device_id);
            services::BmApiResult out;
            const auto listed = client_.list_static_groups(key, dev, app::bm_api::default_timeout_ms, &cancel_);
            if (listed.error) {
                out.failed = true;
                out.message = bm_error_text(listed.error, false);
                done(std::move(out));
                return;
            }
            out.groups = to_gui_groups(listed.groups);
            out.groups_valid = true;
            const auto ctx = client_.get_add_context(key, dev, app::bm_api::default_timeout_ms, &cancel_);
            if (!ctx.error && ctx.context.success) {
                out.add_slot = ctx.context.add_slot;
                out.device_status = ctx.context.status;
            }
            const std::string status = out.device_status ? std::to_string(*out.device_status) : std::string("未知");
            out.message = "已读取 " + std::to_string(out.groups.size()) + " 条 BM 静态组；设备状态 " + status +
                          (out.add_slot ? "。" : "，添加已禁用。");
            done(std::move(out));
        });
    }

    void write(bool add, std::uint32_t device_id, std::string api_key, std::uint32_t talkgroup, int slot,
               services::BmApiDone done) {
        post(std::move(api_key), done, [this, add, device_id, talkgroup, slot, done](const app::bm_api::ApiKey& key) {
            const std::string dev = std::to_string(device_id);
            const auto r = add ? client_.add_static_group(key, dev, talkgroup, slot, app::bm_api::default_timeout_ms, &cancel_)
                               : client_.remove_static_group(key, dev, talkgroup, slot, app::bm_api::default_timeout_ms, &cancel_);
            services::BmApiResult out;
            if (r.error) {
                out.failed = true;
                out.message = bm_error_text(r.error, true);
                done(std::move(out));
                return;
            }
            using app::bm_api::ReadbackStatus;
            out.groups_valid = r.readback_status == ReadbackStatus::confirmed || r.readback_status == ReadbackStatus::not_confirmed;
            out.groups = to_gui_groups(r.groups);
            switch (r.readback_status) {
            case ReadbackStatus::confirmed: out.message = "BM 已接受静态组更改，读取列表已确认。"; break;
            case ReadbackStatus::not_confirmed:
                out.failed = true;
                out.message = "BM 已接受静态组更改，但读取结果与请求不符；请检查列表。";
                break;
            default:
                out.failed = true;
                out.message = "BM 已接受静态组更改，但回查未完成；请刷新确认。";
                break;
            }
            done(std::move(out));
        });
    }

    void stop() {
        cancel_.store(true);
        thread_.stop();
    }

private:
    template <class F>
    void post(std::string api_key, const services::BmApiDone& done, F&& body) {
        auto key_holder = std::make_shared<std::string>(std::move(api_key));
        const bool queued = thread_.post([key_holder, done, body = std::forward<F>(body)]() {
            app::bm_api::Error key_error;
            auto key = app::bm_api::ApiKey::from_text(*key_holder, &key_error);
            wipe(*key_holder);
            if (!key) {
                services::BmApiResult out;
                out.failed = true;
                out.message = key_error.message.empty() ? "BM API Key 格式无效。" : key_error.message;
                done(std::move(out));
                return;
            }
            body(*key);
        });
        if (!queued) {
            wipe(*key_holder);
            services::BmApiResult out;
            out.failed = true;
            out.message = "BM 静态组后台操作未能启动。";
            done(std::move(out));
        }
    }

    app::bm_api::Client client_{};
    std::atomic<bool> cancel_{false};
    TaskThread thread_; // 最后声明
};

// ---------------------------------------------------------------- RadioID

// Start-UiIdentityQuery / Start-NextUiIdentityQuery：队列上限 16、同 ID 合并、单并发、两次联网至少间隔 1 s、
// 失败冷却 30 s×2^(n−1)（上限 900 s，取消不计）、成功清除冷却；缓存命中（found/not_found）不联网。
class IdentityRunner final {
public:
    explicit IdentityRunner(fs::path cache_path) : cache_(std::move(cache_path)), thread_([this]() { loop(); }) {}
    ~IdentityRunner() { stop(); }
    IdentityRunner(const IdentityRunner&) = delete;
    IdentityRunner& operator=(const IdentityRunner&) = delete;

    std::vector<services::IdentityResult> preload() const {
        std::vector<services::IdentityResult> out;
        for (auto& m : app::radio_identity::native_mappings(cache_, app::radio_identity::cache_entry_limit)) {
            out.push_back({m.source_id, true, std::move(m.callsign)});
        }
        return out;
    }

    void lookup(std::uint32_t id, services::IdentityDone done) {
        if (!app::radio_identity::is_valid_radio_id(id) || !done) return;
        std::optional<services::IdentityResult> memo;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) return;
            if (auto it = memo_.find(id); it != memo_.end()) {
                memo = it->second;
            } else if (auto c = cooldown_.find(id); c != cooldown_.end() && steady::now() < c->second.retry_after) {
                return;
            } else if (auto w = waiters_.find(id); w != waiters_.end()) {
                w->second.push_back(std::move(done));
                return;
            } else {
                if (queue_.size() >= 16U) return; // queue_full
                queue_.push_back(id);
                waiters_[id].push_back(std::move(done));
            }
        }
        if (memo) {
            done(*memo);
            return;
        }
        wake_.notify_one();
    }

    void stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) return;
            stopping_ = true;
            queue_.clear();
            waiters_.clear();
        }
        cancel_.store(true);
        wake_.notify_all();
        if (thread_.joinable()) thread_.join();
    }

private:
    struct Cooldown {
        int failures{};
        steady::time_point retry_after{};
    };

    void deliver(std::uint32_t id, std::optional<services::IdentityResult> result) {
        std::vector<services::IdentityDone> waiters;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (auto it = waiters_.find(id); it != waiters_.end()) {
                waiters = std::move(it->second);
                waiters_.erase(it);
            }
            if (result) {
                if (memo_.size() >= 1024U) memo_.clear();
                memo_[id] = *result;
            }
        }
        if (!result) return;
        for (auto& w : waiters) {
            if (w) w(*result);
        }
    }

    static std::optional<services::IdentityResult> known(const app::radio_identity::Result& r) {
        using app::radio_identity::Status;
        if (r.status != Status::found && r.status != Status::not_found) return std::nullopt;
        services::IdentityResult out{r.id, true, std::nullopt};
        if (r.status == Status::found && r.callsign) out.callsign = app::radio_identity::native_callsign(*r.callsign);
        return out;
    }

    void loop() {
        for (;;) {
            std::uint32_t id = 0U;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                wake_.wait(lock, [this]() { return stopping_ || !queue_.empty(); });
                if (stopping_) return;
                id = queue_.front();
                queue_.pop_front();
            }
            try {
                if (auto cached = known(app::radio_identity::resolve(id, cache_))) {
                    deliver(id, cached);
                    continue;
                }
                {
                    std::unique_lock<std::mutex> lock(mutex_);
                    const auto earliest = last_request_ + 1s;
                    if (wake_.wait_until(lock, earliest, [this]() { return stopping_; })) return;
                    last_request_ = steady::now();
                }
                std::error_code ec;
                fs::create_directories(cache_.parent_path(), ec);
                app::radio_identity::QueryOptions options;
                options.timeout_seconds = 5U;
                options.cancel = &cancel_;
                const auto r = app::radio_identity::query(id, cache_, options);
                const auto result = known(r);
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    if (result) {
                        cooldown_.erase(id);
                    } else if (r.error_code.value_or("") != "cancelled") {
                        auto& c = cooldown_[id];
                        c.failures = std::min(8, c.failures + 1);
                        const auto seconds = std::min(900, 30 * (1 << (c.failures - 1)));
                        c.retry_after = steady::now() + std::chrono::seconds(seconds);
                    }
                }
                deliver(id, result);
            } catch (...) {
                deliver(id, std::nullopt);
            }
        }
    }

    fs::path cache_;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<std::uint32_t> queue_;
    std::map<std::uint32_t, std::vector<services::IdentityDone>> waiters_;
    std::map<std::uint32_t, services::IdentityResult> memo_;
    std::map<std::uint32_t, Cooldown> cooldown_;
    steady::time_point last_request_{};
    std::atomic<bool> cancel_{false};
    bool stopping_{};
    std::thread thread_; // 最后声明
};

} // namespace

// ---------------------------------------------------------------- 组装

fs::path executable_directory() {
    std::wstring buffer(MAX_PATH, L'\0');
    for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (n == 0U) return fs::current_path();
        if (n < buffer.size()) {
            buffer.resize(n);
            break;
        }
        buffer.resize(buffer.size() * 2U);
    }
    return fs::path(buffer).parent_path();
}

services::Services make_real_services(EngineApi& engine, RealServiceOptions options) {
    if (options.exe_directory.empty()) options.exe_directory = executable_directory();
    if (options.config_path.empty()) options.config_path = options.exe_directory / L"config.json";

    auto config = std::make_shared<ConfigState>();
    config->path = options.config_path;
    config->exe_directory = options.exe_directory;
    config->lenient = options.lenient_start;

    services::Services sv;
    sv.config = make_config_service(config);
    sv.devices = make_device_service(config);
    // R131：滑块直接读写所选端点的 Windows 主音量（IAudioEndpointVolume）。
    sv.audio_volume.get = [](const std::wstring& id, std::string& error) {
        return app::devices::get_endpoint_volume(narrow(id), error);
    };
    sv.audio_volume.set = [](const std::wstring& id, float scalar, std::string& error) {
        return app::devices::set_endpoint_volume(narrow(id), scalar, error);
    };
    sv.audio_volume.watch = [](const std::wstring& id, std::function<void(float)> on_change,
                               std::string& error) -> std::shared_ptr<void> {
        auto watch = app::devices::watch_endpoint_volume(narrow(id),
            [on_change = std::move(on_change)](const app::devices::EndpointVolumeChange& change) {
                if (!change.self_initiated) on_change(change.scalar);
            }, error);
        return std::shared_ptr<void>(std::move(watch));
    };

    auto cat = std::make_shared<CatRunner>(engine, config);
    sv.cat.state = [cat]() { return cat->state(); };
    sv.cat.connect = [cat](std::wstring port, std::uint32_t baud, services::Done done) {
        cat->connect(std::move(port), baud, std::move(done));
    };
    sv.cat.disconnect = [cat](services::Done done) { cat->disconnect(std::move(done)); };
    sv.cat.apply = [cat](services::CatSettings settings, services::Done done) { cat->apply(settings, std::move(done)); };
    sv.cat.query = [cat](services::Done done) { cat->query(std::move(done)); };
    sv.cat.set_squelch_polling = [cat](bool enabled) { cat->set_squelch_polling(enabled); };
    sv.cat.set_squelch_callback = [cat](services::SquelchCallback callback) {
        cat->set_squelch_callback(std::move(callback));
    };

    // R130：FM 中继记录追加写 <exe>\private\runtime\relay-log.jsonl（每段一行，不含凭据）。
    const auto relay_log_path = options.exe_directory / L"private" / L"runtime" / L"relay-log.jsonl";
    sv.append_relay_log = [relay_log_path](const std::string& json_line) {
        std::error_code ec;
        std::filesystem::create_directories(relay_log_path.parent_path(), ec);
        std::ofstream out(relay_log_path, std::ios::binary | std::ios::app);
        if (!out) return false;
        out << json_line << '\n';
        out.flush();
        return static_cast<bool>(out);
    };

    auto bm = std::make_shared<BmApiRunner>();
    sv.bm_api.list_static_groups = [bm](std::uint32_t device_id, std::string key, services::BmApiDone done) {
        bm->list(device_id, std::move(key), std::move(done));
    };
    sv.bm_api.add_static_group = [bm](std::uint32_t device_id, std::string key, std::uint32_t tg, int slot,
                                      services::BmApiDone done) {
        bm->write(true, device_id, std::move(key), tg, slot, std::move(done));
    };
    sv.bm_api.remove_static_group = [bm](std::uint32_t device_id, std::string key, std::uint32_t tg, int slot,
                                         services::BmApiDone done) {
        bm->write(false, device_id, std::move(key), tg, slot, std::move(done));
    };

    // 与 PS 版一致：<程序目录>\private\runtime\radio-identity-cache.json
    auto identity = std::make_shared<IdentityRunner>(
        app::radio_identity::cache_path(options.exe_directory / L"private" / L"runtime"));
    sv.identity.preload = [identity]() { return identity->preload(); };
    sv.identity.lookup = [identity](std::uint32_t id, services::IdentityDone done) { identity->lookup(id, std::move(done)); };

    sv.set_wakeup = [cat](std::function<void()> wakeup) { cat->set_wakeup(std::move(wakeup)); };
    sv.shutdown = [cat, bm, identity]() {
        cat->set_wakeup({});
        cat->stop();
        bm->stop();
        identity->stop();
    };
    return sv;
}

} // namespace wirex::gui
