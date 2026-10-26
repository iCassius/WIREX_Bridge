#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>

#include "wirex/bm_session.hpp"
#include "wirex/bm_udp.hpp"
#include "wirex/bm_voice_pipeline.hpp"
#include "wirex/bm_test_profile.hpp"
#include "wirex/direct_frame.hpp"
#include "wirex/dmr_vocoder.hpp"
#include "wirex/hri_lcd_identity_candidate.hpp"
#include "wirex/hri_stream_session.hpp"
#include "wirex/hri_t_payload.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using wirex::bm::Endpoint;
using wirex::bm::InputResult;
using wirex::bm::Profile;
using wirex::bm::ReceiveKind;
using wirex::bm::Session;
using wirex::bm::State;
using wirex::bm::UdpTransport;
using wirex::bm_voice::BmVoicePipeline;
using wirex::bm_voice::Error;
using wirex::bm_voice::PlaybackFrame;
using wirex::bm_voice::Readiness;
using wirex::bm_voice::TimePoint;

constexpr std::uint32_t gateway_id = 0x129abcdeU;
constexpr std::uint32_t tg_id = 91U;
constexpr std::uint32_t local_id = 123456U;
constexpr std::uint32_t remote_id = 765432U;

void check(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

Endpoint endpoint_from(const sockaddr_in& address)
{
    Endpoint result{};
    std::copy_n(reinterpret_cast<const std::uint8_t*>(&address.sin_addr.s_addr),
                result.address.size(), result.address.begin());
    result.port = ntohs(address.sin_port);
    return result;
}

sockaddr_in sockaddr_from(const Endpoint& endpoint)
{
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(endpoint.port);
    std::copy(endpoint.address.begin(), endpoint.address.end(),
              reinterpret_cast<std::uint8_t*>(&address.sin_addr.s_addr));
    return address;
}

class FakeMaster final {
public:
    FakeMaster()
    {
        check(WSAStartup(MAKEWORD(2, 2), &wsa_) == 0, "Winsock startup for localhost fake Master");
        socket_ = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        check(socket_ != INVALID_SOCKET, "create localhost fake Master socket");
        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_port = 0U;
        check(inet_pton(AF_INET, "127.0.0.1", &local.sin_addr) == 1,
              "set fake Master address to loopback");
        check(::bind(socket_, reinterpret_cast<const sockaddr*>(&local), sizeof(local)) != SOCKET_ERROR,
              "bind fake Master on a loopback UDP port");
        int size = static_cast<int>(sizeof(local));
        check(getsockname(socket_, reinterpret_cast<sockaddr*>(&local), &size) != SOCKET_ERROR,
              "read fake Master UDP port");
        endpoint_ = endpoint_from(local);
    }

    FakeMaster(const FakeMaster&) = delete;
    FakeMaster& operator=(const FakeMaster&) = delete;

    ~FakeMaster()
    {
        close();
        WSACleanup();
    }

    [[nodiscard]] Endpoint endpoint() const noexcept { return endpoint_; }

    void close() noexcept
    {
        if (socket_ != INVALID_SOCKET) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
        }
    }

    bool send(const Endpoint& target, const std::uint8_t* bytes, std::size_t size)
    {
        if (socket_ == INVALID_SOCKET || bytes == nullptr || size == 0U) return false;
        const auto address = sockaddr_from(target);
        return sendto(socket_, reinterpret_cast<const char*>(bytes), static_cast<int>(size), 0,
                      reinterpret_cast<const sockaddr*>(&address), sizeof(address)) ==
               static_cast<int>(size);
    }

    bool receive(std::vector<std::uint8_t>& bytes, Endpoint& source, std::uint32_t timeout_ms = 500U)
    {
        if (socket_ == INVALID_SOCKET) return false;
        fd_set readable{};
        FD_ZERO(&readable);
        FD_SET(socket_, &readable);
        timeval timeout{};
        timeout.tv_sec = static_cast<long>(timeout_ms / 1000U);
        timeout.tv_usec = static_cast<long>((timeout_ms % 1000U) * 1000U);
        if (select(0, &readable, nullptr, nullptr, &timeout) <= 0) return false;
        std::array<std::uint8_t, 2048U> buffer{};
        sockaddr_in remote{};
        int remote_size = static_cast<int>(sizeof(remote));
        const int received = recvfrom(socket_, reinterpret_cast<char*>(buffer.data()),
                                      static_cast<int>(buffer.size()), 0,
                                      reinterpret_cast<sockaddr*>(&remote), &remote_size);
        if (received == SOCKET_ERROR || remote_size != static_cast<int>(sizeof(remote))) return false;
        bytes.assign(buffer.begin(), buffer.begin() + received);
        source = endpoint_from(remote);
        return true;
    }

private:
    SOCKET socket_{INVALID_SOCKET};
    Endpoint endpoint_{};
    WSADATA wsa_{};
};

std::vector<std::uint8_t> marker(const char* text)
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
    auto packet = marker("RPTACK");
    packet.insert(packet.end(), {1U, 2U, 3U, 4U});
    return packet;
}

std::vector<std::uint8_t> acknowledgement()
{
    auto packet = marker("RPTACK");
    append_id(packet, gateway_id);
    return packet;
}

Profile test_profile()
{
    Profile value{};
    value.gateway_id = gateway_id;
    value.password = "offline-test-password";
    value.callsign = "N0CALL";
    value.rx_frequency = 449000000U;
    value.tx_frequency = 444000000U;
    value.power = 25U;
    value.color_code = 1U;
    value.latitude = "38.0000";
    value.longitude = "-095.000";
    value.height = 75U;
    value.location = "Loopback Lab";
    value.description = "Offline integration";
    value.slot_flags = '4';
    value.url = "https://example.invalid";
    value.version = "test-version";
    value.software = "WIREX-BM-Test";
    return value;
}

