"""Which files a layer may open as a note, and a bounded read of one. Standard library only.

A note is opened only when, after symlinks are resolved, it is a regular file of at most okf_check.max_note_bytes. Kept apart
from okf_notes.py (which imports the validator) because okf-check asks for the cap before any layer runs: this file must not import the vendored validator
(a validator that cannot be imported is L1's finding, and must not stop the cap from being resolved).
The shell twin is note-guard-lib.sh. Run as `okf_guard.py freeze <src> <dst> <cap>`, it also builds the frozen copy every layer reads;
`okf_guard.py read <file> <cap>` prints one file read the same way (ignore-lib.sh reads .okfignore through it).
"""
import errno
import functools
import json
import os
import re
import stat
import sys
import unicodedata
from pathlib import Path

SCHEMA = Path(__file__).resolve().parent.parent / "config" / "okf-check-block.json"
# Controls (C0, DEL, C1), the bidi controls that reorder the text around a name on a terminal (U+061C, U+200E, U+200F, U+202A to
# U+202E, U+2066 to U+2069), and what surrogateescape makes of a byte that is not UTF-8.
_UNSAFE = re.compile("[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069\udc80-\udcff]")
_BAD_BYTE = re.compile("[\udc80-\udcff]")


def _spell(m):
    c = ord(m.group())
    if 0xDC80 <= c <= 0xDCFF:
        c -= 0xDC00   # the byte surrogateescape kept
    return "\\x%02x" % c if c < 0x100 else "\\u%04x" % c


def shown(name, controls=True):
    """`name` as a report prints it: a byte that is not UTF-8, a control character (ESC, CR, TAB, the C1 set) and a bidi control
    are spelled \\xNN (\\uNNNN above U+00FF).

    A name read from disk (Path.rglob, argv, a NUL list) is a str whose undecodable bytes are lone surrogates
    (surrogateescape): printed to a pipe they are the raw byte, and in --json an unreadable \\udcNN. The same name decoded
    with errors="replace" is U+FFFD and no longer opens the file: decode names with surrogateescape, show them with this.
    A control character in a name would reach the terminal as an escape sequence, and a bidi override would reorder what
    follows it, so the text never carries one. Apply it to the name or the text field, never to a whole formatted line (its
    line breaks and indent are layout, not name).
    `controls=False` spells only the bytes that are not UTF-8: for content that is not a name (--json keeps a control
    character in a quoted claim as its JSON escape), where a lone surrogate would be invalid JSON text.
    Any other lone surrogate in a message is left as it was.
    """
    return (_UNSAFE if controls else _BAD_BYTE).sub(_spell, name)


def show_main():
    """stdin to stdout, each line through shown() (okf-check's say() sends a line here when it holds a byte that is not UTF-8
    or a control character); the line breaks themselves stay."""
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    sys.stdout.buffer.write("\n".join(shown(line) for line in text.split("\n")).encode("utf-8"))
    return 0


def obsidian_path(base, rel):
    """The path below folder `base` that the link path `rel` names by Obsidian's rule, or None.

    Each part is the name in its folder spelled exactly so, else the one name equal to it under lower() (okf-export's
    case rule) after Unicode NFC normalisation (macOS may store a name decomposed; okf-export's resolve() uses the same rule).
    Two such names (Notes.md and notes.md on a case-sensitive disk) are ambiguous: None, okf-export does not pick one
    either. A part that matches no name is None too: the verdict comes from the rule, not from the disk, whose own case
    folding is wider (macOS equates straße with STRASSE). The one exception: a part whose folder cannot be listed is
    taken as written and the caller's isfile() decides. `..` is left to the OS, so after a folder link it is the link
    target's parent, as open() reads it; `..` after a part that is not there drops it by name, as realpath() does
    (`sub/../new` with no sub/ folder is new).
    """
    stack, missing = [base], 0   # missing: how many trailing parts name nothing on disk
    for part in rel.replace(os.sep, "/").split("/"):
        if part in ("", "."):
            continue
        if part == ".." and missing:
            stack.pop()   # `..` after a part that is not there: dropped by name, as realpath() drops it
            missing -= 1
            continue
        if part != ".." and not missing:
            try:
                exact, folded = _names(stack[-1])
            except OSError:
                exact = folded = None
            if exact is not None and part not in exact:
                hits = folded.get(_fold(part), ())
                if len(hits) > 1:
                    return None
                if hits:
                    part = hits[0]
                else:
                    missing += 1
        elif part != "..":
            missing += 1
        stack.append(os.path.join(stack[-1], part))
    return None if missing else stack[-1]


