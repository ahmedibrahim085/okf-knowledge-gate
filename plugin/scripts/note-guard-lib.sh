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

# The one reason text for a path whose real path is outside the bundle; the python twin is okf_guard.OUTSIDE_WHY.
OKF_OUTSIDE_WHY='points outside the bundle'

# okf_real_path <path>: the real path of <path>, its link chain walked with readlink (no readlink -f on macOS), at most
# 40 hops; the folder is resolved with cd -P. Prints nothing, and fails, when the chain is longer or a folder is gone.
okf_real_path() {
  local p="$1" t n=0 d
  while [ -L "$p" ]; do
    [ "$n" -lt 40 ] || return 1
    t=$(readlink "$p") || return 1
    case "$t" in /*) p=$t ;; *) case "$p" in */*) p=${p%/*}/$t ;; *) p=$t ;; esac ;; esac
    n=$((n+1))
  done
  case "$p" in */*) d=${p%/*} ;; *) d=. ;; esac
  d=$(cd -P "${d:-/}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "${d%/}" "${p##*/}"
}

# okf_outside <root> <path>: true when <path> is a symlink whose real path is not <root> or below it. Only a link is
# judged: every walker lists paths with find -H, which enters no symlinked folder, so a path that is not a link lies
# in a real folder of the bundle. Each folder of the real path, from the file up, is compared with <root> by `-ef`
# (same device and inode), not by spelling: on a case-insensitive disk /x/Kb and /x/kb are one folder. A chain that
# cannot be resolved counts as outside (fail closed).
okf_outside() {
  local d
  [ -L "$2" ] || return 1
  d=$(okf_real_path "$2") || return 0
  while [ -n "$d" ]; do
    [ "$d" -ef "$1" ] && return 1
    d=${d%/*}
  done
  [ / -ef "$1" ] && return 1
  return 0
}

# okf_note_refusal <path> [<root>]: print why <path> must not be opened, nothing when it may be. A missing path or a dangling
# or looping link prints nothing: those keep their own rules. Notes (*.md) must be regular and within the cap; a folder
# named like a note cannot hang a reader, so it is named as "a folder, not a note" (okf-check warns and keeps its exit
# code). The config files okf-check copies (*.yaml, *.yml, *.json) must not be a device, pipe or socket (a folder named
# like one is a folder, not a file, and is left alone). Any other name is never opened by a layer, so it is not judged.
# With <root>, a note or config link that passes those tests but whose real path is outside <root> is refused;
# the type and size reasons come first, so a link to a device keeps its own reason.
okf_note_refusal() {
  local f="$1" sz cap
  [ -e "$f" ] || return 0
  case "$f" in
    *.md)
      [ -d "$f" ] && { printf '%s' "$OKF_FOLDER_WHY"; return 0; }
      [ -f "$f" ] || { printf 'not a regular file (device/pipe/...)'; return 0; }
      cap=$(okf_note_cap); sz=$(okf_file_size "$f")
      case "$sz" in ''|*[!0-9]*) ;; *) [ "$sz" -le "$cap" ] || { printf 'larger than %s bytes (okf_check.max_note_bytes)' "$cap"; return 0; } ;; esac ;;
    *.yaml|*.yml|*.json)
      [ -f "$f" ] || [ -d "$f" ] || { printf 'not a regular file (device/pipe/...)'; return 0; } ;;
    *) return 0 ;;
  esac
  [ -n "${2:-}" ] && okf_outside "$2" "$f" && printf '%s' "$OKF_OUTSIDE_WHY"
  return 0
}
