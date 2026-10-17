#!/usr/bin/env python3
"""Record a REAL okf-check session for the README demo.

Runs the commands below, in order, on a throwaway bundle (temp dir, temp HOME, the plugin's own bin/ on PATH),
and writes what they printed, with each exit code, to tools/demo/transcript.txt. Nothing is mocked or typed by
hand: render.py turns this transcript into docs/demo.gif, so the GIF cannot show output the tool did not produce.

Fails closed: if any captured line contains a private path or an e-mail address, nothing is written.

Usage: python3 tools/demo/record.py            (writes tools/demo/transcript.txt)
       python3 tools/demo/record.py --stdout   (prints the transcript instead, writes nothing)
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BIN = ROOT / "plugin" / "bin"

INDEX = '---\nokf_version: "0.2"\n---\n# Notes\n'
LOG = "# Log\n\n## 2026-01-01\n* created\n"
# The first version of the note has no `type`: an L1 (OKF spec) error.
NO_TYPE = "---\ntitle: Payment limits\ndescription: Limits for payouts.\n---\n\nbody\n"
# A draft that an agent wrote and that claims a human verified it: the Trust layer flags it.
DRAFT = ('---\ntype: Lesson\ntitle: Payment limits\ndescription: Limits for payouts.\nstatus: draft\ntags: [payments]\n'
         'generated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: human:finance-owner\n    at: "2026-02-01"\n'
         'stale_after: "2099-01-01"\n---\n\nbody\n')
# The same note after a real review: written by a person, stable, reviewed after the last change.
REVIEWED = ('---\ntype: Lesson\ntitle: Payment limits\ndescription: Limits for payouts.\nstatus: stable\ntags: [payments]\n'
            'generated:\n  by: human:dana\n  at: "2026-01-01"\nverified:\n  - by: human:finance-owner\n    at: "2026-02-01"\n'
            'stale_after: "2099-01-01"\n---\n\nbody\n')

# Each scene starts on a cleared screen. A command is run exactly as written.
SCENES = [
    ["okf-check --init-house-rules notes", "okf-check notes"],
    ["cp fixes/draft.md notes/limits.md", "okf-check notes"],
    ["okf-check notes --strict-trust"],
    ["cp fixes/reviewed.md notes/limits.md", "okf-check notes --strict-trust"],
]

PRIVATE = re.compile(r"/Users/|/home/|/var/folders|/private/|/tmp/|ahmedmaged|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[a-z]{2,}")


def main() -> int:
    to_stdout = "--stdout" in sys.argv
    with tempfile.TemporaryDirectory(prefix="okfdemo") as tmp:
        work = pathlib.Path(tmp) / "work"
        (work / "notes").mkdir(parents=True)
        (work / "fixes").mkdir()
        (work / "notes" / "index.md").write_text(INDEX)
        (work / "notes" / "log.md").write_text(LOG)
        (work / "notes" / "limits.md").write_text(NO_TYPE)
        (work / "fixes" / "draft.md").write_text(DRAFT)
        (work / "fixes" / "reviewed.md").write_text(REVIEWED)
        home = pathlib.Path(tmp) / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), PATH=f"{BIN}:{os.environ['PATH']}", LC_ALL="C", NO_COLOR="1")
        env.pop("OKF_AUTO_INSTALL", None)
        out = []
        for scene in SCENES:
            out.append("#scene")
            for cmd in scene:
                r = subprocess.run(cmd, shell=True, cwd=work, env=env, capture_output=True, text=True, timeout=120)
                text = (r.stdout + r.stderr).rstrip("\n")
                out.append(f"$ {cmd}")
                if text:
                    out.extend(text.split("\n"))
                out.append(f"[exit {r.returncode}]")
        # The version line changes every release and says nothing about the demo: keep it out of the picture.
        out = [l for l in out if not re.match(r"^okf-check \d+\.\d+\.\d+ — ", l)]
    bad = [l for l in out if PRIVATE.search(l)]
    if bad:
        print("record.py: refusing to write; private-looking text in the capture:", *bad[:5], sep="\n  ", file=sys.stderr)
        return 1
    text = "\n".join(out) + "\n"
    if to_stdout:
        sys.stdout.write(text)
    else:
        (HERE / "transcript.txt").write_text(text)
        print(f"wrote {HERE / 'transcript.txt'} ({len(out)} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
