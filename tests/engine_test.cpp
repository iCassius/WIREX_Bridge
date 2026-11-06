// Engine 离线测试：注入假 Devices（不打开串口、WinMM 或 UDP），覆盖命令队列与 future 结果、
// 快照发布、事件队列溢出、有界 stop、启动失败与诊断钩子。

#include "wirex/engine.hpp"
#include "wirex/engine_devices.hpp"
#include "wirex/engine_diagnostics.hpp"
#include "wirex/dmr_call.hpp"
#include "wirex/dmrd.hpp"
#include "wirex/dmr_vocoder.hpp"

#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"
#include "wirex/hri_session.hpp"

#include "../src/engine/engine_internal.hpp"

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <atomic>
#include <array>
#include <chrono>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

using namespace std::chrono_literals;
using wirex::engine::CommandResult;
using wirex::engine::CommandStatus;

int failures{};

void check(bool condition, std::string_view label)
{
    if (condition) return;
    std::cerr << "FAILED: " << label << '\n';
    ++failures;
}

template <typename T>
bool ready_within(std::future<T>& future, std::chrono::milliseconds timeout)
{
    return future.wait_for(timeout) == std::future_status::ready;
}

CommandResult get_within(std::future<CommandResult> future, std::chrono::milliseconds timeout, std::string_view label)
{
    if (!ready_within(future, timeout)) {
        check(false, std::string(label) + " future timed out");
        return CommandResult{CommandStatus::failed, 0U, "test_timeout"};
    }
    return future.get();
}

// 共享计数：测试在引擎结束后检查设备是否被关闭。
struct DeviceLog {
    std::mutex input_endpoint_mutex{};
    std::wstring last_opened_input_endpoint{};
    std::atomic<bool> serial_blocked{false};
    std::atomic<bool> serial_close_fails{false};
    std::atomic<int> serial_opened{0};
    std::atomic<int> serial_closed{0};
    std::atomic<int> serial_close_attempts{0};
    std::atomic<int> output_opened{0};
    std::atomic<int> output_closed{0};
    std::atomic<int> output_close_attempts{0};
    std::atomic<int> output_submitted{0};
    std::atomic<int> output_completed{0};
    std::atomic<bool> output_completion_overflow{false};
    std::atomic<bool> output_close_fails_while_open{false};
    std::wstring output_close_failure_endpoint{};
    std::atomic<bool> output_reopen_fails{false};
    std::atomic<bool> output_open_fails_but_remains_open{false};
    std::atomic<bool> output_drained{true};
    std::atomic<int> input_opened{0};
    std::atomic<int> input_closed{0};
    std::atomic<bool> input_close_fails_while_open{false};
    std::atomic<int> version_queries{0};
    std::atomic<int> y_records{0};
    std::atomic<int> t_records{0};
    // R130 FM 中继测试：FakeInput 打开时每次 take_captured 投喂 20 ms PCM；HRI X 记录注入（PTT 电平字节 [12]）。
    std::atomic<bool> input_feeds_pcm{false};
    std::mutex x_mutex{};
    std::deque<char> pending_x_levels{};
    // R131 静音组测试：FakeOutput::submit 收到含非零样本的帧时 +1。
    std::atomic<int> output_nonzero_frames{0};
    // R131 HRI 自动重连测试：为 true 时 FakeSerial 不再回 Y/0（模拟电台退出 HRI 模式，串口仍在）。
    std::atomic<bool> y_ack_suppressed{false};
};

enum class FakeHriBehavior {
    normal,
    wrong_version,
    malformed_version,
    missing_y_ack,
};

// 模拟 FTX-1 HRI：收到 V 查询回 48 字节 FTX-1 版本记录，收到 Y 回 Y/0 确认。
class FakeSerial final : public wirex::engine::SerialPort {
public:
    FakeSerial(std::shared_ptr<DeviceLog> log, bool respond, FakeHriBehavior behavior,
               bool acknowledge_t_records)
        : log_(std::move(log)), respond_(respond), behavior_(behavior),
          acknowledge_t_records_(acknowledge_t_records) {}

    bool write_all(const std::uint8_t* data, std::size_t size) noexcept override
    {
        try {
            const auto parsed = parser_.feed(data, size);
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto& event : parsed.events) {
                if (!event.has_record) continue;
                const auto type = event.record.type;
                if (type == 'V') {
                    ++log_->version_queries;
                    if (respond_) queue_version_record();
                } else if (type == 'Y') {
                    ++log_->y_records;
                    if (respond_ && behavior_ != FakeHriBehavior::missing_y_ack && !log_->y_ack_suppressed.load()) {
                        queue_record('Y', {});
                    }
                } else if (type == 'T') {
                    ++log_->t_records;
                    if (respond_ && acknowledge_t_records_) queue_record('T', {});
                }
            }
            return true;
        } catch (...) {
            return false;
        }
    }

    wirex::engine::SerialReadStatus read_available(std::uint8_t* buffer, std::size_t capacity,
                                                   std::size_t& received) noexcept override
    {
        if (log_->serial_blocked.load()) {
            received = 0U;
            return wirex::engine::SerialReadStatus::transport_error;
        }
        {
            std::lock_guard<std::mutex> x_lock(log_->x_mutex);
            while (!log_->pending_x_levels.empty()) {
                std::vector<std::uint8_t> payload(wirex::hri_session::y_body_size, '0');
                payload[12] = static_cast<std::uint8_t>(log_->pending_x_levels.front());
                log_->pending_x_levels.pop_front();
                std::lock_guard<std::mutex> lock(mutex_);
                queue_record('X', std::move(payload));
            }
        }
        std::lock_guard<std::mutex> lock(mutex_);
        received = std::min(capacity, inbound_.size());
        std::copy(inbound_.begin(), inbound_.begin() + static_cast<std::ptrdiff_t>(received), buffer);
        inbound_.erase(inbound_.begin(), inbound_.begin() + static_cast<std::ptrdiff_t>(received));
        return wirex::engine::SerialReadStatus::ok;
    }

    bool close() noexcept override
    {
        ++log_->serial_close_attempts;
        if (log_->serial_close_fails.load()) return false;
        ++log_->serial_closed;
        return true;
    }

private:
    static std::vector<std::uint8_t> version_payload()
    {
        std::vector<std::uint8_t> payload(48U, '0');
        payload[0] = 'F';
        payload[1] = 'T';
        payload[2] = 'X';
        payload[3] = '-';
        payload[4] = '1';
        return payload;
    }

    void queue_version_record()
    {
        auto payload = version_payload();
        if (behavior_ == FakeHriBehavior::wrong_version) payload[0] = 'X';
        auto encoded = wirex::direct_frame::encode({static_cast<std::uint8_t>('V'), std::move(payload)});
        if (!encoded) return;
        if (behavior_ == FakeHriBehavior::malformed_version && !encoded.bytes.empty()) {
            encoded.bytes.back() = encoded.bytes.back() == '0' ? '1' : '0';
        }
        inbound_.insert(inbound_.end(), encoded.bytes.begin(), encoded.bytes.end());
    }

    void queue_record(std::uint8_t type, std::vector<std::uint8_t> payload)
    {
        const auto encoded = wirex::direct_frame::encode({type, std::move(payload)});
        if (encoded) inbound_.insert(inbound_.end(), encoded.bytes.begin(), encoded.bytes.end());
    }

    std::shared_ptr<DeviceLog> log_;
    bool respond_;
    FakeHriBehavior behavior_;
    bool acknowledge_t_records_{};
    wirex::direct_stream::Parser parser_{};
    std::mutex mutex_{};
    std::vector<std::uint8_t> inbound_{};
};

class FakeInput final : public wirex::engine::AudioInput {
public:
    FakeInput(std::shared_ptr<DeviceLog> log, std::wstring endpoint)
        : log_(std::move(log)), endpoint_(std::move(endpoint)) {}
    bool open() noexcept override
    {
        ++log_->input_opened;
        {
            std::lock_guard<std::mutex> lock(log_->input_endpoint_mutex);
            log_->last_opened_input_endpoint = endpoint_;
        }
        open_ = true;
        return true;
    }
    bool is_open() const noexcept override { return open_; }
    wirex::engine::CaptureStatus take_captured(const Sink& sink, bool, std::uint32_t) noexcept override
    {
        if (!open_ || !log_->input_feeds_pcm.load() || !sink) return wirex::engine::CaptureStatus::ok;
        // 实时节拍：按经过时间投喂 20 ms（960 样本）块，避免一次性灌满 TX 队列。
        const auto now = std::chrono::steady_clock::now();
        if (fed_ == 0U) feed_started_ = now;
        const auto due = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(now - feed_started_).count() / 20) + 1U;
        try {
            while (fed_ < due) {
                std::vector<std::int16_t> pcm(960U);
                for (std::size_t i = 0U; i < pcm.size(); ++i) {
                    pcm[i] = static_cast<std::int16_t>(((i / 24U) % 2U) == 0U ? 400 : -400);
                }
                if (!sink(pcm.data(), pcm.size())) return wirex::engine::CaptureStatus::buffer_failed;
                ++fed_;
            }
        } catch (...) {
            return wirex::engine::CaptureStatus::buffer_failed;
        }
        return wirex::engine::CaptureStatus::ok;
    }
    bool stop_capture() noexcept override { return true; }
    bool close() noexcept override
    {
        if (open_ && log_->input_close_fails_while_open.load()) return false;
        if (open_) ++log_->input_closed;
        open_ = false;
        fed_ = 0U;
        return true;
    }

private:
    std::shared_ptr<DeviceLog> log_;
    std::wstring endpoint_;
    bool open_{};
    std::uint64_t fed_{};
    std::chrono::steady_clock::time_point feed_started_{};
};

class FakeOutput final : public wirex::engine::AudioOutput {
public:
    FakeOutput(std::shared_ptr<DeviceLog> log, std::wstring endpoint, bool can_open,
               bool close_succeeds, bool submit_succeeds)
        : log_(std::move(log)), can_open_(can_open), close_succeeds_(close_succeeds),
          submit_succeeds_(submit_succeeds), endpoint_(std::move(endpoint)) {}
    bool open() noexcept override
    {
        ++log_->output_opened;
        ++open_attempts_;
        if (open_) return false;
        if (!can_open_ && log_->output_open_fails_but_remains_open.load()) {
            open_ = true;
            return false;
        }
        open_ = can_open_ && !(open_attempts_ > 1U && log_->output_reopen_fails.load());
        return open_;
    }
    bool is_open() const noexcept override { return open_; }
    bool completion_overflowed() noexcept override { return log_->output_completion_overflow.exchange(false); }
    bool take_completed(std::uint64_t& generation, std::size_t& count) noexcept override
    {
        if (completed_.empty()) return false;
        generation = completed_.front().first;
        count = completed_.front().second;
        completed_.pop_front();
        ++log_->output_completed;
        return true;
    }
    bool has_capacity() noexcept override { return open_; }
    bool submit(const std::int16_t* pcm, std::size_t sample_count, std::uint64_t generation) noexcept override
    {
        if (!open_ || !submit_succeeds_) return false;
        completed_.emplace_back(generation, 1U);
        ++log_->output_submitted;
        if (pcm != nullptr && std::any_of(pcm, pcm + sample_count, [](std::int16_t sample) { return sample != 0; })) {
            ++log_->output_nonzero_frames;
        }
        return true;
    }
    bool all_drained() noexcept override { return log_->output_drained.load() && completed_.empty(); }
    bool close() noexcept override
    {
        ++log_->output_close_attempts;
        const auto& failure_endpoint = log_->output_close_failure_endpoint;
        if (open_ && log_->output_close_fails_while_open.load() &&
            (failure_endpoint.empty() || endpoint_ == failure_endpoint)) return false;
        if (open_) ++log_->output_closed;
        open_ = false;
        completed_.clear();
        return close_succeeds_;
    }

private:
    std::shared_ptr<DeviceLog> log_;
    bool can_open_{};
    bool close_succeeds_{true};
    bool submit_succeeds_{true};
    std::wstring endpoint_{};
    bool open_{};
    unsigned open_attempts_{};
    std::deque<std::pair<std::uint64_t, std::size_t>> completed_{};
};

struct FakeOptions {
    bool template_ok{true};
    bool serial_ok{true};
    bool hri_responds{true};
    FakeHriBehavior hri_behavior{FakeHriBehavior::normal};
    bool acknowledge_t_records{true};
    // 真实 open_serial 包含 CreateFile、DCB 配置与最长 250 ms 的预排空；>0 时模拟这段耗时。
    unsigned open_delay_ms{0U};
};

class FakeDevices final : public wirex::engine::Devices {
public:
    FakeDevices(std::shared_ptr<DeviceLog> log, FakeOptions options) : log_(std::move(log)), options_(options) {}

    bool load_hri_template(const std::filesystem::path&, std::vector<std::uint8_t>& body) override
    {
        if (!options_.template_ok) return false;
        body.assign(wirex::hri_session::y_body_size, '0');
        body[5] = '2';
        return true;
    }

    std::unique_ptr<wirex::engine::SerialPort> open_serial(const std::wstring&, std::string& failure_reason) override
    {
        if (!options_.serial_ok || log_->serial_blocked.load()) {
            failure_reason = "serial_open_or_configure_failed";
            return nullptr;
        }
        if (options_.open_delay_ms != 0U) std::this_thread::sleep_for(std::chrono::milliseconds(options_.open_delay_ms));
        ++log_->serial_opened;
        return std::make_unique<FakeSerial>(log_, options_.hri_responds, options_.hri_behavior,
                                            options_.acknowledge_t_records);
    }

    std::unique_ptr<wirex::engine::AudioInput> make_audio_input(
        const wirex::engine::AudioEndpoints& endpoints) override
    {
        return std::make_unique<FakeInput>(log_, endpoints.expected_wave_in_endpoint_id);
    }

    std::unique_ptr<wirex::engine::AudioOutput> make_audio_output(const wirex::engine::AudioEndpoints& endpoints) override
    {
        return std::make_unique<FakeOutput>(log_, endpoints.expected_wave_out_endpoint_id,
            endpoints.expected_wave_out_endpoint_id != L"bad-output",
            endpoints.expected_wave_out_endpoint_id != L"old-close-false",
            endpoints.expected_wave_out_endpoint_id != L"bad-submit-output");
    }

private:
    std::shared_ptr<DeviceLog> log_;
    FakeOptions options_;
};

wirex::engine::StartConfig base_config()
{
    wirex::engine::StartConfig config{};
    config.hri_port = L"COM99";
    config.hri_body_file = "C:/fake/device-y.bin";
    config.audio.expected_wave_in_endpoint_id = L"fake-input-1";
    config.audio.expected_wave_out_endpoint_id = L"fake-output-1";
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = 62031U;
    config.bm.profile.callsign = "TEST";
    config.bm.profile.gateway_id = 100U;
    config.bm.profile.color_code = 1U;
    config.bm_start_disconnected = true;  // 不接 BM：不会打开 UDP
    config.local_source_id = 1U;
    config.rx_policy.allowed_groups.push_back({91U, wirex::dmr_call::Slot::ts2});
    config.tx_policy.transmit_enabled = true;
    config.tx_policy.target = {91U, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts2};
    return config;
}

class LoopbackMaster final {
public:
    explicit LoopbackMaster(std::uint32_t gateway_id) : gateway_id_(gateway_id)
    {
        if (WSAStartup(MAKEWORD(2, 2), &wsa_) != 0) throw std::runtime_error("WSAStartup failed");
        socket_ = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket_ == INVALID_SOCKET) throw std::runtime_error("fake master socket failed");
        const DWORD receive_timeout = 40U;
        if (setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&receive_timeout),
                       static_cast<int>(sizeof(receive_timeout))) == SOCKET_ERROR) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
            throw std::runtime_error("fake master receive timeout failed");
        }
        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_port = 0U;
        if (inet_pton(AF_INET, "127.0.0.1", &local.sin_addr) != 1 ||
            ::bind(socket_, reinterpret_cast<const sockaddr*>(&local), sizeof(local)) == SOCKET_ERROR) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
            throw std::runtime_error("fake master loopback bind failed");
        }
        int address_size = static_cast<int>(sizeof(local));
        if (getsockname(socket_, reinterpret_cast<sockaddr*>(&local), &address_size) == SOCKET_ERROR) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
            throw std::runtime_error("fake master port query failed");
        }
        endpoint_.address = {127U, 0U, 0U, 1U};
        endpoint_.port = ntohs(local.sin_port);
        worker_ = std::thread([this]() { run(); });
    }

    LoopbackMaster(const LoopbackMaster&) = delete;
    LoopbackMaster& operator=(const LoopbackMaster&) = delete;

    ~LoopbackMaster()
    {
        stopping_ = true;
        if (worker_.joinable()) worker_.join();
        if (socket_ != INVALID_SOCKET) closesocket(socket_);
        WSACleanup();
    }

    [[nodiscard]] wirex::bm::Endpoint endpoint() const noexcept { return endpoint_; }
    [[nodiscard]] unsigned login_count() const noexcept { return login_count_.load(); }
    [[nodiscard]] unsigned auth_count() const noexcept { return auth_count_.load(); }
    [[nodiscard]] unsigned config_count() const noexcept { return config_count_.load(); }
    [[nodiscard]] unsigned disconnect_count() const noexcept { return disconnect_count_.load(); }
    [[nodiscard]] unsigned dmrd_count() const noexcept { return dmrd_count_.load(); }
    // R131：目标为 TG4000 的 DMRD 数（DMRD 布局：marker 4 + seq 1 + src 3 + dst 3）。
    [[nodiscard]] unsigned dmrd_tg4000_count() const noexcept { return dmrd_tg4000_count_.load(); }
    void reject_auth(bool value) noexcept { reject_auth_ = value; }
    [[nodiscard]] bool send_downlink(const wirex::dmr_call::TxPacket& packet) noexcept
    {
        const auto encoded = wirex::dmrd::encode(packet.datagram);
        if (!encoded) return false;
        sockaddr_in remote{};
        {
            std::lock_guard<std::mutex> lock(remote_mutex_);
            if (!remote_valid_) return false;
            remote = remote_;
        }
        return sendto(socket_, reinterpret_cast<const char*>(encoded.bytes.data()),
            static_cast<int>(encoded.bytes.size()), 0, reinterpret_cast<const sockaddr*>(&remote),
            static_cast<int>(sizeof(remote))) == static_cast<int>(encoded.bytes.size());
    }

private:
    void run() noexcept
    {
        std::array<char, 2048U> buffer{};
        while (!stopping_.load()) {
            sockaddr_in remote{};
            int remote_size = static_cast<int>(sizeof(remote));
            const int count = recvfrom(socket_, buffer.data(), static_cast<int>(buffer.size()), 0,
                reinterpret_cast<sockaddr*>(&remote), &remote_size);
            if (count == SOCKET_ERROR) continue;
            if (count < 4 || remote_size != static_cast<int>(sizeof(remote))) continue;
            {
                std::lock_guard<std::mutex> lock(remote_mutex_);
                remote_ = remote;
                remote_valid_ = true;
            }
            const std::string_view packet(buffer.data(), static_cast<std::size_t>(count));
            const std::string_view marker = packet.substr(0U, std::min<std::size_t>(4U, packet.size()));
            std::array<std::uint8_t, 10U> response{};
            std::size_t response_size = 0U;
            if (marker == "RPTL") {
                ++login_count_;
                constexpr std::array<std::uint8_t, 10U> challenge{{'R','P','T','A','C','K',1U,2U,3U,4U}};
                response = challenge;
                response_size = response.size();
            } else if (marker == "RPTK") {
                ++auth_count_;
                if (reject_auth_.load()) {
                    constexpr std::array<std::uint8_t, 6U> rejected{{'M','S','T','N','A','K'}};
                    std::copy(rejected.begin(), rejected.end(), response.begin());
                    response_size = rejected.size();
                } else {
                    make_acknowledgement(response, response_size);
                }
            } else if (marker == "DMRD") {
                ++dmrd_count_;
                if (packet.size() >= 11U) {
                    const auto byte_at = [&](std::size_t index) {
                        return static_cast<std::uint32_t>(static_cast<unsigned char>(packet[index]));
                    };
                    if (((byte_at(8U) << 16U) | (byte_at(9U) << 8U) | byte_at(10U)) == 4000U) ++dmrd_tg4000_count_;
                }
            } else if (packet.size() >= 5U && packet.substr(0U, 5U) == "RPTCL") {
                ++disconnect_count_;
            } else if (marker == "RPTC") {
                ++config_count_;
                make_acknowledgement(response, response_size);
            }
            if (response_size != 0U) {
                (void)sendto(socket_, reinterpret_cast<const char*>(response.data()),
                    static_cast<int>(response_size), 0, reinterpret_cast<const sockaddr*>(&remote), remote_size);
            }
        }
    }

    void make_acknowledgement(std::array<std::uint8_t, 10U>& response,
                              std::size_t& response_size) noexcept
    {
        constexpr std::array<std::uint8_t, 6U> acknowledgement{{'R','P','T','A','C','K'}};
        std::copy(acknowledgement.begin(), acknowledgement.end(), response.begin());
        response[6U] = static_cast<std::uint8_t>((gateway_id_ >> 24U) & 0xffU);
        response[7U] = static_cast<std::uint8_t>((gateway_id_ >> 16U) & 0xffU);
        response[8U] = static_cast<std::uint8_t>((gateway_id_ >> 8U) & 0xffU);
        response[9U] = static_cast<std::uint8_t>(gateway_id_ & 0xffU);
        response_size = response.size();
    }

    SOCKET socket_{INVALID_SOCKET};
    WSADATA wsa_{};
    wirex::bm::Endpoint endpoint_{};
    std::uint32_t gateway_id_{};
    std::atomic<bool> stopping_{false};
    std::atomic<bool> reject_auth_{true};
    std::atomic<unsigned> login_count_{0U};
    std::atomic<unsigned> auth_count_{0U};
    std::atomic<unsigned> config_count_{0U};
    std::atomic<unsigned> disconnect_count_{0U};
    std::atomic<unsigned> dmrd_count_{0U};
    std::atomic<unsigned> dmrd_tg4000_count_{0U};
    std::mutex remote_mutex_{};
    sockaddr_in remote_{};
    bool remote_valid_{};
    std::thread worker_{};
};

