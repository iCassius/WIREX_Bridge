#include "../src/gui/hri_diagnostics.hpp"
#include "wirex/direct_frame.hpp"
#include "wirex/direct_stream.hpp"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <chrono>
#include <iostream>
#include <string>
#include <vector>

int main()
{
    using namespace wirex::gui::hri_diagnostics;
    Records records;
    std::vector<std::string> lines;
    auto emit = [&](const std::string& line) { assert(line.size() < 560U); lines.push_back(line); };
    bool pressed = false;
    auto ptt = [&](bool value) { pressed = value; };
    std::vector<std::uint8_t> body(100U, '0');
    records.record(true, 'Y', body, emit, ptt);
    assert(lines.size() == 2U && lines[0].find("dump Y dir=TX n=100") == 0U);
    std::cout << "[hri] " << lines[0] << '\n';
    lines.clear();
    records.record(true, 'Y', body, emit, ptt);
    assert(lines.empty());
    body[12] = '2';
    body[16] = '1'; body[17] = '2';
    records.record(true, 'Y', body, emit, ptt);
    assert(lines.size() == 3U && lines[0] == "Y changed=0x0C,0x10-0x11");
    std::cout << "[hri] " << lines[0] << '\n';
    lines.clear();
    body[12] = '0';
    records.record(false, 'X', body, emit, ptt);
    assert(!pressed && lines.size() == 2U);
    lines.clear();
    body[12] = '2'; body[30] = 0x01U;
    records.record(false, 'X', body, emit, ptt);
    assert(pressed && lines.size() == 3U);
    assert(lines[0] == "X diff=0x0C:30->32,0x1E:30->01");
    std::cout << "[hri] " << lines[0] << '\n';
    lines.clear();
    body[30] = 0x02U;
    records.record(false, 'X', body, emit, ptt);
    assert(lines.size() == 1U && lines[0] == "X diff=0x1E:01->02");
    lines.clear();
    records.record(false, 'X', std::vector<std::uint8_t>(100U, 0x0AU), emit, ptt);
    assert(lines.size() > 3U && lines.back().find("ascii=....................") != std::string::npos);
    lines.clear();
    for (int i = 0; i < 21; ++i) records.record(false, 'U', {}, emit, ptt);
    assert(lines.size() == 21U && lines.back() == "count U n=21");
    lines.clear();
    records.record(false, 'G', std::vector<std::uint8_t>(300U, 0U), emit, ptt);
    assert(lines.size() == 4U && lines[0].find("capped=256") != std::string::npos);
    lines.clear();
    records.record(false, 'T', std::vector<std::uint8_t>(118U, 0U), emit, ptt);
    assert(lines.size() == 2U && lines[0].find("dump T") == 0U);
    records.reset();
    lines.clear();
    records.record(true, 'Y', body, emit, ptt);
    assert(lines.size() == 2U);

    const auto encoded = wirex::direct_frame::encode({'X', body});
    assert(encoded);
    wirex::direct_stream::Parser parser;
    assert(parser.feed(encoded.bytes.data(), 3U).events.empty());
    const auto parsed = parser.feed(encoded.bytes.data() + 3U, encoded.bytes.size() - 3U);
    assert(parsed.events.size() == 1U && parsed.events[0].has_record && parsed.events[0].record.payload == body);

    PttCorrelation correlation;
    const auto now = PttCorrelation::Clock::time_point{};
    using namespace std::chrono_literals;
    assert(!correlation.cat("TX0;", now));
    assert(!correlation.ptt(true, now));
    assert(!correlation.cat("TX0;", now + 500ms));
    assert(!correlation.ptt(true, now + 1500ms));
    assert(correlation.tick(now + 1501ms));
    assert(!correlation.cat("TX0;", now + 2000ms));
    assert(!correlation.ptt(false, now + 2100ms));
    assert(!correlation.ptt(true, now + 2200ms));
    assert(!correlation.cat("TX0;", now + 2300ms));
    assert(!correlation.cat("TX1;", now + 2400ms));
    assert(!correlation.ptt(true, now + 4000ms));
    assert(correlation.cat("TX0;", now + 4100ms));
    std::cout << "[hri] warn ptt_pressed_but_radio_not_transmitting\n";
    std::cout << "gui_hri_diagnostics_test passed\n";
}
