#!/bin/bash
# PreToolUse[Write] — creating a NEW .md in a durable-doc location injects a search-first reminder
# (search for an existing home, update it, create a new document only when none fits).
# Non-blocking, fail-open. Edits to existing files pass silently.
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0
case "$FP" in
  *.md) ;;
  *) exit 0 ;;
esac
[ -e "$FP" ] && exit 0

# closest_notes: " Closest existing notes (okf search): a, b, c." when a search binary exists.
# Binary: OKF_SEARCH_BIN, else `okf` on PATH. Never installed or downloaded by the plugin. Any
# problem (absent, slow, failing, empty) prints nothing: the reminder stays exactly as it was.
# descendants PID: every child, grandchild... of PID (empty when pgrep is absent).
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

closest_notes() {
  local bin="${OKF_SEARCH_BIN:-}" dir q out pid wd rc ids
  [ -n "$bin" ] || bin=$(command -v okf 2>/dev/null)
  [ -n "$bin" ] && [ -x "$bin" ] || return 0
  dir=$(cd -P "$(dirname "$FP")" 2>/dev/null && pwd) || return 0   # the tool refuses a symlinked root
  q=$(basename "$FP" .md | tr '_-' '  ')
  out=$(mktemp 2>/dev/null) || return 0
  "$bin" search "$q" "$dir" >"$out" 2>/dev/null &
  pid=$!
  ( sleep 2; kids=$(descendants "$pid"); kill -KILL "$pid" 2>/dev/null; [ -n "$kids" ] && kill -KILL $kids 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill $(descendants "$wd") "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    ids=$(sed -n 's/^[[:space:]]*[0-9][0-9]*\.[[:space:]]*\[[^]]*\][[:space:]]*\[[ 0-9.]*\][[:space:]]*\([^ ]*\).*/\1/p' "$out" | head -3 | paste -sd, - | sed 's/,/, /g')
    [ -n "$ids" ] && printf ' Closest existing notes (okf search): %s.' "$ids"
  fi
  rm -f "$out"
  return 0
}

case "$FP" in
  # OKF reserved files (§8/§9) are structure, not knowledge — they own no failure
  # class, so the lesson-reuse prompt is a false positive on them.
  */.claude/lessons/index.md|*/.claude/lessons/log.md|*/.claude/lessons/README.md) ;;
  */.claude/lessons/*)
    # The lessons store is small and fully readable — a duplicate is always avoidable.
    jq -n --arg fp "$FP" --arg idx "$(dirname "$FP")/index.md" --arg extra "$(closest_notes)" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("Lesson-reuse check (hook-enforced): you are about to CREATE a new lesson at " + $fp + ". FIRST read " + $idx + " (read it, do not guess) and check whether an existing lesson already owns this failure class. Prefer ADDING an addendum to the owning lesson and linking it from the notes that group it. Create a new file only when the trap is genuinely distinct, and say in one line which existing lesson it is NOT." + $extra)}}'
    exit 0 ;;
  */docs/*|*/doc/*)
    jq -n --arg fp "$FP" --arg extra "$(closest_notes)" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("Doc-reuse check (hook-enforced): you are about to CREATE a new durable doc at " + $fp + ". FIRST search for an existing home (your knowledge-base search for vault content, or grep existing *.md in the repo) and prefer UPDATING it. A search that returns nothing may only mean the index is behind, so check the folder too. Create new only when no suitable home exists, and state why in one line." + $extra)}}'
    exit 0 ;;
esac

# Extra durable-doc locations: one shell glob per line in ~/.config/okf/doc-dirs (OKF_DOC_DIRS_FILE
# overrides the path). Blank lines and `#` comments are skipped. Personal locations belong here,
# not in this script. Any problem reading the file leaves the guard silent: fail-open.
CFG="${OKF_DOC_DIRS_FILE:-$HOME/.config/okf/doc-dirs}"
if [ -r "$CFG" ]; then
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the glob comes from the user's own config on purpose
    case "$FP" in
      $pat)
        jq -n --arg fp "$FP" --arg extra "$(closest_notes)" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("Doc-reuse check (hook-enforced): you are about to CREATE a new durable doc at " + $fp + ". FIRST search for an existing home (your knowledge-base search for vault content, or grep existing *.md in the repo) and prefer UPDATING it. Create new only when no suitable home exists, and say why in one line." + $extra)}}' 2>/dev/null
        break ;;
    esac
  done < "$CFG" 2>/dev/null
fi
exit 0
