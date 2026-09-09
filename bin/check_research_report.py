#!/usr/bin/env python3
"""Check an opportunity report against the run-1 checkable criteria.

The report is a markdown file in the gate's scratch dir (report.md, or the
only *.md there). Every criterion below is one the freeze document
(docs/consortium-freeze.md §5) calls checkable; each is checked mechanically
and named by the attr lex-economy's evidence items will carry. The human's
criterion ("would you fund it?") is deliberately NOT here: the machine never
answers it.

Exit 0 and print the verified attrs on success; exit 1 naming every unmet
criterion otherwise.
"""
import re
import sys
from pathlib import Path

CRITERIA = [
    ("checkable:problem-statement", "## Problem", None),
    ("checkable:target-user", "## Target user", None),
    ("checkable:three-alternatives", "## Alternatives", "table3"),
    ("checkable:implementation-estimate", "## Implementation estimate", "hours"),
    ("checkable:dependencies", "## Dependencies", "bullet"),
    ("checkable:two-sources", "## Sources", "urls2"),
    ("checkable:confidence", "## Confidence", "percent"),
    ("checkable:recommendation", "## Recommendation", None),
]


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
    unmet = []
    for attr, heading, kind in CRITERIA:
        why = check(kind, section(text, heading))
        if why:
            unmet.append((attr, heading, why))
    if unmet:
        print("check_research_report: the report does not meet these checkable criteria:\n")
        for attr, heading, why in unmet:
            print(f"  {attr}  ({heading}): {why}")
        print("\nEach section above is required, with the content named. The human's question is not yours to answer.")
        return 1
    print("RESEARCH_REPORT_OK " + " ".join(a for a, _, _ in CRITERIA))
    return 0


if __name__ == "__main__":
    sys.exit(main())
