import "std.list" as list

import "std.str" as str

import "./graph" as graph

import "./gates" as gates

# ── Types ────────────────────────────────────────────────────────────────────
# A single rule violation. Collecting all violations (not short-circuiting)
# lets the Architect fix everything in one round-trip.
type Violation = { rule :: Str, message :: Str }

type MetaspecResult = Valid | Invalid(List[Violation])

fn rule_all_nodes_gated(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.gate) {
      list.concat(acc, [{ rule: "all-nodes-gated", message: str.join(["node ", n.id, " has no gate"], "") }])
    } else {
      acc
    }
  })
}

# Rule 2: every edge must carry a handoff schema (structural; also in graph.validate).
fn rule_all_edges_have_handoff(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.edges, [], fn (acc :: List[Violation], e :: graph.Edge) -> List[Violation] {
    if str.is_empty(e.handoff) {
      list.concat(acc, [{ rule: "all-edges-have-handoff", message: str.join(["edge ", e.from, "->", e.to, " has no handoff schema"], "") }])
    } else {
      acc
    }
  })
}

# Rule 3: every node must have a non-empty role.
fn rule_all_nodes_have_role(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.role) {
      list.concat(acc, [{ rule: "all-nodes-have-role", message: str.join(["node ", n.id, " has empty role"], "") }])
    } else {
      acc
    }
  })
}

# Rule 4: graph must be a DAG (no unbounded cycles).
# Bounded cycles are allowed in a future extension via an iteration-budget field
# on Edge; until that field exists every cycle is a violation.
fn rule_dag(g :: graph.SprintGraph) -> List[Violation] {
  match graph.topo_sort(g) {
    Ok(_) => [],
    Err(e) => [{ rule: "dag-or-budgeted-cycle", message: e }],
  }
}

# Rule 5: every node whose role contains "demo" (case-insensitive) must be
# reachable from at least one node whose role contains "qa".
# This encodes: you cannot demo unverified work.
fn rule_qa_dominates_demo(g :: graph.SprintGraph) -> List[Violation] {
  let demo_nodes := list.fold(g.nodes, [], fn (acc :: List[graph.Node], n :: graph.Node) -> List[graph.Node] {
    if str_role_is(n.role, "demo") {
      list.concat(acc, [n])
    } else {
      acc
    }
  })
  let qa_nodes := list.fold(g.nodes, [], fn (acc :: List[graph.Node], n :: graph.Node) -> List[graph.Node] {
    if str_role_is(n.role, "qa") {
      list.concat(acc, [n])
    } else {
      if n.role == "py_qa" {
        list.concat(acc, [n])
      } else {
        acc
      }
    }
  })
  list.fold(demo_nodes, [], fn (acc :: List[Violation], demo :: graph.Node) -> List[Violation] {
    let has_qa_ancestor := list.fold(qa_nodes, false, fn (found :: Bool, qa :: graph.Node) -> Bool {
      if found {
        true
      } else {
        can_reach(g, qa.id, demo.id)
      }
    })
    if not has_qa_ancestor {
      list.concat(acc, [{ rule: "qa-dominates-demo", message: str.join(["demo node ", demo.id, " has no qa node ancestor (cannot demo unverified work)"], "") }])
    } else {
      acc
    }
  })
}

# Rule 6: graph must not be empty.
fn rule_non_empty(g :: graph.SprintGraph) -> List[Violation] {
  if list.is_empty(g.nodes) {
    [{ rule: "non-empty", message: "SprintGraph has no nodes" }]
  } else {
    []
  }
}

# ── Graph reachability helper (pure) ──────────────────────────────────────────
fn successors(g :: graph.SprintGraph, id :: Str) -> List[Str] {
  list.fold(g.edges, [], fn (acc :: List[Str], e :: graph.Edge) -> List[Str] {
    if e.from == id {
      list.concat(acc, [e.to])
    } else {
      acc
    }
  })
}

# BFS reachability — can we get from `from` to `to` following edges?
fn can_reach(g :: graph.SprintGraph, from :: Str, to :: Str) -> Bool {
  bfs(g, [from], to, [])
}

