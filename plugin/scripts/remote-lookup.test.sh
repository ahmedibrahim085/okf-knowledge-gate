#!/usr/bin/env bash
# Tests for okf-verify --remote: a commit that exists only on the forge (public okf-knowledge-gate #6, first comment; cases
# S24-RL-*; spec row RL-1). A local clone that is behind says UNRESOLVED for a commit a teammate read on
# the forge. With --remote (or okf_check.verify.remote: true) okf-verify asks the forge's API, read-only, for each SHA no
# searched clone holds: found there, it is CONFIRMED (remote) and the detail says the local copy is behind; not found or no
# answer, it stays UNRESOLVED. The clone is never fetched into.
#
# The forge is a local stub (python http.server) reached through OKF_FORGE_API_BASE, a test-only override of the API host.
# bash 3.2 compatible.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
VERIFY="$HERE/okf-verify"
. "$HERE/../tests/okf-test-lib.sh"
export HOME="$TMP/home"; mkdir -p "$HOME"
unset GITHUB_TOKEN GH_TOKEN GITLAB_TOKEN

gitc() { git -C "$1" -c user.name=t -c user.email=t@e -c commit.gpgsign=false "${@:2}"; }
note() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntype: Lesson\ntitle: T\ndescription: D\nstatus: stable\ntags: [t]\ngenerated:\n  by: human:t\n  at: "2026-01-01"\nstale_after: "2099-01-01"\n---\n\n%s\n' "$2" > "$1"
}
# Commit ids made at run time (a literal 40-hex string in a shipped file is refused by the public export's scan).
REMOTE_SHA=$(printf 'on the forge only\n' | git hash-object --stdin)   # on the "forge" only
MISSING_SHA=$(printf 'nowhere\n' | git hash-object --stdin)            # nowhere
OTHER_SHA=$(printf 'nowhere either\n' | git hash-object --stdin)
RS=${REMOTE_SHA:0:7}; MS=${MISSING_SHA:0:7}

# The stub forge: GitHub and GitLab commit endpoints; it logs every request path (and the Authorization header) to a file.
cat > "$TMP/forge.py" <<'PY'
import http.server, json, sys
SHA, LOG = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(LOG, "a").write(self.path + " auth=" + str(self.headers.get("Authorization") or self.headers.get("PRIVATE-TOKEN")) + "\n")
        if self.path.split("?")[0] == f"/repos/acme/svc/commits/{SHA}":
            body = {"sha": SHA, "commit": {"message": "fix: retry the payout job\n\nlong body", "committer": {"date": "2026-05-01T10:00:00Z"}}}
        elif self.path == f"/api/v4/projects/team%2Finfra/repository/commits/{SHA}":
            body = {"id": SHA, "title": "infra: rotate keys", "committed_date": "2026-05-02T10:00:00Z"}
        elif "/boom/" in self.path:
            self.send_response(500); self.end_headers(); return
        elif self.path.startswith("/repos/redir/x/"):
            self.send_response(302); self.send_header("Location", f"/repos/acme/svc/commits/{SHA}"); self.end_headers(); return
        elif self.path.startswith("/repos/list/x/"):
            data = b"[]"; self.send_response(200); self.end_headers(); self.wfile.write(data); return
        elif self.path.startswith("/repos/empty/x/"):
            data = b"{}"; self.send_response(200); self.end_headers(); self.wfile.write(data); return
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"message":"Not Found"}'); return
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
"$REALPY" "$TMP/forge.py" "$REMOTE_SHA" "$TMP/forge.log" > "$TMP/port" 2>/dev/null &
FORGE_PID=$!; trap 'kill $FORGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.3; done
export OKF_FORGE_API_BASE="http://127.0.0.1:$(cat "$TMP/port")"

