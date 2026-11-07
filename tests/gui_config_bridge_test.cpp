// src/gui/config_bridge 的表驱动测试：config.json ↔ GUI ↔ engine::StartConfig 的转换规则（对照 PS 版）。
#include "../src/gui/config_bridge.hpp"

#include "wirex/app/config.hpp"
#include "wirex/app/json.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;
namespace cb = wirex::gui::config_bridge;
namespace dev = wirex::app::devices;
using wirex::dmr_call::CallKind;
using wirex::dmr_call::Slot;

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const std::string& message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

fs::path scratch_dir() {
    wchar_t tmp[MAX_PATH] = {};
    const DWORD n = GetEnvironmentVariableW(L"TMPDIR", tmp, MAX_PATH);
    fs::path base = n > 0U && n < MAX_PATH ? fs::path(tmp) : fs::temp_directory_path();
    const auto dir = base / ("gui-config-bridge-" + std::to_string(GetCurrentProcessId()));
    fs::create_directories(dir);
    return dir;
}

wirex::gui::services::GuiConfig sample_gui() {
    wirex::gui::services::GuiConfig g;
    g.callsign = "N0CALL";
    g.dmr_id = 4609100U;
    g.device_number = "01";
    g.master_preset = "bm-china-4602";
    g.master_host = "43.129.83.124";
    g.master_port = 62031U;
    g.bm_password = "secret";
    g.channels = {{46001U, CallKind::group, Slot::ts2, "全国"},
                  {91U, CallKind::group, Slot::ts2, "World-wide"},
                  {460997U, CallKind::private_call, Slot::ts2, "中国鹦鹉"}};
    g.tx_target = wirex::talkgroup_routing::TxTarget{91U, CallKind::group, Slot::ts2};
    g.playback_gain_step = 4U;
    g.transmit_gain_step = 16U;
    return g;
}

dev::SerialCatalog catalog(std::vector<std::pair<std::string, bool>> ports) {
    std::vector<dev::SerialPortRecord> records;
    for (const auto& [name, hri] : ports) {
        dev::SerialPortRecord r;
        r.port_name = name;
        r.friendly_name = hri ? "Yaesu HRI-200" : "USB Serial";
        r.instance_id = hri ? "USB\\VID_26AA&PID_0030\\1" : "USB\\VID_10C4&PID_EA60\\2";
        r.source = "setupapi";
        records.push_back(r);
    }
    return dev::build_serial_catalog(records, true);
}

dev::WaveDevice wave(std::uint32_t id, const char* name, const char* endpoint) {
    dev::WaveDevice d;
    d.id = id;
    d.name = name;
    d.endpoint_id = std::string(endpoint);
    d.pcm_48000_mono_s16_supported = true;
    return d;
}

cb::StartInputs good_inputs() {
    cb::StartInputs in;
    in.color_code = 1U;
    in.serial = catalog({{"COM5", true}, {"COM6", false}});
    in.wave_inputs = {wave(0U, "Realtek Mic", "{in-realtek}"), wave(1U, "USB Audio CODEC", "{in-usb}")};
    in.wave_outputs = {wave(0U, "Speakers", "{out-spk}"), wave(2U, "USB Audio CODEC", "{out-usb}")};
    in.body_file = L"C:\\fake\\private\\device-y.bin";
    return in;
}

wirex::gui::services::DeviceInventory selection_inventory() {
    wirex::gui::services::DeviceInventory inv;
    inv.serial_discovery_status = "ready";
    inv.serial_ports = {
        {L"COM5", "COM5 · Yaesu HRI-200", true, false, 0, "HRI VID/PID 匹配"},
        {L"COM6", "COM6 · Silicon Labs CP210x", false, true, 220, "CP210x 匹配"},
        {L"COM7", "COM7 · Unknown UART", false, true, 0, "未识别；可手动选择"},
    };
    inv.wave_in = {{L"{usb-in}", "FTX-1 USB Audio Input", 1U, true}};
    inv.wave_out = {{L"{usb-out}", "FTX-1 USB Audio Output", 2U, true}};
    return inv;
}

std::wstring widen_ascii(const std::string& value) {
    return std::wstring(value.begin(), value.end());
}

