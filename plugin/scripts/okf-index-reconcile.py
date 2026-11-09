#!/usr/bin/env python3
"""okf-index-reconcile.py <bundle> [keep-list] — the declared counts of index.md against the files on disk.
With a keep-list (NUL-separated note paths, the set .okfignore keeps), only those notes are counted — the same set the
gate counts on its .okfignore mirror, so `--file` cannot flag a count the gate passes or pass one the gate flags.

Prints machine lines; okf-check owns the wording a person reads:
  MISMATCH <gate wording>     a declared count that does not match
  OK <n> <label>              a declared count that matches
  UNVERIFIABLE <n> <label>    a count no `type:` in the bundle can derive
  SKIP                        index.md declares no count
Exit 0 nothing to report, 1 a MISMATCH, 2 index.md could not be read, 3 the count set is not certain (an anomalous
note: see ANOMALY). The `--file` layer answers counts ONLY when the set is certain: any *.md the ignore rules do not
exclude that the full run would refuse or alias — a symlink, an unreadable file, a note over the cap — is reported as
ANOMALY <n> <first> and no count verdict is printed, so no wrong verdict can hide behind a difference the full run
would treat its own way. The gate path (no keep-list) is unchanged: it never sees ANOMALY.
Reads frontmatter with a regex and parses no YAML, so it needs nothing from the vendored PyYAML.
"""
import os
import pathlib
import re
import sys

args = sys.argv[1:]
bundle = pathlib.Path(args[0])
# --scan: the edit-time (--file) mode. WITHOUT it (the gate's run_index call, bundle alone) this script is byte-identical
# to the version before the anomaly work: no anomaly loop, no ANOMALY line, no .git special case (the gate's mirror has
# none of those to see).
scan = "--scan" in args[1:]
pos = [a for a in args[1:] if not a.startswith("--")]
kept = set(open(pos[0], encoding="utf-8", errors="surrogateescape").read().split("\0")) - {""} if len(pos) > 0 and scan else None
ignored = set(open(pos[1], encoding="utf-8", errors="surrogateescape").read().split("\0")) - {""} if len(pos) > 1 and scan else None
# The SAME concept set L1 counts: everything except the two files OKF v0.2
# reserves. README.md is NOT reserved — it carries frontmatter and L1 counts it,
# which is why L1 reports 51 for the lessons bundle where the untracked-file
# count is 50. Excluding it here produced a reconciler that disagreed with the
# conformance layer standing directly above it in the same report, and two
# definitions of "concept" inside one tool are worse than no check at all.
RESERVED = {"index.md", "log.md"}
def somebodys_note(rel):
    # .git is nobody's note: the gate's mirror prunes it (find -name .git -prune), and the ignore list prunes it the
    # same way, so in --scan mode both walks skip any path with a .git part.
    return ".git" not in pathlib.PurePosixPath(rel).parts


if kept is None:
    concepts = [p for p in bundle.rglob("*.md")
                if p.name not in RESERVED and p.is_file() and (not scan or somebodys_note(p.relative_to(bundle).as_posix()))]
else:
    # somebodys_note is redundant ON PURPOSE (belt and braces): okfignore_list already prunes .git when it builds the
    # list, and this keeps the invariant true even if that builder ever changes.
    concepts = [bundle / k for k in kept if k.endswith(".md") and pathlib.PurePosixPath(k).name not in RESERVED
                and (bundle / k).is_file() and somebodys_note(k)]


cap = int(os.environ.get("OKF_MAX_NOTE_BYTES") or 0)
anom = []
for p in (bundle.rglob("*.md") if scan else ()):
    rel = p.relative_to(bundle).as_posix()
    if rel in RESERVED or ".git" in p.relative_to(bundle).parts or (ignored is not None and rel in ignored):
        continue   # not a note, inside .git (the gate's walk prunes it, so it is nobody's anomaly either), or the
        # ignore rules already exclude it: the full run never sees it either
    if p.is_symlink() or not p.is_file() or not os.access(p, os.R_OK) or (cap and p.is_file() and p.stat().st_size > cap):
        anom.append(rel)
if anom:
    print(f"ANOMALY {len(anom)} {sorted(anom)[0]}")
    sys.exit(3)


def declared_type(p):
    try:
        t = p.read_text(encoding="utf-8-sig", errors="replace")   # a BOM before the fence is no content, as L1 reads it
    except OSError:
        return None
    if not t.startswith("---"):
        return None
    end = t.find("\n---", 3)
    m = re.search(r"^type:\s*(.+?)\s*$", t[:end if end > 0 else len(t)], re.M)
    return m.group(1).strip().strip("\"'") if m else None


types = {}
for p in concepts:
    t = declared_type(p)
    if t:
        types[t.lower()] = types.get(t.lower(), 0) + 1

index_path = bundle / "index.md"
try:
    idx = index_path.read_text(encoding="utf-8", errors="replace")
except OSError:
    sys.exit(2)

# The declaration is a whole BOLD line, so a bold phrase inside a sentence is
# not mistaken for a total.
bold = None
for line in idx.splitlines():
    s = line.strip()
    if s.startswith("**") and s.endswith("**") and re.search(r"\d", s):
        bold = s[2:-2]
        break

bad = []
if bold is None:
    print("SKIP index.md declares no counts")
else:
    good, unknown = [], []
    for seg in re.split(r"[·|,]", bold):
        m = re.match(r"^\s*(\d+)\s+(.+?)\s*\.?\s*$", seg)
        if not m:
            continue
        n, label = int(m.group(1)), m.group(2).strip().lower()
        singular = label[:-1] if label.endswith("s") else label
        if singular in ("concept", "note", "file"):
            actual = len(concepts)
        elif singular in types:
            actual = types[singular]
        else:
            # Not derivable from any `type:` in the bundle. Saying so is the honest
            # outcome; silently treating it as verified would be the failure this
            # whole rule exists to stop.
            unknown.append(f"{n} {label}")
            continue
        (good if n == actual else bad).append((n, label, actual))

    for n, label, actual in bad:
        # "{actual} on disk", not "{actual} are on disk": the count can be 1, and
        # "1 are on disk" in the line an operator reads is a defect in the report.
        print(f"MISMATCH index.md claims {n} {label}; {actual} on disk")
    for n, label, actual in good:
        print(f"OK {n} {label}")
    for u in unknown:
        print(f"UNVERIFIABLE {u}")

sys.exit(1 if bad else 0)
