#include "wirex/console_lifecycle.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << "\n";
        ++failures;
    }
}

bool contains_line(const std::string& text, const std::string& line)
{
    return text.find(line) != std::string::npos;
}

std::string read_all(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

void write_child_state(const std::filesystem::path& path, HWND console_window,
                       bool cancelled, bool cleanup_complete)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output << "ready=1\n"
           << "hwnd=" << std::hex << reinterpret_cast<std::uintptr_t>(console_window) << "\n"
           << "cancel=" << (cancelled ? 1 : 0) << "\n"
           << "cleanup=" << (cleanup_complete ? 1 : 0) << "\n";
    output.flush();
}

int close_event_child(const std::filesystem::path& marker_path)
{
    wirex::ConsoleHandlerScope control_scope;
    if (!control_scope.start()) return 20;

    HWND const console_window = GetConsoleWindow();
    if (console_window == nullptr) {
        write_child_state(marker_path, nullptr, false, false);
        return 77;
    }
    write_child_state(marker_path, console_window, false, false);

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (!control_scope.cancel_requested() && std::chrono::steady_clock::now() < deadline) {
        Sleep(5);
    }
    if (!control_scope.cancel_requested()) return 21;

    // 模拟主线程正在回收资源；控制处理线程只发出取消并等待该完成信号。
    Sleep(40);
    write_child_state(marker_path, console_window, true, true);
    if (!control_scope.signal_cleanup_complete()) return 22;
    if (!control_scope.unregister_now()) return 23;
    return 0;
}

std::wstring quote_argument(const std::wstring& value)
{
    return L"\"" + value + L"\"";
}

int verify_real_close_event()
{
    wchar_t executable_buffer[32768]{};
    const DWORD executable_length = GetModuleFileNameW(nullptr, executable_buffer,
        static_cast<DWORD>(std::size(executable_buffer)));
    if (executable_length == 0 || executable_length >= std::size(executable_buffer)) {
        std::cout << "SKIP: cannot resolve the test executable path for the isolated console child.\n";
        return 77;
    }
    const std::filesystem::path executable(std::wstring(executable_buffer, executable_length));
    const std::filesystem::path marker = std::filesystem::temp_directory_path() /
        (L"wirex-console-close-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
         std::to_wstring(GetTickCount64()) + L".txt");
    std::error_code ignored;
    std::filesystem::remove(marker, ignored);

    std::wstring command_line = quote_argument(executable.wstring()) + L" --close-child " +
        quote_argument(marker.wstring());
    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process{};
    if (CreateProcessW(executable.c_str(), mutable_command.data(), nullptr, nullptr, FALSE,
            CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT, nullptr, nullptr, &startup, &process) == FALSE) {
        std::cout << "SKIP: Windows could not create the hidden, isolated console child.\n";
        std::filesystem::remove(marker, ignored);
        return 77;
    }

    const auto marker_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    std::string state;
    while (std::chrono::steady_clock::now() < marker_deadline) {
        state = read_all(marker);
        if (contains_line(state, "ready=1") || WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) break;
        Sleep(10);
    }

    std::uintptr_t window_value = 0;
    const auto window_pos = state.find("hwnd=");
    if (!contains_line(state, "ready=1") || window_pos == std::string::npos) {
        (void)TerminateProcess(process.hProcess, 77);
        (void)WaitForSingleObject(process.hProcess, 1000);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        std::filesystem::remove(marker, ignored);
        std::cout << "SKIP: isolated child did not expose a console window for a close-event test.\n";
        return 77;
    }
    const auto hex_start = window_pos + 5;
    const auto hex_end = state.find_first_of("\r\n", hex_start);
    try {
        window_value = static_cast<std::uintptr_t>(std::stoull(state.substr(hex_start, hex_end - hex_start), nullptr, 16));
    } catch (...) {
        window_value = 0;
    }

    if (window_value == 0 || PostMessageW(reinterpret_cast<HWND>(window_value), WM_CLOSE, 0, 0) == FALSE) {
        (void)TerminateProcess(process.hProcess, 77);
        (void)WaitForSingleObject(process.hProcess, 1000);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        std::filesystem::remove(marker, ignored);
        std::cout << "SKIP: Windows did not accept WM_CLOSE for the isolated console window.\n";
        return 77;
    }

    const DWORD wait_result = WaitForSingleObject(process.hProcess, 5000);
    state = read_all(marker);
    if (wait_result == WAIT_FAILED) {
        (void)TerminateProcess(process.hProcess, 1);
        (void)WaitForSingleObject(process.hProcess, 1000);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        std::filesystem::remove(marker, ignored);
        std::cerr << "FAIL: waiting for the isolated child process failed.\n";
        return 1;
    }
    if (wait_result == WAIT_TIMEOUT) {
        (void)TerminateProcess(process.hProcess, 77);
        (void)WaitForSingleObject(process.hProcess, 1000);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        std::filesystem::remove(marker, ignored);
        if (contains_line(state, "cancel=1")) {
            std::cerr << "FAIL: child received close cancellation but did not exit after cleanup.\n";
            return 1;
        }
        std::cout << "SKIP: WM_CLOSE did not deliver CTRL_CLOSE_EVENT to the isolated child.\n";
        return 77;
    }

    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    std::filesystem::remove(marker, ignored);
    if (!contains_line(state, "cancel=1")) {
        std::cout << "SKIP: the isolated console closed without observable CTRL_CLOSE_EVENT delivery.\n";
        return 77;
    }
    if (!contains_line(state, "cleanup=1")) {
        std::cerr << "FAIL: child received CTRL_CLOSE_EVENT but the main thread did not record cleanup completion.\n";
        return 1;
    }
    std::cout << "PASS: isolated hidden child received CTRL_CLOSE_EVENT and completed main-thread cleanup.\n";
    return 0;
}

