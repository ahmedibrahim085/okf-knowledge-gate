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

# Spec row IV-1 (cases S32-IV-*).
# S32-IV-H1: an invisible character INSIDE the prefix is a lookalike too. Format characters (Cf: zero-width space,
# joiner and non-joiner, soft hyphen, word joiner, BOM) and combining marks (Mn) render as nothing or sit on the letter, so the
# claim reads as `human:` while no tool does. Each one is a Trust warning, and a failure under --strict-trust.
for cp in 200b 200c 200d 00ad 2060 feff 0307 0301; do
  vnote "$B/v.md" "hu\\u${cp}man:dana"
  rc=$(run "$B" --strict-trust)
  { [ "$rc" = 1 ] && grep -q 'only looks like `human:`' "$TMP/out.txt"; } \
    && ok "S32-IV-H1 U+${cp} inside human: is named as a lookalike and fails --strict-trust (exit 1)" \
    || bad "S32-IV-H1 U+${cp} inside human:" "rc=$rc $(grep -n -A2 'Trust' "$TMP/out.txt" | head -3 | tr '\n' '|')"
done
# S32-IV-H2: the same in front of the prefix and inside process:.
vnote "$B/v.md" '\u200bhuman:dana'; rc=$(run "$B" --strict-trust)
{ [ "$rc" = 1 ] && grep -q 'only looks like `human:`' "$TMP/out.txt"; } && ok "S32-IV-H2 a zero-width space before human: is named" \
  || bad "S32-IV-H2 leading U+200B" "rc=$rc"
vnote "$B/v.md" 'pro\u00adcess:dana'; rc=$(run "$B" --strict-trust)
{ [ "$rc" = 1 ] && grep -q 'only looks like `process:`' "$TMP/out.txt"; } && ok "S32-IV-H2b a soft hyphen inside process: is named" \
  || bad "S32-IV-H2b U+00AD in process:" "rc=$rc"
# S32-IV-H3: a precomposed letter with a mark on it (h with a dot below, U+1E25) is the same spelling, decomposed first.
vnote "$B/v.md" '\u1e25uman:dana'; rc=$(run "$B" --strict-trust)
{ [ "$rc" = 1 ] && grep -q 'only looks like `human:`' "$TMP/out.txt"; } && ok "S32-IV-H3 a precomposed h with a dot below spells human: and is named" \
  || bad "S32-IV-H3 precomposed h" "rc=$rc"
# S32-IV-H4: the warning names the invisible code point(s), because the actor is printed with them in it and reads as `human:`.
vnote "$B/v.md" 'hu\u200b\u00adman:dana'; rc=$(run "$B")
{ grep -q 'only looks like `human:`.*U+00AD, U+200B' "$TMP/out.txt"; } && ok "S32-IV-H4 the warning names the hidden code points (U+00AD, U+200B)" \
  || bad "S32-IV-H4 code points named" "$(grep -n 'only looks like' "$TMP/out.txt" | head -2 | cut -c1-200 | tr '\n' '|')"
# S32-IV-H4b: the code points are listed in numeric order, not as text (U+1D17A sorts before U+200B as text, after it as a number).
vnote "$B/v.md" 'hu\u200b\U0001d17aman:dana'; rc=$(run "$B")
{ grep -q 'only looks like `human:`.*U+200B, U+1D17A' "$TMP/out.txt"; } && ok "S32-IV-H4b the hidden code points are listed in numeric order (U+200B, U+1D17A)" \
  || bad "S32-IV-H4b numeric order" "$(grep -n 'only looks like' "$TMP/out.txt" | head -2 | cut -c1-200 | tr '\n' '|')"
