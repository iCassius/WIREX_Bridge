#include "wirex/app/radio_cat.hpp"

#include <algorithm>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// 不打开任何真实串口：所有 CatClient 测试均通过 FakeTransport（行为照搬 tools/test-radio-cat.ps1 的 fake）。

namespace {

using namespace wirex::app;
using namespace std::chrono_literals;

int assertions = 0;

void check(bool condition, const std::string& description)
{
    ++assertions;
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

// ---------- 解析：表驱动 ----------

struct ParseCase {
    const char* name;
    const char* frame;
    CatCommand expected;
    CatFrameStatus status;
    CatError error;
};

void test_parse_table()
{
    const ParseCase cases[] = {
        {"ID0840 ok", "ID0840;", CatCommand::id, CatFrameStatus::ok, CatError::none},
        {"ID1234 still parses (identity checked later)", "ID1234;", CatCommand::id, CatFrameStatus::ok, CatError::none},
        {"ID short", "ID084;", CatCommand::id, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"AI0", "AI0;", CatCommand::ai, CatFrameStatus::ok, CatError::none},
        {"AI1", "AI1;", CatCommand::ai, CatFrameStatus::ok, CatError::none},
        {"AI2 rejected", "AI2;", CatCommand::ai, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"TX0", "TX0;", CatCommand::tx, CatFrameStatus::ok, CatError::none},
        {"TX2", "TX2;", CatCommand::tx, CatFrameStatus::ok, CatError::none},
        {"TX3 rejected", "TX3;", CatCommand::tx, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"FA fake main", "FA014250000;", CatCommand::fa, CatFrameStatus::ok, CatError::none},
        {"FB fake sub", "FB014300000;", CatCommand::fb, CatFrameStatus::ok, CatError::none},
        {"FA lower bound", "FA000030000;", CatCommand::fa, CatFrameStatus::ok, CatError::none},
        {"FA upper bound", "FA470000000;", CatCommand::fa, CatFrameStatus::ok, CatError::none},
        {"FA below range", "FA000029999;", CatCommand::fa, CatFrameStatus::protocol_error, CatError::frequency_out_of_range},
        {"FA above range", "FA470000001;", CatCommand::fa, CatFrameStatus::protocol_error, CatError::frequency_out_of_range},
        {"FA eight digits", "FA14250000;", CatCommand::fa, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"FB frame for FA", "FB014300000;", CatCommand::fa, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"MD0H", "MD0H;", CatCommand::md, CatFrameStatus::ok, CatError::none},
        {"MD14", "MD14;", CatCommand::md, CatFrameStatus::ok, CatError::none},
        {"MD0G reserved", "MD0G;", CatCommand::md, CatFrameStatus::protocol_error, CatError::unknown_mode_code},
        {"MD0J out of alphabet", "MD0J;", CatCommand::md, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"MD2 side", "MD24;", CatCommand::md, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"PC2025", "PC2025;", CatCommand::pc, CatFrameStatus::ok, CatError::none},
        {"PC1010", "PC1010;", CatCommand::pc, CatFrameStatus::ok, CatError::none},
        {"PC1011 above FieldHead", "PC1011;", CatCommand::pc, CatFrameStatus::protocol_error, CatError::power_out_of_range},
        {"PC2100 radio max", "PC2100;", CatCommand::pc, CatFrameStatus::ok, CatError::none},
        {"PC2004 below min", "PC2004;", CatCommand::pc, CatFrameStatus::protocol_error, CatError::power_out_of_range},
        {"PC3025 path", "PC3025;", CatCommand::pc, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"?; radio error", "?;", CatCommand::pc, CatFrameStatus::radio_error, CatError::radio_rejected_command},
        {"leading space", " ID0840;", CatCommand::id, CatFrameStatus::protocol_error, CatError::invalid_frame},
        {"trailing newline", "ID0840;\n", CatCommand::id, CatFrameStatus::protocol_error, CatError::invalid_frame},
        {"missing terminator", "ID0840", CatCommand::id, CatFrameStatus::protocol_error, CatError::unexpected_response},
        {"empty", "", CatCommand::id, CatFrameStatus::protocol_error, CatError::invalid_frame},
    };
    for (const auto& c : cases) {
        const auto parsed = cat_parse_frame(c.frame, c.expected);
        check(parsed.status == c.status && parsed.error == c.error, std::string("parse: ") + c.name);
    }
    check(cat_parse_frame(std::string(65U, 'A'), CatCommand::id).error == CatError::invalid_frame,
          "parse: frames over 64 bytes are rejected");

    const auto id = cat_parse_frame("ID0840;", CatCommand::id);
    check(id.radio_id == "0840", "ID value is exact");
    const auto mode = cat_parse_frame("MD0H;", CatCommand::md);
    check(mode.mode.side == CatSide::main && mode.mode.mode == CatMode::c4fm_dn && to_string(mode.mode.mode) == "C4FM-DN",
          "MD exposes exact mode name");
    const auto power = cat_parse_frame("PC2025;", CatCommand::pc);
    check(power.power.path == CatPowerPath::spa1 && power.power.watts == 25, "PC separates path and watts");
    check(cat_parse_frame("TX2;", CatCommand::tx).tx_state == 2, "TX2 parses as transmit active");
    check(cat_parse_frame("AI1;", CatCommand::ai).auto_information, "AI1 parses as enabled");
    check(cat_parse_frame("FA145500000;", CatCommand::fa).frequency_hz == 145500000U, "FA Hz value is exact");

    std::string_view command;
    check(cat_frame_command("MD1H;", command) && command == "MD", "generic frame syntax extracts command");
    check(!cat_frame_command("md1H;", command), "lowercase command letters are invalid");
    check(!cat_frame_command("MD1\x01;", command), "control bytes are invalid");
}

// ---------- 帧构造 ----------

void test_command_builders()
{
    struct ModeCase { CatSide side; const char* name; const char* frame; };
    const ModeCase modes[] = {
        {CatSide::main, "C4FM-DN", "MD0H;"},
        {CatSide::sub, "C4FM-VW", "MD1I;"},
        {CatSide::main, "FM", "MD04;"},
        {CatSide::main, "fm", "MD04;"},
        {CatSide::main, "FM-N", "MD0B;"},
    };
    for (const auto& c : modes) {
        const auto mode = cat_mode_from_name(c.name);
        check(mode && cat_mode_command(c.side, *mode) == std::string(c.frame), std::string("mode command ") + c.frame);
    }
    check(!cat_mode_command(CatSide::main, CatMode::usb), "non-voice modes cannot be written");

    struct FrequencyCase { std::uint32_t hz; const char* frame; };
    const FrequencyCase frequencies[] = {
        {14250000U, "FA014250000;"}, {30000U, "FA000030000;"}, {470000000U, "FA470000000;"}, {145500000U, "FA145500000;"},
    };
    for (const auto& c : frequencies) {
        check(cat_frequency_command(c.hz) == std::string(c.frame), std::string("frequency command ") + c.frame);
    }
    check(!cat_frequency_command(29999U) && !cat_frequency_command(470000001U), "frequency outside range is rejected");

    struct PowerCase { CatPowerPath path; int watts; const char* frame; };
    const PowerCase powers[] = {
        {CatPowerPath::field_head, 10, "PC1010;"}, {CatPowerPath::spa1, 25, "PC2025;"},
        {CatPowerPath::spa1, 5, "PC2005;"}, {CatPowerPath::spa1, 50, "PC2050;"},
    };
    for (const auto& c : powers) {
        check(cat_power_command(c.path, c.watts) == std::string(c.frame), std::string("power command ") + c.frame);
    }
    check(!cat_power_command(CatPowerPath::field_head, 25), "FieldHead above 10 W is rejected");
    check(!cat_power_command(CatPowerPath::spa1, 51), "app power above 50 W is rejected without clamping");
    check(!cat_power_command(CatPowerPath::spa1, 4), "power below 5 W is rejected");

    check(cat_read_command(CatCommand::id) == "ID;" && cat_mode_read_command(CatSide::sub) == "MD1;", "read commands");

    CatFrameAssembler assembler;
    std::string frame;
    CatFrameAssembler::Step step = CatFrameAssembler::Step::need_more;
    for (const char c : std::string("ID0840;")) step = assembler.push(c, frame);
    check(step == CatFrameAssembler::Step::complete && frame == "ID0840;", "assembler completes on ';'");
    check(assembler.push('\x80', frame) == CatFrameAssembler::Step::invalid, "assembler rejects non-printable bytes");
    for (int i = 0; i < 64; ++i) step = assembler.push('A', frame);
    check(step == CatFrameAssembler::Step::need_more && assembler.push('A', frame) == CatFrameAssembler::Step::invalid,
          "assembler rejects frames longer than 64 bytes");

    struct PortCase { const wchar_t* input; const wchar_t* normalized; bool valid; };
    const PortCase ports[] = {
        {L"COM11", L"COM11", true}, {L"\\\\.\\COM011", L"COM11", true}, {L" com5 ", L"COM5", true},
        {L"COM0", L"COM0", false}, {L"COM1000", L"COM1000", false}, {L"LPT1", L"LPT1", false},
    };
    for (const auto& c : ports) {
        const auto normalized = cat_normalize_port_name(c.input);
        check(normalized == c.normalized && cat_is_valid_port_name(normalized) == c.valid, "port normalization");
    }
}

// ---------- 门控：表驱动 ----------

void test_gates()
{
    const auto now = std::chrono::steady_clock::now();
    struct GateCase {
        const char* name;
        CatOperation operation;
        CatCoreState core;
        CatGateDecision expected;
    };
    // R131：常驻引擎下只按“发射中 / HRI 下行播放中”门控；{transmitting, hri_downlink_active}
    const CatCoreState idle{false, false};
    const CatCoreState tx{true, false};
    const CatCoreState hri_rx{false, true};
    const CatCoreState tx_and_rx{true, true};
    const GateCase cases[] = {
        {"query never gated", CatOperation::query, tx_and_rx, CatGateDecision::allowed},
        {"frequency: idle resident engine (BM down / HRI idle)", CatOperation::set_frequency, idle, CatGateDecision::allowed},
        {"frequency: transmitting", CatOperation::set_frequency, tx, CatGateDecision::transmitting},
        {"frequency: HRI downlink playing", CatOperation::set_frequency, hri_rx, CatGateDecision::hri_downlink_active},
        {"frequency: tx wins over rx", CatOperation::set_frequency, tx_and_rx, CatGateDecision::transmitting},
        {"mode: idle", CatOperation::set_mode, idle, CatGateDecision::allowed},
        {"mode: transmitting", CatOperation::set_mode, tx, CatGateDecision::transmitting},
        {"mode: HRI downlink playing", CatOperation::set_mode, hri_rx, CatGateDecision::hri_downlink_active},
        {"power: idle", CatOperation::set_power, idle, CatGateDecision::allowed},
        {"power: incoming call via HRI still allowed", CatOperation::set_power, hri_rx, CatGateDecision::allowed},
        {"power: transmitting", CatOperation::set_power, tx, CatGateDecision::transmitting},
    };
    for (const auto& c : cases) {
        check(cat_gate_for(c.operation, c.core, now) == c.expected, std::string("gate: ") + c.name);
    }

    struct StatusCase { CatError error; CatResultStatus status; };
    const StatusCase statuses[] = {
        {CatError::busy, CatResultStatus::busy},
        {CatError::identity_mismatch, CatResultStatus::identity_mismatch},
        {CatError::hri_port_conflict, CatResultStatus::rejected},
        {CatError::power_out_of_range, CatResultStatus::rejected},
        {CatError::frequency_out_of_range, CatResultStatus::rejected},
        {CatError::power_mode_not_supported, CatResultStatus::rejected},
        {CatError::radio_rejected_command, CatResultStatus::rejected},
        {CatError::gate_transmitting, CatResultStatus::busy},
        {CatError::gate_hri_downlink, CatResultStatus::busy},
        {CatError::readback_mismatch, CatResultStatus::mismatch},
        {CatError::timeout, CatResultStatus::unknown},
        {CatError::invalid_frame, CatResultStatus::unknown},
        {CatError::side_mismatch, CatResultStatus::unknown},
        {CatError::serial_io_error, CatResultStatus::unknown},
        {CatError::cancelled, CatResultStatus::unknown},
    };
    for (const auto& c : statuses) {
        check(cat_status_for_error(c.error) == c.status, std::string("status map: ") + std::string(to_string(c.error)));
    }

    check(cat_write_permit_fresh(now - 3000ms, now) && !cat_write_permit_fresh(now - 3001ms, now) &&
              !cat_write_permit_fresh(now + 1ms, now),
          "write permit freshness window is 3 s");
}

// ---------- Fake transport（照搬 PS fake） ----------

struct FakeState {
    std::string ri_answer{"RI00000000;"};   // R130 静噪采样
    std::string sm_answer{"SM0080;"};       // 空字符串：SM0 不应答
    std::string radio_id{"0840"};
    bool ai{false};
    int tx{0};
    std::deque<int> tx_sequence{};
    char power_path{'2'};
    int power_watts{25};
    std::map<char, char> modes{{'0', '4'}, {'1', '4'}};
    std::string async_before_md0{};
    std::string frequency_main{"014250000"};
    std::string frequency_sub{"014300000"};
    bool reject_mode_write{false};
    bool reject_power_write{false};
    bool reject_frequency_write{false};
    bool close_fails{false};
    std::string no_response_for{};
    bool opened{false};
    bool closed{false};
    std::vector<std::string> writes{};
    std::deque<std::string> responses{};
    std::function<void(const std::string&)> on_write{};
};

bool starts_with(const std::string& text, const char* prefix) { return text.rfind(prefix, 0U) == 0U; }

class FakeTransport final : public CatTransport {
public:
    explicit FakeTransport(std::shared_ptr<FakeState> state) : state_(std::move(state)) {}
    CatIo open() override { state_->opened = true; return CatIo::ok; }
    CatIo clear_input() override { return CatIo::ok; }
    CatIo write_frame(std::string_view frame_view, std::chrono::milliseconds) override
    {
        const std::string frame(frame_view);
        auto& s = *state_;
        s.writes.push_back(frame);
        if (s.on_write) s.on_write(frame);
        if (s.no_response_for == frame) return CatIo::ok;
        if (frame == "ID;") s.responses.push_back("ID" + s.radio_id + ";");
        else if (frame == "AI;") s.responses.push_back(s.ai ? "AI1;" : "AI0;");
        else if (frame == "TX;") {
            int value = s.tx;
            if (!s.tx_sequence.empty()) { value = s.tx_sequence.front(); s.tx_sequence.pop_front(); }
            s.responses.push_back("TX" + std::to_string(value) + ";");
        } else if (frame == "FA;") s.responses.push_back("FA" + s.frequency_main + ";");
        else if (frame == "FB;") s.responses.push_back("FB" + s.frequency_sub + ";");
        else if (frame == "MD0;" || frame == "MD1;") {
            const char side = frame[2];
            if (side == '0' && !s.async_before_md0.empty()) {
                s.responses.push_back(s.async_before_md0);
                s.async_before_md0.clear();
            }
            s.responses.push_back(std::string("MD") + side + s.modes[side] + ";");
        } else if (frame.size() == 5U && starts_with(frame, "MD")) {
            if (!s.reject_mode_write) s.modes[frame[2]] = frame[3];
        } else if (frame == "PC;") {
            const std::string watts = std::to_string(1000 + s.power_watts).substr(1U);
            s.responses.push_back(std::string("PC") + s.power_path + watts + ";");
        } else if (frame.size() == 7U && starts_with(frame, "PC")) {
            if (!s.reject_power_write) { s.power_path = frame[2]; s.power_watts = std::stoi(frame.substr(3U, 3U)); }
        } else if (frame.size() == 12U && starts_with(frame, "FA")) {
            if (!s.reject_frequency_write) s.frequency_main = frame.substr(2U, 9U);
        } else if (frame == "RI0;") {
            if (!s.ri_answer.empty()) s.responses.push_back(s.ri_answer);
        } else if (frame == "SM0;") {
            if (!s.sm_answer.empty()) s.responses.push_back(s.sm_answer);
        } else {
            std::cerr << "FAIL: fake observed an unapproved CAT command: " << frame << '\n';
            std::exit(EXIT_FAILURE);
        }
        return CatIo::ok;
    }
    CatIo read_frame(std::string& frame, std::chrono::milliseconds, const std::atomic<bool>* cancel) override
    {
        if (cancel && cancel->load()) return CatIo::cancelled;
        if (state_->responses.empty()) return CatIo::timeout;
        frame = state_->responses.front();
        state_->responses.pop_front();
        return CatIo::ok;
    }
    CatIo close() override
    {
        if (state_->close_fails) return CatIo::io_error;
        state_->closed = true;
        return CatIo::ok;
    }
    std::string source_label() const override { return "CAT test transport"; }

private:
    std::shared_ptr<FakeState> state_;
};

CatClient fake_client(const std::shared_ptr<FakeState>& state)
{
    return CatClient([state](const CatConnection&) { return std::make_unique<FakeTransport>(state); });
}

CatConnection connection(const wchar_t* port = L"COM11", const wchar_t* hri = L"COM5")
{
    CatConnection c;
    c.port_name = port;
    c.hri_port_name = hri;
    return c;
}

CatCoreStateProvider stopped_core()
{
    return []() { return CatCoreState{}; };
}

int count_writes(const FakeState& s, const std::string& frame)
{
    int n = 0;
    for (const auto& w : s.writes) n += w == frame ? 1 : 0;
    return n;
}

bool any_write_with_prefix(const FakeState& s, const char* prefix, std::size_t size)
{
    for (const auto& w : s.writes) {
        if (w.size() == size && starts_with(w, prefix)) return true;
    }
    return false;
}

// R131 诊断：包装工厂逐帧记录 TX/RX，含设置功率的写帧与读回；不改变传输行为。
void test_traced_transport_records_frames()
{
    auto s = std::make_shared<FakeState>();
    std::vector<std::string> trace;
    const CatClient client(make_traced_cat_transport_factory(
        [s](const CatConnection&) { return std::make_unique<FakeTransport>(s); },
        [&trace](bool tx, std::string_view frame, std::string_view port) {
            trace.push_back(std::string(tx ? "TX " : "RX ") + std::string(port) + " " + std::string(frame));
        }));
    const auto r = client.set_power(connection(), 5, stopped_core());
    check(r.status == CatResultStatus::confirmed && s->power_watts == 5, "traced client still sets power");
    const auto has = [&](const std::string& line) { return std::find(trace.begin(), trace.end(), line) != trace.end(); };
    check(has("TX COM11 ID;") && has("RX COM11 ID0840;"), "trace records the identity request and answer");
    check(has("TX COM11 PC;") && has("RX COM11 PC2025;"), "trace records the power read before the write");
    check(has("TX COM11 PC2005;") && has("RX COM11 PC2005;"), "trace records the power write and its readback");
    check(trace.size() == s->writes.size() * 2U - 1U, "every written frame is traced and every answer is traced");
    trace.clear();
    s->no_response_for = "FA;";
    (void)client.query_all(connection());
    check(!trace.empty() && trace.back() == "RX COM11 [read timeout]", "a read timeout is traced without a frame");
}

void test_client_against_fake()
{
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).query_all(connection());
        check(r.status == CatResultStatus::confirmed && r.observed.radio_id && r.observed.radio_id->value == "0840",
              "query confirms FTX-1 identity");
        check(r.observed.main_mode->value.mode == CatMode::fm && r.observed.power->value.watts == 25,
              "query returns mode and CAT power setting");
        check(r.observed.power->value.path == CatPowerPath::spa1 && r.capabilities.power_maximum_watts == 50,
              "SPA-1 application capability is capped at 50 W");
        check(r.source == "CAT test transport" && r.observed.power->source == "CAT test transport" && r.updated_at,
              "injected transport data is labelled with a read time");
        check(s->closed && r.cleanup == CatCleanup::closed, "query closes its short-lived session");
        const std::vector<std::string> expected{"ID;", "AI;", "TX;", "FA;", "FB;", "MD0;", "MD1;", "PC;"};
        check(s->writes == expected, "query sends exactly ID/AI/TX/FA/FB/MD0/MD1/PC, one at a time");
        check(cat_query_grants_write_permit(r), "a confirmed idle query grants a write permit");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 30, stopped_core());
        check(r.status == CatResultStatus::confirmed && r.observed.power->value.watts == 30, "power confirmed after PC readback");
        check(count_writes(*s, "PC2030;") == 1, "power write uses active path and requested watts");
        check(count_writes(*s, "TX0;") == 0 && count_writes(*s, "TX1;") == 0, "no TX-set command is written");
        check(s->closed, "power operation closes its session");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 25, stopped_core());
        check(r.status == CatResultStatus::confirmed && count_writes(*s, "TX;") == 1,
              "same-value power skips the extra pre-write TX read");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 25, stopped_core(), nullptr, true);
        check(r.status == CatResultStatus::confirmed && count_writes(*s, "PC2025;") == 1,
              "forced same-value power sends the CAT write for display echo");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_mode(connection(), CatSide::main, CatMode::fm, stopped_core());
        check(r.status == CatResultStatus::confirmed && count_writes(*s, "MD04;") == 0, "same-value mode is not written");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_main_frequency(connection(), 14250000U, stopped_core());
        check(r.status == CatResultStatus::confirmed && count_writes(*s, "FA014250000;") == 0,
              "same-value frequency is not written");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->tx_sequence = {0, 2};
        const auto r = fake_client(s).set_power(connection(), 30, stopped_core());
        check(r.status == CatResultStatus::busy && r.observed.tx_state->value == 2 && !any_write_with_prefix(*s, "PC", 7U),
              "fresh TX2 immediately before a write blocks it");
        check(!r.capabilities.set_power_available && !r.capabilities.set_mode_available, "busy clears write capabilities");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->power_path = '1';
        s->power_watts = 10;
        const auto r = fake_client(s).set_power(connection(), 25, stopped_core());
        check(r.status == CatResultStatus::rejected && r.error == CatError::power_out_of_range,
              "FieldHead 25 W is rejected instead of clamped");
        check(!any_write_with_prefix(*s, "PC1", 7U), "rejected FieldHead power never reaches the write");
        check(r.observed.power && r.observed.power->value.watts == 10, "rejected power keeps the PC readback observation");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->modes['0'] = '2';  // USB
        const auto r = fake_client(s).set_power(connection(), 30, stopped_core());
        check(r.status == CatResultStatus::rejected && r.error == CatError::power_mode_not_supported &&
                  !any_write_with_prefix(*s, "PC", 7U),
              "power change requires MAIN voice mode");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_mode(connection(), CatSide::main, CatMode::c4fm_dn, stopped_core());
        check(r.status == CatResultStatus::confirmed && r.observed.main_mode->value.mode == CatMode::c4fm_dn,
              "mode confirmed by same-side readback");
        check(count_writes(*s, "MD0H;") == 1 && r.prior_mode && r.prior_mode->mode == CatMode::fm, "C4FM-DN written once");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->radio_id = "1234";
        const auto r = fake_client(s).set_mode(connection(), CatSide::main, CatMode::fm_n, stopped_core());
        check(r.status == CatResultStatus::identity_mismatch && s->writes.size() == 1U, "wrong ID stops before other commands");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->tx = 2;
        const auto r = fake_client(s).set_power(connection(), 30, stopped_core());
        check(r.status == CatResultStatus::busy && !any_write_with_prefix(*s, "PC", 7U), "TX2 blocks setting changes");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->ai = true;
        const auto r = fake_client(s).set_mode(connection(), CatSide::main, CatMode::fm_n, stopped_core());
        check(r.status == CatResultStatus::confirmed && r.observed.auto_information->value, "AI reported but not blocking");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->async_before_md0 = "MD1H;";
        const auto r = fake_client(s).set_mode(connection(), CatSide::main, CatMode::c4fm_dn, stopped_core());
        check(r.status == CatResultStatus::confirmed && r.observed.main_mode->value.mode == CatMode::c4fm_dn,
              "async other-side MD frame is skipped");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_main_frequency(connection(), 145500000U, stopped_core());
        check(r.status == CatResultStatus::confirmed && r.observed.main_frequency_hz->value == 145500000U &&
                  count_writes(*s, "FA145500000;") == 1,
              "MAIN FA confirmed after exact readback, written once");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->reject_frequency_write = true;
        const auto r = fake_client(s).set_main_frequency(connection(), 145500000U, stopped_core());
        check(r.status == CatResultStatus::mismatch && r.observed.main_frequency_hz->value == 14250000U &&
                  count_writes(*s, "FA145500000;") == 1,
              "frequency mismatch is reported without retrying the write");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_main_frequency(connection(), 29999U, stopped_core());
        check(r.status == CatResultStatus::rejected && !s->opened, "out-of-range FA rejected before open");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 51, stopped_core());
        check(r.status == CatResultStatus::rejected && !s->opened, "out-of-range power rejected before open");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->close_fails = true;
        const auto r = fake_client(s).query_all(connection());
        check(r.status == CatResultStatus::unknown && r.cleanup == CatCleanup::close_failed &&
                  r.error == CatError::serial_close_failed && r.observed.power,
              "close failure prevents confirmed while preserving readback");
        check(!r.capabilities.set_frequency_available && !r.capabilities.set_mode_available &&
                  !r.capabilities.set_power_available && !cat_query_grants_write_permit(r),
              "close failure clears every write capability");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).query_all(connection(L"COM11", L"\\\\.\\COM011"));
        check(r.status == CatResultStatus::rejected && r.error == CatError::hri_port_conflict && !s->opened,
              "CAT port aliasing the HRI port is rejected before open");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->no_response_for = "PC;";
        const auto r = fake_client(s).query_all(connection());
        check(r.status == CatResultStatus::unknown && r.error == CatError::timeout, "no data before deadline stays unknown");
        check(!r.capabilities.query_available && !r.capabilities.set_power_available, "timeout leaves no write permit");
        check(s->closed && r.cleanup == CatCleanup::closed, "timeout still closes the session");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).query_all(connection());
        for (const auto& w : s->writes) {
            check(!starts_with(w, "TX0") && !starts_with(w, "TX1") && !starts_with(w, "EX") && !starts_with(w, "MX") &&
                      !starts_with(w, "PS") && !starts_with(w, "AC"),
                  "no PTT/EX/MOX/power-switch/tuner command is sent");
        }
        (void)r;
    }
}

