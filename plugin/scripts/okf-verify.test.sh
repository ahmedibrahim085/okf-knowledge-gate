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
trap 'rm -rf "$TMP" ${LOOPDIR:+"$LOOPDIR"}' EXIT   # LOOPDIR is set later; the trap is live before it exists
trap 'exit 130' INT
trap 'exit 143' TERM

# M6: the REFUTED tests need a parent directory that EXISTS and is NOT ephemeral.
# Anchoring on $HERE broke the suite when it was run from a copy under /tmp — a
# CI that checks out to an ephemeral path went red against correct code. Pick the
# first workable base instead of assuming one, and say so if none exists.
NONEPH=""
for cand in "$HOME" /usr/local /usr; do
  case "$cand" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/var/tmp/*|/private/var/tmp/*|/dev/shm/*) continue ;;
  esac
  [ -d "$cand" ] && { NONEPH="$cand"; break; }
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
grep -qE '^  CONFIRMED [1-9]|^  REFUTED [1-9]' "$TMP/out.txt" && bad "V-4 counts must show 0 refuted" "non-zero" \
  || ok "V-4 the summary counts confirm 0 refuted"
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
# left them behind for the next one (review round 1, 2026-10-14). Still under $NONEPH, so
# the parent is non-ephemeral as M6 requires.
# Sweep dirs a SIGKILLed run left behind (a trap cannot run on kill -9). Only this suite's own
# name pattern, only directly under $NONEPH, only older than a day: a parallel live run is safe.
find "$NONEPH" -maxdepth 1 -type d -name '.okfverify-d1.*' -mtime +0 -exec rm -rf {} + 2>/dev/null || :
LOOPDIR=""
LOOPDIR=$(mktemp -d "$NONEPH/.okfverify-d1.XXXXXX") || { echo "okf-verify.test: cannot create a loop dir under $NONEPH" >&2; exit 2; }
ln -sf "$LOOPDIR/d1_loopB.log" "$LOOPDIR/d1_loopA.log"
ln -sf "$LOOPDIR/d1_loopA.log" "$LOOPDIR/d1_loopB.log"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee `%s/d1_loopA.log`.\n' "$LOOPDIR" > "$D1/c.md"
run "$D1" >/dev/null
grep -qE '^  REFUTED ' "$TMP/out.txt" \
  && bad "D-1 a symlink loop is not REFUTED" "entry exists (lexists true) but was called absent" \
  || ok "D-1 an unresolvable symlink loop is not REFUTED"

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

# --- 0.9.4 #53: source repositories declared once in okf-base.yaml (okf_check.verify.repos) ---------------------------
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

# S1-H1: a declared repository is searched with no --repo flag
note5 "$TMP/s1h1" "Fixed in commit $REAL_SHA."; decl "$TMP/s1h1" "$REPO"
rc=$(run "$TMP/s1h1")
vok "RV-1 (S1-H1) a SHA in a repository declared in okf-base.yaml is CONFIRMED with no --repo"

# S1-H2: --repo adds to the declared list
note5 "$TMP/s1h2" "Fixed in commit $REAL_SHA and in commit $SHA2."; decl "$TMP/s1h2" "$REPO"
rc=$(run "$TMP/s1h2" --repo "$REPO2")
[ "$(grep -cE '^  ok  ' "$TMP/out.txt")" = "2" ] && ok "RV-2 (S1-H2) --repo adds to the declared repositories: both SHAs are CONFIRMED" \
  || bad "RV-2 (S1-H2) declared + --repo" "$(grep -E '^  (ok|unresolved)' "$TMP/out.txt" | tr '\n' ' ')"

# S1-N1: a declared path that does not exist is named, with its reason, and does not change the exit code
note5 "$TMP/s1n1" "Fixed in commit $REAL_SHA."; decl "$TMP/s1n1" "$TMP/no-such-repo-dir" "$REPO"
rc=$(run "$TMP/s1n1")
grep -qE 'declared repository not found: .*/no-such-repo-dir$' "$TMP/out.txt" && grep -qE '^  unresolved .*\[repo\]' "$TMP/out.txt" \
  && ok "RV-3 (S1-N1) a declared path that does not exist is UNRESOLVED and the reason says 'declared repository not found'" \
  || bad "RV-3 (S1-N1) missing declared path" "$(head -8 "$TMP/out.txt" | tr '\n' ' ')"
