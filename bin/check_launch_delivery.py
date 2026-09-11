#!/usr/bin/env python3
"""Check a launch-delivery against the run-2 launch criteria (lex-loom#447,
Run B). Prints one LAUNCH_DELIVERY_VERIFIED line naming every checkable
criterion met, then LAUNCH_DELIVERY_OK (exit 0) or the unmet ones with why
(exit 1). The three human criteria are not this checker's to answer.

  python3 bin/check_launch_delivery.py <company.db> <workspace dir>

What loom recorded, by the sprint's graph (node_results has no role column):
  checkable:iteration-passed          company_iterations status=success
  checkable:channel-plan-present      an accepted node cast as community
  checkable:welcome-sequence-present  an accepted node cast as lifecycle
  checkable:launch-runbook-present    an accepted node cast as release_manager

What the PRODUCT recorded, counted HERE in the product's own store. The
workspace's launch/evidence.json names the store and the read-only queries:
  {"db": "data/app.sqlite",
   "waitlist_signups_sql": "select count(*) from waitlist",
   "would_pay_sql": "select count(*) from waitlist where would_pay=1",
   "first_genuine_submission_sql": "select min(created_at) from submissions where genuine=1",
   "paying_customers_sql": "select count(*) from payments where status='paid'"}
The buyer runs each query itself against the store, opened read-only; a
number the supplier wrote into the file is never consulted. Thresholds are
#452's stages: 100 signups OR 15 would-pay (Stage 0), one paying customer
(Stage 2). No file, no store, a non-SELECT query, or a query that fails:
that criterion is unmet with the reason, never a crash.
"""
import json
import sqlite3
import sys
from pathlib import Path

MIN_SIGNUPS = 100
MIN_WOULD_PAY = 15
MIN_PAYING = 1


def accepted_node_of_role(c: sqlite3.Connection, sprint: str, role: str) -> bool:
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


def scalar(store: Path, sql: str):
    """One read-only SELECT against the product's store -> (value, error)."""
    if not isinstance(sql, str) or not sql.strip().lower().startswith("select"):
        return None, "not a SELECT (only read-only queries are run)"
    try:
        c = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
        try:
            row = c.execute(sql).fetchone()
        finally:
            c.close()
    except sqlite3.Error as e:
        return None, f"{store.name}: {e}"
    return (row[0] if row else None), ""


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: check_launch_delivery.py <company.db> <workspace dir>"); return 2
    db_path, ws = Path(sys.argv[1]), Path(sys.argv[2])
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

    for attr, role in (("checkable:channel-plan-present", "community"),
                       ("checkable:welcome-sequence-present", "lifecycle"),
                       ("checkable:launch-runbook-present", "release_manager")):
        ok = bool(passed_sprint and c is not None and accepted_node_of_role(c, passed_sprint, role))
        (met if ok else unmet).append(attr if ok else (attr, f"no accepted {role} node in {passed_sprint or 'any sprint'}"))

    ev_path = ws / "launch" / "evidence.json"
    ev, store = {}, None
    if ev_path.exists():
        try:
            ev = json.loads(ev_path.read_text())
            store = ws / str(ev.get("db", ""))
        except (json.JSONDecodeError, OSError) as e:
            ev, store = {}, None
            why = f"launch/evidence.json unreadable: {e.__class__.__name__}"
        else:
            why = "" if store.exists() else f"launch/evidence.json names {ev.get('db')!r}, which is not in the workspace"
    else:
        why = "no launch/evidence.json in the workspace (the product must name its store and the queries)"
    if why or store is None:
        for attr in ("checkable:waitlist-threshold", "checkable:first-genuine-submission", "checkable:paying-customer"):
            unmet.append((attr, why))
    else:
        signups, e1 = scalar(store, ev.get("waitlist_signups_sql"))
        would_pay, e2 = scalar(store, ev.get("would_pay_sql"))
        s_ok = isinstance(signups, (int, float)) and signups >= MIN_SIGNUPS
        w_ok = isinstance(would_pay, (int, float)) and would_pay >= MIN_WOULD_PAY
        if s_ok or w_ok:
            met.append("checkable:waitlist-threshold")
        else:
            unmet.append(("checkable:waitlist-threshold", f"counted {signups if not e1 else e1} signups and {would_pay if not e2 else e2} would-pay; Stage 0 needs {MIN_SIGNUPS} or {MIN_WOULD_PAY}"))
        first, e3 = scalar(store, ev.get("first_genuine_submission_sql"))
        if not e3 and first not in (None, "", 0):
            met.append("checkable:first-genuine-submission")
        else:
            unmet.append(("checkable:first-genuine-submission", e3 or "the store records no genuine submission"))
        paying, e4 = scalar(store, ev.get("paying_customers_sql"))
        if not e4 and isinstance(paying, (int, float)) and paying >= MIN_PAYING:
            met.append("checkable:paying-customer")
        else:
            unmet.append(("checkable:paying-customer", e4 or f"counted {paying} paying customers; Stage 2 needs {MIN_PAYING}"))

    print("LAUNCH_DELIVERY_VERIFIED " + " ".join(met))
    if unmet:
        print("check_launch_delivery: the delivery does not meet these checkable criteria:\n")
        for attr, why in unmet:
            print(f"  {attr}: {why}")
        return 1
    print("LAUNCH_DELIVERY_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
