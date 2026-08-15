# test_events.lex — HB2 (lex-loom#214): the append-only event ledger and the
# event-kind wake grammar.
#
# All offline (no LLM, no network):
#
#   1. VOCABULARY — an unknown event kind is refused, never stored; known
#      kinds append.
#   2. GRAMMAR — wake_when is a disjunction of atoms; event kinds are
#      well-formed atoms that are FALSE against the pure ctx (only the
#      scheduler's DB check can make them fire); existing predicates still
#      evaluate exactly as before.
#   3. CONSUMPTION — the mark is one-shot: a second consume touches nothing,
#      and the ledger replays as history (append-only by construction).
#   4. OPT-IN — has_wake_eligible fires only for kinds the manifest declared,
#      and never for consumed events.
#   5. WRITERS — add_board_note projects a board_note event (index only,
#      never the note text); the operate sync bridges event a moved revenue
#      reading and an open incident exactly once each.
#   6. SCHEDULER — round trip on a real DB: a dormant company classifies
#      dormant, gains a board note, classifies event_wake.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.sql" as sql

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/events" as events

import "../src/company" as company

import "../src/scheduler" as scheduler

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-hb2-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn ctx_with(idx :: Int, verdict :: Str) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: "", accepted_count: 0, bounced_count: 0, spend_cents: 0 }
}

# ── 1. Closed vocabulary ─────────────────────────────────────────────────────
fn test_vocabulary() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb2-vocab-", crypto.random_str_hex(6))
      match check("unknown kind refused", match events.record(db, cid, "rm_rf_slash", "test", "{}") {
        Err(m) => str.contains(m, "unknown event kind"),
        Ok(_) => false,
      }) {
        Err(e) => Err(e),
        Ok(_) => match check("nothing stored for the refused kind", list.is_empty(events.unconsumed(db, cid))) {
          Err(e) => Err(e),
          Ok(_) => match events.record(db, cid, "webhook", "test", "{\"ref\":\"x\"}") {
            Err(m) => Err(str.concat("known kind refused: ", m)),
            Ok(_) => check("known kind appended", list.len(events.unconsumed(db, cid)) == 1),
          },
        },
      }
    },
  }
}

# ── 2. The wake grammar ──────────────────────────────────────────────────────
fn test_grammar() -> Result[Unit, Str] {
  match check("disjunction of ctx atoms fires on either side", company.eval_condition("iter ge 5 or verdict-failed", ctx_with(2, "failed"))) {
    Err(e) => Err(e),
    Ok(_) => match check("disjunction false when no atom holds", not company.eval_condition("iter ge 5 or verdict-failed", ctx_with(2, "passed"))) {
      Err(e) => Err(e),
      Ok(_) => match check("event atom is never true against pure ctx", not company.eval_condition("board_note", ctx_with(2, "failed"))) {
        Err(e) => Err(e),
        Ok(_) => match check("event kinds are well-formed atoms", company.is_well_formed_condition("board_note or incident")) {
          Err(e) => Err(e),
          Ok(_) => match check("mixed predicate + event kind is well-formed", company.is_well_formed_condition("verdict-failed or support_item")) {
            Err(e) => Err(e),
            Ok(_) => match check("a typo'd atom is still rejected", not company.is_well_formed_condition("frobnicate or board_note")) {
              Err(e) => Err(e),
              Ok(_) => check("single-atom conditions behave exactly as before", company.eval_condition("verdict-failed", ctx_with(1, "failed")) and not company.eval_condition("never", ctx_with(1, "failed"))),
            },
          },
        },
      },
    },
  }
}

# ── 3. One-shot consumption + replayable history ─────────────────────────────
fn test_consumption() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb2-consume-", crypto.random_str_hex(6))
      let __e1 := events.record_once(db, "ev-1", cid, "board_note", "board", "{\"note_idx\":1}")
      let __e2 := events.record_once(db, "ev-2", cid, "webhook", "ci", "{\"ref\":\"build-42\"}")
      match check("two pending before the run", list.len(events.unconsumed(db, cid)) == 2) {
        Err(e) => Err(e),
        Ok(_) => match check("the run consumes both", events.consume_all(db, cid, "scheduler:event_wake:iter-2") == 2) {
          Err(e) => Err(e),
          Ok(_) => match check("a second consume touches nothing", events.consume_all(db, cid, "someone-else") == 0) {
            Err(e) => Err(e),
            Ok(_) => {
              let __e3 := events.record_once(db, "ev-3", cid, "incident", "operate", "{}")
              let hs := events.history(db, cid)
              match check("ledger keeps appending after consumption", list.len(events.unconsumed(db, cid)) == 1 and list.len(hs) == 3) {
                Err(e) => Err(e),
                Ok(_) => match check("history attributes the consuming run (first mark is permanent)", list.fold(hs, false, fn (found :: Bool, h :: Str) -> Bool {
                  found or str.contains(h, "consumed by scheduler:event_wake:iter-2")
                }) and not list.fold(hs, false, fn (found :: Bool, h :: Str) -> Bool {
                  found or str.contains(h, "someone-else")
                })) {
                  Err(e) => Err(e),
                  Ok(_) => check("dedupe by id: re-recording an existing fact writes nothing", match events.record_once(db, "ev-3", cid, "incident", "operate", "{}") {
                    Ok(_) => list.len(events.history(db, cid)) == 3,
                    Err(_) => false,
                  }),
                },
              }
            },
          },
        },
      }
    },
  }
}

