#pragma once

// GUI 依赖的外部服务占位接口（R128）。CAT、配置、设备枚举和 BM API 由其它模块用 C++ 实现，
// 这里只约定 GUI 需要的最小形状，便于之后接线：
// - 同步函数（state/enumerate/load/save）在 UI 线程调用，必须快速返回（读缓存，不做串口/网络 I/O）；
// - 异步函数通过 Done/回调返回结果，回调可在任意线程调用，ViewModel 负责切回 UI 线程；
// - 未接线的 std::function 为空，ViewModel 把对应功能显示为“未就绪”，不会调用空函数。

#include "wirex/engine.hpp"

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace wirex::gui::services {

using Done = std::function<void(engine::CommandResult)>;

// ---------- 设备枚举 ----------

struct SerialPortInfo {
    std::wstring port{};       // "COM5"
    std::string caption{};     // UTF-8 显示文本，例如 "COM5 · Silicon Labs CP210x"
    bool is_hri{};
    bool is_cat_candidate{};
    int cat_match_rank{};
    std::string cat_match_reason{};
};

struct AudioEndpointInfo {
    std::wstring endpoint_id{}; // MMDevice endpoint id
    std::string name{};         // UTF-8 友好名称
    std::uint32_t wave_id{};    // 当前枚举对应的 WinMM 设备编号
    bool usb_audio_auto_candidate{}; // 依照 WinMM 设备名参与 USB Audio 自动配对
};

struct DeviceInventory {
    std::string serial_discovery_status{"unknown"}; // ready | empty | failed | synthetic
    std::vector<SerialPortInfo> serial_ports{};
    std::vector<AudioEndpointInfo> wave_in{};
    std::vector<AudioEndpointInfo> wave_out{};
};

enum class DeviceResolutionState : std::uint8_t {
    resolved,
    ambiguous,
    missing,
    conflict,
    unavailable,
    manual_unclassified,
    active_not_enumerated,
};

enum class DeviceSelectionSource : std::uint8_t { automatic, saved, manual };

struct ResolvedDeviceSelection {
    DeviceResolutionState state{DeviceResolutionState::unavailable};
    DeviceSelectionSource source{DeviceSelectionSource::automatic};
    std::wstring requested_id{}; // empty = Auto；保留配置选择，不随解析结果改写
    std::wstring resolved_id{};  // 当前解析或运行状态报告的 COM / endpoint ID
    std::string name{};          // 当前目录中的友好名称；无法匹配时可回退为 ID
    std::string reason{};        // UTF-8 中文原因
    bool active{};               // true 表示引擎或 CAT 状态报告正在使用此 ID
};

struct DeviceSelectionSnapshot {
    ResolvedDeviceSelection hri{};
    ResolvedDeviceSelection cat{};
    ResolvedDeviceSelection wave_in{};
    ResolvedDeviceSelection wave_out{};
};

struct DeviceService {
    std::function<DeviceInventory()> enumerate{};
};

// ---------- CAT（FTX-1 MAIN 侧） ----------

enum class CatMode : std::uint8_t { fm, fm_n, c4fm_dn, c4fm_vw };

struct CatSettings {
    CatMode main_mode{CatMode::fm};
    std::uint64_t main_frequency_hz{};
    std::uint32_t power_w{};
};

struct CatState {
    bool connected{};
    bool busy{};                                // 连接/读取/写入进行中
    std::wstring port{};
    std::uint32_t baud_rate{38400U};
    std::optional<CatMode> observed_mode{};     // 最近一次读取值
    std::optional<std::uint64_t> observed_frequency_hz{};
    std::optional<std::uint32_t> observed_power_w{};
    std::uint64_t observed_revision{};          // 可信新读回递增；与连接/busy/error 的 revision 分开
    std::string error{};                        // 中文源文案；空表示无错误
    std::uint64_t revision{};                   // 每次变化 +1
};

struct CatService {
    std::function<CatState()> state{};
    std::function<void(std::wstring port, std::uint32_t baud_rate, Done done)> connect{};
    std::function<void(Done done)> disconnect{};
    std::function<void(CatSettings settings, Done done)> apply{};
};

// ---------- 便携配置 ----------

struct ChannelEntry {
    std::uint32_t id{};
    dmr_call::CallKind kind{dmr_call::CallKind::group};
    dmr_call::Slot slot{dmr_call::Slot::ts1};
    std::string name{};                         // 可空，UTF-8
};

struct GuiConfig {
    std::string ui_language{"zh-CN"};           // zh-CN / en-US；未知值回落至简体中文
    std::string callsign{};
    std::uint32_t dmr_id{};                     // connection.source_id
    std::string device_number{};                // "00".."99" 或空（空：沿用 gateway_id）
    std::uint32_t gateway_id{};                 // 读取时的 connection.gateway_id；保存时见 effective_gateway_id()
    std::string master_preset{"bm-china-4602"}; // ui.bm_server_selection_id：目录中的 id 或 "custom"
    std::string master_host{"43.129.83.124"};
    std::uint16_t master_port{62031U};
    std::string bm_password{};
    std::string bm_api_key{};
    std::wstring hri_port{};                    // 空 = "auto"
    std::wstring cat_port{};                    // 空 = "auto"
    std::uint32_t cat_baud_rate{38400U};
    std::wstring wave_in_endpoint_id{};         // 空 = "auto"
    std::wstring wave_out_endpoint_id{};
    std::uint32_t playback_gain_step{1U};       // 1..16，对应 1000..16000 milli
    std::uint32_t transmit_gain_step{16U};
    std::vector<ChannelEntry> channels{};
    std::optional<talkgroup_routing::TxTarget> tx_target{};
    std::vector<std::uint32_t> blocked_source_ids{};  // routing.blocked_source_ids（只读透传）
};

// BM 设备 ID（Hotspot ID）：两位设备编号时为 DMR ID×100+编号，否则沿用已保存的 gateway_id。
// 对应 bridge-ui.ps1 Get-UiGatewayIdentityForSave。
[[nodiscard]] inline std::uint32_t effective_gateway_id(const GuiConfig& c) noexcept {
    const auto& n = c.device_number;
    if (c.dmr_id != 0U && n.size() == 2U && n[0] >= '0' && n[0] <= '9' && n[1] >= '0' && n[1] <= '9') {
        return c.dmr_id * 100U + static_cast<std::uint32_t>((n[0] - '0') * 10 + (n[1] - '0'));
    }
    return c.gateway_id;
}

struct ConfigService {
    std::function<std::optional<GuiConfig>(std::string& error)> load{};
    std::function<bool(const GuiConfig& config, std::string& error)> save{};
    // 由配置生成引擎启动参数（解析串口与 endpoint ID → WinMM 编号）。
    // 在 UI 线程调用；会做一次设备枚举（约百毫秒级）。
    std::function<std::optional<engine::StartConfig>(const GuiConfig& config, std::string& error)> make_start_config{};
    // 仅构造常驻 BM/路由 runtime 参数，不要求当前存在可用 HRI 串口或 USB Audio。
    std::function<std::optional<engine::StartConfig>(const GuiConfig& config, std::string& error)> make_runtime_config{};
};

// ---------- BrandMeister API（静态组） ----------

struct StaticGroup {
    std::uint32_t talkgroup{};
    int slot{};                                 // API slot：0 = DMO/simplex，1，2
};

struct BmApiResult {
    bool failed{};                              // true：message 为错误文案
    bool groups_valid{};                        // groups 是本次（或写入回读）得到的完整列表
    std::vector<StaticGroup> groups{};
    std::optional<int> add_slot{};              // 仅 list：设备状态 4 → 0，0..3 → 2；未知时为空（添加禁用）
    std::optional<std::int64_t> device_status{};
    std::string message{};                      // 中文源文案；不含 API Key
};

using BmApiDone = std::function<void(BmApiResult result)>;

struct BmApiService {
    // 依次 GET /talkgroup 与 GET /device（取添加时隙）。
    std::function<void(std::uint32_t device_id, std::string api_key, BmApiDone done)> list_static_groups{};
    std::function<void(std::uint32_t device_id, std::string api_key, std::uint32_t talkgroup, int slot, BmApiDone done)> add_static_group{};
    std::function<void(std::uint32_t device_id, std::string api_key, std::uint32_t talkgroup, int slot, BmApiDone done)> remove_static_group{};
};

// ---------- RadioID 呼号查询 ----------

struct IdentityResult {
    std::uint32_t source_id{};
    bool known{};                               // true：found（callsign 有值）或 not_found（callsign 为空）
    std::optional<std::string> callsign{};      // 已规范化，可直接写入引擎身份缓存
};

using IdentityDone = std::function<void(IdentityResult result)>;

struct IdentityService {
    // 只读本地缓存中新鲜且合规的 found 条目（启动时预载到引擎，最多 128 条）。UI 线程调用。
    std::function<std::vector<IdentityResult>()> preload{};
    // 先查缓存；未命中时排队联网查询（节流、失败冷却由服务负责）。done 只在得到确定结果时调用。
    std::function<void(std::uint32_t source_id, IdentityDone done)> lookup{};
};

struct Services {
    DeviceService devices{};
    CatService cat{};
    ConfigService config{};
    BmApiService bm_api{};
    IdentityService identity{};
    // 后台状态（例如 CAT 轮询读数）变化时调用的唤醒函数；ViewModel::set_wakeup 转发。
    std::function<void(std::function<void()> wakeup)> set_wakeup{};
    // 停止后台线程并等待结束；之后不会再调用任何回调。ViewModel 析构时调用。
    std::function<void()> shutdown{};
};

} // namespace wirex::gui::services
