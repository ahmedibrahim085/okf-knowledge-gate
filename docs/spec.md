---
type: Specification
title: okf-check — use cases, stories, scenarios
description: The gate's contract as use cases, user stories and happy/negative/edge scenarios, each traced to a covering test or marked RED.
status: stable
tags: [spec, okf-check, tdd, scenarios]
generated:
  by: agent/claude-opus-5
  at: '2026-07-30'
stale_after: '2027-07-30'
---

# okf-check — specification

**Written after the first implementation, not before.** The owner caught that the
gate was built test-after with no use cases, stories or scenarios. This document
retro-specs what exists (each item traced to a passing test) and forward-specs
what does not (each marked `RED — not implemented`). The RED items are the TDD
queue: write the failing test first, then the code.

Marking this honestly matters — a spec backdated to look like it came first would
misrepresent how the code was actually verified.

---

## Use cases

| ID | Use case |
|---|---|
| **UC-1** | An agent finishing a knowledge edit needs to know, before committing, whether the bundle is still conformant OKF |
| **UC-2** | A maintainer needs to enforce *house* rules the spec does not mandate (e.g. every Lesson carries `stale_after`) |
| **UC-3** | Anyone landing on a **new machine** needs to know which dependencies are missing and the exact command to install each |
| **UC-4** | After any dependency upgrade, someone must confirm the gates still *catch* what they used to catch |
| **UC-5** | CI needs a machine-readable verdict and an exit code that distinguishes *which* layer failed |
| **UC-6** | A reader needs to know which concepts have gone stale, without that blocking unrelated work |

## User stories