void test_device_number() {
    struct Case { const char* name; std::uint32_t source; std::uint32_t gateway; const char* expected; };
    const Case cases[] = {
        {"new_empty", 0U, 0U, "01"},
        {"split_gateway_01", 4609100U, 460910001U, "01"},
        {"split_gateway_99", 4609100U, 460910099U, "99"},
        {"split_gateway_00", 4609100U, 460910000U, "00"},
        {"legacy_bare_id", 4609100U, 4609100U, ""},
        {"legacy_unmatched", 4609100U, 123U, ""},
    };
    for (const auto& c : cases) {
        check(cb::device_number_for(c.source, c.gateway) == c.expected, std::string("device_number_for ") + c.name);
    }
}

void test_rx_policy() {
    const auto g = sample_gui();
    // 未屏蔽：组呼 allow，单呼 selected_peers，blocked_groups 恒空。
    auto p = cb::make_rx_policy(g.channels, {}, g.dmr_id, {1234U, 1234U});
    check(p.group_mode == wirex::talkgroup_routing::GroupMode::selected, "rx group_mode selected");
    check(p.allowed_groups.size() == 2U && p.blocked_groups.empty(), "rx allow 2 groups, no blocked_groups");
    check(p.private_mode == wirex::talkgroup_routing::PrivateMode::selected_peers && p.private_peers.size() == 1U &&
              p.private_peers[0].local_destination_id == g.dmr_id,
          "rx private peer to local source id");
    check(p.blocked_source_ids.size() == 1U, "rx blocked_source_ids deduplicated");
    // 屏蔽组呼 = 从 allow 移除（不能同时出现在 allow 和 block，Router 会拒绝）；屏蔽唯一单呼 → disabled。
    p = cb::make_rx_policy(g.channels, {"group:91:2", "private:460997:2"}, g.dmr_id, {});
    check(p.allowed_groups.size() == 1U && p.allowed_groups[0].destination_id == 46001U, "muted group removed from allow");
    check(p.blocked_groups.empty(), "muted group not in blocked_groups");
    check(p.private_mode == wirex::talkgroup_routing::PrivateMode::disabled && p.private_peers.empty(),
          "all private muted → disabled");
}

void test_channel_key() {
    const auto t = cb::parse_channel_key("private:460997:2");
    check(t && t->destination_id == 460997U && t->kind == CallKind::private_call && t->slot == Slot::ts2, "parse key");
    for (const char* bad : {"", "group:0:1", "group:1:3", "talk:1:1", "group:x:1", "group:16777216:1", "group:1:1:"}) {
        check(!cb::parse_channel_key(bad), std::string("reject key ") + bad);
    }
    check(cb::channel_key(46001U, CallKind::group, Slot::ts1) == "group:46001:1", "format key");
}

void test_select_hri() {
    struct Case { const char* name; std::vector<std::pair<std::string, bool>> ports; const char* requested; const char* expected; };
    const Case cases[] = {
        {"auto_unique_hri", {{"COM5", true}, {"COM6", false}}, "", "COM5"},
        {"auto_literal", {{"COM5", true}, {"COM6", false}}, "auto", "COM5"},
        {"explicit_hri", {{"COM5", true}, {"COM7", true}}, "com7", "COM7"},
        {"auto_two_hri", {{"COM5", true}, {"COM7", true}}, "", nullptr},
        {"explicit_not_hri", {{"COM5", true}, {"COM6", false}}, "COM6", nullptr},
        {"explicit_missing", {{"COM5", true}}, "COM9", nullptr},
        {"no_hri", {{"COM6", false}}, "", nullptr},
        {"no_ports", {}, "", nullptr},
    };
    for (const auto& c : cases) {
        std::string error;
        const auto port = cb::select_hri_port(catalog(c.ports), c.requested, error);
        if (c.expected == nullptr) {
            check(!port && !error.empty(), std::string("select_hri rejects ") + c.name);
        } else {
            check(port && *port == c.expected, std::string("select_hri ") + c.name);
        }
    }
}

void test_active_device_ids() {
    wirex::engine::Snapshot snapshot;
    snapshot.serial_open = true;
    snapshot.hri_port = L"COM5";
    snapshot.wave_in_open = true;
    snapshot.wave_in_endpoint_id = L"{wave-in-active}";
    snapshot.wave_out_open = true;
    snapshot.wave_out_endpoint_id = L"{wave-out-active}";
    wirex::gui::services::CatState cat;
    cat.busy = true;
    cat.port = L"COM77"; // CAT busy may still retain a previous port while a new query is pending.

    auto active = cb::active_device_ids(snapshot, cat);
    check(active.hri_port == L"COM5" && active.wave_in_endpoint_id == L"{wave-in-active}" &&
              active.wave_out_endpoint_id == L"{wave-out-active}",
          "open Engine endpoints are exposed as the active IDs");
    check(active.cat_port.empty(), "CAT busy without confirmed connection does not publish an active port");

    cat.connected = true;
    active = cb::active_device_ids(snapshot, cat);
    check(active.cat_port == L"COM77", "CAT port becomes active after CatState confirms connected");

    cat.connected = false;
    cat.busy = false;
    active = cb::active_device_ids(snapshot, cat);
    check(active.cat_port.empty(), "disconnected CAT state does not publish its retained previous port");
}

