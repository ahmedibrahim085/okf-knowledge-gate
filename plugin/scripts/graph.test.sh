#!/usr/bin/env bash
# Tests for the optional okf-memory layer, "L2 graph" (.scratch okf-ecosystem; cases S27-GR-* in docs/0.9.x-cases.md).
#
# okf-memory (`okf validate --json`) reports orphan notes and broken concept links, which no other layer looks for. The
# layer is opt-in (okf_check.graph: true, or OKF_MEMORY_BIN), runs on the frozen copy under a time limit, and its findings
# are advisories. A stub stands in for the binary, so the suite runs where okf-memory is not installed; with
# OKF_TEST_MEMORY_BIN set to a real binary, S27-GR-L1 runs it too.
#
# Spec row GR-1. bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"
unset OKF_MEMORY_BIN

# The stub: `--help` names okf-memory, `version` prints one, `validate <dir> --json` prints the report in $STUB_REPORT (or,
# with STUB_MODE=hang, sleeps; garbage, prints text). Every call is logged to $TMP/stub.calls.
mkdir -p "$TMP/bin" "$TMP/other"
cat > "$TMP/bin/okf" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TMP/stub.calls"
case "\$1" in
  --help) echo "OKF Agent Memory CLI (v9.9.9)"; exit 0 ;;
  version) echo "okf version v9.9.9 (stub)"; exit 0 ;;
  validate)
    case "\${STUB_MODE:-}" in
      hang) sleep 30 ;; garbage) echo "not json"; exit 1 ;;
      errjson) echo '{"errors":["could not build graph"],"broken_links":null,"orphans":null}'; exit 3 ;;
      nokeys) echo '{"errors":[]}'; exit 0 ;;
      nulls) echo '{"broken_links":null,"orphans":null}'; exit 0 ;;
      onenull) echo '{"broken_links":[{"source_concept":"a.md","target_href":"gone.md"}],"orphans":null}'; exit 0 ;;
    esac
    if [ -f "\$2/bad.md" ] && grep -q 'missing.md' "\$2/bad.md"; then
      echo '{"broken_links":[{"source_concept":"bad.md","target_href":"missing.md","reason":"gone"}],"orphans":[]}'
    else
      if [ -n "\${STUB_REPORT:-}" ]; then cat "\$STUB_REPORT"; else echo '{"broken_links":[],"orphans":[]}'; fi
    fi
    exit 0 ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\necho "$*" >> "%s/other.calls"\necho "okf - some other knowledge tool"\n' "$TMP" > "$TMP/other/okf"
chmod +x "$TMP/bin/okf" "$TMP/other/okf"
printf '{"broken_links":[{"source_concept":"a.md","target_href":"gone.md","reason":"target concept does not exist"}],"orphans":["c"]}\n' > "$TMP/report1.json"

