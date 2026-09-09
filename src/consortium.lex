# consortium.lex -- run 1 of the consortium (docs/consortium-freeze.md) as a
# controller over lex-economy on ONE shared database.
#
# Two companies, one contract at a time, every step a command that can be
# re-run: `open_run` funds both treasuries, declares capabilities, posts
# SoftwareCo's request for opportunity-research/v1, takes ResearchCo's bid,
# lets procurement decide (SoftwareCo cannot build research, so it buys),
# awards, and opens the contract -- which reserves the price on SoftwareCo's
# treasury through lex-economy's own invariants. `deliver` turns the report
# gate's output into evidence, one item per checkable criterion; the human
# criterion gets none, so the verdict is Ambiguous and the commitment is
# held. `answer` records the founder's answer, re-verifies, and settles by
# the freeze rule (100 / 50 / 0). `status_text` shows what a reader needs to
# reconstruct the run without the trail.
#
# Everything the run decided is in tables here, never in a process: a
# controller that dies between phases loses nothing.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "lex-trail/src/log" as tlog

import "lex-economy/src/treasury" as treasury

import "lex-economy/src/capability" as capability

import "lex-economy/src/contract" as contract

import "lex-economy/src/request_bid" as request_bid

import "lex-economy/src/evidence" as evidence

import "lex-economy/src/settlement" as settlement

import "lex-economy/src/consortium" as consortium

import "./economy_binding" as eb

import "./economy_contract" as ec

import "./economy_procurement" as proc

fn softwareco() -> Str {
  "softwareco"
}

fn researchco() -> Str {
  "researchco"
}

fn currency() -> Str {
  "EUR"
}

fn softwareco_capital() -> Int {
  200000
}

fn researchco_capital() -> Int {
  100000
}

fn softwareco_policy_cap() -> Int {
  60000
}

fn research_price() -> Int {
  40000
}

fn max_spend_cents() -> Int {
  300000
}

fn research_deadline_ms() -> Int {
  5400000
}

fn run_wallclock_ms() -> Int {
  21600000
}

fn research_capability() -> Str {
  "opportunity-research/v1"
}

fn human_attr() -> Str {
  "human:would-fund"
}

fn research_contract_id() -> Str {
  "c-research-1"
}

fn software_capability() -> Str {
  "software-delivery/v1"
}

fn software_price() -> Int {
  60000
}

fn software_deadline_ms() -> Int {
  10800000
}

fn software_contract_id() -> Str {
  "c-software-1"
}

# The second contract's criteria: what loom's own trail and workspace show,
# re-derived by bin/check_software_delivery.py. No human criterion: the
# founder's judgement went into the research contract; delivery is
# mechanical.
fn run1_software_criteria() -> List[request_bid.Criterion] {
  [crit("checkable:iteration-passed", "an iteration of the company ended with verdict passed"), crit("checkable:acceptance-passed", "the passing sprint's sealed artifact was re-executed in a clean dir and its own suite passed"), crit("checkable:app-present", "the workspace holds an app.py that is not the path skeleton's"), crit("checkable:tests-present", "the workspace holds test files beyond the path skeleton's")]
}

fn software_request_description(report :: Str) -> Str {
  str.join(["Build the micro-product the opportunity report below recommends, as a paid, hosted micro-API on the python-fastapi path: implement the endpoints the report implies, validate inputs and reject bad ones with a clear 400, and write tests for every endpoint including the invalid cases. Real payment or product creation stays a human step, never autonomous.\n\nOPPORTUNITY REPORT (delivered under contract ", research_contract_id(), "):\n", report], "")
}

fn crit(attr :: Str, description :: Str) -> request_bid.Criterion {
  { attr: attr, description: description }
}

# The first contract's criteria: the checkable attrs are exactly the names
# bin/check_research_report.py prints, the human one is the founder's.
fn run1_criteria() -> List[request_bid.Criterion] {
  [crit("checkable:problem-statement", "a ## Problem section stating the specific problem"), crit("checkable:target-user", "a ## Target user section naming one concrete user type"), crit("checkable:three-alternatives", "an ## Alternatives table with at least three real products"), crit("checkable:implementation-estimate", "an ## Implementation estimate in hours"), crit("checkable:dependencies", "a bulleted ## Dependencies list"), crit("checkable:two-sources", "at least two distinct http(s) sources"), crit("checkable:sources-grounded", "every cited URL was returned by web_search in this run"), crit("checkable:confidence", "a ## Confidence figure between 0 and 100"), crit("checkable:recommendation", "a ## Recommendation to build or not, with why"), crit(human_attr(), "Is the recommended opportunity one you would fund?")]
}

