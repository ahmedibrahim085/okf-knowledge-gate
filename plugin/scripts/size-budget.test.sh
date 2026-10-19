#!/usr/bin/env bash
# Tests for the body-size budget, okf_check.size (cases S16-SB-* in docs/0.9.x-cases.md and
# docs/gherkin/s16-size-budget.feature; public okf-knowledge-gate #17).
#
# Agents read a note whole inside a fixed context window, so a house rule caps the BODY of a note in characters.
# These tests observe what a maintainer sees: `okf-check` text, `--json` and the exit code, on small bundles.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"   # nothing here reads or writes the real home

# mkb <dir> [size block lines]: a clean bundle (index, log, one note c.md) with the house manifest L2 needs. The
# optional lines are appended to okf-base.yaml verbatim, e.g. $'okf_check:\n  size:\n    max_body_chars: 40000'.
mkb() {
  mkbundle "$1"
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"
  [ -n "${2:-}" ] && printf '%s\n' "$2" >> "$1/okf-base.yaml"
  return 0
}

# size_cfg <max> [warn]: the okf_check lines for the two keys; an empty argument leaves its key out.
size_cfg() {
  printf 'okf_check:\n  size:\n'
  [ -n "${1:-}" ] && printf '    max_body_chars: %s\n' "$1"
  [ -n "${2:-}" ] && printf '    warn_body_chars: %s\n' "$2"
  return 0
}

# mknote <file> <chars> [char] [extra frontmatter]: a note whose body is EXACTLY <chars> characters (no newline after
# it), the character repeated; the characters count code points, so "é" gives two bytes each.
mknote() {
  mkdir -p "$(dirname "$1")"
  "$REALPY" - "$@" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
ch = sys.argv[3] if len(sys.argv) > 3 else "a"
extra = sys.argv[4] + "\n" if len(sys.argv) > 4 else ""   # a command substitution drops the final newline
fm = '---\ntype: Lesson\ntitle: T %s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n%s---\n' % (path, extra)
open(path, "w", encoding="utf-8", newline="").write(fm + ch * n)
PY
}

# run <bundle> [args...]: text output in $TMP/out.txt, exit code on stdout.
run() { local b="$1"; shift; "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
runjson() { local b="$1"; shift; "$CHECK" --json "$b" "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }

section "happy"
# S16-SB-H1: the reporter's case. 40,001 characters against a limit of 40,000.
B="$TMP/h1"; mkb "$B" "$(size_cfg 40000)"; mknote "$B/big.md" 40001
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Fq 'big.md: body is 40001 characters, above okf_check.size.max_body_chars 40000' "$TMP/out.txt" \
  && grep -Fq 'split or move a section to a companion note; do not compress' "$TMP/out.txt"; } \
  && ok "S16-SB-H1 a body of 40001 characters under max_body_chars 40000 is an error naming note, size, limit and the fix (exit 1)" \
  || bad "S16-SB-H1 over the maximum" "rc=$rc $(grep -n 'Size\|big.md' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-H2: between the two limits is a warning: exit 0, the note named with its size and the limit, and the verdict
# line does not say a bare pass.
B="$TMP/h2"; mkb "$B" "$(size_cfg 40000 38000)"; mknote "$B/mid.md" 38001
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -Fq 'mid.md: body is 38001 characters, above okf_check.size.warn_body_chars 38000' "$TMP/out.txt" \
  && grep -Fq 'do not compress' "$TMP/out.txt" && grep -q 'Size  *WARN' "$TMP/out.txt" && ! grep -q 'ALL GATES PASS' "$TMP/out.txt"; } \
  && ok "S16-SB-H2 a body of 38001 characters under warn_body_chars 38000 is a warning only (exit 0, counted as an advisory)" \
  || bad "S16-SB-H2 over the warning limit" "rc=$rc $(grep -n 'Size\|mid.md\|PASS' "$TMP/out.txt" | head -4 | tr '\n' '|')"