wirex::dmr_call::CallConfig make_test_downlink_call(std::uint8_t stream_tail)
{
    wirex::dmr_call::CallConfig call{};
    call.source_id = 4600123U;
    call.destination_id = 91U;
    call.gateway_id = 100U;
    call.stream_id = {0x31U, 0x42U, 0x53U, stream_tail};
    call.slot = wirex::dmr_call::Slot::ts2;
    call.kind = wirex::dmr_call::CallKind::group;
    call.color_code = 1U;
    return call;
}

wirex::dmr_call::AmbeVoiceBurst make_test_downlink_voice()
{
    wirex::dmr_vocoder::Encoder encoder;
    wirex::dmr_vocoder::PcmFrame pcm{};
    wirex::dmr_call::AmbeVoiceBurst burst{};
    for (std::size_t index = 0U; index < wirex::dmr_call::codewords_per_burst; ++index) {
        const auto codeword = encoder.encode(pcm);
        std::copy(codeword.begin(), codeword.end(),
                  burst.begin() + static_cast<std::ptrdiff_t>(index * codeword.size()));
    }
    return burst;
}

bool send_test_downlink_header(LoopbackMaster& master, wirex::dmr_call::Transmitter& transmitter,
                              std::uint8_t stream_tail)
{
    const auto started = transmitter.start(make_test_downlink_call(stream_tail));
    return started && master.send_downlink(started.packet);
}

bool send_test_downlink_voice(LoopbackMaster& master, wirex::dmr_call::Transmitter& transmitter,
                              const wirex::dmr_call::AmbeVoiceBurst& voice)
{
    const auto packet = transmitter.voice(voice);
    return packet && master.send_downlink(packet.packet);
}

bool send_test_downlink_terminator(LoopbackMaster& master, wirex::dmr_call::Transmitter& transmitter)
{
    const auto packet = transmitter.finish();
    return packet && master.send_downlink(packet.packet);
}

bool wait_for_local_rx_active(wirex::engine::Engine& engine, std::chrono::milliseconds timeout)
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (engine.snapshot()->active_rx_call) return true;
        std::this_thread::sleep_for(5ms);
    }
    return engine.snapshot()->active_rx_call.has_value();
}

bool wait_for_local_rx_idle(wirex::engine::Engine& engine, std::uint64_t calls_ended_before,
                            std::chrono::milliseconds timeout)
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        const auto snapshot = engine.snapshot();
        if (!snapshot->active_rx_call && snapshot->counters.calls_ended > calls_ended_before &&
            snapshot->media_owner == wirex::talkgroup_routing::MediaOwner::idle) return true;
        std::this_thread::sleep_for(5ms);
    }
    return false;
}

wirex::engine::StartConfig make_bm_only_config(const LoopbackMaster& master,
                                               std::wstring output_endpoint)
{
    auto config = base_config();
    config.start_radio = false;
    config.hri_port.clear();
    config.hri_body_file.clear();
    config.audio = {};
    config.audio.expected_wave_out_endpoint_id = std::move(output_endpoint);
    config.local_audio_start_error.clear();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-loopback-password";
    config.resolved_master = master.endpoint();
    return config;
}

bool wait_for_snapshot(wirex::engine::Engine& engine, std::chrono::milliseconds timeout,
                       bool (*predicate)(const wirex::engine::Snapshot&))
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (predicate(*engine.snapshot())) return true;
        std::this_thread::sleep_for(5ms);
    }
    return predicate(*engine.snapshot());
}

void test_event_queue_overflow()
{
    wirex::engine::detail::EventQueue queue;
    for (std::uint64_t index = 0U; index < 1100U; ++index) {
        wirex::engine::Event event{};
        event.kind = wirex::engine::EventKind::tx_started;
        event.at_ms = index;
        queue.push(std::move(event));
    }
    check(queue.size() == 1024U, "event queue is bounded at 1024 entries");
    check(queue.dropped_total() == 76U, "event queue counts dropped oldest events");
    auto first = queue.drain(10U);
    check(first.size() == 10U, "drain honours the max argument");
    check(!first.empty() && first[0].kind == wirex::engine::EventKind::warning &&
          first[0].text.find("76") != std::string::npos,
          "overflow is reported once as a warning before the retained events");
    check(first.size() > 1U && first[1].at_ms == 76U, "the oldest 76 events were discarded");
    auto rest = queue.drain(4096U);
    check(rest.size() == 1015U, "remaining events drain without a second warning");
    check(!rest.empty() && rest.back().at_ms == 1099U, "newest event is retained");
    check(queue.drain(16U).empty(), "drained queue is empty");
    check(queue.drain(0U).empty(), "drain(0) returns nothing");
}

void test_quarantined_rx_output_cleanup_gate_requires_t0_and_full_drain()
{
    using wirex::engine::detail::quarantined_rx_output_cleanup_ready;
    check(quarantined_rx_output_cleanup_ready(true, true, true, 0U, 0U, true),
          "quarantined output cleanup proceeds after confirmed T0 and complete drain");
    check(!quarantined_rx_output_cleanup_ready(true, true, true, 1U, 0U, true),
          "confirmed T0 cannot release the Router lease while queued PCM remains");
    check(!quarantined_rx_output_cleanup_ready(true, true, true, 0U, 1U, true),
          "confirmed T0 cannot release the Router lease while submitted PCM remains unconfirmed");
    check(!quarantined_rx_output_cleanup_ready(true, true, false, 0U, 0U, true),
          "an open quarantined device must report its output queue drained");
    check(!quarantined_rx_output_cleanup_ready(true, true, true, 0U, 0U, false),
          "a drained output cannot release the lease before HRI T0 is confirmed");
    check(!quarantined_rx_output_cleanup_ready(false, false, false, 0U, 0U, true),
          "the retained-handle cleanup rule applies only to quarantined output");
    check(quarantined_rx_output_cleanup_ready(true, false, false, 0U, 0U, true),
          "a closed output has no device queue to wait on after T0 and pipeline drain");
}

void test_commands_before_start()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    const auto result = get_within(engine.set_audio_gains(1000U, 1000U), 1s, "command before start");
    check(result.status == CommandStatus::not_ready && result.detail == "engine_not_running",
          "commands before start resolve immediately as not_ready");
    const auto audio = get_within(engine.set_audio_endpoints(wirex::engine::AudioEndpoints{}), 1s,
                                  "audio endpoint command before start");
    check(audio.status == CommandStatus::not_ready && audio.detail == "engine_not_running",
          "audio endpoint commands before start resolve immediately as not_ready");
    wirex::engine::BmTarget rejected_profile{};
    rejected_profile.profile.password = "short-secret";
    const auto rejected_bm = get_within(engine.configure_bm(std::move(rejected_profile)), 1s,
                                        "BM profile command before start");
    check(rejected_bm.status == CommandStatus::not_ready && rejected_bm.detail == "engine_not_running",
          "BM profile commands before start resolve as not_ready without entering the worker queue");
    const auto stop = get_within(engine.stop(), 1s, "stop before start");
    check(stop.status == CommandStatus::idempotent, "stop before start is idempotent");
    check(engine.snapshot()->phase == wirex::engine::Phase::stopped, "initial snapshot phase is stopped");
    check(engine.drain_events().empty(), "no events before start");
}

void test_rejected_bm_commands_wipe_password_before_completion()
{
    const auto verify_rejected = [](const char* reason) {
        wirex::engine::detail::Command command{};
        command.kind = wirex::engine::detail::CommandKind::configure_bm;
        command.bm_target.emplace();
        command.bm_target->profile.password = "short-secret";
        auto future = command.promise.get_future();
        const bool wiped = wirex::engine::detail::resolve_rejected_command(
            command, CommandResult{CommandStatus::not_ready, 0U, reason});
        check(wiped && command.bm_target->profile.password.empty(),
              std::string(reason) + " clears BM password bytes before the future completes");
        const auto result = get_within(std::move(future), 1s, reason);
        check(result.status == CommandStatus::not_ready && result.detail == reason,
              std::string(reason) + " rejection result is still delivered to the caller");
    };

    verify_rejected("engine_not_running");
    verify_rejected("engine_stopped");
}

void test_start_failures()
{
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{false, true, true}));
        const auto result = get_within(engine.start(base_config()), 5s, "start with invalid template");
        check(result.status == CommandStatus::accepted,
              "invalid HRI template leaves the BM runtime start successful");
        check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
                  return snapshot.phase == wirex::engine::Phase::running &&
                      snapshot.radio_error == "y_template_invalid";
              }), "invalid HRI template is reported through radio_error while the runtime remains active");
        check(!engine.snapshot()->serial_open && !engine.snapshot()->hri_ready,
              "template failure does not claim an open serial port or ready HRI");
        check(log->serial_opened == 0, "serial is not opened when the template is invalid");
        check(get_within(engine.stop(), 2s, "stop runtime after template failure").status == CommandStatus::accepted,
              "BM runtime remains explicitly stoppable after the radio template failure");
    }
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{true, false, true}));
        auto config = base_config();
        const auto result = get_within(engine.start(std::move(config)), 5s, "start with serial failure");
        check(result.status == CommandStatus::accepted,
              "serial open failure leaves the BM runtime start successful");
        check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
                  return snapshot.phase == wirex::engine::Phase::running &&
                      snapshot.radio_error == "serial_open_or_configure_failed";
              }), "serial open failure is visible on the radio child state");
        check(!engine.snapshot()->serial_open && !engine.snapshot()->hri_ready,
              "serial failure leaves the radio disconnected without stopping Engine");

        wirex::engine::RadioStartConfig retry{};
        retry.hri_port = L"COM99";
        retry.hri_body_file = "C:/fake/device-y.bin";
        retry.audio.expected_wave_in_endpoint_id = L"fake-input-1";
        retry.audio.expected_wave_out_endpoint_id = L"fake-output-1";
        const auto failed_attach = get_within(engine.connect_radio(std::move(retry)), 2s,
                                               "retry attach after serial failure");
        check(failed_attach.status == CommandStatus::failed &&
              failed_attach.detail == "serial_open_or_configure_failed",
              "radio reconnect exposes the repeated exact-port failure without ending runtime");
        check(engine.snapshot()->phase == wirex::engine::Phase::running && !engine.snapshot()->serial_open,
              "a failed radio reconnect preserves the running BM runtime");
        check(get_within(engine.stop(), 2s, "stop runtime after serial failure").status == CommandStatus::accepted,
              "runtime remains stoppable after a radio attach error");
    }
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        auto config = base_config();
        config.radio_playback_gain_milli = 100U;
        const auto result = get_within(engine.start(std::move(config)), 5s, "start with invalid gain");
        check(result.status == CommandStatus::invalid && result.detail == "audio_gain_out_of_range",
              "start rejects gains outside 250..16000");
        check(engine.wait_stopped(2s), "engine ends after gain validation failure");
    }
}

void test_hri_handshake_failures_report_exact_stop_reason()
{
    struct Case {
        const char* label;
        bool responds;
        FakeHriBehavior behavior;
        const char* expected_error;
        std::chrono::milliseconds timeout;
    };
    const Case cases[]{
        {"silent radio", false, FakeHriBehavior::normal, "hri_version_timeout", 5s},
        {"wrong HRI model", true, FakeHriBehavior::wrong_version, "hri_version_mismatch", 2s},
        {"malformed HRI version record", true, FakeHriBehavior::malformed_version,
            "hri_malformed_record", 2s},
        {"missing HRI Y/0", true, FakeHriBehavior::missing_y_ack, "hri_y_ack_timeout", 6s},
    };

    for (const auto& test_case : cases) {
        auto log = std::make_shared<DeviceLog>();
        FakeOptions options{};
        options.hri_responds = test_case.responds;
        options.hri_behavior = test_case.behavior;
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, options));
        std::mutex status_mutex;
        std::vector<std::string> status_events;
        auto config = base_config();
        config.diagnostics.status = [&](const wirex::engine::StatusRecord& record) {
            std::lock_guard<std::mutex> lock(status_mutex);
            status_events.emplace_back(record.event);
            return true;
        };
        check(get_within(engine.start(std::move(config)), 5s,
                         std::string("start HRI diagnostic case: ") + test_case.label).status ==
                  CommandStatus::accepted,
              std::string("an HRI handshake failure must not fail BM runtime startup: ") + test_case.label);

        const auto deadline = std::chrono::steady_clock::now() + test_case.timeout;
        bool observed = false;
        while (std::chrono::steady_clock::now() < deadline) {
            const auto snapshot = engine.snapshot();
            if (snapshot && snapshot->phase == wirex::engine::Phase::running &&
                snapshot->radio_error == test_case.expected_error && !snapshot->serial_open &&
                !snapshot->hri_ready) {
                observed = true;
                break;
            }
            std::this_thread::sleep_for(5ms);
        }
        check(observed, std::string("radio_error preserves HRI StopReason for ") + test_case.label);
        {
            std::lock_guard<std::mutex> lock(status_mutex);
            check(std::find(status_events.begin(), status_events.end(), test_case.expected_error) != status_events.end(),
                  std::string("diagnostic event preserves HRI StopReason for ") + test_case.label);
        }
        check(log->serial_opened == 1 && log->serial_closed == 1,
              std::string("failed HRI handshake closes its fake serial handle: ") + test_case.label);
        check(get_within(engine.stop(), 3s,
                         std::string("stop runtime after HRI diagnostic case: ") + test_case.label).status ==
                  CommandStatus::accepted,
              std::string("BM runtime remains stoppable after HRI handshake failure: ") + test_case.label);
    }
}

void test_running_engine()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    std::atomic<int> wakeups{0};
    engine.set_wakeup([&wakeups]() { ++wakeups; });

    std::mutex status_mutex;
    std::vector<std::string> statuses;
    std::ostringstream status_lines;
    std::uint64_t seq = 0U;
    std::atomic<bool> cleanup_hook_called{false};
    auto config = base_config();
    config.diagnostics.status = [&](const wirex::engine::StatusRecord& record) {
        std::lock_guard<std::mutex> lock(status_mutex);
        statuses.emplace_back(record.event);
        return wirex::engine::append_status_line(status_lines, "1-2", ++seq, record);
    };
    config.diagnostics.cleanup_complete = [&cleanup_hook_called]() {
        cleanup_hook_called = true;
        return true;
    };

    const auto started = get_within(engine.start(config), 5s, "start");
    check(started.status == CommandStatus::accepted, "start succeeds with fake devices");
    const auto second = get_within(engine.start(base_config()), 1s, "second start");
    check(second.status == CommandStatus::busy, "a second start while running is busy");

    // 假 HRI 回应 V 与 Y/0 后，引擎打开 WaveOut 并进入 running。
    check(wait_for_snapshot(engine, 5s, [](const wirex::engine::Snapshot& s) {
              return s.hri_ready && s.wave_out_open && s.phase == wirex::engine::Phase::running;
          }), "fake HRI handshake makes the engine running with WaveOut open");
    check(engine.snapshot()->wave_in_endpoint_id == L"fake-input-1" &&
          engine.snapshot()->wave_out_endpoint_id == L"fake-output-1",
          "snapshot reports stable audio endpoint IDs selected at startup");
    check(engine.snapshot()->hri_port == L"COM99", "snapshot reports the actual selected HRI COM port");
    check(log->version_queries >= 1 && log->y_records >= 1, "engine writes V and Y records to the serial port");

    // 快照发布：至少每 100 ms 一次（心跳），seq 单调递增。
    const auto first_seq = engine.snapshot()->seq;
    std::this_thread::sleep_for(250ms);
    const auto later_seq = engine.snapshot()->seq;
    check(later_seq >= first_seq + 2U, "snapshot heartbeat publishes at least every 100 ms");
    check(wakeups.load() > 0, "wakeup callback runs on publication");

    // 命令：增益（与 control-v2 相同范围 250..16000）。
    auto gains = get_within(engine.set_audio_gains(2000U, 8000U), 2s, "set gains");
    check(gains.status == CommandStatus::accepted && gains.revision == 1U, "valid gains are accepted");
    auto snapshot = engine.snapshot();
    check(snapshot->radio_playback_gain_milli == 2000U && snapshot->mic_transmit_gain_milli == 8000U &&
          snapshot->audio_gains_revision == 1U, "snapshot reflects gains when the future resolves");

    auto new_audio = config.audio;
    new_audio.wave_in_id = 1U;
    new_audio.wave_out_id = 2U;
    new_audio.expected_wave_in_endpoint_id = L"fake-input-2";
    new_audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto switched = get_within(engine.set_audio_endpoints(new_audio), 2s, "switch audio endpoints");
    snapshot = engine.snapshot();
    check(switched.status == CommandStatus::accepted && switched.revision == 1U,
          "idle engine accepts a live audio endpoint switch");
    check(snapshot->wave_in_endpoint_id == L"fake-input-2" &&
          snapshot->wave_out_endpoint_id == L"fake-output-2" && snapshot->audio_endpoints_revision == 1U,
          "snapshot confirms both new endpoints before the command future resolves");

    auto rejected_audio = new_audio;
    rejected_audio.expected_wave_in_endpoint_id = L"fake-input-3";
    rejected_audio.expected_wave_out_endpoint_id = L"bad-output";
    const auto audio_failure = get_within(engine.set_audio_endpoints(rejected_audio), 2s, "reject unavailable output");
    snapshot = engine.snapshot();
    check(audio_failure.status == CommandStatus::failed && audio_failure.detail == "waveout_open_failed",
          "unavailable output rejects the entire endpoint switch");
    check(snapshot->wave_in_endpoint_id == L"fake-input-2" && snapshot->wave_out_endpoint_id == L"fake-output-2" &&
          snapshot->audio_endpoints_revision == 1U,
          "failed switch preserves both previously active endpoints and the revision");

    auto deferred_audio = new_audio;
    deferred_audio.wave_in_id = 4U;
    deferred_audio.wave_out_id = 4U;
    deferred_audio.expected_wave_in_endpoint_id = L"fake-input-4";
    deferred_audio.expected_wave_out_endpoint_id = L"fake-output-4";
    log->output_drained = false;
    auto deferred_switch = engine.set_audio_endpoints(deferred_audio);
    std::this_thread::sleep_for(180ms);
    check(deferred_switch.wait_for(0ms) == std::future_status::timeout,
          "audio endpoint request remains pending while playback is busy");
    log->output_drained = true;
    const auto deferred_result = get_within(std::move(deferred_switch), 2s, "deferred audio endpoint switch");
    snapshot = engine.snapshot();
    check(deferred_result.status == CommandStatus::accepted && deferred_result.revision == 2U &&
          snapshot->wave_in_endpoint_id == L"fake-input-4" && snapshot->wave_out_endpoint_id == L"fake-output-4" &&
          snapshot->audio_endpoints_revision == 2U,
          "queued endpoint switch applies after the current audio route drains");

    auto old_close_error = deferred_audio;
    old_close_error.expected_wave_out_endpoint_id = L"old-close-false";
    const auto arm_close_failure = get_within(engine.set_audio_endpoints(old_close_error), 2s,
                                               "select output that later reports close failure");
    check(arm_close_failure.status == CommandStatus::accepted && arm_close_failure.revision == 3U,
          "test route with close-failure behavior opens successfully");

    auto after_close_error = old_close_error;
    after_close_error.wave_in_id = 5U;
    after_close_error.wave_out_id = 5U;
    after_close_error.expected_wave_in_endpoint_id = L"fake-input-5";
    after_close_error.expected_wave_out_endpoint_id = L"fake-output-5";
    const auto close_warning = get_within(engine.set_audio_endpoints(after_close_error), 2s,
                                          "switch after old output close warning");
    snapshot = engine.snapshot();
    check(close_warning.status == CommandStatus::accepted && close_warning.detail ==
          "waveout_old_endpoint_closed_with_cleanup_warning" && close_warning.revision == 4U,
          "old output close failure with a released handle accepts the new route with a warning");
    check(snapshot->wave_in_endpoint_id == L"fake-input-5" && snapshot->wave_out_endpoint_id == L"fake-output-5" &&
          snapshot->wave_out_open && snapshot->audio_endpoints_revision == 4U,
          "snapshot reports the new live endpoint after old output close failure");
    auto low = get_within(engine.set_audio_gains(249U, 1000U), 2s, "low gain");
    check(low.status == CommandStatus::invalid && low.detail == "invalid_audio_gains", "gain 249 is invalid");
    auto high = get_within(engine.set_audio_gains(1000U, 16001U), 2s, "high gain");
    check(high.status == CommandStatus::invalid, "gain 16001 is invalid");
    auto bounds = get_within(engine.set_audio_gains(250U, 16000U), 2s, "boundary gains");
    check(bounds.status == CommandStatus::accepted && bounds.revision == 2U, "250 and 16000 are accepted");

    // 策略 revision：与 Router 相同的 expected_revision 检查。
    const auto rx_revision = engine.snapshot()->rx_policy_revision;
    wirex::talkgroup_routing::RxPolicy policy{};
    policy.allowed_groups.push_back({46001U, wirex::dmr_call::Slot::ts1});
    auto stale = get_within(engine.replace_rx_policy(rx_revision + 5U, policy), 2s, "stale rx policy");
    check(stale.status == CommandStatus::stale_revision && stale.detail == "revision_conflict",
          "rx policy with a wrong revision is stale");
    auto applied = get_within(engine.replace_rx_policy(rx_revision, policy), 2s, "rx policy");
    check(applied.status == CommandStatus::accepted && applied.revision == rx_revision + 1U,
          "rx policy with the current revision is applied");
    check(engine.snapshot()->rx_policy_revision == rx_revision + 1U &&
          engine.snapshot()->routing_json.find("46001") != std::string::npos,
          "snapshot exposes the new rx revision and routing view");
    const auto tx_revision = engine.snapshot()->tx_policy_revision;
    auto tx = get_within(engine.replace_tx_policy(tx_revision,
        {9U, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts1}, false), 2s, "tx policy");
    check(tx.status == CommandStatus::accepted && engine.snapshot()->tx_target.destination_id == 9U,
          "tx target update is applied");

    // Quick Call：BM 未连接时与原回调一样返回 not_ready。
    auto quick = get_within(engine.quick_call_join({46001U, wirex::dmr_call::Slot::ts1}), 2s, "quick call");
    check(quick.status == CommandStatus::not_ready && quick.detail == "quick_call_not_ready",
          "quick call before BM ready is not_ready");

    // 身份缓存：revision 栅栏与原 control-v2 回调一致。
    auto identity = get_within(engine.upsert_radio_identity(4600001U, 5U, std::string("BG1ABC")), 2s, "identity");
    check(identity.status == CommandStatus::accepted, "identity upsert accepted");
    auto replay = get_within(engine.upsert_radio_identity(4600001U, 5U, std::string("BG1ABC")), 2s, "identity replay");
    check(replay.status == CommandStatus::idempotent, "identical identity payload is idempotent");
    auto old = get_within(engine.upsert_radio_identity(4600001U, 4U, std::string("BG1ABC")), 2s, "identity stale");
    check(old.status == CommandStatus::stale_revision && old.detail == "stale_identity_revision",
          "older identity revision is stale");

    auto bm_stale = get_within(engine.set_bm_connection(false, 0U), 2s, "bm revision zero");
    check(bm_stale.status == CommandStatus::stale_revision && bm_stale.detail == "bm_revision_conflict",
          "bm revision 0 is rejected");
    auto manual = get_within(engine.manual_ptt_toggle(), 2s, "manual ptt");
    check(manual.status == CommandStatus::forbidden, "manual PTT is forbidden unless manual_ptt was configured");

    // 并发投递：多个线程同时提交命令，全部 future 都会兑现。
    std::vector<std::future<CommandResult>> futures;
    std::vector<std::thread> producers;
    std::mutex futures_mutex;
    for (int thread_index = 0; thread_index < 4; ++thread_index) {
        producers.emplace_back([&engine, &futures, &futures_mutex]() {
            for (int index = 0; index < 25; ++index) {
                auto future = engine.set_audio_gains(1000U, 1000U);
                std::lock_guard<std::mutex> lock(futures_mutex);
                futures.push_back(std::move(future));
            }
        });
    }
    for (auto& producer : producers) producer.join();
    int accepted = 0;
    for (auto& future : futures) {
        if (ready_within(future, 5s) && future.get().status == CommandStatus::accepted) ++accepted;
    }
    check(accepted == 100, "100 concurrently queued commands all resolve as accepted");
    check(engine.snapshot()->audio_gains_revision == 102U, "gain revision counts every applied command");

    // 有界停止：fake 设备下应远低于 5 s，且串口与 WaveOut 均关闭。
    const auto stop_started = std::chrono::steady_clock::now();
    auto stop_future = engine.stop();
    auto stop_again = engine.stop();
    const auto stopped = get_within(std::move(stop_future), 5s, "stop");
    const auto stop_elapsed = std::chrono::steady_clock::now() - stop_started;
    check(stopped.status == CommandStatus::accepted, "clean stop resolves accepted");
    check(get_within(std::move(stop_again), 1s, "second stop").status == CommandStatus::accepted,
          "concurrent stop callers receive the same result");
    check(stop_elapsed < 3500ms, "stop completes within the 3 s media cleanup budget");
    check(engine.wait_stopped(1s), "engine thread joins after stop");
    check(log->serial_closed == 1 && log->output_closed >= 1, "stop closes the serial port and WaveOut");
    check(cleanup_hook_called.load(), "cleanup hook runs during shutdown");
    const auto final_snapshot = engine.snapshot();
    check(final_snapshot->phase == wirex::engine::Phase::stopped && !final_snapshot->serial_open &&
          !final_snapshot->wave_out_open, "final snapshot reports stopped with devices closed");
    auto after = get_within(engine.set_audio_gains(1000U, 1000U), 1s, "command after stop");
    check(after.status == CommandStatus::not_ready, "commands after stop are not_ready");

    {
        std::lock_guard<std::mutex> lock(status_mutex);
        check(!statuses.empty() && statuses.front() == "started", "first status record is started");
        bool shutdown_seen = false;
        bool not_requested_seen = false;
        for (const auto& name : statuses) {
            shutdown_seen = shutdown_seen || name == "shutdown_requested";
            not_requested_seen = not_requested_seen || name == "bm_not_requested_before_exit";
        }
        check(shutdown_seen && not_requested_seen, "shutdown status records follow the R127 names");
        check(!statuses.empty() && statuses.back() == "stopped", "last status record is stopped");
        const auto text = status_lines.str();
        check(text.find("{\"run_id\":\"1-2\",\"seq\":1,") == 0, "status line starts with run_id and seq");
        check(text.find("\"tx_input_gain_milli\":1000") != std::string::npos, "status lines carry gain counters");
        check(text.find("\"reconnects\":0}\n") != std::string::npos, "status line keeps the last R127 field");
    }

    bool tx_events_balanced = true;
    int link_changes = 0;
    for (const auto& event : engine.drain_events(2048U)) {
        if (event.kind == wirex::engine::EventKind::bm_link_changed) ++link_changes;
        if (event.kind == wirex::engine::EventKind::tx_started) tx_events_balanced = false;
    }
    check(tx_events_balanced, "no TX starts without a PTT");
    check(link_changes == 0, "BM link stays disabled without a password");

    // 停止后可重新启动（线程回收）。
    const auto restarted = get_within(engine.start(base_config()), 5s, "restart");
    check(restarted.status == CommandStatus::accepted, "engine can be restarted after a clean stop");
    check(get_within(engine.stop(), 5s, "stop after restart").status == CommandStatus::accepted, "restart stops");
}

