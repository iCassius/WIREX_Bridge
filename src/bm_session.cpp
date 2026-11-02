#include "wirex/bm_session.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <limits>
#include <utility>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>

namespace wirex::bm {
namespace {

constexpr std::uint64_t login_retry_ms = 10000U;
constexpr std::uint64_t login_timeout_ms = 60000U;
constexpr std::uint64_t keepalive_interval_ms = 10000U;
constexpr std::uint64_t keepalive_timeout_ms = 60000U;
constexpr std::size_t max_password_size = 256U;
constexpr std::size_t max_options_size = 292U;

std::uint64_t after(std::uint64_t now_ms, std::uint64_t duration_ms) noexcept
{
    const auto max_value = std::numeric_limits<std::uint64_t>::max();
    return now_ms > max_value - duration_ms ? max_value : now_ms + duration_ms;
}

void secure_erase(void* memory, std::size_t size) noexcept
{
    if (memory == nullptr) {
        return;
    }
    SecureZeroMemory(memory, size);
}

void secure_erase(std::string& value) noexcept
{
    if (!value.empty()) {
        secure_erase(&value[0], value.size());
    }
    value.clear();
}

void secure_erase(std::vector<std::uint8_t>& value) noexcept
{
    if (!value.empty()) {
        secure_erase(value.data(), value.size());
    }
    value.clear();
}

bool is_printable_ascii(const std::string& value) noexcept
{
    return std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return ch >= 0x20U && ch <= 0x7eU;
    });
}

bool append_fixed(std::vector<std::uint8_t>& packet,
                  const std::string& value,
                  std::size_t width)
{
    if (value.size() > width || !is_printable_ascii(value)) {
        return false;
    }
    packet.insert(packet.end(), value.begin(), value.end());
    packet.insert(packet.end(), width - value.size(), static_cast<std::uint8_t>(' '));
    return true;
}

bool append_zero_padded(std::vector<std::uint8_t>& packet,
                        std::uint32_t value,
                        std::size_t width)
{
    std::array<char, 16> digits{};
    const auto conversion = std::to_chars(digits.data(), digits.data() + digits.size(), value);
    if (conversion.ec != std::errc{}) {
        return false;
    }
    const auto length = static_cast<std::size_t>(conversion.ptr - digits.data());
    if (length > width) {
        return false;
    }
    packet.insert(packet.end(), width - length, static_cast<std::uint8_t>('0'));
    packet.insert(packet.end(), digits.begin(), digits.begin() + static_cast<std::ptrdiff_t>(length));
    return true;
}

void append_id(std::vector<std::uint8_t>& packet, std::uint32_t gateway_id)
{
    packet.push_back(static_cast<std::uint8_t>((gateway_id >> 24U) & 0xffU));
    packet.push_back(static_cast<std::uint8_t>((gateway_id >> 16U) & 0xffU));
    packet.push_back(static_cast<std::uint8_t>((gateway_id >> 8U) & 0xffU));
    packet.push_back(static_cast<std::uint8_t>(gateway_id & 0xffU));
}

bool id_matches(const std::uint8_t* bytes, std::uint32_t gateway_id) noexcept
{
    return bytes[0] == static_cast<std::uint8_t>((gateway_id >> 24U) & 0xffU) &&
           bytes[1] == static_cast<std::uint8_t>((gateway_id >> 16U) & 0xffU) &&
           bytes[2] == static_cast<std::uint8_t>((gateway_id >> 8U) & 0xffU) &&
           bytes[3] == static_cast<std::uint8_t>(gateway_id & 0xffU);
}

bool starts_with(const std::uint8_t* bytes,
                 std::size_t size,
                 const char* marker,
                 std::size_t marker_size) noexcept
{
    if (bytes == nullptr || size < marker_size) {
        return false;
    }
    for (std::size_t i = 0; i < marker_size; ++i) {
        if (bytes[i] != static_cast<std::uint8_t>(marker[i])) {
            return false;
        }
    }
    return true;
}

bool valid_dmrd(const std::uint8_t* bytes, std::size_t size) noexcept
{
    return bytes != nullptr && size == dmrd_datagram_size &&
           starts_with(bytes, size, "DMRD", 4U);
}

} // 命名空间

