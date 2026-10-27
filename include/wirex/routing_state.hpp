#pragma once

#include "wirex/bm_voice_pipeline.hpp"
#include "wirex/strict_json.hpp"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace wirex::routing_state {

struct StartupConfig {
    std::uint32_t local_source_id{};
    talkgroup_routing::RxPolicy rx_policy{};
    talkgroup_routing::TxPolicy tx_policy{};
};

struct ObservedSource {
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    talkgroup_routing::ObservationLevel observation_level{
        talkgroup_routing::ObservationLevel::outer_header_seen};
};

class ObservedSources final {
public:
    static constexpr std::size_t capacity = 64U;
    void observe(const dmrd::Datagram& datagram, std::uint32_t local_source_id) noexcept;
    [[nodiscard]] const std::vector<ObservedSource>& entries() const noexcept { return entries_; }
private:
    std::vector<ObservedSource> entries_{};
};

[[nodiscard]] bool parse_rx_policy(const strict_json::Value& value,
                                   std::uint32_t local_source_id,
                                   talkgroup_routing::RxPolicy& output) noexcept;
[[nodiscard]] bool parse_tx_target(const strict_json::Value& value,
                                   talkgroup_routing::TxTarget& output) noexcept;
[[nodiscard]] bool parse_startup_config(std::string_view json,
                                        std::uint32_t cli_source_id,
                                        const talkgroup_routing::TxTarget& cli_target,
                                        bool cli_transmit_enabled,
                                        StartupConfig& output) noexcept;
[[nodiscard]] std::string routing_json(const bm_voice::RoutedSnapshot& snapshot,
                                       std::uint32_t local_source_id,
                                       const talkgroup_routing::RxPolicy& rx_policy,
                                       const talkgroup_routing::TxPolicy& tx_policy,
                                       const ObservedSources& observed);

} // namespace wirex::routing_state
