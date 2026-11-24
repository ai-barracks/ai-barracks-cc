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
FLOOD_LINES = int(os.environ.get("FLOOD_LINES", "100000"))
CHUNK_LINES = 20
PROGRESS_EVERY = 2000
LINE = ("x" * 80) + ("가나다라마바사아자차") + "\r\n"


def log(out, lock, kind, **fields):
    record = {"kind": kind, "wall": round(time.time(), 6), **fields}
    with lock:
        out.write(json.dumps(record) + "\n")
        out.flush()


def wait_for_go():
    """Start flooding only when the test signals (AIBCC_GO_FILE), so typing
    and output overlap even though 100k lines take well under a second."""
    go = os.environ.get("AIBCC_GO_FILE")
    if not go:
        return
    deadline = time.time() + 10
    while not os.path.exists(go) and time.time() < deadline:
        time.sleep(0.005)


def flood(stop, out, lock):
    """Writes exactly FLOOD_LINES lines (criteria: 100k), with start /
    progress / done markers so the test only counts samples taken while
    output was really flowing."""
    lines = 0
    wait_for_go()
    try:
        log(out, lock, "flood_start")
        while not stop.is_set() and lines < FLOOD_LINES:
            sys.stdout.write(LINE * CHUNK_LINES)
            sys.stdout.flush()
            lines += CHUNK_LINES
            if lines % PROGRESS_EVERY == 0:
                log(out, lock, "flood_progress", lines=lines)
        log(out, lock, "flood_done", lines=lines)
    except Exception as error:  # surfaced to the test as an invalid run
        log(out, lock, "flood_error", message=str(error))


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
