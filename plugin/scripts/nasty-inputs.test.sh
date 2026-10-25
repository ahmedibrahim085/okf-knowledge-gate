#!/usr/bin/env bash
# Every reader loops over one list of nasty input forms (plugin/tests/nasty-inputs.tsv): names that fold, bytes that are not UTF-8,
# links that leave or loop, a note of 1 MB on one line. Why a list: 99 of the 178 shipped defects of the 2026-10-24
# analysis were a reader that handled the forms its author tried; the forms were named by review, after the fact
# (pattern "input forms not listed").
#
# The verdict required per form and reader is the same everywhere: an answer in the reader's documented exit codes,
# no Traceback, nothing changed inside the bundle, nothing changed outside it, and an end within 90 s. A form the disk
# refuses to create is SKIPPED with its reason, never passed.
#
# Part A: the readers as a user runs them (okf-check, okf-verify, okf-export) over every form.
# Part B: the two historic bugs that need more than "does not crash", replayed from the same list:
#   B1 (BL-722): okf-export's case probe must agree with the disk for every name form.
#   B2 (LT-14, 0.5.12 fixed in 0.5.18): crash isolation must never delete a file outside the bundle through a link.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
CHECK="$HERE/okf-check"
VERIFY="$HERE/okf-verify"
EXPORT="$HERE/okf-export"
FORMS="$HERE/../tests/nasty-inputs.tsv"
REALPY=$(command -v python3)
PASS=0; FAIL=0; SKIP=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfnasty)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP  %s\n' "$1"; }

# --- fixtures: one python helper builds a form into a bundle, another runs a reader and compares trees ----------
cat > "$TMP/mkform.py" <<'PY'
import os, sys, pathlib
slot, spec, d, outside = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
FM = "---\ntype: Lesson\ntitle: T\ndescription: D\ntags: [t]\n---\n"
def decode(s):
    return s.encode("ascii").decode("unicode_escape")
def note(path, text=None, raw=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw if raw is not None else (text or FM + "body\n").encode("utf-8"))
note(d / "good.md")
note(outside / "precious.md", FM + "precious\n")
note(outside / "crashy.md", FM + "CRASHME\n")
try:
    if slot in ("name", "name-bytes"):
        if slot == "name-bytes":
            n = os.fsdecode(decode(spec).encode("latin-1"))
        elif spec.startswith("LONG:"):
            n = "a" * int(spec[5:])
        else:
            n = decode(spec)
        note(d / (n + ".md"))
        note(d / n / "inner.md")
    elif slot == "input-file":
        raws = {
            "bom": ("\ufeff" + FM + "body\n").encode("utf-8"),
            "crlf": (FM + "body\n").replace("\n", "\r\n").encode("utf-8"),
            "latin1": FM.encode("utf-8") + b"caf\xe9 \xff\n",
            "nul": FM.encode("utf-8") + b"a\x00b\n",
            "empty": b"",
            "longline": FM.encode("utf-8") + b"x" * 1000000 + b"\n",
            "tab": b"---\ntype: Lesson\ntitle: T\ndescription: D\ntags:\n\t- t\n---\nbody\n",
            "unclosed": b"---\ntype: Lesson\ntitle: T\ndescription: D\nbody that never closes the block\n",
            "fm-only": FM.encode("utf-8"),
        }
        note(d / "form.md", raw=raws[spec])
    elif slot == "shape":
        if spec == "symlink-folder-out":
            os.symlink(outside, d / "linked")
        elif spec == "symlink-file-out":
            os.symlink(outside / "precious.md", d / "out-note.md")
        elif spec == "dangling-link":
            os.symlink(d / "nowhere.md", d / "dangling.md")
        elif spec == "link-loop":
            os.symlink("loop-b.md", d / "loop-a.md")
            os.symlink("loop-a.md", d / "loop-b.md")
        elif spec == "self-folder-link":
            os.symlink(d, d / "self")
        elif spec == "chmod000":
            if os.getuid() == 0:
                print("SKIP running as root: mode 000 is readable")
                sys.exit(0)
            note(d / "locked.md")
            os.chmod(d / "locked.md", 0)
        elif spec == "hard-link":
            os.link(d / "good.md", d / "hard.md")
        else:
            print("SKIP unknown shape " + spec)
            sys.exit(0)
    else:
        print("SKIP unknown slot " + slot)
        sys.exit(0)
