#!/usr/bin/env bash
# Tests for okf_check.wikilink_root (cases S15-WR-* in docs/0.9.x-cases.md and
# docs/gherkin/s15-wikilink-root.feature; public okf-knowledge-gate #13).
#
# A bundle inside a larger note vault (Obsidian, Foam) links notes by their path from the VAULT root,
# `[[projects/p/README]]`. okflint resolves a wikilink by file name only, and okf-check's post-filter (okf-knowledge-gate#1) looks
# at the bundle root and the note's own folder, so the link reads as L001 "broken". With
# `okf_check: wikilink_root: <folder>` in okf-base.yaml that folder is looked at too.
# These tests observe what a user sees: `okf-check --json` (l2_by_rule), the text, the exit code, and okf-verify's
# --check-config for the shared schema.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
VERIFY="$HERE/okf-verify"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"   # nothing here reads or writes the real home

REALOKF=$(command -v okflint 2>/dev/null || true)

# mkvault <vault>: the okf-knowledge-gate#13 repro. The bundle is <vault>/projects/p/bundle, its note a.md links
# [[projects/p/README]] and the target is <vault>/projects/p/README.md, outside the bundle.
mkvault() {
  local b="$1/projects/p/bundle"
  mkdir -p "$b"
  printf -- '# README\n' > "$1/projects/p/README.md"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n[a](a.md)\n' > "$b/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$b/log.md"
  note "$b/a.md" 'See [[projects/p/README]].'
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$b/okf-base.yaml"
}
# note <file> <body>: a conformant note.
note() {
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01T00:00:00Z"\nstale_after: "2099-01-01"\n---\n\n%s\n' "$2" > "$1"
}
# setroot <bundle> <value>: the okf_check block with one wikilink_root line (the value as YAML text).
setroot() { printf 'okf_check:\n  wikilink_root: %s\n' "$2" >> "$1/okf-base.yaml"; }

# run <bundle>: --json document in $TMP/out.json, exit code on stdout.
runjson() { "$CHECK" --json "$1" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
jget() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps('"$1"', sort_keys=True))' "$TMP/out.json"; }

if [ -z "$REALOKF" ]; then
  skip "S15-WR-* L2 cases need okflint" "install: uv tool install okflint"
