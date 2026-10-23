"""校验并关联 native core 的逐行事件协议。

组件字段按核心原样保留。本模块不会根据进程句柄、accepted 应答或匹配到的协议记录，
推断电台、HRI、音频或停止状态。
"""
from __future__ import annotations

import copy
import json
import re
from dataclasses import dataclass
from typing import Any, Mapping


PROTOCOL_VERSION = 1
MAX_COMMAND_LINE_BYTES = 256
COMMANDS = frozenset(
    {"send_fixed", "capture_mic", "cancel_operation", "shutdown"}
)
MESSAGE_TYPES = frozenset(
    {"snapshot", "request_result", "operation_event", "operation_result", "session_result"}
)
SESSION_STATUSES = frozenset(
    {"running", "stopping", "completed", "failed", "timed_out", "unknown"}
)
REQUEST_STATUSES = frozenset({"accepted", "busy", "rejected"})
RESULT_STATUSES = frozenset({"completed", "failed", "cancelled", "timed_out", "unknown"})
_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$", re.ASCII)


class ProtocolError(ValueError):
    """消息或命令不符合已约定的 native 协议。"""


@dataclass(frozen=True)
class RequestState:
    """UI 发出的请求进度，与设备组件状态分开保存。"""

    request_id: str
    command: str
    status: str
    phase: str
    accepted: bool
    terminal: bool
    last_event: Mapping[str, Any] | None


def new_request_id() -> str:
    """生成 native 命令解析器接受的 request ID。"""
    import uuid

    return uuid.uuid4().hex


