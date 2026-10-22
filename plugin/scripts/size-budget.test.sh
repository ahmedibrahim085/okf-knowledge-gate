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

section "S20-IF size warnings in --json"
# S20-IF-H2: a size warning is in --json warnings[] with the note, the size and the limit; exit stays 0 and l1_warnings
# keeps counting the L1 warnings only.
B="$TMP/if-h2"; mkb "$B" "$(size_cfg 100 50)"; mknote "$B/mid.md" 51
rc=$(runjson "$B")
got=$(jget '[w for w in d["warnings"] if "mid.md: body is 51 characters, above okf_check.size.warn_body_chars 50" in w]')
{ [ "$rc" = 0 ] && [ "$got" != "[]" ] && [ "$(jget '[d["exit"], d["l1_warnings"], d["errors"]]')" = '[0, 0, []]' ]; } \
  && ok "S20-IF-H2 --json: a note over warn_body_chars is in warnings with note, size and limit (exit 0, errors empty)" \
  || bad "S20-IF-H2 size warning in json" "rc=$rc warnings=$(jget 'd["warnings"]')"

# S20-IF-E2: an error and a warning together: the error is in errors[] only, the warning in warnings[] only.
B="$TMP/if-e2"; mkb "$B" "$(size_cfg 100 50)"; mknote "$B/over.md" 101; mknote "$B/mid.md" 51; mknote "$B/ok.md" 50
rc=$(runjson "$B")
{ [ "$rc" = 1 ] && [ "$(jget '[len([e for e in d["errors"] if "over.md: body is 101" in e]), len([w for w in d["warnings"] if "mid.md: body is 51" in w]), len([w for w in d["warnings"] if "over.md" in w or "ok.md" in w])]')" = '[1, 1, 0]' ]; } \
  && ok "S20-IF-E2 --json: over.md only in errors, mid.md only in warnings, ok.md in neither (exit 1)" \
  || bad "S20-IF-E2 error and warning in json" "rc=$rc errors=$(jget 'd["errors"]') warnings=$(jget 'd["warnings"]')"

# S20-IF-E3: an L1 warning and a size warning share warnings[]; l1_warnings counts the L1 one alone.
B="$TMP/if-e3"; mkb "$B" "$(size_cfg 100 50)"; mknote "$B/mid.md" 51
printf -- '---\ntype: Lesson\ntitle: W\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: nobody\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nb\n' > "$B/w.md"
rc=$(runjson "$B")
{ [ "$rc" = 0 ] && [ "$(jget '[d["l1_warnings"], len(d["warnings"]), [w.split(":")[0] for w in d["warnings"]]]')" = '[1, 2, ["w.md", "mid.md"]]' ]; } \
  && ok "S20-IF-E3 --json: warnings holds the L1 warning then the size warning, l1_warnings stays 1" \
  || bad "S20-IF-E3 L1 and size warnings together" "rc=$rc l1=$(jget 'd["l1_warnings"]') warnings=$(jget 'd["warnings"]')"

# S20-IF-N2: golden compare. A size block that nothing exceeds leaves the --json report identical to the same bundle
# without the block, except for the sizes key the block adds (okf-knowledge-gate#17: each note's size, so CI sees the trend).
B="$TMP/if-n2"; mkb "$B"; mknote "$B/n.md" 10
runjson "$B" >/dev/null; cp "$TMP/out.json" "$TMP/if-n2.before"
printf '%s\n' "$(size_cfg 100 50)" >> "$B/okf-base.yaml"
rc=$(runjson "$B")
"$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.pop("sizes"), list); open(sys.argv[1], "w").write(json.dumps(d) + "\n")' "$TMP/out.json" \
  && "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[1], "w").write(json.dumps(d) + "\n")' "$TMP/if-n2.before"
{ [ "$rc" = 0 ] && cmp -s "$TMP/if-n2.before" "$TMP/out.json"; } \
  && ok "S20-IF-N2 a size block nothing exceeds changes the --json report only by its sizes key" \
  || bad "S20-IF-N2 golden compare" "rc=$rc $(diff "$TMP/if-n2.before" "$TMP/out.json" | head -3 | tr '\n' '|')"

