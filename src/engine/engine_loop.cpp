// 引擎主循环：由 R127 probe_main.cpp run_bm_bridge 搬入。设备访问经 Devices 接口，
// 控制命令从 Shared 命令队列取出（原 control-v2 Dispatcher 回调的同一段逻辑），
// 状态报告经 DiagnosticsHooks 输出，状态快照与事件经 Shared 发布。
// 语义保持不变：事件名、失败原因与收尾顺序和 R127 一致。

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

#include "engine_internal.hpp"

#include "wirex/bm_connection_control.hpp"
#include "wirex/bm_network_metadata.hpp"
#include "wirex/bm_session.hpp"
#include "wirex/bm_test_profile.hpp"
#include "wirex/bm_voice_pipeline.hpp"
#include "wirex/audio_peak_window.hpp"
#include "wirex/direct_frame.hpp"
#include "wirex/dmrd.hpp"
#include "wirex/hri_lcd_identity_candidate.hpp"
#include "wirex/hri_ptt_gate.hpp"
#include "wirex/hri_session.hpp"
#include "wirex/hri_stream_session.hpp"
#include "wirex/hri_t_payload.hpp"
#include "wirex/pcm_gain.hpp"
#include "wirex/quick_call.hpp"
#include "wirex/radio_identity_cache.hpp"
#include "wirex/routing_state.hpp"
#include "wirex/session_timing.hpp"
#include "wirex/talkgroup_routing.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace wirex::engine::detail {
namespace {

std::string summarize_rx_policy(const wirex::talkgroup_routing::RxPolicy& policy, std::uint64_t revision)
{
    std::string text = "rev=" + std::to_string(revision) +
        (policy.group_mode == wirex::talkgroup_routing::GroupMode::all_delivered ? " groups=all" : " groups=");
    for (const auto& g : policy.allowed_groups) {
        text += std::to_string(g.destination_id) + "/TS" + std::to_string(static_cast<unsigned>(g.slot)) + " ";
    }
    text += "private=";
    for (const auto& p : policy.private_peers) {
        text += std::to_string(p.source_id) + "/TS" + std::to_string(static_cast<unsigned>(p.slot)) + " ";
    }
    text += "blocked_sources=" + std::to_string(policy.blocked_source_ids.size());
    return text;
}

constexpr std::uint64_t bm_bridge_window_ms = 120000U;
constexpr std::uint64_t bm_bridge_cleanup_ms = 3000U;
constexpr std::uint64_t snapshot_heartbeat_ms = 100U;
constexpr auto audio_endpoint_wait = std::chrono::seconds{30};

struct ProfileSecretGuard {
    bm::Profile& profile;
    ~ProfileSecretGuard() { (void)wipe_secret(profile.password); }
};

bool random_stream_id(std::array<std::uint8_t, 4U>& stream_id) noexcept
{
    return BCryptGenRandom(nullptr, stream_id.data(), static_cast<ULONG>(stream_id.size()),
        BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0;
}

float peak_unit(std::uint32_t peak) noexcept
{
    return static_cast<float>(std::min<std::uint32_t>(peak, 32768U)) / 32768.0F;
}

BmLink bm_link_from(const bm_connection::Snapshot& connection) noexcept
{
    if (!connection.requested_enabled) {
        return connection.error == bm_connection::Error::none ? BmLink::disabled : BmLink::failed;
    }
    if (connection.resolving) return BmLink::resolving;
    switch (connection.bm_state) {
    case bm::State::ready: return BmLink::connected;
    case bm::State::backoff: return BmLink::backoff;
    case bm::State::waiting_login_ack:
    case bm::State::waiting_auth_ack:
    case bm::State::waiting_config_ack:
    case bm::State::waiting_options_ack: return BmLink::connecting;
    case bm::State::idle:
    case bm::State::stopped:
        return connection.error == bm_connection::Error::none ? BmLink::connecting : BmLink::failed;
    }
    return BmLink::failed;
}

const char* hri_stop_reason_name(wirex::hri_session::StopReason reason) noexcept
{
    using wirex::hri_session::StopReason;
    switch (reason) {
    case StopReason::none: return "hri_session_stopped_unknown";
    case StopReason::invalid_configuration: return "hri_session_invalid_configuration";
    case StopReason::invalid_y_template: return "y_template_invalid";
    case StopReason::already_started: return "hri_session_already_started";
    case StopReason::time_overflow: return "hri_session_time_overflow";
    case StopReason::clock_regressed: return "hri_session_clock_regressed";
    case StopReason::deadline: return "hri_session_deadline";
    case StopReason::version_timeout: return "hri_version_timeout";
    case StopReason::cancelled: return "hri_session_cancelled";
    case StopReason::malformed_record: return "hri_malformed_record";
    case StopReason::version_mismatch: return "hri_version_mismatch";
    case StopReason::unexpected_version_record: return "hri_unexpected_version_record";
    case StopReason::receive_limit: return "hri_receive_limit";
    case StopReason::record_limit: return "hri_record_limit";
    case StopReason::transmit_limit: return "hri_transmit_limit";
    case StopReason::y_write_limit: return "hri_y_write_limit";
    case StopReason::y_ack_timeout: return "hri_y_ack_timeout";
    case StopReason::x_ack_limit: return "hri_x_ack_limit";
    case StopReason::write_failed: return "hri_serial_write_failed";
    case StopReason::unexpected_write_completion: return "hri_unexpected_write_completion";
    case StopReason::incomplete_record: return "hri_incomplete_record";
    case StopReason::pending_write_limit: return "hri_pending_write_limit";
    case StopReason::caller_stopped: return "hri_session_stopped";
    case StopReason::transport_failure: return "hri_transport_failure";
    case StopReason::audio_failure: return "hri_audio_failure";
    case StopReason::report_failure: return "hri_report_failure";
    }
    return "hri_session_stopped_unknown";
}

CommandStatus policy_status(talkgroup_routing::PolicyUpdateStatus status) noexcept
{
    using talkgroup_routing::PolicyUpdateStatus;
    switch (status) {
    case PolicyUpdateStatus::applied: return CommandStatus::accepted;
    case PolicyUpdateStatus::revision_conflict: return CommandStatus::stale_revision;
    case PolicyUpdateStatus::invalid_policy: return CommandStatus::invalid;
    case PolicyUpdateStatus::revision_exhausted:
    case PolicyUpdateStatus::resource_failure: return CommandStatus::failed;
    }
    return CommandStatus::failed;
}

const char* policy_detail(talkgroup_routing::PolicyUpdateStatus status) noexcept
{
    using talkgroup_routing::PolicyUpdateStatus;
    switch (status) {
    case PolicyUpdateStatus::applied: return "";
    case PolicyUpdateStatus::revision_conflict: return "revision_conflict";
    case PolicyUpdateStatus::invalid_policy: return "invalid_policy";
    case PolicyUpdateStatus::revision_exhausted: return "revision_exhausted";
    case PolicyUpdateStatus::resource_failure: return "resource_failure";
    }
    return "invalid_policy";
}

} // namespace

CommandResult run_loop(Shared& shared, StartConfig config)
{
    using Clock = std::chrono::steady_clock;
    using StreamSession = wirex::hri_stream_session::Session;
    using StreamAction = wirex::hri_stream_session::Action;
    using StreamActionKind = wirex::hri_stream_session::ActionKind;
    using StreamPhase = wirex::hri_stream_session::Phase;
    using StreamReason = wirex::hri_stream_session::Reason;
    using Pipeline = wirex::bm_voice::BmVoicePipeline;
    using PipelineEventKind = wirex::bm_voice::EventKind;
    using HriPhase = wirex::hri_session::Phase;
    using PttAction = wirex::hri_ptt_gate::Action;
    using PttGate = wirex::hri_ptt_gate::Gate;
    using PttLevel = wirex::hri_ptt_gate::Level;

    auto& hooks = config.diagnostics;
    auto& profile = config.bm.profile;
    ProfileSecretGuard secret_guard{profile};
    auto& devices = *shared.devices;
    const bool manual_ptt = config.manual_ptt;
    const bool continuous_run = !manual_ptt;
    const bool bm_start_disconnected = config.bm_start_disconnected;
    bool launch_transmit_allowed = config.tx_policy.transmit_enabled;
    std::uint32_t radio_playback_gain_milli = config.radio_playback_gain_milli;
    std::uint32_t mic_transmit_gain_milli = config.mic_transmit_gain_milli;
    std::uint64_t audio_gains_revision = 0U;
    std::uint64_t audio_endpoints_revision = 0U;
    wirex::audio_meter::PeakWindow rx_peak_window;
    wirex::audio_meter::PeakWindow tx_peak_window;
    if (!pcm_gain::supported_gain(radio_playback_gain_milli) || !pcm_gain::supported_gain(mic_transmit_gain_milli)) {
        return CommandResult{CommandStatus::invalid, 0U, "audio_gain_out_of_range"};
    }
    // 原 CLI call_template：本机 source、gateway 与 color code 取自 profile；目标来自 TX 策略。
    wirex::dmr_call::CallConfig call_template{};
    call_template.source_id = config.local_source_id;
    call_template.gateway_id = profile.gateway_id;
    call_template.color_code = profile.color_code;
    call_template.destination_id = config.tx_policy.target.destination_id;
    call_template.kind = config.tx_policy.target.kind;
    call_template.slot = config.tx_policy.target.slot;

    auto console = [&](std::string_view text, bool error_stream = false) {
        if (!hooks.console) return;
        try { hooks.console(text, error_stream); } catch (...) {}
    };

    BridgeCounters counters{};
    counters.audio_endpoints_validated = true;
    counters.rx_output_gain_milli = radio_playback_gain_milli;
    counters.tx_input_gain_milli = mic_transmit_gain_milli;

    std::unique_ptr<wirex::bm_connection::ConnectionControl> bm_connection;
    try {
        bm_connection = std::make_unique<wirex::bm_connection::ConnectionControl>(
            std::move(profile), std::move(config.bm.master_host), config.bm.master_port);
    } catch (...) {
        console("无法创建 BM 连接管理器；没有打开设备。\n", true);
        return CommandResult{CommandStatus::failed, 0U, "bm_connection_allocation_failed"};
    }
    auto& bm_session = bm_connection->session();
    auto& transport = bm_connection->transport();
    std::function<CommandResult(const wirex::talkgroup_routing::GroupRoute&)> process_quick_call;
    PttGate ptt_gate;
    std::function<void(PttAction, std::string_view)> handle_ptt_gate_action;
    std::function<void()> synchronize_ptt_gate;
    std::function<void(const wirex::hri_session::PttObservation&)> process_ptt_observation;
    std::string failure_reason;
    bool failed = false;
    bool status_report_failed = false;
    bool shutdown_requested = false;
    bool cleanup_forced = false;
    bool hri_active = false;
    bool hri_ready = false;
    bool radio_input_open = false;
    bool radio_output_open = false;
    bool radio_output_playback_blocked = false;
    // CloseHandle failure is terminal for the wrapper's raw handle ownership: WindowsSerialPort
    // relinquishes the value before CloseHandle, so retrying could target a recycled handle.
    // Keep this latch until runtime shutdown and fail closed for a new HRI attach.
    bool radio_serial_close_unconfirmed = false;
    wirex::bm_local_playback::Session local_playback;
    std::string local_audio_error = config.local_audio_start_error;
    bool local_output_close_pending = false;
    std::uint64_t discarded_local_output_generation = 0U;
    bool pending_receive_start = false;
    bool pending_receive_ended = false;
    bool pending_playback_drain = false;
    bool downlink_blocked = false;
    bool bm_disconnect_cleanup_started = false;
    bool bm_ptt_release_required = false;
    bool bm_disconnect_timeout_reported = false;
    bool bm_ever_requested = bm_connection->snapshot().requested_enabled;
    bool bm_profile_reconfigure_required = false;
    std::optional<Clock::time_point> bm_disconnect_deadline;
    std::string shutdown_reason;
    std::optional<Clock::time_point> cleanup_deadline;
    const auto run_started = Clock::now();
    auto elapsed_ms = [&]() -> std::uint64_t {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - run_started).count();
        return elapsed < 0 ? 0U : static_cast<std::uint64_t>(elapsed);
    };
    auto set_failure = [&](std::string_view reason) {
        if (failure_reason.empty()) failure_reason.assign(reason);
        failed = true;
    };
    std::vector<std::uint8_t> y_body;
    bool radio_requested = config.start_radio && !config.hri_port.empty();
    std::string radio_error = config.radio_start_error;
    bool template_loaded = false;
    if (radio_requested) {
        try { template_loaded = devices.load_hri_template(config.hri_body_file, y_body); } catch (...) {}
        if (!template_loaded) {
            radio_requested = false;
            radio_error = "y_template_invalid";
        }
    } else if (radio_error.empty() && config.start_radio) {
        radio_error = "hri_port_missing";
    }
    const auto start_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    const auto stop_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(0, 1, 9U);
    const auto start_frame_result = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(start_body.begin(), start_body.end())});
    const auto stop_frame_result = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(stop_body.begin(), stop_body.end())});
    if (!start_frame_result || !stop_frame_result) {
        console("Could not build the pinned HRI speaker start/stop candidates.\n", true);
        return CommandResult{CommandStatus::failed, 0U, "hri_stream_candidates_failed"};
    }

    std::unique_ptr<Pipeline> pipeline;
    std::unique_ptr<StreamSession> stream_session;
    std::unique_ptr<AudioInput> radio_input;
    std::unique_ptr<AudioOutput> radio_output;
    std::unique_ptr<wirex::hri_session::Session> hri_session;
    wirex::radio_identity_cache::Cache source_identity_cache;
    wirex::routing_state::ObservedSources observed_sources;
    try {
        pipeline = std::make_unique<Pipeline>();
        stream_session = std::make_unique<StreamSession>(start_frame_result.bytes, stop_frame_result.bytes,
            wirex::hri_stream_session::Config{wirex::hri_stream_session::default_start_record_timeout_ms,
                wirex::hri_stream_session::default_stop_record_timeout_ms,
                wirex::hri_stream_session::max_call_window_ms});
        if (radio_requested) {
            hri_session = std::make_unique<wirex::hri_session::Session>(std::move(y_body),
                wirex::hri_session::Config{wirex::session_timing::active_window_ms, continuous_run});
        }
        radio_input = devices.make_audio_input(config.audio);
        radio_output = devices.make_audio_output(config.audio);
    } catch (...) {
        radio_input.reset();
        radio_output.reset();
    }
    if (!pipeline || !stream_session || !radio_input || !radio_output) {
        console("Bridge software state allocation failed before devices were opened.\n", true);
        return CommandResult{CommandStatus::failed, 0U, "software_state_allocation_failed"};
    }
    if (pipeline->enable_routing(call_template.source_id, config.rx_policy,
                                 config.tx_policy) != wirex::bm_voice::Error::none) {
        console("Could not enable Router arbitration for this BM bridge configuration.\n", true);
        return CommandResult{CommandStatus::invalid, 0U, "routing_policy_invalid"};
    }
    counters.media_owner = "idle";
    auto report_rx_policy = [&](const wirex::talkgroup_routing::RxPolicy& policy, std::uint64_t revision) {
        if (!hooks.rx_policy) return;
        try { hooks.rx_policy(summarize_rx_policy(policy, revision)); } catch (...) {}
    };
    report_rx_policy(config.rx_policy, 1U);
    auto live_tx_permission = [&]() {
        const auto* current = pipeline->routed_tx_policy();
        return current != nullptr ? current->transmit_enabled : launch_transmit_allowed;
    };
    auto live_routed_voice_permission = [&]() {
        return live_tx_permission() && pipeline->routed_tx_voice_permitted();
    };

    if (!bm_start_disconnected) {
        const auto master = config.resolved_master.value_or(bm::Endpoint{});
        if (!config.resolved_master || !bm_connection->start_initial_session(master, 0U)) {
            // BM 与电台分别启动。保留 BM 错误在 ConnectionControl 快照中，继续尝试 HRI。
            bm_connection->abort_initial_startup(0U);
        }
    }

    {
        const auto early = shared.stop_state();
        if (early.requested) {
            bm_connection->abort_initial_startup(0U);
            return CommandResult{CommandStatus::accepted, 0U, "stopped_before_devices_opened"};
        }
    }
    std::unique_ptr<SerialPort> port;
    wirex::hri_session::Snapshot hri_state{};
    if (radio_requested) {
        std::string open_failure;
        try { port = devices.open_serial(config.hri_port, open_failure); } catch (...) { port.reset(); }
        if (!port) {
            radio_error = open_failure.empty() ? "serial_open_or_configure_failed" : open_failure;
            radio_requested = false;
            hri_session.reset();
        } else {
            hri_active = true;
        }
    }
    if (!bm_start_disconnected && bm_connection->snapshot().requested_enabled &&
        !bm_connection->open_initial_transport()) {
        // BM transport 故障只使 BM 保持断开；HRI 仍可进入独立运行态。
        (void)bm_connection->snapshot();
    }

    if (port == nullptr) {
        if (!local_audio_error.empty() || config.audio.expected_wave_out_endpoint_id.empty()) {
            local_playback.output_unavailable(
                wirex::bm_local_playback::OutputError::selection_unavailable);
            if (local_audio_error.empty()) local_audio_error = "尚未选择唯一的 WaveOut 输出设备。";
        } else if (radio_output->open()) {
            radio_output_open = radio_output->is_open();
            local_playback.output_available();
            local_audio_error.clear();
        } else {
            radio_output_open = radio_output->is_open();
            local_playback.output_unavailable(wirex::bm_local_playback::OutputError::open_failed);
            local_audio_error = "waveout_open_failed";
        }
        local_playback.set_environment(false, radio_output_open && !radio_output_playback_blocked);
    }

    auto emit_status = [&](std::string_view event) -> bool {
        if (!hooks.status) return true;
        const auto bm_snapshot = bm_session.snapshot();
        const auto receive_snapshot = pipeline->snapshot();
        const auto gate_snapshot = ptt_gate.snapshot();
        try {
            return hooks.status(StatusRecord{event, elapsed_ms(), bm_snapshot, hri_state,
                gate_snapshot, counters, receive_snapshot});
        } catch (...) {
            return false;
        }
    };

    if (radio_error.size() > 256U) radio_error.resize(256U);

    // ---------- 快照与事件发布 ----------
    std::optional<CallInfo> published_rx_call;
    bool published_tx_active = false;
    BmLink published_bm_link = BmLink::disabled;
    std::uint64_t last_published_ms = 0U;
    bool publish_dirty = true;
    std::optional<wirex::engine::FilteredTraffic> last_filtered;  // 最近一次策略过滤的 BM 流（心跳快照携带）
    auto push_event = [&](EventKind kind, std::string text = {}, std::optional<CallInfo> call = std::nullopt,
                          std::string end_reason = {}) {
        Event event{};
        event.kind = kind;
        event.at_ms = elapsed_ms();
        event.call = std::move(call);
        event.end_reason = std::move(end_reason);
        event.text = std::move(text);
        shared.push_event(std::move(event));
    };
    auto build_snapshot = [&]() {
        const auto local_audio_state = local_playback.snapshot();
        const bool local_output_usable = radio_output_open && !radio_output_playback_blocked &&
            local_audio_state.output_error == wirex::bm_local_playback::OutputError::none;
        local_playback.set_environment(hri_ready && port != nullptr, local_output_usable);
        Snapshot next{};
        next.clock_origin_ms = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(run_started.time_since_epoch()).count());
        next.phase = shutdown_requested ? Phase::stopping : Phase::running;
        next.serial_open = port != nullptr;
        next.hri_port = port != nullptr ? config.hri_port : std::wstring{};
        next.hri_ready = hri_ready;
        next.radio_error = radio_error;
        next.wave_in_open = radio_input_open;
        next.wave_out_open = radio_output_open;
        next.wave_in_endpoint_id = config.audio.expected_wave_in_endpoint_id;
        next.wave_out_endpoint_id = config.audio.expected_wave_out_endpoint_id;
        next.audio_endpoints_revision = audio_endpoints_revision;
        next.local_audio = local_playback.snapshot();
        next.local_audio_error = local_audio_error;
        const auto connection = bm_connection->snapshot();
        next.bm_link = bm_link_from(connection);
        next.bm_requested_enabled = connection.requested_enabled;
        next.bm_connection_revision = connection.revision;
        next.bm_error = wirex::bm_connection::error_name(connection.error);
        const auto routing = pipeline->routing_snapshot();
        next.media_owner = routing.router.media_owner;
        next.rx_policy_revision = routing.router.rx_policy_revision;
        next.tx_policy_revision = routing.router.tx_policy_revision;
        if (const auto* tx = pipeline->routed_tx_policy()) next.tx_target = tx->target;
        next.active_rx_call = published_rx_call;
        next.tx_active = pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle;
        next.radio_playback_gain_milli = radio_playback_gain_milli;
        next.mic_transmit_gain_milli = mic_transmit_gain_milli;
        next.audio_gains_revision = audio_gains_revision;
        const auto meter_now = Clock::now();
        next.levels.rx_peak = rx_peak_window.value(meter_now);
        next.levels.tx_peak = tx_peak_window.value(meter_now);
        next.levels.rx_clipped_samples = counters.rx_pcm_clipped_samples;
        next.levels.tx_clipped_samples = counters.tx_pcm_clipped_samples;
        next.counters.calls_started = counters.calls_started;
        next.counters.calls_ended = counters.calls_ended;
        next.counters.rejected_calls = counters.rejected_calls;
        next.counters.rx_datagrams = counters.rx_datagrams;
        next.counters.tx_datagrams = counters.tx_datagrams;
        next.counters.reconnects = counters.reconnects;
        next.counters.ptt_tx_starts = counters.ptt_tx_starts;
        next.counters.ptt_tx_timeouts = counters.ptt_tx_timeouts;
        next.counters.rx_filtered_datagrams = counters.rx_filtered_datagrams;
        next.last_filtered = last_filtered;
        {
            const auto bm_now = bm_session.snapshot();
            next.network.rtt_valid = bm_now.rtt_valid;
            next.network.rtt_last_ms = bm_now.rtt_last_ms;
            next.network.rtt_avg_ms = bm_now.rtt_avg_ms;
            next.network.rtt_min_ms = bm_now.rtt_min_ms;
            next.network.rtt_max_ms = bm_now.rtt_max_ms;
            next.network.rtt_samples = bm_now.rtt_sample_count;
            const auto& sequence = pipeline->snapshot().dmrd_sequence;
            next.network.session_loss_valid = sequence.session_valid;
            next.network.session_expected = sequence.session_expected;
            next.network.session_missing = sequence.session_missing;
            next.network.call_loss_valid = sequence.call_valid;
            next.network.call_expected = sequence.call_expected;
            next.network.call_missing = sequence.call_missing;
        }
        next.bm_state = connection.bm_state;
        next.hri_phase = hri_state.phase;
        const auto hri_stream = stream_session->snapshot();
        next.hri_t3_record_observed = hri_stream.start_t_record_observed;
        next.hri_t0_record_observed = hri_stream.stop_t_record_observed;
        next.bm_transport_open = connection.transport_open;
        next.bm_resolving = connection.resolving;
        if (failed) next.failure_reason = failure_reason;
        const auto* rx = pipeline->routed_rx_policy();
        const auto* tx = pipeline->routed_tx_policy();
        if (rx != nullptr && tx != nullptr) {
            next.routing_json = wirex::routing_state::routing_json(
                routing, call_template.source_id, *rx, *tx, observed_sources);
        }
        return next;
    };
    // 每轮循环末尾调用：比较离散状态并产生事件；状态有变化或距上次发布 ≥100 ms 时发布新快照。
    auto publish_if_needed = [&]() {
        const bool tx_now = pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle;
        if (tx_now != published_tx_active) {
            published_tx_active = tx_now;
            push_event(tx_now ? EventKind::tx_started : EventKind::tx_ended);
            publish_dirty = true;
        }
        const auto link = bm_link_from(bm_connection->snapshot());
        if (link != published_bm_link) {
            published_bm_link = link;
            push_event(EventKind::bm_link_changed);
            publish_dirty = true;
        }
        const auto now_ms = elapsed_ms();
        if (!publish_dirty && now_ms - last_published_ms < snapshot_heartbeat_ms) return;
        shared.publish(build_snapshot());
        last_published_ms = now_ms;
        publish_dirty = false;
    };

    auto status = [&](std::string_view event) {
        publish_dirty = true;
        if (status_report_failed) return;
        const auto bm_connection_state = bm_connection->snapshot();
        counters.hri_serial_open = port != nullptr;
        counters.hri_ready = hri_ready;
        counters.hri_y_zero_ready = hri_state.y_zero_acknowledged;
        counters.wavein_open = radio_input_open;
        counters.waveout_open = radio_output_open;
        counters.bm_requested_enabled = bm_connection_state.requested_enabled;
        counters.bm_connection_revision = bm_connection_state.revision;
        counters.bm_transport_open = bm_connection_state.transport_open;
        counters.bm_resolving = bm_connection_state.resolving;
        counters.bm_connection_error = wirex::bm_connection::error_name(bm_connection_state.error);
        const auto routing = pipeline->routing_snapshot();
        counters.media_owner = media_owner_name(routing.router.media_owner);
        if (routing.active_rx_mapping) {
            counters.rx_router_generation = routing.active_rx_mapping->router_generation;
            counters.rx_pipeline_generation = routing.active_rx_mapping->pipeline_generation;
        } else if (routing.stopping_rx_mapping) {
            counters.rx_router_generation = routing.stopping_rx_mapping->router_generation;
            counters.rx_pipeline_generation = routing.stopping_rx_mapping->pipeline_generation;
        }
        if (routing.router.active_tx_lease) {
            counters.tx_lease_id = routing.router.active_tx_lease->id;
        }
        if (!emit_status(event)) {
            status_report_failed = true;
            set_failure("status_report_write_failed");
            console("运行状态报告写入或刷新失败；将执行有界收尾并以退出码 2 结束。\n", true);
            push_event(EventKind::warning, "运行状态报告写入失败");
        }
    };
    if (port == nullptr) {
        status(radio_output_open ? "bm_local_playback_output_ready"
                                 : "bm_local_playback_output_unavailable");
    }
    auto record_bm_disconnect_media_error = [&](std::string_view reason) {
        if (bm_connection->disable_pending()) {
            bm_connection->note_media_cleanup_timeout();
            bm_disconnect_timeout_reported = true;
            return;
        }
        set_failure(reason);
    };

    auto clear_lcd_source_identity = [&]() {
        counters.lcd_source_identity_prepared = false;
        counters.lcd_source_identity_source_id = 0U;
        counters.lcd_source_identity_generation = 0U;
        counters.lcd_source_identity_label.clear();
        counters.lcd_source_identity_label_kind = "none";
        counters.lcd_source_identity_cache_revision = 0U;
        counters.lcd_source_identity_serial_write_state = "not_sent";
    };

    std::uint64_t next_runtime_snapshot_ms = 1000U;

    auto last_logged_bm_snapshot = bm_session.snapshot();
    auto log_bm_transition = [&](std::string_view event) {
        const auto current = bm_session.snapshot();
        if (current.state == last_logged_bm_snapshot.state &&
            current.last_failure == last_logged_bm_snapshot.last_failure &&
            current.consecutive_failures == last_logged_bm_snapshot.consecutive_failures) return;
        status(event);
        last_logged_bm_snapshot = current;
    };

    bool serial_failed = false;
    bool radio_fault_pending = false;
    std::string radio_fault_reason;
    auto serial_trace = [&](bool tx, const std::uint8_t* data, std::size_t size) {
        if (!hooks.serial || data == nullptr || size == 0U) return;
        const std::uint8_t record_type = (size >= 2U && data[0] == 0x01U) ? data[1] : 0U;
        try { hooks.serial(tx, record_type, size, elapsed_ms()); } catch (...) {}
    };
    auto serial_write = [&](const std::uint8_t* data, std::size_t size) {
        const bool ok = port != nullptr && port->write_all(data, size);
        if (ok) serial_trace(true, data, size);
        return ok;
    };
    // GUI 事件：来话在 HRI T3 准入时开始，在 call_finished 或任何收尾时结束。
    auto finish_published_rx_call = [&](std::string_view reason) {
        if (!published_rx_call) return;
        push_event(EventKind::rx_call_ended, {}, published_rx_call, std::string(reason));
        published_rx_call.reset();
        publish_dirty = true;
    };
    bool network_ready_seen = false;
    bool bm_ever_ready = false;
    bool operator_ready_instructions_shown = false;
    bool shutdown_tx_terminator_pending = false;
    bool shutdown_tx_terminator_reported = false;
    std::array<std::uint8_t, 4U> active_tx_stream_id{};
    std::array<std::uint8_t, 4U> shutdown_tx_stream_id{};
    std::optional<wirex::quick_call::Plan> active_quick_call_plan;
    std::size_t active_quick_call_next_frame = 0U;
    std::uint8_t active_quick_call_frames_sent = 0U;
    std::optional<std::uint64_t> active_routed_tx_lease_id;
    bool routed_tx_eot_reported = false;
    bool routed_tx_input_cleanup_attempted = false;
    bool routed_tx_input_cleanup_succeeded = true;
    bool routed_tx_cleanup_reported = false;
    std::optional<std::uint64_t> active_routed_rx_pipeline_generation;
    bool routed_rx_waveout_cleanup_attempted = false;
    bool routed_rx_waveout_cleanup_succeeded = true;
    bool routed_rx_cleanup_reported = false;
    bool routed_rx_hri_start_attempted = false;
    bool routed_rx_cancel_action_seen = false;
    auto maybe_complete_routed_tx_cleanup = [&]() {
        if (!active_routed_tx_lease_id || !routed_tx_eot_reported ||
            !routed_tx_input_cleanup_attempted || routed_tx_cleanup_reported) {
            return;
        }
        const auto result = pipeline->complete_routed_tx_cleanup(
            *active_routed_tx_lease_id, routed_tx_input_cleanup_succeeded);
        routed_tx_cleanup_reported = true;
        counters.tx_cleanup_result = routed_tx_input_cleanup_succeeded ? "completed" : "failed";
        if (!routed_tx_input_cleanup_succeeded) record_bm_disconnect_media_error("wavein_routed_tx_cleanup_failed");
        if (routed_tx_input_cleanup_succeeded && counters.tx_eot_result != "failed" &&
            result != wirex::talkgroup_routing::OperationStatus::completed) {
            record_bm_disconnect_media_error("routed_tx_cleanup_completion_rejected");
        }
        status(routed_tx_input_cleanup_succeeded
            ? "tx_wavein_cleanup_completed" : "tx_wavein_cleanup_failed");
    };
    auto report_routed_tx_eot = [&](bool sent) {
        if (!active_routed_tx_lease_id || routed_tx_eot_reported) return;
        const auto result = pipeline->complete_routed_tx_eot(*active_routed_tx_lease_id, sent);
        routed_tx_eot_reported = true;
        counters.tx_eot_result = sent ? "sent" : "failed";
        if (sent && result != wirex::talkgroup_routing::OperationStatus::completed) {
            record_bm_disconnect_media_error("routed_tx_eot_completion_rejected");
        } else if (!sent && result != wirex::talkgroup_routing::OperationStatus::send_failed &&
                   result != wirex::talkgroup_routing::OperationStatus::completed) {
            record_bm_disconnect_media_error("routed_tx_eot_failure_completion_rejected");
        }
        if (!sent) record_bm_disconnect_media_error("routed_tx_eot_not_sent");
        status(sent ? "tx_eot_udp_send_succeeded" : "tx_eot_udp_send_failed");
        maybe_complete_routed_tx_cleanup();
    };
    auto record_routed_tx_input_cleanup = [&](bool succeeded) {
        if (!active_routed_tx_lease_id || routed_tx_cleanup_reported) return;
        routed_tx_input_cleanup_attempted = true;
        routed_tx_input_cleanup_succeeded = routed_tx_input_cleanup_succeeded && succeeded;
        maybe_complete_routed_tx_cleanup();
    };
    auto record_routed_rx_waveout_cleanup = [&](bool succeeded) {
        if (!active_routed_rx_pipeline_generation || routed_rx_cleanup_reported) return;
        routed_rx_waveout_cleanup_attempted = true;
        routed_rx_waveout_cleanup_succeeded = routed_rx_waveout_cleanup_succeeded && succeeded;
    };
    auto report_routed_rx_cleanup = [&](bool hri_t0_confirmed) {
        if (!active_routed_rx_pipeline_generation || routed_rx_cleanup_reported) return;
        const bool generation_t0_confirmed = routed_rx_hri_start_attempted && hri_t0_confirmed;
        const bool cleanup_succeeded = routed_rx_waveout_cleanup_attempted &&
            routed_rx_waveout_cleanup_succeeded &&
            (!routed_rx_hri_start_attempted || generation_t0_confirmed);
        const auto result = pipeline->complete_routed_rx_cleanup(
            *active_routed_rx_pipeline_generation, cleanup_succeeded);
        routed_rx_cleanup_reported = true;
        counters.rx_cleanup_result = cleanup_succeeded ? "completed" : "failed";
        if (!cleanup_succeeded) record_bm_disconnect_media_error("routed_rx_cleanup_failed");
        if (cleanup_succeeded && result != wirex::talkgroup_routing::OperationStatus::completed) {
            record_bm_disconnect_media_error("routed_rx_cleanup_completion_rejected");
        } else if (!cleanup_succeeded &&
                   result != wirex::talkgroup_routing::OperationStatus::cleanup_failed &&
                   result != wirex::talkgroup_routing::OperationStatus::completed) {
            record_bm_disconnect_media_error("routed_rx_cleanup_failure_completion_rejected");
        }
        const auto cleanup_event = !cleanup_succeeded ? "rx_waveout_or_hri_t0_cleanup_failed" :
            (generation_t0_confirmed ? "rx_waveout_reset_and_hri_t0_cleanup_completed"
                                     : "rx_audio_cleanup_hri_not_started_completed");
        const auto local_snapshot = local_playback.snapshot();
        if (local_snapshot.call_active &&
            local_snapshot.generation == *active_routed_rx_pipeline_generation) {
            (void)local_playback.end_call(*active_routed_rx_pipeline_generation);
            local_playback.set_environment(hri_ready && port != nullptr,
                radio_output_open && !radio_output_playback_blocked);
        }
        status(cleanup_event);
    };
    auto maybe_show_operator_ready_instructions = [&]() {
        if (operator_ready_instructions_shown || shutdown_requested || failed || !network_ready_seen ||
            bm_session.snapshot().state != wirex::bm::State::ready || !hri_ready ||
            !hri_state.y_zero_acknowledged) {
            return;
        }
        operator_ready_instructions_shown = true;
        if (live_tx_permission()) {
            const auto* configured_tx = pipeline->routed_tx_policy();
            const auto configured_target = configured_tx != nullptr
                ? configured_tx->target
                : wirex::talkgroup_routing::TxTarget{
                    call_template.destination_id, call_template.kind, call_template.slot};
            if (!manual_ptt) {
                console(u8"已连接并就绪。先松开一次手咪 PTT，再按住手咪讲话；松开后等待 BM 回声。按 Q 停止并退出。\n");
            } else if (configured_target.kind == wirex::dmr_call::CallKind::private_call &&
                (configured_target.destination_id == 460997U || configured_target.destination_id == 9990U)) {
                console(u8"已连接并就绪。按 T 开始 BM 上行，按住手咪讲话；松开后按 T 结束本次上行并等待回声。按 Q 退出。\n");
            } else {
                console(u8"已连接并就绪。按 T 开始 BM 上行，按住手咪讲话；松开后按 T 结束本次上行。按 Q 退出。\n");
            }
        } else if (call_template.kind == wirex::dmr_call::CallKind::group &&
                   call_template.destination_id == 91U) {
            if (call_template.slot == wirex::dmr_call::Slot::ts1) {
                console(u8"已连接并就绪。请在 BM SelfCare 为当前 Gateway 的 TS1 添加 TG91 静态订阅，然后在电台扬声器收听。按 Q 停止并退出。\n");
            } else {
                console(u8"已连接并就绪。请在 BM SelfCare 为当前 Gateway 的 TS2 添加 TG91 静态订阅，然后在电台扬声器收听。按 Q 停止并退出。\n");
            }
        } else {
            console(u8"已连接并就绪。可在所选电台扬声器收听 BM 组呼。按 Q 停止并退出。\n");
        }
    };
    auto stop_tx_input = [&]() -> bool {
        const bool closed = radio_input->close();
        radio_input_open = radio_input->is_open();
        record_routed_tx_input_cleanup(closed);
        return closed;
    };
    auto tx_start_permitted = [&]() {
        if (!live_tx_permission() || shutdown_requested || failed ||
            bm_connection->disable_pending() || bm_ptt_release_required ||
            !network_ready_seen || bm_session.snapshot().state != wirex::bm::State::ready ||
            !hri_ready || !hri_state.y_zero_acknowledged || hri_state.phase == HriPhase::stopped ||
            downlink_blocked || radio_input_open) {
            return false;
        }
        const auto pipeline_state = pipeline->snapshot();
        const auto stream_state = stream_session->snapshot();
        const auto routing_state = pipeline->routing_snapshot().router;
        return pipeline_state.tx_state == wirex::bm_voice::TxState::idle &&
            pipeline_state.rx_state == wirex::bm_voice::RxState::idle &&
            stream_state.phase == StreamPhase::idle &&
            routing_state.media_owner == wirex::talkgroup_routing::MediaOwner::idle &&
            !routing_state.ptt_release_required;
    };
    auto start_tx_call = [&]() {
        if (!tx_start_permitted()) {
            ++counters.rejected_calls;
            status("tx_start_rejected_busy_or_endpoint_not_ready");
            return false;
        }
        auto call = call_template;
        if (!random_stream_id(call.stream_id)) {
            set_failure("stream_id_random_failed");
            return false;
        }
        const auto begin_result = pipeline->begin_routed_tx(
            call, wirex::bm_voice::Readiness{network_ready_seen, hri_ready}, Clock::now());
        if (begin_result != wirex::bm_voice::Error::none) {
            ++counters.rejected_calls;
            const auto rejected_routing = pipeline->routing_snapshot().router;
            if (rejected_routing.active_tx_lease &&
                rejected_routing.active_tx_lease->eot_sent.has_value() &&
                !*rejected_routing.active_tx_lease->eot_sent) {
                counters.tx_lease_id = rejected_routing.active_tx_lease->id;
                counters.tx_eot_result = "failed";
                counters.tx_cleanup_result = "completed";
                set_failure("routed_tx_begin_media_failed");
                status("routed_tx_start_failed_router_faulted_after_eot_not_sent");
            } else {
                const auto rejection_event = begin_result == wirex::bm_voice::Error::busy
                    ? "tx_start_rejected_router_busy_or_ptt_release_required"
                    : (begin_result == wirex::bm_voice::Error::bm_not_ready
                        ? "tx_start_rejected_bm_not_ready"
                        : (begin_result == wirex::bm_voice::Error::hri_not_ready
                            ? "tx_start_rejected_hri_not_ready"
                            : (live_tx_permission()
                                ? "tx_start_rejected_by_router_or_pipeline"
                                : "tx_start_rejected_receive_only_policy")));
                status(rejection_event);
            }
            return false;
        }
        const auto routed = pipeline->routing_snapshot();
        if (!routed.router.active_tx_lease) {
            pipeline->cancel_tx();
            set_failure("routed_tx_lease_missing_after_begin");
            return false;
        }
        active_routed_tx_lease_id = routed.router.active_tx_lease->id;
        routed_tx_eot_reported = false;
        routed_tx_input_cleanup_attempted = false;
        routed_tx_input_cleanup_succeeded = true;
        routed_tx_cleanup_reported = false;
        counters.tx_lease_id = *active_routed_tx_lease_id;
        counters.tx_eot_result = "pending";
        counters.tx_cleanup_result = "pending";
        active_tx_stream_id = call.stream_id;
        if (!radio_input->open()) {
            pipeline->cancel_tx();
            (void)stop_tx_input();
            report_routed_tx_eot(false);
            ++counters.rejected_calls;
            status("radio_wavein_open_failed_tx_cancelled");
            return false;
        }
        radio_input_open = true;
        if (!manual_ptt) ++counters.ptt_tx_starts;
        status(manual_ptt ? "tx_started_explicitly_by_t_key" : "tx_started_from_radio_ptt_down");
        console(u8"上行已开始，请继续讲话。\n");
        return true;
    };
    // 原 consume_tx_wave_buffer 的 PCM 部分；缓冲长度、重新排队与擦除由 AudioInput 实现负责。
    const AudioInput::Sink consume_tx_pcm = [&](std::int16_t* samples, std::size_t count) {
        if (count == 0U) return true;
        const auto gain = wirex::pcm_gain::apply(samples, count, mic_transmit_gain_milli);
        if (!gain.valid) return false;
        const auto pushed = pipeline->push_tx_audio(samples, count, Clock::now());
        if (!pushed) return false;
        counters.tx_audio_samples += count;
        wirex::pcm_gain::accumulate(counters.tx_pcm_input_stats, gain.before);
        wirex::pcm_gain::accumulate(counters.tx_pcm_gained_stats, gain.after);
        tx_peak_window.push(peak_unit(gain.after.peak), Clock::now());
        if (gain.clipped_samples >
            std::numeric_limits<std::uint64_t>::max() - counters.tx_pcm_clipped_samples) {
            counters.tx_pcm_clipped_samples = std::numeric_limits<std::uint64_t>::max();
        } else {
            counters.tx_pcm_clipped_samples += gain.clipped_samples;
        }
        return true;
    };
    auto finish_tx_capture = [&]() {
        if (!radio_input_open) {
            const bool closed = radio_input->close();
            record_routed_tx_input_cleanup(closed);
            return closed;
        }
        bool succeeded = radio_input->stop_capture();
        if (succeeded) {
            succeeded = radio_input->take_captured(consume_tx_pcm, false, 100U) == CaptureStatus::ok;
        }
        const bool closed = radio_input->close();
        radio_input_open = radio_input->is_open();
        record_routed_tx_input_cleanup(closed);
        return succeeded && closed;
    };
    auto end_tx_call = [&]() {
        if (!finish_tx_capture()) {
            pipeline->cancel_tx();
            report_routed_tx_eot(false);
            set_failure("wavein_tx_release_cleanup_failed");
            return false;
        }
        const auto state = pipeline->snapshot();
        if (state.tx_state != wirex::bm_voice::TxState::active) {
            if (state.tx_state != wirex::bm_voice::TxState::idle) pipeline->cancel_tx();
            report_routed_tx_eot(false);
            set_failure("tx_release_without_active_call");
            return false;
        }
        const auto ended = pipeline->end_tx(Clock::now());
        if (ended != wirex::bm_voice::Error::none) {
            pipeline->cancel_tx();
            report_routed_tx_eot(false);
            set_failure("tx_audio_flush_failed");
            return false;
        }
        if (manual_ptt) status("manual_t_key_operator_released_tx_lease");
        status("tx_audio_draining_after_radio_ptt_release");
        return true;
    };
    handle_ptt_gate_action = [&](PttAction action, std::string_view event) {
        if (action == PttAction::start_tx) {
            if (!start_tx_call()) {
                ++counters.ptt_start_rejections;
                ptt_gate.start_failed();
            } else if (!manual_ptt && !ptt_gate.start_succeeded(elapsed_ms())) {
                (void)stop_tx_input();
                pipeline->cancel_tx();
                report_routed_tx_eot(false);
                ptt_gate.start_failed();
                set_failure("ptt_call_timer_start_failed");
            }
            return;
        }
        if (action == PttAction::end_tx) {
            if (end_tx_call()) {
                ++counters.ptt_tx_ends;
                const auto routing = pipeline->routing_snapshot().router;
                const auto completed_target = routing.active_tx_lease
                    ? routing.active_tx_lease->target
                    : wirex::talkgroup_routing::TxTarget{
                        call_template.destination_id, call_template.kind, call_template.slot};
                if (completed_target.kind == wirex::dmr_call::CallKind::private_call &&
                    (completed_target.destination_id == 460997U || completed_target.destination_id == 9990U)) {
                    console(u8"上行已结束，请等待 BM 回声。\n");
                } else {
                    console(u8"上行已结束，可继续收听。\n");
                }
            } else {
                ptt_gate.disarm_until_release();
            }
            return;
        }
        if (action == PttAction::call_timeout) {
            const bool capture_closed = finish_tx_capture();
            if (!capture_closed) set_failure("wavein_ptt_call_timeout_cleanup_failed");
            const auto state = pipeline->snapshot();
            if (state.tx_state != wirex::bm_voice::TxState::idle) {
                if (network_ready_seen && bm_session.snapshot().state == wirex::bm::State::ready) {
                    if (pipeline->stop_tx(Clock::now()) != wirex::bm_voice::Error::none) {
                        pipeline->cancel_tx();
                        report_routed_tx_eot(false);
                        set_failure("ptt_call_timeout_terminator_failed");
                    }
                } else {
                    pipeline->cancel_tx();
                    report_routed_tx_eot(false);
                }
            }
            ptt_gate.disarm_until_release();
            ++counters.ptt_tx_timeouts;
            status("radio_ptt_call_120s_limit_reached_release_required");
            return;
        }
        if (action != PttAction::abort_tx) return;
        if (!stop_tx_input()) record_bm_disconnect_media_error("wavein_ptt_abort_cleanup_failed");
        const auto state = pipeline->snapshot();
        if (state.tx_state != wirex::bm_voice::TxState::idle) {
            if (bm_session.snapshot().state == wirex::bm::State::ready) {
                if (pipeline->stop_tx(Clock::now()) != wirex::bm_voice::Error::none) {
                    pipeline->cancel_tx();
                    report_routed_tx_eot(false);
                    record_bm_disconnect_media_error("ptt_abort_terminator_failed");
                }
            } else {
                pipeline->cancel_tx();
                report_routed_tx_eot(false);
            }
        }
        ptt_gate.disarm_until_release();
        status(event);
    };
    synchronize_ptt_gate = [&]() {
        if (manual_ptt) return;
        const bool ready = !shutdown_requested && !failed && !status_report_failed &&
            !bm_connection->disable_pending() && !bm_ptt_release_required &&
            live_tx_permission() && network_ready_seen &&
            bm_session.snapshot().state == wirex::bm::State::ready && hri_ready &&
            hri_state.y_zero_acknowledged && hri_state.phase != HriPhase::stopped;
        handle_ptt_gate_action(ptt_gate.set_ready(ready), "ptt_aborted_endpoint_not_ready");
    };
    process_ptt_observation = [&](const wirex::hri_session::PttObservation& observation) {
        if (manual_ptt || !observation.y_zero_acknowledged) return;
        if (observation.level == wirex::hri_session::PttLevel::released &&
            pipeline->observe_routed_ptt_release() != wirex::talkgroup_routing::OperationStatus::completed) {
            set_failure("routed_physical_ptt_release_observation_rejected");
        }
        if (observation.level == wirex::hri_session::PttLevel::released) {
            bm_ptt_release_required = false;
        }
        synchronize_ptt_gate();
        PttLevel level = PttLevel::unknown;
        switch (observation.level) {
        case wirex::hri_session::PttLevel::pressed: level = PttLevel::pressed; break;
        case wirex::hri_session::PttLevel::released: level = PttLevel::released; break;
        case wirex::hri_session::PttLevel::unknown: level = PttLevel::unknown; break;
        }
        const bool ptt_level_changed = counters.last_ptt_level != observation.level;
        ++counters.ptt_observations;
        counters.last_ptt_level = observation.level;
        if (observation.level == wirex::hri_session::PttLevel::unknown) {
            ++counters.ptt_unknown_observations;
        }
        const bool can_start = tx_start_permitted();
        const auto before = ptt_gate.snapshot();
        const auto action = ptt_gate.observe(level, can_start);
        if (level == PttLevel::pressed && !before.pressed_latched && !can_start) {
            ++counters.ptt_start_rejections;
            ++counters.rejected_calls;
            status("radio_ptt_down_rejected_busy_release_required");
        }
        if (action == PttAction::abort_tx) {
            handle_ptt_gate_action(action, "tx_aborted_unknown_radio_ptt_state");
        } else {
            handle_ptt_gate_action(action, "radio_ptt_action");
        }
        if (ptt_level_changed) status("radio_ptt_level_changed");
    };
    auto is_shutdown_terminator = [&](const wirex::dmr_call::TxPacket& packet) {
        return shutdown_tx_terminator_pending &&
            packet.kind == wirex::dmr_call::PacketKind::terminator_with_lc &&
            packet.datagram.stream_id == shutdown_tx_stream_id;
    };
    auto report_shutdown_terminator_not_sent = [&](std::string_view reason) {
        if (!shutdown_tx_terminator_pending || shutdown_tx_terminator_reported) return;
        shutdown_tx_terminator_pending = false;
        shutdown_tx_terminator_reported = true;
        status(reason);
    };

    std::function<void(wirex::hri_stream_session::Update)> service_stream_update;
    service_stream_update = [&](wirex::hri_stream_session::Update update) {
        std::deque<StreamAction> pending;
        for (auto& action : update.actions) pending.push_back(std::move(action));
        while (!pending.empty()) {
            auto action = std::move(pending.front());
            pending.pop_front();
            switch (action.kind) {
            case StreamActionKind::write_start_candidate:
            case StreamActionKind::write_stop_candidate: {
                const auto now_ms = elapsed_ms();
                const auto attempted = stream_session->write_attempted(action.write_id, now_ms);
                if (attempted.error != wirex::hri_stream_session::Error::none) {
                    set_failure("hri_stream_write_state_error");
                    break;
                }
                if (action.kind == StreamActionKind::write_start_candidate &&
                    active_routed_rx_pipeline_generation) {
                    routed_rx_hri_start_attempted = true;
                    if (counters.lcd_source_identity_prepared &&
                        counters.lcd_source_identity_generation == *active_routed_rx_pipeline_generation) {
                        counters.lcd_source_identity_serial_write_state = "attempted";
                    }
                }
                const bool full = serial_write(action.frame.data(), action.frame.size());
                if (action.kind == StreamActionKind::write_start_candidate &&
                    active_routed_rx_pipeline_generation && counters.lcd_source_identity_prepared &&
                    counters.lcd_source_identity_generation == *active_routed_rx_pipeline_generation) {
                    counters.lcd_source_identity_serial_write_state = full ? "sent" : "failed";
                }
                if (!full) {
                    serial_failed = true;
                    radio_fault_pending = true;
                    radio_fault_reason = "hri_stream_serial_write_failed";
                }
                auto completed = stream_session->write_completed(action.write_id, full, elapsed_ms());
                for (auto& follow_up : completed.actions) pending.push_back(std::move(follow_up));
                if (completed.error != wirex::hri_stream_session::Error::none) {
                    set_failure("hri_stream_write_completion_error");
                }
                status(action.kind == StreamActionKind::write_start_candidate ? "hri_t3_write" : "hri_t0_write");
                break;
            }
            case StreamActionKind::playback_permitted: {
                const auto result = pipeline->playback_ready(Clock::now());
                if (result != wirex::bm_voice::Error::none) {
                    set_failure("pipeline_playback_start_failed");
                    downlink_blocked = true;
                    service_stream_update(stream_session->cancel(StreamReason::transport_failed, elapsed_ms()));
                } else {
                    status("hri_t3_observed_playback_enabled");
                }
                break;
            }
            case StreamActionKind::cancel_playback:
                clear_lcd_source_identity();
                routed_rx_cancel_action_seen = true;
                pipeline->cancel_rx();
                pending_receive_start = false;
                pending_playback_drain = false;
                {
                    const bool closed = radio_output->close();
                    radio_output_open = radio_output->is_open();
                    record_routed_rx_waveout_cleanup(closed);
                    if (!closed) set_failure("waveout_cancel_cleanup_failed");
                }
                status("playback_cancelled_and_queue_cleared");
                break;
            case StreamActionKind::call_finished: {
                const auto state = stream_session->snapshot();
                const bool hri_t0_confirmed = state.stop_write_succeeded && state.stop_t_record_observed;
                const auto pipeline_state = pipeline->snapshot();
                const bool quarantined_waveout_drained = detail::quarantined_rx_output_cleanup_ready(
                    radio_output_playback_blocked, radio_output_open,
                    radio_output == nullptr || radio_output->all_drained(),
                    pipeline_state.queued_playback_frames,
                    pipeline_state.unconfirmed_playback_frames, hri_t0_confirmed);
                bool waveout_cleanup_ok = false;
                if (quarantined_waveout_drained && hri_t0_confirmed) {
                    // 本次 RX 从未向该被隔离的输出设备提交 PCM，且 HRI T0 已确认。
                    // 释放 Router 的媒体 lease，但保留尚未确认关闭的句柄、隔离状态和错误。
                    waveout_cleanup_ok = true;
                    status("rx_quarantined_waveout_retained_after_t0_and_drain");
                } else {
                    waveout_cleanup_ok = radio_output->close();
                    radio_output_open = radio_output->is_open();
                }
                record_routed_rx_waveout_cleanup(waveout_cleanup_ok);
                const bool aggregate_waveout_cleanup_ok = routed_rx_waveout_cleanup_attempted &&
                    routed_rx_waveout_cleanup_succeeded;
                if (!waveout_cleanup_ok) set_failure("waveout_rx_call_cleanup_failed");
                const bool routed_rx_cleanup_incomplete =
                    wirex::hri_stream_session::routed_rx_cleanup_incomplete(
                        state, routed_rx_hri_start_attempted, aggregate_waveout_cleanup_ok);
                report_routed_rx_cleanup(hri_t0_confirmed);
                clear_lcd_source_identity();
                ++counters.calls_ended;
                finish_published_rx_call(counters.rx_call_end_reason);
                if (state.reason == StreamReason::none && hri_t0_confirmed &&
                    aggregate_waveout_cleanup_ok) {
                    status("downlink_call_drained_t0_observed");
                } else if (routed_rx_cleanup_incomplete) {
                    if (!state.stop_write_succeeded || !state.stop_t_record_observed ||
                        state.reason == StreamReason::stop_write_failed ||
                        state.reason == StreamReason::stop_record_timeout) {
                        downlink_blocked = true;
                    }
                    if (state.reason == StreamReason::stop_write_failed) {
                        record_bm_disconnect_media_error("hri_t0_write_failed");
                    }
                    if (state.stop_write_attempted && state.stop_write_succeeded &&
                        !state.stop_t_record_observed) {
                        record_bm_disconnect_media_error("hri_t0_record_timeout");
                    }
                    status("downlink_call_bounded_cleanup_incomplete");
                }
                if (stream_session->snapshot().phase == StreamPhase::faulted) {
                    downlink_blocked = true;
                }
                break;
            }
            }
        }
    };

    auto apply_hri_update = [&](wirex::hri_session::Update update) {
        hri_state = update.state;
        bool command_writes_succeeded = true;
        for (const auto& command : update.commands) {
            const bool full = serial_write(command.frame.data(), command.frame.size());
            if (!hri_session) break;
            hri_state = hri_session->write_completed(command.id, full, elapsed_ms()).state;
            if (!full) {
                serial_failed = true;
                command_writes_succeeded = false;
                radio_fault_pending = true;
                radio_fault_reason = "hri_control_serial_write_failed";
                break;
            }
        }
        if (update.state.phase == HriPhase::stopped &&
            update.state.stop_reason != wirex::hri_session::StopReason::none &&
            update.state.stop_reason != wirex::hri_session::StopReason::caller_stopped) {
            radio_fault_pending = true;
            radio_fault_reason = hri_stop_reason_name(update.state.stop_reason);
            status(radio_fault_reason);
        }
        if (hri_state.y_zero_acknowledged && !hri_ready && hri_state.phase != HriPhase::stopped) {
            const bool opened = radio_output->open();
            radio_output_open = radio_output->is_open();
            if (!opened) {
                radio_output_playback_blocked = radio_output_open;
                (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::open_failed);
                local_audio_error = "radio_waveout_open_failed";
                radio_fault_pending = true;
                radio_fault_reason = "radio_waveout_open_failed";
            } else {
                radio_output_playback_blocked = false;
                hri_ready = true;
                local_playback.output_available();
                local_audio_error.clear();
                local_playback.set_environment(true, true);
                status("hri_y0_observed_radio_speaker_ready");
                maybe_show_operator_ready_instructions();
            }
        }
        synchronize_ptt_gate();
        if (command_writes_succeeded) {
            for (const auto& observation : update.ptt_observations) {
                process_ptt_observation(observation);
            }
        }
    };

    auto radio_media_idle = [&]() {
        const auto pipeline_state = pipeline->snapshot();
        const auto stream_state = stream_session->snapshot();
        return pipeline_state.tx_state == wirex::bm_voice::TxState::idle &&
            pipeline_state.rx_state == wirex::bm_voice::RxState::idle &&
            (stream_state.phase == StreamPhase::idle || stream_state.phase == StreamPhase::faulted) &&
            !radio_input_open && !pending_receive_start && !pending_receive_ended &&
            !pending_playback_drain && !active_quick_call_plan &&
            (!active_routed_tx_lease_id || routed_tx_cleanup_reported) &&
            (!active_routed_rx_pipeline_generation || routed_rx_cleanup_reported);
    };

    auto radio_media_quiescent = [&]() {
        const auto pipeline_state = pipeline->snapshot();
        const auto stream_state = stream_session->snapshot();
        return pipeline_state.tx_state == wirex::bm_voice::TxState::idle &&
            pipeline_state.rx_state == wirex::bm_voice::RxState::idle &&
            (stream_state.phase == StreamPhase::idle || stream_state.phase == StreamPhase::faulted) &&
            !pending_receive_start && !pending_receive_ended && !pending_playback_drain &&
            !active_quick_call_plan;
    };

    auto radio_audio_resource_retained = [&]() {
        return radio_input_open || radio_output_open ||
            (radio_input && radio_input->is_open()) || (radio_output && radio_output->is_open());
    };

    auto close_serial_once = [&](std::unique_ptr<SerialPort>& candidate) noexcept {
        if (!candidate) return true;
        const bool closed = candidate->close();
        // SerialPort::close consumes its native handle even when Windows cannot confirm the close.
        // Drop the wrapper after exactly one attempt and latch the uncertainty; never retry a raw
        // handle that may already have been invalidated or recycled by the OS.
        candidate.reset();
        if (!closed) {
            radio_serial_close_unconfirmed = true;
            serial_failed = true;
        }
        return closed;
    };

    auto detach_radio = [&](std::string reason) {
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        if (pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle) {
            pipeline->cancel_tx();
            (void)stop_tx_input();
            report_routed_tx_eot(false);
        }
        const auto stream_state = stream_session->snapshot();
        const auto local_rx = local_playback.snapshot();
        const bool preserve_local_rx = local_rx.call_active && !routed_rx_hri_start_attempted &&
            (local_rx.route == wirex::bm_local_playback::Route::local_output ||
             local_rx.route == wirex::bm_local_playback::Route::silent);
        if (stream_state.phase != StreamPhase::idle && stream_state.phase != StreamPhase::faulted) {
            service_stream_update(stream_session->cancel(StreamReason::transport_failed, elapsed_ms()));
        } else if (pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle && !preserve_local_rx) {
            pipeline->cancel_rx();
        }
        if (!preserve_local_rx) {
            pending_receive_start = false;
            pending_receive_ended = false;
            pending_playback_drain = false;
        }
        bool input_close_failed = false;
        bool output_close_failed = false;
        bool serial_close_failed = radio_serial_close_unconfirmed;
        std::string close_error = radio_serial_close_unconfirmed ? "serial_close_unconfirmed" : std::string{};
        if (radio_input) {
            const bool closed = radio_input->close();
            radio_input_open = radio_input->is_open();
            if (!closed) {
                input_close_failed = true;
                close_error = "wavein_close_failed";
            }
            if (closed && !radio_input_open && active_routed_tx_lease_id &&
                !routed_tx_cleanup_reported && routed_tx_eot_reported) {
                record_routed_tx_input_cleanup(true);
            }
        } else {
            radio_input_open = false;
        }
        if (radio_output) {
            const bool closed = radio_output->close();
            radio_output_open = radio_output->is_open();
            if (!closed) {
                output_close_failed = true;
                if (close_error.empty()) close_error = "waveout_close_failed";
            }
        } else {
            radio_output_open = false;
        }
        if (hri_session && hri_active && hri_state.phase != HriPhase::stopped) {
            hri_state = hri_session->cancel().state;
        }
        hri_session.reset();
        hri_active = false;
        hri_ready = false;
        if (port && !radio_serial_close_unconfirmed) {
            if (!close_serial_once(port)) {
                serial_close_failed = true;
                if (close_error.empty()) close_error = "serial_close_unconfirmed";
            }
        }
        if (port == nullptr) config.hri_port.clear();
        if (!radio_input_open) {
            config.audio.wave_in_id = 0U;
            config.audio.expected_wave_in_endpoint_id.clear();
        }
        config.hri_body_file.clear();
        config.start_radio = false;
        hri_state = wirex::hri_session::Snapshot{};
        if (!output_close_failed && !radio_output_open && radio_output &&
            !config.audio.expected_wave_out_endpoint_id.empty()) {
            if (radio_output->open()) {
                radio_output_open = radio_output->is_open();
                radio_output_playback_blocked = false;
                local_playback.output_available();
                local_audio_error.clear();
                status("bm_local_playback_output_restored_after_radio_detach");
            } else {
                radio_output_open = radio_output->is_open();
                radio_output_playback_blocked = radio_output_open;
                local_playback.output_unavailable(wirex::bm_local_playback::OutputError::open_failed);
                local_audio_error = "waveout_open_failed";
                status("bm_local_playback_output_restore_failed");
            }
        } else if (output_close_failed || radio_output_open) {
            radio_output_playback_blocked = true;
            local_playback.output_unavailable(wirex::bm_local_playback::OutputError::close_failed);
            local_audio_error = "waveout_close_failed";
        } else if (config.audio.expected_wave_out_endpoint_id.empty()) {
            local_playback.output_unavailable(
                wirex::bm_local_playback::OutputError::selection_unavailable);
        }
        local_playback.set_environment(false, radio_output_open && !radio_output_playback_blocked);
        if (preserve_local_rx && pending_receive_start && active_routed_rx_pipeline_generation) {
            (void)local_playback.retarget_pending_call(*active_routed_rx_pipeline_generation, false,
                radio_output_open && !radio_output_playback_blocked && local_playback.snapshot().output_error ==
                    wirex::bm_local_playback::OutputError::none);
            status("bm_local_pending_receive_route_refreshed_after_radio_detach");
        }
        radio_error = (input_close_failed || output_close_failed || serial_close_failed)
            ? std::move(close_error) : std::move(reason);
        radio_fault_pending = false;
        radio_fault_reason.clear();
        network_ready_seen = bm_session.snapshot().state == wirex::bm::State::ready &&
            bm_connection->snapshot().requested_enabled;
        publish_dirty = true;
        status("radio_detached_bm_runtime_preserved");
        return !input_close_failed && !output_close_failed && !serial_close_failed;
    };

    auto connect_radio_runtime = [&](const RadioStartConfig& requested) -> CommandResult {
        if (shutdown_requested) return CommandResult{CommandStatus::not_ready, 0U, "engine_stopping"};
        if (requested.hri_port.empty() || requested.audio.expected_wave_in_endpoint_id.empty() ||
            requested.audio.expected_wave_out_endpoint_id.empty()) {
            radio_error = "radio_selection_unresolved";
            return CommandResult{CommandStatus::invalid, 0U, radio_error};
        }
        const auto local_audio = local_playback.snapshot();
        const bool local_output_only = port == nullptr && !hri_ready && !radio_input_open &&
            radio_output_open && !local_audio.call_active &&
            local_audio.output_error == wirex::bm_local_playback::OutputError::none;
        if (radio_serial_close_unconfirmed) {
            publish_dirty = true;
            return CommandResult{CommandStatus::busy, 0U, "radio_serial_close_unconfirmed"};
        }
        if (port != nullptr || (radio_audio_resource_retained() && !local_output_only)) {
            if (port == nullptr) {
                publish_dirty = true;
                return CommandResult{CommandStatus::busy, 0U, "radio_cleanup_required"};
            }
            if (config.hri_port == requested.hri_port &&
                config.audio.expected_wave_in_endpoint_id == requested.audio.expected_wave_in_endpoint_id &&
                config.audio.expected_wave_out_endpoint_id == requested.audio.expected_wave_out_endpoint_id) {
                return CommandResult{CommandStatus::idempotent, 0U, "radio_already_connected"};
            }
            return CommandResult{CommandStatus::busy, 0U, "radio_disconnect_before_reselect"};
        }
        if (!radio_media_idle()) return CommandResult{CommandStatus::busy, 0U, "radio_media_busy"};

        std::vector<std::uint8_t> body;
        bool body_ok = false;
        try {
            body_ok = requested.ap_mode ? devices.load_hri_template_ap(requested.hri_body_file, body)
                                        : devices.load_hri_template(requested.hri_body_file, body);
        } catch (...) {}
        if (!body_ok) {
            radio_error = "y_template_invalid";
            publish_dirty = true;
            status(requested.ap_mode ? "radio_connect_y_template_ap_invalid" : "radio_connect_y_template_direct_invalid");
            return CommandResult{CommandStatus::invalid, 0U, radio_error};
        }
        std::unique_ptr<AudioInput> next_input;
        std::unique_ptr<AudioOutput> next_output;
        std::unique_ptr<SerialPort> next_port;
        std::unique_ptr<wirex::hri_session::Session> next_hri;
        try {
            next_input = devices.make_audio_input(requested.audio);
            next_output = devices.make_audio_output(requested.audio);
            next_hri = std::make_unique<wirex::hri_session::Session>(std::move(body),
                wirex::hri_session::Config{wirex::session_timing::active_window_ms, continuous_run, requested.ap_mode});
        } catch (...) {
            radio_error = "radio_state_allocation_failed";
            publish_dirty = true;
            return CommandResult{CommandStatus::failed, 0U, radio_error};
        }
        if (!next_input || !next_output || !next_hri) {
            radio_error = "radio_state_allocation_failed";
            publish_dirty = true;
            return CommandResult{CommandStatus::failed, 0U, radio_error};
        }
        std::string open_failure;
        try { next_port = devices.open_serial(requested.hri_port, open_failure); } catch (...) { next_port.reset(); }
        if (!next_port) {
            radio_error = open_failure.empty() ? "serial_open_or_configure_failed" : std::move(open_failure);
            publish_dirty = true;
            return CommandResult{CommandStatus::failed, 0U, radio_error};
        }

        if (local_output_only) {
            const bool closed = radio_output->close();
            radio_output_open = radio_output->is_open();
            if (radio_output_open) {
                (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::close_failed);
                local_audio_error = "waveout_close_failed";
                const bool serial_closed = close_serial_once(next_port);
                radio_error = serial_closed ? "waveout_close_failed" : "serial_close_unconfirmed";
                publish_dirty = true;
                return CommandResult{CommandStatus::failed, 0U, radio_error};
            }
            if (!closed) local_audio_error = "waveout_old_endpoint_closed_with_cleanup_warning";
            local_playback.set_environment(false, false);
        }

        radio_input = std::move(next_input);
        radio_output = std::move(next_output);
        port = std::move(next_port);
        hri_session = std::move(next_hri);
        config.hri_port = requested.hri_port;
        config.hri_body_file = requested.hri_body_file;
        config.audio = requested.audio;
        config.start_radio = true;
        hri_state = wirex::hri_session::Snapshot{};
        hri_ready = false;
        hri_active = true;
        serial_failed = false;
        radio_input_open = false;
        radio_output_open = false;
        radio_error.clear();
        apply_hri_update(hri_session->start(elapsed_ms()));
        if (radio_fault_pending) {
            const auto reason = radio_fault_reason.empty() ? std::string("hri_start_failed") : radio_fault_reason;
            detach_radio(reason);
            return CommandResult{CommandStatus::failed, 0U, reason};
        }
        // dev 日志据此记录本次握手使用的 Y 模板（DIRECT offset 0x05='2' / AP '1'）。
        status(requested.ap_mode ? "hri_y_template_ap" : "hri_y_template_direct");
        status("radio_connected_hri_start_requested");
        return CommandResult{CommandStatus::accepted, 0U, ""};
    };

    auto cleanup_routed_rx_without_hri_start = [&](std::string_view event) {
        if (!active_routed_rx_pipeline_generation) return;
        if (routed_rx_hri_start_attempted) return;
        const auto local = local_playback.snapshot();
        if (local.call_active && local.generation == *active_routed_rx_pipeline_generation &&
            (local.route == wirex::bm_local_playback::Route::local_output ||
             local.route == wirex::bm_local_playback::Route::silent)) {
            // BM-only playback keeps its selected output open between calls; the Router lease
            // can finish without sending an HRI T0 or closing that persistent WaveOut.
            record_routed_rx_waveout_cleanup(true);
            report_routed_rx_cleanup(false);
            status(event);
            return;
        }
        const bool closed = radio_output->close();
        radio_output_open = radio_output->is_open();
        record_routed_rx_waveout_cleanup(closed);
        if (!closed) set_failure("waveout_pre_t3_cleanup_failed");
        report_routed_rx_cleanup(false);
        status(event);
    };

    auto begin_local_playback_for_pending_rx = [&]() {
        if (!pending_receive_start || shutdown_requested) return;
        const auto pipeline_state = pipeline->snapshot();
        if (pipeline_state.rx_state == wirex::bm_voice::RxState::idle ||
            pipeline_state.rx_state == wirex::bm_voice::RxState::filtered ||
            pipeline_state.rx_state == wirex::bm_voice::RxState::stopping) {
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("bm_local_receive_inactive_before_playback");
            return;
        }
        const auto decision = wirex::bm_voice::receive_hri_start_decision(pipeline_state);
        if (decision == wirex::bm_voice::ReceiveHriStartDecision::wait_for_voice) return;
        if (decision == wirex::bm_voice::ReceiveHriStartDecision::discard_empty_ended_call) {
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("bm_local_empty_receive_ended");
            return;
        }
        if (!network_ready_seen) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("bm_local_receive_rejected_network_or_media_busy");
            return;
        }
        const auto& receive_call = pipeline_state.receive_call;
        const auto resolved_source_identity = source_identity_cache.find(receive_call.source_id);
        if (pipeline->playback_ready(Clock::now()) != wirex::bm_voice::Error::none) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("bm_local_pipeline_playback_start_failed");
            status("bm_local_playback_admission_failed");
            return;
        }

        pending_receive_start = false;
        pending_receive_ended = false;
        ++counters.calls_started;
        finish_published_rx_call("replaced_by_new_stream");
        CallInfo call_info{};
        call_info.source_id = receive_call.source_id;
        call_info.destination_id = receive_call.destination_id;
        call_info.slot = receive_call.slot;
        call_info.kind = receive_call.kind;
        if (resolved_source_identity) {
            call_info.callsign = resolved_source_identity->callsign;
        }
        call_info.started_ms = elapsed_ms();
        published_rx_call = call_info;
        push_event(EventKind::rx_call_started, {}, call_info);
        publish_dirty = true;
        const auto local = local_playback.snapshot();
        status(local.route == wirex::bm_local_playback::Route::local_output
            ? "bm_local_receive_playback_started" : "bm_local_receive_visible_audio_unavailable");
    };

    auto begin_stream_for_pending_rx = [&]() {
        if (!pending_receive_start || shutdown_requested) return;
        const auto route = local_playback.snapshot().route;
        if (route == wirex::bm_local_playback::Route::local_output ||
            route == wirex::bm_local_playback::Route::silent) {
            begin_local_playback_for_pending_rx();
            return;
        }
        if (!hri_ready) return;
        const auto pipeline_state = pipeline->snapshot();
        if (pipeline_state.rx_state == wirex::bm_voice::RxState::idle ||
            pipeline_state.rx_state == wirex::bm_voice::RxState::filtered ||
            pipeline_state.rx_state == wirex::bm_voice::RxState::stopping) {
            pending_receive_start = false;
            pending_receive_ended = false;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            const auto stream_phase = stream_session->snapshot().phase;
            if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
                service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
            } else if (routed_rx_hri_start_attempted) {
                const bool closed = radio_output->close();
                radio_output_open = radio_output->is_open();
                record_routed_rx_waveout_cleanup(closed);
                if (!closed) set_failure("waveout_stopping_rx_cleanup_failed");
                report_routed_rx_cleanup(false);
            } else {
                cleanup_routed_rx_without_hri_start("rx_media_idle_or_stopping_before_hri_start");
            }
            return;
        }
        const auto hri_start_decision = wirex::bm_voice::receive_hri_start_decision(pipeline_state);
        if (hri_start_decision == wirex::bm_voice::ReceiveHriStartDecision::wait_for_voice ||
            hri_start_decision == wirex::bm_voice::ReceiveHriStartDecision::discard_empty_ended_call) {
            return;
        }
        const auto stream_state = stream_session->snapshot();
        if (downlink_blocked || stream_state.phase != StreamPhase::idle || !network_ready_seen) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            if (stream_state.phase != StreamPhase::idle && stream_state.phase != StreamPhase::faulted) {
                // Receiver替换流时旧播放队列已不再属于当前通话；复位电台输出并收尾旧T会话。
                service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
            }
            cleanup_routed_rx_without_hri_start("rx_rejected_busy_or_hri_cleanup_incomplete");
            status("downlink_call_rejected_busy_or_hri_cleanup_incomplete");
            return;
        }
        if (!radio_output_open) {
            if (!hri_state.y_zero_acknowledged ||
                !radio_output->open()) {
                ++counters.rejected_calls;
                pending_receive_start = false;
                pending_receive_ended = false;
                clear_lcd_source_identity();
                pipeline->cancel_rx();
                downlink_blocked = true;
                set_failure("radio_waveout_reopen_failed");
                cleanup_routed_rx_without_hri_start("rx_rejected_waveout_reopen_failed");
                status("downlink_rejected_without_ready_radio_waveout");
                return;
            }
            radio_output_open = true;
            local_playback.output_available();
            local_audio_error.clear();
            local_playback.set_environment(true, true);
            status("radio_waveout_reopened_after_network_reconnect");
        }
        const auto now_ms = elapsed_ms();
        if (!continuous_run && now_ms >= bm_bridge_window_ms) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("rx_rejected_after_bounded_window");
            return;
        }
        const auto call_window_ms = continuous_run ? wirex::hri_stream_session::max_call_window_ms
            : std::min(wirex::hri_stream_session::max_call_window_ms, bm_bridge_window_ms - now_ms);
        using wirex::bm_voice::RxState;
        const auto& receive_call = pipeline_state.receive_call;
        const bool receive_snapshot_valid =
            (pipeline_state.rx_state == RxState::waiting_for_playback ||
             pipeline_state.rx_state == RxState::buffering ||
             pipeline_state.rx_state == RxState::playing ||
             pipeline_state.rx_state == RxState::draining) &&
            pipeline_state.receive_generation != 0U;
        if (!receive_snapshot_valid) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("rx_rejected_invalid_receive_snapshot");
            status("lcd_source_identity_rejected_invalid_receive_snapshot");
            return;
        }
        const auto resolved_source_identity = source_identity_cache.find(receive_call.source_id);
        const auto lcd_identity = resolved_source_identity.has_value()
            ? wirex::hri_lcd_identity_candidate::overlay_source_callsign(
                start_body, resolved_source_identity->callsign)
            : wirex::hri_lcd_identity_candidate::overlay_source_id_label(
                start_body, receive_call.source_id);
        if (!lcd_identity) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("rx_rejected_invalid_source_identity");
            status("lcd_source_identity_rejected_invalid_source_id");
            return;
        }
        const auto per_call_start_frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
            std::vector<std::uint8_t>(lcd_identity.body.begin(), lcd_identity.body.end())});
        if (!per_call_start_frame) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("rx_rejected_invalid_hri_start_frame");
            status("lcd_source_identity_frame_encode_failed");
            return;
        }
        const bool ended_before_hri_start = pending_receive_ended;
        auto update = stream_session->begin_call_with_start_candidate(
            per_call_start_frame.bytes, now_ms, call_window_ms);
        pending_receive_start = false;
        pending_receive_ended = false;
        if (update.error != wirex::hri_stream_session::Error::none) {
            ++counters.rejected_calls;
            clear_lcd_source_identity();
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("rx_rejected_hri_stream_start");
            status("lcd_source_identity_rejected_by_stream_session");
            return;
        }
        if (update.state.phase == StreamPhase::faulted) {
            ++counters.rejected_calls;
            downlink_blocked = true;
        } else {
            ++counters.calls_started;
            counters.lcd_source_identity_prepared = true;
            counters.lcd_source_identity_source_id = receive_call.source_id;
            counters.lcd_source_identity_generation = pipeline_state.receive_generation;
            counters.lcd_source_identity_label.assign(lcd_identity.label.data(), lcd_identity.label.size());
            counters.lcd_source_identity_label_kind = resolved_source_identity.has_value()
                ? "callsign" : "dmr_id";
            counters.lcd_source_identity_cache_revision = resolved_source_identity.has_value()
                ? resolved_source_identity->revision : 0U;
            counters.lcd_source_identity_serial_write_state = "pending";
            finish_published_rx_call("replaced_by_new_stream");
            CallInfo call_info{};
            call_info.source_id = receive_call.source_id;
            call_info.destination_id = receive_call.destination_id;
            call_info.slot = receive_call.slot;
            call_info.kind = receive_call.kind;
            if (resolved_source_identity.has_value()) {
                call_info.callsign.assign(resolved_source_identity->callsign.data(),
                                          resolved_source_identity->callsign.size());
            }
            call_info.started_ms = elapsed_ms();
            published_rx_call = call_info;
            push_event(EventKind::rx_call_started, {}, call_info);
            status(resolved_source_identity.has_value()
                ? "radio_identity_cache_hit_selected_for_receive_admission"
                : "radio_identity_source_id_fallback_selected_for_receive_admission");
            status("lcd_source_identity_prepared_for_this_call");
        }
        service_stream_update(std::move(update));
        // BM 可以在电台首次 T3 之前结束短呼叫，保留这个顺序并在许可播放后排空尾音。
        if (ended_before_hri_start && stream_session->snapshot().phase != StreamPhase::idle &&
            stream_session->snapshot().phase != StreamPhase::faulted) {
            service_stream_update(stream_session->network_ended(elapsed_ms()));
        }
    };

    auto capture_routed_rx_generation = [&]() {
        if (active_routed_rx_pipeline_generation && !routed_rx_cleanup_reported) {
            set_failure("routed_rx_generation_replaced_before_cleanup");
            return false;
        }
        const auto pipeline_state = pipeline->snapshot();
        const auto routing = pipeline->routing_snapshot();
        std::optional<wirex::bm_voice::RxGenerationMapping> mapping;
        if (routing.active_rx_mapping &&
            routing.active_rx_mapping->pipeline_generation == pipeline_state.receive_generation) {
            mapping = routing.active_rx_mapping;
        } else if (routing.stopping_rx_mapping &&
                   routing.stopping_rx_mapping->pipeline_generation == pipeline_state.receive_generation) {
            mapping = routing.stopping_rx_mapping;
        }
        if (!mapping) {
            set_failure("routed_rx_generation_mapping_missing");
            status("rx_owner_generation_mapping_missing");
            return false;
        }
        active_routed_rx_pipeline_generation = mapping->pipeline_generation;
        routed_rx_waveout_cleanup_attempted = false;
        routed_rx_waveout_cleanup_succeeded = true;
        routed_rx_cleanup_reported = false;
        routed_rx_hri_start_attempted = false;
        routed_rx_cancel_action_seen = false;
        counters.rx_router_generation = mapping->router_generation;
        counters.rx_pipeline_generation = mapping->pipeline_generation;
        counters.rx_cleanup_result = "pending";
        counters.rx_call_end_reason = "in_progress";
        counters.rx_call_missing_packets = 0U;
        counters.rx_call_accepted_voice_bursts = 0U;
        local_playback.set_environment(hri_ready && port != nullptr,
            radio_output_open && !radio_output_playback_blocked);
        const auto route = local_playback.begin_call(mapping->pipeline_generation);
        if (route == wirex::bm_local_playback::BeginResult::busy ||
            route == wirex::bm_local_playback::BeginResult::invalid_generation ||
            route == wirex::bm_local_playback::BeginResult::shutting_down) {
            ++counters.rejected_calls;
            pending_receive_start = false;
            pending_receive_ended = false;
            pipeline->cancel_rx();
            record_routed_rx_waveout_cleanup(true);
            report_routed_rx_cleanup(false);
            status("bm_local_receive_route_unavailable");
            return false;
        }
        if (route == wirex::bm_local_playback::BeginResult::local_output) {
            status("bm_local_receive_route_selected_output");
        } else if (route == wirex::bm_local_playback::BeginResult::silent) {
            status("bm_local_receive_route_selected_silent");
        }
        status("rx_owner_generation_reserved");
        return true;
    };

    auto drain_pipeline_events = [&]() {
        while (const auto event = pipeline->take_event()) {
            switch (event->kind) {
            case PipelineEventKind::receive_started:
                if (capture_routed_rx_generation()) {
                    pending_receive_start = true;
                    begin_stream_for_pending_rx();
                } else {
                    pipeline->cancel_rx();
                }
                break;
            case PipelineEventKind::network_ended:
                counters.rx_call_end_reason = receive_end_reason_name(event->end_reason);
                counters.rx_call_missing_packets = event->missing_packets;
                counters.rx_call_accepted_voice_bursts = event->accepted_voice_bursts;
                if (stream_session->snapshot().phase != StreamPhase::idle &&
                    stream_session->snapshot().phase != StreamPhase::faulted) {
                    service_stream_update(stream_session->network_ended(elapsed_ms()));
                } else if (pending_receive_start) {
                    const auto ended_snapshot = pipeline->snapshot();
                    if (wirex::bm_voice::receive_hri_start_decision(ended_snapshot) ==
                        wirex::bm_voice::ReceiveHriStartDecision::discard_empty_ended_call) {
                        pending_receive_start = false;
                        pending_receive_ended = false;
                        pipeline->cancel_rx();
                        status("bm_empty_receive_ended_without_hri_t3");
                    } else {
                        pending_receive_ended = true;
                    }
                }
                status("bm_receive_ended");
                break;
            case PipelineEventKind::playback_drained:
                if (active_routed_rx_pipeline_generation &&
                    local_playback.snapshot().call_active &&
                    local_playback.snapshot().generation == *active_routed_rx_pipeline_generation &&
                    !routed_rx_hri_start_attempted) {
                    pending_playback_drain = false;
                    ++counters.calls_ended;
                    finish_published_rx_call(counters.rx_call_end_reason);
                    record_routed_rx_waveout_cleanup(true);
                    report_routed_rx_cleanup(false);
                    status("bm_local_receive_playback_drained");
                } else {
                    pending_playback_drain = true;
                    status("bm_receive_playback_drained");
                }
                break;
            case PipelineEventKind::receive_cancelled:
                if (counters.rx_call_end_reason == "in_progress") {
                    counters.rx_call_end_reason = "cancelled";
                    counters.rx_call_missing_packets = 0U;
                }
                counters.rx_call_accepted_voice_bursts = event->accepted_voice_bursts;
                pending_receive_start = false;
                pending_receive_ended = false;
                pending_playback_drain = false;
                clear_lcd_source_identity();
                if (active_routed_rx_pipeline_generation && !routed_rx_cleanup_reported) {
                    const auto phase = stream_session->snapshot().phase;
                    if (phase != StreamPhase::idle && phase != StreamPhase::faulted &&
                        !routed_rx_cancel_action_seen) {
                        service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
                    } else if (phase == StreamPhase::idle || phase == StreamPhase::faulted) {
                        if (routed_rx_hri_start_attempted) {
                            const bool closed = radio_output->close();
                            radio_output_open = radio_output->is_open();
                            record_routed_rx_waveout_cleanup(closed);
                            if (!closed) set_failure("waveout_cancelled_rx_cleanup_failed");
                            report_routed_rx_cleanup(false);
                        } else {
                            cleanup_routed_rx_without_hri_start("rx_cancelled_before_hri_start");
                        }
                    }
                }
                status("bm_receive_cancelled");
                break;
            case PipelineEventKind::playback_start_timeout:
                counters.rx_call_end_reason = "playback_start_timeout";
                counters.rx_call_missing_packets = 0U;
                counters.rx_call_accepted_voice_bursts = event->accepted_voice_bursts;
                pending_receive_start = false;
                pending_receive_ended = false;
                clear_lcd_source_identity();
                ++counters.rejected_calls;
                status("hri_t3_start_window_expired_media_cleared");
                break;
            case PipelineEventKind::collision:
                ++counters.rejected_calls;
                if (stream_session->snapshot().phase != StreamPhase::idle &&
                    stream_session->snapshot().phase != StreamPhase::faulted) {
                    service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
                }
                status("half_duplex_collision_rejected");
                break;
            case PipelineEventKind::queue_overflow:
                ++counters.rejected_calls;
                set_failure("pipeline_queue_bound_reached");
                break;
            }
        }
    };

    auto begin_shutdown = [&](std::string_view reason) {
        if (shutdown_requested) return;
        shutdown_requested = true;
        local_playback.request_shutdown();
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        shutdown_reason.assign(reason);
        cleanup_deadline = Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms};
        pending_receive_start = false;
        pending_receive_ended = false;
        clear_lcd_source_identity();
        (void)stop_tx_input();
        const auto now_ms = elapsed_ms();
        bm_connection->cancel_pending_resolution(now_ms);
        if (pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle) {
            shutdown_tx_stream_id = active_tx_stream_id;
            shutdown_tx_terminator_pending = true;
            shutdown_tx_terminator_reported = false;
            if (bm_session.snapshot().state == wirex::bm::State::ready) {
                const auto stopped = pipeline->stop_tx(Clock::now());
                if (stopped != wirex::bm_voice::Error::none) {
                    pipeline->cancel_tx();
                    report_routed_tx_eot(false);
                    set_failure("tx_exit_terminator_failed");
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_pipeline_rejected");
                } else {
                    status("shutdown_tx_terminator_queued_for_udp_send");
                }
            } else {
                pipeline->cancel_tx();
                report_routed_tx_eot(false);
                report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_network_lost");
            }
        }
        if (hri_active && hri_state.phase != HriPhase::stopped) {
            hri_state = hri_session ? hri_session->cancel().state : wirex::hri_session::Snapshot{};
            hri_active = false;
        }
        const auto stream_phase = stream_session->snapshot().phase;
        if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
            service_stream_update(stream_session->cancel(StreamReason::cancelled, now_ms));
        } else if (pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle) {
            pipeline->cancel_rx();
            cleanup_routed_rx_without_hri_start("rx_shutdown_without_hri_stream");
        }
        status("shutdown_requested");
    };

    status("started");
    // 设备已打开：start() 的 future 在此兑现；此后的失败经快照/事件与 stop() 结果报告。
    shared.publish(build_snapshot());
    shared.resolve_start(CommandResult{CommandStatus::accepted, 0U, ""});
    if (!status_report_failed) {
        if (live_tx_permission()) {
            if (manual_ptt) {
                console(u8"诊断模式：按 T 开始或结束 BM 上行。按 Q 停止并退出。\n");
            } else {
                console(u8"等待 BM 与电台连接。\n"
                                u8"连接后按住手咪讲话；松开后等待回声。按 Q 或 Ctrl+C 停止并退出。\n");
            }
        } else {
            if (continuous_run) {
                console(u8"等待 BM 与电台连接。\n"
                                u8"连接后在所选电台扬声器收听 BM 组呼。按 Q 或 Ctrl+C 停止并退出。\n");
            } else {
                console(u8"等待 BM 与电台连接。\n"
                                u8"连接后在所选电台扬声器收听 BM 组呼。按 Q 或 Ctrl+C 停止并退出。\n");
            }
        }
    } else {
        begin_shutdown("status_report_write_failed");
    }

    auto handle_network_loss = [&](std::string_view reason) {
        const bool was_ready = network_ready_seen && !bm_connection->disable_pending();
        network_ready_seen = false;
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        operator_ready_instructions_shown = false;
        if (was_ready) ++counters.reconnects;
        (void)stop_tx_input();
        pipeline->cancel_tx();
        report_routed_tx_eot(false);
        pipeline->cancel_rx();
        clear_lcd_source_identity();
        status("bm_receive_cancelled");
        pending_receive_start = false;
        pending_receive_ended = false;
        pending_playback_drain = false;
        const auto active_local_audio = local_playback.snapshot();
        const bool bm_only_local_route = port == nullptr && !hri_ready &&
            active_local_audio.route != wirex::bm_local_playback::Route::radio;
        if (radio_output_open && !bm_only_local_route) {
            const bool closed = radio_output->close();
            radio_output_open = radio_output->is_open();
            record_routed_rx_waveout_cleanup(closed);
            if (!closed) set_failure("radio_waveout_network_cleanup_failed");
        }
        const auto phase = stream_session->snapshot().phase;
        if (shutdown_tx_terminator_pending) {
            report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_network_lost");
        }
        if (phase != StreamPhase::idle && phase != StreamPhase::faulted) {
            service_stream_update(stream_session->cancel(StreamReason::network_lost, elapsed_ms()));
        } else if (active_routed_rx_pipeline_generation) {
            cleanup_routed_rx_without_hri_start("rx_network_loss_without_hri_t0");
        }
        status(reason);
        last_logged_bm_snapshot = bm_session.snapshot();
    };

    auto routed_tx_datagram_matches_lease = [&](const wirex::dmrd::Datagram& datagram) {
        const auto routing = pipeline->routing_snapshot().router;
        if (!active_routed_tx_lease_id || !routing.active_tx_lease ||
            routing.active_tx_lease->id != *active_routed_tx_lease_id) {
            return false;
        }
        const auto& target = routing.active_tx_lease->target;
        const auto slot = (datagram.flags & 0x80U) != 0U
            ? wirex::dmr_call::Slot::ts2 : wirex::dmr_call::Slot::ts1;
        const auto kind = (datagram.flags & 0x40U) != 0U
            ? wirex::dmr_call::CallKind::private_call : wirex::dmr_call::CallKind::group;
        return datagram.source_id == call_template.source_id &&
            datagram.gateway_id == call_template.gateway_id &&
            datagram.destination_id == target.destination_id &&
            slot == target.slot && kind == target.kind &&
            datagram.stream_id == active_tx_stream_id;
    };

    auto drain_bm_outbound = [&]() {
        for (auto& packet : bm_session.take_outbound()) {
            if (packet.kind == wirex::bm::PacketKind::control ||
                packet.kind == wirex::bm::PacketKind::keepalive) ++counters.control_tx_attempted;
            wirex::dmrd::DecodeResult routed_decoded{};
            bool is_routed_tx_terminator = false;
            bool is_quick_call_frame = false;
            if (packet.kind == wirex::bm::PacketKind::application) {
                routed_decoded = wirex::dmrd::decode(packet.bytes.data(), packet.bytes.size());
                bool valid_application = false;
                if (routed_decoded && active_quick_call_plan) {
                    valid_application = active_quick_call_next_frame < active_quick_call_plan->frames.size() &&
                        wirex::quick_call::same_datagram(
                            active_quick_call_plan->frames[active_quick_call_next_frame], routed_decoded.datagram);
                    is_quick_call_frame = valid_application;
                } else if (routed_decoded) {
                    valid_application = routed_tx_datagram_matches_lease(routed_decoded.datagram);
                }
                if (!valid_application) {
                    ++counters.rejected_calls;
                    if (active_routed_tx_lease_id) {
                        pipeline->cancel_tx();
                        (void)stop_tx_input();
                        report_routed_tx_eot(false);
                    }
                    set_failure("routed_tx_udp_packet_target_or_lease_changed");
                    status("routed_tx_udp_packet_rejected_before_send");
                    transport.close();
                    bm_session.transport_lost(elapsed_ms());
                    handle_network_loss("routed_tx_udp_packet_rejected_before_send");
                    return false;
                }
                const auto packet_type = static_cast<std::uint8_t>(routed_decoded.datagram.flags & 0x3FU);
                is_routed_tx_terminator = !is_quick_call_frame && packet_type == 0x22U;
                const bool is_active_lease_header = !is_quick_call_frame && packet_type == 0x21U;
                if (!is_quick_call_frame && !live_routed_voice_permission() &&
                    !is_routed_tx_terminator && !is_active_lease_header) {
                    ++counters.rejected_calls;
                    status("bm_queued_voice_dropped_after_tx_permission_revoked");
                    continue;
                }
            }
            const bool is_rptcl = packet.kind == wirex::bm::PacketKind::control &&
                packet.bytes.size() == 9U && packet.bytes[0U] == 'R' && packet.bytes[1U] == 'P' &&
                packet.bytes[2U] == 'T' && packet.bytes[3U] == 'C' && packet.bytes[4U] == 'L';
            bool is_shutdown_terminator = false;
            if (shutdown_tx_terminator_pending && packet.kind == wirex::bm::PacketKind::application) {
                const auto decoded = wirex::dmrd::decode(packet.bytes.data(), packet.bytes.size());
                is_shutdown_terminator = decoded && decoded.datagram.stream_id == shutdown_tx_stream_id &&
                    (decoded.datagram.flags & 0x3FU) == 0x22U;
            }
            if (!transport.is_open() || !transport.send(packet.bytes.data(), packet.bytes.size())) {
                if (is_routed_tx_terminator) report_routed_tx_eot(false);
                if (is_shutdown_terminator) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_udp_send_failed");
                }
                if (is_rptcl) status("bm_rptcl_local_udp_send_failed");
                transport.close();
                bm_session.transport_lost(elapsed_ms());
                log_bm_transition("bm_state_or_failure_changed_after_control_send_failure");
                handle_network_loss("bm_udp_send_lost");
                return false;
            }
            if (packet.kind == wirex::bm::PacketKind::control ||
                packet.kind == wirex::bm::PacketKind::keepalive) ++counters.control_tx_succeeded;
            bm_session.record_outbound_sent(packet, elapsed_ms());
            if (is_quick_call_frame) {
                const auto sent_index = active_quick_call_next_frame;
                ++active_quick_call_frames_sent;
                ++active_quick_call_next_frame;
                status(sent_index == 0U
                    ? "quick_call_header_udp_send_succeeded"
                    : "quick_call_eot_udp_send_succeeded");
            }
            if (is_routed_tx_terminator) report_routed_tx_eot(true);
            if (is_shutdown_terminator) {
                shutdown_tx_terminator_pending = false;
                shutdown_tx_terminator_reported = true;
                status("shutdown_tx_terminator_udp_send_succeeded");
            }
            if (is_rptcl) status("bm_rptcl_local_udp_send_succeeded");
            if (packet.kind == wirex::bm::PacketKind::application && !is_quick_call_frame) {
                ++counters.tx_datagrams;
            }
        }
        return true;
    };

    // 结果映射与 control-v2 Dispatcher 对 QuickCallStatus 的错误码一致；revision 字段携带已发帧数。
    process_quick_call = [&](const wirex::talkgroup_routing::GroupRoute& group) -> CommandResult {
        const auto pipeline_state = pipeline->snapshot();
        const auto routing_state = pipeline->routing_snapshot().router;
        const auto hri_stream_state = stream_session->snapshot();
        const auto bm_state = bm_session.snapshot();
        const auto local_audio_state = local_playback.snapshot();
        const bool cleanup_idle = (!active_routed_tx_lease_id || routed_tx_cleanup_reported) &&
            (!active_routed_rx_pipeline_generation || routed_rx_cleanup_reported) &&
            !radio_input_open && (!radio_output_open || radio_output->all_drained()) &&
            !local_audio_state.call_active && !pending_receive_start &&
            !pending_receive_ended && !pending_playback_drain;
        // 原条件含 dispatcher->hello_seen()：协议层在 hello 之前不会转发本命令，引擎侧等价为真。
        const wirex::quick_call::Readiness readiness{
            !shutdown_requested && !failed && !bm_connection->disable_pending() &&
                !active_quick_call_plan.has_value(),
            !bm_connection->disable_pending() && network_ready_seen &&
                bm_state.state == wirex::bm::State::ready,
            transport.is_open(),
            pipeline_state.tx_state == wirex::bm_voice::TxState::idle &&
                pipeline_state.rx_state == wirex::bm_voice::RxState::idle,
            routing_state.media_owner == wirex::talkgroup_routing::MediaOwner::idle &&
                !routing_state.ptt_release_required,
            hri_stream_state.phase == StreamPhase::idle,
            cleanup_idle};
        const auto gate = wirex::quick_call::check_readiness(readiness);
        if (gate == wirex::quick_call::GateStatus::not_ready) {
            return CommandResult{CommandStatus::not_ready, 0U, "quick_call_not_ready"};
        }
        if (gate == wirex::quick_call::GateStatus::busy) {
            return CommandResult{CommandStatus::busy, 0U, "media_busy"};
        }

        std::array<std::uint8_t, 4U> stream_id{};
        if (!random_stream_id(stream_id)) return CommandResult{CommandStatus::failed, 0U, "quick_call_send_failed"};

        const auto plan_result = wirex::quick_call::make_group_plan(
            call_template.source_id, call_template.gateway_id, group,
            call_template.color_code, stream_id);
        if (!plan_result) {
            return plan_result.error == wirex::quick_call::PlanError::disconnect_group_forbidden
                ? CommandResult{CommandStatus::forbidden, 0U, "disconnect_group_forbidden"}
                : CommandResult{CommandStatus::invalid, 0U, "invalid_or_forbidden_group"};
        }

        active_quick_call_plan = plan_result.plan;
        active_quick_call_next_frame = 0U;
        active_quick_call_frames_sent = 0U;
        const auto send_result = wirex::quick_call::send_once(*active_quick_call_plan,
            [&](const wirex::dmr_call::TxPacket& frame) {
                const auto current_bm_state = bm_session.snapshot();
                if (current_bm_state.state != wirex::bm::State::ready ||
                    !network_ready_seen || !transport.is_open()) {
                    return false;
                }
                const auto encoded = wirex::dmrd::encode(frame.datagram);
                if (!encoded || !bm_session.send_dmrd(encoded.bytes.data(), encoded.bytes.size(), elapsed_ms())) {
                    return false;
                }
                const auto frames_before_drain = active_quick_call_frames_sent;
                (void)drain_bm_outbound();
                // 辅助控制包失败不能掩盖已经完成的本帧 UDP 发送；下一帧仍会重新检查通道状态。
                return active_quick_call_frames_sent == static_cast<std::uint8_t>(frames_before_drain + 1U);
            });
        const auto frames_sent = send_result.packets_sent;
        active_quick_call_plan.reset();
        active_quick_call_next_frame = 0U;
        active_quick_call_frames_sent = 0U;
        CommandResult result{CommandStatus::failed, frames_sent, "quick_call_send_failed"};
        switch (send_result.status) {
        case wirex::quick_call::SendStatus::sent:
            result = frames_sent == 2U
                ? CommandResult{CommandStatus::accepted, frames_sent, ""}
                : CommandResult{CommandStatus::failed, frames_sent, "quick_call_send_incomplete"};
            break;
        case wirex::quick_call::SendStatus::send_failed:
            break;
        case wirex::quick_call::SendStatus::partial_send:
            result.detail = "quick_call_partial_send";
            break;
        }
        push_event(EventKind::quick_call_result, result.detail.empty() ? "request_sent" : result.detail);
        return result;
    };

    auto pump_tx_datagrams = [&]() {
        while (auto packet = pipeline->take_outbound()) {
            if (!routed_tx_datagram_matches_lease(packet->datagram)) {
                pipeline->cancel_tx();
                (void)stop_tx_input();
                report_routed_tx_eot(false);
                set_failure("routed_tx_packet_target_or_lease_changed");
                ptt_gate.disarm_until_release();
                status("routed_tx_packet_rejected_target_or_lease_changed");
                return;
            }
            const auto packet_type = static_cast<std::uint8_t>(packet->datagram.flags & 0x3FU);
            const bool is_lease_header = packet_type == 0x21U;
            const bool is_lease_terminator = packet_type == 0x22U;
            if (!live_routed_voice_permission() && !is_lease_header && !is_lease_terminator) {
                ++counters.rejected_calls;
                status("tx_datagram_dropped_after_permission_revoked");
                continue;
            }
            if (bm_session.snapshot().state != wirex::bm::State::ready) {
                if (is_shutdown_terminator(*packet)) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_network_lost");
                }
                pipeline->cancel_tx();
                (void)stop_tx_input();
                report_routed_tx_eot(false);
                (void)ptt_gate.set_ready(false);
                ptt_gate.disarm_until_release();
                status("tx_stopped_bm_not_ready");
                return;
            }
            const auto encoded = wirex::dmrd::encode(packet->datagram);
            if (!encoded || !bm_session.send_dmrd(encoded.bytes.data(), encoded.bytes.size(), elapsed_ms())) {
                if (is_shutdown_terminator(*packet)) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_bm_queue_rejected");
                }
                pipeline->cancel_tx();
                (void)stop_tx_input();
                report_routed_tx_eot(false);
                ptt_gate.disarm_until_release();
                status("tx_datagram_rejected_and_queue_cleared");
                return;
            }
        }
    };

    auto begin_bm_disconnect_cleanup = [&]() {
        if (!bm_connection->disable_pending() || bm_disconnect_cleanup_started) return;
        bm_disconnect_cleanup_started = true;
        bm_disconnect_deadline = Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms};
        bm_ptt_release_required = true;
        downlink_blocked = true;
        pending_receive_start = false;
        pending_receive_ended = false;
        pending_playback_drain = false;
        clear_lcd_source_identity();
        observed_sources = wirex::routing_state::ObservedSources{};
        while (bm_session.take_received_dmrd()) ++counters.rejected_calls;

        handle_ptt_gate_action(ptt_gate.set_ready(false), "bm_disconnect_ptt_aborted");
        ptt_gate.disarm_until_release();
        const auto stream_phase = stream_session->snapshot().phase;
        if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
            service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
        } else if (pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle ||
                   active_routed_rx_pipeline_generation) {
            pipeline->cancel_rx();
            if (active_routed_rx_pipeline_generation) {
                if (routed_rx_hri_start_attempted) {
                    const bool closed = radio_output->close();
                    radio_output_open = radio_output->is_open();
                    record_routed_rx_waveout_cleanup(closed);
                    if (!closed) record_bm_disconnect_media_error("bm_disconnect_waveout_cleanup_failed");
                    report_routed_rx_cleanup(false);
                } else {
                    cleanup_routed_rx_without_hri_start("bm_disconnect_rx_without_hri_start");
                }
            }
        }
        drain_pipeline_events();
        status("bm_disconnect_media_cleanup_started");
    };

    auto advance_bm_disconnect = [&]() {
        if (!bm_connection->disable_pending()) return;
        if (!bm_disconnect_cleanup_started) begin_bm_disconnect_cleanup();
        const auto pipeline_state = pipeline->snapshot();
        const auto stream_phase = stream_session->snapshot().phase;
        const bool tx_cleanup_complete = pipeline_state.tx_state == wirex::bm_voice::TxState::idle &&
            (!active_routed_tx_lease_id || (routed_tx_eot_reported && routed_tx_cleanup_reported)) &&
            !shutdown_tx_terminator_pending;
        const bool rx_cleanup_complete = pipeline_state.rx_state == wirex::bm_voice::RxState::idle &&
            (stream_phase == StreamPhase::idle || stream_phase == StreamPhase::faulted) &&
            (!active_routed_rx_pipeline_generation || routed_rx_cleanup_reported);
        const bool media_cleanup_complete = tx_cleanup_complete && rx_cleanup_complete;
        const bool timed_out = bm_disconnect_deadline && Clock::now() >= *bm_disconnect_deadline;
        if (!media_cleanup_complete && !timed_out) return;

        if (!media_cleanup_complete && timed_out) {
            bm_connection->note_media_cleanup_timeout();
            bm_disconnect_timeout_reported = true;
            if (pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle) {
                pipeline->cancel_tx();
                (void)stop_tx_input();
                report_routed_tx_eot(false);
            }
            const auto current_stream_phase = stream_session->snapshot().phase;
            if (current_stream_phase != StreamPhase::idle && current_stream_phase != StreamPhase::faulted) {
                service_stream_update(stream_session->cancel(StreamReason::cancelled, elapsed_ms()));
            }
            if (pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle) pipeline->cancel_rx();
            if (active_routed_rx_pipeline_generation && !routed_rx_cleanup_reported) {
                const bool closed = radio_output->close();
                radio_output_open = radio_output->is_open();
                record_routed_rx_waveout_cleanup(closed);
                report_routed_rx_cleanup(false);
            }
            drain_pipeline_events();
            status("bm_disconnect_media_cleanup_timeout");
        }

        // 先排空已经生成的 TX EOT，再停止会清空 BM 媒体队列的 Session。
        if (transport.is_open()) (void)drain_bm_outbound();
        if (!bm_connection->begin_disable(elapsed_ms())) return;
        network_ready_seen = false;
        operator_ready_instructions_shown = false;
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        if (transport.is_open()) (void)drain_bm_outbound();
        bm_connection->finish_disable();
        bm_disconnect_deadline.reset();
        last_logged_bm_snapshot = bm_session.snapshot();
        status(bm_disconnect_timeout_reported ? "bm_disconnected_with_media_cleanup_error"
                                              : "bm_disconnected");
    };

    auto process_t_key = [&]() {
        if (bm_connection->disable_pending() || !live_tx_permission()) {
            ++counters.rejected_calls;
            status("tx_start_rejected_receive_only_policy");
            return;
        }
        const auto pstate = pipeline->snapshot();
        if (pstate.tx_state == wirex::bm_voice::TxState::active) {
            (void)end_tx_call();
            return;
        }
        if (pstate.tx_state == wirex::bm_voice::TxState::draining) {
            status("tx_busy_draining");
            return;
        }
        (void)start_tx_call();
    };

    auto shutdown_media_cleanup_complete = [&]() {
        const bool routed_tx_complete = !active_routed_tx_lease_id ||
            (routed_tx_eot_reported && routed_tx_cleanup_reported);
        return routed_tx_complete && !shutdown_tx_terminator_pending;
    };

    // ---------- 命令（原 control-v2 RoutingCallbacks，逐项等价） ----------
    auto apply_command = [&](Command& command) -> CommandResult {
        switch (command.kind) {
        case CommandKind::replace_rx_policy: {
            const auto update = pipeline->replace_rx_policy(command.revision, command.rx_policy);
            if (update.status == wirex::talkgroup_routing::PolicyUpdateStatus::applied) {
                report_rx_policy(command.rx_policy, update.revision);
            }
            return CommandResult{policy_status(update.status), update.revision, policy_detail(update.status)};
        }
        case CommandKind::replace_tx_policy: {
            const auto* current = pipeline->routed_tx_policy();
            if (current == nullptr || (command.flag && !launch_transmit_allowed)) {
                return CommandResult{CommandStatus::invalid, command.revision, "invalid_policy"};
            }
            auto candidate = *current;
            candidate.target = command.tx_target;
            candidate.transmit_enabled = command.flag;
            const auto update = pipeline->replace_tx_policy(command.revision, candidate);
            return CommandResult{policy_status(update.status), update.revision, policy_detail(update.status)};
        }
        case CommandKind::quick_call_join:
            return process_quick_call(command.group);
        case CommandKind::set_audio_gains:
            // 命令与 PCM 消费在同一线程：两个值在下一块 WaveIn/WaveOut 处理前同时生效。
            if (!pcm_gain::supported_gain(command.first) || !pcm_gain::supported_gain(command.second)) {
                return CommandResult{CommandStatus::invalid, audio_gains_revision, "invalid_audio_gains"};
            }
            radio_playback_gain_milli = command.first;
            mic_transmit_gain_milli = command.second;
            counters.rx_output_gain_milli = radio_playback_gain_milli;
            counters.tx_input_gain_milli = mic_transmit_gain_milli;
            ++audio_gains_revision;
            return CommandResult{CommandStatus::accepted, audio_gains_revision, ""};
        case CommandKind::set_audio_endpoints: {
            const AudioEndpoints& requested = command.audio_endpoints;
            const bool update_input = !requested.expected_wave_in_endpoint_id.empty();
            const bool update_output = !requested.expected_wave_out_endpoint_id.empty();
            if (!update_input && !update_output) {
                return CommandResult{CommandStatus::invalid, audio_endpoints_revision, "invalid_audio_endpoints"};
            }
            if (update_output && !update_input && (port != nullptr || hri_ready)) {
                return CommandResult{CommandStatus::busy, audio_endpoints_revision, "radio_audio_pair_required"};
            }
            AudioEndpoints effective = config.audio;
            if (update_input) {
                effective.expected_wave_in_endpoint_id = requested.expected_wave_in_endpoint_id;
                effective.wave_in_id = requested.wave_in_id;
            }
            if (update_output) {
                effective.expected_wave_out_endpoint_id = requested.expected_wave_out_endpoint_id;
                effective.wave_out_id = requested.wave_out_id;
            }
            const bool input_changed = update_input &&
                (effective.expected_wave_in_endpoint_id != config.audio.expected_wave_in_endpoint_id ||
                 effective.wave_in_id != config.audio.wave_in_id);
            const bool local_output_mode = port == nullptr && !hri_ready;
            const auto local_audio_before_change = local_playback.snapshot();
            const bool retry_local_output = update_output && local_output_mode &&
                (!radio_output_open || local_audio_before_change.output_error !=
                    wirex::bm_local_playback::OutputError::none);
            const bool output_changed = update_output &&
                ((effective.expected_wave_out_endpoint_id != config.audio.expected_wave_out_endpoint_id ||
                  effective.wave_out_id != config.audio.wave_out_id) || retry_local_output);
            if (!input_changed && !output_changed) {
                return CommandResult{CommandStatus::idempotent, audio_endpoints_revision, ""};
            }
            if (shutdown_requested) {
                return CommandResult{CommandStatus::not_ready, audio_endpoints_revision, "engine_stopping"};
            }
            const auto media = pipeline->routing_snapshot().router.media_owner;
            if (media != wirex::talkgroup_routing::MediaOwner::idle || radio_input_open ||
                local_playback.snapshot().call_active ||
                (radio_output_open && !radio_output->all_drained())) {
                return CommandResult{CommandStatus::busy, audio_endpoints_revision, "audio_route_busy"};
            }

            std::unique_ptr<AudioInput> next_input;
            std::unique_ptr<AudioOutput> next_output;
            const auto commit_output_selection_only = [&]() {
                config.audio.wave_out_id = effective.wave_out_id;
                config.audio.expected_wave_out_endpoint_id = effective.expected_wave_out_endpoint_id;
                ++audio_endpoints_revision;
            };
            try {
                if (input_changed) {
                    next_input = devices.make_audio_input(effective);
                    if (!next_input || !next_input->open()) {
                        if (next_input) (void)next_input->close();
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision, "wavein_open_failed"};
                    }
                    if (!next_input->close() || next_input->is_open()) {
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision, "wavein_close_failed"};
                    }
                }
                if (output_changed) {
                    next_output = devices.make_audio_output(effective);
                    if (!next_output) {
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision,
                                             "audio_device_allocation_failed"};
                    }
                }
            } catch (...) {
                return CommandResult{CommandStatus::failed, audio_endpoints_revision, "audio_device_allocation_failed"};
            }

            bool local_output_close_warning = false;
            if (output_changed && local_output_mode) {
                const bool old_was_open = radio_output_open;
                if (old_was_open) {
                    const bool old_output_closed = radio_output->close();
                    radio_output_open = radio_output->is_open();
                    if (radio_output_open) {
                        (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::close_failed);
                        local_audio_error = "waveout_close_failed";
                        publish_dirty = true;
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision,
                                             "waveout_close_failed"};
                    }
                    if (!old_output_closed) {
                        (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::close_failed);
                        local_audio_error = "waveout_old_endpoint_closed_with_cleanup_warning";
                        local_output_close_warning = true;
                    }
                }
                if (!next_output->open()) {
                    const bool candidate_closed = next_output->close();
                    radio_output_open = radio_output && radio_output->is_open();
                    if (next_output->is_open() || !candidate_closed) {
                        // The former output was released; keep ownership of the candidate even
                        // when its open/close pair cannot confirm cleanup.
                        radio_output = std::move(next_output);
                        radio_output_open = radio_output->is_open();
                        radio_output_playback_blocked = radio_output_open;
                        commit_output_selection_only();
                        (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::open_failed);
                        local_audio_error = "waveout_open_failed_cleanup_unconfirmed";
                        publish_dirty = true;
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision,
                                             local_audio_error};
                    }
                    if (radio_output && radio_output->open()) {
                        radio_output_open = radio_output->is_open();
                        radio_output_playback_blocked = false;
                        local_playback.output_available();
                        local_audio_error.clear();
                    } else {
                        radio_output_open = radio_output && radio_output->is_open();
                        radio_output_playback_blocked = radio_output_open;
                        local_playback.output_unavailable(wirex::bm_local_playback::OutputError::open_failed);
                        local_audio_error = "waveout_open_failed";
                    }
                    publish_dirty = true;
                    return CommandResult{CommandStatus::failed, audio_endpoints_revision, "waveout_open_failed"};
                }
            }

            if (output_changed && radio_output_open) {
                const bool old_output_closed = radio_output->close();
                radio_output_open = radio_output->is_open();
                if (radio_output_open) {
                    // The candidate was not opened; retain only the old output handle.
                    radio_error = "waveout_close_failed";
                    publish_dirty = true;
                    return CommandResult{CommandStatus::failed, audio_endpoints_revision, "waveout_close_failed"};
                }
                if (!next_output->open()) {
                    const bool candidate_closed = next_output->close();
                    if (next_output->is_open() || !candidate_closed) {
                        // The old output is closed and the candidate still owns a native handle.
                        // Move it into the tracked slot and publish the endpoint it actually owns.
                        radio_output = std::move(next_output);
                        radio_output_open = radio_output->is_open();
                        radio_output_playback_blocked = true;
                        (void)local_playback.output_failed(
                            wirex::bm_local_playback::OutputError::open_failed);
                        local_audio_error = "waveout_open_failed_cleanup_unconfirmed";
                        commit_output_selection_only();
                        radio_error = "waveout_open_failed_cleanup_unconfirmed";
                        publish_dirty = true;
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision, radio_error};
                    }
                    const bool old_reopened = radio_output->open();
                    radio_output_open = radio_output->is_open();
                    radio_output_playback_blocked = !old_reopened || !radio_output_open;
                    if (radio_output_playback_blocked) {
                        (void)local_playback.output_failed(
                            wirex::bm_local_playback::OutputError::open_failed);
                        local_audio_error = radio_output_open
                            ? "waveout_open_failed_restore_unconfirmed"
                            : "waveout_open_failed_restore_failed";
                    }
                    radio_error = old_reopened && radio_output_open
                        ? "waveout_open_failed"
                        : radio_output_open ? "waveout_open_failed_restore_unconfirmed"
                                            : "waveout_open_failed_restore_failed";
                    publish_dirty = true;
                    return CommandResult{CommandStatus::failed, audio_endpoints_revision, radio_error};
                }
                if (!old_output_closed) {
                    // 旧驱动报告清理失败，但设备句柄已经关闭，无法恢复旧端点。
                    // 保持新端点，发布实际端点并返回失败提示，避免快照谎报仍在使用旧设备。
                    if (input_changed) radio_input = std::move(next_input);
                    radio_output = std::move(next_output);
                    radio_output_open = radio_output->is_open();
                    radio_output_playback_blocked = false;
                    config.audio = effective;
                    ++audio_endpoints_revision;
                    radio_error = "waveout_old_endpoint_closed_with_cleanup_warning";
                    publish_dirty = true;
                    return CommandResult{CommandStatus::accepted, audio_endpoints_revision, radio_error};
                }
            } else if (output_changed && !local_output_mode) {
                if (!next_output->open()) {
                    const bool candidate_closed = next_output->close();
                    if (next_output->is_open() || !candidate_closed) {
                        radio_output = std::move(next_output);
                        radio_output_open = radio_output->is_open();
                        radio_output_playback_blocked = true;
                        (void)local_playback.output_failed(
                            wirex::bm_local_playback::OutputError::open_failed);
                        local_audio_error = "waveout_open_failed_cleanup_unconfirmed";
                        commit_output_selection_only();
                        radio_error = "waveout_open_failed_cleanup_unconfirmed";
                        publish_dirty = true;
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision, radio_error};
                    }
                    radio_error = "waveout_open_failed";
                    radio_output_playback_blocked = true;
                    (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::open_failed);
                    local_audio_error = "waveout_open_failed";
                    publish_dirty = true;
                    return CommandResult{CommandStatus::failed, audio_endpoints_revision, radio_error};
                }
                if (!(hri_ready && port != nullptr)) {
                    const bool candidate_closed = next_output->close();
                    if (!candidate_closed || next_output->is_open()) {
                        if (next_output->is_open()) {
                            radio_output = std::move(next_output);
                            radio_output_open = radio_output->is_open();
                            radio_output_playback_blocked = true;
                            (void)local_playback.output_failed(
                                wirex::bm_local_playback::OutputError::close_failed);
                            local_audio_error = "waveout_close_failed";
                            commit_output_selection_only();
                        }
                        else {
                            radio_output_playback_blocked = true;
                            (void)local_playback.output_failed(
                                wirex::bm_local_playback::OutputError::close_failed);
                            local_audio_error = "waveout_close_failed";
                        }
                        radio_error = "waveout_close_failed";
                        publish_dirty = true;
                        return CommandResult{CommandStatus::failed, audio_endpoints_revision, radio_error};
                    }
                }
            }
            if (input_changed) radio_input = std::move(next_input);
            if (output_changed) {
                radio_output = std::move(next_output);
                radio_output_open = radio_output->is_open();
                radio_output_playback_blocked = false;
            }
            config.audio = effective;
            if (output_changed && local_output_mode) {
                local_playback.output_available();
                local_audio_error.clear();
                local_output_close_pending = false;
            }
            if (output_changed && !local_output_mode && hri_ready && port != nullptr && radio_output_open) {
                local_playback.output_available();
                local_audio_error.clear();
                if (radio_error.rfind("waveout_", 0U) == 0U) radio_error.clear();
            }
            const auto local_audio = local_playback.snapshot();
            local_playback.set_environment(hri_ready && port != nullptr,
                radio_output_open && !radio_output_playback_blocked &&
                    local_audio.output_error == wirex::bm_local_playback::OutputError::none);
            publish_dirty = true;
            ++audio_endpoints_revision;
            return CommandResult{CommandStatus::accepted, audio_endpoints_revision,
                local_output_close_warning ? "waveout_old_endpoint_closed_with_cleanup_warning" : ""};
        }
        case CommandKind::upsert_radio_identity: {
            using Update = wirex::radio_identity_cache::UpsertResult;
            const auto update = command.callsign.has_value()
                ? source_identity_cache.upsert(command.first, command.revision, *command.callsign)
                : source_identity_cache.remove(command.first, command.revision);
            switch (update) {
            case Update::inserted:
            case Update::updated:
            case Update::removed:
            case Update::cleared: return CommandResult{CommandStatus::accepted, command.revision, ""};
            case Update::replayed: return CommandResult{CommandStatus::idempotent, command.revision, ""};
            case Update::invalid_source_id:
            case Update::invalid_revision:
            case Update::invalid_callsign:
                return CommandResult{CommandStatus::invalid, command.revision, "invalid_identity"};
            case Update::stale_revision:
                return CommandResult{CommandStatus::stale_revision, command.revision, "stale_identity_revision"};
            case Update::revision_conflict:
                return CommandResult{CommandStatus::stale_revision, command.revision, "identity_revision_conflict"};
            }
            return CommandResult{CommandStatus::failed, command.revision, "identity_cache_update_failed"};
        }
        case CommandKind::connect_radio:
            if (!command.radio_config) {
                return CommandResult{CommandStatus::invalid, 0U, "radio_config_missing"};
            }
            return connect_radio_runtime(*command.radio_config);
        case CommandKind::disconnect_radio:
            if (!port && !radio_audio_resource_retained()) {
                return CommandResult{CommandStatus::idempotent, 0U, "radio_not_connected"};
            }
            if (!radio_media_quiescent()) return CommandResult{CommandStatus::busy, 0U, "radio_media_busy"};
            return detach_radio({})
                ? CommandResult{CommandStatus::accepted, 0U, ""}
                : CommandResult{CommandStatus::failed, 0U, radio_error};
        case CommandKind::configure_bm: {
            if (!command.bm_target) return CommandResult{CommandStatus::invalid, 0U, "bm_config_missing"};
            const auto manager_state = bm_connection->snapshot();
            if (manager_state.requested_enabled || manager_state.transport_open || manager_state.resolving ||
                bm_connection->disable_cleanup_pending()) {
                return CommandResult{CommandStatus::busy, bm_connection->snapshot().revision,
                                     "bm_disconnect_before_configure"};
            }
            if (!radio_media_idle() || pipeline->routing_snapshot().router.media_owner !=
                    wirex::talkgroup_routing::MediaOwner::idle) {
                return CommandResult{CommandStatus::busy, bm_connection->snapshot().revision,
                                     "media_busy"};
            }
            auto target = std::move(*command.bm_target);
            ProfileSecretGuard target_secret_guard{target.profile};
            const auto source_id = target.local_source_id == 0U ? 1U : target.local_source_id;
            const auto gateway_id = target.profile.gateway_id;
            const auto color_code = target.profile.color_code;
            const auto tx_target = target.tx_policy.target;
            const bool transmit_enabled = target.tx_policy.transmit_enabled;
            std::unique_ptr<Pipeline> next_pipeline;
            try {
                next_pipeline = std::make_unique<Pipeline>();
            } catch (...) {
                return CommandResult{CommandStatus::failed, bm_connection->snapshot().revision,
                                     "bm_runtime_allocation_failed"};
            }
            if (next_pipeline->enable_routing(source_id, target.rx_policy, target.tx_policy) !=
                wirex::bm_voice::Error::none) {
                return CommandResult{CommandStatus::invalid, bm_connection->snapshot().revision,
                                     "routing_policy_invalid"};
            }
            const auto configured = bm_connection->configure(std::move(target.profile),
                std::move(target.master_host), target.master_port);
            if (configured != wirex::bm_connection::RequestResult::accepted) {
                return CommandResult{CommandStatus::busy, bm_connection->snapshot().revision,
                                     wirex::bm_connection::request_error_name(configured)};
            }
            pipeline = std::move(next_pipeline);
            config.local_source_id = source_id;
            config.rx_policy = target.rx_policy;
            config.tx_policy = target.tx_policy;
            report_rx_policy(config.rx_policy, 1U);
            call_template.source_id = source_id;
            call_template.gateway_id = gateway_id;
            call_template.destination_id = tx_target.destination_id;
            call_template.kind = tx_target.kind;
            call_template.slot = tx_target.slot;
            call_template.color_code = color_code;
            launch_transmit_allowed = transmit_enabled;
            counters.media_owner = "idle";
            network_ready_seen = false;
            operator_ready_instructions_shown = false;
            downlink_blocked = false;
            publish_dirty = true;
            return CommandResult{CommandStatus::accepted, bm_connection->snapshot().revision, ""};
        }
        case CommandKind::set_bm_connection: {
            using ManagerResult = wirex::bm_connection::RequestResult;
            if (command.flag && bm_profile_reconfigure_required) {
                return CommandResult{CommandStatus::invalid, bm_connection->snapshot().revision,
                                     "bm_profile_reconfigure_required"};
            }
            const auto result = bm_connection->set_enabled(command.flag, command.revision, elapsed_ms());
            if (command.flag && (result == ManagerResult::accepted || result == ManagerResult::idempotent) &&
                bm_connection->snapshot().requested_enabled) {
                bm_ever_requested = true;
                bm_disconnect_cleanup_started = false;
                bm_disconnect_timeout_reported = false;
                bm_disconnect_deadline.reset();
                downlink_blocked = false;
            }
            const auto actual_revision = bm_connection->snapshot().revision;
            const std::string detail = wirex::bm_connection::request_error_name(result);
            switch (result) {
            case ManagerResult::accepted: return CommandResult{CommandStatus::accepted, actual_revision, detail};
            case ManagerResult::idempotent: return CommandResult{CommandStatus::idempotent, actual_revision, detail};
            case ManagerResult::stale_revision:
            case ManagerResult::revision_conflict:
                return CommandResult{CommandStatus::stale_revision, actual_revision, detail};
            case ManagerResult::transition_busy: return CommandResult{CommandStatus::busy, actual_revision, detail};
            case ManagerResult::password_required:
            case ManagerResult::profile_invalid:
                return CommandResult{CommandStatus::invalid, actual_revision, detail};
            case ManagerResult::master_resolution_failed:
            case ManagerResult::transport_open_failed:
                return CommandResult{CommandStatus::failed, actual_revision, detail};
            }
            return CommandResult{CommandStatus::busy, actual_revision, "bm_transition_busy"};
        }
        case CommandKind::manual_ptt_toggle:
            if (!manual_ptt) return CommandResult{CommandStatus::forbidden, 0U, "manual_ptt_disabled"};
            process_t_key();
            return CommandResult{CommandStatus::accepted, 0U, ""};
        }
        return CommandResult{CommandStatus::invalid, 0U, "unknown_command"};
    };
    struct DeferredAudioCommand {
        Command command{};
        Clock::time_point deadline{};
    };
    std::deque<DeferredAudioCommand> deferred_audio_commands;
    struct DeferredBmCommand {
        DeferredBmCommand(Command&& queued_command, Clock::time_point queued_deadline) noexcept
            : command(std::move(queued_command)), deadline(queued_deadline) {}
        DeferredBmCommand(const DeferredBmCommand&) = delete;
        DeferredBmCommand& operator=(const DeferredBmCommand&) = delete;
        DeferredBmCommand(DeferredBmCommand&& other) noexcept
            : command(std::move(other.command)), deadline(other.deadline) {}
        DeferredBmCommand& operator=(DeferredBmCommand&& other) noexcept
        {
            if (this == &other) return *this;
            resolve_if_pending();
            wipe_secret();
            command = std::move(other.command);
            deadline = other.deadline;
            return *this;
        }
        ~DeferredBmCommand()
        {
            wipe_secret();
            resolve_if_pending();
        }

        void wipe_secret() noexcept
        {
            if (command.bm_target) (void)wirex::engine::detail::wipe_secret(command.bm_target->profile.password);
        }

        void resolve_if_pending() noexcept
        {
            try {
                command.promise.set_value(CommandResult{
                    CommandStatus::not_ready, command.revision, "bm_command_abandoned"});
            } catch (...) {}
        }

        Command command{};
        Clock::time_point deadline{};
    };
    std::deque<DeferredBmCommand> deferred_bm_commands;
    auto process_commands = [&]() {
        auto commands = shared.take_commands();
        const auto update_bm_profile_gate = [&](const Command& command, const CommandResult& result) {
            if (command.kind != CommandKind::configure_bm) return;
            bm_profile_reconfigure_required = result.status != CommandStatus::accepted &&
                result.status != CommandStatus::idempotent;
        };
        const auto finish_command = [&](Command& command, CommandResult result) {
            if (!live_tx_permission()) {
                (void)ptt_gate.set_ready(false);
                ptt_gate.disarm_until_release();
                if (radio_input_open) (void)stop_tx_input();
            }
            // 先发布命令生效后的快照再兑现 future：调用方拿到结果时 snapshot() 已反映新状态。
            shared.publish(build_snapshot());
            last_published_ms = elapsed_ms();
            publish_dirty = false;
            if (command.bm_target) (void)wipe_secret(command.bm_target->profile.password);
            try { command.promise.set_value(std::move(result)); } catch (...) {}
        };
        for (auto& command : commands) {
            const bool bm_operation = command.kind == CommandKind::configure_bm ||
                command.kind == CommandKind::set_bm_connection;
            if (bm_operation && !deferred_bm_commands.empty() && !shutdown_requested) {
                // Do not let later BM operations overtake a saved profile waiting behind disconnect cleanup.
                const auto deadline = Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms + 1000U};
                if (command.bm_target) {
                    ProfileSecretGuard source_secret_guard{command.bm_target->profile};
                    deferred_bm_commands.emplace_back(std::move(command), deadline);
                } else {
                    deferred_bm_commands.emplace_back(std::move(command), deadline);
                }
                continue;
            }
            CommandResult result{CommandStatus::failed, 0U, "fatal"};
            try {
                // 与原管道路径一致：收尾期间命令仍交给同一回调（BM 开关、策略、增益等仍有效）。
                result = apply_command(command);
            } catch (...) {
                result = CommandResult{CommandStatus::failed, 0U, "fatal"};
            }
            if (command.kind == CommandKind::set_audio_endpoints &&
                result.status == CommandStatus::busy && result.detail == "audio_route_busy" &&
                !shutdown_requested) {
                // 活跃媒体先完成；最多等待 30 秒，等待期间命令 future 保持 pending。
                deferred_audio_commands.push_back(
                    DeferredAudioCommand{std::move(command), Clock::now() + audio_endpoint_wait});
                continue;
            }
            const bool deferred_bm_enable = command.kind == CommandKind::set_bm_connection && command.flag &&
                result.detail == "bm_transition_busy";
            const bool deferred_bm_configure = command.kind == CommandKind::configure_bm &&
                result.detail == "bm_disconnect_before_configure";
            if (result.status == CommandStatus::busy && (deferred_bm_enable || deferred_bm_configure) &&
                bm_connection->disable_cleanup_pending() && !shutdown_requested) {
                // Configure and enable keep queue order while the previous BM disable closes its old session.
                // The temporary profile secret is wiped when the queue entry is applied or discarded.
                if (command.bm_target) {
                    ProfileSecretGuard source_secret_guard{command.bm_target->profile};
                    deferred_bm_commands.emplace_back(
                        std::move(command), Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms + 1000U});
                } else {
                    deferred_bm_commands.emplace_back(
                        std::move(command), Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms + 1000U});
                }
                continue;
            }
            update_bm_profile_gate(command, result);
            finish_command(command, std::move(result));
        }

        const auto now = Clock::now();
        for (auto it = deferred_audio_commands.begin(); it != deferred_audio_commands.end();) {
            CommandResult result{CommandStatus::failed, audio_endpoints_revision, "fatal"};
            if (shutdown_requested) {
                result = CommandResult{CommandStatus::not_ready, audio_endpoints_revision, "engine_stopping"};
            } else if (now >= it->deadline) {
                result = CommandResult{CommandStatus::busy, audio_endpoints_revision, "audio_route_busy_timeout"};
            } else {
                try {
                    result = apply_command(it->command);
                } catch (...) {
                    result = CommandResult{CommandStatus::failed, audio_endpoints_revision, "fatal"};
                }
                if (result.status == CommandStatus::busy && result.detail == "audio_route_busy") {
                    ++it;
                    continue;
                }
            }
            finish_command(it->command, std::move(result));
            it = deferred_audio_commands.erase(it);
        }

        for (auto it = deferred_bm_commands.begin(); it != deferred_bm_commands.end();) {
            CommandResult result{CommandStatus::failed, bm_connection->snapshot().revision, "fatal"};
            if (shutdown_requested) {
                result = CommandResult{CommandStatus::not_ready, bm_connection->snapshot().revision,
                                      "engine_stopping"};
            } else if (now >= it->deadline) {
                result = CommandResult{CommandStatus::busy, bm_connection->snapshot().revision,
                                       "bm_transition_timeout"};
            } else if (bm_connection->disable_cleanup_pending()) {
                ++it;
                continue;
            } else {
                try {
                    result = apply_command(it->command);
                } catch (...) {
                    result = CommandResult{CommandStatus::failed, bm_connection->snapshot().revision, "fatal"};
                }
                if (result.status == CommandStatus::busy &&
                    (result.detail == "bm_transition_busy" ||
                     result.detail == "bm_disconnect_before_configure") &&
                    bm_connection->disable_cleanup_pending()) {
                    ++it;
                    continue;
                }
            }
            update_bm_profile_gate(it->command, result);
            finish_command(it->command, std::move(result));
            it = deferred_bm_commands.erase(it);
        }
    };
    bool stop_seen = false;

    bool exception_while_running = false;
    try {
        if (!shutdown_requested) {
            if (hri_active && hri_session) {
                const auto initial = hri_session->start(0U);
                hri_state = initial.state;
                hri_active = hri_state.phase != HriPhase::stopped;
                apply_hri_update(initial);
            }
        }

        while (true) {
            const auto stream_phase_at_loop_start = stream_session->snapshot().phase;
            if (shutdown_requested && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                (stream_phase_at_loop_start == StreamPhase::idle || stream_phase_at_loop_start == StreamPhase::faulted) &&
                shutdown_media_cleanup_complete()) {
                break;
            }
            if (failed && !shutdown_requested) begin_shutdown(failure_reason);
            const auto stream_phase_after_failure_check = stream_session->snapshot().phase;
            if (shutdown_requested && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                (stream_phase_after_failure_check == StreamPhase::idle ||
                 stream_phase_after_failure_check == StreamPhase::faulted) &&
                shutdown_media_cleanup_complete()) {
                break;
            }
            synchronize_ptt_gate();
            const auto now = Clock::now();
            auto now_ms = elapsed_ms();
            if (now_ms >= next_runtime_snapshot_ms) {
                status("runtime_snapshot");
                next_runtime_snapshot_ms = now_ms + 1000U;
            }
            if (!manual_ptt) {
                handle_ptt_gate_action(ptt_gate.tick(now_ms), "ptt_call_timer_event");
            }
            if (!shutdown_requested && !continuous_run && now_ms >= bm_bridge_window_ms) {
                begin_shutdown("120s_run_window_expired");
            }
            // 原控制台取消 / UI 管道 EOF / shutdown 命令：统一为 Engine::stop() 请求。
            {
                const auto stop_request = shared.stop_state();
                if (stop_request.immediate) {
                    // 有界等待已超时：与原 console_close_cleanup_deadline_expired 相同，直接进入资源收尾。
                    set_failure(stop_request.failure_reason.empty()
                        ? "console_close_cleanup_deadline_expired" : stop_request.failure_reason);
                    cleanup_forced = true;
                    break;
                }
                if (stop_request.requested && !stop_seen) {
                    stop_seen = true;
                    if (!stop_request.failure_reason.empty()) set_failure(stop_request.failure_reason);
                    if (!shutdown_requested) {
                        begin_shutdown(stop_request.failure_reason.empty()
                            ? "engine_stop_requested" : stop_request.failure_reason);
                    }
                }
            }
            process_commands();
            begin_bm_disconnect_cleanup();
            // 命令可能打开串口/创建会话并以更新的 elapsed_ms() 启动 HRI/流会话；之后的 tick 必须用
            // 不早于该时刻的时间，否则 hri_session 判定 clock_regressed 并立即停止（R129 实机回归）。
            now_ms = std::max(now_ms, elapsed_ms());

            if (!shutdown_requested && hri_active) {
                const auto update = hri_session ? hri_session->tick(now_ms) : wirex::hri_session::Update{};
                apply_hri_update(update);
                hri_active = hri_state.phase != HriPhase::stopped && hri_session != nullptr;
            }
            service_stream_update(stream_session->tick(now_ms));
            begin_stream_for_pending_rx();

            if (port && !serial_failed) {
                std::array<std::uint8_t, 2048U> serial_bytes{};
                std::size_t actual = 0U;
                const auto read_status = port->read_available(serial_bytes.data(), serial_bytes.size(), actual);
                if (read_status == SerialReadStatus::transport_error) {
                    serial_failed = true;
                    radio_fault_pending = true;
                    radio_fault_reason = "serial_transport_error";
                } else if (read_status == SerialReadStatus::read_failed || actual > serial_bytes.size()) {
                    serial_failed = true;
                    radio_fault_pending = true;
                    radio_fault_reason = "serial_read_failed";
                } else {
                    if (actual != 0U) {
                        serial_trace(false, serial_bytes.data(), actual);
                        if (hri_active && !shutdown_requested) {
                            if (hri_session) apply_hri_update(hri_session->feed(serial_bytes.data(), actual, elapsed_ms()));
                            hri_active = hri_state.phase != HriPhase::stopped && hri_session != nullptr;
                        }
                        const auto stream_phase = stream_session->snapshot().phase;
                        if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
                            service_stream_update(stream_session->feed(serial_bytes.data(), actual, elapsed_ms()));
                        }
                        begin_stream_for_pending_rx();
                    }
                }
            }

            if (radio_fault_pending) {
                const auto reason = radio_fault_reason.empty()
                    ? std::string("radio_transport_failed") : radio_fault_reason;
                detach_radio(reason);
            }

            bm_connection->tick(now_ms);
            auto network_before = bm_session.snapshot().state;
            if (!bm_connection->disable_pending()) bm_session.tick(now_ms);
            log_bm_transition("bm_session_state_or_failure_changed_after_tick");
            if (!bm_connection->disable_pending() && !transport.is_open() &&
                bm_session.snapshot().state == wirex::bm::State::waiting_login_ack) {
                if (!transport.open(bm_connection->endpoint())) {
                    bm_session.transport_lost(now_ms);
                    set_failure("udp_reopen_failed");
                    log_bm_transition("bm_session_state_or_failure_changed_after_udp_reopen_failure");
                }
            }
            if (transport.is_open() && !drain_bm_outbound()) {
                if (network_before == wirex::bm::State::ready) handle_network_loss("bm_reconnect_started");
            }
            for (std::size_t attempt = 0U; attempt < 8U && transport.is_open(); ++attempt) {
                auto received = transport.receive(0U);
                if (received.kind == wirex::bm::ReceiveKind::timeout) break;
                if (received.kind != wirex::bm::ReceiveKind::datagram) {
                    const bool was_ready = bm_session.snapshot().state == wirex::bm::State::ready;
                    transport.close();
                    bm_session.transport_lost(elapsed_ms());
                    log_bm_transition("bm_session_state_or_failure_changed_after_receive_failure");
                    if (was_ready) handle_network_loss("bm_udp_receive_lost");
                    break;
                }
                const auto prior_state = bm_session.snapshot().state;
                const bool dmrd_magic = received.bytes.size() >= 4U &&
                    std::memcmp(received.bytes.data(), "DMRD", 4U) == 0;
                if (!dmrd_magic) ++counters.control_rx_datagrams;
                const auto input_result = bm_session.on_datagram(received.bytes.data(), received.bytes.size(),
                    received.source, elapsed_ms());
                counters.last_input_result = input_result;
                counters.has_last_input_result = true;
                if (input_result == wirex::bm::InputResult::application_datagram) {
                    ++counters.application_rx_datagrams;
                }
                log_bm_transition("bm_session_state_or_failure_changed_after_datagram");
                if (input_result != wirex::bm::InputResult::accepted &&
                    input_result != wirex::bm::InputResult::application_datagram) {
                    status("bm_datagram_result_observed");
                }
                auto current_state = bm_session.snapshot().state;
                if (prior_state != wirex::bm::State::ready && current_state == wirex::bm::State::ready) {
                    network_ready_seen = true;
                    bm_ever_ready = true;
                    maybe_show_operator_ready_instructions();
                }
                if (!bm_connection->disable_pending() && prior_state == wirex::bm::State::ready &&
                    current_state != wirex::bm::State::ready) {
                    handle_network_loss("bm_session_left_ready_state");
                }
                while (auto incoming = bm_session.take_received_dmrd()) {
                    if (bm_connection->disable_pending()) {
                        ++counters.rejected_calls;
                        continue;
                    }
                    const auto decoded = wirex::dmrd::decode(incoming->bytes.data(), incoming->bytes.size());
                    if (!decoded) {
                        ++counters.rejected_calls;
                        continue;
                    }
                    constexpr std::uint8_t dmr_flag_ts2 = 0x80U;
                    constexpr std::uint8_t dmr_flag_private_call = 0x40U;
                    const auto& datagram = decoded.datagram;
                    observed_sources.observe(datagram, call_template.source_id);
                    const auto received_slot = (datagram.flags & dmr_flag_ts2) != 0U
                        ? wirex::dmr_call::Slot::ts2 : wirex::dmr_call::Slot::ts1;
                    const auto received_call_kind = (datagram.flags & dmr_flag_private_call) != 0U
                        ? wirex::dmr_call::CallKind::private_call : wirex::dmr_call::CallKind::group;
                    counters.has_last_rx_header = true;
                    counters.last_rx_source_id = datagram.source_id;
                    counters.last_rx_destination_id = datagram.destination_id;
                    counters.last_rx_slot = static_cast<std::uint8_t>(received_slot);
                    counters.last_rx_call_kind = received_call_kind == wirex::dmr_call::CallKind::private_call
                        ? 'P' : 'G';
                    const auto active_pipeline = pipeline->snapshot();
                    const auto active_hri = stream_session->snapshot();
                    const bool hri_busy = active_hri.phase != StreamPhase::idle;
                    if ((hri_ready && downlink_blocked) || (hri_busy &&
                        (active_pipeline.rx_state == wirex::bm_voice::RxState::idle ||
                         decoded.datagram.stream_id != active_pipeline.receive_call.stream_id))) {
                        // HRI仍在T0收尾或上一通话播放时，不允许新网络流覆盖当前呼叫状态。
                        ++counters.rejected_calls;
                        continue;
                    }
                    ++counters.rx_datagrams;
                    const auto accepted = pipeline->ingest_rx(decoded.datagram, Clock::now());
                    if (accepted.error == wirex::bm_voice::Error::filtered) {
                        ++counters.rx_filtered_datagrams;
                        // routed mode可能拒绝策略不符或retired stream；不再用legacy单滤镜
                        // 推断原因，避免报告与实际Router准入结果不一致。
                        ++counters.rx_filtered_routed_path;
                        last_filtered = wirex::engine::FilteredTraffic{datagram.source_id, datagram.destination_id,
                            received_slot, received_call_kind, elapsed_ms()};
                    }
                    if (accepted.error != wirex::bm_voice::Error::none &&
                        accepted.error != wirex::bm_voice::Error::filtered &&
                        accepted.error != wirex::bm_voice::Error::half_duplex_collision) {
                        ++counters.rejected_calls;
                    }
                    drain_pipeline_events();
                }
                if (!drain_bm_outbound()) break;
            }
            if (!bm_connection->disable_pending() && network_ready_seen &&
                bm_session.snapshot().state != wirex::bm::State::ready) {
                handle_network_loss("bm_session_reconnecting");
            } else if (bm_session.snapshot().state == wirex::bm::State::ready) {
                network_ready_seen = true;
                bm_ever_ready = true;
                maybe_show_operator_ready_instructions();
            }
            synchronize_ptt_gate();

            const auto before_pipeline_tick = pipeline->snapshot();
            const auto pipeline_tick_error = pipeline->tick(Clock::now());
            if (pipeline_tick_error == wirex::bm_voice::Error::deadline_missed) {
                const auto after_pipeline_tick = pipeline->snapshot();
                if (before_pipeline_tick.tx_state != wirex::bm_voice::TxState::idle &&
                    after_pipeline_tick.tx_state == wirex::bm_voice::TxState::idle) {
                    if (!stop_tx_input()) set_failure("wavein_deadline_cleanup_failed");
                    if (!manual_ptt) ptt_gate.disarm_until_release();
                    ++counters.rejected_calls;
                    status("tx_deadline_missed_call_terminated_with_one_eot");
                }
                if (before_pipeline_tick.rx_state != wirex::bm_voice::RxState::idle &&
                    after_pipeline_tick.rx_state == wirex::bm_voice::RxState::idle) {
                    ++counters.rejected_calls;
                    pending_receive_start = false;
                    pending_receive_ended = false;
                    pending_playback_drain = false;
                    const auto stream_phase = stream_session->snapshot().phase;
                    if (stream_phase != StreamPhase::idle && stream_phase != StreamPhase::faulted) {
                        service_stream_update(stream_session->cancel(StreamReason::transport_failed, elapsed_ms()));
                    } else {
                        cleanup_routed_rx_without_hri_start("rx_deadline_without_hri_stream_cleanup");
                    }
                    status("rx_deadline_missed_media_cleared_hri_t0_cleanup");
                }
            } else if (pipeline_tick_error != wirex::bm_voice::Error::none &&
                       pipeline_tick_error != wirex::bm_voice::Error::filtered &&
                       pipeline_tick_error != wirex::bm_voice::Error::half_duplex_collision) {
                set_failure("voice_pipeline_tick_failed");
            }
            drain_pipeline_events();
            begin_stream_for_pending_rx();

            if (radio_input_open && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::active) {
                const auto captured = radio_input->take_captured(consume_tx_pcm, true, 0U);
                if (captured == CaptureStatus::event_failed) {
                    set_failure("radio_wavein_event_failed");
                } else if (captured == CaptureStatus::buffer_failed) {
                    set_failure("radio_wavein_pcm_or_requeue_failed");
                }
            }
            if (failed && !shutdown_requested) begin_shutdown(failure_reason);

            pump_tx_datagrams();
            if (transport.is_open()) (void)drain_bm_outbound();

            if (radio_output_open) {
                if (!radio_output_playback_blocked && radio_output->completion_overflowed()) {
                    const auto local = local_playback.snapshot();
                    const bool bm_local_output_mode = port == nullptr && !hri_ready &&
                        !config.audio.expected_wave_out_endpoint_id.empty();
                    if (bm_local_output_mode) {
                        (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::device_lost);
                        local_audio_error = "waveout_completion_queue_overflow";
                        if (local.call_active && active_routed_rx_pipeline_generation &&
                            !routed_rx_hri_start_attempted) {
                            discarded_local_output_generation = *active_routed_rx_pipeline_generation;
                            const auto queued = pipeline->snapshot().unconfirmed_playback_frames;
                            if (queued != 0U && pipeline->acknowledge_playback(
                                    discarded_local_output_generation, queued, Clock::now()) !=
                                    wirex::bm_voice::Error::none) {
                                set_failure("silent_playback_frame_ack_failed");
                            }
                        }
                        const bool closed = radio_output->close();
                        radio_output_open = radio_output->is_open();
                        local_output_close_pending = radio_output_open;
                        if (!closed || radio_output_open) {
                            (void)local_playback.output_failed(
                                wirex::bm_local_playback::OutputError::close_failed);
                            local_audio_error = "waveout_close_failed";
                        }
                        status(local.call_active ? "bm_local_playback_device_lost"
                                                 : "bm_local_playback_idle_device_lost");
                    } else {
                        set_failure("waveout_completion_queue_overflow");
                        begin_shutdown("waveout_completion_queue_overflow");
                    }
                }
                std::uint64_t completed_generation = 0U;
                std::size_t completed_count = 0U;
                while (radio_output->take_completed(completed_generation, completed_count)) {
                    if (completed_generation == discarded_local_output_generation) continue;
                    const auto acknowledged = pipeline->acknowledge_playback(
                        completed_generation, completed_count, Clock::now());
                    if (acknowledged != wirex::bm_voice::Error::none &&
                        acknowledged != wirex::bm_voice::Error::stale_playback_ack) {
                        set_failure("playback_frame_ack_failed");
                    }
                    if (acknowledged == wirex::bm_voice::Error::none) {
                        counters.pcm_playback_frames += completed_count;
                    }
                }
                const auto local_route = local_playback.snapshot();
                const bool draining_silently = radio_output_playback_blocked ||
                    (local_route.call_active && !routed_rx_hri_start_attempted &&
                     local_route.route == wirex::bm_local_playback::Route::silent);
                // 一轮补满设备侧水位：调度迟到后可一次追回全部在途帧。
                for (std::size_t submitted = 0U;
                     submitted < wirex::bm_voice::max_unconfirmed_playback_frames &&
                     (draining_silently || radio_output->has_capacity()); ++submitted) {
                    wirex::bm_voice::PlaybackFrame frame{};
                    if (!pipeline->take_playback_pcm(frame)) break;
                    if (draining_silently) {
                        const auto acknowledged = pipeline->acknowledge_playback(
                            frame.generation, 1U, Clock::now());
                        SecureZeroMemory(frame.pcm.data(), sizeof(frame.pcm));
                        if (acknowledged != wirex::bm_voice::Error::none) {
                            set_failure("silent_playback_frame_ack_failed");
                            break;
                        }
                        continue;
                    }
                    const auto gain = wirex::pcm_gain::apply(
                        frame.pcm.data(), frame.sample_count, radio_playback_gain_milli);
                    const bool queued = gain.valid &&
                        radio_output->submit(frame.pcm.data(), frame.sample_count, frame.generation);
                    if (queued) {
                        if (gain.before.sample_count >
                            std::numeric_limits<std::uint64_t>::max() - counters.rx_audio_samples) {
                            counters.rx_audio_samples = std::numeric_limits<std::uint64_t>::max();
                        } else {
                            counters.rx_audio_samples += gain.before.sample_count;
                        }
                        wirex::pcm_gain::accumulate(counters.rx_pcm_input_stats, gain.before);
                        wirex::pcm_gain::accumulate(counters.rx_pcm_gained_stats, gain.after);
                        rx_peak_window.push(peak_unit(gain.after.peak), Clock::now());
                        if (gain.clipped_samples >
                            std::numeric_limits<std::uint64_t>::max() - counters.rx_pcm_clipped_samples) {
                            counters.rx_pcm_clipped_samples = std::numeric_limits<std::uint64_t>::max();
                        } else {
                            counters.rx_pcm_clipped_samples += gain.clipped_samples;
                        }
                        SecureZeroMemory(frame.pcm.data(), sizeof(frame.pcm));
                        continue;
                    }
                    SecureZeroMemory(frame.pcm.data(), sizeof(frame.pcm));
                    const auto local = local_playback.snapshot();
                    if (local.call_active &&
                        local.route == wirex::bm_local_playback::Route::local_output &&
                        !routed_rx_hri_start_attempted) {
                        (void)local_playback.output_failed(gain.valid
                            ? wirex::bm_local_playback::OutputError::submit_failed
                            : wirex::bm_local_playback::OutputError::device_lost);
                        local_audio_error = gain.valid ? "waveout_playback_submit_failed"
                                                       : "waveout_playback_gain_invalid";
                        local_output_close_pending = true;
                        const auto discarded = pipeline->acknowledge_playback(
                            frame.generation, 1U, Clock::now());
                        if (discarded != wirex::bm_voice::Error::none) {
                            set_failure("silent_playback_frame_ack_failed");
                        }
                        discarded_local_output_generation = frame.generation;
                        const auto remaining_inflight = pipeline->snapshot().unconfirmed_playback_frames;
                        if (remaining_inflight != 0U && pipeline->acknowledge_playback(
                                frame.generation, remaining_inflight, Clock::now()) != wirex::bm_voice::Error::none) {
                            set_failure("silent_playback_frame_ack_failed");
                        }
                        const bool closed = radio_output->close();
                        radio_output_open = radio_output->is_open();
                        local_output_close_pending = radio_output_open;
                        if (!closed || radio_output_open) {
                            (void)local_playback.output_failed(
                                wirex::bm_local_playback::OutputError::close_failed);
                            local_audio_error = "waveout_close_failed";
                        }
                        status("bm_local_playback_failed_calls_remain_visible");
                        break;
                    }
                    pipeline->cancel_rx();
                    const bool closed = radio_output->close();
                    radio_output_open = radio_output->is_open();
                    record_routed_rx_waveout_cleanup(closed);
                    if (!closed) set_failure("waveout_submit_cleanup_failed");
                    set_failure(gain.valid ? "waveout_playback_submit_failed" : "waveout_playback_gain_invalid");
                    break;
                }
                drain_pipeline_events();
                if (pending_playback_drain && radio_output->all_drained() &&
                    stream_session->snapshot().phase == StreamPhase::draining) {
                    pending_playback_drain = false;
                    service_stream_update(stream_session->playback_drained(elapsed_ms()));
                }
            }

            const auto local_audio_snapshot = local_playback.snapshot();
            if (local_audio_snapshot.call_active &&
                ((local_audio_snapshot.route == wirex::bm_local_playback::Route::silent &&
                  !routed_rx_hri_start_attempted) || radio_output_playback_blocked)) {
                for (std::size_t discarded_frames = 0U; discarded_frames < 3U; ++discarded_frames) {
                    wirex::bm_voice::PlaybackFrame frame{};
                    if (!pipeline->take_playback_pcm(frame)) break;
                    const auto acknowledged = pipeline->acknowledge_playback(
                        frame.generation, 1U, Clock::now());
                    SecureZeroMemory(frame.pcm.data(), sizeof(frame.pcm));
                    if (acknowledged != wirex::bm_voice::Error::none) {
                        set_failure("silent_playback_frame_ack_failed");
                        break;
                    }
                }
                drain_pipeline_events();
            }

            if (local_output_close_pending && radio_output_open && radio_output->all_drained()) {
                const bool closed = radio_output->close();
                radio_output_open = radio_output->is_open();
                if (!closed || radio_output_open) {
                    (void)local_playback.output_failed(wirex::bm_local_playback::OutputError::close_failed);
                    local_audio_error = "waveout_close_failed";
                    status("bm_local_playback_waveout_close_failed");
                }
                local_output_close_pending = false;
                local_playback.set_environment(false,
                    radio_output_open && local_playback.snapshot().output_error ==
                        wirex::bm_local_playback::OutputError::none);
                publish_dirty = true;
            }

            pump_tx_datagrams();
            if (transport.is_open()) (void)drain_bm_outbound();
            advance_bm_disconnect();
            if (failed && !shutdown_requested) begin_shutdown(failure_reason);

            if (shutdown_requested && cleanup_deadline && Clock::now() >= *cleanup_deadline) {
                cleanup_forced = pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle ||
                    pipeline->snapshot().rx_state != wirex::bm_voice::RxState::idle ||
                    (stream_session->snapshot().phase != StreamPhase::idle &&
                     stream_session->snapshot().phase != StreamPhase::faulted) ||
                    !shutdown_media_cleanup_complete();
                if (cleanup_forced) {
                    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_cleanup_deadline");
                    pipeline->cancel_tx();
                    pipeline->cancel_rx();
                    (void)stop_tx_input();
                    const bool output_closed = radio_output->close();
                    radio_output_open = radio_output->is_open();
                    record_routed_rx_waveout_cleanup(output_closed);
                    set_failure("cleanup_deadline_exceeded");
                }
                break;
            }
            const auto stream_phase = stream_session->snapshot().phase;
            if (shutdown_requested && pipeline->snapshot().tx_state == wirex::bm_voice::TxState::idle &&
                (stream_phase == StreamPhase::idle || stream_phase == StreamPhase::faulted) &&
                shutdown_media_cleanup_complete()) {
                break;
            }
            publish_if_needed();
            {
                // 原 Sleep(5)：命令或停止请求到达时立即唤醒。
                std::unique_lock<std::mutex> lock(shared.mutex);
                (void)shared.loop_cv.wait_for(lock, std::chrono::milliseconds{5}, [&shared]() {
                    return !shared.commands.empty() || shared.stop.requested;
                });
            }
        }
    } catch (...) {
        exception_while_running = true;
        set_failure("runtime_exception");
        shutdown_requested = true;
        shutdown_reason = "runtime_exception";
        clear_lcd_source_identity();
        (void)ptt_gate.set_ready(false);
        ptt_gate.disarm_until_release();
        cleanup_deadline = Clock::now() + std::chrono::milliseconds{bm_bridge_cleanup_ms};
        pending_receive_start = false;
        (void)stop_tx_input();
        if (hri_active && hri_state.phase != HriPhase::stopped) {
            hri_state = hri_session ? hri_session->cancel().state : wirex::hri_session::Snapshot{};
            hri_active = false;
        }
        const auto state = stream_session->snapshot();
        if (state.start_write_attempted && !state.stop_write_attempted && port) {
            if (!serial_write(stop_frame_result.bytes.data(), stop_frame_result.bytes.size())) {
                set_failure("exception_cleanup_t0_write_failed");
            }
        }
        pipeline->cancel_tx();
        pipeline->cancel_rx();
        const bool output_closed = radio_output->close();
        radio_output_open = radio_output->is_open();
        record_routed_rx_waveout_cleanup(output_closed);
        push_event(EventKind::fatal, "引擎运行时异常，已执行有界收尾");
    }

    // 收尾期间仍在队列中的命令：明确拒绝，避免调用方永久等待。
    try { process_commands(); } catch (...) {}
    if (!shutdown_requested) begin_shutdown("runtime_loop_ended");
    report_shutdown_terminator_not_sent("shutdown_tx_terminator_not_sent_cleanup_ended");
    if (pipeline->snapshot().tx_state != wirex::bm_voice::TxState::idle) {
        pipeline->cancel_tx();
    }
    if (active_routed_tx_lease_id && !routed_tx_eot_reported) report_routed_tx_eot(false);
    pipeline->cancel_rx();
    const bool input_cleanup_ok = stop_tx_input();
    const bool output_cleanup_ok = radio_output->close();
    radio_output_open = radio_output->is_open();
    record_routed_rx_waveout_cleanup(output_cleanup_ok);
    const auto final_stream_state = stream_session->snapshot();
    report_routed_rx_cleanup(
        final_stream_state.stop_write_succeeded && final_stream_state.stop_t_record_observed);
    finish_published_rx_call("cleanup");
    bool serial_cleanup_ok = !radio_serial_close_unconfirmed;
    if (port) serial_cleanup_ok = close_serial_once(port) && serial_cleanup_ok;
    if (!bm_ever_ready && bm_ever_requested) {
        status("bm_session_never_ready_no_connection_confirmed");
    } else if (!bm_ever_ready) {
        status("bm_not_requested_before_exit");
    }
    const bool bm_ready_before_stop = bm_session.snapshot().state == wirex::bm::State::ready;
    if (bm_session.snapshot().state != wirex::bm::State::stopped) {
        bm_session.stop(elapsed_ms());
        if (bm_ready_before_stop) {
            if (transport.is_open()) {
                status("bm_rptcl_local_send_queued");
                (void)drain_bm_outbound();
            } else {
                status("bm_rptcl_not_sent_transport_closed");
            }
        } else {
            status("bm_rptcl_not_queued_bm_not_ready");
        }
    }
    transport.close();
    bool hook_cleanup_ok = true;
    if (hooks.cleanup_complete) {
        try { hook_cleanup_ok = hooks.cleanup_complete(); } catch (...) { hook_cleanup_ok = false; }
    }
    clear_lcd_source_identity();
    if (!input_cleanup_ok || !output_cleanup_ok || !serial_cleanup_ok || !hook_cleanup_ok) {
        set_failure("owned_resource_cleanup_failed");
    }
    if (exception_while_running) status("stopped_after_runtime_exception");
    else status(failed ? "stopped_with_failure" : "stopped");
    if (failed) {
        std::string final_text = "BM + FTX-1 bridge stopped with bounded cleanup; reason=";
        final_text.append(failure_reason);
        if (!bm_ever_ready) {
            final_text.append("; BM session never reached ready, so a successful connection was not confirmed");
        }
        if (status_report_failed) final_text.append("; status_report=failed");
        final_text.append(". radio_state=unknown.\n");
        console(final_text, true);
    } else {
        console("BM + FTX-1 bridge stopped; radio_state=unknown.\n", true);
    }
    (void)cleanup_forced;
    (void)shutdown_reason;
    shared.publish(build_snapshot());
    return failed ? CommandResult{CommandStatus::failed, 0U, failure_reason}
                  : CommandResult{CommandStatus::accepted, 0U, ""};
}

} // namespace wirex::engine::detail
