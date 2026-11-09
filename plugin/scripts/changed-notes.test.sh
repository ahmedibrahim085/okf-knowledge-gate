#!/usr/bin/env bash
# Tests for okf-check's changed-notes mode, `okf-check <bundle> --changed <git-ref>`: the note-local checks on every
# note changed since a ref. The mode needs git >= 2.40 (GIT_ATTR_SOURCE, the attribute hardening), so this
# suite is macOS-only in the gates (tools/linux-gate.conf): stock Debian 12 ships git 2.39.5 and bookworm-backports
# carries no newer git (checked 2026-11-08); on an older git the whole suite skips, per case, in the summary.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
REALPY=$(command -v python3)
PASS=0; FAIL=0; SKIPS=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfchanged)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

hclean() { # <path> — a complete Lesson note: no L1 warning and no house-profile finding
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: stable\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$1"
}

# --changed requires git >= 2.40 and refuses on older git, so this suite skips there, counted per case: a skipped
# run is M cases the gate never ran, and a gate's skip ceiling judges M. The count is the suite's ok call sites, so
# every case stays a flat ok call (no loops here); the pattern is spelled with a character class so this line does
# not count itself.
gitver=$(git --version 2>/dev/null | awk '{print $3}')
if [[ "$gitver" =~ ^[0-9]+\.[0-9]+ ]]; then
  GIT40=$(awk -v v="$gitver" 'BEGIN { split(v, a, "."); print (a[1]+0 > 2 || (a[1]+0 == 2 && a[2]+0 >= 40)) ? 1 : 0 }')
else
  GIT40=0
fi
if [ "$GIT40" != 1 ]; then
  printf '  SKIP  %s\n' "changed-notes-mode all cases — this git is ${gitver:-unknown}, older than 2.40 (GIT_ATTR_SOURCE unsupported); okf-check refuses --changed here"
  SECTION_CASES=$(grep -cE '[&][&] ok "changed-notes-mode-' "$0")
  SKIPS=$((SKIPS + SECTION_CASES))
else

