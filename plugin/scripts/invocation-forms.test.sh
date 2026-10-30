#!/usr/bin/env bash
# Invocation-forms suite: the same known-bad input through every documented way of calling the tools, each
# compared with a LITERAL exit code (and, where the verdict is text, a literal printed line).
#
# Why: the layers have tests one by one, but nothing ran the SAME input through different command lines. The 0.9.55
# audit did: two probe sets, 111 invocations of the documented forms, 18 answers that differed from the closest form
# beside them — and the ones that matter here are the PASSes where a FAIL was due. This suite is that audit kept as a
# test, so the same input cannot go back to answering two ways.
#
# Seams (agreed in the release plan for 0.9.56):
#   1. the command line of okf-check — arguments in, exit code and printed lines out;
#   2. the command line of okf-verify — the same;
#   3. the Action: its own run block, driven the way a CI step drives it (INPUT_* environment, bash -e -o pipefail).
# No case reaches inside a function, and no expected value is recomputed from the code under test: an exit code is a
# literal from the spec or from the 0.9.55 audit's own output, and a printed-line assertion matches text a reader sees.
#
# Known gaps: a form that is still wrong on this release is listed in plugin/tests/invocation-forms-known-gaps.tsv,
# one line per case key: <key> TAB <reason: what this form answers now> TAB <slug of the slice that fixes it> TAB
# <the wrong exit code it gives today>. Rules, all enforced at the end of this file:
#   - a listed case that FAILS prints KNOWN GAP and is not a failure (the release ships with these open);
#   - a listed case that PASSES fails the run ("unexpected pass": the line is stale, and it would hide that the slice
#     that fixes it has landed);
#   - a listed case that fails with ANOTHER exit code than its line records fails the run ("a different failure"): a
#     crash, a missing tool or a refused argument must not hide behind a known gap;
#   - a line whose key no case runs fails the run: the file and the suite must name the same cases;
#   - the case lines are sorted, so two slices never edit the same line and a merge conflict names who collided.
#
# Run: bash plugin/scripts/invocation-forms.test.sh   (from any directory; own temp HOME, no host git config)
set -uo pipefail
unset CDPATH

HERE=$(cd -P "$(dirname "$0")" && pwd)
TREE=$(cd -P "$HERE/../.." && pwd)
. "$HERE/../tests/okf-test-lib.sh"

CHECK="$HERE/okf-check"
VERIFY="$HERE/okf-verify"
GAPS="$HERE/../tests/invocation-forms-known-gaps.tsv"
export PATH="$HERE:$PATH"
# A temp HOME and no system git config: a fixture's git must never read (or write) the host's credential store, and
# git -c credential.helper= is on every call in this file for the same reason.
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
g() { git -c credential.helper= "$@"; }

W="$TMP/work"; mkdir -p "$W"
OUT="$TMP/out.txt"
RC=0

# run_in <dir> <command...>: run it there, keep its output in $OUT and its exit code in $RC.
run_in() {
  local d="$1"; shift
  ( cd "$d" && "$@" ) > "$OUT" 2>&1
  RC=$?
}
# shown: the first lines of $OUT, for a failure message.
shown() { head -2 "$OUT" 2>/dev/null | tr '\n' ' '; }

# --- known gaps ------------------------------------------------------------------------------------------------
EXERCISED="$TMP/exercised.txt"; : > "$EXERCISED"
in_gaps() { [ -f "$GAPS" ] && awk -F'\t' -v k="$1" '$1 == k { found = 1 } END { exit !found }' "$GAPS"; }
gap_field() { awk -F'\t' -v k="$1" -v f="$2" '$1 == k { print $f; exit }' "$GAPS" 2>/dev/null; }

# verdict <case key> <1 the form gave the right verdict | 0 it did not> <what was expected and what happened> <the exit
#         code this case observed>
# A known gap absorbs ONE failure: the exit code its line records. A crash (127), a refused argument (64) or any other
# code is a different failure and fails the run — otherwise a broken fixture would sit under "known gap" for a release.
verdict() {
  local key="$1" pass="$2" why="$3" seen="${4:-none}" listed
  printf '%s\n' "$key" >> "$EXERCISED"
  if in_gaps "$key"; then
    listed=$(gap_field "$key" 4)
    if [ "$pass" -eq 1 ]; then
      bad "$key — UNEXPECTED PASS: the form now gives the right verdict, but this key is listed as a known gap" \
          "remove its line ($(gap_field "$key" 2)) from plugin/tests/invocation-forms-known-gaps.tsv: the slice that fixes it has landed"
    elif [ -n "$listed" ] && [ "$listed" != "$seen" ]; then
      bad "$key — A DIFFERENT FAILURE THAN THE LISTED ONE" \
          "the known-gaps line records exit $listed for this form and it now fails with exit $seen, so this is not the defect the slice is fixing: fix the line if the form's answer changed, or the case if the fixture broke"
    else
      printf '  KNOWN GAP  %s — %s  [now: %s]\n' "$key" "$(gap_field "$key" 2)" "$why"
    fi
  elif [ "$pass" -eq 1 ]; then
    ok "$key"
  else
    bad "$key" "$why"
  fi
}
# case_precondition_failed <case key> <why the case could not measure anything> — NOT a skip and NOT a known gap: a
# case whose fixture did not reach the state it measures would pass or fail for the wrong reason, and a skip is the same
# silent hole one level up (the gates install okflint, so a missing layer there is a setup error, not absent coverage).
case_precondition_failed() {
  printf '%s\n' "$1" >> "$EXERCISED"
  bad "$1 — PRECONDITION NOT MET: this case measured nothing" "$2"
}

# --- fixtures --------------------------------------------------------------------------------------------------
# A bundle whose index.md declares no counts: L2's index layer is then SKIPPED for every fixture, so one layer never
# decides a case by accident. (printf -- so a format starting with "---" is not read as an option: macOS /bin/sh.)
mkb() {
  mkdir -p "$1"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$1/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$1/log.md"
}
mk_okf_base() { # <bundle> — a starter house-rules file, so L2's profile layer runs (it needs okflint too)
  "$CHECK" --init-house-rules "$1" > "$OUT" 2>&1
}
mkb_counts() { # <bundle> <number of concepts> — the same skeleton with an index.md that declares its counts, so the
               # index layer runs instead of reporting SKIPPED. A declared count must equal the files on disk.
  mkb "$1"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n**%s concepts**\n' "$2" > "$1/index.md"
}

# One repository holds every bundle that cites a file, because okf-verify resolves citations against a git repo.
REPO="$W/repo"
mkdir -p "$REPO/src"
printf 'one\ntwo\nthree\n' > "$REPO/src/real.py"
g init -q "$REPO"
g -C "$REPO" config user.email t@t
g -C "$REPO" config user.name t
g -C "$REPO" add -A
g -C "$REPO" commit -q -m base
SHA=$(g -C "$REPO" rev-parse HEAD)

# A second repository beside the first, so a case can pass two --repo values and check the whole list the report gives.
OTHER="$W/other"
mkdir -p "$OTHER"
printf 'o\n' > "$OTHER/o.txt"
g init -q "$OTHER"
g -C "$OTHER" config user.email t@t
g -C "$OTHER" config user.name t
g -C "$OTHER" add -A
g -C "$OTHER" commit -q -m base

NOTE_EXPIRED='---
type: Lesson
title: Payment limits
description: Limits for payouts.
status: stable
tags: [payments]
generated:
  by: human:dana
  at: "2026-01-01"
stale_after: "2020-01-01"
---

body
'

# The same note, clean (a human verifier on a stable note an agent did not write).
NOTE_CLEAN='---
type: Lesson
title: Payment limits
description: Limits for payouts.
status: stable
tags: [payments]
generated:
  by: human:dana
  at: "2026-01-01"
verified:
  - by: human:finance-owner
    at: "2026-02-01"
stale_after: "2099-01-01"
---

body
'

# A draft note written by an agent and verified by a human: two Trust findings on one note.
NOTE_TRUST='---
type: Lesson
title: Payment limits
description: Limits for payouts.
status: draft
tags: [payments]
generated:
  by: agent/1
  at: "2026-01-01"
verified:
  - by: human:finance-owner
    at: "2026-02-01"
stale_after: "2099-01-01"
---

body
'

# The byte order mark cases: the same expired note with the mark, without it, and with the mark and CRLF line ends.
mkb "$REPO/B/mark";      printf '\357\273\277%s\n' "$NOTE_EXPIRED" > "$REPO/B/mark/n.md"
mkb "$REPO/B/plain";     printf '%s\n' "$NOTE_EXPIRED" > "$REPO/B/plain/n.md"
mkb "$REPO/B/mark-crlf"; printf '\357\273\277%s\n' "$NOTE_EXPIRED" > "$REPO/B/mark-crlf/n.md"
"$REALPY" -c 'import sys, pathlib; p = pathlib.Path(sys.argv[1]); p.write_bytes(p.read_bytes().replace(b"\n", b"\r\n"))' "$REPO/B/mark-crlf/n.md"
mkb "$REPO/B/mark-fresh"; printf '\357\273\277%s\n' "$NOTE_EXPIRED" > "$REPO/B/mark-fresh/n.md"
sed -e 's/2020-01-01/2099-01-01/' "$REPO/B/mark-fresh/n.md" > "$REPO/B/mark-fresh/n.tmp" && mv "$REPO/B/mark-fresh/n.tmp" "$REPO/B/mark-fresh/n.md"

mkb "$REPO/B/clean"; printf '%s\n' "$NOTE_CLEAN" > "$REPO/B/clean/n.md"
mkb "$REPO/B/trust"; printf '%s\n' "$NOTE_TRUST" > "$REPO/B/trust/n.md"

# An agent note with a human verifier: Trust warns on the whole-bundle run, and --file must agree.
mkb "$REPO/B/agent"
printf '%s\n' '---' 'type: Lesson' 'title: Payment limits' 'description: Limits for payouts.' 'status: stable' \
  'tags: [payments]' 'generated:' '  by: agent/claude-1' '  at: "2026-01-01"' 'verified:' \
  '  - by: human:dana' '    at: "2026-02-01"' 'stale_after: "2099-01-01"' '---' '' 'body' > "$REPO/B/agent/n.md"

# A verified list of bare strings: L1 warns on the shape and Trust reads the claim as its `by` actor. The mapping form
# beside it is the control: same note, same verdict.
mkb "$REPO/B/bare"
printf '%s\n' '---' 'type: Lesson' 'title: Payment limits' 'description: Limits for payouts.' 'status: draft' \
  'tags: [payments]' 'generated:' '  by: agent/1' '  at: "2026-01-01"' 'verified:' '  - human:dana' \
  'stale_after: "2099-01-01"' '---' '' 'body' > "$REPO/B/bare/n.md"
mkb "$REPO/B/mapped"
printf '%s\n' '---' 'type: Lesson' 'title: Payment limits' 'description: Limits for payouts.' 'status: draft' \
  'tags: [payments]' 'generated:' '  by: agent/1' '  at: "2026-01-01"' 'verified:' '  - by: human:dana' \
  '    at: "2026-02-01"' 'stale_after: "2099-01-01"' '---' '' 'body' > "$REPO/B/mapped/n.md"

# A citation of a file at the repository ROOT, on a line that does not hold the quoted text: MOVED, exit 1.
printf 'alpha\nbeta\ngamma\n' > "$REPO/spec.md"
mkb "$REPO/B/root"
printf '%s\n' '---' 'type: Lesson' 'title: Cites' 'description: The cited line moved.' 'status: stable' 'tags: [x]' \
  'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' \
  'See spec.md:1 "gamma" for the rule.' > "$REPO/B/root/n.md"

# A citation that is right: spec.md line 2 holds "beta". The negative case of the --repo spelling group.
mkb "$REPO/B/right"
printf '%s\n' '---' 'type: Lesson' 'title: Cites' 'description: The cited line is where it says.' 'status: stable' 'tags: [x]' \
  'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' \
  'See spec.md:2 "beta" for the rule.' > "$REPO/B/right/n.md"

# A document name that exists twice in one bundle ('s second form): the note's own folder holds one of them. The
# bundle given as `.` must reach the exact-path step that picks it, as the absolute spelling does.
DUP="$REPO/B/dup"
mkdir -p "$DUP/a" "$DUP/b"
printf 'line 1\nline 2\n' > "$DUP/a/d.md"
printf 'other 1\nother 2\n' > "$DUP/b/d.md"
printf '%s\n' '---' 'type: Lesson' 'title: Cites' 'description: Cites a line of the document beside it.' 'status: stable' 'tags: [x]' \
  'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' \
  'See d.md:2 "line 2" for the rule.' > "$DUP/a/n.md"

# A link followed by `..`. The system resolves the link first, so `link/..` is the folder the link points into, while
# taking `..` off the spelling names the folder that holds the link. Both must reach the same verdict: a pinned citation
# into the folder the system names is CONFIRMED.
LNK="$W/lnk"
mkdir -p "$LNK/real/inner" "$LNK/T"
ln -s real/inner "$LNK/link"
printf 'alpha\nbeta\ngamma\n' > "$LNK/real/spec.md"
printf 't\n' > "$LNK/T/t.txt"
for d in "$LNK/real" "$LNK/T"; do
  g init -q "$d"
  g -C "$d" config user.email t@t
  g -C "$d" config user.name t
  g -C "$d" add -A
  g -C "$d" commit -q -m base
done
LNK_SHA=$(g -C "$LNK/real" rev-parse HEAD)
mkb "$LNK/b"
printf '%s\n' '---' 'type: Lesson' 'title: Cites' 'description: Pinned to the folder link/.. names.' 'status: stable' 'tags: [x]' \
  'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' \
  "See spec.md:1 @$LNK_SHA for the rule." > "$LNK/b/n.md"
# A bundle the system reaches through the link: `link/../B3` is `real/B3`, and no collapse of `..` names that folder.
mkdir -p "$LNK/real/B3"
printf 'line 1\nline 2\n' > "$LNK/real/B3/d.md"
printf '%s\n' '---' 'type: Lesson' 'title: Cites' 'description: A line of the note beside it.' 'status: stable' 'tags: [x]' \
  'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' \
  'See d.md:2 "line 2" for the rule.' > "$LNK/real/B3/n.md"

# A citation of a file in the repository that is not there (REFUTED, exit 1 with an absolute --repo).
mkb "$REPO/B/ver"
printf '%s\n' '---' 'type: Lesson' 'title: Cites' 'description: Cites a line that is not there.' 'status: stable' \
  'tags: [x]' 'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' \
  "The tool reads input at src/real.py:99 @$SHA and a file src/missing.py:3 @$SHA." > "$REPO/B/ver/n.md"

# The --conserve group: one repository per form of the same question — did the line survive in the COUNTED bundle?
# mkcons <dir> <what B/.okfignore holds>: a repository with B/a.md holding the line at HEAD, everything committed.
mkcons() {
  mkdir -p "$1"
  g init -q "$1"
  g -C "$1" config user.email t@t
  g -C "$1" config user.name t
  mkb "$1/B"
  printf 'Rule X holds\n' > "$1/B/a.md"
  printf '%s' "${2:-}" > "$1/B/.okfignore"
  g -C "$1" add -A
  g -C "$1" commit -q -m base
}
# The defect: the line moved out of a counted note into a note .okfignore excludes.
CONS="$W/cons"; mkcons "$CONS" 'archive/
'
: > "$CONS/B/a.md"
mkdir -p "$CONS/B/archive"
printf 'Rule X holds\n' > "$CONS/B/archive/b.md"