bool Endpoint::operator==(const Endpoint& other) const noexcept
{
    return address == other.address && port == other.port;
}

bool Endpoint::operator!=(const Endpoint& other) const noexcept
{
    return !(*this == other);
}

Session::~Session()
{
    clear_secret();
    clear_last_control_packet();
    for (auto& item : outbound_) {
        secure_erase(item.bytes);
    }
}

bool Session::validate_profile(const Profile& profile) const noexcept
{
    return profile.gateway_id != 0U &&
           !profile.password.empty() && profile.password.size() <= max_password_size &&
           !profile.callsign.empty() && profile.callsign.size() <= 8U &&
           is_printable_ascii(profile.callsign) &&
           profile.rx_frequency <= 999999999U && profile.tx_frequency <= 999999999U &&
           profile.power <= 99U && profile.color_code <= 15U &&
           profile.latitude.size() <= 8U && is_printable_ascii(profile.latitude) &&
           profile.longitude.size() <= 9U && is_printable_ascii(profile.longitude) &&
           profile.height <= 999U && profile.location.size() <= 20U &&
           is_printable_ascii(profile.location) && profile.description.size() <= 19U &&
           is_printable_ascii(profile.description) &&
           (profile.slot_flags == '0' || profile.slot_flags == '1' ||
            profile.slot_flags == '2' || profile.slot_flags == '3' ||
            profile.slot_flags == '4') &&
           profile.url.size() <= 124U && is_printable_ascii(profile.url) &&
           profile.version.size() <= 40U && is_printable_ascii(profile.version) &&
           profile.software.size() <= 40U && is_printable_ascii(profile.software) &&
           profile.options.size() <= max_options_size && is_printable_ascii(profile.options);
}

bool Session::start(Profile&& profile, const Endpoint& master, std::uint64_t now_ms)
{
    if ((state_ != State::idle && state_ != State::stopped) || master.port == 0U ||
        master.address == std::array<std::uint8_t, 4>{{0U, 0U, 0U, 0U}} ||
        !validate_profile(profile)) {
        secure_erase(profile.password);
        last_failure_ = Failure::invalid_profile;
        return false;
    }

    if (state_ == State::stopped) {
        clear_application_queues();
        for (auto& item : outbound_) secure_erase(item.bytes);
        outbound_.clear();
        clear_last_control_packet();
        challenge_salt_.fill(0U);
        has_challenge_salt_ = false;
        phase_deadline_ms_ = 0U;
        next_retry_ms_ = 0U;
        retry_at_ms_ = 0U;
        last_pong_ms_ = 0U;
        next_ping_ms_ = 0U;
        consecutive_failures_ = 0U;
        last_failure_ = Failure::none;
    }
    clear_rtt();

    // 将凭据复制到唯一的运行期缓冲区，随后清除调用方结构中的原始内容。
    password_ = profile.password;
    secure_erase(profile.password);
    profile_ = std::move(profile);
    secure_erase(profile_.password);
    master_ = master;
    begin_login(now_ms);
    return state_ == State::waiting_login_ack;
}

void Session::begin_login(std::uint64_t now_ms)
{
    std::vector<std::uint8_t> packet;
    if (!make_login_packet(packet)) {
        enter_backoff(Failure::invalid_profile, now_ms);
        return;
    }
    set_waiting_state(State::waiting_login_ack, std::move(packet), now_ms);
}

bool Session::make_login_packet(std::vector<std::uint8_t>& packet) const
{
    packet.clear();
    packet.reserve(8U);
    packet.insert(packet.end(), {'R', 'P', 'T', 'L'});
    append_id(packet, profile_.gateway_id);
    return true;
}

