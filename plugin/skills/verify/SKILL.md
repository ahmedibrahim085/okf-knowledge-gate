---
name: verify
description: >-
  Runs okf-verify: checks that the commit SHAs, file paths and line citations an OKF bundle cites still exist,
  and answers CONFIRMED, REFUTED, MOVED or UNRESOLVED per claim. Use when notes cite code, commits or files that
  may have moved or been rewritten, before trusting a note's references, or after a history rewrite.
argument-hint: "<bundle-dir> [--repo DIR]... [--since REF] [--remote] [--host-paths] [--strict] [--json]"
allowed-tools:
  - 'Bash(*/scripts/okf-verify" *)'
  - 'Bash(echo *)'
---

# /okf:verify

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" $ARGUMENTS
```

Pass `--repo DIR` for each repository the SHAs live in (repeatable). Without one, a SHA is UNRESOLVED.

| Verdict | Meaning | Do |
|---|---|---|
| CONFIRMED | Checked, and it holds | Nothing. |
| REFUTED | Checked, and it does not hold (a path whose parent folder exists but the file does not) | Fix the note's reference. |
| MOVED | A line citation with a quoted anchor whose text now sits on another line (exit 1) | Change the line number to the one the detail gives. |
| UNRESOLVED | Could not be checked (no repository searched, a SHA outside it) | Name the repository to add; never report it as false. |

| Add | Effect |
|---|---|
| `--since REF` | Compare each line citation into a file changed since REF with the file at REF |
| `--remote` | Ask the GitHub or GitLab API for a SHA that no searched clone holds |
| `--host-paths` | Also look up cited absolute paths outside the bundle |
| `--strict` | Fail on UNRESOLVED and on notes with no checkable claim |
| `--json` | Machine-readable result |

Path and SHA rules: `${CLAUDE_PLUGIN_ROOT}/skills/okf/references/verify-and-install.md`.
