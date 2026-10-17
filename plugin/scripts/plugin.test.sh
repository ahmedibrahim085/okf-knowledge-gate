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
p10_installed_versions() { ls -d "$1"/*/okf/*/ 2>/dev/null | sed 's#.*/okf/##; s#/$##' | tr '\n' ' '; }
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
  # Only a genuine "nothing installed at all" is a skip; the unreadable-version case was reported above. An OLDER okf
  # in the cache is the commonest stale state (the version was bumped and the plugin never reinstalled): that is a
  # failure, not a skip (0.9.2 F7).
  inst=$(p10_installed_versions "$HOME/.claude/plugins/cache")
  if [ -n "$inst" ]; then
    bad "P-10 the installed plugin is STALE — only other versions are installed" \
        "source is $pv, the cache holds: $inst; reinstall: claude plugin uninstall okf@<marketplace> && claude plugin install okf@<marketplace>"
  else
    skip "P-10 — plugin not installed on this machine (a skip, not a pass)"
  fi
fi
# P-10b: the cache listing itself, against a fixture cache (the live one above depends on this machine).
mkdir -p "$TMP_W/p10cache/mk/okf/0.0.1/scripts" "$TMP_W/p10cache/mk/okf/0.0.2/scripts"
[ "$(p10_installed_versions "$TMP_W/p10cache")" = "0.0.1 0.0.2 " ] && ok "P-10b the cache listing names every installed okf version" || bad "P-10b cache listing" "got '$(p10_installed_versions "$TMP_W/p10cache")'"
[ -z "$(p10_installed_versions "$TMP_W/p10none")" ] && ok "P-10c an empty cache lists nothing (that is the skip case)" || bad "P-10c empty cache" "listed something"

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
# arrived as a standalone graphify tool and a later commit swept the whole
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
# The public export keeps the spec at docs/spec.md.
SPEC="$MKT_ROOT/.okf/specs/okf-check.md"
[ -f "$SPEC" ] || SPEC="$MKT_ROOT/docs/spec.md"
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

# --- 0.9.0 T5: GitHub Action + pre-commit entry (cases S19-S22) ---
# Both are thin doors onto `okf-check`: they add no logic, so the verdict is the same one Claude Code gets.
# Platform contracts (docs.github.com composite actions; pre-commit.com "creating new hooks"): the step sets
# `shell: bash` (runs -eo pipefail), inputs reach the script through env (INPUT_*), GITHUB_ACTION_PATH is
# set explicitly from github.action_path, `language: script` is an alias that works today, `files:` is the
# documented selector. A root action.yml is the docs' own shape (the composite-action page's hello-world
# example is used as OWNER/REPO@SHA). pre-commit's source (pre_commit/repository.py `_hook`, dict.update)
# says a user's `args` REPLACES the hook's default; `entry`'s first token is resolved from the hook repo
# root and args come after it (lang_base.hook_cmd). The real pre-commit tool is not installed here.
ACT="$MKT_ROOT/action.yml"; PCH="$MKT_ROOT/.pre-commit-hooks.yaml"
pyyaml() { PYTHONPATH="$PLUGIN/vendor/pyyaml" "$REALPY" "$@"; }
if [ -f "$ACT" ]; then
  pyyaml - "$ACT" <<'PY' 2>"$TMP_W/act_err.txt"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["runs"]["using"] == "composite", d["runs"]
assert d["inputs"]["bundle"]["required"] is True
for k in ("strict-trust", "fail-stale"):
    assert str(d["inputs"][k]["default"]) == "false", k
steps = d["runs"]["steps"]
assert steps and all(st.get("shell") == "bash" for st in steps if "run" in st)
run = steps[0]["run"]
assert "${{" not in run, "inputs must reach the script through env, never interpolated into it"
env = steps[0]["env"]
assert env["INPUT_BUNDLE"] == "${{ inputs.bundle }}" and env["GITHUB_ACTION_PATH"] == "${{ github.action_path }}"
PY
  [ $? -eq 0 ] && ok "LT-29a action.yml is a composite action: bundle required, strict-trust and fail-stale default false, shell bash, inputs via env (no interpolation into the script)" \
    || bad "LT-29a action.yml structure" "$(head -2 "$TMP_W/act_err.txt" | tr '\n' ' ')"
  pyyaml -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])' "$ACT" > "$TMP_W/act_run.sh" 2>/dev/null
else
  bad "LT-29a action.yml structure" "$ACT does not exist"; : > "$TMP_W/act_run.sh"