int run_unit_checks()
{
    {
        wirex::ConsoleLifecycle lifecycle(100);
        check(lifecycle.signal_main_cleanup_complete(), "normal completion should set the completion event");
        const auto handled = lifecycle.handle_control_event(CTRL_CLOSE_EVENT);
        check(handled == TRUE, "close control event should be consumed");
        check(lifecycle.cancel_requested(), "close control event should request cancellation");
        check(!lifecycle.close_wait_timed_out(), "already-complete cleanup should not time out");
    }

    {
        wirex::ConsoleLifecycle lifecycle(1000);
        BOOL handled = FALSE;
        std::thread callback([&] { handled = lifecycle.handle_control_event(CTRL_CLOSE_EVENT); });
        const auto cancel_deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
        while (!lifecycle.cancel_requested() && std::chrono::steady_clock::now() < cancel_deadline) Sleep(1);
        check(lifecycle.cancel_requested(), "close callback should publish cancellation before waiting");
        check(lifecycle.signal_main_cleanup_complete(), "main thread should be able to release the close callback");
        callback.join();
        check(handled == TRUE, "close callback should return TRUE after main cleanup completion");
        check(!lifecycle.close_wait_timed_out(), "completion before the deadline should not time out");
    }

    {
        auto& scope_lifecycle = wirex::ConsoleLifecycle::process();
        {
            wirex::ConsoleHandlerScope scope(scope_lifecycle);
            check(scope.start(), "scope should register the control handler");
            // 模拟函数在资源回收后提前返回，由 scope 兜底发出完成信号并注销处理器。
        }
        check(scope_lifecycle.handle_control_event(CTRL_CLOSE_EVENT) == TRUE,
            "early scope exit should leave a completed cleanup signal");
        check(!scope_lifecycle.close_wait_timed_out(), "scope cleanup fallback should prevent a close timeout");
    }

    {
        auto& active = wirex::ConsoleLifecycle::process();
        wirex::ConsoleLifecycle rejected(100);
        const bool active_registered = active.register_handler();
        check(active_registered, "first lifecycle should register as the active control handler");
        if (active_registered) {
            {
                wirex::ConsoleHandlerScope rejected_scope(rejected);
                check(!rejected_scope.start(), "a second scope should fail without replacing the active handler");
            }
            check(wirex::ConsoleLifecycle::control_handler(CTRL_C_EVENT) == TRUE,
                "failed registration must leave the existing active handler reachable");
            check(active.cancel_requested(), "existing active lifecycle should receive cancellation");
            check(!rejected.cancel_requested(), "failed lifecycle should not receive the active cancellation");
            check(active.signal_main_cleanup_complete(), "active lifecycle should release the control handler");
            check(active.unregister_handler(), "active lifecycle should unregister cleanly");
        }
    }

    {
        wirex::ConsoleLifecycle lifecycle(50);
        const auto started = std::chrono::steady_clock::now();
        const auto handled = lifecycle.handle_control_event(CTRL_CLOSE_EVENT);
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        check(handled == TRUE, "close callback should return TRUE on timeout");
        check(lifecycle.close_wait_timed_out(), "close callback should record a wait timeout");
        check(elapsed >= 5 && elapsed < 500, "short test timeout should remain bounded");
    }

    bool observed_completed_race = false;
    bool observed_timeout_race = false;
    for (unsigned int i = 0; i < 20; ++i) {
        wirex::ConsoleLifecycle lifecycle(50);
        BOOL handled = FALSE;
        std::thread callback([&] { handled = lifecycle.handle_control_event(CTRL_CLOSE_EVENT); });
        const auto cancel_deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
        while (!lifecycle.cancel_requested() && std::chrono::steady_clock::now() < cancel_deadline) Sleep(1);
        if ((i % 2U) == 0U) Sleep(1);
        else Sleep(75);
        (void)lifecycle.signal_main_cleanup_complete();
        callback.join();
        check(handled == TRUE && lifecycle.cancel_requested(), "close/complete race should always request cancellation");
        if (lifecycle.close_wait_timed_out()) observed_timeout_race = true;
        else observed_completed_race = true;
    }
    check(observed_completed_race, "race coverage should include completion before timeout");
    check(observed_timeout_race, "race coverage should include timeout before late completion");

    {
        wirex::ConsoleLifecycle lifecycle;
        const auto started = std::chrono::steady_clock::now();
        const auto handled = lifecycle.handle_control_event(CTRL_CLOSE_EVENT);
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        check(handled == TRUE, "production close wait should return TRUE at its deadline");
        check(lifecycle.close_wait_timed_out(), "production close wait should record timeout");
        check(elapsed >= 2900 && elapsed < 4800, "production wait should be bounded by the configured 3000 ms");
    }

    return failures == 0 ? 0 : 1;
}

} // 命名空间

int wmain(int argc, wchar_t** argv)
{
    if (argc == 3 && std::wstring(argv[1]) == L"--close-child") {
        return close_event_child(std::filesystem::path(argv[2]));
    }

    const int unit_result = run_unit_checks();
    if (unit_result != 0) return unit_result;
    return verify_real_close_event();
}
