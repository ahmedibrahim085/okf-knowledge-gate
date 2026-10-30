---
name: explain
description: >-
  Explains one finding from okf-check, okf-verify or okf-export: which layer raised it, what it means, and the
  fix for the note. Use when asked what a finding, error, warning, advisory or verdict line means, why a run
  failed, or how to fix a note the gate flagged.
argument-hint: "<the finding line, or <bundle-dir> <note>>"
allowed-tools:
  - 'Bash(*/scripts/okf-check" *)'
  - 'Bash(echo *)'
  - Read
---

# /okf:explain

The finding is `$ARGUMENTS`. When only a bundle and a note are given, run this and take the line it prints. The bundle is
the first path, everything before the first word starting with `--`; the note is the path after `--file`, quoted the
same way. Put both in double quotes, as shown; if the argument text already quotes a path, use it as typed. A path that
holds a `"`, a `$` or a backtick needs single quotes instead, with a `'` inside them written as `'\''`.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" "<bundle-dir>" --file "<note>"
```

1. Find the line's row below (the first word or the layer name on its line).
2. Read the layer's row in the README table, https://github.com/ahmedibrahim085/okf-knowledge-gate#what-it-checks, and `${CLAUDE_PLUGIN_ROOT}/skills/okf/references/layers.md`.
3. Answer in three parts: the layer and what it checks, why this note raised it (quote the note's own line), the exact edit to the note.

| The line shows | Layer and meaning | Fix in the note |
|---|---|---|
| `L1 conformance FAIL`, `§11.x ...` | Not valid OKF: bad frontmatter, a missing or empty `type` | Add or correct the field the line names. |
| `recommended field ... absent`, `cross-link target not found` | L1 warning, soft guidance; the spec tolerates a broken link (§6.1) | Add the field if useful. Keep the outbound link. |
| `Trust (C4)`, `draft with human verification` | A `human:` verifier on a draft note, or a review dated before the note changed | The named person reviews again and dates it after the change; or remove the claim. Never write `human:` yourself. |
| `L2 profile`, a code such as `L001`, `S202`, `F001` | A house rule of `okf-base.yaml` is broken | Fix the note. Never edit `okf-base.yaml` to pass. For `L001` on a vault-root link see `wikilink_root` in the `okf` skill. |
| `L2 index` | `index.md` counts differ from the files | Correct the bold count line. |
| `L3 staleness`, `expired <note> (stale_after ...)` | The note's review date has passed | Re-verify the note's content, then ask the owner for a new date. |
| `Size` | A note body is above `size.max_body_chars` | Split the note or move a section to a companion note. |
| `FACT-CONFLICT` | A note states a declared fact with another value | Change the note to the declared value; the owner changes the fact in `okf-base.yaml`. |
| `LOST` (`--conserve`) | A line removed since the ref appears nowhere | Put the line back, or move it to the note where it belongs. `MOVED` and `DECLARED` need no action; read each `CHANGED` old -> new pair. |
| `Refused notes` | A `*.md` is a device, pipe or socket, or above `max_note_bytes`: no layer opened it (exit 1) | Remove or replace it, or leave it out with `.okfignore`. |
| `COULD NOT RUN`, `SKIPPED` | A layer did not run: not a pass | The reason is on the line; for a missing dependency or no `okf-base.yaml` run `/okf:setup`. |
| `REFUTED` (okf-verify) | A cited path does not exist, under a folder that does | Fix the reference. |
| `MOVED` (okf-verify) | A line citation points at the wrong line | Use the line the detail gives. |
| `UNRESOLVED` (okf-verify) | The claim could not be checked | Add `--repo` for the repository; it is not false. |
| `missing heading`, `missing or ambiguous target` (okf-export) | A `[[link]]` or `#heading` in the vault names nothing | Fix the link in the vault. |
