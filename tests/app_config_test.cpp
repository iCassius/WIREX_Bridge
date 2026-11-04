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
#include <functional>
#include <iostream>
#include <iterator>
#include <optional>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using wirex::app::AppConfig;
using wirex::app::ConfigErrorCode;
namespace json = wirex::app::json;

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

std::string read_bytes(const fs::path& path)
{
    std::ifstream file(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}

void write_bytes(const fs::path& path, const std::string& bytes)
{
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

std::wstring env(const wchar_t* name)
{
    std::wstring value(32768, L'\0');
    const DWORD length = GetEnvironmentVariableW(name, value.data(), static_cast<DWORD>(value.size()));
    if (length == 0 || length >= value.size()) return {};
    value.resize(length);
    return value;
}

fs::path scratch_root()
{
    // TMPDIR is set to <worktree>/tmp by tools/build-app-tests.ps1.
    const std::wstring tmpdir = env(L"TMPDIR");
    fs::path base = !tmpdir.empty() ? fs::path(tmpdir) : fs::temp_directory_path();
    fs::path root = base / ("app-config-test-" + std::to_string(GetCurrentProcessId()));
    fs::remove_all(root);
    fs::create_directories(root);
    return root;
}

bool raw_has_language(const fs::path& path)
{
    json::Value doc;
    if (!json::parse(read_bytes(path), doc).ok()) return false;
    const json::Value* ui = doc.find("ui");
    return ui != nullptr && ui->find("language") != nullptr;
}

std::size_t count_leftovers(const fs::path& directory)
{
    std::size_t count = 0;
    for (const auto& entry : fs::directory_iterator(directory)) {
        const std::string name = entry.path().filename().string();
        if (name.find(".backup") != std::string::npos || name.find("-tmp-") != std::string::npos ||
            name.find(".init-") != std::string::npos) {
            ++count;
        }
    }
    return count;
}

// Default document as stored JSON text (what Initialize-PortableConfig writes).
std::string default_text() { return wirex::app::serialize_config(wirex::app::default_config().document); }

json::Value default_doc()
{
    json::Value doc;
    const auto parsed = json::parse(default_text(), doc);
    if (!parsed.ok()) std::abort();
    return doc;
}

// Edits a parsed default document, then validates it via parse_text (stored-shape check included).
wirex::app::ConfigResult<AppConfig> with_edit(const std::function<void(json::Value&)>& edit)
{
    json::Value doc = default_doc();
    edit(doc);
    return wirex::app::parse_text(json::serialize(doc));
}

json::Value& at(json::Value& doc, const char* section, const char* key) { return *doc.find(section)->find(key); }

json::Value num(const char* literal) { return json::Value::number_literal(literal); }
json::Value str(const char* text) { return json::Value::string(text); }

// ---------------------------------------------------------------------------

void test_defaults()
{
    const AppConfig c = wirex::app::default_config();
    check(c.connection.callsign.empty() && c.connection.password.empty() && c.connection.api_key.empty(),
        "defaults carry no credentials");
    check(c.connection.gateway_id == 0 && c.connection.source_id == 0, "default ids are 0");
    check(c.connection.master == "43.129.83.124" && c.connection.master_port == 62031 && c.connection.color_code == 1,
        "default master endpoint");
    check(c.devices.hri_port == "auto" && c.devices.cat_port == "auto" && c.devices.cat_baud_rate == 38400 &&
        c.devices.cat_stop_bits == "Two" && c.devices.wave_in_endpoint_id == "auto" &&
        c.devices.wave_out_endpoint_id == "auto" && c.devices.desired_power_watts == 25, "default devices");
    check(c.audio.radio_playback_gain_milli == 1000 && c.audio.mic_transmit_gain_milli == 16000, "default gains");
    check(c.channels.size() == 1 && c.channels[0].key() == "private:460997:2" && c.channels[0].name == "460997",
        "default channel is BM parrot");
    check(c.tx_channel_id == "private:460997:2", "default tx channel");
    check(c.routing.blocked_source_ids.empty(), "default routing empty");
    check(c.ui.bm_server_selection_id == "bm-china-4602" && c.ui.legacy_rx_policy.is_null() && c.ui.language == "zh-CN",
        "default ui");
    check(c.window.is_object() && c.window.members.empty(), "default window is empty object");

    auto partial = default_doc();
    partial.find("devices")->erase("cat_baud_rate");
    const auto from_partial = wirex::app::from_document(partial);
    check(from_partial.ok() && from_partial.value().devices.cat_baud_rate == 38400U,
          "from_document fills an omitted CAT baud from the 38400 default");

    // Byte layout matches what PS 5.1 ConvertTo-Json -Depth 24 + "`n" produces for the defaults.
    const std::string expected =
        "{\r\n"
        "    \"schema_version\":  1,\r\n"
        "    \"connection\":  {\r\n"
        "                       \"callsign\":  \"\",\r\n"
        "                       \"gateway_id\":  0,\r\n"
        "                       \"source_id\":  0,\r\n"
        "                       \"master\":  \"43.129.83.124\",\r\n"
        "                       \"master_port\":  62031,\r\n"
        "                       \"color_code\":  1,\r\n"
        "                       \"password\":  \"\",\r\n"
        "                       \"api_key\":  \"\"\r\n"
        "                   },\r\n"
        "    \"devices\":  {\r\n"
        "                    \"serial_port\":  \"auto\",\r\n"
        "                    \"hri_port\":  \"auto\",\r\n"
        "                    \"cat_port\":  \"auto\",\r\n"
        "                    \"cat_baud_rate\":  38400,\r\n"
        "                    \"cat_stop_bits\":  \"Two\",\r\n"
        "                    \"wave_in_endpoint_id\":  \"auto\",\r\n"
        "                    \"wave_out_endpoint_id\":  \"auto\",\r\n"
        "                    \"desired_power_watts\":  25\r\n"
        "                },\r\n"
        "    \"audio\":  {\r\n"
        "                  \"radio_playback_gain\":  1,\r\n"
        "                  \"mic_transmit_gain\":  16\r\n"
        "              },\r\n"
        "    \"channels\":  [\r\n"
        "                     {\r\n"
        "                         \"id\":  460997,\r\n"
        "                         \"kind\":  \"private\",\r\n"
        "                         \"slot\":  2,\r\n"
        "                         \"name\":  \"460997\"\r\n"
        "                     }\r\n"
        "                 ],\r\n"
        "    \"tx_channel_id\":  \"private:460997:2\",\r\n"
        "    \"routing\":  {\r\n"
        "                    \"blocked_source_ids\":  [\r\n"
        "\r\n"
        "                                           ]\r\n"
        "                },\r\n"
        "    \"ui\":  {\r\n"
        "               \"bm_server_selection_id\":  \"bm-china-4602\",\r\n"
        "               \"legacy_rx_policy\":  null,\r\n"
        "               \"language\":  \"zh-CN\"\r\n"
        "           },\r\n"
        "    \"window\":  {\r\n"
        "\r\n"
        "               }\r\n"
        "}\n";
    check(default_text() == expected, "default serialization matches PowerShell ConvertTo-Json layout");
}

struct FieldCase {
    const char* name;
    std::function<void(json::Value&)> edit;
    std::optional<ConfigErrorCode> expected;  // nullopt = accepted
    std::function<bool(const AppConfig&)> verify{};
};

void run_cases(const char* group, const std::vector<FieldCase>& cases)
{
    for (const FieldCase& c : cases) {
        const auto result = with_edit(c.edit);
        const std::string label = std::string(group) + ": " + c.name;
        if (!c.expected) {
            check(result.ok(), label + " should be accepted" + (result.ok() ? "" : " (" + result.error().message + ")"));
            if (result.ok() && c.verify) check(c.verify(result.value()), label + " typed value");
        } else {
            check(!result.ok(), label + " should be rejected");
            if (!result.ok()) {
                check(result.error().code == *c.expected,
                    label + " error code (got message: " + result.error().message + ")");
                check(!result.error().message.empty(), label + " has a message");
            }
        }
    }
}

void test_connection_fields()
{
    using E = ConfigErrorCode;
    const auto set = [](const char* key, json::Value v) {
        return [key, v](json::Value& d) { at(d, "connection", key) = v; };
    };
    run_cases("connection", {
        {"callsign 8 printable", set("callsign", str("N0CALL~ ")), std::nullopt,
            [](const AppConfig& c) { return c.connection.callsign == "N0CALL~ "; }},
        {"callsign 9 chars", set("callsign", str("ABCDEFGHI")), E::invalid_format},
        {"callsign non-ascii", set("callsign", str("\xE4\xB8\xAD")), E::invalid_format},
        {"callsign control char", set("callsign", str("AB\tC")), E::invalid_format},
        {"callsign trailing LF (.NET $ quirk)", set("callsign", str("N0CALL\n")), std::nullopt},
        {"callsign number", set("callsign", num("1")), E::invalid_format},
        {"master 253 chars", set("master", json::Value::string(std::string(253, 'a'))), std::nullopt},
        {"master 254 chars", set("master", json::Value::string(std::string(254, 'a'))), E::invalid_format},
        {"master with space", set("master", str("a b")), E::invalid_format},
        {"master with NBSP", set("master", str("a\xC2\xA0" "b")), E::invalid_format},
        {"master empty", set("master", str("")), std::nullopt},
        {"password 4096", set("password", json::Value::string(std::string(4096, 'p'))), std::nullopt},
        {"password 4097", set("password", json::Value::string(std::string(4097, 'p'))), E::invalid_format},
        {"password null", set("password", json::Value::null()), E::invalid_format},
        {"api_key 8192", set("api_key", json::Value::string(std::string(8192, 'k'))), std::nullopt},
        {"api_key 8193", set("api_key", json::Value::string(std::string(8193, 'k'))), E::invalid_format},
        {"gateway_id max", set("gateway_id", num("4294967295")), std::nullopt,
            [](const AppConfig& c) { return c.connection.gateway_id == 4294967295U; }},
        {"gateway_id over", set("gateway_id", num("4294967296")), E::out_of_range},
        {"gateway_id string digits", set("gateway_id", str("12")), std::nullopt,
            [](const AppConfig& c) { return c.connection.gateway_id == 12; }},
        {"gateway_id string leading zero", set("gateway_id", str("012")), E::invalid_value},
        {"gateway_id negative", set("gateway_id", num("-1")), E::out_of_range},
        {"gateway_id decimal", set("gateway_id", num("1.0")), E::invalid_value},
        {"gateway_id exponent", set("gateway_id", num("1e2")), E::invalid_value},
        {"gateway_id bool", set("gateway_id", json::Value::boolean(true)), E::invalid_value},
        {"gateway_id null", set("gateway_id", json::Value::null()), E::invalid_value},
        {"source_id 16777215", set("source_id", num("16777215")), std::nullopt},
        {"source_id 16777216", set("source_id", num("16777216")), E::out_of_range},
        {"source_id zero allowed", set("source_id", num("0")), std::nullopt},
        {"master_port 0", set("master_port", num("0")), std::nullopt},
        {"master_port 65535", set("master_port", num("65535")), std::nullopt},
        {"master_port 65536", set("master_port", num("65536")), E::out_of_range},
        {"color_code 15", set("color_code", num("15")), std::nullopt},
        {"color_code 16", set("color_code", num("16")), E::out_of_range},
        {"color_code beyond int64 is decimal", set("color_code", num("99999999999999999999")), E::invalid_value},
    });
}

void test_device_fields()
{
    using E = ConfigErrorCode;
    const auto set = [](const char* key, json::Value v) {
        return [key, v](json::Value& d) { at(d, "devices", key) = v; };
    };
    const auto set_both = [](json::Value v) {
        return [v](json::Value& d) { at(d, "devices", "hri_port") = v; at(d, "devices", "serial_port") = v; };
    };
    run_cases("devices", {
        {"hri COM1", set_both(str("COM1")), std::nullopt, [](const AppConfig& c) { return c.devices.hri_port == "COM1"; }},
        {"hri COM999", set_both(str("COM999")), std::nullopt},
        {"hri COM1000", set_both(str("COM1000")), E::invalid_format},
        {"hri COM0", set_both(str("COM0")), E::invalid_format},
        {"hri lower com5", set_both(str("com5")), E::invalid_format},
        {"hri AUTO", set_both(str("AUTO")), E::invalid_format},
        {"serial_port alias overwritten by hri_port",
            [](json::Value& d) { at(d, "devices", "serial_port") = str("COM9"); at(d, "devices", "hri_port") = str("COM5"); },
            std::nullopt, [](const AppConfig& c) {
                return c.devices.hri_port == "COM5" && c.document.find("devices")->find("serial_port")->text == "COM5";
            }},
        {"serial_port invalid", set("serial_port", str("COM0")), E::invalid_format},
        {"cat_port COM12", set("cat_port", str("COM12")), std::nullopt},
        {"stored config missing CAT baud", [](json::Value& d) { d.find("devices")->erase("cat_baud_rate"); }, E::incomplete_section},
        {"cat_port number", set("cat_port", num("5")), E::invalid_format},
        {"wave_in whitespace", set("wave_in_endpoint_id", str(" \t")), E::invalid_format},
        {"wave_in 4096", set("wave_in_endpoint_id", json::Value::string(std::string(4096, 'e'))), std::nullopt},
        {"wave_out 4097", set("wave_out_endpoint_id", json::Value::string(std::string(4097, 'e'))), E::invalid_format},
        {"wave_out endpoint id", set("wave_out_endpoint_id", str("{0.0.0.00000000}.{abc}")), std::nullopt},
        {"baud 4800", set("cat_baud_rate", num("4800")), std::nullopt},
        {"baud 9600", set("cat_baud_rate", num("9600")), std::nullopt},
        {"baud 19200", set("cat_baud_rate", num("19200")), std::nullopt},
        {"baud 115200", set("cat_baud_rate", num("115200")), std::nullopt},
        {"baud 57600 not listed", set("cat_baud_rate", num("57600")), E::invalid_format},
        {"baud 115201", set("cat_baud_rate", num("115201")), E::out_of_range},
        {"baud 0", set("cat_baud_rate", num("0")), E::out_of_range},
        {"stop bits One", set("cat_stop_bits", str("One")), E::invalid_format},
        {"stop bits two", set("cat_stop_bits", str("two")), E::invalid_format},
        {"power 5", set("desired_power_watts", num("5")), std::nullopt},
        {"power 50", set("desired_power_watts", num("50")), std::nullopt},
        {"power 4", set("desired_power_watts", num("4")), E::out_of_range},
        {"power 51", set("desired_power_watts", num("51")), E::out_of_range},
        {"power 0", set("desired_power_watts", num("0")), E::out_of_range},
    });
}

void test_audio_fields()
{
    using E = ConfigErrorCode;
    const auto set = [](const char* key, json::Value v) {
        return [key, v](json::Value& d) { at(d, "audio", key) = v; };
    };
    const auto playback = [](std::uint32_t milli) {
        return [milli](const AppConfig& c) { return c.audio.radio_playback_gain_milli == milli; };
    };
    run_cases("audio", {
        {"0.25 min", set("radio_playback_gain", num("0.25")), std::nullopt, playback(250)},
        {"0.249 below", set("radio_playback_gain", num("0.249")), E::out_of_range},
        {"16 max", set("radio_playback_gain", num("16")), std::nullopt, playback(16000)},
        {"16.0 max", set("radio_playback_gain", num("16.0")), std::nullopt, playback(16000)},
        {"16.001 above", set("radio_playback_gain", num("16.001")), E::out_of_range},
        {"1.25", set("radio_playback_gain", num("1.25")), std::nullopt, playback(1250)},
        {"1.2345 too many decimals", set("radio_playback_gain", num("1.2345")), E::invalid_value},
        {"string 1.5", set("radio_playback_gain", str("1.5")), std::nullopt, playback(1500)},
        {"string .5", set("radio_playback_gain", str(".5")), E::invalid_value},
        {"exponent 2.5e-1 via double", set("radio_playback_gain", num("2.5e-1")), std::nullopt, playback(250)},
        {"negative", set("radio_playback_gain", num("-1")), E::invalid_value},
        {"bool", set("radio_playback_gain", json::Value::boolean(true)), E::invalid_value},
        {"null", set("mic_transmit_gain", json::Value::null()), E::invalid_value},
        {"mic 0", set("mic_transmit_gain", num("0")), E::out_of_range},
        {"mic 100", set("mic_transmit_gain", num("100")), E::out_of_range},
    });
    const auto kept = with_edit(set("radio_playback_gain", num("1.250")));
    check(kept.ok() && kept.value().document.find("audio")->find("radio_playback_gain")->text == "1.250",
        "decimal scale is preserved like System.Decimal");
}

json::Value channel(const char* id, const char* kind, const char* slot, const char* name)
{
    json::Value item = json::Value::object();
    item.set("id", num(id));
    item.set("kind", str(kind));
    item.set("slot", num(slot));
    item.set("name", str(name));
    return item;
}

void test_channel_fields()
{
    using E = ConfigErrorCode;
    const auto channels = [](std::vector<json::Value> items, const char* tx) {
        return [items, tx](json::Value& d) {
            json::Value list = json::Value::array();
            list.items = items;
            d.set("channels", list);
            d.set("tx_channel_id", str(tx));
        };
    };
    std::vector<json::Value> many;
    for (int i = 1; i <= 257; ++i) many.push_back(channel(std::to_string(i).c_str(), "group", "1", "x"));
    std::vector<json::Value> exactly256(many.begin(), many.begin() + 256);
    run_cases("channels", {
        {"two channels", channels({channel("12345", "group", "1", "工作组"), channel("460997", "private", "2", "测试")},
             "private:460997:2"), std::nullopt,
            [](const AppConfig& c) { return c.channels.size() == 2 && c.channels[0].key() == "group:12345:1"; }},
        {"256 channels", channels(exactly256, "group:1:1"), std::nullopt},
        {"257 channels", channels(many, "group:1:1"), E::out_of_range},
        {"id 0", channels({channel("0", "group", "1", "x")}, ""), E::out_of_range},
        {"id 16777215", channels({channel("16777215", "group", "1", "x")}, ""), std::nullopt},
        {"id 16777216", channels({channel("16777216", "group", "1", "x")}, ""), E::out_of_range},
        {"slot 0", channels({channel("1", "group", "0", "x")}, ""), E::out_of_range},
        {"slot 3", channels({channel("1", "group", "3", "x")}, ""), E::out_of_range},
        {"kind Group", channels({channel("1", "Group", "1", "x")}, ""), E::invalid_format},
        {"name 40", channels({channel("1", "group", "1", "0123456789012345678901234567890123456789")}, ""), std::nullopt},
        {"name 41", channels({channel("1", "group", "1", "01234567890123456789012345678901234567890")}, ""), E::invalid_format},
        {"name 40 CJK", channels({channel("1", "group", "1",
             "中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中")}, ""), std::nullopt},
        {"name blank", channels({channel("1", "group", "1", "  ")}, ""), E::invalid_format},
        {"name control", channels({channel("1", "group", "1", "a\x01")}, ""), E::invalid_format},
        {"name zero-width space (Cf)", channels({channel("1", "group", "1", "a\xE2\x80\x8B")}, ""), E::invalid_format},
        {"name emoji (surrogate pair)", channels({channel("1", "group", "1", "a\xF0\x9F\x98\x80")}, ""), E::invalid_format},
        {"missing name", [](json::Value& d) {
             d.find("channels")->items[0] = channel("1", "group", "1", "x");
             d.find("channels")->items[0].erase("name");
             d.set("tx_channel_id", str(""));
         }, E::missing_required_field},
        {"default channel missing name is filled by tuple-key merge (PS behaviour)",
            [](json::Value& d) { d.find("channels")->items[0].erase("name"); }, std::nullopt,
            [](const AppConfig& c) { return c.channels[0].name == "460997"; }},
        {"channel not object", [](json::Value& d) { d.find("channels")->items[0] = num("1"); }, E::not_object},
        {"channels not array", [](json::Value& d) { d.set("channels", json::Value::object()); }, E::invalid_format},
        {"duplicate tuple", channels({channel("1", "group", "1", "a"), channel("1", "group", "1", "b")}, ""), E::duplicate_entry},
        {"same id other slot", channels({channel("1", "group", "1", "a"), channel("1", "group", "2", "b")}, ""), std::nullopt},
        {"empty list + empty tx", channels({}, ""), std::nullopt,
            [](const AppConfig& c) { return c.channels.empty() && c.tx_channel_id.empty(); }},
        {"empty list + tx", channels({}, "group:1:1"), E::invalid_format},
        {"empty tx defaults to first", channels({channel("91", "group", "2", "TG91")}, ""), std::nullopt,
            [](const AppConfig& c) { return c.tx_channel_id == "group:91:2"; }},
        {"tx missing channel", channels({channel("91", "group", "2", "TG91")}, "group:91:1"), E::invalid_format},
        {"tx number", [](json::Value& d) { d.set("tx_channel_id", num("1")); }, E::invalid_format},
        {"id as string", channels({channel("1", "group", "1", "x")}, ""), std::nullopt},
    });
}

void test_routing_ui_window()
{
    using E = ConfigErrorCode;
    const auto blocked = [](std::vector<const char*> ids) {
        return [ids](json::Value& d) {
            json::Value list = json::Value::array();
            for (const char* id : ids) list.items.push_back(num(id));
            at(d, "routing", "blocked_source_ids") = list;
        };
    };
    const auto ui = [](const char* key, json::Value v) { return [key, v](json::Value& d) { d.find("ui")->set(key, v); }; };
    run_cases("routing/ui/window", {
        {"blocked ok", blocked({"3456789", "4567890"}), std::nullopt,
            [](const AppConfig& c) { return c.routing.blocked_source_ids.size() == 2; }},
        {"blocked 0", blocked({"0"}), E::out_of_range},
        {"blocked 16777216", blocked({"16777216"}), E::out_of_range},
        {"blocked duplicate", blocked({"5", "5"}), E::duplicate_entry},
        {"blocked not array", [](json::Value& d) { at(d, "routing", "blocked_source_ids") = num("5"); }, E::invalid_format},
        {"selection custom", ui("bm_server_selection_id", str("custom")), std::nullopt},
        {"selection bm-4602", ui("bm_server_selection_id", str("bm-4602")), std::nullopt},
        {"selection empty", ui("bm_server_selection_id", str("")), std::nullopt},
        {"selection upper", ui("bm_server_selection_id", str("bm-CN")), E::invalid_format},
        {"selection bm-", ui("bm_server_selection_id", str("bm-")), E::invalid_format},
        {"legacy object", ui("legacy_rx_policy", json::Value::object()), std::nullopt},
        {"legacy array", ui("legacy_rx_policy", json::Value::array()), E::not_object},
        {"language en-US", ui("language", str("en-US")), std::nullopt},
        {"language fr-FR", ui("language", str("fr-FR")), E::invalid_format},
        {"language missing defaults", [](json::Value& d) { d.find("ui")->erase("language"); }, std::nullopt,
            [](const AppConfig& c) { return c.ui.language == "zh-CN"; }},
        {"window array", [](json::Value& d) { d.set("window", json::Value::array()); }, E::not_object},
        {"window state kept", [](json::Value& d) { d.find("window")->set("left", num("-12.5")); }, std::nullopt,
            [](const AppConfig& c) { return c.window.find("left") != nullptr && c.window.find("left")->text == "-12.5"; }},
        {"schema 2", [](json::Value& d) { d.set("schema_version", num("2")); }, E::out_of_range},
        {"schema 0", [](json::Value& d) { d.set("schema_version", num("0")); }, E::out_of_range},
        {"schema string 1", [](json::Value& d) { d.set("schema_version", str("1")); }, std::nullopt},
        {"connection array", [](json::Value& d) { d.set("connection", json::Value::array()); }, E::incomplete_section},
        {"missing root field", [](json::Value& d) { d.erase("window"); }, E::missing_required_field},
        {"missing nested field", [](json::Value& d) { d.find("connection")->erase("api_key"); }, E::incomplete_section},
        {"missing legacy_rx_policy", [](json::Value& d) { d.find("ui")->erase("legacy_rx_policy"); }, E::incomplete_section},
        {"credential path nested", [](json::Value& d) { d.find("window")->set("API_KEY_FILE_PATH", str("x")); },
            E::credential_path_field},
        {"credential path root", [](json::Value& d) { d.set("password_file_path", str("x")); }, E::credential_path_field},
    });
}

void test_json_strictness()
{
    using E = ConfigErrorCode;
    struct Case { const char* name; std::string text; E code; };
    const std::string base = default_text();
    const std::vector<Case> cases{
        {"duplicate root key", "{\"a\":1,\"a\":2}", E::duplicate_key},
        {"case-variant duplicate", "{\"a\":1,\"A\":2}", E::duplicate_key},
        {"duplicate nested", "{\"x\":{\"k\":1,\"k\":1}}", E::duplicate_key},
        {"escaped key", "{\"\\u0061\":1}", E::escaped_key},
        {"broken", "{ broken-json", E::invalid_json},
        {"trailing comma", "{\"a\":[1,],}", E::invalid_json},
        {"invalid utf8", "{\"a\":\"\xff\"}", E::invalid_json},
        {"array root", "[]", E::not_object},
        {"too large", std::string(wirex::app::config_max_bytes + 1, ' '), E::too_large},
    };
    for (const Case& c : cases) {
        const auto result = wirex::app::parse_text(c.text);
        check(!result.ok() && result.error().code == c.code, std::string("strict json: ") + c.name);
    }
    // BOM tolerated (ReadAllText strips it).
    check(wirex::app::parse_text("\xEF\xBB\xBF" + base).ok(), "UTF-8 BOM accepted");
}

void test_json_dom()
{
    json::Value v;
    check(json::parse("{\"n\":[-0.5e+3,1E2,0,18446744073709551616]}", v).ok(), "full JSON numbers parse");
    const auto& items = v.find("n")->items;
    check(items[0].text == "-0.5e+3" && items[1].text == "1E2" && items[3].text == "18446744073709551616",
        "number literals kept verbatim");
    check(items[2].as_uint64() == 0U && !items[3].as_uint64().has_value() && !items[0].as_uint64(), "as_uint64");
    check(json::escape_string("<>&'\"\\/\t\x01\xC2\x85\xE2\x80\xA8") ==
        "\"\\u003c\\u003e\\u0026\\u0027\\\"\\\\/\\t\\u0001\\u0085\\u2028\"", "PowerShell string escaping");
    check(json::parse("\"\\ud83d\\ude00\"", v).ok() && v.text == "\xF0\x9F\x98\x80", "surrogate pair decoding");
    check(!json::parse("\"\\ud83d\"", v).ok(), "lone surrogate rejected");
    check(!json::parse("01", v).ok() && !json::parse("1.", v).ok() && !json::parse("+1", v).ok(), "bad numbers rejected");
    // Nested alignment with a CJK key uses UTF-16 width.
    json::Value doc = json::Value::object();
    json::Value list = json::Value::array();
    list.items.push_back(num("1"));
    doc.set("\xE4\xB8\xAD\xE6\x96\x87", list);
    check(json::serialize(doc) == "{\r\n    \"\xE4\xB8\xAD\xE6\x96\x87\":  [\r\n               1\r\n           ]\r\n}",
        "CJK key alignment matches PowerShell");
    std::string deep(70, '[');
    deep += std::string(70, ']');
    check(json::parse(deep, v).error == json::ParseError::too_deep, "depth limit");
}

// Synthetic config mirroring the structure of a PS-generated release config
// (legacy_rx_policy object, empty arrays, four channels) plus the
// tools/test-portable-config.ps1 fixture values. No real credentials.
std::string ps_fixture()
{
    return
        "{\r\n"
        "    \"schema_version\":  1,\r\n"
        "    \"connection\":  {\r\n"
        "                       \"callsign\":  \"N0CALL\",\r\n"
        "                       \"gateway_id\":  461135501,\r\n"
        "                       \"source_id\":  4611355,\r\n"
        "                       \"master\":  \"43.129.83.124\",\r\n"
        "                       \"master_port\":  62031,\r\n"
        "                       \"color_code\":  1,\r\n"
        "                       \"password\":  \"synthetic-password-only\",\r\n"
        "                       \"api_key\":  \"aaaa.bbbb.cccc\",\r\n"
        "                       \"future_identity_field\":  \"keep-too\"\r\n"
        "                   },\r\n"
        "    \"devices\":  {\r\n"
        "                    \"serial_port\":  \"COM5\",\r\n"
        "                    \"hri_port\":  \"COM5\",\r\n"
        "                    \"cat_port\":  \"COM7\",\r\n"
        "                    \"cat_baud_rate\":  38400,\r\n"
        "                    \"cat_stop_bits\":  \"Two\",\r\n"
        "                    \"wave_in_endpoint_id\":  \"{0.0.1.00000000}.{11111111-2222-3333-4444-555555555555}\",\r\n"
        "                    \"wave_out_endpoint_id\":  \"auto\",\r\n"
        "                    \"desired_power_watts\":  30\r\n"
        "                },\r\n"
        "    \"audio\":  {\r\n"
        "                  \"radio_playback_gain\":  1.25,\r\n"
        "                  \"mic_transmit_gain\":  12\r\n"
        "              },\r\n"
        "    \"channels\":  [\r\n"
        "                     {\r\n"
        "                         \"id\":  460997,\r\n"
        "                         \"kind\":  \"private\",\r\n"
        "                         \"slot\":  2,\r\n"
        "                         \"name\":  \"\\u0027\xE6\xB5\x8B\xE8\xAF\x95\xE7\x9B\xAE\xE6\xA0\x87\\u0027\",\r\n"
        "                         \"future_channel_field\":  \"preserve-channel\"\r\n"
        "                     },\r\n"
        "                     {\r\n"
        "                         \"id\":  91,\r\n"
        "                         \"kind\":  \"group\",\r\n"
        "                         \"slot\":  2,\r\n"
        "                         \"name\":  \"TG91\"\r\n"
        "                     },\r\n"
        "                     {\r\n"
        "                         \"id\":  46001,\r\n"
        "                         \"kind\":  \"group\",\r\n"
        "                         \"slot\":  1,\r\n"
        "                         \"name\":  \"TG46001\"\r\n"
        "                     },\r\n"
        "                     {\r\n"
        "                         \"id\":  4000,\r\n"
        "                         \"kind\":  \"group\",\r\n"
        "                         \"slot\":  2,\r\n"
        "                         \"name\":  \"TG4000\"\r\n"
        "                     }\r\n"
        "                 ],\r\n"
        "    \"tx_channel_id\":  \"group:46001:1\",\r\n"
        "    \"routing\":  {\r\n"
        "                    \"blocked_source_ids\":  [\r\n"
        "\r\n"
        "                                           ]\r\n"
        "                },\r\n"
        "    \"ui\":  {\r\n"
        "               \"bm_server_selection_id\":  \"bm-4602\",\r\n"
        "               \"legacy_rx_policy\":  {\r\n"
        "                                        \"group_mode\":  \"selected\",\r\n"
        "                                        \"private_mode\":  \"all_peers_to_local\",\r\n"
        "                                        \"allow_groups\":  [\r\n"
        "                                                             {\r\n"
        "                                                                 \"destination_id\":  12345,\r\n"
        "                                                                 \"slot\":  1\r\n"
        "                                                             }\r\n"
        "                                                         ],\r\n"
        "                                        \"allow_private_peers\":  [\r\n"
        "\r\n"
        "                                                                ],\r\n"
        "                                        \"local_private_routes\":  [\r\n"
        "                                                                     {\r\n"
        "                                                                         \"local_destination_id\":  4611355,\r\n"
        "                                                                         \"slot\":  2\r\n"
        "                                                                     }\r\n"
        "                                                                 ],\r\n"
        "                                        \"blocked_groups\":  [\r\n"
        "                                                               {\r\n"
        "                                                                   \"destination_id\":  9,\r\n"
        "                                                                   \"slot\":  2\r\n"
        "                                                               }\r\n"
        "                                                           ],\r\n"
        "                                        \"blocked_source_ids\":  [\r\n"
        "\r\n"
        "                                                               ]\r\n"
        "                                    }\r\n"
        "           },\r\n"
        "    \"window\":  {\r\n"
        "\r\n"
        "               },\r\n"
        "    \"future_extension\":  {\r\n"
        "                             \"value\":  \"keep-me\",\r\n"
        "                             \"ratio\":  -0.125,\r\n"
        "                             \"nested\":  [\r\n"
        "                                            1.50,\r\n"
        "                                            true,\r\n"
        "                                            null\r\n"
        "                                        ]\r\n"
        "                         }\r\n"
        "}\n";
}

void test_file_round_trips(const fs::path& root)
{
    const fs::path dir = root / "exe root \xE4\xB8\xAD\xE6\x96\x87 path";
    fs::create_directories(dir);
    const fs::path path = dir / "config.json";

    // load of a missing file
    const auto missing = wirex::app::load(path);
    check(!missing.ok() && missing.error().code == ConfigErrorCode::file_not_found, "missing file reported");
    check(!fs::exists(path), "load does not create the file");

    // create_default writes, then never rewrites
    const auto created = wirex::app::create_default(path);
    check(created.ok() && fs::exists(path), "create_default writes config.json");
    check(read_bytes(path) == default_text(), "create_default bytes equal default serialization");
    check(count_leftovers(dir) == 0, "create_default leaves no temp files");
    write_bytes(path, ps_fixture());
    check(wirex::app::create_default(path).ok() && read_bytes(path) == ps_fixture(),
        "create_default validates an existing file without rewriting it");
    write_bytes(path, "{ broken-json");
    check(!wirex::app::create_default(path).ok() && read_bytes(path) == "{ broken-json",
        "create_default keeps malformed bytes");
    check(!wirex::app::create_default(root / "absent" / "config.json").ok(), "create_default needs the directory");

    // PS fixture: byte-exact round trip through load + save
    write_bytes(path, ps_fixture());
    const auto loaded = wirex::app::load(path);
    check(loaded.ok(), "PS fixture loads");
    if (loaded.ok()) {
        const AppConfig& c = loaded.value();
        check(c.connection.callsign == "N0CALL" && c.connection.gateway_id == 461135501 && c.devices.cat_port == "COM7",
            "fixture typed fields");
        check(c.audio.radio_playback_gain_milli == 1250 && c.audio.mic_transmit_gain_milli == 12000, "fixture gains");
        check(c.channels.size() == 4 && c.tx_channel_id == "group:46001:1", "fixture channels");
        check(c.ui.legacy_rx_policy.is_object() && c.ui.legacy_rx_policy.find("allow_groups") != nullptr, "legacy policy kept");
        check(c.document.find("future_extension") != nullptr, "unknown root section kept in document");
        check(wirex::app::serialize_config(c.document).size() + 0 > 0, "document serializes");
        const auto saved = wirex::app::save(path, c);
        check(saved.ok(), "fixture saves");
        // The fixture has no ui.language, so save must not add it; everything else is byte-identical.
        check(read_bytes(path) == ps_fixture(), "unchanged save is byte-identical to the PS-written file");
        check(count_leftovers(dir) == 0, "save leaves no temp/backup files");
    }

    // Edit and save: unknown fields survive, edited channel keeps its extras by tuple key.
    {
        auto c = wirex::app::load(path).value();
        c.connection.master = "bm.example.test";
        c.audio.radio_playback_gain_milli = 2500;
        c.channels[0].name = "renamed";
        c.channels.push_back({777, wirex::app::ChannelKind::group, 1, "TG777"});
        c.routing.blocked_source_ids = {3456789, 4567890};
        const auto saved = wirex::app::save(path, c);
        check(saved.ok(), "edited config saves");
        const auto reread = wirex::app::load(path);
        check(reread.ok(), "edited config reloads");
        if (reread.ok()) {
            const auto& d = reread.value().document;
            check(d.find("future_extension")->find("value")->text == "keep-me" &&
                d.find("future_extension")->find("ratio")->text == "-0.125" &&
                d.find("future_extension")->find("nested")->items[0].text == "1.50", "future_extension preserved verbatim");
            check(d.find("connection")->find("future_identity_field")->text == "keep-too", "nested unknown field preserved");
            check(d.find("channels")->items[0].find("future_channel_field")->text == "preserve-channel" &&
                d.find("channels")->items[0].find("name")->text == "renamed", "channel extras preserved by tuple key");
            check(d.find("audio")->find("radio_playback_gain")->text == "2.5", "edited gain written as decimal");
            check(reread.value().connection.master == "bm.example.test" && reread.value().channels.size() == 5,
                "edited values persisted");
            check(!raw_has_language(path), "ordinary save does not add ui.language");
        }
    }

    // Language: explicit persistence, then preserved by later saves.
    {
        const auto before = read_bytes(path);
        const auto bad = wirex::app::set_language(path, "fr-FR");
        check(!bad.ok() && read_bytes(path) == before, "invalid language rejected without touching file");
        const auto changed = wirex::app::set_language(path, "en-US");
        check(changed.ok() && changed.value().ui.language == "en-US", "set_language persists en-US");
        auto c = wirex::app::load(path).value();
        c.connection.callsign = "B1ABC";
        check(wirex::app::save(path, c).ok(), "save after language change");
        const auto reread = wirex::app::load(path).value();
        check(reread.ui.language == "en-US" && raw_has_language(path),
            "existing ui.language survives ordinary saves");
        wirex::app::SaveOptions persist;
        persist.persist_ui_language = true;
        const fs::path other = dir / "persist.json";
        auto fresh = wirex::app::default_config();
        check(wirex::app::save(other, fresh).ok(), "save to new path");
        check(!raw_has_language(other),
            "new file without persist flag omits language");
        fs::remove(other);
        check(wirex::app::save(other, fresh, persist).ok() &&
            raw_has_language(other),
            "persist_ui_language writes language");
    }

    // Rejections leave bytes untouched.
    {
        const auto before = read_bytes(path);
        auto c = wirex::app::load(path).value();
        c.devices.desired_power_watts = 51;
        const auto rejected = wirex::app::save(path, c);
        check(!rejected.ok() && rejected.error().code == ConfigErrorCode::out_of_range && read_bytes(path) == before,
            "invalid save keeps original bytes");
        c = wirex::app::load(path).value();
        c.document.find("connection")->set("Api_Key_File_Path", str("C:\\private\\key.txt"));
        const auto credential = wirex::app::save(path, c);
        check(!credential.ok() && credential.error().code == ConfigErrorCode::credential_path_field &&
            credential.error().message.find("aaaa.bbbb.cccc") == std::string::npos && read_bytes(path) == before,
            "credential path rejected without echoing secrets");
        check(count_leftovers(dir) == 0, "rejected saves leave no temp files");
    }

    // Damaged / oversized / duplicate files are never overwritten by save.
    struct Bad { const char* name; std::string bytes; ConfigErrorCode code; };
    std::string big = ps_fixture();
    big.insert(big.size() - 3, std::string(wirex::app::config_max_bytes, ' '));
    std::string dup = ps_fixture();
    dup.replace(dup.find("\"master_port\""), 13, "\"master\"");
    std::string missing_key = ps_fixture();
    missing_key.replace(missing_key.find("\"api_key\""), 9, "\"apikey\"");
    const std::vector<Bad> bad_files{
        {"malformed", "{ broken-json", ConfigErrorCode::invalid_json},
        {"oversized", big, ConfigErrorCode::too_large},
        {"duplicate key", dup, ConfigErrorCode::duplicate_key},
        {"missing nested key", missing_key, ConfigErrorCode::incomplete_section},
    };
    for (const Bad& bad : bad_files) {
        write_bytes(path, bad.bytes);
        const auto read = wirex::app::load(path);
        check(!read.ok() && read.error().code == bad.code, std::string("load rejects ") + bad.name);
        const auto write = wirex::app::save(path, wirex::app::default_config());
        check(!write.ok() && read_bytes(path) == bad.bytes, std::string("save keeps ") + bad.name + " bytes");
    }
    check(count_leftovers(dir) == 0, "no leftovers after rejected saves");

    // Save into a missing directory.
    const auto no_dir = wirex::app::save(root / "absent" / "config.json", wirex::app::default_config());
    check(!no_dir.ok() && no_dir.error().code == ConfigErrorCode::directory_missing, "save requires directory");

    // ReplaceFileW failure keeps the original: target opened without FILE_SHARE_DELETE.
    {
        write_bytes(path, ps_fixture());
        HANDLE lock = CreateFileW(path.wstring().c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, nullptr);
        check(lock != INVALID_HANDLE_VALUE, "lock handle opened");
        auto c = wirex::app::default_config();
        c.connection.callsign = "LOCKED";
        const auto locked = wirex::app::save(path, c);
        if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
        check(!locked.ok() && locked.error().code == ConfigErrorCode::io_error, "save fails while target is locked");
        check(read_bytes(path) == ps_fixture(), "locked target keeps original bytes");
        check(count_leftovers(dir) == 0, "failed replace leaves no temp files");
    }
}

void test_release_structure(const fs::path& scratch)
{
    // Structure-only check of a real PS-generated config. Values are never printed.
    // Opt-in: tools/build-app-tests.ps1 -PsConfigSample <path> sets this variable.
    const fs::path sample = env(L"WIREX_PS_CONFIG_SAMPLE");
    std::error_code error;
    if (sample.empty() || !fs::exists(sample, error)) {
        std::cout << "SKIP: WIREX_PS_CONFIG_SAMPLE not set or missing\n";
        return;
    }
    const std::string bytes = read_bytes(sample);
    const auto parsed = wirex::app::parse_text(bytes);
    check(parsed.ok(), "PS release config validates (structure only; contents not logged)");
    if (!parsed.ok()) {
        std::cerr << "  error code " << static_cast<int>(parsed.error().code) << " field " << parsed.error().field << '\n';
        return;
    }
    // Re-serializing the stored document reproduces the PS bytes exactly.
    json::Value raw;
    check(json::parse(bytes, raw).ok() && wirex::app::serialize_config(raw) == bytes,
        "PS release config re-serializes byte-identically");
    // load + unchanged save in the scratch directory reproduces the PS bytes.
    const fs::path copy = scratch / "release-sample.json";
    write_bytes(copy, bytes);
    const auto loaded = wirex::app::load(copy);
    const auto saved = loaded.ok() ? wirex::app::save(copy, loaded.value()) : loaded;
    check(saved.ok() && read_bytes(copy) == bytes, "PS release config survives load + save byte-identically");
    fs::remove(copy);
}

} // namespace

int main()
{
    try {
        const fs::path root = scratch_root();
        test_defaults();
        test_connection_fields();
        test_device_fields();
        test_audio_fields();
        test_channel_fields();
        test_routing_ui_window();
        test_json_strictness();
        test_json_dom();
        test_file_round_trips(root);
        test_release_structure(root);
        fs::remove_all(root);
    } catch (const std::exception& error) {
        std::cerr << "FAIL: unexpected exception: " << error.what() << '\n';
        return 1;
    }
    if (failures != 0) {
        std::cerr << failures << " of " << checks << " checks failed\n";
        return 1;
    }
    std::cout << "PASS: app_config_test (" << checks << " checks)\n";
    return 0;
}
