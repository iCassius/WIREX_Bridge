#include "wirex/app/radio_info.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <system_error>
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
    {   // 语句间短暂停顿不关门（先 muted，重新开门 unmuted）；超过 hang 关门。
        SquelchGate gate;
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        check(!gate.muted(), "open gate is not muted");
        check(gate.sample(rx(false), at(200)) == GateEvent::muted, "first closed sample reports muted");
        check(gate.open() && gate.muted(), "muted gate is still open");
        check(gate.sample(rx(false), at(300)) == GateEvent::none, "muted is reported once per pause");
        check(gate.sample(rx(true), at(500)) == GateEvent::unmuted, "re-open within hang reports unmuted");
        check(gate.open() && !gate.muted(), "unmuted gate keeps the call open");
        check(gate.sample(rx(true), at(550)) == GateEvent::none, "staying open after unmute is not an event");
        check(gate.sample(rx(false), at(600)) == GateEvent::muted, "pause again reports muted");
        check(gate.sample(rx(false), at(1100)) == GateEvent::none, "still within 600 ms hang");
        check(gate.sample(rx(false), at(1200)) == GateEvent::closed, "closes after hang");
        check(!gate.open() && !gate.muted(), "gate reports closed");
        check(gate.sample(rx(false), at(1300)) == GateEvent::none, "closed gate does not report muted");
    }
    {   // muted 后由 tick 到期关门；采样失败不影响 hang 计时。
        SquelchGate gate;
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        check(gate.sample(rx(false), at(200)) == GateEvent::muted, "muted before failed polls");
        check(gate.sample(std::nullopt, at(400)) == GateEvent::none, "failed poll during hang");
        check(gate.tick(at(799)) == GateEvent::none, "tick before hang expires");
        check(gate.tick(at(800)) == GateEvent::closed, "tick closes once hang expires");
    }
    {   // 门未开时的关门采样不报 muted；发射立即关门（不经过 muted）。
        SquelchGate gate;
        check(gate.sample(rx(false), at(0)) == GateEvent::none, "closed gate ignores closed samples");
        (void)gate.sample(rx(true), at(100));
        check(gate.sample(rx(false), at(200)) == GateEvent::none, "half-open (one sample) does not mute");
        (void)gate.sample(rx(true), at(300));
        (void)gate.sample(rx(true), at(400));
        check(gate.sample(rx(false), at(500)) == GateEvent::muted, "muted after open");
        RadioInfo tx = rx(true);
        tx.tx = TxState::tx;
        check(gate.sample(tx, at(600)) == GateEvent::closed, "radio TX while muted closes immediately");
    }
    {   // hang=0：直接关门，不报 muted。
        GateConfig config{};
        config.hang = milliseconds(0);
        SquelchGate gate(config);
        (void)gate.sample(rx(true), at(0));
        (void)gate.sample(rx(true), at(100));
        check(gate.sample(rx(false), at(200)) == GateEvent::closed, "zero hang closes without muted");
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


// 实机回放（2026-11-06，145.200 MHz FM，100 ms 轮询）：research/hil/2026-11-06_fm_squelch_capture2.jsonl
// 位于仓库外父目录（只读）。找不到文件时打印 SKIP，不视为失败。
std::filesystem::path find_capture()
{
    namespace fs = std::filesystem;
    const fs::path name = fs::path("research") / "hil" / "2026-11-06_fm_squelch_capture2.jsonl";
    std::error_code ec;
    char* env = nullptr;
    std::size_t env_size = 0U;
    if (_dupenv_s(&env, &env_size, "WIREX_SQUELCH_CAPTURE") == 0 && env != nullptr) {
        const fs::path p(env);
        std::free(env);
        if (fs::is_regular_file(p, ec)) return p;
    }
    // 主仓库 app/ 下为 ../../research；worktree（app/.claude/worktrees/<id>）需继续向上找。
    fs::path dir = fs::current_path(ec);
    if (ec) return {};
    while (!dir.empty()) {
        std::error_code probe;
        if (fs::is_regular_file(dir / name, probe)) return dir / name;
        if (dir == dir.parent_path()) break;
        dir = dir.parent_path();
    }
    return {};
}

struct ReplayEvent {
    GateEvent event;
    long long t_ms;
};

void test_capture_replay()
{
    const auto path = find_capture();
    if (path.empty()) {
        std::printf("SKIP: squelch capture replay (research/hil/2026-11-06_fm_squelch_capture2.jsonl not found)\n");
        return;
    }
    std::ifstream in(path, std::ios::binary);
    check(static_cast<bool>(in), "capture file opens");
    SquelchGate gate;
    const auto t0 = Clock::now();
    std::vector<ReplayEvent> events;
    std::vector<long long> sql_edges;  // 原始 P8 变化时刻
    bool last_sql = false;
    std::size_t samples = 0U;
    std::string line;
    while (std::getline(in, line)) {
        const auto t_pos = line.find("\"t_ms\": ");
        const auto ri_pos = line.find("\"ri\": \"");
        if (t_pos == std::string::npos || ri_pos == std::string::npos) continue;
        const long long t_ms = std::atoll(line.c_str() + t_pos + 8U);
        const auto ri_begin = ri_pos + 7U;
        const auto ri_end = line.find('"', ri_begin);
        if (ri_end == std::string::npos) continue;
        const auto info = parse(std::string_view(line).substr(ri_begin, ri_end - ri_begin));
        ++samples;
        if (info && info->squelch_open != last_sql) {
            last_sql = info->squelch_open;
            sql_edges.push_back(t_ms);
        }
        const auto event = gate.sample(info, t0 + milliseconds(t_ms));
        if (event != GateEvent::none) events.push_back({event, t_ms});
    }
    std::printf("replay: %s (%zu samples)\n", path.string().c_str(), samples);
    check(samples == 448U, "capture has 448 samples (got " + std::to_string(samples) + ")");
    // P8：34578 开、35875 关、37172 开、40922 关、42625 开（文件结束时仍开）。
    check(sql_edges.size() == 5U, "capture has five P8 edges");
    const std::vector<GateEvent> expected{GateEvent::opened, GateEvent::muted, GateEvent::closed,
                                          GateEvent::opened, GateEvent::muted, GateEvent::closed,
                                          GateEvent::opened};
    bool same = events.size() == expected.size();
    for (std::size_t i = 0U; same && i < expected.size(); ++i) same = events[i].event == expected[i];
    check(same, "replay yields opened, muted, closed, opened, muted, closed, opened");
    if (!same || sql_edges.size() != 5U) {
        for (const auto& e : events) std::printf("  event %d at %lld ms\n", static_cast<int>(e.event), e.t_ms);
        return;
    }
    // muted 落在第一个 P8=0 采样；closed 在其后 hang（600 ms）到期后的第一个采样。
    check(events[1].t_ms == sql_edges[1] && events[4].t_ms == sql_edges[3],
          "muted fires on the first closed sample");
    const auto hang1 = events[2].t_ms - events[1].t_ms;
    const auto hang2 = events[5].t_ms - events[4].t_ms;
    std::printf("replay: muted→closed %lld / %lld ms\n", hang1, hang2);
    check(hang1 >= 600 && hang1 <= 800 && hang2 >= 600 && hang2 <= 800,
          "closed follows muted after the 600 ms hang");
    check(events[0].t_ms > sql_edges[0] && events[0].t_ms - sql_edges[0] <= 200 &&
              events[3].t_ms > sql_edges[2] && events[3].t_ms - sql_edges[2] <= 200,
          "opened on the second consecutive open sample");
    check(gate.open() && !gate.muted(), "capture ends with the gate open");
}

} // namespace

int main()
{
    test_parse();
    test_gate();
    test_capture_replay();
    if (failures != 0) {
        std::printf("%d of %d radio info checks failed\n", failures, checks);
        return 1;
    }
    std::printf("PASS: app_radio_info_test (%d checks)\n", checks);
    return 0;
}
