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
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT   # a case below leaves a folder nobody may list
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
if sys.argv[2] in ("probe", "probe-kill"):
    if sys.argv[2] == "probe-kill":   # BL-722: SIGKILL (untrappable) when the probe creates a file, as a kill -9 in that window
        import os, signal
        real_open = os.open
        def killed(*a, **k):
            os.kill(os.getpid(), signal.SIGKILL)
        os.open = lambda p, flags, *a, **k: killed() if flags & os.O_CREAT else real_open(p, flags, *a, **k)
        Path.touch = killed   # Python 3.9's pathlib bound os.open at import, so the patch above does not reach it
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
# BL-722: a kill -9 inside the probe window leaves nothing behind: the probe writes nothing (it compares the folder with its
# case-swapped name), so a SIGKILL at a write never fires and the answer still agrees with the disk.
rc=$(seam probe-kill "$P/not/yet"); got3=$(cat "$TMP/out.txt"); left3=$(ls -A "$P")
{ [ "$rc" = 0 ] && [ "$got3" = "$want" ] && [ -z "$left3" ]; } \
  && ok "BL-722 a SIGKILL at any write of the output probe leaves nothing beside <out>: the probe writes nothing (answer $want)" \
  || bad "BL-722 probe debris" "rc=$rc want $want got '$got3' left: $left3"
# BL-722b: the name of a volume's mount folder is looked up on the disk above it, so the write-free probe must not judge a
# case-sensitive volume by it. A 20 MB case-sensitive APFS image (hdiutil, no sudo) is mounted and <out> is made in its root.
if command -v hdiutil >/dev/null 2>&1 && hdiutil create -size 20m -fs "Case-sensitive APFS" -volname okfcs "$TMP/cs.dmg" -quiet 2>/dev/null \
  && hdiutil attach "$TMP/cs.dmg" -mountpoint "$TMP/csmnt" -nobrowse -quiet 2>/dev/null; then
  seam probe "$TMP/csmnt/not/yet" >/dev/null; got4=$(cat "$TMP/out.txt")
  # BL-722c as a user meets it: a vault on the case-sensitive volume holds Notes.md and notes.md, and <out> goes in a folder
  # named ıx on this disk ('ıx'.swapcase() is 'IX', which APFS does not take for ıx). Exit 2 on a folding disk, never a lost note.
  V="$TMP/csmnt/kb"; O="$P/ıx/out"; mkdir -p "$P/ıx"; note "$V" Notes.md "UPPER"; note "$V" notes.md "lower"
  rc5=$(run "$V" "$O"); [ "$want" = True ] && want5=2 || want5=0
  hdiutil detach "$TMP/csmnt" -quiet 2>/dev/null || hdiutil detach "$TMP/csmnt" -force -quiet
  [ "$got4" = False ] && ok "BL-722b an <out> in the root of a case-sensitive volume probes as case-sensitive (False)" \
    || bad "BL-722b mount root" "got '$got4' for a case-sensitive APFS volume"
  [ "$rc5" = "$want5" ] && ok "BL-722c Notes.md + notes.md exported into a folder named ıx: exit $want5 on this disk (case-insensitive: $want), no note lost" \
    || bad "BL-722c ıx output folder" "rc=$rc5 want $want5 report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(ls "$O" 2>/dev/null | tr '\n' ' ')"
  rm -rf "$P/ıx"
else
  printf '  SKIP  BL-722b..c no hdiutil or no case-sensitive APFS image here (macOS only)\n'
fi
# BL-722c: the probe agrees with the disk for an output whose nearest folder has a non-ASCII name: ıx (dotless i), straße,
# ﬁle (a ligature) and İx. Their swapcase is not the name the disk folds them to.
mkdir -p "$P/ıx" "$P/straße" "$P/ﬁle" "$P/İx"; got6=""
for d in ıx straße ﬁle İx; do seam probe "$P/$d/out" >/dev/null; got6="$got6$d=$(cat "$TMP/out.txt") "; done
rm -rf "$P/ıx" "$P/straße" "$P/ﬁle" "$P/İx"
[ "$got6" = "ıx=$want straße=$want ﬁle=$want İx=$want " ] && ok "BL-722c the probe agrees with the disk ($want) under folders named ıx, straße, ﬁle and İx" \
  || bad "BL-722c non-ASCII folder names" "want $want for each, got: $got6"

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
# 15c: a heading typed in NFD is found by a link typed in NFC; the anchor keeps the heading's own form (S10-PO-30).
V="$TMP/po15c/vault"; note "$V" h.md "$(printf '# Cafe\314\201 menu')"; note "$V" u.md "$(printf '[[h#Caf\303\251 menu]]')"
rc=$(run "$V" "$TMP/po15c/out")
{ [ "$rc" = 0 ] && grep -qF "$(printf '(h.md#cafe\314\201-menu)')" "$TMP/po15c/out/u.md"; } \
  && ok "S10-PO-15c an NFD heading matches an NFC link (the anchor keeps the heading's NFD form, S10-PO-30)" || bad "S10-PO-15c NFC heading" "rc=$rc $(head -2 "$TMP/out.txt" | tr '\n' ' ') $(grep -o '(h.md#[^)]*)' "$TMP/po15c/out/u.md" | od -c | head -2 | tr '\n' ' ')"
