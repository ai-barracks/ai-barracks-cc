#!/usr/bin/env python3
"""Protocol-level smoke test for AIBCCPtyDaemon (no app, no GUI).

usage: ptyd-smoke.py DAEMON_BINARY

Checks, each printed as PASS/FAIL:
  create      CREATE spawns a child and CREATED reports its pid
  output      the child's output arrives as OUTPUT frames
  input       INPUT bytes reach the child
  survive     the child survives the client disconnecting
  replay      a new client's ATTACH replays earlier output, then live I/O works
  resize      RESIZE changes the child's winsize (stty size)
  paste       a 256 KiB paste is delivered completely (no EAGAIN loss)
  signals     the child has default SIGPIPE/SIGHUP dispositions
  exit        EXITED carries the exit status; ATTACH after exit replays + EXITED
  kill        KILL hangs up a live child
  echo        keystroke round trip (cat in raw mode) p95 < 5 ms: coalescing
              must not delay interactive output
  throughput  100k lines (11.2 MB) delivered in < 1 s
  pressure    a client that stops reading throttles the child (daemon RSS
              bounded) and, once it reads again, gets every line in order
  single      a second daemon on the same socket exits without stealing it
  shutdown    SHUTDOWN stops the daemon and its children
Exit status 0 only if every check passed.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

CREATE, ATTACH, INPUT, RESIZE, DETACH, LIST, KILL, SHUTDOWN = range(1, 9)
CREATED, ATTACHED, OUTPUT, EXITED, SESSIONS, FAILURE = range(101, 107)
HEADER = struct.Struct(">B16sI")
TIMEOUT = 5.0
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.settimeout(0.2)
        self.buffer = b""
        self.frames = []

    def send(self, kind, session, payload=b""):
        self.sock.sendall(HEADER.pack(kind, session.bytes, len(payload)) + payload)

    def send_json(self, kind, session, value):
        self.send(kind, session, json.dumps(value).encode())

    def pump(self):
        try:
            chunk = self.sock.recv(65536)
            if not chunk:
                return False
            self.buffer += chunk
        except socket.timeout:
            pass
        while len(self.buffer) >= HEADER.size:
            kind, raw, length = HEADER.unpack_from(self.buffer)
            if len(self.buffer) < HEADER.size + length:
                break
            payload = self.buffer[HEADER.size:HEADER.size + length]
            self.buffer = self.buffer[HEADER.size + length:]
            self.frames.append((kind, uuid.UUID(bytes=raw), payload))
        return True

    def wait_for(self, predicate, timeout=TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate(self):
                return True
            if not self.pump():
                return predicate(self)
        return predicate(self)

    def output(self, session):
        return b"".join(p for k, s, p in self.frames if k == OUTPUT and s == session)

    def first(self, kind, session=None):
        for k, s, p in self.frames:
            if k == kind and (session is None or s == session):
                return p
        return None

    def close(self):
        self.sock.close()


def create(client, session, script, rows=24, cols=80):
    env = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"}
    client.send_json(CREATE, session, {
        "executable": "/bin/sh", "argv": ["sh", "-c", script], "workingDirectory": "/tmp",
        "environment": env, "columns": cols, "rows": rows,
    })


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def start_daemon(binary, path, log):
    return subprocess.Popen([binary, "--socket", path], stdout=subprocess.DEVNULL, stderr=log,
                            start_new_session=True)


def wait_socket(path):
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.connect(path)
            probe.close()
            return True
        except OSError:
            time.sleep(0.05)
    return False


def scenario_session(binary, path):
    first = Client(path)
    shell = uuid.uuid4()
    create(first, shell, "echo BANNER-$((40+2)); while read line; do "
                         "case \"$line\" in size) stty size;; *) echo \"got:$line:${#line}\";; esac; done")
    ok = first.wait_for(lambda c: c.first(CREATED, shell) is not None)
    info = json.loads(first.first(CREATED, shell) or b"{}")
    pid = info.get("pid", 0)
    check("create", ok and pid > 0 and info.get("alive") is True, f"pid={pid}")
    check("output", first.wait_for(lambda c: b"BANNER-42" in c.output(shell)))
    first.send(INPUT, shell, b"hello\n")
    check("input", first.wait_for(lambda c: b"got:hello:5" in c.output(shell)))
    first.close()
    time.sleep(0.3)
    check("survive", alive(pid))

    second = Client(path)
    second.send(ATTACH, shell)
    attached = second.wait_for(lambda c: c.first(ATTACHED, shell) is not None and b"got:hello" in c.output(shell))
    second.send(INPUT, shell, b"again\n")
    live = second.wait_for(lambda c: b"got:again:5" in c.output(shell))
    check("replay", attached and b"BANNER-42" in second.output(shell) and live)

    second.send_json(RESIZE, shell, {"columns": 132, "rows": 43, "widthPixels": 0, "heightPixels": 0})
    time.sleep(0.1)
    second.send(INPUT, shell, b"size\n")
    check("resize", second.wait_for(lambda c: b"43 132" in c.output(shell)))

    # Canonical mode caps a line at MAX_CANON, so count bytes with a raw reader.
    big = b"p" * (256 * 1024)
    paste = Client(path)
    reader = uuid.uuid4()
    create(paste, reader, "stty raw -echo; head -c 262144 | wc -c; sleep 5")
    paste.wait_for(lambda c: c.first(CREATED, reader) is not None)
    time.sleep(0.3)
    paste.send(INPUT, reader, big)
    check("paste", paste.wait_for(lambda c: b"262144" in c.output(reader), timeout=10),
          "" if b"262144" in paste.output(reader) else repr(paste.output(reader)[-80:]))
    paste.send(KILL, reader)
    paste.close()
    return second, shell, pid


def scenario_signals(path):
    client = Client(path)
    probe = uuid.uuid4()
    # SIGPIPE default: yes is killed by SIGPIPE (status 141), not EPIPE (1).
    # SIGHUP: python reports an inherited SIG_IGN as-is (it only changes PIPE/INT).
    create(client, probe, "{ yes; echo YES-$? >&2; } | head -1 >/dev/null; python3 -c "
                          "'import signal; print(\"HUP-IGN\" if signal.getsignal(signal.SIGHUP) == signal.SIG_IGN "
                          "else \"HUP-DFL\")'")
    client.wait_for(lambda c: b"HUP-" in c.output(probe))
    out = client.output(probe)
    check("signals", b"YES-141" in out and b"HUP-DFL" in out, repr(out.strip()[-60:]))
    client.close()


def scenario_exit(path):
    client = Client(path)
    job = uuid.uuid4()
    create(client, job, "echo FINAL-OUTPUT; exit 7")
    client.wait_for(lambda c: c.first(EXITED, job) is not None)
    status = json.loads(client.first(EXITED, job) or b"{}").get("status")
    client.close()
    later = Client(path)
    later.send(ATTACH, job)
    later.wait_for(lambda c: c.first(EXITED, job) is not None)
    replayed = b"FINAL-OUTPUT" in later.output(job)
    info = json.loads(later.first(ATTACHED, job) or b"{}")
    check("exit", status == 7 and replayed and info.get("alive") is False, f"status={status}")
    later.close()


def scenario_echo(path):
    client = Client(path)
    session = uuid.uuid4()
    create(client, session, "stty raw -echo; exec cat")
    client.wait_for(lambda c: c.first(CREATED, session) is not None)
    time.sleep(0.3)
    client.sock.settimeout(0.001)
    samples = []
    for index in range(40):
        before = len(client.output(session))
        start = time.perf_counter()
        client.send(INPUT, session, b"k")
        if client.wait_for(lambda c: len(c.output(session)) > before, timeout=1):
            samples.append((time.perf_counter() - start) * 1000)
        time.sleep(0.02 if index % 2 else 0.003)
    samples.sort()
    p95 = samples[int(len(samples) * 0.95) - 1] if samples else 1e9
    check("echo", len(samples) == 40 and p95 < 5, f"p50={samples[len(samples)//2]:.2f}ms p95={p95:.2f}ms" if samples else "")
    client.send(KILL, session)
    client.close()


def scenario_throughput(path):
    client = Client(path)
    session = uuid.uuid4()
    create(client, session, "python3 -c \"import sys; l=('x'*80+'가나다라마바사아자차'+'\\n'); "
                            "w=sys.stdout.write; [w(l) for _ in range(100000)]; sys.stdout.flush()\"")
    start = time.time()
    client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=20)
    elapsed = time.time() - start
    size = len(client.output(session))
    check("throughput", size >= 11_200_000 and elapsed < 1.0,
          f"{size} bytes in {elapsed * 1000:.0f}ms ({size / max(elapsed, 1e-6) / 1e6:.0f} MB/s)")
    client.close()


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out or 0)


def scenario_pressure(path, daemon_pid):
    client = Client(path)
    session = uuid.uuid4()
    create(client, session, "python3 -c \"import sys\nfor i in range(10**9): sys.stdout.write('%012d %s\\n' % (i, 'y' * 100))\"")
    client.wait_for(lambda c: c.first(CREATED, session) is not None)
    time.sleep(0.5)
    # Stop reading: the kernel socket buffer fills, then the daemon must stop
    # reading the PTY instead of buffering without bound.
    baseline = rss_kb(daemon_pid)
    time.sleep(3)
    stalled = rss_kb(daemon_pid)
    client.sock.settimeout(0.05)
    deadline = time.time() + 4
    while time.time() < deadline:
        client.pump()
    client.send(KILL, session)
    client.wait_for(lambda c: c.first(EXITED, session) is not None)
    lines = [line for line in client.output(session).split(b"\r\n") if len(line) == 113]
    numbers = [int(line[:12]) for line in lines]
    ordered = bool(numbers) and numbers == list(range(numbers[0], numbers[0] + len(numbers)))
    check("pressure", stalled - baseline < 32 * 1024 and ordered and numbers[0] == 0 and len(numbers) > 10000,
          f"rss {baseline}KB -> {stalled}KB while stalled, lines={len(numbers)} ordered={ordered}")
    client.close()


def scenario_kill(client, shell, pid):
    client.send(KILL, shell)
    exited = client.wait_for(lambda c: c.first(EXITED, shell) is not None)
    time.sleep(0.2)
    check("kill", exited and not alive(pid))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    binary = sys.argv[1]
    workdir = tempfile.mkdtemp(prefix="ptyd-smoke-")
    path = os.path.join(workdir, "ptyd.sock")
    log_path = os.path.join(workdir, "ptyd.log")
    with open(log_path, "w") as log:
        daemon = start_daemon(binary, path, log)
        if not wait_socket(path):
            check("start", False, "socket never appeared")
            return 1
        try:
            client, shell, pid = scenario_session(binary, path)
            scenario_signals(path)
            scenario_exit(path)
            scenario_kill(client, shell, pid)
            scenario_echo(path)
            scenario_throughput(path)
            scenario_pressure(path, daemon.pid)

            survivor = Client(path)
            lingering = uuid.uuid4()
            create(survivor, lingering, "sleep 60")
            survivor.wait_for(lambda c: c.first(CREATED, lingering) is not None)
            lingering_pid = json.loads(survivor.first(CREATED, lingering) or b"{}").get("pid", 0)

            second = start_daemon(binary, path, log)
            second.wait(timeout=TIMEOUT)
            still_served = wait_socket(path) and daemon.poll() is None
            check("single", second.returncode == 0 and still_served, f"second_exit={second.returncode}")

            survivor.send(SHUTDOWN, uuid.UUID(int=0))
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill()
            time.sleep(0.2)
            check("shutdown", daemon.returncode == 0 and not alive(lingering_pid) and not os.path.exists(path),
                  f"exit={daemon.returncode}")
        finally:
            # A crashed scenario must not leave a daemon behind.
            if daemon.poll() is None:
                daemon.kill()
                daemon.wait()
    print(f"log: {log_path}")
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
