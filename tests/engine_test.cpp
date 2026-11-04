// Engine 离线测试：注入假 Devices（不打开串口、WinMM 或 UDP），覆盖命令队列与 future 结果、
// 快照发布、事件队列溢出、有界 stop、启动失败与诊断钩子。

#include "wirex/engine.hpp"
#include "wirex/engine_devices.hpp"
#include "wirex/engine_diagnostics.hpp"

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
    std::atomic<bool> serial_blocked{false};
    std::atomic<int> serial_opened{0};
    std::atomic<int> serial_closed{0};
    std::atomic<int> output_opened{0};
    std::atomic<int> output_closed{0};
    std::atomic<bool> output_close_fails_while_open{false};
    std::atomic<bool> output_drained{true};
    std::atomic<int> input_opened{0};
    std::atomic<int> input_closed{0};
    std::atomic<bool> input_close_fails_while_open{false};
    std::atomic<int> version_queries{0};
    std::atomic<int> y_records{0};
    std::atomic<int> t_records{0};
};

// 模拟 FTX-1 HRI：收到 V 查询回 48 字节 FTX-1 版本记录，收到 Y 回 Y/0 确认。
class FakeSerial final : public wirex::engine::SerialPort {
public:
    FakeSerial(std::shared_ptr<DeviceLog> log, bool respond) : log_(std::move(log)), respond_(respond) {}

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
                    if (respond_) queue_record('V', version_payload());
                } else if (type == 'Y') {
                    ++log_->y_records;
                    if (respond_) queue_record('Y', {});
                } else if (type == 'T') {
                    ++log_->t_records;
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
        std::lock_guard<std::mutex> lock(mutex_);
        received = std::min(capacity, inbound_.size());
        std::copy(inbound_.begin(), inbound_.begin() + static_cast<std::ptrdiff_t>(received), buffer);
        inbound_.erase(inbound_.begin(), inbound_.begin() + static_cast<std::ptrdiff_t>(received));
        return wirex::engine::SerialReadStatus::ok;
    }

    bool close() noexcept override
    {
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

    void queue_record(std::uint8_t type, std::vector<std::uint8_t> payload)
    {
        const auto encoded = wirex::direct_frame::encode({type, std::move(payload)});
        if (encoded) inbound_.insert(inbound_.end(), encoded.bytes.begin(), encoded.bytes.end());
    }

    std::shared_ptr<DeviceLog> log_;
    bool respond_;
    wirex::direct_stream::Parser parser_{};
    std::mutex mutex_{};
    std::vector<std::uint8_t> inbound_{};
};

class FakeInput final : public wirex::engine::AudioInput {
public:
    explicit FakeInput(std::shared_ptr<DeviceLog> log) : log_(std::move(log)) {}
    bool open() noexcept override { ++log_->input_opened; open_ = true; return true; }
    bool is_open() const noexcept override { return open_; }
    wirex::engine::CaptureStatus take_captured(const Sink&, bool, std::uint32_t) noexcept override
    {
        return wirex::engine::CaptureStatus::ok;
    }
    bool stop_capture() noexcept override { return true; }
    bool close() noexcept override
    {
        if (open_ && log_->input_close_fails_while_open.load()) return false;
        if (open_) ++log_->input_closed;
        open_ = false;
        return true;
    }

private:
    std::shared_ptr<DeviceLog> log_;
    bool open_{};
};