# S32-IV-H5: blanks and fillers are the same spelling: a no-break or ideographic space, a braille blank, the hangul fillers
# render as a gap or as nothing, an enclosing mark sits on the letter, and the line, paragraph and next-line separators
# (U+2028, U+2029, U+0085) break the line inside the prefix. Each one is named, with its code point.
for cp in 00a0 3000 2800 3164 ffa0 115f 20dd 2028 2029 0085; do
  vnote "$B/v.md" "hu\\u${cp}man:dana"
  rc=$(run "$B" --strict-trust)
  { [ "$rc" = 1 ] && grep -qi "only looks like \`human:\`.*U+${cp}" "$TMP/out.txt"; } \
    && ok "S32-IV-H5 U+${cp} inside human: is named with its code point and fails --strict-trust (exit 1)" \
    || bad "S32-IV-H5 U+${cp} inside human:" "rc=$rc $(grep -n 'Trust' "$TMP/out.txt" | head -2 | cut -c1-160 | tr '\n' '|')"
done
# S32-IV-N2: names with ordinary spaces and the real prefix are not lookalikes (the blanks only matter inside the spelling).
for who in 'human:Dana Lee' 'human:José Pérez' 'Дана Ли' 'process:build bot'; do
  vnote "$B/v.md" "$who"; run "$B" >/dev/null; c=$(grep -c 'only looks like' "$TMP/out.txt")
  [ "$c" = 0 ] && ok "S32-IV-N2 '$who' is not called a lookalike" || bad "S32-IV-N2 '$who'" "lookalike-lines=$c"
done
# S32-IV-N1: the real prefix, and an invisible character AFTER it (in the id), are not lookalikes.
# (An agent-generated note keeps the plain human: advisory, so --strict-trust exits 1 for the plain id as well.)
vnote "$B/v.md" 'human:dana'; plain=$(run "$B" --strict-trust)
vnote "$B/v.md" 'human:da\u200bna'; rc=$(run "$B" --strict-trust); c=$(grep -c 'only looks like' "$TMP/out.txt")
{ [ "$c" = 0 ] && [ "$rc" = "$plain" ]; } && ok "S32-IV-N1 an invisible character in the id after human: is not a lookalike (same verdict as the plain id)" \
  || bad "S32-IV-N1 id after the prefix" "rc=$rc plain=$plain lookalike-lines=$c"

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

# S32-IV-E1: --selftest also probes an invisible character inside human:. With the hidden-character categories emptied
# in the copy, that probe reports NOT FIRED and exits 5 while the Cyrillic lookalike probe still fires.
CP3="$TMP/plugin3"; cp -R "$HERE/.." "$CP3"
sed -i.bak 's/^HIDDEN_CATEGORIES = .*/HIDDEN_CATEGORIES = ()/' "$CP3/scripts/okf-trust.py"
"$CP3/scripts/okf-check" --selftest >"$TMP/st3.txt" 2>&1; rc3=$?
{ grep -q 'FIRED      invisible character in human: -> named' "$TMP/st.txt" \
  && [ "$rc3" = 5 ] && grep -q 'NOT FIRED  invisible character in human: -> named' "$TMP/st3.txt" \
  && grep -q 'FIRED      lookalike human: -> named' "$TMP/st3.txt"; } \
  && ok "S32-IV-E1 --selftest fires the invisible-character probe; with the hidden-character drop emptied it reports NOT FIRED and exits 5" \
  || bad "S32-IV-E1 selftest probe" "rc3=$rc3 $(grep -n 'invisible\|SELFTEST' "$TMP/st.txt" "$TMP/st3.txt" | tr '\n' '|')"

section "starter name"
# SC-2765: --init-house-rules wrote the folder name unquoted, so a folder named yes, null, 123 or on became a YAML boolean, null or
# integer for base.name (okflint read it without complaint, but the type was wrong). The starter now quotes it.
for fname in yes null 123 on "my notes" 2026-10-24; do
  B="$TMP/names/$fname"; mkdir -p "$B"
  "$CHECK" --init-house-rules "$B" >"$TMP/out.txt" 2>&1; rc=$?
  kind=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[3])   # -I ignores PYTHONPATH