void test_device_selection_preview_and_reinsert() {
    using wirex::gui::services::DeviceResolutionState;
    using wirex::gui::services::DeviceSelectionSource;
    auto gui = sample_gui();
    auto inventory = selection_inventory();

    auto selected = cb::resolve_device_selection(gui, inventory);
    check(selected.hri.state == DeviceResolutionState::resolved && selected.hri.resolved_id == L"COM5" &&
              selected.hri.name.find("Yaesu HRI-200") != std::string::npos,
          "HRI Auto preview resolves and names the unique classified port");
    check(selected.cat.state == DeviceResolutionState::resolved && selected.cat.resolved_id == L"COM6" &&
              selected.cat.source == DeviceSelectionSource::automatic,
          "CAT Auto preview resolves the unique strongest classified candidate");
    check(selected.wave_in.state == DeviceResolutionState::resolved && selected.wave_in.resolved_id == L"{usb-in}" &&
              selected.wave_in.name == "FTX-1 USB Audio Input",
          "audio input Auto preview resolves its endpoint ID and friendly name");
    check(selected.wave_out.state == DeviceResolutionState::resolved && selected.wave_out.resolved_id == L"{usb-out}" &&
              selected.wave_out.name == "FTX-1 USB Audio Output",
          "audio output Auto preview resolves its endpoint ID and friendly name");
    check(selected.hri.requested_id.empty() && selected.cat.requested_id.empty() &&
              selected.wave_in.requested_id.empty() && selected.wave_out.requested_id.empty() &&
              gui.hri_port.empty() && gui.cat_port.empty() && gui.wave_in_endpoint_id.empty() &&
              gui.wave_out_endpoint_id.empty(),
          "resolved Auto preview never writes the concrete IDs into saved selectors");
    auto alternate_auto_spelling = gui;
    alternate_auto_spelling.hri_port = L" AUTO ";
    alternate_auto_spelling.cat_port = L"Auto";
    alternate_auto_spelling.wave_in_endpoint_id = L" AUTO ";
    alternate_auto_spelling.wave_out_endpoint_id = L"Auto";
    const auto normalized_auto = cb::resolve_device_selection(alternate_auto_spelling, inventory);
    check(normalized_auto.hri.resolved_id == selected.hri.resolved_id &&
              normalized_auto.cat.resolved_id == selected.cat.resolved_id &&
              normalized_auto.wave_in.resolved_id == selected.wave_in.resolved_id &&
              normalized_auto.wave_out.resolved_id == selected.wave_out.resolved_id,
          "case and surrounding spaces in Auto selectors resolve to the same preview IDs");

    auto ambiguous = inventory;
    ambiguous.serial_ports.push_back({L"COM8", "COM8 · second HRI", true, false, 0, "HRI VID/PID 匹配"});
    ambiguous.serial_ports.push_back({L"COM9", "COM9 · second CP210x", false, true, 220, "CP210x 匹配"});
    ambiguous.wave_in.push_back({L"{usb-in-2}", "Second USB Audio Input", 3U, true});
    selected = cb::resolve_device_selection(gui, ambiguous);
    check(selected.hri.state == DeviceResolutionState::ambiguous && selected.hri.resolved_id.empty(),
          "multiple HRI devices remain unresolved until manual selection");
    check(selected.cat.state == DeviceResolutionState::ambiguous && selected.cat.resolved_id.empty(),
          "a tie among strongest CAT candidates remains unresolved");
    auto ambiguous_audio = inventory;
    ambiguous_audio.wave_in.push_back({L"{usb-in-2}", "Second USB Audio Input", 3U, true});
    selected = cb::resolve_device_selection(gui, ambiguous_audio);
    check(selected.wave_in.state == DeviceResolutionState::ambiguous && selected.wave_in.resolved_id.empty(),
          "multiple USB Audio inputs remain unresolved while HRI is uniquely identified");

    auto manual = gui;
    manual.hri_port = L"COM5";
    manual.cat_port = L"COM7";
    manual.wave_in_endpoint_id = L"{usb-in}";
    manual.wave_out_endpoint_id = L"{usb-out}";
    selected = cb::resolve_device_selection(manual, inventory);
    check(selected.hri.state == DeviceResolutionState::resolved && selected.hri.source == DeviceSelectionSource::saved,
          "a manually selected HRI port remains selected when currently identified");
    check(selected.cat.state == DeviceResolutionState::manual_unclassified && selected.cat.resolved_id == L"COM7" &&
              selected.cat.source == DeviceSelectionSource::manual,
          "manual CAT selection of an enumerated unknown UART is visible but not auto-identified");
    check(selected.wave_in.state == DeviceResolutionState::resolved && selected.wave_in.resolved_id == L"{usb-in}" &&
              selected.wave_out.state == DeviceResolutionState::resolved && selected.wave_out.resolved_id == L"{usb-out}",
          "explicit stable audio endpoint IDs resolve independently of USB auto matching");

    manual.cat_port = L"COM5";
    selected = cb::resolve_device_selection(manual, inventory);
    check(selected.cat.state == DeviceResolutionState::conflict,
          "CAT manual selection is rejected when it would share the HRI port");

    auto unplugged = gui;
    unplugged.hri_port = L"COM5";
    unplugged.cat_port = L"COM10";
    unplugged.wave_in_endpoint_id = L"{removed-in}";
    unplugged.wave_out_endpoint_id = L"{removed-out}";
    selected = cb::resolve_device_selection(unplugged, inventory);
    check(selected.cat.state == DeviceResolutionState::missing && selected.cat.requested_id == L"COM10" &&
              selected.wave_in.state == DeviceResolutionState::missing &&
              selected.wave_in.requested_id == L"{removed-in}",
          "unplugged explicit devices remain visible as missing without clearing saved IDs");

    auto reinserted = inventory;
    reinserted.serial_ports.push_back({L"COM10", "COM10 · CP210x restored", false, true, 220, "CP210x 匹配"});
    reinserted.wave_in.push_back({L"{removed-in}", "Restored USB Audio Input", 4U, true});
    reinserted.wave_out.push_back({L"{removed-out}", "Restored USB Audio Output", 5U, true});
    selected = cb::resolve_device_selection(unplugged, reinserted);
    check(selected.cat.state == DeviceResolutionState::resolved && selected.cat.resolved_id == L"COM10" &&
              selected.wave_in.resolved_id == L"{removed-in}" && selected.wave_out.resolved_id == L"{removed-out}",
          "reinserted devices with the same COM and endpoint IDs resolve again from preserved config");

    auto changed_hardware = reinserted;
    changed_hardware.serial_ports.erase(std::remove_if(changed_hardware.serial_ports.begin(),
        changed_hardware.serial_ports.end(), [](const auto& port) { return port.port == L"COM6"; }),
        changed_hardware.serial_ports.end());
    selected = cb::resolve_device_selection(gui, changed_hardware);
    check(selected.cat.state == DeviceResolutionState::resolved && selected.cat.resolved_id == L"COM10" &&
              gui.cat_port.empty(),
          "Auto resolves a reinserted device at its new COM number without persisting that number");

    cb::ActiveDeviceIds active;
    active.hri_port = L"COM77";
    active.cat_port = L"COM78";
    active.wave_in_endpoint_id = L"{active-in}";
    active.wave_out_endpoint_id = L"{active-out}";
    selected = cb::resolve_device_selection(gui, inventory, active);
    check(selected.hri.active && selected.hri.state == DeviceResolutionState::active_not_enumerated &&
              selected.hri.resolved_id == L"COM77",
          "active Engine port remains the displayed actual ID when a refresh no longer enumerates it");
    check(selected.cat.active && selected.cat.resolved_id == L"COM78" &&
              selected.wave_in.active && selected.wave_in.resolved_id == L"{active-in}" &&
              selected.wave_out.active && selected.wave_out.resolved_id == L"{active-out}",
          "active CAT and audio IDs override the idle Auto preview in the display snapshot");

    auto unavailable = inventory;
    unavailable.serial_ports.clear();
    unavailable.serial_discovery_status = "failed";
    selected = cb::resolve_device_selection(gui, unavailable);
    check(selected.hri.state == DeviceResolutionState::unavailable &&
              selected.cat.state == DeviceResolutionState::unavailable,
          "device catalog errors are distinguished from an empty or ambiguous catalog");
}

