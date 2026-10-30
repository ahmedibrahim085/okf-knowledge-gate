---
name: export
description: >-
  Runs okf-export: turns an Obsidian-style vault of [[wikilinked]] markdown notes into relative Markdown links
  in an OKF bundle that okf-check can gate once each note carries its own YAML frontmatter (the export writes
  none). Use when asked to convert, export or migrate a vault, an Obsidian folder or wikilinked notes to OKF.
argument-hint: "<vault-dir> <out-dir>"
allowed-tools:
  - 'Bash(*/scripts/okf-export" *)'
  - 'Bash(*/scripts/okf-check" *)'
  - 'Bash(echo *)'
---

# /okf:export

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-export" "<vault-dir>" "<out-dir>"
```

Both arguments are paths and neither is a flag: the first is the vault, the second the folder to write. Put both in
double quotes (`/okf:export "my vault" "out dir"`), one argument each. If the argument text already quotes a path, use
it as typed. If a path holds a `"`, a `$` or a backtick, put it in single quotes instead, and write a `'` inside them
as `'\''`.

Then check the result: `"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" "<out-dir>"`.

Every note the export writes needs YAML frontmatter with a non-empty `type` field. The export copies frontmatter
unchanged and writes no frontmatter into your notes, so a vault whose notes have none exports with exit 0 and is then
refused by `okf-check` at L1 (`§11.1 no parseable YAML frontmatter block` per note, ``§11.2 missing or empty required
`type` field`` for an empty, non-string or missing one). Ask the user to add the block in the vault before exporting: the `type` value is
theirs to choose, and you do not invent note content.

An embed — `![[note]]`, `![[note#heading]]`, `![[img.png]]`, `![[img.png|200]]` — is left as written, and a file it
names inside the vault (and not in a folder or file whose name starts with a dot) is copied into the bundle at the path
it has there; a target outside the vault or with such a name is not copied. A Markdown link can say where a target is,
not that its text is transcluded here.

What `okf-check` reports about an embed depends on the layer. L1 does not check an embed as a link: it resolves no
target of an embed, so a missing one is not reported there. With house rules on (an `okf-base.yaml`, so L2 runs
`okflint`), okflint reads `![[note]]` as the wikilink `[[note]]` and matches a target only among the notes, so a note
target that does not exist, and every embed of a file that is not a note, are listed as an `L001 broken wikilink`
advisory; advisories do not block, but a house-rule error elsewhere in the profile still fails the run.

The vault is read and never written. `<out-dir>` must be empty or new, outside the vault.

| Exit | Meaning | Do |
|---|---|---|
| 0 | Bundle written, every link resolved | Run `okf-check` on it. |
| 1 | Bundle written, and the report lists each missing or ambiguous target, missing heading, malformed log date or file it skipped as `file:line` | Fix those in the vault, then export again into a new `<out-dir>`. |
| 2 | Nothing written (`<out-dir>` not empty, inside the vault, or unwritable; a rename collision) | Fix the command. |

What converts, and what a vault `index.md` and `log.md` become: the okf-export section of the `okf` skill (`/okf:okf`).
