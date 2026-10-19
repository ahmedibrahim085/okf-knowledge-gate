#!/usr/bin/env bash
# Tests for the refusal of notes that are not regular files, the byte cap and the process cleanup
# (cases S17-NR-* in docs/0.9.x-cases.md and docs/gherkin/s17-non-regular.feature).
#
# Incident 2026-10-18: a note that was a symlink to /dev/zero made okflint grow to 112 GB and crashed the host.
# SAFETY: this suite runs on the host. The only device it touches is /dev/null (it returns EOF at once). A real
# /dev/zero, a FIFO, a socket and a memory-eating stub run only in a capped container:
# tools/capped-container-tests.sh. okflint is always a stub that logs the names it is handed and never reads a note.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`).
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
VERIFY="$HERE/okf-verify"
EXPORT="$HERE/okf-export"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"   # nothing here reads or writes the real home

# A stub okflint: answers the doctor's probes, logs the directory it validates and the names in it (never a note's
# bytes), and reports a clean bundle. STUB_LOG is the log file.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
{ echo "== $PWD"; ls -A; } >> "${STUB_LOG:-/dev/null}"
echo '[]'
STUB
chmod +x "$STUBBIN/okflint"

# mkb <dir>: a clean bundle (index, log, c.md) with the house manifest L2 needs.
mkb() {
  mkbundle "$1"
  sed 's/^  name: CHANGE ME/  name: T/' "$HERE/../config/okf-base.yaml.template" > "$1/okf-base.yaml"
}
# run <bundle> [args]: okf-check with the stub okflint first on PATH; stdout+stderr in $TMP/o.txt, status in $RC.
run() { : > "$TMP/stub.log"; env PATH="$STUBBIN:$PATH" STUB_LOG="$TMP/stub.log" timeout 60 "$CHECK" "$@" > "$TMP/o.txt" 2>&1; RC=$?; }
# bytes <file> <n>: a regular file of exactly n bytes (a note, so it starts with a frontmatter)
bytes() { "$REALPY" - "$1" "$2" <<'PY'
import sys
head = b"---\ntype: Lesson\ntitle: Big\ndescription: D\nstatus: stable\nstale_after: \"2099-01-01\"\n---\n"
n = int(sys.argv[2])
open(sys.argv[1], "wb").write((head + b"x" * max(0, n - len(head)))[:n])
PY
}

echo "non-regular notes"

section "okf-check refuses a note that is not a regular file"
# S17-NR-H1: a symlink to a character device. /dev/null is the only device the host may use (it returns EOF at once).
B="$TMP/h1"; mkb "$B"; ln -s /dev/null "$B/z.md"
run "$B"
{ [ "$RC" -eq 1 ] && grep -q 'z.md — not a regular file (device/pipe/...): skipped' "$TMP/o.txt"; } \
  && ok "S17-NR-H1 a symlink to a device is reported once and fails the run (exit 1)" \
  || bad "S17-NR-H1 device symlink" "rc=$RC $(grep -n 'z.md\|FAILED\|ALL GATES' "$TMP/o.txt" | head -3 | tr '\n' ' ')"
[ "$(grep -c 'z.md' "$TMP/o.txt")" -eq 1 ] && ok "S17-NR-H1b the refusal names the note once, not once per layer" \
  || bad "S17-NR-H1b named once" "$(grep -c 'z.md' "$TMP/o.txt") lines name z.md"
{ grep -qx 'c.md' "$TMP/stub.log" && ! grep -qx 'z.md' "$TMP/stub.log"; } \
  && ok "S17-NR-H1c okflint is handed the other notes and never the refused one" \
  || bad "S17-NR-H1c okflint listing" "stub saw: $(grep -v '^==' "$TMP/stub.log" | sort -u | tr '\n' ' ')"
run --json "$B"
"$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any("z.md" in e for e in d["errors"]), d["errors"]; assert d["exit"]==1' "$TMP/o.txt" 2>/dev/null \
  && ok "S17-NR-H1d --json lists the refusal under errors" || bad "S17-NR-H1d json" "$(head -c 300 "$TMP/o.txt")"

# S17-NR-H2: a folder named x.md is not a note and cannot hang a reader, so it is skipped with a visible WARN line and the
# exit code does not change (lead decision). Only devices, pipes and sockets use the "not a regular file" wording.
B="$TMP/h2"; mkb "$B"; mkdir "$B/x.md"
run "$B"
{ [ "$RC" -eq 0 ] && grep -q 'x.md — a folder, not a note: skipped' "$TMP/o.txt" && ! grep -q 'not a regular file' "$TMP/o.txt" && ! grep -q 'FAIL' "$TMP/o.txt"; } \
  && ok "S17-NR-H2 a folder named x.md is skipped with a WARN line and the exit stays 0" || bad "S17-NR-H2 folder x.md" "rc=$RC $(grep -n 'x.md\|FAILED\|regular' "$TMP/o.txt" | head -3 | tr '\n' ' ')"
