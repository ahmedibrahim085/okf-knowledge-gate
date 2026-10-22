# Changelog

All notable changes to the OKF Knowledge Gate plugin are documented in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/): the plugin is `0.x`, so the
minor number moves for new capability and the patch number for fixes and documentation.
Dates are ISO 8601. The entry for a version is also the body of its GitHub release.

## [Unreleased]

## [0.9.44] - 2026-10-22

OKF Knowledge Gate 0.9.44 closes the last silent reads: a note too large to read and a note that starts with a byte order mark are judged like any other note, and the test suites can no longer pass or fail by a race.

### Fixed
- **A note too large to read fails Trust, `--file` and derived L3.** Trust printed PASS and lost the trust findings of a note whose frontmatter trips the loader cap; it now names the note as too large to read and not checked, and the layer fails. `okf-check --file` and derived L3 do the same.
- **A note that starts with a byte order mark is read like any other.** Derived L3 printed nothing for its stale sources, the L2 index left it out of the declared count, and `okf-verify` reported a false "unclosed code fence".
- **The test suites have no `producer | grep -q` race.** Under `set -o pipefail`, `grep -q` can stop reading before the producer finishes, and the pipeline then fails although the pattern matched. Every such line now reads from a here-string, and `tools/check-tests.sh` refuses a new one.

## [0.9.43] - 2026-10-22

OKF Knowledge Gate 0.9.43 makes every stop and every unreadable input a named verdict: no empty `--json` document, no note that is too large to read reported as missing an owner, and the same answer for an unreadable folder on every Python. It also turns the public CI green again.

### Fixed
- **Every stop of `okf-check --duplicates --json` prints a JSON document** with the reason (and the reason on stderr): a manifest that does not parse, an `.okfignore` that cannot be applied, a failed duplicates helper, a missing `python3`. The main `--json`, `--conserve --json` and `--fingerprint --json` do the same on the shared stops.
- **A note too large to read is named, never read as a pass.** Owner and Successor say the note was too large to read and was not checked (layer FAIL) instead of "not valid YAML" or "no deprecated notes"; `--duplicates` lists it as not compared.
- **An unreadable folder gives the same verdict on every Python.** From Python 3.14, `pathlib` stopped raising on a permission error, so `okf-verify` reported an unreadable path as not found, or as REFUTED, and `okf-export` called an unreadable vault "not a folder". Both now name the unreadable path; `okf-check --file` stops at an unreadable folder like the full run; a bundle below an unreadable folder is reported as not readable, and an output folder nobody may enter as "cannot write".
- **The public CI is green.** The linear-cost test of the heading reader compared against a fixed 0.5 s, which a hosted runner exceeds; it now bounds how the cost grows with the input.

### Changed
- `okf-check --facts --json` and `--doctor --json` print their text report (they printed nothing before); `--file --json` stays refused.
- The first line of the macOS gate log names the Python it ran under.

## [0.9.42] - 2026-10-22

OKF Knowledge Gate 0.9.42 closes the review findings of `okf-export` and its public-export scan: every file the export leaves out is named, hidden content cannot ship through a hard link, and the heading reader no longer emits an anchor CommonMark lacks.

### Fixed
- **`okf-export` names every file it leaves out.** A symlinked folder, a broken link, a link loop, a folder that cannot be listed or entered and a file that cannot be examined are problem lines with exit 1, no longer a silent skip. An absolute symlink is reported as "an absolute link": the path of the machine that ran the export never appears in the report.
- **A hard link to a hidden file no longer ships its content.** A visible file that has the same identity as a file under a dot folder or a dot name (`.git`, `.obsidian`, `.env`) is refused and named, and a file with a second name is refused while a folder cannot be listed to rule such a link out. A hard link to a file outside the vault is a documented limit.
- **Notes whose names differ only in Unicode normalisation no longer overwrite each other.** `café` in NFC and in NFD are one file on macOS (APFS); the pair is decided from the names before anything is written, on every disk, and the export stops with exit 2 naming both notes.
- **The heading reader emits no anchor CommonMark lacks.** A lone `#`, indented code after a list item in a block quote and a tab in a block-quote prefix no longer produce a heading; a heading the reader cannot decide stays a loud "missing heading". The slug follows github-slugger for marks, circled letters and tabs.
- **A code span inside a wikilink alias converts** (`[[b|`code`]]` becomes a link with the code text), a `\|` after the alias separator stays as written, and one line of a million `>` ends in under a second instead of 6 s. The README and the plugin text state the limits that remain (no setext heading inside a quote, no heading after a tab in a quote prefix).
- **The public-export scan is linear in the URLs of a line.** A 160 KB line of repeated ticket numbers behind a URL took 16 s; it takes 0.1 s.

### Changed
- A vault that holds the same note name in NFC and in NFD is now refused on Linux too (it exported before, and then lost a note when the folder was copied to a Mac).

## [0.9.41] - 2026-10-22

OKF Knowledge Gate 0.9.41 closes the review findings of the checks and the vendored validator: citations of files with spaces, a time limit for the Python layers, notes with odd names, hidden characters in `human:`, and a symlink target spelled in another case.

