# Changelog

All notable changes to the OKF Knowledge Gate plugin are documented in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/): the plugin is `0.x`, so the
minor number moves for new capability and the patch number for fixes and documentation.
Dates are ISO 8601. The entry for a version is also the body of its GitHub release.

## [Unreleased]

## [0.9.26] - 2026-10-18

OKF Knowledge Gate 0.9.26 adds a size budget for notes, so a note that grows past what an agent can read in one pass is caught before it is compressed in a hurry.

### Added
- **`okf_check.size`** (public issue 17). `max_body_chars` and `warn_body_chars` set an error limit and a warning limit for the body of each note: the text after the frontmatter, in characters, not bytes or tokens (a long `verified:` block does not count; a CRLF line break counts one, a BOM none). A body above the maximum is a house-rule error (exit 1, like `require_owner`); above the warning limit it is a warning. Each finding names the note, its size and the limit, and says to split the note or move a section to a companion note, not to compress it. `index.md` and `log.md` are measured; `.okfignore` leaves a note out. The values must be whole numbers from 1 and the warning limit must be below the maximum, else `okf-check` and `okf-verify --check-config` refuse them with exit 2. Without the setting nothing changes. `--selftest` has a new probe: a note over the limit must be listed and a note under it must not.
- The schema that `okf-verify --check-config` reads has a whole-number type with bounds and a "below its sibling" rule for such pairs.

## [0.9.25] - 2026-10-18

OKF Knowledge Gate 0.9.25 lets a bundle that sits inside a larger note vault resolve root-style wikilinks.

### Added
- **`okf_check.wikilink_root`** (public issue 13). Obsidian-style tools resolve a wikilink such as `[[projects/p/README]]` from the vault root; L2 resolved it from the bundle and reported a false `L001`. The new setting names the vault root, as a folder relative to the bundle: for a bundle at `vault/projects/p/bundle` the root is `../../..`. With it set, an `L001` for a path wikilink is dropped, and counted in the report, when the target exists under that root; a target that is missing there still gives `L001`. Without the setting nothing changes. The root must be the bundle or one of its parent folders; a value that is not a string, is absolute, is missing, is a file, is a sibling folder, is `/` or the home folder, or carries leading or trailing spaces is refused with exit 2 by `okf-check` and `okf-verify --check-config` with the same message. A symlinked folder below the root is not entered, and a symlinked note must stay inside the root. `--selftest` has a new probe: an existing target resolves, a missing one still gives `L001`.

## [0.9.24] - 2026-10-18

OKF Knowledge Gate 0.9.24 stops `okf-export` from overwriting a note silently when two vault notes would get the same output name.

### Fixed
- **`okf-export` refuses two inputs that would be written to one output file.** On a case-sensitive disk a vault folder can hold both `Index.md` and `index.md`; both become the folder note `foo.md`, and the second write replaced the first with exit 0 and no message, so one note's content was lost. The export now stops before writing anything, with exit 2 and a message that names both files (`A and B would both be written to C; rename one of them in the vault`). The existing messages for an `index` or `log` that would be renamed onto an existing note are unchanged, and notes in different folders do not clash.

## [0.9.23] - 2026-10-18

OKF Knowledge Gate 0.9.23 gives the L2 profile a verdict for a bundle that holds a dangling Markdown link.

### Fixed
- **A dangling `*.md` symbolic link no longer stops L2 with `COULD NOT RUN`.** The third-party `okflint` raised `FileNotFoundError` on such a link, so the whole L2 verdict was lost with exit 2, while L1 and L3 simply skip a dangling link. When the tree holds one, L2 now runs on the same copy that `.okfignore` uses, which leaves dangling links out, and each link is reported as an advisory (`dangling symlink: the link target does not exist`, rule `DANGLING_MD`) that counts in `l2_warnings`. A bundle without a dangling `*.md` link takes the old path unchanged, and a link inside an ignored folder is not reported.

## [0.9.22] - 2026-10-18

OKF Knowledge Gate 0.9.22 lets a CI job or an agent see which notes the L2 advisory findings point at.

### Added
- **`okf-check --json` lists the L2 advisories in a new `l2_advisories` key** (public issue 2, second half). Each entry reads `RULE file - message`, the same shape as `l2_findings`, and the list is as long as `l2_warnings`. Past 200 entries the list stops with one line that says how many more there are; `l2_warnings` stays the true total. `l2_findings` keeps meaning house-rule errors only.

### Fixed
- **Messages no longer name the temporary copy.** A finding such as a missing `log.md` used to say `reserved file missing in <temporary folder>/okfmirror`; it now names the bundle.

## [0.9.21] - 2026-10-18

OKF Knowledge Gate 0.9.21 stops the L2 profile from reporting broken links to files that exist when an `.okfignore` is present.

### Fixed
- **A link to an existing image, SVG or PDF no longer gives a false `L002` under `.okfignore`** (public issue 12). With an `.okfignore` that excluded something, the copy that L2 reads carried only notes and config files, so every link to another existing file looked broken: one bundle showed 916 false `L002` findings against none from plain `okflint`. The copy now also links the existing, non-ignored files of the bundle. A link into an ignored folder, and a link to a file that does not exist, still give `L002`. A bundle path that contains `&` works on bash 5 as well as bash 3.2. `--selftest` has a new probe for this case: an ignored folder plus an image link must give no `L002`.

## [0.9.20] - 2026-10-18

OKF Knowledge Gate 0.9.20 starts to cut the time a release spends in the slowest test suite.

### Added
- **`OKF_TEST_TIMING=1` prints the seconds each section of `okf-check.test.sh` takes.** One line per section, with its share of the run; a plain run prints nothing extra.
- **The shared test helpers live in one sourced file** (`plugin/tests/okf-test-lib.sh`), so a suite can be split without copying them.

