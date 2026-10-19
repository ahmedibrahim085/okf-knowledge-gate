"""Which files a layer may open as a note, and a bounded read of one (ticket #109). Standard library only.

A note is opened only when, after symlinks are resolved, it is a regular file of at most okf_check.max_note_bytes. Kept apart
from okf_notes.py (which imports the validator) because okf-check asks for the cap before any layer runs: this file must not import the vendored validator
(a validator that cannot be imported is L1's finding, and must not stop the cap from being resolved).
The shell twin is note-guard-lib.sh. Run as `okf_guard.py freeze <src> <dst> <cap>`, it also builds the frozen copy every layer reads;
`okf_guard.py read <file> <cap>` prints one file read the same way (ignore-lib.sh reads .okfignore through it).
"""
import errno
import json
import os
import stat
import sys
from pathlib import Path

SCHEMA = Path(__file__).resolve().parent.parent / "config" / "okf-check-block.json"


class NoteRefused(OSError):
    """A path that must not be opened as a note. An OSError, so every reader's existing `except OSError` skips it."""


def note_cap(bundle=None, env=True):
    """The byte cap for one note: OKF_MAX_NOTE_BYTES (okf-check exports it), else okf_check.max_note_bytes in the
    bundle's okf-base.yaml, else the schema default. The default lives in config/okf-check-block.json only."""
    given = os.environ.get("OKF_MAX_NOTE_BYTES", "") if env else ""
    if given.isdigit() and int(given) > 0:
        return int(given)
    node = json.loads(SCHEMA.read_text(encoding="utf-8"))["keys"]["max_note_bytes"]
    base = os.path.join(str(bundle), "okf-base.yaml") if bundle is not None else ""
    if base and os.path.isfile(base):   # stat first: opening a FIFO here would block for ever
        try:
            from okf_validate import load_frontmatter   # late: only a bundle that has a manifest needs the YAML reader
            # read_note, not open(): the path was a regular file a moment ago and can be a FIFO now, which open() would wait on
            cfg = load_frontmatter(read_note(base, "utf-8", "replace", cap=node["default"]))   # the manifest is not exempt from the cap
            v = (cfg.get("okf_check") or {}).get("max_note_bytes") if isinstance(cfg, dict) else None
        except Exception:   # a missing or bad manifest is reported once by run_config; the default stays in force
            v = None
        if isinstance(v, int) and not isinstance(v, bool) and node["min"] <= v <= node["max"]:
            return v
    return node["default"]


def refusal(p, cap=None):
    """Why note `p` must not be opened, or None. Only stats: a device, a pipe or a socket is never opened to find out.

    A missing path or a dangling link gives None: callers skip those as they always did.
    """
    try:
        st = os.stat(p)   # follows a symlink: the target's type and size are what a reader would meet
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        return "not a regular file (device/pipe/...)"
    cap = cap or note_cap()
    if st.st_size > cap:
        return "larger than %d bytes (okf_check.max_note_bytes)" % cap
    return None


def read_note(p, encoding="utf-8-sig", errors="replace", cap=None, newline=None):
    """The text of note `p`, read as `open(p, encoding=...).read()` reads it (universal newlines unless `newline` says
    otherwise), but bounded.

    Raises NoteRefused for a path that is not a regular file or holds more than `cap` bytes. Checked on the stat BEFORE
    anything is opened, and again on the opened descriptor (the path can change in between); the read itself stops
    one character past the cap, so a file that grows while it is read cannot fill memory.
    """
    cap = cap or note_cap()
    why = refusal(p, cap)
    if why:
        raise NoteRefused(why)
    # O_NONBLOCK: opening a FIFO with no writer would block. O_NOCTTY: opening a tty must not become our terminal.
    fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOCTTY", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > cap:
            raise NoteRefused("not a regular file (device/pipe/...)" if not stat.S_ISREG(st.st_mode)
                              else "larger than %d bytes (okf_check.max_note_bytes)" % cap)
        with os.fdopen(fd, "r", encoding=encoding, errors=errors, newline=newline) as fh:
            fd = -1   # fdopen owns the descriptor now
            t = fh.read(cap + 1)
    finally:
        if fd != -1:
            os.close(fd)
    if len(t) > cap:
        raise NoteRefused("larger than %d bytes (okf_check.max_note_bytes)" % cap)
    return t


