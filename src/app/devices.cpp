#include "wirex/app/devices.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <mmsystem.h>
#include <mmddk.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <propidl.h>
#include <setupapi.h>
#include <icu.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <map>
#include <mutex>

namespace wirex::app::devices {
namespace {

using Microsoft::WRL::ComPtr;

// {4D36E978-E325-11CE-BFC1-08002BE10318}; defined locally to avoid INITGUID in this TU.
constexpr GUID class_ports_guid{0x4d36e978, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
// PKEY_Device_FriendlyName.
constexpr PROPERTYKEY friendly_name_key{
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

// ---------------------------------------------------------------------------
// Text helpers

std::string to_utf8(std::wstring_view text)
{
    if (text.empty()) return {};
    const int required = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0,
        nullptr, nullptr);
    if (required <= 0) return {};
    std::string result(static_cast<std::size_t>(required), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), required, nullptr, nullptr);
    return result;
}

char lower_ascii(char c) noexcept { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; }

std::string lower_copy(std::string_view text)
{
    std::string out(text);
    for (char& c : out) c = lower_ascii(c);
    return out;
}

bool iequals(std::string_view left, std::string_view right) noexcept
{
    if (left.size() != right.size()) return false;
    for (std::size_t i = 0; i < left.size(); ++i) {
        if (lower_ascii(left[i]) != lower_ascii(right[i])) return false;
    }
    return true;
}

bool is_dotnet_whitespace(char32_t cp) noexcept
{
    return (cp >= 0x09 && cp <= 0x0D) || cp == 0x20 || cp == 0x85 || cp == 0xA0 || cp == 0x1680 ||
        (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F ||
        cp == 0x3000;
}

std::u32string to_u32(std::string_view utf8)
{
    std::u32string out;
    if (utf8.empty()) return out;
    const int wide_length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    if (wide_length <= 0) return out;
    std::wstring wide(static_cast<std::size_t>(wide_length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), wide.data(), wide_length);
    for (std::size_t i = 0; i < wide.size(); ++i) {
        char32_t cp = wide[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < wide.size() && wide[i + 1] >= 0xDC00 && wide[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (static_cast<char32_t>(wide[i + 1]) - 0xDC00);
            ++i;
        }
        out.push_back(cp);
    }
    return out;
}

std::string from_u32(std::u32string_view text)
{
    std::wstring wide;
    for (const char32_t cp : text) {
        if (cp >= 0x10000) {
            wide.push_back(static_cast<wchar_t>(0xD800 + ((cp - 0x10000) >> 10)));
            wide.push_back(static_cast<wchar_t>(0xDC00 + ((cp - 0x10000) & 0x3FF)));
        } else {
            wide.push_back(static_cast<wchar_t>(cp));
        }
    }
    return to_utf8(wide);
}

// String.Trim() / String.IsNullOrWhiteSpace().
std::string dotnet_trim(std::string_view utf8)
{
    const std::u32string cps = to_u32(utf8);
    std::size_t begin = 0;
    std::size_t end = cps.size();
    while (begin < end && is_dotnet_whitespace(cps[begin])) ++begin;
    while (end > begin && is_dotnet_whitespace(cps[end - 1])) --end;
    return from_u32(std::u32string_view(cps).substr(begin, end - begin));
}

bool is_blank(std::string_view utf8) { return dotnet_trim(utf8).empty(); }

// .NET regex \w for \b (letters, Mn, Nd, Pc, plus ZWNJ/ZWJ).
bool is_word_char(char32_t cp)
{
    if (cp == U'_' || cp == 0x200C || cp == 0x200D) return true;
    if (u_isalnum(static_cast<UChar32>(cp))) return true;
    const auto type = u_charType(static_cast<UChar32>(cp));
    return type == U_NON_SPACING_MARK || type == U_CONNECTOR_PUNCTUATION;
}

// (?i)\bHRI\b
bool contains_hri_word(std::string_view utf8)
{
    const std::u32string cps = to_u32(utf8);
    for (std::size_t i = 0; i + 3 <= cps.size(); ++i) {
        const auto lower = [&](std::size_t k) { return cps[k] < 0x80 ? static_cast<char32_t>(lower_ascii(static_cast<char>(cps[k]))) : cps[k]; };
        if (lower(i) != U'h' || lower(i + 1) != U'r' || lower(i + 2) != U'i') continue;
        const bool left = i == 0 || !is_word_char(cps[i - 1]);
        const bool right = i + 3 == cps.size() || !is_word_char(cps[i + 3]);
        if (left && right) return true;
    }
    return false;
}

bool icontains(std::string_view haystack_lower, std::string_view needle_lower)
{
    return haystack_lower.find(needle_lower) != std::string_view::npos;
}

bool icontains_any(std::string_view haystack_lower, std::initializer_list<std::string_view> needles)
{
    for (const auto needle : needles) if (icontains(haystack_lower, needle)) return true;
    return false;
}

// (?i)(A1|A2..).*(B1|B2..) where '.' excludes '\n'.
bool ordered_on_line(std::string_view lower, std::initializer_list<std::string_view> first,
    std::initializer_list<std::string_view> second)
{
    for (const auto a : first) {
        for (std::size_t i = lower.find(a); i != std::string_view::npos; i = lower.find(a, i + 1)) {
            const std::size_t after = i + a.size();
            const std::size_t line_end = std::min(lower.find('\n', after), lower.size());
            const std::string_view rest = lower.substr(after, line_end - after);
            for (const auto b : second) if (rest.find(b) != std::string_view::npos) return true;
        }
    }
    return false;
}

bool either_order(std::string_view lower, std::initializer_list<std::string_view> a, std::initializer_list<std::string_view> b)
{
    return ordered_on_line(lower, a, b) || ordered_on_line(lower, b, a);
}

std::string join(const std::vector<std::string>& parts, std::string_view separator)
{
    std::string out;
    for (std::size_t i = 0; i < parts.size(); ++i) {
        if (i != 0) out += separator;
        out += parts[i];
    }
    return out;
}

void add_unique(std::vector<std::string>& list, const std::string& value)
{
    if (!value.empty() && std::find(list.begin(), list.end(), value) == list.end()) list.push_back(value);
}

int com_number(const std::string& port) { return std::atoi(port.c_str() + 3); }

// ---------------------------------------------------------------------------
// WinMM helpers. Copied from src/probe_main.cpp (wave_endpoint_id, device_name,
// pcm_format, json_escape); de-duplicate once probe_main.cpp can depend on this file.

std::optional<std::wstring> wave_endpoint_id(bool input, UINT device_id)
{
    const auto wave_id = static_cast<UINT_PTR>(device_id);
    DWORD size_bytes = 0U;
    const auto size_result = input
        ? waveInMessage(reinterpret_cast<HWAVEIN>(wave_id), DRV_QUERYFUNCTIONINSTANCEIDSIZE,
            reinterpret_cast<DWORD_PTR>(&size_bytes), 0U)
        : waveOutMessage(reinterpret_cast<HWAVEOUT>(wave_id), DRV_QUERYFUNCTIONINSTANCEIDSIZE,
            reinterpret_cast<DWORD_PTR>(&size_bytes), 0U);
    if (size_result != MMSYSERR_NOERROR || size_bytes < sizeof(wchar_t) ||
        size_bytes > 65536U || size_bytes % sizeof(wchar_t) != 0U) {
        return std::nullopt;
    }

    std::vector<wchar_t> buffer(static_cast<std::size_t>(size_bytes) / sizeof(wchar_t), L'\0');
    const auto id_result = input
        ? waveInMessage(reinterpret_cast<HWAVEIN>(wave_id), DRV_QUERYFUNCTIONINSTANCEID,
            reinterpret_cast<DWORD_PTR>(buffer.data()), size_bytes)
        : waveOutMessage(reinterpret_cast<HWAVEOUT>(wave_id), DRV_QUERYFUNCTIONINSTANCEID,
            reinterpret_cast<DWORD_PTR>(buffer.data()), size_bytes);
    if (id_result != MMSYSERR_NOERROR) return std::nullopt;
    const auto terminator = std::find(buffer.begin(), buffer.end(), L'\0');
    if (terminator == buffer.begin() || terminator == buffer.end()) return std::nullopt;
    return std::wstring(buffer.begin(), terminator);
}

std::wstring device_name(const wchar_t* name, std::size_t capacity)
{
    std::size_t length = 0;
    while (length < capacity && name[length] != L'\0') ++length;
    if (length == 0) return L"<empty name>";
    return std::wstring(name, length);
}

WAVEFORMATEX pcm_format() noexcept
{
    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = 48000;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 2;
    format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
    return format;
}

std::string json_escape(std::string_view value)
{
    std::string escaped;
    escaped.reserve(value.size() + 2);
    escaped.push_back('"');
    for (const unsigned char byte : value) {
        switch (byte) {
        case '"': escaped += "\\\""; break;
        case '\\': escaped += "\\\\"; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (byte < 0x20) {
                static constexpr char digits[] = "0123456789abcdef";
                escaped += "\\u00";
                escaped.push_back(digits[byte >> 4]);
                escaped.push_back(digits[byte & 0x0f]);
            } else {
                escaped.push_back(static_cast<char>(byte));
            }
        }
    }
    escaped.push_back('"');
    return escaped;
}

// ---------------------------------------------------------------------------
// SetupAPI helpers

std::vector<std::wstring> read_multi_sz(const std::vector<BYTE>& bytes)
{
    std::vector<std::wstring> out;
    const auto* text = reinterpret_cast<const wchar_t*>(bytes.data());
    const std::size_t count = bytes.size() / sizeof(wchar_t);
    std::size_t start = 0;
    for (std::size_t i = 0; i < count; ++i) {
        if (text[i] != L'\0') continue;
        if (i == start) break;
        out.emplace_back(text + start, i - start);
        start = i + 1;
    }
    return out;
}

std::optional<std::vector<BYTE>> device_property(HDEVINFO set, SP_DEVINFO_DATA& info, DWORD property)
{
    DWORD type = 0;
    DWORD required = 0;
    SetupDiGetDeviceRegistryPropertyW(set, &info, property, &type, nullptr, 0, &required);
    if (required == 0 || required > 65536U) return std::nullopt;
    std::vector<BYTE> buffer(required + sizeof(wchar_t) * 2U, 0);
    if (!SetupDiGetDeviceRegistryPropertyW(set, &info, property, &type, buffer.data(), required, nullptr)) {
        return std::nullopt;
    }
    return buffer;
}

std::wstring property_string(HDEVINFO set, SP_DEVINFO_DATA& info, DWORD property)
{
    const auto bytes = device_property(set, info, property);
    if (!bytes) return {};
    return std::wstring(reinterpret_cast<const wchar_t*>(bytes->data()));
}

std::wstring device_port_name(HDEVINFO set, SP_DEVINFO_DATA& info)
{
    HKEY key = SetupDiOpenDevRegKey(set, &info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_QUERY_VALUE);
    if (key == INVALID_HANDLE_VALUE) return {};
    std::array<wchar_t, 256> buffer{};
    DWORD size = static_cast<DWORD>((buffer.size() - 1) * sizeof(wchar_t));
    DWORD type = 0;
    const LSTATUS status = RegQueryValueExW(key, L"PortName", nullptr, &type, reinterpret_cast<BYTE*>(buffer.data()), &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS || type != REG_SZ) return {};
    return buffer.data();
}

class ComScope {
public:
    ComScope() noexcept
    {
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        owns_ = SUCCEEDED(hr);
        usable_ = owns_ || hr == RPC_E_CHANGED_MODE;  // already initialized as STA is fine
    }
    ~ComScope() { if (owns_) CoUninitialize(); }
    ComScope(const ComScope&) = delete;
    ComScope& operator=(const ComScope&) = delete;
    [[nodiscard]] bool usable() const noexcept { return usable_; }
private:
    bool owns_{};
    bool usable_{};
};


std::optional<std::string> normalized(const SerialPort& port) { return normalize_port_name(port.port_name); }

bool same(const std::optional<std::string>& left, const std::optional<std::string>& right)
{
    return left && right && *left == *right;
}

} // namespace

// ---------------------------------------------------------------------------
// Serial ports

std::optional<std::string> normalize_port_name(std::string_view raw)
{
    std::string text = dotnet_trim(raw);
    if (text.rfind("\\\\.\\", 0) == 0) text.erase(0, 4);
    const std::string lower = lower_copy(text);
    // (?i)(?:^|\()COM0*([1-9][0-9]*)\)?$
    for (std::size_t start = 0; start + 3 <= lower.size(); ++start) {
        if (lower.compare(start, 3, "com") != 0 || (start != 0 && lower[start - 1] != '(')) continue;
        std::size_t i = start + 3;
        while (i < lower.size() && lower[i] == '0') ++i;
        const std::size_t digits_begin = i;
        if (i >= lower.size() || lower[i] < '1' || lower[i] > '9') continue;
        while (i < lower.size() && lower[i] >= '0' && lower[i] <= '9') ++i;
        const std::size_t digits_end = i;
        if (i < lower.size() && lower[i] == ')') ++i;
        if (i != lower.size() && !(i + 1 == lower.size() && lower[i] == '\n')) continue;
        const std::string digits = lower.substr(digits_begin, digits_end - digits_begin);
        if (digits.size() > 10 || std::stoull(digits) > static_cast<unsigned long long>(std::numeric_limits<int>::max())) {
            return std::nullopt;  // [int] cast overflow
        }
        return "COM" + digits;
    }
    return std::nullopt;
}

SerialCatalog build_serial_catalog(const std::vector<SerialPortRecord>& records, bool synthetic,
    SourceStatus registry_status, SourceStatus setupapi_status)
{
    struct Entry {
        std::vector<std::string> friendly_names, instance_ids, hardware_ids, sources;
    };
    std::map<std::string, Entry> by_port;
    std::vector<std::string> order;
    for (const SerialPortRecord& record : records) {
        auto port = normalize_port_name(record.port_name);
        if (!port) port = normalize_port_name(record.friendly_name);
        if (!port) continue;
        auto [it, inserted] = by_port.try_emplace(*port);
        if (inserted) order.push_back(*port);
        Entry& entry = it->second;
        add_unique(entry.friendly_names, record.friendly_name);
        add_unique(entry.instance_ids, record.instance_id);
        for (const auto& id : record.hardware_ids) add_unique(entry.hardware_ids, id);
        std::string source = record.source.empty() ? (synthetic ? "input" : "unknown") : record.source;
        std::size_t begin = 0;
        while (begin <= source.size()) {
            const std::size_t end = std::min(source.find_first_of(",;|", begin), source.size());
            add_unique(entry.sources, source.substr(begin, end - begin));
            begin = end + 1;
        }
    }
    std::stable_sort(order.begin(), order.end(), [](const std::string& a, const std::string& b) {
        return com_number(a) < com_number(b);
    });

    SerialCatalog catalog;
    catalog.registry_status = registry_status;
    catalog.setupapi_status = setupapi_status;
    for (const std::string& name : order) {
        const Entry& entry = by_port[name];
        SerialPort port;
        port.port_name = name;
        port.friendly_name = entry.friendly_names.empty() ? std::string() : entry.friendly_names.front();
        port.instance_id = entry.instance_ids.empty() ? std::string() : entry.instance_ids.front();
        port.hardware_ids = entry.hardware_ids;
        port.sources = entry.sources;
        std::vector<std::string> identity = entry.instance_ids;
        identity.insert(identity.end(), entry.hardware_ids.begin(), entry.hardware_ids.end());
        std::vector<std::string> description = entry.friendly_names;
        description.insert(description.end(), identity.begin(), identity.end());
        const std::string identity_lower = lower_copy(join(identity, ";"));
        const std::string description_text = join(description, " ");
        const std::string d = lower_copy(description_text);
        port.is_hri = icontains(identity_lower, "vid_26aa&pid_0030") || contains_hri_word(description_text);
        port.cat_match_rank = 0;
        port.cat_match_reason = "未识别的串口；可手动选择";
        if (!port.is_hri) {
            if (either_order(d, {"cp2105", "cp210x"}, {"enhanced", "mi_00"})) {
                port.cat_match_rank = 300; port.cat_match_reason = "CP210x Enhanced 串口匹配";
            } else if (either_order(d, {"vid_10c4&pid_ea70"}, {"mi_00"})) {
                port.cat_match_rank = 300; port.cat_match_reason = "Silicon Labs CP2105 Enhanced 接口匹配";
            } else if (either_order(d, {"cp2105"}, {"enhanced"})) {
                port.cat_match_rank = 300; port.cat_match_reason = "CP2105 Enhanced 串口匹配";
            } else if (icontains(d, "cp2105")) {
                port.cat_match_rank = 250; port.cat_match_reason = "CP2105 串口匹配";
            } else if (icontains(d, "cp210x")) {
                port.cat_match_rank = 220; port.cat_match_reason = "CP210x 串口匹配";
            } else if (icontains(d, "vid_10c4")) {
                port.cat_match_rank = 180; port.cat_match_reason = "Silicon Labs 串口匹配";
            } else if (icontains_any(d, {"usb serial", "usb-to-uart", "usb to uart"})) {
                port.cat_match_rank = 100; port.cat_match_reason = "USB 串行接口候选";
            }
        }
        port.is_cat_candidate = !port.is_hri;
        port.confidence = port.is_hri ? "high" : (port.cat_match_rank > 0 ? "medium" : "unknown");
        catalog.serial_ports.push_back(port);
        if (port.is_hri) catalog.hri_ports.push_back(port);
        if (port.is_cat_candidate) catalog.cat_ports.push_back(port);
    }
    const bool any_ready = registry_status == SourceStatus::ready || setupapi_status == SourceStatus::ready;
    catalog.discovery_status = synthetic ? "synthetic"
        : !catalog.serial_ports.empty() ? "ready"
        : any_ready ? "empty" : "failed";
    return catalog;
}

std::vector<SerialPortRecord> read_serialcomm_registry(SourceStatus& status)
{
    std::vector<SerialPortRecord> records;
    HKEY key = nullptr;
    const LSTATUS opened = RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DEVICEMAP\\SERIALCOMM", 0, KEY_READ, &key);
    if (opened == ERROR_FILE_NOT_FOUND) { status = SourceStatus::unavailable; return records; }
    if (opened != ERROR_SUCCESS) { status = SourceStatus::error; return records; }
    status = SourceStatus::ready;
    for (DWORD index = 0;; ++index) {
        std::array<wchar_t, 512> name{};
        std::array<wchar_t, 256> data{};
        DWORD name_length = static_cast<DWORD>(name.size());
        DWORD data_size = static_cast<DWORD>((data.size() - 1) * sizeof(wchar_t));
        DWORD type = 0;
        const LSTATUS result = RegEnumValueW(key, index, name.data(), &name_length, nullptr, &type,
            reinterpret_cast<BYTE*>(data.data()), &data_size);
        if (result == ERROR_NO_MORE_ITEMS) break;
        if (result == ERROR_MORE_DATA) continue;  // not a COM name
        if (result != ERROR_SUCCESS) { status = SourceStatus::error; break; }
        if (type != REG_SZ) continue;
        const auto port = normalize_port_name(to_utf8(data.data()));
        if (!port) continue;
        SerialPortRecord record;
        record.port_name = *port;
        record.source = "registry";
        records.push_back(std::move(record));
    }
    RegCloseKey(key);
    return records;
}

std::vector<SerialPortRecord> read_setupapi_ports(SourceStatus& status)
{
    std::vector<SerialPortRecord> records;
    HDEVINFO set = SetupDiGetClassDevsW(&class_ports_guid, nullptr, nullptr, DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) { status = SourceStatus::error; return records; }
    status = SourceStatus::ready;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA info{};
        info.cbSize = sizeof(info);
        if (!SetupDiEnumDeviceInfo(set, index, &info)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) status = SourceStatus::error;
            break;
        }
        SerialPortRecord record;
        record.source = "setupapi";
        record.friendly_name = to_utf8(property_string(set, info, SPDRP_FRIENDLYNAME));
        std::array<wchar_t, 512> instance{};
        if (SetupDiGetDeviceInstanceIdW(set, &info, instance.data(), static_cast<DWORD>(instance.size()), nullptr)) {
            record.instance_id = to_utf8(instance.data());
        }
        record.port_name = to_utf8(device_port_name(set, info));
        if (const auto ids = device_property(set, info, SPDRP_HARDWAREID)) {
            for (const auto& id : read_multi_sz(*ids)) add_unique(record.hardware_ids, to_utf8(id));
        }
        add_unique(record.hardware_ids, record.instance_id);
        if (!normalize_port_name(record.port_name) && !normalize_port_name(record.friendly_name)) continue;
        records.push_back(std::move(record));
    }
    SetupDiDestroyDeviceInfoList(set);
    return records;
}

SerialCatalog enumerate_serial_ports()
{
    SourceStatus registry = SourceStatus::not_requested;
    SourceStatus setupapi = SourceStatus::not_requested;
    std::vector<SerialPortRecord> records = read_serialcomm_registry(registry);
    std::vector<SerialPortRecord> devices = read_setupapi_ports(setupapi);
    records.insert(records.end(), devices.begin(), devices.end());
    return build_serial_catalog(records, false, registry, setupapi);
}

PortSelection resolve_port_selection(const SerialCatalog& catalog, std::string_view saved_hri_port,
    std::string_view saved_cat_port, std::string_view manual_cat_port, PortSelectionError& error)
{
    error = PortSelectionError::none;
    const auto& hri_ports = catalog.hri_ports;
    const auto& cat_ports = catalog.cat_ports;
    const auto saved_hri = normalize_port_name(saved_hri_port);
    const auto saved_cat = normalize_port_name(saved_cat_port);

    PortSelection selection;
    selection.hri_match_reason = "未发现唯一的 HRI 设备匹配，请手动选择。";
    const auto saved_hri_matches = std::count_if(hri_ports.begin(), hri_ports.end(),
        [&](const SerialPort& p) { return same(normalized(p), saved_hri); });
    if (saved_hri && saved_hri_matches == 1) {
        selection.hri_port = saved_hri;
        selection.hri_match_reason = "沿用已保存且当前存在的 HRI 串口。";
    } else if (hri_ports.size() == 1) {
        selection.hri_port = normalized(hri_ports.front());
        selection.hri_match_reason = "唯一的 HRI 硬件匹配。";
    }
    const auto& hri_port = selection.hri_port;

    selection.cat_match_reason = "没有唯一的已识别 CAT 串口匹配，请手动选择。";
    const auto saved_cat_matches = std::count_if(cat_ports.begin(), cat_ports.end(), [&](const SerialPort& p) {
        const auto name = normalized(p);
        return same(name, saved_cat) && !same(name, hri_port);
    });
    const auto in_hri_ports = [&](const std::optional<std::string>& port) {
        return std::any_of(hri_ports.begin(), hri_ports.end(), [&](const SerialPort& p) { return same(normalized(p), port); });
    };
    const bool saved_cat_is_hri = saved_cat && (same(saved_cat, hri_port) || in_hri_ports(saved_cat));

    const auto manual_cat = normalize_port_name(manual_cat_port);
    if (!is_blank(manual_cat_port)) {
        std::string upper = dotnet_trim(manual_cat_port);
        for (char& c : upper) if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
        const bool shape_ok = manual_cat && manual_cat->size() <= 6;  // ^COM[1-9][0-9]{0,2}$
        if (!shape_ok || *manual_cat != upper) {
            error = PortSelectionError::invalid_manual_cat_port;
            return {};
        }
    }
    const bool manual_cat_is_hri = manual_cat &&
        (same(manual_cat, hri_port) || same(manual_cat, saved_hri) || in_hri_ports(manual_cat));

    if (saved_cat_is_hri) {
        selection.cat_conflict = true;
        selection.cat_match_reason = "已保存的 CAT 端口当前与 HRI 端口相同或被识别为 HRI；拒绝共用，请手动选择其他端口。";
    } else if (manual_cat_is_hri) {
        selection.cat_conflict = true;
        selection.cat_match_reason = "手动 CAT 端口与 HRI 端口相同或被识别为 HRI；拒绝共用，请手动选择其他端口。";
    } else if (manual_cat) {
        selection.cat_port = manual_cat;
        selection.cat_port_source = "manual";
        selection.cat_match_reason = "用户手动输入；当前设备枚举未确认此端口身份。";
    } else if (saved_cat && saved_cat_matches == 1) {
        selection.cat_port = saved_cat;
        selection.cat_match_reason = "沿用已保存且当前存在的 CAT 串口。";
        selection.cat_port_source = "saved";
    } else {
        int best_rank = 0;
        for (const SerialPort& p : cat_ports) {
            if (p.cat_match_rank > 0 && !same(normalized(p), hri_port)) best_rank = std::max(best_rank, p.cat_match_rank);
        }
        if (best_rank > 0) {
            std::vector<const SerialPort*> best;
            for (const SerialPort& p : cat_ports) {
                if (p.cat_match_rank == best_rank && !same(normalized(p), hri_port)) best.push_back(&p);
            }
            if (best.size() == 1) {
                selection.cat_port = normalized(*best.front());
                selection.cat_match_reason = best.front()->cat_match_reason;
                selection.cat_port_source = "matched";
            }
        }
    }
    if (selection.cat_port && hri_port && *selection.cat_port == *hri_port) {
        selection.cat_port.reset();
        selection.cat_match_reason = "CAT 与 HRI 端口不能相同，请手动选择其他 CAT 串口。";
    }
    return selection;
}

std::string default_hri_selection(const SerialCatalog& catalog, std::string_view saved_port)
{
    if (!saved_port.empty() && saved_port != "auto") {
        const SerialPort* match = nullptr;
        int count = 0;
        for (const SerialPort& p : catalog.hri_ports) {
            if (iequals(p.port_name, saved_port)) { match = &p; ++count; }
        }
        return count == 1 ? match->port_name : std::string(saved_port);
    }
    const auto com5 = std::count_if(catalog.hri_ports.begin(), catalog.hri_ports.end(),
        [](const SerialPort& p) { return p.port_name == "COM5"; });
    if (com5 == 1) return "COM5";
    if (catalog.hri_ports.size() == 1) return catalog.hri_ports.front().port_name;
    return "auto";
}

// ---------------------------------------------------------------------------
// Audio

std::vector<WaveDevice> enumerate_wave_devices(Direction direction)
{
    std::vector<WaveDevice> devices;
    const bool input = direction == Direction::capture;
    const UINT count = input ? waveInGetNumDevs() : waveOutGetNumDevs();
    for (UINT id = 0; id < count; ++id) {
        WaveDevice device;
        device.id = id;
        const auto format = pcm_format();
        MMRESULT result = MMSYSERR_ERROR;
        if (input) {
            WAVEINCAPSW caps{};
            result = waveInGetDevCapsW(id, &caps, sizeof(caps));
            if (result == MMSYSERR_NOERROR) device.name = to_utf8(device_name(caps.szPname, MAXPNAMELEN));
            device.pcm_48000_mono_s16_supported = result == MMSYSERR_NOERROR &&
                waveInOpen(nullptr, id, &format, 0, 0, WAVE_FORMAT_QUERY) == MMSYSERR_NOERROR;
        } else {
            WAVEOUTCAPSW caps{};
            result = waveOutGetDevCapsW(id, &caps, sizeof(caps));
            if (result == MMSYSERR_NOERROR) device.name = to_utf8(device_name(caps.szPname, MAXPNAMELEN));
            device.pcm_48000_mono_s16_supported = result == MMSYSERR_NOERROR &&
                waveOutOpen(nullptr, id, &format, 0, 0, WAVE_FORMAT_QUERY) == MMSYSERR_NOERROR;
        }
        if (result == MMSYSERR_NOERROR) {
            if (const auto endpoint = wave_endpoint_id(input, id)) device.endpoint_id = to_utf8(*endpoint);
        }
        devices.push_back(std::move(device));
    }
    return devices;
}

bool enumerate_mm_endpoints(Direction direction, std::vector<AudioEndpoint>& out)
{
    out.clear();
    ComScope com;
    if (!com.usable()) return false;
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
        return false;
    }
    ComPtr<IMMDeviceCollection> collection;
    const EDataFlow flow = direction == Direction::capture ? eCapture : eRender;
    if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &collection))) return false;
    UINT count = 0;
    if (FAILED(collection->GetCount(&count))) return false;
    std::vector<AudioEndpoint> endpoints;
    for (UINT i = 0; i < count; ++i) {
        ComPtr<IMMDevice> device;
        if (FAILED(collection->Item(i, &device))) continue;
        LPWSTR id = nullptr;
        if (FAILED(device->GetId(&id)) || id == nullptr) continue;
        AudioEndpoint endpoint;
        endpoint.endpoint_id = to_utf8(id);
        CoTaskMemFree(id);
        ComPtr<IPropertyStore> store;
        if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store))) {
            PROPVARIANT value;
            PropVariantInit(&value);
            if (SUCCEEDED(store->GetValue(friendly_name_key, &value)) && value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
                endpoint.friendly_name = to_utf8(value.pwszVal);
            }
            PropVariantClear(&value);
        }
        endpoints.push_back(std::move(endpoint));
    }
    out = std::move(endpoints);
    return true;
}