fi
# Run the action's own script locally, exactly as the runner does (bash -eo pipefail), with its env contract.
runact() { # <bundle> <strict> <stale> [action-root] [require-house-rules]
  ( cd "$TMP_W" && env INPUT_BUNDLE="$1" INPUT_STRICT_TRUST="$2" INPUT_FAIL_STALE="$3" GITHUB_ACTION_PATH="${4:-$MKT_ROOT}" ${5:+INPUT_REQUIRE_HOUSE_RULES="$5"} \
      bash --noprofile --norc -eo pipefail "$TMP_W/act_run.sh" ) >"$TMP_W/act_out.txt" 2>&1
}
mkab() { mkdir -p "$1"; printf -- '---\nokf_version: "0.2"\n---\n# B\n' > "$1/index.md"; printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$1/log.md"; }
mkabnote() { # <bundle> <status> <generated.by> <stale_after>
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: %s\ntags: [t]\ngenerated:\n  by: %s\n  at: "2026-01-01"\nverified:\n  - by: human:dana\n    at: "2026-02-01"\nstale_after: "%s"\n---\n\nbody\n' "$2" "$3" "$4" > "$1/n.md"
}
AB1="$TMP_W/ab1"; mkab "$AB1"; mkabnote "$AB1" stable human:t 2099-01-01
runact "$AB1" false false; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'okf-check' "$TMP_W/act_out.txt"; } && ok "LT-29b S19-H1/S20-N1 the action's script on a conformant bundle: exit 0 and the okf-check verdict in the log" || bad "LT-29b S19-H1" "rc=$rc $(head -2 "$TMP_W/act_out.txt" | tr '\n' ' ')"
runact "" false false; rc=$?
{ [ "$rc" -ne 0 ] && grep -qi "bundle" "$TMP_W/act_out.txt"; } && ok "LT-29c S19-N1 no bundle input: the job fails and the message names the input" || bad "LT-29c S19-N1" "rc=$rc $(head -2 "$TMP_W/act_out.txt" | tr '\n' ' ')"
AB2="$TMP_W/with space/bundle"; mkab "$AB2"; mkabnote "$AB2" stable human:t 2099-01-01
runact "$AB2" false false; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '1 concepts' "$TMP_W/act_out.txt"; } && ok "LT-29d S19-E1 a bundle path with a space reaches okf-check whole" || bad "LT-29d S19-E1" "rc=$rc $(head -2 "$TMP_W/act_out.txt" | tr '\n' ' ')"
AB3="$TMP_W/ab3"; mkab "$AB3"; printf -- '---\ntitle: no type here\n---\n\nbody\n' > "$AB3/e.md"
runact "$AB3" false false; rc=$?
[ "$rc" -eq 1 ] && ok "LT-29e S20-H1 a bundle that exits 1 on the CLI fails the job with exit 1" || bad "LT-29e S20-H1" "rc=$rc"
BRKA="$TMP_W/brk_action"; mkdir -p "$BRKA"; cp -R "$PLUGIN" "$BRKA/plugin" 2>/dev/null
printf 'import sys\nsys.exit(3)\n' > "$BRKA/plugin/scripts/okf-trust.py"
runact "$AB1" false false "$BRKA"; rc=$?
[ "$rc" -eq 2 ] && ok "LT-29f S20-E1 a layer that could not run (exit 2) fails the job, never passes as skipped" || bad "LT-29f S20-E1" "rc=$rc"
AB4="$TMP_W/ab4"; mkab "$AB4"; mkabnote "$AB4" draft agent/1 2099-01-01
runact "$AB4" true false; rc=$?
[ "$rc" -eq 1 ] && ok "LT-29g S21-H1 strict-trust: true fails the job on a draft with a human verifier" || bad "LT-29g S21-H1" "rc=$rc"
runact "$AB4" false false; rc=$?
[ "$rc" -eq 0 ] && ok "LT-29h S21-N1 strict-trust: false (the default) passes the same bundle" || bad "LT-29h S21-N1" "rc=$rc"
AB5="$TMP_W/ab5"; mkab "$AB5"; mkabnote "$AB5" stable human:t 2020-01-01
runact "$AB5" false true; rc=$?
[ "$rc" -eq 4 ] && ok "LT-29i S21-E1 fail-stale: true fails the job with exit 4 on an expired note" || bad "LT-29i S21-E1" "rc=$rc"
runact "$AB1" yes false; rc=$?
{ [ "$rc" -eq 64 ] && grep -q "strict-trust" "$TMP_W/act_out.txt"; } && ok "LT-29j an input other than 'true' or 'false' is refused (exit 64) and named" || bad "LT-29j bad input" "rc=$rc"
# pre-commit entry
if [ -f "$PCH" ]; then
  pyyaml - "$PCH" "$MKT_ROOT" <<'PY' 2>"$TMP_W/pch_err.txt"
import os, re, sys, yaml
hooks = yaml.safe_load(open(sys.argv[1])); root = sys.argv[2]
h = [x for x in hooks if x["id"] == "okf-check"][0]
for k in ("id", "name", "entry", "language"):
    assert h.get(k), k
assert h["language"] == "script" and h["pass_filenames"] is False
ent = os.path.join(root, h["entry"]); assert os.access(ent, os.X_OK), ent
assert h["args"] == ["."], h["args"]
rx = re.compile(h["files"])
assert rx.search("notes/a.md") and rx.search("README.md") and not rx.search("src/app.py") and not rx.search("notes.txt")
PY
  [ $? -eq 0 ] && ok "LT-29k .pre-commit-hooks.yaml: hook okf-check, script entry that exists and is executable, no filenames passed, default arg '.', files selects only .md" \
    || bad "LT-29k pre-commit structure" "$(head -2 "$TMP_W/pch_err.txt" | tr '\n' ' ')"
else
  bad "LT-29k pre-commit structure" "$PCH does not exist"
fi
# S22 behaviour, emulating what pre-commit runs: <entry> <args...> with pass_filenames false, from the repo root.
PC1="$TMP_W/pc1"; mkab "$PC1"; mkabnote "$PC1" draft agent/1 2099-01-01
( cd "$PC1" && "$MKT_ROOT/plugin/scripts/okf-check" . --strict-trust ) >"$TMP_W/pc_out.txt" 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "LT-29l S22-H1 (emulated) the hook's command with --strict-trust blocks a draft with a human verifier" || bad "LT-29l S22-H1" "rc=$rc"
PC2="$TMP_W/pc2"; mkab "$PC2"; mkabnote "$PC2" stable human:t 2099-01-01
( cd "$PC2" && "$MKT_ROOT/plugin/scripts/okf-check" . --strict-trust ) >"$TMP_W/pc_out2.txt" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "LT-29m S22-N1 (emulated) a clean bundle lets the commit through" || bad "LT-29m S22-N1" "rc=$rc"
# Review round 1. A `bundle` that starts with "-" reaches okf-check as a FLAG: `--doctor`, `--selftest`
# and `--help` exit 0, so the job went green without checking anything. Refused before okf-check runs.
for flagval in --doctor --selftest --help -h; do
  runact "$flagval" false false; rc=$?
  { [ "$rc" -eq 64 ] && grep -q "bundle" "$TMP_W/act_out.txt"; } || { bad "LT-29o bundle '$flagval' must be refused" "rc=$rc $(head -1 "$TMP_W/act_out.txt")"; flagval=""; break; }
