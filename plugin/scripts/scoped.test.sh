#!/usr/bin/env bash
# Tests for okf-check's scoped mode, `okf-check <bundle> --file <note>`: L1 and Trust for one note, one line per
# finding, exit codes unchanged. It is what an edit hook calls (okf-knowledge-gate#8), so it must be quiet on a clean
# note and fast. Supports case S9-H1 (docs/gherkin/s09-edit-hook.feature).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
REALPY=$(command -v python3)
PASS=0; FAIL=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfscoped)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

# clean <path>: a note with every field L1 recommends, so it produces no finding of its own.
clean() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: stable\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$1"
}
# run <args...>: exit code printed, output in $TMP/out.txt
run() { "$CHECK" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }

B="$TMP/b"
mkdir -p "$B"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$B/index.md"
clean "$B/good.md"
printf -- '---\ntitle: T\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$B/bad.md"   # only `type` missing

# --- a note with an L1 error: one line, exit 1 ---------------------------------------------------
rc=$(run "$B" --file "$B/bad.md")
{ [ "$rc" = 1 ] && [ "$(wc -l < "$TMP/out.txt" | tr -d ' ')" = 1 ] \
  && grep -qxF 'bad.md: L1 error: §11.2 missing or empty required `type` field' "$TMP/out.txt"; } \
  && ok "SC-1 a note without type: exactly one line 'bad.md: L1 error: ...type...', exit 1" \
  || bad "SC-1 bad note" "rc=$rc out: $(head -5 "$TMP/out.txt" | tr '\n' '|')"

# --- a clean note: nothing printed, exit 0 --------------------------------------------------------
rc=$(run "$B" --file "$B/good.md")
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "SC-2 a clean note prints nothing and exits 0" \
  || bad "SC-2 clean note" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"