# S16-SB-H3: one run with a note over each limit and one under both: the first is the error, the second the warning,
# and a note over the maximum is not warned about a second time.
B="$TMP/h3"; mkb "$B" "$(size_cfg 100 50)"; mknote "$B/over.md" 101; mknote "$B/mid.md" 51; mknote "$B/ok.md" 50
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Fq 'over.md: body is 101 characters, above okf_check.size.max_body_chars 100' "$TMP/out.txt" \
  && grep -Fq 'mid.md: body is 51 characters, above okf_check.size.warn_body_chars 50' "$TMP/out.txt" \
  && [ "$(grep -c 'over.md: body is' "$TMP/out.txt")" = 1 ] && ! grep -q 'ok.md: body is' "$TMP/out.txt"; } \
  && ok "S16-SB-H3 notes over each limit and under both: one error, one warning, one silent (exit 1)" \
  || bad "S16-SB-H3 error and warning together" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -5 | tr '\n' '|')"

section "negative"
# S16-SB-N4: a value that is not a whole number from 1, or a warn limit that is not below the maximum, is a config
# error (exit 2) that says which key and why. The note is 500 characters, so an accepted value would show up as exit 1.
# bad_cfg <label> <yaml lines> <message fragment>
bad_cfg() {
  local B="$TMP/n4-$1" rc
  mkb "$B" "$2"; mknote "$B/big.md" 500
  rc=$(run "$B")
  { [ "$rc" = 2 ] && grep -Fq "$3" "$TMP/out.txt"; } \
    && ok "S16-SB-N4 $1 is refused with a clear message (exit 2)" \
    || bad "S16-SB-N4 $1" "rc=$rc want 2 and '$3': $(grep -n 'Config\|Size' "$TMP/out.txt" | head -2 | tr '\n' '|')"
}
bad_cfg zero      "$(size_cfg 0)"        'okf_check.size.max_body_chars must be a whole number from 1 to'
bad_cfg negative  "$(size_cfg -5)"       'okf_check.size.max_body_chars must be a whole number from 1 to'
bad_cfg string    "$(size_cfg big)"      'okf_check.size.max_body_chars must be a whole number from 1 to'
bad_cfg float     "$(size_cfg 40.5)"     'okf_check.size.max_body_chars must be a whole number from 1 to'
bad_cfg bool      "$(size_cfg true)"     'okf_check.size.max_body_chars must be a whole number from 1 to'
bad_cfg warn-zero "$(size_cfg 100 0)"    'okf_check.size.warn_body_chars must be a whole number from 1 to'
bad_cfg warn-eq   "$(size_cfg 100 100)"  'okf_check.size.warn_body_chars must be below okf_check.size.max_body_chars'
bad_cfg warn-gt   "$(size_cfg 100 200)"  'okf_check.size.warn_body_chars must be below okf_check.size.max_body_chars'
bad_cfg typo-key  $'okf_check:\n  size:\n    max_body_char: 100' 'okf_check.size.max_body_char is not a known key'
bad_cfg not-map   $'okf_check:\n  size: 100' 'okf_check.size must be a mapping'

# size_line <file>: the Size verdict word (FAIL, WARN, PASS or none) of the last run's text.
size_line() { sed -n 's/^  Size  *\([A-Z]*\) .*/\1/p' "$1" | head -1; }

# S16-SB-N1: the limit itself passes; one more character is over. Same for the warning limit.
B="$TMP/n1"; mkb "$B" "$(size_cfg 40000 38000)"; mknote "$B/at-max.md" 38000
rc=$(run "$B")
{ [ "$rc" = 0 ] && [ "$(size_line "$TMP/out.txt")" = PASS ]; } \
  && ok "S16-SB-N1 a body of exactly warn_body_chars (38000) gives no finding" \
  || bad "S16-SB-N1 at the warning limit" "rc=$rc $(grep -n 'Size' "$TMP/out.txt" | head -2 | tr '\n' '|')"
B="$TMP/n1b"; mkb "$B" "$(size_cfg 40000)"; mknote "$B/at-max.md" 40000
rc=$(run "$B")
{ [ "$rc" = 0 ] && [ "$(size_line "$TMP/out.txt")" = PASS ]; } \
  && ok "S16-SB-N1 a body of exactly max_body_chars (40000) passes (exit 0)" \
  || bad "S16-SB-N1 at the maximum" "rc=$rc $(grep -n 'Size' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S16-SB-N2: only the body counts. A 5000-character verified: block in the frontmatter is not measured.
