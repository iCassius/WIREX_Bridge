#pragma once

// wirex_bridge --run 的前端：CLI 已完成参数与预检后，由本适配层启动进程内 Engine，并把
// stdin（control-v1 Q/EOF、control-v2 JSONL）或控制台按键转成 Engine 调用，
// 把 Engine 的诊断钩子写成与 R127 相同的 --status-file JSONL。

#include "wirex/console_lifecycle.hpp"
#include "wirex/engine.hpp"

#include <cstdint>
#include <fstream>
#include <string>

namespace wirex::engine::adapter {

struct FrontendOptions {
    bool ui_pipe{};
    std::uint32_t ui_control_version{1U};
    std::string run_id{};
    std::uint64_t status_sequence{};   // 已写入 status.jsonl 的最后一个 seq（preflight 之后为 1）
};

// 返回进程退出码（0 成功，2 失败）。status_file 已写入 preflight_passed 记录。
[[nodiscard]] int run_engine_frontend(StartConfig config, const FrontendOptions& options,
                                      std::ofstream& status_file, ConsoleHandlerScope& control_scope);

} // namespace wirex::engine::adapter
