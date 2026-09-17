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