void link_wave_ids(std::vector<AudioEndpoint>& endpoints, const std::vector<WaveDevice>& waves)
{
    for (AudioEndpoint& endpoint : endpoints) endpoint.wave_id = wave_id_for_endpoint(waves, endpoint.endpoint_id);
}

std::optional<std::uint32_t> wave_id_for_endpoint(const std::vector<WaveDevice>& waves, std::string_view endpoint_id)
{
    if (endpoint_id.empty()) return std::nullopt;
    std::optional<std::uint32_t> found;
    for (const WaveDevice& wave : waves) {
        if (wave.endpoint_id && iequals(*wave.endpoint_id, endpoint_id)) {
            if (found) return std::nullopt;  // ambiguous mapping is treated as missing
            found = wave.id;
        }
    }
    return found;
}

AudioCatalog enumerate_audio()
{
    AudioCatalog catalog;
    catalog.wave_inputs = enumerate_wave_devices(Direction::capture);
    catalog.wave_outputs = enumerate_wave_devices(Direction::render);
    const bool capture_ok = enumerate_mm_endpoints(Direction::capture, catalog.capture_endpoints);
    const bool render_ok = enumerate_mm_endpoints(Direction::render, catalog.render_endpoints);
    catalog.mmdevice_ok = capture_ok && render_ok;
    link_wave_ids(catalog.capture_endpoints, catalog.wave_inputs);
    link_wave_ids(catalog.render_endpoints, catalog.wave_outputs);
    return catalog;
}

