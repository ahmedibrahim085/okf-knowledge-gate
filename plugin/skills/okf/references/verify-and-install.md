# okf-verify rules, setup and what the gate never does

Contents: okf-verify (verdicts, paths, SHAs) · what counts as a claim · setting up house rules · what this never does

## okf-verify (L4): is what it SAYS still true?

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" <bundle> [--repo DIR]... [--host-paths] [--json] [--strict]
```

Resolves the checkable claims in each concept — cited commit SHAs and file paths —
against reality. Separate from `okf-check` because it needs to be told which
repositories to search; `okf-check` stays zero-config.

**Three verdicts, and the distinction is the whole point:**

```
CONFIRMED   checked, and it holds
REFUTED     checked, and it does NOT hold
UNRESOLVED  could NOT be checked
```

`UNRESOLVED` is **not** a soft `REFUTED`. Collapsing them would report a corpus as
false when the truth is that nobody looked. So SHAs and paths are treated
asymmetrically on purpose:

- A missing **file path** can be REFUTED — but only when its parent directory
  exists, so we know we searched the right place. Missing parent ⇒ different
  machine ⇒ UNRESOLVED. Paths under `/tmp`, `/var/folders` are ephemeral by
  definition and are never refuted.
- A missing **SHA** is *never* REFUTED. It depends on which repos were searched
  and does not survive a history rewrite. When a commit whose message contains
  a subject quoted in the note is found, the detail names three explanations: the
  history was rewritten, or the commit lives in a repository that was not searched,
  or the match is unrelated (it lists what was searched and what could not be).
- Paths inside **fenced code blocks are ignored** — `const LOG = '/tmp/x.log'`
  tells you where to write output; it does not assert the file exists.

Concepts carrying no checkable claim are listed as **unverifiable, not verified**.

## What counts as a claim, and how each is judged

`okf-verify` checks three kinds of claim: a cited commit SHA, a code citation (`path:line @sha`) and an absolute file path.

**Which repositories are searched.** A cited commit SHA is looked up in each `--repo` folder and in each repository the
bundle declares once in its `okf-base.yaml`:

```yaml
okf_check:
  verify:
    repos:
      - path: .          # relative to the bundle, absolute, or starting with ~
```

- `--repo` adds to the declared repositories, and a repository named twice is searched once.
- A declared path that is missing or is not a git repository is reported as UNRESOLVED with that reason; it does not
  change the exit code unless you pass `--strict`.
- An `okf-base.yaml` that cannot be read, is not valid YAML, or whose `okf_check.verify.repos` is not a list of
  `{path: <string>}` stops the run with one error line and exit 2.
- In a shallow clone (the `actions/checkout` default), commits older than the clone are missing: use `fetch-depth: 0`.

**Code citations.** `path:line @sha`, `path:first-last @sha` or `path:line at sha` (for example
`` `src/a.py:10 @d084956` ``) is ONE claim: the commit is looked up as above, then the path in that commit's files.
The path is repo-relative and may be only its end (`a.py` for `src/a.py`).

| Situation | Verdict |
|---|---|
| The file exists at that commit, and the line (or the end of the range) is in it | CONFIRMED |
| The commit is found and the file is not in it | REFUTED (the detail says the path part failed) |
| The line, or the end of the range, is past the end of the file | REFUTED (the detail gives the file's line count) |
| Line 0 (lines start at 1); any line of an empty file (0 lines) | REFUTED |
| A line number of more than 9 digits | REFUTED, as out of range |
| The commit is in no searched repository | UNRESOLVED |
| The end of the path matches more than one file | UNRESOLVED |
| The file is binary or a symlink (its lines cannot be checked) | UNRESOLVED |

A reversed range such as `20-10` is read as the lines up to the larger number. A drive-letter path with backslashes
(`C:\x\y.py:3`), a URL or a version number is not a citation. `path:line` and `@sha` may be split by one line break
but not by a blank line: across a paragraph break they are not one citation.

**Paths with spaces.** A citation is cut at the first space before the path, so `my w.py:3 @sha` names `w.py` unless
the words before it spell a file that exists at that commit:

- only `my w.py` exists: the line is checked in `my w.py` (CONFIRMED, or REFUTED when past the end);
- both exist, or two such names do: UNRESOLVED, naming them, because the writer's intent cannot be told;
- only `w.py` exists: `my` is read as prose and the claim is CONFIRMED against `w.py`.

Quote the path (`` `my w.py`:3 @sha ``, also `".."` and `'..'`) to make the boundary explicit: it is then never cut,
so with only `w.py` present it is REFUTED. A cut that ends a longer name while the words before it do not spell it
(`a dir/w.py:1` for `my dir/w.py`) is UNRESOLVED, never REFUTED.

**Absolute file paths.** Paths in backticks or quotes (and paths that start with `~`) are checked on disk, but only
inside the bundle or a `--repo` folder: a path elsewhere on the machine is UNRESOLVED, so a bundle you did not write
cannot use the check to learn which files exist on your machine. Add `--host-paths` to look those up too. Relative
paths are not read.

## Setting up a bundle's house rules

`L2 SKIPPED — no okf-base.yaml` means house rules are not enforced. Run
`okf-check --init-house-rules <bundle>` to write a starter `<bundle>/okf-base.yaml`
(it never overwrites an existing file; nothing else ever writes it). The starter comes from
`${CLAUDE_PLUGIN_ROOT}/config/okf-base.yaml.template`, which encodes one rule
worth keeping: **`stale_after` is required, not optional.** An undated concept
cannot rot visibly, and invisible rot is what this gate exists to prevent.

Set requirements the bundle *already meets* before adding new ones. A rule that
fails on day one gets disabled on day two.

## What this does NOT do

- **Never installs silently.** A SessionStart preflight only REPORTS a missing or unsupported
  prerequisite. `okf-check --install-deps` prints the plan; `--yes` runs it (the supported okflint
  from `plugin/config/pinned-versions.txt`; `--latest` takes the newest release). Setting
  `OKF_AUTO_INSTALL=1` is your opt-in to let the preflight run the plan itself. A failed install
  puts the exact previous okflint back (a fork build comes back as a fork build). The preflight
  compares version numbers only; `--doctor` checks behaviour.
- **Never runs `okflint index --apply`.** That regenerates `index.md` as a flat
  list and would destroy a curated one.
- **Never rewrites bundle content.** It is a read-only gate; `--migrate` belongs
  to the upstream validator and is the user's call.
- **`okf-check` does not verify that claims are TRUE** — only that the bundle is
  well-formed, house-conformant and unexpired. Conformance is not correctness.
  That question has its own tool, below.