# --- the scoped findings are the full run's findings for that note -------------------------------
# One note with an L1 warning (no tags), a broken link, a near-miss actor and a human verification on a draft.
# The full validator and okf-trust.py runs are the independent source; another note's findings (other.md's broken
# link, which the bundle-wide link check also finds) must not leak in.
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\n---\nSee [x](/nowhere.md).\n' > "$B/other.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: draft\ngenerated:\n  by: Human:dana\n  at: "2026-01-01"\nverified:\n  by: human:t\n  at: "2026-01-02"\n---\nSee [gone](/gone.md) and [ok](good.md).\n' > "$B/sub.md"
rc=$(run "$B" --file "$B/sub.md")
want=$( { PYTHONPATH="$HERE/../vendor/pyyaml" "$REALPY" "$HERE/../vendor/okf_validate.py" "$B" --json 2>/dev/null \
            | "$REALPY" -c 'import json,sys; d=json.load(sys.stdin)
for k,lab in (("errors","error"),("warnings","warning")):
    for m in d[k]:
        if m.startswith("sub.md: "): print("sub.md: L1 %s: %s" % (lab, m[8:]))'
          PYTHONPATH="$HERE/../vendor/pyyaml" "$REALPY" "$HERE/okf-trust.py" "$B" "$TMP/trust.json" >/dev/null 2>&1
          "$REALPY" -c 'import json,sys
for r in json.load(open(sys.argv[1])):
    if r["file"] == "sub.md": print("sub.md: Trust %s: %s %s" % (r["severity"], r["entry"], r["reason"]))' "$TMP/trust.json"; } | sort)
got=$(sort "$TMP/out.txt")
{ [ "$rc" = 0 ] && [ -n "$want" ] && [ "$got" = "$want" ] && grep -q 'cross-link target not found' "$TMP/out.txt" \
  && grep -q 'near-miss' "$TMP/out.txt" && grep -q 'Trust warning' "$TMP/out.txt" && ! grep -q 'bad.md\|other.md\|nowhere' "$TMP/out.txt"; } \
  && ok "SC-3 scoped findings equal the full validator + okf-trust findings for the note (link, near-miss, trust); none from other notes; warnings exit 0" \
  || bad "SC-3 scoped vs full" "rc=$rc got: $(printf '%s' "$got" | tr '\n' '|') want: $(printf '%s' "$want" | tr '\n' '|')"

# --- --strict-trust: a Trust warning or a near-miss actor blocks (exit 1), as in a full run --------
rc=$(run "$B" --file "$B/sub.md" --strict-trust)
[ "$rc" = 1 ] && ok "SC-4 with --strict-trust the same note exits 1" || bad "SC-4 strict-trust" "rc=$rc"

# --- usage errors exit 64 and check nothing -------------------------------------------------------
mkdir -p "$TMP/elsewhere"; clean "$TMP/elsewhere/x.md"; printf 'x\n' > "$B/notes.txt"
r1=$(run "$B" --file "$TMP/elsewhere/x.md"); g1=$(grep -c 'not inside' "$TMP/out.txt")
r2=$(run "$B" --file "$B/notes.txt");        g2=$(grep -c 'not a .md' "$TMP/out.txt")
r3=$(run "$B" --file "$B/missing.md");       g3=$(grep -c 'not a file' "$TMP/out.txt")
r4=$(run "$B" --file);                       g4=$(grep -c 'usage' "$TMP/out.txt")
[ "$r1$r2$r3$r4" = "64646464" ] && [ "$g1$g2$g3$g4" = "1111" ] \
  && ok "SC-5 a note outside the bundle, a non-.md file, a missing file and a missing value each exit 64 with a reason" \
  || bad "SC-5 usage" "exits=$r1,$r2,$r3,$r4 reasons=$g1,$g2,$g3,$g4"

# --- a note the .okfignore excludes is not checked, as in a full run ------------------------------
printf 'bad.md\n' > "$B/.okfignore"
rc=$(run "$B" --file "$B/bad.md")
{ [ "$rc" = 0 ] && grep -qxF 'bad.md: not checked (.okfignore excludes it)' "$TMP/out.txt"; } \
  && ok "SC-6 a note .okfignore excludes is not checked: one line says so, exit 0" \
  || bad "SC-6 okfignore" "rc=$rc out: $(head -2 "$TMP/out.txt" | tr '\n' '|')"
rm -f "$B/.okfignore"

# --- a helper that crashes is "could not run" (exit 2), never an L1 verdict ------------------------
CP="$TMP/plugin-copy"; cp -R "$HERE/.." "$CP"
printf 'raise RuntimeError("boom")\n' > "$CP/scripts/okf-scoped.py"
"$CP/scripts/okf-check" "$B" --file "$B/good.md" > "$TMP/out.txt" 2>&1; rc=$?
{ [ "$rc" = 2 ] && grep -q 'could not run' "$TMP/out.txt"; } \
  && ok "SC-7 a crashing helper (python exit 1, no finding printed) is exit 2 'could not run', not an L1 error" \
  || bad "SC-7 crash" "rc=$rc out: $(tail -2 "$TMP/out.txt" | tr '\n' '|')"

# --- --selftest has a Scoped probe (project rule: every okf-check layer is probed) --------------------
# The failure that matters is the silent one: a helper that keeps no finding prints nothing and exits 0, which the edit
# hook reads as a clean note. The crippled copy drops every finding by filtering on a prefix no finding has.
"$CHECK" --selftest > "$TMP/st.txt" 2>&1; rc=$?
fired=$(grep -A1 '^  Scoped (--file):' "$TMP/st.txt" | grep -c 'FIRED  *note without frontmatter')
CS="$TMP/plugin-silent"; cp -R "$HERE/.." "$CS"
sed -i.orig 's/m.startswith(rel + ": ")/m.startswith(rel + ":: ")/g' "$CS/scripts/okf-scoped.py"
cmp -s "$CS/scripts/okf-scoped.py" "$CS/scripts/okf-scoped.py.orig" && echo "  (cripple changed nothing)"
"$CS/scripts/okf-check" --selftest > "$TMP/st-silent.txt" 2>&1; rcs=$?
{ [ "$rc" = 0 ] && [ "$fired" = 1 ] && [ "$rcs" = 5 ] \
  && grep -A1 '^  Scoped (--file):' "$TMP/st-silent.txt" | grep -q 'NOT FIRED'; } \
  && ok "SC-9 --selftest has a Scoped probe that fires, and a copy whose helper drops every finding reports NOT FIRED and exits 5" \
  || bad "SC-9 Scoped selftest probe" "healthy rc=$rc fired=$fired; crippled rc=$rcs $(grep -n 'Scoped\|SELFTEST' "$TMP/st-silent.txt" | tr '\n' ' ')"

# --- under 1 s on a 100-note bundle (acceptance), measured ---------------------------------------
H="$TMP/h100"; mkdir -p "$H/sub"; printf -- '---\nokf_version: "0.2"\n---\n# H\n' > "$H/index.md"
i=1; while [ "$i" -le 100 ]; do d="$H"; [ $((i % 2)) -eq 0 ] && d="$H/sub"; clean "$d/n$i.md"; i=$((i+1)); done
# The bound is relative to a full run on the same bundle. An absolute "under 1 s" failed once in 16 runs on a loaded host
# (load average about 6), and it could not catch a --file that checks the whole bundle: the full run of these 100 notes
# takes about 0.65 s. A load spike slows both runs; a whole-bundle --file is as slow as the full run.
# Every run counts, nothing is retried: the scoped time is the median of 3 runs, the full time is one run.
timing=$("$REALPY" - "$CHECK" "$H" <<'PY'
import subprocess, sys, time
def secs(*args):
    t = time.time(); subprocess.run([sys.argv[1], sys.argv[2], *args], capture_output=True); return time.time() - t
scoped = sorted(secs("--file", sys.argv[2] + "/sub/n50.md") for _ in range(3))[1]
print("%.2f %.2f" % (scoped, secs()))
PY
)
secs=${timing% *}; full=${timing#* }
"$REALPY" -c "import sys; s, f = float('$secs'), float('$full'); sys.exit(0 if s < f / 2 else 1)" \
  && ok "SC-8 --file on a 100-note bundle takes ${secs} s (median of 3), under half the full run (${full} s)" \
  || bad "SC-8 time" "${secs} s on 100 notes, full run ${full} s"

# --- 0.9.12 review ---------------------------------------------------------------------------------------------
# SC-10 (HIGH): the findings are the full run's, including with a .okfignore: a link to a note the ignore file
# excludes is a broken link in the full run (it checks a filtered mirror), so --file must report it too.
I="$TMP/ign"; mkdir -p "$I"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$I/index.md"
clean "$I/ign.md"; printf 'ign.md\n' > "$I/.okfignore"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\n---\nSee [i](ign.md).\n' > "$I/links.md"
"$CHECK" "$I" > "$TMP/full-ign.txt" 2>&1
rc=$(run "$I" --file "$I/links.md")
{ grep -q 'links.md: cross-link target not found' "$TMP/full-ign.txt" && grep -q 'links.md: L1 warning: .*cross-link target not found' "$TMP/out.txt"; } \
  && ok "SC-10 a link to a note .okfignore excludes is reported by --file as the full run reports it" \
  || bad "SC-10 okfignore link" "rc=$rc scoped: $(head -3 "$TMP/out.txt" | tr '\n' '|') full: $(grep -c 'links.md' "$TMP/full-ign.txt") lines"
# SC-11 (MEDIUM): --file twice is refused (the last used to win, silently); SC-12: --json is refused;
# SC-13: a relative note whose name starts with a dash is a note, not a flag; SC-14: a newline in the name is refused.
mkdir -p "$B/s"; clean "$B/s/x.md"
r1=$(run "$B" --file "$B/good.md" --file "$B/bad.md"); g1=$(grep -c 'twice' "$TMP/out.txt")
r2=$(run "$B" --file "$B/good.md" --json); g2=$(grep -c 'json' "$TMP/out.txt")
{ [ "$r1" = 64 ] && [ "$g1" = 1 ] && [ "$r2" = 64 ] && [ "$g2" -ge 1 ]; } \
  && ok "SC-11 --file given twice and --file with --json each exit 64 with a reason" \
  || bad "SC-11 twice/json" "twice rc=$r1 reason=$g1; json rc=$r2 reason=$g2"
clean "$B/-d.md"; r3=$( cd "$B" && "$CHECK" "$B" --file -d.md >"$TMP/out.txt" 2>&1; printf '%s' "$?")
NL="$B/nl"; mkdir -p "$NL"; clean "$NL/$(printf 'n\nl').md"
r4=$(run "$B" --file "$NL/$(printf 'n\nl').md")
{ [ "$r3" = 0 ] && [ "$r4" = 64 ] && grep -qi 'newline' "$TMP/out.txt"; } \
  && ok "SC-12 a dash-leading relative note name is read as a note (exit 0); a newline in the name is refused (64)" \
  || bad "SC-12 odd names" "dash rc=$r3; newline rc=$r4 out: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