### Changed
- **The staleness (L3) section, the slowest by measure, moved to its own suite** (`okf-check-l3.test.sh`). No test changed: the two files together run the same 513 tests, and they can run side by side.

## [0.9.19] - 2026-10-18

OKF Knowledge Gate 0.9.19 moves the public publish step into the repository and makes its order impossible to get wrong.

### Added
- **`tools/publish-public.sh <exported-tree> <vX.Y.Z> [--dry-run]`.** It clones the public repository, replaces the tree, commits under the public identity (no session trailer), pushes main and the tag in one atomic push, checks on the remote that the tag points at the pushed commit, and only then creates the release. A failed clone, copy, commit, tag or push stops it before the release; a tag that already sits on another commit is refused; a re-run after a failed release continues only when the tree is unchanged. It refuses a tree that holds a `.git` entry in any letter case, a symlink, or no export marker, never passes a credential-helper override, ignores `GIT_*` settings from the environment, and takes a different remote only in an explicit test mode that cannot reach the real repository. `--dry-run` prints the steps and writes nothing.

### Changed
- **`tools/export-public.sh` writes an `.export-ok` marker after its scan.** The marker never ships. It shows that a tree was once exported, not that its content was scanned.

## [0.9.18] - 2026-10-18

OKF Knowledge Gate 0.9.18 moves the version bump of a release out of a session helper and into the repository.

### Added
- **`tools/bump-version.sh OLD NEW [--dry-run]`.** It changes the seven version sites of a release (the plugin manifest, the marketplace entry, the `VERSION` line of `okf-check`, and the pins in the README, the pre-commit hook file and the skill) in one step. It checks that every site reads OLD before it writes anything, refuses an unwritable site, a bad version, and a pin that only starts with OLD, and keeps file modes, CRLF, BOM and a missing final newline. It uses no `sed -i`, so it runs the same on macOS and Linux. `--dry-run` lists the sites and writes nothing.

## [0.9.17] - 2026-10-18

OKF Knowledge Gate 0.9.17 closes a hole in the repository's own test gate: a test suite that exits early no longer passes.

### Fixed
- **`tools/check-tests.sh` rejects a suite with an unindented `exit` or `return` before its final-status line.** Such a suite ran nothing and still exited 0, so the pre-push gate counted it as a pass. The check skips heredoc bodies (quoted, unquoted, `<<-`, spaced), comments and quoted strings, and ignores here-strings and arithmetic shifts. A heredoc that never closes is now a loud `BROKEN` line instead of a silent skip. Known limits are listed in the script header: a multi-line quoted string holding an unindented `exit`, and a second heredoc on one line.

## [0.9.16] - 2026-10-18

OKF Knowledge Gate 0.9.16 makes `okf-export` write the bundle's `log.md` from the vault's own history note.

### Added
- **`okf-export` writes a spec `log.md`.** A vault `log.md` note (spec section 3.1 reserves that name) is read as the history: dated lines, either a date heading (`## 2026-05-22`) whose lines are that day's entries or a list item that starts with a date (`- 2026-05-22: text`), in any order. The export groups them by date, newest first, in a `log.md` in the same folder, with no frontmatter. A vault without a `log.md` note gets no log. Everything that cannot be filed is listed as `file:line` with exit 1 and nothing is dropped silently: a date that is not an ISO `YYYY-MM-DD` day (`2026-02-30`, `2026/05/22`, `2026-05-22T10:00`), a `##` heading that is not a date, a line that belongs to no date, the log's own frontmatter (a spec log has none), and a log with no dated entry (no log is written). The vault's own `# Title` is kept as the log's title, an indented continuation line stays with its dated item, and blank lines between the lines of a day are kept. The name is matched case-folded (`Log.md` on a case-insensitive disk), two logs in one folder stop the export with exit 2, the generated indexes leave the log out, and control characters in log entries become `?`.

## [0.9.15] - 2026-10-18

OKF Knowledge Gate 0.9.15 makes `okf-export` write the index files a bundle needs.

### Added
- **`okf-export` generates index files.** A vault's own `index.md` is a note, not a spec index, so it becomes the folder note: `dir/index.md` is written as `dir/dir.md`, and the root one as `<vault folder>.md`. A spec `index.md` listing is generated in every folder that holds a note, and the root one carries `okf_version`. Each entry is a bullet with the note's title as the link text, the file as the link target and the description after a dash, read from the note's frontmatter, with the file name as the title when the note has none or is not valid UTF-8. A rename onto an existing note stops the export with exit 2 and names both files. Links to the renamed note are rewritten to its new name.
- **A BOM note is listed by its title,** not by its file name.

## [0.9.14] - 2026-10-18

OKF Knowledge Gate 0.9.14 adds `okf-export`, which writes a vault of `[[wikilinked]]` notes out as a bundle `okf-check` can gate.

### Added
- **`okf-export <vault> <out>`.** For a team that edits in an Obsidian-style vault, where backlinks and the graph count only `[[wikilinks]]`: the vault stays the source and is only read, and the export is a separate bundle. Body `[[note]]`, `[[note|alias]]`, `[[note#heading]]` and `[[#heading]]` become relative Markdown links; each target and heading is checked. Frontmatter, code fences and code spans are copied unchanged (a byte order mark and CRLF line endings are kept), and an embed `![[x]]` is left as written. A table-cell alias written `[[a\|alias]]` is read as an alias. A heading link into a file that is not Markdown (`[[doc.pdf#page=3]]`) keeps its fragment and is not read as text. A note that is not valid UTF-8 is listed as `file:1: not valid UTF-8, copied unchanged` and the rest of the vault is still exported. A target is matched by its exact case. Exit 1 lists each missing or ambiguous target and each missing heading as `file:line` (the bundle is still written); exit 2 means nothing was written (`<out>` is not empty, or is inside the vault). Names and link text quoted in those lines have control characters replaced by `?`.
- **`okf-export` is on the Bash tool's PATH** while the plugin is enabled (`plugin/bin/okf-export`), like `okf-check` and `okf-verify`.
- **A new suite, `plugin/scripts/okf-export.test.sh`,** in the release gate.

