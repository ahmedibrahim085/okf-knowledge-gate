#!/usr/bin/env python3
"""okf-edit-hook.py — opt-in PostToolUse hook: check the edited note when it sits in a bundle (okf-knowledge-gate#8).

In a multi-agent setup a whole batch of edits can land before anyone runs okf-check. This hook runs the scoped
check (`okf-check <bundle> --file <note>`) on each Write/Edit of a note and tells Claude about a finding at once.

Platform contract (https://code.claude.com/docs/en/hooks, read 2026-10-18):
  - stdin is the PostToolUse JSON; for Write and Edit "`tool_input.file_path` is always absolute".
  - "To surface a warning to Claude from a `PostToolUse` ... hook, exit 2 instead so Claude sees the stderr even
    though the tool already ran." Exit 0 stdout only reaches the debug log, so silence is exit 0 with no output.
  - A hook that reaches its `timeout` is cancelled and its output discarded; the edit stands either way.

Rules (S9-H1, S9-N1, S9-N2, S9-E1):
  - OFF by default. On only with OKF_EDIT_HOOK=1, or `okf_check: {edit_hook: true}` in the bundle's okf-base.yaml,
    read through okf-verify's validated loader (an invalid block leaves it off; the full okf-check run reports it).
  - The bundle is the nearest folder above the note that holds okf-base.yaml; a file in no bundle is ignored.
  - Time-boxed (config/edit-hook.json, OKF_EDIT_HOOK_TIMEOUT overrides): past the box the check is killed and the
    hook is silent. Fail-open everywhere else too: any error exits 0 without output.
  - ONE stderr line, for an L1 error, a Trust warning or a note-local L2 finding (profile findings, R001, the declared
    counts) only: the hook shows the FIRST finding in okf-check --file order (L1, Trust, then L2) and says how many more
    there are. Ordering by severity needs --file to escape note text first (okf-knowledge-gate ticket 420: a note value can today forge a line
    that looks like an L1 error; a severity sort would put that forgery first). An L1 warning (a missing `tags`) is left
    out on purpose — it would fire on every edit of such a note; `okf-check <bundle> --file <note>` prints it, so a
    release wrapper that wants it reads it there.
"""
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

# Claude Code starts this with a plain python3, not okf-check's py_with_vendor (PYTHONDONTWRITEBYTECODE=1). Loading
# okf-verify and its vendored YAML would leave __pycache__ in the installed plugin on a Linux python (SH-7, LT-56m).
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
CONFIG = HERE.parent / "config" / "edit-hook.json"
sys.path.insert(0, str(HERE))
from okf_guard import shown   # noqa: E402  (spell the note name exactly the way okf-check --file prints it)
# The line shapes okf-check --file prints, in print order. A line is classified by its EARLIEST marker after the
# note-name prefix, so a quoted value or a note name holding a marker string cannot change a line's class.
MARKERS = (": L1 error: ", ": L1 warning: ", ": Trust warning: ", ": Trust advisory: ", ": Trust error: ",
           ": L2 profile error: ", ": L2 index error: ")
# classified but never printed and never counted in `(+N more`: a missing `tags` would fire on every edit ('s
# decision, kept by). Trust warnings and advisories DO print. `: L1 warning: ` must stay in MARKERS so a warning
# line whose quoted value holds `: L1 error: ` is classified by its own prefix and stays dropped.
_WARN = frozenset((": L1 warning: ",))


def classify(line: str, prefixes):
    """Return the marker that sits DIRECTLY AFTER a known line prefix (the escaped note name, or `index.md`),
    or None when the line is not a finding okf-check --file printed. The prefix anchors the class: a note NAME
    or a quoted value that merely CONTAINS a marker string cannot pick the line's class (round 1 I5) — a name
    like `x: L1 warning: y.md` must not drop the note's own L1 error line, and `x: L1 error: y.md` must not
    promote a warning line to a printed hit."""
    for p in prefixes:
        if line.startswith(p):
            rest = line[len(p):]
            # m[2:]: the prefix already ends in ': ', and every marker starts with it.
            return next((m for m in MARKERS if rest.startswith(m[2:])), None)
    return None


def bundle_of(note: Path):
    for d in note.parents:
        if (d / "okf-base.yaml").is_file():
            return d
    return None


def load_verify():
    loader = SourceFileLoader("okf_verify", str(HERE / "okf-verify"))
    verify = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_verify", loader))
    loader.exec_module(verify)
    return verify


def switched_on(bundle: Path) -> bool:
    if os.environ.get("OKF_EDIT_HOOK") == "1":
        return True
    verify = load_verify()
    try:
        return verify.load_block(bundle).get("edit_hook") is True
    except verify.BaseConfigError:
        return False


CONTROL = re.compile("[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]")


def time_box() -> float:
    """OKF_EDIT_HOOK_TIMEOUT, capped at max_seconds; a value that is not a positive number uses timeout_seconds.

    min(nan, 4.5) is nan and a box of 0 or -1 fires at once: either way the hook was silently off (B-7).
    """
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    default, cap = float(cfg["timeout_seconds"]), float(cfg["max_seconds"])
    try:
        box = float(os.environ.get("OKF_EDIT_HOOK_TIMEOUT") or default)
    except ValueError:
        box = default
    return min(box, cap) if box > 0 else default   # nan > 0 is False


