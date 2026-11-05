#!/usr/bin/env python3
"""PTY ground-truth recorder for the AIBCC PoC self-test.

Puts the tty in raw mode and appends one JSON object per line to OUT:
  {"t": <monotonic s>, "kind": "ready", "rows": R, "cols": C}
  {"t": ..., "kind": "bytes", "hex": "e3 85 81"}
  {"t": ..., "kind": "winsize", "rows": R, "cols": C}
After every resize it redraws corner markers (TL at row 1 col 1, BR ending
at the last column of the last row) so a screenshot shows whether the last
row/column is actually visible. Exits on byte 0x04 (Ctrl+D).
Set AIBCC_MOUSE_REPORT=1 to enable SGR mouse reporting (a TUI that captures
the mouse) and AIBCC_BRACKETED_PASTE=1 to enable bracketed paste.
AIBCC_ECHO=1 writes every received chunk back to the screen (R5 render
check: input delivery is logged, its drawing is compared in captures).
AIBCC_BANNER=TEXT is redrawn on row 3 with the markers (persistence replay
check); AIBCC_DA_QUERY=1 sends one DA1 query at start, whose answer arrives
as input (proves a replayed query is not answered twice).
AIBCC_DA_ON_CTRL_A=1 sends a DA1 query each time input holds Ctrl+A (a live
query the test triggers right behind an attach replay).
"""

import fcntl
import json
import os
import signal
import struct
import sys
import termios
import time
import tty

CTRL_A = 0x01
CTRL_D = 0x04
READ_CHUNK = 4096
MOUSE_ON = "\x1b[?1000h\x1b[?1002h\x1b[?1006h"
MOUSE_OFF = "\x1b[?1006l\x1b[?1002l\x1b[?1000l"
BRACKETED_ON = "\x1b[?2004h"
BRACKETED_OFF = "\x1b[?2004l"
DA1_QUERY = "\x1b[c"


def enabled(name):
    return os.environ.get(name) == "1"


def set_modes(on):
    if enabled("AIBCC_MOUSE_REPORT"):
        sys.stdout.write(MOUSE_ON if on else MOUSE_OFF)
    if enabled("AIBCC_BRACKETED_PASTE"):
        sys.stdout.write(BRACKETED_ON if on else BRACKETED_OFF)
    sys.stdout.flush()


def winsize(fd):
    packed = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
    rows, cols, _, _ = struct.unpack("HHHH", packed)
    return rows, cols


def log(out, kind, **fields):
    record = {"t": round(time.monotonic(), 6), "kind": kind, **fields}
    out.write(json.dumps(record) + "\n")
    out.flush()


def draw_markers(rows, cols):
    tail = "BR"
    sys.stdout.write("\x1b[2J\x1b[1;1HTL")
    sys.stdout.write(f"\x1b[{rows};{max(cols - len(tail) + 1, 1)}H{tail}")
    sys.stdout.write(f"\x1b[2;1Hrows={rows} cols={cols}")
    banner = os.environ.get("AIBCC_BANNER")
    if banner:
        sys.stdout.write(f"\x1b[3;1H{banner}")
    sys.stdout.flush()


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: pty_recorder.py OUT\n")
        return 2
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    with open(sys.argv[1], "a", encoding="utf-8") as out:

        def on_winch(_signum, _frame):
            rows, cols = winsize(fd)
            log(out, "winsize", rows=rows, cols=cols)
            draw_markers(rows, cols)

        signal.signal(signal.SIGWINCH, on_winch)
        tty.setraw(fd)
        try:
            rows, cols = winsize(fd)
            draw_markers(rows, cols)
            set_modes(True)
            log(out, "ready", rows=rows, cols=cols)
            if enabled("AIBCC_DA_QUERY"):
                sys.stdout.write(DA1_QUERY)
                sys.stdout.flush()
            while True:
                data = os.read(fd, READ_CHUNK)
                if not data:
                    break
                log(out, "bytes", hex=data.hex(" "))
                if enabled("AIBCC_DA_ON_CTRL_A") and CTRL_A in data:
                    sys.stdout.write(DA1_QUERY)
                    sys.stdout.flush()
                if enabled("AIBCC_ECHO"):
                    sys.stdout.write(data.decode("utf-8", "replace"))
                    sys.stdout.flush()
                if CTRL_D in data:
                    break
        finally:
            set_modes(False)
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
