#!/usr/bin/env bash
# Tests for how every file walker treats symlinks (cases S8-H1, S8-N1, S8-E1 in docs/0.9.x-cases.md and
# docs/gherkin/s08-symlink-aliases.feature).
#
# The rule all walkers share is the vendored validator's, because that file is not ours to edit:
# Python's rglob never enters a symlinked FOLDER and does yield a symlinked FILE. So a folder link is
# either an alias of a folder already in the bundle (its notes are counted once, under their real
# path) or it points outside (its notes are not bundle notes); a note-file link counts wherever it
# points; a dangling link is skipped.
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
WANT=$(printf '%s\n' alias.md outfile.md real/sub/old.md)
WANT_BASE=$(printf '%s\n' alias.md old.md outfile.md)

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
# 1 the vendored validator (L1): files named in a "`tags` is absent" warning
v=$(PYTHONPATH="$VENDOR/pyyaml" "$REALPY" "$VENDOR/okf_validate.py" "$B" --json 2>/dev/null \
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
  && ok "S8-E1 validator, Trust, L3, ignore-lib, okf-verify and the hook all return {alias.md, outfile.md, real/sub/old.md}" \
  || bad "S8-E1 walkers differ from {alias.md outfile.md real/sub/old.md}" "$diff_all"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
