# Changelog

All notable changes to the OKF Knowledge Gate plugin are documented in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/): the plugin is `0.x`, so the
minor number moves for new capability and the patch number for fixes and documentation.
Dates are ISO 8601. The entry for a version is also the body of its GitHub release.

## [Unreleased]

## [0.8.1] - 2026-10-16
### Documentation
- README states that the project is independent and unofficial, and not affiliated with Google,
  the OKF maintainers, or the authors of the tools it builds on.

## [0.8.0] - 2026-10-15

### Added
- **Per-note isolation in L2.** When okflint crashes on a bundle of at most `OKF_L2_ISOLATE_MAX`
  notes (default 200), L2 runs it note by note (about 0.2 s each), names the notes it crashes on,
  and checks the rest. The run exits 2 (or 3 when the checked notes fail): a crashed note is never a pass. Larger bundles keep the
  plain report. The whole rescue shares one `OKF_L2_TIMEOUT` budget (#17).

## [0.7.2] - 2026-10-15

### Fixed
- A `.okfignore` that excludes no file no longer changes the verdict. With every note behind a
  symlinked directory it turned exit 4 into exit 2 and said "excludes every note" (#15).
- A leading `**/` in `.okfignore` also matches at the bundle root, with or without a leading `/` (#16).
- Excluding only non-note files (for example `*.json`) no longer reports "excludes every note".

### Added
- A test that the status vocabulary in `okf-base.yaml.template` and in `l3-lib.sh` stay equal (#18).
- README and SKILL.md document the user-facing environment variables (#19).

## [0.7.1] - 2026-10-15

### Fixed
- A hung `okflint` no longer stalls L2 for as long as it hangs. The call is cut off after
  `OKF_L2_TIMEOUT` seconds (default 120) and the report says it timed out (#10).
- The doc-reuse guard leaves no orphan child process when it kills a hung search binary (#9).
- The spec-traceability test (D-1) runs in the public tree too: it finds the spec at
  `docs/spec.md` (#11).

### Added
- Test fixtures captured from the real `okf search` output, including a two-digit score (#12).
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

[0.5.7]: https://github.com/ahmedibrahim085/okf-knowledge-gate/releases/tag/v0.5.7
