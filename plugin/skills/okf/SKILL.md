---
name: okf
description: >-
  Overview of the OKF Knowledge Gate, three tools over Open Knowledge Format (OKF) bundles, folders of markdown notes
  with YAML frontmatter. okf-check gates a bundle (spec conformance, house rules, staleness, trust in "verified by a
  human" claims), finds duplicate notes, lists where a fact is stated and proves no content was lost since a git ref.
  okf-verify checks that cited commit SHAs, file paths and line citations still exist. okf-export turns an
  Obsidian-style [[wikilink]] vault into a conformant bundle. Use to choose which OKF tool or /okf: skill fits, or to
  read an exit code; each job has its own skill.
user-invocable: true
argument-hint: "<bundle-dir> [--fail-stale | --strict-trust | --json | --fail-on-change | --file <note> | --duplicates | --duplicates-body | --facts [NAME] | --conserve <ref>] | --doctor | --selftest | --install-deps | --init-house-rules <bundle-dir> | --init-ignore <bundle-dir>"
allowed-tools: Bash
---

# OKF knowledge gate

One command over several layers. Knowledge stores rot when the checks are separate tools that someone must
remember, so this is a single entry point.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" $ARGUMENTS     # a plain `okf-check` also works while the plugin is enabled
```

The bundle path is **required** for a check (`--doctor` and `--selftest` need none). With none the command exits 64 with a usage message.

## Entry points

Each job has its own skill; use the one that fits and come back here for the exit codes.

| Skill | Job |
|---|---|
| `/okf:check` | Check a bundle; duplicates, facts, one note, content conservation |
| `/okf:verify` | Do the cited SHAs, paths and line citations still exist (okf-verify) |
| `/okf:export` | Turn a wikilinked vault into a bundle (okf-export) |
| `/okf:setup` | Doctor, install plan, starter house rules and `.okfignore` |
| `/okf:explain` | Explain one finding and the fix for the note |

## Read the exit code, then act

Do not just test for zero. `2` ("could not run") is distinct from `1` ("not conformant") so that CI never confuses them.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | All gates pass (advisories and skipped layers are printed above the last line) | Proceed. A skipped layer is not a pass. |
| 1 | L1: the bundle is not conformant OKF, or an `okf_check` house-rule error (`deprecated_requires`, `require_owner`, a body above `size.max_body_chars`, a note that is not a regular file or is above `max_note_bytes`). With `--strict-trust`: a Trust (C4) policy failure. Also: `--init-ignore` or `--init-house-rules` refused to overwrite a file | Read the output. Fix the notes it names. |
| 2 | A gate COULD NOT RUN (missing dependency, crashed scan, hung tool) | Run `okf-check --doctor`. Report what is missing. Do not install anything without the owner's consent. Never report a pass. |
| 3 | L2: house rules broken, or `index.md` miscounts its own bundle | Fix the notes it names. Never edit `okf-base.yaml` to make a run pass. |
| 4 | L3: stale concepts (only with `--fail-stale`) | List them and ask the owner. Never bump `stale_after` to silence it. |
| 5 | `--selftest` failed: a gate stopped firing | Stop and report. This is the worst outcome. |
| 6 | The bundle changed during the scan (only with `--fail-on-change`) | Re-run when writers are idle. |
| 64 | Usage error: no bundle, an unknown flag, two bundles, or a path that is not a folder | Fix the command. Do not retry it unchanged. |

Precedence when several apply: 5 > 1 > 3 > 2 > 6 > 4. A reached verdict outranks "could not run".

## Interpreting the output

- **ERROR** is a hard OKF conformance failure (unparseable frontmatter, a missing or empty `type`). Fix every one.
- **warn** is soft guidance. Broken cross-links are tolerated by the spec (§6.1): they are knowledge not yet
  written. Never "fix" a bundle by deleting an outbound link.
- **SKIPPED** means a layer did not run. A skipped layer is counted in the verdict line and never shown as PASS; the exit code stays 0 unless another gate fails.
- **`--json`** carries the verdict, the counts and the findings behind them: `errors[]` (L1 and the okf_check house rules such as size), `layers_not_run[]` (each layer that printed `COULD NOT RUN`, `[]` when none; a run that stops before its layers also carries `reason`, and `--duplicates --json` prints the same document on every stop), `l2_findings[]` (house-rule errors only), `l2_advisories[]` (the L2 advisories behind `l2_warnings`, as `RULE file — message`, sorted; the first 200, then one last line that counts the rest; empty when L2 did not run; when okflint crashed on some notes and the others were checked, the list holds the advisories of the notes it checked, as the text does), `l2_warnings` and `l2_by_rule` (the L2 advisory totals; null when L2 did not run, filled the same way after a crash on some notes), `stale[]` (expired or malformed `stale_after`), `lifecycle[]` (a status outside draft, stable, deprecated), `skipped[]` (layers that did not run), `warnings[]` (L1 warnings, then the okf_check size warnings) and `trust_findings` (with `trust_note`, the sentence that okf-check cannot prove who a person is, when it holds a `human:` finding). Each entry is one text line that names the note. The key set is the same on every exit path, plus `misplaced_keys[]` when an okf_check option sits at the top level of okf-base.yaml instead of inside okf_check (it is then ignored).
- **CONCURRENT** means the bundle changed during the scan; the report is a point-in-time reading.

## Trust (C4): can a "verified by a human" claim be trusted?

OKF v0.2 records `verified: by: human:<id>` and cannot authenticate it: an agent can write that line itself.
The Trust (C4) layer reports, per `human:` verified entry: a **draft** note, or a review dated **before** the
note's change, as a warning; an **agent-generated** note as an advisory. It never proves who a person is
(the output says so). `--strict-trust` turns these findings and near-miss actors such as `Human:dana` (read
as an agent) into exit 1; it changes severity only, never what is found.

## Before you trust a green run, and setting up

- After any dependency upgrade run `okf-check --selftest`: it plants a known defect per layer and requires each
  gate to catch it.
- `L2 SKIPPED — no okf-base.yaml` means house rules are not enforced. The owner can run
  `okf-check --init-house-rules <bundle>` to write a starter `<bundle>/okf-base.yaml` (it never overwrites;
  nothing else writes it). `okf-check --init-ignore <bundle>` does the same for `.okfignore`. Only run an init
  command when the owner asks. Set requirements the bundle already meets before adding new ones.
- L2 reports `L001 broken wikilink` for a link written from a vault root (`[[projects/p/README]]`) when the bundle
  sits inside a larger note vault. Setting `okf_check: {wikilink_root: ../../..}` in `okf-base.yaml` (a folder relative
  to the bundle: the bundle itself or a parent) makes okf-check look for such a target there. Set it only when the
  owner asks, and never to hide a link whose target is really missing: that still gives L001.

- A `Size` line means the bundle sets `okf_check.size` in `okf-base.yaml`: a note body above `max_body_chars` is exit 1
  (a house-rule error), above `warn_body_chars` an advisory (exit 0). Fix it by splitting the note or moving a
  section to a companion note. Never compress the text to get under the number, never raise the limit and never add the
  note to `okf_check.size.exclude` to pass a run (`exclude` is for notes a script generates, set by the owner).

- Before you commit a reorganisation of notes (a split, a move to a companion note, a merge), run
  `okf-check <bundle> --conserve HEAD`: every removed line should be MOVED. Put back each LOST line, or move it to the
  note where it belongs; declare a deletion only when the owner asked for it (`OKF-Deleted: <note>` in the commit).

- A `Facts` line means the bundle declares facts in `okf_check.facts`: a `FACT-CONFLICT` names a note that states a fact
  with another value (exit 1). Fix the note to the declared value; if the value itself changed, the owner changes it in
  `okf-base.yaml`, and `okf-check <bundle> --facts NAME` lists every place that must follow.

- An `L2 graph` line means the bundle opted into okf-memory (`okf_check.graph: true`): `WARN` lists orphan notes (no note
  links to them) and concept links whose target is gone. Advisory: link an orphan from its parent or index note, or fix the
  link; never delete a note to silence it. `SKIPPED` means okf-memory is not installed, so those are unchecked.

- A `Refused notes` line means a `*.md` is a device, pipe or socket, or is above `okf_check.max_note_bytes` (default
  5242880 bytes): no layer opened it, and the run exits 1. Remove or replace it, or leave it out with `.okfignore`. Never
  point a symlink named like a note at a device. A folder named like a note gets a `Skipped folders  WARN` line and the
  exit code is unchanged. Every layer reads a bounded, frozen copy of the notes, never the bundle itself. If `okflint` is
  stopped with `exceeded N MB`, the bundle is the cause, not the limit (`OKF_L2_MAX_RSS_MB`, default 2048); `killed (out
  of memory or time limit)` means something outside `okf-check` stopped it. `okflint` never outlives
  `okf-check`: a `timeout`, TERM, INT or even SIGKILL to `okf-check` or to its `okf-limit.py` watchdog stops it (a process
  that calls `setsid` leaves the group and is not reached; `okflint` starts none). The Python layers (Trust, Successor,
  Owner, Size, derived L3) share one time budget, `OKF_LAYER_TIMEOUT` (default 300 s): a layer past it is `COULD NOT RUN`
  naming the limit (exit 2; `--json` `layers_not_run`), never a pass.

## What this never does

- **Never installs silently.** A SessionStart preflight only reports a missing prerequisite.
  `okf-check --install-deps` prints a plan; `--yes` runs it; `OKF_AUTO_INSTALL=1` is the owner's opt-in.
- **Never runs `okflint index --apply`** (it would flatten a curated `index.md`) and **never rewrites bundle content.**
- **Never creates `.okfignore` or `okf-base.yaml` by itself.**
- **Does not verify that claims are true.** `okf-check` says the bundle is well-formed, house-conformant,
  unexpired and honest about who verified it. Conformance is not correctness; that is `okf-verify`.

## okf-verify: is what a note SAYS still true?

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" <bundle> [--repo DIR]... [--host-paths] [--since REF] [--json] [--strict]   # plain `okf-verify` also works while the plugin is enabled
```

It resolves the commit SHAs, file paths and line citations (`decision-12.md:94`) each concept cites. Three verdicts, and the difference matters:

```
CONFIRMED   checked, and it holds
REFUTED     checked, and it does NOT hold
UNRESOLVED  could NOT be checked   (never a soft REFUTED: nobody looked)
```

A missing SHA is never REFUTED (it depends on which repositories were searched and does not survive a history
rewrite); a missing path is REFUTED only when its parent folder exists. `--strict` also fails on UNRESOLVED and on
notes with no checkable claim (those are listed as unverifiable, not verified).

A citation with a quoted anchor (`decision-12.md:94 "shadow, canary"`) whose text now sits on another line is MOVED
(exit 1): fix the line number to the one the detail (or `--json` `moved_to`) gives, unless the citation is pinned with
`@sha` (history is never renumbered). When you add a line citation, add the first words of the line as its anchor.

## One note: `--file`

`okf-check <bundle> --file <note>` checks only that note, L1 and Trust, in well under a second: one line per
finding (`<note>: L1 error: ...`, `L1 warning`, `Trust warning`, `Trust error` for a note the loader refuses for its size), nothing when the note is clean. Exit codes keep
their meaning (1 an L1 error, a Trust error, or a Trust finding under `--strict-trust`; 2 could not run; 64 the note is not a `.md`
inside the bundle). It is meant for an edit hook; the full run is still the gate.

The plugin ships that hook, OFF by default: `okf_check: {edit_hook: true}` in a bundle's `okf-base.yaml` (or
`OKF_EDIT_HOOK=1`) makes every Write/Edit of a note in that bundle run it. On an L1 error or a Trust warning Claude
sees one line starting `okf-check:` after the edit; fix the note it names. The hook is time-boxed and stays silent
when it cannot run. The bundle is the nearest folder above the note with an `okf-base.yaml`, so a manifest above the
project (for example in `$HOME`) with `edit_hook: true` applies to every note below it. If the hook seems to do nothing,
run `okf-check --doctor`: it names the file that switched the hook on and says when the hook's config is unreadable.

