#!/usr/bin/env bash
# Tests for the L2 advisory list in `okf-check --json` (cases S13-LF-* in docs/0.9.x-cases.md and
# docs/gherkin/s13-l2-findings.feature; public okf-knowledge-gate #2, second half).
#
# `l2_warnings` and `l2_by_rule` counted the okflint advisories but no key named the files behind them.
# These tests observe what a CI job or agent reads: the `--json` report of a real okf-check run.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"   # nothing here reads or writes the real home

echo "okf-check L2 advisory list tests"

# A bundle okflint can judge: index, log, one note holding the given body, and the manifest L2 needs.
mkb() { # <dir> [body]
  local d="$1" body="${2:-clean}"
  mkdir -p "$d"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n[a](a.md)\n' > "$d/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$d/log.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01T00:00:00Z"\nstale_after: "2099-01-01"\n---\n\n%s\n' "$body" > "$d/a.md"
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$d/okf-base.yaml"
}

# jq_py <bundle> <python expression over the parsed report `d`> — prints the expression's value.
jq_py() {
  local b="$1" e="$2"
  "$CHECK" --json "$b" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print('"$e"')'
}

if ! command -v okflint >/dev/null 2>&1; then
  skip "S13-LF-* L2 cases need okflint" "uv tool install okflint"
else
  section "S13-LF happy"
  # S13-LF-H1: the okf-knowledge-gate#2 repro. A missing image and a missing note are two L002 advisories.
  B="$TMP/h1"; mkb "$B" '![pic](img/missing.png)
[x](nope.md)'
  got=$(jq_py "$B" 'd["l2_warnings"], d["l2_advisories"]')
  want="2 ['L002 a.md — broken markdown link: img/missing.png', 'L002 a.md — broken markdown link: nope.md']"
  [ "$got" = "$want" ] && ok "S13-LF-H1 --json lists each L2 advisory as 'RULE file — message'" \
    || bad "S13-LF-H1 advisories listed" "got: $got; want: $want"

  section "S13-LF negative"
  # S13-LF-N1: nothing to report gives an empty list, and l2_warnings says 0, not null.
  B="$TMP/n1"; mkb "$B"
  got=$(jq_py "$B" 'd["l2_warnings"], d["l2_advisories"]')
  [ "$got" = "0 []" ] && ok "S13-LF-N1 a clean bundle gives l2_advisories [] and l2_warnings 0" \
    || bad "S13-LF-N1 clean bundle" "got: $got; want: 0 []"

  section "S13-LF edge"
  # S13-LF-E1: 1,200 advisories. The list is cut, the cut is announced with its count, l2_warnings stays the true total.
  B="$TMP/e1"; body=""; i=0
  while [ "$i" -lt 1200 ]; do body="$body[x](n$i.md)
"; i=$((i+1)); done
  mkb "$B" "$body"
  got=$(jq_py "$B" 'd["l2_warnings"], len(d["l2_advisories"]), d["l2_advisories"][-1]')
  want="1200 201 ... and 1000 more (l2_warnings has the total)"
  [ "$got" = "$want" ] && ok "S13-LF-E1 1,200 advisories: 200 listed, an announced cut of 1000, l2_warnings 1200" \
    || bad "S13-LF-E1 capped list" "got: $got; want: $want"

  # S13-LF-E2: the temporary mirror .okfignore builds never shows in the report. log.md is missing, so okflint
  # reports R201 and puts the root it was given into the message.
  B="$TMP/e2"; mkb "$B" '![pic](img/missing.png)'; rm -f "$B/log.md"; mkdir -p "$B/archive"; printf 'old\n' > "$B/archive/o.md"; printf 'archive/\n' > "$B/.okfignore"
  "$CHECK" --json "$B" > "$TMP/e2.json" 2>/dev/null
  got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([x for x in d["l2_findings"] if x.startswith("R201")])' "$TMP/e2.json")
  want="['R201 log.md — reserved file missing in $B: log.md']"
  { [ "$got" = "$want" ] && ! grep -q 'okfmirror' "$TMP/e2.json"; } && ok "S13-LF-E2 with .okfignore the R201 message names the bundle, not the okfmirror copy" \
    || bad "S13-LF-E2 mirror path" "got: $got; want: $want; okfmirror in report: $(grep -c okfmirror "$TMP/e2.json")"

  # S13-LF-E3: same for the copy crash isolation builds when okflint dies on one note. A STUB dies on crashy.md on purpose.
  REALLINT=$(command -v okflint); STUB="$TMP/stub"; mkdir -p "$STUB"
  printf '#!/bin/sh\nif [ "$1" = validate ] && [ -f ./crashy.md ]; then echo "Traceback: stub crash" >&2; exit 3; fi\nexec "%s" "$@"\n' "$REALLINT" > "$STUB/okflint"; chmod +x "$STUB/okflint"
  B="$TMP/e3"; mkb "$B" '![pic](img/missing.png)'; rm -f "$B/log.md"; printf -- '---\ntype: Lesson\ntitle: X\ndescription: D\n---\nCRASHME\n' > "$B/crashy.md"
  env PATH="$STUB:$PATH" "$CHECK" --json "$B" > "$TMP/e3.json" 2>/dev/null
  got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([x for x in d["l2_findings"] if x.startswith("R201")])' "$TMP/e3.json")
  want="['R201 log.md — reserved file missing in $B: log.md']"
  { [ "$got" = "$want" ] && ! grep -q 'l2mirror' "$TMP/e3.json"; } && ok "S13-LF-E3 with a crashed note the R201 message names the bundle, not the l2mirror copy" \
    || bad "S13-LF-E3 l2mirror path" "got: $got; want: $want; l2mirror in report: $(grep -c l2mirror "$TMP/e3.json")"

  # S13-LF-E4: a bundle path and a note name holding a quote and a newline still give valid JSON, and the advisory names the note.
  B="$TMP/e4 \"q\"
