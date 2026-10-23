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
- **US-3** — *As someone on a fresh machine,* I want the gate to tell me what is missing and, only when I ask, install the supported version, so that nothing is installed behind my back and I still do not hunt for commands. (Changed 2026-10-15: it used to say "never to install".)
- **US-4** — *As the person who just upgraded okflint,* I want proof the gates still fire, because an upgrade that silently stops catching things is indistinguishable from a clean run.
- **US-5** — *As CI,* I want distinct exit codes, so a spec violation and a house-rule violation do not look identical.
- **US-6** — *As a reader of a report,* I never want a summary line that contradicts the body above it.

---

## Scenarios

Legend: **✅** covered by a passing test in `plugin/scripts/okf-check.test.sh` ·
**⚠** covered but conditional (states the condition) ·
**🔒** enforced by CONSTRUCTION, no runtime test is possible — the row must say why ·
**🔴** RED — specified, not implemented, no test yet ·
**👁** checked by hand on a real machine (the row gives the command, its output and the date); no test covers it yet.

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
| LT-12a | okflint rejects a BOM note (okflint#8; stock 0.3.1 / 0.5.0) | doctor prints `okflint behaviour  UNPATCHED — fails on: a BOM note (okflint#8)` with the fix pointer | ✅ |
| LT-12b | okflint passes the BOM, non-UTF-8 and impossible-date probes (patched build) | doctor prints `okflint behaviour  PATCHED` | ✅ |
| LT-12c | patched okflint | no UNPATCHED line | ✅ |
| LT-12d | UNPATCHED okflint | doctor is advisory: exit 0 | ✅ |
| LT-12e | okflint crashes on a non-UTF-8 note (okflint#9) | doctor prints UNPATCHED naming a non-UTF-8 note | ✅ |
| LT-12f | okflint crashes on an impossible date (okflint#10) | doctor prints UNPATCHED naming an impossible date | ✅ |
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
| LT-21e | L1 validator past `OKF_L1_TIMEOUT` (a stub validator that sleeps 30 s, limit 1 s) | `COULD NOT RUN — the validator timed out`, exit 2 | ✅ |
| LT-21g | the validator ends itself with TERM (exit 143) | COULD NOT RUN, never "timed out" (only the watchdog's marker says so); the row names `exit status 143` | ✅ |
| LT-21i | the validator exits 124 | COULD NOT RUN, never "timed out" | ✅ |
| LT-21h | the bundle run fails and each note alone hangs (4 notes, limit 2 s) | one `OKF_L1_TIMEOUT` budget for all of L1: timed out, exit 2, under 10 s (not N × the limit) | ✅ |
| LT-21f | `OKF_L1_TIMEOUT=0` | falls back to the default; never an instant kill | ✅ |
| LT-LL1 | the Python layers' frontmatter loader sleeps 30 s on a note (stub; `OKF_LAYER_TIMEOUT=2`) | the Python layers (Trust, Successor, Owner, Size, derived L3, `--duplicates`, the scoped `--file` check) are each `COULD NOT RUN` naming `OKF_LAYER_TIMEOUT`, exit 2; the budget is ONE for all, counted in real milliseconds | ✅ |
| LT-LL2 | the same run, afterwards | no layer process is left running | ✅ |
| LT-LL3 | the same run | one budget for all the layers: only the first one started its parse | ✅ |
| LT-LL4 | `OKF_LAYER_TIMEOUT=0` | falls back to the default (300 s); never an instant kill | ✅ |
| LT-LL5 | a real 0.9 MB frontmatter note, `OKF_LAYER_TIMEOUT=2` | Trust is `COULD NOT RUN` naming the limit, exit 2 | ✅ |
| LT-LL6 | the same run, afterwards | no process that names the bundle is left | ✅ |
| LT-LL7 | `--duplicates` past the limit | `Duplicates` is `COULD NOT RUN` naming the limit, exit 2 | ✅ |
| LT-LL8 | `--file` past the limit (stub) | `COULD NOT RUN` naming the limit on stderr, `<note> was not checked`, exit 2 | ✅ |
| LT-LL9 | `--file` on the real 0.9 MB note, `OKF_LAYER_TIMEOUT=2` | the same, in under 8 s | ✅ |
| LT-LL10 | after a `--file` time limit | no process is left | ✅ |
| LT-LL11 | the edit hook, a layer that outlasts `OKF_EDIT_HOOK_TIMEOUT` | the hook's smaller box fires first: silent, exit 0, the layer stopped with the check | ✅ |
| LT-LL12 | `okf-limit.py` runs a 0.3 s command | `<out>.ms` holds its elapsed time in milliseconds | ✅ |
| LT-LL13 | a healthy 9-note bundle, `OKF_LAYER_TIMEOUT=2`, ten runs | one exit status every time | ✅ |
| LT-LL14 | only the Size reader is slow (stub) | `Size` is `COULD NOT RUN` naming the limit; the layers before it are not stopped | ✅ |
| LT-LL15 | `--json` with layers that could not run | `layers_not_run` lists their names in order; `[]` when none | ✅ |
| LT-LL16 | `--duplicates --json` past the limit (stub) | still one JSON document on stdout (`exit` 2, `layers_not_run` `["Duplicates"]`, `reason`), the reason on stderr, exit 2 | ✅ |
| LT-LL17 | `--facts` past `OKF_FACTS_TIMEOUT` (stub) | the reason on stderr, exit 2 (it has no JSON document); `--conserve` parses no frontmatter and needs no limit | ✅ |
| LT-LL18 | `--file --json` | refused, exit 64, message on stderr, nothing on stdout: no empty document | ✅ |
| LT-LL19 | `OKF_LAYER_TIMEOUT=1`; `--help` with the same value | refused (below the 2 s floor), exit 64, message on stderr, in the full run and in `--file`, `--duplicates`, `--facts` and `--selftest`; `--help` exit 0 | ✅ |
| S38-ST-N1 | `--duplicates --json`, `okf-base.yaml` does not parse | one JSON document (`exit` 2, `layers_not_run` `["Config"]`, `reason`), the reason on stderr, exit 2 | ✅ |
| S38-ST-N2 | `--duplicates --json`, `.okfignore` is a folder | the same, `["Duplicates"]` | ✅ |
| S38-ST-N3 | `--duplicates --json`, `okf-duplicates.py` exits 3 | the same, reason `okf-duplicates.py exited 3`; no half-printed document | ✅ |
| S38-ST-N4 | `--duplicates --json`, `okf-base.yaml` is a link to a device | the same, `["Config"]`; never opened | ✅ |
| S38-ST-N5 | main `--json` with an `.okfignore` that is a folder; main, `--duplicates`, `--conserve` and `--fingerprint` with `--json` over a folder that cannot be read (`--conserve` and `--fingerprint` do not read `.okfignore`) | one document with the reason (the main run's, `--duplicates`', or `{bundle, exit, error}`), stderr, exit 2 | ✅ |
| S38-ST-N6 | no `python3` on PATH: main `--json`, `--duplicates --json` | a document written by hand with `exit` 2 and `reason` | ✅ |
| S38-ST-N7 | `--facts --json` with a manifest that does not parse; `--doctor --json` | the text report on stdout: neither has a JSON document, and `--facts` printed text under `--json` on success already. Decided: text under `--json` for these two; `--file --json` stays refused (exit 64, LT-LL18): its output is findings lines for the edit hook | ✅ |
| S38-ST-O1 | `require_owner`, a 5 KB note whose aliases expand to 1,001,000 items (above `MAX_EXPANDED_ITEMS`) | Owner FAIL: the note was too large to read (the loader's message); not `not valid YAML`, not `no owner`, not `every note needs an owner` | ✅ |
| S38-ST-O3 | the same note beside an invalid YAML note and a note with no owner | `2 error(s): every note needs an owner; 1 note(s) too large to read`; the others keep their words | ✅ |
| S38-ST-S1 | `deprecated_requires: superseded_by`, a deprecated note the loader refuses for its size | Successor FAIL: the note was too large to read, its successor was not checked; never `PASS no deprecated notes`; exit 1 | ✅ |
| S38-ST-S2 | a `superseded_by` target the loader refuses for its size | Successor FAIL: the successor was too large to read, whether it is deprecated was not checked | ✅ |
| S38-ST-D1 | `--duplicates` over a note the loader refuses for its size | the note is named (too large to read, not compared); `no candidate duplicates among the notes read`; exit 0 (advisory) | ✅ |
| S38-ST-D2 | the same with `--json` | `unread[]` (rel, why); `complete` false; absent on a healthy bundle (S38-ST-D3) | ✅ |
| S38-ST-E1 | a healthy bundle, `--json` and `--duplicates --json` | no `reason` key, exit 0 | ✅ |
| S40-CP-T1 | a 5 KB note the loader refuses for its size, the Trust layer | Trust FAIL: the note was too large to read, its trust claims were not checked; never `PASS`; exit 1 | ✅ |
| S40-CP-T2 | the same note beside a draft note with a human verifier | the Trust line counts `1 note(s) too large to read` and the draft note's warning still prints | ✅ |
| S40-CP-T3 | the same with `--json` | `errors[]` names the note as too large to read for Trust | ✅ |
| S40-CP-F1 | `--file` on that note | a `<note>: Trust error: the note was too large to read...` line, exit 1 | ✅ |
| S40-CP-F2 | `okf-scoped.py` run directly on that note | the same line, exit 1 | ✅ |
| S40-CP-L1 | the same note, derived L3 | `L3 derived` FAIL: the note was too large to read, its sources were not compared; exit 1 | ✅ |
| S40-CP-L2 | the same with `--json` | `errors[]` names the note as too large to read for its sources | ✅ |
| S40-CP-H1 | a healthy bundle | `Trust (C4)       PASS` as before, no `L3 derived` line, no too-large line, exit 0 | ✅ |
| S41-BM-01/02 | a note starting with a byte order mark, its source stale or not a local file | the `L3 derived` line is the one the same note without the BOM gets | ✅ |
| S41-BM-03/04 | a BOM note: the L2 index type count; `okf-verify` and a fence line in its frontmatter | the note is counted by its type; no false unclosed code fence | ✅ |
| LT-20p | `.okfignore` that excludes nothing | same verdict and exit as no file (also with notes behind a symlinked dir) | ✅ |
| LT-20q | `**/x.md` | also matches `x.md` at the bundle root | ✅ |
| LT-20q2 | `/**/x.md` | behaves like `**/x.md` | ✅ |
| LT-20r | only non-note files excluded | never reports "excludes every note" | ✅ |
| LT-22 | status vocabulary in the template and the list l3-lib loads | equal as sets | ✅ |
| LT-SV1 | the validator's `STATUS_VALUES` gains a value | L3 accepts it too: one list, read by l3-lib | ✅ |
| LT-SV2 | every `status_values` in the template and `.okf/okf-base.yaml` | equal to `STATUS_VALUES`; a planted drift is caught | ✅ |
| LT-SV3 | `STATUS_VALUES` on two lines, not a list, or the validator gone | okf-check exit 2 naming `STATUS_VALUES`; the SessionStart hook says what was NOT checked; single quotes are a list | ✅ |
| LT-CE1 | `sources[].resource: SRC.txt`, the disk holds `src.txt` | not measured (case-exact, as okf-verify D-11), on every disk | ✅ |
| LT-CE2 | the same source cited as written | measured | ✅ |
| LT-CE3 | `okf-check .` with a `../x.txt` source; the bundle path typed in another case | measured, exit 4 with `--fail-stale`: only the cited part below the folder it shares with the bundle is judged | ✅ |
| LT-CE4 | `okf_guard.case_exact("../x.txt")` from the bundle folder (okf-verify calls it too) | True as written, False as `../X.TXT` | ✅ |
| LT-CE5 | a source that is a symlink whose target is spelled in another case (`l.txt -> SRC.TXT`; a linked folder `dl -> SUB`; an absolute target outside the bundle), with controls spelled as on disk (also through a linked folder whose link climbs with `..`) | not measured, and the line says `is a link whose target is missing or spelled in another case`, on every disk; a wrong or missing name below a correct link keeps `is not a local file`; the controls are measured. An absolute target outside the bundle is judged too: on Linux such a link dangles, so judging it gives macOS the Linux verdict | ✅ |
| LT-CE6 | `okf_guard.case_exact` over a table of 97 spellings (relative, absolute, `..`, outside the bundle, wrong case above and below it, links to a file or a folder, chains, dangling, loops, NFC/NFD, trailing slash, `.`; links that climb with `..` at depth 1 to 3 and in a chain, in a bundle typed below a link, in another case, or as a link in another case) | the answer in the table; only a link with a mis-cased target answers False on a case-insensitive disk | ✅ |
| LT-CE7 | a seeded differential over random trees (bundle below 1 to 3 folders, random links, the bundle path typed exactly, in another case, below a link, as a link) | `case_exact` equals the reference "would a case-sensitive disk resolve this exactly as written, judging only below the bundle" (a component walk with exact listing matches): 0 mismatches; 5,000 trees on macOS and on Debian | ✅ |
| LT-23 | user-facing env variables | documented in README and SKILL.md | ✅ |
| LT-24a | okflint crashes on one note of a small bundle | the note is named, the others are checked, exit 2 | ✅ |
| LT-24b | more notes than `OKF_L2_ISOLATE_MAX` | no rescue: the plain "crashed" report | ✅ |
| LT-24c | no crashing note | unchanged | ✅ |
| LT-24d | rescue run | the mirror is a full copy: no fabricated reserved-file error, no temp path | ✅ |
| LT-24e | every concept note crashes | no PASS line, no "others were checked" | ✅ |
| LT-24f | several crashing notes | listed sorted | ✅ |
| LT-24g | findings in the checked notes plus a crash | exit 3, crashed notes still named | ✅ |
| I-1a/b | `okf-verify` on a bundle with `.okfignore` | an ignored note's claims are not verified | ✅ |
| LT-10 | okflint crashes on a note (non-UTF-8) | L2 prints a `reason:` line with its last error line; skipped, stated, when okflint is absent | ✅ |
| S54-MC-H1/H2/H3 | `okf_check.max_note_bytes` set below the size of `okf-base.yaml` (the starter is about 4 KB) | the manifest is read under its own limit (1 MiB, `manifest_max_bytes`): no `Refused notes` line, no `Config COULD NOT RUN`, its facts and owner rules fire; `--duplicates`, `--facts`, `okf-verify` and `--check-config` read it | ✅ |
| S54-MC-N1 | a NOTE above `max_note_bytes` | still refused (exit 1); the manifest is not named | ✅ |
| S54-MC-E1/E2/E3 | a manifest of exactly 1048576 bytes, and one of 1048578 | the first is read; the second is refused with `larger than 1048576 bytes (the okf-base.yaml size limit)`, not `max_note_bytes` (full run exit 1; `--facts` exit 2) | ✅ |

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

All of these were **closed** in the change that added this section, and it previously still
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

- ~~**GNU `stat`** is exercised only through a stub.~~ **Closed** (2026-10-23,
  SP-443): the Debian gate runs the GNU branch against real coreutils
  (gap audit `stat (GNU coreutils) 9.1`; a real `okf-check` run traced
  `xargs -0 stat -L -c '%s %y %n'` and passed).
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
| D-11b | a cited path that is a symlink whose target is spelled in another case | not CONFIRMED, on every disk; the control (target as on disk) is CONFIRMED (D-11c) | ✅ |
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
nothing. Tracing it first changed the fix: it was added at `tools/`
as a standalone graphify utility, and a later commit swept the whole `scripts/`
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
| `T-1` | readability guard is check-then-act; a directory locked mid-scan was reported `PASS` | ✅ see below |

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

#### `T-1` — fixed, and its test's teeth are proven (2026-10-23)

The guard walks the tree, then the layers read it. A directory locked in that
gap is invisible to both, and the run reported `PASS 0 concepts`, exit 0. The
race cannot be removed — another agent owns its own writes, the same constraint
`E-7` documents — so it is detected and stated after the layers run.

Until 2026-08-02 the test used a `sleep 0.05` racer, and reverting the
re-check made `T-1` SKIP, not FAIL. The test now simulates a directory that
becomes unreadable mid-scan through a `find` shim (`okf-check.test.sh`, the T-1 block), so the timing is fixed. A
mutation run of the 2026-10-23 gap audit (SP-844) with the re-check disabled
(`_unreadable_after=""`) gave `FAIL T-1 a directory locked mid-scan was not
reported`; the real code gave PASS, and the control `T-1b` passed in both.

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
| R-10b | `--help` | the whole header: every exit code of the README table and the script (64, 130, 143 included) and the usage lines | ✅ |

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
| P-8 | Plugin installed and enabled end-to-end on a real machine | installed and enabled: `claude plugin list --json` shows `okf@ahmedmaged-okf` (0.9.49 on that date), `enabled: true`, user scope (2026-10-23, SP-944) | 👁 |

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
| V-6b | Same as V-6 (okf-knowledge-gate#6, comment 2: the commit lived in a repository that was not searched) | UNRESOLVED; the detail says a commit MESSAGE contains the quoted subject and names three explanations (rewritten history, a repository not searched, an unrelated match), with the searched and the unqueryable repositories; never "likely a history rewrite" alone | ✅ |
| V-7 | Bundle path containing a space | works, claims still resolve | ✅ |
| V-8 | No `--repo` given | UNRESOLVED with the scope stated | ✅ |
| V-9 | `--json` | parseable | ✅ |
| V-10 | Path inside a **fenced code block** | not a claim — ignored | ✅ |
| V-11 | Ephemeral path (`/tmp`, `/var/folders`) | never REFUTED | ✅ |
| RV-1 | `okf-base.yaml` declares `okf_check.verify.repos` with one valid git repo, no `--repo` (0.9.50) | not searched: its SHA is UNRESOLVED, `repos searched: NONE`, one UNRESOLVED `[repo]` line `okf_check.verify.repos is not searched since 0.9.50; to search it, pass --repo <path>`, exit 0 | ✅ |
| RV-2 | One declared repo plus `--repo other` | only `other` is searched | ✅ |
| RV-3 | Declared path does not exist, or is not a git repo (was RV-3 and RV-4) | the same one line; nothing is looked up; exit 0, exit 1 under `--strict` | ✅ |
| RV-5 | Declared `../svc` | not searched; the hint names `--repo <bundle>/../svc` | ✅ |
| RV-6 | Same repo declared and passed with `--repo` | searched once, no hint line | ✅ |
| RV-7 | `okf-base.yaml` unreadable, not valid YAML, or `okf_check.verify.repos` not a list of `{path: string}` | one error line naming the file and the problem, exit 2, no verdicts; no `okf_check` key is not an error | ✅ |
| RV-8 | `path:line @sha`, `path:a-b at sha`, suffix path (S2-H2) | one claim, CONFIRMED when the path exists in that commit; the detail shows sha and path; a backticked sha inside the citation is not also a bare-sha claim | ✅ |
| RV-9 | Path missing at the cited commit, including a file that exists only at HEAD (S2-N1) | REFUTED, detail `path part failed`, non-zero exit | ✅ |
| RV-10 | Cited sha in no searched repository (S2-N3) | UNRESOLVED, never REFUTED, exit 0 | ✅ |
| RV-11 | Suffix path matches two files at that commit (S2-E5) | UNRESOLVED, detail `ambiguous` | ✅ |
| RV-12 | Cited line inside the file at that commit (S2-H1) | CONFIRMED; the `--json` detail shows sha, path, line and the line count | ✅ |
| RV-13 | Line, or end of a range, past the end of the file (S2-N2) | REFUTED, detail gives the file's line count, non-zero exit | ✅ |
| RV-14 | Range ending on the last line (S2-E2); one past it; line 0; last line without a final newline | CONFIRMED; REFUTED; REFUTED; counted | ✅ |
| RV-15 | Cited file empty or binary (S2-E1) | empty: REFUTED (0 lines); binary: UNRESOLVED, detail `binary`; never a crash | ✅ |
| RV-20 | Cited path is a symlink at that commit (S2-N4) | UNRESOLVED, detail `symlink`; never REFUTED, never CONFIRMED | ✅ |
| RV-21 | `a dir/w.py:1 @sha` (path cut at a space, words that do not spell the file; `my dir/w.py:1 @sha` is RV-27); `C:\x\y.py:3`, a URL, `v1.2:3 @ 5pm` (S2-E3) | the space case is UNRESOLVED (never REFUTED; a missing `ta.py` beside `data.py` is still REFUTED); the others are no claim and get no verdict | ✅ |
| RV-22 | Line number of 5000 digits, alone or ending a range (S2-N5) | REFUTED `line number out of range`, exit 1, the other citations still print, also under Python 3.11-3.13 | ✅ |
| RV-23 | Reversed range `20-10` (S2-E4) | read as up to the larger number: CONFIRMED when within the file, REFUTED when past the end | ✅ |
| RV-16 | An unknown key under `okf_check`, `verify` or a repository entry; a null `okf_check`/`verify`; `repos` as a list of strings; an empty `path`; invalid UTF-8 | exit 2, one line naming the key (S1-N3, schema shared with `okf-check`) | ✅ |
| RV-17 | `okf-verify <bundle> --check-config` | valid or absent block: exit 0, no output, no verdicts; invalid: one error line, exit 2 | ✅ |
| RV-18 | A declared path that cannot be resolved (`~nosuchuser/x`; a path under an unreadable directory) | since 0.9.50: UNRESOLVED `okf_check.verify.repos is not searched since 0.9.50; ...` in text and `--json`, exit 0, no traceback, no REFUTED; the `--repo` repositories are still searched | ✅ |
| RV-19 | A `path:line @sha` citation, repository declared in `okf-base.yaml`, no `--repo` (S1 x S2 seam) | since 0.9.50: neither CONFIRMED nor REFUTED, whether or not the path exists at that commit (the repository is not searched) | ✅ |
| RV-24 | An `{enum: [...]}` schema node (`okf_check.deprecated_requires`) | the listed value: exit 0; any other: exit 2, the error names the value as JSON (`true`, `null`, `"x "`, not a Python repr) and the allowed ones | ✅ |
| RV-25 | A `{type: boolean}` node (`require_owner`), a `{map: node}` node (`owners`: free keys, each value a node) and a node that `requires` a sibling value (`owners` needs `require_owner: true`), and `key_no_prefix` (an `owners` key that starts with `!`) | valid: exit 0; a non-boolean, a list for the map, a non-string or empty value, and a missing sibling: exit 2 with the message | ✅ |
| RV-26 | A `{type: number, min, max}` node (`okf_check.duplicates.threshold`, `time_limit`) | a number within the bounds, int or float: exit 0; out of bounds, a string, a boolean: exit 2 naming the bounds | ✅ |
| RL-1 | `okf-verify --remote` / `okf_check.verify.remote` (okf-knowledge-gate#6 comment 1, S24-RL-H1..E3): a SHA no searched clone holds is asked of the origin's GitHub or GitLab API, read-only; found: CONFIRMED (remote) with title, date and "local clone is behind"; absent, failed or no known forge: UNRESOLVED saying which; a local SHA is never sent; tokens go only to their own forge; a non-boolean option exit 2 | as stated | ✅ |
| CS-1 | `--conserve <ref>` (okf-knowledge-gate#16, S23-CS-H1..E5): each removed line MOVED, DECLARED, CHANGED (paired by position in its hunk) or LOST; blank, whitespace-only, markup-only and frontmatter lines not counted; advisory exit 0, `--fail-lost` exit 1; `--deleted FILE` and `OKF-Deleted:` trailers; exit 2 outside git or for an unknown ref, 64 without a ref; `--json` conserve{} | as stated | ✅ |
| DF-1 | `okf_check.facts` (okf-knowledge-gate#15, S22-DF-H1..E3b): statements that agree pass; another value is a FACT-CONFLICT naming note, line, fact, both values and the source (exit 1); `facts[]` in `--json`; `--facts [NAME]` lists every occurrence (exit 0, 64 for an unknown name); code blocks and ignored notes not read; a malformed block exit 2 in both tools; a selftest probe that fires and fails when crippled | as stated | ✅ |
| HK-1 | Edit hook values (B-7, S9-SH-11..13): `OKF_EDIT_HOOK_TIMEOUT` nan, 0, -1, abc or empty; an unquoted `edit_hook: yes`/`on`; a long first finding | the default box applies and the finding is reported; the hook stays off and `--check-config` exits 2 naming the option; the first finding is cut, the `(+N more: ...)` hint kept | ✅ |
| DU-1 | `--duplicates` limits (F-7, S25-DU-H1..E3): stub bodies, a limit reached while reading, in the body pass, inside one crowded bucket | a body under 5 words is not a body signal and is counted (`body_short`); CUT SHORT names the pass (`cut_in` read, pairs, body) with notes read or bodies hashed; the bucket loop stops near the limit | ✅ |
| IA-1 | `.okfignore` and symlinks (F-6, S12-IG-F1..F3): an alias of an ignored note; an alias of a kept note; a folder link under an ignored folder | the alias is ignored by every walker; a kept alias is still checked; the folder link is not named; `--json` `symlinked_folders` lists the named ones | ✅ |
| RF-1 | Review fixes (S26-RF-H1..E3): a `verified.by` spelled with lookalike letters; okf-verify missing; a config check that fails without a message | a Trust warning saying it only looks like `human:`/`process:` (exit 1 under `--strict-trust`); the Config line names the missing checker or the exit code, never blames okf-base.yaml; `--selftest` probes both | ✅ |
| IV-1 | Invisible characters in a trust prefix (S32-IV-H1..E1): `hu<U+200B>man:dana` (also U+200C/D, U+00AD, U+2060, U+FEFF, combining marks, a precomposed `ḥ`), a leading U+200B, a soft hyphen inside `process:`, blanks and fillers inside `human:` (U+00A0, U+3000, U+2800, U+3164, U+FFA0, U+115F, enclosing U+20DD); the same characters in the id after `human:`, and ordinary spaces in a name | the first group is a Trust warning saying it only looks like `human:`/`process:` (exit 1 under `--strict-trust`); the warning names the hidden code points; the id and ordinary spaces are not called lookalikes; `--selftest` probes the zero-width case and fails (exit 5) when the Cf/Mn drop is removed | ✅ |
| HD-1 | `okf-check --doctor` and the edit hook (S32-HD-H1..E2): hook on (key in the nearest `okf-base.yaml`, or `OKF_EDIT_HOOK=1`) with `config/edit-hook.json` readable, missing, not JSON or lacking keys; an invalid `okf_check` block; hook off | one line `edit hook ON (<source>); config OK`, `ON (<source>) but CANNOT RUN: <file> ...` saying the hook stays silent, or `OFF: <okf-base.yaml> okf_check block is invalid (<reason>); the hook reads it as off`; no line when off; exit 0 (advisory), the hook itself stays fail-open | ✅ |
| PO-1 | okf-export polish (F-5, S10-PO-1..6) | `--version` on okf-export and okf-verify; an `<out>` file named as one; setext headings are anchors; targets matched exactly, then ignoring case (two case variants ambiguous); a duplicate heading links the first; only `\n` ends a line | ✅ |
| D23-a | okf-export: an HTML block inside a block quote (`> <div>` / `> [[b]]`), then a line with no `>` | the `[[b]]` in the block stays as written; the line after it is outside the quote and its link is converted | ✅ |
| BL-886b | okf-export: a 4-space line after a heading in a quoted list item (` >1. # Dup` / `>     1. # Dup` / `    [[n]]`) | no lazy line (no paragraph is open): indented code, `[[n]]` stays as written | ✅ |
| SC-export417 | okf-export: a line with no `>` after a quote line | stays in the quote only when the quote's own reader has a paragraph open there; else the quote ends before it (oracle: 0 mismatches) | ✅ |
| BL-884 | okf-export: a setext heading inside a block quote, nested, or in a quoted list item | a heading a link can name; one whose text holds a lazy line that could be an underline or start a block (`===`, an indented `# foo`) gets no anchor (a loud `missing heading`) | ✅ |
| RM-230b | okf-export: `> - x` / `lazy` / `- # Head` | `lazy` goes on with the item paragraph in the quote; `# Head` is a heading a link can name | ✅ |
| BL-722 | okf-export: a kill -9 while the case probe runs | nothing is left beside `<out>`: the probe writes nothing (it compares a folder with its case-swapped name) | ✅ |
| GR-1 | The optional okf-memory layer, L2 graph (S27-GR-H1..E3): opted in with `okf_check.graph: true` or `OKF_MEMORY_BIN` | orphans and broken concept links as advisories (`--json` `l2_graph`); not opted in: nothing runs; absent or another `okf`: SKIPPED naming what is unchecked; hung or unreadable: COULD NOT RUN, not a pass; `graph: yes` exit 2 | ✅ |
| LC-1 | A line citation into a living document, `name.md:N`, `name.md:N-M`, `name:N` (okf-knowledge-gate#14, S21-LC-H1..E6) | CONFIRMED when the file has the line; REFUTED when found and shorter; UNRESOLVED when missing, ambiguous or outside the bundle and the searched repos (not looked up); `name:N` only when a note of that name exists | ✅ |
| LC-2 | A content anchor `"text"` after a citation (S21-LC-A1..A8) | on the cited lines CONFIRMED; elsewhere MOVED with `moved_to`, exit 1; nowhere REFUTED; pinned citations checked at their commit and never MOVED | ✅ |
| LC-3 | `--since <ref>` and `okf_check.verify.generated` (S21-LC-C1..C5, G1..G2b) | shifted cited text MOVED, edited in place a warning; a citation into a generated note without an anchor warns; bad ref or no repository exit 2 | ✅ |
| RV-27 | A citation with a space before `:line` (S2-SP-*): `my w.py:3 @sha` with `my w.py` and `w.py` present, with only one of them, with two spaces, in a table cell, quoted; `w.py:3`, a blank line, `@sha` | both present: UNRESOLVED naming both; only `my w.py`: checked in that file; only `w.py`: CONFIRMED (prose) or, quoted, REFUTED; a blank line splits a citation | ✅ |
| RV-28 | A zero-padded line number (S29-LZ-*): `a.py:0000000003 @sha`, the range `0000000018-0000000020`, `0000000021` in a 20-line file, `0000000000`, 5000 zeros before a 3 (also under Python 3.11 to 3.13), and in a document citation, with an anchor, and with `--since` | the number it spells: CONFIRMED when within the file, REFUTED as past the end or "lines start at 1", never "out of range" for a short number, no traceback; `--since` reports MOVED with the new line or range | ✅ |
| RV-29 | `--repo` written relative or absolute (S29-RP-*): an absolute path cited through a link into the repository; a path outside it; `inside_any` on a path under `/net/<host>`; `--repo ../sib` from a link, from a plain folder, and with a stale `$PWD` | the same verdict for both forms of `--repo` (CONFIRMED inside, UNRESOLVED outside), `--strict` exit 0 for the inside one; a cited path outside every root is never touched on disk; the `$PWD` spelling of a relative `--repo` counts only when it names the same folder (a file in the folder a link's own `..` would name stays UNRESOLVED) | ✅ |
| RV-30 | A bundle or `--repo` under a folder nobody may enter (S29-PE-*) | the bundle: one `error: <bundle> cannot be read (Permission denied)` line, exit 2; a `--repo`: `! cannot read, skipped: <path> (<reason>)` and `--json` `repos_unreadable`, not `repos_skipped_not_git`; no traceback | ✅ |
| RV-34 | A line citation into a config-named repository's committed file, its untracked `.md`, and an absolute path into it, no `--repo` (0.9.50) | none is CONFIRMED or REFUTED; exit 0 | ✅ |
| RV-35 | A fixture commit whose 7-character short SHA has no digit (`faecdac`), cited through the suites' `cite_sha` (0.9.51) | cited by a prefix that holds a digit; CONFIRMED; exit 0 | ✅ |
| RV-36 | An `okf_check.verify.repos` entry with no `path` (`- {}`) (0.9.51) | config error `okf_check.verify.repos[0] needs path`; exit 2, no traceback, in okf-verify and in okf-check (RV-36c) | ✅ |
| RV-31 | Citations of one file at one commit (S29-SP-*) | 20 citations run at most 20 git processes in all (141 before); an answer from a git that could not run (killed, timed out) is not remembered: the next citation asks again | ✅ |

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

## 0.9.0 — warnings listed, trust check, init, CI doors

Full user stories and cases are in the private tracker. Rows are added by the ticket that ships them.

### L1 warning listing
Warning lines use the same capped listing as errors (`say_capped`, limit 50, "... and N more"): the cap and the wording are the existing helper's. They sit under the L1 line at the same indent as error lines (the spec text "+N more" and a two-space indent were replaced by that helper's form, so one cap style serves both).

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-25a | A note with `generated.by: Human:dana` | its warning prints as `<note>: <message>`, exit 0 | ✅ |
| LT-25b | A bundle with 0 warnings | no warning line prints | ✅ |
| LT-25c | A bundle with 3 warnings | the summary says 3 and exactly 3 lines print | ✅ |
| LT-25d | 60 warnings | summary says 60, 50 lines print, then "and 10 more" | ✅ |
| LT-25e | 51 warnings | summary says 51, 50 lines print, then "and 1 more" | ✅ |
| LT-25f | `--json` on a bundle with a warning | `warnings` list holds the `<note>: <message>` string; every 0.8.1 key is still present | ✅ |
| LT-25g | `--json` on a clean bundle | `warnings` is an empty list, not a missing key | ✅ |
| LT-25h | A bundle with one error and warnings | the FAIL line carries the warning count, so the warning lines under the error lines are accounted for | ✅ |

### Trust layer C4 — unauthenticated human verification
OKF v0.2 records `verified: by: human:<id>` and cannot authenticate it. The layer (`okf-trust.py`, run by `okf-check`) reports, per `verified` entry whose actor starts with `human:` (the FIRST matching row wins): a draft note → warning; `verified.at` earlier than `generated.at` → warning; an agent-generated note (`<producer>/<version>` or `agent:<id>`) → advisory. `process:` and other actors are never reported. Warnings and advisories both count into the final advisory tally; the layer line shows the split. The exit code stays 0 (`--strict-trust`). The vendored validator is not edited. The layer runs right after L1. The draft and changed-after warnings do not depend on the generator; only the advisory needs an agent generator, so a missing or near-miss `generated.by` gives no advisory (it still warns on a draft). A bare date compared with a timestamp is compared by day (a bare date cannot say which moment of the day). A note that starts with a UTF-8 BOM is read like any other. If the helper fails, the layer line says COULD NOT RUN with the helper's last error line, the exit code is 2, and `--json` reports `trust_findings` as `null` (unknown, not clean).

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-26a | Draft note, `agent/1` generator, `human:finance-owner` verifier (the 0.8.1 baseline: exit 0, no finding) | warning naming `verified[0].by` and the draft; identity line once; exit 0 | ✅ |
| LT-26b | Stable note, human generator, review after the change | no C4 finding | ✅ |
| LT-26c | Draft note with two `human:` entries | two warnings, one per entry | ✅ |
| LT-26d | Review dated before `generated.at` | warning "changed after the claimed review" | ✅ |
| LT-26e | Review dated after `generated.at` | no finding | ✅ |
| LT-26e2 | Review dated equal to `generated.at` | no finding (equal is not earlier) | ✅ |
| LT-26f | Agent-generated stable note, human verifier | advisory, not a warning; exit 0 | ✅ |
| LT-26g | `generated.by: agent:bot` | advisory (second agent form) | ✅ |
| LT-26g2 | Agent note, human verifier with no `at` | advisory only; no changed-after warning | ✅ |
| LT-26g3 | Human-generated note, human verifier | no advisory | ✅ |
| LT-26h | Three entries, only `verified[1]` is `human:` | only `verified[1].by` is reported | ✅ |
| LT-26i | Draft note with a `process:` verifier | never reported | ✅ |
| LT-26j | `process:` generator, `human:` verifier on a draft | warning (the generator type does not hide it) | ✅ |
| LT-26k | No `verified` field | no finding | ✅ |
| LT-26l | `verified: []` on a draft | no finding | ✅ |
| LT-26m | `verified` of the wrong shape (a string) | no crash, no C4 finding | ✅ |
| LT-26n | `verified` as a mapping on a draft | read as one event; warning | ✅ |
| LT-26o | Five findings | the identity line prints once | ✅ |
| LT-26p | A bundle with no C4 case | no C4 finding line | ✅ |
| LT-26q | `--json` on a bundle with a finding | `trust_findings` holds `{file, entry, severity, reason}` | ✅ |
| LT-26r | `--json` on a clean bundle | `trust_findings` is an empty list | ✅ |
| LT-26s | 0 L1 warnings and 2 advisories | L1 line `0 warning(s)`; layer line `2 advisory(ies)`; final tally 2 | ✅ |
| LT-26u | Stable note, empty `generated.by`, human verifier | no finding (no agent to flag) | ✅ |
| LT-26v | Stable note, near-miss generator `Human:dana`, human verifier | no C4 finding (L1 already warns about the actor) | ✅ |
| LT-26w | Draft note, near-miss generator, human verifier | warning (the draft row ignores the generator) | ✅ |
| LT-26x | Note that starts with a UTF-8 BOM | checked like any other note | ✅ |
| LT-26y | Review dated the same day as a timed `generated.at` | no finding (days compared when a side is a bare date) | ✅ |
| LT-26y2 | Review dated the day before a timed `generated.at` | warning | ✅ |
| LT-26z | The trust helper fails | COULD NOT RUN with the helper's error line, exit 2, not a pass | ✅ |
| LT-26z2 | `--json` when the trust helper failed | `trust_findings` is `null` (unknown), not `[]` | ✅ |

### `--strict-trust`
Severity only: with `--strict-trust`, every C4 finding (warning or advisory) and every L1 near-miss actor warning (`Human:dana`) makes the run exit 1. The findings are the same with or without the flag. A `Trust policy FAIL` line follows the trust layer. When no layer failed except the trust policy, the final line reads "FAILED (exit 1) — trust policy failure (--strict-trust)"; with any other layer failing (an L1 or L2 error, staleness, a layer that could not run), that layer's line comes first and the summary does not blame trust alone. No new exit code.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-27a | Draft note with a human verifier, `--strict-trust` | exit 1; "trust policy failure (--strict-trust)" | ✅ |
| LT-27b | The same bundle without the flag | exit 0 | ✅ |
| LT-27c | Advisory-only case (agent note, human verifier), `--strict-trust` | exit 1 | ✅ |
| LT-27d | L1 conformance error plus a C4 case, `--strict-trust` | exit 1; "not conformant" first; summary does not blame trust alone | ✅ |
| LT-27e | Near-miss generator `Human:dana` | exit 1 under the flag, exit 0 without | ✅ |
| LT-27f | Near-miss verifier `Human:dana`, `--strict-trust` | exit 1 | ✅ |
| LT-27g | Honest note, `--strict-trust` | exit 0, no trust line | ✅ |
| LT-27h | `--strict-trust --json` | one JSON line, `"exit":1` | ✅ |
| LT-27i | An unrelated warning whose quoted actor text contains "is a near-miss of" | not counted as a near-miss; exit 0 under the flag | ✅ |
| LT-27j | Trust failure plus a stale failure (`--fail-stale`) | exit 1; the summary does not blame trust alone | ✅ |
| LT-27k | Trust layer could not run, strict mode | the summary does not read as a plain trust-policy failure | ✅ |

### `--init-house-rules`
Without `<bundle>/okf-base.yaml` the L2 house-rules layer is SKIPPED. `okf-check --init-house-rules <bundle>` writes a starter `<bundle>/okf-base.yaml` (the path L2 reads), with the placeholder name set from the folder name (a name with anything but letters, digits, dot, dash, underscore or space falls back to `bundle`; no YAML escaping, by design). It is the ONLY writer of that file; it exits 1 and writes nothing when the file exists (also when it is empty), exits 64 without a usable bundle, and exits non-zero without creating anything when the folder is read-only. The skipped-L2 line names the command. `--json` carries `l2_profile` (`ran`, `skipped`, or `could_not_run` when L2 reached no verdict).

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-28a | `--init-house-rules <bundle>` | writes `<bundle>/okf-base.yaml`, name from the folder, exit 0 | ✅ |
| LT-28b | No bundle argument | usage, exit 64 | ✅ |
| LT-28c | Bundle path that does not exist | nothing created, exit 64, message "is not a directory" | ✅ |
| LT-28d | `okf-base.yaml` already exists (run twice) | exit 1, file byte-identical, message names the file | ✅ |
| LT-28e | An empty `okf-base.yaml` | still refused, left empty | ✅ |
| LT-28f | L2 on a freshly initialised bundle | L2 runs and passes, no placeholder text | ✅ |
| LT-28g | A Lesson without `stale_after` in that bundle | L2 reports it, exit 3 | ✅ |
| LT-28h | Folder name with YAML-special characters | name falls back to `bundle` | ✅ |
| LT-28i | Any check run, flag or preflight on a bundle without the file | the file is never created | ✅ |
| LT-28j | Read-only bundle folder | non-zero exit, nothing created | ✅ |
| LT-28k | Bundle without `okf-base.yaml` | the "not enforced" line names `okf-check --init-house-rules` | ✅ |
| LT-28l | Bundle with `okf-base.yaml` | the line is absent | ✅ |
| LT-28m | `--json` on a bundle without the file | `"l2_profile":"skipped"` | ✅ |
| LT-28n | okflint rejects the manifest (exit 2) | `"l2_profile":"could_not_run"`, not `ran` | ✅ |
| LT-28o | No okflint and no `okf-base.yaml` (found by the Debian run) | the skipped-L2 line names the okflint install AND `okf-check --init-house-rules` | ✅ |
| LT-28p | `--json` with okflint absent | `"l2_profile":"skipped"` | ✅ |

### GitHub Action and pre-commit entry
Two thin doors onto `okf-check`; they add no logic, so the verdict is the one Claude Code gets. `action.yml` (repo root) is a composite action: inputs `bundle` (required), `strict-trust` and `fail-stale` (`'true'`/`'false'`, default `'false'`, anything else exits 64); inputs reach the script through `env`, never interpolated into it; the step runs with `shell: bash` (`-eo pipefail`) so `okf-check`'s exit code is the job's. `.pre-commit-hooks.yaml` (repo root) defines hook `okf-check`: `language: script`, entry `plugin/scripts/okf-check`, default `args: ['.']`, `files: '\.md$'`, `pass_filenames: false`. The public example may use GitHub-hosted runners (owner-confirmed exception to the self-hosted-only rule, which covers the private repo). Read from the sources: a root `action.yml` is the composite-action docs' own shape; pre-commit's source (`pre_commit/repository.py` `_hook`, a dict update) makes a user's `args` REPLACE the hook's default, resolves the first token of `entry` from the hook repo root and appends args after it. S22 is run two ways: through a REAL git commit with a hook script that does what pre-commit does for this hook (files selector, no filenames, entry plus args), and, when the tool is installed, end to end by the real pre-commit tool against a hook repo it clones (LT-29n, LT-29o2, LT-29o3; run on pre-commit 4.7.0 on macOS; not run on Linux: UNVERIFIED there). The `files: '\.md$'` selector runs the check whenever any Markdown file is staged (the hook cannot know which Markdown files belong to the bundle); a commit that stages no Markdown file does not run it. A `bundle` input that starts with `-` is refused (exit 64): it would reach `okf-check` as a flag.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-29a | `action.yml` structure | composite; bundle required; strict-trust and fail-stale default false; `shell: bash`; inputs via env | ✅ |
| LT-29b | The action's script on a conformant bundle | exit 0, the okf-check verdict in the log | ✅ |
| LT-29c | No `bundle` input | the job fails; the message names the input | ✅ |
| LT-29d | Bundle path with a space | okf-check receives the whole path | ✅ |
| LT-29e | A bundle that exits 1 on the CLI | the job fails with exit 1 | ✅ |
| LT-29f | A layer that could not run (exit 2) | the job fails; never a pass | ✅ |
| LT-29g | `strict-trust: true` on a draft with a human verifier | the job fails | ✅ |
| LT-29h | `strict-trust: false` on the same bundle | the job passes | ✅ |
| LT-29i | `fail-stale: true` on an expired note | the job fails with exit 4 | ✅ |
| LT-29j | An input other than `true` or `false` | exit 64; the input is named | ✅ |
| LT-29k | `.pre-commit-hooks.yaml` structure | hook okf-check; script entry exists and is executable; no filenames; default arg `.`; `files` selects only `.md` | ✅ |
| LT-29l | The hook's command with `--strict-trust` on a draft with a human verifier (emulated) | blocks the commit (exit 1) | ✅ |
| LT-29m | The hook's command on a clean bundle (emulated) | lets the commit through | ✅ |
| LT-29n | The REAL pre-commit tool, clean bundle (hook cloned from a git repo; args `., --strict-trust`) | the commit goes through; the hook reports Passed | ✅ |
| LT-29o2 | The REAL pre-commit tool, draft note with a human verifier | the commit is blocked (`trust policy failure`); the user's args reached okf-check; HEAD unchanged | ✅ |
| LT-29o3 | The REAL pre-commit tool, a commit that stages no `.md` file | the hook is Skipped | ✅ |
| LT-29o | `bundle` is `--doctor`, `--selftest`, `--help` or `-h` | refused, exit 64; never passed to okf-check as a flag | ✅ |
| LT-29p | Real `git commit` of a clean bundle with the hook script | commits | ✅ |
| LT-29q | Real `git commit` of a draft note with a human verifier | blocked; HEAD unchanged | ✅ |
| LT-29r | Real `git commit` that stages no `.md` file | the check does not run | ✅ |

### README claims
The README states only what was measured or what the pinned files say. `LT-30a`..`LT-30i` compare it with the files that hold the facts (pin file, `VENDOR.md`) and with the tool's own words (`--latest` "may lack"), and forbid a promise of native Windows, a hedge word in a platform claim, and the stale "requires pyyaml" line.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-30a | README Platforms section | names macOS, Linux and Windows via WSL | ✅ |
| LT-30b | Every README line that mentions Windows | says WSL, no native support, or unsupported (a bare "not" does not count) | ✅ |
| LT-30c | The Windows row | labels WSL, the Action and the pre-commit hook on Windows UNVERIFIED | ✅ |
| LT-30d | Both pinned commits | full ids in the README equal the pin file and VENDOR.md | ✅ |
| LT-30e | Dependencies section | names okf-skills#68 and okflint#11 and says what happens if each is never merged | ✅ |
| LT-30f | CI and usage | Action, pre-commit hook, `--strict-trust`, `--init-house-rules`, python3 prerequisite shown | ✅ |
| LT-30g | `--latest` | the README uses the tool's own words ("may lack the fixes") | ✅ |
| LT-30h | Install section | no longer says PyYAML must be installed (it is vendored) | ✅ |
| LT-30i | Platform claims | no hedge words | ✅ |

### Agent-ready plugin
Source: the `plugin-dev` validator and skill-reviewer agents plus Anthropic's pages (plugins-reference: a plugin's `bin/` is on the Bash tool's PATH while the plugin is enabled; the Agent Skills best-practices page: third-person description of what and when, body under 500 lines, references one level deep). `plugin/bin/okf-check` and `plugin/bin/okf-verify` are pass-through wrappers (no logic; they follow a symlink to themselves). `skills/okf/SKILL.md` is the agent-facing document; maintainer detail lives in `references/`, moved verbatim. UNVERIFIED until the T7 reinstall and a new session: that Claude Code really puts `bin/` on PATH (`command -v okf-check`).

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-31a | Each wrapper vs the real tool | same `--version`, same exit code for a bad flag, from any directory | ✅ |
| LT-31b | `bin/` first on PATH | a bare `okf-check` resolves to the wrapper | ✅ |
| LT-31c | `plugin/LICENSE` | equals the repository LICENSE (a marketplace install copies only `plugin/`) | ✅ |
| LT-31d | SKILL.md content | strict-trust, init-house-rules, Trust (C4), exit precedence, a never-list, the Action and hook, okf-verify | ✅ |
| LT-31e | SKILL.md exit table | row 1 mentions strict-trust / Trust; row 64 exists | ✅ |
| LT-31f | SKILL.md frontmatter | third-person description naming okf-verify, at most 1024 chars; argument-hint lists the 0.9.0 flags; at most 500 lines | ✅ |
| LT-31g | References | every linked reference exists; none links another (one level deep) | ✅ |
| LT-31h | A symlink to a wrapper on PATH | behaves like the real tool (was exit 126) | ✅ |
| LT-31i | Text moved out of SKILL.md | every okf-verify, install and setup rule is still in SKILL.md or a reference | ✅ |
| LT-31j | `--strict` wording | also fails on notes with no checkable claim (okf-verify D-9) | ✅ |
| LT-31k | README | says the commands are on the Bash tool's PATH while the plugin is enabled | ✅ |

### Release review fixes (0.9.0)
Found by the three release reviewers (integration, spec coverage, claims and security) on `release/v0.9.0`. A YAML alias bomb is a small note whose `str()` expands to billions of items; the trust helper never stringifies a non-string (`as_text`). The same bomb hangs the vendored L1 validator in 0.8.1 too; that is reported to the owner, not changed here.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-32a | The trust layer stops firing (helper crippled) | `--selftest` FAILS with exit 5 and names the C4 probe | ✅ |
| LT-32b | A YAML alias bomb in `verified.by` / `generated.by` | the trust helper finishes within 3 s and ignores it | ✅ |
| LT-32c | A finding in a subfolder | named with its path (`notes/a.md`) | ✅ |
| LT-32d | A draft note with a human generator and a human verifier | still warns | ✅ |
| LT-32e | The other two hooks (lessons-staleness-check, doc-reuse-guard) | never create `okf-base.yaml` or `.okfignore` | ✅ |
| LT-33a | The Action given an invalid `strict-trust` containing a newline | exit 64; one `::error::` line; the value is not echoed | ✅ |
| LT-33b | README | says `okflint` (L2) needs Python 3.12 or newer | ✅ |

### YAML alias bomb in L1 and L2 (0.9.1)
A small note whose YAML aliases nest describes billions of items; `str()` on such a value took 4 s and 1094 MB on a 7-level bomb and 2.5 GB on a 9-level one in the vendored validator (identical in 0.8.1). One bounded loader (`load_frontmatter` in the vendored validator, reused by `okf-trust.py`) composes the node graph, counts the alias-expanded size with a memo (no expansion) as two separate numbers, items and scalar characters (one 1 MB scalar repeated by 300 aliases is only 302 items but 300 MB), and refuses a document above 1,000,000 items or 10,000,000 characters as an ordinary invalid-YAML error, which L1 reports as a §11.1 error on that note (a warning for the root `index.md`). The trust helper and the derived-staleness scan use the same loader. `okflint` is an external tool that expands the same bomb, so when L1 rejected any note that way, L2 is not run: `COULD NOT RUN`, with the reason. The guard matches the validator's own message, not a note's path. The vendored file therefore carries a LOCAL patch on top of the pinned upstream commit; `VENDOR.md` lists it.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-34a | An alias bomb in `verified.by`, `generated.by` or `title` | L1 ERROR §11.1 naming the note, exit 1, peak memory under 400 MB (measured 19 MB), within 5 s | ✅ |
| LT-34b | A modest alias (one anchored list reused twice) | parses; exit 0; L1 PASS | ✅ |
| LT-34c | A bomb with `okflint` installed and a manifest | `okflint` is not run; `L2 profile COULD NOT RUN` names alias bombs; exit 1 from L1; peak memory under 400 MB | ✅ |
| LT-34d | One 100 KB scalar repeated by 300 aliases (30 MB expanded from 302 items) | refused by the character limit: exit 1, peak under 400 MB | ✅ |
| LT-34h | A 5-level mapping bomb (12^5 leaves) | refused by the item limit: exit 1, peak under 400 MB (the single merged limit once let it through) | ✅ |
| LT-34e | A bomb in `sources[].resource` | refused in L3 derived staleness too: exit 1, peak under 400 MB | ✅ |
| LT-34f | A bomb in the root `index.md` (a warning in L1) with `okflint` installed | `okflint` is not run: `COULD NOT RUN` naming alias bombs | ✅ |
| LT-34g | A note whose PATH contains the words "alias bomb", with an ordinary L1 error | `okflint` still runs | ✅ |
| LT-35a | The vendored validator, the trust helper and `okf-check` | all parse frontmatter with `load_frontmatter`; no bare `yaml.safe_load` remains | ✅ |
| LT-35b | `VENDOR.md` | lists the local patch and still names the pinned upstream commit (the literal id is held in the test) | ✅ |
| LT-42 | L3 fence rule | trailing blanks on a fence are accepted as in L1; a `---` block after the closing fence is body | ✅ |
| LT-43 | Trust actors | a mixed-script or NFKC-folding look-alike of `human:` is a near-miss; string `verified` and a bare `generated.by` token are read | ✅ |
| LT-44 | L1/L3 robustness | deep nesting is an L1 error; duplicate keys, an empty `stale_after` and a future `generated.at` are reported | ✅ |
| LT-45 | `--json` | carries `errors[]`, `stale[]`, `l2_findings[]`, `skipped[]`; valid for any bundle path; one key set on every exit path | ✅ |
| LT-48 | file walkers | the staleness hook survives a directory name with a newline; with or without an active `.okfignore`, a note behind a folder link that points outside the bundle is not a bundle note (S8-N1, since) | ✅ |
| S8-H1 | one note reached through a symlinked folder alias | L3 lists it once, under its real path | ✅ |
| S8-N1 | a symlinked folder that points outside the bundle | its notes are not counted by any layer; the run names every symlinked folder it did not enter | ✅ |
| S8-E1 | one tree with folder links, note-file links and a dangling link | L1, Trust, L3, `.okfignore` walker, `okf-verify` and the staleness hook return the same file set; a note-file link outside the bundle is in none of them (`symlinks.test.sh`) | ✅ |
| S58-N1 | a note-file symlink whose real path is outside the bundle | no layer reads it; it is named once (`points outside the bundle: not read`) and the run exits 1 (`symlinks.test.sh`) | ✅ |
| S58-R1 | a path swapped to an outside file after the path check | the reader refuses the opened descriptor; `root` is required | ✅ |
| S58-R2 | an okf-export vault file swapped to an outside link after the listing | not written, not indexed, named; exit 1 | ✅ |
| S58-H2 | the bundle path typed in another case (case-insensitive disk) | an inside link is read, an outside one refused | ✅ |
| S58-N3 | `okf-base.yaml`, `.okfignore` or another config file as a symlink whose real path is outside | named, not read, the run does not pass | ✅ |
| S58-E1 | the same note under `--facts`, `--duplicates`, `--file`, the edit hook, `--conserve`, `okf-verify` | not read in any of them | ✅ |
| LT-49 | `--json` L2 counts, L3 lifecycle | `l2_warnings` and `l2_by_rule` carry the text's L2 advisory totals (null when L2 did not run); an unknown `status` is a separate L3 lifecycle line and `lifecycle[]`, never counted as expired, and `--fail-stale` exits 4 only for expired notes | ✅ |
| LT-50 | `--doctor` search binary | `--doctor` says whether the optional `okf` search binary is present (the doc-reuse closest-notes hint) and what is off without it | ✅ |
| LT-47 | GitHub Action | warns on 0 concepts and on each skipped layer; `require-house-rules: true` exits 3 when L2 was skipped; other values exit 64 | ✅ |
| LT-46 | L2 wikilinks | an L001 whose path-qualified target exists is dropped and counted | ✅ |
| SC-1..2 | `--file <note>` | a note with an L1 error prints one line per finding and exits 1; a clean note prints nothing and exits 0 | ✅ |
| SC-3..4 | `--file` vs a full run | the scoped findings equal the full validator + Trust findings for that note, none from other notes; `--strict-trust` blocks as in a full run | ✅ |
| SC-5..7 | `--file` edges | outside the bundle, not `.md`, missing, or no value: exit 64; an `.okfignore`-excluded note is not checked (one line); a crashing helper is exit 2, never an L1 verdict | ✅ |
| SC-8 | `--file` speed | on a 100-note bundle, under half the time of a full run on the same bundle (median of 3; about 0.1 s against 0.65 s measured, so well under the 1 s) | ✅ |
| SC-9 | `--selftest` | a `Scoped (--file)` probe fires on a note without frontmatter; a copy whose helper drops every finding reports `NOT FIRED` and exits 5 | ✅ |
| S9-H1 | edit hook on (`edit_hook: true`), a note with an L1 error is edited | exit 2 and ONE stderr line `okf-check: <finding>` (Claude sees it, https://code.claude.com/docs/en/hooks) | ✅ |
| S9-N1 | edit hook with no key, `false`, or an invalid block | nothing runs, nothing printed; `OKF_EDIT_HOOK=1` turns it on | ✅ |
| S9-N2 | a file in no bundle, or not `.md` | ignored | ✅ |
| S9-E1 | the check outlasts the hook's time box | killed with its children, exit 0, no warning | ✅ |
| SH-7 | the hook run by a plain python3 that writes bytecode beside the module (as on Linux) | no `__pycache__` left in the plugin directory (LT-56m's rule) | ✅ |
| LT-52 edit_hook | `edit_hook: true/false` vs `yes` (unquoted), `"on"`, `1` | both tools accept true and false and refuse the rest (one schema, boolean leaf; an unquoted YAML 1.1 word since 0.9.35, B-7) | ✅ |

### The `okf_check:` options block (0.9.4)
okf-check's own options live in ONE `okf_check:` block of `okf-base.yaml`; each option is off by default. `okflint` 0.5.0 reads only the manifest keys it knows, so the block is not stripped before L2: the L2 warning count with and without it is equal, and LT-51b pins that against the real `okflint`. A block of the wrong shape or a key nobody knows is reported on a `Config` line and in `errors[]`, and the run exits 2: a typo would otherwise switch an option off in silence. The rules live ONCE, as data, in `plugin/config/okf-check-block.json` (each option's ticket adds its key there); `okf-verify` enforces them and `okf-check` calls `okf-verify --check-config`, so the two tools cannot disagree. LT-52 feeds one table of block shapes to both tools and asserts they agree. No block: no `Config` line, and text and `--json` output are byte-identical to the build before this change.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-51a | S4-N1: an unknown key inside `okf_check:` | exit 2; the output names `okf_check.<key>` | ✅ |
| LT-51b | S4-H1: a valid `okf_check:` block, real `okflint` | `l2_profile`, `l2_warnings` and `l2_by_rule` equal the run without the block (SKIPPED when `okflint` is absent) | ✅ |
| LT-51c | S4-E1: no `okf_check:` block | text and `--json` output and exit code byte-identical to the same build with the okf_check step deleted | ✅ |
| LT-52 | One table of `okf_check:` shapes (valid, wrong type, null, list, typo'd key, unknown entry key, empty path, invalid UTF-8, invalid YAML; `deprecated_requires` valid, typo'd, a list and null; `require_owner`/`owners` valid, a string for the boolean, a list, an int or empty owner, and `owners` without `require_owner: true`; `duplicates` valid, out of bounds, a string, zero and a typo'd key; `body_threshold` valid and out of bounds) to BOTH tools | both exit 0 on a valid block; both exit 2 on an invalid one, and `okf-check` shows `okf-verify`'s message | ✅ |

### `--selftest` covers every layer (0.9.6)
`--selftest` has a probe for each layer: L0 (the doctor, pointed at a validator path that does not exist, must say `MISSING`), L1, L2 profile, L2 index (an `index.md` that declares 5 notes for the 1-note baseline; the original `index.md` is put back), Trust, L3 staleness and L3 derived staleness (a note that records the baseline note as of 2000-01-01). Each new probe is proven by a plugin copy with that layer disabled: `--selftest` then reports `NOT FIRED` (the Gherkin "did not fire") and exits 5. Without `okflint` the L2 profile probes are SKIPPED with the reason, and the verdict line names the skipped layer instead of "every gate still fires"; the exit stays 0, as for a skipped layer in a check.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-55a | S3-H1: L3 derived probe, healthy install | `L3 (derived staleness):` `FIRED`; exit 0 | ✅ |
| LT-55b | S3-N1: L3 derived staleness disabled | its probe `NOT FIRED`; exit 5 | ✅ |
| LT-55c | S3-H1: L2 index probe, healthy install | `L2 (index):` `FIRED`; exit 0 | ✅ |
| LT-55d | the L2 index count check disabled | its probe `NOT FIRED`; exit 5 | ✅ |
| LT-55e | S3-H1: L0 probe, healthy install | `L0 (doctor):` `FIRED`; exit 0 | ✅ |
| LT-55f | the doctor's validator check disabled | its probe `NOT FIRED`; exit 5 | ✅ |
| LT-55g | S3-E1: `okflint` absent | `L2 (house profile): SKIPPED — okflint absent`; the verdict names the skip and never says "every gate still fires"; exit 0 | ✅ |

### Deprecation names a successor (okf-knowledge-gate#9, 0.9.7)
`okf_check.deprecated_requires: superseded_by` turns the rule on; it is off by default. Every `status: deprecated` note must carry `superseded_by`: a path, a `[[wikilink]]`, a markdown link (also with a title, `[x](new.md "t")`, or in angle brackets, `[x](<new.md>)`), or a list of them. Each is resolved like the L2 wikilink rule (LT-46): from the bundle root or the note's own folder, with or without `.md`, and only inside the bundle. Each problem is its own error on the `Successor` line and in `errors[]`: no `superseded_by`; `successor not found`; `a note cannot supersede itself`; `successor is not a note` (`index.md` and `log.md` are reserved files); a successor that is deprecated too (`point at the final successor, not a deprecated one`: one hop, chains are not followed). Any error is a house-rule error, exit 1. The value is checked by the shared schema (`config/okf-check-block.json`, an `enum` node, RV-24): any value other than `superseded_by` is a `Config` error, exit 2, naming the value, and the rule stays off. Option off: no `Successor` line.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-53a | S5-N1: deprecated, no `superseded_by` | `Successor FAIL`, the error names the note; exit 1 | ✅ |
| LT-53b | S5-H1: `superseded_by` names an existing stable note | `Successor PASS`; exit 0 | ✅ |
| LT-53c | S5-N2: a missing file, the note itself, another deprecated note | one error each with its own message; exit 1 | ✅ |
| LT-53d | S5-E1: a list of a path and a `[[wikilink]]` to existing notes | `Successor PASS`; exit 0 | ✅ |
| LT-53e | S5-E2: option off, deprecated note without a successor | exit 0; no `Successor` line | ✅ |
| LT-53f | S5-N3: `deprecated_requires: superseded-by` (unknown value) | exit 2; the output names the value | ✅ |
| LT-53g | `--selftest` | a `Successor (deprecated_requires)` probe fires (the option is on for that probe only); a copy with the rule disabled reports `NOT FIRED` and exits 5 | ✅ |
| LT-53h | `[x](new.md "t")`, `[x](new.md 't')`, `[x](<new.md>)` | each resolves to new.md: `Successor PASS` | ✅ |
| LT-53i | `superseded_by: index.md`, `"[[log]]"` | `successor is not a note`; exit 1 | ✅ |
| LT-53j | option on, no deprecated note | `Successor PASS no deprecated notes` | ✅ |

### Ownership (okf-knowledge-gate#11, 0.9.8)
`okf_check.require_owner: true` turns the rule on; it is off by default. A note's owner is its own `owner` key; without one, the folder default from `okf_check.owners` (a mapping of glob to owner, in file order). The globs use the `.okfignore` syntax without negation (a pattern that starts with `!` is a `Config` error, exit 2: it would be inert) and are matched by the same matcher (`ignore-lib.sh`), and the LAST matching pattern wins, not the most specific one. The owner must be a section 7 actor, checked by the vendored validator's own `check_actor` (the check L1 runs on `generated.by`): a value with no actor shape (`team-x`) and a near-miss of `human:` (`Human:dana`) are errors, for a note's key and for a folder default alike. A note with no owner and an owner that is not an actor are house-rule errors on the `Owner` line and in `errors[]`, exit 1. Every L3 staleness and lifecycle finding of a note with an owner ends with ` owner <actor>`, in the text and in each string of `--json` `stale[]` and `lifecycle[]` (no new JSON key: the LT-45 key set is unchanged). The values are checked by the shared schema (`config/okf-check-block.json`): `require_owner` is a `{type: boolean}` node, `owners` a `{map: {type: string}}` node (free glob keys) that `requires` `require_owner: true` (RV-25). A `require_owner` that is not `true`/`false`, `owners` that is not a mapping or has a value that is not a non-empty string, and `owners` without `require_owner: true` are a `Config` error, exit 2, named; the owner rule then does not run, so a default such as `3` never becomes an owner error that outranks that exit 2. Option off: no `Owner` line and no owner on findings. Decided: the Gherkin's `owner: team-x` is not a section 7 actor (S6-E3 makes it an error), so S6-H1 uses `team:x` (and S6-H2 `team:a`); the Gherkin and the cases doc say so.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-54a | S6-N1: option on, a note with no owner and no default | `Owner FAIL`, the error names the note; exit 1 | ✅ |
| LT-54b | S6-H1: `owner: team:x` on an expired note | the stale line and its `stale[]` string end with `owner team:x`; exit 0 | ✅ |
| LT-54c | S6-H2: `owners: {"decisions/**": team:a}`, a note under `decisions/` with no owner | owner `team:a` | ✅ |
| LT-54d | S6-E1: two patterns match | the later one wins, in either order | ✅ |
| LT-54e | S6-E2: a note owner and a different folder default | the note's owner | ✅ |
| LT-54f | S6-E3: `team-x`, `Human:dana`, a folder default `team-a` | an error names the note and the value; exit 1 | ✅ |
| LT-54g | a lifecycle finding (status `current`) of a note with an owner | its `lifecycle[]` string ends with `owner team:y` | ✅ |
| LT-54h | option off, a note with an `owner` key | no `Owner` line, no owner on the stale line; exit 0 | ✅ |
| LT-54i | S6-N2: `require_owner: yes-please`; `owners` as a list; `owners` without `require_owner` | exit 2, the key named | ✅ |
| LT-54j | `--selftest` | an `Owner (require_owner)` probe fires (the option is on for that probe only); a copy with the rule disabled reports `NOT FIRED` and exits 5 | ✅ |
| LT-54k | S6-E4: a note that starts with a UTF-8 BOM (`owner: team:x`; and a deprecated one without a successor) | the owner is read; the Successor rule sees the deprecated note (exit 1) | ✅ |
| LT-54l | `owner: "human:"`; `owner: human:` (not valid YAML) | `not an allowed actor form`; `the frontmatter is not valid YAML, so its owner cannot be read` (never `no owner`) | ✅ |
| LT-54m | S6-N3: `owner: [team:x]`, `owner: 0`, `owner: false` | `owner \`["team:x"]\` is not an allowed actor form` (the value as JSON; never a Python repr on the L3 line); exit 1 | ✅ |
| LT-54n | S6-N4: an `owners` pattern `"!drafts/**"` | `okf_check.owners.!drafts/**: a pattern that starts with ! (negation) is not supported`, exit 2 (also RV-25 and the LT-52 parity row) | ✅ |

### `--duplicates`: candidate duplicate notes (okf-knowledge-gate#10, 0.9.9)
`okf-check <bundle> --duplicates` is a report of its own, not a gate: it runs instead of the layers and exits 0 once it ran (exit 2 when the `okf_check` block fails the schema, as in a check; under `--json` every stop with exit 2 still prints one JSON document with `exit`, `layers_not_run` and `reason`, and the reason goes to stderr: S38-ST-N1..N6). A pair of concept notes is a candidate when the titles are equal after normalization (NFKC, lower case, punctuation to spaces, spaces folded), when both cite the same `sources[].resource` (normalized path), or when the descriptions' word sets overlap (Jaccard) at or above `okf_check.duplicates.threshold`. The strongest signal is shown with its score, both statuses, both `generated.at` values and both effective owners (the note's key, else the folder default). A pair already linked by `superseded_by`, either way, is skipped; notes excluded by `.okfignore` are not compared. `--json` gives `duplicates[]`, `complete`, `compared` and `pairs_total` (keys of this mode only). The comparison stops at `okf_check.duplicates.time_limit` (default 60 s) and then says `CUT SHORT` with the number of pairs compared.

The threshold default is **1.0** (identical description word sets only). It was chosen on a labelled sample of five private knowledge-base vaults (1,034 notes): all 71 candidate pairs (53 same-title, 18 description overlap ≥ 0.5, 0 same-resource; all in one vault) plus 30 random pairs with 0 < overlap < 0.5, labelled DUP/NOT by a fresh-context agent that saw only the two notes' title, description and body start, never a score. Same title: 53 of 53 DUP. Description overlap: 0 of 18 DUP at every threshold from 0.5 to 0.93 (the pairs were templated series: register part 1/2/3, one questions note per team). No threshold below 1.0 reached precision 0.8, so 1.0 is the conservative default and a bundle can lower it. The labels are agent-made, so these precision figures are INFERRED-grade; the pair list is kept out of the repository (the ticket carries counts and pair hashes).

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-56a | S7-N1: no candidate pairs | `no candidate duplicates`; exit 0 | ✅ |
| LT-56b | S7-H1: `Deploy rule` and `deploy  RULE!` | `title 1.00`, both paths, statuses, `generated.at` and owners; exit 0 | ✅ |
| LT-56c | S7-H2: descriptions overlapping 0.86, `threshold: 0.5` | `description 0.86` listed | ✅ |
| LT-56d | the same pair, no option | not listed (default threshold 1.0) | ✅ |
| LT-56e | S7-E2: a same-title pair linked by `superseded_by`, either direction | not listed | ✅ |
| LT-56f | the same `sources[].resource` (`docs/api.md`, `./docs//api.md`) | `resource 1.00` listed | ✅ |
| LT-56g | `require_owner` with a folder default | the effective owner of each note is shown | ✅ |
| LT-56h | S7-E1: 1,000 notes | complete within the 60 s default; no `CUT SHORT` | ✅ |
| LT-56i | S7-E1: the time limit reached (`OKF_DUP_TIME_LIMIT`, tests only) | `CUT SHORT ... N of 500500 pairs compared`; exit 0 | ✅ |
| LT-56j | `--duplicates --json` | `duplicates[]` with signal and both notes; `complete: true`, `pairs_total` | ✅ |
| LT-56k | a same-title note under a `.okfignore`d folder | not compared | ✅ |
| LT-56l | `duplicates.threshold: 5` | `Config` error naming it, exit 2, nothing listed | ✅ |
| LT-56m | a plugin without `okf_notes.py` (the note reader the successor, owner and duplicates rules share) | exit 2 naming the file; the rules never switch themselves off | ✅ |
| LT-56n | `--selftest` | a `Duplicates (--duplicates)` probe fires on a note titled like the baseline note; a copy with the title signal disabled reports `NOT FIRED` and exits 5 | ✅ |
| LT-56o | a BOM-prefixed note with the same title | listed (the shared `okf_notes.py` reader decodes `utf-8-sig`, as L1 does) | ✅ |
| LT-56r | a symlink alias of a note, and a third note with the same title | one pair, under the real note, not the alias: the report keeps one entry per real path | ✅ |

### `--duplicates-body`: similar bodies (okf-knowledge-gate#10, 0.9.10)
`okf-check <bundle> --duplicates-body` is `--duplicates` plus a `body` signal: the Jaccard of the two bodies' 5-word shingle sets (after the same normalization as titles) at or above `okf_check.duplicates.body_threshold` (default **0.6**). Candidates come from MinHash signatures (64 permutations of one 64-bit hash, seeded, so a run is repeatable) in 32 bands of 2 rows, which a pair at J=0.3 reaches with probability 0.95 and at 0.5 with 1.00; each candidate is then checked exactly, so the banding can miss a pair close to the threshold but never invents one. A pair already listed by a stronger signal, or linked by `superseded_by`, is not listed again. The same `time_limit` applies, with `CUT SHORT`. The default 0.6 is measured on bodies: the 24 body pairs a 0.3 run found in one live vault plus 20 random pairs with 0 < body overlap < 0.3, labelled DUP/NOT by a fresh-context agent blind to scores. At 0.3, 12 of 24 were DUP (precision 0.50); every NOT was at or below 0.57 and every pair from 0.62 up was DUP, so 0.6 is the lowest threshold with precision ≥ 0.8 (5 of 5, 1.00); all 20 controls were NOT. On the sample 0.6 also has precision 1.00 (43 of 43). The labels are agent-made, so the figures are INFERRED-grade.

| ID | Scenario | Expected | State |
|---|---|---|---|
| LT-57a | S7-E3: two notes whose bodies share a long paragraph | `body 0.xx` listed; exit 0 | ✅ |
| LT-57b | the same notes with plain `--duplicates` | not compared, not listed | ✅ |
| LT-57c | `body_threshold: 0.95` | the pair below it is not listed | ✅ |
| LT-57f | `body_threshold: 0.3`, a body pair at 0.3-0.5 | found by the banding (8 bands of 4 rows missed it) | ✅ |
| LT-57g | the same pair, no option | not listed: the default body_threshold is 0.6 | ✅ |
| LT-57d | S7-E3: 1,000 notes of 200 words | complete within the 60 s default | ✅ |
| LT-57e | S7-E3: the limit reached | `CUT SHORT`; exit 0 | ✅ |
| LT-57h | `--selftest` | a `Duplicates (--duplicates-body)` probe fires on a note whose body equals the baseline note's; a copy with the body signal disabled reports `NOT FIRED` and exits 5 | ✅ |
| LT-57i | a BOM-prefixed note with the same body | `body 1.00` (the body is read after the frontmatter, `utf-8-sig`) | ✅ |

## Non-goals

- Installing or upgrading dependencies WITHOUT being asked (UC-3: *report* by default; *act* only on `--install-deps --yes` or the owner's `OKF_AUTO_INSTALL=1`)
- Rewriting bundle content — `okflint index --apply` is deliberately never invoked;
  it regenerates `index.md` as a flat list and would destroy a curated one
- Replacing either upstream tool. This composes them; it owns only the staleness
  layer and the orchestration.
