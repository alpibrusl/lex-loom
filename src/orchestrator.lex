# orchestrator.lex -- run_phase / run_sprint with an honest effect row (§VI).
#
# M3: Design phase uses real Architect output with retry; all phases use the
#     derived SprintGraph; re-planning via semantic diff.
# M4: Retro + Digest phases added; tightened specs from the Digest are fed
#     into the next sprint's Architect, closing the learning loop (§12).
#
# Effect row: the honest union of every effect this body touches.
# A dishonest twin that omits, say, [llm] or [sql] is rejected at lex check.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "lex-orm/src/connection" as conn

import "std.int" as int

import "lex-schema/json_value" as jv

import "./agent/runner" as runner

import "lex-llm/src/tool" as ltool

import "./company" as company

import "./graph" as graph

import "./gates" as gates

import "./role_contracts" as contracts

import "./metaspec" as metaspec

import "./phase" as phase

import "./transport" as tr

import "./roles" as roles

import "./lex_skill" as lexskill

import "./cast" as cast

import "./pricing" as pricing

import "./diff" as diff

import "./digest" as digest

import "./improver" as improver

import "./tenant" as tenant

import "./loom_trail" as ltrail

import "lex-trail/src/log" as tlog

import "./manifests" as manifests

import "./authority" as authority

import "./budget" as budget

# ── Types ─────────────────────────────────────────────────────────────────────
type NodeOutcome = { node_id :: Str, attested :: Bool, sealed :: Bool, artifact :: Str, reason :: Str }

type PhaseResult = { phase :: graph.Phase, outcomes :: List[NodeOutcome], success :: Bool }

type SprintResult = { sprint_id :: Str, phases :: List[PhaseResult], success :: Bool, fully_sealed :: Bool, summary :: Str, parked :: Bool }

# trail_log: the per-sprint lex-trail log (#7). None when the trail DB
# could not be opened; all emit_* helpers no-op in that case.
# depth: how many expand-node levels deep we are (0 = top-level sprint).
# Capped at max_expand_depth() to prevent runaway recursion (#35).
# `iter_ctx` (C4, #57) carries the current company-iteration context so a node's
# `activate_when` condition can be evaluated. None ⇒ standalone sprint (a node is
# active iff its activate_when is empty or evaluates true against a default ctx).
# exec_mode: "inline" (default) fans a layer out via in-process list.par_map,
# same as always. "queue" (#93) enqueues each layer's nodes onto lex-jobs and
# blocks on await_node_results instead — a separate `worker.lex::run_worker`
# process (or several) must be running against the same DB to drain them; a
# "queue" sprint with no worker running will simply time out per layer.
# policy_isolation (OA2, #183): the company's raw [policy.isolation] table
# (OA1, #182), threaded down to runner.step so a company's declared grant
# override actually changes what a node's agent can do — "" for every
# standalone (non-company) sprint entry point.
type SprintCfg = { id :: Str, request :: Str, model :: Str, db :: conn.ConnDb, api_calls_max :: Int, roster :: cast.Roster, trail_log :: Option[tlog.Log], review_transitions :: Bool, depth :: Int, iter_ctx :: Option[company.IterCtx], exec_mode :: Str, policy_isolation :: Str }

# Artifact cache: maps node_id → artifact_hash for nodes already run.
# Used for re-planning -- unchanged nodes reuse their prior artifact.
type ArtifactCache = List[(Str, Str)]

# ── Gate evaluation ───────────────────────────────────────────────────────────
#
# Evaluate-at-both-ends (§10).
# Delegates to gates.lex which maps gate DSL strings to lex-spec evaluations.
type GateVerdict = gates.GateVerdict

fn evaluate_gate(gate :: Str, output :: Str) -> GateVerdict {
  gates.evaluate(gate, output)
}

# ── Artifact cache helpers ────────────────────────────────────────────────────
fn cache_get(cache :: ArtifactCache, node_id :: Str) -> Option[Str] {
  list.fold(cache, None, fn (acc :: Option[Str], pair :: (Str, Str)) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => match pair {
        (k, v) => if k == node_id {
          Some(v)
        } else {
          None
        },
      },
    }
  })
}

fn cache_put(cache :: ArtifactCache, node_id :: Str, artifact :: Str) -> ArtifactCache {
  list.concat(cache, [(node_id, artifact)])
}

# ── lex-trail per-node emission (#7) ──────────────────────────────────────────
#
# Each emit_* helper appends a typed event to the per-sprint lex-trail log
# (cfg.trail_log), or no-ops when the log is absent. emit_node_started returns
# the new event id (when logging) so node_accepted/node_denied can chain off it,
# forming a node_started → outcome mini-chain that hangs off the layer parent.
fn emit_node_started(cfg :: SprintCfg, parent :: Option[Str], node_id :: Str, role :: Str, attempt :: Int) -> [sql, time] Option[Str] {
  match cfg.trail_log {
    None => None,
    Some(log) => match ltrail.node_started(log, cfg.id, node_id, role, attempt, parent) {
      Err(_) => None,
      Ok(e) => Some(e.id),
    },
  }
}

fn emit_node_accepted(cfg :: SprintCfg, parent :: Option[Str], node_id :: Str, artifact_hash :: Str) -> [sql, time] Unit {
  match cfg.trail_log {
    None => (),
    Some(log) => {
      let __e := ltrail.node_accepted(log, cfg.id, node_id, artifact_hash, parent)
      ()
    },
  }
}

fn emit_node_denied(cfg :: SprintCfg, parent :: Option[Str], node_id :: Str, gate :: Str, reason :: Str, attempt :: Int) -> [sql, time] Unit {
  match cfg.trail_log {
    None => (),
    Some(log) => {
      let __e := ltrail.node_denied(log, cfg.id, node_id, gate, reason, attempt, parent)
      ()
    },
  }
}

# The current tip of the lex-trail chain (head event id), or None when the log
# is absent. Read at layer boundaries (post-barrier) so it is deterministic.
fn current_parent(cfg :: SprintCfg) -> [sql] Option[Str] {
  match cfg.trail_log {
    None => None,
    Some(log) => ltrail.latest_id(log),
  }
}

# ── Node invocation ───────────────────────────────────────────────────────────
fn max_node_retries() -> Int {
  3
}

# Max recursive expansion depth (#35). At depth 3 a top-level sprint can
# expand into sub-sprints that themselves expand — 3 levels total.
fn max_expand_depth() -> Int {
  3
}

# Default iteration context for a standalone sprint (idx 1, no prior results).
fn default_iter_ctx() -> company.IterCtx {
  { idx: 1, last_verdict: "", digest_summary: "", accepted_count: 0, bounced_count: 0, spend_cents: 0 }
}

# Whether a node runs this iteration. Empty activate_when = always; otherwise the
# company condition DSL (C2) is evaluated against the current iteration context.
fn node_active(n :: graph.Node, cfg :: SprintCfg) -> Bool {
  if str.is_empty(str.trim(n.activate_when)) {
    true
  } else {
    let ctx := match cfg.iter_ctx {
      None => default_iter_ctx(),
      Some(c) => c,
    }
    company.eval_condition(n.activate_when, ctx)
  }
}

fn company_of_sprint(sprint_id :: Str) -> Str {
  match list.head(str.split(sprint_id, "/")) {
    Some(cid) => cid,
    None => sprint_id,
  }
}

# The per-node usage owner (#94): runner.step calls made FOR this node are
# recorded under "<sprint>#<node>", so envelope charging (below) and the
# iteration ledger (company.estimate_iteration_cost_cents, which includes
# these children) both price the node's REAL tokens.
fn node_cost_owner(sprint_id :: Str, node_id :: Str) -> Str {
  str.join([sprint_id, "#", node_id], "")
}

# GOV2 (lex-loom#222): every node dispatch consults the role's spend
# envelope (and the company total) BEFORE the agent runs — an exhausted
# envelope refuses the node (that subtree stops; unrelated roles continue)
# and escalates once. Since #94, a completed node is charged its REAL
# priced usage (the delta of usage recorded under its node owner across
# this invocation, so phase re-runs never double-charge); the artifact-size
# estimate remains only for calls whose provider reported no usage.
fn invoke_node(n :: graph.Node, input :: Str, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] NodeOutcome {
  if node_active(n, cfg) {
    let cid := company_of_sprint(cfg.id)
    match budget.check_role(cfg.db, cid, n.role) {
      Exhausted => {
        let __esc := budget.escalate_exhausted(cfg.db, cid, str.concat("role:", n.role), n.role)
        let __t := tr.trail(cfg.db, cfg.id, "node_refused_budget", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\"}"], ""))
        let __p := io.print(str.join(["[budget] node ", n.id, " (", n.role, ") REFUSED — spend envelope exhausted (no overdraft)"], ""))
        { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.join(["BUDGET: spend envelope exhausted for role '", n.role, "' — refused at dispatch"], "") }
      },
      _ => {
        let __auth := authority.record_node_authority(cfg.db, cid, cfg.id, n.id, n.role, cfg.model, cfg.api_calls_max, cfg.policy_isolation, "inline")
        let usage_before := pricing.usage_cost_cents(cfg.db, node_cost_owner(cfg.id, n.id), false)
        let outcome := match n.expand {
          Some(subtask) => invoke_expand_node(n, subtask, input, cfg, parent),
          None => invoke_node_attempt(n, input, cfg, 1, "", parent),
        }
        let usage_after := pricing.usage_cost_cents(cfg.db, node_cost_owner(cfg.id, n.id), false)
        let cost := budget.charge_basis(usage_before, usage_after, str.len(resolve_input(cfg.db, outcome.artifact)))
        let __c := budget.charge(cfg.db, cid, n.role, cost)
        let __w1 := budget.warn_if_needed(cfg.db, cid, "total")
        let __w2 := budget.warn_if_needed(cfg.db, cid, str.concat("role:", n.role))
        outcome
      },
    }
  } else {
    let __sk := tr.trail(cfg.db, cfg.id, "node_skipped", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\",\"activate_when\":\"", n.activate_when, "\"}"], ""))
    { node_id: n.id, attested: true, sealed: true, artifact: "", reason: str.concat("skipped: activate_when ", n.activate_when) }
  }
}

