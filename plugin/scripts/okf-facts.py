#!/usr/bin/env python3
"""okf-facts.py — declared facts, okf_check.facts in okf-base.yaml (public okf-knowledge-gate#15), for okf-check.

A fact (a count, a version, a list of countries) is stated in many notes. The bundle declares its value once, with the
patterns that find where it is stated (group 1 of each pattern is the stated value):

    okf_check:
      facts:
        launch.countries:
          value: "A and B"
          patterns: ["launch countries?:? *(.+)"]
          source: decisions/0007.md      # optional: where the value is decided

A note that states the fact with another value is a FACT-CONFLICT. Values are compared with case, runs of whitespace and
surrounding punctuation (. , ; : * _ `) ignored, and a stated value ends at the first `;` or `|` (a clause or a table
cell), so `Launch countries: A and B; services up: 5 of 7` states A and B. Code blocks are literals and are not read.
The patterns are checked once, by the shared schema (a regular expression with a capture group); this script trusts them.

Usage (from okf-check, with the vendored validator and okf_notes on sys.path):
    okf-facts.py <bundle> <okf-base.yaml> <notes.lst> check
        one line per statement `S|<json>`, per conflict `E|<finding>`, and `N|<facts>|<statements that agree>`
    okf-facts.py <bundle> <okf-base.yaml> <notes.lst> list [NAME]
        every occurrence of every fact (or of NAME), with its line and value; exit 64 for an unknown NAME
<notes.lst> holds the notes to read, NUL-separated (okf-check's walker, after .okfignore).
"""
import json
import os
import re
import sys

sys.path[:0] = [os.environ.get("OKF_SCRIPTS_DIR", ""), os.environ.get("OKF_VENDOR_DIR", "")]
from okf_notes import load_frontmatter, read_note  # noqa: E402  (bounded reads: a manifest or note is not exempt)

FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})")
INDENTED = re.compile(r"^(?: {4,}|\t)")
STRIP = " .,;:*_`\"'()[]"
MAX_LINE = 4000   # characters of a line the patterns see: a pattern from okf-base.yaml must not get an unbounded input


def norm(v: str) -> str:
    return " ".join(v.split()).strip(STRIP).casefold()


def stated(raw: str) -> str:
    """The value a match states: cut at the first `;` or `|`, surrounding space and punctuation dropped."""
    return re.split(r"[;|]", raw, maxsplit=1)[0].strip().strip(STRIP).strip()


def body_lines(text: str):
    """(line number, text) of each body line outside code blocks. The same code rules as okf-verify's strip_code_fences."""
    rows = text.split("\n")
    start = 0
    if rows and rows[0].strip() == "---":
        for j in range(1, len(rows)):
            if rows[j].strip() == "---":
                start = j + 1
                break
    fence_char, fence_len = "", 0
    for i in range(start, len(rows)):
        line = rows[i]
        m = FENCE.match(line)
        if fence_char:
            if m and m.group(2)[0] == fence_char and len(m.group(2)) >= fence_len:
                fence_char, fence_len = "", 0
            continue
        if m:
            fence_char, fence_len = m.group(2)[0], len(m.group(2))
            continue
        if INDENTED.match(line):
            continue
        yield i + 1, line.rstrip("\r")[:MAX_LINE]


def statements(bundle, files, facts):
    out, seen = [], set()
    for f in sorted(files):
        try:
            text = read_note(f, "utf-8", "replace").lstrip("﻿")
        except OSError:
            continue   # L1 reports a note it cannot read
        rel = os.path.relpath(f, bundle).replace("\n", " ").replace("\t", " ")
        for n, line in body_lines(text):
            for name, spec in facts.items():
                for pat in spec["patterns"]:
                    for m in re.finditer(pat, line, re.I):
                        v = stated(m.group(1) or "")
                        if v and (name, rel, n, m.start(1)) not in seen:   # two patterns, one statement: counted once
                            seen.add((name, rel, n, m.start(1)))
                            out.append({"fact": name, "note": rel, "line": n, "stated": v, "declared": str(spec["value"]),
                                        "agrees": norm(v) == norm(str(spec["value"]))})
    return out


def main(argv):
    bundle, manifest, lst, mode = argv[1:5]
    try:
        cfg = load_frontmatter(read_note(manifest, "utf-8", "replace"))
    except Exception:
        cfg = {}
    opt = (cfg.get("okf_check") or {}) if isinstance(cfg, dict) else {}
    facts = opt.get("facts") if isinstance(opt, dict) else None
    if not isinstance(facts, dict) or not facts:
        if mode == "list":
            print("no okf_check.facts block in okf-base.yaml: nothing to list")
        return 0
    files = [f for f in open(lst, "rb").read().decode("utf-8", "replace").split("\0") if f]
    if mode == "list":
        want = argv[5] if len(argv) > 5 else None
        if want and want not in facts:
            print(f"error: --facts {want}: no such fact (declared: {', '.join(sorted(facts))})")
            return 64
        found = statements(bundle, files, {k: v for k, v in facts.items() if want in (None, k)})
        for name in sorted(facts):
            if want not in (None, name):
                continue
            rows = [s for s in found if s["fact"] == name]
            src = facts[name].get("source")
            print(f"{name}: declared \"{facts[name]['value']}\"{' (source ' + str(src) + ')' if src else ''}, "
                  f"{len(rows)} occurrence(s), {sum(1 for s in rows if not s['agrees'])} differ(s)")
            for s in rows:
                print(f"  {s['note']}:{s['line']}  {s['stated']}{'' if s['agrees'] else '  (differs)'}")
        return 0
    found = statements(bundle, files, facts)
    for s in found:
        print("S|" + json.dumps(s))
        if not s["agrees"]:
            src = facts[s["fact"]].get("source")
            print(f"E|{s['note']}:{s['line']}: FACT-CONFLICT {s['fact']} states \"{s['stated']}\", declared "
                  f"\"{s['declared']}\"{' (source ' + str(src) + ')' if src else ''}")
    print(f"N|{len(facts)}|{sum(1 for s in found if s['agrees'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
