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
. "$HERE/../tests/cite-sha.sh"   # cite_sha: a fixture commit cited with a digit (RV-35)
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
  grep -q '^---$' <<<"$(head -1 "$s")" && ok "P-3 $(basename "$(dirname "$s")")/SKILL.md has frontmatter" \
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
# p10_verdict <source version> <cache root> <source plugin folder>: ONE line, tab-separated, for the caller to report:
# `ok<TAB>title`, `bad<TAB>title<TAB>detail` or `skip<TAB>title`. A function so a test can run it against a fixture cache.
# p10_drift <installed plugin folder> <source plugin folder>: what differs, the first three lines. The WHOLE folder, not
# scripts/ alone: the manifest, hooks.json, skills, bin, config and vendor run as much as a script does. Left out: `*.test.sh`
# (shipped, never invoked by a hook or skill) and `__pycache__` (Python writes it beside a module it imports; on the real
# machine, 0.9.35, it was the only difference between the installed copy and the source:
# `Only in ~/.claude/plugins/cache/ahmedmaged-okf/okf/0.9.35/vendor/pyyaml/yaml: __pycache__`).
p10_drift() { diff -rq -x '*.test.sh' -x '__pycache__' "$1" "$2" 2>&1 | head -3 | tr '\n' ' '; }
p10_verdict() {
  local pv="$1" root="$2" src="$3" cache drift inst kind id ver folder ipath proj
  # With the `claude` CLI on PATH the plugin manager is asked first: `claude plugin list --json` is an array with, per
  # installed plugin, id, version, enabled, scope and installPath (a COPY under ~/.claude/plugins/cache) and, for a
  # directory marketplace, folderVersion. An okf entry that is enabled at the source version passes, once the copy at
  # installPath holds the same plugin folder as the source (a version number says nothing about edits made after it); a
  # missing installPath fails. Output that is not a JSON array, or an array without an okf entry of this user or repository, says nothing
  # about okf: the cache comparison below then decides, as it does where the CLI is absent. The time limit lives in
  # python (P10_LIST_LIMIT seconds), so it holds on a machine without the `timeout` binary.
  if command -v claude >/dev/null 2>&1; then
    proj=$(cd "$src/.." 2>/dev/null && pwd -P)
    IFS=$'\t' read -r kind id ver folder ipath <<< "$("$REALPY" -c '
import json, os, signal, subprocess, sys
pv, proj = sys.argv[1], sys.argv[2]
try:
    # A new session, so the whole group can be stopped: a hung claude may have started children that hold its pipes.
    proc = subprocess.Popen(["claude", "plugin", "list", "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        out = proc.communicate(timeout=float(os.environ.get("P10_LIST_LIMIT", "30")))[0]
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        sys.exit(0)
    d = json.loads(out)
except (OSError, ValueError, subprocess.SubprocessError):
    sys.exit(0)
if not isinstance(d, list):
    sys.exit(0)
def mine(e):
    # An entry installed for another project (scope project, another projectPath) is not this install.
    if e.get("scope") == "project" and os.path.realpath(str(e.get("projectPath", ""))) != proj:
        return False
    return isinstance(e, dict) and str(e.get("id", "")).split("@")[0] == "okf"
es = [e for e in d if isinstance(e, dict) and mine(e)]
if not es:
    sys.exit(0)
def on(e):
    return e.get("enabled") is True or str(e.get("enabled")).lower() == "true"
def row(kind, e):
    fv = e.get("folderVersion")
    print("\t".join([kind, str(e.get("id")), str(e.get("version")), str(fv) if fv and fv != e.get("version") else "-",
                     str(e.get("installPath") or "-")]))
good = [e for e in es if on(e) and e.get("version") == pv]
live = [e for e in es if on(e)]
if good:
    row("ok", good[0])
elif live:
    row("stale", live[0])
else:
    row("disabled", es[0])
' "$pv" "$proj")"
    case "$kind" in
      ok)
        # An assignment on its own: the diff in a pipeline exits 1 on a difference, and under pipefail that would end an && chain.
        drift=""; if [ "$ipath" != "-" ] && [ -d "$ipath" ]; then drift=$(p10_drift "$ipath" "$src"); fi
        if [ "$ipath" != "-" ] && [ ! -d "$ipath" ]; then
          printf 'bad\tP-10 the installed plugin is MISSING — its folder is not there\tclaude plugin list shows %s at version %s, but its installPath %s does not exist, so nothing of it can load; fix: claude plugin update %s (or uninstall and install it again)\n' "$id" "$ver" "$ipath" "$id"
        elif [ -n "$drift" ]; then
          printf 'bad\tP-10 the installed plugin is STALE — users run pre-fix code\tclaude plugin list shows %s at version %s, but its copy at %s differs from this source tree; bump the version, then `claude plugin update %s`; drift: %s\n' "$id" "$ver" "$ipath" "$id" "$drift"
        else
          printf 'ok\tP-10 the INSTALLED plugin matches this source tree (claude plugin list: %s %s, enabled)\n' "$id" "$ver"
        fi
        return 0 ;;
      stale) printf 'bad\tP-10 the installed plugin is STALE — users run pre-fix code\tclaude plugin list shows %s at version %s, this source tree is %s%s; fix: claude plugin update %s, then restart the session\n' \
               "$id" "$ver" "$pv" "$([ "$folder" = "-" ] || printf ' (its marketplace folder holds %s)' "$folder")" "$id"; return 0 ;;
      disabled) printf 'bad\tP-10 the installed plugin is disabled — nothing of it runs\tclaude plugin list shows %s at version %s and enabled is not true; fix: claude plugin enable %s\n' "$id" "$ver" "$id"; return 0 ;;
    esac
  fi
  cache=$(ls -d "$root"/*/okf/"$pv"/ 2>/dev/null | head -1)
  if [ -n "$cache" ] && [ -d "$cache/scripts" ]; then
    # Compare the RUNTIME surface only. `*.test.sh` ships in the package but no
    # hook or skill invokes it, so a test edit is not "users run pre-fix code" —
    # and a gate that cries stale on every dev edit gets ignored, which is the
    # failure mode this whole repo exists to fight.
    drift=$(p10_drift "$cache" "$src")
    if [ -z "$drift" ]; then
      printf 'ok\tP-10 the INSTALLED plugin matches this source tree\n'
    else
      printf 'bad\tP-10 the installed plugin is STALE — users run pre-fix code\tbump the version, then `claude plugin update okf@<marketplace>`; drift: %s\n' "$drift"
    fi
  else
    # Only a genuine "nothing installed at all" is a skip. An OLDER okf in the cache is the commonest stale state (the
    # version was bumped and the plugin never reinstalled): that is a failure, not a skip (0.9.2 F7).
    inst=$(p10_installed_versions "$root")
    if [ -n "$inst" ]; then
      printf 'bad\tP-10 the installed plugin is STALE — only other versions are installed\tsource is %s, the cache holds: %s; reinstall: claude plugin uninstall okf@<marketplace> && claude plugin install okf@<marketplace>\n' "$pv" "$inst"
    else
      printf 'skip\tP-10 — plugin not installed on this machine (a skip, not a pass)\n'
    fi
  fi
}
p10_report() { local k a b; IFS=$'\t' read -r k a b <<< "$1"; case "$k" in ok) ok "$a";; bad) bad "$a" "$b";; skip) skip "$a";; esac; }
if [ -z "$pv" ]; then
  bad "P-10 cannot run — no version could be read from plugin.json" \
      "P-9 above explains why; P-10 is NOT a skip here, it is unable to check"
else
  p10_report "$(p10_verdict "$pv" "$HOME/.claude/plugins/cache" "$PLUGIN")"
fi
# P-10b: the cache listing itself, against a fixture cache (the live one above depends on this machine).
mkdir -p "$TMP_W/p10cache/mk/okf/0.0.1/scripts" "$TMP_W/p10cache/mk/okf/0.0.2/scripts"
[ "$(p10_installed_versions "$TMP_W/p10cache")" = "0.0.1 0.0.2 " ] && ok "P-10b the cache listing names every installed okf version" || bad "P-10b cache listing" "got '$(p10_installed_versions "$TMP_W/p10cache")'"
[ -z "$(p10_installed_versions "$TMP_W/p10none")" ] && ok "P-10c an empty cache lists nothing (that is the skip case)" || bad "P-10c empty cache" "listed something"

# P-10d..g: the cache comparison against fixture caches: the same version and the same scripts pass, a changed script is
# stale, only other versions is stale, an empty cache is a skip.
mkdir -p "$TMP_W/p10nobin" "$TMP_W/p10src/scripts" "$TMP_W/p10src/.claude-plugin" "$TMP_W/p10src/skills/okf" "$TMP_W/p10c3/mk/okf/2.0.0/scripts" "$TMP_W/p10c4"
p10_cache() { PATH="$TMP_W/p10nobin:/usr/bin:/bin" p10_verdict "$@"; }   # the claude CLI hidden: the cache comparison alone
printf 'echo a\n' > "$TMP_W/p10src/scripts/a.sh"; printf '{"name":"okf","version":"3.0.0"}\n' > "$TMP_W/p10src/.claude-plugin/plugin.json"; printf 'skill text\n' > "$TMP_W/p10src/skills/okf/SKILL.md"
for n in 1 2 5 6; do mkdir -p "$TMP_W/p10c$n/mk/okf/3.0.0"; cp -R "$TMP_W/p10src/." "$TMP_W/p10c$n/mk/okf/3.0.0/"; done   # c1 identical; c2 script, c5 manifest, c6 skill changed below
printf 'echo OLD\n' > "$TMP_W/p10c2/mk/okf/3.0.0/scripts/a.sh"; printf '{"name":"okf","version":"3.0.0","x":1}\n' > "$TMP_W/p10c5/mk/okf/3.0.0/.claude-plugin/plugin.json"; printf 'skill text edited\n' > "$TMP_W/p10c6/mk/okf/3.0.0/skills/okf/SKILL.md"
v=$(p10_cache 3.0.0 "$TMP_W/p10c1" "$TMP_W/p10src"); case "$v" in ok$'\t'*) ok "P-10d the same version with the same scripts passes";; *) bad "P-10d matching cache" "got: $v";; esac
v=$(p10_cache 3.0.0 "$TMP_W/p10c2" "$TMP_W/p10src"); case "$v" in bad$'\t'*"STALE — users run pre-fix code"*"drift:"*) ok "P-10e the same version with a changed script is stale";; *) bad "P-10e drifted cache" "got: $v";; esac
v=$(p10_cache 3.0.0 "$TMP_W/p10c3" "$TMP_W/p10src"); case "$v" in bad$'\t'*"only other versions"*"2.0.0"*) ok "P-10f only an older version installed is stale and names it";; *) bad "P-10f older version" "got: $v";; esac
v=$(p10_cache 3.0.0 "$TMP_W/p10c4" "$TMP_W/p10src"); case "$v" in skip$'\t'*) ok "P-10g an empty cache is a skip";; *) bad "P-10g empty cache" "got: $v";; esac

# P-10h..n: with the `claude` CLI on PATH the installed plugin is read from `claude plugin list --json`: a stub prints the
# list. The cache fixtures are chosen to DISAGREE with the list wherever a test needs to show the list wins.
mkdir -p "$TMP_W/p10bin" "$TMP_W/p10nobin"
printf '#!/bin/sh\nprintf "%%s" "$P10_STUB_OUT"\nexit "${P10_STUB_RC:-0}"\n' > "$TMP_W/p10bin/claude"; chmod +x "$TMP_W/p10bin/claude"
p10_with() { # <stub output> <cache root>: the verdict with the stub `claude` first on PATH
  PATH="$TMP_W/p10bin:$PATH" P10_STUB_OUT="$1" p10_verdict 3.0.0 "$2" "$TMP_W/p10src"
}
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":true,"installPath":"'"$TMP_W"'/p10c1/mk/okf/3.0.0"}]' "$TMP_W/p10c4")
case "$v" in ok$'\t'*"claude plugin list"*"okf@mk"*"3.0.0"*) ok "P-10h an enabled okf at the source version passes from the list alone (no cache needed)";; *) bad "P-10h list ok" "got: $v";; esac
v=$(p10_with '[{"id":"okf@mk","version":"2.0.0","enabled":true,"installPath":"x"}]' "$TMP_W/p10c1")
case "$v" in bad$'\t'*"2.0.0"*"3.0.0"*"claude plugin update okf@mk"*) ok "P-10i an older installed version fails, names both versions and the update command, whatever the cache holds";; *) bad "P-10i stale version" "got: $v";; esac
v=$(p10_with '[{"id":"okf@mk","version":"2.0.0","enabled":true,"folderVersion":"3.0.0"}]' "$TMP_W/p10c1")
case "$v" in bad$'\t'*"its marketplace folder holds 3.0.0"*) ok "P-10o a stale entry of a directory marketplace also names the version the folder holds";; *) bad "P-10o folder version" "got: $v";; esac
# P-10p: the version alone is not the proof: the installed copy (installPath) is compared with the source scripts, as the
# cache comparison does. p10c2 holds a changed script, p10c1 the same one.
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":true,"installPath":"'"$TMP_W"'/p10c2/mk/okf/3.0.0"}]' "$TMP_W/p10c4")
case "$v" in bad$'\t'*"STALE — users run pre-fix code"*"p10c2/mk/okf/3.0.0"*"drift:"*) ok "P-10p the right version with a changed installed script is stale and names the installed folder";; *) bad "P-10p drifted installPath" "got: $v";; esac
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":true,"installPath":"'"$TMP_W"'/p10c1/mk/okf/3.0.0"}]' "$TMP_W/p10c4")
case "$v" in ok$'\t'*) ok "P-10p2 the right version with the same installed plugin folder passes";; *) bad "P-10p2 matching installPath" "got: $v";; esac
# P-10p3: an installPath that is not there means the plugin cannot load: that fails and says so.
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":true,"installPath":"'"$TMP_W"'/nowhere"}]' "$TMP_W/p10c4")
case "$v" in bad$'\t'*"installPath"*"nowhere"*"does not exist"*) ok "P-10p3 an installPath that does not exist fails and names it";; *) bad "P-10p3 missing installPath" "got: $v";; esac
# P-10t, P-10u: the whole plugin folder is compared, not only scripts/: a one-line edit to the manifest (c5) or to a skill
# (c6) in the installed copy is stale, by the list and by the cache comparison alike.
for pair in "t:5:.claude-plugin/plugin.json" "u:6:skills/okf/SKILL.md"; do
  id=${pair%%:*}; rest=${pair#*:}; n=${rest%%:*}; file=${rest#*:}
  v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":true,"installPath":"'"$TMP_W"'/p10c'$n'/mk/okf/3.0.0"}]' "$TMP_W/p10c4"); w=$(p10_cache 3.0.0 "$TMP_W/p10c$n" "$TMP_W/p10src")
  { case "$v" in bad$'\t'*"STALE — users run pre-fix code"*"$file"*) true;; *) false;; esac; case "$w" in bad$'\t'*"STALE — users run pre-fix code"*"$file"*) true;; *) false;; esac; } \
    && ok "P-10$id an edit to $file in the installed copy is stale (list and cache comparison)" || bad "P-10$id edit to $file" "list: $v | cache: $w"
done
# P-10q: an entry that belongs to another project (scope project, a projectPath that is not this repository) is not this install.
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":true,"scope":"project","projectPath":"/some/other/project"}]' "$TMP_W/p10c4")
case "$v" in skip$'\t'*) ok "P-10q an okf entry of another project does not count as installed";; *) bad "P-10q project scope" "got: $v";; esac
# P-10r: enabled written as a string: "true" counts, "false" does not and the message says what it saw.
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":"true"}]' "$TMP_W/p10c4"); w=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":"false"}]' "$TMP_W/p10c4")
{ case "$v" in ok$'\t'*) true;; *) false;; esac; case "$w" in bad$'\t'*"disabled"*"enabled is not true"*) true;; *) false;; esac; } \
  && ok "P-10r enabled as the string true passes; as the string false it fails with 'enabled is not true'" || bad "P-10r string enabled" "got: $v | $w"
# P-10s: a claude that hangs must not hang the suite, and must not leave a process behind: the stub starts a child
# (no exec, so the shell stays its parent) and the whole process group is stopped when the limit passes.
mkdir -p "$TMP_W/p10hangbin"
printf '#!/bin/sh\nsleep 62 &\necho $! > "$P10_PIDFILE"\nwait\n' > "$TMP_W/p10hangbin/claude"; chmod +x "$TMP_W/p10hangbin/claude"
t0=$SECONDS; v=$(PATH="$TMP_W/p10hangbin:/usr/bin:/bin" P10_LIST_LIMIT=1 P10_PIDFILE="$TMP_W/p10hang.pid" p10_verdict 3.0.0 "$TMP_W/p10c1" "$TMP_W/p10src"); t1=$((SECONDS-t0))
# Alive means running: in a container with no init process a killed orphan stays as a zombie (state Z) that `kill -0` still sees.
sleep 1; alive=no; st=$(ps -o stat= -p "$(cat "$TMP_W/p10hang.pid" 2>/dev/null)" 2>/dev/null | tr -d ' ')
case "$st" in ""|Z*) ;; *) alive=yes; kill "$(cat "$TMP_W/p10hang.pid")" 2>/dev/null ;; esac
# wallclock-ok: a hang bound: P10_LIST_LIMIT=1 stops a stub that waits 62 s; 6 s sits far below the sleep
{ [ "$t1" -lt 6 ] && [ "$alive" = no ] && case "$v" in ok$'\t'"P-10 the INSTALLED plugin matches this source tree") true;; *) false;; esac; } \
  && ok "P-10s a claude that hangs is given up on after the limit, its child is stopped too, and the cache comparison runs (${t1}s)" || bad "P-10s hung claude" "took ${t1}s, child still running: $alive (state '$st'), got: $v"
v=$(p10_with '[{"id":"okf@mk","version":"3.0.0","enabled":false,"installPath":"x"}]' "$TMP_W/p10c1")
case "$v" in bad$'\t'*"disabled"*"claude plugin enable okf@mk"*) ok "P-10j a disabled okf fails and names the enable command";; *) bad "P-10j disabled" "got: $v";; esac
v=$(p10_with '[{"id":"okf@old","version":"2.0.0","enabled":false},{"id":"okf@mk","version":"3.0.0","enabled":true}]' "$TMP_W/p10c4")
case "$v" in ok$'\t'*"okf@mk"*) ok "P-10k two okf entries: the enabled one at the source version is enough";; *) bad "P-10k two entries" "got: $v";; esac
v=$(p10_with 'error: not logged in' "$TMP_W/p10c1"); w=$(p10_with 'error: not logged in' "$TMP_W/p10c4")
{ case "$v" in ok$'\t'"P-10 the INSTALLED plugin matches this source tree") true;; *) false;; esac; case "$w" in skip$'\t'*) true;; *) false;; esac; } \
  && ok "P-10l output that is not JSON falls back to the cache comparison (match, and skip)" || bad "P-10l not JSON" "got: $v | $w"
v=$(p10_with '[{"id":"other@x","version":"9.9.9","enabled":true}]' "$TMP_W/p10c1"); w=$(p10_with '[]' "$TMP_W/p10c4")
{ case "$v" in ok$'\t'"P-10 the INSTALLED plugin matches this source tree") true;; *) false;; esac; case "$w" in skip$'\t'*) true;; *) false;; esac; } \
  && ok "P-10m a list without an okf entry falls back to the cache comparison" || bad "P-10m no okf entry" "got: $v | $w"
v=$(PATH="$TMP_W/p10nobin:/usr/bin:/bin" p10_verdict 3.0.0 "$TMP_W/p10c1" "$TMP_W/p10src")
{ ! PATH="$TMP_W/p10nobin:/usr/bin:/bin" command -v claude >/dev/null 2>&1 && case "$v" in ok$'\t'"P-10 the INSTALLED plugin matches this source tree") true;; *) false;; esac; } \
  && ok "P-10n without the claude CLI on PATH the cache comparison runs" || bad "P-10n no claude CLI" "claude on that PATH: $(PATH="$TMP_W/p10nobin:/usr/bin:/bin" command -v claude); got: $v"

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
# __pycache__ is left out: it never ships (.gitignore, and tools/export-public.sh excludes it), and okf-export.test.sh
# writes one by loading okf-export, so Z-2 failed whenever that suite ran first (the CI order of the public tree).
done < <(find "$PLUGIN/scripts" -type d -name __pycache__ -prune -o -type f -print0 2>/dev/null)
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
  # 0.9.48: the okf-verify hook through the real pre-commit tool. The hook repo above holds the new .pre-commit-hooks.yaml.
  PCV2="$PCX/vwork"; mkdir -p "$PCV2"; pcgit "$PCV2" init -q; printf 'x\n' > "$PCV2/code.txt"; pcgit "$PCV2" add code.txt; pcgit "$PCV2" commit -qm "code"
  PCV2_SHA=$(cite_sha "$PCV2")
  mkab "$PCV2"; printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in %s.\n' "$PCV2_SHA" > "$PCV2/n.md"
  printf 'repos:\n  - repo: %s\n    rev: %s\n    hooks:\n      - id: okf-verify\n        args: [., --repo, ., --strict]\n' "$PCX/hookrepo" "$PCREV" > "$PCV2/.pre-commit-config.yaml"
  ( cd "$PCV2" && pcenv pre-commit install >/dev/null 2>&1 )
  pcgit "$PCV2" add -A; pcgit "$PCV2" commit -qm "cited commit" >"$TMP_W/pcv_c1.txt" 2>&1; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'okf-verify' "$TMP_W/pcv_c1.txt" && grep -q 'Passed' "$TMP_W/pcv_c1.txt"; } \
    && ok "LT-49o (REAL pre-commit) the okf-verify hook confirms a note's cited commit and the commit goes through" \
    || bad "LT-49o real pre-commit okf-verify" "rc=$rc $(tail -3 "$TMP_W/pcv_c1.txt" | tr '\n' ' ')"
  printf -- '---\ntype: Lesson\ntitle: U\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nNo citation here.\n' > "$PCV2/u.md"
  pcgit "$PCV2" add -A; pcgit "$PCV2" commit -qm "no claim" >"$TMP_W/pcv_c2.txt" 2>&1; rc=$?
  { [ "$rc" -ne 0 ] && grep -q 'Failed' "$TMP_W/pcv_c2.txt" && [ "$(pcgit "$PCV2" rev-list --count HEAD)" = 2 ]; } \
    && ok "LT-49p (REAL pre-commit) with --strict in the user's args a note with no checkable claim BLOCKS the commit; HEAD unchanged" \
    || bad "LT-49p real pre-commit okf-verify --strict" "rc=$rc $(tail -4 "$TMP_W/pcv_c2.txt" | tr '\n' ' ')"
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
{ grep -q '^| macOS' "$TMP_W/readme_platforms.txt" && grep -q '^| Linux' "$TMP_W/readme_platforms.txt" && grep -q '^| Windows | Not supported' "$TMP_W/readme_platforms.txt"; } \
  && ok "LT-30a S23-H1 the README has a Platforms section with rows for macOS and Linux, and a Windows row that says not supported" \
  || bad "LT-30a S23-H1" "Platforms section missing or incomplete: $(head -c 120 "$TMP_W/readme_platforms.txt" | tr '\n' ' ')"
win_bad=$(grep -n -i 'windows' "$README" | grep -v -i 'wsl\|no native\|unsupported' || true)
[ -z "$win_bad" ] && ok "LT-30b S23-N1 every README line that mentions Windows says WSL, no native support, or unsupported (a bare 'not' does not count)" || bad "LT-30b S23-N1" "$win_bad"
grep -i '^| Windows' "$TMP_W/readme_platforms.txt" > "$TMP_W/readme_winrow.txt"
# Windows is not supported, now or later (owner decision 2026-10-24, RM-600 dropped): the row says so for WSL, the Action
# and the pre-commit hook, names the two supported platforms, and no longer calls Windows UNVERIFIED (a pending check).
{ [ -s "$TMP_W/readme_winrow.txt" ] && ! grep -q 'UNVERIFIED' "$TMP_W/readme_winrow.txt" && grep -q 'macOS and Linux' "$TMP_W/readme_winrow.txt" \
  && grep -q 'WSL' "$TMP_W/readme_winrow.txt" && grep -q 'pre-commit' "$TMP_W/readme_winrow.txt" && grep -q 'Action' "$TMP_W/readme_winrow.txt"; } \
  && ok "LT-30c S23-E1 the Windows row says WSL, the Action and the pre-commit hook are not supported, only macOS and Linux are" \
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
for tool in okf-check okf-verify okf-export; do
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
for tool in okf-check okf-verify okf-export; do
  ln -sf "$PLUGIN/bin/$tool" "$SLN/$tool"
  want=$("$PLUGIN/scripts/$tool" --nope-not-a-flag >/dev/null 2>&1; echo $?); got=$(cd / && PATH="$SLN:$PATH" "$tool" --nope-not-a-flag >/dev/null 2>&1; echo $?)
  [ "$want" = "$got" ] && [ "$got" != 126 ] && [ "$got" != 127 ] && ok "LT-31h $tool reached through a SYMLINK to the wrapper behaves like the real tool (exit $got)" || bad "LT-31h $tool via symlink" "real exit $want, via symlink $got"
done
# Nothing an agent needs may be lost when text moves out of SKILL.md into references/. Each phrase below was in
# the old SKILL.md and must be in SKILL.md or a reference file.
lost=""
for needle in 'fenced code' 'var/folders' 'was rewritten, or' 'stale_after. is required' '--migrate' 'previous okflint' 'no checkable claim'; do
  grep -rq -- "$needle" "$PLUGIN/skills/okf/" || lost="$lost [$needle]"
done
[ -z "$lost" ] && ok "LT-31i every okf-verify, install and setup rule of the old SKILL.md is still in SKILL.md or a reference file" || bad "LT-31i rules lost in the move" "missing:$lost"
grep -Eq -- '--strict. also fails on UNRESOLVED and on +notes with no checkable claim' <<<"$(tr '\n' ' ' < "$PLUGIN/skills/okf/SKILL.md")" && ok "LT-31j SKILL.md says --strict also fails on notes with no checkable claim (okf-verify D-9)" || bad "LT-31j --strict wording" "SKILL.md names only UNRESOLVED"
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
{ grep -q 'OKF is' <<<"$head20" && grep -q 'A bundle is' <<<"$head20"; } \
  && ok "LT-36a the first screen defines OKF and bundle for a stranger" || bad "LT-36a first screen" "OKF / bundle are not defined in the first 20 lines"
SAMPLE_BUNDLE="$TMP_W/readme_sample"; mkdir -p "$SAMPLE_BUNDLE/notes"
printf -- '---\nokf_version: "0.2"\n---\n# Notes\n' > "$SAMPLE_BUNDLE/notes/index.md"; printf -- '# Log\n\n## 2026-01-01\n* created\n' > "$SAMPLE_BUNDLE/notes/log.md"
printf -- '---\ntype: Lesson\ntitle: Payment limits\ndescription: Limits for payouts.\nstatus: draft\ntags: [payments]\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: human:finance-owner\n    at: "2026-02-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$SAMPLE_BUNDLE/notes/limits.md"
( cd "$SAMPLE_BUNDLE" && HOME="$TMP_W" "$PLUGIN/scripts/okf-check" notes ) > "$TMP_W/readme_sample_real.txt" 2>&1
# The sample's L2 profile line is what a machine WITH okflint prints. Without okflint that one line reads "okflint not
# installed", so it cannot be compared here: every other line still is, and the L2 line is a skip, never a pass.
have_okflint=0; command -v okflint >/dev/null 2>&1 && have_okflint=1
"$REALPY" - "$README" "$TMP_W/readme_sample_real.txt" "$have_okflint" <<'PY' 2>"$TMP_W/sample_err.txt"
import sys
readme, real = open(sys.argv[1]).read().split("\n"), set(open(sys.argv[2]).read().split("\n"))
start = next((i for i, l in enumerate(readme) if l.strip() == "$ okf-check notes"), None)
if start is None: sys.exit("no '$ okf-check notes' sample block in the README")
lines = []
for l in readme[start + 1:]:
    if l.startswith("```"): break
    lines.append(l)
body = [l for l in lines if l.strip()]
if len(body) < 5: sys.exit("sample too short: %d lines" % len(body))
l2 = [l for l in body if l.startswith("  L2 profile ")]
if sys.argv[3] != "1": body = [l for l in body if l not in l2]
missing = [l for l in body if l not in real]
if missing: sys.exit("README sample lines that real output does not contain: %r" % missing)
if sys.argv[3] != "1" and l2: sys.exit(3)
PY
case $? in
  0) ok "LT-36b the README's sample output is REAL: every line appears in a fresh run on the documented fixture" ;;
  3) ok "LT-36b the README's sample output is REAL: every line but the L2 profile line appears in a fresh run on the documented fixture"
     skip "LT-36b' the sample's L2 profile line — okflint is not installed, so this run prints a different L2 line (UNVERIFIED until okflint is installed)" ;;
  *) bad "LT-36b sample is real" "$(tail -1 "$TMP_W/sample_err.txt" | cut -c1-300)" ;;
esac
! grep -Eq '^\| 0 \| *All gates pass' "$README" && ok "LT-36c the README does not say exit 0 means 'all gates pass' (it also covers skipped layers and warnings)" || bad "LT-36c exit 0 wording" "row 0 still says All gates pass"
awk '/^## Use$/{u=1} u&&/^```bash/{b=1; next} b&&/^```/{exit} b' "$README" > "$TMP_W/readme_usecmds.txt"
grep -q -- '--fail-on-change' "$TMP_W/readme_usecmds.txt" && ok "LT-36d the Use command block shows --fail-on-change (exit 6 needs it)" || bad "LT-36d --fail-on-change" "not in the command block (the exit table alone does not show how to ask for it)"
! grep -q 'CLAUDE_PLUGIN_ROOT' "$README" && ok "LT-36e the README does not rely on \${CLAUDE_PLUGIN_ROOT} (a user's shell does not have it)" || bad "LT-36e CLAUDE_PLUGIN_ROOT" "still mentioned"
li=$(grep -n '^## Install' "$README" | head -1 | cut -d: -f1); lu=$(grep -n '^## Use$' "$README" | head -1 | cut -d: -f1); lp=$(grep -n '^## Platforms' "$README" | head -1 | cut -d: -f1)
{ [ -n "$li" ] && [ -n "$lu" ] && [ -n "$lp" ] && [ "$li" -lt "$lu" ] && [ "$lu" -lt "$lp" ]; } && ok "LT-36f section order: Install, Use, then Platforms" || bad "LT-36f section order" "Install=$li Use=$lu Platforms=$lp"
{ ! grep -q 'remembered zero times' "$README" && ! grep -q 'loudest signal' "$README" && ! grep -q 'Issue forms' "$README"; } && ok "LT-36g no rhetoric and no wrong term (the claims are plain statements)" || bad "LT-36g wording" "rhetorical lines or 'Issue forms' remain"
# The README keeps a short okf-verify summary; the full rules live in the skill's reference, which ships with the plugin.
# The link must land on the heading, and no rule may be lost in the move (each phrase was in the old README paragraph).
VREF="$PLUGIN/skills/okf/references/verify-and-install.md"; vlost=""
grep -q '](plugin/skills/okf/references/verify-and-install.md#what-counts-as-a-claim-and-how-each-is-judged)' "$README" || vlost="$vlost [README link]"
grep -q '^## What counts as a claim, and how each is judged$' "$VREF" || vlost="$vlost [heading]"
for needle in 'searched once' 'path part failed' "file's line count" 'lines start at 1' 'larger number' 'more than 9 digits' 'intent cannot be told' 'paragraph break' '--host-paths' 'fetch-depth: 0'; do
  grep -qF -- "$needle" "$VREF" 2>/dev/null || vlost="$vlost [$needle]"
done
[ -z "$vlost" ] && ok "LT-36j the README links the okf-verify reference, which holds every rule the README paragraph used to carry" || bad "LT-36j okf-verify rules" "missing:$vlost"
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
! grep -q 'says so on every run' <<<"$(tr -s '[:space:]' ' ' < "$README")" \
  && ok "LT-41b the README does not claim the Trust layer speaks 'on every run' (a clean run prints no such note)" || bad "LT-41b README on every run" "claim present"
jsonkeys=$(tr -s '[:space:]' ' ' < "$SKILL_MD" | grep -o -- '--json.\{1,4\} carries the verdict[^.]*' | head -1)
{ for k in 'errors\[\]' 'l2_findings\[\]' 'stale\[\]' 'skipped\[\]'; do grep -q "$k" <<<"$jsonkeys" || exit 1; done; } \
  && ok "LT-41c the skill names the --json finding lists (errors, l2_findings, stale, skipped)" || bad "LT-41c skill --json scope" "sentence missing or incomplete: $jsonkeys"
! grep -q 'refuses to say .ALL GATES PASS' "$SKILL_MD" \
  && ok "LT-41d the skill does not claim ALL GATES PASS is refused while a layer is skipped (an opted-out L2 index still passes)" || bad "LT-41d skill ALL GATES PASS claim" "claim present"
hf=$(grep -E "^  files:" "$MKT_ROOT/.pre-commit-hooks.yaml")
{ grep -Eq "$(printf '%s' "$hf" | sed "s/^  files: '//; s/'\$//")" <<<"kb/okf-base.yaml" && grep -Eq "$(printf '%s' "$hf" | sed "s/^  files: '//; s/'\$//")" <<<"kb/.okfignore"; } \
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

# --- LT-47 (0.9.2 F6): the Action says when nothing, or less than everything, was checked ---------------------
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

# --- S51 (0.9.48): the three tools say what they do. Every user-facing flag, exit code and OKF_* variable is in --help ----------
# The flag, exit-code and variable lists are READ FROM THE CODE (the option parsing of each tool), not typed here, so a flag or
# a variable added without a help line fails this test. What is deliberately kept out of --help is named below with its reason.
S51="$TMP_W/s51"; mkdir -p "$S51"
CHK="$PLUGIN/scripts/okf-check"; VER="$PLUGIN/scripts/okf-verify"; EXP="$PLUGIN/scripts/okf-export"
"$CHK" --help > "$S51/check.txt" 2>&1; rc_hc=$?
"$VER" --help > "$S51/verify.txt" 2>&1; rc_hv=$?
"$EXP" --help > "$S51/export.txt" 2>&1; rc_he=$?
# flags the parsers accept, one per line. okf-check: the arms of its argument loop; the others: add_argument(...) names.
sed -n '/^for a in "\$@"; do/,/^done/p' "$CHK" | grep -oE '^ +-[-a-zA-Z|]*\)' | tr -d ' )' | tr '|' '\n' | grep -E '^--' | sort -u > "$S51/check.flags"
for t in verify export; do
  grep -h 'add_argument(' "$PLUGIN/scripts/okf-$t" | grep -oE '"--[a-z][a-z-]*"' | tr -d '"' | sort -u > "$S51/$t.flags"   # every long option string, whatever comes first in the call
  printf -- '--help\n' >> "$S51/$t.flags"; sort -u -o "$S51/$t.flags" "$S51/$t.flags"
done
# INTERNAL, kept out of the user help: okf-check --fingerprint is the test seam of the change detection (its only caller is
# okf-check.test.sh); okf-verify --check-config/--manifest-dir are how okf-check asks okf-verify to read the okf_check block.
inner_check="--fingerprint"; inner_verify="--check-config --manifest-dir"; inner_export=""
for t in check verify export; do
  eval "inner=\$inner_$t"; miss=""; n=$(wc -l < "$S51/$t.flags" | tr -d ' ')
  while IFS= read -r f; do
    case " $inner " in *" $f "*) continue ;; esac
    grep -qE -- "(^|[^-a-z])$f([^-a-z]|\$)" "$S51/$t.txt" || miss="$miss $f"
  done < "$S51/$t.flags"
  [ -z "$miss" ] && [ "$n" -ge 2 ] && ok "S51-HP-H1 okf-$t --help names every user-facing flag its parser accepts ($n read from the code)" \
    || bad "S51-HP-H1 okf-$t --help flags" "not in the help:$miss (flags read from the parser: $n)"
done
inn=""
for f in $inner_check; do grep -q -- "$f" "$S51/check.txt" && inn="$inn $f"; done
for f in $inner_verify; do grep -q -- "$f" "$S51/verify.txt" && inn="$inn $f"; done
[ -z "$inn" ] && ok "S51-HP-N1 the internal flags (--fingerprint, --check-config, --manifest-dir) are not in the user help" \
  || bad "S51-HP-N1 internal flags in the help" "shown:$inn"
{ [ "$rc_hc" -eq 0 ] && [ "$rc_hv" -eq 0 ] && [ "$rc_he" -eq 0 ]; } && ok "S51-HP-H2 --help exits 0 on all three tools" \
  || bad "S51-HP-H2 --help exit" "okf-check=$rc_hc okf-verify=$rc_hv okf-export=$rc_he"
# the sections every help carries
miss=""
for t in check verify export; do
  for h in '^[Uu]sage:' '^Exit codes' '^Environment' '^Example'; do
    grep -qE -- "$h" "$S51/$t.txt" || miss="$miss okf-$t:$h"
  done
done
[ -z "$miss" ] && ok "S51-HP-H3 each help has a Usage, an Exit codes, an Environment and an Example section" || bad "S51-HP-H3 help sections" "missing:$miss"
# exit codes: okf-check's are the README table and the codes the script holds; okf-verify and okf-export return 0, 1 and 2
miss=""
for c in $( { sed -n 's/^| \([0-9][0-9]*\) |.*/\1/p' "$PLUGIN/../README.md"
              grep -o -E 'exit [0-9]+|EXIT_[A-Z]+=[0-9]+' "$CHK" | sed 's/.*[ =]//'; } | sort -un); do
  grep -qE "^ +$c +[^ ]" "$S51/check.txt" || miss="$miss okf-check:$c"
