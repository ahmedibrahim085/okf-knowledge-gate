#!/usr/bin/env bash
# (shebang for editors and linters only: this file is sourced, never run.)
# note-guard-lib.sh — the one rule for which note files a layer may OPEN.
# A symlink named x.md that points at /dev/zero is a "note" to find, to the shell's -e and to a directory walk,
# and every reader that opened it read for ever: okflint grew to 112 GB and crashed the host (2026-10-18). So a
# note is opened only when, after symlinks are resolved, it is a regular file of at most okf_check.max_note_bytes.
# SOURCED by l3-lib.sh and ignore-lib.sh (the walkers); the python twin is okf_guard.py (refusal, read_note).
# Every test here is a stat: nothing in this file opens the path it judges.
# bash 3.2 compatible.

[ -n "${_OKF_NOTE_GUARD_LOADED:-}" ] && return 0
_OKF_NOTE_GUARD_LOADED=1
_OKF_GUARD_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# okf_note_cap: the byte cap. okf-check puts the effective value (the bundle's setting or the default) in
# OKF_MAX_NOTE_BYTES; a standalone caller gets the default, which lives in config/okf-check-block.json only.
okf_note_cap() {
  local c="${OKF_MAX_NOTE_BYTES:-}"
  # pipefail-safe: only the value is used (callers test it); the status of this assignment is never tested.
  case "$c" in ''|*[!0-9]*|0) c=$(sed -n 's/.*"max_note_bytes"[^}]*"default": *\([0-9][0-9]*\).*/\1/p' "$_OKF_GUARD_DIR/../config/okf-check-block.json" 2>/dev/null | head -1) ;; esac
  printf '%s' "$c"
}

# The one reason text for a folder named like a note; okf-check tells it from a refusal by this exact string.
OKF_FOLDER_WHY='a folder, not a note'

_okf_size_flavor=""
# okf_file_size <path>: the size in bytes of what the path resolves to. stat, never wc: wc reads.
okf_file_size() {
  if [ -z "$_okf_size_flavor" ]; then
    if stat -f '%z' /dev/null >/dev/null 2>&1; then _okf_size_flavor=bsd; else _okf_size_flavor=gnu; fi
  fi
  if [ "$_okf_size_flavor" = bsd ]; then stat -L -f '%z' "$1" 2>/dev/null; else stat -L -c '%s' "$1" 2>/dev/null; fi
}

# okf_note_refusal <path>: print why <path> must not be opened, nothing when it may be. A missing path or a dangling
# or looping link prints nothing: those keep their own rules. Notes (*.md) must be regular and within the cap; a folder
# named like a note cannot hang a reader, so it is named as "a folder, not a note" (okf-check warns and keeps its exit
# code). The config files okf-check copies (*.yaml, *.yml, *.json) must not be a device, pipe or socket (a folder named
# like one is a folder, not a file, and is left alone). Any other name is never opened by a layer, so it is not judged.
okf_note_refusal() {
  local f="$1" sz cap
  [ -e "$f" ] || return 0
  case "$f" in
    *.md)
      [ -d "$f" ] && { printf '%s' "$OKF_FOLDER_WHY"; return 0; }
      [ -f "$f" ] || { printf 'not a regular file (device/pipe/...)'; return 0; }
      cap=$(okf_note_cap); sz=$(okf_file_size "$f")
      case "$sz" in ''|*[!0-9]*) return 0 ;; esac
      [ "$sz" -le "$cap" ] || printf 'larger than %s bytes (okf_check.max_note_bytes)' "$cap" ;;
    *.yaml|*.yml|*.json)
      [ -f "$f" ] || [ -d "$f" ] || printf 'not a regular file (device/pipe/...)' ;;
  esac
  return 0
}
