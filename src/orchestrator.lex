# orchestrator.lex — run_phase / run_sprint with an honest effect row (§VI).
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

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-agent/src/message" as msg

import "lex-agent/src/server" as srv

import "lex-soft/src/runner" as runner

import "./graph"    as graph
import "./gates"    as gates
import "./metaspec" as metaspec

import "./phase" as phase

import "./transport" as tr

import "./roles" as roles

import "./diff" as diff

import "./digest" as digest

import "./tenant" as tenant

# ── Types ─────────────────────────────────────────────────────────────────────
type NodeOutcome = { node_id :: Str, accepted :: Bool, artifact :: Str, reason :: Str }

type PhaseResult = { phase :: graph.Phase, outcomes :: List[NodeOutcome], success :: Bool }

type SprintResult = { sprint_id :: Str, phases :: List[PhaseResult], success :: Bool, summary :: Str }

type SprintCfg = { id :: Str, request :: Str, model :: Str, db :: Db }

# Artifact cache: maps node_id → artifact_hash for nodes already run.
# Used for re-planning — unchanged nodes reuse their prior artifact.
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
fn invoke_node(n :: graph.Node, input :: Str, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
  let agent_cfg_opt := roles.for_role(n.role, cfg.model)
  match agent_cfg_opt {
    None => { node_id: n.id, accepted: false, artifact: "", reason: str.concat("unknown role: ", n.role) },
    Some(agent_cfg) => {
      let handler := runner.make_handler(cfg.db, agent_cfg)
      let in_msg := msg.user_text(if str.is_empty(input) {
        cfg.request
      } else {
        input
      })
      let __ts := tr.trail(cfg.db, cfg.id, "node_started", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\"}"], ""))
      let outcome := handler(in_msg)
      let output := extract_text(outcome.reply)
      match evaluate_gate(n.gate, output) {
        GateDeny(reason) => {
          let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", reason, "\"}"], ""))
          { node_id: n.id, accepted: false, artifact: "", reason: reason }
        },
        GateAllow => match evaluate_gate(n.gate, output) {
          GateDeny(reason) => {
            let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"re-check: ", reason, "\"}"], ""))
            { node_id: n.id, accepted: false, artifact: "", reason: str.concat("re-check denied: ", reason) }
          },
          GateAllow => match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
            Err(e) => { node_id: n.id, accepted: false, artifact: "", reason: str.concat("artifact store failed: ", e) },
            Ok(hash) => {
              let __ta := tr.trail(cfg.db, cfg.id, "node_accepted", str.join(["{\"node\":\"", n.id, "\",\"artifact\":\"", hash, "\"}"], ""))
              { node_id: n.id, accepted: true, artifact: hash, reason: "" }
            },
          },
        },
      }
    },
  }
}

fn extract_text(reply :: Option[msg.Message]) -> Str {
  match reply {
    None => "",
    Some(m) => match list.head(m.parts) {
      None => "",
      Some(TextPart(s)) => s,
      Some(_) => "",
    },
  }
}