g() { HOME="$TMP/okf-git-home" GIT_CONFIG_NOSYSTEM=1 git -c credential.helper= "$@"; }
gbundle() { # <dir> — a git repository holding a complete, listed note and a right declared count, one commit
  rm -rf "$TMP/okf-git-home"; mkdir -p "$TMP/okf-git-home"
  rm -rf "$1"; mkdir -p "$1"
  g -C "$1" init -q
  g -C "$1" config user.name probe; g -C "$1" config user.email probe@probe
  printf -- '---\nokf_version: "0.2"\n---\n' > "$1/index.md"; printf -- '# Log\n' > "$1/log.md"
  hclean "$1/a.md"
  printf -- '**1 concepts.**\n\n- [a](a.md)\n' >> "$1/index.md"
  g -C "$1" add -A; g -C "$1" commit -qm base
}
gcommit() { g -C "$1" add -A; g -C "$1" commit -qm "$2"; }
gprofile() { sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"; }
badfm() { printf -- '---\ntype: measurement\ntitle: T\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$1"; }
gcount() { local n="$1" d="$2" l; shift 2; printf -- '---\nokf_version: "0.2"\n---\n\n**%s concepts.**\n\n' "$n" > "$d/index.md"; for l in "$@"; do printf -- '%s\n' "$l" >> "$d/index.md"; done; }

# happy-1: the public issue's repro, through a plain file write and a commit (no edit hook involved).
C1="$TMP/ch-h1"; gbundle "$C1"; gprofile "$C1"; gcommit "$C1" rules
badfm "$C1/b.md"; gcount 1 "$C1" '- [a](a.md)'
gcommit "$C1" "add b"
"$CHECK" "$C1" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && grep -qxF 'index.md: L2 index error: index.md claims 1 concepts; 2 on disk' "$TMP/out.txt" \
  && ! grep -q 'not listed' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-happy-1 a committed note written outside any hook: the F101 line and the count line, exit 3" \
  || bad "changed-notes-mode-happy-1" "rc=$rc out: $(head -4 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# happy-2: a staged note against HEAD, as a commit hook sees it.
C2="$TMP/ch-h2"; gbundle "$C2"; gprofile "$C2"; gcommit "$C2" rules
badfm "$C2/b.md"; g -C "$C2" add b.md
"$CHECK" "$C2" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && grep -q 'claims 1 concepts; 2 on disk' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-happy-2 a staged note against HEAD is checked (a commit hook)" \
  || bad "changed-notes-mode-happy-2" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# happy-3: changed complete notes with the count right: nothing.
C3="$TMP/ch-h3"; gbundle "$C3"; gprofile "$C3"; gcommit "$C3" rules
hclean "$C3/b.md"; gcount 2 "$C3" '- [a](a.md)' '- [b](b.md)'
gcommit "$C3" "add b"
"$CHECK" "$C3" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-happy-3 changed complete notes with a matching count: nothing, exit 0" \
  || bad "changed-notes-mode-happy-3" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# negative-1: an unchanged note's finding is not reported (the scoping promise).
C4="$TMP/ch-n1"; gbundle "$C4"; gprofile "$C4"; gcommit "$C4" rules
printf -- '---\ntype: nope\ntitle: T\ndescription: D\ntags: [t]\n---\nbody\n' > "$C4/z.md"
gcount 2 "$C4" '- [a](a.md)' '- [z](z.md)'
gcommit "$C4" "broken z from the start"
printf -- 'data\n' > "$C4/data.txt"; gcommit "$C4" "touch data"
"$CHECK" "$C4" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-negative-1 a note that did not change is not read" \
  || bad "changed-notes-mode-negative-1" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# negative-2: an unknown ref.
C5="$TMP/ch-n2"; gbundle "$C5"
"$CHECK" "$C5" --changed no-such-ref >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'no-such-ref' "$TMP/err.txt" && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-negative-2 an unknown ref is exit 2 and names it" \
  || bad "changed-notes-mode-negative-2" "rc=$rc err='$(head -2 "$TMP/err.txt")'"

# negative-3: outside any git repository.
C6="$TMP/ch-n3"; rm -rf "$C6"; mkdir -p "$C6"; printf -- '---\nokf_version: "0.2"\n---\n' > "$C6/index.md"; printf -- '# Log\n' > "$C6/log.md"; hclean "$C6/a.md"
"$CHECK" "$C6" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'git' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-negative-3 a bundle outside any git repository is exit 2" \
  || bad "changed-notes-mode-negative-3" "rc=$rc err='$(head -2 "$TMP/err.txt")'"

# edge-1/edge-2: a deleted note and the declared count.
C8="$TMP/ch-e1"; gbundle "$C8"; gprofile "$C8"; gcommit "$C8" rules; rm -f "$C8/a.md"
printf -- '---\nokf_version: "0.2"\n---\n\n**0 concepts.**\n' > "$C8/index.md"; gcommit "$C8" "drop a"
"$CHECK" "$C8" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-1 a deleted note with the count lowered: nothing, exit 0" \
  || bad "changed-notes-mode-edge-1" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"
C9="$TMP/ch-e2"; gbundle "$C9"; gprofile "$C9"; gcommit "$C9" rules; rm -f "$C9/a.md"; gcommit "$C9" "drop a"
"$CHECK" "$C9" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -qxF 'index.md: L2 index error: index.md claims 1 concepts; 0 on disk' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-2 a deleted note with the count unchanged: the count line, exit 3" \
  || bad "changed-notes-mode-edge-2" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"

# edge-3 (amended): a renamed note is checked under its NEW name only; the count matches, so no count line.
C10="$TMP/ch-e3"; gbundle "$C10"; gprofile "$C10"; gcommit "$C10" rules
badfm "$C10/b.md"; gcount 2 "$C10" '- [a](a.md)' '- [b](b.md)'
gcommit "$C10" "add b"; g -C "$C10" mv b.md b2.md
gcount 2 "$C10" '- [a](a.md)' '- [b2](b2.md)'
gcommit "$C10" "rename b"
"$CHECK" "$C10" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && [ "$(grep -c 'L2 profile error' "$TMP/out.txt")" = 1 ] && grep -q '^b2\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && ! grep -q 'claims' "$TMP/out.txt" && ! grep -q '^b\.md' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-3 a renamed note is checked under its new name only (amended: no not-listed, no count line)" \
  || bad "changed-notes-mode-edge-3" "rc=$rc out: $(head -4 "$TMP/out.txt" | tr '\n' '|')"

# edge-4 (decision 2): only non-markdown and the house profile changed: nothing, even with a stale count.
C11="$TMP/ch-e4"; gbundle "$C11"; gprofile "$C11"; gcommit "$C11" rules
printf -- 'data\n' > "$C11/data.txt"; printf -- '# x\n' >> "$C11/okf-base.yaml"; gcommit "$C11" "data"
"$CHECK" "$C11" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-4 a non-markdown change leaves a stale count unreported (decision 2)" \
  || bad "changed-notes-mode-edge-4" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"

# edge-5: a note never added to git is checked.
C12="$TMP/ch-e5"; gbundle "$C12"; gprofile "$C12"; gcommit "$C12" rules
badfm "$C12/new.md"
"$CHECK" "$C12" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^new\.md: L2 profile error: F101 ' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-5 an untracked new note is checked" \
  || bad "changed-notes-mode-edge-5" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"

# edge-6: the bundle is a sub-folder of the repository; a change outside it is not its business, one inside it is.
C13="$TMP/ch-e6-repo"; rm -rf "$C13"; mkdir -p "$C13/kb"; rm -rf "$TMP/okf-git-home"; mkdir -p "$TMP/okf-git-home"
g -C "$C13" init -q; g -C "$C13" config user.name probe; g -C "$C13" config user.email probe@probe
printf -- '---\nokf_version: "0.2"\n---\n' > "$C13/kb/index.md"; printf -- '# Log\n' > "$C13/kb/log.md"; hclean "$C13/kb/a.md"
printf -- '**1 concepts.**\n\n- [a](a.md)\n' >> "$C13/kb/index.md"
printf -- 'x\n' > "$C13/outside.txt"; g -C "$C13" add -A; g -C "$C13" commit -qm base
printf -- 'y\n' > "$C13/outside.txt"; g -C "$C13" commit -qm change-outside -a
"$CHECK" "$C13/kb" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-6 a change outside the bundle folder is not the bundle's business" \
  || bad "changed-notes-mode-edge-6" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"
gprofile "$C13/kb"; badfm "$C13/kb/b.md"
g -C "$C13" add kb/b.md kb/okf-base.yaml; g -C "$C13" commit -qm add-b
"$CHECK" "$C13/kb" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-6b a sub-folder bundle checks its own changed notes by bundle-relative paths" \
  || bad "changed-notes-mode-edge-6b" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# edge-7: a changed note .okfignore excludes: the not-checked line, exit 0.
C14="$TMP/ch-e7"; gbundle "$C14"; gprofile "$C14"; gcommit "$C14" rules; printf -- 'drafts/\n' > "$C14/.okfignore"; gcommit "$C14" ignore
mkdir -p "$C14/drafts"; badfm "$C14/drafts/wip.md"
"$CHECK" "$C14" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && grep -qxF 'drafts/wip.md: not checked (.okfignore excludes it)' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-7 a changed note .okfignore excludes prints the not-checked line, exit 0" \
  || bad "changed-notes-mode-edge-7" "rc=$rc out='$(head -2 "$TMP/out.txt")'"

# edge-8: nothing changed while the count could be stale: nothing (decision 2).
C15="$TMP/ch-e8"; gbundle "$C15"; gprofile "$C15"; gcommit "$C15" rules
"$CHECK" "$C15" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-8 nothing changed: silent even though the count could be stale" \
  || bad "changed-notes-mode-edge-8" "rc=$rc out='$(head -2 "$TMP/out.txt")'"

# edge-9: two changed notes, an L1 error and an undeclared type: both lines, exit 1.
C16="$TMP/ch-e9"; gbundle "$C16"; gprofile "$C16"; gcommit "$C16" rules
printf -- '---\ntitle: T\ndescription: D\ntags: [t]\n---\nbody\n' > "$C16/nt.md"
badfm "$C16/u.md"
gcount 3 "$C16" '- [a](a.md)' '- [nt](nt.md)' '- [u](u.md)'
gcommit "$C16" "two bad notes"
"$CHECK" "$C16" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 1 ] && grep -q '^nt\.md: L1 error: ' "$TMP/out.txt" && grep -q '^u\.md: L2 profile error: F101 ' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-9 the worst outcome wins: an L1 error and an undeclared type, exit 1" \
  || bad "changed-notes-mode-edge-9" "rc=$rc out: $(head -4 "$TMP/out.txt" | tr '\n' '|')"

# edge-10: --strict-trust is accepted; a Trust warning on a changed note exits 1.
C17="$TMP/ch-e10"; gbundle "$C17"; gcommit "$C17" base
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: draft\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nverified:\n  by: human:t\n  at: "2026-01-02"\n---\nb\n' > "$C17/t.md"
gcount 2 "$C17" '- [a](a.md)' '- [t](t.md)'
gcommit "$C17" "trust note"
"$CHECK" "$C17" --changed HEAD~1 --strict-trust >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 1 ] && grep -q 'Trust warning' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-10 --strict-trust accepted; a Trust warning on a changed note exits 1" \
  || bad "changed-notes-mode-edge-10" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|')"

# edge-11: the help lists --changed <git-ref>. (No producer into grep -q under pipefail: the help goes to a file first.)
"$CHECK" --help >"$TMP/help.txt" 2>&1
grep -q -- '--changed <git-ref>' "$TMP/help.txt" \
  && ok "changed-notes-mode-edge-11 the help lists --changed <git-ref>" \
  || bad "changed-notes-mode-edge-11" "no --changed line in --help"

# edge-12 (amended): a changed README.md is a note like any other — the not-listed check no longer exists.
C18="$TMP/ch-e12"; gbundle "$C18"; gprofile "$C18"; gcommit "$C18" rules; hclean "$C18/README.md"
gcount 2 "$C18" '- [a](a.md)'
gcommit "$C18" "readme"
"$CHECK" "$C18" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-12 a changed README.md is checked like any note (amended: no not-listed check)" \
  || bad "changed-notes-mode-edge-12" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# edge-13: the root index.md changed to carry upkeep: the R001 line, exit 3.
C19="$TMP/ch-e13"; gbundle "$C19"; gprofile "$C19"; gcommit "$C19" rules
printf -- '---\nokf_version: "0.2"\nupkeep: enforced\n---\n\n**1 concepts.**\n\n- [a](a.md)\n' > "$C19/index.md"
gcommit "$C19" "upkeep"
"$CHECK" "$C19" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q 'L2 profile error: R001' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-13 a changed root index.md carrying upkeep: the R001 line, exit 3" \
  || bad "changed-notes-mode-edge-13" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# edge-14: a committed type change makes the per-type count stale.
C20="$TMP/ch-e14"; gbundle "$C20"; gprofile "$C20"; gcommit "$C20" rules
reffm() { printf -- '---\ntype: Reference\ntitle: %s\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' "$1" > "$2"; }
reffm A "$C20/a.md"; reffm B "$C20/b.md"
printf -- '---\nokf_version: "0.2"\n---\n\n**2 concepts · 2 references.**\n\n- [a](a.md)\n- [b](b.md)\n' > "$C20/index.md"
gcommit "$C20" "two references"
printf -- '---\ntype: Lesson\ntitle: B\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$C20/b.md"
gcommit "$C20" "retype b"
"$CHECK" "$C20" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -qxF 'index.md: L2 index error: index.md claims 2 references; 1 on disk' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-14 a committed type change makes the per-type count stale: one line, exit 3" \
  || bad "changed-notes-mode-edge-14" "rc=$rc out: $(head -3 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt" | tr '\n' '|')"

# Amendment: the uncertain-note-set rule reaches --changed too. The F101 of the changed note still decides the exit
# (a reached verdict outranks a layer that could not run); the anomaly is named on stderr.
C21="$TMP/ch-anom"; gbundle "$C21"; gprofile "$C21"; gcommit "$C21" rules
badfm "$C21/b.md"; gcount 2 "$C21" '- [a](a.md)' '- [b](b.md)'
gcommit "$C21" "add b"
printf -- '---\ntype: measurement\ntitle: C\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$C21/c.md"
ln -s a.md "$C21/alias.md"
"$CHECK" "$C21" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^c\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && grep -q 'note(s) the full run refuses or aliases (first: alias.md)' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-anomalous: an anomalous note makes the counts not checked; the changed note's verdict stands (exit 3)" \
  || bad "changed-notes-mode-anomalous" "rc=$rc out='$(head -2 "$TMP/out.txt")' err='$(head -2 "$TMP/err.txt")'"

# My own attack, before any reviewer sees it (lead instruction): hostile refs and hostile diffs.
C22="$TMP/ch-attack"; gbundle "$C22"
"$CHECK" "$C22" --changed '-x' >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q '\-x' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-attack-dashref a ref that starts with '-' is resolved, not read as a flag (exit 2 unknown)" \
  || bad "changed-notes-mode-attack-dashref" "rc=$rc err='$(head -2 "$TMP/err.txt")'"
"$CHECK" "$C22" --changed 'HEAD workaround' >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
[ "$rc" = 2 ] && ok "changed-notes-mode-attack-spaceref a ref with a space is an unknown ref (exit 2)" \
  || bad "changed-notes-mode-attack-spaceref" "rc=$rc err='$(head -2 "$TMP/err.txt")'"
C23="$TMP/ch-oddnames"; gbundle "$C23"; gprofile "$C23"; gcommit "$C23" rules
ODD="od d #""1.md"   # spelled in two parts: a literal '' in code reads as a private ticket reference to the export scan
badfm "$C23/$ODD"; gcommit "$C23" "odd name"
"$CHECK" "$C23" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -qF "$ODD: L2 profile error: F101" "$TMP/out.txt"; } \
  && ok "changed-notes-mode-attack-oddname a note name with spaces and a hash is checked (core.quotepath safe)" \
  || bad "changed-notes-mode-attack-oddname" "rc=$rc out='$(head -2 "$TMP/out.txt")' err='$(head -2 "$TMP/err.txt")'"
C24="$TMP/ch-binary"; gbundle "$C24"
printf 'bin\000ary' > "$C24/blob.bin"; gcommit "$C24" "binary"
"$CHECK" "$C24" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-attack-binary a binary non-markdown change changes nothing" \
  || bad "changed-notes-mode-attack-binary" "rc=$rc out='$(head -2 "$TMP/out.txt")'"


# --- changed-notes round 2: hostile repo config, sub-folder untracked, git failures, decision pins -----------------

# hostile <name>: an executable script whose only act is writing a marker file; prints its path.
hostile() {
  printf '#!/bin/sh\nprintf x > "%s/host-marker-%s"\n' "$TMP" "$1" > "$TMP/host-$1.sh"
  chmod +x "$TMP/host-$1.sh"; printf '%s' "$TMP/host-$1.sh"
}

# sec-fsmonitor-direct: core.fsmonitor in the bundle's own config must never run (code execution vector).
CS1="$TMP/ch-sf1"; gbundle "$CS1"; gprofile "$CS1"; gcommit "$CS1" rules
badfm "$CS1/b.md"; g -C "$CS1" add b.md
g -C "$CS1" config core.fsmonitor "$(hostile fsm)"
"$CHECK" "$CS1" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && [ ! -f "$TMP/host-marker-fsm" ]; } \
  && ok "changed-notes-mode-sec-fsmonitor-direct core.fsmonitor in the bundle config never runs" \
  || bad "changed-notes-mode-sec-fsmonitor-direct" "rc=$rc marker=$([ -f "$TMP/host-marker-fsm" ] && echo WRITTEN || echo absent) out: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

