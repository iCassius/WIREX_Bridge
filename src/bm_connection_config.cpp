#include "wirex/bm_connection_config.hpp"

#include <algorithm>

namespace wirex::bm_connection_config {
namespace {

bool valid_master_name(std::string_view host) noexcept
{
    if (host.empty() || host.size() > 253U) return false;
    bool numeric_dotted = true;
    std::size_t dot_count = 0U;
    for (const unsigned char ch : host) {
        if (ch == '.') {
            ++dot_count;
        } else if (ch < '0' || ch > '9') {
            numeric_dotted = false;
        }
        if (ch > 0x7eU || ch <= 0x20U) return false;
    }
    if (numeric_dotted) {
        if (dot_count != 3U) return false;
        std::size_t offset = 0U;
        for (std::size_t octet = 0U; octet < 4U; ++octet) {
            const auto separator = host.find('.', offset);
            const auto end = separator == std::string_view::npos ? host.size() : separator;
            const auto part = host.substr(offset, end - offset);
            if (part.empty() || part.size() > 3U) return false;
            std::uint32_t value = 0U;
            for (const char ch : part) {
                if (ch < '0' || ch > '9') return false;
                value = (value * 10U) + static_cast<unsigned>(ch - '0');
            }
            if (value > 255U) return false;
            if (octet == 3U) return end == host.size();
            if (separator == std::string_view::npos) return false;
            offset = separator + 1U;
        }
        return false;
    }

    if (host.back() == '.') host.remove_suffix(1U);
    if (host.empty()) return false;
    std::size_t offset = 0U;
    while (offset < host.size()) {
        const auto separator = host.find('.', offset);
        const auto end = separator == std::string_view::npos ? host.size() : separator;
        const auto label = host.substr(offset, end - offset);
        if (label.empty() || label.size() > 63U) return false;
        for (std::size_t index = 0U; index < label.size(); ++index) {
            const unsigned char ch = static_cast<unsigned char>(label[index]);
            const bool alphanumeric = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9');
            if (!alphanumeric && ch != '-') return false;
            if (ch == '-' && (index == 0U || index + 1U == label.size())) return false;
        }
        if (separator == std::string_view::npos) return true;
        offset = separator + 1U;
    }
    return false;
}

} // namespace

bool parse_decimal_u32(std::string_view text, std::uint32_t& value) noexcept
{
    if (text.empty()) return false;
    std::uint64_t parsed = 0U;
    for (const char ch : text) {
        if (ch < '0' || ch > '9') return false;
        const auto digit = static_cast<std::uint64_t>(ch - '0');
        if (parsed > (0xffffffffU - digit) / 10U) return false;
        parsed = (parsed * 10U) + digit;
    }
    value = static_cast<std::uint32_t>(parsed);
    return true;
}

bool any_field_seen(const std::array<bool, 9U>& seen) noexcept
{
    return std::any_of(seen.begin(), seen.end(), [](bool value) { return value; });
}

bool all_fields_seen(const std::array<bool, 9U>& seen) noexcept
{
    return std::all_of(seen.begin(), seen.end(), [](bool value) { return value; });
}

bool validate(const Fields& fields) noexcept
{
    if (fields.callsign.empty() || fields.callsign.size() > 8U || fields.gateway_id == 0U ||
        fields.gateway_id > 0xffffffffU || fields.source_id == 0U || fields.source_id > 0xffffffU ||
        fields.destination_id == 0U || fields.destination_id > 0xffffffU ||
        (fields.slot != 1U && fields.slot != 2U) || fields.color_code > 15U ||
        fields.master.empty() || fields.master.size() > 253U || fields.master_port == 0U ||
        fields.master_port > 65535U || !valid_master_name(fields.master) ||
        (fields.call_kind != "G" && fields.call_kind != "P")) {
        return false;
    }
    for (const unsigned char ch : fields.callsign) {
        if (ch < 0x20U || ch > 0x7eU) return false;
    }
    return true;
}

bool parse_receive_target(std::string_view destination_id,
                          std::string_view slot,
                          std::string_view call_kind,
                          ReceiveTarget& target) noexcept
{
    std::uint32_t parsed_destination = 0U;
    std::uint32_t parsed_slot = 0U;
    if (!parse_decimal_u32(destination_id, parsed_destination) ||
        !parse_decimal_u32(slot, parsed_slot) ||
        parsed_destination == 0U || parsed_destination > 0x00ffffffU ||
        (parsed_slot != 1U && parsed_slot != 2U) ||
        (call_kind != "G" && call_kind != "P")) {
        return false;
    }
    target.destination_id = parsed_destination;
    target.slot = static_cast<std::uint8_t>(parsed_slot);
    target.call_kind = call_kind.front();
    return true;
}

} // namespace wirex::bm_connection_config