done
for t in verify export; do for c in 0 1 2; do grep -qE "^ +$c +[^ ]" "$S51/$t.txt" || miss="$miss okf-$t:$c"; done; done
[ -z "$miss" ] && ok "S51-HP-H4 each help lists its exit codes (okf-check: every code of the README table and the script)" || bad "S51-HP-H4 exit codes in the help" "missing:$miss"
# variables: every OKF_* name the code reads, minus the plumbing and test-only names, is in that tool's help and in the README table
INTERNAL_ENV=" OKF_SCRIPTS_DIR OKF_VENDOR_DIR OKF_MAX_NOTE_BYTES OKF_KEEP_LIST OKF_FOLDER_WHY OKF_OUTSIDE_WHY OKF_STOP_WHY OKF_OWNERS_TSV OKF_SYMLINKED_LST OKF_SIZES_JSONL OKF_PLAIN_RE OKF_L3_ROOT OKF_L2_CRASHED OKF_GRAPH_JSON OKF_FACTS_JSONL OKF_TODAY OKF_PINNED_VERSIONS OKF_FORGE_API_BASE OKF_VERSION "
# plumbing: set by one script for another, or the okf_check.max_note_bytes setting in its env form; OKF_TODAY, OKF_PINNED_VERSIONS and
# OKF_FORGE_API_BASE exist for tests and replays (README); OKF_VERSION in okf-export is a Python name imported from the validator.
miss_h=""; miss_r=""; nvars=0
for t in check verify export; do
  for v in $(grep -hoE '\bOKF_[A-Z0-9_]+' "$PLUGIN/scripts/okf-$t" | sort -u); do
    case "$INTERNAL_ENV" in *" $v "*) continue ;; esac
    nvars=$((nvars+1))
    grep -q -- "$v" "$S51/$t.txt" || miss_h="$miss_h okf-$t:$v"
    grep -qE "^\| \`$v\` \|" "$PLUGIN/../README.md" || miss_r="$miss_r $v"
  done
