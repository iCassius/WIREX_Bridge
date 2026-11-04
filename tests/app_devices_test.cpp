#include "wirex/app/devices.hpp"

#include <algorithm>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

namespace dev = wirex::app::devices;

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const std::string& message)
{
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

dev::SerialPortRecord rec(const char* port, const char* friendly, const char* instance, const char* source = "input")
{
    dev::SerialPortRecord r;
    r.port_name = port;
    r.friendly_name = friendly;
    r.instance_id = instance;
    r.source = source;
    return r;
}

const dev::SerialPort* find_port(const std::vector<dev::SerialPort>& ports, const char* name)
{
    for (const auto& p : ports) if (p.port_name == name) return &p;
    return nullptr;
}

void test_normalize_port_name()
{
    struct Case { const char* input; std::optional<std::string> expected; };
    const std::vector<Case> cases{
        {"COM5", "COM5"},
        {"com5", "COM5"},
        {"\\\\.\\COM011", "COM11"},
        {"  COM7  ", "COM7"},
        {"USB Serial Device (COM12)", "COM12"},
        {"Silicon Labs CP2105 Enhanced COM Port (COM11)", "COM11"},
        {"COM0", std::nullopt},
        {"COM", std::nullopt},
        {"XCOM5", std::nullopt},
        {"COM5x", std::nullopt},
        {"", std::nullopt},
        {"COM99999999999", std::nullopt},
    };
    for (const Case& c : cases) {
        check(dev::normalize_port_name(c.input) == c.expected, std::string("normalize_port_name: ") + c.input);
    }
}

// Same fixtures as tools/test-radio-devices.ps1 (registry + CIM -> registry + SetupAPI).
dev::SerialCatalog ps_catalog()
{
    std::vector<dev::SerialPortRecord> records{
        rec("COM11", "", "", "registry"),
        rec("COM10", "", "", "registry"),
        rec("COM5", "", "", "registry"),
        rec("COM11", "Silicon Labs Dual CP2105 USB to UART Bridge: Enhanced COM Port (COM11)", "USB\\VID_10C4&PID_EA70&MI_00\\A", "setupapi"),
        rec("COM10", "Silicon Labs Dual CP2105 USB to UART Bridge: Standard COM Port (COM10)", "USB\\VID_10C4&PID_EA70&MI_01\\A", "setupapi"),
        rec("COM5", "USB \xE4\xB8\xB2\xE8\xA1\x8C\xE8\xAE\xBE\xE5\xA4\x87 (COM5)", "USB\\VID_26AA&PID_0030\\A", "setupapi"),
        rec("COM8", "Generic UART (COM8)", "USB\\VID_1234&PID_ABCD\\A", "setupapi"),
    };
    return dev::build_serial_catalog(records, true);
}

void test_catalog()
{
    const auto catalog = ps_catalog();
    check(catalog.discovery_status == "synthetic", "synthetic status");
    check(catalog.serial_ports.size() == 4, "four distinct ports");
    check(catalog.serial_ports.front().port_name == "COM5" && catalog.serial_ports.back().port_name == "COM11",
        "ports sorted numerically");
    check(catalog.hri_ports.size() == 1 && catalog.hri_ports[0].port_name == "COM5", "VID_26AA&PID_0030 is HRI");
    check(catalog.cat_ports.size() == 3, "all non-HRI ports are CAT candidates");
    const auto* com11 = find_port(catalog.serial_ports, "COM11");
    const auto* com10 = find_port(catalog.serial_ports, "COM10");
    const auto* com8 = find_port(catalog.serial_ports, "COM8");
    check(com11 && com11->sources.size() == 2, "registry and SetupAPI evidence merged");
    check(com11 && com10 && com11->cat_match_rank == 300 && com10->cat_match_rank == 250,
        "Enhanced outranks Standard CP2105");
    check(com11 && com11->cat_match_reason.find("Enhanced") != std::string::npos, "Enhanced reason");
    check(com8 && com8->cat_match_rank == 0 && com8->confidence == "unknown", "unknown port has no rank");
    check(catalog.hri_ports[0].confidence == "high", "HRI confidence high");

    struct RankCase { const char* friendly; const char* instance; int rank; bool hri; };
    const std::vector<RankCase> ranks{
        {"CP210x USB to UART Bridge (COM3)", "USB\\VID_10C4&PID_EA60\\X", 220, false},
        {"Some Bridge (COM3)", "USB\\VID_10C4&PID_EA60\\X", 180, false},
        {"USB-to-UART (COM3)", "FTDIBUS\\X", 100, false},
        {"Enhanced port", "USB\\VID_10C4&PID_EA70&MI_00\\X", 300, false},
        {"HRI-200 (COM3)", "", 0, true},
        {"SHRIMP (COM3)", "", 0, false},
        {"hri_200 (COM3)", "", 0, false},
        {"USB Serial (COM3)", "", 100, false},
    };
    for (const RankCase& c : ranks) {
        const auto single = dev::build_serial_catalog({rec("COM3", c.friendly, c.instance)}, true);
        check(single.serial_ports.size() == 1 && single.serial_ports[0].cat_match_rank == c.rank &&
            single.serial_ports[0].is_hri == c.hri, std::string("rank/hri: ") + c.friendly);
    }

    const auto alias = dev::build_serial_catalog({
        rec("\\\\.\\COM011", "CP2105 Enhanced COM Port (COM11)", "USB\\VID_10C4&PID_EA70&MI_00\\A"),
        rec("COM5", "HRI (COM5)", ""),
    }, true);
    check(alias.serial_ports.size() == 2 && find_port(alias.serial_ports, "COM11") != nullptr, "aliases normalized");

    const auto empty = dev::build_serial_catalog({}, false, dev::SourceStatus::ready, dev::SourceStatus::error);
    const auto failed = dev::build_serial_catalog({}, false, dev::SourceStatus::error, dev::SourceStatus::unavailable);
    check(empty.discovery_status == "empty" && failed.discovery_status == "failed", "empty vs failed status");
}

void test_port_selection()
{
    const auto catalog = ps_catalog();
    dev::PortSelectionError error{};

    const auto automatic = dev::resolve_port_selection(catalog, "auto", "missing", "", error);
    check(automatic.hri_port == std::string("COM5") && automatic.cat_port == std::string("COM11") &&
        automatic.cat_port_source == "matched", "auto picks unique HRI and strongest CAT");

    const auto saved = dev::resolve_port_selection(catalog, "COM5", "COM10", "", error);
    check(saved.cat_port == std::string("COM10") && saved.cat_port_source == "saved", "saved CAT wins");

    const auto conflict = dev::resolve_port_selection(catalog, "COM5", "COM5", "", error);
    check(!conflict.cat_port && conflict.cat_conflict && conflict.needs_manual_cat(), "saved CAT equal to HRI rejected");

    const auto tie = dev::resolve_port_selection(dev::build_serial_catalog({
        rec("COM5", "USB Serial Device (COM5)", "USB\\VID_26AA&PID_0030\\A"),
        rec("COM11", "CP2105 Enhanced COM Port (COM11)", "USB\\VID_10C4&PID_EA70&MI_00\\A"),
        rec("COM12", "CP2105 Enhanced COM Port (COM12)", "USB\\VID_10C4&PID_EA70&MI_00\\B"),
    }, true), "auto", "auto", "", error);
    check(!tie.cat_port && tie.needs_manual_cat(), "tied top rank needs manual CAT");

    const auto empty = dev::build_serial_catalog({}, true);
    const auto manual = dev::resolve_port_selection(empty, "auto", "auto", "COM11", error);
    check(error == dev::PortSelectionError::none && manual.cat_port == std::string("COM11") &&
        manual.cat_port_source == "manual", "manual CAT allowed without enumeration");
    const auto manual_lower = dev::resolve_port_selection(empty, "auto", "auto", " com11 ", error);
    check(error == dev::PortSelectionError::none && manual_lower.cat_port == std::string("COM11"), "manual CAT trimmed");

    const auto manual_conflict = dev::resolve_port_selection(catalog, "COM5", "auto", "COM5", error);
    check(!manual_conflict.cat_port && manual_conflict.cat_conflict, "manual CAT equal to HRI rejected");

    for (const char* bad : {"COM0", "COM1000", "COM011", "5", "\\\\.\\COM5"}) {
        (void)dev::resolve_port_selection(empty, "auto", "auto", bad, error);
        check(error == dev::PortSelectionError::invalid_manual_cat_port, std::string("manual CAT rejected: ") + bad);
    }

    const auto unknown = dev::resolve_port_selection(
        dev::build_serial_catalog({rec("COM7", "Unidentified UART (COM7)", "")}, true), "auto", "auto", "", error);
    check(!unknown.cat_port && !unknown.hri_port, "unknown ports are never auto-selected");

    const auto two_hri = dev::build_serial_catalog({
        rec("COM5", "HRI (COM5)", ""), rec("COM6", "HRI (COM6)", ""),
    }, true);
    check(!dev::resolve_port_selection(two_hri, "auto", "auto", "", error).hri_port, "two HRI need manual choice");
    check(dev::resolve_port_selection(two_hri, "COM6", "auto", "", error).hri_port == std::string("COM6"),
        "saved HRI among several");

    // Settings-window default.
    check(dev::default_hri_selection(catalog, "auto") == "COM5", "default HRI from catalog");
    check(dev::default_hri_selection(two_hri, "auto") == "COM5", "COM5 preferred among HRI ports");
    check(dev::default_hri_selection(empty, "auto") == "auto", "no HRI keeps auto");
    check(dev::default_hri_selection(catalog, "com5") == "COM5", "saved HRI matched case-insensitively");
    check(dev::default_hri_selection(catalog, "COM9") == "COM9", "missing saved HRI kept for display");
}

dev::WaveDevice wave(std::uint32_t id, const char* name, const char* endpoint, bool pcm = true)
{
    dev::WaveDevice d;
    d.id = id;
    d.name = name;
    if (endpoint != nullptr) d.endpoint_id = endpoint;
    d.pcm_48000_mono_s16_supported = pcm;
    return d;
}

void test_audio_mapping()
{
    const std::vector<dev::WaveDevice> waves{
        wave(0, "Microphone (Realtek)", "{0.0.1.00000000}.{aaaa}"),
        wave(1, "Microphone (USB Audio CODEC )", "{0.0.1.00000000}.{BBBB}"),
        wave(2, "Broken", nullptr),
    };
    std::vector<dev::AudioEndpoint> endpoints(3);
    endpoints[0].endpoint_id = "{0.0.1.00000000}.{bbbb}";
    endpoints[1].endpoint_id = "{0.0.1.00000000}.{AAAA}";
    endpoints[2].endpoint_id = "{0.0.1.00000000}.{cccc}";
    dev::link_wave_ids(endpoints, waves);
    check(endpoints[0].wave_id == 1U && endpoints[1].wave_id == 0U && !endpoints[2].wave_id,
        "endpoint -> WinMM id mapping is case-insensitive and reports missing");
    check(!dev::wave_id_for_endpoint(waves, ""), "empty endpoint id never maps");
    const std::vector<dev::WaveDevice> ambiguous{wave(0, "a", "{x}"), wave(1, "b", "{X}")};
    check(!dev::wave_id_for_endpoint(ambiguous, "{x}"), "ambiguous mapping treated as missing");

    const std::string json = dev::audio_devices_json({wave(0, "Mic \"1\"", "{e}")}, {wave(3, "Out", nullptr, false)});
    check(json == "{\"schema_version\":1,\"type\":\"audio_devices\",\"wave_inputs\":[{\"id\":0,\"name\":\"Mic \\\"1\\\"\","
                  "\"endpoint_id\":\"{e}\",\"pcm_48000_mono_s16_supported\":true}],\"wave_outputs\":[{\"id\":3,"
                  "\"name\":\"Out\",\"endpoint_id\":null,\"pcm_48000_mono_s16_supported\":false}]}\n",
        "audio JSON matches --list-audio-json");

    check(dev::is_usb_audio_name("Speakers (2- usb audio codec)") && !dev::is_usb_audio_name("USB-Audio"),
        "USB Audio name match");
    check(!dev::usable(wave(0, "x", "  ")) && !dev::usable(wave(0, "x", "{e}", false)) && dev::usable(wave(0, "x", "{e}")),
        "usable requires PCM and endpoint id");
}

void test_audio_selection()
{
    const std::vector<dev::WaveDevice> inputs{
        wave(0, "Microphone (Realtek)", "{in-a}"),
        wave(1, "Microphone (USB Audio CODEC )", "{in-usb}"),
    };
    const std::vector<dev::WaveDevice> outputs{
        wave(0, "Speakers (Realtek)", "{out-a}"),
        wave(1, "Speakers (USB Audio CODEC )", "{out-usb}"),
    };
    check(dev::default_endpoint_selection(inputs, "auto") == "{in-usb}", "settings default picks unique USB Audio");
    check(dev::default_endpoint_selection(inputs, "{IN-A}") == "{in-a}", "saved endpoint matched case-insensitively");
    check(dev::default_endpoint_selection(inputs, "{gone}") == "{gone}", "missing saved endpoint kept");
    const std::vector<dev::WaveDevice> two_usb{wave(0, "USB Audio 1", "{1}"), wave(1, "USB Audio 2", "{2}")};
    check(dev::default_endpoint_selection(two_usb, "auto") == "auto", "two USB Audio devices stay auto");

    const auto only_speaker = dev::resolve_audio_output({outputs.front()}, "auto");
    check(only_speaker.ok() && only_speaker.output.endpoint_id == std::string("{out-a}"),
          "BM-only auto output resolves one usable computer speaker without an HRI/USB pair");
    const auto unique_usb_output = dev::resolve_audio_output(outputs, "auto");
    check(unique_usb_output.ok() && unique_usb_output.output.endpoint_id == std::string("{out-usb}"),
          "BM-only auto output preserves the existing unique USB Audio preference");
    const auto multiple_outputs = dev::resolve_audio_output(
        {wave(0, "Speakers (Realtek)", "{out-a}"), wave(1, "Speakers (HDMI)", "{out-hdmi}")}, "auto");
    check(multiple_outputs.error == dev::AudioResolveError::output_not_unique &&
          !multiple_outputs.message.empty(), "BM-only auto output asks for manual choice when several candidates lack a unique USB Audio endpoint");
    const auto explicit_output = dev::resolve_audio_output(outputs, "{OUT-A}");
    check(explicit_output.ok() && explicit_output.output.endpoint_id == std::string("{out-a}"),
          "BM-only explicit output resolves independently of any WaveIn selector");
    const auto missing_output = dev::resolve_audio_output(outputs, "{gone}");
    check(missing_output.error == dev::AudioResolveError::saved_output_missing &&
          !missing_output.message.empty(), "BM-only missing saved output is reported without blocking receive");
    const auto no_outputs = dev::resolve_audio_output({}, "auto");
    check(no_outputs.error == dev::AudioResolveError::no_usable_output &&
          !no_outputs.message.empty(), "BM-only missing output remains an explicit unavailable state");
    const auto duplicate_output = dev::resolve_audio_output(
        {wave(0, "Output A", "{same}"), wave(1, "Output A duplicate", "{SAME}")}, "{same}");
    check(duplicate_output.error == dev::AudioResolveError::output_not_unique,
          "BM-only endpoint ID must resolve exactly once");

    struct Case {
        const char* name;
        const char* in_sel;
        const char* out_sel;
        bool hri;
        dev::AudioResolveError error;
        const char* in_id;
        const char* out_id;
    };
    using E = dev::AudioResolveError;
    const std::vector<Case> cases{
        {"auto pair", "auto", "auto", true, E::none, "{in-usb}", "{out-usb}"},
        {"auto without HRI", "auto", "auto", false, E::input_not_unique, "", ""},
        {"explicit both", "{IN-A}", "{out-a}", false, E::none, "{in-a}", "{out-a}"},
        {"explicit in + auto out (pair agrees)", "{in-usb}", "auto", true, E::none, "{in-usb}", "{out-usb}"},
        {"explicit in + auto out (pair disagrees)", "{in-a}", "auto", true, E::output_not_unique, "", ""},
        {"explicit missing", "{gone}", "auto", true, E::saved_input_missing, "", ""},
        // PS resolves the input first; the incompatible pair is dropped, so auto input fails.
        {"auto in + missing explicit out", "auto", "{gone}", true, E::input_not_unique, "", ""},
        {"explicit out missing", "{in-a}", "{gone}", true, E::saved_output_missing, "", ""},
    };
    for (const Case& c : cases) {
        const auto r = dev::resolve_audio_endpoints(inputs, outputs, c.in_sel, c.out_sel, c.hri);
        bool ok = r.error == c.error;
        if (ok && c.error == E::none) ok = r.input.endpoint_id == std::string(c.in_id) && r.output.endpoint_id == std::string(c.out_id);
        if (ok && c.error != E::none) ok = !r.message.empty();
        check(ok, std::string("resolve_audio_endpoints: ") + c.name);
    }
    const auto none = dev::resolve_audio_endpoints({wave(0, "x", nullptr)}, outputs, "auto", "auto", true);
    check(none.error == E::no_usable_input, "no usable input reported");
}

void test_enumeration_smoke()
{
    // Hardware-dependent results are not asserted; the calls must succeed without crashing.
    const auto serial = dev::enumerate_serial_ports();
    check(serial.discovery_status == "ready" || serial.discovery_status == "empty" || serial.discovery_status == "failed",
        "serial enumeration returns a status");
    for (const auto& port : serial.serial_ports) {
        check(dev::normalize_port_name(port.port_name) == port.port_name, "enumerated port names are canonical");
    }
    const auto audio = dev::enumerate_audio();
    for (const auto& endpoint : audio.capture_endpoints) {
        if (endpoint.wave_id) {
            check(*endpoint.wave_id < audio.wave_inputs.size(), "capture mapping points at a WinMM input");
        }
    }
    for (const auto& endpoint : audio.render_endpoints) {
        if (endpoint.wave_id) {
            check(*endpoint.wave_id < audio.wave_outputs.size(), "render mapping points at a WinMM output");
        }
    }
    std::cout << "INFO: " << serial.serial_ports.size() << " serial port(s), " << audio.wave_inputs.size() << "/"
              << audio.wave_outputs.size() << " WinMM in/out, " << audio.capture_endpoints.size() << "/"
              << audio.render_endpoints.size() << " MMDevice capture/render, mmdevice_ok=" << audio.mmdevice_ok << '\n';
}

} // namespace

int main()
{
    try {
        test_normalize_port_name();
        test_catalog();
        test_port_selection();
        test_audio_mapping();
        test_audio_selection();
        test_enumeration_smoke();
    } catch (const std::exception& error) {
        std::cerr << "FAIL: unexpected exception: " << error.what() << '\n';
        return 1;
    }
    if (failures != 0) {
        std::cerr << failures << " of " << checks << " checks failed\n";
        return 1;
    }
    std::cout << "PASS: app_devices_test (" << checks << " checks)\n";
    return 0;
}
