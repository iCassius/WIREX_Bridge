#include "wirex/talkgroup_routing.hpp"

#include <limits>
#include <utility>

namespace wirex::talkgroup_routing {
namespace {

[[nodiscard]] bool valid_slot(dmr_call::Slot slot) noexcept
{
    return slot == dmr_call::Slot::ts1 || slot == dmr_call::Slot::ts2;
}

[[nodiscard]] bool valid_kind(dmr_call::CallKind kind) noexcept
{
    return kind == dmr_call::CallKind::group || kind == dmr_call::CallKind::private_call;
}

[[nodiscard]] bool valid_id(std::uint32_t id) noexcept
{
    return id != 0U && id <= Router::max_radio_id;
}

[[nodiscard]] bool contains_id(const std::vector<std::uint32_t>& ids,
                               std::uint32_t id) noexcept
{
    for (const auto candidate : ids) {
        if (candidate == id) return true;
    }
    return false;
}

[[nodiscard]] bool contains_route(const std::vector<GroupRoute>& routes,
                                  const GroupRoute& route) noexcept
{
    for (const auto& candidate : routes) {
        if (candidate == route) return true;
    }
    return false;
}

[[nodiscard]] bool contains_peer(const std::vector<PrivatePeerRoute>& routes,
                                 const PrivatePeerRoute& route) noexcept
{
    for (const auto& candidate : routes) {
        if (candidate == route) return true;
    }
    return false;
}

[[nodiscard]] bool contains_local_route(const std::vector<LocalPrivateRoute>& routes,
                                        const LocalPrivateRoute& route) noexcept
{
    for (const auto& candidate : routes) {
        if (candidate == route) return true;
    }
    return false;
}

[[nodiscard]] bool protected_receive_only_target(const TxTarget& target) noexcept
{
    return target.kind == dmr_call::CallKind::group &&
           (target.destination_id == 91U || target.destination_id == 46001U);
}

} // 匿名命名空间

std::optional<RouteCandidate> Router::observe_candidate(
    const dmr_call::CallConfig& call,
    ObservationLevel observation_level) const noexcept
{
    if (!valid_ || !valid_call(call) ||
        (observation_level != ObservationLevel::outer_header_seen &&
         observation_level != ObservationLevel::link_control_validated &&
         observation_level != ObservationLevel::router_reserved &&
         observation_level != ObservationLevel::playback_started)) {
        return std::nullopt;
    }
    RouteCandidate candidate{};
    candidate.observed_call = call;
    candidate.observation_level = observation_level;
    if (call.kind == dmr_call::CallKind::group) {
        candidate.group_route = GroupRoute{call.destination_id, call.slot};
    } else {
        if (call.destination_id != local_source_id_) return std::nullopt;
        candidate.private_peer_source_id = call.source_id;
    }
    return candidate;
}

bool GroupRoute::operator==(const GroupRoute& other) const noexcept
{
    return destination_id == other.destination_id && slot == other.slot;
}

bool PrivatePeerRoute::operator==(const PrivatePeerRoute& other) const noexcept
{
    return source_id == other.source_id &&
           local_destination_id == other.local_destination_id &&
           slot == other.slot;
}

bool LocalPrivateRoute::operator==(const LocalPrivateRoute& other) const noexcept
{
    return local_destination_id == other.local_destination_id && slot == other.slot;
}

bool TxTarget::operator==(const TxTarget& other) const noexcept
{
    return destination_id == other.destination_id && kind == other.kind && slot == other.slot;
}

Router::Router(std::uint32_t local_source_id) noexcept
    : local_source_id_(local_source_id),
      valid_(valid_id(local_source_id))
{
}

PolicyUpdateResult Router::replace_rx_policy(std::uint64_t expected_revision,
                                             const RxPolicy& candidate) noexcept
{
    if (!valid_) return {PolicyUpdateStatus::invalid_policy, rx_policy_revision_, std::nullopt};
    if (expected_revision != rx_policy_revision_) {
        return {PolicyUpdateStatus::revision_conflict, rx_policy_revision_, std::nullopt};
    }
    if (!valid_rx_policy(candidate)) {
        return {PolicyUpdateStatus::invalid_policy, rx_policy_revision_, std::nullopt};
    }
    if (rx_policy_revision_ == std::numeric_limits<std::uint64_t>::max()) {
        return {PolicyUpdateStatus::revision_exhausted, rx_policy_revision_, std::nullopt};
    }

    RxPolicy next;
    try {
        next = candidate;
    } catch (...) {
        return {PolicyUpdateStatus::resource_failure, rx_policy_revision_, std::nullopt};
    }

    rx_policy_ = std::move(next);
    ++rx_policy_revision_;
    std::optional<std::uint64_t> cancelled_generation;
    if ((media_owner_ == MediaOwner::rx_active || media_owner_ == MediaOwner::rx_draining) &&
        active_rx_call_ && !rx_policy_accepts(*active_rx_call_)) {
        media_owner_ = MediaOwner::rx_stopping;
        cancelled_generation = active_rx_generation_;
    }
    return {PolicyUpdateStatus::applied, rx_policy_revision_, cancelled_generation};
}

PolicyUpdateResult Router::replace_tx_policy(std::uint64_t expected_revision,
                                             const TxPolicy& candidate) noexcept
{
    if (!valid_) return {PolicyUpdateStatus::invalid_policy, tx_policy_revision_, std::nullopt};
    if (expected_revision != tx_policy_revision_) {
        return {PolicyUpdateStatus::revision_conflict, tx_policy_revision_, std::nullopt};
    }
    if (!valid_tx_policy(candidate)) {
        return {PolicyUpdateStatus::invalid_policy, tx_policy_revision_, std::nullopt};
    }
    if (tx_policy_revision_ == std::numeric_limits<std::uint64_t>::max()) {
        return {PolicyUpdateStatus::revision_exhausted, tx_policy_revision_, std::nullopt};
    }

    TxPolicy next;
    try {
        next = candidate;
    } catch (...) {
        return {PolicyUpdateStatus::resource_failure, tx_policy_revision_, std::nullopt};
    }

    const bool transmit_revoked = tx_policy_.transmit_enabled && !next.transmit_enabled;
    const bool dynamic_join_revoked = tx_policy_.dynamic_join_enabled && !next.dynamic_join_enabled;
    tx_policy_ = std::move(next);
    ++tx_policy_revision_;
    std::optional<std::uint64_t> stop_tx_lease_id;
    if (active_tx_lease_) {
        const bool dynamic_target_blocked = active_tx_lease_->purpose == TxPurpose::quick_call_join &&
            contains_id(tx_policy_.dynamic_join_blocked_group_ids,
                        active_tx_lease_->target.destination_id);
        const bool revoke_active =
            (active_tx_lease_->purpose == TxPurpose::ptt && transmit_revoked) ||
            (active_tx_lease_->purpose == TxPurpose::quick_call_join &&
             (transmit_revoked || dynamic_join_revoked || dynamic_target_blocked));
        if (revoke_active) {
            active_tx_lease_->admission_revoked = true;
            active_tx_lease_->eot_pending = true;
            if (active_tx_lease_->purpose == TxPurpose::ptt &&
                !active_tx_lease_->ptt_release_seen) {
                ptt_release_required_ = true;
            }
            if (media_owner_ == MediaOwner::tx_active) {
                media_owner_ = MediaOwner::tx_draining;
            }
            stop_tx_lease_id = active_tx_lease_->id;
        }
    }
    return {PolicyUpdateStatus::applied, tx_policy_revision_, std::nullopt, stop_tx_lease_id};
}

RouteMatch Router::match_receive(const dmr_call::CallConfig& call) const noexcept
{
    if (!valid_ || !valid_call(call)) return RouteMatch::invalid_call;
    if (blocked_source(call.source_id)) return RouteMatch::blocked_source;
    if (call.kind == dmr_call::CallKind::group &&
        blocked_group(GroupRoute{call.destination_id, call.slot})) {
        return RouteMatch::blocked_group;
    }
    return rx_policy_accepts(call) ? RouteMatch::allowed : RouteMatch::policy_denied;
}

RxAdmission Router::admit_rx(const dmr_call::CallConfig& call, bool call_start) noexcept
{
    if (!valid_ || !valid_call(call)) return {RxDecision::invalid_call, 0U, std::nullopt};

    const auto match = match_receive(call);
    if (match != RouteMatch::allowed) {
        if (match == RouteMatch::blocked_group) {
            return {RxDecision::blocked_group, 0U, std::nullopt};
        }
        if (match == RouteMatch::blocked_source) {
            return {RxDecision::blocked_source, 0U, std::nullopt};
        }
        if (match == RouteMatch::policy_denied &&
            call.kind == dmr_call::CallKind::group &&
            rx_policy_.group_mode == GroupMode::selected) {
            return {RxDecision::candidate_only,
                    0U,
                    GroupRoute{call.destination_id, call.slot}};
        }
        return {RxDecision::policy_denied, 0U, std::nullopt};
    }

    if (media_owner_ == MediaOwner::rx_active && active_rx_call_ &&
        same_call(*active_rx_call_, call)) {
        return {RxDecision::same_active_call, active_rx_generation_, std::nullopt};
    }
    if (!call_start) {
        return {RxDecision::not_call_start, 0U, std::nullopt};
    }
    if (media_owner_ == MediaOwner::rx_stopping ||
        (media_owner_ == MediaOwner::fault && fault_is_rx_)) {
        return {RxDecision::stopping, active_rx_generation_, std::nullopt};
    }
    if (media_owner_ != MediaOwner::idle) {
        return {RxDecision::media_busy, 0U, std::nullopt};
    }

    std::uint64_t generation{};
    if (!allocate_rx_generation(generation)) {
        return {RxDecision::generation_exhausted, 0U, std::nullopt};
    }
    active_rx_call_ = call;
    active_rx_generation_ = generation;
    media_owner_ = MediaOwner::rx_active;
    return {RxDecision::admitted, generation, std::nullopt};
}

std::optional<std::uint64_t> Router::request_rx_stop() noexcept
{
    if (media_owner_ == MediaOwner::rx_active || media_owner_ == MediaOwner::rx_draining) {
        media_owner_ = MediaOwner::rx_stopping;
        return active_rx_generation_;
    }
    if (media_owner_ == MediaOwner::rx_stopping) return active_rx_generation_;
    if (media_owner_ == MediaOwner::fault && fault_is_rx_) {
        media_owner_ = MediaOwner::rx_stopping;
        return active_rx_generation_;
    }
    return std::nullopt;
}

OperationStatus Router::rx_network_eot(std::uint64_t generation) noexcept
{
    if (generation != active_rx_generation_ || !active_rx_call_) {
        return OperationStatus::stale_generation;
    }
    if (media_owner_ != MediaOwner::rx_active) {
        return OperationStatus::wrong_phase;
    }
    media_owner_ = MediaOwner::rx_draining;
    return OperationStatus::completed;
}

OperationStatus Router::rx_playback_finished(std::uint64_t generation) noexcept
{
    if (generation != active_rx_generation_ || !active_rx_call_) {
        return OperationStatus::stale_generation;
    }
    if (media_owner_ != MediaOwner::rx_draining) {
        return OperationStatus::wrong_phase;
    }
    media_owner_ = MediaOwner::rx_stopping;
    return OperationStatus::completed;
}

OperationStatus Router::complete_rx_stop(std::uint64_t generation,
                                         bool cleanup_succeeded) noexcept
{
    if (generation != active_rx_generation_ || !active_rx_call_) {
        return OperationStatus::stale_generation;
    }
    if (media_owner_ != MediaOwner::rx_stopping &&
        !(media_owner_ == MediaOwner::fault && fault_is_rx_)) {
        return OperationStatus::wrong_phase;
    }
    if (!cleanup_succeeded) {
        media_owner_ = MediaOwner::fault;
        fault_is_rx_ = true;
        return OperationStatus::cleanup_failed;
    }
    clear_rx_owner();
    return OperationStatus::completed;
}

TxStartResult Router::begin_ptt() noexcept
{
    if (!tx_policy_.transmit_enabled) {
        return {TxStartStatus::transmit_disabled, std::nullopt};
    }
    if (ptt_release_required_) {
        return {TxStartStatus::ptt_release_required, std::nullopt};
    }
    if (media_owner_ != MediaOwner::idle) {
        return {TxStartStatus::media_busy, std::nullopt};
    }
    if (!valid_target(tx_policy_.target)) {
        return {TxStartStatus::invalid_target, std::nullopt};
    }
    if (protected_receive_only_target(tx_policy_.target)) {
        return {TxStartStatus::policy_forbidden_target, std::nullopt};
    }
    return begin_tx(tx_policy_.target, TxPurpose::ptt);
}

TxStartResult Router::request_dynamic_join(const GroupRoute& group,
                                           bool explicit_user_action) noexcept
{
    if (!valid_id(group.destination_id) || !valid_slot(group.slot)) {
        return {TxStartStatus::invalid_target, std::nullopt};
    }
    if (!explicit_user_action) {
        return {TxStartStatus::explicit_action_required, std::nullopt};
    }
    if (!tx_policy_.transmit_enabled) {
        return {TxStartStatus::transmit_disabled, std::nullopt};
    }
    if (ptt_release_required_) {
        return {TxStartStatus::ptt_release_required, std::nullopt};
    }
    if (!tx_policy_.dynamic_join_enabled) {
        return {TxStartStatus::dynamic_join_disabled, std::nullopt};
    }
    if (contains_id(tx_policy_.dynamic_join_blocked_group_ids, group.destination_id)) {
        return {TxStartStatus::dynamic_join_blocked, std::nullopt};
    }
    const TxTarget target{group.destination_id, dmr_call::CallKind::group, group.slot};
    if (protected_receive_only_target(target)) {
        return {TxStartStatus::dynamic_join_blocked, std::nullopt};
    }
    return begin_tx(target, TxPurpose::quick_call_join);
}

OperationStatus Router::release_tx(std::uint64_t lease_id) noexcept
{
    if (!active_tx_lease_ || active_tx_lease_->id != lease_id) {
        return OperationStatus::stale_lease;
    }
    if (active_tx_lease_->purpose == TxPurpose::ptt) {
        active_tx_lease_->ptt_release_seen = true;
        ptt_release_required_ = false;
    }
    if (media_owner_ == MediaOwner::tx_draining && active_tx_lease_->eot_pending) {
        return OperationStatus::completed;
    }
    if (media_owner_ != MediaOwner::tx_active) {
        return OperationStatus::wrong_phase;
    }
    active_tx_lease_->eot_pending = true;
    media_owner_ = MediaOwner::tx_draining;
    return OperationStatus::completed;
}

OperationStatus Router::request_tx_stop(std::uint64_t lease_id) noexcept
{
    if (!active_tx_lease_ || active_tx_lease_->id != lease_id) {
        return OperationStatus::stale_lease;
    }
    if (media_owner_ == MediaOwner::fault && !fault_is_rx_) {
        return OperationStatus::wrong_phase;
    }
    if (media_owner_ == MediaOwner::tx_draining && active_tx_lease_->eot_pending) {
        return OperationStatus::completed;
    }
    if (media_owner_ != MediaOwner::tx_active) {
        return OperationStatus::wrong_phase;
    }
    active_tx_lease_->admission_revoked = true;
    active_tx_lease_->eot_pending = true;
    if (active_tx_lease_->purpose == TxPurpose::ptt &&
        !active_tx_lease_->ptt_release_seen) {
        ptt_release_required_ = true;
    }
    media_owner_ = MediaOwner::tx_draining;
    return OperationStatus::completed;
}

OperationStatus Router::observe_ptt_release() noexcept
{
    if (active_tx_lease_ && active_tx_lease_->purpose == TxPurpose::ptt) {
        return release_tx(active_tx_lease_->id);
    }
    ptt_release_required_ = false;
    return OperationStatus::completed;
}

OperationStatus Router::complete_tx_eot(std::uint64_t lease_id, bool sent) noexcept
{
    if (!active_tx_lease_ || active_tx_lease_->id != lease_id) {
        return OperationStatus::stale_lease;
    }
    if (media_owner_ != MediaOwner::tx_draining || !active_tx_lease_->eot_pending) {
        return OperationStatus::wrong_phase;
    }
    active_tx_lease_->eot_pending = false;
    active_tx_lease_->eot_sent = sent;
    if (!sent) {
        media_owner_ = MediaOwner::fault;
        fault_is_rx_ = false;
        return OperationStatus::send_failed;
    }
    return OperationStatus::completed;
}

OperationStatus Router::complete_tx_cleanup(std::uint64_t lease_id,
                                            bool cleanup_succeeded) noexcept
{
    if (!active_tx_lease_ || active_tx_lease_->id != lease_id) {
        return OperationStatus::stale_lease;
    }
    if (active_tx_lease_->eot_pending || !active_tx_lease_->eot_sent.has_value()) {
        return OperationStatus::wrong_phase;
    }
    if (active_tx_lease_->eot_sent == std::optional<bool>{false}) {
        if (media_owner_ != MediaOwner::fault || fault_is_rx_) return OperationStatus::wrong_phase;
        if (!cleanup_succeeded) return OperationStatus::cleanup_failed;
        return OperationStatus::send_failed;
    }
    if (media_owner_ != MediaOwner::tx_draining &&
        !(media_owner_ == MediaOwner::fault && !fault_is_rx_)) return OperationStatus::wrong_phase;
    if (!cleanup_succeeded) {
        media_owner_ = MediaOwner::fault;
        fault_is_rx_ = false;
        return OperationStatus::cleanup_failed;
    }
    clear_tx_owner();
    return OperationStatus::completed;
}

Snapshot Router::snapshot() const noexcept
{
    Snapshot result{};
    result.media_owner = media_owner_;
    result.rx_policy_revision = rx_policy_revision_;
    result.tx_policy_revision = tx_policy_revision_;
    result.active_rx_call = active_rx_call_;
    result.active_rx_generation = active_rx_generation_;
    result.active_tx_lease = active_tx_lease_;
    result.generation_exhausted = rx_generation_exhausted_;
    result.lease_id_exhausted = lease_id_exhausted_;
    result.ptt_release_required = ptt_release_required_;
    return result;
}

bool Router::valid_rx_policy(const RxPolicy& policy) const noexcept
{
    if (policy.group_mode != GroupMode::selected &&
        policy.group_mode != GroupMode::all_delivered) {
        return false;
    }
    if (policy.private_mode != PrivateMode::disabled &&
        policy.private_mode != PrivateMode::selected_peers &&
        policy.private_mode != PrivateMode::all_peers_to_local) {
        return false;
    }

    for (std::size_t index = 0U; index < policy.allowed_groups.size(); ++index) {
        const auto& route = policy.allowed_groups[index];
        if (!valid_id(route.destination_id) || !valid_slot(route.slot)) return false;
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (policy.allowed_groups[prior] == route) return false;
        }
    }
    for (std::size_t index = 0U; index < policy.blocked_groups.size(); ++index) {
        const auto& route = policy.blocked_groups[index];
        if (!valid_id(route.destination_id) || !valid_slot(route.slot)) return false;
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (policy.blocked_groups[prior] == route) return false;
        }
        for (const auto& allowed : policy.allowed_groups) {
            if (allowed == route) return false;
        }
    }
    for (std::size_t index = 0U; index < policy.blocked_source_ids.size(); ++index) {
        const auto id = policy.blocked_source_ids[index];
        if (!valid_id(id)) return false;
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (policy.blocked_source_ids[prior] == id) return false;
        }
    }
    for (std::size_t index = 0U; index < policy.private_peers.size(); ++index) {
        const auto& route = policy.private_peers[index];
        if (!valid_id(route.source_id) ||
            route.local_destination_id != local_source_id_ ||
            !valid_slot(route.slot)) {
            return false;
        }
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (policy.private_peers[prior] == route) return false;
        }
    }
    for (std::size_t index = 0U; index < policy.local_private_routes.size(); ++index) {
        const auto& route = policy.local_private_routes[index];
        if (route.local_destination_id != local_source_id_ || !valid_slot(route.slot)) {
            return false;
        }
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (policy.local_private_routes[prior] == route) return false;
        }
    }
    if (policy.private_mode == PrivateMode::disabled &&
        (!policy.private_peers.empty() || !policy.local_private_routes.empty())) {
        return false;
    }
    if (policy.private_mode == PrivateMode::selected_peers &&
        !policy.local_private_routes.empty()) {
        return false;
    }
    return true;
}