else
  section "S15-WR happy"
  # S15-WR-H1: the okf-knowledge-gate#13 repro. The vault root is three folders up: vault/projects/p/bundle -> vault.
  B="$TMP/h1/projects/p/bundle"; mkvault "$TMP/h1"; setroot "$B" ../../..
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{}' ]; } \
    && ok "S15-WR-H1 the okf-knowledge-gate#13 repro with wikilink_root gives no L001 (exit 0)" \
    || bad "S15-WR-H1 okf-knowledge-gate#13 repro" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') (want exit 0 and {})"

  section "S15-WR negative"
  # S15-WR-N1: a target missing under the root still gives L001 (the filter must not drop everything).
  B="$TMP/n1/projects/p/bundle"; mkvault "$TMP/n1"; setroot "$B" ../../..; note "$B/a.md" 'See [[projects/p/MISSING]].'
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"L001": 1}' ]; } \
    && ok "S15-WR-N1 a wikilink whose target is missing under the root still gives L001 (exit 0, advisory)" \
    || bad "S15-WR-N1 missing target" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') (want exit 0 and {\"L001\": 1})"

  # S15-WR-N2: without the key the repro is unchanged: one L001.
  B="$TMP/n2/projects/p/bundle"; mkvault "$TMP/n2"
  rc=$(runjson "$B")
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"L001": 1}' ]; } \
    && ok "S15-WR-N2 without the key the repro still gives one L001 (exit 0, advisory)" \
    || bad "S15-WR-N2 no key" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') (want exit 0 and {\"L001\": 1})"

  section "S15-WR invalid values"
  # refused <id> <label> <yaml value> <message pattern> [setup command run with the vault in $V]: exit 2 from okf-check
  # (text) and from okf-verify --check-config, the shared schema, with the same message. The L001 stays: a refused value is not used.
  refused() {
    local id="$1" label="$2" val="$3" pat="$4" rc rv oldhome="$HOME"
    V="$TMP/$id"; B="$V/projects/p/bundle"; mkvault "$V"; [ -n "${5:-}" ] && eval "$5"
    setroot "$B" "$val"
    "$CHECK" "$B" >"$TMP/out.txt" 2>&1; rc=$?
    "$REALPY" "$VERIFY" "$B" --check-config >"$TMP/out2.txt" 2>&1; rv=$?
    "$CHECK" --json "$B" >"$TMP/out.json" 2>/dev/null
    if [ "$rc" = 2 ] && [ "$rv" = 2 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"L001": 1}' ] && grep -q "Config .*COULD NOT RUN.*$pat" "$TMP/out.txt" && grep -q "$pat" "$TMP/out2.txt"; then
      ok "S15-WR-$id $label: exit 2 naming the problem"
    else
      bad "S15-WR-$id $label" "okf-check rc=$rc okf-verify rc=$rv; Config line: $(grep 'Config ' "$TMP/out.txt" | head -1 | cut -c1-200); verify: $(head -1 "$TMP/out2.txt" | cut -c1-200)"
    fi
  }
  refused N3 "a number" 3 "okf_check.wikilink_root must be a non-empty string"
  refused N4 "a list" "[../../..]" "okf_check.wikilink_root must be a non-empty string"
  refused N5 "an absolute path" "/tmp" "not an absolute path"
  refused N6 "a root that does not exist" "../../../nowhere" "does not exist"
  refused N7 "a root that is a file" "../README.md" "is not a folder"
  # N8: a sibling folder of the vault is not in the bundle's parent chain; reading it would let a note resolve links
  # against an unrelated project.
  refused N8 "a folder that is not the bundle or one of its parents" "../../../../other" "must be the bundle folder or one of its parent folders" 'mkdir -p "$V/../other"'
  refused N9 "the file system root" "../../../../../../../../../../../../../../.." "too broad"
  refused N10 "the home folder" "../../.." "too broad" 'HOME=$(cd -P "$V" && pwd)'
  refused N11 "a folder above the home folder" "../../.." "too broad" 'HOME=$(cd -P "$V/projects/p" && pwd)'
  # N12/N13: a value with a space at either end would collapse in realpath and do nothing in silence.
  refused N12 "a leading space" '" ../../.."' "must not start or end with a space"
  refused N13 "a trailing space" '"../../.. "' "must not start or end with a space"
  # N14: the value itself holds the text okf-base.yaml; both tools print the whole message (the Config line used to cut
  # everything up to the LAST okf-base.yaml).
  refused N14 "a value that names okf-base.yaml" "../bundle/okf-base.yaml" "okf_check.wikilink_root: ../bundle/okf-base.yaml is not a folder"
  # N16/N17: YAML keeps the last of two equal keys, so the first value vanished in silence (here the wrong ../.. is
  # dropped and the right ../../.. used: the run looked fine). Written twice is a config error, inside the block or the
  # block itself.
  refused N16 "wikilink_root written twice in okf_check" "../..
  wikilink_root: ../../.." "written twice"
  refused N17 "okf_check written twice" "../../.." "written twice" 'printf "okf_check:\n  edit_hook: false\n" >> "$B/okf-base.yaml"'
  # N18: a key written twice deeper in the block is named by its whole path.
  refused N18 "a nested key written twice" "../../..
  verify:
    remote: false
    remote: true" '`okf_check.verify.remote` written twice'
  # N19: `"1"` and `1` are two different YAML keys (a string and an integer): not "written twice"; each is an unknown
  # key, the schema's own error.
  refused N19 'the keys "1" and 1' '../../..
  "1": a
  1: b' "is not a known key"
  grep -q 'written twice' "$TMP/out.txt" "$TMP/out2.txt" \
    && bad "S15-WR-N19b different keys" "reported as written twice: $(grep -h 'twice' "$TMP/out.txt" "$TMP/out2.txt" | head -1)" \
    || ok "S15-WR-N19b \"1\" and 1 are not reported as a key written twice"
  # N15: the schema check without a bundle folder is a config error, not a Python TypeError.
  got=$("$REALPY" - "$VERIFY" <<'PYEOF' 2>&1
import importlib.util, sys
from importlib.machinery import SourceFileLoader
l = SourceFileLoader("okf_verify", sys.argv[1])
v = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_verify", l)); l.exec_module(v)
try:
    v.check_node("..", {"type": "folder"}, "okf_check.wikilink_root")
    print("no error")
except v.BaseConfigError as e:
    print("BaseConfigError")
except Exception as e:
    print(type(e).__name__)
PYEOF
)
  [ "$got" = "BaseConfigError" ] && ok "S15-WR-N15 a folder node checked without a bundle folder is a config error" \
    || bad "S15-WR-N15 folder node without a bundle" "got: $got (want BaseConfigError)"

  section "S15-WR edge"
  # edge <id> <label> <link text> [setup run with the vault in $V and the bundle in $B] [l2_by_rule wanted, default {}]:
  # the link is in a.md of the repro, wikilink_root is ../../.., and the verdict is no L001.
  edge() {
    local id="$1" label="$2" link="$3" want="${5:-}" rc
    [ -n "$want" ] || want='{}'
    V="$TMP/$id"; B="$V/projects/p/bundle"; mkvault "$V"; setroot "$B" ../../..
    [ -n "${4:-}" ] && eval "$4"
    note "$B/a.md" "See $link."
    rc=$(runjson "$B")
    { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = "$want" ]; } \
      && ok "S15-WR-$id $label gives no L001" \
      || bad "S15-WR-$id $label" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') (want exit 0 and $want)"
  }
  edge E1 "an alias" '[[projects/p/README|the readme]]'
  edge E2 "a heading" '[[projects/p/README#Usage]]'
  edge E3 "a name with a space" '[[projects/p/My Note]]' 'printf "# n\n" > "$V/projects/p/My Note.md"'
  edge E4 "the .md extension spelled out" '[[projects/p/README.md]]'
  edge E5 "a link written with a leading slash" '[[/projects/p/README]]'
  edge E6 "a note in a bundle subfolder" '[[projects/p/README]]' 'mkdir -p "$B/sub"; note "$B/sub/deep.md" "See [[projects/p/README]]."; printf "[deep](sub/deep.md)\n" >> "$B/index.md"'
  # notl <id> <label> <link text> <setup> [text pattern]: the link must stay L001 (nothing resolves it).
  notl() {
    local id="$1" label="$2" link="$3" rc
    V="$TMP/$id"; B="$V/projects/p/bundle"; mkvault "$V"; setroot "$B" ../../..
    eval "$4"
    note "$B/a.md" "See $link."
    rc=$(runjson "$B")
    { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"L001": 1}' ]; } \
      && ok "S15-WR-$id $label still gives L001" \
      || bad "S15-WR-$id $label" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') (want exit 0 and {\"L001\": 1})"
  }
  # E7: the target exists under the bundle AND under the root: resolved, counted once.
  V="$TMP/E7"; B="$V/projects/p/bundle"; mkvault "$V"; setroot "$B" ../../..
  mkdir -p "$B/projects/p"; note "$B/projects/p/README.md" inner; printf '[inner](projects/p/README.md)\n' >> "$B/index.md"
  rc=$(runjson "$B"); "$CHECK" "$B" >"$TMP/out.txt" 2>&1
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{}' ] && grep -q ' 1 path wikilink(s) resolved by okf-check' "$TMP/out.txt"; } \
    && ok "S15-WR-E7 a target under the bundle and under the root gives no L001 and is counted once" \
    || bad "S15-WR-E7 both places" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') $(grep 'resolved by' "$TMP/out.txt")"
  # E8 and E9: a symlinked folder is not entered, and a symlink that leaves the root does not resolve.
  notl E8 "a target behind a symlinked folder of the vault" '[[linked/n]]' 'mkdir -p "$V/real"; printf "# n\n" > "$V/real/n.md"; ln -s real "$V/linked"'
  notl E9 "a symlinked note whose target is outside the vault" '[[projects/p/out]]' 'printf "# o\n" > "$TMP/E9-outside.md"; ln -s "$TMP/E9-outside.md" "$V/projects/p/out.md"'
  # E10: L2 runs on a copy of the bundle under .okfignore (and under a dangling link); a root written relative to the bundle
  # is still read from where the bundle really is.
  edge E10 "a bundle that .okfignore copies for L2" '[[projects/p/README]]' 'mkdir -p "$B/archive"; note "$B/archive/old.md" old; printf "archive/\n" > "$B/.okfignore"'
  edge E11 "a bundle with a dangling link that L2 runs around" '[[projects/p/README]]' 'ln -s nowhere.md "$B/dead.md"' '{"DANGLING_MD": 1}'
  # E12/E13: a wikilink resolves by Obsidian's rule on every disk, as okf-export resolves it: the exact name first, else
  # the one name equal to it ignoring case and Unicode normalisation. Linux kept the L001 for [[projects/p/readme]],
  # macOS did not; NFD/NFC: macOS may store a name decomposed.
  NFC=$(printf 'caf\303\251'); NFD=$(printf 'cafe\314\201')
  edge E12 "a vault link written in another letter case" '[[projects/p/readme]]'
  edge E12b "a vault link in NFC to a file named in NFD" "[[projects/p/$NFC]]" 'printf "# c\n" > "$V/projects/p/$NFD.md"'
  edge E13 "a bundle link written in another letter case" '[[Sub/S]]' 'mkdir -p "$B/sub"; note "$B/sub/s.md" s; printf "[s](sub/s.md)\n" >> "$B/index.md"'
  edge E13b "a bundle link in NFD to a file named in NFC" "[[$NFD]]" 'note "$B/$NFC.md" c; printf "[c](%s.md)\n" "$NFC" >> "$B/index.md"'
  # E15: the verdict comes from the rule, not from the disk: [[STRASSE]] does not name straße.md under lower(), so the L001
  # stays even where the disk folds the two (macOS).
  notl E15 "a vault link that only the disk's own case folding would match" '[[projects/p/STRASSE]]' 'printf "# s\n" > "$V/projects/p/straße.md"'
  # E14: a root one folder too shallow (the okf-knowledge-gate#13 layout needs ../../..): the L001 stays, and a hint names
  # the folder above the root that holds the target. E14b: a target that is nowhere gets no hint.
  V="$TMP/E14"; B="$V/projects/p/bundle"; mkvault "$V"; setroot "$B" ../..
  rc=$(runjson "$B"); "$CHECK" "$B" >"$TMP/out.txt" 2>&1
  { [ "$rc" = 0 ] && [ "$(jget 'd["l2_by_rule"]')" = '{"L001": 1}' ] \
    && grep -q 'hint: 1 L001 link(s) resolve from \.\./\.\./\.\., a folder above wikilink_root \.\./\.\.' "$TMP/out.txt" \
    && [ "$(jget 'd.get("l2_hint")')" = '"1 L001 link(s) resolve from ../../.., a folder above wikilink_root ../.."' ]; } \
    && ok "S15-WR-E14 wikilink_root one folder too shallow: the L001 stays and a hint names ../../.. (text and --json l2_hint)" \
    || bad "S15-WR-E14 shallow root hint" "rc=$rc by_rule=$(jget 'd["l2_by_rule"]') $(grep -n 'hint\|L001' "$TMP/out.txt" | tr '\n' ' ')"
  note "$B/a.md" 'See [[projects/p/MISSING]].'; "$CHECK" "$B" >"$TMP/out.txt" 2>&1
  { grep -q 'L001 x1' "$TMP/out.txt" && ! grep -q 'hint:' "$TMP/out.txt"; } \
    && ok "S15-WR-E14b a target that exists nowhere above the root gets no hint" \
    || bad "S15-WR-E14b no hint" "$(grep -n 'hint\|L001' "$TMP/out.txt" | tr '\n' ' ')"
  # E14c: the hint walk uses the same rule: a target written in another letter case is found above the root too.
  note "$B/a.md" 'See [[projects/p/readme]].'; "$CHECK" "$B" >"$TMP/out.txt" 2>&1
  grep -q 'hint: 1 L001 link(s) resolve from \.\./\.\./\.\.,' "$TMP/out.txt" \
    && ok "S15-WR-E14c the hint finds a target written in another letter case" \
    || bad "S15-WR-E14c hint and case" "$(grep -n 'hint\|L001' "$TMP/out.txt" | tr '\n' ' ')"

  section "S15-WR selftest probe"
  # S15-WR-S1: --selftest has a probe for the key, and it fires on the real script.
  "$CHECK" --selftest >"$TMP/st.txt" 2>&1; rc=$?
  { [ "$rc" = 0 ] && grep -q 'FIRED  *wikilink_root resolves an existing target only' "$TMP/st.txt"; } \
    && ok "S15-WR-S1 --selftest has a wikilink_root probe, and it fires on the real script (rc 0)" \
    || bad "S15-WR-S1 selftest probe" "rc=$rc $(grep -n 'wikilink\|SELFTEST' "$TMP/st.txt" | tr '\n' ' ')"
  # S15-WR-S2: a probe is proven by its gate going dead. A copy of the plugin whose root lookup finds nothing must exit 5.
  D2="$TMP/dead-root"; mkdir -p "$D2"; cp -R "$HERE/.." "$D2/plugin" 2>/dev/null
  cp "$D2/plugin/scripts/okf-check" "$TMP/okf-check.orig"
  "$REALPY" - "$D2/plugin/scripts/okf-check" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("    if _wl_root:\n", "    if False:\n", 1))
PYEOF
  if cmp -s "$D2/plugin/scripts/okf-check" "$TMP/okf-check.orig"; then
    bad "S15-WR-S2 crippled copy" "the cripple changed nothing"
  else
    "$D2/plugin/scripts/okf-check" --selftest >"$TMP/st-dead.txt" 2>&1; rc=$?
    { [ "$rc" = 5 ] && grep -q 'NOT FIRED  *wikilink_root resolves an existing target only' "$TMP/st-dead.txt"; } \
      && ok "S15-WR-S2 with the root lookup disabled, the probe reports NOT FIRED and --selftest exits 5" \
      || bad "S15-WR-S2 dead root lookup" "rc=$rc $(grep -n 'wikilink\|SELFTEST' "$TMP/st-dead.txt" | tr '\n' ' ')"
  fi
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