- **US-1** — *As an agent about to commit a knowledge change,* I want one command that runs every check, so that I do not have to remember three tools. (Three tools that must be remembered get remembered zero times — the measured failure mode of every rotted store on this machine.)
- **US-2** — *As a maintainer,* I want house rules in a manifest rather than in code, so that changing policy does not mean editing a script.
- **US-3** — *As someone on a fresh machine,* I want the gate to tell me what is missing and, only when I ask, install the supported version, so that nothing is installed behind my back and I still do not hunt for commands. (Changed 2026-10-15, GitHub issue #4: it used to say "never to install".)
- **US-4** — *As the person who just upgraded okflint,* I want proof the gates still fire, because an upgrade that silently stops catching things is indistinguishable from a clean run.
- **US-5** — *As CI,* I want distinct exit codes, so a spec violation and a house-rule violation do not look identical.
- **US-6** — *As a reader of a report,* I never want a summary line that contradicts the body above it.

---

## Scenarios

Legend: **✅** covered by a passing test in `plugin/scripts/okf-check.test.sh` ·
**⚠** covered but conditional (states the condition) ·
**🔒** enforced by CONSTRUCTION, no runtime test is possible — the row must say why ·
**🔴** RED — specified, not implemented, no test yet.

`🔒` exists because `G-6` was marked ✅ while no test could reach it: `--selftest`
forces `JSON=0`, so the two flags cannot coexist and the defect is unreachable
from the CLI. Marking that ✅ claimed a test that cannot be written. A separate
state is honest; the alternative was a checkmark nobody could verify, which is
this document's recurring defect.

### Happy path

| ID | Scenario | Expected | State |
|---|---|---|---|
| H-1 | Conformant bundle, all deps present | exit 0, `ALL GATES PASS` | ✅ |
| H-2 | `--doctor` with everything installed | exit 0, every tool + version listed | ✅ |
| H-3 | `--selftest` with everything installed | exit 0, every probe `FIRED` | ✅ |
| H-4 | Bundle satisfies the house profile | L2 `PASS`, exit 0 | ✅ |
| H-5 | Nothing expired | L3 `PASS` | ✅ |
| H-6 | `--version` | exit 0 | ✅ |

### Negative path

| ID | Scenario | Expected | State |
|---|---|---|---|
| N-1 | `.md` with no frontmatter | exit 1, cites §11.1 | ✅ |
| N-2 | Frontmatter with empty/whitespace `type` | exit 1, cites §11.2 | ✅ |
| N-3 | Lesson missing `stale_after` (house rule, **not** a spec violation) | exit **3**, cites `F102` — proves L1 and L2 are different layers | ✅ |
| N-4 | `status` outside the manifest vocabulary | exit 3, cites `F105` | ✅ |
| N-5 | No bundle argument | exit 64 | ✅ |
| N-6 | Unknown flag | exit 64 | ✅ |
| N-7 | Bundle path is not a directory | exit 64 | ✅ |
| N-8 | Expired `stale_after`, default | reported, exit 0 (advisory) | ✅ |
| N-9 | Expired `stale_after`, `--fail-stale` | exit 4 | ✅ |
| N-10 | okflint absent | L2 SKIPPED with install command; **never a silent pass** | ✅ |
| N-11 | No `okf-base.yaml` | L2 SKIPPED naming the template | ✅ |
| N-12 | Any layer skipped | summary must NOT read `ALL GATES PASS` | ✅ |
| N-13 | `pyyaml` missing | doctor exit 2, names the install command; a check REFUSES to run | ✅ |
| N-14 | `python3` missing entirely | doctor exit 2, names the install command | ✅ |
| N-15 | Manifest present but malformed | L2 `COULD NOT RUN`, exit 2 — not a pass | ✅ |
| N-16 | okflint version differs from the pin | doctor reports VERSION-SKEW, advises `--selftest` | ✅ |

**N-13/N-14 found a real defect when written RED-first.** `doctor` returned a bare
`1` on a missing dependency — but `1` is `EXIT_CONFORM`, so CI could not distinguish
*"the bundle is not conformant"* from *"the gate could not run at all"*. That is
precisely the confusion the layered exit codes exist to prevent, and it survived
every earlier green run because no test had ever removed a dependency.

### Edge cases

| ID | Scenario | Expected | State |
|---|---|---|---|
| E-1 | Bundle directory containing zero `.md` files | exit 0, `0 concepts` — not a crash | ✅ |
| E-2 | **Bundle path containing a space** | works — every expansion quoted | ✅ |
| E-2b | Spaced path still **DETECTS** staleness | mutation-proven, not merely exit 0 | ✅ |
| E-3 | Binary / non-UTF-8 `.md` | per-file error, whole run does not crash | ✅ |
| E-4 | `--json` output | is valid parseable JSON | ✅ |
| E-5 | Invoked through a symlink (plugin install layout) | resolves `plugin/vendor/` correctly | ✅ |
| E-6a | Bundle path is itself a symlink | followed, not rejected | ✅ |
| E-6b | A **symlinked concept file** inside the bundle | L1 and L3 must agree it exists | ✅ |
| E-7a | Broken symlink (file vanished between listing and read) | skipped, no crash | ✅ |
| E-7b | Unreadable / locked concept | fails **CLOSED**, never a silent pass | ✅ |
| E-7c | Half-written file (another agent mid-write) | fails CLOSED with §11.1 | ✅ |
| E-7d | Bundle **changes during** the scan | reported as a point-in-time reading | ✅ deterministic — injected via a `stat` shim, no longer races |
| E-7d2 | ...and `--fail-on-change` is set | exit 6, proven reachable | ✅ |
| E-7d3 | control: a stable bundle | must NOT be reported as changed | ✅ |
| E-8 | `stale_after` unquoted (YAML parses it as a date object) | compares correctly | ✅ |

### L2 index — does `index.md` describe this bundle? (0.4.1)

`index.md` is the only file that asserts a fact ABOUT the bundle, and nothing
verified it. On `~/.claude/lessons` it claimed 43 lessons, then 0 lessons in every
family, and the gate exited 0 for both; the finished rule found it wrong a third
way — 48 claimed against 47 on disk, because every hand count followed table ROWS
and one lesson is deliberately cross-listed under two families.

Native rather than an `okflint` rule: L2 profile SKIPS entirely without `okflint`,
and the brand-new machine this tool targets does not have it.

| # | Scenario | Expected | Status |
|---|---|---|---|
| I-1 | index states no counts | left alone, exit 0 | ✅ |
| I-2 | a correct bold declaration | exit 0 | ✅ |
| I-3 | index overstates its own bundle | exit 3, names claimed AND actual | ✅ |
| I-3d/e | exactly one concept on disk | reads "1 on disk", never "1 are on disk" | ✅ |
| I-4 | `README.md` present with frontmatter | counted as a concept, exactly as L1 counts it | ✅ |
| I-4b | index forgets `README.md` | exit 3 — off by one is still wrong | ✅ |
| I-5 | a concept cross-listed under two families | counted once, not twice | ✅ |
| I-6 | `type: Lesson Family` alongside `type: Lesson` | exact match only; a family is not a lesson | ✅ |
| I-7 | "Three families cover 37 of the 48 lessons" in prose | a subset sentence is not a total | ✅ |
| I-7b | digit-bearing prose ABOVE a wrong declaration | still exit 3 — proves the rule did not silently skip | ✅ |

### L3 value parsing and gate integrity (0.5.2 - 0.5.8)

| # | Scenario | Expected | Status |
|---|---|---|---|
| LT-01 | `README.md` with an expired `stale_after` | listed as expired (README is a concept; index.md and log.md stay skipped) | ✅ |
| LT-02 | CRLF note, expired | listed as expired by L3 | ✅ |
| LT-02b | CRLF note read by the lessons hook | parsed, expiry reported, not "missing frontmatter" | ✅ |
| LT-03a | `status: stable  # ok` | the comment is not part of the value | ✅ |
| LT-03b | `stale_after: "2026-9-3"` (not zero-padded) | normalised to 2026-09-03 and compared as a date | ✅ |
| LT-03c | `status: "stable # x"` (quoted hash) | value kept whole, reported as a status finding | ✅ |
| LT-03d | `stale_after: soon` | reported as `malformed`, never a silent pass | ✅ |
| LT-03e | `stale_after: 2000-01-01  # review` | comment stripped, expiry reported | ✅ |
| LT-03f | hook: `status: stable  # ok` | no status finding | ✅ |
| LT-03g | hook: quoted value with ` #` | kept whole | ✅ |
| LT-03h | hook: non-padded date | normalised and flagged | ✅ |
| LT-03i | hook: `stale_after: soon` | reported as not a date | ✅ |
| LT-03j | `stale_after: 2026-9-3T00:00:00Z` | date prefix normalised, instant kept, flagged | ✅ |
| LT-04a | `l3-lib.sh` missing | exit 2, never "PASS nothing expired" | ✅ |
| LT-04b | `OKF_TODAY=zzz` | exit 2 (value must be YYYY-MM-DD); a valid pin prints a NOTE line | ✅ |
| LT-05 | the L3 awk/xargs scan exits non-zero | exit 2 `COULD NOT RUN`, never PASS | ✅ |
| LT-06a | exported `CDPATH`, relative script path | same verdict as without CDPATH | ✅ |
| LT-07a | hook run through a symlink | still reports expiries | ✅ |
| LT-07b | hook under exported `CDPATH` | still reports expiries | ✅ |
| LT-08a | hook, `status: draft` / `deprecated` | accepted (same list as okf-check) | ✅ |
| LT-08b | hook, `status: weird` | reported (guards over-flagging only) | ✅ |
| LT-08c | hook label | no claim of "not marked stable" for a list that allows draft | ✅ |
| LT-09a | a note makes the vendored validator crash (status list, impossible date) | exit 2, never a pass | ✅ |
| LT-09b | same (stub validator crashes on a marker) | the first note is named with the validator's last error line | ✅ |
| LT-09c | same | the second note is named with the validator's last error line | ✅ |
| LT-09d | same | the other notes are still validated and counted | ✅ |
| LT-09e | crash plus a real §11 error elsewhere | exit 1 (a reached verdict outranks a gate that could not run) | ✅ |
| LT-11a | impossible date in a note, vendored (patched) validator | a per-file L1 error naming the note, not a crash | ✅ |
| LT-11b | status list and impossible date in the same bundle | L1 reaches a verdict, never COULD NOT RUN | ✅ |
| LT-12a | okflint rejects a BOM note (#8; stock 0.3.1 / 0.5.0) | doctor prints `okflint behaviour  UNPATCHED — fails on: a BOM note (#8)` with the fix pointer | ✅ |
| LT-12b | okflint passes the BOM, non-UTF-8 and impossible-date probes (patched build) | doctor prints `okflint behaviour  PATCHED` | ✅ |
| LT-12c | patched okflint | no UNPATCHED line | ✅ |
| LT-12d | UNPATCHED okflint | doctor is advisory: exit 0 | ✅ |
| LT-12e | okflint crashes on a non-UTF-8 note (#9) | doctor prints UNPATCHED naming a non-UTF-8 note | ✅ |
| LT-12f | okflint crashes on an impossible date (#10) | doctor prints UNPATCHED naming an impossible date | ✅ |
| LT-13a | okflint returns advisory findings with several rule codes | L2 PASS adds `by rule: S208 x2, S209 x1` (top six, most frequent first) | ✅ |
| LT-13b | okflint has `validate-manifest` and accepts the shipped template | doctor prints `okflint manifest check  OK` | ✅ |
| LT-13c | `validate-manifest` rejects the template | doctor prints REJECTED with okflint's last line | ✅ |
| LT-13d | okflint without `validate-manifest` (< 0.4.0) | doctor prints UNAVAILABLE, not an error | ✅ |
| LT-13e | REJECTED template | advisory: doctor exits 0 | ✅ |
| LT-13f | more than six advisory rule codes | the by-rule line ends with `(+N more codes)` | ✅ |
| LT-12g | okflint gives no verdict on a clean control note | doctor prints UNKNOWN with a reason, never UNPATCHED | ✅ |
| LT-12h | shipped template missing | doctor prints UNKNOWN naming the template; probes skipped | ✅ |
| LT-14a | a symlinked directory inside a crashing bundle | files outside the bundle are never deleted | ✅ |
| LT-14b | bundle path with a trailing slash | crash isolation still names the note | ✅ |
| LT-14c | note name with `|` and spaces | printed intact in the crash report | ✅ |
| LT-15a | okflint hangs | a normal run is not stalled (probes run only under --doctor) | ✅ |
| LT-15b | okflint hangs | `--doctor` is bounded (each probe has a timeout) | ✅ |
| LT-16 | SIGTERM during a run | okf-check stops with exit 143 | ✅ |
| LT-17a | okflint present at the supported version | `--preflight` prints nothing | ✅ |
| LT-17b | okflint missing | preflight names it and the one command to fix it | ✅ |
| LT-17c | okflint at an unsupported version | preflight names the found and the supported version | ✅ |
| LT-17d | `--install-deps` without `--yes` | prints the plan, installs nothing, exit 0 | ✅ |
| LT-17e | `--install-deps --yes` | installs the pinned supported source | ✅ |
| LT-17f | the install fails | exit 2 and the previous okflint is reinstalled | ✅ |
| LT-17g | `--install-deps --yes --latest` | installs the newest release, not the pin | ✅ |
| LT-17h | okflint missing, `OKF_AUTO_INSTALL` unset | preflight never installs | ✅ |
| LT-17i | `OKF_AUTO_INSTALL=1` | the preflight runs the install | ✅ |
| LT-17j | `uv` missing | exit 2 naming uv; never a silent pass | ✅ |
| LT-17k | the install fails | the message carries the installer's real exit code | ✅ |
| LT-17l | pinned source that reads as an option (`--index-url=...`) | refused, exit 2, nothing installed | ✅ |
| LT-17m | pins file unreadable | the install is refused; it never falls back to an unpinned release | ✅ |
| LT-17n | the installer hangs | stopped after `OKF_INSTALL_TIMEOUT` seconds (default 200), exit 2, previous okflint put back | ✅ |
| LT-17o | `--install-deps --json` | the plan and result are still printed | ✅ |
| LT-17p | `--help` | lists --preflight, --install-deps, --yes, --latest and OKF_AUTO_INSTALL | ✅ |
| LT-17q | preflight finds a problem | the fix command is printed with the full path to `okf-check`, runnable as printed | ✅ |
| LT-17r | same version number, stock build (rejects a BOM note) while a source is pinned | preflight names the stock build | ✅ |
| LT-17s | patched okflint at the supported version | preflight is silent | ✅ |
| LT-17t | auto-install fails | preflight still exits 0: it never fails the session | ✅ |
| LT-17u | `--latest` | the plan warns that PyPI okflint may lack the okflint#11 fixes | ✅ |
| LT-17v | `--install-deps` | the plan reports jq (optional) | ✅ |
| LT-18a | new `.md` under a default location (`docs/`) | the doc-reuse reminder still fires | ✅ |
| LT-18b | new `.md` under a personal location, no config file | silent: nothing personal is built in | ✅ |
| LT-18c | glob listed in `~/.config/okf/doc-dirs` (`OKF_DOC_DIRS_FILE`) | the reminder fires | ✅ |
| LT-18d | config file unreadable or malformed | the guard stays silent and exits 0 (fail-open) | ✅ |
| LT-18e | the guard source | contains no personal path or vault name | ✅ |
| LT-19a | a search binary lists matches | the reminder names the three closest notes, no more | ✅ |
| LT-19b | no search binary | the reminder is exactly the plain text | ✅ |
| LT-19c | the binary hangs | killed at 2 s, back within 3 s; plain reminder | ✅ |
| LT-19d | the binary fails | plain reminder, exit 0 | ✅ |
| LT-19e | the target directory is a symlink | the search runs on the real path | ✅ |
| LT-19f | any new file | the query is the words of the file name | ✅ |
| LT-19g | output captured from the real okf binary | parses to the three closest ids | ✅ |
| LT-19h | the search binary hangs and has a child | no orphan child is left | ✅ |
| LT-19i | the binary has a grandchild | no orphan grandchild is left | ✅ |
| LT-20a | a bundle with an ignorable note and no `.okfignore` | behaves as before (the note fails the gate) | ✅ |
| LT-20b | `.okfignore` lists `.trash/` and `archive/` | those notes are absent from L1, L2, L3 and L3 derived | ✅ |
| LT-20b2 | the layers read a filtered copy | the report never shows the temp path | ✅ |
| LT-20c | `.okfignore` present | the run states how many files were excluded; `--json` carries `ignored` | ✅ |
| LT-20d | `.okfignore` excludes every note | reported, exit 2, never a pass | ✅ |
| LT-20e | a full run | never creates `.okfignore` | ✅ |
| LT-20f | `--init-ignore` | writes a starter once, refuses to overwrite (exit 1) | ✅ |
| LT-20g | patterns: anchored, name, dir-only, comment, CRLF, `!` | matched as documented; negation skipped with a notice | ✅ |
| LT-20h | a symlinked directory in the bundle | a no-op `.okfignore` gives the same verdict as none (same file set) | ✅ |
| LT-20i | a note cannot be copied | not dropped silently: no pass | ✅ |
| LT-20j | only index.md and log.md remain | reported, exit 2 | ✅ |
| LT-20k | `.okfignore` is a symlink | `--init-ignore` refuses | ✅ |
| LT-20l | L2 index counts | skip ignored notes | ✅ |
| LT-20m/n | L3 derived | still resolves sources against the real bundle; skips ignored notes | ✅ |
| I-1c | `okf-verify`, everything excluded | exit 2 | ✅ |
| LT-21 | okflint hangs in L2 | cut off after `OKF_L2_TIMEOUT` (default 120 s), named, exit 2 | ✅ |
| LT-21b | `OKF_L2_TIMEOUT=0` | falls back to the default; never an instant kill | ✅ |
| LT-21c | a normal run | leaves no timer `sleep` behind | ✅ |
| LT-21d | okflint ignores TERM | still reported as timed out | ✅ |
| LT-20p | `.okfignore` that excludes nothing | same verdict and exit as no file (also with notes behind a symlinked dir) | ✅ |
| LT-20q | `**/x.md` | also matches `x.md` at the bundle root | ✅ |
| LT-20q2 | `/**/x.md` | behaves like `**/x.md` | ✅ |
| LT-20r | only non-note files excluded | never reports "excludes every note" | ✅ |
| LT-22 | status vocabulary in the template and in l3-lib | equal as sets | ✅ |
| LT-23 | user-facing env variables | documented in README and SKILL.md | ✅ |
| I-1a/b | `okf-verify` on a bundle with `.okfignore` | an ignored note's claims are not verified | ✅ |
| LT-10 | okflint crashes on a note (non-UTF-8) | L2 prints a `reason:` line with its last error line; skipped, stated, when okflint is absent | ✅ |

### L3 derived — has what the concept describes moved since? (0.5.0)

`stale_after` is a date somebody typed. A concept stamped 2099 reads as fresh for
years after the artefact it describes changed. OKF v0.2 §5.1 already models the
measurement and nothing used it: `sources[].resource` with an ISO `last_modified`.
Strictly opt-in — a bundle with no `sources` behaves exactly as before.

| # | Scenario | Expected | Status |
|---|---|---|---|
| D-1 | recorded source older than the concept | not stale | ✅ |
| D-1b | source modified ON the recorded date | not stale — same day is not "changed since" | ✅ |
| D-2 | source modified after the concept, `stale_after` 2099 | exit 4 with `--fail-stale`; only the derived check can see this | ✅ |
| D-2c | same bundle without `--fail-stale` | advisory, exit 0 | ✅ |
| D-3 | `resource` is a URL | never judged stale; no network access | ✅ |
| D-3b | the same URL source | reported UNMEASURABLE, never silently verified | ✅ |
| D-4/4b | source with no `last_modified` | no finding at all — "undated" is not "unmeasurable" | ✅ |
| D-5 | concepts with no `sources` | completely untouched | ✅ |

**E-6 split into a non-bug and a real defect once probed.** The bundle-as-symlink
case already worked. The *symlinked concept file* did not: `find -type f` does not
match a symlink, so L1 (python `is_file()`, which follows) counted a concept that
L3 never saw — and an expired concept read as *"nothing expired"*. Fixed with
`find -L` in both the gate and the standalone hook. Same class as
`readdir-symlink-dirent-trap.md`, in bash instead of Node.

**E-7d is the live condition, and it was reproduced 3/3.** On a 40-concept bundle
a file written 0.20 s into the run was counted by L3 and missed by L1: one report
built from two bundle states, presented as a stable verdict. The layers cannot be
made atomic against another agent's writes — so the fix is to *detect and say so*
(fingerprint before/after), not to pretend otherwise.

**The TEST no longer races.** Reproducing the condition and *testing* it are
different problems: the race above is what the gate must survive, but a suite
that waits for a race is a suite whose coverage comes and goes. The condition —
two differing fingerprints — is injected with a `stat` shim, so the assertion
runs every time. That also made two previously impossible assertions available:
that exit 6 is reachable at all, and that a stable bundle is not reported as
changed.

**E-2 is not hypothetical.** A `for f in $(find …)` over a vault directory with spaces in its name (`My Vault/Getting Started/`)
word-split 147 files into 170 this same session and produced two published-then-retracted
statistics. The gate walks user-named paths; it must be proven against a spaced path.

---

## Traceability

- Implementation: `plugin/scripts/okf-check`, `plugin/scripts/okf-verify`
- Behaviour tests: `plugin/scripts/okf-check.test.sh`
- Truth-lane tests: `plugin/scripts/okf-verify.test.sh`
- Package tests: `plugin/scripts/plugin.test.sh`, ending in
  `claude plugin validate --strict` for BOTH the plugin and the marketplace
- Gate-fires-at-all: `okf-check --selftest`

**No test counts are recorded here, deliberately.** They drifted three separate
times — this document said 40, then 49, then 69, while the suite was at 52, 52
and 84. A number that must be hand-updated on every commit is a number that will
be wrong, and a reviewer then has to spend time proving a stale figure is merely
stale rather than fabricated. **Run the suites; they print their own totals.**

The same applies to live-fire figures. A snapshot of `okf-verify` output against
`~/.claude/lessons` is perishable by construction — that bundle is written by
other sessions and grew from 44 to 46 concepts during this review, and the result
also depends on which `--repo` set is passed. Any figure quoted in this repo is a
dated observation, never a reproducible expectation.

## Independent adversarial review — 2026-07-31

Three reviewers were run against this work. Their verdicts are recorded here
because two of them **refuted claims this document previously asserted**.

| Claim as written | Verdict |
|---|---|
| "Exit codes are unambiguous; a dependency failure can never be confused with a conformance failure" | **REFUTED** — `max(rc)` returned 2 for a bundle with a real §11 error plus a bad manifest |
| "The summary can never print ALL GATES PASS when a layer was SKIPPED or an advisory fired" | **REFUTED (advisory half)** — L1/L2 warnings never incremented the counter |
| "UNRESOLVED is never conflated with REFUTED" (L4) | **REFUTED** — three routes produced unchecked claims rendered as false |
| "Every test would fail if its behaviour were reverted" | **REFUTED** — 9 mutants survived a fully green suite |
| "`plugin.test.sh` assertions are real" | **REFUTED** — 2 of 16 were inert |
| "Every ✅ row has a real covering test" | **REFUTED** — 12 rows had none |
| "SKILL.md matches the code" | **REFUTED** — it documented a `.okf/` default the code never had |
| "Never installs anything unasked, never mutates the bundle" | CONFIRMED (install only with `--install-deps --yes` or the `OKF_AUTO_INSTALL=1` opt-in; rows LT-17) |
| "L1 works with no okflint, jq or uv" | CONFIRMED — **but PyYAML is NOT vendored**, so on a stock machine L1 still needs it |

Two CRITICALs where **L2 failed open** were found and fixed: a crashed okflint
(exit 127, or a signal) reported `L2 PASS`, and error detection was an emoji grep
that missed every finding from a differently-formatted okflint — the exact
VERSION-SKEW the doctor warns about. L2 now parses okflint's `--json` and treats
any undocumented exit status as COULD NOT RUN.

**The worst finding was self-inflicted.** The commit titled "6 defects fixed"
introduced a rule requiring SHAs to contain a digit — which silently made V-4's
fixture (`deadbee`) stop parsing as a SHA at all. All four assertions guarding
L4's central rule passed *vacuously*, and this document's claim that the rule was
"mutation-proven" became false. A fix in one place disarmed the test protecting
another.

### Reviewer findings — resolution

All of these were **closed** in `1314fcb`, and this section previously still
listed them as open. A spec that asserts bugs which no longer exist is the same
propagation defect as one that hides bugs which do — caught by the ultra-review
audit, which is exactly what that audit is for.

| ID | Finding | State |
|---|---|---|
| `D-6` | an unclosed fence silently blinds a concept | fixed — reported as UNRESOLVED naming the concept |
| `D-8` | commit URLs never extracted | fixed — `/commit/<sha>` and `/commits/<sha>` |
| `D-9` | `--strict` passed a wholly-uncheckable corpus | fixed — an unverifiable concept now fails `--strict` |
| `M6` | verify suite not relocatable (fixtures anchored on `$HERE`) | fixed — picks a non-ephemeral base; verified from a `/var/folders` copy |
| `D-10` | concepts keyed by basename | fixed — bundle-relative paths |
| `P-8` | plugin validated but never installed | **installed** — `okf@ahmedmaged-okf`, verified from its cache path |
| — | PyYAML not vendored | vendored, pure-python; covered by `N-17` |

### Genuinely still open

- **GNU `stat`** is exercised only through a stub. Never run against real
  coreutils on Linux. Both branches exist; only the BSD one is proven.
- ~~**The plugin's hooks have not fired.**~~ **Closed** — both were live-fired
  against the *installed* copy with real payloads. The `SessionStart` hook named
  an expired concept in valid `hookSpecificOutput` JSON; the `PreToolUse` guard
  fired on a new file in a guarded location and stayed silent for an existing
  file and for a non-`.md` path, both negative legs runtime-proven. Doing this
  is what exposed `P-11` below — the installed copy was seven fixes stale.
  (An earlier probe of mine showed nothing because it wrote to an *existing*
  path, which the guard skips by design. The probe was wrong, not the hook —
  worth recording, because "the hook did nothing" was the wrong conclusion.)
- ~~**Three assertions can SKIP without failing.**~~ ~~`E-7d`, `G-1b`,
  `N-17`.~~ **Closed.** Counting the skips made the loss visible; it did not fix
  it, and stopping there left the coverage exactly as conditional as before,
  only better labelled. All four conditional skips are now deterministic and the
  suite reports **0 skipped** — verified over 8 consecutive runs, on BSD and on
  GNU coreutils + findutils.
  - `E-7d` / `G-1b` raced a background writer. The race was never the behaviour
    under test: what the gate must do is notice that the bundle it fingerprinted
    *before* the layers is not the one it fingerprints *after*. A `stat` shim
    appending one line on the second fingerprint call injects that with
    certainty. `E-7d` also gained the two assertions the race had made
    impossible — that exit 6 is reachable at all, and that a stable bundle does
    not trip it.
  - `T-1` raced a `chmod`, and its mutation never fired: the racer reliably
    landed *after* the layers, where the re-check catches it and the unfixed
    code shows no symptom. A `find` shim now makes the second directory walk
    report an unresolvable path — the state a mid-scan `chmod` produces — while
    the first walk stays clean, so the up-front guard is not what fires.
  - `N-17` skipped wherever `python3 -S` still reached a yaml. A blocker module
    on `PYTHONPATH` shadows the SYSTEM copy without shadowing the vendored one,
    because `okf-check` prepends its vendor directory and Python takes the first
    match. It must be APPENDED — prepending broke the vendored import too and
    failed all four assertions, which is what demonstrated the test's teeth.

  No production surface was added for any of this. The shims live in the test
  and are reached through `PATH`, the technique the okflint tests already use.

  **Quote `0 failed` AND `0 skipped`.** Both are now achievable, so neither is
  an excuse. A suite total is still not evidence.

### Regressions found by reviewing the fixes (G-*)

A second review round took the two commits that closed the findings above as its
subject, and found that **five of them had shipped new defects**. Every one
landed with a green suite. That is the finding worth keeping: a green suite
proves the cases someone thought to write, and a fix is exactly the moment
nobody has thought of the new ones yet.

| ID | Regression | Introduced by | State |
|---|---|---|---|
| `G-1` | `--fail-on-change` compared exit codes numerically, re-opening `R-4` | the commit that fixed `R-4` | ✅ |
| `G-2` | `export PYTHONPATH` put the vendored pure-python PyYAML in front of okflint's compiled one | the PyYAML vendoring commit | ✅ |
| `G-3` | `--fingerprint` never received the `R-6` fail-closed guard added beside it | the commit that added both | ✅ |
| `G-4` | a non-list okflint body, or a finding with no `severity`, produced a false PASS | the `--json` parsing commit | ✅ |
| `G-5` | `raw.find("[")` took a bracket from okflint's banner as the JSON body | same | ✅ |
| `G-6` | selftest's failure dump bypassed `say()` — inert only because the dispatch forces `JSON=0` | pre-existing, latent | 🔒 |
| `G-7` | the vendored PyYAML pin lost to any `yaml` already on `PYTHONPATH` | the `G-2` fix | ✅ |

`G-7` deserves its own note: `VENDOR.md` claimed appending to `PYTHONPATH` let a
system PyYAML win. Measured, that was **false in both directions** — Python
searches all of `PYTHONPATH` before `site-packages`, so the system copy never
won; and append lost to entries already in the variable, so a `yaml` module
inherited from the environment replaced the parser the verdict rests on. A decoy
that calls every file conformant turned a bundle with no `type` key into a PASS.
The pin now prepends. `VENDOR.md` records the refuted claim rather than quietly
replacing it.

| ID | Scenario | Expected | State |
|---|---|---|---|
| G-1 | `--fail-on-change` + a conformance error on a stable bundle | exit 1 | ✅ |
| G-1b | conformance error AND a mid-scan change | exit 1, not 6 | ✅ deterministic — same shim |
| G-2 | a child process (okflint) under okf-check | must NOT load the vendored PyYAML | ✅ |
| G-3 | `--fingerprint` on an unreadable directory | fails CLOSED | ✅ |
| G-4a | okflint emits a non-list JSON body | never `L2 PASS` | ✅ |
| G-4b | a finding with no `severity` key | still fails; okflint's exit 1 is authoritative | ✅ |
| G-5 | a `[` in okflint's banner | JSON body still found | ✅ |
| G-7 | a decoy `yaml` on `PYTHONPATH` | the pin holds; bundle still fails | ✅ |
| D-11 | a case-variant path on a case-insensitive filesystem | UNRESOLVED, never CONFIRMED | ✅ |
| D-12 | `` `path' `` — mismatched delimiters | not a path claim; no manufactured REFUTED | ✅ |
| D-13 | more than 8 concepts with no checkable claim | says how many it withheld | ✅ |
| P-9 | the three version fields disagree | caught — `update` keys off that value | ✅ |
| P-10 | the DEPLOYED scripts differ from this tree | caught, naming the drifted file | ✅ |

### Sibling sweep — the same six classes, elsewhere (G-8..G-13)

Fixing seven defects is not the same as fixing seven *classes*. A sweep asked,
for each class, "where else does this shape appear?" — and the first answer was
worse than anything in the round that prompted it.

| ID | Sibling of | Defect | State |
|---|---|---|---|
| `G-8` | `G-3` fail-open | R-6 guarded the bundle ROOT only; `find … 2>/dev/null` swallowed an unreadable SUBTREE — `ALL GATES PASS`, exit 0, over a directory hiding a concept expired since 2000 | ✅ |
| `G-9` | `G-4` trusted shape | L1 read `d.get("errors",[])`, so valid JSON of the wrong shape became "0 errors" and PASS | ✅ |
| `G-10` | `R-3` `--json` | `--fingerprint --json` printed raw `size mtime path` lines, exit 0 | ✅ |
| `G-11` | `D-13` silent cap | four dumps cut at 10–12 lines with no note of the cut | ✅ |
| `G-12` | `G-2` unscoped export | `export OKF_L3_ROOT` leaks to every later child; latent, no consumer today | ✅ |
| `G-13` | `G-8` | `okf-verify`'s `rglob` skipped an unreadable subtree — a REFUTED claim vanished and it printed *"no refuted claims"*, exit 0 | ✅ |

`G-13` is the one to remember. The layer whose entire purpose is separating
*checked and false* from *nobody checked* reported neither, and looked clean
doing it — a partial scan presented as a verdict, which is precisely what
`UNRESOLVED` was invented to prevent.

**The G-8 fix broke `R-7` before it shipped.** Reading the directory list
newline-delimited split a directory whose *name* contains a newline into
fragments, so every such bundle was declared unreadable and failed closed.
`R-7` exists for exactly that scenario and caught it. NUL-delimited now — and
worth recording, because it is the third time in this arc that a fix produced
the next defect.

**`G-9`'s test survived reverting one guard.** Two independent mechanisms now
produce the fail-closed outcome (missing key, non-numeric count), so removing
either alone still passes. Its teeth were proven by removing both — defence in
depth, not a tautology, and the difference is worth checking rather than
assuming.

### Adversarial review of `tools/` — it began by finding no tests

The review opened by establishing that two of the four new scripts —
`install-git-hooks.sh` and `install-dev-deps.sh` — had **no test files at all**,
and then found the two worst defects of the session in the untested one that
edits `.git/hooks`. Rarely run and destructive when it is, is the worst
combination available.

| finding | severity |
|---|---|
| `refresh-graphs.sh` had no timeout — a hung tool blocks `git commit` **forever** | HIGH |
| `--uninstall` **deleted a foreign hook** whose comment merely quoted the marker | HIGH |
| a read-only hooks dir printed `installed` and exited 0 with nothing written | HIGH |
| `GUARDED` detection pinned one exact English phrase | HIGH |
| a symlinked index dir read as empty and was never refreshed (BSD `find` needs `-L`) | MEDIUM |
| an unreadable index dir gave the same message as a genuinely empty one | MEDIUM |

**Hanging is worse than failing, and my own verification missed it.** I had
tested ten ways `refresh-graphs.sh` could exit non-zero, found none, and
reported that as proof of hook safety. I never tested a tool that simply does
not return. A fast failure is visible; a hang looks like the machine froze.

**The fix could not use `gtimeout`.** Stock macOS ships neither `timeout` nor
`gtimeout` — they arrive with GNU coreutils — so on the exact brand-new machine
this project exists to serve there is nothing to bound with, and "we use
gtimeout" would have been an unbounded hook wearing a safety belt. There is a
portable fallback: background, poll, TERM then KILL, return 124.

**Ownership is structural now.** The marker had been matched anywhere in the
file, so a hook that *mentioned* the marker in a comment was treated as ours and
deleted. Mentioning a name is not bearing it; a substring match cannot tell a
claim of authorship from a reference to it. The marker must be the second line.

**`GUARDED` is decided by STATE, not wording.** Grepping `refusing to overwrite`
pins one phrase from one tool's current release; any reworded refusal reverts to
`FAIL — index left STALE`, the exact inversion the code's own comment forbids.
The detector now asks what is observable: non-zero exit, index still readable,
index unchanged ⇒ nothing was damaged. `G-2` exists so that state test cannot
swallow a real failure.

### The tools' own hard properties, measured

`refresh-graphs.sh` runs from a git hook, so its one inviolable property is that
it can **never** exit non-zero — a single non-zero exit breaks the user's
commits. Asserted against ten adversarial inputs rather than reasoned about:
unreadable index dir, `chmod 000`, index path that is a FILE, index path that is
a broken symlink, repo path containing a space, repo path containing a NEWLINE,
empty `graph.json`, no indexes at all, a tool exiting 3, and a tool that SIGKILLs
itself. **0 non-zero exits.**

`count_nodes` was fed malformed indexes — truncated JSON, `{"nodes": null}`, an
empty file, non-JSON text, an absent file, and 200 bytes of `/dev/urandom` as a
sqlite database. Every case degrades to *"node count not readable here"*: no
false shrink, no invented count. That matters because a fabricated count would
either raise a false alarm or, worse, hide a real one.

**Known residual:** an index that is never readable reports `ok` on every sweep
forever — a permanent blind spot wearing the shape of success. Not live today
(0 occurrences in the last full run) and recorded rather than left implicit.

### The graph sweep — where a lesson changed the outcome

The standing instruction is that the four code-knowledge tools stay current. The
first sweep ran across ~86 indexes and reported `ok` for 85 of them **on exit
status alone**.

`lessons/index-refresh-shrink-is-corruption.md` says that cannot work: a stale
incremental cache exits 0 and returns well-formed data about the WRONG FILES, as
a delta small enough that nobody questions it. It was surfaced by the router at
the moment those results were about to be accepted.

Rebuilt to read each index's own node count before and after. It immediately
caught **three shrinks the first sweep had called `ok`**:

| repo | before → after |
|---|---|
| `easy_talk` | 5274 → 5270 (−4) |
| repo A (large starter project) | 615 → 561 (−54) |
| repo B (large monorepo) | 4886 → 4880 (−6) |

The lesson's own documented instance was **−7 and 100% artefact**. These are the
same shape: believable, unremarkable, invisible to an exit code.

**Investigated per the lesson's protocol rather than assumed.** No commit
removed the code (protocol 1). On a COPY with the cache deleted, graphify is
perfectly deterministic — 504 nodes on three consecutive runs — while the live
index reported 615 then 561, matching neither. Two runs of the same tool on
unchanged source disagreeing is the cache signature, not a refactor.

**`--force` is not used to make a shrink go green.** The lesson's protocol 5 is
explicit that the guard is the only thing between a silent corruption and a
published one; the remedy is to re-extract from a fresh cache and accept
whatever honest number appears, not to raise the threshold.

#### The sweep's own three defects, all found by using it

- **Its summary lied**: counters incremented inside `( cd "$r" && … )` subshells
  died with the subshell, so it read `refreshed 0, failed 0` after 85 refreshes
  and 2 failures — a summary contradicting its own body.
- **A test vanished instead of failing**: `${$((t1-t0))}s` is a bad
  substitution, so the assertion errored and neither passed nor failed.
- **The sweep was piped through `tail -40`**, which buffered every line and
  masked the exit code — `pipeline-exit-masking.md`, committed by the person who
  had just cited that lesson.

### The four items that were open when completion was announced

Completion was announced twice while items were open — once with fixed work
presented in a "findings" table, and once with three race-dependent tests
listed as remaining. Making debt visible is not closing it, and a message that
says *complete* while listing what is not complete is self-contradicting.

| # | Item | Outcome |
|---|---|---|
| 1 | intermittent multi-failure in `okf-verify.test.sh` | **root-caused and fixed** — `Z-11` |
| 2 | three dependency-gated skips on a bare machine | one-command bootstrap; Linux unaffected |
| 3 | the post-merge graph refresh, instructed and unimplemented | **implemented** — `tools/refresh-graphs.sh` |
| 4 | `plugin` skips `claude plugin validate` without the CLI | artefact of the isolation test, not a real gap |

**`Z-11` is the one that matters, and it was never machine load.** Three review
sightings and forty-odd unreproduced runs blamed timing. The diagnostic snapshot
caught it on attempt 36 and answered it in one line: the concept carried *no
checkable claim*, with a fixture SHA of `6476367` — all digits.
`sha.isdigit()` rejected it. A 7-character abbreviation is all digits with
probability (10/16)^7 ≈ **3.7%**, so about one repository in twenty-seven
produced a SHA the tool refused to see. The rule's own comment does the
arithmetic for the *no*-digit case (0.1%) and never did it for this one, which
is 37× more likely.

It was never only a test flake: **in production it silently dropped roughly one
real abbreviated-SHA citation in twenty-seven**, reporting the concept as
carrying nothing checkable. A verification tool quietly declining to verify is
the worst shape this could take. The disambiguator is CONTEXT, not charset —
`commit 1234567` is unambiguous, a bare backticked `1234567` is as likely an
issue number, so only the latter stays rejected.

Proven by synthesising the condition instead of waiting for it: a repository
whose short SHA is all digits (168 amends) is CONFIRMED by the fixed code and
reported as *no checkable claim* by the unfixed code.

**The refresh was implemented, with the evidence against it kept.** The measured
case for not indexing this repo stands and is recorded below; leaving an
instruction unimplemented because I disagreed with it turned it into an open
question nobody had asked. `install-git-hooks.sh` deliberately does **not** use
`core.hooksPath`: this repo carries a `pre-commit` hook from the owner's global
`init.templateDir`, and redirecting hook lookup would have silently disabled it.

**Coverage by environment**, stated because a single number hides it:

| environment | okf-check |
|---|---|
| this machine (deps installed) | 124 passed, 0 failed, 0 skipped |
| GNU coreutils + findutils | 124 passed, 0 failed, 0 skipped |
| bare macOS (no brew, no uv) | 108 passed, 0 failed, **3 skipped** |

The bare-machine skips are optional-dependency preconditions, not defects, and
each prints the command that closes it. On Linux they do not occur: `gstat` and
`gfind` are absent there but `stat` and `find` ARE GNU, which is what `Z-1` and
`Z-7` probe for.

### Debt-zero round (`docs/plans/debt-zero.md`)

| ID | Item | State |
|---|---|---|
| `Z-1` | the GNU `stat` branch had never executed — proven against real coreutils 9.11 | ✅ |
| `Z-2` | every shipped script must be reachable from a hook, skill, or script | ✅ |
| `Z-3` | an empty fingerprint silently disabled change detection | ✅ |
| `Z-4` | a failed `git` lookup was reported as a completed search | ✅ |

| `Z-5` | the `Z-4` fix recorded a failed lookup in one loop and not the other | ✅ |
| `Z-6` | the `Z-4` fix turned every genuinely-absent SHA into "could not query" | ✅ |
| `Z-7` | `find -print -quit` had only ever run on BSD | ✅ |
| `Z-8` | `--fail-on-change` exited 0 while change detection was OFF | ✅ |
| `Z-9` | `--json` had no field for DEGRADED — automation saw a clean `exit:0` | ✅ |
| `Z-10` | a failed subject lookup was rendered AS the commit subject | ✅ |

**`Z-8` is the most serious defect of the round.** `--fail-on-change` is a CI
caller stating *a mid-scan write must fail this run*. With the fingerprint
DEGRADED that detection is off and exit 6 is **unreachable**, so the run exited
0 — the safety net silently absent while the flag requesting it was set. Asking
for a guarantee the tool cannot provide is now COULD NOT RUN. `Z-9` is its
other half: the warning travels through `say()`, which `--json` suppresses by
design, so automation saw `{"exit":0,…}` with no signal at all.

**The skip counter was itself undercounting.** Four `SKIP` sites were mid-line
(`&& echo`, `*) echo … ;;`) and the first sweep's line-anchored pattern could
not match them — the feature added to stop silent undercounting was
undercounting by two. BSD now reports 2 skipped where it had claimed 1.

**`Z-10` took three attempts to get teeth**, and the reason generalises: a plain
non-zero git exit leaks nothing because stdout is empty, and the human report
prints a detail line only for NON-confirmed verdicts. The defect is observable
solely through `--json`, under a signal death. *Where a defect is visible
decides where the test has to look* — grepping the convenient output proved
nothing twice before that was noticed.

**Review of this round found four more, three of them in its own fixes.**
`Z-2` was non-recursive, so a dead file one directory down was never
considered. `Z-2` also excluded `okf-check` and `okf-verify` *before* checking
references, so deleting the `SKILL.md` that documents them would not have
registered. `Z-1c` asserted only `exit 0` — which it could never fail, because
fingerprint problems are advisory by design — and now asserts that change
detection stays live. And `GIT_UNAVAILABLE` was `-1`, which is exactly what
`subprocess` returns for a SIGHUP-killed child: a sentinel colliding with real
data, measured rather than reasoned, now `-1000`.

**The suite passes three ways** — BSD, GNU coreutils, and GNU coreutils plus GNU
findutils 4.11.0 — 0 failed in each.

**`Z-1` closes the oldest open item.** `bundle_fingerprint` has a BSD branch and a
GNU branch; only BSD had ever run, so a defect in the branch every Linux machine
uses was invisible here. Installing GNU coreutils made it testable without
Linux: the full suite passes with `gnubin` first on `PATH`, and `Z-1` keeps it
proven by locating GNU `stat` **by search**, never by an absolute Homebrew path.

**`Z-3` was found by mutating `Z-1`.** Making the GNU branch emit nothing left
the gate printing `ALL GATES PASS`, exit 0 — an empty fingerprint makes
`FP_BEFORE` and `FP_AFTER` compare equal, so E-7 change detection is silently
OFF and every mid-scan write reads as "unchanged". A broken `stat` or an
unrun platform branch turns the whole concurrency lane into a no-op that
reports success. Now reported as `DEGRADED`.

**`Z-4` is a production defect that had been masquerading as a flaky test.**
Two review rounds saw `okf-verify` fail four SHA assertions intermittently and
never reproduced it on demand. Cause: `git()` caught `SubprocessError`, and
`TimeoutExpired` is a subclass of it, so a git call that blew its deadline
returned `(1, "")` — byte-identical to "ran fine, found nothing". The caller
then stated *"not found in the searched repos"*, a claim about a search that
never happened, and a `CONFIRMED` silently became `UNRESOLVED`. That is
"checked and true" degrading to "nobody checked" inside the one layer built to
keep those apart. **Third instance in this codebase of one value carrying two
meanings**, after the L1/L2 shape guards and the `grep -c` conflation — and the
repo's own `shell-or-swallows-errors.md` names the class.

#### `Z-2` — the packaging sweep, not the file

`graphify_reconcile_ids.py` shipped to every install and was referenced by
nothing. Tracing it first changed the fix: it was added at `tools/` in `292dd65`
as a standalone graphify utility, and `dcd102b` swept the whole `scripts/`
directory into the package. The defect is the **over-broad sweep**, so the
remedy is to undo the move — restored byte-identical to `tools/`, out of the
shipped surface, not deleted.

#### The graph-index decision — a pushback, with evidence

The standing request is that the four code-knowledge tools stay fresh after each
merge. Measured here, that is the wrong call **for this repository**:

- `codegraph init` indexed exactly two files: `.okf/okf-base.yaml` and the dead
  `graphify_reconcile_ids.py`. The 700-line `okf-check` — the actual product —
  is bash, which CodeGraph does not index.
- The repo has **11** source files, below the router ladder's ~20-file threshold
  where it says to read directly instead.
- An index that knows almost nothing is worse than none: the router's own rules
  warn that an empty graph result is *inconclusive*, not "no callers", and a
  near-empty index invites exactly that misreading.
- `code-knowledge-graphs/README.md:65-66` states reindexing is deliberately
  never automatic — so a post-merge refresh is an opt-in, not a default.

The index was therefore removed and `.codegraph/`, `.gitnexus/`, `graphify-out/`
added to `.gitignore` — derived artifacts, rebuilt in seconds, and stale by
construction if carried between machines. **If the owner still wants the
refresh**, the mechanism is one line per tool in a `post-merge` hook
(`codegraph init`, `gitnexus analyze --index-only`, `graphify update .`); this
records the recommendation and the evidence rather than deciding it silently.

### Second ultra-review — reviewing the sweep that reviewed the fixes

Three narrow-scoped reviewers plus a direct trace. The headline: **the sibling
sweep that removed silent truncation added three more instances of it**, and the
`G-9` shape guard it shipped was bypassable.

| ID | Defect | State |
|---|---|---|
| `V-1..V-3` | `G-9` checked that `errors` EXISTS, never that it is a LIST — `{"errors": ""}` gave `PASS`, exit 0 | ✅ |
| `V-4` | `bundle_fingerprint` split on newline; a newline in a filename dropped the file silently | ✅ |
| `V-5` | `say_capped` on empty input died with `integer expression expected` | ✅ |
| `U-1` | the `G-11` commit added three NEW silent caps on its own unreadable-dir list | ✅ |
| `U-2` | two caps `G-11` never saw — the L2 COULD-NOT-RUN dump and the selftest dump | ✅ |
| `U-5` | `doc-reuse-guard.sh` shipped with ZERO test references | ✅ |
| `U-6` | `P-7` asserted the staleness hook by grepping a FILENAME, not the JSON contract | ✅ |
| `W-1`/`W-2` | `P-9` scraped versions with `sed \| head -1`; a nested `version` shadowed real drift | ✅ |
| `X-1` | `okf-verify.test.sh` never checked its git fixture built — an empty SHA failed 20 assertions | ✅ |
| `T-1` | readability guard is check-then-act; a directory locked mid-scan was reported `PASS` | ⚠ see below |

**`V-1..V-3` is the third time `present` was mistaken for `well-formed`** — `G-4`
in L2, `G-9` in L1, and now `G-9` again because the guard tested key presence
and not type. `len()` and `for..in` accept a string, so the wrong shape counted
zero and passed. Worse than the false PASS: a 10-character string rendered as
"10 error(s)" with ten single-character messages, and an object rendered as one
error named after its key. Fabricated detail is worse than a refusal.

**`V-4`'s obvious fix does not work.** `find -print0` into `$(...)` loses every
delimiter, because command substitution strips NUL bytes — the first attempt
broke `E-9b`/`E-9c` outright. The list goes through a file.

**`V-5` opened onto the repo's own lesson.** `grep -c` exits 1 for *no match*
and 2 for *could not read*, and one variable was carrying both, so a grep that
FAILED became "0 lines" and silently suppressed the "and N more" tail. That is
`shell-or-swallows-errors.md` verbatim, in code written to fix silent
truncation. Both helpers branch on the exit code now and say "an unknown number
more" when they genuinely do not know.

#### `T-1` — fixed, but its test's teeth are UNPROVEN

The guard walks the tree, then the layers read it. A directory locked in that
gap is invisible to both, and the run reported `PASS 0 concepts`, exit 0. The
race cannot be removed — another agent owns its own writes, the same constraint
`E-7` documents — so it is detected and stated after the layers run.

**The test does not prove the fix prevents the defect.** Reverting the re-check
made `T-1` SKIP, not FAIL, on 4 consecutive runs: the `sleep 0.05` racer reliably
lands *after* the layers, where the re-check still catches it but the unfixed
code has no symptom. So `T-1` proves the re-check fires; it does not reproduce
the original fail-open. Marked ⚠ with `E-7d` and `G-1b` rather than ✅, and
recorded here instead of being quietly counted as coverage.

**Dead code, mentioned not deleted:** `plugin/scripts/graphify_reconcile_ids.py`
has no reference in `hooks.json`, any `SKILL.md`, or any script. It ships and
runs nothing.

### `P-11` — committed ≠ installed

Firing the hooks finally closed the item above, and doing so exposed a worse
one: the *installed* plugin was **seven fixes behind** the source tree, so the
surface actually running still had every `G-*` defect. Neither obvious remedy
worked — `claude plugin marketplace update` reported success and redeployed
nothing (it refreshes catalog metadata), and `claude plugin update` answered
*"already at the latest version (0.1.0)"* and stopped, because the cache is
keyed by the manifest version.

**A fix shipped without a version bump can never reach an installed copy.**
Released as `0.2.0`; `claude plugin update` then reported `0.1.0 -> 0.2.0` and
the deployed scripts carry the fixes. `P-10` exists so this is caught by a test
rather than by noticing.

This is the next link in the chain `P-8` started. `P-8` was *validated ≠
installed*. `P-11` is *committed ≠ installed* — and the reason the whole
`G-*` round would otherwise have been invisible to the only copy that runs.

### Reviewer-driven scenarios (R-*)

Ten tests exist in `okf-check.test.sh` with no row in the tables above — the
reverse of the untraceable-✅ problem, and equally a drift.

| ID | Scenario | Expected | State |
|---|---|---|---|
| R-1 | okflint CRASHES (exit 127 / signal) | COULD NOT RUN — never `L2 PASS` | ✅ |
| R-2 | okflint reports errors in a non-emoji format | detected via `--json`, not by grepping ❌ | ✅ |
| R-3 | `--json` on a FAILING bundle | still valid JSON | ✅ |
| R-4 | conformance error + unusable manifest | exit 1, not masked by 2 | ✅ |
| R-5 | `--selftest --json` | must not report a dead gate | ✅ |
| R-6 | unreadable bundle DIRECTORY | fails CLOSED | ✅ |
| R-7 | newline in the bundle path | L3 still runs | ✅ |
| R-8 | same-named concepts in different directories | distinguishable in the report | ✅ |
| R-9 | two bundle arguments | error, not a silent choice of one | ✅ |
| R-10 | `--help` | documents `--fail-on-change` and exit 6 | ✅ |

---

## Packaging (item 3)

### Use cases
| ID | Use case |
|---|---|
| **P-UC-1** | Install the gate on a machine that has never seen this repo |
| **P-UC-2** | Ship the two hooks so enforcement arrives with the tool, not as manual `settings.json` surgery |

### User stories
- **P-US-1** — *As someone setting up a new machine,* I want one install to bring the gate, its hooks and its vendored checker, so nothing has to be reconstructed by hand.
- **P-US-2** — *As a reviewer of this package,* I want an authority other than the author's judgement to say it is well-formed.

### Scenarios
| ID | Scenario | Expected | State |
|---|---|---|---|
| P-1 | `claude plugin validate --strict` on the plugin | passes | ✅ |
| P-2 | `claude plugin validate --strict` on the marketplace | passes | ✅ |
| P-3 | `skills/` at plugin root, **not** inside `.claude-plugin/` | documented failure mode — asserted | ✅ |
| P-4 | Every script referenced by `hooks.json` exists and is `+x` | documented failure mode — asserted | ✅ |
| P-5 | No absolute machine paths in `hooks.json` | all paths `${CLAUDE_PLUGIN_ROOT}`-relative | ✅ |
| P-6 | Validator travels with the plugin | `plugin/vendor/okf_validate.py` present | ✅ |
| P-7 | Bundle location is overridable | `OKF_BUNDLE_DIR` respected by the hook | ✅ |
| P-8 | Plugin installed and enabled end-to-end on a real machine | **not yet done** | 🔴 |

P-8 is the honest gap: the package validates, but it has not been *installed*.
Validation is not installation, and the difference is exactly the class of claim
this project keeps catching.

---

## Truth verification — L4 (item 4)

The only lane no other OKF tool implements. The upstream validator says so in its
own source: a target outside the bundle is *"legitimate and unverifiable from
here"*. Conformance is a question about form; this is a question about fact.

### Use cases
| ID | Use case |
|---|---|
| **V-UC-1** | Know whether a bundle's cited commits and paths still resolve |
| **V-UC-2** | Distinguish *"this claim is false"* from *"nobody checked"* |
| **V-UC-3** | Know how much of a corpus is verifiable at all before calling it evidence-backed |

### User stories
- **V-US-1** — *As someone relying on a lesson,* I want to know its cited commit still exists, because a history rewrite silently orphaned every SHA in one of them.
- **V-US-2** — *As a reader of a report,* I never want "could not check" rendered as "is false" — that would make the tool worse than not running it.
- **V-US-3** — *As a maintainer,* I want the unverifiable share reported, so an unverified corpus never looks verified.

### Scenarios
| ID | Scenario | Expected | State |
|---|---|---|---|
| V-1 | Concept cites a resolvable SHA | CONFIRMED, exit 0 | ✅ |
| V-2 | Concept cites an existing file path | CONFIRMED | ✅ |
| V-3 | Missing file, **parent exists** | REFUTED, non-zero exit | ✅ |
| V-4 | SHA resolves in no searched repo | **UNRESOLVED**, never REFUTED, exit 0 | ✅ |
| V-5 | Concept with no checkable claim | stated as unverifiable | ✅ |
| V-6 | SHA orphaned by rewrite, subject survives | UNRESOLVED + names the surviving commit | ✅ |
| V-7 | Bundle path containing a space | works, claims still resolve | ✅ |
| V-8 | No `--repo` given | UNRESOLVED with the scope stated | ✅ |
| V-9 | `--json` | parseable | ✅ |
| V-10 | Path inside a **fenced code block** | not a claim — ignored | ✅ |
| V-11 | Ephemeral path (`/tmp`, `/var/folders`) | never REFUTED | ✅ |

**V-10 and V-11 came from live-firing, not from imagination.** The first run on
the real bundle REFUTED `/tmp/net-spy.log` — a `const LOG = …` literal inside an
example script. The lesson never claimed the file existed; it said where to write
output. A tool that cries wolf gets ignored, so both precision rules were added
and the false positive went to zero while CONFIRMED stayed at 10.

**Mutation-proven.** Collapsing `UNRESOLVED` into `REFUTED` — the one dishonesty
this lane must never commit — is caught by two tests.

### Live-fire — a dated observation, not a reproducible expectation

Run on 2026-07-31 against `~/.claude/lessons` (44 concepts at the time) with four
`--repo` arguments, it reported `CONFIRMED 10 · REFUTED 0 · UNRESOLVED 7`, with 32
concepts carrying no checkable claim.

**Do not treat that as a fixture.** A reviewer re-running it hours later saw
`CONFIRMED 8 · UNRESOLVED 9` over 46 concepts — the bundle is written by other
sessions and the result also depends on which repos are searched. Both numbers
were correct when taken.

What matters is not the count but the shape: the UNRESOLVED set included
`eab3e9e` and `95f777f`, the SHAs orphaned by the code-knowledge-graphs history
rewrite. Reporting those as REFUTED would have been wrong — the fix they describe
is still running in production.

## Non-goals

- Installing or upgrading dependencies WITHOUT being asked (UC-3: *report* by default; *act* only on `--install-deps --yes` or the owner's `OKF_AUTO_INSTALL=1`)
- Rewriting bundle content — `okflint index --apply` is deliberately never invoked;
  it regenerates `index.md` as a flat list and would destroy a curated one
- Replacing either upstream tool. This composes them; it owns only the staleness
  layer and the orchestration.
