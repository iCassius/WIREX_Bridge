#include "view_model.hpp"

#include "config_bridge.hpp"
#include "dev_log.hpp"
#include "cat_form_sync.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <charconv>
#include <cstdarg>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <exception>
#include <limits>
#include <utility>

namespace wirex::gui {
namespace {

using engine::BmLink;
using engine::CommandResult;
using engine::CommandStatus;
using engine::Phase;
using talkgroup_routing::MediaOwner;
using namespace std::chrono_literals;

constexpr auto kTransientDuration = 6s;

std::string fmt(const char* format, ...) {
    char buffer[512];
    va_list args;
    va_start(args, format);
    const int n = std::vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    if (n < 0) return {};
    return std::string(buffer, static_cast<std::size_t>(std::min<int>(n, static_cast<int>(sizeof(buffer)) - 1)));
}

ChannelKey key_of(const services::ChannelEntry& e) { return {e.id, e.kind, e.slot}; }

std::uint32_t gain_milli(int step) { return static_cast<std::uint32_t>(std::clamp(step, 1, 16)) * 1000U; }

int gain_step(std::uint32_t milli) {
    return std::clamp(static_cast<int>(std::lround(static_cast<double>(milli) / 1000.0)), 1, 16);
}

bool call_matches(const engine::CallInfo& call, const services::ChannelEntry& ch, std::uint32_t local_id) {
    if (call.kind != ch.kind || call.slot != ch.slot) return false;
    if (ch.kind == dmr_call::CallKind::private_call) {
        return call.source_id == ch.id && (local_id == 0U || call.destination_id == local_id);
    }
    return call.destination_id == ch.id;
}

// BM API slot → 收听频道时隙：1/2 → TS1/TS2；0（DMO/单时隙热点，设备状态 4）→ TS2。
// 理由：FTX-1 网关的 DMRD 流量与本程序新增频道默认都在 TS2（add_channel、Quick Call 同样用 TS2），
// 单时隙热点在 BM 侧不区分时隙，映射到 TS2 才能与现有频道和启动组呼的 TS2 目标对上。
dmr_call::Slot listen_slot(int api_slot) { return api_slot == 1 ? dmr_call::Slot::ts1 : dmr_call::Slot::ts2; }

// 静态组是否覆盖该组呼频道：同 TG 且同时隙；API slot 0 覆盖该 TG 的 TS2 频道，
// 若该 TG 只有一个频道则不论时隙都视为覆盖（Test-UiBmStaticChannelReadback）。
bool static_covers(const services::StaticGroup& g, std::uint32_t id, dmr_call::Slot slot,
                   const std::vector<services::ChannelEntry>& channels) {
    if (g.talkgroup != id) return false;
    if (g.slot == static_cast<int>(slot)) return true;
    if (g.slot != 0) return false;
    if (slot == dmr_call::Slot::ts2) return true;
    const auto same_tg = std::count_if(channels.begin(), channels.end(), [&](const auto& e) {
        return e.kind == dmr_call::CallKind::group && e.id == id;
    });
    return same_tg <= 1;
}

bool bm_profile_changed(const services::GuiConfig& current, const services::GuiConfig& next) {
    return current.callsign != next.callsign || current.dmr_id != next.dmr_id ||
           services::effective_gateway_id(current) != services::effective_gateway_id(next) ||
           current.master_host != next.master_host || current.master_port != next.master_port ||
           current.bm_password != next.bm_password;
}

} // namespace

// ---------------------------------------------------------------- 显示工具

std::string to_utf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string out(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring from_utf8(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring out(static_cast<std::size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

std::string channel_display_name(const services::ChannelEntry& entry) {
    if (!entry.name.empty() && entry.name != std::to_string(entry.id)) return entry.name;
    if (entry.kind == dmr_call::CallKind::group && entry.id == 91U) return "World-wide";
    if (entry.kind == dmr_call::CallKind::group && entry.id == 46001U) return language() == Language::en_us ? "China" : "全国";
    if (entry.kind == dmr_call::CallKind::private_call && entry.id == 460997U) {
        return language() == Language::en_us ? "China Parrot" : "中国鹦鹉";
    }
    return {};
}

std::string format_clock(std::chrono::system_clock::time_point t) {
    const std::time_t tt = std::chrono::system_clock::to_time_t(t);
    std::tm local{};
    if (localtime_s(&local, &tt) != 0) return "--:--:--";
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "%02d:%02d:%02d", local.tm_hour, local.tm_min, local.tm_sec);
    return buffer;
}

const char* bm_link_text(BmLink link) {
    switch (link) {
    case BmLink::disabled: return tr(Str::bm_disabled);
    case BmLink::resolving: return tr(Str::bm_resolving);
    case BmLink::connecting: return tr(Str::bm_connecting);
    case BmLink::connected: return tr(Str::bm_connected);
    case BmLink::backoff: return tr(Str::bm_backoff);
    case BmLink::failed: return tr(Str::bm_failed);
    }
    return tr(Str::bm_disabled);
}

const char* phase_text(const engine::Snapshot& s) {
    switch (s.phase) {
    case Phase::stopped: return tr(Str::phase_stopped);
    case Phase::starting: return s.serial_open ? tr(Str::hri_waiting) : tr(Str::phase_starting);
    case Phase::running: return tr(Str::phase_running);
    case Phase::stopping: return tr(Str::phase_stopping);
    case Phase::failed: return tr(Str::phase_failed);
    }
    return tr(Str::phase_stopped);
}

const char* command_status_text(CommandStatus status) {
    switch (status) {
    case CommandStatus::accepted: return tr(Str::st_accepted);
    case CommandStatus::idempotent: return tr(Str::st_idempotent);
    case CommandStatus::stale_revision: return tr(Str::st_stale_revision);
    case CommandStatus::busy: return tr(Str::st_busy);
    case CommandStatus::not_ready: return tr(Str::st_not_ready);
    case CommandStatus::invalid: return tr(Str::st_invalid);
    case CommandStatus::forbidden: return tr(Str::st_forbidden);
    case CommandStatus::failed: return tr(Str::st_failed);
    }
    return tr(Str::st_failed);
}

// ---------------------------------------------------------------- 生命周期

ViewModel::ViewModel(EngineApi& engine, services::Services services, bool fake)
    : engine_(engine), services_(std::move(services)), fake_(fake), snapshot_(engine.snapshot()) {
    if (!snapshot_) snapshot_ = std::make_shared<const engine::Snapshot>();
    if (services_.config.load) {
        std::string error;
        if (auto loaded = services_.config.load(error)) {
            config_ = std::move(*loaded);
        } else if (!error.empty()) {
            flash(fmt(tr(Str::settings_save_failed), error.c_str()), true, Str::save_settings);
        }
    }
    // 从用户配置恢复上次选择的界面语言；未知值由 parse_language 回落到简体中文。
    if constexpr (kHonorConfigLanguage) {
        set_language(parse_language(config_.ui_language));
    } else {
        set_language(Language::zh_cn);
    }
    playback_step = gain_step(snapshot_->phase == Phase::running ? snapshot_->radio_playback_gain_milli
                                                                 : config_.playback_gain_step * 1000U);
    transmit_step = gain_step(snapshot_->phase == Phase::running ? snapshot_->mic_transmit_gain_milli
                                                                 : config_.transmit_gain_step * 1000U);
    cat_form.port = to_utf8(config_.cat_port);
    for (int i = 0; i < 5; ++i) {
        if (kBaudRates[i] == config_.cat_baud_rate) cat_form.baud_index = i;
    }
    refresh_devices();
    if (services_.cat.state) {
        cat_ = services_.cat.state();
        last_cat_observed_revision_ = cat_.observed_revision;
        if (last_cat_observed_revision_ != 0U) {
            sync_cat_form_from_observed(cat_);
        }
    }
    last_phase_ = snapshot_->phase;
    if (services_.cat.set_squelch_callback) {
        // CAT 线程回调 → 经信箱切回 UI 线程。
        services_.cat.set_squelch_callback([mailbox = mailbox_, this](const services::SquelchEvent& event) {
            mailbox->post([this, event]() { on_squelch(event); });
        });
    }
    update_squelch_polling();
    // 顺序：先冻结启动组呼计划，再读取 BM 静态组；静态组读取结束（或超时）前不激活启动组呼，
    // 读到的静态组频道从计划中剔除（无需 Quick Call），未在收听表中的静态组补进频道。
    startup_group_activation_.freeze(config_.channels);
    static_import_pending_ = true;
    static_sync(); // 已有 API Key 与设备 ID 时读取 BM 静态组
    if (!static_.busy) resolve_startup_static(); // 无 API Key / 设备 ID：不等待
    update_startup_group_activation_status();
    // 正常产品启动时自动独立连接 BM runtime、CAT 与电台；--fake 保持静止，供截图和演示控制。
    if (!fake_) start();
}

ViewModel::~ViewModel() {
    engine_.set_wakeup({});
    {
        std::lock_guard<std::mutex> lock(mailbox_->mutex);
        mailbox_->closed = true;
        mailbox_->actions.clear();
        mailbox_->wakeup = {};
    }
    // 后台线程可能仍持有本对象的回调：先停线程，再销毁成员。
    if (services_.shutdown) services_.shutdown();
}

void ViewModel::Mailbox::post(std::function<void()> action) {
    std::function<void()> wake;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (closed) return;
        actions.push_back(std::move(action));
        wake = wakeup;
    }
    if (wake) wake();
}

void ViewModel::set_wakeup(std::function<void()> wakeup) {
    {
        std::lock_guard<std::mutex> lock(mailbox_->mutex);
        mailbox_->wakeup = wakeup;
    }
    if (services_.set_wakeup) services_.set_wakeup(wakeup);
    engine_.set_wakeup(std::move(wakeup));
}

// 后台线程（CAT/HTTP/RadioID worker）的回调都经这里排队，pump() 在 UI 线程执行。
void ViewModel::post_to_ui(std::function<void()> action) { mailbox_->post(std::move(action)); }

bool ViewModel::pump() {
    bool changed = false;
    if (auto latest = engine_.snapshot(); latest && latest->seq != snapshot_->seq) {
        const bool gains_changed = latest->audio_gains_revision != snapshot_->audio_gains_revision;
        snapshot_ = std::move(latest);
        if (gains_changed) {
            playback_step = gain_step(snapshot_->radio_playback_gain_milli);
            transmit_step = gain_step(snapshot_->mic_transmit_gain_milli);
        }
        if (snapshot_->phase != last_phase_) {
            last_phase_ = snapshot_->phase;
            if (last_phase_ == Phase::running) on_engine_running();
        }
        if (snapshot_->active_rx_call && snapshot_->active_rx_call->callsign.empty()) {
            lookup_identity(*snapshot_->active_rx_call);
        }
        changed = true;
    }
    // 身份写回引擎的结果不需要提示；只回收已完成的 future。
    identity_ops_.erase(std::remove_if(identity_ops_.begin(), identity_ops_.end(),
                                       [](std::future<CommandResult>& f) {
                                           return !f.valid() || f.wait_for(0s) == std::future_status::ready;
                                       }),
                        identity_ops_.end());
    for (const auto& event : engine_.drain_events(256U)) {
        handle_event(event);
        changed = true;
    }
    struct CompletedPending {
        Str op{};
        CommandResult result{};
        std::function<void(const CommandResult&)> on_done{};
    };
    std::vector<CompletedPending> completed;
    for (auto it = pending_.begin(); it != pending_.end();) {
        if (it->future.wait_for(0s) != std::future_status::ready) {
            ++it;
            continue;
        }
        CommandResult r;
        try {
            r = it->future.get();
        } catch (const std::exception& e) {
            r.status = CommandStatus::failed;
            r.detail = e.what();
        }
        auto op = it->op;
        auto done = std::move(it->on_done);
        it = pending_.erase(it);
        completed.push_back({op, std::move(r), std::move(done)});
        changed = true;
    }
    // 完成回调可以再排队一条 future（例如 configure_bm 后 set_bm_connection）；
    // 先完整移除本轮完成项，再调用回调，避免 vector 扩容使遍历迭代器失效。
    for (auto& item : completed) {
        if (item.on_done) item.on_done(item.result);
        report(item.op, item.result);
        changed = true;
    }
    std::vector<std::function<void()>> actions;
    {
        std::lock_guard<std::mutex> lock(mailbox_->mutex);
        actions.swap(mailbox_->actions);
    }
    for (auto& action : actions) {
        action();
        changed = true;
    }
    if (services_.cat.state) {
        auto cat = services_.cat.state();
        const bool state_changed = cat.revision != cat_.revision;
        const bool observation_changed = cat.observed_revision != last_cat_observed_revision_;
        if (state_changed) cat_ = std::move(cat);
        if (observation_changed) {
            last_cat_observed_revision_ = cat_.observed_revision;
            sync_cat_form_from_observed(cat_);
        }
        if (state_changed || observation_changed) {
            changed = true;
        }
    }
    update_squelch_polling();
    if (rx_policy_dirty_ && snapshot_->phase == Phase::running && !pending(Str::op_rx_policy)) {
        rx_policy_dirty_ = false;
        push_rx_policy();
        changed = true;
    }
    if (pump_startup_group_activation()) changed = true;
    if (!transient_text_.empty() && !transient_visible()) {
        transient_text_.clear();
        changed = true;
    }
    return changed;
}

std::optional<std::uint32_t> ViewModel::idle_timeout_ms() const {
    // 命令等待中：轮询 future（引擎完成时也会唤醒，这里只作兜底）。
    if (!pending_.empty() || static_.busy) return 100U;
    if (startup_group_activation_.active() &&
        snapshot_->bm_link == BmLink::connected && !startup_group_activation_.command_pending()) {
        if (const auto retry_at = startup_group_activation_.retry_at()) {
            const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                *retry_at - std::chrono::steady_clock::now()).count();
            return static_cast<std::uint32_t>(std::clamp<long long>(left + 1, 1, 1000));
        }
    }
    // 有来话时显示通话时长、有过滤流量提示时显示“N 秒前”，都需要每秒刷新（提示过期后自然停止）。
    if (snapshot_->active_rx_call || filtered_hint()) return 1000U;
    if (!transient_text_.empty()) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(transient_until_ - std::chrono::steady_clock::now());
        return static_cast<std::uint32_t>(std::max<long long>(left.count(), 0) + 10);
    }
    return std::nullopt;
}

