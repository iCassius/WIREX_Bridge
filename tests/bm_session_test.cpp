#include "wirex/bm_session.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

using wirex::bm::Endpoint;
using wirex::bm::Failure;
using wirex::bm::InputResult;
using wirex::bm::PacketKind;
using wirex::bm::Profile;
using wirex::bm::Session;
using wirex::bm::State;

constexpr std::uint32_t gateway_id = 0x129abcdeU;
const Endpoint master{{127U, 0U, 0U, 1U}, 62001U};
const Endpoint other{{127U, 0U, 0U, 1U}, 62002U};

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::vector<std::uint8_t> packet(const char* text)
{
    const std::string value(text);
    return {value.begin(), value.end()};
}

void append_id(std::vector<std::uint8_t>& bytes, std::uint32_t id)
{
    bytes.push_back(static_cast<std::uint8_t>((id >> 24U) & 0xffU));
    bytes.push_back(static_cast<std::uint8_t>((id >> 16U) & 0xffU));
    bytes.push_back(static_cast<std::uint8_t>((id >> 8U) & 0xffU));
    bytes.push_back(static_cast<std::uint8_t>(id & 0xffU));
}

std::vector<std::uint8_t> acknowledgement(std::uint32_t id)
{
    auto bytes = packet("RPTACK");
    append_id(bytes, id);
    return bytes;
}

std::vector<std::uint8_t> challenge()
{
    auto bytes = packet("RPTACK");
    bytes.insert(bytes.end(), {1U, 2U, 3U, 4U});
    return bytes;
}

Profile profile(std::string options = {})
{
    Profile value{};
    value.gateway_id = gateway_id;
    value.password = "test-bm-pass";
    value.callsign = "N0CALL";
    value.rx_frequency = 449000000U;
    value.tx_frequency = 444000000U;
    value.power = 25U;
    value.color_code = 1U;
    value.latitude = "38.0000";
    value.longitude = "-095.000";
    value.height = 75U;
    value.location = "Loopback Lab";
    value.description = "Offline test";
    value.slot_flags = '4';
    value.url = "https://example.invalid";
    value.version = "test-version";
    value.software = "WIREX-BM-Test";
    value.options = std::move(options);
    return value;
}

std::vector<wirex::bm::OutboundDatagram> start(Session& session,
                                               std::string options = {},
                                               std::uint64_t now_ms = 0U)
{
    auto value = profile(std::move(options));
    check(session.start(std::move(value), master, now_ms), "start valid local session");
    check(session.snapshot().state == State::waiting_login_ack, "wait for login challenge");
    return session.take_outbound();
}

void check_config_packet(const std::vector<std::uint8_t>& bytes)
{
    check(bytes.size() == 302U, "RPTC has exactly 302 bytes");
    check(std::string(bytes.begin(), bytes.begin() + 4) == "RPTC", "RPTC marker");
    check(bytes[4] == 0x12U && bytes[5] == 0x9aU && bytes[6] == 0xbcU &&
              bytes[7] == 0xdeU,
          "RPTC gateway ID uses big-endian bytes");
    check(std::string(bytes.begin() + 8, bytes.begin() + 16) == "N0CALL  ",
          "RPTC callsign is left-padded to its fixed width");
    check(std::string(bytes.begin() + 16, bytes.begin() + 25) == "449000000",
          "RPTC receive frequency has nine decimal digits");
    check(std::string(bytes.begin() + 25, bytes.begin() + 34) == "444000000",
          "RPTC transmit frequency has nine decimal digits");
    check(std::string(bytes.begin() + 34, bytes.begin() + 38) == "2501",
          "RPTC power and color code use two decimal digits");
    check(bytes[97] == static_cast<std::uint8_t>('4'), "RPTC slot flags offset");
    check(std::string(bytes.begin() + 222, bytes.begin() + 234) == "test-version",
          "RPTC software version offset");
    check(std::string(bytes.begin() + 262, bytes.begin() + 275) == "WIREX-BM-Test",
          "RPTC software name offset");
}

