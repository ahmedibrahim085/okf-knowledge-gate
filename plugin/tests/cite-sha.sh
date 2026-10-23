# cite-sha.sh — one helper the suites that cite a fixture commit share. Sourced, never run.
#
# cite_sha <repo> [rev] prints the shortest prefix (7 characters or more) of the commit that holds a digit.
# Why not `git rev-parse --short`: okf-verify skips an id with no digit on purpose (D-7, a word like `faecdac` is
# not taken for a commit), and about 1 short SHA in 1000 has none ((6/16)^7). A fixture that cited `--short` lost
# its claim in that run, which was the intermittent okf-verify.test.sh failure (RV-35). bash 3.2 compatible.
cite_sha() {
  local full n=7
  full=$(git -C "$1" rev-parse "${2:-HEAD}") || return 1
  while [ "$n" -lt "${#full}" ]; do
    case ${full:0:$n} in *[0-9]*) break ;; esac
    n=$((n+1))
  done
  printf '%s\n' "${full:0:$n}"
}