// ---------------------------------------------------------------- 事件

std::chrono::system_clock::time_point ViewModel::to_wall(std::uint64_t engine_ms) const {
    // 引擎时间戳是相对本次运行起点（Snapshot::clock_origin_ms，steady_clock 毫秒）的毫秒数；
    // fake engine 的起点为 0，即时间戳本身就是 steady_clock 毫秒。
    const std::uint64_t origin = snapshot_ ? snapshot_->clock_origin_ms : 0U;
    const auto steady_now = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    const std::uint64_t absolute = origin + engine_ms;
    const auto age = steady_now >= absolute ? steady_now - absolute : 0U;
    return std::chrono::system_clock::now() - std::chrono::milliseconds(age);
}

void ViewModel::handle_event(const engine::Event& event) {
    switch (event.kind) {
    case engine::EventKind::rx_call_started:
        if (event.call) {
            if (event.call->callsign.empty()) lookup_identity(*event.call);
            history_.push_front({*event.call, to_wall(event.call->started_ms)});
            if (history_.size() > history_limit) history_.pop_back();
            if (selected_history_) {
                *selected_history_ += 1U;
                if (*selected_history_ >= history_.size()) selected_history_.reset();
            }
        }
        break;
    case engine::EventKind::quick_call_result:
        // 自动队列在右侧状态行汇总本机发送进度；避免通用事件文案覆盖 TG/TS 级状态。
        if (startup_group_activation_.command_pending()) break;
        if (!event.text.empty()) flash(event.text, false);
        break;
    case engine::EventKind::warning:
        if (!event.text.empty()) flash(event.text, event.kind == engine::EventKind::warning);
        break;
    case engine::EventKind::fatal:
        flash(event.text.empty() ? std::string(tr(Str::phase_failed)) : event.text, true);
        break;
    case engine::EventKind::relay_fm_started:
        if (auto log = dev_log()) {
            const auto target = event.relay_fm ? event.relay_fm->target : talkgroup_routing::TxTarget{};
            log->line("relay", fmt("fm relay started target=%s:%u ts=%d",
                                   target.kind == dmr_call::CallKind::group ? "group" : "private",
                                   target.destination_id, static_cast<int>(target.slot)));
        }
        break;
    case engine::EventKind::relay_fm_ended:
        finish_relay_record(event);
        break;
    case engine::EventKind::rx_call_ended:
    case engine::EventKind::tx_started:
    case engine::EventKind::tx_ended:
    case engine::EventKind::bm_link_changed:
        break;
    }
}

// ---------------------------------------------------------------- FM 中继（R130）

RelayStatus ViewModel::relay_status() const noexcept {
    if (!config_.relay_enabled) return RelayStatus::off;
    if (!config_.relay_fm_enabled) return RelayStatus::c4fm_only;
    if (snapshot_->relay_fm_active) return RelayStatus::active;
    if (!cat_.connected) return RelayStatus::no_cat;
    return RelayStatus::waiting;
}

void ViewModel::update_squelch_polling() {
    const bool want = config_.relay_enabled && config_.relay_fm_enabled && cat_.connected;
    if (want == squelch_polling_) return;
    squelch_polling_ = want;
    if (services_.cat.set_squelch_polling) services_.cat.set_squelch_polling(want);
    if (!want) {
        squelch_open_ = false;
        // 关闭轮询时服务会对开门状态发 closed；这里再兜底请求引擎结束（未在中继时为 idempotent）。
        if (snapshot_->relay_fm_active) request_relay_fm_stop();
    }
}

void ViewModel::request_relay_fm_stop() {
    // start 可能仍在途：stop 照常排队，引擎按命令顺序处理（未在中继时返回 idempotent）。
    track(Str::op_relay_fm, engine_.relay_fm_stop(), [](const CommandResult& result) {
        if (auto log = dev_log()) {
            log->line("relay", "relay_fm_stop status=" + std::to_string(static_cast<int>(result.status)) +
                                   " detail=" + result.detail);
        }
    });
}

void ViewModel::request_relay_fm_mute(bool muted) {
    // 静噪 hang 期间静音上行（去掉关门前的尾噪）；未在中继时引擎返回 idempotent。
    track(Str::op_relay_fm, engine_.relay_fm_mute(muted), [muted](const CommandResult& result) {
        if (auto log = dev_log()) {
            log->line("relay", std::string("relay_fm_mute muted=") + (muted ? "1" : "0") + " status=" +
                                   std::to_string(static_cast<int>(result.status)) + " detail=" + result.detail);
        }
    });
}

void ViewModel::on_squelch(const services::SquelchEvent& event) {
    if (event.edge == services::SquelchEdge::muted || event.edge == services::SquelchEdge::unmuted) {
        // 门仍开启（squelch_open_ 不变）；只在中继段内有意义，空闲时不发命令。
        if (snapshot_->relay_fm_active || pending(Str::op_relay_fm)) {
            request_relay_fm_mute(event.edge == services::SquelchEdge::muted);
        }
        return;
    }
    if (event.edge == services::SquelchEdge::opened) {
        squelch_open_ = true;
        if (!(config_.relay_enabled && config_.relay_fm_enabled)) return;
        track(Str::op_relay_fm, engine_.relay_fm_start(), [this](const CommandResult& result) {
            if (auto log = dev_log()) {
                log->line("relay", "relay_fm_start status=" + std::to_string(static_cast<int>(result.status)) +
                                       " detail=" + result.detail);
            }
            if (result.status == CommandStatus::accepted || result.status == CommandStatus::idempotent) return;
            // busy（BM/HRI 下行或手咪 PTT 占用）只记日志，避免每次开门都刷屏；其它原因提示一次。
            if (result.status == CommandStatus::busy) return;
            const auto detail = result.detail.empty() ? std::string(command_status_text(result.status)) : result.detail;
            flash(fmt(tr(Str::relay_fm_rejected_fmt), detail.c_str()), true, Str::op_relay_fm);
        });
        return;
    }
    squelch_open_ = false;
    last_squelch_peak_ = event.s_meter_peak;
    last_squelch_close_ = std::chrono::steady_clock::now();
    if (relay_awaiting_peak_) {
        // 引擎先结束（超时等）的段：用本次关门峰值补全后再写记录。
        auto record = std::move(*relay_awaiting_peak_);
        relay_awaiting_peak_.reset();
        record.relay_s_peak = event.s_meter_peak;
        for (auto& rec : history_) {
            if (rec.relay_fm && rec.started_wall == record.started_wall) {
                rec.relay_s_peak = record.relay_s_peak;
                break;
            }
        }
        write_relay_record(record);
    }
    request_relay_fm_stop();
}

