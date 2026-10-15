---
name: okf
description: >-
  Check, gate, and maintain an Open Knowledge Format (OKF) bundle. Use when asked
  to validate, lint, or check an OKF bundle; before committing changes to one;
  when a knowledge store needs a conformance, house-rule, or staleness verdict;
  or when deciding whether a directory of markdown should become an OKF bundle at
  all. Runs a deterministic layered gate — not an eyeball pass.
user-invocable: true
argument-hint: "[bundle-dir] [--doctor | --selftest | --fail-stale | --fail-on-change | --json]"
allowed-tools: Bash
---

# OKF knowledge gate

One command over three layers. Three tools that must be remembered get remembered
zero times — that is the measured failure mode of every knowledge store that has
rotted on this machine, and the reason this is a single entry point.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" $ARGUMENTS
```

The bundle path is **required** — there is no default. Passing none exits 64 with
a usage message, and passing two is an error rather than a silent choice of one.
(An earlier draft of this document claimed `.okf/` was the default; the code has
always required the argument, and a test asserts it.)

## Closest notes in the doc-reuse reminder

If an `okf` search binary is on PATH (or `OKF_SEARCH_BIN` points to one), the doc-reuse reminder adds
`Closest existing notes (okf search): a, b, c.` Read those before writing a new note. No binary, a
slow one (2 s limit) or a failing one: the reminder is unchanged.

## Ignoring paths (`.okfignore`)

A `.okfignore` at the bundle root (one glob per line, `#` comments, trailing `/` = directories
only, no `/` = a name at any depth, a leading `**/` = any depth with the root, `!` unsupported) keeps paths such as `archive/` or `.trash/`
out of every layer, `okf-verify` included. The run prints `ignore: N file(s) excluded`; a file that
excludes every note exits 2. Never create it yourself: only `okf-check --init-ignore <bundle>`
writes it, once, on the owner's request.

## What each layer answers

| Layer | Question | Backed by |
|---|---|---|
| **L0 doctor** | can the gate run at all? | runtime + dependency + version-pin check |
| **L1 conformance** | is this valid **OKF**? | the vendored v0.2 checker (`vendor/okf_validate.py`) |
| **L2 profile** | is this valid **OUR** OKF? | `okflint` + the bundle's `okf-base.yaml` |
| **L2 index** | does `index.md` describe **this** bundle? | its own bold count declaration vs the files on disk |
| **L3 staleness** | is it **still true**? | `stale_after` compared against today (UTC), `status` checked against stable / draft / deprecated |
| **L3 derived** | has what it describes **moved since**? | `sources[].last_modified` vs the file's mtime |

L1 is the spec layer and needs no config. L2 profile is the house layer and is
**skipped — never silently passed** when `okflint` or a manifest is absent.

**L2 index** is native rather than an `okflint` rule, precisely because L2 profile
skips when `okflint` is missing — and the brand-new machine this tool targets does
not have it. It reads only a whole **bold** line as a declaration (`**47 lessons ·
3 family parents · 51 concepts.**`), so a true sentence about a subset is not
mistaken for a total, and it counts exactly what L1 counts: `index.md` and `log.md`
are reserved, `README.md` is a concept.

**L3 derived** is the measurement `stale_after` cannot make. `stale_after` is a
date somebody typed; a concept stamped 2099 reads as fresh for years after the
thing it describes changed. A concept that records `sources[].resource` with an ISO
`last_modified` (OKF v0.2 §5.1) is compared against that file's mtime instead.
Strictly opt-in: concepts with no `sources` are untouched. Non-file resources are
reported **UNMEASURABLE**, never counted as verified, and nothing touches the
network.

Both new layers are silent on bundles that make no such claim, so adopting them is
a choice, not a migration.

**What L3 staleness reads** (the same rules in `okf-check` and in the SessionStart
lessons hook, from one shared `scripts/l3-lib.sh`):

- `README.md` is a concept and is checked; `index.md` and `log.md` are reserved and skipped.
  (The lessons hook still skips `README.md` on purpose: there it is a human index.)
- CRLF files are read like LF files.
- An unquoted value loses a trailing ` # comment`; a quoted value keeps its text.
- A non-zero-padded date (`2026-9-3`) is normalised before the compare; a `stale_after`
  that is not a date at all is reported as **malformed**, never passed.
