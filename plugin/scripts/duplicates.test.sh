#!/usr/bin/env bash
# Tests for the limits of `okf-check --duplicates` / `--duplicates-body` (backlog F-7; cases S25-DU-* in docs/0.9.x-cases.md).
#
# The report is advisory (always exit 0), so what it says about how far it got is the whole contract: a stub body is
# not a duplicate signal, the time limit covers reading the notes too, and a cut in the body pass names that pass.
# OKF_DUP_TIME_LIMIT and OKF_DUP_CUT_AT (tests only) make every cut deterministic.
#
# Spec row DU-1. bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"

# note <file> <title> <body>: a stable Lesson with that title and body (descriptions differ, so only the body can pair).
note() { printf -- '---\ntype: Lesson\ntitle: %s\ndescription: Item %s\nstatus: stable\nstale_after: "2099-01-01"\n---\n%s\n' "$2" "$2" "$3" > "$1"; }
run()  { local b="$1"; shift; "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
runjson() { local b="$1"; shift; "$CHECK" --json "$b" "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }
P="Run the migration on a copy of the production database first and check the row counts against the source tables."

section "stub bodies"
# S25-DU-H1: three stubs with the body TODO are not three body duplicates (each scored 1.00 as one shared shingle);
# the report says how many bodies were too short to compare.
B="$TMP/stubs"; mkbundle "$B"; rm "$B/c.md"
for i in 1 2 3; do note "$B/s$i.md" "Stub $i" "TODO"; done
rc=$(run "$B" --duplicates-body)
{ [ "$rc" = 0 ] && grep -q 'no candidate duplicates' "$TMP/out.txt" \
  && grep -Eq '3 note\(s\) with a body under 5 words not compared on body' "$TMP/out.txt"; } \
  && ok "S25-DU-H1 three TODO stubs are not body duplicates; the report counts 3 bodies under 5 words" \
  || bad "S25-DU-H1 stubs" "rc=$rc $(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|')"
rc=$(runjson "$B" --duplicates-body)
{ [ "$rc" = 0 ] && [ "$(jget 'd["body_short"]')" = 3 ] && [ "$(jget 'd["duplicates"]')" = "[]" ]; } \
  && ok "S25-DU-H1b --json body_short is 3 and no pair is listed" || bad "S25-DU-H1b json" "rc=$rc $(head -c 300 "$TMP/out.json")"
# S25-DU-H2: a stub still pairs on its title (the other signals are untouched).
note "$B/s4.md" "Stub 1" "TODO"
rc=$(run "$B" --duplicates-body)
{ [ "$rc" = 0 ] && grep -Eq 'title 1\.00 +s1\.md .* ~ +s4\.md' "$TMP/out.txt"; } \
  && ok "S25-DU-H2 a short-bodied note still pairs on its title" || bad "S25-DU-H2 title" "rc=$rc $(grep -n 'Duplicates\|~' "$TMP/out.txt" | head -3 | tr '\n' '|')"
# S25-DU-H3: two real bodies (5 words and more) still pair on body.
B="$TMP/real"; mkbundle "$B"; rm "$B/c.md"
note "$B/a.md" "Migrations" "$P Ask first."; note "$B/b.md" "Schema" "$P Write it down."
rc=$(run "$B" --duplicates-body)
{ [ "$rc" = 0 ] && grep -Eq 'body 0\.[0-9]+ +a\.md .* ~ +b\.md' "$TMP/out.txt" && ! grep -q 'under 5 words' "$TMP/out.txt"; } \
  && ok "S25-DU-H3 bodies of 5 words and more still pair on body; no short-body line" || bad "S25-DU-H3 body pair" "rc=$rc $(grep -n 'Duplicates\|~' "$TMP/out.txt" | head -3 | tr '\n' '|')"

section "cut short"
# S25-DU-E1: the limit covers reading the notes: a limit reached while reading says so, with how many notes were read.
rc=$(OKF_DUP_TIME_LIMIT=0.000001 run "$B" --duplicates)
{ [ "$rc" = 0 ] && grep -Eq 'CUT SHORT after 1e-06 s \(okf_check.duplicates.time_limit\) while reading notes: 0 of 2 notes read, no pair compared' "$TMP/out.txt"; } \
  && ok "S25-DU-E1 a limit reached while reading notes says CUT SHORT while reading, 0 of 2 notes read" \
  || bad "S25-DU-E1 read cut" "rc=$rc $(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|')"
rc=$(OKF_DUP_TIME_LIMIT=0.000001 runjson "$B" --duplicates)
{ [ "$rc" = 0 ] && [ "$(jget '[d["complete"], d["cut_in"], d["notes_read"], d["notes_total"]]')" = '[false, "read", 0, 2]' ]; } \
  && [ "$(jget 'd["pairs_total"]')" = 1 ] \
  && ok "S25-DU-E1b --json complete false, cut_in read, notes_read 0 of notes_total 2, pairs_total 1 (of all notes)" || bad "S25-DU-E1b json" "rc=$rc $(head -c 300 "$TMP/out.json")"
# S25-DU-E2: a cut in the body pass names that pass and does not read "N of N pairs compared".
rc=$(OKF_DUP_CUT_AT=body run "$B" --duplicates-body)
{ [ "$rc" = 0 ] && grep -Eq 'CUT SHORT .* in the body comparison: all 1 pairs compared on title, description and sources, bodies of 0 of 2 notes hashed' "$TMP/out.txt" \
  && ! grep -q '1 of 1 pairs compared' "$TMP/out.txt"; } \
  && ok "S25-DU-E2 a cut in the body pass says so (bodies of 0 of 2 notes hashed), not '1 of 1 pairs compared'" \
  || bad "S25-DU-E2 body cut wording" "rc=$rc $(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|')"
rc=$(OKF_DUP_CUT_AT=body runjson "$B" --duplicates-body)
{ [ "$rc" = 0 ] && [ "$(jget '[d["complete"], d["cut_in"]]')" = '[false, "body"]' ]; } \
  && ok "S25-DU-E2b --json cut_in body" || bad "S25-DU-E2b json" "rc=$rc $(head -c 300 "$TMP/out.json")"
# S25-DU-E4: the check inside an LSH bucket, with a fake clock instead of the wall clock: time.monotonic advances 1 per
# call, so where the cut falls is a count, the same on every machine and load. The tool runs in this process (exec of its
# own source, time patched first); 97 notes share one body, so each of the 32 band buckets holds all of them (4,656 pairs,
# never a multiple of the 1,000 checks between two looks at the clock). A first run without a limit counts the clock
# calls; the second gets a limit 12 calls short of that, which falls in the last buckets: the cut must come INSIDE a
# bucket (checks not a multiple of 4,656). Without the check in the bucket the tool looks at the clock only between
# buckets, makes fewer calls, and either finishes or stops on a bucket edge: the case fails.
B4="$TMP/fake"; mkdir -p "$B4"; cp "$HERE/../config/okf-base.yaml.template" "$B4/okf-base.yaml"
"$REALPY" - "$B4" <<'PY'
import sys
for i in range(97):
    open("%s/n%03d.md" % (sys.argv[1], i), "w").write('---\ntype: Lesson\ntitle: Note %d\ndescription: Item %d\nstatus: stable\nstale_after: "2099-01-01"\n---\nthe same six words in every note\n' % (i, i))
PY
cat > "$TMP/fakeclock.py" <<'PY'
import contextlib, io, os, sys, time
tool, bundle, schema, vendor, scripts = sys.argv[1:6]
os.environ.update(OKF_SCRIPTS_DIR=scripts, OKF_VENDOR_DIR=vendor)
sys.path.insert(0, os.path.join(vendor, "pyyaml"))
src = compile(open(tool, encoding="utf-8").read(), tool, "exec")
def run(limit, cut_at=""):
    calls = [0]
    def fake():
        calls[0] += 1
        return float(calls[0])
    os.environ["OKF_DUP_TIME_LIMIT"] = repr(limit)
    os.environ["OKF_DUP_CUT_AT"] = cut_at
    real, time.monotonic = time.monotonic, fake
    g = {"__name__": "__main__", "__file__": tool}
    sys.argv = [tool, bundle, schema, "1", "1"]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(src, g)
    except SystemExit:   # the tool ends a --json run with sys.exit(0) after printing its report
        pass
    finally:
        time.monotonic = real
    return calls[0], g
c, g = run(1e9)
per = 97 * 96 // 2
total = g["checked"]
n, g = run(c - 12)
inside = g["cut_in"] == "body" and g["checked"] < total and g["checked"] % per != 0
# The first bucket too: the clock calls up to the body pass (a run stopped there by OKF_DUP_CUT_AT=body), one per note
# while the bodies are signed, then 2 more: the limit falls at the third look at the clock inside the first bucket.
pre, _ = run(1e9, "body")
n1, g1 = run(pre + 97 + 2)
first = g1["cut_in"] == "body" and g1["checked"] < per and g1["checked"] % 1000 == 0
print("cut_in=%s checked=%d total=%d per=%d bands=%s inside=%s first=%s checked_first=%d" % (
    g["cut_in"], g["checked"], total, per, total == 32 * per, inside, first, g1["checked"]))
PY
fc=$("$REALPY" "$TMP/fakeclock.py" "${OKF_DUP_TOOL:-$HERE/okf-duplicates.py}" "$B4" "$HERE/../config/okf-check-block.json" "$HERE/../vendor" "$HERE" 2>&1)
grep -Eq '^cut_in=body checked=[0-9]+ total=148992 per=4656 bands=True inside=True first=True checked_first=[0-9]+$' <<<"$fc" \
  && ok "S25-DU-E4 with a fake clock the bucket loop stops inside a bucket at the limit ($fc)" || bad "S25-DU-E4 fake-clock bucket cut" "$fc"
# S25-DU-E3: the limit is checked inside one LSH bucket: 1,200 notes with one shared body stop near the limit, not after
# the whole bucket (0.9.10: 1,500 notes, limit 3 s, 5.1 s wall).
B="$TMP/bucket"; mkdir -p "$B"; cp "$HERE/../config/okf-base.yaml.template" "$B/okf-base.yaml"
"$REALPY" - "$B" <<'PY'
import sys
for i in range(1200):
    open("%s/n%04d.md" % (sys.argv[1], i), "w").write('---\ntype: Lesson\ntitle: Note %d\ndescription: Item %d\nstatus: stable\nstale_after: "2099-01-01"\n---\nthe same six words in every note\n' % (i, i))
PY
# The limit is set from this machine's own speed, not a fixed number: reading 1,200 notes took 2.8 s on a Mac with a
# virus scanner, so a fixed 2 s limit cut the run while it was still reading and the bucket was never reached. First the
# time to the start of the body pass (OKF_DUP_CUT_AT=body stops there), then a run whose limit is 1.5 times that: it must
# stop inside the body pass, within 6 s plus the time to the body pass of the limit (the 6 s this case always had for
# startup and the JSON report, plus that machine's own speed: on a shared 4-CPU runner and under CPU limits the run after
# the cut took 6.4 s on top of the limit with 3 to 4 s to the body pass, 0.4 s over a fixed 6 s; the whole bucket uncut
# took 7 times the time to the body pass (6.3 s against 0.9 s), so the bound tells a cut from none only where the body pass
# takes over 1.3 s; on a faster machine `cut_in` being "body" is what proves the cut, and S25-DU-E4 below proves it with a
# fake clock).
now() { "$REALPY" -c 'import time; print(time.time())'; }
t0=$(now); rc=$(OKF_DUP_CUT_AT=body runjson "$B" --duplicates-body)
pre=$("$REALPY" -c "import time; print('%.2f' % (time.time() - $t0))")
lim=$("$REALPY" -c "print('%.2f' % ($pre * 1.5))")
t0=$(now); rc=$(OKF_DUP_TIME_LIMIT=$lim runjson "$B" --duplicates-body)
el=$("$REALPY" -c "import time; print('%.1f' % (time.time() - $t0))")
cut=$(jget 'd.get("cut_in")' 2>/dev/null)
if [ "$rc" = 0 ] && [ "$cut" != '"body"' ] && [ "$cut" != '"read"' ] && [ "$cut" != '"pairs"' ]; then
  skip "S25-DU-E3 bucket cut: the whole body pass finished within ${lim} s (1.5 x the ${pre} s before it), so this machine cannot show a cut inside the bucket (cut_in=$cut)"
elif [ "$rc" = 0 ] && [ "$cut" != '"body"' ]; then
  skip "S25-DU-E3 bucket cut: this run reached its ${lim} s limit before the body pass (cut_in=$cut, ${el} s): reading was 1.5 times slower than ${pre} s a moment ago"
else
  { [ "$rc" = 0 ] && [ "$cut" = '"body"' ] && "$REALPY" -c "import sys; sys.exit(0 if $el < $lim + 6 + $pre else 1)"; } \
    && ok "S25-DU-E3 a single crowded bucket stops at the limit (limit ${lim} s = 1.5 x ${pre} s to the body pass; cut_in body, ${el} s)" \
    || bad "S25-DU-E3 bucket cut" "rc=$rc el=${el}s limit=${lim}s cut_in=$cut"
fi

# S36-ON-DU: three notes with one title, named with a space, an ESC byte and a byte that is not UTF-8, are three pairs, with
# and without a .okfignore (the keep list was decoded with errors="replace", so with an .okfignore the odd-named note was
# dropped from every pair: 0.9.40), and the folder-default owner reaches each of them. --json shows the byte as \xff.
# A disk that refuses the name (APFS) skips the case.
U8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
B="$TMP/on-du"; mkbundle "$B"; rm "$B/c.md"
sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$B/okf-base.yaml"
printf 'okf_check:\n  require_owner: true\n  owners:\n    "*.md": team:docs\n' >> "$B/okf-base.yaml"
for n in 'a b' "e$(printf '\033')x" "n$(printf '\377')u"; do
  printf -- '---\ntype: Lesson\ntitle: Same\ndescription: Item %s\nstatus: stable\nstale_after: "2099-01-01"\n---\nbody\n' "$(printf '%s' "$n" | LC_ALL=C tr -c 'a-z' x)" 2>/dev/null > "$B/$n.md"
done
if [ "$(find "$B" -name '*.md' | wc -l | tr -d ' ')" -ne 5 ]; then
  skip "S36-ON-DU this disk refuses a note name that is not UTF-8 (run on Linux)"
elif [ -z "$U8" ]; then
  skip "S36-ON-DU no UTF-8 locale here (locale -a lists neither C.UTF-8 nor en_US.UTF-8)"
else
  for LOC in C "$U8"; do
    for IGN in none okfignore; do
      [ "$IGN" = okfignore ] && printf 'zzz.md\n' > "$B/.okfignore"
      export LC_ALL="$LOC"
      rc=$(run "$B" --duplicates); nt=$(LC_ALL=C grep -a -c 'title 1.00' "$TMP/out.txt"); hd=$(LC_ALL=C grep -a -c '3 candidate pair(s)' "$TMP/out.txt")
      rcj=$(runjson "$B" --duplicates); got=$(jget 'sorted({s["rel"] for x in d["duplicates"] for s in (x["a"], x["b"])})'); ow=$(jget 'sorted({s["owner"] for x in d["duplicates"] for s in (x["a"], x["b"])})')
      np=$(jget 'len(d["duplicates"])')
      unset LC_ALL
      { [ "$rc" = 0 ] && [ "$rcj" = 0 ] && [ "$nt" = 3 ] && [ "$hd" = 1 ] && [ "$np" = 3 ] && [ "$ow" = '["team:docs"]' ] \
        && [ "$got" = '["a b.md", "e\\x1bx.md", "n\\xffu.md"]' ]; } \
        && ok "S36-ON-DU under LC_ALL=$LOC ($IGN) --duplicates pairs all three odd-named notes: 3 pairs in the text and --json, owner team:docs on each" \
        || bad "S36-ON-DU odd names under $LOC ($IGN)" "rc=$rc/$rcj text=$nt/$hd pairs=$np owners=$ow notes=$got"
    done
    rm -f "$B/.okfignore"
  done
fi

section "recall at a low body_threshold"
# SC-dup147 (spec row DU-2): the banding misses some pairs near a low body_threshold, with no sign in the report. The report now says how often it
# found pairs AT the active threshold, from a measured table kept as data (config/duplicates-body-recall.json), only when the
# threshold is below the table's own "show_below". The cases use a copy of the plugin with a hand-made table, so the expected
# numbers are literals here and not read from the shipped file.
CPR="$TMP/plugin-recall"; cp -R "$HERE/.." "$CPR"
cat > "$CPR/config/duplicates-body-recall.json" <<'JSON'
{"show_below": 0.5, "measured": {"date": "2026-01-01", "generator": "test table"}, "points": [
  {"threshold": 0.2, "jaccard": 0.2, "recall": 0.4}, {"threshold": 0.3, "jaccard": 0.3, "recall": 0.9}]}
JSON
rbundle() { # <dir> <body_threshold> — two notes with one body, and that body_threshold
  mkdir -p "$1"; note "$1/a.md" "Alpha one" "$P"; note "$1/b.md" "Beta two" "$P"
  printf 'okf_check:\n  duplicates:\n    body_threshold: %s\n' "$2" > "$1/okf-base.yaml"
}
rrun() { local plug="$1" b="$2"; shift 2; "$plug/scripts/okf-check" "$b" --duplicates-body "$@" >"$TMP/out.txt" 2>&1; "$plug/scripts/okf-check" --json "$b" --duplicates-body "$@" >"$TMP/out.json" 2>/dev/null; }
R1="$TMP/r1"; rbundle "$R1" 0.25; rrun "$CPR" "$R1"
{ grep -Eq 'Duplicates +body_threshold 0\.25: pairs whose bodies overlap by about the threshold were found 40% of the time \(nearest lower measured point 0\.2' "$TMP/out.txt" \
  && [ "$(jget 'd["body_recall"]')" = '{"basis": "nearest lower measured point", "measured_at": 0.2, "recall": 0.4, "threshold": 0.25}' ]; } \
  && ok "SC-dup147 a threshold between two measured points prints the nearest lower point's recall (40% at 0.2), in the text and in --json" \
  || bad "SC-dup147 recall between points" "$(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|') json=$(jget 'd.get("body_recall")')"
R2="$TMP/r2"; rbundle "$R2" 0.3; rrun "$CPR" "$R2"
{ grep -Eq 'body_threshold 0\.3: .* 90% .*\(measured point 0\.3' "$TMP/out.txt" \
  && [ "$(jget '[d["body_recall"]["measured_at"], d["body_recall"]["recall"], d["body_recall"]["basis"]]')" = '[0.3, 0.9, "measured point"]' ]; } \
  && ok "SC-dup147 a threshold on a measured point prints that point's recall (90% at 0.3)" \
  || bad "SC-dup147 recall on a point" "$(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|') json=$(jget 'd.get("body_recall")')"
R3="$TMP/r3"; rbundle "$R3" 0.15; rrun "$CPR" "$R3"
{ grep -Eq 'body_threshold 0\.15: below the measured range \(lowest measured point 0\.2\)' "$TMP/out.txt" \
  && [ "$(jget '[d["body_recall"]["measured_at"], d["body_recall"]["recall"]]')" = '[null, null]' ]; } \
  && ok "SC-dup147 a threshold under the lowest measured point says 'below the measured range', no number" \
  || bad "SC-dup147 below the range" "$(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|') json=$(jget 'd.get("body_recall")')"
for T in 0.5 0.6; do
  RD="$TMP/rd$T"; rbundle "$RD" "$T"; rrun "$CPR" "$RD"
  { ! grep -q 'body_threshold' "$TMP/out.txt" && ! grep -q 'measured' "$TMP/out.txt" && [ "$(jget '"body_recall" in d')" = false ]; } \
    && ok "SC-dup147 body_threshold $T (not below show_below 0.5) prints no recall line and no body_recall key" \
    || bad "SC-dup147 no line at $T" "$(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|')"
done
RN="$TMP/rn"; mkdir -p "$RN"; note "$RN/a.md" "Alpha one" "$P"; note "$RN/b.md" "Beta two" "$P"; printf 'okf_check:\n  duplicates:\n    body_threshold: 0.25\n' > "$RN/okf-base.yaml"
"$CPR/scripts/okf-check" "$RN" --duplicates > "$TMP/out.txt" 2>&1; "$CPR/scripts/okf-check" --json "$RN" --duplicates > "$TMP/out.json" 2>/dev/null
{ ! grep -q 'body_threshold' "$TMP/out.txt" && [ "$(jget '"body_recall" in d')" = false ]; } \
  && ok "SC-dup147 --duplicates without the body pass prints no recall line: the threshold is not used" \
  || bad "SC-dup147 no body pass" "$(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|')"
CPM="$TMP/plugin-norecall"; cp -R "$HERE/.." "$CPM"; rm -f "$CPM/config/duplicates-body-recall.json"
rrun "$CPM" "$R1"
{ grep -Eq 'body_threshold 0\.25: .*recall table .*could not be read' "$TMP/out.txt" && [ "$(jget 'sorted(d["body_recall"])')" = '["error", "threshold"]' ]; } \
  && ok "SC-dup147 a missing table is said, not silent: the recall is not known" \
  || bad "SC-dup147 missing table" "$(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|') json=$(jget 'd.get("body_recall")')"

# A table that is valid JSON but the wrong shape is reported like a missing one, never a crash (no traceback, same exit).
for shape in 'empty points|{"show_below": 0.4, "points": []}' 'a point without recall|{"show_below": 0.4, "points": [{"threshold": 0.2}]}' \
             'show_below as text|{"show_below": "0.4", "points": [{"threshold": 0.2, "recall": 0.4}]}' \
             'points as an object|{"show_below": 0.4, "points": {"0.2": 0.4}}' 'a list at the top|[1, 2]'; do
  printf '%s\n' "${shape#*|}" > "$CPR/config/duplicates-body-recall.json"
  rrun "$CPR" "$R1"; "$CPR/scripts/okf-check" "$R1" --duplicates-body >/dev/null 2>&1; rcs=$?
  { [ "$rcs" = 0 ] && ! grep -q 'Traceback' "$TMP/out.txt" && grep -Eq 'body_threshold 0\.25: the recall table .*could not be read' "$TMP/out.txt" \
    && [ "$(jget '"error" in d["body_recall"]')" = true ]; } \
    && ok "SC-dup147 a recall table with ${shape%%|*} is reported as unreadable, exit 0, no traceback" \
    || bad "SC-dup147 table shape: ${shape%%|*}" "rc=$rcs $(grep -n 'Traceback\|Duplicates\|Error' "$TMP/out.txt" | head -3 | tr '\n' '|') json=$(jget 'd.get("body_recall")')"
done

# The shipped table: a low threshold prints the number the file holds for that point; the default prints nothing.
SHIP="$HERE/../config/duplicates-body-recall.json"
want=$("$REALPY" -c 'import json,sys; t=json.load(open(sys.argv[1])); print("%d%%" % round(100 * [p for p in t["points"] if p["threshold"] == 0.2][0]["recall"]), t["show_below"] > 0.2 and t["show_below"] <= 0.6)' "$SHIP" 2>&1)
RS="$TMP/rs"; rbundle "$RS" 0.2; rrun "$CPR" "$RS"; cp "$SHIP" "$CPR/config/duplicates-body-recall.json"; rrun "$CPR" "$RS"
pct=${want%% *}
{ grep -Eq "body_threshold 0\\.2: .* found ${pct} of the time" "$TMP/out.txt" && [ "${want#* }" = True ]; } \
  && ok "SC-dup147 the shipped table prints its own number for 0.2 ($pct) and its show_below is within (0.2, 0.6]" \
  || bad "SC-dup147 shipped table" "want=$want $(grep -n 'Duplicates' "$TMP/out.txt" | head -3 | tr '\n' '|')"
RS6="$TMP/rs6"; rbundle "$RS6" 0.6; rrun "$CPR" "$RS6"; "$CHECK" "$RS6" --duplicates-body > "$TMP/out2.txt" 2>&1
{ ! grep -q 'body_threshold' "$TMP/out.txt" && ! grep -q 'body_threshold' "$TMP/out2.txt"; } \
  && ok "SC-dup147 the default body_threshold 0.6 prints no recall line with the shipped table (behaviour unchanged)" \
  || bad "SC-dup147 default unchanged" "$(grep -n 'body_threshold' "$TMP/out.txt" "$TMP/out2.txt" | head -2 | tr '\n' '|')"

# The shipped table says where and how precisely it was measured (data, so a reader of the file knows its limits).
meta=$("$REALPY" -c 'import json,sys; m=json.load(open(sys.argv[1]))["measured"]; print(m.get("platform"), m.get("precision"))' "$SHIP" 2>&1)
[ "$meta" = "macOS steps of 0.01 (100 pairs per point)" ] \
  && ok "SC-dup147 the shipped table records the platform (macOS) and the precision (100 pairs per point, steps of 0.01)" \
  || bad "SC-dup147 table platform and precision" "$meta"

# The table is reproducible: the generator (tools/ of the private repository), run with the table's own parameters for one point, gives that point's recall again.
GEN="$HERE/../../tools/duplicates-body-recall.py"
if [ -f "$GEN" ]; then
  par=$("$REALPY" -c 'import json,sys; t=json.load(open(sys.argv[1])); m=t["measured"]["parameters"]; print(m["pairs_per_point"], m["seed"], [p["recall"] for p in t["points"] if p["threshold"] == 0.3][0])' "$SHIP")
  set -- $par
  again=$("$REALPY" "$GEN" --pairs "$1" --seed "$2" --points 0.3 2>/dev/null | "$REALPY" -c 'import json,sys; print(json.load(sys.stdin)["points"][0]["recall"])')
  [ "$again" = "$3" ] && ok "SC-dup147 the generator reproduces the shipped table's recall at 0.3 ($3) from the table's own parameters" \
    || bad "SC-dup147 table reproducible" "table $3, generator $again"
else
  skip "SC-dup147 table reproducibility - the table's generator is kept in the private repository and is not in this tree" "run from the private repository"
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
