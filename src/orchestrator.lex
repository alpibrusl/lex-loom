# orchestrator.lex — run_phase / run_sprint with an honest effect row (§VI).
#
# Layer 2 of the two-layer architecture: a fixed, effect-typed interpreter
# of the SprintGraph value produced by the Architect (layer 1).
#
# M2 scope: in-process lex-llm workers, sequential node execution,
# gate checked at both ends (producer self-check stub + orchestrator re-check),
# trail recorded for every event, artifacts stored by hash reference.
#
# The declared effect row is the union of every effect the body uses.
# A dishonest twin that omits, say, [llm] or [sql] is rejected at lex check.

import "std.str"  as str
import "std.list" as list
import "std.io"   as io
import "std.int"  as int

import "lex-schema/json_value" as jv
import "lex-agent/src/message" as msg
import "lex-agent/src/server"  as srv
import "lex-soft/src/runner"   as runner

import "./graph"     as graph
import "./metaspec"  as metaspec
import "./phase"     as phase
import "./transport" as tr
import "./roles"     as roles

# ── Types ─────────────────────────────────────────────────────────────────────

type NodeOutcome = {
  node_id  :: Str,
  accepted :: Bool,
  artifact :: Str,   # content hash; "" if denied or failed
  reason   :: Str,   # gate denial or error message; "" if accepted
}

type PhaseResult = {
  phase    :: graph.Phase,
  outcomes :: List[NodeOutcome],
  success  :: Bool,
}

type SprintResult = {
  sprint_id :: Str,
  phases    :: List[PhaseResult],
  success   :: Bool,
  summary   :: Str,
}

# Sprint configuration passed to run_sprint.
type SprintCfg = {
  id      :: Str,
  request :: Str,   # the original project request
  model   :: Str,   # LLM model name for all roles
  db      :: Db,
}

# ── Gate evaluation ───────────────────────────────────────────────────────────
#
# Evaluate-at-both-ends (§10): the producer self-checks before emitting,
# and the orchestrator re-checks before accepting. A denied gate is a hard
# stop — Inconclusive is also a deny, never a silent allow.
#
# M2: gate is evaluated as a non-empty check only. Actual SMT evaluation
# via lex-spec lands in M3 when metaspec.lex gains the spec-checker import.

type GateVerdict = GateAllow | GateDeny(Str)

fn evaluate_gate(gate :: Str, output :: Str) -> GateVerdict {
  if str.is_empty(gate) {
    GateDeny("gate is empty — ungated output not allowed")
  } else if str.is_empty(output) {
    GateDeny("node produced empty output")
  } else {
    # M2 stub: non-empty gate + non-empty output = Allow.
    # M3: replace with spec_checker.evaluate(gate, [("output", output)]).
    GateAllow
  }
}

# ── Node invocation ───────────────────────────────────────────────────────────

