#!/usr/bin/env python3
"""okf-conserve.py — the conservation check, `okf-check <bundle> --conserve <ref>` (public okf-knowledge-gate#16).

A change that reorganises notes (a split, a section moved to a companion note, a merge) should keep every line. Each line
removed from the bundle since <ref> (`git diff -w <ref>`, the working tree included) is judged, in this order:

    MOVED     the line appears somewhere in the bundle now (any note, an untracked one included)
    DECLARED  the deletion was declared: the note is named in --deleted FILE or in an `OKF-Deleted: <note>` trailer of a
              commit since <ref>, or the line itself is (`line: <text>` in the file)
    CHANGED   an edit in place: a line added at the same place in the same hunk replaces it (paired by position, so ten
              lines compressed into two are two CHANGED and eight LOST)
    LOST      none of the above

Not counted, because they are not knowledge: blank lines, whitespace-only changes, lines with no letter or digit (a table
rule, a fence) and the frontmatter (a new date is churn). Lines are compared with runs of whitespace collapsed.

The report is advisory (exit 0); with --fail-lost a LOST line is exit 1. Exit 2: not in a git repository, an unknown ref, or
a --deleted file that cannot be read.

Usage (from okf-check): okf-conserve.py <bundle> <ref> <version> <json 0|1> <fail-lost 0|1> [<deleted file>]
"""
import json
import os
import re
import subprocess
import sys

sys.path[:0] = [os.environ.get("OKF_SCRIPTS_DIR", ""), os.environ.get("OKF_VENDOR_DIR", "")]
from okf_notes import read_note, shown  # noqa: E402  (bounded reads)

HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
CAP = 50   # entries per kind in the text report; --json has every one
WIDTH = 100   # characters of each line in the text report; --json has the whole line


def short(t):
    return t if len(t) <= WIDTH else t[:WIDTH - 1] + "…"


