#!/usr/bin/env python3
"""Flag expected values that were pasted rather than derived.

A test is an oracle. When its expected values are hand-written constants, a
wrong one is indistinguishable from a real bug: the run that prompted this
asserted a Unix epoch an hour off against a CORRECT implementation, every gate
did its job and refused to seal, and three iterations went into changing
working code to satisfy it.

Asking a model to "derive expected values" is a request. This makes it
checkable: a value that was computed leaves a computation in the source, and a
value that was pasted leaves a literal.

Deliberately narrow. It flags only literals that plausibly encode a DERIVED
quantity -- Unix epochs and full timestamps -- and never small integers,
status codes, short strings or booleans, which are legitimately written out.
A check that cried wolf on `== 400` would be turned off within a day.

Usage: check_derived_values.py <dir>   (exit 1 if any pasted value is found)
"""
import re
import sys
from pathlib import Path

# A 9-11 digit integer is almost certainly a Unix epoch. Below that it is a
# count, an id, a port, a size -- things a test may legitimately state.
EPOCH = re.compile(r"(?<![\d.])\d{9,11}(?![\d.])")
# A full date-time down to the second: the shape of a converted timestamp.
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}")
RFC2822 = re.compile(r"[A-Z][a-z]{2}, \d{1,2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2}")
ASSERTISH = re.compile(r"\bassert\b|assertEqual|==|Err\(|expected")

def looks_computed(line: str) -> bool:
    """A line that calls into a date/time library is deriving, not pasting."""
    return any(t in line for t in (
        "datetime", "timestamp()", "zoneinfo", "ZoneInfo", "timedelta",
        "fromisoformat", "strftime", "format_datetime", "time.", "calendar.",
    ))

def expected_side(line: str) -> str:
    """Only the EXPECTED value can be pasted; the input side is data the test
    legitimately states. `assert convert("2024-01-15T12:00:00", ...) == x` has a
    timestamp on the left as an INPUT -- flagging it is the kind of false alarm
    that gets a check switched off. Look only to the right of the comparison."""
    if "==" not in line:
        return ""
    return line.split("==", 1)[1]

LITERALS = ((EPOCH, "a Unix epoch"), (TIMESTAMP, "a timestamp"), (RFC2822, "an RFC 2822 date"))

def pinned_literals(lines) -> set:
    """Literals that the file itself checks against a derivation.

    Banning literals outright is too blunt, and a real run proved it: a test
    author pasted "2025-07-11T08:00:00-04:00", the gate refused it four times,
    and the pasted value was RIGHT -- it caught a genuine four-hour bug in the
    implementation. The property actually worth demanding is not "computed" but
    "checkable". A literal pinned to a derivation on the same line

        assert "2025-07-11T08:00:00-04:00" == datetime(
            2025, 7, 11, 12, tzinfo=ZoneInfo("UTC")
        ).astimezone(ZoneInfo("America/New_York")).isoformat()

    is checkable: if the paste is wrong, THAT assertion fails and names the
    oracle, instead of the implementation being blamed for the author's typo --
    which is the failure this check exists to prevent. Once pinned, the literal
    may be used freely for the rest of the file.
    """
    pins = set()
    for line in lines:
        if not looks_computed(line):
            continue
        for pat, _ in LITERALS:
            pins.update(pat.findall(line))
    return pins

def scan(path: Path):
    out = []
    lines = path.read_text(errors="replace").splitlines()
    pins = pinned_literals(lines)
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("#") or not ASSERTISH.search(s):
            continue
        rhs = expected_side(s)
        if not rhs or looks_computed(rhs):
            continue
        for pat, what in LITERALS:
            m = pat.search(rhs)
            if m:
                if m.group(0) not in pins:
                    out.append((i, what, m.group(0), s[:100]))
                break
    return out

def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = [p for p in root.rglob("*") if p.is_file()
             and p.suffix in (".py", ".lex")
             and ("test" in p.name.lower() or p.name.lower().endswith("_test.lex"))]
    if not files:
        print("check_derived_values: no test files found — nothing to check")
        return 0
    bad = [(p, hits) for p in files for hits in [scan(p)] if hits]
    if not bad:
        print(f"check_derived_values: {len(files)} test file(s), expected values are derived")
        return 0
    print("check_derived_values: expected values were PASTED, not derived.\n")
    for p, hits in bad:
        for ln, what, lit, src in hits:
            print(f"  {p.name}:{ln}  {what} written as a literal: {lit}")
            print(f"      {src}")
    print("\nA hand-written expected value is an unverifiable oracle: if it is wrong,")
    print("the failure is indistinguishable from a bug in the implementation, and the")
    print("loop will change working code to satisfy it. Two ways to fix this —")
    print("either is accepted:")
    print("")
    print("  1. COMPUTE the expected value where you assert it:")
    print("       assert body[\"result\"] == datetime(")
    print("           2025, 7, 11, 12, tzinfo=ZoneInfo(\"UTC\")")
    print("       ).astimezone(ZoneInfo(\"America/New_York\")).isoformat()")
    print("")
    print("  2. PIN the literal to a derivation ONCE, then reuse it freely:")
    print("       assert \"2025-07-11T08:00:00-04:00\" == datetime(")
    print("           2025, 7, 11, 12, tzinfo=ZoneInfo(\"UTC\")")
    print("       ).astimezone(ZoneInfo(\"America/New_York\")).isoformat()")
    print("")
    print("Both make a wrong paste fail at the ORACLE, naming your expected value,")
    print("instead of the implementation being blamed for your typo.")
    return 1

if __name__ == "__main__":
    sys.exit(main())
