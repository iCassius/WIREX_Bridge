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
    if (s.empty()) return "auto";
    std::string auto_check = s;
    for (char& c : auto_check) if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
    return auto_check == "AUTO" ? "auto" : s;
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
    g.desired_power_watts = config.devices.desired_power_watts;
    g.hri_frequency_hz = config.devices.hri_frequency_hz;
    g.hri_mode = config.devices.hri_mode == "c4fm_dn" ? hri_y::LchMode::c4fm_dn : hri_y::LchMode::fm;
    g.playback_gain_step = gain_step(config.audio.radio_playback_gain_milli);
    g.transmit_gain_step = gain_step(config.audio.mic_transmit_gain_milli);
    for (const auto& ch : config.channels) {
        services::ChannelEntry e;
        e.id = ch.id;
        e.kind = ch.kind == app::ChannelKind::group ? CallKind::group : CallKind::private_call;
        e.slot = to_slot(ch.slot);
        e.name = ch.name;
        e.muted = ch.muted;
        e.disabled = ch.disabled;
        g.channels.push_back(std::move(e));
    }
    g.tx_target = parse_channel_key(config.tx_channel_id);
    g.blocked_source_ids = config.routing.blocked_source_ids;
    g.relay_enabled = config.relay.enabled;
    g.relay_fm_enabled = config.relay.fm_enabled;
    g.relay_y_template_ap = config.relay.y_template_ap;
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
    if (gui.desired_power_watts < 5U || gui.desired_power_watts > 50U) {
        error = "期望功率必须为 5–50 W。";
        return std::nullopt;
    }
    d.desired_power_watts = gui.desired_power_watts;
    const auto hz = gui.hri_frequency_hz;
    if (hz % 1000U != 0U || !((hz >= 144000000U && hz <= 148000000U) ||
                               (hz >= 430000000U && hz <= 440000000U)) ||
        (gui.hri_mode != hri_y::LchMode::fm && gui.hri_mode != hri_y::LchMode::c4fm_dn)) {
        error = "HRI 频率或调制模式无效。";
        return std::nullopt;
    }
    d.hri_frequency_hz = gui.hri_frequency_hz;
    d.hri_mode = gui.hri_mode == hri_y::LchMode::c4fm_dn ? "c4fm_dn" : "fm";

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
        ch.muted = e.muted;
        ch.disabled = e.disabled;
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
    out.relay.enabled = gui.relay_enabled;
    out.relay.fm_enabled = gui.relay_fm_enabled;
    out.relay.y_template_ap = gui.relay_y_template_ap;
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
        // 停用（disabled）的频道不在 RX 策略中；静音（muted）的仍收听，只在引擎侧静音输出。
        if (ch.disabled || muted_keys.count(channel_key(ch.id, ch.kind, ch.slot)) != 0U) continue;
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
        error = "当前没有识别到 HRI 串口；请检查连接并刷新设备列表。";
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
            error = "指定的串口 " + wanted + " 不是当前识别到的 HRI 端口；请检查选择。";
            return std::nullopt;
        }
        return wanted;
    }
    if (catalog.hri_ports.size() == 1U) return upper_ascii(catalog.hri_ports.front().port_name);
    error = "无法自动选择 HRI COM 端口；请在主界面选择串口或检查 HRI 连接。";
    return std::nullopt;
}

ActiveDeviceIds active_device_ids(const engine::Snapshot& snapshot, const services::CatState& cat) {
    ActiveDeviceIds active;
    if (snapshot.serial_open) active.hri_port = snapshot.hri_port;
    if (cat.connected) active.cat_port = cat.port;
    if (snapshot.wave_in_open) active.wave_in_endpoint_id = snapshot.wave_in_endpoint_id;
    if (snapshot.wave_out_open) active.wave_out_endpoint_id = snapshot.wave_out_endpoint_id;
    return active;
}

