# relationships.lex — directed relationship graph between agents.

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.list" as list

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "./registry" as reg

type Relationship = { id :: Str, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str }

type RelRow = { id :: Str, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str, active :: Int }

fn parse_rel_row(r :: RelRow) -> Relationship {
  { id: r.id, from_agent: r.from_agent, to_agent: r.to_agent, role: r.role, contract_json: r.contract_json }
}

fn db_exec(db :: conn.ConnDb, sql_str :: Str, params :: List[SqlParam]) -> [sql, fs_write] Result[Unit, Str] {
  let sq := ormq.for_dialect({ sql: sql_str, params: params }, db.dialect)
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn add(db :: conn.ConnDb, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str) -> [sql, fs_write, random, time] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  db_exec(db, "INSERT INTO relationships (id, from_agent, to_agent, role, contract_json, active, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)", [PStr(id), PStr(from_agent), PStr(to_agent), PStr(role), PStr(contract_json), PStr(now)])
}

fn remove(db :: conn.ConnDb, from_agent :: Str, to_agent :: Str, role :: Str) -> [sql, fs_write] Result[Unit, Str] {
  db_exec(db, "UPDATE relationships SET active=0 WHERE from_agent=? AND to_agent=? AND role=?", [PStr(from_agent), PStr(to_agent), PStr(role)])
}

fn peers_of(db :: conn.ConnDb, from_agent :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let sq := ormq.for_dialect({ sql: "SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent=? AND active=1", params: [PStr(from_agent)] }, db.dialect)
  let rows :: Result[List[RelRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: RelRow) -> Relationship {
      parse_rel_row(r)
    })),
  }
}

fn peers_by_role(db :: conn.ConnDb, from_agent :: Str, role :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let sq := ormq.for_dialect({ sql: "SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent=? AND role=? AND active=1", params: [PStr(from_agent), PStr(role)] }, db.dialect)
  let rows :: Result[List[RelRow], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: RelRow) -> Relationship {
      parse_rel_row(r)
    })),
  }
}

fn resolve_refs(db :: conn.ConnDb, rels :: List[Relationship]) -> [sql, fs_read] List[reg.AgentRef] {
  list.fold(rels, [], fn (acc :: List[reg.AgentRef], r :: Relationship) -> [sql, fs_read] List[reg.AgentRef] {
    match reg.find_by_id(db, r.to_agent) {
      Ok(Some(ref)) => if ref.status == "active" {
        list.concat(acc, [ref])
      } else {
        acc
      },
      _ => acc,
    }
  })
}