void ViewModel::finish_relay_record(const engine::Event& event) {
    CallRecord record;
    record.relay_fm = true;
    if (event.relay_fm) {
        record.call.destination_id = event.relay_fm->target.destination_id;
        record.call.kind = event.relay_fm->target.kind;
        record.call.slot = event.relay_fm->target.slot;
        record.call.started_ms = event.relay_fm->started_ms;
        record.relay_duration_ms = event.relay_fm->duration_ms;
        record.started_wall = to_wall(event.relay_fm->started_ms);
    } else {
        record.started_wall = to_wall(event.at_ms);
    }
    record.relay_end_reason = event.end_reason;
    bool complete = true;
    if (squelch_open_) {
        complete = false; // 静噪仍开（例如 180 s 超时）：等关门事件补 S 峰值
    } else if (last_squelch_close_ &&
               std::chrono::steady_clock::now() - *last_squelch_close_ <= std::chrono::seconds(5)) {
        record.relay_s_peak = last_squelch_peak_;
    }
    history_.push_front(record);
    if (history_.size() > history_limit) history_.pop_back();
    if (selected_history_) {
        *selected_history_ += 1U;
        if (*selected_history_ >= history_.size()) selected_history_.reset();
    }
    if (complete) {
        write_relay_record(record);
    } else {
        if (relay_awaiting_peak_) write_relay_record(*relay_awaiting_peak_);
        relay_awaiting_peak_ = record;
    }
}

void ViewModel::write_relay_record(const CallRecord& record) {
    const std::time_t tt = std::chrono::system_clock::to_time_t(record.started_wall);
    std::tm utc{};
    char when[32] = "1970-01-01T00:00:00Z";
    if (gmtime_s(&utc, &tt) == 0) std::strftime(when, sizeof(when), "%Y-%m-%dT%H:%M:%SZ", &utc);
    std::string reason;
    for (const char c : record.relay_end_reason) {
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') reason.push_back(c); // 机器可读原因，无需转义
    }
    const std::string peak = record.relay_s_peak ? std::to_string(*record.relay_s_peak) : std::string("null");
    const std::string line = fmt(
        "{\"started_utc\":\"%s\",\"duration_ms\":%llu,\"target_kind\":\"%s\",\"target_id\":%u,\"slot\":%d,"
        "\"s_meter_peak\":%s,\"end_reason\":\"%s\"}",
        when, static_cast<unsigned long long>(record.relay_duration_ms),
        record.call.kind == dmr_call::CallKind::group ? "group" : "private", record.call.destination_id,
        static_cast<int>(record.call.slot), peak.c_str(), reason.c_str());
    if (auto log = dev_log()) log->line("relay", "fm relay ended " + line);
    if (services_.append_relay_log && !services_.append_relay_log(line)) {
        if (auto log = dev_log()) log->line("gui-error", "relay-log.jsonl append failed");
    }
}

void ViewModel::toggle_relay() {
    auto next = config_;
    next.relay_enabled = !config_.relay_enabled;
    std::string error;
    if (!save_config(next, error)) {
        flash(fmt(tr(Str::settings_save_failed), error.c_str()), true, Str::save_settings);
        return;
    }
    if (snapshot_->serial_open || pending(Str::op_start)) flash(tr(Str::relay_reconnect_needed), false);
    update_squelch_polling();
}

void ViewModel::toggle_relay_fm() {
    if (!config_.relay_enabled) return;
    auto next = config_;
    next.relay_fm_enabled = !config_.relay_fm_enabled;
    std::string error;
    if (!save_config(next, error)) {
        flash(fmt(tr(Str::settings_save_failed), error.c_str()), true, Str::save_settings);
        return;
    }
    update_squelch_polling();
}

void ViewModel::preview_relay_enabled() noexcept {
    config_.relay_enabled = true;
    config_.relay_fm_enabled = true;
    // 演示段的关门峰值（模拟 SM0 读数），使注入的 FM 中继记录显示 S 峰值。
    last_squelch_peak_ = 198U;
    last_squelch_close_ = std::chrono::steady_clock::now();
}

void ViewModel::flash(std::string text, bool failed, Str operation) {
    if (auto log = dev_log()) log->line(failed ? "gui-error" : "gui", text);
    if (failed) enqueue_operation_event(operation, text, true);
    transient_text_ = std::move(text);
    transient_failed_ = failed;
    transient_until_ = std::chrono::steady_clock::now() + kTransientDuration;
}

void ViewModel::enqueue_operation_event(Str operation, const std::string& message, bool failed) {
    if (!failed || message.empty()) return;

    std::string safe_message = message;
    const std::string* secrets[] = {&config_.bm_password, &config_.bm_api_key};
    for (const auto* secret : secrets) {
        if (secret->empty()) continue;
        std::size_t pos = 0U;
        while ((pos = safe_message.find(*secret, pos)) != std::string::npos) {
            safe_message.replace(pos, secret->size(), "[redacted]");
            pos += sizeof("[redacted]") - 1U;
        }
    }
    constexpr std::size_t max_message_bytes = 1024U;
    if (safe_message.size() > max_message_bytes) {
        safe_message.resize(max_message_bytes);
        // Keep UTF-8 valid when the byte cap lands inside a multibyte character.
        while (!safe_message.empty() &&
               (static_cast<unsigned char>(safe_message.back()) & 0xC0U) == 0x80U) {
            safe_message.pop_back();
        }
        if (!safe_message.empty() &&
            (static_cast<unsigned char>(safe_message.back()) & 0xC0U) == 0xC0U) {
            safe_message.pop_back();
        }
    }

    operation_events_.push_back({next_operation_event_sequence_++, operation,
                                 std::move(safe_message), true});
    constexpr std::size_t max_events = 64U;
    while (operation_events_.size() > max_events) operation_events_.pop_front();
}

std::vector<OperationEvent> ViewModel::drain_operation_events() {
    std::vector<OperationEvent> drained;
    drained.reserve(operation_events_.size());
    while (!operation_events_.empty()) {
        drained.push_back(std::move(operation_events_.front()));
        operation_events_.pop_front();
    }
    return drained;
}

bool ViewModel::transient_visible() const {
    return !transient_text_.empty() && std::chrono::steady_clock::now() < transient_until_;
}

void ViewModel::report(Str op, const CommandResult& r) {
    if (auto log = dev_log()) {
        log->line("result", std::string(tr(op)) + " status=" + std::to_string(static_cast<int>(r.status)) +
                                " detail=" + r.detail);
    }
    if (op == Str::op_start && suppress_cancelled_start_report_) {
        suppress_cancelled_start_report_ = false;
        return;
    }
    if (op == Str::op_auto_quick_call &&
        (r.status == CommandStatus::busy ||
         (r.status == CommandStatus::not_ready && snapshot_->bm_link != BmLink::connected))) {
        return; // Busy/断线由持久队列状态显示；避免 500ms 重试时刷屏或把暂缓误报为失败。
    }
    if (op == Str::op_relay_fm) return; // FM 中继启停结果由 on_squelch 的回调按状态提示，避免 busy 刷屏
    if (op == Str::op_auto_quick_call) {
        if (r.status == CommandStatus::accepted) return;
        if (startup_group_activation_last_target_) {
            const auto& target = *startup_group_activation_last_target_;
            const auto detail = r.detail.empty() ? command_status_text(r.status) : r.detail.c_str();
            flash(fmt(tr(Str::startup_group_failure_fmt), target.id, static_cast<int>(target.slot), detail), true, op);
        } else if (r.detail.empty()) {
            flash(fmt(tr(Str::result_fmt), tr(op), command_status_text(r.status)), true, op);
        } else {
            flash(fmt(tr(Str::result_fmt_detail), tr(op), command_status_text(r.status), r.detail.c_str()), true, op);
        }
        return;
    }
    const bool ok = r.status == CommandStatus::accepted || r.status == CommandStatus::idempotent;
    // 成功由状态本身体现；Quick Call 的本机发送结果由 quick_call_result 事件文本提示。
    if (ok && op != Str::op_cat) return;
    if (r.detail.empty() || ok) {
        flash(fmt(tr(Str::result_fmt), tr(op), command_status_text(r.status)), !ok, op);
    } else {
        flash(fmt(tr(Str::result_fmt_detail), tr(op), command_status_text(r.status), r.detail.c_str()), true, op);
    }
}

void ViewModel::track(Str op, std::future<CommandResult> future, std::function<void(const CommandResult&)> on_done) {
    if (!future.valid()) {
        CommandResult r;
        r.detail = "no_future";
        if (on_done) on_done(r);
        report(op, r);
        return;
    }
    pending_.push_back({op, std::move(future), std::move(on_done)});
}

bool ViewModel::pending(Str op) const {
    return std::any_of(pending_.begin(), pending_.end(), [op](const PendingOp& p) { return p.op == op; });
}

// ---------------------------------------------------------------- 读取

bool ViewModel::engine_running() const noexcept { return snapshot_->phase == Phase::running; }

bool ViewModel::can_mutate_channels() const noexcept {
    return !pending(Str::op_rx_policy) && !pending(Str::op_tx_policy) &&
           (snapshot_->phase == Phase::running || snapshot_->phase == Phase::stopped);
}

std::size_t ViewModel::channel_page_count() const noexcept {
    return std::max<std::size_t>(1U, (config_.channels.size() + channel_page_size - 1U) / channel_page_size);
}

std::size_t ViewModel::history_page_count() const noexcept {
    return std::max<std::size_t>(1U, (history_.size() + history_page_size - 1U) / history_page_size);
}

