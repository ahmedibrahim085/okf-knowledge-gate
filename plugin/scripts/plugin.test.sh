#!/usr/bin/env bash
# Tests for the okf plugin package itself — structure, manifest, hook wiring.
#
# The authority here is `claude plugin validate --strict`, not my judgement:
# the docs state it checks plugin.json, skill/agent/command frontmatter, and
# hooks/hooks.json for syntax and schema errors, and that --strict turns
# warnings (unrecognized fields, misspellings) into failures. CI-grade.
#
# Run: plugin/scripts/plugin.test.sh
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
PLUGIN=$(cd -P "$HERE/.." && pwd)
PASS=0; FAIL=0
REALPY=$(command -v python3)
TMP_W=$(mktemp -d 2>/dev/null || mktemp -d -t okfplugintest)
trap 'rm -rf "$TMP_W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

SKIPPED=0
# A skip is COVERAGE THAT DID NOT RUN, and it was invisible in the summary: a
# run that quietly tested less printed the same "0 failed" as a run that tested
# everything. Measured this session — E-7d skipped 8/12 in one configuration and
# 0/12 in another — so "0 failed" alone has never been a complete claim. Count
# them and print them; then a green line means green AND complete.
skip() { SKIPPED=$((SKIPPED+1)); printf '  SKIP  %s\n' "$1"; }

echo "okf plugin package tests  ($PLUGIN)"

# --- structure, per the official file-locations reference --------------------
[ -f "$PLUGIN/.claude-plugin/plugin.json" ] && ok "P-1 manifest at .claude-plugin/plugin.json" \
  || bad "manifest at .claude-plugin/plugin.json" "missing"

# Docs, Troubleshooting: "Ensure skills/ or commands/ is at the plugin root, not
# inside .claude-plugin/" — a listed failure mode, so assert it explicitly.
[ -d "$PLUGIN/skills" ] && ok "skills/ is at the plugin ROOT" \
  || bad "skills/ is at the plugin ROOT" "no skills/ directory"
[ -d "$PLUGIN/.claude-plugin/skills" ] && bad "skills/ must NOT be inside .claude-plugin/" "found one there" \
  || ok "skills/ is not misplaced inside .claude-plugin/"

[ -f "$PLUGIN/hooks/hooks.json" ] && ok "hooks/hooks.json present" \
  || bad "hooks/hooks.json present" "missing"

# --- manifest is valid JSON and carries the required name --------------------
if [ -f "$PLUGIN/.claude-plugin/plugin.json" ]; then
  python3 -c "import json,sys; json.load(open('$PLUGIN/.claude-plugin/plugin.json'))" 2>/dev/null \
    && ok "plugin.json parses as JSON" || bad "plugin.json parses as JSON" "parse error"
  n=$(python3 -c "import json;print(json.load(open('$PLUGIN/.claude-plugin/plugin.json')).get('name',''))" 2>/dev/null)
  [ -n "$n" ] && ok "plugin.json declares a name ($n)" || bad "plugin.json declares a name" "absent"
fi

# --- hooks.json: valid JSON, and every referenced script exists + is +x ------
if [ -f "$PLUGIN/hooks/hooks.json" ]; then
  python3 -c "import json,sys; json.load(open('$PLUGIN/hooks/hooks.json'))" 2>/dev/null \
    && ok "P-6 hooks.json parses as JSON" || bad "hooks.json parses as JSON" "parse error"
  # "Hooks not firing | Script not executable | Run chmod +x script.sh" is a
  # documented failure mode — check it mechanically rather than trusting it.
  miss=0; noexec=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    p="$PLUGIN/${rel#./}"
    [ -f "$p" ] || { miss=$((miss+1)); echo "       missing: $rel"; continue; }
    [ -x "$p" ] || { noexec=$((noexec+1)); echo "       not executable: $rel"; }
  done <<EOF
