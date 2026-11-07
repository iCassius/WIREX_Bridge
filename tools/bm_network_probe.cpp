/*
 * BM 4602 真实网络诊断器。
 *
 * 仅显式传入 --run-network-only 时，才会向源码内固定的 BM 4602 IPv4 地址发送
 * Homebrew 控制包，整个会话最多 15 秒。它读取仓库根目录
 * private/bm-device-password.txt，并使用
 * 生产 Session/UdpTransport；发送 RPTL、RPTK、RPTC 和 RPTPING 心跳，只有
 * Session ready 后才发送 RPTCL。它不打开 COM/WinMM，不操作 PTT/RF，不发送 RPTO、TG、DMRD
 * 或语音，不写入日志文件。
 *
 * 无参数或 --help 只显示用法，不读密码、不创建 socket。只有显式的
 * --run-network-only 参数会启动真实网络诊断。不要把它加入通用 builder、自动
 * 测试或默认启动流程。未来手动执行前，必须核对固定目标与用户授权。应从 Git
 * 根目录运行。
 */
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include "wirex/bm_session.hpp"
#include "wirex/bm_network_metadata.hpp"
#include "wirex/bm_udp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace {

using wirex::bm::Endpoint;
using wirex::bm::Failure;
using wirex::bm::InputResult;
using wirex::bm::OutboundDatagram;
using wirex::bm::PacketKind;
using wirex::bm::Profile;
using wirex::bm::Session;
using wirex::bm::Snapshot;
using wirex::bm::State;
using wirex::bm::UdpTransport;

constexpr std::uint32_t gateway_id = 460999901U;
constexpr std::uint32_t deadline_ms = 15000U;
constexpr char password_file[] = "private/bm-device-password.txt";
constexpr std::uintmax_t max_password_file_bytes = 258U;

void erase_bytes(void* memory, std::size_t size) noexcept
{
    if (memory != nullptr && size != 0U) {
        SecureZeroMemory(memory, size);
    }
}

void erase_string(std::string& value) noexcept
{
    if (!value.empty()) {
        erase_bytes(&value[0], value.size());
    }
    value.clear();
}

bool read_password(std::string& password)
{
    const auto path = std::filesystem::absolute(password_file);
    std::error_code file_size_error;
    const auto file_size = std::filesystem::file_size(path, file_size_error);
    if (file_size_error || file_size > max_password_file_bytes) {
        return false;
    }

    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return false;
    }
    std::array<char, max_password_file_bytes + 1U> password_bytes{};
    input.read(password_bytes.data(), static_cast<std::streamsize>(password_bytes.size()));
    const auto bytes_read = static_cast<std::size_t>(input.gcount());
    if (input.bad() || bytes_read > max_password_file_bytes) {
        erase_bytes(password_bytes.data(), password_bytes.size());
        return false;
    }
    password.assign(password_bytes.data(), bytes_read);
    erase_bytes(password_bytes.data(), password_bytes.size());
    while (!password.empty() && (password.back() == '\r' || password.back() == '\n')) {
        password.pop_back();
    }
    if (password.empty() || password.size() > 256U) {
        erase_string(password);
        return false;
    }
    for (const unsigned char ch : password) {
        if (ch < 0x20U || ch > 0x7eU) {
            erase_string(password);
            return false;
        }
    }
    return true;
}

void print_usage()
{
    std::cout << "Usage: bm_network_probe.exe [--help | --run-network-only]\n"
                 "No arguments or --help only print this message.\n"
                 "--run-network-only sends bounded control traffic to the fixed BM 4602 target.\n";
}

const char* state_name(State state) noexcept
{
    switch (state) {
    case State::idle: return "idle";
    case State::waiting_login_ack: return "waiting_login_ack";
    case State::waiting_auth_ack: return "waiting_auth_ack";
    case State::waiting_config_ack: return "waiting_config_ack";
    case State::waiting_options_ack: return "waiting_options_ack";
    case State::ready: return "ready";
    case State::backoff: return "backoff";
    case State::stopped: return "stopped";
    }
    return "unknown";
}

