# test_dag_view.lex — regression coverage for the sprint DAG Mermaid renderer.
#
# Covers: node status read from traces (accepted/denied/pending, with a later
# trace event overriding an earlier one for the same node — the retry case),
# and expand-node sub-sprints rendered as a nested Mermaid subgraph. Verified
# live once against a real completed sprint before writing these (see the
# session notes); these tests pin that behavior down as fast, offline checks.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.sql" as sql

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "std.fs" as fs

import "../src/migrate" as migrate

import "../src/dag_view" as dagv

# "sqlite::memory:" is shared across separate `lex run` invocations, not just
# within one process (confirmed directly while writing these tests: a fixed
# row id like "g1" collided with a leftover row from an earlier run of this
# same file with "UNIQUE constraint failed"). Every row id/sprint id below
# gets a random suffix via uniq() so repeat runs never collide.
fn fresh_db() -> [sql, fs_write] Result[conn.ConnDb, Str] {
  let __clean :: Result[Unit, Str] := fs.remove("sqlite::memory:")
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

fn uniq(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

fn exec(db :: conn.ConnDb, s :: Str) -> [sql, fs_write] Unit {
  let __r := sql.exec(db.handle, s, [])
  ()
}

fn save_graph(db :: conn.ConnDb, id :: Str, sprint_id :: Str, graph_json :: Str, created_at :: Str) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT INTO sprint_graphs (id, sprint_id, phase, graph_json, created_at) VALUES ('", id, "', '", sprint_id, "', 'Implementation', '", str.replace(graph_json, "'", "''"), "', '", created_at, "')"], "")
  let __e := exec(db, q)
  ()
}

fn trace(db :: conn.ConnDb, sprint_id :: Str, kind :: Str, node_id :: Str) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', '", sprint_id, "', '", kind, "', '{\"node\":\"", node_id, "\"}', 't')"], "")
  let __e := exec(db, q)
  ()
}

fn simple_graph(id :: Str) -> Str {
  str.join(["{\"id\":\"", id, "\",\"phase\":\"Implementation\",\"nodes\":[", "{\"id\":\"a\",\"role\":\"build\",\"gate\":\"spec compiles\",\"expand\":null,\"activate_when\":\"\"},", "{\"id\":\"b\",\"role\":\"qa\",\"gate\":\"spec json-verdict-pass\",\"expand\":null,\"activate_when\":\"\"}", "],\"edges\":[{\"from\":\"a\",\"to\":\"b\",\"handoff\":\"schema {}\"}]}"], "")
}

fn expand_graph(id :: Str, child_task :: Str) -> Str {
  str.join(["{\"id\":\"", id, "\",\"phase\":\"Implementation\",\"nodes\":[", "{\"id\":\"a\",\"role\":\"build\",\"gate\":\"spec compiles\",\"expand\":null,\"activate_when\":\"\"},", "{\"id\":\"c\",\"role\":\"build\",\"gate\":\"spec json\",\"expand\":\"", child_task, "\",\"activate_when\":\"\"}", "],\"edges\":[{\"from\":\"a\",\"to\":\"c\",\"handoff\":\"schema {}\"}]}"], "")
}

fn test_renders_accepted_node() -> [random, sql, fs_read, fs_write] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := uniq("s-accept")
      let __g := save_graph(db, uniq("g"), sid, simple_graph(sid), "t1")
      let __t := trace(db, sid, "node_accepted", "a")
      let out := dagv.sprint_dag_mermaid(db, sid)
      if str.contains(out, "(done)") {
        if str.contains(out, "accepted") {
          Ok(())
        } else {
          Err(str.concat("expected 'accepted' css class in output: ", out))
        }
      } else {
        Err(str.concat("expected '(done)' label for the accepted node: ", out))
      }
    },
  }
}

fn test_later_trace_overrides_earlier_for_same_node() -> [random, sql, fs_read, fs_write] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := uniq("s-retry")
      let __g := save_graph(db, uniq("g"), sid, simple_graph(sid), "t1")
      let __t1 := trace(db, sid, "node_denied", "a")
      let __t2 := trace(db, sid, "node_accepted", "a")
      let out := dagv.sprint_dag_mermaid(db, sid)
      if str.contains(out, "(done)") {
        if str.contains(out, "(FAILED)") {
          Err(str.concat("expected only the LATER accepted status to win, still saw FAILED: ", out))
        } else {
          Ok(())
        }
      } else {
        Err(str.concat("expected the retry's final accepted status to win: ", out))
      }
    },
  }
}

fn test_pending_node_has_no_trace_yet() -> [random, sql, fs_read, fs_write] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := uniq("s-pending")
      let __g := save_graph(db, uniq("g"), sid, simple_graph(sid), "t1")
      let out := dagv.sprint_dag_mermaid(db, sid)
      if str.contains(out, "(pending)") {
        if str.contains(out, "pending") {
          Ok(())
        } else {
          Err(str.concat("expected 'pending' css class: ", out))
        }
      } else {
        Err(str.concat("expected '(pending)' for a node with no trace events: ", out))
      }
    },
  }
}

fn test_expand_node_renders_child_as_nested_subgraph() -> [random, sql, fs_read, fs_write] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := uniq("s-expand")
      let child_sid := str.join([sid, "/c"], "")
      let __gp := save_graph(db, uniq("g-parent"), sid, expand_graph(sid, "build a sub-thing"), "t1")
      let __gc := save_graph(db, uniq("g-child"), child_sid, simple_graph(child_sid), "t2")
      let __tp := trace(db, sid, "node_accepted", "c")
      let __tc1 := trace(db, child_sid, "node_accepted", "a")
      let __tc2 := trace(db, child_sid, "node_denied", "b")
      let out := dagv.sprint_dag_mermaid(db, sid)
      if str.contains(out, "subgraph") {
        if str.contains(out, "(FAILED)") {
          Ok(())
        } else {
          Err(str.concat("expected the child sprint's denied node to show FAILED: ", out))
        }
      } else {
        Err(str.concat("expected a nested 'subgraph' block for the expand node: ", out))
      }
    },
  }
}

fn suite() -> [random, sql, fs_read, fs_write] List[Result[Unit, Str]] {
  [test_renders_accepted_node(), test_later_trace_overrides_earlier_for_same_node(), test_pending_node_has_no_trace_yet(), test_expand_node_renders_child_as_nested_subgraph()]
}

fn run_all() -> [io, random, sql, fs_read, fs_write] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

