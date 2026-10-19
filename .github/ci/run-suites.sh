#!/usr/bin/env bash
# run-suites.sh — the CI run of the release suites (.github/workflows/ci.yml). CI runs in the public repository; the script
# also runs in a private tree (tools/ci-workflow.test.sh does that on fixtures).
#
#   .github/ci/run-suites.sh        (from the repository root; okflint, pre-commit and the awk under test already on PATH)
#   exit 0 every suite and --selftest passed · 1 a suite or --selftest failed · 2 no suite found
#
# The suite list is OKF_LINUX_SUITES of tools/linux-gate.conf when the tree has it (the private repository), else every
# *.test.sh in the tree (the public export ships no tools/ but tools/demo). A suite passes by the rule both release gates
# use: the function below is a copy of tools/lib/suite-verdict.sh, which the public tree does not have;
# tools/ci-workflow.test.sh fails when the copy and the original differ.
# Why: the README says the suites pass on Linux; the release gate runs on the maintainer's machines, so nobody else could
# see it. This runs the same list on GitHub's runner, a non-root user as in tools/linux-gate.sh.
set -uo pipefail
unset CDPATH

# --- copy of tools/lib/suite-verdict.sh (keep byte-identical) ---
suite_verdict() {
  local last counts shown
  if [ "$2" -eq 124 ] && [ -n "${3:-}" ]; then echo "timed out after $3 s"; return 1; fi
  [ "$2" -eq 0 ] || { echo "exit $2"; return 1; }
  last=$(awk 'NF { l = $0 } END { print l }' "$1" 2>/dev/null)
  printf '%s\n' "$last" | grep -Eq '^[[:space:]]*[0-9]+ passed, [0-9]+ failed' \
    || { echo "no summary line (N passed, M failed) at the end: the suite stopped before its end"; return 1; }
  counts=$(printf '%s\n' "$last" | awk '{ print $1 + 0, $3 + 0 }')
  case "$counts" in
    "0 0") echo "0 passed: the suite counted no test"; return 1 ;;
    *" 0") ;;
    *) echo "${counts#* } failed"; return 1 ;;
  esac
  # Every suite prints "  PASS  <name>" for each pass: a summary that claims more passes than the log shows was echoed,
  # not counted (`echo "99 passed, 0 failed"; exit 0` ends with a summary line too).
  shown=$(grep -c '^  PASS  ' "$1" 2>/dev/null)
  [ "${shown:-0}" -ge "${counts%% *}" ] || { echo "the summary says ${counts%% *} passed but the log shows ${shown:-0} PASS line(s)"; return 1; }
  return 0
}
# --- end of copy ---

SUITE_TIMEOUT=${OKF_GATE_SUITE_TIMEOUT:-1800}
SUITES=""
if [ -f tools/linux-gate.conf ]; then
  SUITES=$(sed -n 's/^OKF_LINUX_SUITES=//p' tools/linux-gate.conf)
  t=$(sed -n 's/^OKF_GATE_SUITE_TIMEOUT=//p' tools/linux-gate.conf); [ -n "$t" ] && SUITE_TIMEOUT=$t
else
  SUITES=$(find . -name '*.test.sh' -not -path './.git/*' | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')
fi
[ -n "${SUITES// /}" ] || { echo "run-suites: no suite found"; exit 2; }

echo "run-suites: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -s)}") $(uname -m); bash $BASH_VERSION; $(python3 --version 2>&1); okflint $(python3 -c 'import importlib.metadata as m; print(m.version("okflint"))' 2>/dev/null || echo absent); $(pre-commit --version 2>/dev/null || echo 'pre-commit absent'); $(awk -W version 2>&1 | head -1); user $(id -un)"
log=$(mktemp); fail=0
for s in $SUITES; do
  start=$(date +%s)
  timeout -k 10 "$SUITE_TIMEOUT" bash "$s" < /dev/null > "$log" 2>&1; rc=$?
  why=$(suite_verdict "$log" "$rc" "$SUITE_TIMEOUT")
  printf '%-42s rc=%-3s %5ss  %s%s\n' "$s" "$rc" "$(( $(date +%s) - start ))" \
    "$(grep -E '[0-9]+ passed' "$log" | tail -1 | sed 's/^ *//')" "${why:+  GATE-FAIL: $why}"
  if [ -n "$why" ]; then
    fail=1
    echo "::group::$s — FAIL lines and the end of its log"
    grep -A1 '^  FAIL' "$log" | head -60; echo '...'; tail -20 "$log"
    echo "::endgroup::"
  fi
done
plugin/scripts/okf-check --selftest > "$log" 2>&1; rc=$?
printf '%-42s rc=%s\n' "okf-check --selftest" "$rc"
[ "$rc" -eq 0 ] || { fail=1; tail -20 "$log"; }
rm -f "$log"
exit "$fail"
