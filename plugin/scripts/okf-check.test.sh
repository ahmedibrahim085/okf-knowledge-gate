#!/usr/bin/env bash
# Tests for okf-check. Run: tools/okf-check.test.sh
#
# `--selftest` proves the GATES fire. This file proves OKF-CHECK ITSELF behaves —
# exit codes, skip semantics, and the summary line. Both are needed: a gate that
# fires correctly but exits 0 is still a green CI over a broken bundle.
#
# bash 3.2 compatible (macOS ships 3.2 — no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
. "$HERE/../tests/okf-test-lib.sh"


# --- deterministic mid-scan change ------------------------------------------
section "deterministic mid-scan change"
# E-7d and G-1b used to RACE: a background writer with `sleep 0.20`, three
# retries, and a SKIP when the write missed the window. Measured 8/12 skips in
# one configuration and 0/12 in another — coverage that came and went with
# machine load, which is precisely the debt the skip counter exposed.
#
# The race is NOT the behaviour under test. What the gate must do is notice that
# the bundle it fingerprinted before the layers is not the one it fingerprints
# after, and that condition is injectable with certainty: a `stat` shim that
# appends one extra line the SECOND time bundle_fingerprint asks. FP_BEFORE !=
# FP_AFTER on every run, no timing involved.
#
# No production surface is added for this. The shim lives in the test and is
# reached through PATH, the same technique the okflint tests already use. The
# flavour probe (`stat -f '%z' /dev/null`) is deliberately not matched, so
# BSD/GNU selection still happens normally.
REALSTAT=$(command -v stat)
mk_racing_stat() {   # <dir-to-hold-the-shim>
  mkdir -p "$1"
  cat > "$1/stat" <<SHIM
#!/bin/sh
case "\$*" in
  *"%z %Fm %N"*|*"%s %y %n"*)
    n=\$(cat "$1/.calls" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$1/.calls"
    "$REALSTAT" "\$@"
    [ "\$n" -ge 2 ] && echo "4242 0.0 /injected/mid-scan-change.md"
    ;;
  *) exec "$REALSTAT" "\$@" ;;
esac
SHIM
  chmod +x "$1/stat"
  rm -f "$1/.calls"
}

echo "okf-check tests"

# --- structural -------------------------------------------------------------
section "structural"
[ -x "$CHECK" ] && ok "okf-check is executable" || bad "okf-check is executable" "chmod +x needed"
expect_exit 0  "H-6 --version exits 0"            -- "$CHECK" --version
expect_exit 64 "N-5 no bundle arg is a usage error" -- "$CHECK"
expect_exit 64 "N-6 unknown flag is rejected"     -- "$CHECK" --nope
expect_exit 64 "N-7 non-directory bundle rejected" -- "$CHECK" /etc/hosts

# --- doctor -----------------------------------------------------------------
section "doctor"
expect_exit  0 "H-2 doctor passes with deps present" -- "$CHECK" --doctor
expect_match "okf_validate.py" "doctor reports the vendored validator" "$CHECK" --doctor
# LT-12 (ticket 12): the doctor probes okflint BEHAVIOUR on three notes (mattdav/okflint#8, okflint#9,
# okflint#10 -> okflint#11), because the patched build and stock 0.5.0 report the same version string.
# A STUB okflint decides per probe file from $STUB_BAD (comma list: bom,latin1,date).
if command -v okflint >/dev/null 2>&1; then
  T12="$TMP/t12bin"; mkdir -p "$T12"
  cat > "$T12/okflint" <<'STUB'
#!/bin/sh
if [ "$1" = validate ]; then
  bad=",${STUB_BAD:-},"
  if [ -f probe-bom.md ]; then
    case "$bad" in *,bom,*) echo '[{"code": "F001", "file": "probe-bom.md"}]'; exit 1 ;; esac
  fi
  if [ -f probe-latin1.md ]; then
    # the stub also checks the fixture BYTES: an empty file would prove nothing (found 2026-10-14)
    LC_ALL=C grep -q "$(printf '\351')" probe-latin1.md || { echo "stub: latin1 fixture has no 0xE9 byte" >&2; exit 9; }
    case "$bad" in *,latin1,*) echo "UnicodeDecodeError: stub" >&2; exit 1 ;; esac
  fi
  if [ -f probe-baddate.md ]; then
    grep -q '2026-02-30' probe-baddate.md || { echo "stub: date fixture is empty" >&2; exit 9; }
    case "$bad" in *,date,*) echo "ValueError: stub" >&2; exit 1 ;; esac
  fi
  echo '[]'; exit 0
fi
exec "$REALLINT" "$@"
STUB
  chmod +x "$T12/okflint"
  export REALLINT; REALLINT=$(command -v okflint)
  expect_match "okflint behaviour .*PATCHED" "LT-12b doctor reports an okflint that passes all three probes" env PATH="$T12:$PATH" STUB_BAD= "$CHECK" --doctor
  expect_no_match "okflint behaviour .*UNPATCHED" "LT-12c a patched okflint raises no UNPATCHED line" env PATH="$T12:$PATH" STUB_BAD= "$CHECK" --doctor
  expect_match "UNPATCHED.*BOM note" "LT-12a doctor flags an okflint that fails the BOM note (okflint#8)" env PATH="$T12:$PATH" STUB_BAD=bom "$CHECK" --doctor
  expect_match "UNPATCHED.*non-UTF-8" "LT-12e doctor flags an okflint that crashes on a non-UTF-8 note (okflint#9)" env PATH="$T12:$PATH" STUB_BAD=latin1 "$CHECK" --doctor
  expect_match "UNPATCHED.*impossible date" "LT-12f doctor flags an okflint that crashes on an impossible date (okflint#10)" env PATH="$T12:$PATH" STUB_BAD=date "$CHECK" --doctor
  expect_exit 0 "LT-12d an UNPATCHED okflint is advisory: doctor still exits 0" -- env PATH="$T12:$PATH" STUB_BAD=bom,latin1,date "$CHECK" --doctor
  # LT-12g: a build that gives no verdict on a CLEAN note proves nothing: UNKNOWN, not UNPATCHED.
  T12G="$TMP/t12gbin"; mkdir -p "$T12G"
  printf '#!/bin/sh\nif [ "$1" = validate ]; then echo "Manifest error: stub" >&2; exit 2; fi\nexec "%s" "$@"\n' "$REALLINT" > "$T12G/okflint"; chmod +x "$T12G/okflint"
  expect_match "okflint behaviour  UNKNOWN" "LT-12g an okflint with no verdict on a clean note is UNKNOWN" env PATH="$T12G:$PATH" "$CHECK" --doctor
  expect_no_match "UNPATCHED" "LT-12g2 UNKNOWN is never reported as UNPATCHED" env PATH="$T12G:$PATH" "$CHECK" --doctor
  # LT-12h: a missing template skips the probes WITH a stated reason.
  T12H="$TMP/t12hplug"; cp -R "$HERE/.." "$T12H"; rm -f "$T12H/config/okf-base.yaml.template"
  expect_match "okflint behaviour  UNKNOWN.*template" "LT-12h a missing template is stated, not silent" "$T12H/scripts/okf-check" --doctor
else
  skip "LT-12 okflint behaviour probe — okflint absent" "uv tool install okflint"
fi

# LT-13 (ecosystem ticket 01): L2 groups advisory findings by rule code, and the doctor checks
# okflint's `validate-manifest` command against the shipped template.
if command -v okflint >/dev/null 2>&1 && [ -f "$HERE/../config/okf-base.yaml.template" ]; then
  T13="$TMP/t13bin"; mkdir -p "$T13"
  cat > "$T13/okflint" <<'STUB'
#!/bin/sh
case "$1" in
  validate)
    echo '[{"code":"S208","severity":"warning","file":"a.md","message":"x"},{"code":"S208","severity":"warning","file":"b.md","message":"x"},{"code":"S209","severity":"warning","file":"a.md","message":"y"}]'
    exit 0 ;;
  validate-manifest)
    case "$STUB_MANIFEST" in
      reject) echo "Manifest error: stub rejects it" >&2; exit 2 ;;
      *) echo "Manifest OK"; exit 0 ;;
    esac ;;
  --help) if [ "$STUB_NOCMD" = 1 ]; then echo "usage: okflint {audit,validate,index}"; else echo "usage: okflint {audit,validate,validate-manifest,index}"; fi; exit 0 ;;
esac
exec "$REALLINT" "$@"
STUB
  chmod +x "$T13/okflint"; export REALLINT; REALLINT=$(command -v okflint)
  T13B="$TMP/t13bundle"; mkdir -p "$T13B"; sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$T13B/okf-base.yaml"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2099-01-01"\n---\nbody\n' > "$T13B/a.md"
  expect_match "by rule: S208 x2, S209 x1" "LT-13a L2 groups advisory findings by rule code" env PATH="$T13:$PATH" "$CHECK" "$T13B"
  expect_match "okflint manifest check  OK" "LT-13b doctor: validate-manifest accepts the shipped template" env PATH="$T13:$PATH" "$CHECK" --doctor
  expect_match "okflint manifest check  REJECTED.*stub rejects it" "LT-13c doctor: a rejected template names okflint's reason" env PATH="$T13:$PATH" STUB_MANIFEST=reject "$CHECK" --doctor
  expect_match "okflint manifest check  UNAVAILABLE" "LT-13d doctor: an okflint without validate-manifest is UNAVAILABLE, not an error" env PATH="$T13:$PATH" STUB_NOCMD=1 "$CHECK" --doctor
  expect_exit 0 "LT-13e a REJECTED template is advisory: doctor exits 0" -- env PATH="$T13:$PATH" STUB_MANIFEST=reject "$CHECK" --doctor
  # LT-13f: more than six rule codes: the line says how many were dropped.
  cat > "$T13/okflint8" <<'STUB'
#!/bin/sh
if [ "$1" = validate ]; then
  printf '['; i=0
  for c in S201 S202 S203 S204 S205 S206 S207 S208; do
    [ $i -gt 0 ] && printf ','; printf '{"code":"%s","severity":"warning","file":"a.md","message":"x"}' "$c"; i=$((i+1))
  done
  printf ']\n'; exit 0
fi
exec "$REALLINT" "$@"
STUB
  T13C="$TMP/t13cbin"; mkdir -p "$T13C"; cp "$T13/okflint8" "$T13C/okflint"; chmod +x "$T13C/okflint"
  expect_match "by rule: .*(+2 more" "LT-13f the by-rule line reports codes beyond the cap" env PATH="$T13C:$PATH" "$CHECK" "$T13B"
else
  skip "LT-13 okflint manifest check and rule grouping — okflint or the template is absent" "uv tool install okflint"
fi

# --- selftest ---------------------------------------------------------------
section "selftest"
expect_exit  0 "H-3 selftest passes (every gate fires)" -- "$CHECK" --selftest
expect_match "FIRED" "selftest reports fired gates" "$CHECK" --selftest

# --- L1 conformance ---------------------------------------------------------
section "L1 conformance"
CLEAN="$TMP/clean"; mkbundle "$CLEAN"
expect_exit 0 "H-1 clean bundle passes" -- "$CHECK" "$CLEAN"

DIRTY="$TMP/dirty"; mkbundle "$DIRTY"
printf 'no frontmatter\n' > "$DIRTY/broken.md"
expect_exit 1 "non-conformant bundle exits 1" -- "$CHECK" "$DIRTY"
expect_match "11.1" "L1 cites the spec section" "$CHECK" "$DIRTY"

# N-2: an empty/whitespace `type` is a §11.2 conformance ERROR. The spec marked
# this ✅ while the only real fixture was N-1's "no frontmatter"; §11.2 was
# exercised solely by a --selftest probe, which is not what the ✅ legend means.
EMPTYT="$TMP/emptytype"; mkbundle "$EMPTYT"
printf -- '---\ntype: "   "\ntitle: T\ndescription: D\n---\nbody\n' > "$EMPTYT/ws.md"
expect_exit 1 "N-2 whitespace-only type is a conformance error" -- "$CHECK" "$EMPTYT"
expect_match "11.2" "N-2 cites §11.2 for an empty type" "$CHECK" "$EMPTYT"

# H-5: L3's PASS state, isolated. It previously rode on the clean bundle's
# overall exit 0, which conflates all three layers.
expect_match "L3 staleness     PASS" "H-5 L3 reports PASS on a bundle with nothing expired" "$CHECK" "$CLEAN"

# --- L2 profile -------------------------------------------------------------
section "L2 profile"
if command -v okflint >/dev/null 2>&1; then
  PROF="$TMP/prof"; mkbundle "$PROF"
  sed 's/^  name: CHANGE ME/  name: Test/' "$HERE/../config/okf-base.yaml.template" > "$PROF/okf-base.yaml"
  expect_exit 0 "H-4 clean bundle passes the house profile" -- "$CHECK" "$PROF"
  # a Lesson with no stale_after violates the house profile but NOT the spec:
  # this is the case that proves L1 and L2 are genuinely different layers.
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\n---\nbody\n' > "$PROF/nostale.md"
  expect_exit 3 "N-3 house-rule violation exits 3, not 1" -- "$CHECK" "$PROF"
  expect_match "F102" "L2 cites the okflint rule code" "$CHECK" "$PROF"
  # N-4: a REAL bundle whose status is outside the manifest vocabulary. F102
  # (missing field) was covered; F105 (bad value) appeared only inside a STUBBED
  # okflint output, which tests the parser, not the rule.
  rm -f "$PROF/nostale.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: current\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$PROF/badstatus.md"
  expect_exit 3 "N-4 a status outside the vocabulary exits 3" -- "$CHECK" "$PROF"
  expect_match "F105" "N-4 cites F105 for an out-of-vocabulary status" "$CHECK" "$PROF"
  rm -f "$PROF/badstatus.md"
else
  skip "L2 tests — okflint not installed (this is a skip, not a pass)" "uv tool install okflint      # unlocks the L2 house-profile tests"
fi

# --- skip semantics: the defect that makes gates get ignored ----------------
section "skip semantics"
NOMAN="$TMP/noman"; mkbundle "$NOMAN"     # no okf-base.yaml -> L2 skipped
expect_no_match "ALL GATES PASS" "N-12 summary never claims a full pass when a layer skipped" "$CHECK" "$NOMAN"
expect_match "skipped layer" "summary names the skipped layer" "$CHECK" "$NOMAN"
# N-11: the spec claims the SKIP message NAMES THE TEMPLATE, but only the generic
# "skipped layer" substring was ever asserted — the specific behaviour was unpinned.
#
# The "no manifest" branch is only REACHED when okflint exists; without it
# run_profile returns earlier with a different (equally correct) reason. This
# assertion carried that assumption unguarded and FAILED on any machine where
# okflint is not installed — found by running the suite under a hard-isolated
# PATH, which is the check my earlier "clean machine" attempt failed to perform
# because the login profile silently restored /opt/homebrew.
#
# Stubbed rather than skipped: a fake okflint on PATH reaches the branch on
# every machine. Skipping here would trade one silent gap for another.
N11B="$TMP/n11bin"; mkdir -p "$N11B"
printf '#!/bin/sh\nexit 0\n' > "$N11B/okflint"; chmod +x "$N11B/okflint"
PATH="$N11B:$PATH" "$CHECK" "$NOMAN" >"$TMP/n11.txt" 2>&1
grep -q "okf-base.yaml.template" "$TMP/n11.txt" \
  && ok "N-11 the L2 skip names the manifest template to start from" \
  || bad "N-11 the L2 skip names the manifest template" "$(grep -i 'L2 profile' "$TMP/n11.txt" | head -1)"

# === EDGE CASES (spec .okf/specs/okf-check.md) ==============================
section "EDGE CASES (spec .okf/specs/okf-check.md)"
echo "  -- edge cases --"

# E-1: a directory with no .md files at all must not crash
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
expect_exit 0 "E-1 empty bundle does not crash" -- "$CHECK" "$EMPTY"

# E-2: a path with a SPACE. Not hypothetical — an unquoted `$(find …)` split 147
# files into 170 this same session and produced two retracted statistics.
SPACED="$TMP/with space/bundle"; mkbundle "$SPACED"
expect_exit 0 "E-2 bundle path containing a space" -- "$CHECK" "$SPACED"
expect_match "concepts" "E-2 spaced path still counts concepts" "$CHECK" "$SPACED"

# E-2b: the assertion that actually has teeth. Mutation-testing showed E-2 above
# passes even when `find` is unquoted — because it only checks that the run
# SUCCEEDS. The mutant reported "L3 staleness PASS nothing expired" on a bundle
# holding an expired concept: a false negative, the exact failure this gate
# exists to stop. A spaced path must still DETECT staleness, not merely exit 0.
# NOTE the marker: "need attention", not "expired". The PASS line reads "nothing
# expired", so `grep expired` matches success AND failure — a test that cannot
# fail. Mutation-testing exposed exactly that here.
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nbody\n' > "$SPACED/expired.md"
expect_match "need attention" "E-2b staleness is DETECTED on a spaced path (mutation-proven)" "$CHECK" "$SPACED"
expect_match "expired.md (stale_after" "E-2b names the expired file on a spaced path" "$CHECK" "$SPACED"
rm -f "$SPACED/expired.md"

# E-3: a binary .md must be a per-file error, not a crash of the whole run
BIN="$TMP/bin"; mkbundle "$BIN"; printf '\377\376 not utf8' > "$BIN/bad.md"
expect_exit 1 "E-3 binary .md is a per-file error, not a crash" -- "$CHECK" "$BIN"

# E-4: --json must emit parseable JSON
expect_exit 0 "E-4 --json on a clean bundle exits 0" -- "$CHECK" "$CLEAN" --json
"$CHECK" "$CLEAN" --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "E-4 --json output parses as JSON" || bad "E-4 --json output parses as JSON" "python json.load failed"

# E-5: invoked through a symlink (the plugin install layout) must still find vendor/
ln -sf "$CHECK" "$TMP/okf-check-link"
expect_exit 0 "E-5 symlinked invocation resolves vendor/" -- "$TMP/okf-check-link" "$CLEAN"

# E-6: symlinks. Not academic — ~/.claude/skills holds 30 symlinked directories,
# which is how a plugin-installed bundle is likely to be reached.
E6="$TMP/e6real"; mkbundle "$E6"
ln -s "$E6" "$TMP/e6link"
expect_exit 0 "E-6a bundle path IS a symlink" -- "$CHECK" "$TMP/e6link"
expect_match "concepts" "E-6a symlinked bundle still counts concepts" "$CHECK" "$TMP/e6link"

# E-6b is the one with teeth. `find -type f` does NOT match a symlink, so a
# symlinked concept is counted by L1 (python is_file() follows links) and MISSED
# by L3 — the two layers disagree about what is in the bundle. Same class as
# lessons/readdir-symlink-dirent-trap.md, in bash instead of Node.
printf -- '---\ntype: Lesson\ntitle: S\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2000-01-01"\n---\nbody\n' > "$TMP/e6outside.md"
ln -s "$TMP/e6outside.md" "$E6/linked.md"
expect_match "linked.md (stale_after" "E-6b L3 sees a SYMLINKED concept file" "$CHECK" "$E6"
"$CHECK" "$E6" >"$TMP/e6.txt" 2>&1
l1=$(grep -oE '[0-9]+ concepts' "$TMP/e6.txt" | grep -oE '[0-9]+')
l3=$(grep -cE 'stale_after 2000' "$TMP/e6.txt")
[ "${l1:-0}" -eq 2 ] && [ "${l3:-0}" -ge 1 ] \
  && ok "E-6b L1 and L3 agree on bundle contents (both see 2)" \
  || bad "E-6b L1 and L3 agree on bundle contents" "L1 counted ${l1:-?} concepts, L3 flagged ${l3:-0} expired"

# E-9: concepts in SUBDIRECTORIES. Same class as E-6b, one level deeper and
# considerably worse: L1 walks the tree with rglob while L3 used `-maxdepth 1`,
# so every nested concept was invisible to staleness. This repo's own .okf keeps
# ALL its concepts in subdirectories (decisions/, specs/, measurements/,
# corrections/) — L3 was checking nothing there and reporting PASS.
E9="$TMP/e9"; mkbundle "$E9"; mkdir -p "$E9/sub"
printf -- '---\ntype: Lesson\ntitle: Nested\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2000-01-01"\n---\nbody\n' > "$E9/sub/nested.md"
expect_match "nested.md (stale_after" "E-9 L3 sees an expired concept in a SUBDIRECTORY" "$CHECK" "$E9"
"$CHECK" "$E9" >"$TMP/e9.txt" 2>&1
l1=$(grep -oE '[0-9]+ concepts' "$TMP/e9.txt" | grep -oE '^[0-9]+')
l3=$(grep -c 'nested.md' "$TMP/e9.txt")
[ "${l1:-0}" -eq 2 ] && [ "${l3:-0}" -ge 1 ] \
  && ok "E-9 L1 and L3 agree across subdirectories" \
  || bad "E-9 L1 and L3 agree across subdirectories" "L1 counted ${l1:-?}, L3 flagged ${l3:-0}"

# E-9b: the E-7 FINGERPRINT must also see subdirectories, or a nested write
# during a scan goes undetected.
#
# The first version of this test asserted L1's concept COUNT — which comes from
# the validator's own rglob and is completely independent of bundle_fingerprint.
# Mutation-proven worthless: re-adding `-maxdepth 1` to the fingerprint, the very
# regression E-9 exists to prevent, left the suite green. The fingerprint's only
# observable effect is the CONCURRENT notice, so that is what must be asserted. (H5)
# DETERMINISTIC, not a race. The earlier version raced a background writer and
# could only SKIP when it missed the window — and a mutation re-adding
# `-maxdepth 1` to the fingerprint slipped through exactly that way. `--fingerprint`
# lets the property be asserted directly: a nested write MUST change it.
E9B="$TMP/e9b"; mkbundle "$E9B"; mkdir -p "$E9B/sub"
fp_before=$("$CHECK" --fingerprint "$E9B" 2>/dev/null)
printf -- '---\ntype: Lesson\ntitle: N\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$E9B/sub/nested-new.md"
fp_after=$("$CHECK" --fingerprint "$E9B" 2>/dev/null)
[ -n "$fp_before" ] && ok "E-9b the fingerprint is non-empty" || bad "E-9b fingerprint non-empty" "empty"
[ "$fp_before" != "$fp_after" ] \
  && ok "E-9b a NESTED write changes the fingerprint (subdirectories are covered)" \
  || bad "E-9b nested write changes the fingerprint" "identical — the fingerprint cannot see subdirectories"
# and an untouched bundle must NOT change it, or CONCURRENT would fire constantly
fp_again=$("$CHECK" --fingerprint "$E9B" 2>/dev/null)
[ "$fp_after" = "$fp_again" ] && ok "E-9b an untouched bundle yields a stable fingerprint" \
  || bad "E-9b stable fingerprint on an untouched bundle" "changed with no write — CONCURRENT would false-positive"
# a SYMLINKED concept's target changing must also be visible
printf -- '---\ntype: Lesson\ntitle: S\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' > "$TMP/e9b_target.md"
ln -s "$TMP/e9b_target.md" "$E9B/linked.md"
fp_l1=$("$CHECK" --fingerprint "$E9B" 2>/dev/null)
printf -- '---\ntype: Lesson\ntitle: S\ndescription: D CHANGED AND LONGER\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody body body\n' > "$TMP/e9b_target.md"
fp_l2=$("$CHECK" --fingerprint "$E9B" 2>/dev/null)
[ "$fp_l1" != "$fp_l2" ] \
  && ok "E-9c rewriting a SYMLINKED concept's target changes the fingerprint" \
  || bad "E-9c symlinked target change is visible" "identical — stat without -L reads the link, not the target"

# E-8: unquoted stale_after — PyYAML resolves it to a date object
UNQ="$TMP/unq"; mkbundle "$UNQ"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: 2000-01-01\n---\nbody\n' > "$UNQ/old.md"
expect_match "old.md (stale_after" "E-8 unquoted stale_after still compares" "$CHECK" "$UNQ"

# N-15: a malformed manifest must be COULD NOT RUN, never a silent pass
if command -v okflint >/dev/null 2>&1; then
  BADMAN="$TMP/badman"; mkbundle "$BADMAN"
  printf 'this: [is not\n  valid: yaml\n' > "$BADMAN/okf-base.yaml"
  expect_no_match "L2 profile       PASS" "N-15 malformed manifest is not reported as a pass" "$CHECK" "$BADMAN"
fi

# === E-7 CONCURRENT MODIFICATION ===========================================
section "E-7 CONCURRENT MODIFICATION"
# The live condition, not a hypothetical: 2+ crew sessions write these bundles.
# The layers run in sequence (L1 python, L2 okflint, L3 awk), so a write landing
# between them makes one report from two different bundles. Empirically proven
# 3/3 at 0.16-0.24s on a 40-concept bundle: L1 counted 40 while L3 flagged a
# 41st file. The report said nothing about it.
echo "  -- concurrent modification (E-7) --"

mkbig() { # <dir> <n> — a bundle big enough to have a race window
  local b="$1" n="$2" i
  mkdir -p "$b"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$b/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$b/log.md"
  for i in $(seq 1 "$n"); do
    printf -- '---\ntype: Lesson\ntitle: T%s\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nbody\n' "$i" > "$b/c$i.md"
  done
}

# E-7a: a broken symlink (a file that vanished between listing and read) must
# not crash the run — it is genuinely not a concept.
E7A="$TMP/e7a"; mkbundle "$E7A"; ln -s "$TMP/definitely-gone.md" "$E7A/vanished.md"
expect_exit 0 "E-7a broken symlink does not crash the run" -- "$CHECK" "$E7A"

# E-7b: an unreadable concept must FAIL CLOSED, never be skipped into a pass.
E7B="$TMP/e7b"; mkbundle "$E7B"
printf -- '---\ntype: Lesson\ntitle: L\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nb\n' > "$E7B/locked.md"
chmod 000 "$E7B/locked.md"
expect_exit 1 "E-7b unreadable concept fails CLOSED" -- "$CHECK" "$E7B"
expect_no_match "ALL GATES PASS" "E-7b unreadable concept is never a silent pass" "$CHECK" "$E7B"
chmod 644 "$E7B/locked.md"

# E-7c: a half-written file (mid-write by another agent) must fail closed too.
E7C="$TMP/e7c"; mkbundle "$E7C"
printf -- '---\ntype: Lesson\ntitle: Half\ndescription: D\nstatus: stable\n' > "$E7C/partial.md"
expect_exit 1 "E-7c half-written file fails CLOSED" -- "$CHECK" "$E7C"

# E-7d: THE ONE THAT MATTERS. A bundle that changes DURING the scan must say so.
# Without this, a green verdict computed from two different bundle states is
# indistinguishable from a green verdict on a stable one. DETERMINISTIC now —
# see mk_racing_stat above. This assertion can no longer skip.
E7D="$TMP/e7d"; mkbundle "$E7D"
E7DB="$TMP/e7dbin"; mk_racing_stat "$E7DB"
out=$(PATH="$E7DB:$PATH" "$CHECK" "$E7D" 2>&1)
printf '%s' "$out" | grep -qi 'changed during\|CONCURRENT' \
  && ok "E-7d a bundle changed mid-scan is REPORTED" \
  || bad "E-7d a mid-scan change went unreported" \
         "the two fingerprints differed and the report still claimed a stable verdict"
# the flag that exists to make it blocking must actually block
mk_racing_stat "$E7DB"
PATH="$E7DB:$PATH" "$CHECK" "$E7D" --fail-on-change >/dev/null 2>&1; got=$?
[ "$got" -eq 6 ] \
  && ok "E-7d2 --fail-on-change turns a mid-scan change into exit 6" \
  || bad "E-7d2 --fail-on-change did not block on a real change" "exit $got, expected 6"
# control: a STABLE bundle must NOT trip it, or the two above prove nothing
"$CHECK" "$E7D" --fail-on-change >/dev/null 2>&1; got=$?
[ "$got" -eq 0 ] \
  && ok "E-7d3 a stable bundle is not reported as changed" \
  || bad "E-7d3 a stable bundle was called changed" "exit $got — the shim leaked into the control"


# === DEPENDENCY FAILURE PATHS (spec N-13..N-16) =============================
section "DEPENDENCY FAILURE PATHS (spec N-13..N-16)"
# These are the NEW-MACHINE cases. They matter more than any happy path: a gate
# that cannot run must SAY SO, never exit 0 and look like a pass.
echo "  -- dependency failures --"

# Build a sandbox PATH holding only the named tools, so absence is real rather
# than simulated by a flag the code could special-case.
mksandbox() { # <dir> <tool>...
  local d="$1"; shift; mkdir -p "$d"
  local t p
  for t in "$@"; do p=$(command -v "$t" 2>/dev/null); [ -n "$p" ] && ln -sf "$p" "$d/$t"; done
}
BASETOOLS="bash sh env git find awk sed grep date mktemp head tail cut tr wc xargs sort uniq basename dirname readlink chmod printf ls cat rm mkdir cmp stat"

# N-14: python3 absent entirely -> L1 cannot run at all
SB14="$TMP/sb14"; mksandbox "$SB14" $BASETOOLS
if [ ! -e "$SB14/python3" ]; then
  PATH="$SB14" "$SB14/bash" "$CHECK" --doctor >"$TMP/n14.txt" 2>&1; got=$?
  [ "$got" -eq 2 ] && ok "N-14 python3 missing -> doctor exit 2" \
    || bad "N-14 python3 missing -> doctor exit 2" "got exit $got"
  grep -q "python3 *MISSING" "$TMP/n14.txt" && ok "N-14 doctor names python3 as missing" \
    || bad "N-14 doctor names python3 as missing" "$(head -4 "$TMP/n14.txt" | tr '\n' ' ')"
fi

# N-17: PyYAML is VENDORED, so L1 must run on a machine with no site-packages at
# all. `python3 -S` skips site-packages entirely — the closest thing to a stock
# box this test can reach without one. Reviewer-reported: the "runs on a new
# machine" claim was false while PyYAML was a hard external dependency.
SB17="$TMP/sb17"; mksandbox "$SB17" $BASETOOLS
# `-S` alone was not enough to simulate a stock box: on a machine where yaml
# sits somewhere -S still reaches, this whole block SKIPPED — environment-
# dependent coverage that vanished silently. A blocker module makes it
# deterministic everywhere: a `yaml.py` that raises ImportError, placed on
# PYTHONPATH, shadows the SYSTEM copy. It does not shadow the vendored one,
# because okf-check PREPENDS its vendor directory (G-7) and Python takes the
# first match — so this is precisely a stock box: no system PyYAML, vendored
# copy present. Not a stub of the thing under test; a stub of the machine.
#
# The blocker is APPENDED, never prepended. Prepending put it ahead of the
# vendor directory okf-check had just placed there, blocking the vendored copy
# too and failing all four assertions — a stub of the machine that also broke
# the thing under test.
N17BLOCK="$TMP/n17block"; mkdir -p "$N17BLOCK"
printf 'raise ImportError("simulated stock box: no system PyYAML")\n' > "$N17BLOCK/yaml.py"
cat > "$SB17/python3" <<STUB
#!/bin/sh
PYTHONPATH="\${PYTHONPATH:+\$PYTHONPATH:}$N17BLOCK" exec "$REALPY" -S "\$@"
STUB
chmod +x "$SB17/python3"
if "$SB17/python3" -c 'import yaml' 2>/dev/null; then
  bad "N-17 the stock-box simulation failed — yaml still importable" \
      "the blocker module did not shadow the system copy, so nothing below would be tested"
else
  {
    PATH="$SB17:$PATH" "$SB17/bash" "$CHECK" --doctor >"$TMP/n17.txt" 2>&1; got=$?
    [ "$got" -eq 0 ] && ok "N-17 doctor passes with NO site-packages (vendored pyyaml)" \
      || bad "N-17 doctor passes with no site-packages" "exit $got: $(grep -i pyyaml "$TMP/n17.txt" | head -1)"
    grep -q "pyyaml             vendored" "$TMP/n17.txt" \
      && ok "N-17 doctor reports the VENDORED pyyaml is in use" \
      || bad "N-17 doctor names the vendored pyyaml" "$(grep -i pyyaml "$TMP/n17.txt" | head -1)"
    PATH="$SB17:$PATH" "$SB17/bash" "$CHECK" "$CLEAN" >/dev/null 2>&1; got=$?
    [ "$got" -eq 0 ] && ok "N-17 L1 runs a clean bundle with no site-packages" \
      || bad "N-17 L1 runs with no site-packages" "exit $got"
    PATH="$SB17:$PATH" "$SB17/bash" "$CHECK" "$DIRTY" >/dev/null 2>&1; got=$?
    [ "$got" -eq 1 ] && ok "N-17 L1 still DETECTS a non-conformant bundle with no site-packages" \
      || bad "N-17 L1 detects failures with no site-packages" "exit $got — a vendored dep that cannot fail is worthless"
  }
