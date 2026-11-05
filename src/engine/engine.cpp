// wirex::engine::Engine：一个专用引擎线程运行原 run_bm_bridge 主循环（engine_loop.cpp）。
// 线程模型：
// - 调用方线程只做入队/出队与 future 等待，所有协议与设备状态只在引擎线程访问；
// - Shared::mutex 保护命令队列、事件队列、快照指针与停止请求；锁内不调用用户回调；
// - 引擎线程入口捕获全部异常，确保 start/stop/命令的 promise 都会兑现。

#include "engine_internal.hpp"

#include <chrono>
#include <exception>
#include <system_error>
#include <thread>
#include <utility>

namespace wirex::engine {
namespace detail {

bool wipe_secret(std::string& secret) noexcept
{
    const auto size = secret.size();
    auto* bytes = reinterpret_cast<volatile unsigned char*>(secret.data());
    for (std::size_t index = 0U; index < size; ++index) bytes[index] = 0U;
    bool zeroed = true;
    for (std::size_t index = 0U; index < size; ++index) zeroed = zeroed && bytes[index] == 0U;
    secret.clear();
    return zeroed;
}

bool wipe_command_secret(Command& command) noexcept
{
    return !command.bm_target || wipe_secret(command.bm_target->profile.password);
}

bool resolve_rejected_command(Command& command, CommandResult result) noexcept
{
    const bool wiped = wipe_command_secret(command);
    try { command.promise.set_value(std::move(result)); } catch (...) {}
    return wiped;
}

void EventQueue::push(Event event)
{
    last_at_ms_ = event.at_ms;
    if (events_.size() >= event_queue_capacity) {
        events_.pop_front();
        ++dropped_pending_;
        ++dropped_total_;
    }
    events_.push_back(std::move(event));
}

std::vector<Event> EventQueue::drain(std::size_t max)
{
    std::vector<Event> output;
    if (max == 0U) return output;
    output.reserve(std::min(max, events_.size() + 1U));
    if (dropped_pending_ != 0U) {
        Event warning{};
        warning.kind = EventKind::warning;
        warning.at_ms = last_at_ms_;
        warning.text = "事件队列溢出，已丢弃最旧的 " + std::to_string(dropped_pending_) + " 条事件";
        output.push_back(std::move(warning));
        dropped_pending_ = 0U;
    }
    while (output.size() < max && !events_.empty()) {
        output.push_back(std::move(events_.front()));
        events_.pop_front();
    }
    return output;
}

void Shared::publish(Snapshot next)
{
    {
        std::lock_guard<std::mutex> lock(mutex);
        next.seq = ++snapshot_seq;
        snapshot = std::make_shared<const Snapshot>(std::move(next));
    }
    notify_wakeup();
}

void Shared::push_event(Event event)
{
    {
        std::lock_guard<std::mutex> lock(mutex);
        events.push(std::move(event));
    }
    notify_wakeup();
}

void Shared::resolve_start(CommandResult result)
{
    std::optional<std::promise<CommandResult>> promise;
    {
        std::lock_guard<std::mutex> lock(mutex);
        promise.swap(start_promise);
    }
    if (promise) {
        try { promise->set_value(std::move(result)); } catch (...) {}
    }
}

std::deque<Command> Shared::take_commands()
{
    std::deque<Command> taken;
    std::lock_guard<std::mutex> lock(mutex);
    taken.swap(commands);
    return taken;
}

StopRequest Shared::stop_state()
{
    std::lock_guard<std::mutex> lock(mutex);
    return stop;
}

void Shared::notify_wakeup() noexcept
{
    std::function<void()> callback;
    try {
        std::lock_guard<std::mutex> lock(mutex);
        callback = wakeup;
    } catch (...) {
        return;
    }
    if (!callback) return;
    try { callback(); } catch (...) {}
}

} // namespace detail

namespace {

using detail::Command;
using detail::CommandKind;
using detail::Shared;

constexpr auto destructor_stop_wait = std::chrono::seconds{5};

std::future<CommandResult> ready_future(CommandResult result)
{
    std::promise<CommandResult> promise;
    auto future = promise.get_future();
    promise.set_value(std::move(result));
    return future;
}

Phase final_phase(const CommandResult& result) noexcept
{
    return result.status == CommandStatus::accepted ? Phase::stopped : Phase::failed;
}

// 引擎线程入口：运行主循环并兑现全部挂起的 promise。noexcept 保证异常不会越过线程边界。
void engine_thread_main(std::shared_ptr<Shared> shared, StartConfig config) noexcept
{
    CommandResult result{CommandStatus::failed, 0U, "runtime_exception"};
    try {
        result = detail::run_loop(*shared, std::move(config));
    } catch (const std::bad_alloc&) {
        result = CommandResult{CommandStatus::failed, 0U, "resource_failure"};
    } catch (...) {
        result = CommandResult{CommandStatus::failed, 0U, "runtime_exception"};
    }

    // 启动阶段失败时 start() 仍在等待：把失败原因交给它。
    shared->resolve_start(result);

    std::vector<std::promise<CommandResult>> stop_promises;
    std::deque<Command> leftovers;
    try {
        Snapshot last{};
        {
            std::lock_guard<std::mutex> lock(shared->mutex);
            shared->accepting = false;
            if (shared->snapshot) last = *shared->snapshot;
            stop_promises.swap(shared->stop_promises);
            leftovers.swap(shared->commands);
        }
        last.phase = final_phase(result);
        last.failure_reason = result.status == CommandStatus::accepted ? std::string{} : result.detail;
        last.tx_active = false;
        last.active_rx_call.reset();
        last.bm_link = BmLink::disabled;
        shared->publish(std::move(last));
        if (result.status != CommandStatus::accepted) {
            Event fatal{};
            fatal.kind = EventKind::fatal;
            fatal.text = result.detail;
            shared->push_event(std::move(fatal));
        }
    } catch (...) {
        std::lock_guard<std::mutex> lock(shared->mutex);
        shared->accepting = false;
        stop_promises.swap(shared->stop_promises);
        leftovers.swap(shared->commands);
    }
    for (auto& command : leftovers) {
        (void)detail::resolve_rejected_command(
            command, CommandResult{CommandStatus::not_ready, 0U, "engine_stopped"});
    }
    for (auto& promise : stop_promises) {
        try { promise.set_value(result); } catch (...) {}
    }
    {
        std::lock_guard<std::mutex> lock(shared->mutex);
        shared->thread_done = true;
    }
    shared->done_cv.notify_all();
    shared->notify_wakeup();
}

} // namespace

struct Engine::Impl {
    explicit Impl(std::shared_ptr<Devices> devices) : shared(std::make_shared<Shared>(std::move(devices))) {}
    std::shared_ptr<Shared> shared;
    std::thread thread{};

