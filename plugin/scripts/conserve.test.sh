#!/usr/bin/env bash
# Tests for the conservation check, `okf-check <bundle> --conserve <ref>` (public okf-knowledge-gate #16; cases S23-CS-* in
# docs/0.9.x-cases.md; spec row CS-1).
#
# A change that reorganises notes (a split, a section moved to a companion note, a merge) should keep every line. Each line
# removed since <ref> must reappear somewhere in the bundle (MOVED); a removed line with a new line at the same place is an
# edit (CHANGED, shown old -> new); one that is nowhere and replaced by nothing is LOST. The report is advisory (exit 0);
# --fail-lost makes a LOST line exit 1. Intended deletions are declared (--deleted FILE, or an `OKF-Deleted: <note>` trailer).
#
# bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"

gitc() { git -C "$1" -c user.name=t -c user.email=t@e -c commit.gpgsign=false "${@:2}"; }
# note <file> <body lines...>: a conformant note whose body is the given lines.
note() {
  f=$1; shift; mkdir -p "$(dirname "$f")"
  printf -- '---\ntype: Lesson\ntitle: T %s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n' "$f" > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
# repo <dir>: a bundle in its own git repository with one committed note a.md of six body lines.
repo() { mkbundle "$1"; note "$1/a.md" "Alpha line one." "Beta line two." "Gamma line three." "Delta line four." "Epsilon line five." "Zeta line six."; git init -q "$1"; gitc "$1" add -A; gitc "$1" commit -qm base; }
run() { local b="$1"; shift; "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
runjson() { local b="$1"; shift; "$CHECK" --json "$b" "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1]))["conserve"]; print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }

section "happy"
# S23-CS-H1: the reporter's move. Three lines leave a.md for a companion note: every removed line is MOVED, nothing LOST.
B="$TMP/h1"; repo "$B"; note "$B/a.md" "Alpha line one." "Beta line two." "Gamma line three."; note "$B/a-more.md" "Delta line four." "Epsilon line five." "Zeta line six."
rc=$(run "$B" --conserve HEAD)
{ [ "$rc" = 0 ] && grep -Eq 'Conserve +PASS +3 line\(s\) removed: 3 MOVED, 0 CHANGED, 0 LOST, 0 declared' "$TMP/out.txt"; } \
  && ok "S23-CS-H1 lines moved to a companion note are MOVED; nothing LOST (exit 0)" || bad "S23-CS-H1 moved" "rc=$rc $(grep -n 'Conserve\|LOST' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S23-CS-H2: the reporter's truncation. Three lines are cut and appear nowhere: LOST, each with its note and old line number;
# the report is advisory, exit 0.
B="$TMP/h2"; repo "$B"; note "$B/a.md" "Alpha line one." "Beta line two." "Gamma line three."
rc=$(run "$B" --conserve HEAD)
{ [ "$rc" = 0 ] && grep -Eq 'Conserve +WARN +3 line\(s\) removed: 0 MOVED, 0 CHANGED, 3 LOST' "$TMP/out.txt" \
  && grep -Fq 'LOST     a.md:16  Delta line four.' "$TMP/out.txt" && grep -Fq 'LOST     a.md:18  Zeta line six.' "$TMP/out.txt"; } \
  && ok "S23-CS-H2 cut lines that are nowhere are LOST with note and old line number; advisory exit 0" || bad "S23-CS-H2 lost" "rc=$rc $(grep -n 'Conserve\|LOST' "$TMP/out.txt" | head -4 | tr '\n' '|')"

# S23-CS-H3: --fail-lost makes a LOST line exit 1; with nothing lost it stays 0.
rc=$(run "$B" --conserve HEAD --fail-lost); B1="$TMP/h1"; rc1=$(run "$B1" --conserve HEAD --fail-lost)
{ [ "$rc" = 1 ] && [ "$rc1" = 0 ]; } && ok "S23-CS-H3 --fail-lost exits 1 on a LOST line and 0 when everything moved" || bad "S23-CS-H3 fail-lost" "rc=$rc rc_moved=$rc1"

# S23-CS-H4: a line edited in place (a fixed typo) is CHANGED and shown old -> new; it is not LOST, so --fail-lost passes.
B="$TMP/h4"; repo "$B"; note "$B/a.md" "Alpha line one." "Beta line too." "Gamma line three." "Delta line four." "Epsilon line five." "Zeta line six."
rc=$(run "$B" --conserve HEAD --fail-lost)
{ [ "$rc" = 0 ] && grep -Eq '0 MOVED, 1 CHANGED, 0 LOST' "$TMP/out.txt" && grep -Fq 'CHANGED  a.md:14  Beta line two.  ->  Beta line too.' "$TMP/out.txt"; } \
  && ok "S23-CS-H4 a line edited in place is CHANGED, shown old -> new, and does not fail --fail-lost" || bad "S23-CS-H4 changed" "rc=$rc $(grep -n 'Conserve\|CHANGED' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S23-CS-H5: compression. Four lines become one shorter line: one CHANGED (paired by position), three LOST.
B="$TMP/h5"; repo "$B"; note "$B/a.md" "Alpha line one." "Beta, gamma, delta, epsilon in short." "Zeta line six."
rc=$(run "$B" --conserve HEAD --fail-lost)
{ [ "$rc" = 1 ] && grep -Eq '0 MOVED, 1 CHANGED, 3 LOST' "$TMP/out.txt"; } \
  && ok "S23-CS-H5 four lines compressed into one: one CHANGED, three LOST (--fail-lost exit 1)" || bad "S23-CS-H5 compression" "rc=$rc $(grep -n 'Conserve' "$TMP/out.txt" | head -2)"

section "negative"
# S23-CS-N1: what is not knowledge is not counted: blank lines, whitespace-only changes, markup-only lines (a table rule, a fence)
# and the frontmatter (a new date is churn, not content).
B="$TMP/n1"; mkbundle "$B"; note "$B/a.md" "Alpha line one." "" "|---|---|" '```' "Beta  line two." '```'; git init -q "$B"; gitc "$B" add -A; gitc "$B" commit -qm base
note "$B/a.md" "Alpha line one." "Beta line two."; sed -i.bak 's/2026-01-01/2026-02-02/' "$B/a.md"; rm -f "$B/a.md.bak"
rc=$(run "$B" --conserve HEAD --fail-lost)
{ [ "$rc" = 0 ] && grep -Eq 'Conserve +PASS +0 line\(s\) removed' "$TMP/out.txt"; } \
  && ok "S23-CS-N1 blank, whitespace-only, markup-only and frontmatter changes are not counted" || bad "S23-CS-N1 noise" "rc=$rc $(grep -n 'Conserve\|LOST\|CHANGED' "$TMP/out.txt" | head -4 | tr '\n' '|')"

# S23-CS-N2: --conserve needs a ref, a git repository and a commit: 64 without a ref, 2 otherwise, one line each.
B="$TMP/n2"; mkbundle "$B"
rc=$(run "$B" --conserve); rc2=$(run "$B" --conserve HEAD); m2=$(grep -c 'inside a git repository' "$TMP/out.txt")
B3="$TMP/n2b"; repo "$B3"; rc3=$(run "$B3" --conserve no-such-ref)
{ [ "$rc" = 64 ] && [ "$rc2" = 2 ] && [ "$m2" = 1 ] && [ "$rc3" = 2 ] && grep -q 'no-such-ref' "$TMP/out.txt"; } \
  && ok "S23-CS-N2 no ref is exit 64; no repository or an unknown ref is exit 2 with one line" || bad "S23-CS-N2 usage" "rc=$rc rc2=$rc2 m2=$m2 rc3=$rc3"

section "edge"
# S23-CS-E1: a deleted note's lines are LOST unless they reappear; a new untracked note counts as where they went.
B="$TMP/e1"; repo "$B"; rm "$B/a.md"; note "$B/new.md" "Alpha line one." "Beta line two." "Gamma line three." "Delta line four." "Epsilon line five."
rc=$(run "$B" --conserve HEAD)
{ [ "$rc" = 0 ] && grep -Eq '6 line\(s\) removed: 5 MOVED, 0 CHANGED, 1 LOST' "$TMP/out.txt" && grep -Fq 'LOST     a.md:18  Zeta line six.' "$TMP/out.txt"; } \
  && ok "S23-CS-E1 a deleted note's lines found in an untracked note are MOVED; the rest LOST" || bad "S23-CS-E1 deleted note" "rc=$rc $(grep -n 'Conserve\|LOST' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S23-CS-E2: intended deletions are declared, not guessed: --deleted FILE names a note (all its removed lines) or one line.
B="$TMP/e2"; repo "$B"; note "$B/a.md" "Alpha line one." "Beta line two." "Gamma line three."
printf '# deliberately cut\nline: Delta line four.\n' > "$TMP/e2.del"
rc=$(run "$B" --conserve HEAD --fail-lost --deleted "$TMP/e2.del")
printf 'a.md\n' > "$TMP/e2b.del"; rc2=$(run "$B" --conserve HEAD --fail-lost --deleted "$TMP/e2b.del")
{ [ "$rc" = 1 ] && [ "$rc2" = 0 ] && grep -Eq '0 LOST, 3 declared' "$TMP/out.txt"; } \
  && ok "S23-CS-E2 --deleted declares one line (two left LOST, exit 1) or a whole note (0 LOST, exit 0)" || bad "S23-CS-E2 declared file" "rc=$rc rc2=$rc2 $(grep 'Conserve' "$TMP/out.txt")"

# S23-CS-E3: an `OKF-Deleted: <note>` trailer in a commit since the ref declares that note's removed lines.
B="$TMP/e3"; repo "$B"; note "$B/a.md" "Alpha line one."; gitc "$B" add -A; gitc "$B" commit -qm $'trim a.md\n\nOKF-Deleted: a.md'
rc=$(run "$B" --conserve HEAD~1 --fail-lost)
{ [ "$rc" = 0 ] && grep -Eq '5 line\(s\) removed: 0 MOVED, 0 CHANGED, 0 LOST, 5 declared' "$TMP/out.txt"; } \
  && ok "S23-CS-E3 an OKF-Deleted trailer since the ref declares a note's cut lines" || bad "S23-CS-E3 trailer" "rc=$rc $(grep 'Conserve' "$TMP/out.txt")"

# S23-CS-E4: a bundle inside a larger repository: changes outside the bundle are not read; a line moved within the same note
# (a reorder) is MOVED.
R="$TMP/e4"; mkdir -p "$R"; git init -q "$R"; repo_b="$R/kb"; mkbundle "$repo_b"; note "$repo_b/a.md" "One fact." "Two fact."; printf 'x\ny\n' > "$R/outside.txt"
gitc "$R" add -A; gitc "$R" commit -qm base; note "$repo_b/a.md" "Two fact." "One fact."; printf 'x\n' > "$R/outside.txt"
rc=$(run "$repo_b" --conserve HEAD --fail-lost)
{ [ "$rc" = 0 ] && grep -Eq 'Conserve +PASS' "$TMP/out.txt" && ! grep -q 'outside' "$TMP/out.txt"; } \
  && ok "S23-CS-E4 a reorder inside a note is MOVED, and files outside the bundle are not read" || bad "S23-CS-E4 subfolder" "rc=$rc $(grep -n 'Conserve\|LOST\|CHANGED' "$TMP/out.txt" | head -3 | tr '\n' '|')"

# S23-CS-E5: --json gives the counts and every entry with note, line and text (CHANGED with its new text).
B="$TMP/h5"; rc=$(runjson "$B" --conserve HEAD)
got=$(jget '[d["removed"], len(d["moved"]), len(d["changed"]), len(d["lost"]), d["changed"][0]["new"], d["lost"][0]["note"], d["lost"][0]["line"]]')
{ [ "$rc" = 0 ] && [ "$got" = '[4, 0, 1, 3, "Beta, gamma, delta, epsilon in short.", "a.md", 15]' ]; } \
  && ok "S23-CS-E5 --json conserve{} holds the counts and each entry with note, line, text and the new text of a change" || bad "S23-CS-E5 json" "rc=$rc got=$got"

# S23-CS-E6 (review S1, S2): the diff is read whatever the names and the user's git config: a note whose name has a space,
# one whose name is not ASCII, a removed body line that starts with "-- ", and diff.mnemonicPrefix / diff.noprefix set.
B="$TMP/e6"; mkbundle "$B"; note "$B/my note.md" "Space one." "Space two."; note "$B/café.md" "Accent one." "Accent two."; note "$B/sig.md" "Body." "-- Signed alice" "After the signature."
git init -q "$B"; gitc "$B" add -A; gitc "$B" commit -qm base
note "$B/my note.md" "Space one."; note "$B/café.md" "Accent one."; note "$B/sig.md" "Body."
git -C "$B" config diff.mnemonicPrefix true
rc=$(run "$B" --conserve HEAD); git -C "$B" config diff.noprefix true; rc2=$(run "$B" --conserve HEAD)
{ [ "$rc" = 0 ] && [ "$rc2" = 0 ] && grep -Eq '4 line\(s\) removed: 0 MOVED, 0 CHANGED, 4 LOST' "$TMP/out.txt" \
  && grep -Fq 'LOST     my note.md:14  Space two.' "$TMP/out.txt" && grep -Fq 'LOST     café.md:14  Accent two.' "$TMP/out.txt" \
  && grep -Fq 'LOST     sig.md:14  -- Signed alice' "$TMP/out.txt" && grep -Fq 'LOST     sig.md:15  After the signature.' "$TMP/out.txt"; } \
  && ok "S23-CS-E6 names with a space or an accent, a '-- ' body line and diff prefix settings are all read" || bad "S23-CS-E6 parsing" "rc=$rc rc2=$rc2 $(grep -n 'Conserve\|LOST' "$TMP/out.txt" | head -6 | tr '\n' '|')"

# S23-CS-E7 (review S3): only notes are compared: a line removed from okf-base.yaml or a data file is not LOST.
B="$TMP/e7"; repo "$B"; printf 'a: 1\nb: 2\n' > "$B/data.json"; gitc "$B" add -A; gitc "$B" commit -qm data; printf 'a: 1\n' > "$B/data.json"
rc=$(run "$B" --conserve HEAD --fail-lost)
{ [ "$rc" = 0 ] && grep -Eq 'Conserve +PASS +0 line\(s\) removed' "$TMP/out.txt"; } && ok "S23-CS-E7 a line removed from a file that is not a note is not counted" || bad "S23-CS-E7 non-notes" "rc=$rc $(grep 'Conserve\|LOST' "$TMP/out.txt" | head -2)"

# S23-CS-E8 (nit): `OKF-Deleted:` counts only as a trailer, at the end of the message, not in the middle of its body.
B="$TMP/e8"; repo "$B"; note "$B/a.md" "Alpha line one."; gitc "$B" add -A; gitc "$B" commit -qm $'trim\n\nOKF-Deleted: a.md\n\nThe line above was a proposal, then dropped.\n\nSigned-off-by: t'
rc=$(run "$B" --conserve HEAD~1)
grep -Eq '0 declared' "$TMP/out.txt" && ok "S23-CS-E8 OKF-Deleted in the body of a message is not a declaration" || bad "S23-CS-E8 trailer only" "rc=$rc $(grep Conserve "$TMP/out.txt")"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
