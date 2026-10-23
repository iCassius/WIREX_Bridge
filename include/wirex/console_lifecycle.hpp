#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <atomic>

namespace wirex {

class ConsoleLifecycle final {
public:
    static constexpr DWORD production_close_wait_ms = 3000;

    explicit ConsoleLifecycle(DWORD close_wait_ms = production_close_wait_ms,
                              bool process_lifetime = false) noexcept;
    ~ConsoleLifecycle();

    ConsoleLifecycle(const ConsoleLifecycle&) = delete;
    ConsoleLifecycle& operator=(const ConsoleLifecycle&) = delete;

    bool register_handler() noexcept;
    bool unregister_handler() noexcept;
    bool signal_main_cleanup_complete() noexcept;
    bool cancel_requested() const noexcept;
    bool close_wait_timed_out() const noexcept;

    // 无设备测试直接调用同一段控制事件处理逻辑。
    BOOL handle_control_event(DWORD control) noexcept;

    static ConsoleLifecycle& process() noexcept;
    static BOOL WINAPI control_handler(DWORD control) noexcept;

private:
    HANDLE cleanup_complete_event_{};
    DWORD close_wait_ms_{};
    bool process_lifetime_{};
    bool handler_registered_{};
    std::atomic_bool cancel_requested_{false};
    std::atomic_bool close_wait_timed_out_{false};

    static std::atomic<ConsoleLifecycle*> active_;
};

class ConsoleHandlerScope final {
public:
    explicit ConsoleHandlerScope(ConsoleLifecycle& lifecycle = ConsoleLifecycle::process()) noexcept;
    ~ConsoleHandlerScope();

    ConsoleHandlerScope(const ConsoleHandlerScope&) = delete;
    ConsoleHandlerScope& operator=(const ConsoleHandlerScope&) = delete;

    bool start() noexcept;
    bool signal_cleanup_complete() noexcept;
    bool unregister_now() noexcept;
    bool cancel_requested() const noexcept;
    bool close_wait_timed_out() const noexcept;

private:
    ConsoleLifecycle& lifecycle_;
    bool started_{};
    bool cleanup_complete_{};
};

} // 命名空间 wirex