import yaml
n = yaml.safe_load(open(sys.argv[1]))["base"]["name"]
print(type(n).__name__, n == sys.argv[2])' "$B/okf-base.yaml" "$fname" "$HERE/../vendor/pyyaml" 2>&1)
  { [ "$rc" = 0 ] && [ "$kind" = "str True" ]; } \
    && ok "SC-2765 a folder named '$fname' gives a starter whose base.name is the string '$fname'" \
    || bad "SC-2765 starter name '$fname'" "rc=$rc type/equal=$kind $(grep -n 'name:' "$B/okf-base.yaml" | head -1)"
done
# Non-ASCII folder names: the filter that decides between keeping the name and the "bundle" fallback depends on the locale
# (bash 3.2 keeps a letter under en_US.UTF-8; the C locale falls back; bash 5.2 is UNPROVEN until the Debian gate), so the
# case pins only what holds in both: the starter's base.name is a string (the name or "bundle") and the run exits 0.
for LOC in C en_US.UTF-8; do
  for fname in "ıx" "ß" "ﬁ" "İ"; do
    B="$TMP/names-$LOC/$fname"; mkdir -p "$B"
    LC_ALL=$LOC "$CHECK" --init-house-rules "$B" >"$TMP/out.txt" 2>&1; rc=$?
    kind=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[3])   # -I ignores PYTHONPATH
import yaml
n = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["base"]["name"]
print(type(n).__name__, n in (sys.argv[2], "bundle"))' "$B/okf-base.yaml" "$fname" "$HERE/../vendor/pyyaml" 2>&1)
    { [ "$rc" = 0 ] && [ "$kind" = "str True" ]; } \
      && ok "SC-2765 under LC_ALL=$LOC a folder named '$fname' gives a starter whose base.name is a string (the name or bundle)" \
      || bad "SC-2765 non-ASCII '$fname' under $LOC" "rc=$rc type/value=$kind $(grep -n 'name:' "$B/okf-base.yaml" 2>/dev/null | head -1)"
  done
done
B="$TMP/names/a&b"; mkdir -p "$B"; "$CHECK" --init-house-rules "$B" >/dev/null 2>&1
grep -qx '  name: "bundle"' "$B/okf-base.yaml" \
  && ok "SC-2765 a folder name with a character outside letters, digits, dot, dash, underscore and space still falls back to \"bundle\"" \
  || bad "SC-2765 fallback name" "$(grep -n 'name:' "$B/okf-base.yaml" | head -1)"

section "trust note in --json"
# RM-20: the text report says once, under a Trust finding, that okf-check cannot prove who a person is. The --json report held
# only the finding objects, so a CI job or an agent reading it never saw that a `human:` entry is a claim in the file.
B="$TMP/tn1"; mkb "$B"; vnote "$B/v.md" 'human:dana'
"$CHECK" --json "$B" >"$TMP/tn1.json" 2>"$TMP/tn1.err"; rc=$?
note=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["trust_findings"]), d.get("trust_note", "<absent>"))' "$TMP/tn1.json" 2>&1)
{ [ "$rc" = 0 ] && [ "$note" = "1 okf-check cannot prove who a person is. A human: entry is a claim in the file." ]; } \
  && ok "RM-20 --json carries trust_note, the text report's sentence, beside a trust finding" \
  || bad "RM-20 trust_note present" "rc=$rc trust_findings/trust_note: $note"
"$CHECK" "$B" >"$TMP/tn1.txt" 2>&1
[ "$(grep -c 'cannot prove who a person is' "$TMP/tn1.txt")" = 1 ] && grep -q '^                   okf-check cannot prove who a person is. A human: entry is a claim in the file.$' "$TMP/tn1.txt" \
  && ok "RM-20 the text report still prints the sentence once, indented under the Trust lines" \
  || bad "RM-20 text sentence" "$(grep -n 'prove who' "$TMP/tn1.txt" | head -2)"
B="$TMP/tn2"; mkb "$B"
"$CHECK" --json "$B" >"$TMP/tn2.json" 2>"$TMP/tn2.err"
note=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["trust_findings"]), d.get("trust_note", "<absent>"))' "$TMP/tn2.json" 2>&1)
[ "$note" = "0 <absent>" ] && ok "RM-20 --json has no trust_note when there is no human: finding" || bad "RM-20 trust_note absent" "$note"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
