#pragma once

#include <cstddef>

namespace wirex::wave_output_open {

// 保存单个 WaveOut 对象的关闭失败，避免同一对象再次打开。
class State {
public:
    void record_close_result(bool succeeded) noexcept
    {
        if (!succeeded) close_failed_ = true;
    }

    [[nodiscard]] bool reopen_allowed() const noexcept { return !close_failed_; }
    [[nodiscard]] bool close_failed() const noexcept { return close_failed_; }

private:
    bool close_failed_{false};
};

// 准备任一PCM缓冲失败时立即关闭设备，并保留关闭失败状态。
template <typename Prepare, typename Close>
[[nodiscard]] bool prepare_all_or_close(std::size_t count, Prepare&& prepare,
                                        Close&& close, State& state)
{
    for (std::size_t index = 0; index < count; ++index) {
        if (prepare(index)) continue;
        state.record_close_result(close());
        return false;
    }
    return true;
}

} // namespace wirex::wave_output_open
