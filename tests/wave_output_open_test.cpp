#include "wirex/wave_output_open.hpp"

#include <iostream>
#include <string_view>

namespace {

int failures = 0;

void check(bool condition, std::string_view message)
{
    if (condition) return;
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
}

void test_prepare_failure_and_close_failure_keep_handle_unusable()
{
    wirex::wave_output_open::State state;
    bool device_open = true;
    int prepare_calls = 0;
    int close_calls = 0;
    const bool prepared = wirex::wave_output_open::prepare_all_or_close(4,
        [&](std::size_t index) {
            ++prepare_calls;
            return index == 0;
        }, [&]() {
            ++close_calls;
            return false;
        }, state);

    check(!prepared && prepare_calls == 2, "第二个缓冲准备失败后应立即进入关闭收尾");
    check(close_calls == 1 && device_open, "注入关闭失败后应保留仍打开的WaveOut句柄状态");
    check(state.close_failed() && !state.reopen_allowed(), "关闭失败后必须禁止重开同一WaveOut对象");
    const bool reopened = state.reopen_allowed() && wirex::wave_output_open::prepare_all_or_close(4,
        [&](std::size_t) { ++prepare_calls; return true; }, [&]() { return true; }, state);
    check(!reopened,
        "sticky关闭失败后不能再次尝试准备缓冲");
}

void test_prepare_failure_with_successful_close_allows_later_open()
{
    wirex::wave_output_open::State state;
    bool device_open = true;
    const bool prepared = wirex::wave_output_open::prepare_all_or_close(3,
        [](std::size_t index) { return index == 0; }, [&]() {
            device_open = false;
            return true;
        }, state);
    check(!prepared && !device_open, "准备失败时成功关闭应释放设备句柄");
    check(!state.close_failed() && state.reopen_allowed(), "成功清理后可以由后续操作重新打开");
}

} // namespace

int main()
{
    test_prepare_failure_and_close_failure_keep_handle_unusable();
    test_prepare_failure_with_successful_close_allows_later_open();
    if (failures != 0) return 1;
    std::cout << "wave output open cleanup tests passed\n";
    return 0;
}