bool Session::make_auth_packet(const std::uint8_t* salt,
                               std::vector<std::uint8_t>& packet)
{
    if (salt == nullptr || password_.empty() || password_.size() > max_password_size) {
        return false;
    }

    std::vector<std::uint8_t> hash_input;
    hash_input.reserve(4U + password_.size());
    hash_input.insert(hash_input.end(), salt, salt + 4U);
    hash_input.insert(hash_input.end(), password_.begin(), password_.end());

    std::array<std::uint8_t, 32> digest{};
    BCRYPT_ALG_HANDLE algorithm{};
    BCRYPT_HASH_HANDLE hash{};
    DWORD object_size{};
    DWORD bytes_written{};
    std::vector<std::uint8_t> hash_object;
    bool success = false;

    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0U) >= 0 &&
        BCryptGetProperty(algorithm,
                          BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&object_size),
                          sizeof(object_size),
                          &bytes_written,
                          0U) >= 0 &&
        object_size > 0U) {
        hash_object.resize(object_size);
        if (BCryptCreateHash(algorithm,
                             &hash,
                             hash_object.data(),
                             object_size,
                             nullptr,
                             0U,
                             0U) >= 0 &&
            BCryptHashData(hash,
                           hash_input.data(),
                           static_cast<ULONG>(hash_input.size()),
                           0U) >= 0 &&
            BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0U) >= 0) {
            success = true;
        }
    }

    if (hash != nullptr) {
        BCryptDestroyHash(hash);
    }
    if (algorithm != nullptr) {
        BCryptCloseAlgorithmProvider(algorithm, 0U);
    }
    secure_erase(hash_input.data(), hash_input.size());
    secure_erase(hash_object);
    if (!success) {
        secure_erase(digest.data(), digest.size());
        return false;
    }

    packet.clear();
    packet.reserve(40U);
    packet.insert(packet.end(), {'R', 'P', 'T', 'K'});
    append_id(packet, profile_.gateway_id);
    packet.insert(packet.end(), digest.begin(), digest.end());
    secure_erase(digest.data(), digest.size());
    return true;
}

bool Session::make_config_packet(std::vector<std::uint8_t>& packet) const
{
    packet.clear();
    packet.reserve(302U);
    packet.insert(packet.end(), {'R', 'P', 'T', 'C'});
    append_id(packet, profile_.gateway_id);

    const auto power = std::to_string(profile_.power);
    const auto color_code = std::to_string(profile_.color_code);
    const auto height = std::to_string(profile_.height);
    if (!append_fixed(packet, profile_.callsign, 8U) ||
        !append_zero_padded(packet, profile_.rx_frequency, 9U) ||
        !append_zero_padded(packet, profile_.tx_frequency, 9U) ||
        !append_fixed(packet, power.size() == 1U ? "0" + power : power, 2U) ||
        !append_fixed(packet,
                      color_code.size() == 1U ? "0" + color_code : color_code,
                      2U) ||
        !append_fixed(packet, profile_.latitude, 8U) ||
        !append_fixed(packet, profile_.longitude, 9U) ||
        !append_fixed(packet, height.size() == 1U ? "00" + height
                        : height.size() == 2U ? "0" + height
                                              : height,
                      3U) ||
        !append_fixed(packet, profile_.location, 20U) ||
        !append_fixed(packet, profile_.description, 19U)) {
        return false;
    }
    packet.push_back(static_cast<std::uint8_t>(profile_.slot_flags));
    if (!append_fixed(packet, profile_.url, 124U) ||
        !append_fixed(packet, profile_.version, 40U) ||
        !append_fixed(packet, profile_.software, 40U)) {
        return false;
    }
    return packet.size() == 302U;
}

bool Session::make_options_packet(std::vector<std::uint8_t>& packet) const
{
    if (profile_.options.empty() || profile_.options.size() > max_options_size ||
        !is_printable_ascii(profile_.options)) {
        return false;
    }
    packet.clear();
    packet.reserve(8U + profile_.options.size());
    packet.insert(packet.end(), {'R', 'P', 'T', 'O'});
    append_id(packet, profile_.gateway_id);
    packet.insert(packet.end(), profile_.options.begin(), profile_.options.end());
    return true;
}

void Session::set_waiting_state(State state,
                                std::vector<std::uint8_t>&& packet,
                                std::uint64_t now_ms)
{
    clear_last_control_packet();
    last_control_packet_ = std::move(packet);
    state_ = state;
    phase_deadline_ms_ = after(now_ms, login_timeout_ms);
    next_retry_ms_ = after(now_ms, login_retry_ms);
    if (!queue_control(std::vector<std::uint8_t>(last_control_packet_))) {
        enter_backoff(Failure::outbound_queue_full, now_ms);
    }
}

