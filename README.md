# OKF Knowledge Gate

A Claude Code plugin that answers one question about a folder of markdown knowledge:
**can you still trust it?**

It runs one command over the [Open Knowledge Format (OKF)](https://github.com/GoogleCloudPlatform/open-knowledge-format)
toolchain and gives one verdict from four layers: spec conformance, house rules, staleness,
and whether the claims in the notes are still true.

## Why this exists

Knowledge stores rarely fail because of their format. They fail because
nothing runs without being chosen: notes went stale, claims stopped being true, and no check
noticed. The format (OKF) is the easy part. The gate is the part that keeps a store honest.

Objectives:

1. **One entry point.** Three tools that must be remembered are remembered zero times, so
   `okf-check` runs all of them.
2. **Never a false pass.** A layer that cannot run says so (exit 2). A layer that is skipped
   says why. A crash is named, not hidden.
3. **A gate you can verify.** `--selftest` plants a defect per layer and requires each gate to
   catch it, so a gate that silently stopped firing is the loudest signal, not the quietest.
4. **Run on a brand-new machine.** The validator is vendored; `jq` and `okflint` are optional.

## What it does

| Layer | Question | Backed by |
|---|---|---|
| L0 doctor | Can the gate run here at all? | runtimes, dependencies, version pins, behaviour probes |
| L1 conformance | Is this valid OKF? | the vendored OKF v0.2 validator |
| L2 profile | Is this valid *our* OKF? | `okflint` and the bundle's `okf-base.yaml` |
| L2 index | Does `index.md` describe this bundle? | its bold count declaration against the files on disk |
| L3 staleness | Is it still true? | `stale_after` against today, and `status` |
| L3 derived | Has what it describes moved since? | `sources[].last_modified` against the file's mtime |
| L4 claims (`okf-verify`) | Do the cited commits and paths exist? | CONFIRMED, REFUTED or UNRESOLVED per claim |

Also shipped:

- A SessionStart preflight that reports a missing or unsupported prerequisite (`okf-check --preflight`).
- A SessionStart hook that reports stale lessons (`lessons-staleness-check.sh`).
- A PreToolUse hook that stops a duplicate document being written (`doc-reuse-guard.sh`). With an
  [`okf`](https://github.com/GoogleCloudPlatform/open-knowledge-format) search binary on PATH (or
  `OKF_SEARCH_BIN`) it also names the three closest existing notes. The plugin never installs it.
- A skill, `okf`, so an agent knows how to run the gate and read its result.

## Install

Requires `python3` with `pyyaml` (L1). `okflint` is optional (L2).

```bash
claude plugin marketplace add ahmedibrahim085/okf-knowledge-gate   # or a local path
claude plugin install okf@ahmedmaged-okf
```

Restart Claude Code to load a new version. Update with `claude plugin update okf@ahmedmaged-okf`.

**Prerequisites** are checked at every session start (no network, silent when fine). To see and
install what is missing, at the supported versions from `plugin/config/pinned-versions.txt`:

```bash
okf-check --install-deps           # shows the plan, changes nothing
okf-check --install-deps --yes     # runs it (okflint, via uv)
okf-check --install-deps --yes --latest   # newest okflint instead of the supported one
```

Set `OKF_AUTO_INSTALL=1` if you want the session-start check to run the plan itself. It is off by
default because a plugin should not install software unasked.

## Use

```bash
okf-check <bundle>                 # all layers
okf-check <bundle> --fail-stale    # staleness blocks (exit 4)
okf-check <bundle> --json          # machine-readable summary
okf-check --doctor                 # what is installed, and does okflint behave
okf-check --selftest               # re-prove every gate still fires
okf-check --init-ignore <bundle>   # write a starter .okfignore (never automatic, never overwrites)
okf-verify <bundle> --repo DIR     # L4: are the cited SHAs and paths real
```

Read the exit code, do not just test for zero:

| Exit | Meaning |
|---|---|
| 0 | All gates pass |
| 1 | L1: the bundle is not conformant OKF |
| 2 | A gate could not run. Never treat as a pass |
| 3 | L2: house rules broken, or `index.md` miscounts |
| 4 | L3: stale concepts (with `--fail-stale`) |
| 5 | `--selftest` failed: a gate stopped firing |
| 6 | The bundle changed during the scan (with `--fail-on-change`) |

**Leave paths out:** put globs in `<bundle>/.okfignore` (`archive/`, `.trash/`; a leading `**/` matches at any depth, the root included). Every layer skips
them and the run says how many files it excluded. The plugin never creates the file by itself.

**Environment variables** (all optional):

| Variable | Default | Effect |
|---|---|---|
| `OKF_L2_TIMEOUT` | 120 | Seconds before a hung `okflint` is cut off in L2 (exit 2, named). `0` or a non-number means the default. |
| `OKF_INSTALL_TIMEOUT` | 200 | Seconds before `--install-deps` stops the installer. |
| `OKF_AUTO_INSTALL` | off | `1` lets the session-start check run the install plan itself. |
| `OKF_SEARCH_BIN` | `okf` on PATH | The `okf` search binary the doc-reuse reminder uses to name the closest notes. |
| `OKF_DOC_DIRS_FILE` | `~/.config/okf/doc-dirs` | File of extra shell globs for locations the doc-reuse guard watches. |

`OKF_TODAY`, `OKF_PINNED_VERSIONS` and `OKF_BUNDLE_DIR` exist for tests and replays.

The full behaviour contract, one row per scenario with its test, is
[`docs/spec.md`](docs/spec.md).

## How it is built

The plugin wraps other people's tools and adds the gate engineering around them. It does
not re-implement them.

| Dependency | Role | How we use it |
|---|---|---|
| [okf-skills](https://github.com/scaccogatto/okf-skills) validator | L1 spec check | vendored in `plugin/vendor/`; currently our patched copy, see [`VENDOR.md`](plugin/vendor/VENDOR.md) |
| [okflint](https://github.com/mattdav/okflint) | L2 house rules | optional, installed separately; the doctor probes its behaviour |
| PyYAML | parsing | vendored, pure Python |

What is ours: layer precedence in the exit codes, the selftest, change detection, L4 claim
verification, crash isolation (a note that crashes a checker is named and the rest are still
checked), and the behaviour probes. Upstream bug fixes we depend on are submitted as pull
requests: [okf-skills#68](https://github.com/scaccogatto/okf-skills/pull/68) and
[okflint#11](https://github.com/mattdav/okflint/pull/11).

## Repository layout

| Path | Contents |
|---|---|
| `plugin/` | The installable plugin: scripts, hooks, skill, vendored validator, config |
| `plugin/scripts/` | `okf-check`, `okf-verify`, the hooks, and their test suites (`*.test.sh`) |
| `plugin/vendor/` | The vendored validator and PyYAML, with `VENDOR.md` (source, pin, licence) |
| `.github/` | Issue forms and the pull-request template |
| `CHANGELOG.md` | Dated history of every release |

## Status and roadmap

The dated history is in [`CHANGELOG.md`](CHANGELOG.md). Open work is tracked in this repository's
issues. Two upstream pull requests carry fixes the plugin depends on:
[okf-skills#68](https://github.com/scaccogatto/okf-skills/pull/68) and
[okflint#11](https://github.com/mattdav/okflint/pull/11). When they merge, the vendored validator
is replaced by the upstream release.

## Develop and test

```bash
bash plugin/scripts/okf-check.test.sh     # the gate
bash plugin/scripts/okf-verify.test.sh    # L4
bash plugin/scripts/plugin.test.sh        # packaging and install drift
plugin/scripts/okf-check --selftest
```

Everything is bash 3.2 compatible and runs with BSD or GNU awk. Tests are written first and
must go red before the fix; a change is reviewed on two axes (standards and spec) before it
is released.

## Release

1. Raise the version in `plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
   and `VERSION` in `plugin/scripts/okf-check`. A test fails if they disagree.
2. Add a `## [x.y.z] - YYYY-MM-DD` section to [`CHANGELOG.md`](CHANGELOG.md).
3. Run the three suites and `--selftest`.
4. Tag `vx.y.z` and push the tag.
5. Publish the release notes from the changelog section:
   ```bash
   awk '/^## \[x.y.z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
     | gh release create vx.y.z --title "okf x.y.z" --notes-file -
   ```

## License

MIT, see [`LICENSE`](LICENSE). Third-party code keeps its own MIT licence: the vendored
validator (`plugin/vendor/LICENSE.okf-skills`) and PyYAML (`plugin/vendor/LICENSE.pyyaml`).
