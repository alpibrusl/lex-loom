#!/usr/bin/env bash
# rr1-research-report-roundtrip.sh -- the opportunity-report gate, checked.
#
# ResearchCo (docs/consortium-freeze.md) sells opportunity-research/v1. Its
# deliverable is a markdown report whose checkable criteria are verified by
# bin/check_research_report.py, one attr per criterion, so lex-economy's
# evidence items can be built from the checker's own output. This demo proves
# the checker accepts a complete report, refuses each missing criterion BY
# NAME, and never answers the human's question. It also proves the search
# backend the role depends on returns URLs offline-parsable from a fixture,
# because a report grounded in "no results found" is what the gate refuses.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-rr1.XXXXXX")"; trap 'rm -rf "$W"' EXIT

good() {
cat <<'MD'
# Opportunity: CSV schema validation API

## Problem
Solo developers accepting CSV uploads re-implement validation on every project. Errors surface as bad rows in production instead of at upload time.

## Target user
Solo developers building SaaS back-offices who accept spreadsheet uploads from customers.

## Alternatives
| Alternative | What it does | Price / gap |
|---|---|---|
| Cloudmersive Validate CSV | validates CSV syntax via API | free tier 800 calls/month; no schema rules |
| Flatfile | full import UI | from $599/month; too heavy for a solo developer |
| csvlint.io | web validator | free; no API, no schema rules |

## Implementation estimate
40 hours: a FastAPI service with a JSON schema-rules dialect, streaming parser and a test suite.

## Dependencies
- FastAPI
- a CSV parser with streaming support

## Sources
- https://cloudmersive.com/convert/validate-csv-api
- https://flatfile.com/pricing

## Confidence
70 -- would rise with three interviews of developers who accept CSV uploads.

## Recommendation
Build it: the gap between a syntax-only free validator and a $599/month import suite is real and reachable in a week.
MD
}

echo "== 1. a complete report passes and names every verified attr"
mkdir -p "$W/good"; good > "$W/good/report.md"
out=$(cd "$W/good" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"RESEARCH_REPORT_OK"* ]] && [[ "$out" == *"checkable:two-sources"* ]] && [[ "$out" == *"checkable:three-alternatives"* ]]; then ok "complete report accepted; attrs printed for the evidence bundle"; else bad "complete report refused or attrs missing: $out"; fi

echo "== 2. each missing criterion is refused by its attr name (sabotage per section)"
for sec in "## Problem:checkable:problem-statement" "## Target user:checkable:target-user" "## Implementation estimate:checkable:implementation-estimate" "## Dependencies:checkable:dependencies" "## Confidence:checkable:confidence" "## Recommendation:checkable:recommendation"; do
  heading="${sec%%:*}"; attr="${sec#*:}"
  mkdir -p "$W/miss"; good | sed "s|^$heading\$|## Removed|" > "$W/miss/report.md"
  out=$(cd "$W/miss" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 0 ] && [[ "$out" == *"$attr"* ]]; then ok "missing '$heading' refused as $attr"; else bad "missing '$heading' was not refused as $attr (rc=$rc): $out"; fi
done