std::string audio_devices_json(const std::vector<WaveDevice>& inputs, const std::vector<WaveDevice>& outputs)
{
    const auto write = [](std::string& out, const std::vector<WaveDevice>& list) {
        for (std::size_t i = 0; i < list.size(); ++i) {
            if (i != 0) out += ',';
            const WaveDevice& d = list[i];
            out += "{\"id\":" + std::to_string(d.id) + ",\"name\":" + json_escape(d.name) + ",\"endpoint_id\":";
            out += d.endpoint_id ? json_escape(*d.endpoint_id) : std::string("null");
            out += ",\"pcm_48000_mono_s16_supported\":";
            out += d.pcm_48000_mono_s16_supported ? "true" : "false";
            out += '}';
        }
    };
    std::string out = "{\"schema_version\":1,\"type\":\"audio_devices\",\"wave_inputs\":[";
    write(out, inputs);
    out += "],\"wave_outputs\":[";
    write(out, outputs);
    out += "]}\n";
    return out;
}

bool usable(const WaveDevice& device)
{
    return device.pcm_48000_mono_s16_supported && device.endpoint_id && !is_blank(*device.endpoint_id);
}

bool is_usb_audio_name(std::string_view name) { return icontains(lower_copy(name), "usb audio"); }

std::string default_endpoint_selection(const std::vector<WaveDevice>& devices, std::string_view saved_endpoint)
{
    if (!saved_endpoint.empty() && saved_endpoint != "auto") {
        const WaveDevice* match = nullptr;
        int count = 0;
        for (const WaveDevice& d : devices) {
            if (usable(d) && iequals(*d.endpoint_id, saved_endpoint)) { match = &d; ++count; }
        }
        return count == 1 ? *match->endpoint_id : std::string(saved_endpoint);
    }
    const WaveDevice* usb = nullptr;
    int count = 0;
    for (const WaveDevice& d : devices) {
        if (usable(d) && is_usb_audio_name(d.name)) { usb = &d; ++count; }
    }
    return count == 1 ? *usb->endpoint_id : std::string("auto");
}

