"""离线 UI 展示状态；只构造屏幕内容，不连接设备或保存配置。"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


Tone = Literal["muted", "amber", "blue", "green"]


@dataclass(frozen=True)
class StatusReading:
    """一个独立服务/设备的可见状态与简短说明。"""

    value: str
    detail: str
    tone: Tone = "muted"


@dataclass(frozen=True)
class CallReading:
    callsign: str
    direction: str
    talkgroup: str
    timeslot: str
    duration: str


@dataclass(frozen=True)
class DashboardSnapshot:
    """UI 当前要展示的不可变快照；演示数据只能由显式开关选择。"""

    is_demo: bool
    core: StatusReading
    radio: StatusReading
    hri: StatusReading
    cat: StatusReading
    radio_model: str
    radio_firmware: str
    hri_mode: str
    node_mode: str
    gmx_mode: str
    wires_x: StatusReading
    audio: StatusReading
    brandmeister: StatusReading
    call: CallReading | None
    target_talkgroup: str
    target_timeslot: str
    runtime_lines: tuple[str, ...]


def offline_snapshot() -> DashboardSnapshot:
    """返回离线默认画面，不声称连接或读取过任何设备状态。"""
    return DashboardSnapshot(
        is_demo=False,
        core=StatusReading("不可用", "核心未就绪（尚无可执行核心）", "amber"),
        radio=StatusReading("未知", "电台状态待核心确认"),
        hri=StatusReading("未知", "待当前核心快照"),
        cat=StatusReading("未知", "待当前核心快照"),
        radio_model="FTX-1",
        radio_firmware="待核心确认",
        hri_mode="待核心确认",
        node_mode="待核心确认",
        gmx_mode="待核心确认",
        wires_x=StatusReading("未知", "待核心确认 HRI 与 WIRES-X 状态"),
        audio=StatusReading("未知", "尚无音频端点读取来源"),
        brandmeister=StatusReading("未知", "待核心提供连接状态"),
        call=None,
        target_talkgroup="",
        target_timeslot="",
        runtime_lines=("尚无运行记录来源。",),
    )


def demo_snapshot() -> DashboardSnapshot:
    """返回显式演示用固定夹具；这些内容不是设备或网络观测。"""
    return DashboardSnapshot(
        is_demo=True,
        core=StatusReading("无核心", "模拟预览不启动核心进程"),
        radio=StatusReading("未连接", "本地示例字段，不读取电台"),
        hri=StatusReading("模拟状态", "本地示例"),
        cat=StatusReading("模拟状态", "本地示例"),
        radio_model="FTX-1（示例）",
        radio_firmware="示例标记（无版本值）",
        hri_mode="ON（示例）",
        node_mode="DIRECT（示例）",
        gmx_mode="GM-X（示例）",
        wires_x=StatusReading("演示状态", "WIRES-X 模式显示为本地示例", "blue"),
        audio=StatusReading("模拟状态", "虚构音频端点 · 未打开", "blue"),
        brandmeister=StatusReading("未连接", "演示目标 · TG 91 / TS 1"),
        call=CallReading(
            callsign="DEMO-01",
            direction="本地 → 网络",
            talkgroup="91",
            timeslot="1",
            duration="00:12",
        ),
        target_talkgroup="91",
        target_timeslot="1",
        runtime_lines=(
            "演示快照已载入",
            "模拟 HRI 状态：ON / DIRECT / GM-X",
            "模拟通话：DEMO-01 → TG 91 / TS 1",
        ),
    )