B="$TMP/n2"; mkb "$B" "$(size_cfg 100)"
mknote "$B/long-fm.md" 50 a "$(printf 'verified:\n  - by: human:t\n    at: "2026-01-02"\n    note: %s\n' "$("$REALPY" -c 'print("z"*5000)')")"
rc=$(run "$B")
{ [ "$(size_line "$TMP/out.txt")" = PASS ] && [ "$(wc -c < "$B/long-fm.md")" -gt 5000 ]; } \
  && ok "S16-SB-N2 a 5000-character verified: block does not count toward the body" \
  || bad "S16-SB-N2 frontmatter not counted" "rc=$rc size=$(size_line "$TMP/out.txt") $(grep "body is" "$TMP/out.txt" | head -2) $(grep -n 'Size' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S16-SB-N3: no size key (or an empty one): no Size line at all, and an oversize note is nobody's business.
B="$TMP/n3"; mkb "$B"; mknote "$B/huge.md" 90000
rc=$(run "$B")
{ [ "$rc" = 0 ] && [ -z "$(size_line "$TMP/out.txt")" ]; } \
  && ok "S16-SB-N3 without a size key nothing is printed and a 90000-character body passes" \
  || bad "S16-SB-N3 no size key" "rc=$rc $(grep -n 'Size' "$TMP/out.txt" | head -2 | tr '\n' '|')"
B="$TMP/n3b"; mkb "$B" $'okf_check:\n  size: {}'; mknote "$B/huge.md" 90000
rc=$(run "$B")
{ [ "$rc" = 0 ] && [ -z "$(size_line "$TMP/out.txt")" ]; } \
  && ok "S16-SB-N3 an empty size block prints nothing either" \
  || bad "S16-SB-N3 empty size block" "rc=$rc $(grep -n 'Size' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S16-SB-N5: a note .okfignore excludes is not part of the bundle; the control run proves the note is over the limit.
B="$TMP/n5"; mkb "$B" "$(size_cfg 100)"; mknote "$B/archive/old.md" 500
rc=$(run "$B"); ctl=$(grep -c 'archive/old.md: body is 500' "$TMP/out.txt")
printf 'archive/\n' > "$B/.okfignore"
rc2=$(run "$B")
{ [ "$ctl" = 1 ] && [ "$rc" = 1 ] && [ "$rc2" = 0 ] && ! grep -q 'old.md: body is' "$TMP/out.txt"; } \
  && ok "S16-SB-N5 an .okfignore'd oversize note is reported without the ignore file and not with it" \
  || bad "S16-SB-N5 .okfignore" "control rc=$rc hits=$ctl; ignored rc=$rc2 $(grep -n 'Size\|old.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"

section "edge"
# S16-SB-E1: characters are code points, not bytes: 40001 two-byte characters are 80002 bytes and count as 40001.
B="$TMP/e1"; mkb "$B" "$(size_cfg 40000)"; mknote "$B/utf.md" 40001 é
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Fq 'utf.md: body is 40001 characters' "$TMP/out.txt" && [ "$(wc -c < "$B/utf.md")" -gt 80002 ]; } \
  && ok "S16-SB-E1 40001 two-byte characters (80002 body bytes) count as 40001 characters" \
  || bad "S16-SB-E1 multibyte over" "rc=$rc $(grep -n 'Size\|utf.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"
B="$TMP/e1b"; mkb "$B" "$(size_cfg 40000)"; mknote "$B/utf.md" 40000 é
rc=$(run "$B")
[ "$rc" = 0 ] && ok "S16-SB-E1 40000 two-byte characters (80000 bytes) pass: bytes are not the measure" \
  || bad "S16-SB-E1 multibyte at the limit" "rc=$rc $(grep -n 'Size\|utf.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"
B="$TMP/e1c"; mkb "$B" "$(size_cfg 100)"; mknote "$B/emoji.md" 60 🙂
rc=$(run "$B")
[ "$rc" = 0 ] && ok "S16-SB-E1 sixty four-byte characters (240 bytes, one code point each) pass a limit of 100" \
  || bad "S16-SB-E1 four-byte characters" "rc=$rc $(grep -n 'Size\|emoji.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S16-SB-E2: CRLF. A file with CRLF line endings throughout measures like the same file with LF: a line break is one