mkb() { mkbundle "$1"; sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"; [ -z "${2:-}" ] || printf '%s\n' "$2" >> "$1/okf-base.yaml"; }
run() { local b="$1"; shift; "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }
ON=$'okf_check:\n  graph: true'

section "happy"
# S27-GR-H1: opted in, okf-memory reports a broken link and an orphan: a WARN line that lists both; the exit code is the
# one the other layers give (advisory); --json l2_graph carries both lists.
B="$TMP/h1"; mkb "$B" "$ON"
rm -f "$TMP/stub.calls"
rc=$(PATH="$TMP/bin:$PATH" STUB_REPORT="$TMP/report1.json" run "$B")
base=$("$CHECK" "$TMP/h1" >/dev/null 2>&1; echo $?)
{ [ "$rc" = "$base" ] && grep -Eq 'L2 graph +WARN +1 broken concept link\(s\), 1 orphan\(s\) \(okf-memory; advisory\)' "$TMP/out.txt" \
  && grep -q 'broken link: a.md -> gone.md' "$TMP/out.txt" && grep -q 'orphan: c' "$TMP/out.txt"; } \
  && ok "S27-GR-H1 opted in: a WARN line with 1 broken link and 1 orphan, both listed; exit code unchanged ($rc)" \
  || bad "S27-GR-H1 findings" "rc=$rc base=$base $(grep -n -A3 'L2 graph' "$TMP/out.txt" | tr '\n' '|')"
PATH="$TMP/bin:$PATH" STUB_REPORT="$TMP/report1.json" "$CHECK" --json "$B" > "$TMP/out.json" 2>/dev/null
[ "$(jget 'd.get("l2_graph")')" = '{"broken_links": ["a.md -> gone.md"], "orphans": ["c"]}' ] \
  && ok "S27-GR-H1b --json l2_graph lists the broken link and the orphan" || bad "S27-GR-H1b json" "$(jget 'd.get("l2_graph")')"
# S27-GR-H2: a clean graph is a PASS line; the binary ran on the frozen copy (not the bundle folder itself).
rm -f "$TMP/stub.calls"
rc=$(PATH="$TMP/bin:$PATH" run "$B")
{ grep -Eq 'L2 graph +PASS +no orphan note, no broken concept link' "$TMP/out.txt" && grep -q '^validate .* --json$' "$TMP/stub.calls" \
  && ! grep -q "^validate $B " "$TMP/stub.calls"; } \
  && ok "S27-GR-H2 a clean report is PASS, and okf-memory read the frozen copy, not $B" || bad "S27-GR-H2 pass" "$(grep -n 'L2 graph' "$TMP/out.txt") calls: $(cat "$TMP/stub.calls" 2>/dev/null | tr '\n' '|')"
# S27-GR-H3: OKF_MEMORY_BIN alone opts in, for a bundle without the key.
B3="$TMP/h3"; mkb "$B3"
rc=$(OKF_MEMORY_BIN="$TMP/bin/okf" STUB_REPORT="$TMP/report1.json" run "$B3")
grep -Eq 'L2 graph +WARN' "$TMP/out.txt" && ok "S27-GR-H3 OKF_MEMORY_BIN opts in without okf_check.graph" || bad "S27-GR-H3 env opt-in" "$(grep -n 'L2 graph' "$TMP/out.txt")"

section "negative"
# S27-GR-N1: not opted in: no line, and an okf-memory on PATH is never run.
rm -f "$TMP/stub.calls"
rc=$(PATH="$TMP/bin:$PATH" run "$B3")
{ ! grep -q 'L2 graph' "$TMP/out.txt" && [ ! -s "$TMP/stub.calls" ]; } \
  && ok "S27-GR-N1 without okf_check.graph or OKF_MEMORY_BIN there is no L2 graph line and okf-memory is not run" || bad "S27-GR-N1 opt-in" "calls: $(cat "$TMP/stub.calls" 2>/dev/null | tr '\n' '|')"
# S27-GR-N2: opted in and not installed: SKIPPED says what is unchecked, never a pass; --json skipped names it.
rc=$(PATH="/usr/bin:/bin" run "$B")
"$CHECK" --json "$B" > "$TMP/out.json" 2>/dev/null
{ grep -Eq 'L2 graph +SKIPPED — okf-memory not found .*orphans and broken concept links are UNCHECKED' "$TMP/out.txt" \
  && jget 'd["skipped"]' | grep -q 'L2 graph: okf-memory not found'; } \
  && ok "S27-GR-N2 opted in without okf-memory: SKIPPED naming what is unchecked; --json skipped lists it" || bad "S27-GR-N2 skipped" "$(grep -n 'L2 graph' "$TMP/out.txt")"
# S27-GR-N3: another tool called `okf` on PATH is not okf-memory: SKIPPED, and its validate is never run.
rm -f "$TMP/other.calls"
rc=$(PATH="$TMP/other:$PATH" run "$B")
{ grep -Eq 'L2 graph +SKIPPED' "$TMP/out.txt" && ! grep -q '^validate' "$TMP/other.calls" 2>/dev/null; } \
  && ok "S27-GR-N3 a different 'okf' on PATH is not mistaken for okf-memory (SKIPPED, its validate not run)" || bad "S27-GR-N3 other okf" "$(grep -n 'L2 graph' "$TMP/out.txt") calls: $(cat "$TMP/other.calls" 2>/dev/null | tr '\n' '|')"
# S27-GR-N4: an unquoted `graph: yes` is a config error (B-7 rule), not a silent opt-in.
B4="$TMP/n4"; mkb "$B4" $'okf_check:\n  graph: yes'
rc=$(PATH="$TMP/bin:$PATH" run "$B4")
{ [ "$rc" = 2 ] && grep -q 'okf_check.graph must be true or false: write true or false, not yes' "$TMP/out.txt"; } \
  && ok "S27-GR-N4 graph: yes (unquoted) is a Config error, exit 2" || bad "S27-GR-N4 yes" "rc=$rc $(grep -n 'Config' "$TMP/out.txt")"

section "edge"
# S27-GR-E1: a hung okf-memory is stopped at OKF_GRAPH_TIMEOUT: COULD NOT RUN, not a pass, and the run goes on.
t0=$SECONDS
rc=$(PATH="$TMP/bin:$PATH" STUB_MODE=hang OKF_GRAPH_TIMEOUT=1 run "$B"); el=$((SECONDS - t0))
{ grep -Eq 'L2 graph +COULD NOT RUN — okf-memory timed out after 1 s \(OKF_GRAPH_TIMEOUT\); not a pass' "$TMP/out.txt" && [ "$el" -lt 25 ]; } \
  && ok "S27-GR-E1 a hung okf-memory is stopped after OKF_GRAPH_TIMEOUT=1: COULD NOT RUN, not a pass (${el} s)" || bad "S27-GR-E1 timeout" "el=$el $(grep -n 'L2 graph' "$TMP/out.txt")"
# S27-GR-E2: output that is not its JSON report is COULD NOT RUN, never read as a clean graph.
rc=$(PATH="$TMP/bin:$PATH" STUB_MODE=garbage run "$B")
grep -Eq 'L2 graph +COULD NOT RUN — okf-memory exited 1 without a readable report; not a pass' "$TMP/out.txt" \
  && ok "S27-GR-E2 unreadable output is COULD NOT RUN, not a pass" || bad "S27-GR-E2 garbage" "$(grep -n 'L2 graph' "$TMP/out.txt")"
# S27-GR-E3: --doctor names okf-memory when found and says it is optional when not; --selftest probes the layer when found.
d1=$(PATH="$TMP/bin:$PATH" "$CHECK" --doctor 2>&1 | grep 'okf-memory'); d2=$(PATH="/usr/bin:/bin:$(dirname "$REALPY")" "$CHECK" --doctor 2>&1 | grep 'okf-memory')
PATH="$TMP/bin:$PATH" "$CHECK" --selftest > "$TMP/st.txt" 2>&1; src=$?
{ printf '%s' "$d1" | grep -q 'v9.9.9 (stub)  (optional: L2 graph' && printf '%s' "$d2" | grep -q 'absent (optional' \
  && [ "$src" = 0 ] && grep -q 'FIRED      broken concept link' "$TMP/st.txt"; } \
  && ok "S27-GR-E3 --doctor reports okf-memory (found or optional), --selftest's L2 graph probe fires" \
  || bad "S27-GR-E3 doctor and selftest" "d1='$d1' d2='$d2' selftest rc=$src $(grep -n -A1 'graph' "$TMP/st.txt" | tr '\n' '|')"

# S27-GR-E4 (review 0.9.35): a JSON error report (exit 3, null lists) and a report without the two lists are COULD NOT RUN,
# never a clean graph; an OKF_MEMORY_BIN given as a bare name is found on PATH.
rc=$(PATH="$TMP/bin:$PATH" STUB_MODE=errjson run "$B"); e1=$(grep -c 'L2 graph *COULD NOT RUN' "$TMP/out.txt")
rc=$(PATH="$TMP/bin:$PATH" STUB_MODE=nokeys run "$B"); e2=$(grep -c 'L2 graph *COULD NOT RUN' "$TMP/out.txt")
rc=$(PATH="$TMP/bin:$PATH" OKF_MEMORY_BIN=okf run "$B3"); e3=$(grep -Ec 'L2 graph +(PASS|WARN)' "$TMP/out.txt")
{ [ "$e1" = 1 ] && [ "$e2" = 1 ] && [ "$e3" = 1 ]; } \
  && ok "S27-GR-E4 an error report or a report without its lists is COULD NOT RUN; OKF_MEMORY_BIN=okf is looked up on PATH" \
  || bad "S27-GR-E4 strict report" "errjson=$e1 nokeys=$e2 barename=$e3"

# S27-GR-E5 (review 0.9.35 round 2): okf-memory v0.6.2 writes null for an empty list: null lists are a clean graph, and
# one null list does not hide the other's findings.
rc=$(PATH="$TMP/bin:$PATH" STUB_MODE=nulls run "$B"); n1=$(grep -Ec 'L2 graph +PASS' "$TMP/out.txt")
rc=$(PATH="$TMP/bin:$PATH" STUB_MODE=onenull run "$B"); n2=$(grep -Ec 'L2 graph +WARN +1 broken concept link\(s\), 0 orphan\(s\)' "$TMP/out.txt")
{ [ "$n1" = 1 ] && [ "$n2" = 1 ]; } && ok "S27-GR-E5 null lists read as empty: PASS, and 1 broken link with null orphans is a WARN" \
  || bad "S27-GR-E5 null lists" "nulls-pass=$n1 onenull-warn=$n2"

section "live"
# S27-GR-L1: the real okf-memory, when OKF_TEST_MEMORY_BIN names it: a note linking a missing concept is reported.
if [ -n "${OKF_TEST_MEMORY_BIN:-}" ] && [ -x "$OKF_TEST_MEMORY_BIN" ]; then
  BL="$TMP/live"; mkb "$BL" "$ON"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee [x](missing.md).\n' > "$BL/bad.md"
  rc=$(OKF_MEMORY_BIN="$OKF_TEST_MEMORY_BIN" run "$BL")
  grep -q 'broken link: bad.md -> missing.md' "$TMP/out.txt" && ok "S27-GR-L1 the real okf-memory reports bad.md -> missing.md" \
    || bad "S27-GR-L1 live" "$(grep -n -A4 'L2 graph' "$TMP/out.txt" | tr '\n' '|')"
  # S27-GR-L2: a clean bundle (two notes linking each other, linked from the index) is PASS with the real binary (null lists).
  BC="$TMP/live-clean"; mkb "$BC" "$ON"; rm -f "$BC/c.md"
  for n in x y; do o=$([ "$n" = x ] && echo y || echo x)
    printf -- '---\ntype: Lesson\ntitle: T%s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nSee [%s](%s.md).\n' "$n" "$o" "$o" > "$BC/$n.md"; done
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n* [x](x.md)\n* [y](y.md)\n' > "$BC/index.md"
  rc=$(OKF_MEMORY_BIN="$OKF_TEST_MEMORY_BIN" run "$BC")
  grep -Eq 'L2 graph +PASS' "$TMP/out.txt" && ok "S27-GR-L2 the real okf-memory on a clean bundle: PASS" \
    || bad "S27-GR-L2 live clean" "$(grep -n -A3 'L2 graph' "$TMP/out.txt" | tr '\n' '|')"
else
  skip "S27-GR-L1 the real okf-memory was not run (OKF_TEST_MEMORY_BIN is not set)" "OKF_TEST_MEMORY_BIN=/path/to/okf bash plugin/scripts/graph.test.sh"
fi

# S36-ON-GR: a name in okf-memory's report that holds a control character (an ESC, as \u001b in its JSON) or a byte that is not
# UTF-8 reaches neither the terminal nor --json raw: both spell it \x1b and \xff, as every other layer does (the report was read
# with errors="replace", so the byte was U+FFFD, and the ESC went to the terminal and into l2_graph as it was). The stub's report
# stands in for okf-memory, so this runs on every disk.
B="$TMP/on-gr"; mkb "$B" "$ON"
printf '{"broken_links":[{"source_concept":"e\\u001bx.md","target_href":"gone.md"}],"orphans":["n\377u"]}\n' > "$TMP/on-gr.json"
rc=$(PATH="$TMP/bin:$PATH" STUB_REPORT="$TMP/on-gr.json" run "$B")
rawesc=$(LC_ALL=C grep -a -c "$(printf '\033')" "$TMP/out.txt"); rawff=$(LC_ALL=C grep -a -c "$(printf '\377')" "$TMP/out.txt")
PATH="$TMP/bin:$PATH" STUB_REPORT="$TMP/on-gr.json" "$CHECK" --json "$B" > "$TMP/out.json" 2>/dev/null
rawjson=$(LC_ALL=C grep -a -c 'u001b\|ufffd\|udc' "$TMP/out.json")
{ [ "$rawesc" = 0 ] && [ "$rawff" = 0 ] && [ "$rawjson" = 0 ] && grep -aqF 'broken link: e\x1bx.md -> gone.md' "$TMP/out.txt" && grep -aqF 'orphan: n\xffu' "$TMP/out.txt" \
  && [ "$(jget 'd.get("l2_graph")')" = '{"broken_links": ["e\\x1bx.md -> gone.md"], "orphans": ["n\\xffu"]}' ]; } \
  && ok "S36-ON-GR an ESC and a non-UTF-8 byte in okf-memory's names are \\x1b and \\xff in the text and in l2_graph, never raw" \
  || bad "S36-ON-GR names in the graph report" "raw ESC=$rawesc raw 0xff=$rawff raw in json=$rawjson l2_graph=$(jget 'd.get("l2_graph")')"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