- `status` outside stable, draft, deprecated is reported.
- `OKF_L2_ISOLATE_MAX=<notes>` (default 200): when okflint crashes on a bundle this small, L2 names the crashing notes, checks the rest and exits 2 (3 when the checked notes fail).
- `OKF_L2_TIMEOUT=<seconds>` (default 120) cuts off a hung okflint in L2: exit 2, "timed out". `OKF_INSTALL_TIMEOUT` (200) bounds `--install-deps`. `OKF_AUTO_INSTALL=1` lets the session-start check install; it is off by default. `OKF_SEARCH_BIN` names the `okf` search binary; `OKF_DOC_DIRS_FILE` the extra doc-reuse locations file.
- `OKF_TODAY=YYYY-MM-DD` pins "now" (tests and replays). Any other value exits 2, and a
  valid pin prints a NOTE line so a pinned run cannot pass for a real one.
- A scan that cannot run (crashed awk, missing `l3-lib.sh`, unreadable file) exits 2
  `COULD NOT RUN`. It is never "nothing expired".

**When one note crashes a checker.**
- **The validator (L1):** the vendored copy is our patched build (PR okf-skills#68), so a `status`
  list or an impossible date no longer blank L1. If it still crashes on a note, `okf-check` names
  that note with the validator's last error line, validates the other notes from a copy (nothing
  in your bundle is touched), and exits 2 (or 1 if a real §11 error is also present).
- **okflint (L2):** a crash is NOT isolated per note. L2 prints `COULD NOT RUN` with a `reason:`
  line (okflint's last error line) and the house rules are unevaluated for the whole bundle.
  Install the patched okflint (see below) to avoid the known crashes.

**Reading the L2 summary.** A PASS line lists advisory findings grouped by okflint rule code
(`by rule: S205 x123, S202 x84, ...`), so you can see which rule family produced them.
`okf-check --doctor` also runs `okflint validate-manifest` on the shipped template
(`okflint manifest check  OK|REJECTED|UNAVAILABLE`).

**Is my okflint the patched build?** `okf-check --doctor` runs okflint on three probe
notes (a BOM note, a non-UTF-8 note, an impossible date) and prints
`okflint behaviour  PATCHED` or `UNPATCHED — fails on: ...`. A version string cannot tell
the builds apart (the patched build is also 0.5.0), so the probe checks behaviour. UNPATCHED
is advisory: L2 may report a false F001 for a BOM note, or crash on a non-UTF-8 file or an
impossible date. The fix is mattdav/okflint#11; until it merges, install the fork branch.

## Exit codes — read them, do not just check for zero

```
0  all gates pass
1  L1  OKF conformance ERROR      the bundle is not conformant OKF
2  L0  dependency missing         a gate COULD NOT RUN — never treat as a pass
                                 (includes an L3 scan that crashed or has no l3-lib.sh)
3  L2  house-rule ERROR           your own manifest rules are broken,
                                 or index.md miscounts its own bundle
4  L3  stale concepts             only with --fail-stale; covers both an expired
                                 stale_after and a recorded source that has moved
5      --selftest failure         A GATE STOPPED FIRING — the worst outcome
6      bundle changed mid-scan    only with --fail-on-change
```

`2` is distinct from `1` on purpose: "not conformant" and "could not run" must
never look alike to CI.

## Interpreting the result

- **ERROR** → a hard §11 conformance failure (unparseable frontmatter, or a
  missing/empty `type`). Fix every one.
- **warn** → soft guidance. Broken cross-links in particular are *explicitly*
  tolerated by the spec (§6.1) — they represent knowledge not yet written, not
  defects. Never "fix" a bundle by deleting an outbound link.
- **SKIPPED** → a layer did not run. This is not a pass. The summary line will
  refuse to say `ALL GATES PASS` while anything was skipped.
- **CONCURRENT** → the bundle changed while it was being scanned. The layers run
  in sequence, so the report may mix two states; it is a point-in-time reading,
  not a snapshot. Re-run when writers are idle if you need a stable answer.

## Before you trust a green run

After any dependency upgrade, run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-check" --selftest
```

It plants a known defect for each layer and requires each gate to catch it. A
gate is only verified when you have watched it fail — an upgrade that silently
stops catching what it used to is indistinguishable from a clean run.

## Setting up a bundle's house rules

`L2 SKIPPED — no okf-base.yaml` means house rules are not enforced. Start from
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

## L4 — is what it SAYS still true?

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/okf-verify" <bundle> [--repo DIR]... [--json] [--strict]
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
On the reference bundle that is 32 of 44 — a number worth knowing before treating
a corpus as evidence-backed.

## Dependencies

`python3` + `pyyaml` are required (L1). `okflint` is optional (L2) and installed
with `uv tool install okflint`. `jq` is not required. The conformance checker is
vendored, so L1 works on a fresh machine with no clone and no network.
