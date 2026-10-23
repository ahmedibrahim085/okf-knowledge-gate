---
name: export
description: >-
  Runs okf-export: turns an Obsidian-style vault of [[wikilinked]] markdown notes into an OKF bundle that
  okf-check can gate, converting wikilinks and embeds to relative Markdown links. Use when asked to convert,
  export or migrate a vault, an Obsidian folder or wikilinked notes to OKF.
argument-hint: "<vault-dir> <out-dir>"
allowed-tools:
  - 'Bash(*/scripts/okf-export" *)'
  - 'Bash(*/scripts/okf-check" *)'
  - 'Bash(echo *)'
---

# /okf:export

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-export" $ARGUMENTS
```

Then check the result: `"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" <out-dir>`.

The vault is read and never written. `<out-dir>` must be empty or new, outside the vault.

| Exit | Meaning | Do |
|---|---|---|
| 0 | Bundle written, every link resolved | Run `okf-check` on it. |
| 1 | Bundle written, and the report lists each missing or ambiguous target, missing heading, malformed log date or file it skipped as `file:line` | Fix those in the vault, then export again into a new `<out-dir>`. |
| 2 | Nothing written (`<out-dir>` not empty, inside the vault, or unwritable; a rename collision) | Fix the command. |

What converts, and what a vault `index.md` and `log.md` become: the okf-export section of the `okf` skill (`/okf:okf`).
