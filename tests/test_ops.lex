# test_ops.lex — P1b op_call telemetry (#65): wrapped tool handlers append to
# the per-run ops file, flush_op_calls replays it into `traces`, and
# verify_operations re-derives per-operation authority from those rows.
# No LLM required — the whole op_call → verifier path runs offline.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.sql" as sql

import "std.process" as proc

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/agent/runner" as runner

import "../src/verify" as verify

type CountRow = { n :: Int }

type DataRow = { data_json :: Str }

fn make_ok_tool(nm :: Str) -> t.Tool {
  t.define(nm, "always succeeds", { title: "TestTool", description: "test tool args", fields: [s.required_str("x", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(JObj([("ok", JStr("true"))]))
  })
}

fn make_err_tool(nm :: Str) -> t.Tool {
  t.define(nm, "always fails", { title: "TestTool", description: "test tool args", fields: [s.required_str("x", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Err(e.single("", "boom", "tool failed"))
  })
}

fn call_arg() -> jv.Json {
  JObj([("x", JStr("1"))])
}

# "sqlite::memory:" is one shared store per process, not one per open — so
# every test uses its own agent id to keep its trace rows disjoint.
fn fresh_db() -> [sql, fs_write, time] Result[conn.ConnDb, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

fn count_op_calls(db :: conn.ConnDb, agent :: Str) -> [sql] Int {
  let q := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", agent, "' AND event_kind='op_call'"], "")
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => 0 - 1,
    Ok(rs) => match list.head(rs) {
      None => 0 - 1,
      Some(r) => r.n,
    },
  }
}

fn payloads(db :: conn.ConnDb, agent :: Str) -> [sql] Str {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", agent, "' AND event_kind='op_call'"], "")
  let rows :: Result[List[DataRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => "",
    Ok(rs) => str.join(list.map(rs, fn (r :: DataRow) -> Str {
      r.data_json
    }), "\n"),
  }
}

fn insert_grant(db :: conn.ConnDb, sprint :: Str, agent :: Str, role :: Str, tools :: Str) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', '", sprint, "', 'op_grant', '{\"node\":\"n1\",\"role\":\"", role, "\",\"agent\":\"", agent, "\",\"tools\":\"", tools, "\"}', 't1')"], "")
  let __r := sql.exec(db.handle, q, [])
  ()
}

# Invoke a wrapped tool's handler `times` times.
fn invoke_n(tl :: t.Tool, times :: Int) -> [net, io, proc] Unit {
  if times <= 0 {
    ()
  } else {
    let h := tl.execute
    let __r := h(call_arg())
    invoke_n(tl, times - 1)
  }
}

# Wrapped handlers record each executed invocation; flush replays them into
# traces with the invoking agent id and the tool's ok/err outcome.
fn test_wrap_and_flush() -> [net, io, proc, sql, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let run_id := "testops-flush"
      let path := runner.ops_file(run_id)
      let __rm := proc.run("bash", ["-c", str.concat("rm -f ", path)])
      let ok_tool := runner.wrap_tool(path, make_ok_tool("lex_check"))
      let err_tool := runner.wrap_tool(path, make_err_tool("lex_run"))
      let __c1 := invoke_n(ok_tool, 2)
      let __c2 := invoke_n(err_tool, 1)
      let __f := runner.flush_op_calls(db, run_id, "flush-qa")
      let n := count_op_calls(db, "flush-qa")
      if n == 3 {
        let ps := payloads(db, "flush-qa")
        if str.contains(ps, "\"tool\":\"lex_check\",\"ok\":true") {
          if str.contains(ps, "\"tool\":\"lex_run\",\"ok\":false") {
            Ok(())
          } else {
            Err(str.concat("missing err payload for lex_run: ", ps))
          }
        } else {
          Err(str.concat("missing ok payload for lex_check: ", ps))
        }
      } else {
        Err(str.concat("expected 3 op_call rows, got ", int.to_str(n)))
      }
    },
  }
}

# The wrapped tool keeps its name — op_grant emission (orchestrator) and the
# roster both read tl.name, so wrapping must not change the granted tool list.
fn test_wrap_preserves_name() -> Result[Unit, Str] {
  let tl := runner.wrap_tool("/tmp/loom-ops-unused.log", make_ok_tool("lex_check"))
  if tl.name == "lex_check" {
    Ok(())
  } else {
    Err(str.concat("wrapped tool renamed to ", tl.name))
  }
}

# End-to-end into the verifier: ops within the role's policy verify clean.
fn test_verify_operations_within_grant() -> [net, io, proc, sql, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let run_id := "testops-clean"
      let path := runner.ops_file(run_id)
      let __rm := proc.run("bash", ["-c", str.concat("rm -f ", path)])
      let __c1 := invoke_n(runner.wrap_tool(path, make_ok_tool("lex_check")), 1)
      let __c2 := invoke_n(runner.wrap_tool(path, make_ok_tool("lex_run")), 1)
      let __f := runner.flush_op_calls(db, run_id, "clean-qa")
      let __g := insert_grant(db, "s1", "clean-qa", "qa", "lex_check,lex_run")
      let r := verify.verify_operations(db, "s1")
      if r.ops == 2 {
        if r.exceeded == 0 {
          if r.verified {
            Ok(())
          } else {
            Err("clean run not verified")
          }
        } else {
          Err(str.concat("expected 0 exceeded, got ", int.to_str(r.exceeded)))
        }
      } else {
        Err(str.concat("expected 2 ops, got ", int.to_str(r.ops)))
      }
    },
  }
}

