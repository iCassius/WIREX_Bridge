#include "config_bridge.hpp"

#include "wirex/app/bm_servers.hpp"
#include "wirex/bm_connection_config.hpp"
#include "wirex/bm_network_metadata.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <charconv>
#include <cmath>

namespace wirex::gui::config_bridge {
namespace {

using dmr_call::CallKind;
using dmr_call::Slot;

std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string out(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring out(static_cast<std::size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

// "auto" ↔ 空
std::wstring from_selector(const std::string& value) { return value == "auto" ? std::wstring{} : widen(value); }
std::string to_selector(const std::wstring& value) {
    std::string s = narrow(value);
    const auto first = s.find_first_not_of(" \t");
    if (first == std::string::npos) return "auto";
    s = s.substr(first, s.find_last_not_of(" \t") - first + 1U);
    return s.empty() ? "auto" : s;
}

std::string upper_ascii(std::string s) {
    for (char& c : s) {
        if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
    }
    return s;
}

std::string trim(const std::string& s) {
    const auto first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1U);
}

bool is_com_name(const std::string& s) {
    if (s.size() < 4U || s.size() > 6U || s.compare(0, 3, "COM") != 0 || s[3] < '1' || s[3] > '9') return false;
    return std::all_of(s.begin() + 4, s.end(), [](char c) { return c >= '0' && c <= '9'; });
}

std::uint32_t gain_step(std::uint32_t milli) {
    return static_cast<std::uint32_t>(std::clamp(static_cast<int>(std::lround(static_cast<double>(milli) / 1000.0)), 1, 16));
}

Slot to_slot(std::uint8_t slot) { return slot == 1U ? Slot::ts1 : Slot::ts2; }

const char* kind_name(CallKind kind) { return kind == CallKind::group ? "group" : "private"; }

} // namespace

// ---------------------------------------------------------------- 小工具

std::string device_number_for(std::uint32_t source_id, std::uint32_t gateway_id) {
    if (source_id == 0U && gateway_id == 0U) return "01"; // new_empty
    const std::uint64_t base = static_cast<std::uint64_t>(source_id) * 100U;
    if (source_id != 0U && gateway_id >= base && gateway_id < base + 100U) {
        const auto n = static_cast<unsigned>(gateway_id - base);
        return std::string{static_cast<char>('0' + n / 10U), static_cast<char>('0' + n % 10U)};
    }
    return {}; // legacy_bare_id / legacy_unmatched：沿用原 gateway_id
}

std::string known_channel_name(std::uint32_t id, CallKind kind) {
    if (kind == CallKind::group && id == 91U) return "World-wide";
    if (kind == CallKind::group && id == 46001U) return "全国";
    if (kind == CallKind::private_call && id == 460997U) return "中国鹦鹉";
    return {};
}

std::string channel_key(std::uint32_t id, CallKind kind, Slot slot) {
    return std::string(kind_name(kind)) + ":" + std::to_string(id) + ":" + std::to_string(static_cast<int>(slot));
}

std::optional<talkgroup_routing::TxTarget> parse_channel_key(const std::string& key) {
    const auto a = key.find(':');
    const auto b = a == std::string::npos ? std::string::npos : key.find(':', a + 1U);
    if (b == std::string::npos) return std::nullopt;
    const std::string kind = key.substr(0, a);
    std::uint32_t id = 0U;
    std::uint32_t slot = 0U;
    const char* id_begin = key.data() + a + 1U;
    const char* id_end = key.data() + b;
    if (std::from_chars(id_begin, id_end, id).ptr != id_end) return std::nullopt;
    const char* slot_begin = key.data() + b + 1U;
    const char* slot_end = key.data() + key.size();
    if (std::from_chars(slot_begin, slot_end, slot).ptr != slot_end) return std::nullopt;
    if ((kind != "group" && kind != "private") || id == 0U || id > 16777215U || (slot != 1U && slot != 2U)) return std::nullopt;
    return talkgroup_routing::TxTarget{id, kind == "group" ? CallKind::group : CallKind::private_call,
                                       slot == 1U ? Slot::ts1 : Slot::ts2};
}

// ---------------------------------------------------------------- config.json → GUI

services::GuiConfig to_gui(const app::AppConfig& config) {
    services::GuiConfig g;
    g.ui_language = config.ui.language;
    g.callsign = config.connection.callsign;
    g.dmr_id = config.connection.source_id;
    g.gateway_id = config.connection.gateway_id;
    g.device_number = device_number_for(config.connection.source_id, config.connection.gateway_id);
    g.master_preset = config.ui.bm_server_selection_id;
    g.master_host = config.connection.master;
    g.master_port = config.connection.master_port;
    g.bm_password = config.connection.password;
    g.bm_api_key = config.connection.api_key;
    g.hri_port = from_selector(config.devices.hri_port);
    g.cat_port = from_selector(config.devices.cat_port);
    g.cat_baud_rate = config.devices.cat_baud_rate;
    g.wave_in_endpoint_id = from_selector(config.devices.wave_in_endpoint_id);
    g.wave_out_endpoint_id = from_selector(config.devices.wave_out_endpoint_id);
    g.playback_gain_step = gain_step(config.audio.radio_playback_gain_milli);
    g.transmit_gain_step = gain_step(config.audio.mic_transmit_gain_milli);
    for (const auto& ch : config.channels) {
        services::ChannelEntry e;
        e.id = ch.id;
        e.kind = ch.kind == app::ChannelKind::group ? CallKind::group : CallKind::private_call;
        e.slot = to_slot(ch.slot);
        e.name = ch.name;
        g.channels.push_back(std::move(e));
    }
    g.tx_target = parse_channel_key(config.tx_channel_id);
    g.blocked_source_ids = config.routing.blocked_source_ids;
    return g;
}

// ---------------------------------------------------------------- GUI → config.json

std::optional<app::AppConfig> apply_gui(const app::AppConfig& base, const services::GuiConfig& gui, std::string& error) {
    app::AppConfig out = base;
    auto& c = out.connection;
    c.callsign = trim(gui.callsign);
    c.source_id = gui.dmr_id;

    // Get-UiGatewayIdentityForSave
    const std::string number = trim(gui.device_number);
    const bool number_ok = number.size() == 2U && number[0] >= '0' && number[0] <= '9' && number[1] >= '0' && number[1] <= '9';
    if (gui.dmr_id == 0U) {
        c.gateway_id = 0U;
    } else if (number_ok) {
        c.gateway_id = gui.dmr_id * 100U + static_cast<std::uint32_t>((number[0] - '0') * 10 + (number[1] - '0'));
    } else if (!number.empty()) {
        error = "请填写两位设备编号（00–99），再保存本机 DMR ID。";
        return std::nullopt;
    } else if (gui.dmr_id != base.connection.source_id || gui.gateway_id == 0U) {
        error = "请填写两位设备编号（00–99），再保存本机 DMR ID。";
        return std::nullopt;
    } else {
        c.gateway_id = gui.gateway_id; // 编号为空且 DMR ID 未改：沿用原 gateway_id（legacy）
    }

    // New-BmServerSelectionValues
    std::string server_error;
    const auto server = app::bm_servers::new_selection_values(gui.master_preset, trim(gui.master_host), gui.master_port,
                                                              &server_error);
    if (!server) {
        error = server_error;
        return std::nullopt;
    }
    c.master = server->master;
    c.master_port = server->master_port;
    out.ui.bm_server_selection_id = server->selection_id;
    c.password = gui.bm_password;
    c.api_key = trim(gui.bm_api_key);

    auto& d = out.devices;
    d.hri_port = upper_ascii(to_selector(gui.hri_port));
    if (d.hri_port == "AUTO") d.hri_port = "auto";
    d.cat_port = upper_ascii(to_selector(gui.cat_port));
    if (d.cat_port == "AUTO") d.cat_port = "auto";
    d.cat_baud_rate = gui.cat_baud_rate;
    d.cat_stop_bits = "Two";
    d.wave_in_endpoint_id = to_selector(gui.wave_in_endpoint_id);
    d.wave_out_endpoint_id = to_selector(gui.wave_out_endpoint_id);

    // 增益：只有档位变化时才改写，避免把 1.5× 之类的 PS 值舍入成整数档。
    if (gain_step(base.audio.radio_playback_gain_milli) != gui.playback_gain_step) {
        out.audio.radio_playback_gain_milli = std::clamp<std::uint32_t>(gui.playback_gain_step, 1U, 16U) * 1000U;
    }
    if (gain_step(base.audio.mic_transmit_gain_milli) != gui.transmit_gain_step) {
        out.audio.mic_transmit_gain_milli = std::clamp<std::uint32_t>(gui.transmit_gain_step, 1U, 16U) * 1000U;
    }

    out.channels.clear();
    for (const auto& e : gui.channels) {
        app::ChannelConfig ch;
        ch.id = e.id;
        ch.kind = e.kind == CallKind::group ? app::ChannelKind::group : app::ChannelKind::private_call;
        ch.slot = static_cast<std::uint8_t>(e.slot);
        // New-UiChannelRecord：名称为空时用内置名称，否则用 ID 文本。
        ch.name = trim(e.name);
        if (ch.name.empty()) ch.name = known_channel_name(e.id, e.kind);
        if (ch.name.empty()) ch.name = std::to_string(e.id);
        out.channels.push_back(std::move(ch));
    }
    out.tx_channel_id.clear();
    if (gui.tx_target) {
        const auto key = channel_key(gui.tx_target->destination_id, gui.tx_target->kind, gui.tx_target->slot);
        for (const auto& ch : out.channels) {
            if (ch.key() == key) out.tx_channel_id = key;
        }
    }
    if (out.tx_channel_id.empty() && !out.channels.empty()) out.tx_channel_id = out.channels.front().key();
    return out;
}

// ---------------------------------------------------------------- 路由策略

talkgroup_routing::RxPolicy make_rx_policy(const std::vector<services::ChannelEntry>& channels,
                                           const std::set<std::string>& muted_keys, std::uint32_t local_source_id,
                                           const std::vector<std::uint32_t>& blocked_source_ids) {
    talkgroup_routing::RxPolicy p;
    p.group_mode = talkgroup_routing::GroupMode::selected;
    p.private_mode = talkgroup_routing::PrivateMode::disabled;
    for (const auto& ch : channels) {
        if (muted_keys.count(channel_key(ch.id, ch.kind, ch.slot)) != 0U) continue;
        if (ch.kind == CallKind::group) {
            const talkgroup_routing::GroupRoute route{ch.id, ch.slot};
            if (std::find(p.allowed_groups.begin(), p.allowed_groups.end(), route) == p.allowed_groups.end()) {
                p.allowed_groups.push_back(route);
            }
        } else {
            const talkgroup_routing::PrivatePeerRoute route{ch.id, local_source_id, ch.slot};
            if (std::find(p.private_peers.begin(), p.private_peers.end(), route) == p.private_peers.end()) {
                p.private_peers.push_back(route);
            }
        }
    }
    if (!p.private_peers.empty()) p.private_mode = talkgroup_routing::PrivateMode::selected_peers;
    for (const auto id : blocked_source_ids) {
        if (id != 0U && std::find(p.blocked_source_ids.begin(), p.blocked_source_ids.end(), id) == p.blocked_source_ids.end()) {
            p.blocked_source_ids.push_back(id);
        }
    }
    return p;
}

// ---------------------------------------------------------------- 启动参数

std::vector<std::filesystem::path> body_file_candidates(const std::filesystem::path& exe_directory) {
    return {exe_directory / L"private" / L"device-y.bin", exe_directory / L"runtime" / L"private" / L"device-y.bin"};
}

std::optional<std::string> select_hri_port(const app::devices::SerialCatalog& catalog, const std::string& requested,
                                           std::string& error) {
    if (catalog.serial_ports.empty()) {
        error = "当前没有枚举到 Windows COM 端口。";
        return std::nullopt;
    }
    if (catalog.hri_ports.empty()) {
        error = "当前枚举的串口中没有可确认的 HRI 设备。";
        return std::nullopt;
    }
    const std::string wanted = upper_ascii(trim(requested));
    if (!wanted.empty() && wanted != "AUTO") {
        const bool present = is_com_name(wanted) &&
                             std::count_if(catalog.serial_ports.begin(), catalog.serial_ports.end(),
                                           [&](const auto& p) { return upper_ascii(p.port_name) == wanted; }) == 1;
        if (!present) {
            error = "所选串口 " + wanted + " 当前没有枚举到。";
            return std::nullopt;
        }
        if (std::count_if(catalog.hri_ports.begin(), catalog.hri_ports.end(),
                          [&](const auto& p) { return upper_ascii(p.port_name) == wanted; }) != 1) {
            error = "连接配置指定的 " + wanted + " 未匹配到唯一 HRI 设备。";
            return std::nullopt;
        }
        return wanted;
    }
    if (catalog.hri_ports.size() == 1U) return upper_ascii(catalog.hri_ports.front().port_name);
    error = "HRI COM 端口无法唯一自动确定；请在设置中指定串口或检查 HRI 设备。";
    return std::nullopt;
}

std::optional<engine::StartConfig> make_start_config(const services::GuiConfig& gui, const StartInputs& inputs,
                                                     std::string& error) {
    // ConvertFrom-UiPortableConfigToProfile：没有频道或 TX 目标时不生成连接配置。
    if (gui.channels.empty()) {
        error = "频道列表为空；请先在“日常控制”中加入监听频道。";
        return std::nullopt;
    }
    talkgroup_routing::TxTarget target{gui.channels.front().id, gui.channels.front().kind, gui.channels.front().slot};
    if (gui.tx_target) {
        const auto& t = *gui.tx_target;
        const bool listed = std::any_of(gui.channels.begin(), gui.channels.end(), [&](const auto& e) {
            return e.id == t.destination_id && e.kind == t.kind && e.slot == t.slot;
        });
        if (listed) target = t;
    }
    const std::string callsign = trim(gui.callsign);
    const std::uint32_t gateway = services::effective_gateway_id(gui);
    if (callsign.empty() || gui.dmr_id == 0U || gateway == 0U) {
        error = "请先在设置中填写呼号、DMR ID 和设备编号。";
        return std::nullopt;
    }
    // 与 native --profile-* 参数相同的校验（bm_connection_config::validate）。
    const bool profile_ok = bm_connection_config::validate(
        {callsign, gateway, gui.dmr_id, gui.master_host, gui.master_port, target.destination_id,
         static_cast<std::uint64_t>(target.slot), inputs.color_code, target.kind == CallKind::group ? "G" : "P"});
    if (!profile_ok) {
        error = "连接配置中的呼号、ID、服务器、端口、时隙或 Color Code 超出允许范围。";
        return std::nullopt;
    }

    const auto port = select_hri_port(inputs.serial, narrow(gui.hri_port), error);
    if (!port) return std::nullopt;

    const auto audio = app::devices::resolve_audio_endpoints(inputs.wave_inputs, inputs.wave_outputs,
                                                             to_selector(gui.wave_in_endpoint_id),
                                                             to_selector(gui.wave_out_endpoint_id), true);
    if (!audio.ok()) {
        error = audio.message;
        return std::nullopt;
    }
    if (!audio.input.endpoint_id || !audio.output.endpoint_id) {
        error = "本机 WinMM 未返回所选 WaveIn/WaveOut 的 endpoint ID；请检查 Windows 音频端点后重试。";
        return std::nullopt;
    }
    engine::StartConfig sc;
    sc.hri_port = widen(*port);
    sc.hri_body_file = inputs.body_file;
    sc.audio.wave_in_id = audio.input.id;
    sc.audio.wave_out_id = audio.output.id;
    sc.audio.expected_wave_in_endpoint_id = widen(*audio.input.endpoint_id);
    sc.audio.expected_wave_out_endpoint_id = widen(*audio.output.endpoint_id);
    sc.bm.master_host = gui.master_host;
    sc.bm.master_port = gui.master_port;
    sc.bm.profile.gateway_id = gateway;
    sc.bm.profile.callsign = callsign;
    bm::apply_network_metadata(sc.bm.profile);
    sc.bm.profile.color_code = inputs.color_code;
    sc.bm.profile.password = gui.bm_password;
    sc.bm_start_disconnected = true;
    sc.local_source_id = gui.dmr_id;
    sc.rx_policy = make_rx_policy(gui.channels, {}, gui.dmr_id, gui.blocked_source_ids);
    sc.tx_policy.target = target;
    sc.tx_policy.transmit_enabled = true;      // bridge-ui.ps1：-TransmitEnabled $true
    sc.tx_policy.dynamic_join_enabled = false; // native 路由默认（Quick Call 走独立发送路径）
    sc.radio_playback_gain_milli = std::clamp<std::uint32_t>(gui.playback_gain_step, 1U, 16U) * 1000U;
    sc.mic_transmit_gain_milli = std::clamp<std::uint32_t>(gui.transmit_gain_step, 1U, 16U) * 1000U;
    return sc;
}

} // namespace wirex::gui::config_bridge