# character, so a checkout with autocrlf does not move a note across the limit.
B="$TMP/e2"; mkb "$B" "$(size_cfg 60)"; mknote "$B/crlf.md" 0
"$REALPY" - "$B/crlf.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, newline="").read() + "a\n" * 30
open(p, "w", newline="").write(t.replace("\n", "\r\n"))
PY
rc=$(run "$B")
{ [ "$(size_line "$TMP/out.txt")" = PASS ] && grep -q $'\r' "$B/crlf.md"; } \
  && ok "S16-SB-E2 a CRLF note with 30 two-character lines (60 body characters) passes max 60" \
  || bad "S16-SB-E2 CRLF at the limit" "rc=$rc $(grep -n 'Size\|crlf.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"
B="$TMP/e2b"; mkb "$B" "$(size_cfg 59)"; cp "$TMP/e2/crlf.md" "$B/crlf.md"
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Fq 'crlf.md: body is 60 characters' "$TMP/out.txt"; } \
  && ok "S16-SB-E2 the same CRLF note under max 59 reports 60 characters (CRLF counted once)" \
  || bad "S16-SB-E2 CRLF over" "rc=$rc $(grep -n 'Size\|crlf.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S16-SB-E3: a BOM before the frontmatter is not content and does not hide the frontmatter.
B="$TMP/e3"; mkb "$B" "$(size_cfg 100)"; mknote "$B/bom.md" 100
printf '\xef\xbb\xbf' | cat - "$B/bom.md" > "$B/bom.tmp" && mv "$B/bom.tmp" "$B/bom.md"
rc=$(run "$B")
{ [ "$(size_line "$TMP/out.txt")" = PASS ] && [ "$(head -c 3 "$B/bom.md" | od -An -tx1 | tr -d ' ')" = efbbbf ]; } \
  && ok "S16-SB-E3 a BOM note with a 100-character body passes max 100" \
  || bad "S16-SB-E3 BOM" "rc=$rc $(grep -n 'Size\|bom.md' "$TMP/out.txt" | head -2 | tr '\n' '|')"

# S16-SB-E4: an empty body, a frontmatter-only note without a final newline, and a note with no frontmatter.
B="$TMP/e4"; mkb "$B" "$(size_cfg 1)"; mknote "$B/empty.md" 0; mknote "$B/one.md" 1
printf -- '---\ntype: Lesson\ntitle: F\ndescription: D\nstatus: stable\nstale_after: "2099-01-01"\n---' > "$B/fm-only.md"
rc=$(run "$B")
{ grep -q 'c.md: body is 6 ' "$TMP/out.txt" && ! grep -q 'empty.md: body\|fm-only.md: body\|one.md: body' "$TMP/out.txt"; } \
  && ok "S16-SB-E4 an empty body, a frontmatter-only note and a 1-character body pass max 1 (c.md, 6 characters, is the control: it is named)" \
  || bad "S16-SB-E4 empty bodies" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -3 | tr '\n' '|')"
B="$TMP/e4b"; mkb "$B" "$(size_cfg 100)"; "$REALPY" -c 'open("'"$B"'/plain.md","w").write("x"*101)'
rc=$(run "$B")
grep -Fq 'plain.md: body is 101 characters' "$TMP/out.txt" \
  && ok "S16-SB-E4 a note with no frontmatter is all body (101 characters; L1 reports the missing frontmatter)" \
  || bad "S16-SB-E4 no frontmatter" "rc=$rc $(grep -n 'Size\|plain.md' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E5: index.md and log.md are measured like any note (an agent reads them whole; a log only grows).
B="$TMP/e5"; mkb "$B" "$(size_cfg 100)"
"$REALPY" -c 'open("'"$B"'/log.md","w").write("# Log\n\n## 2026-01-01\n" + "* created\n"*20)'
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Eq 'log.md: body is 2[0-9][0-9] characters' "$TMP/out.txt"; } \
  && ok "S16-SB-E5 log.md over the limit is reported" \
  || bad "S16-SB-E5 log.md" "rc=$rc $(grep -n 'Size\|log.md' "$TMP/out.txt" | head -3 | tr '\n' '|')"
B="$TMP/e5b"; mkb "$B" "$(size_cfg 100)"
"$REALPY" -c 'open("'"$B"'/index.md","w").write("---\nokf_version: \"0.2\"\n---\n# B\n\n" + "* a line of the index\n"*10)'
rc=$(run "$B")
grep -Eq 'index.md: body is [0-9]+ characters' "$TMP/out.txt" \
  && ok "S16-SB-E5 index.md over the limit is reported" \
  || bad "S16-SB-E5 index.md" "rc=$rc $(grep -n 'Size\|index.md' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E6: a note that is not valid UTF-8 is L1's to report (once); the size rule does not crash and does not report it.