# ── 4. Opt-in wake eligibility ───────────────────────────────────────────────
fn test_opt_in() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb2-optin-", crypto.random_str_hex(6))
      let __e := events.record_once(db, "ev-s1", cid, "support_item", "cx_a2a", "{\"item\":\"t1\"}")
      match check("declared kind fires", events.has_wake_eligible(db, cid, "board_note or support_item")) {
        Err(e) => Err(e),
        Ok(_) => match check("undeclared kind does not fire", not events.has_wake_eligible(db, cid, "board_note or incident")) {
          Err(e) => Err(e),
          Ok(_) => match check("a wake_when with no event kinds never fires", not events.has_wake_eligible(db, cid, "verdict-failed")) {
            Err(e) => Err(e),
            Ok(_) => {
              let __c := events.consume_all(db, cid, "run-1")
              check("consumed events do not fire", not events.has_wake_eligible(db, cid, "support_item"))
            },
          },
        },
      }
    },
  }
}

# ── 5. Writers: board-note ingestion + operate sync bridges ──────────────────
fn test_writers() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb2-writers-", crypto.random_str_hex(6))
      let __n := company.add_board_note(db, cid, "board: please investigate churn")
      let note_ev := list.filter(events.unconsumed(db, cid), fn (e :: events.Event) -> Bool {
        e.kind == "board_note"
      })
      match check("add_board_note projects a board_note event", list.len(note_ev) == 1) {
        Err(e) => Err(e),
        Ok(_) => match check("the event carries the note's index, never its text", list.fold(note_ev, true, fn (ok :: Bool, e :: events.Event) -> Bool {
          ok and str.contains(e.body_json, "note_idx") and not str.contains(e.body_json, "churn")
        })) {
          Err(e) => Err(e),
          Ok(_) => {
            let __r1 := company.record_operate_signal(db, cid, 1, "revenue_cents", "{\"revenue_cents\": 100}")
            let __s1 := events.sync_revenue_events(db, cid)
            let __s1b := events.sync_revenue_events(db, cid)
            let rev_ev := list.filter(events.unconsumed(db, cid), fn (e :: events.Event) -> Bool {
              e.kind == "operate_signal"
            })
            match check("a moved revenue reading events exactly once", list.len(rev_ev) == 1) {
              Err(e) => Err(e),
              Ok(_) => {
                let iq := ormq.for_dialect({ sql: "INSERT INTO operate_incidents (id, company_id, opened_at, closed_at, status, symptoms_json, budget_spent_milli, budget_cap_milli, root_cause) VALUES ('inc-1', ?, '2026-01-01T00:00:00', '', 'open', '[]', 0, 0, '')", params: [PStr(cid)] }, db.dialect)
                let __iq := sql.exec(db.handle, iq.sql, iq.params)
                let __s2 := events.sync_incident_events(db, cid)
                let __s2b := events.sync_incident_events(db, cid)
                let inc_ev := list.filter(events.unconsumed(db, cid), fn (e :: events.Event) -> Bool {
                  e.kind == "incident"
                })
                check("an open incident events exactly once", list.len(inc_ev) == 1)
              },
            }
          },
        },
      }
    },
  }
}

# ── 6. Scheduler round trip: dormant → board note → event_wake ───────────────
fn test_scheduler_event_wake() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb2-sched-", crypto.random_str_hex(6))
      let cfg :: company.CompanyCfg := { id: cid, goal: "g", model: "m", max_iterations: 9, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "board_note or support_item", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let __s := company.save_stage(db, cid, Maintenance)
      let __it := company.record_iteration(db, { company_id: cid, idx: 1, sprint_id: str.concat(cid, "/iter-1"), parent_sprint_id: "", status: "running", goal: "g" })
      let __fin := company.finish_iteration(db, cid, 1, "success")
      match scheduler.classify_company(db, cid) {
        None => Err("classify_company lost the company"),
        Some(p1) => match p1 {
          (_, d1) => match check("no event yet: dormant", d1.action == "skip" and d1.reason == "dormant") {
            Err(e) => Err(e),
            Ok(_) => {
              let __n := company.add_board_note(db, cid, "wake up, board here")
              match scheduler.classify_company(db, cid) {
                None => Err("classify_company lost the company after note"),
                Some(p2) => match p2 {
                  (_, d2) => check("board note event wakes the dormant company", d2.action == "run" and d2.reason == "event_wake"),
                },
              }
            },
          },
        },
      }
    },
  }
}

fn suite() -> [io, sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_vocabulary(), test_grammar(), test_consumption(), test_opt_in(), test_writers(), test_scheduler_event_wake()]
}

fn run_all() -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
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

