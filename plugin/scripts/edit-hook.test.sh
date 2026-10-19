#!/usr/bin/env bash
# Tests for the opt-in PostToolUse edit hook (okf-edit-hook.py, okf-knowledge-gate#8). Cases S9-H1, S9-N1, S9-N2,
# S9-E1 in docs/gherkin/s09-edit-hook.feature.
#
# The hook is driven the way Claude Code drives it (https://code.claude.com/docs/en/hooks): a PostToolUse JSON
# object on stdin with an absolute `tool_input.file_path`; exit 2 with stderr is the warning Claude sees, exit 0 is
# silence. Every bundle is a temp fixture.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
HOOK="$HERE/okf-edit-hook.py"
TEMPLATE="$HERE/../config/okf-base.yaml.template"
REALPY=$(command -v python3)
PASS=0; FAIL=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfedithook)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }
SKIPPED=0
skip() { SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"; }
# procs <text>: how many running processes have <text> in their command line; SKIP when this machine offers no way
# to look (debian:12 ships without ps). A count that cannot be taken must never read as zero.
procs() {
  if ps -axo command >/dev/null 2>&1; then
    ps -axo command | grep -F -- "$1" | grep -v grep | grep -c .
  elif [ -r /proc/self/cmdline ]; then
    for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$f" 2>/dev/null; echo; done | grep -F -- "$1" | grep -v grep | grep -c .
  else
    echo SKIP
  fi
}

# boxed <secs> <cmd...>: run <cmd> in its own process group with an outer time box, so a hook whose own box broke
# cannot hang the suite. Past <secs> only that group is killed and the exit is 124. Python, because `timeout` is not on
# a stock macOS (the pattern okf-check.test.sh uses for its own time-boxed calls).
boxed() {
  "$REALPY" -c 'import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(p.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait(); sys.exit(124)' "$@"
}

# bundle <dir> <okf_check block or "">: a bundle root with okf-base.yaml (the house template) and an index.
bundle() {
  mkdir -p "$1"
  sed 's/^  name: CHANGE ME/  name: Probe/' "$TEMPLATE" > "$1/okf-base.yaml"
  [ -n "$2" ] && printf '%s\n' "$2" >> "$1/okf-base.yaml"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$1/index.md"
}
badnote() { mkdir -p "$(dirname "$1")"; printf -- '---\ntitle: T\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$1"; }
# fire <file> [env...]: the hook with a PostToolUse payload for an Edit of <file>; exit code printed,
# stdout in $TMP/out.txt, stderr in $TMP/err.txt.
fire() {
  local f="$1"; shift
  "$REALPY" -c 'import json,sys; print(json.dumps({"session_id":"t","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"a","new_string":"b"},"tool_response":{"filePath":sys.argv[1]}}))' "$f" \
    | boxed 30 env "$@" "$REALPY" "$HOOK" >"$TMP/out.txt" 2>"$TMP/err.txt"
  printf '%s' "$?"
}

# --- S9-H1: on, an L1 error in the edited note -> one warning line ----------------------------
B="$TMP/on"; bundle "$B" 'okf_check:
  edit_hook: true'
badnote "$B/sub/bad.md"
rc=$(fire "$B/sub/bad.md")
{ [ "$rc" = 2 ] && [ "$(wc -l < "$TMP/err.txt" | tr -d ' ')" = 1 ] && [ ! -s "$TMP/out.txt" ] \
  && grep -q '^okf-check: sub/bad.md: L1 error: .*`type`' "$TMP/err.txt"; } \
  && ok "S9-H1 edit_hook: true + a note without type: exit 2, exactly one stderr line naming the L1 error" \
  || bad "S9-H1 one warning line" "rc=$rc err: $(head -3 "$TMP/err.txt" | tr '\n' '|') out: $(head -2 "$TMP/out.txt" | tr '\n' '|')"
silent() { [ "$1" = 0 ] && [ ! -s "$TMP/out.txt" ] && [ ! -s "$TMP/err.txt" ]; }

# --- S9-N1: off by default: no key, no env -> nothing runs, nothing printed --------------------
B0="$TMP/off"; bundle "$B0" ''
badnote "$B0/bad.md"
rc=$(fire "$B0/bad.md")
silent "$rc" && ok "S9-N1 no edit_hook key and no OKF_EDIT_HOOK: exit 0, no output, for a note with an L1 error" \
  || bad "S9-N1 off by default" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
rc=$(fire "$B0/bad.md" OKF_EDIT_HOOK=1)
{ [ "$rc" = 2 ] && grep -q 'L1 error' "$TMP/err.txt"; } && ok "S9-N1b OKF_EDIT_HOOK=1 turns it on without the key" \
  || bad "S9-N1b env switch" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
B1="$TMP/false"; bundle "$B1" 'okf_check:
  edit_hook: false'
badnote "$B1/bad.md"
rc=$(fire "$B1/bad.md")
silent "$rc" && ok "S9-N1c edit_hook: false stays off" || bad "S9-N1c false" "rc=$rc"
B2="$TMP/yes-string"; bundle "$B2" 'okf_check:
  edit_hook: "yes"'
badnote "$B2/bad.md"
rc=$(fire "$B2/bad.md")
silent "$rc" && ok "S9-N1d an invalid block (edit_hook: \"yes\", a string) leaves the hook off and silent (fail-open)" \
  || bad "S9-N1d invalid block" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# --- S9-N2: a file outside any bundle, or not a note, is ignored ---------------------------------
mkdir -p "$TMP/loose"; badnote "$TMP/loose/bad.md"
rc=$(fire "$TMP/loose/bad.md" OKF_EDIT_HOOK=1)
r2=$(fire "$B/notes.txt" OKF_EDIT_HOOK=1)
{ silent "$rc" && silent "$r2"; } && ok "S9-N2 a note in no bundle and a non-.md file in a bundle: exit 0, no output, even with OKF_EDIT_HOOK=1" \
  || bad "S9-N2 outside" "rc=$rc,$r2 err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# --- S9-E1: a check that runs past the time box fails open: no warning, nothing left running -----
start=$("$REALPY" -c 'import time; print(time.time())')
rc=$(fire "$B/sub/bad.md" OKF_EDIT_HOOK_TIMEOUT=0.001)
took=$("$REALPY" -c "import time; print('%.1f' % (time.time() - $start))")
sleep 1
left=$(procs "$B")
if [ "$left" = SKIP ]; then
  silent "$rc" && skip "S9-E1 past the time box: exit 0 and no warning (${took} s); left-running check SKIPPED, no ps or /proc here" \
    || bad "S9-E1 time box" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
else
  { silent "$rc" && [ "$left" = 0 ]; } && ok "S9-E1 past the time box: exit 0, no warning, no okf-check left running (${took} s)" \
    || bad "S9-E1 time box" "rc=$rc left=$left err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
fi
# The box must kill okf-check's CHILDREN too (the python it starts), not only okf-check: a plugin copy whose
# okf-check starts a long child that names a unique marker, then the box fires while the child runs.
CP="$TMP/plugin-copy"; cp -R "$HERE/.." "$CP"; MARK="okf-edit-hook-orphan-$$"
printf '#!/usr/bin/env bash\nsh -c "sleep 30; : %s" &\nwait\n' "$MARK" > "$CP/scripts/okf-check"
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$B/sub/bad.md" \
  | boxed 20 env OKF_EDIT_HOOK_TIMEOUT=0.5 "$REALPY" "$CP/scripts/okf-edit-hook.py" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
sleep 1
left=$(procs "$MARK")
if [ "$left" = SKIP ]; then
  skip "S9-E1b children killed by the time box: no ps or /proc on this machine to count them"
else
  { silent "$rc" && [ "$left" = 0 ]; } && ok "S9-E1b the time box kills okf-check's children as well (no orphan left after the box)" \
    || { bad "S9-E1b children" "rc=$rc orphans=$left"; pkill -f "$MARK" 2>/dev/null; }
fi

# --- only what blocks a gate warns; the rest stays quiet --------------------------------------------
mkdir -p "$B/q"; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nb\n' > "$B/q/notags.md"
rc=$(fire "$B/q/notags.md")
silent "$rc" && ok "SH-1 an L1 warning only (no tags) stays quiet" || bad "SH-1 L1 warning" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: draft\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nverified:\n  by: human:t\n  at: "2026-01-02"\n---\nb\n' > "$B/q/draft.md"
rc=$(fire "$B/q/draft.md")
{ [ "$rc" = 2 ] && grep -q '^okf-check: q/draft.md: Trust warning: ' "$TMP/err.txt"; } \
  && ok "SH-2 a Trust warning (a human verified a draft) is one warning line" || bad "SH-2 trust" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
printf -- '---\ntitle: T\nstatus: draft\nverified:\n  by: human:t\n  at: "2026-01-02"\n---\nb\n' > "$B/q/many.md"
rc=$(fire "$B/q/many.md")
{ [ "$rc" = 2 ] && [ "$(wc -l < "$TMP/err.txt" | tr -d ' ')" = 1 ] && grep -q 'L1 error.*(+1 more: okf-check .* --file .*many.md)$' "$TMP/err.txt"; } \
  && ok "SH-3 two findings are still one line: the first, then '(+1 more: okf-check <bundle> --file <note>)'" \
  || bad "SH-3 more" "rc=$rc err: $(cat "$TMP/err.txt" | tr '\n' '|')"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: stable\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nb\n' > "$B/q/clean.md"
rc=$(fire "$B/q/clean.md")
silent "$rc" && ok "SH-4 a clean note: exit 0, no output" || bad "SH-4 clean" "rc=$rc"
printf 'not json' | boxed 30 "$REALPY" "$HOOK" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
silent "$rc" && ok "SH-5 garbage on stdin: exit 0, no output (fail-open)" || bad "SH-5 garbage" "rc=$rc err: $(head -2 "$TMP/err.txt")"

# --- the wiring Claude Code reads: hooks/hooks.json ------------------------------------------------
"$REALPY" - "$HERE/../hooks/hooks.json" "$HERE/../config/edit-hook.json" <<'PY' 2>"$TMP/wire.txt"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
box = json.load(open(sys.argv[2]))["timeout_seconds"]
entries = [h for m in hooks.get("PostToolUse", []) if m.get("matcher") == "Write|Edit" for h in m["hooks"]
           if any(a.endswith("/scripts/okf-edit-hook.py") for a in h.get("args", []))]
assert len(entries) == 1, "one PostToolUse Write|Edit entry running okf-edit-hook.py, found %d" % len(entries)
e = entries[0]
assert e["type"] == "command" and e["command"] == "python3", e
assert e["args"] == ["${CLAUDE_PLUGIN_ROOT}/scripts/okf-edit-hook.py"], e["args"]
assert e["timeout"] > box, "the platform timeout (%s s) must outlast the hook's own box (%s s)" % (e["timeout"], box)
PY
[ $? -eq 0 ] && ok "SH-6 hooks.json: one PostToolUse 'Write|Edit' entry, exec form python3 + \${CLAUDE_PLUGIN_ROOT}/scripts/okf-edit-hook.py, platform timeout above the hook's own box" \
  || bad "SH-6 wiring" "$(tail -1 "$TMP/wire.txt")"

# --- the installed plugin directory stays as installed: no bytecode (LT-56m's rule, 0.9.9) -------------
# Claude Code runs the hook with a plain python3, not through py_with_vendor, and the hook loads okf-verify itself.
# A python3 that writes bytecode beside the module (Linux does) is reproduced on any host by clearing the cache prefix.
PYC="$TMP/pyc"; mkdir -p "$PYC/bin"; cp -R "$HERE/.." "$PYC/plugin"
find "$PYC/plugin" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
printf '#!/bin/sh\nexec "%s" -X pycache_prefix= "$@"\n' "$REALPY" > "$PYC/bin/python3"; chmod +x "$PYC/bin/python3"
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$B/sub/bad.md" \
  | boxed 30 env PATH="$PYC/bin:$PATH" "$PYC/bin/python3" "$PYC/plugin/scripts/okf-edit-hook.py" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
left=$(find "$PYC/plugin" -name '*.pyc' -o -name __pycache__ 2>/dev/null)
{ [ "$rc" = 2 ] && [ -z "$left" ]; } \
  && ok "SH-7 the hook (switched on by okf-base.yaml, so it loads okf-verify) leaves no bytecode in the plugin directory" \
  || bad "SH-7 no bytecode left behind" "rc=$rc left: $(printf '%s' "$left" | head -3 | tr '\n' ' ')"

# --- 0.9.13 review ----------------------------------------------------------------------------------------------
# SH-8 (blocker): the ONE line Claude reads quotes note values back. A hostile value must not carry control bytes
# (escape codes, bells, line breaks) and the line is bounded.
HV="$TMP/on/q/hostile.md"
"$REALPY" - "$HV" <<'PY'
import sys
by = "human:" + "IGNORE PRIOR \x1b[2J \x07 " + "A" * 20000
open(sys.argv[1], "w", encoding="utf-8").write("---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: draft\ngenerated:\n  by: human:t\n  at: \"2026-01-01\"\nverified:\n  by: \"%s\"\n  at: \"2026-01-02\"\n---\nb\n" % by.replace("\x1b", "\\e").replace("\x07", "\\a"))
PY
# YAML double quotes turn \e and \a into the real control characters
rc=$(fire "$HV")
ctl=$(LC_ALL=C tr -d '\n' < "$TMP/err.txt" | LC_ALL=C grep -c '[[:cntrl:]]'); len=$(wc -c < "$TMP/err.txt" | tr -d ' ')
{ [ "$rc" = 2 ] && [ "$ctl" = 0 ] && [ "$len" -le 700 ] && [ "$(wc -l < "$TMP/err.txt" | tr -d ' ')" = 1 ]; } \
  && ok "SH-8 a hostile verified.by (escape codes, 20000 characters) reaches Claude as one bounded line without control bytes (${len} bytes)" \
  || bad "SH-8 hostile value" "rc=$rc control-lines=$ctl bytes=$len"
# SH-9: an unusable OKF_EDIT_HOOK_TIMEOUT is read BEFORE okf-check starts: fail-open and nothing left running.
CP2="$TMP/plugin-copy2"; cp -R "$HERE/.." "$CP2"; MARK2="okf-edit-hook-badbox-$$"
printf '#!/usr/bin/env bash\nsh -c "sleep 30; : %s" &\nwait\n' "$MARK2" > "$CP2/scripts/okf-check"
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$B/sub/bad.md" \
  | boxed 20 env OKF_EDIT_HOOK_TIMEOUT=abc "$REALPY" "$CP2/scripts/okf-edit-hook.py" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
sleep 1; left=$(procs "$MARK2")
if [ "$left" = SKIP ]; then skip "SH-9 bad time box: no ps or /proc here to count a left-running check"
else
  { silent "$rc" && [ "$left" = 0 ]; } && ok "SH-9 OKF_EDIT_HOOK_TIMEOUT=abc: exit 0, no output, okf-check never started (nothing left running)" \
    || { bad "SH-9 bad time box" "rc=$rc left=$left"; pkill -f "$MARK2" 2>/dev/null; }
fi
# SH-10: an override above the platform timeout is capped (config max_seconds), so the hook's own box still fires first.
start=$("$REALPY" -c 'import time; print(time.time())')
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$B/sub/bad.md" \
  | boxed 20 env OKF_EDIT_HOOK_TIMEOUT=60 "$REALPY" "$CP2/scripts/okf-edit-hook.py" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
took=$("$REALPY" -c "import time; print('%.1f' % (time.time() - $start))")
{ silent "$rc" && "$REALPY" -c "import sys; sys.exit(0 if float('$took') < 5.0 else 1)"; } \
  && ok "SH-10 OKF_EDIT_HOOK_TIMEOUT=60 is capped: the box fired after ${took} s, under the 5 s platform timeout" \
  || bad "SH-10 cap" "rc=$rc took=${took} s"
pkill -f "$MARK2" 2>/dev/null

echo
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