# Run the node as a child sprint (#35 — node-as-loom / recursive nodes).
# The child sprint shares the same DB and budget pool. Its trail events are
# identifiable by child sprint id = "<parent_id>/<node_id>".
# If the child sprint passes, the node is accepted; if it fails, denied.
fn invoke_expand_node(n :: graph.Node, subtask :: Str, input :: Str, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] NodeOutcome {
  if cfg.depth >= max_expand_depth() {
    let __tb := tr.trail(cfg.db, cfg.id, "budget_exhausted", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"max expand depth\",\"depth\":", int.to_str(cfg.depth), "}"], ""))
    { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.join(["expand refused: max depth (", int.to_str(max_expand_depth()), ") reached"], "") }
  } else {
    let child_id := str.join([cfg.id, "/", n.id], "")
    let child_request := if str.is_empty(input) {
      subtask
    } else {
      str.join([subtask, "\n\nContext from parent sprint:\n", input], "")
    }
    let __te := tr.trail(cfg.db, cfg.id, "node_expand_started", str.join(["{\"node\":\"", n.id, "\",\"child_sprint\":\"", child_id, "\",\"depth\":", int.to_str(cfg.depth + 1), "}"], ""))
    let started_id := emit_node_started(cfg, parent, n.id, n.role, 1)
    let child_cfg := { id: child_id, request: child_request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: cast.empty_roster(), trail_log: cfg.trail_log, review_transitions: cfg.review_transitions, depth: cfg.depth + 1, iter_ctx: cfg.iter_ctx, exec_mode: cfg.exec_mode, policy_isolation: cfg.policy_isolation }
    let child_result :: SprintResult := run_sprint(child_cfg)
    let result_json := str.join(["{\"success\":", if child_result.success {
      "true"
    } else {
      "false"
    }, ",\"sprint_id\":\"", child_id, "\",\"depth\":", int.to_str(cfg.depth + 1), "}"], "")
    let __tc := tr.trail(cfg.db, cfg.id, "node_expand_complete", str.join(["{\"node\":\"", n.id, "\",\"child_sprint\":\"", child_id, "\",\"success\":", if child_result.success {
      "true"
    } else {
      "false"
    }, "}"], ""))
    if child_result.parked {
      let __tp := tr.trail(cfg.db, cfg.id, "node_parked", str.join(["{\"node\":\"", n.id, "\",\"child_sprint\":\"", child_id, "\",\"reason\":\"child sprint parked on a blocking gate\"}"], ""))
      { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.join(["PARKED via child sprint ", child_id, " (blocking human gate inside)"], "") }
    } else {
      if child_result.success {
        match tr.artifact_put(cfg.db, cfg.id, n.id, result_json) {
          Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("artifact store failed: ", err) },
          Ok(hash) => {
            let __ta := tr.trail(cfg.db, cfg.id, "node_accepted", str.join(["{\"node\":\"", n.id, "\",\"artifact\":\"", hash, "\"}"], ""))
            let __la := emit_node_accepted(cfg, started_id, n.id, hash)
            { node_id: n.id, attested: true, sealed: true, artifact: hash, reason: "" }
          },
        }
      } else {
        let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"child sprint failed\"}"], ""))
        let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, child_result.summary, 1)
        { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.join(["child sprint failed: ", child_result.summary], "") }
      }
    }
  }
}

# ── Blocking human gates (GOV1, lex-loom#221) ─────────────────────────────────
# A `human <oracle> blocking` gate parks the node (and, via run_phase, its
# dependent subtree) until the oracle resolves the attention item. Parked is
# NOT failure: it rides NodeOutcome.reason with this marker so run_phase can
# tell "waiting on the board" apart from "denied" without changing the
# NodeOutcome shape every literal in this file constructs.
fn parked_reason(oracle :: Str, attention_id :: Str) -> Str {
  str.join(["PARKED awaiting oracle '", oracle, "' (attention ", attention_id, ")"], "")
}

fn is_parked_outcome(o :: NodeOutcome) -> Bool {
  str.starts_with(o.reason, "PARKED ")
}

# The re-entry outcome for a blocking gate whose attention item already
# exists: approved -> sealed with the human-attested artifact (the node is
# NOT re-run and no duplicate item is pushed); rejected -> cancelled with the
# board's reason on the trail (terminal, no retry — the board said no);
# pending -> parked again (idempotent).
fn resolved_gate_outcome(n :: graph.Node, cfg :: SprintCfg, item :: tr.AttentionRow) -> [sql, fs_write, time, random, crypto] NodeOutcome {
  if item.verdict == "approved" {
    let __ta := tr.trail(cfg.db, cfg.id, "node_gate_approved", str.join(["{\"node\":\"", n.id, "\",\"attention\":\"", item.id, "\",\"resolved_by\":\"", item.resolved_by, "\"}"], ""))
    { node_id: n.id, attested: true, sealed: true, artifact: item.artifact_hash, reason: "" }
  } else {
    if item.verdict == "rejected" {
      let __tc := tr.trail(cfg.db, cfg.id, "node_cancelled", str.join(["{\"node\":\"", n.id, "\",\"attention\":\"", item.id, "\",\"resolved_by\":\"", item.resolved_by, "\",\"reason\":\"", company.json_escape(item.rejection_reason), "\"}"], ""))
      { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.join(["cancelled by ", item.resolved_by, ": ", item.rejection_reason], "") }
    } else {
      let __tp := tr.trail(cfg.db, cfg.id, "node_parked", str.join(["{\"node\":\"", n.id, "\",\"oracle\":\"", item.oracle, "\",\"attention\":\"", item.id, "\"}"], ""))
      { node_id: n.id, attested: false, sealed: false, artifact: item.artifact_hash, reason: parked_reason(item.oracle, item.id) }
    }
  }
}

# Before ever invoking the agent: a blocking gate node whose attention item
# already exists (a re-entered parked sprint) resolves from the item alone —
# no LLM call, no duplicate attention row.
fn blocking_precheck(n :: graph.Node, cfg :: SprintCfg) -> [sql, fs_read, fs_write, time, random, crypto] Option[NodeOutcome] {
  if gates.is_judgeable(n.gate) and gates.is_blocking(n.gate) {
    match tr.attention_for_node(cfg.db, cfg.id, n.id) {
      None => None,
      Some(item) => Some(resolved_gate_outcome(n, cfg, item)),
    }
  } else {
    None
  }
}

# Every denial keeps the artifact that was denied and the reason it was denied,
# not just a label.
#
# The judge path always stored its rejected output; the gate paths discarded
# theirs and recorded only a summary like {"reason":"gate command failed"}.
# That made a gate denial unreconstructible, and it cost a real diagnosis: when
# the derived-values gate denied a test author, nothing afterwards could say
# whether it had caught a pasted constant or the gate command had simply
# errored. The denied output is now stored under "<node>-denied-<attempt>", and
# the trail carries the gate expression and up to 600 characters of the check's
# own output.
# lex-llm surfaces a failed call as the literal answer text
# "[provider error: <reason>]" (delta.lex). Loom then gated that string as if it
# were the agent's work: in tzpin2, 12 of 19 denials were an HTTP 500 being
# refused for "producing no fenced files to check". An infrastructure failure
# laundered into a content denial, attributed to the test author, burning a
# retry each time and landing in the failure-mode summary as a pipeline defect.
#
# The empty-output case beside this one already retries with a truthful reason.
# This gives a provider failure the same treatment and the same honesty.
fn is_provider_error(output :: Str) -> Bool {
  str.starts_with(str.trim(output), "[provider error")
}

fn invoke_node_attempt(n :: graph.Node, input :: Str, cfg :: SprintCfg, attempt :: Int, prior_denial :: Str, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] NodeOutcome {
  match blocking_precheck(n, cfg) {
    Some(outcome) => outcome,
    None => invoke_node_attempt_fresh(n, input, cfg, attempt, prior_denial, parent),
  }
}

