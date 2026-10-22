# How the layers work

Contents: what each layer answers · what L3 staleness reads · when one note crashes a checker · reading the L2 summary · is my okflint the patched build

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
- `OKF_L1_TIMEOUT=<seconds>` (default 120) bounds L1's validator, whose cost grows with frontmatter size: exit 2, "timed out". `OKF_LAYER_TIMEOUT=<seconds>` (default 300) is one budget for the Python layers (Trust, Successor, Owner, Size, derived L3, `--duplicates`, the scoped `--file` check): past it a layer is `COULD NOT RUN` naming the limit (exit 2; `--json` lists it in `layers_not_run`). Set it to 4 x the parse time of your largest notes (16 to 35 s per layer for a 4.5 MB note). The edit hook has its own, smaller `OKF_EDIT_HOOK_TIMEOUT` box, which fires first and stays silent. `OKF_L2_TIMEOUT=<seconds>` (default 120) cuts off a hung okflint in L2: exit 2, "timed out". `OKF_INSTALL_TIMEOUT` (200) bounds `--install-deps`. `OKF_AUTO_INSTALL=1` lets the session-start check install; it is off by default. `OKF_SEARCH_BIN` names the `okf` search binary; `OKF_DOC_DIRS_FILE` the extra doc-reuse locations file.
- `OKF_TODAY=YYYY-MM-DD` pins "now" (tests and replays). Any other value exits 2, and a
  valid pin prints a NOTE line so a pinned run cannot pass for a real one.
- A scan that cannot run (crashed awk, missing `l3-lib.sh`, unreadable file) exits 2
  `COULD NOT RUN`. It is never "nothing expired".

**When one note crashes a checker.**
- **The validator (L1):** the vendored copy is our patched build (PR okf-skills#68), so a `status`
  list or an impossible date no longer blank L1. A note whose YAML aliases would expand beyond a fixed limit (an
  "alias bomb") is an L1 error on that note, never a hang; our local patch does that (see `plugin/vendor/VENDOR.md`), and
  `okflint` is not run on such a bundle. If it still crashes on a note, `okf-check` names
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
