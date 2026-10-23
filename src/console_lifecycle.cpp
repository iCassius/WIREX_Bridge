#include "wirex/console_lifecycle.hpp"

namespace wirex {

std::atomic<ConsoleLifecycle*> ConsoleLifecycle::active_{nullptr};

ConsoleLifecycle::ConsoleLifecycle(DWORD close_wait_ms, bool process_lifetime) noexcept
    : cleanup_complete_event_(CreateEventW(nullptr, TRUE, FALSE, nullptr)),
      close_wait_ms_(close_wait_ms),
      process_lifetime_(process_lifetime)
{
}

ConsoleLifecycle::~ConsoleLifecycle()
{
    if (handler_registered_) (void)unregister_handler();
    if (!process_lifetime_ && cleanup_complete_event_ != nullptr) {
        CloseHandle(cleanup_complete_event_);
    }
}

bool ConsoleLifecycle::register_handler() noexcept
{
    if (cleanup_complete_event_ == nullptr || handler_registered_) return false;
    cancel_requested_.store(false, std::memory_order_relaxed);
    close_wait_timed_out_.store(false, std::memory_order_relaxed);
    if (ResetEvent(cleanup_complete_event_) == FALSE) return false;

    ConsoleLifecycle* expected = nullptr;
    if (!active_.compare_exchange_strong(expected, this, std::memory_order_acq_rel)) return false;
    if (SetConsoleCtrlHandler(control_handler, TRUE) == FALSE) {
        expected = this;
        (void)active_.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
        return false;
    }
    handler_registered_ = true;
    return true;
}

bool ConsoleLifecycle::unregister_handler() noexcept
{
    if (!handler_registered_) return true;
    if (SetConsoleCtrlHandler(control_handler, FALSE) == FALSE) return false;
    handler_registered_ = false;
    ConsoleLifecycle* expected = this;
    (void)active_.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
    return true;
}

bool ConsoleLifecycle::signal_main_cleanup_complete() noexcept
{
    return cleanup_complete_event_ != nullptr && SetEvent(cleanup_complete_event_) != FALSE;
}

bool ConsoleLifecycle::cancel_requested() const noexcept
{
    return cancel_requested_.load(std::memory_order_acquire);
}

bool ConsoleLifecycle::close_wait_timed_out() const noexcept
{
    return close_wait_timed_out_.load(std::memory_order_acquire);
}

BOOL ConsoleLifecycle::handle_control_event(DWORD control) noexcept
{
    if (control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT) {
        cancel_requested_.store(true, std::memory_order_release);
        return TRUE;
    }
    if (control != CTRL_CLOSE_EVENT) return FALSE;

    cancel_requested_.store(true, std::memory_order_release);
    const DWORD result = cleanup_complete_event_ == nullptr ? WAIT_FAILED :
        WaitForSingleObject(cleanup_complete_event_, close_wait_ms_);
    if (result != WAIT_OBJECT_0) {
        close_wait_timed_out_.store(true, std::memory_order_release);
    }
    // Windows 在此关闭事件处理器返回 TRUE 后会终止进程。
    return TRUE;
}

ConsoleLifecycle& ConsoleLifecycle::process() noexcept
{
    // 进程退出时由操作系统回收事件句柄；对象保持存活，避免回调等待时句柄被关闭。
    static ConsoleLifecycle* const lifecycle = new ConsoleLifecycle(production_close_wait_ms, true);
    return *lifecycle;
}

BOOL WINAPI ConsoleLifecycle::control_handler(DWORD control) noexcept
{
    ConsoleLifecycle* const lifecycle = active_.load(std::memory_order_acquire);
    return lifecycle == nullptr ? FALSE : lifecycle->handle_control_event(control);
}

ConsoleHandlerScope::ConsoleHandlerScope(ConsoleLifecycle& lifecycle) noexcept
    : lifecycle_(lifecycle)
{
}

ConsoleHandlerScope::~ConsoleHandlerScope()
{
    if (!started_) return;
    if (!cleanup_complete_) (void)signal_cleanup_complete();
    (void)lifecycle_.unregister_handler();
}

bool ConsoleHandlerScope::start() noexcept
{
    if (started_) return false;
    started_ = lifecycle_.register_handler();
    return started_;
}

bool ConsoleHandlerScope::signal_cleanup_complete() noexcept
{
    if (!started_) return false;
    if (!lifecycle_.signal_main_cleanup_complete()) return false;
    cleanup_complete_ = true;
    return true;
}

bool ConsoleHandlerScope::unregister_now() noexcept
{
    if (!started_) return true;
    if (!lifecycle_.unregister_handler()) return false;
    started_ = false;
    return true;
}

bool ConsoleHandlerScope::cancel_requested() const noexcept
{
    return lifecycle_.cancel_requested();
}

bool ConsoleHandlerScope::close_wait_timed_out() const noexcept
{
    return lifecycle_.close_wait_timed_out();
}

} // 命名空间 wirex
