#pragma once

#include <string_view>

namespace wirex::ui_control {

enum class Result {
    pending,
    shutdown,
    invalid
};

// WPF 管理的 native run 只接受一个大写 Q 行或输入流 EOF 作为停止请求。
class Parser final {
public:
    [[nodiscard]] Result feed(std::string_view bytes) noexcept
    {
        if (state_ == State::invalid) return Result::invalid;
        if (state_ == State::shutdown) return bytes.empty() ? Result::shutdown : invalidate();
        for (const char byte : bytes) {
            switch (state_) {
            case State::waiting_q:
                if (byte == 'Q') state_ = State::waiting_terminator;
                else return invalidate();
                break;
            case State::waiting_terminator:
                if (byte == '\n') state_ = State::shutdown;
                else if (byte == '\r') state_ = State::waiting_lf;
                else return invalidate();
                break;
            case State::waiting_lf:
                if (byte == '\n') state_ = State::shutdown;
                else return invalidate();
                break;
            case State::shutdown:
                return invalidate();
            case State::invalid:
                return Result::invalid;
            }
        }
        return state_ == State::shutdown ? Result::shutdown : Result::pending;
    }

    [[nodiscard]] Result eof() noexcept
    {
        if (state_ == State::invalid) return Result::invalid;
        state_ = State::shutdown;
        return Result::shutdown;
    }

private:
    enum class State {
        waiting_q,
        waiting_terminator,
        waiting_lf,
        shutdown,
        invalid
    };

    [[nodiscard]] Result invalidate() noexcept
    {
        state_ = State::invalid;
        return Result::invalid;
    }

    State state_{State::waiting_q};
};

} // namespace wirex::ui_control
