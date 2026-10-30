#!/usr/bin/env bash
# Tests for plugin/tests/okf-test-lib.sh, the helpers the okf-check suites share (cases S11-TS-*).
#
# The timing mode is the part with behaviour: OKF_TEST_TIMING=1 prints one line per section
# (seconds and assert count) so a split of the big suite is decided by measurement, not by line counts.
# bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
LIB="$HERE/../tests/okf-test-lib.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okftestlib)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

echo "okf-test-lib tests"

# A throwaway suite with two sections: 2 asserts, then 1 pass + 1 fail + 1 skip, then a section with none.
cat > "$TMP/mini.test.sh" <<'MINI'
#!/usr/bin/env bash
set -uo pipefail
. "$OKF_LIB"
section "first"
sleep 1
ok "a"; ok "b"
section "second"
ok "c"; bad "d" "why"; skip "e"
section "third"
okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
MINI

OKF_LIB="$LIB" OKF_TEST_TIMING=1 bash "$TMP/mini.test.sh" > "$TMP/on.txt" 2>&1; rc_on=$?
OKF_LIB="$LIB" bash "$TMP/mini.test.sh" > "$TMP/off.txt" 2>&1; rc_off=$?

# S11-TS-H1: one line per section, in order, with seconds and the assert count.
if grep -Eq '^TIMING +[1-9][0-9]*\.[0-9]+s +2 asserts +first$' "$TMP/on.txt" \
   && grep -Eq '^TIMING +[0-9]+\.[0-9]+s +3 asserts +second$' "$TMP/on.txt" \
   && grep -Eq '^TIMING +[0-9]+\.[0-9]+s +0 asserts +third$' "$TMP/on.txt" \
   && [ "$(grep -c '^TIMING' "$TMP/on.txt")" -eq 3 ]; then
  ok "TS-1 OKF_TEST_TIMING=1 prints one seconds-and-count line per section (S11-TS-H1)"
else
  bad "TS-1 timing lines" "$(grep -c '^TIMING' "$TMP/on.txt" 2>/dev/null) TIMING lines; output: $(head -12 "$TMP/on.txt" | tr '\n' '|')"
fi

# TS-4: the seconds have a fraction. Two sections of 0.3 s and 0.4 s used to print "0s" and "1s" (whole seconds from
# $SECONDS), so a section could not be told from one twice as long. Each value must be a decimal number of seconds, within
# a wide band around the sleep (a loaded machine runs long, never short), and the two must not both read as whole seconds.
cat > "$TMP/fine.test.sh" <<'FINE'
#!/usr/bin/env bash
set -uo pipefail
. "$OKF_LIB"
section "short"
sleep 0.3
ok "a"
section "longer"
sleep 0.4
ok "b"
okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
FINE
OKF_LIB="$LIB" OKF_TEST_TIMING=1 bash "$TMP/fine.test.sh" > "$TMP/fine.txt" 2>&1
t_short=$(sed -n 's/^TIMING  *\([0-9][0-9]*\.[0-9][0-9]*\)s .* short$/\1/p' "$TMP/fine.txt")
t_long=$(sed -n 's/^TIMING  *\([0-9][0-9]*\.[0-9][0-9]*\)s .* longer$/\1/p' "$TMP/fine.txt")
if [ -n "$t_short" ] && [ -n "$t_long" ] && awk -v a="$t_short" -v b="$t_long" 'BEGIN { exit !(a >= 0.25 && a < 3 && b >= 0.35 && b < 3) }'; then
  ok "TS-4 a 0.3 s and a 0.4 s section print as $t_short s and $t_long s (a decimal number of seconds)"
else
  bad "TS-4 sections of a fraction of a second" "short='$t_short' longer='$t_long'; output: $(grep '^TIMING' "$TMP/fine.txt" | tr '\n' '|')"
fi

# S11-TS-N1: a plain run prints no timing line.
if grep -q '3 passed, 1 failed, 1 SKIPPED' "$TMP/off.txt" && ! grep -q 'TIMING' "$TMP/off.txt"; then
  ok "TS-2 a plain run prints no timing line (S11-TS-N1)"
else
  bad "TS-2 plain run" "output: $(head -12 "$TMP/off.txt" | tr '\n' '|')"
fi

# S11-TS-E1: timing changes neither the verdict nor the summary; the failing assert still fails the run.
if [ "$rc_on" -eq 1 ] && [ "$rc_off" -eq 1 ] && grep -q '3 passed, 1 failed, 1 SKIPPED' "$TMP/on.txt" \
   && [ "$(grep -v '^TIMING' "$TMP/on.txt")" = "$(cat "$TMP/off.txt")" ]; then
  ok "TS-3 timing mode leaves the output, the summary and the exit code unchanged (S11-TS-E1)"
else
  bad "TS-3 timing is inert" "rc_on=$rc_on rc_off=$rc_off"
fi

# S11-TS-E2: a header with no section call right under it would drop its seconds from the report.
miss=""
for f in "$HERE"/okf-check*.test.sh; do
  [ -f "$f" ] || continue
  m=$(awk 'prev && !/^section "/ { print FILENAME ":" NR - 1 } { prev = /^# (---|===) / }' "$f")
  [ -z "$m" ] || miss="$miss $m"
done
if [ -z "$miss" ]; then
  ok "TS-4 every section header in the okf-check suites has a section call under it (S11-TS-E2)"
else
  bad "TS-4 section call missing" "headers without a section call:$miss"
fi

# TS-5 (S18-H4): the summary is the last line a suite prints, also when a skip lists how to run the skipped coverage.
# The gate runners take only a last line of the form "N passed, M failed" as the summary.
printf '#!/usr/bin/env bash\n. "$OKF_LIB"\nok a\nskip b "install the thing"\nokf_test_summary\n[ "$FAIL" -eq 0 ] || exit 1\n' > "$TMP/rem.test.sh"
OKF_LIB="$LIB" bash "$TMP/rem.test.sh" > "$TMP/rem.txt" 2>&1
last=$(awk 'NF { l = $0 } END { print l }' "$TMP/rem.txt")
if grep -Eq '^ *1 passed, 0 failed, 1 SKIPPED' <<<"$last" && grep -q 'install the thing' "$TMP/rem.txt"; then
  ok "TS-5 the summary is the last line, after the skipped-coverage remedies"
else
  bad "TS-5 summary last" "last line: $last"
fi

echo; echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
