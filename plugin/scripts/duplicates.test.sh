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
# S25-DU-E3: the limit is checked inside one LSH bucket: 1,200 notes with one shared body stop near the limit, not after
# the whole bucket (0.9.10: 1,500 notes, limit 3 s, 5.1 s wall).
B="$TMP/bucket"; mkdir -p "$B"; cp "$HERE/../config/okf-base.yaml.template" "$B/okf-base.yaml"
"$REALPY" - "$B" <<'PY'
import sys
for i in range(1200):
    open("%s/n%04d.md" % (sys.argv[1], i), "w").write('---\ntype: Lesson\ntitle: Note %d\ndescription: Item %d\nstatus: stable\nstale_after: "2099-01-01"\n---\nthe same six words in every note\n' % (i, i))
PY
t0=$("$REALPY" -c 'import time; print(time.time())')
rc=$(OKF_DUP_TIME_LIMIT=2 runjson "$B" --duplicates-body)
el=$("$REALPY" -c "import time; print('%.1f' % (time.time() - $t0))")
{ [ "$rc" = 0 ] && [ "$(jget 'd["cut_in"]')" = '"body"' ] && "$REALPY" -c "import sys; sys.exit(0 if $el < 2 + 6 else 1)"; } \
  && ok "S25-DU-E3 a single crowded bucket stops at the limit (cut_in body, ${el} s for the whole okf-check run)" \
  || bad "S25-DU-E3 bucket cut" "rc=$rc el=${el}s cut_in=$(jget 'd.get("cut_in")' 2>/dev/null)"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