void test_login_hash_and_ready()
{
    Session session;
    const auto login = start(session);
    check(login.size() == 1U && login[0].bytes.size() == 8U,
          "start emits one 8-byte RPTL");
    check(login[0].target == master && login[0].kind == PacketKind::control,
          "RPTL targets only configured Master endpoint");
    check(std::string(login[0].bytes.begin(), login[0].bytes.begin() + 4) == "RPTL",
          "RPTL marker");
    check(login[0].bytes[4] == 0x12U && login[0].bytes[5] == 0x9aU &&
              login[0].bytes[6] == 0xbcU && login[0].bytes[7] == 0xdeU,
          "RPTL gateway ID uses big-endian bytes");

    const auto salt = challenge();
    check(session.on_datagram(salt.data(), salt.size(), other, 1U) ==
              InputResult::ignored_wrong_endpoint,
          "challenge from a different source endpoint is ignored");
    check(session.snapshot().state == State::waiting_login_ack,
          "wrong endpoint cannot advance login");
    check(session.on_datagram(salt.data(), salt.size(), master, 2U) == InputResult::accepted,
          "exact 10-byte RPTACK challenge accepted");
    check(session.snapshot().state == State::waiting_auth_ack,
          "challenge moves session to auth acknowledgement");

    const auto auth = session.take_outbound();
    check(auth.size() == 1U && auth[0].bytes.size() == 40U,
          "challenge emits exact 40-byte RPTK");
    check(std::string(auth[0].bytes.begin(), auth[0].bytes.begin() + 4) == "RPTK",
          "RPTK marker");
    const std::array<std::uint8_t, 32> expected_hash{{
        0x82U, 0xf9U, 0x4cU, 0xc2U, 0x58U, 0x35U, 0xe9U, 0xb2U,
        0xbaU, 0xe6U, 0x09U, 0x45U, 0xebU, 0xd5U, 0xd7U, 0xb1U,
        0x88U, 0xf9U, 0x40U, 0xe1U, 0x23U, 0x72U, 0xe3U, 0x6aU,
        0x20U, 0x50U, 0xd7U, 0x6bU, 0xc1U, 0x4dU, 0xdcU, 0x14U,
    }};
    check(std::equal(expected_hash.begin(), expected_hash.end(), auth[0].bytes.begin() + 8),
          "RPTK uses SHA-256(salt || test password) golden vector");

    const auto wrong_id_ack = acknowledgement(gateway_id + 1U);
    check(session.on_datagram(wrong_id_ack.data(), wrong_id_ack.size(), master, 3U) ==
              InputResult::rejected_malformed,
          "10-byte acknowledgement with the wrong gateway ID is rejected");
    check(session.snapshot().state == State::backoff &&
              session.snapshot().last_failure == Failure::wrong_peer_id,
          "wrong acknowledgement ID enters backoff");
    check(session.snapshot().queued_outbound == 0U,
          "wrong acknowledgement clears queued data");
}

