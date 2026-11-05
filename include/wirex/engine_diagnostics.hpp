#pragma once

// 引擎原始诊断数据（R128）。用于 --status-file 兼容输出：适配层通过 DiagnosticsHooks::status
// 拿到与 R127 append_bridge_status 完全相同的输入，再用 append_status_line 逐字段输出。

#include "wirex/bm_session.hpp"
#include "wirex/bm_voice_pipeline.hpp"
#include "wirex/hri_ptt_gate.hpp"
#include "wirex/hri_session.hpp"
#include "wirex/pcm_gain.hpp"

#include <cstdint>
#include <functional>
#include <ostream>
#include <string>
#include <string_view>

namespace wirex::engine {

// 原 probe_main.cpp BmBridgeCounters；run_id 与 status 序号改由写报告的一方持有。
struct BridgeCounters {
    bool audio_endpoints_validated{};
    bool hri_serial_open{};
    bool hri_ready{};
    bool bm_requested_enabled{};
    std::uint64_t bm_connection_revision{};
    bool bm_transport_open{};
    bool bm_resolving{};
    std::string bm_connection_error{"none"};
    bool hri_y_zero_ready{};
    bool wavein_open{};
    bool waveout_open{};
    std::string media_owner{"not_started"};
    std::uint64_t rx_router_generation{};
    std::uint64_t rx_pipeline_generation{};
    std::uint64_t tx_lease_id{};
    std::string rx_cleanup_result{"not_started"};
    std::string rx_call_end_reason{"none"};
    std::uint32_t rx_call_missing_packets{};
    std::uint64_t rx_call_accepted_voice_bursts{};
    std::string tx_eot_result{"not_started"};
    std::string tx_cleanup_result{"not_started"};
    std::uint64_t tx_datagrams{};
    std::uint64_t rx_datagrams{};
    std::uint64_t control_tx_attempted{};
    std::uint64_t control_tx_succeeded{};
    std::uint64_t control_rx_datagrams{};
    std::uint64_t application_rx_datagrams{};
    bm::InputResult last_input_result{bm::InputResult::accepted};
    bool has_last_input_result{};
    std::uint64_t tx_audio_samples{};
    std::uint32_t tx_input_gain_milli{16000U};
    pcm_gain::SignalStats tx_pcm_input_stats{};
    pcm_gain::SignalStats tx_pcm_gained_stats{};
    std::uint64_t tx_pcm_clipped_samples{};
    std::uint32_t rx_output_gain_milli{pcm_gain::unity_milli};
    std::uint64_t rx_audio_samples{};
    pcm_gain::SignalStats rx_pcm_input_stats{};
    pcm_gain::SignalStats rx_pcm_gained_stats{};
    std::uint64_t rx_pcm_clipped_samples{};
    std::uint64_t pcm_playback_frames{};
    std::uint64_t calls_started{};
    std::uint64_t calls_ended{};
    std::uint64_t rejected_calls{};
    std::uint64_t reconnects{};
    std::uint64_t ptt_observations{};
    std::uint64_t ptt_unknown_observations{};
    std::uint64_t ptt_tx_starts{};
    std::uint64_t ptt_tx_ends{};
    std::uint64_t ptt_tx_timeouts{};
    std::uint64_t ptt_start_rejections{};
    hri_session::PttLevel last_ptt_level{hri_session::PttLevel::unknown};
    bool has_last_rx_header{};
    std::uint32_t last_rx_source_id{};
    std::uint32_t last_rx_destination_id{};
    std::uint8_t last_rx_slot{1U};
    char last_rx_call_kind{'G'};
    std::uint64_t rx_filtered_datagrams{};
    std::uint64_t rx_filtered_destination_id{};
    std::uint64_t rx_filtered_slot{};
    std::uint64_t rx_filtered_call_kind{};
    std::uint64_t rx_filtered_protocol{};
    std::uint64_t rx_filtered_routed_path{};
    bool lcd_source_identity_prepared{};
    std::uint32_t lcd_source_identity_source_id{};
    std::uint64_t lcd_source_identity_generation{};
    std::string lcd_source_identity_label;
    std::string lcd_source_identity_label_kind{"none"};
    std::uint64_t lcd_source_identity_cache_revision{};
    std::string lcd_source_identity_serial_write_state{"not_sent"};
};

// 一次状态事件的完整原始输入（引用只在回调期间有效）。
struct StatusRecord {
    std::string_view event;
    std::uint64_t elapsed_ms;
    const bm::Snapshot& bm;
    const hri_session::Snapshot& hri;
    const hri_ptt_gate::Snapshot& ptt_gate;
    const BridgeCounters& counters;
    const bm_voice::Snapshot& receive;
};

struct DiagnosticsHooks {
    // 在引擎线程同步调用（原 append_bridge_status 的每个调用点）。返回 false 或抛出视为
    // status_report_write_failed：引擎记录失败并进入有界收尾，此后不再调用。
    std::function<bool(const StatusRecord&)> status{};
    // 在引擎线程调用；原写往控制台的操作员提示（UTF-8）。error_stream=true 对应 stderr。
    std::function<void(std::string_view, bool error_stream)> console{};
    // 收尾时（关闭串口、发送 RPTCL 之后，最终 stopped 状态之前）调用；返回 false 记为
    // owned_resource_cleanup_failed。CLI 用它释放控制台关闭处理器。
    std::function<bool()> cleanup_complete{};
    // 可选（dev 日志）：HRI 串口每次成功写入/读到数据时在引擎线程调用。record_type 为 HRI 帧
    // （SOH + 类型 + 4 位十六进制长度 + 正文 + EOT + 校验）第 2 字节；块不以 SOH 开头时为 0。
    // 只给类型与字节数，不传正文；必须非阻塞，异常被吞掉。tx=true 为 PC→电台。
    std::function<void(bool tx, std::uint8_t record_type, std::size_t bytes, std::uint64_t elapsed_ms)> serial{};
    // 可选（dev 日志）：RX 策略生效时（启动与每次 replace_rx_policy 成功后）调用，参数为可读摘要。
    std::function<void(std::string_view summary)> rx_policy{};
};

// 与 R127 append_bridge_status 输出逐字节一致（含换行），写入后 flush。seq 由调用方递增。
[[nodiscard]] bool append_status_line(std::ostream& out, std::string_view run_id, std::uint64_t seq,
                                      const StatusRecord& record);

[[nodiscard]] const char* bm_state_name(bm::State state) noexcept;
[[nodiscard]] const char* hri_phase_name(hri_session::Phase phase) noexcept;

} // namespace wirex::engine
