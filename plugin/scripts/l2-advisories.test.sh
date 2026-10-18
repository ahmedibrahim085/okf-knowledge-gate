#!/usr/bin/env bash
# Tests for the L2 advisory list in `okf-check --json` (cases S13-LF-* in docs/0.9.x-cases.md and
# docs/gherkin/s13-l2-findings.feature; GitHub #98, public okf-knowledge-gate #2, second half).
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
  # S13-LF-H1: the public #2 repro. A missing image and a missing note are two L002 advisories.
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
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
