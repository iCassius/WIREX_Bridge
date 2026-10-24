#include "wirex/bm_test_profile.hpp"
#include "wirex/bm_network_metadata.hpp"
#include "wirex/bm_session.hpp"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

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
    check(preset.slot == Slot::ts2, "preset uses the BM echo return timeslot TS2");
    check(preset.color_code == 1U, "preset uses the BM-accepted color code 1");
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

void append_id(std::vector<std::uint8_t>& bytes, std::uint32_t id)
{
    bytes.push_back(static_cast<std::uint8_t>((id >> 24U) & 0xffU));
    bytes.push_back(static_cast<std::uint8_t>((id >> 16U) & 0xffU));
    bytes.push_back(static_cast<std::uint8_t>((id >> 8U) & 0xffU));
    bytes.push_back(static_cast<std::uint8_t>(id & 0xffU));
}

std::vector<std::uint8_t> rptc_for(wirex::bm::Profile profile)
{
    using wirex::bm::Endpoint;
    using wirex::bm::InputResult;
    using wirex::bm::PacketKind;
    using wirex::bm::Session;
    const Endpoint master{{127U, 0U, 0U, 1U}, 62031U};
    Session session;
    if (!session.start(std::move(profile), master, 0U)) {
        check(false, "metadata profile is accepted by the production BM Session validator");
        return {};
    }
    auto outbound = session.take_outbound();
    if (outbound.size() != 1U || outbound[0].kind != PacketKind::control ||
        outbound[0].bytes.size() != 8U ||
        std::string(outbound[0].bytes.begin(), outbound[0].bytes.begin() + 4) != "RPTL") {
        check(false, "production Session starts with the expected login packet");
        return {};
    }

    std::vector<std::uint8_t> challenge{'R', 'P', 'T', 'A', 'C', 'K', 1U, 2U, 3U, 4U};
    if (session.on_datagram(challenge.data(), challenge.size(), master, 1U) != InputResult::accepted) {
        check(false, "production Session accepts the offline test challenge");
        return {};
    }
    outbound = session.take_outbound();
    if (outbound.size() != 1U || outbound[0].bytes.size() != 40U ||
        std::string(outbound[0].bytes.begin(), outbound[0].bytes.begin() + 4) != "RPTK") {
        check(false, "production Session creates an authentication packet for the test profile");
        return {};
    }

    std::vector<std::uint8_t> auth_ack{'R', 'P', 'T', 'A', 'C', 'K'};
    append_id(auth_ack, 461135501U);
    if (session.on_datagram(auth_ack.data(), auth_ack.size(), master, 2U) != InputResult::accepted) {
        check(false, "production Session accepts the matching offline test acknowledgement");
        return {};
    }
    outbound = session.take_outbound();
    if (outbound.size() != 1U || outbound[0].kind != PacketKind::control ||
        outbound[0].bytes.size() != 302U ||
        std::string(outbound[0].bytes.begin(), outbound[0].bytes.begin() + 4) != "RPTC") {
        check(false, "production Session generates the exact RPTC metadata packet");
        return {};
    }
    check(true, "production Session generates the exact RPTC metadata packet");
    return outbound[0].bytes;
}

std::string field(const std::vector<std::uint8_t>& packet, std::size_t offset, std::size_t length)
{
    if (offset > packet.size() || length > packet.size() - offset) return {};
    return std::string(packet.begin() + static_cast<std::ptrdiff_t>(offset),
                       packet.begin() + static_cast<std::ptrdiff_t>(offset + length));
}

