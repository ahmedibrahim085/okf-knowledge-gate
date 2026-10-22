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
  L3 (staleness), L3 (derived staleness), the Successor rule, the Owner rule, the Size rule, the Facts rule, the Config check, a lookalike `human:`, `wikilink_root`, `--duplicates`, `--duplicates-body` and (when okf-memory is installed) L2 graph, and fails if a gate misses it. Without `okflint` the L2 profile probes are
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
| Trust (C4) | Can you believe a `human:` verification? | `okf-trust.py`: a draft note, or a review dated before the change, with a human verifier is a warning; an agent-generated note with one is an advisory. It cannot prove who a person is. A note the loader refuses for its size is `too large to read`: the layer fails (exit 1) instead of passing. |
| L3 staleness | Is it still true? | `stale_after` against today, and `status` |
| L3 derived | Has what it describes moved since? | `sources[].last_modified` against the file's mtime; a path counts only as written (case-exact, as `okf-verify`). A note the loader refuses for its size is `too large to read`: its sources were not compared, and the layer fails (exit 1). |
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
  (`hooks/hooks.json`); while off it only reads the event and exits. The bundle is the nearest folder above the edited
  note that holds an `okf-base.yaml`, so a manifest above the project (for example in `$HOME`) with `edit_hook: true`
  switches it on for every note below it; that is by design, because the hook runs only the plugin's own code.
  `okf-check --doctor` says whether the hook is on for the current folder (or the bundle you name), which file switched
  it on, and whether its config (`config/edit-hook.json`) is readable: the hook stays silent when it is not.
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
okf-check <bundle> --json          # machine-readable summary (`layers_not_run[]` names each layer that printed `COULD NOT RUN`, `[]` when none; `l2_findings[]` lists house-rule errors; `l2_advisories[]` the advisories behind `l2_warnings`, as `RULE file — message`, cut at 200 with a count; `warnings[]` also lists the `okf_check.size` warnings; `misplaced_keys[]` appears only when an `okf_check` option sits at the top level of `okf-base.yaml`; `reason` appears only on a run that stopped before its layers (a folder that cannot be read, an `.okfignore` that cannot be applied, no python3), with the stop named in `layers_not_run[]` and the reason on stderr too, exit 2; `sizes[]` only when `okf_check.size` is set, `facts[]` only when `okf_check.facts` is)
okf-check <bundle> --duplicates    # list candidate duplicate notes (a report, always exit 0)
okf-check <bundle> --duplicates-body   # the same, plus notes whose bodies are similar
okf-check <bundle> --facts [NAME]  # every statement of the declared facts (a dry run, always exit 0)
okf-check <bundle> --conserve REF  # every line removed since REF must reappear: MOVED, CHANGED or LOST
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

  PASS — no blocking errors, but 1 advisory(ies) and 2 skipped layer(s) above (advisories: Trust 1)