### Fixed
- **`okf-verify` no longer cuts an unpinned citation at a space.** `my w.py:3` beside `w.py` was judged as `w.py` (a false CONFIRMED, REFUTED or UNRESOLVED). Only a line break is read as a space now, bare names that differ only in case are told apart, the case of a cited path is judged below the bundle's own spelling, and the walk of the repository is bounded. Its test no longer needs a writable folder above the bundle.
- **The vendored validator is linear on duplicate keys.** A mapping of 60,000 keys (a 0.6 MB note) took 40 s or more; it takes 0.07 s. Its log check no longer reads `##` lines inside code fences.
- **The Python layers have a time limit.** Trust, Successor, Owner, Size, derived L3 and `--duplicates` share one budget, `OKF_LAYER_TIMEOUT` (default 300 s, smallest value 2 s, anything lower exits 64). A layer past it is `COULD NOT RUN` naming the limit, exit 2, and `--json` carries `layers_not_run`; `--duplicates --json` prints a JSON document with the reason; the scoped `--file` check is bounded too.
- **A note whose name is not UTF-8 is no longer dropped.** Size, Facts, Duplicates, derived L3, Conserve and the L2 graph now see it, the owner default of its folder applies, and `okf-verify` no longer crashes on it with a `.okfignore` or `generated` key.
- **Names never reach a terminal raw.** A control character, an ESC byte, a byte that is not UTF-8 or a bidi override (U+202E and the other bidi controls) in a note name is printed as `\xNN` in every text mode, in `--fingerprint` and in `okf-verify`.
- **Hidden characters in `human:` are caught.** A zero-width character, a soft hyphen, a combining mark, a line or paragraph separator, a no-break or ideographic space, a hangul filler or a bidi control inside `human:` or `process:` no longer passes `--strict-trust`. A switched-on edit hook that cannot run now says so.
- **L3 derived judges the target of a symlink.** A source that is a symlink whose target is spelled in another case was measured on macOS and unmeasurable on Linux; the target is now case-exact on both.

### Changed
- `okf-check --json`: a note name that holds a control character is spelled `\xNN` (a literal backslash and `x`), as in the text report, instead of the JSON escape `\u00NN`.
- `okf-check` and `okf-verify` print a name with a control character in the same spelling in every mode.

## [0.9.40] - 2026-10-22

OKF Knowledge Gate 0.9.40 closes the hidden-folder exposure of `okf-export` and turns the public repository's CI green again: it was red on the 0.9.38 and 0.9.39 pushes.

### Fixed
- **`okf-export` no longer copies a dot folder through a symlink.** A note whose symlink resolves to a dot file or folder of the vault (`.obsidian`, `.git`, any `.name`) is skipped and named in the report like a link that leaves the vault, and the run exits 1. Before, `peek.md` pointing to `.obsidian/workspace.md` shipped the settings file into the bundle with exit 0. A link to a visible file inside the vault still exports; a note that links to the skipped file reports "missing target".
- **`okf-check` lists every note it counts, under a UTF-8 locale too.** A note whose name holds a byte that is not UTF-8 was counted ("3 concept(s) need attention", "3 error(s)") but missing from the list below the count and from `--json` (`stale[]`, `errors[]`). Under a UTF-8 locale, which is the default of GitHub's runners, GNU grep read such a line as binary and dropped it while `grep -c` still counted it. The L3 and L1 listings now read their input as text (`grep -a`). This was the public CI failure S30-CF-L1.
- **Test fixes for the CI.** S30-CF-N2b skips without `okflint` instead of failing; S25-DU-E3 allows the machine's own speed on top of its 6 s slack (it failed by 0.4 s on a loaded runner); R-10b reads the help from a file, not through a pipe.