def clean_line(text: str, limit: int) -> str:
    """Control characters out, length bounded: Claude reads this line, and it quotes note values (review 0.9.13)."""
    text = CONTROL.sub("?", text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def main() -> int:
    fp = ((json.load(sys.stdin) or {}).get("tool_input") or {}).get("file_path") or ""
    if not fp.endswith(".md") or not os.path.isfile(fp):
        return 0
    bundle = bundle_of(Path(fp))
    if bundle is None or not switched_on(bundle):
        return 0
    box = time_box()   # before okf-check starts: a bad value must not leave a child nobody waits for
    # Its own process group, so the time box can kill okf-check AND the python it starts.
    proc = subprocess.Popen(["bash", str(HERE / "okf-check"), str(bundle), "--file", fp],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=box)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        return 0
    # split on "\n" only: splitlines() also breaks on U+2028, U+2029 and U+0085, so a surviving separator inside an
    # escaped-away finding would count as a second hit.
    # The class anchors on the line's own prefix — the note's ESCAPED name as okf-check prints it (`shown()` spells
    # what the raw name would break on), or `index.md` for the declared-count line — never on a marker substring
    # that a note name or quoted value carries (round 1 I5).
    # okf-check prints rel from `cd -P` on the note's DIRECTORY plus its basename (a symlinked note name itself is
    # kept, not resolved), and the payload's path may carry `//` or a symlinked folder (SH-3b builds one), so build
    # the note path the same way before spelling the prefix.
    note = os.path.join(os.path.realpath(os.path.dirname(fp)), os.path.basename(fp))
    rel = os.path.relpath(note, os.path.realpath(str(bundle)))
    prefixes = (shown(rel) + ": ", "index.md: ")
    hits = [line for line in out.split("\n")
            if (m := classify(line, prefixes)) is not None and m not in _WARN]
    # 3 and 2 are verdicts too: since `--file` exits 3 for a note-local house-profile or index finding and 2 when a
    # note-local layer could not run. Neither may silence the L1 and Trust lines the same run printed; a run that printed
    # no finding line (a clean note, or nothing was checked) stays silent, which the `not hits` half already decides.
    # What the hook does with the L2 lines themselves 's decision, not this slice's.
    if proc.returncode not in (0, 1, 2, 3) or not hits:
        return 0
    # The cut applies to the first finding alone, so a long one cannot push the hint off the line; the hint gives the
    # command (paths quoted, so it can be pasted) only when the whole line still fits max_line_chars (review 0.9.35).
    limit = int(json.loads(CONFIG.read_text(encoding="utf-8"))["max_line_chars"])
    more = ""
    if len(hits) > 1:
        more = CONTROL.sub("?", f" (+{len(hits) - 1} more: okf-check {shlex.quote(str(bundle))} --file {shlex.quote(fp)})")
        if len(more) > limit // 2:
            more = f" (+{len(hits) - 1} more)"
    print(clean_line(f"okf-check: {hits[0]}", limit - len(more)) + more, file=sys.stderr)
    return 2


def doctor(start: Path) -> None:
    """`--doctor <folder>`, run by `okf-check --doctor`: one line when the hook is switched on for <folder>, saying
    whether it can run. The hook itself is fail-open, so a config it cannot read leaves it silent on every edit; this is
    the one place that says so. Prints nothing when the hook is off. Advisory: never changes an exit code."""
    try:
        if os.environ.get("OKF_EDIT_HOOK") == "1":
            where = "OKF_EDIT_HOOK=1"
        else:
            bundle = bundle_of(start.resolve() / "x")   # "x": bundle_of walks the parents of a note, and <start> must be one
            if bundle is None:
                return
            verify = load_verify()
            try:
                if verify.load_block(bundle).get("edit_hook") is not True:
                    return
            except verify.BaseConfigError as e:   # the hook reads an invalid block as off; the full run is what reports it
                reason = clean_line(str(e).splitlines()[0] if str(e) else type(e).__name__, 160)
                print(f"  edit hook          OFF: {bundle}/okf-base.yaml okf_check block is invalid ({reason}); the hook reads it as off")
                return
            where = f"{bundle}/okf-base.yaml"
    except Exception as e:   # okf-verify missing or broken: the hook cannot even decide whether it is on
        print(f"  edit hook          UNKNOWN   (cannot tell whether it is switched on: {type(e).__name__}: {e})")
        return
    try:
        time_box()   # reads the same config, and the same keys, as a real run
        int(json.loads(CONFIG.read_text(encoding="utf-8"))["max_line_chars"])
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"  edit hook          ON ({where}) but CANNOT RUN: {CONFIG} is missing, unreadable or incomplete "
              f"({type(e).__name__}: {e}). The hook stays silent on every edit until it is restored (reinstall the plugin).")
        return
    print(f"  edit hook          ON ({where}); config OK ({CONFIG.name})")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--doctor"]:
        doctor(Path(sys.argv[2]) if len(sys.argv) > 2 else Path.cwd())
        sys.exit(0)
    try:
        sys.exit(main())
    except Exception:   # fail-open: a broken hook must never get in the way of an edit
        sys.exit(0)