# The edge: a negated line among the patterns. This .okfignore version does not support negation and says so, and every
# layer skips the line: the note stays excluded, so the moved line is still LOST.
CONS_NEG="$W/cons-neg"; mkcons "$CONS_NEG" 'archive/
!archive/keep.md
'
: > "$CONS_NEG/B/a.md"
mkdir -p "$CONS_NEG/B/archive"
printf 'Rule X holds\n' > "$CONS_NEG/B/archive/keep.md"

# The control: the same line deleted outright, with no ignore file on the way.
CONS_DEL="$W/cons-del"; mkcons "$CONS_DEL" ''
: > "$CONS_DEL/B/a.md"

# The second control: the whole counted note removed from the disk, not just emptied. It is the case the ignore filter
# could break by asking "is this note on the list of counted notes?" — a deleted note is on no listing, so that question
# would answer "not counted" and the loss would vanish.
CONS_FILE_DEL="$W/cons-file-del"; mkcons "$CONS_FILE_DEL" 'archive/
'
rm -f "$CONS_FILE_DEL/B/a.md"

# A line that only ever lived in an ignored note, used three ways: reorganised inside that note's folder, deleted from it,
# and moved out of it into a counted note. The first two changed nothing the bundle counts; the third is a gain.
CONS_IN="$W/cons-in"; mkcons "$CONS_IN" 'archive/
'
: > "$CONS_IN/B/a.md"
mkdir -p "$CONS_IN/B/archive"
printf 'An old rule\n' > "$CONS_IN/B/archive/x.md"
g -C "$CONS_IN" add -A; g -C "$CONS_IN" commit -q -m "an ignored note holds a line"
rm -f "$CONS_IN/B/archive/x.md"
printf 'An old rule\n' > "$CONS_IN/B/archive/y.md"

CONS_IGN_DEL="$W/cons-ign-del"; mkcons "$CONS_IGN_DEL" 'archive/
'
: > "$CONS_IGN_DEL/B/a.md"
mkdir -p "$CONS_IGN_DEL/B/archive"
printf 'An old rule\n' > "$CONS_IGN_DEL/B/archive/x.md"
g -C "$CONS_IGN_DEL" add -A; g -C "$CONS_IGN_DEL" commit -q -m "an ignored note holds a line"
rm -f "$CONS_IGN_DEL/B/archive/x.md"

CONS_OUT="$W/cons-out"; mkcons "$CONS_OUT" 'archive/
'
: > "$CONS_OUT/B/a.md"
mkdir -p "$CONS_OUT/B/archive"
printf 'An old rule\n' > "$CONS_OUT/B/archive/x.md"
# A counted note beside it whose line is deleted: a real loss the report must still name, so a run that compared nothing
# at all (the ignored-everything defect) cannot pass this case.
printf 'Second rule holds\n' > "$CONS_OUT/B/d.md"
g -C "$CONS_OUT" add -A; g -C "$CONS_OUT" commit -q -m "an ignored note holds a line"
rm -f "$CONS_OUT/B/archive/x.md"
printf 'An old rule\n' > "$CONS_OUT/B/c.md"
rm -f "$CONS_OUT/B/d.md"

# .okfignore that leaves no note in at all while notes are still there: the comparison would pass a bundle nobody looked
# at. a.md is deleted and index.md/log.md stay on disk, so the bundle still holds notes.
CONS_ALL="$W/cons-all"; mkcons "$CONS_ALL" '*
'
rm -f "$CONS_ALL/B/a.md"

# A bundle whose ONLY note at the ref has a name git would quote: a non-ASCII name, and one holding a newline. Without
# NUL-separated output (`git ls-tree -z`) git prints `"B/caf\303\251.md"`, which does not end in `.md`, so the note read
# as absent and the report passed a bundle nobody compared. The control has the same shape with a plain name.
mkrefname() {  # <dir> <note name>: a bundle holding exactly one note, with that name, at HEAD; then remove it from the disk
  mkdir -p "$1/B"
  g init -q "$1"
  g -C "$1" config user.email t@t
  g -C "$1" config user.name t
  printf 'A rule\n' > "$1/B/$2"
  g -C "$1" add -A
  g -C "$1" commit -q -m "one note, as its name is spelled"
  printf '*\n' > "$1/B/.okfignore"
  g -C "$1" add -A
  g -C "$1" commit -q -m "ignore everything"
  rm -f "$1/B/"*.md
}
mkrefname "$W/ref-non-ascii" 'café.md'
mkrefname "$W/ref-newline" 'new
line.md'
mkrefname "$W/ref-plain" 'a.md'

# What counts as "a note" for the refusal is the gate's meaning: a *.md that is not index.md or log.md, at any depth. These
# bundles keep index.md and log.md (mkb) and differ in the notes beside them. Each file is committed at HEAD with the
# .okfignore text given; the caller then changes the disk.
mkreffiles() {  # <dir> <.okfignore text> <file relative to the repository root>...: B holds index.md and log.md
  local d="$1" f; local ign="$2"; shift 2
  mkdir -p "$d"
  g init -q "$d"
  g -C "$d" config user.email t@t
  g -C "$d" config user.name t
  mkb "$d/B"
  printf '%s' "$ign" > "$d/B/.okfignore"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf 'A rule\n' > "$d/$f"; done
  g -C "$d" add -A
  g -C "$d" commit -q -m base
}
# index.md and log.md are on the disk, the only counted notes: `concepts/` ignored, the concept note deleted.
mkreffiles "$W/idx-ignored" 'concepts/
' B/concepts/a.md
rm -f "$W/idx-ignored/B/concepts/a.md"
# The control: the same .okfignore, but no concept note was ever held.
mkreffiles "$W/idx-never" 'concepts/
'
# The ref holds an ignored note and a counted one; only the ignored one is still on the disk. The counted note's deletion
# is a plain LOST: the refusal needs EVERY ref note excluded, not one of them.
mkreffiles "$W/ref-mixed" 'archive/
' B/archive/x.md B/a.md
rm -f "$W/ref-mixed/B/a.md"
# A concept note on the disk while the ref holds none (it was added, untracked, with everything ignored).
mkreffiles "$W/disk-only" '*
'
printf 'A rule\n' > "$W/disk-only/B/new.md"
# Notes beside the bundle (a sibling that shares its name prefix, and a folder next to it) are not the bundle's notes.
mkreffiles "$W/ref-sibling" '*
' C/c.md B2/x.md
# Names that only look like notes: another case of the suffix, and a longer suffix.
mkreffiles "$W/ref-lookalike" '*
' B/UPPER.MD B/x.md.bak

# The same .okfignore with EVERY note gone from the disk while the ref still holds them: the report cannot compare, and
# the ref is the side that says content existed.
CONS_ALL_GONE="$W/cons-all-gone"; mkcons "$CONS_ALL_GONE" '*
'
rm -f "$CONS_ALL_GONE/B/"*.md

# Bundles that hold no note at all: there is nothing to conserve and nothing was removed, with and without an .okfignore,
# so the refusal above is about notes that exist and not about an empty folder.
CONS_NONE="$W/cons-none"
mkdir -p "$CONS_NONE/B"
g init -q "$CONS_NONE"
g -C "$CONS_NONE" config user.email t@t
g -C "$CONS_NONE" config user.name t
printf 'a readme, not a note\n' > "$CONS_NONE/B/readme.txt"
printf '*\n' > "$CONS_NONE/B/.okfignore"
g -C "$CONS_NONE" add -A
g -C "$CONS_NONE" commit -q -m base
CONS_NONE_PLAIN="$W/cons-none-plain"
mkdir -p "$CONS_NONE_PLAIN/B"
g init -q "$CONS_NONE_PLAIN"
g -C "$CONS_NONE_PLAIN" config user.email t@t
g -C "$CONS_NONE_PLAIN" config user.name t
printf 'a readme, not a note\n' > "$CONS_NONE_PLAIN/B/readme.txt"
g -C "$CONS_NONE_PLAIN" add -A
g -C "$CONS_NONE_PLAIN" commit -q -m base

# The negative: the line moved into a note the bundle counts. It is still in the bundle, so nothing is lost.
CONS_KEPT="$W/cons-kept"; mkcons "$CONS_KEPT" 'archive/
'
: > "$CONS_KEPT/B/a.md"
printf 'Rule X holds\n' > "$CONS_KEPT/B/c.md"

# The Action's run block, extracted exactly as GitHub reads it: the body of the composite step's bash `run: |`. The
# block's own indent is removed line by line, and the block ends at the first non-blank line indented seven spaces or
# less. An indent is measured with match(), not with an interval expression: older mawk does not support `{0,7}`.
ACTION_RUN="$TMP/action-run.sh"
LC_ALL=C awk '
  function indent(s) { match(s, /^ */); return RLENGTH }
  /^      run: \|/ { inblock = 1; next }
  inblock {
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    if (indent($0) <= 7) { inblock = 0; next }
    print substr($0, 9)
  }' "$TREE/action.yml" > "$ACTION_RUN"
if [ -s "$ACTION_RUN" ] && grep -q 'GITHUB_ACTION_PATH' "$ACTION_RUN"; then
  ok "invocation-forms-action-run-block-extracted-edge-1"
else
  bad "invocation-forms-action-run-block-extracted-edge-1" \
      "the Action's run block could not be read from action.yml (empty, or without GITHUB_ACTION_PATH): every Action case below would measure nothing"
fi
A_LOG="$TMP/action.log"
A_RC=0
# act <dir> <INPUT_*=value...>: run the Action the way a CI step does (the runner starts it with bash -e -o pipefail).
act() {
  local d="$1"; shift
  ( cd "$d" && env INPUT_STRICT_TRUST=false INPUT_FAIL_STALE=false INPUT_REQUIRE_HOUSE_RULES=false \
      INPUT_VERIFY=false INPUT_REPO=. GITHUB_ACTION_PATH="$TREE" "$@" bash -e -o pipefail "$ACTION_RUN" ) > "$A_LOG" 2>&1
  A_RC=$?
}

# --- the byte order mark --------------------------------------------------------------------------------
# An expired note that starts with a UTF-8 byte order mark: the mark is not content, so --fail-stale must exit 4 and
# name the note, exactly as it does for the same note without the mark. The exit code alone would not prove the note
# was FOUND, so the report line is asserted with it.
section "an expired note that starts with a byte order mark"
run_in "$REPO" "$CHECK" B/mark --fail-stale
if [ "$RC" -eq 4 ] && grep -Eq 'expired +n\.md \(stale_after 2020-01-01\)' "$OUT"; then v=1; else v=0; fi
verdict "invocation-forms-suite-and-byte-order-mark-expired-note-happy-1" "$v" \
  "expected exit 4 and 'expired  n.md (stale_after 2020-01-01)'; got exit $RC: $(shown)" "$RC"

# The negative case: the same note without the mark already gives that verdict, and must keep it.
run_in "$REPO" "$CHECK" B/plain --fail-stale
if [ "$RC" -eq 4 ] && grep -Eq 'expired +n\.md \(stale_after 2020-01-01\)' "$OUT"; then v=1; else v=0; fi
verdict "invocation-forms-suite-and-byte-order-mark-no-mark-negative-1" "$v" \
  "expected exit 4 and 'expired  n.md (stale_after 2020-01-01)'; got exit $RC: $(shown)" "$RC"

# The edge: the mark and CRLF line ends together (a note saved by an editor on Windows).
run_in "$REPO" "$CHECK" B/mark-crlf --fail-stale
if [ "$RC" -eq 4 ] && grep -Eq 'expired +n\.md \(stale_after 2020-01-01\)' "$OUT"; then v=1; else v=0; fi
verdict "invocation-forms-suite-and-byte-order-mark-crlf-edge-1" "$v" \
  "expected exit 4 and 'expired  n.md (stale_after 2020-01-01)'; got exit $RC: $(shown)" "$RC"

# The control: the mark must not invent staleness — the same mark on a note that is not expired stays a pass.
run_in "$REPO" "$CHECK" B/mark-fresh --fail-stale
if [ "$RC" -eq 0 ] && ! grep -Eq 'expired +n\.md' "$OUT"; then v=1; else v=0; fi
verdict "invocation-forms-suite-and-byte-order-mark-control-1" "$v" \
  "expected exit 0 and no 'expired' line; got exit $RC: $(shown)" "$RC"

# --- okf-check --file with --strict-trust ---------------------------------------------------------
section "okf-check --file applies --strict-trust like the whole-bundle run"
# The whole-bundle run fails on this note: that is the verdict --file must match in every spelling of the path. Each
# case also asserts the Trust finding is printed, so a right exit code for another reason cannot pass.
run_in "$REPO" "$CHECK" B/trust --strict-trust
if [ "$RC" -eq 1 ] && grep -q 'draft with human verification' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-control-1" "$v" \
  "the whole-bundle run must exit 1 with the Trust warning on this note (the control for the --file cases); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/trust --file B/trust/n.md --strict-trust
if [ "$RC" -eq 1 ] && grep -q 'draft with human verification' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-relative-path-happy-1" "$v" \
  "expected exit 1 with the Trust warning (the whole-bundle verdict); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/trust --file "$REPO/B/trust/n.md" --strict-trust
if [ "$RC" -eq 1 ] && grep -q 'draft with human verification' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-absolute-path-happy-1" "$v" \
  "expected exit 1 with the Trust warning (the whole-bundle verdict); got exit $RC: $(shown)" "$RC"

run_in "$REPO/B/trust" "$CHECK" . --file n.md --strict-trust
if [ "$RC" -eq 1 ] && grep -q 'draft with human verification' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-inside-bundle-happy-1" "$v" \
  "expected exit 1 with the Trust warning (the whole-bundle verdict); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/trust --file B/trust/n.md --strict
if [ "$RC" -eq 1 ] && grep -q 'draft with human verification' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-short-alias-happy-1" "$v" \
  "expected exit 1 under the short alias --strict, with the Trust warning; got exit $RC: $(shown)" "$RC"

# A stable note written by an agent and verified by a human: the whole-bundle run warns and fails under --strict-trust.
# Its control is the whole-bundle run on the same note, so the advisory case is measured against a verdict of the same
# input and not against the plan's expectation alone.
run_in "$REPO" "$CHECK" B/agent --strict-trust
if [ "$RC" -eq 1 ] && grep -Eq 'Trust policy +FAIL' "$OUT" \
   && grep -q 'a human review of an agent note cannot be authenticated' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-agent-note-control-1" "$v" \
  "the whole-bundle run must exit 1 on the agent note with the trust policy line and the advisory (the control for the --file case); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/agent --file B/agent/n.md --strict-trust
if [ "$RC" -eq 1 ] && grep -q 'a human review of an agent note cannot be authenticated' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-agent-note-happy-1" "$v" \
  "expected exit 1 with the agent-note advisory (the whole-bundle verdict on an agent note); got exit $RC: $(shown)" "$RC"