except OSError as e:
    print("SKIP the disk refused the form: " + str(e).split(":")[0])
    sys.exit(0)
print("OK")
PY

cat > "$TMP/drive.py" <<'PY'
import hashlib, os, pathlib, subprocess, sys
# drive.py <bundle> <tree> <timeout> -- <command...>: runs the reader, prints "rc=N traceback=0|1 inside=0|1 outside=0|1".
# tree is the folder that holds the bundle and the files around it; "outside" is everything in tree except the bundle,
# so a reader that writes NEXT TO the bundle is caught as well as one that writes into a linked folder.
bundle, tree, timeout = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
cmd = sys.argv[5:]
def digest(root, skip=None):
    h = hashlib.sha256()
    for dirpath, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if skip is None or os.path.join(dirpath, d) != str(skip))
        for name in sorted(files + [x for x in dirs if os.path.islink(os.path.join(dirpath, x))]):
            p = os.path.join(dirpath, name)
            h.update(os.path.relpath(p, root).encode("utf-8", "surrogateescape") + b"\0")
            if os.path.islink(p):
                h.update(b"link:" + os.readlink(p).encode("utf-8", "surrogateescape"))
                continue
            try:
                h.update(str(os.stat(p).st_mode).encode() + pathlib.Path(p).read_bytes())
            except OSError:
                h.update(b"unreadable")
    return h.hexdigest()
b0, o0 = digest(bundle), digest(tree, skip=bundle)
try:
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    rc, text = r.returncode, r.stdout.decode("utf-8", "replace")
except subprocess.TimeoutExpired as e:
    rc, text = 124, (e.stdout or b"").decode("utf-8", "replace")
sys.stderr.write(text[-1500:])
print("rc=%d traceback=%d inside=%d outside=%d" % (rc, int("Traceback (most recent call last)" in text),
                                                   int(digest(bundle) != b0), int(digest(tree, skip=bundle) != o0)))
PY

# $1 reader, $2 form id, $3 slot, $4 spec. Builds the form in a fresh bundle, runs the reader, judges the answer.
judge() {
  local reader="$1" id="$2" slot="$3" spec="$4" run="$TMP/run.$reader.$2" made verdict allowed rc
  mkdir -p "$run/in/b" "$run/in/outside"
  made=$("$REALPY" "$TMP/mkform.py" "$slot" "$spec" "$run/in/b" "$run/in/outside" 2>&1)
  case "$made" in
    SKIP*) skip "$reader / $id: ${made#SKIP }"; return ;;
    OK) ;;
    *) bad "$reader / $id" "the fixture itself failed: $made"; return ;;
  esac
  case "$reader" in
    okf-check)  allowed="0 1 2 3 4 6"; verdict=$("$REALPY" "$TMP/drive.py" "$run/in/b" "$run/in" 90 -- "$CHECK" "$run/in/b" 2>"$run/err") ;;
    okf-verify) allowed="0 1 2";       verdict=$("$REALPY" "$TMP/drive.py" "$run/in/b" "$run/in" 90 -- "$VERIFY" "$run/in/b" 2>"$run/err") ;;
    okf-export) allowed="0 1 2";       verdict=$("$REALPY" "$TMP/drive.py" "$run/in/b" "$run/in" 90 -- "$EXPORT" "$run/in/b" "$run/export" 2>"$run/err") ;;
  esac
  rc=${verdict#rc=}; rc=${rc%% *}
  case " $allowed " in *" $rc "*) ;; *) bad "$reader / $id" "exit $rc is not one of: $allowed. $verdict. last output: $(tail -c 300 "$run/err" | tr '\n' '|')"; return ;; esac
  case "$verdict" in *"traceback=0 inside=0 outside=0") ok "$reader / $id: exit $rc, no traceback, nothing changed inside or outside" ;;
    *) bad "$reader / $id" "$verdict. last output: $(tail -c 300 "$run/err" | tr '\n' '|')" ;; esac
}