# sec-fsmonitor-include: the same vector through include.path.
CS2="$TMP/ch-sf2"; gbundle "$CS2"; gprofile "$CS2"; gcommit "$CS2" rules
badfm "$CS2/b.md"; g -C "$CS2" add b.md
printf '[core]\n\tfsmonitor = %s\n' "$(hostile fsmi)" > "$TMP/host-evil.inc"
g -C "$CS2" config include.path "$TMP/host-evil.inc"
"$CHECK" "$CS2" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && [ ! -f "$TMP/host-marker-fsmi" ]; } \
  && ok "changed-notes-mode-sec-fsmonitor-include core.fsmonitor through include.path never runs" \
  || bad "changed-notes-mode-sec-fsmonitor-include" "rc=$rc marker=$([ -f "$TMP/host-marker-fsmi" ] && echo WRITTEN || echo absent)"

# sec-pin-external / sec-pin-textconv / sec-pin-pager: the drivers that did not execute stay pinned not executing.
CS3="$TMP/ch-sf3"; gbundle "$CS3"; gprofile "$CS3"; gcommit "$CS3" rules
badfm "$CS3/b.md"; g -C "$CS3" add b.md
g -C "$CS3" config diff.external "$(hostile ext)"
printf -- '*.md diff=evilhostile\n' > "$CS3/.gitattributes"; g -C "$CS3" add .gitattributes
g -C "$CS3" config diff.evilhostile.textconv "$(hostile tcx)"
g -C "$CS3" config core.pager "$(hostile pgr)"
"$CHECK" "$CS3" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && [ ! -f "$TMP/host-marker-ext" ] && [ ! -f "$TMP/host-marker-tcx" ] && [ ! -f "$TMP/host-marker-pgr" ]; } \
  && ok "changed-notes-mode-sec-pins diff.external, textconv and pager stay unexecuted" \
  || bad "changed-notes-mode-sec-pins" "rc=$rc markers: ext=$([ -f "$TMP/host-marker-ext" ] && echo WRITTEN) tcx=$([ -f "$TMP/host-marker-tcx" ] && echo WRITTEN) pgr=$([ -f "$TMP/host-marker-pgr" ] && echo WRITTEN)"

