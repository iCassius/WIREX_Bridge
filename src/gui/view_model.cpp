#include "view_model.hpp"

#include "config_bridge.hpp"

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
            flash(fmt(tr(Str::settings_save_failed), error.c_str()), true);
        }
    }
    // R126 决定：运行界面固定中文，ui.language 只读取不改写。启用切换时把 kHonorConfigLanguage 改为 true。
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
    if (services_.cat.state) cat_ = services_.cat.state();
    last_phase_ = snapshot_->phase;
    static_sync(); // 已有 API Key 与设备 ID 时读取 BM 静态组
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
        if (done) done(r);
        report(op, r);
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
        if (cat.revision != cat_.revision) {
            cat_ = std::move(cat);
            changed = true;
        }
    }
    if (!transient_text_.empty() && !transient_visible()) {
        transient_text_.clear();
        changed = true;
    }
    return changed;
}

std::optional<std::uint32_t> ViewModel::idle_timeout_ms() const {
    // 命令等待中：轮询 future（引擎完成时也会唤醒，这里只作兜底）。
    if (!pending_.empty() || static_.busy) return 100U;
    // 有来话时显示通话时长，需要每秒刷新。
    if (snapshot_->active_rx_call) return 1000U;
    if (!transient_text_.empty()) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(transient_until_ - std::chrono::steady_clock::now());
        return static_cast<std::uint32_t>(std::max<long long>(left.count(), 0) + 10);
    }
    return std::nullopt;
}

// ---------------------------------------------------------------- 事件

std::chrono::system_clock::time_point ViewModel::to_wall(std::uint64_t engine_ms) const {
    // 引擎时间戳为单调时钟毫秒；按当前 steady/system 差值换算成墙钟时间用于显示。
    // TODO(engine): 若真实引擎的单调时钟原点不是 steady_clock，需在 Snapshot 中提供换算基准。
    const auto steady_now = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    const auto age = steady_now >= engine_ms ? steady_now - engine_ms : 0U;
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
    case engine::EventKind::warning:
        if (!event.text.empty()) flash(event.text, event.kind == engine::EventKind::warning);
        break;
    case engine::EventKind::fatal:
        flash(event.text.empty() ? std::string(tr(Str::phase_failed)) : event.text, true);
        break;
    case engine::EventKind::rx_call_ended:
    case engine::EventKind::tx_started:
    case engine::EventKind::tx_ended:
    case engine::EventKind::bm_link_changed:
        break;
    }
}

void ViewModel::flash(std::string text, bool failed) {
    transient_text_ = std::move(text);
    transient_failed_ = failed;
    transient_until_ = std::chrono::steady_clock::now() + kTransientDuration;
}

bool ViewModel::transient_visible() const {
    return !transient_text_.empty() && std::chrono::steady_clock::now() < transient_until_;
}

