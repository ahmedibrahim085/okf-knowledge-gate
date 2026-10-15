# Vendored dependencies

Two, both MIT, both pinned. The point of vendoring is that L1 runs on a machine
that has never seen this repo — no clone, no network, no install step.

## okf_validate.py — OKF v0.2 conformance checker

- **Upstream:** https://github.com/scaccogatto/okf-skills
- **Path:** `skills/validate/scripts/okf_validate.py`
- **Pinned commit:** `7ed3084267d050f198eea6cd9f67d5357e9ed047` on branch `fix/validate-62-66` of https://github.com/ahmedibrahim085/okf-skills (okf-skills 0.10.4: upstream 0.10.3 + five fixes)
- **License:** MIT (Marco Boffo, 2026) — `LICENSE.okf-skills`
- **Modified:** YES. Upstream `main` 0.10.3 plus five fixes (#62-#66), open as scaccogatto/okf-skills PR #68. When #68 merges: re-vendor from upstream at the merge commit and set **Modified** back to "no". If #68 is closed unmerged, this file stays our patched copy and the diff against upstream is `git diff upstream/main...fix/validate-62-66 -- skills/validate/scripts/okf_validate.py`.
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
