#pragma once

#include "wirex/bm_voice_pipeline.hpp"

#include <cstdint>
#include <optional>
#include <string_view>

namespace wirex::bm_test_profile {

enum class TxPolicy : std::uint8_t {
    enabled,
    receive_only,
};

struct Preset {
    std::string_view id;
    std::string_view label;
    std::string_view callsign;
    std::string_view master_ipv4;
    std::uint32_t gateway_id{};
    std::uint32_t source_id{};
    std::uint32_t destination_id{};
    std::uint16_t master_port{};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    std::uint8_t color_code{};
};

enum class TxStartStatus : std::uint8_t {
    started,
    denied_receive_only,
    rejected_by_pipeline,
};

struct TxStartResult {
    TxStartStatus status{TxStartStatus::rejected_by_pipeline};
    bm_voice::Error error{bm_voice::Error::none};
};

[[nodiscard]] std::optional<Preset> find(std::string_view id) noexcept;
[[nodiscard]] TxPolicy policy_for(const dmr_call::CallConfig& call) noexcept;
[[nodiscard]] bool permits_transmit(TxPolicy policy) noexcept;
[[nodiscard]] TxStartResult begin_tx(TxPolicy policy,
                                     bm_voice::BmVoicePipeline& pipeline,
                                     const dmr_call::CallConfig& call,
                                     bm_voice::Readiness readiness,
                                     bm_voice::TimePoint now) noexcept;

} // namespace wirex::bm_test_profile
