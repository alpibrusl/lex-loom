# agui_store.lex — persist + replay AG-UI events for a sprint node's LLM
# turn.
#
# Genuine mid-generation streaming (deltas arriving as the model
# generates them) is not achievable from lex-loom alone: lex-llm's
# run_steps eagerly drains the whole provider response per tool-calling
# round before run_loop ever returns an Iter[Step] (confirmed by reading
# lex-llm/src/agent.lex directly) — by the time src/agent/runner.lex's
# step() sees anything, the live moment has already passed. What IS
# achievable, and what this module does: record the AG-UI event sequence
# for a node's already-finished turn, and replay it as one SSE burst —
# real events (RUN_STARTED, TEXT_MESSAGE_*, TOOL_CALL_*, RUN_FINISHED),
# just delivered right after the turn completes rather than as it
# happens. See docs/design/soft-os-aware-agents.md's AG-UI note for the
# full writeup of why this scope was chosen over the alternative
# (filing the real blocker upstream in lex-llm).
#
# `run_id` is the same id runner.lex's own trace.record calls already use
# to correlate one step() call's events — reusing it here means no new
# id-generation scheme, and a human reading the traces table alongside
# this table sees the same key.

import "std.str" as str

import "std.list" as list

import "std.iter" as iter

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-llm/src/delta" as d

import "lex-ag-ui/src/bridge" as agui_bridge

import "lex-ag-ui/src/event" as agui_event

# Encode a node's finished LLM turn as AG-UI events and persist them,
# keyed by run_id. sprint_id is the caller's cost_owner (a real sprint_id
# for an in-sprint node, whatever else a between-iteration caller passes
# otherwise — harmless either way, this table is purely additive replay
# data, nothing reads it as authoritative).
fn persist_agui_events(db :: conn.ConnDb, run_id :: Str, sprint_id :: Str, agent_id :: Str, steps :: List[d.Step]) -> [sql, fs_write, time] Unit {
  let events := iter.to_list(agui_bridge.from_llm_steps(iter.from_list(steps), sprint_id, run_id))
  let events_json := str.concat("[", str.concat(str.join(list.map(events, agui_event.encode), ","), "]"))
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO node_agui_events (run_id, sprint_id, agent_id, events_json, created_at) VALUES (?, ?, ?, ?, ?)", params: [PStr(run_id), PStr(sprint_id), PStr(agent_id), PStr(events_json), PStr(now)] }, db.dialect)
  let __r := sql.exec(db.handle, qd.sql, qd.params)
  ()
}

type AguiReplay = { run_id :: Str, sprint_id :: Str, agent_id :: Str, events_json :: Str, created_at :: Str }

type AguiReplayRow = { run_id :: Str, sprint_id :: Str, agent_id :: Str, events_json :: Str, created_at :: Str }

fn row_to_replay(r :: AguiReplayRow) -> AguiReplay {
  { run_id: r.run_id, sprint_id: r.sprint_id, agent_id: r.agent_id, events_json: r.events_json, created_at: r.created_at }
}

# The most recently recorded turn for a sprint — the "what just happened"
# view a human operator watching a sprint would want.
fn load_latest_agui_events(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[AguiReplay] {
  let qd := ormq.for_dialect({ sql: "SELECT run_id, sprint_id, agent_id, events_json, created_at FROM node_agui_events WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[AguiReplayRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(row_to_replay(r)),
    },
  }
}

