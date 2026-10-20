#!/usr/bin/env bash
# Tests for okf-check's L3 staleness layer. Run: plugin/scripts/okf-check-l3.test.sh
#
# Split out of okf-check.test.sh: measured at 21 to 25 percent of that suite's run, the largest
# section, and independent of the rest (own TMP, own helpers), so the two files run side by side.
# Every test keeps its ID and text. Shared helpers live in plugin/tests/okf-test-lib.sh.
#
# bash 3.2 compatible (macOS ships 3.2 — no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"

echo "okf-check L3 staleness tests"

# --- L3 staleness -----------------------------------------------------------
section "L3 staleness"
STALE="$TMP/stale"; mkbundle "$STALE"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nbody\n' > "$STALE/old.md"
expect_match "old.md (stale_after" "L3 names the expired concept" "$CHECK" "$STALE"
expect_exit 0 "N-8 staleness is advisory by default" -- "$CHECK" "$STALE"
expect_exit 4 "N-9 --fail-stale makes staleness blocking" -- "$CHECK" "$STALE" --fail-stale

# LT-01 (.scratch/okf-local-bugs/01): README.md is a concept (I-4, L1) — L3 skipped it,
# so an expired README was never reported. index.md and log.md stay reserved.
T01="$TMP/t01"; mkbundle "$T01"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nbody\n' > "$T01/README.md"
expect_match "README.md (stale_after" "LT-01 L3 flags an expired README.md" "$CHECK" "$T01"

# LT-02 (.scratch/okf-local-bugs/02): a CRLF note was invisible to L3 (awk saw "---\r").
T02="$TMP/t02"; mkbundle "$T02"
printf -- '---\r\ntype: Lesson\r\ntitle: T\r\ndescription: D\r\nstatus: stable\r\nstale_after: "2000-01-01"\r\n---\r\nbody\r\n' > "$T02/crlf.md"
expect_match "crlf.md (stale_after" "LT-02 L3 flags an expired CRLF note" "$CHECK" "$T02"
# LT-42 (found by the 0.9.1 final review): L1 accepts fences with trailing spaces ("--- "); L3 compared them with
# == "---" and saw no frontmatter, so an expired note passed. And l3_line kept reading after the closing fence, so a
# "---" block in the BODY was read as frontmatter (a false FAIL, and an expired note listed twice).
T42="$TMP/t42"; mkbundle "$T42"
printf -- '--- \ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n--- \nbody\n' > "$T42/spaced.md"
expect_match "spaced.md (stale_after" "LT-42a L3 flags an expired note whose fences carry trailing spaces" "$CHECK" "$T42"
expect_exit 4 "LT-42b ... and --fail-stale makes it blocking" -- "$CHECK" "$T42" --fail-stale
T42B="$TMP/t42b"; mkbundle "$T42B"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2099-01-01"\n---\nbody\n---\nstale_after: "2000-01-01"\n---\nmore\n' > "$T42B/bodyblock.md"
expect_exit 0 "LT-42c a '---' block in the note BODY is not read as frontmatter (no false stale)" -- "$CHECK" "$T42B" --fail-stale
T42C="$TMP/t42c"; mkbundle "$T42C"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nbody\n---\nmore\n---\n' > "$T42C/twice.md"
n42=$("$CHECK" "$T42C" 2>&1 | grep -c 'twice.md (stale_after')
[ "$n42" = 1 ] && ok "LT-42d an expired note with body '---' lines is listed once" || bad "LT-42d listed once" "listed $n42 times"
# LT-03 (.scratch/okf-local-bugs/03): value parsing in L3.
T03="$TMP/t03"; mkbundle "$T03"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable  # ok\n---\nbody\n' > "$T03/cmt.md"
expect_no_match "cmt.md (stable" "LT-03a a trailing comment is not part of the status value" "$CHECK" "$T03"
T03B="$TMP/t03b"; mkbundle "$T03B"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2026-9-3"\n---\nbody\n' > "$T03B/unpadded.md"
expect_match "unpadded.md (stale_after" "LT-03b a non-padded past date is flagged, not silently passed" env OKF_TODAY=2026-10-14 "$CHECK" "$T03B"
# Review round 1 (spec axis): comment stripping must respect quotes, cover stale_after, and
# a non-date stale_after must be reported, not passed.
T03C="$TMP/t03c"; mkbundle "$T03C"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: "stable # x"\n---\nbody\n' > "$T03C/q.md"
expect_match "status   .*q.md" "LT-03c a quoted value that holds ' #' is not truncated at the hash" "$CHECK" "$T03C"
T03D="$TMP/t03d"; mkbundle "$T03D"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: soon\n---\nbody\n' > "$T03D/soon.md"
expect_match "malformed.*soon.md" "LT-03d a non-date stale_after is reported as malformed" "$CHECK" "$T03D"
T03E="$TMP/t03e"; mkbundle "$T03E"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: 2000-01-01  # review\n---\nbody\n' > "$T03E/c.md"
expect_match "c.md (stale_after 2000-01-01)" "LT-03e a trailing comment on stale_after is stripped" "$CHECK" "$T03E"
T03J="$TMP/t03j"; mkbundle "$T03J"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: 2026-9-3T00:00:00Z\n---\nbody\n' > "$T03J/inst.md"
expect_match "inst.md (stale_after 2026-09-03T00:00:00Z)" "LT-03j an unpadded date with a time part is normalised and flagged" env OKF_TODAY=2026-10-14 "$CHECK" "$T03J"
# LT-04 (review round 2): a gate that cannot load its helper must not PASS.
T04="$TMP/t04plug"; cp -R "$HERE/.." "$T04"; rm -f "$T04/scripts/l3-lib.sh"
expect_exit 2 "LT-04a a missing l3-lib.sh is a dependency failure, never a silent L3 PASS" -- "$T04/scripts/okf-check" "$STALE" --fail-stale
expect_exit 2 "LT-04b an OKF_TODAY that is not a date is rejected, not applied" -- env OKF_TODAY=zzz "$CHECK" "$STALE" --fail-stale
# LT-05 (ticket 07): a crashed L3 awk must not read as "nothing expired".
T05="$TMP/t05stub"; mkdir -p "$T05"
printf '#!/bin/sh\ncase "$*" in *okfval*) exit 2 ;; esac\nexec /usr/bin/awk "$@"\n' > "$T05/awk"; chmod +x "$T05/awk"
expect_exit 2 "LT-05 a crashing L3 awk is a dependency failure, never a PASS" -- env PATH="$T05:$PATH" "$CHECK" "$STALE" --fail-stale
# LT-09 (ticket 11): one note the validator crashes on must be NAMED, must not hide the verdict
# on the other notes, and must never read as a pass. The vendored validator no longer crashes on
# the known inputs (okf-skills#62-#66, fixed in the vendored copy), so a STUB crashes on purpose:
# the isolation logic is proven independent of any upstream bug.
T09P="$TMP/t09plug"; cp -R "$HERE/.." "$T09P"
mv "$T09P/vendor/okf_validate.py" "$T09P/vendor/real_validator.py"
cat > "$T09P/vendor/okf_validate.py" <<'PYSTUB'
# l3-lib.sh reads the spec status list from the validator, so a stub carries it
STATUS_VALUES = {"draft", "stable", "deprecated"}
import runpy, sys, pathlib
args = sys.argv[1:]
root = pathlib.Path(args[0])
for f in root.rglob("*.md"):
    if "CRASHME" in f.read_text(errors="replace"):
        raise RuntimeError("stub validator crash on " + f.name)
