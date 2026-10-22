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
# lognote <vault> <name> <body>: a vault log note as written, no frontmatter (a spec 9 log has none; 0.9.16 review item 2).
lognote() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
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

# --- S10-H2: a vault index note is renamed and real indexes are generated ------------------------
# Spec 3.1: index.md is reserved for the folder listing and MUST NOT be a concept. A vault's index.md
# is a note, so it becomes the folder note: dir/index.md -> dir/<dir>.md, root -> <vault folder>.md.
V="$TMP/h2/kb"; O="$TMP/h2/out"
note "$V" index.md "Home: see [[a]]."
note "$V" a.md "# A"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'Home: see [a](a.md).' "$O/kb.md" && grep -qF 'title: index' "$O/kb.md" \
  && ! grep -q 'Home' "$O/index.md"; } 2>/dev/null \
  && ok "S10-H2a the vault-root index.md note becomes kb.md (the vault folder's name), content kept, links converted" \
  || bad "S10-H2a root rename" "rc=$rc out: $(cd "$O" 2>/dev/null && ls | tr '\n' ' ') report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"

# A link keeps its vault meaning and points at the new name.
V="$TMP/h2b/kb"; O="$TMP/h2b/out"
note "$V" sub/index.md "Sub home, up to [[a]]."
note "$V" a.md "Go to [[sub/index]] or [[index|the sub home]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'Go to [sub/index](sub/sub.md) or [the sub home](sub/sub.md).' "$O/a.md" \
  && grep -qF 'Sub home, up to [a](../a.md).' "$O/sub/sub.md" && ! grep -q 'Sub home' "$O/sub/index.md"; } 2>/dev/null \
  && ok "S10-H2b sub/index.md becomes sub/sub.md; [[sub/index]] and [[index]] point at it, and its own links still resolve" \
  || bad "S10-H2b nested rename" "rc=$rc a.md: $(grep -n 'Go to' "$O/a.md" 2>&1 | head -1) out: $(cd "$O" 2>/dev/null && find . -type f | tr '\n' ' ') report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"

# Spec 8: every folder that holds a concept, directly or below, gets an index.md with no frontmatter,
# except the root, which carries okf_version (spec 12). Entries carry the concept's title and description.
V="$TMP/h2c/kb"; O="$TMP/h2c/out"
note "$V" a.md "# A"
note "$V" sub/index.md "Sub home."
note "$V" sub/c.md "# C"
note "$V" deep/x/y.md "# Y"
mkdir -p "$V/img"; printf 'PNG' > "$V/img/pic.png"
rc=$(run "$V" "$O")
printf -- '---\nokf_version: "0.2"\n---\n# Concepts\n\n* [a](a.md) - The a note.\n\n# Folders\n\n* [deep](deep/)\n* [sub](sub/)\n' > "$TMP/want_root"
printf -- '# Concepts\n\n* [c](c.md) - The c note.\n* [index](sub.md) - The index note.\n' > "$TMP/want_sub"
printf -- '# Folders\n\n* [x](x/)\n' > "$TMP/want_deep"
{ [ "$rc" = 0 ] && cmp -s "$TMP/want_root" "$O/index.md" && cmp -s "$TMP/want_sub" "$O/sub/index.md" \
  && cmp -s "$TMP/want_deep" "$O/deep/index.md" && grep -qF '* [y](y.md) - The y note.' "$O/deep/x/index.md" \
  && [ ! -e "$O/img/index.md" ]; } 2>/dev/null \
  && ok "S10-H2c indexes are generated per folder: root with okf_version, nested ones without frontmatter, title + description per entry, none for an attachment-only folder" \
  || bad "S10-H2c generated indexes" "rc=$rc root: $(head -12 "$O/index.md" 2>&1 | tr '\n' '|') sub: $(cat "$O/sub/index.md" 2>&1 | tr '\n' '|') report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
"$CHECK" --json "$O" > "$TMP/check.json" 2>/dev/null
counts=$(tail -1 "$TMP/check.json" | "$REALPY" -c 'import json,sys; d=json.load(sys.stdin); print(d["l1_errors"], d["l1_warnings"], d["concepts"])' 2>&1)
[ "$counts" = "0 0 4" ] \
  && ok "S10-H2 acceptance: okf-check <out> on the renamed + indexed bundle reports 0 L1 errors, 0 warnings, 4 concepts" \
  || bad "S10-H2 acceptance" "l1 errors/warnings/concepts: $counts; $("$CHECK" "$O" 2>&1 | grep -iE 'warn|error|index' | head -4 | tr '\n' ' ')"

# The vendored PyYAML is the one used: a yaml module inherited from PYTHONPATH must not outrank the
# pin (plugin/vendor/VENDOR.md). The decoy fails loudly if it is ever imported.
mkdir -p "$TMP/decoy/yaml"; echo 'raise SystemExit("decoy yaml imported")' > "$TMP/decoy/yaml/__init__.py"
O="$TMP/h2c/out-decoy"
rc=$(PYTHONPATH="$TMP/decoy" run "$V" "$O")
{ [ "$rc" = 0 ] && cmp -s "$TMP/want_sub" "$O/sub/index.md"; } 2>/dev/null \
  && ok "S10-H2d a decoy yaml on PYTHONPATH is not imported: the vendored PyYAML wins and the index is the same" \
  || bad "S10-H2d vendored yaml" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"

# --- S10-H3: dated history lines produce a log ---------------------------------------------------
# Spec 3.1 reserves log.md, so the vault's own log.md note is the history (lead decision).
# Both dated forms, written out of order; spec 9 wants date groups, newest first, no frontmatter. The vault log's own
# title is kept (0.9.16 review item 5).
V="$TMP/h3/kb"; O="$TMP/h3/out"
note "$V" a.md "# A"
lognote "$V" log.md "# History
- 2026-05-15: Started.
## 2026-05-22
* **Update**: Added [[a]].
- 2026-05-15: Second, same day."
rc=$(run "$V" "$O")
printf -- '# History\n\n## 2026-05-22\n* **Update**: Added [a](a.md).\n\n## 2026-05-15\n* Started.\n* Second, same day.\n' > "$TMP/want_log"
{ [ "$rc" = 0 ] && cmp -s "$TMP/want_log" "$O/log.md" && ! grep -q 'log' "$O/index.md"; } 2>/dev/null \
  && ok "S10-H3a a vault log.md becomes a spec 9 log: date groups newest first, items and headings both read, links converted, not indexed" \
  || bad "S10-H3a log" "rc=$rc log: $(cat "$O/log.md" 2>&1 | tr '\n' '|') index: $(grep -n log "$O/index.md" 2>&1 | head -1) report: $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
"$CHECK" --json "$O" > "$TMP/check.json" 2>/dev/null
counts=$(tail -1 "$TMP/check.json" | "$REALPY" -c 'import json,sys; d=json.load(sys.stdin); print(d["l1_errors"], d["l1_warnings"], d["concepts"])' 2>&1)
[ "$counts" = "0 0 1" ] \
  && ok "S10-H3 acceptance: okf-check <out> with the generated log reports 0 L1 errors, 0 warnings, 1 concept (the log is not a concept)" \
  || bad "S10-H3 acceptance" "l1 errors/warnings/concepts: $counts; $("$CHECK" "$O" 2>&1 | grep -iE 'warn|error|log' | head -4 | tr '\n' ' ')"

# No history, no log: a vault without log.md gets none.
O="$TMP/h3/out-none"; mkdir -p "$TMP/h3/nolog"; note "$TMP/h3/nolog" a.md "# A"
rc=$(run "$TMP/h3/nolog" "$O")
{ [ "$rc" = 0 ] && [ -f "$O/index.md" ] && [ ! -e "$O/log.md" ]; } \
  && ok "S10-H3b a vault with no log.md gets no log (and still gets its index)" \
  || bad "S10-H3b no log" "rc=$rc out: $(cd "$O" 2>/dev/null && ls | tr '\n' ' ')"

# A date that is not ISO YYYY-MM-DD or not a real day, and a line under no date, are listed; the
# lines under a rejected date heading are covered by its report; good entries still make the log.
V="$TMP/n3/kb"; O="$TMP/n3/out"
lognote "$V" log.md "# History
stray text
## 2026/05/22
* under a bad heading
- 2026-02-30: not a day
- 2026-05-01: kept"
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qxF 'log.md:2: line belongs to no date: stray text' "$TMP/out.txt" \
  && grep -qxF 'log.md:3: heading 2026/05/22 is not an ISO YYYY-MM-DD date (1 line under it left out)' "$TMP/out.txt" \
  && grep -qxF 'log.md:5: date 2026-02-30 is not an ISO YYYY-MM-DD day' "$TMP/out.txt" \
  && [ "$(wc -l < "$TMP/out.txt" | tr -d ' ')" = 3 ] \
  && [ "$(cat "$O/log.md")" = "$(printf '# History\n\n## 2026-05-01\n* kept')" ]; } 2>/dev/null \
  && ok "S10-N3 a non-ISO date, an impossible day and an undated line are listed as file:line (exit 1); the valid entry still makes the log" \
  || bad "S10-N3 malformed" "rc=$rc report: $(cat "$TMP/out.txt" | tr '\n' '|') log: $(cat "$O/log.md" 2>&1 | tr '\n' '|')"