B="$TMP/e6"; mkb "$B" "$(size_cfg 100)"; printf -- '---\ntype: Lesson\n---\n\xff\xfe\xfd' > "$B/binary.md"
rc=$(run "$B")
{ [ "$(grep -c 'cannot read file' "$TMP/out.txt")" -ge 1 ] && ! grep -q 'Traceback\|binary.md: body is' "$TMP/out.txt" && [ "$rc" = 1 ] \
  && [ "$(size_line "$TMP/out.txt")" = PASS ]; } \
  && ok "S16-SB-E6 a non-UTF-8 note is reported by L1 only; the size rule skips it without a traceback" \
  || bad "S16-SB-E6 non-UTF-8 note" "rc=$rc $(grep -n 'Size\|binary.md\|Traceback' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E7: a note in a folder is named by its path from the bundle root; a trailing newline counts as a character.
B="$TMP/e7"; mkb "$B" "$(size_cfg 100)"; mknote "$B/sub/deep/n.md" 100; printf '\n' >> "$B/sub/deep/n.md"
rc=$(run "$B/")
{ [ "$rc" = 1 ] && grep -Fq 'sub/deep/n.md: body is 101 characters' "$TMP/out.txt"; } \
  && ok "S16-SB-E7 sub/deep/n.md is named by its path (bundle given with a trailing slash); the final newline counts" \
  || bad "S16-SB-E7 nested path" "rc=$rc $(grep -n 'Size\|n.md' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E8: each key alone works: a maximum without a warning limit, and a warning limit without a maximum.
B="$TMP/e8"; mkb "$B" "$(size_cfg 100)"; mknote "$B/n.md" 99
rc=$(run "$B"); [ "$rc" = 0 ] && [ "$(size_line "$TMP/out.txt")" = PASS ] \
  && ok "S16-SB-E8 max_body_chars alone: a body under it passes" || bad "S16-SB-E8 max alone" "rc=$rc"
B="$TMP/e8b"; mkb "$B" "$(size_cfg '' 100)"; mknote "$B/n.md" 101
rc=$(run "$B")
{ [ "$rc" = 0 ] && [ "$(size_line "$TMP/out.txt")" = WARN ] && grep -Fq 'n.md: body is 101 characters, above okf_check.size.warn_body_chars 100' "$TMP/out.txt"; } \
  && ok "S16-SB-E8 warn_body_chars alone: a warning, never an error (exit 0)" \
  || bad "S16-SB-E8 warn alone" "rc=$rc $(grep -n 'Size\|n.md' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E9: --json lists the error in errors[] with the exit code 1; a warning leaves exit 0.
B="$TMP/e9"; mkb "$B" "$(size_cfg 100)"; mknote "$B/big.md" 101
rc=$(runjson "$B"); got=$(jget '[e for e in d["errors"] if "big.md: body is 101" in e]')
{ [ "$rc" = 1 ] && [ "$(jget 'd["exit"]')" = 1 ] && [ "$got" != "[]" ]; } \
  && ok "S16-SB-E9 --json: exit 1 and the finding is in errors" \
  || bad "S16-SB-E9 json" "rc=$rc errors=$(jget 'd["errors"]')"

# S16-SB-E10: precedence. A broken okf_check block is exit 2 and the size rule does not run on numbers it cannot trust;
# a size error outranks a stale note under --fail-stale (a reached verdict beats a staleness one, as for require_owner).
B="$TMP/e10"; mkb "$B" "$(size_cfg 100)"$'\n  require_owner: 3'; mknote "$B/big.md" 101
rc=$(run "$B")
{ [ "$rc" = 2 ] && [ -z "$(size_line "$TMP/out.txt")" ]; } \
  && ok "S16-SB-E10 an invalid sibling key makes the run exit 2 and the size rule stays silent" \
  || bad "S16-SB-E10 config precedence" "rc=$rc $(grep -n 'Config\|Size' "$TMP/out.txt" | head -3 | tr '\n' '|')"