def case_exact(p, base=None, follow=True):
    """Does every component of `p` appear on disk with the case as written? With `base`, only the part below the folder
    `p` and `base` share is judged.

    APFS and NTFS are case-INSENSITIVE by default, so `exists()` answers yes
    for a name that is nowhere on the filesystem: a concept citing `Notes.MD`
    against a repo holding `notes.md` was reported CONFIRMED. The tool then
    asserts it verified a path that does not exist as written — and the whole
    point of the CONFIRMED verdict is that it was checked, not approximated.
    The citation rule of okf-verify (D-11) and of L3's sources[].resource.
    `base` is the folder the citation is relative to: how the user typed the bundle path, and the folders above the
    one the two paths share, are not the citation (`okf-check .` with `../x.txt` judges `x.txt` only).
    Both paths are made absolute first: a relative path holding `..` would otherwise be looked for in a listing.

    A component that is a symlink is followed: its target is judged too (`follow=False`: only the names as written).

    Returns True when we CANNOT tell (unreadable parent): a verdict must never
    be manufactured out of a failed look. (D-11)
    """
    p = os.path.abspath(p)
    root = os.path.commonpath([p, os.path.abspath(base)]) if base is not None else Path(p).anchor
    cur, parts = Path(root), Path(os.path.relpath(p, root)).parts
    for part in (() if parts == (".",) else parts):
        try:
            if part not in _listing(str(cur)):
                return False
        except OSError:
            return True
        cur = cur / part
        if follow and os.path.islink(cur):
            # The target's spelling is part of the citation too: `l.txt -> SRC.TXT` resolves on a case-insensitive disk
            # and dangles on Linux. The target is judged like a cited path (below `base`). A `..` in the link text climbs
            # from the folder's REAL place, which is not where its spelling leads when the folder is itself a link; the
            # path is then spelled in real names, so `base` is too (else the typed spelling above the bundle is judged).
            # A link that dangles or loops is not judged.
            try:
                text = os.readlink(cur)
                folder, tbase = os.path.dirname(cur), base
                if ".." in Path(text).parts:
                    folder, tbase = os.path.realpath(folder), os.path.realpath(base) if base is not None else None
                target = os.path.join(folder, text)
                judge = os.path.samefile(target, cur)
            except OSError:
                judge = False
            if judge and not case_exact(target, tbase):
                return False
    return True


def _fold(name):
    # lower(), as okf-export and Obsidian: casefold() would also match ß to ss.
    return unicodedata.normalize("NFC", name).lower()


@functools.lru_cache(maxsize=4096)
def _listing(folder):
    # One listing per folder and run: 10,000 citations into one folder of 10,000 notes listed it 10,000 times.
    return frozenset(os.listdir(folder))


@functools.lru_cache(maxsize=4096)
def _names(folder):
    # One listing per folder and run: a bundle with thousands of links lists each folder once.
    names = os.listdir(folder)
    folded = {}
    for n in names:
        folded.setdefault(_fold(n), []).append(n)
    return frozenset(names), {k: tuple(v) for k, v in folded.items()}


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


def read_main(p, cap, trim=False):
    """Print the text of `p` (ignore-lib.sh reads .okfignore through this). Exit 3 with the reason on stderr
    when it is refused and 4 when it cannot be read, with the reason on stdout in place of the text; 1 when it is gone.

    `trim` (the `lines` command): each line without the white space around it: space, tab, CR, VT, FF, POSIX [:space:]
    in the C locale. ignore-lib.sh trimmed in bash, where each strip tried every prefix or suffix of the line: a line of
    80 KB of spaces took over a minute. One pass here is linear in the file."""
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
    if trim:
        t = "\n".join(line.strip(" \t\r\v\f") for line in t.split("\n"))
    sys.stdout.write(t)
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "freeze" and sys.argv[4].isdigit():
        sys.exit(freeze_main(sys.argv[2], sys.argv[3], int(sys.argv[4])))
    if len(sys.argv) == 4 and sys.argv[1] in ("read", "lines") and sys.argv[3].isdigit():
        sys.exit(read_main(sys.argv[2], int(sys.argv[3]), trim=sys.argv[1] == "lines"))
    if len(sys.argv) == 2 and sys.argv[1] == "show":
        sys.exit(show_main())
    sys.stderr.write("usage: okf_guard.py freeze <src root> <dst root> <cap bytes>  (records on stdin)\n"
                     "       okf_guard.py read|lines <file> <cap bytes>\n"
                     "       okf_guard.py show  (text on stdin, controls and non-UTF-8 bytes spelled \\xNN)\n")
    sys.exit(64)