void test_client_gates()
{
    const CatCoreStateProvider resident_idle = []() { return CatCoreState{false, false}; };
    const CatCoreStateProvider transmitting = []() { return CatCoreState{true, false}; };
    const CatCoreStateProvider hri_downlink = []() { return CatCoreState{false, true}; };
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_main_frequency(connection(), 145500000U, resident_idle);
        check(r.status == CatResultStatus::confirmed,
              "frequency allowed while the resident engine is idle (" + std::string(to_string(r.error)) + ")");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_mode(connection(), CatSide::main, CatMode::c4fm_dn, resident_idle);
        check(r.status == CatResultStatus::confirmed, "mode allowed while the resident engine is idle");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_main_frequency(connection(), 145500000U, hri_downlink);
        check(r.status == CatResultStatus::busy && r.error == CatError::gate_hri_downlink && !s->opened,
              "HRI downlink blocks frequency before the port is opened");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 30, hri_downlink);
        check(r.status == CatResultStatus::confirmed, "power is allowed during an HRI downlink call");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 30, transmitting);
        check(r.error == CatError::gate_transmitting && r.status == CatResultStatus::busy && !s->opened,
              "engine transmit blocks power before open");
    }
    {
        // 会话中途开始发射：写帧前的第二次门控阻止写入。
        auto s = std::make_shared<FakeState>();
        auto busy = std::make_shared<bool>(false);
        s->on_write = [busy](const std::string& frame) { if (frame == "PC;") *busy = true; };
        const CatCoreStateProvider core = [busy]() { return CatCoreState{*busy, false}; };
        const auto r = fake_client(s).set_power(connection(), 30, core);
        check(r.error == CatError::gate_transmitting && !any_write_with_prefix(*s, "PC", 7U) && s->closed,
              "transmit starting mid-session blocks the power write");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).set_power(connection(), 30, CatCoreStateProvider{});
        check(r.error == CatError::invalid_request && !s->opened, "writes require a core-state provider");
    }
    {
        auto s = std::make_shared<FakeState>();
        std::atomic<bool> cancel{true};
        const auto r = fake_client(s).query_all(connection(), &cancel);
        check(r.error == CatError::cancelled && r.status == CatResultStatus::unknown && !s->opened,
              "pre-cancelled operation never opens the port");
    }
    {
        auto s = std::make_shared<FakeState>();
        std::atomic<bool> cancel{false};
        s->on_write = [&cancel](const std::string& frame) { if (frame == "TX;") cancel.store(true); };
        const auto r = fake_client(s).set_power(connection(), 30, stopped_core(), &cancel);
        check(r.error == CatError::cancelled && !any_write_with_prefix(*s, "PC", 7U) && s->closed,
              "cancel mid-session stops before any write and closes the port");
    }
}