# --- S10-E2: a rename collision stops the export -------------------------------------------------
V="$TMP/e2/kb"; O="$TMP/e2/out"
note "$V" sub/index.md "Sub home."
note "$V" sub/sub.md "Already here."
note "$V" a.md "# A"
rc=$(run "$V" "$O")
{ [ "$rc" = 2 ] && grep -qF 'sub/index.md' "$TMP/out.txt" && grep -qF 'sub/sub.md' "$TMP/out.txt" && [ ! -e "$O" ]; } \
  && ok "S10-E2 sub/index.md -> sub/sub.md when sub/sub.md exists stops the export (exit 2), names both, writes nothing" \
  || bad "S10-E2 collision" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' ' ') out: $(cd "$O" 2>/dev/null && find . -type f | tr '\n' ' ')"

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
# The same for an exit-2 message that names vault files: the index rename collision (S10-E2) quotes both paths.
V="$TMP/ctl2/vault"; O="$TMP/ctl2/out"; D="d$(printf '\007')"
note "$V" "$D/index.md" "# I"; note "$V" "$D/$D.md" "# D"
rc=$(run "$V" "$O")
{ [ "$rc" = 2 ] && grep -q 'already exists' "$TMP/out.txt" && ! LC_ALL=C grep -q "$(printf '[\001-\010\016-\037\177]')" "$TMP/out.txt" \
  && grep -qF 'd?/index.md' "$TMP/out.txt"; } \
  && ok "X-10 control characters in the file names of an exit-2 message (rename collision) are replaced by ?" \
  || bad "X-10 control characters, exit 2" "rc=$rc report: $(head -2 "$TMP/out.txt" | od -c | head -4 | tr '\n' ' ')"
# X-11 (on 0.9.14): the generated index reads each note's title as the validator does. A BOM note is listed under
# its title; a note that is not valid UTF-8 (copied unchanged, X-6) is listed under its file name, not a crash.
V="$TMP/x11/vault"; O="$TMP/x11/out"
mkdir -p "$V"; printf '\357\273\277---\ntype: Note\ntitle: Bom Title\ndescription: With a BOM.\n---\nbody\n' > "$V/bom.md"
printf '%s\n' '---' 'type: Note' 'title: bad' '---' > "$V/bad.md"; printf 'bad \377\376\n' >> "$V/bad.md"
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qxF '* [Bom Title](bom.md) - With a BOM.' "$O/index.md" && grep -qxF '* [bad](bad.md)' "$O/index.md" \
  && ! grep -q Traceback "$TMP/out.txt"; } 2>/dev/null \
  && ok "X-11 the index lists a BOM note under its title and a non-UTF-8 note under its file name (no crash)" \
  || bad "X-11 index of BOM and non-UTF-8 notes" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') index: $(grep -n '^\*' "$O/index.md" 2>&1 | tr '\n' '|')"

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
# And for the log problems: an undated line is quoted in full.
V="$TMP/ctl3/kb"; O="$TMP/ctl3/out"
lognote "$V" log.md "$(printf '# History\nstray\033[2Jtext\n- 2026-05-01: kept')"
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qF 'line belongs to no date: stray?[2Jtext' "$TMP/out.txt" \
  && ! LC_ALL=C grep -q "$(printf '[\001-\010\016-\037\177]')" "$TMP/out.txt"; } \
  && ok "X-16 control characters in a quoted log line are replaced by ? in the problem line (exit 1)" \
  || bad "X-16 control characters, log" "rc=$rc report: $(head -2 "$TMP/out.txt" | od -c | head -4 | tr '\n' ' ')"
# X-17 (on 0.9.14): a log note is read as written (0.9.14 keeps a BOM and CRLF), so its BOM must not make its title
# line an undated line, and a CRLF entry is still an entry.
V="$TMP/x17/kb"; O="$TMP/x17/out"
mkdir -p "$V"; printf '\357\273\277# History\r\n- 2026-05-01: kept\r\n' > "$V/log.md"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ] && grep -qx '## 2026-05-01' "$O/log.md" && grep -qx '\* kept' "$O/log.md"; } 2>/dev/null \
  && ok "X-17 a log note with a BOM and CRLF line ends becomes the spec 9 log with no problem (exit 0)" \
  || bad "X-17 BOM and CRLF log" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') log: $(od -c "$O/log.md" 2>&1 | head -3 | tr '\n' ' ')"

# --- 0.9.15 review ---------------------------------------------------------------------------------------------
# X-12 (blocker): the rename clash check compares names the way the file system does. On a case-insensitive disk (macOS
# APFS, Windows) dir/Dir.md IS dir/dir.md, so the export must stop, name both files and write nothing.
V="$TMP/x12/vault"; O="$TMP/x12/out"
note "$V" dir/index.md "IDX"; note "$V" dir/Dir.md "DIRNOTE"
rc=$(run "$V" "$O")
{ [ "$rc" = 2 ] && grep -q 'dir/index.md would be renamed to dir/dir.md' "$TMP/out.txt" && [ ! -e "$O" ]; } \
  && ok "X-12 a rename onto a note that differs only in case stops the export (exit 2, both named, nothing written)" \
  || bad "X-12 case clash" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(ls "$O" 2>&1 | head -2 | tr '\n' ' ')"
# X-13 (blocker): a vault note named Index.md is the reserved file on a case-insensitive disk; it becomes the folder note too.
V="$TMP/x13/vault"; O="$TMP/x13/out"
note "$V" Index.md "CAPINDEX"; note "$V" o.md "other"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -q CAPINDEX "$O/vault.md" 2>/dev/null && ! grep -q 'CAPINDEX' "$O/index.md"; } \
  && ok "X-13 a note named Index.md is renamed to the folder note, not overwritten by the generated index" \
  || bad "X-13 capital Index.md" "rc=$rc out: $(ls "$O" 2>&1 | tr '\n' ' ') report: $(head -2 "$TMP/out.txt" | tr '\n' '|')"
# X-14 (blocker): a title or folder name can hold line breaks, brackets and control characters; the index line stays ONE
# well-formed Markdown link line.
V="$TMP/x14/vault"; O="$TMP/x14/out"; mkdir -p "$V/fo[ld]er"
printf -- '---\ntype: Note\ntitle: |\n  multi\n  * [inj](x.md)\ndescription: d\n---\nb\n' > "$V/multi.md"
printf -- '---\ntype: Note\ntitle: "Evil ] (x) and \\e[31mred\\a"\ndescription: d\n---\nb\n' > "$V/evil.md"
note "$V" "fo[ld]er/n.md" "n"
rc=$(run "$V" "$O")
lines=$(grep -c '^\* \[' "$O/index.md" 2>/dev/null)
{ [ "$rc" = 0 ] && grep -qF '* [multi * \[inj\](x.md)](multi.md) - d' "$O/index.md" && grep -qF '* [Evil \] (x) and ?\[31mred?](evil.md) - d' "$O/index.md" \
  && grep -qF '* [fo\[ld\]er](fo%5Bld%5Der/)' "$O/index.md" && ! LC_ALL=C grep -q "$(printf '[\001-\010\016-\037\177]')" "$O/index.md"; } \
  && ok "X-14 a block-scalar title, brackets and control characters in a title or folder name stay one escaped link line" \
  || bad "X-14 index line injection" "rc=$rc index: $(cat "$O/index.md" 2>&1 | tr '\n' '|' | cut -c1-300)"
# X-15 (low): a folder named index leaves no name for its folder note; say so instead of 'renamed to itself'.
V="$TMP/x15/vault"; O="$TMP/x15/out"
note "$V" index/index.md "X"
rc=$(run "$V" "$O")
{ [ "$rc" = 2 ] && grep -q 'rename the folder' "$TMP/out.txt"; } \
  && ok "X-15 a folder named index is refused with a message that says to rename the folder" \
  || bad "X-15 folder named index" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

# --- on 0.9.15: the log file follows the same name and text rules ---------------------------------------
# X-18: log.md is reserved whatever its case (a case-insensitive disk reads Log.md as log.md). Log.md becomes the spec 9
# log written as log.md, and the index does not list it as a concept.
V="$TMP/x18/kb"; O="$TMP/x18/out"
note "$V" a.md "# A"
lognote "$V" Log.md "# History
- 2026-05-01: kept"
rc=$(run "$V" "$O")
names=$(cd "$O" 2>/dev/null && "$REALPY" -c 'import os; print(" ".join(sorted(os.listdir("."))))')
{ [ "$rc" = 0 ] && [ "$names" = "a.md index.md log.md" ] && grep -qx '## 2026-05-01' "$O/log.md" \
  && ! grep -qi 'log' "$O/index.md"; } 2>/dev/null \
  && ok "X-18 a vault note named Log.md becomes the spec 9 log, written as log.md and not listed in the index" \
  || bad "X-18 Log.md" "rc=$rc out: $names report: $(head -2 "$TMP/out.txt" | tr '\n' '|') index: $(grep -n '^\*' "$O/index.md" 2>&1 | tr '\n' '|')"
# X-19: on a case-sensitive disk a vault can hold log.md and Log.md; both become log.md, so the export stops (exit 2)
# before writing anything, as for an index rename clash. A case-insensitive disk cannot hold both: SKIP there.
V="$TMP/x19/kb"; O="$TMP/x19/out"; P="$TMP/x19/probe"; mkdir -p "$V" "$P"
printf x > "$P/case-probe"; if [ -e "$P/CASE-PROBE" ]; then
  printf '  SKIP  X-19 log.md and Log.md in one folder: this disk is case-insensitive (runs on the Debian gate)\n'
else
  lognote "$V" log.md "- 2026-05-01: one"; lognote "$V" Log.md "- 2026-05-02: two"
  rc=$(run "$V" "$O")
  { [ "$rc" = 2 ] && grep -q 'Log.md' "$TMP/out.txt" && grep -q 'log.md' "$TMP/out.txt" && [ ! -e "$O/log.md" ]; } \
    && ok "X-19 log.md and Log.md in one folder stop the export (exit 2) before anything is written" \
    || bad "X-19 log name clash" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(ls "$O" 2>&1 | tr '\n' ' ')"
fi
# X-20: the spec 9 log is read by people and agents: control characters in a log entry become "?", as in problem lines.
V="$TMP/x20/kb"; O="$TMP/x20/out"
lognote "$V" log.md "$(printf '# History\n- 2026-05-01: a\033b\n## 2026-05-02\nc\007d')"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qxF '* a?b' "$O/log.md" && grep -qxF 'c?d' "$O/log.md" \
  && ! LC_ALL=C grep -q "$(printf '[\001-\010\016-\037\177]')" "$O/log.md"; } 2>/dev/null \
  && ok "X-20 control characters in log entries become ? in the spec 9 log" \
  || bad "X-20 log control characters" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') log: $(od -c "$O/log.md" 2>&1 | head -4 | tr '\n' ' ')"