AudioOutputSelection resolve_audio_output(const std::vector<WaveDevice>& outputs, std::string_view selector)
{
    AudioOutputSelection result;
    const bool automatic = selector.empty() || selector == "auto";
    const WaveDevice* match = nullptr;
    std::size_t count = 0U;
    std::size_t usable_count = 0U;
    const WaveDevice* unique_usable = nullptr;
    for (const WaveDevice& output : outputs) {
        if (!usable(output)) continue;
        ++usable_count;
        unique_usable = &output;
        if (automatic && is_usb_audio_name(output.name)) {
            match = &output;
            ++count;
        } else if (!automatic && iequals(*output.endpoint_id, selector)) {
            match = &output;
            ++count;
        }
    }
    if (automatic && count == 0U && usable_count == 1U) {
        match = unique_usable;
        count = 1U;
    }
    if (count == 1U) {
        result.output = *match;
        return result;
    }
    if (automatic && usable_count == 0U) {
        result.error = AudioResolveError::no_usable_output;
        result.message = "没有可用的 48 kHz 单声道 WaveOut 端点；来话仍会显示，请手动选择输出设备后重试。";
    } else if (automatic) {
        result.error = AudioResolveError::output_not_unique;
        result.message = "发现多个可用的 WaveOut 端点；来话仍会显示，请手动选择输出设备。";
    } else if (count == 0U) {
        result.error = AudioResolveError::saved_output_missing;
        result.message = "已选择的 WaveOut endpoint 当前没有唯一枚举到；来话仍会显示，请刷新设备或手动选择。";
    } else {
        result.error = AudioResolveError::output_not_unique;
        result.message = "选择的 WaveOut endpoint 对应多条设备记录；请刷新设备列表后手动选择。";
    }
    return result;
}

