#!/usr/bin/env python3
"""okf-check trust layer (C4): unauthenticated human verification.

OKF v0.2 records `verified: by: human:<id>` and cannot authenticate it: an agent can write that
line itself. This reports the cases where the claim is visibly unsafe to trust. It does not prove
identity (only repository review metadata can); it names what is checkable offline.

Usage: okf-trust.py <bundle> <findings.json>
stdout: one line per finding, `W|<note>: <message>` (warning) or `A|<note>: <message>` (advisory), and
`T|<note>: <message>` for a note the frontmatter loader refused for its size (its trust claims were not checked).
<findings.json>: [{"file", "entry", "severity", "reason"}, ...]. Always written.

Per `verified` entry whose actor starts with `human:` (exact lowercase, spec §5.3), the FIRST row wins:
  status is draft                                -> warning
  verified.at is earlier than generated.at       -> warning (the content changed after the review)
  generated.by is an agent form                  -> advisory (an honest later review looks the same)
Entries by `process:` or any other actor are never reported here. Run with PyYAML on the path (okf-check
does this through py_with_vendor). Reads the vendored validator's frontmatter splitter; never edits it.
"""
import datetime
import json
import re
import sys
import unicodedata
from pathlib import Path

import yaml

sys.dont_write_bytecode = True   # a direct run must not leave scripts/__pycache__ in the installed plugin (plugin.test.sh Z-2)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))
from okf_validate import AliasBombError, load_frontmatter, split_frontmatter  # noqa: E402  (the validator's own splitter, so both agree)
sys.path.insert(0, str(Path(__file__).resolve().parent))
from okf_guard import read_note, refusal, shown  # noqa: E402  (bounded read, refusal: a link out of the bundle)

# `<producer>/<version>` or an `agent:<id>` actor; `human:` and `process:` are never agents.
AGENT_FORM = re.compile(r"^(?:agent:\S+|[^\s:/]+/\S+|[^\s:/]+)$")   # a bare token (`claudebot`) is an agent too; `team:<id>` is not


# Letters that render like the ones in `human:` and `process:` (Unicode confusables for h u m a n p r o c e s and the
# colon). NFKD (below) already folds full-width forms and the mathematical alphabets; these survive it. B-4, narrow: a value that
# only LOOKS like `human:` is named, so nobody reads `һυмап:dana` as a human claim. Nothing new is denied.
LOOKALIKE = str.maketrans({
    "\u04bb": "h", "\u04ba": "h", "\u029c": "h", "\u0570": "h", "\u13c2": "h", "\u041d": "h", "\u0397": "h",
    "\u03c5": "u", "\u1d1c": "u", "\u057d": "u", "\u028b": "u",
    "\u043c": "m", "\u1d0d": "m", "\u041c": "m", "\u039c": "m",
    "\u0430": "a", "\u03b1": "a", "\u1d00": "a", "\u0410": "a", "\u0391": "a",
    "\u043f": "n", "\u03b7": "n", "\u0578": "n", "\u0274": "n", "\u039d": "n",
    "\u0440": "p", "\u03c1": "p", "\u0420": "p", "\u03a1": "p",
    "\u0433": "r", "\u0280": "r",
    "\u043e": "o", "\u03bf": "o", "\u041e": "o", "\u039f": "o", "\u0585": "o",
    "\u0441": "c", "\u03f2": "c", "\u0421": "c", "\u1d04": "c", "\u03f9": "c",
    "\u0435": "e", "\u0415": "e", "\u0395": "e",
    "\u0455": "s", "\u0405": "s", "\ua731": "s",
    "\u2236": ":", "\u02f8": ":", "\ua789": ":", "\u0589": ":", "\u05c3": ":", "\ufe55": ":",
})


# Characters that render as nothing, as a gap or on top of a letter: format (Cf: zero-width space and joiners, soft hyphen,
# word joiner, BOM), combining and enclosing marks (Mn, Me), space, line and paragraph separators (Zs: no-break, ideographic;
# Zl, Zp), plus the characters that are controls, letters or symbols by category but draw a blank or break the line (next line
# U+0085, braille blank, hangul fillers).
HIDDEN_CATEGORIES = ("Cf", "Mn", "Me", "Zs", "Zl", "Zp")
BLANK_FILLERS = "\u0085\u115f\u1160\u2800\u3164\uffa0"


def is_hidden(ch):
    """An ordinary space is not hidden: it shows, and an all-ASCII spelling is the validator's near-miss rule, not this one."""
    return ch != " " and (unicodedata.category(ch) in HIDDEN_CATEGORIES or ch in BLANK_FILLERS)


def hidden_code_points(actor):
    """The U+XXXX of every hidden character in the prefix of <actor> (before its first colon), in numeric order, once each. The actor
    is printed with them in it, so the warning has to name them."""
    return [f"U+{n:04X}" for n in sorted({ord(c) for c in actor.split(":", 1)[0] if is_hidden(c)})]   # as written: NFKD would turn U+00A0 into U+0020