# edge-subfolder-untracked: an untracked note in a sub-folder bundle is checked (ls-files --full-name).
CU="$TMP/ch-sub"; rm -rf "$CU" "$TMP/okf-git-home"; mkdir -p "$TMP/okf-git-home" "$CU/kb"
g -C "$CU" init -q; g -C "$CU" config user.name probe; g -C "$CU" config user.email probe@probe
printf -- '---\nokf_version: "0.2"\n---\n' > "$CU/kb/index.md"; printf -- '# Log\n' > "$CU/kb/log.md"
hclean "$CU/kb/a.md"; printf -- '**1 concepts.**\n\n- [a](a.md)\n' >> "$CU/kb/index.md"
hclean "$CU/kb/d.md"; gcount 2 "$CU/kb" '- [a](a.md)' '- [d](d.md)'
g -C "$CU" add -A; g -C "$CU" commit -qm base
gprofile "$CU/kb"; g -C "$CU" add -A; g -C "$CU" commit -qm rules
hclean "$CU/kb/s.md"; g -C "$CU" add kb/s.md                       # staged control
g -C "$CU" rm -q kb/d.md                                          # deleted control
badfm "$CU/kb/m.md"; g -C "$CU" add kb/m.md                       # staged bad control
badfm "$CU/kb/u.md"                                               # UNTRACKED: the case that was missed
"$CHECK" "$CU/kb" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^u\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && grep -q '^m\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && grep -q 'claims 2 concepts; 4 on disk' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-subfolder-untracked an untracked note in a sub-folder bundle is checked" \
  || bad "changed-notes-mode-edge-subfolder-untracked" "rc=$rc out: $(head -6 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt")"

