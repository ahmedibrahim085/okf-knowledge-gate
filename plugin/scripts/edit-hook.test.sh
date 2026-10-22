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
trap 'rm -rf "$TMP" ${SHORT:+"$SHORT"}' EXIT   # SHORT is set below; the trap is live before it exists
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

# SHORT: a bundle under a short path. Whether the hook's '(+N more: ...)' hint gives the full command depends on the
# length of the paths in it (the hint must fit half of max_line_chars): under macOS's long TMPDIR it never does, under
# /tmp it does. The cases that pin the long form run here; SH-3b and SH-13b pin the short form on a long path.
SHORT=$(mktemp -d /tmp/ehXXXXXX) && [ -d "$SHORT" ] && SHORT=$(cd -P "$SHORT" && pwd) || { echo "edit-hook tests: cannot make a folder under /tmp" >&2; exit 1; }
bundle "$SHORT/on" 'okf_check:
  edit_hook: true'

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

# --- S39-PY-15: a bundle folder nobody may enter makes the scoped check stop (exit 2), and the hook is fail-open: exit 0, nothing printed ---
if [ "$(id -u)" != 0 ]; then
  BU="$TMP/unreadable"; bundle "$BU" 'okf_check:
  edit_hook: true'
  badnote "$BU/bad.md"; mkdir -p "$BU/locked"; chmod 000 "$BU/locked"
  rc=$(fire "$BU/bad.md"); chmod 755 "$BU/locked"
  silent "$rc" && ok "S39-PY-15 edit_hook: true, a bundle folder nobody may enter, a note with an L1 error: exit 0 and no output (fail-open: the scoped check stops with exit 2, the hook says nothing)" \
    || bad "S39-PY-15 fail-open on an unreadable folder" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
else
  skip "S39-PY-15 a folder nobody may enter: root enters it anyway"
fi

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
mkdir -p "$SHORT/on/q"; printf -- '---\ntitle: T\nstatus: draft\nverified:\n  by: human:t\n  at: "2026-01-02"\n---\nb\n' > "$SHORT/on/q/many.md"
rc=$(fire "$SHORT/on/q/many.md")
{ [ "$rc" = 2 ] && [ "$(wc -l < "$TMP/err.txt" | tr -d ' ')" = 1 ] && grep -q 'L1 error.*(+1 more: okf-check .* --file .*many.md)$' "$TMP/err.txt"; } \
  && ok "SH-3 two findings are still one line: the first, then '(+1 more: okf-check <bundle> --file <note>)'" \
  || bad "SH-3 more" "rc=$rc err: $(cat "$TMP/err.txt" | tr '\n' '|')"
# SH-3b: the same note under a longer path, still under $SHORT so its length is the same on every host: the full hint
# would be about 210 to 230 characters, more than half of max_line_chars (300) and less than all of it, so it pins that the
# threshold is half: the hint keeps only its count, and the line stays within max_line_chars.
LQ="$SHORT/on/$(printf 'long-folder-name-%s/' 1 2 3 4 5 6 7)"; mkdir -p "$LQ"; cp "$SHORT/on/q/many.md" "$LQ/many.md"
rc=$(fire "$LQ/many.md")
{ [ "$rc" = 2 ] && [ "$(wc -l < "$TMP/err.txt" | tr -d ' ')" = 1 ] && grep -q 'L1 error.* (+1 more)$' "$TMP/err.txt" && ! grep -q -- '--file' "$TMP/err.txt"; } \
  && ok "SH-3b under a long path the hint is the short '(+1 more)', without the command" \
  || bad "SH-3b short hint" "rc=$rc err: $(cut -c1-200 "$TMP/err.txt" | tr '\n' '|')"
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
# SH-9: an unusable OKF_EDIT_HOOK_TIMEOUT falls back to the default box (SH-11), which still fires: nothing left running.
CP2="$TMP/plugin-copy2"; cp -R "$HERE/.." "$CP2"; MARK2="okf-edit-hook-badbox-$$"
printf '#!/usr/bin/env bash\nsh -c "sleep 30; : %s" &\nwait\n' "$MARK2" > "$CP2/scripts/okf-check"
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$B/sub/bad.md" \
  | boxed 20 env OKF_EDIT_HOOK_TIMEOUT=abc "$REALPY" "$CP2/scripts/okf-edit-hook.py" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