std::optional<talkgroup_routing::TxTarget> ViewModel::current_tx_target() const {
    if (snapshot_->phase == Phase::running && snapshot_->tx_target.destination_id != 0U) return snapshot_->tx_target;
    return config_.tx_target;
}

std::vector<ChannelView> ViewModel::channel_page() const {
    std::vector<ChannelView> out;
    const auto tx = current_tx_target();
    const bool tx_active = snapshot_->tx_active || snapshot_->media_owner == MediaOwner::tx_active ||
                           snapshot_->media_owner == MediaOwner::tx_draining;
    const std::size_t begin = channel_page_ * channel_page_size;
    for (std::size_t i = begin; i < config_.channels.size() && i < begin + channel_page_size; ++i) {
        const auto& entry = config_.channels[i];
        ChannelView v;
        v.entry = entry;
        v.key = key_of(entry);
        v.is_tx_target = tx && tx->destination_id == entry.id && tx->kind == entry.kind && tx->slot == entry.slot;
        v.is_tx_active = v.is_tx_target && tx_active;
        v.is_muted = muted_.count(v.key) != 0U;
        v.quick_call_allowed = entry.kind == dmr_call::CallKind::group && entry.id != 4000U;
        v.is_static = v.quick_call_allowed && is_static_channel(entry);
        v.quick_call_sent = quick_call_sent_.count(v.key) != 0U;
        v.quick_call_pending = quick_call_pending_ && *quick_call_pending_ == v.key;
        if (!v.is_muted && snapshot_->active_rx_call && call_matches(*snapshot_->active_rx_call, entry, config_.dmr_id)) {
            v.current_call = with_callsign(*snapshot_->active_rx_call);
        } else {
            for (const auto& rec : history_) {
                if (rec.relay_fm) continue;
                if (call_matches(rec.call, entry, config_.dmr_id)) {
                    v.last_call = rec;
                    v.last_call->call = with_callsign(rec.call);
                    break;
                }
            }
        }
        const char* kind = entry.kind == dmr_call::CallKind::group ? tr(Str::group) : tr(Str::private_call);
        v.title = fmt("%s %u", kind, entry.id);
        if (const auto name = channel_display_name(entry); !name.empty()) v.title += " · " + name;
        v.tooltip = v.title;
        const int slot = static_cast<int>(entry.slot);
        if (v.is_static) {
            v.title += std::string(" · ") + tr(Str::static_group);
            v.tooltip = v.title + "\n" + fmt(tr(Str::tip_static), entry.id, slot);
        } else if (v.quick_call_sent) {
            v.title += std::string(" · ") + tr(Str::dynamic_group);
            v.tooltip = v.title + "\n" + fmt(tr(Str::tip_dynamic_sent), entry.id, slot);
        }
        out.push_back(std::move(v));
    }
    return out;
}

std::vector<CallRecord> ViewModel::recent_callers(std::size_t max) const {
    // 去重后的最近来话（同一 DMR ID 只保留最近一次），不含当前进行中的那通。
    std::vector<CallRecord> out;
    std::set<std::uint32_t> seen;
    const auto active = snapshot_->active_rx_call;
    bool skipped_active = false;
    for (const auto& rec : history_) {
        if (rec.relay_fm) continue;
        if (active && !skipped_active && rec.call.source_id == active->source_id &&
            rec.call.destination_id == active->destination_id) {
            skipped_active = true;
            continue;
        }
        if (!seen.insert(rec.call.source_id).second) continue;
        out.push_back(rec);
        out.back().call = with_callsign(rec.call);
        if (out.size() >= max) break;
    }
    return out;
}

std::optional<std::chrono::system_clock::time_point> ViewModel::current_call_started() const {
    if (!snapshot_->active_rx_call) return std::nullopt;
    return to_wall(snapshot_->active_rx_call->started_ms);
}

std::optional<engine::CallInfo> ViewModel::active_call() const {
    if (!snapshot_->active_rx_call) return std::nullopt;
    return with_callsign(*snapshot_->active_rx_call);
}

engine::CallInfo ViewModel::with_callsign(engine::CallInfo call) const {
    if (call.callsign.empty()) {
        if (auto it = callsigns_.find(call.source_id); it != callsigns_.end()) call.callsign = it->second;
    }
    return call;
}

// ---------------------------------------------------------------- 命令

void ViewModel::start() {
    if (pending(Str::op_start) || pending(Str::op_stop)) return;
    if (snapshot_->phase == Phase::starting || snapshot_->phase == Phase::stopping) return;
    const bool runtime_active = snapshot_->phase == Phase::running;
    if (runtime_active && snapshot_->serial_open) return;
    const auto current_cat = services_.cat.state ? services_.cat.state() : cat_;

    auto next_config = config_;
    const bool cat_auto = cat_form.port.empty() || cat_form.port == "auto";
    next_config.cat_port = cat_auto ? std::wstring{} : from_utf8(cat_form.port);
    next_config.cat_baud_rate = kBaudRates[std::clamp(cat_form.baud_index, 0, 4)];
    if (next_config.cat_port != config_.cat_port || next_config.cat_baud_rate != config_.cat_baud_rate) {
        std::string save_error;
        if (!save_config(next_config, save_error)) {
            flash(fmt(tr(Str::settings_save_failed), save_error.c_str()), true);
            return;
        }
    }

    // 电台参数与 BM runtime 分开解析：设备缺失时仍启动 BM runtime，并保留精确 radio_error。
    std::string radio_error;
    auto radio_config = make_radio_start_config(radio_error);
    const bool can_connect_radio = radio_config.has_value();
    if (runtime_active && !can_connect_radio) {
        flash(radio_error.empty() ? "未找到唯一可用的 HRI/USB Audio 设备。" : radio_error, true);
        return;
    }

    const auto generation = ++radio_connection_generation_;
    if (services_.cat.connect && !current_cat.connected && !current_cat.busy) {
        services_.cat.connect(config_.cat_port, config_.cat_baud_rate,
            [this, generation](CommandResult result) {
                post_to_ui([this, generation, result = std::move(result)]() mutable {
                    if (generation != radio_connection_generation_) {
                        // stop() 先于连接完成时，清理可能刚完成的 CAT 查询，避免过期回调留下 CAT connected。
                        if (services_.cat.state && services_.cat.state().connected && services_.cat.disconnect) {
                            services_.cat.disconnect({});
                        }
                        return;
                    }
                    report(Str::op_cat, result);
                });
            });
    }

    if (runtime_active) {
        // Runtime/BM 已經运行；手动点 Start 只重新连电台，不重启 Engine，也不自动重试 BM。
        track(Str::op_start, engine_.connect_radio(std::move(*radio_config)));
        return;
    }

    std::string runtime_error;
    std::optional<engine::StartConfig> runtime;
    if (services_.config.make_runtime_config) {
        runtime = services_.config.make_runtime_config(config_, runtime_error);
    } else {
        runtime_error = "常驻引擎配置服务不可用。";
    }
    if (!runtime) {
        flash(fmt(tr(Str::result_fmt), tr(Str::op_start), runtime_error.c_str()), true);
        return;
    }

    runtime->start_radio = false;
    runtime->hri_port.clear();
    runtime->hri_body_file.clear();
    runtime->audio = {};
    std::string local_output_error;
    if (auto output = config_bridge::resolve_local_playback_output(config_, devices_, local_output_error)) {
        runtime->audio = *output;
        runtime->local_audio_start_error.clear();
    } else {
        // BM runtime remains available; the engine will keep admitted calls visible
        // and drain their decoded media until a unique output is selected.
        runtime->local_audio_start_error = local_output_error;
        if (!local_output_error.empty()) flash(local_output_error, true, Str::audio_devices);
    }
    runtime->radio_start_error = can_connect_radio ? std::string{} : radio_error;
    runtime->rx_policy = build_rx_policy();
    runtime->radio_playback_gain_milli = gain_milli(playback_step);
    runtime->mic_transmit_gain_milli = gain_milli(transmit_step);
    runtime->bm_start_disconnected = true;

    if (!radio_error.empty()) flash(radio_error, true);
    track(Str::op_start, engine_.start(std::move(*runtime)),
        [this, generation, radio_config = std::move(radio_config)](const CommandResult& result) mutable {
            suppress_cancelled_start_report_ = generation != radio_connection_generation_ &&
                result.status == CommandStatus::not_ready && result.detail == "start_cancelled";
            if (result.status != CommandStatus::accepted) return;

            // 两条子系统命令独立排队；其中一条失败不会撤销另一条或退出常驻 runtime。
            if (radio_config && generation == radio_connection_generation_) {
                track(Str::op_start, engine_.connect_radio(std::move(*radio_config)));
            }
            const auto base_revision = snapshot_->bm_connection_revision;
            if (base_revision == std::numeric_limits<std::uint64_t>::max()) {
                flash("BM 连接 revision 已达到上限，未发起连接。", true);
                return;
            }
            track(Str::op_bm, engine_.set_bm_connection(true, base_revision + 1U));
        });
}

void ViewModel::stop() {
    if (pending(Str::op_stop)) return;
    const auto generation = ++radio_connection_generation_;
    if (services_.cat.disconnect) {
        services_.cat.disconnect([this, generation](CommandResult result) {
            post_to_ui([this, generation, result = std::move(result)]() mutable {
                if (generation == radio_connection_generation_ &&
                    result.status != CommandStatus::accepted && result.status != CommandStatus::idempotent) {
                    report(Str::op_cat, result);
                }
            });
        });
    }
    if (snapshot_->phase == Phase::running &&
        (snapshot_->serial_open || pending(Str::op_start))) {
        // 即使 attach 命令仍在队列中，也排入 detach；BM runtime 始终保留。
        track(Str::op_stop, engine_.disconnect_radio());
    } else {
        CommandResult result;
        result.status = CommandStatus::idempotent;
        report(Str::op_stop, result);
    }
}

