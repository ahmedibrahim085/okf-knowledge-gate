#!/bin/bash
# PreToolUse[Write] — mechanical arm of the doc-reuse rule (rules/tool-selection.md):
# creating a NEW .md in a durable-doc location injects a search-first reminder.
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
case "$FP" in
  # OKF reserved files (§8/§9) are structure, not knowledge — they own no failure
  # class, so the lesson-reuse prompt is a false positive on them.
  */.claude/lessons/index.md|*/.claude/lessons/log.md|*/.claude/lessons/README.md) ;;
  */.claude/lessons/*)
    # The lessons store is small and fully readable — a duplicate is always avoidable.
    jq -n --arg fp "$FP" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("Lesson-reuse check (hook-enforced): you are about to CREATE a new lesson at " + $fp + ". FIRST read ~/.claude/lessons/index.md (the full store is ~38 files / 37k tokens — read it, do not guess) and check whether an existing lesson already owns this failure class; several families already exist (verify-the-method-before-the-result, multi-agent-coordination, writing-it-down-is-not-shipping-it). Prefer ADDING an addendum to the owning lesson and linking it from its family parent. Create a new file only when the trap is genuinely distinct, and say in one line which existing lesson it is NOT.")}}'
    ;;
  */docs/*|*/doc/*)
    jq -n --arg fp "$FP" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("Doc-reuse check (hook-enforced): you are about to CREATE a new durable doc at " + $fp + ". FIRST search for an existing home (your knowledge-base search for vault content, or grep existing *.md in the repo) and prefer UPDATING it. Note: search_notes is title-biased with index lag — no hits does not mean absent. Create new only when no suitable home exists, and state why in one line.")}}'
    ;;
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
        jq -n --arg fp "$FP" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("Doc-reuse check (hook-enforced): you are about to CREATE a new durable doc at " + $fp + ". FIRST search for an existing home (your knowledge-base search for vault content, or grep existing *.md in the repo) and prefer UPDATING it. Create new only when no suitable home exists, and say why in one line.")}}' 2>/dev/null
        break ;;
    esac
  done < "$CFG" 2>/dev/null
fi
exit 0
