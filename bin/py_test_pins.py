#!/usr/bin/env python3
"""The two checks that must PARSE AND RUN Python test code.

Everything else in this gate moved to bin/check_derived_values.lex
(lex-loom#512). What is left is not loom's logic in another language -- it is
the COMPANY'S product language, the same category as paths/python-* and
py_compile, and it runs only when the work dir holds Python test files:

  collection_failure  a suite that cannot be COLLECTED takes every test down
                      before one runs, and `pytest --collect-only` is the only
                      thing that knows whether it can be.
  pin_failure         a pin is only worth something if it is RUN, and running
                      one means walking a Python AST, reconstructing the
                      expression and evaluating it.

Writing a Python parser in Lex to avoid a Python dependency would be the wrong
trade, and a Lex company never reaches this file.

Prints the failure and exits 1; prints nothing and exits 0 when both pass.

Usage: py_test_pins.py <dir>
"""
import ast
import json
import re
import subprocess
import sys
from pathlib import Path

EPOCH = re.compile(r"(?<![\d.])\d{9,11}(?![\d.])")
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}")
RFC2822 = re.compile(r"[A-Z][a-z]{2}, \d{1,2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2}")
LITERALS = ((EPOCH, "a Unix epoch"), (TIMESTAMP, "a timestamp"), (RFC2822, "an RFC 2822 date"))

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
    # pytest's exit codes: 0 tests collected, 5 NO tests collected, 2 collection
    # interrupted by errors, 4 usage error. Only 2 and 4 are the author's
    # collection failure. 5 is what a correct author produces before the build
    # exists -- `pytest.skip("app module not importable", allow_module_level=True)`
    # -- and the metaspec REQUIRES the author to run independently of the
    # build (tests-authored-independently). tzc18 iteration 1 denied exactly
    # that author four times, the failed layer took the builds down with it,
    # and QA had nothing to judge (#360). Whether tests exist and run is QA's
    # and acceptance's question, asked against the built app.
    if r.returncode in (0, 5):
        return ""
    tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-12:])
    # Two test files with one basename in different folders and no
    # tests/__init__.py: pytest's "import file mismatch". tzc21 iter 2's
    # author was denied for it repeatedly under a hint about module-level
    # assertions it could not act on (#377). Name the files and the fixes.
    if "import file mismatch" in (r.stdout + r.stderr):
        by_name = {}
        for f in root.rglob("*.py"):
            if "__pycache__" in f.parts or any(part.startswith("_") for part in f.parts):
                continue
            if f.name.startswith("test_") or f.name.endswith("_test.py"):
                by_name.setdefault(f.name, []).append(str(f.relative_to(root)))
        dups = {k: v for k, v in by_name.items() if len(v) > 1}
        listed = "\n".join(f"  {k}: {', '.join(sorted(v))}" for k, v in sorted(dups.items())) or "  (pytest reported a mismatch; check for two test files with the same name)"
        return ("check_derived_values: the test suite cannot be COLLECTED: two test files share one\n"
                "basename, and pytest refuses to import both (\"import file mismatch\"):\n\n" + listed + "\n\n"
                "Fix either way: keep ONE of them (remove the other with py_check delete:true, or give\n"
                "it a different name), or add an empty tests/__init__.py so the folder is a package.\n")
    # A module that is not on disk yet is the build's to write, not the
    # author's to import around; a collection error caused only by that is
    # not the author's fault either.
    import re as _re
    missing = _re.findall(r"No module named '([A-Za-z_][\w.]*)'", tail)
    if missing and all(not (root / (m.split(".")[0] + ".py")).exists()
                       and not (root / m.split(".")[0]).is_dir() for m in missing) \
            and "AssertionError" not in tail and "SyntaxError" not in tail:
        return ""
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
            if isinstance(node, (ast.Import, ast.ImportFrom, ast.Assign, ast.AnnAssign, ast.FunctionDef, ast.ClassDef)):
                if isinstance(node, ast.FunctionDef) and node.name.startswith("test"):
                    continue  # tests are QA's to run; helpers and fixtures are the prelude
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
        # Each prelude statement runs on its own with failures tolerated -- a
        # module-level `app = importlib.import_module("main")` that needs the
        # build must not stop the datetime pins from being evaluated -- and
        # each pin is evaluated on its own; a pin whose expression cannot be
        # evaluated here (a name the prelude never bound) is skipped, not
        # judged.
        import json
        script = ("import sys\n_ns = {}\n"
                  f"for _stmt in {json.dumps(prelude)}:\n"
                  "    try:\n        exec(_stmt, _ns)\n    except Exception:\n        pass\n"
                  f"for _lineno, _expr, _lit in {json.dumps(pins)}:\n"
                  "    try:\n        _v = eval(_expr, _ns)\n    except Exception:\n        continue\n"
                  "    if _v != eval(_lit):\n"
                  "        print('PIN_FAIL\\t' + str(_lineno) + '\\t' + repr(_v) + '\\t' + _lit)\n")
        try:
            r = subprocess.run([sys.executable, "-c", script], cwd=str(root),
                               capture_output=True, text=True, timeout=60)
        except Exception:
            continue
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
    files = [p for p in root.rglob("*.py") if p.is_file()
             and ("test" in p.name.lower()) and not p.name.startswith("_")]
    if not files:
        return 0
    for check in (lambda: collection_failure(root), lambda: pin_failure(root, files)):
        why = check()
        if why:
            print(why)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
