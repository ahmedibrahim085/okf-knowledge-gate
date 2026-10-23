#!/usr/bin/env bash
# Tests for how every file walker treats symlinks (cases S8-H1, S8-N1, S8-E1 in docs/0.9.x-cases.md and
# docs/gherkin/s08-symlink-aliases.feature).
#
# The rule all walkers share is the vendored validator's, because that file is not ours to edit:
# Python's rglob never enters a symlinked FOLDER and does yield a symlinked FILE. So a folder link is
# either an alias of a folder already in the bundle (its notes are counted once, under their real
# path) or it points outside (its notes are not bundle notes); a note-file link counts when its real
# path is inside the bundle and is refused by name when it is outside (S58); a dangling link is skipped.
#
# Every walker is compared with the same LITERAL expected set, not only with the others: walkers that
# all failed the same way (all empty, all doubled) would otherwise agree and pass.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
VENDOR="$HERE/../vendor"
REALPY=$(command -v python3)
PASS=0; FAIL=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfsymlinks)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

# A note every walker reports by name: expired (L3 and the hook), a draft a human verified (Trust),
# no `tags` (an L1 warning) and no checkable claim (okf-verify's unverifiable list).
note() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: draft\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nverified:\n  by: human:t\n  at: "2026-01-02"\nstale_after: "2020-01-01"\n---\nbody\n' > "$1"
}

# The tree: one physical note, a folder alias of it, a folder link and a note-file link that point
# outside, a note-file alias inside, and a dangling link.
B="$TMP/b"; OUT="$TMP/out"
note "$B/real/sub/old.md"
note "$OUT/o.md"
note "$OUT/f.md"
ln -s real "$B/link"
ln -s ../out "$B/ext"
ln -s real/sub/old.md "$B/alias.md"
ln -s ../out/f.md "$B/outfile.md"
ln -s nowhere.md "$B/dang.md"
WANT=$(printf '%s\n' alias.md real/sub/old.md)   # outfile.md points outside the bundle: no walker reads it (S58)
WANT_BASE=$(printf '%s\n' alias.md old.md)

"$CHECK" "$B" --fail-stale > "$TMP/check.txt" 2>&1

# --- S8-H1: a note reached through a symlinked folder is listed once ----------------------------
{ [ "$(grep -c 'expired  real/sub/old.md' "$TMP/check.txt")" = 1 ] && ! grep -q 'link/sub/old.md' "$TMP/check.txt"; } \
  && ok "S8-H1 the expired note under real/ is listed once; the alias link/sub/old.md is not listed" \
  || bad "S8-H1 listed once" "$(grep -n 'expired\|L3' "$TMP/check.txt" | tr '\n' ' ')"

# --- S8-N1: notes behind a folder link that points outside are not bundle notes -----------------
{ ! grep -q 'ext/o.md\|ext/f.md' "$TMP/check.txt" && grep -q '2 symlinked folder(s) not entered' "$TMP/check.txt" \
  && grep -qxE ' +ext' "$TMP/check.txt" && grep -qxE ' +link' "$TMP/check.txt"; } \
  && ok "S8-N1 notes behind ext -> ../out are not counted, and the run names the folder link it did not enter" \
  || bad "S8-N1 outside link" "$(grep -n 'ext\|symlink' "$TMP/check.txt" | tr '\n' ' ')"

# --- S8-E1: every walker returns the same file set ----------------------------------------------
# 1 L1 as okf-check runs it (the vendored validator on the frozen copy): files named in a "`tags` is absent" warning
v=$("$CHECK" "$B" --json 2>/dev/null \
  | "$REALPY" -c 'import json,sys; print("\n".join(sorted(w.split(":")[0] for w in json.load(sys.stdin)["warnings"] if "`tags` is absent" in w)))')
