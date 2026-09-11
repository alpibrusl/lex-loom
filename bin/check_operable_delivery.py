#!/usr/bin/env python3
"""Check an operable-delivery against the run-2 operable criteria.
    check_operable_delivery.py <company.db> <workspace dir> [--domain <host>]

Run 1's software contract ended at "software built". This contract pays for
the product being OPERABLE -- measurable, restorable, documented for launch,
and reachable over TLS. Every criterion is re-derived by the buyer, the way
run 1's were: from what loom itself recorded, and by re-running the same
grounded checkers the roles' own gates used.

  checkable:iteration-passed       an iteration ended with status success
  checkable:acceptance-passed      that sprint's trail carries acceptance_passed
  checkable:metrics-instrumented   bin/check_metrics_instrumented.py passes on
                                   the workspace (every PRD metric names an
                                   event the code really emits)
  checkable:restore-performed      bin/check_restore_performed.py passes (the
                                   role's backup restores into a fresh database
                                   and its counts match the evidence)
  checkable:runbook-present        the passing sprint has an ACCEPTED node whose
                                   role is release_manager
  checkable:data-map-present       ... whose role is data_protection
  checkable:reachable-over-tls     https://<domain>/healthz answers {"ok":true};
                                   assessed only when --domain is given, and
                                   reported unmet otherwise -- a domain is a
                                   founder-provided need, never assumed

Prints `OPERABLE_DELIVERY_VERIFIED <attrs met>` always, `OPERABLE_DELIVERY_OK`
on a full pass (exit 0), otherwise exit 1 naming each unmet criterion.
"""
import json
import sqlite3
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def sub_checker(script: str, ws: Path) -> tuple[bool, str]:
    p = HERE / script
    if not p.exists():
        return False, f"{script} not found beside this checker"
    r = subprocess.run([sys.executable, str(p), str(ws)], capture_output=True, text=True, timeout=120)
    tail = (r.stdout.strip().splitlines() or [""])[-1][:160]
    return r.returncode == 0, tail


def accepted_node_of_role(c: sqlite3.Connection, sprint: str, role: str) -> bool:
    """An accepted node_results row in `sprint` whose node the sprint's graph
    casts as `role`. node_results carries no role column; the graph does."""
    try:
        roles = {}
        for (gj,) in c.execute("SELECT graph_json FROM sprint_graphs WHERE sprint_id=?", (sprint,)):
            for n in json.loads(gj).get("nodes", []):
                roles[n.get("id")] = n.get("role")
        for (nid,) in c.execute("SELECT node_id FROM node_results WHERE sprint_id=? AND accepted=1", (sprint,)):
            if roles.get(nid) == role:
                return True
    except (sqlite3.Error, json.JSONDecodeError):
        return False
    return False


def main() -> int:
    args = [a for a in sys.argv[1:]]
    domain = ""
    if "--domain" in args:
        i = args.index("--domain"); domain = args[i + 1] if i + 1 < len(args) else ""; del args[i:i + 2]
    if len(args) < 2:
        print("usage: check_operable_delivery.py <company.db> <workspace dir> [--domain <host>]"); return 2
    db_path, ws = Path(args[0]), Path(args[1])
    met, unmet = [], []

    passed_sprint, c = "", None
    if db_path.exists():
        c = sqlite3.connect(str(db_path))
        try:
            row = c.execute("SELECT sprint_id FROM company_iterations WHERE status='success' ORDER BY idx DESC LIMIT 1").fetchone()
            passed_sprint = row[0] if row else ""
        except sqlite3.Error:
            pass
    (met if passed_sprint else unmet).append("checkable:iteration-passed" if passed_sprint else ("checkable:iteration-passed", "no iteration ended with status success"))

    acc = 0
    if passed_sprint:
        try:
            acc = c.execute("SELECT count(*) FROM traces WHERE run_id=? AND event_kind='acceptance_passed'", (passed_sprint,)).fetchone()[0]
        except sqlite3.Error:
            acc = 0
    (met if acc else unmet).append("checkable:acceptance-passed" if acc else ("checkable:acceptance-passed", f"no acceptance_passed in the trail of {passed_sprint or 'any sprint'}"))

    for attr, script in (("checkable:metrics-instrumented", "check_metrics_instrumented.py"),
                         ("checkable:restore-performed", "check_restore_performed.py")):
        ok, why = sub_checker(script, ws)
        (met if ok else unmet).append(attr if ok else (attr, why))

    for attr, role in (("checkable:runbook-present", "release_manager"), ("checkable:data-map-present", "data_protection")):
        ok = bool(passed_sprint and c is not None and accepted_node_of_role(c, passed_sprint, role))
        (met if ok else unmet).append(attr if ok else (attr, f"no accepted {role} node in {passed_sprint or 'any sprint'}"))

    if domain:
        try:
            with urllib.request.urlopen(f"https://{domain}/healthz", timeout=15) as r:
                body = json.loads(r.read().decode() or "{}")
            ok = bool(body.get("ok") is True)
            (met if ok else unmet).append("checkable:reachable-over-tls" if ok else ("checkable:reachable-over-tls", f"https://{domain}/healthz answered but not ok:true"))
        except Exception as e:
            unmet.append(("checkable:reachable-over-tls", f"https://{domain}/healthz: {e.__class__.__name__}: {str(e)[:100]}"))
    else:
        unmet.append(("checkable:reachable-over-tls", "no --domain given; a hostname is a founder-provided need and is never assumed"))

    print("OPERABLE_DELIVERY_VERIFIED " + " ".join(met))
    if unmet:
        print("check_operable_delivery: the delivery does not meet these checkable criteria:\n")
        for attr, why in unmet:
            print(f"  {attr}: {why}")
        return 1
    print("OPERABLE_DELIVERY_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
