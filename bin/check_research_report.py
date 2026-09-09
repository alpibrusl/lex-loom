#!/usr/bin/env python3
"""Check an opportunity report against the run-1 checkable criteria.

The report is a markdown file in the gate's scratch dir (report.md, or the
only *.md there). Every criterion below is one the freeze document
(docs/consortium-freeze.md §5) calls checkable; each is checked mechanically
and named by the attr lex-economy's evidence items will carry. The human's
criterion ("would you fund it?") is deliberately NOT here: the machine never
answers it.

Always prints `RESEARCH_REPORT_VERIFIED <attrs met>`; on success also
`RESEARCH_REPORT_OK <attrs>` and exit 0, otherwise exit 1 naming every unmet
criterion.
"""
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse

CRITERIA = [
    ("checkable:problem-statement", "## Problem", None),
    ("checkable:target-user", "## Target user", None),
    ("checkable:three-alternatives", "## Alternatives", "table3"),
    ("checkable:implementation-estimate", "## Implementation estimate", "hours"),
    ("checkable:dependencies", "## Dependencies", "bullet"),
    ("checkable:two-sources", "## Sources", "urls2"),
    ("checkable:sources-grounded", "## Sources", "grounded"),
    ("checkable:confidence", "## Confidence", "percent"),
    ("checkable:recommendation", "## Recommendation", None),
]


def ledger_path() -> str:
    return os.environ.get("LOOM_SEARCH_LEDGER") or "/tmp/loom-search-ledger-%s.txt" % (os.environ.get("COMPANY_ID") or "default")


def norm(url: str) -> str:
    p = urlparse(url.strip().rstrip(".,;)"))
    return urlunparse((p.scheme.lower(), p.netloc.lower(), p.path.rstrip("/"), "", p.query, ""))


def grounded(body: str) -> str:
    """Every cited URL must be one web_search actually returned in this run.
    The first live probe (2026-09-09) cited 21 sources of which 13 never
    appeared in any result: real-looking products recalled from memory. The
    tool records each URL it returns in the ledger; a citation outside it is
    refused by name."""
    cited = set(re.findall(r"https?://[^\s)>\]]+", body))
    path = Path(ledger_path())
    if not path.exists():
        return "no search ledger at %s: web_search was never called in this run, so no source can be grounded" % path
    seen = {norm(l) for l in path.read_text().splitlines() if l.strip()}
    bad = sorted(u for u in cited if norm(u) not in seen)
    if bad:
        return "cited but never returned by web_search (copy URLs verbatim from the results): " + ", ".join(bad)
    return ""


def section(text: str, heading: str) -> str:
    m = re.search(r"^%s[^\n]*\n(.*?)(?=^## |\Z)" % re.escape(heading), text, re.M | re.S | re.I)
    return m.group(1).strip() if m else ""


def check(kind, body: str) -> str:
    if not body:
        return "section missing or empty"
    if kind == "table3":
        rows = [l for l in body.splitlines() if l.strip().startswith("|") and not re.match(r"^\|\s*-", l.strip())]
        data = rows[1:] if rows else []  # first row is the header
        return "" if len(data) >= 3 else f"needs a markdown table with at least 3 alternatives (found {len(data)})"
    if kind == "hours":
        return "" if re.search(r"\b\d+(\.\d+)?\s*(hours?|h)\b", body, re.I) else "needs an estimate in hours (e.g. '40 hours')"
    if kind == "bullet":
        return "" if re.search(r"^\s*[-*]\s+\S", body, re.M) else "needs at least one bulleted dependency"
    if kind == "urls2":
        urls = set(re.findall(r"https?://[^\s)>\]]+", body))
        return "" if len(urls) >= 2 else f"needs at least 2 distinct http(s) sources (found {len(urls)})"
    if kind == "grounded":
        return grounded(body)
    if kind == "percent":
        m = re.search(r"\b(\d{1,3})\s*%?", body)
        return "" if m and 0 <= int(m.group(1)) <= 100 else "needs a confidence figure between 0 and 100"
    return ""


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    cands = [p for p in root.rglob("*.md") if "__pycache__" not in p.parts]
    report = root / "report.md"
    if not report.exists():
        if len(cands) == 1:
            report = cands[0]
        else:
            print("check_research_report: no report.md on disk (write the report as a fenced block labelled report.md)")
            return 1
    text = report.read_text()
    unmet, met = [], []
    for attr, heading, kind in CRITERIA:
        why = check(kind, section(text, heading))
        if why:
            unmet.append((attr, heading, why))
        else:
            met.append(attr)
    # The verified line is printed on BOTH paths: a buyer building evidence
    # from this output needs to know which criteria a refused report still
    # met (one unmet criterion is a 50% settlement, not a rejection).
    print("RESEARCH_REPORT_VERIFIED " + " ".join(met))
    if unmet:
        print("check_research_report: the report does not meet these checkable criteria:\n")
        for attr, heading, why in unmet:
            print(f"  {attr}  ({heading}): {why}")
        print("\nEach section above is required, with the content named. The human's question is not yours to answer.")
        return 1
    print("RESEARCH_REPORT_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
