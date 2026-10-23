#!/usr/bin/env bash
# The CommonMark corpus test of okf-export: a [[b]] planted at every offset of every example of the CommonMark 0.31.2
# sections "Code spans", "Autolinks" and "Raw HTML" (plugin/tests/commonmark-0.31.2-inline.json, its source and sha256
# inside), exported in ONE real run of `okf-export <vault> <out>`, one note per case.
#
# The reference is markdown-it-py 3.0.0 in "commonmark" mode (the reader tools/okf-export-oracle.py uses). For each case:
#   - the content of every code_inline, html_inline, autolink, code_block, fence and html_block token of the exported
#     note equals that of the planted note (the export changed no code, URL or raw HTML), and
#   - a planted [[b]] that markdown-it reads as text is rewritten to [b](b.md); any other is left as written.
# Each case is compared as a whole note: the expected text is the planted note, or the planted note with [b](b.md) in
# place of the plant. Without markdown-it-py 3.0.0 the suite says SKIPPED, counts 0 passed and exits 3: never a pass.
set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
EXPORT="$HERE/okf-export"
CORPUS="$HERE/../tests/commonmark-0.31.2-inline.json"
PASS=0; FAIL=0; SKIP=0
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t okfspec)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

if ! python3 -c 'import markdown_it, sys; sys.exit(markdown_it.__version__ != "3.0.0")' 2>/dev/null; then
  SKIP=1
  printf '  SKIP  S10-SPEC SKIPPED: markdown-it-py 3.0.0 is not installed for python3 (pip install markdown-it-py==3.0.0); the corpus was NOT checked\n'
else
  # Build the vault: b.md, and one note per case (example number, offset).
  python3 -I - "$CORPUS" "$TMP/vault" > "$TMP/build.txt" 2>&1 <<'PY'
import hashlib, json, os, sys
corpus, vault = sys.argv[1], sys.argv[2]
doc = json.load(open(corpus, encoding="utf-8"))
os.makedirs(vault)
with open(os.path.join(vault, "b.md"), "w", encoding="utf-8") as f:
    f.write("# B\n")
n = 0
for ex in doc["examples"]:
    md = ex["markdown"]
    for o in range(len(md) + 1):
        with open(os.path.join(vault, "e%03d-%03d.md" % (ex["example"], o)), "w", encoding="utf-8", newline="") as f:
            f.write(md[:o] + "[[b]]" + md[o:])
        n += 1
print("examples=%d cases=%d" % (len(doc["examples"]), n))
PY
  rc=$?
  [ "$rc" = 0 ] && ok "S10-SPEC-0 corpus vault built ($(cat "$TMP/build.txt"))" || bad "S10-SPEC-0 corpus vault" "rc=$rc $(head -5 "$TMP/build.txt")"

  "$EXPORT" "$TMP/vault" "$TMP/out" > "$TMP/export.txt" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "S10-SPEC-1 okf-export of the corpus vault exits 0 with no problem line" \
    || bad "S10-SPEC-1 okf-export of the corpus vault" "rc=$rc $(head -5 "$TMP/export.txt" | tr '\n' ';')"

  # Not -I: markdown-it-py may sit in the user site-packages. Run from $TMP, so no module of the caller's folder loads first.
  ( cd "$TMP" && python3 - "$CORPUS" "$TMP/vault" "$TMP/out" ) > "$TMP/compare.txt" 2>&1 <<'PY'
import json, os, re, sys
from markdown_it import MarkdownIt
import markdown_it.rules_inline.html_inline   # the module: the package name html_inline is the rule function
from markdown_it.common import html_re
corpus, vault, out = sys.argv[1:4]
PLANT, LINK = "[[b]]", "[b](b.md)"
doc = json.load(open(corpus, encoding="utf-8"))

# markdown-it-py 3.0.0 reads inline HTML comments and declarations by CommonMark 0.30: no `--` inside a comment, and a
# declaration is `<!` + upper-case letters + whitespace. 0.31.2 (6.6) takes `<!-->`, `<!--->` and any text up to the first
# `-->`, and `<!` + any ASCII letter up to the first `>`. The reference swaps in those two 0.31.2 rules and is checked
# first: it must render every vendored example exactly as the spec's own html.
rule = sys.modules["markdown_it.rules_inline.html_inline"]
STOCK = rule.HTML_TAG_RE
SPEC = re.compile("^(?:" + "|".join([html_re.open_tag, html_re.close_tag, r"<!-->|<!--->|<!--[\s\S]*?-->",
                                      html_re.processing, r"<![A-Za-z][^>]*>", html_re.cdata]) + ")")