class BmLoopback final {
public:
    BmLoopback()
    {
        check(client_.open(master_.endpoint()), "open production BM UDP transport to fake Master");
        auto profile = test_profile();
        check(session_.start(std::move(profile), master_.endpoint(), 0U), "start production BM session");
        auto login = send_control_and_expect("RPTL", 8U);
        client_endpoint_ = login.second;
        const auto challenge_packet = challenge();
        check(master_.send(client_endpoint_, challenge_packet.data(), challenge_packet.size()),
              "fake Master sends challenge through localhost UDP");
        receive_response(1U);
        (void)send_control_and_expect("RPTK", 40U);
        const auto auth_ack = acknowledgement();
        check(master_.send(client_endpoint_, auth_ack.data(), auth_ack.size()),
              "fake Master acknowledges authentication");
        receive_response(2U);
        (void)send_control_and_expect("RPTC", 302U);
        const auto config_ack = acknowledgement();
        check(master_.send(client_endpoint_, config_ack.data(), config_ack.size()),
              "fake Master acknowledges configuration");
        receive_response(3U);
        check(session_.snapshot().state == State::ready, "BM session reaches ready after real loopback handshake");
    }

    BmLoopback(const BmLoopback&) = delete;
    BmLoopback& operator=(const BmLoopback&) = delete;

    [[nodiscard]] Session& session() noexcept { return session_; }
    [[nodiscard]] FakeMaster& master() noexcept { return master_; }
    [[nodiscard]] const Endpoint& client_endpoint() const noexcept { return client_endpoint_; }

    std::vector<std::uint8_t> send_call_packet(const wirex::dmr_call::TxPacket& packet,
                                               std::uint64_t now_ms)
    {
        const auto encoded = wirex::dmrd::encode(packet.datagram);
        check(static_cast<bool>(encoded), "encode production DMR call packet");
        check(session_.send_dmrd(encoded.bytes.data(), encoded.bytes.size(), now_ms),
              "ready BM session queues DMRD packet");
        const auto queued = session_.take_outbound();
        check(queued.size() == 1U && queued[0].kind == wirex::bm::PacketKind::application,
              "BM session produces one application UDP datagram");
        check(client_.send(queued[0].bytes.data(), queued[0].bytes.size()),
              "production BM transport sends DMRD over localhost UDP");
        auto received = receive_master();
        check(received.first == queued[0].bytes && received.second == client_endpoint_,
              "fake Master receives the exact production DMRD bytes from client socket");
        return received.first;
    }

    wirex::dmrd::Datagram send_downlink(const wirex::dmr_call::TxPacket& packet,
                                        std::uint64_t now_ms)
    {
        const auto encoded = wirex::dmrd::encode(packet.datagram);
        check(static_cast<bool>(encoded), "encode fake downlink DMRD packet");
        check(master_.send(client_endpoint_, encoded.bytes.data(), encoded.bytes.size()),
              "fake Master sends DMRD through localhost UDP");
        const auto received = client_.receive(100U);
        check(received.kind == ReceiveKind::datagram && received.source == master_.endpoint(),
              "production BM transport receives fake Master UDP datagram");
        check(session_.on_datagram(received.bytes.data(), received.bytes.size(), received.source, now_ms) ==
                  InputResult::application_datagram,
              "production BM session accepts fake Master DMRD");
        const auto app = session_.take_received_dmrd();
        check(app.has_value() && app->source == master_.endpoint(), "BM session exposes source-checked DMRD");
        const auto decoded = wirex::dmrd::decode(app->bytes.data(), app->bytes.size());
        check(static_cast<bool>(decoded), "decode DMRD received by production BM session");
        return decoded.datagram;
    }

    bool close_close_packet()
    {
        session_.stop(20000U);
        const auto close = session_.take_outbound();
        if (close.size() != 1U || close[0].bytes.size() != 9U ||
            std::string(close[0].bytes.begin(), close[0].bytes.begin() + 5) != "RPTCL") {
            std::cerr << "RPTCL queue mismatch state=" << static_cast<int>(session_.snapshot().state)
                      << " queued=" << close.size() << '\n';
            return false;
        }
        if (!client_.send(close[0].bytes.data(), close[0].bytes.size())) {
            std::cerr << "RPTCL send failed\n";
            return false;
        }
        std::vector<std::uint8_t> received;
        Endpoint source{};
        const bool got = master_.receive(received, source);
        if (!got || received != close[0].bytes || source != client_endpoint_) {
            std::cerr << "RPTCL receive mismatch got=" << got << " size=" << received.size()
                      << " srcport=" << source.port << " clientport=" << client_endpoint_.port << '\n';
            return false;
        }
        return true;
    }

private:
    std::pair<std::vector<std::uint8_t>, Endpoint> receive_master()
    {
        std::pair<std::vector<std::uint8_t>, Endpoint> received;
        check(master_.receive(received.first, received.second), "fake Master receives real UDP datagram");
        return received;
    }

    void receive_response(std::uint64_t now_ms)
    {
        const auto received = client_.receive(100U);
        check(received.kind == ReceiveKind::datagram, "client receives fake Master login response");
        check(session_.on_datagram(received.bytes.data(), received.bytes.size(), received.source, now_ms) ==
                  InputResult::accepted,
              "BM session accepts login response from configured Master endpoint");
    }

