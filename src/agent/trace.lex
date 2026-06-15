# trace.lex — append-only audit log for loom sprints.

import "std.sql" as sql

import "std.time" as time

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

fn record(db :: conn.ConnDb, run_id :: Str, agent_id :: Str, event_kind :: Str, data_json :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let sq := ormq.for_dialect({ sql: "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES (?, ?, ?, ?, ?)", params: [PStr(run_id), PStr(agent_id), PStr(event_kind), PStr(data_json), PStr(now)] }, db.dialect)
  let __lex_discard_1 := sql.exec(db.handle, sq.sql, sq.params)
  ()
}

fn new_run_id() -> [random] Str {
  crypto.random_str_hex(16)
}

