# trace.lex — append-only audit log for loom sprints.
#
# event_kind values used by loom:
#   graph_proposed  graph_validated  graph_rejected
#   node_started    node_accepted    node_denied    node_failed
#   phase_advanced  sprint_complete

import "std.sql" as sql

import "std.time" as time

import "std.crypto" as crypto

fn record(db :: Db, run_id :: Str, agent_id :: Str, event_kind :: Str, data_json :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let q := "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES (?, ?, ?, ?, ?)"
  let __lex_discard_1 := sql.exec(db, q, [PStr(run_id), PStr(agent_id), PStr(event_kind), PStr(data_json), PStr(now)])
  ()
}

fn new_run_id() -> [random] Str {
  crypto.random_str_hex(16)
}