```

A Trust warning counts as an advisory in the last line, so the run still passes (exit 0) unless you pass `--strict-trust`.
The last line counts every warning the sections above list and names each layer's share. A finding that two layers
list is counted once per layer: a link to a missing file is an L1 warning and an L2 `L002`, so it counts 2
(`(advisories: L1 1 + L2 1)`).

`okf-verify` checks four kinds of claim and answers CONFIRMED, REFUTED or UNRESOLVED for each (and MOVED for a citation
whose quoted text is now on another line):

- **A commit SHA** is looked up in each `--repo` folder and in the repositories the bundle lists under
  `okf_check.verify.repos` in `okf-base.yaml`. A SHA that is in no searched repository is UNRESOLVED, never REFUTED.
  Treat `verify.repos` as trusted input: an `okf-base.yaml` from a fork pull request can point it at any repository on the
  runner (an absolute path to an unrelated repository was searched and its commit CONFIRMED), so do not run `okf-verify`
  on an untrusted pull request's bundle with that file in place.
  With `--remote` (or `okf_check.verify.remote: true`) such a SHA is also looked up, read-only, on the GitHub or GitLab
  repository the clone's `origin` names, and is CONFIRMED there when the local clone is only behind.
- **A code citation**, `path:line @sha` (also `path:first-last @sha` and `path:line at sha`), is one claim: the commit
  must exist, the file must exist at that commit, and the line must be in that file.
- **A line citation into a living document**, `decision-12.md:94`, `spec.md:40-42` or `decision-12:94` (no commit): the
  file must have that line. Add the first words of the line in quotes, `decision-12.md:94 "shadow, canary"`, and a citation
  whose line moved is reported as MOVED with its new line number; `--since main` finds the citations an edit shifted.
- **Absolute file paths** in backticks or quotes (and paths that start with `~`) are checked on disk, but only inside
  the bundle or a `--repo` folder, so a bundle you did not write cannot use the check to learn which files exist on your
  machine. `--host-paths` looks up the others too. Relative paths are not read.
  A cited path is read as written and is never looked up on disk to decide whether it is inside: a relative `--repo` and an
  absolute one give the same answer, because a relative one also counts as the folder your shell calls it (`$PWD`).
  A `--repo` or a bundle under a folder you may not enter is named in one line, not a traceback.

In a shallow clone (the `actions/checkout` default), commits older than the clone are missing: use `fetch-depth: 0`.
The full rules (declared repositories, line ranges, anchors, generated notes, paths that contain a space, what is not a
citation) are in
[the okf-verify reference](plugin/skills/okf/references/verify-and-install.md#what-counts-as-a-claim-and-how-each-is-judged).

`okf-export` is for a team that edits in an Obsidian-style vault, whose backlinks and graph count only `[[wikilinks]]`.
The vault stays the source; the export is a bundle `okf-check` can gate. Body `[[note]]`, `[[note|alias]]`,
`[[note#heading]]` and `[[#heading]]` become relative Markdown links, and each target and heading is checked.
Frontmatter, code (fenced, or indented 4 spaces or a tab) and raw HTML blocks are copied unchanged, since Obsidian renders no Markdown in HTML. Limits: inside a block quote a `[[link]]` in an HTML block, or in indented code that follows a list item, is still rewritten, and no setext heading (underlined with `===` or `---`) is recognised, nor any heading on or after a quote line whose `>`, spaces and list markers hold a tab (up to the end of the quote, and for a quote in a list item or one no blank line ended, to the end of the note); a link to one fails with `missing heading`, so name an ATX `# heading` and indent with spaces. A vault's `index.md` note becomes the folder note (`dir/index.md` to
`dir/dir.md`, the root one to `<vault folder>.md`), and an `index.md` listing is generated in every folder that holds
a note, with `okf_version` at the root; a rename onto an existing note stops the export. When `<out>` is on a disk
that does not tell upper from lower case (the macOS default) and the vault is not, two names that differ only in case
(`Notes.md`, `notes.md`) stop it too, as they would be written over each other. Two names that differ only in Unicode
normalisation (`café` written in NFC and in NFD, which macOS stores as one file) stop it on every disk, before anything
is written; the refusal names both notes, with the characters escaped when the two names look alike. A vault `log.md` note becomes
the folder's log: its dated lines (`## 2026-05-22` headings or `- 2026-05-22: text` items, with their indented
continuation lines) are grouped by date, newest first, under the note's own `# title`. Every `## ` heading must be a
date, as spec 9 requires. Exit 1 lists each missing or ambiguous target, missing heading, malformed date, `## ` heading
that is not a date (with the lines left out under it), undated log line, log frontmatter and log with no dated entry as
`file:line` (the bundle is still written); exit 2 means nothing was written (`<out>` is not empty, is inside the
vault or cannot be written, or two notes would be written to one name). A target is matched as Obsidian matches it: an exact match first, then ignoring case (two files that differ only in case are reported as ambiguous). Setext headings (a line underlined with `===` or `---`) are headings a `[[note#heading]]` link can name, except that a setext heading inside a block quote is not recognised: a link to one fails with `missing heading`, so give the quote an ATX heading (`# Title`) to link to. The vault is only read.

`okf-export` leaves out dot files and folders (`.obsidian`, `.git`) and names each file it skips (exit 1). A symlink that
leaves the vault or leads into a dot name is skipped, an absolute one without its host path (`an absolute link`). A symlink to
a folder is not followed, so its notes are not exported, and a broken link or a loop leads nowhere: all three are named,
never skipped in silence. A hard link to a file under a dot name is the same file, so it is skipped and named too (it is found
by device and inode). Limit: a hard link to a file OUTSIDE the vault cannot be told from a file that lives in it and is
exported; use a copy or a symlink, which is refused. A symlink under a dot name (`.store -> /ext`) is not walked either, so a
visible hard link to a file in its target is the same limit. A folder that cannot be listed is named (its files are not
exported), and a file with a second name is skipped and named while a folder (dot or visible) cannot be listed or entered; a file that cannot be examined is named too. A folder that lists but cannot be entered is named too.

A near-miss actor is a wrongly written actor such as `Human:dana`. OKF reads it as an agent, so a person's review is
lost without any other symptom. `--strict-trust` fails on it.