void test_bm_only_wave_out_resolution() {
    using wirex::gui::services::DeviceResolutionState;
    auto gui = sample_gui();
    gui.hri_port.clear();
    gui.wave_in_endpoint_id.clear();
    gui.wave_out_endpoint_id.clear();
    wirex::gui::services::DeviceInventory inventory;
    inventory.serial_discovery_status = "empty";
    inventory.wave_out.push_back({L"{speaker}", "Speakers (Realtek)", 4U, false});

    std::string error;
    auto output = cb::resolve_local_playback_output(gui, inventory, error);
    check(output && output->wave_out_id == 4U && output->expected_wave_out_endpoint_id == L"{speaker}" &&
              output->expected_wave_in_endpoint_id.empty() && error.empty(),
          "BM-only output auto resolves one computer speaker without HRI or WaveIn");
    auto preview = cb::resolve_device_selection(gui, inventory);
    check(preview.hri.state == DeviceResolutionState::missing &&
              preview.wave_in.state == DeviceResolutionState::missing &&
              preview.wave_out.state == DeviceResolutionState::resolved && preview.wave_out.resolved_id == L"{speaker}",
          "BM-only device preview can resolve local WaveOut while radio and WaveIn are absent");

    inventory.wave_out.push_back({L"{headphones}", "Headphones (USB DAC)", 7U, false});
    output = cb::resolve_local_playback_output(gui, inventory, error);
    check(!output && !error.empty(), "multiple non-USB outputs require an explicit selection");
    preview = cb::resolve_device_selection(gui, inventory);
    check(preview.wave_out.state == DeviceResolutionState::ambiguous &&
              preview.wave_out.resolved_id.empty(),
          "multiple output candidates are not silently selected");

    inventory.wave_out.insert(inventory.wave_out.begin(),
        {L"{radio-usb}", "FTX-1 USB Audio Output", 2U, true});
    output = cb::resolve_local_playback_output(gui, inventory, error);
    check(output && output->expected_wave_out_endpoint_id == L"{radio-usb}",
          "existing unique USB Audio auto choice remains preferred with computer speakers also present");

    gui.wave_out_endpoint_id = L"{speaker}";
    output = cb::resolve_local_playback_output(gui, inventory, error);
    check(output && output->expected_wave_out_endpoint_id == L"{speaker}",
          "manual computer speaker selection works independently of the radio USB input");
}

