#!/usr/bin/env bash
# Tests for review findings parked in the backlog registers and fixed in 0.9.35 (cases S26-RF-* in docs/0.9.x-cases.md):
#   - B-4 (narrow): a `verified.by` that only LOOKS like `human:` (Cyrillic and Greek lookalikes) is named as such;
#   - the Config line names the real fault when okf-verify is missing or its check fails without a message (0.9.4);
#   - --selftest probes the Config check and the lookalike rule.
#
# Spec row RF-1. bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"

mkb() { mkbundle "$1"; sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"; }
# vnote <file> <verified.by as a YAML double-quoted string body>
vnote() { printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: "%s"\n    at: "2026-02-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' "$2" > "$1"; }
run() { local b="$1"; shift; "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }

section "lookalike human:"
# S26-RF-H1: `һυмап:dana` (Cyrillic h, Greek upsilon, Cyrillic em, a and pe) is a Trust warning that names it.
B="$TMP/look"; mkb "$B"; vnote "$B/v.md" 'һυмап:dana'
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -Eq 'Trust \(C4\) +WARN +1 warning' "$TMP/out.txt" \
  && grep -q 'v.md: verified\[0\].by `.*:dana` only looks like `human:`: it spells it with lookalike characters' "$TMP/out.txt"; } \
  && ok "S26-RF-H1 a lookalike human: is a Trust warning that says it only looks like human: (exit 0 by default)" \
  || bad "S26-RF-H1 lookalike" "rc=$rc $(grep -n -A2 'Trust' "$TMP/out.txt" | head -4 | tr '\n' '|')"
rc=$(run "$B" --strict-trust)
[ "$rc" = 1 ] && ok "S26-RF-H1b under --strict-trust the lookalike fails the run (exit 1)" || bad "S26-RF-H1b strict" "rc=$rc"
# S26-RF-H2: the same for process:, with a lookalike colon (U+2236).
vnote "$B/v.md" 'prоcess∶ci'
rc=$(run "$B")
grep -q 'only looks like `process:`' "$TMP/out.txt" && ok "S26-RF-H2 a lookalike process: (Cyrillic o, ratio colon) is named too" \
  || bad "S26-RF-H2 process lookalike" "rc=$rc $(grep -n -A2 'Trust' "$TMP/out.txt" | head -3 | tr '\n' '|')"
# S26-RF-N1: plain human: and a non-Latin name that is not a lookalike are not named; an ASCII near-miss (Human:) stays
# the validator's L1 warning and is not reported twice.
vnote "$B/v.md" 'human:дана'
r1=$(run "$B"); c1=$(grep -c 'only looks like' "$TMP/out.txt")
vnote "$B/v.md" 'дана'
r2=$(run "$B"); c2=$(grep -c 'only looks like' "$TMP/out.txt")
vnote "$B/v.md" 'Human:dana'
r3=$(run "$B"); c3=$(grep -c 'only looks like' "$TMP/out.txt"); nm=$(grep -c 'near-miss of' "$TMP/out.txt")
{ [ "$c1" = 0 ] && [ "$c2" = 0 ] && [ "$c3" = 0 ] && [ "$nm" -ge 1 ]; } \
  && ok "S26-RF-N1 human:<Cyrillic id>, a Cyrillic name and the ASCII Human: are not called lookalikes (Human: stays an L1 near-miss)" \
  || bad "S26-RF-N1 no false lookalike" "counts=$c1,$c2,$c3 near-miss=$nm rc=$r1,$r2,$r3"

# S26-RF-H3 (review 0.9.35): capital lookalikes are named too: Cyrillic En (U+041D) and Greek Eta (U+0397) for H.
vnote "$B/v.md" '\u041dUMAN:dana'
rc=$(run "$B"); c1=$(grep -c 'only looks like `human:`' "$TMP/out.txt")
vnote "$B/v.md" '\u0397uman:dana'
rc=$(run "$B"); c2=$(grep -c 'only looks like `human:`' "$TMP/out.txt")
{ [ "$c1" = 1 ] && [ "$c2" = 1 ]; } && ok "S26-RF-H3 НUMAN: and Ηuman: (capital lookalikes) are named" || bad "S26-RF-H3 capitals" "counts=$c1,$c2"

section "config line"
# S26-RF-E1: okf-verify missing from the plugin: the Config line names it, not okf-base.yaml.
CP="$TMP/plugin"; cp -R "$HERE/.." "$CP"; rm "$CP/scripts/okf-verify"
B="$TMP/cfg"; mkb "$B"
"$CP/scripts/okf-check" "$B" >"$TMP/out.txt" 2>&1; rc=$?
{ [ "$rc" = 2 ] && grep -Eq 'Config +COULD NOT RUN — the config check cannot run: .*scripts/okf-verify is missing \(reinstall the plugin\)' "$TMP/out.txt" \
  && ! grep -q "Config .*okf-base.yaml: .*can't open" "$TMP/out.txt"; } \
  && ok "S26-RF-E1 okf-verify missing: the Config line says so (exit 2) and does not blame okf-base.yaml" \
  || bad "S26-RF-E1 missing okf-verify" "rc=$rc $(grep -n 'Config' "$TMP/out.txt" | head -2 | tr '\n' '|')"
# S26-RF-E2: a config check that fails without a message names its exit code instead of printing an empty reason.
printf 'import sys\nsys.exit(1)\n' > "$CP/scripts/okf-verify"
"$CP/scripts/okf-check" "$B" >"$TMP/out.txt" 2>&1; rc=$?
{ [ "$rc" = 2 ] && grep -Eq 'Config +COULD NOT RUN — the config check failed \(okf-verify --check-config exit 1\)$' "$TMP/out.txt"; } \
  && ok "S26-RF-E2 a silent config check failure says 'the config check failed (okf-verify --check-config exit 1)'" \
  || bad "S26-RF-E2 silent failure" "rc=$rc $(grep -n 'Config' "$TMP/out.txt" | head -2 | tr '\n' '|')"

section "selftest"
# S26-RF-E3: --selftest probes the Config check and the lookalike rule; a copy with the lookalike rule disabled fails it.
"$CHECK" --selftest >"$TMP/st.txt" 2>&1; rc=$?
CP2="$TMP/plugin2"; cp -R "$HERE/.." "$CP2"
sed -i.bak 's/^        if look:$/        if False:/' "$CP2/scripts/okf-trust.py"
"$CP2/scripts/okf-check" --selftest >"$TMP/st2.txt" 2>&1; rc2=$?
{ [ "$rc" = 0 ] && grep -q 'FIRED      unknown okf_check option' "$TMP/st.txt" && grep -q 'FIRED      lookalike human: -> named' "$TMP/st.txt" \
  && [ "$rc2" = 5 ] && grep -q 'NOT FIRED  lookalike human: -> named' "$TMP/st2.txt"; } \
  && ok "S26-RF-E3 --selftest fires the Config and lookalike probes; with the rule disabled it reports NOT FIRED and exits 5" \
  || bad "S26-RF-E3 selftest probes" "rc=$rc rc2=$rc2 $(grep -n 'Config\|lookalike\|SELFTEST' "$TMP/st.txt" "$TMP/st2.txt" | tr '\n' '|')"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