bool Router::valid_tx_policy(const TxPolicy& policy) const noexcept
{
    if (policy.target.destination_id == 0U) {
        if (policy.transmit_enabled) return false;
    } else if (!valid_target(policy.target)) {
        return false;
    }
    for (std::size_t index = 0U; index < policy.dynamic_join_blocked_group_ids.size(); ++index) {
        const auto id = policy.dynamic_join_blocked_group_ids[index];
        if (!valid_id(id)) return false;
        for (std::size_t prior = 0U; prior < index; ++prior) {
            if (policy.dynamic_join_blocked_group_ids[prior] == id) return false;
        }
    }
    return true;
}

bool Router::valid_call(const dmr_call::CallConfig& call) const noexcept
{
    return valid_id(call.source_id) && valid_id(call.destination_id) &&
           valid_slot(call.slot) && valid_kind(call.kind);
}

bool Router::valid_target(const TxTarget& target) const noexcept
{
    return valid_id(target.destination_id) && valid_slot(target.slot) &&
           valid_kind(target.kind);
}

bool Router::rx_policy_accepts(const dmr_call::CallConfig& call) const noexcept
{
    if (!valid_call(call) || blocked_source(call.source_id)) return false;
    if (call.kind == dmr_call::CallKind::group) {
        const GroupRoute route{call.destination_id, call.slot};
        if (blocked_group(route)) return false;
        return rx_policy_.group_mode == GroupMode::all_delivered ||
               contains_route(rx_policy_.allowed_groups, route);
    }

    if (call.destination_id != local_source_id_) return false;
    const bool exact_peer_allowed = rx_policy_.private_mode != PrivateMode::disabled &&
        contains_peer(rx_policy_.private_peers,
                      PrivatePeerRoute{call.source_id, call.destination_id, call.slot});
    const bool all_local_route_allowed = rx_policy_.private_mode == PrivateMode::all_peers_to_local &&
        contains_local_route(rx_policy_.local_private_routes,
                             LocalPrivateRoute{call.destination_id, call.slot});
    return exact_peer_allowed || all_local_route_allowed;
}