fn invoke_node_attempt_fresh(n :: graph.Node, input :: Str, cfg :: SprintCfg, attempt :: Int, prior_denial :: Str, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] NodeOutcome {
  let agent_cfg_opt := match cast.roster_lookup(cfg.roster, n.id) {
    Some(c) => Some(c),
    None => roles.for_role(n.role, cfg.model, runner.qa_evidence_path(cfg.id, n.id), cfg.id),
  }
  match agent_cfg_opt {
    None => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("unknown role: ", n.role) },
    Some(agent_cfg) => {
      let calls_so_far := tr.count_trail_events(cfg.db, cfg.id, "node_started")
      if calls_so_far >= cfg.api_calls_max {
        let __tb := tr.trail(cfg.db, cfg.id, "budget_exhausted", str.join(["{\"node\":\"", n.id, "\",\"used\":", int.to_str(calls_so_far), ",\"limit\":", int.to_str(cfg.api_calls_max), "}"], ""))
        { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.join(["budget exhausted: max_api_calls=", int.to_str(cfg.api_calls_max)], "") }
      } else {
        let base_input := if str.is_empty(input) {
          cfg.request
        } else {
          if is_test_author_role(n.role) {
            let schema := response_schema_of(input)
            if str.is_empty(schema) {
              cfg.request
            } else {
              str.join([cfg.request, "\n\nThe response schema this product must return (from the spec — the implementation is being written separately against this same contract):\n", schema], "")
            }
          } else {
            str.join(["Sprint goal: ", cfg.request, "\n\nPrevious step output:\n", input], "")
          }
        }
        let prompt := if str.is_empty(prior_denial) {
          base_input
        } else {
          str.join([base_input, "\n\nYour previous output was rejected by the gate \"", n.gate, "\" with reason: ", prior_denial, "\nPlease fix your output to satisfy the gate."], "")
        }
        let __ts := tr.trail(cfg.db, cfg.id, "node_started", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
        let started_id := emit_node_started(cfg, parent, n.id, n.role, attempt)
        let tool_names := str.join(list.map(agent_cfg.tools, fn (tl :: ltool.Tool) -> Str {
          tl.name
        }), ",")
        let __og := tr.trail(cfg.db, cfg.id, "op_grant", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\",\"agent\":\"", agent_cfg.id, "\",\"tools\":\"", tool_names, "\"}"], ""))
        let evidence_path := runner.qa_evidence_path(cfg.id, n.id)
        let __ce := if gates.is_json_verdict_pass(n.gate) {
          runner.clear_qa_evidence(evidence_path)
        } else {
          ()
        }
        let output := runner.step(cfg.db, agent_cfg, prompt, node_cost_owner(cfg.id, n.id), cfg.policy_isolation)
        let infra := is_provider_error(output)
        if str.is_empty(output) or infra {
          if attempt > max_node_retries() {
            { node_id: n.id, attested: false, sealed: false, artifact: "", reason: if infra {
              str.concat("provider failure, not a content problem: ", str.slice(str.trim(output), 0, 200))
            } else {
              "empty output after retries (model cold-start?)"
            } }
          } else {
            let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", if infra {
              "provider error"
            } else {
              "empty output"
            }, "\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
            invoke_node_attempt(n, input, cfg, attempt + 1, prior_denial, parent)
          }
        } else {
          if gates.is_llm_judge(n.gate) {
            let criteria := gates.judge_criteria(n.gate)
            let judge_cfg := roles.judge_agent(cfg.model, criteria)
            let verdict_raw := runner.step(cfg.db, judge_cfg, str.join(["ARTIFACT TO EVALUATE:\n", output], ""), node_cost_owner(cfg.id, n.id), cfg.policy_isolation)
            let passed := if str.contains(verdict_raw, "\"verdict\":\"PASS\"") {
              true
            } else {
              str.contains(verdict_raw, "\"verdict\": \"PASS\"")
            }
            let __tj := tr.trail(cfg.db, cfg.id, "gate_judged", str.join(["{\"node\":\"", n.id, "\",\"verdict\":\"", if passed {
              "PASS"
            } else {
              "FAIL"
            }, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
            if passed {
              match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
                Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("artifact store failed: ", err) },
                Ok(hash) => {
                  let __ta := tr.trail(cfg.db, cfg.id, "node_accepted", str.join(["{\"node\":\"", n.id, "\",\"artifact\":\"", hash, "\"}"], ""))
                  let __la := emit_node_accepted(cfg, started_id, n.id, hash)
                  { node_id: n.id, attested: true, sealed: true, artifact: hash, reason: "" }
                },
              }
            } else {
              let __sa := tr.artifact_put(cfg.db, cfg.id, n.id, output)
              let judge_reason := str.slice(company.json_escape(verdict_raw), 0, 500)
              let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", judge_reason, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
              let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, str.concat("judge FAIL: ", verdict_raw), attempt)
              if attempt > max_node_retries() {
                { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("judge rejected: ", verdict_raw) }
              } else {
                let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"judge-fail\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
                invoke_node_attempt(n, input, cfg, attempt + 1, str.concat("An LLM judge evaluated your output against the gate criteria and FAILED it. Fix it. Judge verdict: ", verdict_raw), parent)
              }
            }
          } else {
            if gates.is_judgeable(n.gate) {
              let oracle := gates.oracle_of(n.gate)
              match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
                Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("artifact store failed: ", err) },
                Ok(hash) => match tr.push_attention(cfg.db, cfg.id, n.id, n.gate, oracle, hash) {
                  Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("attention push failed: ", err) },
                  Ok(attention_id) => if gates.is_blocking(n.gate) {
                    let __tp := tr.trail(cfg.db, cfg.id, "node_parked", str.join(["{\"node\":\"", n.id, "\",\"oracle\":\"", oracle, "\",\"attention\":\"", attention_id, "\",\"artifact\":\"", hash, "\"}"], ""))
                    { node_id: n.id, attested: false, sealed: false, artifact: hash, reason: parked_reason(oracle, attention_id) }
                  } else {
                    let __ta := tr.trail(cfg.db, cfg.id, "node_attention", str.join(["{\"node\":\"", n.id, "\",\"oracle\":\"", oracle, "\",\"artifact\":\"", hash, "\"}"], ""))
                    let __la := emit_node_accepted(cfg, started_id, n.id, hash)
                    { node_id: n.id, attested: true, sealed: false, artifact: hash, reason: str.join(["awaiting human attestation from oracle: ", oracle], "") }
                  },
                },
              }
            } else {
              match evaluate_gate(n.gate, output) {
                GateDeny(reason) => {
                  let __sd := tr.artifact_put(cfg.db, cfg.id, str.join([n.id, "-denied-", int.to_str(attempt)], ""), output)
                  let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":", jv.stringify(JStr(reason)), ",\"gate\":", jv.stringify(JStr(n.gate)), ",\"attempt\":", int.to_str(attempt), "}"], ""))
                  let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, reason, attempt)
                  if verdict_fail_is_final(n.gate, output) {
                    { node_id: n.id, attested: false, sealed: false, artifact: "", reason: reason }
                  } else {
                    if attempt > max_node_retries() {
                      { node_id: n.id, attested: false, sealed: false, artifact: "", reason: reason }
                    } else {
                      let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
                      invoke_node_attempt(n, input, cfg, attempt + 1, reason, parent)
                    }
                  }
                },
                GateAllow => match evaluate_gate(n.gate, output) {
                  GateDeny(reason) => {
                    let __sd := tr.artifact_put(cfg.db, cfg.id, str.join([n.id, "-denied-recheck-", int.to_str(attempt)], ""), output)
                    let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":", jv.stringify(JStr(str.concat("re-check: ", reason))), ",\"gate\":", jv.stringify(JStr(n.gate)), ",\"attempt\":", int.to_str(attempt), "}"], ""))
                    let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, str.concat("re-check: ", reason), attempt)
                    { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("re-check denied: ", reason) }
                  },
                  GateAllow => match and_contract(n.role, output, cfg.id, str.join([sanitize_id(cfg.id), "-", n.id, "-contract-", int.to_str(attempt)], ""), if gates.is_grounded(n.gate) {
                    runner.verify_compiles(n.role, cfg.id)
                  } else {
                    if gates.is_shell_gate(n.gate) {
                      if runner.is_build_kind(n.role) {
                        runner.verify_shell(gates.shell_command(n.gate), n.role, cfg.id)
                      } else {
                        runner.verify_shell_on_output_from(gates.shell_command(n.gate), output, str.join([cfg.id, "-", n.id, "-", int.to_str(attempt)], ""), runner.tool_work_dir_for_role(n.role, cfg.id))
                      }
                    } else {
                      if str.trim(n.gate) == "spec json-ok-true" {
                        runner.verify_launch_evidence(evidence_path, str.contains(str.replace(gates.first_json_object(output), " ", ""), "\"ok\":true"))
                      } else {
                        if gates.is_json_verdict_pass(n.gate) {
                          let claimed_pass := claimed_pass_of(output)
                          match runner.verify_json_verdict_evidence(evidence_path, claimed_pass) {
                            Err(e) => Err(e),
                            Ok(_) => if claimed_pass {
                              runner.verify_verdict_suite(n.role, cfg.id)
                            } else {
                              Ok(())
                            },
                          }
                        } else {
                          runner.verify_build_compiles(n.role, cfg.id)
                        }
                      }
                    }
                  }) {
                    Err(compile_err) => {
                      let gate_label := if gates.is_shell_gate(n.gate) {
                        "gate command failed"
                      } else {
                        if gates.is_json_verdict_pass(n.gate) {
                          "verdict not grounded"
                        } else {
                          "build does not compile"
                        }
                      }
                      let __sd := tr.artifact_put(cfg.db, cfg.id, str.join([n.id, "-denied-", int.to_str(attempt)], ""), output)
                      let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", gate_label, "\",\"detail\":", jv.stringify(JStr(str.slice(compile_err, 0, 600))), ",\"gate\":", jv.stringify(JStr(n.gate)), ",\"attempt\":", int.to_str(attempt), "}"], ""))
                      let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, str.concat(str.concat(gate_label, ": "), compile_err), attempt)
                      if attempt > max_node_retries() {
                        { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat(str.concat(gate_label, ": "), compile_err) }
                      } else {
                        let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"compile-fail\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
                        invoke_node_attempt(n, input, cfg, attempt + 1, str.join(["Your output did not pass the gate (", gate_label, "). Fix it:\n", compile_err, lexskill.lex_error_hints(compile_err)], ""), parent)
                      }
                    },
                    Ok(_) => {
                      let __ge := if gates.is_grounded(n.gate) {
                        tr.trail(cfg.db, cfg.id, "gate_evidence", str.join(["{\"node\":\"", n.id, "\",\"gate\":\"", n.gate, "\",\"tool\":\"compile\",\"result\":\"ok\"}"], ""))
                      } else {
                        if gates.is_shell_gate(n.gate) {
                          tr.trail(cfg.db, cfg.id, "gate_evidence", str.join(["{\"node\":\"", n.id, "\",\"gate\":\"", n.gate, "\",\"tool\":\"sh\",\"result\":\"ok\"}"], ""))
                        } else {
                          if gates.is_json_verdict_pass(n.gate) {
                            tr.trail(cfg.db, cfg.id, "gate_evidence", str.join(["{\"node\":\"", n.id, "\",\"gate\":\"", n.gate, "\",\"tool\":\"run_code\",\"result\":\"ok\"}"], ""))
                          } else {
                            ()
                          }
                        }
                      }
                      match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
                        Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("artifact store failed: ", err) },
                        Ok(hash) => {
                          let __ta := tr.trail(cfg.db, cfg.id, "node_accepted", str.join(["{\"node\":\"", n.id, "\",\"artifact\":\"", hash, "\"}"], ""))
                          let __la := emit_node_accepted(cfg, started_id, n.id, hash)
                          { node_id: n.id, attested: true, sealed: true, artifact: hash, reason: "" }
                        },
                      }
                    },
                  },
                },
              }
            }
          }
        }
      }
    },
  }
}

# ── Layer execution ───────────────────────────────────────────────────────────
#
# Nodes in a topo layer fan out concurrently via list.par_map (§VI / lex-loom#6).
# Independent same-layer nodes run in parallel; layers stay sequential so a
# layer's inputs are sealed before the next begins. par_map workers each get a
# fresh effect handler that shares the parent's budget pool (so the step/budget
# ceiling still bounds the whole batch) and serialize DB writes on the shared
# sql connection's mutex — the expensive llm/net calls are what actually overlap.
# par_map returns results in input order, so outcome ordering is deterministic.
#
# `parent` is the layer's entry event id in the lex-trail chain (#7): every node
# in the layer chains its node_started off this fixed value, so concurrent
# appends fan out cleanly rather than racing on the log head.
# ── Transition review (intake) ────────────────────────────────────────────────
# Opt-in (cfg.review_transitions). Before a node works, its agent assesses
# whether the handed-in input is sufficient; if not, the inadequate handoff is
# True when a verdict gate was denied because the judge really said FAIL, as
# opposed to returning something unparseable.
#
# Callers must NOT retry the node in the first case. Retrying re-asks the same
# judge about an artifact that did not change, and the feedback it receives is
# the denial reason itself -- "verdict is 'FAIL', expected 'PASS'" -- which
# names the answer the gate is looking for. Observed live (tzlocal iter-2):
# attempt 1 correctly identified a hardcoded expected value that was wrong,
# was denied for saying so, and attempt 2 returned PASS on the very same code.
# The iteration sealed with a suite that really failed 1 of 9. Failing the node
# instead hands it to run_qa_with_bounce, which sends the work back to
# Implementation -- the only actor that can actually make the tests pass.
#
# The second case is different: the artifact may be fine and only the reply
# shape was wrong, so that is still worth another attempt from the same node.
#
# Only an explicit FAIL is final. Any other unexpected verdict value is treated
# as a formatting slip and stays retryable -- being final is a judgement about
# the ARTIFACT, and only the word FAIL actually asserts anything about it.
# Compared case-insensitively. The orchestrator compared `v == "PASS"` while the
# gate compared `str.to_upper(str.trim(v))`, so a model answering "pass" was
# read as claiming failure by one and success by the other -- and the evidence
# check then compared that disagreement against what run_code really reported.
# tzstep2 hit it: `verdict is 'passed', expected 'PASS'`.
# Did the node claim a PASS? Extracted so it can be tested: this comparison used
# to be written inline as `v == "PASS"` while the gate compared
# `str.to_upper(str.trim(v))`, so a model answering "pass" was read as claiming
# failure here and success there -- and the evidence check then compared that
# disagreement against what run_code actually reported. tzstep2 hit it as
# `verdict is 'passed', expected 'PASS'`.
# The one section of the PRD a test author must see: the wire contract.
#
# #282 cut test authors down to the sprint goal alone, because a document-shaped
# PRD in the handoff reliably broke them. That fixed the shape and created a
# gap: the builder works from the PRD and the test author from the raw goal, so
# the two halves specify the product differently and neither is wrong.
#
# Found live (tzfixed iter-1). The service returned {"result": "1752235200"} --
# the CORRECT epoch, verified by hand -- and the test asserted with a helper
# that only accepts numeric leaves, so a correct string answer failed. QA
# reported the implementation as broken and the bounce would have told the
# builder to break working code to satisfy it. That is precisely the failure
# the independent test author exists to prevent, arriving as a TYPE
# disagreement rather than a wrong value, which no gate covered.
#
# Carrying the schema section only, not the PRD: a contract is a few lines, and
# it is the document shape that broke the test author, not the content.
fn response_schema_of(prd :: Str) -> Str {
  let parts := str.split(prd, "## Response Schema")
  if list.len(parts) < 2 {
    ""
  } else {
    match list.head(list.tail(parts)) {
      None => "",
      Some(rest) => match list.head(str.split(rest, "\n## ")) {
        None => "",
        Some(body) => str.trim(body),
      },
    }
  }
}

