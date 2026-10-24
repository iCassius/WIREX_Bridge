#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>

#include "wirex/bm_udp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

using wirex::bm::Endpoint;
using wirex::bm::InputResult;
using wirex::bm::Profile;
using wirex::bm::ReceiveKind;
using wirex::bm::Session;
using wirex::bm::State;
using wirex::bm::UdpTransport;

constexpr std::uint32_t gateway_id = 0x129abcdeU;

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

Endpoint endpoint_from(const sockaddr_in& address)
{
    Endpoint result{};
    std::copy_n(reinterpret_cast<const std::uint8_t*>(&address.sin_addr.s_addr),
                4U,
                result.address.begin());
    result.port = ntohs(address.sin_port);
    return result;
}

sockaddr_in sockaddr_from(const Endpoint& endpoint)
{
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(endpoint.port);
    std::copy(endpoint.address.begin(),
              endpoint.address.end(),
              reinterpret_cast<std::uint8_t*>(&address.sin_addr.s_addr));
    return address;
}

class FakeMaster final {
public:
    FakeMaster()
    {
        WSADATA data{};
        check(WSAStartup(MAKEWORD(2, 2), &data) == 0, "start Winsock for loopback fake Master");
        winsock_started_ = true;
        socket_ = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        check(socket_ != INVALID_SOCKET, "create loopback fake Master UDP socket");

        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_port = 0U;
        check(inet_pton(AF_INET, "127.0.0.1", &local.sin_addr) == 1,
              "encode fake Master loopback address");
        check(::bind(socket_, reinterpret_cast<const sockaddr*>(&local), sizeof(local)) !=
                  SOCKET_ERROR,
              "bind fake Master to localhost only");

        int local_size = static_cast<int>(sizeof(local));
        check(getsockname(socket_, reinterpret_cast<sockaddr*>(&local), &local_size) !=
                  SOCKET_ERROR,
              "read fake Master loopback port");
        endpoint_ = endpoint_from(local);
    }

    FakeMaster(const FakeMaster&) = delete;
    FakeMaster& operator=(const FakeMaster&) = delete;

    ~FakeMaster()
    {
        close();
    }

    [[nodiscard]] Endpoint endpoint() const noexcept { return endpoint_; }
    [[nodiscard]] bool is_open() const noexcept { return socket_ != INVALID_SOCKET; }

    void close() noexcept
    {
        if (socket_ != INVALID_SOCKET) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
        }
        if (winsock_started_) {
            WSACleanup();
            winsock_started_ = false;
        }
    }

    bool send(const Endpoint& target, const std::vector<std::uint8_t>& bytes)
    {
        if (!is_open() || bytes.empty()) {
            return false;
        }
        const auto address = sockaddr_from(target);
        const int sent = sendto(socket_,
                                reinterpret_cast<const char*>(bytes.data()),
                                static_cast<int>(bytes.size()),
                                0,
                                reinterpret_cast<const sockaddr*>(&address),
                                sizeof(address));
        return sent == static_cast<int>(bytes.size());
    }

    bool receive(std::vector<std::uint8_t>& bytes,
                 Endpoint& source,
                 std::uint32_t wait_ms = 500U)
    {
        if (!is_open()) {
            return false;
        }
        fd_set readable{};
        FD_ZERO(&readable);
        FD_SET(socket_, &readable);
        timeval timeout{};
        timeout.tv_sec = static_cast<long>(wait_ms / 1000U);
        timeout.tv_usec = static_cast<long>((wait_ms % 1000U) * 1000U);
        if (select(0, &readable, nullptr, nullptr, &timeout) <= 0) {
            return false;
        }
        std::array<std::uint8_t, 4096> buffer{};
        sockaddr_in remote{};
        int remote_size = static_cast<int>(sizeof(remote));
        const int received = recvfrom(socket_,
                                      reinterpret_cast<char*>(buffer.data()),
                                      static_cast<int>(buffer.size()),
                                      0,
                                      reinterpret_cast<sockaddr*>(&remote),
                                      &remote_size);
        if (received == SOCKET_ERROR || remote_size != static_cast<int>(sizeof(remote))) {
            return false;
        }
        bytes.assign(buffer.begin(), buffer.begin() + received);
        source = endpoint_from(remote);
        return true;
    }

private:
    SOCKET socket_{INVALID_SOCKET};
    Endpoint endpoint_{};
    bool winsock_started_{};
};

std::vector<std::uint8_t> bytes(const char* text)
{
    const std::string value(text);
    return {value.begin(), value.end()};
}

void append_id(std::vector<std::uint8_t>& packet, std::uint32_t id)
{
    packet.push_back(static_cast<std::uint8_t>((id >> 24U) & 0xffU));
    packet.push_back(static_cast<std::uint8_t>((id >> 16U) & 0xffU));
    packet.push_back(static_cast<std::uint8_t>((id >> 8U) & 0xffU));
    packet.push_back(static_cast<std::uint8_t>(id & 0xffU));
}