# 2 okf-trust.py (Trust): files with a finding
PYTHONPATH="$VENDOR/pyyaml" "$REALPY" "$HERE/okf-trust.py" "$B" "$TMP/trust.json" >/dev/null 2>&1
t=$("$REALPY" -c 'import json,sys; print("\n".join(sorted({f["file"] for f in json.load(open(sys.argv[1]))})))' "$TMP/trust.json" 2>/dev/null)
# 3 okf-check L3: expired lines
l=$(sed -n 's/^  expired  \(.*\) (stale_after.*/\1/p' "$TMP/check.txt" | sort)
# 4 ignore-lib.sh --list (the .okfignore walker)
i=$(bash "$HERE/ignore-lib.sh" --list "$B" 2>/dev/null | tr '\0' '\n' | sort)
# 5 okf-verify: the unverifiable list (indented names after its header)
"$HERE/okf-verify" "$B" > "$TMP/verify.txt" 2>&1
r=$(sed -n '/no checkable claim/,$s/^  *\([^ ].*\.md\)$/\1/p' "$TMP/verify.txt" | sort)
# 6 the SessionStart staleness hook: it prints base names, so compare base names (duplicates kept). It prints
# JSON when jq is installed and plain text when not; the entry pattern is read from the raw output in both forms.
h=$(OKF_BUNDLE_DIR="$B" OKF_TODAY=2026-10-18 bash "$HERE/lessons-staleness-check.sh" 2>/dev/null \
  | "$REALPY" -c 'import re,sys; print("\n".join(sorted(re.findall(r"- (\S+\.md) \(stale_after", sys.stdin.read()))))' 2>/dev/null)
