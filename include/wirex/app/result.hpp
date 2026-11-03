#pragma once

#include <optional>
#include <utility>

namespace wirex::app {

// Minimal value-or-error holder shared by the app services. Accessing value()
// on an error result is a programming error; check ok() first.
template <class T, class E>
class Result {
public:
    Result(T value) : value_(std::move(value)) {}  // NOLINT(google-explicit-constructor)
    Result(E error) : error_(std::move(error)) {}  // NOLINT(google-explicit-constructor)

    [[nodiscard]] bool ok() const noexcept { return value_.has_value(); }
    explicit operator bool() const noexcept { return ok(); }

    [[nodiscard]] T& value() & { return *value_; }
    [[nodiscard]] const T& value() const& { return *value_; }
    [[nodiscard]] T&& value() && { return std::move(*value_); }
    [[nodiscard]] const E& error() const noexcept { return error_; }

private:
    std::optional<T> value_{};
    E error_{};
};

} // namespace wirex::app