def _refuse_text(st_mode, size, cap):
    if not stat.S_ISREG(st_mode):
        return "not a regular file (device/pipe/...)"
    if size > cap:
        return "larger than %d bytes (okf_check.max_note_bytes)" % cap
    return None


def freeze_one(src, dst, cap, must_fit):
    """Copy `src` to `dst` with a read that cannot run away. Returns None when copied, "link" when a config file is over
    the cap (the caller links it: nothing here reads it), "gone" when it vanished, else the reason it was refused.

    The type and size are judged on the OPENED descriptor, not on the path: a path that was a note when the pre-scan
    stat it can be /dev/zero now, and the descriptor is what is read. O_NONBLOCK, so a FIFO opens at once; the read
    stops at cap + 1 bytes, so a file that grows while it is copied cannot fill memory or disk.
    """
    try:
        fd = os.open(src, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOCTTY", 0))
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ELOOP, errno.ENOTDIR):
            return "gone"   # removed or looping since the pre-scan: the fingerprint reports the change
        if exc.errno == errno.ENXIO:   # a socket cannot be opened for reading
            return "not a regular file (device/pipe/...)"
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return _refuse_text(st.st_mode, 0, cap)
        if st.st_size > cap:
            return "link" if not must_fit else _refuse_text(st.st_mode, st.st_size, cap)
        with os.fdopen(fd, "rb") as fh:
            fd = -1   # fdopen owns the descriptor now
            data = fh.read(cap + 1)
    finally:
        if fd != -1:
            os.close(fd)
    if len(data) > cap:
        return "link" if not must_fit else _refuse_text(st.st_mode, len(data), cap)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as out:
        out.write(data)
    os.chmod(dst, stat.S_IMODE(st.st_mode))
    os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))   # as cp -p: L3 and the derived-staleness layer compare modification times
    return None


def freeze_main(src_root, dst_root, cap):
    """Records on stdin, NUL-separated: `N<TAB>rel` (a note or the manifest: must fit the cap) or `C<TAB>rel` (other
    config: linked when over the cap). Prints, NUL-separated, `reason<TAB>rel` for every record refused now. Exit 1 on an
    error that is not a refusal, naming it on stderr; a file this user may not read is a refusal: a note is never dropped silently."""
    src_root = os.path.abspath(src_root)
    for rec in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0"):
        if not rec:
            continue
        kind, _, rel = rec.partition("\t")
        try:
            res = freeze_one(os.path.join(src_root, rel), os.path.join(dst_root, rel), cap, kind == "N")
            if res == "link":
                os.makedirs(os.path.dirname(os.path.join(dst_root, rel)), exist_ok=True)
                os.symlink(os.path.join(src_root, rel), os.path.join(dst_root, rel))
            elif res and res != "gone":
                sys.stdout.buffer.write(("%s\t%s\0" % (res, rel)).encode("utf-8", "surrogateescape"))
        except PermissionError as exc:   # a note this user may not read is a finding, never a skipped file (fail closed)
            sys.stdout.buffer.write(("cannot be read (%s)\t%s\0" % (exc.strerror or "permission denied", rel)).encode("utf-8", "surrogateescape"))
        except OSError as exc:
            sys.stderr.write("okfignore: cannot copy %s: %s\n" % (rel, exc.strerror or exc))
            return 1
    sys.stdout.flush()
    return 0


def read_main(p, cap):
    """Print the text of `p` (ignore-lib.sh reads .okfignore through this, #109 round 3). Exit 3 with the reason on stderr
    when it is refused and 4 when it cannot be read, with the reason on stdout in place of the text; 1 when it is gone."""
    try:
        t = read_note(p, "utf-8-sig", "replace", cap=cap)
    except NoteRefused as exc:
        sys.stdout.write(str(exc))
        return 3
    except FileNotFoundError:
        return 1
    except OSError as exc:
        sys.stdout.write("cannot be read (%s)" % (exc.strerror or exc))
        return 4
    sys.stdout.write(t)
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "freeze" and sys.argv[4].isdigit():
        sys.exit(freeze_main(sys.argv[2], sys.argv[3], int(sys.argv[4])))
    if len(sys.argv) == 4 and sys.argv[1] == "read" and sys.argv[3].isdigit():
        sys.exit(read_main(sys.argv[2], int(sys.argv[3])))
    sys.stderr.write("usage: okf_guard.py freeze <src root> <dst root> <cap bytes>  (records on stdin)\n"
                     "       okf_guard.py read <file> <cap bytes>\n")
    sys.exit(64)