fn invoke_node(
  n         :: graph.Node,
  input     :: Str,
  cfg       :: SprintCfg,
) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
  let agent_cfg_opt := roles.for_role(n.role, cfg.model)
  match agent_cfg_opt {
    None =>
      NodeOutcome {
        node_id:  n.id,
        accepted: false,
        artifact: "",
        reason:   str.concat("unknown role: ", n.role),
      },
    Some(agent_cfg) => {
      let handler := runner.make_handler(cfg.db, agent_cfg)
      let in_msg  := msg.user_text(if str.is_empty(input) { cfg.request } else { input })
      let __ts    := tr.trail(cfg.db, cfg.id, "node_started", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\"}"], ""))
      let outcome := handler(in_msg)
      let output  := match outcome.reply {
        None    => "",
        Some(m) => match list.head(m.parts) {
          None               => "",
          Some(TextPart(s))  => s,
          Some(_)            => "",
        },
      }
      # Producer self-check
      let self_verdict := evaluate_gate(n.gate, output)
      match self_verdict {
        GateDeny(reason) => {
          let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"", reason, "\"}"], ""))
          NodeOutcome { node_id: n.id, accepted: false, artifact: "", reason: reason }
        },
        GateAllow => {
          # Orchestrator re-check (evaluate-at-both-ends)
          let re_verdict := evaluate_gate(n.gate, output)
          match re_verdict {
            GateDeny(reason) => {
              let __td := tr.trail(cfg.db, cfg.id, "node_denied", str.join(["{\"node\":\"", n.id, "\",\"reason\":\"re-check: ", reason, "\"}"], ""))
              NodeOutcome { node_id: n.id, accepted: false, artifact: "", reason: str.concat("re-check denied: ", reason) }
            },
            GateAllow => {
              match tr.artifact_put(cfg.db, cfg.id, n.id, output) {
                Err(e) =>
                  NodeOutcome { node_id: n.id, accepted: false, artifact: "", reason: str.concat("artifact store failed: ", e) },
                Ok(hash) => {
                  let __ta := tr.trail(cfg.db, cfg.id, "node_accepted", str.join(["{\"node\":\"", n.id, "\",\"artifact\":\"", hash, "\"}"], ""))
                  NodeOutcome { node_id: n.id, accepted: true, artifact: hash, reason: "" }
                },
              }
            },
          }
        },
      }
    },
  }
}

# ── Layer execution ───────────────────────────────────────────────────────────
#
# Nodes in the same topo layer are independent. M2 runs them sequentially.
# M5: replace list.map here with list.par_map for concurrent fan-out.

fn run_layer(
  layer     :: List[Str],
  g         :: graph.SprintGraph,
  input_ref :: Str,
  cfg       :: SprintCfg,
) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] List[NodeOutcome] {
  list.map(layer, fn (node_id :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] NodeOutcome {
    let node_opt := list.fold(g.nodes, None, fn (acc :: Option[graph.Node], n :: graph.Node) -> Option[graph.Node] {
      match acc {
        Some(_) => acc,
        None    => if n.id == node_id { Some(n) } else { None },
      }
    })
    match node_opt {
      None   => NodeOutcome { node_id: node_id, accepted: false, artifact: "", reason: "node not found in graph" },
      Some(n) => {
        # Resolve input: use the artifact from the first accepted upstream node, else input_ref
        let input_content := if str.is_empty(input_ref) {
          ""
        } else {
          match tr.artifact_get(cfg.db, input_ref) {
            Err(_) => "",
            Ok(c)  => c,
          }
        }
        invoke_node(n, input_content, cfg)
      },
    }
  })
}

# ── run_phase ─────────────────────────────────────────────────────────────────

fn run_phase(
  g         :: graph.SprintGraph,
  p         :: graph.Phase,
  input_ref :: Str,
  cfg       :: SprintCfg,
) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] PhaseResult {
  match graph.topo_sort(g) {
    Err(e) =>
      PhaseResult { phase: p, outcomes: [], success: false },
    Ok(layers) => {
      # Run layers in order; pass the last accepted artifact forward as input_ref
      let result := list.fold(layers, { outcomes: [], last_ref: input_ref, success: true }, fn (
        acc :: { outcomes :: List[NodeOutcome], last_ref :: Str, success :: Bool },
        layer :: List[Str],
      ) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { outcomes :: List[NodeOutcome], last_ref :: Str, success :: Bool } {
        if !acc.success {
          acc
        } else {
          let layer_outcomes := run_layer(layer, g, acc.last_ref, cfg)
          let all_accepted := list.fold(layer_outcomes, true, fn (ok :: Bool, o :: NodeOutcome) -> Bool {
            if !ok { false } else { o.accepted }
          })
          let next_ref := list.fold(layer_outcomes, acc.last_ref, fn (ref :: Str, o :: NodeOutcome) -> Str {
            if o.accepted && !str.is_empty(o.artifact) { o.artifact } else { ref }
          })
          {
            outcomes: list.concat(acc.outcomes, layer_outcomes),
            last_ref: next_ref,
            success:  all_accepted,
          }
        }
      })
      PhaseResult { phase: p, outcomes: result.outcomes, success: result.success }
    },
  }
}