echo "== 3. two alternatives are not three; one source is not two; confidence 140 is not a percentage"
mkdir -p "$W/alt2"; good | command grep -v '^| csvlint' > "$W/alt2/report.md"
out=$(cd "$W/alt2" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:three-alternatives"* ]]; then ok "two table rows refused as checkable:three-alternatives"; else bad "two alternatives accepted"; fi
mkdir -p "$W/src1"; good | command grep -v 'flatfile.com/pricing' > "$W/src1/report.md"
out=$(cd "$W/src1" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:two-sources"* ]]; then ok "one source refused as checkable:two-sources"; else bad "one source accepted"; fi
mkdir -p "$W/conf"; good | sed 's/^70 --/140 --/' > "$W/conf/report.md"
out=$(cd "$W/conf" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:confidence"* ]]; then ok "confidence 140 refused as checkable:confidence"; else bad "confidence 140 accepted"; fi
mkdir -p "$W/hrs"; good | sed 's/^40 hours:/about a week:/' > "$W/hrs/report.md"
out=$(cd "$W/hrs" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:implementation-estimate"* ]]; then ok "an estimate without hours refused"; else bad "'about a week' accepted as an hours estimate"; fi

echo "== 4. no report on disk is a denial that says what to write"
mkdir -p "$W/none"; out=$(cd "$W/none" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"report.md"* ]]; then ok "empty scratch dir refused, naming report.md"; else bad "empty dir not refused"; fi

echo "== 5. the human's criterion is never in the verified attrs"
out=$(cd "$W/good" && python3 "$OLDPWD/bin/check_research_report.py" . 2>&1 || true)
case "$out" in *"human:"*) bad "the checker printed a human: attr -- the machine answered the founder's question" ;; *) ok "no human: attr in the checker's output" ;; esac

echo "== 6. the report reaches the gate through the fence (extract_fenced names report.md)"
mkdir -p "$W/fence"; { printf 'Here is the report.\n\n```report.md\n'; good; printf '```\n'; } > "$W/fence/art.txt"
mkdir -p "$W/fence/w"; python3 bin/extract_fenced.py "$W/fence/art.txt" "$W/fence/w" >/dev/null 2>&1 || true
if [ -f "$W/fence/w/report.md" ] && (cd "$W/fence/w" && python3 "$OLDPWD/bin/check_research_report.py" . >/dev/null 2>&1); then ok "a fenced report.md lands on disk and passes"; else bad "the fenced report did not reach the gate: $(ls "$W/fence/w" 2>/dev/null)"; fi

echo "== 7. the search backend parses result URLs from each engine's html (fixtures, offline)"
python3 - <<'PY' && ok "brave + bing + duckduckgo parsers each return title/snippet/url from fixture html" || bad "a search parser returned nothing from its fixture"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ws", "bin/web_search.py"); ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
brave = '<div class="snippet svelte-x" data-pos="0" data-type="web" data-keynav="true"><div><a href="https://example.com/a" target="_self" class="l1"><div class="title search-snippet-title line-clamp-1 svelte-y">Example <b>A</b></div></a><div class="content desktop-default-regular t-primary line-clamp-2 svelte-z"><!---->Snippet of A</div></div></div>'
bing = '<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=x&amp;u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9i&amp;ntb=1" h="ID">Example B</a></h2><div><p class="b_lineclamp2">Snippet of B</p></div></li>'
ddg = '<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fc&amp;rut=1">Example C</a><a class="result__snippet" href="x">Snippet of C</a>'
ws.fetch = lambda url, data=None: brave if "brave" in url else bing if "bing" in url else ddg
r = {n: f("q") for n, f in (("brave", ws.brave), ("bing", ws.bing), ("duckduckgo", ws.duckduckgo))}
assert r["brave"] == [("Example A", "Snippet of A", "https://example.com/a")], r["brave"]
assert r["bing"] == [("Example B", "Snippet of B", "https://example.com/b")], r["bing"]
assert r["duckduckgo"] == [("Example C", "Snippet of C", "https://example.com/c")], r["duckduckgo"]
PY

echo "== 8. a bot-check page is an error, not an empty answer, so the next backend runs"
python3 - <<'PY' && ok "duckduckgo's anomaly page raises; the chain falls through to a backend with results" || bad "the anomaly page was taken as a real (empty) answer"
import importlib.util, io, contextlib
spec = importlib.util.spec_from_file_location("ws", "bin/web_search.py"); ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
anomaly = "<html>" + "anomaly " * 40 + "</html>"
brave = '<div class="snippet s" data-pos="0" data-type="web"><a href="https://example.com/z"><div class="title t">Z</div></a><div class="content c">S</div></div>'
ws.fetch = lambda url, data=None: anomaly if "duckduckgo" in url else brave
import sys; sys.argv = ["web_search.py", "q"]
buf = io.StringIO()
with contextlib.redirect_stdout(buf): ws.main()
assert "https://example.com/z" in buf.getvalue(), buf.getvalue()
PY

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
