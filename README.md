# OKF Knowledge Gate

A Claude Code plugin and command-line tool that checks a folder of OKF markdown notes and tells you whether you can still trust it.

OKF is the [Open Knowledge Format](https://github.com/GoogleCloudPlatform/open-knowledge-format): a format for markdown
notes that agents read. A bundle is one folder of OKF notes with an `index.md`. `okf-check` runs one command over a
bundle and gives one verdict from several layers.

![okf-check on one note in four steps: it fails with no `type`, passes as a draft with a Trust warning, fails under --strict-trust, then passes once a person has reviewed it](docs/demo.gif)

The GIF is a recording of real runs (about 24 seconds). `tools/demo/record.py` captures the commands and
`tools/demo/render.py` draws the GIF from that capture.

## Why use it

- **It checks that what a note cites still exists.** `okf-verify` looks up the commit SHAs and file paths a note cites
  and answers CONFIRMED, REFUTED or UNRESOLVED. "Could not check" is never shown as "false". Of the 15 OKF tools whose
  source we read in October 2026, none checks the commits a note cites ([how we checked](docs/comparison-2026-10-17.md)).
- **It does not take "a human verified this" on faith.** The Trust layer (check C4 in the spec) flags a verification on a draft note, one
  dated before the note's last change, and one on a note an agent wrote. It cannot prove who a person is, and it says so
  on every finding.
- **One verdict you can gate on.** `okf-check` runs every layer. Exit 1 means "not valid", exit 2 means "could not run",
  and a skipped layer is printed as SKIPPED and never shown as PASS (the exit code stays 0, and the verdict line reports
  a skipped layer). `--selftest` plants one defect in each of L0 (doctor), L1, L2 (profile), L2 (index), Trust,
  L3 (staleness), L3 (derived staleness), the Successor rule, the Owner rule, `--duplicates` and `--duplicates-body` and fails if a gate misses it. Without `okflint` the L2 profile probes are
  SKIPPED, and the verdict line names them.
- **The same check in three places.** Claude Code (hooks, plus a skill an agent reads), a GitHub Action, and a pre-commit
  hook. The test suites pass on macOS and on Debian 12 (see [Platforms](#platforms)).
- **Nothing is installed unasked.** The validator and PyYAML are vendored. `okflint` is optional, and
  `okf-check --install-deps` only prints a plan until you add `--yes` (see [Tools it uses](#tools-it-uses)).

## Contents

- [Why use it](#why-use-it)
- [What it checks](#what-it-checks)
- [Install](#install)
- [Use](#use)
- [Use in CI and git](#use-in-ci-and-git)
- [Tools it uses](#tools-it-uses)
- [Platforms](#platforms)
- [Support and contributing](#support-and-contributing)
- [About this project](#about-this-project)
- [Develop and test](#develop-and-test)
- [Release](#release)
- [License](#license)

## What it checks

| Layer | Question | Backed by |
|---|---|---|
| L0 doctor | Can the gate run here at all? | runtimes, dependencies, version pins, behaviour probes |
| L1 conformance | Is this valid OKF? | the vendored OKF v0.2 validator |
| L2 profile | Is this valid *our* OKF (house rules)? | `okflint` and the bundle's `okf-base.yaml`. `okflint` finds a wikilink by file name only, so it reports `[[sub/b]]` as broken even when `sub/b.md` exists; `okf-check` drops that finding when the file exists (from the bundle root or from the note's folder) and prints how many it dropped |
| L2 index | Does `index.md` describe this bundle? | its bold count declaration against the files on disk |
| Trust (C4) | Can you believe a `human:` verification? | `okf-trust.py`: a draft note, or a review dated before the change, with a human verifier is a warning; an agent-generated note with one is an advisory. It cannot prove who a person is. |
| L3 staleness | Is it still true? | `stale_after` against today, and `status` |
| L3 derived | Has what it describes moved since? | `sources[].last_modified` against the file's mtime |
| L4 claims (`okf-verify`) | Do the cited commits and paths exist? | CONFIRMED, REFUTED or UNRESOLVED per claim |

Also shipped:

- A SessionStart preflight that reports a missing or unsupported prerequisite (`okf-check --preflight`).
- A SessionStart hook that reports stale lessons (`lessons-staleness-check.sh`).
- A PreToolUse hook that stops a duplicate document being written (`doc-reuse-guard.sh`). With an
  [`okf`](https://github.com/GoogleCloudPlatform/open-knowledge-format) search binary on PATH (or
  `OKF_SEARCH_BIN`) it also names the three closest existing notes. The plugin never installs it.
- An opt-in PostToolUse hook (`okf-edit-hook.py`) that checks each note Claude writes or edits inside a bundle
  (`okf-check --file`, L1 and Trust) and gives Claude one warning line on an L1 error or a Trust warning. Off until
  `edit_hook: true` or `OKF_EDIT_HOOK=1`; time-boxed and silent on any failure. It is registered for every install
  (`hooks/hooks.json`); while off it only reads the event and exits.
- A skill, `okf`, so an agent knows how to run the gate and read its result.

## Install

You need `python3`. PyYAML is vendored, so there is nothing else to install for L1. `okflint` (L2) is optional.
`okflint` needs Python 3.12 or newer: `pip` on Python 3.11 refuses it, and `uv` can supply a 3.12 (`okf-check --install-deps`
uses `uv`). Without `okflint`, L2 is SKIPPED, never passed. [Tools it uses](#tools-it-uses) lists everything else.

```bash
claude plugin marketplace add ahmedibrahim085/okf-knowledge-gate   # or a local path
claude plugin install okf@ahmedmaged-okf
```

While the plugin is enabled, Claude Code puts `okf-check`, `okf-verify` and `okf-export` on the Bash tool's PATH (the plugin's `bin/`
folder), so the bare commands below work in a session. Outside Claude Code, run `plugin/scripts/okf-check` from a clone.

Restart Claude Code to load a new version. Update with `claude plugin update okf@ahmedmaged-okf`.

**Prerequisites** are checked at every session start (no network, silent when fine). To see and install what is
missing, at the supported versions from `plugin/config/pinned-versions.txt`:

```bash
okf-check --install-deps           # shows the plan, changes nothing
okf-check --install-deps --yes     # runs it (okflint, via uv)
okf-check --install-deps --yes --latest   # newest okflint instead of the supported one
```

Set `OKF_AUTO_INSTALL=1` if you want the session-start check to run the install plan itself. It is off by default
because a plugin should not install software unasked.

## Use

```bash
okf-check <bundle>                 # all layers
okf-check <bundle> --fail-stale    # staleness blocks (exit 4)
okf-check <bundle> --strict-trust  # unauthenticated human verification and near-miss actors block (exit 1)
okf-check <bundle> --fail-on-change   # exit 6 if the bundle changes during the scan
okf-check <bundle> --json          # machine-readable summary (`l2_findings[]` lists house-rule errors; `l2_advisories[]` the advisories behind `l2_warnings`, as `RULE file — message`, cut at 200 with a count)
okf-check <bundle> --duplicates    # list candidate duplicate notes (a report, always exit 0)
okf-check <bundle> --duplicates-body   # the same, plus notes whose bodies are similar
okf-check <bundle> --file <note>   # L1 + Trust for one note: one line per finding, nothing when clean (for edit hooks)
okf-check --doctor                 # what is installed, and does okflint behave
okf-check --selftest               # re-prove every gate still fires
okf-check --init-ignore <bundle>   # write a starter .okfignore (never automatic, never overwrites)
okf-check --init-house-rules <bundle>   # write a starter okf-base.yaml so L2 runs (never automatic, never overwrites)
okf-verify <bundle> --repo DIR     # L4: are the cited commits real? DIR is where SHAs are looked up
okf-export <vault> <out>           # write a vault of [[wikilinked]] notes out as a bundle
```

What a run looks like (real output; four more lines are left out: the version header, two lines of advice and the L2 index line). The note says a human
verified it, but it is still a draft. `okf-check` cannot prove who a person is, so it flags the claim.
`--strict-trust` turns the flag into exit 1.

```text
$ okf-check notes
  L1 conformance   PASS   1 concepts, 0 errors, 0 warning(s)
  Trust (C4)       WARN   1 warning(s), 0 advisory(ies)
                   limits.md: verified[0].by `human:finance-owner` on a draft note: draft with human verification
                   okf-check cannot prove who a person is. A human: entry is a claim in the file.
  L2 profile       SKIPPED — no okf-base.yaml in notes
  L3 staleness     PASS   nothing expired

  PASS — no blocking errors, but 1 advisory(ies) and 2 skipped layer(s) above
```

A Trust warning counts as an advisory in the last line, so the run still passes (exit 0) unless you pass `--strict-trust`.

`okf-verify` checks three kinds of claim: a cited commit SHA, a code citation (`path:line @sha`) and an absolute file path. A cited commit SHA is looked up in each `--repo` folder and in each repository the bundle declares once in its `okf-base.yaml` under `okf_check.verify.repos` (each entry has a `path`: relative to the bundle, absolute, or starting with `~`; `--repo` adds to them, and a repository named twice is searched once). A declared path that is missing or is not a git repository is reported as UNRESOLVED with that reason; it does not change the exit code unless you pass `--strict`. An `okf-base.yaml` that cannot be read, is not valid YAML, or whose `okf_check.verify.repos` is not a list of `{path: <string>}` stops the run with one error line and exit 2. A code citation written `path:line @sha`, `path:first-last @sha` or `path:line at sha` (for example `` `src/a.py:10 @d084956` ``) is ONE claim: the commit is looked up as above, then the path is looked up in that commit's files. The path is repo-relative and may be only its end (`a.py` for `src/a.py`). It is CONFIRMED when the file exists at that commit, REFUTED when the commit is found and the file is not in it (the detail says the path part failed), and UNRESOLVED when the commit is in no searched repository or the end of the path matches more than one file. The line (or the end of the range) must also exist in that file at that commit: a line past the end is REFUTED and the detail gives the file's line count; line 0 is REFUTED (lines start at 1); an empty file has 0 lines; a reversed range such as `20-10` is read as the lines up to the larger number; a binary file or a symlink is UNRESOLVED because its lines cannot be checked; a line number of more than 9 digits is REFUTED as out of range. A drive-letter path with backslashes (`C:\x\y.py:3`), a URL or a version number is not a citation. A path with a space in a directory name (`my dir/w.py:1 @sha`) is read from the space on, so it is UNRESOLVED when that is the end of a longer file name, never REFUTED. Absolute file paths
in backticks or quotes (and paths that start with `~`) are checked on disk, but only inside the bundle or a `--repo` folder: a path elsewhere on the machine is UNRESOLVED, so a bundle you did not write cannot use the check to learn which files exist on your machine. Add `--host-paths` to look those up too. Relative paths are not read. In a shallow clone (the `actions/checkout` default), commits older than the clone are missing: use `fetch-depth: 0`.

`okf-export` is for a team that edits in an Obsidian-style vault, whose backlinks and graph count only `[[wikilinks]]`.
The vault stays the source; the export is a bundle `okf-check` can gate. Body `[[note]]`, `[[note|alias]]`,
`[[note#heading]]` and `[[#heading]]` become relative Markdown links, and each target and heading is checked.
Frontmatter and code are copied unchanged. A vault's `index.md` note becomes the folder note (`dir/index.md` to
`dir/dir.md`, the root one to `<vault folder>.md`), and an `index.md` listing is generated in every folder that holds
a note, with `okf_version` at the root; a rename onto an existing note stops the export. A vault `log.md` note becomes
the folder's log: its dated lines (`## 2026-05-22` headings or `- 2026-05-22: text` items, with their indented
continuation lines) are grouped by date, newest first, under the note's own `# title`. Every `## ` heading must be a
date, as spec 9 requires. Exit 1 lists each missing or ambiguous target, missing heading, malformed date, `## ` heading
that is not a date (with the lines left out under it), undated log line, log frontmatter and log with no dated entry as
`file:line` (the bundle is still written); exit 2 means nothing was written (`<out>` is not empty or is inside the
vault). A target is matched by its exact case (Obsidian ignores case). The vault is only read.

A near-miss actor is a wrongly written actor such as `Human:dana`. OKF reads it as an agent, so a person's review is
lost without any other symptom. `--strict-trust` fails on it.

Read the exit code, do not just test for zero:

| Exit | Meaning |
|---|---|
| 0 | No gate failed. Skipped layers and warnings print above the verdict: read them |
| 1 | L1: the bundle is not conformant OKF, or (with `--strict-trust`) a trust policy failure. Also: `--init-ignore` or `--init-house-rules` refused to overwrite an existing file |
| 2 | A gate could not run. Never treat as a pass |
| 3 | L2: house rules broken, or `index.md` miscounts |
| 4 | L3: stale concepts (with `--fail-stale`) |
| 5 | `--selftest` failed: a gate stopped firing |
| 6 | The bundle changed during the scan (with `--fail-on-change`) |
| 64 | Usage error: no bundle, an unknown flag, or a path that is not a folder |

**Leave paths out:** put globs in `<bundle>/.okfignore` (`archive/`, `.trash/`; a leading `**/` matches at any depth,
the root included). Every layer skips them and the run says how many files it excluded. The plugin never creates the
file by itself.

**okf-check's own options** live in one `okf_check:` block of `okf-base.yaml`. Every option is off until you set it.
`okflint` ignores the block (measured: the L2 warning count is the same with and without it), and both `okf-check` and
`okf-verify` check it against one schema, `plugin/config/okf-check-block.json`: a key it does not know, or a value of the
wrong shape, exits 2 and names the key, so a typo cannot switch an option off without a word. Known keys: `verify`
(read by `okf-verify`; `repos` is a list of `path:` entries), `deprecated_requires`, `require_owner`, `owners`,
`duplicates` and `edit_hook` (`true` turns the edit hook on for this bundle; a boolean, so a string such as `"on"`
is refused).

```yaml
okf_check:
  verify:
    repos:
      - path: .
  deprecated_requires: superseded_by
```

`deprecated_requires: superseded_by`: every `status: deprecated` note names its replacement in `superseded_by` (a
path, a `[[wikilink]]`, a markdown link, or a list of them, resolved from the bundle root or the note's folder). The
`Successor` line reports a missing `superseded_by`, a successor that is not found, a note that names itself, and a
successor that is deprecated too (one hop: point at the final successor). Each is a house-rule error, exit 1.

`require_owner: true`: every note has an owner, an actor as in OKF section 7 (`human:dana`, `team:docs`,
`tool/1.0`). A note's own `owner` key wins; otherwise `owners` gives folder defaults as globs (the `.okfignore`
syntax, without negation: a pattern that starts with `!` exits 2), and the last matching pattern wins. The `Owner` line reports a note with no owner and an owner that is not an
actor (house-rule errors, exit 1). Each L3 staleness and lifecycle finding ends with `owner <actor>`, in the text and
in `--json` `stale[]` and `lifecycle[]`.

```yaml
okf_check:
  require_owner: true
  owners:
    "decisions/**": team:architecture
    "decisions/security/**": human:dana
```

**Duplicates:** `okf-check <bundle> --duplicates` lists pairs of notes that may record the same knowledge: the same
title (case, punctuation and spacing ignored), the same `sources[].resource`, or descriptions whose words overlap at or
above `okf_check.duplicates.threshold` (default `1.0`, identical word sets; on our labelled sample, lower values
flagged templated series, not duplicates). Each pair shows the signal and score, both statuses, `generated.at` and
owners. Pairs linked by `superseded_by` are skipped. It is a report, not a gate: exit 0. It stops at
`okf_check.duplicates.time_limit` seconds (default 60) and says `CUT SHORT` if it did. `--json` gives `duplicates[]`.
`--duplicates-body` adds pairs whose bodies share 5-word shingles at or above `okf_check.duplicates.body_threshold`
(default `0.6`; on our labelled live sample, 0.3 flagged as many unrelated notes as duplicates), found with MinHash
and then checked exactly, within the same time limit.

**Environment variables** (all optional):

| Variable | Default | Effect |
|---|---|---|
| `OKF_L2_TIMEOUT` | 120 | Seconds before a hung `okflint` is cut off in L2 (exit 2, named). `0` or a non-number means the default. |
| `OKF_L2_ISOLATE_MAX` | 200 | When okflint crashes on a bundle of at most this many notes, L2 finds the crashing notes (one run each), names them and checks the rest. Larger bundles keep the plain "crashed" report. |
| `OKF_INSTALL_TIMEOUT` | 200 | Seconds before `--install-deps` stops the installer. |
| `OKF_AUTO_INSTALL` | off | `1` lets the session-start check run the install plan itself. |
| `OKF_SEARCH_BIN` | `okf` on PATH | The `okf` search binary the doc-reuse reminder uses to name the closest notes. |
| `OKF_DOC_DIRS_FILE` | `~/.config/okf/doc-dirs` | File of extra shell globs for locations the doc-reuse guard watches. |
| `OKF_EDIT_HOOK` | off | `1` turns the edit hook on for every bundle, without the `edit_hook` key. |
| `OKF_EDIT_HOOK_TIMEOUT` | `plugin/config/edit-hook.json` | Seconds the edit hook waits for the check before it gives up silently. |

`OKF_TODAY`, `OKF_PINNED_VERSIONS`, `OKF_BUNDLE_DIR` and `OKF_DUP_TIME_LIMIT` exist for tests and replays.

## Use in CI and git

The same `okf-check`, without Claude Code. Both doors need `python3` on the machine. `okflint` is optional: without it,
L2 is reported as SKIPPED (house rules not enforced), never as a pass.

**GitHub Actions** (the job takes `okf-check`'s exit code):

```yaml
jobs:
  okf:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ahmedibrahim085/okf-knowledge-gate@v0.9.23
        with:
          bundle: path/to/bundle
          strict-trust: 'true'    # optional, default 'false'
          fail-stale: 'false'     # optional, default 'false'
          require-house-rules: 'false'   # optional; 'true' fails the job (exit 3) when L2 was skipped
```

The job logs a `::warning::` when the bundle has 0 concepts and for every skipped layer, because both end in exit 0. GitHub's runners do not ship `okflint`, so L2 is skipped there unless an earlier step installs it; set `require-house-rules: 'true'` to make that a failure.

**pre-commit** (the hook passes no filenames. It checks the bundle named in `args`, and runs when a Markdown file is
staged):

```yaml
repos:
  - repo: https://github.com/ahmedibrahim085/okf-knowledge-gate
    rev: v0.9.23
    hooks:
      - id: okf-check
        args: [path/to/bundle, --strict-trust]
```

Your `args` replace the hook's default (`.`, which only works when the repository root is the bundle: a root `README.md` without frontmatter is a concept that fails L1). pre-commit 4.7.0 accepts the hook's `language: script`. Its source maps
that name to `unsupported_script`; it prints no removal notice today. The hook has been run end to end by pre-commit 4.7.0
on macOS: a clean bundle commits, a draft note with a human verifier is blocked, and a commit that stages no Markdown
file skips the hook.

## Tools it uses

The plugin wraps other people's tools and adds the gate engineering around them. It does not re-implement them. Each
tool below is one the code really calls, and a test checks that the table matches the repository.

| Tool | What it does for us | Needs | Source and licence |
|---|---|---|---|
| python3 | runs the validator, the trust layer and `okf-verify` (run on 3.9 on macOS and 3.12 on Debian 12) | Required | python.org, PSF |
| bash 3.2+ with awk, sed, find, stat, xargs | the gate itself (`okf-check`) | Required | your system |
| git | `okf-verify` looks up cited commits; the pre-commit hook runs in a git repo | Required for `okf-verify` | git-scm.com, GPL-2.0 |
| okf-skills validator | L1: the OKF v0.2 conformance check, with our local patch | Vendored in `plugin/vendor/` | [scaccogatto/okf-skills](https://github.com/scaccogatto/okf-skills), MIT |
| PyYAML 6.0.3 | reads note frontmatter (pure Python) | Vendored in `plugin/vendor/` | [pyyaml.org](https://pyyaml.org), MIT |
| okflint 0.5.0 | L2: house rules and index checks | Optional (needs Python 3.12+) | [mattdav/okflint](https://github.com/mattdav/okflint), MIT |
| uv | installs `okflint` when you run `okf-check --install-deps --yes` | Optional | [astral-sh/uv](https://github.com/astral-sh/uv), MIT or Apache-2.0 |
| pre-commit | runs the hook in your git workflow (tested with 4.7.0) | Optional | [pre-commit.com](https://pre-commit.com), MIT |
| GitHub Actions | runs the Action in CI | Optional | [github.com](https://github.com/features/actions) |
| jq | lets the doc-reuse hook read the tool call (the hook does nothing without it) | Optional | [jqlang.org](https://jqlang.org), MIT |
| Claude Code | the plugin form: hooks and the skill (the command line, Action and hook work without it) | Optional | [Anthropic](https://claude.com/claude-code) |

Used to build and release, not needed to run it: `gitleaks` (a secret scan before every public push), Pillow (renders
the demo GIF), Docker on a second machine (the Linux test runs) and the GitHub CLI.

### Pins and upstream pull requests

Two upstream tools are pinned by commit. A drift from a pin is reported as UNVERIFIED, never as a pass
(`okf-check --doctor`, `okf-check --selftest`).

- **L1 validator, from scaccogatto/okf-skills.** Vendored in `plugin/vendor/okf_validate.py` at commit
  `7ed3084267d050f198eea6cd9f67d5357e9ed047`: okf-skills 0.10.3 plus five fixes (MIT), and a patch of ours that bounds
  the size of a YAML document (alias expansion and one very long scalar). The five fixes are an open pull request,
  [scaccogatto/okf-skills#68](https://github.com/scaccogatto/okf-skills/pull/68). If #68 is never merged, this vendored
  copy stays as it is and keeps working. `plugin/vendor/VENDOR.md` lists what differs from upstream. When #68 merges, we
  replace the copy with upstream at the merge commit and re-apply our patch (or offer it upstream).
- **L2 house rules, from mattdav/okflint.** Version 0.5.0 plus a commit on the maintainer's fork (ahmedibrahim085/okflint) with the BOM, non-UTF-8 and impossible-date
  fixes, `c505b8405b9ef07396a81734c2bdfaa33c57aa25`, installed only when you ask (`okf-check --install-deps --yes`). The
  fixes are an open pull request, [mattdav/okflint#11](https://github.com/mattdav/okflint/pull/11). If #11 is never
  merged, the install keeps using that fork commit. `--latest` installs the newest PyPI okflint and prints a note that it
  "may lack the okflint#11 fixes". `--doctor` reports UNPATCHED if the fixes are missing.

The full behaviour contract, one row per scenario with its test, is
[`docs/spec.md`](docs/spec.md).

## Platforms

| Platform | Status |
|---|---|
| macOS | The 0.9.2 test suites passed here, on bash 3.2 and the BSD tools. The gate was built and measured on this platform. |
| Linux | Written for GNU coreutils, findutils and awk (gawk and mawk). The 0.9.2 suites passed on Debian 12 (aarch64, GNU coreutils 9.1, gawk 5.2.1, bash 5.2.15, non-root user) with `okflint` and pre-commit 4.7.0 installed in a Python 3.12 environment. 0 tests failed. 6 tests were skipped because they cannot apply there: no `claude` CLI, no installed plugin to compare, a case-sensitive filesystem, no lesson file as a fixture, and no Pillow to render the demo. Debian 12 ships Python 3.11, which cannot install `okflint`. An earlier release also passed on Alpine Linux with gawk and mawk (2026-10-14). |
| Windows | There is no native Windows support: the gate is a set of bash scripts. WSL (Windows Subsystem for Linux) is the only path, and nothing has been run under it: UNVERIFIED, as are the Action and the pre-commit hook on Windows. |
| Claude Code | The plugin form (hooks and the skill) needs Claude Code. The command line, the GitHub Action and the pre-commit hook do not. |

## Support and contributing

- **Questions and bug reports:** open an issue at
  [github.com/ahmedibrahim085/okf-knowledge-gate/issues](https://github.com/ahmedibrahim085/okf-knowledge-gate/issues).
  Do not put secrets or private paths in an issue. For a security problem, say so in the title and leave out exploit
  details; the maintainer replies with a private way to send them.
- **Pull requests are welcome.** A change starts with a failing test, and it is reviewed on two axes (standards and
  spec) before release. See [Develop and test](#develop-and-test).
- **What changed:** [`CHANGELOG.md`](CHANGELOG.md), a dated entry for every release.
- **Maintainer:** one person, [ahmedibrahim085](https://github.com/ahmedibrahim085).

## About this project

This is an independent, unofficial project. It is not affiliated with or endorsed by Google, the OKF maintainers, or
the authors of the tools it builds on.

What is ours: layer precedence in the exit codes, the selftest, change detection, L4 claim verification, the trust
layer, crash isolation (a note that crashes a checker is named and the rest are still checked), and the behaviour
probes. Upstream bug fixes we depend on are submitted as pull requests (see [Pins](#pins-and-upstream-pull-requests)).

## Develop and test

```bash
bash plugin/scripts/okf-check.test.sh     # the gate
bash plugin/scripts/okf-check-l3.test.sh  # the gate's L3 staleness layer (own file, runs beside the one above)
bash plugin/scripts/okf-test-lib.test.sh  # the helpers those two share, and OKF_TEST_TIMING=1 (seconds per section)
bash plugin/scripts/okf-verify.test.sh    # L4
bash plugin/scripts/symlinks.test.sh      # every file walker treats symlinks alike
bash plugin/scripts/edit-hook.test.sh     # the opt-in edit hook
bash plugin/scripts/scoped.test.sh        # okf-check --file (one note)
bash plugin/scripts/okf-export.test.sh    # vault export
bash plugin/scripts/plugin.test.sh        # packaging and install drift
bash tools/demo/demo.test.sh              # the README demo is a recording of real runs
plugin/scripts/okf-check --selftest
```

Everything is bash 3.2 compatible and runs with BSD or GNU awk. Tests are written first and must go red before the
fix. A change is reviewed on two axes (standards and spec) before it is released.

### Repository layout

| Path | Contents |
|---|---|
| `plugin/` | The installable plugin: scripts, hooks, skill, vendored validator, config |
| `plugin/scripts/` | `okf-check`, `okf-verify`, `okf-export`, the hooks, and their test suites (`*.test.sh`) |
| `plugin/vendor/` | The vendored validator and PyYAML, with `VENDOR.md` (source, pin, licence) |
| `docs/demo.gif`, `tools/demo/` | The README demo and the scripts that record and render it |
| `docs/comparison-2026-10-17.md` | The evidence behind the comparison claim in "Why use it" |
| `.github/` | Issue templates and the pull-request template |
| `CHANGELOG.md` | Dated history of every release |

## Release

1. Raise the version in `plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `VERSION` in
   `plugin/scripts/okf-check`. A test fails if they disagree. Then move the example pins (`okf-knowledge-gate@vx.y.z`
   and `rev: vx.y.z`) in this README, `plugin/skills/okf/SKILL.md` and `.pre-commit-hooks.yaml` to the new version
   (tests LT-37f and LT-41a).
2. Add a `## [x.y.z] - YYYY-MM-DD` section to [`CHANGELOG.md`](CHANGELOG.md).
3. Run the suites and `--selftest`, on macOS and on Linux: `tools/linux-gate.sh` streams the committed tree
   into a Debian container (settings in `tools/linux-gate.conf`; Docker context from `OKF_DOCKER_CONTEXT`).
4. Tag `vx.y.z` on the private release commit and push the tag there.
5. Publish to the public repository (`ahmedibrahim085/okf-knowledge-gate`). It holds one squashed commit per release,
   so do not push the private history. The examples above pin `vx.y.z`, so the tag must exist there:
   ```bash
   bash tools/export-public.sh "$EXPORT"            # allow-list copy; the scan must pass
   gitleaks detect --no-git --source "$EXPORT"
   git clone https://github.com/ahmedibrahim085/okf-knowledge-gate.git "$PUB"
   # replace the tree of "$PUB" with "$EXPORT" (keep .git), then, in "$PUB":
   git add -A && git commit -m "okf x.y.z: <summary>"
   git tag vx.y.z && git push origin HEAD:main vx.y.z
   ```
6. Publish the release notes from the changelog section, on the public repository:
   ```bash
   awk '/^## \[x.y.z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
     | gh release create vx.y.z -R ahmedibrahim085/okf-knowledge-gate --title "okf x.y.z" --notes-file -
   ```

## License

MIT, see [`LICENSE`](LICENSE). Third-party code keeps its own MIT licence: the vendored validator
(`plugin/vendor/LICENSE.okf-skills`) and PyYAML (`plugin/vendor/LICENSE.pyyaml`).