# Whether this run may reach a real host. Default is local, which deploys
# nowhere: LOOM_ENV unset or "local" means a deploy node has no tool and would
# fail every attempt, so the graph should not contain one.
fn deploy_target_allowed() -> [env] Bool {
  match env.get("LOOM_ENV") {
    None => false,
    Some(v) => {
      let e := str.trim(v)
      if str.is_empty(e) {
        false
      } else {
        not (e == "local")
      }
    },
  }
}

fn claimed_pass_of(output :: Str) -> Bool {
  match gates.extract_verdict(output) {
    Some(v) => str.to_upper(str.trim(v)) == "PASS",
    None => false,
  }
}

fn verdict_fail_is_final(gate :: Str, output :: Str) -> Bool {
  if gates.is_json_verdict_pass(gate) {
    match gates.extract_verdict(output) {
      Some(v) => str.to_upper(str.trim(v)) == "FAIL",
      None => false,
    }
  } else {
    false
  }
}

# bounced back to the node that PRODUCED it, which revises, and the receiving
# node re-assesses the revised input. Bounded by max_transition_rounds.
fn max_transition_rounds() -> Int {
  1
}

type Assessment = { ready :: Bool, missing :: Str }

# Linear, format-tolerant extraction of `{ready, missing}` — avoids depending on
# the model returning perfectly-shaped JSON. Defaults to ready=true on ambiguity
# so a parse hiccup never causes a wasteful bounce.
fn extract_missing(resp :: Str) -> Str {
  let parts := str.split(resp, "\"missing\"")
  match list.head(list.tail(parts)) {
    None => "",
    Some(after) => {
      let segs := str.split(after, "\"")
      match list.head(list.tail(segs)) {
        Some(v) => v,
        None => "",
      }
    },
  }
}

fn parse_assessment(resp :: Str) -> Assessment {
  let not_ready := if str.contains(resp, "\"ready\": false") {
    true
  } else {
    str.contains(resp, "\"ready\":false")
  }
  if not_ready {
    { ready: false, missing: extract_missing(resp) }
  } else {
    { ready: true, missing: "" }
  }
}