[ "$rc" = "0" ] && ok "RV-3 (S1-N1) the declaration alone does not change the exit code" || bad "RV-3 (S1-N1) exit code" "exit $rc"
vok "RV-3 (S1-N1) a valid declared repository next to the missing one is still searched"

# S1-N2: a declared folder that is not a git repository
mkdir -p "$TMP/s1-plain"
note5 "$TMP/s1n2" "Fixed in commit $REAL_SHA."; decl "$TMP/s1n2" "$TMP/s1-plain"
rc=$(run "$TMP/s1n2")
grep -qE 'not a git repository: .*/s1-plain$' "$TMP/out.txt" && grep -qE '^  unresolved .*\[repo\]' "$TMP/out.txt" \
  && ok "RV-4 (S1-N2) a declared folder that is not a git repository is UNRESOLVED with 'not a git repository'" \
  || bad "RV-4 (S1-N2) non-git declared folder" "$(head -8 "$TMP/out.txt" | tr '\n' ' ')"

# S1-E1: ~ is the home folder, a relative path is read from the bundle folder (not from the working directory)
mkdir -p "$S1H/src"; git clone -q "$REPO" "$S1H/src/x" 2>/dev/null
note5 "$TMP/s1e1" "Fixed in commit $REAL_SHA."; decl "$TMP/s1e1" "~/src/x"
rc=$(HOME="$S1H" run "$TMP/s1e1")
vok "RV-5 (S1-E1) a declared '~/src/x' expands to the home folder"
mkdir -p "$TMP/s1rel"; git clone -q "$REPO" "$TMP/s1rel/svc" 2>/dev/null
note5 "$TMP/s1rel/b" "Fixed in commit $REAL_SHA."; decl "$TMP/s1rel/b" "../svc"
rc=$(cd / && run "$TMP/s1rel/b")
vok "RV-5 (S1-E1) a declared '../svc' is read from the bundle folder, whatever the working directory"

# S1-E2: the same repository declared and passed is searched once
note5 "$TMP/s1e2" "Fixed in commit $REAL_SHA."; decl "$TMP/s1e2" "$REPO"
rc=$(run "$TMP/s1e2" --repo "$REPO/.")
n=$(grep -oE 'repos searched: .*' "$TMP/out.txt" | tr ',' '\n' | grep -c "$(basename "$REPO")")
[ "$n" = "1" ] && ok "RV-6 (S1-E2) a repository declared and passed with --repo is searched once" \
  || bad "RV-6 (S1-E2) searched once" "$(grep 'repos searched' "$TMP/out.txt")"

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

# --- 0.9.4 review round 1 (#66 + #53): ONE schema for the okf_check block, enforced by both tools ----------------------
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
# --- RV-24 (#67): an {enum: [...]} schema node (okf_check.deprecated_requires) takes only the listed values
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

