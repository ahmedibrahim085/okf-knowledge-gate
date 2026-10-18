#!/usr/bin/env bash
# Tests for okf-export (an Obsidian-style vault folder -> a conformant OKF bundle).
#
# Every case drives the real command at its only seam, `okf-export <vault> <out>`, and reads the
# effect where a user would: the files in <out>, the exit code, and the report. Fixture vaults are
# built under a temp dir; nothing is ever written into a real vault.
#
# Case ids (S10-*) are the use cases in docs/0.9.x-cases.md and the scenarios in
# docs/gherkin/s10-vault-export.feature.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
EXPORT="$HERE/okf-export"
CHECK="$HERE/okf-check"
REALPY=$(command -v python3)
PASS=0; FAIL=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfexport)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

# note <vault> <rel-path> <body>: a note whose frontmatter carries every field L1 recommends, so a
# warning from okf-check on the exported bundle can only come from the export itself.
note() {
  mkdir -p "$(dirname "$1/$2")"
  name=$(basename "$2" .md)
  printf -- '---\ntype: Note\ntitle: %s\ndescription: The %s note.\ntags: [fixture]\ngenerated:\n  by: process:fixture\n  at: 2026-01-01\n---\n%s\n' \
    "$name" "$name" "$3" > "$1/$2"
}
# run <vault> <out>: run the export; the exit code is printed, the report lands in $TMP/out.txt.
run() { "$EXPORT" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }

# --- S10-H1: wikilinks become relative links ----------------------------------------------------
V="$TMP/h1/vault"; O="$TMP/h1/out"
note "$V" a.md "# A"
note "$V" b.md "See [[a]] for more."
rc=$(run "$V" "$O")
grep -qF 'See [a](a.md) for more.' "$O/b.md" 2>/dev/null \
  && ok "S10-H1a [[a]] becomes [a](a.md) (exit $rc)" \
  || bad "S10-H1a [[a]] becomes a relative link" "rc=$rc b.md: $(grep -n 'See' "$O/b.md" 2>&1 | head -1)"

V="$TMP/h1b/vault"; O="$TMP/h1b/out"
note "$V" a.md "# A"
note "$V" b.md "Read [[a|the A note]] first."
rc=$(run "$V" "$O")
grep -qF 'Read [the A note](a.md) first.' "$O/b.md" 2>/dev/null \
  && ok "S10-H1b [[a|alias]] becomes [alias](a.md)" \
  || bad "S10-H1b alias" "rc=$rc b.md: $(grep -n 'Read' "$O/b.md" 2>&1 | head -1) $(head -3 "$TMP/out.txt")"

# The anchor is the GitHub-style slug of the heading: lower case, punctuation dropped, spaces to '-'.
# The link text is what Obsidian shows for a heading link: "note > heading".
V="$TMP/h1c/vault"; O="$TMP/h1c/out"
note "$V" a.md "# A
## Set-up, then Run!"
note "$V" b.md "Go to [[a#Set-up, then Run!]] now."
rc=$(run "$V" "$O")
grep -qF 'Go to [a > Set-up, then Run!](a.md#set-up-then-run) now.' "$O/b.md" 2>/dev/null \
  && ok "S10-H1c [[a#h]] becomes [a > h](a.md#slug)" \
  || bad "S10-H1c heading" "rc=$rc b.md: $(grep -n 'Go to' "$O/b.md" 2>&1 | head -1) $(head -3 "$TMP/out.txt")"