AudioPair resolve_audio_endpoints(const std::vector<WaveDevice>& inputs, const std::vector<WaveDevice>& outputs,
    std::string_view wave_in_selector, std::string_view wave_out_selector, bool hri_identified)
{
    const auto unique_usb = [](const std::vector<WaveDevice>& list) -> std::optional<WaveDevice> {
        std::optional<WaveDevice> found;
        int count = 0;
        for (const WaveDevice& d : list) if (usable(d) && is_usb_audio_name(d.name)) { found = d; ++count; }
        if (count != 1) return std::nullopt;
        return found;
    };
    // Find-UsbAudioNamePair + Get-CompatibleAutoAudioPair.
    std::optional<std::pair<WaveDevice, WaveDevice>> pair;
    if (hri_identified) {
        const auto in = unique_usb(inputs);
        const auto out = unique_usb(outputs);
        if (in && out) pair.emplace(*in, *out);
    }
    const bool in_auto = wave_in_selector == "auto";
    const bool out_auto = wave_out_selector == "auto";
    if (pair && !in_auto && !out_auto) pair.reset();
    if (pair && !in_auto && !iequals(*pair->first.endpoint_id, wave_in_selector)) pair.reset();
    if (pair && !out_auto && !iequals(*pair->second.endpoint_id, wave_out_selector)) pair.reset();

    AudioPair result;
    const auto by_id = [](const std::vector<WaveDevice>& list, std::string_view id) -> std::optional<WaveDevice> {
        std::optional<WaveDevice> found;
        int count = 0;
        for (const WaveDevice& d : list) if (usable(d) && iequals(*d.endpoint_id, id)) { found = d; ++count; }
        if (count != 1) return std::nullopt;
        return found;
    };
    const auto fallback_error = [](const std::vector<WaveDevice>& list, bool input, AudioPair& r) {
        const bool any = std::any_of(list.begin(), list.end(), [](const WaveDevice& d) { return usable(d); });
        if (!any) {
            r.error = input ? AudioResolveError::no_usable_input : AudioResolveError::no_usable_output;
            r.message = input ? "没有可用的 48 kHz WaveIn 端点；请检查电台 USB 音频连接后重试。"
                              : "没有可用的 48 kHz WaveOut 端点；请检查电台 USB 音频连接后重试。";
        } else {
            r.error = input ? AudioResolveError::input_not_unique : AudioResolveError::output_not_unique;
            r.message = input ? "WaveIn endpoint 无法按 USB Audio 关键词唯一确定；请在设置中选择稳定 endpoint ID。"
                              : "WaveOut endpoint 无法按 USB Audio 关键词唯一确定；请在设置中选择稳定 endpoint ID。";
        }
    };

    if (!in_auto) {
        const auto found = by_id(inputs, wave_in_selector);
        if (!found) {
            result.error = AudioResolveError::saved_input_missing;
            result.message = "连接配置指定的 Waveinput endpoint 当前未唯一枚举到；请检查设备后重试。";
            return result;
        }
        result.input = *found;
    } else if (pair) {
        result.input = pair->first;
    } else {
        fallback_error(inputs, true, result);
        return result;
    }
    if (!out_auto) {
        const auto found = by_id(outputs, wave_out_selector);
        if (!found) {
            result.error = AudioResolveError::saved_output_missing;
            result.message = "连接配置指定的 Waveoutput endpoint 当前未唯一枚举到；请检查设备后重试。";
            return result;
        }
        result.output = *found;
    } else if (pair) {
        result.output = pair->second;
    } else {
        fallback_error(outputs, false, result);
        return result;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Endpoint master volume

namespace {

// Event context passed to SetMasterVolumeLevelScalar so watchers can recognize
// changes made by this module. {6F1C2B7E-3D8A-4C55-9E21-57A0B3C4D9F1}
constexpr GUID volume_event_context{0x6f1c2b7e, 0x3d8a, 0x4c55, {0x9e, 0x21, 0x57, 0xa0, 0xb3, 0xc4, 0xd9, 0xf1}};

void set_hr_error(std::string& error, const char* what, HRESULT hr)
{
    char code[16]{};
    std::snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(hr));
    error = std::string(what) + "（HRESULT " + code + "）";
}

// Strict UTF-8 -> UTF-16; rejects empty input, invalid sequences and embedded NUL.
bool endpoint_id_to_wide(std::string_view endpoint_id, std::wstring& out, std::string& error)
{
    out.clear();
    if (endpoint_id.empty()) {
        set_hr_error(error, "音频端点 ID 为空", E_INVALIDARG);
        return false;
    }
    if (endpoint_id.find('\0') != std::string_view::npos ||
        endpoint_id.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        set_hr_error(error, "音频端点 ID 无效", E_INVALIDARG);
        return false;
    }
    const int length = static_cast<int>(endpoint_id.size());
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, endpoint_id.data(), length, nullptr, 0);
    if (required <= 0) {
        set_hr_error(error, "音频端点 ID 不是有效的 UTF-8", HRESULT_FROM_WIN32(GetLastError()));
        return false;
    }
    std::wstring wide(static_cast<std::size_t>(required), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, endpoint_id.data(), length, wide.data(), required) != required) {
        set_hr_error(error, "音频端点 ID 不是有效的 UTF-8", HRESULT_FROM_WIN32(GetLastError()));
        return false;
    }
    out = std::move(wide);
    return true;
}