void ViewModel::report(Str op, const CommandResult& r) {
    const bool ok = r.status == CommandStatus::accepted || r.status == CommandStatus::idempotent;
    // 成功由状态本身体现；Quick Call 的本机发送结果由 quick_call_result 事件文本提示。
    if (ok && op != Str::op_cat) return;
    if (r.detail.empty() || ok) {
        flash(fmt(tr(Str::result_fmt), tr(op), command_status_text(r.status)), !ok);
    } else {
        flash(fmt(tr(Str::result_fmt_detail), tr(op), command_status_text(r.status), r.detail.c_str()), true);
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
    if (!services_.config.make_start_config) {
        flash(tr(Str::engine_unavailable), true);
        return;
    }
    std::string error;
    auto sc = services_.config.make_start_config(config_, error);
    if (!sc) {
        flash(fmt(tr(Str::result_fmt), tr(Str::op_start), error.c_str()), true);
        return;
    }
    if (!error.empty()) flash(error, true); // 参数可用但有提示（例如 --fake 下真实设备检查未通过）
    // make_start_config 已按配置生成 RX/TX 策略；这里叠加本次会话的临时屏蔽状态。
    sc->rx_policy = build_rx_policy();
    sc->radio_playback_gain_milli = gain_milli(playback_step);
    sc->mic_transmit_gain_milli = gain_milli(transmit_step);
    sc->bm_start_disconnected = true;
    track(Str::op_start, engine_.start(std::move(*sc)));
}

void ViewModel::stop() {
    if (pending(Str::op_stop)) return;
    track(Str::op_stop, engine_.stop());
}

void ViewModel::toggle_bm() {
    if (pending(Str::op_bm)) return;
    const bool enable = !snapshot_->bm_requested_enabled;
    if (enable && config_.bm_password.empty()) {
        flash(tr(Str::password_empty), true);
        return;
    }
    track(Str::op_bm, engine_.set_bm_connection(enable, snapshot_->bm_connection_revision));
}

// Get-UiNativeRxPolicyForChannels：屏蔽 = 从 allow 列表中移除（Router 拒绝同时出现在 allow 与 block 的组）。
talkgroup_routing::RxPolicy ViewModel::build_rx_policy() const {
    std::set<std::string> muted;
    for (const auto& k : muted_) muted.insert(config_bridge::channel_key(k.id, k.kind, k.slot));
    return config_bridge::make_rx_policy(config_.channels, muted, config_.dmr_id, config_.blocked_source_ids);
}

void ViewModel::push_rx_policy() {
    if (snapshot_->phase != Phase::running) return; // 未运行时只改配置，启动时一并下发
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
    entry.name = config_bridge::known_channel_name(id, entry.kind);
    const auto k = key_of(entry);
    if (std::any_of(config_.channels.begin(), config_.channels.end(), [&](const auto& e) { return key_of(e) == k; })) {
        flash(tr(Str::channel_exists), true);
        return;
    }
    config_.channels.push_back(entry);
    add_channel_id.clear();
    set_channel_page(channel_page_count() - 1U);
    persist();
    push_rx_policy();
}

void ViewModel::quick_call(const ChannelKey& key) {
    if (quick_call_pending_ || key.kind != dmr_call::CallKind::group) return;
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

void ViewModel::set_history_target() {
    if (!selected_history_ || *selected_history_ >= history_.size()) return;
    const auto& call = history_[*selected_history_].call;
    ChannelKey key{call.kind == dmr_call::CallKind::group ? call.destination_id : call.source_id, call.kind, call.slot};
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
    services::CatSettings s;
    s.main_mode = static_cast<services::CatMode>(std::clamp(cat_form.mode_index, 0, 3));
    double mhz = 0.0;
    if (!cat_form.frequency_mhz.empty()) {
        const auto [ptr, ec] = std::from_chars(cat_form.frequency_mhz.data(),
                                               cat_form.frequency_mhz.data() + cat_form.frequency_mhz.size(), mhz);
        if (ec != std::errc{} || mhz <= 0.0 || mhz > 1000.0) {
            flash(fmt(tr(Str::result_fmt), tr(Str::op_cat), tr(Str::st_invalid)), true);
            return;
        }
        (void)ptr;
    }
    s.main_frequency_hz = static_cast<std::uint64_t>(std::llround(mhz * 1'000'000.0));
    s.power_w = kPowerWatts[std::clamp(cat_form.power_index, 0, 4)];
    services_.cat.apply(s, [this](CommandResult r) { post_to_ui([this, r = std::move(r)]() { report(Str::op_cat, r); }); });
}

void ViewModel::refresh_devices() {
    if (services_.devices.enumerate) devices_ = services_.devices.enumerate();
}

bool ViewModel::save_config(const services::GuiConfig& next, std::string& error) {
    if (services_.config.save && !services_.config.save(next, error)) return false;
    config_ = next;
    config_.gateway_id = services::effective_gateway_id(next);
    flash(tr(Str::settings_saved), false);
    static_sync(); // 设备 ID 或 API Key 变化时刷新静态组（Sync-BmManagementUiIdentity）
    return true;
}

// ---------------------------------------------------------------- BM 静态组（BmManagementUi.ps1）

bool ViewModel::is_static_channel(const services::ChannelEntry& entry) const {
    // Test-UiBmStaticChannelReadback：同 TG 同时隙；API slot 0（DMO）只在设备状态 4 且该 TG 只有一个频道时对应。
    if (!static_.loaded || entry.kind != dmr_call::CallKind::group) return false;
    bool slot0 = false;
    for (const auto& g : static_.groups) {
        if (g.talkgroup != entry.id) continue;
        if (g.slot == static_cast<int>(entry.slot)) return true;
        if (g.slot == 0) slot0 = true;
    }
    if (!slot0 || !static_.add_slot || *static_.add_slot != 0) return false;
    const auto same_tg = std::count_if(config_.channels.begin(), config_.channels.end(), [&](const auto& e) {
        return e.kind == dmr_call::CallKind::group && e.id == entry.id;
    });
    return same_tg == 1;
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
            }
            if (static_.refresh_pending) {
                static_.refresh_pending = false;
                static_refresh();
            }
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
                if (!r.failed) static_.tg_input.clear();
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
                                         [this, device](services::BmApiResult r) {
                                             post_to_ui([this, device, r = std::move(r)]() {
                                                 static_.busy = false;
                                                 if (device == bm_device_id()) static_apply(r, true);
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

void ViewModel::set_channel_page(std::size_t page) { channel_page_ = std::min(page, channel_page_count() - 1U); }

void ViewModel::set_history_page(std::size_t page) { history_page_ = std::min(page, history_page_count() - 1U); }

void ViewModel::select_history(std::optional<std::size_t> index) { selected_history_ = index; }

} // namespace wirex::gui
