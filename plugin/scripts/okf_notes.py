"""Note helpers shared by okf-check's okf_check rules (successor, owner, duplicates).

One frontmatter reader and one link resolver, so the rules cannot disagree about what a note says or what a link
points at. Needs the vendored okf_validate on sys.path (its bounded loader refuses a YAML alias bomb).
"""
import os

from okf_guard import NoteRefused, note_cap, obsidian_path, read_note, refusal, shown  # noqa: F401  (re-exported: one reader for every tool)
from okf_validate import load_frontmatter, split_frontmatter


INVALID = object()   # pass as meta(p, invalid=INVALID) to tell "not valid YAML" from "no frontmatter"


def meta(p, invalid=None):
    """The frontmatter of note `p` as a dict; {} when it has none, `invalid` (default {}) when it does not parse."""
    try:
        # utf-8-sig: a note that starts with a BOM is read as L1 reads it (0.9.8 review G-1)
        t = read_note(p, "utf-8-sig", "replace")
    except OSError:
        return {}
    end = t.find("\n---", 3) if t.startswith("---") else -1
    if end < 0:
        return {}
    try:
        m = load_frontmatter(t[3:end])
    except Exception:
        return {} if invalid is None else invalid
    return m if isinstance(m, dict) else {}


def body_chars(p):
    """The length of note `p`'s body in characters (code points), or None when the file cannot be read as UTF-8.

    The body is what follows the frontmatter's closing `---` line, split by the validator's own split_frontmatter, so
    the size rule and L1 agree on where a body starts. A note with no frontmatter is all body. The file is read in
    text mode, so CRLF counts as one character: the same note checked out with LF or CRLF line endings measures the same.
    """
    try:
        t = read_note(p, "utf-8", "strict").lstrip("\ufeff")   # as the validator's _read_text: a BOM is not content
    except (OSError, UnicodeDecodeError):
        return None   # L1 reports a file it cannot read; the size rule does not report it a second time
    return len(split_frontmatter(t)[1])


def resolve(ref, note, root):
    """The real path of the note `ref` points at, or None.

    A wikilink, a markdown link or a path. Same convention as the L2 wikilink rule: from the bundle root or from the
    note's own folder, with or without .md, and inside the bundle (`root` is its real path). Names match by Obsidian's
    rule on every disk (obsidian_path): `[[New]]` names new.md on Linux as on macOS.
    """
    s = str(ref).strip()
    if s.startswith("[[") and s.endswith("]]"):
        s = s[2:-2].split("|")[0]
    elif s.startswith("[") and s.endswith(")") and "](" in s:
        s = s[s.index("](") + 2:-1].strip()
        # CommonMark link destination: <dest> in angle brackets, or dest followed by an optional title in double or
        # single quotes or parentheses (review F-B: both forms used to give a false "successor not found").
        if s.startswith("<") and ">" in s:
            s = s[1:s.index(">")]
        else:
            pairs = {'"': '"', "'": "'", ")": "("}
            if s and s[-1] in pairs and s.rfind(" " + pairs[s[-1]]) > 0:
                s = s[:s.rfind(" " + pairs[s[-1]])].rstrip()
    s = s.split("#")[0].strip().lstrip("/")
    if not s:
        return None
    for base in (root, os.path.dirname(os.path.realpath(str(note)))):
        for cand in (s, s + ".md"):
            q = obsidian_path(base, cand)
            q = q and os.path.realpath(q)
            if q and (q == root or q.startswith(root + os.sep)) and os.path.isfile(q) and q.endswith(".md"):
                return q
    return None