Read the exit code, do not just test for zero:

| Exit | Meaning |
|---|---|
| 0 | No gate failed. Skipped layers and warnings print above the verdict: read them |
| 1 | L1: the bundle is not conformant OKF, an `okf_check` house-rule error (`deprecated_requires`, `require_owner`, a body above `size.max_body_chars`, a note that is not a regular file or is above `max_note_bytes`, a `FACT-CONFLICT`), or (with `--strict-trust`) a trust policy failure. Also: `--init-ignore` or `--init-house-rules` refused to overwrite an existing file |
| 2 | A gate could not run. Never treat as a pass |
| 3 | L2: house rules broken, or `index.md` miscounts |
| 4 | L3: stale concepts (with `--fail-stale`) |
| 5 | `--selftest` failed: a gate stopped firing |
| 6 | The bundle changed during the scan (with `--fail-on-change`) |
| 64 | Usage error: no bundle, an unknown flag, or a path that is not a folder |

**Leave paths out:** put globs in `<bundle>/.okfignore` (`archive/`, `.trash/`; a leading `**/` matches at any depth,
the root included). Every layer skips them and the run says how many files it excluded. A symlinked note whose target is
ignored is ignored too, and a symlinked folder that `.okfignore` excludes is not named on the `symlinks` line (`--json`
`symlinked_folders` lists the ones it names). The plugin never creates the file by itself. White space around a pattern
is trimmed: space, tab, CR, VT and FF only, so a trailing no-break or ideographic space is part of the pattern.

**okf-check's own options** live in one `okf_check:` block of `okf-base.yaml`. Every option is off until you set it.
`okflint` ignores the block (measured: the L2 warning count is the same with and without it), and both `okf-check` and
`okf-verify` check it against one schema, `plugin/config/okf-check-block.json`: a key it does not know, or a value of the
wrong shape, exits 2 and names the key, so a typo cannot switch an option off without a word. Known keys: `verify`
(read by `okf-verify`; `repos` is a list of `path:` entries), `deprecated_requires`, `require_owner`, `owners`,
`size`, `facts`, `duplicates`, `wikilink_root`, `graph` (`true` runs the optional okf-memory layer, below) and `edit_hook`
(`true` turns the edit hook on for this bundle). A true/false option takes `true` or `false` only: a string such as `"on"` is
refused, and so is an unquoted `yes`, `no`, `on` or `off`, which this reader takes as a boolean and other YAML readers as a word.

**The optional okf-memory layer (L2 graph).** [okf-memory](https://github.com/okf-memory/okf-agent-memory) (MIT, a single Go
binary called `okf`) finds what no layer here looks for: notes that no other note links to (orphans) and concept links whose
target is gone. With `okf_check: {graph: true}` (or `OKF_MEMORY_BIN` set), `okf-check` runs its read-only `okf validate --json`
on the frozen copy and prints the findings as advisories (`L2 graph  WARN  2 broken concept link(s), 5 orphan(s)`; `--json`
`l2_graph`). The exit code does not change. When okf-memory is not installed the line says SKIPPED and what is unchecked; a
different tool that is also called `okf` is not mistaken for it. The plugin never installs or downloads it. It is installed by hand: download the binary for your platform from the [v0.6.2 release](https://github.com/okf-memory/okf-agent-memory/releases/tag/v0.6.2) (the version this layer was tested with) and check it against these sha256 values from the release's `checksums.txt`: `okf-darwin-arm64` `44bbc5c7caf2de390231ac57858e0bb7a948a5b5107e07ead667d88926ef8535`, `okf-darwin-amd64` `c9167a3545375531f17bad9aded2c4b9d42e5cd02711daebac12c6a46e102cad`, `okf-linux-arm64` `4385f5fa5278a08ba36214aee80e4be2d3b931429d127887f9c69d7f57a24dc0`, `okf-linux-amd64` `2da161da80132f70112a61fc237ce77aca0cbb0ea3767e73d7986dbd7cdcf47c`. Upstream publishes no signature file.

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
successor that is deprecated too (one hop: point at the final successor). Each is a house-rule error, exit 1. A note, or a
successor, the loader refuses for its size is named as `too large to read`: it is not read as a note with no `status`, and the line is
not a PASS.

`require_owner: true`: every note has an owner, an actor as in OKF section 7 (`human:dana`, `team:docs`,
`tool/1.0`). A note's own `owner` key wins; otherwise `owners` gives folder defaults as globs (the `.okfignore`
syntax, without negation: a pattern that starts with `!` exits 2), and the last matching pattern wins. The `Owner` line reports a note with no owner and an owner that is not an
actor (house-rule errors, exit 1), and a note whose frontmatter the loader refused for its size (`too large to read`: the
owner was not checked, which is not a missing owner). Each L3 staleness and lifecycle finding ends with `owner <actor>`, in the text and
in `--json` `stale[]` and `lifecycle[]`.

