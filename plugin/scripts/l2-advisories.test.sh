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

  # BL-624: which 200 advisories survive the cut must not depend on the order okflint reports them in (it follows the
  # disk's listing, which differs between macOS and Linux for the same bundle). 250 links written from n249 down to n000:
  # okflint reports them in that order; the report sorts, so the survivors are the 200 first by name, n000 to n199.
  B="$TMP/e1s"; body=""; i=249
  while [ "$i" -ge 0 ]; do body="$body[x](n$(printf %03d "$i").md)
"; i=$((i-1)); done
  mkb "$B" "$body"
  got=$(jq_py "$B" 'd["l2_warnings"], len(d["l2_advisories"]), d["l2_advisories"][0], d["l2_advisories"][199], d["l2_advisories"][-1]')
  want="250 201 L002 a.md — broken markdown link: n000.md L002 a.md — broken markdown link: n199.md ... and 50 more (l2_warnings has the total)"
  [ "$got" = "$want" ] && ok "BL-624 250 advisories reported in descending order: the 200 listed are the first 200 by name" \
    || bad "BL-624 sorted before the cut" "got: $got; want: $want"

  # S13-LF-E2: the temporary mirror .okfignore builds never shows in the report. log.md is missing, so okflint
  # reports R201 and puts the root it was given into the message.
  B="$TMP/e2"; mkb "$B" '![pic](img/missing.png)'; rm -f "$B/log.md"; mkdir -p "$B/archive"; printf 'old\n' > "$B/archive/o.md"; printf 'archive/\n' > "$B/.okfignore"
  "$CHECK" --json "$B" > "$TMP/e2.json" 2>/dev/null
  got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([x for x in d["l2_findings"] if x.startswith("R201")])' "$TMP/e2.json")
  want="['R201 log.md — reserved file missing in $B: log.md']"
  { [ "$got" = "$want" ] && ! grep -q 'okfmirror' "$TMP/e2.json"; } && ok "S13-LF-E2 with .okfignore the R201 message names the bundle, not the okfmirror copy" \
    || bad "S13-LF-E2 mirror path" "got: $got; want: $want; okfmirror in report: $(grep -c okfmirror "$TMP/e2.json")"

  # OOS-2: the same in the TEXT report when the temp folder is reached through a link (on macOS /var is a link to /private/var,
  # so the report held /private/private/tmp/...: the copy's real path was cut at its linked spelling and the bundle's path put in).
  # TMPDIR is a link here, and the copy's real path is under another spelling of it: the report must name only the bundle.
  B="$TMP/e2t"; mkb "$B" '![pic](img/missing.png)'; rm -f "$B/log.md"; mkdir -p "$B/archive"; printf 'old\n' > "$B/archive/o.md"; printf 'archive/\n' > "$B/.okfignore"
  mkdir -p "$TMP/realtmp"; ln -s "$TMP/realtmp" "$TMP/linktmp"
  TMPDIR="$TMP/linktmp" "$CHECK" "$B" > "$TMP/e2t.txt" 2>/dev/null
  got=$(grep -a 'R201' "$TMP/e2t.txt" | sed 's/^ *//')
  want="R201 log.md — reserved file missing in $B: log.md"
  { [ "$got" = "$want" ] && ! grep -aq 'okfmirror\|/private/private' "$TMP/e2t.txt"; } && ok "OOS-2 text report: the R201 message names the bundle once, whatever spelling of the temp folder the copy's path has" \
    || bad "OOS-2 mirror path in the text report" "got: $got; want: $want"

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

# S45-CJ: a STUB okflint (no real okflint needed) that dies on crash.md and, run on the other notes, reports two warnings.
# The text report lists the advisories and names the crashed note; --json must carry the same advisories.
section "S45-CJ crash isolation in --json"
S45="$TMP/s45"; mkb "$S45/b"; mkdir -p "$S45/bin"; printf -- '---\ntype: Lesson\ntitle: X\ndescription: D\n---\nboom\n' > "$S45/b/crash.md"
cat > "$S45/bin/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
if [ -f crash.md ]; then echo "Traceback: stub crash" >&2; exit 3; fi
echo '[{"severity":"warning","code":"L002","file":"a.md","message":"broken markdown link: nope.md"},{"severity":"warning","code":"S205","file":"a.md","message":"stub advisory"}]'; exit 0
STUB
chmod +x "$S45/bin/okflint"
env PATH="$S45/bin:$PATH" "$CHECK" "$S45/b" > "$S45/t.txt" 2>&1; rc_t=$?
env PATH="$S45/bin:$PATH" "$CHECK" --json "$S45/b" > "$S45/j.json" 2>/dev/null; rc_j=$?
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["l2_profile"], d["l2_warnings"], sorted(d["l2_by_rule"].items()), d["l2_advisories"])' "$S45/j.json" 2>&1)
want="could_not_run 2 [('L002', 1), ('S205', 1)] ['L002 a.md — broken markdown link: nope.md', 'S205 a.md — stub advisory']"
{ [ "$rc_t" = 2 ] && [ "$rc_j" = 2 ] && grep -Fq 'by rule: L002 x1, S205 x1' "$S45/t.txt" && grep -Fq 'crashed on' "$S45/t.txt" && [ "$got" = "$want" ]; } \
  && ok "S45-CJ-H1 a crashed note: --json carries the same two advisories as the text, and still says could_not_run (exit 2 both)" \
  || bad "S45-CJ-H1 json matches text" "rc text=$rc_t json=$rc_j; got: $got; want: $want"
# S45-CJ-N1: no crash, no isolation: unchanged (the same two advisories, l2_profile ran).
rm -f "$S45/b/crash.md"
env PATH="$S45/bin:$PATH" "$CHECK" --json "$S45/b" > "$S45/j2.json" 2>/dev/null
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["l2_profile"], d["l2_warnings"], len(d["l2_advisories"]))' "$S45/j2.json" 2>&1)
[ "$got" = "ran 2 2" ] && ok "S45-CJ-N1 no crashed note: --json is unchanged (ran, 2 warnings, 2 advisories)" \
  || bad "S45-CJ-N1 no crash" "got: $got"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
