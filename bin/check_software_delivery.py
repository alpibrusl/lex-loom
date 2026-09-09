#!/usr/bin/env python3
"""Check a SoftwareCo delivery against the run-1 software-delivery criteria.

    check_software_delivery.py <company.db> <workspace dir> [<skeleton dir>]

Every criterion is mechanical and comes from what loom itself recorded:
  checkable:iteration-passed   an iteration of the company ended with status
                               success (company_iterations)
  checkable:acceptance-passed  that sprint's trail carries acceptance_passed
                               (the sealed artifact was re-executed in a clean
                               dir and its own suite passed)
  checkable:app-present        a top-level Python module exists that is not a
                               test and not the skeleton's (something was built)
  checkable:tests-present      at least one test file exists that is not the
                               skeleton's (something was tested)

Prints `SOFTWARE_DELIVERY_VERIFIED <attrs met>` always, `SOFTWARE_DELIVERY_OK`
on a full pass (exit 0), otherwise exit 1 naming each unmet criterion. The
buyer runs this itself: it re-derives the evidence from the trail rather than
taking the supplier's word (here the same company, which is the point of
routing an internal build through the same contract path).
"""
import hashlib
import sqlite3
import sys
from pathlib import Path


def digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ""


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: check_software_delivery.py <company.db> <workspace dir> [<skeleton dir>]")
        return 2
    db_path, ws = Path(sys.argv[1]), Path(sys.argv[2])
    skeleton = Path(sys.argv[3]) if len(sys.argv) > 3 else Path(__file__).resolve().parent.parent / "paths" / "python-fastapi"
    met, unmet = [], []

    passed_sprint = ""
    if db_path.exists():
        c = sqlite3.connect(str(db_path))
        try:
            row = c.execute("SELECT sprint_id FROM company_iterations WHERE status='success' ORDER BY idx DESC LIMIT 1").fetchone()
            passed_sprint = row[0] if row else ""
        except sqlite3.Error:
            passed_sprint = ""
    if passed_sprint:
        met.append("checkable:iteration-passed")
    else:
        unmet.append(("checkable:iteration-passed", "no iteration of the company ended with status success"))

    acc = 0
    if passed_sprint:
        try:
            acc = c.execute("SELECT count(*) FROM traces WHERE run_id=? AND event_kind='acceptance_passed'", (passed_sprint,)).fetchone()[0]
        except sqlite3.Error:
            acc = 0
    if acc:
        met.append("checkable:acceptance-passed")
    else:
        unmet.append(("checkable:acceptance-passed", "no acceptance_passed in the trail of the passing sprint (%s)" % (passed_sprint or "none")))

    # Run 1 found live: the build put the product in main.py and left the
    # skeleton's app.py untouched, and a criterion pinned to the file NAME
    # settled a working, tested, launched API at 50%. The criterion is that
    # something was built: any top-level Python module that is not a test
    # and not byte-identical to the skeleton's copy.
    skel_mods = {digest(p) for p in skeleton.glob("*.py")}
    built = [p for p in ws.glob("*.py") if not p.name.startswith("test_") and not p.name.endswith("_test.py") and digest(p) not in skel_mods]
    if built:
        met.append("checkable:app-present")
    else:
        unmet.append(("checkable:app-present", "no top-level Python module beyond the path skeleton's (nothing was built)"))

    skel_tests = {digest(p) for p in (skeleton / "tests").glob("test_*.py")} if (skeleton / "tests").exists() else set()
    own_tests = [p for p in ws.rglob("test_*.py") if "__pycache__" not in p.parts and digest(p) not in skel_tests]
    if own_tests:
        met.append("checkable:tests-present")
    else:
        unmet.append(("checkable:tests-present", "no test_*.py beyond the path skeleton's"))

    print("SOFTWARE_DELIVERY_VERIFIED " + " ".join(met))
    if unmet:
        print("check_software_delivery: the delivery does not meet these checkable criteria:\n")
        for attr, why in unmet:
            print(f"  {attr}: {why}")
        return 1
    print("SOFTWARE_DELIVERY_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