sleep 1; left=$(procs "$MARK2")
if [ "$left" = SKIP ]; then skip "SH-9 bad time box: no ps or /proc here to count a left-running check"
else
  { silent "$rc" && [ "$left" = 0 ]; } && ok "SH-9 OKF_EDIT_HOOK_TIMEOUT=abc: the default box fires on a hung check: exit 0, no output, nothing left running" \
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

# --- B-7: hook values that used to switch the hook off without a word (spec row HK-1) -----------------------------------------
# SH-11: a time box that is not a positive number (nan, 0, -1, abc) falls back to config timeout_seconds, so the check
# still runs and warns. min(nan, 4.5) was nan, and 0 or -1 fired the box at once: the hook was silently off.
for v in nan 0 -1 abc ''; do
  rc=$(fire "$B/sub/bad.md" "OKF_EDIT_HOOK_TIMEOUT=$v")
  { [ "$rc" = 2 ] && grep -q 'L1 error' "$TMP/err.txt"; } \
    && ok "SH-11 OKF_EDIT_HOOK_TIMEOUT='$v' uses the default box: the L1 error is still reported" \
    || bad "SH-11 time box '$v'" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
done
# SH-12: an unquoted YAML 1.1 word (yes, on) is not `true`: the hook stays off AND okf-verify --check-config says why,
# so the switch is never off without a word.
for w in yes on; do
  BY="$TMP/yes-$w"; bundle "$BY" "okf_check:
  edit_hook: $w"
  badnote "$BY/bad.md"
  rc=$(fire "$BY/bad.md")
  out=$("$REALPY" "$HERE/okf-verify" "$BY" --check-config 2>&1); crc=$?
  { silent "$rc" && [ "$crc" = 2 ] && grep -q "okf_check.edit_hook must be true or false.*write true or false, not $w" <<<"$out"; } \
    && ok "SH-12 edit_hook: $w (unquoted) leaves the hook off and --check-config exits 2 naming it" \
    || bad "SH-12 edit_hook: $w" "rc=$rc crc=$crc out: $(printf '%s' "$out" | head -2 | tr '\n' '|')"
done
# SH-12c (review 0.9.35): only the okf_check block is read for those words: a comment or another block's `remote: no` is not refused.
BC="$TMP/yes-elsewhere"; bundle "$BC" '# To switch the graph layer off, write  graph: off
deploy:
  remote: no
okf_check:
  edit_hook: true  # yes, on'
"$REALPY" "$HERE/okf-verify" "$BC" --check-config >/dev/null 2>&1; crc=$?
[ "$crc" = 0 ] && ok "SH-12c a comment and another block's 'remote: no' are not read as okf_check options (exit 0)" || bad "SH-12c scope" "crc=$crc"
# SH-12d (review 0.9.35 round 3): a bracket inside a quoted value (a facts pattern) does not keep the block open.
BQ="$TMP/quoted-bracket"; bundle "$BQ" "okf_check:
  facts:
    version: {value: \"1.2\", patterns: ['Version \\[?(\\d+\\.\\d+)']}
deploy:
  remote: no"
"$REALPY" "$HERE/okf-verify" "$BQ" --check-config >/dev/null 2>&1; crc=$?
[ "$crc" = 0 ] && ok "SH-12d a bracket in a quoted pattern does not stretch the okf_check block over 'deploy: remote: no'" || bad "SH-12d quoted bracket" "crc=$crc $("$REALPY" "$HERE/okf-verify" "$BQ" --check-config 2>&1 | head -1)"
BT="$TMP/flow-true"; mkdir -p "$BT"; bundle "$BT" 'okf_check: {edit_hook: True}'
badnote "$BT/bad.md"
rc=$(fire "$BT/bad.md")
{ [ "$rc" = 2 ] && "$REALPY" "$HERE/okf-verify" "$BT" --check-config >/dev/null 2>&1; } \
  && ok "SH-12b edit_hook: True in flow style still switches the hook on" || bad "SH-12b True" "rc=$rc"
# SH-13: the 300-character cut applies to the first finding alone, so the '(+N more: ...)' hint survives a long finding.
LV="$SHORT/on/long"; mkdir -p "$LV"
"$REALPY" - "$LV/l.md" <<'PY'
import sys
by = "human:" + "B" * 2000   # two Trust warnings, the first one long
open(sys.argv[1], "w", encoding="utf-8").write("---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: draft\ngenerated:\n  by: human:t\n  at: \"2026-01-01\"\nverified:\n  - by: \"%s\"\n    at: \"2026-01-02\"\n  - by: \"human:c\"\n    at: \"2026-01-03\"\n---\nb\n" % by)
PY
rc=$(fire "$LV/l.md")
len=$(tr -d '\n' < "$TMP/err.txt" | wc -c | tr -d ' ')
{ [ "$rc" = 2 ] && grep -q '(+[0-9]* more: okf-check ' "$TMP/err.txt" && [ "$(wc -l < "$TMP/err.txt" | tr -d ' ')" = 1 ]; } \
  && ok "SH-13 a long first finding is cut, the '(+N more: ...)' hint is kept (${len} bytes)" \
  || bad "SH-13 hint kept" "rc=$rc err: $(cut -c1-160 "$TMP/err.txt" | tr '\n' '|')"

# SH-13b (review 0.9.35): the whole line stays within max_line_chars when the bundle path is long: the hint keeps its count
# and drops the command when the paths do not fit.
LP="$TMP/on/$(printf 'long-folder-name-%s/' 1 2 3 4 5 6 7 8 9 10 11 12)"; mkdir -p "$LP"; cp "$LV/l.md" "$LP/l.md"
rc=$(fire "$LP/l.md")
max=$("$REALPY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_line_chars"])' "$HERE/../config/edit-hook.json")
len=$(tr -d '\n' < "$TMP/err.txt" | "$REALPY" -c 'import sys; print(len(sys.stdin.read()))')
{ [ "$rc" = 2 ] && [ "$len" -le "$max" ] && grep -q '(+1 more' "$TMP/err.txt"; } \
  && ok "SH-13b with a long bundle path the line is ${len} characters (limit $max) and still says (+1 more" \
  || bad "SH-13b bounded line" "rc=$rc len=$len max=$max $(cut -c1-120 "$TMP/err.txt")"

