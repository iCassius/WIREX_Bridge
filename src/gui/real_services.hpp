#pragma once

// 用 wirex::app 的 C++ 服务实现 services.hpp 的接口（R128 集成）。
// 线程：
// - CAT：一个 runner 线程串行执行连接/应用/每秒轮询，内部通过 app::CatWorker 访问串口；
// - BM API：一个 HTTP 线程（WinHTTP，单任务串行）；
// - RadioID：一个查询线程（队列 16、请求间隔 ≥1 s、失败指数冷却）。
// 所有回调都在这些后台线程上调用；ViewModel 负责切回 UI 线程。Services::shutdown 会停止并等待全部线程。

#include "engine_api.hpp"
#include "services.hpp"

#include <filesystem>

namespace wirex::gui {

struct RealServiceOptions {
    std::filesystem::path exe_directory{};   // device-y.bin 查找位置；默认 config.json 所在目录
    std::filesystem::path config_path{};     // 空：<exe_directory>/config.json
    // --fake：真实启动参数校验失败时仍返回一份最小 StartConfig（并在 error 中给出原因），让模拟引擎可以连接。
    bool lenient_start{};
};

// engine 必须比返回的 Services 活得久（CAT 门控从 engine.snapshot() 读取核心状态）。
[[nodiscard]] services::Services make_real_services(EngineApi& engine, RealServiceOptions options);

// 当前可执行文件所在目录。
[[nodiscard]] std::filesystem::path executable_directory();

} // namespace wirex::gui