# [[#h]] points into the same note; its heading is checked like any other.
V="$TMP/h1f/vault"; O="$TMP/h1f/out"
note "$V" b.md "# Intro
Back to [[#Intro]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'Back to [Intro](#intro).' "$O/b.md"; } 2>/dev/null \
  && ok "S10-H1f [[#h]] becomes [h](#slug) within the same note" \
  || bad "S10-H1f same-note heading" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ') b.md: $(grep -n 'Back' "$O/b.md" 2>&1 | head -1)"

# A target with a '/' is a vault-root path; a link out of a sub-folder climbs with '../'.
V="$TMP/h1d/vault"; O="$TMP/h1d/out"
note "$V" a.md "# A"
note "$V" "deep/sub/c.md" "Up to [[a]]."
note "$V" b.md "Down to [[deep/sub/c]]."
rc=$(run "$V" "$O")
{ grep -qF 'Down to [deep/sub/c](deep/sub/c.md).' "$O/b.md" && grep -qF 'Up to [a](../../a.md).' "$O/deep/sub/c.md"; } 2>/dev/null \
  && ok "S10-H1d [[deep/sub/c]] is a vault-root path; [[a]] from deep/sub/ becomes ../../a.md" \
  || bad "S10-H1d paths" "rc=$rc b.md: $(grep -n 'Down' "$O/b.md" 2>&1 | head -1) c.md: $(grep -n 'Up' "$O/deep/sub/c.md" 2>&1 | head -1) $(tail -1 "$TMP/out.txt")"

# S10-H1 acceptance: okf-check (this checkout's) finds nothing to warn about in the exported bundle.
# "My Note" has a space. CommonMark does not read `[x](My Note.md)` as a link at all (a destination
# holds no space unless encoded or in <>), and neither does the L1 link check, so it would pass
# unchecked: the path must be percent-encoded.
V="$TMP/h1acc/vault"; O="$TMP/h1acc/out"
note "$V" "My Note.md" "# My Note
## Part Two"
note "$V" b.md "All forms: [[My Note]], [[sub/c|c]], [[c#C]], [[#B]].
# B
## C"
note "$V" sub/c.md "# C
Back up: [[My Note#Part Two|part two]], [[b]]."
rc=$(run "$V" "$O")
"$CHECK" --json "$O" > "$TMP/check.json" 2>/dev/null
counts=$(tail -1 "$TMP/check.json" | "$REALPY" -c 'import json,sys; d=json.load(sys.stdin); print(d["l1_errors"], d["l1_warnings"], d["concepts"])' 2>&1)
{ [ "$rc" = 0 ] && [ "$counts" = "0 0 3" ] && grep -qF '[My Note](My%20Note.md)' "$O/b.md"; } \
  && ok "S10-H1 acceptance: okf-check <out> reports 0 L1 errors and 0 L1 warnings over 3 concepts; a space is encoded as %20" \
  || bad "S10-H1 acceptance" "export rc=$rc; l1 errors/warnings/concepts: $counts; b.md: $(grep -n 'All forms' "$O/b.md" 2>&1 | head -1); $("$CHECK" "$O" 2>&1 | grep -iE 'warn|error|cross-link' | head -4 | tr '\n' ' ')"

# --- S10-N1: a missing link target or heading is reported --------------------------------------
# A broken link is still conformant (spec 6.1), so the bundle is written; the exit code is what
# lets CI catch it. The unresolved wikilink is left as written, never turned into a guessed path.
V="$TMP/n1/vault"; O="$TMP/n1/out"
note "$V" a.md "# A"
note "$V" b.md "Fine: [[a]].
Broken: [[nope]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qF 'b.md:11: missing target [[nope]]' "$TMP/out.txt" \
  && grep -qF 'Broken: [[nope]].' "$O/b.md" && grep -qF 'Fine: [a](a.md).' "$O/b.md"; } 2>/dev/null \
  && ok "S10-N1a a missing target exits 1, is listed as file:line, stays as written, and the rest is exported" \
  || bad "S10-N1a missing target" "rc=$rc report: $(head -3 "$TMP/out.txt" | tr '\n' ' ') b.md: $(grep -n 'Broken' "$O/b.md" 2>&1 | head -1)"

# The heading exists only inside a code fence, which is not a heading.
V="$TMP/n1b/vault"; O="$TMP/n1b/out"
note "$V" a.md '# A
```
## Ghost
```'
note "$V" b.md "To [[a#Ghost]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qF 'b.md:10: missing heading [[a#Ghost]]' "$TMP/out.txt" && grep -qF 'To [[a#Ghost]].' "$O/b.md"; } 2>/dev/null \
  && ok "S10-N1b a missing heading (one only inside a code fence) exits 1, is listed, and stays as written" \
  || bad "S10-N1b missing heading" "rc=$rc report: $(head -3 "$TMP/out.txt" | tr '\n' ' ') b.md: $(grep -n 'To ' "$O/b.md" 2>&1 | head -1)"

# Two notes share a name: a bare [[x]] could mean either, so it is reported, never guessed.
V="$TMP/n1c/vault"; O="$TMP/n1c/out"
note "$V" one/x.md "# X1"
note "$V" two/x.md "# X2"
note "$V" b.md "Which [[x]]? This one: [[two/x]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qF 'b.md:10: ambiguous target [[x]]: one/x.md, two/x.md' "$TMP/out.txt" \
  && grep -qF 'Which [[x]]? This one: [two/x](two/x.md).' "$O/b.md"; } 2>/dev/null \
  && ok "S10-N1c a bare name two notes share exits 1 and lists both; a path to one of them still converts" \
  || bad "S10-N1c ambiguous" "rc=$rc report: $(head -3 "$TMP/out.txt" | tr '\n' ' ') b.md: $(grep -n 'Which' "$O/b.md" 2>&1 | head -1)"

# --- S10-E1: frontmatter wikilinks are kept unchanged -------------------------------------------
# They are producer keys (spec 4.1: consumers SHOULD preserve unknown keys); note tools read them.
V="$TMP/e1/vault"; O="$TMP/e1/out"
note "$V" a.md "# A"
mkdir -p "$V"
printf -- '---\ntype: Note\nrelated: "[[a]]"\nup:\n  - "[[a|parent]]"\n---\nBody [[a]].\n' > "$V/b.md"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && [ "$(head -6 "$O/b.md")" = "$(head -6 "$V/b.md")" ] && grep -qF 'Body [a](a.md).' "$O/b.md"; } 2>/dev/null \
  && ok "S10-E1 frontmatter wikilinks are byte-for-byte unchanged while the body link is converted" \
  || bad "S10-E1 frontmatter" "rc=$rc out: $(head -7 "$O/b.md" 2>&1 | tr '\n' '|')"

# Code shows wikilink syntax; it is not a link (CommonMark: no links inside code).
V="$TMP/code/vault"; O="$TMP/code/out"
note "$V" a.md "# A"
note "$V" b.md 'Write `[[a]]` to link, or ``[[nope]]``. Real: [[a]].
~~~~
[[a]] in a fence
~~~
still fenced [[nope]]
~~~~'
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'Write `[[a]]` to link, or ``[[nope]]``. Real: [a](a.md).' "$O/b.md" \
  && grep -qxF '[[a]] in a fence' "$O/b.md" && grep -qxF 'still fenced [[nope]]' "$O/b.md"; } 2>/dev/null \
  && ok "S10-H1e wikilinks in code spans and fences (closed only by a long-enough run) stay as written and are not checked" \
  || bad "S10-H1e code" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ') out: $(sed -n '10,15p' "$O/b.md" 2>&1 | tr '\n' '|')"

# An embed `![[x]]` transcludes x; a Markdown link cannot say that, so it stays as written.
V="$TMP/embed/vault"; O="$TMP/embed/out"
note "$V" a.md "# A"
note "$V" b.md "Embed: ![[a]] Link: [[a]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'Embed: ![[a]] Link: [a](a.md).' "$O/b.md"; } 2>/dev/null \
  && ok "S10-E1b an embed ![[a]] stays as written; a link next to it converts" \
  || bad "S10-E1b embed" "rc=$rc b.md: $(grep -n 'Embed' "$O/b.md" 2>&1 | head -1)"

# --- the vault is only read; <out> is never merged into ------------------------------------------
V="$TMP/safe/vault"; O="$TMP/safe/out"
note "$V" a.md "Link [[a]]."
mkdir -p "$O"; echo keep > "$O/existing.txt"
rc=$(run "$V" "$O")
{ [ "$rc" = 2 ] && grep -q 'not empty' "$TMP/out.txt" && [ ! -e "$O/a.md" ] && [ "$(cat "$O/existing.txt")" = keep ]; } \
  && ok "X-1 a non-empty <out> is refused (exit 2) and nothing is written into it" \
  || bad "X-1 non-empty out" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ') out: $(ls "$O" | tr '\n' ' ')"
rc=$(run "$V" "$V/exported")
{ [ "$rc" = 2 ] && grep -q 'inside' "$TMP/out.txt" && [ ! -e "$V/exported" ]; } \
  && ok "X-2 an <out> inside the vault is refused (exit 2) and the vault is not written to" \
  || bad "X-2 out inside vault" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
rc=$(run "$TMP/no-such-vault" "$TMP/safe/out2")
{ [ "$rc" = 2 ] && grep -q 'not a folder' "$TMP/out.txt" && [ ! -e "$TMP/safe/out2" ]; } \
  && ok "X-3 a vault that is not a folder is refused (exit 2) and no <out> is created" \
  || bad "X-3 missing vault" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"

# Note-tool settings (.obsidian) and VCS data (.git) are not knowledge; attachments are copied as-is.
V="$TMP/files/vault"; O="$TMP/files/out"
note "$V" a.md "See [[pic.png]]."
mkdir -p "$V/.obsidian" "$V/.git"; echo '{}' > "$V/.obsidian/workspace.json"; echo ref > "$V/.git/HEAD"; echo x > "$V/.DS_Store"
printf '\211PNG fixture' > "$V/pic.png"
sum() { (cd "$1" && find . -type f -exec cksum {} + | sort); }
before=$(sum "$V")
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && cmp -s "$V/pic.png" "$O/pic.png" && grep -qF 'See [pic.png](pic.png).' "$O/a.md" \
  && [ ! -e "$O/.obsidian" ] && [ ! -e "$O/.git" ] && [ ! -e "$O/.DS_Store" ] && [ "$(sum "$V")" = "$before" ]; } 2>/dev/null \
  && ok "X-4 dot files and folders are skipped, an attachment is copied byte-for-byte and linkable, and the vault is unchanged" \
  || bad "X-4 files" "rc=$rc out: $(cd "$O" 2>/dev/null && find . | tr '\n' ' ') report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"

# A problem line quotes the link text and the file name, both taken from the vault, and a person or Claude reads it.
# Control characters in them (here ESC and BEL) are replaced, as the edit hook does (0.9.13 review).
V="$TMP/ctl/vault"; O="$TMP/ctl/out"
note "$V" "b$(printf '\007').md" "$(printf 'See [[gh\033ost\007]].')"
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -q 'missing target' "$TMP/out.txt" && ! LC_ALL=C grep -q "$(printf '[\001-\010\016-\037\177]')" "$TMP/out.txt" \
  && grep -qF 'b?.md:' "$TMP/out.txt" && grep -qF '[[gh?ost?]]' "$TMP/out.txt"; } \
  && ok "X-5 control characters in a quoted link or file name are replaced by ? in the problem line (exit 1)" \
  || bad "X-5 control characters" "rc=$rc report: $(head -2 "$TMP/out.txt" | od -c | head -4 | tr '\n' ' ')"

