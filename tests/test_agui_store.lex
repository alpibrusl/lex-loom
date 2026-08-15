# test_agui_store.lex — regression coverage for the AG-UI replay store
# (src/agui_store.lex): persist_agui_events / load_latest_agui_events.
#
# No real LLM call needed — a hand-built List[d.Step] exercises the exact
# same code path runner.lex's LLM branch calls with real data.

import "std.list" as list

import "std.str" as str

import "std.crypto" as crypto

import "std.io" as io

import "lex-orm/src/connection" as conn

import "std.fs" as fs

import "lex-llm/src/delta" as d

import "lex-llm/src/message" as msg

import "../src/migrate" as migrate

import "../src/agui_store" as agui_store

fn fresh_db() -> [sql, fs_write, time, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

# A realistic step sequence: lex-llm delivers text via StepDelta(TextChunk)
# deltas, then a trailing StepDone carrying the final assembled Message
# (which lex-ag-ui's bridge treats purely as a terminator -- the AG-UI
# TEXT_MESSAGE_CONTENT events come from the TextChunk deltas, not StepDone;
# confirmed against lex-ag-ui/src/bridge.lex's fold_step).
fn sample_steps() -> List[d.Step] {
  [StepDelta(TextChunk("hello from a sprint node")), StepDone(AssistantMsg("hello from a sprint node", []))]
}

fn test_persist_then_load_round_trips() -> [env, sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let __p := agui_store.persist_agui_events(db, "run-1", "sprint-1", "loom-build", sample_steps())
      match agui_store.load_latest_agui_events(db, "sprint-1") {
        None => Err("expected a replay row after persisting"),
        Some(r) => if r.run_id == "run-1" {
          if r.agent_id == "loom-build" {
            if str.contains(r.events_json, "RUN_STARTED") {
              if str.contains(r.events_json, "RUN_FINISHED") {
                if str.contains(r.events_json, "hello from a sprint node") {
                  Ok(())
                } else {
                  Err(str.concat("expected the text content in the stored events, got ", r.events_json))
                }
              } else {
                Err(str.concat("expected a RUN_FINISHED event, got ", r.events_json))
              }
            } else {
              Err(str.concat("expected a RUN_STARTED event, got ", r.events_json))
            }
          } else {
            Err(str.concat("expected agent_id=loom-build, got ", r.agent_id))
          }
        } else {
          Err(str.concat("expected run_id=run-1, got ", r.run_id))
        },
      }
    },
  }
}

fn test_load_latest_returns_none_for_unknown_sprint() -> [env, sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => match agui_store.load_latest_agui_events(db, "no-such-sprint") {
      None => Ok(()),
      Some(_) => Err("expected None for a sprint with no recorded events"),
    },
  }
}

fn test_load_latest_prefers_the_most_recent_row() -> [env, sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let __p1 := agui_store.persist_agui_events(db, "run-1", "sprint-1", "loom-build", sample_steps())
      let __p2 := agui_store.persist_agui_events(db, "run-2", "sprint-1", "loom-qa", sample_steps())
      match agui_store.load_latest_agui_events(db, "sprint-1") {
        None => Err("expected a replay row"),
        Some(r) => if r.run_id == "run-2" {
          Ok(())
        } else {
          Err(str.concat("expected the second (later) run to win, got ", r.run_id))
        },
      }
    },
  }
}

fn suite() -> [env, sql, fs_read, fs_write, time, random] List[Result[Unit, Str]] {
  [test_persist_then_load_round_trips(), test_load_latest_returns_none_for_unknown_sprint(), test_load_latest_prefers_the_most_recent_row()]
}

fn run_all() -> [io, env, sql, fs_read, fs_write, time, random] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r {
      Ok(_) => n,
      Err(m) => {
        let __p := io.print(str.concat("test_agui_store FAIL: ", m))
        n + 1
      },
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

