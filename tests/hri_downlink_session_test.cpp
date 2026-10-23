#include "wirex/direct_frame.hpp"
#include "wirex/hri_downlink_session.hpp"

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

using wirex::direct_frame::Record;
using wirex::hri_downlink_session::ActionKind;
using wirex::hri_downlink_session::CandidateFrame;
using wirex::hri_downlink_session::EventError;
using wirex::hri_downlink_session::Phase;
using wirex::hri_downlink_session::Session;
using wirex::hri_downlink_session::Status;
using wirex::hri_downlink_session::StopReason;

int failures = 0;

void check(bool condition, const std::string& message)
{
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

CandidateFrame make_t_frame(std::uint8_t marker)
{
    const auto encoded = wirex::direct_frame::encode(Record{'T', {marker}});
    check(static_cast<bool>(encoded), "合成 T 帧应能编码");
    return encoded.bytes;
}

Session make_session()
{
    return Session(make_t_frame('S'), make_t_frame('E'));
}

void begin_successful_start_write(Session& session)
{
    const auto started = session.start(0);
    check(started.actions.size() == 1 && started.actions[0].kind == ActionKind::write_start_candidate &&
        started.actions[0].write_id == 1,
        "start() 应只给出一个候选写动作");
    if (!started.actions.empty()) {
        check(started.actions[0].frame == make_t_frame('S'), "start 候选帧应原样保留");
    }
    const auto attempted = session.write_attempted(1, 1);
    check(attempted.state.start_write_attempted && !attempted.state.start_write_completed,
        "写入尝试与写入调用结束必须分开记录");
    const auto completed = session.write_completed(1, true, 2);
    check(completed.state.start_write_completed && completed.state.start_write_succeeded &&
        completed.state.phase == Phase::awaiting_start_record,
        "完整起始帧写入后才进入 T 记录等待阶段");
}

wirex::hri_downlink_session::Update feed_t(Session& session, std::uint64_t now_ms, std::uint8_t marker = 'R')
{
    const auto frame = make_t_frame(marker);
    return session.feed(frame.data(), frame.size(), now_ms);
}

void test_successful_bounded_flow_and_cleanup_gate()
{
    Session session = make_session();
    begin_successful_start_write(session);

    const auto start_t = feed_t(session, 10, 'A');
    check(start_t.state.start_matching_t_record_observed && start_t.state.pcm_permitted &&
        start_t.state.phase == Phase::pcm_ready && start_t.actions.size() == 1 &&
        start_t.actions[0].kind == ActionKind::allow_pcm,
        "完整校验的 T 记录应在起始写完成后开放 PCM 动作");
    check(start_t.state.start_matching_t_payload_bytes == 1,
        "匹配的起始 T 记录只保存正文长度，不保存正文内容");
    check(start_t.state.radio_state_unknown, "收到匹配 T 记录仍不得推断 radio 状态");

    const auto pcm_started = session.pcm_started(11);
    check(pcm_started.state.pcm_started && pcm_started.state.phase == Phase::pcm_active,
        "调用方实际启动 PCM 后才记录 pcm_started");
    const auto pcm_done = session.pcm_completed(true, 12);
    check(pcm_done.actions.size() == 1 && pcm_done.actions[0].kind == ActionKind::write_stop_candidate &&
        pcm_done.actions[0].write_id == 2,
        "PCM 完成后应只安排一次停止候选写入");

    const auto old_t = feed_t(session, 13, 'O');
    check(old_t.state.unmatched_t_records == 1 && !old_t.state.stop_matching_t_record_observed,
        "停止帧写完前收到的旧 T 记录不得算作停止应答");
    check(session.write_attempted(1, 14).error == EventError::duplicate_write_attempt,
        "旧的起始写入 ID 不得推进停止写入阶段");
    check(session.write_completed(2, true, 14).error == EventError::write_not_attempted,
        "停止写入完成事件必须先有对应写入尝试");

    const auto stop_attempted = session.write_attempted(2, 15);
    check(stop_attempted.state.stop_write_attempted && !stop_attempted.state.stop_write_completed,
        "停止写入尝试与结束结果应分别记录");
    const auto stop_written = session.write_completed(2, true, 16);
    check(stop_written.state.stop_write_completed && stop_written.state.stop_write_succeeded &&
        stop_written.state.phase == Phase::awaiting_stop_record,
        "停止候选完整写入后才开始等待新的 T 记录");
    const auto stop_t = feed_t(session, 17, 'B');
    check(stop_t.state.stop_matching_t_record_observed && stop_t.state.phase == Phase::cleanup_pending &&
        stop_t.actions.size() == 1 && stop_t.actions[0].kind == ActionKind::cleanup_required,
        "停止写完成后的校验 T 记录应只安排主线程清理");
    check(stop_t.state.stop_matching_t_payload_bytes == 1,
        "匹配的停止 T 记录只保存正文长度，不保存正文内容");
    check(!stop_t.state.final && stop_t.state.status == Status::running,
        "调用方回报本机资源已清理前不得写最终完成状态");

    const auto final = session.cleanup_completed(true, true, 18);
    check(final.state.final && final.state.status == Status::completed &&
        final.state.radio_state_unknown && final.state.stop_reason == StopReason::none,
        "本机资源清理成功后才可结束软件流程，radio 状态仍未知");
    check(session.cleanup_completed(true, true, 19).error == EventError::cleanup_already_reported,
        "重复清理结果必须被拒绝");
}

void test_cancel_before_start_attempt_and_candidate_validation()
{
    Session cancelled(make_t_frame('S'), make_t_frame('E'));
    const auto started = cancelled.start(0);
    check(started.actions.size() == 1, "取消用例应先得到尚未尝试的起始候选");
    const auto cancel = cancelled.cancel(1);
    check(cancel.state.phase == Phase::cleanup_pending && !cancel.state.start_write_attempted &&
        !cancel.state.stop_write_attempted && cancel.state.stop_reason == StopReason::cancelled_before_start_attempt,
        "起始写入尚未尝试时取消不得安排停止写入");
    check(cancel.actions.size() == 1 && cancel.actions[0].kind == ActionKind::cleanup_required,
        "未开始的取消应转交本机资源清理");
    check(cancelled.write_attempted(1, 2).error == EventError::invalid_phase,
        "取消后过期的起始候选不得再被执行");
    const auto final = cancelled.cleanup_completed(true, true, 3);
    check(final.state.status == Status::cancelled && final.state.final &&
        !final.state.start_write_attempted && !final.state.stop_write_attempted,
        "未尝试起始写入的取消可在清理后终结且不发停止帧");

    Session invalid(make_t_frame('S'), CandidateFrame{0x01, 'X'});
    const auto rejected = invalid.start(0);
    check(rejected.actions.size() == 1 && rejected.actions[0].kind == ActionKind::cleanup_required &&
        rejected.state.stop_reason == StopReason::invalid_candidate_frame &&
        !rejected.state.start_write_attempted,
        "非完整校验 T 候选必须在任何写入前拒绝");
}

void test_partial_write_always_schedules_one_stop()
{
    Session session = make_session();
    const auto start = session.start(0);
    (void)start;
    (void)session.write_attempted(1, 1);
    const auto partial = session.write_completed(1, false, 2);
    check(partial.state.start_write_attempted && partial.state.start_write_completed &&
        !partial.state.start_write_succeeded && partial.state.stop_reason == StopReason::start_write_failed &&
        partial.actions.size() == 1 && partial.actions[0].kind == ActionKind::write_stop_candidate,
        "起始帧写入结果不完整时仍要安排唯一一次停止尝试");
    check(session.write_completed(1, false, 3).error == EventError::duplicate_write_completion,
        "重复的迟到起始写完成 ID 不得推进状态");
    (void)session.write_attempted(2, 4);
    (void)session.write_completed(2, true, 5);
    const auto response = feed_t(session, 6);
    check(response.state.stop_matching_t_record_observed && response.state.phase == Phase::cleanup_pending,
        "不确定的起始写入之后仍可观察停止 T，但不得改写此前失败");
    const auto final = session.cleanup_completed(true, true, 7);
    check(final.state.status == Status::failed && final.state.stop_reason == StopReason::start_write_failed,
        "起始部分写入不能因后续停止观察而报告成功");
}

void test_t_records_require_completed_writes_and_valid_checksum()
{
    Session session = make_session();
    (void)session.start(0);
    (void)session.write_attempted(1, 1);
    auto early = make_t_frame('E');
    const auto before_write_done = session.feed(early.data(), early.size(), 2);
    check(!before_write_done.state.start_matching_t_record_observed &&
        before_write_done.state.unmatched_t_records == 1,
        "起始写入完成前收到的 T 记录不得放行 PCM");
    (void)session.write_completed(1, true, 3);

    auto bad_checksum = make_t_frame('B');
    bad_checksum.back() = bad_checksum.back() == '0' ? '1' : '0';
    const auto malformed = session.feed(bad_checksum.data(), bad_checksum.size(), 4);
    check(malformed.state.malformed_records == 1 && !malformed.state.pcm_permitted,
        "校验和错误的 T 帧不得放行 PCM");
    const auto valid = feed_t(session, 5);
    check(valid.state.pcm_permitted && valid.state.malformed_records == 1,
        "之后的新完整校验 T 记录才可放行 PCM");
}

void test_partial_old_t_cannot_cross_candidate_write_completion()
{
    Session start_side = make_session();
    (void)start_side.start(0);
    (void)start_side.write_attempted(1, 1);
    const auto old_start_t = make_t_frame('O');
    (void)start_side.feed(old_start_t.data(), 5, 2);
    (void)start_side.write_completed(1, true, 3);
    const auto old_start_tail = start_side.feed(old_start_t.data() + 5, old_start_t.size() - 5, 4);
    check(!old_start_tail.state.start_matching_t_record_observed && !old_start_tail.state.pcm_permitted,
        "起始写完成前收到的旧 T 半帧必须丢弃，不能拼成应答");
    const auto fresh_start_t = feed_t(start_side, 5, 'N');
    check(fresh_start_t.state.start_matching_t_record_observed && fresh_start_t.state.pcm_permitted,
        "丢弃旧半帧后新的完整起始 T 记录仍可被识别");

    Session stop_side = make_session();
    begin_successful_start_write(stop_side);
    (void)feed_t(stop_side, 10);
    (void)stop_side.pcm_started(11);
    (void)stop_side.pcm_completed(true, 12);
    (void)stop_side.write_attempted(2, 13);
    const auto old_stop_t = make_t_frame('P');
    (void)stop_side.feed(old_stop_t.data(), 5, 14);
    (void)stop_side.write_completed(2, true, 15);
    const auto old_stop_tail = stop_side.feed(old_stop_t.data() + 5, old_stop_t.size() - 5, 16);
    check(!old_stop_tail.state.stop_matching_t_record_observed,
        "停止写完成前收到的旧 T 半帧必须丢弃，不能拼成停止应答");
    const auto fresh_stop_t = feed_t(stop_side, 17, 'Q');
    check(fresh_stop_t.state.stop_matching_t_record_observed && fresh_stop_t.state.phase == Phase::cleanup_pending,
        "停止写完成后新的完整 T 记录仍可被观察");
}

void test_production_start_and_stop_deadlines()
{
    check(wirex::hri_downlink_session::start_record_timeout_ms == 3000 &&
        wirex::hri_downlink_session::normal_stop_record_timeout_ms == 3000 &&
        wirex::hri_downlink_session::cancelled_stop_record_timeout_ms == 500 &&
        wirex::hri_downlink_session::max_flow_duration_ms == 20000 &&
        wirex::hri_downlink_session::default_pcm_window_ms == 7248,
        "生产默认等待上限应为 3 秒、取消停止 500 毫秒、全流程 20 秒和 7248 毫秒 PCM 窗口");

    Session start_timeout = make_session();
    begin_successful_start_write(start_timeout);
    check(start_timeout.tick(3001).actions.empty(), "起始 T 等待未满 3 秒时不得超时");
    check(start_timeout.tick(3002).actions.size() == 1 &&
        start_timeout.snapshot().phase == Phase::stop_write_pending &&
        start_timeout.snapshot().stop_reason == StopReason::start_record_timeout,
        "起始 T 等待超时后应立即安排停止尝试");
    const auto late_start_t = feed_t(start_timeout, 3003);
    check(!late_start_t.state.start_matching_t_record_observed &&
        late_start_t.state.unmatched_t_records == 1,
        "起始 T 超时后的迟到记录不得恢复 PCM 路径");

    (void)start_timeout.write_attempted(2, 3004);
    (void)start_timeout.write_completed(2, true, 3005);
    check(start_timeout.tick(6004).actions.empty(), "停止 T 等待 3 秒前不得提前终结");
    const auto stop_timeout = start_timeout.tick(6005);
    check(stop_timeout.state.phase == Phase::cleanup_pending &&
        stop_timeout.state.stop_reason == StopReason::start_record_timeout &&
        stop_timeout.actions.size() == 1 && stop_timeout.actions[0].kind == ActionKind::cleanup_required,
        "正常停止等待到达 3 秒时应清理并保留失败状态");
    check(start_timeout.cleanup_completed(true, true, 6006).state.status == Status::failed,
        "缺少停止 T 记录时最终状态必须失败");
}

void test_cancelled_stop_wait_is_bounded_to_500ms()
{
    Session session = make_session();
    begin_successful_start_write(session);
    (void)feed_t(session, 10);
    (void)session.pcm_started(11);
    (void)session.pcm_completed(true, 12);
    (void)session.write_attempted(2, 13);
    (void)session.write_completed(2, true, 14);

    const auto cancelled = session.cancel(100);
    check(cancelled.state.phase == Phase::awaiting_stop_record && cancelled.state.stop_reason == StopReason::cancelled,
        "停止应答等待中的取消应继续等候但标记用户取消");
    check(session.tick(599).state.phase == Phase::awaiting_stop_record,
        "取消停止等待的 500 毫秒窗口未到前仍保持等待");
    const auto expired = session.tick(600);
    check(expired.state.phase == Phase::cleanup_pending && expired.state.status == Status::running &&
        expired.state.stop_reason == StopReason::stop_record_timeout,
        "取消后的 500 毫秒停止等待到期应以失败和未知电台状态进入清理");
    check(session.cleanup_completed(true, true, 601).state.status == Status::failed,
        "未观察到匹配停止 T 的取消流程不得报告完成");
}

void test_cancel_advances_time_before_the_next_tick()
{
    Session session = make_session();
    begin_successful_start_write(session);

    const auto cancelled = session.cancel(101);
    check(cancelled.error == EventError::none && cancelled.actions.size() == 1 &&
        cancelled.actions[0].kind == ActionKind::write_stop_candidate,
        "等待起始 T 记录时取消应立即安排唯一停止候选");
    const auto stale_tick = session.tick(100);
    check(stale_tick.error == EventError::invalid_time &&
        stale_tick.state.phase == Phase::stop_write_pending,
        "取消推进时钟后，不得用缓存的旧时间调用下一次tick");
    const auto fresh_tick = session.tick(102);
    check(fresh_tick.error == EventError::none && fresh_tick.state.phase == Phase::stop_write_pending &&
        fresh_tick.actions.empty(),
        "使用新的单调时钟继续tick应保留已排队的唯一停止候选");
}

void test_pcm_deadline_requests_stop_and_transport_fault_blocks_retry()
{
    Session pcm_timeout = make_session();
    const auto start = pcm_timeout.start(0, 100);
    (void)start;
    (void)pcm_timeout.write_attempted(1, 1);
    (void)pcm_timeout.write_completed(1, true, 2);
    (void)feed_t(pcm_timeout, 3);
    check(pcm_timeout.tick(102).actions.empty(), "PCM 时间窗到期前不要求停止");
    const auto expired = pcm_timeout.tick(103);
    check(expired.state.phase == Phase::pcm_stop_pending && expired.actions.size() == 1 &&
        expired.actions[0].kind == ActionKind::request_pcm_stop &&
        expired.state.stop_reason == StopReason::pcm_window_expired,
        "PCM 调用方时间窗到期后应先通知调用方停音");
    const auto pcm_stopped = pcm_timeout.pcm_completed(false, 104);
    check(pcm_stopped.actions.size() == 1 && pcm_stopped.actions[0].kind == ActionKind::write_stop_candidate,
        "调用方回报 PCM 已停后才安排停止 T 写入");

    Session transport_fault = make_session();
    begin_successful_start_write(transport_fault);
    const auto failed = transport_fault.transport_failed(3);
    check(failed.state.phase == Phase::cleanup_pending &&
        failed.state.stop_reason == StopReason::transport_failed && failed.actions.size() == 1 &&
        failed.actions[0].kind == ActionKind::cleanup_required && !failed.state.stop_write_attempted,
        "串口故障后不得盲目重发停止候选");
    check(transport_fault.cleanup_completed(true, false, 4).state.status == Status::failed,
        "串口清理失败必须保留失败终态");
}

void test_overall_limit_and_cleanup_failure()
{
    wirex::hri_downlink_session::Config short_flow{};
    short_flow.overall_timeout_ms = 4000;
    Session session(make_t_frame('S'), make_t_frame('E'), short_flow);
    (void)session.start(0, 100);
    (void)session.write_attempted(1, 1);
    (void)session.write_completed(1, true, 2);
    const auto start_t = feed_t(session, 1000);
    check(start_t.state.start_matching_t_record_observed && !start_t.state.pcm_permitted &&
        start_t.state.phase == Phase::stop_write_pending && start_t.state.stop_reason == StopReason::overall_timeout,
        "全流程窗口不足以保留停止应答时间时不得启动 PCM");
    (void)session.write_attempted(2, 1001);
    (void)session.write_completed(2, true, 1002);
    check(session.snapshot().phase == Phase::awaiting_stop_record,
        "仍有剩余全流程时间时可继续等待停止 T");
    const auto timed_out = session.tick(4000);
    check(timed_out.state.phase == Phase::cleanup_pending &&
        timed_out.state.stop_reason == StopReason::overall_timeout,
        "20 秒生产全流程上限的可配置短测试应在整体截止时结束等待");
    const auto cleanup_failed = session.cleanup_completed(false, true, 4001);
    check(cleanup_failed.state.status == Status::failed && cleanup_failed.state.final &&
        cleanup_failed.state.stop_reason == StopReason::overall_timeout &&
        !cleanup_failed.state.audio_cleanup_succeeded,
        "本机资源回收失败必须记入 final，且不能覆盖更早的整体超时原因");
}

void test_operation_cleanup_keeps_shared_serial_open_for_next_round()
{
    auto complete_operation = [](std::uint64_t base, bool& serial_cleanup_reported) {
        Session session = make_session();
        (void)session.start(base);
        (void)session.write_attempted(1, base + 1);
        (void)session.write_completed(1, true, base + 2);
        (void)feed_t(session, base + 3, 'A');
        (void)session.pcm_started(base + 4);
        (void)session.pcm_completed(true, base + 5);
        (void)session.write_attempted(2, base + 6);
        (void)session.write_completed(2, true, base + 7);
        (void)feed_t(session, base + 8, 'B');
        const auto cleanup = session.operation_cleanup_completed(true, base + 9);
        serial_cleanup_reported = cleanup.state.serial_cleanup_reported;
        check(cleanup.error == EventError::none && cleanup.state.final &&
            cleanup.state.status == Status::completed && cleanup.state.audio_cleanup_reported &&
            cleanup.state.audio_cleanup_succeeded && !cleanup.state.serial_cleanup_reported,
            "每轮下行PCM资源清理完成后应结束该操作，同时如实保留共享串口打开状态");
        return cleanup.state.final;
    };

    bool first_serial_cleanup = true;
    bool second_serial_cleanup = true;
    check(complete_operation(0, first_serial_cleanup), "第一轮下行应能完成");
    check(complete_operation(100, second_serial_cleanup), "共享会话仍持有串口时第二轮下行也应能完成");
    check(!first_serial_cleanup && !second_serial_cleanup,
        "操作级完成不得伪报会话串口已经关闭");
}

void test_legacy_cleanup_still_requires_serial_close()
{
    Session session = make_session();
    (void)session.start(0);
    (void)session.write_attempted(1, 1);
    (void)session.write_completed(1, true, 2);
    (void)feed_t(session, 3, 'A');
    (void)session.pcm_started(4);
    (void)session.pcm_completed(true, 5);
    (void)session.write_attempted(2, 6);
    (void)session.write_completed(2, true, 7);
    (void)feed_t(session, 8, 'B');

    const auto cleanup = session.cleanup_completed(true, false, 9);
    check(cleanup.error == EventError::none && cleanup.state.final &&
        cleanup.state.status == Status::failed && cleanup.state.audio_cleanup_succeeded &&
        cleanup.state.serial_cleanup_reported && !cleanup.state.serial_cleanup_succeeded,
        "旧会话清理API仍须将串口关闭失败记为failed");
}

} // namespace

int main()
{
    test_successful_bounded_flow_and_cleanup_gate();
    test_cancel_before_start_attempt_and_candidate_validation();
    test_partial_write_always_schedules_one_stop();
    test_t_records_require_completed_writes_and_valid_checksum();
    test_partial_old_t_cannot_cross_candidate_write_completion();
    test_production_start_and_stop_deadlines();
    test_cancelled_stop_wait_is_bounded_to_500ms();
    test_cancel_advances_time_before_the_next_tick();
    test_operation_cleanup_keeps_shared_serial_open_for_next_round();
    test_legacy_cleanup_still_requires_serial_close();
    test_pcm_deadline_requests_stop_and_transport_fault_blocks_retry();
    test_overall_limit_and_cleanup_failure();
    test_operation_cleanup_keeps_shared_serial_open_for_next_round();
    if (failures != 0) {
        std::cerr << failures << " 个有限下行协调器检查失败。\n";
        return 1;
    }
    std::cout << "有限下行协调器离线检查全部通过。\n";
    return 0;
}
