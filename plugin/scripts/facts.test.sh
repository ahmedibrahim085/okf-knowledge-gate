#!/usr/bin/env bash
# Tests for declared facts, okf_check.facts (public okf-knowledge-gate #15; cases S22-DF-* in docs/0.9.x-cases.md).
#
# A fact (a count, a version, a list of countries) is stated in many notes. The bundle declares its value once, with the
# patterns that find where it is stated; a note that states another value is a FACT-CONFLICT, a house-rule error (exit 1,
# like require_owner and size). `okf-check <bundle> --facts [NAME]` lists every occurrence before the owner changes a value.
#
# Spec row DF-1. bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"

# mkb <dir> <okf_check facts lines>: a clean bundle with the house manifest and the given facts block.
mkb() {
  mkbundle "$1"
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"
  printf 'okf_check:\n  facts:\n%s\n' "$2" >> "$1/okf-base.yaml"
}
note() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: Lesson\ntitle: T %s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n%s\n' "$1" "$2" > "$1"
}
COUNTRIES=$'    launch.countries:\n      value: "A and B"\n      patterns: ["launch countries?:? *(.+)"]\n      source: decisions/0007.md'
run() { local b="$1"; shift; "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
runjson() { local b="$1"; shift; "$CHECK" --json "$b" "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }

section "happy"
# S22-DF-H1: every statement agrees with the declared value (case, whitespace and a trailing full stop ignored): Facts PASS.
B="$TMP/h1"; mkb "$B" "$COUNTRIES"; note "$B/decisions/0007.md" "Launch countries: A and B"; note "$B/x.md" "The launch countries: a  and b."
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -Eq 'Facts +PASS +1 fact\(s\), 2 statement\(s\) agree' "$TMP/out.txt"; } \
  && ok "S22-DF-H1 statements that agree with the declared value pass (case, spacing, final full stop ignored)" || bad "S22-DF-H1 agree" "rc=$rc $(grep -n 'Facts' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S22-DF-H2: the reporter's case. One note keeps the old value: FACT-CONFLICT naming the note, the line, the fact and both
# values, and the source; exit 1.
B="$TMP/h2"; mkb "$B" "$COUNTRIES"; note "$B/decisions/0007.md" "Launch countries: A and B"; note "$B/old.md" $'intro\n\nLaunch countries: A, B and C'
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Eq 'Facts +FAIL +1 conflict' "$TMP/out.txt" \
  && grep -Fq 'old.md:15: FACT-CONFLICT launch.countries states "A, B and C", declared "A and B" (source decisions/0007.md)' "$TMP/out.txt"; } \
  && ok "S22-DF-H2 a note stating another value is a FACT-CONFLICT with note, line, both values and the source (exit 1)" || bad "S22-DF-H2 conflict" "rc=$rc $(grep -n 'Facts\|FACT' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S22-DF-H3: --json lists the conflict in errors[] and every statement in facts[] with its verdict.
rc=$(runjson "$B"); got=$(jget '[[f["note"], f["line"], f["stated"], f["agrees"]] for f in d["facts"]]'); errs=$(jget '[e for e in d["errors"] if "FACT-CONFLICT" in e]')
{ [ "$rc" = 1 ] && [ "$got" = '[["decisions/0007.md", 13, "A and B", true], ["old.md", 15, "A, B and C", false]]' ] && [ "$errs" != '[]' ]; } \
  && ok "S22-DF-H3 --json: facts[] gives every statement and whether it agrees; the conflict is in errors[]" || bad "S22-DF-H3 json" "rc=$rc facts=$got errors=$errs"

# S22-DF-H4: --facts lists every occurrence of every fact (or of one, by name), with no verdict and exit 0: the dry run an
# owner reads before changing a value.
rc=$(run "$B" --facts launch.countries)
{ [ "$rc" = 0 ] && grep -Fq 'decisions/0007.md:13  A and B' "$TMP/out.txt" && grep -Fq 'old.md:15  A, B and C  (differs)' "$TMP/out.txt" \
  && grep -Fq 'launch.countries: declared "A and B" (source decisions/0007.md), 2 occurrence(s), 1 differ(s)' "$TMP/out.txt"; } \
  && ok "S22-DF-H4 --facts NAME lists every occurrence with its line and value, marks the ones that differ, exit 0" || bad "S22-DF-H4 dry run" "rc=$rc $(head -6 "$TMP/out.txt" | tr '\n' '|')"

