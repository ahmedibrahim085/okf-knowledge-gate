#!/usr/bin/env bash
# Tests for okf-check's scoped mode, `okf-check <bundle> --file <note>`: L1 and Trust for one note, one line per
# finding, exit codes unchanged. It is what an edit hook calls (okf-knowledge-gate#8), so it must be quiet on a clean
# note and fast. Supports case S9-H1 .
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

# --- the near-miss wording has one home: the validator's -----------------------------------------------------
# --strict-trust counts the validator's near-miss warning by its text, in okf-check's full run and here. Both copies of that
# text were typed again beside the validator's own, so a reworded warning silently stopped blocking under --strict-trust.
# The probe rewords the validator in a copy of the plugin: both runs must still block. (SC-4 and LT-27e/i pin the text only
# while the three copies agree.)
N="$TMP/nm"; mkdir -p "$N"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$N/index.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: stable\ngenerated:\n  by: Human:dana\n  at: "2026-01-01"\n---\nbody\n' > "$N/m.md"
rc_full=$("$CHECK" "$N" --strict-trust >"$TMP/nm-full.txt" 2>&1; printf '%s' "$?")
rc_file=$(run "$N" --file "$N/m.md" --strict-trust)
CN="$TMP/plugin-reworded"; cp -R "$HERE/.." "$CN"
n=$(grep -c 'is a near-miss of' "$CN/vendor/okf_validate.py")
sed -i.orig 's/is a near-miss of/resembles/g' "$CN/vendor/okf_validate.py"
cmp -s "$CN/vendor/okf_validate.py" "$CN/vendor/okf_validate.py.orig" && echo "  (reword changed nothing)"
rm -f "$CN/vendor/okf_validate.py.orig"
rm -rf "$CN/vendor/__pycache__"
mrc_full=$("$CN/scripts/okf-check" "$N" --strict-trust >"$TMP/nm-mfull.txt" 2>&1; printf '%s' "$?")
mrc_file=$("$CN/scripts/okf-check" "$N" --file "$N/m.md" --strict-trust >"$TMP/nm-mfile.txt" 2>&1; printf '%s' "$?")
{ [ "$rc_full" = 1 ] && [ "$rc_file" = 1 ] && [ "$n" -ge 1 ] && grep -q 'resembles' "$TMP/nm-mfull.txt" && grep -q 'resembles' "$TMP/nm-mfile.txt" \
  && [ "$mrc_full" = 1 ] && [ "$mrc_file" = 1 ]; } \
  && ok "SC-11 a near-miss actor blocks under --strict-trust in the full run and with --file, also when the validator words its warning differently" \
  || bad "SC-11 near-miss wording" "unmodified full=$rc_full file=$rc_file; reworded full=$mrc_full file=$mrc_file ($(grep -c resembles "$TMP/nm-mfull.txt") / $(grep -c resembles "$TMP/nm-mfile.txt") lines say resembles)"

# SC-12: the near-miss wording cannot be read from the validator (a broken install: the constant is gone, the validator still
# runs and still words the warning). --strict-trust must not read that as "no near-miss": Trust policy COULD NOT RUN, exit 2.
CU="$TMP/plugin-unreadable"; cp -R "$HERE/.." "$CU"
"$REALPY" - "$CU/vendor/okf_validate.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
assert s.count("NEAR_MISS_WORDING") == 2   # the definition and the one use in check_actor
open(p, "w", encoding="utf-8").write(s.replace("NEAR_MISS_WORDING", "NEAR_MISS_PRIVATE"))
PY
urc=$("$CU/scripts/okf-check" "$N" --strict-trust >"$TMP/nm-unread.txt" 2>&1; printf '%s' "$?")
urc0=$("$CU/scripts/okf-check" "$N" >"$TMP/nm-unread0.txt" 2>&1; printf '%s' "$?")
{ [ "$urc" = 2 ] && grep -Eq "Trust policy +COULD NOT RUN +the validator's near-miss wording could not be read" "$TMP/nm-unread.txt" \
  && grep -q 'near-miss of' "$TMP/nm-unread.txt" && [ "$urc0" = 0 ] && ! grep -q 'Trust policy' "$TMP/nm-unread0.txt"; } \
  && ok "SC-12 --strict-trust with an unreadable near-miss wording is exit 2 'Trust policy COULD NOT RUN' (L1 still lists the near-miss); without --strict-trust the run is unchanged" \
  || bad "SC-12 unreadable wording" "strict rc=$urc plain rc=$urc0 $(grep -n 'Trust policy\|near-miss' "$TMP/nm-unread.txt" | head -3 | tr '\n' '|')"

