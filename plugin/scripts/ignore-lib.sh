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

. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/note-guard-lib.sh"   # okf_note_cap, okf_manifest_cap, okf_note_refusal

OKFIGNORE_PATTERNS=()
_OKFIGNORE_FOR=""; _OKFIGNORE_RC=1; _OKFIGNORE_MSG=""; _OKFIGNORE_CACHE=()

# okfignore_present <bundle>: exit 0 when the bundle has a .okfignore of any kind. A folder, FIFO or device counts: it is
# then refused by okfignore_load, never read as "no .okfignore" (round 3).
okfignore_present() { [ -e "$1/.okfignore" ] || [ -L "$1/.okfignore" ]; }

# okfignore_load <bundle>: fill OKFIGNORE_PATTERNS. Return 1 when there is no .okfignore, 2 when it is refused.
# The file is read ONCE per process and bundle, through okf_guard.py read: a non-blocking open, the type judged on the
# opened descriptor, a bounded read. A check of the path followed by `read < path` could meet a FIFO or /dev/zero swapped
# in between, and okf-check waited for ever (container case S17-NR-C13: hung 8 of 12 runs). Later calls, and the subshells
# okf-check starts after the first one, reuse that text, so every layer also applies the same patterns. Its messages are
# printed again on every call, as before.
okfignore_load() {
  if [ "$_OKFIGNORE_FOR" != "$1" ]; then _okfignore_read "$1"; _OKFIGNORE_FOR=$1; fi
  OKFIGNORE_PATTERNS=(${_OKFIGNORE_CACHE[@]+"${_OKFIGNORE_CACHE[@]}"})
  [ -z "$_OKFIGNORE_MSG" ] || printf '%s\n' "$_OKFIGNORE_MSG" >&2
  return "$_OKFIGNORE_RC"
}
_okfignore_read() {
  local f="$1/.okfignore" line text rc
  _OKFIGNORE_CACHE=(); _OKFIGNORE_MSG=""; _OKFIGNORE_RC=1
  okfignore_present "$1" || return 0
  _OKFIGNORE_RC=2
  [ -f "$f" ] && okf_outside "$1" "$f" && { _OKFIGNORE_MSG="okfignore: $f $OKF_OUTSIDE_WHY: not read"; return 0; }   #
  [ -r "$f" ] || { _OKFIGNORE_MSG="okfignore: $f exists but cannot be read"; return 0; }
  # `lines`: each line comes back trimmed of the white space around it, in one linear pass (see okf_guard.read_main).
  text=$(PYTHONDONTWRITEBYTECODE=1 "${PY:-python3}" "$_OKF_GUARD_DIR/okf_guard.py" lines "$f" "$(okf_manifest_cap)"); rc=$?
  case "$rc" in
    0) ;;
    1) _OKFIGNORE_RC=1; return 0 ;;   # gone since the check above: no .okfignore
    3) _OKFIGNORE_MSG="okfignore: $f is $text: not read"; return 0 ;;
    4) _OKFIGNORE_MSG="okfignore: $f $text"; return 0 ;;
    *) _OKFIGNORE_MSG="okfignore: $f could not be read (okf_guard.py exited $rc)"; return 0 ;;
  esac
  _OKFIGNORE_RC=0
  # No parameter-expansion trim here: ${line%$'\r'} and ${line%"${line##*[![:space:]]}"} try every suffix or prefix,
  # so one long line cost time in the square of its length (S30-CF-I1). okf_guard.py trimmed the lines already.
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue;;
      '!'*) _OKFIGNORE_MSG="${_OKFIGNORE_MSG:+$_OKFIGNORE_MSG
}okfignore: negation is not supported in v1, skipped: $line"; continue;;
    esac
    _OKFIGNORE_CACHE+=("$line")
  done <<< "$text"
}

# okfignore_match <relative file path>: exit 0 when a loaded pattern excludes it.
okfignore_match() {   # <rel> [dir]: with "dir", <rel> is itself a folder, so a folder-only pattern (`x/`) can match its last part
  local rel="$1" isdir="${2:-}" pat g dironly anchored anywhere i n prefix
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
        [ "$dironly" -eq 1 ] && [ "$i" -eq $((n-1)) ] && [ -z "$isdir" ] && continue
        case "${comp[$i]}" in $g) return 0;; esac
      done
    else
      prefix=""
      for ((i=0; i<n; i++)); do
        prefix=${prefix:+$prefix/}${comp[$i]}
        [ "$dironly" -eq 1 ] && [ "$i" -eq $((n-1)) ] && [ -z "$isdir" ] && continue
        case "$prefix" in $g) return 0;; esac
        [ "$anywhere" -eq 1 ] && case "$prefix" in */$g) return 0;; esac
      done
    fi
  done
  return 1
}