# X-21: a date in brackets is not a date line (Obsidian writes a daily-note link as [[2026-05-03]]): it is reported as a
# line under no date, not dropped; brackets inside an entry's text are kept as written.
V="$TMP/x21/kb"; O="$TMP/x21/out"
lognote "$V" log.md "- [2026-05-03]: bracketed
- 2026-05-01: see [x] and [y](z)"
rc=$(run "$V" "$O")
{ [ "$rc" = 1 ] && grep -qF 'log.md:1: line belongs to no date: - [2026-05-03]: bracketed' "$TMP/out.txt" \
  && grep -qxF '* see [x] and [y](z)' "$O/log.md"; } 2>/dev/null \
  && ok "X-21 a bracketed date is reported as a line under no date (exit 1); brackets in an entry are kept" \
  || bad "X-21 brackets" "rc=$rc report: $(head -3 "$TMP/out.txt" | tr '\n' '|') log: $(cat "$O/log.md" 2>&1 | tr '\n' '|')"

# --- 0.9.16 review round 1: the log reader (lead's design, items 1-8) ------------------------------------------
# logrun <vault> <out>: the export, then the spec 9 log it wrote (or "<no log>") in $TMP/log.txt.
logrun() { rc=$(run "$1" "$2"); cat "$2/log.md" > "$TMP/log.txt" 2>/dev/null || echo '<no log>' > "$TMP/log.txt"; }
l1() { "$CHECK" --json "$1" 2>/dev/null | tail -1 | "$REALPY" -c 'import json,sys; d=json.load(sys.stdin); print(d["l1_errors"], d["l1_warnings"])' 2>&1; }
# X-22 (item 1, HIGH): a level-2 heading that is not an ISO date is reported and its lines are left out, not filed under
# the previous date; a level-3 heading stays entry text; the log passes the validator's check_log.
V="$TMP/x22/kb"; O="$TMP/x22/out"; note "$V" a.md "# A"
lognote "$V" log.md "# History
## 2026-05-01
* first
## Notes
note line
### Sub
## 2026-05-22T10:00
after
## 2026-05-02
### Sub heading
text"
logrun "$V" "$O"
printf '# History\n\n## 2026-05-02\n### Sub heading\ntext\n\n## 2026-05-01\n* first\n' > "$TMP/want"
{ [ "$rc" = 1 ] && grep -qF 'log.md:4: heading Notes is not an ISO YYYY-MM-DD date' "$TMP/out.txt" \
  && grep -qF 'log.md:7: heading 2026-05-22T10:00 is not an ISO YYYY-MM-DD date' "$TMP/out.txt" \
  && cmp -s "$TMP/want" "$TMP/log.txt" && [ "$(l1 "$O")" = "0 0" ]; } 2>/dev/null \
  && ok "X-22 a non-date ## heading is reported and its lines left out, ### stays text, and the log passes check_log (0 L1 errors, 0 warnings)" \
  || bad "X-22 non-date level-2 heading" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt") log: $(tr '\n' '|' < "$TMP/log.txt") l1: $(l1 "$O")"
# X-23 (item 2, HIGH): frontmatter in the vault log is reported, and the rest of the log is still exported.
V="$TMP/x23/kb"; O="$TMP/x23/out"
note "$V" log.md "- 2026-05-01: kept"
logrun "$V" "$O"
{ [ "$rc" = 1 ] && grep -qxF 'log.md:1: frontmatter dropped, a spec log has none' "$TMP/out.txt" \
  && [ "$(cat "$TMP/log.txt")" = "$(printf '# Log\n\n## 2026-05-01\n* kept')" ]; } 2>/dev/null \
  && ok "X-23 frontmatter in the vault log is reported (exit 1) and the dated entries are still exported" \
  || bad "X-23 log frontmatter" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt") log: $(tr '\n' '|' < "$TMP/log.txt")"
# X-24 (item 3, HIGH): an indented line after a dated item continues that item, on the item's day, until the next
# item, heading or unindented line; with no heading above it, it is not "a line under no date".
V="$TMP/x24/kb"; O="$TMP/x24/out"
lognote "$V" log.md "- 2026-05-04: top
  more
## 2026-05-01
- 2026-05-03: item
  continuation
    deeper
back at heading day"
logrun "$V" "$O"
printf '# Log\n\n## 2026-05-04\n* top\n  more\n\n## 2026-05-03\n* item\n  continuation\n    deeper\n\n## 2026-05-01\nback at heading day\n' > "$TMP/want"
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ] && cmp -s "$TMP/want" "$TMP/log.txt"; } 2>/dev/null \
  && ok "X-24 an indented continuation stays with its dated item's day (exit 0)" \
  || bad "X-24 item continuation" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt") log: $(tr '\n' '|' < "$TMP/log.txt")"
# X-25 (item 4, MEDIUM): the whole date-like token is read, so a malformed date is reported, never split into a date
# and text.
V="$TMP/x25/kb"; O="$TMP/x25/out"
lognote "$V" log.md "- 2026-05-221: x
- 2026-05-22T10:00 y
- 2026-05-01-extra
- 2026-05-02: ok"
logrun "$V" "$O"
{ [ "$rc" = 1 ] && grep -qxF 'log.md:1: date 2026-05-221 is not an ISO YYYY-MM-DD day' "$TMP/out.txt" \
  && grep -qxF 'log.md:2: date 2026-05-22T10 is not an ISO YYYY-MM-DD day' "$TMP/out.txt" \
  && grep -qxF 'log.md:3: date 2026-05-01-extra is not an ISO YYYY-MM-DD day' "$TMP/out.txt" \
  && [ "$(cat "$TMP/log.txt")" = "$(printf '# Log\n\n## 2026-05-02\n* ok')" ]; } 2>/dev/null \
  && ok "X-25 a malformed item date (2026-05-221, 2026-05-22T10:00, 2026-05-01-extra) is reported whole, not split" \
  || bad "X-25 malformed item date" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt") log: $(tr '\n' '|' < "$TMP/log.txt")"