section "S20-IF misplaced okf_check keys"
# S20-IF-H3: a size block at the top level of okf-base.yaml (outside okf_check:) is ignored by every tool. The text
# report says so in a WARN line naming the key and where it belongs, the summary counts it, and the exit code stays 0.
adv() { sed -n 's/.*but \([0-9][0-9]*\) advisory(ies) and.*/\1/p' "$TMP/out.txt"; }
B0="$TMP/if-h3-base"; mkb "$B0"; mknote "$B0/big.md" 60; run "$B0" >/dev/null; base=$(adv)
B="$TMP/if-h3"; mkb "$B" $'size:\n  max_body_chars: 5'; mknote "$B/big.md" 60
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -Fq 'Config           WARN   `size` is at the top level of okf-base.yaml, outside okf_check:; okf-check reads `size` only inside okf_check: move it to okf_check.size' "$TMP/out.txt" \
  && ! grep -Fq 'every tool' "$TMP/out.txt" && [ "$(adv)" = "$((base + 1))" ]; } \
  && ok "S20-IF-H3 a size block outside okf_check gives a WARN line naming the key and where it belongs (exit 0, one more advisory)" \
  || bad "S20-IF-H3 misplaced size block" "rc=$rc base=$base $(grep -n 'Config\|Size\|PASS' "$TMP/out.txt" | head -4 | tr '\n' '|')"

# S20-IF-H4: the same finding in --json: misplaced_keys names the key and where it belongs.
rc=$(runjson "$B")
{ [ "$rc" = 0 ] && [ "$(jget 'd["misplaced_keys"]')" = '[{"belongs": "okf_check.size", "key": "size"}]' ]; } \
  && ok "S20-IF-H4 --json: misplaced_keys lists the key and okf_check.size as its place (exit 0)" \
  || bad "S20-IF-H4 misplaced_keys in json" "rc=$rc keys=$(jget 'sorted(d)')"

# S20-IF-E4: two misplaced keys give two WARN lines and two entries, in the order of the file; a key under okf_check
# in the same file is not reported.
B="$TMP/if-e4"; mkb "$B" $'require_owner: true\nsize:\n  max_body_chars: 5\nokf_check:\n  edit_hook: true'
rc=$(runjson "$B"); got=$(jget '[m["key"] for m in d["misplaced_keys"]]')
run "$B" >/dev/null
{ [ "$rc" = 0 ] && [ "$got" = '["require_owner", "size"]' ] && [ "$(grep -c 'Config           WARN' "$TMP/out.txt")" = 2 ]; } \
  && ok "S20-IF-E4 two misplaced keys: two WARN lines and two entries in file order; edit_hook under okf_check is not reported" \
  || bad "S20-IF-E4 two misplaced keys" "rc=$rc keys=$got $(grep -c 'Config           WARN' "$TMP/out.txt")"

# S20-IF-N3: golden compare. The same key under okf_check, and top-level keys nobody owns, leave --json byte-identical
# to the bundle without them: no misplaced_keys key, no WARN line.
B="$TMP/if-n3"; mkb "$B"; mknote "$B/n.md" 10
runjson "$B" >/dev/null; cp "$TMP/out.json" "$TMP/if-n3.before"
printf 'colour: red\nokf_check:\n  size:\n    max_body_chars: 100\n' >> "$B/okf-base.yaml"
rc=$(runjson "$B"); run "$B" >/dev/null
# sizes[] (okf-knowledge-gate#17) is the size option's own report, present whenever the option is on; it is not a
# misplaced-key finding, so it is taken out before the compare.
"$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("sizes", None); open(sys.argv[1], "w").write(json.dumps(d) + "\n")' "$TMP/out.json"
"$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[1], "w").write(json.dumps(d) + "\n")' "$TMP/if-n3.before"
{ [ "$rc" = 0 ] && cmp -s "$TMP/if-n3.before" "$TMP/out.json" && ! grep -q 'Config  *WARN' "$TMP/out.txt"; } \
  && ok "S20-IF-N3 size under okf_check and an unrelated top-level key are not misplaced (--json byte-identical, no WARN)" \
  || bad "S20-IF-N3 correct placement" "rc=$rc $(diff "$TMP/if-n3.before" "$TMP/out.json" | head -3 | tr '\n' '|')"