fn request_description(problem_space :: Str) -> Str {
  str.join(["Find ONE technically feasible micro-product opportunity in this PROBLEM SPACE and document it with evidence: ", problem_space, ". Deliverable: an opportunity report as a fenced report.md with the sections Problem, Target user, Alternatives (a table of at least three real products found by web_search), Implementation estimate (hours), Dependencies, Sources (URLs copied verbatim from web_search results), Confidence (0-100), Recommendation."], "")
}

# ── persistence ─────────────────────────────────────────────────────────────
type ContractRow = { id :: Str, buyer :: Str, supplier :: Str, price_cents :: Int, currency :: Str, state :: Str, verdict_json :: Str, criteria_json :: Str, evidence_json :: Str, commitment_id :: Str }

type RunRow = { id :: Str, opened_at_ms :: Int, problem_space :: Str }

fn init_schema(db :: conn.ConnDb) -> [sql] Result[Unit, Str] {
  match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS consortium_contracts (id TEXT PRIMARY KEY, buyer TEXT NOT NULL, supplier TEXT NOT NULL, price_cents INTEGER NOT NULL, currency TEXT NOT NULL, state TEXT NOT NULL, verdict_json TEXT NOT NULL DEFAULT '', criteria_json TEXT NOT NULL, evidence_json TEXT NOT NULL DEFAULT '[]', commitment_id TEXT NOT NULL, request_json TEXT NOT NULL DEFAULT '', bid_json TEXT NOT NULL DEFAULT '', updated_at_ms INTEGER NOT NULL)", []) {
    Err(e) => Err(str.concat("consortium schema: ", e.message)),
    Ok(_) => match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS consortium_runs (id TEXT PRIMARY KEY, opened_at_ms INTEGER NOT NULL, problem_space TEXT NOT NULL)", []) {
      Err(e) => Err(str.concat("consortium schema: ", e.message)),
      Ok(_) => Ok(()),
    },
  }
}

fn str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
    None => "",
  }
}

fn bool_field(j :: jv.Json, key :: Str) -> Bool {
  match jv.get_field(j, key) {
    Some(v) => match jv.as_bool(v) {
      Some(b) => b,
      None => false,
    },
    None => false,
  }
}

fn names_json(ns :: List[Str]) -> jv.Json {
  JList(list.map(ns, fn (n :: Str) -> jv.Json {
    JStr(n)
  }))
}

fn names_of(j :: jv.Json) -> List[Str] {
  match jv.get_field(j, "names") {
    Some(v) => match jv.as_list(v) {
      Some(xs) => list.fold(xs, [], fn (acc :: List[Str], x :: jv.Json) -> List[Str] {
        match jv.as_str(x) {
          Some(s) => list.concat(acc, [s]),
          None => acc,
        }
      }),
      None => [],
    },
    None => [],
  }
}

fn criteria_json(cs :: List[request_bid.Criterion]) -> Str {
  jv.stringify(JList(list.map(cs, fn (c :: request_bid.Criterion) -> jv.Json {
    JObj([("attr", JStr(c.attr)), ("description", JStr(c.description))])
  })))
}

fn criteria_of(s :: Str) -> List[request_bid.Criterion] {
  match jv.parse(s) {
    Err(_) => [],
    Ok(j) => match jv.as_list(j) {
      None => [],
      Some(xs) => list.map(xs, fn (x :: jv.Json) -> request_bid.Criterion {
        { attr: str_field(x, "attr"), description: str_field(x, "description") }
      }),
    },
  }
}

fn evidence_json(items :: List[evidence.EvidenceItem]) -> Str {
  jv.stringify(JList(list.map(items, fn (i :: evidence.EvidenceItem) -> jv.Json {
    JObj([("attr", JStr(i.attr)), ("satisfied", JBool(i.satisfied)), ("note", JStr(i.note))])
  })))
}