done
[ -n "$flagval" ] && ok "LT-29o a bundle input that starts with '-' (--doctor, --selftest, --help, -h) is refused with exit 64, never passed to okf-check as a flag"
# S22 through a REAL git commit: a real hook script in a real temp repo, run by git itself. The script does what
# pre-commit does for this hook (files: '\.md$', pass_filenames: false, the entry plus the args). Only the
# pre-commit tool itself is not exercised (UNVERIFIED, LT-29n). Host git config and credential helpers are isolated.
gitx() { ( cd "$GR" && env HOME="$TMP_W/ghome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c credential.helper= -c user.name=t -c user.email=okf-test -c commit.gpgsign=false "$@" ); }
GR="$TMP_W/gitrepo"; mkdir -p "$GR" "$TMP_W/ghome"; mkab "$GR"; mkabnote "$GR" stable human:t 2099-01-01
gitx init -q 2>/dev/null
printf '#!/bin/sh\ngit diff --cached --name-only | grep -Eq "\\.md$" || exit 0\nexec "%s/plugin/scripts/okf-check" . --strict-trust\n' "$MKT_ROOT" > "$GR/.git/hooks/pre-commit"; chmod +x "$GR/.git/hooks/pre-commit"
gitx add -A; gitx commit -qm "clean bundle" >"$TMP_W/g1.txt" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "LT-29p S22-N1 (real git) a clean bundle commits" || bad "LT-29p S22-N1 real git" "rc=$rc $(tail -2 "$TMP_W/g1.txt" | tr '\n' ' ')"
mkabnote "$GR" draft agent/1 2099-01-01; gitx add -A; gitx commit -qm "draft note" >"$TMP_W/g2.txt" 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'trust policy failure' "$TMP_W/g2.txt" && [ "$(gitx rev-list --count HEAD)" = 1 ]; } \
  && ok "LT-29q S22-H1 (real git) a draft note with a human verifier BLOCKS the commit; HEAD stays at 1 commit" \
  || bad "LT-29q S22-H1 real git" "rc=$rc $(tail -2 "$TMP_W/g2.txt" | tr '\n' ' ')"
gitx reset -q --hard HEAD 2>/dev/null; printf 'print(1)\n' > "$GR/app.py"; gitx add app.py; gitx commit -qm "code only" >"$TMP_W/g3.txt" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q 'okf-check' "$TMP_W/g3.txt"; } && ok "LT-29r S22-E1 (real git) a commit that stages no .md file does not run the check" || bad "LT-29r S22-E1 real git" "rc=$rc $(tail -2 "$TMP_W/g3.txt" | tr '\n' ' ')"
if command -v pre-commit >/dev/null 2>&1; then
  # The real pre-commit tool, end to end, against a hook repo it clones (a real git repo holding what a consumer's
  # `repo:` would clone). Everything is isolated: temp HOME, temp pre-commit cache, no global git config, no network.
  PCX="$TMP_W/pcx"; mkdir -p "$PCX/hookrepo" "$PCX/home" "$PCX/work"
  pcenv() { env HOME="$PCX/home" PRE_COMMIT_HOME="$PCX/home/.pc" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$@"; }
  pcgit() { ( cd "$1" && shift && pcenv git -c credential.helper= -c user.name=t -c user.email=okf-test -c commit.gpgsign=false "$@" ); }
  cp -R "$PLUGIN" "$PCX/hookrepo/plugin"; cp "$PCH" "$PCX/hookrepo/.pre-commit-hooks.yaml"
  pcgit "$PCX/hookrepo" init -q; pcgit "$PCX/hookrepo" add -A; pcgit "$PCX/hookrepo" commit -qm hook
  PCREV=$(pcgit "$PCX/hookrepo" rev-parse HEAD)
  mkab "$PCX/work"; mkabnote "$PCX/work" stable human:t 2099-01-01
  printf 'repos:\n  - repo: %s\n    rev: %s\n    hooks:\n      - id: okf-check\n        args: [., --strict-trust]\n' "$PCX/hookrepo" "$PCREV" > "$PCX/work/.pre-commit-config.yaml"
  pcgit "$PCX/work" init -q; ( cd "$PCX/work" && pcenv pre-commit install >"$TMP_W/pc_install.txt" 2>&1 ); pcirc=$?
  pcgit "$PCX/work" add -A; pcgit "$PCX/work" commit -qm "clean bundle" >"$TMP_W/pc_c1.txt" 2>&1; rc=$?
  { [ "$pcirc" -eq 0 ] && [ "$rc" -eq 0 ] && grep -q 'Passed' "$TMP_W/pc_c1.txt"; } \
    && ok "LT-29n S22-N1 (REAL pre-commit) a clean bundle commits; the hook reports Passed" \
    || bad "LT-29n S22-N1 real pre-commit" "install rc=$pcirc commit rc=$rc $(tail -3 "$TMP_W/pc_c1.txt" | tr '\n' ' ')"
  mkabnote "$PCX/work" draft agent/1 2099-01-01; pcgit "$PCX/work" add -A; pcgit "$PCX/work" commit -qm "draft" >"$TMP_W/pc_c2.txt" 2>&1; rc=$?
  { [ "$rc" -ne 0 ] && grep -q 'Failed' "$TMP_W/pc_c2.txt" && grep -q 'trust policy failure' "$TMP_W/pc_c2.txt" && [ "$(pcgit "$PCX/work" rev-list --count HEAD)" = 1 ]; } \
    && ok "LT-29o2 S22-H1 (REAL pre-commit) a draft note with a human verifier BLOCKS the commit; the user's args (., --strict-trust) reached okf-check; HEAD unchanged" \
    || bad "LT-29o2 S22-H1 real pre-commit" "rc=$rc $(tail -4 "$TMP_W/pc_c2.txt" | tr '\n' ' ')"
  pcgit "$PCX/work" reset -q --hard HEAD; printf 'print(1)\n' > "$PCX/work/app.py"; pcgit "$PCX/work" add app.py; pcgit "$PCX/work" commit -qm "code only" >"$TMP_W/pc_c3.txt" 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'Skipped' "$TMP_W/pc_c3.txt"; } \
    && ok "LT-29o3 S22-E1 (REAL pre-commit) a commit that stages no .md file: the hook is Skipped" \
    || bad "LT-29o3 S22-E1 real pre-commit" "rc=$rc $(tail -3 "$TMP_W/pc_c3.txt" | tr '\n' ' ')"
else
  skip "LT-29n S22 end-to-end through the real pre-commit tool — pre-commit is not installed; unlock it with tools/install-dev-deps.sh --yes (UNVERIFIED end-to-end until then)"
fi

# --- 0.9.0 T6: README states the platforms and both pins (cases S23, S24) ---
# A reader should not discover "Windows does not work" or "this rests on two unmerged pull requests" by failure.
# The commit ids are compared with the files that actually pin them, so the README cannot drift from the pins.
README="$MKT_ROOT/README.md"
section() { # <heading-regex> — the README text from that '## ' heading to the next one
  awk -v h="$1" '/^## /{f = ($0 ~ h)} f' "$README"
}
section '^## Platforms' > "$TMP_W/readme_platforms.txt"
{ grep -q 'macOS' "$TMP_W/readme_platforms.txt" && grep -q 'Linux' "$TMP_W/readme_platforms.txt" && grep -q 'WSL' "$TMP_W/readme_platforms.txt"; } \
  && ok "LT-30a S23-H1 the README has a Platforms section naming macOS, Linux and Windows via WSL" \
  || bad "LT-30a S23-H1" "Platforms section missing or incomplete: $(head -c 120 "$TMP_W/readme_platforms.txt" | tr '\n' ' ')"
win_bad=$(grep -n -i 'windows' "$README" | grep -v -i 'wsl\|no native\|unsupported' || true)
[ -z "$win_bad" ] && ok "LT-30b S23-N1 every README line that mentions Windows says WSL, no native support, or unsupported (a bare 'not' does not count)" || bad "LT-30b S23-N1" "$win_bad"
grep -i '^| Windows' "$TMP_W/readme_platforms.txt" > "$TMP_W/readme_winrow.txt"
{ [ -s "$TMP_W/readme_winrow.txt" ] && grep -q 'UNVERIFIED' "$TMP_W/readme_winrow.txt" && grep -q 'pre-commit' "$TMP_W/readme_winrow.txt" && grep -q 'Action' "$TMP_W/readme_winrow.txt"; } \
  && ok "LT-30c S23-E1 the Windows row labels WSL, the Action and the pre-commit hook on Windows as UNVERIFIED" \
  || bad "LT-30c S23-E1" "Windows row: $(cat "$TMP_W/readme_winrow.txt" | head -c 200)"
