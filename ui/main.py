"""WIREX Bridge 第一版离线桌面 UI。"""
from __future__ import annotations

import argparse
import sys
from typing import Sequence

from state import DashboardSnapshot, demo_snapshot, offline_snapshot


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="WIREX Bridge 离线操作面板")
    parser.add_argument(
        "--demo",
        action="store_true",
        help="显示明确标注的固定演示快照，不连接或读取设备",
    )
    return parser.parse_args(argv)


def run_ui(snapshot: DashboardSnapshot) -> int:
    """在 PySide6 可用时显示原生窗口；缺少 Qt 时给出可读提示后退出。"""
    try:
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import (
            QApplication,
            QComboBox,
            QDialog,
            QFrame,
            QGridLayout,
            QHBoxLayout,
            QLabel,
            QLineEdit,
            QMainWindow,
            QPushButton,
            QSizePolicy,
            QTextEdit,
            QVBoxLayout,
            QWidget,
        )
    except ImportError:
        print(
            "无法启动原生窗口：当前 Python 环境没有 PySide6。"
            "此离线 UI 不会安装依赖；可在已具备 PySide6 的环境中运行。",
            file=sys.stderr,
        )
        return 2

    stylesheet = """
        QWidget { background: #171a1d; color: #e8ecee; font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif; font-size: 13px; }
        QMainWindow { background: #171a1d; }
        QFrame#panel, QFrame#statusTile { background: #20252a; border: 1px solid #3a4248; }
        QFrame#statusTile { border-left: 4px solid #66727a; }
        QFrame#statusTile[tone="amber"] { border-left-color: #dda94c; }
        QFrame#statusTile[tone="blue"] { border-left-color: #6eaed8; }
        QFrame#statusTile[tone="green"] { border-left-color: #66bc8b; }
        QLabel#eyebrow { color: #9ba7ad; font-size: 10px; font-weight: 700; letter-spacing: 1px; }
        QLabel#muted { color: #9da8ad; }
        QLabel#value { color: #f1f4f5; font-size: 17px; font-weight: 700; }
        QLabel#callSign { color: #f1f4f5; font-size: 43px; font-weight: 800; }
        QLabel#demoBanner { background: #543e1d; color: #ffdb8c; border: 1px solid #ae8134; font-weight: 800; padding: 8px 12px; }
        QLabel#pill { background: #2b3338; border: 1px solid #46535b; color: #cbd5d9; font-weight: 700; padding: 5px 9px; }
        QPushButton { background: #30383e; border: 1px solid #566169; border-bottom: 3px solid #3b444a; color: #edf1f3; font-weight: 700; padding: 8px 13px; }
        QPushButton:hover { background: #3a444b; }
        QPushButton:disabled { background: #252a2e; border-color: #394147; color: #737e83; }
        QPushButton#exitButton { background: #68412a; border-color: #9c6843; border-bottom-color: #492f20; color: #fff1e4; }
        QPushButton#exitButton:hover { background: #795033; }
        QComboBox { background: #30383e; border: 1px solid #566169; color: #edf1f3; font-weight: 700; padding: 7px 10px; min-width: 160px; }
        QComboBox:disabled { color: #9da8ad; background: #252a2e; border-color: #394147; }
        QLineEdit { background: #181c1f; border: 1px solid #475159; padding: 7px; color: #e8ecee; }
        QLineEdit:disabled { color: #849096; }
        QTextEdit { background: #181c1f; border: 1px solid #3a4248; color: #bec7cb; padding: 6px; }
        QDialog { background: #1b2024; }
    """

    def eyebrow(text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("eyebrow")
        return label

    def muted(text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("muted")
        return label

    def value_label(text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("value")
        return label

    def make_panel() -> QFrame:
        panel = QFrame()
        panel.setObjectName("panel")
        return panel

    class SettingsDialog(QDialog):
        def __init__(self, parent: QWidget | None = None) -> None:
            super().__init__(parent)
            self.setWindowTitle("设置 · 离线预览")
            self.setMinimumWidth(500)
            layout = QVBoxLayout(self)
            layout.setContentsMargins(22, 20, 22, 18)
            layout.setSpacing(13)
            layout.addWidget(eyebrow("CONFIGURATION OUTLINE"))
            title = QLabel("连接与显示结构")
            title.setStyleSheet("font-size: 22px; font-weight: 800;")
            layout.addWidget(title)
            layout.addWidget(muted("本窗口只展示未来配置项，不读取、保存或应用设置。"))

            rows = (
                ("启动策略", "未来启动时按上次配置尝试连接 · 当前未实现"),
                ("FTX-1 信息", "型号、固件、HRI MODE、Node Mode 与 GM/X 均待核心读取/确认"),
                ("电台与核心", "待核心接口定义设备身份、状态来源和能力"),
                ("WIRES-X 模式", "由核心提供已确认状态；本 UI 不从原始数值推断"),
                ("网络目标", "待定义连接状态、目标 TG 与时隙的来源"),
                ("凭据", "本离线版本不收集或持久化凭据"),
            )
            for heading, detail in rows:
                row = QFrame()
                row.setObjectName("panel")
                row_layout = QVBoxLayout(row)
                row_layout.setContentsMargins(12, 9, 12, 9)
                row_layout.setSpacing(3)
                row_layout.addWidget(eyebrow(heading))
                row_layout.addWidget(muted(detail))
                layout.addWidget(row)

            close_button = QPushButton("关闭")
            close_button.clicked.connect(self.accept)
            layout.addWidget(close_button, alignment=Qt.AlignmentFlag.AlignRight)

    class MainWindow(QMainWindow):
        def __init__(self) -> None:
            super().__init__()
            self.setWindowTitle("WIREX Bridge · Operator Panel")
            self.resize(1160, 760)
            self.setMinimumSize(880, 620)
            self.setStyleSheet(stylesheet)

            central = QWidget()
            self.setCentralWidget(central)
            root = QVBoxLayout(central)
            root.setContentsMargins(20, 15, 20, 14)
            root.setSpacing(10)

            header = QHBoxLayout()
            brand = QVBoxLayout()
            brand.setSpacing(1)
            brand.addWidget(eyebrow("WIREX BRIDGE   /   OPERATOR PANEL"))
            app_title = QLabel("数字语音链路控制台")
            app_title.setStyleSheet("font-size: 22px; font-weight: 800;")
            brand.addWidget(app_title)
            header.addLayout(brand, 1)
            usage_label = muted("用途")
            header.addWidget(usage_label)
            usage_selector = QComboBox()
            usage_selector.addItems(("FTX-1 个人终端", "C4FM RF 节点"))
            usage_selector.setCurrentIndex(0)
            usage_selector.setEnabled(False)
            usage_selector.setToolTip("用途选择等待核心能力；当前离线 UI 不连接，也不表示 RF 节点可用。")
            header.addWidget(usage_selector)
            header.addWidget(muted("等待核心能力"))
            settings_button = QPushButton("设置")
            settings_button.clicked.connect(lambda: SettingsDialog(self).exec())
            header.addWidget(settings_button)
            root.addLayout(header)

            if snapshot.is_demo:
                banner = QLabel("模拟预览：无核心、无电台连接  /  下方状态、通话与记录均为本地固定示例")
                banner.setObjectName("demoBanner")
                root.addWidget(banner)

            status_row = QGridLayout()
            status_row.setHorizontalSpacing(9)
            status_row.setVerticalSpacing(8)
            status_row.addWidget(self._status_tile("CORE / 核心", snapshot.core), 0, 0)
            radio_detail = f"型号：{snapshot.radio_model} · 固件：{snapshot.radio_firmware}"
            radio_modes = (
                f"HRI：{snapshot.hri.value} · HRI MODE：{snapshot.hri_mode}",
                f"CAT：{snapshot.cat.value} · Node Mode：{snapshot.node_mode}",
                f"GM/X：{snapshot.gmx_mode} · WIRES-X：{snapshot.wires_x.value}",
            )
            status_row.addWidget(self._status_tile("RADIO / FTX-1", snapshot.radio, radio_detail, radio_modes), 0, 1)
            status_row.addWidget(self._status_tile("AUDIO / 音频", snapshot.audio), 0, 2)
            status_row.addWidget(self._status_tile("NETWORK / BrandMeister", snapshot.brandmeister), 0, 3)
            for column in range(4):
                status_row.setColumnStretch(column, 1)
            root.addLayout(status_row)

            root.addWidget(self._call_panel(snapshot), 1)
            root.addWidget(self._lower_panel(snapshot))

            footer = QHBoxLayout()
            footer.addWidget(eyebrow("AUTO CONNECT"))
            footer.addWidget(muted("未来启动按上次配置尝试连接 · 当前离线 UI 不会发起连接"), 1)
            exit_button = QPushButton("停止并退出")
            exit_button.setObjectName("exitButton")
            exit_button.setToolTip("关闭本离线 UI；当前没有核心、后台任务或连接需要停止。")
            exit_button.clicked.connect(self.close)
            footer.addWidget(exit_button)
            root.addLayout(footer)

        def _status_tile(self, heading: str, reading, detail_override: str | None = None, secondary: tuple[str, ...] = ()) -> QFrame:
            tile = QFrame()
            tile.setObjectName("statusTile")
            tile.setProperty("tone", reading.tone)
            layout = QVBoxLayout(tile)
            layout.setContentsMargins(11, 8, 10, 8)
            layout.setSpacing(2)
            layout.addWidget(eyebrow(heading))
            layout.addWidget(value_label(reading.value))
            detail = muted(detail_override or reading.detail)
            detail.setWordWrap(True)
            layout.addWidget(detail)
            for line in secondary:
                substatus = muted(line)
                substatus.setWordWrap(True)
                substatus.setStyleSheet("color: #91b6cc; font-weight: 700;")
                layout.addWidget(substatus)
            return tile

        def _call_panel(self, data: DashboardSnapshot) -> QFrame:
            panel = make_panel()
            layout = QVBoxLayout(panel)
            layout.setContentsMargins(17, 13, 17, 14)
            layout.setSpacing(9)
            heading_row = QHBoxLayout()
            heading_row.addWidget(eyebrow("CURRENT CHANNEL / 当前通话"), 1)
            badge = QLabel("演示快照" if data.is_demo else "无通话数据源")
            badge.setObjectName("pill")
            heading_row.addWidget(badge)
            layout.addLayout(heading_row)

            content = QHBoxLayout()
            content.setSpacing(18)
            identity = QVBoxLayout()
            identity.setSpacing(3)
            identity.addWidget(eyebrow("发话呼号 / CALLSIGN"))
            callsign = data.call.callsign if data.call else "—"
            big = QLabel(callsign)
            big.setObjectName("callSign")
            identity.addWidget(big)
            identity.addWidget(muted("DEMO-01 为虚构标识 · 不代表设备或网络连接" if data.is_demo else "核心未就绪，当前没有可读取的通话事件。"))
            content.addLayout(identity, 5)

            details = QGridLayout()
            details.setHorizontalSpacing(13)
            details.setVerticalSpacing(11)
            call = data.call
            cells = (
                ("方向 / DIRECTION", call.direction if call else "—"),
                ("目标 / TALK GROUP", f"TG {call.talkgroup}" if call else "—"),
                ("时隙 / TIMESLOT", f"TS {call.timeslot}" if call else "—"),
                ("持续 / DURATION", call.duration if call else "—"),
            )
            for index, (label_text, value_text) in enumerate(cells):
                cell = QVBoxLayout()
                cell.setSpacing(3)
                cell.addWidget(eyebrow(label_text))
                cell.addWidget(value_label(value_text))
                details.addLayout(cell, index // 2, index % 2)
            content.addLayout(details, 4)
            layout.addLayout(content, 1)
            return panel

        def _lower_panel(self, data: DashboardSnapshot) -> QWidget:
            container = QWidget()
            layout = QHBoxLayout(container)
            layout.setContentsMargins(0, 0, 0, 0)
            layout.setSpacing(10)

            controls = make_panel()
            controls_layout = QVBoxLayout(controls)
            controls_layout.setContentsMargins(15, 12, 15, 12)
            controls_layout.setSpacing(7)
            controls_layout.addWidget(eyebrow("TARGET CONTROL / 目标控制"))
            fields = QGridLayout()
            fields.setHorizontalSpacing(9)
            fields.addWidget(eyebrow("目标 TG"), 0, 0)
            fields.addWidget(eyebrow("时隙 TS"), 0, 1)
            tg = QLineEdit(data.target_talkgroup)
            ts = QLineEdit(data.target_timeslot)
            tg.setPlaceholderText("未知")
            ts.setPlaceholderText("未知")
            tg.setEnabled(False)
            ts.setEnabled(False)
            tg.setToolTip("当前没有核心可读取或应用目标。")
            ts.setToolTip("当前没有核心可读取或应用目标。")
            fields.addWidget(tg, 1, 0)
            fields.addWidget(ts, 1, 1)
            controls_layout.addLayout(fields)
            actions = QHBoxLayout()
            connect_button = QPushButton("重试连接")
            apply_button = QPushButton("应用目标")
            for button in (connect_button, apply_button):
                button.setEnabled(False)
                button.setToolTip("当前尚无可执行核心；未来由启动流程按上次配置尝试连接，当前不可用。")
                actions.addWidget(button)
            controls_layout.addLayout(actions)
            controls_layout.addWidget(muted("控制项已禁用 · 离线 UI 不会尝试连接、写入或发射"))

            log_panel = make_panel()
            log_layout = QVBoxLayout(log_panel)
            log_layout.setContentsMargins(15, 12, 15, 12)
            log_layout.setSpacing(7)
            log_layout.addWidget(eyebrow("RUN LOG / 运行记录"))
            log = QTextEdit()
            log.setReadOnly(True)
            log.setMinimumHeight(86)
            log.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
            if data.is_demo:
                log.setPlainText("\n".join(f"·  {line}" for line in data.runtime_lines))
            else:
                log.setPlainText("尚无核心事件或运行记录。")
            log_layout.addWidget(log, 1)
            layout.addWidget(controls, 1)
            layout.addWidget(log_panel, 1)
            return container

    app = QApplication.instance() or QApplication(sys.argv[:1])
    app.setApplicationName("WIREX Bridge")
    window = MainWindow()
    window.show()
    return app.exec()


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv)
    snapshot = demo_snapshot() if args.demo else offline_snapshot()
    return run_ui(snapshot)


if __name__ == "__main__":
    raise SystemExit(main())