    std::pair<std::vector<std::uint8_t>, Endpoint> send_control_and_expect(const char* name,
                                                                           std::size_t size)
    {
        const auto pending = session_.take_outbound();
        check(pending.size() == 1U && pending[0].bytes.size() == size &&
                  std::string(pending[0].bytes.begin(), pending[0].bytes.begin() + 4) == name,
              "BM session emits expected login control packet");
        check(client_.send(pending[0].bytes.data(), pending[0].bytes.size()),
              "production BM transport sends login control packet");
        const auto actual = receive_master();
        check(actual.first == pending[0].bytes, "fake Master receives exact control packet over UDP");
        return actual;
    }

    FakeMaster master_;
    UdpTransport client_;
    Session session_;
    Endpoint client_endpoint_{};
};

wirex::dmr_call::CallConfig call_config(std::uint32_t source, std::uint8_t stream,
                                        wirex::dmr_call::Slot slot = wirex::dmr_call::Slot::ts1)
{
    wirex::dmr_call::CallConfig call{};
    call.source_id = source;
    call.destination_id = tg_id;
    call.gateway_id = gateway_id;
    call.stream_id = {0x31U, 0x42U, 0x53U, stream};
    call.slot = slot;
    call.kind = wirex::dmr_call::CallKind::group;
    call.color_code = 1U;
    return call;
}

wirex::hri_stream_session::CandidateFrame hri_candidate(bool start)
{
    std::vector<std::uint8_t> payload(90U, static_cast<std::uint8_t>('0'));
    payload[0] = static_cast<std::uint8_t>(start ? '3' : '0');
    const auto result = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'), std::move(payload)});
    check(static_cast<bool>(result), "encode fake HRI T3 or T0 record");
    return result.bytes;
}

wirex::dmr_call::AmbeVoiceBurst synth_voice_burst()
{
    wirex::dmr_vocoder::Encoder encoder;
    wirex::dmr_call::AmbeVoiceBurst burst{};
    for (std::size_t unit = 0U; unit < wirex::dmr_call::codewords_per_burst; ++unit) {
        wirex::dmr_vocoder::PcmFrame pcm{};
        for (std::size_t i = 0U; i < pcm.size(); ++i) {
            const auto phase = static_cast<double>(unit * pcm.size() + i) * 2.0 * 3.14159265358979323846 / 48.0;
            pcm[i] = static_cast<std::int16_t>(std::sin(phase) * 5000.0);
        }
        const auto codeword = encoder.encode(pcm);
        std::copy(codeword.begin(), codeword.end(),
                  burst.begin() + static_cast<std::ptrdiff_t>(unit * codeword.size()));
    }
    return burst;
}

void check_dmrd_kind(const wirex::dmrd::Datagram& datagram,
                     wirex::dmr_call::ReceiveEventKind expected,
                     wirex::dmr_call::Receiver& observer,
                     TimePoint now,
                     const char* description)
{
    const auto received = observer.ingest(datagram, now);
    check(received.accepted(), description);
    check(std::any_of(received.events.begin(), received.events.begin() + received.event_count,
                      [expected](const wirex::dmr_call::ReceiveEvent& event) {
                          return event.kind == expected;
                      }), description);
}

void send_pipeline_packet(BmLoopback& link, const wirex::dmr_call::TxPacket& packet,
                          std::uint64_t now_ms, wirex::dmr_call::Receiver& observer,
                          wirex::dmr_call::ReceiveEventKind expected,
                          std::vector<wirex::dmr_call::PacketKind>& order)
{
    const auto bytes = link.send_call_packet(packet, now_ms);
    const auto decoded = wirex::dmrd::decode(bytes.data(), bytes.size());
    check(static_cast<bool>(decoded), "fake Master decodes production DMRD");
    check_dmrd_kind(decoded.datagram, expected, observer, TimePoint{} + std::chrono::milliseconds{now_ms},
                    "DMR call layer accepts transmitted header, voice, or EOT");
    order.push_back(packet.kind);
}

