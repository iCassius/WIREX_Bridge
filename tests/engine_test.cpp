// Engine 离线测试：注入假 Devices（不打开串口、WinMM 或 UDP），覆盖命令队列与 future 结果、
// 快照发布、事件队列溢出、有界 stop、启动失败与诊断钩子。

#include "wirex/engine.hpp"
#include "wirex/engine_devices.hpp"
#include "wirex/engine_diagnostics.hpp"

#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"
#include "wirex/hri_session.hpp"

#include "../src/engine/engine_internal.hpp"

#include <atomic>
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
    std::atomic<int> serial_opened{0};
    std::atomic<int> serial_closed{0};
    std::atomic<int> output_opened{0};
    std::atomic<int> output_closed{0};
    std::atomic<bool> output_drained{true};
    std::atomic<int> input_closed{0};
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
    bool open() noexcept override { open_ = true; return true; }
    bool is_open() const noexcept override { return open_; }
    wirex::engine::CaptureStatus take_captured(const Sink&, bool, std::uint32_t) noexcept override
    {
        return wirex::engine::CaptureStatus::ok;
    }
    bool stop_capture() noexcept override { return true; }
    bool close() noexcept override
    {
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
        if (!options_.serial_ok) {
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
    const auto stop = get_within(engine.stop(), 1s, "stop before start");
    check(stop.status == CommandStatus::idempotent, "stop before start is idempotent");
    check(engine.snapshot()->phase == wirex::engine::Phase::stopped, "initial snapshot phase is stopped");
    check(engine.drain_events().empty(), "no events before start");
}

void test_start_failures()
{
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{false, true, true}));
        const auto result = get_within(engine.start(base_config()), 5s, "start with invalid template");
        check(result.status == CommandStatus::invalid && result.detail == "y_template_invalid",
              "invalid HRI template is reported through the start future");
        check(engine.wait_stopped(2s), "engine thread ends after template failure");
        check(engine.snapshot()->phase == wirex::engine::Phase::failed &&
              engine.snapshot()->failure_reason == "y_template_invalid", "failed snapshot keeps the reason");
        check(log->serial_opened == 0, "serial is not opened when the template is invalid");
    }
    {
        auto log = std::make_shared<DeviceLog>();
        wirex::engine::Engine engine(std::make_shared<FakeDevices>(log, FakeOptions{true, false, true}));
        std::vector<std::string> statuses;
        auto config = base_config();
        config.diagnostics.status = [&statuses](const wirex::engine::StatusRecord& record) {
            statuses.emplace_back(record.event);
            return true;
        };
        const auto result = get_within(engine.start(std::move(config)), 5s, "start with serial failure");
        check(result.status == CommandStatus::failed && result.detail == "serial_open_or_configure_failed",
              "serial open failure is reported with the R127 failure reason");
        check(engine.wait_stopped(2s), "engine thread ends after serial failure");
        check(statuses.size() == 1U && statuses[0] == "serial_open_or_configure_failed",
              "startup failure writes one status record named after the reason");
        bool fatal_seen = false;
        for (const auto& event : engine.drain_events()) {
            fatal_seen = fatal_seen || event.kind == wirex::engine::EventKind::fatal;
        }
        check(fatal_seen, "startup failure emits a fatal event");
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
        check(engine.snapshot()->phase == wirex::engine::Phase::starting, "phase is starting until Y/0");
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
    check(get_within(engine.start(base_config()), 5s, "start for bm").status == CommandStatus::accepted, "start for bm");
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
    // 与 R127 相同：本次运行曾请求 BM 但从未 ready，收尾记为 bm_session_never_ready。
    const auto stopped = get_within(engine.stop(), 5s, "stop after bm request");
    check(stopped.status == CommandStatus::failed && stopped.detail == "bm_session_never_ready",
          "a run that requested BM but never reached ready stops with bm_session_never_ready");
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