void test_stop_with_reason_and_status_failure()
{
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        check(get_within(engine.start(base_config()), 5s, "start for failure stop").status == CommandStatus::accepted,
              "start for stop_with_reason");
        const auto result = get_within(engine.stop_with_reason("ui_control_frame_invalid"), 5s, "stop_with_reason");
        check(result.status == CommandStatus::failed && result.detail == "ui_control_frame_invalid",
              "stop_with_reason marks the run as failed with the given reason");
        check(engine.snapshot()->phase == wirex::engine::Phase::failed, "failed stop leaves phase failed");
    }
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        auto config = base_config();
        std::atomic<int> calls{0};
        config.diagnostics.status = [&calls](const wirex::engine::StatusRecord&) {
            ++calls;
            return false;
        };
        auto start = engine.start(std::move(config));
        check(ready_within(start, 5s), "start resolves when the status hook fails");
        check(engine.wait_stopped(5s), "status hook failure triggers bounded shutdown");
        check(engine.snapshot()->phase == wirex::engine::Phase::failed &&
              engine.snapshot()->failure_reason == "status_report_write_failed",
              "status hook failure is reported as status_report_write_failed");
        check(calls.load() == 1, "status hook is not called again after it fails");
        check(log->serial_closed == 1, "serial is closed after a status failure");
    }
    {
        // HRI 不回应：引擎持续 starting；force_stop_now 立即进入资源收尾。
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{true, true, false}));
        check(get_within(engine.start(base_config()), 5s, "start without HRI").status == CommandStatus::accepted,
              "start succeeds before HRI answers");
        check(engine.snapshot()->phase == wirex::engine::Phase::running &&
              engine.snapshot()->serial_open && !engine.snapshot()->hri_ready,
              "runtime is running while the attached radio is still waiting for HRI Y/0");
        const auto forced = std::chrono::steady_clock::now();
        engine.force_stop_now("console_close_cleanup_deadline_expired");
        check(engine.wait_stopped(2s), "force_stop_now ends the engine quickly");
        check(std::chrono::steady_clock::now() - forced < 1500ms, "forced stop does not wait for media cleanup");
        check(engine.snapshot()->failure_reason == "console_close_cleanup_deadline_expired",
              "forced stop keeps its failure reason");
        check(log->serial_closed == 1, "forced stop still closes the serial port");
    }
}

void test_bm_connection_semantics()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    std::vector<std::string> statuses;
    auto config = base_config();
    config.diagnostics.status = [&statuses](const wirex::engine::StatusRecord& record) {
        statuses.emplace_back(record.event);
        return true;
    };
    check(get_within(engine.start(std::move(config)), 5s, "start for bm").status == CommandStatus::accepted,
          "start for bm");
    // 空密码：开启请求返回 password_required（不打开 UDP），revision 重放返回同一结果。
    auto bm = get_within(engine.set_bm_connection(true, 1U), 2s, "bm enable");
    check(bm.status == CommandStatus::invalid && bm.detail == "bm_password_required" && bm.revision == 1U,
          "bm enable without a password is rejected with the control-v2 error code");
    auto bm_again = get_within(engine.set_bm_connection(true, 1U), 2s, "bm enable replay");
    check(bm_again.status == CommandStatus::invalid && bm_again.detail == "bm_password_required",
          "same bm revision replays the recorded result");
    auto bm_conflict = get_within(engine.set_bm_connection(false, 1U), 2s, "bm conflicting replay");
    check(bm_conflict.status == CommandStatus::stale_revision && bm_conflict.detail == "bm_revision_conflict",
          "same revision with a different request conflicts");
    auto bm_off = get_within(engine.set_bm_connection(false, 2U), 2s, "bm disable");
    check(bm_off.status == CommandStatus::accepted && bm_off.revision == 2U, "bm disable is accepted");
    auto bm_old = get_within(engine.set_bm_connection(true, 1U), 2s, "bm stale");
    check(bm_old.status == CommandStatus::stale_revision && bm_old.detail == "bm_revision_stale",
          "older bm revision is stale");
    check(engine.snapshot()->bm_connection_revision == 2U && !engine.snapshot()->bm_requested_enabled,
          "snapshot reflects the bm connection revision");
    // 无效/缺失 BM 密码只让 BM 保持断开，不应把共享 Engine 的正常停止改成失败。
    const auto stopped = get_within(engine.stop(), 5s, "stop after bm request");
    check(stopped.status == CommandStatus::accepted && stopped.detail.empty(),
          "a rejected BM profile does not turn an otherwise clean Engine stop into failure");
    check(!engine.snapshot()->bm_transport_open && !engine.snapshot()->bm_requested_enabled &&
          std::find(statuses.begin(), statuses.end(), "bm_not_requested_before_exit") != statuses.end(),
          "empty-password enables open no UDP transport and stop records that BM never started");
}

void test_invalid_initial_bm_profile_does_not_fail_runtime_stop()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = base_config();
    config.bm_start_disconnected = false;
    config.bm.profile.password.clear();
    config.resolved_master = wirex::bm::Endpoint{{127U, 0U, 0U, 1U}, 62031U};
    const auto started = get_within(engine.start(std::move(config)), 5s,
                                    "start with invalid initial BM credentials");
    check(started.status == CommandStatus::accepted,
          "invalid BM credentials do not prevent the independent radio runtime from starting");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.phase == wirex::engine::Phase::running &&
                  snapshot.bm_link == wirex::engine::BmLink::failed &&
                  snapshot.bm_error == "password_required" && snapshot.hri_ready;
          }), "the initial BM profile error stays visible while HRI becomes ready");
    check(get_within(engine.stop(), 4s, "stop after invalid initial BM profile").status ==
              CommandStatus::accepted,
          "an initial BM configuration failure is not a shared runtime stop failure");
    check(log->serial_opened == 1 && log->serial_closed == 1,
          "the radio resource opens and closes independently of rejected BM credentials");
}

void test_bm_auth_rejection_does_not_fail_runtime_stop()
{
    constexpr std::uint32_t gateway_id = 100U;
    LoopbackMaster master(gateway_id);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-rejected-profile";
    const auto started = get_within(engine.start(std::move(config)), 5s,
                                    "start runtime for rejected BM shutdown test");
    check(started.status == CommandStatus::accepted,
          "radio and runtime start even though the local fake Master rejects authentication");
    const auto requested = get_within(engine.set_bm_connection(true, 1U), 2s,
                                      "request BM authentication against the fake Master");
    check(requested.status == CommandStatus::accepted,
          "a syntactically valid BM request is accepted before the fake Master response");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.bm_link == wirex::engine::BmLink::failed &&
                  snapshot.bm_error == "master_rejected" && snapshot.phase == wirex::engine::Phase::running;
          }), "authentication rejection remains visible as a BM-only failure");
    check(master.login_count() == 1U && master.auth_count() == 1U && master.config_count() == 0U,
          "the fake Master received one rejected login/auth handshake and no RPTC");
    const auto stopped = get_within(engine.stop(), 5s, "stop runtime after BM authentication rejection");
    check(stopped.status == CommandStatus::accepted && engine.wait_stopped(1s),
          "a terminal BM authentication rejection does not fail clean Engine shutdown");
}

// 回归（R129 实机）：GUI 先 start（不带电台）再 connect_radio。主循环在 process_commands 之前采样 now_ms，
// connect_radio 内部打开串口耗时后以更新的时刻 start HRI；随后同一轮 tick(旧 now_ms) 触发 clock_regressed，
// HRI 立刻停止，现场表现为“CAT 能连、HRI 连不上”，日志只发出一条 V 查询。
void test_connect_radio_after_slow_serial_open_reaches_hri_ready()
{
    auto log = std::make_shared<DeviceLog>();
    FakeOptions options{};
    options.open_delay_ms = 30U;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, options));
    auto config = base_config();
    config.start_radio = false;
    config.hri_port.clear();
    const auto started = get_within(engine.start(config), 5s, "start runtime without radio");
    check(started.status == CommandStatus::accepted, "runtime starts without radio");

    wirex::engine::RadioStartConfig radio{};
    radio.hri_port = L"COM99";
    radio.hri_body_file = "C:/fake/device-y.bin";
    radio.audio.expected_wave_in_endpoint_id = L"fake-input-1";
    radio.audio.expected_wave_out_endpoint_id = L"fake-output-1";
    const auto attached = get_within(engine.connect_radio(std::move(radio)), 3s, "attach radio with slow serial open");
    check(attached.status == CommandStatus::accepted, "connect_radio accepted with slow serial open");
    check(wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.serial_open && snapshot.hri_ready;
          }),
          "HRI reaches ready after connect_radio even when opening the serial port takes time");
    const auto snapshot = engine.snapshot();
    check(snapshot->failure_reason.find("clock_regressed") == std::string::npos,
          "HRI session is not stopped by clock regression after connect_radio");
    (void)get_within(engine.stop(), 5s, "stop after slow-open attach");
}

void test_radio_bm_independent_lifecycle_and_master_rejection()
{
    constexpr std::uint32_t gateway_id = 100U;
    LoopbackMaster master(gateway_id);
    auto log = std::make_shared<DeviceLog>();
    log->serial_blocked = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));

    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-old-profile";
    const auto started = get_within(engine.start(config), 5s, "start runtime with radio serial unavailable");
    check(started.status == CommandStatus::accepted,
          "a failed first HRI serial open does not prevent the BM runtime from starting");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.phase == wirex::engine::Phase::running && !snapshot.serial_open &&
                  snapshot.radio_error == "serial_open_or_configure_failed";
          }), "startup serial failure remains isolated in radio_error");

    const auto rejected_start = get_within(engine.set_bm_connection(true, 1U), 2s,
                                             "connect to fake Master with rejected profile");
    check(rejected_start.status == CommandStatus::accepted && rejected_start.revision == 1U,
          "the first BM request uses a new requested revision while radio stays disconnected");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.phase == wirex::engine::Phase::running &&
                  snapshot.bm_link == wirex::engine::BmLink::failed &&
                  snapshot.bm_error == "master_rejected";
          }), "fake Master authentication rejection becomes a visible terminal BM error");
    check(master.login_count() == 1U && master.auth_count() == 1U && master.config_count() == 0U,
          "the rejected login sends RPTL and RPTK once, then stops before RPTC");
    std::this_thread::sleep_for(1200ms);
    check(master.login_count() == 1U && master.auth_count() == 1U && master.config_count() == 0U,
          "terminal authentication rejection does not retry or send another login packet");
    check(!engine.snapshot()->bm_requested_enabled && !engine.snapshot()->bm_transport_open &&
          !engine.snapshot()->serial_open && engine.snapshot()->phase == wirex::engine::Phase::running,
          "BM rejection leaves both connections closed while the shared runtime stays alive");

    master.reject_auth(false);
    wirex::engine::BmTarget updated{};
    updated.master_host = config.bm.master_host;
    updated.master_port = config.bm.master_port;
    updated.profile = config.bm.profile;
    updated.profile.password = "offline-new-profile";
    updated.local_source_id = config.local_source_id;
    updated.rx_policy = config.rx_policy;
    updated.tx_policy = config.tx_policy;
    const auto configured = get_within(engine.configure_bm(std::move(updated)), 2s,
                                        "replace rejected BM profile");
    check(configured.status == CommandStatus::accepted,
          "a saved profile can replace the rejected master credentials without restarting Engine");
    const auto retried = get_within(engine.set_bm_connection(true, 2U), 2s,
                                    "connect with the updated BM profile");
    check(retried.status == CommandStatus::accepted && retried.revision == 2U,
          "manual retry uses the next requested revision after authentication rejection");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.bm_link == wirex::engine::BmLink::connected &&
                  snapshot.bm_state == wirex::bm::State::ready;
          }), "updated profile reaches ready on the same local fake Master");
    check(master.login_count() == 2U && master.auth_count() == 2U && master.config_count() == 1U,
          "the new attempt sends one fresh RPTL/RPTK/RPTC handshake");
    check(!engine.snapshot()->serial_open && engine.snapshot()->phase == wirex::engine::Phase::running,
          "BM can become ready while the HRI serial port remains unavailable");

    auto disable_bm = engine.set_bm_connection(false, 3U);
    wirex::engine::BmTarget fast_profile{};
    fast_profile.master_host = config.bm.master_host;
    fast_profile.master_port = config.bm.master_port;
    fast_profile.profile = config.bm.profile;
    fast_profile.profile.password = "offline-fast-reconnect-profile";
    fast_profile.local_source_id = config.local_source_id;
    fast_profile.rx_policy = config.rx_policy;
    fast_profile.tx_policy = config.tx_policy;
    auto configure_bm = engine.configure_bm(std::move(fast_profile));
    auto reconnect_bm = engine.set_bm_connection(true, 4U);
    const auto disabled = get_within(std::move(disable_bm), 2s, "begin a fast BM disconnect");
    check(disabled.status == CommandStatus::accepted && disabled.revision == 3U,
          "the BM disconnect request advances its revision before cleanup finishes");
    const auto configured_after_disconnect = get_within(std::move(configure_bm), 5s,
                                                         "queue saved BM profile behind disconnect cleanup");
    check(configured_after_disconnect.status == CommandStatus::accepted &&
          configured_after_disconnect.revision == 3U,
          std::string("configure waits until the old BM session and UDP transport finish closing; got ") +
              configured_after_disconnect.detail + "/" +
              std::to_string(configured_after_disconnect.revision));
    const auto reconnected = get_within(std::move(reconnect_bm), 5s,
                                        "enable BM after the queued profile replacement");
    check(reconnected.status == CommandStatus::accepted && reconnected.revision == 4U,
          std::string("the later enable uses the newly accepted profile after old transport/session cleanup; got ") +
              reconnected.detail + "/" + std::to_string(reconnected.revision));
    const bool reconnected_ready = wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.bm_link == wirex::engine::BmLink::connected &&
                  snapshot.bm_state == wirex::bm::State::ready;
          });
    const auto reconnect_snapshot = engine.snapshot();
    check(reconnected_ready, std::string("queued BM reconnect reaches ready; link=") +
          std::to_string(static_cast<unsigned>(reconnect_snapshot->bm_link)) + "/state=" +
          std::to_string(static_cast<unsigned>(reconnect_snapshot->bm_state)) + "/error=" +
          reconnect_snapshot->bm_error);
    check(master.login_count() == 3U && master.auth_count() == 3U && master.config_count() == 2U &&
          master.disconnect_count() == 1U,
          std::string("fast reconnect has one login/auth/config and one separate logout packet; got ") +
              std::to_string(master.login_count()) + "/" + std::to_string(master.auth_count()) + "/" +
              std::to_string(master.config_count()) + "/" + std::to_string(master.disconnect_count()));

    log->serial_blocked = false;
    wirex::engine::RadioStartConfig radio{};
    radio.hri_port = L"COM99";
    radio.hri_body_file = "C:/fake/device-y.bin";
    radio.audio.expected_wave_in_endpoint_id = L"fake-input-1";
    radio.audio.expected_wave_out_endpoint_id = L"fake-output-1";
    const auto radio_started = get_within(engine.connect_radio(std::move(radio)), 2s,
                                           "attach radio after BM is ready");
    check(radio_started.status == CommandStatus::accepted,
          "the radio can attach later without resetting the already-ready BM session");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.serial_open && snapshot.hri_ready && snapshot.wave_out_open;
          }), "fake HRI handshake makes the separately attached radio ready");

    const auto radio_stopped = get_within(engine.disconnect_radio(), 2s, "detach radio while BM is ready");
    check(radio_stopped.status == CommandStatus::accepted,
          "radio detach is accepted independently of the connected BM manager");
    check(!engine.snapshot()->serial_open && engine.snapshot()->wave_out_open &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected &&
          engine.snapshot()->bm_state == wirex::bm::State::ready &&
          engine.snapshot()->phase == wirex::engine::Phase::running,
          "radio detach restores the local output while preserving BM UDP, ready state, and Engine runtime");
    check(log->serial_opened == 1 && log->serial_closed == 1 &&
          log->output_opened == 3 && log->output_closed == 2,
          "the shared WaveOut closes for HRI ownership and reopens for BM-only playback after detach");

    log->serial_blocked = true;
    wirex::engine::RadioStartConfig failed_radio{};
    failed_radio.hri_port = L"COM99";
    failed_radio.hri_body_file = "C:/fake/device-y.bin";
    failed_radio.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    failed_radio.audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto failed_attach = get_within(engine.connect_radio(std::move(failed_radio)), 2s,
                                          "reconnect radio after its fake port is blocked");
    check(failed_attach.status == CommandStatus::failed &&
          failed_attach.detail == "serial_open_or_configure_failed",
          "a later failed HRI reconnect reports its actual local open error");
    check(engine.snapshot()->phase == wirex::engine::Phase::running && !engine.snapshot()->serial_open &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected &&
          engine.snapshot()->bm_state == wirex::bm::State::ready,
          "a radio reconnect failure cannot disconnect the ready BM session");

    const auto bm_off = get_within(engine.set_bm_connection(false, 5U), 2s, "disconnect BM after radio test");
    check(bm_off.status == CommandStatus::accepted && bm_off.revision == 5U,
          "BM disconnect gets its own next revision after the independent radio operations");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.bm_link == wirex::engine::BmLink::disabled && !snapshot.bm_transport_open;
          }), "BM close releases only its own loopback transport");
    check(get_within(engine.stop(), 5s, "stop shared runtime after loopback test").status ==
              CommandStatus::accepted,
          "shared runtime stops cleanly after the independent BM and radio paths are closed");
}

