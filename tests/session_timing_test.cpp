#include "wirex/session_timing.hpp"

#include <iostream>

int main()
{
    using wirex::session_timing::StopBudget;
    using wirex::session_timing::active_window_expired;
    using wirex::session_timing::cleanup_grace_ms;

    if (active_window_expired(119999) || !active_window_expired(120000)) {
        std::cerr << "120 秒运行窗口边界不正确\n";
        return 1;
    }

    StopBudget natural_deadline(cleanup_grace_ms);
    if (!natural_deadline.begin_shutdown(120000) || natural_deadline.deadline_ms() != 123000 ||
        natural_deadline.expired(122999) || !natural_deadline.expired(123000) ||
        natural_deadline.begin_shutdown(121500) || natural_deadline.deadline_ms() != 123000) {
        std::cerr << "自然运行期限后的固定收尾预算不正确\n";
        return 1;
    }

    StopBudget user_cancel(cleanup_grace_ms);
    if (!user_cancel.begin_shutdown(500) || user_cancel.deadline_ms() != 3500 ||
        user_cancel.expired(3499) || user_cancel.begin_shutdown(1000) ||
        user_cancel.deadline_ms() != 3500 || !user_cancel.expired(3500)) {
        std::cerr << "重复取消延长了收尾预算或边界不正确\n";
        return 1;
    }

    std::cout << "session stop budget tests passed\n";
    return 0;
}
