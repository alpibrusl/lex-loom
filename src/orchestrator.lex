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

import "./graph" as graph

import "./gates" as gates

import "./metaspec" as metaspec

import "./phase" as phase

import "./transport" as tr

import "./roles" as roles

import "./cast" as cast

import "./diff" as diff

import "./digest" as digest

import "./improver" as improver

import "./tenant" as tenant

import "./loom_trail" as ltrail

import "./manifests" as manifests

# ── Types ─────────────────────────────────────────────────────────────────────
type NodeOutcome = { node_id :: Str, attested :: Bool, sealed :: Bool, artifact :: Str, reason :: Str }

type PhaseResult = { phase :: graph.Phase, outcomes :: List[NodeOutcome], success :: Bool }

type SprintResult = { sprint_id :: Str, phases :: List[PhaseResult], success :: Bool, fully_sealed :: Bool, summary :: Str }

type SprintCfg = { id :: Str, request :: Str, model :: Str, db :: conn.ConnDb, api_calls_max :: Int, roster :: cast.Roster }

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

# ── Node invocation ───────────────────────────────────────────────────────────
fn max_node_retries() -> Int {
  1
}

fn invoke_node(n :: graph.Node, input :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
  invoke_node_attempt(n, input, cfg, 1, "")
}

fn invoke_node_attempt(n :: graph.Node, input :: Str, cfg :: SprintCfg, attempt :: Int, prior_denial :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
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
        let output := runner.step(cfg.db, agent_cfg, prompt)
        if str.is_empty(output) {
          if attempt > max_node_retries() {
            { node_id: n.id, attested: false, sealed: false, artifact: "", reason: "empty output after retries (model cold-start?)" }
          } else {
            let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"empty output\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
            invoke_node_attempt(n, input, cfg, attempt + 1, prior_denial)
          }
        } else {
          if gates.is_judgeable(n.gate) {
            let oracle := gates.oracle_of(n.gate)
            match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
              Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("artifact store failed: ", err) },
              Ok(hash) => {
                let __tq := tr.push_attention(cfg.db, cfg.id, n.id, n.gate, oracle, hash)
                let __ta := tr.trail(cfg.db, cfg.id, "node_attention", str.join(["{\"node\":\"", n.id, "\",\"oracle\":\"", oracle, "\",\"artifact\":\"", hash, "\"}"], ""))
                { node_id: n.id, attested: true, sealed: false, artifact: hash, reason: str.join(["awaiting human attestation from oracle: ", oracle], "") }
              },
            }
          } else {
            match evaluate_gate(n.gate, output) {
              GateDeny(reason) => {
                let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", reason, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
                if attempt > max_node_retries() {
                  { node_id: n.id, attested: false, sealed: false, artifact: "", reason: reason }
                } else {
                  let __tr := tr.trail(cfg.db, cfg.id, "node_retrying", str.join(["{\"node\":\"", n.id, "\",\"attempt\":", int.to_str(attempt + 1), "}"], ""))
                  invoke_node_attempt(n, input, cfg, attempt + 1, reason)
                }
              },
              GateAllow => match evaluate_gate(n.gate, output) {
                GateDeny(reason) => {
                  let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"re-check: ", reason, "\"}"], ""))
                  { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("re-check denied: ", reason) }
                },
                GateAllow => match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
                  Err(err) => { node_id: n.id, attested: false, sealed: false, artifact: "", reason: str.concat("artifact store failed: ", err) },
                  Ok(hash) => {
                    let __ta := tr.trail(cfg.db, cfg.id, "node_accepted", str.join(["{\"node\":\"", n.id, "\",\"artifact\":\"", hash, "\"}"], ""))
                    { node_id: n.id, attested: true, sealed: true, artifact: hash, reason: "" }
                  },
                },
              },
            }
          }
        }
      }
    },
  }
}

# ── Layer execution ───────────────────────────────────────────────────────────
#
# Independent nodes in the same topo layer run concurrently via list.par_map.
# Layers are still sequential -- this is the §VI parallel fan-out.
fn invoke_node_for_layer(node_id :: Str, g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
  match cache_get(cache, node_id) {
    Some(hash) => {
      let __ts := tr.trail(cfg.db, cfg.id, "node_reused", str.join(["{\"node\":\"", node_id, "\",\"artifact\":\"", hash, "\"}"], ""))
      { node_id: node_id, attested: true, sealed: true, artifact: hash, reason: "" }
    },
    None => {
      match find_node_in_graph(g, node_id) {
        None => { node_id: node_id, attested: false, sealed: false, artifact: "", reason: "node not found in graph" },
        Some(n) => invoke_node(n, resolve_input(cfg.db, input_ref), cfg),
      }
    },
  }
}

