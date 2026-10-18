#!/usr/bin/env bash
# Tests for a dangling *.md symlink in a bundle (cases S14-DL-* in docs/0.9.x-cases.md and
# docs/gherkin/s14-dangling-md.feature; GitHub #99).
#
# okflint (third party) raises FileNotFoundError on a dangling *.md link, so the whole L2 layer used to be
# COULD NOT RUN. L1 and L3 skip such a link by design. L2 now runs on a mirror without the link and REPORTS it as an
# advisory. These tests observe what a user sees (`okf-check` text, `--json`, exit code) and, through a stub okflint
# that logs its working folder, whether okflint ran on the bundle itself or on a mirror.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"   # nothing here reads or writes the real home

REALOKF=$(command -v okflint 2>/dev/null || true)

# mkb <dir>: a minimal clean bundle (index, log, one note a.md, the house manifest L2 needs).
mkb() {
  mkdir -p "$1"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n[a](a.md)\n' > "$1/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$1/log.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01T00:00:00Z"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$1/a.md"
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"
}

# A stub okflint ahead of the real one on PATH: it appends the folder it was started in to $SPY, then runs the real one.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\npwd -P >> "$SPY"\nexec "%s" "$@"\n' "$REALOKF" > "$TMP/bin/okflint"; chmod +x "$TMP/bin/okflint"

