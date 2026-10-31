#!/usr/bin/env python3
"""PTY ground-truth recorder for the AIBCC PoC self-test.

Puts the tty in raw mode and appends one JSON object per line to OUT:
  {"t": <monotonic s>, "kind": "ready", "rows": R, "cols": C}
  {"t": ..., "kind": "bytes", "hex": "e3 85 81"}
  {"t": ..., "kind": "winsize", "rows": R, "cols": C}
After every resize it redraws corner markers (TL at row 1 col 1, BR ending
at the last column of the last row) so a screenshot shows whether the last
row/column is actually visible. Exits on byte 0x04 (Ctrl+D).
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

CTRL_D = 0x04
READ_CHUNK = 4096


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
            log(out, "ready", rows=rows, cols=cols)
            draw_markers(rows, cols)
            while True:
                data = os.read(fd, READ_CHUNK)
                if not data:
                    break
                log(out, "bytes", hex=data.hex(" "))
                if CTRL_D in data:
                    break
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
