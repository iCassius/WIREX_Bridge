#pragma once

// FTX-1 CAT `RI0;`（RADIO INFORMATION，只读）应答解析与 FM 中继的静噪门控。
// 手册 FTX-1_CAT_OM_ENG_2508-C 第 22 页：应答为 `RI` P1..P8 `;`（11 字节）。
//   P1 固定 0；P2 0 正常 / 1 Hi-SWR；P3 0 停止 / 1 录音 / 2 回放；P4 0 RX / 1 TX / 2 TX INHIBIT；
//   P5 固定 0；P6 0 天调停止 / 1 调谐中；P7 0 扫描停止 / 1 扫描中 / 2 扫描暂停；P8 0 SQL 关 / 1 SQL 开（BUSY）。
// 实测空闲应答为 `RI00000000;`（research/hil/2026-10-22_*.json）。

#include <chrono>
#include <optional>
#include <string_view>

namespace wirex::app::radio_info {

enum class TxState : unsigned char { rx, tx, tx_inhibit };
enum class ScanState : unsigned char { stopped, scanning, paused };

struct RadioInfo {
    bool hi_swr{};
    unsigned char playback{};      // P3：0 停止 / 1 录音 / 2 回放
    TxState tx{TxState::rx};
    bool tuning{};
    ScanState scan{ScanState::stopped};
    bool squelch_open{};           // P8
};

inline constexpr std::string_view query_command = "RI0;";

// 只接受恰好 11 字节、P1/P5 为 '0'、各字段在手册取值范围内的应答；其它返回 nullopt。
[[nodiscard]] std::optional<RadioInfo> parse(std::string_view answer) noexcept;

// FM 中继静噪门控：轮询采样 → 开门/关门事件。
//   开门：连续 open_samples 次 SQL 开（抗单次误码/噪声尖峰）；
//   关门：SQL 关持续 hang 时长（避免语句间短暂停顿被切断）；
//   发射中（tx != rx）或采样失败超过 stale 时长：立即关门（不能把自己的发射当作来话）。
struct GateConfig {
    unsigned open_samples{2U};
    std::chrono::milliseconds hang{std::chrono::milliseconds{600}};
    std::chrono::milliseconds stale{std::chrono::milliseconds{1000}};
};

enum class GateEvent : unsigned char { none, opened, closed };

class SquelchGate final {
public:
    using Clock = std::chrono::steady_clock;
    explicit SquelchGate(GateConfig config = {}) noexcept : config_(config) {}

    // 每次轮询结果调用一次；info 为空表示本次查询失败/超时。
    GateEvent sample(const std::optional<RadioInfo>& info, Clock::time_point now) noexcept;
    // 无新采样时也要周期调用，用于 stale 判定。
    GateEvent tick(Clock::time_point now) noexcept;

    [[nodiscard]] bool open() const noexcept { return open_; }
    void reset() noexcept;

private:
    GateEvent close_gate() noexcept;

    GateConfig config_{};
    bool open_{};
    unsigned consecutive_open_{};
    std::optional<Clock::time_point> closed_since_{};
    std::optional<Clock::time_point> last_good_sample_{};
};

} // namespace wirex::app::radio_info