# 15d: a lazy underline (`===` with no '>') or an underline under a lazy paragraph line of a deeper quote makes no heading,
# and `---` there is a break; `> Kept` / `> ===` is a heading (BL-884), as `Kept` / `===` outside a quote.
V="$TMP/po15d/vault"; note "$V" q1.md "> Title
==="; note "$V" q2.md "> > a
> ==="; note "$V" q3.md "> > b
> ---"; note "$V" q4.md "> Kept
> ==="; note "$V" q5.md "Kept
==="
note "$V" u.md "[[q1#Title]] [[q2#a]] [[q3#b]] [[q4#Kept]] [[q5#Kept]]"
rc=$(run "$V" "$TMP/po15d/out")
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading \[\[q[1-3]#' "$TMP/out.txt")" = 3 ] && grep -qF '(q4.md#kept)' "$TMP/po15d/out/u.md" && grep -qF '(q5.md#kept)' "$TMP/po15d/out/u.md"; } \
  && ok "S10-PO-15d a lazy === and a --- break in a quote make no heading; > Kept / > === does (BL-884), as outside a quote" \
  || bad "S10-PO-15d quote underline" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# 15e: the line for a file that leads outside the vault names it as the vault sees it (its name and its link text), never
# the host path it resolves to.
V="$TMP/po14/vault"; rc=$(run "$V" "$TMP/po15e/out")
{ grep -q '^leak.md' "$TMP/out.txt" && grep -qF '../outside/s.md' "$TMP/out.txt" && ! grep -qF "$TMP" "$TMP/out.txt"; } \
  && ok "S10-PO-15e the outside-the-vault line names leak.md and its link text, no host path" || bad "S10-PO-15e skip line" "$(grep leak "$TMP/out.txt" | cut -c1-200)"

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
# r5 is a heading in CommonMark (`b` is a lazy line of the deeper quote's paragraph, `> > ===` its underline): BL-884 reads it
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading \[\[r[1-4]#' "$TMP/out.txt")" = 4 ] && [ "$(grep -o '\.md#[a-z-]*' "$TMP/po15g/out/u.md")" = ".md#a-b" ]; } \
  && ok "S10-PO-15g dash lines, quoted list items, indented code and lazy lines in quotes give no anchor CommonMark lacks; r5 a b is one it has" \
  || bad "S10-PO-15g quote shapes" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300) | $(tail -1 "$TMP/po15g/out/u.md" 2>/dev/null)"

# BL-884: a setext heading inside a block quote is a heading, at any quote depth and in a quoted list item; a paragraph that
# holds a lazy line which could start a block (here an indented `# foo`) gives no anchor (that line's text is not read), so
# a link to it fails loudly and never gets an anchor CommonMark lacks.
V="$TMP/bl884/vault"; note "$V" a.md "> Title
> =====

> > Deep
> > ---

> - Item
>   ---"; note "$V" z.md "> Top
    # foo
> ==="
note "$V" u.md "see [[a#Title]] [[a#Deep]] [[a#Item]] [[z#Top # foo]]"
rc=$(run "$V" "$TMP/bl884/out")
{ [ "$rc" = 1 ] && grep -qF '(a.md#title)' "$TMP/bl884/out/u.md" && grep -qF '(a.md#deep)' "$TMP/bl884/out/u.md" \
  && grep -qF '(a.md#item)' "$TMP/bl884/out/u.md" && [ "$(grep -c 'missing heading' "$TMP/out.txt")" = 1 ] && ! grep -qF 'z.md#' "$TMP/bl884/out/u.md"; } \
  && ok "BL-884 setext headings inside quotes (nested, in a quoted item) resolve; one over an unread lazy line fails loudly" \
  || bad "BL-884 setext in a quote" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# RM-230b, SC-export417: a lazy line (no '>') stays in the quote only if the quote's own reader has a paragraph open there.
# RM-230b: `lazy` goes on with the item paragraph in the quote, so `- # Head` after it starts a new list: a heading.
V="$TMP/rm230b/vault"; note "$V" a.md "> - x
lazy
- # Head"; note "$V" u.md "see [[a#Head]]"
rc=$(run "$V" "$TMP/rm230b/out")
{ [ "$rc" = 0 ] && grep -qF '(a.md#head)' "$TMP/rm230b/out/u.md"; } \
  && ok "RM-230b a heading after a quote whose last line is lazy is read: [[a#Head]] resolves (exit 0)" \
  || bad "RM-230b heading after a lazy quote line" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# BL-886b: after a heading in a quoted list item no paragraph is open, so the 4-space line is no lazy line: the quote ends
# and the line is indented code, its link stays as written.
V="$TMP/bl886b/vault"; note "$V" n.md "# N"; note "$V" a.md " >1. # Dup
>     1. # Dup
    [[n]]"
rc=$(run "$V" "$TMP/bl886b/out")
{ [ "$rc" = 0 ] && grep -qxF '    [[n]]' "$TMP/bl886b/out/a.md"; } \
  && ok "BL-886b SC-export417 a 4-space line after a heading in a quoted list item is code: its [[n]] stays as written" \
  || bad "BL-886b code after a quoted item" "rc=$rc $(grep -n 'n' "$TMP/bl886b/out/a.md" 2>&1 | tr '\n' ' ')"
# D23-a: an HTML block inside a quote is raw HTML (4.6) as it is outside one: its [[b]] stays as written. A line with no
# '>' after it is no lazy line (no paragraph is open), so it is read outside the quote and its link is converted.
V="$TMP/d23a/vault"; note "$V" b.md "# B"; note "$V" a.md "> <div>
> [[b]]
> </div>

> <div>
> [[b]]
after [[b]]"
rc=$(run "$V" "$TMP/d23a/out")
{ [ "$rc" = 0 ] && [ "$(grep -cxF '> [[b]]' "$TMP/d23a/out/a.md")" = 2 ] && grep -qxF 'after [b](b.md)' "$TMP/d23a/out/a.md"; } \
  && ok "D23-a a [[link]] in an HTML block inside a quote stays as written; the line after the quote is converted" \
  || bad "D23-a HTML block in a quote" "rc=$rc $(grep -n 'b' "$TMP/d23a/out/a.md" 2>&1 | tr '\n' ' ')"

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

# S10-PO-26a..k (0.9.42): the heading reader never gives an anchor CommonMark lacks (tools/okf-export-oracle.py holds the
# generated proof). 26a..d: a lone `#` is an empty ATX heading (4.2): it joins no paragraph into a setext heading, hides no
# heading and no indented code after it. `#foo` and 7 `#` are no heading.
V="$TMP/po26a/vault"; note "$V" n.md "#
some
---"; note "$V" u.md "[[n#some]] [[n#-some]]"
rc=$(run "$V" "$TMP/po26a/out")
{ [ "$rc" = 1 ] && grep -qF '(n.md#some)' "$TMP/po26a/out/u.md" && grep -qF 'missing heading [[n#-some]]' "$TMP/out.txt" && ! grep -qF 'missing heading [[n#some]]' "$TMP/out.txt"; } \
  && ok "S10-PO-26a a lone # above some / --- leaves the heading some (no phantom -some)" \
  || bad "S10-PO-26a lone # then setext" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
V="$TMP/po26b/vault"; note "$V" n.md "x
#
==="; note "$V" u.md "[[n#x-]] [[n#x]]"
rc=$(run "$V" "$TMP/po26b/out")
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[n#x-]]' "$TMP/out.txt" && grep -qF 'missing heading [[n#x]]' "$TMP/out.txt"; } \
  && ok "S10-PO-26b x / lone # / === gives no x- anchor: a lone # is no paragraph text" \
  || bad "S10-PO-26b phantom x-" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
V="$TMP/po26c/vault"; note "$V" b.md "# B"; note "$V" n.md "#
    [[b]]

- x
  #
      [[b]]"; note "$V" u.md "[[b]]"
rc=$(run "$V" "$TMP/po26c/out")
{ [ "$rc" = 0 ] && [ "$(grep -cF '[[b]]' "$TMP/po26c/out/n.md")" = 2 ] && grep -qF '[b](b.md)' "$TMP/po26c/out/u.md"; } \
  && ok "S10-PO-26c a 4-space line after a lone # (at the margin and inside an item) is code: [[b]] stays as written" \
  || bad "S10-PO-26c code after lone #" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300) | $(grep -c . "$TMP/po26c/out/n.md" 2>&1)"
V="$TMP/po26d/vault"; note "$V" e.md "#foo bar

####### seven"; note "$V" u.md "[[e#foo bar]] [[e#seven]]"
rc=$(run "$V" "$TMP/po26d/out")
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading \[\[e#' "$TMP/out.txt")" = 2 ]; } \
  && ok "S10-PO-26d #foo and 7 hashes are no heading (guard: passes on the base script too)" || bad "S10-PO-26d not headings" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# 26e: a lazy line is paragraph text of the quote's item: its indent does not make it an item's ATX heading. A heading
# written inside the item (`>   # H`) still is one.
V="$TMP/po26e/vault"; note "$V" q.md "> - a
    # H"; note "$V" r.md "> - a
>   # H"; note "$V" u.md "[[q#H]] [[r#H]]"
rc=$(run "$V" "$TMP/po26e/out")
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[q#H]]' "$TMP/out.txt" && grep -qF '(r.md#h)' "$TMP/po26e/out/u.md"; } \
  && ok "S10-PO-26e an indented # H lazily after a quoted list item is no heading; one inside the item is" \
  || bad "S10-PO-26e lazy # H" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# 26f: indented code in a quote is no paragraph text, so a line after it is no lazy line and Para/--- is a heading; with a list
# in the quote the reader cannot tell item text from code and the line stays a quoted paragraph (z/--- gets no anchor).
V="$TMP/po26f/vault"; note "$V" g1.md "> text
>
>     code
Para
---"; note "$V" g2.md "> - a
>
>     code
z
---"; note "$V" u.md "[[g1#Para]] [[g2#z]]"
rc=$(run "$V" "$TMP/po26f/out")
{ [ "$rc" = 1 ] && grep -qF '(g1.md#para)' "$TMP/po26f/out/u.md" && grep -qF 'missing heading [[g2#z]]' "$TMP/out.txt"; } \
  && ok "S10-PO-26f Para after indented code in a quote is a heading; z after code in a quoted list is not (no phantom)" \
  || bad "S10-PO-26f code in quote" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# 26g: the new paths stay linear: 160 KB of lone # lines, of quoted list items with indented lines, and of lazy indented
# lines, plus a GENERATED family: every ordered pair of block starts inside a quote, then a lazy line, repeated (review
# round 1 of the block-quote rows found a quadratic reader that a hand-picked list had missed: 6000 lines took 20 s). The
# bound is a RATIO, not a wall-clock number (a hosted CI runner is several times slower than a laptop): the same
# shape at 8 times the size must cost at most 24 times as much plus 0.25 s (best of 3 each; linear is about 8, quadratic
# about 64). A quadratic control proves the check can fail. Timed in memory through the module, as 13j.
"$REALPY" - "$EXPORT" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
shapes = {"lone #": lambda n: ["#"] * (n // 2), "quoted items + code": lambda n: ["> - a", ">     code"] * (n // 14),
          "lazy indented": lambda n: ["> - a"] + ["    # H"] * (n // 8)}
# The family: a quote opens with block start A, then B, then a line without `>`; the cell repeats. Whether the reader ends
# the quote at that lazy line or takes it in depends on A and B, and a reader that scans ahead to the end of the note on
# each quote end costs quadratic time for some pairs only.
STARTS = ["# H", "- a", "    code", "<div>", "[x]: /u", "```", "---", "1. a"]   # heading, bullet, indented code, HTML, link definition, fence, rule, numbered item
LAZY = ["z", "    # H"]
def cell_family(cell):
    return lambda n: cell * max(1, n // len("\n".join(cell)))
family = {"quote %r %r then %r" % (a, b, lz): cell_family(["> " + a, "> " + b, lz]) for a in STARTS for b in STARTS for lz in LAZY}
sizes = {name: 4 * 1024 for name in family}   # bytes; the family starts at 4 KB, every other shape at 40 KB
shapes.update(family)
def best(fn, lines):
    runs = []
    for _ in range(3):
        t = time.perf_counter(); fn(lines); runs.append(time.perf_counter() - t)
    return min(runs)
def too_slow(fn, make, small, big):
    t1, t8 = best(fn, make(small)), best(fn, make(big))
    return t8 > 24 * t1 + 0.25, t1, t8
def quadratic(lines):          # the control: a reader that rescans everything before each line
    for i in range(len(lines)): lines[:i].count("x")
bad_control, c1, c8 = too_slow(quadratic, lambda n: ["l"] * n, 3000, 24000)
print("control quadratic     %.3f s -> %.3f s  %s" % (c1, c8, "caught" if bad_control else "NOT CAUGHT"))
slow = [] if bad_control else ["the quadratic control was not caught"]
for name, make in shapes.items():
    small = sizes.get(name, 40 * 1024)
    flag, t1, t8 = too_slow(lambda ls: list(mod.body_lines(ls + ["after"])), make, small, 8 * small)
    if flag or name not in family:
        print("%-22s %.3f s -> %.3f s" % (name, t1, t8))
    if flag:
        slow.append("%s %.2f s -> %.2f s" % (name, t1, t8))
print("%d shapes timed (%d generated: %d starts x %d starts x %d lazy lines)" % (len(shapes), len(family), len(STARTS), len(STARTS), len(LAZY)))
sys.exit(1 if slow else 0)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-26g lone #, quoted items with code, lazy indented lines and every pair of block starts in a quote then a lazy line, repeated, cost linear time: 8 times the size costs at most 24 times as much plus 0.25 s (a quadratic control is caught; guard: passes on the base script too)" \
  || bad "S10-PO-26g linear cost" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt")"
# 26h: a list item in a quote that holds no paragraph (empty, or its content starts a block) leaves none open, so the next
# line without a `>` is no lazy line: the quote ends there. An HTML block or indented code then starts at that line, and
# the quoted `# Title` after it is no heading; the indented line is code, so its link stays as written.
V="$TMP/po26h/vault"; note "$V" b.md "# B"; note "$V" t1.md "> -
<br>
> # Title"; note "$V" t2.md "> 1.
<br>
> ## Title"; note "$V" t3.md "> - # H
<br>
> # T"; note "$V" t4.md ">  -   # H
    [[b]]"
note "$V" u.md "[[t1#Title]] [[t2#Title]] [[t3#T]] [[t3#H]] [[t4#H]]"
rc=$(run "$V" "$TMP/po26h/out")
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading \[\[t[123]#' "$TMP/out.txt")" = 3 ] && grep -qF '(t3.md#h)' "$TMP/po26h/out/u.md" \
  && grep -qF '(t4.md#h)' "$TMP/po26h/out/u.md" && grep -qF '    [[b]]' "$TMP/po26h/out/t4.md"; } \
  && ok "S10-PO-26h an empty quoted item, or one holding only a heading, ends at the next line without a >: no heading after an HTML block, code stays code" \
  || bad "S10-PO-26h item without paragraph" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300) | $(cat "$TMP/po26h/out/t4.md" 2>&1 | tail -2 | tr '\n' ' ')"
# 26i: a backtick fence's info string has no backtick, and a closing fence has no info string (CommonMark 4.5): ```py inside
# a fence does not close it, so the # Z after it is code; ``` a`b opens none, so the # Y after it is a heading.
V="$TMP/po26i/vault"; note "$V" f1.md '```py
```py
  # Z'; note "$V" f2.md '``` a`b
# Y'; note "$V" f3.md '```
# X
```   
# W'; note "$V" u.md "[[f1#Z]] [[f2#Y]] [[f3#X]] [[f3#W]]"
rc=$(run "$V" "$TMP/po26i/out")
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[f1#Z]]' "$TMP/out.txt" && grep -qF 'missing heading [[f3#X]]' "$TMP/out.txt" \
  && grep -qF '(f2.md#y)' "$TMP/po26i/out/u.md" && grep -qF '(f3.md#w)' "$TMP/po26i/out/u.md"; } \
  && ok "S10-PO-26i an info string closes no fence and a backtick in one opens none" \
  || bad "S10-PO-26i fence info string" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
# 26j: a raw HTML block is literal text in CommonMark (4.6) and Obsidian reads no Markdown in it (forum.obsidian.md/t/markdown-inside-raw-html-not-rendered-correctly/40569, staff: "We don't support markdown in html blocks"), so a wikilink in one is neither rewritten nor checked; after the block's end it is a link again.
V="$TMP/po26j/vault"; note "$V" b.md "# B"; note "$V" h.md "<div>[[b]] [[nope]]</div>

[[b]]

<!--
[[b]]
-->
[[b]]"
rc=$(run "$V" "$TMP/po26j/out")
{ [ "$rc" = 0 ] && [ "$(grep -cF '[[b]]' "$TMP/po26j/out/h.md")" = 2 ] && [ "$(grep -cF '[b](b.md)' "$TMP/po26j/out/h.md")" = 2 ] \
  && grep -qF '<div>[[b]] [[nope]]</div>' "$TMP/po26j/out/h.md"; } \
  && ok "S10-PO-26j a wikilink inside a raw HTML block stays as written and is not checked; one after the block is rewritten" \
  || bad "S10-PO-26j link in HTML block" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300) | $(tail -7 "$TMP/po26j/out/h.md" 2>&1 | tr '\n' ' ')"
# 26k: inside a block quote an HTML block is raw HTML too (D23-a closed the limit this case once pinned): the link stays.
V="$TMP/po26k/vault"; note "$V" b.md "# B"; note "$V" q.md "> <div>[[b]]</div>"
rc=$(run "$V" "$TMP/po26k/out")
{ [ "$rc" = 0 ] && grep -qxF '> <div>[[b]]</div>' "$TMP/po26k/out/q.md"; } \
  && ok "S10-PO-26k a wikilink in a one-line HTML block inside a block quote stays as written (D23-a)" \
  || bad "S10-PO-26k HTML in a quote" "rc=$rc $(tail -2 "$TMP/po26k/out/q.md" 2>&1 | tr '\n' ' ')"

# S10-PO-27 (review round 2): the anchor drops what github-slugger drops. A tab, a control, a zero-width or soft-hyphen
# character, a BOM and a no-break space in heading text are removed (`a<TAB>b` is `ab`, not `a-b`); a combining mark and
# a connector punctuation (U+203F) are kept. The expected hrefs are github-slugger 2.0.0's own output.
V="$TMP/po27/vault"; note "$V" s.md "$(printf '# a\tb\n\n# x\007y\n\n# p\342\200\213q\n\n# s\302\255t\n\n# q\314\201d\n\n# c\342\200\277d\n\n# e\357\273\277g\n\n# k\302\240l')"
note "$V" u.md "$(printf '[[s#ab]] [[s#xy]] [[s#pq]] [[s#st]] [[s#q\314\201d]] [[s#c\342\200\277d]] [[s#eg]] [[s#kl]]')"
rc=$(run "$V" "$TMP/po27/out")
miss=""
for h in 'ab' 'xy' 'pq' 'st' "$(printf 'q\314\201d')" "$(printf 'c\342\200\277d')" 'eg' 'kl'; do
  grep -qF "(s.md#$h)" "$TMP/po27/out/u.md" || miss="$miss $h"
done
{ [ "$rc" = 0 ] && [ -z "$miss" ]; } \
  && ok "S10-PO-27 heading anchors drop a tab, controls, format characters and a no-break space and keep a mark and U+203F, as github-slugger" \
  || bad "S10-PO-27 slug" "rc=$rc missing:$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-200)"

# S10-PO-28: a tab in the container prefix of a block quote line (the '>', spaces, tabs and list markers before its text)
# counts its columns from the start of the line, to the next multiple of 4 (CommonMark 0.31.2 section 2.2, cmark and
# commonmark.js: a tab the '>' marker only part-uses leaves its remaining columns as spaces). So the headings in such a quote
# resolve like those of a quote written with spaces: `>TAB# B` is a heading (2 columns left after the marker's space),
# `>  TAB# H` too, and `>TAB TAB# I` and `>   TAB# J` are indented code (6 columns left), which stays a loud 'missing heading'.
# (0.9.42 to 0.9.46 muted every heading from such a line on, on the belief that CommonMark counts from the container.)
V="$TMP/po28/vault"; note "$V" t.md "$(printf '>\t>  > >1)   \tx\ny\n      >  >  >>  3) # T')"
note "$V" q.md "$(printf '> # A\n>\t# B\n> # C')"; note "$V" r.md "$(printf '> - a\n>\t# D')"; note "$V" p.md "> # P"
note "$V" h.md "$(printf '>  \t# H\n\n> >\t# K\n\n> -\t# L')"; note "$V" c.md "$(printf '>\t\t# I\n\n>   \t# J')"
note "$V" u.md "[[t#T]] [[q#A]] [[q#B]] [[q#C]] [[r#D]] [[p#P]] [[h#H]] [[h#K]] [[h#L]] [[c#I]] [[c#J]]"
rc=$(run "$V" "$TMP/po28/out")
miss=""; for h in 'q#A' 'q#B' 'q#C' 'r#D' 'p#P' 'h#H' 'h#K' 'h#L'; do grep -qF "[[$h]]" "$TMP/out.txt" && miss="$miss $h"; done
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading' "$TMP/out.txt")" = 3 ] && [ -z "$miss" ] && grep -qF 'missing heading [[t#T]]' "$TMP/out.txt" \
  && grep -qF 'missing heading [[c#I]]' "$TMP/out.txt" && grep -qF 'missing heading [[c#J]]' "$TMP/out.txt" \
  && grep -qF '(q.md#b)' "$TMP/po28/out/u.md" && grep -qF '(q.md#c)' "$TMP/po28/out/u.md" && grep -qF '(r.md#d)' "$TMP/po28/out/u.md" \
  && grep -qF '(h.md#h)' "$TMP/po28/out/u.md" && grep -qF '(h.md#k)' "$TMP/po28/out/u.md" && grep -qF '(h.md#l)' "$TMP/po28/out/u.md"; } \
  && ok "S10-PO-28 a tab in a quote line's container prefix counts its columns from the line start: the headings after it resolve, indented code and a lazy line stay no heading (loud)" \
  || bad "S10-PO-28 tab in quote prefix" "rc=$rc unresolved:$miss $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-29: the headings after a quote with a tab in its prefix are read as after any quote. 29a: two `>TAB- item` lines,
# 29b: `> - a` / `> TAB- b`, 29c: a callout with a nested list, all followed by a heading after a blank line. 29d: a tab in the
# quote of a list item; `C` is no heading in CommonMark (the `TAB TAB# C` line after a blank line is indented code), so that
# link stays a loud miss, and the heading after it resolves (0.9.46 muted it).
po29() {   # po29 <id> <body-of-b> <link>: b.md holds the body, a.md links to it; prints the exit code
  V="$TMP/po29$1/vault"; note "$V" b.md "$2"; note "$V" a.md "$3"; rc=$(run "$V" "$TMP/po29$1/out")
}
po29 a "$(printf '# Before\n\n> Quote\n>\t- item\n>\t- item\n\n# After')" "[[b#Before]] [[b#After]]"
{ [ "$rc" = 0 ] && grep -qF '(b.md#before)' "$TMP/po29a/out/a.md" && grep -qF '(b.md#after)' "$TMP/po29a/out/a.md"; } \
  && ok "S10-PO-29a a heading after a blank line that ends a quote with tab-indented items resolves" \
  || bad "S10-PO-29a heading after a tabbed quote" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
po29 b "$(printf '> - a\n> \t- b\n\n# After')" "[[b#After]]"
{ [ "$rc" = 0 ] && grep -qF '(b.md#after)' "$TMP/po29b/out/a.md"; } \
  && ok "S10-PO-29b a heading after a quoted list whose second item has a tab after the margin resolves" \
  || bad "S10-PO-29b heading after a tabbed quote" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
po29 c "$(printf '> [!note]\n>\t- b\n\ntext\n\n## After')" "[[b#After]]"
{ [ "$rc" = 0 ] && grep -qF '(b.md#after)' "$TMP/po29c/out/a.md"; } \
  && ok "S10-PO-29c a heading further down after a callout with a tab-indented list resolves" \
  || bad "S10-PO-29c heading after a callout" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
po29 d "$(printf -- '-\t >> \t# C\n y\n\n\t\t# C\n\n# After')" "[[b#C]] [[b#After]]"
{ [ "$rc" = 1 ] && [ "$(grep -c 'missing heading' "$TMP/out.txt")" = 1 ] && grep -qF 'missing heading [[b#C]]' "$TMP/out.txt" && grep -qF '(b.md#after)' "$TMP/po29d/out/a.md"; } \
  && ok "S10-PO-29d a tab in the quote of a list item: C is no heading (loud) and the heading after it resolves" \
  || bad "S10-PO-29d tab in a quote in an item" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-31: soundness guards for the quote reader once a tab no longer mutes it (found by the reviewer fuzz against
# markdown-it-py and commonmark.py, 40 000 notes, 2026-10-22): a line without '>' that the quote took as a lazy line may be
# a paragraph of its own in CommonMark, so what follows it, up to the next blank line, is not read for headings, and the list
# items its indent does not reach have ended. 31a: `D` is indented code, `a` starts a paragraph and the tab line goes on with
# it; 31b: `<v>` is an HTML block, `x` a paragraph, and `2.` cannot start a list under it; 31c: the same without a tab (the
# hole was there before 0.9.47, the tab mute hid it in a tab-holding note); 31d (guard): `# After` on a line of its own
# after a lazy line, and a heading after a quote line with a tab in an item, still resolve.
po31() {   # po31 <id> <body-of-b> <link>: b.md holds the body, a.md links to it; prints the exit code
  V="$TMP/po31$1/vault"; note "$V" b.md "$2"; note "$V" a.md "$3"; rc=$(run "$V" "$TMP/po31$1/out")
}
po31 a "$(printf '1) >-\n   >\t\tD\na\n\t# Z')" "[[b#Z]]"
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[b#Z]]' "$TMP/out.txt"; } \
  && ok "S10-PO-31a a line after a quote whose code ended in a lazy-looking line is no heading (it continues the paragraph)" \
  || bad "S10-PO-31a lazy end, tab" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
po31 b "$(printf '><v>\nx\n2. >\t# Z')" "[[b#Z]]"
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[b#Z]]' "$TMP/out.txt"; } \
  && ok "S10-PO-31b an ordered item that cannot start a list under the paragraph after an HTML tag line in a quote is no heading" \
  || bad "S10-PO-31b html tag line in a quote" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
po31 c "$(printf '1) >-\n   >       D\na\n    # Z')" "[[b#Z]]"
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[b#Z]]' "$TMP/out.txt"; } \
  && ok "S10-PO-31c the same without a tab: the lazy end of a quote does not leave the list item open" \
  || bad "S10-PO-31c lazy end, spaces" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
po31 d "$(printf -- '- >\t# M\n  y\n# After\n\n>>> foo\n> bar\n>># baz')" "[[b#M]] [[b#After]] [[b#baz]]"
{ [ "$rc" = 0 ] && grep -qF '(b.md#m)' "$TMP/po31d/out/a.md" && grep -qF '(b.md#after)' "$TMP/po31d/out/a.md" && grep -qF '(b.md#baz)' "$TMP/po31d/out/a.md"; } \
  && ok "S10-PO-31d a heading in a quote in an item, one on a line of its own after a lazy line, and a nested quote's heading resolve" \
  || bad "S10-PO-31d guard" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-29e: a note whose first line is `---` indented is no frontmatter (spec 4 and okf-check want '---' at the start of
# the file), so the fence after it runs to the end of the note and `# H` is code: there is no heading H to link to. The
# reader used to skip up to the next `---` line as frontmatter and read `# H` as a heading (found by the reviewer fuzz).
V="$TMP/po29e/vault"; mkdir -p "$V"; printf '   ---\n~~~\nx\n---\n# H\n' > "$V/b.md"; note "$V" a.md "[[b#H]]"
rc=$(run "$V" "$TMP/po29e/out")
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[b#H]]' "$TMP/out.txt"; } \
  && ok "S10-PO-29e an indented --- on the first line is no frontmatter: the fence after it hides the heading" \
  || bad "S10-PO-29e indented frontmatter fence" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-30: the anchor is the heading's own Unicode form, as github-slugger and github.com keep it (a decomposed heading id,
# `user-content-cafe` + U+0301, checked on github.com with a gist, 2026-10-22; the NFC link `#caf%C3%A9` does not jump to it).
# A link is matched to a heading on the NFC of both sides, so a link typed in either form finds a heading typed in either form
# and gets that heading's anchor. 30a NFD heading, NFD link; 30b NFC heading, NFC link (unchanged); 30c NFC heading, NFD link;
# 30d both spellings of one word as two headings: each link takes the exact one; 30e a repeat of an NFD heading is `-1` in the
# NFD form and an NFC link finds it; 30f a heading that does not exist stays a loud 'missing heading'.
NFD_E=$(printf 'e\314\201'); NFC_E=$(printf '\303\251')
po30() {   # po30 <id> <body-of-h> <links>: h.md holds the body, u.md links to it; prints the exit code
  V="$TMP/po30$1/vault"; note "$V" h.md "$2"; note "$V" u.md "$3"; rc=$(run "$V" "$TMP/po30$1/out")
}
po30 a "# Caf${NFD_E} menu" "[[h#Caf${NFD_E} menu]]"
{ [ "$rc" = 0 ] && grep -qF "(h.md#caf${NFD_E}-menu)" "$TMP/po30a/out/u.md"; } \
  && ok "S10-PO-30a a heading typed in NFD gets an NFD anchor for an NFD link" \
  || bad "S10-PO-30a NFD heading, NFD link" "rc=$rc $(grep -o '(h.md#[^)]*)' "$TMP/po30a/out/u.md" | od -c | head -2 | tr '\n' ' ')"
po30 b "# Caf${NFC_E} menu" "[[h#Caf${NFC_E} menu]]"
{ [ "$rc" = 0 ] && grep -qF "(h.md#caf${NFC_E}-menu)" "$TMP/po30b/out/u.md"; } \
  && ok "S10-PO-30b a heading typed in NFC gets an NFC anchor for an NFC link (unchanged)" \
  || bad "S10-PO-30b NFC heading, NFC link" "rc=$rc $(grep -o '(h.md#[^)]*)' "$TMP/po30b/out/u.md" | od -c | head -2 | tr '\n' ' ')"
po30 c "# Caf${NFC_E} menu" "[[h#Caf${NFD_E} menu]]"
{ [ "$rc" = 0 ] && grep -qF "(h.md#caf${NFC_E}-menu)" "$TMP/po30c/out/u.md"; } \
  && ok "S10-PO-30c a heading typed in NFC gets its NFC anchor for a link typed in NFD" \
  || bad "S10-PO-30c NFC heading, NFD link" "rc=$rc $(grep -o '(h.md#[^)]*)' "$TMP/po30c/out/u.md" | od -c | head -2 | tr '\n' ' ')"
po30 d "$(printf '# Caf%s\n# Caf%s' "$NFC_E" "$NFD_E")" "[[h#Caf${NFC_E}]] [[h#Caf${NFD_E}]]"
{ [ "$rc" = 0 ] && grep -qF "(h.md#caf${NFC_E}) " "$TMP/po30d/out/u.md" && grep -qF "(h.md#caf${NFD_E})" "$TMP/po30d/out/u.md"; } \
  && ok "S10-PO-30d two spellings of one word as two headings: each link takes the heading typed in its own form" \
  || bad "S10-PO-30d both spellings" "rc=$rc $(grep -o '(h.md#[^)]*)' "$TMP/po30d/out/u.md" | od -c | head -3 | tr '\n' ' ')"
po30 e "$(printf '# Caf%s\n# Caf%s' "$NFD_E" "$NFD_E")" "[[h#Caf${NFC_E}-1]]"
{ [ "$rc" = 0 ] && grep -qF "(h.md#caf${NFD_E}-1)" "$TMP/po30e/out/u.md"; } \
  && ok "S10-PO-30e the repeat of an NFD heading is numbered in its NFD form and an NFC link finds it" \
  || bad "S10-PO-30e numbered NFD heading" "rc=$rc $(grep -o '(h.md#[^)]*)' "$TMP/po30e/out/u.md" | od -c | head -2 | tr '\n' ' ')"
po30 f "# Caf${NFD_E}" "[[h#Cafx]]"
{ [ "$rc" = 1 ] && grep -qF 'missing heading [[h#Cafx]]' "$TMP/out.txt"; } \
  && ok "S10-PO-30f a heading that is not there stays a loud 'missing heading'" \
  || bad "S10-PO-30f missing heading" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-200)"

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
# reader takes milliseconds; the quadratic ones took 5 s to over 30 s. The bound is a RATIO, not a wall-clock number (as 26g):
# each shape at 8 times the size must cost at most 24 times as much plus 0.25 s (best of 3 each), and a quadratic control proves the
# check can fail.
"$REALPY" - "$EXPORT" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
def shapes(n):   # n = line length in bytes; the nested shape scales both its depth and its line count
    return {"nested + lines": ["- " * (n // 20) + "x"] + ["line %d" % i for i in range(n * 50000 // (160 * 1024))],
            "'- ' run": ["- " * (n // 2) + "x"], "'* ' run": ["* " * (n // 2) + "x"], "'1. ' run": ["1. " * (n // 3) + "x"],
            "markers then a break": ["- " * (n // 4) + "* " * (n // 4)], "'>' run": [">" * n], "'#' run": ["#" * n],
            "backticks": ["`" * n], "spaces": [" " * n + "x"], "tabs": ["\t" * n + "x"]}
def read(lines):
    try:
        list(mod.body_lines(lines + ["after"]))
    except mod.TooDeep:   # the '>' run: one nested read per level, stopped at the cap
        pass
def best(fn, lines):
    runs = []
    for _ in range(3):
        t = time.perf_counter(); fn(lines); runs.append(time.perf_counter() - t)
    return min(runs)
def too_slow(fn, make, small, big):
    t1, t8 = best(fn, make(small)), best(fn, make(big))
    return t8 > 24 * t1 + 0.25, t1, t8
def quadratic(lines):          # the control: a reader that rescans everything before each line
    for i in range(len(lines)): lines[:i].count("x")
bad_control, c1, c8 = too_slow(quadratic, lambda n: ["l"] * n, 3000, 24000)
print("control quadratic     %.3f s -> %.3f s  %s" % (c1, c8, "caught" if bad_control else "NOT CAUGHT"))
slow = [] if bad_control else ["the quadratic control was not caught"]
for name in shapes(1):
    flag, t1, t8 = too_slow(read, lambda n: shapes(n)[name], 20 * 1024, 160 * 1024)
    print("%-22s %.3f s -> %.3f s" % (name, t1, t8))
    if flag:
        slow.append("%s %.2f s -> %.2f s" % (name, t1, t8))
sys.exit(1 if slow else 0)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-13j deep nesting and 160 KB marker, quote, hash, backtick, space and tab lines each cost linear time: 8 times the size costs at most 24 times as much plus 0.25 s (a quadratic control is caught)" \
  || bad "S10-PO-13j linear cost" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt")"

# S10-PO-17: two output names that differ only in Unicode normalisation (café as NFC and as NFD) are one file on macOS (APFS),
# so the second would overwrite the first. The pair is decided from the names alone, before any write and on every disk,
# like the other name clashes; a vault whose names are all in one spelling is not affected. The vault of 17a..17c holds a.md
# and b.md; nfcseam gives them the two spellings as output names (a disk that keeps both spellings, or a vault that holds
# both, cannot be made on this Mac), with the case probe faked: "never" must not run, "true"/"false" is its answer.
# nfcseam <never|true|false> <plain|case> <vault> <out>: main() on <vault> <out>; the exit code is printed, the report is in $TMP/out.txt.
nfcseam() {
  "$REALPY" - "$EXPORT" "$@" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, unicodedata
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
mode, kind = sys.argv[2], sys.argv[3]
stem = ("café", "café") if kind == "plain" else ("CAFÉ", "café")   # "case": the pair also differs in case
names = {"a.md": unicodedata.normalize("NFC", stem[0]) + ".md", "b.md": unicodedata.normalize("NFD", stem[1]) + ".md"}
if kind == "fold":   # one file on APFS (canonical caseless match), but NFC then casefold keeps them apart: iota with dialytika and tonos, in two spellings
    names = {"a.md": "\u0390.md", "b.md": "\u03aa\u0301.md"}
real = mod.vault_out_rel
mod.vault_out_rel = lambda rel, root_name: Path(names[rel.as_posix()]) if rel.as_posix() in names else real(rel, root_name)
def probe(folder):
    if mode == "never":
        raise SystemExit("probe ran")
    return mode == "true"
mod.case_insensitive = probe
sys.argv = ["okf-export", *sys.argv[4:]]
sys.exit(mod.main())
PY
  printf '%s' "$?"
}
V="$TMP/po17/vault"; O="$TMP/po17/out"; note "$V" a.md "# A"; note "$V" b.md "# B"
rc=$(nfcseam never plain "$V" "$O")
{ [ "$rc" = 2 ] && grep -qxF 'okf-export: b.md and a.md would be written over each other: their output names differ only in Unicode normalisation, and a disk such as macOS APFS stores both as one file; rename one of them in the vault' "$TMP/out.txt" \
  && [ ! -e "$O" ]; } \
  && ok "S10-PO-17a two output names that differ only in NFC/NFD stop the export (exit 2) before any write, name both, and never probe the disk" \
  || bad "S10-PO-17a NFC/NFD pair" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
rm -rf "$O"; rc=$(nfcseam true case "$V" "$O")
{ [ "$rc" = 2 ] && grep -qxF 'okf-export: a.md and b.md would be written over each other: '"$O"' is on a disk that does not tell upper from lower case; rename one of them in the vault' "$TMP/out.txt" \
  && [ ! -e "$O" ]; } \
  && ok "S10-PO-17b CAFÉ (NFC) and café (NFD) clash on a case-folding output, which also stores NFC and NFD as one (exit 2, nothing written)" \
  || bad "S10-PO-17b case and NFC" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
rm -rf "$O"; rc=$(nfcseam false case "$V" "$O")
{ [ "$rc" = 0 ] && [ -f "$O/CAF$(printf '\303\211').md" ]; } \
  && ok "S10-PO-17c the same CAFÉ and café on a case-sensitive output both export (exit 0): only a normalisation pair is refused on every disk" \
  || bad "S10-PO-17c case-sensitive output" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
# 17e: APFS matches names by canonical caseless equality, which casefolds and then renormalises; casefolding alone leaves
# U+0390 and U+03AA U+0301 apart (casefold gives U+03B9 U+0308 U+0301 against U+03CA U+0301). Both are one file there.
rm -rf "$O"; rc=$(nfcseam true fold "$V" "$O")
{ [ "$rc" = 2 ] && grep -q 'would be written over each other: .* is on a disk that does not tell upper from lower case' "$TMP/out.txt" && [ ! -e "$O" ]; } \
  && ok "S10-PO-17e U+0390 and U+03AA U+0301 (one name to APFS) clash on a case-folding output (exit 2, nothing written)" \
  || bad "S10-PO-17e canonical caseless pair" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
rm -rf "$O"; rc=$(nfcseam false fold "$V" "$O")
[ "$rc" = 0 ] && ok "S10-PO-17e the same two names both export on a case-sensitive output (exit 0)" \
  || bad "S10-PO-17e case-sensitive output" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|')"
# 17f: the name key agrees with canonical caseless matching, NFD(casefold(NFD(x))), over U+0020..U+2FFFF alone and followed by U+0301
# or U+0308 U+0301: strings whose canonical caseless forms are equal get one key; a miss is two names APFS holds as one file
# that okf-export would tell apart. The always-on key (case off) must keep the fi ligature and fi apart: only a compatibility form joins them.
"$REALPY" - "$EXPORT" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, unicodedata as u
from collections import defaultdict
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
N = u.normalize
canon = lambda s: N("NFD", N("NFD", s).casefold())   # the definition of canonical caseless matching, written out here
groups = defaultdict(set)
for cp in range(0x20, 0x30000):
    c = chr(cp)
    if u.category(c) == "Cs":
        continue
    for x in (c, c + "\u0301", c + "\u0308\u0301"):
        for t in {x, N("NFD", x), N("NFC", x), x.casefold(), N("NFD", x.casefold()), N("NFC", x.casefold())}:
            groups[canon(t)].add(t)
misses = [sorted(g)[0] for g in groups.values() if len({mod.name_key(t) for t in g}) > 1]
print("groups %d misses: %d" % (len(groups), len(misses)), [[hex(ord(ch)) for ch in m] for m in misses[:3]])
apart = mod.name_key("\ufb01", case=False) != mod.name_key("fi", case=False)
print("fi ligature apart with case off:", apart)
sys.exit(0 if not misses and apart else 1)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-17f the name key gives equal keys to every canonically caseless equal string over U+0020..U+2FFFF (misses: 0), and keeps the fi ligature apart from fi when case is off" \
  || bad "S10-PO-17f key against canonical caseless matching" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt" | cut -c1-300)"
# 17d: a vault that really holds both spellings (a disk that keeps them, e.g. the Debian gate) is refused the same way, and the
# two names are printed escaped, because they look alike. APFS stores them as one file: visible SKIP.
V="$TMP/po17d/vault"; O="$TMP/po17d/out"; mkdir -p "$V"
"$REALPY" - "$V" <<'PY'
import sys, unicodedata
for form in ('NFC', 'NFD'):
    open('%s/%s.md' % (sys.argv[1], unicodedata.normalize(form, 'café')), 'w').write('# c\n')
PY
if [ "$(ls "$V" | wc -l | tr -d ' ')" = 2 ]; then
  rc=$(run "$V" "$O")
  { [ "$rc" = 2 ] && grep -qF 'cafe\u0301.md and caf\xe9.md would be written over each other' "$TMP/out.txt" && [ ! -e "$O" ]; } \
    && ok "S10-PO-17d a vault that holds café.md in NFC and in NFD is refused (exit 2) with both names escaped, nothing written" \
    || bad "S10-PO-17d real NFC/NFD vault" "rc=$rc report: $(head -2 "$TMP/out.txt" | tr '\n' '|') out: $(find "$O" -type f 2>/dev/null | tr '\n' ' ')"
else
  printf '  SKIP  S10-PO-17d a vault with café.md in NFC and in NFD: this disk stores both as one file (run on the Debian gate)\n'
fi

# S10-PO-18: a symlink that rglob lists but is_file() refuses is named, not skipped in silence: a link to a FOLDER (rglob does
# not enter it, so its notes would vanish from the bundle), a BROKEN link and a LOOP. Each is a problem line and exit 1; a
# dot-named link stays out like every dot name; the rest of the vault exports as before; no host path is printed.
V="$TMP/po18/vault"; mkdir -p "$V/real" "$V/.hidden"
note "$V" ok.md "# Ok"; note "$V" real/in.md "# In"
ln -s real "$V/linkdir"; ln -s nowhere.md "$V/broken.md"; ln -s loop2.md "$V/loop1.md"; ln -s loop1.md "$V/loop2.md"
ln -s real "$V/.dotlink"; ln -s nowhere.md "$V/.dotbroken.md"; ln -s ../real "$V/.hidden/inner"
rc=$(run "$V" "$TMP/po18/out")
miss=""
[ "$rc" = 1 ] || miss="$miss rc=$rc (a skipped link is a problem, exit 1)"
for n in linkdir broken.md loop1.md loop2.md; do grep -q "^$n — a symlink .*: skipped\$" "$TMP/out.txt" || miss="$miss [$n not named]"; done
grep -q '^linkdir — a symlink to a folder' "$TMP/out.txt" || miss="$miss [linkdir not named as a folder link]"
grep -q '^broken.md — a symlink that leads nowhere' "$TMP/out.txt" || miss="$miss [broken.md not named as leading nowhere]"
grep -q '^\.dot\|^\.hidden' "$TMP/out.txt" && miss="$miss [a dot name was named]"
grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
[ -e "$TMP/po18/out/linkdir" ] && miss="$miss [a symlinked folder was entered]"
[ -f "$TMP/po18/out/ok.md" ] && [ -f "$TMP/po18/out/real/in.md" ] || miss="$miss [ok.md or real/in.md not exported]"
[ -z "$miss" ] && ok "S10-PO-18 a symlinked folder, a broken link and a loop are named with exit 1; dot-named links stay unnamed; the rest exports" \
  || bad "S10-PO-18 silent skips" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-19: the report names a symlink by its link text, never by a path of this machine. A relative link prints its text;
# an absolute link (whose text IS a host path) prints "an absolute link", whether it leads out of the vault or into a dot folder.
V="$TMP/po19/vault"; mkdir -p "$V/.hidden" "$TMP/po19/ext"
printf 'EXTSECRET\n' > "$TMP/po19/ext/out.md"; printf 'HIDDENSECRET\n' > "$V/.hidden/h.md"; note "$V" ok.md "# Ok"
ln -s "$TMP/po19/ext/out.md" "$V/abs.md"; ln -s "$V/.hidden/h.md" "$V/abshidden.md"; ln -s ../ext/out.md "$V/rel.md"
rc=$(run "$V" "$TMP/po19/out")
miss=""
[ "$rc" = 1 ] || miss="$miss rc=$rc"
grep -q '^abs.md — a symlink to an absolute link, which leads outside the vault: skipped$' "$TMP/out.txt" || miss="$miss [abs.md line]"
grep -q '^abshidden.md — a symlink to an absolute link, which leads into a hidden file or folder: skipped$' "$TMP/out.txt" || miss="$miss [abshidden.md line]"
grep -q '^rel.md — a symlink to ../ext/out.md, which leads outside the vault: skipped$' "$TMP/out.txt" || miss="$miss [rel.md keeps its link text]"
grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
grep -rqE 'EXTSECRET|HIDDENSECRET' "$TMP/po19/out" && miss="$miss [content shipped]"
[ -z "$miss" ] && ok "S10-PO-19 an absolute symlink is reported as 'an absolute link' (no host path); a relative one keeps its link text" \
  || bad "S10-PO-19 host path in the report" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-20: a HARD link to a file under a dot name has no target to follow: it IS the hidden file. A visible file with the same
# (device, inode) as one under a dot folder or a dot-named file is refused and named. A second name of a visible file still
# exports; a dot-folder symlink to a visible file does not make that file hidden. A hard link to a file OUTSIDE the vault looks
# like a file that lives here, so it is exported, and named as a warning (S10-PO-32).
V="$TMP/po20/vault"; mkdir -p "$V/.hidden/deep/er" "$V/.git" "$V/.obsidian" "$TMP/po20/ext"
printf 'HIDDENSECRET md\n' > "$V/.hidden/deep/er/h.md"; printf 'HIDDENSECRET config\n' > "$V/.git/config"; printf 'HIDDENSECRET json\n' > "$V/.obsidian/ws.md"
printf 'HIDDENSECRET dotname\n' > "$V/.dotfile.md"; printf 'EXTFILE\n' > "$TMP/po20/ext/e.md"
note "$V" pub/real.md "# Real
visible text"
ln "$V/.hidden/deep/er/h.md" "$V/peek.md"; ln "$V/.git/config" "$V/gitconfig.txt"; ln "$V/.obsidian/ws.md" "$V/ws.md"
ln "$V/peek.md" "$V/chain.md"; ln "$V/.dotfile.md" "$V/pub/dotcopy.md"
ln "$V/pub/real.md" "$V/second.md"; ln -s ../pub/real.md "$V/.hidden/lnk.md"; ln "$TMP/po20/ext/e.md" "$V/ext.md"
rc=$(run "$V" "$TMP/po20/out")
miss=""
[ "$rc" = 1 ] || miss="$miss rc=$rc"
grep -rqF HIDDENSECRET "$TMP/po20/out" && miss="$miss [hidden content shipped: $(grep -rlF HIDDENSECRET "$TMP/po20/out" | sed "s#$TMP/po20/out/##" | tr '\n' ' ')]"
for n in peek.md gitconfig.txt ws.md chain.md pub/dotcopy.md; do
  grep -qxF "$n — a hard link to a hidden file or folder of the vault: skipped" "$TMP/out.txt" || miss="$miss [$n not named]"; done
grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
for n in pub/real.md second.md ext.md; do [ -f "$TMP/po20/out/$n" ] || miss="$miss [$n not exported]"; done
grep -qE '^(pub/real|second)\.md ' "$TMP/out.txt" && miss="$miss [a visible file was named]"
[ -z "$miss" ] && ok "S10-PO-20 a hard link to a hidden file (dot folder, dot name, chain) is refused and named; a visible file's second name exports" \
  || bad "S10-PO-20 hard link to a hidden file" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-32: a visible file whose st_nlink is higher than the names of it found in the vault has another name outside it (GNU tar
# --check-links warns the same way). It cannot be refused, since it looks like a file that lives here, so it is exported and
# named: "<file> — a file with 2 names, 1 of them in the vault; the other names are outside it: exported" (exit 1, like the
# other lines of the report). 32a one outside name; 32b three names, one outside the vault (3 links, 2 found); 32c no
# warning when every name is in the vault (two visible names; a visible and a dot name is the refusal of S10-PO-20); 32d a
# symlink to such a file is not named a second time; 32e the same file twice outside, the count is of names, not of files.
V="$TMP/po32/vault"; mkdir -p "$V/sub" "$TMP/po32/ext"
printf 'EXT one\n' > "$TMP/po32/ext/e.md"; ln "$TMP/po32/ext/e.md" "$V/out1.md"
printf 'EXT three\n' > "$TMP/po32/ext/t.md"; ln "$TMP/po32/ext/t.md" "$V/three-a.md"; ln "$TMP/po32/ext/t.md" "$V/sub/three-b.md"
note "$V" in-a.md "# In a"; ln "$V/in-a.md" "$V/in-b.md"
printf 'EXT sym\n' > "$TMP/po32/ext/s.md"; ln "$TMP/po32/ext/s.md" "$V/sym-target.md"; ln -s sym-target.md "$V/sym-link.md"
rc=$(run "$V" "$TMP/po32/out")
miss=""
[ "$rc" = 1 ] || miss="$miss rc=$rc"
grep -qxF "out1.md — a file with 2 names, 1 of them in the vault; the other names are outside it: exported" "$TMP/out.txt" || miss="$miss [out1.md not named]"
grep -qxF "three-a.md — a file with 3 names, 2 of them in the vault; the other names are outside it: exported" "$TMP/out.txt" || miss="$miss [three-a.md not named]"
grep -qxF "sub/three-b.md — a file with 3 names, 2 of them in the vault; the other names are outside it: exported" "$TMP/out.txt" || miss="$miss [three-b.md not named]"
grep -qxF "sym-target.md — a file with 2 names, 1 of them in the vault; the other names are outside it: exported" "$TMP/out.txt" || miss="$miss [sym-target.md not named]"
grep -qE '^(in-a|in-b|sym-link)\.md ' "$TMP/out.txt" && miss="$miss [a file with all its names here, or a symlink, was named]"
[ "$(grep -c 'of them in the vault' "$TMP/out.txt")" = 4 ] || miss="$miss [not 4 lines: $(grep -c 'of them in the vault' "$TMP/out.txt")]"
grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
for n in out1.md three-a.md sub/three-b.md in-a.md in-b.md sym-target.md; do [ -f "$TMP/po32/out/$n" ] || miss="$miss [$n not exported]"; done
[ -z "$miss" ] && ok "S10-PO-32 a file with a name outside the vault is exported and named (names counted, a symlink and a file whose names are all here are not)" \
  || bad "S10-PO-32 hard link outside the vault" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-400)"
V="$TMP/po32b/vault"; note "$V" a.md "# A"; ln "$V/a.md" "$V/b.md"; note "$V" c.md "# C"
rc=$(run "$V" "$TMP/po32b/out")
{ [ "$rc" = 0 ] && ! grep -q 'of them in the vault' "$TMP/out.txt"; } \
  && ok "S10-PO-32b a vault whose hard links all stay inside it exits 0 with no warning" \
  || bad "S10-PO-32b hard links inside" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-20b: the file identity is (device, inode), not the inode alone: inode numbers repeat across devices, and a vault can hold
# a mount. Timed through the module with os.lstat answering that the hidden file lives on another device: not refused; on the same
# device it is. (A hard link cannot cross devices, so a real second device cannot be built without a mount.)
V="$TMP/po20b/vault"; mkdir -p "$V/.hidden"; printf 'HIDDENSECRET\n' > "$V/.hidden/h.md"; ln "$V/.hidden/h.md" "$V/peek.md"
"$REALPY" - "$EXPORT" "$V" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, os, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
vault, files = Path(sys.argv[2]), [Path("peek.md")]
print("same device:", mod.hidden_hard_links(vault, files))
real = os.lstat
def other_device(path, *a, **k):
    r = real(path, *a, **k)
    return os.stat_result((r.st_mode, r.st_ino, r.st_dev + 1, r.st_nlink, r.st_uid, r.st_gid, r.st_size, r.st_atime, r.st_mtime, r.st_ctime)) if ".hidden" in str(path) else r
os.lstat = other_device
other = mod.hidden_hard_links(vault, files)
print("other device:", other)
sys.exit(0 if other == [] else 1)
PY
rc=$?
{ [ "$rc" = 0 ] && grep -q '^same device: \[(PosixPath' "$TMP/out.txt"; } \
  && ok "S10-PO-20b the same inode on another device is not a hard link to the hidden file (the key is device and inode)" \
  || bad "S10-PO-20b device in the key" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-21: a folder that cannot be listed hides what is in it, and a listing that swallows the error says nothing. 21a: a visible
# file with a second name while a dot folder cannot be listed (mode 0300) may be a hard link to a file in it: refused and named, the
# folder named, not shipped. 21b: a visible folder that cannot be listed is named (its notes are not exported), exit 1. 21c: an
# unlistable dot folder with no file that has a second name loses nothing: exit 0, no line. 21d: a visible file that is gone when
# the hard-link check looks at it is named, not a traceback. The mode is restored by the EXIT trap at the top. Not as root.
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP  S10-PO-21 a folder that cannot be listed: root lists it anyway\n'
else
  V="$TMP/po21/vault"; mkdir -p "$V/.priv" "$V/pub"
  printf 'HIDDENSECRET\n' > "$V/.priv/h.md"; ln "$V/.priv/h.md" "$V/peek.md"; note "$V" ok.md "# Ok"; note "$V" pub/in.md "# In"
  chmod 0300 "$V/.priv" "$V/pub"
  rc=$(run "$V" "$TMP/po21/out"); chmod 0700 "$V/.priv" "$V/pub"
  miss=""
  [ "$rc" = 1 ] || miss="$miss rc=$rc"
  grep -rqF HIDDENSECRET "$TMP/po21/out" && miss="$miss [hidden content shipped]"
  grep -q '^peek.md — a file with more than one name, while the folder \.priv cannot be listed or entered to rule out a hard link to a hidden file: skipped$' "$TMP/out.txt" || miss="$miss [peek.md not named with the folder]"
  grep -q '^pub — a folder that cannot be listed.*: skipped$' "$TMP/out.txt" || miss="$miss [pub not named]"
  grep -q 'Traceback' "$TMP/out.txt" && miss="$miss [traceback]"
  grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
  [ -f "$TMP/po21/out/ok.md" ] || miss="$miss [ok.md not exported]"
  [ -z "$miss" ] && ok "S10-PO-21a/b an unlistable dot folder refuses a file with a second name, an unlistable visible folder is named; both exit 1" \
    || bad "S10-PO-21a/b unlistable folders" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
  V="$TMP/po21c/vault"; mkdir -p "$V/.priv"; printf 'x\n' > "$V/.priv/h.md"; note "$V" ok.md "# Ok"; chmod 0300 "$V/.priv"
  rc=$(run "$V" "$TMP/po21c/out"); chmod 0700 "$V/.priv"
  { [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ] && [ -f "$TMP/po21c/out/ok.md" ]; } \
    && ok "S10-PO-21c an unlistable dot folder with no file that has a second name loses nothing: exit 0, no line" \
    || bad "S10-PO-21c unlistable dot folder, no hard link" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-200)"
fi
V="$TMP/po21d/vault"; mkdir -p "$V"; note "$V" ok.md "# Ok"
"$REALPY" - "$EXPORT" "$V" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
got = mod.hidden_hard_links(Path(sys.argv[2]), [Path("gone.md"), Path("ok.md")])
print(got)
sys.exit(0 if [rel for rel, _ in got] == [Path("gone.md")] else 1)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-21d a visible file that is gone when the hard-link check looks at it is named, not a traceback" \
  || bad "S10-PO-21d vanished file" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt" | cut -c1-300)"

# S10-PO-22: a folder that lists but cannot be entered (mode 0400) made the file listing stop with a PermissionError traceback that
# printed host paths, and exit 1. 22a: a visible one is named once, with its sub-folders not named again; nothing is exported from
# it; no traceback, no host path, exit 1. 22b: under a dot name it is left out like any dot folder: exit 0, no line, no traceback.
# 22c: with a file that has a second name, it is refused and named with that folder (as for a folder that cannot be listed), and the
# hidden content does not ship. Not as root; the mode is restored here and by the EXIT trap.
if [ "$(id -u)" = 0 ]; then
  printf '  SKIP  S10-PO-22 a folder that cannot be entered: root enters it anyway\n'
else
  V="$TMP/po22/vault"; mkdir -p "$V/pub/sub"; note "$V" ok.md "# Ok"; note "$V" pub/a.md "# A"; note "$V" pub/sub/b.md "# B"
  chmod 0400 "$V/pub"; rc=$(run "$V" "$TMP/po22/out"); chmod 0700 "$V/pub"
  miss=""
  [ "$rc" = 1 ] || miss="$miss rc=$rc"
  grep -q '^pub — a folder that cannot be entered: its files are not exported: skipped$' "$TMP/out.txt" || miss="$miss [pub not named]"
  [ "$(grep -c '^pub' "$TMP/out.txt")" = 1 ] || miss="$miss [pub or a sub-folder named more than once]"
  grep -q 'Traceback' "$TMP/out.txt" && miss="$miss [traceback]"
  grep -qF "$TMP" "$TMP/out.txt" && miss="$miss [host path in the report]"
  [ -f "$TMP/po22/out/ok.md" ] && [ ! -e "$TMP/po22/out/pub" ] || miss="$miss [ok.md missing or pub exported]"
  [ -z "$miss" ] && ok "S10-PO-22a a visible folder that cannot be entered is named once (exit 1), no traceback, no host path" \
    || bad "S10-PO-22a unenterable folder" "$miss | $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
  V="$TMP/po22b/vault"; mkdir -p "$V/.priv"; printf 'HIDDENSECRET\n' > "$V/.priv/h.md"; note "$V" ok.md "# Ok"
  chmod 0400 "$V/.priv"; rc=$(run "$V" "$TMP/po22b/out"); chmod 0700 "$V/.priv"
  { [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ] && [ -f "$TMP/po22b/out/ok.md" ]; } \
    && ok "S10-PO-22b a dot folder that cannot be entered is left out like any dot folder: exit 0, no line, no traceback" \
    || bad "S10-PO-22b unenterable dot folder" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
  V="$TMP/po22c/vault"; mkdir -p "$V/.priv"; printf 'HIDDENSECRET\n' > "$V/.priv/h.md"; ln "$V/.priv/h.md" "$V/peek.md"; note "$V" ok.md "# Ok"
  chmod 0400 "$V/.priv"; rc=$(run "$V" "$TMP/po22c/out"); chmod 0700 "$V/.priv"
  { [ "$rc" = 1 ] && grep -q '^peek.md — .*\.priv cannot be listed or entered .*: skipped$' "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt" \
      && ! grep -rqF HIDDENSECRET "$TMP/po22c/out" && [ -f "$TMP/po22c/out/ok.md" ]; } \
    && ok "S10-PO-22c a file with a second name is refused and named while a dot folder cannot be entered; nothing hidden ships" \
    || bad "S10-PO-22c unenterable dot folder, second name" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
fi

# S10-PO-22d: a file whose stat fails in a folder access() calls enterable (NFS root_squash, FUSE, a privacy block) is not dropped
# in silence: it is named "a file that could not be examined (<reason>)", not exported, exit 1. Driven through the module with
# os.stat raising PermissionError for one name (Path.is_file() answers False for that since Python 3.14, so the module asks okf_guard);
# a folder that cannot be entered is still named once, not per file.
V="$TMP/po22d/vault"; mkdir -p "$V"; note "$V" ok.md "# Ok"; note "$V" flaky.md "# Flaky"
"$REALPY" - "$EXPORT" "$V" "$TMP/po22d/out" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, io, pathlib, sys
from contextlib import redirect_stdout
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
import os
real = os.stat
def flaky(path, *a, **k):
    if str(path).endswith("flaky.md"):
        raise PermissionError(13, "Permission denied", str(path))
    return real(path, *a, **k)
os.stat = flaky
out = pathlib.Path(sys.argv[3])
sys.argv = ["okf-export", sys.argv[2], sys.argv[3]]
buf = io.StringIO()
with redirect_stdout(buf):
    rc = mod.main()
os.stat = real   # the checks below ask Path.exists(), which raises on 3.10 to 3.13 for the name made to fail
print(buf.getvalue(), end="")
ok = rc == 1 and "flaky.md — a file that could not be examined (Permission denied): skipped" in buf.getvalue().splitlines() \
    and not (out / "flaky.md").exists() and (out / "ok.md").exists()
sys.exit(0 if ok else 1)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-22d a file whose stat fails in an enterable folder is named 'could not be examined' (exit 1) and not exported" \
  || bad "S10-PO-22d stat fails" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt" | cut -c1-300)"
# S39-PY: Python 3.14 stopped raising from Path.exists(), is_dir() and is_file() (a permission error is a plain False there). A vault or
# an output folder under a folder nobody may enter is said to be unreadable, never "not a folder", on every Python. Run as the Python in use
# is, and with those predicates forced to answer False for an OSError (a sitecustomize on PYTHONPATH), so 3.9 and 3.12 prove the 3.14 behaviour.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$TMP/py314"
  cat > "$TMP/py314/sitecustomize.py" <<'PYEOF'
import pathlib
def _quiet(f):
    def g(self, *a, **k):
        try:
            return f(self, *a, **k)
        except OSError:
            return False
    return g
for _n in ("exists", "is_dir", "is_file"):
    setattr(pathlib.Path, _n, _quiet(getattr(pathlib.Path, _n)))
PYEOF
  mkdir -p "$TMP/py39/lk/vault" "$TMP/py39/v2" "$TMP/py39/lk2"; note "$TMP/py39/lk/vault" a.md "# A"; note "$TMP/py39/v2" b.md "# B"
  py_export() { # <label>
    local lbl="$1" rc
    chmod 000 "$TMP/py39/lk"; rc=$(run "$TMP/py39/lk/vault" "$TMP/py39/o1"); chmod 755 "$TMP/py39/lk"
    { [ "$rc" = 2 ] && grep -q 'lk/vault cannot be read: Permission denied' "$TMP/out.txt" && ! grep -q 'Traceback\|not a folder' "$TMP/out.txt"; } \
      && ok "S39-PY-06 $lbl: a vault under a folder nobody may enter is 'cannot be read' (exit 2), not 'not a folder' and no traceback" \
      || bad "S39-PY-06 $lbl" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
    chmod 000 "$TMP/py39/lk2"; rc=$(run "$TMP/py39/v2" "$TMP/py39/lk2/out"); chmod 755 "$TMP/py39/lk2"
    { [ "$rc" = 2 ] && grep -q 'cannot write to .*lk2/out: Permission denied' "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt"; } \
      && ok "S39-PY-07 $lbl: an output under a folder nobody may enter is 'cannot write to' (exit 2), no traceback" \
      || bad "S39-PY-07 $lbl" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
    mkdir -p "$TMP/py39/out0"; chmod 000 "$TMP/py39/out0"; rc=$(run "$TMP/py39/v2" "$TMP/py39/out0"); chmod 755 "$TMP/py39/out0"
    { [ "$rc" = 2 ] && grep -q "^okf-export: cannot write to .*py39/out0: Permission denied" "$TMP/out.txt" && ! grep -q Traceback "$TMP/out.txt"; } \
      && ok "S39-PY-13 $lbl: an existing output folder nobody may enter is 'cannot write to' (exit 2), no traceback (it was a traceback and exit 1, the 'files skipped' exit)" \
      || bad "S39-PY-13 $lbl" "rc=$rc $(tr '\n' ' ' < "$TMP/out.txt" | cut -c1-300)"
  }
  py_export "as run"
  PYTHONPATH="$TMP/py314${PYTHONPATH:+:$PYTHONPATH}" py_export "with Path predicates that answer False for an OSError (3.14 behaviour)"
else
  printf '  SKIP  S39-PY a folder nobody may enter: root enters it anyway\n'
fi
# S10-PO-23: a code span in a wikilink alias. CommonMark binds a code span tighter than a link (markdown-it-py 3.0.0 and
# commonmark.py 0.9.1 render `[`c`](b.md)` as a link whose text holds <code>, and `[[b|`c`]]` as plain text around <code>),
# so a span wholly inside the alias is part of the new link text (20a). A link inside a span, or one a span cuts through
# (starts or ends inside it), is no link for Obsidian either and stays as written (20b, 20c); none of them is a problem.
V="$TMP/po23/vault"
note "$V" b.md "# B"
note "$V" a.md '[[b|`code`]] and [[b|x `c` y]] and [[b]] and [[b#B|`h`]]'
rc=$(run "$V" "$TMP/po23/out")
want='[`code`](b.md) and [x `c` y](b.md) and [b](b.md) and [`h`](b.md#b)'
{ [ "$rc" = 0 ] && grep -qFx -- "$want" "$TMP/po23/out/a.md"; } \
  && ok "S10-PO-23a a code span inside a wikilink alias is kept in the link text (rc 0, no raw [[ ]] left)" \
  || bad "S10-PO-23a alias with a code span" "rc=$rc want line: $want | got: $(tail -1 "$TMP/po23/out/a.md" 2>/dev/null)"
note "$V" a.md '`[[b]]` and `x [[b|c]] y`'
rc=$(run "$V" "$TMP/po23/out2")
{ [ "$rc" = 0 ] && grep -qFx -- '`[[b]]` and `x [[b|c]] y`' "$TMP/po23/out2/a.md"; } \
  && ok "S10-PO-23b a wikilink inside a code span stays as written" \
  || bad "S10-PO-23b link inside a span" "rc=$rc got: $(tail -1 "$TMP/po23/out2/a.md" 2>/dev/null)"
note "$V" a.md '`x [[b|` y]] and [[b `c]] d` and [[b|a `c]] e `f`'
rc=$(run "$V" "$TMP/po23/out3")
{ [ "$rc" = 0 ] && grep -qFx -- '`x [[b|` y]] and [[b `c]] d` and [[b|a `c]] e `f`' "$TMP/po23/out3/a.md"; } \
  && ok "S10-PO-23c a wikilink that a code span cuts through (its start or its end inside the span) stays as written" \
  || bad "S10-PO-23c span across a link end" "rc=$rc got: $(tail -1 "$TMP/po23/out3/a.md" 2>/dev/null)"
# 20d, 20e: a backslash escapes a backtick outside a code span (CommonMark 6.1), so in ``\`` `` only a one-backtick run is left
# to open a span. 20d: in `\`` y [[b|`c`]]` the span is "` y [[b|`", the link starts inside it, so it is no link and stays as
# written (both renderers find 0 links there). 20e: `\`[[b|`c`]]` has no span before the link, so it converts.
note "$V" a.md 'p x \`` y [[b|`c`]]'
rc=$(run "$V" "$TMP/po23/out4")
{ [ "$rc" = 0 ] && grep -qFx -- 'p x \`` y [[b|`c`]]' "$TMP/po23/out4/a.md"; } \
  && ok "S10-PO-23d an escaped backtick opens no span: the link inside the span the escape leaves stays as written" \
  || bad "S10-PO-23d escaped backtick before a span" "rc=$rc got: $(tail -1 "$TMP/po23/out4/a.md" 2>/dev/null)"
note "$V" a.md 'p \`[[b|`c`]]'
rc=$(run "$V" "$TMP/po23/out5")
{ [ "$rc" = 0 ] && grep -qFx -- 'p \`[`c`](b.md)' "$TMP/po23/out5/a.md"; } \
  && ok "S10-PO-23e a link after an escaped backtick, with no span before it, is rewritten and keeps its span" \
  || bad "S10-PO-23e escaped backtick then a link" "rc=$rc got: $(tail -1 "$TMP/po23/out5/a.md" 2>/dev/null)"
# 23f..h: only the alias SEPARATOR is unescaped (a table cell writes it as \|); every later \| in the alias stays as written.
# 23f: in a paragraph, `\|` inside an alias code span is literal text there, so the code text must not change. 23g, 23h: in a
# table row the output cell must stay one cell (a bare | would split it), with the alias in a code span and outside one.
note "$V" a.md 'p [[b#B|`\|`y`x]]'
rc=$(run "$V" "$TMP/po23/out6")
{ [ "$rc" = 0 ] && grep -qFx -- 'p [`\|`y`x](b.md#b)' "$TMP/po23/out6/a.md"; } \
  && ok "S10-PO-23f a \\| inside an alias code span stays as written (the code text does not change)" \
  || bad "S10-PO-23f bar in an alias span" "rc=$rc got: $(tail -1 "$TMP/po23/out6/a.md" 2>/dev/null)"
note "$V" a.md '| h | k |
|---|---|
| [[b\|`a\|b`]] | k |
| [[b\|a\|b]] | k |
| [[b\|x]] | k |'
rc=$(run "$V" "$TMP/po23/out7")
{ [ "$rc" = 0 ] && grep -qFx -- '| [`a\|b`](b.md) | k |' "$TMP/po23/out7/a.md"; } \
  && ok "S10-PO-23g a table cell [[b\\|\`a\\|b\`]] becomes one cell with the bar still escaped inside the span" \
  || bad "S10-PO-23g table cell, bar in an alias span" "rc=$rc got: $(grep -F '(b.md)' "$TMP/po23/out7/a.md" 2>/dev/null | tr '\n' '~')"
{ [ "$rc" = 0 ] && grep -qFx -- '| [a\|b](b.md) | k |' "$TMP/po23/out7/a.md" && grep -qFx -- '| [x](b.md) | k |' "$TMP/po23/out7/a.md"; } \
  && ok "S10-PO-23h a table cell [[b\\|a\\|b]] keeps the later bar escaped, so the row keeps its cells; [[b\\|x]] is unchanged in effect" \
  || bad "S10-PO-23h table cell, bar outside a span" "rc=$rc got: $(grep -F '(b.md)' "$TMP/po23/out7/a.md" 2>/dev/null | tr '\n' '~')"

# S10-PO-24: one very long line of '>' markers is read in one pass, not once per nesting level. Timed in memory through the
# module (no file is written). 21a: a 1 000 000 byte line of '>' raises TooDeep (as before) in under 1 s (it took 6.6 s on
# a quiet machine, 33 s at the 5 MB note cap, because each of the 100 nested reads matched and sliced the whole line). 21b: the
# cut-off did not move: 100 markers are read (no TooDeep), 101 are not, at the top level, behind a list marker and in a
# quote that is already one level deep.
"$REALPY" - "$EXPORT" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
def deep(lines):
    try:
        list(mod.body_lines(lines))
        return False
    except mod.TooDeep:
        return True
bad = []
t = time.perf_counter()
got = deep([">" * 1_000_000, "after"])
took = time.perf_counter() - t
print("1 MB '>' line: TooDeep=%s %.3f s" % (got, took))
# wallclock-ok: linear takes about 0.06 s here (measured 2026-10-22) for the 1 MB line, 16 times under the 1 s bound; the quadratic reader took 33 s at the 5 MB cap
if not got or took > 1:
    bad.append("1 MB line: TooDeep=%s %.1f s (want True, under 1 s)" % (got, took))
for name, prefix, markers, want in [("top 100", "", 100, False), ("top 101", "", 101, True),
                                    ("item 100", "- ", 100, False), ("item 101", "- ", 101, True),
                                    ("quote+99", "> ", 99, False), ("quote+100", "> ", 100, True)]:
    got = deep([prefix + ">" * markers + " x", "after"])
    print("%-10s TooDeep=%s" % (name, got))
    if got != want:
        bad.append("%s: TooDeep=%s want %s" % (name, got, want))
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-24 a 1 MB line of '>' ends in TooDeep in under 1 s, and the 100-level cut-off is unchanged (top level, in a list item, in a quote)" \
  || bad "S10-PO-24 early TooDeep" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt")"

# S10-PO-25: the two texts a user reads, the README and the plugin's SKILL.md, say what the export reads in block quotes
# since BL-884 and D23-a: setext headings are headings and raw HTML is copied unchanged, inside block quotes too; the old
# limit sentence is gone. The README sits above the plugin folder: a copy of the plugin alone has none, shown as a SKIP.
for doc in "$HERE/../skills/okf/SKILL.md" "$HERE/../../README.md"; do
  if [ ! -f "$doc" ]; then printf '  SKIP  S10-PO-25 %s not found\n' "$(basename "$doc")"; continue; fi
  { ! grep -qF 'a setext heading inside a block quote is not recognised' "$doc" && ! grep -qF 'outside block quotes' "$doc" \
    && [ "$(grep -cF 'inside block quotes too' "$doc")" -ge 2 ]; } \
    && ok "S10-PO-25 $(basename "$doc") says setext headings and raw HTML are read inside block quotes too (BL-884, D23-a), no old limit" \
    || bad "S10-PO-25 $(basename "$doc")" "the old setext-in-quote or HTML-outside-quotes limit is still stated, or 'inside block quotes too' is missing for headings and raw HTML"
done

# S10-PO-33: CommonMark 0.31.2 reads no link in a code span that wraps onto the next line (6.1), in an autolink (6.5) or in
# inline raw HTML: a tag, a comment (6.6). Each [[b]] there stays as written, and the [[b]] in plain text on the same
# lines is still rewritten.
V="$TMP/po33/vault"; note "$V" b.md "# B"
note "$V" a.md 'Span `start
[[b]] end` here [[b]].

A <https://x.test/[[b]]> [[b]].

T <span title="[[b]]">t</span> [[b]].

C <!-- [[b]] --> [[b]].'
rc=$(run "$V" "$TMP/po33/out")
miss=""
for want in '[[b]] end` here [b](b.md).' 'A <https://x.test/[[b]]> [b](b.md).' 'T <span title="[[b]]">t</span> [b](b.md).' 'C <!-- [[b]] --> [b](b.md).'; do
  grep -qFx -- "$want" "$TMP/po33/out/a.md" 2>/dev/null || miss="$miss [want: $want]"
done
{ [ "$rc" = 0 ] && [ -z "$miss" ]; } \
  && ok "S10-PO-33 a [[b]] in a code span over two lines, an autolink, an HTML tag or an HTML comment stays as written; one beside them is rewritten" \
  || bad "S10-PO-33 code span over lines, autolink, inline HTML" "rc=$rc$miss | got: $(tr '\n' '~' < "$TMP/po33/out/a.md" 2>/dev/null | cut -c1-400)"

# S10-PO-35: a line that looks like a GFM delimiter row starts a table only when its cell count equals the header row's
# (GFM 0.29, 4.10). `|-|` under a 3-cell row is paragraph text, so the code span from `x runs to the backtick after [[b]]
# and the link stays as written. A matching delimiter row still makes a table, read row by row: the link there is rewritten.
V="$TMP/po35/vault"; note "$V" b.md "# B"
note "$V" a.md 'a `x | y | z
|-|
[[b]]`'
note "$V" t.md 'a `x | y | z
|-|-|-|
[[b]]` | q | r'
rc=$(run "$V" "$TMP/po35/out")
{ [ "$rc" = 0 ] && grep -qFx -- '[[b]]`' "$TMP/po35/out/a.md" && grep -qFx -- '[b](b.md)` | q | r' "$TMP/po35/out/t.md"; } \
  && ok "S10-PO-35 a delimiter-like row whose cell count differs from the header is no table: the code span over it keeps [[b]]; a matching one is a table" \
  || bad "S10-PO-35 delimiter cell count" "rc=$rc a: $(tail -1 "$TMP/po35/out/a.md" 2>/dev/null) | t: $(tail -1 "$TMP/po35/out/t.md" 2>/dev/null)"

# S10-PO-34: a paragraph is read as one text, so one paragraph of about 1 MB must still cost linear time: unclosed openers
# of every kind (backticks, a comment, a processing instruction, CDATA, a declaration, a tag, an autolink), backtick runs
# of 1 to 3 (the densest shape: it is timed at 3 MB and 24 MB, so its base time, about 0.6 s here, sits well above the
# 0.25 s floor and a slowdown cannot hide under it), tags with no '>', closed items, and one code span over 60 000 lines.
# The bound is a RATIO, as 26g: 8 times the size costs at most 24 times as much plus 0.25 s (best of 3), with a quadratic
# control that must be caught. The 60 000-line span must also cover every line in it, and only those.
"$REALPY" - "$EXPORT" >"$TMP/out.txt" 2>&1 <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
def read(lines):
    joins = set()
    rows = list(mod.body_lines(lines, joins=joins))
    return mod.raw_ranges(lines, rows, joins)
def fill(unit):
    return lambda n: [unit] * (n // len(unit))
shapes = {"unclosed openers": fill("a `b ``c <!-- <? <![CDATA[ <!X <a x=\"y <http://q [[b]]\n"),
          "backtick runs 1-3": fill("".join("`" * (k % 3 + 1) + " " for k in range(60)) + "\n"),
          "tags with no >": fill("<a b c d e f g h i j k l m n o p q r s t u v w x y z\n"),
          "closed items": fill("`x` <b>y</b> <!-- z --> <http://a.b> [[b]]\n"),
          "one span": lambda n: ["`open\n"] + ["text [[b]] more\n"] * (n // 16) + ["close`\n"]}
def best(fn, lines):
    runs = []
    for _ in range(3):
        t = time.perf_counter(); fn(lines); runs.append(time.perf_counter() - t)
    return min(runs)
def too_slow(fn, make, small, big):
    t1, t8 = best(fn, make(small)), best(fn, make(big))
    return t8 > 24 * t1 + 0.25, t1, t8
def quadratic(lines):
    for i in range(len(lines)): lines[:i].count("x")
caught, c1, c8 = too_slow(quadratic, lambda n: ["l"] * n, 3000, 24000)
print("control quadratic  %.3f s -> %.3f s  %s" % (c1, c8, "caught" if caught else "NOT CAUGHT"))
bad = [] if caught else ["the quadratic control was not caught"]
base = {"backtick runs 1-3": 3 * 1024 * 1024}   # bytes; every other shape starts at 128 KB
for name, make in shapes.items():
    small = base.get(name, 128 * 1024)
    flag, t1, t8 = too_slow(read, make, small, 8 * small)
    print("%-18s %.3f s -> %.3f s" % (name, t1, t8))
    if flag:
        bad.append("%s %.2f s -> %.2f s" % (name, t1, t8))
lines = shapes["one span"](1024 * 1024)
got = read(lines)
if sorted(got) != list(range(len(lines))):
    bad.append("one span: %d of %d lines covered" % (len(got), len(lines)))
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" = 0 ] && ok "S10-PO-34 a 1 MB paragraph (unclosed openers, backtick runs of 1-3 at 24 MB, open tags, closed items, one span over 60 000 lines) costs linear time: 8 times the size at most 24 times as much plus 0.25 s (a quadratic control is caught)" \
  || bad "S10-PO-34 1 MB paragraph" "rc=$rc $(tr '\n' ';' < "$TMP/out.txt")"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
