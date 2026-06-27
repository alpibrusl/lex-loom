# Worked, COMPILING example: a SQLite-backed Notes HTTP API in pure Lex
# (std.sql + std.net + std.str). CI lex-checks this file, so every API shown is
# real and current. Served verbatim to the Build agent by lex_guidelines("sql").
#
# Things models get wrong about std.sql (all shown correctly below):
#   - Params are the SqlParam ADT — PStr/PInt/PFloat/PBool/PNull — GLOBAL
#     constructors, NOT sql.str()/sql.int().
#   - Rows are TYPED RECORDS you declare; annotate `Result[List[Row], SqlError]`
#     and read fields directly (r.title). No List[List[sql.Value]], no VStr/VInt.
#   - sql.open -> Result[Db, SqlError]; Db/SqlError/SqlParam are GLOBAL (no `sql.`).

import "std.sql" as sql

import "std.net" as net

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.env" as env

type Request = { body :: Str, method :: Str, path :: Str, query :: Str }

type Response = { body :: Str, status :: Int }

type Note = { id :: Int, title :: Str, body :: Str }

fn db_path() -> [env] Str {
  match env.get("DB_PATH") {
    Some(p) => p,
    None => "/tmp/notes.db",
  }
}

# open + create table (idempotent). Returns the opaque Db handle.
fn init_db() -> [sql, fs_write, env] Result[Db, SqlError] {
  match sql.open(db_path()) {
    Err(e) => Err(e),
    Ok(db) => match sql.exec(db, "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL)", []) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn note_json(n :: Note) -> Str {
  str.join(["{\"id\":", int.to_str(n.id), ",\"title\":\"", n.title, "\",\"body\":\"", n.body, "\"}"], "")
}

fn create_note(db :: Db, title :: Str, body :: Str) -> [sql] Response {
  if str.is_empty(title) {
    { body: "{\"error\":\"title required\"}", status: 400 }
  } else {
    match sql.exec(db, "INSERT INTO notes (title, body) VALUES (?, ?)", [PStr(title), PStr(body)]) {
      Err(e) => { body: str.concat("{\"error\":\"", e.message), status: 500 },
      Ok(_) => { body: "{\"created\":true}", status: 201 },
    }
  }
}

fn get_note(db :: Db, id :: Int) -> [sql] Response {
  let rows :: Result[List[Note], SqlError] := sql.query(db, "SELECT id, title, body FROM notes WHERE id = ?", [PInt(id)])
  match rows {
    Err(e) => { body: str.concat("{\"error\":\"", e.message), status: 500 },
    Ok(rs) => match list.head(rs) {
      None => { body: "{\"error\":\"not found\"}", status: 404 },
      Some(n) => { body: note_json(n), status: 200 },
    },
  }
}

fn list_notes(db :: Db) -> [sql] Response {
  let rows :: Result[List[Note], SqlError] := sql.query(db, "SELECT id, title, body FROM notes ORDER BY id", [])
  match rows {
    Err(e) => { body: str.concat("{\"error\":\"", e.message), status: 500 },
    Ok(rs) => {
      let items := str.join(list.map(rs, note_json), ",")
      { body: str.join(["[", items, "]"], ""), status: 200 }
    },
  }
}

# Read PORT from env (never hardcode).
fn port() -> [env] Int {
  match env.get("PORT") {
    Some(p) => match str.to_int(p) {
      Some(n) => n,
      None => 8099,
    },
    None => 8099,
  }
}

# Router: match method, then path. Parse /notes/<id> with str.strip_prefix.
fn handle(req :: Request) -> [sql, fs_write, env] Response {
  match init_db() {
    Err(e) => { body: str.concat("{\"error\":\"db: ", e.message), status: 500 },
    Ok(db) => match req.method {
      "GET" => match req.path {
        "/health" => { body: "{\"status\":\"ok\"}", status: 200 },
        "/notes" => list_notes(db),
        _ => match str.strip_prefix(req.path, "/notes/") {
          Some(id_str) => match str.to_int(id_str) {
            Some(id) => get_note(db, id),
            None => { body: "{\"error\":\"bad id\"}", status: 400 },
          },
          None => { body: "{\"error\":\"not found\"}", status: 404 },
        },
      },
      "POST" => match req.path {
        "/notes" => create_note(db, req.body, ""),
        _ => { body: "{\"error\":\"not found\"}", status: 404 },
      },
      _ => { body: "{\"error\":\"method not allowed\"}", status: 405 },
    },
  }
}

# Prefer net.serve_fn (closure) over net.serve (by-name): handler effects stay
# visible to the type-checker and policy gate (passes `lex check --strict`).
fn main() -> [net, sql, fs_write, env] Unit {
  net.serve_fn(port(), handle)
}

