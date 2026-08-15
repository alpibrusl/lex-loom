# test_board.lex — GOV4 (lex-loom#224): the board decision surface.
#
# All offline (no LLM, no network):
#
#   1. TYPING — every governance producer's queue address classifies to its
#      decision type; sprint gates classify as "gate".
#   2. ONE QUEUE — five decision types pending on one company surface as
#      one typed, aged list with per-type counts.
#   3. ONE DECIDE PATH — resolver identity is required; a non-registered
#      identity is DENIED once a contact is registered for the oracle
#      (#165); an already-resolved decision cannot be re-decided (the
#      minutes are append-only); defer records who deferred and leaves the
#      item pending.
#   4. MINUTES — the decision history reads back typed, attributed, and
#      chronological.
#   5. SLA — the board_report header leads with pending counts and the age
#      of the oldest decision; an empty queue says "none".

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/board" as board

import "../src/company" as company

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-gov4-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

# Queue one decision of each type at the EXACT addresses the real producers
# use (GOV1 sprint gates, GOV2 budget escalations, GOV3 allocations, ORG4
# strategy, ORG5 roles).
fn queue_five(db :: conn.ConnDb, cid :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  let __g := tr.push_attention(db, str.concat(cid, "/iter-1"), "legal_review", "human legal blocking", "legal", "")
  let __b := tr.push_attention(db, str.concat(cid, "/budget"), "total", "budget envelope exhausted: total", "board", "")
  let __a := tr.push_attention(db, str.concat(cid, "/allocation"), "alloc-1", "allocation proposal", "board", "")
  let __s := tr.push_attention(db, str.concat(cid, "/ceo"), "ceo-1", "ceo proposal pivot", "board", "")
  let __r := tr.push_attention(db, str.concat(cid, "/roles"), "role-growth", "role proposal growth_hacker", "board", "")
  ()
}

# ── 1. Typing ────────────────────────────────────────────────────────────────
fn test_typing() -> Result[Unit, Str] {
  match check("allocation address types as allocation", board.decision_type("acme/allocation", "allocation proposal") == "allocation") {
    Err(e) => Err(e),
    Ok(_) => match check("ceo address types as strategy", board.decision_type("acme/ceo", "ceo proposal pivot") == "strategy") {
      Err(e) => Err(e),
      Ok(_) => match check("roles address types as role", board.decision_type("acme/roles", "role proposal x") == "role") {
        Err(e) => Err(e),
        Ok(_) => match check("budget address types as budget", board.decision_type("acme/budget", "budget envelope exhausted: total") == "budget") {
          Err(e) => Err(e),
          Ok(_) => match check("operate address types as operate", board.decision_type("acme/operate", "operate escalation dossier") == "operate") {
            Err(e) => Err(e),
            Ok(_) => check("a sprint gate types as gate", board.decision_type("acme/iter-3", "human legal blocking") == "gate"),
          },
        },
      },
    },
  }
}

# ── 2. One queue, typed and aged ─────────────────────────────────────────────
fn test_one_queue() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov4-queue-", crypto.random_str_hex(6))
      let __q := queue_five(db, cid)
      let ds := board.pending_for_company(db, cid)
      match check("five decisions pending on one surface", list.len(ds) == 5) {
        Err(e) => Err(e),
        Ok(_) => match check("each type counted once", board.count_of_type(ds, "gate") == 1 and board.count_of_type(ds, "budget") == 1 and board.count_of_type(ds, "allocation") == 1 and board.count_of_type(ds, "strategy") == 1 and board.count_of_type(ds, "role") == 1) {
          Err(e) => Err(e),
          Ok(_) => match check("ages are grounded (non-negative)", list.fold(ds, true, fn (ok :: Bool, d :: board.Decision) -> Bool {
            ok and d.age_hours >= 0
          })) {
            Err(e) => Err(e),
            Ok(_) => check("another company's queue is untouched", list.is_empty(board.pending_for_company(db, str.concat(cid, "-other")))),
          },
        },
      }
    },
  }
}

