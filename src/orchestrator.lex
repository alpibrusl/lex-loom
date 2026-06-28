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

import "./metaspec" as metaspec

import "./phase" as phase

import "./transport" as tr

import "./roles" as roles

import "./lex_skill" as lexskill

import "./cast" as cast

import "./diff" as diff

import "./digest" as digest

import "./improver" as improver

import "./tenant" as tenant

import "./loom_trail" as ltrail

import "lex-trail/src/log" as tlog

import "./manifests" as manifests

# ── Types ─────────────────────────────────────────────────────────────────────
type NodeOutcome = { node_id :: Str, attested :: Bool, sealed :: Bool, artifact :: Str, reason :: Str }

type PhaseResult = { phase :: graph.Phase, outcomes :: List[NodeOutcome], success :: Bool }

type SprintResult = { sprint_id :: Str, phases :: List[PhaseResult], success :: Bool, fully_sealed :: Bool, summary :: Str }

# trail_log: the per-sprint lex-trail log (#7). None when the trail DB
# could not be opened; all emit_* helpers no-op in that case.
# depth: how many expand-node levels deep we are (0 = top-level sprint).
# Capped at max_expand_depth() to prevent runaway recursion (#35).
# `iter_ctx` (C4, #57) carries the current company-iteration context so a node's
# `activate_when` condition can be evaluated. None ⇒ standalone sprint (a node is
# active iff its activate_when is empty or evaluates true against a default ctx).
type SprintCfg = { id :: Str, request :: Str, model :: Str, db :: conn.ConnDb, api_calls_max :: Int, roster :: cast.Roster, trail_log :: Option[tlog.Log], review_transitions :: Bool, depth :: Int, iter_ctx :: Option[company.IterCtx] }

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
  { idx: 1, last_verdict: "", digest_summary: "", accepted_count: 0, bounced_count: 0 }
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

