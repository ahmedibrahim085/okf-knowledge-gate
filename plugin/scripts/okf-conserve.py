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

A note .okfignore excludes is not part of the bundle, so a line that moved into one counts as removed: it is LOST unless
the same line also sits in a note the bundle counts. The list of counted notes is okf-check's (okfignore_list, the matcher
every layer reads), passed in OKF_KEEP_LIST. The same matcher is asked about the notes the ref still had, by path
(okf-check --ignore-filter), so an ignored note is not read on either side: a line moved inside an ignored folder is no
loss, while deleting a note the bundle counts is still a LOST line.

Not counted, because they are not knowledge: blank lines, whitespace-only changes, lines with no letter or digit (a table
rule, a fence) and the frontmatter (a new date is churn). Lines are compared with runs of whitespace collapsed.

The report is advisory (exit 0); with --fail-lost a LOST line is exit 1. Exit 2: not in a git repository, an unknown ref, or
a --deleted file that cannot be read.

Usage (from okf-check): okf-conserve.py <bundle> <ref> <version> <json 0|1> <fail-lost 0|1> [<deleted file>]
       environment:
         OKF_KEEP_LIST  the PATH of a file holding a NUL-separated list of the notes .okfignore leaves in, as paths
                        relative to the bundle; unset or empty means every note counts
         OKF_CHECK_BIN  the okf-check to ask which notes .okfignore excludes (its internal --ignore-filter mode), so a
                        note that was deleted is judged by the same matcher as one that is still on disk
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


# index.md and log.md are bundle files, not notes: okf-check's "every note excluded" refusal skips them at any depth
# (ignore-lib.sh counts "kept" without them), so the refusal here counts a note the same way.
NOT_NOTES = ("index.md", "log.md")