void test_failed_bm_reconfigure_blocks_old_profile_enable()
{
    constexpr std::uint32_t gateway_id = 100U;
    LoopbackMaster master(gateway_id);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));

    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-original-profile";
    check(get_within(engine.start(config), 5s, "start runtime for failed BM reconfigure test").status ==
              CommandStatus::accepted,
          "runtime starts with a local fake Master and an existing BM profile");
    check(get_within(engine.set_bm_connection(true, 1U), 2s, "connect initial BM profile").status ==
              CommandStatus::accepted,
          "initial BM profile connects before profile replacement");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.bm_link == wirex::engine::BmLink::connected &&
                  snapshot.bm_state == wirex::bm::State::ready;
          }), "initial profile reaches ready on the local fake Master");
    check(master.login_count() == 1U && master.auth_count() == 1U && master.config_count() == 1U,
          "the first profile sends one complete login/auth/config sequence");

    auto disable = engine.set_bm_connection(false, 2U);
    wirex::engine::BmTarget invalid{};
    invalid.master_host = config.bm.master_host;
    invalid.master_port = config.bm.master_port;
    invalid.profile = config.bm.profile;
    invalid.profile.password = "offline-invalid-profile";
    invalid.local_source_id = config.local_source_id;
    invalid.rx_policy = config.rx_policy;
    invalid.tx_policy = config.tx_policy;
    invalid.tx_policy.transmit_enabled = true;
    invalid.tx_policy.target.destination_id = 0U;
    auto configure = engine.configure_bm(std::move(invalid));
    auto enable_after_failed_configure = engine.set_bm_connection(true, 3U);

    const auto disabled = get_within(std::move(disable), 2s, "disable before invalid profile replacement");
    check(disabled.status == CommandStatus::accepted && disabled.revision == 2U,
          "disconnect advances the BM revision while the profile replacement is queued");
    const auto rejected_config = get_within(std::move(configure), 5s,
                                           "apply invalid deferred BM routing profile");
    check(rejected_config.status == CommandStatus::invalid &&
          rejected_config.detail == "routing_policy_invalid",
          std::string("invalid deferred profile is rejected before replacing the stored profile; got ") +
              rejected_config.detail);
    const auto blocked_enable = get_within(std::move(enable_after_failed_configure), 5s,
                                           "block enable after failed profile replacement");
    check(blocked_enable.status == CommandStatus::invalid &&
          blocked_enable.detail == "bm_profile_reconfigure_required",
          std::string("enable is rejected rather than using the old profile; got ") + blocked_enable.detail);
    std::this_thread::sleep_for(150ms);
    check(!engine.snapshot()->bm_requested_enabled && !engine.snapshot()->bm_transport_open &&
          master.login_count() == 1U && master.auth_count() == 1U && master.config_count() == 1U,
          "a failed replacement causes no second network login with the old credentials");

    wirex::engine::BmTarget recovered{};
    recovered.master_host = config.bm.master_host;
    recovered.master_port = config.bm.master_port;
    recovered.profile = config.bm.profile;
    recovered.profile.password = "offline-recovered-profile";
    recovered.local_source_id = config.local_source_id;
    recovered.rx_policy = config.rx_policy;
    recovered.tx_policy = config.tx_policy;
    const auto configured = get_within(engine.configure_bm(std::move(recovered)), 2s,
                                       "install a valid BM profile after rejection");
    check(configured.status == CommandStatus::accepted && configured.revision == 2U,
          "a valid profile replaces the old one and clears the enable guard");
    const auto enabled = get_within(engine.set_bm_connection(true, 3U), 2s,
                                    "enable after successful profile replacement");
    check(enabled.status == CommandStatus::accepted && enabled.revision == 3U,
          "the next enable reaches the connection manager after a valid configure");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.bm_link == wirex::engine::BmLink::connected &&
                  snapshot.bm_state == wirex::bm::State::ready;
          }), "the corrected profile connects on the same local fake Master");
    check(master.login_count() == 2U && master.auth_count() == 2U && master.config_count() == 2U,
          "only the initial and corrected profiles send BM login/auth/config packets");
    check(get_within(engine.set_bm_connection(false, 4U), 2s, "disable recovered BM profile").status ==
              CommandStatus::accepted,
          "recovered BM session can be disconnected cleanly");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return !snapshot.bm_requested_enabled && !snapshot.bm_transport_open;
          }), "recovered BM transport is closed before runtime stop");
    check(get_within(engine.stop(), 5s, "stop after failed and recovered profile flow").status ==
              CommandStatus::accepted,
          "the rejected profile flow does not interfere with clean runtime shutdown");
}

void test_radio_detach_close_failure_and_recovery()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    const auto started = get_within(engine.start(base_config()), 5s, "start for radio close failure");
    check(started.status == CommandStatus::accepted, "runtime starts for the close failure test");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.phase == wirex::engine::Phase::running && snapshot.serial_open &&
                  snapshot.hri_ready && snapshot.wave_out_open;
          }), "fake HRI handshake opens the radio output before detach");

    log->output_close_fails_while_open = true;
    const auto failed_detach = get_within(engine.disconnect_radio(), 2s,
                                           "detach with an output handle that refuses to close");
    const auto failed_snapshot = engine.snapshot();
    check(failed_detach.status == CommandStatus::failed &&
          failed_detach.detail == "waveout_close_failed",
          "detach reports the close failure instead of accepting a false disconnect");
    check(failed_snapshot->phase == wirex::engine::Phase::running && !failed_snapshot->serial_open &&
          failed_snapshot->wave_out_open && failed_snapshot->radio_error == "waveout_close_failed",
          "snapshot preserves the live WaveOut handle and cleanup error after HRI serial detach");
    check(log->output_opened == 1 && log->output_closed == 0,
          "failed close does not release or replace the still-open fake WaveOut");

    wirex::engine::RadioStartConfig retry{};
    retry.hri_port = L"COM99";
    retry.hri_body_file = "C:/fake/device-y.bin";
    retry.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    retry.audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto blocked_attach = get_within(engine.connect_radio(std::move(retry)), 2s,
                                            "prevent reattach while the old WaveOut is still open");
    check(blocked_attach.status == CommandStatus::busy && blocked_attach.detail == "radio_cleanup_required" &&
          log->serial_opened == 1 && log->output_opened == 1,
          "reattach fails closed without opening a replacement COM port or WaveOut");

    log->output_close_fails_while_open = false;
    const auto recovered_detach = get_within(engine.disconnect_radio(), 2s,
                                              "retry detach after the fake driver becomes closable");
    check(recovered_detach.status == CommandStatus::accepted,
          "a second detach retries cleanup of the retained handle");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return !snapshot.serial_open && snapshot.wave_out_open && snapshot.radio_error.empty() &&
                  snapshot.phase == wirex::engine::Phase::running;
          }), "snapshot restores the selected local endpoint after the retained handle closes");
    check(log->output_closed == 1 && engine.snapshot()->local_audio.audio_state ==
              wirex::bm_local_playback::AudioState::ready,
          "successful close recovery reopens exactly one local WaveOut for BM-only playback");

    wirex::engine::RadioStartConfig reattach{};
    reattach.hri_port = L"COM99";
    reattach.hri_body_file = "C:/fake/device-y.bin";
    reattach.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    reattach.audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto reattached = get_within(engine.connect_radio(std::move(reattach)), 2s,
                                        "reattach after close recovery");
    check(reattached.status == CommandStatus::accepted && log->serial_opened == 2,
          "radio can attach again only after the retained handle has closed");
    check(get_within(engine.stop(), 4s, "stop after radio handle recovery").status == CommandStatus::accepted,
          "runtime stop remains bounded after a recovered detach and reattach");

    auto stuck_log = std::make_shared<DeviceLog>();
    wirex::engine::Engine stuck_engine(std::make_shared<FakeDevices>(stuck_log, FakeOptions{}));
    check(get_within(stuck_engine.start(base_config()), 5s, "start for permanently stuck handle").status ==
              CommandStatus::accepted,
          "second fake runtime starts for bounded cleanup verification");
    check(wait_for_snapshot(stuck_engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.hri_ready && snapshot.wave_out_open;
          }), "second fake HRI handshake opens WaveOut");
    stuck_log->output_close_fails_while_open = true;
    const auto stop_started = std::chrono::steady_clock::now();
    const auto stuck_stop = get_within(stuck_engine.stop(), 5s, "bounded stop with an uncloseable WaveOut");
    const auto stop_elapsed = std::chrono::steady_clock::now() - stop_started;
    const auto stuck_snapshot = stuck_engine.snapshot();
    check(stuck_stop.status == CommandStatus::failed && stuck_stop.detail == "owned_resource_cleanup_failed",
          "stop reports the unreleased audio handle instead of claiming full cleanup");
    check(stop_elapsed < 3500ms && stuck_engine.wait_stopped(1s),
          "a driver that keeps refusing close cannot extend Engine stop beyond its cleanup budget");
    check(stuck_snapshot->phase == wirex::engine::Phase::failed && stuck_snapshot->wave_out_open &&
          stuck_log->output_closed == 0,
          "final failed-stop snapshot still reports WaveOut open when the fake driver retained its handle");
}

void test_wavein_detach_close_failure_and_recovery()
{
    constexpr std::uint32_t gateway_id = 100U;
    LoopbackMaster master(gateway_id);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = base_config();
    config.manual_ptt = true;
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-wavein-cleanup";
    const auto started = get_within(engine.start(std::move(config)), 5s,
                                    "start for WaveIn close failure test");
    check(started.status == CommandStatus::accepted, "runtime starts for WaveIn cleanup testing");
    check(get_within(engine.set_bm_connection(true, 1U), 2s,
                     "connect localhost fake Master for WaveIn test").status == CommandStatus::accepted,
          "BM request is accepted for the fake manual PTT route");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.hri_ready && snapshot.bm_link == wirex::engine::BmLink::connected &&
                  snapshot.bm_state == wirex::bm::State::ready;
          }), "fake HRI and localhost Master become ready before opening WaveIn");
    check(get_within(engine.manual_ptt_toggle(), 2s, "start fake manual PTT capture").status ==
              CommandStatus::accepted,
          "manual PTT command is accepted by the running fake Engine");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.wave_in_open;
          }), "fake manual PTT opens the WaveIn handle");
    check(log->input_opened == 1, "the fake WaveIn object opened exactly once for the PTT call");

    log->input_close_fails_while_open = true;
    const auto disabled = get_within(engine.set_bm_connection(false, 2U), 2s,
                                     "disconnect BM while WaveIn capture is active");
    check(disabled.status == CommandStatus::accepted,
          "BM shutdown begins independently while the media path cleans up the capture handle");
    check(wait_for_snapshot(engine, 5s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.phase == wirex::engine::Phase::running &&
                  !snapshot.bm_requested_enabled && !snapshot.bm_transport_open &&
                  !snapshot.tx_active && snapshot.wave_in_open;
          }), "BM media and UDP cleanup finish while the still-open WaveIn remains visible");

    const auto failed_detach = get_within(engine.disconnect_radio(), 2s,
                                           "detach while the fake WaveIn refuses to close");
    const auto state_before_recovery = engine.snapshot();
    check(failed_detach.status == CommandStatus::failed && failed_detach.detail == "wavein_close_failed" &&
          state_before_recovery->wave_in_open && state_before_recovery->radio_error == "wavein_close_failed",
          std::string("radio detach preserves the actual WaveIn state and close error; got ") +
              failed_detach.detail + "/open=" + (state_before_recovery->wave_in_open ? "true" : "false") +
              "/error=" + state_before_recovery->radio_error + "/tx=" +
              (state_before_recovery->tx_active ? "true" : "false") + "/media=" +
              std::to_string(static_cast<unsigned>(state_before_recovery->media_owner)) + "/phase=" +
              std::to_string(static_cast<unsigned>(state_before_recovery->phase)));
    check(state_before_recovery->wave_out_open &&
          state_before_recovery->local_audio_error.empty() &&
          state_before_recovery->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready,
          "successful WaveOut restoration remains ready when WaveIn alone refuses to close");
    wirex::engine::RadioStartConfig retry{};
    retry.hri_port = L"COM99";
    retry.hri_body_file = "C:/fake/device-y.bin";
    retry.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    retry.audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto blocked = get_within(engine.connect_radio(std::move(retry)), 2s,
                                    "block reattach while the old WaveIn remains open");
    check(blocked.status == CommandStatus::busy && blocked.detail == "radio_cleanup_required" &&
          log->serial_opened == 1 && log->input_opened == 1 && log->output_opened == 2 &&
          engine.snapshot()->wave_out_open && engine.snapshot()->local_audio_error.empty(),
          std::string("WaveIn cleanup failure blocks HRI reattach while local WaveOut remains ready; got ") +
              blocked.detail + "/serial_opens=" + std::to_string(log->serial_opened) +
              "/input_opens=" + std::to_string(log->input_opened) +
              "/output_opens=" + std::to_string(log->output_opened));

    log->input_close_fails_while_open = false;
    const auto recovered = get_within(engine.disconnect_radio(), 2s,
                                      "retry WaveIn close after the fake driver recovers");
    check(recovered.status == CommandStatus::accepted && !engine.snapshot()->wave_in_open &&
          engine.snapshot()->radio_error.empty() && log->input_closed == 1,
          std::string("a second detach releases the retained WaveIn and clears its error; got ") +
              recovered.detail + "/open=" + (engine.snapshot()->wave_in_open ? "true" : "false") +
              "/error=" + engine.snapshot()->radio_error + "/closed=" + std::to_string(log->input_closed));
    check(get_within(engine.stop(), 4s, "stop after WaveIn recovery").status == CommandStatus::accepted,
          "Engine stops normally after the WaveIn handle has been recovered");
}

void test_serial_detach_close_failure_is_unconfirmed()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(base_config()), 5s, "start for serial close failure").status ==
              CommandStatus::accepted,
          "runtime starts for one-shot serial close failure test");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.phase == wirex::engine::Phase::running && snapshot.serial_open &&
                  snapshot.hri_ready && snapshot.wave_out_open;
          }), "fake radio is ready before the serial close failure");

    log->serial_close_fails = true;
    const auto failed_detach = get_within(engine.disconnect_radio(), 2s,
                                           "detach when CloseHandle outcome is unconfirmed");
    auto state = engine.snapshot();
    check(failed_detach.status == CommandStatus::failed &&
          failed_detach.detail == "serial_close_unconfirmed" && !state->serial_open &&
          !state->hri_ready && state->radio_error == "serial_close_unconfirmed",
          "serial close failure is visible as unconfirmed and is not presented as an open radio");
    check(state->wave_out_open && state->local_audio.audio_state ==
              wirex::bm_local_playback::AudioState::ready && state->local_audio_error.empty(),
          "a serial close failure does not prevent independent local WaveOut recovery");
    check(log->serial_close_attempts == 1 && log->serial_closed == 0,
          "the failing fake records one close attempt and no confirmed close");

    wirex::engine::RadioStartConfig retry{};
    retry.hri_port = L"COM99";
    retry.hri_body_file = "C:/fake/device-y.bin";
    retry.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    retry.audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto blocked_attach = get_within(engine.connect_radio(std::move(retry)), 2s,
                                            "block reattach after unconfirmed serial close");
    check(blocked_attach.status == CommandStatus::busy &&
          blocked_attach.detail == "radio_serial_close_unconfirmed" && log->serial_opened == 1,
          "an unconfirmed native serial close blocks a second COM open");
    const auto retry_detach = get_within(engine.disconnect_radio(), 2s,
                                          "observe one-shot serial close failure again");
    check(retry_detach.status == CommandStatus::failed &&
          retry_detach.detail == "serial_close_unconfirmed" && log->serial_close_attempts == 1,
          "repeated detach reports the latch without retrying an invalid or recycled native handle");
    const int output_closed_before_failed_close = log->output_closed.load();
    log->output_close_fails_while_open = true;
    const auto audio_close_failure = get_within(engine.disconnect_radio(), 2s,
                                                 "retry audio cleanup while serial status stays unconfirmed");
    check(audio_close_failure.status == CommandStatus::failed &&
          audio_close_failure.detail == "serial_close_unconfirmed" &&
          engine.snapshot()->wave_out_open &&
          engine.snapshot()->local_audio_error == "waveout_close_failed" &&
          log->serial_close_attempts == 1 &&
          log->output_closed == output_closed_before_failed_close,
          "the serial latch does not prevent a separate audio close attempt or lose its error state");
    log->output_close_fails_while_open = false;
    const int output_closed_before_recovery = log->output_closed.load();
    const auto audio_recovered = get_within(engine.disconnect_radio(), 2s,
                                             "retry WaveOut cleanup after the fake driver recovers");
    check(audio_recovered.status == CommandStatus::failed &&
          audio_recovered.detail == "serial_close_unconfirmed" &&
          engine.snapshot()->wave_out_open &&
          engine.snapshot()->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready &&
          log->output_closed == output_closed_before_recovery + 1 && log->serial_close_attempts == 1,
          "the latch permits later audio recovery while keeping the serial uncertainty visible");
    const auto stopped = get_within(engine.stop(), 5s,
                                    "stop runtime with unconfirmed serial close ownership");
    check(stopped.status == CommandStatus::failed &&
          stopped.detail == "owned_resource_cleanup_failed" && log->serial_close_attempts == 1,
          "bounded shutdown preserves the unconfirmed-close failure without a second CloseHandle attempt");
}

