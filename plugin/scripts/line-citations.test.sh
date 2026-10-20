#!/usr/bin/env bash
# Tests for okf-verify line citations into living documents (public okf-knowledge-gate #14, slice a; cases S21-LC-* in
# docs/0.9.x-cases.md). A note cites `decision-12.md:94`, `spec.md:40-42` or `decision-12:94` (no commit): the cited file
# must exist with that many lines. CONFIRMED / REFUTED / UNRESOLVED keep their meaning: REFUTED only when the file was
# found and is shorter; a file that is missing, ambiguous or outside the bundle and the searched repositories is UNRESOLVED.
#
# bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
VERIFY="$HERE/okf-verify"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"

# note <file> <body>: a conformant note with that body.
note() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: Lesson\ntitle: T %s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n%s\n' "$1" "$2" > "$1"
}
# lines <file> <n>: a plain document of exactly n lines, each ending in a newline.
lines() { mkdir -p "$(dirname "$1")"; : > "$1"; i=1; while [ "$i" -le "$2" ]; do printf 'line %s\n' "$i" >> "$1"; i=$((i + 1)); done; }
# run <bundle> [args]: text in $TMP/out.txt, exit code on stdout. runjson: the JSON report in $TMP/out.json.
run() { local b="$1"; shift; "$VERIFY" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
runjson() { local b="$1"; shift; "$VERIFY" "$b" --json "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
# verdicts <json expr over r>: one python expression evaluated per result of kind "line", printed as JSON.
lineres() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([[r["claim"], r["verdict"]] for r in d["results"] if r["kind"] == "line"]))' "$TMP/out.json"; }

section "happy"
# Spec row LC-1 (slice a) is covered by the happy, negative and edge sections.
# S21-LC-H1: the reporter's form. decision-12.md has 100 lines; line 94 is within it.
B="$TMP/h1"; mkbundle "$B"; lines "$B/decision-12.md" 100; note "$B/a.md" "As decided in decision-12.md:94, shadow first."
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["decision-12.md:94", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-H1 decision-12.md:94 into a 100-line note is a line claim, CONFIRMED (exit 0)" || bad "S21-LC-H1 name.md:N" "rc=$rc got=$got"

# S21-LC-H2: a range ending on the last line.
B="$TMP/h2"; mkbundle "$B"; lines "$B/spec.md" 42; note "$B/a.md" "See spec.md:40-42."
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["spec.md:40-42", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-H2 spec.md:40-42 into a 42-line file is CONFIRMED (the trailing full stop is not part of the claim)" || bad "S21-LC-H2 range" "rc=$rc got=$got"

# S29-LZ-E3: a zero-padded line number is the number it spells, in a document citation too (plain, and with a quoted anchor).
B="$TMP/lz-d1"; mkbundle "$B"; lines "$B/spec.md" 42; note "$B/a.md" "See spec.md:0000000040-0000000042."
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["spec.md:0000000040-0000000042", "CONFIRMED"]]' ]; } \
  && ok "S29-LZ-E3 spec.md:0000000040-0000000042 into a 42-line file is CONFIRMED" || bad "S29-LZ-E3 zero-padded range" "rc=$rc got=$got"
B="$TMP/lz-d2"; mkbundle "$B"; lines "$B/spec.md" 42; note "$B/a.md" 'spec.md:0000000007 "line 7"'
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["spec.md:0000000007", "CONFIRMED"]]' ]; } \
  && ok "S29-LZ-E3 a zero-padded line with a quoted anchor finds the text on that line" || bad "S29-LZ-E3 zero-padded anchor" "rc=$rc got=$got"

# S21-LC-H3: the short form, resolved by unique file name.
B="$TMP/h3"; mkbundle "$B"; lines "$B/notes/decision-12.md" 100; note "$B/a.md" "As decided in decision-12:94."
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["decision-12:94", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-H3 decision-12:94 resolves by unique name to notes/decision-12.md, CONFIRMED" || bad "S21-LC-H3 name:N" "rc=$rc got=$got"

# S21-LC-H4: a path relative to the citing note's folder, and one relative to the bundle root.
B="$TMP/h4"; mkbundle "$B"; lines "$B/d/x.md" 5; lines "$B/top.md" 5; note "$B/d/a.md" "x.md:5 and top.md:2 and d/x.md:1"
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["x.md:5", "CONFIRMED"], ["top.md:2", "CONFIRMED"], ["d/x.md:1", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-H4 paths resolve from the note's folder, then the bundle root" || bad "S21-LC-H4 relative paths" "rc=$rc got=$got"

# S21-LC-H5: a document of a searched repository (declared or --repo), by its repo-relative path.
B="$TMP/h5"; mkbundle "$B"; R="$TMP/h5repo"; mkdir -p "$R/docs"; git init -q "$R"; lines "$R/docs/guide.md" 3
note "$B/a.md" "The guide says so at docs/guide.md:3."
rc=$(runjson "$B" --repo "$R"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["docs/guide.md:3", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-H5 a repo-relative document of a --repo folder is checked in its working tree" || bad "S21-LC-H5 repo document" "rc=$rc got=$got"

section "negative"
# S21-LC-N1: the file exists and is shorter: REFUTED, the detail gives its line count, exit 1.
B="$TMP/n1"; mkbundle "$B"; lines "$B/decision-12.md" 100; note "$B/a.md" "decision-12.md:200"
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -q 'REFUTED.*decision-12.md:200' "$TMP/out.txt" && grep -q 'has 100 lines' "$TMP/out.txt"; } \
  && ok "S21-LC-N1 a line past the end is REFUTED with the file's line count (exit 1)" || bad "S21-LC-N1 past the end" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S21-LC-N2: line 0, and a range whose end is past the end.
B="$TMP/n2"; mkbundle "$B"; lines "$B/s.md" 10; note "$B/a.md" "s.md:0 and s.md:9-11"
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 1 ] && [ "$got" = '[["s.md:0", "REFUTED"], ["s.md:9-11", "REFUTED"]]' ]; } \
  && ok "S21-LC-N2 line 0 and a range past the end are REFUTED" || bad "S21-LC-N2 line 0 / range" "rc=$rc got=$got"

# S21-LC-N3: a cited document that is nowhere: UNRESOLVED (nobody can say it is false), exit 0.
B="$TMP/n3"; mkbundle "$B"; note "$B/a.md" "missing.md:3"
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -q 'unresolved.*missing.md:3' "$TMP/out.txt" && grep -q 'not found' "$TMP/out.txt"; } \
  && ok "S21-LC-N3 a document found nowhere is UNRESOLVED, never REFUTED (exit 0)" || bad "S21-LC-N3 missing" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S21-LC-N4: two notes end with the cited path and neither relative reading applies: ambiguous, UNRESOLVED.
B="$TMP/n4"; mkbundle "$B"; lines "$B/p/d.md" 5; lines "$B/q/d.md" 5; note "$B/r/a.md" "d.md:1 and d:2"
rc=$(run "$B")
{ [ "$rc" = 0 ] && [ "$(grep -c 'ambiguous' "$TMP/out.txt")" -ge 2 ] && ! grep -q '^  REFUTED ' "$TMP/out.txt"; } \
  && ok "S21-LC-N4 a name two notes share is UNRESOLVED (ambiguous), in both forms" || bad "S21-LC-N4 ambiguous" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S21-LC-N5: `Step:2`, `10:30` and `localhost:8080` name no note: no claim. The note is listed as having no checkable
# claim, and the strings that look like citations are counted with an example (part 3); a time is not counted.
B="$TMP/n5"; mkbundle "$B"; note "$B/a.md" "Step:2 at 10:30 on localhost:8080."
rc=$(runjson "$B"); got=$("$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); u=[x for x in d.get("unrecognized_citations", []) if x["concept"] == "a.md"]; print(json.dumps([d["no_checkable_claims"].count("a.md"), u[0]["count"] if u else None, (u[0]["examples"] if u else [])]))' "$TMP/out.json")
run "$B" >/dev/null
{ [ "$rc" = 0 ] && [ "$got" = '[1, 2, ["Step:2", "localhost:8080"]]' ] && grep -q 'a.md.*2 string(s) look like citations but match no checkable form' "$TMP/out.txt"; } \
  && ok "S21-LC-N5 citation-shaped strings that name no note are not claims; they are counted for the no-claim note" || bad "S21-LC-N5 unrecognized" "rc=$rc got=$got $(grep 'a.md' "$TMP/out.txt" | head -2 | tr '\n' ' ')"

section "edge"
# S21-LC-E1: inside a fenced or indented code block a line citation is a literal, not a claim.
B="$TMP/e1"; mkbundle "$B"; lines "$B/s.md" 2; note "$B/a.md" $'```\ns.md:99\n```\n\n    s.md:98\n\nand s.md:1'
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["s.md:1", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-E1 line citations inside code blocks are ignored" || bad "S21-LC-E1 code" "rc=$rc got=$got"

# S21-LC-E2: a citation pinned to a commit (`d.md:3 @sha`) stays ONE claim of kind citation, not also a line claim.
B="$TMP/e2"; mkbundle "$B"; R="$TMP/e2repo"; mkdir -p "$R"; git init -q "$R"; lines "$R/d.md" 5
git -C "$R" add d.md; git -C "$R" -c user.name=t -c user.email=t@e -c commit.gpgsign=false commit -qm init; sha=$(git -C "$R" rev-parse --short HEAD)
note "$B/a.md" "Pinned: d.md:3 @$sha"
rc=$(runjson "$B" --repo "$R"); got=$("$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(sorted(r["kind"] for r in d["results"])))' "$TMP/out.json")
{ [ "$rc" = 0 ] && [ "$got" = '["citation"]' ]; } && ok "S21-LC-E2 a pinned citation is not also counted as a line claim" || bad "S21-LC-E2 pinned" "rc=$rc kinds=$got"

# S21-LC-E3: a URL, a path glued to other text and a Windows path are not line citations.
B="$TMP/e3"; mkbundle "$B"; lines "$B/d.md" 5; note "$B/a.md" 'https://example.com/d.md:3 and x/../d.md:3x and C:\w\d.md:3'
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[]' ]; } && ok "S21-LC-E3 a URL, a glued suffix and a Windows path give no line claim" || bad "S21-LC-E3 non-citations" "rc=$rc got=$got"

# S21-LC-E4: a relative path that leaves the bundle (and every searched repo) is not opened: UNRESOLVED, so a bundle you did
# not write cannot use the check to learn which files exist on your machine.
mkdir -p "$TMP/e4out"; lines "$TMP/e4out/secret.md" 5
B="$TMP/e4/b"; mkbundle "$B"; note "$B/a.md" "../../e4out/secret.md:2"
rc=$(run "$B")
{ [ "$rc" = 0 ] && grep -q 'unresolved.*secret.md:2' "$TMP/out.txt" && grep -q 'outside the bundle' "$TMP/out.txt"; } \
  && ok "S21-LC-E4 a path outside the bundle and the searched repos is not looked up (UNRESOLVED)" || bad "S21-LC-E4 escape" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S21-LC-E5: a last line without a final newline counts; index.md is a valid target; the same claim twice is reported once.
B="$TMP/e5"; mkbundle "$B"; printf 'a\nb\nc' > "$B/nofinal.md"; note "$B/a.md" "nofinal.md:3, index.md:2 and again nofinal.md:3"
rc=$(runjson "$B"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["nofinal.md:3", "CONFIRMED"], ["index.md:2", "CONFIRMED"]]' ]; } \
  && ok "S21-LC-E5 a last line without a newline counts, index.md is a target, a repeated claim is reported once" || bad "S21-LC-E5 edges" "rc=$rc got=$got"

# S21-LC-E6: a note with a line claim is not in no_checkable_claims, and gets no unrecognized count.
B="$TMP/e6"; mkbundle "$B"; lines "$B/s.md" 3; note "$B/a.md" "s.md:2 and Step:4"
rc=$(runjson "$B"); got=$("$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(["a.md" in d["no_checkable_claims"], [x["concept"] for x in d.get("unrecognized_citations", [])]]))' "$TMP/out.json")
{ [ "$rc" = 0 ] && [ "$got" = '[false, []]' ]; } && ok "S21-LC-E6 a note with a checkable line claim is not listed as unverifiable" || bad "S21-LC-E6 claim counts" "rc=$rc got=$got"

section "anchors (slice b)"
# Spec row LC-2.
# docfile <file> <line>...: a document whose lines are the arguments.
docfile() { mkdir -p "$(dirname "$1")"; f=$1; shift; : > "$f"; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done; }
lineall() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([[r["claim"], r["verdict"], r.get("moved_to")] for r in d["results"] if r["kind"] in ("line", "citation")]))' "$TMP/out.json"; }

# S21-LC-A1: the quoted text is on the cited line: CONFIRMED. Whitespace inside the quote is compared collapsed.
B="$TMP/a1"; mkbundle "$B"; docfile "$B/decision-12.md" "intro" "We roll out with shadow,   canary and then full." "end"
note "$B/a.md" 'decision-12.md:2 "shadow, canary"'
rc=$(runjson "$B"); got=$(lineall)
{ [ "$rc" = 0 ] && [ "$got" = '[["decision-12.md:2", "CONFIRMED", null]]' ]; } \
  && ok "S21-LC-A1 an anchor found on the cited line is CONFIRMED (whitespace collapsed)" || bad "S21-LC-A1 anchor on line" "rc=$rc got=$got"

# S21-LC-A2: the reporter's drift. One line was added above; the quote is now on line 3: MOVED, with the new line, exit 1.
B="$TMP/a2"; mkbundle "$B"; docfile "$B/decision-12.md" "intro" "a new step" "We roll out with shadow, canary." "end"
note "$B/a.md" 'decision-12.md:2 "shadow, canary"'
rc=$(runjson "$B"); got=$(lineall); run "$B" >/dev/null
{ [ "$rc" = 1 ] && [ "$got" = '[["decision-12.md:2", "MOVED", "3"]]' ] && grep -q 'MOVED.*decision-12.md:2' "$TMP/out.txt" \
  && grep -q 'now on line 3' "$TMP/out.txt" && grep -q 'MOVED 1' "$TMP/out.txt"; } \
  && ok "S21-LC-A2 an anchor found on another line is MOVED with the new line number (exit 1, counted)" || bad "S21-LC-A2 moved" "rc=$rc got=$got $(grep -i moved "$TMP/out.txt" | head -2 | tr '\n' ' ')"

# S21-LC-A3: the quote is nowhere in the file: REFUTED (the content is gone, not moved).
B="$TMP/a3"; mkbundle "$B"; docfile "$B/d.md" "one" "two"; note "$B/a.md" 'd.md:1 "shadow, canary"'
rc=$(runjson "$B"); got=$(lineall)
{ [ "$rc" = 1 ] && [ "$got" = '[["d.md:1", "REFUTED", null]]' ]; } && ok "S21-LC-A3 an anchor found nowhere is REFUTED" || bad "S21-LC-A3 gone" "rc=$rc got=$got"

# S21-LC-A4: a line now past the end, with the quote elsewhere: MOVED, not REFUTED; a range moves as a range.
B="$TMP/a4"; mkbundle "$B"; docfile "$B/d.md" "alpha" "beta" "gamma"; note "$B/a.md" 'd.md:9 "beta" and d.md:7-8 "beta gamma"'
rc=$(runjson "$B"); got=$(lineall)
{ [ "$rc" = 1 ] && [ "$got" = '[["d.md:9", "MOVED", "2"], ["d.md:7-8", "MOVED", "2-3"]]' ]; } \
  && ok "S21-LC-A4 a line past the end with its anchor elsewhere is MOVED; a two-line anchor moves as a range" || bad "S21-LC-A4 range move" "rc=$rc got=$got"

# S21-LC-A5: the quote is on several other lines: MOVED, and the detail names every candidate (up to three).
B="$TMP/a5"; mkbundle "$B"; docfile "$B/d.md" "x" "same text" "y" "same text"; note "$B/a.md" 'd.md:1 "same text"'
rc=$(run "$B")
{ [ "$rc" = 1 ] && grep -q 'now on line 2 or 4' "$TMP/out.txt"; } && ok "S21-LC-A5 an anchor on several other lines is MOVED naming each candidate" || bad "S21-LC-A5 candidates" "rc=$rc $(grep -i 'moved\|now on' "$TMP/out.txt" | head -2 | tr '\n' ' ')"

# S21-LC-A6: the short form and curly quotes carry an anchor too.
B="$TMP/a6"; mkbundle "$B"; docfile "$B/n/decision-12.md" "a" "b" "shadow, canary"; note "$B/a.md" 'decision-12:3 “shadow, canary”'
rc=$(runjson "$B"); got=$(lineall)
{ [ "$rc" = 0 ] && [ "$got" = '[["decision-12:3", "CONFIRMED", null]]' ]; } && ok "S21-LC-A6 the short form with a curly-quoted anchor is checked" || bad "S21-LC-A6 short+curly" "rc=$rc got=$got"

# S21-LC-A7: a citation pinned to a commit is history: its anchor is checked at that commit, on the cited lines only, and it is
# never MOVED (the reporter's dated review record must not be renumbered). On the line: CONFIRMED; elsewhere: REFUTED.
B="$TMP/a7"; mkbundle "$B"; R="$TMP/a7repo"; mkdir -p "$R"; git init -q "$R"; docfile "$R/d.md" "intro" "shadow, canary" "end"
git -C "$R" add d.md; git -C "$R" -c user.name=t -c user.email=t@e -c commit.gpgsign=false commit -qm init; sha=$(git -C "$R" rev-parse --short HEAD)
docfile "$R/d.md" "new" "intro" "shadow, canary" "end"   # the working tree moved on; the commit did not
note "$B/a.md" "d.md:2 @$sha \"shadow, canary\" and d.md:1 @$sha \"shadow, canary\""
rc=$(runjson "$B" --repo "$R"); got=$(lineall)
{ [ "$rc" = 1 ] && [ "$got" = "[[\"d.md:2 @$sha\", \"CONFIRMED\", null], [\"d.md:1 @$sha\", \"REFUTED\", null]]" ]; } \
  && ok "S21-LC-A7 a pinned citation's anchor is checked at its commit and is never MOVED" || bad "S21-LC-A7 pinned anchor" "rc=$rc got=$got"

# S21-LC-A8: without an anchor nothing changes: a citation keeps the slice-a verdicts, judged by its line number alone.
B="$TMP/a8"; mkbundle "$B"; docfile "$B/d.md" "a" "b"; note "$B/a.md" 'd.md:2 and d.md:3'
rc=$(runjson "$B"); got=$(lineall)
{ [ "$rc" = 1 ] && [ "$got" = '[["d.md:2", "CONFIRMED", null], ["d.md:3", "REFUTED", null]]' ]; } \
  && ok "S21-LC-A8 without an anchor a citation is judged by its line number alone, as in slice a" || bad "S21-LC-A8 no anchor" "rc=$rc got=$got"

section "shifted and generated (slice c)"
# Spec row LC-3.
gitc() { git -C "$1" -c user.name=t -c user.email=t@e -c commit.gpgsign=false "${@:2}"; }
warns() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([[r["claim"], r["verdict"], r.get("moved_to"), bool(r.get("warning"))] for r in d["results"] if r["kind"] == "line"]))' "$TMP/out.json"; }

# S21-LC-C1: the reporter's case. One line was added to decision.md; a citation into it still points at an existing line, so
# without --since it reads CONFIRMED. With --since HEAD the cited text is found one line lower: MOVED, with the new line.
B="$TMP/c1"; mkbundle "$B"; git init -q "$B"; docfile "$B/decision.md" "a" "b" "the rule" "c"; note "$B/a.md" "See decision.md:3."
gitc "$B" add -A; gitc "$B" commit -qm base; docfile "$B/decision.md" "new step" "a" "b" "the rule" "c"
rc=$(runjson "$B"); before=$(warns); rc2=$(runjson "$B" --since HEAD); got=$(warns); run "$B" --since HEAD >/dev/null
{ [ "$rc" = 0 ] && [ "$before" = '[["decision.md:3", "CONFIRMED", null, false]]' ] && [ "$rc2" = 1 ] \
  && [ "$got" = '[["decision.md:3", "MOVED", "4", false]]' ] && grep -q 'was on line 3 at HEAD and is now on line 4' "$TMP/out.txt"; } \
  && ok "S21-LC-C1 --since: a citation whose text shifted down one line is MOVED with the new line (exit 1)" || bad "S21-LC-C1 shifted" "rc=$rc before=$before rc2=$rc2 got=$got"

# S29-LZ-E4: the same shift, cited with zero-padded numbers (a line and a range): --since compares the cited block and the MOVED
# detail names the new line or range.
B="$TMP/c1z"; mkbundle "$B"; git init -q "$B"; docfile "$B/decision.md" "a" "b" "the rule" "c"; note "$B/a.md" "See decision.md:0000000003 and decision.md:0000000002-0000000003."
gitc "$B" add -A; gitc "$B" commit -qm base; docfile "$B/decision.md" "new step" "a" "b" "the rule" "c"
rc=$(runjson "$B" --since HEAD); got=$(warns); run "$B" --since HEAD >/dev/null
{ [ "$rc" = 1 ] && [ "$got" = '[["decision.md:0000000003", "MOVED", "4", false], ["decision.md:0000000002-0000000003", "MOVED", "3-4", false]]' ] \
  && grep -q 'was on line 0000000003 at HEAD and is now on line 4' "$TMP/out.txt" && grep -q 'was on line 0000000002-0000000003 at HEAD and is now on line 3-4' "$TMP/out.txt"; } \
  && ok "S29-LZ-E4 --since: zero-padded line and range citations are MOVED with the new line (4) and range (3-4)" || bad "S29-LZ-E4 zero-padded shift" "rc=$rc got=$got $(grep 'now on' "$TMP/out.txt" | head -2)"

# S21-LC-C2: the cited file did not change since the ref: no comparison, the plain verdict.
B="$TMP/c2"; mkbundle "$B"; git init -q "$B"; docfile "$B/d.md" "a" "b"; note "$B/a.md" "d.md:2"; gitc "$B" add -A; gitc "$B" commit -qm base
rc=$(runjson "$B" --since HEAD); got=$(warns)
{ [ "$rc" = 0 ] && [ "$got" = '[["d.md:2", "CONFIRMED", null, false]]' ]; } && ok "S21-LC-C2 --since: an unchanged file keeps the plain verdict" || bad "S21-LC-C2 unchanged" "rc=$rc got=$got"

# S21-LC-C3: the cited line itself was edited (its text is nowhere now): the verdict stays (the line exists) and a warning
# says the cited line changed since the ref, so a reviewer looks.
B="$TMP/c3"; mkbundle "$B"; git init -q "$B"; docfile "$B/d.md" "a" "old text" "c"; note "$B/a.md" "d.md:2"; gitc "$B" add -A; gitc "$B" commit -qm base
docfile "$B/d.md" "a" "new text" "c"
rc=$(runjson "$B" --since HEAD); got=$(warns); run "$B" --since HEAD >/dev/null
{ [ "$rc" = 0 ] && [ "$got" = '[["d.md:2", "CONFIRMED", null, true]]' ] && grep -q '! .*changed since HEAD' "$TMP/out.txt"; } \
  && ok "S21-LC-C3 --since: an edited cited line keeps its verdict with a warning that it changed" || bad "S21-LC-C3 edited" "rc=$rc got=$got $(grep '!' "$TMP/out.txt" | head -2)"

# S21-LC-C4: an anchored citation is judged by its anchor, not by --since; a file created after the ref is not compared.
B="$TMP/c4"; mkbundle "$B"; git init -q "$B"; docfile "$B/d.md" "a" "the rule"; note "$B/a.md" 'd.md:2 "the rule" and n.md:1'
gitc "$B" add -A; gitc "$B" commit -qm base; docfile "$B/d.md" "x" "a" "the rule"; docfile "$B/n.md" "fresh"
rc=$(runjson "$B" --since HEAD); got=$(warns)
{ [ "$rc" = 1 ] && [ "$got" = '[["d.md:2", "MOVED", "3", false], ["n.md:1", "CONFIRMED", null, false]]' ]; } \
  && ok "S21-LC-C4 --since leaves anchored citations to their anchor and does not compare a file new since the ref" || bad "S21-LC-C4 anchor/new" "rc=$rc got=$got"

# S21-LC-C5: --since needs a git repository and a commit: otherwise exit 2 with one line, and no verdicts.
B="$TMP/c5"; mkbundle "$B"; note "$B/a.md" "c.md:1"
rc=$(run "$B" --since HEAD); l1=$(grep -c . "$TMP/out.txt"); m1=$(grep -c 'needs the bundle inside a git repository' "$TMP/out.txt")
B2="$TMP/c5b"; mkbundle "$B2"; git init -q "$B2"; gitc "$B2" add -A; gitc "$B2" commit -qm base
rc2=$(run "$B2" --since no-such-ref)
{ [ "$rc" = 2 ] && [ "$l1" = 1 ] && [ "$m1" = 1 ] && [ "$rc2" = 2 ] && [ "$(grep -c .  "$TMP/out.txt")" = 1 ] && grep -q 'no-such-ref: not a commit' "$TMP/out.txt"; } \
  && ok "S21-LC-C5 --since outside a git repository or with an unknown ref is exit 2 with one line" || bad "S21-LC-C5 bad --since" "rc=$rc lines=$l1 rc2=$rc2 $(cat "$TMP/out.txt" | head -2)"

# S21-LC-G1: okf_check.verify.generated lists notes a script regenerates (globs, the .okfignore matcher). A line citation into
# one, without an anchor, keeps its verdict and carries a warning: its line numbers change on every rebuild.
B="$TMP/g1"; mkbundle "$B"; printf 'okf_check:\n  verify:\n    generated: ["registers/**"]\n' > "$B/okf-base.yaml"
docfile "$B/registers/r.md" "a" "b"; docfile "$B/plain.md" "a" "b"; note "$B/a.md" 'registers/r.md:2, r:1, plain.md:2 and registers/r.md:1 "a"'
rc=$(runjson "$B"); got=$(warns); run "$B" >/dev/null
{ [ "$rc" = 0 ] && [ "$got" = '[["registers/r.md:2", "CONFIRMED", null, true], ["plain.md:2", "CONFIRMED", null, false], ["registers/r.md:1", "CONFIRMED", null, false], ["r:1", "CONFIRMED", null, true]]' ] \
  && grep -q '! .*generated' "$TMP/out.txt"; } \
  && ok "S21-LC-G1 a line citation into a generated note warns, unless it carries an anchor" || bad "S21-LC-G1 generated" "rc=$rc got=$got"

# S21-LC-G2: a malformed generated list is refused by both tools (exit 2, naming the key); a negated glob as negation.
for v in '"registers/**"' '[3]' '["!x.md"]'; do
  B="$TMP/g2"; rm -rf "$B"; mkbundle "$B"; printf 'okf_check:\n  verify:\n    generated: %s\n' "$v" > "$B/okf-base.yaml"
  rc=$(run "$B"); "$VERIFY" "$B" --check-config > "$TMP/g2c.txt" 2>&1; rcc=$?
  { [ "$rc" = 2 ] && [ "$rcc" = 2 ] && grep -q 'okf_check.verify.generated' "$TMP/g2c.txt"; } \
    && ok "S21-LC-G2 generated: $v is refused (exit 2, names okf_check.verify.generated)" || bad "S21-LC-G2 generated: $v" "rc=$rc rcc=$rcc $(head -1 "$TMP/g2c.txt")"
done
grep -q 'negation' "$TMP/g2c.txt" && ok "S21-LC-G2b a negated generated glob is refused as negation" || bad "S21-LC-G2b negation" "$(head -1 "$TMP/g2c.txt")"

section "review fixes (0.9.34)"
# S21-LC-R1 (review B1): a symlink in the bundle that points outside it (a note or a folder) is not followed: its target is
# outside the bundle and the searched repositories, so the citation is UNRESOLVED and nothing of the target is read. Before,
# an anchor turned CONFIRMED / REFUTED into an oracle on the target's text (a link to /proc/self/environ).
mkdir -p "$TMP/r1out"; printf 'HOME=/root\nTOKEN=s3cret\nthird\n' > "$TMP/r1out/creds.md"
B="$TMP/r1"; mkbundle "$B"; ln -s "$TMP/r1out/creds.md" "$B/env.md"; ln -s "$TMP/r1out" "$B/link"
note "$B/a.md" 'env:1 "HOME=/root", env.md:2 "TOKEN=nope" and link/creds.md:3'
rc=$(runjson "$B"); got=$(lineres); run "$B" >/dev/null
{ [ "$rc" = 0 ] && [ "$got" = '[["env.md:2", "UNRESOLVED"], ["link/creds.md:3", "UNRESOLVED"], ["env:1", "UNRESOLVED"]]' ] && [ "$(grep -c 'outside the bundle' "$TMP/out.txt")" = 3 ]; } \
  && ok "S21-LC-R1 a symlink to a file or folder outside the bundle is not followed (UNRESOLVED, not read)" || bad "S21-LC-R1 symlink escape" "rc=$rc got=$got"

# S21-LC-R2 (review B2): --since compares only a citation the note already had at the ref. A branch that moves the text AND
# corrects the citation (d.md:3 -> d.md:4) is CONFIRMED, not MOVED.
B="$TMP/r2"; mkbundle "$B"; git init -q "$B"; docfile "$B/d.md" "a" "b" "KEY line" "c"; note "$B/a.md" "See d.md:3."
gitc "$B" add -A; gitc "$B" commit -qm base; docfile "$B/d.md" "new" "a" "b" "KEY line" "c"; note "$B/a.md" "See d.md:4."
rc=$(runjson "$B" --since HEAD); got=$(warns)
{ [ "$rc" = 0 ] && [ "$got" = '[["d.md:4", "CONFIRMED", null, false]]' ]; } && ok "S21-LC-R2 --since leaves a citation the branch already corrected alone" || bad "S21-LC-R2 corrected" "rc=$rc got=$got"

# S21-LC-R3 (review S1): a path that is the end of a bundle note AND a document of a searched repository is ambiguous:
# UNRESOLVED, never a REFUTED against the wrong file.
B="$TMP/r3"; mkbundle "$B"; lines "$B/notes/docs/guide.md" 2; R="$TMP/r3repo"; mkdir -p "$R/docs"; git init -q "$R"; lines "$R/docs/guide.md" 50
note "$B/a.md" "docs/guide.md:40"
rc=$(runjson "$B" --repo "$R"); got=$(lineres)
{ [ "$rc" = 0 ] && [ "$got" = '[["docs/guide.md:40", "UNRESOLVED"]]' ]; } && ok "S21-LC-R3 a bundle suffix match and a repo document for one path is ambiguous (UNRESOLVED)" || bad "S21-LC-R3 ambiguity" "rc=$rc got=$got"

# S21-LC-R4 (review S2, S3): an anchor whose text wraps over two lines is found (MOVED to where it starts); two anchors on the
# same citation are two claims.
B="$TMP/r4"; mkbundle "$B"; docfile "$B/d.md" "a" "b" "c" "we roll out shadow then" "canary and full" "e"
note "$B/a.md" 'd.md:1 "shadow then canary" and d.md:2 "b" and d.md:2 "zzz"'
rc=$(runjson "$B"); got=$(lineall)
{ [ "$rc" = 1 ] && [ "$got" = '[["d.md:1", "MOVED", "4"], ["d.md:2", "CONFIRMED", null], ["d.md:2", "REFUTED", null]]' ]; } \
  && ok "S21-LC-R4 a wrapped anchor is found where it starts; two anchors on one citation are both checked" || bad "S21-LC-R4 anchors" "rc=$rc got=$got"

# S21-LC-R5 (review S4): a long line (a 20 KB inline image) in a note with no claim does not slow the citation hint down.
B="$TMP/r5"; mkbundle "$B"; note "$B/a.md" "![x](data:image/png;base64,$("$REALPY" -c 'print("iVBORw0KGgo" * 2000)'))"
note "$B/b.md" "$("$REALPY" -c 'print(",a" * 3000)')"
t0=$(date +%s); rc=$(run "$B"); dt=$(( $(date +%s) - t0 ))
{ [ "$rc" = 0 ] && [ "$dt" -lt 10 ]; } && ok "S21-LC-R5 a 20 KB line and a 6 KB comma list take ${dt} s, not minutes" || bad "S21-LC-R5 slow scan" "rc=$rc dt=$dt"

# S21-LC-R6 (review S5): --since works when the bundle is reached through a symlinked folder.
B="$TMP/r6"; mkbundle "$B"; git init -q "$B"; docfile "$B/d.md" "a" "KEY" "b"; note "$B/a.md" "d.md:2"; gitc "$B" add -A; gitc "$B" commit -qm base
docfile "$B/d.md" "x" "a" "KEY" "b"; ln -s "$B" "$TMP/r6link"
rc=$(runjson "$TMP/r6link" --since HEAD); got=$(warns)
{ [ "$rc" = 1 ] && [ "$got" = '[["d.md:2", "MOVED", "3", false]]' ]; } && ok "S21-LC-R6 --since through a symlinked bundle path still compares" || bad "S21-LC-R6 symlinked path" "rc=$rc got=$got"

# S21-LC-R7 (review nit): a generated glob padded with spaces matches, as .okfignore trims its lines.
B="$TMP/r7"; mkbundle "$B"; printf 'okf_check:\n  verify:\n    generated: ["  registers/**  "]\n' > "$B/okf-base.yaml"; docfile "$B/registers/r.md" "a"; note "$B/a.md" "registers/r.md:1"
rc=$(runjson "$B"); got=$(warns)
{ [ "$rc" = 0 ] && [ "$got" = '[["registers/r.md:1", "CONFIRMED", null, true]]' ]; } && ok "S21-LC-R7 a padded generated glob matches" || bad "S21-LC-R7 trim" "rc=$rc got=$got"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