void test_ack_lengths_options_and_dmrd()
{
    Session session;
    const auto login = start(session, "TS=1");
    (void)login;
    const auto salt = challenge();
    check(session.on_datagram(salt.data(), salt.size(), master, 1U) == InputResult::accepted,
          "accept challenge for options path");
    (void)session.take_outbound();
    check(session.on_datagram(salt.data(), salt.size(), master, 1U) ==
              InputResult::ignored_duplicate_ack,
          "ignore a repeated challenge while waiting for its authentication acknowledgement");
    check(session.snapshot().state == State::waiting_auth_ack &&
              session.snapshot().queued_outbound == 0U,
          "repeated challenge does not restart authentication");

    auto ack = acknowledgement(gateway_id);
    check(session.on_datagram(ack.data(), ack.size(), master, 2U) == InputResult::accepted,
          "accept HomeBrew 10-byte auth acknowledgement with gateway ID");
    auto config = session.take_outbound();
    check(config.size() == 1U, "auth acknowledgement emits one config packet");
    check_config_packet(config[0].bytes);

    const auto config_ack = acknowledgement(gateway_id);
    check(session.on_datagram(config_ack.data(), config_ack.size(), master, 3U) ==
              InputResult::accepted,
          "accept HomeBrew 10-byte config acknowledgement");
    const auto option_packets = session.take_outbound();
    check(option_packets.size() == 1U && option_packets[0].bytes.size() == 12U,
          "options packet has marker, gateway ID, and exact option bytes");
    check(std::string(option_packets[0].bytes.begin(), option_packets[0].bytes.begin() + 4) ==
              "RPTO",
          "RPTO marker");
    check(std::string(option_packets[0].bytes.begin() + 8, option_packets[0].bytes.end()) ==
              "TS=1",
          "RPTO option contents");

    const auto options_ack = acknowledgement(gateway_id);
    check(session.on_datagram(options_ack.data(), options_ack.size(), master, 4U) ==
              InputResult::accepted,
          "accept HomeBrew 10-byte options acknowledgement");
    check(session.snapshot().state == State::ready,
          "session becomes ready only after final options acknowledgement");
    const auto duplicate_ack = acknowledgement(gateway_id);
    check(session.on_datagram(duplicate_ack.data(), duplicate_ack.size(), master, 4U) ==
              InputResult::ignored_duplicate_ack,
          "ignore a delayed duplicate acknowledgement after ready");
    check(session.snapshot().state == State::ready,
          "duplicate acknowledgement does not disconnect a ready session");

    std::array<std::uint8_t, wirex::bm::dmrd_datagram_size> dmrd{};
    std::copy_n("DMRD", 4U, dmrd.begin());
    dmrd[4] = 7U;
    dmrd[5] = 0x12U;
    check(!session.send_dmrd(dmrd.data(), dmrd.size() - 1U, 5U),
          "reject outbound truncated DMRD");
    check(session.send_dmrd(dmrd.data(), dmrd.size(), 5U),
          "ready session queues exact 55-byte outbound DMRD");
    auto outbound_dmrd = session.take_outbound();
    check(outbound_dmrd.size() == 1U && outbound_dmrd[0].kind == PacketKind::application &&
              outbound_dmrd[0].bytes.size() == 55U,
          "outbound DMRD remains an application datagram");

    check(session.on_datagram(dmrd.data(), dmrd.size(), other, 6U) ==
              InputResult::ignored_wrong_endpoint,
          "DMRD from another endpoint is ignored");
    check(session.on_datagram(dmrd.data(), dmrd.size(), master, 7U) ==
              InputResult::application_datagram,
          "ready session accepts inbound exact 55-byte DMRD");
    auto inbound = session.take_received_dmrd();
    check(inbound.has_value() && inbound->source == master && inbound->bytes == dmrd,
          "received DMRD is exposed unchanged to the call layer");

    check(session.send_dmrd(dmrd.data(), dmrd.size(), 8U),
          "queue application data before transport-loss cleanup");
    check(session.on_datagram(dmrd.data(), dmrd.size() - 1U, master, 9U) ==
              InputResult::rejected_malformed,
          "reject inbound truncated DMRD");
    const auto state = session.snapshot();
    check(state.state == State::backoff && state.last_failure == Failure::malformed_response,
          "malformed inbound frame breaks the session into backoff");
    check(state.queued_outbound == 0U && state.queued_inbound == 0U,
          "malformed frame clears both application queues");
    check(!session.send_dmrd(dmrd.data(), dmrd.size(), 10U),
          "backoff session cannot send DMRD");
}

