#!/usr/bin/env python3
"""Check that every success metric the PM defined is actually instrumented.

The analytics role exists because a metric written in a PRD and never measured
is a metric that cannot decide anything. A company that ships without this can
answer "did it build" but never "did it work", which is the question the next
iteration turns on.

So this gate is grounded, not a judge: it reads the metrics the PRD states, and
fails unless each one names an event that the workspace REALLY emits -- the
event name has to appear in a source file, not only in the measurement plan.
A plan that cites an event nobody fires is exactly the failure mode here, and
it reads identically to a real one until someone looks.

Looks for, under the gate's scratch dir:
  - the PRD:  prd.md, or any *.md with a "## Success metrics" section
  - the plan: metrics.md / measurement-plan.md, or the same PRD

Always prints `METRICS_VERIFIED <attrs met>`; on success also `METRICS_OK` and
exit 0, otherwise exit 1 naming every metric that is not instrumented.
"""
import re
import sys
from pathlib import Path

SOURCE_SUFFIXES = {".py", ".ts", ".js", ".tsx", ".jsx", ".lex", ".go", ".rb", ".java", ".rs", ".sql"}
METRIC_HEADINGS = ("## Success metrics", "## Success Metrics", "## Metrics")
PLAN_HEADINGS = ("## Measurement plan", "## Measurement Plan", "## Instrumentation")
# An event NAMED in prose: quoted or backticked.
EVENT = re.compile(r"[`\"']([a-z][a-z0-9_.]{2,63})[`\"']")
# An event EMITTED in code: the same name, but in the first argument of a call
# that plausibly records it. Matching bare quoted strings instead would let any
# dict key or literal anywhere in the source satisfy a metric -- a metric citing
# `"users"` would pass against an unrelated {"users": ...}, which is precisely
# the false pass this gate exists to prevent.
EMIT = re.compile(
    r"\b(?:track|emit|capture|record|log_event|logEvent|trackEvent|"
    r"(?:analytics|posthog|mixpanel|amplitude|segment|telemetry)\s*\.\s*\w+)"
    r"\s*\(\s*[`\"']([a-z][a-z0-9_.]{2,63})[`\"']"
)


def section(text: str, headings) -> str:
    for h in headings:
        i = text.find(h)
        if i == -1:
            continue
        rest = text[i + len(h):]
        nxt = re.search(r"^## ", rest, re.M)
        return rest[: nxt.start()] if nxt else rest
    return ""


def bullets(block: str):
    return [b.strip("-* \t") for b in block.splitlines() if b.strip().startswith(("-", "*"))if b.strip("-* \t")]


def emitted_events(root: Path) -> set:
    """Event names a source file really EMITS -- named in a recording call."""
    found = set()
    for p in root.rglob("*"):
        if not p.is_file() or p.suffix not in SOURCE_SUFFIXES:
            continue
        if any(part in {".git", "node_modules", "__pycache__", ".venv"} for part in p.parts):
            continue
        try:
            found.update(m.group(1) for m in EMIT.finditer(p.read_text(errors="ignore")))
        except Exception:
            continue
    return found


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    docs = sorted(root.rglob("*.md"))
    if not docs:
        print("check_metrics_instrumented: no markdown found; expected the PRD and a measurement plan")
        return 1

    metrics_block = plan_block = ""
    for d in docs:
        try:
            t = d.read_text(errors="ignore")
        except Exception:
            continue
        metrics_block = metrics_block or section(t, METRIC_HEADINGS)
        plan_block = plan_block or section(t, PLAN_HEADINGS)

    metrics = bullets(metrics_block)
    if not metrics:
        print("check_metrics_instrumented: no '## Success metrics' section with bullets found in any .md")
        print("  The PM defines the metrics; this role instruments them. Without them there is nothing to check.")
        return 1

    emitted = emitted_events(root)
    plan_events = {m.group(1) for m in EVENT.finditer(plan_block)}

    met, unmet = [], []
    for i, metric in enumerate(metrics, 1):
        attr = f"checkable:metric-{i}-instrumented"
        cited = {e for e in EVENT.finditer(metric)}
        names = {m.group(1) for m in cited} or plan_events
        live = names & emitted
        if live:
            met.append(attr)
        else:
            unmet.append((attr, metric[:90], sorted(names)[:4]))

    print("METRICS_VERIFIED " + " ".join(met))
    if unmet:
        print("check_metrics_instrumented: these metrics are not traceable to an event the code emits:\n")
        for attr, metric, names in unmet:
            cited = ", ".join(names) if names else "(no event named)"
            print(f"  {attr}: {metric}\n      cites: {cited}")
        print(f"\n  events actually emitted by the workspace: {', '.join(sorted(emitted)) or '(none)'}")
        print("\nName the event in the metric or the measurement plan, AND emit it from the product.")
        return 1
    print("METRICS_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