## [0.9.13] - 2026-10-18

OKF Knowledge Gate 0.9.13 can check each note Claude writes or edits, at once, with an opt-in hook.

### Added
- **An opt-in PostToolUse hook, `okf-edit-hook.py`.** After a `Write` or `Edit` of a `.md` note inside a bundle (the nearest folder above the note that holds `okf-base.yaml`), it runs `okf-check <bundle> --file <note>` and gives Claude one warning line for an L1 error or a Trust warning, so a batch of edits is checked before anyone runs the full gate. A note outside any bundle is ignored. It is **off by default**: turn it on with `okf_check: {edit_hook: true}` in the bundle's `okf-base.yaml` (a YAML boolean; a quoted string such as `"on"` is refused) or with `OKF_EDIT_HOOK=1` for every bundle. It is time-boxed (`plugin/config/edit-hook.json`, 4 s; `OKF_EDIT_HOOK_TIMEOUT` overrides) and fails open: on a timeout, a crash or any other error it exits 0 without output, and the edit stands. An L1 warning (a missing `tags`) does not fire it, because it would fire on every edit of such a note. The one line Claude reads is cleaned: control characters become `?` and it is cut at 300 characters, because it quotes note values back. `OKF_EDIT_HOOK_TIMEOUT` cannot raise the box above 4.5 s (the platform cancels the hook at 5 s).
- **The hook is registered for every install** (`plugin/hooks/hooks.json`, matcher `Write|Edit`, platform timeout 5 s). While it is off, it reads the event and, for a `.md` file inside a bundle, that bundle's `okf-base.yaml`, then exits (about 0.07 s measured).
- **A new suite, `plugin/scripts/edit-hook.test.sh`,** in the release gate.

## [0.9.12] - 2026-10-18

OKF Knowledge Gate 0.9.12 checks one note in well under a second, so an edit hook can run it.

### Added
- **`okf-check <bundle> --file <note>`.** L1 and Trust for that one note, no other layer: one line per finding (`<note>: L1 error: ...`, `L1 warning`, `Trust warning`), nothing when the note is clean. It calls the vendored validator's own per-file checks, so it copies no rule; a test compares its findings with a full run's for the same note. Exit codes keep their meaning: 1 for an L1 error (or, with `--strict-trust`, a Trust warning or a near-miss actor), 0 otherwise, 2 when it could not run, 64 when the note is missing, is not a `.md` file, or lies outside the bundle. A note that `.okfignore` excludes prints `not checked (.okfignore excludes it)` and exits 0. The full run is still the gate.
- **`--selftest` probes `--file`** (a note without frontmatter must print its L1 error), and a crippled copy exits 5, because the edit hook reads "nothing printed" as a clean note.
- **A new suite, `plugin/scripts/scoped.test.sh`,** in the release gate.

## [0.9.11] - 2026-10-18

OKF Knowledge Gate 0.9.11 makes every file walker treat symlinks the same way, so a note is counted once.

### Fixed
- **A symlinked folder is no longer entered; a symlinked note file still counts.** The layers walked with `find -L`, which followed a folder link: a folder that aliased another folder in the bundle listed every note in it twice (an expired note appeared twice under `--fail-stale`), and a link that pointed outside the bundle counted the outside notes as bundle notes. The vendored validator never entered folder links, so the layers disagreed with it. All walkers now use one rule (`okf_md_files`), the validator's: a folder link below the bundle root is not entered, a note-file link counts wherever it points, a dangling link is skipped, and the bundle root itself may be a symlink.
- **The text report names what it left out.** When a bundle holds symlinked folders, the report has a line `symlinks  N symlinked folder(s) not entered`, so notes behind a link are left out on the record, not silently. It never changes the exit code. (`--json` does not list them.)
- **`--duplicates` and `--duplicates-body` keep one entry per real path.** A symlink alias of a note is no longer listed against a third note that shares its title. The real file wins over the alias, whatever order the walk finds them.
- **A new suite, `plugin/scripts/symlinks.test.sh`,** checks that every walker returns the same file set on the same symlink tree (case S8-E1), and runs in the release gate.

## [0.9.10] - 2026-10-18

OKF Knowledge Gate 0.9.10 finds notes whose bodies are near copies, with `--duplicates-body`.

### Added
- **`okf-check <bundle> --duplicates-body`.** The same report as `--duplicates`, plus pairs of notes whose bodies share 5-word shingles at or above `okf_check.duplicates.body_threshold` (default `0.6`: on a blind-labelled sample of 24 live body pairs, 0.3 had precision 0.50 and 0.6 had 1.00). Candidates come from MinHash signatures with LSH banding, and the exact Jaccard of the shingle sets decides. It is advisory and time-boxed like `--duplicates`: exit 0, `CUT SHORT` when the limit was hit, `--json` `duplicates[]`. A note that starts with a byte order mark is counted by its body, not its frontmatter.
- **A symlink alias of a note is not a body duplicate of its target, and an unreadable `.md` entry** (a dangling symlink, a folder named `x.md`) **is skipped.** Both were found in review: the first listed a note against itself, the second stopped the report with exit 2.
- **`--selftest` probes `--duplicates-body`**, and a crippled copy exits 5.

## [0.9.9] - 2026-10-18

OKF Knowledge Gate 0.9.9 lists candidate duplicate notes, so a maintainer can deprecate one of a pair.

