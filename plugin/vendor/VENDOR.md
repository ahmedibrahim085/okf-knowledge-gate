# Vendored dependencies

Two, both MIT, both pinned. The point of vendoring is that L1 runs on a machine
that has never seen this repo — no clone, no network, no install step.

## okf_validate.py — OKF v0.2 conformance checker

- **Upstream:** https://github.com/scaccogatto/okf-skills
- **Path:** `skills/validate/scripts/okf_validate.py`
- **Pinned commit:** `7ed3084267d050f198eea6cd9f67d5357e9ed047` on branch `fix/validate-62-66` of https://github.com/ahmedibrahim085/okf-skills (okf-skills 0.10.4: upstream 0.10.3 + five fixes)
- **License:** MIT (Marco Boffo, 2026) — `LICENSE.okf-skills`
- **Run by itself:** `okf_validate.py` skips a sub-folder nobody may enter and then reports the bundle conformant (checked: a `chmod 000` sub-folder gave "conformant — no issues", exit 0, under Python 3.9.6). `okf-check` stops at such a folder ("no verdict is possible") before it runs the validator, so use `okf-check`, not the bare file.
- **Modified:** YES. Upstream `main` 0.10.3 plus five fixes (#62-#66), open as scaccogatto/okf-skills PR #68. When #68 merges: re-vendor from upstream at the merge commit and set **Modified** back to "no". If #68 is closed unmerged, this file stays our patched copy and the diff against upstream is `git diff upstream/main...fix/validate-62-66 -- skills/validate/scripts/okf_validate.py`.
- **Local patch (0.9.1), not in the pinned commit; offered upstream as commit 94e808b4 of PR #68 (open on 2026-10-23):** `load_frontmatter`, `AliasBombError`, `_children`, `_expanded_size`, `MAX_EXPANDED_ITEMS`, `MAX_EXPANDED_CHARS` and `MAX_SCALAR_CHARS` in `okf_validate.py`, and an `AliasBombError` clause in `check_index`. They replace the three `yaml.safe_load(raw)` calls with a loader that counts the alias-expanded size of a document (items and scalar characters, tracked separately) on the shared node graph and refuses one above 1,000,000 items or 10,000,000 characters, or any single scalar above 100,000 characters (a 2,000,000-digit integer took 47 s to build on Python 3.9), as an ordinary invalid-YAML error (a YAML alias bomb used to take 1094 MB and 4 s on a 7-level bomb and 2.5 GB on a 9-level one). `scripts/okf-trust.py` and the derived-staleness scan in `scripts/okf-check` import the same loader. **Modified stays YES after #68 merges:** re-vendor from upstream, then re-apply this patch if the merged PR does not hold 94e808b4 (tests LT-34a..i and LT-35a..b fail if it is lost).
- **Local patch (0.9.2), not in the pinned commit and not in PR #68:** `_near_miss` in `okf_validate.py` replaces the `ACTOR_HUMANISH` test in `check_actor`: besides a different case (`Human:`), it flags a spelling that folds to `human`/`process` under NFKC (fullwidth) and a prefix that mixes ASCII and non-ASCII letters (`humаn:` with a Cyrillic а); a prefix wholly in another script is not flagged. Also in 0.9.2: `load_frontmatter_ex` (returns the data and the duplicate keys; `load_frontmatter` wraps it) turns a `RecursionError` from a deeply nested document into the same `AliasBombError`, and `check_concept` warns on a duplicate key; `check_not_future` warns when `generated.at` is later than tomorrow. Tests LT-43a..c and LT-44a..e fail if they are lost. **Modified stays YES after #68 merges.**
- **Local patches (0.9.41, #157), not in the pinned commit and not in PR #68** (`gh pr diff 68` holds neither `check_log`, `Counter` nor `strip_fences`; the PR was still open on 2026-10-22): (1) `_duplicate_keys` counts the keys of a mapping once with `collections.Counter`; our 0.9.2 patch called `keys.count(k)` for every key, which is O(n^2): 60,000 keys (0.6 MB) took 40 s or more (39.66 s and 55.86 s measured), and every layer that re-reads the note paid it again; now 0.07 s, same result. (2) `strip_fences` is the fence walk that was inside `strip_code` (`strip_code` is unchanged in behaviour), and `check_log` reads its lines, so a `## ` line inside a fenced block no longer gives a false "date heading is not ISO 8601" warning; an unclosed fence hides the rest of the log, as it does for link checks. Tests S31-VD-E1, E1b, H1, N1, N2 fail if they are lost (E1, E1b, H1, N1 are RED on the 0.9.40 validator; N2 is the unchanged-behaviour guard: a real bad heading still warns). **Modified stays YES after #68 merges.** Offer both upstream if the owner wants.
- **Spec:** OKF v0.2 — https://github.com/ahmedibrahim085/okf-skills/blob/7ed3084267d050f198eea6cd9f67d5357e9ed047/skills/okf/reference/SPEC.md (the SPEC.md shipped with the pinned fork commit; upstream 0.10.3 content)

A single self-contained file whose only dependency is PyYAML. Vendoring removes
an install step from every new machine, pins the exact behaviour the gate was
verified against, and makes any upstream change an auditable diff rather than a
silent update.

## pyyaml — YAML parser (pure-python only)

- **Upstream:** https://github.com/yaml/pyyaml
- **Version:** 6.0.3
- **License:** MIT (Ingy döt Net, Kirill Simonov) — `LICENSE.pyyaml`
- **Modified:** no, but **incomplete on purpose** — see below.

### The C extension is deliberately NOT vendored

Upstream ships `_yaml.cpython-39-darwin.so`, a compiled extension tied to one
platform AND one Python minor version. Vendoring it would break every machine
that is not this one — the exact opposite of the goal. PyYAML's `__init__.py`
imports `cyaml` inside a `try/except ImportError`, so its absence degrades to the
pure-python loader: identical results, and no measurable cost at this scale —
46 frontmatter blocks parse in 10.6 ms without libyaml, 10.7 ms with it.
Verified with `python3 -S` (site-packages disabled): `__with_libyaml__ == False`,
`safe_load` correct.

### The vendored copy wins, on purpose

An earlier version of this file claimed `okf-check` appends to `PYTHONPATH` so
that "a system PyYAML still wins when present". That was **false**, and the
review that caught it is worth recording: Python searches the whole of
`PYTHONPATH` before `site-packages`, so append-vs-prepend never affected the
system copy at all. Measured — plain `python3` loads
`~/Library/Python/3.9/.../yaml`; with the vendor dir anywhere in `PYTHONPATH`,
it loads the vendored one.

What append *did* change was the ordering against entries **already** in
`PYTHONPATH` — and there it lost. A `yaml` module inherited from the environment
outranked the pin. Test G-7 makes the consequence concrete with a decoy parser
that reports every file as a conformant concept: under the old ordering, a
bundle whose only concept has no `type` key came back PASS.

So `okf-check` now **prepends**. The pin exists to make one bundle produce one
verdict on any machine; ambient environment is precisely the variance it has to
outrank. The scope is narrow — `py_with_vendor` sets the variable per
invocation for the validator alone, never exports it, so `okflint` keeps its own
compiled copy (test G-2). `--doctor` reports which copy is in play.

This was a reviewer finding: the claim "runs on a new machine" was false while
PyYAML was a hard external dependency. Covered by test N-17, which runs the whole
gate under an interpreter with no site-packages and asserts it still DETECTS a
non-conformant bundle — a vendored dependency that cannot fail is worthless.

## Refreshing either pin

    diff <upstream-file> vendor/<file>          # review, then copy
    # update the pin above, then:
    plugin/scripts/okf-check --selftest         # MUST still pass

Never refresh without re-running `--selftest`. An upgrade that silently stops
catching what it used to catch is indistinguishable from a passing run.