void test_real_loopback_tx_and_cancel_before_rptcl()
{
    BmLoopback link;
    auto pipeline = std::make_unique<BmVoicePipeline>();
    const auto base = TimePoint{} + 1s;
    const auto call = call_config(local_id, 1U);
    check(pipeline->begin_tx(call, Readiness{true, true}, base) == Error::none,
          "TX begins only after loopback BM and synthetic HRI are ready");
    wirex::dmr_call::Receiver observer;
    std::vector<wirex::dmr_call::PacketKind> order;
    const auto header = pipeline->take_outbound();
    check(header && header->kind == wirex::dmr_call::PacketKind::voice_lc_header,
          "pipeline creates real DMR voice LC header");
    send_pipeline_packet(link, *header, 1000U, observer,
                         wirex::dmr_call::ReceiveEventKind::call_started, order);

    std::array<std::int16_t, wirex::bm_voice::max_tx_audio_samples_per_push> pcm{};
    for (std::size_t i = 0U; i < pcm.size(); ++i) {
        pcm[i] = static_cast<std::int16_t>(std::sin(static_cast<double>(i) * 2.0 * 3.14159265358979323846 / 48.0) * 7000.0);
    }
    check(pipeline->push_tx_audio(pcm.data(), pcm.size(), base + 1ms).error == Error::none,
          "real codec accepts synthetic 48 kHz TX PCM");
    check(pipeline->tick(base + 60ms) == Error::none && !pipeline->take_outbound().has_value(),
          "TX waits for enough continuous capture PCM before starting its burst clock");
    check(pipeline->push_tx_audio(pcm.data(), pcm.size(), base + 100ms).error == Error::none,
          "real codec accepts the next synthetic 100 ms WaveInput block");
    check(pipeline->tick(base + 160ms) == Error::none,
          "TX starts the 60 ms clock after its bounded capture prebuffer fills");
    bool saw_voice = false;
    const auto first_voice = pipeline->take_outbound();
    check(first_voice && first_voice->kind == wirex::dmr_call::PacketKind::voice_sync,
          "first continuous capture burst carries DMR voice sync");
    send_pipeline_packet(link, *first_voice, 1160U, observer,
                         wirex::dmr_call::ReceiveEventKind::voice, order);
    saw_voice = true;
    check(pipeline->end_tx(base + 200ms) == Error::none, "TX resampler and codec flush before EOT");
    bool saw_eot = false;
    for (std::uint64_t elapsed_ms = 220U; elapsed_ms <= 820U && !saw_eot; elapsed_ms += 60U) {
        const auto now = base + std::chrono::milliseconds{static_cast<std::int64_t>(elapsed_ms)};
        const auto tick_error = pipeline->tick(now);
        if (tick_error != Error::none) {
            std::cerr << "TX tick elapsed_ms=" << elapsed_ms << " error=" << static_cast<int>(tick_error)
                      << " queued=" << pipeline->snapshot().queued_tx_codewords << '\n';
            check(false, "TX pacing tick succeeds");
        }
        while (const auto packet = pipeline->take_outbound()) {
            const bool is_terminator = packet->kind == wirex::dmr_call::PacketKind::terminator_with_lc;
            send_pipeline_packet(link, *packet, 1000U + elapsed_ms, observer,
                                 is_terminator ? wirex::dmr_call::ReceiveEventKind::call_ended
                                               : wirex::dmr_call::ReceiveEventKind::voice,
                                 order);
            saw_voice = saw_voice || packet->kind == wirex::dmr_call::PacketKind::voice_sync ||
                                      packet->kind == wirex::dmr_call::PacketKind::voice;
            saw_eot = saw_eot || is_terminator;
        }
    }
    check(saw_voice && saw_eot, "fake Master received actual codec voice followed by DMR EOT");

    // 用户主动取消时丢弃媒体，只发一个终止 LC，然后再经同一 UDP 传输发送 RPTCL。
    const auto cancel_call = call_config(local_id, 2U);
    check(pipeline->begin_tx(cancel_call, Readiness{true, true}, base + 2s) == Error::none,
          "TX can re-enter after the first DMR EOT");
    const auto cancel_header = pipeline->take_outbound();
    check(cancel_header && cancel_header->kind == wirex::dmr_call::PacketKind::voice_lc_header,
          "cancelled TX sends its LC header before termination");
    send_pipeline_packet(link, *cancel_header, 3000U, observer,
                         wirex::dmr_call::ReceiveEventKind::call_started, order);
    check(pipeline->push_tx_audio(pcm.data(), pcm.size(), base + 2001ms).error == Error::none,
          "cancelled TX queues synthetic speech before user stop");
    check(pipeline->stop_tx(base + 2010ms) == Error::none,
          "user cancel drops pending media and creates one terminator");
    std::size_t cancel_terminators = 0U;
    while (const auto packet = pipeline->take_outbound()) {
        check(packet->kind == wirex::dmr_call::PacketKind::terminator_with_lc,
              "user cancel emits no queued voice after dropping media");
        ++cancel_terminators;
        send_pipeline_packet(link, *packet, 3010U, observer,
                             wirex::dmr_call::ReceiveEventKind::call_ended, order);
    }
    check(cancel_terminators == 1U, "user cancel emits at most one DMR terminator");
    check(link.close_close_packet(), "RPTCL reaches fake Master after user-cancel terminator");
}

wirex::bm_voice::ReceiveResult ingest_rx_packet(BmLoopback& link, BmVoicePipeline& pipeline,
                                                const wirex::dmr_call::TxPacket& packet,
                                                std::uint64_t now_ms)
{
    const auto datagram = link.send_downlink(packet, now_ms);
    return pipeline.ingest_rx(datagram,
        TimePoint{} + std::chrono::milliseconds{now_ms});
}

void send_rx_packet(BmLoopback& link, BmVoicePipeline& pipeline,
                    const wirex::dmr_call::TxPacket& packet, std::uint64_t now_ms)
{
    const auto result = ingest_rx_packet(link, pipeline, packet, now_ms);
    check(result.error == Error::none, "pipeline accepts selected DMRD from real loopback session");
}

std::uint64_t write_id(const wirex::hri_stream_session::Update& update,
                       wirex::hri_stream_session::ActionKind kind)
{
    for (const auto& action : update.actions) if (action.kind == kind) return action.write_id;
    throw std::runtime_error("expected fake HRI write action not found");
}

void record_write(wirex::hri_stream_session::Session& hri,
                  const wirex::hri_stream_session::Action& action,
                  std::uint64_t now_ms,
                  std::vector<wirex::hri_stream_session::CandidateFrame>& writes)
{
    check(action.kind == wirex::hri_stream_session::ActionKind::write_start_candidate ||
              action.kind == wirex::hri_stream_session::ActionKind::write_stop_candidate,
          "fake HRI sink receives only T3/T0 candidate actions");
    writes.push_back(action.frame);
    check(hri.write_attempted(action.write_id, now_ms).error == wirex::hri_stream_session::Error::none,
          "fake HRI records a serial write attempt");
    check(hri.write_completed(action.write_id, true, now_ms).error == wirex::hri_stream_session::Error::none,
          "fake HRI records successful write completion");
}

struct FakeHriAudioSink {
    struct Pending {
        std::uint64_t due_ms{};
        std::uint64_t generation{};
    };
    std::deque<Pending> pending;
    std::size_t submitted_frames{};
    std::size_t acknowledged_frames{};
    std::size_t submitted_samples{};
    std::uint64_t last_ack_ms{};