fn assess_input(n :: graph.Node, input :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Assessment {
  match roles.assessor_agent(n.role, cfg.model) {
    assessor => {
      let resp := runner.step(cfg.db, assessor, str.join(["Your assigned input:\n", input], ""), node_cost_owner(cfg.id, n.id), cfg.policy_isolation)
      parse_assessment(resp)
    },
  }
}

# Resolve a node's input, running the intake-review loop when enabled. Returns
# the (possibly upstream-revised) input string to hand to the node.
fn prepare_input(n :: graph.Node, input_ref :: Str, g :: graph.SprintGraph, cfg :: SprintCfg, parent :: Option[Str], round :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Str {
  let input := resolve_input(cfg.db, input_ref)
  if cfg.review_transitions {
    if str.is_empty(input) {
      input
    } else {
      if round > max_transition_rounds() {
        input
      } else {
        let a := assess_input(n, input, cfg)
        if a.ready {
          let __t := tr.trail(cfg.db, cfg.id, "transition_review", str.join(["{\"node\":\"", n.id, "\",\"ready\":true,\"round\":", int.to_str(round), "}"], ""))
          input
        } else {
          match tr.artifact_node_id(cfg.db, input_ref) {
            None => input,
            Some(producer_id) => match find_node_in_graph(g, producer_id) {
              None => input,
              Some(producer) => {
                let __tb := tr.trail(cfg.db, cfg.id, "transition_bounced", str.join(["{\"to_node\":\"", n.id, "\",\"from_node\":\"", producer_id, "\",\"missing\":", jv.stringify(JStr(a.missing)), ",\"round\":", int.to_str(round), "}"], ""))
                let revise_prompt := str.join([input, "\n\nA downstream ", n.role, " agent cannot proceed because: ", a.missing, "\n\nRevise YOUR output above to add exactly this, keeping everything else intact. Output the full revised result."], "")
                let revised := invoke_node(producer, revise_prompt, cfg, parent)
                if revised.attested {
                  prepare_input(n, revised.artifact, g, cfg, parent, round + 1)
                } else {
                  input
                }
              },
            },
          }
        }
      }
    }
  } else {
    input
  }
}

fn invoke_node_for_layer(node_id :: Str, g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] NodeOutcome {
  match cache_get(cache, node_id) {
    Some(hash) => {
      let __ts := tr.trail(cfg.db, cfg.id, "node_reused", str.join(["{\"node\":\"", node_id, "\",\"artifact\":\"", hash, "\"}"], ""))
      { node_id: node_id, attested: true, sealed: true, artifact: hash, reason: "" }
    },
    None => {
      match find_node_in_graph(g, node_id) {
        None => { node_id: node_id, attested: false, sealed: false, artifact: "", reason: "node not found in graph" },
        Some(n) => invoke_node(n, prepare_input(n, input_ref, g, cfg, parent, 1), cfg, parent),
      }
    },
  }
}

fn run_layer(layer :: List[Str], g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg, parent :: Option[Str], phase_name :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] { outcomes :: List[NodeOutcome], cache :: ArtifactCache } {
  if cfg.exec_mode == "queue" {
    run_layer_queued(layer, g, input_ref, cache, cfg, parent, phase_name)
  } else {
    let outcomes := list.par_map(layer, fn (node_id :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] NodeOutcome {
      invoke_node_for_layer(node_id, g, input_ref, cache, cfg, parent)
    })
    let new_cache := list.fold(outcomes, cache, fn (acc :: ArtifactCache, o :: NodeOutcome) -> ArtifactCache {
      if o.attested {
        cache_put(acc, o.node_id, o.artifact)
      } else {
        acc
      }
    })
    { outcomes: outcomes, cache: new_cache }
  }
}

# ── Queue-driven layer execution (#93) ────────────────────────────────────────
# Same contract as the inline path above (same input/output shape, same
# artifact-cache semantics) but fans a layer out onto lex-jobs instead of
# list.par_map: cached nodes resolve immediately, everything else is
# enqueue_node'd and then awaited via await_node_results. A separate
# worker.lex::run_worker process (or several) must be draining the "loom:node"
# queue against the same DB — this function only produces and waits, it never
# executes a node itself.
fn queue_await_timeout_ms() -> Int {
  600000
}

fn queue_await_poll_ms() -> Int {
  1000
}

fn node_result_for(rows :: List[tr.NodeResultRow], node_id :: Str) -> Option[tr.NodeResultRow] {
  list.fold(rows, None, fn (acc :: Option[tr.NodeResultRow], r :: tr.NodeResultRow) -> Option[tr.NodeResultRow] {
    match acc {
      Some(_) => acc,
      None => if r.node_id == node_id {
        Some(r)
      } else {
        None
      },
    }
  })
}

fn run_layer_queued(layer :: List[Str], g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg, parent :: Option[Str], phase_name :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] { outcomes :: List[NodeOutcome], cache :: ArtifactCache } {
  let to_enqueue := list.fold(layer, [], fn (acc :: List[Str], node_id :: Str) -> List[Str] {
    match cache_get(cache, node_id) {
      Some(_) => acc,
      None => list.concat(acc, [node_id]),
    }
  })
  let __sg := if list.is_empty(to_enqueue) {
    ()
  } else {
    let __s := tr.save_sprint_graph(cfg.db, cfg.id, phase_name, graph.to_json_str(g))
    ()
  }
  let __enq := list.map(to_enqueue, fn (node_id :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
    match find_node_in_graph(g, node_id) {
      None => (),
      Some(n) => {
        let prepared_input := prepare_input(n, input_ref, g, cfg, parent, 1)
        let enqueued_ref := if str.is_empty(prepared_input) {
          ""
        } else {
          match tr.artifact_put(cfg.db, cfg.id, str.join([node_id, "-input"], ""), prepared_input) {
            Err(_) => "",
            Ok(h) => h,
          }
        }
        let __cl := tr.clear_node_result(cfg.db, cfg.id, phase_name, node_id)
        let __e := tr.enqueue_node(cfg.db, cfg.id, node_id, phase_name, enqueued_ref, cfg.model, cfg.request, cfg.api_calls_max)
        ()
      },
    }
  })
  let awaited := if list.is_empty(to_enqueue) {
    Ok([])
  } else {
    tr.await_node_results(cfg.db, cfg.id, phase_name, to_enqueue, queue_await_timeout_ms(), queue_await_poll_ms())
  }
  let outcomes := list.map(layer, fn (node_id :: Str) -> NodeOutcome {
    match cache_get(cache, node_id) {
      Some(hash) => { node_id: node_id, attested: true, sealed: true, artifact: hash, reason: "" },
      None => match awaited {
        Err(m) => { node_id: node_id, attested: false, sealed: false, artifact: "", reason: str.concat("queue await failed: ", m) },
        Ok(rows) => match node_result_for(rows, node_id) {
          None => { node_id: node_id, attested: false, sealed: false, artifact: "", reason: "no result recorded for this node (job lost?)" },
          Some(r) => { node_id: node_id, attested: r.accepted == 1, sealed: r.accepted == 1, artifact: r.artifact, reason: r.reason },
        },
      },
    }
  })
  let new_cache := list.fold(outcomes, cache, fn (acc :: ArtifactCache, o :: NodeOutcome) -> ArtifactCache {
    if o.attested {
      cache_put(acc, o.node_id, o.artifact)
    } else {
      acc
    }
  })
  { outcomes: outcomes, cache: new_cache }
}

fn find_node_in_graph(g :: graph.SprintGraph, node_id :: Str) -> Option[graph.Node] {
  list.fold(g.nodes, None, fn (acc :: Option[graph.Node], n :: graph.Node) -> Option[graph.Node] {
    match acc {
      Some(_) => acc,
      None => if n.id == node_id {
        Some(n)
      } else {
        None
      },
    }
  })
}

fn resolve_input(db :: conn.ConnDb, input_ref :: Str) -> [sql, fs_read, vcs] Str {
  if str.is_empty(input_ref) {
    ""
  } else {
    match tr.artifact_get(db, input_ref) {
      Err(_) => "",
      Ok(c) => c,
    }
  }
}

# ── run_phase ─────────────────────────────────────────────────────────────────
fn run_phase(g :: graph.SprintGraph, p :: graph.Phase, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] PhaseResult {
  match graph.topo_sort(g) {
    Err(e) => { phase: p, outcomes: [], success: false },
    Ok(layers) => {
      let entry_parent := current_parent(cfg)
      let result := list.fold(layers, { outcomes: [], last_ref: input_ref, cache: cache, success: true, parent: entry_parent, parked: [] }, fn (acc :: { outcomes :: List[NodeOutcome], last_ref :: Str, cache :: ArtifactCache, success :: Bool, parent :: Option[Str], parked :: List[Str] }, layer :: List[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] { outcomes :: List[NodeOutcome], last_ref :: Str, cache :: ArtifactCache, success :: Bool, parent :: Option[Str], parked :: List[Str] } {
        if not acc.success {
          acc
        } else {
          let blocked := graph.descendants(g, acc.parked)
          let is_blocked := fn (id :: Str) -> Bool {
            list.fold(blocked, false, fn (found :: Bool, b :: Str) -> Bool {
              found or b == id
            })
          }
          let to_run := list.filter(layer, fn (id :: Str) -> Bool {
            not is_blocked(id)
          })
          let held_outcomes := list.map(list.filter(layer, is_blocked), fn (id :: Str) -> [sql, fs_write, time, random, crypto] NodeOutcome {
            let __tp := tr.trail(cfg.db, cfg.id, "node_parked_downstream", str.join(["{\"node\":\"", id, "\"}"], ""))
            { node_id: id, attested: false, sealed: false, artifact: "", reason: "PARKED downstream of a blocking human gate" }
          })
          let layer_result := run_layer(to_run, g, acc.last_ref, acc.cache, cfg, acc.parent, graph.phase_to_str(p))
          let combined := list.concat(layer_result.outcomes, held_outcomes)
          let all_ok := list.fold(combined, true, fn (ok :: Bool, o :: NodeOutcome) -> Bool {
            if not ok {
              false
            } else {
              o.attested or is_parked_outcome(o)
            }
          })
          let new_parked := list.fold(combined, acc.parked, fn (ps :: List[Str], o :: NodeOutcome) -> List[Str] {
            if is_parked_outcome(o) {
              list.concat(ps, [o.node_id])
            } else {
              ps
            }
          })
          let next_ref := list.fold(layer_result.outcomes, acc.last_ref, fn (ref :: Str, o :: NodeOutcome) -> Str {
            if o.attested {
              if not str.is_empty(o.artifact) {
                o.artifact
              } else {
                ref
              }
            } else {
              ref
            }
          })
          { outcomes: list.concat(acc.outcomes, combined), last_ref: next_ref, cache: layer_result.cache, success: all_ok, parent: current_parent(cfg), parked: new_parked }
        }
      })
      { phase: p, outcomes: result.outcomes, success: result.success }
    },
  }
}

# ── Design phase: Architect emits real SprintGraph ────────────────────────────
#
# The Architect is prompted to output JSON matching SprintGraph exactly.
# The orchestrator parses, validates structurally (graph.validate) and
# semantically (metaspec.check), then bounces errors back for up to
# MAX_DESIGN_RETRIES attempts before failing the sprint.
fn max_design_retries() -> Int {
  3
}

# design_prompt: the Architect reads the PM's PRD (prd) plus the original request for context.
fn design_prompt(prd :: Str, request :: Str) -> Str {
  str.join(["PM PRD:\n", prd, "\n\nOriginal request (for context):\n", request, "\n\nOutput ONLY the JSON sprint graph — no prose, no markdown fences."], "")
}

fn design_retry_prompt(prd :: Str, request :: Str, errors :: Str) -> Str {
  str.join([design_prompt(prd, request), "\n\nYour previous graph was rejected with these errors:\n", errors, "\nFix all errors and output only the corrected JSON."], "")
}

type DesignResult = DesignOk(graph.SprintGraph) | DesignFailed(Str)

fn run_design(prd :: Str, request :: Str, specs_context :: Str, attempts :: Int, errors :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] DesignResult {
  if attempts > max_design_retries() {
    DesignFailed(str.join(["Architect failed after ", int.to_str(max_design_retries()), " attempts. Last errors: ", errors], ""))
  } else {
    let prompt := if str.is_empty(errors) {
      design_prompt(prd, request)
    } else {
      design_retry_prompt(prd, request, errors)
    }
    let agent_cfg := roles.architect_agent(cfg.model)
    let direct := runner.step(cfg.db, agent_cfg, prompt, cfg.id, cfg.policy_isolation)
    let tmp_path := roles.graph_tmp_path(cfg.id)
    let output := match io.read(tmp_path) {
      Ok(file_content) => {
        let __rm := io.write(tmp_path, "")
        file_content
      },
      Err(_) => direct,
    }
    let __tl := io.print(str.join(["[loom] architect attempt=", int.to_str(attempts), " output_len=", int.to_str(str.len(output))], ""))
    match graph.from_json_str(output) {
      Err(parse_err) => {
        let __tr := tr.trail(cfg.db, cfg.id, "graph_rejected", str.join(["{\"reason\":\"", parse_err, "\",\"attempt\":", int.to_str(attempts), "}"], ""))
        run_design(prd, request, specs_context, attempts + 1, str.join(["JSON parse error: ", parse_err], ""), cfg)
      },
      Ok(g) => match graph.validate(g) {
        Err(struct_err) => {
          let __tr := tr.trail(cfg.db, cfg.id, "graph_rejected", str.join(["{\"reason\":\"", struct_err, "\",\"attempt\":", int.to_str(attempts), "}"], ""))
          run_design(prd, request, specs_context, attempts + 1, str.join(["structural error: ", struct_err], ""), cfg)
        },
        Ok(_) => match metaspec.check_for_target(g, deploy_target_allowed()) {
          Invalid(vs) => {
            let error_str := list.fold(vs, "", fn (acc :: Str, v :: metaspec.Violation) -> Str {
              str.join([acc, v.rule, ": ", v.message, "; "], "")
            })
            let __tr := tr.trail(cfg.db, cfg.id, "graph_rejected", str.join(["{\"reason\":\"metaspec: ", error_str, "\",\"attempt\":", int.to_str(attempts), "}"], ""))
            run_design(prd, request, specs_context, attempts + 1, str.join(["metaspec violations: ", error_str], ""), cfg)
          },
          Valid => {
            let __tv := tr.trail(cfg.db, cfg.id, "graph_validated", str.join(["{\"graph_id\":\"", g.id, "\",\"nodes\":", int.to_str(list.len(g.nodes)), "}"], ""))
            let __tg := tr.record_transition(cfg.db, cfg.id, "Design", "Implementation", "GraphValidated")
            let __sg := tr.save_sprint_graph(cfg.db, cfg.id, "Design", graph.to_json_str(g))
            DesignOk(g)
          },
        },
      },
    }
  }
}

# ── run_sprint ────────────────────────────────────────────────────────────────
#
# Node ids in `g` whose role is exactly "qa" or "demo" -- i.e. the graph
# already embeds its own qa/demo-style gate as part of its normal topology
# (as opposed to a bare build-only graph with nothing resembling a final
# quality gate). Non-empty here means the "QA phase" step in run_sprint must
# NOT re-run the graph -- see the call site for why.
fn qa_demo_role_nodes(g :: graph.SprintGraph) -> List[Str] {
  graph.str_filter(graph.node_ids(g), fn (id :: Str) -> Bool {
    match find_node_in_graph(g, id) {
      None => false,
      Some(n) => if n.role == "qa" {
        true
      } else {
        n.role == "demo"
      },
    }
  })
}

fn max_qa_bounces() -> Int {
  4
}

# Run QA; if it fails, bounce back to Implementation and retry (up to max_qa_bounces).
# Returns both the final QA result and the latest impl result (possibly updated).
type QaBounceResult = { qa :: PhaseResult, impl :: PhaseResult }

# A stalled bounce: the rebuild the previous denial triggered came back with
# the EXACT SAME QA denial reason, or produced byte-identical content
# (content-addressed artifact hashes match) -- either way the rebuild
# attempt changed nothing that mattered, so spending yet another full
# Implementation+QA round on it would just repeat the same outcome. Found
# live burning a real OpenCode subscription: build<->QA bounced the full
# max_qa_bounces() every iteration without the underlying defect (wrong
# framework, missing output format) ever actually changing -- every round
# after the first was pure wasted spend once the denial reason stopped
# changing.
fn bounce_stalled(qa_denial :: Str, prior_denial :: Str, new_impl_ref :: Str, prior_impl_ref :: Str) -> Bool {
  if str.is_empty(prior_denial) {
    false
  } else {
    if qa_denial == prior_denial {
      true
    } else {
      new_impl_ref == prior_impl_ref
    }
  }
}

# Which node produced this artifact. Empty when we cannot tell -- callers must
# then fall back to re-running everything rather than silently doing less.
# Merge a re-run's outcomes over the prior ones: a node the bounce re-ran takes
# its fresh outcome, a node it did not keeps the old one. Needed because the
# bounce now re-runs only the affected subgraph, so the fresh list is partial
# and cannot stand alone as the phase result.
fn merge_outcomes(prior :: List[NodeOutcome], fresh :: List[NodeOutcome]) -> List[NodeOutcome] {
  let updated := list.map(prior, fn (o :: NodeOutcome) -> NodeOutcome {
    list.fold(fresh, o, fn (acc :: NodeOutcome, f :: NodeOutcome) -> NodeOutcome {
      if f.node_id == o.node_id {
        f
      } else {
        acc
      }
    })
  })
  list.fold(fresh, updated, fn (acc :: List[NodeOutcome], f :: NodeOutcome) -> List[NodeOutcome] {
    let seen := list.fold(prior, false, fn (b :: Bool, o :: NodeOutcome) -> Bool {
      if b {
        true
      } else {
        o.node_id == f.node_id
      }
    })
    if seen {
      acc
    } else {
      list.concat(acc, [f])
    }
  })
}

# An Implementation phase is successful only when every one of its nodes was
# attested. Recomputed from the merged outcomes rather than carried, so a node
# that failed and was never repaired cannot be lost.
fn impl_phase_of(outcomes :: List[NodeOutcome]) -> PhaseResult {
  { phase: graph.Implementation, outcomes: outcomes, success: list.fold(outcomes, true, fn (ok :: Bool, o :: NodeOutcome) -> Bool {
    if ok {
      o.attested
    } else {
      false
    }
  }) }
}

# ── Acceptance: the deliverable is checked, not the claim about it ───────────
#
# Every green result this repo produced was wrong until something re-ran the
# artifact. Twice, live: a sprint sealed success=true with a QA verdict of
# "11/11 tests pass" and a deliverable containing no tests at all; and a sprint
# sealed success=true after its build node was denied four times and wrote not
# one file. Both passed every gate, because the gates grounded a verdict in
# evidence the JUDGED PARTY produced -- QA's own run_code snippet, discarded
# immediately after -- rather than in the artifact.
#
# So this is deliberately not another agent. An LLM auditor has the same
# weakness: we watched a judge return a correct FAIL, get denied for saying
# FAIL, and return PASS on identical code. What caught both bugs was
# mechanical: materialise what was SEALED into a clean directory and run its
# tests. No model, nothing to persuade.
#
# It reads the sealed artifact rather than the agent's work dir on purpose. The
# work dir is where the agent was writing; the artifact is what the sprint is
# claiming. Those diverged in practice -- one run's work dir held a stale file
# from a later, failed iteration.
fn acceptance_command(g :: graph.SprintGraph) -> Str {
  let qa_kind := graph.qa_role_for_graph(g)
  if qa_kind == "py_qa" {
    "if ls test_*.py *_test.py >/dev/null 2>&1; then python3 -m pytest -q; else echo 'ACCEPTANCE: no test file in the sealed artifact'; false; fi"
  } else {
    if qa_kind == "qa" {
      "rc=0; found=0; for f in *_test.lex test_*.lex; do [ -e \"$f\" ] || continue; found=1; ${LEX:-lex} run --allow-effects io,fs_read,fs_write,time,random,crypto,net \"$f\" run_all || rc=1; done; if [ \"$found\" -eq 0 ]; then echo 'ACCEPTANCE: no test file in the sealed artifact'; rc=1; fi; [ \"$rc\" -eq 0 ]"
    } else {
      ""
    }
  }
}

# Ok(()) means the sealed artifact really passes its own tests. An empty
# command means this stack has no acceptance runner yet, and the check abstains
# rather than inventing a pass -- abstaining is visible in the trail, a fake
# pass is not.
fn run_acceptance(cfg :: SprintCfg, g :: graph.SprintGraph, artifact_ref :: Str) -> [io, proc, sql, fs_read, fs_write, time, random, crypto, vcs] Result[Unit, Str] {
  let cmd := acceptance_command(g)
  if str.is_empty(cmd) {
    let __ts := tr.trail(cfg.db, cfg.id, "acceptance_skipped", "{\"reason\":\"no acceptance runner for this stack\"}")
    Ok(())
  } else {
    let content := resolve_input(cfg.db, artifact_ref)
    if str.is_empty(str.trim(content)) {
      let __te := tr.trail(cfg.db, cfg.id, "acceptance_failed", "{\"reason\":\"sealed artifact is empty\"}")
      Err("acceptance: the sprint sealed an empty artifact")
    } else {
      match runner.verify_shell_on_output(cmd, content, str.join([sanitize_id(cfg.id), "-acceptance"], "")) {
        Ok(_) => {
          let __ta := tr.trail(cfg.db, cfg.id, "acceptance_passed", "{\"checked\":\"sealed artifact re-executed in a clean dir\"}")
          Ok(())
        },
        Err(e) => {
          let __td := tr.trail(cfg.db, cfg.id, "acceptance_failed", str.join(["{\"reason\":", jv.stringify(JStr(str.slice(e, 0, 400))), "}"], ""))
          Err(str.concat("acceptance: the sealed artifact does not pass its own tests: ", str.slice(e, 0, 300)))
        },
      }
    }
  }
}

fn sanitize_id(s :: Str) -> Str {
  str.replace(str.replace(s, "/", "_"), " ", "_")
}

# A test author is given the GOAL, and not the previous step's output.
#
# Bisected against a live failure, same agent and tools throughout, only the
# input differing:
#
#   sprint goal alone (720 chars)   tool_execs=1  answer 16090 chars  fenced
#   the PM's PRD      (6360 chars)  tool_execs=0  answer   688 chars  no fence
#   both together     (7079 chars)  tool_execs=0  answer   636 chars  no fence
#
# It is not length -- 8879 characters of filler did not break it. It is SHAPE.
# The PRD arrives as a formatted document (## Goal, ## User Stories, ##
# Acceptance Criteria, ## Out of Scope, ## Tech Notes) and the model answers in
# kind: in the live run it produced 30418 characters of markdown analysis with
# ```json fences and never called py_check at all. Handed the terse goal, the
# same agent writes the test file and calls the tool.
#
# This also happens to be what independence wants. A test author is supposed to
# derive its tests from the requirements, and the PRD is a derived restatement
# of them -- one more artifact between the spec and the oracle.
fn is_test_author_role(role :: Str) -> Bool {
  if role == "test_author" {
    true
  } else {
    if role == "py_test_author" {
      true
    } else {
      role == "ts_test_author"
    }
  }
}

fn producing_node(outcomes :: List[NodeOutcome], artifact :: Str) -> Str {
  list.fold(outcomes, "", fn (acc :: Str, o :: NodeOutcome) -> Str {
    if str.is_empty(acc) {
      if o.attested and o.artifact == artifact {
        o.node_id
      } else {
        acc
      }
    } else {
      acc
    }
  })
}

# The part of Implementation a QA failure actually implicates: the node whose
# artifact QA rejected, plus everything downstream of it. Nodes the failure
# cannot have touched are left alone.
#
# The bounce used to re-run the ENTIRE Implementation phase every round, which
# is what made repair unaffordable: measured on this repo, three bounces turned
# a ~10-minute company into 45+, and one all-local tzconvert run cost 2.7 hours
# and 2.6M tokens. A repair loop you can afford to run ten times is a different
# instrument from one you can afford to run four times.
#
# Returns the FULL graph when the producing node is unknown. Narrowing on a
# guess would silently skip work that needed doing, which is a far worse
# failure than re-running too much.
# The test author is implicated by a QA failure just as much as the builder is
# -- that is the whole point of having written the tests separately. It is a
# SIBLING of the build node, not a descendant, so walking descendants alone
# re-runs only the builder, and the loop keeps telling one party to fix a
# disagreement the other may have caused.
fn test_author_ids(g :: graph.SprintGraph) -> List[Str] {
  list.fold(g.nodes, [], fn (acc :: List[Str], n :: graph.Node) -> List[Str] {
    if n.role == "test_author" {
      list.concat(acc, [n.id])
    } else {
      acc
    }
  })
}

fn affected_impl_subgraph(g :: graph.SprintGraph, node_id :: Str) -> graph.SprintGraph {
  if str.is_empty(node_id) {
    g
  } else {
    let ids := list.concat(list.concat([node_id], graph.descendants(g, [node_id])), test_author_ids(g))
    graph.subgraph_of_ids(g, ids, graph.Implementation, "-affected")
  }
}

# The Architect emits ONE graph carrying a single phase, so its QA nodes used
# to execute inside Implementation and this bounce was reachable only when the
# Architect FORGOT to include QA at all (the synthetic fallback). When it did
# include one -- the common case -- the old code took `{ qa: impl_result, impl:
# impl_result }` and never bounced: a QA failure just sank the sprint, with the
# builder never told. Observed live (tzlocal2): every iteration ended
# bounced=0. The graph is now split into an Implementation half and a QA half
# so a real QA failure sends the work back to whoever can fix it.
# Enforce the role's own deliverable contract on top of whatever gate the
# Architect chose. A pure wrapper around the gate result -- Err wins, and a
# contract violation turns an otherwise-passing gate into a denial that names
# the missing artifact.
#
# The gate is per-GRAPH and an LLM picks it; this is per-ROLE and always runs.
# tzlaunch iteration 3 is the case for the distinction: bin/check_imports.py
# existed, worked, and would have caught the module that could not import --
# the Architect just did not attach it to that node. A check a model has to
# remember to opt into is a suggestion, not a validation.
fn and_contract(role :: Str, output :: Str, sprint_id :: Str, scratch :: Str, gate_result :: Result[Unit, Str]) -> [io, proc] Result[Unit, Str] {
  match gate_result {
    Err(e) => Err(e),
    Ok(_) => {
      let seed := runner.tool_work_dir_for_role(role, sprint_id)
      list.fold(contracts.deliverables_for(role), Ok(()), fn (acc :: Result[Unit, Str], d :: contracts.Deliverable) -> [io, proc] Result[Unit, Str] {
        match acc {
          Err(e) => Err(e),
          Ok(_) => match runner.verify_shell_on_output_from(contracts.check_cmd(d), output, scratch, seed) {
            Ok(_) => Ok(()),
            Err(_) => Err(contracts.missing_message(role, d)),
          },
        }
      })
    },
  }
}

fn run_qa_with_bounce(qa_graph :: graph.SprintGraph, impl_graph :: graph.SprintGraph, impl_result :: PhaseResult, impl_ref :: Str, impl_node :: Str, task_input :: Str, cfg :: SprintCfg, bounce :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] QaBounceResult {
  run_qa_with_bounce_tracked(qa_graph, impl_graph, impl_result, impl_ref, impl_node, task_input, cfg, bounce, "", impl_ref)
}

# The build nodes in this graph that never produced anything, as a printable
# list -- "" when at least one of them did.
#
# QA cannot judge a build that never ran. Found live (tzshdr1, iterations 2 and
# 3): the graph contained py_build and py_test_author, both were cast, neither
# ever started, and py_qa then spent four retries per round denying "work dir
# missing" and "NO TEST FILE". Two whole iterations and most of a 2.9M-token
# budget went into a QA node re-reading an empty directory, and the run was
# recorded as the QA model failing. Retrying against an artifact that does not
# exist cannot succeed; the only honest move is to stop and name the producer.
fn missing_producers(impl_graph :: graph.SprintGraph, impl_result :: PhaseResult) -> Str {
  let builds := list.filter(impl_graph.nodes, fn (n :: graph.Node) -> Bool {
    runner.is_build_kind(n.role)
  })
  if list.is_empty(builds) {
    ""
  } else {
    let produced := list.filter(builds, fn (n :: graph.Node) -> Bool {
      list.fold(impl_result.outcomes, false, fn (acc :: Bool, o :: NodeOutcome) -> Bool {
        if acc {
          true
        } else {
          o.attested and o.node_id == n.id
        }
      })
    })
    if list.is_empty(produced) {
      str.join(list.map(builds, fn (n :: graph.Node) -> Str {
        n.id
      }), ", ")
    } else {
      ""
    }
  }
}

fn run_qa_with_bounce_tracked(qa_graph :: graph.SprintGraph, impl_graph :: graph.SprintGraph, impl_result :: PhaseResult, impl_ref :: Str, impl_node :: Str, task_input :: Str, cfg :: SprintCfg, bounce :: Int, prior_denial :: Str, prior_impl_ref :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] QaBounceResult {
  let absent := missing_producers(impl_graph, impl_result)
  let qa_result := if str.is_empty(absent) {
    run_phase(qa_graph, graph.QA, impl_ref, [], cfg)
  } else {
    let __tp := tr.trail(cfg.db, cfg.id, "qa_skipped_no_producer", str.join(["{\"builds\":", jv.stringify(JStr(absent)), "}"], ""))
    { phase: graph.QA, outcomes: [{ node_id: "qa", attested: false, sealed: false, artifact: "", reason: str.join(["QA did not run: the build node(s) ", absent, " never produced an artifact in this sprint, so there is nothing to judge"], "") }], success: false }
  }
  let qa_passed := qa_result.success
  if qa_passed {
    { qa: qa_result, impl: impl_phase_of(impl_result.outcomes) }
  } else {
    let qa_denial := list.fold(qa_result.outcomes, "", fn (acc :: Str, o :: NodeOutcome) -> Str {
      if str.is_empty(acc) {
        o.reason
      } else {
        acc
      }
    })
    if bounce_stalled(qa_denial, prior_denial, impl_ref, prior_impl_ref) {
      let __tst := tr.trail(cfg.db, cfg.id, "phase_bounce_stalled", str.join(["{\"bounce\":", int.to_str(bounce), ",\"reason\":\"", qa_denial, "\"}"], ""))
      { qa: qa_result, impl: impl_phase_of(impl_result.outcomes) }
    } else {
      if bounce > max_qa_bounces() {
        { qa: qa_result, impl: impl_phase_of(impl_result.outcomes) }
      } else {
        let __tb := tr.trail(cfg.db, cfg.id, "phase_bounced", str.join(["{\"from\":\"QA\",\"to\":\"Implementation\",\"bounce\":", int.to_str(bounce), "}"], ""))
        let __tt := tr.record_transition(cfg.db, cfg.id, "QA", "Implementation", "QaFailed")
        let bounce_input := str.join(["<<<LOOM_BOUNCE>>>", task_input, "<<<LOOM_SEP>>>", resolve_input(cfg.db, impl_ref), "<<<LOOM_SEP>>>", qa_denial], "")
        let new_impl_ref_result := tr.artifact_put(cfg.db, cfg.id, "bounce-input", bounce_input)
        let new_impl_ref := match new_impl_ref_result {
          Ok(h) => h,
          Err(_) => impl_ref,
        }
        let rerun_graph := affected_impl_subgraph(impl_graph, impl_node)
        let __ti := tr.trail(cfg.db, cfg.id, "phase_bounce_scope", str.join(["{\"bounce\":", int.to_str(bounce), ",\"from_node\":\"", impl_node, "\",\"rerunning\":", int.to_str(list.len(rerun_graph.nodes)), ",\"of\":", int.to_str(list.len(impl_graph.nodes)), "}"], ""))
        let new_impl := run_phase(rerun_graph, graph.Implementation, new_impl_ref, [], cfg)
        let new_impl_ref2 := first_accepted_artifact(new_impl.outcomes)
        let next_node := producing_node(new_impl.outcomes, new_impl_ref2)
        let __tt2 := tr.record_transition(cfg.db, cfg.id, "Implementation", "QA", "NoEvidence")
        let merged := impl_phase_of(merge_outcomes(impl_result.outcomes, new_impl.outcomes))
        run_qa_with_bounce_tracked(qa_graph, impl_graph, merged, new_impl_ref2, next_node, task_input, cfg, bounce + 1, qa_denial, impl_ref)
      }
    }
  }
}

# ── Dynamic DAG extension (#41) ───────────────────────────────────────────────
#
# After Implementation, the Architect may EXTEND the sprint graph in response to
# intermediate results — adding gated nodes for sub-tasks discovered at runtime.
# Safety envelope (identical to Design): the FULL extended graph must pass the
# metaspec before any new node runs; an invalid delta is rejected (not the
# sprint); a hard node budget + round cap bound runaway growth. Already-run
# nodes are cache-hit (node_reused), so only genuinely new nodes execute.
#
# Opt-in via env DYNAMIC_DAG=1 — default behaviour is unchanged.
type ExtResult = { graph :: graph.SprintGraph, impl_result :: PhaseResult, ref :: Str }

fn max_extension_rounds() -> Int {
  2
}

# Total nodes a sprint graph may reach via dynamic extension. Success compounds
# as ~p^n, so an unbounded graph is both unpredictable and likely to fail.
fn max_total_nodes() -> Int {
  12
}

fn dynamic_enabled() -> [env] Bool {
  match env.get("DYNAMIC_DAG") {
    None => false,
    Some(v) => if v == "1" {
      true
    } else {
      v == "true"
    },
  }
}

# Seed an ArtifactCache from a phase's accepted outcomes so re-running the
# extended graph skips (node_reused) every node that already produced an artifact.
fn cache_from_outcomes(outcomes :: List[NodeOutcome]) -> ArtifactCache {
  list.fold(outcomes, [], fn (acc :: ArtifactCache, o :: NodeOutcome) -> ArtifactCache {
    if o.attested {
      if str.is_empty(o.artifact) {
        acc
      } else {
        cache_put(acc, o.node_id, o.artifact)
      }
    } else {
      acc
    }
  })
}

# Node ids present in `ext` but not in `base` — the genuinely new work.
fn new_node_ids(base :: graph.SprintGraph, ext :: graph.SprintGraph) -> List[Str] {
  let base_ids := graph.node_ids(base)
  graph.str_filter(graph.node_ids(ext), fn (id :: Str) -> Bool {
    not graph.str_contains(base_ids, id)
  })
}

fn extension_prompt(request :: Str, artifact :: Str, current_graph_json :: Str) -> Str {
  str.join(["The Implementation phase produced this accepted artifact:\n", artifact, "\n\nThe current sprint graph is:\n", current_graph_json, "\n\nOriginal request:\n", request, "\n\nDecide whether additional gated nodes are needed to finish the request", " (e.g. a sub-task the work surfaced). If the work is COMPLETE, output the", " current graph UNCHANGED. If extension is needed, output the FULL graph —", " every existing node (same ids) PLUS the new gated nodes and the edges that", " connect them. Output ONLY the JSON sprint graph — no prose, no fences."], "")
}

# One extension round: ask the Architect for an extended graph, validate it the
# same way Design does, run only the new nodes, then recurse. Returns the final
# graph + impl outcomes + result ref. Any rejection or fixed point ends the loop
# with the inputs unchanged (the sprint proceeds on what it already has).
fn run_extensions(base :: graph.SprintGraph, impl_result :: PhaseResult, impl_ref :: Str, cfg :: SprintCfg, round :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] ExtResult {
  if not dynamic_enabled() {
    { graph: base, impl_result: impl_result, ref: impl_ref }
  } else {
    if round > max_extension_rounds() {
      { graph: base, impl_result: impl_result, ref: impl_ref }
    } else {
      let agent_cfg := roles.architect_agent(cfg.model)
      let prompt := extension_prompt(cfg.request, resolve_input(cfg.db, impl_ref), graph.to_json_str(base))
      let direct := runner.step(cfg.db, agent_cfg, prompt, cfg.id, cfg.policy_isolation)
      let tmp_path := roles.graph_tmp_path(cfg.id)
      let output := match io.read(tmp_path) {
        Ok(file_content) => {
          let __rm := io.write(tmp_path, "")
          file_content
        },
        Err(_) => direct,
      }
      match graph.from_json_str(output) {
        Err(parse_err) => {
          let __tr := tr.trail(cfg.db, cfg.id, "graph_extension_rejected", str.join(["{\"reason\":\"parse: ", parse_err, "\",\"round\":", int.to_str(round), "}"], ""))
          { graph: base, impl_result: impl_result, ref: impl_ref }
        },
        Ok(ext) => {
          let news := new_node_ids(base, ext)
          if list.is_empty(news) {
            let __tr := tr.trail(cfg.db, cfg.id, "graph_extension_fixpoint", str.join(["{\"round\":", int.to_str(round), ",\"nodes\":", int.to_str(list.len(graph.node_ids(ext))), "}"], ""))
            { graph: base, impl_result: impl_result, ref: impl_ref }
          } else {
            if list.len(graph.node_ids(ext)) > max_total_nodes() {
              let __tb := tr.trail(cfg.db, cfg.id, "budget_exhausted", str.join(["{\"reason\":\"max nodes\",\"round\":", int.to_str(round), ",\"nodes\":", int.to_str(list.len(graph.node_ids(ext))), ",\"limit\":", int.to_str(max_total_nodes()), "}"], ""))
              { graph: base, impl_result: impl_result, ref: impl_ref }
            } else {
              match graph.validate(ext) {
                Err(struct_err) => {
                  let __tr := tr.trail(cfg.db, cfg.id, "graph_extension_rejected", str.join(["{\"reason\":\"structural: ", struct_err, "\",\"round\":", int.to_str(round), "}"], ""))
                  { graph: base, impl_result: impl_result, ref: impl_ref }
                },
                Ok(_) => match metaspec.check(ext) {
                  Invalid(vs) => {
                    let error_str := list.fold(vs, "", fn (acc :: Str, v :: metaspec.Violation) -> Str {
                      str.join([acc, v.rule, ": ", v.message, "; "], "")
                    })
                    let __tr := tr.trail(cfg.db, cfg.id, "graph_extension_rejected", str.join(["{\"reason\":\"metaspec: ", error_str, "\",\"round\":", int.to_str(round), "}"], ""))
                    { graph: base, impl_result: impl_result, ref: impl_ref }
                  },
                  Valid => {
                    let __ts := tr.trail(cfg.db, cfg.id, "graph_extended", str.join(["{\"round\":", int.to_str(round), ",\"new_nodes\":", int.to_str(list.len(news)), ",\"total_nodes\":", int.to_str(list.len(graph.node_ids(ext))), "}"], ""))
                    let cache := cache_from_outcomes(impl_result.outcomes)
                    let ext_phase := run_phase(ext, graph.Implementation, impl_ref, cache, cfg)
                    let ext_ref := first_accepted_artifact(ext_phase.outcomes)
                    let next_ref := if str.is_empty(ext_ref) {
                      impl_ref
                    } else {
                      ext_ref
                    }
                    run_extensions(ext, ext_phase, next_ref, cfg, round + 1)
                  },
                },
              }
            }
          }
        },
      }
    }
  }
}

# Full Intake → Design → Implementation → QA → Demo pass.
# M3: Design produces a real SprintGraph used for all subsequent phases.
# Re-planning: if the Architect emits a refined graph after Design, semantic
# diff identifies which nodes need re-running.
fn run_sprint(cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] SprintResult {
  let __reg := tenant.register(cfg.db, cfg.id, cfg.request, "")
  let __ti := tr.trail(cfg.db, cfg.id, "sprint_started", str.join(["{\"request\":", jv.stringify(JStr(cfg.request)), ",\"request_len\":", int.to_str(str.len(cfg.request)), "}"], ""))
  let __tm := tr.trail(cfg.db, cfg.id, "sprint_manifest", manifests.sprint_manifest_json(cfg.id))
  let llog_opt := match ltrail.open(str.concat(cfg.id, "-trail.db")) {
    Err(_) => None,
    Ok(llog) => {
      let __lt := ltrail.sprint_started(llog, cfg.id, cfg.request, None)
      Some(llog)
    },
  }
  let cfg := { id: cfg.id, request: cfg.request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: cfg.roster, trail_log: llog_opt, review_transitions: cfg.review_transitions, depth: cfg.depth, iter_ctx: cfg.iter_ctx, exec_mode: cfg.exec_mode, policy_isolation: cfg.policy_isolation }
  let intake_graph := { id: str.concat(cfg.id, "-intake"), phase: graph.Intake, nodes: [{ id: "intake", role: "pm", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [] }
  let intake_result := run_phase(intake_graph, graph.Intake, cfg.request, [], cfg)
  let intake_ref := first_accepted_artifact(intake_result.outcomes)
  let prd := resolve_input(cfg.db, intake_ref)
  let __tph1 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Intake\",\"to\":\"Design\"}")
  let prior_specs := digest.load_tightened_specs(cfg.db, cfg.id)
  let specs_context := digest.specs_context(prior_specs)
  let design_dr := run_design(prd, cfg.request, specs_context, 1, "", cfg)
  match design_dr {
    DesignFailed(reason) => {
      let __tf := tr.trail(cfg.db, cfg.id, "sprint_failed", str.join(["{\"reason\":\"", reason, "\"}"], ""))
      { sprint_id: cfg.id, phases: [intake_result], success: false, fully_sealed: false, summary: str.join(["Sprint ", cfg.id, " failed in Design: ", reason], ""), parked: false }
    },
    DesignOk(sprint_graph) => {
      let design_ref := intake_ref
      let roster := cast.select_roster(cfg.db, sprint_graph, cfg.request, cfg.model, cfg.id)
      let __tc := tr.trail(cfg.db, cfg.id, "phase_cast", str.join(["{\"agents\":", int.to_str(list.len(roster)), "}"], ""))
      let cfg := { id: cfg.id, request: cfg.request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: roster, trail_log: cfg.trail_log, review_transitions: cfg.review_transitions, depth: cfg.depth, iter_ctx: cfg.iter_ctx, exec_mode: cfg.exec_mode, policy_isolation: cfg.policy_isolation }
      let __ltgv := match llog_opt {
        None => (),
        Some(log) => {
          let __e := ltrail.graph_validated(log, cfg.id, sprint_graph.id, list.len(sprint_graph.nodes), ltrail.latest_id(log))
          ()
        },
      }
      let __tph2 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Design\",\"to\":\"Implementation\"}")
      let __tpm2 := tr.trail(cfg.db, cfg.id, "phase_manifest", str.join(["{\"phase\":\"Implementation\",\"grant\":\"", manifests.grant_summary_for_phase("Implementation"), "\"}"], ""))
      let impl_graph := graph.impl_subgraph(sprint_graph)
      let impl_result0 := run_phase(impl_graph, graph.Implementation, design_ref, [], cfg)
      let impl_ref0 := first_accepted_artifact(impl_result0.outcomes)
      let ext := run_extensions(impl_graph, impl_result0, impl_ref0, cfg, 1)
      let impl_graph_ext := ext.graph
      let impl_result := ext.impl_result
      let impl_ref := ext.ref
      let __tph3 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Implementation\",\"to\":\"QA\"}")
      let __tpm3 := tr.trail(cfg.db, cfg.id, "phase_manifest", str.join(["{\"phase\":\"QA\",\"grant\":\"", manifests.grant_summary_for_phase("QA"), "\"}"], ""))
      let qa_impl_result := if graph.has_qa_node(sprint_graph) {
        run_qa_with_bounce(graph.qa_subgraph(sprint_graph), impl_graph_ext, impl_result, impl_ref, producing_node(impl_result.outcomes, impl_ref), resolve_input(cfg.db, design_ref), cfg, 1)
      } else {
        let synthetic_graph := { id: str.concat(cfg.id, "-qa"), phase: graph.QA, nodes: [{ id: "qa", role: graph.qa_role_for_graph(sprint_graph), gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "demo", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "qa", to: "demo", handoff: "schema {}" }] }
        run_qa_with_bounce(synthetic_graph, impl_graph_ext, impl_result, impl_ref, producing_node(impl_result.outcomes, impl_ref), resolve_input(cfg.db, design_ref), cfg, 1)
      }
      let qa_result := qa_impl_result.qa
      let impl_result2 := qa_impl_result.impl
      let demo_ref := first_accepted_artifact(qa_result.outcomes)
      let __tph4 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Demo\",\"to\":\"Digest\"}")
      let next_sprint_id := str.concat(cfg.id, "-next")
      let digest_result := digest.run_digest(cfg.id, next_sprint_id, cfg.model, cfg.db)
      let __tph6 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Digest\",\"to\":\"Improve\"}")
      let improve_result := match digest_result {
        DigestFailed(_) => improver.empty_result(),
        DigestOk(d) => improver.run_improvement(cfg.db, next_sprint_id, d.lessons, cfg.model),
      }
      let __tpi := tr.trail(cfg.db, cfg.id, "phase_improved", str.join(["{\"agents_improved\":", int.to_str(list.len(improve_result.new_agent_ids)), ",\"roles\":[", str.join(list.map(improve_result.new_agent_ids, fn (id :: Str) -> Str {
        str.join(["\"", id, "\""], "")
      }), ","), "]}"], ""))
      let __tph7 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Improve\",\"to\":\"Intake\"}")
      let digest_summary := match digest_result {
        DigestOk(d) => str.join([" Digest: ", int.to_str(list.len(d.tightened_specs)), " spec(s) tightened. Improved ", int.to_str(list.len(improve_result.new_agent_ids)), " agent(s)."], ""),
        DigestFailed(e) => str.join([" Digest failed: ", e], ""),
      }
      let all_phases := [intake_result, impl_result2, qa_result]
      let phases_ok := list.fold(all_phases, true, fn (ok :: Bool, pr :: PhaseResult) -> Bool {
        if not ok {
          false
        } else {
          pr.success
        }
      })
      let acceptance := if phases_ok {
        run_acceptance(cfg, sprint_graph, impl_ref)
      } else {
        Ok(())
      }
      let overall_ok := match acceptance {
        Ok(_) => phases_ok,
        Err(_) => false,
      }
      let acceptance_note := match acceptance {
        Ok(_) => "",
        Err(e) => str.concat(" ", e),
      }
      let fully_sealed := list.fold(all_phases, true, fn (ok :: Bool, pr :: PhaseResult) -> Bool {
        if not ok {
          false
        } else {
          list.fold(pr.outcomes, ok, fn (ok2 :: Bool, o :: NodeOutcome) -> Bool {
            if not ok2 {
              false
            } else {
              o.sealed
            }
          })
        }
      })
      let summary := if not overall_ok {
        str.join(["Sprint ", cfg.id, " failed. Check trail for node denials.", digest_summary], "")
      } else {
        if fully_sealed {
          str.join(["Sprint ", cfg.id, " complete. Demo: ", demo_ref, ".", digest_summary], "")
        } else {
          str.join(["Sprint ", cfg.id, " complete — awaiting human attestation.", digest_summary], "")
        }
      }
      let __tc := tr.trail(cfg.db, cfg.id, "sprint_complete", str.join(["{\"success\":", if overall_ok {
        "true"
      } else {
        "false"
      }, ",\"fully_sealed\":", if fully_sealed {
        "true"
      } else {
        "false"
      }, "}"], ""))
      let __ltc := match llog_opt {
        None => (),
        Some(log) => {
          let __e := ltrail.sprint_complete(log, cfg.id, overall_ok, fully_sealed, demo_ref, ltrail.latest_id(log))
          ()
        },
      }
      let __ts := if overall_ok {
        tenant.complete(cfg.db, cfg.id)
      } else {
        tenant.fail(cfg.db, cfg.id)
      }
      let attested_ids := list.fold(all_phases, [], fn (acc :: List[Str], pr :: PhaseResult) -> List[Str] {
        list.concat(acc, list.fold(pr.outcomes, [], fn (a2 :: List[Str], o :: NodeOutcome) -> List[Str] {
          if o.attested {
            list.concat(a2, [o.node_id])
          } else {
            a2
          }
        }))
      })
      let __cup := cast.update_pool_from_sprint(cfg.db, roster, attested_ids)
      let any_parked := list.fold(all_phases, false, fn (p_acc :: Bool, pr :: PhaseResult) -> Bool {
        if p_acc {
          true
        } else {
          list.fold(pr.outcomes, false, fn (o_acc :: Bool, o :: NodeOutcome) -> Bool {
            o_acc or is_parked_outcome(o)
          })
        }
      })
      let __tpk := if any_parked {
        tr.trail(cfg.db, cfg.id, "sprint_parked", "{\"parked\":true}")
      } else {
        ()
      }
      { sprint_id: cfg.id, phases: all_phases, success: if any_parked {
        false
      } else {
        overall_ok
      }, fully_sealed: if str.is_empty(acceptance_note) {
        fully_sealed
      } else {
        false
      }, summary: if any_parked {
        str.join(["Sprint ", cfg.id, " PARKED — awaiting a blocking human gate decision."], "")
      } else {
        str.concat(summary, acceptance_note)
      }, parked: any_parked }
    },
  }
}

# ── Re-plan: apply a refined graph ────────────────────────────────────────────
#
# Called when the Architect emits a refined graph after the first Design pass.
# Returns the updated cache with only the nodes that need re-running cleared.
fn apply_replan(old_graph :: graph.SprintGraph, new_graph :: graph.SprintGraph, cache :: ArtifactCache) -> ArtifactCache {
  let d := diff.diff(old_graph, new_graph)
  if diff.is_empty(d) {
    cache
  } else {
    let to_rerun := diff.nodes_to_rerun(d, new_graph)
    list.fold(cache, [], fn (acc :: ArtifactCache, pair :: (Str, Str)) -> ArtifactCache {
      match pair {
        (k, _) => if graph.str_contains(to_rerun, k) {
          acc
        } else {
          list.concat(acc, [pair])
        },
      }
    })
  }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
fn first_accepted_artifact(outcomes :: List[NodeOutcome]) -> Str {
  list.fold(outcomes, "", fn (ref :: Str, o :: NodeOutcome) -> Str {
    if str.is_empty(ref) and o.attested {
      o.artifact
    } else {
      ref
    }
  })
}