# --- a verified list of bare strings: Trust reads the claim (slice trust-reads-a-verified-list-of-bare-strings) --
# L1 warns that a verified entry is not a `{by, at}` mapping, and the claim is still in the file: Trust reads a bare string
# as its `by` actor, as it already reads the scalar `verified: human:dana`. Before this, --file printed the L1 warning alone
# and exited 0 even under --strict-trust, while the mapping form of the same note exited 1.
TB="$TMP/bare"; mkdir -p "$TB"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$TB/index.md"
bare() { # <file> <verified block>
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: draft\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\n%s\nstale_after: "2099-01-01"\n---\nbody\n' "$2" > "$TB/$1"
}
bare_with() { # <file> <status> <generated.by> <verified block>
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: %s\ngenerated:\n  by: %s\n  at: "2026-01-01"\n%s\nstale_after: "2099-01-01"\n---\nbody\n' "$2" "$3" "$4" > "$TB/$1"
}
bare n.md "$(printf 'verified:\n  - human:dana')"
rc=$(run "$TB" --file "$TB/n.md" --strict-trust)
{ [ "$rc" = 1 ] && [ "$(wc -l < "$TMP/out.txt" | tr -d ' ')" = 2 ] \
  && grep -qxF 'n.md: L1 warning: §5.2 every `verified` entry needs a `by` actor' "$TMP/out.txt" \
  && grep -qxF 'n.md: Trust warning: verified[0].by `human:dana` on a draft note: draft with human verification' "$TMP/out.txt"; } \
  && ok "SC-TB1 a verified list of bare strings on a draft note: --file prints the Trust warning and --strict-trust exits 1" \
  || bad "SC-TB1 bare string, --file --strict-trust" "rc=$rc out: $(head -5 "$TMP/out.txt" | tr '\n' '|')"

rc=$(run "$TB" --file "$TB/n.md")
{ [ "$rc" = 0 ] && grep -qxF 'n.md: Trust warning: verified[0].by `human:dana` on a draft note: draft with human verification' "$TMP/out.txt"; } \
  && ok "SC-TB2 the same note without --strict-trust: the same Trust warning, exit 0 (the flag decides severity only)" \
  || bad "SC-TB2 bare string, --file" "rc=$rc out: $(head -5 "$TMP/out.txt" | tr '\n' '|')"

# The scoped line and the whole-bundle line carry the same finding (the SC-3/SC-4 rule): one reading of the entry, two reports.
full=$("$CHECK" "$TB" --strict-trust >"$TMP/tb-full.txt" 2>&1; printf '%s' "$?")
f=$(sed -n 's/^ *n\.md: //p' "$TMP/tb-full.txt" | grep -F 'verified[0].by `human:dana` on a draft note' | head -1)
s=$(sed -n 's/^n\.md: Trust warning: //p' "$TMP/out.txt" | head -1)
{ [ "$full" = 1 ] && [ -n "$f" ] && [ "$f" = "$s" ]; } \
  && ok "SC-TB3 the whole-bundle run and --file print the same finding for a bare-string note ('$s')" \
  || bad "SC-TB3 bare string, scoped vs full" "full rc=$full full='$f' scoped='$s'"

# Hostile text: the actor is printed verbatim, so a newline in it must be spelled, not obeyed. One Trust line for the entry
# and no line carrying the string's own `Trust warning: forged` text. (L1's own message keeps the raw newline: its wording
# is the validator's, out of this slice.)
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: draft\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - "human:dana\\nTrust warning: forged"\nstale_after: "2099-01-01"\n---\nbody\n' > "$TB/nl.md"
rc=$(run "$TB" --file "$TB/nl.md" --strict-trust)
{ [ "$rc" = 1 ] && [ "$(grep -cF 'nl.md: Trust warning: verified[0].by `human:dana\x0aTrust warning: forged` on a draft note: draft with human verification' "$TMP/out.txt")" = 1 ] \
  && ! grep -q '^Trust warning: forged' "$TMP/out.txt"; } \
  && ok "SC-TB4 a bare string holding a newline: one Trust line, the newline spelled \\x0a, no forged finding line" \
  || bad "SC-TB4 bare string, newline in the actor" "rc=$rc out: $(head -6 "$TMP/out.txt" | tr '\n' '|')"