void check_rptc_metadata(const std::vector<std::uint8_t>& packet,
                         std::string_view callsign_field, std::string_view cc_field)
{
    check(packet.size() == 302U, "RPTC metadata packet has the protocol-defined length");
    const std::array<std::uint8_t, 4U> expected_gateway{{0x1bU, 0x7cU, 0x5eU, 0x8dU}};
    check(field(packet, 4U, 4U) == std::string(expected_gateway.begin(), expected_gateway.end()),
          "RPTC preserves the configured Gateway ID");
    check(field(packet, 8U, 8U) == std::string(callsign_field),
          "RPTC preserves and serializes the caller's callsign");
    check(field(packet, 16U, 9U) == "438800000" && field(packet, 25U, 9U) == "438800000",
          "RPTC contains the accepted 438.8 MHz BM node metadata in fixed-width fields");
    check(field(packet, 34U, 2U) == "00" && field(packet, 36U, 2U) == cc_field,
          "RPTC serializes power 0 and the caller-selected color code");
    check(field(packet, 38U, 8U) == "0.000000" && field(packet, 46U, 9U) == "00.000000",
          "RPTC uses the accepted fixed-width coordinate strings");
    check(field(packet, 55U, 3U) == "000" &&
              field(packet, 58U, 20U) == std::string("DIRECT") + std::string(14U, ' ') &&
              field(packet, 78U, 19U) == std::string("FTX-1") + std::string(14U, ' '),
          "RPTC contains the validated height, location, and device description fields");
    check(packet.size() > 97U && packet[97U] == static_cast<std::uint8_t>('4'),
          "RPTC preserves the selected slot-flags field");
    check(field(packet, 98U, 124U) == std::string("www.qrz.com") + std::string(113U, ' ') &&
              field(packet, 222U, 40U) == std::string("20261024") + std::string(32U, ' ') &&
              field(packet, 262U, 40U) == std::string("MMDVM_WIREX_Bridge") +
                  std::string(40U - std::string("MMDVM_WIREX_Bridge").size(), ' '),
          "RPTC contains the accepted URL, software version, and virtual node type at fixed widths");
}

void test_shared_network_metadata()
{
    wirex::bm::Profile preset{};
    preset.gateway_id = 461135501U;
    preset.callsign = "BI7KGD";
    preset.password = "offline-secret-sentinel";
    preset.color_code = 1U;
    preset.options = "stale-option";
    const auto preset_password = preset.password;
    wirex::bm::apply_network_metadata(preset);
    check(preset.gateway_id == 461135501U && preset.callsign == "BI7KGD",
          "shared BM metadata does not overwrite Gateway ID or callsign");
    check(preset.password == preset_password,
          "shared BM metadata does not overwrite the secret");
    check(preset.color_code == 1U,
          "preset caller retains its explicitly selected color code");
    check(preset.options.empty(), "shared metadata clears the old optional RPTC options");
    check_rptc_metadata(rptc_for(std::move(preset)), "BI7KGD  ", "01");

    wirex::bm::Profile manual{};
    manual.gateway_id = 461135501U;
    manual.callsign = "N0MAN";
    manual.password = "manual-secret-sentinel";
    manual.color_code = 7U;
    const auto manual_password = manual.password;
    wirex::bm::apply_network_metadata(manual);
    check(manual.gateway_id == 461135501U && manual.callsign == "N0MAN" &&
              manual.password == manual_password && manual.color_code == 7U,
          "shared BM metadata preserves manual identity, password, and color-code input");
    check_rptc_metadata(rptc_for(std::move(manual)), "N0MAN   ", "07");
}

} // namespace