section "negative"
# S22-DF-N1: without a facts block nothing is printed and the output is unchanged.
B="$TMP/n1"; mkbundle "$B"; sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$B/okf-base.yaml"; note "$B/x.md" "Launch countries: Z"
rc=$(run "$B"); rcj=$(runjson "$B"); has=$(jget '"facts" in d')
{ [ "$rc" = 0 ] && ! grep -q 'Facts' "$TMP/out.txt" && [ "$has" = false ]; } && ok "S22-DF-N1 no facts block: no Facts line, no facts key" || bad "S22-DF-N1 off" "rc=$rc has=$has"

# S22-DF-N2: a statement inside a code block is a literal, not a statement of the fact.
B="$TMP/n2"; mkb "$B" "$COUNTRIES"; note "$B/x.md" $'```\nLaunch countries: Z\n```\n\n    Launch countries: Y'
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -Eq 'Facts +PASS +1 fact\(s\), 0 statement\(s\) agree' "$TMP/out.txt"; } && ok "S22-DF-N2 statements inside code blocks are not checked" || bad "S22-DF-N2 code" "rc=$rc $(grep 'Facts\|FACT' "$TMP/out.txt" | head -2)"

# S22-DF-N3: a malformed block is the Config line's exit 2, in okf-check and okf-verify --check-config: a fact with no value,
# no patterns, a pattern that is not a regular expression, a pattern with no capture group, an unknown key.
for f in $'    f:\n      patterns: ["x: (.+)"]' $'    f:\n      value: "1"' $'    f:\n      value: "1"\n      patterns: ["x: (.+"]' \
         $'    f:\n      value: "1"\n      patterns: ["x: .+"]' $'    f:\n      value: "1"\n      patterns: ["x: (.+)"]\n      colour: red'; do
  B="$TMP/n3"; rm -rf "$B"; mkb "$B" "$f"
  rc=$(run "$B"); "$HERE/okf-verify" "$B" --check-config > "$TMP/n3v.txt" 2>&1; rcv=$?
  { [ "$rc" = 2 ] && [ "$rcv" = 2 ] && grep -q 'okf_check.facts.f' "$TMP/n3v.txt"; } \
    && ok "S22-DF-N3 refused by both tools (exit 2): $(head -1 "$TMP/n3v.txt" | sed 's/.*okf_check.facts.f/okf_check.facts.f/' | cut -c1-80)" \
    || bad "S22-DF-N3 malformed fact" "rc=$rc rcv=$rcv $(head -1 "$TMP/n3v.txt")"
done

section "edge"
# S22-DF-E1: several patterns, several facts; a line may state two facts; an .okfignore'd note is not checked.
B="$TMP/e1"; mkb "$B" "$COUNTRIES"$'\n    service.count:\n      value: "7 of 8"\n      patterns: ["services up: (\\\\d+ of \\\\d+)", "(\\\\d+ of \\\\d+) services"]'
note "$B/x.md" "Launch countries: A and B; services up: 5 of 7"; note "$B/y.md" "We run 7 of 8 services."; printf 'arch/\n' > "$B/.okfignore"; note "$B/arch/z.md" "Launch countries: Q"
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Eq 'Facts +FAIL +1 conflict' "$TMP/out.txt" && grep -Fq 'x.md:13: FACT-CONFLICT service.count states "5 of 7", declared "7 of 8"' "$TMP/out.txt" \
  && ! grep -q 'arch/z.md' "$TMP/out.txt"; } \
  && ok "S22-DF-E1 two facts, two patterns, one line stating two facts; an ignored note is skipped" || bad "S22-DF-E1 several" "rc=$rc $(grep 'Facts\|FACT' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S22-DF-E2: --facts with an unknown name is a usage error (exit 64) naming the declared facts; --facts without a facts block
# says there is none (exit 0).
B="$TMP/e2"; mkb "$B" "$COUNTRIES"; note "$B/x.md" "Launch countries: A and B"
rc=$(run "$B" --facts nope); rc2=0
{ [ "$rc" = 64 ] && grep -q 'launch.countries' "$TMP/out.txt"; } && ok "S22-DF-E2 --facts with an unknown name is exit 64 and lists the declared names" || bad "S22-DF-E2 unknown name" "rc=$rc $(head -2 "$TMP/out.txt")"