# --- S32-HD (spec row HD-1): `okf-check --doctor` says plainly when a switched-on hook cannot run ----------------------------------------------
# The hook is fail-open: with config/edit-hook.json gone or unreadable it exits 0 without a word on every edit, so the user who
# switched it on sees no check and no reason. --doctor is the one place that can say so; it stays advisory (exit 0).
doctor() { "$1/okf-check" "$2" --doctor >"$TMP/doc.txt" 2>&1; printf '%s' "$?"; }
HD="$TMP/hd"; bundle "$HD/on" 'okf_check:
  edit_hook: true'; mkdir -p "$HD/on/sub"
rc=$(doctor "$HERE" "$HD/on")
{ [ "$rc" = 0 ] && grep -Eq '^  edit hook +ON \(.*okf-base.yaml\); config OK' "$TMP/doc.txt"; } \
  && ok "S32-HD-H1 edit_hook: true and a readable config: --doctor says the hook is ON and its config is OK" \
  || bad "S32-HD-H1 doctor, config readable" "rc=$rc $(grep -n 'edit hook' "$TMP/doc.txt" | head -2 | tr '\n' '|')"
CPD="$TMP/plugin-doc"; cp -R "$HERE/.." "$CPD"; rm "$CPD/config/edit-hook.json"
rc=$(doctor "$CPD/scripts" "$HD/on")
{ [ "$rc" = 0 ] && grep -Eq '^  edit hook +ON \(.*okf-base.yaml\) but CANNOT RUN: .*edit-hook.json' "$TMP/doc.txt" \
  && grep -q 'stays silent' "$TMP/doc.txt"; } \
  && ok "S32-HD-N1 edit_hook: true and config/edit-hook.json missing: --doctor says CANNOT RUN, names the file and that the hook stays silent (exit 0)" \
  || bad "S32-HD-N1 doctor, config missing" "rc=$rc $(grep -n -A1 'edit hook' "$TMP/doc.txt" | head -3 | tr '\n' '|')"
badnote "$HD/on/bad.md"
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$HD/on/bad.md" \
  | boxed 30 "$REALPY" "$CPD/scripts/okf-edit-hook.py" >"$TMP/out.txt" 2>"$TMP/err.txt"; hrc=$?
silent "$hrc" && ok "S32-HD-N1b the same plugin copy: the hook itself still exits 0 with no output (fail-open is unchanged)" \
  || bad "S32-HD-N1b fail-open unchanged" "rc=$hrc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
printf '{ not json' > "$CPD/config/edit-hook.json"
rc=$(doctor "$CPD/scripts" "$HD/on")
{ [ "$rc" = 0 ] && grep -Eq 'but CANNOT RUN: .*edit-hook.json' "$TMP/doc.txt"; } \
  && ok "S32-HD-N2 a config that is not JSON: CANNOT RUN" || bad "S32-HD-N2 doctor, config not JSON" "rc=$rc $(grep -n 'edit hook' "$TMP/doc.txt" | head -2 | tr '\n' '|')"