std::vector<std::uint8_t> challenge()
{
    auto packet = bytes("RPTACK");
    packet.insert(packet.end(), {1U, 2U, 3U, 4U});
    return packet;
}

std::vector<std::uint8_t> acknowledgement()
{
    auto packet = bytes("RPTACK");
    append_id(packet, gateway_id);
    return packet;
}

Profile test_profile()
{
    Profile profile{};
    profile.gateway_id = gateway_id;
    profile.password = "test-bm-pass";
    profile.callsign = "N0CALL";
    profile.rx_frequency = 449000000U;
    profile.tx_frequency = 444000000U;
    profile.power = 25U;
    profile.color_code = 1U;
    profile.latitude = "38.0000";
    profile.longitude = "-095.000";
    profile.height = 75U;
    profile.location = "Loopback Lab";
    profile.description = "Offline test";
    profile.slot_flags = '4';
    profile.url = "https://example.invalid";
    profile.version = "test-version";
    profile.software = "WIREX-BM-Test";
    return profile;
}

void send_pending(Session& session, UdpTransport& transport)
{
    for (const auto& item : session.take_outbound()) {
        check(item.target.port != 0U, "outbound datagram has a target endpoint");
        check(transport.send(item.bytes.data(), item.bytes.size()),
              "WinSock transport sends a session datagram");
    }
}

std::vector<std::uint8_t> receive_from_fake(FakeMaster& fake, Endpoint& client)
{
    std::vector<std::uint8_t> received;
    check(fake.receive(received, client), "fake Master receives a bounded UDP datagram");
    return received;
}

void receive_at_client(UdpTransport& client,
                       Session& session,
                       std::uint64_t now_ms,
                       InputResult expected)
{
    const auto received = client.receive(1000U);
    check(received.kind == ReceiveKind::datagram, "client receives fake Master datagram");
    check(session.on_datagram(received.bytes.data(),
                              received.bytes.size(),
                              received.source,
                              now_ms) == expected,
          "state machine reports the expected fake Master packet result");
}

Endpoint establish(FakeMaster& fake, UdpTransport& client, Session& session)
{
    check(client.open(fake.endpoint()), "open WinSock client socket to loopback fake Master");
    auto profile = test_profile();
    check(session.start(std::move(profile), fake.endpoint(), 0U),
          "start fake Master session with offline test credential");
    send_pending(session, client);

    Endpoint client_endpoint{};
    const auto login = receive_from_fake(fake, client_endpoint);
    check(login.size() == 8U && std::string(login.begin(), login.begin() + 4) == "RPTL",
          "fake Master receives exact RPTL");
    check(fake.send(client_endpoint, challenge()), "fake Master sends challenge from loopback");
    receive_at_client(client, session, 1U, InputResult::accepted);
    send_pending(session, client);

    const auto auth = receive_from_fake(fake, client_endpoint);
    check(auth.size() == 40U && std::string(auth.begin(), auth.begin() + 4) == "RPTK",
          "fake Master receives exact RPTK");
    check(auth[8] == 0x82U && auth[39] == 0x14U,
          "fake Master receives the precomputed password hash vector");
    check(fake.send(client_endpoint, acknowledgement()),
          "fake Master sends matching 10-byte authentication acknowledgement");
    receive_at_client(client, session, 2U, InputResult::accepted);
    send_pending(session, client);

    const auto config = receive_from_fake(fake, client_endpoint);
    check(config.size() == 302U && std::string(config.begin(), config.begin() + 4) == "RPTC",
          "fake Master receives exact RPTC configuration");
    check(fake.send(client_endpoint, acknowledgement()),
          "fake Master sends matching 10-byte configuration acknowledgement");
    receive_at_client(client, session, 3U, InputResult::accepted);
    check(session.snapshot().state == State::ready,
          "loopback session reports ready only after Master configuration acknowledgement");
    return client_endpoint;
}

void test_loopback_handshake_and_transport_bounds()
{
    FakeMaster fake;
    UdpTransport client;
    Session session;
    const auto client_endpoint = establish(fake, client, session);

    const auto start = std::chrono::steady_clock::now();
    const auto timeout = client.receive(5000U);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    check(timeout.kind == ReceiveKind::timeout,
          "real WinSock receive reports socket timeout with no fake Master response");
    check(elapsed.count() < 500,
          "requested multi-second receive is clamped to the 100 ms transport bound");

    UdpTransport rogue;
    check(rogue.open(client_endpoint), "open rogue loopback sender toward client endpoint");
    std::vector<std::uint8_t> pong = bytes("MSTPONG");
    append_id(pong, gateway_id);
    check(rogue.send(pong.data(), pong.size()), "rogue transport sends a valid-looking pong");
    const auto wrong_source = client.receive(1000U);
    check(wrong_source.kind == ReceiveKind::datagram,
          "client receives rogue datagram for source verification");
    check(session.on_datagram(wrong_source.bytes.data(),
                              wrong_source.bytes.size(),
                              wrong_source.source,
                              5U) == InputResult::ignored_wrong_endpoint,
          "state machine rejects a valid-looking packet from another UDP endpoint");
    check(session.snapshot().state == State::ready,
          "wrong source cannot change a ready session");

    std::vector<std::uint8_t> oversized(3000U, 0x5aU);
    check(fake.send(client_endpoint, oversized), "fake Master sends oversized local datagram");
    const auto oversized_result = client.receive(1000U);
    check(oversized_result.kind == ReceiveKind::oversized_datagram,
          "WinSock transport rejects a datagram larger than its receive buffer");
    check(oversized_result.source == fake.endpoint(),
          "oversized datagram still reports the source endpoint for session validation");
    check(session.on_datagram(nullptr, 0U, oversized_result.source, 4U) ==
              InputResult::rejected_malformed,
          "oversized input is treated as malformed by the state machine");
    check(session.snapshot().state == State::backoff,
          "malformed loopback packet enters backoff and does not keep ready state");
}