fn evidence_of(s :: Str) -> List[evidence.EvidenceItem] {
  match jv.parse(s) {
    Err(_) => [],
    Ok(j) => match jv.as_list(j) {
      None => [],
      Some(xs) => list.map(xs, fn (x :: jv.Json) -> evidence.EvidenceItem {
        { attr: str_field(x, "attr"), satisfied: bool_field(x, "satisfied"), note: str_field(x, "note") }
      }),
    },
  }
}

fn verdict_json(v :: contract.Verdict) -> Str {
  jv.stringify(match v {
    Fulfilled => JObj([("kind", JStr("fulfilled")), ("names", JList([]))]),
    PartiallyFulfilled(ns) => JObj([("kind", JStr("partially-fulfilled")), ("names", names_json(ns))]),
    Rejected(ns) => JObj([("kind", JStr("rejected")), ("names", names_json(ns))]),
    Ambiguous(ns) => JObj([("kind", JStr("ambiguous")), ("names", names_json(ns))]),
  })
}

fn verdict_of(s :: Str) -> Option[contract.Verdict] {
  match jv.parse(s) {
    Err(_) => None,
    Ok(j) => {
      let kind := str_field(j, "kind")
      if kind == "fulfilled" {
        Some(contract.Fulfilled)
      } else {
        if kind == "partially-fulfilled" {
          Some(contract.PartiallyFulfilled(names_of(j)))
        } else {
          if kind == "rejected" {
            Some(contract.Rejected(names_of(j)))
          } else {
            if kind == "ambiguous" {
              Some(contract.Ambiguous(names_of(j)))
            } else {
              None
            }
          }
        }
      }
    },
  }
}

fn state_str(st :: contract.ContractState) -> Str {
  match st {
    Awarded => "awarded",
    InProgress => "in-progress",
    Delivered => "delivered",
    Verified(_) => "verified",
    Settled => "settled",
    Disputed => "disputed",
    Cancelled => "cancelled",
  }
}

fn state_verdict_json(st :: contract.ContractState) -> Str {
  match st {
    Verified(v) => verdict_json(v),
    _ => "",
  }
}

fn state_of(s :: Str, vj :: Str) -> contract.ContractState {
  if s == "awarded" {
    contract.Awarded
  } else {
    if s == "in-progress" {
      contract.InProgress
    } else {
      if s == "delivered" {
        contract.Delivered
      } else {
        if s == "verified" {
          match verdict_of(vj) {
            Some(v) => contract.Verified(v),
            None => contract.Verified(contract.Ambiguous([])),
          }
        } else {
          if s == "settled" {
            contract.Settled
          } else {
            if s == "disputed" {
              contract.Disputed
            } else {
              contract.Cancelled
            }
          }
        }
      }
    }
  }
}

fn contract_of_row(r :: ContractRow) -> contract.Contract {
  { id: r.id, buyer: r.buyer, supplier: r.supplier, price: { cents: r.price_cents, currency: r.currency }, state: state_of(r.state, r.verdict_json) }
}

fn save_contract(db :: conn.ConnDb, c :: contract.Contract, criteria :: List[request_bid.Criterion], items :: List[evidence.EvidenceItem], commitment_id :: Str, request_json :: Str, bid_json :: Str, now_ms :: Int) -> [sql] Result[Unit, Str] {
  let del := ormq.for_dialect({ sql: "DELETE FROM consortium_contracts WHERE id=?", params: [PStr(c.id)] }, db.dialect)
  match sql.exec(db.handle, del.sql, del.params) {
    Err(e) => Err(str.concat("consortium: clear contract: ", e.message)),
    Ok(_) => {
      let ins := ormq.for_dialect({ sql: "INSERT INTO consortium_contracts (id, buyer, supplier, price_cents, currency, state, verdict_json, criteria_json, evidence_json, commitment_id, request_json, bid_json, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", params: [PStr(c.id), PStr(c.buyer), PStr(c.supplier), PInt(c.price.cents), PStr(c.price.currency), PStr(state_str(c.state)), PStr(state_verdict_json(c.state)), PStr(criteria_json(criteria)), PStr(evidence_json(items)), PStr(commitment_id), PStr(request_json), PStr(bid_json), PInt(now_ms)] }, db.dialect)
      match sql.exec(db.handle, ins.sql, ins.params) {
        Err(e) => Err(str.concat("consortium: save contract: ", e.message)),
        Ok(_) => Ok(()),
      }
    },
  }
}

