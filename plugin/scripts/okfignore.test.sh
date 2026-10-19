#!/usr/bin/env bash
# Tests for the .okfignore L2 mirror (cases S12-IG-* in docs/0.9.x-cases.md and
# docs/gherkin/s12-ignore-mirror.feature; public okf-knowledge-gate #12).
#
# Under a .okfignore that excludes something, L2 runs on a filtered mirror of the bundle. The mirror
# used to hold only notes and config, so a link to an existing image/SVG/PDF read as broken (L002).
# These tests observe the verdict a user sees (`okf-check --json` -> l2_by_rule) and the mirror's file set.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
PASS=0; FAIL=0; SKIPPED=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfignoretest)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$TMP/home"; mkdir -p "$HOME"   # nothing here reads or writes the real home

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }
skip() { SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"; }

# A bundle with an index that links a.md, a.md linking $2 (default img/pic.png), the manifest L2 needs,
# and an archive/ folder that .okfignore excludes (so the mirror is built).
mkb() { # <dir> [link target]
  local d="$1" link="${2:-img/pic.png}"
  mkdir -p "$d/archive"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n[a](a.md)\n' > "$d/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$d/log.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01T00:00:00Z"\nstale_after: "2099-01-01"\n---\n\n![pic](%s)\n' "$link" > "$d/a.md"
  printf -- 'old\n' > "$d/archive/old.md"
  printf 'archive/\n' > "$d/.okfignore"
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$d/okf-base.yaml"
}

# l2 <bundle> — the l2_by_rule object okf-check --json reports, e.g. {} or {"L002": 1}
l2() { "$CHECK" --json "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["l2_by_rule"], sort_keys=True))'; }

if ! command -v okflint >/dev/null 2>&1; then
  skip "S12-IG-* L2 cases need okflint (install: uv tool install okflint)"
else
  # S12-IG-H1: the okf-knowledge-gate#12 repro. The control run (no .okfignore) proves the bundle itself is clean.
  B="$TMP/h1"; mkb "$B"; mkdir -p "$B/img"; printf 'png' > "$B/img/pic.png"
  got=$(l2 "$B"); mv "$B/.okfignore" "$B/.okfignore.off"; ctl=$(l2 "$B")
  { [ "$got" = "{}" ] && [ "$ctl" = "{}" ]; } && ok "S12-IG-H1 a link to an existing image gives no L002 when .okfignore excludes a folder" \
    || bad "S12-IG-H1 existing image" "l2_by_rule=$got without .okfignore=$ctl (want {} and {})"

  # S12-IG-N1: the mirror must not make a missing file look present.
  B="$TMP/n1"; mkb "$B" img/missing.png; mkdir -p "$B/img"
  got=$(l2 "$B")
  [ "$got" = '{"L002": 1}' ] && ok "S12-IG-N1 a link to a missing image still gives L002" \
    || bad "S12-IG-N1 missing image" "l2_by_rule=$got (want {\"L002\": 1})"

  # S12-IG-N2: a file that exists but sits in an ignored folder is not in the bundle.
  B="$TMP/n2"; mkb "$B" archive/x.png; printf 'png' > "$B/archive/x.png"
  got=$(l2 "$B")
  [ "$got" = '{"L002": 1}' ] && ok "S12-IG-N2 a link into an ignored folder (the file exists) still gives L002" \
    || bad "S12-IG-N2 link into ignored folder" "l2_by_rule=$got (want {\"L002\": 1})"

  # S12-IG-E1: names the copy loop and okflint must both survive.
  e1() { # <label> <relative path of the target> [link as written in the note]
    local B="$TMP/e1-$1"; mkb "$B" "${3:-$2}"; mkdir -p "$B/$(dirname "$2")"; printf 'png' > "$B/$2"
    got=$(l2 "$B")
    [ "$got" = "{}" ] && ok "S12-IG-E1$1 $4 gives no L002" || bad "S12-IG-E1$1 $4" "l2_by_rule=$got (want {})"
  }
  e1 a "assets/deep/er/pic.png" "" "an image in a nested subfolder"
  e1 b "img/my pic.png" "<img/my pic.png>" "a file name with a space"
  e1 c "img/.hidden.png" "" "a dotfile"
  e1 d "img/café-日本.png" "" "a non-ASCII file name"
  B="$TMP/e1-e"; mkb "$B" img/alias.png; mkdir -p "$B/img"; printf 'png' > "$B/img/real.png"; ln -s real.png "$B/img/alias.png"
  got=$(l2 "$B")
  [ "$got" = "{}" ] && ok "S12-IG-E1e a symlink to a file inside the bundle gives no L002" || bad "S12-IG-E1e symlink to file" "l2_by_rule=$got (want {})"

  # S12-IG-E2: .okfignore that excludes no note or config file builds no mirror, so a non-markdown ignore changes nothing.
  B="$TMP/e2"; mkb "$B"; mkdir -p "$B/img/raw"; printf 'png' > "$B/img/pic.png"; printf 'psd' > "$B/img/raw/big.psd"
  printf 'img/raw/\n' > "$B/.okfignore"; rm -rf "$B/archive"
  printf -- '---\ntype: Lesson\ntitle: U\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01T00:00:00Z"\nstale_after: "2099-01-01"\n---\n\n![pic](img/pic.png) [raw](img/raw/big.psd)\n' > "$B/a.md"
  got=$(l2 "$B")
  [ "$got" = "{}" ] && ok "S12-IG-E2 .okfignore that excludes only a non-markdown folder builds no mirror: both links resolve, no L002" \
    || bad "S12-IG-E2 non-markdown ignore only" "l2_by_rule=$got (want {})"

  # S12-IG-E6: a bundle path with & and a space (bash 5.2 reads & in a ${var/pat/rep} replacement as the matched text).
  B="$TMP/R&D kb/b"; mkb "$B"; mkdir -p "$B/img"; printf 'png' > "$B/img/pic.png"
  got=$(l2 "$B")
  [ "$got" = "{}" ] && ok "S12-IG-E6 a bundle under a path with & and a space gives no L002" \
    || bad "S12-IG-E6 & in the bundle path" "l2_by_rule=$got (want {})"
fi

# --- the mirror's file set (no okflint needed) ---------------------------------------------------------
# Literal expected set, so a mirror that lost or gained a file cannot agree with itself.
mirror() { # <bundle> <dest> — runs okfignore_mirror alone; prints its count line, rc on the last line
  ( set +e; . "$HERE/ignore-lib.sh"; okfignore_mirror "$1" "$2" 2>"$2.err"; echo "rc=$?" )
}
B="$TMP/m"; D="$TMP/m-out"; mkdir -p "$B/archive" "$B/img" "$B/.git" "$B/real" "$TMP/m-outside"
printf -- 'n\n' > "$B/a.md"; printf -- 'n\n' > "$B/archive/old.md"; printf 'p' > "$B/archive/x.png"
printf 'p' > "$B/img/pic.png"; printf 'p' > "$B/.git/blob.png"; printf 'p' > "$B/real/doc.pdf"; printf 'p' > "$TMP/m-outside/o.png"
printf 'cfg: 1\n' > "$B/okf-base.yaml"; printf 'archive/\n' > "$B/.okfignore"
ln -s "$TMP/m-outside" "$B/linkdir"; ln -s no-such-target.png "$B/dangling.png"; ln -s real/doc.pdf "$B/alias.pdf"
out=$(mirror "$B" "$D")
got=$(cd "$D" && find . \( -type f -o -type l \) | sort | tr '\n' ' ')
want="./.okfignore ./a.md ./alias.pdf ./img/pic.png ./okf-base.yaml ./real/doc.pdf "
{ [ "$got" = "$want" ]; } && ok "S12-IG-E3 the mirror holds the non-ignored files only: no ignored folder, no .git, no symlinked folder, no dangling link" \
  || bad "S12-IG-E3 mirror file set" "got=[$got] want=[$want]"
[ -L "$D/img/pic.png" ] && [ "$(cat "$D/img/pic.png")" = "p" ] && ok "S12-IG-E4 a non-markdown file is a link to the original: no copy, the content is the original's" \
  || bad "S12-IG-E4 link, not copy" "$(ls -l "$D/img/pic.png" 2>&1)"
printf '%s\n' "$out" | head -1 | grep -qx '1 1 1' && ok "S12-IG-E5 counts keep their meaning: 1 note kept, 1 note excluded, 1 file excluded (the ignored image is not counted)" \
  || bad "S12-IG-E5 counts" "$(printf '%s' "$out" | tr '\n' ' ') (want '1 1 1 rc=0')"

# S12-IG-N3: a link that cannot be made fails the mirror, naming the file (as a failed copy does).
mkdir -p "$TMP/noln"; printf '#!/bin/sh\nexit 1\n' > "$TMP/noln/ln"; chmod +x "$TMP/noln/ln"
out=$(PATH="$TMP/noln:$PATH" mirror "$B" "$TMP/m-fail")
{ printf '%s' "$out" | grep -q 'rc=1' && grep -q 'cannot link' "$TMP/m-fail.err"; } \
  && ok "S12-IG-N3 a link that fails makes the mirror fail closed (rc 1), naming the file" \
  || bad "S12-IG-N3 failed link" "$(printf '%s' "$out" | tr '\n' ' ') err=$(cat "$TMP/m-fail.err")"

# S12-IG-E6b: the same, at the mirror: a link made under a path with & and a space resolves (a dangling link fails -e).
B="$TMP/R&D mirror/b"; mkdir -p "$B/img" "$B/archive"
printf -- 'n\n' > "$B/a.md"; printf -- 'n\n' > "$B/archive/old.md"; printf 'p' > "$B/img/pic.png"; printf 'archive/\n' > "$B/.okfignore"
out=$(mirror "$B" "$TMP/R&D mirror/out")
{ [ -e "$TMP/R&D mirror/out/img/pic.png" ] && [ "$(cat "$TMP/R&D mirror/out/img/pic.png")" = "p" ]; } \
  && ok "S12-IG-E6b the mirror's link under a path with & and a space resolves to the original" \
  || bad "S12-IG-E6b & in the path" "$(ls -l "$TMP/R&D mirror/out/img/pic.png" 2>&1) $(printf '%s' "$out" | tr '\n' ' ')"

# S12-IG-N5: a batch that links some files and then fails is retried file by file; links already made are not an error.
mkdir -p "$TMP/halfln"; cat > "$TMP/halfln/ln" <<'STUB'
#!/bin/bash
# links the first source of a multi-source call, then fails: a partly successful batch
if [ $# -gt 3 ]; then /bin/ln -s "$2" "${@: -1}"; exit 1; fi
exec /bin/ln "$@"
STUB
chmod +x "$TMP/halfln/ln"
B="$TMP/n5/b"; mkdir -p "$B/img" "$B/archive"
printf -- 'n\n' > "$B/a.md"; printf -- 'n\n' > "$B/archive/old.md"; printf 'archive/\n' > "$B/.okfignore"
printf '1' > "$B/img/one.png"; printf '2' > "$B/img/two.png"; printf '3' > "$B/img/three.png"
out=$(PATH="$TMP/halfln:$PATH" mirror "$B" "$TMP/n5/out")
{ printf '%s' "$out" | grep -q 'rc=0' && [ "$(cat "$TMP/n5/out/img/one.png" "$TMP/n5/out/img/two.png" "$TMP/n5/out/img/three.png" 2>&1)" = "123" ]; } \
  && ok "S12-IG-N5 a batch that links some files and then fails is retried without failing on the links already made" \
  || bad "S12-IG-N5 partly successful batch" "$(printf '%s' "$out" | tr '\n' ' ') err=$(cat "$TMP/n5/out.err")"

# --- --selftest probe ----------------------------------------------------------------------------------
if ! command -v okflint >/dev/null 2>&1; then
  skip "S12-IG-H2/N4 --selftest probe needs okflint"
else
  "$CHECK" --selftest >"$TMP/st.txt" 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'FIRED  *ignored folder and a linked image' "$TMP/st.txt"; } \
    && ok "S12-IG-H2 --selftest has a probe for a linked image under .okfignore, and it fires on the real script (rc 0)" \
    || bad "S12-IG-H2 selftest probe" "rc=$rc $(grep -n 'ignore' "$TMP/st.txt" | tr '\n' ' ')"
  # A probe is proven by its gate going dead: a plugin copy whose mirror drops the links must exit 5.
  D4="$TMP/dead-mirror"; mkdir -p "$D4"; cp -R "$HERE/.." "$D4/plugin" 2>/dev/null
  sed -i.orig 's|_okfignore_flush() {|_okfignore_flush() { return 0;|' "$D4/plugin/scripts/ignore-lib.sh"
  if cmp -s "$D4/plugin/scripts/ignore-lib.sh" "$D4/plugin/scripts/ignore-lib.sh.orig"; then
    bad "S12-IG-N4 crippled copy" "the cripple changed nothing"
  else
    "$D4/plugin/scripts/okf-check" --selftest >"$TMP/st-dead.txt" 2>&1; rc=$?
    { [ "$rc" -eq 5 ] && grep -q 'NOT FIRED  *ignored folder and a linked image' "$TMP/st-dead.txt"; } \
      && ok "S12-IG-N4 with the mirror not linking files, the probe reports NOT FIRED and --selftest exits 5" \
      || bad "S12-IG-N4 dead mirror" "rc=$rc $(grep -n 'ignore\|SELFTEST' "$TMP/st-dead.txt" | tr '\n' ' ')"
  fi
fi

# --- F-6 (0.9.11 register, spec row IA-1): .okfignore reaches a file alias, and the symlinks line honours it -------------------------
# S12-IG-F1: archive/ is ignored and alias.md -> archive/old.md (a note with no frontmatter, an L1 error) is an alias of
# an ignored note: it is ignored too, by every walker, instead of being checked through the back door.
B="$TMP/f1"; mkb "$B"; ln -s archive/old.md "$B/alias.md"
"$CHECK" --json "$B" > "$TMP/f1.json" 2>/dev/null; rc=$?
errs=$(python3 -c 'import json,sys; print(sum("alias.md" in e for e in json.load(open(sys.argv[1]))["errors"]))' "$TMP/f1.json" 2>/dev/null)
listed=$(bash "$HERE/ignore-lib.sh" --list "$B" 2>/dev/null | tr '\0' '\n' | grep -c '^alias.md$')
{ [ "$rc" = 0 ] && [ "$errs" = 0 ] && [ "$listed" = 0 ]; } \
  && ok "S12-IG-F1 a file alias of an ignored note is ignored as well: no L1 error for alias.md, not in ignore-lib --list" \
  || bad "S12-IG-F1 alias of an ignored note" "rc=$rc errors-naming-alias=$errs listed=$listed"
# S12-IG-F1b: an alias of a note that is NOT ignored is still checked (the file-link rule).
B="$TMP/f1b"; mkb "$B"; mkdir -p "$B/real"; printf 'no frontmatter\n' > "$B/real/n.md"; ln -s real/n.md "$B/alias.md"
"$CHECK" --json "$B" > "$TMP/f1b.json" 2>/dev/null; rc=$?
errs=$(python3 -c 'import json,sys; print(sum("alias.md" in e for e in json.load(open(sys.argv[1]))["errors"]))' "$TMP/f1b.json" 2>/dev/null)
{ [ "$rc" = 1 ] && [ "$errs" -ge 1 ]; } && ok "S12-IG-F1b an alias of a kept note is still checked (L1 error, exit 1)" \
  || bad "S12-IG-F1b alias of a kept note" "rc=$rc errors-naming-alias=$errs"
# S12-IG-F2: a symlinked folder that .okfignore excludes is not named on the symlinks line; one that is not excluded is.
B="$TMP/f2"; mkb "$B"; mkdir -p "$TMP/f2-out/x" "$TMP/f2-out/y"
ln -s ../../f2-out/x "$B/archive/linked"; ln -s ../f2-out/y "$B/kept"
"$CHECK" "$B" > "$TMP/f2.txt" 2>&1
{ grep -q '1 symlinked folder(s) not entered' "$TMP/f2.txt" && grep -qxE ' +kept' "$TMP/f2.txt" && ! grep -q 'archive/linked' "$TMP/f2.txt"; } \
  && ok "S12-IG-F2 the symlinks line leaves out a folder link under an ignored folder and names the other one" \
  || bad "S12-IG-F2 symlinks line" "$(grep -n -A2 'symlink' "$TMP/f2.txt" | tr '\n' '|')"
# S12-IG-F3: --json carries the list as symlinked_folders (present only when there is one).
"$CHECK" --json "$B" > "$TMP/f2.json" 2>/dev/null
got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("symlinked_folders")))' "$TMP/f2.json" 2>/dev/null)
"$CHECK" --json "$TMP/f1b" > "$TMP/f3.json" 2>/dev/null
none=$(python3 -c 'import json,sys; print("symlinked_folders" in json.load(open(sys.argv[1])))' "$TMP/f3.json" 2>/dev/null)
{ [ "$got" = '["kept"]' ] && [ "$none" = False ]; } \
  && ok "S12-IG-F3 --json symlinked_folders lists [\"kept\"]; a bundle without folder links has no such key" \
  || bad "S12-IG-F3 json list" "got=$got none=$none"

echo
echo "  $PASS passed, $FAIL failed, $SKIPPED skipped"
[ "$FAIL" -eq 0 ] || exit 1