fn bfs(g :: graph.SprintGraph, frontier :: List[Str], target :: Str, visited :: List[Str]) -> Bool {
  match list.head(frontier) {
    None => false,
    Some(current) => if current == target {
      true
    } else {
      let next_visited := list.concat(visited, [current])
      let rest := graph.str_filter(frontier, fn (s :: Str) -> Bool {
        s != current
      })
      let nexts := list.fold(successors(g, current), rest, fn (acc :: List[Str], s :: Str) -> List[Str] {
        if if graph.str_contains(next_visited, s) {
          true
        } else {
          graph.str_contains(acc, s)
        } {
          acc
        } else {
          list.concat(acc, [s])
        }
      })
      bfs(g, nexts, target, next_visited)
    },
  }
}

fn str_role_is(role :: Str, keyword :: Str) -> Bool {
  str.starts_with(str.to_lower(role), keyword)
}

# ── Rule 7: every node role must resolve to a registered agent (#33) ──────────
# Hallucinated/typo'd roles (e.g. "builder", "implement") otherwise pass the
# metaspec and only fail at runtime with "unknown role" — after the design round
# is already spent. Catch them up front. Keep in sync with roles.for_role.
fn known_roles() -> List[Str] {
  ["pm", "architect", "build", "py_build", "fe_build", "qa", "py_qa", "devops", "deploy", "docs", "security", "ux_designer", "brand_designer", "content_designer", "launch", "demo", "brand_strategist", "copywriter", "content_creator", "seo_specialist", "finance", "legal", "monetization_handoff", "scribe"]
}

fn role_is_known(role :: Str) -> Bool {
  list.fold(known_roles(), false, fn (found :: Bool, r :: Str) -> Bool {
    if found {
      true
    } else {
      r == role
    }
  })
}

fn rule_roles_resolve(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.role) {
      acc
    } else {
      if role_is_known(n.role) {
        acc
      } else {
        list.concat(acc, [{ rule: "roles-resolve", message: str.join(["node ", n.id, " has unknown role '", n.role, "' (no registered agent)"], "") }])
      }
    }
  })
}

# ── Rule 8: every gate must be a recognized expression (#32/#33) ──────────────
# An unrecognized gate silently falls back to the non-empty check in
# gates.evaluate — a silent-allow that defeats predictability. Reject up front.
fn rule_gates_well_formed(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.gate) {
      acc
    } else {
      if gates.is_well_formed(n.gate) {
        acc
      } else {
        list.concat(acc, [{ rule: "gates-well-formed", message: str.join(["node ", n.id, " has unrecognized gate '", n.gate, "' (would silently fall back to non-empty)"], "") }])
      }
    }
  })
}

# ── Rule 9: expand nodes must use a gatable gate (#35) ───────────────────────
# An expand node runs a full child sprint; its gate is evaluated against the
# child sprint result JSON. It must use a real gate (not len-gt which is a
# vibe check) so the expansion is honestly auditable.
fn rule_expand_gates(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    match n.expand {
      None => acc,
      Some(_) => if str.starts_with(n.gate, "spec len-gt") {
        list.concat(acc, [{ rule: "expand-gate", message: str.join(["expand node ", n.id, " uses weak gate '", n.gate, "' — use 'spec json' or stronger"], "") }])
      } else {
        acc
      },
    }
  })
}

# ── Rule 10: 'spec compiles' only means something for build/py_build (#21) ───
# `spec compiles` runs the real compiler against work_dir_for(role) — but only
# build/py_build ever write files there via a tool (lex_check/py_check). Every
# other role (ux_designer, docs, devops, ...) just returns prose in its final
# answer; nothing is ever persisted for the compiler to check, so the gate
# fails FOREVER, burning every retry with no informative error. Found live: an
# e2e sprint graph where the architect (a weaker local model) tagged a
# ux_designer spec node with 'spec compiles', bouncing the whole phase 4 times
# before the sprint failed. Catch this at graph-validation time — cheap — so
# the architect is told to fix the graph before any node ever runs.
fn rule_compiles_gate_matches_role(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.trim(n.gate) == "spec compiles" {
      if n.role == "build" {
        acc
      } else {
        if n.role == "py_build" {
          acc
        } else {
          list.concat(acc, [{ rule: "compiles-gate-matches-role", message: str.join(["node ", n.id, " (role '", n.role, "') uses gate 'spec compiles', but only build/py_build nodes write files a compiler can check — this role's output is never persisted, so the gate can never pass. Use 'spec judge \"...\"' or 'spec len-gt N' instead."], "") }])
        }
      }
    } else {
      acc
    }
  })
}