# edge-full-name: ls-files --full-name pinned. A bundle at kb/ with an untracked note at kb/kb/u.md: the cwd-relative
# listing (without --full-name) prints 'kb/u.md', the prefix strip turns it into 'u.md', and the wrong path is checked
# (or nothing is); the root-relative listing prints 'kb/kb/u.md' and the note is found under kb/u.md of the bundle.
CU2="$TMP/ch-fn"; rm -rf "$CU2" "$TMP/okf-git-home"; mkdir -p "$TMP/okf-git-home" "$CU2/kb"
g -C "$CU2" init -q; g -C "$CU2" config user.name probe; g -C "$CU2" config user.email probe@probe
printf -- '---\nokf_version: "0.2"\n---\n' > "$CU2/kb/index.md"; printf -- '# Log\n' > "$CU2/kb/log.md"
hclean "$CU2/kb/a.md"; printf -- '**1 concepts.**\n\n- [a](a.md)\n' >> "$CU2/kb/index.md"
g -C "$CU2" add -A; g -C "$CU2" commit -qm base
gprofile "$CU2/kb"; g -C "$CU2" add -A; g -C "$CU2" commit -qm rules
mkdir -p "$CU2/kb/kb"; badfm "$CU2/kb/kb/u.md"
"$CHECK" "$CU2/kb" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^kb/u\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && grep -q 'claims 1 concepts; 2 on disk' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-full-name an untracked note under a same-named inner folder is checked under its bundle path" \
  || bad "changed-notes-mode-edge-full-name" "rc=$rc out: $(head -4 "$TMP/out.txt" | tr '\n' '|') err: $(head -2 "$TMP/err.txt")"

# edge-badindex: a corrupt .git/index is exit 2 with a named line, never a silent rc 0.
CB="$TMP/ch-bi"; gbundle "$CB"; gprofile "$CB"; gcommit "$CB" rules
badfm "$CB/b.md"; g -C "$CB" add b.md
cp "$CB/.git/index" "$TMP/index.bak"; printf 'garbage-not-an-index' > "$CB/.git/index"
"$CHECK" "$CB" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
cp "$TMP/index.bak" "$CB/.git/index"
{ [ "$rc" = 2 ] && grep -q 'git diff .* failed' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-edge-badindex a corrupt index is exit 2 naming git diff" \
  || bad "changed-notes-mode-edge-badindex" "rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# edge-lockindex: an unreadable .git/index is exit 2 the same way.
CL="$TMP/ch-li"; gbundle "$CL"; gprofile "$CL"; gcommit "$CL" rules
badfm "$CL/b.md"; g -C "$CL" add b.md
chmod 000 "$CL/.git/index"
"$CHECK" "$CL" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
chmod 644 "$CL/.git/index"
{ [ "$rc" = 2 ] && grep -qE 'git (diff|ls-files).*failed' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-edge-lockindex an unreadable index is exit 2 with the named line" \
  || bad "changed-notes-mode-edge-lockindex" "rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# edge-rangeref: a range is not a single commit-ish: exit 2, named, for every range form (flat: one case each).
CR="$TMP/ch-rr"; gbundle "$CR"; gprofile "$CR"; gcommit "$CR" rules
"$CHECK" "$CR" --changed 'HEAD~1..HEAD' >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'single commit-ish' "$TMP/err.txt" && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-rangeref a range ref (HEAD~1..HEAD) is exit 2 asking for a single commit-ish" \
  || bad "changed-notes-mode-edge-rangeref" "ref=HEAD~1..HEAD rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"
"$CHECK" "$CR" --changed 'HEAD~1...HEAD' >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'single commit-ish' "$TMP/err.txt" && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-rangeref a range ref (HEAD~1...HEAD) is exit 2 asking for a single commit-ish" \
  || bad "changed-notes-mode-edge-rangeref" "ref=HEAD~1...HEAD rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"
"$CHECK" "$CR" --changed 'origin/main..HEAD' >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'single commit-ish' "$TMP/err.txt" && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-edge-rangeref a range ref (origin/main..HEAD) is exit 2 asking for a single commit-ish" \
  || bad "changed-notes-mode-edge-rangeref" "ref=origin/main..HEAD rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# edge-foreign-gitdir: GIT_DIR pointing at another repo is ignored — the bundle's own repository decides.
CF="$TMP/ch-fg"; gbundle "$CF"; gprofile "$CF"; gcommit "$CF" rules
badfm "$CF/b.md"; g -C "$CF" add b.md
CO="$TMP/ch-fg-other"; gbundle "$CO"
GIT_DIR="$CO/.git" "$CHECK" "$CF" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && grep -q 'claims 1 concepts; 2 on disk' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-edge-foreign-gitdir a foreign GIT_DIR never selects the repository" \
  || bad "changed-notes-mode-edge-foreign-gitdir" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# negative-helpref: --changed --help is a REF named --help (unknown ref, exit 2), not the help text.
CN="$TMP/ch-nh"; gbundle "$CN"; gprofile "$CN"; gcommit "$CN" rules
"$CHECK" "$CN" --changed --help >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q "unknown git ref '--help'" "$TMP/err.txt" && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-negative-helpref --changed --help takes --help as the ref, not as help" \
  || bad "changed-notes-mode-negative-helpref" "rc=$rc out='$(head -2 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# pin-count-once: two changed notes, one count line (the count check runs once, not per note).
CP="$TMP/ch-pc"; gbundle "$CP"; gprofile "$CP"; gcommit "$CP" rules
badfm "$CP/b.md"; badfm "$CP/c.md"; gcount 1 "$CP" '- [a](a.md)'
g -C "$CP" add b.md c.md
"$CHECK" "$CP" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && [ "$(grep -c 'claims 1 concepts' "$TMP/out.txt")" = 1 ]; } \
  && ok "changed-notes-mode-pin-count-once two changed notes still print the count line exactly once" \
  || bad "changed-notes-mode-pin-count-once" "rc=$rc count-lines=$(grep -c 'claims 1 concepts' "$TMP/out.txt" || true)"

# pin-txt-no-count: a change set with no markdown runs no count check even when the declared count is stale.
CX="$TMP/ch-px"; gbundle "$CX"; gprofile "$CX"; gcommit "$CX" rules
hclean "$CX/b.md"; gcount 1 "$CX" '- [a](a.md)'; printf -- 'data\n' > "$CX/data.txt"
gcommit "$CX" "stale count committed"
printf -- 'more\n' > "$CX/data.txt"
"$CHECK" "$CX" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-pin-txt-no-count no markdown changed means no count check, even stale" \
  || bad "changed-notes-mode-pin-txt-no-count" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')'"

# pin-outside-md: a changed markdown file outside the bundle — committed or untracked — is not checked and triggers
# no count. Both git streams carry the `-- .` pathspec that scopes them to the bundle, so a regression that drops the
# pathspec (or the prefix filter guarding an unscoped stream) fails here: the outside note enters the set, the stale
# count line prints, and rc stops being 0.
CW="$TMP/ch-po"; rm -rf "$CW" "$TMP/okf-git-home"; mkdir -p "$TMP/okf-git-home" "$CW/kb"
g -C "$CW" init -q; g -C "$CW" config user.name probe; g -C "$CW" config user.email probe@probe
printf -- '---\nokf_version: "0.2"\n---\n' > "$CW/kb/index.md"; printf -- '# Log\n' > "$CW/kb/log.md"
hclean "$CW/kb/a.md"; printf -- '**2 concepts.**\n\n- [a](a.md)\n- [z](z.md)\n' >> "$CW/kb/index.md"
g -C "$CW" add -A; g -C "$CW" commit -qm base
printf -- '---\ntitle: Outside\n---\nno type at all\n' > "$CW/outside.md"
g -C "$CW" add outside.md; g -C "$CW" commit -qm outside-note
printf -- '---\ntitle: Outside untracked\n---\nno type at all\n' > "$CW/outside-untracked.md"
"$CHECK" "$CW/kb" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-pin-outside-md a changed markdown file outside the bundle changes nothing" \
  || bad "changed-notes-mode-pin-outside-md" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')'"

# pin-gitdir-skip: a stray markdown file under a nested .git directory is never a changed note. Git itself refuses
# .git paths in both streams (ls-files --others stays silent; update-index says Invalid path), so the pin holds the
# behavior, and the guard in changed_one stays as defense for the day a git version changes its mind.
CG="$TMP/ch-gd"; gbundle "$CG"; gprofile "$CG"; gcommit "$CG" rules
mkdir -p "$CG/sub/.git"; printf -- 'no frontmatter at all\n' > "$CG/sub/.git/x.md"
"$CHECK" "$CG" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 0 ] && ! grep -q 'x\.md' "$TMP/out.txt" && ! grep -q 'claims' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-pin-gitdir-skip a path under .git is never a changed note" \
  || bad "changed-notes-mode-pin-gitdir-skip" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')'"