bool Session::queue_control(std::vector<std::uint8_t>&& packet)
{
    if (outbound_.size() >= max_queued_datagrams) {
        secure_erase(packet);
        return false;
    }
    outbound_.push_back(OutboundDatagram{master_, std::move(packet), PacketKind::control});
    return true;
}

InputResult Session::on_datagram(const std::uint8_t* bytes,
                                 std::size_t size,
                                 const Endpoint& source,
                                 std::uint64_t now_ms)
{
    if (source != master_) {
        return InputResult::ignored_wrong_endpoint;
    }
    if (state_ == State::idle || state_ == State::stopped) {
        return InputResult::rejected_wrong_state;
    }
    if (bytes == nullptr || size == 0U) {
        enter_backoff(Failure::malformed_response, now_ms);
        return InputResult::rejected_malformed;
    }

    if (starts_with(bytes, size, "MSTNAK", 6U)) {
        if (size == 10U && !id_matches(bytes + 6U, profile_.gateway_id)) {
            enter_backoff(Failure::wrong_peer_id, now_ms);
            return InputResult::rejected_malformed;
        }
        if (size != 6U && size != 10U) {
            enter_backoff(Failure::malformed_response, now_ms);
            return InputResult::rejected_malformed;
        }
        enter_backoff(Failure::master_rejected, now_ms);
        return InputResult::master_rejected;
    }
    if (starts_with(bytes, size, "MSTCL", 5U)) {
        if (size == 9U && !id_matches(bytes + 5U, profile_.gateway_id)) {
            enter_backoff(Failure::wrong_peer_id, now_ms);
            return InputResult::rejected_malformed;
        }
        if (size != 5U && size != 9U) {
            enter_backoff(Failure::malformed_response, now_ms);
            return InputResult::rejected_malformed;
        }
        enter_backoff(Failure::master_closed, now_ms);
        return InputResult::master_closed;
    }

    if (starts_with(bytes, size, "RPTACK", 6U)) {
        if (state_ == State::waiting_login_ack) {
            // 固定的 MMDVM_CM 源码从 [6..9] 读取 salt，但不检查总长度。
            // 本实现只接受恰好 10 字节的 challenge；后续确认允许 6 字节兼容形式，
            // 或附带且匹配 gateway ID 的 10 字节形式。
            if (size != 10U) {
                enter_backoff(Failure::malformed_response, now_ms);
                return InputResult::rejected_malformed;
            }
            std::copy(bytes + 6U, bytes + 10U, challenge_salt_.begin());
            has_challenge_salt_ = true;
            std::vector<std::uint8_t> auth_packet;
            if (!make_auth_packet(bytes + 6U, auth_packet)) {
                enter_backoff(Failure::authentication_error, now_ms);
                return InputResult::rejected_malformed;
            }
            set_waiting_state(State::waiting_auth_ack, std::move(auth_packet), now_ms);
            return InputResult::accepted;
        }
        if (state_ == State::waiting_auth_ack) {
            if (size == 10U && has_challenge_salt_ &&
                std::equal(challenge_salt_.begin(), challenge_salt_.end(), bytes + 6U)) {
                return InputResult::ignored_duplicate_ack;
            }
            if (size == 10U && !id_matches(bytes + 6U, profile_.gateway_id)) {
                enter_backoff(Failure::wrong_peer_id, now_ms);
                return InputResult::rejected_malformed;
            }
            if (size != 6U && size != 10U) {
                enter_backoff(Failure::malformed_response, now_ms);
                return InputResult::rejected_malformed;
            }
            std::vector<std::uint8_t> config_packet;
            if (!make_config_packet(config_packet)) {
                enter_backoff(Failure::invalid_profile, now_ms);
                return InputResult::rejected_malformed;
            }
            set_waiting_state(State::waiting_config_ack, std::move(config_packet), now_ms);
            return InputResult::accepted;
        }
        if (state_ == State::waiting_config_ack) {
            if (size == 10U && !id_matches(bytes + 6U, profile_.gateway_id)) {
                enter_backoff(Failure::wrong_peer_id, now_ms);
                return InputResult::rejected_malformed;
            }
            if (size != 6U && size != 10U) {
                enter_backoff(Failure::malformed_response, now_ms);
                return InputResult::rejected_malformed;
            }
            if (profile_.options.empty()) {
                state_ = State::ready;
                clear_last_control_packet();
                consecutive_failures_ = 0U;
                last_failure_ = Failure::none;
                last_pong_ms_ = now_ms;
                next_ping_ms_ = after(now_ms, keepalive_interval_ms);
                return InputResult::accepted;
            }
            std::vector<std::uint8_t> options_packet;
            if (!make_options_packet(options_packet)) {
                enter_backoff(Failure::invalid_profile, now_ms);
                return InputResult::rejected_malformed;
            }
            set_waiting_state(State::waiting_options_ack, std::move(options_packet), now_ms);
            return InputResult::accepted;
        }
        if (state_ == State::waiting_options_ack) {
            if (size == 10U && !id_matches(bytes + 6U, profile_.gateway_id)) {
                enter_backoff(Failure::wrong_peer_id, now_ms);
                return InputResult::rejected_malformed;
            }
            if (size != 6U && size != 10U) {
                enter_backoff(Failure::malformed_response, now_ms);
                return InputResult::rejected_malformed;
            }
            state_ = State::ready;
            clear_last_control_packet();
            consecutive_failures_ = 0U;
            last_failure_ = Failure::none;
            last_pong_ms_ = now_ms;
            next_ping_ms_ = after(now_ms, keepalive_interval_ms);
            return InputResult::accepted;
        }
        if (state_ == State::ready) {
            if (size == 10U && has_challenge_salt_ &&
                std::equal(challenge_salt_.begin(), challenge_salt_.end(), bytes + 6U)) {
                return InputResult::ignored_duplicate_ack;
            }
            if (size == 10U && !id_matches(bytes + 6U, profile_.gateway_id)) {
                enter_backoff(Failure::wrong_peer_id, now_ms);
                return InputResult::rejected_malformed;
            }
            if (size == 6U || size == 10U) {
                return InputResult::ignored_duplicate_ack;
            }
            enter_backoff(Failure::malformed_response, now_ms);
            return InputResult::rejected_malformed;
        }
        enter_backoff(Failure::unexpected_response, now_ms);
        return InputResult::rejected_wrong_state;
    }

    if (starts_with(bytes, size, "MSTPONG", 7U)) {
        if (state_ != State::ready) {
            enter_backoff(Failure::unexpected_response, now_ms);
            return InputResult::rejected_wrong_state;
        }
        if (size != 11U) {
            enter_backoff(Failure::malformed_response, now_ms);
            return InputResult::rejected_malformed;
        }
        if (!id_matches(bytes + 7U, profile_.gateway_id)) {
            enter_backoff(Failure::wrong_peer_id, now_ms);
            return InputResult::rejected_malformed;
        }
        last_pong_ms_ = now_ms;
        if (rtt_pending_) {
            if (now_ms >= rtt_sent_at_ms_ && now_ms < rtt_expires_at_ms_) {
                const auto sample = now_ms - rtt_sent_at_ms_;
                rtt_last_ms_ = sample;
                if (rtt_sample_count_ == 0U || sample < rtt_min_ms_) rtt_min_ms_ = sample;
                if (rtt_sample_count_ == 0U || sample > rtt_max_ms_) rtt_max_ms_ = sample;
                if (rtt_sum_ms_ <= std::numeric_limits<std::uint64_t>::max() - sample) {
                    rtt_sum_ms_ += sample;
                } else {
                    rtt_sum_ms_ = std::numeric_limits<std::uint64_t>::max();
                }
                if (rtt_sample_count_ != std::numeric_limits<std::uint64_t>::max()) {
                    ++rtt_sample_count_;
                }
            }
            rtt_pending_ = false;
        }
        return InputResult::accepted;
    }

    if (starts_with(bytes, size, "DMRD", 4U)) {
        if (state_ != State::ready) {
            return InputResult::rejected_wrong_state;
        }
        if (!valid_dmrd(bytes, size)) {
            enter_backoff(Failure::malformed_response, now_ms);
            return InputResult::rejected_malformed;
        }
        if (inbound_.size() >= max_queued_datagrams) {
            enter_backoff(Failure::inbound_queue_full, now_ms);
            return InputResult::rejected_application_queue_full;
        }
        ApplicationDatagram datagram{};
        datagram.source = source;
        std::copy(bytes, bytes + size, datagram.bytes.begin());
        inbound_.push_back(std::move(datagram));
        return InputResult::application_datagram;
    }

    return InputResult::ignored_unknown_packet;
}