B="$TMP/e10b"; mkb "$B" "$(size_cfg 100)"; mknote "$B/big.md" 101
sed -i.bak 's/stale_after: "2099-01-01"/stale_after: "2000-01-01"/' "$B/big.md"; rm -f "$B/big.md.bak"
rc=$(run "$B" --fail-stale)
[ "$rc" = 1 ] && ok "S16-SB-E10 a size error and an expired note under --fail-stale exit 1, not 4" \
  || bad "S16-SB-E10 stale precedence" "rc=$rc $(grep -n 'Size\|FAILED' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E11: a symlinked folder is not entered (its notes count once, under their real path); a symlinked note file counts.
B="$TMP/e11"; mkb "$B" "$(size_cfg 100)"; mknote "$B/real/big.md" 101; ln -s real "$B/alias"
rc=$(run "$B")
{ [ "$rc" = 1 ] && [ "$(grep -c 'body is 101' "$TMP/out.txt")" = 1 ] && grep -Fq 'real/big.md: body is 101' "$TMP/out.txt"; } \
  && ok "S16-SB-E11 a symlinked folder is not entered: the oversize note is reported once, under real/" \
  || bad "S16-SB-E11 folder link" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -3 | tr '\n' '|')"
B="$TMP/e11b"; mkb "$B" "$(size_cfg 100)"; mknote "$TMP/e11b-outside/note.md" 101; ln -s "$TMP/e11b-outside/note.md" "$B/linked.md"
rc=$(run "$B")
grep -Fq 'linked.md: body is 101' "$TMP/out.txt" \
  && ok "S16-SB-E11 a symlinked note file is measured, like the other layers read it" \
  || bad "S16-SB-E11 file link" "rc=$rc $(grep -n 'Size\|linked' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-E12: --selftest plants a note over a limit set for the probe only, and a gate that stops firing fails it.
"$CHECK" --selftest >"$TMP/st.txt" 2>&1; rc=$?
{ [ "$rc" = 0 ] && grep -Eq 'FIRED  +body over the limit' "$TMP/st.txt"; } \
  && ok "S16-SB-E12 --selftest: the size probe reports FIRED and the run exits 0" \
  || bad "S16-SB-E12 selftest" "rc=$rc $(grep -n 'Size\|body over\|SELFTEST' "$TMP/st.txt" | head -3 | tr '\n' '|')"
D="$TMP/dead-size"; mkdir -p "$D"; cp -R "$HERE/.." "$D/plugin" 2>/dev/null
sed -i.orig 's|^run_size() {|run_size() { return 0;|' "$D/plugin/scripts/okf-check"
if cmp -s "$D/plugin/scripts/okf-check" "$D/plugin/scripts/okf-check.orig"; then
  bad "S16-SB-E12 crippled copy" "the cripple changed nothing"
else
  "$D/plugin/scripts/okf-check" --selftest >"$TMP/st-dead.txt" 2>&1; rc=$?
  { [ "$rc" = 5 ] && grep -Eq 'NOT FIRED  +body over the limit' "$TMP/st-dead.txt"; } \
    && ok "S16-SB-E12 with the size rule crippled the probe reports NOT FIRED and --selftest exits 5" \
    || bad "S16-SB-E12 dead size rule" "rc=$rc $(grep -n 'Size\|body over\|SELFTEST' "$TMP/st-dead.txt" | head -3 | tr '\n' '|')"
fi

# S16-SB-E12 control leg: a size rule that flags EVERY note (c > mx turned into c >= 0) must not pass the probe, because
# the probe also requires that the notes under the limit are not listed.
D="$TMP/all-size"; mkdir -p "$D"; cp -R "$HERE/.." "$D/plugin" 2>/dev/null
sed -i.orig 's|c > mx|c >= 0|' "$D/plugin/scripts/okf-check"
if cmp -s "$D/plugin/scripts/okf-check" "$D/plugin/scripts/okf-check.orig"; then
  bad "S16-SB-E12 flag-everything copy" "the mutation changed nothing"
else
  "$D/plugin/scripts/okf-check" --selftest >"$TMP/st-all.txt" 2>&1; rc=$?
  { [ "$rc" = 5 ] && grep -Eq 'NOT FIRED  +body over the limit' "$TMP/st-all.txt"; } \
    && ok "S16-SB-E12 with the size rule flagging every note the probe reports NOT FIRED and --selftest exits 5" \
    || bad "S16-SB-E12 flag-everything size rule" "rc=$rc $(grep -n 'Size\|body over\|SELFTEST' "$TMP/st-all.txt" | head -3 | tr '\n' '|')"
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
