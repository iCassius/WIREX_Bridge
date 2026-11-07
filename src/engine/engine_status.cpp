// R127 append_bridge_status 的逐字段移植：字段名、顺序、格式与 --status-file 历史输出一致。
// 旧 WPF UI 解析 status.jsonl，这里的任何改动都必须保持输出字节不变。

#include "engine_internal.hpp"

#include "wirex/dmr_call.hpp"
#include "wirex/talkgroup_routing.hpp"

#include <chrono>
#include <cstdint>
#include <ostream>
#include <string_view>

namespace wirex::engine {

const char* hri_phase_name(wirex::hri_session::Phase phase) noexcept
{
    using wirex::hri_session::Phase;
    switch (phase) {
    case Phase::not_started: return "not_started";
    case Phase::awaiting_version_write: return "awaiting_version_write";
    case Phase::awaiting_version: return "awaiting_version";
    case Phase::waiting_for_y_due: return "waiting_for_y_due";
    case Phase::exchanging: return "exchanging";
    case Phase::stopped: return "stopped";
    }
    return "unknown";
}

const char* bm_state_name(wirex::bm::State state) noexcept
{
    using wirex::bm::State;
    switch (state) {
    case State::idle: return "idle";
    case State::waiting_login_ack: return "waiting_login_ack";
    case State::waiting_auth_ack: return "waiting_auth_ack";
    case State::waiting_config_ack: return "waiting_config_ack";
    case State::waiting_options_ack: return "waiting_options_ack";
    case State::ready: return "ready";
    case State::backoff: return "backoff";
    case State::stopped: return "stopped";
    }
    return "unknown";
}

namespace detail {

const char* bm_failure_name(wirex::bm::Failure failure) noexcept
{
    using wirex::bm::Failure;
    switch (failure) {
    case Failure::none: return "none";
    case Failure::invalid_profile: return "invalid_profile";
    case Failure::login_timeout: return "login_timeout";
    case Failure::auth_timeout: return "auth_timeout";
    case Failure::config_timeout: return "config_timeout";
    case Failure::options_timeout: return "options_timeout";
    case Failure::pong_timeout: return "pong_timeout";
    case Failure::master_rejected: return "master_rejected";
    case Failure::master_closed: return "master_closed";
    case Failure::malformed_response: return "malformed_response";
    case Failure::unexpected_response: return "unexpected_response";
    case Failure::wrong_peer_id: return "wrong_peer_id";
    case Failure::authentication_error: return "authentication_error";
    case Failure::inbound_queue_full: return "inbound_queue_full";
    case Failure::transport_lost: return "transport_lost";
    case Failure::outbound_queue_full: return "outbound_queue_full";
    }
    return "unknown";
}

const char* bm_input_result_name(wirex::bm::InputResult result) noexcept
{
    using wirex::bm::InputResult;
    switch (result) {
    case InputResult::accepted: return "accepted";
    case InputResult::application_datagram: return "application_datagram";
    case InputResult::ignored_wrong_endpoint: return "ignored_wrong_endpoint";
    case InputResult::ignored_unknown_packet: return "ignored_unknown_packet";
    case InputResult::rejected_wrong_state: return "rejected_wrong_state";
    case InputResult::rejected_malformed: return "rejected_malformed";
    case InputResult::rejected_application_queue_full: return "rejected_application_queue_full";
    case InputResult::ignored_duplicate_ack: return "ignored_duplicate_ack";
    case InputResult::master_rejected: return "master_rejected";
    case InputResult::master_closed: return "master_closed";
    }
    return "unknown";
}

const char* hri_stream_phase_name(wirex::hri_stream_session::Phase phase) noexcept
{
    using wirex::hri_stream_session::Phase;
    switch (phase) {
    case Phase::idle: return "idle";
    case Phase::start_write_pending: return "start_write_pending";
    case Phase::start_write_in_progress: return "start_write_in_progress";
    case Phase::awaiting_start_record: return "awaiting_start_record";
    case Phase::playing: return "playing";
    case Phase::draining: return "draining";
    case Phase::stop_write_pending: return "stop_write_pending";
    case Phase::stop_write_in_progress: return "stop_write_in_progress";
    case Phase::awaiting_stop_record: return "awaiting_stop_record";
    case Phase::faulted: return "faulted";
    }
    return "unknown";
}

const char* ptt_level_name(wirex::hri_session::PttLevel level) noexcept
{
    using wirex::hri_session::PttLevel;
    switch (level) {
    case PttLevel::unknown: return "unknown";
    case PttLevel::pressed: return "pressed";
    case PttLevel::released: return "released";
    }
    return "unknown";
}

const char* media_owner_name(wirex::talkgroup_routing::MediaOwner owner) noexcept
{
    using wirex::talkgroup_routing::MediaOwner;
    switch (owner) {
    case MediaOwner::idle: return "idle";
    case MediaOwner::rx_active: return "rx_active";
    case MediaOwner::rx_draining: return "rx_draining";
    case MediaOwner::rx_stopping: return "rx_stopping";
    case MediaOwner::tx_active: return "tx_active";
    case MediaOwner::tx_draining: return "tx_draining";
    case MediaOwner::fault: return "fault";
    }
    return "unknown";
}

const char* receive_media_state_name(wirex::bm_voice::RxState state) noexcept
{
    using wirex::bm_voice::RxState;
    switch (state) {
    case RxState::idle: return "idle";
    case RxState::filtered: return "filtered";
    case RxState::waiting_for_playback: return "waiting_for_playback";
    case RxState::buffering: return "buffering";
    case RxState::playing: return "playing";
    case RxState::draining: return "draining";
    case RxState::stopping: return "stopping";
    }
    return "idle";
}

const char* receive_end_reason_name(wirex::dmr_call::CallEndReason reason) noexcept
{
    using wirex::dmr_call::CallEndReason;
    switch (reason) {
    case CallEndReason::terminator: return "terminator";
    case CallEndReason::watchdog: return "watchdog";
    case CallEndReason::replaced_by_new_stream: return "replaced_by_new_stream";
    }
    return "unknown";
}

} // namespace detail

namespace {

std::uint64_t current_utc_epoch_ms() noexcept
{
    const auto elapsed = std::chrono::system_clock::now().time_since_epoch();
    const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
    return milliseconds > 0 ? static_cast<std::uint64_t>(milliseconds) : 0U;
}

} // namespace

bool append_status_line(std::ostream& file, std::string_view run_id, std::uint64_t seq,
                        const StatusRecord& record)
{
    using namespace detail;
    if (!file || run_id.empty()) return false;
    const auto& event = record.event;
    const auto elapsed_ms = record.elapsed_ms;
    const auto& bm_snapshot = record.bm;
    const auto& hri_snapshot = record.hri;
    const auto& ptt_gate_snapshot = record.ptt_gate;
    const auto& counters = record.counters;
    const auto& receive_snapshot = record.receive;
    using wirex::bm_voice::RxState;
    const bool current_call_valid = !receive_snapshot.receive_network_ended &&
        (receive_snapshot.rx_state == RxState::waiting_for_playback ||
         receive_snapshot.rx_state == RxState::buffering ||
         receive_snapshot.rx_state == RxState::playing);
    const auto& current_call = receive_snapshot.receive_call;
    const auto current_call_phase = current_call_valid
        ? receive_media_state_name(receive_snapshot.rx_state) : "none";
    const auto current_call_kind = !current_call_valid ? "none" :
        (current_call.kind == wirex::dmr_call::CallKind::private_call ? "P" : "G");
    const auto current_call_slot = current_call_valid
        ? static_cast<unsigned int>(current_call.slot) : 0U;
    const auto current_call_color_code = current_call_valid && receive_snapshot.receive_color_code_known
        ? static_cast<unsigned int>(current_call.color_code) : 0U;
    file << "{\"run_id\":\"" << run_id << "\",\"seq\":" << seq
         << ",\"timestamp_utc_ms\":" << current_utc_epoch_ms()
         << ",\"event\":\"" << event << "\",\"elapsed_ms\":" << elapsed_ms
         << ",\"bm_state\":\"" << bm_state_name(bm_snapshot.state)
         << "\",\"bm_failure\":\"" << bm_failure_name(bm_snapshot.last_failure)
         << "\",\"bm_connection\":{\"requested_enabled\":" << (counters.bm_requested_enabled ? "true" : "false")
         << ",\"revision\":" << counters.bm_connection_revision
         << ",\"transport_open\":" << (counters.bm_transport_open ? "true" : "false")
         << "},\"bm_resolving\":" << (counters.bm_resolving ? "true" : "false")
         << ",\"bm_connection_error\":\"" << counters.bm_connection_error
         << "\",\"bm_consecutive_failures\":" << bm_snapshot.consecutive_failures
         << ",\"radio_state\":\"unknown\""
         << ",\"audio_endpoints_validated\":" << (counters.audio_endpoints_validated ? "true" : "false")
         << ",\"hri_serial_open\":" << (counters.hri_serial_open ? "true" : "false")
         << ",\"hri_ready\":" << (counters.hri_ready ? "true" : "false")
         << ",\"hri_y_zero_ready\":" << (counters.hri_y_zero_ready ? "true" : "false")
         << ",\"wavein_state\":\"" << (counters.wavein_open ? "open" : "closed") << "\""
         << ",\"waveout_state\":\"" << (counters.waveout_open ? "open" : "closed") << "\""
         << ",\"media_owner\":\"" << counters.media_owner << "\""
         << ",\"rx_router_generation\":" << counters.rx_router_generation
         << ",\"rx_pipeline_generation\":" << counters.rx_pipeline_generation
         << ",\"tx_lease_id\":" << counters.tx_lease_id
         << ",\"rx_cleanup_result\":\"" << counters.rx_cleanup_result << "\""
         << ",\"rx_call_end_reason\":\"" << counters.rx_call_end_reason << "\""
         << ",\"rx_call_missing_packets\":" << counters.rx_call_missing_packets
         << ",\"rx_call_accepted_voice_bursts\":" << counters.rx_call_accepted_voice_bursts
         << ",\"tx_eot_result\":\"" << counters.tx_eot_result << "\""
         << ",\"tx_cleanup_result\":\"" << counters.tx_cleanup_result << "\""
         << ",\"control_tx_attempted\":" << counters.control_tx_attempted
         << ",\"control_tx_succeeded\":" << counters.control_tx_succeeded
         << ",\"bm_rtt_valid\":" << (bm_snapshot.rtt_valid ? "true" : "false")
         << ",\"bm_rtt_last_ms\":";
    if (bm_snapshot.rtt_valid) file << bm_snapshot.rtt_last_ms;
    else file << "null";
    file << ",\"bm_rtt_sample_count\":";
    if (bm_snapshot.rtt_valid) file << bm_snapshot.rtt_sample_count;
    else file << "null";
    file << ",\"bm_rtt_min_ms\":";
    if (bm_snapshot.rtt_valid) file << bm_snapshot.rtt_min_ms;
    else file << "null";
    file << ",\"bm_rtt_avg_ms\":";
    if (bm_snapshot.rtt_valid) file << bm_snapshot.rtt_avg_ms;
    else file << "null";
    file << ",\"bm_rtt_max_ms\":";
    if (bm_snapshot.rtt_valid) file << bm_snapshot.rtt_max_ms;
    else file << "null";
    file << ",\"rx_call_dmrd_valid\":"
         << (receive_snapshot.dmrd_sequence.call_valid ? "true" : "false")
         << ",\"rx_call_dmrd_received\":";
    if (receive_snapshot.dmrd_sequence.call_valid) file << receive_snapshot.dmrd_sequence.call_received;
    else file << "null";
    file << ",\"rx_call_dmrd_missing\":";
    if (receive_snapshot.dmrd_sequence.call_valid) file << receive_snapshot.dmrd_sequence.call_missing;
    else file << "null";
    file << ",\"rx_call_dmrd_expected\":";
    if (receive_snapshot.dmrd_sequence.call_valid) file << receive_snapshot.dmrd_sequence.call_expected;
    else file << "null";
    file << ",\"rx_call_dmrd_loss_pct\":";
    if (receive_snapshot.dmrd_sequence.call_valid && receive_snapshot.dmrd_sequence.call_expected != 0U) {
        file << static_cast<double>(receive_snapshot.dmrd_sequence.call_missing) * 100.0 /
              static_cast<double>(receive_snapshot.dmrd_sequence.call_expected);
    } else file << "null";
    file << ",\"rx_call_dmrd_loss_complete\":";
    if (receive_snapshot.dmrd_sequence.call_valid) {
        file << (receive_snapshot.dmrd_sequence.call_loss_complete ? "true" : "false");
    } else file << "null";
    file << ",\"rx_session_dmrd_valid\":"
         << (receive_snapshot.dmrd_sequence.session_valid ? "true" : "false")
         << ",\"rx_session_dmrd_received\":";
    if (receive_snapshot.dmrd_sequence.session_valid) file << receive_snapshot.dmrd_sequence.session_received;
    else file << "null";
    file << ",\"rx_session_dmrd_missing\":";
    if (receive_snapshot.dmrd_sequence.session_valid) file << receive_snapshot.dmrd_sequence.session_missing;
    else file << "null";
    file << ",\"rx_session_dmrd_expected\":";
    if (receive_snapshot.dmrd_sequence.session_valid) file << receive_snapshot.dmrd_sequence.session_expected;
    else file << "null";
    file << ",\"rx_session_dmrd_loss_pct\":";
    if (receive_snapshot.dmrd_sequence.session_valid && receive_snapshot.dmrd_sequence.session_expected != 0U) {
        file << static_cast<double>(receive_snapshot.dmrd_sequence.session_missing) * 100.0 /
              static_cast<double>(receive_snapshot.dmrd_sequence.session_expected);
    } else file << "null";
    file << ",\"rx_session_dmrd_duplicate\":";
    if (receive_snapshot.dmrd_sequence.session_valid) file << receive_snapshot.dmrd_sequence.session_duplicate;
    else file << "null";
    file << ",\"rx_session_dmrd_out_of_order\":";
    if (receive_snapshot.dmrd_sequence.session_valid) file << receive_snapshot.dmrd_sequence.session_out_of_order;
    else file << "null";
    file << ",\"rx_queue_bursts\":" << receive_snapshot.queued_rx_bursts
         << ",\"rx_queue_playback_frames\":" << receive_snapshot.queued_playback_frames
         << ",\"rx_queue_unconfirmed_playback_frames\":" << receive_snapshot.unconfirmed_playback_frames
         << ",\"rx_buffered_receive_frames\":" << receive_snapshot.buffered_receive_frames
         << ",\"control_rx_datagrams\":" << counters.control_rx_datagrams
         << ",\"application_rx_datagrams\":" << counters.application_rx_datagrams
         << ",\"last_input_result\":\""
         << (counters.has_last_input_result ? bm_input_result_name(counters.last_input_result) : "none")
         << "\",\"hri_phase\":\"" << hri_phase_name(hri_snapshot.phase)
         << "\",\"hri_y_zero_ack_records\":" << hri_snapshot.counters.y_zero_ack_received
         << ",\"hri_y_writes\":" << hri_snapshot.counters.y_write_completed
         << ",\"hri_x100_records\":" << hri_snapshot.counters.x100_received
         << ",\"hri_x_copy_records\":" << hri_snapshot.counters.x_copy_branch_count
         << ",\"hri_x_config_records\":" << hri_snapshot.counters.unsupported_config_import_records
         << ",\"hri_x_ack_writes\":" << hri_snapshot.counters.x0_write_completed
         << ",\"hri_x_ack_requested\":" << hri_snapshot.counters.x0_write_requested
         << ",\"hri_other_valid_records\":" << hri_snapshot.counters.other_valid_records
         << ",\"hri_malformed_records\":" << hri_snapshot.counters.malformed_records
         << ",\"hri_valid_records\":" << hri_snapshot.counters.valid_records
         << ",\"ptt_gate_ready\":" << (ptt_gate_snapshot.ready ? "true" : "false")
         << ",\"ptt_gate_armed\":" << (ptt_gate_snapshot.armed ? "true" : "false")
         << ",\"ptt_gate_pressed_latched\":" << (ptt_gate_snapshot.pressed_latched ? "true" : "false")
         << ",\"ptt_gate_tx_active\":" << (ptt_gate_snapshot.tx_active ? "true" : "false")
         << ",\"ptt_last_state\":\"" << ptt_level_name(counters.last_ptt_level)
         << "\",\"ptt_observations\":" << counters.ptt_observations
         << ",\"ptt_unknown_observations\":" << counters.ptt_unknown_observations
         << ",\"ptt_tx_starts\":" << counters.ptt_tx_starts
         << ",\"ptt_tx_ends\":" << counters.ptt_tx_ends
         << ",\"ptt_tx_timeouts\":" << counters.ptt_tx_timeouts
         << ",\"ptt_start_rejections\":" << counters.ptt_start_rejections
         << ",\"last_rx_header_valid\":" << (counters.has_last_rx_header ? "true" : "false")
         << ",\"last_rx_source_id\":" << counters.last_rx_source_id
         << ",\"last_rx_destination_id\":" << counters.last_rx_destination_id
         << ",\"last_rx_slot\":" << static_cast<unsigned int>(counters.last_rx_slot)
         << ",\"last_rx_call_kind\":\"" << counters.last_rx_call_kind << "\""
         << ",\"current_call_valid\":" << (current_call_valid ? "true" : "false")
         << ",\"current_call_phase\":\"" << current_call_phase << "\""
         << ",\"current_call_source_id\":" << (current_call_valid ? current_call.source_id : 0U)
         << ",\"current_call_destination_id\":" << (current_call_valid ? current_call.destination_id : 0U)
         << ",\"current_call_slot\":" << current_call_slot
         << ",\"current_call_kind\":\"" << current_call_kind << "\""
         << ",\"current_call_color_code\":" << current_call_color_code
         << ",\"current_call_link_control_validated\":"
         << (current_call_valid && receive_snapshot.receive_link_control_validated ? "true" : "false")
         << ",\"current_call_color_code_known\":"
         << (current_call_valid && receive_snapshot.receive_color_code_known ? "true" : "false")
         << ",\"current_call_generation\":" << (current_call_valid ? receive_snapshot.receive_generation : 0U)
         << ",\"receive_media_state\":\"" << receive_media_state_name(receive_snapshot.rx_state) << "\""
         << ",\"lcd_source_identity\":{\"prepared\":"
         << (counters.lcd_source_identity_prepared ? "true" : "false")
         << ",\"source_id\":" << counters.lcd_source_identity_source_id
         << ",\"receive_generation\":" << counters.lcd_source_identity_generation
         << ",\"label\":\"" << counters.lcd_source_identity_label << "\""
         << ",\"display\":\"unknown\""
         << ",\"label_kind\":\"" << counters.lcd_source_identity_label_kind << "\""
         << ",\"cache_revision\":" << counters.lcd_source_identity_cache_revision
         << ",\"serial_write_state\":\"" << counters.lcd_source_identity_serial_write_state << "\"}"
         << ",\"rx_filtered_datagrams\":" << counters.rx_filtered_datagrams
         << ",\"rx_filtered_source_id\":" << counters.rx_filtered_source_id
         << ",\"rx_filtered_destination_id\":" << counters.rx_filtered_destination_id
         << ",\"rx_filtered_slot\":" << counters.rx_filtered_slot
         << ",\"rx_filtered_call_kind\":" << counters.rx_filtered_call_kind
         << ",\"rx_filtered_protocol\":" << counters.rx_filtered_protocol
         << ",\"rx_filtered_reason\":\"" << counters.rx_filtered_reason << "\""
         << ",\"rx_filtered_stream_id\":" << counters.rx_filtered_stream_id
         << ",\"rx_filtered_routed_path\":" << counters.rx_filtered_routed_path
         << ",\"tx_datagrams\":" << counters.tx_datagrams
         << ",\"rx_datagrams\":" << counters.rx_datagrams
         << ",\"tx_audio_samples\":" << counters.tx_audio_samples
         << ",\"tx_input_gain_milli\":" << counters.tx_input_gain_milli
         << ",\"tx_pcm_input_samples\":" << counters.tx_pcm_input_stats.sample_count
         << ",\"tx_pcm_input_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.tx_pcm_input_stats)
         << ",\"tx_pcm_input_peak\":" << counters.tx_pcm_input_stats.peak
         << ",\"tx_pcm_gained_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.tx_pcm_gained_stats)
         << ",\"tx_pcm_gained_peak\":" << counters.tx_pcm_gained_stats.peak
         << ",\"tx_pcm_clipped_samples\":" << counters.tx_pcm_clipped_samples
         << ",\"rx_output_gain_milli\":" << counters.rx_output_gain_milli
         << ",\"rx_audio_samples\":" << counters.rx_audio_samples
         << ",\"rx_pcm_input_samples\":" << counters.rx_pcm_input_stats.sample_count
         << ",\"rx_pcm_input_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.rx_pcm_input_stats)
         << ",\"rx_pcm_input_peak\":" << counters.rx_pcm_input_stats.peak
         << ",\"rx_pcm_gained_rms_dbfs\":" << wirex::pcm_gain::rms_dbfs(counters.rx_pcm_gained_stats)
         << ",\"rx_pcm_gained_peak\":" << counters.rx_pcm_gained_stats.peak
         << ",\"rx_pcm_clipped_samples\":" << counters.rx_pcm_clipped_samples
         << ",\"playback_frames\":" << counters.pcm_playback_frames
         << ",\"calls_started\":" << counters.calls_started
         << ",\"calls_ended\":" << counters.calls_ended
         << ",\"rejected_calls\":" << counters.rejected_calls
         << ",\"reconnects\":" << counters.reconnects << "}\n";
    if (!file) return false;
    file.flush();
    return static_cast<bool>(file);
}

} // namespace wirex::engine
