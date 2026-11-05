"""FTX-1 CAT 只读静噪采样（FM 中继研究用）。

只发送只读查询：ID; RI0; SM0; SM1; SQ0; TX;  —— 不发送任何设置、发射或菜单写入命令。
用法：python -I tools/research/cat_squelch_probe.py --port COM11 --baud 38400 --seconds 60 --out <jsonl>
采样间隔默认 100 ms；每行输出一个 JSON 采样，退出时打印 SQL 开门段汇总。
仅依赖标准库（ctypes 调用 Win32 串口 API）。运行前关闭占用该 COM 口的程序（WIREX Bridge / 官方 WIRES-X）。
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import sys
import time

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = wt.HANDLE(-1).value
PURGE_RXCLEAR = 0x0008
PURGE_TXCLEAR = 0x0004
TWOSTOPBITS = 2
NOPARITY = 0

# 只读命令白名单：脚本拒绝发送任何其它内容。
READ_ONLY = {b"ID;", b"RI0;", b"SM0;", b"SM1;", b"SQ0;", b"TX;"}


class DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wt.DWORD), ("BaudRate", wt.DWORD), ("flags", wt.DWORD), ("wReserved", wt.WORD),
        ("XonLim", wt.WORD), ("XoffLim", wt.WORD), ("ByteSize", ctypes.c_ubyte), ("Parity", ctypes.c_ubyte),
        ("StopBits", ctypes.c_ubyte), ("XonChar", ctypes.c_char), ("XoffChar", ctypes.c_char),
        ("ErrorChar", ctypes.c_char), ("EofChar", ctypes.c_char), ("EvtChar", ctypes.c_char),
        ("wReserved1", wt.WORD),
    ]


class COMMTIMEOUTS(ctypes.Structure):
    _fields_ = [
        ("ReadIntervalTimeout", wt.DWORD), ("ReadTotalTimeoutMultiplier", wt.DWORD),
        ("ReadTotalTimeoutConstant", wt.DWORD), ("WriteTotalTimeoutMultiplier", wt.DWORD),
        ("WriteTotalTimeoutConstant", wt.DWORD),
    ]


k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateFileW.restype = wt.HANDLE
k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE]


class Port:
    def __init__(self, name: str, baud: int) -> None:
        self.handle = k32.CreateFileW("\\\\.\\" + name, GENERIC_READ | GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None)
        if self.handle in (None, INVALID_HANDLE_VALUE):
            raise OSError(f"无法打开 {name}（错误 {ctypes.get_last_error()}）；确认没有其它程序占用该端口。")
        dcb = DCB()
        dcb.DCBlength = ctypes.sizeof(DCB)
        if not k32.GetCommState(self.handle, ctypes.byref(dcb)):
            self.close()
            raise OSError(f"GetCommState 失败（{ctypes.get_last_error()}）")
        dcb.BaudRate = baud
        dcb.ByteSize = 8
        dcb.Parity = NOPARITY
        dcb.StopBits = TWOSTOPBITS
        dcb.flags = 0x0001  # fBinary；DTR/RTS 关闭、无流控（与 app::radio_cat 一致）
        if not k32.SetCommState(self.handle, ctypes.byref(dcb)):
            self.close()
            raise OSError(f"SetCommState 失败（{ctypes.get_last_error()}）")
        timeouts = COMMTIMEOUTS(5, 0, 50, 0, 200)
        if not k32.SetCommTimeouts(self.handle, ctypes.byref(timeouts)):
            self.close()
            raise OSError(f"SetCommTimeouts 失败（{ctypes.get_last_error()}）")
        k32.PurgeComm(self.handle, PURGE_RXCLEAR | PURGE_TXCLEAR)

    def query(self, command: bytes, timeout_s: float = 0.3) -> str | None:
        if command not in READ_ONLY:
            raise ValueError(f"拒绝发送非只读命令：{command!r}")
        written = wt.DWORD(0)
        if not k32.WriteFile(self.handle, command, len(command), ctypes.byref(written), None) or written.value != len(command):
            return None
        deadline = time.monotonic() + timeout_s
        buffer = bytearray()
        chunk = ctypes.create_string_buffer(64)
        while time.monotonic() < deadline:
            read = wt.DWORD(0)
            if not k32.ReadFile(self.handle, chunk, 64, ctypes.byref(read), None):
                return None
            buffer += chunk.raw[: read.value]
            if b";" in buffer:
                answer, _, _ = buffer.partition(b";")
                return answer.decode("ascii", "replace") + ";"
        return None

    def close(self) -> None:
        if self.handle not in (None, INVALID_HANDLE_VALUE):
            k32.CloseHandle(self.handle)
            self.handle = None


def parse_ri(answer: str | None) -> dict | None:
    if not answer or len(answer) != 11 or not answer.startswith("RI") or not answer.endswith(";"):
        return None
    p = answer[2:10]
    if not p.isdigit():
        return None
    return {"tx": int(p[3]), "scan": int(p[6]), "sql_open": p[7] == "1", "raw": answer}


def parse_3digit(answer: str | None, prefix: str) -> int | None:
    if answer and answer.startswith(prefix) and len(answer) == len(prefix) + 4 and answer[len(prefix):-1].isdigit():
        return int(answer[len(prefix):-1])
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", default="COM11")
    parser.add_argument("--baud", type=int, default=38400)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--interval-ms", type=int, default=100)
    parser.add_argument("--out", required=True, help="JSONL 输出路径")
    args = parser.parse_args()

    try:
        port = Port(args.port, args.baud)
    except OSError as error:
        print(error, file=sys.stderr)
        return 2
    segments: list[dict] = []
    try:
        ident = port.query(b"ID;")
        if ident != "ID0840;":
            print(f"CAT 身份不符：{ident!r}（期望 ID0840;），停止。", file=sys.stderr)
            return 3
        squelch_level = parse_3digit(port.query(b"SQ0;"), "SQ0")
        tx_state = port.query(b"TX;")
        print(f"已连接 {args.port} {args.baud} 8N2：ID0840，MAIN 静噪等级 {squelch_level}，TX 状态 {tx_state}")
        print(f"开始采样 {args.seconds:.0f} s（间隔 {args.interval_ms} ms）。现在用第二台电台对 FTX-1 发射，"
              "建议：按住 3 s → 松开 3 s，重复 3 次。Ctrl+C 可提前结束。")
        start = time.monotonic()
        open_since: float | None = None
        open_peak = 0
        samples = failures = 0
        with open(args.out, "w", encoding="utf-8") as out:
            while time.monotonic() - start < args.seconds:
                t = time.monotonic() - start
                ri = parse_ri(port.query(b"RI0;"))
                sm = parse_3digit(port.query(b"SM0;"), "SM0")
                sm_sub = parse_3digit(port.query(b"SM1;"), "SM1")
                samples += 1
                if ri is None:
                    failures += 1
                record = {"t_ms": round(t * 1000), "ri": ri["raw"] if ri else None,
                          "sql_open": ri["sql_open"] if ri else None, "tx": ri["tx"] if ri else None, "s_meter": sm, "s_meter_sub": sm_sub}
                out.write(json.dumps(record) + "\n")
                if ri and ri["sql_open"]:
                    if open_since is None:
                        open_since = t
                        open_peak = 0
                        print(f"  {t:7.2f}s  SQL 开门  S={sm}")
                    open_peak = max(open_peak, sm or 0)
                elif ri and open_since is not None:
                    segments.append({"start_s": round(open_since, 2), "duration_s": round(t - open_since, 2), "s_peak": open_peak})
                    print(f"  {t:7.2f}s  SQL 关门  持续 {t - open_since:.2f}s  峰值 S={open_peak}")
                    open_since = None
                elapsed = time.monotonic() - start - t
                time.sleep(max(0.0, args.interval_ms / 1000.0 - elapsed))
        if open_since is not None:
            segments.append({"start_s": round(open_since, 2), "duration_s": None, "s_peak": open_peak})
        print(f"\n采样 {samples} 次，查询失败 {failures} 次；SQL 开门段 {len(segments)} 个：")
        for s in segments:
            print(f"  {s}")
    except KeyboardInterrupt:
        print("\n已中断。")
    finally:
        port.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
