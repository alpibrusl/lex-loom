# registry.lex — agent registration and discovery.

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

type AgentRef = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str], status :: Str }

type AgentRow = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities_json :: Str, status :: Str }

fn parse_agent_row(r :: AgentRow) -> AgentRef {
  let cap_list := match jv.parse(r.capabilities_json) {
    Ok(JList(items)) => list.fold(items, [], fn (acc :: List[Str], j :: jv.Json) -> List[Str] {
      match j {
        JStr(s) => list.concat(acc, [s]),
        _ => acc,
      }
    }),
    _ => [],
  }
  { id: r.id, kind: r.kind, name: r.name, inbox_url: r.inbox_url, capabilities: cap_list, status: r.status }
}

fn db_exec(db :: conn.ConnDb, sql_str :: Str, params :: List[SqlParam]) -> [sql, fs_write] Result[Unit, Str] {
  let sq := ormq.for_dialect({ sql: sql_str, params: params }, db.dialect)
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn register(db :: conn.ConnDb, id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let caps_json := jv.stringify(JList(list.map(capabilities, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))
  let q := "INSERT INTO agents (id, kind, name, inbox_url, capabilities_json, status, registered_at, last_seen_at) VALUES (?, ?, ?, ?, ?, 'active', ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, inbox_url=excluded.inbox_url, capabilities_json=excluded.capabilities_json, status='active', last_seen_at=excluded.last_seen_at"
  db_exec(db, q, [PStr(id), PStr(kind), PStr(name), PStr(inbox_url), PStr(caps_json), PStr(now), PStr(now)])
}

fn heartbeat(db :: conn.ConnDb, id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  db_exec(db, "UPDATE agents SET last_seen_at=? WHERE id=?", [PStr(now), PStr(id)])
}

fn set_status(db :: conn.ConnDb, id :: Str, status :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  db_exec(db, "UPDATE agents SET status=?, last_seen_at=? WHERE id=?", [PStr(status), PStr(now), PStr(id)])
}

fn find_by_id(db :: conn.ConnDb, id :: Str) -> [sql, fs_read] Result[Option[AgentRef], Str] {
  let sq := ormq.for_dialect({ sql: "SELECT id, kind, name, inbox_url, capabilities_json, status FROM agents WHERE id=?", params: [PStr(id)] }, db.dialect)
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(match list.head(rs) {
      None => None,
      Some(r) => Some(parse_agent_row(r)),
    }),
  }
}

fn find_by_kind(db :: conn.ConnDb, kind :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let sq := ormq.for_dialect({ sql: "SELECT id, kind, name, inbox_url, capabilities_json, status FROM agents WHERE kind=? AND status='active'", params: [PStr(kind)] }, db.dialect)
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

fn list_all(db :: conn.ConnDb) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db.handle, "SELECT id, kind, name, inbox_url, capabilities_json, status FROM agents ORDER BY kind, name", [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

