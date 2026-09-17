# query.lex — the two questions loom's shell scripts kept shelling to Python to
# answer: "what is this field in this JSON" and "what does this SQL count".
#
# Those two jobs were 59 of the ~139 `python3 -c` call sites left in loom's
# shell after the gate checkers moved to Lex (lex-loom#512), spread over
# forty-four scripts, each one an `import sys,json` or `import sqlite3,sys`
# one-liner with its own quoting and its own idea of what a missing key means.
#
# One tool instead. A missing field is an empty string and exit 1, never a
# traceback -- the scripts that call this are `$(...)` substitutions in a
# pipeline, where a Python stack trace lands in a variable and is then used as
# if it were a value.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.sql" as sql

import "std.int" as int

import "lex-schema/json_value" as jv

type ValRow = { v :: Str }

# A dotted path: "company.uuid" reaches {"company":{"uuid":...}}. A numeric
# segment indexes a list, so "deliveries.0.verdict" works on the shapes the
# consortium runner reads.
fn walk(j :: jv.Json, segments :: List[Str]) -> Option[jv.Json] {
  match list.head(segments) {
    None => Some(j),
    Some(seg) => match index_of(seg) {
      Some(i) => match j {
        JList(items) => match nth(items, i) {
          None => None,
          Some(child) => walk(child, list.tail(segments)),
        },
        _ => None,
      },
      None => match jv.get_field(j, seg) {
        None => None,
        Some(child) => walk(child, list.tail(segments)),
      },
    },
  }
}

fn index_of(seg :: Str) -> Option[Int] {
  if str.is_empty(seg) {
    None
  } else {
    match str.to_int(seg) {
      None => None,
      Some(n) => Some(n),
    }
  }
}

fn nth(xs :: List[jv.Json], i :: Int) -> Option[jv.Json] {
  if i < 0 {
    None
  } else {
    if i == 0 {
      list.head(xs)
    } else {
      nth(list.tail(xs), i - 1)
    }
  }
}

# A scalar prints bare -- "8093", not "\"8093\"" -- because every caller
# substitutes it straight into a shell variable. Anything structural prints as
# JSON, so a caller that wants a sub-document gets one.
fn render(j :: jv.Json) -> Str {
  match j {
    JStr(s) => s,
    JInt(n) => int.to_str(n),
    JBool(b) => if b {
      "true"
    } else {
      "false"
    },
    JNull => "",
    _ => jv.stringify(j),
  }
}

fn json_get(text :: Str, path :: Str) -> [io] Int {
  match jv.parse(text) {
    Err(_) => 1,
    Ok(j) => match walk(j, list.filter(str.split(path, "."), fn (s :: Str) -> Bool {
      not str.is_empty(s)
    })) {
      None => 1,
      Some(found) => {
        let __ := io.print(render(found))
        0
      },
    },
  }
}

fn main_json(path :: Str, field :: Str) -> [fs_read, io] Int {
  match io.read(path) {
    Err(_) => 1,
    Ok(text) => json_get(text, field),
  }
}

fn main_json_str(text :: Str, field :: Str) -> [io] Int {
  json_get(text, field)
}

# Build a JSON object from k=v arguments. Replaces
# `python3 -c 'print(json.dumps({"item_id": sys.argv[1]}))'` -- the shape a
# dozen callers in the cloud runner needed, each with its own quoting. A value
# that parses as JSON is embedded as JSON, so nesting composes; anything else
# is a string, which is what a shell variable almost always is.
fn main_obj(pairs :: Str) -> [io] Int {
  let fields := list.fold(str.split(pairs, "\n"), [], fn (acc :: List[(Str, jv.Json)], kv :: Str) -> List[(Str, jv.Json)] {
    if str.is_empty(str.trim(kv)) {
      acc
    } else {
      let parts := str.split(kv, "=")
      match list.head(parts) {
        None => acc,
        Some(k) => {
          let raw := str.join(list.tail(parts), "=")
          list.concat(acc, [(k, match jv.parse(raw) {
            Err(_) => JStr(raw),
            Ok(j) => match j {
              JStr(_) => JStr(raw),
              JInt(_) => j,
              JBool(_) => j,
              JObj(_) => j,
              JList(_) => j,
              _ => JStr(raw),
            },
          })])
        },
      }
    }
  })
  let __ := io.print(jv.stringify(JObj(fields)))
  0
}