void test_bm_only_local_playback_quick_call_and_reconnect()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = make_bm_only_config(master, L"fake-output-local");
    check(get_within(engine.start(std::move(config)), 5s, "start BM-only local playback runtime").status ==
              CommandStatus::accepted,
          "BM-only runtime starts with a selected WaveOut and no HRI port");
    check(engine.snapshot()->phase == wirex::engine::Phase::running &&
          !engine.snapshot()->serial_open && !engine.snapshot()->hri_ready &&
          engine.snapshot()->wave_out_open &&
          engine.snapshot()->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready,
          "startup opens only the selected local WaveOut and reports it ready");

    check(get_within(engine.set_bm_connection(true, 1U), 2s, "connect BM-only local runtime").status ==
              CommandStatus::accepted,
          "BM-only local runtime accepts its first connection request");
    const auto connected_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < connected_deadline &&
           engine.snapshot()->bm_link != wirex::engine::BmLink::connected) std::this_thread::sleep_for(5ms);
    check(engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "localhost fake Master reaches ready without an HRI connection");

    const auto quick = get_within(engine.quick_call_join({91U, wirex::dmr_call::Slot::ts2}), 2s,
                                  "send Quick Call while local WaveOut remains open");
    check(quick.status == CommandStatus::accepted,
          "a persistent BM-only WaveOut does not block Quick Call readiness");
    std::this_thread::sleep_for(150ms);

    check(get_within(engine.set_bm_connection(false, 2U), 2s, "disconnect BM-only local runtime").status ==
              CommandStatus::accepted,
          "BM-only local runtime accepts a disconnect request");
    const auto disconnected_deadline = std::chrono::steady_clock::now() + 3s;
    while (std::chrono::steady_clock::now() < disconnected_deadline &&
           engine.snapshot()->bm_requested_enabled) std::this_thread::sleep_for(5ms);
    check(!engine.snapshot()->bm_requested_enabled && engine.snapshot()->wave_out_open,
          "disconnecting BM preserves the local output selection and open WaveOut");
    check(get_within(engine.set_bm_connection(true, 3U), 2s, "reconnect BM-only local runtime").status ==
              CommandStatus::accepted,
          "BM-only local runtime can reconnect after a clean disconnect");
    const auto reconnected_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < reconnected_deadline &&
           engine.snapshot()->bm_link != wirex::engine::BmLink::connected) std::this_thread::sleep_for(5ms);
    check(engine.snapshot()->bm_link == wirex::engine::BmLink::connected && engine.snapshot()->wave_out_open,
          "BM reconnect leaves the selected local output open and ready");

    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 41U),
          "localhost fake Master sends a valid DMRD voice LC header");
    std::this_thread::sleep_for(60ms);
    bool saw_started = false;
    for (std::size_t index = 0U; index < 7U; ++index) {
        check(send_test_downlink_voice(master, transmitter, voice),
              "localhost fake Master sends a valid DMRD AMBE voice burst");
        if (index == 1U) {
            saw_started = wait_for_local_rx_active(engine, 1s);
            check(saw_started, "BM-only DMRD creates a visible active call before its terminator");
            const auto active = engine.snapshot();
            check(active->active_rx_call && active->active_rx_call->destination_id == 91U &&
                  active->active_rx_call->slot == wirex::dmr_call::Slot::ts2 &&
                  active->local_audio.route == wirex::bm_local_playback::Route::local_output &&
                  active->local_audio.audio_state == wirex::bm_local_playback::AudioState::playing,
                  "local receive publishes the accepted group call and locks the PC output route");
        }
        std::this_thread::sleep_for(60ms);
    }
    check(log->output_submitted.load() > 0,
          "decoded BM-only voice PCM is submitted to the selected fake WaveOut");
    check(send_test_downlink_terminator(master, transmitter),
          "localhost fake Master sends a valid DMRD terminator");
    const auto ended_before = engine.snapshot()->counters.calls_ended;
    check(wait_for_local_rx_idle(engine, ended_before, 4s),
          "local WaveOut playback drain releases the Router lease after network EOT");
    check(engine.snapshot()->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready &&
          engine.snapshot()->wave_out_open && engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "the selected output remains ready for the next BM group call");
    check(log->serial_opened.load() == 0 && log->t_records.load() == 0,
          "BM-only call playback does not open HRI serial or send T3/T0 records");

    bool saw_call_start = false;
    bool saw_call_end = false;
    for (const auto& event : engine.drain_events(1024U)) {
        saw_call_start = saw_call_start || event.kind == wirex::engine::EventKind::rx_call_started;
        saw_call_end = saw_call_end || event.kind == wirex::engine::EventKind::rx_call_ended;
    }
    check(saw_call_start && saw_call_end,
          "BM-only receive publishes both history start and end events for the UI");

    log->output_completion_overflow = true;
    const auto overflow_deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < overflow_deadline &&
           engine.snapshot()->local_audio.output_error != wirex::bm_local_playback::OutputError::device_lost) {
        std::this_thread::sleep_for(5ms);
    }
    check(engine.snapshot()->local_audio.output_error == wirex::bm_local_playback::OutputError::device_lost &&
          engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "late local WaveOut completion overflow remains visible without stopping BM runtime");
    check(get_within(engine.stop(), 5s, "stop after BM-only local playback").status == CommandStatus::accepted,
          "BM-only playback runtime shuts down cleanly after local output loss");
}

// R131：静音组的来话照常发布（active_rx_call / 事件），但提交给 WaveOut 的 PCM 全为 0；解除静音后恢复出声。
void test_muted_group_call_is_visible_but_silent()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = make_bm_only_config(master, L"fake-output-muted");
    check(get_within(engine.start(std::move(config)), 5s, "start BM-only muted-group runtime").status ==
              CommandStatus::accepted,
          "muted-group runtime starts with a selected WaveOut");
    check(get_within(engine.set_bm_connection(true, 1U), 2s, "connect muted-group runtime").status ==
              CommandStatus::accepted,
          "muted-group runtime accepts its BM connection request");
    const auto connected_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < connected_deadline &&
           engine.snapshot()->bm_link != wirex::engine::BmLink::connected) std::this_thread::sleep_for(5ms);
    check(engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "muted-group runtime reaches BM ready");

    const auto invalid = get_within(engine.set_muted_groups({{0U, wirex::dmr_call::Slot::ts2}}), 2s,
                                    "reject invalid muted group");
    check(invalid.status == CommandStatus::invalid && invalid.detail == "invalid_muted_group",
          "set_muted_groups rejects destination_id 0");
    const auto muted = get_within(engine.set_muted_groups({{91U, wirex::dmr_call::Slot::ts2},
                                                           {91U, wirex::dmr_call::Slot::ts2}}),
                                  2s, "mute TG91 TS2");
    check(muted.status == CommandStatus::accepted && muted.revision == 1U &&
              engine.snapshot()->muted_groups_revision == 1U,
          "set_muted_groups accepts a new set, merges duplicates and publishes its revision");
    const auto repeated = get_within(engine.set_muted_groups({{91U, wirex::dmr_call::Slot::ts2}}), 2s,
                                     "repeat TG91 TS2 mute");
    check(repeated.status == CommandStatus::idempotent && repeated.revision == 1U,
          "set_muted_groups with the same set is idempotent");

    // 非静音的三角波 PCM，保证解码后非零。
    wirex::dmr_vocoder::Encoder encoder;
    wirex::dmr_vocoder::PcmFrame tone{};
    for (std::size_t index = 0U; index < tone.size(); ++index) {
        const auto phase = static_cast<int>(index % 20U);
        tone[index] = static_cast<std::int16_t>((phase < 10 ? phase : 20 - phase) * 1600 - 8000);
    }
    wirex::dmr_call::AmbeVoiceBurst voice{};
    for (std::size_t index = 0U; index < wirex::dmr_call::codewords_per_burst; ++index) {
        const auto codeword = encoder.encode(tone);
        std::copy(codeword.begin(), codeword.end(),
                  voice.begin() + static_cast<std::ptrdiff_t>(index * codeword.size()));
    }

    const auto run_call = [&](std::uint8_t stream_tail, const char* label) {
        wirex::dmr_call::Transmitter transmitter;
        check(send_test_downlink_header(master, transmitter, stream_tail), label);
        std::this_thread::sleep_for(60ms);
        bool saw_active = false;
        for (std::size_t index = 0U; index < 7U; ++index) {
            check(send_test_downlink_voice(master, transmitter, voice), label);
            if (index == 1U) {
                saw_active = wait_for_local_rx_active(engine, 1s);
                const auto active = engine.snapshot();
                saw_active = saw_active && active->active_rx_call &&
                    active->active_rx_call->destination_id == 91U &&
                    active->active_rx_call->slot == wirex::dmr_call::Slot::ts2;
            }
            std::this_thread::sleep_for(60ms);
        }
        check(send_test_downlink_terminator(master, transmitter), label);
        const auto ended_before = engine.snapshot()->counters.calls_ended;
        check(wait_for_local_rx_idle(engine, ended_before, 4s), label);
        bool saw_start = false;
        bool saw_end = false;
        for (const auto& event : engine.drain_events(1024U)) {
            saw_start = saw_start || event.kind == wirex::engine::EventKind::rx_call_started;
            saw_end = saw_end || event.kind == wirex::engine::EventKind::rx_call_ended;
        }
        return saw_active && saw_start && saw_end;
    };

    check(run_call(51U, "muted TG91 TS2 downlink call"),
          "a muted group call is still published as active_rx_call with start/end events");
    check(log->output_submitted.load() > 0 && log->output_nonzero_frames.load() == 0,
          "muted group playback is still submitted to WaveOut but every PCM sample is zero");

    const auto cleared = get_within(engine.set_muted_groups({}), 2s, "clear muted groups");
    check(cleared.status == CommandStatus::accepted && cleared.revision == 2U,
          "clearing the muted set is accepted");
    const auto submitted_before = log->output_submitted.load();
    check(run_call(52U, "unmuted TG91 TS2 downlink call"),
          "an unmuted group call is published as before");
    check(log->output_submitted.load() > submitted_before && log->output_nonzero_frames.load() > 0,
          "after clearing the muted set the group call PCM is audible again");

    // R131：TG4000 动态组断开走专用命令；quick_call_join 对 4000 仍然禁止。
    const auto forbidden = get_within(engine.quick_call_join({4000U, wirex::dmr_call::Slot::ts2}), 2s,
                                      "quick_call_join TG4000");
    check(forbidden.status == CommandStatus::forbidden && forbidden.detail == "disconnect_group_forbidden",
          "quick_call_join still forbids TG4000");
    const auto tg4000_before = master.dmrd_tg4000_count();
    const auto disconnected = get_within(engine.disconnect_dynamic_groups(wirex::dmr_call::Slot::ts2), 2s,
                                         "disconnect dynamic groups TS2");
    check(disconnected.status == CommandStatus::accepted && disconnected.revision == 2U,
          "disconnect_dynamic_groups sends TG4000 header and terminator and returns accepted");
    const auto tg4000_deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < tg4000_deadline &&
           master.dmrd_tg4000_count() < tg4000_before + 2U) std::this_thread::sleep_for(5ms);
    check(master.dmrd_tg4000_count() >= tg4000_before + 2U,
          "fake Master receives two DMRD datagrams addressed to TG4000");
    check(get_within(engine.stop(), 5s, "stop muted-group runtime").status == CommandStatus::accepted,
          "muted-group runtime shuts down cleanly");
}

void test_bm_only_unavailable_output_still_displays_and_drains()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = make_bm_only_config(master, {});
    config.local_audio_start_error = "WaveOut 未解析，请手动选择输出设备。";
    check(get_within(engine.start(std::move(config)), 5s, "start BM-only runtime without WaveOut").status ==
              CommandStatus::accepted,
          "BM-only runtime starts even without a unique local output");
    check(!engine.snapshot()->wave_out_open &&
          engine.snapshot()->local_audio.output_error ==
              wirex::bm_local_playback::OutputError::selection_unavailable &&
          !engine.snapshot()->local_audio_error.empty(),
          "missing output is exposed as a persistent visible selection error");
    check(get_within(engine.set_bm_connection(true, 1U), 2s, "connect BM without WaveOut").status ==
              CommandStatus::accepted,
          "BM connects independently of local audio availability");
    const auto connected_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < connected_deadline &&
           engine.snapshot()->bm_link != wirex::engine::BmLink::connected) std::this_thread::sleep_for(5ms);

    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 42U),
          "fake Master sends a valid header despite the missing local output");
    std::this_thread::sleep_for(60ms);
    for (std::size_t index = 0U; index < 5U; ++index) {
        check(send_test_downlink_voice(master, transmitter, voice),
              "fake Master sends voice for the visible silent route");
        std::this_thread::sleep_for(60ms);
    }
    check(wait_for_local_rx_active(engine, 2s),
          "incoming BM group call remains visible when no WaveOut is available");
    const auto active = engine.snapshot();
    check(active->active_rx_call &&
          active->local_audio.route == wirex::bm_local_playback::Route::silent &&
          active->local_audio.audio_state == wirex::bm_local_playback::AudioState::failed &&
          active->local_audio.output_error == wirex::bm_local_playback::OutputError::selection_unavailable,
          "the UI can distinguish visible silent reception from actual audio playback");
    check(log->output_submitted.load() == 0 && log->serial_opened.load() == 0,
          "silent receive sends no audio frames to a device and opens no HRI serial port");
    check(send_test_downlink_terminator(master, transmitter),
          "fake Master ends the visible silent call with DMRD EOT");
    const auto ended_before = engine.snapshot()->counters.calls_ended;
    check(wait_for_local_rx_idle(engine, ended_before, 4s),
          "silent PCM acknowledgement drains the call and releases its Router lease");
    check(engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected &&
          engine.snapshot()->local_audio_error == "WaveOut 未解析，请手动选择输出设备。",
          "audio selection failure stays visible while BM and the runtime remain active");
    check(get_within(engine.stop(), 5s, "stop after silent BM receive").status == CommandStatus::accepted,
          "runtime with unavailable local audio stops cleanly");
}

void test_bm_local_output_submit_failure_keeps_call_visible()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = make_bm_only_config(master, L"bad-submit-output");
    check(get_within(engine.start(std::move(config)), 5s, "start BM runtime with failing local output").status ==
              CommandStatus::accepted,
          "a WaveOut that opens but rejects playback does not prevent runtime startup");
    check(get_within(engine.set_bm_connection(true, 1U), 2s,
                     "connect BM with failing local output").status == CommandStatus::accepted,
          "BM can connect while the selected output is available only for the open probe");
    const auto connected_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < connected_deadline &&
           engine.snapshot()->bm_link != wirex::engine::BmLink::connected) std::this_thread::sleep_for(5ms);

    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 45U),
          "fake Master sends a call to the endpoint that will reject playback");
    std::this_thread::sleep_for(60ms);
    for (std::size_t index = 0U; index < 5U; ++index) {
        check(send_test_downlink_voice(master, transmitter, voice),
              "fake Master delivers voice while WaveOut submit fails");
        std::this_thread::sleep_for(60ms);
    }
    check(wait_for_local_rx_active(engine, 2s),
          "the network call remains visible after the first local playback error");
    const auto failure_deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < failure_deadline &&
           engine.snapshot()->local_audio.output_error !=
               wirex::bm_local_playback::OutputError::submit_failed) std::this_thread::sleep_for(5ms);
    check(engine.snapshot()->active_rx_call &&
          engine.snapshot()->local_audio.route == wirex::bm_local_playback::Route::silent &&
          engine.snapshot()->local_audio.output_error == wirex::bm_local_playback::OutputError::submit_failed &&
          engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "WaveOut submit failure switches the active call to visible silent draining without stopping BM");
    check(send_test_downlink_terminator(master, transmitter),
          "the failing-output call still receives its network terminator");
    const auto ended_before = engine.snapshot()->counters.calls_ended;
    check(wait_for_local_rx_idle(engine, ended_before, 4s),
          "silent draining releases the Router lease after WaveOut failure");
    check(engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->local_audio.output_error ==
              wirex::bm_local_playback::OutputError::submit_failed &&
          log->output_submitted.load() == 0,
          "failed output stays reported and no rejected PCM is counted as played");
    check(get_within(engine.stop(), 5s, "stop after local submit failure").status == CommandStatus::accepted,
          "runtime stops cleanly after the call drains without audio output");
}

void test_radio_output_switch_keeps_failed_handles_tracked()
{
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        check(get_within(engine.start(base_config()), 5s,
                         "start before old radio output close failure").status == CommandStatus::accepted,
              "radio runtime starts before the output handoff test");
        check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
                  return snapshot.hri_ready && snapshot.wave_out_open;
              }), "radio output is open before changing endpoint");
        const int open_count_before_switch = log->output_opened.load();
        wirex::engine::AudioEndpoints successful_switch{};
        successful_switch.wave_in_id = 2U;
        successful_switch.wave_out_id = 2U;
        successful_switch.expected_wave_in_endpoint_id = L"fake-input-2";
        successful_switch.expected_wave_out_endpoint_id = L"fake-output-2";
        const auto switched = get_within(engine.set_audio_endpoints(successful_switch), 2s,
                                          "switch a live HRI output exactly once");
        check(switched.status == CommandStatus::accepted && engine.snapshot()->wave_out_open &&
              engine.snapshot()->wave_out_endpoint_id == L"fake-output-2" &&
              log->output_opened == open_count_before_switch + 1,
              "a live HRI switch opens the candidate once and keeps it active");
        const int open_count_before = log->output_opened.load();
        const int close_attempts_before = log->output_close_attempts.load();
        log->output_close_fails_while_open = true;
        wirex::engine::AudioEndpoints requested{};
        requested.wave_in_id = 3U;
        requested.wave_out_id = 3U;
        requested.expected_wave_in_endpoint_id = L"fake-input-3";
        requested.expected_wave_out_endpoint_id = L"fake-output-3";
        const auto result = get_within(engine.set_audio_endpoints(requested), 2s,
                                       "change output while the old handle refuses close");
        const auto snapshot = engine.snapshot();
        check(result.status == CommandStatus::failed && result.detail == "waveout_close_failed" &&
              snapshot->wave_out_open && snapshot->wave_out_endpoint_id == L"fake-output-2" &&
              snapshot->radio_error == "waveout_close_failed",
              "failed old output close keeps its actual endpoint and exposes the radio error");
        check(log->output_opened == open_count_before &&
              log->output_close_attempts == close_attempts_before + 1,
              "the candidate WaveOut is neither opened nor closed when the old handle remains open");
        log->output_close_fails_while_open = false;
        check(get_within(engine.stop(), 5s, "stop after old output close failure").status ==
                  CommandStatus::accepted,
              "the tracked old WaveOut closes after the fake driver recovers");
    }

    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        check(get_within(engine.start(base_config()), 5s,
                         "start before failed new radio output open").status == CommandStatus::accepted,
              "second radio runtime starts for failed new-output recovery");
        check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& snapshot) {
                  return snapshot.hri_ready && snapshot.wave_out_open;
              }), "old output is live before the replacement open fails");
        log->output_reopen_fails = true;
        wirex::engine::AudioEndpoints requested{};
        requested.wave_in_id = 2U;
        requested.wave_out_id = 3U;
        requested.expected_wave_in_endpoint_id = L"fake-input-2";
        requested.expected_wave_out_endpoint_id = L"bad-output";
        const auto result = get_within(engine.set_audio_endpoints(requested), 2s,
                                       "fail candidate open and restoration of the old output");
        auto snapshot = engine.snapshot();
        check(result.status == CommandStatus::failed &&
              result.detail == "waveout_open_failed_restore_failed" &&
              !snapshot->wave_out_open && snapshot->radio_error == "waveout_open_failed_restore_failed" &&
              snapshot->wave_out_endpoint_id == L"fake-output-1" &&
              snapshot->audio_endpoints_revision == 0U,
              "when both new open and old restore fail, the snapshot reports no active output and preserves the saved old choice");
        log->output_reopen_fails = false;
        const int open_count_before_recovery = log->output_opened.load();
        wirex::engine::AudioEndpoints recovered{};
        recovered.wave_in_id = 3U;
        recovered.wave_out_id = 4U;
        recovered.expected_wave_in_endpoint_id = L"fake-input-3";
        recovered.expected_wave_out_endpoint_id = L"fake-output-recovered";
        const auto recovery = get_within(engine.set_audio_endpoints(recovered), 2s,
                                         "restore an output while HRI remains ready");
        snapshot = engine.snapshot();
        check(recovery.status == CommandStatus::accepted && snapshot->hri_ready &&
              snapshot->wave_out_open &&
              snapshot->wave_out_endpoint_id == L"fake-output-recovered" &&
              snapshot->radio_error.empty() &&
              log->output_opened == open_count_before_recovery + 1,
              "a ready HRI opens and retains the newly selected output immediately after a failed switch");
        check(get_within(engine.stop(), 5s, "stop after both output opens fail").status ==
                  CommandStatus::accepted,
              "the failed output switch still permits bounded engine cleanup");
    }

    {
        LoopbackMaster master(100U);
        master.reject_auth(false);
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        auto config = make_bm_only_config(master, L"fake-output-1");
        config.bm_start_disconnected = false;
        check(get_within(engine.start(std::move(config)), 5s,
                         "start BM-only before quarantining a partial WaveOut").status ==
                  CommandStatus::accepted,
              "BM-only runtime starts for a partially opened output test");
        check(wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& snapshot) {
                  return !snapshot.hri_ready && snapshot.bm_link == wirex::engine::BmLink::connected &&
                      snapshot.bm_state == wirex::bm::State::ready && snapshot.wave_out_open;
              }), "BM and the original local output become ready before switching");
        log->output_close_failure_endpoint = L"bad-output";
        log->output_open_fails_but_remains_open = true;
        log->output_close_fails_while_open = true;
        wirex::engine::AudioEndpoints requested{};
        requested.wave_out_id = 3U;
        requested.expected_wave_out_endpoint_id = L"bad-output";
        const auto failed = get_within(engine.set_audio_endpoints(requested), 2s,
                                       "retain a candidate that fails open and refuses close");
        check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& state) {
                  return state.wave_out_endpoint_id == L"bad-output" &&
                      state.local_audio_error == "waveout_open_failed_cleanup_unconfirmed";
              }),
              "the switch reaches the quarantined bad-output candidate rather than failing on the old output");
        auto snapshot = engine.snapshot();
        check(failed.status == CommandStatus::failed &&
              failed.detail == "waveout_open_failed_cleanup_unconfirmed" &&
              snapshot->wave_out_open && snapshot->radio_error.empty() &&
              snapshot->local_audio_error == "waveout_open_failed_cleanup_unconfirmed" &&
              snapshot->wave_in_endpoint_id.empty() &&
              snapshot->wave_out_endpoint_id == L"bad-output",
              "a partially prepared output candidate stays owned and reports its local playback error without a WaveIn selection");
        const int submits_before_call = log->output_submitted.load();
        wirex::dmr_call::Transmitter transmitter;
        const auto voice = make_test_downlink_voice();
        check(send_test_downlink_header(master, transmitter, 91U),
              "fake Master sends a call while the candidate output is quarantined");
        std::this_thread::sleep_for(60ms);
        for (std::size_t index = 0U; index < 5U; ++index) {
            check(send_test_downlink_voice(master, transmitter, voice),
                  "fake Master sends voice while the output is quarantined");
            std::this_thread::sleep_for(60ms);
        }
        check(wait_for_local_rx_active(engine, 2s),
              "incoming BM call remains visible with a quarantined output handle");
        check(log->output_submitted.load() == submits_before_call &&
              engine.snapshot()->phase == wirex::engine::Phase::running &&
              engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
              "quarantined WaveOut receives no PCM and does not stop the BM call/runtime");
        const auto ended_before = engine.snapshot()->counters.calls_ended;
        check(send_test_downlink_terminator(master, transmitter),
              "fake Master ends the call while output remains quarantined");
        const auto call_end_deadline = std::chrono::steady_clock::now() + 4s;
        bool call_ended = false;
        while (std::chrono::steady_clock::now() < call_end_deadline) {
            const auto state = engine.snapshot();
            if (!state->active_rx_call && state->counters.calls_ended > ended_before) {
                call_ended = true;
                break;
            }
            std::this_thread::sleep_for(5ms);
        }
        const auto after_end = engine.snapshot();
        check(call_ended, std::string("BM call stream ends after silent drain; active=") +
              (after_end->active_rx_call ? "true" : "false") + ", ended=" +
              std::to_string(after_end->counters.calls_ended) + ", previous=" +
              std::to_string(ended_before));
        const bool router_idle = wait_for_snapshot(engine, 2s, [](const auto& state) {
            return state.media_owner == wirex::talkgroup_routing::MediaOwner::idle;
        });
        check(router_idle, "Router releases the BM RX media lease after the call ends");
        const auto drained = engine.snapshot();
        check(!drained->local_audio.call_active &&
              drained->local_audio.route == wirex::bm_local_playback::Route::inactive &&
              log->output_submitted.load() == submits_before_call,
              "silent PCM draining finishes without submitting frames to the quarantined WaveOut");
        log->output_close_fails_while_open = false;
        const auto stopped = get_within(engine.stop(), 5s,
                                        "stop after the partially opened output closes");
        check(stopped.status == CommandStatus::accepted,
              std::string("retained candidate output can be closed during bounded shutdown; status=") +
                  std::to_string(static_cast<int>(stopped.status)) + ", detail=" + stopped.detail +
                  ", output_close_attempts=" + std::to_string(log->output_close_attempts.load()) +
                  ", output_closed=" + std::to_string(log->output_closed.load()));
    }
}