# --- 0.9.14 review ---------------------------------------------------------------------------------------------
# X-6 (blocker): a note that is not valid UTF-8 must not stop the export half-way: it is listed, copied as it is, and
# the rest of the vault is written. A heading link into a non-Markdown file (a PDF page link) is not read as text.
V="$TMP/x6/vault"; O="$TMP/x6/out"
note "$V" b.md "# B"
note "$V" c.md "Link [[b]] and a page [[doc.pdf#page=3]]."
printf '%s\n' '---' 'type: Note' 'title: bad' '---' > "$V/bad.md"; printf 'bad \377\376 [[b]]\n' >> "$V/bad.md"
printf '\211PDF fixture \377' > "$V/doc.pdf"
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -q '^bad.md:1: not valid UTF-8' "$TMP/out.txt" && cmp -s "$V/bad.md" "$O/bad.md" \
  && grep -qF 'Link [b](b.md) and a page [doc.pdf > page=3](doc.pdf#page=3).' "$O/c.md" && ! grep -q Traceback "$TMP/out.txt"; } 2>/dev/null \
  && ok "X-6 a non-UTF-8 note is listed and copied unchanged, the rest is exported; a heading link into a PDF is not read as text" \
  || bad "X-6 non-UTF-8 and pdf anchor" "rc=$rc report: $(head -3 "$TMP/out.txt" | tr '\n' '|') c.md: $(grep -n 'Link' "$O/c.md" 2>&1 | head -1)"