fn invoke_node(n :: graph.Node, input :: Str, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] NodeOutcome {
  if node_active(n, cfg) {
    match n.expand {
      Some(subtask) => invoke_expand_node(n, subtask, input, cfg, parent),
      None => invoke_node_attempt(n, input, cfg, 1, "", parent),
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
fn invoke_expand_node(n :: graph.Node, subtask :: Str, input :: Str, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] NodeOutcome {
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
    let child_cfg := { id: child_id, request: child_request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: cast.empty_roster(), trail_log: cfg.trail_log, review_transitions: cfg.review_transitions, depth: cfg.depth + 1, iter_ctx: cfg.iter_ctx }
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

fn invoke_node_attempt(n :: graph.Node, input :: Str, cfg :: SprintCfg, attempt :: Int, prior_denial :: Str, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] NodeOutcome {
  let agent_cfg_opt := match cast.roster_lookup(cfg.roster, n.id) {
    Some(c) => Some(c),
    None => roles.for_role(n.role, cfg.model),
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
          str.join(["Sprint goal: ", cfg.request, "\n\nPrevious step output:\n", input], "")
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
        let output := runner.step(cfg.db, agent_cfg, prompt)
        if str.is_empty(output) {
          if attempt > max_node_retries() {
            { node_id: n.id, attested: false, sealed: false, artifact: "", reason: "empty output after retries (model cold-start?)" }
          } else {
            let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"empty output\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
            invoke_node_attempt(n, input, cfg, attempt + 1, prior_denial, parent)
          }
        } else {
          if gates.is_llm_judge(n.gate) {
            let criteria := gates.judge_criteria(n.gate)
            let judge_cfg := roles.judge_agent(cfg.model, criteria)
            let verdict_raw := runner.step(cfg.db, judge_cfg, str.join(["ARTIFACT TO EVALUATE:\n", output], ""))
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
              let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"judge fail\",\"attempt\":", int.to_str(attempt), "}"], ""))
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
                Ok(hash) => {
                  let __tq := tr.push_attention(cfg.db, cfg.id, n.id, n.gate, oracle, hash)
                  let __ta := tr.trail(cfg.db, cfg.id, "node_attention", str.join(["{\"node\":\"", n.id, "\",\"oracle\":\"", oracle, "\",\"artifact\":\"", hash, "\"}"], ""))
                  let __la := emit_node_accepted(cfg, started_id, n.id, hash)
                  { node_id: n.id, attested: true, sealed: false, artifact: hash, reason: str.join(["awaiting human attestation from oracle: ", oracle], "") }
                },
              }
            } else {
              match evaluate_gate(n.gate, output) {
                GateDeny(reason) => {
                  let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", reason, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
                  let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, reason, attempt)
                  if attempt > max_node_retries() {
                    { node_id: n.id, attested: false, sealed: false, artifact: "", reason: reason }
                  } else {
                    let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
                    invoke_node_attempt(n, input, cfg, attempt + 1, reason, parent)
                  }
                },
                GateAllow => match evaluate_gate(n.gate, output) {
                  GateDeny(reason) => {
                    let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"re-check: ", reason, "\"}"], ""))
                    let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, str.concat("re-check: ", reason), attempt)
                    { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("re-check denied: ", reason) }
                  },
                  GateAllow => match if gates.is_grounded(n.gate) {
                    runner.verify_compiles(n.role)
                  } else {
                    if gates.is_shell_gate(n.gate) {
                      runner.verify_shell(gates.shell_command(n.gate), n.role)
                    } else {
                      runner.verify_build_compiles(n.role)
                    }
                  } {
                    Err(compile_err) => {
                      let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"build does not compile\",\"attempt\":", int.to_str(attempt), "}"], ""))
                      let __ld := emit_node_denied(cfg, started_id, n.id, n.gate, str.concat("build does not compile: ", compile_err), attempt)
                      if attempt > max_node_retries() {
                        { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("build does not compile: ", compile_err) }
                      } else {
                        let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"compile-fail\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
                        invoke_node_attempt(n, input, cfg, attempt + 1, str.join(["Your build does not compile. Fix EVERY file (including tests) until each one compiles:\n", compile_err, lexskill.lex_error_hints(compile_err)], ""), parent)
                      }
                    },
                    Ok(_) => {
                      let __ge := if gates.is_grounded(n.gate) {
                        tr.trail(cfg.db, cfg.id, "gate_evidence", str.join(["{\"node\":\"", n.id, "\",\"gate\":\"", n.gate, "\",\"tool\":\"compile\",\"result\":\"ok\"}"], ""))
                      } else {
                        if gates.is_shell_gate(n.gate) {
                          tr.trail(cfg.db, cfg.id, "gate_evidence", str.join(["{\"node\":\"", n.id, "\",\"gate\":\"", n.gate, "\",\"tool\":\"sh\",\"result\":\"ok\"}"], ""))
                        } else {
                          ()
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

fn assess_input(n :: graph.Node, input :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Assessment {
  match roles.assessor_agent(n.role, cfg.model) {
    assessor => {
      let resp := runner.step(cfg.db, assessor, str.join(["Your assigned input:\n", input], ""))
      parse_assessment(resp)
    },
  }
}

# Resolve a node's input, running the intake-review loop when enabled. Returns
# the (possibly upstream-revised) input string to hand to the node.
fn prepare_input(n :: graph.Node, input_ref :: Str, g :: graph.SprintGraph, cfg :: SprintCfg, parent :: Option[Str], round :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Str {
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

fn invoke_node_for_layer(node_id :: Str, g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] NodeOutcome {
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

fn run_layer(layer :: List[Str], g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg, parent :: Option[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] { outcomes :: List[NodeOutcome], cache :: ArtifactCache } {
  let outcomes := list.par_map(layer, fn (node_id :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] NodeOutcome {
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
fn run_phase(g :: graph.SprintGraph, p :: graph.Phase, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] PhaseResult {
  match graph.topo_sort(g) {
    Err(e) => { phase: p, outcomes: [], success: false },
    Ok(layers) => {
      let entry_parent := current_parent(cfg)
      let result := list.fold(layers, { outcomes: [], last_ref: input_ref, cache: cache, success: true, parent: entry_parent }, fn (acc :: { outcomes :: List[NodeOutcome], last_ref :: Str, cache :: ArtifactCache, success :: Bool, parent :: Option[Str] }, layer :: List[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] { outcomes :: List[NodeOutcome], last_ref :: Str, cache :: ArtifactCache, success :: Bool, parent :: Option[Str] } {
        if not acc.success {
          acc
        } else {
          let layer_result := run_layer(layer, g, acc.last_ref, acc.cache, cfg, acc.parent)
          let all_ok := list.fold(layer_result.outcomes, true, fn (ok :: Bool, o :: NodeOutcome) -> Bool {
            if not ok {
              false
            } else {
              o.attested
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
          { outcomes: list.concat(acc.outcomes, layer_result.outcomes), last_ref: next_ref, cache: layer_result.cache, success: all_ok, parent: current_parent(cfg) }
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

fn run_design(prd :: Str, request :: Str, specs_context :: Str, attempts :: Int, errors :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] DesignResult {
  if attempts > max_design_retries() {
    DesignFailed(str.join(["Architect failed after ", int.to_str(max_design_retries()), " attempts. Last errors: ", errors], ""))
  } else {
    let prompt := if str.is_empty(errors) {
      design_prompt(prd, request)
    } else {
      design_retry_prompt(prd, request, errors)
    }
    let agent_cfg := roles.architect_agent(cfg.model)
    let direct := runner.step(cfg.db, agent_cfg, prompt)
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
        Ok(_) => match metaspec.check(g) {
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
fn max_qa_bounces() -> Int {
  4
}

# Run QA; if it fails, bounce back to Implementation and retry (up to max_qa_bounces).
# Returns both the final QA result and the latest impl result (possibly updated).
type QaBounceResult = { qa :: PhaseResult, impl :: PhaseResult }

fn run_qa_with_bounce(qa_graph :: graph.SprintGraph, impl_graph :: graph.SprintGraph, impl_ref :: Str, task_input :: Str, cfg :: SprintCfg, bounce :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] QaBounceResult {
  let qa_result := run_phase(qa_graph, graph.QA, impl_ref, [], cfg)
  let qa_passed := qa_result.success
  if qa_passed {
    { qa: qa_result, impl: { phase: graph.Implementation, outcomes: [], success: true } }
  } else {
    if bounce > max_qa_bounces() {
      { qa: qa_result, impl: { phase: graph.Implementation, outcomes: [], success: false } }
    } else {
      let __tb := tr.trail(cfg.db, cfg.id, "phase_bounced", str.join(["{\"from\":\"QA\",\"to\":\"Implementation\",\"bounce\":", int.to_str(bounce), "}"], ""))
      let __tt := tr.record_transition(cfg.db, cfg.id, "QA", "Implementation", "QaFailed")
      let qa_denial := list.fold(qa_result.outcomes, "", fn (acc :: Str, o :: NodeOutcome) -> Str {
        if str.is_empty(acc) {
          o.reason
        } else {
          acc
        }
      })
      let bounce_input := str.join(["<<<LOOM_BOUNCE>>>", task_input, "<<<LOOM_SEP>>>", resolve_input(cfg.db, impl_ref), "<<<LOOM_SEP>>>", qa_denial], "")
      let new_impl_ref_result := tr.artifact_put(cfg.db, cfg.id, "bounce-input", bounce_input)
      let new_impl_ref := match new_impl_ref_result {
        Ok(h) => h,
        Err(_) => impl_ref,
      }
      let new_impl := run_phase(impl_graph, graph.Implementation, new_impl_ref, [], cfg)
      let new_impl_ref2 := first_accepted_artifact(new_impl.outcomes)
      let __tt2 := tr.record_transition(cfg.db, cfg.id, "Implementation", "QA", "NoEvidence")
      run_qa_with_bounce(qa_graph, impl_graph, new_impl_ref2, task_input, cfg, bounce + 1)
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
fn run_extensions(base :: graph.SprintGraph, impl_result :: PhaseResult, impl_ref :: Str, cfg :: SprintCfg, round :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] ExtResult {
  if not dynamic_enabled() {
    { graph: base, impl_result: impl_result, ref: impl_ref }
  } else {
    if round > max_extension_rounds() {
      { graph: base, impl_result: impl_result, ref: impl_ref }
    } else {
      let agent_cfg := roles.architect_agent(cfg.model)
      let prompt := extension_prompt(cfg.request, resolve_input(cfg.db, impl_ref), graph.to_json_str(base))
      let direct := runner.step(cfg.db, agent_cfg, prompt)
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
fn run_sprint(cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] SprintResult {
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
  let cfg := { id: cfg.id, request: cfg.request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: cfg.roster, trail_log: llog_opt, review_transitions: cfg.review_transitions, depth: cfg.depth, iter_ctx: cfg.iter_ctx }
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
      { sprint_id: cfg.id, phases: [intake_result], success: false, fully_sealed: false, summary: str.join(["Sprint ", cfg.id, " failed in Design: ", reason], "") }
    },
    DesignOk(sprint_graph) => {
      let design_ref := intake_ref
      let roster := cast.select_roster(cfg.db, sprint_graph, cfg.request, cfg.model)
      let __tc := tr.trail(cfg.db, cfg.id, "phase_cast", str.join(["{\"agents\":", int.to_str(list.len(roster)), "}"], ""))
      let cfg := { id: cfg.id, request: cfg.request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: roster, trail_log: cfg.trail_log, review_transitions: cfg.review_transitions, depth: cfg.depth, iter_ctx: cfg.iter_ctx }
      let __ltgv := match llog_opt {
        None => (),
        Some(log) => {
          let __e := ltrail.graph_validated(log, cfg.id, sprint_graph.id, list.len(sprint_graph.nodes), ltrail.latest_id(log))
          ()
        },
      }
      let __tph2 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Design\",\"to\":\"Implementation\"}")
      let __tpm2 := tr.trail(cfg.db, cfg.id, "phase_manifest", str.join(["{\"phase\":\"Implementation\",\"grant\":\"", manifests.grant_summary_for_phase("Implementation"), "\"}"], ""))
      let impl_result0 := run_phase(sprint_graph, graph.Implementation, design_ref, [], cfg)
      let impl_ref0 := first_accepted_artifact(impl_result0.outcomes)
      let ext := run_extensions(sprint_graph, impl_result0, impl_ref0, cfg, 1)
      let sprint_graph := ext.graph
      let impl_result := ext.impl_result
      let impl_ref := ext.ref
      let __tph3 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Implementation\",\"to\":\"QA\"}")
      let __tpm3 := tr.trail(cfg.db, cfg.id, "phase_manifest", str.join(["{\"phase\":\"QA\",\"grant\":\"", manifests.grant_summary_for_phase("QA"), "\"}"], ""))
      let qa_demo_nodes := graph.str_filter(graph.node_ids(sprint_graph), fn (id :: Str) -> Bool {
        match find_node_in_graph(sprint_graph, id) {
          None => false,
          Some(n) => if n.role == "qa" {
            true
          } else {
            n.role == "demo"
          },
        }
      })
      let qa_demo_graph := if list.is_empty(qa_demo_nodes) {
        { id: str.concat(cfg.id, "-qa"), phase: graph.QA, nodes: [{ id: "qa", role: "qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "demo", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "qa", to: "demo", handoff: "schema {}" }] }
      } else {
        sprint_graph
      }
      let qa_impl_result := run_qa_with_bounce(qa_demo_graph, sprint_graph, impl_ref, resolve_input(cfg.db, design_ref), cfg, 1)
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
      let overall_ok := list.fold(all_phases, true, fn (ok :: Bool, pr :: PhaseResult) -> Bool {
        if not ok {
          false
        } else {
          pr.success
        }
      })
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
      { sprint_id: cfg.id, phases: all_phases, success: overall_ok, fully_sealed: fully_sealed, summary: summary }
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