printf '{"timeout_seconds": 4}' > "$CPD/config/edit-hook.json"
rc=$(doctor "$CPD/scripts" "$HD/on")
{ [ "$rc" = 0 ] && grep -Eq 'but CANNOT RUN: .*edit-hook.json' "$TMP/doc.txt"; } \
  && ok "S32-HD-N3 a config without max_seconds and max_line_chars: CANNOT RUN" || bad "S32-HD-N3 doctor, config keys missing" "rc=$rc $(grep -n 'edit hook' "$TMP/doc.txt" | head -2 | tr '\n' '|')"
bundle "$HD/off" ''
rc=$(doctor "$CPD/scripts" "$HD/off")
{ [ "$rc" = 0 ] && ! grep -q 'edit hook' "$TMP/doc.txt"; } \
  && ok "S32-HD-N4 hook off (no key): --doctor adds no edit-hook line, even with the config missing" || bad "S32-HD-N4 doctor, hook off" "rc=$rc $(grep -n 'edit hook' "$TMP/doc.txt" | head -2 | tr '\n' '|')"
rc=$(doctor "$HERE" "$HD/on/sub")
HDP=$(cd -P "$HD/on" && pwd)   # the hook resolves links (macOS /var is /private/var)
{ [ "$rc" = 0 ] && grep -Fq "($HDP/okf-base.yaml)" "$TMP/doc.txt"; } \
  && ok "S32-HD-E1 from a folder below the bundle, --doctor names the okf-base.yaml that switches the hook on" \
  || bad "S32-HD-E1 doctor, nearest manifest" "rc=$rc $(grep -n 'edit hook' "$TMP/doc.txt" | head -2 | tr '\n' '|')"
cp "$HERE/../config/edit-hook.json" "$CPD/config/edit-hook.json"
# S32-HD-N5: a bad okf_check block reads as "hook off" (the hook is fail-open), so --doctor has to say so: the user who wrote
# edit_hook: true sees no check and no reason otherwise. The full run reports the block; the hook itself stays silent.
bundle "$HD/bad" 'okf_check: {edit_hook: true, bogus_key: 1}'; badnote "$HD/bad/bad.md"
rc=$(doctor "$HERE" "$HD/bad")
HDB=$(cd -P "$HD/bad" && pwd)
{ [ "$rc" = 0 ] && grep -Eq "^  edit hook +OFF: $HDB/okf-base.yaml okf_check block is invalid \(.*bogus_key.*\); the hook reads it as off" "$TMP/doc.txt"; } \
  && ok "S32-HD-N5 an invalid okf_check block: --doctor prints 'edit hook OFF: <okf-base.yaml> okf_check block is invalid (...)', exit 0" \
  || bad "S32-HD-N5 doctor, invalid block" "rc=$rc $(grep -n 'edit hook' "$TMP/doc.txt" | head -2 | cut -c1-240 | tr '\n' '|')"
rc=$(fire "$HD/bad/bad.md")
silent "$rc" && ok "S32-HD-N5b the same bundle: the hook itself still exits 0 with no output (fail-open is unchanged)" \
  || bad "S32-HD-N5b fail-open unchanged" "rc=$rc err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"
OKF_EDIT_HOOK=1 "$CPD/scripts/okf-check" "$HD/off" --doctor >"$TMP/doc.txt" 2>&1; rc=$?
rm "$CPD/config/edit-hook.json"; OKF_EDIT_HOOK=1 "$CPD/scripts/okf-check" "$HD/off" --doctor >"$TMP/doc2.txt" 2>&1
{ [ "$rc" = 0 ] && grep -Eq '^  edit hook +ON \(OKF_EDIT_HOOK=1\); config OK' "$TMP/doc.txt" \
  && grep -Eq '^  edit hook +ON \(OKF_EDIT_HOOK=1\) but CANNOT RUN' "$TMP/doc2.txt"; } \
  && ok "S32-HD-E2 OKF_EDIT_HOOK=1 switches it on without the key: --doctor reports it, with the config and without" \
  || bad "S32-HD-E2 doctor, env switch" "rc=$rc $(grep -h 'edit hook' "$TMP/doc.txt" "$TMP/doc2.txt" | head -2 | tr '\n' '|')"

echo
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