### Added
- **`okf-check <bundle> --duplicates`.** A report of its own, not a gate: it runs instead of the layers and always exits 0 once it ran. A pair of notes is a candidate when they have the same normalized title, cite the same `sources[].resource`, or have descriptions whose word sets overlap at or above `okf_check.duplicates.threshold` (default `1.0`: identical word sets, because lower values flagged templated series on our labelled sample). Each pair shows the signal and score, both statuses, both `generated.at` values and both owners. A pair already linked by `superseded_by` is skipped. The run is time-boxed by `okf_check.duplicates.time_limit` seconds (default 60) and says `CUT SHORT` if it was. `--json` adds `duplicates[]`.
- **A note whose `sources` is not a list is read, and a symlink alias of a note is not listed against its target.** Both were found in review: the first made `--duplicates` stop with exit 2, the second reported a note as a duplicate of itself.
- **`--selftest` probes `--duplicates`**, and a crippled copy exits 5. The note reader the Successor, Owner and duplicates rules share moved to `okf_notes.py`.

## [0.9.8] - 2026-10-18

OKF Knowledge Gate 0.9.8 lets a bundle require that every note has an owner, and shows the owner on stale and lifecycle findings.

### Added
- **`okf_check.require_owner` and `okf_check.owners`.** With `require_owner: true` (off by default), every note must have an owner: an actor in the form of OKF section 7 (`human:dana`, `team:docs`, `tool/1.0`). A note's own `owner` key wins. Otherwise `owners` gives folder defaults as globs (the `.okfignore` syntax), and the last matching pattern wins. The new `Owner` line reports a note with no owner and an owner that is not an actor; both are house-rule errors and exit 1. `owners` is only valid when `require_owner` is on; a bad value exits 2 and names it.
- **The owner shows on staleness findings.** Each L3 staleness and lifecycle finding ends with `owner <actor>`, in the text and in the `--json` `stale[]` and `lifecycle[]` entries, so a report can be sent to the right person.
- **A note that starts with a byte order mark is read correctly by the Successor and Owner rules.** Before, such a note was accepted by L1 but its `superseded_by` or `owner` was not seen, so a deprecated note without a successor passed the Successor rule (0.9.7) and a note with an owner was reported as having none. An `owners` pattern that starts with `!` (negation) is refused with exit 2 instead of being ignored in silence, and an `owner` that is not a string (a list, a number, `false`) is reported as not an allowed actor form.
- **`--selftest` probes the Owner rule** (a note without an owner, option on), and a crippled copy exits 5. The schema gained `map`, `boolean` and `requires` node kinds for these options.

## [0.9.7] - 2026-10-18

OKF Knowledge Gate 0.9.7 lets a bundle require that a deprecated note names the note that replaces it.

### Added
- **`okf_check.deprecated_requires: superseded_by`.** With this option in the `okf_check:` block of `okf-base.yaml` (off by default), every note with `status: deprecated` must carry `superseded_by`: a path, a `[[wikilink]]`, a markdown link, or a list of them, resolved from the bundle root or the note's own folder (the same way the L2 wikilink rule resolves a link). The new `Successor` line reports a deprecated note with no `superseded_by`, a successor that is not found, a note that names itself, and a successor that is deprecated too (one hop only: point at the final successor). Each is a house-rule error and exits 1. A value other than `superseded_by` for the option exits 2 and names the allowed value. The schema gained an `enum` node kind for this.

## [0.9.6] - 2026-10-18

OKF Knowledge Gate 0.9.6 makes `--selftest` prove more of the gate: it now plants a defect for three layers it never tested.

### Added
- **`okf-check --selftest` probes L0, the L2 index and L3 derived staleness.** Before, it planted one defect in each of L1, L2 (profile), Trust and L3 (staleness). It now also checks that the doctor notices a missing vendored validator (L0), that an `index.md` which counts the wrong number of notes is caught (L2 index), and that a note recording a source as of an old date is caught when that source has changed since (L3 derived staleness). A probe that does not fire exits 5, as before.

### Fixed
- **A `--selftest` that skipped a probe no longer says "every gate still fires".** Without `okflint` the L2 profile probes are SKIPPED, and the verdict line now names them as unverified instead of claiming every gate fired.

## [0.9.5] - 2026-10-18

OKF Knowledge Gate 0.9.5 makes `okf-verify` check code citations written as a file, a line and a commit, the form most notes use for code.

### Added
- **`okf-verify` reads `path:line @sha` as one claim.** `` `src/a.py:10 @d084956` ``, `path:first-last @sha` and `path:line at sha` are looked up as a single claim. The commit is searched in every repository (`--repo` and the ones the bundle declares), then the path is looked up in that commit's files. It may be only the end of the path (`a.py` for `src/a.py`). The verdict is CONFIRMED when the file exists at that commit; REFUTED when the commit is found and the file is not in it (the detail says the path part failed); UNRESOLVED when the commit is in no searched repository, or when the end of the path matches more than one file.
- **The cited line must exist.** A line, or the end of a range, past the end of the file is REFUTED and the detail gives the file's line count; line 0 is REFUTED; a range ending on the last line is CONFIRMED; an empty file has no line (REFUTED) and a binary file is UNRESOLVED with the reason `binary`, never a crash. `--json` shows the sha, path, line and line count of each citation.

## [0.9.4] - 2026-10-18

OKF Knowledge Gate 0.9.4 lets a bundle name its source repositories once, and gives `okf-check`'s own options a home that is checked, so a typo cannot switch an option off.

### Added
- **`okf-verify` reads the repositories a bundle declares.** `okf-base.yaml` may list them under `okf_check.verify.repos` (each entry has a `path`: relative to the bundle, absolute, or starting with `~`). `okf-verify <bundle>` searches them for cited commits, `--repo` adds more, and a repository named twice is searched once. A declared path that is missing, or is a folder but not a git repository, is reported as UNRESOLVED with that reason.
- **One `okf_check:` block holds `okf-check`'s own options.** It is validated against one schema, `plugin/config/okf-check-block.json`, by `okf-verify` (`okf-verify --check-config <bundle>`), and `okf-check` calls that, so the two tools cannot disagree. A key the schema does not know, or a value of the wrong shape, exits 2 and names the key. `okflint` ignores the block (measured: the L2 warning count is the same with and without it). Without the block, output is unchanged.