fi

# N-13: python3 present but pyyaml absent. A stub python3 that fails ONLY on
# `import yaml` isolates the dependency from the interpreter.
SB13="$TMP/sb13"; mksandbox "$SB13" $BASETOOLS
cat > "$SB13/python3" <<STUB
#!/bin/sh
case "\$*" in *"import yaml"*) exit 1 ;; esac
exec "$REALPY" "\$@"
STUB
chmod +x "$SB13/python3"
PATH="$SB13" "$SB13/bash" "$CHECK" --doctor >"$TMP/n13.txt" 2>&1; got=$?
[ "$got" -eq 2 ] && ok "N-13 pyyaml missing -> doctor exit 2" \
  || bad "N-13 pyyaml missing -> doctor exit 2" "got exit $got: $(head -4 "$TMP/n13.txt" | tr '\n' ' ')"
grep -q "pyyaml *MISSING" "$TMP/n13.txt" && ok "N-13 doctor names pyyaml and its install command" \
  || bad "N-13 doctor names pyyaml" "$(head -5 "$TMP/n13.txt" | tr '\n' ' ')"
# and a CHECK must refuse to run rather than report a pass
PATH="$SB13" "$SB13/bash" "$CHECK" "$CLEAN" >"$TMP/n13b.txt" 2>&1; got=$?
[ "$got" -eq 2 ] && ok "N-13 check refuses to run without pyyaml (exit 2)" \
  || bad "N-13 check refuses to run without pyyaml" "got exit $got"
expect_no_match "ALL GATES PASS" "N-13 no false pass when a gate cannot run" \
  env PATH="$SB13" "$SB13/bash" "$CHECK" "$CLEAN"

# N-10: okflint genuinely ABSENT from PATH. The spec marked this ✅ while every
# okflint assertion was wrapped in `if command -v okflint` — so no test ever
# removed it and ran a full check. The claim being made is that L2 SKIPS with an
# install command and NEVER silently passes.
SB10="$TMP/sb10"; mksandbox "$SB10" $BASETOOLS python3
if ! PATH="$SB10" command -v okflint >/dev/null 2>&1; then
  PATH="$SB10" "$SB10/bash" "$CHECK" "$CLEAN" >"$TMP/n10.txt" 2>&1; got=$?
  [ "$got" -eq 0 ] && ok "N-10 a clean bundle still passes with okflint absent" \
    || bad "N-10 clean bundle passes without okflint" "exit $got"
  grep -q "L2 profile       SKIPPED" "$TMP/n10.txt" && ok "N-10 L2 is SKIPPED when okflint is absent" \
    || bad "N-10 L2 SKIPPED when okflint absent" "$(grep 'L2' "$TMP/n10.txt" | head -1)"
  grep -q "uv tool install okflint" "$TMP/n10.txt" && ok "N-10 the skip names the install command" \
    || bad "N-10 skip names the install command" "no install hint"
  grep -q "ALL GATES PASS" "$TMP/n10.txt" && bad "N-10 must not claim ALL GATES PASS with L2 skipped" "it did" \
    || ok "N-10 never claims ALL GATES PASS while L2 is skipped"
else
  skip "N-10 — okflint leaked into the sandbox PATH (a skip, not a pass)"
fi

# P-7: the staleness hook's bundle path must be overridable, or the plugin ships
# one machine's layout. Marked ✅ in the spec with zero test references anywhere.
HOOK="$HERE/lessons-staleness-check.sh"
if [ -f "$HOOK" ]; then
  P7="$TMP/p7bundle"; mkdir -p "$P7"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nb\n' > "$P7/old.md"
  out=$(OKF_BUNDLE_DIR="$P7" bash "$HOOK" 2>&1)
  printf '%s' "$out" | grep -q 'old.md' && ok "P-7 OKF_BUNDLE_DIR redirects the hook to another bundle" \
    || bad "P-7 OKF_BUNDLE_DIR is honoured" "hook did not report old.md: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  out=$(OKF_BUNDLE_DIR="$TMP/does-not-exist" bash "$HOOK" 2>&1); rc=$?
  [ -z "$out" ] && [ "$rc" -eq 0 ] && ok "P-7 a missing OKF_BUNDLE_DIR exits quietly (fail-open by design)" \
    || bad "P-7 missing OKF_BUNDLE_DIR is quiet" "rc=$rc out=$(printf '%s' "$out" | head -1)"
  # LT-02b (.scratch/okf-local-bugs/02): CRLF note is not "missing frontmatter" and is checked.
  P7C="$TMP/p7crlf"; mkdir -p "$P7C"
  printf -- '---\r\ntype: Lesson\r\nstale_after: "2000-01-01"\r\n---\r\nb\r\n' > "$P7C/crlf-expired.md"
  out=$(OKF_BUNDLE_DIR="$P7C" bash "$HOOK" 2>&1)
  printf '%s' "$out" | grep -q 'missing OKF frontmatter' && bad "LT-02b CRLF note is not reported as missing frontmatter" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')" \
    || { printf '%s' "$out" | grep -q 'crlf-expired.md (stale_after' && ok "LT-02b CRLF note is parsed and its expiry reported" \
    || bad "LT-02b CRLF note expiry reported" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"; }
  # LT-03f..i: the hook parses values like okf-check L3 does (one shared lib, l3-lib.sh).
  P7V="$TMP/p7vals"; mkdir -p "$P7V"
  printf -- '---\ntype: Lesson\nstatus: stable  # ok\n---\nb\n' > "$P7V/cmt.md"
  printf -- '---\ntype: Lesson\nstatus: "stable # x"\n---\nb\n' > "$P7V/q.md"
  printf -- '---\ntype: Lesson\nstatus: stable\nstale_after: "2026-9-3"\n---\nb\n' > "$P7V/unpad.md"
  printf -- '---\ntype: Lesson\nstatus: stable\nstale_after: soon\n---\nb\n' > "$P7V/soon.md"
  out=$(OKF_TODAY=2026-10-14 OKF_BUNDLE_DIR="$P7V" bash "$HOOK" 2>&1)
  printf '%s' "$out" | grep -q 'cmt.md (status' && bad "LT-03f hook: trailing comment is not part of status" "$(printf '%s' "$out" | head -6 | tr '\n' ' ')" || ok "LT-03f hook: trailing comment is not part of status"
  printf '%s' "$out" | grep -q 'q.md (status: stable # x)' && ok "LT-03g hook: quoted value keeps its ' #'" || bad "LT-03g hook: quoted value keeps its ' #'" "$(printf '%s' "$out" | head -6 | tr '\n' ' ')"
  printf '%s' "$out" | grep -q 'unpad.md (stale_after 2026-09-03)' && ok "LT-03h hook: non-padded date is normalised and flagged" || bad "LT-03h hook: non-padded date flagged" "$(printf '%s' "$out" | head -6 | tr '\n' ' ')"
  printf '%s' "$out" | grep -q 'soon.md.*not a date' && ok "LT-03i hook: non-date stale_after is reported" || bad "LT-03i hook: non-date stale_after reported" "$(printf '%s' "$out" | head -6 | tr '\n' ' ')"
  # LT-07 (ticket 08): hook via a symlink and under CDPATH.
  P7L="$TMP/p7link"; mkdir -p "$P7L/bin"; ln -s "$HOOK" "$P7L/bin/hook.sh"
  out=$(OKF_BUNDLE_DIR="$P7" bash "$P7L/bin/hook.sh" 2>&1)
  printf '%s' "$out" | grep -q 'old.md' && ok "LT-07a hook run through a symlink still reports expiries" || bad "LT-07a hook via symlink" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  out=$(cd "$HERE/.." && OKF_BUNDLE_DIR="$P7" CDPATH="$PWD" bash scripts/lessons-staleness-check.sh 2>&1)
  printf '%s' "$out" | grep -q 'old.md' && ok "LT-07b hook survives an exported CDPATH" || bad "LT-07b hook under CDPATH" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  # LT-08 (ticket 10): status list matches okf-check (stable|draft|deprecated).
  P7S="$TMP/p7status"; mkdir -p "$P7S"
  printf -- '---\ntype: Lesson\nstatus: draft\n---\nb\n' > "$P7S/d.md"
  printf -- '---\ntype: Lesson\nstatus: deprecated\n---\nb\n' > "$P7S/dep.md"
  printf -- '---\ntype: Lesson\nstatus: weird\n---\nb\n' > "$P7S/w.md"
  out=$(OKF_BUNDLE_DIR="$P7S" bash "$HOOK" 2>&1)
  printf '%s' "$out" | grep -qE '(d|dep)\.md \(status' && bad "LT-08a hook accepts draft and deprecated" "$(printf '%s' "$out" | head -4 | tr '\n' ' ')" || ok "LT-08a hook accepts draft and deprecated"
  printf '%s' "$out" | grep -q 'not marked stable' && bad "LT-08c hook label does not claim 'not marked stable' for a list that allows draft" "label is stale" || ok "LT-08c hook label matches its status list"
  printf '%s' "$out" | grep -q 'w.md (status: weird)' && ok "LT-08b hook still reports an unknown status" || bad "LT-08b hook reports unknown status" "$(printf '%s' "$out" | head -4 | tr '\n' ' ')"
fi

# N-16: okflint installed but at a version the gate was never verified against
if command -v okflint >/dev/null 2>&1; then
  printf 'okf_validate  deadbeef\nokflint       0.0.1-never-tested\n' > "$TMP/fakepins.txt"
  OKF_PINNED_VERSIONS="$TMP/fakepins.txt" "$CHECK" --doctor >"$TMP/n16.txt" 2>&1
  grep -q "VERSION-SKEW" "$TMP/n16.txt" && ok "N-16 version skew is reported" \
    || bad "N-16 version skew is reported" "$(grep okflint "$TMP/n16.txt" | head -2 | tr '\n' ' ')"
  grep -q "selftest" "$TMP/n16.txt" && ok "N-16 skew advises --selftest" \
    || bad "N-16 skew advises --selftest" "no selftest advice in output"
fi

# N-15: a malformed manifest must be COULD NOT RUN + exit 2, never a silent pass
if command -v okflint >/dev/null 2>&1; then
  BAD2="$TMP/badman2"; mkbundle "$BAD2"
  printf 'this: [is not\n  valid: yaml\n' > "$BAD2/okf-base.yaml"
  expect_exit 2 "N-15 malformed manifest exits 2 (cannot run != pass)" -- "$CHECK" "$BAD2"
fi

# === ADVERSARIAL REVIEW FINDINGS (2026-07-31) ===============================
section "ADVERSARIAL REVIEW FINDINGS (2026-07-31)"
# An independent reviewer REFUTED three claims and found two CRITICALs where L2
# fails OPEN. Every case below is its reproduction, turned into a test.
echo "  -- adversarial review findings --"

# Stub okflint on PATH so its exit status and output format can be controlled.
stub_okflint() { # <exit> <stdout>
  mkdir -p "$TMP/stub"
  { printf '#!/bin/sh\n'; printf 'cat <<"EOS"\n%s\nEOS\n' "$2"; printf 'exit %s\n' "$1"; } > "$TMP/stub/okflint"
  chmod +x "$TMP/stub/okflint"
}
with_stub() { PATH="$TMP/stub:$PATH" "$@"; }

SB="$TMP/stubbundle"; mkbundle "$SB"
sed 's/^  name: CHANGE ME/  name: Test/' "$HERE/../config/okf-base.yaml.template" > "$SB/okf-base.yaml"

# R-1 CRITICAL: okflint CRASHES (exit 127 / signal) and L2 reported PASS.
# `ec` was only ever compared against 2, so every other non-zero status — a
# missing binary, a segfault, an internal error — read as a clean run.
# This is lessons/shell-or-swallows-errors.md: one status carrying two meanings.
stub_okflint 127 ""
with_stub "$CHECK" "$SB" >"$TMP/r1.txt" 2>&1; got=$?
grep -q "L2 profile       PASS" "$TMP/r1.txt" \
  && bad "R-1 a crashed okflint is not reported as PASS" "exit 127 produced L2 PASS" \
  || ok "R-1 a crashed okflint is not reported as PASS"
[ "$got" -ne 0 ] && ok "R-1 a crashed okflint does not exit 0" || bad "R-1 crashed okflint non-zero exit" "exit 0"

# R-2 CRITICAL: error detection was `grep -c '❌'`. An okflint whose output format
# differs — exactly the VERSION-SKEW the doctor warns about — reports its errors
# in plain text, and every one of them became invisible. Fails OPEN.
stub_okflint 1 'ERROR F102 bad.md missing required field: stale_after
ERROR F105 bad.md value outside vocabulary'
with_stub "$CHECK" "$SB" >"$TMP/r2.txt" 2>&1; got=$?
grep -q "L2 profile       PASS" "$TMP/r2.txt" \
  && bad "R-2 non-emoji okflint errors are not missed" "L2 said PASS while okflint exited 1 with errors" \
  || ok "R-2 non-emoji okflint errors are detected"
[ "$got" -ne 0 ] && ok "R-2 non-emoji errors produce a non-zero exit" || bad "R-2 non-emoji errors non-zero exit" "exit 0"
rm -rf "$TMP/stub"

# R-3 HIGH: --json emitted INVALID JSON on every non-clean bundle — detail
# printers wrote to stdout bypassing say(). E-4 only ever tested a CLEAN bundle,
# so the suite was green over it. Another fixture-masked assertion.
RJ="$TMP/rj"; mkbundle "$RJ"; printf 'no frontmatter\n' > "$RJ/broken.md"
"$CHECK" "$RJ" --json >"$TMP/r3.txt" 2>/dev/null
python3 -c "import json,sys;json.load(open('$TMP/r3.txt'))" 2>/dev/null \
  && ok "R-3 --json is valid JSON on a FAILING bundle" \
  || bad "R-3 --json is valid JSON on a FAILING bundle" "$(head -2 "$TMP/r3.txt" | tr '\n' ' ')"

RS="$TMP/rs"; mkbundle "$RS"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2000-01-01"\n---\nb\n' > "$RS/old.md"
"$CHECK" "$RS" --json >"$TMP/r3b.txt" 2>/dev/null
python3 -c "import json,sys;json.load(open('$TMP/r3b.txt'))" 2>/dev/null \
  && ok "R-3b --json is valid JSON with a stale advisory" \
  || bad "R-3b --json valid with advisory" "$(head -2 "$TMP/r3b.txt" | tr '\n' ' ')"

# R-4 HIGH: exit codes collided. `worst=max(rc)` meant a real §11 conformance
# failure PLUS an unusable manifest returned 2 — documented as "dependency
# missing" — so CI would retry or install instead of failing the bundle.
RC="$TMP/rc"; mkbundle "$RC"; printf 'no frontmatter\n' > "$RC/broken.md"
printf 'this: [is not\n  valid: yaml\n' > "$RC/okf-base.yaml"
if command -v okflint >/dev/null 2>&1; then
  "$CHECK" "$RC" >/dev/null 2>&1; got=$?
  [ "$got" -eq 1 ] && ok "R-4 a conformance failure is not masked by a dependency code (exit 1)" \
    || bad "R-4 conformance failure not masked" "got exit $got; 2 means 'could not run', hiding the §11 error"
fi

# R-5 HIGH: `--selftest --json` reported a DEAD GATE and exited 5 — the code
# documented as the worst outcome — because JSON=1 suppressed say() and the probe
# saw no output to match. A false alarm on the one signal that must never lie.
"$CHECK" --selftest --json >/dev/null 2>&1; got=$?
[ "$got" -eq 0 ] && ok "R-5 --selftest --json does not falsely report a dead gate" \
  || bad "R-5 --selftest --json false failure" "exit $got (plain --selftest exits 0)"

# R-6 HIGH: an UNREADABLE or wrong directory failed OPEN — "PASS 0 concepts",
# exit 0. A typo'd path read as a clean bill of health. The same fail-closed
# principle E-7b enforces for one unreadable FILE was absent for the DIRECTORY.
RU="$TMP/ru"; mkbundle "$RU"; chmod 000 "$RU"
"$CHECK" "$RU" >/dev/null 2>&1; got=$?
chmod 755 "$RU"
[ "$got" -ne 0 ] && ok "R-6 an unreadable bundle directory fails CLOSED" \
  || bad "R-6 unreadable bundle directory fails CLOSED" "exit 0 — a permission problem read as a pass"

# R-7 MEDIUM: a newline in the bundle path silently disabled L3 (`tr '\n' '\0'`
# split the path). Same class as E-2b, which covered spaces only.
RN="$TMP/nl
x"; mkbundle "$RN"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2000-01-01"\n---\nb\n' > "$RN/old.md"
expect_match "old.md (stale_after" "R-7 a newline in the bundle path does not disable L3" "$CHECK" "$RN"

# R-8 MEDIUM: introduced by MY OWN E-9 fix. Now that the scan is recursive, L3
# reduced FILENAME to a basename, so two distinct expired files rendered as two
# identical unactionable lines.
RB="$TMP/rb"; mkbundle "$RB"; mkdir -p "$RB/decisions" "$RB/specs"
for d in decisions specs; do
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2000-01-01"\n---\nb\n' > "$RB/$d/notes.md"
done
"$CHECK" "$RB" >"$TMP/r8.txt" 2>&1
n=$(grep -cE 'decisions/notes\.md|specs/notes\.md' "$TMP/r8.txt" || true)
[ "${n:-0}" -ge 2 ] && ok "R-8 L3 distinguishes same-named concepts in different directories" \
  || bad "R-8 L3 distinguishes same-named concepts" "reported basenames only — two identical, unactionable lines"

# R-9 MEDIUM: extra positional arguments were silently dropped, so
# `okf-check <FAILING> <CLEAN>` checked only the last and exited 0.
RG1="$TMP/rg1"; mkbundle "$RG1"; printf 'no frontmatter\n' > "$RG1/broken.md"
RG2="$TMP/rg2"; mkbundle "$RG2"
"$CHECK" "$RG1" "$RG2" >/dev/null 2>&1; got=$?
[ "$got" -ne 0 ] && ok "R-9 a second bundle argument is not silently dropped" \
  || bad "R-9 second bundle argument not silently dropped" "exit 0 — the failing bundle was never examined"

# R-10 LOW: exit 6 and --fail-on-change were absent from --help.
"$CHECK" --help 2>&1 | grep -q 'fail-on-change' \
  && ok "R-10 --help documents --fail-on-change" || bad "R-10 --help documents --fail-on-change" "absent"
"$CHECK" --help 2>&1 | grep -qE '^#?\s*6\s' \
  && ok "R-10 --help documents exit code 6" || bad "R-10 --help documents exit 6" "EXIT CODES block stops at 5"

# === ULTRA-REVIEW REGRESSION FINDINGS (2026-07-31) ==========================
section "ULTRA-REVIEW REGRESSION FINDINGS (2026-07-31)"
# Both CRITICALs below are regressions introduced by the commits that FIXED other
# things — the most dangerous kind, because the suite was green when they landed.
echo "  -- ultra-review regression findings --"

# G-1 CRITICAL: --fail-on-change compared RAW exit codes instead of rank(), and
# every layer returns 0..4, so `$worst -lt 6` was ALWAYS true. A mid-scan write
# therefore overwrote a real conformance failure with exit 6. This is R-4 — a
# real verdict masked by an unrelated code — reintroduced by the very commit that
# fixed R-4 for the other three gates.
#
# Deterministic, no race: --fingerprint proves the mechanism, and here we assert
# the PRECEDENCE directly by checking that a conformance failure survives.
G1="$TMP/g1"; mkbundle "$G1"; printf 'no frontmatter\n' > "$G1/broken.md"
"$CHECK" "$G1" --fail-on-change >/dev/null 2>&1; got=$?
[ "$got" -eq 1 ] \
  && ok "G-1 --fail-on-change does not mask a conformance failure on a stable bundle" \
  || bad "G-1 --fail-on-change masks a conformance failure" "exit $got, expected 1"

# and the interaction under a mid-scan change: the CONFORMANCE error must still
# win, because a verdict that was REACHED outranks one that was disturbed.
# Deterministic via the same shim; this no longer skips either.
G1B="$TMP/g1b"; mkbundle "$G1B"; printf 'no frontmatter\n' > "$G1B/broken.md"
G1BB="$TMP/g1bbin"; mk_racing_stat "$G1BB"
out=$(PATH="$G1BB:$PATH" "$CHECK" "$G1B" --fail-on-change 2>&1); rc=$?
if printf '%s' "$out" | grep -qi 'changed during\|CONCURRENT'; then
  [ "$rc" -eq 1 ] \
    && ok "G-1b a conformance error outranks a mid-scan change (exit 1, not 6)" \
    || bad "G-1b conformance outranks mid-scan change" "exit $rc — the §11 error was masked by exit 6"
else
  bad "G-1b the injected mid-scan change was not detected" \
      "the shim did not take effect, so the precedence rule was never exercised"
fi


# G-2 CRITICAL: `export PYTHONPATH` leaked the vendored pure-python PyYAML into
# every CHILD process, including okflint — which has its own newer, compiled copy.
# Verified by the reviewer: okflint standalone had libyaml=True, but as a child of
# okf-check it loaded the vendored libyaml=False copy. The commit message claimed
# "a system PyYAML wins if present"; that was true only for okf-check's OWN import.
if command -v okflint >/dev/null 2>&1; then
  mkdir -p "$TMP/spy"
  # The spy writes to a FILE, not stderr: okf-check captures the child's stderr
  # into its own scratch file, so a stderr probe is invisible to this test.
  cat > "$TMP/spy/okflint" <<STUB
#!/usr/bin/env python3
import sys
try:
    import yaml; loc = yaml.__file__
except Exception as e:
    loc = "<none:%s>" % e
open("$TMP/spy_yaml.txt", "w").write(loc)
print("[]")
STUB
  chmod +x "$TMP/spy/okflint"
  SPYB="$TMP/spyb"; mkbundle "$SPYB"
  sed 's/^  name: CHANGE ME/  name: Test/' "$HERE/../config/okf-base.yaml.template" > "$SPYB/okf-base.yaml"
  rm -f "$TMP/spy_yaml.txt"
  PATH="$TMP/spy:$PATH" "$CHECK" "$SPYB" >/dev/null 2>&1
  spy=$(cat "$TMP/spy_yaml.txt" 2>/dev/null)
  case "$spy" in
    *plugin/vendor/pyyaml*) bad "G-2 the vendored PyYAML must not leak into child processes" "the okflint child loaded $spy" ;;
    "")                     skip "G-2 — the spy never ran (L2 may have been skipped)" ;;
    *)                      ok  "G-2 a child process does not inherit the vendored PyYAML" ;;
  esac
fi

# G-3 HIGH: --fingerprint was added in the same commit as the R-6 fail-closed fix
# but never received it — an unreadable directory read as a silent clean result.
G3="$TMP/g3"; mkbundle "$G3"; chmod 000 "$G3"
"$CHECK" --fingerprint "$G3" >/dev/null 2>&1; got=$?
chmod 755 "$G3"
[ "$got" -ne 0 ] && ok "G-3 --fingerprint fails CLOSED on an unreadable directory" \
  || bad "G-3 --fingerprint fails closed" "exit 0 on a chmod-000 bundle — a silent clean read"

# G-4 HIGH: run_profile trusted the JSON shape. Two ways to reach ALL GATES PASS
# while okflint said otherwise: a non-list body with exit 0, and a finding with no
# `severity` key while exit 1 says findings exist. R-2's failure mode, one layer in.
stub_okflint 0 '{"findings":[]}'
with_stub "$CHECK" "$SB" >"$TMP/g4a.txt" 2>&1; got=$?
grep -q "L2 profile       PASS" "$TMP/g4a.txt" \
  && bad "G-4a a non-list okflint body is not reported as PASS" "unparseable body read as a clean run" \
  || ok "G-4a a non-list okflint body is not reported as PASS"
stub_okflint 1 '[{"code":"F102","file":"bad.md","message":"missing required field"}]'
with_stub "$CHECK" "$SB" >"$TMP/g4b.txt" 2>&1; got=$?
[ "$got" -ne 0 ] \
  && ok "G-4b a finding with no severity key still fails (okflint exit 1 is authoritative)" \
  || bad "G-4b severity-less finding fails" "exit 0 — counted as a warning while okflint reported findings"
rm -rf "$TMP/stub"

# G-5 MEDIUM: the JSON body was located with `raw.find("[")`, which grabs the
# first bracket ANYWHERE — including one inside okflint's pre-JSON banner.
stub_okflint 1 'Warning: unknown okf_version=[0.3]
[{"code":"F105","tier":"profile","severity":"error","file":"bad.md","message":"bad status"}]'
with_stub "$CHECK" "$SB" >"$TMP/g5.txt" 2>&1; got=$?
[ "$got" -eq 3 ] && ok "G-5 a bracket in okflint's banner does not break JSON extraction" \
  || bad "G-5 banner bracket breaks JSON extraction" "exit $got, expected 3 (FAIL 1 house-rule error)"
rm -rf "$TMP/stub"

# G-7: the vendored PyYAML is a PIN, and a pin that ambient environment can
# shadow is not a pin. `py_with_vendor` APPENDED the vendor dir to PYTHONPATH,
# so any pre-existing entry outranked it — Python searches PYTHONPATH left to
# right, and the whole of PYTHONPATH before site-packages. An operator (or a
# stray export in a CI image) with a `yaml` module on PYTHONPATH silently
# replaced the parser the gate's verdict depends on.
# Not shape-checked: the decoy LIES — it reports every file as a valid concept.
# If it is reachable, a bundle whose concept has NO `type` passes L1.
DECOY="$TMP/decoy"; mkdir -p "$DECOY/yaml"
cat > "$DECOY/yaml/__init__.py" <<'PY'
__with_libyaml__ = False
class YAMLError(Exception): pass
def safe_load(s, *a, **k):  # every document looks like a conformant concept
    return {"type": "concept", "id": "decoy", "title": "decoy"}
def safe_load_all(s, *a, **k):
    yield safe_load(s)
PY
NOTYPE="$TMP/notype"; mkdir -p "$NOTYPE"
printf -- '---\nid: x\ntitle: no type key at all\n---\n\nbody\n' > "$NOTYPE/a.md"
printf -- '---\ntype: index\n---\n\n# Index\n' > "$NOTYPE/index.md"
# baseline: with no decoy, the missing `type` IS caught (else the test proves nothing)
"$CHECK" "$NOTYPE" >/dev/null 2>&1; base=$?
[ "$base" -eq 1 ] \
  || bad "G-7 baseline: a concept with no \`type\` must fail L1" "exit $base, expected 1"
PYTHONPATH="$DECOY" "$CHECK" "$NOTYPE" >/dev/null 2>&1; got=$?
[ "$got" -eq 1 ] \
  && ok "G-7 an ambient PYTHONPATH cannot shadow the pinned YAML parser" \
  || bad "G-7 decoy yaml on PYTHONPATH shadowed the pinned parser" \
         "exit $got, expected 1 — a lying parser produced a PASS"

# === sibling defects of the G-* classes (found by sweeping for more) ==========
section "sibling defects of the G-* classes (found by sweeping for more)"
echo "  -- sibling sweep --"

# G-8 CRITICAL: R-6 made the bundle ROOT fail closed, and stopped there. A
# NESTED unreadable directory was still swallowed by `find ... 2>/dev/null`:
# L1 counted the concepts it could see, L3 reported "nothing expired", and the
# run exited 0 — a clean bill of health over a subtree we were never allowed to
# read, hiding a concept expired since 2000.
G8="$TMP/g8"; mkbundle "$G8"; mkdir -p "$G8/sub"
printf -- '---\ntype: Lesson\ntitle: Expired\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2020-01-01"\nstale_after: "2000-01-01"\n---\n\nbody\n' > "$G8/sub/old.md"
"$CHECK" "$G8" >"$TMP/g8ctl.txt" 2>&1
grep -q 'need attention' "$TMP/g8ctl.txt" \
  || bad "G-8 control: the expired concept must be seen while readable" \
         "L3 did not flag it even with the subdir readable — fixture is wrong"
chmod 000 "$G8/sub"
"$CHECK" "$G8" >"$TMP/g8.txt" 2>&1; got=$?
chmod 755 "$G8/sub"
[ "$got" -ne 0 ] \
  && ok "G-8 an unreadable NESTED directory fails CLOSED (exit $got)" \
  || bad "G-8 nested unreadable directory failed OPEN" \
         "exit 0 — reported '$(grep -o "L3 staleness.*" "$TMP/g8.txt" | head -1)' over a subtree it could not read"

# G-9 HIGH: the same trusted-shape defect as G-4, in L1 instead of L2. The
# reader does `d.get("errors",[])`, so a report that is valid JSON but the
# WRONG SHAPE — `{}`, or a validator that changed its schema — reads as zero
# errors and prints PASS. G-4 taught that "parsed" is not "understood".
# Stubbed by COPYING the plugin tree and replacing the vendored validator —
# the same technique the R-1/R-2 tests use for okflint. No environment override
# is added to production just to make this testable.
G9="$TMP/g9"; mkbundle "$G9"
G9P="$TMP/g9plugin"; mkdir -p "$G9P"
cp -R "$HERE/../"* "$G9P/" 2>/dev/null
cat > "$G9P/vendor/okf_validate.py" <<'PY'
import sys
print('{"ok": true}')          # valid JSON, wrong SHAPE: no errors/warnings key
sys.exit(0)
PY
chmod +x "$G9P/scripts/okf-check"
"$G9P/scripts/okf-check" "$G9" >"$TMP/g9.txt" 2>&1; got=$?
[ "$got" -eq 2 ] \
  && ok "G-9 a validator report of the wrong SHAPE is COULD NOT RUN, not PASS (exit 2)" \
  || bad "G-9 wrong-shape L1 report read as a verdict" \
         "exit $got, expected 2; said: $(grep -o 'L1 conformance.*' "$TMP/g9.txt" | head -1)"
# guard: the same stubbed tree with a WELL-shaped report must still reach a verdict,
# or G-9 could pass merely because the copied tree is broken.
cat > "$G9P/vendor/okf_validate.py" <<'PY'
import sys
print('{"errors": [], "warnings": [], "counts": {"concepts": 1}}')
sys.exit(0)
PY
"$G9P/scripts/okf-check" "$G9" >/dev/null 2>&1; got=$?
[ "$got" -eq 0 ] || bad "G-9 guard: a well-shaped report must still PASS in the stubbed tree" \
                        "exit $got — the copy is broken, so the G-9 assertion above proves nothing"

# G-10 HIGH: `--fingerprint --json` printed raw `size mtime path` lines and
# exited 0. Same class as R-3 (--json corrupted by human text), in the mode
# added after R-3 was fixed.
G10="$TMP/g10"; mkbundle "$G10"
"$CHECK" --fingerprint "$G10" --json >"$TMP/g10.txt" 2>&1
"$REALPY" -c "import json,sys;json.load(open('$TMP/g10.txt'))" 2>/dev/null \
  && ok "G-10 --fingerprint --json emits valid JSON" \
  || bad "G-10 --fingerprint --json is not JSON" "first line: $(head -1 "$TMP/g10.txt")"

# G-11 MEDIUM: four detail dumps cut at 10-12 lines with no note of the cut —
# the silent-cap defect already fixed in okf-verify's no_claims list, never
# applied here. A reader sees 12 errors and reasonably concludes there are 12.
G11="$TMP/g11"; mkbundle "$G11"
i=1; while [ "$i" -le 15 ]; do printf 'no frontmatter %s\n' "$i" > "$G11/bad$i.md"; i=$((i+1)); done
"$CHECK" "$G11" >"$TMP/g11.txt" 2>&1
grep -qE 'and [0-9]+ more' "$TMP/g11.txt" \
  && ok "G-11 a truncated L1 error dump states how many it withheld" \
  || bad "G-11 L1 error dump truncates silently" \
         "printed $(grep -c '§11' "$TMP/g11.txt") of 15 errors with no 'and N more'"

