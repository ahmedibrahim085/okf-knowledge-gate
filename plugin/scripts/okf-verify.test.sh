#!/usr/bin/env bash
# Tests for okf-verify (L4 — truth verification).
#
# L1/L2 answer "is this well-formed?". L4 answers "is what it SAYS still true?".
# Conformance is not correctness: a concept citing a commit that no longer exists
# is perfectly conformant and quietly wrong.
#
# The load-bearing rule under test is the distinction between REFUTED and
# UNRESOLVED. "I could not check" must never render as "it is false" — that is
# lessons/negative-claims-state-scope.md, and getting it wrong would make L4
# worse than useless.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
VERIFY="$HERE/okf-verify"
REALPY=$(command -v python3)   # captured before any PATH stub shadows it
PASS=0; FAIL=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfverify)
trap 'rm -rf "$TMP" ${LOOPDIR:+"$LOOPDIR"} >/dev/null 2>&1' EXIT   # LOOPDIR is set later; the trap is live before it exists. Silent: the gates read a suite's last line as its summary, and a wrapped rm can print
trap 'exit 130' INT
trap 'exit 143' TERM

# M6: the REFUTED tests need a parent directory that EXISTS and is NOT ephemeral.
# Anchoring on $HERE broke the suite when it was run from a copy under /tmp — a
# CI that checks out to an ephemeral path went red against correct code. Pick the
# first workable base instead of assuming one, and say so if none exists.
# NONEPH only has to EXIST; the D-1 loop dir is created in it, so that one also has to be WRITABLE. An ephemeral HOME and a read-only
# /usr/local left no such folder and the suite aborted with rc 2 after 260 lines: LOOPBASE is the first folder that is both.
NONEPH=""; LOOPBASE=""
for cand in "$HOME" /usr/local /usr; do
  case "$cand" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/var/tmp/*|/private/var/tmp/*|/dev/shm/*) continue ;;
  esac
  [ -d "$cand" ] || continue
  [ -n "$NONEPH" ] || NONEPH="$cand"
  [ -w "$cand" ] && { LOOPBASE="$cand"; break; }
done

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }

# An intermittent 5-failure mode has been observed THREE times in this suite —
# twice by reviewers, once here — and never reproduced on demand. One real cause
# was found and fixed (git timeouts misclassified as "found nothing", Z-4), but
# the flake outlived it, so that was not the whole story and it should not have
# been called root-caused.
#
# What can be done without a reproduction is make the NEXT occurrence explain
# itself. Every failure snapshots the state a diagnosis needs — the tool's own
# output, whether the git fixture is still intact, load, and PATH — to a file
# OUTSIDE the trap-cleaned temp dir, whose path the summary prints. Three
# sightings have produced no diagnosis; the fourth should not be wasted too.
FAILCTX=$(mktemp "${TMPDIR:-/tmp}/okf-verify-failure.XXXXXX")
capture_failure() {
  {
    printf '\n===== %s =====\n' "$1"
    printf 'detail: %s\n' "$2"
    printf 'when:   %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    printf 'load:   %s\n' "$(uptime 2>/dev/null | sed 's/.*load/load/')"
    printf 'git:    %s\n' "$(command -v git || echo 'NOT ON PATH')"
    printf 'fixture repo still valid: %s\n' \
      "$(git -C "$REPO" rev-parse --short HEAD 2>&1 | head -1)"
    printf 'REAL_SHA at start: %s\n' "${REAL_SHA:-<unset>}"
    printf '%s\n' '--- last okf-verify output ---'   # %s: a leading -- is an option to printf
    [ -f "$TMP/out.txt" ] && cat "$TMP/out.txt" || echo '(no out.txt)'
  } >> "$FAILCTX" 2>&1
}
# bad_hard: a failure that is ALWAYS a failure. Used by the assertions that
# deliberately exercise git-unavailable handling, so the infra guard below can
# never swallow them.
bad_hard() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; capture_failure "$1" "$2"; }
bad() {
  # A git that could not RUN is a machine failure, not a defect in okf-verify.
  # Under heavy load these assertions went red five at a time and green on every
  # rerun; two review rounds spent time on it before the cause was found. A
  # suite that blames the tool for the machine costs whoever reads it next.
  # This is a SKIP, which the summary now counts — never a silent pass.
  if [ -f "$TMP/out.txt" ] && grep -qE 'could not query|git timed out|git could not be executed' "$TMP/out.txt"; then
    skip "$1 — git could not run here (machine, not okf-verify)"
    return 0
  fi
  FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"
  capture_failure "$1" "$2"
}
SKIPPED=0
# A skip is COVERAGE THAT DID NOT RUN, and it was invisible in the summary: a
# run that quietly tested less printed the same "0 failed" as a run that tested
# everything. Measured this session — E-7d skipped 8/12 in one configuration and
# 0/12 in another — so "0 failed" alone has never been a complete claim. Count
# them and print them; then a green line means green AND complete.
skip() { SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"; }

run() { "$VERIFY" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
has() { grep -q "$1" "$TMP/out.txt"; }

# Verdict-COLUMN helpers. `has "CONFIRMED"` also matched the summary line
# "CONFIRMED n   REFUTED n   UNRESOLVED n", which every run prints, so six
# assertions passed regardless of the actual verdict — four mutations survived
# them. Anchor on the column instead.
vok()         { grep -qE '^  ok  '        "$TMP/out.txt" && ok "$1" || bad "$1" "no CONFIRMED verdict line"; }
vrefuted()    { grep -qE '^  REFUTED '    "$TMP/out.txt" && ok "$1" || bad "$1" "no REFUTED verdict line"; }
vunresolved() { grep -qE '^  unresolved ' "$TMP/out.txt" && ok "$1" || bad "$1" "no UNRESOLVED verdict line"; }


echo "okf-verify (L4) tests"

# --- a real git repo with a real commit, to cite truthfully ------------------
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'x\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt
git -C "$REPO" -c commit.gpgsign=false commit -qm "fix: a real commit to cite"
REAL_SHA=$(git -C "$REPO" rev-parse --short HEAD)

# X-1: the fixture is NEVER assumed. Every step above is quiet, so when the repo
# failed to build — git slow or unavailable under a loaded machine — REAL_SHA
# came out empty and TWENTY assertions failed, each reading as a defect in
# okf-verify. A reviewer filed it as a "transient flake" and moved on, which is
# the real cost: a broken fixture that presents as broken code burns the time of
# whoever next reads the suite. Exit 2 (could not run), never 1 (failures), so
# the two are distinguishable — the same rule the gate itself enforces.
if [ -z "$REAL_SHA" ] || ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  printf '  FIXTURE BROKEN — could not build the git repo this suite cites.\n' >&2
  printf '     Nothing below would be testing okf-verify; it would be testing the fixture.\n' >&2
  printf '     git: %s\n' "$(command -v git 2>/dev/null || echo 'NOT ON PATH')" >&2
  exit 2
fi

mkb() { mkdir -p "$1"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$1/index.md"; }

# --- HAPPY -------------------------------------------------------------------
B1="$TMP/b1"; mkb "$B1"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit %s.\n' "$REAL_SHA" > "$B1/c.md"
rc=$(run "$B1" --repo "$REPO")
[ "$rc" = "0" ] && ok "V-1 a resolvable SHA exits 0" || bad "V-1 a resolvable SHA exits 0" "exit $rc: $(head -3 "$TMP/out.txt" | tr '\n' ' ')"
vok "V-1 the SHA is reported CONFIRMED"

# an existing file path is a checkable claim too
B2="$TMP/b2"; mkb "$B2"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/f.txt` for the fix.\n' "$REPO" > "$B2/c.md"
rc=$(run "$B2" --repo "$REPO")
vok "V-2 an existing file path is CONFIRMED"

# --- NEGATIVE ----------------------------------------------------------------
# A path that does not exist IS refutable — the claim is checkable and false.
#
# The cited parent must be NON-EPHEMERAL, so $HERE (this script's own directory)
# rather than $TMP: mktemp puts fixtures under /var/folders, which the ephemeral
# rule correctly declines to refute. Using $TMP here made this test fail against
# CORRECT code — a fixture artifact, not a defect. Nothing is ever created at the
# cited path; only its absence is asserted.
B3="$TMP/b3"; mkb "$B3"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/definitely-not-here-xyz.txt`.\n' "$NONEPH" > "$B3/c.md"
rc=$(run "$B3" --repo "$REPO" --host-paths)
vrefuted "V-3 a missing file path is REFUTED"
[ "$rc" != "0" ] && ok "V-3 a refuted claim is a non-zero exit" || bad "V-3 refuted -> non-zero exit" "exit 0"

# THE LOAD-BEARING ONE. An unresolvable SHA means the repo was not searched or
# the history was rewritten. That is "I could not check", never "it is false".
B4="$TMP/b4"; mkb "$B4"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit deadbe3.\n' > "$B4/c.md"
rc=$(run "$B4" --repo "$REPO")
vunresolved "V-4 an unresolvable SHA is UNRESOLVED, not REFUTED"
# Anchor on the VERDICT COLUMN, not the bare word: the summary prints
# "REFUTED 0" and the legend explains what REFUTED means, so `grep REFUTED`
# matches a clean run too. Third instance this session of a marker that appears
# in both the success and failure text — see lessons/llm-green-tests-not-working-code.md.
grep -qE '^  REFUTED ' "$TMP/out.txt" && bad "V-4 an unresolvable SHA must NOT be called REFUTED" "a REFUTED verdict line was emitted" \
  || ok "V-4 an unresolvable SHA is never given a REFUTED verdict"
# POSITIVE as well: the summary line must be there, with its layout (a blank line before it, two spaces of indent). A negative
# check alone went blind when the summary was printed as "\x0a  CONFIRMED ..." (a layout character spelled as if it were a name).
grep -qE '^  CONFIRMED [0-9]+   REFUTED 0   UNRESOLVED [1-9]' "$TMP/out.txt" && ! grep -qE '^  (CONFIRMED|REFUTED) [1-9]+   REFUTED [1-9]|^  REFUTED [1-9]' "$TMP/out.txt" \
  && [ "$(grep -B1 -E '^  CONFIRMED [0-9]' "$TMP/out.txt" | head -1)" = "" ] \
  && ok "V-4 the summary counts confirm 0 refuted (the line is there: indented, after a blank line)" || bad "V-4 counts must show 0 refuted" "$(grep -n 'CONFIRMED' "$TMP/out.txt" | cat -v | head -2 | tr '\n' '|')"
[ "$rc" = "0" ] && ok "V-4 UNRESOLVED alone does not fail the run" || bad "V-4 UNRESOLVED does not fail" "exit $rc"

# --- EDGE --------------------------------------------------------------------
# A concept with nothing checkable must SAY so. Reporting it as a pass would
# make an unverifiable corpus look verified.
B5="$TMP/b5"; mkb "$B5"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nPure prose with no citation of any kind.\n' > "$B5/c.md"
rc=$(run "$B5" --repo "$REPO")
has "no checkable" && ok "V-5 a concept with no checkable claim says so" \
  || bad "V-5 no-checkable-claim is stated" "$(head -4 "$TMP/out.txt" | tr '\n' ' ')"

# History rewrite: the SHA is gone but the commit SUBJECT survives. This happened
# for real (code-knowledge-graphs, 2026-07-30) and orphaned every cited SHA.
B6="$TMP/b6"; mkb "$B6"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nOrphaned by a rewrite: `cafe123` "fix: a real commit to cite".\n' > "$B6/c.md"
rc=$(run "$B6" --repo "$REPO")
has "rewrite\|subject\|message" && ok "V-6 an orphaned SHA hints at the surviving commit subject" \
  || bad "V-6 orphaned SHA hints at commit subject" "$(head -5 "$TMP/out.txt" | tr '\n' ' ')"
# V-6b (okf-knowledge-gate#6, comment 2): a matching subject does not prove a rewrite. In the reported cases the commit lived in a
# repository that was not searched, and a short subject matches unrelated commits. The detail names BOTH explanations and the
# searched repositories, never "likely a history rewrite" alone; the verdict stays UNRESOLVED.
# The search matches the quoted text anywhere in a commit MESSAGE, so the detail says so, and names the third case: an unrelated
# commit whose message happens to contain it (0.9.33 review, finding 1).
{ has "rewritten" && has "not searched" && has "unrelated" && has "message contains" && has "searched: " && ! has "likely a history rewrite" && has "UNRESOLVED"; } \
  && ok "V-6b a matching commit message names three explanations (rewrite, a repository not searched, an unrelated match) and the searched repositories" \
  || bad "V-6b rewrite hint" "$(grep -i 'subject' "$TMP/out.txt" | head -2 | tr '\n' ' ' | cut -c1-300)"

# A bundle path with a space — the bug that produced two retracted statistics.
B7="$TMP/with space/b7"; mkb "$B7"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit %s.\n' "$REAL_SHA" > "$B7/c.md"
rc=$(run "$B7" --repo "$REPO")
[ "$rc" = "0" ] && ok "V-7 a bundle path containing a space works" || bad "V-7 spaced bundle path" "exit $rc"
vok "V-7 claims are still resolved on a spaced path"

# No repo given: SHAs cannot be checked at all. That is a stated limitation, not
# a clean bill of health.
B8="$TMP/b8"; mkb "$B8"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit %s.\n' "$REAL_SHA" > "$B8/c.md"
rc=$(run "$B8")
vunresolved "V-8 with no --repo, SHAs are UNRESOLVED and the scope is stated"

# V-10: a path inside a FENCED CODE BLOCK is a code literal, not a claim.
# Found live-firing on the real bundle: `const LOG = '/tmp/net-spy.log'` in an
# example script was REFUTED because /tmp exists and the file does not. The
# lesson never claimed the file existed — it told you where to write output.
# A tool that cries wolf gets ignored, so precision here is load-bearing.
#
# The fenced path MUST be non-ephemeral ($HERE, not $TMP). With $TMP the path
# lands under /var/folders, so the ephemeral rule alone renders it UNRESOLVED and
# the assertion passes whether or not fences are stripped — a test that cannot
# fail. Mutation testing (removing strip_code_fences) exposed exactly that: the
# mutant survived 17/17. Fourth tautological assertion found in this project.
B10="$TMP/b10"; mkb "$B10"
{ printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nRun this:\n\n'
  printf '```js\n'
  printf "const LOG = '%s/nope-not-real-xyz.log';\n" "$NONEPH"
  printf '```\n'
} > "$B10/c.md"
rc=$(run "$B10" --repo "$REPO")
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "V-10 a path inside a code fence is not a claim" "it was REFUTED — code literals are instructions, not assertions" \
  || ok "V-10 a path inside a code fence is not treated as a claim"

# V-11: ephemeral locations (/tmp, /var/folders) are transient by definition.
# Absence there proves nothing about whether the claim was ever true.
B11="$TMP/b11"; mkb "$B11"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nOutput lands at `/tmp/some-run-artifact.log` during the run.\n' > "$B11/c.md"
rc=$(run "$B11" --repo "$REPO")
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "V-11 an ephemeral /tmp path is not REFUTED" "absence in /tmp proves nothing" \
  || ok "V-11 an ephemeral /tmp path is not REFUTED"

# === FINDINGS FROM ADVERSARIAL REVIEW (2026-07-31) ==========================
# An independent reviewer REFUTED the central claim by producing merely-unchecked
# claims rendered as REFUTED via three routes. Root cause it identified: check_path
# treated `exists() == False` as proof of absence, when that is three distinct
# states — genuinely absent, unresolvable (ELOOP), and unreadable (raises).
# Only the first justifies REFUTED.

# D-1 CRITICAL: a symlink loop. The directory entry EXISTS (lexists is True) but
# exists() swallows ELOOP and returns False -> REFUTED. The tool asserted a file
# does not exist when it demonstrably does.
# The loop MUST live outside an ephemeral root: placed under $TMP (/var/folders)
# the ephemeral guard masks the loop bug and this test passes on broken code.
# Verified: lexists=True, exists()=False, parent exists => REFUTED. Fifth masked
# assertion in this project, all from fixture placement.
D1="$TMP/d1"; mkb "$D1"
# A unique directory per run: fixed names collided between parallel runs and a killed run
# left them behind for the next one (review round 1, 2026-10-14). Still under a non-ephemeral folder
# ($LOOPBASE), so the parent is non-ephemeral as M6 requires.
# Sweep dirs a SIGKILLed run left behind (a trap cannot run on kill -9). Only this suite's own
# name pattern, only directly under $LOOPBASE, only older than a day: a parallel live run is safe.
LOOPDIR=""
if [ -z "$LOOPBASE" ]; then
  # An ephemeral loop dir would mask the defect (see above), so the test does not run; it is not made to pass.
  skip "D-1 — no writable folder outside an ephemeral root (HOME, /usr/local, /usr): the loop test did not run (skip, not a pass)"
else
  find "$LOOPBASE" -maxdepth 1 -type d -name '.okfverify-d1.*' -mtime +0 -exec rm -rf {} + 2>/dev/null || :
  LOOPDIR=$(mktemp -d "$LOOPBASE/.okfverify-d1.XXXXXX") || { echo "okf-verify.test: cannot create a loop dir under $LOOPBASE" >&2; exit 2; }
  ln -sf "$LOOPDIR/d1_loopB.log" "$LOOPDIR/d1_loopA.log"
  ln -sf "$LOOPDIR/d1_loopA.log" "$LOOPDIR/d1_loopB.log"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/d1_loopA.log`.\n' "$LOOPDIR" > "$D1/c.md"
  run "$D1" >/dev/null
  grep -qE '^  REFUTED ' "$TMP/out.txt" \
    && bad "D-1 a symlink loop is not REFUTED" "entry exists (lexists true) but was called absent" \
    || ok "D-1 an unresolvable symlink loop is not REFUTED"
fi

# D-2 CRITICAL: an unreadable path crashed the run with a traceback, and the
# crash exit code (1) is indistinguishable from "REFUTED found". Every other
# concept in the bundle went unreported.
D2="$TMP/d2"; mkb "$D2"; mkdir -p "$TMP/d2locked"
printf 'x\n' > "$TMP/d2locked/secret.txt"; chmod 000 "$TMP/d2locked"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/d2locked/secret.txt`.\n' "$TMP" > "$D2/c.md"
printf -- '---\ntype: Lesson\ntitle: Other\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nplain\n' > "$D2/other.md"
run "$D2" >/dev/null
# Grep for the CRASH signal only. The fix deliberately names the exception type
# in its detail line ("cannot stat (PermissionError) — unreadable"), so matching
# the bare exception name flags the correct behaviour as a failure. A traceback,
# and the concept that follows going unreported, are the real symptoms.
grep -qi 'Traceback' "$TMP/out.txt" \
  && bad "D-2 an unreadable path does not crash the run" "traceback emitted" \
  || ok "D-2 an unreadable path does not crash the run"
grep -q 'other.md' "$TMP/out.txt" || grep -q 'no checkable' "$TMP/out.txt" \
  && ok "D-2 the rest of the bundle is still reported after an unreadable path" \
  || bad "D-2 the rest of the bundle is still reported" "the run aborted before other.md"
chmod 755 "$TMP/d2locked" 2>/dev/null

# D-3 HIGH: the ephemeral guard was a prefix test on the UNRESOLVED path, so the
# canonical macOS temp root (/private/var/folders, what realpath($TMPDIR) returns)
# and /var/tmp both fell through to REFUTED. Byte-identical location, two verdicts.
# The cited parent must EXIST, or the "parent missing" branch returns UNRESOLVED
# and the test passes without exercising the ephemeral rule at all. `pwd -P`
# gives the CANONICAL form of $TMP — on macOS /private/var/folders/... — which is
# a real, existing directory. Mutation M8 survived the fabricated-path version.
D3="$TMP/d3"; mkb "$D3"
D3_CANON=$(cd "$TMP" && pwd -P)
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nArtifacts: `%s/no-such-artifact.log` and `/var/tmp/run-xyz.log`.\n' "$D3_CANON" > "$D3/c.md"
run "$D3" >/dev/null
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "D-3 canonical + alternate temp roots are ephemeral" "one was REFUTED" \
  || ok "D-3 /private/var/folders and /var/tmp are treated as ephemeral"

# D-4 HIGH: FENCE toggled on ``` and ~~~ interchangeably, so a ~~~ block that
# DOCUMENTS a ``` fence untoggled at the inner fence and leaked its literals.
D4="$TMP/d4"; mkb "$D4"
{ printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nDocumenting markdown inside markdown:\n\n'
  printf '~~~markdown\n'
  printf '```js\n'
  printf "const LOG = '%s/d4-literal-not-a-claim.log';\n" "$NONEPH"
  printf '```\n'
  printf '~~~\n'
} > "$D4/c.md"
run "$D4" >/dev/null
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "D-4 a ~~~ block documenting a \`\`\` fence does not leak literals" "leaked and was REFUTED" \
  || ok "D-4 mismatched fence types do not leak code literals"

# D-5: 4-space indented code blocks are standard CommonMark and were not stripped.
D5="$TMP/d5"; mkb "$D5"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nExample:\n\n    LOG = "%s/d5-indented-literal.log"\n' "$NONEPH" > "$D5/c.md"
run "$D5" >/dev/null
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "D-5 an indented code block is not a claim" "it was REFUTED" \
  || ok "D-5 indented code blocks are not treated as claims"

# D-7: my own earlier probe tested BARE prose words and CSS colours and reported
# "clean". It never tested BACKTICKED hex-only English words, which the context
# regex accepts. Real SHAs essentially always contain a digit; these do not.
D7="$TMP/d7"; mkb "$D7"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nWords: `defaced`, `effaced`, `acceded`, `deadbeef`, `cafebabe`, `feedface`.\n' > "$D7/c.md"
run "$D7" >/dev/null
n=$(grep -cE '\[sha\]' "$TMP/out.txt" || true)
[ "${n:-0}" -eq 0 ] && ok "D-7 hex-only English words are not read as SHAs" \
  || bad "D-7 hex-only English words are not read as SHAs" "$n false positives"

# D-6: an unclosed fence runs to end-of-document under CommonMark — which is
# CORRECT parsing — but it silently blinds L4 for that concept. Correct is not
# the same as safe: the reader must be told the document ate its own claims.
D6="$TMP/d6"; mkb "$D6"
{ printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n'
  printf '```js\n'
  printf 'never closed\n'
  printf 'Fixed in commit %s.\n' "$REAL_SHA"
} > "$D6/c.md"
run "$D6" --repo "$REPO" >/dev/null
has "unclosed" && ok "D-6 an unclosed fence is reported, not silent" \
  || bad "D-6 unclosed fence is reported" "the rest of the concept was swallowed with no warning"

# D-8: the commonest citation form in the wild is a commit URL, and it matched
# nothing — the context word had to be followed by whitespace, and a URL has a
# slash. A tool that cannot see the usual citation is not verifying much.
D8="$TMP/d8"; mkb "$D8"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee https://github.com/o/r/commit/%s for the fix.\n' "$REAL_SHA" > "$D8/c.md"
run "$D8" --repo "$REPO" >/dev/null
vok "D-8 a commit URL is extracted and resolved"

# D-9: --strict is sold as "for a corpus that must stay checkable", yet a corpus
# with NOTHING checkable passed it. That is precisely the corpus it should catch.
D9="$TMP/d9"; mkb "$D9"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nPure prose, nothing checkable at all.\n' > "$D9/c.md"
rc=$(run "$D9" --repo "$REPO" --strict)
[ "$rc" != "0" ] && ok "D-9 --strict fails a wholly-uncheckable corpus" \
  || bad "D-9 --strict fails an uncheckable corpus" "exit 0 — the case --strict exists for"
rc=$(run "$D9" --repo "$REPO")
[ "$rc" = "0" ] && ok "D-9 without --strict an uncheckable corpus still passes" \
  || bad "D-9 non-strict unaffected" "exit $rc"

# --json must be parseable, for CI
rc=$(run "$B1" --repo "$REPO" --json)
python3 -c "import json,sys;json.load(open('$TMP/out.txt'))" 2>/dev/null \
  && ok "V-9 --json emits parseable JSON" || bad "V-9 --json parseable" "$(head -2 "$TMP/out.txt")"

# D-11: on a case-INSENSITIVE filesystem (APFS is, by default) `exists()`
# answers yes for a name that never appears on disk. A concept citing
# `Notes.MD` when the repo holds `notes.md` was reported CONFIRMED — the
# checker asserting it verified a path that is not there as written.
# Skipped, loudly, where the filesystem is case-sensitive: the defect cannot
# occur there and a passing assertion would mean nothing.
CI="$TMP/ci"; mkdir -p "$CI"; : > "$CI/notes.md"
if [ -e "$CI/NOTES.MD" ]; then
  BD11="$TMP/bd11"; mkb "$BD11"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/NOTES.MD` for detail.\n' "$CI" > "$BD11/c.md"
  run "$BD11" --repo "$REPO" >/dev/null
  grep -qE '^  ok  ' "$TMP/out.txt" \
    && bad "D-11 a case-variant path must not be CONFIRMED" \
           "reported CONFIRMED for NOTES.MD; only notes.md exists" \
    || ok "D-11 a case-variant path is not CONFIRMED on a case-insensitive filesystem"
else
  skip "D-11 — filesystem is case-sensitive, the defect cannot occur (skip, not a pass)"
fi

# D-11b: the same rule for a cited path that is a symlink whose TARGET is spelled in another case. On a case-insensitive
# disk the link resolves and was CONFIRMED; on Linux it dangles. Neither disk may CONFIRM it. The control (the target
# spelled as on disk) is CONFIRMED on both. Linux alone cannot go red here: the macOS run is the one that does.
BD11B="$TMP/bd11b"; mkb "$BD11B"; mkdir -p "$BD11B/d"; echo x > "$BD11B/d/src.txt"
ln -s SRC.TXT "$BD11B/d/l.txt"; ln -s src.txt "$BD11B/d/ok.txt"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/d/l.txt` for detail.\n' "$BD11B" > "$BD11B/c.md"
run "$BD11B" --repo "$REPO" >/dev/null
grep -qE '^  ok  ' "$TMP/out.txt" \
  && bad "D-11b a link whose target is spelled in another case must not be CONFIRMED" "reported CONFIRMED for d/l.txt -> SRC.TXT; only src.txt exists" \
  || ok "D-11b a link whose target is spelled in another case is not CONFIRMED"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/d/ok.txt` for detail.\n' "$BD11B" > "$BD11B/c.md"
run "$BD11B" --repo "$REPO" >/dev/null
vok "D-11c control: a link whose target is spelled as on disk is CONFIRMED"

# D-12: the path regex accepted MISMATCHED delimiters, so a stray apostrophe
# after a backtick made ordinary prose look like a cited path. That path is
# then absent, and the run manufactures a REFUTED — the one verdict this tool
# must never invent. Delimiters must pair.
# The parent MUST exist, or check_path returns UNRESOLVED for that reason
# instead and the assertion proves nothing — the first draft of this test
# passed against the unfixed regex for exactly that reason.
BD12="$TMP/bd12"; mkb "$BD12"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nThe fix landed in `%s/never-written-d12.md'"'"' as noted.\n' "$NONEPH" > "$BD12/c.md"
run "$BD12" --repo "$REPO" --host-paths >/dev/null
# guard: the matched-delimiter form of the same path MUST be REFUTED, else the
# test above could pass because the path was never extracted at all.
BD12M="$TMP/bd12m"; mkb "$BD12M"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nThe fix landed in `%s/never-written-d12.md` as noted.\n' "$NONEPH" > "$BD12M/c.md"
"$VERIFY" "$BD12M" --repo "$REPO" --host-paths >"$TMP/d12m.txt" 2>&1
grep -qE '^  REFUTED ' "$TMP/d12m.txt" \
  || bad "D-12 guard: the matched-delimiter form must still be REFUTED" \
         "no REFUTED for \`$NONEPH/never-written-d12.md\` — extraction is broken, not delimiter-strict"
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "D-12 mismatched delimiters must not yield a path claim" \
         "manufactured a REFUTED from \`path' — mismatched quote treated as a citation" \
  || ok "D-12 mismatched delimiters do not manufacture a REFUTED"

# D-13: the no-checkable-claim list stopped at 8 with no indication that more
# followed. Silent truncation reads as "that is all of them" — the same class
# of defect as a gate that skips a layer without saying so.
BD13="$TMP/bd13"; mkb "$BD13"
i=1; while [ "$i" -le 11 ]; do
  printf -- '---\ntype: Lesson\ntitle: T%s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nprose with nothing checkable in it at all\n' "$i" > "$BD13/c$i.md"
  i=$((i+1))
done
run "$BD13" --repo "$REPO" >/dev/null
listed=$(grep -c '^              ' "$TMP/out.txt")
grep -q 'and 3 more' "$TMP/out.txt" \
  && ok "D-13 a truncated no-claims list states how many it withheld" \
  || bad "D-13 truncation is silent" "printed $listed of 11 with no 'and N more'"

# G-13: okf-check's G-8 defect, in okf-verify. `Path.rglob` silently skips a
# directory it cannot read, so a concept whose claim is REFUTED simply vanishes
# and the run prints "no refuted claims" and exits 0. That is the worst possible
# shape of this failure: the tool whose entire purpose is to distinguish
# "checked and false" from "not checked" reported neither, and looked clean.
G13="$TMP/g13"; mkb "$G13"; mkdir -p "$G13/sub"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/definitely-not-here-g13.md` for detail.\n' "$NONEPH" > "$G13/sub/claim.md"
rc=$(run "$G13" --repo "$REPO" --host-paths)
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  || bad "G-13 control: the claim must be REFUTED while the subdir is readable" \
         "no REFUTED verdict — fixture is wrong, so the assertion below proves nothing"
chmod 000 "$G13/sub"
rc=$(run "$G13" --repo "$REPO" --host-paths)
chmod 755 "$G13/sub"
[ "$rc" != "0" ] \
  && ok "G-13 an unreadable subdirectory fails CLOSED (exit $rc)" \
  || bad "G-13 unreadable subdirectory failed OPEN" \
         "exit 0 and '$(grep -E 'no refuted|CONFIRMED' "$TMP/out.txt" | tail -1 | sed 's/^ *//')' — a subtree it never read"