run --json "$B"
"$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["exit"]==0 and d["errors"]==[], d' "$TMP/o.txt" 2>/dev/null \
  && ok "S17-NR-H2b --json: a folder named x.md is not an error (exit 0, errors empty)" || bad "S17-NR-H2b json" "$(head -c 300 "$TMP/o.txt")"

# S17-NR-H3: the byte cap. 5242880 bytes is allowed, one more is refused.
B="$TMP/h3"; mkb "$B"; bytes "$B/edge.md" 5242880
run "$B"
{ [ "$RC" -eq 0 ] && ! grep -q 'larger than' "$TMP/o.txt" && grep -qx 'edge.md' "$TMP/stub.log"; } && ok "S17-NR-H3a a note of exactly 5242880 bytes is read (and handed to okflint)" || bad "S17-NR-H3a at the cap" "rc=$RC $(grep -n 'edge.md\|larger' "$TMP/o.txt" | head -2)"
bytes "$B/edge.md" 5242881
run "$B"
{ [ "$RC" -eq 1 ] && grep -q 'edge.md — larger than 5242880 bytes (okf_check.max_note_bytes): skipped' "$TMP/o.txt"; } \
  && ok "S17-NR-H3b a regular note of 5242881 bytes is refused with the cap in the message" \
  || bad "S17-NR-H3b over the cap" "rc=$RC $(grep -n 'edge.md\|FAILED' "$TMP/o.txt" | head -3 | tr '\n' ' ')"
! grep -qx 'edge.md' "$TMP/stub.log" && ok "S17-NR-H3c okflint never sees the oversize note" || bad "S17-NR-H3c okflint listing" "edge.md was handed to okflint"

# S17-NR-N1: a bundle of regular notes prints no refusal line and keeps its verdict.
B="$TMP/n1"; mkb "$B"
run "$B"
{ [ "$RC" -eq 0 ] && ! grep -qi 'refused\|not a regular file' "$TMP/o.txt"; } && ok "S17-NR-N1 a clean bundle prints no refusal and passes (exit 0)" \
  || bad "S17-NR-N1 clean bundle" "rc=$RC $(grep -in 'refus\|regular' "$TMP/o.txt" | head -2)"

# S17-NR-N2: .okfignore wins: an ignored refused note is not a finding and is not read.
B="$TMP/n2"; mkb "$B"; mkdir "$B/archive"; ln -s /dev/null "$B/archive/z.md"; printf 'archive/\n' > "$B/.okfignore"
run "$B"
{ [ "$RC" -eq 0 ] && ! grep -q 'z.md' "$TMP/o.txt"; } && ok "S17-NR-N2 a device note inside an ignored folder is not reported" \
  || bad "S17-NR-N2 ignored device note" "rc=$RC $(grep -n 'z.md' "$TMP/o.txt" | head -2)"

