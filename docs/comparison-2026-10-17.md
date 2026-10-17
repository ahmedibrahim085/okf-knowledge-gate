# How we checked one comparison claim (2026-10-17)

The README says, under "Why use it": of the 15 OKF tools whose source we read, none checks that the commits a note cites
still exist. This page is the evidence for that sentence, and its limits.

## The claim, exactly

> Of the 15 OKF tools whose source we read on 2026-10-16 and 2026-10-17, none contains code that checks whether a commit
> **cited in a note** still exists. `okf-verify` in this project does (CONFIRMED, REFUTED or UNRESOLVED per commit).

It is a statement about what we read, on those dates. It is not a statement about every OKF tool, and it does not say
the other tools are worse: they do other jobs well (see "What the others do").

## Method

1. Each repository was cloned read-only at the commit listed below.
2. Every source file (`.py .rb .go .rs .ts .js .sh .java`, plus `Rakefile`/`.rake` for Ruby), excluding tests, specs,
   fixtures and vendored code, was searched for code that asks git about commits: `cat-file`, `rev-parse`, `merge-base`,
   `rev-list`, `git -C`, a git library (`libgit2`, `go-git`, `pygit2`, `gitpython`, `Rugged`, `git2::`) or a `git`
   subprocess.
3. Every hit was read in context to see what is asked and why.
4. **Positive control:** the same patterns find our own `plugin/scripts/okf-verify`, which calls
   `git cat-file -e <sha>^{commit}` for each cited commit. A search that cannot find that would prove nothing.

## Repositories read

| Repository | Commit | Commit date (UTC) |
|---|---|---|
| GoogleCloudPlatform/open-knowledge-format | ad30107c31 | 2026-08-21 |
| mattdav/okflint | e865826a54 | 2026-10-15 |
| oak-invest/kiso | fe77c8dafd | 2026-10-15 |
| Sudhakaran88/okf-conformance | 3e958ae965 | 2026-08-12 |
| longsizhuo/okf-frontmatter | 382ace5c56 | 2026-06-30 |
| okfcli/okf | 9985a55e98 | 2026-09-03 |
| jyjeanne/okf-rs | 6d52cc7ad0 | 2026-08-21 |
| superops-team/okf | 88a751032e | 2026-09-17 |
| W4G1/okf | 085e6bbf64 | 2026-09-04 |
| PoorvaJ-WW/okft | 3e62c403a5 | 2026-07-14 |
| joshuaswarren/remnic | 1f66cf2570 | 2026-10-15 |
| scaccogatto/okf-skills | a8b96420de | 2026-10-13 |
| Connorrmcd6/surface | 12859c21d0 | 2026-09-27 |
| xSAVIKx/okf-skills | 129f35ad0b | 2026-10-03 |
| serradura/okf (with `okf-pro`) | cfb7ffa | 2026-09-06 |

## What the git calls in the others do

None of these checks a commit that a note cites.

| Repository | What it asks git |
|---|---|
| mattdav/okflint | the current branch name, in a developer task script |
| jyjeanne/okf-rs | the repository's `HEAD`, for provenance |
| superops-team/okf | the repository root and `HEAD`, in its git hooks and a discovery script |
| scaccogatto/okf-skills | the closest case: `skills/backfill` runs `git rev-parse --verify <sha>^{commit}` on a SHA the user types on the command line (`--show <sha>`), to print that commit's diff. It checks the user's input, not the commits notes cite |
| Connorrmcd6/surface | `merge-base` and diffs, to tell which code a note's anchor points at has changed |
| xSAVIKx/okf-skills | which files change together (go-git history walk), and whether a release tag exists |
| joshuaswarren/remnic | `merge-base` and diffs in a pull-request preflight script |
| serradura/okf | one `git status --porcelain` call in its Rakefile; nothing resolves a commit |
| the other seven | no git call that touches commits |

## What the others do that we do not

This project does not replace them. Several do jobs `okf-check` does not: `surface` hashes the code a note anchors to,
`serradura/okf` has a much larger test suite and its own Claude Code hooks, and `okf-pro` reports duplicate notes.
The README names only what this project does and does not claim to be better at anything else.

## Limits

- We read source. We did not run the other tools, so a behaviour that only shows at run time is not covered.
- The search is by pattern and by file extension. A tool could check commits through a library we did not list, in a
  language we did not scan, or in a dependency.
- CI workflow files (`.yml`) were not searched. okflint's CI runs `git cat-file -e` on a push's before-SHA; that is not a commit cited in a note.
- The repositories change. The commits above are what we read.
- A negative result from a search is only as good as the search. Reproduce it with the patterns in "Method".

## Reproduce

```bash
git clone --depth 1 <repository> && cd <repository>
git ls-files | grep -E '\.(py|rb|go|rs|ts|js|sh|java)$' | grep -viE 'test|spec|fixture|vendor' \
  | xargs grep -nE 'cat-file|rev-parse|merge-base|rev-list|git -C|libgit2|pygit2|go-git|gitpython|Rugged|git2::'
```

Then read each hit. Report a mistake by opening an issue; we will correct this page and the README.
