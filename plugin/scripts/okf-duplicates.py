"""okf-check --duplicates (#69): candidate duplicate pairs in an OKF bundle. Advisory: the caller always exits 0.

Usage: okf-duplicates.py <bundle> <schema json> <json 0|1>

A pair is a candidate when the two notes have the same normalized title, or descriptions whose word sets overlap
(Jaccard) at or above okf_check.duplicates.threshold, or cite the same sources[].resource. The strongest signal
is the one shown. A pair already linked by superseded_by (either way) is skipped. Each pair is shown with the signal and its
score, both statuses, both generated.at values and both owners.
"""
import itertools
import json
import os
import pathlib
import re
import sys
import time
import unicodedata

sys.path[:0] = [os.environ["OKF_SCRIPTS_DIR"], os.environ["OKF_VENDOR_DIR"]]
from okf_notes import meta, resolve  # noqa: E402
from okf_validate import load_frontmatter  # noqa: E402

bundle, as_json = sys.argv[1], sys.argv[3] == "1"
root = pathlib.Path(bundle)
# Defaults live in the schema (config/okf-check-block.json), next to the rules that bound them; okf-check has already
# run that schema over the block (run_config), so the values here are valid.
schema = json.load(open(sys.argv[2], encoding="utf-8"))["keys"]["duplicates"]["keys"]
try:
    cfg = load_frontmatter(open(root / "okf-base.yaml", encoding="utf-8").read()) or {}
except OSError:
    cfg = {}
opt = ((cfg.get("okf_check") or {}).get("duplicates") or {}) if isinstance(cfg, dict) else {}
threshold = opt.get("threshold", schema["threshold"]["default"])
# OKF_DUP_TIME_LIMIT exists for tests (like OKF_TODAY): it makes a cut-short run deterministic.
limit = float(os.environ.get("OKF_DUP_TIME_LIMIT") or opt.get("time_limit", schema["time_limit"]["default"]))
deadline = time.monotonic() + limit


def norm(s):
    """NFKC, lower case, punctuation to spaces, runs of spaces folded (decided on #69)."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", unicodedata.normalize("NFKC", str(s)).lower())).strip()


# The effective owners okf-check computed (#68: the note's key, else the folder default); absent when the option is off.
owners = {}
if os.environ.get("OKF_OWNERS_TSV") and os.path.isfile(os.environ["OKF_OWNERS_TSV"]):
    owners = dict(l.rstrip("\n").split("\t", 1) for l in open(os.environ["OKF_OWNERS_TSV"], encoding="utf-8") if "\t" in l)
real = os.path.realpath(bundle)
# .okfignore: okf-check passes the notes it keeps (NUL-separated, relative); an ignored note is never compared.
keep = None
if os.environ.get("OKF_KEEP_LIST"):
    keep = {x for x in open(os.environ["OKF_KEEP_LIST"], encoding="utf-8", errors="replace").read().split("\0") if x}

notes = []
for p in sorted(root.rglob("*.md")):
    if p.name in ("index.md", "log.md") or (keep is not None and str(p.relative_to(root)) not in keep):
        continue
    m = meta(p)
    gen = m.get("generated") if isinstance(m.get("generated"), dict) else {}
    sb = m.get("superseded_by") or []
    succ = {resolve(r, p, real) for r in (sb if isinstance(sb, list) else [sb])} - {None}
    srcs = m.get("sources")   # L1 only warns on a non-list `sources`, so a note with one still reaches this report
    res = {os.path.normpath(str(s.get("resource")).strip()) for s in (srcs if isinstance(srcs, list) else [])
           if isinstance(s, dict) and str(s.get("resource") or "").strip()}
    rel = str(p.relative_to(root))
    notes.append({"rel": rel, "real": os.path.realpath(str(p)), "succ": succ, "res": res,
                  "title": norm(m.get("title") or ""), "words": set(norm(m.get("description") or "").split()),
                  "status": str(m.get("status") or "-"), "at": str(gen.get("at") or "-"),
                  "owner": owners.get(rel) or str(m.get("owner") or "-")})

pairs, compared, total, cut = [], 0, len(notes) * (len(notes) - 1) // 2, False
for a, b in itertools.combinations(notes, 2):
    if compared % 1000 == 0 and time.monotonic() > deadline:
        cut = True   # S7-E1: stop, and say how far the comparison got
        break
    compared += 1
    if a["real"] == b["real"]:
        continue   # a symlink alias is the same note, not a duplicate of its target
    if b["real"] in a["succ"] or a["real"] in b["succ"]:
        continue   # already resolved by a deprecation (S7-E2)
    if a["title"] and a["title"] == b["title"]:
        pairs.append({"signal": "title", "score": 1.0, "a": a, "b": b})
        continue
    if a["res"] & b["res"]:
        pairs.append({"signal": "resource", "score": 1.0, "a": a, "b": b})
        continue
    if a["words"] and b["words"]:
        j = len(a["words"] & b["words"]) / len(a["words"] | b["words"])
        if j >= threshold:
            pairs.append({"signal": "description", "score": round(j, 2), "a": a, "b": b})

if as_json:
    side = lambda n: {k: n[k] for k in ("rel", "status", "at", "owner")}
    print(json.dumps({"bundle": bundle, "exit": 0, "complete": not cut, "compared": compared, "pairs_total": total,
                      "duplicates": [{"signal": x["signal"], "score": x["score"], "a": side(x["a"]), "b": side(x["b"])}
                                     for x in pairs]}))
    sys.exit(0)
if cut:
    print("  Duplicates       CUT SHORT after %g s (okf_check.duplicates.time_limit): %d of %d pairs compared;"
          " the list below is partial" % (limit, compared, total))
if not pairs:
    print("  Duplicates       no candidate duplicates" + (" among the pairs compared" if cut else ""))
else:
    print("  Duplicates       %d candidate pair(s) (advisory: deprecate one of each, or keep both)" % len(pairs))
    side = lambda n: "%s [%s, %s, owner %s]" % (n["rel"], n["status"], n["at"], n["owner"])
    for x in pairs:
        print("                   %s %.2f  %s  ~  %s" % (x["signal"], x["score"], side(x["a"]), side(x["b"])))