# The same reading through --file for the other two rows: the advisory (a stable note an agent generated) and the look-alike
# actor. Parity is one shared function, so the rows must answer here as they do in the whole run, not only the draft row.
bare_with adv.md stable agent/1 "$(printf 'verified:\n  - human:dana')"
rc=$(run "$TB" --file "$TB/adv.md" --strict-trust)
{ [ "$rc" = 1 ] && grep -qxF 'adv.md: Trust advisory: verified[0].by `human:dana` on a note generated by `agent/1`: a human review of an agent note cannot be authenticated' "$TMP/out.txt"; } \
  && ok "SC-TB5 a bare string on a stable agent-generated note: --file prints the advisory and --strict-trust exits 1" \
  || bad "SC-TB5 bare string, advisory row, --file" "rc=$rc out: $(head -5 "$TMP/out.txt" | tr '\n' '|')"

CYR=$(printf 'hum\xd0\xb0n')     # "humаn": the third letter is CYRILLIC SMALL LETTER A
bare look.md "verified:
  - ${CYR}:dana"
rc=$(run "$TB" --file "$TB/look.md" --strict-trust)
{ [ "$rc" = 1 ] && grep -qF 'only looks like `human:`' "$TMP/out.txt"; } \
  && ok "SC-TB6 a bare string that only looks like human: --file prints the look-alike warning and --strict-trust exits 1" \
  || bad "SC-TB6 bare string, look-alike row, --file" "rc=$rc out: $(head -5 "$TMP/out.txt" | tr '\n' '|')"

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
  && grep -q 'NOT FIRED' <<<"$(grep -A1 '^  Scoped (--file):' "$TMP/st-silent.txt")"; } \
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

# S36-ON-SC: with a .okfignore that excludes a note, --file on a note named with a byte that is not UTF-8 still checks it
# (the keep list was decoded with errors="replace", so the note matched nothing and its broken link went unreported: 0.9.40).
# A disk that refuses the name (APFS) skips the case.
U8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
O="$TMP/on-sc"; mkdir -p "$O"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$O/index.md"
clean "$O/ign.md"; printf 'ign.md\n' > "$O/.okfignore"
N="n$(printf '\377')u.md"
clean "$O/$N" 2>/dev/null; printf 'See [m](nowhere.md).\n' 2>/dev/null >> "$O/$N"
if [ ! -f "$O/$N" ]; then
  printf '  SKIP  %s\n' "S36-ON-SC this disk refuses a note name that is not UTF-8 (run on Linux)"
elif [ -z "$U8" ]; then
  printf '  SKIP  %s\n' "S36-ON-SC no UTF-8 locale here (locale -a lists neither C.UTF-8 nor en_US.UTF-8)"
else
  for LOC in C "$U8"; do
    LC_ALL="$LOC" "$CHECK" "$O" --file "$O/$N" >"$TMP/out.txt" 2>&1; rc=$?
    n=$(LC_ALL=C grep -a -c 'L1 warning: .*nowhere.md' "$TMP/out.txt")
    [ "$n" = 1 ] && ok "S36-ON-SC under LC_ALL=$LOC --file on a non-UTF-8-named note reports its broken link with a .okfignore present (exit $rc)" \
      || bad "S36-ON-SC odd name with .okfignore under $LOC" "rc=$rc $(head -2 "$TMP/out.txt" | cat -v | tr '\n' '|')"
  done
fi

# S39-PY-14: --file runs the same unreadable-folder guard as the full run, before it reads anything. A sub-folder nobody may enter
# (mode 000) or that lists but cannot be entered (mode 0400) is exit 2 and the named message, on every Python; it used to be
# "cross-link target not found" (000, and 0400 on 3.14 and later, exit 0) or a PermissionError (0400 before 3.14, exit 2).
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP  S39-PY-14 a folder nobody may enter: root enters it anyway\n'
else
  for mode in 0400 000; do
    P="$TMP/py$mode"; mkdir -p "$P/sub"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$P/index.md"; clean "$P/n.md"; clean "$P/sub/m.md"
    printf 'See [m](sub/m.md).\n' >> "$P/n.md"
    chmod $mode "$P/sub"; rc=$(run "$P" --file "$P/n.md"); chmod 755 "$P/sub"
    { [ "$rc" = 2 ] && grep -q 'contains directories this process cannot read' "$TMP/out.txt" && grep -q "unreadable: .*py$mode/sub" "$TMP/out.txt" \
        && ! grep -q 'PermissionError\|not found\|Traceback' "$TMP/out.txt"; } \
      && ok "S39-PY-14 --file with a mode-$mode sub-folder: 'contains directories this process cannot read', exit 2, no PermissionError, no 'not found'" \
      || bad "S39-PY-14 --file, sub-folder mode $mode" "rc=$rc $(head -3 "$TMP/out.txt" | cut -c1-160 | tr '\n' '|')"
  done
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
