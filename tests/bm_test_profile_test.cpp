#include "wirex/bm_test_profile.hpp"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string_view>

namespace {

int failures = 0;

void check(bool condition, const char* description)
{
    if (condition) return;
    std::fprintf(stderr, "FAIL: %s\n", description);
    ++failures;
}

void check_common_identity(const wirex::bm_test_profile::Preset& preset)
{
    using wirex::dmr_call::CallKind;
    using wirex::dmr_call::Slot;
    check(preset.callsign == "BI7KGD", "preset uses the confirmed callsign");
    check(preset.gateway_id == 461135501U, "preset uses Gateway ID with ESSID 01");
    check(preset.source_id == 4611355U, "preset uses the base Radio ID as Source ID");
    check(preset.master_ipv4 == "43.129.83.124", "preset uses the pinned BrandMeister IPv4 address");
    check(preset.master_port == 62031U, "preset uses BrandMeister UDP port 62031");
    check(preset.slot == Slot::ts1, "preset uses TS1");
    check(preset.color_code == 0U, "preset uses color code 0");
    check(preset.kind == CallKind::private_call || preset.kind == CallKind::group,
          "preset has a DMR call kind");
}

wirex::dmr_call::CallConfig call_for(const wirex::bm_test_profile::Preset& preset)
{
    wirex::dmr_call::CallConfig call{};
    call.source_id = preset.source_id;
    call.destination_id = preset.destination_id;
    call.gateway_id = preset.gateway_id;
    call.stream_id = {1U, 2U, 3U, 4U};
    call.slot = preset.slot;
    call.kind = preset.kind;
    call.color_code = preset.color_code;
    return call;
}

} // namespace

int main()
{
    using namespace wirex;
    using bm_test_profile::TxPolicy;
    using bm_test_profile::TxStartStatus;
    using dmr_call::CallKind;

    const auto china = bm_test_profile::find("parrot-cn");
    const auto global = bm_test_profile::find("parrot-global");
    const auto listen = bm_test_profile::find("listen-46001");
    check(china.has_value(), "Chinese parrot preset exists");
    check(global.has_value(), "generic parrot preset exists");
    check(listen.has_value(), "receive-only 46001 preset exists");
    check(!bm_test_profile::find("unknown").has_value(), "unknown presets are rejected");
    if (!china || !global || !listen) return EXIT_FAILURE;

    check_common_identity(*china);
    check_common_identity(*global);
    check_common_identity(*listen);
    check(china->destination_id == 460997U && china->kind == CallKind::private_call,
          "China preset targets private-call echo 460997");
    check(global->destination_id == 9990U && global->kind == CallKind::private_call,
          "generic preset targets private-call echo 9990");
    check(listen->destination_id == 46001U && listen->kind == CallKind::group,
          "46001 preset is a group call");
    check(bm_test_profile::policy_for(call_for(*china)) == TxPolicy::enabled &&
          bm_test_profile::policy_for(call_for(*global)) == TxPolicy::enabled,
          "parrot presets allow explicitly requested transmit");
    const auto listen_call = call_for(*listen);
    check(bm_test_profile::policy_for(listen_call) == TxPolicy::receive_only,
          "46001 group preset is receive-only");

    bm_voice::BmVoicePipeline listen_pipeline;
    const auto denied = bm_test_profile::begin_tx(bm_test_profile::policy_for(listen_call), listen_pipeline,
        listen_call, bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
    check(denied.status == TxStartStatus::denied_receive_only,
          "shared native transmit policy rejects T for 46001");
    check(listen_pipeline.snapshot().tx_state == bm_voice::TxState::idle,
          "receive-only T does not start the TX pipeline or create LC");
    check(!listen_pipeline.take_outbound().has_value(),
          "receive-only T creates no DMRD packet");

    auto manual_national_group = listen_call;
    check(bm_test_profile::policy_for(manual_national_group) == TxPolicy::receive_only,
          "the manual group-call configuration for TG 46001 is also receive-only");
    bm_voice::BmVoicePipeline manual_pipeline;
    const auto manual_denied = bm_test_profile::begin_tx(
        bm_test_profile::policy_for(manual_national_group), manual_pipeline, manual_national_group,
        bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
    check(manual_denied.status == TxStartStatus::denied_receive_only &&
          manual_pipeline.snapshot().tx_state == bm_voice::TxState::idle &&
          !manual_pipeline.take_outbound().has_value(),
          "manual T for group 46001 creates no TX state, LC, or DMRD packet");

    auto other_manual_group = listen_call;
    other_manual_group.destination_id = 46002U;
    check(bm_test_profile::policy_for(other_manual_group) == TxPolicy::enabled,
          "other manual group targets keep the existing transmit policy");
    auto manual_private_46001 = listen_call;
    manual_private_46001.kind = CallKind::private_call;
    check(bm_test_profile::policy_for(manual_private_46001) == TxPolicy::enabled,
          "the receive-only rule applies to group 46001, not private ID 46001");

    for (const auto* preset : {&*china, &*global}) {
        bm_voice::BmVoicePipeline pipeline;
        const auto result = bm_test_profile::begin_tx(bm_test_profile::policy_for(call_for(*preset)), pipeline,
            call_for(*preset), bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
        check(result.status == TxStartStatus::started,
              "transmit-enabled preset can start TX through the shared policy");
        check(pipeline.snapshot().tx_state == bm_voice::TxState::active,
              "transmit-enabled preset enters the normal TX pipeline");
        pipeline.cancel_tx();
    }

    if (failures != 0) {
        std::fprintf(stderr, "%d BM test profile checks failed.\n", failures);
        return EXIT_FAILURE;
    }
    std::puts("BM test preset and receive-only policy checks passed.");
    return EXIT_SUCCESS;
}
