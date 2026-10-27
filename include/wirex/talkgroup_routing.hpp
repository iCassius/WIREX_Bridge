#pragma once

#include "wirex/dmr_call.hpp"

#include <cstdint>
#include <optional>
#include <vector>

namespace wirex::talkgroup_routing {

struct GroupRoute {
    std::uint32_t destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};

    [[nodiscard]] bool operator==(const GroupRoute& other) const noexcept;
};

struct PrivatePeerRoute {
    std::uint32_t source_id{};
    std::uint32_t local_destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};

    [[nodiscard]] bool operator==(const PrivatePeerRoute& other) const noexcept;
};

struct LocalPrivateRoute {
    std::uint32_t local_destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};

    [[nodiscard]] bool operator==(const LocalPrivateRoute& other) const noexcept;
};

enum class GroupMode : std::uint8_t {
    selected,
    all_delivered,
};

enum class PrivateMode : std::uint8_t {
    disabled,
    selected_peers,
    all_peers_to_local,
};

struct RxPolicy {
    GroupMode group_mode{GroupMode::selected};
    std::vector<GroupRoute> allowed_groups;
    std::vector<GroupRoute> blocked_groups;
    std::vector<std::uint32_t> blocked_source_ids;
    PrivateMode private_mode{PrivateMode::disabled};
    std::vector<PrivatePeerRoute> private_peers;
    std::vector<LocalPrivateRoute> local_private_routes;
};

struct TxTarget {
    std::uint32_t destination_id{};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    dmr_call::Slot slot{dmr_call::Slot::ts1};

    [[nodiscard]] bool operator==(const TxTarget& other) const noexcept;
};

struct TxPolicy {
    bool transmit_enabled{};
    bool dynamic_join_enabled{};
    std::vector<std::uint32_t> dynamic_join_blocked_group_ids;
    TxTarget target{};
};

enum class MediaOwner : std::uint8_t {
    idle,
    rx_active,
    rx_draining,
    rx_stopping,
    tx_active,
    tx_draining,
    fault,
};

enum class PolicyUpdateStatus : std::uint8_t {
    applied,
    revision_conflict,
    invalid_policy,
    revision_exhausted,
    resource_failure,
};

struct PolicyUpdateResult {
    PolicyUpdateStatus status{PolicyUpdateStatus::invalid_policy};
    std::uint64_t revision{};
    std::optional<std::uint64_t> cancelled_rx_generation;
    std::optional<std::uint64_t> stop_tx_lease_id;

    [[nodiscard]] explicit operator bool() const noexcept
    {
        return status == PolicyUpdateStatus::applied;
    }
};

enum class RouteMatch : std::uint8_t {
    allowed,
    policy_denied,
    blocked_group,
    blocked_source,
    invalid_call,
};

enum class ObservationLevel : std::uint8_t {
    outer_header_seen,
    link_control_validated,
    router_reserved,
    playback_started,
};

struct RouteCandidate {
    dmr_call::CallConfig observed_call{};
    ObservationLevel observation_level{ObservationLevel::outer_header_seen};
    std::optional<GroupRoute> group_route;
    std::optional<std::uint32_t> private_peer_source_id;
};

enum class RxDecision : std::uint8_t {
    admitted,
    same_active_call,
    candidate_only,
    not_call_start,
    policy_denied,
    blocked_group,
    blocked_source,
    invalid_call,
    media_busy,
    stopping,
    generation_exhausted,
};

struct RxAdmission {
    RxDecision decision{RxDecision::invalid_call};
    std::uint64_t generation{};
    std::optional<GroupRoute> candidate_group;

    [[nodiscard]] bool admitted() const noexcept
    {
        return decision == RxDecision::admitted || decision == RxDecision::same_active_call;
    }
};

enum class TxPurpose : std::uint8_t {
    ptt,
    quick_call_join,
};

enum class TxStartStatus : std::uint8_t {
    started,
    explicit_action_required,
    transmit_disabled,
    dynamic_join_disabled,
    dynamic_join_blocked,
    policy_forbidden_target,
    ptt_release_required,
    media_busy,
    invalid_target,
    lease_id_exhausted,
};

struct TxLease {
    std::uint64_t id{};
    TxTarget target{};
    TxPurpose purpose{TxPurpose::ptt};
    std::uint64_t policy_revision{};
    bool ptt_release_seen{};
    bool admission_revoked{};
    bool eot_pending{};
    std::optional<bool> eot_sent;
};

struct TxStartResult {
    TxStartStatus status{TxStartStatus::invalid_target};
    std::optional<TxLease> lease;

    [[nodiscard]] explicit operator bool() const noexcept
    {
        return status == TxStartStatus::started && lease.has_value();
    }
};

enum class OperationStatus : std::uint8_t {
    completed,
    not_active,
    stale_generation,
    stale_lease,
    wrong_phase,
    cleanup_failed,
    send_failed,
    generation_exhausted,
};

