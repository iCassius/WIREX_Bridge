#pragma once

#include <string_view>

namespace wirex::operation_audio_cleanup {

// 记录单轮下行的 WaveOut 关闭结果；关闭失败后状态只能保持失败。
class State {
public:
    void begin_operation() noexcept
    {
        begun_ = true;
        close_failed_ = false;
    }

    void record_close_result(bool succeeded) noexcept
    {
        if (!succeeded) close_failed_ = true;
    }

    template <typename Close>
    bool close_if_open(bool& output_open, Close&& close)
    {
        if (!output_open) return !close_failed_;
        const bool succeeded = close();
        output_open = false;
        record_close_result(succeeded);
        return succeeded;
    }

    [[nodiscard]] bool close_failed() const noexcept { return close_failed_; }
    [[nodiscard]] bool reopen_allowed() const noexcept { return !close_failed_; }

    [[nodiscard]] std::string_view status(bool output_open) const noexcept
    {
        if (close_failed_) return "failed";
        if (!begun_) return "not_started";
        return output_open ? "pending" : "succeeded";
    }

private:
    bool begun_{false};
    bool close_failed_{false};
};

} // namespace wirex::operation_audio_cleanup