# README wording must follow the tool's own words, not a stronger paraphrase of them.
latest_msg=$(PYTHONPATH="$PLUGIN/vendor/pyyaml" OKF_PINNED_VERSIONS="$PLUGIN/config/pinned-versions.txt" "$PLUGIN/scripts/okf-check" --install-deps --latest 2>&1 | grep -o 'may lack' | head -1)
{ [ "$latest_msg" = "may lack" ] && grep -q 'may lack' "$README"; } \
  && ok "LT-30g the README describes --latest with the tool's own words ('may lack the fixes')" \
  || bad "LT-30g --latest wording" "tool says: '$latest_msg'; README has 'may lack': $(grep -c 'may lack' "$README")"
! grep -q 'Requires `python3` with `pyyaml`' "$README" && ok "LT-30h the README no longer says pyyaml must be installed (it is vendored)" || bad "LT-30h pyyaml line" "README still says pyyaml is required"
! grep -n -i 'should behave\|should work\|probably\|likely' "$README" > "$TMP_W/readme_hedge.txt" && ok "LT-30i the README has no hedge words in its platform claims" || bad "LT-30i hedge words" "$(head -2 "$TMP_W/readme_hedge.txt" | tr '\n' ' ')"
OKFS_PIN=$(awk '$1=="okf_validate"{print $2}' "$PLUGIN/config/pinned-versions.txt")
OKFL_PIN=$(awk '$1=="okflint_source"{n=split($2,a,"@"); print a[n]}' "$PLUGIN/config/pinned-versions.txt")
VEND_PIN=$(grep -o 'Pinned commit:\*\* `[0-9a-f]\{40\}`' "$PLUGIN/vendor/VENDOR.md" | grep -o '[0-9a-f]\{40\}' | head -1)
{ [ -n "$OKFS_PIN" ] && [ "$OKFS_PIN" = "$VEND_PIN" ] && [ -n "$OKFL_PIN" ] && grep -q "$OKFS_PIN" "$README" && grep -q "$OKFL_PIN" "$README"; } \
  && ok "LT-30d S24-H1/E1 the README names both pinned commits in full, and they equal the pin file and VENDOR.md ($(printf '%.7s' "$OKFS_PIN"), $(printf '%.7s' "$OKFL_PIN"))" \
  || bad "LT-30d S24-H1/E1" "okf_validate pin=$OKFS_PIN vendor=$VEND_PIN okflint pin=$OKFL_PIN; README has them: $(grep -c "$OKFS_PIN" "$README") / $(grep -c "$OKFL_PIN" "$README")"
section '^## Tools it uses' > "$TMP_W/readme_deps.txt"
n_never=$(tr -s '[:space:]' ' ' < "$TMP_W/readme_deps.txt" | grep -o 'never merged' | wc -l | tr -d ' ')  # joined: the sentence wraps across lines
{ grep -q 'okf-skills#68\|okf-skills/pull/68' "$TMP_W/readme_deps.txt" && grep -q 'okflint#11\|okflint/pull/11' "$TMP_W/readme_deps.txt" && [ "$n_never" -ge 2 ]; } \
  && ok "LT-30e S24-N1 the Tools section (Pins) names both pull requests (okf-skills#68, okflint#11) and says what happens if each is never merged" \
  || bad "LT-30e S24-N1" "never-merged lines: $n_never; section: $(head -c 100 "$TMP_W/readme_deps.txt" | tr '\n' ' ')"
{ grep -q 'ahmedibrahim085/okf-knowledge-gate@' "$README" && grep -q 'id: okf-check' "$README" && grep -q -- '--strict-trust' "$README" && grep -q -- '--init-house-rules' "$README" && grep -q 'python3' "$README"; } \
  && ok "LT-30f the README shows the Action and the pre-commit hook, --strict-trust, --init-house-rules and the python3 prerequisite" \
  || bad "LT-30f README usage" "missing: $(for p in 'okf-knowledge-gate@' 'id: okf-check' '--strict-trust' '--init-house-rules'; do grep -q -- "$p" "$README" || printf '%s ' "$p"; done)"

# --- 0.9.0 T8: the plugin is usable by an AGENT as shipped ---
# Anthropic: files in a plugin's bin/ are on the Bash tool's PATH while the plugin is enabled (plugins-reference);
# Agent Skills best practices: a third-person description saying what and when, a body under 500 lines,
# references one level deep. The skill is the one document an agent reads, so it must teach what 0.9.0 added.
for tool in okf-check okf-verify; do
  [ -x "$PLUGIN/bin/$tool" ] || { bad "LT-31a bin/$tool exists and is executable" "missing"; continue; }
  want=$("$PLUGIN/scripts/$tool" --version 2>&1 | head -1); got=$(cd / && "$PLUGIN/bin/$tool" --version 2>&1 | head -1)
  "$PLUGIN/bin/$tool" --nope-not-a-flag >/dev/null 2>&1; rc_w=$?; "$PLUGIN/scripts/$tool" --nope-not-a-flag >/dev/null 2>&1; rc_s=$?
  { [ -n "$want" ] && [ "$want" = "$got" ] && [ "$rc_w" = "$rc_s" ]; } \
    && ok "LT-31a bin/$tool is a pass-through: same --version ('$got'), same exit code for a bad flag ($rc_w), from any directory" \
    || bad "LT-31a bin/$tool pass-through" "scripts says '$want' rc=$rc_s; bin says '$got' rc=$rc_w"
done
[ "$(PATH="$PLUGIN/bin:$PATH" command -v okf-check)" = "$PLUGIN/bin/okf-check" ] && ok "LT-31b with bin/ on PATH, a bare 'okf-check' resolves to the plugin's wrapper" || bad "LT-31b bare okf-check on PATH" "$(PATH="$PLUGIN/bin:$PATH" command -v okf-check)"
if [ -f "$MKT_ROOT/LICENSE" ]; then
  cmp -s "$PLUGIN/LICENSE" "$MKT_ROOT/LICENSE" && ok "LT-31c plugin/LICENSE equals the repository LICENSE (a marketplace install copies only plugin/)" || bad "LT-31c plugin/LICENSE" "missing or different from $MKT_ROOT/LICENSE"
else
  [ -f "$PLUGIN/LICENSE" ] && ok "LT-31c plugin/LICENSE ships with the plugin" || bad "LT-31c plugin/LICENSE" "missing"
