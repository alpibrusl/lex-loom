#!/usr/bin/env python3
"""Check that a backup exists AND that restoring it really works.

An untested backup is a belief. Every launch checklist has "backups: yes" on
it, and the first time anyone learns the backup was empty, or the wrong file,
or unreadable, is the night they need it. The ops role exists to perform the
restore before that night; this gate exists so the role cannot merely say it
did.

So the gate does not trust the role's evidence file -- it RE-EXECUTES the
restore. It finds the backup the role produced, restores it into a fresh
temporary SQLite database, runs an integrity check, and counts the rows
itself. The evidence file (ops/restore-evidence.json) must agree with what the
gate measured, or the gate fails: agreement between an independent
measurement and the claim is the evidence, not the claim alone.

Under the gate's scratch dir it looks for:
  ops/restore-evidence.json   {backup: <path>, tables: {<name>: <rows>, ...}}
  <backup>                    a SQLite file, or a .sql dump, named in the evidence

Always prints `RESTORE_VERIFIED <attrs met>`; on success also `RESTORE_OK` and
exit 0, otherwise exit 1 naming what failed.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

EVIDENCE = "ops/restore-evidence.json"


def restore_into(tmp_db: Path, backup: Path) -> None:
    """Restore a backup into tmp_db. .sql dumps are replayed; anything else is
    treated as a SQLite file and copied byte-for-byte (which is a restore:
    the question is whether the file is a readable, consistent database)."""
    if backup.suffix.lower() == ".sql":
        sql = backup.read_text(errors="replace")
        con = sqlite3.connect(tmp_db)
        try:
            con.executescript(sql)
            con.commit()
        finally:
            con.close()
    else:
        tmp_db.write_bytes(backup.read_bytes())


def measure(db: Path) -> dict:
    con = sqlite3.connect(db)
    try:
        ok = con.execute("PRAGMA integrity_check").fetchone()[0]
        if ok != "ok":
            raise RuntimeError(f"integrity_check: {ok}")
        names = [r[0] for r in con.execute(
            "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name")]
        return {n: con.execute(f'select count(*) from "{n}"').fetchone()[0] for n in names}
    finally:
        con.close()


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    met, unmet = [], []

    ev_path = root / EVIDENCE
    if not ev_path.is_file():
        print("RESTORE_VERIFIED")
        print(f"check_restore_performed: no {EVIDENCE}. The ops role must perform a restore and record what it restored.")
        return 1
    try:
        ev = json.loads(ev_path.read_text())
        backup = root / ev["backup"]
        claimed = {k: int(v) for k, v in ev["tables"].items()}
    except Exception as e:
        print("RESTORE_VERIFIED")
        print(f"check_restore_performed: {EVIDENCE} is not the expected shape ({e}); need {{backup, tables}}")
        return 1

    if backup.is_file() and backup.stat().st_size > 0:
        met.append("checkable:backup-present")
    else:
        unmet.append(("checkable:backup-present", f"backup {ev['backup']} missing or empty"))

    measured = None
    if backup.is_file():
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td) / "restored.sqlite"
            try:
                restore_into(tmp, backup)
                measured = measure(tmp)
                met.append("checkable:restore-performed")
            except Exception as e:
                unmet.append(("checkable:restore-performed", f"restoring {ev['backup']} into a fresh database failed: {e}"))

    if measured is not None:
        if not measured:
            unmet.append(("checkable:restore-has-data", "the restored database has no tables -- an empty backup restores perfectly and protects nothing"))
        elif sum(measured.values()) == 0:
            unmet.append(("checkable:restore-has-data", f"every table restored empty: {measured}"))
        else:
            met.append("checkable:restore-has-data")
        if measured == claimed:
            met.append("checkable:evidence-matches-restore")
        else:
            unmet.append(("checkable:evidence-matches-restore",
                          f"the evidence claims {claimed} but an independent restore measured {measured}"))

    print("RESTORE_VERIFIED " + " ".join(met))
    if unmet:
        print("check_restore_performed: the restore is not proven:\n")
        for attr, why in unmet:
            print(f"  {attr}: {why}")
        print("\nPerform the restore for real, into a fresh database, and record exactly what it contained.")
        return 1
    print("RESTORE_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