bool Router::blocked_source(std::uint32_t source_id) const noexcept
{
    return contains_id(rx_policy_.blocked_source_ids, source_id);
}

bool Router::blocked_group(const GroupRoute& route) const noexcept
{
    return contains_route(rx_policy_.blocked_groups, route);
}

bool Router::same_call(const dmr_call::CallConfig& left,
                       const dmr_call::CallConfig& right) const noexcept
{
    return left.source_id == right.source_id &&
           left.destination_id == right.destination_id &&
           left.gateway_id == right.gateway_id &&
           left.stream_id == right.stream_id &&
           left.slot == right.slot && left.kind == right.kind;
}

TxStartResult Router::begin_tx(const TxTarget& target, TxPurpose purpose) noexcept
{
    if (!valid_target(target)) return {TxStartStatus::invalid_target, std::nullopt};
    if (ptt_release_required_) return {TxStartStatus::ptt_release_required, std::nullopt};
    if (media_owner_ != MediaOwner::idle) {
        return {TxStartStatus::media_busy, std::nullopt};
    }
    std::uint64_t lease_id{};
    if (!allocate_lease_id(lease_id)) {
        return {TxStartStatus::lease_id_exhausted, std::nullopt};
    }
    TxLease lease{};
    lease.id = lease_id;
    lease.target = target;
    lease.purpose = purpose;
    lease.policy_revision = tx_policy_revision_;
    active_tx_lease_ = lease;
    media_owner_ = MediaOwner::tx_active;
    return {TxStartStatus::started, lease};
}

bool Router::allocate_rx_generation(std::uint64_t& generation) noexcept
{
    if (rx_generation_exhausted_ || next_rx_generation_ == 0U) return false;
    generation = next_rx_generation_;
    if (next_rx_generation_ == std::numeric_limits<std::uint64_t>::max()) {
        rx_generation_exhausted_ = true;
    } else {
        ++next_rx_generation_;
    }
    return true;
}

bool Router::allocate_lease_id(std::uint64_t& lease_id) noexcept
{
    if (lease_id_exhausted_ || next_lease_id_ == 0U) return false;
    lease_id = next_lease_id_;
    if (next_lease_id_ == std::numeric_limits<std::uint64_t>::max()) {
        lease_id_exhausted_ = true;
    } else {
        ++next_lease_id_;
    }
    return true;
}

void Router::clear_rx_owner() noexcept
{
    active_rx_call_.reset();
    active_rx_generation_ = 0U;
    media_owner_ = MediaOwner::idle;
    fault_is_rx_ = false;
}

void Router::clear_tx_owner() noexcept
{
    active_tx_lease_.reset();
    media_owner_ = MediaOwner::idle;
    fault_is_rx_ = false;
}

} // 命名空间 wirex::talkgroup_routing
