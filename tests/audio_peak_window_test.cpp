#include "wirex/audio_peak_window.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

namespace {
int assertions = 0;

void check(bool ok, const char* message) {
    ++assertions;
    if (!ok) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}
} // namespace

int main() {
    using wirex::audio_meter::PeakWindow;
    using namespace std::chrono_literals;
    const auto origin = PeakWindow::Clock::time_point{};
    PeakWindow meter;

    meter.push(0.4F, origin);
    check(std::abs(meter.value(origin + 199ms) - 0.4F) < 0.0001F, "level is visible inside the 200 ms window");
    meter.push(0.8F, origin + 100ms);
    check(std::abs(meter.value(origin + 200ms) - 0.8F) < 0.0001F, "window reports its highest recent peak");
    check(std::abs(meter.value(origin + 300ms) - 0.8F) < 0.0001F, "newer sample remains inside the window");
    check(meter.value(origin + 301ms) == 0.0F, "level clears after all samples leave the window");

    meter.push(2.0F, origin + 400ms);
    check(meter.value(origin + 400ms) == 1.0F, "level is clamped to its normalized maximum");
    meter.push(std::numeric_limits<float>::quiet_NaN(), origin + 410ms);
    check(meter.value(origin + 410ms) == 1.0F, "non-finite samples do not corrupt the live peak");

    std::cout << "PASS: " << assertions << " audio peak-window assertions\n";
    return 0;
}