# U-3: the G-13 guard lists `unreadable[:3]` and stops — the same silent cap
# D-13 removed from the no-claims list two commits earlier, reintroduced in the
# commit that copied G-8's guard across.
U3="$TMP/u3"; mkb "$U3"
i=1; while [ "$i" -le 5 ]; do mkdir -p "$U3/d$i"; : > "$U3/d$i/x.md"; chmod 000 "$U3/d$i"; i=$((i+1)); done
rc=$(run "$U3" --repo "$REPO")
i=1; while [ "$i" -le 5 ]; do chmod 755 "$U3/d$i"; i=$((i+1)); done
[ "$rc" != "0" ] || bad "U-3 control: unreadable dirs must fail closed" "exit 0 — G-13 regressed"
grep -qE 'and [0-9]+ more' "$TMP/out.txt" \
  && ok "U-3 okf-verify's unreadable list states how many it withheld" \
  || bad "U-3 okf-verify unreadable list truncates silently" \
         "listed $(grep -c 'unreadable:' "$TMP/out.txt") of 5 with no 'and N more'"

# Z-4: the root cause of an intermittent 4-failure mode seen twice in review,
# never reproduced on demand. `git()` caught SubprocessError — and
# TimeoutExpired is a SUBCLASS of it — returning (1, "") on timeout, which is
# byte-identical to "git ran fine and found nothing". Every non-zero rc then
# fell through to the message "not found in the searched repos": a positive
# factual claim, asserted when nothing was actually searched.
#
# In production that silently downgrades CONFIRMED to UNRESOLVED on a loaded
# machine — "checked and true" becoming "nobody checked" inside the one layer
# built to keep those apart. Third instance of one value carrying two meanings
# in this codebase, and the repo's own lesson names the class.
Z4="$TMP/z4"; mkb "$Z4"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit %s.\n' "$REAL_SHA" > "$Z4/c.md"
Z4D="$TMP/z4bin"; mkdir -p "$Z4D"
printf '#!/bin/sh\nexit 127\n' > "$Z4D/git"; chmod +x "$Z4D/git"   # git present but broken
PATH="$Z4D:$PATH" "$VERIFY" "$Z4" --repo "$REPO" >"$TMP/z4.txt" 2>&1
grep -q 'not found in the searched repos' "$TMP/z4.txt" \
  && bad_hard "Z-4 a broken git is reported as 'not found in the searched repos'" \
         "that is a claim about a search that never ran" \
  || ok "Z-4 a broken git is not reported as a completed search"
grep -qiE 'could not|unavailable|failed to run|git' "$TMP/z4.txt" \
  && ok "Z-4b the report says the lookup could not be performed" \
  || bad_hard "Z-4b a failed git lookup is invisible in the report" "$(grep -E '^  (ok|REFUTED|unresolved)' "$TMP/z4.txt" | head -1)"

# Z-5: the Z-4 fix recorded a failed lookup in the FIRST loop and not the
# second. The subject search — the history-rewrite fallback — just `continue`d
# on GIT_UNAVAILABLE, so a git that worked for `cat-file` and failed for
# `log --grep` left `unavailable` empty and the run still said "not found in the
# searched repos". The same false claim, one level down, introduced by the fix
# for it. Stub git so ONLY the subject search fails.
Z5="$TMP/z5"; mkb "$Z5"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit deadbe3, described as "a real commit subject to search for".\n' > "$Z5/c.md"
Z5D="$TMP/z5bin"; mkdir -p "$Z5D"
REALGIT=$(command -v git)
cat > "$Z5D/git" <<SH
#!/bin/sh
case "\$*" in *--grep*) exit 127 ;; esac
exec "$REALGIT" "\$@"
SH
chmod +x "$Z5D/git"
PATH="$Z5D:$PATH" "$VERIFY" "$Z5" --repo "$REPO" >"$TMP/z5.txt" 2>&1
grep -q 'not found in the searched repos' "$TMP/z5.txt" \
  && bad_hard "Z-5 a failed SUBJECT search still claims a completed search" \
         "the history-rewrite fallback never ran, yet the report says the repos were searched" \
  || ok "Z-5 a failed subject search is not reported as a completed search"

# Z-6: guards the OPPOSITE direction from Z-4, and exists because the Z-4 fix
# broke it. `cat-file -e` exits 128 for an absent object, so "treat anything but
# 0 or 1 as a failed lookup" turned every genuinely-missing SHA into "could not
# query" — the same false claim as Z-4, pointing the other way, and no test
# noticed because the VERDICT stayed UNRESOLVED in both cases. Only the detail
# text differed, and nothing asserted the detail text.
Z6="$TMP/z6"; mkb "$Z6"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit deadbe3.\n' > "$Z6/c.md"
run "$Z6" --repo "$REPO" >/dev/null
grep -q 'not found in the searched repos' "$TMP/out.txt" \
  && ok "Z-6 an absent SHA in a healthy repo says NOT FOUND, not 'could not query'" \
  || bad_hard "Z-6 an absent SHA is misreported as a failed lookup" \
         "$(grep -E '^ +(not found|could not)' "$TMP/out.txt" | head -1 | sed 's/^ *//')"