### Fixed
- **A declared repository that cannot be resolved no longer crashes `okf-verify`.** A path such as `~nosuchuser/x`, or one under an unreadable folder, raised a traceback and exit 1, which reads as "a claim was refuted". It is now UNRESOLVED with the reason ("cannot resolve: <path>"), exit 0, and the other repositories are still searched.
- **The pre-push gate no longer writes into the repository it runs in.** In a linked worktree git hands a hook `GIT_DIR`; the suites the gate launched then built their fixture repositories inside the real one (fixture commits, `core.bare = true`, a replaced `pre-commit` hook). The installed hook and the gate now clear the git environment before running anything, and the gate refuses a tree that lost `tools/export-public.sh` instead of passing it as another project's tree. Development tooling only; the published plugin is unaffected.

### Changed
- **`okf-verify` stops with exit 2 on a malformed `okf-base.yaml`.** An unreadable file, invalid YAML, a top level that is not a mapping, or a `verify.repos` entry that is not `{path: <string>}` was ignored before. A declaration that is ignored in silence reads as "no repositories declared". This also applies to a bundle with no `okf_check` block; `okf-check` already failed such files.

## [0.9.3] - 2026-10-17

OKF Knowledge Gate 0.9.3 changes no plugin behaviour. It scripts the release checks that were run by hand, so a slip fails before it reaches a release. These tools live in the development repository and are not part of the published plugin.

### Added
- **A Linux release gate.** `tools/linux-gate.sh` streams the committed tree into a Debian 12 container, installs the pinned `okflint` and `pre-commit` in a Python 3.12 environment as a non-root user, and runs every suite and `--selftest`. The image, versions and suite list are in `tools/linux-gate.conf`; the Docker context comes from `OKF_DOCKER_CONTEXT` or docker's current context. Without docker, or with an unreachable context, it stops with exit 2 and names the setting.
- **A pre-push gate.** `tools/install-git-hooks.sh` also installs a `pre-push` hook. It runs `tools/pre-push-gate.sh` on each pushed commit (not on the working tree): the test-file check, the public export and its scan, and the exported tree's `plugin.test.sh`. A tree that passed is recorded, so pushing it again does not re-run the suite.
- **A test-file check.** `tools/check-tests.sh` fails when any `*.test.sh` does not parse or no longer ends with its final-status line, the line that makes a suite fail.

## [0.9.2] - 2026-10-17