void Session::tick(std::uint64_t now_ms)
{
    if (state_ == State::backoff) {
        if (now_ms >= retry_at_ms_) {
            begin_login(now_ms);
        }
        return;
    }

    if (state_ == State::ready) {
        if (now_ms >= after(last_pong_ms_, keepalive_timeout_ms)) {
            enter_backoff(Failure::pong_timeout, now_ms);
            return;
        }
        if (rtt_pending_ && now_ms >= rtt_expires_at_ms_) {
            rtt_pending_ = false;
        }
        if (now_ms >= next_ping_ms_) {
            if (rtt_pending_) {
                next_ping_ms_ = rtt_expires_at_ms_;
                return;
            }
            std::vector<std::uint8_t> ping;
            ping.reserve(11U);
            ping.insert(ping.end(), {'R', 'P', 'T', 'P', 'I', 'N', 'G'});
            append_id(ping, profile_.gateway_id);
            if (outbound_.size() >= max_queued_datagrams) {
                enter_backoff(Failure::outbound_queue_full, now_ms);
                return;
            }
            outbound_.push_back(OutboundDatagram{master_, std::move(ping), PacketKind::keepalive});
            next_ping_ms_ = after(now_ms, keepalive_interval_ms);
        }
        return;
    }

    if (state_ != State::waiting_login_ack && state_ != State::waiting_auth_ack &&
        state_ != State::waiting_config_ack && state_ != State::waiting_options_ack) {
        return;
    }
    if (now_ms >= phase_deadline_ms_) {
        enter_backoff(timeout_failure(), now_ms);
        return;
    }
    if (now_ms >= next_retry_ms_) {
        if (!queue_control(std::vector<std::uint8_t>(last_control_packet_))) {
            enter_backoff(Failure::outbound_queue_full, now_ms);
            return;
        }
        next_retry_ms_ = after(now_ms, login_retry_ms);
    }
}