# S22-DF-E3: --selftest plants a conflicting value and requires the Facts gate to fire.
rc=$("$CHECK" --selftest >"$TMP/st.txt" 2>&1; echo $?)
{ [ "$rc" = 0 ] && grep -A1 'Facts (okf_check.facts)' "$TMP/st.txt" | grep -q 'FIRED'; } && ok "S22-DF-E3 --selftest has a Facts probe that fires" || bad "S22-DF-E3 selftest" "rc=$rc $(grep -A1 'Facts' "$TMP/st.txt" | head -2)"

# S22-DF-E4 (review S4): a pattern from okf-base.yaml with catastrophic backtracking cannot hang the run: the facts step runs
# under a time limit (OKF_FACTS_TIMEOUT, default 60 s) and reports COULD NOT RUN (exit 2) when it passes.
B="$TMP/e4"; mkb "$B" $'    f:\n      value: "1"\n      patterns: ["(a+)+$"]'; note "$B/x.md" "$(printf 'a%.0s' $(seq 40))!"   # made at run time: a 40-letter hex run reads as a commit id to the export scan
t0=$(date +%s); rc=$(OKF_FACTS_TIMEOUT=3 run "$B"); dt=$(( $(date +%s) - t0 ))
{ [ "$rc" = 2 ] && [ "$dt" -lt 30 ] && grep -Eq 'Facts +COULD NOT RUN .*timed out after 3 s' "$TMP/out.txt"; } \
  && ok "S22-DF-E4 a runaway pattern is stopped by the time limit: COULD NOT RUN, exit 2 (${dt} s)" || bad "S22-DF-E4 redos" "rc=$rc dt=$dt $(grep 'Facts' "$TMP/out.txt")"

# S22-DF-E5 (review S5, nits): a value inside brackets is not read with the bracket; two patterns matching the same text give
# one statement; a CRLF note is read like an LF one.
B="$TMP/e5"; mkb "$B" "$COUNTRIES"$'\n    launch.dup:\n      value: "A and B"\n      patterns: ["launch countries: (.+)", "launch countries?:? *(.+)"]'
note "$B/x.md" "(Launch countries: A and B)"; printf -- '---\r\ntype: Lesson\r\ntitle: C\r\ndescription: D\r\nstatus: stable\r\ntags: [t]\r\ngenerated:\r\n  by: human:t\r\n  at: "2026-01-01"\r\nstale_after: "2099-01-01"\r\n---\r\n\r\nLaunch countries: A and B\r\n' > "$B/crlf.md"
rc=$(runjson "$B"); got=$(jget '[[f["fact"], f["note"], f["stated"], f["agrees"]] for f in d["facts"]]')
{ [ "$rc" = 0 ] && [ "$got" = '[["launch.countries", "crlf.md", "A and B", true], ["launch.dup", "crlf.md", "A and B", true], ["launch.countries", "x.md", "A and B", true], ["launch.dup", "x.md", "A and B", true]]' ]; } \
  && ok "S22-DF-E5 brackets are not part of a value, one statement per fact and line, CRLF notes read as LF" || bad "S22-DF-E5 values" "rc=$rc got=$got"

D="$TMP/dead-facts"; mkdir -p "$D"; cp -R "$HERE/.." "$D/plugin" 2>/dev/null
sed -i.orig 's|^run_facts() {|run_facts() { return 0;|' "$D/plugin/scripts/okf-check"
if cmp -s "$D/plugin/scripts/okf-check" "$D/plugin/scripts/okf-check.orig"; then
  bad "S22-DF-E3b crippled copy" "the cripple changed nothing"
else
  "$D/plugin/scripts/okf-check" --selftest >"$TMP/st-dead.txt" 2>&1; rc=$?
  { [ "$rc" = 5 ] && grep -Eq 'NOT FIRED  +a note states another value' "$TMP/st-dead.txt"; } \
    && ok "S22-DF-E3b with the facts rule crippled the probe reports NOT FIRED and --selftest exits 5" \
    || bad "S22-DF-E3b dead facts rule" "rc=$rc $(grep -n 'Facts\|another value\|SELFTEST' "$TMP/st-dead.txt" | head -3 | tr '\n' '|')"
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
