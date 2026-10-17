# okf-verify rules, setup and what the gate never does

Contents: okf-verify (verdicts, paths, SHAs) · setting up house rules · what this never does

## okf-verify (L4): is what it SAYS still true?

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" <bundle> [--repo DIR]... [--host-paths] [--json] [--strict]
```

Resolves the checkable claims in each concept — cited commit SHAs and file paths —
against reality. Separate from `okf-check` because it needs to be told which
repositories to search; `okf-check` stays zero-config.

**Three verdicts, and the distinction is the whole point:**

```
CONFIRMED   checked, and it holds
REFUTED     checked, and it does NOT hold
UNRESOLVED  could NOT be checked
```

`UNRESOLVED` is **not** a soft `REFUTED`. Collapsing them would report a corpus as
false when the truth is that nobody looked. So SHAs and paths are treated
asymmetrically on purpose:

- A missing **file path** can be REFUTED — but only when its parent directory
  exists, so we know we searched the right place. Missing parent ⇒ different
  machine ⇒ UNRESOLVED. Paths under `/tmp`, `/var/folders` are ephemeral by
  definition and are never refuted.
- A missing **SHA** is *never* REFUTED. It depends on which repos were searched
  and does not survive a history rewrite. When the commit *subject* still
  resolves, that is reported as the likely rewrite rather than a false claim.
- Paths inside **fenced code blocks are ignored** — `const LOG = '/tmp/x.log'`
  tells you where to write output; it does not assert the file exists.

Concepts carrying no checkable claim are listed as **unverifiable, not verified**.

## Setting up a bundle's house rules

`L2 SKIPPED — no okf-base.yaml` means house rules are not enforced. Run
`okf-check --init-house-rules <bundle>` to write a starter `<bundle>/okf-base.yaml`
(it never overwrites an existing file; nothing else ever writes it). The starter comes from
`${CLAUDE_PLUGIN_ROOT}/config/okf-base.yaml.template`, which encodes one rule
worth keeping: **`stale_after` is required, not optional.** An undated concept
cannot rot visibly, and invisible rot is what this gate exists to prevent.

Set requirements the bundle *already meets* before adding new ones. A rule that
fails on day one gets disabled on day two.

## What this does NOT do

- **Never installs silently.** A SessionStart preflight only REPORTS a missing or unsupported
  prerequisite. `okf-check --install-deps` prints the plan; `--yes` runs it (the supported okflint
  from `plugin/config/pinned-versions.txt`; `--latest` takes the newest release). Setting
  `OKF_AUTO_INSTALL=1` is your opt-in to let the preflight run the plan itself. A failed install
  puts the exact previous okflint back (a fork build comes back as a fork build). The preflight
  compares version numbers only; `--doctor` checks behaviour.
- **Never runs `okflint index --apply`.** That regenerates `index.md` as a flat
  list and would destroy a curated one.
- **Never rewrites bundle content.** It is a read-only gate; `--migrate` belongs
  to the upstream validator and is the user's call.
- **`okf-check` does not verify that claims are TRUE** — only that the bundle is
  well-formed, house-conformant and unexpired. Conformance is not correctness.
  That question has its own tool, below.