# S17-NR-E1: a symlink to a regular note inside the bundle is still one note (0.9.11 rule) and is not refused.
B="$TMP/e1"; mkb "$B"; ln -s c.md "$B/alias.md"
run --json "$B"
c=$("$REALPY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["concepts"])' "$TMP/o.txt" 2>/dev/null)
{ [ "$RC" -eq 0 ] && [ "$c" = 2 ]; } && ok "S17-NR-E1 a symlink to a regular note still counts (2 concepts) and is not refused" \
  || bad "S17-NR-E1 note alias" "rc=$RC concepts=$c"

# S17-NR-E2: a symlink loop and a dangling link keep their old behaviour (skipped, not refused).
B="$TMP/e2"; mkb "$B"; ln -s loop.md "$B/loop.md"; ln -s nowhere.md "$B/dead.md"
run "$B"
! grep -q 'not a regular file' "$TMP/o.txt" && ok "S17-NR-E2 a link loop and a dangling link are not reported as non-regular" \
  || bad "S17-NR-E2 loop and dangling" "$(grep -n 'regular' "$TMP/o.txt" | head -2)"

# S17-NR-E3: the cap is a setting. okf_check.max_note_bytes lowers it, and a bad value is a config error.
B="$TMP/e3"; mkb "$B"; printf 'okf_check:\n  max_note_bytes: 2048\n' >> "$B/okf-base.yaml"; bytes "$B/mid.md" 3000
run "$B"
{ [ "$RC" -eq 1 ] && grep -q 'mid.md — larger than 2048 bytes (okf_check.max_note_bytes): skipped' "$TMP/o.txt"; } \
  && ok "S17-NR-E3a okf_check.max_note_bytes: 2048 refuses a 3000-byte note" || bad "S17-NR-E3a custom cap" "rc=$RC $(grep -n 'mid.md\|Config' "$TMP/o.txt" | head -3 | tr '\n' ' ')"
for v in 0 -5 1.5 '"big"' true; do
  B="$TMP/e3b"; mkb "$B"; printf 'okf_check:\n  max_note_bytes: %s\n' "$v" >> "$B/okf-base.yaml"
  run "$B"; rc1=$RC; grep -q 'max_note_bytes' "$TMP/o.txt"; g1=$?
  "$VERIFY" "$B" --check-config > "$TMP/v.txt" 2>&1; rc2=$?
  { [ "$rc1" -eq 2 ] && [ "$g1" -eq 0 ] && [ "$rc2" -ne 0 ] && grep -q 'max_note_bytes' "$TMP/v.txt"; } \
    && ok "S17-NR-E3b max_note_bytes: $v is rejected by okf-check (exit 2) and by okf-verify --check-config" \
    || bad "S17-NR-E3b max_note_bytes: $v" "okf-check rc=$rc1 named=$g1; okf-verify rc=$rc2"
done

section "the other tools that open a note"
# S17-NR-H4: --duplicates. It walks the original bundle, so it meets the device itself.
B="$TMP/h4"; mkb "$B"; ln -s /dev/null "$B/z.md"; bytes "$B/big.md" 5242881
env PATH="$STUBBIN:$PATH" timeout 60 "$CHECK" --duplicates "$B" > "$TMP/o.txt" 2> "$TMP/e.txt"; RC=$?
{ [ "$RC" -eq 0 ] && grep -q 'okf-duplicates: z.md — not a regular file (device/pipe/...): skipped' "$TMP/e.txt" \
  && grep -q 'okf-duplicates: big.md — larger than 5242880 bytes' "$TMP/e.txt"; } \
  && ok "S17-NR-H4 --duplicates names a device note and an oversize note on stderr and still exits 0" \
  || bad "S17-NR-H4 duplicates" "rc=$RC stderr: $(head -3 "$TMP/e.txt" | tr '\n' ' ')"

# S17-NR-H5: --file. A device is not a file (exit 64, never opened); an oversize note is an L1-level finding (exit 1).
B="$TMP/h5"; mkb "$B"; ln -s /dev/null "$B/z.md"; bytes "$B/big.md" 5242881
env PATH="$STUBBIN:$PATH" timeout 60 "$CHECK" "$B" --file "$B/z.md" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 64 ] && grep -q 'is not a file' "$TMP/o.txt"; } && ok "S17-NR-H5a --file on a device note: exit 64, 'is not a file'" || bad "S17-NR-H5a --file device" "rc=$RC $(head -2 "$TMP/o.txt")"
env PATH="$STUBBIN:$PATH" timeout 60 "$CHECK" "$B" --file "$B/big.md" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 1 ] && grep -q 'big.md: L1 error: refused, larger than 5242880 bytes (okf_check.max_note_bytes): skipped' "$TMP/o.txt"; } \
  && ok "S17-NR-H5b --file on an oversize note: one finding line, exit 1" || bad "S17-NR-H5b --file oversize" "rc=$RC $(head -2 "$TMP/o.txt")"

# S17-NR-H6: the edit hook warns Claude about an oversize note and stays silent for a device (it never opens either).
B="$TMP/h6"; mkb "$B"; printf 'okf_check:\n  edit_hook: true\n' >> "$B/okf-base.yaml"; ln -s /dev/null "$B/z.md"; bytes "$B/big.md" 5242881
printf '{"tool_input":{"file_path":"%s"}}' "$B/big.md" | env PATH="$STUBBIN:$PATH" timeout 60 "$REALPY" "$HERE/okf-edit-hook.py" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -q 'big.md: L1 error: refused, larger than' "$TMP/o.txt"; } && ok "S17-NR-H6a the edit hook warns about an oversize note (exit 2)" || bad "S17-NR-H6a hook oversize" "rc=$RC $(head -2 "$TMP/o.txt")"
printf '{"tool_input":{"file_path":"%s"}}' "$B/z.md" | env PATH="$STUBBIN:$PATH" timeout 60 "$REALPY" "$HERE/okf-edit-hook.py" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 0 ] && [ ! -s "$TMP/o.txt" ]; } && ok "S17-NR-H6b the edit hook ignores a device note (exit 0, silent)" || bad "S17-NR-H6b hook device" "rc=$RC $(head -2 "$TMP/o.txt")"