OKF Knowledge Gate 0.9.2 closes the false passes the final 0.9.1 review found, makes `--json` carry the findings, and stops two noisy results (the Action's silent green, and `[[sub/b]]` reported as broken).

### Fixed
- **L3 (staleness) uses the same frontmatter fence rule as L1.** A note whose fences had trailing spaces (`--- `) and an expired `stale_after` passed; a `---` block in a note's body was read as frontmatter (a false stale, and an expired note listed up to three times).
- **The Trust layer reads look-alikes.** `verified[].by: humаn:dana` written with a Cyrillic or fullwidth letter is a near-miss of `human:` (`--strict-trust` exits 1); a string-valued `verified: human:dana` on a draft note is read; a bare `generated.by` token such as `claudebot` counts as an agent. A prefix wholly in another script (`团队:`) is not flagged.
- **L1 and L3 findings that were silent:** a deeply nested document is an L1 error on that note instead of a crash that blanked L1 and Trust for the whole bundle; a duplicate frontmatter key and a `generated.at` later than tomorrow are warnings; a `stale_after:` with no value is reported by L3.
- **The verdict line counts every skipped layer.** It said "1 skipped layer(s)" when two layers were SKIPPED (the L2 index skip was not counted).
- **`--json` is valid JSON for any bundle path** (a path containing a double quote broke it) and has the same keys on every exit path.
- **`okf-verify`:** a `..` in a cited path no longer reads as "only a case-variant exists"; a SHA missing from a shallow clone says the clone is shallow.
- **The pre-commit hook** also runs when only `okf-base.yaml` or `.okfignore` changes.
- **L2 no longer reports path-qualified wikilinks as broken.** `okflint` finds a wikilink by file name only, so `[[sub/b]]` was reported (L001) although `sub/b.md` exists. `okf-check` drops that finding when the file exists, from the bundle root or from the note's folder, and prints how many it dropped. A link to a note that does not exist is still reported.

### Added
- **L3 keeps a status outside draft, stable, deprecated apart from staleness.** It has its own `L3 lifecycle` line and is no longer counted as "need attention" beside expired notes; `--fail-stale` exits 4 only when a note is expired or its `stale_after` is malformed (before, 80 unknown-status notes made it exit 4 with nothing expired).
- `--json` carries `errors[]`, `stale[]`, `l2_findings[]`, `skipped[]`, `lifecycle[]`, `l2_warnings` and `l2_by_rule` next to the counts. The L2 totals are what the text prints ("138 warning(s), by rule: S202 x136, L002 x2"); they are null when L2 did not run.
- The GitHub Action logs a `::warning::` for a bundle with 0 concepts and for each skipped layer, and has an input `require-house-rules` (default `false`): `true` fails the job with exit 3 when L2 was skipped.
- `okf-verify --host-paths` (see Changed).

### Changed
- `--doctor` says whether the optional `okf` search binary is present. Without it the doc-reuse reminder cannot name the closest existing notes, and nothing said so before.
- **The export keeps CHANGELOG compare links for releases the public repository holds** (the exported suite failed on them).
- **Fixed by the cross-vendor review:** the staleness hook no longer prints nothing when a directory name holds a newline; an active `.okfignore` no longer drops a note reachable only through a symlinked directory; the doc-reuse hook no longer ships the maintainer's lesson-store facts.
- **`okf-verify` no longer looks up cited paths outside the bundle and the `--repo` folders.** Such a path is UNRESOLVED. Before, a bundle you did not write could use the check to learn which files exist on your machine. Pass `--host-paths` for the old behaviour.
- The public export drops private issue numbers and commit ids from every file (the vendored validator keeps its public upstream references).
- A plugin installed at a different version than the source tree is now a test failure, not a skip.

## [0.9.1] - 2026-10-17

OKF Knowledge Gate 0.9.1 fixes a memory problem: a small note can no longer make `okf-check` use gigabytes of memory.

### Security
- **A note with nested YAML aliases (an "alias bomb") no longer exhausts memory.** In 0.9.0 a small note could
  make L1 (the OKF spec check) use gigabytes of memory and not finish: a 9-level bomb used 2.5 GB and did not finish
  in 60 s. It is now an L1 error on that note, found in under 1 s at about 24 MB, and the run exits 1 and names the note.
- The limits are 1,000,000 items, 10,000,000 scalar characters in all and 100,000 characters in any one scalar, counted
  without expanding anything. Normal notes, including ones that reuse an anchored value, are unaffected. The
  single-scalar limit closes a slow case: a 2,000,000-digit integer made `okf-check` run for 47 s on Python 3.9.
- L2 (house rules, run by `okflint`) is not run after L1 rejects a note this way, because `okflint` would expand the
  same bomb. L2 prints `COULD NOT RUN` with the reason. The trust layer and the L3 derived-staleness scan use the same
  limit.
- The vendored validator now carries a small local patch for this; `plugin/vendor/VENDOR.md` lists it.

### Added
- A demo GIF in the README, recorded from real `okf-check` runs (`tools/demo/` records and renders it, and a test
  fails if the demo is out of date).

### Fixed
- The pre-commit hook now also runs when only `okf-base.yaml` or `.okfignore` changes, not just `.md` files.
- The skill says `--json` carries the verdict only (not the failing notes), and no longer claims `ALL GATES PASS` is refused
  whenever a layer is skipped.

### Known limits
Found in the final pre-release review. They also exist in 0.9.0, are not regressions, and are scheduled for 0.9.2:
- L3 (staleness) does not see an expired `stale_after` when the frontmatter fences have trailing spaces.
- `--strict-trust` does not flag a look-alike of `human:` written with a non-ASCII letter, or `verified:` written as a
  plain string instead of a list or mapping.
- Duplicate YAML keys in a note are accepted without a warning (the last one wins).

### Changed
- The README opens with what OKF and a bundle are and a real sample run. Its sections follow the order a new user
  needs (install, use, CI, platforms, dependencies), and every claim in it has a source or an UNVERIFIED label.

## [0.9.0] - 2026-10-16

OKF Knowledge Gate 0.9.0 adds a check for "verified by a human" claims in notes, and runs the same check in CI and in git hooks.

### Changed
- **Upgrade note.** Every run now prints a Trust line. A run that passed before can now show advisories, because a trust
  warning counts in the final advisory tally. With `--strict-trust` it can fail with exit 1, and exit 1 now also means a
  trust-policy failure.
- **L1 warnings are listed**, not only counted (capped at 50 with "and N more"). L1 is the OKF spec check. The FAIL line
  carries the warning count.
- The skill (`SKILL.md`) is rewritten for agents: an action per exit code, the exit precedence, a never-list, the Trust
  layer, the CI doors. Maintainer detail moved, unchanged, to `references/`.
- README: a Platforms table that states what was measured and labels the rest UNVERIFIED, the two upstream pins with
  what happens if their pull requests are never merged, and CI and git usage.
- Exit 1 is documented to cover `--init-ignore` and `--init-house-rules` refusing to overwrite a file (they already did).
- `tools/install-dev-deps.sh` also plans `pre-commit` (opt-in `--yes`) so the hook can be tested end to end.

### Added
- **Trust layer (C4): unauthenticated human verification.** OKF v0.2 records `verified: by: human:<id>` and cannot
  authenticate it, so an agent can write that line itself. `okf-check` now reports, per `human:` entry, a draft note or
  a review dated before the note's change as a warning, and an agent-generated note as an advisory. It prints that it
  cannot prove who a person is.
- **`--strict-trust`.** Makes those findings, and near-miss actors such as `Human:dana` (read as an agent), fail the run
  with exit 1. It changes severity only.
- **`okf-check --init-house-rules <bundle>`.** Writes a starter `<bundle>/okf-base.yaml` so L2 (house rules, run by
  `okflint`) runs. Never automatic, never overwrites. Without `okflint`, the skipped-L2 line names this command too.
- **GitHub Action and pre-commit hook.** `action.yml` (inputs `bundle`, `strict-trust`, `fail-stale`) and
  `.pre-commit-hooks.yaml` run the same `okf-check` without Claude Code.
- **`bin/` wrappers.** `okf-check` and `okf-verify` are on the Bash tool's PATH while the plugin is enabled (a documented
  Claude Code feature), so an agent does not need the long path.
- `--json` gains `warnings`, `trust_findings` (`null` when the layer could not run) and `l2_profile` (`ran`, `skipped`
  or `could_not_run`).
- `--selftest` probes the trust layer, so a disabled trust rule cannot print `SELFTEST PASS`.
- The plugin folder ships its own `LICENSE`.

### Security
- **Known issue in 0.9.0, fixed in 0.9.1:** a note with nested YAML aliases (an "alias bomb") can make L1 use
  gigabytes of memory and not finish. The trust layer of 0.9.0 already refuses such a note, but L1 and L2 did not. Upgrade
  to 0.9.1.