void ViewModel::toggle_bm() {
    if (pending(Str::op_bm)) return;
    if (snapshot_->phase != Phase::running) {
        flash("BM runtime 尚未运行。", true);
        return;
    }
    const auto current_revision = snapshot_->bm_connection_revision;
    if (current_revision == std::numeric_limits<std::uint64_t>::max()) {
        flash("BM 连接 revision 已达到上限，无法切换连接。", true);
        return;
    }
    const auto requested_revision = current_revision + 1U;
    if (snapshot_->bm_requested_enabled) {
        track(Str::op_bm, engine_.set_bm_connection(false, requested_revision), [this](const CommandResult& result) {
            if (result.status == CommandStatus::accepted || result.status == CommandStatus::idempotent) {
                bm_configure_pending_ = false;
            }
        });
        return;
    }

    std::string error;
    auto target = make_bm_target(error);
    if (!target) {
        flash(fmt(tr(Str::result_fmt), tr(Str::op_bm), error.c_str()), true);
        return;
    }
    const auto requested_profile_generation = bm_profile_generation_;
    bm_configure_pending_ = true;
    track(Str::op_bm, engine_.configure_bm(std::move(*target)),
        [this, requested_profile_generation](const CommandResult& configured) {
            bm_configure_pending_ = false;
            if (configured.status != CommandStatus::accepted && configured.status != CommandStatus::idempotent) return;
            if (requested_profile_generation != bm_profile_generation_) {
                flash(tr(Str::bm_config_saved_during_connection), true);
                return; // A newer profile was saved while configure_bm was pending; never enable the old one.
            }
            const auto revision = std::max(configured.revision, snapshot_->bm_connection_revision);
            if (revision == std::numeric_limits<std::uint64_t>::max()) {
                flash("BM 连接 revision 已达到上限，未发起连接。", true);
                return;
            }
            track(Str::op_bm, engine_.set_bm_connection(true, revision + 1U));
        });
}

std::optional<engine::RadioStartConfig> ViewModel::make_radio_start_config(std::string& error) const {
    if (!services_.config.make_start_config) {
        error = "电台设备解析服务不可用。";
        return std::nullopt;
    }
    // make_start_config 同时构造 StartConfig；清除临时 GUI 副本里的密码，避免第二份明文密码被复制进结果。
    auto radio_only = config_;
    std::fill(radio_only.bm_password.begin(), radio_only.bm_password.end(), '\0');
    radio_only.bm_password.clear();
    auto parsed = services_.config.make_start_config(radio_only, error);
    if (!parsed || !parsed->start_radio || parsed->hri_port.empty() ||
        parsed->audio.expected_wave_in_endpoint_id.empty() ||
        parsed->audio.expected_wave_out_endpoint_id.empty()) {
        if (error.empty()) error = "未解析到唯一可用的 HRI 串口和 USB Audio 输入/输出端点。";
        return std::nullopt;
    }
    engine::RadioStartConfig result;
    result.hri_port = std::move(parsed->hri_port);
    result.hri_body_file = std::move(parsed->hri_body_file);
    result.audio = std::move(parsed->audio);
    // R131：中继开启默认仍用 DIRECT 模板（实机确认 AP 模板对中继无区别）；relay.y_template="ap" 时才用 AP 变体。
    result.ap_mode = config_.relay_enabled && config_.relay_y_template_ap;
    if (auto log = dev_log()) {
        log->line("gui", std::string(result.ap_mode ? "radio connect y_template=ap" : "radio connect y_template=direct") +
                             " relay=" + (config_.relay_enabled ? "on" : "off"));
    }
    return result;
}

std::optional<engine::BmTarget> ViewModel::make_bm_target(std::string& error) const {
    if (!services_.config.make_runtime_config) {
        error = "BM 配置服务不可用。";
        return std::nullopt;
    }
    auto runtime = services_.config.make_runtime_config(config_, error);
    if (!runtime) return std::nullopt;
    auto target = std::move(runtime->bm);
    target.local_source_id = runtime->local_source_id;
    target.rx_policy = build_rx_policy();
    target.tx_policy = runtime->tx_policy;
    return target;
}

// Get-UiNativeRxPolicyForChannels：屏蔽 = 从 allow 列表中移除（Router 拒绝同时出现在 allow 与 block 的组）。
talkgroup_routing::RxPolicy ViewModel::build_rx_policy() const {
    std::set<std::string> muted;
    for (const auto& k : muted_) muted.insert(config_bridge::channel_key(k.id, k.kind, k.slot));
    return config_bridge::make_rx_policy(config_.channels, muted, config_.dmr_id, config_.blocked_source_ids);
}

void ViewModel::push_rx_policy() {
    if (snapshot_->phase != Phase::running) {
        // 未运行时只改配置，启动时一并下发；启动中则等进入 running 后补发（启动参数可能已是旧策略）。
        if (snapshot_->phase == Phase::starting || pending(Str::op_start)) rx_policy_dirty_ = true;
        return;
    }
    if (pending(Str::op_rx_policy)) {
        rx_policy_dirty_ = true; // revision 会过期：等在途命令完成后按最新频道重发
        return;
    }
    track(Str::op_rx_policy, engine_.replace_rx_policy(snapshot_->rx_policy_revision, build_rx_policy()));
}

void ViewModel::persist() {
    if (!services_.config.save) return;
    std::string error;
    if (!services_.config.save(config_, error)) flash(fmt(tr(Str::settings_save_failed), error.c_str()), true);
}

void ViewModel::set_tx_target(const ChannelKey& key) {
    if (!can_mutate_channels()) return;
    talkgroup_routing::TxTarget target{key.id, key.kind, key.slot};
    if (snapshot_->phase != Phase::running) {
        config_.tx_target = target;
        persist();
        return;
    }
    track(Str::op_tx_policy, engine_.replace_tx_policy(snapshot_->tx_policy_revision, target, true),
          [this, target](const CommandResult& r) {
              if (r.status == CommandStatus::accepted || r.status == CommandStatus::idempotent) {
                  config_.tx_target = target;
                  persist();
              }
          });
}

void ViewModel::remove_channel(const ChannelKey& key) {
    if (!can_mutate_channels()) return;
    erase_channel(key);
}

void ViewModel::erase_channel(const ChannelKey& key) {
    auto& chs = config_.channels;
    chs.erase(std::remove_if(chs.begin(), chs.end(), [&](const auto& e) { return key_of(e) == key; }), chs.end());
    muted_.erase(key);
    quick_call_sent_.erase(key);
    if (config_.tx_target && config_.tx_target->destination_id == key.id && config_.tx_target->kind == key.kind &&
        config_.tx_target->slot == key.slot) {
        config_.tx_target.reset();
    }
    set_channel_page(channel_page_);
    persist();
    push_rx_policy();
}

void ViewModel::remove_static_channel(const ChannelKey& key) {
    if (!can_mutate_channels()) return;
    if (config_.bm_api_key.empty()) {
        erase_channel(key);
        flash(fmt(tr(Str::static_unlisten_no_key_fmt), key.id), false);
        return;
    }
    const auto group = static_group_for(key);
    if (!group) {
        erase_channel(key);
        return;
    }
    if (static_.busy || !services_.bm_api.remove_static_group) {
        static_status(static_.busy ? "BM 静态组操作正在进行。" : "BM 静态组模块不可用。", true);
        return;
    }
    static_.busy = true;
    static_status(fmt(tr(Str::static_removing_fmt), group->talkgroup), false);
    const auto device = bm_device_id();
    const auto g = *group; // 删除保留原 API slot
    services_.bm_api.remove_static_group(device, config_.bm_api_key, g.talkgroup, g.slot,
        [this, device, key, g](services::BmApiResult r) {
            post_to_ui([this, device, key, g, r = std::move(r)]() {
                static_.busy = false;
                if (device != bm_device_id()) {
                    static_status("设备或 API Key 已变更；频道保留。", true);
                    return;
                }
                static_apply(r, true);
                if (r.failed) {
                    const auto detail = r.message.empty() ? std::string(tr(Str::st_failed)) : r.message;
                    static_status(fmt(tr(Str::static_remove_failed_fmt), g.talkgroup, detail.c_str()), true);
                    return;
                }
                erase_channel(key);
                static_status(fmt(tr(Str::static_removed_unlisten_fmt), g.talkgroup), false);
            });
        });
}

void ViewModel::toggle_mute(const ChannelKey& key) {
    if (!can_mutate_channels()) return;
    if (!muted_.erase(key)) muted_.insert(key);
    push_rx_policy();
}

void ViewModel::add_channel() {
    if (!can_mutate_channels()) {
        flash(tr(Str::channel_not_ready), true);
        return;
    }
    // 编辑框可能是 "46001 组呼" 这样的预设文本：只取开头的数字。
    std::uint32_t id = 0U;
    const char* first = add_channel_id.data();
    while (*first == ' ') ++first;
    const char* last = add_channel_id.data() + add_channel_id.size();
    const auto [ptr, ec] = std::from_chars(first, last, id);
    if (ec != std::errc{} || ptr == first || id == 0U || id > 16777215U) {
        flash(tr(Str::channel_id_invalid), true);
        return;
    }
    if (add_channel_kind == 0) {
        flash(tr(Str::channel_kind_needed), true);
        return;
    }
    services::ChannelEntry entry;
    entry.id = id;
    entry.kind = add_channel_kind == 1 ? dmr_call::CallKind::private_call : dmr_call::CallKind::group;
    entry.slot = dmr_call::Slot::ts2; // bridge-ui.ps1 channelEditorSlot 默认 TS2（BM 热点为单时隙 TS2）
    const auto k = key_of(entry);
    if (std::any_of(config_.channels.begin(), config_.channels.end(), [&](const auto& e) { return key_of(e) == k; })) {
        flash(tr(Str::channel_exists), true);
        return;
    }
    add_channel_id.clear();
    add_channel_entry(std::move(entry));
}

void ViewModel::add_channel_entry(services::ChannelEntry entry) {
    entry.name = config_bridge::known_channel_name(entry.id, entry.kind);
    config_.channels.push_back(std::move(entry));
    set_channel_page(channel_page_count() - 1U);
    persist();
    push_rx_policy();
}

