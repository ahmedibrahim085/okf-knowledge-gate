"""okf-check --duplicates (#69): candidate duplicate pairs in an OKF bundle. Advisory: the caller always exits 0.

Usage: okf-duplicates.py <bundle> <schema json> <json 0|1> [body 0|1]

A pair is a candidate when the two notes have the same normalized title, or descriptions whose word sets overlap
(Jaccard) at or above okf_check.duplicates.threshold, or cite the same sources[].resource. The strongest signal
is the one shown. A pair already linked by superseded_by (either way) is skipped. With body 1 (--duplicates-body, #70),
pairs whose bodies share 5-word shingles (Jaccard) at or above okf_check.duplicates.body_threshold are added: MinHash
signatures with LSH banding pick the candidates, and the exact Jaccard of the shingle sets decides. Each pair is shown with the signal and its
score, both statuses, both generated.at values and both owners.
"""
import hashlib
import itertools
import json
import os
import pathlib
import random
import re
import sys
import time
import unicodedata

sys.path[:0] = [os.environ["OKF_SCRIPTS_DIR"], os.environ["OKF_VENDOR_DIR"]]
from okf_notes import meta, resolve  # noqa: E402
from okf_validate import load_frontmatter  # noqa: E402

bundle, as_json = sys.argv[1], sys.argv[3] == "1"
with_body = len(sys.argv) > 4 and sys.argv[4] == "1"
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
body_threshold = opt.get("body_threshold", schema["body_threshold"]["default"])
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
    shingles = set()
    if with_body:
        try:
            t = open(p, encoding="utf-8-sig", errors="replace").read()   # a BOM note, as L1 reads it (0.9.8 review G-1)
        except OSError:
            t = ""   # a dangling symlink, an unreadable file or a folder named x.md: no body, not a crash (advisory report)
        e = t.find("\n---", 3) if t.startswith("---") else -1
        w = norm(t[e + 4:] if e >= 0 else t).split()
        shingles = {" ".join(w[i:i + 5]) for i in range(max(1, len(w) - 4))} if w else set()
    notes.append({"rel": rel, "real": os.path.realpath(str(p)), "succ": succ, "res": res, "sh": shingles,
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

# --duplicates-body: MinHash (64 permutations of one 64-bit hash) in 32 bands of 2 rows. A pair shares a band bucket
# with probability 1-(1-J^2)^32 (Mining of Massive Datasets, 3.4): 0.95 at J=0.3, 1.00 at 0.5 and above (the default
# body_threshold is 0.6), 0.08 at 0.05. 8 bands of 4 rows gave only 0.06 at J=0.3. The candidates are then checked exactly, so a false
# candidate costs time, never a wrong pair.
# SHORTCUT: a pair with body overlap close to body_threshold can be missed by the banding; exact all-pairs Jaccard
# would not miss it but is quadratic in the shingle sets. Raise the bands if that recall matters.
if with_body and not cut:
    P61, rnd = (1 << 61) - 1, random.Random(70)
    perms = [(rnd.randrange(1, P61), rnd.randrange(0, P61)) for _ in range(64)]
    listed = {(x["a"]["rel"], x["b"]["rel"]) for x in pairs}
    buckets = {}
    for idx, n in enumerate(notes):
        if time.monotonic() > deadline:
            cut = True
            break
        if not n["sh"]:
            continue
        hs = [int.from_bytes(hashlib.blake2b(x.encode(), digest_size=8).digest(), "big") for x in n["sh"]]
        sig = [min((a * h + b) % P61 for h in hs) for a, b in perms]
        for band in range(32):
            buckets.setdefault((band, tuple(sig[band * 2:band * 2 + 2])), []).append(idx)
    seen = set()
    for members in buckets.values():
        if cut:
            break
        for i, j in itertools.combinations(members, 2):
            if (i, j) in seen:
                continue
            seen.add((i, j))
            a, b = notes[i], notes[j]
            if (a["rel"], b["rel"]) in listed or a["real"] == b["real"] or b["real"] in a["succ"] or a["real"] in b["succ"]:
                continue
            jb = len(a["sh"] & b["sh"]) / len(a["sh"] | b["sh"])
            if jb >= body_threshold:
                pairs.append({"signal": "body", "score": round(jb, 2), "a": a, "b": b})
        if time.monotonic() > deadline:
            cut = True

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