# ── run_sprint ────────────────────────────────────────────────────────────────
#
# One full Intake → Design → Implementation → QA → Demo pass.
# The Architect derives the graph during Design; subsequent phases use it.
#
# Effect row: the honest union of every effect this body touches.

fn run_sprint(cfg :: SprintCfg) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] SprintResult {
  let __ti := tr.trail(cfg.db, cfg.id, "sprint_started", str.join(["{\"request\":\"", cfg.request, "\"}"], ""))

  # ── Step 1: Intake — acknowledge and log the request
  let intake_graph := graph.SprintGraph {
    id:    str.concat(cfg.id, "-intake"),
    phase: graph.Intake,
    nodes: [{ id: "intake", role: "architect", gate: "spec non-empty" }],
    edges: [],
  }
  let intake_result := run_phase(intake_graph, graph.Intake, "", cfg)
  let __tph1 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Intake\",\"to\":\"Design\"}")

  # ── Step 2: Design — Architect derives the sprint graph
  let intake_ref := first_accepted_artifact(intake_result.outcomes)
  let design_graph := graph.SprintGraph {
    id:    str.concat(cfg.id, "-design"),
    phase: graph.Design,
    nodes: [{ id: "design", role: "architect", gate: "spec non-empty" }],
    edges: [],
  }
  let design_result := run_phase(design_graph, graph.Design, intake_ref, cfg)
  let design_ref := first_accepted_artifact(design_result.outcomes)
  let __tph2 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Design\",\"to\":\"Implementation\"}")

  # ── Step 3: Implementation — build role processes the design
  let impl_graph := graph.SprintGraph {
    id:    str.concat(cfg.id, "-impl"),
    phase: graph.Implementation,
    nodes: [{ id: "build", role: "build", gate: "spec non-empty" }],
    edges: [],
  }
  let impl_result := run_phase(impl_graph, graph.Implementation, design_ref, cfg)
  let impl_ref := first_accepted_artifact(impl_result.outcomes)
  let __tph3 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"Implementation\",\"to\":\"QA\"}")

  # ── Step 4: QA — evaluates the implementation
  let qa_graph := graph.SprintGraph {
    id:    str.concat(cfg.id, "-qa"),
    phase: graph.QA,
    nodes: [
      { id: "qa",   role: "qa",   gate: "spec non-empty" },
      { id: "demo", role: "demo", gate: "spec non-empty" },
    ],
    edges: [{ from: "qa", to: "demo", handoff: "schema { type: string }" }],
  }
  let qa_result := run_phase(qa_graph, graph.QA, impl_ref, cfg)
  let demo_ref := first_accepted_artifact(qa_result.outcomes)
  let __tph4 := tr.trail(cfg.db, cfg.id, "phase_advanced", "{\"from\":\"QA\",\"to\":\"Demo\"}")

  # ── Collect results
  let all_phases := [intake_result, design_result, impl_result, qa_result]
  let overall_success := list.fold(all_phases, true, fn (ok :: Bool, pr :: PhaseResult) -> Bool {
    if !ok { false } else { pr.success }
  })
  let summary := if overall_success {
    str.join(["Sprint ", cfg.id, " completed. Demo artifact: ", demo_ref], "")
  } else {
    str.join(["Sprint ", cfg.id, " failed. Check trail for node denials."], "")
  }

  let __tc := tr.trail(cfg.db, cfg.id, "sprint_complete", str.join(["{\"success\":", if overall_success { "true" } else { "false" }, "}"], ""))

  SprintResult {
    sprint_id: cfg.id,
    phases:    all_phases,
    success:   overall_success,
    summary:   summary,
  }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

fn first_accepted_artifact(outcomes :: List[NodeOutcome]) -> Str {
  list.fold(outcomes, "", fn (ref :: Str, o :: NodeOutcome) -> Str {
    if str.is_empty(ref) && o.accepted { o.artifact } else { ref }
  })
}

fn phase_success(pr :: PhaseResult) -> Bool {
  pr.success
}
