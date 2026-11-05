#include "wirex/app/radio_info.hpp"

#include <cstdio>
#include <string>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool ok, const std::string& what)
{
    ++checks;
    if (!ok) {
        ++failures;
        std::printf("FAILED: %s\n", what.c_str());
    }
}

using namespace wirex::app::radio_info;
using Clock = SquelchGate::Clock;
using std::chrono::milliseconds;

void test_parse()
{
    struct Case {
        const char* name;
        const char* answer;
        bool ok;
        bool squelch;
        TxState tx;
    };
    const std::vector<Case> cases{
        {"recorded idle answer", "RI00000000;", true, false, TxState::rx},
        {"squelch open", "RI00000001;", true, true, TxState::rx},
        {"transmitting", "RI00010000;", true, false, TxState::tx},
        {"tx inhibit with busy", "RI00020001;", true, true, TxState::tx_inhibit},
        {"hi-swr, playing, tuning, scan paused", "RI01200121;", true, true, TxState::rx},
        {"too short", "RI0000000;", false, false, TxState::rx},
        {"too long", "RI000000000;", false, false, TxState::rx},
        {"missing terminator", "RI000000000", false, false, TxState::rx},
        {"wrong command", "RG00000000;", false, false, TxState::rx},
        {"P1 not fixed 0", "RI10000000;", false, false, TxState::rx},
        {"P5 not fixed 0", "RI00001000;", false, false, TxState::rx},
        {"P8 out of range", "RI00000002;", false, false, TxState::rx},
        {"P4 out of range", "RI00030000;", false, false, TxState::rx},
        {"non-digit", "RI0000000X;", false, false, TxState::rx},
        {"empty", "", false, false, TxState::rx},
    };
    for (const auto& c : cases) {
        const auto info = parse(c.answer);
        check(info.has_value() == c.ok, std::string("parse validity: ") + c.name);
        if (info && c.ok) {
            check(info->squelch_open == c.squelch, std::string("squelch: ") + c.name);
            check(info->tx == c.tx, std::string("tx: ") + c.name);
        }
    }
    const auto detail = parse("RI01200121;");
    check(detail && detail->hi_swr && detail->playback == 2U && detail->tuning && detail->scan == ScanState::paused,
          "all fields decoded");
}

RadioInfo rx(bool squelch)
{
    RadioInfo info{};
    info.squelch_open = squelch;
    return info;
}

void test_gate()
{
    const auto t0 = Clock::now();
    auto at = [&](int ms) { return t0 + milliseconds(ms); };

    {   // 单次尖峰不开门；连续两次开门。
        SquelchGate gate;
        check(gate.sample(rx(true), at(0)) == GateEvent::none, "first open sample does not open");
        check(gate.sample(rx(false), at(100)) == GateEvent::none, "spike resets");
        check(gate.sample(rx(true), at(200)) == GateEvent::none, "needs consecutive samples");
        check(gate.sample(rx(true), at(300)) == GateEvent::opened, "two consecutive open samples open the gate");
        check(gate.open(), "gate reports open");
        check(gate.sample(rx(true), at(400)) == GateEvent::none, "staying open is not a new event");
    }
    {   // 语句间短暂停顿不关门；超过 hang 关门。
        SquelchGate gate;
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        check(gate.sample(rx(false), at(200)) == GateEvent::none, "short pause holds");
        check(gate.sample(rx(true), at(500)) == GateEvent::none, "re-open within hang keeps the call");
        check(gate.sample(rx(false), at(600)) == GateEvent::none, "pause again");
        check(gate.sample(rx(false), at(1100)) == GateEvent::none, "still within 600 ms hang");
        check(gate.sample(rx(false), at(1200)) == GateEvent::closed, "closes after hang");
        check(!gate.open(), "gate reports closed");
    }
    {   // 电台发射立即关门（防止把自己的发射当作来话/回环）。
        SquelchGate gate;
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        RadioInfo tx = rx(true);
        tx.tx = TxState::tx;
        check(gate.sample(tx, at(200)) == GateEvent::closed, "radio TX closes immediately");
        check(gate.sample(tx, at(300)) == GateEvent::none, "TX with busy never opens");
        check(gate.sample(tx, at(400)) == GateEvent::none, "still not opened during TX");
    }
    {   // 查询失败超过 stale：关门；无新采样时 tick 也能关门。
        SquelchGate gate;
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        check(gate.sample(std::nullopt, at(500)) == GateEvent::none, "one failed poll tolerated");
        check(gate.tick(at(1099)) == GateEvent::none, "below stale threshold");
        check(gate.tick(at(1100)) == GateEvent::closed, "stale CAT closes the gate");
    }
    {   // reset 清空状态。
        SquelchGate gate;
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        gate.reset();
        check(!gate.open(), "reset closes without event");
        check(gate.sample(rx(true), at(200)) == GateEvent::none, "after reset needs consecutive samples again");
    }
}

} // namespace

int main()
{
    test_parse();
    test_gate();
    if (failures != 0) {
        std::printf("%d of %d radio info checks failed\n", failures, checks);
        return 1;
    }
    std::printf("PASS: app_radio_info_test (%d checks)\n", checks);
    return 0;
}