done
[ -z "$miss_h" ] && [ "$nvars" -gt 10 ] && ok "S51-HP-H5 each help names every user-facing OKF_* variable its tool reads ($nvars read from the code)" || bad "S51-HP-H5 variables in the help" "missing:$miss_h (read from the code: $nvars)"
[ -z "$miss_r" ] && ok "S51-HP-H6 the README Environment variables table has a row for each of them (OKF_VERIFY_WALK_LIMIT and OKF_VERIFY_SPAN_LIMIT included)" || bad "S51-HP-H6 README table" "no row for:$miss_r"
miss=""
for v in GITHUB_TOKEN GH_TOKEN GITLAB_TOKEN; do grep -q "$v" "$S51/verify.txt" || miss="$miss $v"; done
for w in CONFIRMED REFUTED UNRESOLVED MOVED; do grep -q "$w" "$S51/verify.txt" || miss="$miss $w"; done
[ -z "$miss" ] && ok "S51-HP-H7 okf-verify --help names the forge tokens it reads and the four verdict words" || bad "S51-HP-H7 okf-verify tokens and verdicts" "missing:$miss"
# the maintainer notes are code comments, not help
miss=""
for w in 'WHY ONE ENTRY POINT' 'PORTABILITY' 'max(rc)' 'bash 3.2'; do grep -qF -- "$w" "$S51/check.txt" && miss="$miss '$w'"; done
[ -z "$miss" ] && ok "S51-HP-N2 okf-check --help carries no maintainer notes" || bad "S51-HP-N2 maintainer notes in the help" "still there:$miss"
# aliases: one spelling for one concept across the tools; the old name still works and gives the same output and exit code
A1="$S51/a_verify"; mkdir -p "$A1"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nPure prose, nothing checkable at all.\n' > "$A1/c.md"
"$VER" "$A1" --strict > "$S51/v1.txt" 2>&1; r1=$?; "$VER" "$A1" --strict-trust > "$S51/v2.txt" 2>&1; r2=$?; "$VER" "$A1" > "$S51/v0.txt" 2>&1; r0=$?
{ [ "$r1" -eq 1 ] && [ "$r2" -eq 1 ] && [ "$r0" -eq 0 ] && cmp -s "$S51/v1.txt" "$S51/v2.txt"; } \
  && ok "S51-AL-H1 okf-verify --strict-trust is --strict: same report, exit 1 on an uncheckable corpus (exit 0 without)" \
  || bad "S51-AL-H1 okf-verify --strict-trust" "strict=$r1 strict-trust=$r2 plain=$r0 $(diff "$S51/v1.txt" "$S51/v2.txt" | head -2 | tr '\n' ' ')"
