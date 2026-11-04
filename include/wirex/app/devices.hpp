#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// Serial port and audio endpoint discovery for the native app, plus the pure
// FTX-1 "auto" selection rules from ui/windows/RadioDevices.psm1,
// ui/windows/bridge-ui.ps1 and tools/start-bm-radio-bridge.ps1.
// All strings are UTF-8.
namespace wirex::app::devices {

// ---------------------------------------------------------------------------
// Serial ports

enum class SourceStatus : std::uint8_t { not_requested, ready, unavailable, error, synthetic };

// One raw observation of a port (registry value or SetupAPI device node).
struct SerialPortRecord {
    std::string port_name{};      // any spelling accepted by normalize_port_name
    std::string friendly_name{};  // SPDRP_FRIENDLYNAME
    std::string instance_id{};    // device instance ID
    std::vector<std::string> hardware_ids{};
    std::string source{};         // "registry", "setupapi", "input", ...
};

struct SerialPort {
    std::string port_name{};  // canonical "COMn"
    std::string friendly_name{};
    std::string instance_id{};
    std::vector<std::string> hardware_ids{};
    std::vector<std::string> sources{};
    bool is_hri{};
    bool is_cat_candidate{};
    int cat_match_rank{};
    std::string cat_match_reason{};
    std::string confidence{};  // "high" | "medium" | "unknown"
};

struct SerialCatalog {
    std::string discovery_status{};  // "ready" | "empty" | "failed" | "synthetic"
    SourceStatus registry_status{SourceStatus::not_requested};
    SourceStatus setupapi_status{SourceStatus::not_requested};
    std::vector<SerialPort> serial_ports{};  // sorted by COM number
    std::vector<SerialPort> hri_ports{};
    std::vector<SerialPort> cat_ports{};
    [[nodiscard]] bool serial_ready() const noexcept { return !serial_ports.empty(); }
};

// ConvertTo-RadioPortName: strips "\\.\", accepts "COM0007" or "... (COM7)",
// returns "COM7"; nullopt when no COM name is present.
[[nodiscard]] std::optional<std::string> normalize_port_name(std::string_view text);

// Get-RadioDeviceCatalog merge/classification over arbitrary records (pure).
[[nodiscard]] SerialCatalog build_serial_catalog(const std::vector<SerialPortRecord>& records, bool synthetic,
    SourceStatus registry_status = SourceStatus::synthetic, SourceStatus setupapi_status = SourceStatus::synthetic);

// HKLM\HARDWARE\DEVICEMAP\SERIALCOMM values.
[[nodiscard]] std::vector<SerialPortRecord> read_serialcomm_registry(SourceStatus& status);
// Present GUID_DEVCLASS_PORTS devices: friendly name, instance ID, hardware IDs, PortName.
[[nodiscard]] std::vector<SerialPortRecord> read_setupapi_ports(SourceStatus& status);
// Registry + SetupAPI, merged and classified.
[[nodiscard]] SerialCatalog enumerate_serial_ports();

struct PortSelection {
    std::optional<std::string> hri_port{};
    std::optional<std::string> cat_port{};
    std::string hri_match_reason{};
    std::string cat_match_reason{};
    std::string cat_port_source{};  // "", "manual", "saved", "matched"
    bool cat_conflict{};
    [[nodiscard]] bool needs_manual_hri() const noexcept { return !hri_port.has_value(); }
    [[nodiscard]] bool needs_manual_cat() const noexcept { return !cat_port.has_value(); }
};

enum class PortSelectionError : std::uint8_t { none, invalid_manual_cat_port };

// Resolve-RadioDevicePortSelection. `manual_cat_port` empty means not given;
// a non-empty value that is not "COM1".."COM999" yields invalid_manual_cat_port.
[[nodiscard]] PortSelection resolve_port_selection(const SerialCatalog& catalog, std::string_view saved_hri_port,
    std::string_view saved_cat_port, std::string_view manual_cat_port, PortSelectionError& error);

// Settings-window HRI default (Get-UiSerialOptions): a saved non-auto value is
// kept as-is; for "auto" prefer the HRI port named COM5, then the unique HRI.
// Returns "auto" when nothing qualifies.
[[nodiscard]] std::string default_hri_selection(const SerialCatalog& catalog, std::string_view saved_port);

// ---------------------------------------------------------------------------
// Audio endpoints

enum class Direction : std::uint8_t { capture, render };

// One WinMM device, same fields as `wirex_bridge.exe --list-audio-json`.
struct WaveDevice {
    std::uint32_t id{};                       // WinMM device number
    std::string name{};                       // WAVE*CAPS szPname (may be truncated to 31 chars)
    std::optional<std::string> endpoint_id{};  // DRV_QUERYFUNCTIONINSTANCEID
    bool pcm_48000_mono_s16_supported{};
};

// One active MMDevice endpoint.
struct AudioEndpoint {
    std::string endpoint_id{};
    std::string friendly_name{};  // PKEY_Device_FriendlyName
    std::optional<std::uint32_t> wave_id{};  // matching WinMM number, if any
};

struct AudioCatalog {
    bool mmdevice_ok{};
    std::vector<WaveDevice> wave_inputs{};
    std::vector<WaveDevice> wave_outputs{};
    std::vector<AudioEndpoint> capture_endpoints{};
    std::vector<AudioEndpoint> render_endpoints{};
};

// WinMM enumeration identical to probe_main.cpp list_audio_devices_json().
[[nodiscard]] std::vector<WaveDevice> enumerate_wave_devices(Direction direction);
// MMDevice enumeration of DEVICE_STATE_ACTIVE endpoints. Initializes COM on
// the calling thread when needed. Returns false (and leaves `out` empty) on failure.
[[nodiscard]] bool enumerate_mm_endpoints(Direction direction, std::vector<AudioEndpoint>& out);
// Both, linked through link_wave_ids().
[[nodiscard]] AudioCatalog enumerate_audio();

// Fills AudioEndpoint::wave_id by case-insensitive endpoint ID comparison (pure).
void link_wave_ids(std::vector<AudioEndpoint>& endpoints, const std::vector<WaveDevice>& waves);
[[nodiscard]] std::optional<std::uint32_t> wave_id_for_endpoint(const std::vector<WaveDevice>& waves,
    std::string_view endpoint_id);
// Serialized like --list-audio-json (single line, trailing "\n").
[[nodiscard]] std::string audio_devices_json(const std::vector<WaveDevice>& inputs, const std::vector<WaveDevice>& outputs);

// Usable = 48 kHz mono s16 supported and a non-blank endpoint ID.
[[nodiscard]] bool usable(const WaveDevice& device);
// Case-insensitive "USB Audio" substring test used by every PS auto rule.
[[nodiscard]] bool is_usb_audio_name(std::string_view name);

// Settings-window default (Get-UiEndpointOptions): saved non-auto endpoint is
// returned as stored (matched case-insensitively against usable devices when
// present); for "auto" the single usable "USB Audio" device, else "auto".
[[nodiscard]] std::string default_endpoint_selection(const std::vector<WaveDevice>& devices,
    std::string_view saved_endpoint);

enum class AudioResolveError : std::uint8_t {
    none,
    no_usable_input,
    no_usable_output,
    input_not_unique,   // auto could not pick a unique USB Audio input
    output_not_unique,
    saved_input_missing,   // explicit endpoint not enumerated exactly once
    saved_output_missing,
};

struct AudioPair {
    WaveDevice input{};
    WaveDevice output{};
    AudioResolveError error{AudioResolveError::none};
    std::string message{};  // Chinese, mirrors start-bm-radio-bridge.ps1 wording
    [[nodiscard]] bool ok() const noexcept { return error == AudioResolveError::none; }
};

struct AudioOutputSelection {
    WaveDevice output{};
    AudioResolveError error{AudioResolveError::none};
    std::string message{};
    [[nodiscard]] bool ok() const noexcept { return error == AudioResolveError::none; }
};

// BM-only receive playback resolves its render endpoint independently from
// HRI COM and WaveIn. "auto" selects only when exactly one usable render
// endpoint exists; otherwise the caller should ask the user to choose one.
[[nodiscard]] AudioOutputSelection resolve_audio_output(
    const std::vector<WaveDevice>& outputs, std::string_view selector);

// Non-interactive start-time resolution (start-bm-radio-bridge.ps1 with
// -NoInteractive): explicit selectors must be enumerated exactly once; "auto"
// sides use the unique USB Audio input/output pair, which is only considered
// when the HRI port was positively identified and must agree with any explicit side.
[[nodiscard]] AudioPair resolve_audio_endpoints(const std::vector<WaveDevice>& inputs,
    const std::vector<WaveDevice>& outputs, std::string_view wave_in_selector, std::string_view wave_out_selector,
    bool hri_identified);

} // namespace wirex::app::devices
