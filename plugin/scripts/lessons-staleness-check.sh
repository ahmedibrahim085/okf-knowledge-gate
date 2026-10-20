#!/bin/bash
# SessionStart — the READER for the OKF `stale_after` / `status` fields in ~/.claude/lessons/.
#
# Frontmatter with no consumer is decoration. This is the consumer: it names lessons whose
# stale_after horizon has passed, or whose status is not in the OKF lifecycle (STATUS_VALUES), so the store cannot
# rot silently the way an unread markdown pile does.
#
# CONTEXT COST: zero while everything is current — it prints nothing. A fired report is
# ~20 tokens per named lesson. It never reads lesson BODIES; only frontmatter, in-process.
#
# PERF: one awk pass over every file. The first version spawned awk+sed+sed per file
# (763 ms on 41 files) — measured, not assumed. Keep it a single invocation.
#
# Fail-open by design: any error exits 0 and emits nothing. Never blocks a session.
# macOS-safe: no `declare -A`, no `mapfile`, no GNU-only flags — this box ships bash 3.2
# (see lessons/monitor-zsh-glob-trap.md).

# Overridable: this ships inside a plugin, and another machine may keep its
# bundle somewhere else entirely. The default matches this author's layout; the
# env var is what makes the hook portable rather than personal.
L="${OKF_BUNDLE_DIR:-$HOME/.claude/lessons}"
[ -d "$L" ] || exit 0

TODAY=${OKF_TODAY:-$(date -u +%Y-%m-%d)}   # OKF_TODAY: test seam, pins "now"
unset CDPATH   # an exported CDPATH redirects `cd -P` (ticket 08)
# Resolve a symlink to this file, as okf-check does: the lib lives beside the REAL script.
_self="$0"
while [ -L "$_self" ]; do
  _dir=$(cd -P "$(dirname "$_self")" && pwd)
  _self=$(readlink "$_self")
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_L3LIB="$(cd -P "$(dirname "$_self")" && pwd)/l3-lib.sh"
# Fail loud, not silent: a hook that cannot parse must say so, or expiries stay hidden.
[ -r "$_L3LIB" ] || { echo "lessons staleness check — l3-lib.sh missing next to this hook; expiries NOT checked"; exit 0; }
. "$_L3LIB"
[ -z "$L3_STATUS_ERR" ] || { echo "lessons staleness check — $L3_STATUS_ERR; statuses and expiries NOT checked"; exit 0; }

# `find` not a bare glob: an empty dir must yield an empty loop, not a shell error.
# One awk invocation handles every file; string compare is a correct date compare for ISO-8601.
# okf_md_files: a symlinked concept never matches a bare `-type f`, so it would be skipped silently; a symlinked
# FOLDER is not entered (the validator's rule). Found in okf-check by test E-6b and fixed here in the same
# pass — "my new entry works now" is how 30 other missing entries stay hidden
# (lessons/readdir-symlink-dirent-trap.md).
# -print0, not `| tr '\n' '\0'`: a directory NAME holding a newline split the list and the hook printed nothing at all.
report=$(okf_md_files "$L" | xargs -0 awk -v today="$TODAY" -v statuses="${L3_STATUS//,/, }" "$L3_AWK_LIB"'
  { sub(/\r$/, "") }   # CRLF notes (LT-02b)
  FNR == 1 {
    base = FILENAME
    sub(/^.*\//, "", base)
    # log.md belongs here too: OKF §9 says a reserved file must NOT carry
    # frontmatter, so flagging it as "missing frontmatter" is a false positive.
    # It was absent from this list until log.md was actually created (2026-07-31)
    # — a rule with no instance to fire on cannot be seen to be wrong.
    # README.md stays skipped HERE on purpose (ticket 01, decided 2026-10-14): in the lessons
    # directory README.md is a human index, not a lesson. okf-check L3 counts README.md as a
    # concept (OKF I-4) — the two scripts differ because their inputs differ.
    r = l3_begin($0, base == "README.md" || base == "index.md" || base == "log.md")
    if (r == "nofm") missing = missing " " base
    skip = (r != "open"); next
  }
  skip { next }
  l3_line($0) {
    if (L3_sa != "" && !okfisdate(L3_sa)) malformed = malformed sprintf("\n  - %s (stale_after %s is not a date)", base, L3_sa)
    else if (L3_sa != "" && L3_sa < today) expired = expired sprintf("\n  - %s (stale_after %s)", base, L3_sa)
    if (L3_st != "" && !okfstatusok(L3_st)) nonstd = nonstd sprintf("\n  - %s (status: %s)", base, L3_st)
  }
  END {
    if (expired != "") printf "Lessons past their stale_after horizon — re-verify or extend:%s\n", expired
    if (malformed != "") printf "Lessons with a stale_after that is not a date:%s\n", malformed
    if (nonstd  != "") printf "Lessons with an unknown status (not one of %s):%s\n", statuses, nonstd
    if (missing != "") printf "Lessons missing OKF frontmatter (run the migrate script):%s\n", missing
  }
' 2>/dev/null)

[ -z "$report" ] && exit 0

if command -v jq >/dev/null 2>&1; then
  jq -n --arg m "$report" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("lessons staleness check — " + $m)}}'
else
  printf 'lessons staleness check — %s\n' "$report"
fi
exit 0