std::optional<FilteredHint> ViewModel::filtered_hint() const {
    if (!snapshot_ || !snapshot_->last_filtered || snapshot_->bm_link != BmLink::connected) return std::nullopt;
    const auto& traffic = *snapshot_->last_filtered;
    const auto age = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now() - to_wall(traffic.last_ms));
    if (age >= FilteredHint::window) return std::nullopt;
    FilteredHint hint;
    hint.traffic = traffic;
    hint.age_s = static_cast<std::uint32_t>(std::max<long long>(age.count(), 0));
    // 组呼按 TG/时隙收听；私呼的频道 ID 是对端（来源）ID，与 make_rx_policy 的 PrivatePeerRoute 一致。
    hint.key = traffic.kind == dmr_call::CallKind::group
                   ? ChannelKey{traffic.destination_id, traffic.kind, traffic.slot}
                   : ChannelKey{traffic.source_id, traffic.kind, traffic.slot};
    // 已加入且未屏蔽：过滤记录是加入前的旧流量，不再提示。
    const bool listening = muted_.count(hint.key) == 0U &&
        std::any_of(config_.channels.begin(), config_.channels.end(),
                    [&](const auto& e) { return key_of(e) == hint.key; });
    if (listening) return std::nullopt;
    return hint;
}

void ViewModel::listen_filtered() {
    const auto hint = filtered_hint();
    if (!hint) return;
    if (!can_mutate_channels()) {
        flash(tr(Str::channel_not_ready), true);
        return;
    }
    const auto& key = hint->key;
    if (key.id == 0U || key.id > 16777215U) {
        flash(tr(Str::channel_id_invalid), true);
        return;
    }
    const bool exists = std::any_of(config_.channels.begin(), config_.channels.end(),
                                    [&](const auto& e) { return key_of(e) == key; });
    if (exists) {
        // 已在列表但被屏蔽：恢复收听；否则说明策略尚未生效，提示已存在。
        if (muted_.erase(key) != 0U) {
            push_rx_policy();
        } else {
            flash(tr(Str::channel_exists), true);
        }
        return;
    }
    services::ChannelEntry entry;
    entry.id = key.id;
    entry.kind = key.kind;
    entry.slot = key.slot;
    add_channel_entry(std::move(entry));
}

void ViewModel::quick_call(const ChannelKey& key) {
    if (quick_call_pending_ || startup_group_activation_.active() || key.kind != dmr_call::CallKind::group) return;
    quick_call_pending_ = key;
    track(Str::op_quick_call, engine_.quick_call_join({key.id, key.slot}), [this, key](const CommandResult& r) {
        quick_call_pending_.reset();
        if (r.status == CommandStatus::accepted) quick_call_sent_.insert(key);
    });
}

void ViewModel::commit_gains() {
    config_.playback_gain_step = static_cast<std::uint32_t>(playback_step);
    config_.transmit_gain_step = static_cast<std::uint32_t>(transmit_step);
    persist();
    if (snapshot_->phase != Phase::running) return;
    track(Str::op_gains, engine_.set_audio_gains(gain_milli(playback_step), gain_milli(transmit_step)));
}

void ViewModel::set_audio_devices(std::wstring wave_in_endpoint_id, std::wstring wave_out_endpoint_id) {
    const bool radio_attached = snapshot_->serial_open || snapshot_->hri_ready;
    if (!radio_attached) {
        // Keep the WaveIn selector for a later HRI attach, but make WaveOut
        // independently usable as the BM-only computer playback endpoint.
        auto normalized_input = wave_in_endpoint_id;
        if (normalized_input == L"auto" || normalized_input == L"AUTO") normalized_input.clear();
        if (normalized_input != config_.wave_in_endpoint_id) {
            config_.wave_in_endpoint_id = std::move(normalized_input);
            persist();
        }
        set_audio_output(std::move(wave_out_endpoint_id));
        return;
    }

    if (wave_in_endpoint_id.empty() || wave_out_endpoint_id.empty()) {
        flash(tr(Str::audio_devices_failed), true);
        return;
    }
    const auto input = std::find_if(devices_.wave_in.begin(), devices_.wave_in.end(),
        [&](const services::AudioEndpointInfo& endpoint) { return endpoint.endpoint_id == wave_in_endpoint_id; });
    const auto output = std::find_if(devices_.wave_out.begin(), devices_.wave_out.end(),
        [&](const services::AudioEndpointInfo& endpoint) { return endpoint.endpoint_id == wave_out_endpoint_id; });
    if (input == devices_.wave_in.end() || output == devices_.wave_out.end()) {
        flash(tr(Str::audio_devices_failed), true);
        return;
    }
    if (pending(Str::op_audio_devices)) return;

    engine::AudioEndpoints audio{};
    audio.wave_in_id = input->wave_id;
    audio.wave_out_id = output->wave_id;
    audio.expected_wave_in_endpoint_id = wave_in_endpoint_id;
    audio.expected_wave_out_endpoint_id = wave_out_endpoint_id;

    if (snapshot_->phase == Phase::running || snapshot_->phase == Phase::starting) {
        track(Str::op_audio_devices, engine_.set_audio_endpoints(audio),
            [this, wave_in_endpoint_id = std::move(wave_in_endpoint_id),
                  wave_out_endpoint_id = std::move(wave_out_endpoint_id)](const CommandResult& result) {
                if (result.status != CommandStatus::accepted && result.status != CommandStatus::idempotent) return;
                config_.wave_in_endpoint_id = wave_in_endpoint_id;
                config_.wave_out_endpoint_id = wave_out_endpoint_id;
                persist();
                if (result.detail == "waveout_old_endpoint_closed_with_cleanup_warning") {
                    flash("新音频设备已生效，但旧设备报告了清理警告。", true);
                }
            });
        return;
    }

    config_.wave_in_endpoint_id = std::move(wave_in_endpoint_id);
    config_.wave_out_endpoint_id = std::move(wave_out_endpoint_id);
    persist();
}

void ViewModel::set_audio_output(std::wstring wave_out_endpoint_id) {
    if (pending(Str::op_audio_devices)) return;
    const bool automatic = wave_out_endpoint_id.empty() || wave_out_endpoint_id == L"auto" ||
                          wave_out_endpoint_id == L"AUTO";
    auto candidate = config_;
    candidate.wave_out_endpoint_id = automatic ? std::wstring{} : wave_out_endpoint_id;
    std::string error;
    auto output = config_bridge::resolve_local_playback_output(candidate, devices_, error);
    if (!output) {
        if (automatic && snapshot_->phase != Phase::running && snapshot_->phase != Phase::starting) {
            config_.wave_out_endpoint_id.clear();
            persist();
        }
        flash(error.empty() ? tr(Str::audio_devices_failed) : std::move(error), true, Str::audio_devices);
        return;
    }

    const std::wstring selector = automatic ? std::wstring{} : wave_out_endpoint_id;
    if (snapshot_->phase == Phase::running || snapshot_->phase == Phase::starting) {
        engine::AudioEndpoints audio{};
        audio.wave_out_id = output->wave_out_id;
        audio.expected_wave_out_endpoint_id = output->expected_wave_out_endpoint_id;
        track(Str::op_audio_devices, engine_.set_audio_endpoints(audio),
            [this, selector](const CommandResult& result) {
                if (result.status != CommandStatus::accepted && result.status != CommandStatus::idempotent) return;
                config_.wave_out_endpoint_id = selector;
                persist();
                if (result.detail == "waveout_old_endpoint_closed_with_cleanup_warning") {
                    flash("新音频设备已生效，但旧设备报告了清理警告。", true, Str::audio_devices);
                }
            });
        return;
    }

    config_.wave_out_endpoint_id = selector;
    persist();
}

void ViewModel::set_history_target() {
    if (!selected_history_ || *selected_history_ >= history_.size()) return;
    const auto& rec = history_[*selected_history_];
    const auto& call = rec.call;
    // FM 中继记录的 destination_id 就是当时的上行目标（私呼时为对端 ID）。
    ChannelKey key{call.kind == dmr_call::CallKind::group || rec.relay_fm ? call.destination_id : call.source_id,
                   call.kind, call.slot};
    const bool listed = std::any_of(config_.channels.begin(), config_.channels.end(),
                                    [&](const auto& e) { return key_of(e) == key; });
    if (!listed) {
        flash(tr(Str::tip_history_target), true);
        return;
    }
    set_tx_target(key);
}

void ViewModel::cat_toggle_connection() {
    if (!services_.cat.connect || cat_.busy) {
        if (!services_.cat.connect) flash(fmt(tr(Str::result_fmt), tr(Str::op_cat), tr(Str::st_not_ready)), true);
        return;
    }
    auto done = [this](CommandResult r) { post_to_ui([this, r = std::move(r)]() { report(Str::op_cat, r); }); };
    if (cat_.connected) {
        services_.cat.disconnect(done);
        return;
    }
    const auto baud = kBaudRates[std::clamp(cat_form.baud_index, 0, 4)];
    config_.cat_port = from_utf8(cat_form.port);
    config_.cat_baud_rate = baud;
    persist();
    services_.cat.connect(config_.cat_port, baud, done);
}

void ViewModel::cat_apply() {
    if (!services_.cat.apply) return;
    if (cat_form.mode_index < 0 || cat_form.mode_index >= 4 ||
        cat_form.power_index < 0 || cat_form.power_index >= 5) {
        flash(fmt(tr(Str::result_fmt), tr(Str::op_cat), tr(Str::st_invalid)), true);
        return;
    }
    services::CatSettings s;
    s.main_mode = static_cast<services::CatMode>(cat_form.mode_index);
    double mhz = 0.0;
    if (!cat_form.frequency_mhz.empty()) {
        const auto [ptr, ec] = std::from_chars(cat_form.frequency_mhz.data(),
                                               cat_form.frequency_mhz.data() + cat_form.frequency_mhz.size(), mhz);
        if (ec != std::errc{} || ptr != cat_form.frequency_mhz.data() + cat_form.frequency_mhz.size() ||
            mhz <= 0.0 || mhz > 1000.0) {
            flash(fmt(tr(Str::result_fmt), tr(Str::op_cat), tr(Str::st_invalid)), true);
            return;
        }
    }
    s.main_frequency_hz = static_cast<std::uint64_t>(std::llround(mhz * 1'000'000.0));
    s.power_w = kPowerWatts[cat_form.power_index];

    const std::array<bool, 3> submitted{true, !cat_form.frequency_mhz.empty(), true};
    const auto submitted_revision = cat_form_edit_revision_;
    services_.cat.apply(s, [this, submitted, submitted_revision](CommandResult r) {
        post_to_ui([this, r = std::move(r), submitted, submitted_revision]() {
            const bool ok = r.status == CommandStatus::accepted || r.status == CommandStatus::idempotent;
            if (ok) {
                cat_form_sync::clear_applied_dirty(cat_form_dirty_, submitted_revision,
                                                   cat_form_edit_revision_, submitted);
                if (services_.cat.state) {
                    auto state = services_.cat.state();
                    cat_ = std::move(state);
                    last_cat_observed_revision_ = cat_.observed_revision;
                    sync_cat_form_from_observed(cat_);
                }
            }
            report(Str::op_cat, r);
        });
    });
}