### Changed
- The Linux release gate runs the suites under `OKF_LINUX_LANG` of `tools/linux-gate.conf` (`C.UTF-8`, the runner's locale), so a failure that shows only under a UTF-8 locale shows in the private gate first.
- README: the Release section says its steps run in the private repository, and a public clone runs `.github/ci/run-suites.sh`.

## [0.9.39] - 2026-10-20

OKF Knowledge Gate 0.9.39 closes the leftovers of the overnight review: the public-export scan, `okf-export` anchors and links, and the `okf-check` time limit and path rules.

### Fixed
- **The public-export scan is linear on long lists of ticket numbers.** A 160 KB line of repeated ticket numbers hit Python's recursion limit after 55 s; it takes 0.3 s. A submodule (a gitlink) is refused and its path is named as written, where `tar` copied its working tree whole. An allow-file error now names the check that failed (unknown keyword, argument count, missing reason) and shows a bad value first.
- **A `binary` pin in `tools/export-public.allow` can accept scan classes for that one file** (`accept=home-path,e-mail,private-name,commit-id,GH-N,#NN,private-repo-link`); an unknown class is an allow-file error and the acceptance covers no other file.
- **`okf-export` keeps links to repeated headings.** Repeated headings get GitHub's numbered anchors (`dup`, `dup-1`, and the next free number when a heading is literally `dup-1`); heading anchors are Unicode NFC, so a heading typed in NFD matches an NFC link and the reverse.
- **`okf-export` no longer copies a file that leaves the vault.** A symlink (or a file under a symlinked folder) whose target is outside the vault is skipped and named in the problems.
- **`okf-export` reads block quotes.** ATX headings, fences and indented code inside a quote are read as outside it, and a quote nested more than 100 levels stops with a named problem instead of a Python traceback. A setext heading (`===` or `---` underline) inside a block quote is not recognised: a link to one fails with "missing heading" and is never rewritten to an anchor that CommonMark lacks.
- **`okf-export` keeps code spans in titles**: a title with a backtick span and a closing bracket is escaped outside the span only, and the index link stays one link.
- **`okf-export` matches names by case and Unicode form** (the Obsidian rule `okf-check` already used): two names that differ only in normalisation are reported as ambiguous in an escaped, readable form.
- **`okf-check` stops a validator that does not finish.** Every L1 validator run is limited by `OKF_L1_TIMEOUT` (default 120 s; zero or a non-number falls back to the default). When it fires, L1 prints "COULD NOT RUN" with the limit and exits 2, where an 840 KB note once gave exit 0 and PASS. One total budget covers the per-note probes. A validator that stops itself with a signal is reported as a crash, not as a time-out.
- **`okf-check --help` prints the whole header** and lists exit codes 64, 130 and 143, checked against the README table.
- **`okf-check` reads the status list from one place**, `STATUS_VALUES` of the vendored validator. A missing, unreadable, duplicated or non-list `STATUS_VALUES` is an error that names it (exit 2), and no longer an empty list that rejects every status.
- **L3 judges the case of a cited source below the bundle only**, so a source typed as `SRC.txt` for `src.txt` is "not a local file", while `okf-check .` with a `../x.txt` source and a bundle path typed in another case are measured as before.
- **CI pins `actions/checkout` to v7.0.1 (node24)**, and a test fails when the workflow and `tools/export-public.allow` disagree on the pin.

## [0.9.38] - 2026-10-20

OKF Knowledge Gate 0.9.38 closes the false passes found by the overnight review of the open backlog: the public-export scan, `okf-verify` results, and `okf-check` link and warning handling.

### Fixed
- **The public-export scan no longer lets private text through.** `tools/export-public.sh` refuses links to any page of the private repository except a compare link, `GH-` references and full-width `＃` numbers, and text hidden in encoded forms (HTML entities, percent encoding, full-width or zero-width characters, UTF-16 and UTF-32 text), in file and folder names, or behind a binary file name or header. It copies only tracked files and refuses when it cannot tell which files those are; a read-only destination and any `tar` failure now fail the export; a symlink (also to a folder) is a finding. A binary file is allowed only when `tools/export-public.allow` pins its path and sha256; the one tracked binary, `docs/demo.gif`, is pinned. The checks are one table (`python3 tools/export-refs.py matrix`), each cell measured, and the tests are generated from it. Three scans that were quadratic in the line length are linear now.
- **`tools/publish-public.sh` checks what was scanned.** The export marker carries a digest of the exported tree and publish recomputes it, so a file added or edited after the scan is refused. The digest catches edits after the export, not a marker written by hand.
- **`okf-verify` reads zero-padded line numbers.** `a.py:0000000003` is line 3, in every place a line number is read (also `--since` and the moved-line detail).
- **`okf-verify --repo` with a relative path finds citations written with an absolute path**, and a bundle or `--repo` folder that cannot be read gives one clear line instead of a traceback (exit 2 for a bundle; an unreadable `--repo` is listed under `repos_unreadable` in `--json`).
- **`okf-verify` is faster on bundles with many citations.** It remembers the answers of its git calls for the run: 100 citations took 717 git processes and now take 16.
- **`okf-check` resolves wikilinks and `superseded_by` successors by one rule on every disk.** The rule is the Obsidian one that `okf-export` already used: case is ignored, the Unicode form (NFC or NFD) is ignored, an exact name wins, and two names that differ only by case are ambiguous and not resolved. Before, macOS accepted what Linux refused (`[[New]]` for `new.md`). Behaviour change: on Linux a link in another case now resolves; on macOS a link that only the disk's own folding accepted (`[[STRASSE]]` for `straße.md`) does not.
- **`okf-check` counts L1 warnings in the advisory total** and prints the share of each layer: `(advisories: L1 9 + L2 24)`. A finding that both layers report counts once per layer.
- **`okf-check` explains a too-shallow `wikilink_root`** (a hint in the text output and `l2_hint` in `--json`), and a key written twice in `okf_check`, or a second `okf_check:` block, exits 2 naming the nested key.
- **A very long `.okfignore` line is read in linear time.** A 640 KB line of spaces took over a minute; it takes about half a second. Only space, tab, CR, VT and FF are trimmed, so a trailing no-break or ideographic space is now part of the pattern.

### Changed
- README: the platform rows state the release they were measured on (0.9.37, `tools/macos-gate.sh` and `tools/linux-gate.sh`), a warning that `okf_check.verify.repos` from an untrusted pull request is trusted input for `okf-verify`, the wikilink rule above, and how to re-pin a re-recorded `docs/demo.gif` in Release step 5.

## [0.9.37] - 2026-10-20

OKF Knowledge Gate 0.9.37 finishes the CommonMark list work in `okf-export` and corrects one step of the release recipe.

### Fixed
- **`okf-export` reads the blocks inside a list item the way CommonMark does.** One block reader now covers headings, links and code in list items: a setext heading inside an item, an ATX heading on the list marker's line or indented four or more spaces in a nested item, a fenced block on the marker's line, an HTML block and a link reference definition inside an item. A link to such a heading resolves instead of giving a false `missing heading` line, and a `# no` line inside a code fence is no longer read as a heading. Against the CommonMark reference parser the 44-case check dropped from 5 differences to 0; the export of this repository's `.okf`, `docs` and `.scratch` folders is byte for byte the same as before. Headings inside block quotes are still not found (a separate kind of container, stated in the code). The cost of reading a line stays in proportion to its length, also for a 160 KB line of nested markers, and a test pins it.
- **`okf-export` handles Windows line endings in list items.** A file with CRLF line ends gives the same report as the same file with LF.

### Changed
- README, Release step 7: `claude plugin update okf@ahmedmaged-okf` does bring the installed plugin to a newer working copy (observed 0.9.35 to 0.9.36: "updated ... Restart to apply changes"); it only says there is nothing to update when the working copy equals the installed version.

## [0.9.36] - 2026-10-20

OKF Knowledge Gate 0.9.36 makes `okf-export` follow CommonMark for lists, and closes the findings of the first macOS run of 0.9.35 and the open items of our own release tooling.

### Fixed
- **`okf-export` finds headings after a list the way CommonMark does.** A paragraph indented one to three spaces after a list and a blank line is no longer read as list content, so a setext heading in it (`Para` over `---`) resolves instead of giving a false `missing heading` line (exit 1, the bundle was still written). The exporter now keeps a stack of the open list items' content indents: a marker, or a line after a blank line, closes only the items it is indented below; a margin line continues an item only under an open paragraph (a lazy continuation), so a thematic break, a fence, an empty item or indented code inside an item ends the list as it should. Headings and the code-block rules for link rewriting come from the same tracker, so a link inside an item's indented code or fence stays as written. Checked against a CommonMark reference implementation on 81 cases (0 mismatches on the exporter's own set), and the export of the repository's own bundle is byte-identical to 0.9.35. Known gaps, listed on the ticket: a setext heading inside a list item, a heading on the marker line (`- # H`), an ATX heading more than three spaces into an item, a heading inside a block quote, a fence on the marker line, and an HTML block or a link reference definition inside an item.
- **`tools/linux-gate.sh` validates every value that reaches Docker or the container script.** A double quote in `tools/linux-gate.conf` broke the inner script, and a value such as `--privileged` as the image name became a Docker option. The image, memory, process and CPU limits, the Docker context, the Python, uv and pre-commit versions, the okflint pin, the suite list and the suite timeout are now checked against strict patterns; a bad value stops the gate with exit 2 and names the key before Docker runs, and control characters in the rejected value are written escaped.
- **`plugin.test.sh` P-10 reads `claude plugin list --json`.** It no longer guesses the installed version from the cache folder: it reads the `okf` entry (version, enabled, scope), compares the version with the source tree and compares the installed copy's files with the source plugin folder. A stale version, a disabled plugin, a copy with edited files, a missing install path and another project's install each fail with a message that names the fix. With no `claude` command, or output that is not JSON, the old cache-folder check runs as before. A hung `claude` is stopped at a time limit, with its child processes.
- **Two macOS-only test fragilities from the first macOS run of 0.9.35.** The `edit-hook` tests SH-3 and SH-13 assumed a short temp folder (the macOS one is about 100 characters long, which makes the hook print its short hint); they run in a short folder now and a new case pins the short form on a long path. The `duplicates` test S25-DU-E3 assumed that reading 1,200 notes takes less than the 2 s limit; it times the run first, skips with a printed reason when the phases cannot be told apart, and a new test, S25-DU-E4, cuts the scan with a fake clock at an exact count (140,000 of 148,992 checks), so a bucket loop that ignores the limit fails on every machine. The products were correct.

### Added
- **A CI job on the self-hosted runner** (private repository only): it runs the same suites as the hosted jobs on the machine that runs the Debian gate, only for branches of this repository, with the checkout pinned to a commit and without stored credentials, a time limit, and a last step that always empties the workspace and temp folder because the runner is not ephemeral. `run-suites.sh` refuses to run as root, because the permission tests need a normal user.

### Changed
- README: how to install the optional okf-memory binary by hand, with the sha256 values of v0.6.2 (the plugin still never downloads it; vendoring was decided against: 30 MB of unsigned binaries in the history, and both features that use it are opt-in); the release steps say that the plugin is read from the working copy, so a release needs a fast-forward of that copy and a restart, not an uninstall and install.

## [0.9.35] - 2026-10-19

OKF Knowledge Gate 0.9.35 clears the backlog's "later" list: an optional okf-memory layer finds orphan notes and broken concept links, the duplicates report stops comparing stub bodies and says where it was cut short, `.okfignore` reaches symlinked notes, `okf-export` matches targets as Obsidian does, and settings that used to switch something off without a word are now refused or fall back to their default.

### Added
- **The optional okf-memory layer, L2 graph.** With `okf_check: {graph: true}` in `okf-base.yaml` (or `OKF_MEMORY_BIN` set), `okf-check` runs [okf-memory](https://github.com/okf-memory/okf-agent-memory)'s read-only `okf validate --json` on the frozen copy, under `OKF_GRAPH_TIMEOUT` (default 60 s), and lists orphan notes and broken concept links as advisories (`L2 graph  WARN`; `--json` `l2_graph`). The exit code does not change. Opted in without okf-memory, the line says SKIPPED and what is unchecked; a different tool also called `okf` is not mistaken for it; a hung or unreadable run is COULD NOT RUN, never a pass. `--doctor` names it and `--selftest` probes it when it is installed. The plugin never installs or downloads it.
- **`--version` on `okf-export` and `okf-verify`**, from `plugin.json`, so the wrapper test compares real versions.
- **`--selftest` probes the Config check and the lookalike rule** (below).
- **`--json` `symlinked_folders`** lists the symlinked folders the run did not enter (present only when there is one).

### Changed
- **Stub bodies are not body duplicates.** `--duplicates-body` skips a body under 5 words (one shingle: every `TODO` stub scored 1.00 against every other) and counts those notes (`--json` `body_short`); title, description and sources still compare.
- **`--duplicates` says where it was cut short.** The time limit now covers reading the notes and is checked inside one crowded LSH bucket (1,200 notes sharing one body: 17.7 s uncut, now 4 s with a 2 s limit). A cut names its pass: while reading (`N of M notes read`), the pair comparison, or the body comparison (`bodies of N of M notes hashed`); `--json` gains `cut_in`, `notes_read` and `notes_total`.
- **`.okfignore` reaches a symlinked note**: an alias whose target is ignored is ignored by every walker (an alias of a kept note is still checked), and a symlinked folder that `.okfignore` excludes is no longer named on the `symlinks` line.
- **`okf-export` matches targets as Obsidian does**: an exact match first, then ignoring case (`[[Alpha]]` finds `alpha.md`); two files that differ only in case are an ambiguous target. Setext headings (a line underlined with `===` or `---`) are headings a `[[note#heading]]` link can name. Only `\n` ends a line, so a form feed no longer shifts the line numbers of the report, and an `<out>` that is a file is named as one.
- **The Debian release gate runs its suites four at a time** through the tested tree's `.github/ci/run-suites.sh`, can reuse a provisioned image (`OKF_LINUX_CACHE=1`, the conf default, tagged `okf-linux-gate:<hash of every input>`), and trusts a CA bundle given in `OKF_LINUX_CA_FILE`, for a network whose proxy re-signs TLS.

### Fixed
- **Edit hook values that switched the hook off without a word.** `OKF_EDIT_HOOK_TIMEOUT=nan` passed the cap (`min(nan, 4.5)` is nan) and `0` or `-1` fired the box at once; a value that is not a positive number now uses the default. An unquoted `edit_hook: yes` (YAML 1.1 reads it as true, other readers as a word) is refused for every true/false option, by both tools. A long first finding no longer pushes the `(+N more: ...)` hint off the one line Claude reads.
- **A `verified.by` that only looks like `human:`** (Cyrillic or Greek lookalike letters, a lookalike colon) is a Trust warning that says so, and fails `--strict-trust`; nothing new is denied.
- **The Config line names the real fault**: a missing `okf-verify` and a config check that exits without a message no longer read as a fault of `okf-base.yaml` or an empty reason.

## [0.9.34] - 2026-10-19

OKF Knowledge Gate 0.9.34 closes the open public requests: `okf-verify` checks line citations into living documents (with content anchors and a MOVED verdict) and can confirm a commit that exists only on the forge; `okf-check` gains declared facts and a conservation check; and the CI runner runs suites in parallel.

### Added
- **`okf-verify` checks line citations into living documents** (okf-knowledge-gate#14, all three slices). `decision-12.md:94`, `spec.md:40-42` and `decision-12:94` (by unique note name) are claims of a new kind, `line`: CONFIRMED when the file has that line, REFUTED when the file was found and is shorter, UNRESOLVED when it is missing, ambiguous or outside the bundle and the searched repositories (never looked up there). The short form counts only when a note of that name exists, so `Step:2` and `10:30` stay prose. A note with no checkable claim reports how many strings look like citations but match no checkable form (`--json` `unrecognized_citations`).
- **Content anchors and the MOVED verdict.** `decision-12.md:94 "shadow, canary"`: the quoted text on the cited lines is CONFIRMED; on other lines of the file the citation is MOVED with the new line (`--json` `moved_to`), which fails the run like REFUTED; nowhere, REFUTED. A citation pinned to a commit checks its anchor at that commit and is never MOVED.
- **`okf-verify --since <ref>`** compares each unanchored line citation into a file changed since the ref with the file at the ref: cited text that moved is MOVED with the new line, text changed in place keeps its verdict with a warning. **`okf_check.verify.generated`** lists notes a script regenerates; a line citation into one without an anchor warns.

- **Declared facts, `okf_check.facts`** (okf-knowledge-gate#15, both slices). The bundle declares a fact's value once, with the regular expressions that find where it is stated (group 1 is the value) and optionally its source note. A note that states another value is a `FACT-CONFLICT`, a house-rule error (exit 1) naming the note, the line, the fact and both values; `--json` `facts[]` lists every statement. `okf-check <bundle> --facts [NAME]` is the dry run: every occurrence with its line, the differing ones marked, exit 0. The shared schema gains `required` keys, `{min: N}` for lists and a `regex` type, so a bad pattern is exit 2 in both tools. `--selftest` has a Facts probe.

- **The conservation check, `okf-check <bundle> --conserve <ref>`** (okf-knowledge-gate#16, all three slices). Every line removed since the ref must reappear: MOVED when it is anywhere in the bundle now, CHANGED when a line added at the same place replaces it (shown old -> new, paired by position, so compression shows as LOST), DECLARED when the deletion was declared (`--deleted FILE` or an `OKF-Deleted: <note>` trailer), LOST otherwise with its note and old line. Blank, whitespace-only, markup-only and frontmatter lines are not counted. Advisory (exit 0); `--fail-lost` exits 1 on a LOST line; `--json` gives every entry.

- **`okf-verify --remote`: commits that exist only on the forge** (okf-knowledge-gate#6, first comment). A SHA no searched clone holds is asked of the clone's `origin` on GitHub or GitLab, read-only (the clone is never fetched into). Found there it is CONFIRMED, and the detail gives the title and date and says the local clone is behind; otherwise it stays UNRESOLVED and says whether the forge lacked it, the request failed or the origin is no known forge. Opt-in with the flag or `okf_check.verify.remote: true`; `GITHUB_TOKEN`/`GH_TOKEN` and `GITLAB_TOKEN` each go only to their own forge.


### Changed
- **The CI suite runner runs suites in parallel** (gate speed). `.github/ci/run-suites.sh` runs `OKF_SUITE_JOBS` suites at a time (default: the CPU count, at most 4), the two heavy halves of the okf-check tests first, and still reports in suite-list order by the gates' verdict rule. Each suite already has its own temporary folder, so they share no state; a freed slot is refilled at once and the largest suites start first. Measured on a 4-CPU Linux machine (Ubuntu 24.04, same tree): the public suite list took 1,268 s one at a time and 581 s with 4 jobs, the private list 581 s too, which is the length of its longest suite (`okf-check.test.sh`, 574 s): the run now ends when that suite does.

**Review of the 0.9.34 work (three reviewers, one per feature): three blockers and the should-fix findings fixed before release.** Line citations: a symlink inside the bundle that points outside it is judged by its target and not read (an anchor had made the verdict an oracle on the target's text); `--since` compares only a citation the note already had at the ref; a bundle note and a repository document that both match are ambiguous; a wrapped anchor is found; two anchors on one citation are two claims; the hint for citation-shaped text no longer backtracks for minutes on a long line. `--remote`: a GitLab token goes only to gitlab.com or a host named in `OKF_GITLAB_HOSTS`, matched exactly; redirects are not followed; an answer that does not name the commit, or a broken one, is a failed lookup; a host that failed is not asked again. Facts: the patterns run under a time limit; brackets are not part of a value; two patterns on the same text count once; CRLF notes read as LF. Conservation: names with spaces or accents, a removed line starting with `-- ` and the user's diff settings no longer hide removed lines; only notes are compared; `OKF-Deleted` counts only as a trailer. The CI runner writes no bytecode and fails a suite whose result is missing.

**Upgrade note:** a bundle that already writes `name.md:N` citations now has them checked. One that points past the end of its file is REFUTED and makes `okf-verify` exit 1 where 0.9.33 ignored it. Check with `okf-verify <bundle>` before you update a CI pin.

## [0.9.33] - 2026-10-19

OKF Knowledge Gate 0.9.33 adds CI on GitHub's runner for the public repository, finishes the body-size budget (exclude globs and per-note sizes) and stops `okf-verify` from blaming a history rewrite it cannot prove.

### Added
- **CI on GitHub's runner, in the public repository.** `.github/workflows/ci.yml` runs on every pull request and every push to `main` of the public repository (`.github/` is exported whole). In a private repository its jobs are skipped, because Actions minutes are billed there; a skipped job is not a pass. It runs the release suites and `--selftest` on Ubuntu 24.04 as a non-root user, with the pinned `okflint` and pre-commit installed in a Python 3.12 environment, once with gawk and once with mawk (the README claims both; the release gate runs gawk only). A second job runs the repository's own Action (`uses: ./`) and checks that it passes a valid bundle and fails a bundle with an L1 error and a `require-house-rules` run without `okflint`. The suite runner, `.github/ci/run-suites.sh`, judges each suite by the release gates' own rule (exit 0 and a final summary of at least 1 passed and 0 failed). It reads the suite list from `tools/linux-gate.conf` when the tree has one and otherwise runs every `*.test.sh`. `tools/ci-workflow.test.sh` fails if the runner's copy of that rule, or the workflow's default versions, drift from `tools/lib/suite-verdict.sh` and `tools/linux-gate.conf`.
- **`okf_check.size.exclude` and `--json` `sizes[]`, the rest of the body-size budget** (okf-knowledge-gate#17). `exclude` is a list of globs in the `.okfignore` syntax whose notes the size rule does not measure (generated notes, for example); the globs go through the same matcher as `.okfignore` and `owners`, a pattern that starts with `!` is refused (exit 2, in `okf-check` and `okf-verify --check-config`), and the Size line counts the notes it left out. With the option on, `--json` `sizes[]` gives every measured note its body size and both limits, so CI can show the trend before a note breaks. Without `okf_check.size` the output is unchanged; with it, `--json` differs from 0.9.32 only by the new `sizes` key. The schema gains `{item_no_prefix: "!"}` for list items, as map keys already had `key_no_prefix`; spaces around a pattern are dropped, as `.okfignore` drops them, and a pattern holding a tab or a line break is refused (exit 2).

### Changed
- **The README's `okf-verify` paragraph is a short summary now; the full rules moved to the skill's reference.** The paragraph had grown to about 600 words of edge cases in one block. The README keeps the three kinds of claim, the `--host-paths` boundary and the shallow-clone advice, and links `plugin/skills/okf/references/verify-and-install.md`, which now holds every rule (declared repositories, the verdict for each citation case as a table, paths that contain a space, what is not a citation). The reference ships with the plugin, so an agent reading the skill gets the same rules. LT-36j fails if the link, the heading or a rule goes missing. No behaviour changed.
- **`okf-verify` no longer calls a missing SHA "likely a history rewrite" just because a commit with the same subject exists** (okf-knowledge-gate#6, second comment). In the reported cases the commit lived in a repository that was not searched, and a short subject matches unrelated commits. The search matches the quoted text anywhere in a commit message, so the detail now says that and names three explanations: a rewritten history, a repository that was not searched, or an unrelated match. It lists the repositories searched and any that could not be queried. The verdict stays UNRESOLVED.

### Fixed
- **`plugin.test.sh` Z-2 no longer fails after `okf-export.test.sh` has run.** That suite loads `okf-export` through Python, which writes `plugin/scripts/__pycache__/`; Z-2 then reported the `.pyc` file as a dead file that "ships to every install". `__pycache__` never ships (`.gitignore`, and the export excludes it), so Z-2 now leaves it out. A real unreferenced script is still reported. Found because the public tree runs its suites in name order, where `okf-export.test.sh` comes before `plugin.test.sh`.
- **`plugin.test.sh` no longer fails LT-36b on a machine without `okflint`.** The README sample shows the L2 line a machine with `okflint` prints (`SKIPPED — no okf-base.yaml in notes`); without `okflint` the run prints `okflint not installed` there, so the line-by-line compare failed although the README was right. Every other sample line is still compared; the L2 line is compared only when `okflint` is on PATH, and otherwise is reported as a SKIP (UNVERIFIED), never as a pass. A failure now prints the missing lines instead of the first two lines of a Python traceback.

## [0.9.32] - 2026-10-19

OKF Knowledge Gate 0.9.32 shows three findings that `okf-check` already had but the user could not see.

### Fixed
- **The summary counts the L2 warnings as advisories.** On a bundle with a broken link, L2 reported a warning and the summary line said `0 advisory(ies)`. The summary count now includes the L2 warnings, in line with `l2_warnings` in `--json` (on this repository's own bundle the count goes from 0 to 24). The README demo closes with `PASS ... 2 advisory(ies)` instead of `ALL GATES PASS`, because its last run has two L2 warnings; the transcript and the GIF were recorded again.
- **`okf_check.size` warnings are listed in `--json`.** They were printed in the text output but missing from `warnings[]`, so a CI job could not see them. Each entry names the note, its size and the limit. `warnings[]` no longer has the same length as `l1_warnings` when a size warning exists.
- **A `okf_check` option written at the top level of `okf-base.yaml` gets a WARN.** A `size:` block (or any of the nine known `okf_check` options) outside `okf_check:` was ignored without a word: `okflint` called the manifest valid, `okf-verify --check-config` returned 0, and `okf-check` printed nothing, so the gate was off and nothing said so. The text output now warns, naming the option and where it belongs; when the same option is also inside `okf_check:` the warning says to delete the top-level copy. `--json` lists them in `misplaced_keys`. Unknown keys stay silent and the exit code does not change.

### Changed
- Output for a bundle with no warnings and no misplaced option is byte-identical to 0.9.31 in text, `--json`, `--strict-trust` and `--fail-stale` (checked on three bundles); the only differences are the summary count when L2 warnings exist, the new `warnings[]` entries and `misplaced_keys`, all listed above.

## [0.9.31] - 2026-10-19

OKF Knowledge Gate 0.9.31 makes the public export refuse to publish private ticket numbers and private commit ids, which earlier public releases had carried.

### Fixed
- **The public export no longer publishes private issue and pull-request numbers or private commit ids.** The export removed references only in a fixed number range, so 51 private `(#NN)` references and one private commit id reached the public repository, and a number that looked like a public issue could point to a different one. The scan now runs on every text file and fails the export (exit 1, nothing written, no marker, and the publish step refuses an unmarked tree) in these cases: a private number or commit id in a code string, a docstring, a fenced block or a YAML value (fix the source by hand); a link into the private repository; a text file that is not UTF-8, unless the allow file lists it; a crash of the scan itself (it fails closed; before, an unexpected exit code counted as "findings found"). In prose and in comments the number is removed.
- **A number is public only after the name of a public repository** (the okf-knowledge-gate, okflint and okf-skills issues keep their numbers). A number after any other word, after the word "ticket" or "public", or after the private repository's own name is private and is removed or refused.
- **Commit ids are found in any case, from 7 to 64 characters, glued to other text, or split over two lines**, and the allow file cannot hide text: a `binary` entry must name a binary extension, and a short or whole-file entry is refused.
- **The doctor output of `okf-check` now names the repository** (the okflint issues 8, 9 and 10); it printed a bare number, which on the public repository is a different issue. The heading `Refused notes` lost its private number.

### Corrected
- The 0.9.2 entry said the public export drops private issue numbers and commit ids from every file. It did not: the export of 0.9.30 still held 72 private issue numbers in parentheses and three private commit ids, and so did the earlier public releases. Fixed here; the claim was wrong, not the release.

## [0.9.30] - 2026-10-19

OKF Knowledge Gate 0.9.30 stops `okf-export` from silently overwriting a note when the output disk ignores case, and from rewriting links inside indented code.

### Fixed
- **`okf-export` refuses two notes whose output names differ only in case when the output folder ignores case.** On macOS (APFS) and Windows, `Notes.md` and `notes.md` from one vault folder were written to the same file, and the second replaced the first with exit 0 and no message. When two output names would differ only in case, the exporter now checks whether the output folder folds case (with a temporary folder it creates and removes) and, if it does, stops with exit 2 naming both source files, before it writes anything. On a case-sensitive output both notes are exported as before. The check runs only when such a pair exists, so an ordinary export writes nothing extra. An output folder that cannot be written is reported with exit 2 and one line, not a traceback.
- **Indented code blocks are left as written.** A line indented by four spaces or a tab after a blank line, a heading or the start of the file is code in CommonMark; `okf-export` rewrote `[[x]]` inside it as if it were prose. A four-space indent inside a list item still continues the item, and fenced blocks were already left alone.

### Changed
- In a vault log, an item line indented four spaces after a blank line outside a list (`    - 2026-05-22: x` under a `## 2026-05-22` heading) is now an indented code block, as it is in the vault itself, so the exporter keeps the raw line and does not turn it into a dated item. Inside a list it is still read as an item.
- The output of the export for ordinary vaults is unchanged (checked on a synthetic vault, the repository's own `.okf` and `docs/`).

## [0.9.29] - 2026-10-19

OKF Knowledge Gate 0.9.29 stops `okf-verify` from confirming a code citation against the wrong file when the cited path contains a space.

### Fixed
- **A citation whose path has a space is no longer confirmed against the part after the space.** Given a note that cites `my w.py:3 @sha`, `okf-verify` read the path as `w.py` (the text after the last space) and reported CONFIRMED against a different file, even when a file named `my w.py` existed. It now looks for the longest name the words before `:line` can spell: when only `my w.py` exists the claim is checked in that file (CONFIRMED or REFUTED with its line count), when both `my w.py` and `w.py` exist it is UNRESOLVED and names both, and when only `w.py` exists the plain text form is still CONFIRMED against `w.py` (`my` is prose), while the quoted form (`` `my w.py`:3 ``, `"my w.py":3`) is REFUTED. A Windows path with a space is not a citation.
- **A blank line ends a citation.** `w.py:3`, a blank line and then `@sha` were read as one citation; only a single line break between them still counts.
- Two consequences of the new path search were kept out of the output: the same citation written twice with different words in front (`see w.py:3 @sha` and `Also in w.py:3 @sha`) is still one claim, and `git ls-tree -r` runs once per commit, not once per citation.

### Changed
- The case for a space-cut path in an earlier release (S2-E3) is amended: `a dir/w.py:1 @sha` (words that do not spell a file) stays UNRESOLVED, and `my dir/w.py:1 @sha` is CONFIRMED against `my dir/w.py`.

## [0.9.28] - 2026-10-19

OKF Knowledge Gate 0.9.28 closes holes in our own release gate: a test suite that ran nothing could be reported as passing, and six suites never ran on Linux.

### Fixed
- **The gate runners no longer pass a suite that did not run its tests.** `tools/check-tests.sh` accepted a suite with an early `exit 0` in forms it could not see (`true && exit 0`, `{ exit 0; }`, an `if` body, a one-line `FAIL=0; exit 0; ...`). Both gate runners now call one verdict function: a suite passes only when it exits 0, its last non-empty line is a summary of at least one passed and no failed, and the log holds as many `PASS` lines as the summary says. A suite with no summary, with `0 passed`, with a summary quoted inside a failure message, or killed after printing a good summary fails.
- **Six suites that the Debian gate never ran are now listed in `tools/linux-gate.conf` and pass there** (check-tests, install-git-hooks, linux-gate, pre-push-gate, refresh-graphs, sync-all-graphs), and a new check fails when a `*.test.sh` file is neither listed nor marked macOS-only with a reason.
- **An empty suite list fails** in both runners (it passed with zero suites run).

### Added
- **`tools/macos-gate.sh`**: the macOS gate that was a scratch script is now in the repository. It reads the same suite list from the conf, runs the two halves of the okf-check tests side by side, gives each suite stdin from `/dev/null` and a time limit from the conf, and writes a machine sample (load, Defender CPU, process count, top five processes) every 5 s next to its log, so a slow run keeps its own evidence.
- It takes the heavy-suite lock with its pid in it, takes the lock over from a gate that was killed, waits a bounded time for a live one, and stops the side-by-side suites before it gives the lock back on TERM, INT or HUP.

### Changed
- The Debian gate runs the tested tree as a one-commit git repository, because three of the newly listed suites need one.
- Known limits, on the backlog: a suite that skips most of its cases still passes; killing the gate with SIGKILL leaves the side-by-side suites running until their time limit.

## [0.9.27] - 2026-10-19

OKF Knowledge Gate 0.9.27 makes `okf-check` and the other tools safe to run on a folder that holds a note which is not a regular file. On 2026-10-18 a note that was a symbolic link to `/dev/zero` made the L2 profile tool grow to more than 100 GB of memory and brought a 24 GB Mac down.

### Fixed
- **A note that is a device file, a pipe, a socket or a folder, or that is larger than a limit, is refused before any layer reads it.** `okf-check` names the file and the reason, skips it, and carries on with the rest; the exit code is the exit code of a refusal. `okf_check.max_note_bytes` sets the limit; the default is 5,242,880 bytes (5 MiB). A folder named like a note (`x.md/`) is a warning, not an error.
- **Every layer now reads a frozen copy, not the live folder.** The check used to look at a file once and open it later, so a file swapped for a device in between could still reach a reader. `okf-check` now copies each note once, with a non-blocking open, the type and size judged on the open file and at most the limit plus one byte read, and L1, L2, L3, Trust and the house rules read only that copy. The same bounded read protects `okf-verify`, `okf-export`, `--duplicates`, `okf-trust`, `okf-scoped`, the edit hook, `okf-base.yaml` and `.okfignore`.
- **The L2 tool runs under a supervisor (`okf-limit.py`).** It gets its own process group, a time limit (`OKF_L2_TIMEOUT`, default 120 s) and a memory limit (`OKF_L2_MAX_RSS_MB`, default 2048 MB), and it is stopped with `okf-check`, including when `okf-check` is killed with SIGKILL. A timeout and an out-of-memory stop are reported as such. A missing supervisor is a `COULD NOT RUN` with exit 2, never a pass.
- **`.okfignore` that is a device, a pipe, a folder or too large is refused** with exit 2 and a message, instead of being treated as absent or read without a limit.
- **A bad `TMPDIR` is reported before anything is written** (a line was written to the root of the disk before).

### Added
- **`--selftest` probe "device and folder refused"**: a crippled copy of the refusal makes `--selftest` exit 5.
- **`docs/agents/safe-probe-brief.md`**: the rules for any probe that can use up memory, disk or processes (only in a memory-capped container, never on a developer's machine), and the heavy-suite lock protocol in the README release section.

### Changed
- The Debian gate runs its container with hard limits (memory 4 GB, 1024 processes, 4 CPUs) and a new suite, `tools/capped-container-tests.sh`, runs the device, pipe and race cases inside a 1 GB container (38 cases).
- Cost: on 300 ordinary notes a run takes about 0.7 s longer (measured: 3.4 s to 4.1 s and 4.0 s to 4.8 s in two independent runs on a loaded machine). The output for ordinary input is byte-identical to 0.9.26 (checked on four bundles in text, `--json`, `--strict-trust` and `--fail-stale`).
- Known limits, documented: a program started by `okflint` that creates a new session (`setsid`) escapes the group kill; a `.okfignore` of exactly the limit on one line makes the check spin for a long time (it was so before this release and is on the backlog).

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

[Unreleased]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.44...HEAD
[0.9.44]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.43...v0.9.44
[0.9.43]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.42...v0.9.43
[0.9.42]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.41...v0.9.42
[0.9.41]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.40...v0.9.41
[0.9.40]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.39...v0.9.40
[0.9.39]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.38...v0.9.39
[0.9.38]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.37...v0.9.38
[0.9.37]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.36...v0.9.37
[0.9.36]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.35...v0.9.36
[0.9.35]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.34...v0.9.35
[0.9.34]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.33...v0.9.34
[0.9.33]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.32...v0.9.33
[0.9.32]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.31...v0.9.32
[0.9.31]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.30...v0.9.31
[0.9.30]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.29...v0.9.30
[0.9.29]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.28...v0.9.29
[0.9.28]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.27...v0.9.28
[0.9.27]: https://github.com/ahmedibrahim085/okf-knowledge-gate/compare/v0.9.26...v0.9.27
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