bool com_ready(const ComScope& com, std::string& error)
{
    if (com.usable()) return true;
    set_hr_error(error, "COM 初始化失败", E_FAIL);
    return false;
}

// Resolves endpoint_id to its IAudioEndpointVolume. COM must be usable on the calling thread.
ComPtr<IAudioEndpointVolume> open_endpoint_volume(std::string_view endpoint_id, std::string& error)
{
    std::wstring wide;
    if (!endpoint_id_to_wide(endpoint_id, wide, error)) return nullptr;
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
        set_hr_error(error, "无法创建 MMDevice 枚举器", hr);
        return nullptr;
    }
    ComPtr<IMMDevice> device;
    hr = enumerator->GetDevice(wide.c_str(), &device);
    if (FAILED(hr) || !device) {
        set_hr_error(error, "找不到音频端点", FAILED(hr) ? hr : E_POINTER);
        return nullptr;
    }
    ComPtr<IAudioEndpointVolume> volume;
    hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
        reinterpret_cast<void**>(volume.GetAddressOf()));
    if (FAILED(hr) || !volume) {
        set_hr_error(error, "无法打开音频端点音量控制", FAILED(hr) ? hr : E_POINTER);
        return nullptr;
    }
    return volume;
}

class VolumeCallback final : public IAudioEndpointVolumeCallback {
public:
    explicit VolumeCallback(std::function<void(const EndpointVolumeChange&)> on_change)
        : on_change_(std::move(on_change)) {}
    VolumeCallback(const VolumeCallback&) = delete;
    VolumeCallback& operator=(const VolumeCallback&) = delete;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override
    {
        if (object == nullptr) return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IAudioEndpointVolumeCallback)) {
            *object = static_cast<IAudioEndpointVolumeCallback*>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override
    {
        const ULONG remaining = --references_;
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE OnNotify(PAUDIO_VOLUME_NOTIFICATION_DATA data) override
    {
        if (data == nullptr) return E_POINTER;
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!on_change_) return S_OK;
            EndpointVolumeChange change;
            change.scalar = std::clamp(data->fMasterVolume, 0.0F, 1.0F);
            change.muted = data->bMuted != FALSE;
            change.self_initiated = IsEqualGUID(data->guidEventContext, volume_event_context) != FALSE;
            on_change_(change);
        } catch (...) {
            // Never let exceptions cross the COM boundary.
        }
        return S_OK;
    }

    // Waits for an in-flight OnNotify to finish; afterwards on_change is never invoked.
    void disable() noexcept
    {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            on_change_ = nullptr;
        } catch (...) {
        }
    }