# X-26 (item 5, MEDIUM): the vault log's own title is kept, so a link to it ([[#History]]) still has its target.
V="$TMP/x26/kb"; O="$TMP/x26/out"; note "$V" a.md "# A"
lognote "$V" log.md "# History
## 2026-05-01
* see [[#History]]"
logrun "$V" "$O"
{ [ "$rc" = 0 ] && [ "$(head -1 "$TMP/log.txt")" = '# History' ] && grep -qxF '* see [History](#history)' "$TMP/log.txt" \
  && [ "$(l1 "$O")" = "0 0" ]; } 2>/dev/null \
  && ok "X-26 the vault log's # title is the log's title, so [[#History]] keeps its target; the validator accepts it" \
  || bad "X-26 log title" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt") log: $(tr '\n' '|' < "$TMP/log.txt") l1: $(l1 "$O")"
# X-27 (item 6, MEDIUM): a blank line inside a day is kept (one, however many were written), so a second paragraph is
# not joined onto a list item; blank lines at the end of a day are dropped.
V="$TMP/x27/kb"; O="$TMP/x27/out"
lognote "$V" log.md "## 2026-05-01
- 2026-05-01: item

second paragraph


third

"
logrun "$V" "$O"
printf '# Log\n\n## 2026-05-01\n* item\n\nsecond paragraph\n\nthird\n' > "$TMP/want"
{ [ "$rc" = 0 ] && cmp -s "$TMP/want" "$TMP/log.txt"; } 2>/dev/null \
  && ok "X-27 one blank line between kept lines of a day is kept, extra and trailing blank lines are not" \
  || bad "X-27 blank lines" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt") log: $(od -c "$TMP/log.txt" | head -5 | tr '\n' ' ')"
# X-28 (item 7, LOW): the report for a rejected date heading says how many lines under it were left out.
V="$TMP/x28/kb"; O="$TMP/x28/out"
lognote "$V" log.md "## Misc
* one
## 2026/05/22
* a
* b

## 2026-05-01
* kept"
logrun "$V" "$O"
{ [ "$rc" = 1 ] && grep -qxF 'log.md:1: heading Misc is not an ISO YYYY-MM-DD date (1 line under it left out)' "$TMP/out.txt" \
  && grep -qxF 'log.md:3: heading 2026/05/22 is not an ISO YYYY-MM-DD date (2 lines under it left out)' "$TMP/out.txt"; } 2>/dev/null \
  && ok "X-28 a rejected heading's report counts the lines left out under it (1 line, 2 lines)" \
  || bad "X-28 left-out count" "rc=$rc report: $(tr '\n' '|' < "$TMP/out.txt")"
# X-29 (item 8, LOW): a log with no dated entry is reported (exit 1), so a [[log]] link pointing at nothing is not silent.
r29=""
for body in "" "# History" "# History
## 2026-05-01"; do
  V="$TMP/x29/kb"; O="$TMP/x29/out"; rm -rf "$TMP/x29"; lognote "$V" log.md "$body"
  logrun "$V" "$O"
  { [ "$rc" = 1 ] && grep -qxF 'log.md:1: no dated entry, no log written' "$TMP/out.txt" && [ ! -e "$O/log.md" ]; } \
    || r29="$r29 [$(printf '%s' "$body" | tr '\n' '/'): rc=$rc $(tr '\n' '|' < "$TMP/out.txt")]"
done
[ -z "$r29" ] && ok "X-29 an empty log, a title only and headings only are reported as no dated entry (exit 1), no log written" \
  || bad "X-29 no dated entry" "$r29"

# --- S10-CL: two inputs that map to one output name ----------------------------------------
# Index.md and index.md can share a folder only on a case-sensitive disk; both become <folder>.md, so the second
# write used to replace the first in silence. The unit cases (CL-U*) hand the command's own path rule an in-memory
# file list, so they run on every disk; the CL-C* cases build the real vault and SKIP where the disk cannot hold it.
# shared <root-name> <vault-relative file>...: the (first, second, output) triples okf-export refuses, one per line.
shared() {
  "$REALPY" - "$EXPORT" "$@" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
for a, b, out in mod.shared_outputs(sorted(Path(p) for p in sys.argv[3:]), sys.argv[2]):
    print(f"{a.as_posix()}|{b.as_posix()}|{out.as_posix()}")
PY
}
got=$(shared kb foo/Index.md foo/index.md)
[ "$got" = "foo/Index.md|foo/index.md|foo/foo.md" ] \
  && ok "S10-CL-U1 foo/Index.md and foo/index.md both map to foo/foo.md and are reported as a pair" \
  || bad "S10-CL-U1 pair" "got: $(printf '%s' "$got" | tail -1)"
got=$(shared kb Index.md index.md a.md)
[ "$got" = "Index.md|index.md|kb.md" ] \
  && ok "S10-CL-U2 root-level Index.md and index.md both map to the vault folder's name (kb.md)" \
  || bad "S10-CL-U2 root pair" "got: $(printf '%s' "$got" | tail -1)"
got=$(shared kb foo/INDEX.md foo/Index.md foo/index.md)
[ "$got" = "foo/INDEX.md|foo/Index.md|foo/foo.md" ] \
  && ok "S10-CL-U3 a three-way clash is one line that names the first two files" \
  || bad "S10-CL-U3 three-way" "got: $(printf '%s' "$got" | tr '\n' ' ')"
got=$(shared kb a/index.md A/index.md)
[ -z "$got" ] \
  && ok "S10-CL-U4 index.md in a/ and in A/ (a/a.md, A/A.md) do not clash" \
  || bad "S10-CL-U4 different folders" "got: $(printf '%s' "$got" | tr '\n' ' ')"
got=$(shared kb a.md A.md foo/index.md foo/foo2.md log.md)
[ -z "$got" ] \
  && ok "S10-CL-U5 a vault with no shared output name reports no pair (A.md and a.md stay two files, as before)" \
  || bad "S10-CL-U5 no clash" "got: $(printf '%s' "$got" | tr '\n' ' ')"

V="$TMP/cl/kb"; O="$TMP/cl/out"; P="$TMP/cl/probe"; mkdir -p "$P"
printf x > "$P/case-probe"
if [ -e "$P/CASE-PROBE" ]; then
  printf '  SKIP  S10-CL-C1..C4 Index.md/index.md and Log.md/log.md in one folder: this disk is case-insensitive (run on the Debian gate)\n'
else
  note "$V" foo/Index.md "CAPITAL-I"; note "$V" foo/index.md "LOWER-i"
  rc=$(run "$V" "$O")
  { [ "$rc" = 2 ] && grep -qxF 'okf-export: foo/Index.md and foo/index.md would both be written to foo/foo.md; rename one of them in the vault' "$TMP/out.txt" \
    && [ ! -e "$O" ]; } \
    && ok "S10-CL-C1 foo/Index.md + foo/index.md stop the export (exit 2), name both and the shared output, write nothing" \
    || bad "S10-CL-C1 index clash" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"

  rm -rf "$TMP/cl"; mkdir -p "$P"; note "$V" Index.md "CAPITAL-I"; note "$V" index.md "LOWER-i"
  rc=$(run "$V" "$O")
  { [ "$rc" = 2 ] && grep -qxF 'okf-export: Index.md and index.md would both be written to kb.md; rename one of them in the vault' "$TMP/out.txt" \
    && [ ! -e "$O" ]; } \
    && ok "S10-CL-C2 root-level Index.md + index.md stop the export (exit 2), nothing written" \
    || bad "S10-CL-C2 root clash" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"

  rm -rf "$TMP/cl"; mkdir -p "$P"; lognote "$V" log.md "- 2026-05-01: one"; lognote "$V" Log.md "- 2026-05-02: two"
  rc=$(run "$V" "$O")
  { [ "$rc" = 2 ] && grep -qxF 'okf-export: Log.md would be renamed to log.md, which already exists; rename one of them in the vault' "$TMP/out.txt" \
    && [ ! -e "$O" ]; } \
    && ok "S10-CL-C3 log.md + Log.md keep their own message (exit 2), nothing written" \
    || bad "S10-CL-C3 log clash" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"

  rm -rf "$TMP/cl"; mkdir -p "$P"; note "$V" a/index.md "in a"; note "$V" A/index.md "in A"
  rc=$(run "$V" "$O")
  { [ "$rc" = 0 ] && grep -qx 'in a' "$O/a/a.md" && grep -qx 'in A' "$O/A/A.md"; } 2>/dev/null \
    && ok "S10-CL-C4 index.md in a/ and in A/ export to a/a.md and A/A.md (exit 0)" \
    || bad "S10-CL-C4 different folders" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
fi

# --- S10-IC: an indented code block is code, as a fenced one is ------------------------------
# CommonMark: 4 spaces (or a tab) in, where a paragraph cannot continue, open a code block; inside a list the same
# indent continues the list item. A [[link]] in code is shown text, so it stays as written and is not checked.
V="$TMP/ic/kb"; O="$TMP/ic/out"
note "$V" b.md "# B"
note "$V" a.md "$(printf 'Text.\n\n    code [[b]] indented\n    more [[nope]]\n\n\tcode [[b]] tabbed\n\nAfter [[b]].')"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qxF '    code [[b]] indented' "$O/a.md" && grep -qxF '    more [[nope]]' "$O/a.md" \
  && grep -qxF "$(printf '\tcode [[b]] tabbed')" "$O/a.md" && grep -qxF 'After [b](b.md).' "$O/a.md"; } 2>/dev/null \
  && ok "S10-IC-1 [[links]] in an indented code block (4 spaces or a tab, after a blank line) stay as written and are not checked" \
  || bad "S10-IC-1 indented code" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') a.md: $(tail -7 "$O/a.md" 2>/dev/null | tr '\n' '|')"

rm -rf "$TMP/ic"; note "$V" b.md "# B"
note "$V" a.md "$(printf -- '- item\n\n    more of the item [[b]]\n\n1. step\n\n    more of the step [[b]]\n\nAfter the list.\n\n    code again [[b]]')"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qxF '    more of the item [b](b.md)' "$O/a.md" && grep -qxF '    more of the step [b](b.md)' "$O/a.md" \
  && grep -qxF '    code again [[b]]' "$O/a.md"; } 2>/dev/null \
  && ok "S10-IC-2 inside a list the same 4-space indent continues the item (a link), and code opens again after the list ends" \
  || bad "S10-IC-2 list continuation" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') a.md: $(tail -11 "$O/a.md" 2>/dev/null | tr '\n' '|')"

# S10-IC-3 (pin; passes as written): in a vault log.md an item indented 4 spaces after a blank line outside a list is an
# indented code block, as in CommonMark, so it stays a raw line of its day, not a dated item; inside a list it is still one.
rm -rf "$TMP/ic"; mkdir -p "$V"
lognote "$V" log.md "$(printf '# Log\n\n## 2026-05-22\n\n    - 2026-05-21: raw\n\n## 2026-05-23\n- 2026-05-23: a\n\n    - 2026-05-20: dated')"
rc=$(run "$V" "$O"); log=$(cat "$O/log.md" 2>/dev/null)
want=$(printf '# Log\n\n## 2026-05-23\n* a\n\n## 2026-05-22\n    - 2026-05-21: raw\n\n## 2026-05-20\n* dated')
{ [ "$rc" = 0 ] && [ "$log" = "$want" ]; } \
  && ok "S10-IC-3 a log item indented 4 after a blank line outside a list stays a raw line of its day; inside a list it is a dated item" \
  || bad "S10-IC-3 log indented item" "rc=$rc log: $(printf '%s' "$log" | tr '\n' '|') report: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

# --- S10-CO: an output disk that does not tell upper from lower case --------------------------
# A case-sensitive vault may hold Notes.md and notes.md; macOS and Windows disks write both to one file. okf-export
# probes the output disk and, where it folds case, refuses names that differ only in case. The unit cases (CO-U*)
# hand the rule an in-memory file list; CO-M* run main() with a fake probe result (a seam), because a case-folding
# disk cannot be made in the Debian container and a case-sensitive one cannot be made on this Mac.
# folds <root-name> <vault-relative file>...: the (first, second) pairs okf-export refuses on a case-folding output.
folds() {
  "$REALPY" - "$EXPORT" "$@" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
for a, b in mod.case_clashes(sorted(Path(p) for p in sys.argv[3:]), sys.argv[2]):
    print(f"{a.as_posix()}|{b.as_posix()}")
PY
}
got=$(folds kb Notes.md notes.md a.md)
[ "$got" = "Notes.md|notes.md" ] \
  && ok "S10-CO-U1 Notes.md and notes.md are reported as a pair on a case-folding output" \
  || bad "S10-CO-U1 pair" "got: $(printf '%s' "$got" | tail -1)"
got=$(folds kb sub/deep/Notes.md sub/deep/notes.md sub/x.md)
[ "$got" = "sub/deep/Notes.md|sub/deep/notes.md" ] \
  && ok "S10-CO-U2 the same pair in nested folders is reported with its folders" \
  || bad "S10-CO-U2 nested" "got: $(printf '%s' "$got" | tr '\n' ' ')"
got=$(folds kb A/x.md a/x.md a/y.md)
[ "$got" = "A|a" ] \
  && ok "S10-CO-U3 folders A/ and a/ are one pair, reported once at the folders (not again for A/x.md and a/x.md)" \
  || bad "S10-CO-U3 folders" "got: $(printf '%s' "$got" | tr '\n' ' ')"
got=$(folds kb a.md b.md foo/index.md foo/bar.md Log.md)
[ -z "$got" ] \
  && ok "S10-CO-U4 a vault with no names that differ only in case reports no pair" \
  || bad "S10-CO-U4 no clash" "got: $(printf '%s' "$got" | tr '\n' ' ')"

