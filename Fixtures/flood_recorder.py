#!/usr/bin/env python3
"""ST-02 load fixture: floods the terminal with output while recording input.

Writes lines of 80 ASCII + 10 Hangul characters continuously (until Ctrl+D or
FLOOD_SECONDS) from a background thread, and logs every input chunk with a
wall-clock timestamp (time.time(); python's monotonic clock is process
relative on this Mac, so the app compares against Date() instead):
  {"kind": "ready", "wall": ...}
  {"kind": "bytes", "hex": "61", "wall": ...}
  {"kind": "flood_done", "lines": N, "wall": ...}
"""

import json
import os
import sys
import termios
import threading
import time
import tty

CTRL_D = 0x04
FLOOD_SECONDS = 8.0
LINE = ("x" * 80) + ("가나다라마바사아자차") + "\r\n"


def log(out, lock, kind, **fields):
    record = {"kind": kind, "wall": round(time.time(), 6), **fields}
    with lock:
        out.write(json.dumps(record) + "\n")
        out.flush()


def flood(stop, out, lock):
    lines = 0
    deadline = time.time() + FLOOD_SECONDS
    while not stop.is_set() and time.time() < deadline:
        sys.stdout.write(LINE * 20)
        sys.stdout.flush()
        lines += 20
    log(out, lock, "flood_done", lines=lines)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: flood_recorder.py OUT\n")
        return 2
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    lock = threading.Lock()
    stop = threading.Event()
    with open(sys.argv[1], "a", encoding="utf-8") as out:
        tty.setraw(fd)
        try:
            log(out, lock, "ready")
            worker = threading.Thread(target=flood, args=(stop, out, lock), daemon=True)
            worker.start()
            while True:
                data = os.read(fd, 4096)
                if not data:
                    break
                log(out, lock, "bytes", hex=data.hex(" "))
                if CTRL_D in data:
                    break
        finally:
            stop.set()
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