# pin-newline-msg: the newline refusal message is pinned exactly.
CM="$TMP/ch-nl"; gbundle "$CM"
"$CHECK" "$CM" --changed "$(printf 'HEAD\nx')" >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 64 ] && grep -qxF 'error: --changed: a newline in the ref cannot name a git ref' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-pin-newline-msg the newline refusal line is exact" \
  || bad "changed-notes-mode-pin-newline-msg" "rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# --- changed-notes round 3: filter drivers, the git version gate, the guard pins -------------------------------

# stat-dirty <file>: forces a worktree re-hash during the diff, which is where a clean filter would run.
statdirty() { touch -t 202001010000 "$1"; }

# sec-filter-clean: a committed .gitattributes assigning a clean filter never runs it. The hostile config lands after
# the fixture's own last git add (git add itself would run the clean filter while staging).
F1="$TMP/ch-fl1"; gbundle "$F1"; gprofile "$F1"; gcommit "$F1" rules
printf -- '*.md filter=evil\n' > "$F1/.gitattributes"; g -C "$F1" add .gitattributes; gcommit "$F1" attrs
badfm "$F1/b.md"; g -C "$F1" add b.md
g -C "$F1" config filter.evil.clean "$(hostile flc)"
statdirty "$F1/b.md"
"$CHECK" "$F1" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && [ ! -f "$TMP/host-marker-flc" ]; } \
  && ok "changed-notes-mode-sec-filter-clean a tree .gitattributes clean filter never runs" \
  || bad "changed-notes-mode-sec-filter-clean" "rc=$rc marker=$([ -f "$TMP/host-marker-flc" ] && echo WRITTEN || echo absent) out: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

# sec-filter-process: the process-filter form of the same vector (hostile config again after the last fixture add).
F2="$TMP/ch-fl2"; gbundle "$F2"; gprofile "$F2"; gcommit "$F2" rules
printf -- '*.md filter=evil\n' > "$F2/.gitattributes"; g -C "$F2" add .gitattributes; gcommit "$F2" attrs
badfm "$F2/b.md"; g -C "$F2" add b.md
g -C "$F2" config filter.evil.process "$(hostile flp)"
statdirty "$F2/b.md"
"$CHECK" "$F2" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && [ ! -f "$TMP/host-marker-flp" ]; } \
  && ok "changed-notes-mode-sec-filter-process a tree .gitattributes process filter never runs" \
  || bad "changed-notes-mode-sec-filter-process" "rc=$rc marker=$([ -f "$TMP/host-marker-flp" ] && echo WRITTEN || echo absent)"

# sec-attrfile: core.attributesFile cannot smuggle an attribute assignment either.
F3="$TMP/ch-fl3"; gbundle "$F3"; gprofile "$F3"; gcommit "$F3" rules
badfm "$F3/b.md"; g -C "$F3" add b.md
printf -- '*.md filter=eva\n' > "$TMP/host-attrs"; g -C "$F3" config core.attributesFile "$TMP/host-attrs"
g -C "$F3" config filter.eva.clean "$(hostile eva)"
statdirty "$F3/b.md"
"$CHECK" "$F3" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && [ ! -f "$TMP/host-marker-eva" ]; } \
  && ok "changed-notes-mode-sec-attrfile core.attributesFile cannot assign a filter" \
  || bad "changed-notes-mode-sec-attrfile" "rc=$rc marker=$([ -f "$TMP/host-marker-eva" ] && echo WRITTEN || echo absent)"

