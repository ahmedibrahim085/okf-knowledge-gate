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
  - ONE stderr line, for an L1 error or a Trust warning only: an L1 warning (a missing `tags`) would fire on every
    edit of such a note.
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
WARN_ON = (": L1 error: ", ": Trust warning: ")   # the line shapes okf-check --file prints (okf-scoped.py)


def bundle_of(note: Path):
    for d in note.parents:
        if (d / "okf-base.yaml").is_file():
            return d
    return None


def switched_on(bundle: Path) -> bool:
    if os.environ.get("OKF_EDIT_HOOK") == "1":
        return True
    loader = SourceFileLoader("okf_verify", str(HERE / "okf-verify"))
    verify = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_verify", loader))
    loader.exec_module(verify)
    try:
        return verify.load_block(bundle).get("edit_hook") is True
    except verify.BaseConfigError:
        return False


CONTROL = re.compile("[\x00-\x1f\x7f-\x9f\u2028\u2029]")


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
    hits = [line for line in out.splitlines() if any(w in line for w in WARN_ON)]
    if proc.returncode not in (0, 1) or not hits:
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


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:   # fail-open: a broken hook must never get in the way of an edit
        sys.exit(0)