class FakeOutput final : public wirex::engine::AudioOutput {
public:
    FakeOutput(std::shared_ptr<DeviceLog> log, bool can_open, bool close_succeeds)
        : log_(std::move(log)), can_open_(can_open), close_succeeds_(close_succeeds) {}
    bool open() noexcept override { ++log_->output_opened; open_ = can_open_; return open_; }
    bool is_open() const noexcept override { return open_; }
    bool completion_overflowed() noexcept override { return false; }
    bool take_completed(std::uint64_t&, std::size_t&) noexcept override { return false; }
    bool has_capacity() noexcept override { return open_; }
    bool submit(const std::int16_t*, std::size_t, std::uint64_t) noexcept override { return open_; }
    bool all_drained() noexcept override { return log_->output_drained.load(); }
    bool close() noexcept override
    {
        if (open_ && log_->output_close_fails_while_open.load()) return false;
        if (open_) ++log_->output_closed;
        open_ = false;
        return close_succeeds_;
    }

private:
    std::shared_ptr<DeviceLog> log_;
    bool can_open_{};
    bool close_succeeds_{true};
    bool open_{};
};

struct FakeOptions {
    bool template_ok{true};
    bool serial_ok{true};
    bool hri_responds{true};
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
        ++log_->serial_opened;
        return std::make_unique<FakeSerial>(log_, options_.hri_responds);
    }

    std::unique_ptr<wirex::engine::AudioInput> make_audio_input(const wirex::engine::AudioEndpoints&) override
    {
        return std::make_unique<FakeInput>(log_);
    }

    std::unique_ptr<wirex::engine::AudioOutput> make_audio_output(const wirex::engine::AudioEndpoints& endpoints) override
    {
        return std::make_unique<FakeOutput>(log_, endpoints.expected_wave_out_endpoint_id != L"bad-output",
            endpoints.expected_wave_out_endpoint_id != L"old-close-false");
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
    void reject_auth(bool value) noexcept { reject_auth_ = value; }

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
    std::thread worker_{};
};

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
    check(!engine.snapshot()->serial_open && !engine.snapshot()->wave_out_open &&
          engine.snapshot()->bm_link == wirex::engine::BmLink::connected &&
          engine.snapshot()->bm_state == wirex::bm::State::ready &&
          engine.snapshot()->phase == wirex::engine::Phase::running,
          "radio stop closes HRI/audio but preserves BM UDP, ready state, and Engine runtime");
    check(log->serial_opened == 1 && log->serial_closed == 1 &&
          log->output_opened == 1 && log->output_closed == 1,
          "fake radio resources are opened and closed exactly once while BM stays connected");

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
              return !snapshot.serial_open && !snapshot.wave_out_open && snapshot.radio_error.empty() &&
                  snapshot.phase == wirex::engine::Phase::running;
          }), "snapshot clears the endpoint/error only after the retained handle actually closes");
    check(log->output_closed == 1, "successful recovery closes the retained WaveOut exactly once");

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
    wirex::engine::RadioStartConfig retry{};
    retry.hri_port = L"COM99";
    retry.hri_body_file = "C:/fake/device-y.bin";
    retry.audio.expected_wave_in_endpoint_id = L"fake-input-2";
    retry.audio.expected_wave_out_endpoint_id = L"fake-output-2";
    const auto blocked = get_within(engine.connect_radio(std::move(retry)), 2s,
                                    "block reattach while the old WaveIn remains open");
    check(blocked.status == CommandStatus::busy && blocked.detail == "radio_cleanup_required" &&
          log->serial_opened == 1,
          std::string("WaveIn cleanup failure prevents a second COM/audio open; got ") + blocked.detail +
              "/serial_opens=" + std::to_string(log->serial_opened));

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
}

} // namespace

int main()
{
    try {
        test_event_queue_overflow();
        test_embedded_hri_template();
        test_commands_before_start();
        test_start_failures();
        test_running_engine();
        test_stop_with_reason_and_status_failure();
        test_bm_connection_semantics();
        test_invalid_initial_bm_profile_does_not_fail_runtime_stop();
        test_bm_auth_rejection_does_not_fail_runtime_stop();
        test_radio_bm_independent_lifecycle_and_master_rejection();
        test_rejected_bm_commands_wipe_password_before_completion();
        test_failed_bm_reconfigure_blocks_old_profile_enable();
        test_radio_detach_close_failure_and_recovery();
        test_wavein_detach_close_failure_and_recovery();
        test_destructor_stops_running_engine();
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