void test_application_queue_limit()
{
    Session session;
    (void)start(session);
    const auto salt = challenge();
    (void)session.on_datagram(salt.data(), salt.size(), master, 1U);
    (void)session.take_outbound();
    const auto auth_ack = acknowledgement(gateway_id);
    (void)session.on_datagram(auth_ack.data(), auth_ack.size(), master, 2U);
    (void)session.take_outbound();
    const auto config_ack = acknowledgement(gateway_id);
    (void)session.on_datagram(config_ack.data(), config_ack.size(), master, 3U);
    check(session.snapshot().state == State::ready, "ready before outbound queue limit check");

    std::array<std::uint8_t, wirex::bm::dmrd_datagram_size> dmrd{};
    std::copy_n("DMRD", 4U, dmrd.begin());
    for (std::size_t i = 0; i < wirex::bm::max_queued_datagrams; ++i) {
        check(session.send_dmrd(dmrd.data(), dmrd.size(), 4U),
              "queue DMRD while capacity remains");
    }
    check(!session.send_dmrd(dmrd.data(), dmrd.size(), 5U),
          "reject DMRD when the bounded queue is full");
    check(session.snapshot().state == State::backoff &&
              session.snapshot().last_failure == Failure::outbound_queue_full &&
              session.snapshot().queued_outbound == 0U,
          "full outbound queue is reported and cleared instead of silently dropping data");
}

void test_ready_ack_wrong_id()
{
    Session session;
    (void)start(session);
    const auto salt = challenge();
    (void)session.on_datagram(salt.data(), salt.size(), master, 1U);
    (void)session.take_outbound();
    const auto auth_ack = acknowledgement(gateway_id);
    (void)session.on_datagram(auth_ack.data(), auth_ack.size(), master, 2U);
    (void)session.take_outbound();
    const auto config_ack = acknowledgement(gateway_id);
    (void)session.on_datagram(config_ack.data(), config_ack.size(), master, 3U);
    check(session.snapshot().state == State::ready, "ready before delayed wrong-ID ACK");

    const auto wrong_ack = acknowledgement(gateway_id + 1U);
    check(session.on_datagram(wrong_ack.data(), wrong_ack.size(), master, 4U) ==
              InputResult::rejected_malformed,
          "reject a delayed acknowledgement carrying a different gateway ID");
    check(session.snapshot().state == State::backoff &&
              session.snapshot().last_failure == Failure::wrong_peer_id,
          "wrong ID in ready state breaks the authenticated session");
}

void test_transport_loss_clears_queued_application_data()
{
    Session session;
    (void)start(session);
    const auto salt = challenge();
    (void)session.on_datagram(salt.data(), salt.size(), master, 1U);
    (void)session.take_outbound();
    const auto auth_ack = acknowledgement(gateway_id);
    (void)session.on_datagram(auth_ack.data(), auth_ack.size(), master, 2U);
    (void)session.take_outbound();
    const auto config_ack = acknowledgement(gateway_id);
    (void)session.on_datagram(config_ack.data(), config_ack.size(), master, 3U);
    check(session.snapshot().state == State::ready, "ready before transport loss");

    std::array<std::uint8_t, wirex::bm::dmrd_datagram_size> dmrd{};
    std::copy_n("DMRD", 4U, dmrd.begin());
    check(session.send_dmrd(dmrd.data(), dmrd.size(), 4U),
          "queue DMRD before transport loss");
    session.transport_lost(5U);
    const auto state = session.snapshot();
    check(state.state == State::backoff && state.last_failure == Failure::transport_lost,
          "transport error enters reconnect backoff");
    check(state.queued_outbound == 0U && state.queued_inbound == 0U,
          "transport loss clears application queues");
}