# Z-10: on the CONFIRMED path the follow-up subject lookup's return code was
# discarded, so when THAT call failed its error string was printed as the commit
# subject — "resolves in repo: git exited 128". The verdict was correct and the
# evidence printed beside it was fabricated, which is the more corrosive half:
# a reader checking the tool's work sees a plausible-looking subject that is
# really an error message. Stub git so cat-file succeeds and `log -1` fails.
Z10="$TMP/z10"; mkb "$Z10"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit %s.\n' "$REAL_SHA" > "$Z10/c.md"
Z10D="$TMP/z10bin"; mkdir -p "$Z10D"
# The stub must make the subject lookup return GIT_UNAVAILABLE, because that is
# the only path where git() carries a DETAIL STRING in the slot the caller reads
# as the subject. A plain non-zero exit yields empty stdout and leaks nothing —
# the first version of this fixture did that and passed against the unfixed
# code, proving nothing. A signal death is the cheapest way to reach it.
cat > "$Z10D/git" <<SH
#!/bin/sh
case "\$*" in *"--format=%s"*) kill -HUP \$\$ ;; esac
exec "$(command -v git)" "\$@"
SH
chmod +x "$Z10D/git"
# Asserted through --json, because the human report prints a detail line only
# for NON-confirmed verdicts — the leak is invisible there. The first version of
# this test grepped the human output and could not fail no matter what the code
# did. Where a defect is observable decides where the test has to look.
PATH="$Z10D:$PATH" "$VERIFY" "$Z10" --repo "$REPO" --json >"$TMP/z10.json" 2>/dev/null
if "$REALPY" -c "
import json,sys
d=json.load(open('$TMP/z10.json'))
leaks=[r['detail'] for r in d.get('results',[])
       if 'resolves in' in r.get('detail','')
       and any(s in r['detail'] for s in ('git exited','killed by signal','timed out','could not be executed'))]
raise SystemExit(1 if leaks else 0)
" 2>/dev/null; then
  ok "Z-10 a failed subject lookup never masquerades as the commit subject"
else
  bad_hard "Z-10 a failed subject lookup is rendered AS the commit subject" \
           "$("$REALPY" -c "import json;print([r['detail'] for r in json.load(open('$TMP/z10.json')).get('results',[])])" 2>/dev/null)"
fi

# Z-11: THE INTERMITTENT FAILURE, ROOT-CAUSED AT LAST. Three review sightings
# and forty-odd unreproduced runs blamed machine load. It was never load.
#
# `sha.isdigit()` dropped any all-digit SHA. Git's 7-character abbreviation is
# all digits with probability (10/16)^7 ≈ 3.7%, so roughly one fixture repo in
# twenty-seven produced a SHA this tool refused to see — and five assertions
# went red together, exactly the signature that was reported. The rule's own
# comment does the arithmetic for the NO-digit case (0.1%) and never did it for
# this one, which is 37x more likely and silently drops REAL claims.
#
# The disambiguator is the CONTEXT, not the charset: `commit 1234567` and
# `/commit/1234567` are unambiguous. A bare backticked `1234567` is not — it is
# as likely an issue number — so that one stays rejected.
Z11="$TMP/z11"; mkb "$Z11"
Z11R="$TMP/z11repo"; mkdir -p "$Z11R"
git -C "$Z11R" init -q; git -C "$Z11R" config user.email t@t; git -C "$Z11R" config user.name t
printf 'x\n' > "$Z11R/f.txt"; git -C "$Z11R" add f.txt
git -C "$Z11R" -c commit.gpgsign=false commit -qm "seed"
# an all-digit SHA that does NOT exist in the repo: the point is EXTRACTION,
# so UNRESOLVED is the right verdict — what must not happen is silence.
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in commit 1234567.\n' > "$Z11/c.md"
run "$Z11" --repo "$Z11R" >/dev/null
grep -q 'no checkable claim' "$TMP/out.txt" \
  && bad_hard "Z-11 an all-digit SHA in commit context is dropped as uncheckable" \
              "1234567 after the word 'commit' is a SHA; ~3.7% of real abbreviations look like this" \
  || ok "Z-11 an all-digit SHA in commit context is extracted, not silently dropped"
# and the ambiguous bare form must STILL be rejected, or precision is lost
Z11B="$TMP/z11b"; mkb "$Z11B"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee issue `1234567` for detail.\n' > "$Z11B/c.md"
run "$Z11B" --repo "$Z11R" >/dev/null
grep -q 'no checkable claim' "$TMP/out.txt" \
  && ok "Z-11b a bare backticked all-digit token is still not treated as a SHA" \
  || bad_hard "Z-11b an issue number was treated as a SHA" "precision lost: bare 1234567 must stay rejected"