# seam <fake|probe> <args>: with "true"/"false" (or "never": the probe must not run), main() runs on <vault> <out> with that probe result (exit code
# printed, report in $TMP/out.txt); with "probe", the real probe's answer for one folder is printed.
seam() {
  "$REALPY" - "$EXPORT" "$@" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
if sys.argv[2] == "probe":
    print(mod.case_insensitive(Path(sys.argv[3])))
    sys.exit(0)
mode = sys.argv[2]   # read now: sys.argv is replaced below
def probe(folder):
    if mode == "never":
        raise SystemExit("probe ran")
    return mode == "true"
mod.case_insensitive = probe
sys.argv = ["okf-export", *sys.argv[3:]]
sys.exit(mod.main())
PY
  printf '%s' "$?"
}
V="$TMP/co/n"; O="$TMP/co/n-out"; note "$V" a.md "# A"; note "$V" sub/b.md "[[a]]"
rc=$(seam never "$V" "$O")
[ "$rc" = 0 ] && ok "S10-CO-P2 an export with no case-only pair never runs the probe, so nothing is made in or beside <out> for it" \
  || bad "S10-CO-P2 probe only on a pair" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

P="$TMP/co/probe"; mkdir -p "$P"; printf x > "$P/case-probe"
[ -e "$P/CASE-PROBE" ] && want=True || want=False
rm "$P/case-probe"
seam probe "$P" >/dev/null; got1=$(cat "$TMP/out.txt"); left1=$(ls -A "$P")
seam probe "$P/not/yet" >/dev/null; got2=$(cat "$TMP/out.txt"); left2=$(ls -A "$P")
{ [ "$got1" = "$want" ] && [ "$got2" = "$want" ] && [ -z "$left1$left2" ]; } \
  && ok "S10-CO-P1 the output probe agrees with the disk ($want), also for an output not yet made, and leaves nothing behind" \
  || bad "S10-CO-P1 probe" "want $want got '$got1' '$got2' left: $left1 $left2"

V="$TMP/co/kb"; O="$TMP/co/out"; note "$V" a.md "# A"; mkdir -p "$O"; chmod 555 "$O"
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP  S10-CO-M3 an output folder that cannot be written: root writes it anyway\n'
else
  rc=$(run "$V" "$O")
  { [ "$rc" = 2 ] && grep -q "^okf-export: cannot write to $O: " "$TMP/out.txt" && [ -z "$(ls -A "$O")" ]; } \
    && ok "S10-CO-M3 an output folder that cannot be written stops the export (exit 2) with one line, no traceback" \
    || bad "S10-CO-M3 unwritable" "rc=$rc report: $(head -3 "$TMP/out.txt" | tr '\n' '|')"
fi
chmod 755 "$O"

rm -rf "$TMP/co/kb" "$O"; mkdir -p "$V"; printf x > "$V/case-probe"
if [ -e "$V/CASE-PROBE" ]; then
  printf '  SKIP  S10-CO-M1..M2 Notes.md and notes.md in one vault folder: this disk is case-insensitive (run on the Debian gate)\n'
else
  rm "$V/case-probe"; note "$V" sub/Notes.md "UPPER"; note "$V" sub/notes.md "lower"
  rc=$(seam true "$V" "$O")
  { [ "$rc" = 2 ] && grep -qxF "okf-export: sub/Notes.md and sub/notes.md would be written over each other: $O is on a disk that does not tell upper from lower case; rename one of them in the vault" "$TMP/out.txt" \
    && [ ! -e "$O" ]; } \
    && ok "S10-CO-M1 on a case-folding output, sub/Notes.md + sub/notes.md stop the export (exit 2), name both, write nothing" \
    || bad "S10-CO-M1 folding output" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
  rm -rf "$O"; rc=$(run "$V" "$O")
  { [ "$rc" = 0 ] && grep -qx 'UPPER' "$O/sub/Notes.md" && grep -qx 'lower' "$O/sub/notes.md"; } 2>/dev/null \
    && ok "S10-CO-M2 on a case-sensitive output (the real probe) the same two notes both export (exit 0)" \
    || bad "S10-CO-M2 sensitive output" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
fi

# --- F-5 (0.9.14 and 0.9.15 registers, spec row PO-1): okf-export polish ------------------------------------------------------------
# S10-PO-1: --version on okf-export and okf-verify prints the plugin version (plugin.json), so LT-31a compares versions.
want=$("$REALPY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$HERE/../.claude-plugin/plugin.json")
ev=$("$EXPORT" --version 2>&1); erc=$?; vv=$("$HERE/okf-verify" --version 2>&1); vrc=$?
{ [ "$erc" = 0 ] && [ "$ev" = "okf-export $want" ] && [ "$vrc" = 0 ] && [ "$vv" = "okf-verify $want" ]; } \
  && ok "S10-PO-1 okf-export --version and okf-verify --version print '<tool> $want' (exit 0)" \
  || bad "S10-PO-1 --version" "export rc=$erc '$ev'; verify rc=$vrc '$(printf '%s' "$vv" | head -1)'"