private:
    ~VolumeCallback() = default;
    std::atomic<ULONG> references_{1};
    std::mutex mutex_;
    std::function<void(const EndpointVolumeChange&)> on_change_;
};

// Releases everything acquired by watch_endpoint_volume, in order.
void release_watch(CO_MTA_USAGE_COOKIE mta, ComPtr<IAudioEndpointVolume>& volume, VolumeCallback* callback,
    bool registered) noexcept
{
    if (registered && volume) (void)volume->UnregisterControlChangeNotify(callback);
    if (callback != nullptr) {
        callback->disable();
        callback->Release();
    }
    volume.Reset();
    if (mta != nullptr) (void)CoDecrementMTAUsage(mta);
}

class EndpointVolumeWatchImpl final : public EndpointVolumeWatch {
public:
    EndpointVolumeWatchImpl(CO_MTA_USAGE_COOKIE mta, ComPtr<IAudioEndpointVolume> volume, VolumeCallback* callback) noexcept
        : mta_(mta), volume_(std::move(volume)), callback_(callback) {}
    EndpointVolumeWatchImpl(const EndpointVolumeWatchImpl&) = delete;
    EndpointVolumeWatchImpl& operator=(const EndpointVolumeWatchImpl&) = delete;
    ~EndpointVolumeWatchImpl() override { release_watch(mta_, volume_, callback_, true); }

private:
    CO_MTA_USAGE_COOKIE mta_{};
    ComPtr<IAudioEndpointVolume> volume_;
    VolumeCallback* callback_{};
};

} // namespace

