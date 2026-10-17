---
name: okf
description: >-
  Checks and gates an Open Knowledge Format (OKF) bundle with one deterministic command (okf-check):
  spec conformance, house rules, staleness, and whether human "verified" claims can be trusted. A second
  command (okf-verify) checks that the commit SHAs and file paths a bundle cites still exist. Use when asked
  to validate, lint or check an OKF bundle, before committing changes to one, or when a knowledge store
  needs a conformance, house-rule, staleness, trust or truth verdict. Also use when a folder of markdown notes
  with YAML frontmatter (lessons, decisions, a knowledge base) must be checked.
user-invocable: true
argument-hint: "<bundle-dir> [--fail-stale | --strict-trust | --json | --fail-on-change] | --doctor | --selftest | --init-house-rules <bundle-dir>"
allowed-tools: Bash
---

# OKF knowledge gate

One command over several layers. Knowledge stores rot when the checks are separate tools that someone must
remember, so this is a single entry point.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" $ARGUMENTS     # a plain `okf-check` also works while the plugin is enabled
```

The bundle path is **required** for a check (`--doctor` and `--selftest` need none). With none the command exits 64 with a usage message.

## Read the exit code, then act

Do not just test for zero. `2` ("could not run") is distinct from `1` ("not conformant") so that CI never confuses them.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | All gates pass (advisories and skipped layers are printed above the last line) | Proceed. A skipped layer is not a pass. |
| 1 | L1: the bundle is not conformant OKF. With `--strict-trust`: a Trust (C4) policy failure. Also: `--init-ignore` or `--init-house-rules` refused to overwrite a file | Read the output. Fix the notes it names. |
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
- **`--json`** carries the verdict only (exit, counts, `l2_profile`, and so on), not the list of failing notes. Read the text output when you must name a note.
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

## What this never does

- **Never installs silently.** A SessionStart preflight only reports a missing prerequisite.
  `okf-check --install-deps` prints a plan; `--yes` runs it; `OKF_AUTO_INSTALL=1` is the owner's opt-in.
- **Never runs `okflint index --apply`** (it would flatten a curated `index.md`) and **never rewrites bundle content.**
- **Never creates `.okfignore` or `okf-base.yaml` by itself.**
- **Does not verify that claims are true.** `okf-check` says the bundle is well-formed, house-conformant,
  unexpired and honest about who verified it. Conformance is not correctness; that is `okf-verify`.

## okf-verify: is what a note SAYS still true?

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" <bundle> [--repo DIR]... [--json] [--strict]   # plain `okf-verify` also works while the plugin is enabled
```

It resolves the commit SHAs and file paths each concept cites. Three verdicts, and the difference matters:

```
CONFIRMED   checked, and it holds
REFUTED     checked, and it does NOT hold
UNRESOLVED  could NOT be checked   (never a soft REFUTED: nobody looked)
```

A missing SHA is never REFUTED (it depends on which repositories were searched and does not survive a history
rewrite); a missing path is REFUTED only when its parent folder exists. `--strict` also fails on UNRESOLVED and on
notes with no checkable claim (those are listed as unverifiable, not verified).

## In CI and git

The same `okf-check`, without Claude Code: the GitHub Action `ahmedibrahim085/okf-knowledge-gate@v0.9.1`
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
