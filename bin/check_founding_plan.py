#!/usr/bin/env python3
"""Check a founding plan (plan.md) before the founder is asked to approve it.

The plan is the first deliverable of a company whose manifest says
[policy] founding = true: the idea, a monthly budget in euros, the
resources it wants, the actions only the founder can take, a success metric
and a timeline. Each criterion is checked by name, the budget's Total row is
RECOMPUTED from the item rows (a pasted total is refused), and the verified
attrs are printed so the approval carries them.

Prints `FOUNDING_PLAN_VERIFIED <attrs>` always, `FOUNDING_PLAN_OK <attrs>`
and `FOUNDING_PLAN_TOTAL_EUR=<n>` on a full pass (exit 0); exit 1 naming
each unmet criterion otherwise.
"""
import re
import sys
from pathlib import Path

SECTIONS = [
    ("checkable:idea", "## Idea", "text"),
    ("checkable:budget", "## Budget", "budget"),
    ("checkable:resources", "## Resources", "bullets"),
    ("checkable:human-actions", "## Human actions", "bullets"),
    ("checkable:success-metric", "## Success metric", "text"),
    ("checkable:timeline", "## Timeline", "text"),
]


def section(text: str, heading: str) -> str:
    m = re.search(r"^%s[^\n]*\n(.*?)(?=^## |\Z)" % re.escape(heading), text, re.M | re.S | re.I)
    return m.group(1).strip() if m else ""


def euros(cell: str):
    m = re.search(r"-?\d[\d.,]*", cell.replace("€", ""))
    if not m:
        return None
    raw = m.group(0).replace(",", "")
    try:
        return float(raw)
    except ValueError:
        return None


def budget(body: str):
    rows = [l.strip() for l in body.splitlines() if l.strip().startswith("|") and not re.match(r"^\|\s*-", l.strip())]
    if len(rows) < 2:
        return "needs a markdown table: | Item | EUR / month | Notes |, at least one item row and a Total row", 0.0
    items, total = [], None
    for r in rows[1:]:
        cells = [c.strip() for c in r.strip("|").split("|")]
        if len(cells) < 2:
            continue
        v = euros(cells[1])
        if cells[0].lower().startswith("total"):
            total = v
        elif v is not None:
            items.append(v)
    if not items:
        return "no item row with a numeric EUR amount", 0.0
    if total is None:
        return "no Total row", 0.0
    s = sum(items)
    if abs(s - total) > 0.5:
        return f"Total row says {total:g} but the item rows sum to {s:g}: recompute, do not paste", 0.0
    return "", total


def check(kind, body):
    if not body:
        return "section missing or empty", 0.0
    if kind == "bullets":
        return ("" if re.search(r"^\s*[-*]\s+\S", body, re.M) else "needs at least one bullet"), 0.0
    if kind == "budget":
        return budget(body)
    return "", 0.0


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    plan = root / "plan.md"
    if not plan.exists():
        cands = [p for p in root.rglob("*.md") if "__pycache__" not in p.parts]
        if len(cands) == 1:
            plan = cands[0]
        else:
            print("check_founding_plan: no plan.md on disk (write the plan as a fenced block labelled plan.md)")
            return 1
    text = plan.read_text()
    met, unmet, total = [], [], 0.0
    for attr, heading, kind in SECTIONS:
        why, t = check(kind, section(text, heading))
        if why:
            unmet.append((attr, heading, why))
        else:
            met.append(attr)
            if kind == "budget":
                total = t
    print("FOUNDING_PLAN_VERIFIED " + " ".join(met))
    if unmet:
        print("check_founding_plan: the plan does not meet these checkable criteria:\n")
        for attr, heading, why in unmet:
            print(f"  {attr}  ({heading}): {why}")
        return 1
    print("FOUNDING_PLAN_OK " + " ".join(met))
    print(f"FOUNDING_PLAN_TOTAL_EUR={total:g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
