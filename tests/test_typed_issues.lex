# test_typed_issues.lex — #521: a lex company's backlog as typed issues.
#
# Pure halves (shape rule, proposal parsing) are pinned by `examples {}` in
# src/issues.lex and evaluated on every `lex check`. This file covers the
# seams that touch the toolchain and the backlog:
#   1. the untyped fallback: with no LOOM_WORKSPACE (tests, ad-hoc runs) a cx
#      proposal still queues, untyped, with the reason on the trail;
#   2. the typed loop against a real store: create → publish with
#      --intent-issue → verify, verdict read back — needs `lex issue` on PATH
#      (lex-lang ≥ 0.11.50), otherwise skipped honestly, never faked.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.crypto" as crypto

import "std.process" as proc

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/transport" as tr

import "../src/company" as company

import "../src/company_runner" as company_runner

import "../src/issues" as issues

fn fresh_db() -> [sql, fs_write, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-ti-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
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

fn cx_graph() -> Str {
  "{\"id\":\"s\",\"phase\":\"Implementation\",\"nodes\":[{\"id\":\"support-desk\",\"role\":\"cx\",\"gate\":\"spec judge x\"}],\"edges\":[]}"
}

# A cx artifact with one typed bug and one plain feature request.
fn cx_output() -> Str {
  "DRAFT -- prepared by an AI agent.\n\n## Backlog proposals\n```json\n{\"backlog\":[{\"goal\":\"Reject empty submissions\",\"theme\":\"validation\",\"kind\":\"bug\",\"example\":\"submit(\\\"\\\") => Err(\\\"empty\\\")\"},{\"goal\":\"Add CSV export\",\"theme\":\"export\"}]}\n```\n"
}

# The toolchain on PATH knows `lex issue` (lex-lang ≥ 0.11.48; the JSON
# output and --intent-issue this binding reads are ≥ 0.11.50).
fn toolchain_has_issues() -> [proc] Bool {
  match proc.run("bash", ["-c", "${LEX:-lex} issue 2>&1; ${LEX:-lex} publish 2>&1"]) {
    Err(_) => false,
    Ok(r) => {
      let out := str.concat(r.stdout, r.stderr)
      str.contains(out, "usage: lex issue") and str.contains(out, "--intent-issue")
    },
  }
}

fn tmp_dir(tag :: Str) -> [random, crypto] Str {
  str.join(["/tmp/loom-ti-", tag, "-", crypto.random_str_hex(6)], "")
}

# 1. Untyped fallback (no LOOM_WORKSPACE in a test process): the proposals
# still join the backlog with issue_id "" and the trail says why. This is the
# negative control that a typing failure never drops a user's request.
fn test_untyped_fallback_queues_the_goal() -> [sql, fs_write, fs_read, time, random, crypto, vcs, io, env, proc] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid := str.concat("s-", crypto.random_str_hex(6))
      let cid := str.concat("c-", crypto.random_str_hex(6))
      match tr.save_sprint_graph(db, sid, "Implementation", cx_graph()) {
        Err(m) => Err(str.concat("save graph: ", m)),
        Ok(_) => match tr.artifact_put(db, sid, "support-desk", cx_output()) {
          Err(m) => Err(str.concat("artifact_put: ", m)),
          Ok(_) => {
            let typed := company.cx_typed_proposals(db, sid)
            let added := company_runner.propose_from_cx(db, cid, sid, 2)
            let items := company.load_backlog(db, cid)
            let untyped := list.filter(items, fn (it :: company.BacklogItem) -> Bool {
              str.is_empty(it.issue_id)
            })
            match check("both proposals parsed typed (bug with example, plain feature)", list.len(typed) == 2 and match list.head(typed) {
              Some(p) => issues.shape_for(p) == "failing_example",
              None => false,
            }) {
              Err(e) => Err(e),
              Ok(_) => match check("both goals queued", added == 2 and list.len(items) == 2) {
                Err(e) => Err(e),
                Ok(_) => match check("queued untyped without a workspace (issue_id empty)", list.len(untyped) == 2) {
                  Err(e) => Err(e),
                  Ok(_) => check("the trail records why typing was skipped, once per goal", tr.count_trail_events(db, cid, "issue_create_failed") == 2 and tr.count_trail_events(db, cid, "backlog_added") == 2),
                },
              },
            }
          },
        },
      }
    },
  }
}

# 2. The typed loop against a real store. Skips (Ok, printed) when the
# toolchain on PATH predates `lex issue` — CI pins one that has it.
fn test_create_realize_verify_round_trip() -> [io, proc, random, crypto, fs_write] Result[Unit, Str] {
  if not toolchain_has_issues() {
    let __p := io.print("skip: toolchain on PATH has no `lex issue` / --intent-issue (need lex-lang >= 0.11.50)")
    Ok(())
  } else {
    let store := tmp_dir("store")
    let work := tmp_dir("work")
    let __mk := proc.run("bash", ["-c", str.join(["mkdir -p ", work, " && printf 'fn gcd(a :: Int, b :: Int) -> Int { if b == 0 { a } else { gcd(b, a %% b) } }\\n' > ", work, "/main.lex && printf 'fn t() -> Int { 1 }\\n' > ", work, "/main_test.lex"], "")])
    let feature := { goal: "add gcd", theme: "math", kind: "feature", example: "", api: ["gcd:(a :: Int, b :: Int) -> Int:added"] }
    let bug := { goal: "gcd(0,0) is 0", theme: "math", kind: "bug", example: "gcd(0, 0) => 1", api: [] }
    match issues.create_issue(store, "co", feature) {
      Err(m) => Err(str.concat("create typed_delta: ", m)),
      Ok(fid) => match issues.create_issue(store, "co", bug) {
        Err(m) => Err(str.concat("create failing_example: ", m)),
        Ok(bid) => match issues.primary_source(work) {
          Err(m) => Err(str.concat("primary_source: ", m)),
          Ok((src, modules)) => match check("primary source is main.lex, tests excluded", str.ends_with(src, "/main.lex") and modules == 1) {
            Err(e) => Err(e),
            Ok(_) => match issues.realize(store, fid, "add gcd", "sprint-1", src) {
              Err(m) => Err(str.concat("realize: ", m)),
              Ok(head) => {
                let v_feature := issues.verify(store, fid)
                let v_bug := issues.verify(store, bid)
                let same := match issues.create_issue(store, "co", feature) {
                  Ok(again) => again == fid,
                  Err(_) => false,
                }
                match check("publish returned a head op", str.len(head) == 64) {
                  Err(e) => Err(e),
                  Ok(_) => match check(str.concat("typed_delta verified at the head: ", issues.verdict_detail(v_feature)), issues.verdict_name(v_feature) == "verified") {
                    Err(e) => Err(e),
                    Ok(_) => match check(str.concat("wrong expected value fails (the example RAN): ", issues.verdict_detail(v_bug)), issues.verdict_name(v_bug) == "failed" and str.contains(issues.verdict_detail(v_bug), "expected")) {
                      Err(e) => Err(e),
                      Ok(_) => check("re-creating the same proposal yields the same content-addressed id", same),
                    },
                  },
                }
              },
            },
          },
        },
      },
    }
  }
}

fn suite() -> [sql, fs_write, fs_read, time, random, crypto, vcs, io, env, proc] List[Result[Unit, Str]] {
  [test_untyped_fallback_queues_the_goal(), test_create_realize_verify_round_trip()]
}

fn run_all() -> [io, random, sql, fs_read, fs_write, time, crypto, vcs, env, proc] Unit {
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
    io.print("ok   2 typed issue tests")
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