def _validate_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or _ID_RE.fullmatch(value) is None:
        raise ProtocolError(f"{label} must match [A-Za-z0-9_-]{{1,64}}")
    return value


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def _parse_event(raw: str | bytes | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise ProtocolError("event is not valid UTF-8") from exc

    if isinstance(raw, str):
        line = raw.rstrip("\r\n")
        if not line or "\n" in line or "\r" in line:
            raise ProtocolError("expected exactly one non-empty JSON line")
        try:
            message = json.loads(line, object_pairs_hook=_reject_duplicate_json_keys)
        except ProtocolError:
            raise
        except (json.JSONDecodeError, UnicodeError) as exc:
            raise ProtocolError("event is not valid JSON") from exc
    elif isinstance(raw, Mapping):
        message = copy.deepcopy(dict(raw))
    else:
        raise ProtocolError("event must be a JSON line or object")

    if not isinstance(message, dict):
        raise ProtocolError("event must be a JSON object")

    required = {
        "protocol_version",
        "type",
        "run_id",
        "seq",
        "request_id",
        "status",
        "phase",
    }
    missing = required.difference(message)
    if missing:
        raise ProtocolError("missing event fields: " + ", ".join(sorted(missing)))

    version = message["protocol_version"]
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol_version: {version!r}")

    message_type = message["type"]
    if not isinstance(message_type, str) or message_type not in MESSAGE_TYPES:
        raise ProtocolError(f"unsupported event type: {message_type!r}")

    _validate_id(message["run_id"], "run_id")
    seq = message["seq"]
    if type(seq) is not int or seq <= 0:
        raise ProtocolError("seq must be a positive integer")

    request_id = message["request_id"]
    if request_id is not None:
        _validate_id(request_id, "request_id")
    if message_type == "snapshot" and request_id is not None:
        raise ProtocolError("snapshot request_id must be null")
    if message_type not in {"snapshot", "session_result"} and request_id is None:
        raise ProtocolError(f"{message_type} requires request_id")

    status = message["status"]
    if not isinstance(status, str) or not status:
        raise ProtocolError("status must be a non-empty string")
    phase = message["phase"]
    if not isinstance(phase, str) or not phase.strip():
        raise ProtocolError("phase must be a non-empty string")

    if message_type in {"snapshot", "operation_event"}:
        if status not in SESSION_STATUSES:
            raise ProtocolError(f"unsupported session status: {status!r}")
    elif message_type == "request_result":
        if status not in REQUEST_STATUSES:
            raise ProtocolError(f"unsupported request status: {status!r}")
    elif status not in RESULT_STATUSES:
        raise ProtocolError(f"unsupported result status: {status!r}")

    return message


class CoreProtocolAdapter:
    """绑定首个 native 快照，并校验后续事件与请求。

    每个适配器只对应一个 native 进程 run。stdout 关闭时 UI 调用
    :meth:`mark_eof`；只有持有的进程句柄已发出退出信号后才调用
    :meth:`mark_process_exited`。这两种情况都会让最后一份快照变成过期数据。
    """

    def __init__(self) -> None:
        self._run_id: str | None = None
        self._last_seq = 0
        self._snapshot: dict[str, Any] | None = None
        self._last_event: dict[str, Any] | None = None
        self._requests: dict[str, RequestState] = {}
        self._shutdown_request_id: str | None = None
        self._shutdown_result: dict[str, Any] | None = None
        self._session_terminal = False
        self._session_status: str | None = None
        self._session_phase: str | None = None
        self._stale = True
        self._eof = False
        self._process_exited = False

    @property
    def run_id(self) -> str | None:
        return self._run_id

    @property
    def last_seq(self) -> int:
        return self._last_seq

    @property
    def stale(self) -> bool:
        return self._stale

    @property
    def eof(self) -> bool:
        return self._eof

    @property
    def process_exited(self) -> bool:
        return self._process_exited

    @property
    def session_status(self) -> str | None:
        return self._session_status

    @property
    def session_phase(self) -> str | None:
        return self._session_phase

    @property
    def session_terminal(self) -> bool:
        return self._session_terminal

    @property
    def snapshot(self) -> Mapping[str, Any] | None:
        return copy.deepcopy(self._snapshot)

    @property
    def last_event(self) -> Mapping[str, Any] | None:
        return copy.deepcopy(self._last_event)

    @property
    def requests(self) -> Mapping[str, RequestState]:
        return dict(self._requests)

    @property
    def pending_requests(self) -> Mapping[str, RequestState]:
        return {key: value for key, value in self._requests.items() if not value.terminal}

    @property
    def terminal_requests(self) -> Mapping[str, RequestState]:
        return {key: value for key, value in self._requests.items() if value.terminal}

    @property
    def shutdown_result(self) -> Mapping[str, Any] | None:
        return copy.deepcopy(self._shutdown_result)

    def prepare_command(self, request_id: str, command: str) -> bytes:
        """登记 UI 命令，并按约定编码为 ASCII stdin 行。"""
        if self._eof or self._process_exited:
            raise ProtocolError("native process input is already closed")
        if self._session_terminal:
            raise ProtocolError("native session has already ended")
        if self._run_id is None:
            raise ProtocolError("cannot send commands before the first snapshot")
        if self._stale:
            raise ProtocolError("cannot send commands while core state is stale")
        request_id = _validate_id(request_id, "request_id")
        if not isinstance(command, str) or command not in COMMANDS:
            raise ProtocolError(f"unsupported command: {command!r}")
        if request_id in self._requests:
            raise ProtocolError("request_id has already been used in this run")
        if command == "shutdown":
            if self._shutdown_request_id is not None:
                raise ProtocolError("shutdown has already been requested")
            self._shutdown_request_id = request_id
        elif self._shutdown_request_id is not None:
            raise ProtocolError("cannot send a new operation after shutdown starts")
        elif self._session_status != "running":
            raise ProtocolError("cannot send operations unless the session is running")

        line = f"{PROTOCOL_VERSION} {self._run_id} {request_id} {command}\n".encode("ascii")
        if len(line) > MAX_COMMAND_LINE_BYTES:
            raise ProtocolError("command line exceeds the native limit")

        self._requests[request_id] = RequestState(
            request_id=request_id,
            command=command,
            status="sent",
            phase=self._session_phase or "starting",
            accepted=False,
            terminal=False,
            last_event=None,
        )
        return line

    def consume(self, raw: str | bytes | Mapping[str, Any]) -> Mapping[str, Any] | None:
        """应用合法事件；旧 run 或旧序号会被丢弃并返回 ``None``。"""
        if self._eof or self._process_exited:
            raise ProtocolError("event received after the native process stream closed")
        if self._session_terminal:
            raise ProtocolError("event received after the native session result")
        message = _parse_event(raw)

        if self._run_id is None:
            if message["type"] != "snapshot":
                raise ProtocolError("the first native event must be a snapshot")
        else:
            if message["run_id"] != self._run_id:
                return None
            if message["seq"] <= self._last_seq:
                return None

        request_state: RequestState | None = None
        if message["type"] in {"request_result", "operation_event", "operation_result"}:
            request_id = message["request_id"]
            request_state = self._requests.get(request_id)
            if request_state is None:
                raise ProtocolError("event refers to a request not owned by this UI run")
            if request_state.terminal:
                raise ProtocolError("event arrived after this request reached a terminal result")

            if message["type"] in {"operation_event", "operation_result"} and request_state.command == "shutdown":
                raise ProtocolError("shutdown responses must use session_result")
            elif message["type"] in {"operation_event", "operation_result"}:
                if not request_state.accepted:
                    raise ProtocolError("operation event arrived before request acceptance")
            elif request_state.accepted:
                raise ProtocolError("request_result may be sent only once")

        if message["type"] == "session_result":
            request_id = message["request_id"]
            if request_id is None:
                if self._shutdown_request_id is not None:
                    sent_shutdown = self._requests[self._shutdown_request_id]
                    if sent_shutdown.accepted and not sent_shutdown.terminal:
                        raise ProtocolError("an accepted shutdown result must echo its request_id")
            else:
                request_state = self._requests.get(request_id)
                if request_state is None:
                    raise ProtocolError("session_result refers to a request not owned by this UI run")
                if request_state.command != "shutdown" or not request_state.accepted or request_state.terminal:
                    raise ProtocolError("session_result must match an accepted shutdown request")

        self._run_id = message["run_id"]
        self._last_seq = message["seq"]
        self._last_event = copy.deepcopy(message)
        self._stale = False
        self._session_status = message["status"] if message["type"] in {"snapshot", "operation_event", "session_result"} else self._session_status
        self._session_phase = message["phase"] if message["type"] in {"snapshot", "operation_event", "session_result"} else self._session_phase

        if message["type"] == "snapshot":
            self._snapshot = copy.deepcopy(message)
        elif message["type"] == "request_result":
            assert request_state is not None
            terminal = message["status"] in {"busy", "rejected"}
            self._requests[request_state.request_id] = RequestState(
                request_id=request_state.request_id,
                command=request_state.command,
                status=message["status"],
                phase=message["phase"],
                accepted=message["status"] == "accepted",
                terminal=terminal,
                last_event=copy.deepcopy(message),
            )
        elif message["type"] == "operation_event":
            assert request_state is not None
            self._requests[request_state.request_id] = RequestState(
                request_id=request_state.request_id,
                command=request_state.command,
                status=request_state.status,
                phase=message["phase"],
                accepted=True,
                terminal=False,
                last_event=copy.deepcopy(message),
            )
        elif message["type"] == "operation_result":
            assert request_state is not None
            self._requests[request_state.request_id] = RequestState(
                request_id=request_state.request_id,
                command=request_state.command,
                status=message["status"],
                phase=message["phase"],
                accepted=True,
                terminal=True,
                last_event=copy.deepcopy(message),
            )
        elif message["type"] == "session_result":
            if request_state is not None:
                self._requests[request_state.request_id] = RequestState(
                    request_id=request_state.request_id,
                    command=request_state.command,
                    status=message["status"],
                    phase=message["phase"],
                    accepted=True,
                    terminal=True,
                    last_event=copy.deepcopy(message),
                )
            self._shutdown_result = copy.deepcopy(message)
            self._session_terminal = True

        return copy.deepcopy(message)

    def mark_eof(self) -> None:
        """标记 stdout 到达 EOF；最后一份快照从此不再代表当前状态。"""
        self._eof = True
        self._stale = True

    def mark_process_exited(self) -> None:
        """监督器持有的进程句柄确认退出后，标记 native 进程已退出。"""
        self._process_exited = True
        self._stale = True
