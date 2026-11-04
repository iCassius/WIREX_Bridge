#pragma once

// config.json（app::AppConfig）↔ GUI 配置（services::GuiConfig）↔ 引擎启动参数（engine::StartConfig）的纯函数转换。
// 规则逐条对照 PowerShell 版：
// - 读取/保存：ui/windows/bridge-ui.ps1 Apply-UiPortableConfigToControls / Save-SettingsFromWindow /
//   Set-UiGatewayIdentityState / Get-UiGatewayIdentityForSave；
// - 启动参数：ConvertFrom-UiPortableConfigToProfile + Get-UiNativeRxPolicyForChannels（bridge-ui.ps1）、
//   tools/start-bm-radio-bridge.ps1 -PrepareOnly（Read-PortSelection -RequireHri -NoInteractive、
//   Get-CompatibleAutoAudioPair、Test-ApprovedBody、Get-ProfileConnectionArgs、New-RoutingStateDocument）。
// 文件/设备 I/O 不在这里做：调用方枚举设备；空 body_file 使用源码内置的已批准 HRI Y 模板。

#include "services.hpp"

#include "wirex/app/config.hpp"
#include "wirex/app/devices.hpp"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace wirex::gui::config_bridge {

// ---------- config.json ↔ GuiConfig ----------

[[nodiscard]] services::GuiConfig to_gui(const app::AppConfig& config);

// 把 GUI 字段写回 base（保留 base.document 中的未知字段与 GUI 不管理的字段：color_code、cat_stop_bits、
// desired_power_watts、window、legacy_rx_policy 等）。失败时返回 nullopt 并写中文原因（不含密码/Key）。
[[nodiscard]] std::optional<app::AppConfig> apply_gui(const app::AppConfig& base, const services::GuiConfig& gui,
                                                      std::string& error);

// Set-UiGatewayIdentityState：由已保存的 source_id/gateway_id 反推两位设备编号。
[[nodiscard]] std::string device_number_for(std::uint32_t source_id, std::uint32_t gateway_id);

// Get-UiKnownChannelName（中文源文案）。
[[nodiscard]] std::string known_channel_name(std::uint32_t id, dmr_call::CallKind kind);

// "group:46001:2" ↔ TxTarget
[[nodiscard]] std::string channel_key(std::uint32_t id, dmr_call::CallKind kind, dmr_call::Slot slot);
[[nodiscard]] std::optional<talkgroup_routing::TxTarget> parse_channel_key(const std::string& key);

// ---------- 路由策略 ----------

// Get-UiNativeRxPolicyForChannels：未屏蔽的组呼 → allowed_groups；未屏蔽的单呼 → private_peers（本机 = local_source_id）；
// 有单呼时 private_mode=selected_peers 否则 disabled；blocked_groups 恒为空（屏蔽 = 从 allowed 中移除）；
// blocked_source_ids 取 routing.blocked_source_ids。
[[nodiscard]] talkgroup_routing::RxPolicy make_rx_policy(const std::vector<services::ChannelEntry>& channels,
                                                         const std::set<std::string>& muted_keys,
                                                         std::uint32_t local_source_id,
                                                         const std::vector<std::uint32_t>& blocked_source_ids);

// ---------- 启动参数 ----------

inline constexpr std::uintmax_t approved_body_length = 100U;
inline constexpr const char* approved_body_sha256 = "82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f";

// device-y.bin 候选位置（新 ZIP 布局在前）：<exe>/private/device-y.bin，<exe>/runtime/private/device-y.bin。
[[nodiscard]] std::vector<std::filesystem::path> body_file_candidates(const std::filesystem::path& exe_directory);

// Read-PortSelection -RequireHri -NoInteractive：显式端口必须当前存在且是唯一 HRI；"auto" 时取唯一 HRI。
[[nodiscard]] std::optional<std::string> select_hri_port(const app::devices::SerialCatalog& catalog,
                                                         const std::string& requested, std::string& error);

struct StartInputs {
    std::uint8_t color_code{1U};                          // connection.color_code（GUI 不编辑）
    app::devices::SerialCatalog serial{};
    std::vector<app::devices::WaveDevice> wave_inputs{};
    std::vector<app::devices::WaveDevice> wave_outputs{};
    std::filesystem::path body_file{};                    // 可选外部覆盖；留空使用内置模板
};

[[nodiscard]] std::optional<engine::StartConfig> make_start_config(const services::GuiConfig& gui,
                                                                    const StartInputs& inputs, std::string& error);

} // namespace wirex::gui::config_bridge