struct Snapshot {
    MediaOwner media_owner{MediaOwner::idle};
    std::uint64_t rx_policy_revision{1U};
    std::uint64_t tx_policy_revision{1U};
    std::optional<dmr_call::CallConfig> active_rx_call;
    std::uint64_t active_rx_generation{};
    std::optional<TxLease> active_tx_lease;
    bool generation_exhausted{};
    bool lease_id_exhausted{};
    bool ptt_release_required{};
};

class Router final {
public:
    static constexpr std::uint32_t max_radio_id = 0x00ffffffU;

    explicit Router(std::uint32_t local_source_id) noexcept;

    // 在单线程事件循环中调用。revision 用于识别过期更新，不提供线程同步。

    [[nodiscard]] bool valid() const noexcept { return valid_; }
    [[nodiscard]] std::uint32_t local_source_id() const noexcept { return local_source_id_; }

    [[nodiscard]] PolicyUpdateResult replace_rx_policy(std::uint64_t expected_revision,
                                                        const RxPolicy& candidate) noexcept;
    [[nodiscard]] PolicyUpdateResult replace_tx_policy(std::uint64_t expected_revision,
                                                        const TxPolicy& candidate) noexcept;
    // 只返回候选值；不缓存、不订阅、不准入，也不启动播放。
    [[nodiscard]] std::optional<RouteCandidate> observe_candidate(
        const dmr_call::CallConfig& call,
        ObservationLevel observation_level) const noexcept;
    [[nodiscard]] RouteMatch match_receive(const dmr_call::CallConfig& call) const noexcept;
    // 只接受上游已验证的新通话开始，或当前活动流的后续帧。
    [[nodiscard]] RxAdmission admit_rx(const dmr_call::CallConfig& call,
                                       bool call_start) noexcept;

    // 返回当前 RX generation，等待外层完成媒体与 HRI 清理。
    [[nodiscard]] std::optional<std::uint64_t> request_rx_stop() noexcept;
    [[nodiscard]] OperationStatus rx_network_eot(std::uint64_t generation) noexcept;
    [[nodiscard]] OperationStatus rx_playback_finished(std::uint64_t generation) noexcept;
    [[nodiscard]] OperationStatus complete_rx_stop(std::uint64_t generation,
                                                    bool cleanup_succeeded) noexcept;

    [[nodiscard]] TxStartResult begin_ptt() noexcept;
    [[nodiscard]] TxStartResult request_dynamic_join(const GroupRoute& group,
                                                      bool explicit_user_action) noexcept;
    [[nodiscard]] OperationStatus release_tx(std::uint64_t lease_id) noexcept;
    // 硬件报告手咪已松开后，清除安全锁存。
    [[nodiscard]] OperationStatus observe_ptt_release() noexcept;
    [[nodiscard]] OperationStatus complete_tx_eot(std::uint64_t lease_id,
                                                   bool sent) noexcept;
    [[nodiscard]] OperationStatus complete_tx_cleanup(std::uint64_t lease_id,
                                                       bool cleanup_succeeded) noexcept;

    [[nodiscard]] Snapshot snapshot() const noexcept;
    [[nodiscard]] const RxPolicy& rx_policy() const noexcept { return rx_policy_; }
    [[nodiscard]] const TxPolicy& tx_policy() const noexcept { return tx_policy_; }

private:
    friend struct RouterTestAccess;

    [[nodiscard]] bool valid_rx_policy(const RxPolicy& policy) const noexcept;
    [[nodiscard]] bool valid_tx_policy(const TxPolicy& policy) const noexcept;
    [[nodiscard]] bool valid_call(const dmr_call::CallConfig& call) const noexcept;
    [[nodiscard]] bool valid_target(const TxTarget& target) const noexcept;
    [[nodiscard]] bool rx_policy_accepts(const dmr_call::CallConfig& call) const noexcept;
    [[nodiscard]] bool blocked_source(std::uint32_t source_id) const noexcept;
    [[nodiscard]] bool blocked_group(const GroupRoute& route) const noexcept;
    [[nodiscard]] bool same_call(const dmr_call::CallConfig& left,
                                 const dmr_call::CallConfig& right) const noexcept;
    [[nodiscard]] TxStartResult begin_tx(const TxTarget& target, TxPurpose purpose) noexcept;
    [[nodiscard]] bool allocate_rx_generation(std::uint64_t& generation) noexcept;
    [[nodiscard]] bool allocate_lease_id(std::uint64_t& lease_id) noexcept;
    void clear_rx_owner() noexcept;
    void clear_tx_owner() noexcept;

    std::uint32_t local_source_id_{};
    bool valid_{};
    RxPolicy rx_policy_{};
    TxPolicy tx_policy_{};
    std::uint64_t rx_policy_revision_{1U};
    std::uint64_t tx_policy_revision_{1U};
    MediaOwner media_owner_{MediaOwner::idle};
    std::optional<dmr_call::CallConfig> active_rx_call_;
    std::uint64_t active_rx_generation_{};
    std::uint64_t next_rx_generation_{1U};
    bool rx_generation_exhausted_{};
    std::optional<TxLease> active_tx_lease_;
    std::uint64_t next_lease_id_{1U};
    bool lease_id_exhausted_{};
    bool fault_is_rx_{};
    bool ptt_release_required_{};
};

} // namespace wirex::talkgroup_routing
