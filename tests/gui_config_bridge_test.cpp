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

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
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

void test_start_config() {
    std::string error;
    auto sc = cb::make_start_config(sample_gui(), good_inputs(), error);
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

    // TX 目标不在频道表中 → 回落第一个频道（Normalize：tx_channel_id 默认第一项）。
    auto g = sample_gui();
    g.tx_target = wirex::talkgroup_routing::TxTarget{4000U, CallKind::group, Slot::ts2};
    sc = cb::make_start_config(g, good_inputs(), error);
    check(sc && sc->tx_policy.target.destination_id == 46001U, "start tx target fallback to first channel");

    struct Bad { const char* name; void (*mutate)(wirex::gui::services::GuiConfig&, cb::StartInputs&); };
    const Bad bad[] = {
        {"no_channels", [](auto& gg, auto&) { gg.channels.clear(); }},
        {"no_callsign", [](auto& gg, auto&) { gg.callsign.clear(); }},
        {"no_dmr_id", [](auto& gg, auto&) { gg.dmr_id = 0U; }},
        {"long_callsign", [](auto& gg, auto&) { gg.callsign = "ABCDEFGHI"; }},
        {"bad_master", [](auto& gg, auto&) { gg.master_host = "bad host"; }},
        {"no_hri", [](auto&, auto& in) { in.serial = catalog({{"COM6", false}}); }},
        {"saved_endpoint_missing", [](auto& gg, auto&) { gg.wave_in_endpoint_id = L"{gone}"; }},
        {"usb_not_unique", [](auto&, auto& in) { in.wave_inputs.push_back(wave(3U, "USB Audio Device", "{in-usb2}")); }},
        {"no_body", [](auto&, auto& in) { in.body_file.clear(); }},
    };
    for (const auto& b : bad) {
        auto gg = sample_gui();
        auto in = good_inputs();
        b.mutate(gg, in);
        error.clear();
        check(!cb::make_start_config(gg, in, error) && !error.empty(), std::string("start rejects ") + b.name);
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

int main() {
    SetConsoleOutputCP(CP_UTF8);
    test_device_number();
    test_rx_policy();
    test_channel_key();
    test_select_hri();
    test_start_config();
    test_round_trip_preserves_unknown();
    std::cout << "gui_config_bridge_test: " << (checks - failures) << "/" << checks << " passed\n";
    return failures == 0 ? 0 : 1;
}