// ---------- Worker ----------

void test_worker()
{
    auto s = std::make_shared<FakeState>();
    CatWorker worker(fake_client(s), stopped_core());

    CatJob query;
    query.operation = CatOperation::query;
    query.connection = connection();
    std::atomic<int> callbacks{0};
    const auto qr = worker.submit(query, [&callbacks](const CatResult&) { ++callbacks; }).get();
    check(qr.status == CatResultStatus::confirmed && callbacks.load() == 1, "worker runs query and invokes callback");
    auto snap = worker.snapshot();
    check(snap.write_authorized && snap.observed.power && snap.observed.power->value.watts == 25,
          "confirmed query grants write permit and records observation");

    CatJob power = query;
    power.operation = CatOperation::set_power;
    power.power_watts = 30;
    const auto pr = worker.submit(power).get();
    check(pr.status == CatResultStatus::confirmed && worker.snapshot().observed.power->value.watts == 30,
          "worker applies power with a fresh permit");

    worker.disconnect();
    snap = worker.snapshot();
    check(!snap.write_authorized && !snap.capabilities && snap.observed.power && snap.observed.power->value.watts == 30 &&
              snap.generation == 1U,
          "disconnect revokes write permit but keeps last observation");

    // 断开后再写：先自动 query（冻结目标），通过后才写。
    s->writes.clear();
    power.power_watts = 35;
    const auto pr2 = worker.submit(power).get();
    check(pr2.status == CatResultStatus::confirmed && s->writes.front() == "ID;" && count_writes(*s, "PC2035;") == 1,
          "write without a fresh permit performs an authorizing query first");

    // 授权 query 失败（TX2）则不写。
    worker.disconnect();
    s->writes.clear();
    s->tx = 2;
    power.power_watts = 40;
    const auto pr3 = worker.submit(power).get();
    check(pr3.status != CatResultStatus::confirmed && !any_write_with_prefix(*s, "PC", 7U) &&
              !worker.snapshot().write_authorized,
          "failed authorizing query never leads to a write");
    s->tx = 0;

    // identity mismatch 清空观测值。
    s->radio_id = "9999";
    const auto ir = worker.submit(query).get();
    check(ir.status == CatResultStatus::identity_mismatch && !worker.snapshot().observed.power,
          "identity mismatch drops observations");
}