# A tool outside the role's canonical policy that actually executes is counted
# as exceeded — the trail proves the excess operation, not just the grant.
fn test_verify_operations_exceeded() -> [net, io, proc, sql, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let run_id := "testops-rogue"
      let path := runner.ops_file(run_id)
      let __rm := proc.run("bash", ["-c", str.concat("rm -f ", path)])
      let __c1 := invoke_n(runner.wrap_tool(path, make_ok_tool("payments_transfer")), 1)
      let __f := runner.flush_op_calls(db, run_id, "rogue-agent")
      let __g := insert_grant(db, "s2", "rogue-agent", "qa", "lex_check")
      let r := verify.verify_operations(db, "s2")
      if r.exceeded == 1 {
        if r.verified {
          Err("exceeded run must not verify")
        } else {
          Ok(())
        }
      } else {
        Err(str.concat("expected 1 exceeded, got ", int.to_str(r.exceeded)))
      }
    },
  }
}

# flush removes the ops file: a second flush finds nothing and adds no rows.
fn test_flush_is_drained() -> [net, io, proc, sql, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let run_id := "testops-drain"
      let path := runner.ops_file(run_id)
      let __rm := proc.run("bash", ["-c", str.concat("rm -f ", path)])
      let __c1 := invoke_n(runner.wrap_tool(path, make_ok_tool("lex_check")), 1)
      let __f1 := runner.flush_op_calls(db, run_id, "drain-qa")
      let __f2 := runner.flush_op_calls(db, run_id, "drain-qa")
      let n := count_op_calls(db, "drain-qa")
      if n == 1 {
        Ok(())
      } else {
        Err(str.concat("expected 1 op_call after double flush, got ", int.to_str(n)))
      }
    },
  }
}

fn suite() -> [net, io, proc, sql, fs_write, time] List[Result[Unit, Str]] {
  [test_wrap_preserves_name(), test_wrap_and_flush(), test_verify_operations_within_grant(), test_verify_operations_exceeded(), test_flush_is_drained()]
}

fn run_all() -> [net, io, proc, sql, fs_write, time] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r {
      Ok(_) => n,
      Err(m) => {
        let __p := io.print(str.concat("test_ops FAIL: ", m))
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