# I-1: a note under a .okfignore path is not verified.
BI="$TMP/bi"; mkb "$BI"; mkdir -p "$BI/archive"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/ignored-not-here-xyz.txt`.\n' "$NONEPH" > "$BI/archive/c.md"
rc=$(run "$BI" --repo "$REPO" --host-paths)
[ "$rc" != "0" ] && ok "I-1a baseline: the refuted claim under archive/ fails without .okfignore" || bad "I-1a baseline" "exit 0"
cp "$B4/c.md" "$BI/live.md"; printf 'archive/\n' > "$BI/.okfignore"
rc=$(run "$BI" --repo "$REPO" --host-paths)
[ "$rc" = "0" ] && ok "I-1b the same claim under an ignored path is not verified (exit 0)" || bad "I-1b ignored path skipped" "exit $rc"

printf '*\n' > "$BI/.okfignore"
rc=$(run "$BI" --repo "$REPO" --host-paths)
[ "$rc" = "2" ] && ok "I-1c a .okfignore that excludes every note exits 2" || bad "I-1c all excluded" "exit $rc"

mkdir -p "$TMP/bi-out"; printf -- 'x\n' > "$TMP/bi-out/o.md"; ln -s "$TMP/bi-out" "$BI/lnk"
rc=$(run "$BI" --repo "$REPO" --host-paths)
[ "$rc" = "2" ] && ok "I-1d a symlinked directory cannot hide that everything was excluded" || bad "I-1d symlink bypass" "exit $rc"

# --- 0.9.2 F5: found by the 0.9.1 final review ----------------------------------------------------------------
note5() { # <bundle> <body line> — a one-note bundle citing <body line>
  mkb "$1"; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n%s\n' "$2" > "$1/n.md"
}
# (a) ".." in a cited path is resolved, not mistaken for a case difference
mkdir -p "$REPO/sub"
note5 "$TMP/f5a" "See \`$REPO/sub/../f.txt\` for the fix."
rc=$(run "$TMP/f5a" --repo "$REPO")
vok "V-F5a a cited path with .. that lands on an existing file inside --repo is CONFIRMED (not 'only a case-variant')"
# (b) a path outside the bundle and every --repo folder is not probed unless --host-paths is given
note5 "$TMP/f5b" "See \`$HERE/okf-verify.test.sh\` for the tool."
rc=$(run "$TMP/f5b" --repo "$REPO")
{ vunresolved "V-F5b a path outside the bundle and --repo is UNRESOLVED by default"; } 
grep -q 'outside the bundle' "$TMP/out.txt" && ok "V-F5b2 ... and the reason says it is outside the bundle and the --repo folders" || bad "V-F5b2 reason" "$(grep -n 'okf-verify' "$TMP/out.txt" | head -1)"
rc=$(run "$TMP/f5b" --repo "$REPO" --host-paths)
vok "V-F5b3 --host-paths checks it on disk (CONFIRMED)"
note5 "$TMP/f5b2" "See \`$HERE/no-such-file-here.xyz\` for the tool."
rc=$(run "$TMP/f5b2" --repo "$REPO")
{ grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt"; } && ok "V-F5b4 a missing outside path is UNRESOLVED too: no REFUTED/CONFIRMED difference leaks host files" || bad "V-F5b4 oracle" "$(grep -n 'no-such' "$TMP/out.txt" | head -1)"
# (c) a SHA missing from a shallow clone says so
SH="$TMP/cl5"; git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m "second commit for the shallow test"
git clone -q --depth 1 "file://$REPO" "$SH" 2>/dev/null
OLD_SHA=$(git -C "$REPO" rev-parse --short HEAD~1)
note5 "$TMP/f5c" "Fixed in commit $OLD_SHA."
rc=$(run "$TMP/f5c" --repo "$SH")
grep -qi 'shallow' "$TMP/out.txt" && ok "V-F5c a SHA absent from a shallow clone says the clone is shallow (git fetch --unshallow)" || bad "V-F5c shallow" "$(grep -n 'unresolved' "$TMP/out.txt" | head -1 | cut -c1-200)"

# --- 0.9.4 source repositories declared once in okf-base.yaml (okf_check.verify.repos) ---------------------------
# Git here is isolated from the host: a temp HOME and no system config, and no credential helper (rules/no-host-secret-stores-in-tests.md).
S1H="$TMP/s1home"; mkdir -p "$S1H"
export GIT_CONFIG_NOSYSTEM=1
decl() { # <bundle> <path>... — write <bundle>/okf-base.yaml declaring those repositories
  local b="$1"; shift
  { printf 'okf_check:\n  verify:\n    repos:\n'; for p in "$@"; do printf '      - path: %s\n' "$p"; done; } > "$b/okf-base.yaml"
}
# a second repository with its own commit, so "searched in both" can be told apart from "searched in one"
REPO2="$TMP/repo2"; mkdir -p "$REPO2"; git -C "$REPO2" init -q 2>/dev/null
git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
printf 'y\n' > "$REPO2/g.txt"; git -C "$REPO2" add g.txt
git -C "$REPO2" -c commit.gpgsign=false -c credential.helper= commit -qm "fix: a commit in the second repository"
SHA2=$(git -C "$REPO2" rev-parse --short HEAD)

# 0.9.50 okf-verify searches only the repositories given with --repo. A repository named in okf-base.yaml is not
# searched (the file arrives with the bundle, so it is not the user's choice); each one is named on its own line with
# the --repo flag to use instead, so it is never dropped in silence, and it never reads as REFUTED or CONFIRMED.
cfgline() { # <path part> — the number of "not searched ... pass --repo <path>" details naming it (an [repo] UNRESOLVED line must exist)
  grep -qE '^  unresolved .*\[repo\]' "$TMP/out.txt" || { echo 0; return; }
  grep -F 'okf_check.verify.repos is not searched since 0.9.50; to search it, pass --repo' "$TMP/out.txt" | grep -cF -- "$1"; }

# S1-H1: a declared repository is not searched: its SHA is UNRESOLVED, the entry is named with --repo, exit 0
note5 "$TMP/s1h1" "Fixed in commit $REAL_SHA."; decl "$TMP/s1h1" "$REPO"
rc=$(run "$TMP/s1h1")
{ [ "$rc" = "0" ] && ! grep -qE '^  ok  ' "$TMP/out.txt" && grep -q 'repos searched: NONE' "$TMP/out.txt" && [ "$(cfgline "$REPO")" = "1" ]; } \
  && ok "RV-1 (S1-H1) a repository named in okf-base.yaml is not searched; one line names it and the --repo flag (exit 0)" \
  || bad "RV-1 (S1-H1) config repo not searched" "rc=$rc $(head -8 "$TMP/out.txt" | tr '\n' ' ')"

# S1-H2: the same SHA is CONFIRMED when the repository is given with --repo
note5 "$TMP/s1h2" "Fixed in commit $REAL_SHA and in commit $SHA2."; decl "$TMP/s1h2" "$REPO"
rc=$(run "$TMP/s1h2" --repo "$REPO2")
{ [ "$(grep -cE '^  ok  ' "$TMP/out.txt")" = "1" ] && grep -qE "^  ok  .*$SHA2" "$TMP/out.txt"; } \
  && ok "RV-2 (S1-H2) only the --repo repository is searched: its SHA is CONFIRMED, the config repo's SHA is not" \
  || bad "RV-2 (S1-H2) --repo only" "$(grep -E '^  (ok|unresolved)' "$TMP/out.txt" | tr '\n' ' ')"

# S1-N1/N2: a declared path that does not exist, or is not a git repository, is named the same way; it is never looked at
mkdir -p "$TMP/s1-plain"
note5 "$TMP/s1n1" "Fixed in commit $REAL_SHA."; decl "$TMP/s1n1" "$TMP/no-such-repo-dir" "$TMP/s1-plain"
rc=$(run "$TMP/s1n1")
{ [ "$rc" = "0" ] && [ "$(cfgline no-such-repo-dir)" = "1" ] && [ "$(cfgline s1-plain)" = "1" ]; } \
  && ok "RV-3 (S1-N1/N2) a missing or non-git declared path gets the same one line, exit 0" \
  || bad "RV-3 (S1-N1/N2) missing/non-git declared path" "rc=$rc $(head -8 "$TMP/out.txt" | tr '\n' ' ')"
rc=$(run "$TMP/s1n1" --strict)
[ "$rc" = "1" ] && ok "RV-3 (S1-N1) under --strict an unsearched config repo fails the run (it is UNRESOLVED, not a pass)" || bad "RV-3 strict" "exit $rc"

# S1-E1: the suggested --repo path is the one the entry names, read from the bundle folder
mkdir -p "$TMP/s1rel"; git clone -q "$REPO" "$TMP/s1rel/svc" 2>/dev/null
note5 "$TMP/s1rel/b" "Fixed in commit $REAL_SHA."; decl "$TMP/s1rel/b" "../svc"
rc=$(cd / && run "$TMP/s1rel/b")
{ ! grep -qE '^  ok  ' "$TMP/out.txt" && grep -qF -- "--repo $TMP/s1rel/b/../svc" "$TMP/out.txt"; } \
  && ok "RV-5 (S1-E1) a relative declared path is not searched; the line names --repo <bundle>/../svc" \
  || bad "RV-5 (S1-E1) relative path hint" "$(head -8 "$TMP/out.txt" | tr '\n' ' ')"

# S1-E2: a repository named in okf-base.yaml AND given with --repo is searched once, with no "not searched" line
note5 "$TMP/s1e2" "Fixed in commit $REAL_SHA."; decl "$TMP/s1e2" "$REPO"
rc=$(run "$TMP/s1e2" --repo "$REPO/.")
n=$(grep -oE 'repos searched: .*' "$TMP/out.txt" | tr ',' '\n' | grep -c "$(basename "$REPO")")
{ [ "$n" = "1" ] && grep -qE '^  ok  ' "$TMP/out.txt" && ! grep -q 'not searched' "$TMP/out.txt"; } \
  && ok "RV-6 (S1-E2) a repository declared and passed with --repo is searched once and not reported" \
  || bad "RV-6 (S1-E2) searched once" "$(head -6 "$TMP/out.txt" | tr '\n' ' ')"

# The read routes the advisory names: a line citation into the declared repository's committed file and its untracked
# .md, and an absolute path, are not resolved through a config-named repository (no CONFIRMED, no REFUTED).
CR="$TMP/s1cr"; mkdir -p "$CR/docs"; git -C "$CR" init -q; printf 'a\nb\nc\n' > "$CR/docs/t.md"
git -C "$CR" add docs/t.md; git -C "$CR" -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c credential.helper= commit -qm c
CRS=$(git -C "$CR" rev-parse --short HEAD); printf 'x\ny\n' > "$CR/docs/u.md"
note5 "$TMP/s1cr-b" "See docs/t.md:3 @$CRS and docs/u.md:2 and $CR/docs/u.md:1."; decl "$TMP/s1cr-b" "$CR"
rc=$(run "$TMP/s1cr-b")
{ [ "$rc" = "0" ] && ! grep -qE '^  (ok  |REFUTED)' "$TMP/out.txt"; } \
  && ok "RV-34 committed, untracked and absolute citations are not resolved through a config-named repository" \
  || bad "RV-34 config repo read routes" "rc=$rc $(grep -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ')"

# S1-N3: an okf-base.yaml that cannot be read, or whose declaration is not a list of {path: str}, stops the run (exit 2) with ONE line
# naming the file and the problem. Ignoring it would read as "no repositories declared" and the SHAs would say "no repository searched".
badbase() { # <id> <label> <yaml text> — a one-note bundle with that okf-base.yaml; run it; expect exit 2, one line, naming the file
  note5 "$TMP/s1n3-$1" "Fixed in commit $REAL_SHA."; printf '%s\n' "$3" > "$TMP/s1n3-$1/okf-base.yaml"
  rc=$(run "$TMP/s1n3-$1")
  if [ "$rc" = "2" ] && [ "$(wc -l < "$TMP/out.txt" | tr -d ' ')" = "1" ] && grep -q 'okf-base.yaml' "$TMP/out.txt" && ! grep -qE '^  (ok|unresolved|REFUTED)' "$TMP/out.txt"; then
    ok "RV-7 (S1-N3) $2: exit 2, one line, names okf-base.yaml"
  else
    bad "RV-7 (S1-N3) $2" "exit $rc, $(wc -l < "$TMP/out.txt" | tr -d ' ') line(s): $(head -3 "$TMP/out.txt" | tr '\n' ' ')"
  fi
}
badbase a "YAML that does not parse" 'okf_check: ['
badbase b "repos that is a string, not a list" $'okf_check:\n  verify:\n    repos: ../svc'
badbase c "an entry with no path" $'okf_check:\n  verify:\n    repos:\n      - name: svc'
badbase d "a path that is not a string" $'okf_check:\n  verify:\n    repos:\n      - path: 42'
badbase e "okf_check that is not a mapping" 'okf_check: yes'
badbase f "a top level that is not a mapping" '- just
- a list'
if [ "$(id -u)" != "0" ]; then
  note5 "$TMP/s1n3-g" "Fixed in commit $REAL_SHA."; decl "$TMP/s1n3-g" "$REPO"; chmod 000 "$TMP/s1n3-g/okf-base.yaml"
  rc=$(run "$TMP/s1n3-g"); chmod 644 "$TMP/s1n3-g/okf-base.yaml"
  [ "$rc" = "2" ] && grep -q 'okf-base.yaml' "$TMP/out.txt" && ok "RV-7 (S1-N3) an unreadable okf-base.yaml: exit 2, names the file" || bad "RV-7 (S1-N3) unreadable okf-base.yaml" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
else
  skip "RV-7 (S1-N3) unreadable okf-base.yaml — running as root, chmod 000 does not stop the read (skip, not a pass)"
fi
# an okf-base.yaml that declares nothing, or has no okf_check key, is fine: L2 owns that file and most bundles never mention okf_check
note5 "$TMP/s1n3-h" "Fixed in commit $REAL_SHA."; printf 'okf_version: "0.2"\nbase:\n  name: X\n' > "$TMP/s1n3-h/okf-base.yaml"
rc=$(run "$TMP/s1n3-h" --repo "$REPO")
[ "$rc" = "0" ] && vok "RV-7 (S1-N3) an okf-base.yaml with no okf_check key is not an error" || bad "RV-7 (S1-N3) okf-base.yaml without okf_check" "exit $rc"

# --- 0.9.4 review round 1: ONE schema for the okf_check block, enforced by both tools ----------------------
# An unknown key is an error: a typo such as `verify.repo` otherwise ran with "repos searched: NONE" and exit 0 -- a declared
# repository list silently switched off. okf-check enforces the same rules (okf-check.test.sh LT-52 is the parity table).
badbase g "a typo'd key under verify (repo for repos)" $'okf_check:\n  verify:\n    repo:\n      - path: .'
grep -q 'okf_check.verify.repo' "$TMP/out.txt" && ok "RV-16 the error names the unknown key okf_check.verify.repo" || bad "RV-16 names the key" "$(head -2 "$TMP/out.txt" | tr '\n' ' ')"
badbase i "an unknown key inside a repository entry" $'okf_check:\n  verify:\n    repos:\n      - path: .\n        nmae: x'
grep -q 'nmae' "$TMP/out.txt" && ok "RV-16 ... and names the unknown entry key" || bad "RV-16 names the entry key" "$(head -2 "$TMP/out.txt" | tr '\n' ' ')"
badbase j "an unknown key directly under okf_check" $'okf_check:\n  colour: red'
badbase k "okf_check that is empty (null)" 'okf_check:'
badbase l "verify that is empty (null)" $'okf_check:\n  verify:'
badbase m "repos as a list of strings" $'okf_check:\n  verify:\n    repos: [.]'
badbase n "a path that is an empty string" $'okf_check:\n  verify:\n    repos:\n      - path: ""'
# invalid UTF-8 is an error here as in okf-check (it used to be read with errors="replace" there)
note5 "$TMP/s1n3-o" "Fixed in commit $REAL_SHA."; printf 'okf_check:\n  verify:\n    repos:\n      - path: \377\n' > "$TMP/s1n3-o/okf-base.yaml"
rc=$(run "$TMP/s1n3-o"); [ "$rc" = "2" ] && grep -q 'okf-base.yaml' "$TMP/out.txt" && ok "RV-16 invalid UTF-8 in okf-base.yaml: exit 2, names the file" || bad "RV-16 invalid UTF-8" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
# valid shapes stay valid
note5 "$TMP/s1n3-p" "Fixed in commit $REAL_SHA."; printf 'okf_check: {}\n' > "$TMP/s1n3-p/okf-base.yaml"
rc=$(run "$TMP/s1n3-p" --repo "$REPO"); [ "$rc" = "0" ] && ok "RV-16 an empty okf_check mapping is valid" || bad "RV-16 empty mapping" "exit $rc"

# --check-config: the shared validator, called by okf-check. Silent and exit 0 when the block is fine; one error line and exit 2 otherwise.
note5 "$TMP/cc1" "Fixed in commit $REAL_SHA."; decl "$TMP/cc1" "$REPO"
rc=$(run "$TMP/cc1" --check-config)
{ [ "$rc" = "0" ] && [ ! -s "$TMP/out.txt" ]; } && ok "RV-17 --check-config on a valid block: exit 0, no output, no verdicts" || bad "RV-17 --check-config valid" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
note5 "$TMP/cc2" "x"; rc=$(run "$TMP/cc2" --check-config)
{ [ "$rc" = "0" ] && [ ! -s "$TMP/out.txt" ]; } && ok "RV-17 --check-config with no okf-base.yaml: exit 0, no output" || bad "RV-17 --check-config no manifest" "exit $rc"
note5 "$TMP/cc3" "x"; printf 'okf_check:\n  verify:\n    repo: []\n' > "$TMP/cc3/okf-base.yaml"
rc=$(run "$TMP/cc3" --check-config)
{ [ "$rc" = "2" ] && [ "$(wc -l < "$TMP/out.txt" | tr -d ' ')" = "1" ] && grep -q 'okf_check.verify.repo' "$TMP/out.txt"; } && ok "RV-17 --check-config on a bad block: one error line, exit 2" || bad "RV-17 --check-config invalid" "exit $rc: $(head -3 "$TMP/out.txt" | tr '\n' ' ')"
# --- RV-24: an {enum: [...]} schema node (okf_check.deprecated_requires) takes only the listed values
note5 "$TMP/cc4" "x"; printf 'okf_check:\n  deprecated_requires: superseded_by\n' > "$TMP/cc4/okf-base.yaml"
rc=$(run "$TMP/cc4" --check-config); [ "$rc" = "0" ] && ok "RV-24 an enum node accepts its listed value" || bad "RV-24 enum valid" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
note5 "$TMP/cc5" "x"; printf 'okf_check:\n  deprecated_requires: superseded-by\n' > "$TMP/cc5/okf-base.yaml"
rc=$(run "$TMP/cc5" --check-config)
{ [ "$rc" = "2" ] && grep -q 'okf_check.deprecated_requires: "superseded-by" is not one of: superseded_by' "$TMP/out.txt"; } \
  && ok "RV-24 an enum node refuses another value, naming the value and the allowed ones (exit 2)" || bad "RV-24 enum invalid" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
# the offending value is shown as JSON (true, null, "x "), not as a Python repr (True, None): review F-D
for c in "cc6|true|true" "cc7||null" "cc8|\"x \"|\"x \""; do
  id=${c%%|*}; rest=${c#*|}; val=${rest%%|*}; shown=${rest#*|}
  note5 "$TMP/$id" "x"; printf 'okf_check:\n  deprecated_requires: %s\n' "$val" > "$TMP/$id/okf-base.yaml"
  rc=$(run "$TMP/$id" --check-config)
  { [ "$rc" = "2" ] && grep -qF "okf_check.deprecated_requires: $shown is not one of" "$TMP/out.txt"; } \
    && ok "RV-24 the refused value '$val' is shown as JSON: $shown" || bad "RV-24 JSON value $id" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
done

# --- 0.9.4 review round 2: a declared path that cannot be resolved is UNRESOLVED 'not searched' (0.9.50), never a crash ---------------------
# `~nosuchuser/x` made expanduser() raise RuntimeError and an unreadable parent made exists() raise PermissionError: a traceback and exit 1,
# and exit 1 means "a claim was REFUTED". Since 0.9.50 the entry is not searched; it is still reported (UNRESOLVED, the
# --repo hint) and the run goes on (exit 0, no REFUTED, no traceback).
unres() { # <label> <bundle> — the run for <bundle> (already made) must report that declared repo as UNRESOLVED 'not searched', in text and in --json
  local lbl="$1" b="$2" rc1 rc2
  rc2=$(run "$b" --repo "$REPO" --json)
  { [ "$rc2" = "0" ] && ! grep -q 'Traceback' "$TMP/out.txt" && grep -q '"kind": "repo"' "$TMP/out.txt" && grep -q 'not searched since 0.9.50' "$TMP/out.txt" && ! grep -q '"verdict": "REFUTED"' "$TMP/out.txt"; } \
    && ok "RV-18 $lbl, --json: UNRESOLVED 'not searched', exit 0" || bad "RV-18 $lbl --json" "exit $rc2: $(head -6 "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
  rc1=$(run "$b" --repo "$REPO")
  { [ "$rc1" = "0" ] && ! grep -q 'Traceback' "$TMP/out.txt" && grep -qE '^  unresolved .*\[repo\]' "$TMP/out.txt" && grep -q 'not searched since 0.9.50' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt"; } \
    && ok "RV-18 $lbl: UNRESOLVED 'not searched', exit 0, no traceback" || bad "RV-18 $lbl" "exit $rc1: $(head -6 "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
  vok "RV-18 $lbl: the other (--repo) repository is still searched"
}
note5 "$TMP/u1" "Fixed in commit $REAL_SHA."; decl "$TMP/u1" "~nosuchuser_zz/x"
HOME="$S1H" unres "a '~user' that does not exist" "$TMP/u1"
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$TMP/u2lock/sub"; chmod 000 "$TMP/u2lock"
  note5 "$TMP/u2" "Fixed in commit $REAL_SHA."; decl "$TMP/u2" "$TMP/u2lock/sub"
  unres "a declared path under an unreadable directory" "$TMP/u2"
  chmod 755 "$TMP/u2lock"
else
  skip "RV-18 a declared path under an unreadable directory — running as root, chmod 000 does not stop the read (skip, not a pass)"
fi
# --- 0.9.5 path:line @sha citations (sha + path; the line) ------------------------------------------------
# One claim per citation: `<path>:<line>[-<line>] @<sha>` or `... at <sha>`. The sha is resolved in the searched repos, then the path is
# looked up in that commit's tree. Fixture: a repository whose FIRST commit lacks the cited file, so "exists at that commit" differs from "exists now".
CREPO="$TMP/crepo"; mkdir -p "$CREPO"; git -C "$CREPO" init -q 2>/dev/null
git -C "$CREPO" config user.email t@t; git -C "$CREPO" config user.name t
printf 'readme\n' > "$CREPO/README"; git -C "$CREPO" add README
git -C "$CREPO" -c commit.gpgsign=false -c credential.helper= commit -qm "docs: first commit, no source yet"
C1=$(git -C "$CREPO" rev-parse --short HEAD)
mkdir -p "$CREPO/src" "$CREPO/x" "$CREPO/y"
seq 1 20 > "$CREPO/src/a.py"; printf 'p\n' > "$CREPO/x/dup.py"; printf 'q\n' > "$CREPO/y/dup.py"
git -C "$CREPO" add src x y
git -C "$CREPO" -c commit.gpgsign=false -c credential.helper= commit -qm "feat: add the source files"
C2=$(git -C "$CREPO" rev-parse --short HEAD)
cite() { # <dir> <citation text> — a one-note bundle with that citation
  note5 "$1" "Evidence: $2"; }
verdict_line() { grep -E '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt" | head -1; }

# S2-H2 / S2-H1 forms: `@sha` with the full path, `at sha` with a line range and a suffix path
cite "$TMP/c1" "\`src/a.py:10 @$C2\`"
rc=$(run "$TMP/c1" --repo "$CREPO")
vok "RV-8 (S2-H2) 'path:line @sha' with the full path is CONFIRMED"
grep -q "$C2" "$TMP/out.txt" && grep -q 'src/a.py' "$TMP/out.txt" && ok "RV-8 (S2-H2) the detail shows the sha and the path" || bad "RV-8 detail" "$(cat "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
cite "$TMP/c2" "see a.py:10-15 at $C2 for the loop"
rc=$(run "$TMP/c2" --repo "$CREPO")
vok "RV-8 (S2-H2) 'a.py:10-15 at sha' (line range, suffix path) is CONFIRMED"
[ "$(grep -cE '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt")" = "1" ] && ok "RV-8 (S2-H2) a citation is ONE claim, not a sha claim plus a path claim" || bad "RV-8 one claim" "$(grep -E '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' '|')"

cite "$TMP/c2b" "a.py:10 @\`$C2\`"
rc=$(run "$TMP/c2b" --repo "$CREPO")
[ "$(grep -cE '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt")" = "1" ] && ok "RV-8 (S2-H2) a backticked sha inside the citation is not ALSO counted as a bare sha claim" || bad "RV-8 backticked sha" "$(grep -E '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' '|')"

# S2-N1: the path does not exist at that commit -> REFUTED, and the detail says the path part failed
cite "$TMP/c3" "\`src/nope.py:3 @$C2\`"
rc=$(run "$TMP/c3" --repo "$CREPO")
vrefuted "RV-9 (S2-N1) a path missing at that commit is REFUTED"
grep -q 'path part failed' "$TMP/out.txt" && ok "RV-9 (S2-N1) the detail says the path part failed" || bad "RV-9 detail" "$(grep -A1 REFUTED "$TMP/out.txt" | tr '\n' ' ')"
[ "$rc" = "1" ] && ok "RV-9 (S2-N1) a refuted citation is a non-zero exit" || bad "RV-9 exit" "exit $rc"
# "at that commit": the file exists NOW but not in the cited (first) commit
cite "$TMP/c3b" "\`src/a.py:3 @$C1\`"
rc=$(run "$TMP/c3b" --repo "$CREPO")
vrefuted "RV-9 (S2-N1) a file that exists at HEAD but not at the cited commit is REFUTED"

# S1 x S2 seam (0.9.50): a citation does not resolve against a repository named only in okf-base.yaml: not CONFIRMED and
# not REFUTED (a missing path at that commit would otherwise tell the bundle's author what the repository holds)
cite "$TMP/seam1" "\`src/a.py:10 @$C2\`"; decl "$TMP/seam1" "$CREPO"
rc=$(run "$TMP/seam1")
{ [ "$rc" = "0" ] && ! grep -qE '^  (ok  |REFUTED)' "$TMP/out.txt"; } && ok "RV-19 (S1 x S2) a path:line @sha citation is not resolved against a config-named repository" \
  || bad "RV-19 (S1 x S2) config seam" "rc=$rc $(grep -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ')"
cite "$TMP/seam2" "\`src/nope.py:3 @$C2\`"; decl "$TMP/seam2" "$CREPO"
rc=$(run "$TMP/seam2")
{ [ "$rc" = "0" ] && ! grep -qE '^  (ok  |REFUTED)' "$TMP/out.txt"; } && ok "RV-19 (S1 x S2) ... nor REFUTED when the path is missing at that commit" \
  || bad "RV-19 (S1 x S2) config seam refuted" "rc=$rc $(grep -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ')"

# S2-N3: the sha is in no searched repository -> UNRESOLVED, never REFUTED
cite "$TMP/c4" "\`src/a.py:10 @deadbe3\`"
rc=$(run "$TMP/c4" --repo "$CREPO")
vunresolved "RV-10 (S2-N3) a sha in no searched repository is UNRESOLVED"
grep -qE '^  REFUTED ' "$TMP/out.txt" && bad "RV-10 (S2-N3) must not be REFUTED" "a REFUTED line was emitted" || ok "RV-10 (S2-N3) ... and is never REFUTED"
[ "$rc" = "0" ] && ok "RV-10 (S2-N3) UNRESOLVED alone does not fail the run" || bad "RV-10 exit" "exit $rc"

# a suffix that matches two files is ambiguous: neither confirmed nor refuted
cite "$TMP/c5" "\`dup.py:1 @$C2\`"
rc=$(run "$TMP/c5" --repo "$CREPO")
vunresolved "RV-11 a suffix path matching two files at that commit is UNRESOLVED (ambiguous), not guessed"
grep -q 'ambiguous' "$TMP/out.txt" && ok "RV-11 ... and the detail says ambiguous" || bad "RV-11 detail" "$(grep -A1 unresolved "$TMP/out.txt" | tr '\n' ' ')"

# --- 0.9.5 the cited line (or the end of the range) must exist in the file AT THAT COMMIT --------------------------
# A third commit adds an empty file, a binary file and a file without a final newline, so the edge cases have a real object to hit.
printf '' > "$CREPO/empty.txt"; printf 'a\0b\1\2\n' > "$CREPO/bin.dat"; printf 'one\ntwo' > "$CREPO/nonl.txt"
git -C "$CREPO" add empty.txt bin.dat nonl.txt
git -C "$CREPO" -c commit.gpgsign=false -c credential.helper= commit -qm "feat: an empty, a binary and an unterminated file"
C3=$(git -C "$CREPO" rev-parse --short HEAD)

# S2-H1: a line inside the file is CONFIRMED and the detail shows the sha, the path and the line
cite "$TMP/l1" "\`src/a.py:10 @$C2\`"
rc=$(run "$TMP/l1" --repo "$CREPO")
vok "RV-12 (S2-H1) a line inside the file (20 lines) is CONFIRMED"
# a CONFIRMED claim's detail is in the --json output (the text report prints a detail only for claims that are not confirmed)
rc=$(run "$TMP/l1" --repo "$CREPO" --json)
grep -qE '"detail": "sha '"$C2"' resolves in crepo; path src/a.py has 20 lines at that commit; line 10 is within it"' "$TMP/out.txt" \
  && ok "RV-12 (S2-H1) the detail shows the sha, the path, the line and the line count" || bad "RV-12 detail" "$(grep '"detail"' "$TMP/out.txt" | tr '\n' ' ')"

# S2-N2: a line, or the end of a range, past the end of the file is REFUTED with the file's line count
for c in "src/a.py:25" "src/a.py:18-25"; do
  cite "$TMP/l2" "\`$c @$C2\`"
  rc=$(run "$TMP/l2" --repo "$CREPO")
  vrefuted "RV-13 (S2-N2) '$c' (file has 20 lines) is REFUTED"
  grep -q '20 lines' "$TMP/out.txt" && ok "RV-13 (S2-N2) '$c': the detail shows the line count" || bad "RV-13 '$c' detail" "$(grep -A1 REFUTED "$TMP/out.txt" | tr '\n' ' ')"
done
[ "$rc" = "1" ] && ok "RV-13 (S2-N2) a line past the end is a non-zero exit" || bad "RV-13 exit" "exit $rc"

# S2-E2: the boundary. A range ending on the last line holds; one more does not. Lines start at 1.
cite "$TMP/l3" "\`src/a.py:15-20 @$C2\`"; rc=$(run "$TMP/l3" --repo "$CREPO")
vok "RV-14 (S2-E2) a range whose end is the last line is CONFIRMED"
cite "$TMP/l3b" "\`src/a.py:15-21 @$C2\`"; rc=$(run "$TMP/l3b" --repo "$CREPO")
vrefuted "RV-14 (S2-E2) a range ending one past the last line is REFUTED"
cite "$TMP/l3c" "\`src/a.py:0 @$C2\`"; rc=$(run "$TMP/l3c" --repo "$CREPO")
vrefuted "RV-14 line 0 does not exist (lines start at 1): REFUTED, not CONFIRMED"
cite "$TMP/l3d" "\`nonl.txt:2 @$C3\`"; rc=$(run "$TMP/l3d" --repo "$CREPO")
vok "RV-14 the last line of a file with no final newline counts"
cite "$TMP/l3e" "\`nonl.txt:3 @$C3\`"; rc=$(run "$TMP/l3e" --repo "$CREPO")
vrefuted "RV-14 ... and one past it does not"

# S2-E1: an empty file and a binary file get a stated verdict, not a crash
cite "$TMP/l4" "\`empty.txt:1 @$C3\`"; rc=$(run "$TMP/l4" --repo "$CREPO")
{ [ "$rc" = "1" ] && vrefuted "RV-15 (S2-E1) a line in an empty file is REFUTED (0 lines)" && grep -q '0 lines' "$TMP/out.txt"; } || bad "RV-15 empty file" "exit $rc: $(head -4 "$TMP/out.txt" | tr '\n' ' ')"
cite "$TMP/l5" "\`bin.dat:1 @$C3\`"; rc=$(run "$TMP/l5" --repo "$CREPO")
vunresolved "RV-15 (S2-E1) a line in a binary file is UNRESOLVED (lines cannot be checked), not a crash"
grep -q 'binary' "$TMP/out.txt" && ok "RV-15 (S2-E1) ... and the detail says binary" || bad "RV-15 binary detail" "$(grep -A1 unresolved "$TMP/out.txt" | tr '\n' ' ')"
[ "$rc" = "0" ] && ok "RV-15 (S2-E1) UNRESOLVED alone does not fail the run" || bad "RV-15 exit" "exit $rc"

# --- 0.9.5 review fixes ------------------------------------------------------------------------------------------------
# F1: a symlink at the cited commit holds the LINK TEXT as its blob. Counting it gave `link.py:5` -> REFUTED "has 1 lines" and `link.py:1` -> a false CONFIRMED.
ln -s src/a.py "$CREPO/link.py"; git -C "$CREPO" add link.py
git -C "$CREPO" -c commit.gpgsign=false -c credential.helper= commit -qm "feat: a symlink to the source file"
C4=$(git -C "$CREPO" rev-parse --short HEAD)
for ln in 5 1; do
  cite "$TMP/sy$ln" "\`link.py:$ln @$C4\`"; rc=$(run "$TMP/sy$ln" --repo "$CREPO")
  { [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && grep -q 'symlink' "$TMP/out.txt" && ! grep -qE '^  (REFUTED|ok  ) ' "$TMP/out.txt"; } \
    && ok "RV-20 (S2-N4) a line in a symlink ('link.py:$ln') is UNRESOLVED (symlink), not REFUTED and not CONFIRMED" \
    || bad "RV-20 symlink line $ln" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-250)"
done

# F2: the path of a citation must start at a boundary. `my dir/w.py:1 @sha` was cut to `dir/w.py` and looked up as a suffix, and `C:\x\y.py:3 @sha` to `y.py`:
# both REFUTED a claim nobody made. A Windows path, a URL and a version number are not citations. A path cut at a SPACE cannot be told from prose by
# looking at the characters, so a cut that matches the END of a longer file name (not at a "/") is UNRESOLVED, never REFUTED.
mkdir -p "$CREPO/my dir"; printf 'w\n' > "$CREPO/my dir/w.py"; printf 'd\n' > "$CREPO/data.py"; git -C "$CREPO" add -A
git -C "$CREPO" -c commit.gpgsign=false -c credential.helper= commit -qm "feat: a directory with a space"
C5=$(git -C "$CREPO" rev-parse --short HEAD)
cite "$TMP/sp1" "a dir/w.py:1 @$C5"; rc=$(run "$TMP/sp1" --repo "$CREPO")  # "a" does not spell the real name `my dir/w.py`; the spelled-out `my dir/w.py:1` is RV-27
{ [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  (REFUTED|ok  ) ' "$TMP/out.txt"; } \
  && ok "RV-21 (S2-E3) 'a dir/w.py:1 @sha' (a space inside the path, words that do not spell the file) is UNRESOLVED, not a false REFUTED of 'dir/w.py'" \
  || bad "RV-21 space in the directory" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-250)"
# only a cut AT A SPACE is UNRESOLVED: a missing file whose name merely ends the same way (ta.py vs data.py) is still a real REFUTED
cite "$TMP/sp2" "ta.py:1 @$C5"; rc=$(run "$TMP/sp2" --repo "$CREPO")
vrefuted "RV-21 (S2-E3) 'ta.py' is REFUTED even though data.py ends with it (only a cut at a space is UNRESOLVED)"
for c in 'C:\x\y.py:3' 'http://host.example/a.py:80' 'v1.2:3'; do
  case "$c" in 'v1.2:3') tail_="@ 5pm";; *) tail_="@$C5";; esac
  cite "$TMP/nc" "See $c $tail_ here."; rc=$(run "$TMP/nc" --repo "$CREPO")
  { [ "$rc" = "0" ] && grep -q 'no checkable' "$TMP/out.txt" && ! grep -qE '^  (REFUTED|unresolved|ok  ) ' "$TMP/out.txt"; } \
    && ok "RV-21 (S2-E3) '$c $tail_' is not a citation: no claim, no verdict" \
    || bad "RV-21 not a citation: $c" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-250)"
done

# F4: a line number of thousands of digits made int() raise (Python >= 3.9.14, 3.10.7, 3.11+: the integer string conversion limit), which aborted the WHOLE
# run: exit 1, no output. A line number over 9 digits is REFUTED "line number out of range" without being converted, and the other claims still print.
BIGN=$("$REALPY" -c 'print("9" * 5000)')
note5 "$TMP/big" "See src/a.py:$BIGN @$C2 and src/a.py:3 @$C2 and src/a.py:1-$BIGN @$C2."
rc=$(run "$TMP/big" --repo "$CREPO")
{ [ "$rc" = "1" ] && grep -qE '^  REFUTED ' "$TMP/out.txt" && grep -q 'line number out of range' "$TMP/out.txt" && grep -qE '^  ok  .*src/a.py:3 ' "$TMP/out.txt" && ! grep -q 'Traceback' "$TMP/out.txt"; } \
  && ok "RV-22 (S2-N5) a 5000-digit line number (alone or ending a range) is REFUTED 'out of range', and the other citation still prints" \
  || bad "RV-22 huge line number" "exit $rc: $(grep -E '^  (ok|REFUTED|unresolved)|Error|Traceback' "$TMP/out.txt" | cut -c1-120 | tr '\n' '|' | cut -c1-300)"
# the same, through every newer Python on this machine (the limit is not in the 3.9 that macOS ships)
for py in python3.11 python3.12 python3.13; do
  command -v "$py" >/dev/null 2>&1 || continue
  "$py" "$VERIFY" "$TMP/big" --repo "$CREPO" >"$TMP/out.txt" 2>&1; rc=$?
  { [ "$rc" = "1" ] && grep -q 'line number out of range' "$TMP/out.txt" && ! grep -q 'Traceback' "$TMP/out.txt"; } \
    && ok "RV-22 (S2-N5) under $py the huge line number does not abort the run" || bad "RV-22 under $py" "exit $rc: $(tail -2 "$TMP/out.txt" | cut -c1-200 | tr '\n' ' ')"
done

# S2-E4: line 0 is REFUTED (RV-14); a reversed range such as 20-10 is read as the lines up to the LARGER number (stated in the README), so it holds when that is within the file
cite "$TMP/rv1" "\`src/a.py:20-10 @$C2\`"; rc=$(run "$TMP/rv1" --repo "$CREPO")
vok "RV-23 (S2-E4) a reversed range '20-10' is read as up to line 20 (the larger number): CONFIRMED for a 20-line file"
cite "$TMP/rv2" "\`src/a.py:25-10 @$C2\`"; rc=$(run "$TMP/rv2" --repo "$CREPO")
vrefuted "RV-23 (S2-E4) ... and REFUTED when the larger number is past the end"
# --- RV-27 (audit R056/R058): a citation whose text before `:line` holds a space. The parser cuts the path at the space, so `my w.py:3` was
# checked against `w.py` and CONFIRMED. Fixtures are tiny repos: spcommit makes one commit holding the named files with the given line counts.
spcommit() { # <repo> <name:lines>... — a fresh repo with one commit; prints the short sha
  local r="$1"; shift; mkdir -p "$r"; git -C "$r" init -q 2>/dev/null; git -C "$r" config user.email t@t; git -C "$r" config user.name t
  local f; for f in "$@"; do mkdir -p "$r/$(dirname "${f%:*}")"; seq 1 "${f##*:}" > "$r/${f%:*}"; done
  git -C "$r" add -A; git -C "$r" -c commit.gpgsign=false -c credential.helper= commit -qm "feat: files"; git -C "$r" rev-parse --short HEAD
}
# S2-SP-N1: both `my w.py` and `w.py` exist: the writer's intent cannot be told, so UNRESOLVED naming both; never CONFIRMED on a guess
SP1=$(spcommit "$TMP/sp-both" "my w.py:1" "w.py:5")
cite "$TMP/sp-b1" "my w.py:3 @$SP1"; rc=$(run "$TMP/sp-b1" --repo "$TMP/sp-both")
{ [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  (REFUTED|ok  ) ' "$TMP/out.txt" && grep -q 'my w.py' "$TMP/out.txt" && grep -qE 'and w\.py|w\.py and|or w\.py' "$TMP/out.txt"; } \
  && ok "RV-27 (S2-SP-N1) 'my w.py:3 @sha' with both 'my w.py' and 'w.py' present is UNRESOLVED naming both, not CONFIRMED against w.py" \
  || bad "RV-27 S2-SP-N1 both files" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"

# one line of the form `<verdict word> ... <detail>`: the first verdict row, for a compact failure message
sprow() { grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300; }
# S2-SP-H1/N2: only `my w.py` exists (5 lines): the spelled-out name is tried first, so the line is checked in THAT file
SP2=$(spcommit "$TMP/sp-only-spaced" "my w.py:5")
cite "$TMP/sp-h1" "my w.py:3 @$SP2"; rc=$(run "$TMP/sp-h1" --repo "$TMP/sp-only-spaced")
vok "RV-27 (S2-SP-H1) 'my w.py:3' with only 'my w.py' present is CONFIRMED against that file"
rc=$(run "$TMP/sp-h1" --repo "$TMP/sp-only-spaced" --json)
grep -q 'path my w.py has 5 lines' "$TMP/out.txt" && ok "RV-27 (S2-SP-H1) ... and the detail names 'my w.py', not 'w.py'" || bad "RV-27 S2-SP-H1 detail" "$(grep '"detail"' "$TMP/out.txt" | tr '\n' ' ')"
cite "$TMP/sp-n2" "my w.py:9 @$SP2"; rc=$(run "$TMP/sp-n2" --repo "$TMP/sp-only-spaced")
{ vrefuted "RV-27 (S2-SP-N2) 'my w.py:9' (file has 5 lines) is REFUTED" && grep -q 'my w.py has 5 lines' "$TMP/out.txt"; } || bad "RV-27 S2-SP-N2 detail" "exit $rc: $(sprow)"
# S2-SP-N3: the path is written QUOTED, so the boundary is explicit: `w.py` is never the file named, even when it is the only one that exists
SP3=$(spcommit "$TMP/sp-only-plain" "w.py:5")
for q in '"my w.py":3' "\`my w.py\`:3" "'my w.py':3"; do
  cite "$TMP/sp-n3" "$q @$SP3"; rc=$(run "$TMP/sp-n3" --repo "$TMP/sp-only-plain")
  { [ "$rc" = "1" ] && grep -qE '^  REFUTED ' "$TMP/out.txt" && grep -q 'path part failed' "$TMP/out.txt" && ! grep -qE '^  ok  ' "$TMP/out.txt"; } \
    && ok "RV-27 (S2-SP-N3) quoted $q with only 'w.py' present is REFUTED (path part), never CONFIRMED against w.py" || bad "RV-27 S2-SP-N3 $q" "exit $rc: $(sprow)"
done
cite "$TMP/sp-n3b" "\"my w.py\":3 @$SP2"; rc=$(run "$TMP/sp-n3b" --repo "$TMP/sp-only-spaced")
vok "RV-27 (S2-SP-N3) a quoted \"my w.py\":3 resolves against the file of that name"
# S2-SP-E1: a name with TWO spaces is read from the writer's words: `my big w.py` alone resolves, and with `w.py` present it is UNRESOLVED
SP4=$(spcommit "$TMP/sp-two" "my big w.py:5"); cite "$TMP/sp-e1" "my big w.py:3 @$SP4"; rc=$(run "$TMP/sp-e1" --repo "$TMP/sp-two")
vok "RV-27 (S2-SP-E1) 'my big w.py:3' (two spaces) with only 'my big w.py' present is CONFIRMED against that file"
SP5=$(spcommit "$TMP/sp-two-b" "my big w.py:5" "w.py:5"); cite "$TMP/sp-e1b" "my big w.py:3 @$SP5"; rc=$(run "$TMP/sp-e1b" --repo "$TMP/sp-two-b")
{ vunresolved "RV-27 (S2-SP-E1) ... and UNRESOLVED when 'w.py' also exists" && ! grep -qE '^  (ok  |REFUTED) ' "$TMP/out.txt"; } || bad "RV-27 S2-SP-E1 two spaces" "exit $rc: $(sprow)"
# S2-SP-E2: inside a table cell and inside a backtick-wrapped citation, with both files present
cite "$TMP/sp-e2" "| note | my w.py:3 @$SP1 |"; rc=$(run "$TMP/sp-e2" --repo "$TMP/sp-both")
vunresolved "RV-27 (S2-SP-E2) a citation in a table cell is UNRESOLVED when 'my w.py' and 'w.py' both exist"
cite "$TMP/sp-e2b" "\`my w.py:3 @$SP1\`"; rc=$(run "$TMP/sp-e2b" --repo "$TMP/sp-both")
vunresolved "RV-27 (S2-SP-E2) a backtick-wrapped citation is UNRESOLVED when both exist"
cite "$TMP/sp-e2c" "| note | my w.py:3 @$SP2 |"; rc=$(run "$TMP/sp-e2c" --repo "$TMP/sp-only-spaced")
vok "RV-27 (S2-SP-E2) a table-cell citation resolves against 'my w.py' when that is the only match"
# S2-SP-E3: a Windows path with a space and backslashes is not a citation (no claim, no verdict), as for the space-free one
cite "$TMP/sp-e3" "See C:\\my dir\\w.py:3 @$SP1 here."; rc=$(run "$TMP/sp-e3" --repo "$TMP/sp-both")
{ [ "$rc" = "0" ] && grep -q 'no checkable' "$TMP/out.txt" && ! grep -qE '^  (REFUTED|unresolved|ok  ) ' "$TMP/out.txt"; } \
  && ok "RV-27 (S2-SP-E3) 'C:\\my dir\\w.py:3 @sha' is not a citation: no claim, no verdict" || bad "RV-27 S2-SP-E3" "exit $rc: $(sprow)"
# S2-SP-E4: an ordinary word before a citation whose path exists alone stays CONFIRMED (prose, RV-8): only a SPELLED-OUT name changes the reading
SP6=$(spcommit "$TMP/sp-plain" "w.py:5"); cite "$TMP/sp-e4" "my w.py:3 @$SP6"; rc=$(run "$TMP/sp-e4" --repo "$TMP/sp-plain")
vok "RV-27 (S2-SP-E4) 'my w.py:3' with only 'w.py' present is CONFIRMED: 'my' is prose when no file is named 'my w.py'"
# S2-SP-N4 (R058): `path:line` and `@sha` in different paragraphs are two statements, not one citation; a soft-wrapped single newline is still one
cite "$TMP/sp-n4" "w.py:3

@$SP6"; rc=$(run "$TMP/sp-n4" --repo "$TMP/sp-plain")
{ [ "$rc" = "0" ] && ! grep -qE '^  (REFUTED|unresolved|ok  ) .*citation' "$TMP/out.txt" && ! grep -q '\[citation\]' "$TMP/out.txt"; } \
  && ok "RV-27 (S2-SP-N4) 'w.py:3', a blank line, '@sha' is not one citation (R058)" || bad "RV-27 S2-SP-N4 paragraphs" "exit $rc: $(sprow)"
cite "$TMP/sp-n4b" "w.py:3
at $SP6"; rc=$(run "$TMP/sp-n4b" --repo "$TMP/sp-plain")
vok "RV-27 (S2-SP-N4) ... while 'w.py:3' and 'at sha' on consecutive lines of one paragraph are still one citation"
# S2-SP-D1 (round 2): the same citation written twice with different words before it is ONE claim when no spaced file exists: output must not depend on prose
mkb "$TMP/sp-d1"; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nsee w.py:3 @%s\n\nAlso in w.py:3 @%s\n' "$SP6" "$SP6" > "$TMP/sp-d1/n.md"
rc=$(run "$TMP/sp-d1" --repo "$TMP/sp-plain")
{ [ "$rc" = "0" ] && grep -q 'CONFIRMED 1 ' "$TMP/out.txt" && [ "$(grep -cE '^  ok  ' "$TMP/out.txt")" = "1" ]; } \
  && ok "RV-27 (S2-SP-D1) 'see w.py:3 @sha' and 'Also in w.py:3 @sha' (only w.py exists) collapse to one CONFIRMED claim" || bad "RV-27 S2-SP-D1 duplicate" "exit $rc: $(grep -E 'CONFIRMED|^  ok' "$TMP/out.txt" | tr '\n' ' ')"
# ... two ambiguous readings with both files present give the SAME result, so they collapse; a reading that resolves differently prints beside it
mkb "$TMP/sp-d2"; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nmy w.py:3 @%s\n\nAlso my w.py:3 @%s\n\nsee w.py:3 @%s\n' "$SP1" "$SP1" "$SP1" > "$TMP/sp-d2/n.md"
rc=$(run "$TMP/sp-d2" --repo "$TMP/sp-both")
{ [ "$(grep -cE '^  unresolved ' "$TMP/out.txt")" = "1" ] && [ "$(grep -cE '^  ok  ' "$TMP/out.txt")" = "1" ] ; } \
  && ok "RV-27 (S2-SP-D1) identical results collapse (two UNRESOLVED readings -> one) while a differing result prints beside them" || bad "RV-27 S2-SP-D1 distinct" "exit $rc: $(sprow)"
# S2-SP-H1 (round 2): the text `ok` line names the file it was checked against, not the cut tail
cite "$TMP/sp-h1b" "my w.py:3 @$SP2"; rc=$(run "$TMP/sp-h1b" --repo "$TMP/sp-only-spaced")
grep -q 'my w\.py:3' <<<"$(grep -E '^  ok  ' "$TMP/out.txt")" && ok "RV-27 (S2-SP-H1) the ok line names 'my w.py', the file that was checked" || bad "RV-27 S2-SP-H1 ok line" "$(sprow)"
# --- RV-33 (S2-SP-E5..E8): the name is the writer's own text, not its words rejoined with one space, and any number of words may belong to it.
# citejson <dir> <repo>: the citation results as JSON [[claim, verdict]...] (kind citation).
citejson() { "$VERIFY" "$1" --repo "$2" --json > "$TMP/out.json" 2>/dev/null; "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([[r["claim"].split(" @")[0], r["verdict"]] for r in d["results"] if r["kind"] == "citation"], ensure_ascii=False))' "$TMP/out.json"; }
for sep in '  ' $'\t' $'\xc2\xa0'; do
  W5=$(spcommit "$TMP/sp-ws" "my${sep}w.py:5" "w.py:5"); cite "$TMP/sp-e5" "my${sep}w.py:3 @$W5"; got=$(citejson "$TMP/sp-e5" "$TMP/sp-ws")
  W6=$(spcommit "$TMP/sp-ws1" "my${sep}w.py:5"); cite "$TMP/sp-e5b" "my${sep}w.py:3 @$W6"; got2=$(citejson "$TMP/sp-e5b" "$TMP/sp-ws1")
  { [ "$got" = "$("$REALPY" -c 'import json,sys; print(json.dumps([[sys.argv[1] + "w.py:3", "UNRESOLVED"]], ensure_ascii=False))' "my${sep}")" ] \
    && [ "$got2" = "$("$REALPY" -c 'import json,sys; print(json.dumps([[sys.argv[1] + "w.py:3", "CONFIRMED"]], ensure_ascii=False))' "my${sep}")" ]; } \
    && ok "RV-33 (S2-SP-E5) 'my${sep}w.py:3 @sha' ($(printf '%s' "$sep" | od -An -c | tr -s ' ' | tr -d '\n')) is the file of that exact name: UNRESOLVED beside w.py, CONFIRMED alone" \
    || bad "RV-33 S2-SP-E5 whitespace" "both=$got alone=$got2"
done
# S2-SP-E6: a name soft-wrapped over two lines is tried as written and with the break read as a space; a blank line ends the paragraph
W7=$(spcommit "$TMP/sp-wrap" "my w.py:5" "w.py:5"); cite "$TMP/sp-e6" "my
w.py:3 @$W7"; got=$(citejson "$TMP/sp-e6" "$TMP/sp-wrap")
cite "$TMP/sp-e6b" "my

w.py:3 @$W7"; got2=$(citejson "$TMP/sp-e6b" "$TMP/sp-wrap")
{ [ "$got" = '[["my w.py:3", "UNRESOLVED"]]' ] && [ "$got2" = '[["w.py:3", "CONFIRMED"]]' ]; } \
  && ok "RV-33 (S2-SP-E6) a soft-wrapped 'my<newline>w.py:3 @sha' is UNRESOLVED beside w.py; with a blank line between the words, they are not part of the name" || bad "RV-33 S2-SP-E6 wrap" "wrapped=$got blank=$got2"
# S2-SP-E7: any number of words before the cut may belong to the name
W8=$(spcommit "$TMP/sp-five" "one two three four five.py:5" "five.py:5"); cite "$TMP/sp-e7" "one two three four five.py:3 @$W8"; got=$(citejson "$TMP/sp-e7" "$TMP/sp-five")
W9=$(spcommit "$TMP/sp-five1" "one two three four five.py:5"); cite "$TMP/sp-e7b" "one two three four five.py:3 @$W9"; got2=$(citejson "$TMP/sp-e7b" "$TMP/sp-five1")
{ [ "$got" = '[["one two three four five.py:3", "UNRESOLVED"]]' ] && [ "$got2" = '[["one two three four five.py:3", "CONFIRMED"]]' ]; } \
  && ok "RV-33 (S2-SP-E7) a five-word name is found (UNRESOLVED beside five.py, CONFIRMED alone)" || bad "RV-33 S2-SP-E7 five words" "both=$got alone=$got2"
# S2-SP-E8: an ambiguous citation names the spaced form in its claim, and a quoted name with a non-ASCII letter is a claim
cite "$TMP/sp-e8" "my w.py:3 @$SP1 and w.py:3 @$SP1"; got=$(citejson "$TMP/sp-e8" "$TMP/sp-both")
W10=$(spcommit "$TMP/sp-uni" "café w.py:5" "w.py:5"); cite "$TMP/sp-e8b" "\`café w.py\`:3 @$W10"; got2=$(citejson "$TMP/sp-e8b" "$TMP/sp-uni")
{ [ "$got" = '[["my w.py:3", "UNRESOLVED"], ["w.py:3", "CONFIRMED"]]' ] && [ "$got2" = '[["café w.py:3", "CONFIRMED"]]' ]; } \
  && ok "RV-33 (S2-SP-E8) the ambiguous claim reads 'my w.py:3', the bare one 'w.py:3'; a quoted \`café w.py\`:3 is a claim" || bad "RV-33 S2-SP-E8 claim text / unicode" "text=$got unicode=$got2"
# S2-SP-E9: only a line break is read as a space: `my  w.py` (two spaces), `my<TAB>w.py` and `my<NBSP>w.py` with only `my w.py` at the commit name no file
# (UNRESOLVED: the cut `w.py` ends a longer name), and the claim is not checked against `my w.py`
W11=$(spcommit "$TMP/sp-ws2" "my w.py:5")
for sep in '  ' $'\t' $'\xc2\xa0'; do
  cite "$TMP/sp-e9" "my${sep}w.py:3 @$W11"; got=$(citejson "$TMP/sp-e9" "$TMP/sp-ws2")
  [ "$got" = '[["w.py:3", "UNRESOLVED"]]' ] && ok "RV-33 (S2-SP-E9) 'my${sep}w.py:3 @sha' with only 'my w.py' present is UNRESOLVED, not CONFIRMED against it" || bad "RV-33 S2-SP-E9 whitespace not collapsed" "got=$got"
done
W12=$(spcommit "$TMP/sp-ab" "a b.py:5" "a  b.py:5"); cite "$TMP/sp-e9b" "a  b.py:3 @$W12 and a b.py:4 @$W12"; got=$(citejson "$TMP/sp-e9b" "$TMP/sp-ab")
[ "$got" = '[["a  b.py:3", "CONFIRMED"], ["a b.py:4", "CONFIRMED"]]' ] && ok "RV-33 (S2-SP-E9) 'a  b.py' and 'a b.py' are two files, each CONFIRMED under the claim as written" || bad "RV-33 S2-SP-E9 two spellings" "got=$got"
# S2-SP-P1 (round 2): the tree listing is read once per (repo, sha), not once per citation
mkdir -p "$TMP/gitspy"; printf '#!/bin/sh\necho "$@" >> "%s/gitspy.log"\nexec "%s" "$@"\n' "$TMP" "$(command -v git)" > "$TMP/gitspy/git"; chmod +x "$TMP/gitspy/git"
{ printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n'; for i in 1 2 3 4 5; do echo "see w.py:$i @$SP6"; echo; done; } > "$TMP/sp-p1.md"
mkb "$TMP/sp-p1"; cp "$TMP/sp-p1.md" "$TMP/sp-p1/n.md"; : > "$TMP/gitspy.log"
PATH="$TMP/gitspy:$PATH" "$VERIFY" "$TMP/sp-p1" --repo "$TMP/sp-plain" >"$TMP/out.txt" 2>&1
n=$(grep -c 'ls-tree -r' "$TMP/gitspy.log")
{ grep -q 'CONFIRMED 5 ' "$TMP/out.txt" && [ "$n" -le 1 ]; } && ok "RV-27 (S2-SP-P1) 5 citations of one commit run 'git ls-tree -r' at most once (ran $n)" || bad "RV-27 S2-SP-P1 spawns" "ls-tree -r ran $n times: $(grep -E 'CONFIRMED' "$TMP/out.txt")"
# --- RV-28: a zero-padded line number is the number it spells. The length test ran on the digits as written, so ten digits with
# leading zeros were "out of range" although the file has the line (src/a.py has 20 lines at $C2).
cite "$TMP/lz1" "\`src/a.py:0000000003 @$C2\`"; rc=$(run "$TMP/lz1" --repo "$CREPO")
{ [ "$rc" = "0" ] && grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-28 (S29-LZ-H1) 'a.py:0000000003 @sha' is CONFIRMED, as 'a.py:3' is" || bad "RV-28 S29-LZ-H1 zero-padded" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
cite "$TMP/lz2" "\`src/a.py:0000000018-0000000020 @$C2\`"; rc=$(run "$TMP/lz2" --repo "$CREPO")
{ [ "$rc" = "0" ] && grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-28 (S29-LZ-E1) a zero-padded range 0000000018-0000000020 is CONFIRMED" || bad "RV-28 S29-LZ-E1 range" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
cite "$TMP/lz3" "\`src/a.py:0000000021 @$C2\`"; rc=$(run "$TMP/lz3" --repo "$CREPO")
{ [ "$rc" = "1" ] && grep -qE '^  REFUTED ' "$TMP/out.txt" && grep -q 'is past the end' "$TMP/out.txt"; } && ok "RV-28 (S29-LZ-N1) 'a.py:0000000021' (20 lines) is REFUTED as past the end, not as 'out of range'" || bad "RV-28 S29-LZ-N1 past the end" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
cite "$TMP/lz4" "\`src/a.py:0000000000 @$C2\`"; rc=$(run "$TMP/lz4" --repo "$CREPO")
{ [ "$rc" = "1" ] && grep -q 'lines start at 1' "$TMP/out.txt"; } && ok "RV-28 (S29-LZ-N2) 'a.py:0000000000' is REFUTED: lines start at 1" || bad "RV-28 S29-LZ-N2 zero" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
ZEROS=$(printf '0%.0s' $(seq 1 5000))
[ "${#ZEROS}" -le 8192 ] || { echo "fixture too large"; exit 2; }
cite "$TMP/lz5" "\`src/a.py:${ZEROS}3 @$C2\`"; rc=$(run "$TMP/lz5" --repo "$CREPO")
{ [ "$rc" = "0" ] && grep -qE '^  ok  ' "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt"; } && ok "RV-28 (S29-LZ-E2) 5000 zeros before a 3 is line 3: CONFIRMED, no traceback" || bad "RV-28 S29-LZ-E2 many zeros" "exit $rc: $(grep -E '^  (ok|REFUTED|unresolved)|Error|Traceback' "$TMP/out.txt" | cut -c1-120 | tr '\n' '|' | cut -c1-300)"
for py in python3.11 python3.12 python3.13; do
  command -v "$py" >/dev/null 2>&1 || continue
  "$py" "$VERIFY" "$TMP/lz5" --repo "$CREPO" >"$TMP/out.txt" 2>&1; rc=$?
  { [ "$rc" = "0" ] && ! grep -q Traceback "$TMP/out.txt"; } && ok "RV-28 (S29-LZ-E2) under $py 5000 zeros before a 3 does not abort the run" || bad "RV-28 S29-LZ-E2 under $py" "exit $rc: $(tail -2 "$TMP/out.txt" | cut -c1-200 | tr '\n' ' ')"
done
# --- RV-29: a cited absolute path inside a --repo folder is inside it whether --repo is written relative or absolute.
# macOS spells its temp folders through a link (/var -> /private/var); a link of our own makes the same case on any system.
mkdir -p "$TMP/rp/real/repo" "$TMP/rp/other"; ln -s real "$TMP/rp/link"
git -C "$TMP/rp/real/repo" init -q 2>/dev/null; printf 'x\n' > "$TMP/rp/real/repo/f.txt"; printf 'y\n' > "$TMP/rp/other/o.txt"
note5 "$TMP/rp/b1" "See \`$TMP/rp/link/repo/f.txt\` for it."
note5 "$TMP/rp/b2" "See \`$TMP/rp/other/o.txt\` for it."
for form in relative absolute; do
  [ "$form" = relative ] && repoarg="link/repo" || repoarg="$TMP/rp/link/repo"
  (cd "$TMP/rp" && "$VERIFY" "$TMP/rp/b1" --repo "$repoarg" --strict >"$TMP/out.txt" 2>&1); rc=$?
  { [ "$rc" = "0" ] && grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-29 (S29-RP-H1) a path inside the repo, cited through a link, is CONFIRMED with a $form --repo (--strict exit 0)" || bad "RV-29 S29-RP-H1 $form" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
  (cd "$TMP/rp" && "$VERIFY" "$TMP/rp/b2" --repo "$repoarg" >"$TMP/out.txt" 2>&1); rc=$?
  { [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && grep -q 'outside the bundle and the --repo folders' "$TMP/out.txt"; } && ok "RV-29 (S29-RP-N1) a path outside the repo stays UNRESOLVED with a $form --repo" || bad "RV-29 S29-RP-N1 $form" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
done
# S29-RP-N2: asking whether a cited path is inside the roots never touches the file system for a path OUTSIDE them (a path under
# /net/<host> would make macOS mount that host). The roots are looked at, the cited path is read as written.
"$REALPY" - "$VERIFY" "$TMP/rp" <<'PY' >"$TMP/out.txt" 2>&1
import importlib.machinery, importlib.util, os, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okfv", sys.argv[1])
spec = importlib.util.spec_from_loader("okfv", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
seen = []
real_lstat, real_stat = os.lstat, os.stat
def spy(fn):
    def f(path, *a, **k):
        seen.append(str(path)); return fn(path, *a, **k)
    return f
os.lstat, os.stat = spy(real_lstat), spy(real_stat)
os.chdir(sys.argv[2])
outside = "/net/zz-no-such-host/share/f.txt"
got = m.inside_any(outside, [Path("link/repo"), Path(sys.argv[2]) / "real" / "repo"])
touched = [p for p in seen if "zz-no-such-host" in p or p == "/net"]
print("inside=%s touched=%s" % (got, touched))
sys.exit(0 if (got is False and not touched) else 1)
PY
[ "$?" = "0" ] && ok "RV-29 (S29-RP-N2) a cited path outside every root is read as written: inside_any does not touch it on disk" || bad "RV-29 S29-RP-N2 no stat outside the roots" "$(tail -2 "$TMP/out.txt" | cut -c1-200 | tr '\n' ' ')"
# S29-RP-N3 / N4: the shell's spelling of a relative --repo (its $PWD) is only a spelling of the SAME folder. Run from a link L to
# real/a/b, `--repo ../sib` is real/a/sib for the system but $TMP/pw/B/sib when `..` is taken off the spelling L/..: a file that
# lies in the other folder is outside the repository and must stay UNRESOLVED. A stale $PWD (it names another folder) counts for nothing.
mkdir -p "$TMP/pw/B/real/a/b" "$TMP/pw/B/real/a/sib" "$TMP/pw/B/sib" "$TMP/pw/C/w/repo" "$TMP/pw/C/other/repo"
git -C "$TMP/pw/B/real/a/sib" init -q 2>/dev/null; git -C "$TMP/pw/C/w/repo" init -q 2>/dev/null
printf 'y\n' > "$TMP/pw/B/sib/x.txt"; printf 'in\n' > "$TMP/pw/B/real/a/sib/in.txt"; printf 'z\n' > "$TMP/pw/C/other/repo/z.txt"; ln -s real/a/b "$TMP/pw/B/L"
note5 "$TMP/pw/B/out" "See \`$TMP/pw/B/sib/x.txt\` here."; note5 "$TMP/pw/B/in" "See \`$(cd "$TMP/pw/B/real/a/sib" && pwd -P)/in.txt\` here."; note5 "$TMP/pw/C/bun" "See \`$TMP/pw/C/other/repo/z.txt\` here."
(cd "$TMP/pw/B/L" && PWD="$TMP/pw/B/L" "$VERIFY" "$TMP/pw/B/out" --repo ../sib >"$TMP/out.txt" 2>&1); rc=$?
{ [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-29 (S29-RP-N3) from a link, '--repo ../sib': a file in the OTHER folder sib stays UNRESOLVED (not CONFIRMED through a \$PWD spelling)" || bad_hard "RV-29 S29-RP-N3 dotdot under a linked PWD" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-260)"
(cd "$TMP/pw/B/L" && PWD="$TMP/pw/B/L" "$VERIFY" "$TMP/pw/B/in" --repo ../sib >"$TMP/out.txt" 2>&1); rc=$?
{ [ "$rc" = "0" ] && grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-29 (S29-RP-H2) ... and a file in the folder '--repo ../sib' really names (cited by its real path) is CONFIRMED" || bad "RV-29 S29-RP-H2 dotdot control" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-260)"
(cd "$TMP/pw/C/w" && PWD="$TMP/pw/C/other" "$VERIFY" "$TMP/pw/C/bun" --repo repo >"$TMP/out.txt" 2>&1); rc=$?
{ [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-29 (S29-RP-N4) a stale \$PWD (naming another folder) is ignored: a file in that other folder stays UNRESOLVED" || bad_hard "RV-29 S29-RP-N4 stale PWD" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-260)"
# S29-RP-E1: the guard does not turn away the ordinary case: `..` with an unlinked $PWD (a macOS temp folder is the link here) still
# reads the repository as the note spells it.
mkdir -p "$TMP/pw/D/a/b" "$TMP/pw/D/a/sib"; git -C "$TMP/pw/D/a/sib" init -q 2>/dev/null; printf 'd\n' > "$TMP/pw/D/a/sib/f.txt"
note5 "$TMP/pw/D/bun" "See \`$TMP/pw/D/a/sib/f.txt\` here."
(cd "$TMP/pw/D/a/b" && "$VERIFY" "$TMP/pw/D/bun" --repo ../sib --strict >"$TMP/out.txt" 2>&1); rc=$?
{ [ "$rc" = "0" ] && grep -qE '^  ok  ' "$TMP/out.txt"; } && ok "RV-29 (S29-RP-E1) '--repo ../sib' from a plain folder still CONFIRMS a file cited by the spelling of that folder" || bad "RV-29 S29-RP-E1 dotdot plain" "exit $rc: $(grep -A1 -E '^  (ok|REFUTED|unresolved)' "$TMP/out.txt" | tr '\n' ' ' | cut -c1-260)"
# --- RV-30: a bundle (or --repo) under a folder nobody may enter is one error line naming the folder, never a traceback.
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$TMP/pl/outer/b"; note5 "$TMP/pl/outer/b" "Fixed in commit $REAL_SHA."
  mkdir -p "$TMP/pl/inner/r"; note5 "$TMP/pl/okb" "Fixed in commit $REAL_SHA."
  chmod 000 "$TMP/pl/outer"
  rc=$(run "$TMP/pl/outer/b")
  chmod 755 "$TMP/pl/outer"
  { [ "$rc" = "2" ] && [ "$(wc -l < "$TMP/out.txt" | tr -d ' ')" = "1" ] && grep -q "^error: .*pl/outer/b" "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt"; } \
    && ok "RV-30 (S29-PE-N1) a bundle under an unreadable folder: one 'error:' line naming it, exit 2, no traceback" \
    || bad "RV-30 S29-PE-N1 unreadable bundle" "exit $rc: $(head -3 "$TMP/out.txt" | cut -c1-160 | tr '\n' '|')"
  chmod 000 "$TMP/pl/inner"
  rc=$(run "$TMP/pl/okb" --repo "$TMP/pl/inner/r"); cp "$TMP/out.txt" "$TMP/pl-text.txt"
  "$VERIFY" "$TMP/pl/okb" --json --repo "$TMP/pl/inner/r" >"$TMP/pl-json.txt" 2>/dev/null
  chmod 755 "$TMP/pl/inner"
  { [ "$rc" != "1" ] && ! grep -q Traceback "$TMP/pl-text.txt" && grep -q "^  ! cannot read, skipped: .*pl/inner/r (Permission denied)" "$TMP/pl-text.txt" && ! grep -q "not a git repo" "$TMP/pl-text.txt"; } \
    && ok "RV-30 (S29-PE-N2) a --repo under an unreadable folder is 'cannot read, skipped' with the reason, not 'not a git repo', and no traceback" \
    || bad "RV-30 S29-PE-N2 unreadable --repo" "exit $rc: $(head -3 "$TMP/pl-text.txt" | cut -c1-160 | tr '\n' '|')"
  "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repos_skipped_not_git"] == [], d["repos_skipped_not_git"]; u=d["repos_unreadable"]; assert len(u) == 1 and u[0]["path"].endswith("pl/inner/r") and u[0]["why"] == "Permission denied", u' "$TMP/pl-json.txt" 2>"$TMP/pl-json.err" \
    && ok "RV-30 (S29-PE-N3) --json lists it in repos_unreadable (path and reason), and repos_skipped_not_git holds only paths that are not git repositories" \
    || bad "RV-30 S29-PE-N3 json" "$(tail -1 "$TMP/pl-json.err") $(head -c 200 "$TMP/pl-json.txt" | tr '\n' ' ')"
else
  skip "RV-30 a bundle under an unreadable folder — running as root, chmod 000 does not stop the read (skip, not a pass)"
fi
# --- S39-PY: Python 3.14 stopped raising from Path.exists(), is_dir() and is_file(): a permission error is a plain False there.
# Every verdict below says "cannot look", never "not found" or "refuted", on every Python. Run twice: as the Python in use is, and with
# those three predicates made to answer False for an OSError (a sitecustomize on PYTHONPATH), so a 3.9 or 3.12 run proves the 3.14 behaviour too.
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$TMP/py314"
  cat > "$TMP/py314/sitecustomize.py" <<'PYEOF'
import pathlib
def _quiet(f):
    def g(self, *a, **k):
        try:
            return f(self, *a, **k)
        except OSError:
            return False
    return g
for _n in ("exists", "is_dir", "is_file"):
    setattr(pathlib.Path, _n, _quiet(getattr(pathlib.Path, _n)))
PYEOF
  PYB="$TMP/pyun"; mkdir -p "$PYB/lockedfile" "$PYB/outer/bundle" "$PYB/inner/r" "$PYB/mf/b" "$PYB/lrepo/docs"
  printf 'x\n' > "$PYB/lockedfile/secret.txt"; printf 'a\nb\n' > "$PYB/lrepo/docs/spec.md"; git -C "$PYB/lrepo" init -q 2>/dev/null
  note5 "$PYB/b1" "See \`$PYB/lockedfile/secret.txt\`."
  note5 "$PYB/outer/bundle" "Fixed in commit $REAL_SHA."
  note5 "$PYB/b3" "See docs/spec.md:1 here."
  note5 "$PYB/b4" "Fixed in commit $REAL_SHA."; decl "$PYB/b4" "$PYB/inner/r"
  note5 "$PYB/mf/b" "x"
  note5 "$PYB/b6" "Fixed in commit $REAL_SHA."; note5 "$PYB/b6/sub" "x"
  py_unreadable() { # <label> — the unreadable-folder verdicts, with the environment as it stands
    local lbl="$1" rc
    chmod 000 "$PYB/lockedfile"
    rc=$(run "$PYB/b1" --host-paths); chmod 755 "$PYB/lockedfile"
    { [ "$rc" = "0" ] && grep -q 'cannot stat' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt"; } \
      && ok "S39-PY-01 $lbl: a cited file under a folder nobody may enter is UNRESOLVED 'cannot stat', not REFUTED (exit 0)" \
      || bad "S39-PY-01 $lbl" "exit $rc: $(grep -E '^  (ok|REFUTED|unresolved)|cannot|Traceback' "$TMP/out.txt" | head -3 | cut -c1-200 | tr '\n' '|')"
    chmod 000 "$PYB/outer"
    rc=$(run "$PYB/outer/bundle"); chmod 755 "$PYB/outer"
    { [ "$rc" = "2" ] && grep -q "^error: .*outer/bundle cannot be read" "$TMP/out.txt" && ! grep -q 'not a directory' "$TMP/out.txt"; } \
      && ok "S39-PY-02 $lbl: a bundle under a folder nobody may enter is 'cannot be read', not 'is not a directory' (exit 2)" \
      || bad "S39-PY-02 $lbl" "exit $rc: $(head -2 "$TMP/out.txt" | cut -c1-200 | tr '\n' '|')"
    chmod 000 "$PYB/lrepo/docs"
    rc=$(run "$PYB/b3" --repo "$PYB/lrepo"); chmod 755 "$PYB/lrepo/docs"
    { [ "$rc" = "0" ] && ! grep -q Traceback "$TMP/out.txt" && grep -q 'cannot be looked up: docs/spec.md' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt"; } \
      && ok "S39-PY-03 $lbl: a line citation into a --repo folder nobody may enter is UNRESOLVED 'cannot be looked up', no traceback (exit 0)" \
      || bad "S39-PY-03 $lbl" "exit $rc: $(head -4 "$TMP/out.txt" | cut -c1-200 | tr '\n' '|')"
    chmod 000 "$PYB/mf/b"
    rc=$(run "$PYB/mf/b" --check-config); chmod 755 "$PYB/mf/b"
    { [ "$rc" = "2" ] && grep -q 'okf-base.yaml cannot read: Permission denied' "$TMP/out.txt"; } \
      && ok "S39-PY-04 $lbl: --check-config in a bundle folder nobody may enter is 'cannot read' (exit 2), not 'no manifest, fine'" \
      || bad "S39-PY-04 $lbl" "exit $rc: $(head -2 "$TMP/out.txt" | cut -c1-200 | tr '\n' '|')"
    chmod 0400 "$PYB/b6/sub"
    rc=$(run "$PYB/b6"); chmod 755 "$PYB/b6/sub"
    { [ "$rc" = "2" ] && grep -q 'contains directories this process cannot read' "$TMP/out.txt" && grep -q 'unreadable: .*b6/sub' "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt"; } \
      && ok "S39-PY-11 $lbl: a bundle folder that lists but cannot be entered (mode 0400) is named 'contains directories this process cannot read' (exit 2), no traceback" \
      || bad "S39-PY-11 $lbl" "exit $rc: $(head -3 "$TMP/out.txt" | cut -c1-200 | tr '\n' '|')"
    chmod 000 "$PYB/inner"
    rc=$(run "$PYB/b4"); chmod 755 "$PYB/inner"
    { [ "$rc" = "0" ] && ! grep -q Traceback "$TMP/out.txt" && grep -q 'not searched since 0.9.50' "$TMP/out.txt"; } \
      && ok "S39-PY-05 $lbl: a declared repository under a folder nobody may enter is reported 'not searched', no traceback (exit 0)" \
      || bad "S39-PY-05 $lbl" "exit $rc: $(head -4 "$TMP/out.txt" | cut -c1-200 | tr '\n' '|')"
  }
  py_unreadable "as run"
  PYTHONPATH="$TMP/py314${PYTHONPATH:+:$PYTHONPATH}" py_unreadable "with Path predicates that answer False for an OSError (3.14 behaviour)"
else
  skip "S39-PY a folder nobody may enter — running as root, chmod 000 does not stop the read (skip, not a pass)"
fi
# --- RV-31: what git answers about one commit and one file is asked once per run. 20 citations of different lines of one file at one
# commit used to spawn about 6 git processes each; the count must not grow with the citations.
{ printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n'; for i in $(seq 1 20); do echo "Cite src/a.py:$i @$C2."; echo; done; } > "$TMP/c-p1.md"
[ "$(wc -c < "$TMP/c-p1.md" | tr -d ' ')" -lt 1048576 ] || { echo "fixture too large"; exit 2; }
mkb "$TMP/c-p1"; cp "$TMP/c-p1.md" "$TMP/c-p1/n.md"; : > "$TMP/gitspy.log"
PATH="$TMP/gitspy:$PATH" "$VERIFY" "$TMP/c-p1" --repo "$CREPO" >"$TMP/out.txt" 2>&1
n=$(wc -l < "$TMP/gitspy.log" | tr -d ' ')
{ grep -q 'CONFIRMED 20 ' "$TMP/out.txt" && [ "$n" -le 20 ]; } && ok "RV-31 (S29-SP-H1) 20 citations of one file at one commit run at most 20 git processes (ran $n)" || bad "RV-31 S29-SP-H1 spawns" "git ran $n times: $(grep -E 'CONFIRMED' "$TMP/out.txt")"
# S29-SP-N1: an answer given by a git that did not run (here: killed by a signal on its first call) is not kept. The first
# citation is UNRESOLVED (nobody could look); the second, of another line of the same file at the same commit, is CONFIRMED.
mkdir -p "$TMP/gitflaky"; printf '#!/bin/sh\nif [ ! -e "%s/flaky.once" ]; then : > "%s/flaky.once"; kill -9 $$; fi\nexec "%s" "$@"\n' "$TMP" "$TMP" "$(command -v git)" > "$TMP/gitflaky/git"; chmod +x "$TMP/gitflaky/git"
rm -f "$TMP/flaky.once"; cite "$TMP/c-p2" "src/a.py:1 @$C2 and src/a.py:2 @$C2"
PATH="$TMP/gitflaky:$PATH" "$VERIFY" "$TMP/c-p2" --repo "$CREPO" >"$TMP/out.txt" 2>&1
{ grep -q 'CONFIRMED 1 ' "$TMP/out.txt" && grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt"; } && ok "RV-31 (S29-SP-N1) a git killed on its first call is not remembered: one citation UNRESOLVED, the next CONFIRMED, none REFUTED" || bad_hard "RV-31 S29-SP-N1 flaky git" "$(grep -E 'CONFIRMED|^  (ok|unresolved|REFUTED)' "$TMP/out.txt" | cut -c1-140 | tr '\n' '|')"
# --- S43: a cited blob is read in pieces; memory does not grow with it. A git stand-in writes a 24 MB, 300000-line blob to the pipe
# (no file of that size exists here), and the peak Python memory of the run (tracemalloc) must stay far below the blob. Real 1, 100
# and 300 MB blobs are measured in a memory-capped container (docs/0.9.x-cases.md S43), never on this machine.
BREPO="$TMP/brepo"; mkdir -p "$BREPO"; git -C "$BREPO" init -q 2>/dev/null
git -C "$BREPO" config user.email t@t; git -C "$BREPO" config user.name t
printf 'tiny\n' > "$BREPO/big.txt"; git -C "$BREPO" add big.txt
git -C "$BREPO" -c commit.gpgsign=false -c credential.helper= commit -qm "feat: big.txt"
BS=$(git -C "$BREPO" rev-parse --short HEAD)
mkdir -p "$TMP/gitbig"
cat > "$TMP/gitbig/git" <<'SHEOF'
#!/bin/sh
case "$*" in *"cat-file blob"*) exec @PY@ -c 'import sys
w = sys.stdout.buffer.write
for k in range(300):
    w("".join("row %06d the quick brown fox jumps over the lazy dog and keeps running far away\n" % i for i in range(k * 1000 + 1, k * 1000 + 1001)).encode())' ;; esac
exec @GIT@ "$@"
SHEOF
sed -i.bak -e "s|@PY@|$REALPY|" -e "s|@GIT@|$(command -v git)|" "$TMP/gitbig/git"; rm -f "$TMP/gitbig/git.bak"; chmod +x "$TMP/gitbig/git"
cat > "$TMP/peak.py" <<'PYEOF'
import os, runpy, sys, tracemalloc
tracemalloc.start()
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name="__main__")
except SystemExit:
    pass
open(os.environ["PEAKFILE"], "w").write(str(tracemalloc.get_traced_memory()[1]))
PYEOF
bigrun() { PEAKFILE="$TMP/peak.txt" PATH="$TMP/gitbig:$PATH" "$REALPY" "$TMP/peak.py" "$VERIFY" "$@" >"$TMP/out.txt" 2>&1; }
cite "$TMP/bg0" "big.txt:1 @$BS"   # the same run on the 5-byte blob: what the interpreter and the module cost by themselves
PEAKFILE="$TMP/peak0.txt" "$REALPY" "$TMP/peak.py" "$VERIFY" "$TMP/bg0" --repo "$BREPO" >"$TMP/out.txt" 2>&1; base=$(cat "$TMP/peak0.txt" 2>/dev/null || echo 0)
cite "$TMP/bg1" "big.txt:5 @$BS and big.txt:300000 @$BS and big.txt:300001 @$BS and big.txt:5 @$BS \"row 000005 the quick\" and big.txt:6 @$BS \"row 000005 the quick\" and big.txt:299999-300000 @$BS \"row 300000 the\""
bigrun "$TMP/bg1" --repo "$BREPO"; peak=$(cat "$TMP/peak.txt" 2>/dev/null || echo 999999999)
[ "$base" -gt 0 ] && [ "$peak" -lt $((base + 2000000)) ] && ok "S43-H1 a 24 MB cited blob is read in pieces: peak Python memory $peak bytes, $((peak - base)) over a 5-byte blob (limit 2 MB)" || bad_hard "S43-H1 peak memory" "peak $peak bytes for a 24 MB blob, $base for a 5-byte one"
{ grep -q 'CONFIRMED 4 ' "$TMP/out.txt" && grep -q 'REFUTED 2 ' "$TMP/out.txt"; } && ok "S43-H2 verdicts on the streamed blob: lines in range CONFIRMED, line 300001 REFUTED, a quoted text on its line CONFIRMED and on another line REFUTED" || bad_hard "S43-H2 verdicts" "$(grep -E '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt" | cut -c1-120 | tr '\n' '|')"
cite "$TMP/bg2" "big.txt:5-100 @$BS \"row 000099 the\""
OKF_VERIFY_SPAN_LIMIT=1000 bigrun "$TMP/bg2" --repo "$BREPO"
{ grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt" && grep -q 'more than 1000 bytes' "$TMP/out.txt"; } && ok "S43-N1 cited lines above the byte limit are UNRESOLVED with the reason, never REFUTED" || bad_hard "S43-N1 span limit" "$(grep -E '^  (ok  |REFUTED|unresolved)' "$TMP/out.txt" | cut -c1-160 | tr '\n' '|')"

# S43-H3: --since reads the cited file at the ref in pieces too. The note and a 9-line decision.md are committed; decision.md at the ref
# is replaced, by a git stand-in, with the 24 MB blob; in the working tree one line was added above the cited text (row 5 is now on
# line 6). The run must say MOVED to line 6, and stay within 2 MB of the same run on a small file at the ref.
SN="$TMP/sn1"; mkb "$SN"; git -C "$SN" init -q 2>/dev/null; git -C "$SN" config user.email t@t; git -C "$SN" config user.name t
{ for i in 1 2 3 4 5 6 7 8 9; do printf 'row %06d the quick brown fox jumps over the lazy dog and keeps running far away\n' "$i"; done; } > "$SN/decision.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee decision.md:5.\n' > "$SN/n.md"
git -C "$SN" add -A; git -C "$SN" -c commit.gpgsign=false -c credential.helper= commit -qm base
{ echo "a new first line"; cat "$SN/decision.md"; } > "$SN/d.tmp"; mv "$SN/d.tmp" "$SN/decision.md"
PEAKFILE="$TMP/peak0.txt" "$REALPY" "$TMP/peak.py" "$VERIFY" "$SN" --since HEAD >"$TMP/out0.txt" 2>&1; base=$(cat "$TMP/peak0.txt" 2>/dev/null || echo 0)
mkdir -p "$TMP/gitsince"; sed 's|\*"cat-file blob"\*)|*"HEAD:decision.md"*)|' "$TMP/gitbig/git" > "$TMP/gitsince/git"; chmod +x "$TMP/gitsince/git"
PEAKFILE="$TMP/peak.txt" PATH="$TMP/gitsince:$PATH" "$REALPY" "$TMP/peak.py" "$VERIFY" "$SN" --since HEAD >"$TMP/out.txt" 2>&1; peak=$(cat "$TMP/peak.txt" 2>/dev/null || echo 999999999)
{ grep -q 'MOVED' "$TMP/out0.txt" && grep -q 'now on line 6' "$TMP/out0.txt"; } || bad_hard "S43-H3 baseline" "$(grep -aE 'MOVED|ok  |REFUTED' "$TMP/out0.txt" | cut -c1-160 | tr '\n' '|')"
{ [ "$base" -gt 0 ] && [ "$peak" -lt $((base + 2000000)) ] && grep -q 'now on line 6' "$TMP/out.txt"; } && ok "S43-H3 --since with a 24 MB file at the ref: MOVED to line 6, peak Python memory $((peak - base)) bytes over the small-file run (limit 2 MB)" || bad_hard "S43-H3 --since peak memory" "peak $peak bytes, $base for the small file: $(grep -aE 'MOVED|ok  |REFUTED|unresolved' "$TMP/out.txt" | cut -c1-160 | tr '\n' '|')"

# S43-N2: a binary file or a symlink at the --since ref is not compared, and the report says so (it used to be compared as text).
SB="$TMP/sn2"; mkb "$SB"; git -C "$SB" init -q 2>/dev/null; git -C "$SB" config user.email t@t; git -C "$SB" config user.name t
printf 'one\ntwo\0three\nfour\n' > "$SB/bin.md"; printf 'one\ntwo\nthree\n' > "$SB/real.md"; ln -s real.md "$SB/lnk.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee bin.md:2 and lnk.md:2.\n' > "$SB/n.md"
git -C "$SB" add -A; git -C "$SB" -c commit.gpgsign=false -c credential.helper= commit -qm base
rm "$SB/lnk.md"; printf 'new\none\ntwo\nthree\n' > "$SB/lnk.md"; printf 'new\none\ntwo\nthree\n' > "$SB/bin.md"
rc=$(run "$SB" --since HEAD)
[ "$(grep -c 'not compared: binary or symlink at HEAD' "$TMP/out.txt")" = 2 ] && ok "S43-N2 a binary file and a symlink at the --since ref each say 'not compared', never silently" || bad_hard "S43-N2 binary or symlink at the ref" "rc=$rc $(grep -aE '^  (ok|MOVED|REFUTED|unresolved)|!' "$TMP/out.txt" | cut -c1-140 | tr '\n' '|')"
# S43-N3: a note at the --since ref over the byte limit is named, not read as "never cited".
rc=$(OKF_VERIFY_SPAN_LIMIT=150 "$VERIFY" "$SN" --since HEAD >"$TMP/out.txt" 2>&1; printf '%s' "$?")
{ grep -q 'note at HEAD too large to compare' "$TMP/out.txt" && ! grep -q 'MOVED' "$TMP/out.txt"; } && ok "S43-N3 a note over the limit at the --since ref is named 'too large to compare'" || bad_hard "S43-N3 note too large at the ref" "rc=$rc $(grep -aE '^  (ok|MOVED|REFUTED|unresolved)|!' "$TMP/out.txt" | cut -c1-140 | tr '\n' '|')"
# S43-N4: an exception inside the reader leaves no git behind (the stand-in writes its pid, sends 70000 bytes, then sleeps).
mkdir -p "$TMP/gitkill"; printf '#!/bin/sh\ncase "$*" in *"cat-file blob"*) echo $$ > "%s/kill.pid"; head -c 70000 /dev/zero | tr "\\000" x; exec sleep 30;; esac\nexec "%s" "$@"\n' "$TMP" "$(command -v git)" > "$TMP/gitkill/git"; chmod +x "$TMP/gitkill/git"
PATH="$TMP/gitkill:$PATH" "$REALPY" -c '
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_verify_t", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_verify_t", loader)); loader.exec_module(mod)
def feed(chunk):
    raise RuntimeError("boom")
try:
    mod._stream_blob(Path(sys.argv[2]), "HEAD", "decision.md", feed)
except RuntimeError:
    sys.exit(0)
sys.exit(3)' "$VERIFY" "$SN" >"$TMP/out.txt" 2>&1; rc=$?
pid=$(cat "$TMP/kill.pid" 2>/dev/null || echo 0)
{ [ "$rc" = 0 ] && [ "$pid" -gt 0 ] && ! kill -0 "$pid" 2>/dev/null; } && ok "S43-N4 an exception raised while the blob is read leaves no git process running" || { [ "$pid" -gt 0 ] && kill "$pid" 2>/dev/null; bad_hard "S43-N4 git left running" "rc=$rc pid=$pid $(cat "$TMP/out.txt" | tail -3 | tr '\n' '|')"; }

# --- RV-32 (S3-CE-1): a bundle typed in another case than its folder, citing a path in the SAME typed case. case_exact judged every
# component of the cited path from `/`, so the typed `repo` (the folder is `Repo`) made every cited path UNRESOLVED, and --strict failed.
# Only the part below the bundle is the citation. A wrong case BELOW the bundle is still a case-variant (guard). Skipped where the
# filesystem is case-sensitive: there `repo` and `Repo` are two folders and the defect cannot occur.
CE="$TMP/ce32"; mkdir -p "$CE/Repo/b"; : > "$CE/Repo/b/in.txt"; mkb "$CE/Repo/b"
if [ -e "$CE/REPO/B/IN.TXT" ]; then
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/repo/b/in.txt`.\n' "$CE" > "$CE/Repo/b/note.md"
  rc=$(run "$CE/repo/b" --strict)
  { [ "$rc" = 0 ] && grep -qE '^  ok  ' "$TMP/out.txt"; } \
    && ok "RV-32 (S3-CE-1) a bundle typed in another case, citing a path in that typed case, is CONFIRMED (--strict exit 0)" \
    || bad "RV-32 S3-CE-1 typed-case bundle" "exit $rc: $(grep -E '^  (ok|unresolved)|case' "$TMP/out.txt" | head -2 | cut -c1-200 | tr '\n' '|')"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/repo/b/IN.TXT`.\n' "$CE" > "$CE/Repo/b/note.md"
  rc=$(run "$CE/repo/b")
  { [ "$rc" = 0 ] && grep -qE '^  unresolved ' "$TMP/out.txt" && grep -q 'case-variant' "$TMP/out.txt"; } \
    && ok "RV-32 (S3-CE-1 guard) a wrong case below the bundle is still UNRESOLVED as a case-variant" \
    || bad "RV-32 S3-CE-1 guard" "exit $rc: $(grep -E 'unresolved|case' "$TMP/out.txt" | head -2 | cut -c1-200 | tr '\n' '|')"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/Repo/b/in.txt`.\n' "$CE" > "$CE/Repo/b/note.md"
  rc=$(run "$CE/repo/b")
  { [ "$rc" = 0 ] && grep -qE '^  unresolved ' "$TMP/out.txt" && grep -q 'typed in another case than this path' "$TMP/out.txt"; } \
    && ok "RV-32 (S3-CE-1 message) a path outside only because the bundle is typed in another case says so" \
    || bad "RV-32 S3-CE-1 message" "exit $rc: $(grep -E '^  (ok|unresolved)|outside' "$TMP/out.txt" | head -2 | cut -c1-200 | tr '\n' '|')"