const char* failure_name(Failure failure) noexcept
{
    switch (failure) {
    case Failure::none: return "none";
    case Failure::invalid_profile: return "invalid_profile";
    case Failure::login_timeout: return "login_timeout";
    case Failure::auth_timeout: return "auth_timeout";
    case Failure::config_timeout: return "config_timeout";
    case Failure::options_timeout: return "options_timeout";
    case Failure::pong_timeout: return "pong_timeout";
    case Failure::master_rejected: return "master_rejected";
    case Failure::master_closed: return "master_closed";
    case Failure::malformed_response: return "malformed_response";
    case Failure::unexpected_response: return "unexpected_response";
    case Failure::wrong_peer_id: return "wrong_peer_id";
    case Failure::authentication_error: return "authentication_error";
    case Failure::inbound_queue_full: return "inbound_queue_full";
    case Failure::transport_lost: return "transport_lost";
    case Failure::outbound_queue_full: return "outbound_queue_full";
    }
    return "unknown";
}

const char* input_result_name(InputResult result) noexcept
{
    switch (result) {
    case InputResult::accepted: return "accepted";
    case InputResult::application_datagram: return "application_datagram";
    case InputResult::ignored_wrong_endpoint: return "ignored_wrong_endpoint";
    case InputResult::ignored_unknown_packet: return "ignored_unknown_packet";
    case InputResult::rejected_wrong_state: return "rejected_wrong_state";
    case InputResult::rejected_malformed: return "rejected_malformed";
    case InputResult::rejected_application_queue_full: return "rejected_application_queue_full";
    case InputResult::ignored_duplicate_ack: return "ignored_duplicate_ack";
    case InputResult::master_rejected: return "master_rejected";
    case InputResult::master_closed: return "master_closed";
    }
    return "unknown";
}

std::string_view prefix(const std::uint8_t* bytes, std::size_t size) noexcept
{
    const auto matches = [bytes, size](std::string_view tag) {
        return bytes != nullptr && size >= tag.size() &&
               std::equal(tag.begin(), tag.end(), bytes);
    };
    // RPTCL 与 RPTC 共享前四字节，先识别完整的 9 字节关闭包。
    constexpr std::array<std::string_view, 16> known{{
        "MSTPONG", "RPTPING", "RPTPONG", "MSTACK", "MSTNAK", "MSTCL",
        "RPTACK", "RPTL", "RPTK", "RPTCL", "RPTC", "RPTO", "DMRD", "DMRA",
        "DMRG", "UNKNOWN"
    }};
    for (const auto tag : known) {
        if (tag != "UNKNOWN" && matches(tag)) {
            return tag;
        }
    }
    return "UNKNOWN";
}

std::uint64_t elapsed_ms(std::chrono::steady_clock::time_point origin) noexcept
{
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - origin).count());
}

void emit_snapshot(const Snapshot& snapshot)
{
    std::cout << "STATE " << state_name(snapshot.state)
              << " Failure=" << failure_name(snapshot.last_failure) << '\n';
}