# The negative case: the fix must not turn every note into a failure — a clean note stays exit 0 and prints no finding.
# B/clean is the note no Trust finding is due on: a stable note written by a human and verified by a human. The Trust
# cases above run on B/trust and B/agent, so this case and they share the flags, and only the input decides the answer.
run_in "$REPO" "$CHECK" B/clean --file B/clean/n.md --strict-trust
if [ "$RC" -eq 0 ] && ! grep -q 'Trust' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-negative-1" "$v" \
  "expected exit 0 and no Trust finding for a clean note under --file --strict-trust; got exit $RC: $(shown)" "$RC"

# The edge: a note outside the bundle cannot be judged against the bundle's other notes, so it is an input the tool
# cannot use (exit 64) naming the path — never a run whose exit code says something about a note nobody checked.
run_in "$REPO" "$CHECK" B/trust --file B/clean/n.md --strict-trust
if [ "$RC" -eq 64 ] && grep -q "error: --file 'B/clean/n.md' is not inside" "$OUT"; then v=1; else v=0; fi
verdict "file-mode-strict-trust-edge-1" "$v" \
  "expected exit 64 and an error line saying the note is not inside the bundle; got exit $RC: $(shown)" "$RC"

# --- okf-verify with --repo . ---------------------------------------------------------------------
section "okf-verify judges a citation the same with --repo . as with an absolute path"
# The verdict word is asserted with the exit code: a moved line is MOVED, and exit 1 without that word would be a
# different failure wearing the right number. The match is the FINDING line — `MOVED` in a line of its own, naming the
# note — because the word also sits in okf-verify's help text and in the summary counts.
run_in "$REPO" "$VERIFY" B/root --repo .
if [ "$RC" -eq 1 ] && grep -Eq '^ *MOVED +n\.md' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-happy-1" "$v" \
  "expected exit 1 and a MOVED finding for n.md (an absolute --repo gives both); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$VERIFY" B/root --repo ./
if [ "$RC" -eq 1 ] && grep -Eq '^ *MOVED +n\.md' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-slash-happy-1" "$v" \
  "expected exit 1 and a MOVED finding for n.md (an absolute --repo gives both); got exit $RC: $(shown)" "$RC"

# A relative --repo spelled with `..` where no link is on the way, so it names the repository folder however it is taken
# apart. This case and the control below pass on the base tool and here: they are guards. The two link cases and the
# three typed-spelling cases further down guard the form of the fix rather than the defect it closes: they fail against
# a tool that collapses `..` lexically, which names another folder once a link is on the way.
run_in "$W" "$VERIFY" repo/B/root --repo repo/B/..
if [ "$RC" -eq 1 ] && grep -Eq '^ *MOVED +n\.md' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-edge-2" "$v" \
  "expected exit 1 and a MOVED finding for n.md with --repo repo/B/.. (it normalises to the repository folder); got exit $RC: $(shown)" "$RC"

# The second edge: the BUNDLE is given as `.` and a document name exists twice. The note's own folder decides, as it does
# for the absolute bundle path, so the citation is CONFIRMED — the word `ok` is asserted because the defect's own answer
# (an ambiguous UNRESOLVED) also exits 0.
run_in "$DUP" "$VERIFY" .
if [ "$RC" -eq 0 ] && grep -Eq '^ *ok +a/n\.md +\[line\] d\.md:2' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-edge-1" "$v" \
  "expected exit 0 and an 'ok' finding for a/n.md: the note's own folder holds d.md, as the absolute bundle path confirms; got exit $RC: $(shown)" "$RC"

# The control: the absolute spelling of the same repository, which the relative forms must match.
run_in "$REPO" "$VERIFY" B/root --repo "$REPO"
if [ "$RC" -eq 1 ] && grep -Eq '^ *MOVED +n\.md' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-control-1" "$v" \
  "expected exit 1 and a MOVED finding for n.md: the absolute --repo is the control of this group; got exit $RC: $(shown)" "$RC"

# The negative: a relative --repo must not invent a MOVED. A citation that is right stays an `ok` line and exit 0.
run_in "$REPO" "$VERIFY" B/right --repo .
if [ "$RC" -eq 0 ] && grep -Eq '^ *ok +n\.md +\[line\] spec\.md:2' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-negative-1" "$v" \
  "expected exit 0 and an 'ok' finding for n.md: spec.md line 2 holds the quoted text; got exit $RC: $(shown)" "$RC"

# A link followed by `..` on the --repo side: the folder the system names through the link is the one searched, so the
# pinned citation into it stays CONFIRMED. The word `ok` is asserted: without it a crash or a skip would read as a pass.
run_in "$LNK" "$VERIFY" b --repo link/..
if [ "$RC" -eq 0 ] && grep -Eq '^ *ok +n\.md +\[citation\] spec\.md:1' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-link-then-dotdot-repo-edge-1" "$v" \
  "expected exit 0 and an 'ok' finding: link/.. is the folder the link points into, which holds spec.md; got exit $RC: $(shown)" "$RC"

# The same on the bundle side: `link/../B3` is the folder the system names through the link, so the run has a bundle and
# a verdict, where collapsing `..` first lands on a folder that is not there.
run_in "$LNK" "$VERIFY" link/../B3
if [ "$RC" -eq 0 ] && grep -Eq '^ *ok +n\.md +\[line\] d\.md:2' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-link-then-dotdot-bundle-edge-1" "$v" \
  "expected exit 0 and an 'ok' finding: the bundle link/../B3 is the folder the system names through the link; got exit $RC: $(shown)" "$RC"

# The report names what the user typed, not the path this tool resolved for reading: a machine reading --json and a person
# reading an error line both asked for `B/right` and `nonexist`.
run_in "$REPO" "$VERIFY" B/right --repo . --json
if [ "$RC" -eq 0 ] && grep -q '"bundle": "B/right"' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-typed-bundle-control-1" "$v" \
  "expected \"bundle\": \"B/right\" in --json, the path as typed; got exit $RC: $(grep -m1 '"bundle"' "$OUT" | tr -d ' ')" "$RC"

run_in "$REPO" "$VERIFY" nonexist --repo .
if [ "$RC" -eq 2 ] && grep -q 'error: nonexist is not a directory' "$OUT"; then v=1; else v=0; fi
verdict "repo-dot-form-typed-error-control-1" "$v" \
  "expected exit 2 and 'error: nonexist is not a directory', the path as typed; got exit $RC: $(shown)" "$RC"

# The same rule for the machine-readable list of searched repositories, checked WHOLE: two --repo values, in the order
# they were passed, each spelled as typed. A reader that compares the field with the arguments it passed keeps working.
run_in "$REPO" "$VERIFY" B/right --repo . --repo ../other --json
searched=$("$REALPY" -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(d["repos_searched"]))' "$OUT" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$searched" = '[".", "../other"]' ]; then v=1; else v=0; fi
verdict "repo-dot-form-typed-repos-searched-control-1" "$v" \
  "expected \"repos_searched\": [\".\", \"../other\"] in --json, both paths as typed; got exit $RC with $searched" "$RC"

# --- okf-verify with a --repo that cannot be used -------------------------------------------------------
section "okf-verify stops when --repo names a missing folder or a file"
# A folder that is there but holds no repository, for the negative case: the new check must leave its skip alone.
NREPO="$W/not-a-repository"
mkdir -p "$NREPO"
ln -s nowhere-at-all "$W/dangling"   # a link that resolves to nothing: not a folder either
# The message must be an error line naming the path the user typed — okf-verify's own `error: <what> is not a
# directory` shape — not just the path somewhere in the output: an exit 2 with the path in a help or summary line would
# not tell anyone what to fix.
run_in "$REPO" "$VERIFY" B/ver --repo no-such-repo
if [ "$RC" -eq 2 ] && grep -Eq 'error: .*no-such-repo' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-missing-folder-happy-1" "$v" \
  "expected exit 2 and an error line naming no-such-repo (an input the tool cannot use), not a green run; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$VERIFY" B/ver --repo B/ver/n.md
if [ "$RC" -eq 2 ] && grep -Eq 'error: .*B/ver/n\.md' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-is-a-file-happy-1" "$v" \
  "expected exit 2 and an error line naming the typed path B/ver/n.md, not a green run; got exit $RC: $(shown)" "$RC"

# The control: a repository that is there is still searched, and its folder is named in the report.
run_in "$REPO" "$VERIFY" B/right --repo "$REPO"
if [ "$RC" -eq 0 ] && grep -q 'repos searched: repo' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-control-1" "$v" \
  "expected exit 0 and 'repos searched: repo': a folder that is a repository is searched, not refused; got exit $RC: $(shown)" "$RC"

# The negative: a folder that is there and holds no repository is skipped with a printed reason, as before. The new check
# refuses a path the tool cannot use, not a path that is not a repository — a mistyped folder and an uninitialised one
# are two different mistakes, and only the first stops the run.
run_in "$REPO" "$VERIFY" B/right --repo "$W/not-a-repository"
if [ "$RC" -eq 0 ] && grep -q 'not a git repo, skipped' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-negative-1" "$v" \
  "expected exit 0 and the 'not a git repo, skipped' line for a folder that holds no repository; got exit $RC: $(shown)" "$RC"

# --strict changes what counts as a failed claim, never whether a folder is there: a --repo the tool cannot use stops the
# run with the same code and the same message under it.
run_in "$REPO" "$VERIFY" B/ver --repo no-such-repo --strict
if [ "$RC" -eq 2 ] && grep -Eq 'error: .*no-such-repo' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-strict-edge-1" "$v" \
  "expected exit 2 and an error line naming no-such-repo under --strict too; got exit $RC: $(shown)" "$RC"

# An unset shell variable is the likeliest way a repository is mistyped: `--repo "$REPO"` with $REPO empty passes an empty
# argument, and the value `Path("")` turns into is `.` — the folder the shell happens to be in. It is refused as empty.
run_in "$REPO" "$VERIFY" B/ver --repo ""
if [ "$RC" -eq 2 ] && grep -q 'error: --repo is empty' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-empty-string-edge-1" "$v" \
  "expected exit 2 and 'error: --repo is empty' for an empty --repo; got exit $RC: $(shown)" "$RC"

# One unusable value stops the run wherever it sits, even with a good repository beside it.
run_in "$REPO" "$VERIFY" B/ver --repo no-such-repo --repo "$REPO"
if [ "$RC" -eq 2 ] && grep -Eq 'error: --repo .*no-such-repo' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-repeated-edge-1" "$v" \
  "expected exit 2 naming no-such-repo with a good repository beside it; got exit $RC: $(shown)" "$RC"

# A link that resolves to nothing is not a folder.
run_in "$REPO" "$VERIFY" B/ver --repo "$W/dangling"
if [ "$RC" -eq 2 ] && grep -Eq 'error: --repo .*dangling' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-dangling-symlink-edge-1" "$v" \
  "expected exit 2 naming the dangling link; got exit $RC: $(shown)" "$RC"

# A file spelled with a trailing slash: the system answers ENOTDIR, which is still not a directory.
run_in "$REPO" "$VERIFY" B/ver --repo B/ver/n.md/
if [ "$RC" -eq 2 ] && grep -Eq 'error: --repo .*B/ver/n\.md' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-file-trailing-slash-edge-1" "$v" \
  "expected exit 2 naming B/ver/n.md/ ; got exit $RC: $(shown)" "$RC"

# The help text is where a user looks for what stops a run, so the refusal is listed there under exit 2.
run_in "$W" "$VERIFY" --help
if [ "$RC" -eq 0 ] && grep -q 'a --repo that is not a directory' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-help-control-1" "$v" \
  "expected --help to list 'a --repo that is not a directory' under exit 2; got exit $RC: $(grep -m1 'no verdict' "$OUT")" "$RC"

# Both wrong at once: the bundle is named first, as it was before this slice, so the message a long-standing script reads
# does not change.
run_in "$REPO" "$VERIFY" nonexist --repo no-such-repo
if [ "$RC" -eq 2 ] && grep -q 'error: nonexist is not a directory' "$OUT"; then v=1; else v=0; fi
verdict "repo-must-exist-bundle-first-edge-1" "$v" \
  "expected the bundle to be the one named when both the bundle and a --repo are missing; got exit $RC: $(shown)" "$RC"

# --- --conserve and .okfignore ----------------------------------------------------------------
section "--conserve counts a line moved into an ignored note as lost"
# The behaviour is a LOST line, and the count must be non-zero: the report prints "0 LOST" on a clean run, so the bare word
# LOST would be true of every run and would prove nothing.
run_in "$CONS" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 1 ] && grep -Eq '[1-9][0-9]* LOST' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-happy-1" "$v" \
  "expected exit 1 and a non-zero LOST count: the line is in an ignored note, so it is not in the counted bundle; got exit $RC: $(shown)" "$RC"

# The edge: a negated line. The case asserts the count AND the tool's own line about negation, so a matcher that quietly
# supported negation — re-including the note, and answering exit 0 — would fail this case rather than pass it.
run_in "$CONS_NEG" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 1 ] && grep -Eq '[1-9][0-9]* LOST' "$OUT" && grep -q 'negation is not supported' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-edge-1" "$v" \
  "expected exit 1, a non-zero LOST count and the 'negation is not supported' line: the negated pattern is skipped as every layer skips it, so the note stays excluded; got exit $RC: $(shown)" "$RC"

# The control: a deletion is LOST and exits 1. This is the verdict the ignored-note case must match, measured on the same
# tool with no ignore file on the way, so the case above cannot pass by reporting every movement as lost.
run_in "$CONS_DEL" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 1 ] && grep -Eq '0 MOVED, 0 CHANGED, [1-9][0-9]* LOST' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-control-1" "$v" \
  "expected exit 1 and '0 MOVED, 0 CHANGED, 1 LOST' for a deletion; got exit $RC: $(shown)" "$RC"

# A counted note removed from the disk entirely is still a LOST line. This is the case an ignore filter breaks by asking
# "is the note on the list of counted notes?", because a deleted note is on no listing: the answer would read "not
# counted" and the loss would disappear. The .okfignore here exists and excludes only archive/, so a.md counts.
run_in "$CONS_FILE_DEL" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 1 ] && grep -Eq '0 MOVED, 0 CHANGED, [1-9][0-9]* LOST' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-delete-counted-note-control-2" "$v" \
  "expected exit 1 and a LOST line for a whole note deleted from the disk (it is not on any list of notes on disk); got exit $RC: $(shown)" "$RC"

# The negative: the line moved into a note the bundle counts is MOVED, nothing is lost, and the run exits 0. Without it,
# a change that called every movement lost would pass the cases above.
run_in "$CONS_KEPT" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq '1 MOVED, 0 CHANGED, 0 LOST' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-negative-1" "$v" \
  "expected exit 0 and '1 MOVED, 0 CHANGED, 0 LOST': the line is in a counted note; got exit $RC: $(shown)" "$RC"