# G-12 LOW: `export OKF_L3_ROOT` is the same unscoped-export shape as G-2. No
# consumer reads that name today, so this is structural, not live — but G-2 was
# also "just a PATH tweak" until okflint silently changed parser.
G12="$TMP/g12"; mkbundle "$G12"
cat > "$TMP/g12spy.sh" <<'SH'
#!/bin/bash
printf '%s' "${OKF_L3_ROOT-UNSET}" > "$SPYOUT"
exec /usr/bin/env awk "$@"
SH
chmod +x "$TMP/g12spy.sh"
SPYOUT="$TMP/g12spy.txt" PATH="$TMP:$PATH" "$CHECK" "$G12" >/dev/null 2>&1
if grep -q 'OKF_L3_ROOT="\$bundle/"' "$CHECK" && grep -q '^  export OKF_L3_ROOT' "$CHECK"; then
  bad "G-12 OKF_L3_ROOT is exported into every later child process" \
      "okf-check:$(grep -n '^  export OKF_L3_ROOT' "$CHECK" | cut -d: -f1) — scope it to the awk call, as py_with_vendor does"
else
  ok "G-12 OKF_L3_ROOT is scoped to the command that needs it"
fi

# U-1: the commit that fixed silent caps (G-11) introduced three more of them.
# The unreadable-directory list prints 3 and stops, so a bundle with 5 locked
# directories reports 3 and reads as the complete list — the exact defect G-11
# had just removed, written by the same hand in the same commit.
U1="$TMP/u1"; mkbundle "$U1"
for i in 1 2 3 4 5; do mkdir -p "$U1/d$i"; : > "$U1/d$i/x.md"; chmod 000 "$U1/d$i"; done
"$CHECK" "$U1" >"$TMP/u1.txt" 2>&1
"$CHECK" --fingerprint "$U1" >"$TMP/u1f.txt" 2>&1
for i in 1 2 3 4 5; do chmod 755 "$U1/d$i"; done
grep -qE 'and [0-9]+ more' "$TMP/u1.txt" \
  && ok "U-1 the unreadable-directory list states how many it withheld" \
  || bad "U-1 unreadable-directory list truncates silently" \
         "listed $(grep -c 'unreadable:' "$TMP/u1.txt") of 5 with no 'and N more'"
grep -qE 'and [0-9]+ more' "$TMP/u1f.txt" \
  && ok "U-1b --fingerprint's unreadable list also states how many" \
  || bad "U-1b --fingerprint unreadable list truncates silently" \
         "listed $(grep -c 'unreadable:' "$TMP/u1f.txt") of 5 with no 'and N more'"

# U-2: the L2 "COULD NOT RUN" dump cuts okflint's explanation at 3 lines with no
# marker. Pre-existing, and missed by the G-11 sweep because that sweep grepped
# `head -1[02]` — a pattern that cannot match `head -3`. An instrument that
# could not see the failure it was checking for (probe-instrument-silently-lied).
if command -v okflint >/dev/null 2>&1; then
  U2="$TMP/u2"; mkbundle "$U2"
  printf 'not: [valid\n  yaml: at all\n   deeply: broken\n    more: junk\n     and: more\n' > "$U2/okf-base.yaml"
  "$CHECK" "$U2" >"$TMP/u2.txt" 2>&1; got=$?
  if grep -q 'COULD NOT RUN' "$TMP/u2.txt"; then
    lines=$(grep -cE '^                   ' "$TMP/u2.txt")
    if [ "$lines" -ge 3 ]; then
      grep -qE 'and [0-9]+ more' "$TMP/u2.txt" \
        && ok "U-2 the L2 COULD-NOT-RUN dump states how many lines it withheld" \
        || bad "U-2 L2 COULD-NOT-RUN dump truncates silently" "printed $lines detail lines, no 'and N more'"
    else
      skip "U-2 — okflint's rejection was under 3 lines here (a skip, not a pass)"
    fi
  else
    skip "U-2 — this okflint did not report COULD NOT RUN for the fixture (a skip, not a pass)"
  fi
fi

# U-5: `doc-reuse-guard.sh` ships in the plugin, is wired to PreToolUse[Write],
# and had ZERO test references anywhere. It was live-fired once by hand and the
# commit message says so — but a manual run is not coverage, and this is the
# hook that fires on every Write for the rest of the session.
GUARD="$HERE/doc-reuse-guard.sh"
if [ ! -f "$GUARD" ]; then
  skip "U-5 — doc-reuse-guard.sh absent (a skip, not a pass)"
elif ! command -v jq >/dev/null 2>&1; then
  skip "U-5 — jq absent and the guard exits 0 without it (a skip, not a pass)"
else
  # positive: a NEW .md in a guarded location must produce a reminder
  out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/lessons/u5-brand-new.md","content":"x"}}' "$HOME" | bash "$GUARD" 2>&1)
  printf '%s' "$out" | grep -q 'hookSpecificOutput' \
    && ok "U-5 the guard fires on a new lesson file" \
    || bad "U-5 guard fires on a new lesson" "no hookSpecificOutput: $(printf '%s' "$out" | head -1)"
  # and its stdout must be JSON Claude Code can actually parse
  printf '%s' "$out" | "$REALPY" -c 'import json,sys;d=json.load(sys.stdin);assert d["hookSpecificOutput"]["hookEventName"]=="PreToolUse"' 2>/dev/null \
    && ok "U-5b the guard emits valid PreToolUse hook JSON" \
    || bad "U-5b guard JSON invalid" "stdout is not parseable PreToolUse output: $(printf '%s' "$out" | head -1)"
  # negative legs, runtime-proven rather than asserted in a comment.
  # The fixture must be an existing NON-RESERVED lesson: the first draft used
  # index.md, which the guard skips under the reserved-files rule, so removing
  # the `[ -e "$FP" ]` check entirely still left the test passing. It was
  # measuring the wrong exclusion.
  EXIST=$(ls "$HOME"/.claude/lessons/*.md 2>/dev/null | grep -vE 'index\.md|log\.md|README\.md' | head -1)
  if [ -n "$EXIST" ]; then
    out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$EXIST" | bash "$GUARD" 2>&1)
    [ -z "$out" ] && ok "U-5c the guard is silent for a file that already exists" \
      || bad "U-5c guard should skip existing files" "emitted: $(printf '%s' "$out" | head -1)"
  else
    skip "U-5c — no non-reserved lesson on this machine to use as a fixture (a skip, not a pass)"
  fi
  out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/x.py","content":"x"}}' "$TMP" | bash "$GUARD" 2>&1)
  [ -z "$out" ] && ok "U-5d the guard is silent for a non-.md path" \
    || bad "U-5d guard should skip non-markdown" "emitted: $(printf '%s' "$out" | head -1)"
fi

# U-6: P-7 asserts the staleness hook by grepping for a FILENAME. A hook that
# printed `old.md is stale {not json` would satisfy that grep — and Claude Code
# parses hook stdout as JSON, so a malformed emit is a broken session, not a
# cosmetic issue. Assert the contract, not the substring.
if [ -f "$HOOK" ]; then
  U6="$TMP/u6"; mkdir -p "$U6"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nb\n' > "$U6/old.md"
  out=$(OKF_BUNDLE_DIR="$U6" bash "$HOOK" 2>&1)
  printf '%s' "$out" | "$REALPY" -c 'import json,sys;d=json.load(sys.stdin);assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart";assert "old.md" in d["hookSpecificOutput"]["additionalContext"]' 2>/dev/null \
    && ok "U-6 the staleness hook emits valid SessionStart JSON naming the concept" \
    || bad "U-6 staleness hook output is not valid SessionStart JSON" "$(printf '%s' "$out" | head -1)"
fi

# V-1..V-3: the G-9 shape guard checked that `errors` EXISTS, never that it is a
# LIST. `len()` and `for..in` both work on a string, so a validator emitting
# `{"errors": ""}` produced "PASS 7 concepts, 0 errors" and exit 0 — the precise
# case an earlier commit message claims is now COULD NOT RUN. Present is not the same as
# well-formed, which is the whole lesson of G-4 and G-9, missed a third time.
V1P="$TMP/v1plugin"; mkdir -p "$V1P"; cp -R "$HERE/../"* "$V1P/" 2>/dev/null
chmod +x "$V1P/scripts/okf-check"
V1B="$TMP/v1b"; mkbundle "$V1B"
shape_case() { # <label> <json-for-errors> <expected-exit>
  cat > "$V1P/vendor/okf_validate.py" <<PY
import sys
print('{"errors": $2, "warnings": [], "counts": {"concepts": 7}}')
sys.exit(0)
PY
  "$V1P/scripts/okf-check" "$V1B" >"$TMP/v1.txt" 2>&1; local got=$?
  [ "$got" -eq "$3" ] \
    && ok "$1 (exit $got)" \
    || bad "$1" "exit $got, expected $3; said: $(grep -o 'L1 conformance.*' "$TMP/v1.txt" | head -1)"
}
shape_case 'V-1 an `errors` string must be COULD NOT RUN, never PASS' '""' 2
shape_case 'V-2 a non-empty `errors` string must not become N fabricated errors' '"not-a-list"' 2
shape_case 'V-3 an `errors` object must not be read as a list of errors' '{"count":5}' 2
# guard: a well-shaped report in the same stubbed tree must still reach a verdict
cat > "$V1P/vendor/okf_validate.py" <<'PY'
import sys
print('{"errors": [], "warnings": [], "counts": {"concepts": 1}}')
sys.exit(0)
PY
"$V1P/scripts/okf-check" "$V1B" >/dev/null 2>&1
[ $? -eq 0 ] || bad "V-guard: a well-shaped report must still PASS in the stubbed tree" \
                    "the copy is broken, so V-1..V-3 prove nothing"

# V-4: `bundle_fingerprint` captures find's output into a shell variable
# newline-delimited. A `.md` filename containing a literal newline is split into
# two nonexistent fragments and SILENTLY DROPPED — no warning, exit 0. That file
# then has no change-detection coverage either, since this function backs the
# E-7 mid-scan comparison. Pre-existing; the same bug class G-8 fixed next door.
V4="$TMP/v4"; mkbundle "$V4"
printf 'x\n' > "$V4/$(printf 'has\nnewline').md"
real=$(find -L "$V4" -name '*.md' -type f -print0 | tr '\0' '\n' | grep -c . )
fp=$("$CHECK" --fingerprint "$V4" 2>/dev/null | grep -c .)
[ "$fp" -eq "$real" ] \
  && ok "V-4 a newline in a filename does not silently drop it from the fingerprint" \
  || bad "V-4 fingerprint silently drops a newline-named file" \
         "$fp fingerprint lines for $real real .md files"

# V-5: say_capped/err_capped on EMPTY stdin. `grep -c .` prints 0 AND exits 1,
# so `|| echo 0` fires too and total becomes "0\n0", which `[ -gt ]` rejects with
# "integer expression expected" on stderr. No call site can feed it empty today —
# forward-flagged rather than left to be discovered by the change that can.
out=$(printf '' | bash -c 'TMP=$(mktemp -d); JSON=0
say() { [ "$JSON" -eq 1 ] || printf "%s\n" "$*"; }
'"$(sed -n '/^say_capped() {/,/^}/p' "$CHECK")"'
say_capped 12 "  "; rm -rf "$TMP"' 2>&1)
[ -z "$out" ] \
  && ok "V-5 say_capped on empty input is silent, not an integer-expression error" \
  || bad "V-5 say_capped errors on empty input" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 90)"

# T-1: the readability guard is check-then-act. A directory locked AFTER the
# guard passes but BEFORE the layers read it is invisible to both — reproduced
# once with the window widened, where the concept vanished and the run printed
# "PASS 0 concepts", exit 0.
#
# This USED TO RACE a background chmod and skip when it missed, and its mutation
# never fired: the racer reliably landed after the layers, where the post-scan
# re-check catches it and the unfixed code shows no symptom. So it proved the
# re-check existed without reproducing the fail-open — teeth I could not claim.
#
# Injected instead, with a `find` shim: the SECOND `-type d` walk (the post-scan
# re-check) also emits a path that does not resolve, so `[ -r ]` fails and the
# directory reads as unreadable — exactly the state a mid-scan chmod produces.
# The first walk (the up-front guard) is left clean, so the guard passes and the
# re-check is genuinely the thing under test.
T1="$TMP/t1"; mkbundle "$T1"
T1B="$TMP/t1bin"; mkdir -p "$T1B"
REALFIND=$(command -v find)
cat > "$T1B/find" <<SHIM
#!/bin/sh
case "\$*" in
  *"-type d"*)
    n=\$(cat "$T1B/.calls" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$T1B/.calls"
    "$REALFIND" "\$@"
    # second walk = a directory that became unreachable during the scan
    [ "\$n" -ge 2 ] && printf '%s\0' "$T1/vanished-mid-scan"
    ;;
  *) exec "$REALFIND" "\$@" ;;
esac
SHIM
chmod +x "$T1B/find"; rm -f "$T1B/.calls"
PATH="$T1B:$PATH" "$CHECK" "$T1" >"$TMP/t1.txt" 2>&1; got=$?
if grep -q 'no verdict is possible' "$TMP/t1.txt"; then
  bad "T-1 the up-front guard fired, so the POST-scan re-check was never exercised" \
      "the shim leaked into the first walk"
elif grep -q 'became unreadable DURING this scan' "$TMP/t1.txt" && [ "$got" -ne 0 ]; then
  ok "T-1 a directory that becomes unreadable mid-scan is detected, not silently passed"
else
  bad "T-1 a directory locked mid-scan was not reported" \
      "exit $got — the re-check missed it and the run looked clean"
fi
# control: without the shim the same bundle must pass, or T-1 proves nothing
"$CHECK" "$T1" >/dev/null 2>&1; got=$?
[ "$got" -eq 0 ] \
  && ok "T-1b the same bundle is clean when nothing changes mid-scan" \
  || bad "T-1b the control bundle did not pass" "exit $got"


# Z-1s: the GNU BRANCH of bundle_fingerprint, exercised on EVERY machine.
#
# Z-1 below runs the real GNU binary and skips where none exists, which left the
# branch every Linux box uses untested on a bare mac. Two different claims were
# tangled together:
#   (a) does OUR code handle GNU-format stat output correctly?   — our code
#   (b) does real GNU stat actually emit that format?            — GNU's code
# (a) needs no GNU installed. The flavour probe picks GNU when `stat -f` FAILS,
# so a shim that fails for -f and answers -c with genuine GNU-shaped output
# selects the GNU branch deterministically anywhere. (b) stays with Z-1, where
# it belongs, because only the real binary can answer it.
Z1S="$TMP/z1s"; mkbundle "$Z1S"
Z1SB="$TMP/z1sbin"; mkdir -p "$Z1SB"
cat > "$Z1SB/stat" <<'SHIM'
#!/bin/sh
# BSD probe must fail so okf-check selects the GNU branch
case "$1" in -f) exit 1 ;; esac
# GNU form: stat -L -c '%s %y %n' FILE...   -> "size mtime name"
fmt=""; files=""
while [ $# -gt 0 ]; do
  case "$1" in
    -L) ;;
    -c) fmt="$2"; shift ;;
    *)  files="$files $1" ;;
  esac
  shift
done
# HONOUR the format string. The first version accepted any -c and emitted
# "size mtime name" regardless, so corrupting okf-check's GNU format was
# invisible and the mutation did not fail — a shim that proved only that the
# branch was reached. Real GNU stat errors on an unknown directive; so does this.
case "$fmt" in
  '%s %y %n') ;;
  *) echo "stat: invalid directive: $fmt" >&2; exit 1 ;;
esac
for f in $files; do
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  mt=$(/usr/bin/stat -f '%Fm' "$f" 2>/dev/null || echo 0)
  printf '%s %s %s\n' "${sz:-0}" "$mt" "$f"
done
SHIM
chmod +x "$Z1SB/stat"
z1s_a=$(PATH="$Z1SB:$PATH" "$CHECK" --fingerprint "$Z1S" 2>/dev/null)
[ -n "$z1s_a" ] \
  && ok "Z-1s the GNU branch produces a fingerprint (no GNU install needed)" \
  || bad "Z-1s the GNU branch produced nothing" "the branch every Linux box runs is empty"
printf 'appended\n' >> "$Z1S/c.md"
z1s_b=$(PATH="$Z1SB:$PATH" "$CHECK" --fingerprint "$Z1S" 2>/dev/null)
[ "$z1s_a" != "$z1s_b" ] \
  && ok "Z-1s2 the GNU branch detects a modified concept" \
  || bad "Z-1s2 GNU fingerprint is blind to a change" "byte-identical after a write"
PATH="$Z1SB:$PATH" "$CHECK" "$Z1S" >"$TMP/z1s.txt" 2>&1; got=$?
{ [ "$got" -eq 0 ] && ! grep -q 'DEGRADED' "$TMP/z1s.txt"; } \
  && ok "Z-1s3 a clean bundle passes on the GNU branch with change detection live" \
  || bad "Z-1s3 the GNU branch degrades a clean run" "exit $got$(grep -q DEGRADED "$TMP/z1s.txt" && echo ' with DEGRADED')"

# Z-1: bundle_fingerprint has a BSD branch and a GNU branch, and until now only
# the BSD one had ever executed. The GNU branch is what runs on every Linux
# machine, so a defect there was invisible on the machine that wrote it — the
# spec carried this as an open item from the beginning.
#
# GNU `stat` is located by SEARCH, never by an absolute Homebrew path: the point
# is portability, and hardcoding one distribution's layout would be the same
# mistake in miniature.
gnu_stat_bin=""
if command -v gstat >/dev/null 2>&1 && gstat --version 2>/dev/null | head -1 | grep -q 'GNU coreutils'; then
  gnu_stat_bin=$(command -v gstat)
elif command -v stat >/dev/null 2>&1 && stat --version 2>/dev/null | head -1 | grep -q 'GNU coreutils'; then
  gnu_stat_bin=$(command -v stat)
fi
if [ -z "$gnu_stat_bin" ]; then
  skip "Z-1 — no GNU coreutils stat here; the branch every Linux box runs is unproven" \
       "brew install coreutils       # unlocks Z-1: the GNU stat fingerprint branch"
else
  ZD="$TMP/zgnu"; mkdir -p "$ZD"
  ln -sf "$gnu_stat_bin" "$ZD/stat"          # `stat` IS GNU for this invocation only
  ZB="$TMP/zb"; mkbundle "$ZB"
  z1=$(PATH="$ZD:$PATH" "$CHECK" --fingerprint "$ZB" 2>/dev/null)
  [ -n "$z1" ] \
    && ok "Z-1 the GNU stat branch produces a fingerprint" \
    || bad "Z-1 GNU stat branch produced nothing" "the branch every Linux box runs is empty"
  # and it must actually DETECT a change, not merely emit text
  printf 'appended\n' >> "$ZB/c.md"
  z2=$(PATH="$ZD:$PATH" "$CHECK" --fingerprint "$ZB" 2>/dev/null)
  [ "$z1" != "$z2" ] \
    && ok "Z-1b the GNU branch detects a modified concept" \
    || bad "Z-1b GNU fingerprint is blind to a change" "byte-identical after a write — change detection is dead under GNU"
  # Z-1c asserted only "exit 0", which it CANNOT fail: fingerprint problems are
  # advisory by design (that is the Z-3 fix), so a `stat` that always errors
  # still exits 0 with a DEGRADED line. The assertion was decorative. It now
  # checks the thing that can actually break — that the GNU branch produced a
  # usable fingerprint, i.e. change detection is live rather than DEGRADED.
  PATH="$ZD:$PATH" "$CHECK" "$CLEAN" >"$TMP/z1c.txt" 2>&1; got=$?
  if [ "$got" -ne 0 ]; then
    bad "Z-1c GNU stat breaks the normal path" "exit $got on a bundle that passes under BSD"
  elif grep -q 'DEGRADED' "$TMP/z1c.txt"; then
    bad "Z-1c GNU stat leaves change detection DEGRADED" \
        "exit 0, but the fingerprint was empty — the concurrency lane is off under GNU"
  else
    ok "Z-1c under GNU stat the run passes AND change detection stays live"
  fi
fi

# Z-7: `find -print -quit` guards the Z-3 DEGRADED check, and `-quit` is a GNU
# extension that BSD also implements — two different implementations of a flag
# this gate depends on. Only BSD had run it. Measured on GNU findutils 4.11.0
# it behaves identically, and this keeps that true. Located by search, like
# Z-1, so no Homebrew path is baked in.
gnu_find_bin=""
if command -v gfind >/dev/null 2>&1 && gfind --version 2>/dev/null | head -1 | grep -q 'GNU findutils'; then
  gnu_find_bin=$(command -v gfind)
elif command -v find >/dev/null 2>&1 && find --version 2>/dev/null | head -1 | grep -q 'GNU findutils'; then
  gnu_find_bin=$(command -v find)
fi
if [ -z "$gnu_find_bin" ]; then
  skip "Z-7 — no GNU findutils here; the -quit guard is BSD-proven only" \
       "brew install findutils       # unlocks Z-7: -print -quit under GNU find"
else
  Z7D="$TMP/z7bin"; mkdir -p "$Z7D"; ln -sf "$gnu_find_bin" "$Z7D/find"
  Z7="$TMP/z7"; mkbundle "$Z7"
  PATH="$Z7D:$PATH" "$CHECK" "$Z7" >"$TMP/z7.txt" 2>&1; got=$?
  if [ "$got" -ne 0 ]; then
    bad "Z-7 GNU find breaks the run" "exit $got on a bundle that passes under BSD find"
  elif grep -q 'DEGRADED' "$TMP/z7.txt"; then
    bad "Z-7 GNU find leaves change detection DEGRADED" "the -print -quit guard misfired under GNU"
  else
    ok "Z-7 the run is clean under GNU find, and -print -quit behaves the same"
  fi
fi

# Z-8: `--fail-on-change` is a CI flag — the caller is saying "a mid-scan write
# must fail this run". When the fingerprint is DEGRADED that detection is OFF,
# and the run still exited 0: the safety net silently absent while the flag that
# requests it is set. Exit 6 is not merely unlikely there, it is UNREACHABLE.
# Asking for a guarantee the tool cannot provide must be COULD NOT RUN, not
# success — the same rule every other layer here follows.
Z8="$TMP/z8"; mkbundle "$Z8"
Z8D="$TMP/z8bin"; mkdir -p "$Z8D"
printf '#!/bin/sh\nexit 0\n' > "$Z8D/stat"; chmod +x "$Z8D/stat"
PATH="$Z8D:$PATH" "$CHECK" "$Z8" --fail-on-change >/dev/null 2>&1; got=$?
[ "$got" -eq 2 ] \
  && ok "Z-8 --fail-on-change fails CLOSED when change detection is DEGRADED (exit 2)" \
  || bad "Z-8 --fail-on-change silently succeeds with detection off" \
         "exit $got — the caller asked for change detection and got a pass without it"
# ...and without the flag it stays advisory, or every degraded run becomes a failure
PATH="$Z8D:$PATH" "$CHECK" "$Z8" >/dev/null 2>&1; got=$?
[ "$got" -eq 0 ] \
  && ok "Z-8b without --fail-on-change a DEGRADED fingerprint stays advisory" \
  || bad "Z-8b DEGRADED became blocking without being asked" "exit $got"

# Z-9: `--json` is what CI reads, and DEGRADED had no field in it at all. The
# text warning goes through say(), which --json suppresses by design (R-3), so
# a machine consumer saw {"exit":0,...} with no indication that change detection
# was off. Not corruption — a silent capability gap, which is worse for the
# reader who cannot see the human output.
PATH="$Z8D:$PATH" "$CHECK" "$Z8" --json >"$TMP/z9.txt" 2>/dev/null
"$REALPY" -c "import json;d=json.load(open('$TMP/z9.txt'));raise SystemExit(0 if d.get('change_detection')=='degraded' else 1)" 2>/dev/null \
  && ok "Z-9 --json carries a change_detection field when the fingerprint is DEGRADED" \
  || bad "Z-9 --json hides DEGRADED from automation" "$(cat "$TMP/z9.txt")"
# and a healthy run must say so too, or the field is unreadable without a baseline
"$CHECK" "$Z8" --json >"$TMP/z9b.txt" 2>/dev/null
"$REALPY" -c "import json;d=json.load(open('$TMP/z9b.txt'));raise SystemExit(0 if d.get('change_detection')=='ok' else 1)" 2>/dev/null \
  && ok "Z-9b a healthy run reports change_detection ok" \
  || bad "Z-9b the field is absent on a healthy run" "$(cat "$TMP/z9b.txt")"

# Z-3: found by mutating the GNU branch to emit nothing — the gate still printed
# ALL GATES PASS and exit 0. An empty fingerprint makes FP_BEFORE and FP_AFTER
# compare equal, so E-7 change detection is silently OFF: every mid-scan write
# now reads as "unchanged". A broken `stat`, an unsupported format string, or a
# platform whose branch nobody ran turns the whole concurrency lane into a
# no-op that reports success. Same fail-open family as G-8 and G-13.
Z3="$TMP/z3"; mkbundle "$Z3"
Z3D="$TMP/z3bin"; mkdir -p "$Z3D"
printf '#!/bin/sh\nexit 0\n' > "$Z3D/stat"; chmod +x "$Z3D/stat"   # emits nothing, exits clean
PATH="$Z3D:$PATH" "$CHECK" "$Z3" >"$TMP/z3.txt" 2>&1; got=$?
grep -qE 'change detection|fingerprint' "$TMP/z3.txt" \
  && ok "Z-3 an empty fingerprint on a non-empty bundle is REPORTED, not silent" \
  || bad "Z-3 empty fingerprint silently disables change detection" \
         "exit $got with no mention of it; E-7 coverage is off and the run looks clean"

# --- I: index.md count claims are checked against the files on disk ---------
section "I: index.md count claims are checked against the files on disk"
# index.md is the one file in a bundle that ASSERTS a fact about the bundle, and
# it was the one file nothing verified. Measured on ~/.claude/lessons in this
# session: it claimed 43 lessons, then claimed 0 lessons in all three families,
# and okf-check exited 0 for both. At the time of writing this test it claims
# "48 lessons · 3 family parents · 51 concepts" and the disk holds 47 + 3 = 50 —
# an index that has been wrong, in one direction or another, every time it was
# counted by hand.
#
# SCOPE, deliberately narrow. Only an explicit BOLD summary line is parsed. A
# first attempt matched any "<n> <word>s" in prose and immediately mis-fired on
# "Three families cover 37 of the 48 lessons", which is a true sentence about a
# subset. Counting sentences is not the job; verifying a declared total is.
mkcounted() { # <dir> <summary-line> <n-concepts>
  mkdir -p "$1"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n\n%s\n' "$2" > "$1/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$1/log.md"
  local i=0
  while [ "$i" -lt "$3" ]; do
    printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$1/c$i.md"
    i=$((i+1))
  done
}

# I-1 (HAPPY): an index that claims nothing is not second-guessed.
IQ="$TMP/idx-noclaim"; mkbundle "$IQ"
expect_exit 0 "I-1 an index that states no counts is left alone" -- "$CHECK" "$IQ"

# I-2 (HAPPY): a correct claim passes.
IG="$TMP/idx-right"; mkcounted "$IG" '**3 concepts.**' 3
expect_exit 0 "I-2 a correct count claim passes" -- "$CHECK" "$IG"

# I-3 (NEGATIVE): a wrong claim is a house-profile failure, exit 3.
IB="$TMP/idx-wrong"; mkcounted "$IB" '**4 concepts.**' 3
expect_exit 3 "I-3 an index that overstates its own bundle fails" -- "$CHECK" "$IB"
expect_match 'claims 4' "I-3b the failure names the claimed number" "$CHECK" "$IB"
# Matches the number IN CONTEXT. A bare '3' would have matched almost any line
# of okf-check's output and passed regardless of what the rule reported.
expect_match '3 on disk' "I-3c the failure names the number actually on disk" "$CHECK" "$IB"
# The count can be 1, and the message must not read "1 are on disk".
IS1="$TMP/idx-singular"; mkcounted "$IS1" '**5 concepts.**' 1
expect_match '1 on disk' "I-3d the message is grammatical when exactly one concept exists" "$CHECK" "$IS1"
expect_no_match '1 are on disk' "I-3e no 'N are' construction for a single concept" "$CHECK" "$IS1"

# I-4 (EDGE): reserved files are not concepts. index.md, log.md and README.md
# are structural, and counting them would make every correct index look wrong by
# two or three — the rule would then be trained away as noise.
FM='---\ntype: %s\ntitle: R\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n'
IR="$TMP/idx-readme"; mkcounted "$IR" '**3 concepts.**' 2
printf -- "$FM" Lesson > "$IR/README.md"
expect_exit 0 "I-4 README.md counts as a concept, exactly as L1 counts it" -- "$CHECK" "$IR"
IR2="$TMP/idx-readme-off"; mkcounted "$IR2" '**2 concepts.**' 2
printf -- "$FM" Lesson > "$IR2/README.md"
expect_exit 3 "I-4b an index that forgets README.md is off by one and says so" -- "$CHECK" "$IR2"

# I-7 (EDGE): prose ABOUT a subset is not a declaration.
# The live index contains "Three families cover 37 of the 48 lessons" — two
# numbers, both true, neither a total. Matching counts anywhere in the file
# turned that sentence into two competing claims and failed the bundle. Only a
# whole bold line is a declaration. Without this case the restriction is a
# comment, not a behaviour.
IP="$TMP/idx-prose"; mkcounted "$IP" '**2 lessons.**' 2
printf -- '\nThree families cover 1 of the 2 lessons, and 9 other things exist.\n' >> "$IP/index.md"
expect_exit 0 "I-7 a sentence about a subset is not read as a total" -- "$CHECK" "$IP"

# I-7b: the same restriction, proved from the other side.
# I-7 alone has no teeth. Relaxing the rule to "any line with a digit" makes it
# latch onto `okf_version: "0.2"` in the frontmatter, find no parseable claim,
# and SKIP — so I-7 still passes, because a rule that checks NOTHING passes every
# test that expects a pass. This bundle puts digit-bearing prose ABOVE a bold
# declaration that is WRONG: only a reader that ignores the prose reaches the
# declaration and fails. A silent skip is visible here and nowhere else.
IP2="$TMP/idx-prose-first"; mkcounted "$IP2" 'ignored placeholder' 2
{ printf -- '---\nokf_version: "0.2"\n---\n# B\n\n'
  printf -- 'Roughly 9 lessons are planned for later.\n\n'
  printf -- '**5 lessons.**\n'; } > "$IP2/index.md"
expect_exit 3 "I-7b prose above a wrong declaration does not hide it" -- "$CHECK" "$IP2"

# I-6 (EDGE): a type label must match EXACTLY. The family parents in the live
# bundle declare `type: Lesson Family`, and a prefix match counted all three as
# Lessons — turning 47 real lessons into 50 and making a wrong index look right.
IT="$TMP/idx-types"; mkcounted "$IT" '**2 lessons.**' 2
printf -- "$FM" 'Lesson Family' > "$IT/fam.md"
expect_exit 0 "I-6 'Lesson Family' is not counted as a 'Lesson'" -- "$CHECK" "$IT"

# I-5 (EDGE): a concept listed TWICE is one concept. In the real bundle
# background-agent-silent-finish.md is cross-listed under two families on
# purpose, and counting row LINES rather than unique files is precisely how the
# live index came to claim one lesson more than exists.
ID="$TMP/idx-dup"; mkcounted "$ID" '**2 concepts.**' 2
printf -- '\n| [`c0.md`](c0.md) | x |\n| [`c1.md`](c1.md) | y |\n| [`c0.md`](c0.md) | cross-listed |\n' >> "$ID/index.md"
expect_exit 0 "I-5 a cross-listed concept is counted once, not twice" -- "$CHECK" "$ID"

# --- D: DERIVED staleness — the source moved, whatever stale_after promised ---
section "D: DERIVED staleness"
# `stale_after` is a date somebody typed. A lesson stamped 2027-08-02 reads as
# fresh for a year even if the thing it describes changed yesterday, so L3 has
# been checking a PROMISE, not a measurement. OKF v0.2 already models the
# measurement: §5.1 `sources[]` carries a required `resource` and an optional
# ISO `last_modified`, so a concept can state which artefact it was written
# against and when. Nothing in either bundle uses it yet — the mechanism existed
# and was unused, which is why this is opt-in and silent for concepts without it.
mksourced() { # <dir> <resource> <last_modified>
  mkdir -p "$1"
  printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$1/index.md"
  printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$1/log.md"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\nsources:\n  - id: s1\n    resource: "%s"\n    last_modified: "%s"\n---\n\nbody\n' "$2" "$3" > "$1/c.md"
}

# D-1 (HAPPY): the source has not moved since the concept was written.
DS1="$TMP/derived-fresh"; mksourced "$DS1" "src.txt" "2099-01-01"
printf 'source\n' > "$DS1/src.txt"; touch -t 202601010000 "$DS1/src.txt"
expect_exit 0 "D-1 a source older than its concept is not stale" -- "$CHECK" "$DS1" --fail-stale

# D-1b: the BOUNDARY. Same day is not "changed since". D-1's dates were decades
# apart, so `>` and `>=` behaved identically and swapping them changed nothing
# any test could see — an off-by-one that would call every freshly recorded
# source stale on the day it was recorded.
DS1B="$TMP/derived-sameday"; mksourced "$DS1B" "src.txt" "2026-03-04"
printf 'source\n' > "$DS1B/src.txt"; touch -t 202603041200 "$DS1B/src.txt"
expect_exit 0 "D-1b a source modified on the recorded date is not stale" -- "$CHECK" "$DS1B" --fail-stale

# D-2 (NEGATIVE): the source moved AFTER the concept recorded it. stale_after
# still says 2099, so only the derived check can see this.
DS2="$TMP/derived-stale"; mksourced "$DS2" "src.txt" "2026-01-01"
printf 'changed\n' > "$DS2/src.txt"    # written now, long after 2026-01-01
expect_exit 4 "D-2 a source modified after the concept is stale despite stale_after 2099" -- "$CHECK" "$DS2" --fail-stale
expect_match 'src.txt' "D-2b the report names the source that moved" "$CHECK" "$DS2"
expect_exit 0 "D-2c derived staleness stays advisory without --fail-stale" -- "$CHECK" "$DS2"

# D-3 (EDGE): a resource that is not a local file cannot be measured. Saying so
# is the honest outcome; treating it as verified would be the silent pass this
# whole layer exists to remove.
DS3="$TMP/derived-url"; mksourced "$DS3" "https://example.com/spec" "2026-01-01"
expect_exit 0 "D-3 a non-file resource is not judged stale" -- "$CHECK" "$DS3" --fail-stale
expect_match 'not a local file\|could not be measured\|unmeasurable' \
  "D-3b an unmeasurable source is reported, not silently passed" "$CHECK" "$DS3"

# D-4 (EDGE): no last_modified means there is nothing to compare against.
DS4="$TMP/derived-nodate"; mkdir -p "$DS4"
printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$DS4/index.md"
printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$DS4/log.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\nsources:\n  - id: s1\n    resource: "src.txt"\n---\n\nbody\n' > "$DS4/c.md"
printf 'x\n' > "$DS4/src.txt"
expect_exit 0 "D-4 a source with no last_modified is not guessed at" -- "$CHECK" "$DS4" --fail-stale
# The exit code alone cannot see this. Dropping the `recorded is None` guard
# still exits 0 — the date parse fails and the source lands in UNMEASURABLE —
# but "no date was recorded" and "the date could not be read" are different
# facts, and reporting the first as the second is noise in a report whose whole
# value is that its lines mean something.
expect_no_match 'src.txt' "D-4b an undated source produces no finding at all" "$CHECK" "$DS4"

# D-5 (EDGE): a bundle with no sources at all is completely unaffected.
DS5="$TMP/derived-none"; mkbundle "$DS5"
expect_exit 0 "D-5 concepts without sources are untouched" -- "$CHECK" "$DS5" --fail-stale

# LT-20 per-layer (review round 1): each layer must skip ignored notes, and the derived layer must
# still resolve sources against the REAL bundle (a copy in TMP cannot see ../ or non-md files).
PL="$TMP/pl-index"; mkcounted "$PL" '**3 concepts.**' 3
mkdir -p "$PL/archive"; cp "$PL"/*.md "$PL/archive/" 2>/dev/null; rm -f "$PL/archive/index.md" "$PL/archive/log.md"
"$CHECK" "$PL" >"$TMP/pl1.txt" 2>&1; rc0=$?
printf 'archive/\n' > "$PL/.okfignore"
"$CHECK" "$PL" >"$TMP/pl2.txt" 2>&1; rc1=$?
{ [ "$rc0" -ne 0 ] && [ "$rc1" -eq 0 ]; } && ok "LT-20l L2 index counts skip ignored notes (exit $rc0 -> $rc1)" \
  || bad "LT-20l L2 index" "without=$rc0 with=$rc1 $(grep -i 'index' "$TMP/pl2.txt" | head -2 | tr '\n' ' ')"
PD="$TMP/pl-derived"; mksourced "$PD" "src.txt" "2000-01-01"
printf 'source\n' > "$PD/src.txt"; touch -t 202601010000 "$PD/src.txt"
"$CHECK" "$PD" --fail-stale >/dev/null 2>&1; rc0=$?
mkdir -p "$PD/archive"; printf 'archive/\n' > "$PD/.okfignore"
"$CHECK" "$PD" --fail-stale >/dev/null 2>&1; rc1=$?
{ [ "$rc0" -eq 4 ] && [ "$rc1" -eq 4 ]; } && ok "LT-20m L3 derived still resolves sources with a .okfignore present (exit $rc0 -> $rc1)" \
  || bad "LT-20m derived sources" "without=$rc0 with=$rc1 (want 4 and 4)"
mv "$PD"/*.md "$PD/archive/" 2>/dev/null; cp "$PD/archive/index.md" "$PD/archive/log.md" "$PD/" 2>/dev/null
cat "$PD/.okfignore" >/dev/null
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$PD/live.md"
"$CHECK" "$PD" --fail-stale >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "LT-20n L3 derived skips an ignored note whose source moved" || bad "LT-20n derived skips ignored" "exit $rc"

PX="$TMP/pl-dangling"; mkbundle "$PX"; ln -s "$PX/nowhere.md" "$PX/d.md"
"$CHECK" "$PX" >/dev/null 2>&1; rc0=$?
printf '# c\n' > "$PX/.okfignore"
"$CHECK" "$PX" >/dev/null 2>&1; rc1=$?
[ "$rc0" = "$rc1" ] && ok "LT-20o a dangling symlink gives the same verdict with a no-op .okfignore (exit $rc1)" || bad "LT-20o dangling symlink" "without=$rc0 with=$rc1"

# LT-21: a hung okflint is cut off and named; it never stalls the run.
H21="$TMP/h21"; mkbundle "$H21/b"; mkdir -p "$H21/bin"
cp "$HERE/../config/okf-base.yaml.template" "$H21/b/okf-base.yaml" 2>/dev/null
cat > "$H21/bin/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
sleep 40
STUB
chmod +x "$H21/bin/okflint"
t0=$(date +%s); env PATH="$H21/bin:$PATH" OKF_L2_TIMEOUT=3 "$CHECK" "$H21/b" >"$TMP/h21.txt" 2>&1; rc=$?; t1=$(date +%s)
{ [ "$rc" -eq 2 ] && [ $((t1-t0)) -lt 15 ] && grep -q "timed out after 3 s" "$TMP/h21.txt"; } \
  && ok "LT-21 a hung okflint is cut off after OKF_L2_TIMEOUT and named (exit 2 in $((t1-t0))s)" \
  || bad "LT-21 hung okflint" "rc=$rc ${t1}-${t0} $(grep -n L2 "$TMP/h21.txt" | head -2 | tr '\n' ' ')"
pkill -f 'sleep 40' 2>/dev/null
# F1: 0 is not "kill at once"
cat > "$H21/bin/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
echo '{"errors":[],"warnings":[],"summary":{"errors":0,"warnings":0}}'; sleep 2
STUB
env PATH="$H21/bin:$PATH" OKF_L2_TIMEOUT=0 "$CHECK" "$H21/b" >"$TMP/h21z.txt" 2>&1
grep -q "timed out" "$TMP/h21z.txt" && bad "LT-21b OKF_L2_TIMEOUT=0 must not kill at once" "timed out" \
  || ok "LT-21b OKF_L2_TIMEOUT=0 falls back to the default, not instant kill"
# F2: a finished run leaves no timer sleep behind
env PATH="$H21/bin:$PATH" OKF_L2_TIMEOUT=97 "$CHECK" "$H21/b" >/dev/null 2>&1; sleep 1
_o=$(pgrep -f '^sleep 97$' | wc -l | tr -d ' '); pkill -f '^sleep 97$' 2>/dev/null
[ "$_o" = "0" ] && ok "LT-21c no timer sleep is left behind after a normal run" || bad "LT-21c orphan timer" "$_o left"
# F4: an okflint that ignores TERM is still reported as timed out
cat > "$H21/bin/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
trap '' TERM; sleep 8
STUB
env PATH="$H21/bin:$PATH" OKF_L2_TIMEOUT=2 "$CHECK" "$H21/b" >"$TMP/h21t.txt" 2>&1
grep -q "timed out after 2 s" "$TMP/h21t.txt" && ok "LT-21d an okflint that ignores TERM is reported as timed out" || bad "LT-21d ignores TERM" "$(grep -n L2 "$TMP/h21t.txt" | head -2)"
pkill -f '^sleep 8$' 2>/dev/null

# LT-20p: an ignore file that excludes nothing changes nothing, even when every note is
# behind a symlinked directory. Since (S8-N1) a folder link that points outside the bundle is not
# entered by any layer, so both runs see no note (exit 0) and both name the link; before, L3 alone saw it (exit 4).
SL="$TMP/sl15"; mkdir -p "$SL/b" "$SL/out"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$SL/b/index.md"
printf -- '---\ntype: Lesson\ntitle: S\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2000-01-01"\n---\nx\n' > "$SL/out/stale.md"
ln -s "$SL/out" "$SL/b/lnk"
"$CHECK" "$SL/b" --fail-stale >/dev/null 2>&1; rc0=$?
printf '# nothing\n' > "$SL/b/.okfignore"
"$CHECK" "$SL/b" --fail-stale >"$TMP/sl15.txt" 2>&1; rc1=$?
{ [ "$rc0" = "0" ] && [ "$rc1" = "0" ] && ! grep -q "excludes every note" "$TMP/sl15.txt" && grep -qxE ' +lnk' "$TMP/sl15.txt"; } \
  && ok "LT-20p a no-op .okfignore keeps the verdict (exit $rc0 -> $rc1) and prints no false message" \
  || bad "LT-20p no-op ignore file" "without=$rc0 with=$rc1 $(grep -n IGNORE "$TMP/sl15.txt" | head -1)"
# LT-20q: a leading **/ also matches at the bundle root.
GQ="$TMP/gq16"; mkdir -p "$GQ/a"; for n in x.md a/x.md keep.md; do printf '# n\n' > "$GQ/$n"; done; printf '**/x.md\n' > "$GQ/.okfignore"
got=$(bash "$HERE/ignore-lib.sh" --list "$GQ" 2>/dev/null | tr '\0' '\n' | sort | tr '\n' ' ')
[ "$got" = "keep.md " ] && ok "LT-20q **/x.md excludes x.md at the root and a/x.md" || bad "LT-20q leading **/" "kept=[$got]"
printf '/**/x.md\n' > "$GQ/.okfignore"
got=$(bash "$HERE/ignore-lib.sh" --list "$GQ" 2>/dev/null | tr '\0' '\n' | sort | tr '\n' ' ')
[ "$got" = "keep.md " ] && ok "LT-20q2 /**/x.md behaves like **/x.md" || bad "LT-20q2 slash then **/" "kept=[$got]"
# LT-20r (review): excluding only NON-note files must not claim 'excludes every note'.
JN="$TMP/jn"; mkdir -p "$JN/b"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$JN/b/index.md"; printf '{}\n' > "$JN/b/x.json"; printf '*.json\n' > "$JN/b/.okfignore"
"$CHECK" "$JN/b" >"$TMP/jn.txt" 2>&1; rc=$?
{ [ "$rc" = "0" ] && ! grep -q "excludes every note" "$TMP/jn.txt"; } && ok "LT-20r excluding only a non-note file is not 'every note' (exit $rc)" || bad "LT-20r non-note exclusion" "rc=$rc $(grep -n IGNORE "$TMP/jn.txt" | head -1)"
# LT-22: the status vocabulary exists twice; the copies must stay equal.
tpl=$(sed -n 's/.*status_values: \[\(.*\)\].*/\1/p' "$HERE/../config/okf-base.yaml.template" | head -1 | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ' ')
lib=$(sed -n 's/^function okfstatusok.*{ return \(.*\) }$/\1/p' "$HERE/l3-lib.sh" | grep -o '"[a-z]*"' | tr -d '"' | sort | tr '\n' ' ')
{ [ -n "$tpl" ] && [ "$tpl" = "$lib" ]; } && ok "LT-22 status values in okf-base.yaml.template equal l3-lib.sh ($lib)" || bad "LT-22 status parity" "template=[$tpl] l3-lib=[$lib]"
# LT-23: every user-facing environment variable is documented in README and in the skill.
# "The skill" is SKILL.md plus the reference files it links (0.9.0 moved the maintainer detail into
# skills/okf/references/, one level deep, as Anthropic's skill guidance asks); the variables did not go away.
miss=""; for v in OKF_L2_TIMEOUT OKF_L2_ISOLATE_MAX OKF_INSTALL_TIMEOUT OKF_DOC_DIRS_FILE OKF_SEARCH_BIN OKF_AUTO_INSTALL; do
  grep -q "$v" "$HERE/../../README.md" 2>/dev/null || miss="$miss README:$v"
  grep -rq "$v" "$HERE/../skills/okf" 2>/dev/null || miss="$miss SKILL:$v"
done
[ -z "$miss" ] && ok "LT-23 user-facing environment variables are documented" || bad "LT-23 env docs" "missing:$miss"

# LT-24: a note that crashes okflint is named and the others are still checked;
# above OKF_L2_ISOLATE_MAX notes the rescue is skipped (today's report).
I24="$TMP/i24"; mkbundle "$I24/b"; mkdir -p "$I24/bin"
cp "$HERE/../config/okf-base.yaml.template" "$I24/b/okf-base.yaml"
for n in good1 good2 bad; do printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nx\n' > "$I24/b/$n.md"; done
cat > "$I24/bin/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
if [ -f bad.md ]; then echo "Traceback: boom" >&2; exit 3; fi
echo '[]'; exit 0
STUB
chmod +x "$I24/bin/okflint"
env PATH="$I24/bin:$PATH" "$CHECK" "$I24/b" >"$TMP/i24a.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && grep -q "bad.md" "$TMP/i24a.txt" && grep -q "L2 profile  *PASS" "$TMP/i24a.txt" && ! grep -q "exited 3 (crashed or missing)" "$TMP/i24a.txt"; } \
  && ok "LT-24a a crashing note is named, the others are checked, exit 2 (never a pass)" \
  || bad "LT-24a isolation" "rc=$rc $(grep -n 'L2\|bad.md' "$TMP/i24a.txt" | head -4 | tr '\n' ' ')"
env PATH="$I24/bin:$PATH" OKF_L2_ISOLATE_MAX=1 "$CHECK" "$I24/b" >"$TMP/i24b.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && grep -q "exited 3 (crashed or missing)" "$TMP/i24b.txt"; } \
  && ok "LT-24b above the cap the rescue is skipped and the old report is kept" \
  || bad "LT-24b cap" "rc=$rc $(grep -n 'L2' "$TMP/i24b.txt" | head -3 | tr '\n' ' ')"
rm -f "$I24/b/bad.md"
env PATH="$I24/bin:$PATH" "$CHECK" "$I24/b" >"$TMP/i24c.txt" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "LT-24c no crashing note: unchanged, exit 0" || bad "LT-24c clean" "rc=$rc"

# LT-24d-g (review round 1): the rescue mirror is a full copy (reserved files, assets), crashed notes
# are sorted, all-crash is not a PASS, and findings still decide the exit.
J24="$TMP/j24"; mkbundle "$J24/b"; mkdir -p "$J24/bin"; cp "$HERE/../config/okf-base.yaml.template" "$J24/b/okf-base.yaml"
for n in good1 bad2 bad1; do printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\nx\n' > "$J24/b/$n.md"; done
cat > "$J24/bin/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
if [ -f bad1.md ] || [ -f bad2.md ]; then echo "boom" >&2; exit 3; fi
if [ ! -f index.md ]; then echo '[{"severity":"error","code":"R201","file":"index.md","message":"reserved file missing"}]'; exit 1; fi
if [ -f good1.md ] && [ -n "$FIND_GOOD" ]; then echo '[{"severity":"error","code":"S999","file":"good1.md","message":"finding"}]'; exit 1; fi
echo '[]'; exit 0
STUB
chmod +x "$J24/bin/okflint"
env PATH="$J24/bin:$PATH" "$CHECK" "$J24/b" >"$TMP/j24a.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && ! grep -q "R201" "$TMP/j24a.txt" && ! grep -q "l2mirror" "$TMP/j24a.txt"; } \
  && ok "LT-24d the rescue mirror keeps index.md: no fabricated R201, no temp path (exit $rc)" \
  || bad "LT-24d reserved files" "rc=$rc $(grep -n 'R201\|l2mirror' "$TMP/j24a.txt" | head -2 | tr '\n' ' ')"
a=$(grep -n "bad1.md" "$TMP/j24a.txt" | head -1 | cut -d: -f1); b=$(grep -n "bad2.md" "$TMP/j24a.txt" | head -1 | cut -d: -f1)
{ [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } && ok "LT-24f crashed notes are listed sorted" || bad "LT-24f order" "bad1 line=$a bad2 line=$b"
env PATH="$J24/bin:$PATH" FIND_GOOD=1 "$CHECK" "$J24/b" >"$TMP/j24c.txt" 2>&1; rc=$?
{ [ "$rc" -eq 3 ] && grep -q "S999" "$TMP/j24c.txt" && grep -q "bad1.md" "$TMP/j24c.txt"; } \
  && ok "LT-24g findings in the checked notes keep exit 3 and the crashed notes are still named" \
  || bad "LT-24g findings plus crash" "rc=$rc"
for _f in "$J24/b"/*.md; do case "${_f##*/}" in index.md|log.md|bad1.md|bad2.md) ;; *) rm -f "$_f";; esac; done
env PATH="$J24/bin:$PATH" "$CHECK" "$J24/b" >"$TMP/j24d.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && ! grep -q "L2 profile  *PASS" "$TMP/j24d.txt" && ! grep -q "other notes were checked" "$TMP/j24d.txt"; } \
  && ok "LT-24e when every note crashes there is no PASS line and no 'others were checked'" \
  || bad "LT-24e all crash" "rc=$rc $(grep -n 'L2' "$TMP/j24d.txt" | head -3 | tr '\n' ' ')"

# --- 0.9.0 T1: L1 warnings are LISTED, not only counted (cases S1, S2, S13) ---
section "0.9.0 T1"
# 0.8.1 printed "1 warning(s)" and named nothing; the text was visible only by running
# the vendored validator by hand. A count a reader cannot act on is a count they stop reading.
mkwarnnote() { # <bundle> <file> <actor> — a note whose generated.by is <actor>
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: %s\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' "$3" > "$1/$2"
}
W1="$TMP/w1"; mkbundle "$W1"; mkwarnnote "$W1" n.md "Human:dana"
"$CHECK" "$W1" >"$TMP/w1.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '1 warning(s)' "$TMP/w1.txt" && grep -Eq '^ +n\.md: .*near-miss' "$TMP/w1.txt"; } \
  && ok "LT-25a S1-H1 a near-miss actor warning is listed as '<note>: <message>' (exit 0)" \
  || bad "LT-25a S1-H1 listing" "rc=$rc $(grep -n 'warning\|n.md' "$TMP/w1.txt" | head -3 | tr '\n' ' ')"

W0="$TMP/w0"; mkbundle "$W0"
"$CHECK" "$W0" >"$TMP/w0.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '0 warning(s)' "$TMP/w0.txt" && ! grep -Eq '^ +[^ ]+\.md: ' "$TMP/w0.txt"; } \
  && ok "LT-25b S1-N1 a bundle with 0 warnings lists no warning line" \
  || bad "LT-25b S1-N1 clean" "rc=$rc"

mkwarnbundle() { # <dir> <n> — a bundle with <n> near-miss notes, n1.md ... n<n>.md
  mkbundle "$1"; local i=1; while [ "$i" -le "$2" ]; do mkwarnnote "$1" "n$i.md" "Human:dana"; i=$((i+1)); done
}
W3="$TMP/w3"; mkwarnbundle "$W3" 3
"$CHECK" "$W3" >"$TMP/w3.txt" 2>&1
listed=$(grep -Ec '^ +n[0-9]+\.md: ' "$TMP/w3.txt")
{ grep -q '3 warning(s)' "$TMP/w3.txt" && [ "$listed" -eq 3 ]; } \
  && ok "LT-25c S2-H1 the count equals the number of listed warning lines (3 = 3)" \
  || bad "LT-25c S2-H1 count" "listed=$listed $(grep -n 'warning(s)' "$TMP/w3.txt" | head -1)"

W60="$TMP/w60"; mkwarnbundle "$W60" 60
"$CHECK" "$W60" >"$TMP/w60.txt" 2>&1
listed=$(grep -Ec '^ +n[0-9]+\.md: ' "$TMP/w60.txt")
{ grep -q '60 warning(s)' "$TMP/w60.txt" && [ "$listed" -eq 50 ] && grep -q 'and 10 more' "$TMP/w60.txt"; } \
  && ok "LT-25d S1-E1 60 warnings: the summary says 60, 50 lines print, then 'and 10 more'" \
  || bad "LT-25d S1-E1 cap" "listed=$listed $(grep -n 'more\|warning(s)' "$TMP/w60.txt" | head -2 | tr '\n' ' ')"
W51="$TMP/w51"; mkwarnbundle "$W51" 51
"$CHECK" "$W51" >"$TMP/w51.txt" 2>&1
listed=$(grep -Ec '^ +n[0-9]+\.md: ' "$TMP/w51.txt")
{ grep -q '51 warning(s)' "$TMP/w51.txt" && [ "$listed" -eq 50 ] && grep -q 'and 1 more' "$TMP/w51.txt"; } \
  && ok "LT-25e S2-E1 51 warnings: the summary says 51, 50 lines print, then 'and 1 more'" \
  || bad "LT-25e S2-E1 cap+1" "listed=$listed"

"$CHECK" --json "$W1" >"$TMP/w1j.txt" 2>/dev/null
"$REALPY" - "$TMP/w1j.txt" <<'PY' 2>"$TMP/w1jerr.txt"
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
assert isinstance(d["warnings"], list) and len(d["warnings"]) == 1, d.get("warnings")
assert d["warnings"][0].startswith("n.md: ") and "near-miss" in d["warnings"][0]
assert d["l1_warnings"] == 1
for k in ("bundle", "exit", "l1_errors", "l1_warnings", "concepts", "change_detection"):
    assert k in d, k
PY
rc=$?
[ "$rc" -eq 0 ] && ok "LT-25f S13-H1/E1 --json carries 'warnings' (list of '<note>: <message>') and keeps every 0.8.1 key" \
  || bad "LT-25f S13-H1 json" "$(head -2 "$TMP/w1jerr.txt" | tr '\n' ' ')"
"$CHECK" --json "$W0" >"$TMP/w0j.txt" 2>/dev/null
grep -q '"warnings":\[\]' "$TMP/w0j.txt" \
  && ok "LT-25g S13-N1 --json on a clean bundle has an empty 'warnings' list, not a missing key" \
  || bad "LT-25g S13-N1 json empty" "$(tail -1 "$TMP/w0j.txt" | cut -c1-160)"

# LT-25h (round-1 review, both axes): on a FAILING bundle the warning lines print under the error
# lines. Without a count on the FAIL line, "1 error(s)" sits above two unlabelled lines and the
# reader cannot tell which one is the warning — the count-is-not-the-lines defect LT-25c guards on PASS.
WF="$TMP/wf"; mkbundle "$WF"; mkwarnnote "$WF" w.md "Human:dana"
printf -- '---\ntitle: no type here\n---\n\nbody\n' > "$WF/e.md"
"$CHECK" "$WF" >"$TMP/wf.txt" 2>&1; rc=$?
nwarn=$("$CHECK" --json "$WF" 2>/dev/null | tail -1 | "$REALPY" -c 'import json,sys; print(json.load(sys.stdin)["l1_warnings"])')
{ [ "$rc" -eq 1 ] && [ "${nwarn:-0}" -ge 1 ] && grep -Eq "L1 conformance +FAIL +[0-9]+ error\(s\), ${nwarn} warning\(s\)" "$TMP/wf.txt"; } \
  && ok "LT-25h a failing bundle's FAIL line carries the warning count (${nwarn}) so the warning lines under it are accounted for" \
  || bad "LT-25h FAIL-path warning count" "rc=$rc nwarn=$nwarn $(grep -n 'FAIL' "$TMP/wf.txt" | head -1)"

# --- 0.9.0 T2: C4 "unauthenticated human verification" (cases S3-S6, S9-S12) ---
section "0.9.0 T2"
# OKF v0.2 records `verified: by: human:<id>` and cannot authenticate it: an agent can write that
# line itself. 0.8.1 gave exit 0 and no finding for a DRAFT note an agent generated and a "human"
# verified. Executed baseline: generated.by agent/1 + verified human:finance-owner + draft.
mktrust() { # <bundle> <file> <status> <generated.by> <generated.at> <verified-yaml-block>
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: %s\ntags: [t]\ngenerated:\n  by: %s\n  at: "%s"\n%s\nstale_after: "2099-01-01"\n---\n\nbody\n' "$3" "$4" "$5" "$6" > "$1/$2"
}
VH='verified:\n  - by: human:finance-owner\n    at: "2026-02-01"'
C1="$TMP/c4a"; mkbundle "$C1"; mktrust "$C1" n.md draft agent/1 2026-01-01 "$(printf "$VH")"
"$CHECK" "$C1" >"$TMP/c4a.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$TMP/c4a.txt" \
  && [ "$(grep -c 'cannot prove who a person is' "$TMP/c4a.txt")" -eq 1 ]; } \
  && ok "LT-26a S3-H1/S11-H1 a draft note with a human: verifier warns (names verified[0].by, exit 0) and the identity line prints once" \
  || bad "LT-26a S3-H1 draft+human" "rc=$rc $(grep -n 'n.md\|prove\|Trust' "$TMP/c4a.txt" | head -3 | tr '\n' ' ')"

