# ignore-lib.sh — .okfignore support, shared by okf-check (sourced) and okf-verify (run as
# `bash ignore-lib.sh --list <bundle>`). One matcher, so the layers cannot disagree about what is
# "in" the bundle.
#
# Syntax (v1): one gitignore-style glob per line. `#` starts a comment. A trailing `/` matches
# directories only. A pattern with no `/` matches a file or directory NAME at any depth. A pattern
# with a `/` is anchored at the bundle root. A leading `**/` matches at any depth, the root
# included. `*` also crosses `/` (simpler than gitignore).
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
  local rel="$1" pat g dironly anchored anywhere i n prefix
  local -a comp
  [ "${#OKFIGNORE_PATTERNS[@]}" -gt 0 ] || return 1
  IFS=/ read -r -a comp <<< "$rel"
  n=${#comp[@]}
  for pat in "${OKFIGNORE_PATTERNS[@]}"; do
    g=$pat; dironly=0; anchored=0
    case "$g" in */) dironly=1; g=${g%/};; esac
    anywhere=0
    case "$g" in /*) anchored=1; g=${g#/};; esac
    case "$g" in '**/'*) g=${g#'**/'}; anywhere=1;; esac   # gitignore: any depth, root included
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
        [ "$anywhere" -eq 1 ] && case "$prefix" in */$g) return 0;; esac
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
  done < <(find -H "$bundle" -name .git -prune -o \( -type f -o -type l \) -name '*.md' -print0 2>/dev/null)   # -H: okf_md_files' rule (l3-lib.sh)
}

# okfignore_mirror <bundle> <dest>: copy the non-ignored notes and config (*.md, *.yaml, *.yml,
# *.json) into <dest> and link every other non-ignored file to its original (a link to an image,
# SVG or PDF must still resolve inside the mirror, #93). Prints "<kept> <excluded-notes> <excluded-files>" (the first two count concept notes: *.md other than
# index.md and log.md; the third counts ignored notes and config, not the linked files). Same file set L1 sees without .okfignore: symlinked directories are NOT
# entered (find -H, as okf_md_files and the validator, #62), so a note is neither lost nor listed by one layer only. Exit 1 (naming the file on stderr) when a copy or link fails, so a note is never dropped
# silently. Nothing is deleted outside <dest>.
okfignore_mirror() {
  local bundle="${1%/}" dest="$2" f rel kept=0 excl=0 exall=0 isnote iscfg rc abs dir mdir="" ldir="" l
  local -a pend=() src=()
  okfignore_load "$bundle"; rc=$?; [ "$rc" -eq 2 ] && return 2
  [ -n "$dest" ] && [ "$dest" != / ] || return 2
  abs=$(cd -P "$bundle" && pwd) || return 2
  rm -rf "$dest"; mkdir -p "$dest"
  # Links are made one `ln` per run of files in the same folder, not one per file: a bundle with thousands of images
  # would otherwise double its process spawns (#93). A failed batch is retried file by file to name the culprit.
  _okfignore_flush() {
    [ "${#pend[@]}" -gt 0 ] || return 0
    # A loop, not a prefix substitution: bash 5.2 reads an & in the replacement as the matched text, so a bundle under
    # /x/R&D/kb got links to /x/RD/kb. -f on the retry: a batch that failed half way has already made some links.
    for l in "${pend[@]}"; do src+=("$abs/$l"); done
    if ! ln -s "${src[@]}" "$dest${ldir:+/$ldir}/" 2>/dev/null; then
      for l in "${pend[@]}"; do ln -sf "$abs/$l" "$dest${ldir:+/$ldir}/" 2>/dev/null || { echo "okfignore: cannot link $l" >&2; return 1; }; done
    fi
    pend=(); src=()
  }
  while IFS= read -r -d '' f; do
    [ -e "$f" ] || continue          # dangling symlink: L1 skips it too
    rel=${f#"$bundle"/}
    iscfg=1
    case "${rel##*/}" in *.md|*.yaml|*.yml|*.json) ;; *) iscfg=0; [ -d "$f" ] && continue;; esac   # a link to a folder is not entered (#62)
    isnote=0
    case "$rel" in *.md) case "${rel##*/}" in index.md|log.md) ;; *) isnote=1;; esac;; esac
    if okfignore_match "$rel"; then
      # The count keeps its meaning (okf-verify prints the same one): notes and config only, not the files linked below.
      if [ "$iscfg" -eq 1 ]; then
        exall=$((exall+1))
        [ "$isnote" -eq 1 ] && excl=$((excl+1))
      fi
      continue
    fi
    dir=""; case "$rel" in */*) dir=${rel%/*};; esac
    if [ -n "$dir" ] && [ "$dir" != "$mdir" ]; then mkdir -p "$dest/$dir" || return 1; mdir=$dir; fi
    case "${rel##*/}" in
      *.md|*.yaml|*.yml|*.json)
        cp -p "$f" "$dest/$rel" 2>/dev/null || { echo "okfignore: cannot copy $rel" >&2; return 1; }
        [ "$isnote" -eq 1 ] && kept=$((kept+1));;
      *) if [ "$dir" != "$ldir" ] || [ "${#pend[@]}" -ge 200 ]; then _okfignore_flush || return 1; ldir=$dir; fi
         pend+=("$rel");;
    esac
  done < <(find -H "$bundle" -name .git -prune -o \( -type f -o -type l \) -print0 2>/dev/null)
  _okfignore_flush || return 1
  printf '%s %s %s\n' "$kept" "$excl" "$exall"
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
