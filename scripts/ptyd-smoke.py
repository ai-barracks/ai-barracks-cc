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
  pressure    a client that stops reading throttles the child even while it
              writes without pause (daemon RSS bounded, child still running),
              and once it reads again gets exactly every line of a fixed-size
              sequence, then the end marker, then one EXITED (Codex r4)
  exit-order  a descendant that keeps the PTY busy after the child exited
              neither delays EXITED for ever nor lets an ATTACH see EXITED
              before OUTPUT (r4: EXITED -> OUTPUT -> EXITED)
  kill-tree   KILL also ends a HUP-ignoring background job of the child (r4),
              and of a child that already exited (r6)
  input-cap   input to a child that does not read is refused past the cap
              with an INPUT_REFUSED frame instead of buffered without bound
              (r4); the session lives on and I/O resumes once it reads (r6)
  leak        killed sessions are freed: daemon RSS stays flat over many
              create/output/kill cycles, each of which must succeed (r4, r6)
  hello       HELLO is answered with the daemon's revision (2+), so an app
              can tell an older daemon left running by an earlier build (r7)
  leftovers   what an exited child left running is ended by KILL even if
              forked after the exit, by SHUTDOWN, and survives record
              pruning so a KILL still reaches it (r7)
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

CREATE, ATTACH, INPUT, RESIZE, DETACH, LIST, KILL, SHUTDOWN, HELLO = range(1, 10)
CREATED, ATTACHED, OUTPUT, EXITED, SESSIONS, FAILURE, INPUT_REFUSED, WELCOME = range(101, 109)
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


PRESSURE_LINES = 200_000
PRESSURE_END = b"PRESSURE-END"


def frame_kinds(client, session):
    return [k for k, s, _ in client.frames if s == session]


def exited_once_after_output(client, session):
    """Exactly one EXITED, and no OUTPUT after it."""
    kinds = frame_kinds(client, session)
    if kinds.count(EXITED) != 1:
        return False
    return OUTPUT not in kinds[kinds.index(EXITED):]


def scenario_pressure(path, daemon_pid):
    client = Client(path)
    session = uuid.uuid4()
    # cat writes the prepared sequence in kernel-sized blocks back to back:
    # the PTY never runs dry, so a reader that only looks at pause when a read
    # comes back empty never does. -onlcr: no CR insertion (macOS emits a
    # stray CR when it splits a write at a newline).
    sequence = os.path.join(os.path.dirname(path), "pressure.txt")
    with open(sequence, "wb") as handle:
        for block in range(0, PRESSURE_LINES, 1000):
            handle.write("".join("%012d %s\n" % (i, "y" * 100) for i in range(block, block + 1000)).encode())
        handle.write(PRESSURE_END + b"\n")
    create(client, session, f"stty -onlcr; cat {sequence}")
    client.wait_for(lambda c: c.first(CREATED, session) is not None)
    pid = json.loads(client.first(CREATED, session) or b"{}").get("pid", 0)
    time.sleep(0.5)
    # Stop reading: the kernel socket buffer fills, then the daemon must stop
    # reading the PTY instead of buffering without bound.
    baseline = rss_kb(daemon_pid)
    time.sleep(3)
    stalled = rss_kb(daemon_pid)
    throttled = alive(pid)
    exited = client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=30)
    client.wait_for(lambda c: False, timeout=0.3)
    lines = [line for line in client.output(session).split(b"\n") if line]
    numbers = [int(line[:12]) for line in lines if len(line) == 113]
    complete = numbers == list(range(PRESSURE_LINES)) and len(lines) == PRESSURE_LINES + 1 and lines[-1] == PRESSURE_END
    check("pressure", stalled - baseline < 32 * 1024 and throttled and exited and complete
          and exited_once_after_output(client, session),
          f"rss {baseline}KB -> {stalled}KB while stalled, throttled={throttled}, lines={len(numbers)}/{PRESSURE_LINES}, "
          f"end={lines[-1][:16] if lines else None}, exited={exited}")
    client.close()