std::optional<engine::AudioEndpoints> resolve_local_playback_output(
    const services::GuiConfig& gui, const services::DeviceInventory& inventory, std::string& error) {
    error.clear();
    std::vector<app::devices::WaveDevice> outputs;
    outputs.reserve(inventory.wave_out.size());
    for (const auto& endpoint : inventory.wave_out) {
        app::devices::WaveDevice output;
        output.id = endpoint.wave_id;
        output.name = endpoint.usb_audio_auto_candidate ? "USB Audio" : endpoint.name;
        output.endpoint_id = narrow(endpoint.endpoint_id);
        output.pcm_48000_mono_s16_supported = true; // DeviceInventory includes only usable 48 kHz mono endpoints.
        outputs.push_back(std::move(output));
    }

    const auto resolved = app::devices::resolve_audio_output(outputs, to_selector(gui.wave_out_endpoint_id));
    if (!resolved.ok() || !resolved.output.endpoint_id) {
        error = resolved.message.empty() ? "WaveOut 输出设备没有唯一解析结果；请手动选择。" : resolved.message;
        return std::nullopt;
    }

    engine::AudioEndpoints audio;
    audio.wave_out_id = resolved.output.id;
    audio.expected_wave_out_endpoint_id = widen(*resolved.output.endpoint_id);
    return audio;
}