def git(top, *args, errors="replace"):
    # errors="surrogateescape" for a list of file names: a name decoded with "replace" no longer opens the file (U+FFFD for a
    # non-UTF-8 byte), and the later `:(literal)path` pathspec then matches nothing.
    try:
        p = subprocess.run(["git", "-C", str(top), *args], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, f"git could not run ({type(e).__name__})"
    return p.returncode, p.stdout.decode("utf-8", errors)


def norm(line):
    return " ".join(line.split())


def counts(line):
    """Is this line knowledge? Not blank and not markup only (a table rule, a fence, a lone dash)."""
    return any(c.isalnum() for c in line)


def frontmatter_lines(text):
    """The 1-based line numbers of the frontmatter block (both --- lines included), or an empty set."""
    rows = text.split("\n")
    if not rows or rows[0].strip() != "---":
        return set()
    for j in range(1, len(rows)):
        if rows[j].strip() == "---":
            return set(range(1, j + 2))
    return set()


def pathspec(rel_bundle):
    """The notes of the bundle as a git pathspec: only notes are compared (a data file or okf-base.yaml is not knowledge)."""
    lit = re.sub(r"([*?\[\]\\])", r"\\\1", rel_bundle)   # a bundle path holding glob characters is still literal
    return f":(glob){lit + '/' if lit else ''}**/*.md"


def removed_lines(top, ref, rel_bundle):
    """[(path relative to the repo top, old line number, text, hunk id)] removed since ref, and {hunk id: [added texts]}.

    The changed notes are listed with -z (a name is never quoted or cut at a tab), then each is diffed alone and only its
    hunks are read: a removed body line that starts with `-- ` cannot be taken for a file header, and the user's diff
    settings (mnemonicPrefix, noprefix, external tools, colour) are overridden.
    """
    base = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-renames", "--no-ext-diff", "--no-textconv"]
    rc, out = git(top, *base, "-z", "--name-only", ref, "--", pathspec(rel_bundle), errors="surrogateescape")
    if rc != 0:
        raise RuntimeError(f"git diff {ref} failed")
    removed, added, hunk = [], {}, 0
    for path in (x for x in out.split("\0") if x):
        rc, d = git(top, *base, "--src-prefix=a/", "--dst-prefix=b/", "-U0", "-w", ref, "--", f":(literal){path}")
        if rc != 0:
            raise RuntimeError(f"git diff {ref} -- {path} failed")
        old_no, in_hunk = 0, False
        for line in d.split("\n"):
            m = HUNK.match(line)
            if m:
                hunk += 1
                old_no, in_hunk = int(m.group(1)), True
                added[hunk] = []
                continue
            if not in_hunk:
                continue   # the header lines before the first hunk
            if line.startswith("-"):
                removed.append((path, old_no, line[1:], hunk))
                old_no += 1
            elif line.startswith("+"):
                added[hunk].append(line[1:])
    return removed, added


def trailer_notes(top, ref):
    """Notes named by `OKF-Deleted: <note>` trailers in the commits since ref (one per line, a path relative to the bundle)."""
    # git's own trailer parser: `OKF-Deleted:` counts in the trailer block at the end of a message, not in its prose.
    rc, out = git(top, "log", "--format=%(trailers:key=OKF-Deleted,valueonly)", f"{ref}..HEAD", errors="surrogateescape")
    return {x.strip() for x in out.split("\n") if x.strip()} if rc == 0 else set()


def main(argv):
    bundle, ref, version, as_json, fail_lost = argv[1], argv[2], argv[3], argv[4] == "1", argv[5] == "1"
    deleted_file = argv[6] if len(argv) > 6 else ""

    def fail(msg, code):
        if as_json:
            print(json.dumps({"bundle": bundle, "exit": code, "error": msg}))
        else:
            print(f"okf-check: --conserve: {msg}", file=sys.stderr)
        return code

    rc, top = git(bundle, "rev-parse", "--show-toplevel")
    top = top.strip()
    if rc != 0 or not top:
        return fail(f"{bundle} is not inside a git repository, so there is no history to compare with", 2)
    rc, _ = git(top, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if rc != 0:
        return fail(f"{ref} is not a commit in {top}", 2)
    real_bundle, real_top = os.path.realpath(bundle), os.path.realpath(top)
    rel_bundle = os.path.relpath(real_bundle, real_top)
    rel_bundle = "" if rel_bundle == "." else rel_bundle

    declared_notes, declared_lines = trailer_notes(top, ref), set()
    if deleted_file:
        try:
            # A note name keeps its bytes (surrogateescape, as git's list of names is read); a `line:` entry is text and is
            # decoded as the diff text is (replace), so a line holding a byte that is not UTF-8 still matches.
            for line in read_note(deleted_file, "utf-8", "surrogateescape").split("\n"):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("line:"):
                    declared_lines.add(norm(line[5:].encode("utf-8", "surrogateescape").decode("utf-8", "replace")))
                else:
                    declared_notes.add(line)
        except OSError as e:
            return fail(f"cannot read {deleted_file} ({e.strerror or type(e).__name__})", 2)

    # The bundle as it is now: every line of every note on disk, tracked or not.
    corpus = set()
    for root, dirs, files in os.walk(real_bundle):
        dirs[:] = [d for d in dirs if d != ".git" and not os.path.islink(os.path.join(root, d))]
        for f in files:
            if f.endswith(".md"):
                try:
                    corpus.update(norm(x) for x in read_note(os.path.join(root, f), "utf-8", "replace").split("\n"))
                except OSError:
                    pass

    try:
        removed, added = removed_lines(real_top, ref, rel_bundle)
    except RuntimeError as e:
        return fail(str(e), 2)

    fm_cache = {}
    def in_frontmatter(path, n):
        if path not in fm_cache:
            rc, text = git(real_top, "show", f"{ref}:{path}")
            fm_cache[path] = frontmatter_lines(text) if rc == 0 else set()
        return n in fm_cache[path]

    kinds = {"moved": [], "declared": [], "changed": [], "lost": []}
    pending = {}   # hunk id -> entries that may pair with an added line
    for path, n, text, hunk in removed:
        if not counts(text) or in_frontmatter(path, n):
            continue
        note = os.path.relpath(path, rel_bundle) if rel_bundle else path
        entry = {"note": shown(note), "line": n, "text": text.strip()}
        if norm(text) in corpus:
            kinds["moved"].append(entry)
        elif note in declared_notes or norm(text) in declared_lines:
            kinds["declared"].append(entry)
        else:
            pending.setdefault(hunk, []).append(entry)
    for hunk, entries in pending.items():
        repl = [a.strip() for a in added.get(hunk, []) if counts(a)]
        for i, entry in enumerate(entries):
            if i < len(repl):
                kinds["changed"].append(dict(entry, new=repl[i]))
            else:
                kinds["lost"].append(entry)
    for k in kinds:
        kinds[k].sort(key=lambda e: (e["note"], e["line"]))

    total = sum(len(v) for v in kinds.values())
    lost = len(kinds["lost"])
    code = 1 if (fail_lost and lost) else 0
    if as_json:
        print(json.dumps({"bundle": bundle, "exit": code, "conserve": {"ref": ref, "removed": total, **kinds}}))
        return code
    word = "PASS" if not lost else ("FAIL" if fail_lost else "WARN")
    print(f"okf-check {version} — conservation of {bundle} since {ref}")
    print(f"  Conserve         {word:6} {total} line(s) removed: {len(kinds['moved'])} MOVED, {len(kinds['changed'])} CHANGED, "
          f"{lost} LOST, {len(kinds['declared'])} declared")
    for e in kinds["lost"][:CAP]:
        print(f"    LOST     {e['note']}:{e['line']}  {short(e['text'])}")
    if lost > CAP:
        print(f"    ... and {lost - CAP} more LOST line(s) (--json lists every one)")
    for e in kinds["changed"][:CAP]:
        print(f"    CHANGED  {e['note']}:{e['line']}  {short(e['text'])}  ->  {short(e['new'])}")
    if len(kinds["changed"]) > CAP:
        print(f"    ... and {len(kinds['changed']) - CAP} more CHANGED line(s) (--json lists every one)")
    if lost:
        print("  A LOST line was removed and is nowhere in the bundle now. Put it back, move it to the note where it belongs, or")
        print("  declare the deletion (--deleted FILE, or an OKF-Deleted: <note> trailer in the commit).")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