int main()
{
    using namespace wirex;
    using bm_test_profile::TxPolicy;
    using bm_test_profile::TxStartStatus;
    using dmr_call::CallKind;

    test_shared_network_metadata();

    const auto china = bm_test_profile::find("parrot-cn");
    const auto global = bm_test_profile::find("parrot-global");
    const auto listen = bm_test_profile::find("listen-46001");
    const auto listen_91 = bm_test_profile::find("listen-91");
    check(china.has_value(), "Chinese parrot preset exists");
    check(global.has_value(), "generic parrot preset exists");
    check(listen.has_value(), "receive-only 46001 preset exists");
    check(listen_91.has_value(), "receive-only TG91 preset exists");
    check(!bm_test_profile::find("unknown").has_value(), "unknown presets are rejected");
    if (!china || !global || !listen || !listen_91) return EXIT_FAILURE;

    check_common_identity(*china);
    check_common_identity(*global);
    check_common_identity(*listen);
    check_common_identity(*listen_91);
    check(china->destination_id == 460997U && china->kind == CallKind::private_call,
          "China preset targets private-call echo 460997");
    check(global->destination_id == 9990U && global->kind == CallKind::private_call,
          "generic preset targets private-call echo 9990");
    check(listen->destination_id == 46001U && listen->kind == CallKind::group,
          "46001 preset is a group call");
    check(listen_91->destination_id == 91U && listen_91->kind == CallKind::group,
          "TG91 preset targets group call 91");
    check(bm_test_profile::policy_for(call_for(*china)) == TxPolicy::enabled &&
          bm_test_profile::policy_for(call_for(*global)) == TxPolicy::enabled,
          "parrot presets allow explicitly requested transmit");
    const auto listen_call = call_for(*listen);
    check(bm_test_profile::policy_for(listen_call) == TxPolicy::receive_only,
          "46001 group preset is receive-only");
    const auto listen_91_call = call_for(*listen_91);
    check(bm_test_profile::policy_for(listen_91_call) == TxPolicy::receive_only,
          "TG91 group preset is receive-only");

    bm_voice::BmVoicePipeline listen_pipeline;
    const auto denied = bm_test_profile::begin_tx(bm_test_profile::policy_for(listen_call), listen_pipeline,
        listen_call, bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
    check(denied.status == TxStartStatus::denied_receive_only,
          "shared native transmit policy rejects T for 46001");
    check(listen_pipeline.snapshot().tx_state == bm_voice::TxState::idle,
          "receive-only T does not start the TX pipeline or create LC");
    check(!listen_pipeline.take_outbound().has_value(),
          "receive-only T creates no DMRD packet");

    bm_voice::BmVoicePipeline listen_91_pipeline;
    const auto listen_91_denied = bm_test_profile::begin_tx(
        bm_test_profile::policy_for(listen_91_call), listen_91_pipeline, listen_91_call,
        bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
    check(!bm_test_profile::permits_transmit(bm_test_profile::policy_for(listen_91_call)) &&
              listen_91_denied.status == TxStartStatus::denied_receive_only,
          "physical PTT and keyboard T share a transmit policy that rejects TG91 group calls");
    check(listen_91_pipeline.snapshot().tx_state == bm_voice::TxState::idle &&
              !listen_91_pipeline.take_outbound().has_value(),
          "TG91 receive-only policy creates no TX state, LC, or DMRD packet");

    auto manual_ts1_call = call_for(*china);
    manual_ts1_call.slot = dmr_call::Slot::ts1;
    bm_voice::BmVoicePipeline manual_ts1_pipeline;
    const auto manual_ts1_result = bm_test_profile::begin_tx(
        bm_test_profile::policy_for(manual_ts1_call), manual_ts1_pipeline, manual_ts1_call,
        bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
    const auto manual_ts1_header = manual_ts1_pipeline.take_outbound();
    check(manual_ts1_result.status == TxStartStatus::started && manual_ts1_header.has_value() &&
              (manual_ts1_header->datagram.flags & 0x80U) == 0U,
          "manual configuration may keep TS1 instead of inheriting the preset TS2 slot");
    manual_ts1_pipeline.cancel_tx();

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

    auto manual_tg91_group = listen_91_call;
    manual_tg91_group.slot = dmr_call::Slot::ts1;
    check(bm_test_profile::policy_for(manual_tg91_group) == TxPolicy::receive_only,
          "manual group destination 91 is receive-only on either timeslot");
    bm_voice::BmVoicePipeline manual_tg91_pipeline;
    const auto manual_tg91_denied = bm_test_profile::begin_tx(
        bm_test_profile::policy_for(manual_tg91_group), manual_tg91_pipeline, manual_tg91_group,
        bm_voice::Readiness{true, true}, bm_voice::TimePoint{});
    check(manual_tg91_denied.status == TxStartStatus::denied_receive_only &&
              manual_tg91_pipeline.snapshot().tx_state == bm_voice::TxState::idle &&
              !manual_tg91_pipeline.take_outbound().has_value(),
          "manual T for TG91 creates no TX state, LC, or DMRD packet");

    auto other_manual_group = listen_call;
    other_manual_group.destination_id = 46002U;
    check(bm_test_profile::policy_for(other_manual_group) == TxPolicy::enabled,
          "other manual group targets keep the existing transmit policy");
    auto manual_private_46001 = listen_call;
    manual_private_46001.kind = CallKind::private_call;
    check(bm_test_profile::policy_for(manual_private_46001) == TxPolicy::enabled,
          "the receive-only rule applies to group 46001, not private ID 46001");
    auto manual_private_91 = listen_91_call;
    manual_private_91.kind = CallKind::private_call;
    check(bm_test_profile::policy_for(manual_private_91) == TxPolicy::enabled,
          "TG91 receive-only rule applies to group calls, not private ID 91");

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