sys.argv = [str(pathlib.Path(__file__).with_name("real_validator.py"))] + args
runpy.run_path(sys.argv[0], run_name="__main__")
PYSTUB
T09="$TMP/t09"; mkbundle "$T09"
printf -- '---\ntype: Lesson\ntitle: Good\ndescription: D\nstatus: stable\nstale_after: "2099-01-01"\n---\nbody\n' > "$T09/good.md"
printf -- '---\ntype: Lesson\ntitle: A\ndescription: D\n---\nCRASHME\n' > "$T09/bad-a.md"
printf -- '---\ntype: Lesson\ntitle: B\ndescription: D\n---\nCRASHME\n' > "$T09/bad-b.md"
S09="$T09P/scripts/okf-check"
expect_exit 2 "LT-09a a validator crash is exit 2 (could not run), not a pass" -- "$S09" "$T09"
expect_match "bad-a.md: RuntimeError" "LT-09b the first crashing note is named with the reason" "$S09" "$T09"
expect_match "bad-b.md: RuntimeError" "LT-09c the second crashing note is named with the reason" "$S09" "$T09"
expect_match "L1 conformance   PASS   [1-9][0-9]* concepts, 0 errors" "LT-09d the remaining notes are still validated and counted" "$S09" "$T09"
T09B="$TMP/t09b"; cp -R "$T09" "$T09B"; printf 'no frontmatter at all\n' > "$T09B/nofm.md"
expect_exit 1 "LT-09e a real conformance error elsewhere outranks the crash (exit 1)" -- "$S09" "$T09B"
# LT-18: the doc-reuse guard's personal locations live in a config file.
if [ -f "$HERE/doc-reuse-guard.sh" ] && command -v jq >/dev/null 2>&1; then
  G18="$HERE/doc-reuse-guard.sh"; T18="$TMP/t18"; mkdir -p "$T18/proj/docs" "$T18/vault/Notes/sub" "$T18/cfg"
  guard18() {  # guard18 <file_path> [env...]  -> stdout
    local fp="$1"; shift
    printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$fp" | env "$@" bash "$G18" 2>/dev/null
  }
  out=$(guard18 "$T18/proj/docs/new-note.md" OKF_DOC_DIRS_FILE="$T18/cfg/none")
  printf '%s' "$out" | grep -q "Doc-reuse check" && ok "LT-18a a new .md under a default location (docs/) still triggers the reminder" \
    || bad "LT-18a default location" "out=$(printf '%s' "$out" | head -c 120)"
  out=$(guard18 "$T18/vault/Notes/sub/new-note.md" OKF_DOC_DIRS_FILE="$T18/cfg/none")
  [ -z "$out" ] && ok "LT-18b a personal location is not built in: with no config file it does not trigger" \
    || bad "LT-18b personal location" "out=$(printf '%s' "$out" | head -c 120)"
  printf '# extra durable-doc locations, one shell glob per line\n\n*/Notes/*\n' > "$T18/cfg/dirs"
  out=$(guard18 "$T18/vault/Notes/sub/new-note.md" OKF_DOC_DIRS_FILE="$T18/cfg/dirs")
  printf '%s' "$out" | grep -q "Doc-reuse check" && ok "LT-18c a glob listed in the config file triggers the reminder" \
    || bad "LT-18c config glob" "out=$(printf '%s' "$out" | head -c 120)"
  printf '*/[unclosed\n' > "$T18/cfg/bad"; chmod 000 "$T18/cfg/bad" 2>/dev/null
  guard18 "$T18/vault/x/new.md" OKF_DOC_DIRS_FILE="$T18/cfg/bad" >/dev/null; rc1=$?
  chmod 600 "$T18/cfg/bad"; printf '*/[unclosed\n' > "$T18/cfg/bad"
  guard18 "$T18/vault/x/new.md" OKF_DOC_DIRS_FILE="$T18/cfg/bad" >/dev/null; rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && ok "LT-18d an unreadable or malformed config file never blocks a write (fail-open, exit 0)" \
    || bad "LT-18d fail-open" "rc1=$rc1 rc2=$rc2"
  PRIV18="tol""aria|claude-settings-""backups"
  ! grep -qiE "$PRIV18" "$G18" && ok "LT-18e no personal path or vault name is left in the guard source" \
    || bad "LT-18e private names in the guard" "$(grep -niE "$PRIV18" "$G18" | head -3 | cut -c1-100)"
else
  skip "LT-18 doc-reuse guard config — guard or jq absent" "install jq"
fi

# LT-19: the guard names the closest existing notes when a search binary exists.
if [ -f "$HERE/doc-reuse-guard.sh" ] && command -v jq >/dev/null 2>&1; then
  G19="$HERE/doc-reuse-guard.sh"; T19="$TMP/t19"; mkdir -p "$T19/docs" "$T19/real/docs" "$T19/bin"
  mkdir -p "$T19/lnk"; ln -s "$T19/real/docs" "$T19/lnk/docs"
  cat > "$T19/bin/okf" <<'STUB'