# The line lived in an ignored note at the ref and still does, moved inside that folder: nothing the bundle counts changed,
# so the run exits 0 and the report says 0 lines were removed — the ignored note was read at neither end. A count line
# other than zero is the failure this case exists for.
run_in "$CONS_IN" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq '0 line\(s\) removed' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-move-inside-ignored-folder-edge-1" "$v" \
  "expected exit 0 and '0 line(s) removed': the line moved from one ignored note to another, so nothing counted lost it; got exit $RC: $(shown)" "$RC"

# The same note deleted: content nobody counts was never in the bundle, so a deletion there is no loss either.
run_in "$CONS_IGN_DEL" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq '0 line\(s\) removed' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-delete-in-ignored-note-edge-1" "$v" \
  "expected exit 0 and '0 line(s) removed': the deleted note is one .okfignore excludes, so no counted content was lost; got exit $RC: $(shown)" "$RC"

# The other direction is a gain, and it must stay one: the line left an ignored note and sits in a counted note now. The
# ref note is not read (that is the fix), so no MOVED count can appear for it; the case asserts what is left: the ONE real
# loss beside it (d.md, a counted note deleted) is reported by name and by count, and the ignored note's line is not.
run_in "$CONS_OUT" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 1 ] && grep -Eq '1 LOST' "$OUT" && grep -Eq 'LOST +d\.md:1' "$OUT" && ! grep -q 'archive/x\.md' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-move-out-of-ignored-folder-negative-2" "$v" \
  "expected exit 1 with the one real LOST line named d.md and no word about the ignored note; got exit $RC: $(shown)" "$RC"

# .okfignore = '*' (no note left in) with a note deleted: the report must not pass a bundle nobody looked at. Exit 2, the
# gate's own sentence, no PASS line; and one JSON document with the same stop under --json.
run_in "$CONS_ALL" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT" \
   && ! grep -Eq 'Conserve +PASS' "$OUT"; then text_stop=1; else text_stop=0; fi
run_in "$CONS_ALL" "$CHECK" B --conserve HEAD --fail-lost --json
if [ "$RC" -eq 2 ] && grep -q '"exit": 2' "$OUT" && grep -q 'nothing was checked (not a pass)' "$OUT"; then json_stop=1; else json_stop=0; fi
{ [ "$text_stop" -eq 1 ] && [ "$json_stop" -eq 1 ]; } && v=1 || v=0
verdict "conserve-honours-ignore-file-ignore-everything-edge-1" "$v" \
  "expected exit 2 with '.okfignore excludes every note - nothing was checked (not a pass)' in the text and a --json stop, and no PASS; text=$text_stop json=$json_stop, last exit $RC: $(shown)" "$RC"

# The same .okfignore once every note is gone from the disk — but the ref still holds them. This is not the gate's
# question: the gate asks "does the bundle hold a note now" (measured: `ignore: 0 file(s) excluded`, `L1 PASS 0
# concepts`, exit 0), while this report asks "did content that existed get lost". Content that existed at the ref is gone
# and every note is excluded, so it stops like the case above; base read LOST/exit 1 here, and a silent PASS would be a
# regression against it.
run_in "$CONS_ALL_GONE" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT" && ! grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ignore-everything-all-deleted-edge-1" "$v" \
  "expected exit 2 with the shared sentence: the ref holds notes and .okfignore counts none of them, so nobody compared the removed lines; got exit $RC: $(shown)" "$RC"

# The plain-name control: the same fixture shape, the name git prints without quotes. It must answer like the two above,
# so a listing that stopped reading the ref altogether cannot pass this group.
run_in "$W/ref-plain" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-listing-plain-name-control-4" "$v" \
  "expected exit 2 for a bundle whose only ref note is a.md, now gone from the disk; got exit $RC: $(shown)" "$RC"

run_in "$W/ref-non-ascii" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-listing-non-ascii-name-edge-4" "$v" \
  "expected exit 2: the ref holds café.md, and a quoted name must not read as no note; got exit $RC: $(shown)" "$RC"

run_in "$W/ref-newline" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-listing-newline-name-edge-5" "$v" \
  "expected exit 2: the ref holds a note whose name contains a newline, and it must count; got exit $RC: $(shown)" "$RC"

# index.md and log.md are not notes for this count (the gate skips them: ignore-lib.sh counts "kept" without them). With
# `concepts/` ignored and the only concept note deleted, the gate refuses the bundle; the report must too, and not pass
# 0 lines removed because two files that are not notes stayed counted. Base read LOST/exit 1 here.
run_in "$W/idx-ignored" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT" && ! grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-index-and-log-do-not-count-negative-1" "$v" \
  "expected exit 2: the only concept note is ignored and gone, index.md and log.md are not notes; got exit $RC: $(shown)" "$RC"

run_in "$W/idx-never" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-index-and-log-do-not-count-control-2" "$v" \
  "expected exit 0 PASS: no concept note was ever held, so nothing was lost; got exit $RC: $(shown)" "$RC"

run_in "$W/disk-only" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'excludes every note - nothing was checked (not a pass)' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-note-on-disk-none-at-ref-edge-6" "$v" \
  "expected exit 2: a concept note is on the disk and .okfignore excludes it, though the ref holds none; got exit $RC: $(shown)" "$RC"

run_in "$W/ref-mixed" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 1 ] && grep -Eq 'LOST +a\.md' "$OUT" && ! grep -q 'excludes every note' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-holds-ignored-and-counted-note-negative-9" "$v" \
  "expected exit 1 LOST a.md: the ref holds a counted note and an ignored one, and the counted one was deleted; got exit $RC: $(shown)" "$RC"

run_in "$W/ref-sibling" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-listing-sibling-folder-control-7" "$v" \
  "expected exit 0: the notes at the ref sit in C and B2, not in the bundle B; got exit $RC: $(shown)" "$RC"

run_in "$W/ref-lookalike" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-listing-lookalike-name-control-8" "$v" \
  "expected exit 0: UPPER.MD and x.md.bak are not notes; got exit $RC: $(shown)" "$RC"

# The ref listing itself can fail. It reads a non-zero exit as an answer only in a bug: the earlier version did exactly
# that and its check could never fire, so a failing `git ls-tree` is a loud exit 2 that names the git error. A stub `git`
# on PATH fails only that subcommand, so the rest of the run is real.
STUB_GIT="$TMP/stub-git"; mkdir -p "$STUB_GIT"
printf '#!/bin/sh\ncase "$*" in *" ls-tree "*) echo "fatal: simulated: cannot read the tree" >&2; exit 128 ;; esac\nexec %s "$@"\n' \
  "$(command -v git)" > "$STUB_GIT/git"
chmod +x "$STUB_GIT/git"
run_in "$CONS_ALL_GONE" env PATH="$STUB_GIT:$PATH" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 2 ] && grep -q 'git ls-tree HEAD failed (exit 128' "$OUT" && ! grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "conserve-honours-ignore-file-ref-listing-fails-edge-3" "$v" \
  "expected exit 2 naming the failed 'git ls-tree' and a fatal message, never a verdict or a silent 'no notes at the ref'; got exit $RC: $(shown)" "$RC"

# A bundle that holds no note at all is a different thing: nothing was removed and nothing could be lost, with an
# .okfignore (that then excludes nothing) and without one. Both read exit 0 and '0 line(s) removed', as before.
run_in "$CONS_NONE" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq '0 line\(s\) removed' "$OUT"; then none_ignore=1; else none_ignore=0; fi
run_in "$CONS_NONE_PLAIN" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq '0 line\(s\) removed' "$OUT"; then none_plain=1; else none_plain=0; fi
{ [ "$none_ignore" -eq 1 ] && [ "$none_plain" -eq 1 ]; } && v=1 || v=0
verdict "conserve-honours-ignore-file-no-notes-negative-3" "$v" \
  "expected exit 0 and '0 line(s) removed' for a bundle with no notes, with and without an .okfignore; with=$none_ignore without=$none_plain, last exit $RC: $(shown)" "$RC"

# An .okfignore this process may not read cannot be skipped: the report would count notes it was told to leave out, or
# leave out notes it was told to count. It stops with exit 2 and names the file, as every other mode does.
CONS_LOCKED="$W/cons-locked"; mkcons "$CONS_LOCKED" 'archive/
'
chmod 000 "$CONS_LOCKED/B/.okfignore"
if [ -r "$CONS_LOCKED/B/.okfignore" ]; then
  case_precondition_failed "conserve-honours-ignore-file-unreadable-ignore-file-edge-2" \
    "the test runs as a user that can read a mode-000 file (root), so an unreadable .okfignore cannot be staged"
else
  run_in "$CONS_LOCKED" "$CHECK" B --conserve HEAD --fail-lost
  if [ "$RC" -eq 2 ] && grep -q 'could not be applied' "$OUT"; then v=1; else v=0; fi
  verdict "conserve-honours-ignore-file-unreadable-ignore-file-edge-2" "$v" \
    "expected exit 2 and a line saying .okfignore could not be applied; got exit $RC: $(shown)" "$RC"
fi
chmod 644 "$CONS_LOCKED/B/.okfignore" 2>/dev/null

# --- a flag a report mode never reads --------------------------------------------------------------
section "a gate flag is not dropped when a report mode is given"
# The command line is refused (exit 64) rather than merged into one report: merging a gate and a report in one pass is a
# bigger change, and a user who asked for a gate must never get a report's exit 0. The message names both flags, or the
# user cannot tell which one to drop.
run_in "$REPO" "$CHECK" B/mark --duplicates --fail-stale
if [ "$RC" -eq 64 ] && grep -q -- '--fail-stale cannot be combined with --duplicates' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-happy-1" "$v" \
  "expected exit 64 and the line '--fail-stale cannot be combined with --duplicates'; got exit $RC: $(shown)" "$RC"

# The control for the refusal: the flag the message names works where the tool says it works. A bundle unchanged since the
# commit has nothing removed, so --conserve --fail-lost passes with exit 0 and its PASS line — the run the pair above
# replaces with a refusal.
GATE="$W/gate-flags"
mkdir -p "$GATE"
g init -q "$GATE"
g -C "$GATE" config user.email t@t
g -C "$GATE" config user.name t
mkb "$GATE/B"
g -C "$GATE" add -A
g -C "$GATE" commit -q -m base
run_in "$GATE" "$CHECK" B --conserve HEAD --fail-lost
if [ "$RC" -eq 0 ] && grep -Eq 'Conserve +PASS' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-conserve-control-1" "$v" \
  "expected exit 0 and a Conserve PASS line: --fail-lost is a valid flag with --conserve, and this bundle lost no line; got exit $RC: $(shown)" "$RC"

# --fail-stale alone is the other control: the flag the refusal names still decides a gate when no report mode is given.
# The bundle holds the expired note, so the verdict is exit 4, and the note is named — an exit 4 for another reason would
# not be this behaviour.
run_in "$REPO" "$CHECK" B/mark --fail-stale
if [ "$RC" -eq 4 ] && grep -Eq 'expired +n\.md \(stale_after 2020-01-01\)' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-control-1" "$v" \
  "expected exit 4 and the expired line for n.md: --fail-stale alone still gates; got exit $RC: $(shown)" "$RC"

# And the report mode alone still works: --duplicates is an advisory report with no gate flag, so it runs and exits 0.
# The report's own heading is asserted, because exit 0 is also what a run that printed nothing gives.
run_in "$REPO" "$CHECK" B/mark --duplicates
if [ "$RC" -eq 0 ] && grep -q 'duplicates in B/mark' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-negative-1" "$v" \
  "expected exit 0 and the 'duplicates in B/mark' heading: --duplicates alone still runs; got exit $RC: $(shown)" "$RC"

# The same class at the same site: --fail-lost and --deleted name work only --conserve does. Without it the check ran and
# exited 0 with the flag unread — a user who typed a failing gate got a green verdict. Refused, and the message says
# which flag and what it needs.
run_in "$REPO" "$CHECK" B/mark --fail-lost
if [ "$RC" -eq 64 ] && grep -q -- '--fail-lost only works with --conserve' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-fail-lost-alone-edge-1" "$v" \
  "expected exit 64 and the line '--fail-lost only works with --conserve'; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --deleted "$TMP/unused.del"
if [ "$RC" -eq 64 ] && grep -q -- '--deleted only works with --conserve' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-deleted-alone-edge-1" "$v" \
  "expected exit 64 and the line '--deleted only works with --conserve'; got exit $RC: $(shown)" "$RC"

# A report mode and one of those two flags together get their own advice: the flag is no gate flag, so telling the user to
# "run the gate and the report as two commands" would be wrong. The line must name the report mode as well, and point at
# --conserve, the only mode that reads the flag.
run_in "$REPO" "$CHECK" B/mark --duplicates --fail-lost
if [ "$RC" -eq 64 ] && grep -q -- '--fail-lost only works with --conserve, not with --duplicates' "$OUT" \
   && grep -q -- 'run --conserve <ref> --fail-lost' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-fail-lost-with-duplicates-edge-1" "$v" \
  "expected exit 64 and a line saying --fail-lost needs --conserve and is not a gate flag (not the two-commands advice); got exit $RC: $(shown)" "$RC"

# A flag this tool reads must not take its value from the caller's environment: with FAIL_LOST exported, a plain run
# refused itself (exit 64) although the user typed no flag at all. The bundle is clean, so a plain run exits 0.
run_in "$REPO" env FAIL_LOST=1 DELETED_GIVEN=1 "$CHECK" B/clean
if [ "$RC" -eq 0 ] && grep -q 'L1 conformance' "$OUT" && ! grep -q 'only works with --conserve' "$OUT"; then v=1; else v=0; fi
verdict "gate-flag-with-report-mode-inherited-environment-edge-1" "$v" \
  "expected exit 0 and a check that ran (an exported FAIL_LOST/DELETED_GIVEN is not a flag on the command line); got exit $RC: $(shown)" "$RC"

# --- file-mode-and-report-mode-refusals --------------------------------------------------------------------
# The same class one step earlier in the argument loop. A second mode replaced the first without a word (the LAST mode
# won), and `--file` — a scoped gate, not a report — never refused the gate flags it cannot read. Every case below runs
# on a form this file builds itself; the same commands against the release head before this slice gave: `--file n.md
# --fail-stale` and `--fail-on-change` exit 0 printing nothing; `--duplicates --facts` only the facts line and
# `--facts --duplicates` only the duplicates report; `--doctor --fail-stale` the doctor report and no freshness
# judgement. Two texts, so each refusal says which flag is dropped and why:
#   two modes, or a gate flag with an action mode — "<first> cannot be combined with <second>: a run does one thing,
#   so <first> would be read by nothing — run them as two commands";
#   a gate flag with --file — "--fail-stale cannot be combined with --file: --file checks one note and reads no gate
#   flag, ...". Naming: TWO MODES are named in the order typed (each order of one pair has its own key), and a GATE FLAG
#   with a mode always names the gate flag first, because the gate flag is the flag that would be read by nothing; the
#   loop below proves that both orders give the same line.
run_in "$REPO" "$CHECK" B/mark --file B/mark/n.md --fail-stale
if [ "$RC" -eq 64 ] && grep -q -- '--fail-stale cannot be combined with --file: --file checks one note and reads no gate flag' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-file-fail-stale-happy-1" "$v" \
  "expected exit 64 and a line saying --fail-stale cannot be combined with --file (the scoped check reads no gate flag); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --file B/mark/n.md --fail-on-change