diff_all=""
for pair in "validator:$v" "trust:$t" "L3:$l" "ignore-lib:$i" "okf-verify:$r"; do
  [ "${pair#*:}" = "$WANT" ] || diff_all="$diff_all [${pair%%:*}: $(printf '%s' "${pair#*:}" | tr '\n' ' ')]"
done
[ "$h" = "$WANT_BASE" ] || diff_all="$diff_all [hook: $(printf '%s' "$h" | tr '\n' ' ')]"
[ -z "$diff_all" ] \
  && ok "S8-E1 L1, Trust, L3, ignore-lib, okf-verify and the hook all return {alias.md, real/sub/old.md}" \
  || bad "S8-E1 walkers differ from {alias.md real/sub/old.md}" "$diff_all"

# --- S58: only paths whose real path is inside the bundle are read --------------------------------
# One bundle, every layer switched on. Outside it: a file with no frontmatter (ITEM=...) and two notes whose
# frontmatter would give a finding in every layer. Inside it: a note reached through a symlink (S58-H1).
export HOME="$TMP/home"; export GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"   # git below runs with no host config or credentials
O="$TMP/o58"; C="$TMP/b58"; mkdir -p "$O" "$C/sub"
printf -- '---\nokf_version: "0.2"\n---\n# I\n' > "$C/index.md"
printf -- '---\ntype: Lesson\ntitle: Same Title\ndescription: inside\nstatus: stable\nowner: human:me\ntags: [a]\nstale_after: "2099-01-01"\n---\nITEM=x\nKept line one.\n' > "$C/in.md"
printf -- '---\ntype: Lesson\ntitle: Real\ndescription: real\nstatus: stable\nowner: human:me\ntags: [a]\nstale_after: "2099-01-01"\n---\nITEM=insidelink\n' > "$C/sub/real.md"
: > "$C/src.txt"
base58() { sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$HERE/../config/okf-base.yaml.template"
  printf 'okf_check:\n  require_owner: true\n  deprecated_requires: superseded_by\n  size:\n    max_body_chars: 60\n  facts:\n    tok:\n      value: "x"\n      patterns: ["ITEM=? *(.+)"]\n'; }
base58 > "$C/okf-base.yaml"
printf 'ITEM=dummy-outside-1\n' > "$O/plain.txt"
printf -- '---\ntype: Lesson\ntitle: Same Title\ndescription: outside one\nstatus: draft\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nverified:\n  by: human:outmark\n  at: "2026-01-02"\nstale_after: "2020-01-01"\n---\nITEM=dummy-outside-2 and a body that is longer than sixty characters in all\nKept line two.\n' > "$O/o1.md"
printf -- '---\ntype: Lesson\ntitle: Two\ndescription: outside two\nstatus: deprecated\nstale_after: "2099-01-01"\nsources:\n  - resource: src.txt\n    last_modified: "2000-01-01"\n---\nshort\n' > "$O/o2.md"
ln -s "$O/plain.txt" "$C/olink0.md"; ln -s ../o58/o1.md "$C/olink1.md"; ln -s ../o58/o2.md "$C/olink2.md"
ln -s sub/real.md "$C/inlink.md"; ln -s ../o58 "$C/extdir"
OUTS='olink[012]\.md|extdir/|dummy-outside|outmark'
"$CHECK" "$C" --fail-stale > "$TMP/c58.txt" 2>&1; rc58=$?
# block <header>: the lines of one layer, from its header to the next layer's header
block() { awk -v h="  $1" 'index($0, h) == 1 {on = 1; print; next} on && /^  [A-Z]/ {on = 0} on' "$TMP/c58.txt"; }

# --- S58-N1: a note whose real path is outside the bundle: named, not read, the run fails ----------
{ [ "$rc58" = 1 ] && grep -q 'olink0.md — points outside the bundle: not read' "$TMP/c58.txt" \
  && grep -q 'olink1.md — points outside the bundle: not read' "$TMP/c58.txt" \
  && grep -q 'olink2.md — points outside the bundle: not read' "$TMP/c58.txt"; } \
  && ok "S58-N1 the three outside links are named (points outside the bundle: not read) and the run exits 1" \
  || bad "S58-N1 named and exit 1" "rc=$rc58 $(grep -n 'outside\|Refused' "$TMP/c58.txt" | tr '\n' ' ')"
for layer in "L1 conformance" "Trust (C4)" "L2 profile" "Successor" "Owner" "Size" "Facts" "L3 staleness" "L3 derived"; do
  hit=$(block "$layer" | grep -E "$OUTS")
  [ -z "$hit" ] && ok "S58-N1 $layer reports nothing from an outside path" \
    || bad "S58-N1 $layer reads an outside path" "$(printf '%s' "$hit" | tr '\n' ' ')"
done

# --- S58-H1: a symlink inside the bundle is still read ----------------------------------------------
grep -q 'insidelink' <<< "$(block Facts)" && ok "S58-H1 Facts still reads inlink.md -> sub/real.md (inside the bundle)" \
  || bad "S58-H1 inside link read" "$(block Facts | tr '\n' ' ')"

# --- S58-N2: a symlinked folder whose real path is outside: its notes are not read, the folder is named
{ ! grep -q 'extdir/' "$TMP/c58.txt" && grep -qxE ' +extdir' "$TMP/c58.txt"; } \
  && ok "S58-N2 no note below extdir -> ../o58 is read, and extdir is named on the symlinks line" \
  || bad "S58-N2 outside folder" "$(grep -n 'extdir' "$TMP/c58.txt" | tr '\n' ' ')"

# --- S58-N3: a config file whose real path is outside is named, and the run does not pass ------------
cfg58() {   # <name> <file in the bundle> <outside content>: a bundle whose <file> is a symlink to an outside file
  local d="$TMP/cfg-$1"; mkdir -p "$d" "$O/$1"
  printf -- '---\nokf_version: "0.2"\n---\n# I\n' > "$d/index.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [a]\n---\nITEM=y\n' > "$d/in.md"
  [ "$2" = okf-base.yaml ] || base58 > "$d/okf-base.yaml"
  printf '%s\n' "$3" > "$O/$1/target"; ln -s "$O/$1/target" "$d/$2"
  "$CHECK" "$d" > "$TMP/cfg-$1.txt" 2>&1; echo $?
}
rc=$(cfg58 base okf-base.yaml "$(base58)")
{ [ "$rc" != 0 ] && grep -q 'okf-base.yaml — points outside the bundle: not read' "$TMP/cfg-base.txt" && ! grep -q 'FACT-CONFLICT' "$TMP/cfg-base.txt"; } \
  && ok "S58-N3 an okf-base.yaml outside the bundle is named and not read (exit $rc)" \
  || bad "S58-N3 okf-base.yaml" "rc=$rc $(grep -n 'okf-base\|FACT' "$TMP/cfg-base.txt" | tr '\n' ' ')"
"$HERE/okf-verify" "$TMP/cfg-base" > "$TMP/cfg-base.v" 2>&1; rc=$?
{ [ "$rc" = 2 ] && grep -q 'okf-base.yaml points outside the bundle: not read' "$TMP/cfg-base.v"; } \
  && ok "S58-N3 okf-verify does not read an okf-base.yaml outside the bundle (exit 2, named)" \
  || bad "S58-N3 okf-verify okf-base.yaml" "rc=$rc $(tr '\n' ' ' < "$TMP/cfg-base.v")"
rc=$(cfg58 ign .okfignore "in.md")
{ [ "$rc" != 0 ] && grep -q '\.okfignore points outside the bundle: not read' "$TMP/cfg-ign.txt" && ! grep -q 'file(s) excluded' "$TMP/cfg-ign.txt"; } \
  && ok "S58-N3 an .okfignore outside the bundle is named and not read (exit $rc)" \
  || bad "S58-N3 .okfignore" "rc=$rc $(grep -n 'okfignore\|ignore' "$TMP/cfg-ign.txt" | tr '\n' ' ')"
rc=$(cfg58 json notes.json '{"a": 1}')
{ [ "$rc" != 0 ] && grep -q 'notes.json — points outside the bundle: not read' "$TMP/cfg-json.txt"; } \
  && ok "S58-N3 a notes.json outside the bundle is named (exit $rc)" \
  || bad "S58-N3 notes.json" "rc=$rc $(tr '\n' ' ' < "$TMP/cfg-json.txt" | cut -c1-300)"

# --- S58-E1: every other mode that reads notes leaves the outside notes unread -----------------------
"$CHECK" "$C" --facts > "$TMP/e58.out" 2> "$TMP/e58.err"
{ ! grep -qE "$OUTS" "$TMP/e58.out" && grep -q insidelink "$TMP/e58.out" && grep -q 'olink1.md — points outside the bundle: not read' "$TMP/e58.err"; } \
  && ok "S58-E1 --facts lists no outside text, still lists the inside link, and names the outside note on stderr" \
  || bad "S58-E1 --facts" "out: $(tr '\n' ' ' < "$TMP/e58.out") err: $(tr '\n' ' ' < "$TMP/e58.err")"
"$CHECK" "$C" --duplicates > "$TMP/e58.out" 2> "$TMP/e58.err"
{ ! grep -qE "$OUTS" "$TMP/e58.out" && grep -q 'olink1.md — points outside the bundle: not read' "$TMP/e58.err"; } \
  && ok "S58-E1 --duplicates pairs no outside note and names it on stderr" \
  || bad "S58-E1 --duplicates" "out: $(tr '\n' ' ' < "$TMP/e58.out") err: $(tr '\n' ' ' < "$TMP/e58.err")"
"$CHECK" "$C" --file "$C/olink1.md" > "$TMP/e58.out" 2>&1; rc=$?
{ [ "$rc" = 1 ] && ! grep -q outmark "$TMP/e58.out" && grep -q 'olink1.md: L1 error: refused, points outside the bundle: not read' "$TMP/e58.out"; } \
  && ok "S58-E1 --file on an outside note is one refusal line, exit 1" \
  || bad "S58-E1 --file" "rc=$rc $(tr '\n' ' ' < "$TMP/e58.out")"
"$REALPY" -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$C/olink1.md" \
  | OKF_EDIT_HOOK=1 "$REALPY" "$HERE/okf-edit-hook.py" > /dev/null 2> "$TMP/e58.err"; rc=$?
{ [ "$rc" = 2 ] && ! grep -q outmark "$TMP/e58.err" && grep -q 'points outside the bundle' "$TMP/e58.err"; } \
  && ok "S58-E1 the edit hook on an outside note warns with the refusal, not with the note's text" \
  || bad "S58-E1 edit hook" "rc=$rc $(tr '\n' ' ' < "$TMP/e58.err")"
"$HERE/okf-verify" "$C" > "$TMP/e58.out" 2>&1
grep -q 'refused: points outside the bundle' <<< "$(grep -A1 'unresolved  olink1.md' "$TMP/e58.out")" \
  && ok "S58-E1 okf-verify does not open the outside note and says why" \
  || bad "S58-E1 okf-verify" "$(grep -n 'olink' "$TMP/e58.out" | tr '\n' ' ')"
# --conserve: a line removed from in.md that only the outside note still holds is lost, not moved
G="$TMP/g58"; mkdir -p "$G"; cp -R "$C" "$G/b"; rm -f "$G/b/extdir" "$G/b/olink1.md"; ln -s ../../o58/o1.md "$G/b/olink1.md"
gitc() { git -C "$G" -c user.name=t -c user.email=t@e -c commit.gpgsign=false -c credential.helper= "$@"; }
gitc init -q && printf 'Kept line two.\n' >> "$G/b/in.md" && gitc add -A && gitc commit -qm base
grep -v 'Kept line two.' "$G/b/in.md" > "$G/in.tmp" && mv "$G/in.tmp" "$G/b/in.md"
"$CHECK" "$G/b" --conserve HEAD --fail-lost > "$TMP/e58.out" 2>&1; rc=$?
{ [ "$rc" = 1 ] && grep -q 'Kept line two' "$TMP/e58.out"; } \
  && ok "S58-E1 --conserve does not count a line that only an outside note holds as moved (exit 1 with --fail-lost)" \
  || bad "S58-E1 --conserve" "rc=$rc $(tr '\n' ' ' < "$TMP/e58.out" | cut -c1-300)"
"$HERE/okf-verify" "$TMP/cfg-ign" > "$TMP/e58.out" 2>&1; rc=$?
{ [ "$rc" = 2 ] && [ "$(grep -c '\.okfignore points outside the bundle: not read' "$TMP/e58.out")" = 1 ] && ! grep -q 'file(s) excluded' "$TMP/e58.out"; } \
  && ok "S58-E1 okf-verify names an .okfignore outside the bundle once and stops with exit 2, as for okf-base.yaml" \
  || bad "S58-E1 okf-verify .okfignore" "rc=$rc $(tr '\n' ' ' < "$TMP/e58.out" | cut -c1-300)"

# --- S58-R1: the reader judges the file it opened, not only the path it checked ----------------------
# Deterministic: the path check is switched off (as if the path changed after it), so only the check on the opened
# descriptor stands between the reader and the outside file.
R="$TMP/r58"; mkdir -p "$R/b" "$R/o"; printf 'ITEM=dummy-outside-3\n' > "$R/o/plain.txt"; printf 'ITEM=x\n' > "$R/b/in.md"
ln -s "$R/o/plain.txt" "$R/b/olink3.md"; head -c 100 /dev/zero | tr '\0' 'a' > "$R/o/big.json"; ln -s "$R/o/big.json" "$R/b/big.json"
PYTHONPATH="$HERE" "$REALPY" - "$R/b" > "$TMP/r58.out" 2>&1 <<'PY'
import os, sys
import okf_guard
b = sys.argv[1]
okf_guard.refusal = lambda *a, **k: None
try:
    print("LINK READ " + okf_guard.read_note(os.path.join(b, "olink3.md"), root=b).strip())
except okf_guard.NoteRefused as e:
    print("LINK REFUSED " + str(e))
print("INSIDE READ " + okf_guard.read_note(os.path.join(b, "in.md"), root=b).strip())
try:
    okf_guard.read_note(os.path.join(b, "in.md"))
    print("NOROOT READ")
except TypeError:
    print("NOROOT REQUIRED")
print("FREEZE " + str(okf_guard.freeze_one(os.path.join(b, "big.json"), os.path.join(b, "copy.json"), 10, False, root=b)))
PY
r58=$(<"$TMP/r58.out")
grep -qx 'LINK REFUSED points outside the bundle' <<< "$r58" && ok "S58-R1 read_note refuses an opened file whose real path is outside the bundle" \
  || bad "S58-R1 read_note descriptor check" "$r58"
grep -qx 'INSIDE READ ITEM=x' <<< "$r58" && ok "S58-R1 read_note still reads a note inside the bundle" || bad "S58-R1 inside read" "$r58"
grep -qx 'NOROOT REQUIRED' <<< "$r58" && ok "S58-R1 read_note needs root: a caller cannot leave the check out" || bad "S58-R1 root required" "$r58"
grep -qx 'FREEZE points outside the bundle' <<< "$r58" && ok "S58-R1 the frozen copy refuses an outside config file before it would link an oversize one" \
  || bad "S58-R1 freeze order" "$r58"
# the facts reader does not trust the list it is handed
printf '%s\0' "$C/olink0.md" "$C/olink1.md" "$C/in.md" > "$TMP/r58.lst"
PYTHONPATH="$VENDOR/pyyaml:$VENDOR" OKF_SCRIPTS_DIR="$HERE" OKF_VENDOR_DIR="$VENDOR" "$REALPY" "$HERE/okf-facts.py" "$C" "$C/okf-base.yaml" "$TMP/r58.lst" list > "$TMP/r58.out" 2>&1
{ ! grep -q 'dummy-outside' "$TMP/r58.out" && grep -q 'in.md' "$TMP/r58.out"; } \
  && ok "S58-R1 okf-facts.py does not read an outside note that its list names" || bad "S58-R1 okf-facts list" "$(tr '\n' ' ' < "$TMP/r58.out")"

# --- S58-R2: okf-export judges the file it opened, not only the listing ------------------------------
# Deterministic: a.md and b.png are swapped for links to an outside file after the listing judged them (the hook is
# case_clashes, which main() calls between the listing and the copy).
X="$TMP/x58"; mkdir -p "$X/v"; printf '# A\nplain\n' > "$X/v/a.md"; printf 'PNG\n' > "$X/v/b.png"; printf 'ITEM=dummy-outside-4\n' > "$O/plain4.txt"
"$REALPY" - "$HERE/okf-export" "$X/v" "$X/out" "$O/plain4.txt" > "$TMP/x58.out" 2>&1 <<'PY'
import importlib.machinery, importlib.util, os, sys
exp, vault, out, outside = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("okf_export", exp)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(m)
listed = m.case_clashes
def swap(*a, **k):
    for n in ("a.md", "b.png"):
        os.remove(os.path.join(vault, n))
        os.symlink(outside, os.path.join(vault, n))
    return listed(*a, **k)
m.case_clashes = swap
sys.argv = ["okf-export", vault, out]
print("EXIT", m.main())
PY
{ ! grep -rqs 'dummy-outside' "$X/out" && grep -q '^EXIT 1$' "$TMP/x58.out" && grep -q 'a.md — points outside the vault' "$TMP/x58.out" && grep -q 'b.png — points outside the vault' "$TMP/x58.out"; } \
  && ok "S58-R2 okf-export copies no file swapped for an outside link after its listing, names both and exits 1" \
  || bad "S58-R2 okf-export swap" "$(tr '\n' ' ' < "$TMP/x58.out" | cut -c1-300) out: $(grep -rl 'dummy-outside' "$X/out" 2>/dev/null | tr '\n' ' ')"

# --- S58-H2: the bundle path typed in another case (a case-insensitive disk) --------------------------
K="$TMP/CaseB"; mkdir -p "$K/sub"; cp "$C/index.md" "$C/in.md" "$C/okf-base.yaml" "$K/"
printf -- '---\ntype: Lesson\ntitle: R\ndescription: r\nowner: human:me\ntags: [a]\n---\nITEM=insidecase\n' > "$K/sub/real.md"
ln -s "$K/sub/real.md" "$K/abs.md"; ln -s "$O/o1.md" "$K/olinkc.md"
if [ -d "$TMP/caseb" ]; then
  "$CHECK" "$TMP/caseb" > "$TMP/k58.txt" 2>&1
  { ! grep -q 'abs.md — points outside' "$TMP/k58.txt" && grep -q 'abs.md:.*insidecase' "$TMP/k58.txt" \
    && grep -q 'olinkc.md — points outside the bundle: not read' "$TMP/k58.txt"; } \
    && ok "S58-H2 with the bundle path in another case, an absolute link inside is read and one outside is refused" \
    || bad "S58-H2 case-insensitive disk" "$(grep -n 'abs.md\|olinkc' "$TMP/k58.txt" | tr '\n' ' ')"
else
  printf '  SKIP  S58-H2 the disk is case-sensitive: a path in another case is another path\n'
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