#!/bin/sh
[ -n "$STUB_LOG" ] && echo "$@" >> "$STUB_LOG"
[ -n "$STUB_SLEEP" ] && sleep "$STUB_SLEEP"
[ "$STUB_FAIL" = 1 ] && { echo "garbage <<<" ; exit 3; }
echo "Found 3 matching concept(s):"
echo " 1. [context]    [88.19] alpha-note (Lesson)"
echo "    first description"
echo " 2. [context]    [50.00] beta-note (Lesson)"
echo " 3. [context]    [10.00] gamma-note (Lesson)"
echo " 4. [context]    [ 5.00] delta-note (Lesson)"
STUB
  chmod +x "$T19/bin/okf"
  g19() { local fp="$1"; shift; printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$fp" | env OKF_DOC_DIRS_FILE="$T19/none" "$@" bash "$G19" 2>/dev/null; }
  out=$(g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf")
  { printf '%s' "$out" | grep -q "Closest existing notes" && printf '%s' "$out" | grep -q "alpha-note, beta-note, gamma-note" && ! printf '%s' "$out" | grep -q "delta-note"; } \
    && ok "LT-19a the reminder names the three closest notes (and only three)" || bad "LT-19a closest notes" "out=$(printf '%s' "$out" | head -c 200)"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "LT-19a2 the reminder stays valid hook JSON" || bad "LT-19a2 JSON" "invalid"
  out0=$(g19 "$T19/docs/new-note-name.md" PATH="/usr/bin:/bin" OKF_SEARCH_BIN="")
  { printf '%s' "$out0" | grep -q "Doc-reuse check" && ! printf '%s' "$out0" | grep -q "Closest"; } \
    && ok "LT-19b no search binary: the reminder is exactly today's text" || bad "LT-19b no binary" "out=$(printf '%s' "$out0" | head -c 160)"
  t0=$(date +%s); out=$(g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf" STUB_SLEEP=15); t1=$(date +%s)
  # The stub hangs for 15 s. The bound is "well under the hang", not a fixed 3 s: at load 24 an honest cut-off took 5 s
  # and a fixed limit failed a correct guard (final review, CI-owner POV). A guard that does not cut off takes >= 15 s.
  { [ $((t1-t0)) -lt 12 ] && printf '%s' "$out" | grep -q "Doc-reuse check" && ! printf '%s' "$out" | grep -q "Closest"; } \
    && ok "LT-19c a hung search binary is cut off (returned in $((t1-t0))s, well under its 15 s hang) and the reminder is today's text" || bad "LT-19c timeout" "took $((t1-t0))s out=$(printf '%s' "$out" | head -c 120)"
  out=$(g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf" STUB_FAIL=1); rc=$?
  { printf '%s' "$out" | grep -q "Doc-reuse check" && ! printf '%s' "$out" | grep -q "Closest" && [ "$rc" -eq 0 ]; } \
    && ok "LT-19d a failing search binary leaves today's reminder (exit 0)" || bad "LT-19d failing binary" "rc=$rc out=$(printf '%s' "$out" | head -c 120)"
  : > "$T19/argv.log"
  g19 "$T19/lnk/docs/other-note.md" OKF_SEARCH_BIN="$T19/bin/okf" STUB_LOG="$T19/argv.log" >/dev/null
  phys=$(cd -P "$T19/real/docs" && pwd)
  grep -q "$phys\$" "$T19/argv.log" && ok "LT-19e a symlinked directory is resolved to its real path before the search" \
    || bad "LT-19e symlink resolved" "argv=$(cat "$T19/argv.log")"
  grep -q "other note" "$T19/argv.log" && ok "LT-19f the query is the words of the new file's name" || bad "LT-19f query words" "argv=$(cat "$T19/argv.log")"
  # LT-19g: output captured from the real okf v0.6.1 binary, 4 hits, 1-2 digit scores.
  cat > "$T19/bin/okf-real" <<'REAL'
#!/bin/sh
cat <<'OUT'
Found 4 matching concept(s):

 1. [context]    [1.84] alpha-note (Lesson)
    about alpha topics
    Matches: title, description, id, body

 2. [context]    [1.84] alpha-note-two (Lesson)
    about alpha topics
    Matches: title, description, id, body

 3. [context]    [1.21] alpha-three (Lesson)
    about alpha topics
    Matches: title, description, id, body

 4. [context]    [0.58] beta-other (Lesson)
    about alpha topics
    Matches: description, body

OUT
REAL
  chmod +x "$T19/bin/okf-real"
  cat > "$T19/bin/okf-real2" <<'REAL'
#!/bin/sh
cat <<'OUT'
Found 3 matching concept(s):

 1. [context]    [10.56] alpha-note (Lesson)
    alpha note about alpha note
    Matches: title, tags, description, id, body

 2. [context]    [4.60] alpha-two (Lesson)
    alpha topics
    Matches: title, description, id, body

 3. [context]    [0.13] other-three (Lesson)
    other
    Matches: body

OUT
REAL
  chmod +x "$T19/bin/okf-real2"
  out=$(g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf-real2")
  printf '%s' "$out" | grep -q "alpha-note, alpha-two, other-three" \
    && ok "LT-19g2 real okf output with a two-digit score [10.56] parses" || bad "LT-19g2 two-digit score" "out=$(printf '%s' "$out" | head -c 240)"
  out=$(g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf-real")
  printf '%s' "$out" | grep -q "alpha-note, alpha-note-two, alpha-three" \
    && ok "LT-19g real okf output (captured) parses to the three closest ids" || bad "LT-19g real output" "out=$(printf '%s' "$out" | head -c 240)"
  # LT-19h: a hung binary's child process is not left behind.
  cat > "$T19/bin/okf-fork" <<'FORK'
#!/bin/sh
sleep 37 &
wait
FORK
  chmod +x "$T19/bin/okf-fork"
  g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf-fork" >/dev/null
  sleep 1
  cat > "$T19/bin/okf-grand" <<'GRAND'
#!/bin/sh
sh -c 'sleep 38; :' &
wait
GRAND
  chmod +x "$T19/bin/okf-grand"
  g19 "$T19/docs/new-note-name.md" OKF_SEARCH_BIN="$T19/bin/okf-grand" >/dev/null
  sleep 1
  _gleft=$(pgrep -f 'sleep 38' | wc -l | tr -d ' '); pkill -f 'sleep 38' 2>/dev/null
  [ "$_gleft" = "0" ] && ok "LT-19i no orphan GRANDCHILD is left either" || bad "LT-19i grandchild" "$_gleft process(es) left"
  _left=$(pgrep -f 'sleep 37' | wc -l | tr -d ' ')
  pkill -f 'sleep 37' 2>/dev/null
  [ "$_left" = "0" ] && ok "LT-19h no orphan child is left after a hung search binary is killed" || bad "LT-19h orphan" "$_left process(es) left"
else
  skip "LT-19 guard closest notes — guard or jq absent" "install jq"
fi

# LT-20: .okfignore is read by every layer, written only by --init-ignore.
T20="$TMP/t20"; mkbundle "$T20/b"
mkdir -p "$T20/b/.trash" "$T20/b/archive" "$T20/b/live"
printf -- 'no frontmatter at all\n' > "$T20/b/.trash/old.md"
f=$(ls "$T20/b"/*.md | grep -v 'index.md\|log.md' | head -1)
[ -n "$f" ] && sed 's/2099-01-01/2000-01-01/' "$f" > "$T20/b/archive/old.md"
"$CHECK" "$T20/b" --fail-stale >"$TMP/o20a.txt" 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "LT-20a baseline: an ignorable .trash note fails the gate without .okfignore (exit $rc)" \
  || bad "LT-20a baseline" "expected non-zero, got 0"
printf '.trash/\narchive/\n' > "$T20/b/.okfignore"
"$CHECK" "$T20/b" --fail-stale >"$TMP/o20b.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q 'trash\|archive/old' "$TMP/o20b.txt"; } \
  && ok "LT-20b ignored paths are absent from every layer (exit 0, no mention)" \
  || bad "LT-20b ignored paths" "rc=$rc $(grep -n 'trash\|archive\|FAIL' "$TMP/o20b.txt" | head -4 | tr '\n' ' ')"
grep -q 'okfmirror\|/l1mirror' "$TMP/o20b.txt" && bad "LT-20b2 no temp path leaks into the report" "$(grep -n okfmirror "$TMP/o20b.txt" | head -2)" \
  || ok "LT-20b2 no temp path leaks into the report"
grep -qi 'okfignore.*2 file' "$TMP/o20b.txt" && ok "LT-20c the run states how many files .okfignore excluded" \
  || bad "LT-20c excluded count" "$(grep -n -i ignore "$TMP/o20b.txt" | head -3)"
"$CHECK" "$T20/b" --json 2>/dev/null | grep -q '"ignored":2' && ok "LT-20c2 --json reports ignored:2" || bad "LT-20c2 json ignored" "missing"
printf '*\n' > "$T20/b/.okfignore"
"$CHECK" "$T20/b" >"$TMP/o20d.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && grep -qi 'excludes every' "$TMP/o20d.txt"; } \
  && ok "LT-20d an ignore file that excludes every note is reported, exit 2" \
  || bad "LT-20d excludes all" "rc=$rc $(head -c 200 "$TMP/o20d.txt")"
rm -f "$T20/b/.okfignore"
before=$(cd "$T20/b" && find . -type f | sort | tr '\n' ' ')
"$CHECK" "$T20/b" >/dev/null 2>&1
after=$(cd "$T20/b" && find . -type f | sort | tr '\n' ' ')
{ [ "$before" = "$after" ] && [ ! -e "$T20/b/.okfignore" ]; } && ok "LT-20e a full run never creates .okfignore" || bad "LT-20e no auto-create" "tree changed"
"$CHECK" --init-ignore "$T20/b" >/dev/null 2>&1; rc1=$?
printf '# mine\n' > "$T20/b/.okfignore"; h=$(cksum < "$T20/b/.okfignore")
"$CHECK" --init-ignore "$T20/b" >/dev/null 2>&1; rc2=$?
{ [ "$rc1" -eq 0 ] && [ "$rc2" -ne 0 ] && [ "$h" = "$(cksum < "$T20/b/.okfignore")" ]; } \
  && ok "LT-20f --init-ignore writes once and refuses to overwrite (rc $rc1 then $rc2)" \
  || bad "LT-20f init-ignore" "rc1=$rc1 rc2=$rc2"
# matcher: anchored vs name patterns, dir-only, comments, CRLF, negation skipped
mkdir -p "$T20/m/a/b" "$T20/m/docs" "$T20/m/x/docs"
for n in a/b/n.md a/keep.md docs/g.md x/docs/g.md top.tmp.md keep.md; do printf '# n\n' > "$T20/m/$n"; done
printf '# c\r\n/docs/\r\n*.tmp.md\n!keep.md\na/b/\n' > "$T20/m/.okfignore"
got=$(bash "$HERE/ignore-lib.sh" --list "$T20/m" 2>/dev/null | tr '\0' '\n' | sort | tr '\n' ' ')
want="a/keep.md keep.md x/docs/g.md "
[ "$got" = "$want" ] && ok "LT-20g matcher: anchored dir, name glob, nested dir, comment, CRLF, negation skipped" \
  || bad "LT-20g matcher" "got=[$got] want=[$want]"

# LT-20 review fixes (round 1): fail closed, same file set as without .okfignore.
R20="$TMP/r20"; mkbundle "$R20/b"; mkdir -p "$R20/outside" "$R20/b/dec"
printf -- 'no frontmatter\n' > "$R20/outside/escaped.md"; ln -s "$R20/outside" "$R20/b/linked"
"$CHECK" "$R20/b" >"$TMP/r20a.txt" 2>&1; rc0=$?
printf '# c\n' > "$R20/b/.okfignore"
"$CHECK" "$R20/b" >"$TMP/r20b.txt" 2>&1; rc1=$?
[ "$rc0" = "$rc1" ] && ok "LT-20h a no-op .okfignore gives the same verdict as none, with a symlinked dir (exit $rc1)" \
  || bad "LT-20h symlinked dir" "without=$rc0 with=$rc1"
rm -f "$R20/b/.okfignore"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nx\n' > "$R20/b/dec/n.md"
chmod 000 "$R20/b/dec/n.md"
printf '# c\n' > "$R20/b/.okfignore"
"$CHECK" "$R20/b" >"$TMP/r20c.txt" 2>&1; rc=$?
chmod 644 "$R20/b/dec/n.md"
{ [ "$rc" -ne 0 ] && ! grep -q 'ALL GATES PASS' "$TMP/r20c.txt"; } && ok "LT-20i an unreadable note is not silently dropped from the mirror (exit $rc)" \
  || bad "LT-20i unreadable note" "rc=$rc $(tail -3 "$TMP/r20c.txt" | tr '\n' ' ')"
rm -rf "$R20/b/dec" "$R20/b/linked"; printf '*/\n' > "$R20/b/.okfignore"; mkdir -p "$R20/b/sub"; printf -- 'x\n' > "$R20/b/sub/a.md"
for _f in "$R20/b"/*.md; do case "${_f##*/}" in index.md|log.md) ;; *) mv "$_f" "$R20/b/sub/moved.md";; esac; done
"$CHECK" "$R20/b" >"$TMP/r20d.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && ! grep -q 'ALL GATES PASS' "$TMP/r20d.txt"; } && ok "LT-20j excluding every concept (index.md and log.md remain) is reported, exit 2" \
  || bad "LT-20j only reserved files left" "rc=$rc $(tail -3 "$TMP/r20d.txt" | tr '\n' ' ')"
rm -f "$R20/b/.okfignore"; ln -s "$R20/elsewhere.txt" "$R20/b/.okfignore"
"$CHECK" --init-ignore "$R20/b" >/dev/null 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && [ ! -e "$R20/elsewhere.txt" ]; } && ok "LT-20k --init-ignore refuses to write through a symlink" || bad "LT-20k init through symlink" "rc=$rc"
rm -f "$R20/b/.okfignore"

# LT-17: preflight and opt-in installer for the supported prerequisites.
# A stub `uv` records every call; PATH is the stub dir plus system basics, so the machine's real
# okflint and uv are never touched.
T17="$TMP/t17"; mkdir -p "$T17/bin"
cat > "$T17/bin/uv" <<'STUB'
#!/bin/sh
echo "$*" >> "$UVLOG"
case "$1 $2" in
  "tool list")
    if [ -f "$UVLOG.installed" ]; then printf 'okflint v%s\n- okflint\n' "$(cat "$UVLOG.installed")"
    elif [ -n "$UV_HAS" ]; then printf 'okflint v%s\n- okflint\n' "$UV_HAS"; fi
    exit 0 ;;
  "tool dir") if [ "$3" = "--bin" ]; then echo "$UV_BINDIR"; else echo "$UV_TOOLDIR"; fi; exit 0 ;;
  "tool install")
    [ -n "$UV_SLEEP" ] && sleep "$UV_SLEEP"
    [ "$UV_FAIL" = 1 ] && { rm -rf "$UV_TOOLDIR/okflint"; echo "stub: install failed" >&2; exit "${UV_FAIL_RC:-1}"; }
    echo "0.5.0" > "$UVLOG.installed"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T17/bin/uv"
printf '#!/bin/sh\nexit 0\n' > "$T17/bin/okflint"; chmod +x "$T17/bin/okflint"
printf 'okflint 0.5.0\nokflint_source git+https://example.invalid/okflint@abc123\n' > "$T17/pins.txt"
t17() {  # t17 <extra env...> -- <okf-check args...>  (PATH keeps the stub uv and system basics only)
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  : > "$T17/uv.log"; rm -f "$T17/uv.log.installed"
  env PATH="$T17/bin:/usr/bin:/bin" OKF_PINNED_VERSIONS="$T17/pins.txt" UVLOG="$T17/uv.log" "${envs[@]+"${envs[@]}"}" "$CHECK" "$@" > "$T17/out.txt" 2>&1
  return $?
}
t17 UV_HAS=0.5.0 -- --preflight
[ ! -s "$T17/out.txt" ] && ok "LT-17a preflight is silent when okflint is present at the supported version" \
  || bad "LT-17a preflight silent" "$(head -3 "$T17/out.txt" | tr '\n' ' ')"
mv "$T17/bin/okflint" "$T17/bin/okflint.off"
t17 UV_HAS= -- --preflight
grep -q "okflint" "$T17/out.txt" && grep -q -- "--install-deps" "$T17/out.txt" && ok "LT-17b preflight names a missing okflint and the one command to fix it" \
  || bad "LT-17b preflight names missing okflint" "$(head -3 "$T17/out.txt" | tr '\n' ' ')"
mv "$T17/bin/okflint.off" "$T17/bin/okflint"
t17 UV_HAS=0.3.1 -- --preflight
grep -q "0.3.1" "$T17/out.txt" && grep -q "0.5.0" "$T17/out.txt" && ok "LT-17c preflight names an unsupported version and the supported one" \
  || bad "LT-17c preflight unsupported version" "$(head -3 "$T17/out.txt" | tr '\n' ' ')"
t17 UV_HAS=0.3.1 -- --install-deps; rc=$?
{ grep -q "git+https://example.invalid/okflint@abc123" "$T17/out.txt" && grep -q "0.3.1 -> git+https" "$T17/out.txt" && grep -q "\[pinned source" "$T17/out.txt" && ! grep -q "tool install" "$T17/uv.log" && [ "$rc" -eq 0 ]; } \
  && ok "LT-17d --install-deps without --yes prints the plan and installs nothing (exit 0)" \
  || bad "LT-17d plan only" "rc=$rc out=$(head -4 "$T17/out.txt" | tr '\n' ' ') log=$(cat "$T17/uv.log" | tr '\n' ';')"
t17 UV_HAS=0.3.1 -- --install-deps --yes; rc=$?
{ grep -q "tool install --force git+https://example.invalid/okflint@abc123" "$T17/uv.log" && [ "$rc" -eq 0 ] && grep -q "okflint            0.5.0  (pinned 0.5.0)" "$T17/out.txt"; } \
  && ok "LT-17e --install-deps --yes installs the pinned source and the doctor then reports the supported version (exit 0)" \
  || bad "LT-17e install" "rc=$rc log=$(cat "$T17/uv.log" | tr '\n' ';')"
mkdir -p "$T17/tooldir/okflint" "$T17/bindir"; echo "previous-build" > "$T17/tooldir/okflint/marker"
t17 UV_HAS=0.3.1 UV_FAIL=1 UV_FAIL_RC=7 UV_TOOLDIR="$T17/tooldir" UV_BINDIR="$T17/bindir" -- --install-deps --yes; rc=$?
{ [ "$rc" -eq 2 ] && [ "$(cat "$T17/tooldir/okflint/marker" 2>/dev/null)" = "previous-build" ]; } \
  && ok "LT-17f a failed install exits 2 and puts back the EXACT previous okflint (fork build included)" \
  || bad "LT-17f failed install" "rc=$rc marker=$(cat "$T17/tooldir/okflint/marker" 2>&1) log=$(cat "$T17/uv.log" | tr '\n' ';')"
grep -q "exit 7" "$T17/out.txt" && ok "LT-17k a failed install reports the installer's real exit code" \
  || bad "LT-17k real exit code" "out=$(grep -i 'FAILED' "$T17/out.txt" | head -1)"
t17 UV_HAS=0.3.1 -- --install-deps --yes --latest; rc=$?
grep -qE "tool install --force okflint$" "$T17/uv.log" && ok "LT-17g --latest installs the newest release, not the pin" \
  || bad "LT-17g latest" "log=$(cat "$T17/uv.log" | tr '\n' ';')"
mv "$T17/bin/okflint" "$T17/bin/okflint.off"
t17 UV_HAS= -- --preflight
! grep -q "tool install" "$T17/uv.log" && ok "LT-17h preflight never installs by default" || bad "LT-17h no install by default" "log=$(cat "$T17/uv.log")"
t17 UV_HAS= OKF_AUTO_INSTALL=1 -- --preflight
grep -q "tool install --force git+https://example.invalid/okflint@abc123" "$T17/uv.log" && ok "LT-17i OKF_AUTO_INSTALL=1 lets the preflight install" \
  || bad "LT-17i auto install" "log=$(cat "$T17/uv.log" | tr '\n' ';')"
mv "$T17/bin/uv" "$T17/bin/uv.off"
t17 UV_HAS= -- --install-deps --yes; rc=$?
{ [ "$rc" -eq 2 ] && grep -qi "uv" "$T17/out.txt"; } && ok "LT-17j no uv: exit 2 naming uv, never a silent pass" \
  || bad "LT-17j no uv" "rc=$rc out=$(head -3 "$T17/out.txt" | tr '\n' ' ')"
mv "$T17/bin/uv.off" "$T17/bin/uv"
# LT-17q: the fix command printed by the preflight must be runnable as printed.
mv "$T17/bin/okflint" "$T17/bin/okflint.off" 2>/dev/null
t17 UV_HAS= -- --preflight; fixcmd=$(grep -o 'run: bash [^ ]*okf-check --install-deps' "$T17/out.txt" | head -1 | sed 's/^run: //')
[ -n "$fixcmd" ] && ok "LT-17q the preflight prints a fix command with the full path to okf-check" \
  || bad "LT-17q runnable fix command" "out=$(head -2 "$T17/out.txt" | tr '\n' ' ')"
mv "$T17/bin/okflint.off" "$T17/bin/okflint" 2>/dev/null
# LT-17r: same version number, wrong build: a pinned source means the PATCHED build is supported,
# so the preflight probes one BOM note and names a stock build.
cat > "$T17/bin/okflint" <<'STUB'
#!/bin/sh
[ "$1" = validate ] && { echo '[{"code":"F001","severity":"error","file":"probe-bom.md"}]'; exit 1; }
exit 0
STUB
chmod +x "$T17/bin/okflint"
t17 UV_HAS=0.5.0 -- --preflight
grep -qi "stock" "$T17/out.txt" && ok "LT-17r preflight names a stock okflint that has the supported version number" \
  || bad "LT-17r stock vs fork" "out=$(head -3 "$T17/out.txt" | tr '\n' ' ')"
printf '#!/bin/sh\n[ "$1" = validate ] && { echo "[]"; exit 0; }\nexit 0\n' > "$T17/bin/okflint"
t17 UV_HAS=0.5.0 -- --preflight
[ ! -s "$T17/out.txt" ] && ok "LT-17s preflight stays silent for a patched okflint at the supported version" \
  || bad "LT-17s patched silent" "out=$(head -3 "$T17/out.txt" | tr '\n' ' ')"
printf '#!/bin/sh\nexit 0\n' > "$T17/bin/okflint"
# LT-17t: the preflight never fails the session, even when an auto-install fails.
mv "$T17/bin/okflint" "$T17/bin/okflint.off"
t17 UV_HAS= OKF_AUTO_INSTALL=1 UV_FAIL=1 UV_TOOLDIR="$T17/tooldir" UV_BINDIR="$T17/bindir" -- --preflight; rc=$?
[ "$rc" -eq 0 ] && ok "LT-17t preflight exits 0 even when the auto-install fails" || bad "LT-17t preflight exit" "rc=$rc"
mv "$T17/bin/okflint.off" "$T17/bin/okflint"
# LT-17u: --latest says plainly that stock PyPI okflint lacks the okflint#11 fixes.
t17 UV_HAS=0.3.1 -- --install-deps --latest
grep -qi "okflint#11" "$T17/out.txt" && ok "LT-17u --latest warns that the PyPI release may lack the okflint#11 fixes" \
  || bad "LT-17u latest warning" "out=$(head -6 "$T17/out.txt" | tr '\n' ' ')"
# LT-17v: jq is reported in the plan (optional, and what is off without it).
grep -q "jq" "$T17/out.txt" && ok "LT-17v the plan reports jq (optional)" || bad "LT-17v jq line" "out=$(head -8 "$T17/out.txt" | tr '\n' ' ')"
# LT-17l: a pinned source that could be read as an option is refused, and nothing is installed.
printf 'okflint 0.5.0\nokflint_source --index-url=http://evil.invalid/simple\n' > "$T17/pins-evil.txt"
t17 UV_HAS=0.3.1 OKF_PINNED_VERSIONS="$T17/pins-evil.txt" -- --install-deps --yes; rc=$?
{ [ "$rc" -eq 2 ] && ! grep -q "tool install" "$T17/uv.log" && grep -qi "refus" "$T17/out.txt"; } \
  && ok "LT-17l an option-shaped pinned source is refused (exit 2, nothing installed)" \
  || bad "LT-17l option injection" "rc=$rc log=$(cat "$T17/uv.log" | tr '\n' ';') out=$(head -3 "$T17/out.txt" | tr '\n' ' ')"
# LT-17m: an unreadable pins file must not turn into an unpinned install.
cp "$T17/pins.txt" "$T17/pins-locked.txt"; chmod 000 "$T17/pins-locked.txt"
t17 UV_HAS=0.3.1 OKF_PINNED_VERSIONS="$T17/pins-locked.txt" -- --install-deps --yes; rc=$?
chmod 600 "$T17/pins-locked.txt"
{ [ "$rc" -eq 2 ] && ! grep -q "tool install" "$T17/uv.log"; } \
  && ok "LT-17m an unreadable pins file refuses the install instead of installing latest" \
  || bad "LT-17m unreadable pins" "rc=$rc log=$(cat "$T17/uv.log" | tr '\n' ';')"
# LT-17n: the install is time-bounded.
t17 UV_HAS=0.3.1 UV_SLEEP=20 OKF_INSTALL_TIMEOUT=2 UV_TOOLDIR="$T17/tooldir" UV_BINDIR="$T17/bindir" -- --install-deps --yes; rc=$?
{ [ "$rc" -eq 2 ] && grep -qi "timed out" "$T17/out.txt"; } \
  && ok "LT-17n a hung installer is stopped after the time limit (exit 2)" \
  || bad "LT-17n install timeout" "rc=$rc out=$(head -4 "$T17/out.txt" | tr '\n' ' ')"
# LT-17o: --json does not hide the plan or the result of an install request.
t17 UV_HAS=0.3.1 -- --install-deps --json
grep -q "plan" "$T17/out.txt" && ok "LT-17o --json does not swallow the install plan" || bad "LT-17o json plan" "out=$(head -3 "$T17/out.txt" | tr '\n' ' ')"
# LT-17p: --help lists the new flags.
"$CHECK" --help 2>&1 | grep -q -- "--install-deps" && "$CHECK" --help 2>&1 | grep -q "OKF_AUTO_INSTALL" \
  && ok "LT-17p --help documents --preflight, --install-deps, --yes, --latest, OKF_AUTO_INSTALL" \
  || bad "LT-17p help" "flags missing from --help"

# LT-14 (review of 0.5.11-0.5.17): the isolation mirror must never touch files outside the
# bundle, must survive a trailing slash, and must print awkward note names intact.
T14="$TMP/t14"; mkbundle "$T14"; T14X="$TMP/t14ext"; mkdir -p "$T14X"
printf -- '---\ntype: Lesson\ntitle: Good\ndescription: D\n---\nbody\n' > "$T14/good.md"
printf -- '---\ntype: Lesson\ntitle: A\ndescription: D\n---\nCRASHME\n' > "$T14/bad.md"
printf -- '---\ntype: Lesson\ntitle: W\ndescription: D\n---\nCRASHME\n' > "$T14/we|ird name.md"
printf -- '---\ntype: Lesson\ntitle: X\ndescription: D\n---\nCRASHME\n' > "$T14X/crashy.md"
printf -- '---\ntype: Lesson\ntitle: P\ndescription: D\n---\nprecious\n' > "$T14X/precious.md"
ln -s "$T14X" "$T14/linked"
"$S09" "$T14" > "$TMP/t14.out" 2>&1
[ -f "$T14X/precious.md" ] && [ -f "$T14X/crashy.md" ] && ok "LT-14a a symlinked directory's files survive crash isolation" \
  || bad "LT-14a files outside the bundle were deleted" "precious.md/crashy.md missing after the run"
expect_match "we|ird name.md: RuntimeError" "LT-14c a note name with | and spaces is printed intact" "$S09" "$T14"
expect_match "bad.md: RuntimeError" "LT-14b a trailing slash on the bundle path still isolates the crash" "$S09" "$T14/"
# LT-15: a hung okflint must not stall a normal run, and --doctor must stay bounded.
T15B="$TMP/t15bin"; mkdir -p "$T15B"
printf '#!/bin/sh\nsleep 30\n' > "$T15B/okflint"; chmod +x "$T15B/okflint"
t0=$(date +%s); env PATH="$T15B:$PATH" "$CHECK" "$T09" >/dev/null 2>&1; t1=$(date +%s)
[ $((t1 - t0)) -lt 20 ] && ok "LT-15a a hung okflint does not stall a normal run ($((t1 - t0))s)" \
  || bad "LT-15a a hung okflint stalled a normal run" "took $((t1 - t0))s"
t0=$(date +%s); env PATH="$T15B:$PATH" "$CHECK" --doctor >/dev/null 2>&1; t1=$(date +%s)
[ $((t1 - t0)) -lt 40 ] && ok "LT-15b --doctor is bounded against a hung okflint ($((t1 - t0))s)" \
  || bad "LT-15b --doctor hung" "took $((t1 - t0))s"
# LT-16: SIGTERM stops the gate.
T16="$TMP/t16plug"; cp -R "$T09P" "$T16"
printf 'STATUS_VALUES = {"draft", "stable", "deprecated"}\nimport time\ntime.sleep(60)\n' > "$T16/vendor/okf_validate.py"
( "$T16/scripts/okf-check" "$T09" >/dev/null 2>&1 & p=$!; sleep 1; kill -TERM $p 2>/dev/null; wait $p; echo $? > "$TMP/t16.rc" )
[ "$(cat "$TMP/t16.rc")" = "143" ] && ok "LT-16 SIGTERM stops okf-check (exit 143)" \
  || bad "LT-16 SIGTERM did not stop okf-check with 143" "rc=$(cat "$TMP/t16.rc")"
# LT-11: the vendored validator (patched, okf-skills PR #68) no longer crashes on the notes
# that used to blank L1. A revert to the unpatched file turns this red.
T11="$TMP/t11"; mkbundle "$T11"
printf -- '---\ntype: Lesson\ntitle: S\ndescription: D\nstatus: [draft, stable]\n---\nbody\n' > "$T11/status-list.md"
printf -- '---\ntype: Lesson\ntitle: D\ndescription: D\ndecided: 2026-02-30\n---\nbody\n' > "$T11/bad-date.md"
expect_match "bad-date.md: §11.1 frontmatter is not valid YAML" "LT-11a an impossible date is a per-file L1 error, not a crash" "$CHECK" "$T11"
expect_no_match "COULD NOT RUN" "LT-11b the vendored validator reaches a verdict on both notes" "$CHECK" "$T11"
# LT-10 (ticket 11): an okflint crash prints its reason, not only "report was not a findings list".
# A STUB crashes on purpose: patched okflint (PR mattdav/okflint#11) no longer crashes on the
# known inputs, so the reason-line logic is proven independent of any upstream bug.
# Needs a real okflint for everything except `validate`; a skip is stated, not a pass.
TPL10="$HERE/../config/okf-base.yaml.template"
if command -v okflint >/dev/null 2>&1 && [ -f "$TPL10" ]; then
  REALLINT=$(command -v okflint)
  T10B="$TMP/t10bin"; mkdir -p "$T10B"
  printf '#!/bin/sh\nif [ "$1" = validate ]; then echo "Traceback (most recent call last):" >&2; echo "UnicodeDecodeError: stub crash" >&2; exit 1; fi\nexec "%s" "$@"\n' "$REALLINT" > "$T10B/okflint"; chmod +x "$T10B/okflint"
  T10="$TMP/t10"; mkdir -p "$T10"; sed 's/^  name: CHANGE ME/  name: T/' "$TPL10" > "$T10/okf-base.yaml"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2099-01-01"\n---\nbody\n' > "$T10/ok.md"
  expect_match "reason:.*UnicodeDecodeError" "LT-10 an okflint crash prints the reason line" env PATH="$T10B:$PATH" "$CHECK" "$T10"
else
  skip "LT-10 okflint crash reason — okflint or the manifest template is absent" "uv tool install okflint"
fi
# LT-06 (ticket 08): an exported CDPATH must not redirect the script's own cd.
expect_match "L3 staleness" "LT-06a okf-check survives an exported CDPATH with a relative path" bash -c 'cd "$1" && CDPATH="$1" bash scripts/okf-check "$2"' _ "$HERE/.." "$STALE"

# S30-CF-L1: expired notes whose names hold a space, an ESC byte and a byte that is not UTF-8 are each listed by L3 (a
# PASS that skipped them would be a false pass). A disk that refuses the non-UTF-8 name (APFS) skips this, not a pass.
T29="$TMP/t29"; mkbundle "$T29"
for n in 'a b' "e$(printf '\033')x" "n$(printf '\377')u"; do
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nbody\n' > "$T29/$n.md" 2>/dev/null
done
if [ "$(find "$T29" -name '*.md' | wc -l | tr -d ' ')" -ne 6 ]; then
  skip "S30-CF-L1 this disk refuses a note name that is not UTF-8 (run on Linux)"
else
  "$CHECK" "$T29" >"$TMP/t29.txt" 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'L3 staleness' "$TMP/t29.txt" && ! grep -q 'COULD NOT RUN' "$TMP/t29.txt" \
    && [ "$(grep -c '(stale_after' "$TMP/t29.txt")" -eq 3 ]; } \
    && ok "S30-CF-L1 three expired notes named with a space, ESC and a non-UTF-8 byte: L3 lists all three (exit 0)" \
    || bad "S30-CF-L1 odd names" "rc=$rc $(grep -c '(stale_after' "$TMP/t29.txt") listed; $(grep -E 'L3|COULD' "$TMP/t29.txt" | cat -v | tr '\n' ' ')"
fi

# LT-CE1/CE2: L3 derived measures a cited sources[].resource only when it exists with the case as written (the citation
# rule of okf-verify, D-11). On a case-insensitive disk SRC.txt used to be measured through src.txt, and on Linux it was
# not: the same bundle got two verdicts.
CE="$TMP/ce"; mkbundle "$CE"; echo x > "$CE/src.txt"
_ce_note() { printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nsources:\n  - resource: %s\n    last_modified: "2000-01-01"\n---\nbody\n' "$1" > "$CE/c.md"; }
_ce_note SRC.txt; "$CHECK" "$CE" >"$TMP/ce1.txt" 2>&1
{ grep -q 'L3 derived       c.md: SRC.txt is not a local file' "$TMP/ce1.txt" && ! grep -q 'SRC.txt changed' "$TMP/ce1.txt"; } \
  && ok "LT-CE1 a cited source in another case (SRC.txt, the disk holds src.txt) is not measured" \
  || bad "LT-CE1 cited source case" "$(grep 'L3 derived' "$TMP/ce1.txt" | head -2 | tr '\n' ' ')"
_ce_note src.txt; "$CHECK" "$CE" >"$TMP/ce2.txt" 2>&1
grep -q 'L3 derived       c.md: src.txt changed ' "$TMP/ce2.txt" \
  && ok "LT-CE2 control: the source cited as written is measured (STALE)" \
  || bad "LT-CE2 control" "$(grep 'L3 derived' "$TMP/ce2.txt" | head -2 | tr '\n' ' ')"
# LT-CE3: the case rule judges only the cited part, never how the bundle path was typed. `okf-check .` (the pre-commit
# form) with a source in the parent folder (`../x.txt`) is measured as on the base release (exit 4 with --fail-stale), and
# so is the bundle given in another case on a case-insensitive disk.
CE3="$TMP/ce3"; mkdir -p "$CE3/Repo"; mkbundle "$CE3/Repo/b"; echo x > "$CE3/Repo/x.txt"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nsources:\n  - resource: ../x.txt\n    last_modified: "2000-01-01"\n---\nbody\n' > "$CE3/Repo/b/c.md"
(cd "$CE3/Repo/b" && "$CHECK" . --fail-stale) >"$TMP/ce3.txt" 2>&1; rc=$?
{ [ "$rc" -eq 4 ] && grep -q 'L3 derived       c.md: ../x.txt changed ' "$TMP/ce3.txt"; } \
  && ok "LT-CE3 okf-check . with a ../ source: measured, exit 4 with --fail-stale" \
  || bad "LT-CE3 okf-check . and a ../ source" "rc=$rc $(grep 'L3 derived' "$TMP/ce3.txt" | head -2 | tr '\n' ' ')"
if [ -d "$CE3/repo/b" ]; then
  "$CHECK" "$CE3/repo/b" --fail-stale >"$TMP/ce3b.txt" 2>&1; rc=$?
  { [ "$rc" -eq 4 ] && grep -q 'L3 derived       c.md: ../x.txt changed ' "$TMP/ce3b.txt"; } \
    && ok "LT-CE3b the bundle path typed in another case (repo/b for Repo/b): the source is still measured, exit 4" \
    || bad "LT-CE3b bundle path case" "rc=$rc $(grep 'L3 derived' "$TMP/ce3b.txt" | head -2 | tr '\n' ' ')"
else
  skip "LT-CE3b bundle path typed in another case: a case-sensitive disk, repo/b does not exist"
fi
# LT-CE4: okf_guard.case_exact, which okf-verify calls too, judges a relative path that climbs (`../x.txt`) from the folder
# it is relative to: it used to look for `..` in a folder listing and answer False for a file that exists as written.
_ce4=$(cd "$CE3/Repo/b" && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from okf_guard import case_exact
print(case_exact("../x.txt"), case_exact("../X.TXT"), case_exact("../x.txt", "."))' "$HERE" 2>&1)
[ "$_ce4" = "True False True" ] && ok "LT-CE4 case_exact: ../x.txt as written is True, ../X.TXT is False, from the folder it is relative to" \
  || bad "LT-CE4 case_exact and ../" "got '$_ce4' (want 'True False True')"

# LT-SV1: the spec status list has one source, the vendored validator's STATUS_VALUES; L3 (l3-lib.sh) reads it. A copy of
# the plugin with one more value in the validator must make L3 accept it too.
SV="$TMP/sv"; mkdir -p "$SV"; cp -R "$HERE/.." "$SV/plugin"
sed -i.bak 's/^STATUS_VALUES = {"draft", "stable", "deprecated"}$/STATUS_VALUES = {"draft", "stable", "deprecated", "review"}/' \
  "$SV/plugin/vendor/okf_validate.py"
_sv=$(bash -c '. "$1/plugin/scripts/l3-lib.sh"; awk "$L3_AWK_LIB"'\''BEGIN { print okfstatusok("review") okfstatusok("stable") okfstatusok("bogus") okfstatusok("") okfstatusok("draft,stable") }'\' _ "$SV" 2>&1)
{ grep -q '"review"}$' "$SV/plugin/vendor/okf_validate.py" && [ "$_sv" = "11000" ]; } \
  && ok "LT-SV1 L3 accepts exactly the validator's STATUS_VALUES (one source)" || bad "LT-SV1 status source" "got '$_sv' (want 11000)"
# LT-SV2: the house copies of the list (status_values in this repository's .okf/okf-base.yaml and the shipped template) equal
# the spec list. They are separate on purpose (docs/feature-landscape-2026-10-14.md section 5), so this test keeps them
# from drifting. The planted copy proves the comparison can fail.
_svdrift() {   # <validator> <yaml>...: prints each list that differs from STATUS_VALUES
  PYTHONPATH="$HERE/../vendor/pyyaml" python3 - "$@" <<'PY'
import ast, re, sys, yaml
src = open(sys.argv[1], encoding="utf-8").read()
spec = ast.literal_eval(re.search(r"^STATUS_VALUES = (\{.*\})$", src, re.M).group(1))
def lists(n):
    if isinstance(n, dict):
        for k, v in n.items():
            if k == "status_values": yield v
            else: yield from lists(v)
    elif isinstance(n, list):
        for v in n: yield from lists(v)
for f in sys.argv[2:]:
    found = list(lists(yaml.safe_load(open(f, encoding="utf-8"))))
    if not found: print(f"{f}: no status_values")
    for v in found:
        if not isinstance(v, list) or set(v) != spec: print(f"{f}: {v}")
PY
}
# .okf/ is this repository's own bundle and is not in the public export: compared where it exists.
_svf=("$HERE/../config/okf-base.yaml.template"); [ -f "$HERE/../../.okf/okf-base.yaml" ] && _svf+=("$HERE/../../.okf/okf-base.yaml")
_d=$(_svdrift "$HERE/../vendor/okf_validate.py" "${_svf[@]}" 2>&1)
_p=$(_svdrift "$SV/plugin/vendor/okf_validate.py" "$HERE/../config/okf-base.yaml.template" 2>&1)
{ [ -z "$_d" ] && [ -n "$_p" ]; } && ok "LT-SV2 every status_values copy equals the validator's STATUS_VALUES (a planted drift is caught)" \
  || bad "LT-SV2 status_values drift" "drift: ${_d:-none}; planted: ${_p:-not caught}"
# LT-SV3: a status list l3-lib.sh cannot read is named, never an awk error read as "nothing to report". Each case is a copy
# of the plugin with the validator's STATUS_VALUES line changed: two lines (a), a non-list (b), the file gone (c). okf-check
# exits 2 naming STATUS_VALUES; the SessionStart hook says the statuses were not checked. Single quotes (d) are a list.
_sv3() {   # <case> <python that rewrites the validator text in variable s, or "rm">
  local d="$TMP/sv3$1"; mkdir -p "$d"; cp -R "$HERE/.." "$d/plugin"
  if [ "$2" = rm ]; then rm -f "$d/plugin/vendor/okf_validate.py"
  else python3 -c '
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
exec(sys.argv[2])
open(p, "w", encoding="utf-8").write(s)' "$d/plugin/vendor/okf_validate.py" "$2"; fi
  echo "$d"
}
SVL="$TMP/sv3lessons"; mkdir -p "$SVL"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: bogus\nstale_after: "2099-01-01"\n---\nbody\n' > "$SVL/l.md"
miss=""
for c in a b c; do
  case "$c" in
    a) d=$(_sv3 a 's = s.replace("STATUS_VALUES = {", "STATUS_VALUES = {\"x\"}\nSTATUS_VALUES = {", 1)') ;;
    b) d=$(_sv3 b 's = s.replace("STATUS_VALUES = {\"draft\", \"stable\", \"deprecated\"}", "STATUS_VALUES = {LIFECYCLE}", 1)') ;;
    c) d=$(_sv3 c rm) ;;
  esac
  "$d/plugin/scripts/okf-check" "$STALE" >"$d/out" 2>&1; rc=$?
  { [ "$rc" -eq 2 ] && grep -q 'STATUS_VALUES' "$d/out"; } || miss="$miss $c:okf-check(rc=$rc $(head -1 "$d/out" | cut -c1-90))"
  h=$(OKF_BUNDLE_DIR="$SVL" bash "$d/plugin/scripts/lessons-staleness-check.sh" 2>&1)
  case "$h" in *STATUS_VALUES*"NOT checked"*) ;; *) miss="$miss $c:hook($(printf %s "$h" | head -1 | cut -c1-90))" ;; esac
done
d=$(_sv3 d 's = s.replace("STATUS_VALUES = {\"draft\", \"stable\", \"deprecated\"}", "STATUS_VALUES = {'"'"'draft'"'"', '"'"'stable'"'"', '"'"'deprecated'"'"'}", 1)')
_q=$(bash -c '. "$1/plugin/scripts/l3-lib.sh"; awk "$L3_AWK_LIB"'\''BEGIN { print okfstatusok("stable") okfstatusok("bogus") }'\' _ "$d" 2>&1)
[ "$_q" = "10" ] || miss="$miss d:single-quotes($_q)"
[ -z "$miss" ] && ok "LT-SV3 an unreadable STATUS_VALUES stops okf-check (exit 2) and the hook (named); single quotes are read" \
  || bad "LT-SV3 status list errors" "$miss"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