# ── Layer execution ───────────────────────────────────────────────────────────
#
# M3: sequential. M5: replace list.map with list.par_map.
fn run_layer(layer :: List[Str], g :: graph.SprintGraph, input_ref :: Str, cache :: ArtifactCache, cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { outcomes :: List[NodeOutcome], cache :: ArtifactCache } {
  list.fold(layer, { outcomes: [], cache: cache }, fn (acc :: { outcomes :: List[NodeOutcome], cache :: ArtifactCache }, node_id :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { outcomes :: List[NodeOutcome], cache :: ArtifactCache } {
    match cache_get(acc.cache, node_id) {
      Some(hash) => {
        let __ts := tr.trail(cfg.db, cfg.id, "node_reused", str.join(["{\"node\":\"", node_id, "\",\"artifact\":\"", hash, "\"}"], ""))
        let outcome := { node_id: node_id, accepted: true, artifact: hash, reason: "" }
        { outcomes: list.concat(acc.outcomes, [outcome]), cache: acc.cache }
      },
      None => {
        let node_opt := find_node_in_graph(g, node_id)
        match node_opt {
          None => {
            let outcome := { node_id: node_id, accepted: false, artifact: "", reason: "node not found in graph" }
            { outcomes: list.concat(acc.outcomes, [outcome]), cache: acc.cache }
          },
          Some(n) => {
            let input_content := resolve_input(cfg.db, input_ref)
            let outcome := invoke_node(n, input_content, cfg)
            let next_cache := if outcome.accepted {
              cache_put(acc.cache, node_id, outcome.artifact)
            } else {
              acc.cache
            }
            let next_ref := if outcome.accepted {
              outcome.artifact
            } else {
              input_ref
            }
            { outcomes: list.concat(acc.outcomes, [outcome]), cache: next_cache }
          },
        }
      },
    }
  })
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

fn resolve_input(db :: Db, input_ref :: Str) -> [sql, fs_read] Str {
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
              o.accepted
            }
          })
          let next_ref := list.fold(layer_result.outcomes, acc.last_ref, fn (ref :: Str, o :: NodeOutcome) -> Str {
            if o.accepted {
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
  str.join([
    "You are the Architect for a software sprint.\n\n",
    "Project request:\n", request, "\n\n",
    "Output ONLY a JSON object with this exact shape (no prose, no markdown fences):\n",
    "{\n",
    "  \"id\": \"<sprint-graph-id>\",\n",
    "  \"phase\": \"Design\",\n",
    "  \"nodes\": [\n",
    "    {\"id\": \"<node-id>\", \"role\": \"<role>\", \"gate\": \"<gate-expr>\"}\n",
    "  ],\n",
    "  \"edges\": [\n",
    "    {\"from\": \"<node-id>\", \"to\": \"<node-id>\", \"handoff\": \"schema {}\"}\n",
    "  ]\n",
    "}\n\n",
    "Valid roles: architect, build, qa, demo, scribe.\n\n",
    "Valid gate expressions (choose the most specific one for each role):\n",
    "  spec non-empty              — output must not be empty (default)\n",
    "  spec contains PASS          — output must contain the word PASS (use for qa nodes)\n",
    "  spec contains fn            — output must contain a function definition (use for build nodes)\n",
    "  spec starts-with fn         — output must start with fn keyword\n",
    "  spec json                   — output must be valid JSON\n",
    "  spec json-field <key>       — output must be JSON with field <key>\n",
    "  spec len-gt <N>             — output must be longer than N characters\n\n",
    "Rules: every node must have a gate; edges must reference existing node ids; ",
    "no cycles; every demo node must have a qa ancestor.",
  ], "")
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
    let agent_cfg := roles.architect_with_context(cfg.model, specs_context)
    let handler := runner.make_handler(cfg.db, agent_cfg)
    let outcome := handler(msg.user_text(prompt))
    let output := extract_text(outcome.reply)
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
# Full Intake → Design → Implementation → QA → Demo pass.
# M3: Design produces a real SprintGraph used for all subsequent phases.
# Re-planning: if the Architect emits a refined graph after Design, semantic
# diff identifies which nodes need re-running.
fn run_sprint(cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] SprintResult {
  let __reg := tenant.register(cfg.db, cfg.id, cfg.request, "")
  let __ti := tr.trail(cfg.db, cfg.id, "sprint_started", str.join(["{\"request_len\":", int.to_str(str.len(cfg.request)), "}"], ""))
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
      { sprint_id: cfg.id, phases: [intake_result], success: false, summary: str.join(["Sprint ", cfg.id, " failed in Design: ", reason], "") }
    },
    DesignOk(sprint_graph) => {
      let design_ref := intake_ref
      let __tph2 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Design\",\"to\":\"Implementation\"}")
      let impl_result := run_phase(sprint_graph, graph.Implementation, design_ref, [], cfg)
      let impl_ref := first_accepted_artifact(impl_result.outcomes)
      let __tph3 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Implementation\",\"to\":\"QA\"}")
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
        { id: str.concat(cfg.id, "-qa"), phase: graph.QA, nodes: [{ id: "qa", role: "qa", gate: "spec contains PASS" }, { id: "demo", role: "demo", gate: "spec non-empty" }], edges: [{ from: "qa", to: "demo", handoff: "schema {}" }] }
      } else {
        sprint_graph
      }
      let qa_result := run_phase(qa_demo_graph, graph.QA, impl_ref, [], cfg)
      let demo_ref := first_accepted_artifact(qa_result.outcomes)
      let __tph4 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"QA\",\"to\":\"Demo\"}")
      let retro_graph := { id: str.concat(cfg.id, "-retro"), phase: graph.Retro, nodes: [{ id: "retro-scribe", role: "scribe", gate: "spec non-empty" }], edges: [] }
      let retro_result := run_phase(retro_graph, graph.Retro, demo_ref, [], cfg)
      let __tph5 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Retro\",\"to\":\"Digest\"}")
      let next_sprint_id := str.concat(cfg.id, "-next")
      let digest_result := digest.run_digest(cfg.id, next_sprint_id, cfg.model, cfg.db)
      let __tph6 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Digest\",\"to\":\"Intake\"}")
      let digest_summary := match digest_result {
        DigestOk(d) => str.join([" Digest: ", int.to_str(list.len(d.tightened_specs)), " spec(s) tightened."], ""),
        DigestFailed(e) => str.join([" Digest failed: ", e], ""),
      }
      let all_phases := [intake_result, impl_result, qa_result, retro_result]
      let overall_ok := list.fold(all_phases, true, fn (ok :: Bool, pr :: PhaseResult) -> Bool {
        if not ok {
          false
        } else {
          pr.success
        }
      })
      let summary := if overall_ok {
        str.join(["Sprint ", cfg.id, " complete. Demo: ", demo_ref, ".", digest_summary], "")
      } else {
        str.join(["Sprint ", cfg.id, " failed. Check trail for node denials.", digest_summary], "")
      }
      let __tc := tr.trail(cfg.db, cfg.id, "sprint_complete", str.join(["{\"success\":", if overall_ok {
        "true"
      } else {
        "false"
      }, "}"], ""))
      let __ts := if overall_ok {
        tenant.complete(cfg.db, cfg.id)
      } else {
        tenant.fail(cfg.db, cfg.id)
      }
      { sprint_id: cfg.id, phases: all_phases, success: overall_ok, summary: summary }
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
    if str.is_empty(ref) and o.accepted {
      o.artifact
    } else {
      ref
    }
  })
}