# A JSON array of strings, one per input line. Replaces
# `python3 -c 'print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'`
# -- the shape `ls -1 paths | ...` needed to tell the control plane which
# stack paths this runner can build.
fn main_array(lines :: Str) -> [io] Int {
  let items := list.map(list.filter(list.map(str.split(lines, "\n"), fn (l :: Str) -> Str {
    str.trim(l)
  }), fn (l :: Str) -> Bool {
    not str.is_empty(l)
  }), fn (l :: Str) -> jv.Json {
    JStr(l)
  })
  let __ := io.print(jv.stringify(JList(items)))
  0
}

# Set one field on an existing document. Replaces the `with_token` idiom, which
# read a JSON body, added a credential and re-serialised it -- in a shell
# function, with the token on the command line.
fn main_set(text :: Str, field :: Str, value :: Str) -> [io] Int {
  match jv.parse(text) {
    Err(_) => 1,
    Ok(j) => match j {
      JObj(fields) => {
        let kept := list.filter(fields, fn (kv :: (Str, jv.Json)) -> Bool {
          match kv {
            (k, _) => k != field,
          }
        })
        let __ := io.print(jv.stringify(JObj(list.concat(kept, [(field, JStr(value))]))))
        0
      },
      _ => 1,
    },
  }
}

# Set a field at a dotted PATH, list indices included:
# `resource_changes.1.provider_name`. main_set only reached the top level,
# which was enough until a demo needed to forge one resource's provider inside
# a plan to prove the gate catches it.
fn set_at(j :: jv.Json, segments :: List[Str], value :: jv.Json) -> jv.Json {
  match list.head(segments) {
    None => value,
    Some(seg) => {
      let rest := list.tail(segments)
      match index_of(seg) {
        Some(i) => match j {
          JList(items) => JList(replace_nth(items, i, set_at(match nth(items, i) {
            None => JNull,
            Some(c) => c,
          }, rest, value))),
          _ => j,
        },
        None => match j {
          JObj(fields) => JObj(upsert(fields, seg, set_at(match jv.get_field(j, seg) {
            None => JNull,
            Some(c) => c,
          }, rest, value))),
          _ => j,
        },
      }
    },
  }
}

fn replace_nth(items :: List[jv.Json], i :: Int, v :: jv.Json) -> List[jv.Json] {
  list.map(list.enumerate(items), fn (iv :: (Int, jv.Json)) -> jv.Json {
    match iv {
      (k, item) => if k == i {
        v
      } else {
        item
      },
    }
  })
}

fn upsert(fields :: List[(Str, jv.Json)], key :: Str, v :: jv.Json) -> List[(Str, jv.Json)] {
  if list.fold(fields, false, fn (f :: Bool, kv :: (Str, jv.Json)) -> Bool {
    match kv {
      (k, _) => f or k == key,
    }
  }) {
    list.map(fields, fn (kv :: (Str, jv.Json)) -> (Str, jv.Json) {
      match kv {
        (k, old) => if k == key {
          (k, v)
        } else {
          (k, old)
        },
      }
    })
  } else {
    list.concat(fields, [(key, v)])
  }
}

fn main_set_path(text :: Str, path :: Str, value :: Str) -> [io] Int {
  match jv.parse(text) {
    Err(_) => 1,
    Ok(j) => {
      let __ := io.print(jv.stringify(set_at(j, segments_of(path), JStr(value))))
      0
    },
  }
}

# The first element of a list whose field equals a value, then a path into it.
# Replaces the decision-reading idiom repeated six times in the cloud runner:
# `ds=[d for d in json.loads(x).get("decisions",[]) if d.get("status")=="decided"]`
# then `ds[0]["verdict"]`.
fn main_find(text :: Str, listpath :: Str, cond :: Str, path :: Str) -> [io] Int {
  let parts := str.split(cond, "=")
  let key := match list.head(parts) {
    None => "",
    Some(k) => k,
  }
  let want := str.join(list.tail(parts), "=")
  match jv.parse(text) {
    Err(_) => 1,
    Ok(j) => match walk(j, segments_of(listpath)) {
      None => 1,
      Some(JList(items)) => match list.head(list.filter(items, fn (it :: jv.Json) -> Bool {
        match jv.get_field(it, key) {
          Some(JStr(v)) => v == want,
          _ => false,
        }
      })) {
        None => 1,
        Some(found) => match walk(found, segments_of(path)) {
          None => 1,
          Some(v) => {
            let __ := io.print(render(v))
            0
          },
        },
      },
      _ => 1,
    },
  }
}