# c4run <name> <status> <generated.by> <generated.at> <verified-yaml>  — one-note bundle, run, set C4RC/C4OUT
c4run() {
  local d="$TMP/c4_$1"; mkbundle "$d"; rm -f "$d/c.md"; mktrust "$d" n.md "$2" "$3" "$4" "$5"
  C4OUT="$TMP/c4_$1.txt"; "$CHECK" "$d" >"$C4OUT" 2>&1; C4RC=$?; C4DIR="$d"
}
# vent <by> [<at>] — one verified list entry
vent() { if [ -n "${2:-}" ]; then printf '  - by: %s\n    at: "%s"\n' "$1" "$2"; else printf '  - by: %s\n' "$1"; fi; }
c4quiet() { # <label> — no Trust finding line and the identity line absent
  { grep -q 'Trust (C4) *PASS' "$C4OUT" && ! grep -q 'cannot prove who a person is' "$C4OUT" && [ "$C4RC" -eq 0 ]; } \
    && ok "$1" || bad "$1" "rc=$C4RC $(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
}

c4run b stable human:t 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
c4quiet "LT-26b S3-N1/S9-H1 a stable note, human generator, review after the change: no C4 finding, exit 0"

c4run c draft agent/1 2026-01-01 "verified:
$(vent human:a 2026-02-01)
$(vent human:b 2026-02-02)"
{ grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$C4OUT" && grep -Eq '^ +n\.md: verified\[1\]\.by .*draft' "$C4OUT" && grep -q '2 warning(s), 0 advisory' "$C4OUT"; } \
  && ok "LT-26c S3-E1 a draft with two human entries gives two warnings, one per entry" \
  || bad "LT-26c S3-E1 two entries" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -3 | tr '\n' ' ')"

c4run d stable human:t 2026-10-10 "verified:
$(vent human:dana 2026-10-01)"
{ grep -Eq '^ +n\.md: verified\[0\]\.by .*changed after the claimed review' "$C4OUT" && grep -q '1 warning(s), 0 advisory' "$C4OUT" && [ "$C4RC" -eq 0 ]; } \
  && ok "LT-26d S4-H1 review dated before generated.at: warning 'changed after the claimed review'" \
  || bad "LT-26d S4-H1 changed-after" "rc=$C4RC $(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
c4run e stable human:t 2026-10-10 "verified:
$(vent human:dana 2026-10-12)"
c4quiet "LT-26e S4-N1 review dated after generated.at: no finding"
c4run e2 stable human:t 2026-10-10 "verified:
$(vent human:dana 2026-10-10)"
c4quiet "LT-26e2 S4-E1 review dated equal to generated.at: not earlier, no finding"

c4run f stable agent/1 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
{ grep -Eq '^ +n\.md: verified\[0\]\.by .*cannot be authenticated' "$C4OUT" && grep -q '0 warning(s), 1 advisory' "$C4OUT" && [ "$C4RC" -eq 0 ] \
  && grep -q '1 advisory(ies)' "$C4OUT"; } \
  && ok "LT-26f S5-H1 an agent-generated note with a human verifier gives an advisory, not a warning (exit 0)" \
  || bad "LT-26f S5-H1 advisory" "rc=$C4RC $(grep -n 'Trust\|n.md\|PASS' "$C4OUT" | head -3 | tr '\n' ' ')"
c4run g stable agent:bot 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
grep -q '0 warning(s), 1 advisory' "$C4OUT" && ok "LT-26g S5-E1 the agent:<id> generator form is an agent too" || bad "LT-26g S5-E1 agent: form" "$(grep -n Trust "$C4OUT" | head -1)"
c4run g2 stable agent/1 2026-01-01 "verified:
$(vent human:dana)"
{ grep -q '0 warning(s), 1 advisory' "$C4OUT" && ! grep -q 'changed after' "$C4OUT"; } \
  && ok "LT-26g2 S5-E2 an agent note, human verifier with no 'at': advisory only, no changed-after warning" \
  || bad "LT-26g2 S5-E2 no at" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
c4run g3 stable human:t 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
grep -q 'Trust (C4) *PASS' "$C4OUT" && ok "LT-26g3 S5-N1 a human-generated note with a human verifier gives no advisory" || bad "LT-26g3 S5-N1" "$(grep -n Trust "$C4OUT" | head -1)"

c4run h draft agent/1 2026-01-01 "verified:
$(vent process:lint 2026-02-01)
$(vent human:dana 2026-02-01)
$(vent process:ci 2026-02-02)"
{ grep -Eq '^ +n\.md: verified\[1\]\.by ' "$C4OUT" && ! grep -Eq 'verified\[(0|2)\]' "$C4OUT" && grep -q '1 warning(s), 0 advisory' "$C4OUT"; } \
  && ok "LT-26h S6-E1/S10-E1 only the human: entry is reported, indexed by its position (verified[1])" \
  || bad "LT-26h S6-E1 index" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -3 | tr '\n' ' ')"
c4run i draft agent/1 2026-01-01 "verified:
$(vent process:ci-linter 2026-02-01)"
c4quiet "LT-26i S10-H1 a process: verifier on a draft is never reported"
c4run j draft process:nightly 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$C4OUT" && ok "LT-26j S10-N1 a process: generator does not hide a human verifier on a draft" || bad "LT-26j S10-N1" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
c4run k stable human:t 2026-01-01 ""
c4quiet "LT-26k S9-E1 a note with no verified field: no C4 finding"
c4run l draft agent/1 2026-01-01 "verified: []"
c4quiet "LT-26l S12-E1 an empty verified list on a draft: no finding"
c4run m draft agent/1 2026-01-01 "verified: just-a-string"
{ [ "$C4RC" -le 1 ] && ! grep -q 'Traceback' "$C4OUT" && grep -q 'Trust (C4) *PASS' "$C4OUT"; } \
  && ok "LT-26m S12-N1 a verified field of the wrong shape: no crash and no C4 finding (L1 owns the shape)" \
  || bad "LT-26m S12-N1" "rc=$C4RC $(grep -n 'Trace\|Trust' "$C4OUT" | head -2 | tr '\n' ' ')"
c4run n draft agent/1 2026-01-01 "verified:
  by: human:dana
  at: \"2026-02-01\""
grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$C4OUT" && ok "LT-26n S12-H1 a verified MAPPING (one event) is read as a one-element list" || bad "LT-26n S12-H1 mapping" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"