    void submit(const PlaybackFrame& frame, std::uint64_t now_ms)
    {
        ++submitted_frames;
        submitted_samples += frame.sample_count;
        const auto duration_ms = std::max<std::size_t>(1U, (frame.sample_count + 47U) / 48U);
        pending.push_back({now_ms + duration_ms, frame.generation});
    }
};

void test_short_downlink_eot_waits_for_t3_and_final_audio_ack()
{
    BmLoopback link;
    auto pipeline = std::make_unique<BmVoicePipeline>();
    check(pipeline->set_receive_filter({tg_id, true, wirex::dmr_call::Slot::ts1, true,
                                        wirex::dmr_call::CallKind::group}) == Error::none,
          "RX filter selects one talkgroup, slot, and group-call kind");
    wirex::hri_stream_session::Session hri(hri_candidate(true), hri_candidate(false));
    std::vector<wirex::hri_stream_session::CandidateFrame> hri_writes;
    const std::uint64_t base_ms = 5000U;
    wirex::hri_stream_session::Update hri_update{};

    auto call = call_config(remote_id, 3U);
    wirex::dmr_call::Transmitter sender;
    const auto header = sender.start(call);
    check(static_cast<bool>(header), "synthetic DMR source creates voice LC header");
    send_rx_packet(link, *pipeline, header.packet, base_ms);
    const auto burst = synth_voice_burst();
    auto first = sender.voice(burst);
    auto second = sender.voice(burst);
    check(first && second, "synthetic source creates two real AMBE voice bursts");
    send_rx_packet(link, *pipeline, first.packet, base_ms + 60U);
    send_rx_packet(link, *pipeline, second.packet, base_ms + 120U);
    const auto eot = sender.finish();
    check(static_cast<bool>(eot), "synthetic source creates DMR terminator with LC");
    send_rx_packet(link, *pipeline, eot.packet, base_ms + 300U);

    const auto early_snapshot = pipeline->snapshot();
    if (!(early_snapshot.rx_state == wirex::bm_voice::RxState::draining &&
          early_snapshot.queued_rx_bursts == 2U && early_snapshot.queued_playback_frames == 0U)) {
        std::cerr << "early snapshot state=" << static_cast<int>(early_snapshot.rx_state)
                  << " bursts=" << early_snapshot.queued_rx_bursts
                  << " playback=" << early_snapshot.queued_playback_frames << '\n';
    }
    check(early_snapshot.rx_state == wirex::bm_voice::RxState::draining &&
              early_snapshot.queued_rx_bursts == 2U && early_snapshot.queued_playback_frames == 0U,
          "early EOT retains both speech bursts without decoding before T3 permission");
    check(early_snapshot.receive_call.source_id == remote_id && early_snapshot.receive_generation != 0U,
          "early BM EOT retains the accepted call source ID and generation until HRI T3 can start");
    bool saw_network_end = false;
    while (const auto event = pipeline->take_event()) {
        if (event->kind == wirex::bm_voice::EventKind::network_ended) saw_network_end = true;
    }
    check(saw_network_end, "the short BM call reports EOT before HRI T3 starts");

    const auto default_start_body = wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body(1, 1, 9U);
    const auto tagged_start = wirex::hri_lcd_identity_candidate::overlay_source_id_label(
        default_start_body, early_snapshot.receive_call.source_id);
    check(static_cast<bool>(tagged_start), "the accepted short-call source ID builds one source label");
    const auto tagged_frame = wirex::direct_frame::encode({static_cast<std::uint8_t>('T'),
        std::vector<std::uint8_t>(tagged_start.body.begin(), tagged_start.body.end())});
    check(static_cast<bool>(tagged_frame), "the per-call T3 candidate encodes as a DIRECT frame");
    hri_update = hri.begin_call_with_start_candidate(tagged_frame.bytes, base_ms);
    check(hri_update.error == wirex::hri_stream_session::Error::none &&
          hri_update.state.phase == wirex::hri_stream_session::Phase::start_write_pending &&
          hri_update.actions.front().frame == tagged_frame.bytes,
          "the default per-call path uses source from the accepted receive snapshot");
    record_write(hri, hri_update.actions.front(), base_ms, hri_writes);
    hri_update = hri.network_ended(base_ms + 300U);
    check(hri_update.error == wirex::hri_stream_session::Error::none &&
          hri.snapshot().phase == wirex::hri_stream_session::Phase::awaiting_start_record,
          "network EOT at 300 ms remains pending until HRI observes T3");

    // Fake HRI delays its T record until 1000 ms after this call began.
    hri_update = hri.feed(hri_writes.front().data(), hri_writes.front().size(), base_ms + 1000U);
    check(hri_update.state.start_t_record_observed && hri_update.state.playback_permitted,
          "fake HRI T3 observation permits buffered playback at 1000 ms");
    check(pipeline->playback_ready(TimePoint{} + std::chrono::milliseconds{base_ms + 1000U}) == Error::none,
          "pipeline starts decoding only after fake HRI T3 observation");

    FakeHriAudioSink sink;
    bool saw_playback_drained = false;
    bool saw_t0_after_final_ack = false;
    for (std::uint64_t elapsed = 1000U; elapsed < 1800U && !saw_t0_after_final_ack; ++elapsed) {
        const std::uint64_t now_ms = base_ms + elapsed;
        if (elapsed % 20U == 0U) {
            check(pipeline->tick(TimePoint{} + std::chrono::milliseconds{now_ms}) == Error::none,
                  "RX playback tick advances one bounded decode step");
        }
        PlaybackFrame frame{};
        while (pipeline->take_playback_pcm(frame)) sink.submit(frame, now_ms);

        while (!sink.pending.empty() && sink.pending.front().due_ms <= now_ms) {
            const auto completion = sink.pending.front();
            sink.pending.pop_front();
            check(pipeline->acknowledge_playback(completion.generation, 1U,
                      TimePoint{} + std::chrono::milliseconds{now_ms}) == Error::none,
                  "fake WHDR_DONE completion acknowledges the matching pipeline generation");
            ++sink.acknowledged_frames;
            sink.last_ack_ms = now_ms;
            while (const auto event = pipeline->take_event()) {
                if (event->kind != wirex::bm_voice::EventKind::playback_drained) continue;
                saw_playback_drained = true;
                hri_update = hri.playback_drained(now_ms);
                const auto id = write_id(hri_update, wirex::hri_stream_session::ActionKind::write_stop_candidate);
                const auto action = *std::find_if(hri_update.actions.begin(), hri_update.actions.end(),
                    [id](const wirex::hri_stream_session::Action& item) { return item.write_id == id; });
                check(sink.pending.empty() && sink.acknowledged_frames == sink.submitted_frames,
                      "HRI T0 is delayed until every submitted audio buffer is acknowledged");
                record_write(hri, action, now_ms, hri_writes);
                saw_t0_after_final_ack = true;
                hri_update = hri.feed(hri_writes.back().data(), hri_writes.back().size(), now_ms);
                check(hri_update.state.phase == wirex::hri_stream_session::Phase::idle &&
                          hri_update.state.stop_t_record_observed,
                      "fake HRI observes T0 only after playback has drained");
                break;
            }
            if (saw_t0_after_final_ack) break;
        }
    }
    check(saw_playback_drained && saw_t0_after_final_ack,
          "short downlink completes T3, full PCM playback, final ACK, then T0");
    check(sink.submitted_frames >= 7U && sink.submitted_samples >= 6U * 960U,
          "real AMBE decoder supplies both full voice bursts and the resampler tail to fake audio sink");
}

