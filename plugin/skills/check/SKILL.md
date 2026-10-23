---
name: check
description: >-
  Runs okf-check on an OKF bundle (a folder of markdown notes with YAML frontmatter) and reports the verdict:
  spec conformance, house rules, staleness, trust in "verified by a human" claims. Also finds duplicate notes,
  lists where a fact is stated, checks one note, and proves no content was lost since a git ref. Use when asked to
  validate, lint or review notes, before committing notes, in CI, after editing one note, before a refactor of
  notes, or to find duplicates.
argument-hint: "<bundle-dir> [--fail-stale | --strict-trust | --json | --file <note> | --duplicates | --facts [NAME] | --conserve <ref>]"
allowed-tools:
  - 'Bash(*/scripts/okf-check" *)'
  - 'Bash(echo *)'
---

# /okf:check

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" $ARGUMENTS
```

The bundle folder comes first. With none, the tool exits 64. Read the exit code with the table in the `okf` skill
(`/okf:okf`): `2` means a gate could not run and is never a pass.

| Job | Add |
|---|---|
| Staleness blocks the run (exit 4) | `--fail-stale` |
| Unproven or near-miss `human:` verification blocks (exit 1) | `--strict-trust` |
| Machine-readable result | `--json` |
| One note you just edited, L1 and Trust only | `--file <note>` |
| The bundle changes under a writer (exit 6) | `--fail-on-change` |
| Notes that may record the same thing (a report, exit 0) | `--duplicates`, or `--duplicates-body` to compare bodies too |
| Every place a declared fact is stated (needs `okf_check.facts`) | `--facts [NAME]` |
| Nothing lost since a ref, after a split, move or merge of notes | `--conserve <ref>` |
| Exit 1 on a LOST line; `--deleted <file>` declares deletions the owner asked for (a note path per line, or `line: <text>`) | `--fail-lost`, `--deleted <file>` |
| Prove each gate still fires | `--selftest` (no bundle) |

When a finding is unclear, run `/okf:explain` on it. When the cited commits and paths matter, run `/okf:verify`.