std::optional<float> get_endpoint_volume(std::string_view endpoint_id, std::string& error)
{
    error.clear();
    ComScope com;
    if (!com_ready(com, error)) return std::nullopt;
    const ComPtr<IAudioEndpointVolume> volume = open_endpoint_volume(endpoint_id, error);
    if (!volume) return std::nullopt;
    float scalar = 0.0F;
    const HRESULT hr = volume->GetMasterVolumeLevelScalar(&scalar);
    if (FAILED(hr)) {
        set_hr_error(error, "读取音频端点音量失败", hr);
        return std::nullopt;
    }
    return std::clamp(scalar, 0.0F, 1.0F);
}

bool set_endpoint_volume(std::string_view endpoint_id, float scalar, std::string& error)
{
    error.clear();
    if (std::isnan(scalar)) {
        set_hr_error(error, "音量值无效", E_INVALIDARG);
        return false;
    }
    const float clamped = std::clamp(scalar, 0.0F, 1.0F);
    ComScope com;
    if (!com_ready(com, error)) return false;
    const ComPtr<IAudioEndpointVolume> volume = open_endpoint_volume(endpoint_id, error);
    if (!volume) return false;
    const HRESULT hr = volume->SetMasterVolumeLevelScalar(clamped, &volume_event_context);
    if (FAILED(hr)) {
        set_hr_error(error, "设置音频端点音量失败", hr);
        return false;
    }
    return true;
}

std::unique_ptr<EndpointVolumeWatch> watch_endpoint_volume(std::string_view endpoint_id,
    std::function<void(const EndpointVolumeChange&)> on_change, std::string& error)
{
    error.clear();
    if (!on_change) {
        set_hr_error(error, "音量变化回调为空", E_INVALIDARG);
        return nullptr;
    }
    ComScope com;
    if (!com_ready(com, error)) return nullptr;
    // Keep the MTA alive for the watch's lifetime, independent of the creating thread.
    CO_MTA_USAGE_COOKIE mta{};
    HRESULT hr = CoIncrementMTAUsage(&mta);
    if (FAILED(hr)) {
        set_hr_error(error, "COM 初始化失败", hr);
        return nullptr;
    }
    ComPtr<IAudioEndpointVolume> volume = open_endpoint_volume(endpoint_id, error);
    if (!volume) {
        release_watch(mta, volume, nullptr, false);
        return nullptr;
    }
    VolumeCallback* callback = nullptr;
    try {
        callback = new VolumeCallback(std::move(on_change));
    } catch (...) {
        release_watch(mta, volume, nullptr, false);
        set_hr_error(error, "内存不足", E_OUTOFMEMORY);
        return nullptr;
    }
    hr = volume->RegisterControlChangeNotify(callback);
    if (FAILED(hr)) {
        release_watch(mta, volume, callback, false);
        set_hr_error(error, "注册音频端点音量通知失败", hr);
        return nullptr;
    }
    try {
        return std::make_unique<EndpointVolumeWatchImpl>(mta, std::move(volume), callback);
    } catch (...) {
        release_watch(mta, volume, callback, true);
        set_hr_error(error, "内存不足", E_OUTOFMEMORY);
        return nullptr;
    }
}

} // namespace wirex::app::devices
