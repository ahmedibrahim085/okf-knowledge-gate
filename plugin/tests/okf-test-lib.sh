# okf-test-lib.sh — helpers the okf-check suites share. Sourced, never run: `. "$HERE/../tests/okf-test-lib.sh"`.
#
# It lives outside plugin/scripts on purpose: plugin.test.sh Z-2 fails on any script there that nothing but a
# test references. One copy of the helpers means the suites split out of okf-check.test.sh cannot
# drift apart. Each sourcing suite gets its OWN `mktemp -d` TMP and counters, so suites run in parallel.
#
# OKF_TEST_TIMING=1 prints one `TIMING <secs>s <n> asserts <name>` line per `section "<name>"` call.
# bash 3.2 compatible (macOS ships 3.2 — no `declare -A`, no `mapfile`).

PASS=0; FAIL=0
REALPY=$(command -v python3)   # defined ONCE, before any sandbox stub uses it
. "$(dirname "${BASH_SOURCE[0]}")/cite-sha.sh"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfchecktest)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

SKIPPED=0
# A skip is COVERAGE THAT DID NOT RUN, and it was invisible in the summary: a
# run that quietly tested less printed the same "0 failed" as a run that tested
# everything. Measured this session — E-7d skipped 8/12 in one configuration and
# 0/12 in another — so "0 failed" alone has never been a complete claim. Count
# them and print them; then a green line means green AND complete.
# skip <message> [remedy] — a skip is coverage that did not run, and an opaque
# one leaves the reader with no way to close it. The optional remedy is
# collected and printed with the summary, so "coverage did not run in full"
# comes with the command that makes it run. Preconditions we cannot remove
# (optional dependencies) at least stop being silent dead ends.
SKIP_REMEDIES=""
skip() {
  SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"
  [ -n "${2:-}" ] && case "$SKIP_REMEDIES" in
    *"$2"*) ;;                       # each remedy listed once
    *) SKIP_REMEDIES="$SKIP_REMEDIES
      $2" ;;
  esac
  return 0
}

# expect_exit <expected> <label> -- <cmd...>
expect_exit() {
  local want="$1" label="$2"; shift 3
  "$@" >"$TMP/out.txt" 2>&1; local got=$?
  [ "$got" -eq "$want" ] && ok "$label (exit $got)" \
    || bad "$label" "expected exit $want, got $got; output: $(head -3 "$TMP/out.txt" | tr '\n' ' ')"
}

expect_match() {
  local pat="$1" label="$2"; shift 2
  "$@" >"$TMP/out.txt" 2>&1
  grep -q "$pat" "$TMP/out.txt" && ok "$label" \
    || bad "$label" "output did not match '$pat': $(head -3 "$TMP/out.txt" | tr '\n' ' ')"
}

expect_no_match() {
  local pat="$1" label="$2"; shift 2
  "$@" >"$TMP/out.txt" 2>&1
  grep -q "$pat" "$TMP/out.txt" && bad "$label" "output unexpectedly matched '$pat'" || ok "$label"
}

mkbundle() { # <dir> — a minimal conformant bundle
  mkdir -p "$1"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$1/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n'   > "$1/log.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$1/c.md"
}

# okf_now_ms — the clock in milliseconds, for the timing mode only (a plain run never calls it). bash 3.2 (macOS) has no
# EPOCHREALTIME, so perl or python3 is asked, once per section edge; with neither, whole seconds from $SECONDS.
okf_now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000)); return; fi
  t=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null); [ -z "$t" ] || { echo "$t"; return; }
  t=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null); [ -z "$t" ] || { echo "$t"; return; }
  echo $((SECONDS * 1000))
}
# section <name> — marks where a section of a suite starts. With OKF_TEST_TIMING=1 it closes the section before it
# with one line: seconds to a hundredth and the asserts that ran in it (pass + fail + skip). A plain run prints nothing.
TIMING_NAME=""; TIMING_T0=0; TIMING_N0=0
section_flush() {
  [ -n "$TIMING_NAME" ] || return 0
  local ms; ms=$(( $(okf_now_ms) - TIMING_T0 ))
  printf 'TIMING %4s.%02ds %4s asserts  %s\n' "$((ms / 1000))" "$((ms % 1000 / 10))" "$((PASS+FAIL+SKIPPED-TIMING_N0))" "$TIMING_NAME"
  TIMING_NAME=""
}
section() {
  [ "${OKF_TEST_TIMING:-}" = 1 ] || return 0
  section_flush
  TIMING_NAME=$1; TIMING_T0=$(okf_now_ms); TIMING_N0=$((PASS+FAIL+SKIPPED))
}

# okf_test_summary — the closing lines every suite prints; the suite's own last line is `[ "$FAIL" -eq 0 ] || exit 1`.
okf_test_summary() {
  [ "${OKF_TEST_TIMING:-}" = 1 ] && section_flush
  echo
  if [ "$SKIPPED" -gt 0 ]; then
    # The remedies come first: the gate runners take only the LAST line of a suite as its summary.
    [ -n "$SKIP_REMEDIES" ] && {
      printf '  to run the skipped coverage:%s\n' "$SKIP_REMEDIES"
      printf '  or in one step: tools/install-dev-deps.sh --yes\n'
    }
    echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
  else
    echo "  $PASS passed, $FAIL failed"
  fi
  return 0
}
