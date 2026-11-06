#pragma once

// CAT-1 结果到 GUI 状态的纯同步规则；便于在不打开串口的条件下验证可信读回边界。
#include "services.hpp"

#include "wirex/app/radio_cat.hpp"

namespace wirex::gui::cat_state_sync {

enum class Update : std::uint8_t { ignored, updated, invalidated };

inline std::optional<services::CatMode> to_gui_mode(app::CatMode mode) noexcept {
    switch (mode) {
    case app::CatMode::fm: return services::CatMode::fm;
    case app::CatMode::fm_n: return services::CatMode::fm_n;
    case app::CatMode::c4fm_dn: return services::CatMode::c4fm_dn;
    case app::CatMode::c4fm_vw: return services::CatMode::c4fm_vw;
    default: return std::nullopt;
    }
}

inline bool has_observation(const app::CatObserved& observed) noexcept {
    return observed.main_mode.has_value() || observed.main_frequency_hz.has_value() || observed.power.has_value();
}

inline bool may_adopt_observation(const app::CatResult& result) noexcept {
    if (result.status == app::CatResultStatus::confirmed) return true;
    return result.operation == app::CatOperation::set_power &&
           (result.status == app::CatResultStatus::rejected || result.status == app::CatResultStatus::mismatch) &&
           result.cleanup == app::CatCleanup::closed;
}

inline bool invalidate_observation(services::CatState& state) noexcept {
    const bool had_observation = state.observed_mode.has_value() ||
                                 state.observed_frequency_hz.has_value() ||
                                 state.observed_power_w.has_value();
    state.observed_mode.reset();
    state.observed_frequency_hz.reset();
    state.observed_power_w.reset();
    state.power_maximum_watts.reset();
    if (had_observation) ++state.observed_revision;
    return had_observation;
}

inline Update apply(services::CatState& state, const app::CatResult& result,
                    const app::CatObserved& cumulative_observed) noexcept {
    if (result.status == app::CatResultStatus::identity_mismatch) {
        (void)invalidate_observation(state);
        return Update::invalidated;
    }
    if (!may_adopt_observation(result) || !has_observation(result.observed)) return Update::ignored;

    state.observed_mode.reset();
    state.observed_frequency_hz.reset();
    state.observed_power_w.reset();
    if (cumulative_observed.main_mode) {
        state.observed_mode = to_gui_mode(cumulative_observed.main_mode->value.mode);
    }
    if (cumulative_observed.main_frequency_hz) {
        state.observed_frequency_hz = cumulative_observed.main_frequency_hz->value;
    }
    if (cumulative_observed.power) {
        state.observed_power_w = static_cast<std::uint32_t>(cumulative_observed.power->value.watts);
        state.power_maximum_watts = cumulative_observed.power->value.path == app::CatPowerPath::field_head ? 10U : 50U;
    }
    ++state.observed_revision;
    return Update::updated;
}

} // namespace wirex::gui::cat_state_sync