def scenario_exit_order(path):
    """The child exits while a HUP-ignoring background job keeps writing to
    the PTY: the reader's final read must end, and a client attaching in
    between must never see OUTPUT after EXITED."""
    client = Client(path)
    session = uuid.uuid4()
    create(client, session, "( trap '' HUP; while :; do echo spam-spam-spam-spam; done ) & sleep 0.3; echo LEADER-DONE; exit 4")
    client.wait_for(lambda c: c.first(CREATED, session) is not None)
    pid = json.loads(client.first(CREATED, session) or b"{}").get("pid", 0)
    deadline = time.time() + TIMEOUT
    while alive(pid) and time.time() < deadline:
        client.pump()
    late = Client(path)
    late.send(ATTACH, session)
    late.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=10)
    exited = client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=10)
    late.wait_for(lambda c: False, timeout=0.5)
    client.wait_for(lambda c: False, timeout=0.5)
    status = json.loads(client.first(EXITED, session) or b"{}").get("status")
    ordered = exited_once_after_output(client, session) and exited_once_after_output(late, session)
    check("exit-order", exited and status == 4 and ordered and b"LEADER-DONE" in client.output(session),
          f"status={status} late={[k for k in frame_kinds(late, session) if k != OUTPUT][:4]} "
          f"late_tail_kinds={frame_kinds(late, session)[-3:]}")
    try:
        os.killpg(pid, 9)
    except (ProcessLookupError, PermissionError):
        pass
    client.send(KILL, session)
    late.close()
    client.close()


def scenario_kill_tree(path):
    client = Client(path)
    session = uuid.uuid4()
    create(client, session, "trap '' HUP; sleep 600 & echo BG=$!; wait")
    client.wait_for(lambda c: b"BG=" in c.output(session))
    out = client.output(session)
    background = int(out.split(b"BG=")[1].split()[0]) if b"BG=" in out else 0
    client.send(KILL, session)
    exited = client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=10)
    time.sleep(0.5)
    survived = background > 0 and alive(background)
    if survived:
        os.kill(background, 9)
    # The leader exits first and leaves the job running; KILL on the ended
    # session still ends it (r6).
    ended = uuid.uuid4()
    create(client, ended, "trap '' HUP; sleep 600 & echo BG=$!; exit 0")
    left = client.wait_for(lambda c: c.first(EXITED, ended) is not None, timeout=10)
    out = client.output(ended)
    orphan = int(out.split(b"BG=")[1].split()[0]) if b"BG=" in out else 0
    orphan_alive_before = orphan > 0 and alive(orphan)
    client.send(KILL, ended)
    time.sleep(0.5)
    orphan_survived = orphan > 0 and alive(orphan)
    if orphan_survived:
        os.kill(orphan, 9)
    check("kill-tree", exited and background > 0 and not survived and left and orphan_alive_before and not orphan_survived,
          f"background={background} survived={survived} after_exit={orphan} survived={orphan_survived}")
    client.close()


def scenario_input_cap(path):
    client = Client(path)
    session = uuid.uuid4()
    # Does not read for 3 s, then takes exactly the 8 MiB the cap admits and
    # echoes whatever comes next.
    create(client, session, "stty raw -echo; sleep 3; head -c 8388608 > /dev/null; echo DRAINED; exec cat")
    client.wait_for(lambda c: c.first(CREATED, session) is not None)
    pid = json.loads(client.first(CREATED, session) or b"{}").get("pid", 0)
    time.sleep(0.3)
    chunk = b"i" * (1024 * 1024)
    for _ in range(12):
        client.send(INPUT, session, chunk)
        client.pump()
    refused = client.wait_for(lambda c: c.first(INPUT_REFUSED, session) is not None)
    message = (client.first(INPUT_REFUSED, session) or b"").decode(errors="replace")
    lives = alive(pid) and client.first(FAILURE, session) is None and client.first(EXITED, session) is None
    drained = client.wait_for(lambda c: b"DRAINED" in c.output(session), timeout=15)
    client.send(INPUT, session, b"PING-AFTER-REFUSAL")
    resumed = client.wait_for(lambda c: b"PING-AFTER-REFUSAL" in c.output(session))
    check("input-cap", refused and "input refused" in message and lives and drained and resumed,
          f"{message[:40]!r} lives={lives} drained={drained} resumed={resumed}")
    client.send(KILL, session)
    client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=10)
    client.close()