void Session::transport_lost(std::uint64_t now_ms)
{
    if (state_ != State::idle && state_ != State::stopped && state_ != State::backoff) {
        enter_backoff(Failure::transport_lost, now_ms);
    }
}

void Session::stop(std::uint64_t)
{
    if (state_ == State::stopped) {
        clear_secret();
        return;
    }

    const bool was_ready = state_ == State::ready;
    clear_rtt();
    clear_application_queues();
    for (auto& item : outbound_) {
        secure_erase(item.bytes);
    }
    outbound_.clear();
    clear_last_control_packet();
    challenge_salt_.fill(0U);
    has_challenge_salt_ = false;

    if (was_ready) {
        std::vector<std::uint8_t> close_packet;
        close_packet.reserve(9U);
        close_packet.insert(close_packet.end(), {'R', 'P', 'T', 'C', 'L'});
        append_id(close_packet, profile_.gateway_id);
        outbound_.push_back(OutboundDatagram{master_, std::move(close_packet), PacketKind::control});
    }
    clear_secret();
    state_ = State::stopped;
}

void Session::record_outbound_sent(const OutboundDatagram& packet,
                                   std::uint64_t now_ms) noexcept
{
    if (packet.kind != PacketKind::keepalive || state_ != State::ready ||
        packet.target != master_ || packet.bytes.size() != 11U ||
        !starts_with(packet.bytes.data(), packet.bytes.size(), "RPTPING", 7U) ||
        !id_matches(packet.bytes.data() + 7U, profile_.gateway_id)) {
        return;
    }
    if (rtt_pending_ && now_ms < rtt_expires_at_ms_) return;
    rtt_pending_ = true;
    rtt_sent_at_ms_ = now_ms;
    rtt_expires_at_ms_ = after(now_ms, keepalive_interval_ms);
}

