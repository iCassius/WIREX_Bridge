#include "wirex/bm_test_profile.hpp"

#include <array>

namespace wirex::bm_test_profile {
namespace {

constexpr std::array<Preset, 4U> presets{{
    {"parrot-cn", "中国鹦鹉 460997", "BI7KGD", "43.129.83.124",
     461135501U, 4611355U, 460997U, 62031U, dmr_call::Slot::ts2,
     dmr_call::CallKind::private_call, 1U},
    {"parrot-global", "通用鹦鹉 9990", "BI7KGD", "43.129.83.124",
     461135501U, 4611355U, 9990U, 62031U, dmr_call::Slot::ts2,
     dmr_call::CallKind::private_call, 1U},
    {"listen-46001", "全国频道 46001（仅接收）", "BI7KGD", "43.129.83.124",
     461135501U, 4611355U, 46001U, 62031U, dmr_call::Slot::ts2,
     dmr_call::CallKind::group, 1U, true},
    {"listen-91", "全球 TG91（仅接收）", "BI7KGD", "43.129.83.124",
     461135501U, 4611355U, 91U, 62031U, dmr_call::Slot::ts2,
     dmr_call::CallKind::group, 1U, true},
}};

} // namespace

std::optional<Preset> find(std::string_view id) noexcept
{
    for (const auto& preset : presets) {
        if (preset.id == id) return preset;
    }
    return std::nullopt;
}

TxPolicy policy_for(const dmr_call::CallConfig&) noexcept
{
    return TxPolicy::enabled;
}

TxPolicy policy_for(const dmr_call::CallConfig& call, bool listen_only) noexcept
{
    return listen_only ? TxPolicy::receive_only : policy_for(call);
}

bool permits_transmit(TxPolicy policy) noexcept
{
    return policy == TxPolicy::enabled;
}

TxStartResult begin_tx(TxPolicy policy,
                       bm_voice::BmVoicePipeline& pipeline,
                       const dmr_call::CallConfig& call,
                       bm_voice::Readiness readiness,
                       bm_voice::TimePoint now) noexcept
{
    if (!permits_transmit(policy)) {
        return {TxStartStatus::denied_receive_only, bm_voice::Error::none};
    }
    const auto error = pipeline.begin_tx(call, readiness, now);
    return {error == bm_voice::Error::none ? TxStartStatus::started
                                           : TxStartStatus::rejected_by_pipeline,
            error};
}

} // namespace wirex::bm_test_profile