void test_partial_audio_endpoint_commit_matches_ptt_input()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-partial-endpoint-ptt";
    config.resolved_master = master.endpoint();
    config.bm_start_disconnected = false;
    config.manual_ptt = true;
    check(get_within(engine.start(std::move(config)), 5s,
                     "start for partial audio endpoint and PTT check").status == CommandStatus::accepted,
          "BM and HRI start for the partial endpoint PTT check");
    check(wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& state) {
              return state.hri_ready && state.bm_link == wirex::engine::BmLink::connected &&
                  state.bm_state == wirex::bm::State::ready;
          }), "HRI and the localhost fake Master are ready before endpoint selection");

    log->output_close_failure_endpoint = L"bad-output";
    log->output_open_fails_but_remains_open = true;
    log->output_close_fails_while_open = true;
    wirex::engine::AudioEndpoints requested{};
    requested.wave_in_id = 2U;
    requested.wave_out_id = 3U;
    requested.expected_wave_in_endpoint_id = L"fake-input-2";
    requested.expected_wave_out_endpoint_id = L"bad-output";
    const auto failed = get_within(engine.set_audio_endpoints(requested), 2s,
                                   "fail output cleanup after validating a new WaveIn");
    check(failed.status == CommandStatus::failed &&
          failed.detail == "waveout_open_failed_cleanup_unconfirmed" &&
          wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& state) {
              return state.wave_in_endpoint_id == L"fake-input-1" &&
                  state.wave_out_endpoint_id == L"bad-output" &&
                  state.radio_error == "waveout_open_failed_cleanup_unconfirmed";
          }),
          "uncertain candidate ownership commits its output ID only and keeps the old input ID");
    auto state = engine.snapshot();
    check(get_within(engine.manual_ptt_toggle(), 2s,
                     "start manual PTT after partial output commit").status == CommandStatus::accepted &&
          wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.wave_in_open;
          }), "manual PTT opens the input retained by the partial commit");
    {
        std::lock_guard<std::mutex> lock(log->input_endpoint_mutex);
        check(log->last_opened_input_endpoint == state->wave_in_endpoint_id &&
              log->last_opened_input_endpoint == L"fake-input-1",
              "actual PTT WaveIn matches the endpoint retained in the snapshot");
    }
    log->output_close_fails_while_open = false;
    const auto stopped = get_within(engine.stop(), 5s, "stop after partial endpoint PTT check");
    check(stopped.status == CommandStatus::accepted,
          "engine cleans up the PTT lease and retained candidate output");
}

void test_audio_warning_commit_matches_ptt_input()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = base_config();
    config.audio.expected_wave_out_endpoint_id = L"old-close-false";
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-warning-endpoint-ptt";
    config.resolved_master = master.endpoint();
    config.bm_start_disconnected = false;
    config.manual_ptt = true;
    check(get_within(engine.start(std::move(config)), 5s,
                     "start for old-close-warning endpoint commit").status == CommandStatus::accepted,
          "BM and HRI start for the accepted-warning PTT check");
    check(wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& state) {
              return state.hri_ready && state.bm_link == wirex::engine::BmLink::connected &&
                  state.bm_state == wirex::bm::State::ready && state.wave_out_open;
          }), "old WaveOut and the localhost fake Master are ready before switching");

    wirex::engine::AudioEndpoints requested{};
    requested.wave_in_id = 2U;
    requested.wave_out_id = 2U;
    requested.expected_wave_in_endpoint_id = L"fake-input-2";
    requested.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto switched = get_within(engine.set_audio_endpoints(requested), 2s,
                                     "accept the replacement after old close reports a warning");
    check(switched.status == CommandStatus::accepted &&
          switched.detail == "waveout_old_endpoint_closed_with_cleanup_warning" &&
          wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& state) {
              return state.wave_in_endpoint_id == L"fake-input-2" &&
                  state.wave_out_endpoint_id == L"fake-output-2" && state.wave_out_open;
          }), "accepted warning commits the input and output endpoints as a pair");
    const auto state = engine.snapshot();
    check(get_within(engine.manual_ptt_toggle(), 2s,
                     "start manual PTT after accepted endpoint warning").status == CommandStatus::accepted &&
          wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& snapshot) {
              return snapshot.wave_in_open;
          }), "manual PTT opens the input installed by the accepted pair commit");
    {
        std::lock_guard<std::mutex> lock(log->input_endpoint_mutex);
        check(log->last_opened_input_endpoint == state->wave_in_endpoint_id &&
              log->last_opened_input_endpoint == L"fake-input-2",
              "actual PTT WaveIn matches the newly committed input endpoint");
    }
    const auto stopped = get_within(engine.stop(), 5s, "stop after accepted warning PTT check");
    check(stopped.status == CommandStatus::accepted,
          "engine cleans up the PTT lease after the paired endpoint commit");
}

void test_hri_quarantined_output_call_releases_lease_and_recovers()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    FakeOptions options{};
    options.acknowledge_t_records = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, options));
    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-hri-quarantined-output";
    config.resolved_master = master.endpoint();
    config.bm_start_disconnected = false;
    check(get_within(engine.start(std::move(config)), 5s,
                     "start HRI and localhost BM for quarantined-output RX test").status ==
              CommandStatus::accepted,
          "HRI/BM runtime starts before output quarantine");
    check(wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& state) {
              return state.hri_ready && state.bm_link == wirex::engine::BmLink::connected &&
                  state.bm_state == wirex::bm::State::ready && state.wave_out_open;
          }), "HRI, BM and the original output are ready before switching");

    log->output_close_failure_endpoint = L"bad-output";
    log->output_open_fails_but_remains_open = true;
    log->output_close_fails_while_open = true;
    wirex::engine::AudioEndpoints requested{};
    requested.wave_in_id = 2U;
    requested.wave_out_id = 3U;
    requested.expected_wave_in_endpoint_id = L"fake-input-2";
    requested.expected_wave_out_endpoint_id = L"bad-output";
    const auto selection = get_within(engine.set_audio_endpoints(requested), 2s,
                                      "quarantine WaveOut candidate while HRI remains ready");
    check(selection.status == CommandStatus::failed &&
          selection.detail == "waveout_open_failed_cleanup_unconfirmed" &&
          wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& state) {
              return state.hri_ready && state.wave_out_open &&
                  state.wave_out_endpoint_id == L"bad-output" &&
                  state.radio_error == "waveout_open_failed_cleanup_unconfirmed";
          }), "the failed candidate remains tracked and quarantined while HRI stays ready");

    const auto first_t_before = log->t_records.load();
    wirex::dmr_call::Transmitter first;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, first, 91U),
          "fake Master starts the first HRI-routed BM call");
    std::this_thread::sleep_for(60ms);
    for (std::size_t index = 0U; index < 5U; ++index) {
        check(send_test_downlink_voice(master, first, voice),
              "fake Master sends first-call voice while WaveOut is quarantined");
        std::this_thread::sleep_for(60ms);
    }
    check(wait_for_local_rx_active(engine, 2s),
          "the first HRI-routed call remains visible after the WaveOut failure");
    const auto first_ended_before = engine.snapshot()->counters.calls_ended;
    check(send_test_downlink_terminator(master, first),
          "fake Master ends the first HRI-routed call");
    check(wait_for_local_rx_idle(engine, first_ended_before, 4s),
          "confirmed HRI T0 and drained silent PCM release the first Router lease");
    const auto first_state = engine.snapshot();
    check(first_state->hri_t3_record_observed && first_state->hri_t0_record_observed,
          "the first-call snapshot confirms both HRI T3 and T0 records were observed");
    check(log->t_records.load() >= first_t_before + 2 &&
          engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected &&
          engine.snapshot()->radio_error == "waveout_open_failed_cleanup_unconfirmed" &&
          engine.snapshot()->wave_out_open && engine.snapshot()->wave_out_endpoint_id == L"bad-output" &&
          engine.snapshot()->media_owner == wirex::talkgroup_routing::MediaOwner::idle &&
          !engine.snapshot()->local_audio.call_active &&
          log->output_submitted.load() == 0,
          "HRI T3/T0 complete while the blocked WaveOut remains owned, visible and unused");

    const auto next_t_before = log->t_records.load();
    wirex::dmr_call::Transmitter following;
    check(send_test_downlink_header(master, following, 92U),
          "fake Master starts another call after the first Router lease cleanup");
    std::this_thread::sleep_for(60ms);
    for (std::size_t index = 0U; index < 5U; ++index) {
        check(send_test_downlink_voice(master, following, voice),
              "fake Master sends the later call while the output stays quarantined");
        std::this_thread::sleep_for(60ms);
    }
    check(wait_for_local_rx_active(engine, 2s),
          "a later HRI-routed call is admitted after the quarantined-output cleanup");
    const auto following_ended_before = engine.snapshot()->counters.calls_ended;
    check(send_test_downlink_terminator(master, following),
          "fake Master ends the later HRI-routed call");
    check(wait_for_local_rx_idle(engine, following_ended_before, 4s) &&
          log->t_records.load() >= next_t_before + 2 &&
          engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "later T3/T0 and silent drain also release the Router lease without stopping BM");
    const auto following_state = engine.snapshot();
    check(following_state->hri_t3_record_observed && following_state->hri_t0_record_observed,
          "the later-call snapshot confirms both HRI T3 and T0 records were observed");

    log->output_close_fails_while_open = false;
    const auto stopped = get_within(engine.stop(), 5s,
                                    "stop after HRI calls used a retained blocked output");
    check(stopped.status == CommandStatus::accepted,
          "bounded stop closes the retained candidate once the fake driver permits cleanup");
}

void test_hri_healthy_waveout_downlink_end_to_end()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    FakeOptions options{};
    options.acknowledge_t_records = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, options));
    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = "offline-healthy-hri-downlink";
    config.resolved_master = master.endpoint();
    config.bm_start_disconnected = false;
    check(get_within(engine.start(std::move(config)), 5s,
                     "start healthy HRI/WaveOut and localhost BM downlink test").status ==
              CommandStatus::accepted,
          "runtime starts with healthy HRI and WaveOut endpoints");
    check(wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& state) {
              return state.hri_ready && state.bm_link == wirex::engine::BmLink::connected &&
                  state.bm_state == wirex::bm::State::ready && state.wave_out_open;
          }), "HRI, WaveOut and localhost BM are ready before the call");

    const auto submitted_before = log->output_submitted.load();
    const auto completed_before = log->output_completed.load();
    const auto t_records_before = log->t_records.load();
    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 91U),
          "fake Master sends a healthy HRI-routed DMRD header");
    std::this_thread::sleep_for(60ms);
    for (std::size_t index = 0U; index < 7U; ++index) {
        check(send_test_downlink_voice(master, transmitter, voice),
              "fake Master sends voice for the healthy HRI-routed call");
        std::this_thread::sleep_for(60ms);
    }
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& state) {
              return state.active_rx_call.has_value() && state.hri_t3_record_observed;
          }), "the engine observes HRI T3 and publishes the incoming call");
    const auto submit_deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < submit_deadline &&
           log->output_submitted.load() == submitted_before) std::this_thread::sleep_for(5ms);
    check(log->output_submitted.load() > submitted_before,
          "decoded BM audio is submitted to the selected healthy WaveOut");

    const auto ended_before = engine.snapshot()->counters.calls_ended;
    check(send_test_downlink_terminator(master, transmitter),
          "fake Master ends the healthy HRI-routed DMRD call");
    check(wait_for_local_rx_idle(engine, ended_before, 4s),
          "the healthy HRI T0 and WaveOut drain release the Router lease");
    const auto state = engine.snapshot();
    const auto submitted_after = log->output_submitted.load();
    const auto completed_after = log->output_completed.load();
    check(state->hri_t3_record_observed && state->hri_t0_record_observed &&
          state->phase == wirex::engine::Phase::running && state->hri_ready &&
          state->bm_link == wirex::engine::BmLink::connected &&
          state->media_owner == wirex::talkgroup_routing::MediaOwner::idle &&
          !state->active_rx_call && !state->local_audio.call_active &&
          state->radio_error.empty() && state->local_audio_error.empty() &&
          submitted_after > submitted_before &&
          completed_after - completed_before == submitted_after - submitted_before &&
          log->t_records.load() >= t_records_before + 2,
          "healthy HRI T3/T0, completed WaveOut PCM and Router cleanup all succeed");
    check(get_within(engine.stop(), 5s,
                     "stop after healthy HRI/WaveOut downlink").status == CommandStatus::accepted,
          "the healthy downlink runtime stops cleanly after cleanup");
}

void test_output_only_selection_recovers_and_switches_with_hri()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = base_config();
    config.start_radio = false;
    config.hri_port.clear();
    config.hri_body_file.clear();
    config.audio = {};
    config.audio.expected_wave_out_endpoint_id = L"bad-output";
    check(get_within(engine.start(std::move(config)), 5s, "start with local WaveOut open failure").status ==
              CommandStatus::accepted,
          "an unavailable initial WaveOut does not fail the BM runtime");
    check(!engine.snapshot()->wave_out_open &&
          engine.snapshot()->local_audio.output_error == wirex::bm_local_playback::OutputError::open_failed,
          "failed local output open is reflected in the runtime snapshot");

    wirex::engine::AudioEndpoints output_only{};
    output_only.wave_out_id = 2U;
    output_only.expected_wave_out_endpoint_id = L"fake-output-local";
    const auto recovered = get_within(engine.set_audio_endpoints(output_only), 2s,
                                      "select a WaveOut without a WaveIn endpoint");
    check(recovered.status == CommandStatus::accepted && engine.snapshot()->wave_out_open &&
          engine.snapshot()->wave_out_endpoint_id == L"fake-output-local" &&
          engine.snapshot()->wave_in_endpoint_id.empty() &&
          engine.snapshot()->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready,
          "output-only endpoint selection recovers audio without requiring WaveIn");

    wirex::engine::AudioEndpoints unavailable_replacement{};
    unavailable_replacement.wave_out_id = 3U;
    unavailable_replacement.expected_wave_out_endpoint_id = L"bad-output";
    const auto failed_switch = get_within(engine.set_audio_endpoints(unavailable_replacement), 2s,
                                           "fail new local output and restore the old endpoint");
    const auto restored_snapshot = engine.snapshot();
    check(failed_switch.status == CommandStatus::failed && failed_switch.detail == "waveout_open_failed" &&
          restored_snapshot->wave_out_open &&
          restored_snapshot->wave_out_endpoint_id == L"fake-output-local" &&
          restored_snapshot->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready &&
          restored_snapshot->local_audio.output_error == wirex::bm_local_playback::OutputError::none &&
          restored_snapshot->local_audio_error.empty(),
          "failed local output selection keeps the old endpoint usable and clears its transient error");

    wirex::engine::RadioStartConfig radio{};
    radio.hri_port = L"COM99";
    radio.hri_body_file = "C:/fake/device-y.bin";
    radio.audio.wave_in_id = 2U;
    radio.audio.wave_out_id = 2U;
    radio.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    radio.audio.expected_wave_out_endpoint_id = L"fake-output-local";
    check(get_within(engine.connect_radio(std::move(radio)), 2s,
                     "attach HRI after BM-only WaveOut startup").status == CommandStatus::accepted,
          "HRI attach still works after a failed local output switch restores the old endpoint");
    const auto radio_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < radio_deadline && !engine.snapshot()->hri_ready)
        std::this_thread::sleep_for(5ms);
    check(engine.snapshot()->hri_ready && engine.snapshot()->serial_open && engine.snapshot()->wave_out_open,
          "HRI handshake opens its paired WaveOut after the BM-only output is released");
    check(get_within(engine.disconnect_radio(), 2s, "detach HRI and restore local WaveOut").status ==
              CommandStatus::accepted,
          "radio detach returns ownership to the BM-only local output path");
    const auto local_deadline = std::chrono::steady_clock::now() + 3s;
    while (std::chrono::steady_clock::now() < local_deadline && engine.snapshot()->serial_open)
        std::this_thread::sleep_for(5ms);
    check(!engine.snapshot()->serial_open && engine.snapshot()->wave_out_open &&
          engine.snapshot()->wave_in_endpoint_id.empty() &&
          engine.snapshot()->wave_out_endpoint_id == L"fake-output-local" &&
          engine.snapshot()->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready,
          "radio detach closes HRI resources and restores the selected local WaveOut alone");
    check(engine.stop().wait_for(5s) == std::future_status::ready,
          "runtime with output-only audio can stop after a radio attach cycle");
}

void test_local_output_close_warning_keeps_audio_ready()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = make_bm_only_config(master, L"old-close-false");
    check(get_within(engine.start(std::move(config)), 5s,
                     "start with a local output that reports a closed-with-warning result").status ==
              CommandStatus::accepted,
          "BM-only runtime starts with the old local output selected");
    check(engine.snapshot()->wave_out_open, "old local WaveOut is open before switching");
    wirex::engine::AudioEndpoints requested{};
    requested.wave_out_id = 2U;
    requested.expected_wave_out_endpoint_id = L"fake-output-new";
    const auto switched = get_within(engine.set_audio_endpoints(requested), 2s,
                                     "switch after old local close reports a warning");
    const auto snapshot = engine.snapshot();
    check(switched.status == CommandStatus::accepted && switched.detail ==
              "waveout_old_endpoint_closed_with_cleanup_warning" &&
          snapshot->wave_out_open && snapshot->wave_out_endpoint_id == L"fake-output-new" &&
          snapshot->local_audio.audio_state == wirex::bm_local_playback::AudioState::ready &&
          snapshot->local_audio.output_error == wirex::bm_local_playback::OutputError::none &&
          snapshot->local_audio_error.empty(),
          "the cleanup warning remains in the result while the new local WaveOut is reported ready");
    check(get_within(engine.stop(), 5s, "stop after warning-only local output switch").status ==
              CommandStatus::accepted,
          "warning-only output switch still stops cleanly");
}

void test_hri_failure_preserves_pending_bm_local_receive()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    FakeOptions options{};
    options.hri_behavior = FakeHriBehavior::missing_y_ack;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, options));
    auto config = make_bm_only_config(master, L"fake-output-local");
    check(get_within(engine.start(std::move(config)), 5s, "start BM runtime for pending HRI failure case").status ==
              CommandStatus::accepted,
          "BM runtime starts before the independent HRI attach attempt");
    check(get_within(engine.set_bm_connection(true, 1U), 2s, "connect BM for pending HRI failure case").status ==
              CommandStatus::accepted,
          "BM connection request is accepted while local output is selected");
    const auto bm_deadline = std::chrono::steady_clock::now() + 4s;
    while (std::chrono::steady_clock::now() < bm_deadline &&
           engine.snapshot()->bm_link != wirex::engine::BmLink::connected) std::this_thread::sleep_for(5ms);

    wirex::engine::RadioStartConfig radio{};
    radio.hri_port = L"COM99";
    radio.hri_body_file = "C:/fake/device-y.bin";
    radio.audio.wave_in_id = 1U;
    radio.audio.wave_out_id = 1U;
    radio.audio.expected_wave_in_endpoint_id = L"fake-input-1";
    radio.audio.expected_wave_out_endpoint_id = L"fake-output-local";
    check(get_within(engine.connect_radio(std::move(radio)), 2s,
                     "start fake HRI handshake that will fail").status == CommandStatus::accepted,
          "HRI starts independently while the BM session remains ready");
    const auto y_deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < y_deadline && log->y_records.load() == 0)
        std::this_thread::sleep_for(5ms);
    check(log->y_records.load() != 0 &&
          wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& state) {
              return !state.hri_ready && !state.wave_out_open;
          }),
          "the fake HRI is waiting for Y/0 while it temporarily owns the shared WaveOut");

    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 43U),
          "BM delivers an admitted header while HRI has not acknowledged Y/0");
    const auto pending_deadline = std::chrono::steady_clock::now() + 1s;
    while (std::chrono::steady_clock::now() < pending_deadline &&
           !engine.snapshot()->local_audio.call_active) std::this_thread::sleep_for(5ms);
    check(engine.snapshot()->local_audio.call_active && !engine.snapshot()->active_rx_call,
          "BM header reserves a pending local receive before the first voice burst");

    // Trigger a deterministic offline serial failure so the pending BM call can
    // prove it survives detach before the pipeline's three-second voice deadline.
    log->serial_blocked = true;
    const auto detach_deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < detach_deadline && engine.snapshot()->serial_open)
        std::this_thread::sleep_for(5ms);
    check(!engine.snapshot()->serial_open && engine.snapshot()->wave_out_open &&
          engine.snapshot()->local_audio.call_active &&
          engine.snapshot()->local_audio.route == wirex::bm_local_playback::Route::local_output,
          "HRI failure restores local WaveOut and retargets only the still-pending BM header");

    std::this_thread::sleep_for(60ms);
    bool saw_started = false;
    for (std::size_t index = 0U; index < 6U; ++index) {
        check(send_test_downlink_voice(master, transmitter, voice),
              "post-detach BM voice burst remains deliverable");
        if (index == 1U) saw_started = wait_for_local_rx_active(engine, 1s);
        std::this_thread::sleep_for(60ms);
    }
    check(saw_started && engine.snapshot()->active_rx_call && log->output_submitted.load() > 0,
          "the preserved header is admitted after the first voice and decoded to local WaveOut");
    check(send_test_downlink_terminator(master, transmitter),
          "post-detach BM call ends through the normal DMRD path");
    const auto ended_before = engine.snapshot()->counters.calls_ended;
    check(wait_for_local_rx_idle(engine, ended_before, 4s),
          "post-detach local playback releases its Router lease normally");

    wirex::dmr_call::Transmitter following;
    check(send_test_downlink_header(master, following, 44U),
          "a subsequent BM call starts after the HRI failure cleanup");
    std::this_thread::sleep_for(60ms);
    for (std::size_t index = 0U; index < 4U; ++index) {
        check(send_test_downlink_voice(master, following, voice),
              "the following call's voice is accepted after cleanup");
        std::this_thread::sleep_for(60ms);
    }
    check(wait_for_local_rx_active(engine, 1s),
          "a later BM call is visible after pending-header detach cleanup");
    check(send_test_downlink_terminator(master, following),
          "the following BM call terminates normally");
    const auto second_ended_before = engine.snapshot()->counters.calls_ended;
    check(wait_for_local_rx_idle(engine, second_ended_before, 4s),
          "the next call also releases its local Router lease");
    check(log->t_records.load() == 0 && engine.snapshot()->phase == wirex::engine::Phase::running &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "BM-only calls after HRI failure send no T3/T0 and keep BM runtime ready");
    check(get_within(engine.stop(), 5s, "stop after pending-header HRI failure case").status ==
              CommandStatus::accepted,
          "runtime stops cleanly after the pending local receive is released");
}