# S17-NR-H7: okf-verify reports a refused note as UNRESOLVED (nobody looked) and does not open it.
B="$TMP/h7"; mkb "$B"; ln -s /dev/null "$B/z.md"; bytes "$B/big.md" 5242881
timeout 60 "$VERIFY" "$B" > "$TMP/o.txt" 2>&1; RC=$?
{ grep -q 'z.md' "$TMP/o.txt" && grep -q 'refused: not a regular file (device/pipe/...)' "$TMP/o.txt" \
  && grep -q 'refused: larger than 5242880 bytes (okf_check.max_note_bytes)' "$TMP/o.txt"; } \
  && ok "S17-NR-H7 okf-verify names both refused notes as UNRESOLVED with the reason" \
  || bad "S17-NR-H7 verify" "rc=$RC $(grep -n 'z.md\|big.md\|refused' "$TMP/o.txt" | head -3 | tr '\n' ' ')"

# S17-NR-H8: okf-export leaves a refused note out and reports it with the other problems (exit 1).
V="$TMP/h8"; mkdir -p "$V"; printf -- '---\ntype: Lesson\ntitle: A\ndescription: D\n---\nbody\n' > "$V/a.md"; ln -s /dev/null "$V/z.md"; bytes "$V/big.md" 5242881
timeout 60 "$EXPORT" "$V" "$TMP/h8-out" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 1 ] && grep -q 'z.md — not a regular file (device/pipe/...): skipped' "$TMP/o.txt" && grep -q 'big.md — larger than 5242880 bytes' "$TMP/o.txt" \
  && [ -f "$TMP/h8-out/a.md" ] && [ ! -e "$TMP/h8-out/z.md" ] && [ ! -e "$TMP/h8-out/big.md" ]; } \
  && ok "S17-NR-H8 okf-export skips both refused notes, exports the rest and exits 1 with the reasons" \
  || bad "S17-NR-H8 export" "rc=$RC $(head -4 "$TMP/o.txt" | tr '\n' ' ') out: $(ls "$TMP/h8-out" 2>&1 | tr '\n' ' ')"

section "no layer reads the live bundle after the pre-scan (the race of review round 1)"
# S17-NR-R1: the pre-scan judges a path by stat; a layer that opened the live tree later could meet a note that had turned
# into /dev/zero in between (container case C9). So every layer reads a frozen copy. A sitecustomize on PYTHONPATH logs every
# open of a note or config file under the live bundle by any python process (the one copy helper excepted), and the
# okflint stub logs the folder it is run in. Both logs must stay free of the live bundle.
SPYDIR="$TMP/spy"; mkdir -p "$SPYDIR"
cat > "$SPYDIR/sitecustomize.py" <<'PYSPY'
import builtins, io, os, sys
_live, _log = os.environ.get("SPY_LIVE"), os.environ.get("SPY_LOG")
if _live and _log and not (len(sys.argv) > 1 and os.path.basename(sys.argv[0]) == "okf_guard.py" and sys.argv[1] == "freeze"):
    _root = os.path.realpath(_live) + os.sep
    def _seen(path, how):
        if isinstance(path, int):
            return
        f = sys._getframe(1)
        while f is not None:   # okf_guard.note_cap reads the manifest for the cap BEFORE the copy exists: the one allowed live read
            if f.f_code.co_name == "note_cap":
                return
            f = f.f_back
        try:
            p = os.fsdecode(os.fspath(path))
        except (TypeError, ValueError):
            return
        a = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(p))), os.path.basename(p))
        if a.startswith(_root) and a.endswith((".md", ".yaml", ".yml", ".json")):
            with _real_open(_log, "a") as fh:
                fh.write("%s %s %s\n" % (how, os.path.basename(sys.argv[0] or "-c"), a))
    _real_open, _os_open = builtins.open, os.open
    def _open(file, *a, **k):
        _seen(file, "open")
        return _real_open(file, *a, **k)
    class _osopen:   # not a function: pathlib stores os.open as a class attribute, and a function would be bound as a method
        def __call__(self, path, flags, mode=0o777, *, dir_fd=None):
            _seen(path, "os.open")
            return _os_open(path, flags, mode, dir_fd=dir_fd)
    builtins.open = io.open = _open
    os.open = _osopen()
