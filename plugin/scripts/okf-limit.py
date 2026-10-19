#!/usr/bin/env python3
"""okf-limit.py <secs> <max_rss_mb> <outfile> -- <command...> — run one external command under a time and memory limit.

okf-check runs okflint through this (its run_limited). The command gets its own process group, so the whole tree
(okflint is started by a uv shim, and the python that holds the memory can be a grandchild) is stopped, never just the
direct child. stdout goes to <outfile> and stderr to <outfile>.err, so a crash is "no stdout" and never reads as a verdict.

Stops the command, and writes the reason to <outfile>.limit, when:
  - <secs> pass: TERM to the group, KILL a second later; exit 143; the marker says `timeout`.
  - the group's resident memory (sampled with ps four times a second) passes <max_rss_mb>: KILL at once, exit 137; `rss <measured MB> <limit MB>`.
    A runaway read of a device grew a process by over 1 GB per second (2026-10-18, 112 GB), so there is no grace period.
  - okf-check goes away (its pid is no longer our parent), or this process gets TERM, INT or HUP: the group is stopped
    and nothing is left running. This process leaves okf-check's session on purpose: a caller that kills okf-check's
    own process group with SIGKILL would otherwise leave this watchdog and its command behind.
  - this process itself gets SIGKILL (no handler can run): a small watcher, started in a session of its own, holds the
    other end of a pipe, sees it close, and kills the command's group. A group whose member called setsid (a grandchild
    in a session of its own) is outside killpg and is not reached: okflint starts none, and nothing here can reach it.
Otherwise it exits with the command's status (128 + n for a signal n). No `ps` and no /proc: the memory limit is off and
the marker says `nomem` once; the time limit still holds.
"""
import os
import select
import signal
import subprocess
import sys
import time

TERM_GRACE = 1.0   # seconds between TERM and KILL
SAMPLE_EVERY = 0.25   # seconds between memory samples: a runaway read grew over 1 GB per second, so one a second is too slow


def sample(root_pgid):
    """Total RSS in MB of every process in the group `root_pgid` or descended from one; None when nothing can be sampled."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,rss="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = None
    rows = {}
    if out:
        for line in out.splitlines():
            f = line.split()
            if len(f) == 4 and all(x.isdigit() for x in f):
                rows[int(f[0])] = (int(f[1]), int(f[2]), int(f[3]))   # ppid, pgid, rss in KB
    elif os.path.isdir("/proc/self"):   # a Linux image without procps (debian:12 minimal)
        page = os.sysconf("SC_PAGE_SIZE")
        for name in os.listdir("/proc"):
            if name.isdigit():
                try:
                    with open("/proc/%s/stat" % name) as fh:
                        rest = fh.read().rsplit(")", 1)[1].split()   # state ppid pgrp session tty tpgid flags ... rss at [21]
                    rows[int(name)] = (int(rest[1]), int(rest[2]), int(rest[21]) * page // 1024)
                except (OSError, IndexError, ValueError):
                    pass
    else:
        return None
    members = {pid for pid, (_, pg, _) in rows.items() if pg == root_pgid}
    grew = True
    while grew:
        grew = False
        for pid, (pp, _, _) in rows.items():
            if pp in members and pid not in members:
                members.add(pid)
                grew = True
    return sum(rows[p][2] for p in members) // 1024


def stop(pgid, hard=False):
    """TERM the group, wait up to TERM_GRACE for it to go, then KILL it. hard: KILL at once."""
    for sig in ([signal.SIGKILL] if hard else [signal.SIGTERM, signal.SIGKILL]):
        try:
            os.killpg(pgid, sig)
        except OSError:
            return
        end = time.monotonic() + (0 if sig == signal.SIGKILL else TERM_GRACE)
        while time.monotonic() < end:
            try:
                os.killpg(pgid, 0)
            except OSError:
                return
            time.sleep(0.05)


def start_watcher(pgid):
    """Fork a watcher that kills the group `pgid` when this process dies without saying goodbye. Returns the pipe end to
    write the goodbye to, and the watcher's pid: one byte means "I stopped the command myself" (and this process then
    waits for the watcher, or a container without init would keep it defunct for ever), end of file with no byte means this
    process was killed. The watcher has its own session (a group kill aimed at okf-check does not reach it) and no inherited
    output descriptors (a caller that waits on a pipe must not wait on it)."""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(w)
            os.setsid()
            devnull = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(devnull, fd)
            while True:
                if select.select([r], [], [], SAMPLE_EVERY)[0]:
                    if not os.read(r, 1):   # end of file with no goodbye: the supervisor is gone
                        stop(pgid, hard=True)
                    break
                try:
                    os.killpg(pgid, 0)
                except OSError:   # the command's group is gone already
                    break
        finally:
            os._exit(0)
    os.close(r)
    return w, pid


def main():
    secs, cap, out = float(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    parent = os.getppid()
    try:
        os.setsid()
    except OSError:
        pass
    for stale in (out + ".limit",):
        try:
            os.unlink(stale)
        except OSError:
            pass
    with open(out, "wb") as so, open(out + ".err", "wb") as se:
        try:
            child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=so, stderr=se, start_new_session=True)
        except OSError as exc:
            se.write(("okf-limit: cannot run %s: %s\n" % (cmd[0], exc)).encode())
            return 127
    goodbye, watcher = start_watcher(child.pid)
    reason = []

    def bye(signum, _frame):   # okf-check was told to stop, or Ctrl-C: nothing may outlive it
        reason.append("signal")
        stop(child.pid)
        sys.exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, bye)

    def mark(text):
        with open(out + ".limit", "w") as fh:
            fh.write(text + "\n")

    try:
        return supervise(child, parent, secs, cap, out, mark)
    finally:
        try:
            os.write(goodbye, b"x")   # the watcher stands down: the command is already stopped
            os.close(goodbye)
            os.waitpid(watcher, 0)   # it exits at once; reaped here so no defunct process is left behind
        except OSError:
            pass


def supervise(child, parent, secs, cap, out, mark):
    t0, warned, last = time.monotonic(), False, time.monotonic()
    while True:
        try:
            rc = child.wait(timeout=0.05)   # short polls: a command that ends in 0.2 s must not cost a whole second
            stop(child.pid, hard=True)   # a grandchild may outlive the command it was started by
            return rc if rc >= 0 else 128 - rc
        except subprocess.TimeoutExpired:
            pass
        if os.getppid() != parent:
            stop(child.pid)
            return 143
        if time.monotonic() - t0 >= secs:
            mark("timeout")
            stop(child.pid)
            child.wait()
            return 143
        if time.monotonic() - last < SAMPLE_EVERY:
            continue
        last = time.monotonic()
        mb = sample(child.pid)
        if mb is None:
            if not warned:
                mark("nomem")
                warned = True
        elif mb > cap:
            mark("rss %d %d" % (mb, cap))
            stop(child.pid, hard=True)
            child.wait()
            return 137

if __name__ == "__main__":
    sys.exit(main())