void test_private_echo_ts2_return_and_narrow_filter()
{
    BmLoopback link;
    constexpr std::uint32_t echo_gateway_id = 461135501U;
    constexpr std::uint32_t echo_radio_id = 4611355U;
    constexpr std::uint32_t echo_service_id = 460997U;
    auto make_echo_call = [=](std::uint32_t destination, wirex::dmr_call::CallKind kind,
                              wirex::dmr_call::Slot slot, std::uint8_t stream_tail) {
        wirex::dmr_call::CallConfig call{};
        call.source_id = echo_service_id;
        call.destination_id = destination;
        call.gateway_id = echo_gateway_id;
        call.stream_id = {0U, 0U, 0U, stream_tail};
        call.slot = slot;
        call.kind = kind;
        call.color_code = 1U;
        return call;
    };

    wirex::dmr_call::Transmitter sender;
    auto echo = make_echo_call(echo_radio_id, wirex::dmr_call::CallKind::private_call,
                               wirex::dmr_call::Slot::ts2, 0U);
    const auto header = sender.start(echo);
    check(static_cast<bool>(header), "fake Master private-call source creates a valid LC header");
    auto return_header = header.packet;
    return_header.datagram.sequence = 1U;
    check(return_header.datagram.flags == 0xe1U,
          "synthetic Echo header matches the observed private TS2 flags 0xE1");
    const auto burst = synth_voice_burst();
    const auto first = sender.voice(burst);
    const auto second = sender.voice(burst);
    auto return_first = first.packet;
    auto return_second = second.packet;
    ++return_first.datagram.sequence;
    ++return_second.datagram.sequence;
    const auto eot = sender.finish();
    check(static_cast<bool>(eot), "synthetic Echo source creates one DMR terminator");
    auto return_eot = eot.packet;
    ++return_eot.datagram.sequence;
    check(return_eot.datagram.flags == 0xe2U,
          "synthetic Echo terminator matches the observed private TS2 flags 0xE2");
    const std::array<wirex::dmr_call::TxPacket, 4U> echo_packets{{
        return_header, return_first, return_second, return_eot
    }};

    BmVoicePipeline ts1_pipeline;
    check(ts1_pipeline.set_receive_filter({echo_radio_id, true, wirex::dmr_call::Slot::ts1, true,
                                          wirex::dmr_call::CallKind::private_call}) == Error::none,
          "previous TS1 receive filter remains a single-slot private-call filter");
    for (std::size_t index = 0U; index < echo_packets.size(); ++index) {
        const auto result = ingest_rx_packet(link, ts1_pipeline, echo_packets[index],
                                             30000U + 60U * index);
        check(result.error == Error::filtered,
              "observed private TS2 Echo header, voice, and terminator are filtered by the old TS1 policy");
        check(result.protocol.event_count == 0U,
              "TS1 filter rejection produces no DMR Receiver call events");
    }
    check(ts1_pipeline.snapshot().rx_state == wirex::bm_voice::RxState::idle &&
              !ts1_pipeline.take_event(),
          "TS1 filter produces no pipeline call-start or call-end events");

    BmVoicePipeline preset_pipeline;
    check(preset_pipeline.set_receive_filter({echo_radio_id, true, wirex::dmr_call::Slot::ts2, true,
                                              wirex::dmr_call::CallKind::private_call}) == Error::none,
          "TS2 preset filter remains restricted to the local ID and private calls");
    std::size_t started_events = 0U;
    std::size_t voice_events = 0U;
    std::size_t ended_events = 0U;
    std::size_t pipeline_starts = 0U;
    std::size_t pipeline_ends = 0U;
    for (std::size_t index = 0U; index < echo_packets.size(); ++index) {
        const auto result = ingest_rx_packet(link, preset_pipeline, echo_packets[index],
                                             31000U + 60U * index);
        check(result.error == Error::none && result.protocol.accepted(),
              "TS2 preset filter accepts the observed source, destination, private kind, and CC1 stream");
        for (std::size_t event_index = 0U; event_index < result.protocol.event_count; ++event_index) {
            switch (result.protocol.events[event_index].kind) {
            case wirex::dmr_call::ReceiveEventKind::call_started: ++started_events; break;
            case wirex::dmr_call::ReceiveEventKind::voice: ++voice_events; break;
            case wirex::dmr_call::ReceiveEventKind::call_ended: ++ended_events; break;
            case wirex::dmr_call::ReceiveEventKind::link_control_confirmed: break;
            }
        }
        while (const auto event = preset_pipeline.take_event()) {
            if (event->kind == wirex::bm_voice::EventKind::receive_started) ++pipeline_starts;
            if (event->kind == wirex::bm_voice::EventKind::network_ended) ++pipeline_ends;
        }
    }
    const auto received = preset_pipeline.snapshot().receive_call;
    check(started_events == 1U && voice_events == 2U && ended_events == 1U &&
              pipeline_starts == 1U && pipeline_ends == 1U,
          "TS2 preset pipeline emits receive-start, voice, and network-end events");
    check(received.source_id == echo_service_id && received.destination_id == echo_radio_id &&
              received.kind == wirex::dmr_call::CallKind::private_call &&
              received.slot == wirex::dmr_call::Slot::ts2 && received.color_code == 1U,
          "TS2 pipeline state preserves the observed Echo identities and color code");
    check(preset_pipeline.snapshot().rx_state == wirex::bm_voice::RxState::draining &&
              preset_pipeline.snapshot().queued_playback_frames == 0U,
          "protocol regression does not claim HRI readiness or audio playback");

    wirex::dmr_call::Transmitter wrong_destination_sender;
    const auto wrong_destination = wrong_destination_sender.start(make_echo_call(
        echo_radio_id + 1U, wirex::dmr_call::CallKind::private_call, wirex::dmr_call::Slot::ts2, 1U));
    check(static_cast<bool>(wrong_destination), "wrong-destination private fixture has a valid LC header");
    const auto wrong_destination_result = ingest_rx_packet(link, preset_pipeline,
        wrong_destination.packet, 31300U);
    check(wrong_destination_result.error == Error::filtered,
          "TS2 preset still rejects private calls addressed to a different destination ID");

    wirex::dmr_call::Transmitter wrong_kind_sender;
    const auto wrong_kind = wrong_kind_sender.start(make_echo_call(
        echo_radio_id, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts2, 2U));
    check(static_cast<bool>(wrong_kind), "wrong-kind group fixture has a valid LC header");
    const auto wrong_kind_result = ingest_rx_packet(link, preset_pipeline, wrong_kind.packet, 31360U);
    check(wrong_kind_result.error == Error::filtered,
          "TS2 preset still rejects group calls to the local ID");
}