# X-7 (blocker): S10-E1 holds for a note that starts with a byte order mark, and a CRLF note keeps its line endings.
V="$TMP/x7/vault"; O="$TMP/x7/out"
note "$V" b.md "# B"
printf '\357\273\277---\ntype: Note\ntitle: bom\nrel: "[[b]]"\n---\nBody [[b]]\n' > "$V/bom.md"
printf -- '---\r\ntype: Note\r\ntitle: crlf\r\nrel: "[[b]]"\r\n---\r\nBody [[b]]\r\n' > "$V/crlf.md"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'rel: "[[b]]"' "$O/bom.md" && [ "$(head -c 3 "$O/bom.md" | od -An -tx1 | tr -d ' \n')" = efbbbf ] && grep -qF 'Body [b](b.md)' "$O/bom.md" \
  && grep -qF 'rel: "[[b]]"' "$O/crlf.md" && [ "$(LC_ALL=C grep -c $'\r$' "$O/crlf.md")" = 6 ] && grep -q 'Body \[b\](b.md)' "$O/crlf.md"; } 2>/dev/null \
  && ok "X-7 a BOM note keeps its BOM and its frontmatter wikilink, a CRLF note keeps every CRLF, bodies are converted" \
  || bad "X-7 BOM and CRLF" "rc=$rc bom: $(od -c "$O/bom.md" 2>&1 | head -3 | tr '\n' ' ') crlf CRs: $(LC_ALL=C grep -c $'\r$' "$O/crlf.md" 2>&1)"
# X-8: Obsidian writes a table-cell alias as [[a\|alias]].
V="$TMP/x8/vault"; O="$TMP/x8/out"
note "$V" a.md "# A"
note "$V" t.md '| col |
|---|
| [[a\|the A note]] |'
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF '| [the A note](a.md) |' "$O/t.md"; } 2>/dev/null \
  && ok "X-8 [[a\\|alias]] in a table cell becomes [alias](a.md)" \
  || bad "X-8 table alias" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') t.md: $(grep -n 'the A' "$O/t.md" 2>&1)"

# X-9 (0.9.14 re-verify): a heading link into a note that starts with a byte order mark and has no frontmatter finds the heading.
V="$TMP/x9/vault"; O="$TMP/x9/out"
note "$V" l.md "See [[h#Top]]."
printf '\357\273\277# Top\nbody\n' > "$V/h.md"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'See [h > Top](h.md#top).' "$O/l.md"; } 2>/dev/null \
  && ok "X-9 a heading in a BOM note without frontmatter is found" \
  || bad "X-9 BOM heading" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