# --- 0.9.4 review round 2 (#53): a declared path that cannot be resolved is UNRESOLVED, never a crash ---------------------
# `~nosuchuser/x` made expanduser() raise RuntimeError and an unreadable parent made exists() raise PermissionError: a traceback and exit 1,
# and exit 1 means "a claim was REFUTED". The entry is reported with the reason "cannot resolve" and the run goes on (exit 0, no REFUTED).
unres() { # <label> <bundle> — the run for <bundle> (already made) must report that declared repo as UNRESOLVED 'cannot resolve', in text and in --json
  local lbl="$1" b="$2" rc1 rc2
  rc2=$(run "$b" --repo "$REPO" --json)
  { [ "$rc2" = "0" ] && ! grep -q 'Traceback' "$TMP/out.txt" && grep -q '"kind": "repo"' "$TMP/out.txt" && grep -q 'cannot resolve' "$TMP/out.txt" && ! grep -q '"verdict": "REFUTED"' "$TMP/out.txt"; } \
    && ok "RV-18 $lbl, --json: UNRESOLVED 'cannot resolve', exit 0" || bad "RV-18 $lbl --json" "exit $rc2: $(head -6 "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
  rc1=$(run "$b" --repo "$REPO")
  { [ "$rc1" = "0" ] && ! grep -q 'Traceback' "$TMP/out.txt" && grep -qE '^  unresolved .*\[repo\]' "$TMP/out.txt" && grep -q 'cannot resolve' "$TMP/out.txt" && ! grep -qE '^  REFUTED ' "$TMP/out.txt"; } \
    && ok "RV-18 $lbl: UNRESOLVED 'cannot resolve', exit 0, no traceback" || bad "RV-18 $lbl" "exit $rc1: $(head -6 "$TMP/out.txt" | tr '\n' ' ' | cut -c1-300)"
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
# --- 0.9.5 #56: path:line @sha citations (sha + path; the line is #57) ------------------------------------------------
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

# S1 x S2 seam: a citation resolves against a repository declared in okf-base.yaml, with no --repo flag
cite "$TMP/seam1" "\`src/a.py:10 @$C2\`"; decl "$TMP/seam1" "$CREPO"
rc=$(run "$TMP/seam1")
vok "RV-19 (S1 x S2) a path:line @sha citation is CONFIRMED against a repository declared in okf-base.yaml (no --repo)"
cite "$TMP/seam2" "\`src/nope.py:3 @$C2\`"; decl "$TMP/seam2" "$CREPO"
rc=$(run "$TMP/seam2")
vrefuted "RV-19 (S1 x S2) ... and REFUTED the same way when the path is missing at that commit"

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

# --- 0.9.5 #57: the cited line (or the end of the range) must exist in the file AT THAT COMMIT --------------------------
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

# --- 0.9.5 review fixes (#57) ------------------------------------------------------------------------------------------------
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
cite "$TMP/sp1" "my dir/w.py:1 @$C5"; rc=$(run "$TMP/sp1" --repo "$CREPO")
{ [ "$rc" = "0" ] && grep -qE '^  unresolved ' "$TMP/out.txt" && ! grep -qE '^  (REFUTED|ok  ) ' "$TMP/out.txt"; } \
  && ok "RV-21 (S2-E3) 'my dir/w.py:1 @sha' (a space inside the path) is UNRESOLVED, not a false REFUTED of 'dir/w.py'" \
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
# --- RV-25 (#68): a {type: boolean} node, a {map: node} node (free keys) and a node that {requires} a sibling value
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
# --- RV-26 (#69): a {type: number, min, max} node (okf_check.duplicates.threshold / time_limit)
RVID=RV-26
cc num-ok    '  duplicates:\n    threshold: 0.5\n    time_limit: 30\n' 0
cc num-int   '  duplicates:\n    threshold: 1\n' 0
cc num-high  '  duplicates:\n    threshold: 5\n' 2 'okf_check.duplicates.threshold must be a number from 0.1 to 1'
cc num-str   '  duplicates:\n    time_limit: soon\n' 2 'okf_check.duplicates.time_limit must be a number from 1 to 3600'
cc num-bool  '  duplicates:\n    threshold: true\n' 2 'okf_check.duplicates.threshold must be a number'

echo
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
if [ "$FAIL" -gt 0 ]; then
  echo "  diagnostic snapshot: $FAILCTX"
  echo "  (this suite has an unreproduced intermittent failure mode — if that is"
  echo "   what you just hit, that file is the evidence nobody has captured yet)"
else
  rm -f "$FAILCTX"
fi
[ "$FAIL" -eq 0 ] || exit 1
