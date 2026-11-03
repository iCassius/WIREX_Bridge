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
};

struct AudioEndpointInfo {
    std::wstring endpoint_id{}; // MMDevice endpoint id
    std::string name{};         // UTF-8 友好名称
};

struct DeviceInventory {
    std::vector<SerialPortInfo> serial_ports{};
    std::vector<AudioEndpointInfo> wave_in{};
    std::vector<AudioEndpointInfo> wave_out{};
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
    std::string ui_language{"zh-CN"};           // 运行界面固定中文；保留字段供以后启用切换
    std::string callsign{};
    std::uint32_t dmr_id{};
    std::string device_number{};                // "00".."99" 或空
    std::string master_preset{"bm-china-4602"}; // "bm-china-4602" | "custom"
    std::string master_host{"43.129.83.124"};
    std::uint16_t master_port{62031U};
    std::string bm_password{};
    std::string bm_api_key{};
    std::wstring hri_port{};
    std::wstring cat_port{};
    std::uint32_t cat_baud_rate{38400U};
    std::wstring wave_in_endpoint_id{};
    std::wstring wave_out_endpoint_id{};
    std::uint32_t playback_gain_step{1U};       // 1..16，对应 1000..16000 milli
    std::uint32_t transmit_gain_step{16U};
    std::vector<ChannelEntry> channels{};
    std::optional<talkgroup_routing::TxTarget> tx_target{};
};

struct ConfigService {
    std::function<std::optional<GuiConfig>(std::string& error)> load{};
    std::function<bool(const GuiConfig& config, std::string& error)> save{};
    // 由配置生成引擎启动参数（解析 endpoint id → WinMM 编号、device-y.bin 路径等）。
    std::function<std::optional<engine::StartConfig>(const GuiConfig& config, std::string& error)> make_start_config{};
};

// ---------- BrandMeister API（静态组） ----------

using StaticGroupsDone = std::function<void(std::optional<std::vector<std::uint32_t>> groups, std::string error)>;

struct BmApiService {
    std::function<void(std::uint32_t device_id, std::string api_key, StaticGroupsDone done)> list_static_groups{};
    std::function<void(std::uint32_t device_id, std::string api_key, std::uint32_t talkgroup, StaticGroupsDone done)> add_static_group{};
    std::function<void(std::uint32_t device_id, std::string api_key, std::uint32_t talkgroup, StaticGroupsDone done)> remove_static_group{};
};

struct Services {
    DeviceService devices{};
    CatService cat{};
    ConfigService config{};
    BmApiService bm_api{};
};

} // namespace wirex::gui::services