# sec-submodule-dirty: a dirty submodule with its own fsmonitor and clean filter changes nothing and runs neither.
# The submodule's configs are set AFTER its last fixture git call (git add itself consults core.fsmonitor).
F4="$TMP/ch-fl4"; gbundle "$F4"; gprofile "$F4"; gcommit "$F4" rules
FS="$TMP/ch-fl4-sub"; gbundle "$FS"
printf -- '*.md filter=evil\n' > "$FS/.gitattributes"; g -C "$FS" add .gitattributes; gcommit "$FS" attrs
g -C "$F4" -c protocol.file.allow=always submodule add "file://$FS" sub >/dev/null 2>&1
gcommit "$F4" "add submodule"
g -C "$FS" config core.fsmonitor "$(hostile sub-fsm)"
g -C "$FS" config filter.evil.clean "$(hostile sub-flc)"
printf -- 'dirty\n' >> "$FS/a.md"
statdirty "$FS/a.md"
badfm "$F4/b.md"; g -C "$F4" add b.md
"$CHECK" "$F4" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" \
  && [ ! -f "$TMP/host-marker-sub-fsm" ] && [ ! -f "$TMP/host-marker-sub-flc" ]; } \
  && ok "changed-notes-mode-sec-submodule-dirty a dirty submodule's own config never runs" \
  || bad "changed-notes-mode-sec-submodule-dirty" "rc=$rc fsm=$([ -f "$TMP/host-marker-sub-fsm" ] && echo WRITTEN) flc=$([ -f "$TMP/host-marker-sub-flc" ] && echo WRITTEN)"

# sec-readme-residual: the README names the info/attributes residual, so the sentence cannot silently vanish.
{ grep -q 'info/attributes' "$HERE/../../README.md" && grep -q 'cannot be disabled' "$HERE/../../README.md"; } \
  && ok "changed-notes-mode-sec-readme-residual the README names the info/attributes residual" \
  || bad "changed-notes-mode-sec-readme-residual" "README lacks the residual wording"

# sec-submodule-infoattrs: --ignore-submodules=all pinned — the parent's diff never enters a submodule whose own
# .git/info/attributes assigns a filter (the one attribute path no flag closes; skipping the submodule closes it).
# The submodule's git dir is the PARENT's .git/modules/sub (submodule add clones into it), so the hostile files land
# there, after the add, and the submodule's checked-out note is made stat-dirty to force any entering diff to hash it.
FA="$TMP/ch-fl5"; gbundle "$FA"; gprofile "$FA"; gcommit "$FA" rules
FB="$TMP/ch-fl5-sub"; gbundle "$FB"
g -C "$FA" -c protocol.file.allow=always submodule add "file://$FB" sub >/dev/null 2>&1
# A fresh clone's stat cache is empty: the parent's next add -A would hash the submodule's files through whatever
# filter is assigned by then. Warm the cache first, while no filter exists; the hostile files land after the commit.
g -C "$FA/sub" update-index --refresh >/dev/null 2>&1
gcommit "$FA" "add submodule"
mkdir -p "$FA/.git/modules/sub/info"; printf -- '*.md filter=evil\n' > "$FA/.git/modules/sub/info/attributes"
g --git-dir="$FA/.git/modules/sub" config filter.evil.clean "$(hostile sub-info)"
statdirty "$FA/sub/a.md"
badfm "$FA/b.md"; g -C "$FA" add b.md
"$CHECK" "$FA" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt" && [ ! -f "$TMP/host-marker-sub-info" ]; } \
  && ok "changed-notes-mode-sec-submodule-infoattrs the diff never enters a submodule with an info-attributes filter" \
  || bad "changed-notes-mode-sec-submodule-infoattrs" "rc=$rc marker=$([ -f "$TMP/host-marker-sub-info" ] && echo WRITTEN || echo absent) out: $(head -2 "$TMP/out.txt" | tr '\n' '|')"

# guard-foreign-env: GIT_DIR AND GIT_WORK_TREE both pointing elsewhere are ignored (the pins of the env unset).
F6="$TMP/ch-ge"; gbundle "$F6"; gprofile "$F6"; gcommit "$F6" rules
badfm "$F6/b.md"; g -C "$F6" add b.md
F6O="$TMP/ch-ge-other"; gbundle "$F6O"
GIT_DIR="$F6O/.git" GIT_WORK_TREE="$F6O" "$CHECK" "$F6" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && grep -q '^b\.md: L2 profile error: F101 ' "$TMP/out.txt"; } \
  && ok "changed-notes-mode-guard-foreign-env GIT_DIR and GIT_WORK_TREE both foreign are ignored" \
  || bad "changed-notes-mode-guard-foreign-env" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# guard-coreworktree: core.worktree pointing elsewhere is caught by the contains-bundle check.
F7="$TMP/ch-cw"; gbundle "$F7"; gprofile "$F7"; gcommit "$F7" rules
mkdir -p "$TMP/ch-cw-elsewhere"
g -C "$F7" config core.worktree "$TMP/ch-cw-elsewhere"
"$CHECK" "$F7" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'does not contain' "$TMP/err.txt"; } \
  && ok "changed-notes-mode-guard-coreworktree core.worktree elsewhere is refused by name" \
  || bad "changed-notes-mode-guard-coreworktree" "rc=$rc err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# guard-index-untouched: with NO stat-dirty tracked file, the run leaves .git/index byte-identical and un-rewritten.
# (A stat-dirty tracked file is different: `git diff <commit>` refreshes the stat cache and rewrites .git/index under
# its own lock even with GIT_OPTIONAL_LOCKS=0 — reviewer B executed that; this case pins the quiet path only.)
F8="$TMP/ch-ix"; gbundle "$F8"; gprofile "$F8"; gcommit "$F8" rules
badfm "$F8/b.md"; g -C "$F8" add b.md
cp "$F8/.git/index" "$TMP/index-before"; touch -t 202001010000 "$F8/.git/index"
printf 'now\n' > "$TMP/now-marker"; sleep 0
"$CHECK" "$F8" --changed HEAD >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 3 ] && cmp -s "$TMP/index-before" "$F8/.git/index" && ! [ "$F8/.git/index" -nt "$TMP/now-marker" ]; } \
  && ok "changed-notes-mode-guard-index-untouched no stat-dirty tracked file: .git/index stays untouched" \
  || bad "changed-notes-mode-guard-index-untouched" "rc=$rc same=$(cmp -s "$TMP/index-before" "$F8/.git/index" && echo yes || echo NO) rewritten=$([ "$F8/.git/index" -nt "$TMP/now-marker" ] && echo yes || echo no)"