# an abbreviation that worked before the alias keeps working: --strict-trust is rewritten, not registered, so --str is not ambiguous
"$VER" "$A1" --str > "$S51/v3.txt" 2>&1; r3=$?; "$VER" "$A1" --stric > "$S51/v4.txt" 2>&1; r4=$?
{ [ "$r3" -eq 1 ] && [ "$r4" -eq 1 ] && cmp -s "$S51/v1.txt" "$S51/v3.txt" && cmp -s "$S51/v1.txt" "$S51/v4.txt"; } \
  && ok "S51-AL-E1 okf-verify --str and --stric still mean --strict (same report, exit 1), as before the alias" \
  || bad "S51-AL-E1 okf-verify abbreviation of --strict" "--str=$r3 --stric=$r4 $(head -2 "$S51/v3.txt" | tr '\n' ' ')"
A2="$S51/a_check"; mkdir -p "$A2"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: draft\ntags: [t]\ngenerated:\n  by: agent/1\n  at: "2026-01-01"\nverified:\n  - by: human:finance-owner\n    at: "2026-02-01"\nstale_after: "2099-01-01"\n---\n\nbody\n' > "$A2/n.md"
"$CHK" "$A2" --strict-trust > "$S51/c1.txt" 2>&1; r1=$?; "$CHK" "$A2" --strict > "$S51/c2.txt" 2>&1; r2=$?; "$CHK" "$A2" > "$S51/c0.txt" 2>&1; r0=$?
{ [ "$r1" -eq 1 ] && [ "$r2" -eq 1 ] && [ "$r0" -eq 0 ] && cmp -s "$S51/c1.txt" "$S51/c2.txt"; } \
  && ok "S51-AL-H2 okf-check --strict is --strict-trust: same report, exit 1 on a draft with a human verifier (exit 0 without)" \
  || bad "S51-AL-H2 okf-check --strict" "strict-trust=$r1 strict=$r2 plain=$r0 $(diff "$S51/c1.txt" "$S51/c2.txt" | head -2 | tr '\n' ' ')"