void test_rejection_and_malformed_challenge()
{
    {
        FakeMaster fake;
        UdpTransport client;
        Session session;
        check(client.open(fake.endpoint()), "open transport for rejection test");
        auto profile = test_profile();
        check(session.start(std::move(profile), fake.endpoint(), 0U),
              "start session for rejection test");
        send_pending(session, client);
        Endpoint client_endpoint{};
        const auto login = receive_from_fake(fake, client_endpoint);
        check(login.size() == 8U, "fake Master receives login before rejection");
        auto nak = bytes("MSTNAK");
        append_id(nak, gateway_id);
        check(fake.send(client_endpoint, nak), "fake Master sends 10-byte ID-bearing MSTNAK");
        receive_at_client(client, session, 1U, InputResult::master_rejected);
        check(session.snapshot().state == State::backoff,
              "Master rejection enters bounded reconnect backoff");
    }

    {
        FakeMaster fake;
        UdpTransport client;
        Session session;
        check(client.open(fake.endpoint()), "open transport for malformed challenge test");
        auto profile = test_profile();
        check(session.start(std::move(profile), fake.endpoint(), 0U),
              "start session for malformed challenge test");
        send_pending(session, client);
        Endpoint client_endpoint{};
        const auto login = receive_from_fake(fake, client_endpoint);
        check(login.size() == 8U, "fake Master receives login before malformed challenge");
        auto malformed = challenge();
        malformed.pop_back();
        check(fake.send(client_endpoint, malformed), "fake Master sends 9-byte malformed challenge");
        receive_at_client(client, session, 1U, InputResult::rejected_malformed);
        check(session.snapshot().state == State::backoff,
              "malformed challenge never advances to authentication");
    }
}

void test_disconnect_and_orderly_exit()
{
    {
        FakeMaster fake;
        UdpTransport client;
        Session session;
        (void)establish(fake, client, session);
        std::array<std::uint8_t, wirex::bm::dmrd_datagram_size> dmrd{};
        std::copy_n("DMRD", 4U, dmrd.begin());
        check(session.send_dmrd(dmrd.data(), dmrd.size(), 4U),
              "queue application frame before fake Master disconnect");
        fake.close();
        const auto no_reply = client.receive(25U);
        check(no_reply.kind == ReceiveKind::timeout,
              "closed fake Master produces a real UDP receive timeout");
        session.tick(60003U);
        check(session.snapshot().state == State::backoff,
              "missing keepalive response moves disconnected session to backoff");
        check(session.snapshot().queued_outbound == 0U,
              "disconnect clears queued DMRD so old voice cannot replay after reconnect");
    }

    {
        FakeMaster fake;
        UdpTransport client;
        Session session;
        const auto client_endpoint = establish(fake, client, session);
        session.stop(4U);
        check(session.snapshot().state == State::stopped,
              "orderly exit moves session to stopped");
        const auto close_packets = session.take_outbound();
        check(close_packets.size() == 1U && close_packets[0].bytes.size() == 9U,
              "orderly exit queues one RPTCL close packet");
        check(client.send(close_packets[0].bytes.data(), close_packets[0].bytes.size()),
              "WinSock transport sends RPTCL before socket close");
        Endpoint source{};
        const auto close_at_fake = receive_from_fake(fake, source);
        check(close_at_fake == close_packets[0].bytes && source == client_endpoint,
              "fake Master observes exact RPTCL from the session's UDP endpoint");
        client.close();
        check(client.receive(0U).kind == ReceiveKind::closed,
              "closed WinSock transport reports closed without blocking");
        check(!client.send(close_at_fake.data(), close_at_fake.size()),
              "closed transport rejects subsequent sends");
    }
}

} // 命名空间

int main()
{
    test_loopback_handshake_and_transport_bounds();
    test_rejection_and_malformed_challenge();
    test_disconnect_and_orderly_exit();
    std::cout << "All BM loopback UDP checks passed.\n";
    return EXIT_SUCCESS;
}