fn load_contract(db :: conn.ConnDb, id :: Str) -> [sql] Result[ContractRow, Str] {
  let q := ormq.for_dialect({ sql: "SELECT id, buyer, supplier, price_cents, currency, state, verdict_json, criteria_json, evidence_json, commitment_id FROM consortium_contracts WHERE id=?", params: [PStr(id)] }, db.dialect)
  let rows :: Result[List[ContractRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(e) => Err(str.concat("consortium: read contract: ", e.message)),
    Ok(rs) => match list.head(rs) {
      None => Err(str.join(["consortium: no contract ", id, " (run `open` first)"], "")),
      Some(r) => Ok(r),
    },
  }
}

fn all_contracts(db :: conn.ConnDb) -> [sql] List[ContractRow] {
  let q := ormq.for_dialect({ sql: "SELECT id, buyer, supplier, price_cents, currency, state, verdict_json, criteria_json, evidence_json, commitment_id FROM consortium_contracts ORDER BY id", params: [] }, db.dialect)
  let rows :: Result[List[ContractRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn load_run(db :: conn.ConnDb) -> [sql] Option[RunRow] {
  let q := ormq.for_dialect({ sql: "SELECT id, opened_at_ms, problem_space FROM consortium_runs WHERE id=?", params: [PStr("run-1")] }, db.dialect)
  let rows :: Result[List[RunRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn min_int(a :: Int, b :: Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

fn no_trust(_s :: Str) -> Int {
  0
}

fn request_json_of(r :: request_bid.WorkRequest) -> Str {
  jv.stringify(JObj([("id", JStr(r.id)), ("buyer", JStr(r.buyer)), ("capability", JStr(r.capability)), ("description", JStr(r.description)), ("budget_ceiling_cents", JInt(r.budget_ceiling.cents)), ("deadline_ms", JInt(r.deadline_ms))]))
}

fn bid_json_of(b :: request_bid.Bid) -> Str {
  jv.stringify(JObj([("id", JStr(b.id)), ("request_id", JStr(b.request_id)), ("supplier", JStr(b.supplier)), ("price_cents", JInt(b.price.cents)), ("message", JStr(b.message))]))
}

# ── phases ──────────────────────────────────────────────────────────────────
type Opened = { contract :: contract.Contract, goal :: Str, reason :: Str, commitment_id :: Str }

fn offers_of(db :: conn.ConnDb, company :: Str) -> [sql, fs_read] List[capability.Offer] {
  list.fold(eb.company_offers(db), [], fn (acc :: List[capability.Offer], co :: capability.CompanyOffers) -> List[capability.Offer] {
    if co.company == company {
      list.concat(acc, co.offers)
    } else {
      acc
    }
  })
}

fn open_run(db :: conn.ConnDb, log :: tlog.Log, problem_space :: Str, now_ms :: Int) -> [sql, time, fs_read, fs_write] Result[Opened, Str] {
  match init_schema(db) {
    Err(e) => Err(e),
    Ok(_) => match load_contract(db, research_contract_id()) {
      Ok(_) => Err("consortium: run 1 is already open (the research contract exists); use status, deliver or answer"),
      Err(_) => match eb.ensure_treasury(db, softwareco(), currency(), softwareco_capital()) {
        Err(e) => Err(e),
        Ok(buyer_t) => match eb.ensure_treasury(db, researchco(), currency(), researchco_capital()) {
          Err(e) => Err(e),
          Ok(_) => match eb.declare_capabilities(db, softwareco(), ["core"], "python-fastapi") {
            Err(e) => Err(e),
            Ok(_) => match eb.declare_capabilities(db, researchco(), ["core", "research"], "research-report") {
              Err(e) => Err(e),
              Ok(_) => open_contract_phase(db, log, problem_space, now_ms, buyer_t),
            },
          },
        },
      },
    },
  }
}

fn open_contract_phase(db :: conn.ConnDb, log :: tlog.Log, problem_space :: Str, now_ms :: Int, buyer_t :: treasury.Treasury) -> [sql, time, fs_read] Result[Opened, Str] {
  let found := capability.find(eb.company_offers(db), capability.exact_query(research_capability()))
  let sellers := list.map(found, fn (m :: capability.Match) -> Str {
    m.company
  })
  if list.is_empty(list.filter(sellers, fn (s :: Str) -> Bool {
    s == researchco()
  })) {
    Err(str.join(["consortium: nobody offers ", research_capability(), " (found: ", str.join(sellers, ","), ")"], ""))
  } else {
    let req := request_bid.post_request("req-research-1", softwareco(), research_capability(), request_description(problem_space), { cents: softwareco_policy_cap(), currency: currency() }, run1_criteria(), now_ms + research_deadline_ms())
    match request_bid.submit_bid(req, "bid-researchco-1", researchco(), { cents: research_price(), currency: currency() }, "opportunity report within 90 minutes, gated by check_research_report", now_ms) {
      Err(e) => Err(str.concat("consortium: bid: ", e)),
      Ok(bid) => {
        let available := min_int(treasury.available_cents(buyer_t), softwareco_policy_cap())
        let decision := proc.decide(research_capability(), offers_of(db, softwareco()), [bid], 0, available, 0, no_trust)
        match decision.decision {
          Build => Err(str.concat("consortium: procurement chose Build for research SoftwareCo cannot do: ", decision.reason)),
          Defer => Err(str.concat("consortium: procurement deferred: ", decision.reason)),
          Buy(chosen) => match request_bid.award(req, [chosen], chosen.id) {
            Err(e) => Err(str.concat("consortium: award: ", e)),
            Ok((req2, bids)) => match list.head(bids) {
              None => Err("consortium: no bid after award"),
              Some(won) => match settlement.open_contract(db.handle, log, req2, won, research_contract_id(), "commit-research-1") {
                Err(e) => Err(str.concat("consortium: open contract: ", e)),
                Ok(c) => match save_contract(db, c, run1_criteria(), [], "commit-research-1", request_json_of(req2), bid_json_of(won), now_ms) {
                  Err(e) => Err(e),
                  Ok(_) => match sql.exec(db.handle, "INSERT OR REPLACE INTO consortium_runs (id, opened_at_ms, problem_space) VALUES (?, ?, ?)", [PStr("run-1"), PInt(now_ms), PStr(problem_space)]) {
                    Err(e) => Err(str.concat("consortium: save run: ", e.message)),
                    Ok(_) => Ok({ contract: c, goal: ec.goal_from_request(req2), reason: decision.reason, commitment_id: "commit-research-1" }),
                  },
                },
              },
            },
          },
        }
      },
    }
  }
}

# The second contract: SoftwareCo executes internally (procurement says
# Build: it sells software-delivery/v1 and can afford its own estimate), and
# the contract still exists, with SoftwareCo as both parties, so the artifact
# goes through the same evidence -> verdict -> settlement path. Opens only
# once the research contract has settled: the report is its input.
fn open_software(db :: conn.ConnDb, log :: tlog.Log, report :: Str, now_ms :: Int) -> [sql, time, fs_read] Result[Opened, Str] {
  match load_contract(db, research_contract_id()) {
    Err(e) => Err(e),
    Ok(rrow) => if rrow.state != "settled" {
      Err(str.join(["consortium: the research contract is ", rrow.state, ", not settled; the software contract takes the settled report as input"], ""))
    } else {
      match load_contract(db, software_contract_id()) {
        Ok(_) => Err("consortium: the software contract is already open; use status or deliver-software"),
        Err(_) => match treasury.get_treasury(db.handle, softwareco()) {
          Ok(Some(t)) => {
            let own := offers_of(db, softwareco())
            let available := min_int(treasury.available_cents(t), softwareco_policy_cap())
            let decision := proc.decide(software_capability(), own, [], software_price(), available, 0, no_trust)
            match decision.decision {
              Build => {
                let req := request_bid.post_request("req-software-1", softwareco(), software_capability(), software_request_description(report), { cents: softwareco_policy_cap(), currency: currency() }, run1_software_criteria(), now_ms + software_deadline_ms())
                match request_bid.submit_bid(req, "bid-softwareco-1", softwareco(), { cents: software_price(), currency: currency() }, "internal build on the python-fastapi path, verified by loom acceptance", now_ms) {
                  Err(e) => Err(str.concat("consortium: self-bid: ", e)),
                  Ok(bid) => match request_bid.award(req, [bid], bid.id) {
                    Err(e) => Err(str.concat("consortium: award: ", e)),
                    Ok((req2, bids)) => match list.head(bids) {
                      None => Err("consortium: no bid after award"),
                      Some(won) => match settlement.open_contract(db.handle, log, req2, won, software_contract_id(), "commit-software-1") {
                        Err(e) => Err(str.concat("consortium: open software contract: ", e)),
                        Ok(c) => match save_contract(db, c, run1_software_criteria(), [], "commit-software-1", request_json_of(req2), bid_json_of(won), now_ms) {
                          Err(e) => Err(e),
                          Ok(_) => Ok({ contract: c, goal: ec.goal_from_request(req2), reason: decision.reason, commitment_id: "commit-software-1" }),
                        },
                      },
                    },
                  },
                }
              },
              Buy(_) => Err(str.concat("consortium: procurement chose Buy for a capability SoftwareCo sells: ", decision.reason)),
              Defer => Err(str.concat("consortium: procurement deferred the software build: ", decision.reason)),
            }
          },
          _ => Err("consortium: softwareco has no treasury (run open first)"),
        },
      }
    },
  }
}

# What a phase decided: the verdict as verified, and the contract after
# settlement (whose state no longer carries the verdict once Settled).
type Outcome = { verdict :: contract.Verdict, final :: contract.Contract }

fn verdict_in(c :: contract.Contract) -> contract.Verdict {
  match c.state {
    Verified(v) => v,
    _ => contract.Ambiguous([]),
  }
}

fn settle_and_save(db :: conn.ConnDb, log :: tlog.Log, verified :: contract.Contract, criteria :: List[request_bid.Criterion], items :: List[evidence.EvidenceItem], commitment_id :: Str, now_ms :: Int) -> [sql, time] Result[Outcome, Str] {
  match ec.settle_if_decided(db, log, verified, commitment_id) {
    Err(e) => Err(str.concat("consortium: settle: ", e)),
    Ok(final) => match save_contract(db, final, criteria, items, commitment_id, "", "", now_ms) {
      Err(e) => Err(e),
      Ok(_) => Ok({ verdict: verdict_in(verified), final: final }),
    },
  }
}

# The supplier delivered: the checker's output becomes the evidence. A
# delivery meeting NO checkable criterion is Rejected on that half alone --
# the founder is not asked whether to fund a report that was not delivered,
# and the human criterion stays unassessed, not answered by the machine.
fn deliver(db :: conn.ConnDb, log :: tlog.Log, contract_id :: Str, checker_output :: Str, now_ms :: Int) -> [sql, time] Result[Outcome, Str] {
  match load_contract(db, contract_id) {
    Err(e) => Err(e),
    Ok(row) => {
      let c := contract_of_row(row)
      let criteria := criteria_of(row.criteria_json)
      match c.state {
        Awarded => {
          let items := ec.evidence_from_checker(criteria, checker_output)
          let met := list.filter(items, fn (i :: evidence.EvidenceItem) -> Bool {
            i.satisfied
          })
          let verified := if list.is_empty(met) {
            ec.verify_with_verdict(c, contract.Rejected(list.map(items, fn (i :: evidence.EvidenceItem) -> Str {
              i.attr
            })))
          } else {
            ec.verify_with_evidence(c, criteria, items)
          }
          match verified {
            Err(e) => Err(str.concat("consortium: verify: ", e)),
            Ok(v) => settle_and_save(db, log, v, criteria, items, row.commitment_id, now_ms),
          }
        },
        _ => Err(str.join(["consortium: contract ", contract_id, " is ", state_str(c.state), ", not awarded; deliver is refused"], "")),
      }
    },
  }
}

# The founder's answer to the human criterion: re-verify and settle.
fn answer(db :: conn.ConnDb, log :: tlog.Log, contract_id :: Str, yes :: Bool, note :: Str, now_ms :: Int) -> [sql, time] Result[Outcome, Str] {
  match load_contract(db, contract_id) {
    Err(e) => Err(e),
    Ok(row) => {
      let c := contract_of_row(row)
      let criteria := criteria_of(row.criteria_json)
      let items := list.concat(evidence_of(row.evidence_json), [ec.human_answer_item(human_attr(), yes, note)])
      match ec.reverify_after_answer(c, criteria, items) {
        Err(e) => Err(str.concat("consortium: ", e)),
        Ok(verified) => settle_and_save(db, log, verified, criteria, items, row.commitment_id, now_ms),
      }
    },
  }
}

fn verdict_words(v :: contract.Verdict) -> Str {
  match v {
    Fulfilled => "fulfilled",
    PartiallyFulfilled(ns) => str.concat("partially fulfilled; unmet: ", str.join(ns, ", ")),
    Rejected(ns) => str.concat("rejected; unmet: ", str.join(ns, ", ")),
    Ambiguous(ns) => str.concat("ambiguous; awaiting: ", str.join(ns, ", ")),
  }
}

fn verdict_text(st :: contract.ContractState) -> Str {
  match st {
    Verified(v) => verdict_words(v),
    _ => "",
  }
}

fn treasury_line(db :: conn.ConnDb, company :: Str) -> [sql] Str {
  match treasury.get_treasury(db.handle, company) {
    Ok(Some(t)) => str.join(["  ", company, ": balance=", int.to_str(t.balance_cents), "c committed=", int.to_str(t.committed_cents), "c available=", int.to_str(treasury.available_cents(t)), "c"], ""),
    _ => str.join(["  ", company, ": no treasury"], ""),
  }
}

fn balance_of(db :: conn.ConnDb, company :: Str) -> [sql] Int {
  match treasury.get_treasury(db.handle, company) {
    Ok(Some(t)) => t.balance_cents,
    _ => 0,
  }
}

fn is_terminal_state(s :: Str) -> Bool {
  s == "settled" or s == "disputed" or s == "cancelled"
}

# The portfolio view lex-economy's should_terminate takes, from the tables.
fn portfolio_view(db :: conn.ConnDb, now_ms :: Int) -> [sql] consortium.PortfolioView {
  let rows := all_contracts(db)
  let remaining := balance_of(db, softwareco()) + balance_of(db, researchco())
  let open := list.len(list.filter(rows, fn (r :: ContractRow) -> Bool {
    not is_terminal_state(r.state)
  }))
  let all_terminal := list.is_empty(list.filter(rows, fn (r :: ContractRow) -> Bool {
    not is_terminal_state(r.state)
  }))
  { objective_met: not list.is_empty(rows) and all_terminal, total_spent_cents: softwareco_capital() + researchco_capital() - remaining, open_contracts: open, remaining_capital_cents: remaining, now_ms: now_ms }
}

fn status_text(db :: conn.ConnDb, now_ms :: Int) -> [sql] Str {
  let run_line := match load_run(db) {
    None => "run-1: not opened",
    Some(r) => str.join(["run-1: opened at ", int.to_str(r.opened_at_ms), "ms; problem space: ", r.problem_space], ""),
  }
  let contracts := list.map(all_contracts(db), fn (r :: ContractRow) -> Str {
    let c := contract_of_row(r)
    str.join(["  ", r.id, ": ", r.buyer, " -> ", r.supplier, " ", int.to_str(r.price_cents), "c state=", r.state, if str.is_empty(verdict_text(c.state)) {
      ""
    } else {
      str.concat(" verdict=", verdict_text(c.state))
    }], "")
  })
  let view := portfolio_view(db, now_ms)
  let deadline := match load_run(db) {
    None => 0,
    Some(r) => r.opened_at_ms + run_wallclock_ms(),
  }
  let terminate := consortium.should_terminate(view, { max_spend_cents: max_spend_cents(), deadline_ms: deadline })
  str.join([run_line, "\ntreasuries:\n", treasury_line(db, softwareco()), "\n", treasury_line(db, researchco()), "\ncontracts:\n", if list.is_empty(contracts) {
    "  (none)"
  } else {
    str.join(contracts, "\n")
  }, "\nportfolio: spent=", int.to_str(view.total_spent_cents), "c of max ", int.to_str(max_spend_cents()), "c; open contracts=", int.to_str(view.open_contracts), "; objective met=", if view.objective_met {
    "yes"
  } else {
    "no"
  }, "; should terminate=", if terminate {
    "yes"
  } else {
    "no"
  }], "")
}