# --- 0.9.48 entry points (cases S51): one skill per job, a description that names all three tools, generic hook texts ---
# Plugin reference (code.claude.com/docs/en/skills, frontmatter table): `description` says what the skill does and when to use it
# (the description and when_to_use text is cut at 1,536 characters in the skill listing); a plugin skill runs as /<plugin>:<skill>.
SKD="$PLUGIN/skills"
ENTRY_SKILLS="check verify export setup explain"
sk48_bad=""
for sk in $ENTRY_SKILLS; do
  f="$SKD/$sk/SKILL.md"
  if [ ! -f "$f" ]; then sk48_bad="$sk48_bad [$sk: no SKILL.md]"; continue; fi
  r=$(pyyaml - "$f" "$sk" <<'PY' 2>&1
import re, sys, yaml
text = open(sys.argv[1]).read(); want = sys.argv[2]
fm = yaml.safe_load(text.split("---")[1])
d = fm.get("description", "")
bad = []
if fm.get("name") != want: bad.append("name is %r, folder is %r" % (fm.get("name"), want))
if not 40 <= len(d) <= 600: bad.append("description is %d characters (40..600)" % len(d))
if "Use when" not in d: bad.append("description has no 'Use when'")
if re.match(r"\s*(Check|Use|Run|Validate|Verify|Export|Set|Explain)\b", d): bad.append("description is an imperative, not third person")
if not fm.get("argument-hint"): bad.append("no argument-hint")
if len(text.splitlines()) > 90: bad.append("body is %d lines (short skills: 90 at most)" % len(text.splitlines()))
tools = fm.get("allowed-tools")
need = {"check": ["okf-check"], "verify": ["okf-verify"], "export": ["okf-export", "okf-check"], "setup": ["okf-check"], "explain": ["okf-check"]}[want]
if not isinstance(tools, list): bad.append("allowed-tools is not a list")
else:
    if "Bash" in tools: bad.append("allowed-tools grants all of Bash")
    for t in need:
        if not any(x.startswith("Bash(") and "/scripts/" + t + '"' in x for x in tools): bad.append("allowed-tools has no Bash(...) pattern for scripts/" + t)
print("; ".join(bad))
PY
  )
  [ -z "$r" ] || sk48_bad="$sk48_bad [$sk: $r]"