services::DeviceSelectionSnapshot resolve_device_selection(const services::GuiConfig& gui,
                                                             const services::DeviceInventory& inventory,
                                                             const ActiveDeviceIds& active) {
    using app::devices::PortSelectionError;
    using services::DeviceResolutionState;
    using services::DeviceSelectionSource;

    const auto is_auto = [](const std::wstring& value) {
        const std::string selector = upper_ascii(trim(narrow(value)));
        return selector.empty() || selector == "AUTO";
    };
    const auto missing_or_unavailable = [&]() {
        return inventory.serial_discovery_status == "failed" ||
                       inventory.serial_discovery_status == "unknown"
                   ? DeviceResolutionState::unavailable
                   : DeviceResolutionState::missing;
    };
    const auto normalized_port = [](const std::wstring& value) {
        return app::devices::normalize_port_name(narrow(value));
    };
    const auto serial_matches = [&](std::string_view port) {
        std::vector<const services::SerialPortInfo*> matches;
        for (const auto& info : inventory.serial_ports) {
            const auto normalized = app::devices::normalize_port_name(narrow(info.port));
            if (normalized && *normalized == port) matches.push_back(&info);
        }
        return matches;
    };

    services::DeviceSelectionSnapshot result;
    result.hri.source = is_auto(gui.hri_port) ? DeviceSelectionSource::automatic : DeviceSelectionSource::saved;
    result.cat.source = is_auto(gui.cat_port) ? DeviceSelectionSource::automatic : DeviceSelectionSource::saved;
    result.wave_in.source = is_auto(gui.wave_in_endpoint_id) ? DeviceSelectionSource::automatic : DeviceSelectionSource::saved;
    result.wave_out.source = is_auto(gui.wave_out_endpoint_id) ? DeviceSelectionSource::automatic : DeviceSelectionSource::saved;
    if (!is_auto(gui.hri_port)) result.hri.requested_id = gui.hri_port;
    if (!is_auto(gui.cat_port)) result.cat.requested_id = gui.cat_port;
    if (!is_auto(gui.wave_in_endpoint_id)) result.wave_in.requested_id = gui.wave_in_endpoint_id;
    if (!is_auto(gui.wave_out_endpoint_id)) result.wave_out.requested_id = gui.wave_out_endpoint_id;

    app::devices::SerialCatalog serial_catalog;
    serial_catalog.discovery_status = inventory.serial_discovery_status;
    for (const auto& info : inventory.serial_ports) {
        app::devices::SerialPort port;
        port.port_name = narrow(info.port);
        port.friendly_name = info.caption;
        port.is_hri = info.is_hri;
        port.is_cat_candidate = info.is_cat_candidate;
        port.cat_match_rank = info.cat_match_rank;
        port.cat_match_reason = info.cat_match_reason;
        port.confidence = info.is_hri ? "high" : (info.cat_match_rank > 0 ? "medium" : "unknown");
        serial_catalog.serial_ports.push_back(port);
        if (port.is_hri) serial_catalog.hri_ports.push_back(port);
        if (port.is_cat_candidate) serial_catalog.cat_ports.push_back(port);
    }

    const std::string hri_selector = to_selector(gui.hri_port);
    std::string hri_error;
    const auto selected_hri = select_hri_port(serial_catalog, hri_selector, hri_error);
    if (selected_hri) {
        const auto matches = serial_matches(*selected_hri);
        if (matches.size() == 1U) {
            result.hri.state = DeviceResolutionState::resolved;
            result.hri.resolved_id = widen(*selected_hri);
            result.hri.name = matches.front()->caption;
            result.hri.reason = is_auto(gui.hri_port)
                ? "自动选择 HRI 串口 " + *selected_hri + "。"
                : "沿用已保存且当前识别为 HRI 的串口。";
        } else {
            result.hri.state = DeviceResolutionState::ambiguous;
            result.hri.reason = "系统返回重复的 COM 记录；请刷新设备列表后手动选择 HRI 串口。";
        }
    } else if (serial_catalog.serial_ports.empty() || serial_catalog.hri_ports.empty()) {
        result.hri.state = missing_or_unavailable();
        result.hri.reason = result.hri.state == DeviceResolutionState::unavailable
            ? "Windows 串口目录读取失败；请刷新设备列表后重试。"
            : (serial_catalog.serial_ports.empty() ? "当前没有枚举到 Windows COM 端口。"
                                                   : "当前串口目录没有识别到 HRI 设备。");
    } else if (is_auto(gui.hri_port)) {
        result.hri.state = DeviceResolutionState::ambiguous;
            result.hri.reason = "发现多个 HRI 串口候选；请手动选择一个。";
    } else {
        const auto wanted = normalized_port(gui.hri_port);
        const auto matches = wanted ? serial_matches(*wanted) : std::vector<const services::SerialPortInfo*>{};
        if (matches.empty()) {
            result.hri.state = missing_or_unavailable();
            result.hri.reason = "已保存的 HRI 串口 " + narrow(gui.hri_port) + " 当前没有枚举到。";
        } else if (matches.size() != 1U) {
            result.hri.state = DeviceResolutionState::ambiguous;
            result.hri.reason = "系统返回重复的 HRI 串口记录；请手动选择一个。";
        } else {
            result.hri.state = DeviceResolutionState::conflict;
            result.hri.reason = "已保存的串口当前没有识别为 HRI。";
        }
    }

    {
        const std::string cat_selector = to_selector(gui.cat_port);
        const std::string manual_cat = is_auto(gui.cat_port) ? std::string{} : cat_selector;
        PortSelectionError selection_error{};
        const auto selection = app::devices::resolve_port_selection(serial_catalog, hri_selector, cat_selector,
                                                                      manual_cat, selection_error);
        if (selection_error != PortSelectionError::none || selection.cat_conflict) {
            result.cat.state = DeviceResolutionState::conflict;
            result.cat.reason = selection.cat_match_reason.empty()
                ? "CAT 串口选择无效或与 HRI 串口冲突。" : selection.cat_match_reason;
        } else if (selection.cat_port) {
            const auto matches = serial_matches(*selection.cat_port);
            if (matches.empty()) {
                result.cat.state = missing_or_unavailable();
                result.cat.reason = "选择的 CAT 串口 " + *selection.cat_port + " 当前没有枚举到。";
            } else if (matches.size() != 1U) {
                result.cat.state = DeviceResolutionState::ambiguous;
                result.cat.reason = "系统返回重复的 CAT 串口记录；请刷新设备列表后手动选择。";
            } else {
                result.cat.resolved_id = widen(*selection.cat_port);
                result.cat.name = matches.front()->caption;
                result.cat.source = selection.cat_port_source == "manual" ? DeviceSelectionSource::manual
                    : selection.cat_port_source == "saved" ? DeviceSelectionSource::saved
                                                            : DeviceSelectionSource::automatic;
                if (selection.cat_port_source == "manual" && matches.front()->cat_match_rank <= 0) {
                    result.cat.state = DeviceResolutionState::manual_unclassified;
                    result.cat.reason = "当前目录中未识别该端口的 CAT 身份；保留用户明确选择的 COM 口。";
                } else {
                    result.cat.state = DeviceResolutionState::resolved;
                    result.cat.reason = selection.cat_match_reason;
                }
            }
        } else {
            int best_rank = 0;
            std::size_t best_count = 0U;
            for (const auto& port : serial_catalog.cat_ports) {
                if (port.cat_match_rank <= 0) continue;
                if (selection.hri_port && port.port_name == *selection.hri_port) continue;
                if (port.cat_match_rank > best_rank) {
                    best_rank = port.cat_match_rank;
                    best_count = 1U;
                } else if (port.cat_match_rank == best_rank) {
                    ++best_count;
                }
            }
            if (best_rank > 0 && best_count > 1U) {
                result.cat.state = DeviceResolutionState::ambiguous;
                result.cat.reason = "发现多个同级 CAT 串口候选；为避免选错，请手动选择。";
            } else {
                result.cat.state = is_auto(gui.cat_port) ? missing_or_unavailable() : DeviceResolutionState::missing;
                result.cat.reason = result.cat.state == DeviceResolutionState::unavailable
                    ? "Windows 串口目录读取失败；请刷新设备列表后重试。"
                    : "未找到可自动选择的 CAT 串口；可手动选择当前枚举的非 HRI 端口。";
            }
        }
    }

    const auto make_wave_devices = [](const std::vector<services::AudioEndpointInfo>& endpoints) {
        std::vector<app::devices::WaveDevice> waves;
        waves.reserve(endpoints.size());
        for (const auto& endpoint : endpoints) {
            app::devices::WaveDevice wave;
            wave.id = endpoint.wave_id;
            // Candidate metadata was captured from the same WinMM name test used by
            // enumerate_audio(); keep the helper's auto decision identical to startup.
            wave.name = endpoint.usb_audio_auto_candidate ? "USB Audio" : endpoint.name;
            wave.endpoint_id = narrow(endpoint.endpoint_id);
            wave.pcm_48000_mono_s16_supported = true;
            waves.push_back(std::move(wave));
        }
        return waves;
    };
    const auto wave_inputs = make_wave_devices(inventory.wave_in);
    const auto wave_outputs = make_wave_devices(inventory.wave_out);
    const std::string wave_in_selector = to_selector(gui.wave_in_endpoint_id);
    const std::string wave_out_selector = to_selector(gui.wave_out_endpoint_id);
    const bool hri_identified = result.hri.state == DeviceResolutionState::resolved;
    const auto audio_selection = app::devices::resolve_audio_endpoints(
        wave_inputs, wave_outputs, wave_in_selector, wave_out_selector, hri_identified);
    const auto endpoint_matches = [](const std::vector<services::AudioEndpointInfo>& endpoints,
                                     std::string_view wanted) {
        std::vector<const services::AudioEndpointInfo*> matches;
        for (const auto& endpoint : endpoints) {
            if (upper_ascii(narrow(endpoint.endpoint_id)) == upper_ascii(std::string(wanted))) {
                matches.push_back(&endpoint);
            }
        }
        return matches;
    };
    const auto set_explicit_wave = [&](services::ResolvedDeviceSelection& selection,
                                       const std::vector<services::AudioEndpointInfo>& endpoints) {
        const auto matches = endpoint_matches(endpoints, narrow(selection.requested_id));
        if (matches.empty()) {
            selection.state = DeviceResolutionState::missing;
            selection.reason = "已保存的音频 endpoint 当前没有枚举到；配置已保留。";
        } else if (matches.size() != 1U) {
            selection.state = DeviceResolutionState::ambiguous;
            selection.reason = "系统返回重复的音频端点记录；请刷新设备列表或手动选择。";
        } else {
            selection.state = DeviceResolutionState::resolved;
            selection.resolved_id = matches.front()->endpoint_id;
            selection.name = matches.front()->name;
            selection.reason = "沿用当前枚举到的稳定音频 endpoint ID。";
        }
    };
    const bool input_auto = is_auto(gui.wave_in_endpoint_id);
    const bool output_auto = is_auto(gui.wave_out_endpoint_id);
    const auto set_auto_wave = [&](services::ResolvedDeviceSelection& selection,
                                   const std::vector<services::AudioEndpointInfo>& endpoints,
                                   const std::vector<services::AudioEndpointInfo>& opposite_endpoints,
                                   bool opposite_auto, const std::wstring& opposite_requested,
                                   const app::devices::WaveDevice& selected_by_helper, bool helper_selected) {
        if (helper_selected && selected_by_helper.endpoint_id) {
            const auto matches = endpoint_matches(endpoints, *selected_by_helper.endpoint_id);
            if (matches.size() == 1U) {
                selection.state = DeviceResolutionState::resolved;
                selection.resolved_id = matches.front()->endpoint_id;
                selection.name = matches.front()->name;
                selection.reason = "与启动配置相同的 USB Audio 自动选择结果。";
                return;
            }
        }
        const auto count = static_cast<std::size_t>(std::count_if(endpoints.begin(), endpoints.end(),
            [](const auto& endpoint) { return endpoint.usb_audio_auto_candidate; }));
        const auto opposite_count = static_cast<std::size_t>(std::count_if(opposite_endpoints.begin(), opposite_endpoints.end(),
            [](const auto& endpoint) { return endpoint.usb_audio_auto_candidate; }));
        if (count > 1U) {
            selection.state = DeviceResolutionState::ambiguous;
            selection.reason = "发现多个 USB Audio 候选；请手动选择。";
        } else if (count == 0U) {
            selection.state = DeviceResolutionState::missing;
            selection.reason = "当前没有 USB Audio 自动候选；请手动选择已枚举的端点。";
        } else if (!hri_identified) {
            selection.state = DeviceResolutionState::unavailable;
            selection.reason = "请先选择 HRI 串口，再使用 USB Audio 自动选择。";
        } else if (opposite_auto && opposite_count > 1U) {
            selection.state = DeviceResolutionState::ambiguous;
            selection.reason = "另一方向有多个 USB Audio 候选；请手动选择输入和输出设备。";
        } else if (!opposite_auto && endpoint_matches(opposite_endpoints, narrow(opposite_requested)).size() == 1U) {
            selection.state = DeviceResolutionState::conflict;
            selection.reason = "手动端点与唯一 USB Audio 配对不一致；请手动选择两个端点或恢复 Auto。";
        } else if (opposite_count == 0U) {
            selection.state = DeviceResolutionState::missing;
            selection.reason = "另一方向没有 USB Audio 自动候选；请手动选择输入和输出设备。";
        } else {
            selection.state = DeviceResolutionState::unavailable;
            selection.reason = "当前设备组合不能自动选择；请手动选择输入和输出设备。";
        }
    };
    if (!input_auto) {
        set_explicit_wave(result.wave_in, inventory.wave_in);
    } else {
        set_auto_wave(result.wave_in, inventory.wave_in, inventory.wave_out, output_auto,
                      gui.wave_out_endpoint_id, audio_selection.input, audio_selection.input.endpoint_id.has_value());
    }

    if (!output_auto) {
        set_explicit_wave(result.wave_out, inventory.wave_out);
    } else {
        std::string output_error;
        const auto local_output = resolve_local_playback_output(gui, inventory, output_error);
        if (local_output && !local_output->expected_wave_out_endpoint_id.empty()) {
            const auto matches = endpoint_matches(inventory.wave_out,
                narrow(local_output->expected_wave_out_endpoint_id));
            if (matches.size() == 1U) {
                result.wave_out.state = DeviceResolutionState::resolved;
                result.wave_out.resolved_id = matches.front()->endpoint_id;
                result.wave_out.name = matches.front()->name;
                result.wave_out.reason = "WaveOut 可独立选择；已按唯一 USB Audio 候选或唯一可用输出解析。";
            } else {
                result.wave_out.state = DeviceResolutionState::ambiguous;
                result.wave_out.reason = "WaveOut 自动解析结果未在当前设备目录中唯一匹配；请手动选择。";
            }
        } else {
            const auto has_output = std::any_of(inventory.wave_out.begin(), inventory.wave_out.end(),
                [](const services::AudioEndpointInfo& endpoint) { return !endpoint.endpoint_id.empty(); });
            result.wave_out.state = has_output ? DeviceResolutionState::ambiguous : DeviceResolutionState::missing;
            result.wave_out.reason = output_error.empty()
                ? "WaveOut 自动选择没有唯一结果；请手动选择。" : std::move(output_error);
        }
    }

    const auto apply_active_serial = [&](services::ResolvedDeviceSelection& selection, const std::wstring& active_port) {
        if (active_port.empty()) return;
        selection.active = true;
        selection.resolved_id = active_port;
        const auto wanted = app::devices::normalize_port_name(narrow(active_port));
        const auto matches = wanted ? serial_matches(*wanted) : std::vector<const services::SerialPortInfo*>{};
        if (matches.size() == 1U) {
            selection.state = DeviceResolutionState::resolved;
            selection.name = matches.front()->caption;
            selection.reason = "连接状态报告当前实际使用的串口。";
        } else {
            selection.state = DeviceResolutionState::active_not_enumerated;
            selection.name = narrow(active_port);
            selection.reason = "连接状态仍报告此串口，但最新设备目录没有唯一匹配项。";
        }
    };
    const auto apply_active_audio = [](services::ResolvedDeviceSelection& selection, const std::wstring& active_id,
                                       const std::vector<services::AudioEndpointInfo>& endpoints) {
        if (active_id.empty()) return;
        selection.active = true;
        selection.resolved_id = active_id;
        const std::string wanted = upper_ascii(narrow(active_id));
        std::vector<const services::AudioEndpointInfo*> matches;
        for (const auto& endpoint : endpoints) {
            if (upper_ascii(narrow(endpoint.endpoint_id)) == wanted) matches.push_back(&endpoint);
        }
        if (matches.size() == 1U) {
            selection.state = DeviceResolutionState::resolved;
            selection.name = matches.front()->name;
            selection.reason = "引擎状态报告当前实际使用的音频 endpoint。";
        } else {
            selection.state = DeviceResolutionState::active_not_enumerated;
            selection.name = narrow(active_id);
            selection.reason = "引擎仍报告此 endpoint，但最新设备目录没有唯一匹配项。";
        }
    };
    apply_active_serial(result.hri, active.hri_port);
    apply_active_serial(result.cat, active.cat_port);
    apply_active_audio(result.wave_in, active.wave_in_endpoint_id, inventory.wave_in);
    apply_active_audio(result.wave_out, active.wave_out_endpoint_id, inventory.wave_out);
    return result;
}