# S11-E1: five findings, the identity line prints once
D5="$TMP/c4_five"; mkbundle "$D5"; rm -f "$D5/c.md"; i=1
while [ "$i" -le 5 ]; do mktrust "$D5" "n$i.md" draft agent/1 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"; i=$((i+1)); done
"$CHECK" "$D5" >"$TMP/c4_five.txt" 2>&1
{ [ "$(grep -c 'cannot prove who a person is' "$TMP/c4_five.txt")" -eq 1 ] && grep -q '5 warning(s), 0 advisory' "$TMP/c4_five.txt"; } \
  && ok "LT-26o S11-E1 five findings: the identity line prints once" || bad "LT-26o S11-E1" "$(grep -c 'prove' "$TMP/c4_five.txt")"
# S11-N1 is LT-26b (quiet case has no identity line). S6-N1: a clean bundle prints no C4 line.
"$CHECK" "$W0" 2>&1 | grep -Eq '^ +[^ ]+\.md: verified\[' && bad "LT-26p S6-N1" "clean bundle printed a C4 line" || ok "LT-26p S6-N1 a bundle with no C4 case prints no C4 finding line"

# S2-N1 (carried from T1): 0 L1 warnings and 2 advisories: each counter keeps its own meaning.
D2="$TMP/c4_two"; mkbundle "$D2"; rm -f "$D2/c.md"
mktrust "$D2" a.md stable agent/1 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
mktrust "$D2" b.md stable agent/1 2026-01-01 "verified:
$(vent human:erin 2026-02-01)"
"$CHECK" "$D2" >"$TMP/c4_two.txt" 2>&1
{ grep -q 'L1 conformance *PASS.* 0 warning(s)' "$TMP/c4_two.txt" && grep -q '0 warning(s), 2 advisory(ies)' "$TMP/c4_two.txt" \
  && grep -q 'but 2 advisory(ies)' "$TMP/c4_two.txt"; } \
  && ok "LT-26s S2-N1 0 L1 warnings and 2 advisories: the L1 line says 0 warning(s), the final tally says 2 advisory(ies)" \
  || bad "LT-26s S2-N1 counters" "$(grep -n 'warning(s)\|advisory' "$TMP/c4_two.txt" | head -3 | tr '\n' ' ')"

# Review round 1. Row "generator missing or near-miss": the ADVISORY needs an agent generator, so none fires;
# the draft and changed-after warnings do not depend on the generator and still fire.
c4run u stable "" 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
c4quiet "LT-26u a stable note whose generated.by is empty, human verifier: no C4 finding (no agent to flag)"
c4run v stable Human:dana 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
c4quiet "LT-26v a near-miss generator (Human:dana) on a stable note: no C4 finding (L1 already warns about the actor)"
c4run w draft Human:dana 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$C4OUT" && ok "LT-26w a draft still warns when the generator is a near-miss (the draft row does not depend on the generator)" || bad "LT-26w" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
# A UTF-8 BOM before the frontmatter fence: L1 counts the note, so this layer must read it too.
D7="$TMP/c4_bom"; mkbundle "$D7"; rm -f "$D7/c.md"
{ printf '\357\273\277'; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: draft\ntags: [t]\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: human:dana\n    at: "2026-02-01"\nstale_after: "2099-01-01"\n---\n\nbody\n'; } > "$D7/n.md"
"$CHECK" "$D7" >"$TMP/c4_bom.txt" 2>&1
grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$TMP/c4_bom.txt" && ok "LT-26x a note that starts with a UTF-8 BOM is checked too (L1 counts it)" || bad "LT-26x BOM" "$(grep -n 'concepts\|Trust' "$TMP/c4_bom.txt" | head -2 | tr '\n' ' ')"
# A bare date against a timestamp: compare days, so a same-day review of a timed change is not 'changed after'.
c4run y stable human:t "2026-10-16T10:00:00Z" "verified:
$(vent human:dana 2026-10-16)"
c4quiet "LT-26y a review dated the same DAY as a timed generated.at: no finding (a bare date cannot say which came first)"
c4run y2 stable human:t "2026-10-16T10:00:00Z" "verified:
$(vent human:dana 2026-10-15)"
grep -q 'changed after the claimed review' "$C4OUT" && ok "LT-26y2 a review dated the day BEFORE a timed generated.at still warns" || bad "LT-26y2" "$(grep -n 'Trust' "$C4OUT" | head -1)"
# Fail closed: a broken trust helper is COULD NOT RUN (exit 2), never a pass, and --json says "unknown", not "clean".
BRK="$TMP/c4_brokenplugin"; mkdir -p "$BRK"; cp -R "$HERE/.." "$BRK/plugin" 2>/dev/null
printf 'import sys\nsys.stderr.write("boom from test\\n")\nsys.exit(3)\n' > "$BRK/plugin/scripts/okf-trust.py"
"$BRK/plugin/scripts/okf-check" "$C1" >"$TMP/c4_broken.txt" 2>&1; rc=$?
{ [ "$rc" -eq 2 ] && grep -Eq 'Trust \(C4\) +COULD NOT RUN.*boom from test' "$TMP/c4_broken.txt" && ! grep -q 'ALL GATES PASS' "$TMP/c4_broken.txt"; } \
  && ok "LT-26z a broken trust helper is COULD NOT RUN (exit 2) with the helper's own error shown" \
  || bad "LT-26z COULD NOT RUN" "rc=$rc $(grep -n 'Trust' "$TMP/c4_broken.txt" | head -1)"
"$BRK/plugin/scripts/okf-check" --json "$C1" >"$TMP/c4_brokenj.txt" 2>/dev/null
grep -q '"trust_findings":null' "$TMP/c4_brokenj.txt" \
  && ok "LT-26z2 --json reports trust_findings as null (unknown) when the layer could not run, not an empty list" \
  || bad "LT-26z2 json null" "$(tail -1 "$TMP/c4_brokenj.txt" | cut -c1-200)"

# S13: trust_findings in --json (always present; empty list when clean)
"$CHECK" --json "$C1" >"$TMP/c4json.txt" 2>/dev/null
"$REALPY" - "$TMP/c4json.txt" <<'PY' 2>"$TMP/c4jsonerr.txt"
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
f = d["trust_findings"]
assert len(f) == 1, f
assert set(f[0]) == {"file", "entry", "severity", "reason"}, f[0]
assert (f[0]["file"], f[0]["entry"], f[0]["severity"]) == ("n.md", "verified[0].by", "warning"), f[0]
assert d["exit"] == 0 and "warnings" in d and "l1_warnings" in d
PY
[ $? -eq 0 ] && ok "LT-26q S13-H1 --json carries trust_findings objects {file, entry, severity, reason}" || bad "LT-26q S13-H1" "$(head -2 "$TMP/c4jsonerr.txt" | tr '\n' ' ')"
"$CHECK" --json "$W0" 2>/dev/null | grep -q '"trust_findings":\[\]' && ok "LT-26r S13-N1 --json on a clean bundle has an empty trust_findings list" || bad "LT-26r S13-N1" "missing or non-empty"

# --- 0.9.0 T3: --strict-trust (cases S7, S8, S9-H1) ---
section "0.9.0 T3"
# Severity only: the findings are the same with or without the flag. A CI owner who wants a block
# opts in; the default stays advisory so the honest "agent drafts, person reviews later" flow is quiet.
c4run s1 draft agent/1 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
"$CHECK" --strict-trust "$C4DIR" >"$TMP/st1.txt" 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'trust policy failure (--strict-trust)' "$TMP/st1.txt" && grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$TMP/st1.txt"; } \
  && ok "LT-27a S7-H1 --strict-trust: a draft with a human verifier exits 1 and says 'trust policy failure (--strict-trust)'" \
  || bad "LT-27a S7-H1" "rc=$rc $(grep -n 'FAILED\|Trust' "$TMP/st1.txt" | head -3 | tr '\n' ' ')"
[ "$C4RC" -eq 0 ] && ok "LT-27b S7-N1/S8-N1 the same bundle without the flag still exits 0" || bad "LT-27b S7-N1" "rc=$C4RC"
c4run s2 stable agent/1 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
"$CHECK" --strict-trust "$C4DIR" >"$TMP/st2.txt" 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "LT-27c S7-E1 --strict-trust also fails an advisory-only case (agent note, human verifier)" || bad "LT-27c S7-E1" "rc=$rc"
# S7-E2: an L1 conformance error and a C4 case together: exit 1, 'not conformant' prints before the trust failure
DE="$TMP/st_both"; mkbundle "$DE"; rm -f "$DE/c.md"; mktrust "$DE" n.md draft agent/1 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
printf -- '---\ntitle: no type here\n---\n\nbody\n' > "$DE/e.md"
"$CHECK" --strict-trust "$DE" >"$TMP/st_both.txt" 2>&1; rc=$?
a=$(grep -n 'not conformant OKF' "$TMP/st_both.txt" | head -1 | cut -d: -f1); b=$(grep -n 'Trust policy' "$TMP/st_both.txt" | head -1 | cut -d: -f1)
{ [ "$rc" -eq 1 ] && [ -n "$a" ] && { [ -z "$b" ] || [ "$a" -lt "$b" ]; } && ! grep -q 'trust policy failure' "$TMP/st_both.txt"; } \
  && ok "LT-27d S7-E2 an L1 conformance error plus a C4 case: exit 1, 'not conformant' comes first, the summary does not blame trust alone" \
  || bad "LT-27d S7-E2" "rc=$rc a=$a b=$b $(grep -n 'FAILED' "$TMP/st_both.txt" | head -1)"
# S8: near-miss actors
c4run n1 stable Human:dana 2026-01-01 ""; C4DIR_N1="$C4DIR"
"$CHECK" --strict-trust "$C4DIR" >"$TMP/st_n1.txt" 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'trust policy failure (--strict-trust)' "$TMP/st_n1.txt" && [ "$C4RC" -eq 0 ] && grep -q 'near-miss of' "$C4OUT"; } \
  && ok "LT-27e S8-H1/S8-N1 a near-miss generator (Human:dana) fails under --strict-trust and only warns without it" \
  || bad "LT-27e S8-H1" "strict rc=$rc plain rc=$C4RC"
c4run n2 stable human:t 2026-01-01 "verified:
$(vent Human:dana 2026-02-01)"
"$CHECK" --strict-trust "$C4DIR" >"$TMP/st_n2.txt" 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "LT-27f S8-E1 a near-miss VERIFIER (Human:dana) fails under --strict-trust" || bad "LT-27f S8-E1" "rc=$rc"
c4run h1 stable human:t 2026-01-01 "verified:
$(vent human:erin 2026-02-01)"
"$CHECK" --strict-trust "$C4DIR" >"$TMP/st_h1.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q 'trust policy' "$TMP/st_h1.txt"; } \
  && ok "LT-27g S9-H1 an honest note passes under --strict-trust (exit 0, no trust line)" || bad "LT-27g S9-H1" "rc=$rc"
"$CHECK" --strict-trust --json "$C1" >"$TMP/st_j.txt" 2>/dev/null; rc=$?
{ [ "$rc" -eq 1 ] && grep -q '"exit":1' "$TMP/st_j.txt" && [ "$(wc -l < "$TMP/st_j.txt" | tr -d ' ')" -eq 1 ]; } \
  && ok "LT-27h --strict-trust with --json: one JSON line, exit 1" || bad "LT-27h" "rc=$rc"

# Review round 1. The near-miss count must match the validator's near-miss warning only, not any
# warning whose quoted actor text happens to contain those words.
c4run z1 stable "zz is a near-miss of" 2026-01-01 ""
"$CHECK" --strict-trust "$C4DIR" >"$TMP/st_z1.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'matches no actor shape' "$TMP/st_z1.txt" && ! grep -q 'trust policy' "$TMP/st_z1.txt"; } \
  && ok "LT-27i an unrelated warning that quotes the words 'is a near-miss of' does not fail --strict-trust" \
  || bad "LT-27i unrelated warning" "rc=$rc $(grep -n 'Trust policy\|FAILED' "$TMP/st_z1.txt" | head -2 | tr '\n' ' ')"
# The summary blames trust alone ONLY when nothing else failed: here staleness (--fail-stale, exit 4) failed too.
DS="$TMP/st_stale"; mkbundle "$DS"; rm -f "$DS/c.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: draft\ntags: [t]\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: human:dana\n    at: "2026-02-01"\nstale_after: "2020-01-01"\n---\n\nbody\n' > "$DS/n.md"
"$CHECK" --strict-trust --fail-stale "$DS" >"$TMP/st_stale.txt" 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'Trust policy *FAIL' "$TMP/st_stale.txt" && ! grep -q 'trust policy failure' "$TMP/st_stale.txt" && grep -Eq 'FAILED \(exit 1\)' "$TMP/st_stale.txt"; } \
  && ok "LT-27j trust failure plus a stale failure (--fail-stale): exit 1, the summary does not blame trust alone" \
  || bad "LT-27j summary blame" "rc=$rc $(grep -n 'FAILED' "$TMP/st_stale.txt" | head -1)"
# A trust layer that could not run plus a near-miss under --strict-trust: the summary must not say 'trust policy failure' alone.
"$BRK/plugin/scripts/okf-check" --strict-trust "$C4DIR_N1" >"$TMP/st_brk.txt" 2>&1; rc=$?
{ ! grep -q 'trust policy failure' "$TMP/st_brk.txt" && grep -q 'COULD NOT RUN' "$TMP/st_brk.txt"; } \
  && ok "LT-27k strict mode with a trust layer that could not run: the summary does not read as a plain trust-policy failure" \
  || bad "LT-27k could-not-run summary" "rc=$rc $(grep -n 'FAILED' "$TMP/st_brk.txt" | head -1)"

# --- 0.9.0 T4: --init-house-rules (cases S14-S18) ---
section "0.9.0 T4"
# L2 (house rules) was SKIPPED until the user hand-copied a template: an adoption cliff. The command
# writes the file the L2 layer actually reads (<bundle>/okf-base.yaml) and nothing else ever writes it.
H1="$TMP/ih1"; mkbundle "$H1"
"$CHECK" --init-house-rules "$H1" >"$TMP/ih1.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$H1/okf-base.yaml" ] && grep -q 'okf-base.yaml' "$TMP/ih1.txt" && ! grep -q 'CHANGE ME' "$H1/okf-base.yaml" && grep -q '^  name: ih1$' "$H1/okf-base.yaml"; } \
  && ok "LT-28a S14-H1 --init-house-rules <bundle> writes <bundle>/okf-base.yaml (name set from the folder), exit 0" \
  || bad "LT-28a S14-H1" "rc=$rc $(head -2 "$TMP/ih1.txt" | tr '\n' ' ')"
"$CHECK" --init-house-rules >"$TMP/ih2.txt" 2>&1; rc=$?
[ "$rc" -eq 64 ] && ok "LT-28b S14-N1 no bundle argument: usage, exit 64" || bad "LT-28b S14-N1" "rc=$rc"
"$CHECK" --init-house-rules "$TMP/ih_nowhere" >"$TMP/ih3.txt" 2>&1; rc=$?
{ [ "$rc" -eq 64 ] && [ ! -e "$TMP/ih_nowhere" ] && grep -q 'is not a directory' "$TMP/ih3.txt"; } && ok "LT-28c S14-E1 a bundle path that does not exist: nothing created, exit 64, the message says it is not a directory" || bad "LT-28c S14-E1" "rc=$rc $(head -1 "$TMP/ih3.txt")"
# S15: never overwrite
H2="$TMP/ih_exist"; mkbundle "$H2"; printf 'my own rules\n' > "$H2/okf-base.yaml"; cp "$H2/okf-base.yaml" "$TMP/ih_exist.before"
"$CHECK" --init-house-rules "$H2" >"$TMP/ih4.txt" 2>&1; rc=$?; "$CHECK" --init-house-rules "$H2" >/dev/null 2>&1; rc2=$?
{ [ "$rc" -eq 1 ] && [ "$rc2" -eq 1 ] && cmp -s "$H2/okf-base.yaml" "$TMP/ih_exist.before" && grep -q 'okf-base.yaml' "$TMP/ih4.txt"; } \
  && ok "LT-28d S15-H1/N1 an existing okf-base.yaml: exit 1, byte-identical after two runs, the message names the file" \
  || bad "LT-28d S15" "rc=$rc"
H3="$TMP/ih_empty"; mkbundle "$H3"; : > "$H3/okf-base.yaml"
"$CHECK" --init-house-rules "$H3" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && [ ! -s "$H3/okf-base.yaml" ]; } && ok "LT-28e S15-E1 an EMPTY okf-base.yaml is still refused and left empty" || bad "LT-28e S15-E1" "rc=$rc"
# S16: L2 runs on the starter file (needs okflint)
if command -v okflint >/dev/null 2>&1; then
  "$CHECK" "$H1" >"$TMP/ih5.txt" 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -Eq 'L2 profile +PASS' "$TMP/ih5.txt" && ! grep -q 'CHANGE ME' "$TMP/ih5.txt"; } \
    && ok "LT-28f S16-H1 L2 runs (not SKIPPED) and passes on the starter file as written" \
    || bad "LT-28f S16-H1" "rc=$rc $(grep -n 'L2' "$TMP/ih5.txt" | head -2 | tr '\n' ' ')"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\n---\n\nbody\n' > "$H1/nostale.md"
  "$CHECK" "$H1" >"$TMP/ih6.txt" 2>&1; rc=$?
  { [ "$rc" -eq 3 ] && grep -q 'nostale.md' "$TMP/ih6.txt"; } && ok "LT-28g S16-N1 a Lesson without stale_after breaks a starter rule: L2 reports it, exit 3" || bad "LT-28g S16-N1" "rc=$rc"
else
  skip "LT-28f/g L2 on the starter file — okflint not installed"
fi
H4="$TMP/ih:odd\"name"; mkbundle "$H4"
"$CHECK" --init-house-rules "$H4" >/dev/null 2>&1
grep -q '^  name: bundle$' "$H4/okf-base.yaml" && ok "LT-28h S16-E1 a folder name with YAML-special characters falls back to 'bundle'" || bad "LT-28h S16-E1" "$(grep -n 'name:' "$H4/okf-base.yaml" | head -1)"
# S17: only this command writes the file
H5="$TMP/ih_never"; mkbundle "$H5"
for flag in "" "--json" "--strict-trust" "--fail-stale"; do "$CHECK" $flag "$H5" >/dev/null 2>&1; done
"$CHECK" "$H5" --preflight >/dev/null 2>&1; "$CHECK" --preflight "$H5" >/dev/null 2>&1
[ ! -e "$H5/okf-base.yaml" ] && ok "LT-28i S17-H1/N1 no check run, flag or preflight ever creates okf-base.yaml" || bad "LT-28i S17" "file appeared"
H6="$TMP/ih_ro"; mkbundle "$H6"; chmod 555 "$H6"
"$CHECK" --init-house-rules "$H6" >"$TMP/ih7.txt" 2>&1; rc=$?; chmod 755 "$H6"
{ [ "$rc" -ne 0 ] && [ ! -e "$H6/okf-base.yaml" ]; } && ok "LT-28j S17-E1 a read-only bundle folder: non-zero exit, nothing created (rc=$rc)" || bad "LT-28j S17-E1" "rc=$rc"
# S18: the skip line names the command; --json says so as data
"$CHECK" "$H5" >"$TMP/ih8.txt" 2>&1
{ grep -q 'okf-check --init-house-rules' "$TMP/ih8.txt" && grep -q 'NOT enforced' "$TMP/ih8.txt"; } \
  && ok "LT-28k S18-H1 the 'house rules not enforced' line names okf-check --init-house-rules" || bad "LT-28k S18-H1" "$(grep -n 'L2 profile' -A1 "$TMP/ih8.txt" | head -2 | tr '\n' ' ')"
"$CHECK" "$H2" >"$TMP/ih9.txt" 2>&1
! grep -q 'init-house-rules' "$TMP/ih9.txt" && ok "LT-28l S18-N1 with an okf-base.yaml present the line is absent" || bad "LT-28l S18-N1" "named the command"
"$CHECK" --json "$H5" >"$TMP/ih10.txt" 2>/dev/null
grep -q '"l2_profile":"skipped"' "$TMP/ih10.txt" && ok "LT-28m S18-E1 --json carries l2_profile:\"skipped\" as data" || bad "LT-28m S18-E1" "$(tail -1 "$TMP/ih10.txt" | cut -c1-200)"

# Review round 1. l2_profile must not say "ran" when L2 could not reach a verdict: a CI job that
# reads the field would think the house rules were checked.
if command -v okflint >/dev/null 2>&1; then
  HX="$TMP/ih_badmanifest"; mkbundle "$HX"; printf 'base: [not, a, map]\n' > "$HX/okf-base.yaml"
  "$CHECK" --json "$HX" >"$TMP/ih_bm.txt" 2>/dev/null; rc=$?
  { [ "$rc" -eq 2 ] && grep -q '"l2_profile":"could_not_run"' "$TMP/ih_bm.txt"; } \
    && ok "LT-28n l2_profile is could_not_run (not ran) when okflint rejects the manifest (exit 2)" \
    || bad "LT-28n l2_profile on a rejected manifest" "rc=$rc $(tail -1 "$TMP/ih_bm.txt" | cut -c1-200)"
else
  skip "LT-28n l2_profile on a rejected manifest — okflint not installed"
fi

# Found by running the suite on Debian (Linux, no okflint): LT-28k passed on macOS only because okflint was
# installed there. Without okflint the skip comes from a different branch, and that branch did not name the
# command that creates the starter file. A person without okflint is exactly who needs the hint.
HN="$TMP/ih_noflint"; mkbundle "$HN"
PATH="$SB10" "$SB10/bash" "$CHECK" "$HN" >"$TMP/ih_nf.txt" 2>&1
{ grep -q 'L2 profile *SKIPPED' "$TMP/ih_nf.txt" && grep -q 'okf-check --init-house-rules' "$TMP/ih_nf.txt"; } \
  && ok "LT-28o S18-H1 (no okflint, no okf-base.yaml) the skipped-L2 line names okf-check --init-house-rules as well as the okflint install" \
  || bad "LT-28o S18-H1 without okflint" "$(grep -n 'L2 profile' -A2 "$TMP/ih_nf.txt" | head -3 | tr '\n' ' ')"
PATH="$SB10" "$SB10/bash" "$CHECK" --json "$HN" >"$TMP/ih_nfj.txt" 2>/dev/null
grep -q '"l2_profile":"skipped"' "$TMP/ih_nfj.txt" && ok "LT-28p --json says l2_profile:\"skipped\" when okflint is absent" || bad "LT-28p" "$(tail -1 "$TMP/ih_nfj.txt" | cut -c1-200)"

# --- 0.9.0 release review (round 1): findings of the integration, spec and security reviewers ---
section "0.9.0 release review (round 1)"
# (a) A gate that cannot fail is the defect this tool exists to catch: --selftest had no probe for the trust layer,
# so a disabled trust rule still printed SELFTEST PASS. Cripple a plugin copy's helper; selftest must now FAIL (exit 5).
DEADT="$TMP/deadtrust"; mkdir -p "$DEADT"; cp -R "$HERE/.." "$DEADT/plugin" 2>/dev/null
# Guarded like the real helper: okf-scoped.py (--file) imports okf-trust.py, and an unguarded stub wrote "[]" into
# the caller's working directory under the scoped note's name.
printf 'import sys, json\nif __name__ == "__main__":\n    json.dump([], open(sys.argv[2], "w"))\n' > "$DEADT/plugin/scripts/okf-trust.py"
"$DEADT/plugin/scripts/okf-check" --selftest >"$TMP/deadtrust.txt" 2>&1; rc=$?
{ [ "$rc" -eq 5 ] && grep -q 'NOT FIRED' "$TMP/deadtrust.txt" && grep -q 'C4' "$TMP/deadtrust.txt"; } \
  && ok "LT-32a --selftest FAILS (exit 5) when the trust layer stops firing: the Trust gate has a probe" \
  || bad "LT-32a selftest trust probe" "rc=$rc $(grep -n 'C4\|SELFTEST' "$TMP/deadtrust.txt" | head -2 | tr '\n' ' ')"
# (b) A YAML alias bomb in verified.by / generated.by made str() expand billions of items (2.5 GB, killed at 60 s).
# The helper must not stringify a non-string actor. Bounded: the helper gets 3 s, then it is killed.
BOMB="$TMP/bomb"; mkbundle "$BOMB"; rm -f "$BOMB/c.md"
"$REALPY" - "$BOMB/n.md" <<'PY'
import sys
lines = ["---", "type: Lesson", "title: T", "description: D", "status: draft", "tags: [t]", 'stale_after: "2099-01-01"',
         "x0: &a0 [x,x,x,x,x,x,x,x,x]"]
for i in range(1, 8):
    lines.append("x%d: &a%d [%s]" % (i, i, ",".join(["*a%d" % (i - 1)] * 9)))
lines += ["generated: {by: *a7, at: \"2026-01-01\"}", "verified:", "  - by: *a7", "    at: \"2026-02-01\"", "---", "", "body"]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
"$REALPY" - "$HERE/okf-trust.py" "$BOMB" "$TMP/bomb.json" <<'PY' 2>"$TMP/bomb_err.txt"
import subprocess, sys, os
env = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(sys.argv[1]), "..", "vendor", "pyyaml"))
try:
    r = subprocess.run([sys.executable, sys.argv[1], sys.argv[2], sys.argv[3]], timeout=3, env=env, capture_output=True)
except subprocess.TimeoutExpired:
    print("TIMEOUT: the helper expanded the alias bomb", file=sys.stderr); sys.exit(1)