# okfignore_alias_ignored <bundle> <file>: true when <file> is a symlink whose target is a file inside <bundle> that
# .okfignore excludes. An alias is the same note as its target, so ignoring the target ignores the alias (F-6); an alias
# of a kept note is judged by its own path as before (a link outside the bundle is refused). The link chain is
# walked by okf_real_path (note-guard-lib.sh), at most 40 hops.
okfignore_alias_ignored() {
  [ -L "$2" ] && [ "${#OKFIGNORE_PATTERNS[@]}" -gt 0 ] || return 1
  local t top
  t=$(okf_real_path "$2") || return 1
  [ -f "$t" ] || return 1
  top=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  case "$t" in "$top"/*) ;; *) return 1 ;; esac
  okfignore_match "${t#"$top"/}"
}

# okfignore_list <bundle>: print (NUL-separated) the *.md files that are NOT ignored, as paths
# relative to the bundle. No .okfignore: every *.md.
okfignore_list() {
  local bundle="$1" f rel cap
  bundle=${bundle%/}
  cap=$(okf_note_cap)
  okfignore_load "$bundle"; [ $? -eq 2 ] && return 2
  while IFS= read -r -d '' f; do
    [ -e "$f" ] || continue          # dangling symlink: L1 skips it too
    [ -f "$f" ] || continue          # a device, pipe or folder is not a note: okf_refused_notes names it
    [ -L "$f" ] && [ -n "$(okf_note_refusal "$f" "$bundle")" ] && continue
    rel=${f#"$bundle"/}
    okfignore_match "$rel" && continue
    okfignore_alias_ignored "$bundle" "$f" && continue
    printf '%s\0' "$rel"
  done < <(find -H "$bundle" -name .git -prune -o \( \( -type f ! -size +"${cap}"c \) -o -type l \) -name '*.md' -print0 2>/dev/null)   # -H: okf_md_files' rule (l3-lib.sh)
  okf_reap_procsub
}

# okf_refused_notes <bundle>: print, NUL-separated, one "<reason><TAB><path relative to the bundle>" for every path a layer
# must not open: a *.md that is not a regular file (device, pipe, socket, folder) or is over okf_check.max_note_bytes, a
# config file (*.yaml, *.yml, *.json) that is a device, pipe or socket, and a link of either whose real path is outside the
# bundle. What .okfignore excludes is not listed: no layer
# reads it. Dangling and looping links are not listed (l2_dangling reports them). Nothing is opened (note-guard-lib.sh).
okf_refused_notes() {
  local bundle="${1%/}" f rel why cap
  cap=$(okf_note_cap)
  okfignore_load "$bundle"; [ $? -eq 2 ] && return 2
  while IFS= read -r -d '' f; do
    why=$(okf_note_refusal "$f" "$bundle")
    [ -n "$why" ] || continue
    rel=${f#"$bundle"/}
    okfignore_match "$rel" && continue
    printf '%s\t%s\0' "$why" "$rel"
  done < <(find -H "$bundle" -name .git -prune -o \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) \( \( ! -type f ! -type l \) -o -type l -o \( -type f -size +"${cap}"c \) \) -print0 2>/dev/null)
  okf_reap_procsub
}

# okfignore_mirror <bundle> <dest>: the FROZEN COPY every layer reads. Copy the non-ignored notes and config (*.md,
# *.yaml, *.yml, *.json) into <dest> and link every other non-ignored file to its original (a link to an image,
# SVG or PDF must still resolve inside the mirror). The copy is made by okf_guard.py freeze: a bounded read judged
# on the opened descriptor, so a path that turned into a device after the pre-scan is refused, never read for ever. What it
# refuses is written to <dest>.refused (okf_refused_notes' record format) and is not in <dest>. Prints "<kept> <excluded-notes> <excluded-files>" (the first two count concept notes: *.md other than
# index.md and log.md; the third counts ignored notes and config, not the linked files). Same file set L1 sees without .okfignore: symlinked directories are NOT
# entered (find -H, as okf_md_files and the validator), so a note is neither lost nor listed by one layer only. Exit 1 (naming the file on stderr) when a copy or link fails, so a note is never dropped
# silently. Nothing is deleted outside <dest>. A non-markdown file that .okfignore excludes is not linked, whatever else is
# excluded: it is not part of the bundle, so a link to it is an L002 advisory (one rule; BL-605).
okfignore_mirror() {
  local bundle="${1%/}" dest="$2" f rel kept=0 excl=0 exall=0 isnote iscfg rc abs dir mdir="" ldir="" l kind late
  local -a pend=() src=()
  local lst="${dest}.copy" refused="${dest}.refused"
  okfignore_load "$bundle"; rc=$?; [ "$rc" -eq 2 ] && return 2
  [ -n "$dest" ] && [ "$dest" != / ] || return 2
  abs=$(cd -P "$bundle" && pwd) || return 2
  rm -rf "$dest" "$lst" "$refused"; mkdir -p "$dest"; : > "$lst"; : > "$refused"
  # Links are made one `ln` per run of files in the same folder, not one per file: a bundle with thousands of images
  # would otherwise double its process spawns. A failed batch is retried file by file to name the culprit.
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
    # A refused note or config file (see okf_refused_notes) is neither copied nor linked: cp would read a device for ever,
    # and a layer that finds the link would open it. A folder named like a config file keeps its old path below.
    [ -L "$f" ] && [ -n "$(okf_note_refusal "$f" "$bundle")" ] && continue
    rel=${f#"$bundle"/}
    [ "$rel" = .okfignore ] && continue   # written below from the one read, not linked to the live file
    iscfg=1
    case "${rel##*/}" in *.md|*.yaml|*.yml|*.json) ;; *) iscfg=0; [ -d "$f" ] && continue;; esac   # a link to a folder is not entered
    isnote=0
    case "$rel" in *.md) case "${rel##*/}" in index.md|log.md) ;; *) isnote=1;; esac;; esac
    if [ "${#OKFIGNORE_PATTERNS[@]}" -gt 0 ] && { okfignore_match "$rel" || { [ "$iscfg" -eq 1 ] && okfignore_alias_ignored "$bundle" "$f"; }; }; then   # no pattern: no call (a bash function costs a millisecond per note)
      # The count keeps its meaning (okf-verify prints the same one): notes and config only, not the files linked below.
      if [ "$iscfg" -eq 1 ]; then
        exall=$((exall+1))
        [ "$isnote" -eq 1 ] && excl=$((excl+1))
      fi
      continue
    fi
    dir=""; case "$rel" in */*) dir=${rel%/*};; esac
    case "${rel##*/}" in
      *.md|*.yaml|*.yml|*.json)
        # no mkdir here: the copy helper makes the folder of each file it copies (one process, not one per folder change)
        kind=C; case "${rel##*/}" in *.md) kind=N;; esac   # a note must fit the cap; other config is linked when over it
        [ "$rel" = okf-base.yaml ] && kind=M   # the manifest must fit its own limit (okf_guard.manifest_cap), not the note cap
        printf '%s\t%s\0' "$kind" "$rel" >&7   # fd 7 is $lst, opened once for the whole loop
        [ "$isnote" -eq 1 ] && kept=$((kept+1));;
      *) if [ -n "$dir" ] && [ "$dir" != "$mdir" ]; then mkdir -p "$dest/$dir" || return 1; mdir=$dir; fi
         if [ "$dir" != "$ldir" ] || [ "${#pend[@]}" -ge 200 ]; then _okfignore_flush || return 1; ldir=$dir; fi
         pend+=("$rel");;
    esac
  done 7>"$lst" < <(find -H "$bundle" -name .git -prune -o \( -type f -o -type l \) ! \( -type f -name '*.md' -size +"$(okf_note_cap)"c \) -print0 2>/dev/null)
  okf_reap_procsub
  _okfignore_flush || return 1
  # The layers that load the copy's .okfignore (L2 on a bundle with a dangling link) read these patterns, not the bundle's file.
  [ "$rc" -ne 0 ] || printf '%s\n' ${OKFIGNORE_PATTERNS[@]+"${OKFIGNORE_PATTERNS[@]}"} > "$dest/.okfignore" || return 1
  PYTHONDONTWRITEBYTECODE=1 "${PY:-python3}" "$_OKF_GUARD_DIR/okf_guard.py" freeze "$bundle" "$dest" "$(okf_note_cap)" < "$lst" > "$refused" || return 1
  # a note refused while it was copied (it became a device after the pre-scan) is not a kept note
  while IFS= read -r -d '' late; do
    rel=${late#*$'\t'}
    case "$rel" in *.md) case "${rel##*/}" in index.md|log.md) ;; *) kept=$((kept-1));; esac;; esac
  done < "$refused"
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
  okfignore_list "${2:?usage: ignore-lib.sh --list <bundle>}"; exit $?   # 2: the .okfignore was refused; the caller must not read "no notes kept"
fi
# `bash ignore-lib.sh --match <pattern>...` reads NUL-separated bundle-relative paths on stdin and prints the ones the patterns
# match, NUL-separated: okf-verify's okf_check.verify.generated globs go through this one matcher too (okf-knowledge-gate#14).
if [ "${0##*/}" = "ignore-lib.sh" ] && [ "${1:-}" = "--match" ]; then
  shift; OKFIGNORE_PATTERNS=("$@")
  while IFS= read -r -d '' _rel; do okfignore_match "$_rel" && printf '%s\0' "$_rel"; done
  exit 0
fi