## okf-export: a note-tool vault in, an OKF bundle out

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-export" <vault> <out>   # plain `okf-export` also works while the plugin is enabled
```

For a team that edits in an Obsidian-style vault: the vault stays the source, and the export is a bundle
`okf-check` can gate. Body `[[note]]`, `[[note|alias]]`, `[[note#heading]]` and `[[#heading]]` become relative
Markdown links; frontmatter, code (fenced or indented) and raw HTML blocks (inside block quotes too; Obsidian reads no Markdown in them) are copied unchanged. Targets match as Obsidian matches them
(exact first, then ignoring case), and a setext heading (underlined with `===` or `---`) is a heading a link can name, inside block quotes too (a tab before a quote line's text counts its columns from the start of the line, as CommonMark does). A vault `index.md` note is renamed to
the folder note (`dir/dir.md`) and spec index files are generated (root carries `okf_version`); a rename collision
stops the export with exit 2, and so do two names that differ only in case when `<out>` is on a case-insensitive disk. A vault `log.md` note becomes the spec log (dated lines grouped, newest first; every `## ` heading must
be a date). Exit 1 lists every missing or ambiguous target, missing heading, malformed date, non-date `## ` heading,
undated log line, log frontmatter and log with no dated entry as `file:line` (the bundle is still written); exit 2 means nothing was written (`<out>` not
empty, inside the vault, or cannot be written). It never writes into the vault.

## In CI and git

The same `okf-check`, without Claude Code: the GitHub Action `ahmedibrahim085/okf-knowledge-gate@v0.9.56`
(inputs `bundle`, `strict-trust`, `fail-stale`) and the pre-commit hook `id: okf-check` (its `args` replace the
default `.`). Both take `okf-check`'s exit code. Details are in the repository README.

## More detail, loaded only when needed

- How each layer works, the L3 staleness rules, what happens when one note crashes a checker, the okflint
  "patched" probe: `references/layers.md`
- Ignoring paths with `.okfignore` and the doc-reuse reminder: `references/ignore-and-reminders.md`
- okf-verify path and SHA rules (fenced code, ephemeral paths, history rewrites), setting up house rules, install
  and `--latest` behaviour, what the gate never does: `references/verify-and-install.md`

## Dependencies

`python3` is required (PyYAML is vendored; the conformance checker is vendored, so L1 works with no clone and no
network). `okflint` is optional (L2) and is installed only on request: `okf-check --install-deps`.