void test_start_config() {
    std::string error;
    const auto gui = sample_gui();
    const auto start_inputs = good_inputs();
    auto sc = cb::make_start_config(gui, start_inputs, error);
    check(sc.has_value(), "start config ok: " + error);
    if (!sc) return;
    check(sc->hri_port == L"COM5", "start hri port auto");
    check(sc->audio.wave_in_id == 1U && sc->audio.wave_out_id == 2U, "start wave ids from USB Audio pair");
    check(sc->audio.expected_wave_in_endpoint_id == L"{in-usb}" && sc->audio.expected_wave_out_endpoint_id == L"{out-usb}",
          "start expected endpoints");
    check(sc->bm.profile.gateway_id == 460910001U && sc->local_source_id == 4609100U, "start gateway = id*100+no");
    check(sc->bm.profile.callsign == "N0CALL" && sc->bm.profile.password == "secret", "start callsign/password");
    check(sc->bm.profile.software == "MMDVM_WIREX_Bridge" && sc->bm.profile.description == "FTX-1" &&
              sc->bm.profile.rx_frequency == 438800000U && sc->bm.profile.slot_flags == '4',
          "start RPTC metadata = apply_network_metadata");
    check(sc->bm.profile.color_code == 1U, "start color code from config");
    check(sc->bm.master_host == "43.129.83.124" && sc->bm.master_port == 62031U, "start master");
    check(sc->bm_start_disconnected, "start bm disconnected");
    check(sc->tx_policy.transmit_enabled && !sc->tx_policy.dynamic_join_enabled, "start tx enabled, dynamic join off");
    check(sc->tx_policy.target.destination_id == 91U && sc->tx_policy.target.kind == CallKind::group &&
              sc->tx_policy.target.slot == Slot::ts2,
          "start tx target from tx_channel_id");
    check(sc->rx_policy.allowed_groups.size() == 2U && sc->rx_policy.private_peers.size() == 1U, "start rx policy");
    check(sc->radio_playback_gain_milli == 4000U && sc->mic_transmit_gain_milli == 16000U, "start gains");

    wirex::gui::services::DeviceInventory inventory;
    inventory.serial_discovery_status = "ready";
    for (const auto& port : start_inputs.serial.serial_ports) {
        inventory.serial_ports.push_back({widen_ascii(port.port_name), port.port_name + " · " + port.friendly_name,
                                          port.is_hri, port.is_cat_candidate, port.cat_match_rank,
                                          port.cat_match_reason});
    }
    const auto add_audio = [](const std::vector<dev::WaveDevice>& waves,
                              std::vector<wirex::gui::services::AudioEndpointInfo>& endpoints) {
        for (const auto& item : waves) {
            if (!dev::usable(item)) continue;
            endpoints.push_back({widen_ascii(*item.endpoint_id), item.name, item.id,
                                 dev::is_usb_audio_name(item.name)});
        }
    };
    add_audio(start_inputs.wave_inputs, inventory.wave_in);
    add_audio(start_inputs.wave_outputs, inventory.wave_out);
    const auto preview = cb::resolve_device_selection(gui, inventory);
    check(preview.hri.resolved_id == sc->hri_port,
          "displayed HRI Auto ID equals the port selected for the actual start configuration");
    check(preview.wave_in.resolved_id == sc->audio.expected_wave_in_endpoint_id &&
              preview.wave_out.resolved_id == sc->audio.expected_wave_out_endpoint_id,
          "displayed audio Auto endpoint IDs equal those selected for the actual start configuration");
    auto alternate_auto_gui = gui;
    alternate_auto_gui.hri_port = L" AUTO ";
    alternate_auto_gui.wave_in_endpoint_id = L" AUTO ";
    alternate_auto_gui.wave_out_endpoint_id = L"Auto";
    error.clear();
    const auto alternate_start = cb::make_start_config(alternate_auto_gui, start_inputs, error);
    check(alternate_start && alternate_start->hri_port == sc->hri_port &&
              alternate_start->audio.expected_wave_in_endpoint_id == sc->audio.expected_wave_in_endpoint_id &&
              alternate_start->audio.expected_wave_out_endpoint_id == sc->audio.expected_wave_out_endpoint_id,
          "start-time helper treats case-insensitive Auto spellings like the displayed Auto selection");
    dev::PortSelectionError cat_error{};
    const auto cat = dev::resolve_port_selection(start_inputs.serial, "auto", "auto", "", cat_error);
    check(cat_error == dev::PortSelectionError::none && cat.cat_port &&
              preview.cat.resolved_id == widen_ascii(*cat.cat_port),
          "displayed CAT Auto ID equals the production serial selection helper result");

    auto embedded = good_inputs();
    embedded.body_file.clear();
    error.clear();
    sc = cb::make_start_config(sample_gui(), embedded, error);
    check(sc && sc->hri_body_file.empty(), "empty body path selects the approved embedded template");

    // TX 目标不在频道表中 → 回落第一个频道（Normalize：tx_channel_id 默认第一项）。
    auto g = sample_gui();
    g.tx_target = wirex::talkgroup_routing::TxTarget{4000U, CallKind::group, Slot::ts2};
    sc = cb::make_start_config(g, good_inputs(), error);
    check(sc && sc->tx_policy.target.destination_id == 46001U, "start tx target fallback to first channel");

    error = "stale-error";
    auto runtime_only = cb::make_runtime_config(sample_gui(), 7U, error);
    check(runtime_only && !runtime_only->start_radio && runtime_only->bm_start_disconnected &&
              runtime_only->hri_port.empty() && runtime_only->audio.expected_wave_in_endpoint_id.empty() &&
              error.empty(),
          "runtime-only config clears stale errors and does not resolve or open radio devices");

    struct Bad {
        const char* name;
        void (*mutate)(wirex::gui::services::GuiConfig&, cb::StartInputs&);
        bool bm_only_invalid;
    };
    const Bad bad[] = {
        {"no_channels", [](auto& gg, auto&) { gg.channels.clear(); }, true},
        {"no_callsign", [](auto& gg, auto&) { gg.callsign.clear(); }, true},
        {"no_dmr_id", [](auto& gg, auto&) { gg.dmr_id = 0U; }, true},
        {"long_callsign", [](auto& gg, auto&) { gg.callsign = "ABCDEFGHI"; }, true},
        {"bad_master", [](auto& gg, auto&) { gg.master_host = "bad host"; }, true},
        {"no_hri", [](auto&, auto& in) { in.serial = catalog({{"COM6", false}}); }, false},
        {"saved_endpoint_missing", [](auto& gg, auto&) { gg.wave_in_endpoint_id = L"{gone}"; }, false},
        {"usb_not_unique", [](auto&, auto& in) { in.wave_inputs.push_back(wave(3U, "USB Audio Device", "{in-usb2}")); }, false},
    };
    for (const auto& b : bad) {
        auto gg = sample_gui();
        auto in = good_inputs();
        b.mutate(gg, in);
        error.clear();
        const auto candidate = cb::make_start_config(gg, in, error);
        if (b.bm_only_invalid) {
            check(candidate && candidate->start_radio && error.empty(),
                  std::string("BM-only invalid field does not block radio start: ") + b.name);
            if (candidate && std::string_view(b.name) == "no_channels") {
                check(!candidate->tx_policy.transmit_enabled,
                      "an empty saved channel list leaves BM transmit disabled while radio starts");
            }
        } else {
            check(!candidate && !error.empty(), std::string("radio selection rejects ") + b.name);
        }
        check(error.find("secret") == std::string::npos, std::string("error has no password ") + b.name);
    }

    // 显式 endpoint：按 id 精确匹配（大小写不敏感）。
    g = sample_gui();
    g.wave_in_endpoint_id = L"{IN-REALTEK}";
    g.wave_out_endpoint_id = L"{out-spk}";
    sc = cb::make_start_config(g, good_inputs(), error);
    check(sc && sc->audio.wave_in_id == 0U && sc->audio.wave_out_id == 0U, "start explicit endpoints");
}

