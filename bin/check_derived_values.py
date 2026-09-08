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
        "fromisoformat", "isoformat", "astimezone", "strftime",
        "format_datetime", "formatdate", "utcfromtimestamp", "time.",
        "calendar.",
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
    # A name bound to a derivation, e.g. `expected_iso = datetime(...).isoformat()`.
    # Derivation is TRANSITIVE, because it is written that way:
    #
    #     expected_dt  = datetime(...).astimezone(...)   <- computed
    #     expected_iso = expected_dt.isoformat()         <- computed FROM it
    #
    # Taking only the first pass would leave expected_iso unrecognised, which is
    # precisely the name the pin below compares against.
    derived_names = set()
    for _ in range(4):
        grew = False
        for line in lines:
            m = re.match(r"\s*([A-Za-z_]\w*)\s*=(?!=)", line)
            if not m or m.group(1) in derived_names:
                continue
            rhs = line.split("=", 1)[1]
            from_derived = any(re.search(r"\b%s\b" % re.escape(n), rhs) for n in derived_names)
            if looks_computed(line) or from_derived:
                derived_names.add(m.group(1)); grew = True
        if not grew:
            break

    pins = set()
    for line in lines:
        # The literal and the derivation on ONE line.
        inline = looks_computed(line)
        # Or the literal compared against a name bound to a derivation earlier.
        # This is how the idiom is actually written, and rejecting it was a real
        # false positive: a run produced exactly
        #
        #     expected_iso = datetime(2025, 7, 11, 12, tzinfo=ZoneInfo("UTC")) \
        #         .astimezone(ZoneInfo("America/New_York")).isoformat()
        #     # Pin: verify our derivation
        #     assert expected_iso == "2025-07-11T08:00:00-04:00"
        #
        # -- derived, pinned, commented as a pin -- and this check called it a
        # pasted constant. The gate was rejecting correct tests, including one
        # whose values were right and had caught a genuine four-hour bug in an
        # implementation.
        via_name = "==" in line and any(
            re.search(r"\b%s\b" % re.escape(n), line) for n in derived_names
        )
        if not (inline or via_name):
            continue
        for pat, _ in LITERALS:
            pins.update(pat.findall(line))
    return pins

def scan(path: Path):
    out = []
    lines = path.read_text(errors="replace").splitlines()
    pins = pinned_literals(lines)
    # A literal that appears more than once in the file is an INPUT being
    # echoed, not a hand-written oracle: `json={"timestamp": "2025-07-11T12:00:00"}`
    # posted, then `assert data["timestamp_in"] == "2025-07-11T12:00:00"`. That
    # round-trip is a real test of the API. tzc11 denied one such assertion ten
    # times across three iterations -- the single largest denial source in the run.
    text = "\n".join(lines)
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
                if m.group(0) not in pins and text.count(m.group(0)) < 2:
                    out.append((i, what, m.group(0), s[:100]))
                break
    return out

def collection_failure(root: Path) -> str:
    """A test file that cannot be COLLECTED takes the whole suite down before
    a single test runs. tzc13, iteration 1: test_tzconvert.py pinned a derived
    value to a hand-written literal at module level -- and the literal was
    wrong (Kolkata is +05:30, the pin said +05:00) -- so pytest failed at
    collection, 7 tests never ran, and QA discovered it a phase later. The
    author's own gate can say so first."""
    import subprocess
    # A Lex suite is collected by `lex run <file> run_all`, not by pytest.
    # The Lex test_author eval baseline read 0/5 because every attempt was
    # denied "no tests collected" by a pytest run over a directory holding
    # only .lex files (#344). Only a suite with Python test files is pytest's.
    py_tests = [p for p in root.rglob("*.py")
                if "test" in p.name.lower() and not p.name.startswith("_")]
    if not py_tests:
        return ""
    # pytest's ABSENCE is the preflight's finding, not this check's: on a CI
    # runner without it, `python -m pytest` exits non-zero for every suite
    # and this check denied all of them while the same suites passed locally.
    probe = subprocess.run([sys.executable, "-c", "import pytest"], capture_output=True)
    if probe.returncode != 0:
        return ""
    try:
        r = subprocess.run([sys.executable, "-m", "pytest", "--collect-only", "-q", "-p", "no:cacheprovider", "."],
                           cwd=str(root), capture_output=True, text=True, timeout=120)
    except Exception:
        return ""  # pytest missing or hung: not this check's verdict to give
    if r.returncode == 0:
        return ""
    tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-12:])
    return ("check_derived_values: the test suite cannot be COLLECTED, so no test can run.\n"
            "A module-level assertion or import in a test file fails before pytest starts;\n"
            "fix the file so `pytest --collect-only` passes:\n\n" + tail + "\n")