void test_tg91_ts2_group_receive_filter()
{
    BmLoopback link;
    const auto preset = wirex::bm_test_profile::find("listen-91");
    check(preset.has_value(), "TG91 loopback filter comes from the listen-91 preset");
    if (!preset) return;
    check(preset->destination_id == 91U && preset->slot == wirex::dmr_call::Slot::ts2 &&
              preset->kind == wirex::dmr_call::CallKind::group,
          "listen-91 preset remains TG91 group on TS2");
    auto ingest = [&](std::uint32_t destination, wirex::dmr_call::Slot slot,
                      wirex::dmr_call::CallKind kind, std::uint8_t stream,
                      std::uint64_t now_ms) {
        BmVoicePipeline pipeline;
        check(pipeline.set_receive_filter({preset->destination_id, true, preset->slot, true,
                                           preset->kind}) == Error::none,
              "TG91 receive filter selects only destination 91, TS2, and group calls");
        wirex::dmr_call::CallConfig call{};
        call.source_id = 4611355U;
        call.destination_id = destination;
        call.gateway_id = 461135501U;
        call.stream_id = {0x91U, 0x92U, 0x93U, stream};
        call.slot = slot;
        call.kind = kind;
        call.color_code = 1U;
        wirex::dmr_call::Transmitter sender;
        const auto header = sender.start(call);
        check(static_cast<bool>(header), "fake Master creates a valid LC header for TG91 filter check");
        return ingest_rx_packet(link, pipeline, header.packet, now_ms);
    };

    const auto accepted = ingest(preset->destination_id, preset->slot,
                                 preset->kind, 1U, 40000U);
    check(accepted.error == Error::none && accepted.protocol.accepted(),
          "TG91 TS2 group call passes the receive-only preset filter");
    const auto wrong_destination = ingest(preset->destination_id + 1U, preset->slot,
                                          preset->kind, 2U, 40100U);
    check(wrong_destination.error == Error::filtered,
          "TG91 filter rejects a different group destination");
    const auto wrong_slot = ingest(preset->destination_id, wirex::dmr_call::Slot::ts1,
                                   preset->kind, 3U, 40200U);
    check(wrong_slot.error == Error::filtered,
          "TG91 filter rejects a TS1 group call");
    const auto wrong_kind = ingest(preset->destination_id, preset->slot,
                                   wirex::dmr_call::CallKind::private_call, 4U, 40300U);
    check(wrong_kind.error == Error::filtered,
          "TG91 filter rejects a private call addressed to ID 91");
}

