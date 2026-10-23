"""okf-check --duplicates: candidate duplicate pairs in an OKF bundle. Advisory: the caller always exits 0.

Usage: okf-duplicates.py <bundle> <schema json> <json 0|1> [body 0|1]

A pair is a candidate when the two notes have the same normalized title, or descriptions whose word sets overlap
(Jaccard) at or above okf_check.duplicates.threshold, or cite the same sources[].resource. The strongest signal
is the one shown. A pair already linked by superseded_by (either way) is skipped. With body 1 (--duplicates-body),
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

sys.dont_write_bytecode = True   # a direct run must not leave scripts/__pycache__ in the installed plugin (plugin.test.sh Z-2)
sys.path[:0] = [os.environ["OKF_SCRIPTS_DIR"], os.environ["OKF_VENDOR_DIR"]]
from okf_notes import TooLarge, meta, read_manifest, read_note, refusal, resolve, shown  # noqa: E402
from okf_validate import load_frontmatter  # noqa: E402

bundle, as_json = sys.argv[1], sys.argv[3] == "1"
with_body = len(sys.argv) > 4 and sys.argv[4] == "1"
root = pathlib.Path(bundle)
# Defaults live in the schema (config/okf-check-block.json), next to the rules that bound them; okf-check has already
# run that schema over the block (run_config), so the values here are valid.
schema = json.load(open(sys.argv[2], encoding="utf-8"))["keys"]["duplicates"]["keys"]
try:
    # read_note: a bounded read of a regular file (okf-check has refused a device or pipe named okf-base.yaml up front;
    # this is the second wall, for one that appeared after that check). NoteRefused is an OSError.
    cfg = load_frontmatter(read_manifest(root / "okf-base.yaml", "utf-8", "strict")) or {}
except OSError:
    cfg = {}
opt = ((cfg.get("okf_check") or {}).get("duplicates") or {}) if isinstance(cfg, dict) else {}
threshold = opt.get("threshold", schema["threshold"]["default"])
body_threshold = opt.get("body_threshold", schema["body_threshold"]["default"])
# OKF_DUP_TIME_LIMIT exists for tests (like OKF_TODAY): it makes a cut-short run deterministic. OKF_DUP_CUT_AT (tests
# only) names the pass the limit is reached in (read, pairs, body), so each pass's report can be pinned without a race.
limit = float(os.environ.get("OKF_DUP_TIME_LIMIT") or opt.get("time_limit", schema["time_limit"]["default"]))
deadline = time.monotonic() + limit
CUT_AT = os.environ.get("OKF_DUP_CUT_AT", "")
MIN_BODY_WORDS = 5   # one shingle: a shorter body ("TODO") is the same single shingle in every stub, so every stub scored 1.00


def over(phase):
    return CUT_AT == phase or time.monotonic() > deadline


def norm(s):
    """NFKC, lower case, punctuation to spaces, runs of spaces folded (decided)."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", unicodedata.normalize("NFKC", str(s)).lower())).strip()


# The effective owners okf-check computed (the note's key, else the folder default); absent when the option is off.
owners = {}
if os.environ.get("OKF_OWNERS_TSV") and os.path.isfile(os.environ["OKF_OWNERS_TSV"]):
    owners = dict(l.rstrip("\n").split("\t", 1) for l in open(os.environ["OKF_OWNERS_TSV"], encoding="utf-8", errors="surrogateescape") if "\t" in l)
real = os.path.realpath(bundle)
# .okfignore: okf-check passes the notes it keeps (NUL-separated, relative); an ignored note is never compared.
keep = None
if os.environ.get("OKF_KEEP_LIST"):
    keep = {x for x in open(os.environ["OKF_KEEP_LIST"], encoding="utf-8", errors="surrogateescape").read().split("\0") if x}

# One entry per real path: a symlink alias is the same note as its target, so a third note that duplicates it is
# one pair. The real file wins over an alias whatever the walk order (LT-56r).
by_real = {}
refused = []
for p in sorted(root.rglob("*.md")):
    if p.name in ("index.md", "log.md") or (keep is not None and str(p.relative_to(root)) not in keep):
        continue
    why = refusal(p)   # a device, pipe, folder or oversize file is never opened; stderr, because stdout may be --json
    if why:
        refused.append("%s — %s: skipped" % (p.relative_to(root), why))
        continue
    r = os.path.realpath(str(p))
    if r not in by_real or (by_real[r].is_symlink() and not p.is_symlink()):
        by_real[r] = p

for line in refused:
    print("okf-duplicates: " + shown(line), file=sys.stderr)