done
[ -z "$sk48_bad" ] && ok "LT-48a skills check, verify, export, setup and explain each exist: name = folder, third-person description with 'Use when' (40-600 chars), argument-hint, at most 90 lines, an allowed-tools list scoped to the scripts it runs (not bare Bash)" || bad "LT-48a entry-point skills" "$sk48_bad"
sk48_bad=""
want_cmd() { grep -qF -- "$2" "$SKD/$1/SKILL.md" 2>/dev/null || sk48_bad="$sk48_bad [$1: no '$2']"; }
want_cmd check '"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" $ARGUMENTS'
want_cmd verify '"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" $ARGUMENTS'
want_cmd export '"${CLAUDE_PLUGIN_ROOT}/scripts/okf-export" $ARGUMENTS'
for fl in --doctor --install-deps --init-house-rules --init-ignore; do want_cmd setup "scripts/okf-check\" $fl"; done
want_cmd explain 'references/layers.md'
want_cmd explain '#what-it-checks'
[ -z "$sk48_bad" ] && ok "LT-48b each skill names its exact command: check/verify/export run their tool with \$ARGUMENTS, setup has the four setup commands, explain points to the layer reference and the README row" || bad "LT-48b skill commands" "$sk48_bad"
# Every flag a skill names must exist in the tool it names (a skill that teaches a flag the tool lacks is a wrong answer).
flag_bad=""
for f in "$SKD"/{check,verify,export,setup,explain}/SKILL.md; do
  [ -f "$f" ] || continue
  for fl in $(grep -o -- '--[a-z][a-z-]*' "$f" | sort -u); do
    grep -qF -- "$fl" "$PLUGIN/scripts/okf-check" "$PLUGIN/scripts/okf-verify" "$PLUGIN/scripts/okf-export" "$PLUGIN/scripts/okf-limit.py" 2>/dev/null || flag_bad="$flag_bad [$(basename "$(dirname "$f")") $fl]"
  done
done
[ -z "$flag_bad" ] && ok "LT-48c every --flag named in the five entry-point skills exists in okf-check, okf-verify or okf-export" || bad "LT-48c flags named in skills" "$flag_bad"
# Reachability: every user-facing mode of the three tools is documented in at least one entry point.
reach_bad=""
for fl in --doctor --selftest --json --fail-stale --strict-trust --file --fail-on-change --duplicates --duplicates-body --facts --conserve --fail-lost --deleted --init-ignore --init-house-rules --install-deps --yes --latest --repo --host-paths --since --remote --strict; do
  grep -rqF -- "$fl" "$SKD" || reach_bad="$reach_bad $fl"
done
[ -z "$reach_bad" ] && ok "LT-48d every user-facing flag of okf-check and okf-verify appears in at least one skill (entry point)" || bad "LT-48d flags with no entry point" "$reach_bad"
# The umbrella description names all three tools and their jobs; the body points at the five entry points.
pyyaml - "$SKD/okf/SKILL.md" <<'PY' 2>"$TMP_W/skd_err.txt"
import sys, yaml
text = open(sys.argv[1]).read()
fm = yaml.safe_load(text.split("---")[1]); d = fm["description"]
for w in ("okf-check", "okf-verify", "okf-export", "duplicate", "wikilink", "citation", "lost"):
    assert w in d, "description does not say %r" % w
assert len(d) <= 1024, len(d)
for w in ("validate", "lint", "deduplicating", "before committing"):
    assert w not in d, "the umbrella description carries the job trigger %r (the job skills own those)" % w
assert "Use to choose" in d or "Use when unsure" in d, "no umbrella trigger"
for s in ("check", "verify", "export", "setup", "explain"):
    assert "/okf:" + s in text, "body does not name /okf:" + s
for fl in ("--file", "--facts", "--conserve", "--init-ignore", "--install-deps"):
    assert fl in fm["argument-hint"], "argument-hint lacks " + fl
PY
[ $? -eq 0 ] && ok "LT-48e the okf skill description names okf-check, okf-verify and okf-export with duplicates, wikilinks, citations and lost content; the body names /okf:check .. /okf:explain; the argument-hint lists the missing flags" || bad "LT-48e umbrella skill" "$(head -2 "$TMP_W/skd_err.txt" | tr '\n' ' ')"
# No private ticket numbers in the new shipped text.
nn=$(grep -nE '(^|[^A-Za-z0-9_-])#[0-9]+' "$SKD"/{check,verify,export,setup,explain}/SKILL.md "$SKD/okf/SKILL.md" 2>/dev/null || true)
[ -z "$nn" ] && ok "LT-48f no #NNN issue number in the entry-point skills or the okf skill" || bad "LT-48f private numbers" "$(printf '%s' "$nn" | head -2 | tr '\n' ' ')"
# Hook texts: nothing that only one author's machine or tools can use.
if command -v jq >/dev/null 2>&1; then
  g48_bad=""; G48="$TMP_W/g48"; mkdir -p "$G48/proj/docs" "$G48/home/.claude/lessons" "$G48/cfg" "$G48/extra/area"
  printf '%s\n' "$G48/extra/*" > "$G48/cfg/doc-dirs"
  for fp in "$G48/home/.claude/lessons/new-one.md" "$G48/proj/docs/new-doc.md" "$G48/extra/area/new-note.md"; do
    o=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$fp" | HOME="$G48/home" OKF_DOC_DIRS_FILE="$G48/cfg/doc-dirs" OKF_SEARCH_BIN=/nonexistent bash "$PLUGIN/scripts/doc-reuse-guard.sh" 2>&1)
    [ -n "$o" ] || { g48_bad="$g48_bad [silent for ${fp#$G48/}]"; continue; }
    for w in search_notes 'index lag' '~/.claude' 'families' 'parent note'; do grep -qF -- "$w" <<<"$o" && g48_bad="$g48_bad [${fp#$G48/} says '$w']"; done
    grep -qF -- "Doc-reuse check" <<<"$o" || grep -qF -- "Lesson-reuse check" <<<"$o" || g48_bad="$g48_bad [${fp#$G48/} lost its heading]"
  done
  grep -qF 'rules/tool-selection' "$PLUGIN/scripts/doc-reuse-guard.sh" && g48_bad="$g48_bad [guard header names the author's rule file]"
  grep -qF 'migrate script' "$PLUGIN/scripts/lessons-staleness-check.sh" && g48_bad="$g48_bad [staleness hook says 'migrate script']"
  [ -z "$g48_bad" ] && ok "LT-48g the doc-reuse reminder (lesson, docs and doc-dirs branches) and the staleness hook carry no author-specific tool or path text, and the reminder still fires" || bad "LT-48g generic hook texts" "$g48_bad"