$(python3 - "$PLUGIN/hooks/hooks.json" <<'PY'
import json,re,sys
d=json.load(open(sys.argv[1]))
out=set()
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k in ("command","args"):
                for s in ([v] if isinstance(v,str) else v if isinstance(v,list) else []):
                    for m in re.findall(r'\$\{CLAUDE_PLUGIN_ROOT\}(/[^"\s]+)', str(s)):
                        out.add("."+m)
            else: walk(v)
    elif isinstance(o,list):
        for x in o: walk(x)
walk(d)
print("\n".join(sorted(out)))
PY
)
EOF
  [ "$miss" -eq 0 ]   && ok "every hook script referenced by hooks.json exists" || bad "hook scripts exist" "$miss missing"
  [ "$noexec" -eq 0 ] && ok "every hook script is executable"                   || bad "hook scripts executable" "$noexec not +x"

  # Absolute paths are a documented error: "All paths must be relative and start
  # with ./". The previous check was a LINE-BASED grep, but hooks.json is
  # pretty-printed — `"args": [` and the path sit on different lines, so the
  # pattern could never match. Mutation-proven inert: swapping in a hard-coded
  # an absolute home path left the suite 16/16 green. Parse the JSON instead. (H2)
  abs=$(python3 - "$PLUGIN/hooks/hooks.json" <<'PY'
import json,sys,re
d=json.load(open(sys.argv[1]))
bad=[]
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k in ("command","args"):
                for s in ([v] if isinstance(v,str) else v if isinstance(v,list) else []):
                    if re.match(r'^/(Users|home|private|opt|var)/', str(s)): bad.append(str(s))
            else: walk(v)
    elif isinstance(o,list):
        for x in o: walk(x)
walk(d)
print("\n".join(bad))
PY
  )
  [ -z "$abs" ] && ok "hooks.json uses no absolute machine paths" \
    || bad "hooks.json uses no absolute machine paths" "$abs — breaks on every other machine"
  grep -q 'CLAUDE_PLUGIN_ROOT' "$PLUGIN/hooks/hooks.json" \
    && ok "hooks.json references scripts via \${CLAUDE_PLUGIN_ROOT}" \
    || bad "hooks.json uses \${CLAUDE_PLUGIN_ROOT}" "documented cause of 'MCP server fails / path errors'"
fi

# --- the skill has the frontmatter the loader requires -----------------------
for s in "$PLUGIN"/skills/*/SKILL.md; do
  [ -f "$s" ] || continue
  head -1 "$s" | grep -q '^---$' && ok "P-3 $(basename "$(dirname "$s")")/SKILL.md has frontmatter" \
    || bad "$(basename "$(dirname "$s")")/SKILL.md has frontmatter" "must open with ---"
  # BOTH, not either. The regex was an OR while the label promised "name+
  # description", so deleting `name:` left the suite 16/16 green. (H3)
  miss=""
  grep -qE '^name:' "$s"        || miss="$miss name"
  grep -qE '^description:' "$s" || miss="$miss description"
  [ -z "$miss" ] && ok "$(basename "$(dirname "$s")")/SKILL.md declares name AND description" \
    || bad "$(basename "$(dirname "$s")")/SKILL.md declares name AND description" "missing:$miss"
done

# --- self-containment: the plugin must work on a machine that has only it ----
[ -f "$PLUGIN/vendor/okf_validate.py" ] && ok "P-4 vendored validator travels with the plugin" \
  || bad "vendored validator travels with the plugin" "vendor/okf_validate.py missing — L1 would need a clone"
[ -f "$PLUGIN/config/okf-base.yaml.template" ] && ok "manifest template ships with the plugin" \
  || bad "manifest template ships with the plugin" "missing"

# --- the official validator is the final word --------------------------------
if command -v claude >/dev/null 2>&1; then
  out=$(claude plugin validate "$PLUGIN" --strict 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "P-5 claude plugin validate --strict passes" \
    || bad "claude plugin validate --strict passes" "$(printf '%s' "$out" | head -4 | tr '\n' ' ')"
  # Spec row P-2 was marked ✅ while NOTHING validated the marketplace manifest.
  MKT=$(cd -P "$PLUGIN/.." && pwd)
  if [ -f "$MKT/.claude-plugin/marketplace.json" ]; then
    out=$(claude plugin validate "$MKT" --strict 2>&1); rc=$?
    [ "$rc" -eq 0 ] && ok "claude plugin validate --strict passes for the MARKETPLACE" \
      || bad "marketplace validate --strict" "$(printf '%s' "$out" | head -4 | tr '\n' ' ')"
  fi
else
  skip "claude CLI absent — cannot run the official validator (a skip, not a pass)"
fi

# --- release discipline ------------------------------------------------------
# P-9: three version fields, in three files, that nothing compared. They agree
# today by luck. `claude plugin update` keys off the manifest version, so a
# disagreement is not cosmetic — it decides whether a shipped fix can ever
# reach an installed copy. Proven by mutation, not RED-first: the invariant
# already held when the test was written, and saying so is the honest form.
MKT_ROOT=$(cd -P "$PLUGIN/.." && pwd)
# PARSED AS JSON, not scraped with sed. `sed ... | head -1` took the FIRST
# "version" anywhere in the file, so a nested one (engines.claude-code.version)
# shadowed a genuinely drifted top-level value and P-9 passed over the very
# drift it exists to catch. The marketplace side used a `/"name":"okf"/,/}/`
# range, which stops at the first `}` — adding a documented optional `author`
# object before `version` emptied it and cried wolf on a valid manifest. These
# are manifests with a schema; read them with a parser. (W-1, W-2)
ver_plugin_json() {
  python3 - "$1" <<'PY' 2>/dev/null
import json,sys
try: print(json.load(open(sys.argv[1])).get("version",""))
except Exception: pass
PY
}
ver_marketplace() {   # <marketplace.json> <plugin-name>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for e in d.get("plugins",[]):
        if e.get("name")==sys.argv[2]: print(e.get("version","")); break
except Exception: pass
PY
}
pv=$(ver_plugin_json "$PLUGIN/.claude-plugin/plugin.json")
mv_=$(ver_marketplace "$MKT_ROOT/.claude-plugin/marketplace.json" okf)
cv=$("$PLUGIN/scripts/okf-check" --version 2>/dev/null | awk '{print $2}')
# The marketplace manifest lives at the REPO root, one level above the plugin.
# An INSTALLED copy has no such neighbour — and the tests ship inside the
# plugin, so every user who ran them saw "P-9 version fields disagree" with an
# empty marketplace value. Absent is not disagreeing. Found by running the
# shipped tests on a second machine that had only the plugin, then reproduced
# from this machine's own installed cache: it was failing for everyone.
MKT_MANIFEST="$MKT_ROOT/.claude-plugin/marketplace.json"
if [ ! -f "$MKT_MANIFEST" ]; then
  if [ -n "$pv" ] && [ "$pv" = "$cv" ]; then
    ok "P-9 plugin.json and okf-check --version agree ($pv)"
  else
    bad "P-9 version fields disagree" "plugin.json=$pv okf-check=$cv"
  fi
  skip "P-9 marketplace entry — no marketplace manifest beside this copy (installed plugin, not a source tree)"
elif [ -n "$pv" ] && [ "$pv" = "$mv_" ] && [ "$pv" = "$cv" ]; then
  ok "P-9 plugin.json, marketplace entry and okf-check --version agree ($pv)"
else
  bad "P-9 version fields disagree" "plugin.json=$pv marketplace=$mv_ okf-check=$cv"
fi

# P-10: the DEPLOYED copy is what actually runs. `git commit` does not update
# it, and neither does `claude plugin marketplace update` — both were observed
# leaving the cache on pre-fix code while the source tree was seven fixes
# ahead. Installed ≠ running was already a lesson here; committed ≠ installed
# is the next link in the same chain.
# Resolve the cache dir BY VERSION. `head -1` picked 0.1.0 — an older release
# Claude Code keeps alongside the current one — so the test compared source
# against a version nobody runs and failed after a correct redeploy.
# A version we could not read is a BROKEN GATE, not an absent install. With
# $pv empty the glob degraded to the okf cache root, found no scripts/ there,
# and printed "plugin not installed on this machine" — a check disabling itself
# and reporting a benign reason, exactly when the manifest it depends on is
# unreadable. Distinguish "cannot run" from "nothing to compare".
if [ -z "$pv" ]; then
  bad "P-10 cannot run — no version could be read from plugin.json" \
      "P-9 above explains why; P-10 is NOT a skip here, it is unable to check"
  CACHE=""
else
  CACHE=$(ls -d "$HOME/.claude/plugins/cache"/*/okf/"$pv"/ 2>/dev/null | head -1)