# negative-versionref: --changed --version takes --version as the ref, like --help.
F9="$TMP/ch-nv"; gbundle "$F9"; gprofile "$F9"; gcommit "$F9" rules
"$CHECK" "$F9" --changed --version >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ [ "$rc" = 2 ] && grep -q "unknown git ref '--version'" "$TMP/err.txt" && [ ! -s "$TMP/out.txt" ]; } \
  && ok "changed-notes-mode-negative-versionref --changed --version takes --version as the ref" \
  || bad "changed-notes-mode-negative-versionref" "rc=$rc out='$(head -2 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# forged-name-bidi-l2: a committed note whose NAME carries a bidi override and whose type is
# undeclared: the F101 line spells the name, and no raw bidi byte reaches stdout or stderr.
CNB="$TMP/ch-forged-bidi"; gbundle "$CNB"; gprofile "$CNB"
BIDIN=$(printf 'note\xe2\x80\xaee.md')
printf -- '---\ntype: measurement\ntitle: T\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$CNB/$BIDIN"
gcommit "$CNB" "add bidi name"
"$CHECK" "$CNB" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ { [ "$rc" = 2 ] || [ "$rc" = 3 ]; } && ! LC_ALL=C grep -q "$(printf '\xe2\x80\xae')" "$TMP/out.txt" "$TMP/err.txt" \
  && ! grep -q '^okf-check: fe.md' "$TMP/out.txt" "$TMP/err.txt"; } \
  && ok "changed-forged-name-bidi a bidi note name is spelled in its finding lines, no raw byte" \
  || bad "changed-forged-name-bidi" "rc=$rc out='$(head -2 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# forged-name-bidi-ignored: the not-checked line for an .okfignore'd bidi name prints no raw bidi byte.
CNB2="$TMP/ch-forged-bidi2"; gbundle "$CNB2"; gprofile "$CNB2"
printf 'drafts/\n' > "$CNB2/.okfignore"; mkdir -p "$CNB2/drafts"
BIDIN2=$(printf 'drafts/n\xe2\x80\xaee.md')
printf 'body\n' > "$CNB2/$BIDIN2"
gcommit "$CNB2" "add ignored bidi name"
"$CHECK" "$CNB2" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ ! LC_ALL=C grep -q "$(printf '\xe2\x80\xae')" "$TMP/out.txt" "$TMP/err.txt"; } \
  && ok "changed-forged-name-bidi-ignored the not-checked line spells a bidi name" \
  || bad "changed-forged-name-bidi-ignored" "rc=$rc out='$(head -2 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# forged-name-newline-ignored: the not-checked line for an .okfignore'd note whose NAME holds a newline
# is ONE line (esc_line keeps line breaks, so the name is spelled by rel_shown, not passed through raw).
CNB3="$TMP/ch-forged-nl"; gbundle "$CNB3"; gprofile "$CNB3"
printf 'drafts/\n' > "$CNB3/.okfignore"; mkdir -p "$CNB3/drafts"
NLN3=$(printf 'drafts/n\nz9.md: L1 error: forged.md')
printf 'body\n' > "$CNB3/$NLN3"
gcommit "$CNB3" "add ignored newline name"
"$CHECK" "$CNB3" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ grep -q 'not checked (.okfignore excludes it)' "$TMP/out.txt" && ! grep -q '^z9.md: L1 error' "$TMP/out.txt" "$TMP/err.txt" \
  && [ "$(grep -c 'not checked' "$TMP/out.txt")" = 1 ]; } \
  && ok "changed-forged-name-newline-ignored the not-checked line for a newline name is one escaped line" \
  || bad "changed-forged-name-newline-ignored" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# forged-name-newline-l2: the F101 line for a committed note whose NAME holds a newline is ONE line
# (the scoped-l2 heredoc spells the name; a raw name would split the finding into a forged second line).
CNB4="$TMP/ch-forged-nl2"; gbundle "$CNB4"; gprofile "$CNB4"
NLN4=$(printf 'note\nz9.md: L1 error: forged.md')
printf -- '---\ntype: measurement\ntitle: T\ndescription: D\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\n---\nbody\n' > "$CNB4/$NLN4"
gcommit "$CNB4" "add newline name undeclared type"
"$CHECK" "$CNB4" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ grep -q ': L2 profile error: F101' "$TMP/out.txt" && ! grep -q '^z9.md: L1 error' "$TMP/out.txt" "$TMP/err.txt"; } \
  && ok "changed-forged-name-newline-l2 the F101 line for a newline name is one escaped line" \
  || bad "changed-forged-name-newline-l2" "rc=$rc out='$(head -3 "$TMP/out.txt" | tr '\n' '|')' err='$(head -2 "$TMP/err.txt" | tr '\n' '|')'"

# was-not-checked-hostile (n3): the layer-stopped "was not checked" line spells a hostile name; the raw
# name (esc_line keeps line breaks) would split the line into a forged second line. OKF_LAYER_TIMEOUT=1 stops
# the scoped layer of every changed note, so the branch is reached deterministically.
CNB5="$TMP/ch-wnc"; gbundle "$CNB5"; gprofile "$CNB5"
for i in $(seq 1 80); do
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: stable\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$CNB5/filler-$i.md"
done
NLN5=$(printf 'zz\nz9.md: L1 error: forged.md')
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\nstatus: stable\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$CNB5/$NLN5"
gcommit "$CNB5" "add filler notes and the newline name"
OKF_LAYER_TIMEOUT=2 "$CHECK" "$CNB5" --changed HEAD~1 >"$TMP/out.txt" 2>"$TMP/err.txt"; rc=$?
{ grep -q 'was not checked' "$TMP/err.txt" && ! grep -q '^z9.md: L1 error' "$TMP/out.txt" "$TMP/err.txt"; } \
  && ok "changed-was-not-checked-hostile the layer-stopped line spells a newline name" \
  || bad "changed-was-not-checked-hostile" "rc=$rc out='$(head -2 "$TMP/out.txt" | tr '\n' '|')' err='$(head -3 "$TMP/err.txt" | tr '\n' '|')'"

fi

echo
if [ "$SKIPS" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPS SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