# S20-IF-E5: a broken okf_check block is still the Config line's exit 2; a misplaced key beside it does not change that.
B="$TMP/if-e5"; mkb "$B" $'size:\n  max_body_chars: 5\nokf_check:\n  colour: red'
rc=$(run "$B")
{ [ "$rc" = 2 ] && grep -Fq 'Config           COULD NOT RUN' "$TMP/out.txt" && ! grep -Fq 'Config           WARN' "$TMP/out.txt"; } \
  && ok "S20-IF-E5 a broken okf_check block beside a misplaced key is exit 2 (could not run) and prints no misplaced-key WARN" \
  || bad "S20-IF-E5 precedence" "rc=$rc $(grep -n 'Config' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S20-IF-E6: the key is at the top level AND inside okf_check. The option is on (the copy inside is read), so the
# line says the top-level copy is a duplicate to delete, not a key to move; a key that is only misplaced still says move.
B="$TMP/if-e6"; mkb "$B" $'size:\n  max_body_chars: 5\nrequire_owner: true\nokf_check:\n  size:\n    max_body_chars: 100'; mknote "$B/n.md" 10
rc=$(run "$B"); rcj=$(runjson "$B"); got=$(jget '[m["key"] for m in d["misplaced_keys"]]')
{ [ "$rc" = 0 ] && grep -Fq 'Config           WARN   `size` is at the top level of okf-base.yaml and also inside okf_check:; okf-check reads `size` only inside okf_check: delete the top-level copy' "$TMP/out.txt" \
  && grep -Fq 'Config           WARN   `require_owner` is at the top level of okf-base.yaml, outside okf_check:; okf-check reads `require_owner` only inside okf_check: move it to okf_check.require_owner' "$TMP/out.txt" \
  && [ "$got" = '["size", "require_owner"]' ]; } \
  && ok "S20-IF-E6 a key present inside okf_check too is a duplicate to delete; a key only at the top level is still one to move" \
  || bad "S20-IF-E6 duplicate key" "rc=$rc keys=$got $(grep -n 'Config' "$TMP/out.txt" | head -3 | tr '\n' '|')"

section "S16-SB rest: exclude globs and per-note sizes (okf-knowledge-gate#17)"
# S16-SB-X1: okf_check.size.exclude lists globs (the .okfignore syntax) whose notes are not measured. A generated note
# over the maximum is not an error when its folder is excluded; the Size line says how many notes were left out.
B="$TMP/x1"; mkb "$B" "$(size_cfg 100)"$'\n    exclude: ["generated/**"]'; mknote "$B/generated/reg.md" 500; mknote "$B/n.md" 10
rc=$(run "$B")
{ [ "$rc" = 0 ] && ! grep -q 'reg.md: body is' "$TMP/out.txt" && grep -Eq 'Size +PASS .*1 excluded by okf_check.size.exclude' "$TMP/out.txt"; } \
  && ok "S16-SB-X1 a note under an excluded glob is not measured; the Size line counts it as excluded (exit 0)" \
  || bad "S16-SB-X1 exclude" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-X2: a glob that does not cover the note leaves it measured: the error stays.
B="$TMP/x2"; mkb "$B" "$(size_cfg 100)"$'\n    exclude: ["generated/**"]'; mknote "$B/notes/big.md" 500
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -Fq 'notes/big.md: body is 500 characters, above okf_check.size.max_body_chars 100' "$TMP/out.txt"; } \
  && ok "S16-SB-X2 a note outside every excluded glob is still measured (exit 1)" \
  || bad "S16-SB-X2 exclude miss" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S16-SB-X3: the same matcher as .okfignore and owners: "**/x.md" matches at any depth, the root included, and a bare name