fi
if [ -n "$CACHE" ] && [ -d "$CACHE/scripts" ]; then
  # Compare the RUNTIME surface only. `*.test.sh` ships in the package but no
  # hook or skill invokes it, so a test edit is not "users run pre-fix code" —
  # and a gate that cries stale on every dev edit gets ignored, which is the
  # failure mode this whole repo exists to fight.
  drift=$(diff -rq -x '*.test.sh' "$CACHE/scripts" "$PLUGIN/scripts" 2>&1 | head -3 | tr '\n' ' ')
  [ -z "$drift" ] && ok "P-10 the INSTALLED plugin matches this source tree" \
    || bad "P-10 the installed plugin is STALE — users run pre-fix code" \
           "bump the version, then \`claude plugin update okf@<marketplace>\`; drift: $drift"
elif [ -n "$pv" ]; then
  # only a genuine "nothing installed to compare against" is a skip; the
  # unreadable-version case was already reported as a failure above
  skip "P-10 — plugin not installed on this machine (a skip, not a pass)"
fi

# W-1/W-2: the extractors themselves, against manifests crafted to break the
# old sed. Both shapes are legal per the official schema.
WF="$TMP_W"; mkdir -p "$WF"
# PRETTY-PRINTED on purpose. A single-line fixture does not reproduce the bug:
# sed's `.*` is greedy, so on one line it captures the LAST match and happens to
# be right. The old extractor failed on `head -1` picking the first matching
# LINE, which only exists in a multi-line manifest — the shape real ones have.
cat > "$WF/nested.json" <<'JSON'
{
  "engines": {
    "claude-code": {
      "version": "0.0.1"
    }
  },
  "name": "okf",
  "version": "9.9.9"
}
JSON
got=$(ver_plugin_json "$WF/nested.json")
[ "$got" = "9.9.9" ] && ok "W-1 a nested \"version\" does not shadow the top-level one" \
  || bad "W-1 nested version shadows the real one" "extracted '$got', expected 9.9.9"