[ -f "$FORMS" ] || { echo "no $FORMS" >&2; exit 2; }
NFORMS=0
while IFS=$'\t' read -r id slot spec build why; do
  case "$id" in ''|'#'*) continue ;; esac
  NFORMS=$((NFORMS+1))
  for reader in okf-check okf-verify okf-export; do judge "$reader" "$id" "$slot" "$spec"; done
done < "$FORMS"
[ "$NFORMS" -ge 20 ] && ok "the list holds $NFORMS forms (at least 20)" || bad "the list is too short" "$NFORMS forms in nasty-inputs.tsv"

# --- B1: the case probe agrees with the disk for every name form (BL-722) -------------------
cat > "$TMP/probe.py" <<'PY'
import importlib.machinery, importlib.util, os, pathlib, sys
loader = importlib.machinery.SourceFileLoader("okf_export", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("okf_export", loader))
loader.exec_module(mod)
root = pathlib.Path(sys.argv[2])
(root / "a").touch()
want = (root / "A").exists()   # the disk itself: does it fold case?
(root / "a").unlink()
bad = []
for line in open(sys.argv[3], encoding="utf-8"):
    if not line.strip() or line.startswith("#"):
        continue
    id_, slot, spec = line.rstrip("\n").split("\t")[:3]
    if slot != "name":
        continue
    n = ("a" * int(spec[5:])) if spec.startswith("LONG:") else spec.encode("ascii").decode("unicode_escape")
    f = root / n
    try:
        f.mkdir()
    except OSError:
        continue
    try:
        got = mod.case_insensitive(f / "out")
    finally:
        f.rmdir()
    if got != want:
        bad.append("%s: probe says %s, disk says %s" % (id_, got, want))
print("BAD " + "; ".join(bad) if bad else "OK")
PY
mkdir -p "$TMP/probe"
res=$("$REALPY" "$TMP/probe.py" "$EXPORT" "$TMP/probe" "$FORMS" 2>&1)
[ "$res" = OK ] && ok "B1 okf-export's case probe agrees with the disk under every name form" \
  || bad "B1 the case probe disagrees with the disk" "$res"

# --- B2: crash isolation never deletes a file outside the bundle (LT-14) -------------------
P2="$TMP/plug2"; cp -R "$HERE/.." "$P2"
mv "$P2/vendor/okf_validate.py" "$P2/vendor/real_validator.py"
cat > "$P2/vendor/okf_validate.py" <<'PYSTUB'
# l3-lib.sh reads the spec status list from the validator, so a stub carries it
STATUS_VALUES = {"draft", "stable", "deprecated"}
import runpy, sys, pathlib
args = sys.argv[1:]
root = pathlib.Path(args[0])
for f in root.rglob("*.md"):
    if "CRASHME" in f.read_text(errors="replace"):
        raise RuntimeError("stub validator crash on " + f.name)
sys.argv = [str(pathlib.Path(__file__).with_name("real_validator.py"))] + args
runpy.run_path(sys.argv[0], run_name="__main__")
PYSTUB
b2="$TMP/b2"; mkdir -p "$b2/b" "$b2/outside"
"$REALPY" "$TMP/mkform.py" shape symlink-folder-out "$b2/b" "$b2/outside" >/dev/null
printf -- '---\ntype: Lesson\ntitle: A\ndescription: D\n---\nCRASHME\n' > "$b2/b/bad.md"
"$P2/scripts/okf-check" "$b2/b" > "$b2/out.txt" 2>&1
[ -f "$b2/outside/precious.md" ] && [ -f "$b2/outside/crashy.md" ] \
  && ok "B2 files behind a symlinked folder survive crash isolation (okf-check, crashing note in the bundle)" \
  || bad "B2 files outside the bundle were deleted" "precious.md and crashy.md after the run: $(ls "$b2/outside" | tr '\n' ' ')"

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