std::optional<engine::StartConfig> make_runtime_config(const services::GuiConfig& gui,
                                                       std::uint8_t color_code,
                                                       std::string& error) {
    error.clear();
    // runtime 先按保存配置创建；BM 字段缺失只会让 BM 命令失败，不阻止 radio 启动。
    const auto local_source_id = gui.dmr_id == 0U ? 1U : gui.dmr_id;
    talkgroup_routing::TxTarget target = gui.channels.empty()
        ? talkgroup_routing::TxTarget{1U, CallKind::group, dmr_call::Slot::ts1}
        : talkgroup_routing::TxTarget{gui.channels.front().id, gui.channels.front().kind, gui.channels.front().slot};
    if (gui.tx_target) {
        const auto& t = *gui.tx_target;
        const bool listed = std::any_of(gui.channels.begin(), gui.channels.end(), [&](const auto& e) {
            return e.id == t.destination_id && e.kind == t.kind && e.slot == t.slot;
        });
        if (listed) target = t;
    }
    const std::string callsign = trim(gui.callsign);
    const std::uint32_t gateway = services::effective_gateway_id(gui);
    engine::StartConfig sc;
    sc.start_radio = false;
    sc.radio_start_error.clear();
    sc.bm.master_host = gui.master_host;
    sc.bm.master_port = gui.master_port;
    sc.bm.profile.gateway_id = gateway;
    sc.bm.profile.callsign = callsign;
    bm::apply_network_metadata(sc.bm.profile);
    sc.bm.profile.color_code = color_code <= 15U ? color_code : 1U;
    sc.bm.profile.password = gui.bm_password;
    sc.bm_start_disconnected = true;
    sc.local_source_id = local_source_id;
    sc.rx_policy = make_rx_policy(gui.channels, {}, local_source_id, gui.blocked_source_ids);
    sc.tx_policy.target = target;
    sc.tx_policy.transmit_enabled = !gui.channels.empty();
    sc.tx_policy.dynamic_join_enabled = false; // native 路由默认（Quick Call 走独立发送路径）
    sc.radio_playback_gain_milli = std::clamp<std::uint32_t>(gui.playback_gain_step, 1U, 16U) * 1000U;
    sc.mic_transmit_gain_milli = std::clamp<std::uint32_t>(gui.transmit_gain_step, 1U, 16U) * 1000U;
    return sc;
}

std::optional<engine::StartConfig> make_start_config(const services::GuiConfig& gui, const StartInputs& inputs,
                                                     std::string& error) {
    auto runtime = make_runtime_config(gui, inputs.color_code, error);
    if (!runtime) return std::nullopt;
    // BM 登录字段无效时仍允许 HRI 单独连接；BM 连接命令会返回具体校验错误。
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
    runtime->hri_port = widen(*port);
    runtime->hri_body_file = inputs.body_file;
    runtime->audio.wave_in_id = audio.input.id;
    runtime->audio.wave_out_id = audio.output.id;
    runtime->audio.expected_wave_in_endpoint_id = widen(*audio.input.endpoint_id);
    runtime->audio.expected_wave_out_endpoint_id = widen(*audio.output.endpoint_id);
    runtime->start_radio = true;
    runtime->radio_start_error.clear();
    return runtime;
}

} // namespace wirex::gui::config_bridge
