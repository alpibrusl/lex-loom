# test_cx_backlog.lex — #442: cx closes the loop. The goals cx proposes from
# real support items (a fenced json block at the end of its output) become
# pending backlog items, by the graph's ground-truth role, once each.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/transport" as tr

import "../src/company" as company

import "../src/company_runner" as company_runner

fn fresh_db() -> [sql, fs_write, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-cxb-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

fn cx_graph() -> Str {
  "{\"id\":\"s\",\"phase\":\"Implementation\",\"nodes\":[{\"id\":\"demo-1\",\"role\":\"demo\",\"gate\":\"spec len-gt 50\"},{\"id\":\"support-desk\",\"role\":\"cx\",\"gate\":\"spec judge x\"}],\"edges\":[]}"
}

fn cx_output() -> Str {
  "DRAFT -- prepared by an AI agent.\n\n## Replies\n- item 12: ...\n\n## Triage\n- export (2): items 12, 15\n\n## Backlog proposals\n```json\n{\"backlog\":[{\"goal\":\"Add CSV export of submissions\",\"theme\":\"export\"},{\"goal\":\"Add CSV export of submissions\",\"theme\":\"export\"},{\"goal\":\"Show a delivery status per submission\",\"theme\":\"delivery\"}]}\n```\n"
}

fn seed(db :: conn.ConnDb, sprint_id :: Str, graph :: Str, node_id :: Str, content :: Str) -> [sql, fs_write, fs_read, time, random, crypto, vcs] Result[Unit, Str] {
  match tr.save_sprint_graph(db, sprint_id, "Implementation", graph) {
    Err(m) => Err(str.concat("save graph: ", m)),
    Ok(_) => match tr.artifact_put(db, sprint_id, node_id, content) {
      Err(m) => Err(str.concat("artifact_put: ", m)),
      Ok(_) => Ok(()),
    },
  }
}

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn test_proposals_read_by_role_not_name() -> [sql, fs_write, fs_read, time, random, crypto, vcs] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := str.concat("s-", crypto.random_str_hex(6))
      match seed(db, sid, cx_graph(), "support-desk", cx_output()) {
        Err(m) => Err(m),
        Ok(_) => {
          let goals := company.cx_backlog_proposals(db, sid)
          match check("cx artifact found by graph role although the node is named support-desk", list.len(goals) == 3) {
            Err(e) => Err(e),
            Ok(_) => check("first goal is the first proposed", match list.head(goals) {
              Some(g) => g == "Add CSV export of submissions",
              None => false,
            }),
          }
        },
      }
    },
  }
}

fn test_no_cx_node_means_nothing() -> [sql, fs_write, fs_read, time, random, crypto, vcs] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := str.concat("s-", crypto.random_str_hex(6))
      let graph := "{\"id\":\"s\",\"phase\":\"Implementation\",\"nodes\":[{\"id\":\"cx-looking-name\",\"role\":\"demo\",\"gate\":\"spec len-gt 50\"}],\"edges\":[]}"
      match seed(db, sid, graph, "cx-looking-name", cx_output()) {
        Err(m) => Err(m),
        Ok(_) => check("a demo node named like cx proposes nothing", list.is_empty(company.cx_backlog_proposals(db, sid))),
      }
    },
  }
}

fn test_proposals_join_backlog_once() -> [sql, fs_write, fs_read, time, random, crypto, vcs, io] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := str.concat("s-", crypto.random_str_hex(6))
      let cid := str.concat("c-", crypto.random_str_hex(6))
      match seed(db, sid, cx_graph(), "support-desk", cx_output()) {
        Err(m) => Err(m),
        Ok(_) => {
          let __pre := company.append_backlog(db, cid, "Show a delivery status per submission")
          let added := company_runner.propose_from_cx(db, cid, sid, 3)
          let again := company_runner.propose_from_cx(db, cid, sid, 4)
          let items := company.load_backlog(db, cid)
          match check("one new goal added: the duplicate in the output and the one already queued are skipped", added == 1) {
            Err(e) => Err(e),
            Ok(_) => match check("a second pass adds nothing", again == 0) {
              Err(e) => Err(e),
              Ok(_) => match check("backlog holds exactly the two distinct goals", list.len(items) == 2) {
                Err(e) => Err(e),
                Ok(_) => check("the trail names cx as the source", tr.count_trail_events(db, cid, "backlog_added") == 1),
              },
            },
          }
        },
      }
    },
  }
}

fn suite() -> [sql, fs_write, fs_read, time, random, crypto, vcs, io] List[Result[Unit, Str]] {
  [test_proposals_read_by_role_not_name(), test_no_cx_node_means_nothing(), test_proposals_join_backlog_once()]
}

fn run_all() -> [io, random, sql, fs_read, fs_write, time, crypto, vcs] Unit {
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
    io.print("ok   3 cx backlog tests")
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

