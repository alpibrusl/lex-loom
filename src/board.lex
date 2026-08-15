# board.lex — GOV4 (lex-loom#224): board interface v2 — a decision surface,
# not just a report.
#
# Everything the company owes the board already flows through ONE queue
# (GOV1's attention_queue): blocking human gates (GOV1), budget escalations
# (GOV2), allocation proposals (GOV3), strategy proposals (ORG4),
# role-creation approvals (ORG5) — and, with this module, operate
# escalate-tier dossiers (#118/#124), queued from the heartbeat. GOV4 adds
# the SURFACE over that queue:
#
#   1. TYPED. Every pending item classifies into a decision type derived
#      from where it was queued — gate / budget / allocation / strategy /
#      role / operate / config — with its age, so "what does the board owe
#      an answer" is one list, not five report sections.
#   2. ONE DECIDE PATH. `decide` is the single authorized write: RESOLVER_ID
#      required and recorded, #165's registered-contact rule enforced, with
#      approve / reject / defer. The CLI command and the web API BOTH call
#      this exact function — #204's "same check in both paths" upgraded
#      from mirrored code to literally one function.
#   3. APPEND-ONLY MINUTES. The decision history — who decided what, when,
#      why — is read straight from resolved attention rows plus deferral
#      trail events. Nothing here can edit or truncate it.
#   4. SLA VISIBILITY. board_report now LEADS with pending decisions and
#      the age of the oldest one — a company parked on a gate is
#      unmissable.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.io" as io

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "./transport" as tr

import "./company" as company

# ── Decision typing ──────────────────────────────────────────────────────────
# The queue's sprint_id encodes WHO queued the item: governance passes use
# fixed per-company sub-sprints; everything else is a sprint node's human
# gate.
fn decision_type(sprint_id :: Str, gate :: Str) -> Str {
  if str.ends_with(sprint_id, "/allocation") {
    "allocation"
  } else {
    if str.ends_with(sprint_id, "/ceo") {
      "strategy"
    } else {
      if str.ends_with(sprint_id, "/roles") {
        "role"
      } else {
        if str.ends_with(sprint_id, "/budget") {
          "budget"
        } else {
          if str.ends_with(sprint_id, "/operate") {
            "operate"
          } else {
            if str.ends_with(sprint_id, "/scheduler") {
              "config"
            } else {
              "gate"
            }
          }
        }
      }
    }
  }
}

# ── Pending decisions (with ages) ────────────────────────────────────────────
type Decision = { id :: Str, dtype :: Str, sprint_id :: Str, node_id :: Str, gate :: Str, oracle :: Str, artifact_hash :: Str, age_hours :: Int }

type PendingRow = { id :: Str, sprint_id :: Str, node_id :: Str, gate :: Str, oracle :: Str, artifact_hash :: Str, age_hours :: Int }

fn pending_for_company(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Decision] {
  let q := ormq.for_dialect({ sql: "SELECT id, sprint_id, node_id, gate, oracle, artifact_hash, CAST((julianday('now') - julianday(created_at)) * 24 AS INTEGER) AS age_hours FROM attention_queue WHERE verdict='pending' AND (sprint_id = ? OR sprint_id LIKE ?) ORDER BY created_at ASC", params: [PStr(company_id), PStr(str.concat(company_id, "/%"))] }, db.dialect)
  let rows :: Result[List[PendingRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: PendingRow) -> Decision {
      { id: r.id, dtype: decision_type(r.sprint_id, r.gate), sprint_id: r.sprint_id, node_id: r.node_id, gate: r.gate, oracle: r.oracle, artifact_hash: r.artifact_hash, age_hours: r.age_hours }
    }),
  }
}

fn count_of_type(ds :: List[Decision], dtype :: Str) -> Int {
  list.len(list.filter(ds, fn (d :: Decision) -> Bool {
    d.dtype == dtype
  }))
}

fn oldest_age_hours(ds :: List[Decision]) -> Int {
  list.fold(ds, 0, fn (acc :: Int, d :: Decision) -> Int {
    if d.age_hours > acc {
      d.age_hours
    } else {
      acc
    }
  })
}

fn known_types() -> List[Str] {
  ["gate", "budget", "allocation", "strategy", "role", "operate", "config"]
}

fn decision_line(d :: Decision) -> Str {
  str.join(["- [", d.dtype, "] ", d.id, " — ", d.gate, " (oracle ", d.oracle, ", age ", int.to_str(d.age_hours), "h)"], "")
}