bool Session::send_dmrd(const std::uint8_t* bytes,
                        std::size_t size,
                        std::uint64_t now_ms)
{
    (void)now_ms;
    if (state_ != State::ready || !valid_dmrd(bytes, size)) {
        return false;
    }
    if (outbound_.size() >= max_queued_datagrams) {
        enter_backoff(Failure::outbound_queue_full, now_ms);
        return false;
    }
    std::vector<std::uint8_t> packet(bytes, bytes + size);
    outbound_.push_back(OutboundDatagram{master_, std::move(packet), PacketKind::application});
    return true;
}

std::optional<ApplicationDatagram> Session::take_received_dmrd()
{
    if (inbound_.empty()) {
        return std::nullopt;
    }
    auto datagram = std::move(inbound_.front());
    inbound_.pop_front();
    return datagram;
}

std::vector<OutboundDatagram> Session::take_outbound()
{
    std::vector<OutboundDatagram> packets;
    packets.reserve(outbound_.size());
    while (!outbound_.empty()) {
        packets.push_back(std::move(outbound_.front()));
        outbound_.pop_front();
    }
    return packets;
}

Snapshot Session::snapshot() const noexcept
{
    Snapshot result{state_,
                    last_failure_,
                    state_ == State::backoff ? retry_at_ms_
                    : state_ == State::ready ? next_ping_ms_
                    : state_ == State::idle || state_ == State::stopped ? 0U
                                                                        : next_retry_ms_,
                    outbound_.size(),
                    inbound_.size(),
                    consecutive_failures_};
    result.rtt_valid = rtt_sample_count_ != 0U;
    result.rtt_last_ms = rtt_last_ms_;
    result.rtt_sample_count = rtt_sample_count_;
    result.rtt_min_ms = rtt_min_ms_;
    result.rtt_avg_ms = rtt_sample_count_ == 0U
        ? 0.0
        : static_cast<double>(rtt_sum_ms_) / static_cast<double>(rtt_sample_count_);
    result.rtt_max_ms = rtt_max_ms_;
    return result;
}

void Session::enter_backoff(Failure failure, std::uint64_t now_ms)
{
    if (state_ == State::stopped || state_ == State::idle) {
        return;
    }
    clear_application_queues();
    clear_rtt();
    for (auto& item : outbound_) {
        secure_erase(item.bytes);
    }
    outbound_.clear();
    clear_last_control_packet();
    challenge_salt_.fill(0U);
    has_challenge_salt_ = false;
    last_failure_ = failure;
    if (consecutive_failures_ < std::numeric_limits<std::uint32_t>::max()) {
        ++consecutive_failures_;
    }
    const auto exponent = std::min<std::uint32_t>(consecutive_failures_ - 1U, 5U);
    const auto delay_ms = std::min<std::uint64_t>(1000ULL << exponent, 30000ULL);
    retry_at_ms_ = after(now_ms, delay_ms);
    state_ = State::backoff;
}

void Session::clear_application_queues() noexcept
{
    inbound_.clear();
    for (auto iterator = outbound_.begin(); iterator != outbound_.end();) {
        if (iterator->kind == PacketKind::application) {
            secure_erase(iterator->bytes);
            iterator = outbound_.erase(iterator);
        } else {
            ++iterator;
        }
    }
}

void Session::clear_secret() noexcept
{
    secure_erase(password_);
}

void Session::clear_last_control_packet() noexcept
{
    secure_erase(last_control_packet_);
}

void Session::clear_rtt() noexcept
{
    rtt_pending_ = false;
    rtt_sent_at_ms_ = 0U;
    rtt_expires_at_ms_ = 0U;
    rtt_last_ms_ = 0U;
    rtt_sample_count_ = 0U;
    rtt_min_ms_ = 0U;
    rtt_max_ms_ = 0U;
    rtt_sum_ms_ = 0U;
}

Failure Session::timeout_failure() const noexcept
{
    switch (state_) {
    case State::waiting_login_ack:
        return Failure::login_timeout;
    case State::waiting_auth_ack:
        return Failure::auth_timeout;
    case State::waiting_config_ack:
        return Failure::config_timeout;
    case State::waiting_options_ack:
        return Failure::options_timeout;
    default:
        return Failure::none;
    }
}

} // 命名空间 wirex::bm