void test_round_trip_preserves_unknown() {
    const auto dir = scratch_dir();
    const auto path = dir / "config.json";
    std::error_code ec;
    fs::remove(path, ec);
    auto created = wirex::app::create_default(path);
    check(created.ok(), "create_default");
    if (!created.ok()) return;

    // 注入未知字段（根、section、频道），再读回并经 GUI 保存。
    std::string text;
    {
        std::ifstream in(path, std::ios::binary);
        text.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    }
    const auto pos = text.rfind('}');
    text.insert(pos, ",\n    \"future_extension\": {\"keep\": true}\n");
    const auto conn = text.find("\"callsign\"");
    text.insert(conn, "\"future_connection_field\": 7,\n");
    {
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        out << text;
    }
    auto loaded = wirex::app::load(path);
    check(loaded.ok(), "load with unknown fields");
    if (!loaded.ok()) return;

    auto gui = cb::to_gui(loaded.value());
    check(gui.hri_port.empty() && gui.wave_in_endpoint_id.empty(), "auto → empty selectors");
    check(gui.device_number == "01" && gui.channels.size() == 1U && gui.channels[0].slot == Slot::ts2, "defaults to gui");
    gui.callsign = "N0CALL";
    gui.dmr_id = 4609100U;
    gui.device_number = "07";
    gui.bm_api_key = "  key-with-space  ";
    gui.desired_power_watts = 15U;
    gui.hri_port = L"com5";
    gui.channels.push_back({46001U, CallKind::group, Slot::ts2, ""});
    gui.tx_target = wirex::talkgroup_routing::TxTarget{46001U, CallKind::group, Slot::ts2};
    std::string error;
    auto next = cb::apply_gui(loaded.value(), gui, error);
    check(next.has_value(), "apply_gui: " + error);
    if (!next) return;
    check(next->connection.gateway_id == 460910007U, "apply gateway id");
    check(next->connection.api_key == "key-with-space", "apply trims api key");
    check(next->devices.hri_port == "COM5" && next->devices.cat_port == "auto", "apply port selectors");
    check(next->tx_channel_id == "group:46001:2", "apply tx channel id");
    check(next->channels.back().name == "全国", "apply known channel name");
    auto saved = wirex::app::save(path, *next);
    check(saved.ok(), "save");
    {
        std::ifstream in(path, std::ios::binary);
        text.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    }
    check(text.find("future_extension") != std::string::npos, "unknown root section preserved");
    check(text.find("future_connection_field") != std::string::npos, "unknown connection field preserved");
    auto reread = wirex::app::load(path);
    check(reread.ok() && cb::to_gui(reread.value()).device_number == "07", "reread device number");
    check(reread.ok() && cb::to_gui(reread.value()).desired_power_watts == 15U,
          "desired power round-trips through config.json");
    auto channel = cb::to_gui(reread.value());
    channel.hri_frequency_hz = 430125000U;
    channel.hri_mode = wirex::hri_y::LchMode::c4fm_dn;
    const auto channel_config = cb::apply_gui(reread.value(), channel, error);
    check(channel_config && channel_config->devices.hri_frequency_hz == 430125000U &&
          channel_config->devices.hri_mode == "c4fm_dn", "GUI channel converts to portable config");
    if (channel_config) {
        const auto saved_channel = wirex::app::save(path, *channel_config);
        const auto loaded_channel = wirex::app::load(path);
        check(saved_channel && loaded_channel && cb::to_gui(loaded_channel.value()).hri_frequency_hz == 430125000U &&
              cb::to_gui(loaded_channel.value()).hri_mode == wirex::hri_y::LchMode::c4fm_dn,
              "GUI channel round-trips through config.json");
    }
    channel.hri_frequency_hz = 145100001U;
    check(!cb::apply_gui(reread.value(), channel, error), "GUI rejects invalid HRI frequency");
    auto invalid_power = gui;
    invalid_power.desired_power_watts = 51U;
    check(!cb::apply_gui(reread.value(), invalid_power, error), "reject GUI desired power above 50 W");
    invalid_power.desired_power_watts = 4U;
    check(!cb::apply_gui(reread.value(), invalid_power, error), "reject GUI desired power below 5 W");

    // 设备编号规则（Get-UiGatewayIdentityForSave）
    auto g2 = cb::to_gui(reread.value());
    g2.device_number = "7";
    check(!cb::apply_gui(reread.value(), g2, error), "reject one-digit device number");
    g2.device_number.clear();
    g2.dmr_id = 4609101U;
    check(!cb::apply_gui(reread.value(), g2, error), "reject changed id with empty device number");
    g2.dmr_id = 4609100U;
    g2.gateway_id = 4609100U; // legacy bare id
    auto legacy = cb::apply_gui(reread.value(), g2, error);
    check(legacy && legacy->connection.gateway_id == 4609100U, "keep legacy gateway with empty device number");
    // 自定义服务器
    g2 = cb::to_gui(reread.value());
    g2.master_preset = "custom";
    g2.master_host = "bm.example.org";
    g2.master_port = 55555U;
    auto custom = cb::apply_gui(reread.value(), g2, error);
    check(custom && custom->connection.master == "bm.example.org" && custom->connection.master_port == 55555U &&
              custom->ui.bm_server_selection_id == "custom",
          "custom server");
    g2.master_preset = "bm-us-3102";
    auto us = cb::apply_gui(reread.value(), g2, error);
    check(us && us->connection.master == "3102.master.brandmeister.network", "catalog server hostname");
    fs::remove_all(dir, ec);
}

} // namespace