```yaml
okf_check:
  require_owner: true
  owners:
    "decisions/**": team:architecture
    "decisions/security/**": human:dana
```

`wikilink_root: <folder>`: a bundle inside a larger note vault (Obsidian, Foam) links notes by their path
from the vault root, `[[projects/p/README]]`, and `okflint` reports each such link as L001 although the note exists.
With the key set, an L001 for a path wikilink is also dropped (and counted in the "resolved by okf-check" line) when
`<folder>/<path>.md` exists. `<folder>` is relative to the bundle: for the bundle `vault/projects/p/bundle` the vault
root is `../../..`. A target that is missing under the folder still gives L001, and without the key nothing changes.
A symlinked folder is not entered. When the target exists in a folder above `<folder>`, the L2 lines say so
(`hint: 1 L001 link(s) resolve from ../../.., a folder above wikilink_root ../..`; in `--json`, `l2_hint`).
A wikilink names a note by Obsidian's rule, on every disk, here and in the Successor rule: the name spelled exactly
so, else the one name equal to it ignoring letter case (Python `lower()`, as `okf-export` does) and the Unicode
normalisation form (`[[New]]` names `new.md` on Linux as on macOS; macOS may store `café` decomposed; `okf-export`
does not ignore the normalisation form yet). The rule decides, not the disk: `[[STRASSE]]` does not name `straße.md`,
although macOS treats the two as one name. Two names that differ only in case (`Notes.md` and `notes.md`, on a
case-sensitive disk) make a link that matches neither exactly ambiguous: it is not resolved. A key written twice
inside `okf_check:`, or `okf_check:` written twice, is refused too (YAML would keep the last value in silence). The key is refused (exit 2, naming the key) when it is not a string, is an absolute
path, does not exist, is not a folder, is not the bundle or one of its parent folders, or is the file system root, the
home folder or a folder above it.

```yaml
okf_check:
  wikilink_root: ../../..
```

`size`: a body-size budget per note, for notes that agents read whole inside a fixed context window. `max_body_chars`
and `warn_body_chars` are optional whole numbers from 1, and the warning limit must be below the maximum (else exit 2,
naming the key). The measure is the BODY only, the text after the frontmatter's closing `---` line (a long `verified:`
block does not count), in characters, not bytes or tokens: a two-byte letter is one, a CRLF line break is one, a BOM is
none, and the final newline counts. A note with no frontmatter is all body. A body above `max_body_chars` is a house-rule
error (exit 1, like `require_owner`); above `warn_body_chars` it is a warning (exit 0, counted as an advisory in the
verdict). Each finding names the note, its size and the limit, and says to split the note or move a section to a
companion note, not to compress it. `index.md` and `log.md` are measured like any note (a log only grows); leave a
note out with `.okfignore`, or from this rule alone with `exclude`: a list of globs in the `.okfignore` syntax (a pattern
that starts with `!` exits 2), for example generated notes. The Size line counts the notes it left out. A note that is
not valid UTF-8 is reported by L1 only. Findings are in the text and in `--json` (`errors[]`, `warnings[]`); with the
option on, `--json` `sizes[]` also gives every measured note its body size and the two limits, so CI can show the trend
before a note breaks.

```yaml
okf_check:
  size:
    max_body_chars: 40000
    warn_body_chars: 38000
    exclude: ["generated/**"]
```