# ── Rule 11: monetization_handoff must never be self-certified (#89) ─────────
# The one node in the whole graph a model must never attest itself: it hands
# off creating a real payment/product integration to a human. A `spec judge`
# or any autonomous gate here would let the model decide monetization is
# "shipped" on its own say-so — exactly what this role exists to prevent.
# Enforced structurally, not just by prompt instruction, matching this
# codebase's own attestation-ladder philosophy (grounded > judge > human):
# if the model's prompt-following slips, the graph is rejected outright.
fn rule_monetization_handoff_is_human_gated(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if n.role == "monetization_handoff" {
      if gates.is_judgeable(n.gate) {
        acc
      } else {
        list.concat(acc, [{ rule: "monetization-handoff-human-gated", message: str.join(["node ", n.id, " (role 'monetization_handoff') uses gate '", n.gate, "', but this role must NEVER be self-certified — its gate must be 'human <oracle>' (e.g. 'human founder')."], "") }])
      }
    } else {
      acc
    }
  })
}

# ── Public API ────────────────────────────────────────────────────────────────
fn check(g :: graph.SprintGraph) -> MetaspecResult
  examples {
    check({ id: "g0", phase: graph.Intake, nodes: [{ id: "n1", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }) => Valid,
    check({ id: "g1", phase: graph.Intake, nodes: [], edges: [] }) => Invalid([{ rule: "non-empty", message: "SprintGraph has no nodes" }]),
    check({ id: "g2", phase: graph.QA, nodes: [{ id: "d", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "qa-dominates-demo", message: "demo node d has no qa node ancestor (cannot demo unverified work)" }]),
    check({ id: "g3", phase: graph.QA, nodes: [{ id: "q", role: "qa", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "q", to: "d", handoff: "schema {}" }] }) => Valid,
    check({ id: "g4", phase: graph.Intake, nodes: [{ id: "a", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "b", role: "qa", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }, { from: "b", to: "a", handoff: "schema {}" }] }) => Invalid([{ rule: "dag-or-budgeted-cycle", message: "cycle detected in SprintGraph — add an iteration budget to allow bounded cycles" }]),
    check({ id: "g5", phase: graph.Intake, nodes: [{ id: "n1", role: "builder", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "roles-resolve", message: "node n1 has unknown role 'builder' (no registered agent)" }]),
    check({ id: "g6", phase: graph.Intake, nodes: [{ id: "n1", role: "build", gate: "spec maybe-ok", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "gates-well-formed", message: "node n1 has unrecognized gate 'spec maybe-ok' (would silently fall back to non-empty)" }]),
    check({ id: "g7", phase: graph.Intake, nodes: [{ id: "n1", role: "ux_designer", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "compiles-gate-matches-role", message: "node n1 (role 'ux_designer') uses gate 'spec compiles', but only build/py_build nodes write files a compiler can check — this role's output is never persisted, so the gate can never pass. Use 'spec judge \"...\"' or 'spec len-gt N' instead." }]),
    check({ id: "g8", phase: graph.Intake, nodes: [{ id: "n1", role: "monetization_handoff", gate: "spec judge \"looks good\"", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "monetization-handoff-human-gated", message: "node n1 (role 'monetization_handoff') uses gate 'spec judge \"looks good\"', but this role must NEVER be self-certified — its gate must be 'human <oracle>' (e.g. 'human founder')." }])
  }
{
  let violations := list.fold([rule_non_empty(g), rule_all_nodes_have_role(g), rule_all_nodes_gated(g), rule_all_edges_have_handoff(g), rule_dag(g), rule_qa_dominates_demo(g), rule_roles_resolve(g), rule_gates_well_formed(g), rule_expand_gates(g), rule_compiles_gate_matches_role(g), rule_monetization_handoff_is_human_gated(g)], [], fn (acc :: List[Violation], vs :: List[Violation]) -> List[Violation] {
    list.concat(acc, vs)
  })
  if list.is_empty(violations) {
    Valid
  } else {
    Invalid(violations)
  }
}

