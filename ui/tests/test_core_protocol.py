"""离线协议与生命周期测试；不启动 Qt、设备或核心进程。"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

UI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(UI_DIR))

from core_protocol import CoreProtocolAdapter, ProtocolError  # noqa: E402


def snapshot(seq: int = 1, run_id: str = "native-run-1", **overrides):
    event = {
        "protocol_version": 1,
        "type": "snapshot",
        "run_id": run_id,
        "seq": seq,
        "request_id": None,
        "status": "running",
        "phase": "starting",
        "hri": {"phase": "not_started", "y_zero_acknowledged": False},
        "audio": {
            "radio_input": "not_started",
            "pc_output": "not_started",
            "mic_capture": "idle",
            "candidate_output": "not_started",
        },
        "downlink": {"phase": "idle", "operation_result": "not_started", "radio_state": "unknown"},
        "pc_cleanup": {
            "radio_input": "not_started",
            "pc_output": "not_started",
            "candidate_output": "not_started",
            "serial_handle": "not_opened",
        },
    }
    event.update(overrides)
    return event


def event(message_type: str, seq: int, request_id: str | None, status: str, phase: str, **fields):
    result = {
        "protocol_version": 1,
        "type": message_type,
        "run_id": "native-run-1",
        "seq": seq,
        "request_id": request_id,
        "status": status,
        "phase": phase,
    }
    result.update(fields)
    return result


class CoreProtocolAdapterTests(unittest.TestCase):
    def test_first_snapshot_binds_run_and_preserves_device_fields_verbatim(self):
        adapter = CoreProtocolAdapter()
        raw = json.dumps(snapshot()) + "\n"

        accepted = adapter.consume(raw)

        self.assertEqual(adapter.run_id, "native-run-1")
        self.assertEqual(adapter.last_seq, 1)
        self.assertFalse(adapter.stale)
        self.assertEqual(accepted["hri"]["phase"], "not_started")
        self.assertEqual(adapter.snapshot["audio"]["mic_capture"], "idle")
        self.assertEqual(adapter.snapshot["downlink"]["radio_state"], "unknown")
        self.assertEqual(adapter.session_status, "running")
        self.assertEqual(adapter.session_phase, "starting")

    def test_ui_command_is_ascii_and_matches_native_four_field_line(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())

        line = adapter.prepare_command("request_1-a", "capture_mic")

        self.assertEqual(line, b"1 native-run-1 request_1-a capture_mic\n")
        self.assertLessEqual(len(line), 256)
        self.assertIn("request_1-a", adapter.pending_requests)

    def test_accepted_and_operation_phase_do_not_complete_a_request(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("mic-1", "capture_mic")

        adapter.consume(event("request_result", 2, "mic-1", "accepted", "capturing"))
        accepted = adapter.pending_requests["mic-1"]
        self.assertTrue(accepted.accepted)
        self.assertFalse(accepted.terminal)

        adapter.consume(event("operation_event", 3, "mic-1", "running", "capturing", captured_bytes=120))
        capturing = adapter.pending_requests["mic-1"]
        self.assertFalse(capturing.terminal)
        self.assertEqual(capturing.last_event["captured_bytes"], 120)

        adapter.consume(event("operation_result", 4, "mic-1", "completed", "listening", captured_bytes=960))
        result = adapter.terminal_requests["mic-1"]
        self.assertEqual(result.status, "completed")
        self.assertTrue(result.terminal)
        self.assertNotEqual(adapter.session_status, "completed")

    def test_old_run_and_duplicate_or_reversed_sequence_are_discarded(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("fixed-1", "send_fixed")
        adapter.consume(event("request_result", 2, "fixed-1", "accepted", "downlink"))

        old_run = event("operation_event", 99, "fixed-1", "running", "downlink")
        old_run["run_id"] = "previous-run"
        self.assertIsNone(adapter.consume(old_run))
        self.assertIsNone(adapter.consume(event("operation_event", 2, "fixed-1", "running", "downlink")))
        self.assertEqual(adapter.last_seq, 2)
        self.assertEqual(adapter.pending_requests["fixed-1"].phase, "downlink")
        self.assertFalse(adapter.stale)

    def test_operation_result_must_belong_to_an_accepted_ui_request(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())

        with self.assertRaises(ProtocolError):
            adapter.consume(event("operation_result", 2, "foreign", "completed", "listening"))

        adapter.prepare_command("mic-1", "capture_mic")
        with self.assertRaises(ProtocolError):
            adapter.consume(event("operation_result", 2, "mic-1", "completed", "listening"))
        self.assertEqual(adapter.last_seq, 1)

    def test_busy_or_rejected_request_is_terminal_without_affecting_other_requests(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("capture-1", "capture_mic")
        adapter.prepare_command("fixed-1", "send_fixed")
        adapter.consume(event("request_result", 2, "capture-1", "accepted", "capturing"))
        adapter.consume(event("request_result", 3, "fixed-1", "busy", "capturing"))

        self.assertIn("capture-1", adapter.pending_requests)
        self.assertEqual(adapter.terminal_requests["fixed-1"].status, "busy")
        with self.assertRaises(ProtocolError):
            adapter.consume(event("operation_result", 4, "fixed-1", "completed", "listening"))

    def test_shutdown_result_does_not_substitute_for_process_exit(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("stop-1", "shutdown")
        adapter.consume(event("request_result", 2, "stop-1", "accepted", "stopping"))
        adapter.consume(event("session_result", 3, "stop-1", "completed", "stopped"))

        self.assertEqual(adapter.shutdown_result["status"], "completed")
        self.assertFalse(adapter.process_exited)
        self.assertFalse(adapter.stale)

        adapter.mark_process_exited()
        self.assertTrue(adapter.process_exited)
        self.assertTrue(adapter.stale)

    def test_unrequested_final_result_ends_session_without_completing_a_request(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())

        adapter.consume(event("session_result", 2, None, "timed_out", "stopped"))

        self.assertTrue(adapter.session_terminal)
        self.assertEqual(adapter.shutdown_result["status"], "timed_out")
        self.assertEqual(adapter.requests, {})
        self.assertFalse(adapter.process_exited)
        self.assertFalse(adapter.stale)
        with self.assertRaises(ProtocolError):
            adapter.prepare_command("late-1", "send_fixed")

        adapter.mark_process_exited()
        self.assertTrue(adapter.stale)

    def test_deadline_final_can_race_a_shutdown_line_before_native_accepts_it(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("stop-1", "shutdown")
        self.assertFalse(adapter.pending_requests["stop-1"].accepted)

        adapter.consume(event("session_result", 2, None, "timed_out", "stopped"))

        self.assertTrue(adapter.session_terminal)
        self.assertEqual(adapter.shutdown_result["status"], "timed_out")
        self.assertFalse(adapter.requests["stop-1"].accepted)
        self.assertEqual(adapter.requests["stop-1"].status, "sent")

    def test_unaccepted_shutdown_then_stdout_eof_keeps_device_snapshot_stale(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("stop-1", "shutdown")
        adapter.consume(event("session_result", 2, None, "failed", "stopped"))
        adapter.mark_eof()

        self.assertTrue(adapter.session_terminal)
        self.assertTrue(adapter.stale)
        self.assertFalse(adapter.requests["stop-1"].accepted)
        self.assertIsNone(adapter.requests["stop-1"].last_event)

    def test_eof_marks_last_snapshot_stale_and_closes_command_input(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        saved_snapshot = adapter.snapshot

        adapter.mark_eof()

        self.assertTrue(adapter.stale)
        self.assertTrue(adapter.eof)
        self.assertEqual(adapter.snapshot, saved_snapshot)
        self.assertEqual(adapter.requests, {})
        self.assertFalse(adapter.process_exited)
        with self.assertRaises(ProtocolError):
            adapter.prepare_command("fixed-1", "send_fixed")
        with self.assertRaises(ProtocolError):
            adapter.consume(event("operation_event", 2, "fixed-1", "running", "downlink"))

    def test_protocol_version_run_id_sequence_and_first_snapshot_are_strict(self):
        adapter = CoreProtocolAdapter()
        with self.assertRaises(ProtocolError):
            adapter.consume(event("request_result", 1, "req-1", "accepted", "starting"))

        bad_version = snapshot()
        bad_version["protocol_version"] = True
        with self.assertRaises(ProtocolError):
            CoreProtocolAdapter().consume(bad_version)

        bad_id = snapshot()
        bad_id["run_id"] = "contains space"
        with self.assertRaises(ProtocolError):
            CoreProtocolAdapter().consume(bad_id)

        bad_seq = snapshot()
        bad_seq["seq"] = True
        with self.assertRaises(ProtocolError):
            CoreProtocolAdapter().consume(bad_seq)

    def test_duplicate_json_keys_are_rejected_and_new_phases_are_preserved(self):
        adapter = CoreProtocolAdapter()
        with self.assertRaises(ProtocolError):
            adapter.consume('{"protocol_version":1,"protocol_version":1}')

        bad_phase = snapshot()
        bad_phase["phase"] = ""
        with self.assertRaises(ProtocolError):
            CoreProtocolAdapter().consume(bad_phase)

        future_phase = snapshot(phase="capture_input_audio")
        adapter = CoreProtocolAdapter()
        adapter.consume(future_phase)
        self.assertEqual(adapter.session_phase, "capture_input_audio")

    def test_repeated_stop_and_request_id_reuse_are_rejected(self):
        adapter = CoreProtocolAdapter()
        adapter.consume(snapshot())
        adapter.prepare_command("stop-1", "shutdown")
        with self.assertRaises(ProtocolError):
            adapter.prepare_command("stop-2", "shutdown")
        with self.assertRaises(ProtocolError):
            adapter.prepare_command("stop-1", "cancel_operation")


if __name__ == "__main__":
    unittest.main()