`facts`: declared facts (okf-knowledge-gate#15). A fact such as a count, a version or a list of countries is stated in
many notes; when it changes, some keep the old value. Declare its value once, with the regular expressions that find
where it is stated (group 1 is the stated value), and optionally the note where it is decided:

```yaml
okf_check:
  facts:
    launch.countries:
      value: "A and B"
      patterns: ["launch countries?:? *(.+)"]
      source: decisions/0007.md
```

A note line that states the fact with another value is a `FACT-CONFLICT`, a house-rule error (exit 1) naming the note, the
line, the fact and both values. Patterns match without regard to case; values are compared with case, runs of spaces and
surrounding punctuation and brackets ignored, and a stated value ends at the first `;` or `|` (a clause or a table cell).
The note bodies are read, not their frontmatter or code blocks, and `.okfignore` applies. The patterns run under a time
limit (`OKF_FACTS_TIMEOUT`), so a pattern that backtracks without end gives COULD NOT RUN (exit 2), not a hung run.
`value` and `patterns` are required; a pattern that is not a regular expression or has no capture group exits 2, in
`okf-check` and `okf-verify --check-config`. `--json` `facts[]` lists every statement and whether it agrees. Before you
change a value, `okf-check <bundle> --facts launch.countries` lists every occurrence with its line, marks the ones that
differ, and always exits 0.

**Conservation:** `okf-check <bundle> --conserve <ref>` (okf-knowledge-gate#16) asks whether a change kept what was
there. A split, a section moved to a companion note or a merge should keep every line; an agent that compresses a note to
pass a size limit does not announce what it dropped. Each line removed since `<ref>` (`git diff -w`, the working tree
included) is MOVED when it appears anywhere in the bundle now (an untracked note included), DECLARED when the deletion was
declared, CHANGED when a line added at the same place replaces it (shown old -> new, paired by position, so ten lines
compressed into two are two CHANGED and eight LOST), and LOST otherwise, with its note and old line number. Only notes
(`*.md`) are compared; blank lines, whitespace-only changes, lines with no letter or digit and the frontmatter are not
counted. A declaration counts only as a trailer, in the last paragraph of the commit message. The report is advisory
(exit 0); `--fail-lost` exits 1 on a LOST line. Declare intended deletions with `--deleted FILE` (a note path per line
for a whole note, or `line: <text>` for one line) or an `OKF-Deleted: <note>` trailer in the commit message. `--json`
gives every entry. The bundle must be in a git repository (exit 2 otherwise, or for an unknown ref).

**Notes that are not regular files, and the byte cap:** a note is opened only when, after symlinks are resolved, it is a
regular file of at most `okf_check.max_note_bytes` bytes (a whole number from 1, default `5242880`, 5 MB; a bad value
is exit 2). A `*.md` that is a device, a pipe or a socket, or is above the cap, is not read by any layer or by
`okf-verify`, `okf-export`, `--duplicates`, `--file` or the edit hook. `okf-check` names it once (`z.md — not a regular
file (device/pipe/...): skipped`, in `--json` `errors[]`), checks the other notes, and exits 1; `.okfignore` leaves it
out as it does any path. A *folder* named like a note is not a note and cannot hang a reader: it gets one `Skipped
folders  WARN` line (`d.md — a folder, not a note: skipped`, counted as an advisory) and the exit code does not change.
A device or pipe named `okf-base.yaml` is refused the same way, in every mode: `--duplicates` stops with exit 2 and
names it (with `--json`, in one JSON document: `exit`, `layers_not_run`, `reason`; so does every other stop of that mode), a full run exits 1. Why: a symlink to `/dev/zero` named like a note made `okflint` read for ever and grow to
112 GB (2026-10-18).

**What every layer reads:** `okf-check` judges the paths by `stat` first, then copies the notes and config it will read
into a private frozen copy with a bounded read that checks the type and size of the file it actually opened (at most the
cap, never waiting on a pipe). L1, Trust, the `okf_check` rules, L2 (`okflint`) and L3 read that copy only, so a note that
turns into a link to a device after the pre-scan is refused in the copy and reported, never read; the only live reads
left are `stat` calls, the bounded copy itself and the bounded read of a derived-staleness source. A run reports the
state of the bundle at the moment of the copy; a write during the run is still reported as `CONCURRENT`.

**The `okflint` watchdog:** `okflint` runs under `okf-limit.py`: it is stopped, with its whole process tree, at
`OKF_L2_TIMEOUT` seconds (`COULD NOT RUN — okflint timed out after N s`) or when it holds more than `OKF_L2_MAX_RSS_MB`
megabytes (`COULD NOT RUN — okflint exceeded N MB`), both exit 2. An `okflint` killed from outside (the out-of-memory
killer, a container limit) is reported as `killed (out of memory or time limit)`, not as timed out. It never outlives
`okf-check`: a `timeout`, TERM, INT or HUP stops it, and so does a SIGKILL to `okf-check` or to the watchdog itself (a
small watcher in a session of its own kills the command's group when the watchdog disappears). One limit remains: a
process that calls `setsid` leaves the group and is not reached; `okflint` starts none. Test such cases (a real device,
a pipe, a memory-eating stub) only in a container with memory, swap and pids caps, never on a real machine.

```yaml
okf_check:
  max_note_bytes: 5242880
```

**Duplicates:** `okf-check <bundle> --duplicates` lists pairs of notes that may record the same knowledge: the same
title (case, punctuation and spacing ignored), the same `sources[].resource`, or descriptions whose words overlap at or
above `okf_check.duplicates.threshold` (default `1.0`, identical word sets; on our labelled sample, lower values
flagged templated series, not duplicates). Each pair shows the signal and score, both statuses, `generated.at` and
owners. Pairs linked by `superseded_by` are skipped. It is a report, not a gate: exit 0. It stops at
`okf_check.duplicates.time_limit` seconds (default 60), which covers reading the notes too, and says `CUT SHORT` and in
which pass (reading, the pair comparison, the body comparison) if it did. `--json` gives `duplicates[]`, and `complete`,
`cut_in`, `notes_read` and `notes_total`. A note the loader refuses for its size is named (`too large to read`, not
compared), the report says `among the notes read`, and `--json` has `unread[]` and `complete: false`.
`--duplicates-body` adds pairs whose bodies share 5-word shingles at or above `okf_check.duplicates.body_threshold`
(default `0.6`; on our labelled live sample, 0.3 flagged as many unrelated notes as duplicates), found with MinHash
and then checked exactly, within the same time limit. A body under 5 words (a stub such as `TODO`) is not compared on its
body, since every such stub is the same single shingle; the report counts those notes (`--json` `body_short`).

**Environment variables** (all optional):

| Variable | Default | Effect |
|---|---|---|
| `OKF_L1_TIMEOUT` | 120 | Seconds L1's validator may run in all (the runs that find a note it crashes on share them); its cost grows with frontmatter size. Past it L1 is `COULD NOT RUN — the validator timed out` (exit 2). `0` or a non-number means the default. |
| `OKF_LAYER_TIMEOUT` | 300 | Seconds the Python layers (Trust, Successor, Owner, Size, derived L3, `--duplicates` and the scoped `--file` check) may run in all: ONE budget for the lot, counted in real milliseconds, as `OKF_L1_TIMEOUT` is for L1. Four of them parse every note's frontmatter (3.6 to 7.7 s per MB, linear), and a parse cannot be stopped from inside Python. Past it the layer is `COULD NOT RUN` naming the limit (exit 2, and `layers_not_run` in `--json`); a layer with no time left is not started. Rule for the value: 4 layers x the parse time of your largest notes, plus the rest: one 4.5 MB note took 16 s per layer on a fast Mac and 35 s on a slower one, so the default fits a note at the 5 MB cap; raise it for several such notes. Size parses no YAML but reads every note whole (54 to 74 ms for 4.5 MB), so it shares the budget. `0` or a non-number means the default; `1` is refused (exit 64): below 2 seconds the same bundle gets different verdicts from run to run. |
| `OKF_L2_TIMEOUT` | 120 | Seconds before a hung `okflint` is cut off in L2 (exit 2, named). `0` or a non-number means the default. |
| `OKF_L2_MAX_RSS_MB` | 2048 | Megabytes `okflint` and its children may hold before they are stopped (exit 2, named). Sampled four times a second with `ps`. `0` or a non-number means the default. |
| `OKF_L2_ISOLATE_MAX` | 200 | When okflint crashes on a bundle of at most this many notes, L2 finds the crashing notes (one run each), names them and checks the rest. Larger bundles keep the plain "crashed" report. |
| `OKF_INSTALL_TIMEOUT` | 200 | Seconds before `--install-deps` stops the installer. |
| `OKF_AUTO_INSTALL` | off | `1` lets the session-start check run the install plan itself. |
| `OKF_SEARCH_BIN` | `okf` on PATH | The `okf` search binary the doc-reuse reminder uses to name the closest notes. |
| `OKF_DOC_DIRS_FILE` | `~/.config/okf/doc-dirs` | File of extra shell globs for locations the doc-reuse guard watches. |
| `OKF_EDIT_HOOK` | off | `1` turns the edit hook on for every bundle, without the `edit_hook` key. |
| `OKF_EDIT_HOOK_TIMEOUT` | `plugin/config/edit-hook.json` | Seconds the edit hook waits for the check before it gives up silently, capped at `max_seconds`. A value that is not a positive number uses the default. The hook's check runs under `OKF_LAYER_TIMEOUT` too, but this box (4 s by default, 4.5 s at most) is far smaller and fires first: the hook stays silent, exits 0 and the check is stopped with it, so the layer limit matters in the hook only when set below the box. |
| `OKF_MEMORY_BIN` | `okf` on PATH | The okf-memory binary for the L2 graph layer; setting it also turns the layer on. |
| `OKF_GRAPH_TIMEOUT` | 60 | Seconds okf-memory may run before the L2 graph line says COULD NOT RUN. |

`OKF_TODAY`, `OKF_PINNED_VERSIONS`, `OKF_BUNDLE_DIR`, `OKF_DUP_TIME_LIMIT`, `OKF_DUP_CUT_AT` and `OKF_FORGE_API_BASE` exist for tests and replays.
`okf-verify --remote` reads `GITHUB_TOKEN` (or `GH_TOKEN`) for GitHub and `GITLAB_TOKEN` for GitLab, each sent only to its own
forge (a self-hosted GitLab must be named in `OKF_GITLAB_HOSTS`); without one it asks anonymously (GitHub allows 60 lookups an
hour). `OKF_FACTS_TIMEOUT` (default 60) is the seconds the `okf_check.facts` patterns may run before the Facts line says
COULD NOT RUN.

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
      - uses: ahmedibrahim085/okf-knowledge-gate@v0.9.44
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
    rev: v0.9.44
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
| python3 | runs the validator, the trust layer and `okf-verify` (run on 3.9 and 3.15 on macOS and 3.12 on Debian 12) | Required | python.org, PSF |
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
  [scaccogatto/okf-skills#68](https://github.com/scaccogatto/okf-skills/pull/68). If okf-skills#68 is never merged, this vendored
  copy stays as it is and keeps working. `plugin/vendor/VENDOR.md` lists what differs from upstream. When okf-skills#68 merges, we
  replace the copy with upstream at the merge commit and re-apply our patch (or offer it upstream).
- **L2 house rules, from mattdav/okflint.** Version 0.5.0 plus a commit on the maintainer's fork (ahmedibrahim085/okflint) with the BOM, non-UTF-8 and impossible-date
  fixes, `c505b8405b9ef07396a81734c2bdfaa33c57aa25`, installed only when you ask (`okf-check --install-deps --yes`). The
  fixes are an open pull request, [mattdav/okflint#11](https://github.com/mattdav/okflint/pull/11). If okflint#11 is never
  merged, the install keeps using that fork commit. `--latest` installs the newest PyPI okflint and prints a note that it
  "may lack the okflint#11 fixes". `--doctor` reports UNPATCHED if the fixes are missing.

The full behaviour contract, one row per scenario with its test, is
[`docs/spec.md`](docs/spec.md).

## Platforms

| Platform | Status |
|---|---|
| macOS | The test suites pass here, on bash 3.2 and the BSD tools (0.9.37: `tools/macos-gate.sh`, 36 suites and `--selftest`). The gate was built and measured on this platform. The log of the gate names the Python it ran under (`python 3.9.6`); Python 3.14 changed what `pathlib` does with a permission error, so `okf-verify.test.sh` and `okf-export.test.sh` pass under 3.9.6 and 3.15.0 since 0.9.43. |
| Linux | Written for GNU coreutils, findutils and awk (gawk and mawk). The 0.9.37 suites passed on Debian 12 (aarch64, bash 5.2.15, Python 3.12.13, gawk 5.2.1, non-root user) with `okflint` 0.5.0 and pre-commit 4.7.0 installed in a Python 3.12 environment: `tools/linux-gate.sh`, 36 suites and `--selftest`, 0 failed. Debian 12 ships Python 3.11, which cannot install `okflint`; the gate image installs Python 3.12. An earlier release also passed on Alpine Linux with gawk and mawk (2026-10-14). In the public repository, every pull request and every push to `main` also runs the suites and `--selftest` on GitHub's Ubuntu 24.04 runner, once with gawk and once with mawk, and runs the GitHub Action on a valid and an invalid bundle (`.github/workflows/ci.yml`). |
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
| `.github/` | Issue templates, the pull-request template, and CI: `workflows/ci.yml` runs the suites and the Action, `ci/run-suites.sh` is its suite runner (`OKF_SUITE_JOBS` suites at a time, default the CPU count up to 4) |
| `CHANGELOG.md` | Dated history of every release |

## Release

These steps run in the maintainer's private repository. The public repository ships `tools/demo` only: the other
`tools/` scripts and files named here (`tools/linux-gate.sh`, `tools/macos-gate.sh`, `tools/export-public.sh`,
`tools/export-public.allow` and the rest) and `docs/agents/safe-probe-brief.md` are not in it. From a public clone, run the
suites with `.github/ci/run-suites.sh` (see [Develop and test](#develop-and-test)).

1. Raise the version in `plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `VERSION` in
   `plugin/scripts/okf-check`. A test fails if they disagree. Then move the example pins (`okf-knowledge-gate@vx.y.z`
   and `rev: vx.y.z`) in this README, `plugin/skills/okf/SKILL.md` and `.pre-commit-hooks.yaml` to the new version
   (tests LT-37f and LT-41a).
2. Add a `## [x.y.z] - YYYY-MM-DD` section to [`CHANGELOG.md`](CHANGELOG.md).
3. Run the suites and `--selftest`, on macOS and on Linux: `tools/linux-gate.sh` streams the committed tree
   into a Debian container (settings in `tools/linux-gate.conf`; Docker context from `OKF_DOCKER_CONTEXT`; the suites run
   four at a time, the provisioned image is reused across runs with `OKF_LINUX_CACHE=1`, and `OKF_LINUX_CA_FILE` names a CA
   bundle to trust behind a proxy that re-signs TLS: it is bind-mounted, so with a remote Docker context the same path must
   hold it on the Docker host), and
   `tools/macos-gate.sh <log>` runs the same suite list on this Mac's working tree under the `python3` on `PATH` (the first line
   of the log ends with `python <version>`: run it under the oldest Python the plugin supports, 3.9, and under the newest on the
   Mac, because the verdict of a check on an unreadable folder differed between 3.9 and 3.14 and later), holding the heavy-suite lock (a lock
   left by a killed gate is taken over) and writing a machine sample every 5 s to `<log>.samples`. Both gates run each
   suite with stdin from `/dev/null` under a time limit (`OKF_GATE_SUITE_TIMEOUT`) and pass it only when it exits 0 and
   its last line is a summary of at least 1 passed and 0 failed, so a suite that stops early fails. `tools/check-tests.sh` (run by
   the pre-push gate) fails on a `*.test.sh` that `tools/linux-gate.conf` does not list.
   Two rules for whoever runs them (the full text, to paste into an agent's brief, is `docs/agents/safe-probe-brief.md`):
   - **Dangerous probes never run on the machine you work on.** A real device, a pipe, a socket, a file over 10 MB, an
     alias or zip bomb or a fork loop runs only in a throwaway container with hard caps
     (`docker run --rm --memory=1g --memory-swap=1g --pids-limit=256 --cpus=2 ...`) on another machine. The only device a
     host test may use is `/dev/null`. `timeout` is not a memory cap.
   - **Heavy suites take turns.** `okf-check.test.sh` and `okf-check-l3.test.sh` take seven minutes or more. Wait for the
     lock with `until mkdir /tmp/okf-heavy.lock 2>/dev/null; do sleep 20; done`, run each once on the final tree, and
     release it with `rmdir /tmp/okf-heavy.lock` (also after a failure).
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
   A binary ships only when `tools/export-public.allow` pins it by path and sha256 (`binary docs/demo.gif <sha256> # reason`):
   the scan cannot read inside it, so a person looks at it first. After re-recording `docs/demo.gif` (`tools/demo`), look at
   the new GIF, then replace its pin with the output of `shasum -a 256 docs/demo.gif`. An unpinned or changed binary stops
   the export, named with its sha256.
6. Publish the release notes from the changelog section, on the public repository:
   ```bash
   awk '/^## \[x.y.z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
     | gh release create vx.y.z -R ahmedibrahim085/okf-knowledge-gate --title "okf x.y.z" --notes-file -
   ```
7. Bring the installed plugin to the new version. `okf@ahmedmaged-okf` comes from a directory marketplace, so no
   uninstall or reinstall is needed: fast-forward the working copy that the marketplace points at
   (`git merge --ff-only origin/main`, it stays on `main`), then run `claude plugin update okf@ahmedmaged-okf`. It copies
   the new version into the plugin cache and says "updated from x to y ... Restart to apply changes" (observed on
   0.9.35 to 0.9.36; with the working copy still at the installed version it says there is nothing to update). Check
   `claude plugin list --json`: the `okf` entry shows the new `version` and `folderVersion`. A running session loads the
   plugin when it starts: restart it, or run `/reload-plugins`, and prove the loaded version with `okf-check --version`.
   `plugin.test.sh` P-10 reads the same `claude plugin list --json` and compares the installed copy with the source tree.

## License

MIT, see [`LICENSE`](LICENSE). Third-party code keeps its own MIT licence: the vendored validator
(`plugin/vendor/LICENSE.okf-skills`) and PyYAML (`plugin/vendor/LICENSE.pyyaml`).
