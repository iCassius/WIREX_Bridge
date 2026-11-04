#pragma once

#include "services.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <set>
#include <utility>
#include <vector>

namespace wirex::gui {

struct StartupGroupActivationTarget {
    std::uint32_t destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
};

struct StartupGroupActivationStats {
    std::size_t target_count{};
    std::size_t locally_sent{};
    std::size_t failed{};
    std::size_t busy_skipped{};
    std::size_t private_skipped{};
    std::size_t disconnect_group_skipped{};
    std::size_t duplicate_skipped{};
    std::size_t invalid_skipped{};
};

// 本次进程只触发一次的启动组呼队列。接收 `accepted` 只记录本机发完两帧；
// 连接中断会暂停未处理项，重连后续做，已处理项不会重发。
class StartupGroupActivation final {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;
    static constexpr auto busy_retry_interval = std::chrono::milliseconds(500);
    static constexpr auto busy_timeout = std::chrono::seconds(30);

    enum class DecisionKind : std::uint8_t { wait, send, finished };
    struct Decision {
        DecisionKind kind{DecisionKind::wait};
        StartupGroupActivationTarget target{};
    };
    enum class ConnectionChange : std::uint8_t { none, paused, resumed };

    // 应用启动时冻结保存的组呼频道顺序。TG4000 是断开控制，不参与自动发送；
    // 相同 TG/slot 只发送一次。后续配置编辑不会改变本计划。
    bool freeze(const std::vector<services::ChannelEntry>& channels) {
        if (frozen_) return false;
        frozen_ = true;
        std::set<std::pair<std::uint32_t, dmr_call::Slot>> seen;
        for (const auto& channel : channels) {
            if (channel.kind != dmr_call::CallKind::group) {
                ++stats_.private_skipped;
                continue;
            }
            if (channel.id == 4000U) {
                ++stats_.disconnect_group_skipped;
                continue;
            }
            if (channel.id == 0U || channel.id > 16777215U ||
                (channel.slot != dmr_call::Slot::ts1 && channel.slot != dmr_call::Slot::ts2)) {
                ++stats_.invalid_skipped;
                continue;
            }
            if (!seen.emplace(channel.id, channel.slot).second) {
                ++stats_.duplicate_skipped;
                continue;
            }
            targets_.push_back({channel.id, channel.slot});
        }
        stats_.target_count = targets_.size();
        return true;
    }

    // 仅在本进程第一次观察到 BM connected 时调用，不允许重连重置本序列。
    bool activate() noexcept {
        if (!frozen_ || started_) return false;
        started_ = true;
        finished_ = targets_.empty();
        return true;
    }

    [[nodiscard]] Decision next(bool bm_connected, TimePoint now) {
        if (!started_ || finished_ || command_pending_) return {};
        if (!bm_connected) {
            clear_busy_wait();
            return {};
        }
        if (busy_since_ && now - *busy_since_ >= busy_timeout) {
            stats_.busy_skipped += remaining();
            index_ = targets_.size();
            finished_ = true;
            return {DecisionKind::finished, {}};
        }
        if (retry_at_ && now < *retry_at_) return {};
        command_pending_ = true;
        return {DecisionKind::send, targets_[index_]};
    }

    void complete(engine::CommandStatus status, bool bm_connected, TimePoint now) {
        if (!command_pending_) return;
        command_pending_ = false;
        switch (status) {
        case engine::CommandStatus::accepted:
            ++stats_.locally_sent;
            advance();
            clear_busy_wait();
            return;
        case engine::CommandStatus::busy:
            if (!bm_connected) {
                clear_busy_wait();
                return; // 当前项尚未发送，断线后等 ready 再试
            }
            if (!busy_since_) busy_since_ = now;
            retry_at_ = now + busy_retry_interval;
            return; // Engine 的 busy readiness gate 在发送任何帧前返回
        case engine::CommandStatus::not_ready:
            if (!bm_connected) return; // BM 已断开；未处理目标在同一运行期重连后续做
            ++stats_.failed;
            advance();
            clear_busy_wait();
            return;
        case engine::CommandStatus::idempotent:
        case engine::CommandStatus::stale_revision:
        case engine::CommandStatus::invalid:
        case engine::CommandStatus::forbidden:
        case engine::CommandStatus::failed:
            ++stats_.failed;
            advance();
            clear_busy_wait();
            return;
        }
    }

    [[nodiscard]] ConnectionChange observe_connection(bool connected) noexcept {
        if (!started_ || finished_) return ConnectionChange::none;
        if (!connected) {
            if (paused_) return ConnectionChange::none;
            paused_ = true;
            clear_busy_wait();
            return ConnectionChange::paused;
        }
        if (!paused_) return ConnectionChange::none;
        paused_ = false;
        return ConnectionChange::resumed;
    }

    [[nodiscard]] bool frozen() const noexcept { return frozen_; }
    [[nodiscard]] bool started() const noexcept { return started_; }
    [[nodiscard]] bool active() const noexcept { return started_ && !finished_; }
    [[nodiscard]] bool finished() const noexcept { return finished_; }
    [[nodiscard]] bool command_pending() const noexcept { return command_pending_; }
    [[nodiscard]] bool paused() const noexcept { return paused_; }
    [[nodiscard]] std::size_t remaining() const noexcept { return targets_.size() - index_; }
    [[nodiscard]] const StartupGroupActivationStats& stats() const noexcept { return stats_; }
    [[nodiscard]] std::optional<TimePoint> retry_at() const noexcept { return retry_at_; }

private:
    void advance() noexcept {
        if (index_ < targets_.size()) ++index_;
        if (index_ >= targets_.size()) finished_ = true;
    }

    void clear_busy_wait() noexcept {
        busy_since_.reset();
        retry_at_.reset();
    }

    std::vector<StartupGroupActivationTarget> targets_{};
    StartupGroupActivationStats stats_{};
    std::size_t index_{};
    std::optional<TimePoint> busy_since_{};
    std::optional<TimePoint> retry_at_{};
    bool frozen_{};
    bool started_{};
    bool finished_{};
    bool command_pending_{};
    bool paused_{};
};

} // namespace wirex::gui