sys.exit(0 if r.returncode == 0 else 2)
PY
rc=$?
[ "$rc" -eq 0 ] && ok "LT-32b a YAML alias bomb in verified.by / generated.by is ignored by the trust helper (done within 3 s, no expansion)" || bad "LT-32b alias bomb" "rc=$rc $(head -1 "$TMP/bomb_err.txt")"
# (c) Spec-review gaps: S6-H1 a note in a SUBFOLDER is named with its path; S9-N1 a draft with a human generator still warns;
# S17-N1 the other two hooks never create okf-base.yaml either.
SUBB="$TMP/subf"; mkbundle "$SUBB"; rm -f "$SUBB/c.md"; mkdir -p "$SUBB/notes"; mktrust "$SUBB/notes" a.md draft human:t 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
"$CHECK" "$SUBB" >"$TMP/subf.txt" 2>&1
grep -Eq '^ +notes/a\.md: verified\[0\]\.by' "$TMP/subf.txt" && ok "LT-32c S6-H1 a finding in a subfolder names the note with its path (notes/a.md)" || bad "LT-32c S6-H1" "$(grep -n 'a.md\|Trust' "$TMP/subf.txt" | head -2 | tr '\n' ' ')"
c4run dh draft human:t 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$C4OUT" && ok "LT-32d S9-N1 a draft with a HUMAN generator and a human verifier still warns" || bad "LT-32d S9-N1" "$(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
HK="$TMP/hookbundle"; mkbundle "$HK"
OKF_BUNDLE_DIR="$HK" bash "$HERE/lessons-staleness-check.sh" </dev/null >/dev/null 2>&1
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/new-note.md"}}' "$HK" | OKF_BUNDLE_DIR="$HK" bash "$HERE/doc-reuse-guard.sh" >/dev/null 2>&1
[ ! -e "$HK/okf-base.yaml" ] && [ ! -e "$HK/.okfignore" ] && ok "LT-32e S17-N1 the other two hooks (lessons-staleness-check, doc-reuse-guard) never create okf-base.yaml or .okfignore" || bad "LT-32e S17-N1" "a hook wrote a file: $(ls -A "$HK" | tr '\n' ' ')"

# --- 0.9.1 B1: a YAML alias bomb must not expand in the vendored L1 validator ---
section "0.9.1 B1"
# 0.9.0 guarded the trust helper only. The validator stringified verified[].by through str(): on a 7-level bomb
# it took 4 s and 1094 MB; the 9-level bomb of the security review reached 2.5 GB. One bounded loader now sits
# behind every frontmatter parse; a bomb is an L1 ERROR on that note. The test is deterministic: it asserts the
# verdict (exit 1, the note named) and a memory ceiling, not just speed.
mkbomb() { # <file> <field: verified|generated|title>
  "$REALPY" - "$1" "$2" <<'PY'
import sys
f = sys.argv[2]
ref = "*a7"
lines = ["---", "type: Lesson", "x0: &a0 [x,x,x,x,x,x,x,x,x]"]
for i in range(1, 8):
    lines.append("x%d: &a%d [%s]" % (i, i, ",".join(["*a%d" % (i - 1)] * 9)))
lines += ["title: %s" % (ref if f == "title" else "T"), "description: D", "status: stable", "tags: [t]", 'stale_after: "2099-01-01"']
if f == "sources":
    lines += ["sources:", "  - resource: *a7", '    last_modified: "2026-01-01"']
lines.append("generated: {by: %s, at: \"2026-01-01\"}" % (ref if f == "generated" else "human:t"))
lines += ["verified:", "  - by: %s" % (ref if f == "verified" else "human:dana"), "    at: \"2026-02-01\"", "---", "", "body"]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
}
runbounded() { # <bundle> — run okf-check with an 8 s limit; prints "rc peakMB" or TIMEOUT
  "$REALPY" - "$CHECK" "$1" <<'PY'
import subprocess, sys, resource
try:
    r = subprocess.run([sys.argv[1], sys.argv[2]], timeout=5, capture_output=True, text=True)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
div = 1048576 if sys.platform == "darwin" else 1024
open(sys.argv[2] + ".out", "w").write(r.stdout + r.stderr)
print(r.returncode, int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / div))
PY
}
for fld in verified generated title; do
  BB="$TMP/bomb34_$fld"; mkbundle "$BB"; rm -f "$BB/c.md"; mkbomb "$BB/n.md" "$fld"
  res=$(runbounded "$BB"); rc=${res%% *}; mb=${res##* }
  { [ "$rc" = 1 ] && [ "$mb" -lt 400 ] && grep -q 'n.md' "$BB.out" && grep -qi 'alias' "$BB.out"; } \
    && ok "LT-34a an alias bomb in '$fld' is an L1 ERROR on that note (exit 1, named, peak ${mb} MB, no expansion)" \
    || bad "LT-34a alias bomb in $fld" "result='$res' $(grep -n -i 'alias\|n.md\|PASS\|FAIL' "$BB.out" 2>/dev/null | head -2 | tr '\n' ' ')"
done
MA="$TMP/modest_alias"; mkbundle "$MA"; rm -f "$MA/c.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: &t [a, b]\nrelated: *t\nalso: *t\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$MA/n.md"
"$CHECK" "$MA" >"$TMP/modest.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'L1 conformance *PASS' "$TMP/modest.txt"; } && ok "LT-34b a modest alias (one anchored list reused twice) still parses: exit 0, L1 PASS" || bad "LT-34b modest alias" "rc=$rc $(grep -n 'L1' "$TMP/modest.txt" | head -1)"

# L2: okflint is an external tool and expands the same bomb (935 MB in 5 s on the 7-level one; unbounded until
# OKF_L2_TIMEOUT, 120 s by default). L1 has already refused the note, so okf-check does not hand such a bundle
# to okflint: L2 says COULD NOT RUN and why, immediately.
if command -v okflint >/dev/null 2>&1; then
  BL="$TMP/bomb34_l2"; mkbundle "$BL"; rm -f "$BL/c.md"; mkbomb "$BL/n.md" verified
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$BL/okf-base.yaml"
  res=$(OKF_L2_TIMEOUT=60 runbounded "$BL"); rc=${res%% *}; mb=${res##* }
  { [ "$rc" = 1 ] && [ "$mb" -lt 400 ] && grep -Eq 'L2 profile +COULD NOT RUN.*alias bomb' "$BL.out"; } \
    && ok "LT-34c L2: okflint is NOT run on a bundle with an alias bomb: COULD NOT RUN, naming the reason (exit 1 from L1, peak ${mb} MB, within 8 s)" \
    || bad "LT-34c L2 alias bomb" "result='$res' $(grep -n 'L2 profile' "$BL.out" 2>/dev/null | head -1)"
else
  skip "LT-34c L2 alias bomb — okflint not installed"
fi

# Review round 1. Four ways the first fix still let a bomb through (found by running them):
# (d) a long scalar repeated by aliases: 302 items but 300 MB; (e) L3 derived staleness parsed frontmatter itself;
# (f) a bomb in the root index.md is only a WARNING in L1 and reached okflint; (g) the L2 guard must match the
# validator's message, not a note whose PATH contains the words.
BS="$TMP/bomb34_scalar"; mkbundle "$BS"; rm -f "$BS/c.md"
"$REALPY" - "$BS/n.md" <<'PY'
import sys
big = "x" * 100000
open(sys.argv[1], "w").write('---\ntype: Lesson\nbig: &b "%s"\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\nstale_after: "2099-01-01"\ngenerated: {by: human:t, at: "2026-01-01"}\nverified:\n  - by: [%s]\n    at: "2026-02-01"\n---\n\nbody\n' % (big, ",".join(["*b"] * 300)))
PY
res=$(runbounded "$BS"); rc=${res%% *}; mb=${res##* }
{ [ "$rc" = 1 ] && [ "$mb" -lt 400 ] && grep -qi 'alias' "$BS.out"; } \
  && ok "LT-34d one 100 KB scalar repeated by 300 aliases is refused (30 MB expanded from 302 items): exit 1, peak ${mb} MB" \
  || bad "LT-34d scalar amplification" "result='$res' $(grep -n -i 'alias\|n.md' "$BS.out" 2>/dev/null | head -1)"
BL3="$TMP/bomb34_l3"; mkbundle "$BL3"; rm -f "$BL3/c.md"; mkbomb "$BL3/n.md" sources
res=$(runbounded "$BL3"); rc=${res%% *}; mb=${res##* }
{ [ "$rc" = 1 ] && [ "$mb" -lt 400 ] && grep -q 'n.md' "$BL3.out"; } \
  && ok "LT-34e a bomb in sources[].resource does not expand in L3 derived staleness either (exit 1, peak ${mb} MB)" \
  || bad "LT-34e L3 derived staleness" "result='$res'"
if command -v okflint >/dev/null 2>&1; then
  BI="$TMP/bomb34_index"; mkbundle "$BI"
  "$REALPY" - "$BI/index.md" <<'PY'
import sys
lines = ["---", 'okf_version: "0.2"', "x0: &a0 [x,x,x,x,x,x,x,x,x]"]
for i in range(1, 8):
    lines.append("x%d: &a%d [%s]" % (i, i, ",".join(["*a%d" % (i - 1)] * 9)))
lines += ["owner: *a7", "---", "# B"]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$BI/okf-base.yaml"
  res=$(OKF_L2_TIMEOUT=60 runbounded "$BI"); mb=${res##* }
  { [ "$res" != TIMEOUT ] && [ "$mb" -lt 400 ] && grep -Eq 'L2 profile +COULD NOT RUN.*alias bomb' "$BI.out"; } \
    && ok "LT-34f a bomb in the root index.md (a WARNING in L1) keeps okflint from running (peak ${mb} MB)" \
    || bad "LT-34f root index.md bomb" "result='$res' $(grep -n 'L2 profile' "$BI.out" 2>/dev/null | head -1)"
  BP="$TMP/bomb34_path"; mkbundle "$BP"; mkdir -p "$BP/alias bomb notes"; printf -- '---\ntitle: no type here\n---\n\nbody\n' > "$BP/alias bomb notes/x.md"
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$BP/okf-base.yaml"
  "$CHECK" "$BP" >"$TMP/bomb34_path.txt" 2>&1
  ! grep -q 'rejected .* as YAML alias bombs' "$TMP/bomb34_path.txt" \
    && ok "LT-34g a note whose PATH contains 'alias bomb' (with an ordinary L1 error) does not stop okflint from running" \
    || bad "LT-34g path text forged the guard" "$(grep -n 'L2 profile' "$TMP/bomb34_path.txt" | head -1)"
else
  skip "LT-34f/g okflint guard cases — okflint not installed"
fi

# (h) Item count and character count are SEPARATE limits (1,000,000 items; 10,000,000 characters). Merging them into
# one number loosened the item limit tenfold and let a 5-level mapping bomb (12^5 leaves) through (exit 0, 5.5 s, 97 MB).
BM="$TMP/bomb34_map"; mkbundle "$BM"; rm -f "$BM/c.md"
"$REALPY" - "$BM/n.md" <<'PY'
import sys
lines = ["---", "type: Lesson", "m0: &m0 {a: 1, b: 2, c: 3}"]
for i in range(1, 6):
    lines.append("m%d: &m%d {%s}" % (i, i, ", ".join("k%d_%d: *m%d" % (i, j, i - 1) for j in range(12))))
lines += ["title: T", "description: D", "status: stable", "tags: [t]", 'stale_after: "2099-01-01"', 'generated: {by: human:t, at: "2026-01-01"}', "verified:", "  - by: *m5", '    at: "2026-02-01"', "---", "", "body"]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
res=$(runbounded "$BM"); rc=${res%% *}; mb=${res##* }
{ [ "$rc" = 1 ] && [ "$mb" -lt 400 ] && grep -qi 'alias' "$BM.out"; } \
  && ok "LT-34h a 5-level mapping bomb (12^5 leaves) is refused by the ITEM limit: exit 1, peak ${mb} MB" \
  || bad "LT-34h mapping bomb" "result='$res' $(grep -n 'n.md' "$BM.out" 2>/dev/null | head -1 | cut -c1-120)"

# (i) One huge scalar. A 2,000,000-digit integer is a single scalar well under the character limit, but int() on it is
# quadratic on CPython < 3.11 (2M digits: 47 s, exit 0, found by the attacker review). A scalar above 100,000 characters
# is refused up front, as the other bounded cases are.
BS="$TMP/bomb34_scalar"; mkbundle "$BS"; rm -f "$BS/c.md"
"$REALPY" - "$BS/n.md" <<'PY'
import sys
open(sys.argv[1], "w").write("---\ntype: Lesson\nn: " + "9" * 150000 + "\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\nstale_after: \"2099-01-01\"\n---\n\nbody\n")
PY
res=$(runbounded "$BS"); rc=${res%% *}
{ [ "$rc" = 1 ] && grep -qi 'single scalar' "$BS.out"; } \
  && ok "LT-34i a single 150,000-character scalar is refused up front: exit 1" \
  || bad "LT-34i huge scalar" "result='$res' $(grep -n 'n.md' "$BS.out" 2>/dev/null | head -1 | cut -c1-120)"

# --- LT-43 (0.9.2 F2): the Trust layer reads look-alike actors and string-valued verified -------------------------
section "LT-43 (0.9.2 F2)"
# Found by the 0.9.1 final review (each exited 0 under --strict-trust): a Cyrillic "а" in `humаn:`, `verified:` written
# as a plain string, and a bare unknown generated.by token. c4run/vent/mktrust are defined with LT-26.
CYR=$(printf 'hum\xd0\xb0n')     # "humаn": the third letter is CYRILLIC SMALL LETTER A
c4run lk stable human:t 2026-01-01 "verified:
$(vent "${CYR}:dana" 2026-02-01)"
"$CHECK" "$C4DIR" --strict-trust >"$C4OUT.s" 2>&1; src=$?
{ [ "$C4RC" -eq 0 ] && grep -q 'near-miss of `human:`' "$C4OUT" && [ "$src" -eq 1 ]; } \
  && ok "LT-43a a mixed-script look-alike of human: (Cyrillic a) is a near-miss: warning, and exit 1 under --strict-trust" \
  || bad "LT-43a look-alike" "rc=$C4RC strict=$src $(grep -n 'near-miss\|Trust' "$C4OUT" | head -2 | tr '\n' ' ')"
FW=$(printf '\xef\xbd\x88\xef\xbd\x95\xef\xbd\x8d\xef\xbd\x81\xef\xbd\x8e')   # fullwidth "human"
c4run fw stable human:t 2026-01-01 "verified:
$(vent "${FW}:dana" 2026-02-01)"
grep -q 'near-miss of `human:`' "$C4OUT" && ok "LT-43b a fullwidth spelling of human: is a near-miss" || bad "LT-43b fullwidth" "$(grep -n 'near-miss\|Trust' "$C4OUT" | head -2 | tr '\n' ' ')"
ZH=$(printf '\xe5\x9b\xa2\xe9\x98\x9f')   # a non-Latin prefix is not a look-alike of anything
c4run zh stable human:t 2026-01-01 "verified:
$(vent "${ZH}:ga4" 2026-02-01)"
! grep -q 'near-miss' "$C4OUT" && ok "LT-43c a wholly non-Latin actor prefix is NOT a near-miss (no false warning for CJK bundles)" || bad "LT-43c CJK prefix" "$(grep -n 'near-miss' "$C4OUT" | head -1)"
c4run vs draft agent/1 2026-01-01 "verified: human:dana"
"$CHECK" "$C4DIR" --strict-trust >"$C4OUT.s" 2>&1; src=$?
{ grep -Eq '^ +n\.md: verified\[0\]\.by .*draft' "$C4OUT" && [ "$src" -eq 1 ]; } \
  && ok "LT-43d verified written as a plain string is still read: a draft note gets the C4 warning, exit 1 under --strict-trust" \
  || bad "LT-43d string verified" "strict=$src $(grep -n 'Trust\|n.md' "$C4OUT" | head -2 | tr '\n' ' ')"
c4run bt stable claudebot 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
grep -q '0 warning(s), 1 advisory' "$C4OUT" && ok "LT-43e a bare generated.by token (no slash, no colon) counts as an agent: advisory" || bad "LT-43e bare token" "$(grep -n 'Trust' "$C4OUT" | head -1)"
c4run tm stable team:ga4 2026-01-01 "verified:
$(vent human:dana 2026-02-01)"
c4quiet "LT-43f a team:<id> generator stays a non-agent (no advisory): the open prefix family is unchanged"

# --- LT-44 (0.9.2 F3): L1/L3 robustness found by the 0.9.1 final review --------------------------------------------
section "LT-44 (0.9.2 F3)"
# note44 <bundle> <extra-frontmatter-lines...>: one-note bundle whose note has a full, valid header plus the extra lines
note44() {
  local d="$TMP/n44_$1"; mkbundle "$d"; rm -f "$d/c.md"; shift
  { printf -- '---\ntype: Lesson\ndescription: D\nstatus: stable\ntags: [t]\n'; printf '%s\n' "$@"; printf -- '---\n\nbody\n'; } > "$d/n.md"
  N44DIR="$d"; N44OUT="$d.txt"; "$CHECK" "$d" >"$N44OUT" 2>&1; N44RC=$?
}
# (a) deep nesting is an ordinary L1 error on that note, not a crash that blanks L1 and Trust for the whole bundle
note44 deep "title: T" "stale_after: \"2099-01-01\"" "d: $("$REALPY" -c 'print("["*3000 + "]"*3000)')"
{ [ "$N44RC" -eq 1 ] && grep -q 'n.md: .*nested too deeply' "$N44OUT" && ! grep -q 'COULD NOT RUN' "$N44OUT"; } \
  && ok "LT-44a a 3000-deep nested list is an L1 error on that note (exit 1), and no layer says COULD NOT RUN" \
  || bad "LT-44a deep nesting" "rc=$N44RC $(grep -n 'n.md\|COULD NOT' "$N44OUT" | head -2 | cut -c1-140 | tr '\n' ' ')"
# (b) a duplicate key is a warning (YAML last-wins would hide the first value)
note44 dup "title: A" "title: B" "stale_after: \"2099-01-01\""
{ [ "$N44RC" -eq 0 ] && grep -q 'n.md: .*duplicate key `title`' "$N44OUT"; } \
  && ok "LT-44b a duplicate frontmatter key is a warning that names the key (exit 0)" \
  || bad "LT-44b duplicate key" "rc=$N44RC $(grep -n 'n.md\|warning' "$N44OUT" | head -2 | cut -c1-140 | tr '\n' ' ')"
note44 nodup "title: A" "stale_after: \"2099-01-01\""
! grep -q 'duplicate key' "$N44OUT" && ok "LT-44c no duplicate key, no duplicate-key warning" || bad "LT-44c clean" "$(grep -n 'duplicate' "$N44OUT" | head -1)"
# (c) an empty stale_after is reported by L3, not skipped as if the note had no horizon at all
note44 nullsa "title: T" "stale_after:"
"$CHECK" "$N44DIR" --fail-stale >"$N44OUT" 2>&1; src=$?
{ [ "$src" -eq 4 ] && grep -q 'malformed n.md (stale_after' "$N44OUT"; } \
  && ok "LT-44d an empty stale_after is reported by L3 as malformed (exit 4 under --fail-stale)" \
  || bad "LT-44d empty stale_after" "rc=$src $(grep -n 'L3\|n.md' "$N44OUT" | head -2 | cut -c1-140 | tr '\n' ' ')"
# (d) generated.at in the future is a warning
note44 fut "title: T" "stale_after: \"2099-01-01\"" "generated:" "  by: human:t" "  at: \"2099-06-01\""
"$CHECK" "$N44DIR" >"$N44OUT" 2>&1; src=$?
grep -q 'n.md: .*generated.at.*in the future' "$N44OUT" && ok "LT-44e generated.at in the future is a warning" || bad "LT-44e future generated.at" "rc=$src $(grep -n 'n.md\|generated' "$N44OUT" | head -3 | cut -c1-140 | tr '\n' ' ')"

# --- LT-45 (0.9.2 F4): --json carries the findings, is valid for any path, and the verdict counts every skipped layer ---
section "LT-45 (0.9.2 F4)"
# jq44 <json-file> <python-expr over d>: print the expression's value (d is the parsed document)
jq44() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }
J44="$TMP/j44"; mkbundle "$J44"
"$CHECK" "$J44" --json >"$J44.json" 2>&1
[ "$(jq44 "$J44.json" 'all(isinstance(d.get(k), list) for k in ("errors","stale","l2_findings","skipped"))')" = True ] \
  && ok "LT-45a --json on a clean bundle carries errors, stale, l2_findings and skipped as lists" \
  || bad "LT-45a arrays present" "$(jq44 "$J44.json" 'sorted(d)' | cut -c1-200)"
[ "$(jq44 "$J44.json" 'len(d["skipped"])')" = 1 ] || [ "$(jq44 "$J44.json" 'len(d["skipped"])')" = 2 ] \
  && ok "LT-45b skipped[] lists the skipped layers (no okf-base.yaml in the fixture)" \
  || bad "LT-45b skipped" "$(jq44 "$J44.json" 'd["skipped"]')"
nsk=$(grep -c 'SKIPPED' <("$CHECK" "$J44" 2>&1)); verd=$("$CHECK" "$J44" 2>&1 | sed -n 's/.* \([0-9][0-9]*\) skipped layer.*/\1/p')
[ "$nsk" = "$verd" ] && ok "LT-45c the verdict line counts every SKIPPED layer ($nsk = $verd)" || bad "LT-45c verdict count" "SKIPPED lines=$nsk verdict says '$verd'"
J44E="$TMP/j44e"; mkbundle "$J44E"; printf -- '---\ntitle: no type\n---\nbody\n' > "$J44E/bad.md"
"$CHECK" "$J44E" --json >"$J44E.json" 2>&1
[ "$(jq44 "$J44E.json" 'any("bad.md" in e for e in d["errors"])')" = True ] \
  && ok "LT-45d errors[] names the failing note" || bad "LT-45d errors" "$(jq44 "$J44E.json" 'd.get("errors")' | cut -c1-200)"
J44S="$TMP/j44s"; mkbundle "$J44S"; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nbody\n' > "$J44S/old.md"
"$CHECK" "$J44S" --json >"$J44S.json" 2>&1
[ "$(jq44 "$J44S.json" 'any("old.md" in e for e in d["stale"])')" = True ] \
  && ok "LT-45e stale[] names the expired note" || bad "LT-45e stale" "$(jq44 "$J44S.json" 'd.get("stale")' | cut -c1-200)"
J44Q="$TMP/j44 \"q\" dir"; mkbundle "$J44Q"
"$CHECK" "$J44Q" --json >"$TMP/j44q.json" 2>&1
[ "$(jq44 "$TMP/j44q.json" 'd["bundle"].endswith("dir")')" = True ] \
  && ok "LT-45f --json is valid JSON when the bundle path contains double quotes" || bad "LT-45f quoted path" "$(head -c 200 "$TMP/j44q.json")"
J44I="$TMP/j44i"; mkbundle "$J44I"; rm -f "$J44I/c.md"; printf 'c.md\n' > "$J44I/.okfignore"; printf -- '---\ntype: Lesson\n---\n' > "$J44I/x.md"; printf 'x.md\n' >> "$J44I/.okfignore"
"$CHECK" "$J44I" --json >"$J44I.json" 2>&1
[ "$(jq44 "$J44I.json" 'all(k in d for k in ("errors","stale","l2_findings","skipped","warnings","trust_findings","l2_profile"))')" = True ] \
  && ok "LT-45g the ignore-everything exit (2) emits the same key set as a normal run" || bad "LT-45g key set" "$(jq44 "$J44I.json" 'sorted(d)' | cut -c1-200)"
if command -v okflint >/dev/null 2>&1; then
  J44L="$TMP/j44l"; mkbundle "$J44L"; sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$J44L/okf-base.yaml"
  printf -- '---\ntype: NotAType\n---\nbody\n' > "$J44L/odd.md"
  "$CHECK" "$J44L" --json >"$J44L.json" 2>&1; l2rc=$?
  { [ "$l2rc" -ne 0 ] && [ "$(jq44 "$J44L.json" 'len(d["l2_findings"]) > 0')" = True ]; } \
    && ok "LT-45h l2_findings[] carries the house-rule errors (exit $l2rc)" || bad "LT-45h l2_findings" "rc=$l2rc $(jq44 "$J44L.json" 'd.get("l2_findings")' | cut -c1-200)"
else
  skip "LT-45h l2_findings — okflint not installed"
fi

# --- LT-46 (0.9.2 F9, okf-knowledge-gate#1): okflint reports L001 for a path-qualified wikilink whose target exists ------
section "LT-46 (0.9.2 F9, okf-knowledge-gate#1)"
# okflint 0.5.0 resolves [[x]] by file name only, so [[sub/b]] is "broken" even with sub/b.md present. okf-check drops an
# L001 whose target exists in the bundle (bundle-root-relative or relative to the note), and says how many it dropped.
if command -v okflint >/dev/null 2>&1; then
  wl9() { # <name> <hygiene level> — bundle with a.md linking [[sub/b]] [[b]] [[sub/nope]] and sub/b.md present
    W9="$TMP/wl9_$1"; mkbundle "$W9"; rm -f "$W9/c.md"; mkdir -p "$W9/sub"
    sed -e 's/^  name: CHANGE ME/  name: Probe/' -e "s/^  broken_links: .*/  broken_links: $2/" "$HERE/../config/okf-base.yaml.template" > "$W9/okf-base.yaml"
    printf -- '---\ntype: Lesson\ntitle: A\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nsee [[sub/b]] and [[b]]%s\n' "$3" > "$W9/a.md"
    printf -- '---\ntype: Lesson\ntitle: B\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$W9/sub/b.md"
    "$CHECK" "$W9" >"$W9.txt" 2>&1; W9RC=$?
  }
  wl9 warn warn " and [[sub/nope]]"
  { [ "$W9RC" -eq 0 ] && grep -Eq 'by rule:.*L001 x1([^0-9]|$)' "$W9.txt" && grep -q '1 path wikilink(s) resolved by okf-check' "$W9.txt"; } \
    && ok "LT-46a [[sub/b]] (target exists) is not reported; [[sub/nope]] still is; the dropped count is printed" \
    || bad "LT-46a path wikilink" "rc=$W9RC $(grep -n 'L2 profile\|wikilink' "$W9.txt" | head -3 | cut -c1-140 | tr '\n' ' ')"
  wl9 err error ""
  { [ "$W9RC" -eq 0 ] && grep -Eq 'L2 profile +PASS' "$W9.txt"; } \
    && ok "LT-46b with broken_links: error, a bundle whose only L001 is a resolvable path wikilink passes (exit 0)" \
    || bad "LT-46b error level" "rc=$W9RC $(grep -n 'L2 profile' "$W9.txt" | head -2 | cut -c1-160 | tr '\n' ' ')"
  wl9 err2 error " and [[sub/nope]]"
  { [ "$W9RC" -eq 3 ] && grep -q 'sub/nope' "$W9.txt"; } \
    && ok "LT-46c ... and a truly broken wikilink still fails L2 (exit 3)" \
    || bad "LT-46c genuine broken link" "rc=$W9RC $(grep -n 'L2 profile\|nope' "$W9.txt" | head -2 | cut -c1-160 | tr '\n' ' ')"
else
  skip "LT-46a-c path wikilinks — okflint not installed"
fi

# --- LT-48 (0.9.2, cross-vendor review): the staleness hook and .okfignore must not lose notes silently ------------
section "LT-48 (0.9.2, cross-vendor review)"
# (a) A directory whose NAME contains a newline made the session hook print nothing for the WHOLE bundle: the file list was
# joined with `tr '\n' '\0'`, so the newline inside a path split it in two and awk aborted before it reported anything.
HK48="$HERE/lessons-staleness-check.sh"
N48="$TMP/lt48a"; mkdir -p "$N48" "$N48/odd
name"
printf -- '---\ntype: Lesson\nstatus: stable\nstale_after: "2000-01-01"\n---\nb\n' > "$N48/old.md"
printf -- '---\ntype: Lesson\nstatus: stable\nstale_after: "2099-01-01"\n---\nb\n' > "$N48/odd
name/fine.md"
out=$(OKF_TODAY=2026-10-14 OKF_BUNDLE_DIR="$N48" bash "$HK48" 2>&1)
printf '%s' "$out" | grep -q 'old.md (stale_after' \
  && ok "LT-48a the staleness hook still reports an expired lesson when a directory name contains a newline" \
  || bad "LT-48a newline-named directory" "hook printed: $(printf '%s' "$out" | head -c 120)"
# (b) With an active .okfignore, a note reachable only through a SYMLINKED DIRECTORY was checked by no layer: the ignore
# mirror and keep-list walked with find without -L, so the run said "0 checked" about a bundle whose note it reports
# without the ignore file (cross-vendor review, finding 3). Since (S8-N1) a folder link that points outside the
# bundle is entered by NO layer, the ignore walker included: the note is not a bundle note in either run, both runs
# name the link, and with archive/ ignored nothing is left, which the run says instead of passing.
S48="$TMP/lt48b"; mkbundle "$S48"; rm -f "$S48/c.md"; mkdir -p "$S48/archive" "$TMP/lt48b_outside/sub"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nb\n' > "$TMP/lt48b_outside/sub/old.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nb\n' > "$S48/archive/a.md"
ln -s ../lt48b_outside "$S48/link"
"$CHECK" "$S48" >"$S48.base.txt" 2>&1
printf 'archive/\n' > "$S48/.okfignore"
"$CHECK" "$S48" >"$S48.ign.txt" 2>&1
{ ! grep -q 'link/sub/old.md' "$S48.base.txt" && ! grep -q 'link/sub/old.md' "$S48.ign.txt" \
  && grep -qxE ' +link' "$S48.base.txt" && grep -qxE ' +link' "$S48.ign.txt" && grep -q 'nothing was checked' "$S48.ign.txt"; } \
  && ok "LT-48b with or without an active .okfignore, a note behind an outside folder link is not a bundle note, the link is named, and 'nothing was checked' is said" \
  || bad "LT-48b ignore + symlinked directory" "$(grep -n 'ignore \|IGNORE\|old.md' "$S48.ign.txt" | head -3 | cut -c1-120 | tr '\n' ' ')"

# --- LT-49 (0.9.2, okf-knowledge-gate#2 and #3): --json carries the L2 counts; L3 keeps "unknown status" apart from "expired" --
section "LT-49 (0.9.2, okf-knowledge-gate#2 and #3)"
# (a) the text says "138 warning(s), by rule: S202 x136, L002 x2"; --json had only l2_profile "ran".
if command -v okflint >/dev/null 2>&1; then
  wl9 cnt warn " and [[sub/nope]]"
  "$CHECK" "$W9" --json >"$W9.json" 2>&1
  txtn=$(sed -n 's/.*L2 profile .*PASS .*0 errors, \([0-9][0-9]*\) warning.*/\1/p' "$W9.txt")
  { [ -n "$txtn" ] && [ "$(jq44 "$W9.json" 'd.get("l2_warnings")')" = "$txtn" ] && [ "$(jq44 "$W9.json" 'sum(d.get("l2_by_rule",{}).values())')" = "$txtn" ]; } \
    && ok "LT-49a --json carries l2_warnings and l2_by_rule, equal to the text's count ($txtn) and its per-rule breakdown" \
    || bad "LT-49a l2 counts in --json" "text=$txtn json=$(jq44 "$W9.json" '(d.get("l2_warnings"), d.get("l2_by_rule"))' | cut -c1-160)"
else
  skip "LT-49a l2 counts in --json — okflint not installed"
fi
J49="$TMP/j49"; mkbundle "$J49"
"$CHECK" "$J49" --json >"$J49.json" 2>&1
{ [ "$(jq44 "$J49.json" '"l2_warnings" in d and "l2_by_rule" in d and "lifecycle" in d')" = True ] && [ "$(jq44 "$J49.json" 'd["l2_warnings"] is None')" = True ]; } \
  && ok "LT-49b when L2 did not run, l2_warnings is null (not 0) and the keys are still present" \
  || bad "LT-49b l2 keys when skipped" "$(jq44 "$J49.json" '(d.get("l2_warnings"), d.get("l2_by_rule"), d.get("lifecycle"))' | cut -c1-160)"
# (b) 80 notes with a status outside the lifecycle used to read as "84 need attention" beside 4 expired notes
# and made --fail-stale exit 4 on a bundle in which nothing had expired.
L49="$TMP/l49"; mkbundle "$L49"; rm -f "$L49/c.md"
for i in 1 2 3; do printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: accepted\nstale_after: "2099-01-01"\n---\nb\n' > "$L49/s$i.md"; done
"$CHECK" "$L49" --fail-stale --json >"$L49.json" 2>&1; rcl=$?
"$CHECK" "$L49" >"$L49.txt" 2>&1
{ [ "$rcl" -eq 0 ] && grep -Eq 'L3 staleness +PASS +nothing expired' "$L49.txt" && grep -Eq 'L3 lifecycle +3 concept\(s\)' "$L49.txt" && [ "$(jq44 "$L49.json" 'len(d["stale"])')" = 0 ] && [ "$(jq44 "$L49.json" 'len(d["lifecycle"])')" = 3 ]; } \
  && ok "LT-49c three notes with an unknown status and none expired: --fail-stale exits 0, L3 says nothing expired, the status findings sit on their own L3 lifecycle line and in lifecycle[]" \
  || bad "LT-49c unknown status vs expired" "rc=$rcl $(grep -n 'L3' "$L49.txt" | head -3 | cut -c1-130 | tr '\n' ' ')"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "2000-01-01"\n---\nb\n' > "$L49/old.md"
"$CHECK" "$L49" --fail-stale >"$L49.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 4 ] && grep -Eq 'L3 staleness +1 concept\(s\) need attention' "$L49.txt" && grep -Eq 'L3 lifecycle +3 concept\(s\)' "$L49.txt"; } \
  && ok "LT-49d with one expired note beside three unknown-status notes the counts are separate (1 and 3) and --fail-stale exits 4" \
  || bad "LT-49d separate counts" "rc=$rcl $(grep -n 'L3' "$L49.txt" | head -3 | cut -c1-130 | tr '\n' ' ')"

# --- LT-50 (0.9.2, okf-knowledge-gate#7): the doc-reuse "closest notes" hint says when it is off ----------------------------
section "LT-50 (0.9.2, okf-knowledge-gate#7)"
# The hint needs a search binary (`okf`) that okf-check never installs; without it the hint was off with no word anywhere.
O50="$TMP/o50"; mkdir -p "$O50/empty"; printf '#!/bin/sh\nexit 0\n' > "$O50/okf"; chmod +x "$O50/okf"
out=$(env OKF_SEARCH_BIN= PATH="/usr/bin:/bin" "$CHECK" --doctor 2>&1)
printf '%s' "$out" | grep -Eq 'okf search +absent' && ok "LT-50a --doctor reports the missing search binary and what it switches off" || bad "LT-50a doctor absent" "$(printf '%s' "$out" | grep -n 'okf search' | head -1)"
out=$(env OKF_SEARCH_BIN="$O50/okf" "$CHECK" --doctor 2>&1)
printf '%s' "$out" | grep -Eq 'okf search +present' && ok "LT-50b --doctor names the search binary when it is configured" || bad "LT-50b doctor present" "$(printf '%s' "$out" | grep -n 'okf search' | head -1)"

# --- LT-51 (0.9.4, cases S4-*): okf-check's own options live in one okf_check: block of okf-base.yaml -----------
section "LT-51 (0.9.4, cases S4-*)"
L51="$TMP/l51"; mkbundle "$L51"
sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$L51/okf-base.yaml"
printf 'okf_check:\n  verify:\n    repos:\n      - path: .\n  colour: red\n' >> "$L51/okf-base.yaml"
"$CHECK" "$L51" >"$L51.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 2 ] && grep -q 'okf_check\.colour' "$L51.txt"; } \
  && ok "LT-51a S4-N1 an unknown key inside okf_check exits 2 and names the key" \
  || bad "LT-51a S4-N1 unknown okf_check key" "rc=$rcl $(grep -n 'okf_check\|Config' "$L51.txt" | head -2 | tr '\n' ' ')"
# S4-H1 pins okflint's behaviour: it ignores the block today, so it is not stripped. An okflint that starts to count it
# turns this RED, and then the block must be stripped before okflint runs.
mkbundle "$L51/a"; mkbundle "$L51/b"
sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$L51/a/okf-base.yaml"
cp "$L51/a/okf-base.yaml" "$L51/b/okf-base.yaml"; printf 'okf_check:\n  verify:\n    repos:\n      - path: .\n' >> "$L51/b/okf-base.yaml"
if command -v okflint >/dev/null 2>&1; then
  "$CHECK" "$L51/a" --json >"$L51/a.json" 2>&1; rca=$?
  "$CHECK" "$L51/b" --json >"$L51/b.json" 2>&1; rcb=$?
  wa=$(jq44 "$L51/a.json" '(d["l2_profile"], d["l2_warnings"], sorted(d["l2_by_rule"].items()))')
  wb=$(jq44 "$L51/b.json" '(d["l2_profile"], d["l2_warnings"], sorted(d["l2_by_rule"].items()))')
  { [ "$rca" -eq "$rcb" ] && [ "$wa" = "$wb" ] && case "$wa" in "('ran', "[0-9]*) true;; *) false;; esac; } \
    && ok "LT-51b S4-H1 a valid okf_check block leaves the L2 advisory count unchanged ($wa)" \
    || bad "LT-51b S4-H1 L2 count with the block" "without: rc=$rca $wa; with: rc=$rcb $wb"
else
  skip "LT-51b S4-H1 L2 count with an okf_check block — okflint absent" "uv tool install okflint"
fi
# S4-E1: no block = the 0.9.2 behaviour, byte for byte. The baseline is this very build with the okf_check step deleted (a copy of the
# plugin with the run_config call removed), so it needs no git history. Text and --json, same bundle path, same exit code.
B51="$TMP/l51base"; mkdir -p "$B51"; cp -R "$HERE/.." "$B51/plugin" 2>/dev/null
if grep -q '^run_config "\$BUNDLE"' "$B51/plugin/scripts/okf-check"; then
  sed -i.bak '/^run_config "\$BUNDLE"/d' "$B51/plugin/scripts/okf-check"
  "$CHECK" "$L51/a" >"$L51/new.txt" 2>&1; rcn=$?;      "$B51/plugin/scripts/okf-check" "$L51/a" >"$L51/old.txt" 2>&1; rco=$?
  "$CHECK" "$L51/a" --json >"$L51/new.json" 2>&1; rjn=$?; "$B51/plugin/scripts/okf-check" "$L51/a" --json >"$L51/old.json" 2>&1; rjo=$?
  { [ "$rcn" -eq 0 ] && [ "$rcn" -eq "$rco" ] && [ "$rjn" -eq "$rjo" ] && cmp -s "$L51/new.txt" "$L51/old.txt" && cmp -s "$L51/new.json" "$L51/old.json"; } \
    && ok "LT-51c S4-E1 with no okf_check block the text and --json output and the exit code are byte-identical to the build without the okf_check step" \
    || bad "LT-51c S4-E1 no block" "rc new/old=$rcn/$rco json $rjn/$rjo; $(diff "$L51/new.txt" "$L51/old.txt" | head -3 | tr '\n' ' ')"
else
  bad "LT-51c S4-E1 no block" "the run_config call line was not found in okf-check, so there is no baseline to compare with"
fi

# LT-52 (0.9.4 review round 1): okf-check and okf-verify read ONE schema for the okf_check block, and this table proves they agree.
# A rule re-implemented in a second tool ships with a parity test: every row goes to BOTH tools. A valid block: both exit 0. An invalid one:
# both exit 2, and okf-check shows the message okf-verify prints (the validator is okf-verify's --check-config, so the wording cannot drift).
VERIFY="$HERE/okf-verify"
P52="$TMP/p52"; mkdir -p "$P52"
par() { # <label> <ok|err> <printf-format of the lines appended to okf-base.yaml>
  local d="$P52/$1"; mkbundle "$d"
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$d/okf-base.yaml"
  printf "$3" >> "$d/okf-base.yaml"
  "$CHECK" "$d" >"$d.chk" 2>&1; local c=$?
  "$REALPY" "$VERIFY" "$d" >"$d.ver" 2>&1; local v=$?
  local want=0; [ "$2" = err ] && want=2
  if [ "$c" -ne "$want" ] || [ "$v" -ne "$want" ]; then
    bad "LT-52 parity: $1" "want both exit $want; okf-check=$c okf-verify=$v: $(grep -h 'Config\|error:' "$d.chk" "$d.ver" | head -2 | tr '\n' ' ')"; return
  fi
  if [ "$2" = err ]; then
    local msg; msg=$(sed -n 's/^error: .*okf-base\.yaml //p' "$d.ver" | head -1)
    if [ -n "$msg" ] && grep -qF -- "$msg" "$d.chk"; then ok "LT-52 parity: $1 -> both exit 2, same message"; else bad "LT-52 parity: $1" "okf-check did not show okf-verify's message '$msg': $(grep -h 'Config' "$d.chk" | head -1)"; fi
  else
    ok "LT-52 parity: $1 -> both exit 0"
  fi
}
par noblock       ok  ''
par empty-map     ok  'okf_check: {}\n'
par path-dot      ok  'okf_check:\n  verify:\n    repos:\n      - path: .\n'
par two-paths     ok  'okf_check:\n  verify:\n    repos:\n      - path: .\n      - path: ../x\n'
par readme-flow   err 'okf_check:\n  verify:\n    repos: [.]\n'
par repos-string  err 'okf_check:\n  verify:\n    repos: "x"\n'
par verify-int    err 'okf_check:\n  verify: 5\n'
par block-list    err 'okf_check: [a]\n'
par block-scalar  err 'okf_check: foo\n'
par block-null    err 'okf_check:\n'
par verify-null   err 'okf_check:\n  verify:\n'
par path-int      err 'okf_check:\n  verify:\n    repos:\n      - path: 3\n'
par path-empty    err 'okf_check:\n  verify:\n    repos:\n      - path: ""\n'
par typo-repo     err 'okf_check:\n  verify:\n    repo:\n      - path: .\n'
par entry-extra   err 'okf_check:\n  verify:\n    repos:\n      - path: .\n        nmae: x\n'
par top-unknown   err 'okf_check:\n  colour: red\n'
# edit_hook is a boolean leaf: a string or a number is refused by both tools, and so is an unquoted yes (B-7: YAML
# 1.1 reads it as true, other YAML readers as a word)
par edit-hook-true   ok  'okf_check:\n  edit_hook: true\n'
par edit-hook-false  ok  'okf_check:\n  edit_hook: false\n'
par edit-hook-yes    err 'okf_check:\n  edit_hook: yes\n'
par edit-hook-string err 'okf_check:\n  edit_hook: "on"\n'
par edit-hook-int    err 'okf_check:\n  edit_hook: 1\n'
par bad-utf8      err 'okf_check:\n  verify:\n    repos:\n      - path: \377\n'
par bad-yaml      err 'okf_check: [\n'
# deprecated_requires is an enum node (one allowed value today)
par dep-ok        ok  'okf_check:\n  deprecated_requires: superseded_by\n'
par dep-typo      err 'okf_check:\n  deprecated_requires: superseded-by\n'
par dep-list      err 'okf_check:\n  deprecated_requires: [superseded_by]\n'
par dep-null      err 'okf_check:\n  deprecated_requires:\n'
# require_owner is a boolean node; owners is a {map: string} node (free glob keys) that requires require_owner: true
par own-ok        ok  'okf_check:\n  require_owner: true\n  owners:\n    "**": team:a\n'
par own-off       ok  'okf_check:\n  require_owner: false\n'
par own-str       err 'okf_check:\n  require_owner: yes-please\n'
par own-list      err 'okf_check:\n  require_owner: true\n  owners: [team:a]\n'
par own-int       err 'okf_check:\n  require_owner: true\n  owners:\n    "decisions/**": 3\n'
par own-empty     err 'okf_check:\n  require_owner: true\n  owners:\n    "decisions/**": ""\n'
par own-norequire err 'okf_check:\n  owners:\n    "decisions/**": team:a\n'
par own-reqfalse  err 'okf_check:\n  require_owner: false\n  owners:\n    "decisions/**": team:a\n'
par own-negation  err 'okf_check:\n  require_owner: true\n  owners:\n    "!drafts/**": team:a\n'
# duplicates is a keys node of two {type: number} nodes
par dup-ok        ok  'okf_check:\n  duplicates:\n    threshold: 0.6\n    time_limit: 30\n'
par dup-high      err 'okf_check:\n  duplicates:\n    threshold: 1.5\n'
par dup-str       err 'okf_check:\n  duplicates:\n    time_limit: soon\n'
par dup-zero      err 'okf_check:\n  duplicates:\n    time_limit: 0\n'
par dup-unknown   err 'okf_check:\n  duplicates:\n    treshold: 0.6\n'
par dup-body      ok  'okf_check:\n  duplicates:\n    body_threshold: 0.3\n'
par dup-body-06   ok  'okf_check:\n  duplicates:\n    body_threshold: 0.6\n'
par dup-body-high err 'okf_check:\n  duplicates:\n    body_threshold: 2\n'
# an alias bomb in okf-base.yaml: both tools go through the bounded loader (LT-35a forbids a bare yaml.safe_load), so it is a YAML error, not a hang
BOMB52=$("$REALPY" -c 'print("x0: &a0 [x,x,x,x,x,x,x,x,x]"); [print("x%d: &a%d [%s]" % (i, i, ",".join(["*a%d" % (i - 1)] * 9))) for i in range(1, 8)]')
par alias-bomb    err "okf_check: {}\n$BOMB52\n"
grep -qi 'alias' "$P52/alias-bomb.ver" && ok "LT-52 parity: the alias bomb is named as one" || bad "LT-52 parity: alias bomb message" "$(head -2 "$P52/alias-bomb.ver" | cut -c1-200)"

# --- LT-55 (0.9.6, cases S3-*): --selftest has a probe for L0, L2 index and L3 derived staleness ----------------
section "LT-55 (0.9.6, cases S3-*)"
# A probe is proven by its layer going dead: each case cripples one layer in a plugin copy, and --selftest must exit 5.
# lt55_dead <name> <sed expression> [script, default okf-check] — a plugin copy whose script carries the expression; fails the test if it did
# not change the file (a cripple that misses its target would make the RED meaningless).
lt55_dead() {
  local d="$TMP/lt55-$1" f="${3:-okf-check}"; rm -rf "$d"; mkdir -p "$d"; cp -R "$HERE/.." "$d/plugin" 2>/dev/null
  sed -i.orig "$2" "$d/plugin/scripts/$f"
  cmp -s "$d/plugin/scripts/$f" "$d/plugin/scripts/$f.orig" && { echo "cripple $1 changed nothing"; return 1; }
  "$d/plugin/scripts/okf-check" --selftest >"$d.txt" 2>&1; echo "rc=$?"
}
"$CHECK" --selftest >"$TMP/lt55.txt" 2>&1; rcl=$?
L55_DER=$(grep -A1 '^  L3 (derived staleness):' "$TMP/lt55.txt" | grep -c 'FIRED  *recorded source changed')
{ [ "$rcl" -eq 0 ] && [ "$L55_DER" -eq 1 ]; } \
  && ok "LT-55a S3-H1 --selftest has an L3 derived-staleness probe that fires on a healthy install" \
  || bad "LT-55a S3-H1 L3 derived probe" "rc=$rcl $(grep -n 'L3' "$TMP/lt55.txt" | tr '\n' ' ')"
r=$(lt55_dead derived 's/if mtime > rec:/if False:/')
{ [ "$r" = "rc=5" ] && grep -A1 '^  L3 (derived staleness):' "$TMP/lt55-derived.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-55b S3-N1 with L3 derived staleness disabled, its probe reports NOT FIRED and --selftest exits 5" \
  || bad "LT-55b S3-N1 dead L3 derived" "$r $(grep -n 'L3\|SELFTEST' "$TMP/lt55-derived.txt" | tr '\n' ' ')"
L55_IDX=$(grep -A1 '^  L2 (index):' "$TMP/lt55.txt" | grep -c 'FIRED  *index.md count wrong')
{ [ "$rcl" -eq 0 ] && [ "$L55_IDX" -eq 1 ]; } \
  && ok "LT-55c S3-H1 --selftest has an L2 index probe that fires on a healthy install" \
  || bad "LT-55c S3-H1 L2 index probe" "rc=$rcl $(grep -n 'L2' "$TMP/lt55.txt" | tr '\n' ' ')"
r=$(lt55_dead index 's/(good if n == actual else bad)/good/')
{ [ "$r" = "rc=5" ] && grep -A1 '^  L2 (index):' "$TMP/lt55-index.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-55d with the L2 index check disabled, its probe reports NOT FIRED and --selftest exits 5" \
  || bad "LT-55d dead L2 index" "$r $(grep -n 'L2\|SELFTEST' "$TMP/lt55-index.txt" | tr '\n' ' ')"
L55_L0=$(grep -A1 '^  L0 (doctor):' "$TMP/lt55.txt" | grep -c 'FIRED  *validator missing')
{ [ "$rcl" -eq 0 ] && [ "$L55_L0" -eq 1 ]; } \
  && ok "LT-55e S3-H1 --selftest has an L0 doctor probe that fires on a healthy install" \
  || bad "LT-55e S3-H1 L0 probe" "rc=$rcl $(grep -n 'L0' "$TMP/lt55.txt" | tr '\n' ' ')"
r=$(lt55_dead l0 's/if \[ -f "\$VALIDATOR" \]; then/if true; then/')
{ [ "$r" = "rc=5" ] && grep -A1 '^  L0 (doctor):' "$TMP/lt55-l0.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-55f with the L0 validator check disabled, its probe reports NOT FIRED and --selftest exits 5" \
  || bad "LT-55f dead L0" "$r $(grep -n 'L0\|SELFTEST' "$TMP/lt55-l0.txt" | tr '\n' ' ')"
# S3-E1: okflint absent. The okflint probes are SKIPPED with the reason, and the verdict line must not call them fired.
SB55="$TMP/sb52"; mksandbox "$SB55" $BASETOOLS python3 cp mv
if ! PATH="$SB55" command -v okflint >/dev/null 2>&1; then
  PATH="$SB55" "$SB55/bash" "$CHECK" --selftest >"$TMP/lt55g.txt" 2>&1; rcl=$?
  { [ "$rcl" -eq 0 ] && grep -q 'L2 (house profile): SKIPPED — okflint absent' "$TMP/lt55g.txt" \
      && ! grep -q 'every gate still fires' "$TMP/lt55g.txt" && grep -q 'SELFTEST PASS.*SKIPPED.*L2 (house profile)' "$TMP/lt55g.txt"; } \
    && ok "LT-55g S3-E1 okflint absent: the L2 profile probes are SKIPPED with the reason and the verdict names the skip, not 'every gate'" \
    || bad "LT-55g S3-E1 okflint absent" "rc=$rcl $(grep -n 'SKIPPED\|SELFTEST' "$TMP/lt55g.txt" | tr '\n' ' ')"
else
  skip "LT-55g S3-E1 the sandbox still finds okflint"
fi

# --- LT-53 (0.9.7, cases S5-*): okf_check.deprecated_requires: superseded_by ----------------------------------------
section "LT-53 (0.9.7, cases S5-*)"
# lt53 <name> <superseded_by line or empty> [option line] — a bundle with a stable new.md and a deprecated old.md; prints rc.
lt53() {
  local d="$TMP/lt53-$1"; rm -rf "$d"; mkbundle "$d"
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$d/okf-base.yaml"
  printf 'okf_check:\n  %s\n' "${3:-deprecated_requires: superseded_by}" >> "$d/okf-base.yaml"
  printf -- '---\ntype: Lesson\ntitle: New\ndescription: D\nstatus: stable\nstale_after: "2099-01-01"\n---\nbody\n' > "$d/new.md"
  printf -- '---\ntype: Lesson\ntitle: Old\ndescription: D\nstatus: deprecated\nstale_after: "2099-01-01"\n%s---\nbody\n' "${2:+$2
}" > "$d/old.md"
  "$CHECK" "$d" >"$d.txt" 2>&1; echo "rc=$?"
}
r=$(lt53 n1 "")
{ [ "$r" = "rc=1" ] && grep -q 'Successor .*FAIL' "$TMP/lt53-n1.txt" && grep -q 'old.md: status deprecated but no superseded_by' "$TMP/lt53-n1.txt"; } \
  && ok "LT-53a S5-N1 a deprecated note with no superseded_by is a house-rule error naming the note (exit 1)" \
  || bad "LT-53a S5-N1 no successor" "$r $(grep -n 'Successor\|Config\|old.md' "$TMP/lt53-n1.txt" | head -3 | tr '\n' ' ')"
r=$(lt53 h1 'superseded_by: new.md')
{ [ "$r" = "rc=0" ] && grep -q 'Successor .*PASS .*1 deprecated note' "$TMP/lt53-h1.txt"; } \
  && ok "LT-53b S5-H1 a deprecated note whose superseded_by names an existing stable note passes" \
  || bad "LT-53b S5-H1 valid successor" "$r $(grep -n 'Successor' -A1 "$TMP/lt53-h1.txt" | head -2 | tr '\n' ' ')"
# S5-N2: each invalid target is its own error, with its own message.
for c in "n2a|superseded_by: gone.md|superseded_by gone.md: successor not found" \
         "n2b|superseded_by: old.md|a note cannot supersede itself" \
         "n2c|superseded_by: old2.md|point at the final successor, not a deprecated one"; do
  id=${c%%|*}; rest=${c#*|}; line=${rest%%|*}; msg=${rest#*|}
  d="$TMP/lt53-$id"
  r=$(lt53 "$id" "$line")
  [ "$id" = n2c ] && { sed 's/^title: Old$/title: Old2/; s/^superseded_by: old2.md$/superseded_by: new.md/' "$d/old.md" > "$d/old2.md"; "$CHECK" "$d" >"$d.txt" 2>&1; r="rc=$?"; }
  { [ "$r" = "rc=1" ] && grep -q "^ *old.md: .*$msg" "$d.txt" && ! grep -q '^ *old2.md: .*superseded_by' "$d.txt"; } \
    && ok "LT-53c S5-N2 ($line) is an error saying '$msg' (exit 1)" \
    || bad "LT-53c S5-N2 $line" "$r $(grep -n 'Successor' -A2 "$d.txt" | head -3 | tr '\n' ' ')"
done
r=$(lt53 e1 'superseded_by: [new.md, "[[c]]"]')
{ [ "$r" = "rc=0" ] && grep -q 'Successor .*PASS' "$TMP/lt53-e1.txt"; } \
  && ok "LT-53d S5-E1 a list of two existing notes (a path and a wikilink) passes" \
  || bad "LT-53d S5-E1 two successors" "$r $(grep -n 'Successor' -A2 "$TMP/lt53-e1.txt" | head -3 | tr '\n' ' ')"
r=$(lt53 e2 "" "verify: {repos: [{path: .}]}")
{ [ "$r" = "rc=0" ] && ! grep -q 'Successor' "$TMP/lt53-e2.txt"; } \
  && ok "LT-53e S5-E2 with the option off a deprecated note without a successor passes and no Successor line is printed" \
  || bad "LT-53e S5-E2 option off" "$r $(grep -n 'Successor' -A1 "$TMP/lt53-e2.txt" | head -2 | tr '\n' ' ')"
# A value other than superseded_by would switch the rule off in silence, like an unknown key (LT-51a): exit 2, named.
r=$(lt53 val "" "deprecated_requires: superseded-by")
{ [ "$r" = "rc=2" ] && grep -q 'deprecated_requires.*superseded-by' "$TMP/lt53-val.txt"; } \
  && ok "LT-53f S5-N3 an unknown deprecated_requires value exits 2 and names the value" \
  || bad "LT-53f unknown deprecated_requires value" "$r $(grep -n 'Successor\|Config' "$TMP/lt53-val.txt" | head -2 | tr '\n' ' ')"
# --selftest has a Successor probe (project rule: every layer has one, proven by a copy with the rule disabled -> exit 5).
"$CHECK" --selftest >"$TMP/lt53g.txt" 2>&1; rcl=$?
L53=$(grep -A1 '^  Successor (deprecated_requires):' "$TMP/lt53g.txt" | grep -c 'FIRED  *deprecated, no superseded_by')
r=$(lt55_dead succ 's/    if m.get("status") != "deprecated":/    if True:/')
{ [ "$rcl" -eq 0 ] && [ "$L53" -eq 1 ] && [ "$r" = "rc=5" ] && grep -A1 '^  Successor (deprecated_requires):' "$TMP/lt55-succ.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-53g --selftest has a Successor probe that fires, and a copy with the rule disabled reports NOT FIRED and exits 5" \
  || bad "LT-53g Successor selftest probe" "healthy rc=$rcl fired=$L53; crippled $r $(grep -n 'Successor\|SELFTEST' "$TMP/lt55-succ.txt" 2>/dev/null | tr '\n' ' ')"
# Markdown links with a title or in angle brackets are links too (CommonMark): [x](new.md "t") and [x](<new.md>).
for c in "h1|superseded_by: '[x](new.md \"The new rule\")'" "h2|superseded_by: \"[x](new.md 'The new rule')\"" "h3|superseded_by: '[x](<new.md>)'"; do
  id=${c%%|*}; line=${c#*|}
  r=$(lt53 "$id" "$line")
  { [ "$r" = "rc=0" ] && grep -q 'Successor .*PASS' "$TMP/lt53-$id.txt"; } \
    && ok "LT-53h a markdown-link successor with a title or angle brackets resolves ($id)" \
    || bad "LT-53h markdown link form $id" "$r $(grep -n 'Successor' -A1 "$TMP/lt53-$id.txt" | head -2 | tr '\n' ' ')"
done
# With the option on and no deprecated note the line says so, instead of "0 deprecated note(s) name a valid successor".
D="$TMP/lt53-nodep"; rm -rf "$D"; mkbundle "$D"; sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$D/okf-base.yaml"
printf 'okf_check:\n  deprecated_requires: superseded_by\n' >> "$D/okf-base.yaml"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'Successor +PASS +no deprecated notes' "$D.txt"; } \
  && ok "LT-53j with the option on and no deprecated note the Successor line says 'no deprecated notes'" \
  || bad "LT-53j no deprecated notes wording" "rc=$rcl $(grep -n 'Successor' "$D.txt" | tr '\n' ' ')"
# index.md and log.md are reserved files, not notes: they cannot be a successor.
for c in "i1|superseded_by: index.md" "i2|superseded_by: \"[[log]]\""; do
  id=${c%%|*}; line=${c#*|}
  r=$(lt53 "$id" "$line")
  { [ "$r" = "rc=1" ] && grep -q 'old.md: .*successor is not a note' "$TMP/lt53-$id.txt"; } \
    && ok "LT-53i a reserved file as successor ($line) is an error: successor is not a note (exit 1)" \
    || bad "LT-53i reserved file as successor $id" "$r $(grep -n 'Successor' -A1 "$TMP/lt53-$id.txt" | head -2 | tr '\n' ' ')"
done

# --- LT-54 (0.9.8, cases S6-*): okf_check.require_owner and okf_check.owners folder defaults ------------------------
section "LT-54 (0.9.8, cases S6-*)"
# mk54 <name> <okf_check body, printf %b> — a bundle (c.md, no owner) with the template manifest plus that block.
mk54() {
  local d="$TMP/lt54-$1"; rm -rf "$d"; mkbundle "$d"
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$d/okf-base.yaml"
  printf 'okf_check:\n%b' "$2" >> "$d/okf-base.yaml"
}
# note54 <bundle dir> <rel path> <owner line or empty> [stale_after] — a stable Lesson.
note54() {
  mkdir -p "$(dirname "$1/$2")"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\nstale_after: "%s"\n%s---\nbody\n' "${4:-2099-01-01}" "${3:+$3
}" > "$1/$2"
}
mk54 n1 '  require_owner: true\n'
"$CHECK" "$TMP/lt54-n1" >"$TMP/lt54-n1.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 1 ] && grep -q 'Owner .*FAIL' "$TMP/lt54-n1.txt" && grep -q 'c.md: no owner' "$TMP/lt54-n1.txt"; } \
  && ok "LT-54a S6-N1 a note with no owner and no folder default is a house-rule error naming the note (exit 1)" \
  || bad "LT-54a S6-N1 no owner" "rc=$rcl $(grep -n 'Owner\|Config' "$TMP/lt54-n1.txt" | head -3 | tr '\n' ' ')"
# S6-H1. The Gherkin's `team-x` matches no section 7 actor shape (S6-E3 makes that an error), so the owner is `team:x`,
# the spec's own `<prefix>:<id>` form.
mk54 h1 '  require_owner: true\n'; D="$TMP/lt54-h1"
note54 "$D" c.md 'owner: team:x'; note54 "$D" old.md 'owner: team:x' 2000-01-01
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
"$CHECK" "$D" --json >"$D.json" 2>&1
{ [ "$rcl" -eq 0 ] && grep -Eq 'expired +old.md .*owner team:x' "$D.txt" && grep -q 'Owner .*PASS' "$D.txt" \
    && [ "$(jq44 "$D.json" '[s for s in d["stale"] if "old.md" in s and "owner team:x" in s] != []')" = True ]; } \
  && ok "LT-54b S6-H1 a note's owner is shown on its stale finding, in the text and in --json stale[]" \
  || bad "LT-54b S6-H1 owner on stale" "rc=$rcl $(grep -n 'expired\|Owner' "$D.txt" | head -3 | tr '\n' ' ') json: $(jq44 "$D.json" 'd["stale"]')"
# lt54_owner <name> <okf_check body> <owner line of the expired note decisions/b/d.md> — prints "rc=N owner=<shown>".
lt54_owner() {
  local D="$TMP/lt54-$1"; mk54 "$1" "$2"
  note54 "$D" c.md 'owner: team:x'; note54 "$D" decisions/b/d.md "$3" 2000-01-01
  "$CHECK" "$D" >"$D.txt" 2>&1; local rc=$?
  printf 'rc=%s owner=%s' "$rc" "$(sed -n 's/^ *expired  *decisions\/b\/d.md .* owner //p' "$D.txt")"
}
r=$(lt54_owner h2 '  require_owner: true\n  owners:\n    "decisions/**": team:a\n' '')
[ "$r" = "rc=0 owner=team:a" ] && ok "LT-54c S6-H2 a folder default (decisions/**) is the owner of a note under it with no owner key" \
  || bad "LT-54c S6-H2 folder default" "$r $(grep -n 'Owner' -A1 "$TMP/lt54-h2.txt" | head -2 | tr '\n' ' ')"
r=$(lt54_owner e1a '  require_owner: true\n  owners:\n    "decisions/**": team:a\n    "decisions/b/**": team:b\n' '')
r2=$(lt54_owner e1b '  require_owner: true\n  owners:\n    "decisions/b/**": team:b\n    "decisions/**": team:a\n' '')
{ [ "$r" = "rc=0 owner=team:b" ] && [ "$r2" = "rc=0 owner=team:a" ]; } \
  && ok "LT-54d S6-E1 when two folder patterns match, the later one wins (in either order, not the more specific one)" \
  || bad "LT-54d S6-E1 last match wins" "a-then-b: $r; b-then-a: $r2"
r=$(lt54_owner e2 '  require_owner: true\n  owners:\n    "decisions/**": team:a\n' 'owner: team:n')
[ "$r" = "rc=0 owner=team:n" ] && ok "LT-54e S6-E2 a note's own owner beats the matching folder default" \
  || bad "LT-54e S6-E2 note owner wins" "$r"
# S6-E3: the owner must be a section 7 actor (the validator's own check_actor): `team-x` matches no shape, and
# `Human:dana` is a near-miss of `human:` that section 5.3 reads as an agent. A bad folder default is caught the same way.
for c in "e3a|owner: team-x|c.md|team-x" "e3b|owner: Human:dana|c.md|Human:dana"; do
  id=${c%%|*}; rest=${c#*|}; line=${rest%%|*}; rest=${rest#*|}; nm=${rest%%|*}; val=${rest#*|}
  mk54 "$id" '  require_owner: true\n'; note54 "$TMP/lt54-$id" c.md "$line"
  "$CHECK" "$TMP/lt54-$id" >"$TMP/lt54-$id.txt" 2>&1; rcl=$?
  { [ "$rcl" -eq 1 ] && grep -Eq "^ +$nm: owner .*$val" "$TMP/lt54-$id.txt"; } \
    && ok "LT-54f S6-E3 owner '$val' is not an allowed actor form: an error names the note and the value (exit 1)" \
    || bad "LT-54f S6-E3 $line" "rc=$rcl $(grep -n 'Owner' -A1 "$TMP/lt54-$id.txt" | head -2 | tr '\n' ' ')"
done
r=$(lt54_owner e3c '  require_owner: true\n  owners:\n    "decisions/**": team-a\n' '')
{ case "$r" in rc=1*) true;; *) false;; esac && grep -Eq '^ +decisions/b/d.md: owner .*team-a' "$TMP/lt54-e3c.txt"; } \
  && ok "LT-54f S6-E3 a folder default that is not an actor form is an error on each note it covers" \
  || bad "LT-54f S6-E3 bad folder default" "$r $(grep -n 'Owner' -A1 "$TMP/lt54-e3c.txt" | head -2 | tr '\n' ' ')"
# The owner travels on L3 lifecycle findings too (--json lifecycle[]).
mk54 lc '  require_owner: true\n'; D="$TMP/lt54-lc"; note54 "$D" c.md 'owner: team:x'
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: current\nowner: team:y\nstale_after: "2099-01-01"\n---\nb\n' > "$D/odd.md"
"$CHECK" "$D" --json >"$D.json" 2>&1
[ "$(jq44 "$D.json" '[s for s in d["lifecycle"] if "odd.md" in s and s.endswith("owner team:y")] != []')" = True ] \
  && ok "LT-54g the owner is shown on an L3 lifecycle finding in --json lifecycle[]" \
  || bad "LT-54g owner on lifecycle" "$(jq44 "$D.json" 'd["lifecycle"]')"
# Option off: an owner key in a note changes nothing (no Owner line, no owner on findings).
mk54 off '  verify: {repos: [{path: .}]}\n'; D="$TMP/lt54-off"; note54 "$D" old.md 'owner: team:x' 2000-01-01
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && ! grep -q 'Owner\|owner team' "$D.txt" && grep -Eq 'expired +old.md' "$D.txt"; } \
  && ok "LT-54h with require_owner off there is no Owner line and no owner on the stale finding" \
  || bad "LT-54h option off" "rc=$rcl $(grep -n 'Owner\|expired' "$D.txt" | head -2 | tr '\n' ' ')"
# A value that would switch the rule off in silence exits 2 and is named (as LT-51a, LT-53f).
for c in "v1|  require_owner: yes-please\n|require_owner" "v2|  require_owner: true\n  owners: [team:a]\n|owners" \
         "v3|  owners:\n    \"decisions/**\": team:a\n|owners"; do
  id=${c%%|*}; rest=${c#*|}; body=${rest%%|*}; key=${rest#*|}
  mk54 "$id" "$body"; "$CHECK" "$TMP/lt54-$id" >"$TMP/lt54-$id.txt" 2>&1; rcl=$?
  { [ "$rcl" -eq 2 ] && grep -q "okf_check.$key" "$TMP/lt54-$id.txt"; } \
    && ok "LT-54i S6-N2 an unusable okf_check.$key ($id) exits 2 and names the key" \
    || bad "LT-54i unusable okf_check.$key ($id)" "rc=$rcl $(grep -n 'Owner\|Config' "$TMP/lt54-$id.txt" | head -2 | tr '\n' ' ')"
done
# --selftest has an Owner probe (project rule: every layer has one, proven by a copy with the rule disabled -> exit 5).
"$CHECK" --selftest >"$TMP/lt54j.txt" 2>&1; rcl=$?
L54=$(grep -A1 '^  Owner (require_owner):' "$TMP/lt54j.txt" | grep -c 'FIRED  *note without an owner')
r=$(lt55_dead owner 's/^    if not own:$/    if False:/')
{ [ "$rcl" -eq 0 ] && [ "$L54" -eq 1 ] && [ "$r" = "rc=5" ] && grep -A1 '^  Owner (require_owner):' "$TMP/lt55-owner.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-54j --selftest has an Owner probe that fires, and a copy with the rule disabled reports NOT FIRED and exits 5" \
  || bad "LT-54j Owner selftest probe" "healthy rc=$rcl fired=$L54; crippled $r $(grep -n 'Owner\|SELFTEST' "$TMP/lt55-owner.txt" 2>/dev/null | tr '\n' ' ')"
# G-1 (0.9.8 review): a note that starts with a UTF-8 BOM is read like L1 reads it (the owner and the status are seen).
mk54 bom '  require_owner: true\n  deprecated_requires: superseded_by\n'; D="$TMP/lt54-bom"; note54 "$D" c.md 'owner: team:x'
printf '\357\273\277---\ntype: Lesson\ntitle: B\ndescription: D\nstatus: stable\nowner: team:x\nstale_after: "2099-01-01"\n---\nb\n' > "$D/bom.md"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'Owner .*PASS' "$D.txt" && ! grep -q 'bom.md: no owner' "$D.txt"; } \
  && ok "LT-54k a BOM-prefixed note with owner: team:x has its owner (exit 0)" \
  || bad "LT-54k BOM owner" "rc=$rcl $(grep -n 'Owner' -A1 "$D.txt" | head -2 | tr '\n' ' ')"
printf '\357\273\277---\ntype: Lesson\ntitle: B\ndescription: D\nstatus: deprecated\nowner: team:x\nstale_after: "2099-01-01"\n---\nb\n' > "$D/bom.md"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 1 ] && grep -q 'bom.md: status deprecated but no superseded_by' "$D.txt"; } \
  && ok "LT-54k a BOM-prefixed deprecated note without a successor is seen by the Successor rule (exit 1)" \
  || bad "LT-54k BOM successor" "rc=$rcl $(grep -n 'Successor' -A1 "$D.txt" | head -2 | tr '\n' ' ')"
# owner "human:" (quoted) is not an actor; owner: human: (unquoted) is not valid YAML, so it cannot be read at all.
mk54 hum '  require_owner: true\n'; D="$TMP/lt54-hum"; note54 "$D" c.md 'owner: "human:"'
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 1 ] && grep -q 'c.md: owner `human:` is not an allowed actor form' "$D.txt"; } \
  && ok "LT-54l owner \"human:\" (an empty id) is not an allowed actor form" || bad "LT-54l quoted human:" "rc=$rcl $(grep -n 'Owner' -A1 "$D.txt" | head -2 | tr '\n' ' ')"
note54 "$D" c.md 'owner: human:'
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 1 ] && grep -q 'c.md: the frontmatter is not valid YAML, so its owner cannot be read' "$D.txt" && ! grep -q 'c.md: no owner' "$D.txt"; } \
  && ok "LT-54l owner: human: (not valid YAML) says the owner cannot be read, not 'no owner'" || bad "LT-54l unquoted human:" "rc=$rcl $(grep -n 'Owner' -A1 "$D.txt" | head -2 | tr '\n' ' ')"