if [ "$RC" -eq 64 ] && grep -q -- '--fail-on-change cannot be combined with --file: --file checks one note and reads no gate flag' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-file-fail-on-change-happy-1" "$v" \
  "expected exit 64 and a line saying --fail-on-change cannot be combined with --file; got exit $RC: $(shown)" "$RC"

# Two report modes: the second used to replace the first, and the run still exited 0, so the report the user asked for
# was never printed. One key per order, because the message names the pair in the order typed.
run_in "$REPO" "$CHECK" B/mark --duplicates --facts
if [ "$RC" -eq 64 ] && grep -q -- 'error: --duplicates cannot be combined with --facts: a run does one thing, so --duplicates would be read by nothing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-two-report-modes-happy-1" "$v" \
  "expected exit 64 naming --duplicates then --facts; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --facts --duplicates
if [ "$RC" -eq 64 ] && grep -q -- 'error: --facts cannot be combined with --duplicates: a run does one thing, so --facts would be read by nothing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-duplicates-facts-edge-1" "$v" \
  "expected exit 64 naming --facts then --duplicates (the other order of the pair above); got exit $RC: $(shown)" "$RC"

# --file is a mode too, and it lost the same way: this pair exited 0 printing nothing.
run_in "$REPO" "$CHECK" B/mark --duplicates --file B/mark/n.md
if [ "$RC" -eq 64 ] && grep -q -- 'error: --duplicates cannot be combined with --file: a run does one thing, so --duplicates would be read by nothing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-duplicates-file-edge-1" "$v" \
  "expected exit 64 naming --duplicates then --file; got exit $RC: $(shown)" "$RC"

# --duplicates with --duplicates-body is one mode, but it is not a licence for a second real mode: the pair stays
# allowed (both orders, below), and a real second mode after it is still dropped in silence, so it refuses. The count is
# of distinct modes, so the duplicates family counts once and the message names it by its first spelling.
run_in "$REPO" "$CHECK" B/mark --duplicates --duplicates-body --facts
if [ "$RC" -eq 64 ] && grep -q -- 'error: --duplicates cannot be combined with --facts: a run does one thing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-three-modes-after-duplicates-body-edge-1" "$v" \
  "expected exit 64 naming --duplicates then --facts: the duplicates pair is one mode and does not excuse a second; got exit $RC: $(shown)" "$RC"

# Three flags at once: a new refusal and an existing one both apply. The refusal is chosen by flag TYPE, not by argument
# order, and the two new ones are checked first, so this names --file and --duplicates and never the report-mode text
# ("a report mode replaces the gate run"), which is the message the same command line gave before the change.
run_in "$REPO" "$CHECK" B/mark --file B/mark/n.md --duplicates --fail-stale
if [ "$RC" -eq 64 ] && grep -q -- 'error: --file cannot be combined with --duplicates: a run does one thing' "$OUT" \
   && ! grep -q -- 'a report mode replaces the gate run' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-three-flag-precedence-edge-1" "$v" \
  "expected exit 64 and the two-mode text naming --file and --duplicates (not the report-mode text); got exit $RC: $(shown)" "$RC"

