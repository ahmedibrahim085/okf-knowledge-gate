#!/usr/bin/env bash
# (shebang for editors and linters only: this file is sourced, never run.)
# l3-lib.sh — awk helpers shared by okf-check (L3) and lessons-staleness-check.sh.
# SOURCED, never executed. Defines L3_AWK_LIB: awk function text to put in front of a
# program ("$L3_AWK_LIB"'...program...'). One copy, because two hand-written parsers
# drifted apart once already (code-review round 1, 2026-10-14).
# `read -d ''` not `$(cat <<EOF)`: bash 3.2 mis-parses unbalanced quotes inside a heredoc in $(...).
IFS= read -r -d '' L3_AWK_LIB <<'AWKEOF' || :
# okfval: YAML scalar value. A quoted value keeps its text (a " #" inside quotes is data,
# not a comment); an unquoted one loses a trailing " # comment".
function okfval(v) {
  if (match(v, /^"[^"]*"/) || match(v, /^'[^']*'/)) return substr(v, 2, RLENGTH-2)
  sub(/[ \t]+#.*$/, "", v); gsub(/[ \t]+$/, "", v); return v
}
# okfisdate: starts with YYYY-MM-DD (RFC 3339 instants qualify).
function okfisdate(d) { return d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ }
# okfdate: zero-pad a non-padded Y-M-D prefix so string compare is a date compare.
function okfdate(d,    head, rest, dp) {
  if (match(d, /^[0-9][0-9][0-9][0-9]-[0-9]+-[0-9]+/)) {
    head = substr(d, 1, RLENGTH); rest = substr(d, RLENGTH + 1)
    split(head, dp, "-")
    return sprintf("%04d-%02d-%02d", dp[1], dp[2], dp[3]) rest
  }
  return d
}
# okfstatusok: the status values L3 accepts (the OKF lifecycle: stable, draft, deprecated).
function okfstatusok(v) { return v == "stable" || v == "draft" || v == "deprecated" }
# The frontmatter state machine, shared so the two scripts cannot drift again.
# State lives in L3_infm / L3_sa / L3_st. The callers keep their own skip rules and reporting.
# l3_begin: call on FNR==1. Returns "reserved", "nofm" (no frontmatter) or "open".
function l3_begin(first, reserved) {
  L3_infm = 0; L3_sa = ""; L3_st = ""; L3_sk = 0
  if (reserved) return "reserved"
  if (first !~ /^---[ \t]*$/) return "nofm"   # same fence rule as L1 (okf_validate.split_frontmatter): trailing blanks allowed
  L3_infm = 1; return "open"
}
# l3_line: feed each later line of an "open" file. Returns 1 on the closing delimiter,
# with L3_sa already date-normalised and L3_st holding the status value.
function l3_line(line) {
  if (!L3_infm) return 0   # past the closing fence the rest is body: a "---" block there is not frontmatter
  if (line ~ /^---[ \t]*$/) { L3_infm = 0; L3_sa = okfdate(L3_sa); if (L3_sk && L3_sa == "") L3_sa = "<empty>"; return 1 }   # a key with no value is reported, not skipped
  if (line ~ /^stale_after:/)  { L3_sk = 1; sub(/^stale_after:[ \t]*/, "", line); L3_sa = okfval(line) }
  else if (line ~ /^status:/)  { sub(/^status:[ \t]*/, "", line);      L3_st = okfval(line) }
  return 0
}
AWKEOF