void test_watchdog_and_disconnect_generation_isolation()
{
    auto pipeline = std::make_unique<BmVoicePipeline>();
    std::uint64_t old_generation = 0U;
    PlaybackFrame old_frame{};
    {
        BmLoopback link;
        check(pipeline->set_receive_filter({tg_id, true, wirex::dmr_call::Slot::ts1, true,
                                            wirex::dmr_call::CallKind::group}) == Error::none,
              "set receive filter for watchdog call");
        auto call = call_config(remote_id, 4U);
        wirex::dmr_call::Transmitter sender;
        const auto header = sender.start(call);
        send_rx_packet(link, *pipeline, header.packet, 10000U);
        const auto burst = synth_voice_burst();
        const auto first = sender.voice(burst);
        const auto second = sender.voice(burst);
        send_rx_packet(link, *pipeline, first.packet, 10060U);
        send_rx_packet(link, *pipeline, second.packet, 10120U);
        check(pipeline->playback_ready(TimePoint{} + 10121ms) == Error::none,
              "watchdog call is permitted to play by synthetic HRI");
        check(pipeline->tick(TimePoint{} + 10121ms) == Error::none,
              "watchdog call begins real codec decoding");
        check(pipeline->take_playback_pcm(old_frame), "watchdog call submits first PCM frame to sink");
        old_generation = old_frame.generation;
        check(pipeline->acknowledge_playback(old_frame.generation, 1U, TimePoint{} + 10122ms) == Error::none,
              "fake sink acknowledges first watchdog-call frame");
        PlaybackFrame playback{};
        std::size_t extra_frames = 0U;
        while (pipeline->take_playback_pcm(playback)) ++extra_frames;
        check(extra_frames == 2U &&
                  pipeline->acknowledge_playback(old_generation, extra_frames, TimePoint{} + 10122ms) == Error::none,
              "fake sink drains remaining first-burst frames before the watchdog interval");
        for (std::uint64_t tick_ms = 10181U; tick_ms <= 10421U; tick_ms += 60U) {
            check(pipeline->tick(TimePoint{} + std::chrono::milliseconds{tick_ms}) == Error::none,
                  "regular 60 ms playback ticks continue while waiting for lost EOT");
            std::size_t completed = 0U;
            std::uint64_t generation = 0U;
            while (pipeline->take_playback_pcm(playback)) {
                generation = playback.generation;
                ++completed;
            }
            if (completed != 0U) {
                check(pipeline->acknowledge_playback(generation, completed,
                          TimePoint{} + std::chrono::milliseconds{tick_ms}) == Error::none,
                      "fake sink acknowledges watchdog-call audio without leaving buffers in flight");
            }
        }
        check(pipeline->tick(TimePoint{} + 10480ms) == Error::none,
              "missing EOT reaches DMR Receiver watchdog using virtual monotonic time");
        bool watchdog_end = false;
        while (const auto event = pipeline->take_event()) {
            watchdog_end = watchdog_end ||
                (event->kind == wirex::bm_voice::EventKind::network_ended &&
                 event->end_reason == wirex::dmr_call::CallEndReason::watchdog);
        }
        check(watchdog_end, "missing DMR EOT causes network_ended with watchdog reason");

        link.session().transport_lost(11000U);
        pipeline->cancel_rx();
        const auto state = pipeline->snapshot();
        check(state.rx_state == wirex::bm_voice::RxState::idle && state.queued_rx_bursts == 0U &&
                  state.queued_playback_frames == 0U && state.unconfirmed_playback_frames == 0U,
              "BM disconnect cancels RX and clears queued and submitted pipeline media");
        check(pipeline->acknowledge_playback(old_generation, 1U, TimePoint{} + 11001ms) ==
                  Error::stale_playback_ack,
              "old fake WHDR_DONE completion cannot acknowledge a cancelled call generation");
    }

    // 新的 localhost BM session 和新通话复用同一个 pipeline；代际号不会重置或复用。
    {
        BmLoopback link;
        auto call = call_config(remote_id, 5U);
        wirex::dmr_call::Transmitter sender;
        const auto header = sender.start(call);
        send_rx_packet(link, *pipeline, header.packet, 20000U);
        const auto burst = synth_voice_burst();
        const auto voice = sender.voice(burst);
        const auto next_voice = sender.voice(burst);
        send_rx_packet(link, *pipeline, voice.packet, 20060U);
        send_rx_packet(link, *pipeline, next_voice.packet, 20120U);
        check(pipeline->playback_ready(TimePoint{} + 20121ms) == Error::none,
              "reconnected BM call becomes playable after its new HRI readiness");
        check(pipeline->tick(TimePoint{} + 20121ms) == Error::none,
              "reconnected call decodes with fresh RX state");
        PlaybackFrame new_frame{};
        check(pipeline->take_playback_pcm(new_frame), "reconnected call submits a new PCM frame");
        check(new_frame.generation > old_generation,
              "reconnected call receives a strictly newer playback generation");
        check(pipeline->acknowledge_playback(old_generation, 1U, TimePoint{} + 20122ms) ==
                  Error::stale_playback_ack,
              "completion from prior socket generation remains stale after a new call starts");
        check(pipeline->acknowledge_playback(new_frame.generation, 1U, TimePoint{} + 20123ms) == Error::none,
              "current call accepts its own fake audio completion");
    }
}

} // namespace

int main()
{
    try {
        test_real_loopback_tx_and_cancel_before_rptcl();
        test_short_downlink_eot_waits_for_t3_and_final_audio_ack();
        test_private_echo_ts2_return_and_narrow_filter();
        test_tg91_ts2_group_receive_filter();
        test_watchdog_and_disconnect_generation_isolation();
        std::cout << "BM Bridge component loopback checks passed (localhost UDP, real codec/DMR/pipeline, synthetic HRI/audio sink).\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