else
  skip "RV-32 (S3-CE-1) — filesystem is case-sensitive, the defect cannot occur (skip, not a pass)"
fi
# --- RV-25: a {type: boolean} node, a {map: node} node (free keys) and a node that {requires} a sibling value
RVID=RV-25
cc() { # <name> <okf_check body, printf %b> <want rc> [message the error must contain]
  note5 "$TMP/$1" "x"; printf 'okf_check:\n%b' "$2" > "$TMP/$1/okf-base.yaml"; rc=$(run "$TMP/$1" --check-config)
  { [ "$rc" = "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" "$TMP/out.txt"; }; } && ok "$RVID $1: exit $3${4:+, says '$4'}" || bad "$RVID $1" "exit $rc: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
}
cc bool-ok   '  require_owner: true\n' 0
cc bool-str  '  require_owner: yes-please\n' 2 'okf_check.require_owner must be true or false'
cc map-ok    '  require_owner: true\n  owners:\n    "decisions/**": team:a\n    "x/": human:dana\n' 0
cc map-list  '  require_owner: true\n  owners: [team:a]\n' 2 'okf_check.owners must be a mapping'
cc map-value '  require_owner: true\n  owners:\n    "decisions/**": 3\n' 2 'okf_check.owners.decisions/** must be a non-empty string'
cc requires  '  owners:\n    "decisions/**": team:a\n' 2 'okf_check.owners needs okf_check.require_owner: true'
cc negation  '  require_owner: true\n  owners:\n    "!x/**": team:a\n' 2 'okf_check.owners.!x/**: a pattern that starts with ! (negation) is not supported'
# --- RV-26: a {type: number, min, max} node (okf_check.duplicates.threshold / time_limit)
RVID=RV-26
cc num-ok    '  duplicates:\n    threshold: 0.5\n    time_limit: 30\n' 0
cc num-int   '  duplicates:\n    threshold: 1\n' 0
cc num-high  '  duplicates:\n    threshold: 5\n' 2 'okf_check.duplicates.threshold must be a number from 0.1 to 1'
cc num-str   '  duplicates:\n    time_limit: soon\n' 2 'okf_check.duplicates.time_limit must be a number from 1 to 3600'
cc num-bool  '  duplicates:\n    threshold: true\n' 2 'okf_check.duplicates.threshold must be a number'