# ── 3. The one decide path ───────────────────────────────────────────────────
fn test_decide_path() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov4-decide-", crypto.random_str_hex(6))
      let __q := queue_five(db, cid)
      let __c := company.add_contact(db, cid, "board", "board-jane", "Jane", "")
      match list.head(board.pending_for_company(db, cid)) {
        None => Err("no pending decisions"),
        Some(_) => {
          let alloc := list.head(list.filter(board.pending_for_company(db, cid), fn (d :: board.Decision) -> Bool {
            d.dtype == "allocation"
          }))
          match alloc {
            None => Err("allocation decision missing"),
            Some(d) => match check("no resolver: refused", match board.decide(db, d.id, "approved", "", "") {
              Err(m) => str.contains(m, "RESOLVER_ID is required"),
              Ok(_) => false,
            }) {
              Err(e) => Err(e),
              Ok(_) => match check("non-registered identity: DENIED", match board.decide(db, d.id, "approved", "", "random-passerby") {
                Err(m) => str.contains(m, "DENIED"),
                Ok(_) => false,
              }) {
                Err(e) => Err(e),
                Ok(_) => match check("bad verdict: refused", match board.decide(db, d.id, "maybe", "", "board-jane") {
                  Err(m) => str.contains(m, "verdict must be"),
                  Ok(_) => false,
                }) {
                  Err(e) => Err(e),
                  Ok(_) => match check("defer records the act and keeps the item pending", match board.decide(db, d.id, "deferred", "need next quarter numbers", "board-jane") {
                    Ok(_) => tr.trail_contains(db, cid, "decision_deferred", d.id) and list.len(board.pending_for_company(db, cid)) == 5,
                    Err(_) => false,
                  }) {
                    Err(e) => Err(e),
                    Ok(_) => match check("registered identity decides", match board.decide(db, d.id, "approved", "", "board-jane") {
                      Ok(_) => true,
                      Err(_) => false,
                    }) {
                      Err(e) => Err(e),
                      Ok(_) => match check("decision leaves the pending queue", list.len(board.pending_for_company(db, cid)) == 4) {
                        Err(e) => Err(e),
                        Ok(_) => match check("an already-resolved decision cannot be re-decided", match board.decide(db, d.id, "rejected", "changed my mind", "board-jane") {
                          Err(m) => str.contains(m, "append-only"),
                          Ok(_) => false,
                        }) {
                          Err(e) => Err(e),
                          Ok(_) => check("the decision is trail-recorded with its type", tr.trail_contains(db, cid, "decision_recorded", "\"type\":\"allocation\"")),
                        },
                      },
                    },
                  },
                },
              },
            },
          }
        },
      }
    },
  }
}

# ── 4 + 5. Minutes + SLA header ──────────────────────────────────────────────
fn test_minutes_and_sla() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov4-sla-", crypto.random_str_hex(6))
      match check("empty queue says none", str.contains(board.sla_section(db, cid), "DECISIONS AWAITING THE BOARD: none")) {
        Err(e) => Err(e),
        Ok(_) => {
          let __q := queue_five(db, cid)
          let section := board.sla_section(db, cid)
          match check("header leads with the pending count", str.contains(section, "DECISIONS AWAITING THE BOARD: 5 pending")) {
            Err(e) => Err(e),
            Ok(_) => match check("header carries the oldest age", str.contains(section, "(oldest: ")) {
              Err(e) => Err(e),
              Ok(_) => match check("header carries per-type counts", str.contains(section, "gate: 1") and str.contains(section, "allocation: 1") and str.contains(section, "strategy: 1")) {
                Err(e) => Err(e),
                Ok(_) => {
                  let d := list.head(list.filter(board.pending_for_company(db, cid), fn (x :: board.Decision) -> Bool {
                    x.dtype == "role"
                  }))
                  match d {
                    None => Err("role decision missing"),
                    Some(dd) => {
                      let __r1 := board.decide(db, dd.id, "approved", "", "board-jane")
                      let __r2 := match list.head(list.filter(board.pending_for_company(db, cid), fn (x :: board.Decision) -> Bool {
                        x.dtype == "budget"
                      })) {
                        None => Ok(""),
                        Some(b) => board.decide(db, b.id, "rejected", "raise revenue first", "board-jane"),
                      }
                      let ms := board.minutes(db, cid)
                      match check("minutes hold both decisions", list.len(ms) == 2) {
                        Err(e) => Err(e),
                        Ok(_) => match check("minutes are typed and attributed", list.fold(ms, false, fn (found :: Bool, m :: Str) -> Bool {
                          found or str.contains(m, "[role]") and str.contains(m, "approved by board-jane")
                        })) {
                          Err(e) => Err(e),
                          Ok(_) => check("minutes carry the rejection reason", list.fold(ms, false, fn (found :: Bool, m :: Str) -> Bool {
                            found or str.contains(m, "raise revenue first")
                          })),
                        },
                      }
                    },
                  }
                },
              },
            },
          }
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_typing(), test_one_queue(), test_decide_path(), test_minutes_and_sla()]
}

fn run_all() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
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

