# check_restore_performed.lex — a backup exists AND restoring it really works.
#
# An untested backup is a belief. Every launch checklist has "backups: yes" on
# it, and the first time anyone learns the backup was empty, or the wrong file,
# or unreadable, is the night they need it. The ops role exists to perform the
# restore before that night; this gate exists so the role cannot merely SAY it
# did.
#
# So the gate does not trust the role's evidence file -- it RE-EXECUTES the
# restore: finds the backup, restores it into a fresh temporary SQLite
# database, runs an integrity check, and counts the rows itself. The evidence
# must AGREE with what the gate measured. Agreement between an independent
# measurement and the claim is the evidence; the claim alone is not.
#
# Ported from check_restore_performed.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.sql" as sql

import "std.int" as int

import "std.time" as time

import "lex-schema/json_value" as jv

type Count = { name :: Str, rows :: Int }

type NameRow = { name :: Str }

type CountRow = { n :: Int }

type CheckRow = { c :: Str }

fn evidence_name() -> Str {
  "ops/restore-evidence.json"
}

# A .sql dump is replayed; anything else is treated as a SQLite file and copied
# byte-for-byte -- which IS a restore: the question the gate asks is whether
# the file is a readable, consistent database, not how it was produced.
fn restore_into(tmp_db :: Str, backup :: Str) -> [fs_read, fs_write, fs_walk, sql, io] Str {
  if str.ends_with(str.to_lower(backup), ".sql") {
    match io.read(backup) {
      Err(_) => "cannot read the dump",
      Ok(dump) => match sql.open(tmp_db) {
        Err(e) => e.message,
        Ok(h) => list.fold(str.split(dump, ";"), "", fn (acc :: Str, stmt :: Str) -> [sql] Str {
          if not str.is_empty(acc) {
            acc
          } else {
            if str.is_empty(str.trim(stmt)) {
              acc
            } else {
              let r :: Result[List[CountRow], SqlError] := sql.query(h, stmt, [])
              match r {
                Err(e) => sql_reason(e.message),
                Ok(_) => acc,
              }
            }
          }
        }),
      },
    }
  } else {
    match fs.copy(backup, tmp_db) {
      Err(e) => e,
      Ok(_) => "",
    }
  }
}

fn sql_reason(m :: Str) -> Str {
  match str.strip_prefix(m, "sql.query: ") {
    None => m,
    Some(rest) => rest,
  }
}

# `PRAGMA integrity_check AS c` is not valid SQL -- a pragma takes no alias --
# and the syntax error came out as "restoring your backup failed", the checker
# blaming the ops role for the checker's own bug. The table-valued form
# pragma_integrity_check() does take one.
#
# The comment lives ABOVE the fn because lex fmt deletes comments inside a body
# (lex-lang#755).
fn measure(db :: Str) -> [sql, fs_read, fs_write, fs_walk] Result[List[Count], Str] {
  match sql.open(db) {
    Err(e) => Err(e.message),
    Ok(h) => {
      let ic :: Result[List[CheckRow], SqlError] := sql.query(h, "SELECT integrity_check AS c FROM pragma_integrity_check()", [])
      match ic {
        Err(e) => Err(sql_reason(e.message)),
        Ok(rs) => {
          let verdict := match list.head(rs) {
            None => "ok",
            Some(r) => r.c,
          }
          if verdict != "ok" {
            Err(str.concat("integrity_check: ", verdict))
          } else {
            let names :: Result[List[NameRow], SqlError] := sql.query(h, "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name", [])
            match names {
              Err(e) => Err(sql_reason(e.message)),
              Ok(ns) => Ok(list.fold(ns, [], fn (acc :: List[Count], nr :: NameRow) -> [sql] List[Count] {
                let c :: Result[List[CountRow], SqlError] := sql.query(h, str.join(["select count(*) AS n from \"", nr.name, "\""], ""), [])
                match c {
                  Err(_) => acc,
                  Ok(cs) => list.concat(acc, [{ name: nr.name, rows: match list.head(cs) {
                    None => 0,
                    Some(x) => x.n,
                  } }]),
                }
              })),
            }
          }
        },
      }
    },
  }
}

# Python's dict repr, because this string goes into a refusal a founder reads
# next to the one the Python printed, and "{'waitlist': 120}" is what they have
# seen before.
fn dict_repr(cs :: List[Count]) -> Str {
  str.join(["{", str.join(list.map(cs, fn (c :: Count) -> Str {
    str.join(["'", c.name, "': ", int.to_str(c.rows)], "")
  }), ", "), "}"], "")
}

fn same_counts(a :: List[Count], b :: List[Count]) -> Bool {
  if list.len(a) != list.len(b) {
    false
  } else {
    list.fold(a, true, fn (acc :: Bool, x :: Count) -> Bool {
      if not acc {
        false
      } else {
        list.fold(b, false, fn (found :: Bool, y :: Count) -> Bool {
          if found {
            true
          } else {
            x.name == y.name and x.rows == y.rows
          }
        })
      }
    })
  }
}

fn total(cs :: List[Count]) -> Int {
  list.fold(cs, 0, fn (a :: Int, c :: Count) -> Int {
    a + c.rows
  })
}