x"; mkb "$B" '[x](nope.md)'; mv "$B/a.md" "$B/a\"b.md"; printf '[a](a"b.md)\n' >> "$B/index.md"
  got=$("$CHECK" --json "$B" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["l2_warnings"], d["l2_advisories"])' 2>&1)
  want="1 ['L002 a\"b.md — broken markdown link: nope.md']"
  [ "$got" = "$want" ] && ok "S13-LF-E4 --json stays valid for a bundle path and a note name with a quote and a newline" \
    || bad "S13-LF-E4 awkward names" "got: $got; want: $want"

  section "S20-IF advisory count"
  # S20-IF-H1: the summary counts the warnings the sections listed. One broken link is listed twice, as an L1 warning
  # and as an L2 one, so it is 2 advisories (L1 warnings are counted since S30-CF-N2); the line names each layer's share.
  B="$TMP/if1"; mkb "$B" '[x](nope.md)'
  "$CHECK" "$B" > "$TMP/if1.txt" 2>&1; rc=$?
  { [ "$rc" = 0 ] && grep -Fq 'L1 conformance   PASS   1 concepts, 0 errors, 1 warning(s)' "$TMP/if1.txt" \
    && grep -Fq 'L2 profile       PASS   0 errors, 1 warning(s) (advisory)' "$TMP/if1.txt" \
    && grep -Fq 'PASS — no blocking errors, but 2 advisory(ies) and' "$TMP/if1.txt" \
    && grep -Fq 'above (advisories: L1 1 + L2 1)' "$TMP/if1.txt"; } \
    && ok "S20-IF-H1 one broken link, 1 L1 and 1 L2 warning, gives '2 advisory(ies)' (L1 1 + L2 1) in the summary line (exit 0)" \
    || bad "S20-IF-H1 advisory count" "rc=$rc $(grep -n 'L1 conf\|L2 profile\|PASS' "$TMP/if1.txt" | tr '\n' '|')"

  # S20-IF-E1: the sources add up once each: two L1 warnings, two L2 warnings and one Trust warning are 5 advisories.
  B="$TMP/if2"; mkb "$B" '[x](nope.md)
[y](gone.md)'
  printf -- '---\ntype: Lesson\ntitle: V\ndescription: D\nstatus: draft\ntags: [t]\ngenerated:\n  by: process:x\n  at: "2026-01-01T00:00:00Z"\nverified:\n  by: human:bob\n  at: "2026-01-02T00:00:00Z"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$B/v.md"
  printf '[v](v.md)\n' >> "$B/index.md"
  "$CHECK" "$B" > "$TMP/if2.txt" 2>&1; rc=$?
  { [ "$rc" = 0 ] && grep -Fq 'L1 conformance   PASS   2 concepts, 0 errors, 2 warning(s)' "$TMP/if2.txt" \
    && grep -Fq 'Trust (C4)       WARN   1 warning(s), 0 advisory(ies)' "$TMP/if2.txt" \
    && grep -Fq 'L2 profile       PASS   0 errors, 2 warning(s) (advisory)' "$TMP/if2.txt" \
    && grep -Fq 'PASS — no blocking errors, but 5 advisory(ies) and' "$TMP/if2.txt" \
    && grep -Fq 'above (advisories: L1 2 + Trust 1 + L2 2)' "$TMP/if2.txt"; } \
    && ok "S20-IF-E1 two L1, two L2 and one Trust warning give '5 advisory(ies)' (L1 2 + Trust 1 + L2 2) in the summary" \
    || bad "S20-IF-E1 advisories add up" "rc=$rc $(grep -n 'L1 conf\|Trust\|L2 profile\|PASS' "$TMP/if2.txt" | tr '\n' '|')"

  # S20-IF-N1: nothing to report keeps the summary count at 0 (the L2 count is not added twice or from a stale value).
  B="$TMP/if3"; mkb "$B"
  "$CHECK" "$B" > "$TMP/if3.txt" 2>&1; rc=$?
  { [ "$rc" = 0 ] && ! grep -Eq 'but [1-9][0-9]* advisory' "$TMP/if3.txt"; } \
    && ok "S20-IF-N1 a bundle with no L2 or Trust warning does not report advisories" \
    || bad "S20-IF-N1 clean summary" "rc=$rc $(grep -n 'PASS' "$TMP/if3.txt" | tr '\n' '|')"
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