else
  skip "LT-48g — jq absent and the guard exits 0 without it (a skip, not a pass)"
fi
# README line on the PreToolUse hook: it reminds, it does not stop (the script header says "Non-blocking, fail-open").
hookline=$(grep -n 'doc-reuse-guard.sh' "$README" | head -1)
{ grep -qi 'remind' <<<"$hookline" && ! grep -qi 'stops' <<<"$hookline"; } && ok "LT-48h the README says the PreToolUse hook reminds (it is non-blocking) and does not say it stops a write" || bad "LT-48h README hook line" "$hookline"

# --- 0.9.48 docs and CI surfaces (cases S52): which-tool table, split Use section, starter config, Action verify, pre-commit verify ---
python3 - "$README" <<'PY' 2>"$TMP_W/rd_err.txt"
import re, sys
text = open(sys.argv[1]).read(); lines = text.split("\n")
def slug(h): return re.sub(r"[^a-z0-9 _-]", "", h.lower()).replace(" ", "-")
heads = [l for l in lines if re.match(r"#{2,4} ", l)]
anchors = {slug(re.sub(r"^#+ ", "", h)) for h in heads}
i = next(i for i, l in enumerate(lines) if l == "## Which tool do I use?")
tbl = []
for l in lines[i + 1:]:
    if l.startswith("## "): break
    if l.startswith("|"): tbl.append(l)
assert len(tbl) >= 12, "which-tool table has %d lines" % len(tbl)
body = "\n".join(tbl)
for need in ("okf-check", "okf-verify", "okf-export", "/okf:check", "/okf:verify", "/okf:export", "/okf:setup", "/okf:explain", "--conserve", "--duplicates", "--facts", "--doctor"):
    assert need in body, "table lacks " + need
use = []
on = False
for l in lines:
    if l == "## Use": on = True; continue
    if on and l.startswith("## "): break
    if on and l.startswith("### "): use.append(l[4:])
for h in ("Check", "Verify", "Export", "Options", "Ignore", "Environment"):
    assert any(u.startswith(h) for u in use), "Use has no '### %s' sub-heading (has %r)" % (h, use)
contents = []
on = False
for l in lines:
    if l == "## Contents": on = True; continue
    if on and l.startswith("## "): break
    if on: contents += re.findall(r"\]\(#([^)]+)\)", l)
broken = [a for a in contents if a not in anchors]
assert contents and not broken, "Contents links that land on no heading: %r" % broken
assert "which-tool-do-i-use" in contents, "Contents does not list the table"
assert sum(1 for a in contents if a in {slug(u) for u in use}) >= 4, "Contents does not link the Use sub-headings"
PY
[ $? -eq 0 ] && ok "LT-49a the README has a 'Which tool do I use?' table (all three tools, the slash commands, the extra modes), the Use section has Check/Verify/Export/Options/Ignore/Environment sub-headings, and every Contents link lands on a heading" || bad "LT-49a README structure" "$(tail -1 "$TMP_W/rd_err.txt" | cut -c1-300)"
bl=$(grep -n 'Cowork' "$README" | head -3)
{ grep -q 'claude.ai' <<<"$bl" && grep -q 'bin/' "$README"; } && ok "LT-49b the README says whether the plugin's bin/ folder matters on claude.ai and Cowork" || bad "LT-49b bin/ note" "no README line with claude.ai and Cowork"
{ grep -q 'plugin/bin' <<<"$(grep -n 'Cowork' "$README")" || grep -q 'plugin root' <<<"$(grep -n 'Cowork' "$README")"; } && [ -d "$PLUGIN/bin" ] && ok "LT-49c the Cowork note names the folder that triggers it, and plugin/bin exists as it says" || bad "LT-49c bin/ note facts" "the note does not name plugin/bin (or the plugin root), or $PLUGIN/bin is missing"
# Starter config: a commented okf_check block with every option of the schema; uncommented, it passes the config check.
TPL="$PLUGIN/config/okf-base.yaml.template"
"$REALPY" - "$TPL" "$PLUGIN/config/okf-check-block.json" <<'PY' 2>"$TMP_W/tpl_err.txt"
import json, sys
tpl = open(sys.argv[1]).read().split("\n"); schema = json.load(open(sys.argv[2]))
cm = "\n".join(l for l in tpl if l.lstrip().startswith("#"))
assert "# okf_check:" in cm, "no commented okf_check: block"
assert not any(l.startswith("okf_check:") for l in tpl), "the block must stay commented"
def keys(node, out):
    for k, v in node.get("keys", {}).items():
        out.add(k); keys(v, out)
        for sub in ("list", "map"):
            if isinstance(v.get(sub), dict): keys(v[sub], out)
    return out
allk = keys(schema, set()) | {"path"}
missing = sorted(k for k in allk if k not in cm)
assert not missing, "options missing from the commented block: %r" % missing
PY
[ $? -eq 0 ] && ok "LT-49d the starter template carries a commented okf_check: block that names every option of plugin/config/okf-check-block.json" || bad "LT-49d starter okf_check block" "$(tail -1 "$TMP_W/tpl_err.txt" | cut -c1-300)"
TB="$TMP_W/tplb"; mkdir -p "$TB/refs"; mkab "$TB"
"$REALPY" - "$TPL" "$TB/okf-base.yaml" <<'PY'
import re, sys
out, on = [], False
for l in open(sys.argv[1]).read().split("\n"):
    if l.strip() == "# okf_check:": on = True
    if on and l.startswith("# "): l = l[2:]
    elif on and l.strip() == "#": l = ""
    elif on and not l.startswith("#"): on = False
    out.append(l)
open(sys.argv[2], "w").write("\n".join(out))
PY
chk48=$("$PLUGIN/scripts/okf-verify" "$TB" --check-config 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^okf_check:' "$TB/okf-base.yaml"; } && ok "LT-49e with the okf_check block uncommented, okf-verify --check-config accepts the starter (the example values are valid)" || bad "LT-49e uncommented starter" "rc=$rc $(printf '%s' "$chk48" | head -2 | tr '\n' ' ')"
# GitHub Action: verify, repo, args and verify-args inputs.
pyyaml - "$ACT" <<'PY' 2>"$TMP_W/act2_err.txt"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); i = d["inputs"]; env = d["runs"]["steps"][0]["env"]
assert str(i["verify"]["default"]) == "false", "verify default"
assert str(i["repo"]["default"]) == ".", "repo default"
for k in ("args", "verify-args", "report-args"):
    assert k in i and i[k].get("required") is False, k
for k, v in (("INPUT_VERIFY", "verify"), ("INPUT_REPO", "repo"), ("INPUT_ARGS", "args"), ("INPUT_VERIFY_ARGS", "verify-args"), ("INPUT_REPORT_ARGS", "report-args")):
    assert env[k] == "${{ inputs.%s }}" % v, k