md_it = MarkdownIt("commonmark")

def renders_off(tag_re):
    rule.HTML_TAG_RE = tag_re
    return [ex["example"] for ex in doc["examples"] if md_it.render(ex["markdown"]) != ex["html"]]

stock_off, spec_off = renders_off(STOCK), renders_off(SPEC)
print("REFERENCE %s: markdown-it-py 3.0.0 with the 0.31.2 comment and declaration rules renders %d of %d examples as the spec"
      " html (off: %s); stock 3.0.0 is off on %s" % ("ok" if not spec_off else "BAD", len(doc["examples"]) - len(spec_off),
                                                     len(doc["examples"]), spec_off or "none", stock_off or "none"))

def kept(text):
    """The protected contents of a note, in order: (kind, content)."""
    got = []
    def walk(tokens):
        for t in tokens:
            if t.type in ("code_inline", "html_inline", "code_block", "fence", "html_block"):
                got.append((t.type, t.content))
            elif t.type == "link_open" and t.markup == "autolink":
                got.append(("autolink", t.attrs.get("href")))
            if t.children:
                walk(t.children)
    walk(md_it.parse(text))
    return got

def as_text(text):
    """Whether markdown-it reads the one [[b]] in `text` as text: it is in a text token, in no protected token. The text
    token of an autolink is its URL, not text."""
    seen, auto = [], [0]
    def walk(tokens):
        for t in tokens:
            if t.markup == "autolink":
                auto[0] += 1 if t.type == "link_open" else -1
            elif t.type == "text" and PLANT in t.content and not auto[0]:
                seen.append(t)
            if t.children:
                walk(t.children)
    walk(md_it.parse(text))
    return len(seen) == 1

def compare(show):
    """(cases, rewritten, differences, examples that differ) of the exported corpus against the current reference."""
    cases = diffs = rewritten = 0
    where = set()
    for ex in doc["examples"]:
        src = ex["markdown"]
        for o in range(len(src) + 1):
            planted = src[:o] + PLANT + src[o:]
            try:
                with open(os.path.join(out, "e%03d-%03d.md" % (ex["example"], o)), encoding="utf-8", newline="") as f:
                    got = f.read()
            except OSError as err:
                got = "<missing: %s>" % err.strerror
            text = as_text(planted) and src[o - 1:o] != "!"   # ![[b]] is an embed, which okf-export leaves as written
            want = src[:o] + LINK + src[o:] if text else planted
            rewritten += text
            cases += 1
            why = []
            if kept(got) != kept(planted):
                why.append("protected content changed")
            if got != want:
                why.append("want %r got %r" % (want, got))
            if why:
                diffs += 1
                where.add(ex["example"])
                if show and diffs <= 40:
                    print("DIFF example %d offset %d (%s): %s" % (ex["example"], o, ex["section"], "; ".join(why)))
    return cases, rewritten, diffs, sorted(where)

rule.HTML_TAG_RE = STOCK
_, _, stock_diffs, stock_where = compare(False)
rule.HTML_TAG_RE = SPEC
cases, rewritten, diffs, _ = compare(True)
print("cases=%d rewritten=%d left=%d differences=%d (against stock markdown-it-py 3.0.0: %d, in examples %s)"
      % (cases, rewritten, cases - rewritten, diffs, stock_diffs, stock_where or "none"))
sys.exit(1 if diffs or not cases or spec_off else 0)
PY
  rc=$?
  ref=$(grep '^REFERENCE ' "$TMP/compare.txt")
  grep -q '^REFERENCE ok:' "$TMP/compare.txt" && ok "S10-SPEC-R ${ref#REFERENCE ok: }" \
    || bad "S10-SPEC-R the reference renders the examples as the spec html" "${ref:-no REFERENCE line} $(tail -3 "$TMP/compare.txt" | tr '\n' ';')"
  summary=$(tail -1 "$TMP/compare.txt")
  [ "$rc" = 0 ] && ok "S10-SPEC-2 every planted [[b]] matches the reference: code, autolinks and raw HTML unchanged, text links rewritten ($summary)" \
    || bad "S10-SPEC-2 corpus against markdown-it-py" "rc=$rc $summary | $(head -40 "$TMP/compare.txt" | tr '\n' '~' | cut -c1-6000)"
fi

echo
echo "  $PASS passed, $FAIL failed$([ "$SKIP" -gt 0 ] && printf ', %s SKIPPED' "$SKIP")"
[ "$SKIP" -eq 0 ] || exit 3   # a skipped corpus is no pass, here or in a gate
[ "$FAIL" -eq 0 ] || exit 1
