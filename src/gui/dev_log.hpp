#pragma once

// 隐藏的 dev 日志：开发版（WIREX_DEV_BUILD=1）默认开启，正式版默认关闭；
// 命令行 --dev-log / --no-dev-log 覆盖默认值。输出到 <exe 目录>/logs/wirex-<本地时间>.log。
// 记录引擎状态、操作员提示、GUI 操作结果及 HRI/CAT 诊断帧。
// 不记录 BM 密码、API Key 或音频数据。

#include "wirex/engine_diagnostics.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string_view>

namespace wirex::gui {

#ifndef WIREX_DEV_BUILD
#define WIREX_DEV_BUILD 0
#endif

class DevLog final {
public:
    // 打开失败时返回 nullptr（不影响程序运行）。
    [[nodiscard]] static std::shared_ptr<DevLog> open(const std::filesystem::path& exe_directory);

    // 线程安全；每行自动加本地时间戳与换行，并立即 flush（便于崩溃后分析）。
    void line(std::string_view category, std::string_view text);

    // 把引擎诊断钩子接到本日志；保留调用方已设置的钩子（先调原钩子，再写日志）。
    void attach(engine::DiagnosticsHooks& hooks, std::string_view run_label);

    void reset_hri_correlation();
    void observe_hri_ptt(bool pressed);
    void poll_hri_correlation();
    void observe_cat_frame(std::string_view frame);

    [[nodiscard]] const std::filesystem::path& path() const noexcept;
    // 每次 attach 递增的运行序号（日志里区分同一进程内的多次引擎运行）。
    [[nodiscard]] std::uint64_t next_run_seq();

    ~DevLog();
    DevLog(const DevLog&) = delete;
    DevLog& operator=(const DevLog&) = delete;

private:
    DevLog();
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// 进程级实例（gui_main 在启动时设置；未开启时为 nullptr）。
void set_dev_log(std::shared_ptr<DevLog> log);
[[nodiscard]] std::shared_ptr<DevLog> dev_log();

} // namespace wirex::gui
