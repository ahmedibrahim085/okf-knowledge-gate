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
# Not as root: root ignores chmod, so the suites' permission tests would fail (the gates run them as a plain user).
[ "$(id -u)" -ne 0 ] || { echo "run-suites: refusing to run as root: run it as a plain user" >&2; exit 2; }

# --- copy of tools/lib/suite-verdict.sh (keep byte-identical) ---
suite_verdict() {
  local last counts shown
  if [ "$2" -eq 124 ] && [ -n "${3:-}" ]; then echo "timed out after $3 s"; return 1; fi
  [ "$2" -eq 0 ] || { echo "exit $2"; return 1; }
  last=$(awk 'NF { l = $0 } END { print l }' "$1" 2>/dev/null)
  grep -Eq '^[[:space:]]*[0-9]+ passed, [0-9]+ failed' <<<"$last" \
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

# OKF_LINUX_SUITES and OKF_GATE_SUITE_TIMEOUT in the environment win over the conf, as in tools/linux-gate.sh, which
# passes its own values in (review 0.9.35).
SUITE_TIMEOUT=1800
SUITES=""
if [ -f tools/linux-gate.conf ]; then
  SUITES=$(sed -n 's/^OKF_LINUX_SUITES=//p' tools/linux-gate.conf)
  t=$(sed -n 's/^OKF_GATE_SUITE_TIMEOUT=//p' tools/linux-gate.conf); [ -n "$t" ] && SUITE_TIMEOUT=$t
else
  SUITES=$(find . -name '*.test.sh' -not -path './.git/*' | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')
fi
SUITES=${OKF_LINUX_SUITES:-$SUITES}
SUITE_TIMEOUT=${OKF_GATE_SUITE_TIMEOUT:-$SUITE_TIMEOUT}
# Not passed on: a suite that runs this script on a fixture tree (tools/ci-workflow.test.sh) must read that tree's list.
unset OKF_LINUX_SUITES OKF_GATE_SUITE_TIMEOUT
[ -n "${SUITES// /}" ] || { echo "run-suites: no suite found"; exit 2; }

echo "run-suites: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -s)}") $(uname -m); bash $BASH_VERSION; $(python3 --version 2>&1); okflint $(python3 -c 'import importlib.metadata as m; print(m.version("okflint"))' 2>/dev/null || echo absent); $(pre-commit --version 2>/dev/null || echo 'pre-commit absent'); $(awk -W version 2>&1 | head -1); user $(id -un)"
# OKF_SUITE_JOBS (gate speed): how many suites run at once; default the CPU count, at most 4. Each suite has its own mktemp folder
# (plugin/tests/okf-test-lib.sh), so they do not share state; the suites in OKF_GATE_SIDE_BY_SIDE (the two heavy halves of
# the okf-check tests) start first. The report lists the suites in suite-list order, whatever order they finish in. A pool
# that waits on its oldest job, not `wait -n`: bash 3.2 (macOS) has no `wait -n`.
JOBS=${OKF_SUITE_JOBS:-$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 1)}
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
[ -n "${OKF_SUITE_JOBS:-}" ] || { [ "$JOBS" -le 4 ] || JOBS=4; }
unset OKF_SUITE_JOBS
SIDE=""
[ -f tools/linux-gate.conf ] && SIDE=$(sed -n 's/^OKF_GATE_SIDE_BY_SIDE=//p' tools/linux-gate.conf)
echo "run-suites: $JOBS suite(s) at a time"
# No bytecode: suites that run at once would race on plugin/scripts/__pycache__ (a copy taken mid-write fails).
export PYTHONDONTWRITEBYTECODE=1
WORK=$(mktemp -d); fail=0; pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# run_one <suite> <n>: run it under the time limit, its log in $WORK/<n>.log, its seconds and exit code in $WORK/<n>.rc.
run_one() {
  local start rc; start=$(date +%s)
  timeout -k 10 "$SUITE_TIMEOUT" bash "$1" < /dev/null > "$WORK/$2.log" 2>&1; rc=$?
  echo "$rc $(( $(date +%s) - start ))" > "$WORK/$2.rc"
}
# Start order: the side-by-side suites, then the rest by file size, largest first (the long suites are the big files: the
# run ends no sooner than its longest suite, so that one must not start last).
BYSIZE=$(for s in $SUITES; do printf '%s %s\n' "$(wc -c < "$s" | tr -d ' ')" "$s"; done | sort -rn | awk '{print $2}')
n=0; order=""
for s in $SIDE $BYSIZE; do
  case " $order " in *" $s "*) continue ;; esac   # a side-by-side suite is also in the list: run it once
  case " $SUITES " in *" $s "*) ;; *) continue ;; esac
  # A free slot is taken as soon as any job ends: poll with kill -0 (bash 3.2 has no `wait -n`). Waiting on the oldest job
  # instead left slots idle behind a long suite (0.9.34 gate: 907 s for a run whose longest suite took 570 s).
  while :; do
    live=""; for p in $pids; do if kill -0 "$p" 2>/dev/null; then live="$live $p"; else wait "$p"; fi; done; pids=$live
    set -- $pids; [ "$#" -lt "$JOBS" ] && break
    sleep 0.2
  done
  order="$order $s"; n=$((n + 1)); eval "idx_$n=\$s"
  run_one "$s" "$n" & pids="$pids $!"
done
for p in $pids; do wait "$p"; done
for s in $SUITES; do
  i=0; k=1; while [ "$k" -le "$n" ]; do eval "[ \"\$idx_$k\" = \"\$s\" ]" && i=$k; k=$((k + 1)); done
  [ "$i" -gt 0 ] || continue
  rc=255; secs=0   # no result file (the job was killed): a failure, never the previous suite's result
  [ -f "$WORK/$i.rc" ] && read -r rc secs < "$WORK/$i.rc"
  why=$(suite_verdict "$WORK/$i.log" "$rc" "$SUITE_TIMEOUT")
  printf '%-42s rc=%-3s %5ss  %s%s\n' "$s" "$rc" "$secs" \
    "$(grep -E '[0-9]+ passed' "$WORK/$i.log" | tail -1 | sed 's/^ *//')" "${why:+  GATE-FAIL: $why}"
  if [ -n "$why" ]; then
    fail=1
    echo "::group::$s — FAIL lines and the end of its log"
    # pipefail-safe: display only; the verdict above is already decided and this status is never tested.
    grep -A1 '^  FAIL' "$WORK/$i.log" | head -60; echo '...'; tail -20 "$WORK/$i.log"
    echo "::endgroup::"
  fi
done
log="$WORK/selftest.log"
plugin/scripts/okf-check --selftest > "$log" 2>&1; rc=$?
printf '%-42s rc=%s\n' "okf-check --selftest" "$rc"
[ "$rc" -eq 0 ] || { fail=1; tail -20 "$log"; }
exit "$fail"