void test_malformed_rejection_timeout_and_stop()
{
    {
        Session session;
        (void)start(session);
        auto short_challenge = challenge();
        short_challenge.pop_back();
        check(session.on_datagram(short_challenge.data(), short_challenge.size(), master, 1U) ==
                  InputResult::rejected_malformed,
              "reject short challenge before reading the salt");
        check(session.snapshot().state == State::backoff &&
                  session.snapshot().last_failure == Failure::malformed_response,
              "malformed challenge never reports ready");
    }

    {
        Session session;
        (void)start(session);
        const auto nak = [&] {
            auto bytes = packet("MSTNAK");
            append_id(bytes, gateway_id);
            return bytes;
        }();
        check(session.on_datagram(nak.data(), nak.size(), master, 1U) ==
                  InputResult::master_rejected,
              "accept fixed-source 10-byte MSTNAK with matching ID as rejection");
        check(session.snapshot().state == State::backoff &&
                  session.snapshot().last_failure == Failure::master_rejected,
              "Master rejection enters backoff");
    }

    {
        Session session;
        (void)start(session);
        auto close = packet("MSTCL");
        append_id(close, gateway_id);
        check(session.on_datagram(close.data(), close.size(), master, 1U) ==
                  InputResult::master_closed,
              "accept fixed-source 9-byte MSTCL with matching peer ID");
        check(session.snapshot().state == State::backoff &&
                  session.snapshot().last_failure == Failure::master_closed,
              "Master close enters backoff");
    }

    {
        Session session;
        auto login = start(session);
        check(login.size() == 1U, "initial login datagram");
        session.tick(10000U);
        auto retry = session.take_outbound();
        check(retry.size() == 1U && retry[0].bytes == login[0].bytes,
              "login phase retransmits the same request after 10 seconds");
        session.tick(60000U);
        check(session.snapshot().state == State::backoff &&
                  session.snapshot().last_failure == Failure::login_timeout,
              "60-second login timeout enters backoff");
        check(session.snapshot().next_action_at_ms == 61000U,
              "first reconnect delay is bounded to one second");
        session.tick(60999U);
        check(session.snapshot().state == State::backoff,
              "session does not retry before backoff expires");
        session.tick(61000U);
        check(session.snapshot().state == State::waiting_login_ack,
              "session starts a fresh RPTL after backoff");
        check(session.take_outbound().size() == 1U,
              "backoff expiry emits one fresh login request");
    }

    {
        Session session;
        (void)start(session);
        const auto salt = challenge();
        (void)session.on_datagram(salt.data(), salt.size(), master, 1U);
        (void)session.take_outbound();
        const auto ack = acknowledgement(gateway_id);
        (void)session.on_datagram(ack.data(), ack.size(), master, 2U);
        (void)session.take_outbound();
        const auto config_ack = acknowledgement(gateway_id);
        (void)session.on_datagram(config_ack.data(), config_ack.size(), master, 3U);
        check(session.snapshot().state == State::ready, "ready before orderly stop");
        std::array<std::uint8_t, wirex::bm::dmrd_datagram_size> dmrd{};
        std::copy_n("DMRD", 4U, dmrd.begin());
        check(session.send_dmrd(dmrd.data(), dmrd.size(), 4U),
              "queue DMRD before orderly stop");
        session.stop(4U);
        check(session.snapshot().state == State::stopped, "stop marks session stopped");
        const auto close = session.take_outbound();
        check(close.size() == 1U && close[0].bytes.size() == 9U &&
                  std::string(close[0].bytes.begin(), close[0].bytes.begin() + 5) == "RPTCL",
              "stop emits exact 9-byte RPTCL only for a ready session");
        check(close[0].bytes[5] == 0x12U && close[0].bytes[8] == 0xdeU,
              "RPTCL contains the gateway ID");
    }
}

} // 命名空间

int main()
{
    test_login_hash_and_ready();
    test_ack_lengths_options_and_dmrd();
    test_malformed_rejection_timeout_and_stop();
    test_application_queue_limit();
    test_ready_ack_wrong_id();
    test_transport_loss_clears_queued_application_data();
    std::cout << "All BM session state-machine checks passed.\n";
    return EXIT_SUCCESS;
}