# run <bundle> [args...]: text output in $TMP/out.txt, the folders okflint ran in at $TMP/spy.txt, exit code on stdout.
run() { local b="$1"; shift; : > "$TMP/spy.txt"; SPY="$TMP/spy.txt" PATH="$TMP/bin:$PATH" "$CHECK" "$b" "$@" >"$TMP/out.txt" 2>&1; printf '%s' "$?"; }
# jget <expr>: a field of the last --json document, e.g. jget 'd["l2_warnings"]'
runjson() { local b="$1"; shift; : > "$TMP/spy.txt"; SPY="$TMP/spy.txt" PATH="$TMP/bin:$PATH" "$CHECK" --json "$b" "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }
# ran_on_bundle <bundle>: 0 when every okflint start was in the bundle folder itself (no mirror).
ran_on_bundle() { local want; want=$(cd -P "$1" && pwd); [ -s "$TMP/spy.txt" ] && [ "$(sort -u "$TMP/spy.txt")" = "$want" ]; }

if [ -z "$REALOKF" ]; then
  skip "S14-DL-* L2 cases need okflint" "install: uv tool install okflint"
else
  section "S14-DL happy"
  # S14-DL-H1: the #99 repro. L2 used to be COULD NOT RUN (exit 2).
  B="$TMP/h1"; mkb "$B"; ln -s nowhere.md "$B/dead.md"
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_profile"]')" = '"ran"' ] && [ "$(jget 'd["l2_warnings"]')" = 1 ] \
      && [ "$(jget 'd["l2_by_rule"]')" = '{"DANGLING_MD": 1}' ]; } \
    && ok "S14-DL-H1 a dangling dead.md no longer stops L2: it ran, one advisory, exit 0" \
    || bad "S14-DL-H1 dangling note" "rc=$rc profile=$(jget 'd["l2_profile"]') warnings=$(jget 'd["l2_warnings"]') by_rule=$(jget 'd["l2_by_rule"]')"

  # S14-DL-H2: the text names the link, so it is reported and not hidden.
  run "$B" >/dev/null
  grep -Fq '  dead.md — dangling symlink: the link target does not exist' "$TMP/out.txt" && grep -Eq '^  L2 profile +PASS +0 errors, 1 warning' "$TMP/out.txt" \
    && ok "S14-DL-H2 the text output names dead.md as a dangling symlink and counts it in the L2 warnings" \
    || bad "S14-DL-H2 text names the link" "$(grep -n 'L2\|dead' "$TMP/out.txt" | head -4 | tr '\n' '|')"

  section "S14-DL negative"
  # S14-DL-N1: no dangling link -> okflint runs on the bundle itself (no mirror), as before.
  B="$TMP/n1"; mkb "$B"
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && ran_on_bundle "$B" && [ "$(jget 'd["l2_warnings"]')" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{}' ]; } \
    && ok "S14-DL-N1 a bundle with no dangling link: okflint runs on the bundle itself, no advisory" \
    || bad "S14-DL-N1 no dangling link" "rc=$rc spy=$(sort -u "$TMP/spy.txt" | tr '\n' ' ') warnings=$(jget 'd["l2_warnings"]')"

  # S14-DL-N2: a dangling link in a folder .okfignore excludes is no finding (the ignore mirror never held it).
  B="$TMP/n2"; mkb "$B"; mkdir "$B/archive"; ln -s nowhere.md "$B/archive/dead.md"; printf 'archive/\n' > "$B/.okfignore"
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_warnings"]')" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{}' ]; } \
    && ok "S14-DL-N2 a dangling link inside an ignored folder is not reported" \
    || bad "S14-DL-N2 ignored dangling link" "rc=$rc warnings=$(jget 'd["l2_warnings"]') by_rule=$(jget 'd["l2_by_rule"]')"

  # S14-DL-N3: a dangling link that is not a *.md file (an image, a *.MD name okflint does not read) builds no mirror.
  B="$TMP/n3"; mkb "$B"; ln -s nowhere.png "$B/pic.png"; ln -s nowhere.MD "$B/UP.MD"; ln -s nowhere.markdown "$B/m.markdown"
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && ran_on_bundle "$B" && [ "$(jget 'd["l2_warnings"]')" = 0 ]; } \
    && ok "S14-DL-N3 a dangling .png, .MD and .markdown link does not trigger the mirror" \
    || bad "S14-DL-N3 non-note dangling links" "rc=$rc spy=$(sort -u "$TMP/spy.txt" | tr '\n' ' ') warnings=$(jget 'd["l2_warnings"]')"

  section "S14-DL edge"
  # S14-DL-E1: a dangling link whose target is written as a folder.
  B="$TMP/e1"; mkb "$B"; ln -s missing-dir/ "$B/dirlink.md"
  rc=$(run "$B")
  { [ "$rc" = 0 ] && grep -Fq '  dirlink.md — dangling symlink' "$TMP/out.txt"; } \
    && ok "S14-DL-E1 a dangling link to a folder name is reported and L2 runs (exit 0)" \
    || bad "S14-DL-E1 dangling folder link" "rc=$rc $(grep -n 'L2\|dirlink' "$TMP/out.txt" | head -3 | tr '\n' '|')"

  # S14-DL-E2: in a subfolder the report gives the path from the bundle root.
  B="$TMP/e2"; mkb "$B"; mkdir -p "$B/sub/deep"; ln -s nowhere.md "$B/sub/deep/dead.md"
  rc=$(run "$B")
  { [ "$rc" = 0 ] && grep -Fq '  sub/deep/dead.md — dangling symlink' "$TMP/out.txt"; } \
    && ok "S14-DL-E2 a dangling link in a subfolder is reported with its path from the bundle root" \
    || bad "S14-DL-E2 subfolder" "rc=$rc $(grep -n 'L2\|dead' "$TMP/out.txt" | head -3 | tr '\n' '|')"

  # S14-DL-E3: two links, two advisories, one line each.
  B="$TMP/e3"; mkb "$B"; ln -s nowhere.md "$B/dead1.md"; ln -s nowhere.md "$B/dead2.md"
  rc=$(runjson "$B"); run "$B" >/dev/null
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"DANGLING_MD": 2}' ] && grep -Fq '  dead1.md — dangling' "$TMP/out.txt" && grep -Fq '  dead2.md — dangling' "$TMP/out.txt"; } \
    && ok "S14-DL-E3 two dangling links give two advisories, one line each" \
    || bad "S14-DL-E3 two links" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]')"

  # S14-DL-E4: dangling link AND .okfignore (the ignore mirror already skips the link): still reported, one for the link outside the ignored folder.
  B="$TMP/e4"; mkb "$B"; mkdir "$B/archive"; ln -s nowhere.md "$B/archive/gone.md"; ln -s nowhere.md "$B/dead.md"; printf 'archive/\n' > "$B/.okfignore"
  rc=$(run "$B")
  { [ "$rc" = 0 ] && grep -Fq '  dead.md — dangling symlink' "$TMP/out.txt" && ! grep -q 'gone.md' "$TMP/out.txt" && grep -Eq '^  L2 profile +PASS +0 errors, 1 warning' "$TMP/out.txt"; } \
    && ok "S14-DL-E4 with an .okfignore the link outside the ignored folder is reported, the one inside is not" \
    || bad "S14-DL-E4 dangling and .okfignore" "rc=$rc $(grep -n 'L2\|dead\|gone' "$TMP/out.txt" | head -4 | tr '\n' '|')"

  # S14-DL-E4b: the same with an .okfignore that excludes nothing (no ignore mirror is built; the dangling mirror is).
  B="$TMP/e4b"; mkb "$B"; ln -s nowhere.md "$B/dead.md"; printf '# nothing\n' > "$B/.okfignore"
  rc=$(run "$B")
  { [ "$rc" = 0 ] && grep -Fq '  dead.md — dangling symlink' "$TMP/out.txt"; } \
    && ok "S14-DL-E4b a dangling link with an .okfignore that excludes nothing is reported (exit 0)" \
    || bad "S14-DL-E4b no-op .okfignore" "rc=$rc $(grep -n 'L2\|dead' "$TMP/out.txt" | head -3 | tr '\n' '|')"

  # S14-DL-E5: a symlink loop is not a file either (okflint: Too many levels of symbolic links).
  B="$TMP/e5"; mkb "$B"; ln -s loop.md "$B/loop.md"
  rc=$(run "$B")
  { [ "$rc" = 0 ] && grep -Fq '  loop.md — dangling symlink' "$TMP/out.txt"; } \
    && ok "S14-DL-E5 a link loop (loop.md -> loop.md) is reported like a dangling link (exit 0)" \
    || bad "S14-DL-E5 link loop" "rc=$rc $(grep -n 'L2\|loop' "$TMP/out.txt" | head -3 | tr '\n' '|')"

  # S14-DL-E6: an unreadable note is not a dangling link: no mirror, no advisory (what it does to L1 is not this case).
  B="$TMP/e6"; mkb "$B"; cp "$B/a.md" "$B/b.md"; chmod 000 "$B/b.md"
  if [ -r "$B/b.md" ]; then skip "S14-DL-E6 unreadable note (chmod 000 is still readable here, running as root)"
  else
    run "$B" >/dev/null
    { ran_on_bundle "$B" && ! grep -q 'dangling' "$TMP/out.txt"; } \
      && ok "S14-DL-E6 an unreadable note is not treated as a dangling link: okflint runs on the bundle itself" \
      || bad "S14-DL-E6 unreadable note" "spy=$(sort -u "$TMP/spy.txt" | tr '\n' ' ') $(grep -c dangling "$TMP/out.txt") dangling lines"
  fi
  chmod 644 "$TMP/e6/b.md" 2>/dev/null

  # S14-DL-E7: the advisory never hides a real finding: a house-rule error elsewhere still gives its own exit (3, as without the link).
  B="$TMP/e7"; mkb "$B"; ln -s nowhere.md "$B/dead.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: current\nstale_after: "2099-01-01"\n---\nbody\n' > "$B/bad.md"
  rc=$(run "$B")
  { [ "$rc" = 3 ] && grep -Eq '^  L2 profile +FAIL' "$TMP/out.txt" && grep -Fq 'dead.md — dangling symlink' "$TMP/out.txt"; } \
    && ok "S14-DL-E7 a house-rule error next to a dangling link still fails L2 (exit 3) and the link is listed" \
    || bad "S14-DL-E7 real finding" "rc=$rc $(grep -n 'L2\|dead' "$TMP/out.txt" | head -4 | tr '\n' '|')"

  # S14-DL-E8: the mirror keeps what a note links to: an existing image gives no L002 (the #93 file set).
  B="$TMP/e8"; mkb "$B"; ln -s nowhere.md "$B/dead.md"; mkdir "$B/img"; printf 'png' > "$B/img/pic.png"; printf '\n![p](img/pic.png)\n' >> "$B/a.md"
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"DANGLING_MD": 1}' ]; } \
    && ok "S14-DL-E8 a link to an existing image still resolves on the dangling-link mirror (no L002)" \
    || bad "S14-DL-E8 image on the mirror" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]')"

  # S14-DL-E9: a trailing slash on the bundle path changes nothing.
  B="$TMP/e9"; mkb "$B"; ln -s nowhere.md "$B/dead.md"
  rc=$(run "$B/")
  { [ "$rc" = 0 ] && grep -Fq '  dead.md — dangling symlink' "$TMP/out.txt"; } \
    && ok "S14-DL-E9 a bundle path with a trailing slash is handled the same" \
    || bad "S14-DL-E9 trailing slash" "rc=$rc $(grep -n 'L2\|dead' "$TMP/out.txt" | head -3 | tr '\n' '|')"
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