# such as "log.md" matches at any depth too, as in .gitignore.
B="$TMP/x3"; mkb "$B" "$(size_cfg 100)"$'\n    exclude: ["**/huge.md", "log.md"]'; mknote "$B/a/b/huge.md" 500; mknote "$B/huge.md" 500
"$REALPY" -c 'import sys; open(sys.argv[1], "a").write("x" * 300 + "\n")' "$B/log.md"; mknote "$B/a/log.md" 500
rc=$(run "$B")
{ [ "$rc" = 0 ] && ! grep -q 'body is' "$TMP/out.txt" && grep -Eq 'Size +PASS .*4 excluded' "$TMP/out.txt"; } \
  && ok "S16-SB-X3 exclude globs follow the .okfignore matcher (**/ at any depth, the root included; a bare name at any depth, as in .gitignore)" \
  || bad "S16-SB-X3 matcher" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -4 | tr '\n' '|')"

# S16-SB-X4: a malformed exclude is the Config line's exit 2 naming the key, in okf-check and in okf-verify --check-config:
# not a list, an item that is not a non-empty string, and a negated item ("!x", which the matcher cannot honour).
for v in '"generated/**"' '[3]' '[""]' '["!keep.md"]'; do
  B="$TMP/x4"; rm -rf "$B"; mkb "$B" "$(size_cfg 100)"$'\n'"    exclude: $v"; mknote "$B/n.md" 10
  rc=$(run "$B"); "$HERE/okf-verify" "$B" --check-config >"$TMP/x4v.txt" 2>&1; rcv=$?
  { [ "$rc" = 2 ] && grep -Fq 'okf_check.size.exclude' "$TMP/out.txt" && [ "$rcv" = 2 ] && grep -Fq 'okf_check.size.exclude' "$TMP/x4v.txt"; } \
    && ok "S16-SB-X4 exclude: $v is refused by both tools (exit 2, names okf_check.size.exclude)" \
    || bad "S16-SB-X4 exclude: $v" "rc=$rc rcv=$rcv $(grep -n 'Config\|exclude' "$TMP/out.txt" "$TMP/x4v.txt" | head -3 | tr '\n' '|')"
done
grep -Fq 'negation' "$TMP/x4v.txt" && ok "S16-SB-X4b a negated exclude item is refused as negation, not as a bad string" \
  || bad "S16-SB-X4b negation message" "$(cat "$TMP/x4v.txt" | head -2)"

# S16-SB-X5: spaces around a pattern are dropped, as .okfignore drops them from each line (0.9.33 review, finding 2); a pattern
# holding a tab or a line break cannot be a path and is refused (exit 2), never dropped in silence (finding 3).
B="$TMP/x5"; mkb "$B" "$(size_cfg 100)"$'\n    exclude: ["  other/**  "]'; mknote "$B/other/y.md" 500
rc=$(run "$B")
{ [ "$rc" = 0 ] && ! grep -q 'y.md: body is' "$TMP/out.txt" && grep -Eq '1 excluded' "$TMP/out.txt"; } \
  && ok "S16-SB-X5 a pattern padded with spaces matches as .okfignore would" || bad "S16-SB-X5 trim" "rc=$rc $(grep -n 'Size\|body is' "$TMP/out.txt" | head -2 | tr '\n' '|')"
B="$TMP/x5b"; mkb "$B" "$(size_cfg 100)"$'\n    exclude: ["a\\tb/**"]'; mknote "$B/n.md" 10
rc=$(run "$B"); "$HERE/okf-verify" "$B" --check-config >"$TMP/x5v.txt" 2>&1; rcv=$?
{ [ "$rc" = 2 ] && [ "$rcv" = 2 ] && grep -q 'tab or a line break' "$TMP/x5v.txt"; } \
  && ok "S16-SB-X5b a pattern holding a tab is refused by both tools (exit 2)" || bad "S16-SB-X5b tab" "rc=$rc rcv=$rcv $(head -1 "$TMP/x5v.txt")"