## [0.8.1] - 2026-10-16
### Documentation
- README states that the project is independent and unofficial, and not affiliated with Google,
  the OKF maintainers, or the authors of the tools it builds on.

## [0.8.0] - 2026-10-15

### Added
- **Per-note isolation in L2.** When okflint crashes on a bundle of at most `OKF_L2_ISOLATE_MAX`
  notes (default 200), L2 runs it note by note (about 0.2 s each), names the notes it crashes on,
  and checks the rest. The run exits 2 (or 3 when the checked notes fail): a crashed note is never a pass. Larger bundles keep the
  plain report. The whole rescue shares one `OKF_L2_TIMEOUT` budget.

## [0.7.2] - 2026-10-15

### Fixed
- A `.okfignore` that excludes no file no longer changes the verdict. With every note behind a
  symlinked directory it turned exit 4 into exit 2 and said "excludes every note".
- A leading `**/` in `.okfignore` also matches at the bundle root, with or without a leading `/`.
- Excluding only non-note files (for example `*.json`) no longer reports "excludes every note".

### Added
- A test that the status vocabulary in `okf-base.yaml.template` and in `l3-lib.sh` stay equal.
- README and SKILL.md document the user-facing environment variables.

## [0.7.1] - 2026-10-15

### Fixed
- A hung `okflint` no longer stalls L2 for as long as it hangs. The call is cut off after
  `OKF_L2_TIMEOUT` seconds (default 120) and the report says it timed out.
- The doc-reuse guard leaves no orphan child process when it kills a hung search binary.
- The spec-traceability test (D-1) runs in the public tree too: it finds the spec at
  `docs/spec.md`.

### Added
- Test fixtures captured from the real `okf search` output, including a two-digit score.
- `OKF_L2_TIMEOUT=0` means the default, and an okflint that ignores TERM is still reported as timed out.

## [0.7.0] - 2026-10-15

### Fixed
- The doc-reuse guard no longer prints two reminders when a path matches both a built-in location
  and a `doc-dirs` glob.

### Added
- **`.okfignore`.** A file at the bundle root, one gitignore-style glob per line, keeps paths such
  as `archive/` and `.trash/` out of every layer (L1, L2 profile and index, L3, L3 derived, and
  `okf-verify`). A trailing `/` means directories only; a pattern without `/` matches a name at any
  depth; `*` also crosses `/`; `!` negation is skipped with a notice. The run prints how many files
  were excluded (`--json`: `ignored`). A file that excludes every note exits 2. Nothing is
  created automatically: `okf-check --init-ignore <bundle>` writes a starter once and never
  overwrites. Without `.okfignore` behaviour is unchanged. L1, L2 and L3 read a filtered copy
  (symlinked directories are not followed, as in L1 without the file); L3 derived reads the real
  bundle so source paths resolve. An unreadable `.okfignore` or an uncopyable note is exit 2.
- The doc-reuse guard names the three closest existing notes (`Closest existing notes (okf search): a, b, c.`)
  when an `okf` search binary is available (`OKF_SEARCH_BIN`, else `okf` on PATH). The plugin does
  not install it. Absent, slow (2 s limit) or failing binary: the reminder is unchanged.