def is_note(name):
    base = name.rsplit("/", 1)[-1]
    return base.endswith(".md") and base not in NOT_NOTES


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
            for line in read_note(deleted_file, "utf-8", "surrogateescape", root=None).split("\n"):   # --deleted names a file of the user's, not a note
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("line:"):
                    declared_lines.add(norm(line[5:].encode("utf-8", "surrogateescape").decode("utf-8", "replace")))
                else:
                    declared_notes.add(line)
        except OSError as e:
            return fail(f"cannot read {deleted_file} ({e.strerror or type(e).__name__})", 2)

    # The bundle as it is now: every line of every note on disk, tracked or not, minus the notes .okfignore leaves out.
    # That list comes from okf-check (okfignore_list, the matcher every layer reads), so a line that now lives only in an
    # ignored note is not in the bundle: it reads LOST like a deletion, which is what an archive move is.
    counted = None
    keep_list = os.environ.get("OKF_KEEP_LIST", "")
    if keep_list:
        try:
            with open(keep_list, "rb") as fh:
                raw = fh.read().decode("utf-8", "surrogateescape")
        except OSError as e:
            return fail(f"cannot read the list of counted notes ({e.strerror or type(e).__name__})", 2)
        counted = {os.path.join(real_bundle, rel) for rel in raw.split("\0") if rel}
    corpus = set()
    md_on_disk = 0
    for root, dirs, files in os.walk(real_bundle):
        dirs[:] = [d for d in dirs if d != ".git" and not os.path.islink(os.path.join(root, d))]
        for f in files:
            if f.endswith(".md"):
                md_on_disk += is_note(f)
                path = os.path.join(root, f)
                if counted is not None and path not in counted:
                    continue
                try:
                    corpus.update(norm(x) for x in read_note(path, "utf-8", "replace", root=real_bundle).split("\n"))
                except OSError:
                    pass

    def list_ref_notes():
        """The notes the ref holds under the bundle, as paths from the repository root. A plain path, not a pathspec with magic: `git ls-tree` refuses
        `:(glob)`, and its non-zero exit was read here as "the ref had no notes" — a check that can never fire. Names come
        NUL-separated (-z): without it git quotes a name that is not plain ASCII or holds a newline (`"B/caf\303\251.md"`),
        and a quoted name does not end in `.md`, so the note was counted as absent. Filtered in Python; a failure is loud
        (the caller stops with exit 2), never an answer."""
        rc, out = git(real_top, "ls-tree", "-r", "--name-only", "-z", ref, "--", rel_bundle or ".", errors="surrogateescape")
        if rc != 0:
            detail = out.strip().splitlines()
            return None, "git ls-tree %s failed (exit %d%s)" % (ref, rc, ": " + detail[-1] if detail else "")
        return [x for x in out.split("\0") if is_note(x)], None

    def ignored_notes(notes):
        """Which of these note paths (relative to the bundle) .okfignore excludes, asked of okf-check's internal
        --ignore-filter: the answer comes from the one matcher every layer reads, so this report cannot drift from them.
        Returns (set, None) on an answer, or (None, why) when the question could not be put."""
        if not notes:
            return set(), None
        binary = os.environ.get("OKF_CHECK_BIN", "")
        if not binary:
            return None, "--conserve needs okf-check to apply .okfignore, and this run did not name it (OKF_CHECK_BIN)"
        payload = ("\0".join(notes) + "\0").encode("utf-8", "surrogateescape")
        try:
            p = subprocess.run([binary, bundle, "--ignore-filter"], input=payload, capture_output=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as e:
            return None, f"okf-check could not say which notes .okfignore excludes ({type(e).__name__})"
        if p.returncode != 0:
            detail = p.stderr.decode("utf-8", "replace").strip().splitlines()
            return None, "okf-check could not say which notes .okfignore excludes (exit %d%s)" % (
                p.returncode, ": " + detail[-1] if detail else "")
        return {x for x in p.stdout.decode("utf-8", "surrogateescape").split("\0") if x}, None

    try:
        removed, added = removed_lines(real_top, ref, rel_bundle)
    except RuntimeError as e:
        return fail(str(e), 2)

    # The ref side is filtered by the same matcher, asked about a PATH: the list of counted notes comes from the files on
    # disk, so it cannot judge a note that was deleted (it would stop a deleted counted note from being LOST). A line that
    # lived only in an ignored note was never in the bundle; reorganising that note, or deleting it, loses nothing.
    ref_notes = sorted({os.path.relpath(os.path.join(real_top, p), real_bundle) for p, _n, _t, _h in removed})
    ignored, err = ignored_notes(ref_notes)
    if err:
        return fail(err, 2)

    # .okfignore that leaves no note in: the report would print PASS 0 line(s) removed for a bundle nobody looked at — a
    # pass for lines that really were removed, on the commit that added the pattern. The question is this report's own,
    # wider than the gate's: did content that existed get lost? So a note on the disk OR a note the ref still holds (the
    # bundle was emptied on the commit under test) is a comparison nobody made. A bundle that never held a note answers
    # exit 0, as the gate does for it (its own output: "ignore: 0 file(s) excluded", "L1 PASS 0 concepts").
    # "Leaves no note in" means every note, so a note at the ref that .okfignore does not exclude is a note the report can
    # judge: deleting it is a plain LOST, not a refusal (base answered LOST/exit 1 there, and it still does).
    if counted is not None and not any(is_note(c) for c in counted):
        at_ref, err = list_ref_notes()
        if err:
            return fail(err, 2)
        at_ref = [os.path.relpath(os.path.join(real_top, p), real_bundle) for p in at_ref]
        ignored_at_ref, err = ignored_notes(at_ref)
        if err:
            return fail(err, 2)
        if (md_on_disk or at_ref) and all(n in ignored_at_ref for n in at_ref):
            return fail(os.environ.get("OKF_IGNORE_ALL_WHY", ".okfignore excludes every note - nothing was checked (not a pass)"), 2)

    fm_cache = {}
    def in_frontmatter(path, n):
        if path not in fm_cache:
            rc, text = git(real_top, "show", f"{ref}:{path}")
            fm_cache[path] = frontmatter_lines(text) if rc == 0 else set()
        return n in fm_cache[path]

    kinds = {"moved": [], "declared": [], "changed": [], "lost": []}
    pending = {}   # hunk id -> entries that may pair with an added line
    for path, n, text, hunk in removed:
        if os.path.relpath(os.path.join(real_top, path), real_bundle) in ignored:
            continue   # not in the bundle at the ref either: nobody lost this line
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