PYSPY
B="$TMP/r1"; mkb "$B"; sed 's/^status: stable$/status: stable\nowner: team:t/' "$B/c.md" > "$B/c.new" && mv "$B/c.new" "$B/c.md"; mkdir "$B/sub"; cp "$B/c.md" "$B/sub/d.md"
printf 'okf_check:\n  deprecated_requires: superseded_by\n  require_owner: true\n  size:\n    max_body_chars: 100000\n' >> "$B/okf-base.yaml"
: > "$TMP/spy.log"; : > "$TMP/stub.log"
env PATH="$STUBBIN:$PATH" STUB_LOG="$TMP/stub.log" SPY_LIVE="$B" SPY_LOG="$TMP/spy.log" PYTHONPATH="$SPYDIR" timeout 120 "$CHECK" "$B" > "$TMP/o.txt" 2>&1; RC=$?
grep -q 'Successor' "$TMP/o.txt" && grep -q 'Owner' "$TMP/o.txt" && grep -q 'Size' "$TMP/o.txt" && grep -q 'L2 index' "$TMP/o.txt" \
  && ok "S17-NR-R1a the control run executed the successor, owner, size and index layers (the spy sees them)" || bad "S17-NR-R1a control" "rc=$RC $(grep -c . "$TMP/o.txt") lines"
[ ! -s "$TMP/spy.log" ] && ok "S17-NR-R1b no python layer opened a note or config file of the live bundle" \
  || bad "S17-NR-R1b python layers read the live bundle" "$(sort "$TMP/spy.log" | uniq -c | sort -rn | head -4 | tr '\n' ';')"
live_real=$(cd -P "$B" && pwd)
if grep -qxF "== $B" "$TMP/stub.log" || grep -qxF "== $live_real" "$TMP/stub.log"; then bad "S17-NR-R1c okflint runs on a frozen copy" "okflint was run in the live bundle"; else ok "S17-NR-R1c okflint is never run in the live bundle"; fi
[ "$RC" -eq 0 ] && ok "S17-NR-R1d the frozen run gives the same verdict as before (exit 0)" || bad "S17-NR-R1d verdict" "rc=$RC $(tail -3 "$TMP/o.txt" | tr '\n' ' ')"

# S17-NR-R2: the freeze is bounded and judged on the opened descriptor, so a note that is a character device when it is
# copied is refused, not copied. /dev/null is the one device the host may use: the helper is called directly with a list.
FZ="$TMP/fz"; mkdir -p "$FZ/src" "$FZ/dst"; printf 'a\n' > "$FZ/src/ok.md"; ln -s /dev/null "$FZ/src/dev.md"
printf 'N\tok.md\0N\tdev.md\0' | "$REALPY" "$HERE/okf_guard.py" freeze "$FZ/src" "$FZ/dst" 5242880 > "$FZ/refused.lst" 2> "$FZ/err.txt"; RC=$?
{ [ "$RC" -eq 0 ] && [ -f "$FZ/dst/ok.md" ] && [ ! -e "$FZ/dst/dev.md" ] && tr '\0' '\n' < "$FZ/refused.lst" | grep -q 'not a regular file.*dev.md'; } \
  && ok "S17-NR-R2 the copy helper refuses a device it meets while copying and copies the regular note" \
  || bad "S17-NR-R2 freeze helper" "rc=$RC $(tr '\0' '|' < "$FZ/refused.lst") $(head -1 "$FZ/err.txt") dst: $(ls "$FZ/dst" | tr '\n' ' ')"

section "okf-base.yaml is read like a note"
# S17-NR-M1: a manifest that is a device is refused up front in --duplicates (it used to be opened by a plain open().read()).
B="$TMP/m1"; mkb "$B"; rm "$B/okf-base.yaml"; ln -s /dev/null "$B/okf-base.yaml"
env PATH="$STUBBIN:$PATH" timeout 60 "$CHECK" --duplicates "$B" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -q 'okf-base.yaml — not a regular file (device/pipe/...)' "$TMP/o.txt"; } \
  && ok "S17-NR-M1a --duplicates refuses a manifest that is a device (exit 2, named)" || bad "S17-NR-M1a duplicates manifest" "rc=$RC $(head -3 "$TMP/o.txt" | tr '\n' ' ')"
run "$B"
{ [ "$RC" -eq 1 ] && grep -q 'okf-base.yaml — not a regular file (device/pipe/...): skipped' "$TMP/o.txt"; } \
  && ok "S17-NR-M1b a full run names the device manifest once and fails (exit 1)" || bad "S17-NR-M1b full run manifest" "rc=$RC $(grep -n 'okf-base' "$TMP/o.txt" | head -3 | tr '\n' ' ')"

