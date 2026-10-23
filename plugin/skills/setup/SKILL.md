---
name: setup
description: >-
  Sets up OKF on a machine or a folder: reports what is missing (okf-check --doctor), shows or runs the
  dependency install plan, and writes a starter okf-base.yaml (house rules) or .okfignore for a bundle. Use when
  asked to set up, install or initialise OKF, when a run says a layer is SKIPPED or COULD NOT RUN, or for a
  bundle with no house rules.
argument-hint: "[<bundle-dir>]"
allowed-tools:
  - 'Bash(*/scripts/okf-check" *)'
  - 'Bash(echo *)'
---

# /okf:setup

Run these in order. Each ends when its output is read; stop at the first step the owner did not ask for.

1. What is missing on this machine (changes nothing):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" --doctor
   ```

2. The install plan for the supported `okflint` (prints, changes nothing):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" --install-deps
   ```

   Run it with `--yes` only when the owner says so. `--latest` picks the newest `okflint` instead of the supported one.

3. House rules for the bundle `$ARGUMENTS`: a starter `<bundle>/okf-base.yaml` (never overwrites; edit `name:` and the types to the bundle):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" --init-house-rules <bundle-dir>
   ```

4. Paths to leave out of every layer: a starter `<bundle>/.okfignore` (never overwrites):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" --init-ignore <bundle-dir>
   ```

Steps 3 and 4 write a file: run them on the owner's request. Done when `okf-check <bundle-dir>` shows L2 as PASS or a named reason.
The starter holds a commented `okf_check:` block listing every option.
