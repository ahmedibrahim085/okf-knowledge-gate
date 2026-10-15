# ignore-lib.sh — .okfignore support, shared by okf-check (sourced) and okf-verify (run as
# `bash ignore-lib.sh --list <bundle>`). One matcher, so the layers cannot disagree about what is
# "in" the bundle (GitHub issue #7).
#
# Syntax (v1): one gitignore-style glob per line. `#` starts a comment. A trailing `/` matches
# directories only. A pattern with no `/` matches a file or directory NAME at any depth. A pattern
# with a `/` is anchored at the bundle root. `*` also crosses `/` (simpler than gitignore).
# Negation (`!pat`) is not supported and is skipped with a notice on stderr.
# The file is only ever READ by the plugin. `okf-check --init-ignore` is the only writer.

OKFIGNORE_PATTERNS=()

# okfignore_load <bundle>: fill OKFIGNORE_PATTERNS. Return 1 when there is no .okfignore.
okfignore_load() {
  local f="$1/.okfignore" line
  OKFIGNORE_PATTERNS=()
  [ -f "$f" ] || [ -L "$f" ] || return 1
  [ -r "$f" ] || { echo "okfignore: $f exists but cannot be read" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line%"${line##*[![:space:]]}"}      # trailing whitespace
    line=${line#"${line%%[![:space:]]*}"}      # leading whitespace
    case "$line" in
      ''|'#'*) continue;;
      '!'*) echo "okfignore: negation is not supported in v1, skipped: $line" >&2; continue;;
    esac
    OKFIGNORE_PATTERNS+=("$line")
  done < "$f"
  return 0
}

# okfignore_match <relative file path>: exit 0 when a loaded pattern excludes it.
okfignore_match() {
  local rel="$1" pat g dironly anchored i n prefix
  local -a comp
  [ "${#OKFIGNORE_PATTERNS[@]}" -gt 0 ] || return 1
  IFS=/ read -r -a comp <<< "$rel"
  n=${#comp[@]}
  for pat in "${OKFIGNORE_PATTERNS[@]}"; do
    g=$pat; dironly=0; anchored=0
    case "$g" in */) dironly=1; g=${g%/};; esac
    case "$g" in /*) anchored=1; g=${g#/};; esac
    case "$g" in */*) anchored=1;; esac
    [ -n "$g" ] || continue
    if [ "$anchored" -eq 0 ]; then
      for ((i=0; i<n; i++)); do
        [ "$dironly" -eq 1 ] && [ "$i" -eq $((n-1)) ] && continue
        case "${comp[$i]}" in $g) return 0;; esac
      done
    else
      prefix=""
      for ((i=0; i<n; i++)); do
        prefix=${prefix:+$prefix/}${comp[$i]}
        [ "$dironly" -eq 1 ] && [ "$i" -eq $((n-1)) ] && continue
        case "$prefix" in $g) return 0;; esac
      done
    fi
  done
  return 1
}

# okfignore_list <bundle>: print (NUL-separated) the *.md files that are NOT ignored, as paths
# relative to the bundle. No .okfignore: every *.md.
okfignore_list() {
  local bundle="$1" f rel
  bundle=${bundle%/}
  okfignore_load "$bundle"; [ $? -eq 2 ] && return 2
  while IFS= read -r -d '' f; do
    [ -e "$f" ] || continue          # dangling symlink: L1 skips it too
    rel=${f#"$bundle"/}
    okfignore_match "$rel" && continue
    printf '%s\0' "$rel"
  done < <(find "$bundle" -name .git -prune -o \( -type f -o -type l \) -name '*.md' -print0 2>/dev/null)
}

# okfignore_mirror <bundle> <dest>: copy the non-ignored notes and config (*.md, *.yaml, *.yml,
# *.json) into <dest>. Prints "<kept> <excluded>" (counts of concept notes: *.md other than
# index.md and log.md). Same file set L1 sees without .okfignore: symlinked directories are not
# followed. Exit 1 (naming the file on stderr) when a copy fails, so a note is never dropped
# silently. Nothing is deleted outside <dest>.
okfignore_mirror() {
  local bundle="${1%/}" dest="$2" f rel kept=0 excl=0 isnote rc
  okfignore_load "$bundle"; rc=$?; [ "$rc" -eq 2 ] && return 2
  [ -n "$dest" ] && [ "$dest" != / ] || return 2
  rm -rf "$dest"; mkdir -p "$dest"
  while IFS= read -r -d '' f; do
    [ -e "$f" ] || continue          # dangling symlink: L1 skips it too
    rel=${f#"$bundle"/}
    isnote=0
    case "$rel" in *.md) case "${rel##*/}" in index.md|log.md) ;; *) isnote=1;; esac;; esac
    if okfignore_match "$rel"; then
      [ "$isnote" -eq 1 ] && excl=$((excl+1))
      continue
    fi
    case "$rel" in */*) mkdir -p "$dest/${rel%/*}" || return 1;; esac
    cp -p "$f" "$dest/$rel" 2>/dev/null || { echo "okfignore: cannot copy $rel" >&2; return 1; }
    [ "$isnote" -eq 1 ] && kept=$((kept+1))
  done < <(find "$bundle" -name .git -prune -o \( -type f -o -type l \) \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print0 2>/dev/null)
  printf '%s %s\n' "$kept" "$excl"
}

# okfignore_starter: the file `--init-ignore` writes.
okfignore_starter() {
  cat <<'STARTER'
# .okfignore — paths okf-check and okf-verify leave out. One glob per line.
# A trailing / matches directories only. A pattern without / matches a name at any depth.
archive/
.trash/
node_modules/
.git/
.obsidian/
STARTER
}

if [ "${0##*/}" = "ignore-lib.sh" ] && [ "${1:-}" = "--list" ]; then
  okfignore_list "${2:?usage: ignore-lib.sh --list <bundle>}"
fi