void test_failed_local_waveout_handoff_latches_serial_close_uncertainty()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = make_bm_only_config(master, L"fake-output-local");
    check(get_within(engine.start(std::move(config)), 5s,
                     "start before failed local WaveOut handoff").status == CommandStatus::accepted,
          "BM runtime starts with the local output selected");
    check(engine.snapshot()->wave_out_open && !engine.snapshot()->serial_open,
          "local WaveOut is owned before HRI attach starts");

    log->output_close_fails_while_open = true;
    log->serial_close_fails = true;
    wirex::engine::RadioStartConfig radio{};
    radio.hri_port = L"COM99";
    radio.hri_body_file = "C:/fake/device-y.bin";
    radio.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    radio.audio.expected_wave_out_endpoint_id = L"fake-output-local";
    const auto failed_attach = get_within(engine.connect_radio(std::move(radio)), 2s,
                                           "fail local WaveOut handoff and new serial close");
    auto state = engine.snapshot();
    check(failed_attach.status == CommandStatus::failed &&
          failed_attach.detail == "serial_close_unconfirmed" && !state->serial_open &&
          state->radio_error == "serial_close_unconfirmed" && state->wave_out_open,
          "failed handoff reports the unconfirmed serial close while retaining the original WaveOut");
    check(state->local_audio.output_error == wirex::bm_local_playback::OutputError::close_failed &&
          state->local_audio_error == "waveout_close_failed" && log->serial_opened == 1 &&
          log->serial_close_attempts == 1 && log->serial_closed == 0,
          "both resource failures remain visible and the candidate COM handle gets one close attempt");

    wirex::engine::RadioStartConfig retry{};
    retry.hri_port = L"COM99";
    retry.hri_body_file = "C:/fake/device-y.bin";
    retry.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    retry.audio.expected_wave_out_endpoint_id = L"fake-output-local";
    const auto blocked = get_within(engine.connect_radio(std::move(retry)), 2s,
                                     "prevent another attach after uncertain candidate close");
    check(blocked.status == CommandStatus::busy &&
          blocked.detail == "radio_serial_close_unconfirmed" && log->serial_opened == 1 &&
          log->serial_close_attempts == 1,
          "the failure latch prevents a second COM open or another unsafe close attempt");
    log->output_close_fails_while_open = false;
    const auto stopped = get_within(engine.stop(), 5s,
                                    "stop after uncertain candidate serial cleanup");
    check(stopped.status == CommandStatus::failed &&
          stopped.detail == "owned_resource_cleanup_failed" && log->serial_close_attempts == 1,
          "shutdown reports the unresolved serial cleanup without retrying the consumed handle");
}

// ---------- R130 FM 中继 ----------

wirex::engine::StartConfig relay_config(const LoopbackMaster& master, const char* password)
{
    auto config = base_config();
    config.bm.master_host = "127.0.0.1";
    config.bm.master_port = master.endpoint().port;
    config.bm.profile.password = password;
    config.resolved_master = master.endpoint();
    config.bm_start_disconnected = false;
    return config;
}

bool wait_hri_and_bm_ready(wirex::engine::Engine& engine)
{
    return wait_for_snapshot(engine, 4s, [](const wirex::engine::Snapshot& s) {
        return s.hri_ready && s.bm_link == wirex::engine::BmLink::connected &&
            s.bm_state == wirex::bm::State::ready;
    });
}

std::optional<wirex::engine::Event> wait_relay_event(wirex::engine::Engine& engine, wirex::engine::EventKind kind,
                                                     std::chrono::milliseconds timeout)
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        for (auto& event : engine.drain_events()) {
            if (event.kind == kind) return event;
        }
        std::this_thread::sleep_for(5ms);
    }
    return std::nullopt;
}

void push_x_level(DeviceLog& log, char level)
{
    std::lock_guard<std::mutex> lock(log.x_mutex);
    log.pending_x_levels.push_back(level);
}

void test_relay_fm_start_stop_sends_dmrd_uplink()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    log->input_feeds_pcm = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(relay_config(master, "offline-relay-uplink")), 5s, "start relay uplink").status ==
              CommandStatus::accepted, "runtime starts for FM relay uplink");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before FM relay");
    (void)engine.drain_events();
    const auto dmrd_before = master.dmrd_count();

    const auto started = get_within(engine.relay_fm_start(), 2s, "relay_fm_start");
    check(started.status == CommandStatus::accepted, "relay_fm_start is accepted: " + started.detail);
    const auto snapshot = engine.snapshot();
    check(snapshot->relay_fm_active && snapshot->wave_in_open && snapshot->tx_active,
          "snapshot reports relay active with WaveIn open and TX active");
    const auto started_event = wait_relay_event(engine, wirex::engine::EventKind::relay_fm_started, 1s);
    check(started_event && started_event->relay_fm && started_event->relay_fm->target.destination_id == 91U,
          "relay_fm_started carries the tx_policy target");
    check(get_within(engine.relay_fm_start(), 2s, "second relay_fm_start").status == CommandStatus::idempotent,
          "repeated relay_fm_start is idempotent");

    // 半双工：中继上行期间 BM 来话被 Router 拒绝（media_busy），中继继续。
    wirex::dmr_call::Transmitter downlink;
    check(send_test_downlink_header(master, downlink, 77U), "fake Master sends a downlink during the relay");
    std::this_thread::sleep_for(400ms);
    check(!engine.snapshot()->active_rx_call && engine.snapshot()->relay_fm_active,
          "BM downlink is not admitted while the FM relay uplink is active");

    const auto stopped = get_within(engine.relay_fm_stop(), 2s, "relay_fm_stop");
    check(stopped.status == CommandStatus::accepted, "relay_fm_stop is accepted: " + stopped.detail);
    const auto ended = wait_relay_event(engine, wirex::engine::EventKind::relay_fm_ended, 1s);
    check(ended && ended->end_reason == "squelch_closed" && ended->relay_fm && ended->relay_fm->duration_ms > 0U &&
              ended->relay_fm->target.destination_id == 91U &&
              ended->relay_fm->target.slot == wirex::dmr_call::Slot::ts2,
          "relay_fm_ended reports squelch_closed, duration and target");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) {
              return !s.relay_fm_active && !s.tx_active && !s.wave_in_open;
          }), "relay segment drains and releases WaveIn");
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < deadline && master.dmrd_count() < dmrd_before + 3U) {
        std::this_thread::sleep_for(10ms);
    }
    check(master.dmrd_count() >= dmrd_before + 3U,
          "fake Master receives DMRD header, voice and terminator from the relay: " +
              std::to_string(master.dmrd_count() - dmrd_before));
    check(get_within(engine.relay_fm_stop(), 2s, "idle relay_fm_stop").status == CommandStatus::idempotent,
          "relay_fm_stop without a segment is idempotent");
    check(get_within(engine.stop(), 5s, "stop after relay uplink").status == CommandStatus::accepted,
          "runtime stops cleanly after the FM relay");
}

void test_relay_fm_rejected_during_bm_downlink()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(relay_config(master, "offline-relay-downlink")), 5s, "start relay downlink").status ==
              CommandStatus::accepted, "runtime starts for downlink half-duplex test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before downlink");
    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 91U), "fake Master sends downlink header");
    for (int i = 0; i < 4 && !engine.snapshot()->active_rx_call; ++i) {
        std::this_thread::sleep_for(60ms);
        (void)send_test_downlink_voice(master, transmitter, voice);
    }
    check(wait_for_local_rx_active(engine, 2s), "BM downlink becomes active");
    const auto rejected = get_within(engine.relay_fm_start(), 2s, "relay_fm_start during downlink");
    check(rejected.status == CommandStatus::busy && rejected.detail == "relay_fm_busy_downlink",
          "relay_fm_start is busy during BM downlink: " + rejected.detail);
    check(engine.snapshot()->counters.relay_fm_rejected_busy == 1U && !engine.snapshot()->relay_fm_active,
          "busy rejection is counted and no relay starts");
    const auto ended_before = engine.snapshot()->counters.calls_ended;
    (void)send_test_downlink_terminator(master, transmitter);
    (void)wait_for_local_rx_idle(engine, ended_before, 4s);
    check(get_within(engine.stop(), 5s, "stop after downlink rejection").status == CommandStatus::accepted,
          "runtime stops after downlink rejection test");
}

void test_relay_fm_rejected_while_mic_ptt_active()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    log->input_feeds_pcm = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(relay_config(master, "offline-relay-ptt")), 5s, "start relay ptt").status ==
              CommandStatus::accepted, "runtime starts for mic PTT conflict test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before mic PTT");
    push_x_level(*log, '0');  // 松开：ptt_gate armed
    std::this_thread::sleep_for(100ms);
    push_x_level(*log, '2');  // 按下：手咪上行
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) { return s.tx_active; }),
          "mic PTT press starts the uplink");
    const auto rejected = get_within(engine.relay_fm_start(), 2s, "relay_fm_start during mic PTT");
    check(rejected.status == CommandStatus::busy && rejected.detail == "relay_fm_busy_ptt",
          "relay_fm_start is busy while mic PTT is transmitting: " + rejected.detail);
    auto snapshot = engine.snapshot();
    check(snapshot->counters.relay_fm_rejected_busy == 1U && !snapshot->relay_fm_active && snapshot->tx_active &&
              snapshot->counters.ptt_tx_starts == 1U,
          "only the mic PTT lease exists after the rejected relay start");
    push_x_level(*log, '0');
    const bool released = wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) {
        return !s.tx_active && s.media_owner == wirex::talkgroup_routing::MediaOwner::idle;
    });
    snapshot = engine.snapshot();
    check(released, "mic PTT release ends its uplink; tx=" + std::to_string(snapshot->tx_active) +
              " media=" + std::to_string(static_cast<unsigned>(snapshot->media_owner)) +
              " wavein=" + std::to_string(snapshot->wave_in_open) +
              " ptt_starts=" + std::to_string(snapshot->counters.ptt_tx_starts));

    // 反向：中继进行中按手咪 PTT 不产生第二个上行。
    check(get_within(engine.relay_fm_start(), 2s, "relay_fm_start after PTT").status == CommandStatus::accepted,
          "relay starts once the mic PTT is released");
    push_x_level(*log, '2');
    std::this_thread::sleep_for(300ms);
    snapshot = engine.snapshot();
    check(snapshot->relay_fm_active && snapshot->tx_active && snapshot->counters.ptt_tx_starts == 2U,
          "mic PTT press during the relay does not start a second uplink");
    push_x_level(*log, '0');
    std::this_thread::sleep_for(150ms);
    check(engine.snapshot()->relay_fm_active, "mic PTT release does not end the relay segment");
    check(get_within(engine.relay_fm_stop(), 2s, "relay_fm_stop after PTT").status == CommandStatus::accepted,
          "relay stops normally after the ignored mic PTT");
    check(get_within(engine.stop(), 5s, "stop after PTT conflict").status == CommandStatus::accepted,
          "runtime stops after PTT conflict test");
}

void test_relay_fm_timeout()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    log->input_feeds_pcm = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = relay_config(master, "offline-relay-timeout");
    config.relay_fm_max_duration_ms = 300U;
    check(get_within(engine.start(std::move(config)), 5s, "start relay timeout").status == CommandStatus::accepted,
          "runtime starts for relay timeout test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before relay timeout");
    (void)engine.drain_events();
    check(get_within(engine.relay_fm_start(), 2s, "relay_fm_start for timeout").status == CommandStatus::accepted,
          "relay starts for timeout test");
    const auto ended = wait_relay_event(engine, wirex::engine::EventKind::relay_fm_ended, 3s);
    check(ended && ended->end_reason == "timeout" && ended->relay_fm && ended->relay_fm->duration_ms >= 300U,
          "relay segment ends with reason timeout after the configured limit");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) {
              return !s.relay_fm_active && !s.tx_active && !s.wave_in_open &&
                  s.media_owner == wirex::talkgroup_routing::MediaOwner::idle;
          }), "TX returns to idle after the relay timeout");
    check(get_within(engine.relay_fm_start(), 2s, "relay_fm_start after timeout").status == CommandStatus::accepted,
          "a new relay segment can start after a timeout");
    check(get_within(engine.relay_fm_stop(), 2s, "relay_fm_stop after timeout").status == CommandStatus::accepted,
          "the follow-up segment stops normally");
    check(get_within(engine.stop(), 5s, "stop after relay timeout").status == CommandStatus::accepted,
          "runtime stops after relay timeout test");
}

void test_relay_fm_rejected_when_bm_not_ready()
{
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(base_config()), 5s, "start relay bm not ready").status == CommandStatus::accepted,
          "runtime starts without BM");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) { return s.hri_ready; }),
          "HRI ready without BM");
    const auto not_ready = get_within(engine.relay_fm_start(), 2s, "relay_fm_start without BM");
    check(not_ready.status == CommandStatus::not_ready && not_ready.detail == "relay_fm_bm_not_ready",
          "relay_fm_start is not_ready without BM: " + not_ready.detail);
    const auto revision = engine.snapshot()->tx_policy_revision;
    check(get_within(engine.replace_tx_policy(revision,
              {91U, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts2}, false), 2s,
              "disable transmit").status == CommandStatus::accepted, "transmit can be disabled");
    const auto forbidden = get_within(engine.relay_fm_start(), 2s, "relay_fm_start with transmit disabled");
    check(forbidden.status == CommandStatus::forbidden && forbidden.detail == "relay_fm_transmit_disabled",
          "relay_fm_start is forbidden when transmit is disabled: " + forbidden.detail);
    check(engine.snapshot()->counters.relay_fm_rejected_busy == 0U && !engine.snapshot()->relay_fm_active,
          "not_ready/forbidden rejections do not count as busy");
    check(get_within(engine.stop(), 5s, "stop after bm not ready").status == CommandStatus::accepted,
          "runtime stops after BM-not-ready test");
}

void test_relay_fm_transmit_revoked_ends_segment()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    log->input_feeds_pcm = true;
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(relay_config(master, "offline-relay-revoke")), 5s, "start relay revoke").status ==
              CommandStatus::accepted, "runtime starts for relay revoke test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before relay revoke");
    (void)engine.drain_events();
    check(get_within(engine.relay_fm_start(), 2s, "relay_fm_start before revoke").status == CommandStatus::accepted,
          "relay starts before transmit revoke");
    const auto revision = engine.snapshot()->tx_policy_revision;
    (void)get_within(engine.replace_tx_policy(revision,
        {91U, wirex::dmr_call::CallKind::group, wirex::dmr_call::Slot::ts2}, false), 2s, "revoke transmit");
    const auto ended = wait_relay_event(engine, wirex::engine::EventKind::relay_fm_ended, 2s);
    check(ended && ended->end_reason == "transmit_disabled",
          "revoking transmit ends the relay segment with reason transmit_disabled");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) {
              return !s.relay_fm_active && !s.tx_active && !s.wave_in_open;
          }), "relay resources are released after the revoke");
    check(get_within(engine.stop(), 5s, "stop after relay revoke").status == CommandStatus::accepted,
          "runtime stops after relay revoke test");
}

// ---------- R131 FM 中继尾音：静音 + 前瞻延迟 ----------

// 引擎线程 status 钩子记录的上行计数（tx_pipeline_* 为实际送入 AMBE 管线的样本）。
struct TxProbePoint {
    std::string event;
    std::uint64_t audio_samples{};
    std::uint64_t pipeline_samples{};
    std::uint64_t pipeline_sum_squares{};
};

struct TxProbe {
    std::mutex mutex{};
    std::vector<TxProbePoint> points{};

    std::optional<TxProbePoint> last(std::string_view event)
    {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto it = points.rbegin(); it != points.rend(); ++it) {
            if (it->event == event) return *it;
        }
        return std::nullopt;
    }
};

void attach_tx_probe(wirex::engine::StartConfig& config, const std::shared_ptr<TxProbe>& probe)
{
    config.diagnostics.status = [probe](const wirex::engine::StatusRecord& record) {
        std::lock_guard<std::mutex> lock(probe->mutex);
        probe->points.push_back({std::string(record.event), record.counters.tx_audio_samples,
                                 record.counters.tx_pipeline_samples,
                                 record.counters.tx_pipeline_stats.sum_squares});
        return true;
    };
}

void test_relay_fm_mute_zeroes_tail_and_keeps_frame_cadence()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    log->input_feeds_pcm = true;  // 假采集：±400 方波（增益后 ±6400），代表“语音”，静音后应全部变为 0
    auto probe = std::make_shared<TxProbe>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = relay_config(master, "offline-relay-mute");
    attach_tx_probe(config, probe);
    check(get_within(engine.start(std::move(config)), 5s, "start relay mute").status == CommandStatus::accepted,
          "runtime starts for relay mute test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before relay mute");
    (void)engine.drain_events();

    const auto idle_mute = get_within(engine.relay_fm_mute(true), 2s, "relay_fm_mute without segment");
    check(idle_mute.status == CommandStatus::idempotent && idle_mute.detail == "relay_fm_not_active",
          "relay_fm_mute outside a segment is idempotent: " + idle_mute.detail);

    check(get_within(engine.relay_fm_start(), 2s, "relay_fm_start for mute").status == CommandStatus::accepted,
          "relay starts for mute test");
    std::this_thread::sleep_for(500ms);  // 语音段
    check(get_within(engine.relay_fm_mute(true), 2s, "mute #1").status == CommandStatus::accepted,
          "relay_fm_mute(true) is accepted during the segment");
    check(engine.snapshot()->relay_fm_muted && engine.snapshot()->relay_fm_active,
          "snapshot reports relay_fm_muted during the segment");
    check(get_within(engine.relay_fm_mute(true), 2s, "mute #1 again").status == CommandStatus::idempotent,
          "repeated mute is idempotent");
    const auto dmrd_at_mute = master.dmrd_count();
    std::this_thread::sleep_for(400ms);  // 尾噪段（假采集仍在送非零样本）
    const auto dmrd_after_mute = master.dmrd_count();
    check(get_within(engine.relay_fm_mute(false), 2s, "unmute").status == CommandStatus::accepted,
          "relay_fm_mute(false) restores the uplink");
    check(!engine.snapshot()->relay_fm_muted, "snapshot clears relay_fm_muted after unmute");
    std::this_thread::sleep_for(400ms);  // 重新开门后的语音
    check(get_within(engine.relay_fm_mute(true), 2s, "mute #2").status == CommandStatus::accepted,
          "second mute (squelch closing again) is accepted");
    std::this_thread::sleep_for(300ms);
    check(get_within(engine.relay_fm_stop(), 2s, "relay_fm_stop after mute").status == CommandStatus::accepted,
          "relay_fm_stop after mute is accepted");
    const auto ended = wait_relay_event(engine, wirex::engine::EventKind::relay_fm_ended, 2s);
    check(ended && ended->end_reason == "squelch_closed", "muted segment still ends with squelch_closed");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) {
              return !s.relay_fm_active && !s.relay_fm_muted && !s.tx_active && !s.wave_in_open &&
                  s.media_owner == wirex::talkgroup_routing::MediaOwner::idle;
          }), "segment end clears the mute and drains TX (EOT sent)");

    const auto start = probe->last("relay_fm_tx_started");
    const auto unmuted = probe->last("relay_fm_unmuted");
    std::optional<TxProbePoint> muted1;
    std::optional<TxProbePoint> muted2;
    {
        std::lock_guard<std::mutex> lock(probe->mutex);
        for (const auto& point : probe->points) {
            if (point.event != "relay_fm_muted") continue;
            if (!muted1) muted1 = point;
            else muted2 = point;
        }
    }
    const auto stopped = probe->last("tx_audio_draining_after_radio_ptt_release");
    check(start && muted1 && unmuted && muted2 && stopped, "status probe captured every relay step");
    if (start && muted1 && unmuted && muted2 && stopped) {
        // 语音段：前瞻延迟 120 ms 后开始送出非零样本。
        check(muted1->pipeline_sum_squares > start->pipeline_sum_squares,
              "voice before the mute reaches the pipeline");
        check(muted1->audio_samples >= muted1->pipeline_samples &&
                  muted1->audio_samples - muted1->pipeline_samples <= 120U * 48U + 960U,
              "lookahead holds back at most ~120 ms of captured audio (held " +
                  std::to_string(muted1->audio_samples - muted1->pipeline_samples) + ")");
        // 静音段：样本照常送入（帧节奏不变）但全为 0。
        check(unmuted->pipeline_sum_squares == muted1->pipeline_sum_squares,
              "every sample delivered while muted is zero");
        const auto muted_samples = unmuted->pipeline_samples - muted1->pipeline_samples;
        check(muted_samples >= 300U * 48U,
              "muted uplink keeps feeding the pipeline (" + std::to_string(muted_samples) + " samples in ~400 ms)");
        check(dmrd_after_mute >= dmrd_at_mute + 4U,
              "DMRD voice bursts keep flowing while muted (" + std::to_string(dmrd_after_mute - dmrd_at_mute) + ")");
        // 恢复段：重新出现非零样本。
        check(muted2->pipeline_sum_squares > unmuted->pipeline_sum_squares, "unmute restores the voice");
        // 第二次静音到结束：缓冲内尾部被丢弃，只送零；捕获计数与送出计数之差不超过一个缓冲。
        check(stopped->pipeline_sum_squares == muted2->pipeline_sum_squares,
              "the muted tail (including the lookahead buffer) never reaches the pipeline");
        check(stopped->pipeline_samples > muted2->pipeline_samples, "frames continue after the second mute");
        check(stopped->audio_samples - stopped->pipeline_samples <= 120U * 48U + 960U,
              "end of segment discards at most the lookahead buffer");
    }
    check(get_within(engine.relay_fm_start(), 2s, "relay_fm_start after muted segment").status == CommandStatus::accepted,
          "a new segment after a muted one starts unmuted");
    check(!engine.snapshot()->relay_fm_muted, "new segment starts unmuted");
    check(get_within(engine.relay_fm_stop(), 2s, "relay_fm_stop second segment").status == CommandStatus::accepted,
          "second segment stops");
    check(get_within(engine.stop(), 5s, "stop after relay mute").status == CommandStatus::accepted,
          "runtime stops after relay mute test");
}

