#include "../src/gui/fake_engine.hpp"

#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <string>

namespace {

using namespace std::chrono_literals;
using wirex::engine::CommandResult;
using wirex::engine::CommandStatus;

int assertions = 0;

void check(bool condition, const char* message)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void test_start_stop_interleaving_cancels_late_cat_connect()
{
    wirex::gui::FakeEngine engine;
    auto services = wirex::gui::make_fake_services(engine);

    std::promise<CommandResult> connect_promise;
    auto connect_future = connect_promise.get_future();
    services.cat.connect(L"COM6", 38400U, [&connect_promise](CommandResult result) {
        connect_promise.set_value(std::move(result));
    });

    const auto connecting = services.cat.state();
    check(connecting.busy && !connecting.connected,
          "CAT state reports the in-flight connection before stop begins");

    std::promise<CommandResult> disconnect_promise;
    auto disconnect_future = disconnect_promise.get_future();
    services.cat.disconnect([&disconnect_promise](CommandResult result) {
        disconnect_promise.set_value(std::move(result));
    });

    check(disconnect_future.wait_for(1s) == std::future_status::ready,
          "stop/disconnect completes within its fake service delay");
    const auto disconnected = disconnect_future.get();
    check(disconnected.status == CommandStatus::accepted,
          "stop/disconnect cancels the pending CAT connection generation");

    check(connect_future.wait_for(1s) == std::future_status::ready,
          "superseded CAT connection callback eventually resolves");
    const auto connect_result = connect_future.get();
    check(connect_result.status == CommandStatus::not_ready &&
          connect_result.detail == "cat_connection_cancelled",
          "late CAT connection reports cancellation instead of success");

    const auto final_state = services.cat.state();
    check(!final_state.connected && !final_state.busy && final_state.port.empty(),
          "late CAT connection leaves no connected, busy, or selected-port state after stop");
}

} // namespace

int main()
{
    test_start_stop_interleaving_cancels_late_cat_connect();
    std::cout << "PASS: " << assertions << " fake CAT lifecycle assertions\n";
    return EXIT_SUCCESS;
}