void emit_ack_metadata(const std::vector<std::uint8_t>& bytes,
                       State before,
                       std::array<std::uint8_t, 4>& salt,
                       bool& has_salt)
{
    if (bytes.size() != 10U ||
        !std::equal(bytes.begin(), bytes.begin() + 6, "RPTACK")) {
        return;
    }
    const auto payload = bytes.data() + 6U;
    if (before == State::waiting_login_ack) {
        std::copy_n(payload, salt.size(), salt.begin());
        has_salt = true;
        std::cout << "ACK_META kind=challenge\n";
        return;
    }
    if (before == State::waiting_auth_ack) {
        const bool matches_salt = has_salt &&
            std::equal(salt.begin(), salt.end(), payload);
        const std::array<std::uint8_t, 4> expected_id{{
            static_cast<std::uint8_t>((gateway_id >> 24U) & 0xffU),
            static_cast<std::uint8_t>((gateway_id >> 16U) & 0xffU),
            static_cast<std::uint8_t>((gateway_id >> 8U) & 0xffU),
            static_cast<std::uint8_t>(gateway_id & 0xffU)
        }};
        const bool matches_gateway = std::equal(expected_id.begin(), expected_id.end(), payload);
        std::cout << "ACK_META matches_salt=" << (matches_salt ? "true" : "false")
                  << " matches_gateway=" << (matches_gateway ? "true" : "false") << '\n';
        return;
    }
    if (before == State::waiting_config_ack || before == State::waiting_options_ack) {
        const std::array<std::uint8_t, 4> expected_id{{
            static_cast<std::uint8_t>((gateway_id >> 24U) & 0xffU),
            static_cast<std::uint8_t>((gateway_id >> 16U) & 0xffU),
            static_cast<std::uint8_t>((gateway_id >> 8U) & 0xffU),
            static_cast<std::uint8_t>(gateway_id & 0xffU)
        }};
        const bool matches_gateway = std::equal(expected_id.begin(), expected_id.end(), payload);
        std::cout << "ACK_META matches_gateway=" << (matches_gateway ? "true" : "false") << '\n';
    }
}

bool send_queued(Session& session,
                 UdpTransport& transport,
                 std::set<std::string>& sent_prefixes,
                 std::chrono::steady_clock::time_point origin)
{
    auto outbound = session.take_outbound();
    for (auto& item : outbound) {
        const auto tag = prefix(item.bytes.data(), item.bytes.size());
        const std::string tag_string(tag);
        const bool is_control = item.kind == PacketKind::control;
        const bool is_keepalive = item.kind == PacketKind::keepalive;
        if ((!is_control && !is_keepalive) || tag == "UNKNOWN" ||
            (is_control && !sent_prefixes.insert(tag_string).second)) {
            if (!item.bytes.empty()) {
                erase_bytes(item.bytes.data(), item.bytes.size());
            }
            continue;
        }
        std::cout << "TX prefix=" << tag << " len=" << item.bytes.size() << '\n';
        const bool sent = transport.send(item.bytes.data(), item.bytes.size());
        if (!sent) {
            if (!item.bytes.empty()) {
                erase_bytes(item.bytes.data(), item.bytes.size());
            }
            std::cout << "TX_RESULT prefix=" << tag << " result=failed\n";
            session.transport_lost(elapsed_ms(origin));
            return false;
        }
        session.record_outbound_sent(item, elapsed_ms(origin));
        if (!item.bytes.empty()) {
            erase_bytes(item.bytes.data(), item.bytes.size());
        }
        std::cout << "TX_RESULT prefix=" << tag << " result=sent\n";
    }
    return true;
}

} // namespace