# S36-ON-VF: notes named with a space, an ESC byte and a byte that is not UTF-8 are verified like any other. The .okfignore keep
# list and the okf_check.verify.generated match carry names to and from ignore-lib.sh: they were decoded with errors="replace",
# so with a .okfignore the odd-named note was skipped without a word, and with `generated` set okf-verify stopped with a
# traceback (a name that is not UTF-8 cannot be encoded back). Each of the three notes cites missing.md:3 (UNRESOLVED), so a
# skipped note is a missing line. The text and --json spell the names e\x1bx.md and n\xffu.md, never raw. Under the C locale
# and a UTF-8 one; a disk that refuses the name (APFS) skips the case.
U8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
for CASE in ignore generated; do
  B="$TMP/on-vf-$CASE"; mkb "$B"
  case "$CASE" in
    ignore)    printf 'ign.md\n' > "$B/.okfignore"
               printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\n---\nNot a claim.\n' > "$B/ign.md" ;;
    generated) printf 'okf_check:\n  verify:\n    generated: ["g*.md"]\n' > "$B/okf-base.yaml" ;;
  esac
  for n in 'a b' "e$(printf '\033')x" "n$(printf '\377')u"; do
    printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\n---\nSee missing.md:3 for it.\n' > "$B/$n.md" 2>/dev/null
  done
  if [ ! -f "$B/n$(printf '\377')u.md" ]; then
    skip "S36-ON-VF ($CASE) this disk refuses a note name that is not UTF-8 (run on Linux)"
  elif [ -z "$U8" ]; then
    skip "S36-ON-VF ($CASE) no UTF-8 locale here (locale -a lists neither C.UTF-8 nor en_US.UTF-8)"
  else
    for LOC in C "$U8"; do
      rc=$(LC_ALL="$LOC" run "$B"); nu=$(LC_ALL=C grep -a -c '^  unresolved .*missing.md:3' "$TMP/out.txt")
      raw=$("$REALPY" -c 'import re,sys
n = 0
for ln in open(sys.argv[1], "rb").read().split(b"\n"):
    try: t = ln.decode("utf-8")
    except UnicodeDecodeError: n += 1; continue
    if re.search("[\\x00-\\x1f\\x7f-\\x9f]", t): n += 1
print(n)' "$TMP/out.txt"); named=$(LC_ALL=C grep -a -c 'e\\x1bx.md\|n\\xffu.md' "$TMP/out.txt")
      LC_ALL="$LOC" "$VERIFY" "$B" --json >"$TMP/out.json" 2>/dev/null
      got=$("$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(sorted({r["concept"] for r in d["results"]})))' "$TMP/out.json" 2>&1)
      { [ "$rc" = 0 ] && [ "$nu" = 3 ] && [ "$raw" = 0 ] && [ "$named" -ge 2 ] && [ "$got" = '["a b.md", "e\\x1bx.md", "n\\xffu.md"]' ]; } \
        && ok "S36-ON-VF under LC_ALL=$LOC ($CASE) okf-verify checks all three odd-named notes; the text and --json spell them \\x1b and \\xff (exit 0)" \
        || bad "S36-ON-VF odd names under $LOC ($CASE)" "rc=$rc unresolved lines=$nu raw lines=$raw named=$named concepts=$got $(grep -a -m2 'Traceback\|Error' "$TMP/out.txt" | cat -v | tr '\n' '|')"
    done
  fi
done

# S36-ON-SK: the report skeleton of okf-verify is byte-for-byte what it was for an ASCII bundle: the header, the indent of each
# line, the blank line before the totals, the legend and the verdict line. A name or a claim is spelled where it is printed
# (okf_guard.shown), never the line around it: the totals line was once printed as "\x0a  CONFIRMED ..." because the whole
# line, its line break included, went through the spelling. The expected text is the output of the 0.9.40 script for this bundle.
SK="$TMP/on-sk"; mkb "$SK"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\n---\nSee d.md:2 and fixed in commit deadbe3.\n' > "$SK/c.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\n---\nNo claim here.\nSecond line.\n' > "$SK/d.md"
rc=$(run "$SK"); sed "s|$SK|BUNDLE|" "$TMP/out.txt" > "$TMP/on-sk.txt"
cat > "$TMP/on-sk.want" <<'WANT'
okf-verify — BUNDLE
  repos searched: NONE (SHAs cannot be checked)
  ok          c.md  [line] d.md:2
  unresolved  c.md  [sha] deadbe3
              no repository searched (pass --repo to check SHAs)
  1 concept(s) carry no checkable claim — unverifiable, not verified:
              d.md

  CONFIRMED 1   REFUTED 0   UNRESOLVED 1
  UNRESOLVED means NOT CHECKED — it is not a soft REFUTED and must not be read as one.
  no refuted claims
WANT
{ [ "$rc" = 0 ] && cmp -s "$TMP/on-sk.txt" "$TMP/on-sk.want"; } \
  && ok "S36-ON-SK the text report of an ASCII bundle is the 0.9.40 report, byte for byte" \
  || bad "S36-ON-SK report skeleton" "rc=$rc $(diff "$TMP/on-sk.want" "$TMP/on-sk.txt" | cat -v | head -4 | tr '\n' '|')"

# S36-ON-VJ: --json keeps the content fields as they were: a control character in a quoted example stays the JSON escape \u001b
# (spelling it \x1b would change the contract for content), while the TEXT report spells it \x1b for the terminal. Only a name
# (concept, a path) is spelled in --json, and a byte that is not UTF-8 in any field (a lone surrogate is not valid JSON text).
VJ="$TMP/on-vj"; mkb "$VJ"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\n---\nNo claim, only Step%sx:12 here.\n' "$(printf '\033')" > "$VJ/c.md"
rc=$(run "$VJ"); rawesc=$(LC_ALL=C grep -a -c "$(printf '\033')" "$TMP/out.txt"); sp=$(LC_ALL=C grep -a -c 'e\.g\. Step\\x1bx:12' "$TMP/out.txt")
"$VERIFY" "$VJ" --json >"$TMP/on-vj.json" 2>/dev/null
ex=$(LC_ALL=C grep -a -c '"Step\\u001bx:12"' "$TMP/on-vj.json")
{ [ "$rc" = 0 ] && [ "$rawesc" = 0 ] && [ "$sp" = 1 ] && [ "$ex" = 1 ]; } \
  && ok "S36-ON-VJ --json keeps a control character in a quoted example as \\u001b; the text spells it \\x1b" \
  || bad "S36-ON-VJ content in --json" "rc=$rc raw ESC in text=$rawesc spelled in text=$sp json example=$ex $(grep -a -m1 examples -A1 "$TMP/on-vj.json" | cat -v | tr '\n' '|')"

echo
# Before the summary: the gate runners take only a suite's LAST line as its summary, and a wrapped `rm` can print.
if [ "$FAIL" -gt 0 ]; then
  echo "  diagnostic snapshot: $FAILCTX"
  echo "  (this suite has an unreproduced intermittent failure mode — if that is"
  echo "   what you just hit, that file is the evidence nobody has captured yet)"
else
  rm -f "$FAILCTX" >/dev/null 2>&1
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