cat > "$WF/mkt.json" <<'JSON'
{ "name": "m", "plugins": [
  { "name": "other", "version": "1.1.1" },
  { "name": "okf", "author": { "name": "a" }, "version": "9.9.9" } ] }
JSON
got=$(ver_marketplace "$WF/mkt.json" okf)
[ "$got" = "9.9.9" ] && ok "W-2 an object before \"version\" does not truncate the lookup" \
  || bad "W-2 marketplace lookup truncated by a nested object" "extracted '$got', expected 9.9.9"
got=$(ver_marketplace "$WF/mkt.json" other)
[ "$got" = "1.1.1" ] && ok "W-2b the lookup selects the named plugin, not the first" \
  || bad "W-2b marketplace lookup picked the wrong plugin" "extracted '$got', expected 1.1.1"

# Z-2: every non-test file under scripts/ ships to every install, so each one
# must be reachable from something. graphify_reconcile_ids.py was not: it
# arrived as a standalone graphify tool in 292dd65 and dcd102b swept the whole
# scripts/ directory into the package, carrying 13 KB of dead weight to every
# machine. Nothing caught it because nothing was looking.
#
# The reference set is DERIVED from hooks.json, the skills, and the scripts
# themselves — never a literal allow-list, which would rot the moment a script
# is renamed and would have to be edited to hide a new orphan.
orphans=""
# RECURSIVE. The first version globbed `scripts/*` only, so a dead file one
# directory down was never even considered — the glob matched the directory,
# `[ -f ]` rejected it, and the check moved on reporting clean. NUL-delimited so
# a filename with a space or newline is one candidate, not several.
while IFS= read -r -d '' f; do
  b=$(basename "$f")
  case "$b" in *.test.sh) continue ;; esac      # tests are run by a human or CI, not by the plugin
  # okf-check and okf-verify used to be excluded unconditionally, BEFORE any
  # reference check ran — so if the SKILL.md that documents them were ever
  # deleted, nothing would notice them becoming orphans. They earn their place
  # by being referenced, like everything else.
  refs=0
  for src in "$PLUGIN"/hooks/* "$PLUGIN"/skills/*/SKILL.md "$PLUGIN"/scripts/*; do
    [ -f "$src" ] || continue
    case "$src" in *.test.sh) continue ;; esac
    [ "$src" = "$f" ] && continue               # a file referencing itself proves nothing
    grep -qF "$b" "$src" 2>/dev/null && { refs=1; break; }
  done
  [ "$refs" -eq 0 ] && orphans="$orphans $b"
done < <(find "$PLUGIN/scripts" -type f -print0 2>/dev/null)
[ -z "$orphans" ] \
  && ok "Z-2 every shipped script is reachable from a hook, a skill, or another script" \
  || bad "Z-2 dead files ship to every install" \
         "unreferenced:$orphans — remove them or wire them up; git history keeps them"

# D-1: every scenario row the spec marks ✅ or ⚠ must be CITED by a test.
# This document has now been corrected three times for rows that claimed
# coverage nothing could verify — untraceable ✅ is its recurring defect, and
# fixing the instances without fixing the class just resets the clock. A
# measurement found 19 such rows; this makes the 20th impossible to land.
#
# Traceability, not correctness: it proves a row is CLAIMED by some assertion,
# which is what a ✅ asserts. Whether that assertion has teeth is what mutation
# testing is for.
SPEC="$MKT_ROOT/.okf/specs/okf-check.md"
if [ ! -f "$SPEC" ]; then
  skip "D-1 spec traceability — no spec beside this copy (installed plugin, not a source tree)"
else
  untraceable=$("$REALPY" - "$SPEC" "$PLUGIN/scripts" <<'PY' 2>/dev/null
import re, sys, pathlib
spec = pathlib.Path(sys.argv[1]).read_text()
sdir = pathlib.Path(sys.argv[2])
tests = "\n".join(f.read_text() for f in sorted(sdir.glob("*.test.sh")))
rows = re.findall(r'^\|\s*`?([A-Z]+-[0-9]+[a-z0-9]*)`?\s*\|.*?\|\s*(?:✅|⚠)', spec, re.M)
missing = [r for r in dict.fromkeys(rows) if not re.search(r'\b'+re.escape(r)+r'\b', tests)]
print(" ".join(missing))
PY
)
  if [ -z "$untraceable" ]; then
    ok "D-1 every ✅/⚠ scenario row in the spec is cited by a test"
  else
    bad "D-1 spec rows claim coverage no test cites" "untraceable: $untraceable"
  fi
fi

echo
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
