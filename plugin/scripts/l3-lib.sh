#!/usr/bin/env bash
# (shebang for editors and linters only: this file is sourced, never run.)
# l3-lib.sh — awk helpers shared by okf-check (L3) and lessons-staleness-check.sh.
# SOURCED, never executed. Defines L3_AWK_LIB: awk function text to put in front of a
# program ("$L3_AWK_LIB"'...program...'). One copy, because two hand-written parsers
# drifted apart once already (code-review round 1, 2026-10-14).
# `read -d ''` not `$(cat <<EOF)`: bash 3.2 mis-parses unbalanced quotes inside a heredoc in $(...).
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/note-guard-lib.sh"   # okf_note_cap, okf_note_refusal
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

# okf_md_files <root>: print, NUL-separated, the *.md files a bundle holds, by the one rule every walker shares
# (cases S8-H1, S8-N1, S8-E1). The rule is the vendored validator's, because that file is not ours to edit:
# Python's rglob never enters a symlinked FOLDER (3.9 pathlib: `entry_is_dir and not entry.is_symlink()`) and
# does yield a symlinked FILE. So a folder link below the root is not entered: it is an alias of a folder
# already in the bundle (its notes count once, under their real path) or it points outside (not bundle notes).
# A note-file link counts wherever it points; a dangling link is skipped. `-H`: the root itself may be a
# symlink (E-6a). `find -L` here listed one note twice and counted notes outside the bundle.
# A note that is not a regular file within okf_check.max_note_bytes is not listed (note-guard-lib.sh): a layer that is
# handed the list must be able to open every entry. `-size` keeps an oversize file out without a process per note; only a
# link, whose target find does not measure, is judged by okf_note_refusal. okf_refused_notes (ignore-lib.sh) names them.
okf_md_files() {
  local f cap
  cap=$(okf_note_cap)
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && [ -n "$(okf_note_refusal "$f")" ] && continue
    printf '%s\0' "$f"
  done < <(find -H "$1" -name '*.md' \( \( -type f ! -size +"${cap}"c \) -o -type l \) -print0 2>/dev/null)
}

# okf_folder_links <root>: the symlinked folders below <root> that okf_md_files does not enter, one
# root-relative path per line, sorted, so a run can name what it left out instead of dropping it silently.
okf_folder_links() {
  local f
  find -H "$1" -mindepth 1 -type l -print0 2>/dev/null | while IFS= read -r -d '' f; do
    [ -d "$f" ] && printf '%s\n' "${f#"${1%/}"/}"
  done | sort
}