fn run_layer(layer :: List[Str], g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { outcomes :: List[NodeOutcome], cache :: ArtifactCache } {
  # Nodes run sequentially via list.map (NOT list.par_map). par_map workers are
  # hard-capped at 10M VM steps regardless of --max-steps, and a single agent
  # node — a multi-turn tool loop that serialises a growing conversation each
  # turn — routinely exceeds that. Running on the main thread honours the
  # process step limit (--max-steps), so a node can use as much budget as the
  # invocation allows. Sprints are LLM-latency-bound, so losing intra-layer
  # parallelism costs little wall-clock. Restore par_map only once the runtime
  # lets workers inherit the process step limit (see lex-loom#9).
  let outcomes := list.map(layer, fn (node_id :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
    invoke_node_for_layer(node_id, g, input_ref, cache, cfg)
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

fn resolve_input(db :: conn.ConnDb, input_ref :: Str) -> [sql, fs_read] Str {
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
fn run_phase(g :: graph.SprintGraph, p :: graph.Phase, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] PhaseResult {
  match graph.topo_sort(g) {
    Err(e) => { phase: p, outcomes: [], success: false },
    Ok(layers) => {
      let result := list.fold(layers, { outcomes: [], last_ref: input_ref, cache: cache, success: true }, fn (acc :: { outcomes :: List[NodeOutcome], last_ref :: Str, cache :: ArtifactCache, success :: Bool }, layer :: List[Str]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { outcomes :: List[NodeOutcome], last_ref :: Str, cache :: ArtifactCache, success :: Bool } {
        if not acc.success {
          acc
        } else {
          let layer_result := run_layer(layer, g, acc.last_ref, acc.cache, cfg)
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
          { outcomes: list.concat(acc.outcomes, layer_result.outcomes), last_ref: next_ref, cache: layer_result.cache, success: all_ok }
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

fn design_prompt(request :: Str) -> Str {
  str.join(["You are the Architect for a software sprint.\n\n", "Project request:\n", request, "\n\n", "Output ONLY a JSON object with this exact shape (no prose, no markdown fences):\n", "{\n", "  \"id\": \"<sprint-graph-id>\",\n", "  \"phase\": \"Design\",\n", "  \"nodes\": [\n", "    {\"id\": \"<node-id>\", \"role\": \"<role>\", \"gate\": \"<gate-expr>\"}\n", "  ],\n", "  \"edges\": [\n", "    {\"from\": \"<node-id>\", \"to\": \"<node-id>\", \"handoff\": \"schema {}\"}\n", "  ]\n", "}\n\n", "Valid roles: architect, build, qa, demo, scribe.\n\n", "Valid gate expressions (choose the most specific one for each role):\n", "  spec non-empty              -- Formal: output must not be empty (use for architect/scribe/demo nodes)\n", "  spec json-verdict-pass      -- Formal: output must be JSON {\"verdict\":\"PASS\",...} (ALWAYS use for qa nodes)\n", "  spec len-gt 50              -- Formal: output must be longer than 50 chars (use for build nodes)\n", "  spec len-gt 200             -- Formal: output must be longer than 200 chars (use for large build tasks)\n", "  spec json                   -- Formal: output must be valid JSON\n", "  spec json-field <key>       -- Formal: output must be JSON with field <key>\n", "  spec len-gt <N>             -- Formal: output must be longer than N characters\n", "  human <oracle>              -- Judgeable: output is queued for named oracle attestation\n", "                                 (use for high-stakes nodes where a human must approve)\n", "                                 e.g. 'human product', 'human tech-lead', 'human security'\n\n", "Rules: every node must have a gate; edges must reference existing node ids; ", "no cycles; every demo node must have a qa ancestor. QA nodes MUST use 'spec json-verdict-pass'."], "")
}

fn design_retry_prompt(request :: Str, errors :: Str) -> Str {
  str.join([design_prompt(request), "\n\nYour previous graph was rejected with these errors:\n", errors, "\nFix all errors and output only the corrected JSON."], "")
}

type DesignResult = DesignOk(graph.SprintGraph) | DesignFailed(Str)

fn run_design(request :: Str, specs_context :: Str, attempts :: Int, errors :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] DesignResult {
  if attempts > max_design_retries() {
    DesignFailed(str.join(["Architect failed after ", int.to_str(max_design_retries()), " attempts. Last errors: ", errors], ""))
  } else {
    let prompt := if str.is_empty(errors) {
      design_prompt(request)
    } else {
      design_retry_prompt(request, errors)
    }
    let agent_cfg := roles.architect_with_context(cfg.model, specs_context, cfg.id)
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
        run_design(request, specs_context, attempts + 1, str.join(["JSON parse error: ", parse_err], ""), cfg)
      },
      Ok(g) => match graph.validate(g) {
        Err(struct_err) => {
          let __tr := tr.trail(cfg.db, cfg.id, "graph_rejected", str.join(["{\"reason\":\"", struct_err, "\",\"attempt\":", int.to_str(attempts), "}"], ""))
          run_design(request, specs_context, attempts + 1, str.join(["structural error: ", struct_err], ""), cfg)
        },
        Ok(_) => match metaspec.check(g) {
          Invalid(vs) => {
            let error_str := list.fold(vs, "", fn (acc :: Str, v :: metaspec.Violation) -> Str {
              str.join([acc, v.rule, ": ", v.message, "; "], "")
            })
            let __tr := tr.trail(cfg.db, cfg.id, "graph_rejected", str.join(["{\"reason\":\"metaspec: ", error_str, "\",\"attempt\":", int.to_str(attempts), "}"], ""))
            run_design(request, specs_context, attempts + 1, str.join(["metaspec violations: ", error_str], ""), cfg)
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
  2
}

# Run QA; if it fails, bounce back to Implementation and retry (up to max_qa_bounces).
# Returns both the final QA result and the latest impl result (possibly updated).
type QaBounceResult = { qa :: PhaseResult, impl :: PhaseResult }

fn run_qa_with_bounce(qa_graph :: graph.SprintGraph, impl_graph :: graph.SprintGraph, impl_ref :: Str, cfg :: SprintCfg, bounce :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] QaBounceResult {
  let qa_result := run_phase(qa_graph, graph.QA, impl_ref, [], cfg)
  let qa_passed := list.fold(qa_result.outcomes, false, fn (found :: Bool, o :: NodeOutcome) -> Bool {
    if found {
      true
    } else {
      o.attested
    }
  })
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
      let bounce_input := str.join([resolve_input(cfg.db, impl_ref), "\n\nQA feedback (your previous output did not pass): ", qa_denial], "")
      let new_impl_ref_result := tr.artifact_put(cfg.db, cfg.id, "bounce-input", bounce_input)
      let new_impl_ref := match new_impl_ref_result {
        Ok(h) => h,
        Err(_) => impl_ref,
      }
      let new_impl := run_phase(impl_graph, graph.Implementation, new_impl_ref, [], cfg)
      let new_impl_ref2 := first_accepted_artifact(new_impl.outcomes)
      let __tt2 := tr.record_transition(cfg.db, cfg.id, "Implementation", "QA", "NoEvidence")
      run_qa_with_bounce(qa_graph, impl_graph, new_impl_ref2, cfg, bounce + 1)
    }
  }
}

# Full Intake → Design → Implementation → QA → Demo pass.
# M3: Design produces a real SprintGraph used for all subsequent phases.
# Re-planning: if the Architect emits a refined graph after Design, semantic
# diff identifies which nodes need re-running.
fn run_sprint(cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] SprintResult {
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
  let intake_graph := { id: str.concat(cfg.id, "-intake"), phase: graph.Intake, nodes: [{ id: "intake", role: "architect", gate: "spec non-empty" }], edges: [] }
  let intake_result := run_phase(intake_graph, graph.Intake, "", [], cfg)
  let intake_ref := first_accepted_artifact(intake_result.outcomes)
  let __tph1 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Intake\",\"to\":\"Design\"}")
  let prior_specs := digest.load_tightened_specs(cfg.db, cfg.id)
  let specs_context := digest.specs_context(prior_specs)
  let design_dr := run_design(cfg.request, specs_context, 1, "", cfg)
  match design_dr {
    DesignFailed(reason) => {
      let __tf := tr.trail(cfg.db, cfg.id, "sprint_failed", str.join(["{\"reason\":\"", reason, "\"}"], ""))
      { sprint_id: cfg.id, phases: [intake_result], success: false, fully_sealed: false, summary: str.join(["Sprint ", cfg.id, " failed in Design: ", reason], "") }
    },
    DesignOk(sprint_graph) => {
      let design_ref := intake_ref
      let roster := cast.select_roster(cfg.db, sprint_graph, cfg.request, cfg.model)
      let __tc := tr.trail(cfg.db, cfg.id, "phase_cast", str.join(["{\"agents\":", int.to_str(list.len(roster)), "}"], ""))
      let cfg := { id: cfg.id, request: cfg.request, model: cfg.model, db: cfg.db, api_calls_max: cfg.api_calls_max, roster: roster }
      let __ltgv := match llog_opt {
        None => (),
        Some(log) => {
          let __e := ltrail.graph_validated(log, cfg.id, sprint_graph.id, list.len(sprint_graph.nodes), ltrail.latest_id(log))
          ()
        },
      }
      let __tph2 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Design\",\"to\":\"Implementation\"}")
      let __tpm2 := tr.trail(cfg.db, cfg.id, "phase_manifest", str.join(["{\"phase\":\"Implementation\",\"grant\":\"", manifests.grant_summary_for_phase("Implementation"), "\"}"], ""))
      let impl_result := run_phase(sprint_graph, graph.Implementation, design_ref, [], cfg)
      let impl_ref := first_accepted_artifact(impl_result.outcomes)
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
        { id: str.concat(cfg.id, "-qa"), phase: graph.QA, nodes: [{ id: "qa", role: "qa", gate: "spec json-verdict-pass" }, { id: "demo", role: "demo", gate: "spec non-empty" }], edges: [{ from: "qa", to: "demo", handoff: "schema {}" }] }
      } else {
        sprint_graph
      }
      let qa_impl_result := run_qa_with_bounce(qa_demo_graph, sprint_graph, impl_ref, cfg, 1)
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