# The section board_report LEADS with. A company that owes the board an
# answer is unmissable; a company that owes nothing says so in one line.
fn sla_section(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Str {
  let ds := pending_for_company(db, company_id)
  if list.is_empty(ds) {
    "DECISIONS AWAITING THE BOARD: none\n"
  } else {
    let counts := str.join(list.filter(list.map(known_types(), fn (t :: Str) -> Str {
      let n := count_of_type(ds, t)
      if n == 0 {
        ""
      } else {
        str.join([t, ": ", int.to_str(n)], "")
      }
    }), fn (s :: Str) -> Bool {
      not str.is_empty(s)
    }), ", ")
    str.join(["DECISIONS AWAITING THE BOARD: ", int.to_str(list.len(ds)), " pending (oldest: ", int.to_str(oldest_age_hours(ds)), "h) — ", counts, "\n", str.join(list.map(ds, fn (d :: Decision) -> Str {
      decision_line(d)
    }), "\n"), "\n"], "")
  }
}

# ── The ONE decide path (CLI and API both call exactly this) ─────────────────
# verdicts: "approved" | "rejected" | "deferred". A deferral is a recorded
# board act — who deferred, why — but the item stays pending and its age
# keeps counting (deferring is not a way to make a decision disappear).
fn decide(db :: conn.ConnDb, item_id :: Str, verdict :: Str, reason :: Str, resolver_id :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Result[Str, Str] {
  if str.is_empty(resolver_id) {
    Err("RESOLVER_ID is required — who decided must always be on the record")
  } else {
    if not (verdict == "approved" or verdict == "rejected" or verdict == "deferred") {
      Err("verdict must be 'approved', 'rejected' or 'deferred'")
    } else {
      match tr.get_attention(db, item_id) {
        None => Err(str.concat("no such decision: ", item_id)),
        Some(item) => if item.verdict != "pending" {
          Err(str.join(["decision ", item_id, " is already resolved (", item.verdict, " by ", item.resolved_by, ") — minutes are append-only"], ""))
        } else {
          let company_id := company.company_id_of_sprint(item.sprint_id)
          if not company.is_authorized_resolver(db, company_id, item.oracle, resolver_id) {
            Err(str.join(["DENIED: ", resolver_id, " is not a registered contact for oracle '", item.oracle, "' on company '", company_id, "'"], ""))
          } else {
            let dtype := decision_type(item.sprint_id, item.gate)
            if verdict == "deferred" {
              let __t := tr.trail(db, company_id, "decision_deferred", str.join(["{\"decision\":\"", item_id, "\",\"type\":\"", dtype, "\",\"by\":\"", resolver_id, "\",\"reason\":\"", company.json_escape(reason), "\"}"], ""))
              Ok(str.join(["deferred by ", resolver_id, " — the item stays pending and its age keeps counting"], ""))
            } else {
              match tr.resolve_attention(db, item_id, verdict, reason, resolver_id) {
                Err(e) => Err(e),
                Ok(_) => {
                  let __t := tr.trail(db, company_id, "decision_recorded", str.join(["{\"decision\":\"", item_id, "\",\"type\":\"", dtype, "\",\"verdict\":\"", verdict, "\",\"by\":\"", resolver_id, "\"}"], ""))
                  Ok(str.join([verdict, " by ", resolver_id], ""))
                },
              }
            }
          }
        },
      }
    }
  }
}

# ── The minutes (append-only by construction) ────────────────────────────────
type MinuteRow = { id :: Str, sprint_id :: Str, gate :: Str, oracle :: Str, verdict :: Str, rejection_reason :: Str, resolved_at :: Str, resolved_by :: Str }

fn minutes(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT id, sprint_id, gate, oracle, verdict, rejection_reason, resolved_at, resolved_by FROM attention_queue WHERE verdict IN ('approved', 'rejected') AND (sprint_id = ? OR sprint_id LIKE ?) ORDER BY resolved_at ASC", params: [PStr(company_id), PStr(str.concat(company_id, "/%"))] }, db.dialect)
  let rows :: Result[List[MinuteRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: MinuteRow) -> Str {
      let reason := if str.is_empty(r.rejection_reason) {
        ""
      } else {
        str.join([" — ", r.rejection_reason], "")
      }
      str.join(["[", r.resolved_at, "] [", decision_type(r.sprint_id, r.gate), "] ", r.id, ": ", r.verdict, " by ", r.resolved_by, reason], "")
    }),
  }
}

# ── Operate dossiers into the queue ──────────────────────────────────────────
# CTL6's escalate-tier dossiers used to surface in the report only. Queue
# each as a board decision (once — deduped by content hash) so the fifth
# decision type flows through the same surface. Run from the scheduler
# heartbeat, like every other governance pass.
fn queue_operate_dossiers(db :: conn.ConnDb, company_id :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto, vcs] Int {
  let dossiers := company.escalation_dossiers_for_company(db, company_id)
  list.fold(dossiers, 0, fn (n :: Int, d :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto, vcs] Int {
    match tr.artifact_put(db, str.concat(company_id, "/operate"), "dossier", d) {
      Err(_) => n,
      Ok(hash) => if tr.trail_contains(db, company_id, "operate_dossier_queued", hash) {
        n
      } else {
        match tr.push_attention(db, str.concat(company_id, "/operate"), "dossier", "operate escalation dossier", "board", hash) {
          Err(_) => n,
          Ok(att_id) => {
            let __t := tr.trail(db, company_id, "operate_dossier_queued", str.join(["{\"attention\":\"", att_id, "\",\"artifact\":\"", hash, "\"}"], ""))
            let __p := io.print(str.join(["[board] ", company_id, ": operate escalation dossier queued for the board — attention ", att_id], ""))
            n + 1
          },
        }
      },
    }
  })
}

