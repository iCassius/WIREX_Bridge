"""离线状态与演示隔离验证；不导入 Qt，也不接触设备或网络。"""
import sys
import unittest
from pathlib import Path

UI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(UI_DIR))

from main import parse_arguments
from state import demo_snapshot, offline_snapshot


class UiSnapshotTests(unittest.TestCase):
    def test_demo_requires_an_explicit_command_line_flag(self):
        self.assertFalse(parse_arguments([]).demo)
        self.assertTrue(parse_arguments(["--demo"]).demo)

    def test_offline_view_has_unavailable_core_and_unknown_components(self):
        state = offline_snapshot()
        self.assertFalse(state.is_demo)
        self.assertIsNone(state.call)
        self.assertIn("核心未就绪（尚无可执行核心）", state.core.detail)
        self.assertEqual(state.radio.value, "未知")
        self.assertEqual(state.hri.value, "未知")
        self.assertEqual(state.cat.value, "未知")
        self.assertEqual(state.wires_x.value, "未知")
        self.assertEqual(state.audio.value, "未知")
        self.assertEqual(state.brandmeister.value, "未知")
        self.assertEqual((state.target_talkgroup, state.target_timeslot), ("", ""))
        self.assertEqual(state.radio_firmware, "待核心确认")
        self.assertEqual(state.node_mode, "待核心确认")

    def test_demo_is_separate_and_never_claims_a_real_connection(self):
        state = demo_snapshot()
        self.assertTrue(state.is_demo)
        self.assertIsNotNone(state.call)
        self.assertEqual(state.call.callsign, "DEMO-01")
        self.assertEqual(state.core.value, "无核心")
        self.assertEqual(state.radio.value, "未连接")
        self.assertEqual(state.hri.value, "模拟状态")
        self.assertEqual(state.cat.value, "模拟状态")
        self.assertEqual(state.brandmeister.value, "未连接")
        self.assertIn("示例", state.node_mode)
        self.assertTrue(all("模拟" in line or "演示" in line for line in state.runtime_lines))


if __name__ == "__main__":
    unittest.main()