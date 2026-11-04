#include "../src/gui/cat_form_sync.hpp"
#include "../src/gui/cat_state_sync.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

int checks = 0;
int failures = 0;

void check(bool condition, const char* message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

wirex::app::CatObserved full_observation(std::uint32_t frequency_hz = 145'500'000U,
                                         wirex::app::CatMode mode = wirex::app::CatMode::c4fm_dn,
                                         int power_w = 25) {
    using namespace wirex::app;
    CatObserved observed;
    observed.main_mode = CatObservation<CatModeReading>{CatModeReading{CatSide::main, mode}};
    observed.main_frequency_hz = CatObservation<std::uint32_t>{frequency_hz};
    observed.power = CatObservation<CatPowerReading>{CatPowerReading{CatPowerPath::spa1, power_w}};
    return observed;
}

void test_frequency_and_value_mapping() {
    using namespace wirex::gui;
    check(cat_form_sync::format_frequency_mhz(145'000'000U) == "145",
          "whole MHz frequency is formatted without redundant decimals");
    check(cat_form_sync::format_frequency_mhz(145'500'000U) == "145.5",
          "frequency is formatted in MHz");
    check(cat_form_sync::format_frequency_mhz(145'000'001U) == "145.000001",
          "frequency formatting retains 1 Hz precision");
    check(cat_form_sync::format_frequency_mhz(145'123'450U) == "145.12345",
          "frequency formatting trims trailing zeroes only");

    services::CatState state;
    CatForm form;
    const std::array<bool, 3> clean{};
    const std::array<bool, 3> inactive{};
    check(form.power_index == -1, "power selector starts unknown when the service has no CAT readback");
    cat_form_sync::sync(form, state, clean, inactive);
    check(form.power_index == -1, "empty CAT state keeps power unknown instead of choosing 25 W");
    state.observed_mode = services::CatMode::c4fm_vw;
    state.observed_frequency_hz = 433'125'000U;
    state.observed_power_w = 50U;
    cat_form_sync::sync(form, state, clean, inactive);
    check(form.mode_index == 3 && form.frequency_mhz == "433.125" && form.power_index == 4,
          "FM/C4FM mode, frequency, and supported power map to form indexes");

    state.observed_mode.reset();
    state.observed_power_w = 30U;
    cat_form_sync::sync(form, state, clean, inactive);
    check(form.mode_index == -1 && form.power_index == -1,
          "unknown mode and non-preset power remain explicitly unselected");
}

void test_disconnect_and_reconnect_observation_lifecycle() {
    using namespace wirex::gui;
    services::CatState state;
    state.connected = true;
    state.observed_mode = services::CatMode::c4fm_dn;
    state.observed_frequency_hz = 433'500'000U;
    state.observed_power_w = 25U;
    state.observed_revision = 7U;

    CatForm form;
    const std::array<bool, 3> clean{};
    const std::array<bool, 3> inactive{};
    cat_form_sync::sync(form, state, clean, inactive);
    check(form.power_index == 3 && form.frequency_mhz == "433.5",
          "a confirmed observation populates the form before disconnect");

    form.mode_index = 1;
    form.frequency_mhz = "draft-frequency";
    form.power_index = 4;
    const std::array<bool, 3> dirty{true, false, false};
    const std::array<bool, 3> editing{false, false, true};
    const bool invalidated = cat_state_sync::invalidate_observation(state);
    state.connected = false;
    state.busy = false;
    check(invalidated && state.observed_revision == 8U && !state.observed_mode &&
              !state.observed_frequency_hz && !state.observed_power_w,
          "disconnect invalidates prior trusted CAT values and advances the observation revision");
    cat_form_sync::sync(form, state, dirty, editing);
    check(form.mode_index == 1 && form.frequency_mhz.empty() && form.power_index == 4,
          "disconnect clears clean fields while preserving dirty and currently edited drafts");

    cat_form_sync::sync(form, state, clean, inactive);
    check(form.mode_index == -1 && form.frequency_mhz.empty() && form.power_index == -1,
          "after edits are cleared, a disconnected state without trusted readback displays unknown");

    state.busy = true;
    cat_form_sync::sync(form, state, clean, inactive);
    check(form.power_index == -1,
          "reconnection in progress does not restore a default power before a trusted readback");

    wirex::app::CatResult query;
    query.operation = wirex::app::CatOperation::query;
    query.status = wirex::app::CatResultStatus::confirmed;
    query.observed = full_observation(433'500'000U, wirex::app::CatMode::c4fm_dn, 15);
    check(cat_state_sync::apply(state, query, query.observed) == cat_state_sync::Update::updated,
          "a confirmed query after reconnect restores trusted values");
    state.busy = false;
    state.connected = true;
    cat_form_sync::sync(form, state, clean, inactive);
    check(form.power_index == 2 && form.frequency_mhz == "433.5",
          "reconnected form shows the new confirmed power and frequency");
}

void test_dirty_and_active_fields_are_not_replaced() {
    using namespace wirex::gui;
    services::CatState state;
    state.observed_mode = services::CatMode::fm;
    state.observed_frequency_hz = 146'520'000U;
    state.observed_power_w = 10U;
    CatForm form;
    form.mode_index = 2;
    form.frequency_mhz = "draft-frequency";
    form.power_index = 4;
    const std::array<bool, 3> dirty{true, true, false};
    const std::array<bool, 3> editing{false, false, true};
    cat_form_sync::sync(form, state, dirty, editing);
    check(form.mode_index == 2 && form.frequency_mhz == "draft-frequency" && form.power_index == 4,
          "async observations preserve edited drafts and the currently active control");

    const std::array<bool, 3> inactive{};
    const std::array<bool, 3> power_clean{false, false, false};
    cat_form_sync::sync(form, state, power_clean, inactive);
    check(form.power_index == 1,
          "a clean inactive power selector receives the latest trusted readback");
}

void test_apply_revision_and_observation_trust() {
    using namespace wirex::gui;
    std::array<bool, 3> dirty{true, true, true};
    const std::array<std::uint64_t, 3> submitted_revision{4U, 5U, 6U};
    const std::array<std::uint64_t, 3> current_revision{4U, 7U, 6U};
    const std::array<bool, 3> submitted{true, true, false};
    cat_form_sync::clear_applied_dirty(dirty, submitted_revision, current_revision, submitted);
    check(!dirty[0] && dirty[1] && dirty[2],
          "successful apply clears only submitted fields unchanged since submission");

    using namespace wirex::app;
    services::CatState state;
    state.observed_mode = services::CatMode::fm_n;
    state.observed_frequency_hz = 144'800'000U;
    state.observed_power_w = 5U;
    state.observed_revision = 9U;

    CatResult failed_query;
    failed_query.operation = CatOperation::query;
    failed_query.status = CatResultStatus::unknown;
    failed_query.observed = full_observation(433'500'000U, CatMode::fm, 50);
    auto update = cat_state_sync::apply(state, failed_query, failed_query.observed);
    check(update == cat_state_sync::Update::ignored && state.observed_revision == 9U &&
          state.observed_frequency_hz == 144'800'000U,
          "failed CAT query payload cannot replace the last trusted values");

    CatResult confirmed_query;
    confirmed_query.operation = CatOperation::query;
    confirmed_query.status = CatResultStatus::confirmed;
    confirmed_query.observed = full_observation();
    update = cat_state_sync::apply(state, confirmed_query, confirmed_query.observed);
    check(update == cat_state_sync::Update::updated && state.observed_revision == 10U &&
          state.observed_mode == services::CatMode::c4fm_dn &&
          state.observed_frequency_hz == 145'500'000U && state.observed_power_w == 25U,
          "confirmed CAT query publishes the merged trusted readback");

    CatResult rejected_power;
    rejected_power.operation = CatOperation::set_power;
    rejected_power.status = CatResultStatus::rejected;
    rejected_power.cleanup = CatCleanup::closed;
    rejected_power.observed.power = CatObservation<CatPowerReading>{CatPowerReading{CatPowerPath::spa1, 10}};
    CatObserved cumulative = confirmed_query.observed;
    cumulative.power = rejected_power.observed.power;
    update = cat_state_sync::apply(state, rejected_power, cumulative);
    check(update == cat_state_sync::Update::updated && state.observed_power_w == 10U &&
          state.observed_revision == 11U,
          "closed rejected power write may adopt the confirmed power readback");

    CatResult wrong_identity;
    wrong_identity.status = CatResultStatus::identity_mismatch;
    update = cat_state_sync::apply(state, wrong_identity, {});
    check(update == cat_state_sync::Update::invalidated && state.observed_revision == 12U &&
          !state.observed_mode && !state.observed_frequency_hz && !state.observed_power_w,
          "radio identity mismatch invalidates prior values and notifies the form sync path");
}

} // namespace

int main() {
    test_frequency_and_value_mapping();
    test_disconnect_and_reconnect_observation_lifecycle();
    test_dirty_and_active_fields_are_not_replaced();
    test_apply_revision_and_observation_trust();
    if (failures != 0) return EXIT_FAILURE;
    std::cout << "PASS: " << checks << " native CAT form synchronization checks\n";
    return EXIT_SUCCESS;
}