# S17-NR-G1: .okfignore is judged like a note before bash reads it line by line (a link to a device would be read for ever).
B="$TMP/g1"; mkb "$B"; ln -s /dev/null "$B/.okfignore"
run "$B"
{ [ "$RC" -eq 2 ] && grep -q 'okfignore: .*is not a regular file (device/pipe/...): not read' "$TMP/o.txt"; } \
  && ok "S17-NR-G1 a .okfignore that is a device is not read: it is named and the run stops (exit 2)" || bad "S17-NR-G1 okfignore device" "rc=$RC $(head -3 "$TMP/o.txt" | tr '\n' ' ')"
# S17-NR-G2: a .okfignore that is not a regular file and not a link (here a folder; a FIFO behaves the same, container
# only) is refused like the device above, in every mode. It used to read as "no .okfignore" and the run passed.
B="$TMP/g2"; mkb "$B"; mkdir "$B/.okfignore"
for spec in "full run|" "--file|--file $B/c.md" "--duplicates|--duplicates"; do
  name=${spec%%|*}; args=${spec#*|}
  if [ "$name" = "--duplicates" ]; then run --duplicates "$B"; else run "$B" $args; fi
  { [ "$RC" -eq 2 ] && grep -q 'okfignore: .*\.okfignore is not a regular file (device/pipe/...): not read' "$TMP/o.txt"; } \
    && ok "S17-NR-G2 $name: a .okfignore that is a folder is refused, named, exit 2" || bad "S17-NR-G2 $name folder .okfignore" "rc=$RC $(head -4 "$TMP/o.txt" | tr '\n' ' ')"
done

section "okf-check stops before it writes anywhere it should not"
# S17-NR-T1: no temporary folder can be made. The run stops at once, named, exit 2, and nothing is written to "/refused.lst"
# (an empty $TMP made every "$TMP/x" a path at the filesystem root). A failing mktemp stub: macOS mktemp ignores a TMPDIR
# that does not exist and falls back to the user's temporary folder (measured), so a bad TMPDIR cannot make it fail here.
B="$TMP/t1"; mkb "$B"; NOTMP="$TMP/notmp"; mkdir -p "$NOTMP"; printf '#!/bin/sh\nexit 1\n' > "$NOTMP/mktemp"; chmod +x "$NOTMP/mktemp"
env PATH="$NOTMP:$STUBBIN:$PATH" timeout 60 "$CHECK" "$B" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -q 'cannot make a temporary folder' "$TMP/o.txt" && ! grep -q 'refused.lst' "$TMP/o.txt"; } \
  && ok "S17-NR-T1 no temporary folder: named, exit 2, nothing written at /" || bad "S17-NR-T1 bad TMPDIR" "rc=$RC $(head -4 "$TMP/o.txt" | tr '\n' ' ')"
# S17-NR-T2: a plugin copy without okf-limit.py says so, exit 2 (it was reported as "manifest rejected by okflint").
D="$TMP/nolimit"; mkdir -p "$D"; cp -R "$HERE/.." "$D/plugin" 2>/dev/null; rm -f "$D/plugin/scripts/okf-limit.py"
env PATH="$STUBBIN:$PATH" timeout 60 "$D/plugin/scripts/okf-check" "$B" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -q 'okf-limit.py is missing' "$TMP/o.txt"; } \
  && ok "S17-NR-T2 okf-limit.py missing: named, exit 2" || bad "S17-NR-T2 okf-limit.py missing" "rc=$RC $(head -4 "$TMP/o.txt" | tr '\n' ' ')"

section "the report says what happened"
# S17-NR-O1: an okflint that is killed from outside (the kernel's OOM killer: exit 137, no limit marker of ours) is not "timed out".
KILLBIN="$TMP/killbin"; mkdir -p "$KILLBIN"
cat > "$KILLBIN/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
kill -KILL $$
STUB
chmod +x "$KILLBIN/okflint"
B="$TMP/o1"; mkb "$B"
env PATH="$KILLBIN:$PATH" timeout 60 "$CHECK" "$B" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 2 ] && grep -q 'okflint was killed (out of memory or time limit)' "$TMP/o.txt" && ! grep -q 'timed out' "$TMP/o.txt"; } \
  && ok "S17-NR-O1 an okflint killed from outside is reported as killed, not as timed out" || bad "S17-NR-O1 killed wording" "rc=$RC $(grep -n 'L2' "$TMP/o.txt" | head -2 | tr '\n' ' ')"

