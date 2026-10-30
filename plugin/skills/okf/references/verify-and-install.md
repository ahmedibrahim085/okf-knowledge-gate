# okf-verify rules, setup and what the gate never does

Contents: okf-verify (verdicts, paths, SHAs) · what counts as a claim · setting up house rules · what this never does

## okf-verify (L4): is what it SAYS still true?

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" "<bundle>" [--repo DIR]... [--host-paths] [--json] [--strict]
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

`okf-verify` checks four kinds of claim: a cited commit SHA, a code citation pinned to a commit (`path:line @sha`), a line
citation into a living document (`name.md:N`, no commit) and an absolute file path.

**Which repositories are searched.** A cited commit SHA is looked up in each `--repo` folder, and only there. A
repository named twice is searched once.

- Since 0.9.50 a repository named under `okf_check.verify.repos` in `okf-base.yaml` is not searched: that file arrives
  with the bundle, so it is not your choice. Each entry is reported UNRESOLVED with
  `okf_check.verify.repos is not searched since 0.9.50; to search it, pass --repo <path>` (a relative path is shown from the bundle folder); it does not change the exit code unless you pass
  `--strict`. An entry that is also given with `--repo` is searched and not reported.
- An `okf-base.yaml` that cannot be read, is not valid YAML, or whose `okf_check.verify.repos` is not a list of
  `{path: <string>}` stops the run with one error line and exit 2.