notes, cut_in, short_bodies, unread = [], None, 0, []
to_read = sorted(by_real.values())
for p in to_read:
    if over("read"):
        cut_in = "read"   # the limit covers reading too: a bundle of huge notes stops here, and says so
        break
    m = meta(p, too_large=True)
    if isinstance(m, TooLarge):   # not compared, and the report says so: it is not "no duplicates" for that note
        unread.append({"rel": str(p.relative_to(root)), "why": "the note was too large to read: " + m.why})
        continue
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
            t = read_note(p, "utf-8-sig", "replace")   # a BOM note, as L1 reads it (0.9.8 review G-1)
        except OSError:
            t = ""   # a dangling symlink, an unreadable file or a folder named x.md: no body, not a crash (advisory report)
        e = t.find("\n---", 3) if t.startswith("---") else -1
        w = norm(t[e + 4:] if e >= 0 else t).split()
        if 0 < len(w) < MIN_BODY_WORDS:
            short_bodies += 1   # not compared on body; still compared on title, description and sources
        shingles = {" ".join(w[i:i + 5]) for i in range(len(w) - 4)} if len(w) >= MIN_BODY_WORDS else set()
    notes.append({"rel": rel, "real": os.path.realpath(str(p)), "succ": succ, "res": res, "sh": shingles,
                  "title": norm(m.get("title") or ""), "words": set(norm(m.get("description") or "").split()),
                  "status": str(m.get("status") or "-"), "at": str(gen.get("at") or "-"),
                  "owner": owners.get(rel) or str(m.get("owner") or "-")})

# Of all the notes, not only those read before a cut (review 0.9.35), so an incomplete run reads "0 of N pairs".
pairs, compared, total, cut = [], 0, len(to_read) * (len(to_read) - 1) // 2, cut_in is not None
for a, b in itertools.combinations(notes, 2):
    if cut or (compared % 1000 == 0 and over("pairs")):
        cut, cut_in = True, cut_in or "pairs"   # S7-E1: stop, and say how far the comparison got
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
    buckets, signed, checked = {}, 0, 0
    for idx, n in enumerate(notes):
        if over("body"):
            cut, cut_in = True, "body"
            break
        signed = idx + 1
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
            checked += 1
            if checked % 1000 == 0 and time.monotonic() > deadline:
                cut, cut_in = True, "body"   # inside the bucket: 1,500 notes in one bucket ran 2 s past the limit
                break
            if (i, j) in seen:
                continue
            seen.add((i, j))
            a, b = notes[i], notes[j]
            if (a["rel"], b["rel"]) in listed or a["real"] == b["real"] or b["real"] in a["succ"] or a["real"] in b["succ"]:
                continue
            jb = len(a["sh"] & b["sh"]) / len(a["sh"] | b["sh"])
            if jb >= body_threshold:
                pairs.append({"signal": "body", "score": round(jb, 2), "a": a, "b": b})
        if not cut and time.monotonic() > deadline:
            cut, cut_in = True, "body"

if as_json:
    side = lambda n: {"rel": shown(n["rel"]), **{k: n[k] for k in ("status", "at", "owner")}}
    print(json.dumps({"bundle": bundle, "exit": 0, "complete": not cut and not unread, "cut_in": cut_in, "notes_read": len(notes),
                      "notes_total": len(to_read), "body_short": short_bodies, "compared": compared, "pairs_total": total,
                      "duplicates": [{"signal": x["signal"], "score": x["score"], "a": side(x["a"]), "b": side(x["b"])}
                                     for x in pairs],
                      **({"unread": [{"rel": shown(u["rel"]), "why": u["why"]} for u in unread]} if unread else {})}))
    sys.exit(0)
if cut_in == "read":
    print("  Duplicates       CUT SHORT after %g s (okf_check.duplicates.time_limit) while reading notes: %d of %d notes read,"
          " no pair compared" % (limit, len(notes), len(to_read)))
elif cut_in == "body":
    how = ("bodies of %d of %d notes hashed" % (signed, len(notes)) if signed < len(notes)
           else "%d body candidate pair(s) checked before the stop" % checked)
    print("  Duplicates       CUT SHORT after %g s (okf_check.duplicates.time_limit) in the body comparison: all %d pairs"
          " compared on title, description and sources, %s; the list below is partial" % (limit, total, how))
elif cut:
    print("  Duplicates       CUT SHORT after %g s (okf_check.duplicates.time_limit): %d of %d pairs compared;"
          " the list below is partial" % (limit, compared, total))
if short_bodies:
    print("  Duplicates       %d note(s) with a body under %d words not compared on body (title, description and"
          " sources still compared)" % (short_bodies, MIN_BODY_WORDS))
if unread:
    print("  Duplicates       %d note(s) too large to read, not compared:" % len(unread))
    for u in unread[:5]:
        print("                   %s: %s" % (shown(u["rel"]), u["why"]))
    if len(unread) > 5:
        print("                   ... and %d more (--json lists every one)" % (len(unread) - 5))
if not pairs:
    print("  Duplicates       no candidate duplicates" + (" among the pairs compared" if cut else " among the notes read" if unread else ""))
else:
    print("  Duplicates       %d candidate pair(s) (advisory: deprecate one of each, or keep both)" % len(pairs))
    side = lambda n: "%s [%s, %s, owner %s]" % (shown(n["rel"]), n["status"], n["at"], n["owner"])
    for x in pairs:
        print("                   %s %.2f  %s  ~  %s" % (x["signal"], x["score"], side(x["a"]), side(x["b"])))