def pin_failure(root: Path, files) -> str:
    """A pin is only worth something if it is RUN. tzc16, iteration 1: the
    author pinned `assert EXPECTED_EPOCH == 1752181800` -- derived name on
    one side, literal on the other, exactly the accepted idiom -- and the
    literal was 12h10m wrong (1752181800 is 21:10 UTC, not 09:00). This check
    saw a pin and passed it; QA failed the pin three bounces later, blaming a
    correct app each time. The author has no tool that computes, so a pin it
    writes is a guess with a derivation next to it. Execute the pins here:
    module-level imports and assignments as the prelude, then every
    `assert <expr> == <literal>` whose literal this check would have
    flagged, each reported with the value the derivation actually gives.
    Anything other than an AssertionError (an import that needs the app, a
    syntax the parser rejects) is not this check's verdict."""
    import ast, subprocess
    out = []
    for path in files:
        try:
            tree = ast.parse(path.read_text(), filename=str(path))
        except SyntaxError:
            continue
        prelude, pins = [], []
        for node in tree.body:
            if isinstance(node, (ast.Import, ast.ImportFrom, ast.Assign, ast.AnnAssign)):
                prelude.append(ast.get_source_segment(path.read_text(), node) or "")
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Assert) and isinstance(node.test, ast.Compare)
                    and len(node.test.ops) == 1 and isinstance(node.test.ops[0], ast.Eq)):
                continue
            left, right = node.test.left, node.test.comparators[0]
            def is_lit(n):
                return isinstance(n, ast.Constant) and any(
                    pat.search(str(n.value)) for pat, _ in LITERALS)
            if is_lit(right) and not is_lit(left):
                expr, lit = left, right
            elif is_lit(left) and not is_lit(right):
                expr, lit = right, left
            else:
                continue
            if isinstance(expr, ast.Constant):
                continue
            pins.append((node.lineno, ast.unparse(expr), repr(lit.value)))
        if not pins:
            continue
        script = "\n".join(prelude) + "\n"
        for lineno, expr, lit in pins:
            script += (f"_v = ({expr})\n"
                       f"if _v != {lit}: print('PIN_FAIL\\t{lineno}\\t' + repr(_v) + '\\t' + {lit!r}); \n")
        try:
            r = subprocess.run([sys.executable, "-c", script], cwd=str(root),
                               capture_output=True, text=True, timeout=60)
        except Exception:
            continue
        if r.returncode != 0:
            continue  # the prelude needs something this scratch run lacks: not our verdict
        for line in r.stdout.splitlines():
            if line.startswith("PIN_FAIL\t"):
                _, lineno, got, lit = line.split("\t", 3)
                out.append((path.name, lineno, lit, got))
    if not out:
        return ""
    msg = ["check_derived_values: a PIN is wrong -- the derivation does not give the literal.", ""]
    for name, lineno, lit, got in out:
        msg.append(f"  {name}:{lineno}  pinned {lit}, but the derivation gives {got}")
    msg += ["", "The pin did its job here instead of at QA: the literal was typed from memory",
            "and the computation disagrees. Replace the literal with the derivation's value",
            "(the second number above) or drop the pin and assert against the derivation.", ""]
    return "\n".join(msg)


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = [p for p in root.rglob("*") if p.is_file()
             and p.suffix in (".py", ".lex")
             and ("test" in p.name.lower() or p.name.lower().endswith("_test.lex"))]
    if not files:
        # Not "nothing to check" — this IS the finding. A test author whose
        # gate exits 0 for writing no tests seals and hands off, and QA then
        # dies three retries later with "NO TEST FILE", wearing the blame for
        # the omission. Watched happen in tzpin: 3 QA denials, all misfiled.
        print("check_derived_values: NO TEST FILE was written.\n")
        print("A test author's deliverable is a test file. Write one (test_*.py,")
        print("*_test.py, or *_test.lex) with py_check/lex_check so it is on disk,")
        print("then restate it in a fenced block. Prose describing the tests you")
        print("would write is not a test suite, and nothing downstream can run it.")
        return 1
    bad = [(p, hits) for p in files for hits in [scan(p)] if hits]
    if not bad:
        coll = collection_failure(root)
        if coll:
            print(coll)
            return 1
        pin = pin_failure(root, files)
        if pin:
            print(pin)
            return 1
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
    # The hint has to be in the author's language: a .lex author shown a
    # Python datetime derivation has nothing to copy (#344).
    if any(str(f).endswith(".lex") for f, *_ in findings):
        print("  1. COMPUTE the expected value where you assert it:")
        print("       if v == 1700000000 + 330 * 60 { Ok(()) } else { Err(\"shift\") }")
        print("")
        print("  2. PIN the literal to a derivation ONCE, then reuse it freely:")
        print("       let expected := 1700000000 + 330 * 60")
        print("       if expected == 1700019800 { ... }   # the pin; reuse `expected` below")
        print("")
    else:
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