void ViewModel::set_cat_form_editing(CatFormField field, bool editing) noexcept {
    cat_form_editing_[cat_form_sync::index(field)] = editing;
}

void ViewModel::mark_cat_form_edited(CatFormField field) noexcept {
    const auto i = cat_form_sync::index(field);
    cat_form_dirty_[i] = true;
    ++cat_form_edit_revision_[i];
}

void ViewModel::sync_cat_form_from_observed(const services::CatState& state) {
    cat_form_sync::sync(cat_form, state, cat_form_dirty_, cat_form_editing_);
}

void ViewModel::refresh_devices() {
    if (services_.devices.enumerate) devices_ = services_.devices.enumerate();
}

services::DeviceSelectionSnapshot ViewModel::device_selection() const {
    const auto active = config_bridge::active_device_ids(*snapshot_, cat_);
    return config_bridge::resolve_device_selection(config_, devices_, active);
}

bool ViewModel::save_config(const services::GuiConfig& next, std::string& error) {
    const bool bm_changed = bm_profile_changed(config_, next);
    if (bm_changed) {
        if (bm_profile_generation_ == std::numeric_limits<std::uint64_t>::max()) {
            error = "BM 配置版本已达到上限，无法安全保存。";
            return false;
        }
        const bool bm_link_active = snapshot_->bm_requested_enabled || snapshot_->bm_link == BmLink::resolving ||
            snapshot_->bm_link == BmLink::connecting || snapshot_->bm_link == BmLink::connected ||
            snapshot_->bm_link == BmLink::backoff;
        const bool configure_only = bm_configure_pending_ && !bm_link_active;
        const bool startup_pending = pending(Str::op_start) || snapshot_->phase == Phase::starting;
        if (!configure_only && (bm_link_active || startup_pending || pending(Str::op_bm))) {
            error = tr(Str::bm_config_changed_while_connecting);
            return false;
        }
    }
    if (services_.config.save && !services_.config.save(next, error)) return false;
    config_ = next;
    config_.gateway_id = services::effective_gateway_id(next);
    if (bm_changed) ++bm_profile_generation_;
    flash(tr(Str::settings_saved), false);
    static_sync(); // 设备 ID 或 API Key 变化时刷新静态组（Sync-BmManagementUiIdentity）
    return true;
}

// ---------------------------------------------------------------- BM 静态组（BmManagementUi.ps1）

bool ViewModel::is_static_channel(const services::ChannelEntry& entry) const {
    // Test-UiBmStaticChannelReadback：同 TG 同时隙；API slot 0（DMO）只在设备状态 4 且该 TG 只有一个频道时对应。
    return entry.kind == dmr_call::CallKind::group && static_group_for(key_of(entry)).has_value();
}

std::optional<services::StaticGroup> ViewModel::static_group_for(const ChannelKey& key) const {
    if (!static_.loaded || key.kind != dmr_call::CallKind::group) return std::nullopt;
    // 精确时隙优先，其次 API slot 0。
    for (const auto& g : static_.groups) {
        if (g.talkgroup == key.id && g.slot == static_cast<int>(key.slot)) return g;
    }
    for (const auto& g : static_.groups) {
        if (g.slot == 0 && static_covers(g, key.id, key.slot, config_.channels)) return g;
    }
    return std::nullopt;
}

// 把已读取的 BM 静态组补进收听频道（不在收听表中的才加），保存配置并下发收听策略。
void ViewModel::import_static_channels() {
    if (!static_.loaded) return;
    std::vector<std::uint32_t> added;
    for (const auto& g : static_.groups) {
        if (g.talkgroup == 0U || g.talkgroup > 16777215U) continue;
        const bool listed = std::any_of(config_.channels.begin(), config_.channels.end(), [&](const auto& e) {
            return e.kind == dmr_call::CallKind::group && static_covers(g, e.id, e.slot, config_.channels);
        });
        if (listed) continue;
        services::ChannelEntry entry;
        entry.id = g.talkgroup;
        entry.kind = dmr_call::CallKind::group;
        entry.slot = listen_slot(g.slot);
        entry.name = config_bridge::known_channel_name(entry.id, entry.kind);
        config_.channels.push_back(std::move(entry));
        added.push_back(g.talkgroup);
    }
    if (added.empty()) return;
    persist();
    push_rx_policy();
    std::string list;
    for (const auto tg : added) list += (list.empty() ? "" : ", ") + std::to_string(tg);
    flash(fmt(tr(Str::static_imported_fmt), static_cast<unsigned>(added.size()), list.c_str()), false);
}

// 首次静态组读取结束（成功、失败、无 API Key 或超时）后调用一次：从启动组呼计划中剔除静态组频道。
void ViewModel::resolve_startup_static() {
    if (startup_static_resolved_) return;
    startup_static_resolved_ = true;
    startup_static_wait_since_.reset();
    if (static_.loaded) {
        startup_group_activation_.skip_if([this](const StartupGroupActivationTarget& t) {
            return std::any_of(static_.groups.begin(), static_.groups.end(), [&](const auto& g) {
                return static_covers(g, t.destination_id, t.slot, config_.channels);
            });
        });
    }
    update_startup_group_activation_status();
}

// Set-MainText BmStaticGroupStatus → Set-UiTransientStatus：静态组状态显示在标题栏的临时提示中；
// 面板内只保留最后一条作为列表悬停提示。
void ViewModel::static_status(std::string text, bool failed) {
    static_.status = text;
    static_.status_failed = failed;
    if (!text.empty()) flash(std::move(text), failed);
}

void ViewModel::static_sync() {
    const auto device = bm_device_id();
    const auto& key = config_.bm_api_key;
    if (device == static_.observed_device && key == static_.observed_key) return;
    const bool had = static_.loaded;
    static_.loaded = false;
    static_.groups.clear();
    static_.add_slot.reset();
    static_.device_status.reset();
    static_.selected.reset();
    static_.page = 0U;
    static_.observed_device = device;
    static_.observed_key = key;
    static_import_pending_ = true; // 新设备/Key 的首次成功读取补充收听频道
    if (key.empty() || device == 0U) {
        static_status(key.empty() ? std::string() : std::string("请先保存有效的 BM 设备 ID。"), !key.empty());
        return;
    }
    if (had) static_status("设备或 API Key 已变更；请刷新 BM 静态组。", false);
    if (static_.busy) {
        static_.refresh_pending = true;
        return;
    }
    static_refresh();
}

void ViewModel::static_refresh() {
    if (!services_.bm_api.list_static_groups) {
        static_status("BM 静态组模块不可用。", true);
        return;
    }
    if (config_.bm_api_key.empty()) {
        static_status("请输入 BM API Key。", true);
        return;
    }
    const auto device = bm_device_id();
    if (device == 0U) {
        static_status("请先保存有效的 BM 设备 ID。", true);
        return;
    }
    if (static_.busy) {
        static_.refresh_pending = true;
        return;
    }
    static_.busy = true;
    static_.observed_device = device;
    static_.observed_key = config_.bm_api_key;
    static_status("正在读取 BM 静态组。", false);
    services_.bm_api.list_static_groups(device, config_.bm_api_key, [this, device](services::BmApiResult r) {
        post_to_ui([this, device, r = std::move(r)]() {
            static_.busy = false;
            if (device != bm_device_id() || static_.observed_key != config_.bm_api_key) {
                static_status("设备或 API Key 已变更；未显示旧设备的 BM 静态组。", false);
            } else {
                static_apply(r, false);
                if (static_.loaded && static_import_pending_) {
                    static_import_pending_ = false;
                    import_static_channels();
                }
            }
            if (static_.refresh_pending) {
                static_.refresh_pending = false;
                static_refresh();
            }
            if (!static_.busy) resolve_startup_static();
        });
    });
}

void ViewModel::static_apply(const services::BmApiResult& r, bool write) {
    static_.page = 0U;
    static_.selected.reset();
    if (r.groups_valid) {
        static_.groups = r.groups;
        static_.loaded = true;
    } else if (!write) {
        static_.groups.clear();
        static_.loaded = false;
    }
    if (!write) {
        static_.add_slot = r.add_slot;
        static_.device_status = r.device_status;
    }
    static_status(r.message, r.failed);
}

void ViewModel::static_add() {
    if (static_.busy) {
        static_status("BM 静态组操作正在进行。", true);
        return;
    }
    if (!static_.loaded || static_.observed_device != bm_device_id() || static_.observed_key != config_.bm_api_key) {
        static_status("请先读取当前设备的 BM 静态组。", true);
        return;
    }
    std::uint32_t tg = 0U;
    const auto& text = static_.tg_input;
    const auto [ptr, ec] = std::from_chars(text.data(), text.data() + text.size(), tg);
    if (text.empty() || text.size() > 8U || ec != std::errc{} || ptr != text.data() + text.size() || tg == 0U ||
        tg > 16777215U) {
        static_status("请输入 1 至 16777215 的静态组 ID。", true);
        return;
    }
    if (!static_.add_slot) {
        static_status("设备状态不可用；添加已禁用。", true);
        return;
    }
    const int slot = *static_.add_slot;
    if (std::any_of(static_.groups.begin(), static_.groups.end(),
                    [&](const auto& g) { return g.talkgroup == tg && g.slot == slot; })) {
        static_status("该静态组已存在。", true);
        return;
    }
    static_.busy = true;
    static_status("正在向 BM 添加静态组。", false);
    const auto device = bm_device_id();
    services_.bm_api.add_static_group(device, config_.bm_api_key, tg, slot, [this, device](services::BmApiResult r) {
        post_to_ui([this, device, r = std::move(r)]() {
            static_.busy = false;
            if (device == bm_device_id()) {
                static_apply(r, true);
                if (!r.failed) {
                    static_.tg_input.clear();
                    import_static_channels(); // 新静态组同步加入收听频道
                }
            }
        });
    });
}