int main(int argc, char* argv[])
{
    if (argc == 1 || (argc == 2 && std::string_view(argv[1]) == "--help")) {
        print_usage();
        return 0;
    }
    if (argc != 2 || std::string_view(argv[1]) != "--run-network-only") {
        print_usage();
        return 2;
    }

    Profile profile{};
    std::string password;
    if (!read_password(password)) {
        return 2;
    }
    profile.gateway_id = gateway_id;
    profile.password = std::move(password);
    erase_string(password);
    profile.callsign = "N0CALL";
    wirex::bm::apply_network_metadata(profile);
    profile.color_code = 1U;

    const Endpoint master{{43U, 129U, 83U, 124U}, 62031U};
    UdpTransport transport;
    if (!transport.open(master)) {
        erase_string(profile.password);
        return 3;
    }

    Session session;
    const auto origin = std::chrono::steady_clock::now();
    if (!session.start(std::move(profile), master, 0U)) {
        emit_snapshot(session.snapshot());
        transport.close();
        return 4;
    }

    std::array<std::uint8_t, 4> challenge_salt{};
    bool has_challenge_salt = false;
    std::set<std::string> sent_prefixes;
    emit_snapshot(session.snapshot());
    if (!send_queued(session, transport, sent_prefixes, origin)) {
        emit_snapshot(session.snapshot());
        transport.close();
        return 5;
    }

    int exit_code = 6;
    while (elapsed_ms(origin) < deadline_ms) {
        const auto now = elapsed_ms(origin);
        session.tick(now);
        auto snapshot = session.snapshot();
        if (snapshot.state == State::backoff) {
            emit_snapshot(snapshot);
            exit_code = 7;
            break;
        }
        if (snapshot.state == State::ready) {
            session.stop(now);
            const bool queued_sends_succeeded =
                send_queued(session, transport, sent_prefixes, origin);
            const bool close_sent = queued_sends_succeeded &&
                sent_prefixes.find("RPTCL") != sent_prefixes.end();
            emit_snapshot(session.snapshot());
            if (!close_sent) {
                std::cout << "RPTCL_RESULT result=not_sent\n";
            }
            exit_code = close_sent ? 0 : 5;
            break;
        }
        if (!send_queued(session, transport, sent_prefixes, origin)) {
            emit_snapshot(session.snapshot());
            exit_code = 5;
            break;
        }

        const auto remaining = deadline_ms - static_cast<std::uint32_t>(now);
        const auto received = transport.receive(std::min<std::uint32_t>(remaining, UdpTransport::max_wait_ms));
        if (received.kind == wirex::bm::ReceiveKind::timeout) {
            continue;
        }
        if (received.kind != wirex::bm::ReceiveKind::datagram) {
            session.transport_lost(elapsed_ms(origin));
            emit_snapshot(session.snapshot());
            exit_code = 5;
            break;
        }

        const auto tag = prefix(received.bytes.data(), received.bytes.size());
        std::cout << "RX prefix=" << tag << " len=" << received.bytes.size() << '\n';
        if (tag == "DMRD") {
            const auto result = session.on_datagram(received.bytes.data(), received.bytes.size(),
                                                    received.source, elapsed_ms(origin));
            std::cout << "INPUT_RESULT " << input_result_name(result) << '\n';
            emit_snapshot(session.snapshot());
            exit_code = 8;
            break;
        }

        const auto before = session.snapshot().state;
        emit_ack_metadata(received.bytes, before, challenge_salt, has_challenge_salt);
        const auto result = session.on_datagram(received.bytes.data(), received.bytes.size(),
                                                received.source, elapsed_ms(origin));
        std::cout << "INPUT_RESULT " << input_result_name(result) << '\n';
        snapshot = session.snapshot();
        emit_snapshot(snapshot);
        if (snapshot.state == State::backoff) {
            exit_code = 7;
            break;
        }
        if (snapshot.state == State::ready) {
            session.stop(elapsed_ms(origin));
            const bool queued_sends_succeeded =
                send_queued(session, transport, sent_prefixes, origin);
            const bool close_sent = queued_sends_succeeded &&
                sent_prefixes.find("RPTCL") != sent_prefixes.end();
            emit_snapshot(session.snapshot());
            if (!close_sent) {
                std::cout << "RPTCL_RESULT result=not_sent\n";
            }
            exit_code = close_sent ? 0 : 5;
            break;
        }
        if (!send_queued(session, transport, sent_prefixes, origin)) {
            emit_snapshot(session.snapshot());
            exit_code = 5;
            break;
        }
    }

    if (exit_code == 6) {
        emit_snapshot(session.snapshot());
    }
    erase_bytes(challenge_salt.data(), challenge_salt.size());
    session.stop(elapsed_ms(origin));
    transport.close();
    return exit_code;
}