# A gate flag with an action mode is the same class: --doctor printed its report and judged no freshness, exit 0. The loop
# covers every action mode with every gate flag in both orders, so a refusal that fires for one mode but not another, or
# for one flag but not another, or only when the mode is typed first, fails here rather than in a user's run. The gate flag
# is the flag that would be read by nothing, so the line names it first whichever order was typed.
# The loop gets its OWN bundle: on a build that does not refuse these pairs, `--init-house-rules` and `--init-ignore`
# RUN and write into the bundle, so a loop over B/mark would leave okf-base.yaml behind and change the answers of the
# cases below it (measured: on the release head the facts-json negative saw "no okf_check.facts block" instead of "no
# okf-base.yaml"). A separate bundle keeps every case independent of the order the suite runs in.
mkb "$W/gate-modes"; printf '%s\n' "$NOTE_EXPIRED" > "$W/gate-modes/n.md"
for _am in --doctor --selftest --preflight --fingerprint --init-ignore --init-house-rules --install-deps; do
  for _gf in --fail-stale --strict-trust --fail-on-change; do
    for _order in mode-first flag-first; do
      _mn=${_am#--}; _fn=${_gf#--}
      if [ "$_order" = mode-first ]; then
        run_in "$W" "$CHECK" gate-modes "$_am" "$_gf"
      else
        run_in "$W" "$CHECK" gate-modes "$_gf" "$_am"
      fi
      if [ "$RC" -eq 64 ] && grep -q -- "error: $_gf cannot be combined with $_am: a run does one thing, so $_gf would be read by nothing" "$OUT"; then v=1; else v=0; fi
      verdict "file-mode-and-report-mode-refusals-$_mn-with-$_fn-$_order-edge-1" "$v" \
        "expected exit 64 naming $_gf then $_am ($_order): the gate flag is the one read by nothing; got exit $RC: $(shown)" "$RC"
    done
  done
done

# The same gate flags with --file in the order that puts the flag first: the --file text names the flag first too, so this
# is the same line as the --file-first cases above.
run_in "$REPO" "$CHECK" B/mark --fail-stale --file B/mark/n.md
if [ "$RC" -eq 64 ] && grep -q -- 'error: --fail-stale cannot be combined with --file: --file checks one note and reads no gate flag' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-fail-stale-before-file-happy-1" "$v" \
  "expected exit 64 and the --file line with the flag typed first; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --fail-on-change --file B/mark/n.md
if [ "$RC" -eq 64 ] && grep -q -- 'error: --fail-on-change cannot be combined with --file: --file checks one note and reads no gate flag' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-fail-on-change-before-file-happy-1" "$v" \
  "expected exit 64 and the --file line with the flag typed first; got exit $RC: $(shown)" "$RC"

# --file is a mode, so the other order of the --duplicates pair is refused too, and names --file first because --file was
# typed first (`--duplicates --file n.md` is the case above).
run_in "$REPO" "$CHECK" B/mark --file B/mark/n.md --duplicates
if [ "$RC" -eq 64 ] && grep -q -- 'error: --file cannot be combined with --duplicates: a run does one thing, so --file would be read by nothing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-file-duplicates-edge-1" "$v" \
  "expected exit 64 naming --file then --duplicates; got exit $RC: $(shown)" "$RC"

# The distinct count: a flag typed three times is one mode, and so is --duplicates with --duplicates-body. Both used to
# exit 0 and still must — a refusal here would break a script that repeats a flag.
run_in "$REPO" "$CHECK" B/mark --duplicates --duplicates --duplicates
if [ "$RC" -eq 0 ] && grep -q 'duplicates in B/mark' "$OUT" && ! grep -q 'cannot be combined' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-duplicates-thrice-negative-1" "$v" \
  "expected exit 0 and the duplicates report: one flag typed three times is one mode; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --duplicates-body --duplicates
if [ "$RC" -eq 0 ] && grep -q 'duplicates in B/mark' "$OUT" && ! grep -q 'cannot be combined' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-duplicates-body-duplicates-negative-1" "$v" \
  "expected exit 0 and the duplicates report: the body variant in the other order is one mode (the forward order is the -duplicates-duplicates-body-negative-1 case); got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --duplicates --duplicates-body --duplicates
if [ "$RC" -eq 0 ] && grep -q 'duplicates in B/mark' "$OUT" && ! grep -q 'cannot be combined' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-duplicates-body-repeated-edge-1" "$v" \
  "expected exit 0: the duplicates family typed three times is still one mode; got exit $RC: $(shown)" "$RC"

# Two distinct modes with one of them repeated: still two, so it refuses and names the two distinct ones.
run_in "$REPO" "$CHECK" B/mark --doctor --selftest --selftest
if [ "$RC" -eq 64 ] && grep -q -- 'error: --doctor cannot be combined with --selftest: a run does one thing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-doctor-selftest-repeated-edge-1" "$v" \
  "expected exit 64 naming --doctor then --selftest (the repeat is not a third mode); got exit $RC: $(shown)" "$RC"

# Three distinct modes: the message names the FIRST and the LAST typed (the first is dropped, the last wins), so it is
# always a true pair and stays short.
run_in "$REPO" "$CHECK" B/mark --duplicates --facts --conserve HEAD
if [ "$RC" -eq 64 ] && grep -q -- 'error: --duplicates cannot be combined with --conserve: a run does one thing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-three-distinct-modes-edge-1" "$v" \
  "expected exit 64 naming the first and the last of three modes (--duplicates then --conserve); got exit $RC: $(shown)" "$RC"

# A repeat at the end of a long command line is not a new mode, so it must not be the name the message uses: the first
# form used to say "--doctor cannot be combined with --doctor", the second "--duplicates cannot be combined with
# --duplicates-body", both naming one mode against itself or against its own body variant.
run_in "$REPO" "$CHECK" B/mark --doctor --selftest --preflight --doctor
if [ "$RC" -eq 64 ] && grep -q -- 'error: --doctor cannot be combined with --preflight: a run does one thing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-three-modes-repeating-the-first-edge-1" "$v" \
  "expected exit 64 naming --doctor then --preflight: the trailing --doctor repeats a mode already given; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --duplicates --facts --doctor --duplicates-body
if [ "$RC" -eq 64 ] && grep -q -- 'error: --duplicates cannot be combined with --doctor: a run does one thing' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-three-modes-repeating-the-family-edge-1" "$v" \
  "expected exit 64 naming --duplicates then --doctor: --duplicates-body at the end is the same mode as --duplicates; got exit $RC: $(shown)" "$RC"

# The negatives: every combination that IS read stays allowed, and must answer exactly as before the change. --strict-trust
# is the one gate flag --file reads (okf-check passes it to the scoped layer), so it must still block on a Trust warning.
run_in "$REPO" "$CHECK" B/agent --file B/agent/n.md --strict-trust
if [ "$RC" -eq 1 ] && grep -q 'n.md: Trust advisory: verified\[0\].by' "$OUT" && ! grep -q 'cannot be combined' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-file-strict-trust-negative-1" "$v" \
  "expected exit 1 and the note's Trust advisory line: --file still reads --strict-trust, so this pair is never refused; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --facts --json
if [ "$RC" -eq 0 ] && grep -q 'no okf-base.yaml in B/mark: nothing to list' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-facts-json-negative-1" "$v" \
  "expected exit 0 and the facts text report: --json with --facts is decided (S38-ST-N7), not refused; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --doctor --json
if [ "$RC" -eq 0 ] && grep -q 'python3' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-doctor-json-negative-1" "$v" \
  "expected exit 0 and the doctor report: --json with --doctor is decided (S38-ST-N7), not refused; got exit $RC: $(shown)" "$RC"

run_in "$REPO" "$CHECK" B/mark --duplicates --duplicates-body
if [ "$RC" -eq 0 ] && grep -q 'duplicates in B/mark' "$OUT"; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-duplicates-duplicates-body-negative-1" "$v" \
  "expected exit 0 and the duplicates report: --duplicates-body is a documented variant of --duplicates, not a second mode; got exit $RC: $(shown)" "$RC"

# The control: the scoped check alone still runs and still answers as it did (exit 0, no line for this note), with no
# refusal on stderr — a refusal that fired on the mode by itself would make every case above pass for the wrong reason.
run_in "$REPO" "$CHECK" B/mark --file B/mark/n.md
if [ "$RC" -eq 0 ] && [ ! -s "$OUT" ]; then v=1; else v=0; fi
verdict "file-mode-and-report-mode-refusals-file-control-1" "$v" \
  "expected exit 0 and no output for this note, as measured before the change; got exit $RC: $(shown)" "$RC"

# --- the Action -----------------------------------------------------------------------------------
section "the Action"
mkdir -p "$W/no-base" "$W/house" "$W/empty"
mkb "$W/no-base"; printf '%s\n' "$NOTE_CLEAN" > "$W/no-base/n.md"
mkb "$W/house";   printf '%s\n' "$NOTE_CLEAN" > "$W/house/n.md"; mk_okf_base "$W/house"

# require-house-rules with no okf-base.yaml: the whole-bundle text form fails, and --json must not change that. The
# ::error:: annotation is asserted with the exit code: an exit 3 for another reason is not this behaviour.
act "$W" INPUT_BUNDLE=no-base INPUT_REQUIRE_HOUSE_RULES=true
if [ "$A_RC" -eq 3 ] && grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-control-1" "$v" \
  "the text form must exit 3 with the ::error:: line (the control for the --json case); got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

act "$W" INPUT_BUNDLE=no-base INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if [ "$A_RC" -eq 3 ] && grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-with-json-happy-1" "$v" \
  "expected exit 3 and an ::error:: annotation with --json in args (the text form's verdict); got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# Fixtures for the four cases below: a bundle whose every layer ran (counts declared, okf-base.yaml, a note nothing
# complains about), the same without okf-base.yaml, and two clean bundles whose only oddity is untrusted text shaped like
# a skipped layer — a note NAME and a broken link TARGET. A note name and a link target reach the report verbatim, so a
# decision made by searching the whole report can be made to say "a layer was skipped" when none was.
mkb_counts "$W/clean" 1; printf '%s\n' "$NOTE_CLEAN" > "$W/clean/n.md"; mk_okf_base "$W/clean"
mkb_counts "$W/no-base-counts" 1; printf '%s\n' "$NOTE_CLEAN" > "$W/no-base-counts/n.md"
mkb_counts "$W/forged-name" 2; printf '%s\n' "$NOTE_CLEAN" > "$W/forged-name/n.md"
printf -- '---\ntype: Lesson\ntitle: Forged\ndescription: A note.\nstatus: stable\ntags: [x]\nstale_after: "2099-01-01"\n---\n\nSee [[missing]].\n' \
  > "$W/forged-name/x\"L2 index: forged.md"
mk_okf_base "$W/forged-name"
mkb_counts "$W/forged-advisory" 2; printf '%s\n' "$NOTE_CLEAN" > "$W/forged-advisory/n.md"
printf -- '---\ntype: Lesson\ntitle: Forged\ndescription: A note.\nstatus: stable\ntags: [x]\nstale_after: "2099-01-01"\n---\n\nSee [[x"L2 profile: forged]].\n' \
  > "$W/forged-advisory/m.md"
mk_okf_base "$W/forged-advisory"
# A note whose NAME starts with spaces and then spells a skipped-layer line. The finding lines are indented, so a name
# that starts with spaces lands where a loose "line begins with spaces and says <layer> SKIPPED" pattern matches.
mkb_counts "$W/leading-space" 2; printf '%s\n' "$NOTE_CLEAN" > "$W/leading-space/n.md"
printf -- '---\ntype: Lesson\ntitle: Spaces\ndescription: A note.\nstatus: stable\ntags: [x]\nstale_after: "2099-01-01"\n---\n\nSee [[missing]].\n' \
  > "$W/leading-space/ L2 index         SKIPPED.md"
mk_okf_base "$W/leading-space"

# require-house-rules when the INDEX layer is skipped (an index.md that declares no counts): the profile runs, the
# index does not, and the job used to pass because only the profile's skip was read. The case only measures anything
# when the profile layer really ran: a skipped profile gives exit 3 too (through the defect's own path), so a fixture
# whose profile was skipped would pass for the wrong reason. Both halves are checked in the log, not assumed.
act "$W" INPUT_BUNDLE=house INPUT_REQUIRE_HOUSE_RULES=true
if grep -Eq '^ +L2 profile +SKIPPED' "$A_LOG" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-index-skipped-happy-1" \
    "L2's profile layer was SKIPPED (no okf-base.yaml, or okflint is not installed), so a skipped INDEX layer cannot be told from a skipped profile: this case would pass through the profile's own skip. Install okflint (tools/install-dev-deps.sh) and let --init-house-rules write the fixture's okf-base.yaml. Log: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$A_RC" -eq 3 ] && grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-index-skipped-happy-1" "$v" \
    "expected exit 3 and an ::error:: annotation when the index layer is skipped; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# The two defects of this slice together: the index layer skipped AND --json in args. Neither the format nor the layer
# may hide it. Same fixture as the case above, so the same precondition guard applies.
act "$W" INPUT_BUNDLE=house INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
# The log of this run is one JSON document, so the profile's verdict is read from l2_profile (the case above reads the
# text report's SKIPPED line for the same fact).
if grep -qF '"l2_profile":"skipped"' "$A_LOG" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-index-skipped-with-json-edge-1" \
    "L2's profile layer was SKIPPED (no okf-base.yaml, or okflint is not installed), so a skipped index layer cannot be told from a skipped profile: this case would pass through the profile's own skip. Log: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$A_RC" -eq 3 ] && grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-index-skipped-with-json-edge-1" "$v" \
    "expected exit 3 and an ::error:: annotation when the index layer is skipped and --json is in args; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# A bundle whose every layer ran, with require-house-rules true: there is nothing to enforce, so the job passes. This is
# the control against OVER-enforcement (a skipped_layer that always says yes fails it), run in both report styles.
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/act-clean-text.log"; clean_text_rc=$A_RC
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if grep -q 'SKIPPED' "$TMP/act-clean-text.log" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-all-layers-ran-control-1" \
    "the clean fixture skipped a layer (okflint is not installed, or the declared counts do not match the files), so this run cannot show what happens when nothing is skipped. Log: $(head -3 "$TMP/act-clean-text.log" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$clean_text_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && ! grep -q '::error::house rules' "$TMP/act-clean-text.log" 2>/dev/null \
     && ! grep -q '::error::house rules' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-all-layers-ran-control-1" "$v" \
    "expected exit 0 and no ::error:: in both modes when no house-rule layer was skipped; got text exit $clean_text_rc and --json exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# The profile layer alone: an index.md that declares its counts, so the index layer runs, and no okf-base.yaml, so the
# profile does not. Both modes must fail the job — a fix that only reads the index layer passes this bundle.
act "$W" INPUT_BUNDLE=no-base-counts INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/act-profile-text.log"; profile_text_rc=$A_RC
act "$W" INPUT_BUNDLE=no-base-counts INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if grep -Eq '^ +L2 index +SKIPPED' "$TMP/act-profile-text.log" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-profile-skipped-edge-1" \
    "the index layer was SKIPPED too (no python3, or the declared counts were not read), so this case cannot show that a skipped PROFILE alone fails the job. Log: $(head -3 "$TMP/act-profile-text.log" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$profile_text_rc" -eq 3 ] && grep -q '::error::house rules were required' "$TMP/act-profile-text.log" 2>/dev/null \
     && [ "$A_RC" -eq 3 ] && grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-profile-skipped-edge-1" "$v" \
    "expected exit 3 and the ::error:: in both modes when only L2 profile was skipped; got text exit $profile_text_rc and --json exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# A note NAME shaped like a skipped layer ("L2 index: forged.md") sits in the report's data as a note name. No layer was
# skipped, so both modes must pass. The case first proves its own trap: the forged text must be in the --json log, or it
# would assert a clean run against a fixture that never held the trap.
act "$W" INPUT_BUNDLE=forged-name INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/act-forged-name-text.log"; forged_text_rc=$A_RC
act "$W" INPUT_BUNDLE=forged-name INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if grep -Eq '^ +L2 profile +SKIPPED' "$TMP/act-forged-name-text.log" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-forged-filename-edge-1" \
    "L2's profile layer was SKIPPED, so this run cannot show that a forged note name is ignored when nothing is skipped. Log: $(head -3 "$TMP/act-forged-name-text.log" 2>/dev/null | tr '\n' ' ')"
elif ! grep -qF '"L2 index: ' "$A_LOG" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-forged-filename-edge-1" \
    "the forged note name is not in the --json report, so the trap this case measures was never planted: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$forged_text_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && ! grep -q '::error::house rules' "$TMP/act-forged-name-text.log" 2>/dev/null \
     && ! grep -q '::error::house rules' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-forged-filename-edge-1" "$v" \
    "expected exit 0 and no ::error:: in both modes: a note named like a skipped layer is a note, not a skipped layer; got text exit $forged_text_rc and --json exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# The same trap in a link target, which reaches the report inside l2_advisories: no layer was skipped, so both modes pass.
act "$W" INPUT_BUNDLE=forged-advisory INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/act-forged-advisory-text.log"; forged_adv_rc=$A_RC
act "$W" INPUT_BUNDLE=forged-advisory INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if grep -Eq '^ +L2 profile +SKIPPED' "$TMP/act-forged-advisory-text.log" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-forged-advisory-edge-1" \
    "L2's profile layer was SKIPPED, so this run cannot show that a forged link target is ignored when nothing is skipped. Log: $(head -3 "$TMP/act-forged-advisory-text.log" 2>/dev/null | tr '\n' ' ')"
elif ! grep -qF '"L2 profile: ' "$A_LOG" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-forged-advisory-edge-1" \
    "the forged link target is not in the --json report (okflint may not report the dangling link), so the trap this case measures was never planted: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$forged_adv_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && ! grep -q '::error::house rules' "$TMP/act-forged-advisory-text.log" 2>/dev/null \
     && ! grep -q '::error::house rules' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-forged-advisory-edge-1" "$v" \
    "expected exit 0 and no ::error:: in both modes: a link target shaped like a skipped layer is an advisory, not a skipped layer; got text exit $forged_adv_rc and --json exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# The same trap in the TEXT report: a note named " L2 index         SKIPPED.md" puts that text where the finding lines
# are indented. No layer was skipped, so both modes must pass. The case proves its own trap: the text log must hold a
# line that a loose "spaces then <layer> SKIPPED" pattern matches, or the fixture never created the trap.
act "$W" INPUT_BUNDLE=leading-space INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/act-leading-space-text.log"; leading_text_rc=$A_RC
act "$W" INPUT_BUNDLE=leading-space INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if grep -Eq '^ +L2 index +SKIPPED' "$TMP/act-leading-space-text.log" 2>/dev/null; then
  trap_planted=1
else
  trap_planted=0
fi
if grep -Eq '^ +L2 profile +SKIPPED' "$TMP/act-leading-space-text.log" 2>/dev/null; then
  case_precondition_failed "action-enforces-house-rules-leading-space-name-edge-1" \
    "L2's profile layer was SKIPPED, so this run cannot show that a forged note name is ignored when nothing is skipped. Log: $(head -3 "$TMP/act-leading-space-text.log" 2>/dev/null | tr '\n' ' ')"
elif [ "$trap_planted" -eq 0 ]; then
  case_precondition_failed "action-enforces-house-rules-leading-space-name-edge-1" \
    "the forged note name is not in the text report, so the trap this case measures was never planted: $(head -3 "$TMP/act-leading-space-text.log" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$leading_text_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && ! grep -q '::error::house rules' "$TMP/act-leading-space-text.log" 2>/dev/null \
     && ! grep -q '::error::house rules' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-enforces-house-rules-leading-space-name-edge-1" "$v" \
    "expected exit 0 and no ::error:: in both modes: a note named like a skipped layer is a note, not a skipped layer; got text exit $leading_text_rc and --json exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
fi

# The --json decision must fail CLOSED. A stub okf-check dictates exactly what the tool prints, so each route below is
# measured on its own: a report the Action cannot read is not a pass, whatever went wrong.
stub_check() { # <line>... — the body of a stub okf-check
  mkdir -p "$W/stub/plugin/scripts"
  { printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' "$@"; } > "$W/stub/plugin/scripts/okf-check"
  chmod +x "$W/stub/plugin/scripts/okf-check"
}
# A notice on stderr beside one valid document: the two streams are captured apart, so the notice cannot reach the parse
# and the skipped layer it names still fails the job. (With the streams merged this read as an unreadable report and the
# job passed — the opposite of what the message below says.)
stub_check 'printf "%s\n" "okf-check: a warning on stderr" >&2' \
           'printf "%s\n" "{\"bundle\":\"x\",\"exit\":0,\"l2_profile\":\"ran\",\"layers_not_run\":[],\"skipped\":[\"L2 profile: forged\"]}"'
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub"
if [ "$A_RC" -eq 3 ] && grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-stderr-beside-json-edge-1" "$v" \
  "expected exit 3: a stderr notice beside a valid report must not switch the enforcement off; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# Two documents, a list, no skipped key: each is a report the Action cannot read, so the job must fail with the reason.
stub_check 'printf "%s\n" "{\"skipped\":[],\"layers_not_run\":[]}" "{\"skipped\":[\"L2 profile: forged\"]}"'
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub"
if [ "$A_RC" -eq 3 ] && grep -q '::error::okf-check --json did not give one readable report (the output is not one JSON document)' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-two-json-documents-edge-1" "$v" \
  "expected exit 3 naming the unreadable report when two documents are printed; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

stub_check 'printf "%s\n" "{\"bundle\":\"x\",\"l2_profile\":\"ran\"}"'
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub"
if [ "$A_RC" -eq 3 ] && grep -q '::error::okf-check --json did not give one readable report (the report has no skipped list)' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-skipped-key-absent-edge-1" "$v" \
  "expected exit 3 naming the missing skipped list, not a pass; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The opposite input: one readable document that names no skipped layer passes, so the three cases above are shown red
# against a stub that is wrong in one way each, not against every stub.
stub_check 'printf "%s\n" "{\"bundle\":\"x\",\"exit\":0,\"l2_profile\":\"ran\",\"layers_not_run\":[],\"skipped\":[]}"'
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub"
if [ "$A_RC" -eq 0 ] && ! grep -q '::error::' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-one-clean-document-control-1" "$v" \
  "expected exit 0 and no ::error:: for one readable document naming no skipped layer; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The job's three temp files hold the bundle's own output, so none may outlive the run. `mktemp` is shimmed onto PATH to
# create every temp file in one folder this case watches: anything left there afterwards is a leak. (A TMPDIR variable
# would not do it: BSD mktemp, on macOS, ignores it and uses the system folder.)
MKWATCH="$TMP/action-tmpwatch"; rm -rf "$MKWATCH"; mkdir -p "$MKWATCH/bin" "$MKWATCH/files"
REAL_MKTEMP=$(command -v mktemp)
{ printf '%s\n' '#!/usr/bin/env bash' 'd=""' 'for a in "$@"; do [ "$a" = -d ] && d=-d; done' \
    "exec \"$REAL_MKTEMP\" \$d \"$MKWATCH/files/tmp.XXXXXXXXXX\""; } > "$MKWATCH/bin/mktemp"
chmod +x "$MKWATCH/bin/mktemp"
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true PATH="$MKWATCH/bin:$PATH"
left=$(find "$MKWATCH/files" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
created=$(find "$MKWATCH/files" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')
if [ "$A_RC" -eq 0 ] && [ "$left" -eq 0 ]; then v=1; else v=0; fi
verdict "action-enforces-house-rules-temp-files-removed-edge-1" "$v" \
  "expected exit 0 and no temp file left behind: the log and the two captured streams hold bundle content; got exit $A_RC and $left file(s) left${created:+ ($created)}" "$A_RC"

# A temp folder that cannot be written: mktemp fails, and with `set -e` that used to stop the step with mktemp's own
# message and no annotation. The job must say why, with a code the caller can assert. The shim below is that failure.
MKFAIL="$TMP/action-mktemp-fails"; rm -rf "$MKFAIL"; mkdir -p "$MKFAIL/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "mktemp: cannot create a temporary file" >&2' 'exit 1' > "$MKFAIL/bin/mktemp"
chmod +x "$MKFAIL/bin/mktemp"
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true PATH="$MKFAIL/bin:$PATH"
if [ "$A_RC" -eq 2 ] && grep -q '::error::.*temp folder .TMPDIR. is not writable' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-temp-file-creation-fails-edge-1" "$v" \
  "expected exit 2 and an ::error:: naming the temp folder when mktemp cannot create a file; got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# A python3 that is on PATH but broken: it prints nothing and exits 1, as a crash does. A crash is not an answer, so the
# job must fail with the parse message rather than read exit 1 as "no layer was skipped". A stub okf-check prints the
# report, so the broken interpreter is the only thing out of place (with the real tool on PATH it would fail first, on
# its own python, and the case would measure that instead).
SHIM="$TMP/shim"; rm -rf "$SHIM"; mkdir -p "$SHIM"
shim_py() { # <exit code>
  { printf '%s\n' '#!/usr/bin/env bash'; printf 'exit %s\n' "$1"; } > "$SHIM/python3"
  chmod +x "$SHIM/python3"
}
stub_check 'printf "%s\n" "{\"bundle\":\"x\",\"exit\":0,\"l2_profile\":\"ran\",\"layers_not_run\":[],\"skipped\":[\"L2 profile: forged\"]}"'
shim_py 1
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub" PATH="$SHIM:$PATH"
if [ "$A_RC" -eq 3 ] && grep -q '::error::okf-check --json did not give one readable report' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-broken-interpreter-edge-1" "$v" \
  "expected exit 3 naming the unreadable report when python3 crashes (exit 1); got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The opposite input: an interpreter that answers the parser's own table with "no layer was skipped" lets the job pass, so
# the case above measures the crash and not every shim.
stub_check 'printf "%s\n" "{\"bundle\":\"x\",\"exit\":0,\"l2_profile\":\"ran\",\"layers_not_run\":[],\"skipped\":[]}"'
{ printf '%s\n' '#!/usr/bin/env bash'; printf 'printf "concepts\\t1\\nL2 profile\\tno\\nL2 index\\tno\\nL2 graph\\tno\\n"\n'; } > "$SHIM/python3"
chmod +x "$SHIM/python3"
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub" PATH="$SHIM:$PATH"
if [ "$A_RC" -eq 0 ] && ! grep -q '::error::' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-interpreter-not-skipped-control-1" "$v" \
  "expected exit 0 and no ::error:: when the parser answers 'no layer was skipped'; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The negative is a GUARD, not a RED case: it passes on the release head too (the input was already false by default),
# and it exists so a fix cannot make the default "true" in silence. Its opposite input is the control above (exit 3), so
# the assertion is shown red rather than being true of every run: the same bundle whose house-rule layers are skipped
# passes here when require-house-rules is unset, and prints no ::error:: line.
act "$W" INPUT_BUNDLE=no-base INPUT_REQUIRE_HOUSE_RULES=
if [ "$A_RC" -eq 0 ] && ! grep -q '::error::house rules were required' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-enforces-house-rules-default-false-negative-1" "$v" \
  "expected exit 0 and no ::error::house rules line when require-house-rules is unset: the input's default stays false; got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The warning annotations must be the same in both output modes (the text mode already has them).
act "$W" INPUT_BUNDLE=empty
if [ "$A_RC" -eq 0 ] && grep -q '::warning::okf-check found 0 concepts' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-prints-every-warning-control-1" "$v" \
  "the text mode must print the 0-concepts warning (the control for the --json case); got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

act "$W" INPUT_BUNDLE=empty INPUT_ARGS=--json
if [ "$A_RC" -eq 0 ] && grep -q '::warning::okf-check found 0 concepts' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-prints-every-warning-zero-concepts-happy-1" "$v" \
  "expected exit 0 and the '0 concepts' ::warning:: with --json; got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

act "$W" INPUT_BUNDLE=no-base INPUT_ARGS=--json
if [ "$A_RC" -eq 0 ] && grep -q '::warning::okf-check skipped a layer (L2 profile)' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-prints-every-warning-skipped-layer-happy-1" "$v" \
  "expected exit 0 and a skipped-layer ::warning:: naming L2 profile, with --json; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The negative: a clean bundle (every layer ran, one concept) prints no warning at all, in both modes. It is the opposite
# input of the cases above: if "skipped a layer" were printed unconditionally, this one would go red.
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/warn-clean-text.log"; warn_clean_rc=$A_RC
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if [ "$warn_clean_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
   && ! grep -q '::warning::' "$TMP/warn-clean-text.log" 2>/dev/null \
   && ! grep -q '::warning::' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-prints-every-warning-negative-1" "$v" \
  "expected no ::warning:: line in either mode for a bundle whose every layer ran; got text exit $warn_clean_rc, --json exit $A_RC: $(grep '::warning::' "$A_LOG" 2>/dev/null | head -2 | tr '\n' ' ')" "$A_RC"

# A note named " L2 index         SKIPPED.md" puts the words of a skipped-layer line into the report, where the finding
# lines are indented. Nobody skipped a layer, so no warning may name one — the text mode used a loose pattern and warned.
act "$W" INPUT_BUNDLE=leading-space INPUT_REQUIRE_HOUSE_RULES=true
cp "$A_LOG" "$TMP/warn-forged-text.log"; warn_forged_rc=$A_RC
act "$W" INPUT_BUNDLE=leading-space INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json
if ! grep -Eq '^ +L2 index +SKIPPED' "$TMP/warn-forged-text.log" 2>/dev/null; then
  case_precondition_failed "action-prints-every-warning-forged-name-edge-1" \
    "the forged note name is not in the text report, so the trap this case measures was never planted: $(head -3 "$TMP/warn-forged-text.log" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$warn_forged_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && ! grep -q '::warning::okf-check skipped a layer' "$TMP/warn-forged-text.log" 2>/dev/null \
     && ! grep -q '::warning::okf-check skipped a layer' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-prints-every-warning-forged-name-edge-1" "$v" \
    "expected no skipped-layer ::warning:: in either mode: the line the trap plants is a finding, not a skipped layer; got text exit $warn_forged_rc, --json exit $A_RC: $(grep '::warning::' "$A_LOG" 2>/dev/null | head -2 | tr '\n' ' ')" "$A_RC"
fi

# Every layer okf-check can skip from the command line gets its own warning: the three are named in one document, and all
# three must come back, and nothing else. A loop that still held the old list (L2 profile, L2 index, L3 staleness) would
# answer two, and a loop with one name too many would answer four.
stub_check 'printf "%s\n" "{\"bundle\":\"x\",\"exit\":0,\"concepts\":1,\"l2_profile\":\"skipped\",\"layers_not_run\":[],\"skipped\":[\"L2 profile: r\",\"L2 index: r\",\"L2 graph: r\"]}"'
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=false INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub"
n_warn=$(grep -c '^::warning::okf-check skipped a layer' "$A_LOG" 2>/dev/null); [ -n "$n_warn" ] || n_warn=0
all3=1
for layer in 'L2 profile' 'L2 index' 'L2 graph'; do
  grep -qF "::warning::okf-check skipped a layer ($layer)" "$A_LOG" 2>/dev/null || all3=0
done
if [ "$A_RC" -eq 0 ] && [ "$n_warn" -eq 3 ] && [ "$all3" -eq 1 ]; then v=1; else v=0; fi
verdict "action-prints-every-warning-every-layer-edge-1" "$v" \
  "expected one ::warning:: per skippable layer, three in all (L2 profile, L2 index, L2 graph); got $n_warn: $(grep '::warning::' "$A_LOG" 2>/dev/null | head -5 | tr '\n' ' ')" "$A_RC"

# L2 graph answering nothing readable: okf-check prints COULD NOT RUN, records it in layers_not_run[] and still exits 0,
# so the job passes with nothing checked. Both modes must warn, in the same words. (The other COULD NOT RUN sites return
# EXIT_DEP and fail the job: L3 staleness at okf-check:2478/2533, and the layer runner.)
GRAPHBIN="$TMP/okfmem"; rm -rf "$GRAPHBIN"; mkdir -p "$GRAPHBIN"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in --help) echo "OKF Agent Memory 0.0 stub"; exit 0 ;; esac' 'echo "not a report"' 'exit 0' > "$GRAPHBIN/okf"
chmod +x "$GRAPHBIN/okf"
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=false OKF_MEMORY_BIN="$GRAPHBIN/okf"
cp "$A_LOG" "$TMP/warn-graph-text.log"; graph_text_rc=$A_RC
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=false INPUT_ARGS=--json OKF_MEMORY_BIN="$GRAPHBIN/okf"
if ! grep -q 'L2 graph         COULD NOT RUN' "$TMP/warn-graph-text.log" 2>/dev/null; then
  case_precondition_failed "action-prints-every-warning-graph-could-not-run-edge-1" \
    "the stub okf-memory did not reach the COULD NOT RUN path, so this case measured nothing: $(grep 'L2 graph' "$TMP/warn-graph-text.log" 2>/dev/null | head -2 | tr '\n' ' ')"
else
  if [ "$graph_text_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && [ "$(grep -c '^::warning::okf-check could not run a layer (L2 graph)' "$TMP/warn-graph-text.log" 2>/dev/null)" = 1 ] \
     && [ "$(grep -c '^::warning::okf-check could not run a layer (L2 graph)' "$A_LOG" 2>/dev/null)" = 1 ] \
     && [ "$(grep -c '(L2 graph)' "$TMP/warn-graph-text.log" 2>/dev/null)" = 1 ] \
     && [ "$(grep -c '(L2 graph)' "$A_LOG" 2>/dev/null)" = 1 ]; then v=1; else v=0; fi
  verdict "action-prints-every-warning-graph-could-not-run-edge-1" "$v" \
    "expected exactly one ::warning:: naming L2 graph in both modes, and it must be the 'could not run' one; got text exit $graph_text_rc, --json exit $A_RC: $(grep '::warning::' "$A_LOG" 2>/dev/null | head -3 | tr '\n' ' ')" "$A_RC"
fi

# The parser's answer must be a table. An interpreter that prints anything else and exits 0 is not an answer: the
# enforcement fails CLOSED instead of reading the missing rows as "no layer was skipped". The case below the next one
# (`interpreter-not-skipped-control-1`) is the opposite input: a real table with three "no" rows passes.
stub_check 'printf "%s\n" "{\"concepts\":1,\"skipped\":[],\"layers_not_run\":[]}"'
{ printf '%s\n' '#!/usr/bin/env bash' 'printf "garbage\n"' 'exit 0'; } > "$SHIM/python3"; chmod +x "$SHIM/python3"
act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub" PATH="$SHIM:$PATH"
if [ "$A_RC" -eq 3 ] && grep -q '::error::okf-check --json did not give one readable report (the parser gave no table row for concepts)' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-prints-every-warning-garbage-table-edge-1" "$v" \
  "expected exit 3 naming the missing table row when python3 prints something that is not a table; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# The parse needs layers_not_run as a list; one case per wrong shape, so removing that check turns three cases red.
for shape in absent null string; do
  case "$shape" in
    absent) stub_check 'printf "%s\n" "{\"skipped\":[]}"' ;;
    null)   stub_check 'printf "%s\n" "{\"skipped\":[],\"layers_not_run\":null}"' ;;
    string) stub_check 'printf "%s\n" "{\"skipped\":[],\"layers_not_run\":\"L2 graph\"}"' ;;
  esac
  act "$W" INPUT_BUNDLE=clean INPUT_REQUIRE_HOUSE_RULES=true INPUT_ARGS=--json GITHUB_ACTION_PATH="$W/stub"
  if [ "$A_RC" -eq 3 ] && grep -q '::error::okf-check --json did not give one readable report (the report has no layers_not_run list)' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-prints-every-warning-layers-not-run-$shape-edge-1" "$v" \
    "expected exit 3 naming the missing layers_not_run list when it is $shape; got exit $A_RC: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"
done

# A note named "L1 conformance   PASS   0 concepts.md" spells the 0-concepts line where findings are printed. The bundle
# has one concept and the layers ran, so neither mode may claim 0 concepts.
mkb_counts "$W/forged-concepts" 2; printf '%s\n' "$NOTE_CLEAN" > "$W/forged-concepts/n.md"
printf -- '---\ntype: Lesson\ntitle: Conformance\ndescription: A note.\nstatus: stable\ntags: [x]\nstale_after: "2099-01-01"\n---\n\nSee [[missing]].\n' \
  > "$W/forged-concepts/L1 conformance   PASS   0 concepts.md"
mk_okf_base "$W/forged-concepts"
act "$W" INPUT_BUNDLE=forged-concepts INPUT_REQUIRE_HOUSE_RULES=false
cp "$A_LOG" "$TMP/warn-forged-concepts-text.log"; fc_text_rc=$A_RC
act "$W" INPUT_BUNDLE=forged-concepts INPUT_REQUIRE_HOUSE_RULES=false INPUT_ARGS=--json
if ! grep -Eq '^ +L1 conformance +PASS +0 concepts' "$TMP/warn-forged-concepts-text.log" 2>/dev/null; then
  case_precondition_failed "action-prints-every-warning-forged-concepts-edge-1" \
    "the forged note name is not in the text report, so the trap this case measures was never planted: $(head -3 "$TMP/warn-forged-concepts-text.log" 2>/dev/null | tr '\n' ' ')"
else
  if [ "$fc_text_rc" -eq 0 ] && [ "$A_RC" -eq 0 ] \
     && ! grep -q '::warning::okf-check found 0 concepts' "$TMP/warn-forged-concepts-text.log" 2>/dev/null \
     && ! grep -q '::warning::okf-check found 0 concepts' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
  verdict "action-prints-every-warning-forged-concepts-edge-1" "$v" \
    "expected no 0-concepts ::warning:: in either mode: the bundle has two files and this is a note name; got text exit $fc_text_rc, --json exit $A_RC: $(grep '::warning::' "$A_LOG" 2>/dev/null | head -2 | tr '\n' ' ')" "$A_RC"
fi

# report-args with a value (--conserve HEAD): the report runs, and the job keeps exit 0. The fixture's gate run must
# pass on its own (a clean note), so the case measures the report's effect and not the gate's verdict.
AREP="$W/act-report"
mkdir -p "$AREP"
g init -q "$AREP"
g -C "$AREP" config user.email t@t
g -C "$AREP" config user.name t
mkb "$AREP/B"
printf '%s\n' '---' 'type: Lesson' 'title: Rule' 'description: A rule.' 'status: stable' 'tags: [x]' 'generated:' \
  '  by: human:dana' '  at: "2026-01-01"' 'verified:' '  - by: human:finance-owner' '    at: "2026-02-01"' \
  'stale_after: "2099-01-01"' '---' '' 'Rule X holds' > "$AREP/B/n.md"
printf 'archive/\n' > "$AREP/B/.okfignore"
g -C "$AREP" add -A
g -C "$AREP" commit -q -m base
printf '%s\n' '---' 'type: Lesson' 'title: Rule' 'description: A rule.' 'status: stable' 'tags: [x]' 'generated:' \
  '  by: human:dana' '  at: "2026-01-01"' 'verified:' '  - by: human:finance-owner' '    at: "2026-02-01"' \
  'stale_after: "2099-01-01"' '---' '' 'Rule Y holds' > "$AREP/B/n.md"
mkdir -p "$AREP/B/archive"
printf 'Rule X holds\n' > "$AREP/B/archive/x.md"

act "$AREP" INPUT_BUNDLE=B 'INPUT_REPORT_ARGS=--conserve HEAD'
if [ "$A_RC" -eq 0 ] && grep -Eq '^  Conserve +' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-report-mode-with-value-exit-code-happy-1" "$v" \
  "expected exit 0 with the Conserve report in the log: a report never decides the job; got exit $A_RC: $(head -2 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

if grep -Eq '^  Conserve +' "$A_LOG" 2>/dev/null; then v=1; else v=0; fi
verdict "action-report-mode-with-value-report-happy-1" "$v" \
  "expected the Conserve report in the log; got: $(head -3 "$A_LOG" 2>/dev/null | tr '\n' ' ')" "$A_RC"

# --- a verified list of bare strings (slice trust-reads-a-verified-list-of-bare-strings) ----------------------------
section "a verified list of bare strings"
run_in "$REPO" "$CHECK" B/bare --strict-trust
if [ "$RC" -eq 1 ]; then v=1; else v=0; fi
verdict "trust-bare-string-verified-list-happy-1" "$v" \
  "expected exit 1: the bare string is a human: claim on a draft note, so --strict-trust must not pass it; got exit $RC: $(shown)" "$RC"

# The negative: without the flag the same finding is printed and the run passes (the flag decides severity only).
run_in "$REPO" "$CHECK" B/bare
if [ "$RC" -eq 0 ]; then v=1; else v=0; fi
verdict "trust-bare-string-verified-list-negative-1" "$v" \
  "expected exit 0 without --strict-trust, the Trust warning still printed; got exit $RC: $(shown)" "$RC"

# The control: the same note with the review written as a mapping, which the mapping reader already reports.
run_in "$REPO" "$CHECK" B/mapped --strict-trust
if [ "$RC" -eq 1 ]; then v=1; else v=0; fi
verdict "trust-bare-string-verified-list-control-1" "$v" \
  "expected exit 1 for the mapping form of the same note; got exit $RC: $(shown)" "$RC"

# --- a later release: a --repo that is a subfolder of the repository (carried to 0.9.60) ----------------
section "a later release: a --repo inside the repository"
mkdir -p "$W/subrepo/src"
g init -q "$W/subrepo"
g -C "$W/subrepo" config user.email t@t
g -C "$W/subrepo" config user.name t
printf 'x\n' > "$W/subrepo/src/a"
g -C "$W/subrepo" add -A
g -C "$W/subrepo" commit -q -m base
SUBSHA=$(g -C "$W/subrepo" rev-parse HEAD)
mkb "$W/subnotes"
printf '%s\n' '---' 'type: Lesson' 'title: Pinned' 'description: Pinned citation.' 'status: stable' 'tags: [x]' \
  'generated:' '  by: human:dana' '  at: "2026-01-01"' 'stale_after: "2099-01-01"' '---' '' "commit $SUBSHA" > "$W/subnotes/n.md"
run_in "$W" "$VERIFY" subnotes --repo subrepo/src --strict
if [ "$RC" -eq 0 ]; then v=1; else v=0; fi
verdict "repo-is-a-repository-subfolder-happy-1" "$v" \
  "expected exit 0: a folder inside the repository is the repository to search; got exit $RC: $(shown)" "$RC"

# --- a bundle path with a space, through the command line each skill documents ---------------------------
# A SKILL.md is not a script: the host substitutes the argument text into the skill body and the model copies the code
# fence it reads into Bash, so the line a skill documents IS the command a user runs. The seam is that line, filled the
# way the skill's own rule says to fill it, and run by a shell:
#   - the words before the first `--` word are the bundle path, and the skill shows it inside double quotes: a quoted
#     placeholder ("<bundle-dir>") keeps its quotes and takes the value inside them;
#   - a word after a flag that takes a path (--repo, --file, --deleted) is quoted the same way, as the rule says;
#   - an unquoted placeholder (<bundle-dir>) takes the path raw, which is what a model filling that slot writes;
#   - $ARGUMENTS takes the WHOLE argument text as typed, one raw string with no quotes added — flags included — which
#     is what the host substitutes (Claude Code skills docs, "Available string substitutions": the placeholder "always
#     expands to the full argument string as typed"). A fence that quotes the whole placeholder therefore puts the
#     path AND the flags in one argument, and this is what the with-a-flag case catches.
# No case reaches inside a function, and the expected exit codes are literals measured on the fixed forms.
section "a bundle path with a space, through the command line each skill documents"
SKILLS="$TREE/plugin/skills"
PLUGIN_ROOT="$TREE/plugin"
# The fixtures: a bundle, a vault and an export target, each with a space in its name, and a repository beside them.
mkb "$W/sp ace/b"
printf -- '---\ntype: Lesson\ntitle: N\ndescription: A note.\nstatus: stable\ntags: [x]\ngenerated:\n  by: human:dana\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$W/sp ace/b/n.md"
VAULT="$W/my vault"; mkdir -p "$VAULT"
printf '# Index\n\nsee [[note]]\n' > "$VAULT/index.md"
printf '# Note\n\nbody\n' > "$VAULT/note.md"
EXPORT_OUT="$W/out dir"
SP_REPO="$W/sp ace/repo"; mkdir -p "$SP_REPO"
printf 'x\n' > "$SP_REPO/a.txt"
g init -q "$SP_REPO"
g -C "$SP_REPO" config user.email t@t
g -C "$SP_REPO" config user.name t
g -C "$SP_REPO" add -A
g -C "$SP_REPO" commit -q -m base

# doc_line <skill> <must contain>: the first line of the skill's first bash fence that holds <must contain>, with an
# inline `#` note removed. Empty when the skill documents no such line (a case then measures nothing).
doc_line() {
  awk -v want="$2" '
    /^[ \t]*```/ { fenced = !fenced; next }
    fenced && index($0, want) { sub(/[ \t]+#.*$/, ""); print; exit }
  ' "$SKILLS/$1/SKILL.md"
}
# fill <line> <word>...: the arguments in the slots the skill left (see the comment above this section). The words
# before the first `--` word are the path; the rest are flags, and a flag that takes a path has its value quoted.
fill() {
  local line="$1"; shift
  local -a lead=() tail=(); local w seen=0 raw=""
  for w in "$@"; do
    raw="$raw${raw:+ }$w"
    case "$w" in
      --*) seen=1; tail+=("$w"); continue ;;
    esac
    if [ "$seen" -eq 0 ]; then lead+=("$w"); continue; fi
    case "${tail[${#tail[@]}-1]}" in
      --repo|--file|--deleted) tail+=("\"$w\"") ;;
      *) tail+=("$w") ;;
    esac
  done
  # The patterns sit in variables: an unquoted variable is read as a regex by [[ =~ ]], while a pattern written inline
  # with quotes in it is read as a literal string, which silently matches nothing. The replacement is done with prefix
  # and suffix removal, not ${var/pat/repl}: on bash 3.2 (macOS) that form drops the quote characters from both the
  # pattern and the replacement, so a quoted placeholder keeps its old quotes and gains new ones.
  local quoted='"[<][^<>]*[>]"' plain='[<][^<>]*[>]' token pre
  if [[ "$line" == *'$ARGUMENTS'* ]]; then
    pre="${line%%'$ARGUMENTS'*}"; line="$pre$raw${line#*'$ARGUMENTS'}"
  else
    for w in ${lead[@]+"${lead[@]}"}; do
      if [[ "$line" =~ $quoted ]]; then
        token="${BASH_REMATCH[0]}"; pre="${line%%"$token"*}"; line="$pre\"$w\"${line#*"$token"}"
      elif [[ "$line" =~ $plain ]]; then
        token="${BASH_REMATCH[0]}"; pre="${line%%"$token"*}"; line="$pre$w${line#*"$token"}"
      fi
    done
    [ "${#tail[@]}" -eq 0 ] || line="$line ${tail[*]}"
  fi
  printf '%s\n' "$line"
}
# doc_filled <skill> <must contain> <word>...: the documented line, with its slots filled.
doc_filled() { local sk="$1" want="$2"; shift 2; fill "$(doc_line "$sk" "$want")" "$@"; }
# run_line <dir> <shell line>: run it there through a shell, the way a code fence is run, and keep the exit code.
run_line() {
  ( cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c "$2" ) > "$OUT" 2>&1
  RC=$?
}
# precondition <case key> <skill> <must contain>: the case cannot measure anything without a line to run.
precondition() {
  [ -n "$(doc_line "$2" "$3")" ] && return 0
  case_precondition_failed "$1" "the $2 skill documents no line holding '$3', so this case measured nothing"
  return 1
}

# /okf:check: the bundle path in double quotes is one argument, and the run reports on the folder it names.
if precondition "skill-command-quotes-the-path-check-happy-1" check '/scripts/okf-check'; then
  run_line "$W" "$(doc_filled check '/scripts/okf-check' "$W/sp ace/b")"
  if [ "$RC" -eq 0 ] && grep -qF "$W/sp ace/b" "$OUT"; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-check-happy-1" "$v" \
    "expected exit 0 and a report on '$W/sp ace/b'; got exit $RC: $(shown)" "$RC"
fi

# The same line with the flag the skill's own table documents. The flag is one of the arguments, so it lands after the
# quoted path in a correct fence and inside the quotes in a fence that quotes the whole $ARGUMENTS — where the tool
# then gets one argument and refuses it (exit 64). This is the case a whole-quote fence cannot pass.
if precondition "skill-command-quotes-the-path-check-with-a-flag-happy-1" check '/scripts/okf-check'; then
  run_line "$W" "$(doc_filled check '/scripts/okf-check' "$W/sp ace/b" --json)"
  if [ "$RC" -eq 0 ] && [ "$(head -c 1 "$OUT")" = '{' ]; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-check-with-a-flag-happy-1" "$v" \
    "expected exit 0 and one JSON document: the path is one argument and the flag still reaches the tool as a flag; got exit $RC: $(shown)" "$RC"
fi

# The control for the design, spelled out and not read from a skill: one quote around path AND flag is the obvious fix
# and it breaks every flag, so no fence may use that shape. The cases above read the real SKILL.md files, so that shape
# fails there too when a fence is written that way.
run_line "$W" "\"$CHECK\" \"sp ace/b --json\""
if [ "$RC" -eq 64 ] && grep -q 'is not a directory' "$OUT"; then v=1; else v=0; fi
verdict "skill-command-quotes-the-path-whole-quoted-control-1" "$v" \
  "expected exit 64 'is not a directory': one quote around path AND flag is not the fix; got exit $RC: $(shown)" "$RC"

# The negative: a path with no space still goes through the same documented line unchanged.
if precondition "skill-command-quotes-the-path-plain-path-negative-1" check '/scripts/okf-check'; then
  run_line "$REPO" "$(doc_filled check '/scripts/okf-check' "B/clean")"
  if [ "$RC" -eq 0 ]; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-plain-path-negative-1" "$v" \
    "expected exit 0 on a path with no space; got exit $RC: $(shown)" "$RC"
fi

# /okf:okf (the overview skill) documents the same checkpoint line.
if precondition "skill-command-quotes-the-path-overview-happy-1" okf '/scripts/okf-check'; then
  run_line "$W" "$(doc_filled okf '/scripts/okf-check' "$W/sp ace/b")"
  if [ "$RC" -eq 0 ] && grep -qF "$W/sp ace/b" "$OUT"; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-overview-happy-1" "$v" \
    "expected exit 0 and a report on '$W/sp ace/b'; got exit $RC: $(shown)" "$RC"
fi

# The overview's primary fence is a check and nothing more: a flag written into it would change every run (--json would
# print JSON where the skill means a check, and a flag can refuse an argument the user passed). No word starting with
# `--` belongs in it. This reads the real file, so a fence that grows one fails here.
if precondition "skill-command-quotes-the-path-overview-fence-without-a-flag-control-1" okf '/scripts/okf-check'; then
  fenced_line=$(doc_line okf '/scripts/okf-check')
  case " $fenced_line " in
    *' --'*) v=0 ;;
    *) v=1 ;;
  esac
  verdict "skill-command-quotes-the-path-overview-fence-without-a-flag-control-1" "$v" \
    "the overview's primary fence line must carry no flag; got: $fenced_line" "none"
fi

# /okf:verify: the same bundle, verified.
if precondition "skill-command-quotes-the-path-verify-happy-1" verify '/scripts/okf-verify'; then
  run_line "$W" "$(doc_filled verify '/scripts/okf-verify' "$W/sp ace/b")"
  if [ "$RC" -eq 0 ] && grep -qF "$W/sp ace/b" "$OUT"; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-verify-happy-1" "$v" \
    "expected exit 0 and a report on '$W/sp ace/b'; got exit $RC: $(shown)" "$RC"
fi

# /okf:verify with a --repo whose folder holds a space: the skill's rule covers a path that follows a flag, so the
# repository must be searched as one folder (the report names it, and never says NONE).
if precondition "skill-command-quotes-the-path-verify-with-a-repo-happy-1" verify '/scripts/okf-verify'; then
  run_line "$W" "$(doc_filled verify '/scripts/okf-verify' "$W/sp ace/b" --repo "$SP_REPO")"
  if [ "$RC" -eq 0 ] && grep -q 'repos searched: repo' "$OUT" && ! grep -q 'repos searched: NONE' "$OUT"; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-verify-with-a-repo-happy-1" "$v" \
    "expected exit 0 and 'repos searched: repo': the --repo path is one argument; got exit $RC: $(shown)" "$RC"
fi

# /okf:export: two paths, both with a space, and the bundle must land in the folder named.
if precondition "skill-command-quotes-the-path-export-happy-1" export '/scripts/okf-export'; then
  run_line "$W" "$(doc_filled export '/scripts/okf-export' "$VAULT" "$EXPORT_OUT")"
  if [ "$RC" -eq 0 ] && [ -f "$EXPORT_OUT/index.md" ]; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-export-happy-1" "$v" \
    "expected exit 0 and a bundle in '$EXPORT_OUT'; got exit $RC: $(shown)" "$RC"
fi

# /okf:setup: --init-house-rules writes into the bundle named, not into a folder split off its name.
if precondition "skill-command-quotes-the-path-setup-init-house-rules-happy-1" setup '--init-house-rules'; then
  mkdir -p "$W/sp ace/starter"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$W/sp ace/starter/index.md"
  run_line "$W" "$(doc_filled setup '--init-house-rules' "$W/sp ace/starter")"
  if [ "$RC" -eq 0 ] && [ -f "$W/sp ace/starter/okf-base.yaml" ]; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-setup-init-house-rules-happy-1" "$v" \
    "expected exit 0 and okf-base.yaml inside '$W/sp ace/starter'; got exit $RC: $(shown)" "$RC"
fi

# The same write through --init-ignore: the other init flag takes a bundle path, and it splits the same way.
if precondition "skill-command-quotes-the-path-setup-init-ignore-happy-1" setup '--init-ignore'; then
  mkdir -p "$W/sp ace/ignore"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$W/sp ace/ignore/index.md"
  run_line "$W" "$(doc_filled setup '--init-ignore' "$W/sp ace/ignore")"
  if [ "$RC" -eq 0 ] && [ -f "$W/sp ace/ignore/.okfignore" ]; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-setup-init-ignore-happy-1" "$v" \
    "expected exit 0 and .okfignore inside '$W/sp ace/ignore'; got exit $RC: $(shown)" "$RC"
fi

# /okf:explain: one note, named by a path that also holds a space.
if precondition "skill-command-quotes-the-path-explain-file-happy-1" explain '--file'; then
  run_line "$W" "$(doc_filled explain '--file' "$W/sp ace/b" "$W/sp ace/b/n.md")"
  if [ "$RC" -eq 0 ]; then v=1; else v=0; fi
  verdict "skill-command-quotes-the-path-explain-file-happy-1" "$v" \
    "expected exit 0: one note checked, no finding; got exit $RC: $(shown)" "$RC"
fi

# --- the known-gaps file and the suite name the same cases -----------------------------------------------------
section "the known-gaps file"
if [ -f "$GAPS" ]; then
  grep -v '^#' "$GAPS" > "$TMP/gapkeys.txt" 2>/dev/null
  if [ -s "$TMP/gapkeys.txt" ]; then
    LC_ALL=C sort -c "$TMP/gapkeys.txt" 2>/dev/null \
      && ok "invocation-forms-known-gaps-sorted-edge-1" \
      || bad "invocation-forms-known-gaps-sorted-edge-1" "the known-gaps lines are not sorted by case key: $(LC_ALL=C sort -c "$TMP/gapkeys.txt" 2>&1 | head -1)"
  else
    ok "invocation-forms-known-gaps-sorted-edge-1"
  fi
  stale=""
  while IFS=$'\t' read -r key reason slug seen; do
    case "$key" in ''|'#'*) continue ;; esac
    grep -qxF "$key" "$EXERCISED" || stale="$stale $key"
  done < "$GAPS"
  [ -z "$stale" ] \
    && ok "invocation-forms-known-gaps-line-names-a-case-edge-1" \
    || bad "invocation-forms-known-gaps-line-names-a-case-edge-1" "known-gaps lines that name no case:$stale — a typo, or a case that was renamed"
  n_gaps=$(grep -c -v '^#' "$GAPS" 2>/dev/null); [ -n "$n_gaps" ] || n_gaps=0
  printf '  known gaps: %s\n' "$n_gaps"
else
  skip "invocation-forms-known-gaps-sorted-edge-1 — no known-gaps file at $GAPS" "restore plugin/tests/invocation-forms-known-gaps.tsv"
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
