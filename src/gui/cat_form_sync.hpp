#pragma once

// CAT 读回到可编辑表单的纯同步规则；不访问串口，供 ViewModel 与离线测试共用。
#include "view_model.hpp"

#include <array>
#include <cstdint>
#include <iterator>
#include <string>

namespace wirex::gui::cat_form_sync {

inline constexpr std::size_t index(CatFormField field) noexcept {
    return static_cast<std::size_t>(field);
}

inline std::string format_frequency_mhz(std::uint64_t frequency_hz) {
    const auto whole = frequency_hz / 1'000'000U;
    const auto remainder = static_cast<std::uint32_t>(frequency_hz % 1'000'000U);
    std::string text = std::to_string(whole);
    if (remainder == 0U) return text;

    // remainder + 1,000,000 总是七位数字；取末六位可保留到 1 Hz。
    std::string fraction = std::to_string(1'000'000U + remainder).substr(1U);
    while (!fraction.empty() && fraction.back() == '0') fraction.pop_back();
    text.push_back('.');
    text += fraction;
    return text;
}

inline int mode_index(const std::optional<services::CatMode>& mode) noexcept {
    if (!mode) return -1;
    switch (*mode) {
    case services::CatMode::fm: return 0;
    case services::CatMode::fm_n: return 1;
    case services::CatMode::c4fm_dn: return 2;
    case services::CatMode::c4fm_vw: return 3;
    }
    return -1;
}

inline int power_index(const std::optional<std::uint32_t>& power_w) noexcept {
    if (!power_w) return -1;
    for (std::size_t i = 0; i < std::size(kPowerWatts); ++i) {
        if (kPowerWatts[i] == *power_w) return static_cast<int>(i);
    }
    return -1;
}

inline void sync(CatForm& form, const services::CatState& state,
                 const std::array<bool, 3>& dirty, const std::array<bool, 3>& editing,
                 const std::array<bool, 3>& allow_dirty = {}) {
    const auto can_update = [&](CatFormField field) {
        const auto i = index(field);
        return !editing[i] && (!dirty[i] || allow_dirty[i]);
    };

    if (can_update(CatFormField::mode)) form.mode_index = mode_index(state.observed_mode);
    if (can_update(CatFormField::frequency)) {
        form.frequency_mhz = state.observed_frequency_hz
            ? format_frequency_mhz(*state.observed_frequency_hz) : std::string{};
    }
    if (can_update(CatFormField::power)) form.power_index = power_index(state.observed_power_w);
}

inline void clear_applied_dirty(std::array<bool, 3>& dirty,
                                const std::array<std::uint64_t, 3>& submitted_revision,
                                const std::array<std::uint64_t, 3>& current_revision,
                                const std::array<bool, 3>& submitted) noexcept {
    for (std::size_t i = 0; i < dirty.size(); ++i) {
        if (submitted[i] && submitted_revision[i] == current_revision[i]) dirty[i] = false;
    }
}

} // namespace wirex::gui::cat_form_sync