# G-3: an owner that is not a string (a list, a number, a boolean) is not an actor, and is never printed as a Python repr.
for c in "t1|owner: [team:x]|[\"team:x\"]" "t2|owner: 0|0" "t3|owner: false|false"; do
  id=${c%%|*}; rest=${c#*|}; line=${rest%%|*}; shown=${rest#*|}
  mk54 "$id" '  require_owner: true\n'; D="$TMP/lt54-$id"; note54 "$D" c.md "$line" 2000-01-01
  "$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
  { [ "$rcl" -eq 1 ] && grep -qF "c.md: owner \`$shown\` is not an allowed actor form" "$D.txt" && ! grep -q "owner \['" "$D.txt" && ! grep -q 'c.md: no owner' "$D.txt"; } \
    && ok "LT-54m owner '$line' is not an allowed actor form (shown as $shown), exit 1" \
    || bad "LT-54m owner type $id" "rc=$rcl $(grep -n 'Owner\|expired' -A1 "$D.txt" | head -3 | tr '\n' ' ')"
done
# G-2: an owners pattern with a leading ! (negation, not supported) is refused, not silently inert.
mk54 neg '  require_owner: true\n  owners:\n    "**": team:a\n    "!drafts/**": team:b\n'; D="$TMP/lt54-neg"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 2 ] && grep -q 'okf_check.owners.!drafts/\*\*: a pattern that starts with ! (negation) is not supported' "$D.txt"; } \
  && ok "LT-54n S6-N4 an owners pattern that starts with ! exits 2 naming it (negation is not supported)" \
  || bad "LT-54n negated owners pattern" "rc=$rcl $(grep -n 'Config\|Owner' "$D.txt" | head -2 | tr '\n' ' ')"