def scenario_leak(path, daemon_pid):
    client = Client(path)
    cycles, size = 60, 900 * 1024

    def cycle():
        session = uuid.uuid4()
        create(client, session, f"head -c {size} /dev/zero | tr '\\0' z; sleep 30")
        produced = client.wait_for(lambda c: len(c.output(session)) >= size, timeout=10)
        client.send(KILL, session)
        ended = client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=10)
        client.frames = []
        return produced and ended

    warm = all([cycle() for _ in range(5)])
    baseline = rss_kb(daemon_pid)
    measured = all([cycle() for _ in range(cycles)])
    grown = rss_kb(daemon_pid) - baseline
    # A flat RSS proves nothing if the sessions never ran (r6).
    check("leak", warm and measured and grown < 16 * 1024,
          f"rss +{grown}KB over {cycles} sessions of {size // 1024}KB, all_cycles_ok={warm and measured}")
    client.close()


def scenario_hello(path):
    client = Client(path)
    client.send(HELLO, uuid.UUID(int=0))
    answered = client.wait_for(lambda c: c.first(WELCOME) is not None, timeout=2)
    revision = json.loads(client.first(WELCOME) or b"{}").get("revision")
    check("hello", answered and isinstance(revision, int) and revision >= 2, f"revision={revision}")
    client.close()


def leftover_session(client, script):
    """An exited session whose HUP-ignoring helper keeps running; returns
    (session, helper pid, late child pid file)."""
    session = uuid.uuid4()
    create(client, session, script)
    client.wait_for(lambda c: c.first(EXITED, session) is not None, timeout=10)
    out = client.output(session)
    helper = int(out.split(b"HELPER=")[1].split()[0]) if b"HELPER=" in out else 0
    return session, helper


def scenario_leftovers(path):
    client = Client(path)
    workdir = os.path.dirname(path)
    # A child forked by the helper after the leader's exit (r7: a snapshot
    # taken at reap missed it).
    late_file = os.path.join(workdir, "late.pid")
    late_script = (f"( trap '' HUP; sleep 1; sleep 600 & echo $! > {late_file}; wait ) & "
                   "echo HELPER=$!; exit 0")
    late_session, late_helper = leftover_session(client, late_script)
    deadline = time.time() + 5
    while not os.path.exists(late_file) and time.time() < deadline:
        time.sleep(0.1)
    time.sleep(0.2)
    late = int(open(late_file).read().strip() or 0) if os.path.exists(late_file) else 0
    client.send(KILL, late_session)
    time.sleep(0.8)
    late_ok = late > 0 and late_helper > 0 and not alive(late) and not alive(late_helper)
    # Pruning keeps a record that still has processes, so KILL reaches them.
    held_session, held = leftover_session(client, "( trap '' HUP; sleep 600 ) & echo HELPER=$!; exit 0")
    for _ in range(34):
        filler = uuid.uuid4()
        create(client, filler, "exit 0")
        client.wait_for(lambda c: c.first(EXITED, filler) is not None, timeout=5)
    client.send(KILL, held_session)
    time.sleep(0.8)
    pruned_ok = held > 0 and not alive(held)
    check("leftovers", late_ok and pruned_ok,
          f"late={late} alive={alive(late) if late else None} after_prune_alive={alive(held) if held else None}")
    for pid in (late, late_helper, held):
        if pid > 0 and alive(pid):
            os.kill(pid, 9)
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
            scenario_exit_order(path)
            scenario_kill_tree(path)
            scenario_input_cap(path)
            scenario_leak(path, daemon.pid)
            scenario_hello(path)
            scenario_leftovers(path)

            survivor = Client(path)
            lingering = uuid.uuid4()
            create(survivor, lingering, "sleep 60")
            survivor.wait_for(lambda c: c.first(CREATED, lingering) is not None)
            lingering_pid = json.loads(survivor.first(CREATED, lingering) or b"{}").get("pid", 0)
            # SHUTDOWN also ends what an exited session's child left (r7).
            _, orphan_pid = leftover_session(survivor, "( trap '' HUP; sleep 600 ) & echo HELPER=$!; exit 0")

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
            orphan_alive = orphan_pid > 0 and alive(orphan_pid)
            if orphan_alive:
                os.kill(orphan_pid, 9)
            check("shutdown", daemon.returncode == 0 and not alive(lingering_pid) and not os.path.exists(path)
                  and orphan_pid > 0 and not orphan_alive, f"exit={daemon.returncode} orphan_alive={orphan_alive}")
        finally:
            # A crashed scenario must not leave a daemon behind.
            if daemon.poll() is None:
                daemon.kill()
                daemon.wait()
    print(f"log: {log_path}")
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