fi
SKILL="$PLUGIN/skills/okf/SKILL.md"
sk_missing=""
for needle in '--strict-trust' '--init-house-rules' 'Trust (C4)' 'Precedence' 'Never' 'okf-knowledge-gate@' 'pre-commit' 'okf-verify' 'COULD NOT RUN'; do
  grep -q -- "$needle" "$SKILL" || sk_missing="$sk_missing [$needle]"
done
[ -z "$sk_missing" ] && ok "LT-31d SKILL.md teaches 0.9.0: strict-trust, init-house-rules, Trust (C4), exit precedence, a never-list, the Action and hook, okf-verify" || bad "LT-31d SKILL.md content" "missing:$sk_missing"
grep -Eq '^\| *1 *\|.*(strict-trust|Trust)' "$SKILL" && grep -Eq '^\| *64 *\|' "$SKILL" && ok "LT-31e the SKILL.md exit table says what exit 1 means with --strict-trust and lists exit 64" || bad "LT-31e exit table" "row 1 or row 64 missing"
pyyaml - "$SKILL" <<'PY' 2>"$TMP_W/skill_err.txt"
import sys, re, yaml
text = open(sys.argv[1]).read()
fm = yaml.safe_load(text.split("---")[1])
d = fm["description"]
assert len(d) <= 1024, len(d)
assert "okf-verify" in d, "the description must mention okf-verify"
assert not re.match(r"\s*(Check|Use|Run|Validate)\b", d), "third person, not an imperative"
assert "--strict-trust" in fm["argument-hint"] and "--init-house-rules" in fm["argument-hint"]
assert len(text.splitlines()) <= 500, len(text.splitlines())
PY
[ $? -eq 0 ] && ok "LT-31f SKILL.md frontmatter: third-person description naming okf-verify (<=1024 chars), argument-hint lists the 0.9.0 flags, body <= 500 lines" || bad "LT-31f SKILL.md frontmatter" "$(head -2 "$TMP_W/skill_err.txt" | tr '\n' ' ')"
ref_bad=""
for r in $(grep -o 'references/[A-Za-z0-9_.-]*\.md' "$SKILL" | sort -u); do [ -f "$PLUGIN/skills/okf/$r" ] || ref_bad="$ref_bad $r"; done
nrefs=$(grep -o 'references/[A-Za-z0-9_.-]*\.md' "$SKILL" | sort -u | wc -l | tr -d ' ')
deep=$(grep -l 'references/' "$PLUGIN"/skills/okf/references/*.md 2>/dev/null || true)
{ [ -z "$ref_bad" ] && [ "$nrefs" -ge 1 ] && [ -z "$deep" ]; } && ok "LT-31g SKILL.md links $nrefs reference file(s), all exist, and none links another reference (one level deep)" || bad "LT-31g references" "missing:$ref_bad count=$nrefs nested:$deep"

# Review round 1. A PATH entry may be a SYMLINK to the wrapper; resolving the link's own folder broke it (exit 126).
SLN="$TMP_W/symlinked"; mkdir -p "$SLN"
for tool in okf-check okf-verify; do
  ln -sf "$PLUGIN/bin/$tool" "$SLN/$tool"
  want=$("$PLUGIN/scripts/$tool" --nope-not-a-flag >/dev/null 2>&1; echo $?); got=$(cd / && PATH="$SLN:$PATH" "$tool" --nope-not-a-flag >/dev/null 2>&1; echo $?)
  [ "$want" = "$got" ] && [ "$got" != 126 ] && [ "$got" != 127 ] && ok "LT-31h $tool reached through a SYMLINK to the wrapper behaves like the real tool (exit $got)" || bad "LT-31h $tool via symlink" "real exit $want, via symlink $got"
done
# Nothing an agent needs may be lost when text moves out of SKILL.md into references/. Each phrase below was in
# the old SKILL.md and must be in SKILL.md or a reference file.
lost=""
for needle in 'fenced code' 'var/folders' 'likely rewrite' 'stale_after. is required' '--migrate' 'previous okflint' 'no checkable claim'; do
  grep -rq -- "$needle" "$PLUGIN/skills/okf/" || lost="$lost [$needle]"
done
[ -z "$lost" ] && ok "LT-31i every okf-verify, install and setup rule of the old SKILL.md is still in SKILL.md or a reference file" || bad "LT-31i rules lost in the move" "missing:$lost"
tr '\n' ' ' < "$PLUGIN/skills/okf/SKILL.md" | grep -Eq -- '--strict. also fails on UNRESOLVED and on +notes with no checkable claim' && ok "LT-31j SKILL.md says --strict also fails on notes with no checkable claim (okf-verify D-9)" || bad "LT-31j --strict wording" "SKILL.md names only UNRESOLVED"
grep -qi 'bin/\|on the Bash tool.s PATH\|on the Bash PATH' "$MKT_ROOT/README.md" && ok "LT-31k the README says the commands are on the Bash tool's PATH while the plugin is enabled" || bad "LT-31k README bin" "README does not mention it"

# Release review round 1: the Action must not echo an input value into a workflow command (a newline in the value
# injected a second ::error:: line), and the README must say what L2 needs (found by the Debian run).
runact "$AB1" $'x\n::error::injected' false; rc=$?
nerr=$(grep -c '^::error::' "$TMP_W/act_out.txt")
{ [ "$rc" -eq 64 ] && [ "$nerr" -eq 1 ] && ! grep -q 'injected' "$TMP_W/act_out.txt"; } \
  && ok "LT-33a an invalid strict-trust value is refused (exit 64) without echoing the value: exactly one ::error:: line, no injection" \
  || bad "LT-33a echo of the input value" "rc=$rc error lines=$nerr $(grep -n 'injected' "$TMP_W/act_out.txt" | head -1)"
grep -q 'Python 3.12' "$README" && ok "LT-33b the README says okflint (L2) needs Python 3.12 or newer" || bad "LT-33b README Python" "no mention of Python 3.12"

# --- 0.9.1 B1: the vendored validator carries a LOCAL patch; it must be documented and must not be lost ---
VENDF="$PLUGIN/vendor/okf_validate.py"; VMD="$PLUGIN/vendor/VENDOR.md"
{ grep -q 'def load_frontmatter' "$VENDF" && ! grep -q 'yaml\.safe_load(raw)' "$VENDF" && grep -q 'load_frontmatter' "$PLUGIN/scripts/okf-trust.py" && ! grep -q 'yaml\.safe_load(raw)' "$PLUGIN/scripts/okf-trust.py" && grep -q 'load_frontmatter' "$PLUGIN/scripts/okf-check" && ! grep -q 'yaml\.safe_load' "$PLUGIN/scripts/okf-check"; } \
  && ok "LT-35a the bounded loader is in the vendored validator and the trust helper, and no frontmatter is parsed with a bare yaml.safe_load" \
  || bad "LT-35a bounded loader" "a yaml.safe_load(raw) call or the loader is missing"
{ grep -q 'Local patch' "$VMD" && grep -q 'load_frontmatter' "$VMD" && grep -q "$OKFS_PIN" "$VMD" && grep -q '7ed3084267d050f198eea6cd9f67d5357e9ed047' "$VMD"; } \
  && ok "LT-35b VENDOR.md lists the local patch and still names the pinned upstream commit" \
  || bad "LT-35b VENDOR.md" "the local patch is not documented, or the pinned commit is gone"

# --- 0.9.1 B2: README and release notes, reviewed by a stranger-reader and a facts-reader ---
# A claim is only as good as what backs it: the sample on the README's first screen is REAL output (compared line
# by line with a fresh run), the exit table says what exit 0 really covers, and the release notes do not claim
# a fix that was not in the release.
head20=$(head -20 "$README")
{ printf '%s' "$head20" | grep -q 'OKF is' && printf '%s' "$head20" | grep -q 'A bundle is'; } \
  && ok "LT-36a the first screen defines OKF and bundle for a stranger" || bad "LT-36a first screen" "OKF / bundle are not defined in the first 20 lines"
SAMPLE_BUNDLE="$TMP_W/readme_sample"; mkdir -p "$SAMPLE_BUNDLE/notes"
printf -- '---\nokf_version: "0.2"\n---\n# Notes\n' > "$SAMPLE_BUNDLE/notes/index.md"; printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$SAMPLE_BUNDLE/notes/log.md"
printf -- '---\ntype: Lesson\ntitle: Payment limits\ndescription: Limits for payouts.\nstatus: draft\ntags: [payments]\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: human:finance-owner\n    at: "2026-02-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$SAMPLE_BUNDLE/notes/limits.md"
( cd "$SAMPLE_BUNDLE" && HOME="$TMP_W" "$PLUGIN/scripts/okf-check" notes ) > "$TMP_W/readme_sample_real.txt" 2>&1
"$REALPY" - "$README" "$TMP_W/readme_sample_real.txt" <<'PY' 2>"$TMP_W/sample_err.txt"
import sys
readme, real = open(sys.argv[1]).read().split("\n"), set(open(sys.argv[2]).read().split("\n"))
start = next((i for i, l in enumerate(readme) if l.strip() == "$ okf-check notes"), None)
assert start is not None, "no '$ okf-check notes' sample block in the README"
lines = []
for l in readme[start + 1:]:
    if l.startswith("```"): break
    lines.append(l)
body = [l for l in lines if l.strip()]
assert len(body) >= 5, "sample too short: %d lines" % len(body)
missing = [l for l in body if l not in real]
assert not missing, "README sample lines that real output does not contain: %r" % missing
PY
[ $? -eq 0 ] && ok "LT-36b the README's sample output is REAL: every line appears in a fresh run on the documented fixture" || bad "LT-36b sample is real" "$(head -2 "$TMP_W/sample_err.txt" | tr '\n' ' ' | cut -c1-300)"
! grep -Eq '^\| 0 \| *All gates pass' "$README" && ok "LT-36c the README does not say exit 0 means 'all gates pass' (it also covers skipped layers and warnings)" || bad "LT-36c exit 0 wording" "row 0 still says All gates pass"
awk '/^## Use$/{u=1} u&&/^```bash/{b=1; next} b&&/^```/{exit} b' "$README" > "$TMP_W/readme_usecmds.txt"
grep -q -- '--fail-on-change' "$TMP_W/readme_usecmds.txt" && ok "LT-36d the Use command block shows --fail-on-change (exit 6 needs it)" || bad "LT-36d --fail-on-change" "not in the command block (the exit table alone does not show how to ask for it)"
! grep -q 'CLAUDE_PLUGIN_ROOT' "$README" && ok "LT-36e the README does not rely on \${CLAUDE_PLUGIN_ROOT} (a user's shell does not have it)" || bad "LT-36e CLAUDE_PLUGIN_ROOT" "still mentioned"
li=$(grep -n '^## Install' "$README" | head -1 | cut -d: -f1); lu=$(grep -n '^## Use$' "$README" | head -1 | cut -d: -f1); lp=$(grep -n '^## Platforms' "$README" | head -1 | cut -d: -f1)
{ [ -n "$li" ] && [ -n "$lu" ] && [ -n "$lp" ] && [ "$li" -lt "$lu" ] && [ "$lu" -lt "$lp" ]; } && ok "LT-36f section order: Install, Use, then Platforms" || bad "LT-36f section order" "Install=$li Use=$lu Platforms=$lp"
{ ! grep -q 'remembered zero times' "$README" && ! grep -q 'loudest signal' "$README" && ! grep -q 'Issue forms' "$README"; } && ok "LT-36g no rhetoric and no wrong term (the claims are plain statements)" || bad "LT-36g wording" "rhetorical lines or 'Issue forms' remain"
grep -q 'Absolute file paths' "$README" && ok "LT-36h the README says what --repo and path checks really do (SHAs via --repo; absolute file paths on disk)" || bad "LT-36h okf-verify wording" "no 'Absolute file paths' sentence"
if [ -f "$MKT_ROOT/docs/backlog-2026-10-14.md" ]; then
  grep -q 'Debian 12, 0.9.1' "$MKT_ROOT/docs/backlog-2026-10-14.md" && grep -q 'pre-commit 4.7.0' "$MKT_ROOT/docs/backlog-2026-10-14.md" \
    && ok "LT-36i the Debian run the README cites (with okflint and pre-commit) is recorded in the backlog doc" || bad "LT-36i Debian run record" "the backlog doc does not record the run with okflint and pre-commit 4.7.0"
else
  skip "LT-36i Debian run record — docs/backlog is not part of this tree (the public export)"
fi
# Release notes
CL="$MKT_ROOT/CHANGELOG.md"
sec() { awk -v h="$1" 'index($0, "## [" h "]") == 1 {f=1; next} /^## \[/ {f=0} f' "$CL"; }
sec 0.9.0 > "$TMP_W/cl_090.txt"; sec Unreleased > "$TMP_W/cl_unrel.txt"
first=$(awk 'NF{print; exit}' "$TMP_W/cl_090.txt")
case "$first" in '#'*|'-'*|'') bad "LT-37a [0.9.0] opens with a plain summary sentence" "first line: '$first'";; *) ok "LT-37a [0.9.0] opens with a plain summary sentence";; esac
{ grep -q 'Upgrade note' "$TMP_W/cl_090.txt" && grep -q '^### Security' "$TMP_W/cl_090.txt" && grep -q 'fixed in 0.9.1' "$TMP_W/cl_090.txt"; } \
  && ok "LT-37b [0.9.0] carries an upgrade note and says the alias-bomb problem was fixed only in 0.9.1" || bad "LT-37b [0.9.0] honesty" "missing the upgrade note, the Security heading, or 'fixed in 0.9.1'"
! grep -q 'ignores a YAML alias bomb' "$TMP_W/cl_090.txt" && ok "LT-37c [0.9.0] no longer claims it ignores a YAML alias bomb (L1 still expanded one)" || bad "LT-37c overclaim" "the overclaiming bullet is still there"
latest_rel=$(grep -o '^## \[[0-9][0-9.]*\]' "$CL" | head -1 | tr -d '#[] '); prev_rel=$(grep -o '^## \[[0-9][0-9.]*\]' "$CL" | sed -n 2p | tr -d '#[] ')
{ grep -q "^\[Unreleased\]: .*compare/v${latest_rel}\.\.\.HEAD" "$CL" && grep -q "^\[${latest_rel}\]: .*compare/v${prev_rel}\.\.\.v${latest_rel}" "$CL" && grep -q '^\[0.9.0\]: .*compare/v0.8.1\.\.\.v0.9.0' "$CL"; } \
  && ok "LT-37d the CHANGELOG compare links follow the releases: Unreleased from v${latest_rel}, v${prev_rel}...v${latest_rel}, and 0.9.0" || bad "LT-37d compare links" "a definition is missing or stale (latest=${latest_rel}, previous=${prev_rel})"
first_latest=$(sec "$latest_rel" | awk 'NF{print; exit}')
case "$first_latest" in '#'*|'-'*|'') bad "LT-37e the latest release opens with a plain summary sentence" "first line: '$first_latest'";; *) ok "LT-37e the latest release ($latest_rel) opens with a plain summary sentence";; esac

# --- 0.9.1 B3: the demo GIF is embedded with alt text that says what it shows, and the file ships ---
alt=$(grep -o '!\[[^]]*\](docs/demo\.gif)' "$README" | head -1 | sed 's/^!\[//; s/\](docs\/demo\.gif)$//')
{ [ "${#alt}" -ge 60 ] && [ -f "$MKT_ROOT/docs/demo.gif" ]; } && ok "LT-38 the README embeds docs/demo.gif with alt text that describes it (${#alt} chars) and the file exists" || bad "LT-38 demo embed" "alt='${alt}' file=$([ -f "$MKT_ROOT/docs/demo.gif" ] && echo yes || echo no)"

# --- 0.9.1 release: the README's example tags follow the latest RELEASED version in the CHANGELOG ---
# The README showed @v0.9.0 while describing a patch that only 0.9.1 contains. The tag is read from the CHANGELOG
# (the first dated heading), not from the code, so a release that forgets the README fails here.
latest_rel=$(grep -o '^## \[[0-9][0-9.]*\]' "$MKT_ROOT/CHANGELOG.md" | head -1 | tr -d '#[] ')
tags=$(grep -oE '(okf-knowledge-gate@v|rev: v)[0-9.]+' "$README" | grep -oE 'v[0-9.]+$' | sort -u | tr '\n' ' ')
{ [ -n "$latest_rel" ] && [ "$tags" = "v$latest_rel " ]; } && ok "LT-37f the README's @v / rev: v example tags equal the latest released version in the CHANGELOG (v$latest_rel)" || bad "LT-37f README example tags" "CHANGELOG latest=$latest_rel, README tags='$tags'"

# --- final review: version pins outside the README, wording that a clean run falsifies, hook scope ---
SKILL_MD="$PLUGIN/skills/okf/SKILL.md"
other=$(grep -hoE '(okf-knowledge-gate@v|rev: v)[0-9.]+' "$SKILL_MD" "$MKT_ROOT/.pre-commit-hooks.yaml" | grep -oE 'v[0-9.]+$' | sort -u | tr '\n' ' ')
{ [ -n "$latest_rel" ] && [ "$other" = "v$latest_rel " ]; } && ok "LT-41a the skill's @v pin and the pre-commit hook's rev: comment equal the latest released version (v$latest_rel)" || bad "LT-41a version pins outside the README" "CHANGELOG latest=$latest_rel, found='$other'"
! tr -s '[:space:]' ' ' < "$README" | grep -q 'says so on every run' \
  && ok "LT-41b the README does not claim the Trust layer speaks 'on every run' (a clean run prints no such note)" || bad "LT-41b README on every run" "claim present"
jsonkeys=$(tr -s '[:space:]' ' ' < "$SKILL_MD" | grep -o -- '--json.\{1,4\} carries the verdict[^.]*' | head -1)
{ for k in 'errors\[\]' 'l2_findings\[\]' 'stale\[\]' 'skipped\[\]'; do printf '%s' "$jsonkeys" | grep -q "$k" || exit 1; done; } \
  && ok "LT-41c the skill names the --json finding lists (errors, l2_findings, stale, skipped)" || bad "LT-41c skill --json scope" "sentence missing or incomplete: $jsonkeys"
! grep -q 'refuses to say .ALL GATES PASS' "$SKILL_MD" \
  && ok "LT-41d the skill does not claim ALL GATES PASS is refused while a layer is skipped (an opted-out L2 index still passes)" || bad "LT-41d skill ALL GATES PASS claim" "claim present"
hf=$(grep -E "^  files:" "$MKT_ROOT/.pre-commit-hooks.yaml")
{ echo kb/okf-base.yaml | grep -Eq "$(printf '%s' "$hf" | sed "s/^  files: '//; s/'\$//")" && echo kb/.okfignore | grep -Eq "$(printf '%s' "$hf" | sed "s/^  files: '//; s/'\$//")"; } \
  && ok "LT-41e the pre-commit hook also runs when only okf-base.yaml or .okfignore changes" || bad "LT-41e hook files regex" "$hf"
cl_ver=$(grep -o '^## \[[0-9][0-9.]*\] - [0-9-]*' "$MKT_ROOT/CHANGELOG.md" | head -1)
case "$cl_ver" in *' - 20'*) ok "LT-37g the latest CHANGELOG section is dated ($cl_ver)";; *) bad "LT-37g dated release section" "latest section: '$cl_ver'";; esac

# --- 0.9.1 B5: the README is a funnel (what, demo, WHY use it, contents, install, use, tools, ... licence last) ---
# Structure from primary sources read 2026-10-17 (GitHub Docs "About READMEs", makeareadme.com, the standard-readme spec,
# opensource.guide; ruff, shellcheck and gitleaks as examples): what the project does and why it is useful come first,
# a Contents list is required past 100 lines, Install carries the dependencies, the licence is last.
"$REALPY" - "$README" "$MKT_ROOT" <<'PY' 2>"$TMP_W/funnel_err.txt"
import os, re, sys
text = open(sys.argv[1]).read(); root = sys.argv[2]
lines = text.split("\n")
# (a) one-line description right under the title, under 160 characters
title = next(i for i, l in enumerate(lines) if l.startswith("# "))
desc = next(l for l in lines[title + 1:] if l.strip())
assert len(desc) < 160 and not desc.startswith("#"), "description %d chars: %r" % (len(desc), desc[:60])
# (b) the first section after the demo GIF is "Why use it"
img = next(i for i, l in enumerate(lines) if l.startswith("![") and "docs/demo.gif" in l)
heads = [(i, l) for i, l in enumerate(lines) if l.startswith("## ") and i > img]
assert heads and heads[0][1].strip() == "## Why use it", "first section after the demo is %r" % (heads[0][1] if heads else None)
# (c) the Why section: at least three bullets, each with evidence (a link into docs/ or a number)
why = []
for l in lines[heads[0][0] + 1:]:
    if l.startswith("## "): break
    why.append(l)
bullets, cur = [], None
for l in why:                      # a bullet wraps across lines: join its continuation lines
    if l.startswith("- "):
        cur = l; bullets.append(cur)
    elif cur is not None and l.startswith("  "):
        bullets[-1] += " " + l.strip()
    elif not l.strip():
        cur = None
assert len(bullets) >= 3, "only %d Why bullets" % len(bullets)
for b in bullets:
    assert re.search(r"\]\((docs/|#)|\d", b), "a Why bullet has no evidence (a link into docs/ or the page, or a number): %r" % b[:70]
# (d) Contents lists every other ## heading, with the anchor GitHub makes
def slug(h):
    h = h.lower().strip()
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")
sections = [l[3:].strip() for l in lines if l.startswith("## ")]
assert "Contents" in sections, "no Contents section"
for h in sections:
    if h != "Contents":
        assert "](#%s)" % slug(h) in text, "Contents has no link for %r (#%s)" % (h, slug(h))
# (e) the licence is the last section
assert sections[-1] == "License", "last section is %r, not License" % sections[-1]
# (f) the Tools table names what the plugin uses, with required / optional, and the comparison evidence exists
body = text[text.index("## Tools it uses"):]
body = body[:body.index("\n## ", 5)] if "\n## " in body[5:] else body
for tool, needs in [("python3", "Required"), ("bash", "Required"), ("git", "Required"), ("okf-skills", "Vendored"),
                    ("PyYAML", "Vendored"), ("okflint", "Optional"), ("uv", "Optional"), ("pre-commit", "Optional"),
                    ("jq", "Optional"), ("GitHub Actions", "Optional")]:
    row = next((l for l in body.split("\n") if l.startswith("|") and l.strip("|").split("|")[0].strip().startswith(tool)), None)  # match the FIRST cell
    assert row, "the Tools table has no row for %s" % tool
    assert needs in row, "the %s row does not say %s: %r" % (tool, needs, row[:90])
assert os.path.exists(os.path.join(root, "docs", "comparison-2026-10-17.md")), "docs/comparison-2026-10-17.md is missing"
assert "](docs/comparison-2026-10-17.md)" in text, "the README does not link the comparison evidence"
PY
[ $? -eq 0 ] && ok "LT-39 the README is a funnel: one-line description, demo, 'Why use it' first (evidence in every bullet), a Contents list for every section, a Tools table checked by name, the licence last" || bad "LT-39 README funnel" "$(head -2 "$TMP_W/funnel_err.txt" | tr '\n' ' ' | cut -c1-300)"
# every tool the Tools table names is really used by the repo (not a wish list)
tools_ok=1; miss=""
chk() { grep -qE "$2" "$3" 2>/dev/null || { tools_ok=0; miss="$miss $1"; }; }
chk okflint 'okflint' "$PLUGIN/config/pinned-versions.txt"
chk uv 'uv tool install' "$PLUGIN/scripts/okf-check"
chk git 'git' "$PLUGIN/scripts/okf-verify"
chk pre-commit 'language: script' "$MKT_ROOT/.pre-commit-hooks.yaml"
chk jq 'jq ' "$PLUGIN/scripts/doc-reuse-guard.sh"
chk "GitHub Actions" 'composite' "$MKT_ROOT/action.yml"
[ -d "$PLUGIN/vendor/pyyaml" ] || { tools_ok=0; miss="$miss PyYAML"; }
[ -f "$PLUGIN/vendor/okf_validate.py" ] || { tools_ok=0; miss="$miss okf-skills"; }
[ "$tools_ok" -eq 1 ] && ok "LT-40 every tool the README's Tools table names is used by the repo (okflint, uv, git, pre-commit, jq, the Action, the vendored PyYAML and validator)" || bad "LT-40 Tools table vs the repo" "not found in the repo:$miss"

# --- LT-47 (0.9.2 F6, #43): the Action says when nothing, or less than everything, was checked ---------------------
# A job was green for an empty or mistyped bundle path and on a runner without okflint (exit 0, "0 concepts", L2 SKIPPED).
AB5="$TMP_W/ab5_empty"; mkab "$AB5"
runact "$AB5" false false; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^::warning::.*0 concepts' "$TMP_W/act_out.txt"; } \
  && ok "LT-47a a bundle with 0 concepts still exits 0 but the job log carries a ::warning:: that nothing was checked" \
  || bad "LT-47a empty bundle warning" "rc=$rc $(grep -n 'warning\|concepts' "$TMP_W/act_out.txt" | head -2 | tr '\n' ' ')"
runact "$AB1" false false; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^::warning::.*skipped.*L2 profile' "$TMP_W/act_out.txt"; } \
  && ok "LT-47b a skipped layer (no okf-base.yaml / no okflint) exits 0 with a ::warning:: that names the layer" \
  || bad "LT-47b skipped-layer warning" "rc=$rc $(grep -n 'warning\|SKIPPED' "$TMP_W/act_out.txt" | head -2 | tr '\n' ' ')"
runact "$AB1" false false "$MKT_ROOT" true; rc=$?
{ [ "$rc" -eq 3 ] && grep -q '^::error::.*house rules' "$TMP_W/act_out.txt"; } \
  && ok "LT-47c require-house-rules: true fails the job (exit 3) with an ::error:: when L2 was skipped" \
  || bad "LT-47c require-house-rules" "rc=$rc $(grep -n 'error\|SKIPPED' "$TMP_W/act_out.txt" | head -2 | tr '\n' ' ')"
runact "$AB1" false false "$MKT_ROOT" yes; rc=$?
{ [ "$rc" -eq 64 ] && grep -q "require-house-rules must be 'true' or 'false'" "$TMP_W/act_out.txt"; } \
  && ok "LT-47d a require-house-rules value other than true/false is refused (exit 64)" \
  || bad "LT-47d invalid require-house-rules" "rc=$rc $(head -1 "$TMP_W/act_out.txt")"

echo
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