# S16-SB-J1: --json sizes[] lists every measured note with its body size and both limits (null when a limit is not set),
# sorted by path; an excluded note is not in it.
B="$TMP/j1"; mkb "$B" "$(size_cfg 100)"$'\n    exclude: ["generated/**"]'; mknote "$B/generated/reg.md" 500; mknote "$B/n.md" 10
rc=$(runjson "$B"); got=$(jget '[(s["note"], s["body_chars"], s["max_body_chars"], s["warn_body_chars"]) for s in d["sizes"] if s["note"] == "n.md"]')
notes=$(jget '[s["note"] for s in d["sizes"]]')
{ [ "$rc" = 0 ] && [ "$got" = '[["n.md", 10, 100, null]]' ] && ! printf '%s' "$notes" | grep -q 'generated' \
  && printf '%s' "$notes" | grep -q '"index.md"'; } \
  && ok "S16-SB-J1 --json sizes[] gives each measured note its body size and the limits; excluded notes are absent" \
  || bad "S16-SB-J1 sizes[]" "rc=$rc got=$got notes=$notes"

# S16-SB-J2: without the size option there is no sizes key: --json is unchanged for every bundle that does not opt in.
B="$TMP/j2"; mkb "$B"; mknote "$B/n.md" 10
rc=$(runjson "$B"); has=$(jget '"sizes" in d')
{ [ "$rc" = 0 ] && [ "$has" = false ]; } && ok "S16-SB-J2 no size option, no sizes key in --json" || bad "S16-SB-J2 sizes absent" "rc=$rc has=$has"

# S36-ON-SZ: notes named with a space, an ESC byte and a byte that is not UTF-8 are each measured: Size lists all three
# in the text and in --json sizes[] and errors[], under the C locale and a UTF-8 one (a name decoded with errors="replace"
# no longer matched the file, so the note was skipped and Size passed over it: 0.9.40). The byte shows as \xff in both. A
# disk that refuses the name (APFS) skips the case.
U8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
B="$TMP/on-sz"; mkb "$B" "$(size_cfg 100)"
for n in 'a b' "e$(printf '\033')x" "n$(printf '\377')u"; do
  { printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n'; head -c 300 /dev/zero | tr '\0' x; } 2>/dev/null > "$B/$n.md"
done
if [ "$(find "$B" -name '*.md' | wc -l | tr -d ' ')" -ne 6 ]; then
  skip "S36-ON-SZ this disk refuses a note name that is not UTF-8 (run on Linux)"
elif [ -z "$U8" ]; then
  skip "S36-ON-SZ no UTF-8 locale here (locale -a lists neither C.UTF-8 nor en_US.UTF-8)"
else
  for LOC in C "$U8"; do
    export LC_ALL="$LOC"
    rc=$(run "$B"); nt=$(LC_ALL=C grep -a -c 'body is 300 characters' "$TMP/out.txt"); sz=$(LC_ALL=C grep -a -c 'Size  *FAIL  *3 note(s) over' "$TMP/out.txt")
    rcj=$(runjson "$B"); got=$(jget '[s["note"] for s in d["sizes"] if s["body_chars"] == 300]'); ne=$(jget 'len([e for e in d["errors"] if "body is 300" in e])')
    unset LC_ALL
    { [ "$rc" = 1 ] && [ "$rcj" = 1 ] && [ "$nt" = 3 ] && [ "$sz" = 1 ] && [ "$ne" = 3 ] \
      && [ "$got" = '["a b.md", "e\\x1bx.md", "n\\xffu.md"]' ]; } \
      && ok "S36-ON-SZ under LC_ALL=$LOC Size measures all three odd-named notes: 3 lines in the text, sizes[] and errors[] (exit 1)" \
      || bad "S36-ON-SZ odd names under $LOC" "rc=$rc/$rcj text=$nt size-line=$sz errors[]=$ne sizes[]=$got"
  done
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
