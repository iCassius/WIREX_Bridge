#pragma once

namespace wirex::audio_input_cleanup {

// 记录一只 WaveIn 对象的关闭结果；发生失败后本轮不能再次打开。
class State {
public:
    void record_close_result(bool succeeded) noexcept
    {
        if (!succeeded) close_failed_ = true;
    }

    [[nodiscard]] bool reopen_allowed() const noexcept { return !close_failed_; }
    [[nodiscard]] bool close_failed() const noexcept { return close_failed_; }

    template <typename Close>
    bool close_if_open(bool& input_open, Close&& close)
    {
        if (!input_open) return !close_failed_;
        const bool succeeded = close();
        input_open = false;
        record_close_result(succeeded);
        return succeeded;
    }

private:
    bool close_failed_{false};
};

} // namespace wirex::audio_input_cleanup