void test_mic_ptt_bypasses_relay_lookahead()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    log->input_feeds_pcm = true;
    auto probe = std::make_shared<TxProbe>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    auto config = relay_config(master, "offline-ptt-no-lookahead");
    attach_tx_probe(config, probe);
    check(get_within(engine.start(std::move(config)), 5s, "start mic PTT lookahead").status == CommandStatus::accepted,
          "runtime starts for mic PTT lookahead test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before mic PTT");
    push_x_level(*log, '0');
    std::this_thread::sleep_for(100ms);
    push_x_level(*log, '2');
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) { return s.tx_active && s.wave_in_open; }),
          "mic PTT starts an uplink");
    std::this_thread::sleep_for(300ms);
    push_x_level(*log, '0');
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) { return !s.tx_active && !s.wave_in_open; }),
          "mic PTT release drains the uplink");
    const auto stopped = probe->last("tx_audio_draining_after_radio_ptt_release");
    check(stopped && stopped->audio_samples > 0U && stopped->audio_samples == stopped->pipeline_samples,
          "mic PTT sends every captured sample straight to the pipeline (no lookahead delay)");
    check(get_within(engine.relay_fm_mute(true), 2s, "mute without relay").status == CommandStatus::idempotent,
          "relay_fm_mute does not affect a mic PTT runtime");
    check(get_within(engine.stop(), 5s, "stop after mic PTT lookahead").status == CommandStatus::accepted,
          "runtime stops after mic PTT lookahead test");
}

// ---------- R131 HRI 自动重连 ----------

std::optional<wirex::engine::Event> wait_event_kind(wirex::engine::Engine& engine, wirex::engine::EventKind kind,
                                                    std::chrono::milliseconds timeout)
{
    return wait_relay_event(engine, kind, timeout);
}

wirex::engine::StartConfig reconnect_config(const LoopbackMaster& master, const char* password)
{
    auto config = relay_config(master, password);
    config.hri_reconnect_interval_ms = 150U;
    config.hri_reconnect_max_interval_ms = 600U;
    return config;
}

void test_hri_reconnects_after_serial_transport_error()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(reconnect_config(master, "offline-hri-reconnect")), 5s,
                     "start HRI reconnect").status == CommandStatus::accepted,
          "runtime starts for HRI reconnect test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before the serial fault");
    (void)engine.drain_events();
    const auto opened_before = log->serial_opened.load();

    // 串口读返回 transport_error，同时打开失败（设备拔出）：进入重连并按退避重试打开。
    log->serial_blocked = true;
    const auto lost = wait_event_kind(engine, wirex::engine::EventKind::hri_lost, 2s);
    check(lost && lost->end_reason == "serial_transport_error",
          "transport error publishes hri_lost with the machine-readable reason");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) {
              return s.hri_reconnecting && !s.hri_ready && !s.serial_open &&
                  s.radio_error == "serial_transport_error" && s.bm_link == wirex::engine::BmLink::connected;
          }), "engine reports hri_reconnecting while BM stays connected");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) {
              return s.hri_reconnect_attempts >= 3U;
          }), "reconnect keeps retrying while the port cannot be opened");
    const auto attempts_early = engine.snapshot()->hri_reconnect_attempts;
    std::this_thread::sleep_for(1200ms);
    const auto attempts_late = engine.snapshot()->hri_reconnect_attempts;
    // 150 ms 起步逐次加倍到 600 ms 上限：1.2 s 内不超过约 3 次（无退避时约 8 次）。
    check(attempts_late > attempts_early && attempts_late - attempts_early <= 3U,
          "serial open failures back off up to the maximum interval (" +
              std::to_string(attempts_late - attempts_early) + " attempts in 1.2 s)");
    check(log->serial_opened.load() == opened_before, "blocked port is never opened");

    log->serial_blocked = false;
    const auto restored = wait_event_kind(engine, wirex::engine::EventKind::hri_restored, 3s);
    check(restored.has_value(), "unblocking the port publishes hri_restored");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) {
              return s.hri_ready && s.serial_open && !s.hri_reconnecting && s.radio_error.empty() &&
                  s.wave_out_open;
          }), "hri_ready returns to true after the reconnect");
    check(engine.snapshot()->failure_reason.find("clock_regressed") == std::string::npos &&
              engine.snapshot()->phase == wirex::engine::Phase::running,
          "reconnect does not trip hri_session clock_regressed");

    // 恢复后再次掉线：新一轮重连（计数从 0 开始）。
    log->y_ack_suppressed = true;
    const auto y_lost = wait_event_kind(engine, wirex::engine::EventKind::hri_lost, 5s);
    check(y_lost && y_lost->end_reason == "hri_y_ack_timeout",
          "a missing Y/0 (radio left HRI mode) also triggers hri_lost");
    check(wait_for_snapshot(engine, 1s, [](const wirex::engine::Snapshot& s) { return s.hri_reconnecting; }),
          "Y/0 timeout enters reconnecting");
    log->y_ack_suppressed = false;
    check(wait_event_kind(engine, wirex::engine::EventKind::hri_restored, 6s).has_value() &&
              wait_for_snapshot(engine, 1s, [](const wirex::engine::Snapshot& s) {
                  return s.hri_ready && !s.hri_reconnecting;
              }),
          "radio back in HRI mode is reconnected automatically");
    check(get_within(engine.stop(), 5s, "stop after HRI reconnect").status == CommandStatus::accepted,
          "runtime stops cleanly after HRI reconnects");
}

void test_hri_reconnect_stops_after_user_disconnect()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(reconnect_config(master, "offline-hri-user-disconnect")), 5s,
                     "start HRI user disconnect").status == CommandStatus::accepted,
          "runtime starts for user disconnect test");
    check(wait_hri_and_bm_ready(engine), "HRI ready before the user disconnect test");
    log->serial_blocked = true;
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) { return s.hri_reconnecting; }),
          "serial fault enters reconnecting");
    const auto stopped = get_within(engine.disconnect_radio(), 2s, "disconnect while reconnecting");
    check(stopped.status == CommandStatus::accepted, "disconnect_radio during reconnect is accepted: " + stopped.detail);
    const auto state = engine.snapshot();
    check(!state->hri_reconnecting && !state->serial_open && state->radio_error.empty(),
          "user disconnect stops the reconnect and clears the radio error");
    const auto attempts = state->hri_reconnect_attempts;
    log->serial_blocked = false;
    const auto opened = log->serial_opened.load();
    std::this_thread::sleep_for(1000ms);
    check(log->serial_opened.load() == opened && engine.snapshot()->hri_reconnect_attempts == attempts &&
              !engine.snapshot()->serial_open && !engine.snapshot()->hri_ready,
          "no reconnect attempts after the user disconnected");

    // 用户主动断开一个正常连接：不触发重连。
    wirex::engine::RadioStartConfig radio{};
    radio.hri_port = L"COM99";
    radio.hri_body_file = "C:/fake/device-y.bin";
    radio.audio.expected_wave_in_endpoint_id = L"fake-input-1";
    radio.audio.expected_wave_out_endpoint_id = L"fake-output-1";
    check(get_within(engine.connect_radio(radio), 2s, "reconnect manually").status == CommandStatus::accepted,
          "manual connect_radio after the cancelled reconnect");
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) { return s.hri_ready; }),
          "manual connect reaches hri_ready");
    (void)engine.drain_events();
    check(get_within(engine.disconnect_radio(), 2s, "user disconnect healthy radio").status == CommandStatus::accepted,
          "user disconnect of a healthy radio is accepted");
    const auto opened_after = log->serial_opened.load();
    std::this_thread::sleep_for(800ms);
    bool lost_seen = false;
    for (const auto& event : engine.drain_events()) lost_seen = lost_seen || event.kind == wirex::engine::EventKind::hri_lost;
    check(!lost_seen && !engine.snapshot()->hri_reconnecting && log->serial_opened.load() == opened_after,
          "a user disconnect never triggers hri_lost or reconnect");

    // 手动连接得到的配置同样会自动重连（connect_radio 保存 RadioStartConfig）。
    check(get_within(engine.connect_radio(radio), 2s, "connect again").status == CommandStatus::accepted &&
              wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) { return s.hri_ready; }),
          "connect_radio again");
    log->serial_blocked = true;
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) { return s.hri_reconnecting; }),
          "connect_radio config reconnects after a fault");
    log->serial_blocked = false;
    check(wait_for_snapshot(engine, 3s, [](const wirex::engine::Snapshot& s) { return s.hri_ready && !s.hri_reconnecting; }),
          "connect_radio config is restored");

    // 探测进行中（串口已打开、等待 Y/0）时用户断开：立即拆除探测并停止重连。
    log->y_ack_suppressed = true;
    check(wait_for_snapshot(engine, 6s, [](const wirex::engine::Snapshot& s) { return s.hri_reconnecting; }),
          "Y/0 loss enters reconnecting before the in-flight probe test");
    const auto probe_opened = log->serial_opened.load();
    const auto probe_deadline = std::chrono::steady_clock::now() + 3s;
    while (std::chrono::steady_clock::now() < probe_deadline && log->serial_opened.load() == probe_opened) {
        std::this_thread::sleep_for(5ms);
    }
    check(log->serial_opened.load() > probe_opened && !engine.snapshot()->serial_open,
          "a probe opened the port but the snapshot does not report it as connected");
    const auto closed_before = log->serial_closed.load();
    const auto cancel = get_within(engine.disconnect_radio(), 2s, "disconnect during in-flight probe");
    check(cancel.status == CommandStatus::accepted && log->serial_closed.load() == closed_before + 1 &&
              !engine.snapshot()->hri_reconnecting,
          "disconnect during an in-flight probe closes its port and stops the reconnect: " + cancel.detail);
    log->y_ack_suppressed = false;
    const auto opened_final = log->serial_opened.load();
    std::this_thread::sleep_for(600ms);
    check(log->serial_opened.load() == opened_final, "no probe after disconnecting an in-flight attempt");
    check(get_within(engine.stop(), 5s, "stop after user disconnect test").status == CommandStatus::accepted,
          "runtime stops after the user disconnect test");
}

void test_bm_playback_continues_during_hri_reconnect()
{
    LoopbackMaster master(100U);
    master.reject_auth(false);
    auto log = std::make_shared<DeviceLog>();
    wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
    check(get_within(engine.start(reconnect_config(master, "offline-hri-reconnect-playback")), 5s,
                     "start reconnect playback").status == CommandStatus::accepted,
          "runtime starts for reconnect playback test");
    check(wait_hri_and_bm_ready(engine), "HRI and BM ready before reconnect playback");
    log->y_ack_suppressed = true;  // 串口仍可打开：每次探测都会打开串口并等待 Y/0
    check(wait_for_snapshot(engine, 6s, [](const wirex::engine::Snapshot& s) {
              return s.hri_reconnecting && s.wave_out_open &&
                  s.local_audio.audio_state == wirex::bm_local_playback::AudioState::ready;
          }), "HRI loss restores BM-only local playback while reconnecting");
    check(wait_for_snapshot(engine, 2s, [](const wirex::engine::Snapshot& s) { return s.hri_reconnect_attempts >= 1U; }),
          "a reconnect probe has started");
    check(engine.snapshot()->hri_reconnecting && !engine.snapshot()->serial_open && engine.snapshot()->wave_out_open,
          "a probe waiting for Y/0 keeps the local WaveOut and is not shown as connected");

    const auto submitted_before = log->output_submitted.load();
    const auto ended_before = engine.snapshot()->counters.calls_ended;
    const auto t_before = log->t_records.load();
    wirex::dmr_call::Transmitter transmitter;
    const auto voice = make_test_downlink_voice();
    check(send_test_downlink_header(master, transmitter, 51U), "BM downlink header during reconnect");
    std::this_thread::sleep_for(60ms);
    bool saw_started = false;
    for (std::size_t index = 0U; index < 6U; ++index) {
        check(send_test_downlink_voice(master, transmitter, voice), "BM downlink voice during reconnect");
        if (index == 1U) saw_started = wait_for_local_rx_active(engine, 1s);
        std::this_thread::sleep_for(60ms);
    }
    check(saw_started && log->output_submitted.load() > submitted_before,
          "BM call plays on the local WaveOut during the reconnect");
    check(engine.snapshot()->hri_reconnecting && engine.snapshot()->bm_link == wirex::engine::BmLink::connected,
          "reconnect continues in the background while the call plays");
    check(send_test_downlink_terminator(master, transmitter), "BM downlink terminator during reconnect");
    check(wait_for_local_rx_idle(engine, ended_before, 4s), "local call ends normally during the reconnect");
    check(log->t_records.load() == t_before, "the reconnect probe never sends HRI T3/T0 for a local call");

    log->y_ack_suppressed = false;
    check(wait_for_snapshot(engine, 8s, [](const wirex::engine::Snapshot& s) {
              return s.hri_ready && !s.hri_reconnecting && s.wave_out_open;
          }), "HRI is restored after the local call and takes over the WaveOut");
    check(get_within(engine.stop(), 5s, "stop after reconnect playback").status == CommandStatus::accepted,
          "runtime stops after the reconnect playback test");
}

void test_destructor_stops_running_engine()
{
    auto log = std::make_shared<DeviceLog>();
    const auto started_at = std::chrono::steady_clock::now();
    {
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{}));
        check(get_within(engine.start(base_config()), 5s, "start before destructor").status == CommandStatus::accepted,
              "start before destructor");
    }
    check(std::chrono::steady_clock::now() - started_at < 6s, "destructor stop is bounded");
    check(log->serial_closed == 1, "destructor closes the serial port");
}

void test_embedded_hri_template()
{
    std::vector<std::uint8_t> body;
    const auto devices = wirex::engine::make_windows_devices();
    check(devices && devices->load_hri_template({}, body), "approved HRI Y template loads from the executable");
    check(body.size() == wirex::hri_session::y_body_size && body[5] == '2',
          "embedded HRI Y template passes size and marker checks");

    // AP 变体：内嵌模板 offset 0x05 改为 '1'，其余 99 字节与 DIRECT 相同，按第二个固定哈希校验。
    std::vector<std::uint8_t> ap_body;
    check(devices && devices->load_hri_template_ap({}, ap_body), "approved AP HRI Y template variant loads");
    bool rest_identical = ap_body.size() == body.size();
    for (std::size_t index = 0U; rest_identical && index < body.size(); ++index) {
        if (index != 5U && ap_body[index] != body[index]) rest_identical = false;
    }
    check(ap_body.size() == wirex::hri_session::y_body_size && ap_body[5] == '1' && rest_identical,
          "AP HRI Y template differs from DIRECT only at offset 0x05");

    // 外部文件：DIRECT 文件在 AP 模式下也被接受（统一改为 '1'）；AP 文件在 DIRECT 模式下被拒绝；改动其它字节被拒绝。
    const auto scratch = std::filesystem::temp_directory_path() /
        ("engine-test-y-" + std::to_string(GetCurrentProcessId()));
    std::error_code ignored;
    std::filesystem::create_directories(scratch, ignored);
    const auto write_body = [&](const std::filesystem::path& path, const std::vector<std::uint8_t>& bytes) {
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        return static_cast<bool>(file);
    };
    const auto direct_file = scratch / "direct.bin";
    const auto ap_file = scratch / "ap.bin";
    const auto tampered_file = scratch / "tampered.bin";
    auto tampered = ap_body;
    tampered[20] = static_cast<std::uint8_t>(tampered[20] ^ 0x01U);
    check(write_body(direct_file, body) && write_body(ap_file, ap_body) && write_body(tampered_file, tampered),
          "scratch Y template files are written");
    std::vector<std::uint8_t> loaded;
    check(devices->load_hri_template_ap(direct_file, loaded) && loaded == ap_body,
          "external DIRECT template is accepted in AP mode and switched to offset 0x05 = '1'");
    check(devices->load_hri_template_ap(ap_file, loaded) && loaded == ap_body,
          "external AP template matches the second approved SHA-256");
    check(!devices->load_hri_template(ap_file, loaded), "AP template is rejected when AP mode is off");
    check(!devices->load_hri_template_ap(tampered_file, loaded), "AP mode still rejects unapproved template bytes");
    std::filesystem::remove_all(scratch, ignored);
}

} // namespace

int main()
{
    try {
        test_event_queue_overflow();
        test_quarantined_rx_output_cleanup_gate_requires_t0_and_full_drain();
        test_embedded_hri_template();
        test_commands_before_start();
        test_start_failures();
        test_hri_handshake_failures_report_exact_stop_reason();
        test_running_engine();
        test_stop_with_reason_and_status_failure();
        test_bm_connection_semantics();
        test_invalid_initial_bm_profile_does_not_fail_runtime_stop();
        test_bm_auth_rejection_does_not_fail_runtime_stop();
        test_connect_radio_after_slow_serial_open_reaches_hri_ready();
        test_radio_bm_independent_lifecycle_and_master_rejection();
        test_rejected_bm_commands_wipe_password_before_completion();
        test_failed_bm_reconfigure_blocks_old_profile_enable();
        test_radio_detach_close_failure_and_recovery();
        test_wavein_detach_close_failure_and_recovery();
        test_serial_detach_close_failure_is_unconfirmed();
        test_bm_only_local_playback_quick_call_and_reconnect();
        test_bm_only_unavailable_output_still_displays_and_drains();
        test_bm_local_output_submit_failure_keeps_call_visible();
        test_radio_output_switch_keeps_failed_handles_tracked();
        test_partial_audio_endpoint_commit_matches_ptt_input();
        test_audio_warning_commit_matches_ptt_input();
        test_hri_quarantined_output_call_releases_lease_and_recovers();
        test_hri_healthy_waveout_downlink_end_to_end();
        test_output_only_selection_recovers_and_switches_with_hri();
        test_local_output_close_warning_keeps_audio_ready();
        test_hri_failure_preserves_pending_bm_local_receive();
        test_failed_local_waveout_handoff_latches_serial_close_uncertainty();
        test_destructor_stops_running_engine();
        test_relay_fm_start_stop_sends_dmrd_uplink();
        test_relay_fm_rejected_during_bm_downlink();
        test_relay_fm_rejected_while_mic_ptt_active();
        test_relay_fm_timeout();
        test_relay_fm_rejected_when_bm_not_ready();
        test_relay_fm_transmit_revoked_ends_segment();
        test_muted_group_call_is_visible_but_silent();
        test_relay_fm_mute_zeroes_tail_and_keeps_frame_cadence();
        test_mic_ptt_bypasses_relay_lookahead();
        test_hri_reconnects_after_serial_transport_error();
        test_hri_reconnect_stops_after_user_disconnect();
        test_bm_playback_continues_during_hri_reconnect();
    } catch (const std::exception& error) {
        std::cerr << "FAILED: unexpected exception: " << error.what() << '\n';
        return 1;
    } catch (...) {
        std::cerr << "FAILED: unexpected non-standard exception\n";
        return 1;
    }
    if (failures != 0) {
        std::cerr << failures << " engine test check(s) failed\n";
        return 1;
    }
    std::cout << "engine_test passed\n";
    return 0;
}