# S10-PO-2: an <out> that is a file is named as one, not as "exists and is not empty".
V="$TMP/po2/vault"; note "$V" a.md "# A"; printf 'x\n' > "$TMP/po2/file"
rc=$(run "$V" "$TMP/po2/file")
{ [ "$rc" = 2 ] && grep -q 'po2/file exists and is not a folder' "$TMP/out.txt"; } \
  && ok "S10-PO-2 <out> that is a file: 'exists and is not a folder', exit 2" || bad "S10-PO-2 out is a file" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-3: setext headings (a line underlined with === or ---) are headings a [[note#heading]] link can name.
V="$TMP/po3/vault"; O="$TMP/po3/out"
note "$V" a.md "Set up
======

text

Run it
------"
note "$V" b.md "See [[a#Set up]] and [[a#Run it]]."
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF 'See [a > Set up](a.md#set-up) and [a > Run it](a.md#run-it).' "$O/b.md"; } \
  && ok "S10-PO-3 setext headings (=== and ---) resolve as link anchors (exit 0)" \
  || bad "S10-PO-3 setext headings" "rc=$rc $(head -3 "$TMP/out.txt") b.md: $(grep -n 'See' "$O/b.md" 2>&1 | head -1)"
# S10-PO-3b: a --- after a blank line is a thematic break, not a heading of the paragraph above.
note "$V" c.md "Para

---"
note "$V" d.md "[[c#Para]]"
rc=$(run "$V" "$TMP/po3/out2")
{ [ "$rc" = 1 ] && grep -q 'missing heading \[\[c#Para\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-3b a --- after a blank line is a thematic break: [[c#Para]] stays a missing heading" || bad "S10-PO-3b thematic break" "rc=$rc $(head -3 "$TMP/out.txt")"
# S10-PO-4: targets match case-insensitively, as Obsidian matches them: [[Alpha]] and [[Sub/Beta]] find alpha.md and
# sub/beta.md. Two files that differ only in case are ambiguous for a link that matches neither exactly.
V="$TMP/po4/vault"; O="$TMP/po4/out"
note "$V" alpha.md "# Alpha"; note "$V" sub/beta.md "# Beta"
note "$V" c.md "[[Alpha]] and [[Sub/Beta|beta]]"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF '[Alpha](alpha.md) and [beta](sub/beta.md)' "$O/c.md"; } \
  && ok "S10-PO-4 [[Alpha]] and [[Sub/Beta]] resolve to alpha.md and sub/beta.md (case-insensitive, exit 0)" \
  || bad "S10-PO-4 case-insensitive targets" "rc=$rc $(head -3 "$TMP/out.txt") c.md: $(tail -1 "$O/c.md" 2>&1)"
V="$TMP/po4b/vault"; note "$V" x/note.md "# N"; note "$V" y/Note.md "# N"; note "$V" c.md "[[NOTE]]"
rc=$(run "$V" "$TMP/po4b/out")
{ [ "$rc" = 1 ] && grep -q 'ambiguous target \[\[NOTE\]\]: x/note.md, y/Note.md' "$TMP/out.txt"; } \
  && ok "S10-PO-4b [[NOTE]] with x/note.md and y/Note.md is ambiguous, both named" || bad "S10-PO-4b ambiguous by case" "rc=$rc $(head -3 "$TMP/out.txt")"
# S10-PO-5: duplicate headings: a link goes to the first, as in Obsidian and as GitHub's unsuffixed anchor does.
V="$TMP/po5/vault"; O="$TMP/po5/out"
note "$V" a.md "## Notes
one
## Notes
two"
note "$V" b.md "[[a#Notes]]"
rc=$(run "$V" "$O")
{ [ "$rc" = 0 ] && grep -qF '[a > Notes](a.md#notes)' "$O/b.md"; } \
  && ok "S10-PO-5 with two '## Notes' headings [[a#Notes]] links the first (#notes)" || bad "S10-PO-5 duplicate headings" "rc=$rc $(cat "$O/b.md" 2>&1 | tail -1)"
# S10-PO-6: a form feed inside a line does not shift the line numbers of the report (only \n ends a line).
V="$TMP/po6/vault"; mkdir -p "$V"
printf -- '---\ntitle: B\n---\nx\fy\n[[missing]]\n' > "$V/b.md"
rc=$(run "$V" "$TMP/po6/out")
{ [ "$rc" = 1 ] && grep -q '^b.md:5: missing target \[\[missing\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-6 a form feed in line 4 leaves [[missing]] reported on line 5, as an editor counts" || bad "S10-PO-6 line numbers" "rc=$rc $(head -2 "$TMP/out.txt" | tr '\f' '^')"
# S10-PO-7 (review 0.9.35): a list item's continuation line followed by --- is a list then a thematic break, not a heading.
V="$TMP/po7/vault"; note "$V" t.md "- item one
  continued text
---"
note "$V" u.md "[[t#continued text]]"
rc=$(run "$V" "$TMP/po7/out")
{ [ "$rc" = 1 ] && grep -q 'missing heading \[\[t#continued text\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-7 a list continuation followed by --- is not a heading" || bad "S10-PO-7 list then ---" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-8: case is ignored the way Obsidian ignores it (lower case), not by Unicode case folding: [[STRASSE]] is not straße.md.
V="$TMP/po8/vault"; note "$V" straße.md "# S"; note "$V" c.md "[[STRASSE]] [[STRAßE]]"
rc=$(run "$V" "$TMP/po8/out")
{ [ "$rc" = 1 ] && grep -q 'missing target \[\[STRASSE\]\]' "$TMP/out.txt" && ! grep -q 'STRAßE' "$TMP/out.txt"; } \
  && ok "S10-PO-8 [[STRASSE]] is not matched to straße.md; [[STRAßE]] is" || bad "S10-PO-8 lower not casefold" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-9: a lone \r (old Mac line end) still ends a line, as editors count it.
V="$TMP/po9/vault"; mkdir -p "$V"; printf -- '---\rtitle: B\r---\rOld\rMac\r[[gone]]\r' > "$V/b.md"
rc=$(run "$V" "$TMP/po9/out")
{ [ "$rc" = 1 ] && grep -q '^b.md:6: missing target \[\[gone\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-9 with \\r line ends [[gone]] is reported on line 6" || bad "S10-PO-9 CR lines" "rc=$rc $(head -2 "$TMP/out.txt" | tr '\r' '^')"
# S10-PO-10 (review 0.9.35 round 2): a thematic break (*** or a --- after a blank line) is not heading text.
V="$TMP/po10/vault"; note "$V" t.md "***
Bar
==="
note "$V" u.md "[[t#Bar]]"
rc=$(run "$V" "$TMP/po10/out")
{ [ "$rc" = 0 ] && grep -qF '[t > Bar](t.md#bar)' "$TMP/po10/out/u.md"; } \
  && ok "S10-PO-10 *** then Bar underlined with === is a break and the heading Bar" || bad "S10-PO-10 thematic break" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-11: after a list and a blank line, a line indented less than the item's content (2 for `- `, 3 for `1. `) ends
# the list (CommonMark 0.31.2, 5.2 List items), so a setext heading there is found.
V="$TMP/po11/vault"; note "$V" t.md "- item

 Spaced Para
 ---"
note "$V" o.md "1. item

  Ordered Para
  ---"
note "$V" u.md "[[t#Spaced Para]] [[o#Ordered Para]]"
rc=$(run "$V" "$TMP/po11/out")
{ [ "$rc" = 0 ] && grep -qF '[t > Spaced Para](t.md#spaced-para)' "$TMP/po11/out/u.md" \
    && grep -qF '[o > Ordered Para](o.md#ordered-para)' "$TMP/po11/out/u.md"; } \
  && ok "S10-PO-11 a paragraph indented less than the list item's content is out of the list: its setext heading resolves" \
  || bad "S10-PO-11 list ends by indent" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-11b: indented exactly as the item's content, the paragraph stays in the item, so a --- at the margin after it is
# a thematic break that ends the list, not its underline.
V="$TMP/po11b/vault"; note "$V" t.md "- item

  Two In
---"
note "$V" u.md "[[t#Two In]]"
rc=$(run "$V" "$TMP/po11b/out")
{ [ "$rc" = 1 ] && grep -q 'missing heading \[\[t#Two In\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-11b a paragraph indented as the item's content stays list content: no heading" \
  || bad "S10-PO-11b equal indent" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-11c: a tab counts to the next stop of 4 columns (CommonMark 2.2 Tabs), so a tab-indented paragraph is list content.
V="$TMP/po11c/vault"; note "$V" t.md "$(printf -- '- item\n\n\tTabbed\n---')"
note "$V" u.md "[[t#Tabbed]]"
rc=$(run "$V" "$TMP/po11c/out")
{ [ "$rc" = 1 ] && grep -q 'missing heading \[\[t#Tabbed\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-11c a tab-indented paragraph after a list item stays list content: no heading" \
  || bad "S10-PO-11c tab indent" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-11d/11e: in a nested list, a paragraph indented as the OUTER item's content belongs to the outer item: a --- at the
# margin after it is a thematic break, and a === there is a lazy continuation line; neither makes it a heading.
for u in --- ===; do
  V="$TMP/po11d$u/vault"; note "$V" t.md "- a
  - b

  Outer text
$u"
  note "$V" u.md "[[t#Outer text]]"
  rc=$(run "$V" "$TMP/po11d$u/out")
  case $u in ---) id=S10-PO-11d;; *) id=S10-PO-11e;; esac
  { [ "$rc" = 1 ] && grep -q 'missing heading \[\[t#Outer text\]\]' "$TMP/out.txt"; } \
    && ok "$id a paragraph of the outer item after a nested item, then $u at the margin: no heading" \
    || bad "$id nested outer paragraph $u" "rc=$rc $(head -2 "$TMP/out.txt")"
done
# S10-PO-11f: two open levels (content at 2 and 4): a paragraph at 6 (beyond the inner item), 4 or 2 stays in the list;
# one indented 1 space is below every level, so the list ends and its setext heading resolves. A third level is not
# possible here: LIST_ITEM reads a marker only 0-3 spaces in, so `    - c` would be text of `b`.
V="$TMP/po11f/vault"; for lv in 6 4 2 1; do
  pad=$(printf '%*s' "$lv" '')
  note "$V" "d$lv.md" "- a
  - b

${pad}Level $lv
---"
done
note "$V" u.md "[[d6#Level 6]] [[d4#Level 4]] [[d2#Level 2]] [[d1#Level 1]]"
rc=$(run "$V" "$TMP/po11f/out")
{ [ "$rc" = 1 ] && grep -q 'missing heading \[\[d6#Level 6\]\]' "$TMP/out.txt" \
    && grep -q 'missing heading \[\[d4#Level 4\]\]' "$TMP/out.txt" && grep -q 'missing heading \[\[d2#Level 2\]\]' "$TMP/out.txt" \
    && ! grep -q 'd1#Level 1' "$TMP/out.txt" && grep -qF '[d1 > Level 1](d1.md#level-1)' "$TMP/po11f/out/u.md"; } \
  && ok "S10-PO-11f two levels: a paragraph at 6, 4 or 2 spaces stays in the list; 1 space ends it" \
  || bad "S10-PO-11f two levels" "rc=$rc $(head -4 "$TMP/out.txt" | tr '\n' ' ')"
# S10-PO-12a..e: the list rules of CommonMark 0.31.2 (5.2 List items, 4.1 Thematic breaks, 4.5 Fenced code) that end or
# keep a list, read by ONE tracker for headings and for code. Each note's [[x#P]] heading must resolve.
V="$TMP/po12/vault"
note "$V" a.md "- x
***
P
---"                                   # 12a: a thematic break at the margin ends the list, even with no blank line
note "$V" b.md "-

  P
---"                                   # 12b: an empty item ends at the blank line after it
note "$V" c.md "- a

  # In Item
  text
---
Q
---"                                   # 12c: an ATX heading inside an item is a heading and does not end the list
note "$V" e.md "- a
\`\`\`
x
\`\`\`
P
---"                                   # 12e: a fence at the margin ends the list, even with no blank line
note "$V" u.md "[[a#P]] [[b#P]] [[c#In Item]] [[c#Q]] [[e#P]] [[c#text]]"
rc=$(run "$V" "$TMP/po12/out"); U="$TMP/po12/out/u.md"
for c in 'a#P|a > P](a.md#p)' 'b#P|b > P](b.md#p)' 'c#In Item|c > In Item](c.md#in-item)' 'c#Q|c > Q](c.md#q)' 'e#P|e > P](e.md#p)'; do
  link=${c%%|*}; id=S10-PO-12${link%%#*}
  { grep -qF "[${c#*|}" "$U" && ! grep -qF "missing heading [[$link]]" "$TMP/out.txt"; } \
    && ok "$id [[$link]] resolves: [${c#*|}" || bad "$id [[$link]]" "rc=$rc $(grep -F "[[$link]]" "$TMP/out.txt" | head -1)"
done
{ [ "$rc" = 1 ] && grep -q 'missing heading \[\[c#text\]\]' "$TMP/out.txt"; } \
  && ok "S10-PO-12c text in the item after its heading is list content, not a setext heading" \
  || bad "S10-PO-12c text in the item" "rc=$rc: 'text' under the item's heading was read as a setext heading"
# S10-PO-12f..k: a line at the margin continues a list item only lazily, under an open paragraph. After a block that
# leaves no paragraph open inside the item (an ATX heading, a break, a closed fence, also in a nested item, indented
# code, an empty marker, a setext underline), it ends the list, so P below is a heading.
V="$TMP/po12f/vault"
note "$V" f.md "- a
  # H
P
---"
note "$V" g.md "- a
  ***
P
---"
note "$V" h.md "- a
  - b
    \`\`\`
    x
    \`\`\`
P
---"
note "$V" i.md "- a

      code
P
---"
note "$V" j.md "-
P
---"
note "$V" k.md "- a
  ----
P
---"
note "$V" u.md "[[f#P]] [[g#P]] [[h#P]] [[i#P]] [[j#P]] [[k#P]]"
rc=$(run "$V" "$TMP/po12f/out"); U="$TMP/po12f/out/u.md"
for n in f g h i j k; do
  { grep -qF "[$n > P]($n.md#p)" "$U" && ! grep -qF "missing heading [[$n#P]]" "$TMP/out.txt"; } \
    && ok "S10-PO-12$n [[$n#P]] resolves: P at the margin is no lazy line after a block that closes the paragraph" \
    || bad "S10-PO-12$n [[$n#P]]" "rc=$rc $(grep -F "[[$n#P]]" "$TMP/out.txt" | head -1)"
done
# S10-PO-12l: inside a list item, indented code (content indent + 4) and a fence in a nested item are code: a link in
# them stays as written, while the item's text links (also the line after the fence closes) are rewritten.
V="$TMP/po12l/vault"; note "$V" u.md "# Top"
note "$V" t.md "- a [[u#Top]]

      code [[u#Top]]

  - b
    \`\`\`
    fenced [[u#Top]]
    \`\`\`
    after [[u#Top]]"
rc=$(run "$V" "$TMP/po12l/out"); O="$TMP/po12l/out/t.md"
{ [ "$rc" = 0 ] && grep -qFe '- a [u > Top](u.md#top)' "$O" && grep -qF '      code [[u#Top]]' "$O" && grep -qF '    fenced [[u#Top]]' "$O" && grep -qF '    after [u > Top](u.md#top)' "$O"; } \
  && ok "S10-PO-12l a link in an item's indented code and in a nested item's fence stays as written" \
  || bad "S10-PO-12l code in items" "rc=$rc $(grep -n 'Top' "$O" 2>&1 | tr '\n' ' ')"
# S10-PO-12d: the code reader uses the same tracker: a paragraph indented less than the item's content ends the list,
# so a 4-space line after it and a blank line is an indented code block and its link stays as written.
V="$TMP/po12d/vault"; note "$V" t.md "- item

 Para

    code [[nope]]"
rc=$(run "$V" "$TMP/po12d/out")
{ [ "$rc" = 0 ] && grep -qF '    code [[nope]]' "$TMP/po12d/out/t.md"; } \
  && ok "S10-PO-12d after a list ends by indent, a 4-space line is code: [[nope]] stays as written" \
  || bad "S10-PO-12d code after the list" "rc=$rc $(head -2 "$TMP/out.txt")"
# S10-PO-13a..g: blocks inside a list item, read relative to the item's content as CommonMark 0.31.2 reads them (5.2
# List items, 4.6 HTML blocks, 4.7 Link reference definitions): each leaves no paragraph open, so a line at the margin
# after it ends the list; headings inside an item, ATX or setext, also on the marker line, are headings.
V="$TMP/po13/vault"
note "$V" a.md "- a
  <div>
  x
  </div>
P
---"                                   # 13a: a closed HTML block in the item
note "$V" b.md "- a

  [x]: /y
P
---"                                   # 13b: a link reference definition in the item
note "$V" c.md "- a

  1. x
     # Deep
  t
P
---"                                   # 13c: an ATX heading 5 spaces in, at the nested item's content (P is lazy text)
note "$V" d.md "- \`\`\`
  # no
  [[u]]
  \`\`\`
P
---"                                   # 13d: a fence on the marker line
note "$V" e.md "- a
  <div>
P
---"                                   # 13e: an HTML block that never closes ends with its item
note "$V" f.md "- a

  Inner
  ---"                                 # 13f: a setext heading inside the item
note "$V" g.md "- # Marker
1. # One
2. # Two"                              # 13g: ATX headings on the marker line
note "$V" u.md "[[a#P]] [[b#P]] [[c#Deep]] [[d#P]] [[e#P]] [[f#Inner]] [[g#Marker]] [[g#One]] [[g#Two]] [[c#P]] [[d#no]]"
rc=$(run "$V" "$TMP/po13/out"); U="$TMP/po13/out/u.md"
for c in 'a#P|a > P](a.md#p)' 'b#P|b > P](b.md#p)' 'c#Deep|c > Deep](c.md#deep)' 'd#P|d > P](d.md#p)' 'e#P|e > P](e.md#p)' \
         'f#Inner|f > Inner](f.md#inner)' 'g#Marker|g > Marker](g.md#marker)' 'g#One|g > One](g.md#one)' 'g#Two|g > Two](g.md#two)'; do
  link=${c%%|*}; id=S10-PO-13${link%%#*}
  { grep -qF "[${c#*|}" "$U" && ! grep -qF "missing heading [[$link]]" "$TMP/out.txt"; } \
    && ok "$id [[$link]] resolves: [${c#*|}" || bad "$id [[$link]]" "rc=$rc $(grep -F "[[$link]]" "$TMP/out.txt" | head -1)"
done
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[c#P]]' "$TMP/out.txt" && grep -qF 'missing heading [[d#no]]' "$TMP/out.txt" \
    && grep -qF '  [[u]]' "$TMP/po13/out/d.md"; } \
  && ok "S10-PO-13c/d lazy text P and a # line inside a fence are no headings; a link inside the marker-line fence stays as written" \
  || bad "S10-PO-13c/d no false heading" "rc=$rc $(grep -F -e '[[c#P]]' -e '[[d#no]]' "$TMP/out.txt" | tr '\n' ' ') $(grep -F 'u' "$TMP/po13/out/d.md" | tr '\n' ' ')"
# S10-PO-13h: after a thematic break or a setext heading no paragraph is open, so a 4-space line opens an indented code
# block (CommonMark 4.4) and its link stays as written.
V="$TMP/po13h/vault"; note "$V" t.md "***
    code [[nope]]

Title
=====
    code [[gone]]"
rc=$(run "$V" "$TMP/po13h/out")
{ [ "$rc" = 0 ] && grep -qF '    code [[nope]]' "$TMP/po13h/out/t.md" && grep -qF '    code [[gone]]' "$TMP/po13h/out/t.md"; } \
  && ok "S10-PO-13h a 4-space line after a break or a setext heading is code: its link stays as written" \
  || bad "S10-PO-13h code after a break" "rc=$rc $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
# S10-PO-14a..e: wrong results found by the triage of 0.9.37, one row each (link, what the export must do with it).
V="$TMP/po14/vault"; mkdir -p "$TMP/po14/outside"; printf 'SECRET outside the vault\n' > "$TMP/po14/outside/s.md"
note "$V" h.md "# Dup
one
# Dup
two"
note "$V" q.md "> # Quoted heading
> text

- > ## In item quote"
ln -s ../outside/s.md "$V/leak.md"
python3 - "$V" <<'PY'
import sys, unicodedata
v = sys.argv[1]
name = unicodedata.normalize('NFD', 'café')   # stored decomposed, as macOS may store it
open('%s/%s.md' % (v, name), 'w').write('---\ntype: Note\ntitle: "`a]b` thing"\ndescription: d.\ntags: [x]\ngenerated:\n  by: process:fixture\n  at: 2026-01-01\n---\nbody\n')
PY
note "$V" u.md "[[h#Dup]] [[h#dup-1]] [[q#Quoted heading]] [[q#In item quote]] [[$(printf 'caf\303\251')]]"
rc=$(run "$V" "$TMP/po14/out"); U="$TMP/po14/out/u.md"
miss=""
for c in 'a|[h > Dup](h.md#dup)' 'a|[h > dup-1](h.md#dup-1)' 'c|[q > Quoted heading](q.md#quoted-heading)' 'c|[q > In item quote](q.md#in-item-quote)' \
         'e|(cafe%CC%81.md)'; do
  id=${c%%|*}; want=${c#*|}; alt=${want#*|}; want=${want%%|*}
  { grep -qF "$want" "$U" || { [ "$alt" != "$want" ] && grep -qF "$alt" "$U"; }; } || miss="$miss 14$id[$want]"
done
grep -q 'leak.md' "$TMP/out.txt" && ! grep -q SECRET "$TMP/po14/out/leak.md" 2>/dev/null || miss="$miss 14b[leak shipped: $(grep -c SECRET "$TMP/po14/out/leak.md" 2>/dev/null)]"
grep -qF '* [`a]b` thing]' "$TMP/po14/out/index.md" || miss="$miss 14d[$(grep -F 'thing' "$TMP/po14/out/index.md")]"
[ -z "$miss" ] && ok "S10-PO-14 duplicate-heading anchors, quoted headings, a symlink out of the vault refused, a code-span title, an NFC link to an NFD file" \
  || bad "S10-PO-14 triage rows" "rc=$rc failed:$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-15a..e (review round 1 of the triage rows). 15a: quotes inside list items nested 1200 and 100000 levels deep
# (`> - > - ... # Deep`) never crash the export: the note is named, copied unchanged, the run exits 1 with no traceback.
for depth in 1200 100000; do
  V="$TMP/po15a$depth/vault"; mkdir -p "$V"
  python3 - "$V/deep.md" "$depth" <<'PY'
import sys
path, depth = sys.argv[1], int(sys.argv[2])
data = ('---\ntype: Note\ntitle: D\ndescription: Deep.\n---\n' + '> - ' * depth + '# Deep\n').encode()
assert len(data) < 1048576, len(data)
open(path, 'wb').write(data)
PY
  rc=$(run "$V" "$TMP/po15a$depth/out")
  { [ "$rc" = 1 ] && grep -q '^deep.md:.*nested deeper than' "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt" && [ -f "$TMP/po15a$depth/out/deep.md" ]; } \
    && ok "S10-PO-15a quotes and list items nested $depth deep: named, copied unchanged, exit 1, no traceback" \
    || bad "S10-PO-15a nesting $depth" "rc=$rc $(grep -m2 -e deep.md -e Error "$TMP/out.txt" | cut -c1-160 | tr '\n' ' ')"
done
# 15b: heading anchors follow github-slugger: a generated anchor already taken gets the next free number.
V="$TMP/po15b/vault"; note "$V" h.md "# Foo
# Foo-1
# Foo
# Bar
# Bar
# Bar-1"
note "$V" u.md "[[h#foo-2]] [[h#bar-1-1]]"
rc=$(run "$V" "$TMP/po15b/out")
{ [ "$rc" = 0 ] && grep -qF '(h.md#foo-2)' "$TMP/po15b/out/u.md" && grep -qF '(h.md#bar-1-1)' "$TMP/po15b/out/u.md"; } \
  && ok "S10-PO-15b Foo, Foo-1, Foo gives foo-2 and Bar, Bar, Bar-1 gives bar-1-1, as github-slugger" || bad "S10-PO-15b slugger" "rc=$rc $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
# 15c: a heading typed in NFD matches a link typed in NFC (the anchor is made from NFC text).
V="$TMP/po15c/vault"; note "$V" h.md "$(printf '# Cafe\314\201 menu')"; note "$V" u.md "$(printf '[[h#Caf\303\251 menu]]')"
rc=$(run "$V" "$TMP/po15c/out")
{ [ "$rc" = 0 ] && grep -qF "$(printf '(h.md#caf\303\251-menu)')" "$TMP/po15c/out/u.md"; } \
  && ok "S10-PO-15c an NFD heading matches an NFC link (anchor from NFC text)" || bad "S10-PO-15c NFC heading" "rc=$rc $(head -2 "$TMP/out.txt" | tr '\n' ' ')"
# 15d: inside a block quote no setext underline makes a heading (a shortcut: okf-export never invents an anchor, and a
# link to such a heading fails loudly). Outside a quote `Kept` / `===` is still a heading.
V="$TMP/po15d/vault"; note "$V" q1.md "> Title
==="; note "$V" q2.md "> > a
> ==="; note "$V" q3.md "> > b
> ---"; note "$V" q4.md "> Kept
> ==="; note "$V" q5.md "Kept
==="
note "$V" u.md "[[q1#Title]] [[q2#a]] [[q3#b]] [[q4#Kept]] [[q5#Kept]]"
rc=$(run "$V" "$TMP/po15d/out")
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading \[\[q[1-4]#' "$TMP/out.txt")" = 4 ] && grep -qF '(q5.md#kept)' "$TMP/po15d/out/u.md"; } \
  && ok "S10-PO-15d no === / --- under a quote makes a heading (a link to one fails loudly); outside a quote it does" \
  || bad "S10-PO-15d quote underline" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# 15e: the line for a file that leads outside the vault names it as the vault sees it (its name and its link text), never
# the host path it resolves to.
V="$TMP/po14/vault"; rc=$(run "$V" "$TMP/po15e/out")
{ grep -q '^leak.md' "$TMP/out.txt" && grep -qF '../outside/s.md' "$TMP/out.txt" && ! grep -qF "$TMP" "$TMP/out.txt"; } \
  && ok "S10-PO-15e the outside-the-vault line names leak.md and its link text, no host path" || bad "S10-PO-15e skip line" "$(grep leak "$TMP/out.txt" | cut -c1-200)"

# 15f: two files whose names differ only in Unicode normalisation (on a disk that keeps both): an ambiguous link names
# them in an escaped form and says so, instead of two names that look the same.
V="$TMP/po15f/vault"; mkdir -p "$V"
python3 - "$V" <<'PY'
import sys, unicodedata
for form in ('NFC', 'NFD'):
    open('%s/%s.md' % (sys.argv[1], unicodedata.normalize(form, 'café')), 'w').write('# c\n')
PY
if [ "$(ls "$V" | wc -l | tr -d ' ')" = 2 ]; then
  note "$V" u.md "$(printf '[[CAF\303\211]]')"   # a case-insensitive link: exact matches none, folded matches both
  rc=$(run "$V" "$TMP/po15f/out")
  { [ "$rc" = 1 ] && grep -q 'ambiguous target.*differ only in Unicode normalisation' "$TMP/out.txt" && grep -qF 'caf\xe9.md' "$TMP/out.txt"; } \
    && ok "S10-PO-15f names that differ only in normalisation are printed escaped, and the message says so" \
    || bad "S10-PO-15f ambiguous NFC names" "rc=$rc $(grep ambiguous "$TMP/out.txt" | cut -c1-200)"
else
  ok "S10-PO-15f SKIPPED: this disk stores NFC and NFD names as one file"
fi

# 15g: shapes that once gave an anchor CommonMark does not have: a short dash line or a quoted list item before lazy text
# and a bare underline, an underline after indented code in a nested quote, and lazy lines across quote levels. Each link
# fails loudly (missing heading), none gets an anchor.
V="$TMP/po15g/vault"; note "$V" r1.md "> > a
> --
b c
-"; note "$V" r2.md "> - x
> --
b c
-"; note "$V" r3.md "> - x
> ===
b c
-"; note "$V" r4.md "> # H
> >     code
> b
> > ==="; note "$V" r5.md "> > a
> b
> > ==="
note "$V" u.md "[[r1#b c]] [[r2#b c]] [[r3#b c]] [[r4#b]] [[r5#a b]]"
rc=$(run "$V" "$TMP/po15g/out")
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading \[\[r[1-5]#' "$TMP/out.txt")" = 5 ] && ! grep -qF '.md#' "$TMP/po15g/out/u.md"; } \
  && ok "S10-PO-15g dash lines, quoted list items, indented code and lazy lines in quotes give no anchor CommonMark lacks" \
  || bad "S10-PO-15g quote shapes" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300) | $(tail -1 "$TMP/po15g/out/u.md" 2>/dev/null)"

# S10-PO-16: a dot file or folder is left out of the bundle (.obsidian settings, .git data), and so is a symlink INSIDE the
# vault that leads into one: the dot rule is about where the content lives, not what the link is called. The link is skipped
# and named by its name and link text (no host path); a link to a visible file inside the vault still exports; a note that
# links to the skipped file fails loudly (missing target), it is never a silent copy.
V="$TMP/po16/vault"; mkdir -p "$V/.hidden" "$V/.git" "$V/.obsidian"
printf 'HIDDENSECRET md\n' > "$V/.hidden/h.md"; printf 'HIDDENSECRET config\n' > "$V/.git/config"; printf 'HIDDENSECRET json\n' > "$V/.obsidian/workspace.json"
note "$V" pub/real.md "# Real
visible text"
ln -s .hidden/h.md "$V/peek.md"; ln -s .git/config "$V/gitconfig.txt"; ln -s .obsidian/workspace.json "$V/ws.json"
ln -s peek.md "$V/chain.md"; ln -s pub/real.md "$V/ok.md"; ln -s .hidden "$V/hiddendir"; mkdir -p "$V/.hidden/sub"; printf 'HIDDENSECRET sub\n' > "$V/.hidden/sub/s.md"
rc=$(run "$V" "$TMP/po16/out")
miss=""
[ "$rc" = 1 ] || miss="$miss rc=$rc (problems are reported, so exit 1, as for a link that leaves the vault)"
grep -rqF HIDDENSECRET "$TMP/po16/out" && miss="$miss [hidden content shipped: $(grep -rlF HIDDENSECRET "$TMP/po16/out" | sed "s#$TMP/po16/out/##" | tr '\n' ' ')]"
for n in peek.md gitconfig.txt ws.json chain.md; do grep -q "^$n " "$TMP/out.txt" || miss="$miss [$n not named]"; done
grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
[ -e "$TMP/po16/out/hiddendir" ] && miss="$miss [a symlinked folder to a dot folder was entered]"
[ -f "$TMP/po16/out/ok.md" ] && grep -q 'visible text' "$TMP/po16/out/ok.md" || miss="$miss [symlink to a visible file not exported]"
note "$V" u.md "[[peek]]"; rc=$(run "$V" "$TMP/po16/out2")
{ [ "$rc" = 1 ] && grep -q 'missing target \[\[peek\]\]' "$TMP/out.txt"; } || miss="$miss [link to the skipped file: rc=$rc]"
{ grep -rqF HIDDENSECRET "$TMP/po16/out2" || [ -e "$TMP/po16/out2/peek.md" ]; } && miss="$miss [a note linking to the skipped file copied it]"
[ -z "$miss" ] && ok "S10-PO-16 a symlink into a dot folder (.hidden, .git, .obsidian, a chain) is skipped and named, a visible link still exports, a link to it fails loudly" \
  || bad "S10-PO-16 symlink into a dot folder" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-200)"

# S10-PO-13i: the block reader matches a line without its line end, so every S10-PO-11/12/13/14 vault saved with CRLF line
# ends exports to the same report and, CRs aside, the same files as its LF copy.
crlf_bad=""; crlf_n=0
for V in "$TMP"/po1[12345]*/vault; do
  [ -d "$V" ] || continue; crlf_n=$((crlf_n + 1))
  C="${V%/vault}/crlf"; rm -rf "$C"; cp -R "$V" "$C"
  # -type f: not a symlink (writing to one would write through to its target)
  for f in $(cd "$C" && find . -name '*.md' -type f); do awk '{ printf "%s\r\n", $0 }' "$V/$f" > "$C/$f"; done
  rl=$(run "$V" "${V%/vault}/o-lf"); cp "$TMP/out.txt" "$TMP/out-lf.txt"
  rc=$(run "$C" "${V%/vault}/o-crlf")
  diff -r <(cd "${V%/vault}/o-lf" && find . -type f | sort | xargs cat) <(cd "${V%/vault}/o-crlf" && find . -type f | sort | xargs cat | tr -d '\r') >/dev/null \
    && [ "$rl" = "$rc" ] && diff "$TMP/out-lf.txt" <(tr -d '\r' < "$TMP/out.txt") >/dev/null \
    || crlf_bad="$crlf_bad ${V%/vault}:$(diff "$TMP/out-lf.txt" <(tr -d '\r' < "$TMP/out.txt") | grep '^[<>]' | head -1)"
done
[ -z "$crlf_bad" ] && [ "$crlf_n" -ge 10 ] && ok "S10-PO-13i all $crlf_n S10-PO-11 to 15 vaults export the same with CRLF line ends" \
  || bad "S10-PO-13i CRLF" "$crlf_n vaults converted (10 or more expected);$crlf_bad"
# S10-PO-13j: the block reader's cost is linear in line length and nesting depth. Timed in memory through the module (no
# file is written): one marker line opening 8000 nested items then 50 000 lines, and 160 KB single lines of marker runs
# (`- - - ... x`, `* * * ... x`, `1. 1. ... x`, markers then a break) and of `>`, `#`, backticks, spaces, tabs. A linear
# reader takes milliseconds; the quadratic ones took 5 s to over 30 s. The limit, 3 s per shape, allows a slow runner.
"$REALPY" - "$EXPORT" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
n = 160 * 1024
shapes = {"8000 nested + 50000 lines": ["- " * 8000 + "x"] + ["line %d" % i for i in range(50000)],
          "'- ' run": ["- " * (n // 2) + "x"], "'* ' run": ["* " * (n // 2) + "x"], "'1. ' run": ["1. " * (n // 3) + "x"],
          "markers then a break": ["- " * (n // 4) + "* " * (n // 4)], "'>' run": [">" * n], "'#' run": ["#" * n],
          "backticks": ["`" * n], "spaces": [" " * n + "x"], "tabs": ["\t" * n + "x"]}
slow = []
for name, body in shapes.items():
    t = time.perf_counter()
    try:
        list(mod.body_lines(body + ["after"]))
    except mod.TooDeep:   # the '>' run: one nested read per level, stopped at the cap
        pass
    took = time.perf_counter() - t
    print("%-28s %.3f s" % (name, took))
    if took > 3:
        slow.append("%s %.1f s" % (name, took))
sys.exit(1 if slow else 0)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-13j deep nesting and 160 KB marker, quote, hash, backtick, space and tab lines each read in under 3 s" \
  || bad "S10-PO-13j linear cost" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt")"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
