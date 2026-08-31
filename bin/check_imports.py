#!/usr/bin/env python3
"""Check that every module a build produced actually imports.

`spec compiles` runs py_compile, which PARSES. It never resolves an import, so
a build that names a package nobody installed, or imports a symbol that does
not exist, compiles cleanly and then fails the moment anything runs it. The
failure surfaces at the launch node as {"ok": false} — several nodes and
several retries away from the build that caused it.

A live run made the case by itself: iteration 2's PM wrote "the build gate must
be `python -c 'import app_main'` (do NOT use py_compile)" into the goal text.
The pipeline asked for this check on its own.

Each import runs in its own subprocess with a timeout, so a module with a
side effect at import time cannot hang or poison the gate. -P keeps the
working directory off sys.path for the checker itself while still letting the
child import from it via its own cwd.

Usage: check_imports.py <dir>   (exit 1 if any module fails to import)
"""
import subprocess
import sys
from pathlib import Path

TIMEOUT_S = 20

def modules(root: Path):
    """Top-level, importable, non-test, non-scratch modules."""
    for p in sorted(root.glob("*.py")):
        stem = p.stem
        if stem.startswith("_") or "test" in stem.lower() or stem == "conftest":
            continue
        yield stem

def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    names = list(modules(root))
    if not names:
        print("check_imports: no importable modules found — nothing to check")
        return 0
    bad = []
    for name in names:
        try:
            r = subprocess.run(
                [sys.executable, "-c", f"import {name}"],
                cwd=root, capture_output=True, text=True, timeout=TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            bad.append((name, f"import did not finish in {TIMEOUT_S}s — something runs at import time"))
            continue
        if r.returncode != 0:
            tail = [l for l in (r.stderr or "").strip().splitlines() if l.strip()]
            bad.append((name, tail[-1] if tail else "import failed"))
    if not bad:
        print(f"check_imports: {len(names)} module(s) import cleanly")
        return 0
    print("check_imports: a module the build produced does not import.\n")
    for name, why in bad:
        print(f"  {name}: {why}")
    print("\nThis compiles but cannot run: py_compile only parses. Fix the import")
    print("itself — use a package that exists (stdlib, flask, fastapi, jinja2,")
    print("markdown, pytest), or correct the module/symbol name.")
    return 1

if __name__ == "__main__":
    sys.exit(main())
