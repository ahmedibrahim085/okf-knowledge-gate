#!/usr/bin/env python3
"""okf-scoped.py <bundle> <rel> [--strict-trust] — L1 and Trust for ONE note, for `okf-check <bundle> --file <note>`.

An edit hook (okf-knowledge-gate#8) needs the edited note checked in well under a second, so this parses one note's
YAML instead of the whole bundle's. It copies no rule: L1 calls the vendored validator's own per-file checks, in
the order its validate() calls them, then its check_links over the bundle's note list (links are read, no YAML is
parsed) and keeps only this note's findings; Trust calls okf-trust.py's findings_for. scoped.test.sh compares the
result with a full run's findings for the same note, so a drift between the two shows up as a failing test.

Output: one line per finding, `<rel>: L1 error: ...`, `<rel>: L1 warning: ...`, `<rel>: Trust warning: ...`,
`<rel>: Trust advisory: ...`, `<rel>: Trust error: ...` (the loader refused the note for its size); nothing for a clean note.
Exit 1: an L1 error, a Trust error, or with --strict-trust a Trust warning or advisory or a near-miss actor
(okf-check's own --strict-trust rule, which counts warnings and advisories as the whole-bundle run does). Exit 0:
otherwise. Exit 2: could not run.
Run with the vendored PyYAML on the path (okf-check does this through py_with_vendor).
"""
import importlib.util
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True   # a direct run must not leave scripts/__pycache__ in the installed plugin (plugin.test.sh Z-2)
sys.path.insert(0, str(HERE.parent / "vendor"))
sys.path.insert(0, str(HERE))
import okf_validate as v  # noqa: E402
from okf_guard import OUTSIDE_WHY, read_note, refusal, shown  # noqa: E402  (stat-based refusal and a bounded read)

_spec = importlib.util.spec_from_file_location("okf_trust", HERE / "okf-trust.py")
trust = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(trust)

# The validator's near-miss wording, as okf-check's --strict-trust counts it: read from the validator, not typed again.
NEAR_MISS = v.NEAR_MISS_WORDING


def main(argv: list) -> int:
    bundle, rel, strict = Path(argv[1]), argv[2], "--strict-trust" in argv[3:]
    path = bundle / rel
    why = refusal(path, root=bundle)   # the target note: the bash side has judged it already; this is the same rule for a direct caller
    if why:
        print(f"{rel}: L1 error: refused, {why}: {'not read' if why == OUTSIDE_WHY else 'skipped'}")   # the line shape the edit hook warns on
        return 1
    report = v.Report()
    if path.name == "index.md":
        v.check_index(path, rel, is_root=(path.parent == bundle), report=report)
    elif path.name == "log.md":
        v.check_log(path, rel, report)
    else:
        v.check_concept(path, rel, bundle, report)
    # The validator's own walker (validate()): the link check must know every note to tell a broken link.
    # .okfignore: okf-check passes the notes it keeps (NUL-separated, relative); the full run links against only those.
    keep = None
    if os.environ.get("OKF_KEEP_LIST"):
        keep = {x for x in open(os.environ["OKF_KEEP_LIST"], encoding="utf-8", errors="surrogateescape").read().split("\0") if x}
    # refusal(): a sibling that is a device or over the cap is never read for its links
    v.check_links(bundle, sorted(p for p in bundle.rglob("*.md") if p.is_file() and refusal(p, root=bundle) is None
                                 and (keep is None or str(p.relative_to(bundle)) in keep)), report)
    mine = len(rel) + 2
    errors = [m[mine:] for m in report.errors if m.startswith(rel + ": ")]
    warnings = [m[mine:] for m in report.warnings if m.startswith(rel + ": ")]

    rows, too_large = [], None
    if path.name not in ("index.md", "log.md"):   # Trust reads concepts only, as okf-trust.py does
        try:
            raw, _ = v.split_frontmatter(read_note(path, "utf-8-sig", "strict", root=bundle))
            meta = v.load_frontmatter(raw) if raw is not None else None
        except v.AliasBombError as e:   # the loader's size cap: its trust claims are unread, which is not "no finding" (L1 reports the cap too)
            meta, too_large = None, str(e)
        except (OSError, UnicodeDecodeError, trust.yaml.YAMLError, ValueError):
            meta = None   # L1 already reports an unreadable or malformed note
        if isinstance(meta, dict):
            # list(): findings_for is a generator, and the printing loop below already walks it. Read twice, a
            # generator is empty the second time — the strict test saw no warning and exited 0 on a note whose
            # Trust warning it had just printed.
            rows = list(trust.findings_for(meta))

    for e in errors:
        print(f"{rel}: L1 error: {e}")
    for w in warnings:
        print(f"{rel}: L1 warning: {w}")
    if too_large:
        print(f"{rel}: Trust error: the note was too large to read, so its trust claims were not checked: {too_large}")
    for severity, entry, reason in rows:
        # shown(): the reason quotes the note's own `by` text, and a control character in it would forge a report line
        #. The text report spells it; the JSON copy in the whole run keeps the JSON escape.
        print(f"{rel}: Trust {severity}: {entry} {shown(reason)}")
    # --strict-trust counts Trust warnings AND advisories, as the whole-bundle run does (its TRUST_FINDINGS is
    # warnings + advisories): an agent note verified by a human is the advisory form of the same claim, and the
    # whole-bundle run fails it. The near-miss actor wording is the validator's own, never typed again.
    strict_hit = strict and (any(s in ("warning", "advisory") for s, _, _ in rows)
                             or any(NEAR_MISS in w for w in warnings))
    return 1 if errors or too_large or strict_hit else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:   # a crash must never read as "L1 error" (exit 1): it is "could not run"
        print(f"okf-scoped: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(2)