def lookalike_prefix(actor):
    """`human:` or `process:` when <actor> only looks like it: lookalike letters that the plain spelling check (the
    validator's near-miss rule, ASCII only) does not see. None for the real prefix and for an ASCII near-miss."""
    if actor.startswith(("human:", "process:")) or actor.isascii():
        return None
    # Hidden characters out: `hu<U+200B>man:` reads as `human:` and no tool does. NFKD, not NFKC: NFKC would recompose a
    # precomposed letter such as U+1E25 (`ḥ`), so the Mn drop could not remove its mark; NFKD splits it into base and mark.
    # Each character is judged as written first (NFKD turns a no-break space into an ordinary one), then its parts.
    visible = "".join(d for c in actor if not is_hidden(c) for d in unicodedata.normalize("NFKD", c) if not is_hidden(d))
    folded = visible.translate(LOOKALIKE).lower()
    for p in ("human:", "process:"):
        if folded.startswith(p):
            return p
    return None


def as_text(value):
    """The stripped text of a YAML string; anything else is "". A YAML alias bomb is a small file whose
    str() expands to billions of items (2.5 GB, killed at 60 s), so a non-string is never stringified."""
    return value.strip() if isinstance(value, str) else ""


def as_instant(value):
    """(UTC datetime, has_time) from a YAML date, datetime or RFC 3339 string; None if unreadable.
    has_time is False for a bare date: it cannot say WHICH moment of that day, so earlier() compares days."""
    try:
        if isinstance(value, datetime.datetime):
            dt, has_time = value, True
        elif isinstance(value, datetime.date):
            dt, has_time = datetime.datetime(value.year, value.month, value.day), False
        elif isinstance(value, str):
            text = value.strip()
            has_time = bool(re.search(r"[T ]\d", text))
            dt = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        else:
            return None  # absent, or not a date or a string: never stringified (see as_text)
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    return dt, has_time


def earlier(a, b):
    """True when instant a is before instant b; days only when either side is a bare date."""
    if a[1] and b[1]:
        return a[0] < b[0]
    return a[0].date() < b[0].date()


def findings_for(meta):
    status = as_text(meta.get("status"))
    gen = meta.get("generated")
    gen_by = as_text(gen.get("by")) if isinstance(gen, dict) else ""
    gen_at = as_instant(gen.get("at")) if isinstance(gen, dict) else None
    ver = meta.get("verified")
    if isinstance(ver, str):
        ver = {"by": ver}   # L1 warns that `verified` is not a mapping; the claim itself is still read here
    entries = [ver] if isinstance(ver, dict) else ver
    if not isinstance(entries, list):
        return
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        actor = as_text(entry.get("by"))
        where = f"verified[{i}].by"
        look = lookalike_prefix(actor)
        if look:
            hidden = hidden_code_points(actor)
            seen = f" (its prefix holds the hidden {', '.join(hidden)})" if hidden else ""
            yield ("warning", where, f"`{actor}` only looks like `{look}`: it spells it with lookalike characters, so no "
                                     f"tool reads it as that actor; write `{look}` in plain ASCII{seen}")
            continue
        if not actor.startswith("human:"):
            continue
        ver_at = as_instant(entry.get("at"))
        if status == "draft":
            yield ("warning", where, f"`{actor}` on a draft note: draft with human verification")
        elif ver_at is not None and gen_at is not None and earlier(ver_at, gen_at):
            yield ("warning", where, f"`{actor}` is dated before generated.at: the note changed after the claimed review")
        elif AGENT_FORM.match(gen_by):
            yield ("advisory", where, f"`{actor}` on a note generated by `{gen_by}`: a human review of an agent note cannot be authenticated")


def main():
    bundle, out_path = Path(sys.argv[1]), sys.argv[2]
    records = []
    for path in sorted(bundle.rglob("*.md")):
        if path.name in ("index.md", "log.md") or not path.is_file() or refusal(path, root=bundle):   # not a link out of the bundle
            continue
        try:
            # utf-8-sig: a BOM would hide the opening fence, and L1 counts such a note.
            raw, _ = split_frontmatter(read_note(path, "utf-8-sig", "strict", root=bundle))
            meta = load_frontmatter(raw) if raw is not None else None
        except AliasBombError as e:   # the loader's size cap: a trust claim in this note is unread, which is not "no finding" (L1 reports the cap too)
            print(f"T|{shown(path.relative_to(bundle).as_posix())}: the note was too large to read, so its trust claims were not checked: {e}")
            continue
        except (OSError, UnicodeDecodeError, yaml.YAMLError, ValueError):
            continue  # L1 reports an unreadable or malformed note; this layer has nothing to add
        if not isinstance(meta, dict):
            continue
        rel = path.relative_to(bundle).as_posix()
        for severity, entry, reason in findings_for(meta):
            records.append({"file": rel, "entry": entry, "severity": severity, "reason": reason})
    for r in records:
        tag = "W" if r["severity"] == "warning" else "A"
        print(f'{tag}|{r["file"]}: {r["entry"]} {r["reason"]}')
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump([dict(r, file=shown(r["file"])) for r in records], fh)   # --json reads a name that is not UTF-8 as \xff, not a lone surrogate


if __name__ == "__main__":
    main()