void test_worker_disconnect_drops_queue()
{
    auto s = std::make_shared<FakeState>();
    std::promise<void> gate;
    auto gate_future = gate.get_future().share();
    std::atomic<bool> entered{false};
    s->on_write = [&](const std::string& frame) {
        if (frame == "ID;" && !entered.exchange(true)) gate_future.wait();
    };
    auto worker = std::make_unique<CatWorker>(fake_client(s), stopped_core());
    CatJob query;
    query.connection = connection();
    auto first = worker->submit(query);
    while (!entered.load()) std::this_thread::yield();
    auto second = worker->submit(query);
    worker->disconnect();
    gate.set_value();
    const auto r1 = first.get();
    const auto r2 = second.get();
    check(r2.error == CatError::cancelled, "queued job is cancelled by disconnect");
    check(r1.error == CatError::cancelled, "in-flight job observes cancellation");
    check(!worker->snapshot().write_authorized, "no permit after disconnect");
    worker.reset();
}

} // namespace

// R130：FM 中继静噪快速采样只发 RI0;/SM0;，SM0 失败不影响 RI。
void test_squelch_sample()
{
    struct SmCase { const char* frame; std::optional<unsigned> value; };
    const SmCase sm_cases[] = {
        {"SM0134;", 134U}, {"SM0000;", 0U}, {"SM0255;", 255U}, {"SM0256;", std::nullopt},
        {"SM1134;", std::nullopt}, {"SM013;", std::nullopt}, {"?;", std::nullopt}, {"SM01a4;", std::nullopt},
    };
    for (const auto& c : sm_cases) {
        check(cat_parse_s_meter(c.frame) == c.value, std::string("S meter parse ") + c.frame);
    }
    {
        auto s = std::make_shared<FakeState>();
        s->ri_answer = "RI00000001;";
        s->sm_answer = "SM0134;";
        const auto r = fake_client(s).query_squelch(connection());
        check(r.error == CatError::none && r.ri_frame == "RI00000001;" && r.s_meter == 134U,
              "squelch sample returns RI frame and S meter");
        const std::vector<std::string> expected{"RI0;", "SM0;"};
        check(s->writes == expected, "squelch sample sends only RI0; and SM0;");
        check(s->closed && r.cleanup == CatCleanup::closed, "squelch sample closes its short session");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->sm_answer = "?;";
        const auto r = fake_client(s).query_squelch(connection());
        check(r.error == CatError::none && r.ri_frame == "RI00000000;" && !r.s_meter,
              "SM0 rejection leaves s_meter empty but keeps the RI sample");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->sm_answer.clear();
        auto c = connection();
        c.timeout = 150ms;
        const auto r = fake_client(s).query_squelch(c);
        check(r.error == CatError::none && !r.s_meter, "SM0 silence does not fail the RI sample");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->ri_answer.clear();
        auto c = connection();
        c.timeout = 150ms;
        const auto r = fake_client(s).query_squelch(c);
        check(r.error == CatError::timeout && r.ri_frame.empty() && s->closed,
              "missing RI0 answer is a timeout and still closes the port");
        check(count_writes(*s, "SM0;") == 0, "SM0 is not sent after RI0 fails");
    }
    {
        auto s = std::make_shared<FakeState>();
        s->ri_answer = "RI00000003;";
        const auto r = fake_client(s).query_squelch(connection());
        check(r.error == CatError::unexpected_response, "out-of-range RI0 answer is rejected");
    }
    {
        auto s = std::make_shared<FakeState>();
        const auto r = fake_client(s).query_squelch(connection(L"COM5", L"COM5"));
        check(r.error == CatError::hri_port_conflict && !s->opened, "squelch sample refuses the HRI port");
    }
}

int main()
{
    test_squelch_sample();
    test_parse_table();
    test_command_builders();
    test_gates();
    test_client_against_fake();
    test_traced_transport_records_frames();
    test_client_gates();
    test_worker();
    test_worker_disconnect_drops_queue();
    std::cout << "PASS: " << assertions << " CAT assertions (no physical serial ports opened)\n";
    return EXIT_SUCCESS;
}