# clone <dir> <origin url>: a local repository with one commit and that origin.
clone() { mkdir -p "$1"; git init -q "$1"; printf 'x\n' > "$1/f"; gitc "$1" add f; gitc "$1" commit -qm init; git -C "$1" remote add origin "$2"; }
runjson() { local b="$1"; shift; "$VERIFY" "$b" --json "$@" >"$TMP/out.json" 2>/dev/null; printf '%s' "$?"; }
shares() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([[r["claim"][:7], r["verdict"]] for r in d["results"] if r["kind"] == "sha"]))' "$TMP/out.json"; }
detail() { "$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print([r["detail"] for r in d["results"] if r["kind"] == "sha"][0])' "$TMP/out.json"; }

section "happy"
# S24-RL-H1: a GitHub origin. Without --remote the commit is UNRESOLVED and nothing is asked; with --remote it is CONFIRMED
# (remote), the detail names the forge repository, the commit title and date, and says the local clone is behind.
R="$TMP/svc"; clone "$R" "https://github.com/acme/svc.git"; B="$TMP/h1"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $REMOTE_SHA."
: > "$TMP/forge.log"; rc=$(runjson "$B" --repo "$R"); before=$(shares); asked=$(grep -c . "$TMP/forge.log")
rc2=$(runjson "$B" --repo "$R" --remote); got=$(shares); d=$(detail)
src=$("$REALPY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print([r.get("source") for r in d["results"] if r["kind"] == "sha"][0])' "$TMP/out.json")
{ [ "$rc" = 0 ] && [ "$before" = '[["'"$RS"'", "UNRESOLVED"]]' ] && [ "$asked" = 0 ] && [ "$rc2" = 0 ] && [ "$got" = '[["'"$RS"'", "CONFIRMED"]]' ] && [ "$src" = remote ] \
  && grep -q 'on the remote github.com/acme/svc' <<<"$d" && grep -q 'fix: retry the payout job' <<<"$d" \
  && grep -q '2026-05-01' <<<"$d" && grep -q 'local clone .* is behind' <<<"$d"; } \
  && ok "S24-RL-H1 --remote confirms a commit found only on GitHub, naming the repo, title and date; without it nothing is asked" || bad "S24-RL-H1 github" "rc=$rc before=$before asked=$asked rc2=$rc2 got=$got d=$d"

# S24-RL-H2: a self-hosted GitLab origin (scp-like host:path form), named in OKF_GITLAB_HOSTS, and the option declared in okf-base.yaml.
R="$TMP/infra"; clone "$R" "gitlab.example.com:team/infra.git"; B="$TMP/h2"; mkbundle "$B"; note "$B/a.md" "See commit $REMOTE_SHA."
printf 'okf_check:\n  verify:\n    remote: true\n' > "$B/okf-base.yaml"
rc=$(OKF_GITLAB_HOSTS=gitlab.example.com runjson "$B" --repo "$R"); got=$(shares); d=$(detail)
{ [ "$rc" = 0 ] && [ "$got" = '[["'"$RS"'", "CONFIRMED"]]' ] && grep -q 'gitlab.example.com/team/infra' <<<"$d" && grep -q 'infra: rotate keys' <<<"$d"; } \
  && ok "S24-RL-H2 okf_check.verify.remote: true asks a GitLab origin (ssh URL, any host)" || bad "S24-RL-H2 gitlab" "rc=$rc got=$got d=$d"

section "negative"
# S24-RL-N1: not on the forge either: UNRESOLVED, and the detail says the remote was asked; never REFUTED.
R="$TMP/svc"; B="$TMP/n1"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $MISSING_SHA."
rc=$(runjson "$B" --repo "$R" --remote); got=$(shares); d=$(detail)
{ [ "$rc" = 0 ] && [ "$got" = '[["'"$MS"'", "UNRESOLVED"]]' ] && grep -q 'not on the remote github.com/acme/svc either' <<<"$d"; } \
  && ok "S24-RL-N1 a commit the forge does not have stays UNRESOLVED (never REFUTED), saying the remote was asked" || bad "S24-RL-N1 not found" "rc=$rc got=$got d=$d"

# S24-RL-N2: the forge fails (HTTP 500) or the origin is no forge we know: UNRESOLVED, saying the lookup did not run.
R="$TMP/boom"; clone "$R" "https://github.com/boom/x.git"; B="$TMP/n2"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $MISSING_SHA."
rc=$(runjson "$B" --repo "$R" --remote); d=$(detail)
R2="$TMP/other"; clone "$R2" "https://example.org/x/y.git"; rc2=$(runjson "$B" --repo "$R2" --remote); d2=$(detail)
{ [ "$rc" = 0 ] && grep -q 'remote lookup on github.com/boom/x failed' <<<"$d" && [ "$rc2" = 0 ] && grep -q 'no GitHub or GitLab origin' <<<"$d2"; } \
  && ok "S24-RL-N2 a failing forge, or an origin that is no known forge, is UNRESOLVED and says why" || bad "S24-RL-N2 failures" "rc=$rc d=$d rc2=$rc2 d2=$d2"

section "edge"
# S24-RL-E1: a SHA the local clone holds is never sent to the forge; the clone is not fetched into (its refs are unchanged).
R="$TMP/svc"; local_sha=$(git -C "$R" rev-parse HEAD); refs_before=$(git -C "$R" for-each-ref | md5sum)
B="$TMP/e1"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $local_sha."; : > "$TMP/forge.log"
rc=$(runjson "$B" --repo "$R" --remote); asked=$(grep -c "$local_sha" "$TMP/forge.log"); refs_after=$(git -C "$R" for-each-ref | md5sum)
{ [ "$rc" = 0 ] && [ "$asked" = 0 ] && [ "$refs_before" = "$refs_after" ]; } \
  && ok "S24-RL-E1 a commit found locally is not asked for; the clone's refs are unchanged" || bad "S24-RL-E1 local first" "rc=$rc asked=$asked"

# S24-RL-E2: a token goes only to its own forge: GITHUB_TOKEN to the GitHub API, GITLAB_TOKEN to a GitLab API, never across.
: > "$TMP/forge.log"; B="$TMP/e2"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $REMOTE_SHA."
GITHUB_TOKEN=gh-secret GITLAB_TOKEN=gl-secret OKF_GITLAB_HOSTS=gitlab.example.com "$VERIFY" "$B" --repo "$TMP/svc" --repo "$TMP/infra" --remote --json >/dev/null 2>&1
gh_line=$(grep '/repos/acme/svc/' "$TMP/forge.log" | head -1); gl_line=$(grep '/api/v4/' "$TMP/forge.log" | head -1)
{ grep -q 'auth=Bearer gh-secret' <<<"$gh_line" && ! grep -q 'gl-secret' <<< "$gh_line" \
  && { [ -z "$gl_line" ] || { grep -q 'auth=gl-secret' <<<"$gl_line" && ! grep -q 'gh-secret' <<< "$gl_line"; }; }; } \
  && ok "S24-RL-E2 GITHUB_TOKEN goes to GitHub only and GITLAB_TOKEN to GitLab only" || bad "S24-RL-E2 tokens" "gh=$gh_line gl=$gl_line"

# S24-RL-E3: the option is a boolean in the shared schema: a string is refused by both tools.
B="$TMP/e3"; mkbundle "$B"; printf 'okf_check:\n  verify:\n    remote: "yes"\n' > "$B/okf-base.yaml"
"$VERIFY" "$B" --check-config > "$TMP/e3.txt" 2>&1; rc=$?
{ [ "$rc" = 2 ] && grep -q 'okf_check.verify.remote must be true or false' "$TMP/e3.txt"; } && ok "S24-RL-E3 verify.remote must be a boolean (exit 2)" || bad "S24-RL-E3 schema" "rc=$rc $(cat "$TMP/e3.txt")"

# S24-RL-E4 (review blocker): a host is a GitLab only when it is gitlab.com or named in OKF_GITLAB_HOSTS, exactly. An origin on
# gitlab.com.evil.com, or a self-hosted GitLab nobody listed, is not asked and gets no token.
for url in "https://gitlab.com.evil.com/x/y.git" "ssh://notgitlab.attacker.io/x/y.git" "gitlab.example.com:team/infra.git"; do
  R="$TMP/lk"; rm -rf "$R"; clone "$R" "$url"; B="$TMP/e4"; rm -rf "$B"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $REMOTE_SHA."
  : > "$TMP/forge.log"; GITLAB_TOKEN=gl-secret runjson "$B" --repo "$R" --remote >/dev/null; d=$(detail)
  { [ ! -s "$TMP/forge.log" ] && grep -q 'no GitHub or GitLab origin' <<<"$d"; } \
    && ok "S24-RL-E4 $url is not asked and gets no token" || bad "S24-RL-E4 $url" "asked: $(cat "$TMP/forge.log") d=$d"
done

# S24-RL-E5 (review): a redirect is not followed (headers would go with it): the lookup fails, UNRESOLVED.
R="$TMP/rd"; clone "$R" "https://github.com/redir/x.git"; B="$TMP/e5"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $REMOTE_SHA."
: > "$TMP/forge.log"; rc=$(GITHUB_TOKEN=gh-secret runjson "$B" --repo "$R" --remote); got=$(shares); d=$(detail)
{ [ "$rc" = 0 ] && [ "$got" = '[["'"$RS"'", "UNRESOLVED"]]' ] && grep -q 'failed (redirect' <<<"$d" && [ "$(grep -c 'acme/svc' "$TMP/forge.log")" = 0 ]; } \
  && ok "S24-RL-E5 a redirect is refused, not followed" || bad "S24-RL-E5 redirect" "rc=$rc got=$got d=$d log=$(cat "$TMP/forge.log")"

# S24-RL-E6 (review): a 200 whose body is not the commit (a list, an empty object) is a failed lookup, never CONFIRMED, never a crash.
for who in list empty; do
  R="$TMP/m-$who"; clone "$R" "https://github.com/$who/x.git"; B="$TMP/e6"; rm -rf "$B"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $REMOTE_SHA."
  rc=$(runjson "$B" --repo "$R" --remote); got=$(shares); d=$(detail)
  { [ "$rc" = 0 ] && [ "$got" = '[["'"$RS"'", "UNRESOLVED"]]' ] && grep -q 'failed' <<<"$d"; } \
    && ok "S24-RL-E6 a 200 with a $who body is a failed lookup (UNRESOLVED, exit 0)" || bad "S24-RL-E6 $who body" "rc=$rc got=$got d=$d"
done

# S24-RL-E7 (review): a host that failed once is not asked again in the same run (no 10 s wait per SHA on a dead network).
R="$TMP/boom"; B="$TMP/e7"; mkbundle "$B"; note "$B/a.md" "Fixed in commit $MISSING_SHA and in commit $OTHER_SHA."
: > "$TMP/forge.log"; runjson "$B" --repo "$R" --remote >/dev/null
[ "$(grep -c '/boom/' "$TMP/forge.log")" = 1 ] && ok "S24-RL-E7 after one failure a host is not asked again in the run" || bad "S24-RL-E7 host failure" "$(cat "$TMP/forge.log")"

okf_test_summary
[ "$FAIL" -eq 0 ] || exit 1
