#!/usr/bin/env bash
# Tests for the README demo (tools/demo/record.py, render.py, transcript.txt, docs/demo.gif).
# The GIF must be a picture of REAL runs: the transcript is regenerated from the current tree and compared with the
# committed one, the capture holds no private text, and the GIF is small, loops, and ends on a held frame.
# Run: bash tools/demo/demo.test.sh      (the GIF checks need Pillow; they SKIP, counted, without it)
set -uo pipefail
HERE=$(cd -P "$(dirname "$0")" && pwd)
ROOT=$(cd -P "$HERE/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIPPED=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }
skip() { SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"; }
PY=$(command -v python3)

# DM-1: the recording runs on the current tree and the commands exit as the story says:
# init 0, fail 1 | cp 0, draft passes with a warning 0 | strict-trust fails 1 | cp 0, reviewed note passes 0.
"$PY" "$HERE/record.py" --stdout > "$TMP/fresh.txt" 2> "$TMP/rec_err.txt"; rc=$?
codes=$(grep -o '^\[exit [0-9]*\]' "$TMP/fresh.txt" | grep -o '[0-9]*' | tr '\n' ' ')
{ [ "$rc" -eq 0 ] && [ "$codes" = "0 1 0 0 1 0 0 " ]; } && ok "DM-1 the recording runs and the exit codes tell the story ($codes)" || bad "DM-1 recording" "rc=$rc codes='$codes' $(head -2 "$TMP/rec_err.txt" | tr '\n' ' ')"
# DM-2: the committed transcript IS what the tool prints today (a stale demo is a false demo).
cmp -s "$TMP/fresh.txt" "$HERE/transcript.txt" && ok "DM-2 the committed transcript equals a fresh recording of the current tree" || bad "DM-2 stale transcript" "run: python3 tools/demo/record.py, then render.py"
# DM-3: nothing private in the capture (checked here with its own patterns, not record.py's).
if grep -nE '/Users/|/home/|/var/folders|/private/|/tmp/|@[A-Za-z]|ahmed' "$HERE/transcript.txt" > "$TMP/priv.txt"; then bad "DM-3 private text in the transcript" "$(head -2 "$TMP/priv.txt" | tr '\n' ' ')"; else ok "DM-3 the transcript holds no private path, name or e-mail"; fi
# DM-4: the GIF.
GIF="$ROOT/docs/demo.gif"
if "$PY" -c 'import PIL' 2>/dev/null; then
  "$PY" - "$GIF" <<'PY' > "$TMP/gif.txt" 2>&1
import os, sys
from PIL import Image
p = sys.argv[1]
assert open(p, "rb").read(6) in (b"GIF87a", b"GIF89a"), "not a GIF"
size = os.path.getsize(p)
assert size < 1_000_000, "GIF is %d bytes (limit 1,000,000)" % size
im = Image.open(p)
assert im.info.get("loop") == 0, "does not loop"
assert im.n_frames >= 100, "only %d frames" % im.n_frames
assert im.size[0] <= 1000, "wider than 1000 px"
im.seek(im.n_frames - 1)
assert im.info.get("duration", 0) >= 3000, "the last frame is not held (%s ms)" % im.info.get("duration")
print("ok %d bytes, %d frames, %dx%d" % (size, im.n_frames, im.size[0], im.size[1]))
PY
  [ $? -eq 0 ] && ok "DM-4 docs/demo.gif is a small looping GIF that ends on a held frame ($(cat "$TMP/gif.txt"))" || bad "DM-4 GIF" "$(tail -1 "$TMP/gif.txt")"
  "$PY" "$HERE/render.py" "$TMP/r1.gif" >/dev/null 2>&1; "$PY" "$HERE/render.py" "$TMP/r2.gif" >/dev/null 2>&1
  cmp -s "$TMP/r1.gif" "$TMP/r2.gif" && [ -s "$TMP/r1.gif" ] && ok "DM-5 rendering is deterministic (two renders are byte-identical)" || bad "DM-5 determinism" "two renders differ or none was written"
else
  skip "DM-4/5 GIF checks — Pillow is not installed"
fi
echo
if [ "$SKIPPED" -gt 0 ]; then echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"; else echo "  $PASS passed, $FAIL failed"; fi
[ "$FAIL" -eq 0 ] || exit 1