    // 有界等待线程结束；结束则 join。超时返回 false，线程保持可 join，由调用方决定后续。
    bool join_for(std::chrono::milliseconds timeout)
    {
        bool done = false;
        {
            std::unique_lock<std::mutex> lock(shared->mutex);
            done = shared->done_cv.wait_for(lock, timeout, [this]() { return shared->thread_done; });
        }
        if (!done) return false;
        if (thread.joinable()) {
            try { thread.join(); } catch (const std::system_error&) { return false; }
        }
        return true;
    }

    std::future<CommandResult> enqueue(Command command)
    {
        auto future = command.promise.get_future();
        {
            std::lock_guard<std::mutex> lock(shared->mutex);
            // 收尾期间仍接受命令（与原 control-v2 一致）；线程结束后统一拒绝。
            if (!shared->accepting) {
                (void)detail::resolve_rejected_command(
                    command, CommandResult{CommandStatus::not_ready, 0U, "engine_not_running"});
                return future;
            }
            shared->commands.push_back(std::move(command));
        }
        shared->loop_cv.notify_all();
        return future;
    }
};

Engine::Engine() : impl_(std::make_unique<Impl>(make_windows_devices())) {}

Engine::Engine(std::shared_ptr<Devices> devices)
    : impl_(std::make_unique<Impl>(devices ? std::move(devices) : make_windows_devices()))
{
}

Engine::~Engine()
{
    if (!impl_) return;
    try {
        (void)stop();
        if (!impl_->join_for(std::chrono::duration_cast<std::chrono::milliseconds>(destructor_stop_wait))) {
            // 超时：请求立即收尾后再给 1 s；仍未结束则分离，避免析构函数无限阻塞。
            // Shared 由线程共同持有，分离后不会悬空。
            force_stop_now("engine_destructor_stop_timeout");
            (void)impl_->join_for(std::chrono::milliseconds{1000});
        }
    } catch (...) {
    }
    if (impl_->thread.joinable()) {
        try { impl_->thread.detach(); } catch (...) {}
    }
    try {
        std::lock_guard<std::mutex> lock(impl_->shared->mutex);
        impl_->shared->wakeup = nullptr;
    } catch (...) {}
}

std::future<CommandResult> Engine::start(StartConfig config)
{
    auto& shared = impl_->shared;
    std::promise<CommandResult> promise;
    auto future = promise.get_future();
    {
        std::lock_guard<std::mutex> lock(shared->mutex);
        if (!shared->thread_done) {
            promise.set_value(CommandResult{CommandStatus::busy, 0U, "engine_already_running"});
            return future;
        }
    }
    // 上一轮已结束的线程在此回收（不阻塞：thread_done 已为真）。
    if (impl_->thread.joinable()) {
        try { impl_->thread.join(); } catch (const std::system_error&) {}
    }
    {
        std::lock_guard<std::mutex> lock(shared->mutex);
        shared->thread_done = false;
        shared->accepting = true;
        shared->stop = detail::StopRequest{};
        shared->start_promise = std::move(promise);
        shared->commands.clear();
        Snapshot starting{};
        starting.seq = ++shared->snapshot_seq;
        starting.phase = Phase::starting;
        starting.radio_playback_gain_milli = config.radio_playback_gain_milli;
        starting.mic_transmit_gain_milli = config.mic_transmit_gain_milli;
        shared->snapshot = std::make_shared<const Snapshot>(std::move(starting));
    }
    try {
        impl_->thread = std::thread(engine_thread_main, shared, std::move(config));
    } catch (...) {
        // 线程创建失败（std::system_error / bad_alloc）：回滚状态并兑现 start。
        CommandResult failure{CommandStatus::failed, 0U, "engine_thread_start_failed"};
        {
            std::lock_guard<std::mutex> lock(shared->mutex);
            shared->thread_done = true;
            shared->accepting = false;
        }
        shared->resolve_start(failure);
        Snapshot failed_snapshot{};
        failed_snapshot.phase = Phase::failed;
        failed_snapshot.failure_reason = failure.detail;
        shared->publish(std::move(failed_snapshot));
    }
    return future;
}

std::future<CommandResult> Engine::stop()
{
    return stop_with_reason({});
}

std::future<CommandResult> Engine::stop_with_reason(std::string failure_reason)
{
    auto& shared = impl_->shared;
    std::promise<CommandResult> promise;
    auto future = promise.get_future();
    {
        std::lock_guard<std::mutex> lock(shared->mutex);
        if (shared->thread_done) {
            promise.set_value(CommandResult{CommandStatus::idempotent, 0U, "engine_not_running"});
            return future;
        }
        if (!shared->stop.requested) {
            shared->stop.requested = true;
            shared->stop.failure_reason = std::move(failure_reason);
        }
        shared->stop_promises.push_back(std::move(promise));
    }
    shared->loop_cv.notify_all();
    return future;
}

void Engine::force_stop_now(std::string failure_reason)
{
    auto& shared = impl_->shared;
    {
        std::lock_guard<std::mutex> lock(shared->mutex);
        if (shared->thread_done) return;
        shared->stop.requested = true;
        shared->stop.immediate = true;
        if (shared->stop.failure_reason.empty()) shared->stop.failure_reason = std::move(failure_reason);
    }
    shared->loop_cv.notify_all();
}

bool Engine::wait_stopped(std::chrono::milliseconds timeout)
{
    return impl_->join_for(timeout);
}

std::future<CommandResult> Engine::set_bm_connection(bool enabled, std::uint64_t requested_revision)
{
    Command command{};
    command.kind = CommandKind::set_bm_connection;
    command.flag = enabled;
    command.revision = requested_revision;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::configure_bm(BmTarget config)
{
    Command command{};
    command.kind = CommandKind::configure_bm;
    command.bm_target.emplace(std::move(config));
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::connect_radio(RadioStartConfig config)
{
    Command command{};
    command.kind = CommandKind::connect_radio;
    command.radio_config.emplace(std::move(config));
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::disconnect_radio()
{
    Command command{};
    command.kind = CommandKind::disconnect_radio;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::replace_rx_policy(std::uint64_t expected_revision,
                                                     talkgroup_routing::RxPolicy policy)
{
    Command command{};
    command.kind = CommandKind::replace_rx_policy;
    command.revision = expected_revision;
    command.rx_policy = std::move(policy);
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::replace_tx_policy(std::uint64_t expected_revision,
                                                     talkgroup_routing::TxTarget target,
                                                     bool transmit_enabled)
{
    Command command{};
    command.kind = CommandKind::replace_tx_policy;
    command.revision = expected_revision;
    command.tx_target = target;
    command.flag = transmit_enabled;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::quick_call_join(talkgroup_routing::GroupRoute route)
{
    Command command{};
    command.kind = CommandKind::quick_call_join;
    command.group = route;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::set_audio_gains(std::uint32_t radio_playback_gain_milli,
                                                   std::uint32_t mic_transmit_gain_milli)
{
    Command command{};
    command.kind = CommandKind::set_audio_gains;
    command.first = radio_playback_gain_milli;
    command.second = mic_transmit_gain_milli;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::set_audio_endpoints(AudioEndpoints audio)
{
    Command command;
    command.kind = CommandKind::set_audio_endpoints;
    command.audio_endpoints = std::move(audio);
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::upsert_radio_identity(std::uint32_t source_id, std::uint64_t revision,
                                                         std::optional<std::string> callsign)
{
    Command command{};
    command.kind = CommandKind::upsert_radio_identity;
    command.first = source_id;
    command.revision = revision;
    command.callsign = std::move(callsign);
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::manual_ptt_toggle()
{
    Command command{};
    command.kind = CommandKind::manual_ptt_toggle;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::relay_fm_start()
{
    Command command{};
    command.kind = CommandKind::relay_fm_start;
    return impl_->enqueue(std::move(command));
}

std::future<CommandResult> Engine::relay_fm_stop()
{
    Command command{};
    command.kind = CommandKind::relay_fm_stop;
    return impl_->enqueue(std::move(command));
}

std::shared_ptr<const Snapshot> Engine::snapshot() const
{
    std::lock_guard<std::mutex> lock(impl_->shared->mutex);
    return impl_->shared->snapshot;
}

std::vector<Event> Engine::drain_events(std::size_t max)
{
    std::lock_guard<std::mutex> lock(impl_->shared->mutex);
    return impl_->shared->events.drain(max);
}

void Engine::set_wakeup(std::function<void()> wakeup)
{
    std::lock_guard<std::mutex> lock(impl_->shared->mutex);
    impl_->shared->wakeup = std::move(wakeup);
}

} // namespace wirex::engine