// R130：relay.enabled / relay.fm_enabled 与 GuiConfig 往返；默认关闭。
void test_relay_round_trip() {
    const auto base = wirex::app::default_config();
    auto gui = cb::to_gui(base);
    check(!gui.relay_enabled && !gui.relay_fm_enabled, "relay toggles default off");
    gui.relay_enabled = true;
    gui.relay_fm_enabled = true;
    std::string error;
    auto next = cb::apply_gui(base, gui, error);
    check(next.has_value() && next->relay.enabled && next->relay.fm_enabled, "apply_gui writes relay toggles");
    if (!next) return;
    const auto back = cb::to_gui(*next);
    check(back.relay_enabled && back.relay_fm_enabled, "to_gui reads relay toggles");
    gui.relay_enabled = false;
    next = cb::apply_gui(*next, gui, error);
    check(next.has_value() && !next->relay.enabled && next->relay.fm_enabled,
          "relay master switch is independent of the stored FM toggle");
    // R131：relay.y_template 默认 DIRECT，"ap" 往返。
    check(!gui.relay_y_template_ap && next.has_value() && !next->relay.y_template_ap,
          "relay y_template defaults to direct");
    gui.relay_y_template_ap = true;
    next = cb::apply_gui(*next, gui, error);
    check(next.has_value() && next->relay.y_template_ap, "apply_gui writes relay.y_template=ap");
    check(next.has_value() && cb::to_gui(*next).relay_y_template_ap,
          "to_gui reads relay.y_template=ap");
}

int main() {
    SetConsoleOutputCP(CP_UTF8);
    test_relay_round_trip();
    test_device_number();
    test_rx_policy();
    test_channel_key();
    test_select_hri();
    test_active_device_ids();
    test_device_selection_preview_and_reinsert();
    test_bm_only_wave_out_resolution();
    test_start_config();
    test_round_trip_preserves_unknown();
    std::cout << "gui_config_bridge_test: " << (checks - failures) << "/" << checks << " passed\n";
    return failures == 0 ? 0 : 1;
}