### Planned
- Replace the vendored validator with the upstream release when
  [okf-skills#68](https://github.com/scaccogatto/okf-skills/pull/68) merges, and install
  okflint from its release when [okflint#11](https://github.com/mattdav/okflint/pull/11) merges.
- Evaluate an optional search and graph-health layer (orphans, broken links, search before
  write). Tracked in this repository's issues.

## [0.6.1] - 2026-10-15

### Changed
- The doc-reuse guard no longer has personal document locations built in. Defaults are generic
  (`docs/`, `doc/`, the lessons directory). Extra locations go in `~/.config/okf/doc-dirs`, one
  shell glob per line (`OKF_DOC_DIRS_FILE` overrides the path). A missing or unreadable file never
  blocks a write.

## [0.6.0] - 2026-10-15

### Added
- **Prerequisite preflight.** A SessionStart hook runs `okf-check --preflight`: silent when
  python3 and okflint are present at the supported version, one line naming the problem and the
  fix otherwise. It never fails the session.
- **`okf-check --install-deps`** prints the plan for the supported okflint and, with `--yes`,
  installs it with `uv`. `--latest` takes the newest release. A failed install reinstalls the
  previous okflint exactly (the saved tool directory comes back). The install is time-bounded
  (`OKF_INSTALL_TIMEOUT`, default 200 s), refuses a pinned source that could be read as an option,
  and refuses to run when the pins file is unreadable. `OKF_AUTO_INSTALL=1` lets the preflight run
  the plan; it is off by default.
- `plugin/config/pinned-versions.txt` has an `okflint_source` line: the fork commit that carries
  the okflint#11 fixes, until that pull request merges.

### Changed
- The skill, README, marketplace text and spec no longer say the plugin "never installs": it installs only when asked.
- The preflight prints a fix command that runs as printed (full path), and it names a stock okflint
  that has the supported version number (one BOM probe, only when a source is pinned).
- `--latest` warns that the newest PyPI okflint may lack the okflint#11 fixes.
- The plan reports `jq` (optional).

## [0.5.18] - 2026-10-14

### Fixed
- Crash isolation no longer deletes files. With a symlinked directory in the bundle, the
  first version removed a file outside the bundle. The isolation now works on copies and
  never deletes.
- A trailing slash on the bundle path no longer breaks crash isolation.
- A note name that contains `|` or a newline is printed intact in the crash report.
- A hung okflint no longer stalls every run. The okflint probes run only under `--doctor`,
  and each probe has a timeout.
- `okf-check` stops on SIGTERM (exit 143) instead of continuing.
- The by-rule summary says how many rule codes it left out.
- A stray empty test directory is no longer shipped in the plugin.

### Added
- The doctor reports `UNKNOWN` when okflint gives no verdict on a clean control note, and
  when its template is missing. It no longer reports a false `UNPATCHED`.

### Changed
- The skill text states that an okflint crash is not isolated per note.

## [0.5.17] - 2026-10-14

### Added
- The L2 summary groups advisory findings by rule code, for example
  `by rule: S205 x123, S202 x84`.
- The doctor runs `okflint validate-manifest` on the shipped template and reports
  `OK`, `REJECTED` or `UNAVAILABLE`.

## [0.5.16] - 2026-10-14

### Changed
- The okflint behaviour probe covers three cases: a BOM note, a non-UTF-8 note and an
  impossible date.

### Fixed
- Two probe fixtures were written empty and tested nothing. Found by running the probe
  against real stock okflint builds.

## [0.5.15] - 2026-10-14

### Added
- `okf-check --doctor` probes okflint behaviour, because the patched build and stock 0.5.0
  print the same version string.

## [0.5.14] - 2026-10-14

### Changed
- The okflint crash-reason test uses a crashing stub, so it no longer depends on an upstream bug.

## [0.5.13] - 2026-10-14

### Changed
- The vendored validator is now our patched copy of okf-skills (upstream 0.10.3 plus five
  fixes, submitted as okf-skills PR #68). It replaces the 0.6.0 copy.

### Fixed
- A `status` that is a list or mapping no longer crashes the validator.
- An impossible date in frontmatter is a per-file error, not a crash.
- A percent-encoded link (`My%20Note.md`) resolves to the file.
- Link syntax inside an inline code span is not read as a link.
- An indented `---` inside a block scalar no longer ends the frontmatter.

## [0.5.12] - 2026-10-14

### Fixed
- One note that crashed the validator blanked the whole L1 verdict and named no file. The
  note is now named with the validator's last error line, the other notes are still
  validated, and the exit code is 2 (1 if a real conformance error is also present).
- An okflint crash prints a `reason:` line.

## [0.5.11] - 2026-10-14

### Changed
- The `okf` skill documents the L3 value rules and the cases that exit with code 2.

## [0.5.10] - 2026-10-14

### Changed
- `okf-check` and the lessons staleness hook share one frontmatter reader (`l3-lib.sh`).
  No behaviour change.

## [0.5.9] - 2026-10-14

### Added
- The spec lists the L3 rules as rows LT-01 to LT-08c, each cited by a test.

### Fixed
- The test suites kept running after SIGTERM. INT and TERM now stop them.

## [0.5.8] - 2026-10-14

### Fixed
- A killed `okf-verify.test.sh` left directories in `$HOME`. The suite sweeps its own
  stale directories at the start of a run.

### Changed
- The L3 rules were verified on GNU awk and mawk, on macOS and Linux.

## [0.5.7] - 2026-10-14

### Changed
- The accepted `status` values (stable, draft, deprecated) are defined once and shared.

### Fixed
- The hook label no longer claims "not marked stable" for a list that allows `draft`.
- The scan failure message names awk and xargs, not awk alone.

## [0.5.6] - 2026-10-14

### Fixed
- A crashed L3 awk read as "PASS nothing expired". It now exits 2.
- The lessons hook works through a symlink and under an exported `CDPATH`.
- The lessons hook accepts the same `status` values as `okf-check` (it flagged `draft`).

## [0.5.5] - 2026-10-14

### Fixed
- A missing `l3-lib.sh` made L3 pass silently. It now exits 2.
- `OKF_TODAY` is validated and refused unless it is `YYYY-MM-DD`.

## [0.5.4] - 2026-10-14

### Added
- `OKF_TODAY` pins "today" for tests and replays.

### Changed
- The lessons hook reads values like `okf-check` does (comments, quotes, non-padded dates).

## [0.5.3] - 2026-10-14

### Changed
- okflint is pinned at 0.5.0 (was 0.3.1).

## [0.5.2] - 2026-10-14

### Fixed
- L3 skipped every `README.md`. A `README.md` is a concept and is now checked.
- A CRLF note was invisible to L3 and to the lessons hook.
- A trailing `# comment` on `status` or `stale_after`, and a non-zero-padded date, were
  mis-read. A `stale_after` that is not a date is reported as malformed.
- `okf-verify.test.sh` wrote files into the plugin directory.

### Added
- `VENDOR.md` names the OKF spec version and URL.

## [0.5.1] - 2026-08-02

### Added
- L2 index: `index.md` is checked against the bundle it describes (bold count declarations
  against the files on disk).

## [0.5.0] - 2026-08-02

### Added
- L3 derived staleness: a concept that records `sources[].last_modified` is compared with the
  file's mtime, not only with its `stale_after` date.

Earlier history is in the git log and the `pre-*` / `post-*` tags.

[Unreleased]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.26...HEAD
[0.9.26]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.25...v0.9.26
[0.9.25]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.24...v0.9.25
[0.9.24]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.23...v0.9.24
[0.9.23]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.22...v0.9.23
[0.9.22]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.21...v0.9.22
[0.9.21]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.20...v0.9.21
[0.9.20]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.19...v0.9.20
[0.9.19]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.18...v0.9.19
[0.9.18]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.17...v0.9.18
[0.9.17]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.16...v0.9.17
[0.9.16]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.15...v0.9.16
[0.9.15]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.14...v0.9.15
[0.9.14]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.13...v0.9.14
[0.9.13]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.12...v0.9.13
[0.9.12]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.11...v0.9.12
[0.9.11]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.10...v0.9.11
[0.9.10]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.9...v0.9.10
[0.9.9]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.8...v0.9.9
[0.9.8]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.7...v0.9.8
[0.9.7]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.6.0...v0.6.1