- In a shallow clone (the `actions/checkout` default), commits older than the clone are missing: use `fetch-depth: 0`.
- `--remote` (or `okf_check.verify.remote: true`, okf-knowledge-gate#6): a SHA that no searched clone holds is looked up
  on the forge the clone's `origin` names, through its API, read-only; the clone is never fetched into. A forge is
  `github.com`, `gitlab.com`, or a self-hosted GitLab named in `OKF_GITLAB_HOSTS` (comma-separated), matched exactly: an
  origin on `gitlab.com.evil.com` is not asked. Found there, it is CONFIRMED (`--json` `"source": "remote"`) and the detail
  gives the commit's title and date and says the local clone is behind. Not on the forge (or not visible without a token), a
  failed request, a redirect (never followed), an answer that does not name the commit, or an origin that is no known forge:
  it stays UNRESOLVED and the detail says which; a host that failed once is not asked again in the run. A SHA the clone holds
  is never sent. `GITHUB_TOKEN` or `GH_TOKEN` goes to github.com only, `GITLAB_TOKEN` to a GitLab host only. The SHA part of
  a `path:line @sha` citation is not looked up remotely: its lines are read from the local commit.

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

The name is the text as written, from any word of the same paragraph (a blank line or a code block ends it): a double space, a
tab or a no-break space between its words is part of the file name, and a name soft-wrapped over two lines is also tried with
the line break read as a space (only a line break: two spaces are not one). Any number of words may belong to the name. Words of
prose count too: with a file `old notes w.md` beside `w.md`, "I read the old notes w.md:15" is UNRESOLVED (ambiguous), as the
writer may have meant either; quote or rename to settle it.

The file names of a searched repository come from `git ls-files` (tracked and untracked files, not the ignored ones). If git
cannot list the repository, its folder is walked (`.git` skipped) up to 100000 entries (`OKF_VERIFY_WALK_LIMIT`); past that, a
line citation with words before it, which may spell a file there, is UNRESOLVED and the detail names the limit.

Quote the path (`` `my w.py`:3 @sha ``, also `".."` and `'..'`) to make the boundary explicit: it is then never cut,
so with only `w.py` present it is REFUTED. A cut that ends a longer name while the words before it do not spell it
(`a dir/w.py:1` for `my dir/w.py`) is UNRESOLVED, never REFUTED.

**Line citations into living documents** (okf-knowledge-gate#14). `decision-12.md:94`, `spec.md:40-42` and the short form
`decision-12:94` cite a line of a document that keeps changing, with no commit:

- a path is read from the citing note's folder, then from the bundle root, then as the end of one bundle path, then from
  the root of each searched repository (`docs/guide.md:3` in a `--repo` folder's working tree);
- the short form `name:N` is a claim only when a note named `name.md` exists, so prose such as `Step:2` or `localhost:8080`
  is not read as a citation; a time such as `10:30` never is;
- CONFIRMED when the file has that line, REFUTED when the file was found and is shorter (or the line is 0), UNRESOLVED when
  the file is missing, two candidates match (`ambiguous`: two notes share the name, or a bundle note and a repository
  document both end with the path), or the path leaves the bundle and every searched repository, in which case it is not
  looked up at all; a symlink is judged by where it points, so a link inside the bundle to a file outside it is not read;
- a name that holds a space follows the rule of pinned citations: `my w.md:10` names `w.md` unless the words before it spell
  a file that exists. Only `my w.md` exists: that file is checked (the report names it). `my w.md` and `w.md` both exist, or
  two files `my w.md`: UNRESOLVED, naming them; its claim reads `my w.md:10`, so it is told from the claim `w.md:10`. The
  short form works the same way (`Handbook for agents:10`). Quote the name (`` `my w.md`:10 ``, also `".."` and `'..'`) and
  it is never cut. The quotes may hold any letter (`` `café notes.md`:10 ``) and may hold the short form
  (`"Handbook for agents":10`), which is a claim when a note of that name exists, like the unquoted short form;
- a file counts only in the case it is written: `spec.md:10` beside `Spec.md` is UNRESOLVED on every disk, not REFUTED on a
  case-insensitive one;
- inside a code block it is a literal; a citation pinned with `@sha` stays a code citation.

A note with no checkable claim is listed with the number of strings in it that look like citations (`word:12`) but match
no checkable form, with an example (`--json` `unrecognized_citations`), so a writer learns which forms are checked.

**Content anchors and MOVED.** A citation may carry a quoted text, the first words of the cited line:
`decision-12.md:94 "shadow, canary"` (straight or curly quotes). The text is compared with the raw line, whitespace
collapsed and case as written (`**shadow**, canary` does not contain `shadow, canary`); a text that wraps onto the next line
is found too. Two anchors on the same citation are two claims.

| Where the quoted text is | Verdict |
|---|---|
| on the cited line(s) | CONFIRMED |
| on other lines of the same file | MOVED, with the new line in the detail and in `--json` `moved_to` |
| nowhere in the file | REFUTED |

MOVED fails the run (exit 1), like REFUTED: the citation was checked and its line number is wrong, and the right one is
known. A citation pinned to a commit (`path:line @sha "text"`) is history: its anchor is checked at that commit, on the cited
lines only, and it is never MOVED. `okf-verify` never rewrites a note.

**`--since <ref>`.** For a line citation without an anchor into a file that changed since `<ref>` (the bundle must be in a
git repository), the cited lines at `<ref>` are looked for in the file as it is now: found on other lines, the citation is
MOVED with the new line; changed in place, the verdict stays and a warning says the cited line changed. Only a citation the
note already had at `<ref>` is compared, so a branch that moved the text and corrected the citation passes. Use it on a
branch (`--since main`) to see which inbound citations an edit shifted; a renamed file is not followed. An unknown ref, or a
bundle outside a repository, is exit 2.

**Generated notes.** `okf_check.verify.generated` lists, as `.okfignore` globs, the notes a script regenerates (their line
numbers move on every rebuild). A line citation into one without an anchor keeps its verdict and carries a warning to add
an anchor:

```yaml
okf_check:
  verify:
    generated: ["registers/**"]
```

**Absolute file paths.** Paths in backticks or quotes (and paths that start with `~`) are checked on disk, but only
inside the bundle or a `--repo` folder: a path elsewhere on the machine is UNRESOLVED, so a bundle you did not write
cannot use the check to learn which files exist on your machine. Add `--host-paths` to look those up too. Relative
paths are not read.

## Setting up a bundle's house rules

`L2 SKIPPED — no okf-base.yaml` means house rules are not enforced. Run
`okf-check --init-house-rules "<bundle>"` to write a starter `<bundle>/okf-base.yaml`
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
