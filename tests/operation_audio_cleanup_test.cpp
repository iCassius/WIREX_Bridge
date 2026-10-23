#include "wirex/operation_audio_cleanup.hpp"

#include <iostream>
#include <string_view>

namespace {

int failures = 0;

void check(bool condition, std::string_view message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void test_close_failure_is_sticky_and_blocks_reopen()
{
    wirex::operation_audio_cleanup::State state;
    check(state.status(false) == "not_started", "尚未执行下行时应报告not_started");
    state.begin_operation();
    bool output_open = true;
    check(state.status(output_open) == "pending", "打开的radio WaveOut应显示清理等待中");

    // 注入WaveClose失败，验证native使用的关闭包装保留失败并清除打开标记。
    int close_calls = 0;
    const bool close_result = state.close_if_open(output_open, [&]() {
        ++close_calls;
        return false;
    });
    check(!close_result && !output_open && close_calls == 1,
        "WaveClose失败时应只尝试一次并清除本机打开标记");
    check(state.close_failed() && !state.reopen_allowed(), "WaveClose失败后必须保留失败并禁止重开");
    check(state.status(output_open) == "failed", "关闭标记清零不能把失败改成成功");

    const bool repeated_result = state.close_if_open(output_open, [&]() {
        ++close_calls;
        return true;
    });
    check(!repeated_result && close_calls == 1,
        "关闭失败后不能再次关闭或重新打开同一Wave对象");
    check(state.status(output_open) == "failed", "后续成功结果不能抹掉本轮已知失败");
}

void test_next_operation_starts_with_independent_cleanup_state()
{
    wirex::operation_audio_cleanup::State state;
    state.begin_operation();
    state.record_close_result(false);
    state.begin_operation();
    check(state.reopen_allowed() && state.status(false) == "succeeded",
        "仅在显式开始下一轮时重置该轮清理状态");
}

} // namespace

int main()
{
    test_close_failure_is_sticky_and_blocks_reopen();
    test_next_operation_starts_with_independent_cleanup_state();
    if (failures != 0) {
        std::cerr << failures << " operation audio cleanup test(s) failed\n";
        return 1;
    }
    std::cout << "operation audio cleanup tests passed\n";
    return 0;
}