# S17-NR-I1: .okfignore that matched nothing, and a refused link: the report must not say "0 file(s) excluded" while a path was left out.
B="$TMP/i1"; mkb "$B"; ln -s /dev/null "$B/z.md"; printf 'nothing-here/\n' > "$B/.okfignore"
run "$B"
{ [ "$RC" -eq 1 ] && grep -q 'no file matched its patterns' "$TMP/o.txt" && ! grep -q '0 file(s) excluded' "$TMP/o.txt"; } \
  && ok "S17-NR-I1 .okfignore that matched nothing says so, and does not claim 0 files excluded beside a refused path" \
  || bad "S17-NR-I1 ignore wording" "rc=$RC $(grep -n 'ignore' "$TMP/o.txt" | head -3 | tr '\n' ' ')"

section "okflint is stopped as a whole tree, and never outlives okf-check"
# procs <text>: how many running processes have <text> in their command line (SKIP when this machine offers no way to look).
procs() {
  if ps -axo command >/dev/null 2>&1; then
    ps -axo command | grep -F -- "$1" | grep -v grep | grep -c .
  elif [ -r /proc/self/cmdline ]; then
    for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$f" 2>/dev/null; echo; done | grep -F -- "$1" | grep -v grep | grep -c .
  else
    echo SKIP
  fi
}
# A slow okflint: the doctor's probes answer at once, a validate run records that it started and then sleeps 30 s in a
# CHILD process (the shape of the uv shim: the process that holds the memory is not the one okf-check started).
SLOWBIN="$TMP/slowbin"; mkdir -p "$SLOWBIN"
cat > "$SLOWBIN/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
[ -f "$PWD/slow-trigger" ] || { echo '[]'; exit 0; }
echo started >> "$STUB_STARTED"
sleep "$STUB_SLEEP"
STUB
chmod +x "$SLOWBIN/okflint"
mkslow() { mkb "$1"; : > "$1/slow-trigger"; }
# The signal is sent to okf-check's own pid only (not its group): what a CI cancel or `kill <pid>` does. Python sends it
# because a non-interactive shell cannot deliver SIGINT to a background job.
sigrun() { # <signal> <bundle> <sleep marker>
  STUB_SLEEP="$3" STUB_STARTED="$TMP/started" PATH="$SLOWBIN:$PATH" "$REALPY" - "$1" "$CHECK" "$2" <<'PY'
import os, signal, subprocess, sys, time
sig = getattr(signal, "SIG" + sys.argv[1])
# SIGINT back to its default: a suite started as a background job inherits "ignored" and bash cannot trap an ignored signal
p = subprocess.Popen([sys.argv[2], sys.argv[3]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
t0 = time.time()
while not os.path.exists(os.environ["STUB_STARTED"]) and time.time() - t0 < 60 and p.poll() is None:
    time.sleep(0.2)
p.send_signal(sig)
try:
    p.wait(timeout=20)
except subprocess.TimeoutExpired:
    p.kill(); p.wait()
    print("okf-check ignored the signal")
PY
}

# S17-NR-P1: the limit kills the command's children too (okf-check:578 killed only the direct child).
B="$TMP/p1"; mkslow "$B"; rm -f "$TMP/started"
STUB_SLEEP=3117 STUB_STARTED="$TMP/started" PATH="$SLOWBIN:$PATH" OKF_L2_TIMEOUT=2 timeout 60 "$CHECK" "$B" > "$TMP/o.txt" 2>&1; RC=$?
left=$(procs 'sleep 3117')
if [ "$left" = SKIP ]; then skip "S17-NR-P1 no way to list processes here"
elif [ "$RC" -eq 2 ] && [ "$left" -eq 0 ] && grep -q 'timed out after 2 s' "$TMP/o.txt"; then ok "S17-NR-P1 after the L2 limit okf-check exits 2 and no child of okflint is left running"
else bad "S17-NR-P1 limit kills the tree" "rc=$RC left=$left $(grep -n 'L2' "$TMP/o.txt" | head -2 | tr '\n' ' ')"; pkill -f 'sleep 3117' 2>/dev/null; fi

# S17-NR-P2/P3: an outside TERM or INT to okf-check alone leaves nothing behind.
for sg in TERM INT; do
  B="$TMP/p23"; mkslow "$B"; rm -f "$TMP/started"
  got=$(sigrun $sg "$B" 3118); sleep 2; left=$(procs 'sleep 3118')
  if [ "$left" = SKIP ]; then skip "S17-NR-P2 $sg: no way to list processes here"
  elif [ "$left" -eq 0 ] && [ -z "$got" ]; then ok "S17-NR-P2 $sg to okf-check alone: it stops and no okflint child is left 2 s later"
  else bad "S17-NR-P2 $sg" "left=$left $got"; pkill -f 'sleep 3118' 2>/dev/null; fi
done

# S17-NR-P4: the memory watchdog. A stub that holds 80 MB under OKF_L2_MAX_RSS_MB=25 is stopped, named, exit 2.
MEMBIN="$TMP/membin"; mkdir -p "$MEMBIN"
cat > "$MEMBIN/okflint" <<'STUB'
#!/bin/sh
case "$*" in *--version*|*--help*|*validate-manifest*) echo "okflint 0.5.0"; exit 0;; esac
[ -f "$PWD/mem-trigger" ] || { echo '[]'; exit 0; }
exec python3 -c 'import time; b = bytearray(b"x") * (80 * 1024 * 1024); time.sleep(120)'
STUB
chmod +x "$MEMBIN/okflint"
B="$TMP/p4"; mkb "$B"; : > "$B/mem-trigger"
t0=$SECONDS; PATH="$MEMBIN:$PATH" OKF_L2_MAX_RSS_MB=25 timeout 90 "$CHECK" "$B" > "$TMP/o.txt" 2>&1; RC=$?; dt=$((SECONDS-t0))
left=$(procs 'bytearray(b"x")')
if [ "$left" = SKIP ]; then skip "S17-NR-P4 no way to list processes here"
elif [ "$RC" -eq 2 ] && [ "$dt" -lt 30 ] && [ "$left" -eq 0 ] && grep -q 'COULD NOT RUN — okflint exceeded 25 MB' "$TMP/o.txt"; then
  ok "S17-NR-P4 a stub holding 80 MB is stopped at OKF_L2_MAX_RSS_MB=25: COULD NOT RUN, exit 2, ${dt} s, nothing left"
else bad "S17-NR-P4 memory watchdog" "rc=$RC ${dt}s left=$left $(grep -n 'L2' "$TMP/o.txt" | head -2 | tr '\n' ' ')"; pkill -f 'bytearray(b"x")' 2>/dev/null; fi
# the same stub under the default limit (2048 MB) is not touched: the watchdog does not fire on a healthy run
B="$TMP/p4b"; mkb "$B"
PATH="$MEMBIN:$PATH" timeout 60 "$CHECK" "$B" > "$TMP/o.txt" 2>&1; RC=$?
{ [ "$RC" -eq 0 ] && ! grep -q 'exceeded' "$TMP/o.txt"; } && ok "S17-NR-P4b a normal run under the default memory limit is unaffected (exit 0)" || bad "S17-NR-P4b default limit" "rc=$RC"

section "--selftest"
# S17-NR-ST: the probe fires on the real code, and a copy whose refusal is crippled exits 5 (a gate nobody watched fire).
# Real okflint (the selftest runs its L2 probes); the stub is not on the PATH here.
if ! command -v okflint >/dev/null 2>&1; then
  skip "S17-NR-ST needs okflint (install: uv tool install okflint)"
else
  timeout 300 "$CHECK" --selftest > "$TMP/st.txt" 2>&1; RC=$?
  # The probe's heading is user-visible: it names the check, not a ticket of the private repository.
  { [ "$RC" -eq 0 ] && grep -q 'FIRED  *device and folder refused' "$TMP/st.txt" && grep -qxF '  Refused notes:' "$TMP/st.txt"; } \
    && ok "S17-NR-ST1 --selftest has the refusal probe under the heading 'Refused notes:', it fires, and the run passes (exit 0)" \
    || bad "S17-NR-ST1 selftest probe" "rc=$RC $(grep -n 'refus\|SELFTEST' "$TMP/st.txt" | head -3 | tr '\n' ' ')"
  D="$TMP/crip"; mkdir -p "$D"; cp -R "$HERE/.." "$D/plugin" 2>/dev/null
  sed -i.orig "s|\[ -f \"\$f\" \] \|\| { printf 'not a regular file (device/pipe/...)'; return 0; }|:|" "$D/plugin/scripts/note-guard-lib.sh"
  if cmp -s "$D/plugin/scripts/note-guard-lib.sh" "$D/plugin/scripts/note-guard-lib.sh.orig"; then
    bad "S17-NR-ST2 crippled copy" "the cripple changed nothing"
  else
    timeout 300 "$D/plugin/scripts/okf-check" --selftest > "$TMP/st-dead.txt" 2>&1; RC=$?
    { [ "$RC" -eq 5 ] && grep -q 'NOT FIRED  *device and folder refused' "$TMP/st-dead.txt"; } \
      && ok "S17-NR-ST2 with the refusal crippled the probe reports NOT FIRED and --selftest exits 5" \
      || bad "S17-NR-ST2 crippled refusal" "rc=$RC $(grep -n 'refus\|SELFTEST' "$TMP/st-dead.txt" | head -3 | tr '\n' ' ')"
  fi
fi

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