void ViewModel::static_remove() {
    if (static_.busy) {
        static_status("BM 静态组操作正在进行。", true);
        return;
    }
    if (!static_.loaded || !static_.selected || *static_.selected >= static_.groups.size()) {
        static_status("请先选择当前设备的一条 BM 静态组。", true);
        return;
    }
    const auto group = static_.groups[*static_.selected]; // 删除保留原 slot
    static_.busy = true;
    static_status("正在向 BM 移除静态组。", false);
    const auto device = bm_device_id();
    services_.bm_api.remove_static_group(device, config_.bm_api_key, group.talkgroup, group.slot,
        [this, device, group](services::BmApiResult r) {
            post_to_ui([this, device, group, r = std::move(r)]() {
                static_.busy = false;
                if (device != bm_device_id()) return;
                static_apply(r, true);
                if (r.failed) return;
                // 与频道卡片“移除”一致：BM 静态组移除成功后同步取消对应收听频道。
                std::vector<ChannelKey> keys;
                for (const auto& e : config_.channels) {
                    if (e.kind == dmr_call::CallKind::group && static_covers(group, e.id, e.slot, config_.channels)) {
                        keys.push_back(key_of(e));
                    }
                }
                for (const auto& k : keys) erase_channel(k);
                if (!keys.empty()) static_status(fmt(tr(Str::static_removed_unlisten_fmt), group.talkgroup), false);
            });
        });
}

void ViewModel::static_set_page(std::size_t page) {
    const std::size_t pages = std::max<std::size_t>(1U, (static_.groups.size() + StaticGroupsView::page_size - 1U) /
                                                            StaticGroupsView::page_size);
    static_.page = std::min(page, pages - 1U);
}

void ViewModel::static_select(std::optional<std::size_t> index) { static_.selected = index; }

// ---------------------------------------------------------------- 身份查询（bridge-ui.ps1 Start-UiIdentityQuery）

void ViewModel::lookup_identity(const engine::CallInfo& call) {
    if (!services_.identity.lookup || call.source_id == 0U || call.source_id > 16777215U) return;
    if (callsigns_.count(call.source_id) != 0U || !identity_requested_.insert(call.source_id).second) return;
    services_.identity.lookup(call.source_id, [this](services::IdentityResult r) {
        post_to_ui([this, r = std::move(r)]() { apply_identity(r); });
    });
}

void ViewModel::apply_identity(const services::IdentityResult& r) {
    identity_requested_.erase(r.source_id);
    if (!r.known) return;
    if (r.callsign) {
        callsigns_[r.source_id] = *r.callsign;
    } else {
        callsigns_.erase(r.source_id);
    }
    if (snapshot_->phase == Phase::running) push_identity(r.source_id, r.callsign);
}

void ViewModel::push_identity(std::uint32_t source_id, std::optional<std::string> callsign) {
    // revision：本次运行内单调递增（每次引擎进入 running 从 1 开始）。
    identity_ops_.push_back(engine_.upsert_radio_identity(source_id, ++identity_revision_, std::move(callsign)));
}

void ViewModel::on_engine_running() {
    // Initialize-UiNativeIdentitySync：预载缓存中的新鲜映射，再回放本次会话查到的结果。
    identity_revision_ = 0U;
    std::set<std::uint32_t> pushed;
    if (services_.identity.preload) {
        for (auto& m : services_.identity.preload()) {
            if (!m.callsign) continue;
            pushed.insert(m.source_id);
            callsigns_.emplace(m.source_id, *m.callsign);
            push_identity(m.source_id, std::move(m.callsign));
        }
    }
    for (const auto& [id, callsign] : callsigns_) {
        if (pushed.count(id) == 0U) push_identity(id, callsign);
    }
}

bool ViewModel::pump_startup_group_activation() {
    bool changed = false;
    bool state_transition_reported = false;
    const bool bm_connected = snapshot_->bm_link == BmLink::connected;
    const auto now = std::chrono::steady_clock::now();

    if (!startup_static_resolved_ && bm_connected) {
        // 等首次静态组读取结果，最多 10 秒；BM API 不可达时不阻塞动态组激活。
        if (!startup_static_wait_since_) startup_static_wait_since_ = now;
        if (now - *startup_static_wait_since_ >= 10s) resolve_startup_static();
    }
    if (!startup_group_activation_.started() && bm_connected && startup_static_resolved_) {
        if (startup_group_activation_.activate()) {
            startup_group_activation_status_ = fmt(
                tr(Str::startup_group_connected_fmt),
                static_cast<unsigned>(startup_group_activation_.stats().target_count));
            changed = true;
            state_transition_reported = true;
        }
    }

    switch (startup_group_activation_.observe_connection(bm_connected)) {
    case StartupGroupActivation::ConnectionChange::paused:
        startup_group_activation_status_ = fmt(
            tr(Str::startup_group_paused_fmt),
            static_cast<unsigned>(startup_group_activation_.remaining()),
            static_cast<unsigned>(startup_group_activation_.stats().locally_sent),
            static_cast<unsigned>(startup_group_activation_.stats().failed));
        changed = true;
        state_transition_reported = true;
        break;
    case StartupGroupActivation::ConnectionChange::resumed:
        startup_group_activation_status_ = fmt(
            tr(Str::startup_group_resumed_fmt),
            static_cast<unsigned>(startup_group_activation_.remaining()));
        changed = true;
        state_transition_reported = true;
        break;
    case StartupGroupActivation::ConnectionChange::none:
        break;
    }

    if (!startup_group_activation_.started()) return changed;
    if (startup_group_activation_.command_pending()) return changed;

    const auto decision = startup_group_activation_.next(bm_connected, now);
    if (decision.kind == StartupGroupActivation::DecisionKind::finished) {
        const auto previous = startup_group_activation_status_;
        update_startup_group_activation_status();
        return changed || previous != startup_group_activation_status_;
    }
    if (decision.kind == StartupGroupActivation::DecisionKind::wait) {
        if (!state_transition_reported) {
            const auto previous = startup_group_activation_status_;
            update_startup_group_activation_status();
            changed = changed || previous != startup_group_activation_status_;
        }
        return changed;
    }

    const ChannelKey key{decision.target.destination_id, dmr_call::CallKind::group, decision.target.slot};
    if (quick_call_pending_) {
        // 只能有一个 Quick Call future；如手动请求仍在途，按无发包的 Busy 等待处理。
        startup_group_activation_.complete(CommandStatus::busy, bm_connected, now);
        if (!state_transition_reported) {
            const auto previous = startup_group_activation_status_;
            update_startup_group_activation_status();
            changed = changed || previous != startup_group_activation_status_;
        }
        return changed;
    }

    quick_call_pending_ = key;
    startup_group_activation_last_target_ = key;
    track(Str::op_auto_quick_call, engine_.quick_call_join({key.id, key.slot}), [this, key](const CommandResult& r) {
        quick_call_pending_.reset();
        if (r.status == CommandStatus::accepted) {
            quick_call_sent_.insert(key);
            flash(fmt(tr(Str::startup_group_sent_fmt), key.id, static_cast<int>(key.slot)), false);
        }
        startup_group_activation_.complete(
            r.status, snapshot_->bm_link == BmLink::connected, std::chrono::steady_clock::now());
    });
    if (!state_transition_reported) {
        const auto previous = startup_group_activation_status_;
        update_startup_group_activation_status();
        changed = changed || previous != startup_group_activation_status_;
    }
    return true;
}

void ViewModel::update_startup_group_activation_status() {
    const auto& stats = startup_group_activation_.stats();
    if (!startup_group_activation_.started()) {
        startup_group_activation_status_ = fmt(
            tr(Str::startup_group_waiting_fmt),
            static_cast<unsigned>(stats.target_count),
            static_cast<unsigned>(stats.private_skipped),
            static_cast<unsigned>(stats.disconnect_group_skipped),
            static_cast<unsigned>(stats.duplicate_skipped),
            static_cast<unsigned>(stats.invalid_skipped),
            static_cast<unsigned>(stats.static_skipped));
        return;
    }
    if (startup_group_activation_.finished()) {
        startup_group_activation_status_ = fmt(
            tr(Str::startup_group_done_fmt),
            static_cast<unsigned>(stats.locally_sent),
            static_cast<unsigned>(stats.target_count),
            static_cast<unsigned>(stats.failed),
            static_cast<unsigned>(stats.busy_skipped),
            static_cast<unsigned>(stats.private_skipped),
            static_cast<unsigned>(stats.disconnect_group_skipped),
            static_cast<unsigned>(stats.duplicate_skipped),
            static_cast<unsigned>(stats.invalid_skipped),
            static_cast<unsigned>(stats.static_skipped));
        return;
    }
    if (startup_group_activation_.paused()) {
        startup_group_activation_status_ = fmt(
            tr(Str::startup_group_paused_fmt),
            static_cast<unsigned>(startup_group_activation_.remaining()),
            static_cast<unsigned>(stats.locally_sent),
            static_cast<unsigned>(stats.failed));
        return;
    }
    if (!startup_group_activation_.command_pending() && startup_group_activation_.retry_at()) {
        startup_group_activation_status_ = tr(Str::startup_group_busy);
        return;
    }
    startup_group_activation_status_ = fmt(
        tr(Str::startup_group_progress_fmt),
        static_cast<unsigned>(stats.locally_sent),
        static_cast<unsigned>(stats.target_count),
        static_cast<unsigned>(stats.failed),
        static_cast<unsigned>(startup_group_activation_.remaining()));
}

void ViewModel::set_channel_page(std::size_t page) { channel_page_ = std::min(page, channel_page_count() - 1U); }

void ViewModel::set_history_page(std::size_t page) { history_page_ = std::min(page, history_page_count() - 1U); }

void ViewModel::select_history(std::optional<std::size_t> index) { selected_history_ = index; }

} // namespace wirex::gui