# --- LT-56 (0.9.9, cases S7-*): okf-check --duplicates lists candidate duplicate pairs (advisory, always exit 0) ------
section "LT-56 (0.9.9, cases S7-*)"
# mk56 <name> [okf_check body, printf %b] — a bundle (c.md from mkbundle) with the template manifest and that block.
mk56() {
  local d="$TMP/lt56-$1"; rm -rf "$d"; mkbundle "$d"
  sed 's/^  name: CHANGE ME/  name: Probe/' "$HERE/../config/okf-base.yaml.template" > "$d/okf-base.yaml"
  [ -n "${2:-}" ] && printf 'okf_check:\n%b' "$2" >> "$d/okf-base.yaml"
  return 0
}
# note56 <bundle dir> <rel> <title> <description> [extra frontmatter lines] [status]
note56() {
  mkdir -p "$(dirname "$1/$2")"
  printf -- '---\ntype: Lesson\ntitle: %s\ndescription: %s\nstatus: %s\ngenerated:\n  by: human:t\n  at: "2026-01-02"\nstale_after: "2099-01-01"\n%s---\nbody\n' \
    "$3" "$4" "${6:-stable}" "${5:+$5
}" > "$1/$2"
}
mk56 n1; D="$TMP/lt56-n1"; note56 "$D" a.md "Alpha rule" "Use alpha for x"; note56 "$D" b.md "Beta rule" "Beta covers y"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-56a S7-N1 a bundle with no candidate pairs says 'no candidate duplicates', exit 0" \
  || bad "LT-56a S7-N1 no pairs" "rc=$rcl $(head -3 "$D.txt" | tr '\n' ' ')"
# S7-H1: titles equal after NFKC, lower case, punctuation and spacing are folded.
mk56 h1; D="$TMP/lt56-h1"; note56 "$D" a.md "Deploy rule" "Ship on Fridays"; note56 "$D" sub/b.md "deploy  RULE!" "Never on weekends" 'owner: team:x' draft
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
L=$(grep 'title 1.00' "$D.txt")
{ [ "$rcl" -eq 0 ] && grep -q '1 candidate pair' "$D.txt" && case "$L" in *a.md*stable*2026-01-02*sub/b.md*draft*2026-01-02*team:x*) true;; *) false;; esac; } \
  && ok "LT-56b S7-H1 two notes with the same normalized title are listed with the score, both statuses, generated.at and owner, exit 0" \
  || bad "LT-56b S7-H1 same title" "rc=$rcl line='$L' $(head -4 "$D.txt" | tr '\n' ' ')"
# S7-H2: description word overlap (Jaccard of the word sets) at or above okf_check.duplicates.threshold. 6 shared words
# of 7: 0.86. The default threshold is 1.0 (identical word sets only): on the labelled sample no lower threshold
# reached precision 0.8, so the same pair is NOT listed without the option.
mk56 h2 '  duplicates:\n    threshold: 0.5\n'; D="$TMP/lt56-h2"
note56 "$D" a.md "Staging first" "Use the staging cluster before release"; note56 "$D" b.md "Cluster order" "Use the staging cluster before every release"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'description 0\.86 +a\.md .* ~ +b\.md' "$D.txt"; } \
  && ok "LT-56c S7-H2 descriptions that overlap at or above okf_check.duplicates.threshold are listed with their score" \
  || bad "LT-56c S7-H2 description overlap" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
cp "$HERE/../config/okf-base.yaml.template" "$D/okf-base.yaml"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-56d without the option the description threshold is 1.0: a 0.86 overlap is not listed" \
  || bad "LT-56d default threshold" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# S7-E2: a pair already linked by superseded_by (either note naming the other) is not listed.
for c in "e2a|old.md|new.md" "e2b|new.md|old.md"; do
  id=${c%%|*}; rest=${c#*|}; from=${rest%%|*}; to=${rest#*|}
  mk56 "$id"; D="$TMP/lt56-$id"; note56 "$D" old.md "Deploy rule" "Old way"; note56 "$D" new.md "Deploy rule" "New way"
  printf -- '---\ntype: Lesson\ntitle: Deploy rule\ndescription: The retired way\nstatus: deprecated\nsuperseded_by: "[[%s]]"\nstale_after: "2099-01-01"\n---\nb\n' "${to%.md}" > "$D/$from"
  "$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
  { [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
    && ok "LT-56e S7-E2 a same-title pair where $from names $to in superseded_by is not listed" \
    || bad "LT-56e S7-E2 $from supersedes $to" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
done
# The same sources[].resource (normalized path) is a candidate too.
mk56 res; D="$TMP/lt56-res"
note56 "$D" a.md "Retry policy" "Back off" $'sources:\n  - resource: docs/api.md'; note56 "$D" b.md "Client limits" "Rate caps" $'sources:\n  - resource: ./docs//api.md'
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'resource 1\.00 +a\.md' "$D.txt"; } \
  && ok "LT-56f two notes citing the same sources[].resource (after path normalization) are listed" \
  || bad "LT-56f same resource" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# The owner is the effective one: a folder default when the note has no owner key.
mk56 own '  require_owner: true\n  owners:\n    "**": team:a\n'; D="$TMP/lt56-own"; rm -f "$D/c.md"
note56 "$D" a.md "Deploy rule" "One"; note56 "$D" b.md "Deploy rule" "Two" 'owner: team:b'
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'a\.md \[[^]]*owner team:a\] +~ +b\.md \[[^]]*owner team:b\]' "$D.txt"; } \
  && ok "LT-56g the owner shown is the effective one: the folder default for a note without an owner key" \
  || bad "LT-56g effective owner" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# --- LT-58 (0.9.11 review, S8-E1): a dangling symlink named *.md is no note for the okf_check rules either -----------
section "LT-58 (0.9.11 review, S8-E1)"
# The walkers of the layers skip it (okf_md_files); the Successor and Owner rules walked with rglob and counted it.
mk56 dng '  require_owner: true\n  deprecated_requires: superseded_by\n'; D="$TMP/lt56-dng"; rm -f "$D/c.md"
note56 "$D" a.md "Alpha" "One" 'owner: team:x'; ln -s nowhere.md "$D/dang.md"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
# okflint (not ours) may itself fail on the dangling link, so the exit code is not asserted: the two rules' own lines are.
{ grep -Eq '^  Owner +PASS +1 note' "$D.txt" && grep -Eq '^  Successor +PASS' "$D.txt" && ! grep -q 'dang.md: no owner' "$D.txt"; } \
  && ok "LT-58a a dangling symlink named dang.md is not a note: the Owner rule counts 1 note and reports no finding for it" \
  || bad "LT-58a dangling symlink in the okf_check rules" "rc=$rcl $(grep -n 'dang' "$D.txt" | head -3 | tr '\n' ' ')"
# LT-56p (0.9.9 review, HIGH): a note whose `sources` is not a list passes L1 with a warning, so the report must read it, not crash.
mk56 srcs; D="$TMP/lt56-srcs"; note56 "$D" a.md "Same" "One" 'sources: 5'; note56 "$D" b.md "Same" "Two" 'sources: {x: 1}'; note56 "$D" c.md "Other" "Three" 'sources: text'
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'title 1\.00 +a\.md .*~ +b\.md' "$D.txt" && ! grep -q Traceback "$D.txt"; } \
  && ok "LT-56p a note whose sources is a number, a mapping or a string is read, not a crash (exit 0)" \
  || bad "LT-56p non-list sources" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# LT-56q (0.9.9 review, MEDIUM): a symlink to a note in the bundle is the same note, not a duplicate of its own target.
mk56 lnk; D="$TMP/lt56-lnk"; note56 "$D" a.md "Alias" "One"; ln -s a.md "$D/alias.md"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-56q a symlink alias of a note is not listed as a duplicate of its target" \
  || bad "LT-56q symlink alias" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# LT-56r (0.9.9 review register): the alias and its target are ONE note, so a third note that duplicates it is one
# pair, listed under the real note. The alias sorts first on purpose: the real path must win, not the walk order.
mk56 lnk3; D="$TMP/lt56-lnk3"; note56 "$D" b.md "Alias" "One"; ln -s b.md "$D/a-link.md"; note56 "$D" c.md "Alias" "Two"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && [ "$(grep -c ' ~ ' "$D.txt")" = 1 ] && grep -Eq 'title 1\.00 +b\.md .*~ +c\.md' "$D.txt" \
  && ! grep -q 'a-link\.md' "$D.txt"; } \
  && ok "LT-56r a symlink alias is counted once: a third duplicate note is one pair, under the real note" \
  || bad "LT-56r alias plus a third note" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# LT-56m: the plugin directory ships as it was installed. A python3 that writes bytecode beside the imported module
# (Linux does; Apple's python redirects it to a cache folder) left scripts/__pycache__/ behind, and plugin.test.sh Z-2
# then reported it as a dead file on the Debian gate (0.9.9). A shim python3 that clears the cache prefix reproduces
# that on any host.
mk56 pyc; D="$TMP/lt56-pyc"; note56 "$D" a.md "Same" "One"; note56 "$D" b.md "Same" "Two"
PYC="$TMP/lt56-pyc-plugin"; rm -rf "$PYC"; mkdir -p "$PYC/bin"; cp -R "$HERE/.." "$PYC/plugin" 2>/dev/null
find "$PYC/plugin" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
printf '#!/bin/sh\nexec "%s" -X pycache_prefix= "$@"\n' "$REALPY" > "$PYC/bin/python3"; chmod +x "$PYC/bin/python3"
PATH="$PYC/bin:$PATH" "$PYC/plugin/scripts/okf-check" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'a.md' "$D.txt" && [ -z "$(find "$PYC/plugin" -name '*.pyc' -o -name __pycache__ 2>/dev/null)" ]; } \
  && ok "LT-56m --duplicates leaves no bytecode in the plugin directory" \
  || bad "LT-56m no bytecode left behind" "rc=$rcl $(find "$PYC/plugin" -name '*.pyc' | head -3 | tr '\n' ' ')"
# S7-E1: 1,000 notes end within the default time limit (60 s), and a run that hits the limit says it was cut short.
# OKF_DUP_TIME_LIMIT (tests only, like OKF_TODAY) replaces the limit so the cut is deterministic, not a race.
mk56 e1; D="$TMP/lt56-e1"
"$REALPY" - "$D" <<'PY'
import sys
for i in range(1000):
    open("%s/n%04d.md" % (sys.argv[1], i), "w").write('---\ntype: Lesson\ntitle: Note %d\ndescription: Topic %d covers item %d of set %d\nstatus: stable\nstale_after: "2099-01-01"\n---\nb\n' % (i, i % 37, i, i % 11))
PY
t0=$SECONDS; "$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?; el=$((SECONDS - t0))
{ [ "$rcl" -eq 0 ] && [ "$el" -lt 60 ] && ! grep -q 'CUT SHORT' "$D.txt"; } \
  && ok "LT-56h S7-E1 1,000 notes are compared in full within the 60 s default (${el} s here)" \
  || bad "LT-56h S7-E1 1,000 notes" "rc=$rcl ${el}s $(head -3 "$D.txt" | tr '\n' ' ')"
# Cut in the pair pass (OKF_DUP_CUT_AT, 0.9.35): a bare tiny limit now stops while the notes are read (S25-DU-E1).
OKF_DUP_CUT_AT=pairs "$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'CUT SHORT .*[0-9]+ of 500500 pairs compared' "$D.txt"; } \
  && ok "LT-56i S7-E1 a run that reaches the time limit says CUT SHORT and how many pairs it compared, exit 0" \
  || bad "LT-56i S7-E1 cut short" "rc=$rcl $(head -3 "$D.txt" | tr '\n' ' ')"
# --json: duplicates[] (signal, score, both notes) plus complete/compared/pairs_total; a key of this mode only.
D="$TMP/lt56-h1"; "$CHECK" "$D" --duplicates --json >"$D.json" 2>&1; rcl=$?
[ "$rcl" -eq 0 ] && [ "$(jq44 "$D.json" '(d["complete"], d["pairs_total"], [(x["signal"], x["a"]["rel"], x["b"]["rel"], x["b"]["owner"]) for x in d["duplicates"]])')" = "(True, 3, [('title', 'a.md', 'sub/b.md', 'team:x')])" ] \
  && ok "LT-56j --duplicates --json gives duplicates[] with the signal and both notes, and says the run was complete" \
  || bad "LT-56j --json" "rc=$rcl $(head -c 300 "$D.json")"
# .okfignore: an ignored note is not compared, as in every layer of a check.
mk56 ign; D="$TMP/lt56-ign"; note56 "$D" a.md "Deploy rule" "One"; note56 "$D" archive/b.md "Deploy rule" "Two"; printf 'archive/\n' > "$D/.okfignore"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-56k a note excluded by .okfignore is not compared" || bad "LT-56k .okfignore" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# A duplicates block that fails the schema is the Config line's exit 2, and no pairs are reported.
mk56 bad '  duplicates:\n    threshold: 5\n'; D="$TMP/lt56-bad"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 2 ] && grep -q 'okf_check.duplicates.threshold must be a number from 0.1 to 1' "$D.txt" && ! grep -q 'Duplicates ' "$D.txt"; } \
  && ok "LT-56l --duplicates with an unusable okf_check.duplicates value exits 2 naming it, and lists nothing" \
  || bad "LT-56l bad duplicates config" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# okf_notes.py (the note reader the successor, owner and duplicates rules share) missing: exit 2, named. Without the
# guard the successor rule's import failed inside its try and the rule switched itself off with exit 0.
D56M="$TMP/lt56m"; rm -rf "$D56M"; mkdir -p "$D56M"; cp -R "$HERE/.." "$D56M/plugin" 2>/dev/null; rm -f "$D56M/plugin/scripts/okf_notes.py"
mk56 m '  deprecated_requires: superseded_by\n'; "$D56M/plugin/scripts/okf-check" "$TMP/lt56-m" >"$D56M.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 2 ] && grep -q 'okf_notes.py is missing' "$D56M.txt"; } \
  && ok "LT-56m a plugin without okf_notes.py exits 2 naming it, instead of switching the okf_check rules off" \
  || bad "LT-56m okf_notes.py missing" "rc=$rcl $(head -3 "$D56M.txt" | tr '\n' ' ')"
# --selftest has a Duplicates probe (project rule): a note titled like the baseline note must be listed.
"$CHECK" --selftest >"$TMP/lt56n.txt" 2>&1; rcl=$?
L56=$(grep -A1 '^  Duplicates (--duplicates):' "$TMP/lt56n.txt" | grep -c 'FIRED  *same title')
r=$(lt55_dead dup 's/    if a\["title"\] and a\["title"\] == b\["title"\]:/    if False:/' okf-duplicates.py)
{ [ "$rcl" -eq 0 ] && [ "$L56" -eq 1 ] && [ "$r" = "rc=5" ] && grep -A1 '^  Duplicates (--duplicates):' "$TMP/lt55-dup.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-56n --selftest has a Duplicates probe that fires, and a copy with the title signal disabled reports NOT FIRED and exits 5" \
  || bad "LT-56n Duplicates selftest probe" "healthy rc=$rcl fired=$L56; crippled $r $(grep -n 'Duplicates\|SELFTEST' "$TMP/lt55-dup.txt" 2>/dev/null | tr '\n' ' ')"
# A note that starts with a UTF-8 BOM is read like L1 reads it (0.9.8 review G-1, the shared okf_notes.py reader).
mk56 bom; D="$TMP/lt56-bom"; note56 "$D" a.md "Deploy rule" "One"
printf '\357\273\277---\ntype: Lesson\ntitle: Deploy rule\ndescription: Two\nstatus: stable\nstale_after: "2099-01-01"\n---\nb\n' > "$D/bom.md"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'title 1\.00 +a\.md .* ~ +bom\.md' "$D.txt"; } \
  && ok "LT-56o a BOM-prefixed note with the same title is listed" || bad "LT-56o BOM note" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"

# --- LT-57 (0.9.10, case S7-E3): --duplicates-body adds pairs whose bodies are similar (MinHash, time-boxed) ---------
section "LT-57 (0.9.10, case S7-E3)"
# body57 <file> <title> <description> <body> — a stable Lesson with that body.
body57() { printf -- '---\ntype: Lesson\ntitle: %s\ndescription: %s\nstatus: stable\nstale_after: "2099-01-01"\n---\n%s\n' "$2" "$3" "$4" > "$1"; }
P57="Run the migration on a copy of the production database first, check the row counts against the source tables, keep the old schema for one release, and only then drop the columns the new code no longer reads."
mk56 e3; D="$TMP/lt56-e3"
body57 "$D/a.md" "Migrations" "How we change tables" "$P57 Ask the data owner before you start."
body57 "$D/b.md" "Schema changes" "Rules for altering columns" "$P57 Write the rollback down in the ticket."
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'body 0\.[0-9]+ +a\.md .* ~ +b\.md' "$D.txt"; } \
  && ok "LT-57a S7-E3 --duplicates-body adds a pair whose bodies share most of their text (exit 0)" \
  || bad "LT-57a S7-E3 body pair" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
"$CHECK" "$D" --duplicates >"$D.txt" 2>&1
grep -q 'no candidate duplicates' "$D.txt" && ok "LT-57b plain --duplicates does not compare bodies" || bad "LT-57b plain --duplicates" "$(head -4 "$D.txt" | tr '\n' ' ')"
printf 'okf_check:\n  duplicates:\n    body_threshold: 0.95\n' >> "$D/okf-base.yaml"
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-57c okf_check.duplicates.body_threshold is honoured: a pair below 0.95 is not listed" || bad "LT-57c body_threshold" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# Banding recall at body_threshold 0.3 (set explicitly): two bodies sharing about a third of their shingles are found.
mk56 e3n '  duplicates:\n    body_threshold: 0.3\n'; D="$TMP/lt56-e3n"
body57 "$D/a.md" "Release notes" "One" "$P57 alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu"
body57 "$D/b.md" "Upgrade steps" "Two" "$P57 one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix"
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'body 0\.(3[0-9]|4[0-9]) +a\.md' "$D.txt"; } \
  && ok "LT-57f with body_threshold 0.3 a body pair at 0.3-0.5 is found by the banding" \
  || bad "LT-57f body recall near the threshold" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# The default body_threshold is 0.6: on 24 live body pairs, blind-labelled, 0.3 had precision 0.50 and 0.6 had 1.00
# (every NOT at or below 0.57). The same 0.3-0.5 pair is not listed without the option.
cp "$HERE/../config/okf-base.yaml.template" "$D/okf-base.yaml"
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-57g without the option body_threshold is 0.6: a 0.3-0.5 body pair is not listed" \
  || bad "LT-57g default body_threshold" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# S7-E3 "time-boxed": 1,000 notes with bodies complete within the 60 s default; a reached limit says CUT SHORT.
mk56 e3k; D="$TMP/lt56-e3k"
"$REALPY" - "$D" <<'PY'
import random, sys
r = random.Random(70); words = ["w%d" % i for i in range(3000)]
for i in range(1000):
    body = " ".join(r.choice(words) for _ in range(200))
    open("%s/n%04d.md" % (sys.argv[1], i), "w").write('---\ntype: Lesson\ntitle: Note %d\ndescription: Item %d\nstatus: stable\nstale_after: "2099-01-01"\n---\n%s\n' % (i, i, body))
PY
t0=$SECONDS; "$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?; el=$((SECONDS - t0))
{ [ "$rcl" -eq 0 ] && [ "$el" -lt 60 ] && ! grep -q 'CUT SHORT' "$D.txt"; } \
  && ok "LT-57d S7-E3 --duplicates-body on 1,000 notes of 200 words completes within the 60 s default (${el} s here)" \
  || bad "LT-57d S7-E3 1,000 bodies" "rc=$rcl ${el}s $(head -3 "$D.txt" | tr '\n' ' ')"
OKF_DUP_TIME_LIMIT=0.000001 "$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'CUT SHORT' "$D.txt"; } \
  && ok "LT-57e S7-E3 a --duplicates-body run that reaches the limit says CUT SHORT, exit 0" || bad "LT-57e cut short" "rc=$rcl $(head -3 "$D.txt" | tr '\n' ' ')"
# --selftest has a Duplicates-body probe (project rule): a note whose body equals the baseline note's must be listed.
"$CHECK" --selftest >"$TMP/lt57h.txt" 2>&1; rcl=$?
L57=$(grep -A1 '^  Duplicates (--duplicates-body):' "$TMP/lt57h.txt" | grep -c 'FIRED  *same body')
r=$(lt55_dead body 's/            if jb >= body_threshold:/            if False:/' okf-duplicates.py)
{ [ "$rcl" -eq 0 ] && [ "$L57" -eq 1 ] && [ "$r" = "rc=5" ] && grep -A1 '^  Duplicates (--duplicates-body):' "$TMP/lt55-body.txt" | grep -q 'NOT FIRED'; } \
  && ok "LT-57h --selftest has a Duplicates-body probe that fires, and a copy with the body signal disabled reports NOT FIRED and exits 5" \
  || bad "LT-57h Duplicates-body selftest probe" "healthy rc=$rcl fired=$L57; crippled $r $(grep -n 'Duplicates\|SELFTEST' "$TMP/lt55-body.txt" 2>/dev/null | tr '\n' ' ')"
# A BOM-prefixed note's body is its text after the frontmatter, as for any note.
mk56 e3b; D="$TMP/lt56-e3b"
body57 "$D/a.md" "Migrations" "How we change tables" "$P57"
printf '\357\273\277---\ntype: Lesson\ntitle: Schema changes\ndescription: Rules for altering columns\nstatus: stable\nstale_after: "2099-01-01"\n---\n%s\n' "$P57" > "$D/b.md"
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -Eq 'body 1\.00 +a\.md .* ~ +b\.md' "$D.txt"; } \
  && ok "LT-57i a BOM-prefixed note with the same body is a body 1.00 pair (its frontmatter is not counted as body)" \
  || bad "LT-57i BOM body" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# LT-57j (0.9.10 review, HIGH): a symlink alias of a note is the same note, not a body duplicate of its target.
mk56 e3l; D="$TMP/lt56-e3l"; body57 "$D/a.md" "Alias" "One" "$P57"; ln -s a.md "$D/alias.md"
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt"; } \
  && ok "LT-57j a symlink alias of a note is not a body duplicate of its target" \
  || bad "LT-57j symlink alias body" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"
# LT-57k (0.9.10 review, HIGH): a .md entry that cannot be read (dangling symlink, a directory) is skipped, not a crash: the report is advisory, exit 0.
mk56 e3u; D="$TMP/lt56-e3u"; body57 "$D/a.md" "Alpha" "One" "$P57"; ln -s missing.md "$D/broken.md"; mkdir -p "$D/dir.md"
"$CHECK" "$D" --duplicates-body >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'no candidate duplicates' "$D.txt" && ! grep -q Traceback "$D.txt"; } \
  && ok "LT-57k a dangling symlink and a directory named x.md are skipped by --duplicates-body (exit 0)" \
  || bad "LT-57k unreadable .md entry" "rc=$rcl $(head -4 "$D.txt" | tr '\n' ' ')"

section "S30 (successor resolved by Obsidian's rule, L1 warnings in the tally)"
# note29 <file> <title> <status> [one more frontmatter line]
note29() {
  printf -- '---\ntype: Lesson\ntitle: %s\ndescription: D\nstatus: %s\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n%s---\n\nbody\n' \
    "$2" "$3" "${4:+$4
}" > "$1"
}
# succ30 <id> <target file> <superseded_by value> [setup, run in the bundle folder]: the target note and old.md
# (deprecated, naming the value), deprecated_requires on.
succ30() {
  mk56 "$1" '  deprecated_requires: superseded_by\n'; D="$TMP/lt56-$1"; rm -f "$D/c.md"
  [ -z "${4:-}" ] || (cd "$D" && eval "$4")
  mkdir -p "$D/$(dirname "$2")"; note29 "$D/$2" New stable; note29 "$D/old.md" Old deprecated "superseded_by: $3"
  "$CHECK" "$D" >"$D.txt" 2>&1 </dev/null
}
# S30-CF-H1: a successor resolves by Obsidian's rule, the one okf-export and the L2 wikilink filter use, on every disk:
# the exact name first, else the one name equal to it ignoring case and Unicode normalisation (macOS may store a name
# decomposed); `..` is followed the way the OS follows it, through a folder link too. macOS found [[New]] and Linux did
# not; an earlier fix made macOS fail too (and NFD names, and lnk/..).
NFC=$(printf 'caf\303\251'); NFD=$(printf 'cafe\314\201')
while IFS='|' read -r id tgt val setup; do
  succ30 "cf$id" "$tgt" "$val" "$setup"; rcl=$?
  { [ "$rcl" -eq 0 ] && grep -q 'Successor *PASS *1 deprecated note(s) name a valid successor' "$D.txt"; } \
    && ok "S30-CF-H1 $id: superseded_by $val names $tgt: Successor PASS (exit 0), on every disk" \
    || bad "S30-CF-H1 $id" "rc=$rcl $(grep -A1 'Successor' "$D.txt" | tr '\n' ' ')"
done <<EOF
exact|new.md|"[[new]]"|
case|new.md|"[[New]]"|
case-mdlink|new.md|"[n](New.md)"|
case-path|new.md|NEW.md|
nfd-file|$NFD.md|"[[$NFC]]"|
nfc-file|$NFC.md|"[[$NFD]]"|
space|my note.md|"[[My Note]]"|
dot|new.md|"[[./new]]"|
dotdot|new.md|"[[sub/../New]]"|mkdir sub
EOF
# S30-CF-H2: the resolver itself, on a real tree (okf-duplicates reads the bundle, not a copy): `..` after a folder link
# is the link target's parent, as the OS reads it, and `..` after a folder that is not there is dropped, as realpath
# drops it. An earlier fix walked `..` by name and lost the first case.
D="$TMP/cf-h2"; mkdir -p "$D/d/e"; note29 "$D/d/z.md" Z stable; note29 "$D/new.md" New stable; ln -s d/e "$D/lnk"
got=$(OKF_D="$D" PYTHONPATH="$HERE:$HERE/../vendor" "$REALPY" -c '
import os
from okf_notes import resolve
r = os.path.realpath(os.environ["OKF_D"])
for ref in ("[[lnk/../Z]]", "[[nosub/../New]]", "[[sub/../New]]"):
    q = resolve(ref, os.path.join(r, "old.md"), r)
    print(os.path.relpath(q, r) if q else None)' 2>&1 | tr '\n' ' ')
[ "$got" = "d/z.md new.md new.md " ] \
  && ok "S30-CF-H2 resolve(): [[lnk/../Z]] is d/z.md through the folder link; [[nosub/../New]] is new.md" \
  || bad "S30-CF-H2 resolve() and .." "got: $got (want: d/z.md new.md new.md)"
# S30-CF-N1c: a folder link inside the bundle is not entered (rule of the symlinks layer): its notes are not in the copy the
# layers read, so [[lnk/New]] stays not found, as before.
succ30 cfn1c sub/new.md '"[[lnk/New]]"' 'mkdir sub && ln -s sub lnk'; rcl=$?
{ [ "$rcl" -eq 1 ] && grep -qF 'superseded_by [[lnk/New]]: successor not found' "$D.txt"; } \
  && ok "S30-CF-N1c superseded_by [[lnk/New]] through a folder link: not entered, successor not found (exit 1)" \
  || bad "S30-CF-N1c folder link" "rc=$rcl $(grep -A1 'Successor' "$D.txt" | tr '\n' ' ')"
# S30-CF-N1d: the verdict comes from the rule, not from the disk: names that lower() does not equate stay not found even
# where the disk folds them (macOS equates straße with STRASSE, ΟΔΟΣ with οδος and İ with i; Linux and okf-export
# do not).
while IFS='|' read -r id tgt val; do
  succ30 "cf$id" "$tgt" "$val"; rcl=$?
  vv=$(printf '%s' "$val" | tr -d '"')
  { [ "$rcl" -eq 1 ] && grep -qF "superseded_by $vv: successor not found" "$D.txt"; } \
    && ok "S30-CF-N1d $id: superseded_by $vv with only $tgt: successor not found (exit 1), on every disk" \
    || bad "S30-CF-N1d $id" "rc=$rcl $(grep -A1 'Successor' "$D.txt" | tr '\n' ' ')"
done <<EOF
sz|straße.md|"[[STRASSE]]"
sigma|ΟΔΟΣ.md|"[[οδος]]"
idot|İ.md|"[[i]]"
EOF
# S30-CF-N1: a name that matches nothing is not found, and two names that differ only in case (a case-sensitive disk)
# make a link that matches neither exactly ambiguous: not found, as okf-export does not pick one.
succ30 cfn1 new.md '"[[Neww]]"'; rcl=$?
{ [ "$rcl" -eq 1 ] && grep -qF 'superseded_by [[Neww]]: successor not found' "$D.txt"; } \
  && ok "S30-CF-N1 superseded_by [[Neww]] with only new.md: Successor FAIL, successor not found (exit 1)" \
  || bad "S30-CF-N1 no match" "rc=$rcl $(grep -A1 'Successor' "$D.txt" | tr '\n' ' ')"
succ30 cfn1b new.md '"[[NEW]]"' 'note29 New.md Other stable'; rcl=$?
if [ "$(find "$D" -name '*.md' | wc -l | tr -d ' ')" -lt 5 ]; then
  skip "S30-CF-N1b this disk folds case, so New.md and new.md are one file (run on Linux)"
else
  { [ "$rcl" -eq 1 ] && grep -qF 'superseded_by [[NEW]]: successor not found' "$D.txt"; } \
    && ok "S30-CF-N1b superseded_by [[NEW]] with New.md and new.md: ambiguous, Successor FAIL (exit 1)" \
    || bad "S30-CF-N1b ambiguous" "rc=$rcl $(grep -A1 'Successor' "$D.txt" | tr '\n' ' ')"
fi
# S30-CF-N2: an L1 warning is an advisory like an L2 one; the final tally counted only the others (0 for 1 warning).
D="$TMP/cf-n2"; mkbundle "$D"; note29 "$D/c.md" T stable; printf 'See [m](missing.md).\n' >> "$D/c.md"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
{ [ "$rcl" -eq 0 ] && grep -q 'L1 conformance *PASS .*, 1 warning(s)' "$D.txt" && grep -q 'but 1 advisory(ies) and .* above (advisories: L1 1)$' "$D.txt"; } \
  && ok "S30-CF-N2 one L1 warning (a link to a missing file) and nothing else: the tally says 1 advisory(ies) (advisories: L1 1)" \
  || bad "S30-CF-N2 L1 warning in the tally" "rc=$rcl $(grep -E 'L1 conf|advisor' "$D.txt" | tr '\n' ' ')"
# S30-CF-N2b: L1 and L2 warnings add up: the tally is the sum of the two warning counts printed above it.
mk56 cfn2b; D="$TMP/lt56-cfn2b"; printf 'See [m](missing.md).\n' >> "$D/c.md"
"$CHECK" "$D" >"$D.txt" 2>&1; rcl=$?
w1=$(sed -n 's/^  L1 conformance *PASS .*, \([0-9]*\) warning(s).*/\1/p' "$D.txt")
w2=$(sed -n 's/^  L2 profile *PASS *0 errors, \([0-9]*\) warning(s).*/\1/p' "$D.txt")
{ [ "$rcl" -eq 0 ] && [ "${w1:-0}" -ge 1 ] && [ -n "$w2" ] && grep -q "but $((w1 + w2)) advisory(ies) and .* above (advisories: L1 $w1 + L2 $w2)\$" "$D.txt"; } \
  && ok "S30-CF-N2b $w1 L1 and $w2 L2 warning(s): the tally says $((${w1:-0} + ${w2:-0})) advisory(ies), L1 $w1 + L2 $w2" \
  || bad "S30-CF-N2b L1 + L2 tally" "rc=$rcl w1=$w1 w2=$w2 $(grep -E 'advisor' "$D.txt" | tr '\n' ' ')"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