assert "${{" not in d["runs"]["steps"][0]["run"]
PY
[ $? -eq 0 ] && ok "LT-49f action.yml declares verify (default false), repo (default .), args, verify-args and report-args, each reaching the script through env" || bad "LT-49f action inputs" "$(tail -1 "$TMP_W/act2_err.txt" | cut -c1-300)"
runact2() { # <bundle> <env assignments...> -- the same contract as runact, with the 0.9.48 inputs
  local b="$1"; shift
  ( cd "$ACTWD" && env INPUT_BUNDLE="$b" INPUT_STRICT_TRUST=false INPUT_FAIL_STALE=false GITHUB_ACTION_PATH="$MKT_ROOT" "$@" \
      bash --noprofile --norc -eo pipefail "$TMP_W/act_run.sh" ) >"$TMP_W/act_out.txt" 2>&1
}
ACTWD="$TMP_W/actwd"; mkdir -p "$ACTWD/bundle"; ( cd "$ACTWD" && g=$(command -v git) && "$g" init -q . && "$g" config user.email a@b && "$g" config user.name n && printf 'x\n' > code.txt && "$g" add code.txt && "$g" commit -q -m first )
mkab "$ACTWD/bundle"; AW_SHA=$(cite_sha "$ACTWD")
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in %s.\n' "$AW_SHA" > "$ACTWD/bundle/n.md"
runact2 bundle INPUT_VERIFY=true; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^okf-verify' "$TMP_W/act_out.txt" && grep -q 'CONFIRMED 1' "$TMP_W/act_out.txt"; } && ok "LT-49g verify: true runs okf-verify after okf-check on the workspace repo: the citation is CONFIRMED, exit 0" || bad "LT-49g verify input" "rc=$rc $(tail -3 "$TMP_W/act_out.txt" | tr '\n' ' ')"
runact2 bundle INPUT_VERIFY=true INPUT_VERIFY_ARGS="--strict"; rc=$?
printf -- '---\ntype: Lesson\ntitle: U\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nNo citation here.\n' > "$ACTWD/bundle/u.md"
runact2 bundle INPUT_VERIFY=true INPUT_VERIFY_ARGS="--strict"; rc2=$?
{ [ "$rc" -eq 0 ] && [ "$rc2" -eq 1 ]; } && ok "LT-49h verify-args reach okf-verify: --strict passes a bundle with only checkable claims (0) and fails one note with no claim (1)" || bad "LT-49h verify-args" "rc=$rc rc2=$rc2 $(tail -2 "$TMP_W/act_out.txt" | tr '\n' ' ')"
rm -f "$ACTWD/bundle/u.md"
runact2 bundle INPUT_VERIFY=false; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q '^okf-verify' "$TMP_W/act_out.txt"; } && ok "LT-49i verify: false (and the unset default) does not run okf-verify" || bad "LT-49i verify off" "rc=$rc"
mkabnote "$ACTWD/bundle" draft agent/1 2099-01-01
runact2 bundle INPUT_ARGS="--strict-trust"; rc=$?
runact2 bundle; rcn=$?
{ [ "$rc" -eq 1 ] && [ "$rcn" -eq 0 ]; } && ok "LT-49j args reach okf-check: --strict-trust fails a draft with a human verifier (1), the same bundle without args passes (0)" || bad "LT-49j args input" "with=$rc without=$rcn"
rm -f "$ACTWD/bundle/n.md"
printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\nFixed in %s.\n' "$AW_SHA" > "$ACTWD/bundle/n.md"
guard_bad=""
for pair in "INPUT_ARGS=--duplicates|" "INPUT_ARGS=--duplicates-body|" "INPUT_ARGS=--facts|" "INPUT_ARGS=--facts launch.countries|" "INPUT_ARGS=--conserve HEAD|" "INPUT_ARGS=--duplicates --conserve HEAD|" "INPUT_ARGS=--file n.md|" "INPUT_ARGS=--fail-lost|" "INPUT_ARGS=--deleted x|" "INPUT_ARGS=--yes|" "INPUT_ARGS=--latest|" "INPUT_ARGS=--nope|" "INPUT_ARGS=--doctor|" "INPUT_ARGS=--strict-trust --selftest|" "INPUT_ARGS=-h|" "INPUT_ARGS=--init-house-rules|" "INPUT_ARGS=--install-deps|" $'INPUT_ARGS=--json\n::error::injected|' "INPUT_VERIFY=yes|" "INPUT_VERIFY=true|INPUT_REPO=--help" "INPUT_VERIFY=true|INPUT_VERIFY_ARGS=--help" "INPUT_VERIFY=true|INPUT_VERIFY_ARGS=--check-config"; do
  ga="${pair%%|*}"; gb="${pair#*|}"
  if [ -n "$gb" ]; then runact2 bundle "$ga" "$gb"; else runact2 bundle "$ga"; fi; rc=$?
  nerr=$(grep -c '^::error::' "$TMP_W/act_out.txt")
  { [ "$rc" -eq 64 ] && [ "$nerr" -eq 1 ] && ! grep -q 'injected' "$TMP_W/act_out.txt"; } || guard_bad="$guard_bad [$(printf '%s' "$pair" | head -1) rc=$rc errors=$nerr]"
done
[ -z "$guard_bad" ] && ok "LT-49k args other than --strict-trust, --fail-stale, --json and --fail-on-change (every report mode --duplicates, --duplicates-body, --facts, --conserve, --file included, alone or after an allowed flag) , a bad verify value, a repo starting with '-' and an injected newline are refused: exit 64, one ::error:: line" || bad "LT-49k input guards" "$guard_bad"
# args keeps the full gate run: the four options that change a verdict or its form are accepted, and a gate failure stays a failure.
printf -- '---\ntitle: no type\n---\n\nbody\n' > "$ACTWD/bundle/notype.md"
runact2 bundle INPUT_ARGS="--strict-trust --fail-stale --json --fail-on-change"; rc=$?
runact2 bundle INPUT_ARGS="--duplicates"; rcd=$?
{ [ "$rc" -eq 1 ] && [ "$rcd" -eq 64 ] && ! grep -q 'Duplicates' "$TMP_W/act_out.txt"; } && ok "LT-49q a bundle with a note that has no type fails the job (1) with the four allowed args, and args '--duplicates' is refused (64) instead of replacing the gate run with a report that exits 0" || bad "LT-49q args cannot switch the gate off" "allowed=$rc duplicates=$rcd"
# report-args: report modes run AFTER the gate and never change its exit code.
runact2 bundle INPUT_REPORT_ARGS="--duplicates"; rc=$?
grep -q 'Duplicates' "$TMP_W/act_out.txt" && sawd=1 || sawd=0
rm -f "$ACTWD/bundle/notype.md"
runact2 bundle INPUT_REPORT_ARGS="--facts --duplicates"; rcok=$?
grep -q 'Duplicates' "$TMP_W/act_out.txt" && grep -q 'nothing to list' "$TMP_W/act_out.txt" && sawok=1 || sawok=0
{ [ "$rc" -eq 1 ] && [ "$sawd" -eq 1 ] && [ "$rcok" -eq 0 ] && [ "$sawok" -eq 1 ]; } && ok "LT-49r report-args runs each report on its own after the gate (--facts and --duplicates both print) and does not change the exit code: a failing bundle still exits 1 (report printed), a clean one 0 (report printed)" || bad "LT-49r report-args" "failing=$rc saw=$sawd clean=$rcok saw=$sawok"
rg_bad=""
for pair in "INPUT_REPORT_ARGS=--strict-trust|" "INPUT_REPORT_ARGS=--doctor|" "INPUT_REPORT_ARGS=--fail-lost|" "INPUT_REPORT_ARGS=--file n.md|" "INPUT_REPORT_ARGS=HEAD|" $'INPUT_REPORT_ARGS=--duplicates\n::error::injected|'; do
  ga="${pair%%|*}"; runact2 bundle "$ga"; rc=$?
  nerr=$(grep -c '^::error::' "$TMP_W/act_out.txt")
  { [ "$rc" -eq 64 ] && [ "$nerr" -eq 1 ] && ! grep -q 'injected' "$TMP_W/act_out.txt"; } || rg_bad="$rg_bad [$(printf '%s' "$pair" | head -1) rc=$rc errors=$nerr]"
done
[ -z "$rg_bad" ] && ok "LT-49s report-args accepts only --duplicates, --duplicates-body, --facts and --conserve (with their values) and needs one of them: anything else is refused, exit 64, one ::error:: line" || bad "LT-49s report-args guards" "$rg_bad"
# pre-commit: an okf-verify hook next to okf-check.
pyyaml - "$PCH" "$MKT_ROOT" <<'PY' 2>"$TMP_W/pch2_err.txt"
import os, re, sys, yaml
hooks = yaml.safe_load(open(sys.argv[1])); root = sys.argv[2]
h = [x for x in hooks if x["id"] == "okf-verify"][0]
for k in ("id", "name", "description", "entry", "language"):
    assert h.get(k), k
assert h["language"] == "script" and h["pass_filenames"] is False
assert os.access(os.path.join(root, h["entry"]), os.X_OK), h["entry"]
assert h["args"] == [".", "--repo", "."], h["args"]
rx = re.compile(h["files"]); assert rx.search("notes/a.md") and not rx.search("src/app.py")
PY
[ $? -eq 0 ] && ok "LT-49l .pre-commit-hooks.yaml has an okf-verify hook: script entry that exists and is executable, no filenames, default args '. --repo .', selects Markdown" || bad "LT-49l okf-verify hook" "$(tail -1 "$TMP_W/pch2_err.txt" | cut -c1-300)"
PCV="$TMP_W/pcv"; cp -R "$ACTWD" "$PCV"
( cd "$PCV" && "$MKT_ROOT/plugin/scripts/okf-verify" bundle --repo . ) >"$TMP_W/pcv_out.txt" 2>&1; rc=$?
( cd "$PCV" && "$MKT_ROOT/plugin/scripts/okf-verify" bundle --repo . --strict ) >/dev/null 2>&1; rcs=$?
{ [ "$rc" -eq 0 ] && grep -q 'CONFIRMED 1' "$TMP_W/pcv_out.txt"; } && ok "LT-49m (emulated) the hook's command, entry plus its args, confirms a cited commit of the repository (exit 0)" || bad "LT-49m okf-verify hook command" "rc=$rc $(tail -2 "$TMP_W/pcv_out.txt" | tr '\n' ' ')"
{ grep -q 'id: okf-verify' "$README" && grep -qE 'verify: .?.true' "$README" && grep -q 'report-args' "$README" && ! grep -qE "^ +args: '--(duplicates|facts|conserve|file)" "$README"; } && ok "LT-49n the README shows the okf-verify hook, the Action's verify input and report-args, and no report mode as an Action 'args' example" || bad "LT-49n README CI examples" "id: okf-verify, 'verify: true' or report-args missing, or a report mode is shown under args"

echo
if [ "$SKIPPED" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $SKIPPED SKIPPED — coverage did not run in full"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