fn segments_of(path :: Str) -> List[Str] {
  list.filter(str.split(path, "."), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
}

# The first column of every row, one per line. The demos' `sqlq` helper, which
# eight of them had defined for themselves with slightly different NULL and
# missing-file handling.
fn main_sql_rows(db :: Str, query :: Str) -> [sql, fs_read, fs_write, io] Int {
  if not str.starts_with(str.to_lower(str.trim(query)), "select") {
    1
  } else {
    match sql.open(str.join(["file:", db, "?mode=ro"], "")) {
      Err(_) => 1,
      Ok(h) => {
        # `WITH q(v) AS (<query>)` names the caller's first column without the
        # caller having to alias it. The alternative was requiring `AS v` at
        # every call site, which would have put a tool's implementation detail
        # into twelve queries that read perfectly well already.
        let rows :: Result[List[ValRow], SqlError] := sql.query(h, str.join(["WITH q(v) AS (", query, ") SELECT CAST(COALESCE(v, '') AS TEXT) AS v FROM q"], ""), [])
        match rows {
          Err(_) => 1,
          Ok(rs) => {
            let __ := list.fold(rs, 0, fn (n :: Int, r :: ValRow) -> [io] Int {
              let __p := io.print(r.v)
              n + 1
            })
            0
          },
        }
      },
    }
  }
}

# Run statements against a database, writes allowed. This is the WRITE
# counterpart to main_sql, and it is deliberately a separate entry point: a
# script that only counts rows should not be able to drop a table by typo.
#
# It exists because loom's demos seeded their fixtures through
# `python3 - <<PY / import sqlite3 / CREATE TABLE ... / INSERT INTO ...`. The
# SQL was always the real content; Python was there to hold a connection. Now
# the SQL is the file and nothing holds it.
#
# Split on ";" because std.sql takes one statement at a time. A ";" inside a
# string literal would split wrongly -- no fixture here has one, and a checker
# that silently mangled such a statement would be worse than one that cannot
# take it, so an empty or unparseable fragment stops the run with its own
# error rather than being skipped.
fn main_sql_exec(db :: Str, script :: Str) -> [sql, fs_read, fs_write, io] Int {
  match sql.open(db) {
    Err(e) => {
      let __ := io.print(str.concat("sql-exec: ", e.message))
      1
    },
    Ok(h) => list.fold(str.split(script, ";"), 0, fn (rc :: Int, stmt :: Str) -> [sql, io] Int {
      if rc != 0 or str.is_empty(str.trim(stmt)) {
        rc
      } else {
        let r :: Result[List[ValRow], SqlError] := sql.query(h, stmt, [])
        match r {
          Err(e) => {
            let __ := io.print(str.join(["sql-exec: ", e.message, " in: ", str.trim(stmt)], ""))
            1
          },
          Ok(_) => 0,
        }
      }
    }),
  }
}

# One scalar from one SELECT, opened read-only. Read-only because a script
# asking "how many nodes were cancelled" has no business being able to write,
# and because these run against a company's live trail while it is running.
fn main_sql(db :: Str, query :: Str) -> [sql, fs_read, fs_write, io] Int {
  if not str.starts_with(str.to_lower(str.trim(query)), "select") {
    let __ := io.print("")
    1
  } else {
    match sql.open(str.join(["file:", db, "?mode=ro"], "")) {
      Err(_) => {
        let __ := io.print("")
        1
      },
      Ok(h) => {
        let rows :: Result[List[ValRow], SqlError] := sql.query(h, str.join(["SELECT CAST(COALESCE((", query, "), '') AS TEXT) AS v"], ""), [])
        match rows {
          Err(_) => {
            let __ := io.print("")
            1
          },
          Ok(rs) => match list.head(rs) {
            None => {
              let __ := io.print("")
              1
            },
            Some(r) => {
              let __ := io.print(r.v)
              0
            },
          },
        }
      },
    }
  }
}