fn claimed_of(ev :: jv.Json) -> Option[List[Count]] {
  match jv.get_field(ev, "tables") {
    None => None,
    Some(t) => match t {
      JObj(fields) => Some(list.map(fields, fn (kv :: (Str, jv.Json)) -> Count {
        match kv {
          (k, v) => { name: k, rows: match v {
            JInt(n) => n,
            JStr(s) => match str.to_int(s) {
              None => 0,
              Some(i) => i,
            },
            _ => 0,
          } },
        }
      })),
      _ => None,
    },
  }
}

fn field_str(j :: jv.Json, name :: Str) -> Str {
  match jv.get_field(j, name) {
    None => "",
    Some(v) => match v {
      JStr(s) => s,
      _ => "",
    },
  }
}

type Finding = { attr :: Str, why :: Str }

fn main(root_arg :: Str) -> [fs_read, fs_write, fs_walk, sql, io, time] Int {
  let root := if str.is_empty(root_arg) {
    "."
  } else {
    root_arg
  }
  let ev_path := str.join([root, "/", evidence_name()], "")
  if not fs.is_file(ev_path) {
    let __a := io.print("RESTORE_VERIFIED")
    let __b := io.print(str.join(["check_restore_performed: no ", evidence_name(), ". The ops role must perform a restore and record what it restored."], ""))
    1
  } else {
    match io.read(ev_path) {
      Err(_) => malformed("cannot be read"),
      Ok(raw) => match jv.parse(raw) {
        Err(e) => malformed(e.message),
        Ok(ev) => match claimed_of(ev) {
          None => malformed("'tables'"),
          Some(claimed) => {
            let rel := field_str(ev, "backup")
            if str.is_empty(rel) {
              malformed("'backup'")
            } else {
              judge(root, rel, claimed)
            }
          },
        },
      },
    }
  }
}

fn malformed(why :: Str) -> [io] Int {
  let __a := io.print("RESTORE_VERIFIED")
  let __b := io.print(str.join(["check_restore_performed: ", evidence_name(), " is not the expected shape (", why, "); need {backup, tables}"], ""))
  1
}

fn judge(root :: Str, rel :: Str, claimed :: List[Count]) -> [fs_read, fs_write, fs_walk, sql, io, time] Int {
  let backup := str.join([root, "/", rel], "")
  let present := fs.is_file(backup) and file_size(backup) > 0
  let tmp := str.join(["/tmp/loom-restore-", int.to_str(time.now_ms()), ".sqlite"], "")
  let restore_result := if not fs.is_file(backup) {
    Err("missing")
  } else {
    let err := restore_into(tmp, backup)
    if not str.is_empty(err) {
      Err(err)
    } else {
      match measure(tmp) {
        Err(e) => Err(e),
        Ok(m) => Ok(m),
      }
    }
  }
  let base := if present {
    ([{ attr: "checkable:backup-present", why: "" }], [])
  } else {
    ([], [{ attr: "checkable:backup-present", why: str.join(["backup ", rel, " missing or empty"], "") }])
  }
  match base {
    (met0, unmet0) => {
      let rest := match restore_result {
        Err(e) => if e == "missing" {
          ([], [])
        } else {
          ([], [{ attr: "checkable:restore-performed", why: str.join(["restoring ", rel, " into a fresh database failed: ", e], "") }])
        },
        Ok(measured) => {
          let data := if list.is_empty(measured) {
            ([], [{ attr: "checkable:restore-has-data", why: "the restored database has no tables -- an empty backup restores perfectly and protects nothing" }])
          } else {
            if total(measured) == 0 {
              ([], [{ attr: "checkable:restore-has-data", why: str.join(["every table restored empty: ", dict_repr(measured)], "") }])
            } else {
              ([{ attr: "checkable:restore-has-data", why: "" }], [])
            }
          }
          let agree := if same_counts(measured, claimed) {
            ([{ attr: "checkable:evidence-matches-restore", why: "" }], [])
          } else {
            ([], [{ attr: "checkable:evidence-matches-restore", why: str.join(["the evidence claims ", dict_repr(claimed), " but an independent restore measured ", dict_repr(measured)], "") }])
          }
          match (data, agree) {
            ((dm, du), (am, au)) => (list.concat([{ attr: "checkable:restore-performed", why: "" }], list.concat(dm, am)), list.concat(du, au)),
          }
        },
      }
      match rest {
        (met1, unmet1) => report(list.concat(met0, met1), list.concat(unmet0, unmet1)),
      }
    },
  }
}

fn file_size(p :: Str) -> [fs_walk] Int {
  match fs.stat(p) {
    Err(_) => 0,
    Ok(s) => s.size,
  }
}

fn report(met :: List[Finding], unmet :: List[Finding]) -> [io] Int {
  let attrs := str.join(list.map(met, fn (f :: Finding) -> Str {
    f.attr
  }), " ")
  let __v := io.print(str.concat("RESTORE_VERIFIED ", attrs))
  if list.is_empty(unmet) {
    let __o := io.print(str.concat("RESTORE_OK ", attrs))
    0
  } else {
    let __h := io.print("check_restore_performed: the restore is not proven:\n")
    let __l := list.fold(unmet, 0, fn (n :: Int, f :: Finding) -> [io] Int {
      let __ := io.print(str.join(["  ", f.attr, ": ", f.why], ""))
      n + 1
    })
    let __f := io.print("\nPerform the restore for real, into a fresh database, and record exactly what it contained.")
    1
  }
}

