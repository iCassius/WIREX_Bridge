#pragma once

#include "wirex/app/json.hpp"
#include "wirex/app/result.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

// Portable config.json (schema v1). Field set, defaults, validation order and
// Chinese messages mirror ui/windows/PortableConfig.psm1 so either
// implementation can read what the other wrote.
namespace wirex::app {

inline constexpr std::size_t config_max_bytes = 131072U;
inline constexpr std::size_t config_max_channels = 256U;
inline constexpr std::uint32_t gain_min_milli = 250U;
inline constexpr std::uint32_t gain_max_milli = 16000U;

enum class ConfigErrorCode : std::uint8_t {
    file_not_found,       // load(): nothing at path (caller may fall back to default_config())
    directory_missing,
    io_error,
    too_large,
    invalid_json,
    duplicate_key,
    escaped_key,
    missing_required_field,  // stored shape: root key absent
    incomplete_section,      // stored shape: section not an object or nested key absent
    not_object,
    unsupported_version,
    invalid_value,           // PS "数值无效" / wrong JSON type
    out_of_range,            // PS "超出允许范围"
    invalid_format,          // PS "字段格式无效" and other format rules
    duplicate_entry,
    credential_path_field,
};

struct ConfigError {
    ConfigErrorCode code{ConfigErrorCode::io_error};
    std::string field{};    // dotted path, e.g. "devices.cat_port"; empty for file-level errors
    std::string message{};  // UTF-8 Chinese text; never contains config values
};

template <class T>
using ConfigResult = Result<T, ConfigError>;

struct ConnectionConfig {
    std::string callsign{};
    std::uint32_t gateway_id{0};
    std::uint32_t source_id{0};
    std::string master{"43.129.83.124"};
    std::uint16_t master_port{62031};
    std::uint8_t color_code{1};
    std::string password{};
    std::string api_key{};
};

struct DevicesConfig {
    // devices.serial_port is a legacy alias that is always written equal to hri_port.
    std::string hri_port{"auto"};
    std::string cat_port{"auto"};
    std::uint32_t cat_baud_rate{38400};
    std::string cat_stop_bits{"Two"};
    std::string wave_in_endpoint_id{"auto"};
    std::string wave_out_endpoint_id{"auto"};
    std::uint32_t desired_power_watts{25};
};

struct AudioConfig {
    std::uint32_t radio_playback_gain_milli{1000};
    std::uint32_t mic_transmit_gain_milli{16000};
};

enum class ChannelKind : std::uint8_t { group, private_call };

struct ChannelConfig {
    std::uint32_t id{};
    ChannelKind kind{ChannelKind::private_call};
    std::uint8_t slot{};
    std::string name{};
    // R131 optional per-channel flags ("muted"/"disabled"); absent means false.
    bool muted{};
    bool disabled{};

    // Tuple key "kind:id:slot", e.g. "private:460997:2".
    [[nodiscard]] std::string key() const;
};

struct RoutingConfig {
    std::vector<std::uint32_t> blocked_source_ids{};
};

struct UiConfig {
    std::string bm_server_selection_id{"bm-china-4602"};
    json::Value legacy_rx_policy{};  // null or object, kept opaque
    std::string language{"zh-CN"};   // "zh-CN" or "en-US"
};

// Optional root section "relay" (R130, native only; PortableConfig.psm1 keeps it
// as an unknown section). Absent section or absent member = false. When present,
// the section must be an object and each known member a JSON boolean; other
// members are preserved verbatim. save() writes the section only when the file
// already has it or a flag is true, so default files stay byte-identical to PS.
struct RelayConfig {
    bool enabled{false};     // relay.enabled：中继总开关（AP PC 模式 Y 模板）
    bool fm_enabled{false};  // relay.fm_enabled：FM 中继（CAT 静噪触发；官方未支持）
};

struct AppConfig {
    ConnectionConfig connection{};
    DevicesConfig devices{};
    AudioConfig audio{};
    std::vector<ChannelConfig> channels{};
    std::string tx_channel_id{};
    RoutingConfig routing{};
    UiConfig ui{};
    RelayConfig relay{};
    json::Value window{json::Value::object()};

    // Full normalized document the typed fields were read from. Unknown members
    // (root sections such as "future_extension", per-section and per-channel
    // extras) live only here and are written back by save().
    json::Value document{};
};

struct SaveOptions {
    // Write ui.language even when the existing file does not store it
    // (mirrors Save-WirexPortableConfig -PersistUiLanguage).
    bool persist_ui_language{false};
};

// In-memory defaults (one channel private:460997:2), identical to
// New-WirexPortableConfigDefaults after validation.
[[nodiscard]] AppConfig default_config();

// Reads and validates config.json: 128 KiB cap, strict UTF-8 JSON, duplicate
// and escaped keys rejected, stored shape checked, then merged over defaults.
// Returns ConfigErrorCode::file_not_found when the file does not exist.
[[nodiscard]] ConfigResult<AppConfig> load(const std::filesystem::path& path);

// Validates an in-memory document (same rules as load() after the stored-shape
// check). Exposed for tests and for callers holding JSON text already.
[[nodiscard]] ConfigResult<AppConfig> from_document(const json::Value& document);
[[nodiscard]] ConfigResult<AppConfig> parse_text(std::string_view json_text);

// Typed fields applied over config.document (or the default document when empty).
[[nodiscard]] json::Value to_document(const AppConfig& config);

// Merge over the current file (which must itself be valid), validate, then
// write a temp file and ReplaceFileW it into place. The original file is left
// untouched on any failure. Returns the config as written.
[[nodiscard]] ConfigResult<AppConfig> save(const std::filesystem::path& path, const AppConfig& config,
    SaveOptions options = {});

// Writes only ui.language into the raw stored document (Set-WirexPortableConfigLanguage).
[[nodiscard]] ConfigResult<AppConfig> set_language(const std::filesystem::path& path, std::string_view language);

// First-start generation (Initialize-PortableConfig): if path exists it is only
// validated, never rewritten; otherwise defaults are written atomically without
// replacing a file created concurrently.
[[nodiscard]] ConfigResult<AppConfig> create_default(const std::filesystem::path& path);

// PowerShell-compatible bytes for a document: ConvertTo-Json layout plus "\n".
[[nodiscard]] std::string serialize_config(const json::Value& document);

[[nodiscard]] std::string format_gain_milli(std::uint32_t milli);
[[nodiscard]] std::string channel_kind_name(ChannelKind kind);

} // namespace wirex::app
